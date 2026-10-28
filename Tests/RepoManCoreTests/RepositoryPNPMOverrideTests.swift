import Foundation
import XCTest
@testable import RepoManCore

final class RepositoryPNPMOverrideTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RepoManPNPM-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try GitRunner.run(["init", "-b", "main"], at: root)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testWorkspaceOverridesPassButWrongImporterAndOverrideMetadataFail() async throws {
        try write("package.json", #"{"packageManager":"pnpm@10.17.1","dependencies":{"sharp":"^0.35.3"}}"#)
        try write("pnpm-workspace.yaml", "overrides:\n  sharp: 0.35.5\n")
        try write("pnpm-lock.yaml", lock())
        var report = try await inspect()
        XCTAssertEqual(report.status(for: "dependencies.lockfileDrift"), .passed)

        try write("pnpm-lock.yaml", lock(specifier: "0.35.4"))
        report = try await inspect()
        XCTAssertEqual(report.status(for: "dependencies.lockfileDrift"), .findings)
        XCTAssertTrue(report.findings().first?.evidence.contains("dependencies.sharp") == true)

        try write("pnpm-lock.yaml", lock())
        try write("pnpm-workspace.yaml", "overrides:\n  sharp: 0.35.6\n")
        report = try await inspect()
        XCTAssertEqual(report.status(for: "dependencies.lockfileDrift"), .findings)
        XCTAssertTrue(report.findings().first?.evidence.contains("override declarations") == true)
    }

    func testWorkspaceChildInheritsRootOverridesAndUnrelatedDriftSurvives() async throws {
        try write("package.json", #"{"packageManager":"pnpm@10.17.1"}"#)
        try write("packages/app/package.json", #"{"dependencies":{"sharp":"^0.35.3","other":"^1"}}"#)
        try write("pnpm-workspace.yaml", "packages:\n  - packages/*\noverrides:\n  sharp: 0.35.5\n")
        try write("pnpm-lock.yaml", "lockfileVersion: '9.0'\noverrides:\n  sharp: 0.35.5\nimporters:\n  .: {}\n  packages/app:\n    dependencies:\n      sharp:\n        specifier: 0.35.5\n        version: 0.35.5\n      other:\n        specifier: ^1\n        version: 1.0.0\n")
        _ = try GitRunner.run(["add", "."], at: root)
        var report = try await inspect()
        XCTAssertEqual(report.status(for: "dependencies.lockfileDrift"), .passed)
        try write("packages/app/package.json", #"{"dependencies":{"sharp":"^0.35.3","other":"^2"}}"#)
        report = try await inspect()
        XCTAssertEqual(report.findings().first?.subject, "packages/app/package.json")
        XCTAssertTrue(report.findings().first?.evidence.contains("dependencies.other") == true)
    }

    func testManifestOverridesAndRootDependencyReferences() async throws {
        try write("package.json", #"{"packageManager":"pnpm@10.17.1","dependencies":{"sharp":"^0.35.3","source":"0.35.5"},"pnpm":{"overrides":{"sharp":"$source"}}}"#)
        let sourceEntry = "      source:\n        specifier: 0.35.5\n        version: 0.35.5\n"
        // pnpm serializes the resolved reference, not the literal $source string.
        try write("pnpm-lock.yaml", lock() + sourceEntry)
        var report = try await inspect()
        XCTAssertEqual(report.status(for: "dependencies.lockfileDrift"), .passed)
        try write("package.json", #"{"packageManager":"pnpm@10.17.1","dependencies":{"sharp":"^0.35.3"},"pnpm":{"overrides":{"sharp":"$source"}}}"#)
        report = try await inspect()
        XCTAssertEqual(report.status(for: "dependencies.lockfileDrift"), .incomplete)
    }

    func testTransitiveOverrideMetadataDriftIsNotHiddenByUnchangedDirectDependencies() async throws {
        try write("package.json", #"{"packageManager":"pnpm@10.17.1","dependencies":{"sharp":"^0.35.3"}}"#)
        try write("pnpm-workspace.yaml", "overrides:\n  'parent>other': 2.0.0\n")
        try write("pnpm-lock.yaml", lock(specifier: "^0.35.3").replacingOccurrences(of: "  sharp: 0.35.5", with: "  'parent>other': 2.0.0"))
        var report = try await inspect()
        XCTAssertEqual(report.status(for: "dependencies.lockfileDrift"), .passed)
        try write("pnpm-workspace.yaml", "overrides:\n  'parent>other': 3.0.0\n")
        report = try await inspect()
        XCTAssertEqual(report.status(for: "dependencies.lockfileDrift"), .findings)
    }

    func testQualifiedOverrideWithChangedSpecifierStaysUnknown() async throws {
        try write("package.json", #"{"packageManager":"pnpm@10.17.1","dependencies":{"sharp":"^0.35.3"}}"#)
        for selector in ["sharp@^0.35.3", "sharp@>=0.35.3", "parent@1>sharp", "parent@>=1>sharp@>=0.35.3"] {
            try write("pnpm-workspace.yaml", "overrides:\n  '\(selector)': 0.35.5\n")
            try write("pnpm-lock.yaml", lock().replacingOccurrences(of: "  sharp: 0.35.5", with: "  '\(selector)': 0.35.5"))
            let report = try await inspect()
            XCTAssertEqual(report.status(for: "dependencies.lockfileDrift"), .incomplete, selector)
            XCTAssertTrue(report.findings().isEmpty)
        }
    }

    func testConflictingAndInlineOverrideSourcesStayUnknownWithoutValues() async throws {
        try write("package.json", #"{"packageManager":"pnpm@10.17.1","dependencies":{"sharp":"^0.35.3"},"pnpm":{"overrides":{"sharp":"secret-canary"}}}"#)
        try write("pnpm-lock.yaml", lock())
        for workspace in ["overrides:\n  sharp: 0.35.5\n", "overrides: {sharp: secret-canary}\n"] {
            try write("pnpm-workspace.yaml", workspace)
            let report = try await inspect()
            XCTAssertEqual(report.status(for: "dependencies.lockfileDrift"), .incomplete)
            XCTAssertFalse(report.unavailableChecks.values.joined().contains("secret-canary"))
        }
    }

    private func lock(specifier: String = "0.35.5", override: String = "0.35.5") -> String {
        "lockfileVersion: '9.0'\noverrides:\n  sharp: \(override)\nimporters:\n  .:\n    dependencies:\n      sharp:\n        specifier: \(specifier)\n        version: 0.35.5\n"
    }
    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    private func inspect() async throws -> RepositoryInspectionReport {
        let snapshot = RepositorySnapshot(url: root, name: "fixture", branch: "main", upstream: nil, remoteURL: nil,
            ahead: nil, behind: nil, changes: [], staleBranches: [], worktrees: [], commits: [], checkedAt: Date(),
            rootFiles: try FileManager.default.contentsOfDirectory(atPath: root.path))
        return await RepositoryIssueCatalog(checks: RepositoryLockfileChecks.checks()).inspect(snapshot)
    }
}
