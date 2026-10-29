import Foundation
import XCTest
@testable import RepoManCore

final class RepositoryCheckerRegressionTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RepoManRegression-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try GitRunner.run(["init", "-b", "main"], at: root)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testNativeNodeTestsCountAsJavaScriptTestCoverageButDecoysDoNot() async throws {
        try write("package.json", "{}")
        try write(".repoman.json", #"{"ci":{"components":[{"path":".","ecosystem":"javascript","requires":["test"]}]}}"#)
        for command in ["node --test", "node --test test/*.test.js", "node --test=tests"] {
            try workflow("      - run: " + command)
            let report = try await inspect("ci.coverage")
            XCTAssertEqual(report.status(for: "ci.coverage"), .passed, command)
        }
        for command in ["echo 'node --test'", "printf 'node --test'", "node --test-reporter spec", "node --test-name-pattern foo"] {
            try workflow("      - run: " + command)
            let report = try await inspect("ci.coverage")
            XCTAssertNotEqual(report.status(for: "ci.coverage"), .passed, command)
        }
        try workflow("      - run: echo no-validation")
        let missing = try await inspect("ci.coverage")
        XCTAssertEqual(missing.status(for: "ci.coverage"), .findings)
        try workflow("      - run: node --test\n        continue-on-error: true")
        let suppressed = try await inspect("ci.suppressedFailures")
        XCTAssertEqual(suppressed.status(for: "ci.suppressedFailures"), .findings)
    }

    func testSameRepositoryCheckoutPathResolvesScriptsActionsAndVersionFiles() async throws {
        try write("scripts/check.py", "pass")
        try write(".python-version", "3.14")
        try write(".github/actions/check/action.yml", "name: check")
        try workflow("""
              - uses: actions/checkout@sha
                with:
                  path: trusted-delivery
              - run: python3 scripts/check.py
                working-directory: trusted-delivery
              - uses: ./trusted-delivery/.github/actions/check
              - uses: actions/setup-python@sha
                with:
                  python-version-file: trusted-delivery/.python-version
              - uses: actions/upload-artifact@sha
                with:
                  path: |
                    generated/file
                    another/file
        """)
        var report = try await inspect("files.projectReferences")
        XCTAssertEqual(report.status(for: "files.projectReferences"), .passed)
        try FileManager.default.removeItem(at: root.appendingPathComponent("scripts/check.py"))
        report = try await inspect("files.projectReferences")
        XCTAssertEqual(report.status(for: "files.projectReferences"), .findings)
        XCTAssertTrue(report.findings().first?.evidence.contains("scripts/check.py is missing") == true)
    }

    func testCheckoutLayoutsDoNotLeakAcrossJobsAndReusableWorkflowsStayRepositoryRelative() async throws {
        try write("scripts/check.py", "pass")
        try write(".github/workflows/reuse.yml", "on: workflow_call\njobs: {}")
        try workflow("""
              - uses: actions/checkout@sha
                with:
                  path: source
              - run: python3 source/scripts/check.py
          second:
            steps:
              - uses: actions/checkout@sha
              - run: python3 source/scripts/check.py
          reuse:
            uses: ./.github/workflows/reuse.yml
        """)
        let report = try await inspect("files.projectReferences")
        XCTAssertEqual(report.status(for: "files.projectReferences"), .findings)
        XCTAssertTrue(report.findings().first?.evidence.contains("source/scripts/check.py is missing") == true)
        XCTAssertFalse(report.findings().first?.evidence.contains("reuse.yml") == true)
    }

    func testExternalRevisionsSparseAndConditionalCheckoutsStayIncomplete() async throws {
        for input in ["repository: other/project", "ref: another-revision", "sparse-checkout: scripts", "path: ${{ matrix.checkout }}"] {
            try workflow("      - uses: actions/checkout@sha\n        with:\n          path: source\n          " + input + "\n      - run: python3 source/scripts/check.py")
            let report = try await inspect("files.projectReferences")
            XCTAssertEqual(report.status(for: "files.projectReferences"), .incomplete, input)
            XCTAssertTrue(report.findings().isEmpty)
        }
        try workflow("      - uses: actions/checkout@sha\n        if: false\n      - run: python3 scripts/check.py")
        let conditional = try await inspect("files.projectReferences")
        XCTAssertEqual(conditional.status(for: "files.projectReferences"), .incomplete)
    }

