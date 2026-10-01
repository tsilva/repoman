import Foundation

enum RepositoryGitHealthChecks {
    static func checks() -> [RepositoryCheck] {
        [
            CheckSupport.check("git.unpublishedBranches", "Unpublished branch work", .git, "arrow.up.doc", inspect: { context, _ in
                try requireRemoteState(context)
                guard try hasRemote(context) else { return [] }
                let remotes = try context.gitRead(["for-each-ref", "--format=%(refname)", "refs/remotes"])
                guard !remotes.isEmpty else { throw RepairError.blocked("No fetched remote branches are available for comparison.") }
                let occupied = Set(try text(context, ["worktree", "list", "--porcelain"]).components(separatedBy: .newlines)
                    .filter { $0.hasPrefix("branch refs/heads/") }.map { String($0.dropFirst("branch ".count)) })
                var findings: [RepositoryFinding] = []
                for branch in try branches(context) where !occupied.contains(branch.ref) {
                    let output = try text(context, ["rev-list", "--count", branch.ref, "--not", "--remotes"])
                    guard let count = Int(output), count >= 0 else { throw RepairError.blocked("Invalid branch comparison result.") }
                    if count > 0 {
                        findings.append(CheckSupport.finding(context, "git.unpublishedBranches", branch.ref, "Unpublished branch work",
                            "\(branch.name) contains \(count) commits unreachable from any fetched remote branch. Review this work before removing the branch.", .git, "arrow.up.doc"))
                    }
                }
                return findings
            }),
            CheckSupport.check("git.upstream", "Missing or deleted upstream", .git, "arrow.triangle.branch", inspect: { context, _ in
                try requireRemoteState(context)
                guard try hasRemote(context) else { return [] }
                let current = try text(context, ["symbolic-ref", "--quiet", "HEAD"], codes: [0, 1])
                var findings: [RepositoryFinding] = []
                for branch in try branches(context) {
                    if branch.upstream.isEmpty, branch.ref == current {
                        let configured = try text(context, ["config", "--get", "branch.\(branch.name).merge"], codes: [0, 1])
                        findings.append(CheckSupport.finding(context, "git.upstream", branch.ref, "Missing upstream",
                            configured.isEmpty ? "\(branch.name) has no configured upstream although this repository has remotes. Confirm whether this is intentionally a local branch." :
                                "\(branch.name) has upstream configuration, but Git cannot resolve its tracking ref. Review its remote and fetch mapping.", .git, "arrow.triangle.branch", severity: .information))
                    } else if branch.tracking == "[gone]" {
                        findings.append(CheckSupport.finding(context, "git.upstream", branch.ref, "Configured upstream is missing",
                            "\(branch.name) tracks \(branch.upstream), but that ref is absent locally. Refresh remote refs and review whether the branch was deleted or tracking needs repair.", .git, "arrow.triangle.branch"))
                    }
                }
                return findings
            }),
            CheckSupport.check("git.checkoutIntegrity", "Broken submodule or LFS checkout", .git, "shippingbox", inspect: { context, _ in
                var findings: [RepositoryFinding] = []
                // No submodule traversal, hooks, network access or LFS filter execution.
                let index = try text(context, ["ls-files", "--stage", "-z"])
                for entry in index.split(separator: "\0") {
                    guard let tab = entry.firstIndex(of: "\t") else { throw RepairError.blocked("Invalid Git index record.") }
                    let fields = entry[..<tab].split(separator: " ")
                    guard fields.count == 3 else { throw RepairError.blocked("Invalid Git index metadata.") }
                    guard fields[0] == "160000", fields[2] == "0" else { continue }
                    let path = String(entry[entry.index(after: tab)...])
                    guard try context.exists(path + "/.git") else {
                        findings.append(CheckSupport.finding(context, "git.checkoutIntegrity", path, "Submodule checkout missing",
                            "The index records a submodule at \(path), but its checkout has no .git metadata.", .git, "shippingbox"))
                        continue
                    }
                    // Constrain -C to the repository and verify it really is this checkout.
                    _ = try context.localTargetExists(path)
                    let top = try text(context, ["-C", path, "rev-parse", "--show-toplevel"])
                    let expected = context.snapshot.url.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath().path
                    guard URL(fileURLWithPath: top).standardizedFileURL.resolvingSymlinksInPath().path == expected else {
                        throw RepairError.blocked("Submodule metadata does not identify its checkout.")
                    }
                    let head = try text(context, ["-C", path, "rev-parse", "--verify", "HEAD"])
                    if head != fields[1] {
                        findings.append(CheckSupport.finding(context, "git.checkoutIntegrity", path, "Submodule commit differs",
                            "\(path) is checked out at \(head.prefix(12)); the index records \(fields[1].prefix(12)). Review intentional submodule updates.", .git, "shippingbox", severity: .information))
                    }
                }
                let paths = try context.trackedPaths()
                guard !paths.isEmpty else { return findings }
                let attributes = try text(context, ["check-attr", "-z", "filter", "--"] + paths)
                    .split(separator: "\0").map(String.init)
                guard attributes.count % 3 == 0 else { throw RepairError.blocked("Invalid Git attribute response.") }
                for offset in stride(from: 0, to: attributes.count, by: 3) where attributes[offset + 2] == "lfs" {
                    let path = attributes[offset]
                    guard let size = try context.regularFileSize(path), size <= 1024 else { continue }
                    if let source = try context.trackedText(path), isLFSPointer(source) {
                        findings.append(CheckSupport.finding(context, "git.checkoutIntegrity", path, "LFS content is not materialized",
                            "\(path) has filter=lfs and contains an LFS pointer instead of file content. Confirm whether a pointer-only checkout is intentional.", .git, "shippingbox"))
                    }
                }
                return findings
            })
        ]
    }
    private struct Branch { let ref: String; let upstream: String; let tracking: String; var name: String { String(ref.dropFirst("refs/heads/".count)) } }
    private static func branches(_ context: RepositoryInspectionContext) throws -> [Branch] {
        let output = try text(context, ["for-each-ref", "--format=%(refname)%09%(upstream)%09%(upstream:track)", "refs/heads"])
        let lines = output.split(separator: "\n")
        guard lines.count <= 64 else { throw RepairError.blocked("More than 64 local branches need inspection.") }
        return try lines.map { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0].hasPrefix("refs/heads/") else { throw RepairError.blocked("Invalid Git branch metadata.") }
            return Branch(ref: String(parts[0]), upstream: String(parts[1]), tracking: String(parts[2]))
        }
    }
    private static func requireRemoteState(_ context: RepositoryInspectionContext) throws {
        if context.snapshot.fetchError != nil { throw RepairError.blocked("Remote fetch failed; branch publication and upstream state cannot be verified.") }
    }
    private static func hasRemote(_ context: RepositoryInspectionContext) throws -> Bool { !(try text(context, ["remote"])).isEmpty }
    private static func text(_ context: RepositoryInspectionContext, _ args: [String], codes: Set<Int32> = [0]) throws -> String {
        let data = try context.gitRead(args, successfulExitCodes: codes)
        guard let value = String(data: data, encoding: .utf8) else { throw RepairError.blocked("Git metadata is not UTF-8.") }
        // Preserve tab delimiters, including an empty final upstream field.
        return value.trimmingCharacters(in: .newlines)
    }
    static func isLFSPointer(_ source: String) -> Bool {
        CheckSupport.matches(source, #"\Aversion https://git-lfs.github.com/spec/v1\r?\noid sha256:[a-f0-9]{64}\r?\nsize [0-9]+(?:\r?\n)?\z"#)
    }
}
