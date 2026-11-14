import Foundation
import XCTest
@testable import RepoManCore

final class RepositoryAccessInventoryTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RepoManAccess-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try GitRunner.run(["init", "-b", "main"], at: root)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func write(_ text: String, path: String = ".runbox.yaml") throws {
        try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }
    private func inspect(_ id: String = "access.configuration") async throws -> RepositoryInspectionReport {
        let snapshot = RepositorySnapshot(url: root, name: "fixture", branch: "main", upstream: nil, remoteURL: nil,
            ahead: nil, behind: nil, changes: [], staleBranches: [], worktrees: [], commits: [], checkedAt: Date(),
            rootFiles: try FileManager.default.contentsOfDirectory(atPath: root.path))
        return await RepositoryIssueCatalog(checks: RepositoryAccessChecks.checks().filter { $0.id == id }).inspect(snapshot)
    }
    private let inventory = """
        version: 1
        default: catalog
        profiles:
          catalog:
            provider:
              type: infisical
              instance: https://fixture.invalid
            execution:
              argv:
              - '{python}'
              - '-m'
              - fixture
              arguments:
              - - catalog
            description: Nested execution/provider values are opaque to inventory inspection.
        """
    func testAbsentConfigurationDoesNotRequireRunboxOrAnEmptyInventory() async throws {
        let report = try await inspect()
        XCTAssertEqual(report.status(for: "access.configuration"), .notApplicable)
        XCTAssertTrue(report.findings().isEmpty)
    }
    func testBlockInventoryWithNestedCommandsAndPublicTrackedMetadata() async throws {
        try write(inventory)
        _ = try GitRunner.run(["add", ".runbox.yaml"], at: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: root.appendingPathComponent(".runbox.yaml").path)
        let report = try await inspect()
        XCTAssertEqual(report.status(for: "access.configuration"), .passed)
        XCTAssertTrue(report.unavailableChecks.isEmpty)
        let privacy = try await inspect("access.localPrivacy")
        XCTAssertEqual(privacy.status(for: "access.localPrivacy"), .notApplicable)
        XCTAssertTrue(privacy.findings().isEmpty)
    }
    func testMetadataOnlyBindingsAndBrokersNeedNoCommandDefault() async throws {
        for section in ["bindings", "brokers"] {
            try write("version: 1\n\(section):\n  metadata:\n    description: 'private-fixture-value'\n")
            let report = try await inspect()
            XCTAssertEqual(report.status(for: "access.configuration"), .passed)
            XCTAssertFalse(String(describing: report).contains("private-fixture-value"))
        }
    }
    func testBadVersionMissingDefaultEmptyInventoryAndUnknownFieldsAreFindings() async throws {
        for content in [inventory.replacingOccurrences(of: "version: 1", with: "version: true"),
                        inventory.replacingOccurrences(of: "default: catalog", with: "default: private-fixture-value"),
                        inventory.replacingOccurrences(of: "default: catalog\n", with: ""),
                        "version: 1\nprofiles: {}\n", "version: 1\ndefault: private-fixture-value\nbindings:\n  source: {}\n",
                        inventory + "\nprivate-fixture-value: hidden\n"] {
            try write(content)
            let report = try await inspect()
            XCTAssertEqual(report.status(for: "access.configuration"), .findings)
            XCTAssertFalse(report.findings().isEmpty)
            XCTAssertFalse(String(describing: report).contains("private-fixture-value"))
        }
    }
    func testUnsupportedAndDuplicateInventorySyntaxStaysIncompleteWithoutValues() async throws {
        for content in ["version: 1\nversion: 1\nbindings: {}\n", "version: 1\nbindings: &private-fixture-value {}\n",
                        "version: 1\nbindings:\n  duplicate: {}\n  duplicate: {}\n", "{\"version\":1,\"private-fixture-value\":1}",
                        "version: 1\nprofiles:\n\tbad: {}", "---\nversion: 1\n---\nversion: 1"] {
            try write(content)
            let report = try await inspect()
            XCTAssertNotNil(report.unavailableChecks["access.configuration"])
            XCTAssertFalse(String(describing: report).contains("private-fixture-value"))
        }
    }
    func testRetiredFilesAreReportedWithoutParsingAndSurviveAnIncompleteCurrentInventory() async throws {
        for name in [".access.toml", ".access.local.toml", ".infisical.yaml", ".infisical.json", ".keyenv.toml"] {
            try write("private-fixture-value: not metadata", path: name)
        }
        var report = try await inspect()
        XCTAssertEqual(report.findings().count, 5)
        XCTAssertFalse(String(describing: report).contains("private-fixture-value"))
        try write("private-fixture-value")
        report = try await inspect()
        XCTAssertEqual(report.findings().count, 5)
        XCTAssertNotNil(report.unavailableChecks["access.configuration"])
        XCTAssertFalse(String(describing: report).contains("private-fixture-value"))
    }
    func testSymlinkAndOversizedConfigurationAreIncompleteWithoutReadingOutsideFiles() async throws {
        let outside = root.deletingLastPathComponent().appendingPathComponent("private-fixture-value-" + UUID().uuidString)
        try inventory.write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        let path = root.appendingPathComponent(".runbox.yaml")
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: outside)
        var report = try await inspect()
        XCTAssertNotNil(report.unavailableChecks["access.configuration"])
        XCTAssertFalse(String(describing: report).contains(outside.path))
        try FileManager.default.removeItem(at: path)
        try write(String(repeating: "private-fixture-value", count: 4000))
        report = try await inspect()
        XCTAssertNotNil(report.unavailableChecks["access.configuration"])
        XCTAssertFalse(String(describing: report).contains("private-fixture-value"))
    }
    func testTooManyCommandProfilesIsNotAccepted() async throws {
        try write("version: 1\ndefault: p0\nprofiles:\n" + (0..<65).map { "  p\($0): {}" }.joined(separator: "\n"))
        let report = try await inspect()
        XCTAssertTrue(report.findings().first?.evidence.contains("64") == true)
    }
}
