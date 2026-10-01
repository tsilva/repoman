# Repository isolation research

Investigated on 2026-10-01 for RepoMan on macOS 27. The objective is to give each launched Codex process unrestricted execution and editing inside one existing repository, while preventing access to other host repositories and personal files. Required system tools, authentication, and disposable runtime storage need a separately defined policy. This report records research and disposable experiments; it does not enable a new product sandbox.

## Current conclusion

Apple Containerization is the strongest supported candidate for Linux-compatible repositories: a Swift package using Apple's Virtualization framework and a separate lightweight Linux VM for each container. The local fixture successfully ran unrestricted guest commands and repository binaries while blocking other host paths. A writable live share still modified an external hardlink alias, so the preferred strict design uses an independent-inode repository snapshot and a trusted, confined change import. That import is not implemented yet. Linux cannot transparently run native macOS binaries or Xcode. [Apple Containerization](https://github.com/apple/containerization), [container 0.7.1 architecture](https://github.com/apple/container/blob/0.7.1/docs/technical-overview.md).

The execution backend is suitable and verified for offline Linux Codex commands. End-to-end authenticated repairs, the Swift library integration, and secure change import remain implementation work; this investigation has not enabled them in RepoMan.

No supported, immediately deployable, extremely lightweight native macOS mechanism was found that meets all the original constraints. App Sandbox prevents arbitrary execution in dynamically selected directories. Endpoint Security descendants clients can apply native policies, but have entitlement, coverage, and client-loss limitations. A full macOS VM remains the stronger native-toolchain alternative, with substantially more guest setup than a Linux container.

## Recommended RepoMan architecture

1. Create a private repository snapshot using independent inodes; use APFS copy-on-write cloning when available. Preserve the original tree as the change-import baseline.
2. Launch one daemonless Linux VM through the Swift Containerization library, mounting only the snapshot. Use a reviewed fixed library version rather than the older CLI used for this experiment.
3. Boot a controlled prebuilt image containing Linux Codex and the repository's Linux toolchain. Run Codex with full guest permissions and no approval prompts.
4. Keep host home directories, global Codex configuration, control sockets, SSH agent and inherited host environment out of the guest. Keep caches and sessions in guest/private storage.
5. Give the guest no network interface. Add a narrow outbound HTTP/authentication broker over vsock for model requests and approved dependency traffic; this broker is proposed and untested.
6. Stop the VM before collecting output. Import a validated, conflict-checked patch with trusted host code that cannot follow arbitrary output paths or write through hardlinks. This importer is not implemented.

This preserves full execution autonomy in the guest while keeping host effects under a small trusted interface. It intentionally replaces immediate edits to the original working tree with snapshot execution and controlled import. For repositories requiring Xcode or other native macOS binaries, use a macOS guest instead of claiming Linux compatibility.

## Endpoint Security descendants clients

