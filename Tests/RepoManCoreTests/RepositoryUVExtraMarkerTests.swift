import Foundation
import XCTest
@testable import RepoManCore

final class RepositoryUVExtraMarkerTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RepoManExtra-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try GitRunner.run(["init", "-b", "main"], at: root)
        _ = try GitRunner.run(["config", "user.name", "Test"], at: root)
        _ = try GitRunner.run(["config", "user.email", "test@example.com"], at: root)
        _ = try GitRunner.run(["commit", "--allow-empty", "-m", "Initial"], at: root)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testNativeUVExtraGuardAndMinorVersionNormalization() async throws {
        // uv 0.11.13 emits this environment-first marker for a Python 3.10 dev extra.
        for marker in [
            "python_full_version < '3.11' and extra == 'dev'",
            "extra == 'dev' and python_version < '3.11'",
            "('dev' == extra) and (python_full_version < '3.11')"
        ] {
            try fixture(marker: marker)
            let report = try await inspect()
            XCTAssertTrue(report.findings().isEmpty, marker)
            XCTAssertTrue(report.unavailableChecks.isEmpty, "\(marker): \(report.unavailableChecks)")
        }
    }
    func testConjoinedEnvironmentTermsKeepTheirMeaning() async throws {
        try fixture(requirement: "tomli>=2.2.0; python_version < '3.11' and sys_platform == 'linux'",
                    marker: "(sys_platform == 'linux' and extra == 'dev') and python_full_version < '3.11'")
        let report = try await inspect()
        XCTAssertTrue(report.findings().isEmpty)
        XCTAssertTrue(report.unavailableChecks.isEmpty)
    }
    func testChangedOptionalRequirementRemainsRealDrift() async throws {
        try fixture(requirement: "tomli>=3; python_version < '3.11'")
        let report = try await inspect()
        XCTAssertEqual(report.findings().count, 1)
        XCTAssertTrue(report.unavailableChecks.isEmpty)
    }
    func testChangedPythonConditionRemainsRealDrift() async throws {
        for marker in [
            "python_full_version < '3.12' and extra == 'dev'",
            "python_full_version <= '3.11' and extra == 'dev'",
            "python_full_version < '3.11.1' and extra == 'dev'"
        ] {
            try fixture(marker: marker)
            let report = try await inspect()
            XCTAssertEqual(report.findings().count, 1, marker)
            XCTAssertTrue(report.unavailableChecks.isEmpty, marker)
        }
    }
    func testAddedConditionOrRemovedExtraGuardIsRealDrift() async throws {
        for (requirement, marker) in [
            ("tomli>=2.2.0", "python_full_version < '3.11' and extra == 'dev'"),
            ("tomli>=2.2.0; python_version < '3.11'", "python_full_version < '3.11'")
        ] {
            try fixture(requirement: requirement, marker: marker)
            let report = try await inspect()
            XCTAssertEqual(report.findings().count, 1)
            XCTAssertTrue(report.unavailableChecks.isEmpty)
        }
    }
    func testUnknownExtraCannotBecomeAPass() async throws {
        try fixture(marker: "python_full_version < '3.11' and extra == 'missing'")
        let report = try await inspect()
        XCTAssertTrue(report.findings().isEmpty)
        XCTAssertNotNil(report.unavailableChecks["dependencies.lockfileDrift"])
    }
    func testAmbiguousOrMultipleExtraGuardsRemainUnknown() async throws {
        for marker in [
            "python_full_version < '3.11' or extra == 'dev'",
            "python_full_version < '3.11' and extra != 'dev'",
            "extra == 'dev' and extra == 'dev' and python_version < '3.11'",
            "extra == 'dev' and extra == 'other' and python_version < '3.11'",
            "(extra == 'dev' or extra == 'other') and python_version < '3.11'"
        ] {
            try fixture(marker: marker)
            let report = try await inspect()
            XCTAssertTrue(report.findings().isEmpty, marker)
            XCTAssertNotNil(report.unavailableChecks["dependencies.lockfileDrift"], marker)
        }
    }
    func testExtraVariablesInsideProjectRequirementsRemainUnsupported() async throws {
        for table in ["project", "project.optional-dependencies"] {
            let declaration = "tomli>=2.2.0; python_version < '3.11' and extra == 'dev'"
            try fixture(requirement: declaration)
            if table == "project" {
                try write("pyproject.toml", "[project]\nname='app'\ndependencies=[\"\(declaration)\"]\n")
            }
            let report = try await inspect()
            XCTAssertTrue(report.findings().isEmpty)
            XCTAssertNotNil(report.unavailableChecks["dependencies.lockfileDrift"])
        }
    }
    private func fixture(requirement: String = "tomli>=2.2.0; python_version < '3.11'",
                         marker: String = "python_full_version < '3.11' and extra == 'dev'") throws {
        try write("pyproject.toml", """
        [project]
        name = 'app'
        [project.optional-dependencies]
        dev = ["\(requirement)"]
        """)
        try write("uv.lock", """
        version = 1
        [[package]]
        name = 'app'
        source = { virtual = '.' }
        [package.metadata]
        requires-dist = [{name = 'tomli', specifier = '>=2.2.0', marker = "\(marker)"}]
        provides-extras = ['dev']
        """)
    }
    private func inspect() async throws -> RepositoryInspectionReport {
        let snapshot = RepositorySnapshot(url: root, name: "test", branch: "main", upstream: nil,
            remoteURL: nil, ahead: nil, behind: nil, changes: [], staleBranches: [], worktrees: [], commits: [],
            rootFiles: try FileManager.default.contentsOfDirectory(atPath: root.path))
        return await RepositoryIssueCatalog(checks: RepositoryIssueCatalog.standardChecks.filter {
            $0.id == "dependencies.lockfileDrift"
        }).inspect(snapshot)
    }
    private func write(_ path: String, _ contents: String) throws {
        try contents.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }
}
