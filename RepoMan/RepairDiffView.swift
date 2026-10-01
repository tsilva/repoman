import SwiftUI

struct RepairChangesBadge: View {
    let diff: RepairDiff
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(diff.files.isEmpty ? "View changes" : "\(diff.files.count) \(diff.files.count == 1 ? "file" : "files") changed")
                    .foregroundStyle(Theme.secondary)
                if !diff.files.isEmpty { RepairDiffCounts(additions: diff.additions, deletions: diff.deletions) }
            }
            .font(.system(size: 12)).padding(.horizontal, 12).padding(.vertical, 7)
            .background(hovered ? Theme.selection : Theme.control, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain).onHover { hovered = $0 }
        .accessibilityLabel("Review changes")
        .accessibilityValue("\(diff.files.count) files changed, \(diff.additions) additions, \(diff.deletions) deletions")
        .accessibilityIdentifier("repair-changes-badge")
        .help("Open changes sidebar")
    }
}

private struct RepairDiffCounts: View {
    let additions: Int
    let deletions: Int
    var body: some View {
        HStack(spacing: 5) {
            Text("+\(additions)").foregroundStyle(Theme.green)
            Text("-\(deletions)").foregroundStyle(Theme.red)
        }.monospacedDigit().fixedSize()
    }
}

struct RepositoryWorkingTreeSidebar: View {
    @EnvironmentObject private var store: RepositoryStore
    let repository: RepositorySnapshot
    let close: () -> Void
    @State private var source: String?
    @State private var error: String?

    var body: some View {
        Group {
            if let source {
                RepairDiffSidebar(source: source, title: "Uncommitted changes",
                                  emptyTitle: "No uncommitted changes",
                                  emptyDescription: "This repository's working tree is clean.", close: close)
            } else {
                Panel {
                    HStack {
                        Text("Uncommitted changes").font(.system(size: 17, weight: .semibold))
                        Spacer()
                        ToolbarActionButton(symbol: "xmark", title: "Close changes sidebar", action: close)
                    }
                } content: {
                    if let error {
                        ContentUnavailableView("Could not load changes", systemImage: "exclamationmark.triangle",
                                               description: Text(error))
                    } else {
                        ProgressView("Loading changes…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .task(id: repository.checkedAt) {
            let directory = repository.url
            do {
                let loaded: String
                if store.isDemo {
                    loaded = repository.changes.map { change in
                        "diff --git a/\(change.path) b/\(change.path)\n--- a/\(change.path)\n+++ b/\(change.path)\n@@ -1 +1 @@\n-Previous illustrative content\n+Updated illustrative content\n"
                    }.joined()
                } else {
                    loaded = try await Task.detached(priority: .userInitiated) {
                        try RepairDiff.workingTreeSource(at: directory)
                    }.value
                }
                guard !Task.isCancelled else { return }
                source = loaded
                error = nil
            } catch {
                guard !Task.isCancelled else { return }
                source = nil
                self.error = error.localizedDescription
            }
        }
    }
}

struct RepairDiffSidebar: View {
    let source: String
    var title = "Changes"
    var emptyTitle = "No file diff available"
    var emptyDescription = "The agent has not supplied a file diff yet."
    let close: () -> Void
    @State private var diff = RepairDiff("")
    @State private var selectedFileID: Int?
    @State private var filter = ""
    private var selectedFile: RepairDiff.File? {
        diff.files.first { $0.id == selectedFileID } ?? diff.files.first
    }
    private var filteredFiles: [RepairDiff.File] {
        diff.files.filter { filter.isEmpty || $0.path.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        Panel {
            HStack(spacing: 10) {
                Text(title).font(.system(size: 17, weight: .semibold))
                Text("\(diff.files.count) \(diff.files.count == 1 ? "file" : "files")")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                Spacer()
                RepairDiffCounts(additions: diff.additions, deletions: diff.deletions).font(.system(size: 12))
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 11)).frame(width: 26, height: 26)
                }.buttonStyle(.plain).foregroundStyle(Theme.secondary)
                    .help("Close changes sidebar").accessibilityLabel("Close changes sidebar")
            }
        } content: {
            HSplitView {
                Group {
                    if let file = selectedFile {
                        RepairFileDiffView(file: file).id(file.id)
                    } else {
                        ContentUnavailableView(emptyTitle, systemImage: "doc.text", description: Text(emptyDescription))
                    }
                }.frame(minWidth: 230, maxWidth: .infinity, maxHeight: .infinity)
                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
                        TextField("Filter files…", text: $filter).textFieldStyle(.plain)
                            .accessibilityLabel("Filter changed files")
                        if !filter.isEmpty {
                            Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(Theme.secondary).accessibilityLabel("Clear file filter")
                        }
                    }.font(.system(size: 11)).padding(8)
                        .background(Theme.control, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
                        .padding(.horizontal, 10).padding(.top, 10)
                    CodexScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(RepairDiffTree.nodes(filteredFiles)) { node in
                                RepairDiffTreeRow(node: node, selection: selectedFile?.id) { selectedFileID = $0 }
                            }
                            if filteredFiles.isEmpty {
                                Text("No matching files").font(.system(size: 11)).foregroundStyle(Theme.secondary).padding(10)
                            }
                        }.padding(.horizontal, 6).padding(.bottom, 10)
                    }
                }.frame(minWidth: 150, idealWidth: 190, maxWidth: 280, maxHeight: .infinity)
            }
        }
        .foregroundStyle(Theme.primary)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .task(id: source) {
            let input = source
            let parsed = await Task.detached(priority: .userInitiated) { RepairDiff(input) }.value
            guard !Task.isCancelled else { return }
            let path = selectedFile?.path
            diff = parsed
            selectedFileID = parsed.files.first { $0.path == path }?.id ?? parsed.files.first?.id
        }
    }
}

