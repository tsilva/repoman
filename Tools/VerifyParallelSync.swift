import Foundation

/// Exercises the app's sync coordination with disposable local repositories.
@main
struct VerifyParallelSync {
    struct Fixture: Sendable {
        let repository: URL
        let remote: URL
        let hookReady: URL
        let hookRelease: URL
        let review: RepositorySyncReview
        let commonDirectory: String
    }

    enum VerificationError: Error { case failed(String) }

    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw VerificationError.failed(message) }
    }

    @MainActor
    static func wait(_ message: String, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition() {
            try require(Date() < deadline, "Timed out: \(message)")
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    static func fixture(_ name: String, in root: URL, holdPush: Bool) throws -> Fixture {
        let repository = root.appendingPathComponent(name)
        let remote = root.appendingPathComponent("\(name).git")
        let hooks = root.appendingPathComponent("\(name)-hooks")
        let ready = root.appendingPathComponent("\(name)-ready")
        let release = root.appendingPathComponent("\(name)-release")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        _ = try GitRunner.run(["init", "--bare", remote.path], at: root)
        _ = try GitRunner.run(["init", "-b", "main", repository.path], at: root)
        for setting in [["user.name", "Sync Verification"], ["user.email", "sync@example.invalid"],
                        ["commit.gpgsign", "false"], ["core.hooksPath", hooks.path]] {
            _ = try GitRunner.run(["config"] + setting, at: repository)
        }
        let file = repository.appendingPathComponent("file.txt")
        try "initial\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try GitRunner.run(["add", "file.txt"], at: repository)
        _ = try GitRunner.run(["commit", "-m", "Initial"], at: repository)
        _ = try GitRunner.run(["remote", "add", "local", remote.path], at: repository)
        _ = try GitRunner.run(["push", "-u", "local", "main"], at: repository)
        if holdPush {
            let hook = hooks.appendingPathComponent("pre-push")
            try """
            #!/bin/sh
            touch '\(ready.path)'
            while [ ! -e '\(release.path)' ]; do sleep 0.05; done
            """.write(to: hook, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        }
        try "\(name) updated\n".write(to: file, atomically: true, encoding: .utf8)
        return Fixture(repository: repository, remote: remote, hookReady: ready, hookRelease: release,
                       review: try RepositorySync.review(at: repository),
                       commonDirectory: try RepairTaskQueue.commonDirectory(at: repository))
    }

    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("repoman-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (first, second, third, linkedReview) = try await Task.detached {
            let first = try fixture("first", in: root, holdPush: true)
            let second = try fixture("second", in: root, holdPush: true)
            let third = try fixture("third", in: root, holdPush: false)
            let linked = root.appendingPathComponent("linked")
            _ = try GitRunner.run(["worktree", "add", "-b", "linked", linked.path, "HEAD"], at: first.repository)
            _ = try GitRunner.run(["branch", "--set-upstream-to=local/main", "linked"], at: linked)
            return (first, second, third, try RepositorySync.review(at: linked))
        }.value
        defer {
            // Release any waiting hooks even if a verification fails.
            for fixture in [first, second] {
                try? "".write(to: fixture.hookRelease, atomically: true, encoding: .utf8)
            }
        }

        let store = RepositoryStore()
        store.synchronize(first.review, selectedPaths: ["file.txt"], message: "First")
        try require(store.syncUnavailableReason(for: second.review.snapshot) == nil,
                    "A different repository was blocked by the first sync")
        store.synchronize(second.review, selectedPaths: ["file.txt"], message: "Second")
        store.synchronize(first.review, selectedPaths: ["file.txt"], message: "Duplicate")
        try require(store.syncStates[first.repository.path]?.isRunning == true,
                    "A duplicate request replaced the active sync state")
        try await wait("both pushes overlap") {
            FileManager.default.fileExists(atPath: first.hookReady.path) &&
            FileManager.default.fileExists(atPath: second.hookReady.path)
        }
        try require(store.busyCommonDirectories == [first.commonDirectory, second.commonDirectory],
                    "Both repositories must remain reserved while pushing")

        store.synchronize(linkedReview, selectedPaths: [], message: "")
        try await wait("shared worktree rejected") { store.syncStates[linkedReview.snapshot.id]?.isRunning == false }
        guard case .failed(let error) = store.syncStates[linkedReview.snapshot.id] else {
            throw VerificationError.failed("A worktree sharing an active Git directory was allowed to sync")
        }
        try require(error.contains("shared Git directory"), "Unexpected worktree error: \(error)")

        try "".write(to: first.hookRelease, atomically: true, encoding: .utf8)
        try await wait("first sync completed") { store.syncStates[first.repository.path]?.isRunning == false }
        guard case .succeeded = store.syncStates[first.repository.path] else {
            throw VerificationError.failed("The first sync did not succeed")
        }
        try require(store.isSyncing && store.busyCommonDirectories == [second.commonDirectory],
                    "Completing one sync cleared another repository's reservation")
        try require(store.syncUnavailableReason(for: second.review.snapshot) != nil,
                    "The second repository lost its duplicate-sync protection")

        try "changed after review\n".write(to: third.repository.appendingPathComponent("file.txt"),
                                            atomically: true, encoding: .utf8)
        store.synchronize(third.review, selectedPaths: ["file.txt"], message: "Stale")
        try await wait("stale review failed") { store.syncStates[third.repository.path]?.isRunning == false }
        guard case .failed = store.syncStates[third.repository.path] else {
            throw VerificationError.failed("A stale review unexpectedly succeeded")
        }
        try require(store.isSyncing && store.busyCommonDirectories == [second.commonDirectory],
                    "A failed sync cleared another repository's reservation")
        let fresh = try await Task.detached { try RepositorySync.review(at: third.repository) }.value
        store.synchronize(fresh, selectedPaths: ["file.txt"], message: "Retry")
        try await wait("failed repository retried") { store.syncStates[third.repository.path]?.isRunning == false }
        guard case .succeeded = store.syncStates[third.repository.path] else {
            throw VerificationError.failed("The failed repository could not retry")
        }

        try "".write(to: second.hookRelease, atomically: true, encoding: .utf8)
        try await wait("all syncs completed") { !store.isSyncing }
        guard case .succeeded = store.syncStates[second.repository.path] else {
            throw VerificationError.failed("The second sync did not succeed")
        }
        try require(store.busyCommonDirectories.isEmpty, "Completed syncs retained Git reservations")
        try await Task.detached {
            for fixture in [first, second] {
                let text = try GitRunner.text(["show", "main:file.txt"], at: fixture.remote)
                try require(text == "\(fixture.repository.lastPathComponent) updated", "The remote missed the commit")
            }
        }.value
        print("Parallel sync verification passed: overlapping pushes, duplicate protection, shared worktree exclusion, independent completion/failure, and retry.")
    }
}
