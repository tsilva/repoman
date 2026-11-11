import CryptoKit
import Darwin
import Foundation

public struct RepositoryInboxTask: Identifiable, Sendable, Equatable {
    public var id: Int { markerOffset }
    public let title: String
    public let notes: String
    public let isComplete: Bool
    public let lineNumber: Int
    /// UTF-8 byte offset of the single character inside the Markdown checkbox.
    public let markerOffset: Int
}

public struct RepositoryInbox: Sendable, Equatable {
    public let repositoryURL: URL
    public var url: URL { repositoryURL.appendingPathComponent("INBOX.md") }
    public let tasks: [RepositoryInboxTask]
    public let revision: String
    fileprivate let source: Data

    /// Parses Todos only; Notes, fenced examples and HTML comments are not tasks.
    public init(repositoryURL: URL, source: Data) throws {
        guard source.count <= Self.maximumBytes, let text = String(data: source, encoding: .utf8) else {
            throw RepositoryInboxError.unsupported
        }
        self.repositoryURL = repositoryURL.standardizedFileURL
        self.source = source
        revision = Self.hash(source)
        tasks = Self.parse(text)
    }

    public static let maximumBytes = 1_048_576
    /// Returns a new snapshot without touching disk (also used by the illustrative UI).
    public func settingComplete(_ complete: Bool, task: RepositoryInboxTask) throws -> RepositoryInbox {
        guard tasks.contains(task), source.indices.contains(task.markerOffset) else { throw RepositoryInboxError.changed }
        var updated = source
        updated[task.markerOffset] = complete ? 120 : 32
        return try RepositoryInbox(repositoryURL: repositoryURL, source: updated)
    }

    fileprivate static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func parse(_ text: String) -> [RepositoryInboxTask] {
        let pattern = try! NSRegularExpression(pattern: #"^([ \t]*)(?:[-+*]|[0-9]+[.)])[ \t]+\[([ xX])\][ \t]+(.+?)\r?$"#)
        var result: [RepositoryInboxTask] = []
        var current: (title: String, complete: Bool, line: Int, offset: Int)?
        var notes: [String] = []
        var inTodos = false
        var fence: Character?
        var fenceLength = 0
        var comment = false
        var offset = 0
        func finish() {
            if let item = current {
                result.append(.init(title: item.title,
                                    notes: notes.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                                    isComplete: item.complete, lineNumber: item.line, markerOffset: item.offset))
            }
            current = nil
            notes = []
        }
        for (index, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .newlines)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            defer { offset += raw.utf8.count + 1 }
            if comment || trimmed.contains("<!--") {
                comment = !trimmed.contains("-->")
                continue
            }
            if let character = trimmed.first, character == "`" || character == "~" {
                let count = trimmed.prefix(while: { $0 == character }).count
                if count >= 3 {
                    if fence == nil { fence = character; fenceLength = count }
                    else if fence == character && count >= fenceLength && trimmed.dropFirst(count).isEmpty { fence = nil }
                    if inTodos, current != nil { notes.append(line) }
                    continue
                }
            }
            if fence != nil {
                if inTodos, current != nil { notes.append(line) }
                continue
            }
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                if trimmed.dropFirst(level).first == " " {
                    finish()
                    if level <= 2 {
                        let heading = trimmed.dropFirst(level).trimmingCharacters(in: CharacterSet(charactersIn: " #\t"))
                        inTodos = level == 2 && heading.lowercased() == "todos"
                    }
                    continue
                }
            }
            guard inTodos else { continue }
            let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = pattern.firstMatch(in: line, range: nsRange),
               let marker = Range(match.range(at: 2), in: line), let title = Range(match.range(at: 3), in: line) {
                finish()
                current = (String(line[title]).trimmingCharacters(in: .whitespaces), line[marker] != " ", index + 1,
                           offset + line[..<marker.lowerBound].utf8.count)
            } else if current != nil {
                notes.append(line)
            }
        }
        finish()
        return result
    }
}

public enum RepositoryInboxError: Error, LocalizedError, Equatable {
    case missing, unsafePath, unsupported, changed, busy, unavailable, readOnly

    public var errorDescription: String? {
        switch self {
        case .missing: return "No INBOX.md in this repository."
        case .unsafePath: return "Inbox access is unavailable for linked files, linked folders or Obsidian vaults."
        case .unsupported: return "The inbox must be a UTF-8 text file no larger than 1 MiB."
        case .changed: return "The inbox changed. Refresh and try again."
        case .busy: return "Another inbox edit is in progress. Try again."
        case .unavailable: return "The inbox could not be read or saved. Check its file permissions."
        case .readOnly: return "Checkbox editing requires an untracked inbox excluded by a root /INBOX.md ignore rule."
        }
    }
}

/// Local-only inbox I/O. Inspection never writes; only an explicit toggle calls setComplete.
/// A one-byte write avoids replacing a whole document edited by another application.
public enum RepositoryInboxFile {
    public static func read(at repository: URL) throws -> RepositoryInbox {
        let descriptor = try openInbox(repository, flags: O_RDONLY)
        defer { close(descriptor) }
        return try RepositoryInbox(repositoryURL: repository, source: bytes(descriptor))
    }

    public static func editingAllowed(at repository: URL) -> Bool {
        do { try validateEditingPolicy(repository); return true } catch { return false }
    }

