import Foundation
import XCTest
@testable import RepoManCore

final class RepositoryIssuesTests: XCTestCase {
    private var root: URL!
    private let issues = RepositoryIssueCatalog()
    private let actions = RepositoryActionCatalog()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RepoManIssues-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
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

    func testDivergenceProducesOneFindingAndWorktreesAreInformational() {
        let snapshot = RepositorySnapshot(url: root, name: "repo", branch: "feature", upstream: "origin/feature", remoteURL: nil,
                                           ahead: 2, behind: 3, changes: [], staleBranches: ["old"], worktrees: ["linked"], commits: [],
                                           rootFiles: ["README.md", ".gitignore", "LICENSE"])
        XCTAssertEqual(issues.findings(in: snapshot).map(\.checkID), ["git.diverged", "git.staleBranches", "git.worktrees"])
        XCTAssertEqual(issues.findings(in: snapshot).first?.actionIDs, ["git.inspect"])
        let informational = issues.findings(in: snapshot, disabledChecks: ["git.diverged"])
        XCTAssertEqual(informational.count, 2)
        XCTAssertTrue(informational.allSatisfy { $0.severity == .information && $0.actionIDs.isEmpty })
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
        XCTAssertThrowsError(try actions.prepare("files.readme", at: repo))
        XCTAssertThrowsError(try actions.prepare("files.gitignore", at: repo))
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

    func testFilePreviewIsReadOnlyAndEditableDraftIsVerifiedAfterExecution() throws {
        let repo = try repository("python")
        try write("pyproject.toml", "[project]\nname = 'example'\n", in: repo)
        var plan = try actions.prepare("files.gitignore", at: repo)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent(".gitignore").path))
        XCTAssertTrue(plan.content!.contains(".venv/"))
        XCTAssertFalse(plan.content!.contains("node_modules/"))
        plan.content! += "local-output/\n"
        let result = try actions.execute(plan)
        XCTAssertTrue(try String(contentsOf: repo.appendingPathComponent(".gitignore"), encoding: .utf8).contains("local-output/"))
        XCTAssertFalse(issues.findings(in: result.snapshot).contains { $0.checkID == "files.gitignore" })
        XCTAssertTrue(issues.findings(in: result.snapshot).contains { $0.checkID == "git.changes" })
        XCTAssertThrowsError(try actions.execute(plan))
    }

    func testAlternateIgnoredReadmeCreatedAfterPreviewIsNotOverwritten() throws {
        let repo = try repository("readme")
        let plan = try actions.prepare("files.readme", at: repo)
        try write(".git/info/exclude", "README.rst\n", in: repo)
        try write("README.rst", "Keep this", in: repo)
        XCTAssertThrowsError(try actions.execute(plan))
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("README.rst"), encoding: .utf8), "Keep this")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("README.md").path))
    }

    func testExistingIgnoredSymlinkIsNeverOverwritten() throws {
        let repo = try repository("symlink")
        let plan = try actions.prepare("files.gitignore", at: repo)
        let outside = root.appendingPathComponent("outside.txt")
        try "Keep outside".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: repo.appendingPathComponent(".gitignore"), withDestinationURL: outside)
        XCTAssertThrowsError(try actions.execute(plan))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "Keep outside")
    }

    func testSelectedCommitPreservesOtherStagedChangesAndUsesLiteralPaths() throws {
        let repo = try repository("commit", initialFiles: ["a.txt", "b.txt"])
        try write("a.txt", "selected\n", in: repo)
        try write("b.txt", "leave staged\n", in: repo)
        try git(["add", "b.txt"], at: repo)
        try write("literal[1].txt", "new\n", in: repo)
        let plan = try actions.prepare("git.commit", at: repo, input: .init(paths: ["a.txt", "literal[1].txt"], message: "Selected files"))
        XCTAssertTrue(plan.preview.contains("+new"))
        let result = try actions.execute(plan)
        XCTAssertEqual(try text(["show", "HEAD:a.txt"], at: repo), "selected")
        XCTAssertEqual(try text(["show", "HEAD:b.txt"], at: repo), "initial")
        XCTAssertEqual(try text(["diff", "--cached", "--name-only"], at: repo), "b.txt")
        XCTAssertEqual(result.snapshot.changedFileCount, 1)
    }

    func testPartialStagingIncludesFullSelectedContents() throws {
        let repo = try repository("partial", initialFiles: ["a.txt"])
        try write("a.txt", "staged\n", in: repo)
        try git(["add", "a.txt"], at: repo)
        try write("a.txt", "full working copy\n", in: repo)
        let plan = try actions.prepare("git.commit", at: repo, input: .init(paths: ["a.txt"], message: "Full file"))
        XCTAssertTrue(plan.preview.contains("full working copy"))
        _ = try actions.execute(plan)
        XCTAssertEqual(try text(["show", "HEAD:a.txt"], at: repo), "full working copy")
    }

    func testFileContentChangeInvalidatesCommitPreviewEvenWhenStatusIsUnchanged() throws {
        let repo = try repository("stale", initialFiles: ["a.txt"])
        try write("a.txt", "first\n", in: repo)
        let plan = try actions.prepare("git.commit", at: repo, input: .init(paths: ["a.txt"], message: "Preview"))
        let before = try text(["status", "--porcelain"], at: repo)
        try write("a.txt", "second\n", in: repo)
        XCTAssertEqual(try text(["status", "--porcelain"], at: repo), before)
        XCTAssertThrowsError(try actions.execute(plan))
        XCTAssertEqual(try text(["log", "-1", "--format=%s"], at: repo), "Initial")
    }

    func testInitialCommitCannotIncludeUnselectedStagedFiles() throws {
        let repo = try repository("initial")
        try write("a.txt", "a", in: repo)
        try write("b.txt", "b", in: repo)
        try git(["add", "b.txt"], at: repo)
        XCTAssertThrowsError(try actions.prepare("git.commit", at: repo, input: .init(paths: ["a.txt"], message: "Initial")))
        let plan = try actions.prepare("git.commit", at: repo, input: .init(paths: ["a.txt", "b.txt"], message: "Initial"))
        _ = try actions.execute(plan)
        XCTAssertEqual(try text(["ls-tree", "--name-only", "HEAD"], at: repo), "a.txt\nb.txt")
    }

    func testRenameAndDetachedHeadCommitAreBlockedBeforeStaging() throws {
        let repo = try repository("rename", initialFiles: ["a.txt"])
        try git(["mv", "a.txt", "renamed.txt"], at: repo)
        XCTAssertThrowsError(try actions.prepare("git.commit", at: repo, input: .init(paths: ["renamed.txt"], message: "Rename")))
        try git(["reset", "--hard", "HEAD"], at: repo)
        try git(["checkout", "--detach"], at: repo)
        try write("a.txt", "change", in: repo)
        XCTAssertThrowsError(try actions.prepare("git.commit", at: repo, input: .init(paths: ["a.txt"], message: "Detached")))
    }

    func testFastForwardPullAndPushUseConfiguredUpstream() throws {
        let (repo, other) = try remoteRepositories()
        try write("remote.txt", "remote\n", in: other)
        try git(["add", "."], at: other)
        try git(["commit", "-m", "Remote change"], at: other)
        try git(["push"], at: other)
        let pull = try actions.prepare("git.pull", at: repo)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("remote.txt").path))
        let pulled = try actions.execute(pull)
        XCTAssertEqual(pulled.snapshot.behind, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent("remote.txt").path))
        try write("local.txt", "local\n", in: repo)
        try git(["add", "."], at: repo)
        try git(["commit", "-m", "Local change"], at: repo)
        let push = try actions.prepare("git.push", at: repo)
        XCTAssertTrue(push.preview.contains("Local change"))
        XCTAssertEqual(try actions.execute(push).snapshot.ahead, 0)
        try git(["fetch"], at: other)
        XCTAssertEqual(try text(["rev-parse", "origin/main"], at: other), try text(["rev-parse", "HEAD"], at: repo))
    }

    func testPullBlocksDirtyTreeAndNewRemoteCommitsAfterPreview() throws {
        let (repo, other) = try remoteRepositories()
        try write("remote.txt", "first\n", in: other)
        try git(["add", "."], at: other)
        try git(["commit", "-m", "First remote"], at: other)
        try git(["push"], at: other)
        try write("a.txt", "dirty", in: repo)
        XCTAssertThrowsError(try actions.prepare("git.pull", at: repo))
        try git(["restore", "a.txt"], at: repo)
        let plan = try actions.prepare("git.pull", at: repo)
        let originalHead = try text(["rev-parse", "HEAD"], at: repo)
        try write("remote.txt", "second\n", in: other)
        try git(["add", "."], at: other)
        try git(["commit", "-m", "Second remote"], at: other)
        try git(["push"], at: other)
        XCTAssertThrowsError(try actions.execute(plan))
        XCTAssertEqual(try text(["rev-parse", "HEAD"], at: repo), originalHead)
    }

    func testLicenseRequiresExplicitInputAndDemoCannotExecute() throws {
        let repo = try repository("license")
        XCTAssertThrowsError(try actions.prepare("files.license", at: repo))
        let plan = try actions.prepare("files.license", at: repo, input: .init(copyrightHolder: "Example Author"))
        XCTAssertTrue(plan.content!.contains("Example Author"))
        XCTAssertTrue(plan.content!.contains("MIT License"))
        _ = try actions.execute(plan)
        let demo = try actions.demonstrationPlan("files.readme", snapshot: GitRepositoryScanner.scan(repo), input: .init())
        XCTAssertThrowsError(try actions.execute(demo))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("README.md").path))
    }

    func testActionRegistryCanBeExtendedWithoutChangingTheRunner() throws {
        let repo = try repository("extended")
        let custom = RepositoryActionDefinition(id: "custom.inspect", title: "Custom", applyTitle: "Inspect", mutatesRepository: false,
                                                prepare: { url, input in
            try RepositoryActionPlan.capture(at: url, actionID: "custom.inspect", title: "Custom", explanation: "Read-only", preview: "Custom preview", input: input)
        }, execute: { plan in
            RepositoryActionResult(message: "Custom result", snapshot: try GitRepositoryScanner.scan(plan.repositoryURL))
        })
        let catalog = RepositoryActionCatalog(actions: [custom])
        XCTAssertEqual(try catalog.execute(catalog.prepare("custom.inspect", at: repo)).message, "Custom result")
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
