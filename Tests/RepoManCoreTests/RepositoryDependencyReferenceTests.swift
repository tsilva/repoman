import Foundation
import XCTest
@testable import RepoManCore

final class RepositoryDependencyReferenceTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RepoManDependencyReferences-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try GitRunner.run(["init", "-b", "main"], at: root)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testMissingDeclaredDependencyScriptIsIncompleteRatherThanMissingSource() async throws {
        try write("package.json", #"{"dependencies":{"tool":"1.0.0"},"scripts":{"check":"node node_modules/tool/check.mjs"}}"#)
        let report = await inspect()
        XCTAssertTrue(report.findings().isEmpty)
        XCTAssertTrue(report.unavailableChecks["files.projectReferences"]?.contains("dependency-provided") == true)
        try write("node_modules/tool/check.mjs", "throw new Error('must never execute')")
        let installed = await inspect()
        XCTAssertTrue(installed.findings().isEmpty)
        XCTAssertNil(installed.unavailableChecks["files.projectReferences"])
    }
    func testMissingLocalSourceAndUndeclaredDependencyAreStillFindings() async throws {
        try write("package.json", #"{"dependencies":{"tool":"1.0.0"},"scripts":{"check":"node node_modules/tool/check.mjs && node scripts/missing.js && node node_modules/typo/check.mjs"}}"#)
        let report = await inspect()
        let evidence = report.findings().map(\.evidence).joined()
        XCTAssertTrue(evidence.contains("scripts/missing.js"))
        XCTAssertTrue(evidence.contains("node_modules/typo/check.mjs"))
        XCTAssertFalse(evidence.contains("node_modules/tool/check.mjs"))
        XCTAssertNotNil(report.unavailableChecks["files.projectReferences"])
    }
    func testExpoRouterEntryUsesFrameworkContractAndMissingInstallationStaysUnknown() async throws {
        try write("package.json", #"{"private":true,"dependencies":{"expo":"54.0.0","expo-router":"6.0.23"},"main":"expo-router/entry"}"#)
        let report = await inspect()
        XCTAssertTrue(report.findings().isEmpty)
        XCTAssertNotNil(report.unavailableChecks["files.projectReferences"])
        try write("node_modules/expo-router/entry.js", "throw new Error('must never execute')")
        let installed = await inspect()
        XCTAssertTrue(installed.findings().isEmpty)
        XCTAssertNil(installed.unavailableChecks["files.projectReferences"])
    }
    func testExpoContractDoesNotHideOrdinaryPackageEntriesOrTypos() async throws {
        for manifest in [
            #"{"private":true,"main":"expo-router/entry"}"#,
            #"{"dependencies":{"expo":"54.0.0","expo-router":"6.0.23"},"main":"expo-router/entry"}"#,
            #"{"private":true,"dependencies":{"expo":"54.0.0","expo-router":"6.0.23"},"main":"expo-router/typo"}"#,
            #"{"private":true,"dependencies":{"expo":"54.0.0","expo-router":"6.0.23"},"main":"./expo-router/entry"}"#,
            #"{"private":true,"dependencies":{"expo":"54.0.0","expo-router":"6.0.23"},"main":"index.js"}"#
        ] {
            try write("package.json", manifest)
            let report = await inspect()
            XCTAssertFalse(report.findings().isEmpty, manifest)
        }
    }
    func testNestedAndScopedDependencyScriptsAndExplicitMainRemainBounded() async throws {
        try write("packages/tool/package.json", #"{"devDependencies":{"@scope/tool":"1.0.0"},"main":"node_modules/@scope/tool/entry.js","scripts":{"check":"node ./node_modules/@scope/tool/check.mjs"}}"#)
        let report = await inspect()
        XCTAssertTrue(report.findings().isEmpty)
        XCTAssertNotNil(report.unavailableChecks["files.projectReferences"])
        try write("packages/tool/node_modules/@scope/tool/check.mjs", "throw new Error('must never execute')")
        try write("packages/tool/node_modules/@scope/tool/entry.js", "throw new Error('must never execute')")
        let installed = await inspect()
        XCTAssertTrue(installed.findings().isEmpty)
        XCTAssertNil(installed.unavailableChecks["files.projectReferences"])
    }
    func testEscapingDependencyPathsAndDynamicTargetsDoNotBecomePasses() async throws {
        for path in ["node_modules/tool/../../missing.js", "node_modules/$PACKAGE/check.mjs"] {
            let manifest: [String:Any] = ["dependencies":["tool":"1.0.0"],"scripts":["check":"node " + path]]
            try write("package.json", String(decoding: try JSONSerialization.data(withJSONObject: manifest), as: UTF8.self))
            let report = await inspect()
            XCTAssertTrue(!report.findings().isEmpty || report.unavailableChecks["files.projectReferences"] != nil)
        }
    }
    func testInstalledPackageWithMissingFileRemainsActionable() async throws {
        try write("package.json", #"{"dependencies":{"tool":"1.0.0"},"scripts":{"check":"node node_modules/tool/typo.mjs"}}"#)
        try write("node_modules/tool/package.json", #"{"name":"tool","version":"1.0.0"}"#)
        let report = await inspect()
        XCTAssertTrue(report.findings().first?.evidence.contains("Installed dependency target node_modules/tool/typo.mjs is missing") == true)
        XCTAssertNil(report.unavailableChecks["files.projectReferences"])
    }

    private func write(_ path: String, _ source: String) throws {
        let target = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try source.write(to: target, atomically: true, encoding: .utf8)
        if !path.split(separator: "/").contains("node_modules") { _ = try GitRunner.run(["add", "--", path], at: root) }
    }
    private func inspect() async -> RepositoryInspectionReport {
        let snapshot = RepositorySnapshot(url: root, name: "fixture", branch: "main", upstream: nil, remoteURL: nil,
            ahead: nil, behind: nil, changes: [], staleBranches: [], worktrees: [], commits: [], rootFiles: FileManager.default.fileExists(atPath: root.appendingPathComponent("package.json").path) ? ["package.json"] : [])
        return await RepositoryIssueCatalog(checks: RepositoryProjectReferenceChecks.checks()).inspect(snapshot)
    }
}
