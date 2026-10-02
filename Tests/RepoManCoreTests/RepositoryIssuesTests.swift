import Foundation
import XCTest
@testable import RepoManCore

final class RepositoryIssuesTests: XCTestCase {
    private var root: URL!
    private let issues = RepositoryIssueCatalog()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RepoManIssues-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testIncompleteChecksSharePendingCountsWithoutBecomingFindings() throws {
        let snapshot = try GitRepositoryScanner.scan(repository("incomplete"))
        let finding = RepositoryFinding(repositoryID: snapshot.id, checkID: "git.pull", subject: "main",
            title: "Commits to pull", evidence: "3 commits are available.", category: .git, symbol: "arrow.down")
        let ciFinding = RepositoryFinding(repositoryID: snapshot.id, checkID: "ci.coverage",
            title: "Missing CI coverage", evidence: "No validation was found.", category: .ci, symbol: "checkmark.shield")
        let report = RepositoryInspectionReport(snapshot: snapshot, results: [
            "git.pull": .findings([finding]),
            "ci.coverage": .findings([ciFinding]),
            "files.secrets": .unavailable("Tracked text exceeds 1 MiB."),
            "dependencies.lockfileDrift": .unavailable("Python groups need resolver review.")
        ], checkOrder: ["git.pull", "ci.coverage", "files.secrets", "dependencies.lockfileDrift"])
        let incomplete = issues.incompleteItems(in: report)
        XCTAssertEqual(Set(incomplete.map { $0.finding.checkID }), ["files.secrets", "dependencies.lockfileDrift"])
        XCTAssertTrue(incomplete.allSatisfy { $0.isIncomplete && $0.task == nil && $0.finding.recipeIDs.isEmpty })
        XCTAssertEqual(incomplete.first { $0.finding.checkID == "dependencies.lockfileDrift" }?.finding.title,
            "Manifest and lockfile consistency")
        XCTAssertEqual(report.findings(), [finding, ciFinding])
        let visible = RepositoryIssueListItem.items(findings: report.findings(), tasks: []) + incomplete
        XCTAssertEqual(RepositoryIssueStatus.counts(in: visible), [.pending: 4])
        XCTAssertEqual(issues.incompleteItems(in: report, disabledChecks: ["files.secrets"]).map { $0.finding.checkID },
            ["dependencies.lockfileDrift"])
        let recovered = RepositoryInspectionReport(snapshot: snapshot, results: [
            "files.secrets": .findings([]), "dependencies.lockfileDrift": .findings([])
        ], checkOrder: ["files.secrets", "dependencies.lockfileDrift"])
        XCTAssertTrue(issues.incompleteItems(in: recovered).isEmpty)
    }

    func testIncompleteCheckDoesNotReplaceAnExistingRepairConversation() throws {
        let snapshot = try GitRepositoryScanner.scan(repository("conversation"))
        let check = try XCTUnwrap(issues.checks.first { $0.id == "files.secrets" })
        let finding = RepositoryFinding(repositoryID: snapshot.id, checkID: check.id,
            title: check.title, evidence: "Original evidence", category: check.category, symbol: check.symbol)
        var task = RepairTask(finding: finding, repository: snapshot, prompt: "Review the finding")
        task.state = .running
        let incomplete = RepositoryIssueListItem(incompleteCheck: check, repositoryID: snapshot.id, reason: "File too large")
        let visible = RepositoryIssueListItem.items(findings: [], tasks: [task], includeCompleted: true) + [incomplete]
        XCTAssertEqual(visible.count, 2)
        XCTAssertEqual(Set(visible.map(\.id)).count, 2)
        XCTAssertEqual(visible.first?.task?.id, task.id)
        XCTAssertEqual(RepositoryIssueStatus.counts(in: visible), [.processing: 1, .pending: 1])
    }

    func testFileChecksRecognizeVariantsAndDoNotTreatUnknownAsMissing() throws {
        let repo = try repository("files")
        try write("ReadMe.rst", "Docs", in: repo)
        try write("LICENCE.txt", "Terms", in: repo)
        try write(".gitignore", "ignored/", in: repo)
        let snapshot = try GitRepositoryScanner.scan(repo)
        XCTAssertFalse(issues.findings(in: snapshot).contains { $0.checkID.hasPrefix("files.") })
        let unknown = RepositorySnapshot(url: repo, name: "files", branch: "main", upstream: nil, remoteURL: nil,
                                         ahead: nil, behind: nil, changes: [], staleBranches: [], worktrees: [], commits: [])
        XCTAssertEqual(issues.findings(in: unknown).map(\.checkID), ["inspection.files"])
    }