    func testUnknownCheckoutKeepsKnownMissingReferences() async throws {
        try workflow("""
              - uses: actions/checkout@sha
              - run: python3 scripts/missing.py
              - uses: actions/checkout@sha
                with:
                  path: other
                  repository: other/project
              - run: python3 other/scripts/check.py
        """)
        let report = try await inspect("files.projectReferences")
        XCTAssertNotNil(report.unavailableChecks["files.projectReferences"])
        XCTAssertTrue(report.findings().first?.evidence.contains("scripts/missing.py") == true)
        XCTAssertFalse(report.findings().first?.evidence.contains("other/scripts/check.py") == true)
    }

    func testUVMinorUpperBoundNormalizationPreservesRealMarkerDrift() async throws {
        for (manifest, lock, expected) in [
            ("python_version < '3.11'", "python_full_version < '3.11'", RepositoryCheckStatus.passed),
            ("python_version < '3.11'", "python_full_version < '3.12'", .findings),
            ("python_version == '3.11'", "python_full_version == '3.11'", .findings),
            ("python_version < '3.11.2'", "python_full_version < '3.11.2'", .findings)
        ] {
            try write("pyproject.toml", "[project]\nname = 'app'\n[dependency-groups]\ndev = [\"tomli>=2.2.0; \(manifest)\"]")
            try write("uv.lock", "version = 1\n[[package]]\nname = 'app'\nsource = { virtual = '.' }\n[package.metadata.requires-dev]\ndev = [{name = 'tomli', specifier = '>=2.2.0', marker = \"\(lock)\"}]")
            let report = try await inspect("dependencies.lockfileDrift")
            XCTAssertEqual(report.status(for: "dependencies.lockfileDrift"), expected, manifest + " / " + lock)
        }
    }

    private func workflow(_ steps: String) throws {
        try write(".github/workflows/ci.yml", "on: [push, pull_request]\njobs:\n  test:\n    steps:\n" + steps)
    }

    func testLogoFreeTaglinePassesButDescriptionMismatchRemainsActionable() async throws {
        let readme = taglineHeader("Build &amp; learn")
        XCTAssertEqual(try GitHubTagline.tagline(readme), "Build & learn")
        XCTAssertEqual(try GitHubTagline.tagline(readme.replacingOccurrences(of: "</p>", with: "<img src=\"logo.png\" />\n</p>")), "Build & learn")
        let snapshot = RepositorySnapshot(url: root, name: "fixture", branch: "main", upstream: nil,
            remoteURL: "https://github.com/owner/project.git", ahead: nil, behind: nil,
            changes: [], staleBranches: [], worktrees: [], commits: [], rootFiles: [])
        for (description, expected) in [("Build & learn", RepositoryCheckStatus.passed), ("Stale description", .findings)] {
            let checks = RepositoryMetadataChecks.checks(load: { _ in
                PublishedRepositoryMetadata(description: description, branch: "main", sha: "abcdef123", readme: readme)
            }).filter { $0.id == "github.description" }
            let report = await RepositoryIssueCatalog(checks: checks).inspect(snapshot)
            XCTAssertEqual(report.status(for: "github.description"), expected)
        }
    }

    func testLogoFreeTaglineStillRejectsInvalidMarkersAndContent() throws {
        let valid = taglineHeader("Valid")
        for readme in [valid + valid, valid.replacingOccurrences(of: "repo-tagline:end", with: "repo-tagline:star"),
                       valid.replacingOccurrences(of: "repo-tagline:start", with: "repo-tagline:end"),
                       taglineHeader(""), taglineHeader("<em>Nested</em>"), taglineHeader(String(repeating: "x", count: 351)),
                       "```html\n" + valid + "\n```", valid.replacingOccurrences(of: "<p align=\"center\">", with: "<p>"),
                       "<p align=\"center\">Other content</p>\n" + valid] {
            XCTAssertThrowsError(try GitHubTagline.tagline(readme))
        }
    }