private struct RepairDiffTree: Identifiable {
    let id: String
    let name: String
    let file: RepairDiff.File?
    let children: [RepairDiffTree]

    static func nodes(_ files: [RepairDiff.File], depth: Int = 0, prefix: String = "") -> [Self] {
        let groups = Dictionary(grouping: files) { file in
            let parts = file.path.split(separator: "/")
            return depth < parts.count ? String(parts[depth]) : "Changes"
        }
        return groups.keys.sorted { left, right in
            let leftFolder = groups[left]!.contains { $0.path.split(separator: "/").count > depth + 1 }
            let rightFolder = groups[right]!.contains { $0.path.split(separator: "/").count > depth + 1 }
            return leftFolder == rightFolder ? left.localizedStandardCompare(right) == .orderedAscending : leftFolder
        }.map { name in
            let group = groups[name]!
            let path = prefix + name
            if let file = group.first, file.path.split(separator: "/").count <= depth + 1 {
                return Self(id: "file-\(file.id)", name: name, file: file, children: [])
            }
            return Self(id: path, name: name, file: nil, children: nodes(group, depth: depth + 1, prefix: path + "/"))
        }
    }
}

private struct RepairDiffTreeRow: View {
    let node: RepairDiffTree
    let selection: Int?
    let select: (Int) -> Void
    @State private var expanded = true

    var body: some View {
        if let file = node.file {
            Button { select(file.id) } label: {
                HStack(spacing: 6) {
                    Image(systemName: file.reviewSymbol).foregroundStyle(file.reviewColor)
                    Text(node.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 3)
                    if file.additions > 0 || file.deletions > 0 {
                        RepairDiffCounts(additions: file.additions, deletions: file.deletions).font(.system(size: 10))
                    }
                }.font(.system(size: 11)).padding(.horizontal, 6).padding(.vertical, 8)
                    .background(selection == file.id ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).help(file.path)
                .accessibilityLabel("\(file.path), \(file.status)")
                .accessibilityAddTraits(selection == file.id ? .isSelected : [])
        } else {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(node.children) { child in
                    RepairDiffTreeRow(node: child, selection: selection, select: select)
                }
            } label: {
                Text(node.name).font(.system(size: 11, weight: .medium)).padding(.vertical, 6)
            }.tint(Theme.secondary)
        }
    }
}

private struct RepairFileDiffView: View {
    let file: RepairDiff.File
    private var emphasizedRanges: [Int: Range<Int>] {
        var ranges: [Int: Range<Int>] = [:]
        var removed: [RepairDiff.Line] = []
        var added: [RepairDiff.Line] = []
        func flush() {
            for (old, new) in zip(removed, added) {
                let a = Array(old.text), b = Array(new.text)
                var prefix = 0
                while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
                var suffix = 0
                while suffix < min(a.count, b.count) - prefix,
                      a[a.count - suffix - 1] == b[b.count - suffix - 1] { suffix += 1 }
                if prefix < a.count - suffix { ranges[old.id] = prefix..<(a.count - suffix) }
                if prefix < b.count - suffix { ranges[new.id] = prefix..<(b.count - suffix) }
            }
            removed = []; added = []
        }
        for line in file.lines {
            switch line.kind {
            case .deletion:
                if !added.isEmpty { flush() }
                removed.append(line)
            case .addition: added.append(line)
            default: flush()
            }
        }
        flush()
        return ranges
    }

