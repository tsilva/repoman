import Foundation
import XCTest
@testable import RepoManCore

final class RepositoryUVProjectPolicyTests: XCTestCase {
    private var root: URL!
    private let exclusions = "constraint-dependencies=['mistralai!=2.4.6','guardrails-ai!=0.10.1']\n"
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("repoman-uv-policy-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        _ = try GitRunner.run(["init", "-b", "main"], at: root)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func write(_ path: String, _ text: String) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
        _ = try GitRunner.run(["add", "--", path], at: root)
    }
    private func project(_ name: String = "fixture", constraints: Bool = true) -> String {
        "[project]\nname='" + name + "'\nversion='1.0.0'\n[tool.uv]\n" + (constraints ? exclusions : "")
    }
    private func inspect() async throws -> RepositoryInspectionReport {
        let snapshot = RepositorySnapshot(url: root, name: "fixture", branch: "main", upstream: nil, remoteURL: nil,
            ahead: nil, behind: nil, changes: [], staleBranches: [], worktrees: [], commits: [],
            rootFiles: try FileManager.default.contentsOfDirectory(atPath: root.path))
        return await RepositoryIssueCatalog(checks: RepositoryDependencyChecks.checks().filter { $0.id == "dependencies.safeguards" }).inspect(snapshot)
    }
    func testProjectConstraintsRemainEffectiveBesideUVSettingsFile() async throws {
        try write("pyproject.toml", project())
        try write("uv.toml", "exclude-newer='7 days'\n")
        let report = try await inspect()
        XCTAssertEqual(report.status(for: "dependencies.safeguards"), .passed)
    }
    func testUVSettingsOnlyConstraintsCannotHideMissingProjectProtection() async throws {
        try write("pyproject.toml", project(constraints: false))
        try write("uv.toml", "exclude-newer='7 days'\n" + exclusions)
        let report = try await inspect()
        XCTAssertEqual(report.status(for: "dependencies.safeguards"), .findings)
        XCTAssertTrue(report.findings().first?.evidence.contains("mistralai!=2.4.6") == true)
        XCTAssertTrue(report.findings().first?.evidence.contains("guardrails-ai!=0.10.1") == true)
    }
    func testSettingsAgePrecedenceRemainsIndependentOfProjectConstraints() async throws {
        try write("pyproject.toml", project() + "exclude-newer='7 days'\n")
        try write("uv.toml", "exclude-newer='1 day'\n")
        let report = try await inspect()
        XCTAssertEqual(report.status(for: "dependencies.safeguards"), .findings)
        XCTAssertTrue(report.findings().first?.evidence.contains("seven days") == true)
        XCTAssertFalse(report.findings().first?.evidence.contains("do not exclude") == true)
    }
    func testWorkspaceMembersUseRootMetadataAndIgnoreMemberSettings() async throws {
        try write("pyproject.toml", project() + "[tool.uv.workspace]\nmembers=['packages/*']\n")
        try write("uv.toml", "exclude-newer='7 days'\n")
        try write("packages/member/pyproject.toml", project("member", constraints: false))
        try write("packages/member/uv.toml", "exclude-newer='1 day'\n")
        let report = try await inspect()
        XCTAssertEqual(report.status(for: "dependencies.safeguards"), .passed)
    }
    func testMemberConstraintsCannotMaskMissingWorkspaceRootConstraints() async throws {
        try write("pyproject.toml", project(constraints: false) + "[tool.uv.workspace]\nmembers=['packages/*']\n")
        try write("uv.toml", "exclude-newer='7 days'\n")
        try write("packages/member/pyproject.toml", project("member"))
        let report = try await inspect()
        XCTAssertEqual(report.status(for: "dependencies.safeguards"), .findings)
        XCTAssertEqual(Set(report.findings().map(\.subject)), ["pyproject.toml", "packages/member/pyproject.toml"])
    }
    func testIndependentNestedProjectCannotBorrowAncestorConstraints() async throws {
        try write("pyproject.toml", project())
        try write("uv.toml", "exclude-newer='7 days'\n")
        try write("packages/member/pyproject.toml", project("member", constraints: false))
        try write("packages/member/uv.toml", "exclude-newer='7 days'\n")
        let report = try await inspect()
        XCTAssertEqual(report.findings().map(\.subject), ["packages/member/pyproject.toml"])
    }
    func testExcludedWorkspaceProjectUsesItsOwnProjectMetadata() async throws {
        try write("pyproject.toml", project() + "[tool.uv.workspace]\nmembers=['packages/*']\nexclude=['packages/member']\n")
        try write("uv.toml", "exclude-newer='7 days'\n")
        try write("packages/member/pyproject.toml", project("member", constraints: false))
        try write("packages/member/uv.toml", "exclude-newer='7 days'\n")
        let report = try await inspect()
        XCTAssertEqual(report.findings().map(\.subject), ["packages/member/pyproject.toml"])
    }
}
