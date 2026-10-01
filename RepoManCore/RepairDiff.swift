import Foundation

/// The agent's unified diff, decoded for review without reading or changing repository files.
public struct RepairDiff: Sendable {
    /// Read staged and unstaged changes against HEAD, plus non-ignored untracked files.
    /// This never writes to the index or working tree. Run it off the main actor.
    public static func workingTreeSource(at directory: URL) throws -> String {
        let base: String
        if let head = try? GitRunner.text(["rev-parse", "--verify", "HEAD"], at: directory) {
            base = head
        } else {
            // The empty tree also works before a repository's first commit.
            base = try GitRunner.text(["hash-object", "-t", "tree", "/dev/null"], at: directory)
        }
        let options = ["--no-ext-diff", "--no-textconv", "--no-color", "--src-prefix=a/", "--dst-prefix=b/"]
        var source = String(decoding: try GitRunner.run(["diff"] + options + [base, "--"], at: directory), as: UTF8.self)
        let paths = try GitRunner.run(["ls-files", "--others", "--exclude-standard", "-z"], at: directory)
        for path in paths.split(separator: 0).map({ String(decoding: $0, as: UTF8.self) }) {
            let patch = try GitRunner.run(["diff", "--no-index"] + options + ["--", "/dev/null", path],
                                          at: directory, successfulExitCodes: [0, 1])
            source += String(decoding: patch, as: UTF8.self)
        }
        return source
    }

    public struct Line: Identifiable, Sendable {
        public enum Kind: Sendable { case context, addition, deletion, hunk, note }
        public let id: Int
        public let kind: Kind
        public let text: String
        public let oldNumber: Int?
        public let newNumber: Int?
    }

    public struct File: Identifiable, Sendable {
        public let id: Int
        public var path: String
        public var oldPath: String?
        public var status = "Modified"
        public var lines: [Line] = []
        public var additions: Int { lines.filter { $0.kind == .addition }.count }
        public var deletions: Int { lines.filter { $0.kind == .deletion }.count }
    }

    public let files: [File]
    public var additions: Int { files.reduce(0) { $0 + $1.additions } }
    public var deletions: Int { files.reduce(0) { $0 + $1.deletions } }