    func testManagedArchiveNoticePreservesDescriptionTagline() throws {
        for readme in ["<!-- archive-repo:deprecation-notice:start -->\n> [!WARNING]\n> **Deprecated**\n>\n> Agents made this experiment obsolete.\n<!-- archive-repo:deprecation-notice:end -->\n\n<p align=\"center\">\n<!-- repo-tagline:start -->\n<strong>Build &amp; learn 🚀</strong>\n<!-- repo-tagline:end -->\n</p>",
            "<!-- archive-repo:deprecation-notice:start -->\r\n> [!WARNING]\r\n> **Deprecated**\r\n>\r\n> Agents made this experiment obsolete.\r\n<!-- archive-repo:deprecation-notice:end -->\r\n\r\n<p align=\"center\">\r\n<!-- repo-tagline:start -->\r\n<strong>Build &amp; learn 🚀</strong>\r\n<!-- repo-tagline:end -->\r\n</p>",
            "<!-- archive-repo:deprecation-notice:start -->\n> [!WARNING]\n> **Deprecated**\n>\n> First reason.\n>\n> Second reason.\n<!-- archive-repo:deprecation-notice:end -->\n\n<p align=\"center\">\n<!-- repo-tagline:start -->\n<strong>Build &amp; learn 🚀</strong>\n<!-- repo-tagline:end -->\n</p>"] {
            XCTAssertEqual(try GitHubTagline.tagline(readme), "Build & learn 🚀")
        }
    }