    func testFinishedLicenseRepairRemainsInIssueListAfterRefreshAndReload() throws {
        let repo = try repository("license", initialFiles: ["README.md", ".gitignore"])
        let before = try GitRepositoryScanner.scan(repo)
        let finding = try XCTUnwrap(issues.findings(in: before).first { $0.checkID == "files.license" })
        var task = RepairTask(finding: finding, repository: before, prompt: "Add MIT License")
        task.state = .running
        let running = RepositoryIssueListItem.items(findings: issues.findings(in: before), tasks: [task], includeCompleted: true)
        XCTAssertEqual(running.first { $0.finding.id == finding.id }?.task?.id, task.id)

        try write("LICENSE", "MIT License", in: repo)
        let after = try GitRepositoryScanner.scan(repo)
        let verification = issues.verify(finding, in: after)
        guard case .absent = verification else { return XCTFail("License finding should be resolved") }
        task.state = .resolved
        task.verification = verification
        task.upsertConversation(RepairConversationEntry(id: "reply", kind: .assistant, text: "Added LICENSE."))
        let storage = RepairTaskStorage(url: root.appendingPathComponent("repairs/tasks.json"))
        try storage.save([task])

        let currentFindings = issues.findings(in: after)
        let visible = RepositoryIssueListItem.items(findings: currentFindings, tasks: try storage.load(), includeCompleted: true)
        let finished = try XCTUnwrap(visible.first { $0.task?.id == task.id })
        XCTAssertEqual(finished.finding, finding)
        XCTAssertEqual(finished.task?.state, .resolved)
        XCTAssertEqual(finished.task?.conversation, task.conversation)
        XCTAssertFalse(finished.isArchived)
        XCTAssertEqual(visible.filter { $0.finding.id == finding.id }.count, 1)
        // Finished rows remain selectable without becoming outstanding findings again.
        XCTAssertFalse(RepositoryIssueListItem.items(findings: currentFindings, tasks: [task])
            .contains { $0.finding.id == finding.id })
    }

    func testDivergenceProducesOneFindingAndWorktreesAreInformational() {
        let snapshot = RepositorySnapshot(url: root, name: "repo", branch: "feature", upstream: "origin/feature", remoteURL: nil,
                                           ahead: 2, behind: 3, changes: [], staleBranches: ["old"], worktrees: ["linked"], commits: [],
                                           rootFiles: ["README.md", ".gitignore", "LICENSE"])
        XCTAssertEqual(issues.findings(in: snapshot).map(\.checkID), ["git.diverged", "git.staleBranches", "git.worktrees"])
        XCTAssertEqual(issues.findings(in: snapshot).first?.recipeIDs, ["git.inspect"])
        let informational = issues.findings(in: snapshot, disabledChecks: ["git.diverged"])
        XCTAssertEqual(informational.count, 2)
        XCTAssertTrue(informational.allSatisfy { $0.severity == .information })
        XCTAssertTrue(informational[0].evidence.contains("old"))
        XCTAssertTrue(informational[1].evidence.contains("linked"))
    }

