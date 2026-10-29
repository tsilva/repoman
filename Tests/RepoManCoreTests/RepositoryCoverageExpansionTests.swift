import Foundation
import XCTest
@testable import RepoManCore

final class RepositoryCoverageExpansionTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RepoManCoverage-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try GitRunner.run(["init", "-b", "main"], at: root)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testUVConfigFileValidationAndNonValidationCommands() async throws {
        try write("pyproject.toml", "[project]\nname='app'")
        for command in ["uv run --locked --config-file uv.toml pytest -q", "uv run --config-file=uv.toml ruff check .", "uv run --config-file 'config path.toml' pytest",
                        "uv --config-file uv.toml run --locked pytest -q", "uv --config-file=uv.toml run ruff check .", "uv --config-file 'config path.toml' run pytest"] {
            try workflow("      - run: " + command)
            let report = try await inspect("ci.coverage")
            XCTAssertEqual(report.status(for: "ci.coverage"), .passed, command)
        }
        for command in ["echo 'uv run --config-file uv.toml pytest'", "uv run --config-file pytest", "uv run --config-file uv.toml echo pytest", "uv run --config-file 'unused && pytest' echo done", "uv run --config-file 'unused && pytest'",
                        "echo 'uv --config-file uv.toml run pytest'", "python -c 'print(\"uv --config-file uv.toml run pytest\")'", "uv --config-file run pytest", "uv --config-file uv.toml run echo pytest", "uv --config-file 'unused && pytest' run echo done", "uv --config-file '$CONFIG' run pytest", "uv run --config-file '$CONFIG' pytest", "uv --config-file --locked run pytest"] {
            try workflow("      - run: " + command)
            let report = try await inspect("ci.coverage")
            XCTAssertNotEqual(report.status(for: "ci.coverage"), .passed, command)
        }
        try workflow("      - run: uv run --config-file uv.toml pytest\n        continue-on-error: true")
        let suppressed = try await inspect("ci.suppressedFailures")
        XCTAssertEqual(suppressed.status(for: "ci.suppressedFailures"), .findings)
        try workflow("      - run: uv --config-file uv.toml run pytest\n        continue-on-error: true")
        let globalSuppressed = try await inspect("ci.suppressedFailures")
        XCTAssertEqual(globalSuppressed.status(for: "ci.suppressedFailures"), .findings)
    }

    func testLiteralPythonMatrixPassesButUnsupportedRuntimeRemainsAFinding() async throws {
        try write("pyproject.toml", "[project]\nname='app'\nrequires-python='>=3.11,<3.15'")
        try write(".python-version", "3.14")
        for axis in ["['3.11', '3.14']", "\n          - '3.11'\n          - '3.14'"] {
            try matrix(axis)
            let report = try await inspect("dependencies.runtime")
            XCTAssertEqual(report.status(for: "dependencies.runtime"), .passed, axis)
        }
        try matrix("['3.10', '3.14']")
        let mismatch = try await inspect("dependencies.runtime")
        XCTAssertEqual(mismatch.status(for: "dependencies.runtime"), .findings)
        XCTAssertTrue(mismatch.findings().first?.evidence.contains(".github/workflows/ci.yml") == true)
    }

    func testDynamicOrCoercedMatricesStayIncompleteAndJobsDoNotShareAxes() async throws {
        try write("pyproject.toml", "[project]\nname='app'\nrequires-python='>=3.11'")
        for axis in ["${{ fromJSON(inputs.versions) }}", "[3.10, 3.14]", "['3.11' '3.14']", "['3.1''1']", "['${{ inputs.python }}']", "[]", "['3.14']\n        include:\n          - python-version: '3.10'", "['3.14']\n        exclude:\n          - python-version: '3.14'"] {
            try matrix(axis)
            let report = try await inspect("dependencies.runtime")
            XCTAssertEqual(report.status(for: "dependencies.runtime"), .incomplete, axis)
        }
        try matrix("['3.14']", extra: "\n  other:\n    steps:\n      - uses: actions/setup-python@sha\n        with:\n          python-version: ${{ matrix.python-version }}")
        let report = try await inspect("dependencies.runtime")
        XCTAssertEqual(report.status(for: "dependencies.runtime"), .incomplete)
    }

    func testPNPMIntersectingQualifiedOverridesPassButWrongSpecifierAndManifestFail() async throws {
        try pnpm(requirement: "^8", specifier: "8.5.26", overrides: ["postcss@8.4.31": "8.5.26", "postcss@8.5.6": "8.5.26"])
        var report = try await inspect("dependencies.lockfileDrift")
        XCTAssertEqual(report.status(for: "dependencies.lockfileDrift"), .passed)
        try pnpm(requirement: "^8", specifier: "8.5.25", overrides: ["postcss@8.4.31": "8.5.26"])
        report = try await inspect("dependencies.lockfileDrift")
        XCTAssertEqual(report.status(for: "dependencies.lockfileDrift"), .findings)
        try pnpm(requirement: "^9", specifier: "8.5.26", overrides: ["postcss@8.4.31": "8.5.26"])
        report = try await inspect("dependencies.lockfileDrift")
        XCTAssertEqual(report.status(for: "dependencies.lockfileDrift"), .findings)
    }

    func testQualifiedOverrideRangeBoundariesAndNonmatchingRules() async throws {
        for (requirement, selector, matches) in [
            ("^8", "8.4.31", true), ("~8.4.0", ">=8.5.0", false),
            (">8", "8.5.0", false), ("<=8", "8.5.0", true),
            ("^0.2.3", "0.3.0", false), ("^0.0.3", "0.0.4", false),
            ("^0.0", "0.0.4", true), ("8.x", ">=8.4.0 <9", true)
        ] {
            try pnpm(requirement: requirement, specifier: matches ? "99.0.0" : requirement, overrides: ["postcss@" + selector: "99.0.0"])
            let report = try await inspect("dependencies.lockfileDrift")
            XCTAssertEqual(report.status(for: "dependencies.lockfileDrift"), .passed, requirement + " / " + selector)
        }
    }

    func testCompetingUnsupportedAndOlderManagerOverrideSemanticsStayIncomplete() async throws {
        for overrides in [["postcss@^8": "8.5.25", "postcss@>=8": "8.5.26"], ["postcss@^8": "8.5.26", "parent>postcss": "9"], ["postcss@8 || 9": "8.5.26"], ["postcss@8.0.0-beta.1": "8.5.26"], ["postcss@08.0.0": "8.5.26"], ["postcss@^8": "-"]] {
            try pnpm(requirement: "^8", specifier: "8.5.26", overrides: overrides)
            let report = try await inspect("dependencies.lockfileDrift")
            XCTAssertEqual(report.status(for: "dependencies.lockfileDrift"), .incomplete)
        }
        try pnpm(requirement: "^8", specifier: "8.5.26", overrides: ["postcss@^8": "8.5.26"], manager: "pnpm@9.15.0")
        let older = try await inspect("dependencies.lockfileDrift")
        XCTAssertEqual(older.status(for: "dependencies.lockfileDrift"), .incomplete)
    }

    func testUnknownQualifiedOverridePreservesOtherDependencyAndManifestDrift() async throws {
        try pnpm(requirement: "^8", specifier: "8.5.26", overrides: ["postcss@8 || 9": "8.5.26"])
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("package.json"))) as! [String: Any]
        manifest["dependencies"] = ["postcss": "^8", "other": "^2"]
        try write("package.json", String(decoding: JSONSerialization.data(withJSONObject: manifest), as: UTF8.self))
        let lock = try String(contentsOf: root.appendingPathComponent("pnpm-lock.yaml"), encoding: .utf8)
        try write("pnpm-lock.yaml", lock + "      other:\n        specifier: '^1'\n        version: 1.0.0\n")
        try write("pyproject.toml", "[project]\nname='app'\ndependencies=['requests>=3']")
        try write("uv.lock", "version=1\n[[package]]\nname='app'\nsource={virtual='.'}\n[package.metadata]\nrequires-dist=[{name='requests',specifier='>=2'}]")
        let report = try await inspect("dependencies.lockfileDrift")
        XCTAssertNotNil(report.unavailableChecks["dependencies.lockfileDrift"])
        XCTAssertEqual(Set(report.findings().map(\.subject)), ["package.json", "pyproject.toml"])
        XCTAssertTrue(report.findings().first(where: { $0.subject == "package.json" })?.evidence.contains("dependencies.other") == true)
    }

    private func pnpm(requirement: String, specifier: String, overrides: [String: String], manager: String = "pnpm@10.27.0") throws {
        let json: [String: Any] = ["packageManager": manager, "dependencies": ["postcss": requirement], "pnpm": ["overrides": overrides]]
        try write("package.json", String(decoding: JSONSerialization.data(withJSONObject: json), as: UTF8.self))
        let entries = overrides.sorted { $0.key < $1.key }.map { "  '\($0.key)': '\($0.value)'" }.joined(separator: "\n")
        try write("pnpm-lock.yaml", "lockfileVersion: '9.0'\noverrides:\n" + entries + "\nimporters:\n  .:\n    dependencies:\n      postcss:\n        specifier: '\(specifier)'\n        version: 8.5.26\n")
    }
    private func matrix(_ axis: String, extra: String = "") throws {
        try write(".github/workflows/ci.yml", "on: push\njobs:\n  test:\n    strategy:\n      matrix:\n        python-version: " + axis + "\n        os: ['ubuntu-latest', 'macos-latest']\n    steps:\n      - uses: actions/setup-python@sha\n        with:\n          python-version: ${{ matrix.python-version }}" + extra)
    }
    private func workflow(_ steps: String) throws {
        try write(".github/workflows/ci.yml", "on: push\njobs:\n  test:\n    steps:\n" + steps)
    }
    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    private func inspect(_ id: String) async throws -> RepositoryInspectionReport {
        let snapshot = RepositorySnapshot(url: root, name: "fixture", branch: "main", upstream: nil, remoteURL: nil,
            ahead: nil, behind: nil, changes: [], staleBranches: [], worktrees: [], commits: [],
            rootFiles: try FileManager.default.contentsOfDirectory(atPath: root.path))
        return await RepositoryIssueCatalog(checks: RepositoryIssueCatalog.standardChecks.filter { $0.id == id }).inspect(snapshot)
    }
}
