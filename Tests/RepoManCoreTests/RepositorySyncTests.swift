import Foundation
import XCTest
@testable import RepoManCore

final class RepositorySyncTests: XCTestCase {
    private var root: URL!
    private var repo: URL { root.appendingPathComponent("repo") }
    private var remote: URL { root.appendingPathComponent("remote.git") }
    private var other: URL { root.appendingPathComponent("other") }
    private let identity = ["GIT_AUTHOR_NAME": "Sync Test", "GIT_AUTHOR_EMAIL": "sync@example.invalid",
                            "GIT_COMMITTER_NAME": "Sync Test", "GIT_COMMITTER_EMAIL": "sync@example.invalid"]

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "--bare", remote.path], at: root)
        try git(["init", "-b", "main", repo.path], at: root)
        try git(["config", "user.name", "Sync Test"])
        try git(["config", "user.email", "sync@example.invalid"])
        try git(["config", "commit.gpgsign", "false"])
        try git(["config", "core.hooksPath", root.appendingPathComponent("hooks").path])
        try write("initial\n", "tracked.txt")
        try git(["add", "."])
        try git(["commit", "-m", "Initial"])
        // Use a non-origin remote and different upstream branch to verify the destination.
        try git(["remote", "add", "backup", remote.path])
        try git(["push", "-u", "backup", "HEAD:published"])
        try git(["clone", "-b", "published", remote.path, other.path], at: root)
        try git(["config", "commit.gpgsign", "false"], at: other)
        try git(["config", "core.hooksPath", root.appendingPathComponent("hooks").path], at: other)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testCommitAndPushSelectedFilesPreservesExcludedIndexAndWorkingTree() throws {
        try git(["config", "push.followTags", "true"])
        try git(["tag", "-a", "extra", "-m", "Do not publish through Sync"])
        try write("selected\n", "tracked.txt")
        try write("staged\n", "excluded.txt")
        try git(["add", "excluded.txt"])
        try write("unstaged\n", "excluded.txt")
        let review = try RepositorySync.review(at: repo)
        let result = try RepositorySync.synchronize(review, selectedPaths: ["tracked.txt"], message: "Selected")
        XCTAssertEqual(result.ahead, 0)
        XCTAssertEqual(result.behind, 0)
        XCTAssertEqual(result.changes.map(\.path), ["excluded.txt"])
        XCTAssertEqual(try git(["show", ":excluded.txt"]), "staged")
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("excluded.txt")), "unstaged\n")
        XCTAssertEqual(try git(["show", "published:tracked.txt"], at: remote), "selected")
        XCTAssertThrowsError(try git(["show", "published:excluded.txt"], at: remote))
        XCTAssertThrowsError(try git(["show-ref", "--verify", "refs/tags/extra"], at: remote))
    }

    func testRejectsChangedFileAndChangedIndexAfterReview() throws {
        try write("first\n", "tracked.txt")
        var review = try RepositorySync.review(at: repo)
        try write("second\n", "tracked.txt")
        let head = try git(["rev-parse", "HEAD"])
        XCTAssertThrowsError(try RepositorySync.synchronize(review, selectedPaths: ["tracked.txt"], message: "Stale"))
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), head)
        review = try RepositorySync.review(at: repo)
        try git(["add", "tracked.txt"])
        XCTAssertThrowsError(try RepositorySync.synchronize(review, selectedPaths: ["tracked.txt"], message: "Stale"))
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), head)
    }

    func testDetectsNewIncomingCommitsBeforeCommittingPartialSelection() throws {
        try write("local\n", "tracked.txt")
        try write("keep\n", "keep.txt")
        let review = try RepositorySync.review(at: repo)
        let head = try git(["rev-parse", "HEAD"])
        try incoming("remote\n", path: "remote.txt")
        XCTAssertThrowsError(try RepositorySync.synchronize(review, selectedPaths: ["tracked.txt"], message: "Partial"))
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try git(["diff", "--cached"]), "")
    }

    func testCommitsAllChangesMergesIncomingAndPushesConfiguredUpstream() throws {
        try incoming("remote\n", path: "remote.txt")
        try write("local\n", "local.txt")
        let result = try RepositorySync.synchronize(RepositorySync.review(at: repo), selectedPaths: ["local.txt"], message: "Local")
        XCTAssertEqual(result.changedFileCount, 0)
        XCTAssertEqual(result.ahead, 0)
        XCTAssertEqual(result.behind, 0)
        XCTAssertEqual(try git(["show", "published:local.txt"], at: remote), "local")
        XCTAssertEqual(try git(["show", "published:remote.txt"], at: remote), "remote")
    }

    func testPullOnlyFastForwardsWithoutCreatingCommit() throws {
        try incoming("remote\n", path: "tracked.txt")
        let result = try RepositorySync.synchronize(RepositorySync.review(at: repo), selectedPaths: [], message: "")
        XCTAssertEqual(result.behind, 0)
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), try git(["rev-parse", "HEAD"], at: other))
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("tracked.txt")), "remote\n")
    }

    func testPushOnlyLeavesLocalUncommittedChangesAlone() throws {
        try git(["commit", "--allow-empty", "-m", "Local"])
        try write("uncommitted\n", "tracked.txt")
        let result = try RepositorySync.synchronize(RepositorySync.review(at: repo), selectedPaths: [], message: "")
        XCTAssertEqual(result.ahead, 0)
        XCTAssertEqual(result.changedFileCount, 1)
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("tracked.txt")), "uncommitted\n")
    }

    func testMergeConflictPreservesLocalCommitAndStopsPush() throws {
        try incoming("remote\n", path: "tracked.txt")
        try write("local\n", "tracked.txt")
        XCTAssertThrowsError(try RepositorySync.synchronize(RepositorySync.review(at: repo), selectedPaths: ["tracked.txt"], message: "Local"))
        XCTAssertEqual(try git(["log", "-1", "--format=%s"]), "Local")
        XCTAssertEqual(try git(["show", "published:tracked.txt"], at: remote), "remote")
        XCTAssertFalse(try git(["ls-files", "--unmerged"]).isEmpty)
        XCTAssertThrowsError(try RepositorySync.review(at: repo))
    }

    func testRejectedPushPreservesCommitAndCleanIndex() throws {
        let hooks = remote.appendingPathComponent("hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let hook = hooks.appendingPathComponent("pre-receive")
        try "#!/bin/sh\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try write("local\n", "tracked.txt")
        XCTAssertThrowsError(try RepositorySync.synchronize(RepositorySync.review(at: repo), selectedPaths: ["tracked.txt"], message: "Saved"))
        XCTAssertEqual(try git(["log", "-1", "--format=%s"]), "Saved")
        XCTAssertEqual(try git(["status", "--porcelain"]), "")
        XCTAssertEqual(try git(["show", "published:tracked.txt"], at: remote), "initial")
    }

    func testRenameAndLiteralPathspecNamesCommitCorrectly() throws {
        try git(["mv", "tracked.txt", "renamed.txt"])
        try write("literal\n", ":(glob)*.txt")
        let result = try RepositorySync.synchronize(RepositorySync.review(at: repo),
            selectedPaths: ["renamed.txt", ":(glob)*.txt"], message: "Rename and add")
        XCTAssertEqual(result.changedFileCount, 0)
        XCTAssertEqual(try git(["show", "published:renamed.txt"], at: remote), "initial")
        XCTAssertEqual(try git(["show", "published::(glob)*.txt"], at: remote), "literal")
        XCTAssertThrowsError(try git(["show", "published:tracked.txt"], at: remote))
    }

    func testBrokenUntrackedSymlinkCanBeReviewedAndCommitted() throws {
        try FileManager.default.createSymbolicLink(atPath: repo.appendingPathComponent("link").path,
                                                  withDestinationPath: "missing-target")
        let result = try RepositorySync.synchronize(RepositorySync.review(at: repo), selectedPaths: ["link"], message: "Link")
        XCTAssertEqual(result.changedFileCount, 0)
        XCTAssertEqual(try git(["show", "published:link"], at: remote), "missing-target")
    }

    func testChangedRemoteDestinationRejectsReviewedAction() throws {
        let review = try RepositorySync.review(at: repo)
        try git(["remote", "set-url", "backup", root.appendingPathComponent("different.git").path])
        XCTAssertThrowsError(try RepositorySync.synchronize(review, selectedPaths: [], message: ""))
    }

    func testMessageContextIncludesOnlySelectedChangesAndPreservesIndexAndHead() throws {
        try write("selected tracked content\n", "tracked.txt")
        try write("selected untracked content\n", "new.txt")
        try write("PRIVATE EXCLUDED CONTENT\n", "excluded.txt")
        try git(["add", "excluded.txt"])
        let status = try git(["status", "--porcelain"])
        let head = try git(["rev-parse", "HEAD"])
        let context = try RepositorySync.commitMessageContext(RepositorySync.review(at: repo), selectedPaths: ["tracked.txt", "new.txt"])
        XCTAssertTrue(context.contains("selected tracked content"))
        XCTAssertTrue(context.contains("selected untracked content"))
        XCTAssertFalse(context.contains("excluded.txt"))
        XCTAssertFalse(context.contains("PRIVATE EXCLUDED CONTENT"))
        XCTAssertEqual(try git(["status", "--porcelain"]), status)
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try git(["show", ":excluded.txt"]), "PRIVATE EXCLUDED CONTENT")
    }

    func testMessageContextHandlesRenamesSymlinksAndLiteralPathspecs() throws {
        try git(["mv", "tracked.txt", "renamed.txt"])
        try FileManager.default.createSymbolicLink(atPath: repo.appendingPathComponent("link").path, withDestinationPath: "missing-target")
        try write("literal selected content\n", ":(glob)*.txt")
        try write("excluded content\n", "excluded.txt")
        let context = try RepositorySync.commitMessageContext(RepositorySync.review(at: repo),
            selectedPaths: ["renamed.txt", "link", ":(glob)*.txt"])
        XCTAssertTrue(context.contains("renamed.txt"))
        XCTAssertTrue(context.contains("tracked.txt"))
        XCTAssertTrue(context.contains("missing-target"))
        XCTAssertTrue(context.contains("literal selected content"))
        XCTAssertFalse(context.contains("excluded content"))
    }

    func testMessageContextBoundsLargeDiffAndRejectsStaleOrEmptySelections() throws {
        try write(String(repeating: "large content é\n", count: 300), "tracked.txt")
        let review = try RepositorySync.review(at: repo)
        let context = try RepositorySync.commitMessageContext(review, selectedPaths: ["tracked.txt"], maximumBytes: 256)
        XCTAssertLessThanOrEqual(context.utf8.count, 256)
        XCTAssertTrue(context.contains("Additional diff content omitted"))
        XCTAssertThrowsError(try RepositorySync.commitMessageContext(review, selectedPaths: []))
        XCTAssertThrowsError(try RepositorySync.commitMessageContext(review, selectedPaths: ["excluded.txt"]))
        try write("new version\n", "tracked.txt")
        XCTAssertThrowsError(try RepositorySync.commitMessageContext(review, selectedPaths: ["tracked.txt"]))
    }

    func testRejectsDetachedMissingUpstreamBlankMessageAndBusyIndex() throws {
        try write("local\n", "tracked.txt")
        let review = try RepositorySync.review(at: repo)
        XCTAssertThrowsError(try RepositorySync.synchronize(review, selectedPaths: ["tracked.txt"], message: " \n"))
        try Data().write(to: repo.appendingPathComponent(".git/index.lock"))
        XCTAssertThrowsError(try RepositorySync.synchronize(review, selectedPaths: ["tracked.txt"], message: "Busy"))
        try FileManager.default.removeItem(at: repo.appendingPathComponent(".git/index.lock"))
        try git(["config", "--unset", "branch.main.remote"])
        XCTAssertThrowsError(try RepositorySync.review(at: repo))
        try git(["checkout", "--detach"])
        XCTAssertThrowsError(try RepositorySync.review(at: repo))
    }

    private func incoming(_ contents: String, path: String) throws {
        try contents.write(to: other.appendingPathComponent(path), atomically: true, encoding: .utf8)
        try git(["add", "--", path], at: other)
        try git(["commit", "-m", "Incoming"], at: other)
        try git(["push"], at: other)
    }

    private func write(_ contents: String, _ path: String) throws {
        try contents.write(to: repo.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    @discardableResult private func git(_ arguments: [String], at url: URL? = nil) throws -> String {
        String(decoding: try GitRunner.run(arguments, at: url ?? repo, environmentOverrides: identity), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
