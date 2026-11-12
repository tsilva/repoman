import Darwin
import Foundation
import XCTest
@testable import RepoManCore

final class RepositoryInboxTests: XCTestCase {
    private var directory: URL!
    private var inbox: URL { directory.appendingPathComponent("INBOX.md") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("repoman-inboxes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        _ = try GitRunner.run(["init", "--quiet"], at: directory)
        try "/INBOX.md\n".write(to: directory.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    private func write(_ text: String) throws { try Data(text.utf8).write(to: inbox) }

    func testParsesOnlyTodosAndPreservesUnicodeNotesAndExactOffsets() throws {
        let text = "# Inbox\r\n\r\n## Todos\r\n\r\n- [ ] Fix café 🔧\r\n\r\n  Keep [context](guide.md).\r\n  - supporting detail\r\n- [X] Done\r\n\r\n```md\r\n- [ ] Example only\r\n```\r\n<!--\r\n- [ ] Hidden\r\n-->\r\n## Notes\r\n- [ ] Possibility, not a todo\r\n"
        let snapshot = try RepositoryInbox(repositoryURL: directory, source: Data(text.utf8))
        XCTAssertEqual(snapshot.tasks.map(\.title), ["Fix café 🔧", "Done"])
        XCTAssertEqual(snapshot.tasks.map(\.isComplete), [false, true])
        XCTAssertTrue(snapshot.tasks[0].notes.contains("Keep [context](guide.md)."))
        XCTAssertTrue(snapshot.tasks[0].notes.contains("supporting detail"))
        for task in snapshot.tasks {
            XCTAssertEqual(Data(text.utf8)[task.markerOffset], task.isComplete ? 88 : 32)
        }
    }

    func testCheckboxWriteAndUndoChangeOnlyOneByteWithoutReformattingOrReplacingFile() throws {
        let source = "# Inbox\r\n\r\n## Todos\r\n\r\n* [ ] 日本語 café\r\n  context\r\n1. [X] Existing\r\n\r\n## Notes\r\nKeep this unchanged."
        try write(source)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: inbox.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: inbox.path)
        let initial = try RepositoryInboxFile.read(at: directory)
        let changed = try RepositoryInboxFile.setComplete(true, task: initial.tasks[0], in: initial)
        var expected = Data(source.utf8)
        expected[initial.tasks[0].markerOffset] = 120
        XCTAssertEqual(try Data(contentsOf: inbox), expected)
        XCTAssertEqual(changed.tasks.map(\.isComplete), [true, true])
        let after = try FileManager.default.attributesOfItem(atPath: inbox.path)
        XCTAssertEqual(attributes[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(after[.posixPermissions] as? Int, 0o640)
        _ = try RepositoryInboxFile.setComplete(false, task: changed.tasks[0], in: changed)
        XCTAssertEqual(try Data(contentsOf: inbox), Data(source.utf8))
    }

    func testConcurrentChangeAndStaleUndoAreRejectedWithoutOverwritingExternalEdits() throws {
        try write("# Inbox\n## Todos\n- [ ] First\n")
        let initial = try RepositoryInboxFile.read(at: directory)
        let updated = try RepositoryInboxFile.setComplete(true, task: initial.tasks[0], in: initial)
        let external = "# Inbox\n## Todos\n- [x] First\n- [ ] Added elsewhere\n"
        try write(external)
        for snapshot in [initial, updated] {
            XCTAssertThrowsError(try RepositoryInboxFile.setComplete(false, task: snapshot.tasks[0], in: snapshot)) {
                XCTAssertEqual($0 as? RepositoryInboxError, .changed)
            }
        }
        XCTAssertEqual(try String(contentsOf: inbox), external)
    }

    func testIdenticalTaskTitlesHaveIndependentLocations() throws {
        try write("# Inbox\n## Todos\n- [ ] Same\n- [ ] Same\n")
        let initial = try RepositoryInboxFile.read(at: directory)
        XCTAssertNotEqual(initial.tasks[0].id, initial.tasks[1].id)
        let changed = try RepositoryInboxFile.setComplete(true, task: initial.tasks[1], in: initial)
        XCTAssertEqual(changed.tasks.map(\.isComplete), [false, true])
    }

    func testUndoRestoresUppercaseMarkerExactlyAndRejectsOtherDifferences() throws {
        let source = "# Inbox\n## Todos\n- [X] Existing\n"
        try write(source)
        let initial = try RepositoryInboxFile.read(at: directory)
        let changed = try RepositoryInboxFile.setComplete(false, task: initial.tasks[0], in: initial)
        _ = try RepositoryInboxFile.undo(previous: initial, current: changed)
        XCTAssertEqual(try String(contentsOf: inbox), source)
        let unrelated = try RepositoryInbox(repositoryURL: directory, source: Data((source + "Extra notes\n").utf8))
        XCTAssertThrowsError(try RepositoryInboxFile.undo(previous: unrelated, current: changed))
    }

    func testTrackedOrUnignoredInboxRemainsReadableButCannotBeChanged() throws {
        let source = "# Inbox\n## Todos\n- [ ] First\n"
        try write(source)
        XCTAssertTrue(RepositoryInboxFile.editingAllowed(at: directory))
        _ = try GitRunner.run(["add", "--force", "--", "INBOX.md"], at: directory)
        let snapshot = try RepositoryInboxFile.read(at: directory)
        XCTAssertFalse(RepositoryInboxFile.editingAllowed(at: directory))
        XCTAssertThrowsError(try RepositoryInboxFile.setComplete(true, task: snapshot.tasks[0], in: snapshot))
        _ = try GitRunner.run(["rm", "--cached", "--", "INBOX.md"], at: directory)
        try "*.md\n".write(to: directory.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        XCTAssertFalse(RepositoryInboxFile.editingAllowed(at: directory))
        XCTAssertThrowsError(try RepositoryInboxFile.setComplete(true, task: snapshot.tasks[0], in: snapshot))
        XCTAssertEqual(try String(contentsOf: inbox), source)
    }

    func testSymlinkHardlinkVaultAndNonregularFilesAreRejected() throws {
        let target = directory.appendingPathComponent("target.md")
        try "# Inbox\n## Todos\n- [ ] Private\n".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: inbox, withDestinationURL: target)
        XCTAssertThrowsError(try RepositoryInboxFile.read(at: directory))
        try FileManager.default.removeItem(at: inbox)
        try FileManager.default.linkItem(at: target, to: inbox)
        XCTAssertThrowsError(try RepositoryInboxFile.read(at: directory))
        try FileManager.default.removeItem(at: inbox)
        XCTAssertEqual(mkfifo(inbox.path, 0o600), 0)
        XCTAssertThrowsError(try RepositoryInboxFile.read(at: directory))
        try FileManager.default.removeItem(at: inbox)
        try write("# Inbox\n## Todos\n- [ ] First\n")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(".obsidian"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try RepositoryInboxFile.read(at: directory))
        XCTAssertEqual(try String(contentsOf: target), "# Inbox\n## Todos\n- [ ] Private\n")
    }

    func testMissingInvalidAndOversizedFilesDoNotBecomeEmptySuccessfulInboxes() throws {
        XCTAssertThrowsError(try RepositoryInboxFile.read(at: directory)) { XCTAssertEqual($0 as? RepositoryInboxError, .missing) }
        try Data([0xff, 0xfe]).write(to: inbox)
        XCTAssertThrowsError(try RepositoryInboxFile.read(at: directory))
        try Data(repeating: 65, count: RepositoryInbox.maximumBytes + 1).write(to: inbox)
        XCTAssertThrowsError(try RepositoryInboxFile.read(at: directory))
    }

    func testLockContentionRejectsWrite() throws {
        try write("# Inbox\n## Todos\n- [ ] First\n")
        let snapshot = try RepositoryInboxFile.read(at: directory)
        let descriptor = open(inbox.path, O_RDWR)
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        XCTAssertThrowsError(try RepositoryInboxFile.setComplete(true, task: snapshot.tasks[0], in: snapshot)) {
            XCTAssertEqual($0 as? RepositoryInboxError, .busy)
        }
    }

    func testReorderMovesCompleteUnicodeBlocksAndPreservesCRLFSectionsAndFileIdentity() throws {
        let prefix = "# Inbox\r\n\r\n## Todos\r\n\r\nIntro stays here.\r\n\r\n"
        let first = "* [ ] Fix café 🔧\r\n\r\n  Supporting context.\r\n  - Keep this detail."
        let second = "1. [X] Done\r\n```md\r\n- [ ] Example only\r\n```\r\n<!-- Private context -->"
        let third = "- [ ] Third"
        let suffix = "\r\n\r\n## Notes\r\nLeave these notes unchanged."
        let source = prefix + first + "\r\n\r\n" + second + "\r\n" + third + suffix
        try write(source)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: inbox.path)
        let inode = try FileManager.default.attributesOfItem(atPath: inbox.path)[.systemFileNumber] as? NSNumber
        let initial = try RepositoryInboxFile.read(at: directory)
        let moved = try RepositoryInboxFile.move(initial.tasks[0], relativeTo: initial.tasks[2], after: true, in: initial)
        XCTAssertEqual(moved.tasks.map(\.title), ["Done", "Third", "Fix café 🔧"])
        XCTAssertEqual(try String(contentsOf: inbox), prefix + second + "\r\n\r\n" + third + "\r\n" + first + suffix)
        let attributes = try FileManager.default.attributesOfItem(atPath: inbox.path)
        XCTAssertEqual(attributes[.systemFileNumber] as? NSNumber, inode)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o640)
        _ = try RepositoryInboxFile.undoMove(previous: initial, current: moved)
        XCTAssertEqual(try Data(contentsOf: inbox), Data(source.utf8))
    }

    func testReorderLastTaskWithoutFinalNewlineAndDuplicateTitles() throws {
        let source = "# Inbox\n## Todos\n- [ ] Same\n  First notes.\n- [x] Hidden\n- [ ] Same\n  Last notes."
        try write(source)
        let initial = try RepositoryInboxFile.read(at: directory)
        let moved = try RepositoryInboxFile.move(initial.tasks[2], relativeTo: initial.tasks[0], after: false, in: initial)
        XCTAssertEqual(try String(contentsOf: inbox), "# Inbox\n## Todos\n- [ ] Same\n  Last notes.\n- [ ] Same\n  First notes.\n- [x] Hidden")
        XCTAssertEqual(moved.tasks.map(\.notes), ["Last notes.", "First notes.", ""])
        _ = try RepositoryInboxFile.undoMove(previous: initial, current: moved)
        XCTAssertEqual(try String(contentsOf: inbox), source)
    }

    func testReorderRelativeAnchorsKeepOtherTasksInOrderAndIgnoreNoOp() throws {
        let snapshot = try RepositoryInbox(repositoryURL: directory, source: Data("## Todos\n- [ ] A\n- [x] Hidden\n- [ ] B\n- [ ] C\n".utf8))
        let moved = try snapshot.moving(snapshot.tasks[0], relativeTo: snapshot.tasks[2], after: true)
        XCTAssertEqual(moved.tasks.map(\.title), ["Hidden", "B", "A", "C"])
        XCTAssertEqual(try snapshot.moving(snapshot.tasks[0], relativeTo: snapshot.tasks[0], after: true), snapshot)
        XCTAssertEqual(try snapshot.moving(snapshot.tasks[0], relativeTo: snapshot.tasks[1], after: false), snapshot)
    }

    func testReorderDoesNotCrossHeadingsOrChangeMarkdownInterpretation() throws {
        let snapshot = try RepositoryInbox(repositoryURL: directory, source: Data("## Todos\n- [ ] A\n### Later\n- [ ] B\n## Notes\nUnchanged\n".utf8))
        XCTAssertThrowsError(try snapshot.moving(snapshot.tasks[0], relativeTo: snapshot.tasks[1], after: true)) {
            XCTAssertEqual($0 as? RepositoryInboxError, .differentSection)
        }
        let unfinished = try RepositoryInbox(repositoryURL: directory, source: Data("## Todos\n- [ ] A\n- [ ] B\n```md\nExample\n".utf8))
        XCTAssertThrowsError(try unfinished.moving(unfinished.tasks[1], relativeTo: unfinished.tasks[0], after: false)) {
            XCTAssertEqual($0 as? RepositoryInboxError, .unsupportedMove)
        }
    }

    func testReorderAndUndoRejectExternalChangesAndArbitrarySnapshots() throws {
        let source = "## Todos\n- [ ] A\n- [ ] B\n## Notes\nKeep\n"
        try write(source)
        let initial = try RepositoryInboxFile.read(at: directory)
        let moved = try RepositoryInboxFile.move(initial.tasks[1], relativeTo: initial.tasks[0], after: false, in: initial)
        let unrelated = try RepositoryInbox(repositoryURL: directory, source: Data(source.replacingOccurrences(of: "Keep", with: "Gone").utf8))
        XCTAssertThrowsError(try RepositoryInboxFile.undoMove(previous: unrelated, current: moved))
        let external = source + "External notes\n"
        try write(external)
        XCTAssertThrowsError(try RepositoryInboxFile.undoMove(previous: initial, current: moved)) {
            XCTAssertEqual($0 as? RepositoryInboxError, .changed)
        }
        XCTAssertThrowsError(try RepositoryInboxFile.move(initial.tasks[1], relativeTo: initial.tasks[0], after: false, in: initial)) {
            XCTAssertEqual($0 as? RepositoryInboxError, .changed)
        }
        XCTAssertEqual(try String(contentsOf: inbox), external)
    }

    func testReorderEnforcesPolicyLocksAndSafePaths() throws {
        let source = "## Todos\n- [ ] A\n- [ ] B\n"
        try write(source)
        let initial = try RepositoryInboxFile.read(at: directory)
        let descriptor = open(inbox.path, O_RDWR)
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        XCTAssertThrowsError(try RepositoryInboxFile.move(initial.tasks[0], relativeTo: initial.tasks[1], after: true, in: initial)) {
            XCTAssertEqual($0 as? RepositoryInboxError, .busy)
        }
        close(descriptor)
        _ = try GitRunner.run(["add", "--force", "--", "INBOX.md"], at: directory)
        XCTAssertThrowsError(try RepositoryInboxFile.move(initial.tasks[0], relativeTo: initial.tasks[1], after: true, in: initial)) {
            XCTAssertEqual($0 as? RepositoryInboxError, .readOnly)
        }
        _ = try GitRunner.run(["rm", "--cached", "--", "INBOX.md"], at: directory)
        let target = directory.appendingPathComponent("original.md")
        try FileManager.default.moveItem(at: inbox, to: target)
        try FileManager.default.createSymbolicLink(at: inbox, withDestinationURL: target)
        XCTAssertThrowsError(try RepositoryInboxFile.move(initial.tasks[0], relativeTo: initial.tasks[1], after: true, in: initial)) {
            XCTAssertEqual($0 as? RepositoryInboxError, .unsafePath)
        }
        XCTAssertEqual(try String(contentsOf: target), source)
    }
}
