import Foundation
import XCTest
@testable import RepoManCore

final class RepositoryHealthChecksTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RepoManHealth-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-b", "main"])
        try git(["config", "user.name", "Test"])
        try git(["config", "user.email", "test@example.com"])
        try git(["commit", "--allow-empty", "-m", "Initial"])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testAllTenDetectorsAndRecipesAreRegistered() {
        let checks = RepositoryGitHealthChecks.checks() + RepositoryContentChecks.checks() + RepositoryLockfileChecks.checks()
            + RepositoryRuntimeChecks.checks() + RepositoryWorkflowSecurityChecks.checks() + RepositoryProjectReferenceChecks.checks()
        XCTAssertEqual(checks.count, 10)
        XCTAssertEqual(Set(checks.map(\.id)).count, 10)
        for check in checks {
            XCTAssertTrue(RepositoryIssueCatalog().checks.contains { $0.id == check.id })
            XCTAssertTrue(RepairRecipeCatalog().recipes.contains { $0.id == check.id })
        }
    }
    func testUnpublishedBranchesUsesEveryRemoteAndSkipsActiveBranch() async throws {
        try remote()
        try git(["branch", "published"])
        try git(["branch", "forgotten"])
        try write("change.txt", "work")
        try git(["add", "change.txt"])
        try git(["commit", "-m", "Unpublished"])
        let commit = try gitText(["rev-parse", "HEAD"])
        try git(["update-ref", "refs/heads/forgotten", commit])
        let before = try await inspect("git.unpublishedBranches")
        XCTAssertEqual(before.findings().map(\.subject), ["refs/heads/forgotten"])
        let finding = try XCTUnwrap(before.findings().first)
        try git(["update-ref", "refs/remotes/another/published", commit])
        let after = try await inspect("git.unpublishedBranches")
        XCTAssertTrue(after.findings().isEmpty)
        if case .absent = catalog("git.unpublishedBranches").verify(finding, in: after) {} else { XCTFail("Publication was not verified") }
    }
    func testFailedRemoteFetchCannotResolveBranchFindings() async throws {
        try remote()
        var snapshot = try snapshot()
        snapshot.fetchError = "offline"
        for id in ["git.unpublishedBranches", "git.upstream"] {
            let report = await catalog(id).inspect(snapshot)
            XCTAssertNotNil(report.unavailableChecks[id])
            let finding = RepositoryFinding(repositoryID: snapshot.id, checkID: id, subject: "refs/heads/main", title: "Old", evidence: "Old", category: .git, symbol: "doc")
            if case .unknown = catalog(id).verify(finding, in: report) {} else { XCTFail("Failed fetch resolved finding") }
        }
    }
    func testMissingAndGoneUpstreamHaveStableBranchSubjects() async throws {
        try remote()
        let missing = try await inspect("git.upstream")
        XCTAssertEqual(missing.findings().first?.title, "Missing upstream")
        try git(["config", "branch.main.remote", "origin"])
        try git(["config", "branch.main.merge", "refs/heads/main"])
        let healthy = try await inspect("git.upstream")
        XCTAssertTrue(healthy.findings().isEmpty)
        try git(["update-ref", "-d", "refs/remotes/origin/main"])
        let gone = try await inspect("git.upstream")
        XCTAssertEqual(gone.findings().first?.subject, missing.findings().first?.subject)
        XCTAssertEqual(gone.findings().first?.title, "Configured upstream is missing")
    }
    func testOfflineRepositoriesAreNotFlaggedForUpstream() async throws {
        let report = try await inspect("git.upstream")
        XCTAssertTrue(report.findings().isEmpty)
        XCTAssertTrue(report.unavailableChecks.isEmpty)
    }
    func testRefreshFetchesAllRemotesAndPrunesOnlyTrackingRefs() throws {
        let first = root.appendingPathComponent("first.git"), second = root.appendingPathComponent("second.git")
        try git(["init", "--bare", first.path])
        try git(["init", "--bare", second.path])
        try git(["remote", "add", "first", first.path])
        try git(["remote", "add", "second", second.path])
        try git(["push", "first", "main:main", "main:obsolete"])
        try git(["push", "second", "main:other"])
        // A hostile/mirror-style configured refmap must not overwrite local branch refs.
        try git(["config", "remote.first.fetch", "+refs/heads/*:refs/heads/*"])
        try git(["branch", "obsolete"])
        try git(["tag", "local-tag"])
        let branchRefs = try gitText(["for-each-ref", "--format=%(refname) %(objectname)", "refs/heads", "refs/tags"])
        try write("uncommitted.txt", "Preserve me")
        let status = try gitText(["status", "--porcelain"])
        try GitRepositoryScanner.fetch(root)
        XCTAssertFalse(try gitText(["rev-parse", "refs/remotes/first/main"]).isEmpty)
        XCTAssertFalse(try gitText(["rev-parse", "refs/remotes/second/other"]).isEmpty)
        try git(["--git-dir", first.path, "update-ref", "-d", "refs/heads/obsolete"])
        try GitRepositoryScanner.fetch(root)
        let tracking = try gitText(["for-each-ref", "--format=%(refname)", "refs/remotes"])
        XCTAssertFalse(tracking.contains("refs/remotes/first/obsolete"))
        XCTAssertEqual(branchRefs, try gitText(["for-each-ref", "--format=%(refname) %(objectname)", "refs/heads", "refs/tags"]))
        XCTAssertEqual(status, try gitText(["status", "--porcelain"]))
        XCTAssertEqual(try GitRepositoryScanner.scan(root, includeDetails: false).remoteURL, first.path)
    }
    func testSecretsAreRedactedAndResolutionDoesNotExecuteFiles() async throws {
        let token = "ghp_" + String(repeating: "a", count: 36)
        try write("config.py", "token = '\(token)'\n")
        try write("script.sh", "touch should-never-exist")
        try git(["add", "."])
        let status = try gitText(["status", "--porcelain"])
        let before = try await inspect("files.secrets")
        let finding = try XCTUnwrap(before.findings().first)
        XCTAssertEqual(finding.subject, "config.py")
        XCTAssertTrue(finding.evidence.contains("line 1"))
        XCTAssertFalse(finding.evidence.contains(token))
        XCTAssertFalse(finding.evidence.contains(String(token.prefix(10))))
        XCTAssertEqual(status, try gitText(["status", "--porcelain"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("should-never-exist").path))
        try write("config.py", "token = os.environ['TOKEN']")
        let after = try await inspect("files.secrets")
        if case .absent = catalog("files.secrets").verify(finding, in: after) {} else { XCTFail("Removal was not verified") }
    }
    func testPrivateKeyAndBinaryScope() async throws {
        try write("key.pem", "-----BEGIN OPENSSH PRIVATE KEY-----\nfixture\n-----END OPENSSH PRIVATE KEY-----")
        try write("example.swift", "let header = \"-----BEGIN PRIVATE KEY-----\"")
        try Data([0, 255, 0, 1]).write(to: root.appendingPathComponent("asset.bin"))
        try git(["add", "."])
        let report = try await inspect("files.secrets")
        XCTAssertEqual(report.findings().map(\.subject), ["key.pem"])
        XCTAssertTrue(report.unavailableChecks.isEmpty)
    }
    func testCompiledSecretPatternsPreserveUnicodeLineNumbersAndRedaction() async throws {
        let lines = [
            "ordinary text 😀",
            "\t-----BEGIN RSA PRIVATE KEY-----  ",
            "😀 ghp_" + String(repeating: "a", count: 36),
            "AWS: AKIA" + String(repeating: "A", count: 16),
            "Slack: xoxb-" + String(repeating: "1", count: 10) + "-" + String(repeating: "2", count: 10) + "-" + String(repeating: "a", count: 20),
            "Stripe: sk_live_" + String(repeating: "a", count: 24),
            "HF: hf_" + String(repeating: "a", count: 34)
        ]
        try write("config.txt", lines.joined(separator: "\n"))
        try git(["add", "config.txt"])
        let report = try await inspect("files.secrets")
        let finding = try XCTUnwrap(report.findings().first)
        for (kind, line) in [("Private key", 2), ("GitHub token", 3), ("AWS access key ID", 4),
                             ("Slack token", 5), ("Stripe live secret", 6), ("Hugging Face token", 7)] {
            XCTAssertTrue(finding.evidence.contains("\(kind) at line \(line)"))
        }
        XCTAssertFalse(finding.evidence.contains(String(repeating: "a", count: 20)))
        XCTAssertTrue(report.unavailableChecks.isEmpty)
    }
    func testOversizedTextAndEscapingSymlinksStayUnavailable() async throws {
        try write("big.txt", String(repeating: "x", count: 1_048_577))
        try git(["add", "."])
        for id in ["files.secrets", "files.mergeMarkers"] { let report = try await inspect(id); XCTAssertNotNil(report.unavailableChecks[id]) }
        try git(["rm", "--cached", "big.txt"])
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("escape.txt").path, withDestinationPath: "/etc/hosts")
        try git(["add", "escape.txt"])
        let report = try await inspect("files.secrets")
        XCTAssertNotNil(report.unavailableChecks["files.secrets"])
    }
    func testUnreadableTextCannotResolveAnExistingSecret() async throws {
        try write("key.pem", "-----BEGIN PRIVATE KEY-----\nsecret\n")
        try git(["add", "key.pem"])
        let before = try await inspect("files.secrets")
        let finding = try XCTUnwrap(before.findings().first)
        try Data([0, 255]).write(to: root.appendingPathComponent("key.pem"))
        let after = try await inspect("files.secrets")
        if case .unknown = catalog("files.secrets").verify(finding, in: after) {} else { XCTFail("Binary text resolved secret finding") }
    }
    func testFileThresholdAndReasonedException() async throws {
        try write("asset.dat", String(repeating: "x", count: 2048))
        try write(".repoman.json", #"{"version":1,"maximumTrackedFileBytes":1024}"#)
        try git(["add", "asset.dat"])
        let before = try await inspect("files.oversized")
        XCTAssertEqual(before.findings().map(\.subject), ["asset.dat"])
        try write(".repoman.json", #"{"version":1,"maximumTrackedFileBytes":1024,"exceptions":{"files.oversized":{"asset.dat":"Intentional fixture"}}}"#)
        let after = try await inspect("files.oversized")
        XCTAssertTrue(after.findings().isEmpty)
        try write(".repoman.json", #"{"maximumTrackedFileBytes":0}"#)
        let invalid = try await inspect("files.oversized")
        XCTAssertNotNil(invalid.unavailableChecks["files.oversized"])
    }
    func testCompleteMergeMarkersAndDocumentationExamples() async throws {
        let conflict = "<<<<<<< HEAD\nlet x = 1\n||||||| base\nlet x = 0\n=======\nlet x = 2\n>>>>>>> feature\n"
        try write("code.swift", conflict)
        try write("docs/example.md", conflict)
        try write("divider.txt", "=======\nordinary divider\n")
        try git(["add", "."])
        let report = try await inspect("files.mergeMarkers")
        XCTAssertEqual(report.findings().map(\.subject), ["code.swift"])
        XCTAssertTrue(report.findings().first?.evidence.contains("lines 1") == true)
    }
    func testMissingAndUnexpectedSubmoduleCheckout() async throws {
        let commit = try gitText(["rev-parse", "HEAD"])
        try git(["update-index", "--add", "--cacheinfo", "160000,\(commit),module"])
        let missing = try await inspect("git.checkoutIntegrity")
        XCTAssertEqual(missing.findings().first?.title, "Submodule checkout missing")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("module"), withIntermediateDirectories: true)
        try git(["-C", "module", "init", "-b", "main"])
        try git(["-C", "module", "config", "user.name", "Test"])
        try git(["-C", "module", "config", "user.email", "test@example.com"])
        try git(["-C", "module", "commit", "--allow-empty", "-m", "Different commit"])
        let mismatch = try await inspect("git.checkoutIntegrity")
        XCTAssertEqual(mismatch.findings().first?.title, "Submodule commit differs")
        let moduleHead = try gitText(["-C", "module", "rev-parse", "HEAD"])
        try git(["update-index", "--cacheinfo", "160000,\(moduleHead),module"])
        let healthy = try await inspect("git.checkoutIntegrity")
        XCTAssertTrue(healthy.findings().isEmpty)
        XCTAssertTrue(healthy.unavailableChecks.isEmpty)
    }
    func testLFSPointersOnlyFlagPathsWithLFSAttributes() async throws {
        let pointer = "version https://git-lfs.github.com/spec/v1\noid sha256:" + String(repeating: "a", count: 64) + "\nsize 999\n"
        try write(".gitattributes", "*.dat filter=lfs diff=lfs merge=lfs -text\n")
        try write("asset.dat", pointer)
        try write("example.txt", pointer)
        try git(["-c", "filter.lfs.process=", "-c", "filter.lfs.clean=cat", "-c", "filter.lfs.required=false", "add", "."])
        let report = try await inspect("git.checkoutIntegrity")
        XCTAssertEqual(report.findings().map(\.subject), ["asset.dat"])
        XCTAssertTrue(report.unavailableChecks.isEmpty)
        try write("asset.dat", "materialized data")
        let after = try await inspect("git.checkoutIntegrity")
        XCTAssertTrue(after.findings().isEmpty)
    }
    func testNPMLockDriftIncludingWorkspaceAndRedactedSources() async throws {
        try write("package.json", #"{"packageManager":"npm@10.0.0","workspaces":["packages/*"],"dependencies":{"a":"^2"}}"#)
        try write("packages/app/package.json", #"{"dependencies":{"b":"^1"}}"#)
        try write("package-lock.json", #"{"lockfileVersion":3,"packages":{"":{"dependencies":{"a":"^1"}},"packages/app":{"dependencies":{"b":"^1"}}}}"#)
        try git(["add", "."])
        let before = try await inspect("dependencies.lockfileDrift")
        XCTAssertEqual(before.findings().map(\.subject), ["package.json"])
        try write("package.json", #"{"packageManager":"npm@10.0.0","workspaces":["packages/*"],"dependencies":{"a":"^1"}}"#)
        let after = try await inspect("dependencies.lockfileDrift")
        XCTAssertTrue(after.findings().isEmpty)
        XCTAssertTrue(after.unavailableChecks.isEmpty)
    }
    func testPNPMSpecifierDriftAndCatalogsStayUnknown() async throws {
        try write("package.json", #"{"packageManager":"pnpm@10.0.0","dependencies":{"a":"^2"}}"#)
        try write("pnpm-lock.yaml", "lockfileVersion: '9.0'\nimporters:\n  .:\n    dependencies:\n      a:\n        specifier: ^1\n        version: 1.0.0\n")
        let before = try await inspect("dependencies.lockfileDrift")
        XCTAssertEqual(before.findings().count, 1)
        try write("package.json", #"{"packageManager":"pnpm@10.0.0","dependencies":{"a":"^1"}}"#)
        let after = try await inspect("dependencies.lockfileDrift")
        XCTAssertTrue(after.findings().isEmpty)
        XCTAssertTrue(after.unavailableChecks.isEmpty)
        try write("package.json", #"{"packageManager":"pnpm@10.0.0","dependencies":{"a":"catalog:"}}"#)
        let unsupported = try await inspect("dependencies.lockfileDrift")
        XCTAssertNotNil(unsupported.unavailableChecks["dependencies.lockfileDrift"])
    }
    func testBunTextLockfileCommentsWorkspacesAndAllDependencyGroups() async throws {
        let manifest = #"{"packageManager":"bun@1.3.14","workspaces":["packages/*"],"dependencies":{"a":"^1"},"devDependencies":{"b":"latest"},"peerDependencies":{"c":"^5"},"optionalDependencies":{"d":"^2"}}"#
        let lock = """
        {
          // Bun writes trailing commas in text lockfiles.
          "lockfileVersion": 1,
          "configVersion": 1,
          "workspaces": {
            "": {
              "dependencies": {"a": "^1",},
              "devDependencies": {"b": "latest",},
              "peerDependencies": {"c": "^5",},
              "optionalDependencies": {"d": "^2",},
            },
            /* Workspace paths are relative to the lockfile directory. */
            "packages/app": {"dependencies": {"local": "workspace:*",},},
          },
          "packages": {},
        }
        """
        try write("package.json", manifest)
        try write("packages/app/package.json", #"{"dependencies":{"local":"workspace:*"}}"#)
        try write("bun.lock", lock)
        try git(["add", "."])
        let status = try gitText(["status", "--porcelain"])
        for version in [0, 1] {
            try write("bun.lock", lock.replacingOccurrences(of: "\"lockfileVersion\": 1", with: "\"lockfileVersion\": \(version)"))
            let healthy = try await inspect("dependencies.lockfileDrift")
            XCTAssertTrue(healthy.findings().isEmpty)
            XCTAssertTrue(healthy.unavailableChecks.isEmpty)
        }
        try write("bun.lock", lock)
        for (group, name, version) in [("dependencies", "a", "^1"), ("devDependencies", "b", "latest"),
                                       ("peerDependencies", "c", "^5"), ("optionalDependencies", "d", "^2")] {
            try write("package.json", manifest.replacingOccurrences(of: "\"\(name)\":\"\(version)\"", with: "\"\(name)\":\"changed\""))
            let drift = try await inspect("dependencies.lockfileDrift")
            XCTAssertTrue(drift.unavailableChecks.isEmpty)
            XCTAssertEqual(drift.findings().map(\.subject), ["package.json"])
            XCTAssertTrue(drift.findings().first?.evidence.contains("\(group).\(name)") == true)
        }
        try write("package.json", manifest)
        try write("packages/app/package.json", #"{"dependencies":{"local":"workspace:^"}}"#)
        let workspaceDrift = try await inspect("dependencies.lockfileDrift")
        XCTAssertEqual(workspaceDrift.findings().map(\.subject), ["packages/app/package.json"])
        try write("packages/app/package.json", #"{"dependencies":{"local":"workspace:*"}}"#)
        XCTAssertEqual(status, try gitText(["status", "--porcelain"]))
        XCTAssertEqual(lock, try String(contentsOf: root.appendingPathComponent("bun.lock"), encoding: .utf8))
    }
    func testBunJSONCDoesNotDamageStringsOrExposeDependencyValues() async throws {
        let url = "https://user:secret@example.com/a,b/*file*/#v1"
        let manifest: [String: Any] = ["packageManager": "bun@1.3.14", "dependencies": ["remote": url]]
        let lock: [String: Any] = ["lockfileVersion": 1, "workspaces": ["": ["dependencies": ["remote": url]]], "packages": [:]]
        try write("package.json", String(decoding: JSONSerialization.data(withJSONObject: manifest), as: UTF8.self))
        try write("bun.lock", "/*comment*/" + String(decoding: JSONSerialization.data(withJSONObject: lock), as: UTF8.self) + "//end")
        let healthy = try await inspect("dependencies.lockfileDrift")
        XCTAssertTrue(healthy.findings().isEmpty)
        XCTAssertTrue(healthy.unavailableChecks.isEmpty)
        try write("package.json", #"{"packageManager":"bun@1.3.14","dependencies":{"remote":"^2"}}"#)
        let drift = try await inspect("dependencies.lockfileDrift")
        let finding = try XCTUnwrap(drift.findings().first)
        XCTAssertTrue(finding.evidence.contains("dependencies.remote"))
        XCTAssertFalse(finding.evidence.contains("secret"))
        XCTAssertFalse(finding.evidence.contains(url))
        try write("package.json", #"{"packageManager":"bun@1.3.14"}"#)
        let removed = try await inspect("dependencies.lockfileDrift")
        XCTAssertEqual(removed.findings().count, 1)
        try write("bun.lock", #"{"lockfileVersion":1,"workspaces":{"":{}},"packages":{}}"#)
        let resolved = try await inspect("dependencies.lockfileDrift")
        if case .absent = catalog("dependencies.lockfileDrift").verify(finding, in: resolved) {} else { XCTFail("Synchronized Bun lockfile did not resolve drift") }
    }
    func testUnsupportedOrMalformedBunLocksCannotResolveDrift() async throws {
        try write("package.json", #"{"packageManager":"bun@1.3.14","dependencies":{"a":"^2"}}"#)
        try write("bun.lock", #"{"lockfileVersion":1,"workspaces":{"":{"dependencies":{"a":"^1"}}},"packages":{}}"#)
        let before = try await inspect("dependencies.lockfileDrift")
        let finding = try XCTUnwrap(before.findings().first)
        for source in [
            #"{"lockfileVersion":99,"workspaces":{"":{}},"packages":{}}"#,
            #"{"lockfileVersion":1,"configVersion":99,"workspaces":{"":{}},"packages":{}}"#,
            #"{"lockfileVersion":1,"workspaces":{"":{"dependencies":{"a":2}}},"packages":{}}"#,
            #"{"lockfileVersion":1,"workspaces":{"":{}},"packages":{}} /*unfinished"#,
            #"{"lockfileVersion":1,"workspaces":{"":{}},"packages":{},"#,
            #"{"lockfileVersion":1,"workspaces":{"":{}}}"#
        ] {
            try write("bun.lock", source)
            let report = try await inspect("dependencies.lockfileDrift")
            XCTAssertTrue(report.findings().isEmpty)
            XCTAssertNotNil(report.unavailableChecks["dependencies.lockfileDrift"])
            if case .unknown = catalog("dependencies.lockfileDrift").verify(finding, in: report) {} else { XCTFail("Malformed Bun lockfile resolved drift") }
        }
        try FileManager.default.removeItem(at: root.appendingPathComponent("bun.lock"))
        try write("bun.lockb", "binary fixture")
        let binary = try await inspect("dependencies.lockfileDrift")
        XCTAssertTrue(binary.unavailableChecks["dependencies.lockfileDrift"]?.contains("Binary bun.lockb") == true)
        try write("bun.lock", #"{"lockfileVersion":1,"workspaces":{"":{"dependencies":{"a":"^2"}}},"packages":{}}"#)
        let textPreferred = try await inspect("dependencies.lockfileDrift")
        XCTAssertTrue(textPreferred.findings().isEmpty)
        XCTAssertTrue(textPreferred.unavailableChecks.isEmpty)
        try write("package.json", #"{"packageManager":"bun@1.3.14","dependencies":{"a":"catalog:"}}"#)
        let catalog = try await inspect("dependencies.lockfileDrift")
        XCTAssertNotNil(catalog.unavailableChecks["dependencies.lockfileDrift"])
        try write("package.json", #"{"packageManager":"bun@1.3.14"}"#)
        try write("bun.lock", #"{"lockfileVersion":1,"workspaces":{},"packages":{}}"#)
        let missing = try await inspect("dependencies.lockfileDrift")
        XCTAssertTrue(missing.findings().first?.evidence.contains("workspace package metadata is missing") == true)
    }
    func testUVMetadataDriftAndSpecifierNormalization() async throws {
        try write("pyproject.toml", "[project]\nname = 'app'\nrequires-python = '>=3.12'\ndependencies = ['some_package >=1, <2']\n")
        try write("uv.lock", """
        version = 1
        requires-python = ">=3.12"
        [[package]]
        name = "app"
        version = "0.1.0"
        source = { virtual = "." }
        [package.metadata]
        requires-dist = [{ name = "some-package", specifier = "<2,>=1" }]
        """)
        let healthy = try await inspect("dependencies.lockfileDrift")
        XCTAssertTrue(healthy.findings().isEmpty)
        XCTAssertTrue(healthy.unavailableChecks.isEmpty)
        try write("pyproject.toml", "[project]\nname = 'app'\ndependencies = ['some-package>=2']\n")
        let drift = try await inspect("dependencies.lockfileDrift")
        XCTAssertEqual(drift.findings().count, 1)
        try write("pyproject.toml", "[project]\nname = 'app'\ndependencies = ['some-package[extra]>=2']\n")
        let extraDrift = try await inspect("dependencies.lockfileDrift")
        XCTAssertEqual(extraDrift.findings().count, 1)
        XCTAssertTrue(extraDrift.unavailableChecks.isEmpty)
        try write("pyproject.toml", "[project]\nname = 'app'\ndependencies = [\"some-package>=2; python_version < '3.13'\"]\n")
        let unsupported = try await inspect("dependencies.lockfileDrift")
        XCTAssertNotNil(unsupported.unavailableChecks["dependencies.lockfileDrift"])
    }
    func testUVOptionalDependenciesAndRequestedExtras() async throws {
        let project = """
        [project]
        name = "agentbridge-cli"
        dependencies = ["uvicorn[standard]>=0.32.0", "fastapi>=0.141.1"]
        [project.optional-dependencies]
        test = ["pytest>=9.1.1", "ruff>=0.15.0"]
        """
        let lock = """
        version = 1
        [[package]]
        name = "agentbridge-cli"
        source = { editable = "." }
        [package.metadata]
        requires-dist = [
            { name = "fastapi", specifier = ">=0.141.1" },
            { name = "pytest", marker = "extra == 'test'", specifier = ">=9.1.1" },
            { name = "ruff", marker = "extra == 'test'", specifier = ">=0.15.0" },
            { name = "uvicorn", extras = ["standard"], specifier = ">=0.32.0" },
        ]
        provides-extras = ["test"]
        """
        try write("pyproject.toml", project)
        try write("uv.lock", lock)
        let healthy = try await inspect("dependencies.lockfileDrift")
        XCTAssertTrue(healthy.findings().isEmpty)
        XCTAssertTrue(healthy.unavailableChecks.isEmpty)
        // Detect an optional version change, a removed dependency and a changed requested extra.
        for (before, after, evidence) in [
            ("pytest>=9.1.1", "pytest>=10", "optional-dependencies.test.pytest"),
            (", \"ruff>=0.15.0\"", "", "optional-dependencies.test.ruff"),
            ("uvicorn[standard]", "uvicorn[other]", "dependencies.uvicorn")
        ] {
            try write("pyproject.toml", project.replacingOccurrences(of: before, with: after))
            let drift = try await inspect("dependencies.lockfileDrift")
            XCTAssertTrue(drift.unavailableChecks.isEmpty)
            XCTAssertTrue(drift.findings().first?.evidence.contains(evidence) == true)
        }
        try write("pyproject.toml", project)
        for (before, after) in [
            ("extras = [\"standard\"]", "extras = []"),
            ("name = \"pytest\"", "name = \"unexpected\"")
        ] {
            try write("uv.lock", lock.replacingOccurrences(of: before, with: after))
            let drift = try await inspect("dependencies.lockfileDrift")
            XCTAssertTrue(drift.unavailableChecks.isEmpty)
            XCTAssertEqual(drift.findings().count, 1)
        }
    }
    func testUVSharedOptionalRequirementsNormalizationAndEmptyExtras() async throws {
        let project = """
        [project]
        name = "app"
        dependencies = ["some_package[Z_extra,foo.bar] >=1, <2"]
        [project.optional-dependencies]
        Test_Group = ["some-package[foo-bar]>=2"]
        other = ["some-package[foo-bar]>=2"]
        empty = []
        """
        let lock = """
        version = 1
        [[package]]
        name = "app"
        source = { virtual = "." }
        [package.metadata]
        requires-dist = [
            { name = 'some-package', extras = ['foo-bar', 'z-extra'], specifier = '<2,>=1' },
            { name = 'some-package', extras = ['foo-bar'], marker = "extra == 'test-group' or extra == 'other'", specifier = '>=2' },
        ]
        provides-extras = ['empty', 'other', 'test-group']
        """
        try write("pyproject.toml", project)
        try write("uv.lock", lock)
        let healthy = try await inspect("dependencies.lockfileDrift")
        XCTAssertTrue(healthy.findings().isEmpty)
        XCTAssertTrue(healthy.unavailableChecks.isEmpty)
        try write("pyproject.toml", project.replacingOccurrences(of: "empty = []", with: "added = []"))
        let drift = try await inspect("dependencies.lockfileDrift")
        XCTAssertTrue(drift.unavailableChecks.isEmpty)
        let evidence = try XCTUnwrap(drift.findings().first?.evidence)
        XCTAssertTrue(evidence.contains("optional-dependencies.empty"))
        XCTAssertTrue(evidence.contains("optional-dependencies.added"))
    }
    func testUVUnsupportedOrMalformedOptionalMetadataStaysUnknown() async throws {
        let project = "[project]\nname = 'app'\ndependencies = []\n[project.optional-dependencies]\ntest = ['pytest>=9']\n"
        let lock = """
        version = 1
        [[package]]
        name = "app"
        source = { virtual = "." }
        [package.metadata]
        requires-dist = [{ name = "pytest", marker = "extra == 'test'", specifier = ">=9" }]
        provides-extras = ["test"]
        """
        for declaration in [
            "\"pytest>=9; python_version < '3.13'\"",
            "'pytest @ https://example.com/package.whl'",
            "'pytest>=9', 'pytest>=10'",
            "'pytest[bad extra]>=9'",
            "'pytest>=9' 'ruff>=1'"
        ] {
            try write("pyproject.toml", project.replacingOccurrences(of: "'pytest>=9'", with: declaration))
            try write("uv.lock", lock)
            let report = try await inspect("dependencies.lockfileDrift")
            XCTAssertTrue(report.findings().isEmpty)
            XCTAssertNotNil(report.unavailableChecks["dependencies.lockfileDrift"], declaration)
        }
        try write("pyproject.toml", project)
        for (before, after) in [
            ("extra == 'test'", "extra == 'test' and python_version < '3.13'"),
            ("extra == 'test'", "extra == 'missing'"),
            ("name = \"pytest\"", "name = \"pytest\", unknown = \"value\""),
            ("name = \"pytest\"", "name = \"pytest\", name = \"pytest\""),
            ("name = \"pytest\",", "name = \"pytest\""),
            ("specifier = \">=9\"", "specifier = \">=9\", extras = [\"bad extra\"]")
        ] {
            try write("uv.lock", lock.replacingOccurrences(of: before, with: after))
            let report = try await inspect("dependencies.lockfileDrift")
            XCTAssertTrue(report.findings().isEmpty)
            XCTAssertNotNil(report.unavailableChecks["dependencies.lockfileDrift"], after)
        }
        try write("uv.lock", lock)
        for unsupported in [
            "\n[dependency-groups]\ndev = ['ruff']",
            "\n[tool.uv.sources]\npytest = { workspace = true }",
            "\n[tool.uv]\ndev-dependencies = ['ruff']"
        ] {
            try write("pyproject.toml", project + unsupported)
            let report = try await inspect("dependencies.lockfileDrift")
            XCTAssertNotNil(report.unavailableChecks["dependencies.lockfileDrift"])
        }
    }
    func testUnsupportedLockfileCannotResolveEarlierDrift() async throws {
        try write("package.json", #"{"packageManager":"npm@10.0.0","dependencies":{"a":"^2"}}"#)
        try write("package-lock.json", #"{"lockfileVersion":3,"packages":{"":{"dependencies":{"a":"^1"}}}}"#)
        let before = try await inspect("dependencies.lockfileDrift")
        let finding = try XCTUnwrap(before.findings().first)
        try write("package-lock.json", #"{"lockfileVersion":99}"#)
        let report = try await inspect("dependencies.lockfileDrift")
        if case .unknown = catalog("dependencies.lockfileDrift").verify(finding, in: report) {} else { XCTFail("Unsupported schema resolved finding") }
    }
    func testRuntimeRangesContainersAndCI() async throws {
        try write("package.json", #"{"engines":{"node":">=20 <23"}}"#)
        try write(".nvmrc", "20.11.0\n")
        try write("Dockerfile", "FROM node:20-alpine\n")
        try workflow("""
        on: push
        jobs:
          test:
            steps:
              - uses: actions/setup-node@v4
                with:
                  node-version: '18'
        """)
        let mismatch = try await inspect("dependencies.runtime")
        XCTAssertEqual(mismatch.findings().count, 1)
        XCTAssertTrue(mismatch.findings().first?.evidence.contains("ci.yml") == true)
        try workflow("on: push\njobs: {}\n")
        let healthy = try await inspect("dependencies.runtime")
        XCTAssertTrue(healthy.findings().isEmpty)
        XCTAssertTrue(healthy.unavailableChecks.isEmpty)
    }
    func testPythonRangesAndDynamicRuntimeStayUnknown() async throws {
        try write("pyproject.toml", "[project]\nrequires-python = '>=3.10,<3.13'")
        try write(".python-version", "3.12")
        let healthy = try await inspect("dependencies.runtime")
        XCTAssertTrue(healthy.findings().isEmpty)
        XCTAssertTrue(healthy.unavailableChecks.isEmpty)
        try write(".python-version", "3.13")
        let mismatch = try await inspect("dependencies.runtime")
        XCTAssertEqual(mismatch.findings().count, 1)
        try write(".python-version", "system")
        let unknown = try await inspect("dependencies.runtime")
        XCTAssertNotNil(unknown.unavailableChecks["dependencies.runtime"])
    }
    func testIntentionalCIVersionsAreNotComparedAgainstEachOther() async throws {
        try write("package.json", #"{"engines":{"node":">=18 <23"},"volta":{"node":"20.11.0"}}"#)
        try write(".nvmrc", "20")
        try workflow("""
        on: push
        jobs:
          test:
            steps:
              - uses: actions/setup-node@v4
                with:
                  node-version: '18'
              - uses: actions/setup-node@v4
                with:
                  node-version: '22'
        """)
        let report = try await inspect("dependencies.runtime")
        XCTAssertTrue(report.findings().isEmpty)
    }
    func testUnrelatedMultilineActionInputsDoNotDisableNewChecks() async throws {
        try write("package.json", #"{"engines":{"node":">=20"}}"#)
        try workflow("""
        on: push
        jobs:
          test:
            steps:
              - uses: actions/github-script@v7
                with:
                  script: |
                    console.log('example')
              - uses: actions/setup-node@v4
                with:
                  node-version: '20'
        """)
        for id in ["ci.security", "dependencies.runtime", "files.projectReferences"] {
            let report = try await inspect(id)
            XCTAssertTrue(report.findings().isEmpty)
            XCTAssertTrue(report.unavailableChecks.isEmpty, "\(id): \(report.unavailableChecks)")
        }
    }
    func testMalformedRuntimeDeclarationsStayUnknown() async throws {
        try write("package.json", #"{"engines":{"node":20}}"#)
        let report = try await inspect("dependencies.runtime")
        XCTAssertNotNil(report.unavailableChecks["dependencies.runtime"])
    }
    func testWorkflowRisksAndSafeEnvironmentVariables() async throws {
        try workflow("""
        on: pull_request_target
        permissions: write-all
        jobs:
          test:
            steps:
              - uses: actions/checkout@v4
                with:
                  ref: ${{ github.event.pull_request.head.sha }}
              - run: echo '${{ github.event.pull_request.title }}'
        """)
        let risky = try await inspect("ci.security")
        let finding = try XCTUnwrap(risky.findings().first)
        XCTAssertTrue(finding.evidence.contains("write-all"))
        XCTAssertTrue(finding.evidence.contains("untrusted event text"))
        XCTAssertTrue(finding.evidence.contains("contributor's head"))
        try workflow("""
        on: pull_request
        permissions:
          contents: read
        jobs:
          test:
            steps:
              - run: echo "$TITLE"
                env:
                  TITLE: ${{ github.event.pull_request.title }}
              - run: |
                  echo 'permissions: write-all'
        """)
        let safe = try await inspect("ci.security")
        XCTAssertTrue(safe.findings().isEmpty)
        XCTAssertTrue(safe.unavailableChecks.isEmpty)
    }
    func testWorkflowGlobalWritesAndUnsupportedInputs() async throws {
        try workflow("on: push\npermissions: {contents: write}\njobs: {}\n")
        let broad = try await inspect("ci.security")
        XCTAssertEqual(broad.findings().count, 1)
        try workflow("on: push\npermissions: ${{ inputs.permissions }}\njobs: {}\n")
        let dynamic = try await inspect("ci.security")
        XCTAssertNotNil(dynamic.unavailableChecks["ci.security"])
    }
    func testWorkspaceAndEntryPointReferencesSkipGeneratedOutput() async throws {
        try write("package.json", #"{"workspaces":["packages/*","missing"],"main":"dist/index.js","types":"generated/types.d.ts","exports":{".":"./src/index.js"},"scripts":{"test":"node scripts/test.js"}}"#)
        try write("packages/good/package.json", "{}")
        try write("packages/excluded/note.txt", "not a package")
        try write(".gitignore", "generated/\n")
        try git(["add", "."])
        let report = try await inspect("files.projectReferences")
        let evidence = try XCTUnwrap(report.findings().first?.evidence)
        XCTAssertTrue(evidence.contains("missing"))
        XCTAssertTrue(evidence.contains("packages/excluded"))
        XCTAssertTrue(evidence.contains("src/index.js"))
        XCTAssertTrue(evidence.contains("scripts/test.js"))
        XCTAssertFalse(evidence.contains("dist/index.js"))
        XCTAssertFalse(evidence.contains("generated/types.d.ts"))
        XCTAssertFalse(evidence.contains("packages/good"))
    }
    func testUVWorkspaceExclusionsAndNoScriptExecution() async throws {
        try write("pyproject.toml", "[tool.uv.workspace]\nmembers = ['packages/*']\nexclude = ['packages/excluded']\n")
        try write("packages/good/pyproject.toml", "[project]\nname='good'")
        try write("packages/excluded/data.txt", "fixture")
        try git(["add", "."])
        let healthy = try await inspect("files.projectReferences")
        XCTAssertTrue(healthy.findings().isEmpty)
        XCTAssertTrue(healthy.unavailableChecks.isEmpty)
    }
    func testCIReferencesRespectWorkingDirectoryAndIgnoreEchoArguments() async throws {
        try write("project/scripts/check.py", "raise RuntimeError('do not run')")
        try write(".github/actions/local/action.yml", "name: Local")
        try workflow("""
        on: push
        jobs:
          test:
            steps:
              - uses: ./.github/actions/local
              - run: python scripts/check.py
                working-directory: project
              - run: echo scripts/imaginary.py
              - run: node missing.js
        """)
        let report = try await inspect("files.projectReferences")
        XCTAssertEqual(report.findings().count, 1)
        let evidence = try XCTUnwrap(report.findings().first?.evidence)
        XCTAssertTrue(evidence.contains("missing.js"))
        XCTAssertFalse(evidence.contains("check.py"))
        XCTAssertFalse(evidence.contains("imaginary.py"))
        XCTAssertFalse(evidence.contains("action.yml"))
    }
    func testEscapingWorkspaceAndUnsupportedYAMLRemainUnknown() async throws {
        try write("package.json", #"{"workspaces":["../other"]}"#)
        let workspace = try await inspect("files.projectReferences")
        XCTAssertNotNil(workspace.unavailableChecks["files.projectReferences"])
        try workflow("on: push\njobs: &jobs\n  test: {}\n")
        let workflow = try await inspect("ci.security")
        XCTAssertNotNil(workflow.unavailableChecks["ci.security"])
    }
    func testChangingScriptDirectoriesAndDynamicPathsStayUnknown() async throws {
        try write("package.json", #"{"scripts":{"test":"cd project && node script.js"}}"#)
        let directory = try await inspect("files.projectReferences")
        XCTAssertNotNil(directory.unavailableChecks["files.projectReferences"])
        try write("package.json", #"{"scripts":{"test":"node $SCRIPT.js"}}"#)
        let dynamic = try await inspect("files.projectReferences")
        XCTAssertNotNil(dynamic.unavailableChecks["files.projectReferences"])
    }

    private func remote() throws {
        try git(["remote", "add", "origin", "https://example.invalid/project.git"])
        let commit = try gitText(["rev-parse", "HEAD"])
        try git(["update-ref", "refs/remotes/origin/main", commit])
    }
    private func catalog(_ id: String) -> RepositoryIssueCatalog { RepositoryIssueCatalog(checks: RepositoryIssueCatalog.standardChecks.filter { $0.id == id }) }
    private func inspect(_ id: String) async throws -> RepositoryInspectionReport { await catalog(id).inspect(try snapshot()) }
    private func snapshot() throws -> RepositorySnapshot {
        RepositorySnapshot(url: root, name: "test", branch: try gitText(["symbolic-ref", "--short", "HEAD"]), upstream: nil,
            remoteURL: nil, ahead: nil, behind: nil, changes: [], staleBranches: [], worktrees: [], commits: [],
            rootFiles: try FileManager.default.contentsOfDirectory(atPath: root.path))
    }
    private func workflow(_ source: String) throws { try write(".github/workflows/ci.yml", source) }
    private func write(_ path: String, _ source: String) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try source.write(to: file, atomically: true, encoding: .utf8)
    }
    private func git(_ args: [String]) throws { _ = try GitRunner.run(args, at: root) }
    private func gitText(_ args: [String]) throws -> String { try GitRunner.text(args, at: root) }
}
