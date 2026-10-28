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
