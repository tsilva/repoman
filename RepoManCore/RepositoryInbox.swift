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
    /// Complete item contents, excluding the trailing line endings belonging to each slot.
    fileprivate let taskRanges: [Range<Int>]
    private let taskGroups: [Int]

    /// Parses Todos only; Notes, fenced examples and HTML comments are not tasks.
    public init(repositoryURL: URL, source: Data) throws {
        guard source.count <= Self.maximumBytes, let text = String(data: source, encoding: .utf8) else {
            throw RepositoryInboxError.unsupported
        }
        self.repositoryURL = repositoryURL.standardizedFileURL
        self.source = source
        revision = Self.hash(source)
        let parsed = Self.parse(text)
        tasks = parsed.tasks
        taskRanges = parsed.ranges
        taskGroups = parsed.groups
    }

    public static let maximumBytes = 1_048_576
    /// Returns a new snapshot without touching disk (also used by the illustrative UI).
    public func settingComplete(_ complete: Bool, task: RepositoryInboxTask) throws -> RepositoryInbox {
        guard tasks.contains(task), source.indices.contains(task.markerOffset) else { throw RepositoryInboxError.changed }
        var updated = source
        updated[task.markerOffset] = complete ? 120 : 32
        return try RepositoryInbox(repositoryURL: repositoryURL, source: updated)
    }

    /// Original task identities in the requested order. Hidden tasks retain their relative order.
    public func taskOrder(moving task: RepositoryInboxTask, relativeTo target: RepositoryInboxTask,
                          after: Bool) throws -> [RepositoryInboxTask] {
        guard let from = tasks.firstIndex(of: task), let to = tasks.firstIndex(of: target) else {
            throw RepositoryInboxError.changed
        }
        guard taskGroups[from] == taskGroups[to] else { throw RepositoryInboxError.differentSection }
        guard from != to else { return tasks }
        var order = tasks
        order.remove(at: from)
        let destination = order.firstIndex(of: target)!
        order.insert(task, at: destination + (after ? 1 : 0))
        return order
    }

    /// Moves item contents with their notes, preserving headings and every slot's line endings.
    public func moving(_ task: RepositoryInboxTask, relativeTo target: RepositoryInboxTask,
                       after: Bool) throws -> RepositoryInbox {
        let order = try taskOrder(moving: task, relativeTo: target, after: after)
        let contents = Dictionary(uniqueKeysWithValues: zip(tasks, taskRanges).map { ($0.0.id, source.subdata(in: $0.1)) })
        var updated = Data()
        var offset = 0
        for (slot, item) in zip(taskRanges, order) {
            updated.append(source.subdata(in: offset..<slot.lowerBound))
            updated.append(contents[item.id]!)
            offset = slot.upperBound
        }
        updated.append(source.subdata(in: offset..<source.count))
        let result = try RepositoryInbox(repositoryURL: repositoryURL, source: updated)
        // Reject unusual Markdown whose interpretation changes when moved (for example an open fence).
        guard result.tasks.count == order.count,
              zip(result.tasks, order).allSatisfy({ $0.title == $1.title && $0.notes == $1.notes && $0.isComplete == $1.isComplete }) else {
            throw RepositoryInboxError.unsupportedMove
        }
        return result
    }

    /// Only a permutation of complete task blocks is a valid reorder undo.
    fileprivate func isReordering(of other: RepositoryInbox) -> Bool {
        guard repositoryURL == other.repositoryURL, taskGroups == other.taskGroups,
              source.count == other.source.count else { return false }
        func parts(_ document: RepositoryInbox) -> (fixed: [Data], items: [Int: [Data: Int]]) {
            var fixed: [Data] = [], items: [Int: [Data: Int]] = [:], offset = 0
            for (index, range) in document.taskRanges.enumerated() {
                fixed.append(document.source.subdata(in: offset..<range.lowerBound))
                items[document.taskGroups[index], default: [:]][document.source.subdata(in: range), default: 0] += 1
                offset = range.upperBound
            }
            fixed.append(document.source.subdata(in: offset..<document.source.count))
            return (fixed, items)
        }
        let left = parts(self), right = parts(other)
        return left.fixed == right.fixed && left.items == right.items
    }

    fileprivate static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func parse(_ text: String) -> (tasks: [RepositoryInboxTask], ranges: [Range<Int>], groups: [Int]) {
        let pattern = try! NSRegularExpression(pattern: #"^([ \t]*)(?:[-+*]|[0-9]+[.)])[ \t]+\[([ xX])\][ \t]+(.+?)\r?$"#)
        var result: [RepositoryInboxTask] = []
        let bytes = Array(text.utf8)
        var ranges: [Range<Int>] = [], groups: [Int] = []
        var itemStart = 0, group = 0
        var current: (title: String, complete: Bool, line: Int, offset: Int)?
        var notes: [String] = []
        var inTodos = false
        var fence: Character?
        var fenceLength = 0
        var comment = false
        var offset = 0
        func finish() {
            if let item = current {
                var end = min(offset, bytes.count)
                while end > itemStart && (bytes[end - 1] == 10 || bytes[end - 1] == 13) { end -= 1 }
                ranges.append(itemStart..<end)
                groups.append(group)
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
                    group += 1
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
                itemStart = offset
                current = (String(line[title]).trimmingCharacters(in: .whitespaces), line[marker] != " ", index + 1,
                           offset + line[..<marker.lowerBound].utf8.count)
            } else if current != nil {
                notes.append(line)
            }
        }
        finish()
        return (result, ranges, groups)
    }
}