    func testManagedNoticeCannotHideMalformedOrMisplacedMarkers() throws {
        for readme in ["<!-- archive-repo:deprecation-notice:start -->\n> [!WARNING]\n> **Deprecated**\n>\n> Agents made this experiment obsolete.\n<!-- archive-repo:deprecation-notice:end -->\n\n<!-- archive-repo:deprecation-notice:start -->\n> [!WARNING]\n> **Deprecated**\n>\n> Agents made this experiment obsolete.\n<!-- archive-repo:deprecation-notice:end -->\n\n<p align=\"center\">\n<!-- repo-tagline:start -->\n<strong>Build &amp; learn 🚀</strong>\n<!-- repo-tagline:end -->\n</p>",
            "<p align=\"center\">\n<!-- repo-tagline:start -->\n<strong>Build &amp; learn 🚀</strong>\n<!-- repo-tagline:end -->\n</p>\n<!-- archive-repo:deprecation-notice:start -->\n> [!WARNING]\n> **Deprecated**\n>\n> Agents made this experiment obsolete.\n<!-- archive-repo:deprecation-notice:end -->\n\n",
            "<!-- archive-repo:deprecation-notice:start -->\n> [!WARNING]\n> **Deprecated**\n>\n> Agents made this experiment obsolete.\n<!-- archive-repo:deprecation-notice:star -->\n\n<p align=\"center\">\n<!-- repo-tagline:start -->\n<strong>Build &amp; learn 🚀</strong>\n<!-- repo-tagline:end -->\n</p>",
            "<!-- archive-repo:deprecation-notice:end -->\n> [!WARNING]\n> **Deprecated**\n>\n> Agents made this experiment obsolete.\n<!-- archive-repo:deprecation-notice:end -->\n\n<p align=\"center\">\n<!-- repo-tagline:start -->\n<strong>Build &amp; learn 🚀</strong>\n<!-- repo-tagline:end -->\n</p>",
            "<!-- archive-repo:deprecation-notice:start -->\n> [!NOTE]\n> **Deprecated**\n>\n> Agents made this experiment obsolete.\n<!-- archive-repo:deprecation-notice:end -->\n\n<p align=\"center\">\n<!-- repo-tagline:start -->\n<strong>Build &amp; learn 🚀</strong>\n<!-- repo-tagline:end -->\n</p>",
            "<!-- archive-repo:deprecation-notice:start -->\n> [!WARNING]\n> Deprecated\n>\n> Agents made this experiment obsolete.\n<!-- archive-repo:deprecation-notice:end -->\n\n<p align=\"center\">\n<!-- repo-tagline:start -->\n<strong>Build &amp; learn 🚀</strong>\n<!-- repo-tagline:end -->\n</p>",
            "<!-- archive-repo:deprecation-notice:start -->\n> [!WARNING]\n> **Deprecated**\n>\n\n<!-- archive-repo:deprecation-notice:end -->\n\n<p align=\"center\">\n<!-- repo-tagline:start -->\n<strong>Build &amp; learn 🚀</strong>\n<!-- repo-tagline:end -->\n</p>",
            "<!-- archive-repo:deprecation-notice:start -->\n> [!WARNING]\n> **Deprecated**\n>\nUnquoted rationale\n<!-- archive-repo:deprecation-notice:end -->\n\n<p align=\"center\">\n<!-- repo-tagline:start -->\n<strong>Build &amp; learn 🚀</strong>\n<!-- repo-tagline:end -->\n</p>",
            "```markdown\n<!-- archive-repo:deprecation-notice:start -->\n> [!WARNING]\n> **Deprecated**\n>\n> Agents made this experiment obsolete.\n<!-- archive-repo:deprecation-notice:end -->\n\n<p align=\"center\">\n<!-- repo-tagline:start -->\n<strong>Build &amp; learn 🚀</strong>\n<!-- repo-tagline:end -->\n</p>\n```",
            "~~~markdown\n<!-- archive-repo:deprecation-notice:start -->\n> [!WARNING]\n> **Deprecated**\n>\n> Agents made this experiment obsolete.\n<!-- archive-repo:deprecation-notice:end -->\n\n<p align=\"center\">\n<!-- repo-tagline:start -->\n<strong>Build &amp; learn 🚀</strong>\n<!-- repo-tagline:end -->\n</p>\n~~~",
            "<!-- archive-repo:deprecation-notice:start -->\n> [!WARNING]\n> **Deprecated**\n>\n> Agents made this experiment obsolete.\n<!-- archive-repo:deprecation-notice:end -->\n\n<p align=\"center\">\n<!-- repo-tagline:start -->\n<strong>Build &amp; learn 🚀</strong>\n<!-- repo-tagline:end -->\n</p><!-- archive-repo:deprecation-notice:start -->",
            "<!-- archive-repo:deprecation-notice:start -->\n> [!WARNING]\n> **Deprecated**\n>\n> <!-- repo-tagline:start -->\n<!-- archive-repo:deprecation-notice:end -->\n\n<p align=\"center\">\n<!-- repo-tagline:start -->\n<strong>Build &amp; learn 🚀</strong>\n<!-- repo-tagline:end -->\n</p>",
            "<!-- archive-repo:deprecation-notice:start -->\n> [!WARNING]\n> **Deprecated**\n>\n> Agents made this experiment obsolete.\n<!-- archive-repo:deprecation-notice:end -->\n\n<p align=\"center\">\n<!-- repo-tagline:start -->\n<strong>Build &amp; learn 🚀</strong>\n<!-- repo-tagline:star -->\n</p>",
            "<!-- archive-repo:deprecation-notice:start -->\n> [!WARNING]\n> **Deprecated**\n>\n> Agents made this experiment obsolete.\n<!-- archive-repo:deprecation-notice:end -->\n\n<p align=\"center\">\n<!-- repo-tagline:start -->\n<strong>Build &amp; learn 🚀</strong>\n<!-- repo-tagline:end -->\n</p><p align=\"center\">\n<!-- repo-tagline:start -->\n<strong>Build &amp; learn 🚀</strong>\n<!-- repo-tagline:end -->\n</p>",
            "<!-- archive-repo:deprecation-notice:start -->\n> [!WARNING]\n> **Deprecated**\n>\n> Agents made this experiment obsolete.\n<!-- archive-repo:deprecation-notice:end -->\n\n<p>\n<!-- repo-tagline:start -->\n<strong>Build &amp; learn 🚀</strong>\n<!-- repo-tagline:end -->\n</p>",
            "<!-- archive-repo:deprecation-notice:start -->\n> [!WARNING]\n> **Deprecated**\n>\n> Agents made this experiment obsolete.\n<!-- archive-repo:deprecation-notice:end -->\n\n<p align=\"center\">\n<!-- repo-tagline:start -->\n<strong><em>Bad</em></strong>\n<!-- repo-tagline:end -->\n</p>"] {
            XCTAssertThrowsError(try GitHubTagline.tagline(readme))
        }
    }

    private func taglineHeader(_ text: String) -> String {
        "<p align=\"center\">\n<!-- repo-tagline:start -->\n<strong>" + text + "</strong>\n<!-- repo-tagline:end -->\n</p>"
    }
    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    private func inspect(_ id: String) async throws -> RepositoryInspectionReport {
        let snapshot = RepositorySnapshot(url: root, name: "fixture", branch: "main", upstream: nil, remoteURL: nil,
            ahead: nil, behind: nil, changes: [], staleBranches: [], worktrees: [], commits: [], checkedAt: Date(),
            rootFiles: try FileManager.default.contentsOfDirectory(atPath: root.path))
        return await RepositoryIssueCatalog(checks: RepositoryIssueCatalog.standardChecks.filter { $0.id == id }).inspect(snapshot)
    }
}