    func testDirectoriesNamedLikeDocumentsDoNotSatisfyFileChecks() throws {
        let repo = try repository("directories")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("README.md"), withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".gitignore"), withIntermediateDirectories: false)
        let findings = issues.findings(in: try GitRepositoryScanner.scan(repo))
        XCTAssertTrue(findings.contains { $0.checkID == "files.readme" })
        XCTAssertTrue(findings.contains { $0.checkID == "files.gitignore" })
    }

    func testUnknownUpstreamCountsRemainVisibleAsUnknown() {
        let snapshot = RepositorySnapshot(url: root, name: "unknown", branch: "main", upstream: "origin/main", remoteURL: nil,
                                          ahead: nil, behind: nil, changes: [], staleBranches: [], worktrees: [], commits: [],
                                          rootFiles: ["README.md", ".gitignore", "LICENSE"])
        XCTAssertEqual(issues.findings(in: snapshot).map(\.checkID), ["inspection.comparison"])
    }

    func testCustomDetectorUsesStableIdentityAndCanReturnMultipleSubjects() throws {
        let repo = try repository("custom")
        let check = RepositoryCheck(id: "custom.check", title: "Custom", category: .setup, symbol: "doc") { s in
            ["a", "b"].map { RepositoryFinding(repositoryID: s.id, checkID: "custom.check", subject: $0,
                                               title: "Custom finding", evidence: "Evidence", category: .setup, symbol: "doc") }
        }
        let catalog = RepositoryIssueCatalog(checks: [check])
        let first = catalog.findings(in: try GitRepositoryScanner.scan(repo))
        let second = catalog.findings(in: try GitRepositoryScanner.scan(repo))
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(Set(first.map(\.id)).count, 2)
    }

    func testInspectionReportsProgressAndFindingsBeforeSlowChecksFinish() async {
        let snapshot = RepositorySnapshot(url: root, name: "progress", branch: "main", upstream: nil, remoteURL: nil,
                                          ahead: nil, behind: nil, changes: [], staleBranches: [], worktrees: [], commits: [])
        let gate = InspectionTestGate()
        // Unblock on failure too, so a scheduler regression fails instead of hanging the suite.
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(2)); await gate.open() } catch {}
        }
        defer { watchdog.cancel() }
        let recorder = InspectionProgressRecorder()
        let catalog = RepositoryIssueCatalog(checks: [
            RepositoryCheck(id: "fast", title: "Fast", category: .setup, symbol: "doc", inspect: { context in
                [RepositoryFinding(repositoryID: context.snapshot.id, checkID: "fast", title: "Found early",
                                   evidence: "Evidence", category: .setup, symbol: "doc")]
            }),
            RepositoryCheck(id: "slow", title: "Slow", category: .setup, symbol: "doc", inspect: { _ in
                await gate.wait()
                return []
            }),
            RepositoryCheck(id: "unavailable", title: "Unavailable", category: .setup, symbol: "doc", inspect: { _ in
                throw GitError.failed("Unavailable")
            }),
            RepositoryCheck(id: "empty", title: "Empty", category: .setup, symbol: "doc", detect: { _ in [] }),
            RepositoryCheck(id: "next-batch", title: "Next batch", category: .setup, symbol: "doc", detect: { _ in [] })
        ])
        let final = await catalog.inspect(snapshot, onProgress: { report in
            await recorder.append(report)
            if report.results["next-batch"] != nil { await gate.open() }
        })
        let reports = await recorder.reports
        XCTAssertEqual(reports.map { $0.results.count }, Array(0...5))
        XCTAssertTrue(reports.allSatisfy { $0.checkOrder.count == 5 })
        XCTAssertTrue(reports.contains { !$0.findings().isEmpty && $0.results["slow"] == nil })
        XCTAssertTrue(reports.contains { $0.results["next-batch"] != nil && $0.results["slow"] == nil })
        XCTAssertEqual(final.unavailableChecks["unavailable"], "Unavailable")
        XCTAssertEqual(final.findings().map(\.title), ["Found early"])
        XCTAssertEqual(reports.last?.results.count, final.results.count)
    }

    func testEmptyInspectionReportsZeroChecks() async {
        let snapshot = RepositorySnapshot(url: root, name: "empty", branch: "main", upstream: nil, remoteURL: nil,
                                          ahead: nil, behind: nil, changes: [], staleBranches: [], worktrees: [], commits: [])
        let recorder = InspectionProgressRecorder()
        let report = await RepositoryIssueCatalog(checks: []).inspect(snapshot, onProgress: { await recorder.append($0) })
        let reports = await recorder.reports
        XCTAssertEqual(reports.count, 1)
        XCTAssertTrue(report.results.isEmpty)
        XCTAssertTrue(report.checkOrder.isEmpty)
    }

    private func repository(_ name: String, initialFiles: [String] = []) throws -> URL {
        let repo = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-b", "main"], at: repo)
        try configure(repo)
        if !initialFiles.isEmpty {
            for file in initialFiles { try write(file, "initial\n", in: repo) }
            try git(["add", "."], at: repo)
            try git(["commit", "-m", "Initial"], at: repo)
        }
        return repo
    }

    private func configure(_ repo: URL) throws {
        try git(["config", "user.name", "RepoMan Test"], at: repo)
        try git(["config", "user.email", "repoman@example.invalid"], at: repo)
        try git(["config", "commit.gpgsign", "false"], at: repo)
        try git(["config", "core.hooksPath", "/dev/null"], at: repo)
    }

    private func remoteRepositories() throws -> (URL, URL) {
        let remote = root.appendingPathComponent("origin.git")
        try git(["init", "--bare", remote.path], at: root)
        let repo = try repository("repo", initialFiles: ["a.txt"])
        try git(["remote", "add", "origin", remote.path], at: repo)
        try git(["push", "-u", "origin", "main"], at: repo)
        let other = root.appendingPathComponent("other")
        try git(["clone", "-b", "main", remote.path, other.path], at: root)
        try configure(other)
        return (repo, other)
    }

    private func write(_ path: String, _ text: String, in repo: URL) throws {
        try text.write(to: repo.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }
    private func git(_ arguments: [String], at repo: URL) throws { _ = try GitRunner.run(arguments, at: repo) }
    private func text(_ arguments: [String], at repo: URL) throws -> String { try GitRunner.text(arguments, at: repo) }
}

private actor InspectionProgressRecorder {
    var reports: [RepositoryInspectionReport] = []
    func append(_ report: RepositoryInspectionReport) { reports.append(report) }
}

private actor InspectionTestGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