public enum RepositoryInboxError: Error, LocalizedError, Equatable {
    case missing, unsafePath, unsupported, changed, busy, unavailable, readOnly, differentSection, unsupportedMove

    public var errorDescription: String? {
        switch self {
        case .missing: return "No INBOX.md in this repository."
        case .unsafePath: return "Inbox access is unavailable for linked files, linked folders or Obsidian vaults."
        case .unsupported: return "The inbox must be a UTF-8 text file no larger than 1 MiB."
        case .changed: return "The inbox changed. Refresh and try again."
        case .busy: return "Another inbox edit is in progress. Try again."
        case .unavailable: return "The inbox could not be read or saved. Check its file permissions."
        case .readOnly: return "Inbox editing requires an untracked inbox excluded by a root /INBOX.md ignore rule."
        case .differentSection: return "Move todos within the same heading."
        case .unsupportedMove: return "This task’s Markdown cannot be safely reordered. Edit the source inbox instead."
        }
    }
}

/// Local-only inbox I/O. Inspection never writes; explicit edits verify the displayed source.
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

    public static func move(_ task: RepositoryInboxTask, relativeTo target: RepositoryInboxTask,
                            after: Bool, in snapshot: RepositoryInbox) throws -> RepositoryInbox {
        let updated = try snapshot.moving(task, relativeTo: target, after: after)
        return try writeReordering(updated, replacing: snapshot)
    }

    public static func undoMove(previous: RepositoryInbox, current: RepositoryInbox) throws -> RepositoryInbox {
        guard previous.isReordering(of: current) else { throw RepositoryInboxError.changed }
        return try writeReordering(previous, replacing: current)
    }

    private static func writeReordering(_ updated: RepositoryInbox, replacing snapshot: RepositoryInbox) throws -> RepositoryInbox {
        guard updated.isReordering(of: snapshot) else { throw RepositoryInboxError.changed }
        try validateEditingPolicy(snapshot.repositoryURL)
        let descriptor = try openInbox(snapshot.repositoryURL, flags: O_RDWR)
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw RepositoryInboxError.busy }
        defer { flock(descriptor, LOCK_UN) }
        guard try bytes(descriptor) == snapshot.source,
              try isCurrent(descriptor, repository: snapshot.repositoryURL) else { throw RepositoryInboxError.changed }
        guard let first = snapshot.source.indices.first(where: { snapshot.source[$0] != updated.source[$0] }),
              let last = snapshot.source.indices.last(where: { snapshot.source[$0] != updated.source[$0] }) else { return snapshot }
        let changed = updated.source.subdata(in: first..<(last + 1))
        // Same-size writes preserve file identity and permissions, without touching other sections.
        guard try bytes(descriptor) == snapshot.source else { throw RepositoryInboxError.changed }
        let count = changed.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, off_t(first)) }
        guard count == changed.count, fsync(descriptor) == 0 else { throw RepositoryInboxError.unavailable }
        guard try isCurrent(descriptor, repository: snapshot.repositoryURL), try bytes(descriptor) == updated.source else {
            throw RepositoryInboxError.changed
        }
        return updated
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