    public static func setComplete(_ complete: Bool, task: RepositoryInboxTask,
                                   in snapshot: RepositoryInbox) throws -> RepositoryInbox {
        try setMarker(complete ? 120 : 32, task: task, in: snapshot)
    }

    /// Reverses exactly one checkbox edit, including the original uppercase/lowercase marker.
    public static func undo(previous: RepositoryInbox, current: RepositoryInbox) throws -> RepositoryInbox {
        guard previous.repositoryURL == current.repositoryURL, previous.source.count == current.source.count else {
            throw RepositoryInboxError.changed
        }
        let differences = previous.source.indices.filter { previous.source[$0] != current.source[$0] }
        guard differences.count == 1, let offset = differences.first,
              let task = current.tasks.first(where: { $0.markerOffset == offset }),
              previous.tasks.contains(where: { $0.markerOffset == offset }),
              [32, 88, 120].contains(previous.source[offset]) else { throw RepositoryInboxError.changed }
        return try setMarker(previous.source[offset], task: task, in: current)
    }

    private static func setMarker(_ marker: UInt8, task: RepositoryInboxTask,
                                  in snapshot: RepositoryInbox) throws -> RepositoryInbox {
        try validateEditingPolicy(snapshot.repositoryURL)
        let descriptor = try openInbox(snapshot.repositoryURL, flags: O_RDWR)
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw RepositoryInboxError.busy }
        defer { flock(descriptor, LOCK_UN) }
        guard try bytes(descriptor) == snapshot.source,
              snapshot.tasks.contains(task), task.markerOffset >= 0, task.markerOffset < snapshot.source.count else {
            throw RepositoryInboxError.changed
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, try isCurrent(descriptor, repository: snapshot.repositoryURL) else {
            throw RepositoryInboxError.changed
        }
        var expected = snapshot.source
        if expected[task.markerOffset] == marker { return snapshot }
        expected[task.markerOffset] = marker
        // Recheck after policy checks and immediately before touching this one byte.
        guard try bytes(descriptor) == snapshot.source else { throw RepositoryInboxError.changed }
        var value = marker
        guard pwrite(descriptor, &value, 1, off_t(task.markerOffset)) == 1, fsync(descriptor) == 0 else {
            throw RepositoryInboxError.unavailable
        }
        guard try isCurrent(descriptor, repository: snapshot.repositoryURL), try bytes(descriptor) == expected else {
            throw RepositoryInboxError.changed
        }
        return try RepositoryInbox(repositoryURL: snapshot.repositoryURL, source: expected)
    }

    private static func validateEditingPolicy(_ repository: URL) throws {
        let tracked = try GitRunner.run(["ls-files", "-z", "--", "INBOX.md"], at: repository, timeout: 5, maximumOutputBytes: 4096)
        let rulesURL = repository.appendingPathComponent(".gitignore")
        guard let rules = try? String(contentsOf: rulesURL, encoding: .utf8),
              rules.components(separatedBy: .newlines).contains(where: { $0.trimmingCharacters(in: .whitespaces) == "/INBOX.md" }),
              tracked.isEmpty else { throw RepositoryInboxError.readOnly }
        let ignored = try GitRunner.run(["check-ignore", "--", "INBOX.md"], at: repository, timeout: 5,
                                        successfulExitCodes: [0, 1], maximumOutputBytes: 4096)
        guard !ignored.isEmpty else { throw RepositoryInboxError.readOnly }
    }

    private static func validateRoot(_ repository: URL) throws {
        let root = repository.standardizedFileURL
        guard root.resolvingSymlinksInPath().path == root.path,
              FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) else {
            throw RepositoryInboxError.unsafePath
        }
        var ancestor = root
        while ancestor.path != "/" {
            if FileManager.default.fileExists(atPath: ancestor.appendingPathComponent(".obsidian").path) {
                throw RepositoryInboxError.unsafePath
            }
            ancestor.deleteLastPathComponent()
        }
    }

    private static func openInbox(_ repository: URL, flags: Int32) throws -> Int32 {
        try validateRoot(repository)
        let descriptor = open(repository.appendingPathComponent("INBOX.md").path, flags | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { throw RepositoryInboxError.missing }
            if errno == ELOOP { throw RepositoryInboxError.unsafePath }
            throw RepositoryInboxError.unavailable
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else {
            close(descriptor)
            throw RepositoryInboxError.unsafePath
        }
        guard info.st_size >= 0, info.st_size <= RepositoryInbox.maximumBytes else {
            close(descriptor)
            throw RepositoryInboxError.unsupported
        }
        return descriptor
    }

    private static func isCurrent(_ descriptor: Int32, repository: URL) throws -> Bool {
        try validateRoot(repository)
        var opened = stat(), current = stat()
        guard fstat(descriptor, &opened) == 0,
              lstat(repository.appendingPathComponent("INBOX.md").path, &current) == 0 else { return false }
        return opened.st_dev == current.st_dev && opened.st_ino == current.st_ino && current.st_nlink == 1
    }

    private static func bytes(_ descriptor: Int32) throws -> Data {
        var data = Data(count: RepositoryInbox.maximumBytes + 1)
        let count = data.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
        guard count >= 0 else { throw RepositoryInboxError.unavailable }
        guard count <= RepositoryInbox.maximumBytes else { throw RepositoryInboxError.unsupported }
        data.count = count
        return data
    }
}
