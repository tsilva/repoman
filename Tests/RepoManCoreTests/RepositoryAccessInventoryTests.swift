import Foundation
import XCTest
@testable import RepoManCore

final class RepositoryAccessInventoryTests: XCTestCase {
    func testAccessInventoryUsesCurrentFilesAndIgnoresLegacyFormats() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RepoManAccess-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try GitRunner.run(["init", "-b", "main"], at: root)
        // Legacy contents must not be parsed, echoed, or accepted as an inventory.
        for path in [".keyenv.toml", ".infisical.json"] {
            try "secret-canary: deliberately invalid metadata".write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        func inspect() async throws -> RepositoryInspectionReport {
            let snapshot = RepositorySnapshot(url: root, name: "fixture", branch: "main", upstream: nil, remoteURL: nil,
                ahead: nil, behind: nil, changes: [], staleBranches: [], worktrees: [], commits: [], checkedAt: Date(),
                rootFiles: try FileManager.default.contentsOfDirectory(atPath: root.path))
            return await RepositoryIssueCatalog(checks: RepositoryAccessChecks.checks().filter { $0.id == "access.configuration" }).inspect(snapshot)
        }
        var report = try await inspect()
        XCTAssertEqual(report.status(for: "access.configuration"), .notApplicable)
        XCTAssertTrue(report.findings().isEmpty)
        XCTAssertTrue(report.unavailableChecks.isEmpty)
        XCTAssertFalse(String(describing: report).contains("secret-canary"))

        let inventory = "version = 1\n[profiles.wandb]\ndescription = 'Notebook logging'\nvariables = ['WANDB_API_KEY']\n"
        let path = root.appendingPathComponent(".access.toml")
        try inventory.write(to: path, atomically: true, encoding: .utf8)
        report = try await inspect()
        XCTAssertEqual(report.status(for: "access.configuration"), .passed)
        XCTAssertTrue(report.findings().isEmpty)
        XCTAssertTrue(report.unavailableChecks.isEmpty)

        try inventory.replacingOccurrences(of: "version = 1", with: "version = true").write(to: path, atomically: true, encoding: .utf8)
        report = try await inspect()
        XCTAssertEqual(report.status(for: "access.configuration"), .findings)
        XCTAssertEqual(report.findings().first?.subject, ".access.toml")
        XCTAssertFalse(String(describing: report).contains("secret-canary"))
    }
}
