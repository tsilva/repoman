import XCTest
@testable import RepoManCore

final class RepairDiffTests: XCTestCase {
    func testWorkingTreeDiffIncludesStagedUnstagedAndUntrackedWithoutWriting() throws {
        let directory = try makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("original\n", to: "tracked.txt", in: directory)
        try write("removed\n", to: "deleted.txt", in: directory)
        try write("ignored.txt\n", to: ".gitignore", in: directory)
        _ = try GitRunner.run(["add", "."], at: directory)
        _ = try GitRunner.run(["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                               "commit", "-m", "Initial"], at: directory)
        try write("staged\n", to: "tracked.txt", in: directory)
        _ = try GitRunner.run(["add", "tracked.txt"], at: directory)
        try write("working\n", to: "tracked.txt", in: directory)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("deleted.txt"))
        try write("new content\n", to: "café with spaces.txt", in: directory)
        try write("ignore me\n", to: "ignored.txt", in: directory)
        try Data([0, 1, 2, 3]).write(to: directory.appendingPathComponent("binary.dat"))
        try write("", to: "empty.txt", in: directory)
        let indexURL = directory.appendingPathComponent(".git/index")
        let indexBefore = try Data(contentsOf: indexURL)
        let statusBefore = try GitRunner.run(["status", "--porcelain", "-z"], at: directory)

        let diff = RepairDiff(try RepairDiff.workingTreeSource(at: directory))

        XCTAssertEqual(Set(diff.files.map(\.path)), ["tracked.txt", "deleted.txt", "café with spaces.txt", "binary.dat", "empty.txt"])
        let tracked = try XCTUnwrap(diff.files.first { $0.path == "tracked.txt" })
        XCTAssertEqual(tracked.lines.filter { $0.kind == .addition }.map(\.text), ["working"])
        XCTAssertEqual(tracked.lines.filter { $0.kind == .deletion }.map(\.text), ["original"])
        XCTAssertEqual(diff.files.first { $0.path == "deleted.txt" }?.status, "Deleted")
        XCTAssertEqual(diff.files.first { $0.path == "binary.dat" }?.lines.first?.text, "Binary file changed")
        XCTAssertEqual(diff.files.first { $0.path == "empty.txt" }?.status, "Added")
        XCTAssertEqual(try Data(contentsOf: indexURL), indexBefore)
        XCTAssertEqual(try GitRunner.run(["status", "--porcelain", "-z"], at: directory), statusBefore)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("tracked.txt")), "working\n")
    }

    func testWorkingTreeDiffBeforeFirstCommitAndForCleanRepository() throws {
        let directory = try makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertTrue(RepairDiff(try RepairDiff.workingTreeSource(at: directory)).files.isEmpty)
        try write("staged\n", to: "new.txt", in: directory)
        _ = try GitRunner.run(["add", "new.txt"], at: directory)
        try write("working\n", to: "new.txt", in: directory)
        let diff = RepairDiff(try RepairDiff.workingTreeSource(at: directory))
        XCTAssertEqual(diff.files.count, 1)
        XCTAssertEqual(diff.files.first?.status, "Added")
        XCTAssertEqual(diff.files.first?.lines.filter { $0.kind == .addition }.map(\.text), ["working"])
        _ = try GitRunner.run(["add", "."], at: directory)
        _ = try GitRunner.run(["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                               "commit", "-m", "Initial"], at: directory)
        XCTAssertTrue(RepairDiff(try RepairDiff.workingTreeSource(at: directory)).files.isEmpty)
    }

    func testWorkingTreeDiffReportsInvalidRepository() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try RepairDiff.workingTreeSource(at: directory))
    }

    private func makeRepository() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try GitRunner.run(["init", "-b", "main"], at: directory)
        return directory
    }

    private func write(_ text: String, to path: String, in directory: URL) throws {
        try text.write(to: directory.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    func testCountsAndLineNumbersAcrossHunksAndFiles() {
        let diff = RepairDiff("""
        diff --git a/docs/issues.md b/docs/issues.md
        --- a/docs/issues.md
        +++ b/docs/issues.md
        @@ -2,3 +2,4 @@
         context
        -old
        +new
        +extra
         context
        @@ -20 +21 @@
        -before
        +after
        diff --git a/LICENSE b/LICENSE
        new file mode 100644
        --- /dev/null
        +++ b/LICENSE
        @@ -0,0 +1,2 @@
        +MIT License
        +Copyright
        """)
        XCTAssertEqual(diff.files.map(\.path), ["docs/issues.md", "LICENSE"])
        XCTAssertEqual(diff.additions, 5)
        XCTAssertEqual(diff.deletions, 2)
        XCTAssertEqual(diff.files[1].status, "Added")
        let changed = diff.files[0].lines.filter { $0.kind == .addition || $0.kind == .deletion }
        XCTAssertEqual(changed.map(\.oldNumber), [3, nil, nil, 20, nil])
        XCTAssertEqual(changed.map(\.newNumber), [nil, 3, 4, nil, 21])
    }

    func testHeaderLookingContentIsCountedAndFragmentsRemainSeparate() {
        let diff = RepairDiff("""
        --- first.md
        @@ -1 +1 @@
        --- removed content
        +++ added content
        --- second.md
        @@ -0,0 +1 @@
        +second
        """)
        XCTAssertEqual(diff.files.map(\.path), ["first.md", "second.md"])
        XCTAssertEqual(diff.files[0].lines.filter { $0.kind == .deletion }.first?.text, "-- removed content")
        XCTAssertEqual(diff.additions, 2)
        XCTAssertEqual(diff.deletions, 1)
    }

    func testRenameBinaryDeletedAndModeChanges() {
        let diff = RepairDiff("""
        diff --git a/old.txt b/new.txt
        similarity index 100%
        rename from old.txt
        rename to new.txt
        diff --git a/icon.png b/icon.png
        Binary files a/icon.png and b/icon.png differ
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        --- a/gone.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -gone
        \\ No newline at end of file
        diff --git a/run.sh b/run.sh
        old mode 100644
        new mode 100755
        """)
        XCTAssertEqual(diff.files.map(\.status), ["Renamed", "Modified", "Deleted", "Modified"])
        XCTAssertEqual(diff.files[0].oldPath, "old.txt")
        XCTAssertEqual(diff.files[0].path, "new.txt")
        XCTAssertEqual(diff.files[1].lines.first?.text, "Binary file changed")
        XCTAssertEqual(diff.files[2].path, "gone.txt")
        XCTAssertEqual(diff.files[3].lines.count, 2)
        XCTAssertEqual(diff.additions, 0)
        XCTAssertEqual(diff.deletions, 1)
    }

    func testSpacesAndGitQuotedUnicodePaths() {
        let diff = RepairDiff("""
        diff --git a/my file.txt b/my file.txt
        --- a/my file.txt
        +++ b/my file.txt
        @@ -0,0 +1 @@
        +hello
        diff --git "a/caf\\303\\251.txt" "b/caf\\303\\251.txt"
        --- "a/caf\\303\\251.txt"
        +++ "b/caf\\303\\251.txt"
        @@ -0,0 +1 @@
        +bonjour
        """)
        XCTAssertEqual(diff.files.map(\.path), ["my file.txt", "café.txt"])
        XCTAssertEqual(diff.additions, 2)
    }

    func testEmptyDiffHasNoChanges() {
        let diff = RepairDiff("")
        XCTAssertTrue(diff.files.isEmpty)
        XCTAssertEqual(diff.additions, 0)
        XCTAssertEqual(diff.deletions, 0)
    }
}
