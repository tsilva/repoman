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
        XCTAssertEqual(decoded["schemaVersion"] as? Int, 2)
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
        XCTAssertEqual(invalid.exitCode, 3)
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

    func testInformationalResultsDoNotFailAndKeepTheirEvidence() throws {
        let snapshot = try GitRepositoryScanner.scan(root, includeDetails: false)
        let info = RepositoryFinding(repositoryID: snapshot.id, checkID: "git.worktrees", title: "Linked worktrees",
            evidence: "A linked checkout exists.", category: .git, severity: .information, symbol: "square.on.square")
        let results: [String: RepositoryCheckResult] = ["git.worktrees": .findings([info])]
        let report = RepositoryCheckReport(RepositoryInspectionReport(snapshot: snapshot, results: results,
            checkOrder: ["git.worktrees"]), head: nil, checkerVersion: "fixture")
        XCTAssertEqual(report.exitCode, 0)
        XCTAssertEqual(report.checks.first?.status, "information")
        XCTAssertEqual(report.checks.first?.findings.first?.evidence, info.evidence)
        XCTAssertEqual(RepositoryIssueListItem(finding: info).status, .information)
        XCTAssertEqual(RepositoryIssueStatus.counts(in: [.init(finding: info)]), [.information: 1])
        let unknown = RepositoryCheckReport(RepositoryInspectionReport(snapshot: snapshot,
            results: ["git.worktrees": .partial([info], "Other worktrees unavailable")],
            checkOrder: ["git.worktrees"]), head: nil, checkerVersion: "fixture")
        XCTAssertEqual(unknown.exitCode, 3)
        XCTAssertEqual(unknown.checks.first?.status, "incomplete")
        let violation = RepositoryFinding(repositoryID: snapshot.id, checkID: "fixture", title: "Actual problem",
            evidence: "Violation", category: .setup, symbol: "circle")
        let mixed = RepositoryCheckReport(RepositoryInspectionReport(snapshot: snapshot,
            results: ["fixture": .partial([info, violation], "Other inputs unavailable")],
            checkOrder: ["fixture"]), head: nil, checkerVersion: "fixture")
        XCTAssertEqual(mixed.exitCode, 1)
        XCTAssertEqual(mixed.checks.first?.findings.count, 2)
    }

    func testPythonCoverageDiagnosticIdentifiesOnlyUnsupportedDeclarations() async throws {
        _ = try GitRunner.run(["rm", "package.json"], at: root)
        for (declaration, expected) in [
            ("[dependency-groups]\ndev = ['pytest']", "dependency-groups"),
            ("[project]\nname = 'fixture'\ndynamic = ['dependencies']", "project.dynamic"),
            ("[tool.uv.sources]\nexample = { path = '../private-path' }", "tool.uv.sources"),
            ("[tool.uv]\ndev-dependencies = ['pytest']", "tool.uv.dev-dependencies")
        ] {
            try write("pyproject.toml", declaration)
            try write("uv.lock", "version = 1")
            _ = try GitRunner.run(["add", "pyproject.toml", "uv.lock"], at: root)
            let report = try await RepositoryChecker.run(at: root, checkIDs: ["dependencies.lockfileDrift"])
            let check = try XCTUnwrap(report.checks.first)
            XCTAssertEqual(check.status, "incomplete")
            XCTAssertEqual(report.exitCode, 3)
            let reason = try XCTUnwrap(check.reason)
            XCTAssertTrue(reason.hasPrefix("pyproject.toml:"), reason)
            XCTAssertTrue(reason.contains(expected), reason)
            XCTAssertTrue(reason.contains("uv lock --check"), reason)
            XCTAssertFalse(reason.contains("private-path"))
            for absent in ["project.dynamic", "dependency-groups", "tool.uv.sources", "tool.uv.dev-dependencies"] where absent != expected {
                XCTAssertFalse(reason.contains(absent), reason)
            }
        }
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

    func testUnfetchedComparisonsRetainLocalCountsWithoutClaimingRemoteHealth() async throws {
        _ = try GitRunner.run(["remote", "add", "origin", root.appendingPathComponent("unreachable-remote").path], at: root)
        _ = try GitRunner.run(["update-ref", "refs/remotes/origin/main", "HEAD"], at: root)
        _ = try GitRunner.run(["config", "branch.main.remote", "origin"], at: root)
        _ = try GitRunner.run(["config", "branch.main.merge", "refs/heads/main"], at: root)
        let noDifference = try await RepositoryChecker.run(at: root, checkIDs: ["git.push", "git.pull", "git.diverged"])
        XCTAssertEqual(noDifference.exitCode, 3)
        XCTAssertTrue(noDifference.checks.allSatisfy { $0.status == "incomplete" })
        _ = try GitRunner.run(["commit", "--allow-empty", "-m", "Local work"], at: root)
        let report = try await RepositoryChecker.run(at: root, checkIDs: ["git.push"])
        let finding = try XCTUnwrap(report.checks.first?.findings.first)
        XCTAssertTrue(finding.title.contains("provisional"))
        XCTAssertEqual(finding.severity, .information)
        XCTAssertTrue(finding.evidence.contains("1 commits"))
        XCTAssertTrue(finding.evidence.contains("local remote-tracking refs"))
        var snapshot = try GitRepositoryScanner.scan(root, includeDetails: false)
        snapshot.fetchedAt = Date()
        let catalog = RepositoryIssueCatalog(checks: RepositoryIssueCatalog.standardChecks.filter { $0.id == "git.push" })
        let fresh = await catalog.inspect(snapshot)
        XCTAssertEqual(fresh.status(for: "git.push"), .findings)
        XCTAssertEqual(fresh.findings().first?.severity, .attention)
        snapshot.fetchedAt = Date().addingTimeInterval(-301)
        XCTAssertFalse(snapshot.hasFreshRemoteComparison)
        let expired = await catalog.inspect(snapshot)
        XCTAssertEqual(expired.status(for: "git.push"), .incomplete)
        snapshot.fetchedAt = Date(); snapshot.fetchError = "Fetch failed"
        XCTAssertFalse(snapshot.hasFreshRemoteComparison)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/FETCH_HEAD").path))
    }

    func testSiblingTargetsSupportGitFilesWithoutOpeningContentsOrFollowingEscapes() throws {
        let parent = root.deletingLastPathComponent()
        let sibling = parent.appendingPathComponent("sibling-" + UUID().uuidString)
        let metadata = parent.appendingPathComponent("metadata-" + UUID().uuidString)
        let outside = parent.appendingPathComponent("private-" + UUID().uuidString)
        defer {
            for url in [sibling, metadata, outside] { try? FileManager.default.removeItem(at: url) }
        }
        _ = try GitRunner.run(["init", "--separate-git-dir", metadata.path, sibling.path], at: root)
        try "Private fixture contents".write(to: outside, atomically: true, encoding: .utf8)
        try "Sibling fixture".write(to: sibling.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: sibling.appendingPathComponent("escape.md"), withDestinationURL: outside)
        let context = RepositoryInspectionContext(snapshot: try GitRepositoryScanner.scan(root, includeDetails: false))
        let prefix = "../" + sibling.lastPathComponent
        XCTAssertTrue(try context.localTargetExists(prefix + "/README.md"))
        XCTAssertTrue(try context.localTargetExists(prefix))
        XCTAssertFalse(try context.localTargetExists(prefix + "/missing.md"))
        XCTAssertThrowsError(try context.readText(prefix + "/README.md"))
        XCTAssertThrowsError(try context.localTargetExists(prefix + "/escape.md")) { error in
            XCTAssertFalse(error.localizedDescription.contains(outside.path))
            XCTAssertFalse(error.localizedDescription.contains("Private fixture contents"))
        }
        XCTAssertThrowsError(try context.localTargetExists("../../outside.md"))
        XCTAssertThrowsError(try context.localTargetExists("../unavailable-" + UUID().uuidString + "/README.md"))
        let alias = root.appendingPathComponent("sibling-link")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: sibling)
        XCTAssertThrowsError(try context.localTargetExists("sibling-link/README.md"))
    }

    func testRemoteReportReflectsRefreshAndFailureWithoutExposingErrors() throws {
        var snapshot = try GitRepositoryScanner.scan(root, includeDetails: false)
        func report(_ snapshot: RepositorySnapshot) -> RepositoryCheckReport {
            RepositoryCheckReport(RepositoryInspectionReport(snapshot: snapshot, results: [:], checkOrder: []),
                                  head: nil, checkerVersion: "fixture")
        }
        XCTAssertTrue(report(snapshot).remoteRefs.contains("No configured Git remotes"))
        _ = try GitRunner.run(["remote", "add", "origin", root.appendingPathComponent("remote").path], at: root)
        snapshot = try GitRepositoryScanner.scan(root, includeDetails: false)
        XCTAssertTrue(report(snapshot).remoteRefs.contains("--fetch"))
        snapshot.fetchedAt = Date()
        XCTAssertTrue(report(snapshot).remoteRefs.contains("successfully refreshed"))
        snapshot.fetchError = "private-provider-error"
        XCTAssertTrue(report(snapshot).remoteRefs.contains("failed"))
        XCTAssertFalse(report(snapshot).remoteRefs.contains("private-provider-error"))
        let result = RepositoryCheck.result([], for: "git.push", snapshot: snapshot)
        guard case .partial(_, let reason) = result else { return XCTFail("A failed fetch cannot establish remote health") }
        XCTAssertTrue(reason.contains("failed"))
        XCTAssertFalse(reason.contains("private-provider-error"))
    }
}