The installed macOS 27 SDK declares `es_new_descendants_client`. It receives notifications for its own process and authorization plus notification events for existing and future descendants. It requires neither root nor TCC approval, but still requires `com.apple.developer.endpoint-security.client`. Unlike the older system-wide client, it cannot observe unrelated processes. [Apple API documentation](https://developer.apple.com/documentation/endpointsecurity/es_new_descendants_client(_:_:)), [installed ESClient.h](/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include/EndpointSecurity/ESClient.h:798).

The entitlement must be requested from Apple; adding an entitlement string to an ad-hoc signature is insufficient provisioning. Apple engineers confirm that an app or helper can host the client, rather than requiring a system extension, and that the newer API targets AI-agent confinement. Current signing infrastructure requires the client to reside in a bundle. No approved entitlement or valid signing identity is available locally, so actual enforcement could not be tested here. [Entitlement requirement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.endpoint-security.client), [Apple helper guidance](https://developer.apple.com/forums/thread/832204), [Apple signing/lifecycle guidance](https://developer.apple.com/forums/thread/848882).

There is a decisive lifetime limitation: Apple DTS explicitly confirms that when the client disappears, its restrictions disappear and future operations are allowed. No persistent policy mechanism is available today. A later watchdog reaction would leave an interval without enforcement; cooperative exit-on-parent-death cannot establish a boundary against untrusted code. [Apple client-loss explanation](https://developer.apple.com/forums/thread/845950).

The following details come directly from the installed SDK headers:

| Surface | Available control | Limitation for this requirement |
| --- | --- | --- |
| Content reads and writes | `AUTH_OPEN`, create, unlink, rename, truncate, copyfile, mmap and other authorization events | `WRITE` is notification-only. Prevent already-open host descriptors from entering the worker; authorizing opens does not reauthorize every later byte read/write. |
| Directory access | `AUTH_READDIR`, `AUTH_CHDIR`, `AUTH_READLINK` and attribute-related events | `STAT` and `ACCESS` are notification-only. A strict promise of no external metadata access is unsupported. |
| Execution and process manipulation | `AUTH_EXEC`, signal, get-task, process checks, suspend/resume | All authorization events must be subscribed and handled deliberately; notification alone cannot prevent an operation. |
| Unix sockets | `AUTH_UIPC_CONNECT`, `AUTH_UIPC_BIND` | There is no general IP socket-connect authorization event in the enum; host/LAN service access needs another network boundary. |
| Named XPC/Mach services | macOS 27 `AUTH_XPC_CONNECT`, `AUTH_BOOTSTRAP_LOOK_UP`, `AUTH_BOOTSTRAP_CHECK_IN` | These can restrict named service acquisition, not arbitrary messages sent over inherited/transferred Mach rights. Broad allowed services could perform work outside the process tree. |
| Handler deadline or queue overflow | `es_set_deadline_miss_mode(...FAIL_CLOSED)` | It denies missed/dropped authorization events while the client exists; it does not persist restrictions after client loss. |

Sources: [event enum and version availability](/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include/EndpointSecurity/ESTypes.h:106), [event data and semantics](/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include/EndpointSecurity/ESMessage.h:2432), [deadline behavior](/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include/EndpointSecurity/ESClient.h:832). The descriptor and inherited-Mach-right conclusions are architectural inferences from operation-specific authorization, not locally demonstrated escapes.

Apple DTS says descendants cannot become invisible through reparenting or session changes. However, LaunchServices/XPC jobs started by unrelated daemons are not thereby descendants: the design must deny or narrowly broker those services. New bootstrap events report the initiating process separately from launchd, which submits the event. A policy that checks only the enclosing message's process would attribute these requests incorrectly. [Apple subtree guidance](https://developer.apple.com/forums/thread/848882), [SDK bootstrap fields](/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include/EndpointSecurity/ESMessage.h:2444).

Verdict: useful for a native policy product with Apple provisioning and a carefully stated threat model; unsuitable as RepoMan's immediate hard isolation boundary by itself.

## Supported App Sandbox accommodations

Dynamic security-scoped folder grants authorize reads and writes, not execution. `com.apple.security.files.user-selected.executable` permits writing executable files without the usual quarantine restriction; it does not grant dynamic execution permission. Apple's current documentation explicitly disallows using user-selected access to run programs outside the app bundle or its permitted containers. [File access documentation](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox), [entitlement explanation](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html).

The earlier native fixture experiment granted repository editing, blocked sibling access and symlink escapes, and successfully ran bundled Codex under an outer App Sandbox. It could interpret a repo script with `/bin/sh`, but could not execute a repo-local binary or script directly. `/usr/bin/git` and `/usr/bin/clang` failed through `xcrun`; direct tools inside Xcode passed version checks only. The experiment and assertions are preserved in [.build/app-sandbox-investigation/Findings.md](/Users/tsilva/repos/tsilva/repoman/.build/app-sandbox-investigation/Findings.md).

Bundling a controlled toolset or copying executable outputs into the helper's container is possible, but changes paths and does not establish unrestricted in-place execution. A shared helper container can expose data from previous repository sessions. Statically listing repository paths in temporary exception entitlements is also different from a dynamic grant: entitlements are sealed into the executable's signature. Generating or re-signing a helper per selected repo has not been validated for distribution and is not a documented dynamic execution solution. Broadly granting all repositories would defeat repository isolation. [Static path exceptions](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html), [signed entitlements](https://developer.apple.com/documentation/bundleresources/entitlements).

Apple's developer-tool guidance warns that complex toolchains may stop working in App Sandbox and recommends either accepting those limits or embedding controlled tool versions. It provides no supported dynamic executable permission workaround. [Developer tools guidance](https://developer.apple.com/forums/thread/746478).

Verdict: appropriate for restricted editing/repair with a controlled toolset; not the requested general developer environment.

## Alternative comparison

| Approach | Repository behavior | Main tradeoff |
| --- | --- | --- |
| Apple Containerization / `container` | One writable host directory share in a separate Linux VM; arbitrary Linux tools and outputs can execute | Strong candidate for Linux-compatible repos; initial kernel/image setup, guest memory, Linux dependency environment. |
| BoxLite | Embedded Rust microVM engine with C, Python and other SDKs; selected volume shares | Library candidate, but Swift needs a C bridge and the macOS host jailer uses deprecated `sandbox-exec` as an additional layer. |
| Linux bubblewrap with Landlock/seccomp | Lightweight mount/process/network namespaces plus persistent descendant restrictions | Linux-only; on a Mac it still needs a Linux VM or remote Linux host. Policy arguments and kernel features determine security. |
| Docker on macOS | Bind-mount only the selected repo into a Linux container | Existing installations make an early prototype convenient, but runtime management and shared-VM architecture add machinery. Never expose the daemon socket or privileged host mounts. |
| Dedicated Lima instance | Linux VM with explicitly configured mounts and tool environment | Defaults include home sharing; must override those defaults. General-purpose VM setup is broader than the per-container Apple design. |
| Full macOS VM through Virtualization.framework | Native macOS/Xcode inside a guest with only selected shares | Native compatibility, but guest installation, disk image, macOS updates, and development tool setup are substantially heavier. |
| `sandbox-exec` or wrappers using it | Native process-tree restriction with custom profiles | Deprecated custom policy interface; not a long-term supported recommendation. |

Primary sources: [Apple container 0.7.1 overview](https://github.com/apple/container/blob/0.7.1/docs/technical-overview.md), [bubblewrap policy responsibility](https://github.com/containers/bubblewrap), [Landlock inheritance and limitations](https://docs.kernel.org/userspace-api/landlock.html), [Docker security](https://docs.docker.com/engine/security/), [Lima mounts](https://lima-vm.io/docs/config/mount/), [Apple macOS VM guide](https://developer.apple.com/documentation/virtualization/running-macos-in-a-virtual-machine-on-apple-silicon), [Apple custom-sandbox guidance](https://developer.apple.com/forums/thread/661939).

Landlock can add restrictions that descendants cannot remove, but it is not a filesystem visibility namespace and has ABI-dependent capabilities. Bubblewrap starts from a separate mount namespace and exposes paths chosen by the caller. Both require deliberate descriptor, process, IPC, and network policy rather than assuming that a directory allowlist is sufficient. Neither executes macOS binaries.

BoxLite provides per-box hardware virtualization through KVM or Hypervisor.framework and a C SDK, so a Swift bridge is possible. Its own feature list identifies `sandbox-exec` as the macOS OS-level jailer. The guest VM is a separate boundary, but this is not an entirely deprecation-free stack. Apple's first-party Swift package is a more direct fit for RepoMan; neither comparison establishes a measured performance advantage. [BoxLite source and SDK overview](https://github.com/boxlite-ai/boxlite).

## First-party coding-agent example and version caveats

Apple's experimental `sandboxy` example already implements a closely matching flow: one Linux VM per agent session, a virtio-fs workspace share, cached environment, and configurable agent launch commands. Claude and Pi definitions are built in; Codex needs a custom definition. It advertises warm starts below one second, but that is a project claim, not a measurement on this machine. Defaults are four CPUs and 4 GB, adjustable by the caller. The example deliberately mounts agent configuration and forwards selected variables, and its README admits that host services listening on `0.0.0.0` remain reachable. Use it as an integration reference, not an unmodified hard-boundary solution. [Apple sandboxy README](https://github.com/apple/containerization/blob/main/examples/sandboxy/README.md).

The source's initial installation phase also shares the workspace and configured mounts while it uses full networking. For RepoMan, build/cache the controlled guest image before attaching repository data or credentials. Its runtime environment is constructed explicitly, and process streams can be supplied by the calling app. The example's entitlement file requests only `com.apple.security.virtualization`, unlike Endpoint Security's restricted entitlement. [Agent launch implementation](https://github.com/apple/containerization/blob/main/examples/sandboxy/Sources/sandboxy/RunAgentCommand.swift), [example entitlements](https://github.com/apple/containerization/blob/main/examples/sandboxy/sandboxy.entitlements).

The installed `container` CLI is 0.7.1 and is used only for the disposable local probe. It is not a deployment recommendation. Apple subsequently fixed host environment leakage when an untrusted image declared a bare variable name rather than `NAME=value`; the fix is included in CLI 1.2.0. A product should require a current reviewed fixed version and an explicit environment, not inherit host secrets. [Apple fix and regression test](https://github.com/apple/container/pull/2027), [1.2.0 release](https://github.com/apple/container/releases/tag/1.2.0).

This specific flaw is in the higher-level CLI's `Parser.allEnv`. The low-level Containerization `LinuxProcessConfiguration` copies or accepts an environment array and serializes it directly to OCI without looking up bare names in the host environment. Using the library avoids that particular parser path; filtering image variables and supplying explicit guest variables is still preferable. This is source inspection, not a security audit of every library path. [Library process configuration](https://github.com/apple/containerization/blob/main/Sources/Containerization/LinuxProcessConfiguration.swift), [CLI fix diff](https://github.com/apple/container/pull/2027/files).

## Integration conditions for a Linux VM candidate

Share exactly one canonical repository directory, not its parent, the user's home, Docker socket, SSH agent, or the host's complete Codex state. Provide a Linux Codex executable and the repository's Linux toolchain in the guest. Keep caches and session state guest-local. Authentication needs a narrow token or network broker design; it has not yet been tested with real credentials.

Treat linked worktrees, Git alternates and submodules whose metadata lives outside the shared root as unsupported unless explicitly resolved without widening host access. A share exposes the selected directory, so external hardlinks and aliases need inspection or an independent-inode copy if their effect must be excluded. A live preflight check alone would not prevent another host process from adding an external alias afterward. Symlinks referring to host-only absolute paths should fail inside the guest, but must be verified against the chosen sharing implementation.

Network access is a separate boundary. A guest that can reach an unrestricted host service can ask that service to perform unsandboxed work. Keep host control APIs private and explicitly decide whether host/LAN access is allowed. The strongest proposed architecture keeps the guest without a network interface and routes only approved model/package traffic through a dedicated vsock broker. That broker is not implemented or tested. The guest's own root filesystem and tools remain accessible; the intended guarantee concerns access to other host data, not literally a filesystem containing only the repository.

A snapshot copies bytes accessible through ordinary repository entries; it does not sanitize content or exclude bytes that happen to have another hardlink outside the repository. If the policy requires excluding all such objects, reject multiply linked files before copying. Copy-on-write APFS clones create independent inodes and therefore separate future writes, but are not a semantic filter for secrets already present in the repo.

Importing results must not follow guest-created symlinks or overwrite existing externally aliased files in place. A trusted importer needs no-follow directory traversal, ordinary-file validation, conflict checks against the original snapshot, and atomic replacement with new inodes. Treat unsupported file types, ambiguous links or concurrent source changes as errors. Without these controls, importing the sandbox's output could recreate the very host access the VM prevented. This is a proposed integration requirement, not a completed product feature.

## Local VM verification

The disposable fixture used installed Apple `container` 0.7.1, Alpine 3.22.2, one CPU, a configured 128 MiB guest-memory limit, and no network interface. No actual authentication credentials were copied and no model inference was requested.

| Fixture operation | Direct repository share | Independent APFS snapshot |
| --- | --- | --- |
| Run as guest root | Allowed | Allowed |
| Read/write workspace | Allowed | Allowed |
| Copy a Linux executable into workspace and run it | Allowed | Allowed |
| Child-process workspace write | Allowed | Allowed |
| Read/write sibling host directory through an absolute or relative symlink | Blocked | Blocked |
| Read/write host-only absolute paths | Blocked | Blocked |
| Network interfaces | Loopback only | Loopback only |
| Write an entry hardlinked to a sibling host file | Modified sibling inode | Modified snapshot only; original inode unchanged |

One cached direct-share fixture invocation took about 2.094 seconds. The small APFS snapshot operation (`/bin/cp -cR`) took about 0.0063 seconds, and its container fixture invocation took about 1.159 seconds. These are single observations of a tiny shell fixture, not general startup, memory, copying or developer-workload benchmarks. In particular, a 128 MiB shell fixture says nothing about sufficient memory for Codex or builds.

Evidence: [direct fixture results](/Users/tsilva/repos/tsilva/repoman/.build/container-isolation-investigation/fixture.json), [snapshot fixture results](/Users/tsilva/repos/tsilva/repoman/.build/container-isolation-investigation/snapshot.json). The guest root was writable and distinct from the host; full-autonomy commands could change their guest environment while the host-path tests still failed.

The subsequent fixture used the official Linux musl Codex 0.159.2 binary, checked against its GitHub release SHA-256 digest. In a cached VM with a configured 512 MiB memory ceiling and no network interface, its app-server initialized in about 1.157 seconds. This is a single observed initialize time and a configured ceiling, not measured resident memory.

An actual app-server `command/exec` request with `sandboxPolicy.type = dangerFullAccess` succeeded: Codex executed a workspace-local binary and wrote the snapshot; three outside/symlink reads stayed blocked. A hardlink write changed only the snapshot, the original external alias stayed unchanged, and the original repository received no newly created file. The Codex executable was shared read-only solely for this fixture; production would embed it in the controlled guest image. [Codex protocol results](/Users/tsilva/repos/tsilva/repoman/.build/container-isolation-investigation/codex.json).

No authentication, model turn or inference was involved. Model networking, authentication refresh, a representative build/test workflow, secure import and shipped Swift-library integration remain unverified. The tested older CLI provides evidence for the execution model, not evidence that its version should be deployed.

All containers created by this investigation were removed. The Apple container service was restored to its initially inactive state; existing Docker and Lima installations were not changed. Disposable fixture sources and logs remain under `.build/container-isolation-investigation/`. Product code and launch behavior were not changed by this research.
