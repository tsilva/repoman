import Foundation
import XCTest
@testable import RepoManCore

final class GitRepositoryScannerTests: XCTestCase {
    func testScansDivergenceChangesAndLinkedWorktree() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let remote = root.appendingPathComponent("origin.git")
        let repo = root.appendingPathComponent("repo")
        let other = root.appendingPathComponent("other")
        let worktree = root.appendingPathComponent("linked-worktree")
        try git(["init", "--bare", remote.path], in: root)
        try git(["clone", remote.path, repo.path], in: root)
        try git(["switch", "-c", "main"], in: repo)
        try "initial\n".write(to: repo.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try git(["add", "tracked.txt"], in: repo)
        try git(["commit", "-m", "Initial"], in: repo)
        try git(["push", "-u", "origin", "main"], in: repo)

        try git(["clone", "-b", "main", remote.path, other.path], in: root)
        try "remote\n".write(to: other.appendingPathComponent("remote.txt"), atomically: true, encoding: .utf8)
        try git(["add", "remote.txt"], in: other)
        try git(["commit", "-m", "Remote"], in: other)
        try git(["push"], in: other)

        try "local\n".write(to: repo.appendingPathComponent("local.txt"), atomically: true, encoding: .utf8)
        try git(["add", "local.txt"], in: repo)
        try git(["commit", "-m", "Local"], in: repo)
        try git(["fetch", "origin"], in: repo)
        try git(["worktree", "add", "-b", "scratch", worktree.path, "main"], in: repo)

        try "initial\nchanged\n".write(to: repo.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try "one\ntwo\n".write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)

        let discovered = try GitRepositoryScanner.repositories(in: root)
        let names = Set(discovered.map(\.lastPathComponent))
        XCTAssertTrue(names.contains("repo"))
        XCTAssertTrue(names.contains("other"))
        XCTAssertFalse(names.contains("origin.git"))

        let snapshot = try GitRepositoryScanner.scan(repo)
        XCTAssertEqual(snapshot.branch, "main")
        XCTAssertEqual(snapshot.ahead, 1)
        XCTAssertEqual(snapshot.behind, 1)
        XCTAssertEqual(snapshot.worktrees.count, 1)
        XCTAssertEqual(snapshot.changedFileCount, 2)
        XCTAssertEqual(snapshot.changes.first(where: { $0.path == "tracked.txt" })?.added, 1)
        XCTAssertEqual(snapshot.changes.first(where: { $0.path == "new.txt" })?.added, 2)
        XCTAssertEqual(snapshot.commits.first?.subject, "Local")

        let summary = try GitRepositoryScanner.scan(repo, includeDetails: false)
        XCTAssertFalse(summary.detailsLoaded)
        XCTAssertEqual(summary.changedFileCount, 2)
        XCTAssertTrue(summary.commits.isEmpty)
        XCTAssertNil(summary.changes.first(where: { $0.path == "tracked.txt" })?.added)
    }

    func testRenameAppearsOnceUnderItsNewName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-b", "main"], in: root)
        try "hello\n".write(to: root.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
        try git(["add", "old.txt"], in: root)
        try git(["commit", "-m", "Initial"], in: root)
        try git(["mv", "old.txt", "new.txt"], in: root)

        let snapshot = try GitRepositoryScanner.scan(root)
        XCTAssertEqual(snapshot.changes.map(\.path), ["new.txt"])
        XCTAssertEqual(snapshot.changes.first?.kind, .modified)
    }

    private func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_AUTHOR_NAME"] = "RepoMan Test"
        environment["GIT_AUTHOR_EMAIL"] = "repoman@example.invalid"
        environment["GIT_COMMITTER_NAME"] = "RepoMan Test"
        environment["GIT_COMMITTER_EMAIL"] = "repoman@example.invalid"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " ")) failed")
    }
}
