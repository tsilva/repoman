import Foundation

/// Separates pipe tables from prose while leaving the existing inline Markdown intact.
public struct ConversationMarkdown: Equatable, Sendable {
    public enum Block: Equatable, Sendable {
        case text(String)
        case table(Table)
    }

    public struct Table: Equatable, Sendable {
        public enum Alignment: Equatable, Sendable { case left, center, right }
        public let headers: [String]
        public let alignments: [Alignment]
        public let rows: [[String]]
    }

    public let blocks: [Block]

    /// Markdown emitted by the agent can link directly to an absolute local path.
    /// Launch Services needs a file URL rather than that scheme-less URL.
    public static func openDestination(for link: URL) -> URL {
        guard link.scheme == nil, link.host == nil, link.path.hasPrefix("/") else { return link }
        return URL(fileURLWithPath: link.path)
    }

    public init(_ source: String) {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var blocks: [Block] = []
        var prose: [String] = []
        var index = 0
        var fence: (character: Character, count: Int)?

        func flushProse() {
            let text = prose.joined(separator: "\n")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(.text(text))
            }
            prose.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = Self.fenceMarker(line) {
                if let open = fence {
                    if marker.character == open.character, marker.count >= open.count,
                       trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespaces).isEmpty {
                        fence = nil
                    }
                } else {
                    fence = marker
                }
                prose.append(line)
                index += 1
                continue
            }
            if fence == nil, index + 1 < lines.count,
               let headers = Self.cells(line),
               let delimiters = Self.cells(lines[index + 1]),
               headers.count == delimiters.count,
               let alignments = Self.alignments(delimiters) {
                flushProse()
                index += 2
                var rows: [[String]] = []
                while index < lines.count, Self.fenceMarker(lines[index]) == nil,
                      let cells = Self.cells(lines[index]) {
                    // Markdown pads short rows and ignores cells beyond the header width.
                    rows.append(Array((cells + Array(repeating: "", count: headers.count)).prefix(headers.count)))
                    index += 1
                }
                blocks.append(.table(Table(headers: headers, alignments: alignments, rows: rows)))
            } else {
                prose.append(line)
                index += 1
            }
        }
        flushProse()
        self.blocks = blocks
    }

    private static func fenceMarker(_ line: String) -> (character: Character, count: Int)? {
        guard !line.hasPrefix("    "), !line.hasPrefix("\t") else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let character = trimmed.first, character == "`" || character == "~" else { return nil }
        let count = trimmed.prefix(while: { $0 == character }).count
        return count >= 3 ? (character, count) : nil
    }

    private static func cells(_ line: String) -> [String]? {
        guard !line.hasPrefix("    "), !line.hasPrefix("\t") else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var cells: [String] = []
        var cell = ""
        var escaped = false
        var separators = 0
        var endsWithSeparator = false
        for character in trimmed {
            if character == "|", !escaped {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
                separators += 1
                endsWithSeparator = true
            } else {
                // Pipe escapes belong to table syntax, including inside inline code.
                if character == "|", escaped { cell.removeLast() }
                cell.append(character)
                endsWithSeparator = false
            }
            escaped = character == "\\" ? !escaped : false
        }
        guard separators > 0 else { return nil }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        if trimmed.first == "|" { cells.removeFirst() }
        if endsWithSeparator { cells.removeLast() }
        return cells.isEmpty ? nil : cells
    }

    private static func alignments(_ cells: [String]) -> [Table.Alignment]? {
        var result: [Table.Alignment] = []
        for cell in cells {
            var rule = cell[...]
            let left = rule.first == ":"
            let right = rule.last == ":"
            if left { rule = rule.dropFirst() }
            if right { rule = rule.dropLast() }
            guard rule.count >= 3, rule.allSatisfy({ $0 == "-" }) else { return nil }
            result.append(right ? (left ? .center : .right) : .left)
        }
        return result
    }
}
