import Foundation
import XCTest
@testable import RepoManCore

final class RepositoryAdditionalChecksTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RepoManAdditional-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-b", "main"])
        try git(["config", "user.name", "Test"])
        try git(["config", "user.email", "test@example.com"])
        try git(["commit", "--allow-empty", "-m", "Initial"])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testAdditionalChecksHaveRecipesAndUniqueIDs() {
        let additional = RepositoryDependencyChecks.checks() + RepositoryWorkflowChecks.checks() + RepositoryHygieneChecks.checks() + RepositoryMetadataChecks.checks()
        XCTAssertEqual(additional.count, 13)
        XCTAssertEqual(Set(additional.map(\.id)).count, 13)
        let catalog = RepositoryIssueCatalog(), recipes = RepairRecipeCatalog()
        for check in additional {
            XCTAssertTrue(catalog.checks.contains { $0.id == check.id })
            XCTAssertTrue(recipes.recipes.contains { $0.id == check.id })
        }
    }
    func testManagerMismatchIncludesCIAndPreservesSiblingWorkingDirectories() async throws {
        try write("package.json", #"{"packageManager":"pnpm@10.33.0"}"#)
        try write("package-lock.json", "{}")
        try workflow("ci.yml", """
        on: push
        jobs:
          test:
            steps:
              - run: npm ci
              - run: npm install
                working-directory: other-project
              - run: npm install --global pnpm@10.33.0
        """)
        let report = try await inspect("dependencies.manager")
        let finding = try XCTUnwrap(report.findings().first)
        XCTAssertTrue(finding.evidence.contains("package-lock.json"))
        XCTAssertTrue(finding.evidence.contains("ci.yml"))
        XCTAssertFalse(finding.evidence.contains("other-project"))
        XCTAssertTrue(report.unavailableChecks.isEmpty)
    }
    func testLockfileMustBeTrackedAndResolutionIsVerified() async throws {
        try write("pyproject.toml", "[project]\nname = 'example'")
        let catalog = self.catalog("dependencies.lockfile")
        let before = try await catalog.inspect(snapshot())
        let finding = try XCTUnwrap(before.findings().first)
        try write("uv.lock", "version = 1")
        var after = try await catalog.inspect(snapshot())
        XCTAssertTrue(after.findings().first?.evidence.contains("not tracked") == true)
        try git(["add", "uv.lock"])
        after = try await catalog.inspect(snapshot())
        XCTAssertTrue(after.findings().isEmpty)
        if case .absent = catalog.verify(finding, in: after) {} else { XCTFail("Tracked lockfile did not resolve") }
    }
    func testWorkspacePackagesShareParentLockAndManager() async throws {
        try write("package.json", #"{"packageManager":"pnpm@10.33.0"}"#)
        try write("pnpm-lock.yaml", "lockfileVersion: '9.0'")
        try write("packages/client/package.json", #"{"name":"client"}"#)
        try write("pnpm-workspace.yaml", "packages:\n  - packages/*")
        try git(["add", "."])
        let observed1 = try await inspect("dependencies.lockfile").findings().isEmpty
        XCTAssertTrue(observed1)
        let observed2 = try await inspect("dependencies.manager").findings().isEmpty
        XCTAssertTrue(observed2)
    }
    func testUVTomlSupersedesProjectConfigurationAndAcceptsOlderCutoff() async throws {
        try write("pyproject.toml", "[tool.uv]\nexclude-newer = '1 day'")
        try write("uv.toml", """
        exclude-newer = "7 days"
        constraint-dependencies = [
          "mistralai!=2.4.6",
          "guardrails-ai!=0.10.1",
        ]
        """)
        let observed3 = try await inspect("dependencies.safeguards").findings().isEmpty
        XCTAssertTrue(observed3)
        try write("uv.toml", "exclude-newer = '2000-01-01T00:00:00Z'\nconstraint-dependencies = ['mistralai!=2.4.6', 'guardrails-ai!=0.10.1']")
        let observed4 = try await inspect("dependencies.safeguards").findings().isEmpty
        XCTAssertTrue(observed4)
        try write("uv.toml", "exclude-newer = '1 day'")
        let report = try await inspect("dependencies.safeguards")
        XCTAssertTrue(report.findings().first?.evidence.contains("seven days") == true)
    }
    func testPNPMRequiresWorkspaceAndVersionTenCompatibilitySettings() async throws {
        try write("package.json", #"{"packageManager":"pnpm@10.33.0"}"#)
        try write(".npmrc", "minimum-release-age=10080\nblock-exotic-subdeps=true")
        let observed5 = try await inspect("dependencies.safeguards").findings().isEmpty
        XCTAssertFalse(observed5)
        try write("pnpm-workspace.yaml", "minimumReleaseAge: 10080\nblockExoticSubdeps: true\nonlyBuiltDependencies:\n  - esbuild")
        let observed6 = try await inspect("dependencies.safeguards").findings().isEmpty
        XCTAssertTrue(observed6)
    }
    func testPipConstraintsMustExistAndBeTracked() async throws {
        try write("requirements.txt", "-c constraints.txt\npytest==8.4.0")
        let observed7 = try await inspect("dependencies.safeguards").findings().isEmpty
        XCTAssertFalse(observed7)
        try write("constraints.txt", "mistralai!=2.4.6\nguardrails-ai!=0.10.1")
        try git(["add", "constraints.txt"])
        let observed8 = try await inspect("dependencies.safeguards").findings().isEmpty
        XCTAssertTrue(observed8)
    }
    func testBunSafeguardsUseSecondsAndRepositoryOwnedScriptSettings() async throws {
        try write("package.json", #"{"packageManager":"bun@1.3.14"}"#)
        try write(".npmrc", "min-release-age=10080\nignore-scripts=true\n")
        let missing = try await inspect("dependencies.safeguards")
        XCTAssertTrue(missing.unavailableChecks.isEmpty)
        XCTAssertTrue(missing.findings().first?.evidence.contains("604800 seconds") == true)
        try write("bunfig.toml", "[install]\nminimumReleaseAge = 10080\nignoreScripts = true\n")
        let tooYoung = try await inspect("dependencies.safeguards")
        XCTAssertEqual(tooYoung.findings().count, 1)
        try write("bunfig.toml", "[install]\nminimumReleaseAge = 604_800 # seven days\n")
        let healthy = try await inspect("dependencies.safeguards")
        XCTAssertTrue(healthy.findings().isEmpty)
        XCTAssertTrue(healthy.unavailableChecks.isEmpty)
        try write("bunfig.toml", "[install]\nminimumReleaseAge = 604800\nignoreScripts = false\n")
        let enabled = try await inspect("dependencies.safeguards")
        XCTAssertTrue(enabled.findings().first?.evidence.contains("lifecycle scripts") == true)
        try write("bunfig.toml", "[install]\nminimumReleaseAge = 604800\nignoreScripts = true\nminimumReleaseAgeExcludes = ['typescript']\n")
        let exclusions = try await inspect("dependencies.safeguards")
        XCTAssertTrue(exclusions.findings().first?.evidence.contains("minimumReleaseAgeExcludes") == true)
        try write("bunfig.toml", "[install]\nminimumReleaseAge = 604800\nignoreScripts = true\nminimumReleaseAgeExcludes = [\n]\n")
        let emptyExclusions = try await inspect("dependencies.safeguards")
        XCTAssertTrue(emptyExclusions.findings().isEmpty)
    }
    func testBunWorkspaceSafeguardsDoNotLeakIntoIndependentProjects() async throws {
        try write("package.json", #"{"packageManager":"bun@1.3.14","workspaces":["packages/*"]}"#)
        try write("bun.lock", "{}")
        try write("bunfig.toml", "[install]\nminimumReleaseAge = 604800\nignoreScripts = true\n")
        try write("packages/client/package.json", #"{"name":"client"}"#)
        try write("standalone/package.json", #"{"packageManager":"bun@1.3.14"}"#)
        try git(["add", "."])
        let report = try await inspect("dependencies.safeguards")
        XCTAssertTrue(report.unavailableChecks.isEmpty)
        XCTAssertEqual(report.findings().map(\.subject), ["standalone/package.json"])
        // A workspace member with its own lockfile is inspected as an independent install.
        try write("packages/client/bun.lock", "{}")
        let independent = try await inspect("dependencies.safeguards")
        XCTAssertEqual(Set(independent.findings().map(\.subject)), ["packages/client/package.json", "standalone/package.json"])
    }
    func testBunCIOverridesAreCheckedInSeconds() async throws {
        try write("package.json", #"{"packageManager":"bun@1.3.14"}"#)
        try write("bunfig.toml", "[install]\nminimumReleaseAge = 604800\nignoreScripts = true\n")
        try workflow("ci.yml", "on: push\njobs:\n  test:\n    steps:\n      - run: bun install --minimum-release-age=10080\n")
        let unsafe = try await inspect("dependencies.safeguards")
        XCTAssertTrue(unsafe.findings().first?.evidence.contains("Bun dependency age") == true)
        try workflow("ci.yml", "on: push\njobs:\n  test:\n    steps:\n      - run: bun ci --minimum-release-age 604800 --ignore-scripts\n")
        let safe = try await inspect("dependencies.safeguards")
        XCTAssertTrue(safe.findings().isEmpty)
        XCTAssertTrue(safe.unavailableChecks.isEmpty)
    }
    func testMalformedBunConfigurationStaysUnknown() async throws {
        try write("package.json", #"{"packageManager":"bun@1.3.14"}"#)
        for value in ["[", "_604800", "604__800", "'604800'"] {
            try write("bunfig.toml", "[install]\nminimumReleaseAge = \(value)\n")
            let report = try await inspect("dependencies.safeguards")
            XCTAssertTrue(report.findings().isEmpty)
            XCTAssertNotNil(report.unavailableChecks["dependencies.safeguards"])
        }
    }
    func testSourcesReviewDirectDependenciesButAllowWorkspaceReferences() async throws {
        try write("package.json", #"{"dependencies":{"local":"workspace:*","remote":"git+https://example.com/repo.git"}}"#)
        let report = try await inspect("dependencies.sources")
        XCTAssertTrue(report.findings().first?.evidence.contains("remote") == true)
        XCTAssertFalse(report.findings().first?.evidence.contains("dependencies.local") == true)
        try write("package.json", #"{"dependencies":{"local":"workspace:*"}}"#)
        let observed9 = try await inspect("dependencies.sources").findings().isEmpty
        XCTAssertTrue(observed9)
        try write("pyproject.toml", "[project.optional-dependencies]\ntest = ['custom @ https://example.com/test.whl']\n[tool.uv.sources]\nlocal = { workspace = true }")
        let py = try await inspect("dependencies.sources")
        XCTAssertTrue(py.findings().first?.evidence.contains("optional-dependencies") == true)
        XCTAssertFalse(py.findings().first?.evidence.contains("tool.uv.sources.local") == true)
    }
    func testMutableActionsIncludeReusableJobsAndIgnoreShellText() async throws {
        try workflow("ci.yml", """
        on: push
        jobs:
          call:
            uses: owner/repo/.github/workflows/check.yml@main
          test:
            steps:
              - uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
              - uses: ./local-action
              - run: |
                  echo hello
                  uses: fake/action@v1
        """)
        let report = try await inspect("ci.mutableActions")
        let finding = try XCTUnwrap(report.findings().first)
        XCTAssertTrue(finding.evidence.contains("owner/repo"))
        XCTAssertFalse(finding.evidence.contains("fake/action"))
        XCTAssertFalse(finding.evidence.contains("checkout"))
    }
    func testFailureSuppressionOnlyReportsExecutableValidation() async throws {
        try workflow("ci.yml", """
        on: push
        jobs:
          tests:
            continue-on-error: true
            steps:
              - name: Optional tests
                run: uv run pytest
          diagnostics:
            steps:
              - run: echo 'npm test' || true
              - run: curl https://example.com || true
        """)
        let report = try await inspect("ci.suppressedFailures")
        XCTAssertTrue(report.findings().first?.evidence.contains("Optional tests") == true)
        XCTAssertFalse(report.findings().first?.evidence.contains("diagnostics") == true)
        try workflow("ci.yml", "on: push\njobs:\n  tests:\n    steps:\n      - run: npm test || true")
        let observed10 = try await inspect("ci.suppressedFailures").findings().isEmpty
        XCTAssertFalse(observed10)
    }
    func testUnsupportedWorkflowCannotVerifyEarlierFindingAsResolved() async throws {
        try workflow("ci.yml", "on: push\njobs:\n  tests:\n    steps:\n      - uses: actions/checkout@v4")
        let catalog = self.catalog("ci.mutableActions")
        let before = try await catalog.inspect(snapshot())
        let finding = try XCTUnwrap(before.findings().first)
        try workflow("ci.yml", "on: push\njobs: {tests: {steps: [{uses: actions/checkout@v4}]}}")
        let after = try await catalog.inspect(snapshot())
        XCTAssertNotNil(after.unavailableChecks["ci.mutableActions"])
        if case .unknown = catalog.verify(finding, in: after) {} else { XCTFail("Unsupported YAML resolved finding") }
    }
    func testGeneratedTrackingAndPolicyExceptionsHaveStableSubjects() async throws {
        try write("__pycache__/module.pyc", "cache")
        try write(".gitignore", "__pycache__/\n")
        try git(["add", "-f", "__pycache__/module.pyc"])
        let before = try await inspect("files.generatedTracked")
        XCTAssertEqual(before.findings().first?.subject, "__pycache__/module.pyc")
        try write(".repoman.json", #"{"exceptions":{"files.generatedTracked":{"__pycache__/module.pyc":"Intentional binary fixture"}}}"#)
        let observed11 = try await inspect("files.generatedTracked").findings().isEmpty
        XCTAssertTrue(observed11)
        try write(".repoman.json", #"{"exceptions":{"files.generatedTracked":{"__pycache__/module.pyc":""}}}"#)
        let observed12 = try await inspect("files.generatedTracked").unavailableChecks["files.generatedTracked"]
        XCTAssertNotNil(observed12)
    }
    func testOldStashesUseCommitIdentityAndDoNotModifyRepository() async throws {
        try write("tracked.txt", "initial")
        try git(["add", "tracked.txt"]); try git(["commit", "-m", "Tracked"])
        try write("tracked.txt", "changes")
        try git(["stash", "push", "-m", "Keep this"])
        let listBefore = try GitRunner.run(["stash", "list"], at: root)
        let context = try snapshot(checkedAt: Date().addingTimeInterval(35 * 86_400))
        let report = await catalog("git.oldStashes").inspect(context)
        let finding = try XCTUnwrap(report.findings().first)
        XCTAssertTrue(finding.evidence.contains("tracked.txt"))
        XCTAssertEqual(finding.subject.count, 40)
        XCTAssertEqual(try GitRunner.run(["stash", "list"], at: root), listBefore)
        let observed13 = try await inspect("git.oldStashes").findings().isEmpty
        XCTAssertTrue(observed13)
        try write(".repoman.json", #"{"stashAgeDays":90}"#)
        let observed14 = await catalog("git.oldStashes").inspect(context).findings().isEmpty
        XCTAssertTrue(observed14)
    }
    func testGitMarkersAndDetachedHeadAreDetected() async throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git/rebase-merge"), withIntermediateDirectories: true)
        let report = try await inspect("git.unfinishedOperation")
        XCTAssertTrue(report.findings().contains { $0.subject == "rebase-merge" })
        try FileManager.default.removeItem(at: root.appendingPathComponent(".git/rebase-merge"))
        try git(["checkout", "--detach"])
        let observed15 = try await inspect("git.unfinishedOperation").findings().contains { $0.subject == "HEAD" }
        XCTAssertTrue(observed15)
    }
    func testDocumentationResolvesRelativeLinksAndSkipsExamples() async throws {
        try write("README.md", """
        [Missing](docs/missing.md)
        ![Existing](docs/image%20file.png)
        [Remote](https://example.com/not-local)
        `[Inline example](not-real-inline.md)`
        <!-- [Comment example](not-real-comment.md) -->
        ```md
        [Example](not-real.md)
        ```
        """)
        try write("docs/image file.png", "image")
        try write("docs/guide.md", "[Home](../README.md)\n[Root](..)\n[Missing image](missing.png)")
        try git(["add", "."])
        let report = try await inspect("docs.brokenLinks")
        XCTAssertEqual(report.findings().count, 2)
        XCTAssertFalse(report.findings().contains { $0.evidence.contains("not-real") || $0.evidence.contains("Existing") })
        try write("docs/missing.md", "Restored")
        try write("docs/missing.png", "Restored")
        let observed16 = try await inspect("docs.brokenLinks").findings().isEmpty
        XCTAssertTrue(observed16)
    }
    func testMissingSkillReferenceIsDetectedAndEscapingLinksStayUnknown() async throws {
        try write("AGENTS.md", "Use `.codex/skills/build/SKILL.md`.\n")
        let observed17 = try await inspect("docs.brokenLinks").findings().isEmpty
        XCTAssertFalse(observed17)
        try write("AGENTS.md", "[Outside](../outside-file.md)")
        let observed18 = try await inspect("docs.brokenLinks").unavailableChecks["docs.brokenLinks"]
        XCTAssertNotNil(observed18)
    }
    func testNotebookOptInErrorsSizeAndMalformedFormat() async throws {
        let notebook: [String: Any] = ["nbformat":4, "cells":[["cell_type":"code", "outputs":[["output_type":"error", "ename":"ExpectedError", "evalue":"example", "traceback":[]]]]]]
        try write("example.ipynb", String(decoding: JSONSerialization.data(withJSONObject: notebook), as: UTF8.self))
        try git(["add", "example.ipynb"])
        let observed19 = try await inspect("notebooks.hygiene").findings().isEmpty
        XCTAssertTrue(observed19)
        try write(".repoman.json", #"{"notebooks":{"enabled":true,"maximumOutputBytes":1024}}"#)
        let observed20 = try await inspect("notebooks.hygiene").findings().isEmpty
        XCTAssertFalse(observed20)
        let large: [String: Any] = ["nbformat":4, "cells":[["cell_type":"code", "outputs":[["output_type":"stream", "text":String(repeating:"x", count:2048)]]]]]
        try write("example.ipynb", String(decoding: JSONSerialization.data(withJSONObject: large), as: UTF8.self))
        let observed21 = try await inspect("notebooks.hygiene").findings().isEmpty
        XCTAssertFalse(observed21)
        try write("example.ipynb", "{}")
        let observed22 = try await inspect("notebooks.hygiene").unavailableChecks["notebooks.hygiene"]
        XCTAssertNotNil(observed22)
    }
    func testMalformedPolicyAndSymlinkCannotEstablishAbsence() async throws {
        try write("package.json", #"{"packageManager":"npm@11.0.0"}"#)
        try write(".repoman.json", #"{"stashAgeDay":5}"#)
        let observed23 = try await inspect("dependencies.safeguards").unavailableChecks["dependencies.safeguards"]
        XCTAssertNotNil(observed23)
        try FileManager.default.removeItem(at: root.appendingPathComponent(".repoman.json"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".npmrc"), withDestinationURL: root.deletingLastPathComponent().appendingPathComponent("outside"))
        let observed24 = try await inspect("dependencies.safeguards").unavailableChecks["dependencies.safeguards"]
        XCTAssertNotNil(observed24)
    }
    func testGitOutputLimitAndFileSizeLimitStayBounded() throws {
        try write("tracked.txt", "text"); try git(["add", "tracked.txt"])
        XCTAssertThrowsError(try GitRunner.run(["ls-files", "-z"], at: root, maximumOutputBytes: 1))
        try write("oversized.txt", String(repeating: "x", count: 1_048_577))
        let context = RepositoryInspectionContext(snapshot: try snapshot())
        XCTAssertThrowsError(try context.readText("oversized.txt"))
    }

    func testUnmergedIndexIsDetectedWithoutChangingIt() async throws {
        try write("conflict.txt", "base")
        try git(["add", "conflict.txt"]); try git(["commit", "-m", "Base"])
        try git(["checkout", "-b", "other"])
        try write("conflict.txt", "other")
        try git(["commit", "-am", "Other"])
        try git(["checkout", "main"])
        try write("conflict.txt", "main")
        try git(["commit", "-am", "Main"])
        _ = try GitRunner.run(["merge", "other"], at: root, successfulExitCodes: [1])
        let before = try GitRunner.run(["ls-files", "--unmerged", "-z"], at: root)
        let report = try await inspect("git.unfinishedOperation")
        XCTAssertTrue(report.findings().contains { $0.subject == "conflicts" })
        XCTAssertTrue(report.findings().contains { $0.subject == "MERGE_HEAD" })
        XCTAssertEqual(try GitRunner.run(["ls-files", "--unmerged", "-z"], at: root), before)
    }
    func testMetadataUsesPublishedReadmeAndStableRemoteIdentity() async throws {
        try write("README.md", header("Uncommitted feature tagline"))
        let snapshot = RepositorySnapshot(url: root, name: "test", branch: "feature", upstream: nil,
            remoteURL: "git@github.com:owner/project.git", ahead: nil, behind: nil,
            changes: [], staleBranches: [], worktrees: [], commits: [], rootFiles: ["README.md"])
        let published = header("Published &amp; safe")
        let checks = RepositoryMetadataChecks.checks(load: { _ in
            PublishedRepositoryMetadata(description: "old", branch: "main", sha: "abcdef123456", readme: published)
        })
        let catalog = RepositoryIssueCatalog(checks: checks)
        let before = await catalog.inspect(snapshot)
        let finding = try XCTUnwrap(before.findings().first)
        XCTAssertEqual(finding.subject, "owner/project")
        XCTAssertTrue(finding.evidence.contains("Published & safe"))
        XCTAssertFalse(finding.evidence.contains("Uncommitted feature"))
        let unavailable = RepositoryIssueCatalog(checks: RepositoryMetadataChecks.checks(load: { _ in
            throw RepairError.blocked("Authentication failed")
        }))
        let unknown = await unavailable.inspect(snapshot)
        if case .unknown = unavailable.verify(finding, in: unknown) {} else { XCTFail("Auth failure resolved metadata") }
        let fixed = RepositoryIssueCatalog(checks: RepositoryMetadataChecks.checks(load: { _ in
            PublishedRepositoryMetadata(description: "Published & safe", branch: "main", sha: "newcommit", readme: published)
        }))
        let after = await fixed.inspect(snapshot)
        if case .absent = fixed.verify(finding, in: after) {} else { XCTFail("Matching description did not resolve") }
    }
    func testTaglineMatchesPublishedSyncContractAndRejectsBadMarkers() throws {
        XCTAssertEqual(try GitHubTagline.tagline(header("⚡  Build\n&amp; ship  🚀")), "⚡ Build & ship 🚀")
        XCTAssertEqual(try GitHubTagline.tagline(header("a_b *c*")), "a_b *c*")
        XCTAssertNil(try GitHubTagline.tagline("Supports repo-tagline:start conventions."))
        for value in ["<!-- repo-tagline:start -->hello", header("Valid") + "<!-- repo-tagline:star -->",
                      header("<em>Nested</em>"), "```html\n" + header("Example") + "\n```"] {
            XCTAssertThrowsError(try GitHubTagline.tagline(value))
        }
        XCTAssertThrowsError(try GitHubTagline.tagline(header(String(repeating: "x", count: 351))))
    }
    func testGraphQLMetadataDecoderRejectsMissingBinaryAndErrorResponses() throws {
        func response(_ blob: [String: Any]?) throws -> Data {
            let commit: [String: Any] = ["oid":"123abc", "readme":blob.map { ["object":$0] } ?? NSNull()]
            return try JSONSerialization.data(withJSONObject: ["data":["repository":["description":"old",
                "defaultBranchRef":["name":"main", "target":commit]]]])
        }
        let readme = header("Published")
        let decoded = try GitHubTagline.decode(response(["text":readme, "byteSize":readme.utf8.count, "isBinary":false]))
        XCTAssertEqual(decoded.readme, readme)
        XCTAssertEqual(decoded.branch, "main")
        XCTAssertNil(try GitHubTagline.decode(response(nil)).readme)
        XCTAssertThrowsError(try GitHubTagline.decode(response(["text":readme, "byteSize":1_048_577, "isBinary":false])))
        XCTAssertThrowsError(try GitHubTagline.decode(response(["text":NSNull(), "byteSize":12, "isBinary":true])))
        XCTAssertThrowsError(try GitHubTagline.decode(Data(#"{"errors":[{"message":"rate limited"}]}"#.utf8)))
        XCTAssertThrowsError(try GitHubTagline.decode(Data(#"{"data":{"repository":null}}"#.utf8)))
    }
    func testStandaloneUVSourcesAndPolicyOverridesAreReviewed() async throws {
        try write("pyproject.toml", "[project]\nname = 'example'")
        try write("uv.toml", "exclude-newer = '7 days'\n[sources]\ncustom = { index = 'gpu' }\n[[index]]\nname = 'gpu'\nurl = 'https://example.com/wheels'\n[exclude-newer-package]\ncustom = false")
        let report = try await inspect("dependencies.sources")
        let finding = try XCTUnwrap(report.findings().first)
        XCTAssertTrue(finding.evidence.contains("alternate package index"))
        XCTAssertTrue(finding.evidence.contains("global dependency age policy"))
    }
    private func header(_ tagline: String) -> String {
        "<p align=\"center\">\n<img src=\"logo.png\" />\n<!-- repo-tagline:start -->\n<strong>" + tagline + "</strong>\n<!-- repo-tagline:end -->\n</p>"
    }

    func testIndependentNestedProjectDoesNotUseUnrelatedParentLockfile() async throws {
        try write("pyproject.toml", "[project]\nname = 'root'")
        try write("uv.lock", "version = 1")
        try write("examples/standalone/pyproject.toml", "[project]\nname = 'standalone'")
        try git(["add", "."])
        let report = try await inspect("dependencies.lockfile")
        XCTAssertEqual(report.findings().map(\.subject), ["examples/standalone/pyproject.toml"])
        try write("pyproject.toml", "[project]\nname = 'root'\n[tool.uv.workspace]\nmembers = ['examples/*']")
        let workspace = try await inspect("dependencies.lockfile")
        XCTAssertTrue(workspace.findings().isEmpty)
    }
    func testCIOverrideWeakensOtherwiseValidRepositoryPolicy() async throws {
        try write("pyproject.toml", "[tool.uv]\nexclude-newer = '7 days'\nconstraint-dependencies = ['mistralai!=2.4.6','guardrails-ai!=0.10.1']")
        try workflow("ci.yml", "on: push\njobs:\n  test:\n    steps:\n      - run: uv sync --exclude-newer '1 day'")
        let report = try await inspect("dependencies.safeguards")
        XCTAssertTrue(report.findings().first?.evidence.contains("overrides the uv") == true)
    }
    func testEmptyExclusionsAndDefaultRegistryAreNotCustomSources() async throws {
        try write("package.json", #"{"packageManager":"pnpm@10.33.0"}"#)
        try write("pnpm-workspace.yaml", "minimumReleaseAgeExclude: []\nminimumReleaseAge: 10080\nblockExoticSubdeps: true")
        try write(".npmrc", "registry=https://registry.npmjs.org/ # standard registry")
        let report = try await inspect("dependencies.sources")
        XCTAssertTrue(report.findings().isEmpty)
    }

    func testShellCasePatternIsNotMistakenForYAMLAnchor() throws {
        let source = """
        on: push
        jobs:
          test:
            steps:
              - uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
              - run: |
                  case "$value" in
                    docker:*@sha256:*) ;;
                  esac
        """
        XCTAssertEqual(try WorkflowInspection.references(source).count, 1)
        XCTAssertEqual(try WorkflowInspection.steps(source).count, 2)
        XCTAssertThrowsError(try WorkflowInspection.steps("on: push\njobs:\n  test:\n    steps: *shared"))
    }
    func testMetadataDiscoversActualReadmeBeforeRequestingItsContents() throws {
        let snapshot = RepositorySnapshot(url: root, name: "test", branch: "feature", upstream: nil,
            remoteURL: "git@github.com:owner/project.git", ahead: nil, behind: nil,
            changes: [], staleBranches: [], worktrees: [], commits: [], rootFiles: [])
        let discovery = try JSONSerialization.data(withJSONObject: ["data":["repository":["description":"first",
            "defaultBranchRef":["name":"main", "target":["oid":"firstcommit", "tree":["entries":[["name":"ReadMe.rst","type":"blob"]]]]]]]])
        let text = header("Published")
        let latest = try JSONSerialization.data(withJSONObject: ["data":["repository":["description":"Published",
            "defaultBranchRef":["name":"main", "target":["oid":"latestcommit", "readme":["object":["text":text,"byteSize":text.utf8.count,"isBinary":false]]]]]]])
        var calls: [[String]] = []
        let metadata = try GitHubTagline.load(snapshot, run: { arguments in
            calls.append(arguments)
            return calls.count == 1 ? discovery : latest
        })
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls[1].contains("path=ReadMe.rst"))
        XCTAssertFalse(calls[0].contains { $0.contains("file(path:") })
        XCTAssertEqual(metadata.sha, "latestcommit")
        XCTAssertEqual(metadata.description, "Published")
    }
    func testTaglineDecodesEntitiesOnceAndCachedFileLimitsRemainStrict() throws {
        XCTAssertEqual(try GitHubTagline.tagline(header("&lt; &amp;lt;")), "< &lt;")
        try write("large.ipynb", String(repeating: "x", count: 1_048_577))
        let context = RepositoryInspectionContext(snapshot: try snapshot())
        XCTAssertEqual(try context.readNotebook("large.ipynb").utf8.count, 1_048_577)
        XCTAssertThrowsError(try context.readText("large.ipynb"))
    }

    func testLocalInspectionPreservesIndexFilesAndNeverRunsGitHelpers() async throws {
        try write("tracked.txt", "initial")
        try git(["add", "tracked.txt"]); try git(["commit", "-m", "Tracked"])
        try write("tracked.txt", "stash content")
        try git(["stash", "push"])
        try write("tracked.txt", "working changes")
        let probe = root.appendingPathComponent("probe.sh")
        let marker = root.appendingPathComponent("helper-was-run")
        try write("probe.sh", "#!/bin/sh\ntouch '" + marker.path + "'\n")
        try FileManager.default.setAttributes([.posixPermissions:0o700], ofItemAtPath:probe.path)
        try git(["config", "core.fsmonitor", probe.path])
        try git(["config", "diff.external", probe.path])
        let index = root.appendingPathComponent(".git/index")
        let before = try Data(contentsOf:index)
        let modified = try FileManager.default.attributesOfItem(atPath:index.path)[.modificationDate] as? Date
        let checks = RepositoryIssueCatalog.standardChecks.filter {
            $0.requiresExtendedInspection && !["ci.failing", "ci.coverage", "github.description", "github.privateVisibility"].contains($0.id)
        }
        let report = await RepositoryIssueCatalog(checks:checks).inspect(try snapshot(checkedAt:Date().addingTimeInterval(35 * 86_400)))
        XCTAssertTrue(report.unavailableChecks.isEmpty)
        XCTAssertTrue(report.findings().contains { $0.checkID == "git.oldStashes" })
        XCTAssertEqual(try Data(contentsOf:index), before)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath:index.path)[.modificationDate] as? Date, modified)
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("tracked.txt")), "working changes")
        XCTAssertFalse(FileManager.default.fileExists(atPath:marker.path))
    }

    func testSimilarNamesAndVersionsDoNotSatisfyBadPackageExclusions() async throws {
        try write("pyproject.toml", "[tool.uv]\nexclude-newer = '7 days'\nconstraint-dependencies = ['other-mistralai!=2.4.6','guardrails-ai!=0.10.10']")
        let report = try await inspect("dependencies.safeguards")
        let evidence = try XCTUnwrap(report.findings().first).evidence
        XCTAssertTrue(evidence.contains("mistralai!=2.4.6"))
        XCTAssertTrue(evidence.contains("guardrails-ai!=0.10.1"))
    }

    func testMetadataCacheExpiresAndRepairInspectionAlwaysBypassesIt() async throws {
        let snapshot = RepositorySnapshot(url: root, name: "test", branch: "main", upstream: nil,
            remoteURL: "git@github.com:owner/project.git", ahead: nil, behind: nil,
            changes: [], staleBranches: [], worktrees: [], commits: [], rootFiles: [])
        let cache = PublishedMetadataCache(), counter = MetadataLoadCounter()
        let now = Date(timeIntervalSince1970:1_790_850_000)
        let first = try await cache.load(snapshot, allowCached:true, now:now, loader:{ _ in await counter.next() })
        let reused = try await cache.load(snapshot, allowCached:true, now:now.addingTimeInterval(30), loader:{ _ in await counter.next() })
        XCTAssertFalse(first.cached)
        XCTAssertTrue(reused.cached)
        XCTAssertEqual(first.metadata.description, reused.metadata.description)
        let fresh = try await cache.load(snapshot, allowCached:false, now:now.addingTimeInterval(40), loader:{ _ in await counter.next() })
        XCTAssertFalse(fresh.cached)
        XCTAssertNotEqual(fresh.metadata.description, first.metadata.description)
        let expired = try await cache.load(snapshot, allowCached:true, now:now.addingTimeInterval(700), loader:{ _ in await counter.next() })
        XCTAssertFalse(expired.cached)
        let count = await counter.count
        XCTAssertEqual(count, 3)
    }
    func testCachedAbsenceCannotResolveAnEarlierFinding() async throws {
        let id = "github.description"
        let catalog = RepositoryIssueCatalog(checks:[RepositoryCheck(id:id,title:"Description",category:.documentation,symbol:"doc",inspect:{ context in
            context.markCached(id)
            return []
        })])
        let snapshot = try snapshot()
        let finding = RepositoryFinding(repositoryID:snapshot.id,checkID:id,subject:"owner/project",title:"Description",evidence:"Old mismatch",category:.documentation,symbol:"doc")
        let report = await catalog.inspect(snapshot, allowCachedRemoteMetadata:true)
        XCTAssertEqual(report.cachedChecks, [id])
        if case .unknown = catalog.verify(finding, in:report) {} else { XCTFail("Cached absence resolved a finding") }
        let preserved = report.updatingSnapshot(snapshot,catalog:catalog)
        XCTAssertEqual(preserved.cachedChecks, [id])
    }

    private func catalog(_ id: String) -> RepositoryIssueCatalog { RepositoryIssueCatalog(checks: RepositoryIssueCatalog.standardChecks.filter { $0.id == id }) }
    private func inspect(_ id: String) async throws -> RepositoryInspectionReport { await catalog(id).inspect(try snapshot()) }
    private func snapshot(checkedAt: Date = Date()) throws -> RepositorySnapshot {
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        return RepositorySnapshot(url: root, name: "test", branch: "main", upstream: nil, remoteURL: nil, ahead: nil, behind: nil, changes: [], staleBranches: [], worktrees: [], commits: [], checkedAt: checkedAt, rootFiles: files)
    }
    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    private func workflow(_ name: String, _ source: String) throws { try write(".github/workflows/" + name, source) }
    private func git(_ arguments: [String]) throws { _ = try GitRunner.run(arguments, at: root) }
}

private actor MetadataLoadCounter {
    private(set) var count = 0
    func next() -> PublishedRepositoryMetadata {
        count += 1
        return PublishedRepositoryMetadata(description:String(count),branch:"main",sha:String(count),readme:nil)
    }
}
