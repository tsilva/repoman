import Foundation
import XCTest
@testable import RepoManCore

final class GitRepositoryScannerTests: XCTestCase {
    func testLastActivityUsesHEADCommitterDateInFullAndSummaryScans() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-b", "main"], in: root)
        for includeDetails in [true, false] {
            XCTAssertNil(try GitRepositoryScanner.scan(root, includeDetails: includeDetails).lastCommitAt)
        }
        try git(["commit", "--allow-empty", "--date=2020-01-01T00:00:00Z", "-m", "Initial"],
                in: root, committerDate: "2024-01-01T00:00:00Z")
        let expected = Date(timeIntervalSince1970: 1_704_067_200)
        // Scanning or detaching HEAD must not make an old commit look newly active.
        for detached in [false, true] {
            if detached { try git(["checkout", "--detach"], in: root) }
            for includeDetails in [true, false] {
                let snapshot = try GitRepositoryScanner.scan(root, includeDetails: includeDetails)
                XCTAssertEqual(snapshot.lastCommitAt, expected)
                XCTAssertEqual(snapshot.commits.count, includeDetails ? 1 : 0)
            }
        }
    }

    func testBlacklistExcludesArchivedTargetsAndKeepsVisibleActiveRepositories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("repositories")
        let archived = folder.appendingPathComponent(".archived")
        let archivedRepo = archived.appendingPathComponent("gymrec")
        let active = folder.appendingPathComponent("active")
        for repo in [archivedRepo, active] {
            try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("gymrec"), withDestinationURL: archivedRepo)

        // Discovery already skips directory symlinks; the matcher also checks their targets.
        XCTAssertEqual(try GitRepositoryScanner.repositories(in: folder).map(\.lastPathComponent), ["active"])
        XCTAssertTrue(RepositoryPathBlacklist(paths: [".archived"], relativeTo: folder)
            .contains(folder.appendingPathComponent("gymrec")))
        XCTAssertEqual(try GitRepositoryScanner.repositories(in: archived).map(\.lastPathComponent), ["gymrec"])
        XCTAssertEqual(try GitRepositoryScanner.repositories(in: folder, excludingPaths: [".archived"]).map(\.lastPathComponent), ["active"])
        XCTAssertEqual(try GitRepositoryScanner.repositories(in: archived, excludingPaths: [".archived"]), [])
        XCTAssertEqual(try GitRepositoryScanner.repositories(in: folder, excludingPaths: [archived.path]).map(\.lastPathComponent), ["active"])
        XCTAssertEqual(try GitRepositoryScanner.repositories(in: folder, excludingPaths: [folder.path]), [])
    }

    func testBlacklistUsesPathBoundariesAndResolvesRelativePathsAndAliases() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("repositories")
        let excluded = folder.appendingPathComponent("archive")
        let sibling = folder.appendingPathComponent("archive-other")
        for repo in [excluded, sibling] {
            try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        }
        let alias = root.appendingPathComponent("archive-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: excluded)

        for rule in [excluded.path + "/", "./archive", "./unused/../archive", alias.path, " archive "] {
            XCTAssertEqual(try GitRepositoryScanner.repositories(in: folder, excludingPaths: [rule]).map(\.lastPathComponent), ["archive-other"], rule)
        }
        XCTAssertEqual(try GitRepositoryScanner.repositories(in: folder, excludingPaths: ["", "  "]).count, 2)
        let names = RepositoryPathBlacklist(paths: [".archived"], relativeTo: folder)
        XCTAssertTrue(names.contains(folder.appendingPathComponent("container/.archived/repo")))
        XCTAssertFalse(names.contains(folder.appendingPathComponent("container/.archived-other/repo")))
        let home = RepositoryPathBlacklist(paths: ["~/archive"], relativeTo: folder)
        XCTAssertTrue(home.contains(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("archive/repo")))
        XCTAssertFalse(home.contains(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("archive-other/repo")))
    }

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
        XCTAssertFalse(names.contains("linked-worktree"))

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

    func testDiscoveryKeepsSeparateGitDirectoryAndExcludesWorktreesWithoutTheirMainRepository() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("repositories")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let repo = folder.appendingPathComponent("repo")
        let gitDirectory = root.appendingPathComponent("metadata")
        try git(["init", "-b", "main", "--separate-git-dir", gitDirectory.path, repo.path], in: root)
        try git(["commit", "--allow-empty", "-m", "Initial"], in: repo)
        let linked = folder.appendingPathComponent("linked-worktree")
        try git(["worktree", "add", "-b", "scratch", linked.path], in: repo)

        let outside = root.appendingPathComponent("outside")
        try git(["init", "-b", "main", outside.path], in: root)
        try git(["commit", "--allow-empty", "-m", "Initial"], in: outside)
        let detached = folder.appendingPathComponent("detached-worktree")
        try git(["worktree", "add", "--detach", detached.path], in: outside)

        let nested = folder.appendingPathComponent("container/nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try git(["init", nested.path], in: root)
        let hidden = folder.appendingPathComponent(".hidden-repo")
        try git(["init", hidden.path], in: root)

        XCTAssertEqual(try GitRepositoryScanner.repositories(in: folder).map(\.lastPathComponent), ["repo"])
        XCTAssertEqual(try GitRepositoryScanner.scan(repo).worktrees, ["linked-worktree"])
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

    func testDiscoveryReadsRelativeGitMetadataAndRejectsInvalidPointers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("repositories")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let repo = folder.appendingPathComponent("repo with spaces")
        let metadata = root.appendingPathComponent("metadata with spaces")
        try git(["init", "-b", "main", "--separate-git-dir", metadata.path, repo.path], in: root)
        try "gitdir: ../../metadata with spaces\n".write(
            to: repo.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try ".\n".write(to: metadata.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)

        for (name, pointer) in [
            ("missing", "gitdir: ../../missing\n"),
            ("malformed", "not a git pointer\n"),
            ("empty", "gitdir: \n"),
            ("oversized", "gitdir: " + String(repeating: "a", count: 5_000))
        ] {
            let directory = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try pointer.write(to: directory.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        }

        XCTAssertEqual(try GitRepositoryScanner.repositories(in: folder).map(\.lastPathComponent), ["repo with spaces"])
        XCTAssertEqual(try GitRepositoryScanner.scan(repo).branch, "main")
    }

    private func git(_ arguments: [String], in directory: URL, committerDate: String? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_AUTHOR_NAME"] = "RepoMan Test"
        environment["GIT_AUTHOR_EMAIL"] = "repoman@example.invalid"
        environment["GIT_COMMITTER_NAME"] = "RepoMan Test"
        environment["GIT_COMMITTER_EMAIL"] = "repoman@example.invalid"
        if let committerDate { environment["GIT_COMMITTER_DATE"] = committerDate }
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " ")) failed")
    }
}
