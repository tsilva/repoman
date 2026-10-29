import Foundation
import XCTest
@testable import RepoManCore

final class CurrentDependencyInventoryTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RepoManCurrentLocks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try GitRunner.run(["init", "-b", "main"], at: root)
        for (key, value) in [("user.name", "Fixture"), ("user.email", "fixture@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] {
            _ = try GitRunner.run(["config", key, value], at: root)
        }
        try write("README.md", "Fixture\n"); _ = try GitRunner.run(["add", "."], at: root)
        _ = try GitRunner.run(["commit", "-m", "Fixture"], at: root)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    private var lock: String { #"{"lockfileVersion":3,"packages":{"node_modules/child":{"version":"1.0.0","resolved":"https://registry.npmjs.org/child/-/child-1.0.0.tgz"}}}"# }
    private func context() throws -> RepositoryInspectionContext { .init(snapshot: try GitRepositoryScanner.scan(root, includeDetails: false)) }
    func testUntrackedCompleteLocksAndManifestsAreCapturedAndHashed() throws {
        try write("package.json", #"{"name":"fixture","dependencies":{"child":"1.0.0"}}"#); try write("package-lock.json", lock)
        let context = try context(), capture = try CurrentDependencyInventory.capture(context)
        XCTAssertTrue(capture.reasons.isEmpty); XCTAssertEqual(capture.entries.map(\.identity), ["npm:child@1.0.0"])
        XCTAssertEqual(Set(capture.inputs.map(\.path)), ["package.json", "package-lock.json"])
        XCTAssertTrue(capture.inputs.allSatisfy { $0.sha256.count == 64 }); XCTAssertTrue(capture.unchanged(context))
    }
    func testKnownInventorySurvivesAnotherMalformedLock() throws {
        try write("package-lock.json", lock); try write("other/package-lock.json", "invalid")
        let capture = try CurrentDependencyInventory.capture(context())
        XCTAssertEqual(capture.entries.map(\.identity), ["npm:child@1.0.0"]); XCTAssertFalse(capture.reasons.isEmpty)
    }
    func testPythonLockCannotCoverMissingJavaScriptComponentLock() throws {
        try write("pyproject.toml", "[project]\nname='fixture'\nversion='1.0.0'\n")
        try write("uv.lock", "version=1\n[[package]]\nname='fixture'\nversion='1.0.0'\nsource={virtual='.'}\n")
        try write("web/package.json", #"{"name":"web"}"#)
        XCTAssertTrue(try CurrentDependencyInventory.capture(context()).reasons.contains { $0.contains("web/package.json") })
    }
    func testSameSizeInputMutationNewLocksAndHeadChangesInvalidateCapture() throws {
        try write("package.json", #"{"name":"fixture"}"#); try write("package-lock.json", lock)
        let context = try context(), capture = try CurrentDependencyInventory.capture(context)
        try write("package-lock.json", lock.replacingOccurrences(of: "1.0.0", with: "2.0.0")); XCTAssertFalse(capture.unchanged(context))
        try write("package-lock.json", lock); try write("other/package-lock.json", lock); XCTAssertFalse(capture.unchanged(context))
        try FileManager.default.removeItem(at: root.appendingPathComponent("other"))
        _ = try GitRunner.run(["commit", "--allow-empty", "-m", "Changed head"], at: root); XCTAssertFalse(capture.unchanged(context))
    }
    func testRequirementsOnlyInputIsIncompleteAndNeverAnEmptyClearInventory() throws {
        try write("requirements.txt", "child==1.0.0\n")
        let capture = try CurrentDependencyInventory.capture(context())
        XCTAssertTrue(capture.hasDeclarations); XCTAssertTrue(capture.lockfiles.isEmpty); XCTAssertFalse(capture.reasons.isEmpty)
    }
    func testUnstagedRemovedLockLeavesMissingComponentCoverage() throws {
        try write("package.json", #"{"name":"fixture"}"#); try write("package-lock.json", lock)
        _ = try GitRunner.run(["add", "."], at: root); _ = try GitRunner.run(["commit", "-m", "Locked"], at: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("package-lock.json"))
        let capture = try CurrentDependencyInventory.capture(context())
        XCTAssertTrue(capture.lockfiles.isEmpty); XCTAssertFalse(capture.reasons.isEmpty)
    }
}