    public init(_ source: String) {
        var files: [File] = []
        var current: File?
        var inHunk = false
        var hasHunk = false
        var oldNumber = 0
        var newNumber = 0
        var oldRemaining = 0
        var newRemaining = 0

        func finish() {
            if let file = current { files.append(file) }
            current = nil
            inHunk = false
            hasHunk = false
        }
        func start(_ path: String) {
            finish()
            current = File(id: files.count, path: path)
        }
        func append(_ kind: Line.Kind, _ text: String, old: Int? = nil, new: Int? = nil) {
            let lineID = current?.lines.count ?? 0
            current?.lines.append(Line(id: lineID, kind: kind,
                                      text: text, oldNumber: old, newNumber: new))
        }

        var rawLines = source.components(separatedBy: "\n")
        if rawLines.last == "" { rawLines.removeLast() }
        for line in rawLines {
            if line.hasPrefix("diff --git ") {
                let paths = Self.headerPaths(String(line.dropFirst(11)))
                start(Self.path(paths.last ?? "Changes"))
                current?.oldPath = paths.first.map { Self.path($0) }
            } else if line.hasPrefix("@@ ") {
                if current == nil { start("Changes") }
                let parts = line.split(separator: " ")
                oldNumber = parts.count > 2 ? Self.hunkStart(parts[1]) : 0
                newNumber = parts.count > 2 ? Self.hunkStart(parts[2]) : 0
                oldRemaining = parts.count > 2 ? Self.hunkCount(parts[1]) : 0
                newRemaining = parts.count > 2 ? Self.hunkCount(parts[2]) : 0
                inHunk = true
                hasHunk = true
                append(.hunk, line)
            } else if inHunk && line.hasPrefix("+") {
                append(.addition, String(line.dropFirst()), new: newNumber)
                newNumber += 1
                newRemaining -= 1
                inHunk = oldRemaining > 0 || newRemaining > 0
            } else if inHunk && line.hasPrefix("-") {
                append(.deletion, String(line.dropFirst()), old: oldNumber)
                oldNumber += 1
                oldRemaining -= 1
                inHunk = oldRemaining > 0 || newRemaining > 0
            } else if inHunk && line.hasPrefix(" ") {
                append(.context, String(line.dropFirst()), old: oldNumber, new: newNumber)
                oldNumber += 1
                newNumber += 1
                oldRemaining -= 1
                newRemaining -= 1
                inHunk = oldRemaining > 0 || newRemaining > 0
            } else if line.hasPrefix("--- ") {
                // fileChange events can contain only an old-file header followed by a hunk.
                let path = Self.path(String(line.dropFirst(4)))
                if current == nil || hasHunk { start(path == "/dev/null" ? "Changes" : path) }
                current?.oldPath = path
                if path == "/dev/null" { current?.status = "Added" }
                inHunk = false
            } else if line.hasPrefix("+++ ") {
                let path = Self.path(String(line.dropFirst(4)))
                if path == "/dev/null" { current?.status = "Deleted" }
                else { current?.path = path }
            } else if line.hasPrefix("new file mode") {
                current?.status = "Added"
            } else if line.hasPrefix("deleted file mode") {
                current?.status = "Deleted"
            } else if line.hasPrefix("rename from ") {
                current?.oldPath = Self.path(String(line.dropFirst(12)), stripPrefix: false)
                current?.status = "Renamed"
            } else if line.hasPrefix("rename to ") {
                current?.path = Self.path(String(line.dropFirst(10)), stripPrefix: false)
            } else if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
                append(.note, "Binary file changed")
            } else if line.hasPrefix("old mode ") || line.hasPrefix("new mode ") || line.hasPrefix("\\ No newline") {
                append(.note, line)
            }
        }
        finish()
        self.files = files
    }

    private static func hunkStart(_ value: Substring) -> Int {
        Int(value.dropFirst().split(separator: ",").first ?? "0") ?? 0
    }

    private static func hunkCount(_ value: Substring) -> Int {
        let parts = value.dropFirst().split(separator: ",")
        return parts.count > 1 ? Int(parts[1]) ?? 0 : 1
    }

    private static func headerPaths(_ value: String) -> [String] {
        // Unquoted Git paths may contain spaces; the b/ boundary separates them.
        if !value.hasPrefix("\""), let boundary = value.range(of: " b/") {
            return [String(value[..<boundary.lowerBound]), String(value[boundary.lowerBound...].dropFirst())]
        }
        var tokens: [String] = []
        var token = ""
        var quoted = false
        var escaped = false
        for char in value {
            if char == " " && !quoted { if !token.isEmpty { tokens.append(token); token = "" }; continue }
            token.append(char)
            if escaped { escaped = false }
            else if char == "\\" { escaped = true }
            else if char == "\"" { quoted.toggle() }
        }
        if !token.isEmpty { tokens.append(token) }
        return tokens
    }

    private static func path(_ value: String, stripPrefix: Bool = true) -> String {
        var path = value.components(separatedBy: "\t").first ?? value
        if path.hasPrefix("\""), path.hasSuffix("\"") {
            let chars = Array(path.dropFirst().dropLast())
            var bytes: [UInt8] = []
            var index = 0
            while index < chars.count {
                if chars[index] == "\\", index + 1 < chars.count {
                    index += 1
                    let escapes: [Character: UInt8] = ["n": 10, "t": 9, "r": 13, "\\": 92, "\"": 34]
                    if let byte = escapes[chars[index]] { bytes.append(byte) }
                    else {
                        var octal = ""
                        while index < chars.count && octal.count < 3 && "01234567".contains(chars[index]) {
                            octal.append(chars[index]); index += 1
                        }
                        if let byte = UInt8(octal, radix: 8) { bytes.append(byte); continue }
                        bytes.append(contentsOf: String(chars[index]).utf8)
                    }
                } else { bytes.append(contentsOf: String(chars[index]).utf8) }
                index += 1
            }
            path = String(decoding: bytes, as: UTF8.self)
        }
        if stripPrefix && (path.hasPrefix("a/") || path.hasPrefix("b/")) { path = String(path.dropFirst(2)) }
        return path
    }
}
