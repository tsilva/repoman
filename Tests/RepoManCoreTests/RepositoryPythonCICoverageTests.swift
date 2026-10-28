import Foundation
import XCTest
@testable import RepoManCore

final class RepositoryPythonCICoverageTests: XCTestCase {
    private var root: URL!
    private let source = """
    import unittest
    class Checks(unittest.TestCase):
        def test_result(self):
            self.assertEqual(2 + 2, 4)
    if __name__ == '__main__':
        unittest.main()
    """

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RepoManPythonCI-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try GitRunner.run(["init", "-b", "main"], at: root)
        try write("pyproject.toml", "[project]\nname = 'fixture'\n")
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testDirectUnittestIsRecognizedWithoutExecutingRepositoryCode() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"))
        let marker = root.appendingPathComponent("must-not-run")
        let script = source.replacingOccurrences(of: "self.assertEqual(2 + 2, 4)", with: "open('\(marker.path)', 'w').write('not executed')\n        self.assertEqual(2 + 2, 4)")
        try write("tests/checks.py", script)
        try workflow("python3 tests/checks.py")
        let report = try await inspect()
        XCTAssertTrue(report.findings().isEmpty)
        XCTAssertNil(report.unavailableChecks["ci.coverage"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
    func testCommentsDisabledMainAndSuppressedExitDoNotEstablishCoverage() async throws {
        for script in ["# unittest.main()\n", source.replacingOccurrences(of: "__name__ == '__main__'", with: "False"), source.replacingOccurrences(of: "unittest.main()", with: "unittest.main(exit=False)"), source + "\nunittest = None\n", source.replacingOccurrences(of: "class Checks", with: "@unittest.skip('disabled')\nclass Checks")] {
            try write("tests/checks.py", script)
            try workflow("python3 tests/checks.py")
            let report = try await inspect()
            XCTAssertNotNil(report.unavailableChecks["ci.coverage"])
        }
    }
    func testHelpMissingScriptsAndUnverifiedCheckoutsStayIncomplete() async throws {
        try write("tests/checks.py", source)
        for (command, checkout) in [("python3 tests/checks.py --help", ""), ("python3 tests/missing.py", ""), ("python3 tests/checks.py", "\n        with:\n          ref: other-revision"), ("python3 tests/checks.py", "\n        with:\n          path: different-layout")] {
            try workflow(command, checkout: checkout)
            let report = try await inspect()
            XCTAssertNotNil(report.unavailableChecks["ci.coverage"])
        }
    }
    func testWorkingDirectoriesDoNotBorrowOtherComponentsValidation() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"))
        try write("tools/checks.py", source)
        try write(".repoman.json", #"{"ci":{"components":[{"path":".","ecosystem":"python","requires":["test"]}]}}"#)
        try workflow("python3 checks.py", directory: "tools")
        let rootReport = try await inspect()
        XCTAssertEqual(rootReport.findings().first?.subject, ".#python")
        try write(".repoman.json", #"{"ci":{"components":[{"path":"tools","ecosystem":"python","requires":["test"]}]}}"#)
        let nestedReport = try await inspect()
        XCTAssertTrue(nestedReport.findings().isEmpty)
        XCTAssertNil(nestedReport.unavailableChecks["ci.coverage"])
    }
    func testFalseJobConditionStillMakesValidationMissing() async throws {
        try write("tests/checks.py", source)
        try workflow("python3 tests/checks.py", jobGuard: "    if: false\n")
        let report = try await inspect()
        XCTAssertEqual(report.findings().first?.checkID, "ci.coverage")
    }

    func testStandardLibrarySetupAndLiteralMethodDefaults() async throws {
        let script = "from pathlib import Path\nROOT = Path(__file__).resolve().parents[1]\n" + source.replacingOccurrences(of: "def test_result(self):", with: "def test_result(self, expected=4):")
        try write("tests/checks.py", script)
        try workflow("python3.11 'tests/checks.py'")
        let report = try await inspect()
        XCTAssertTrue(report.findings().isEmpty)
        XCTAssertNil(report.unavailableChecks["ci.coverage"])
    }
    func testShadowingHooksAndUnsafeModuleSetupStayUnknown() async throws {
        for script in [source + "\nload_tests = None\n", source.replacingOccurrences(of: "class Checks", with: "def load_tests(*args): return None\nclass Checks"), source.replacingOccurrences(of: "import unittest", with: "import unittest\nunittest.main = lambda: None"), source.replacingOccurrences(of: "import unittest", with: "import unittest\nraise SystemExit(0)"), source.replacingOccurrences(of: "class Checks", with: "class load_tests")] {
            try write("tests/checks.py", script)
            try workflow("python3 tests/checks.py")
            let report = try await inspect()
            XCTAssertNotNil(report.unavailableChecks["ci.coverage"])
        }
        try write("tests/checks.py", source)
        try write("tests/unittest.py", "raise RuntimeError('must not import')")
        try workflow("python3 tests/checks.py")
        let shadow = try await inspect()
        XCTAssertNotNil(shadow.unavailableChecks["ci.coverage"])
    }
    func testUnavailableParserAndUnsupportedCommandForms() {
        XCTAssertNil(PythonUnittestInspection.importsIfUnittest(source, interpreter: "/nonexistent/repoman-python"))
        XCTAssertNil(PythonUnittestInspection.importsIfUnittest("not valid python !"))
        for command in ["python3 checks.py --help", "python3 checks.py || true", "echo python3 checks.py", "python3 $SOURCE.py", "python3 /tmp/checks.py", "python3 ../checks.py", "python3 checks.py; exit 0", "python3 -c 'unittest.main()'", "python3 -option.py", "python3 bad\"quote.py"] {
            XCTAssertNil(PythonUnittestInspection.literalScript(command), command)
        }
    }
    func testScriptBeforeCheckoutAndOtherJobCheckoutStayUnknown() async throws {
        try write("tests/checks.py", source)
        for workflow in [
            "on: push\njobs:\n  test:\n    steps:\n      - run: python3 tests/checks.py\n      - uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n",
            "on: push\njobs:\n  setup:\n    steps:\n      - uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n  test:\n    steps:\n      - run: python3 tests/checks.py\n"
        ] {
            try write(".github/workflows/ci.yml", workflow)
            let report = try await inspect()
            XCTAssertNotNil(report.unavailableChecks["ci.coverage"])
        }
    }

    func testPythonShellAndToleratedFailuresStayUnknown() async throws {
        try write("tests/checks.py", source)
        for suffix in ["\n        shell: python", "\n        continue-on-error: true"] {
            try workflow("python3 tests/checks.py" + suffix)
            let report = try await inspect()
            XCTAssertNotNil(report.unavailableChecks["ci.coverage"])
        }
    }

    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        _ = try GitRunner.run(["add", "--", path], at: root)
    }
    private func workflow(_ command: String, checkout: String = "", directory: String? = nil, jobGuard: String = "") throws {
        try write(".github/workflows/ci.yml", "on: push\njobs:\n  test:\n" + jobGuard + "    steps:\n      - uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" + checkout + "\n      - run: " + command + (directory.map { "\n        working-directory: " + $0 } ?? "") + "\n")
    }
    private func inspect() async throws -> RepositoryInspectionReport {
        let snapshot = RepositorySnapshot(url: root, name: "fixture", branch: "main", upstream: nil, remoteURL: nil,
            ahead: nil, behind: nil, changes: [], staleBranches: [], worktrees: [], commits: [], rootFiles: ["pyproject.toml"])
        return await RepositoryIssueCatalog(checks: [RepositoryCIChecks.checks().first { $0.id == "ci.coverage" }!]).inspect(snapshot)
    }
}
