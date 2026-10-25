import XCTest
@testable import RepoManCore

final class RepositoryCheckReportTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try GitRunner.run(["init", "-b", "main"], at: root)
        for (key, value) in [("user.name", "Fixture"), ("user.email", "fixture@example.invalid"),
                             ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] {
            _ = try GitRunner.run(["config", key, value], at: root)
        }
        try write("package.json", #"{"name":"fixture","version":"1.0.0","packageManager":"npm@10.0.0"}"#)
        _ = try GitRunner.run(["add", "package.json"], at: root)
        _ = try GitRunner.run(["commit", "-m", "Fixture"], at: root)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func write(_ path: String, _ text: String) throws {
        try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    func testSharedCheckerMatchesDashboardAndLeavesGitStateUntouched() async throws {
        let ids: Set<String> = ["dependencies.safeguards", "dependencies.lockfile"]
        let paths = [".git/index", ".git/HEAD", ".git/config", "package.json"]
        let before = try paths.map { try Data(contentsOf: root.appendingPathComponent($0)) }
        let snapshot = try GitRepositoryScanner.scan(root, includeDetails: false)
        let dashboard = await RepositoryIssueCatalog(checks: RepositoryIssueCatalog.standardChecks.filter { ids.contains($0.id) }).inspect(snapshot)
        let report = try await RepositoryChecker.run(at: root, checkIDs: ids)
        XCTAssertEqual(Set(report.checks.flatMap(\.findings).map(\.id)), Set(dashboard.findings().map(\.id)))
        XCTAssertEqual(report.exitCode, 1)
        XCTAssertNotNil(report.head)
        XCTAssertEqual(try paths.map { try Data(contentsOf: root.appendingPathComponent($0)) }, before)
        let decoded = try JSONSerialization.jsonObject(with: report.json()) as! [String: Any]
        XCTAssertEqual(decoded["schemaVersion"] as? Int, 1)
        XCTAssertNotNil(decoded["observedAt"])
    }

    func testReasonedExceptionsAppearOnlyWhenTheySuppressARealFinding() async throws {
        let initial = try await RepositoryChecker.run(at: root, checkIDs: ["dependencies.safeguards"])
        let subject = try XCTUnwrap(initial.checks.first?.findings.first?.subject)
        let policy: [String: Any] = ["version": 1, "exceptions": ["dependencies.safeguards": [subject: "Controlled fixture", "unused": "Unused exception"]]]
        try JSONSerialization.data(withJSONObject: policy).write(to: root.appendingPathComponent(".repoman.json"))
        let report = try await RepositoryChecker.run(at: root, checkIDs: ["dependencies.safeguards"])
        XCTAssertEqual(report.exitCode, 0)
        XCTAssertEqual(report.checks.first?.exceptions, [subject: "Controlled fixture"])
        XCTAssertTrue(try XCTUnwrap(report.checks.first).findings.isEmpty)
    }

    func testLocalModeSkipsAllRemoteLoadersAndMalformedPolicyIsIncomplete() async throws {
        _ = try GitRunner.run(["remote", "add", "origin", "https://github.com/fixture/private-fixture.git"], at: root)
        let report = try await RepositoryChecker.run(at: root)
        for check in report.checks where check.id == "ci.failing" || check.id.hasPrefix("github.") {
            XCTAssertEqual(check.status, "skipped")
            XCTAssertNotNil(check.reason)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/FETCH_HEAD").path))
        try write(".repoman.json", "invalid")
        let invalid = try await RepositoryChecker.run(at: root, checkIDs: ["dependencies.safeguards"])
        XCTAssertEqual(invalid.checks.first?.status, "incomplete")
        XCTAssertEqual(invalid.exitCode, 1)
    }

    func testPartialResultsRetainFindingsAndCannotReportClean() throws {
        let snapshot = try GitRepositoryScanner.scan(root, includeDetails: false)
        let finding = RepositoryFinding(repositoryID: snapshot.id, checkID: "fixture", title: "Detected",
                                        evidence: "Observed", category: .setup, symbol: "circle")
        let inspection = RepositoryInspectionReport(snapshot: snapshot, results: ["fixture": .partial([finding], "Other evidence unavailable")], checkOrder: ["fixture"])
        let report = RepositoryCheckReport(inspection, head: nil, checkerVersion: "fixture")
        XCTAssertEqual(report.exitCode, 1)
        XCTAssertEqual(report.checks.first?.status, "incomplete")
        XCTAssertEqual(report.checks.first?.findings.first?.id, finding.id)
    }

    func testInvalidSelectionAndUnapprovedRemoteCheckAreRejected() async throws {
        for ids: Set<String> in [["unknown"], ["github.description"]] {
            do { _ = try await RepositoryChecker.run(at: root, checkIDs: ids); XCTFail("Expected rejection") }
            catch {}
        }
    }

    func testMaintenanceTaskQuotesPathsAndRequiresFreshEvidence() {
        let finding = RepositoryFinding(repositoryID: "/tmp/it's a repo", checkID: "github.description", subject: "README",
                                        title: "Drift", evidence: "Observed", category: .documentation, symbol: "circle")
        let task = RepositoryMaintenanceTask.text(for: finding, observedAt: nil)
        XCTAssertTrue(task.contains("'/tmp/it'\\''s a repo'"))
        XCTAssertTrue(task.contains("--remote --format json"))
        XCTAssertTrue(task.contains("does not authorize"))
    }
}