    var body: some View {
        let emphasis = emphasizedRanges
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: file.reviewSymbol).foregroundStyle(file.reviewColor)
                Text(file.path).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle).help(file.path)
                Spacer(minLength: 4)
                RepairDiffCounts(additions: file.additions, deletions: file.deletions).font(.system(size: 12))
            }.padding(.horizontal, 14).frame(height: 42).background(Theme.panel)
            Rectangle().fill(Theme.border).frame(height: 1)
            if file.status == "Renamed", let old = file.oldPath {
                Text("Renamed from \(old)").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if file.lines.isEmpty {
                            Text("\(file.status) · No text changes").foregroundStyle(Theme.secondary).padding(16)
                        }
                        ForEach(file.lines) { line in
                            RepairDiffLineView(line: line, emphasis: emphasis[line.id], path: file.path)
                        }
                    }.frame(minWidth: geometry.size.width, alignment: .leading).textSelection(.enabled)
                }
            }
        }.background(Theme.panel)
    }
}

private struct RepairDiffLineView: View {
    let line: RepairDiff.Line
    let emphasis: Range<Int>?
    let path: String
    private var text: AttributedString {
        let source = line.text.isEmpty ? " " : line.text
        var value = AttributedString(source)
        if line.kind == .addition || line.kind == .deletion || line.kind == .context {
            let ext = (path as NSString).pathExtension.lowercased()
            let patterns: [(String, Color)]
            if ["md", "markdown"].contains(ext) {
                patterns = [("^#{1,6} .*$", Theme.red), ("`[^`]+`", Theme.green)]
            } else if ["swift", "js", "jsx", "ts", "tsx", "py", "json", "sh", "yml", "yaml"].contains(ext) {
                // Lightweight token colors; the diff remains readable for every file type.
                patterns = [
                    (#"\b(?:import|from|let|var|const|func|function|struct|class|enum|public|private|return|if|else|guard|for|in|await|async|case|switch|def|true|false|nil|null|None)\b"#, Theme.purple),
                    (#"\b[0-9]+(?:\.[0-9]+)?\b"#, Theme.amber),
                    (#""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#, Theme.green),
                    (#"//.*$"#, Theme.subtle)
                ]
            } else { patterns = [] }
            for (pattern, color) in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                    guard let range = Range(match.range, in: source),
                          let start = AttributedString.Index(range.lowerBound, within: value),
                          let end = AttributedString.Index(range.upperBound, within: value) else { continue }
                    value[start..<end].foregroundColor = color
                }
            }
        }
        if let emphasis {
            let start = value.characters.index(value.startIndex, offsetBy: emphasis.lowerBound)
            let end = value.characters.index(value.startIndex, offsetBy: emphasis.upperBound)
            value[start..<end].backgroundColor = color.opacity(0.28)
        }
        return value
    }
    private var color: Color {
        switch line.kind {
        case .addition: return Theme.green
        case .deletion: return Theme.red
        case .hunk, .note: return Theme.subtle
        case .context: return Theme.primary
        }
    }
    private var background: Color {
        switch line.kind {
        case .addition: return Theme.green.opacity(0.13)
        case .deletion: return Theme.red.opacity(0.13)
        case .hunk: return Theme.control.opacity(0.5)
        default: return .clear
        }
    }
    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(line.kind == .addition || line.kind == .deletion ? color : .clear).frame(width: 3)
            Text(line.oldNumber.map(String.init) ?? "").foregroundStyle(line.kind == .deletion ? color : Theme.subtle)
                .frame(width: 36, alignment: .trailing).padding(.trailing, 7)
            Text(line.newNumber.map(String.init) ?? "").foregroundStyle(line.kind == .addition ? color : Theme.subtle)
                .frame(width: 36, alignment: .trailing).padding(.trailing, 7)
            Text(line.kind == .addition ? "+" : line.kind == .deletion ? "-" : " ")
                .foregroundStyle(color).frame(width: 16)
            Text(text).foregroundStyle(line.kind == .hunk || line.kind == .note ? Theme.subtle : Theme.primary)
                .fixedSize(horizontal: true, vertical: false).padding(.trailing, 18)
            Spacer(minLength: 0)
        }.font(.system(size: 11, design: .monospaced)).frame(height: 22)
            .frame(maxWidth: .infinity, alignment: .leading).background(background)
    }
}

private extension RepairDiff.File {
    var reviewSymbol: String {
        let ext = (path as NSString).pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp", "svg", "icns"].contains(ext) { return "photo.fill" }
        if ext == "swift" { return "swift" }
        return status == "Added" ? "doc.badge.plus" : status == "Deleted" ? "doc.badge.minus" : "doc.text"
    }
    var reviewColor: Color {
        if status == "Deleted" { return Theme.red }
        if reviewSymbol == "photo.fill" { return Theme.purple }
        if reviewSymbol == "swift" { return Theme.amber }
        return Theme.green
    }
}
