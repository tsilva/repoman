import Foundation
import XCTest
@testable import RepoManCore

final class CodexStorageTests: XCTestCase {
    private func fixture() throws -> (root: URL, storage: CodexStorage, task: RepairTask) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RepoMan storage \(UUID().uuidString)")
        let repository = root.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let snapshot = RepositorySnapshot(url: repository, name: "fixture", branch: "main", upstream: nil, remoteURL: nil,
            ahead: nil, behind: nil, changes: [], staleBranches: [], worktrees: [], commits: [])
        let finding = RepositoryFinding(repositoryID: snapshot.id, checkID: "files.readme", title: "README", evidence: "Missing", category: .documentation, symbol: "doc")
        var task = RepairTask(finding: finding, repository: snapshot, prompt: "Write a README")
        task.threadID = UUID().uuidString.lowercased()
        return (root, CodexStorage(homeDirectory: root.appendingPathComponent("private"), legacyHomeDirectory: root.appendingPathComponent("legacy")), task)
    }

    private func writeTranscript(root: URL, task: RepairTask, directory: String = "sessions/2026/10/01", cwd: URL? = nil) throws -> URL {
        let directory = root.appendingPathComponent("legacy").appendingPathComponent(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("rollout-2026-10-01T00-00-00-\(task.threadID!).jsonl")
        let header: [String: Any] = ["type": "session_meta", "payload": ["id": task.threadID!, "cwd": (cwd ?? task.repositoryURL).path]]
        var data = try JSONSerialization.data(withJSONObject: header)
        data.append(Data("\n{\"type\":\"test_history\"}\n".utf8))
        try data.write(to: url)
        return url
    }

    func testLegacyTranscriptIsCopiedWithoutCredentialsAndNeverOverwritesPrivateProgress() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let source = try writeTranscript(root: f.root, task: f.task)
        let original = try Data(contentsOf: source)
        for name in ["auth.json", "config.toml"] {
            try "shared-data".write(to: f.root.appendingPathComponent("legacy/\(name)"), atomically: true, encoding: .utf8)
        }
        let parentHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
        try f.storage.prepare(for: f.task)
        let copy = f.storage.homeDirectory.appendingPathComponent("sessions/2026/10/01/\(source.lastPathComponent)")
        XCTAssertEqual(try Data(contentsOf: copy), original)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(ProcessInfo.processInfo.environment["CODEX_HOME"], parentHome)
        for name in ["auth.json", "config.toml"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.storage.homeDirectory.appendingPathComponent(name).path))
            XCTAssertEqual(try String(contentsOf: f.root.appendingPathComponent("legacy/\(name)"), encoding: .utf8), "shared-data")
        }
        let handle = try FileHandle(forWritingTo: copy)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("private-progress\n".utf8)); try handle.close()
        let advanced = try Data(contentsOf: copy)
        try f.storage.prepare(for: f.task)
        XCTAssertEqual(try Data(contentsOf: copy), advanced)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testArchivedLegacyTranscriptIsCopiedIntoPrivateSessions() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let source = try writeTranscript(root: f.root, task: f.task, directory: "archived_sessions")
        try f.storage.prepare(for: f.task)
        XCTAssertEqual(try Data(contentsOf: f.storage.homeDirectory.appendingPathComponent("sessions/\(source.lastPathComponent)")), try Data(contentsOf: source))
    }

    func testDifferentRepositoryOrMissingTranscriptBlocksMigration() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        XCTAssertThrowsError(try f.storage.prepare(for: f.task))
        _ = try writeTranscript(root: f.root, task: f.task, cwd: f.root.appendingPathComponent("another-repository"))
        XCTAssertThrowsError(try f.storage.prepare(for: f.task)) { error in
            XCTAssertTrue(error.localizedDescription.contains("does not match"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.storage.homeDirectory.appendingPathComponent("sessions").path))
    }

    func testNewPrivateRecordDoesNotImportLegacyTranscriptsEvenWhenPrivateHistoryIsMissing() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try writeTranscript(root: f.root, task: f.task)
        var task = f.task; task.codexStorageVersion = 1
        try f.storage.prepare(for: task)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.storage.homeDirectory.appendingPathComponent("sessions").path))
    }

    func testSharedOrAliasedHomeIsRejectedBeforeWriting() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let legacy = f.root.appendingPathComponent("legacy")
        XCTAssertThrowsError(try CodexStorage(homeDirectory: legacy, legacyHomeDirectory: legacy).prepare(for: f.task))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let alias = f.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: legacy)
        XCTAssertThrowsError(try CodexStorage(homeDirectory: alias, legacyHomeDirectory: legacy).prepare(for: f.task))
    }
}
