import AppKit
import SwiftUI
import UniformTypeIdentifiers

private struct InboxRefreshKey: FocusedValueKey { typealias Value = () -> Void }
extension FocusedValues {
    var inboxRefresh: (() -> Void)? {
        get { self[InboxRefreshKey.self] }
        set { self[InboxRefreshKey.self] = newValue }
    }
}

struct RepositoryInboxesView: View {
    @ObservedObject var inboxes: RepositoryInboxStore
    let repositories: [RepositorySnapshot]
    let repositoryID: String?
    let isDemo: Bool
    @State private var draggedTask: InboxTaskDrag?
    @State private var dropTarget: InboxTaskDropTarget?
    @State private var rowHeights: [String: CGFloat] = [:]

    private func key(_ task: RepositoryInboxTask, _ entry: RepositoryInboxStore.Entry) -> String { "\(entry.id):\(task.id)" }

    private var scoped: [RepositoryInboxStore.Entry] {
        inboxes.entries.filter { repositoryID == nil || $0.id == repositoryID }
    }

    private func tasks(_ entry: RepositoryInboxStore.Entry) -> [RepositoryInboxTask] {
        (entry.document?.tasks ?? []).filter {
            (inboxes.showAll || !$0.isComplete || inboxes.recentlyCompleted.contains(key($0, entry)))
                && (inboxes.search.isEmpty || "\(entry.name) \($0.title) \($0.notes)".localizedCaseInsensitiveContains(inboxes.search))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(24)
            taskList.frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 24).padding(.bottom, 20)
            footer
        }
        .foregroundStyle(Theme.primary)
        .background(Theme.background)
        .accessibilityIdentifier("repository-inboxes-overview")
        .focusedSceneValue(\.inboxRefresh, { Task { await refresh(force: true) } })
        .onChange(of: inboxes.showAll) { _, _ in inboxes.clearRecentCompletions() }
        .task(id: repositories.map(\.id)) {
            await refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                await refresh()
            }
        }
    }

    private func refresh(force: Bool = false) async { await inboxes.refresh(repositories: repositories, demo: isDemo, force: force) }

    private var header: some View {
        HStack(spacing: 16) {
            Text("Inboxes").font(.system(size: 22, weight: .semibold))
            Spacer(minLength: 4)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
                TextField("Search inboxes…", text: $inboxes.search).textFieldStyle(.plain)
                    .accessibilityIdentifier("inbox-search")
            }
            .padding(.horizontal, 10).frame(width: 220, height: 30)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))
            Picker("Show tasks", selection: $inboxes.showAll) {
                Text("Open").tag(false)
                Text("All").tag(true)
            }
            .labelsHidden()
            .pickerStyle(.segmented).frame(width: 130).accessibilityIdentifier("inbox-task-filter")
        }
    }

    private var taskList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if inboxes.isRefreshing && inboxes.entries.isEmpty {
                    ProgressView("Reading inboxes…").padding(20)
                } else {
                    let visible = scoped.filter { !tasks($0).isEmpty }
                    if visible.isEmpty { emptyList.padding(24) }
                    ForEach(visible) { entry in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(entry.name).font(.system(size: 13, weight: .semibold))
                                Spacer(minLength: 8)
                                Button { openSource(entry) } label: { Label("INBOX.md", systemImage: "arrow.up.right.square") }
                                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.blue)
                                    .disabled(isDemo).help("Open the source inbox")
                            }
                            .padding(.horizontal, 14)
                            if !entry.editable {
                                Label("Read only", systemImage: "lock").font(.system(size: 10)).foregroundStyle(Theme.amber)
                                    .help(RepositoryInboxError.readOnly.localizedDescription).padding(.horizontal, 14)
                            }
                            VStack(spacing: 0) {
                                ForEach(tasks(entry)) { task in taskRow(task, entry) }
                            }
                        }
                        .padding(.top, 18).padding(.bottom, 20)
                        if entry.id != visible.last?.id {
                            Divider().overlay(Theme.border).padding(.horizontal, 14)
                        }
                    }
                }
            }
            .padding(8)
        }
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))
    }

    private var emptyList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: inboxes.search.isEmpty ? "tray" : "magnifyingglass").font(.system(size: 23)).foregroundStyle(Theme.secondary)
            Text(inboxes.search.isEmpty ? (inboxes.showAll ? "No inbox tasks" : "No open tasks") : "No matching tasks")
                .font(.system(size: 16, weight: .semibold))
            Text(inboxes.search.isEmpty ? "Tasks appear from the Todos section of each repository’s INBOX.md." : "Try a different search or show all tasks.")
                .foregroundStyle(Theme.secondary)
            ForEach(scoped.filter { $0.error != nil }) { entry in
                Text("\(entry.name): \(entry.error ?? "")").foregroundStyle(Theme.amber)
            }
        }
    }

    private func taskRow(_ task: RepositoryInboxTask, _ entry: RepositoryInboxStore.Entry) -> some View {
        let taskKey = key(task, entry)
        let summary = Self.taskSummary(task.title)
        let hasContext = summary != task.title || !task.notes.isEmpty
        let expanded = inboxes.expandedTaskIDs.contains(taskKey)
        return VStack(alignment: .leading, spacing: 12) {
          HStack(alignment: .top, spacing: 9) {
            Button {
                Task { await inboxes.setComplete(!task.isComplete, task: task, entry: entry) }
            } label: {
                Image(systemName: task.isComplete ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15)).foregroundStyle(task.isComplete ? Theme.green : Theme.secondary)
            }
            .buttonStyle(.plain).disabled(inboxes.isSaving || !entry.editable)
            .accessibilityLabel(task.isComplete ? "Reopen \(summary)" : "Complete \(summary)")
            .accessibilityIdentifier("inbox-toggle-\(entry.name)-\(task.lineNumber)")
            if hasContext {
                Button {
                    if expanded { inboxes.expandedTaskIDs.remove(taskKey) }
                    else { inboxes.expandedTaskIDs.insert(taskKey) }
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Text(inline(summary)).strikethrough(task.isComplete)
                            .foregroundStyle(task.isComplete ? Theme.secondary : Theme.primary)
                            .multilineTextAlignment(.leading).lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10)).foregroundStyle(Theme.secondary).padding(.top, 3)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(expanded ? "Collapse" : "Expand") \(summary)")
                .accessibilityIdentifier("inbox-expand-\(entry.name)-\(task.lineNumber)")
                .help(expanded ? "Hide task context" : "Show the full task and notes")
            } else {
                Text(inline(summary)).strikethrough(task.isComplete)
                    .foregroundStyle(task.isComplete ? Theme.secondary : Theme.primary)
                    .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            if entry.editable, (entry.document?.tasks.count ?? 0) > 1 {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    .frame(width: 20, height: 20).contentShape(Rectangle())
                    .help("Drag to reorder this todo")
                    .accessibilityLabel("Reorder \(summary)")
                    .accessibilityIdentifier("inbox-drag-\(entry.name)-\(task.lineNumber)")
                    .onDrag {
                        guard !inboxes.isSaving, let document = entry.document else { return NSItemProvider() }
                        let drag = InboxTaskDrag(repositoryID: entry.id, revision: document.revision, task: task)
                        draggedTask = drag
                        return NSItemProvider(object: drag.token as NSString)
                    } preview: {
                        Text(summary).font(.system(size: 13)).lineLimit(2).padding(10)
                            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .accessibilityAction(named: "Move up") { moveAdjacent(task, entry, down: false) }
                    .accessibilityAction(named: "Move down") { moveAdjacent(task, entry, down: true) }
            }
          }
          if expanded {
            VStack(alignment: .leading, spacing: 12) {
                if summary != task.title { Text(inline(task.title)).lineSpacing(4) }
                if !task.notes.isEmpty { notes(task.notes) }
            }
            .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 24)
          }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowHeights[taskKey] = $0 }
        .overlay(alignment: dropTarget?.after == true ? .bottom : .top) {
            if dropTarget?.key == taskKey {
                Rectangle().fill(Theme.blue).frame(height: 2).allowsHitTesting(false)
            }
        }
        .onDrop(of: [InboxTaskDrag.type], delegate: InboxTaskDropDelegate(
            inboxes: inboxes, entry: entry, task: task, key: taskKey,
            height: rowHeights[taskKey] ?? 36, draggedTask: $draggedTask, target: $dropTarget))
    }

    private func moveAdjacent(_ task: RepositoryInboxTask, _ entry: RepositoryInboxStore.Entry, down: Bool) {
        let visible = tasks(entry)
        guard let index = visible.firstIndex(of: task), visible.indices.contains(index + (down ? 1 : -1)) else { return }
        let neighbor = visible[index + (down ? 1 : -1)]
        Task { await inboxes.move(task, relativeTo: neighbor, after: down, entry: entry) }
    }

    /// Presentation only: a checkbox still represents the complete source item.
    static func taskSummary(_ title: String) -> String {
        guard title.count > 240 else { return title }
        var firstSentence = title
        title.enumerateSubstrings(in: title.startIndex..<title.endIndex, options: .bySentences) { sentence, _, _, stop in
            if let sentence { firstSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines) }
            stop = true
        }
        guard firstSentence.count > 240 else { return firstSentence }
        return String(firstSentence.prefix(237)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if inboxes.isSaving { ProgressView().controlSize(.mini); Text("Saving…") }
            else if let error = inboxes.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.amber)
            } else if let message = inboxes.message {
                Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(Theme.green)
            }
            if inboxes.undoEdit != nil {
                Button("Undo") { Task { await inboxes.undo() } }.buttonStyle(.plain).foregroundStyle(Theme.blue)
                    .disabled(inboxes.isSaving).accessibilityIdentifier("inbox-undo")
            }
            Spacer(minLength: 8)
            let missing = scoped.filter(\.missing).count
            let unavailable = scoped.filter { $0.error != nil }.count
            if missing > 0 { Text("\(missing) without an inbox").foregroundStyle(Theme.secondary) }
            if unavailable > 0 {
                Label("\(unavailable) unavailable", systemImage: "exclamationmark.triangle").foregroundStyle(Theme.amber)
                    .help(scoped.filter { $0.error != nil }.map { "\($0.name): \($0.error ?? "")" }.joined(separator: "\n"))
            }
        }
        .font(.system(size: 11)).padding(.horizontal, 24).frame(minHeight: 44)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    private func notes(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(text.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                let lines = paragraph.components(separatedBy: .newlines).filter { !$0.isEmpty }
                if !lines.isEmpty && lines.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") }) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Image(systemName: "circle.fill").font(.system(size: 4)).accessibilityHidden(true)
                                Text(inline(String(line.trimmingCharacters(in: .whitespaces).dropFirst(2))))
                            }
                        }
                    }
                } else { Text(inline(paragraph)).lineSpacing(5) }
            }
        }
        .font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openSource(_ entry: RepositoryInboxStore.Entry) {
        guard !isDemo, let document = entry.document else { return }
        NSWorkspace.shared.open(document.url)
    }
}

private struct InboxTaskDrag {
    static let type = UTType.utf8PlainText
    let token = UUID().uuidString
    let repositoryID: String
    let revision: String
    let task: RepositoryInboxTask
}

private struct InboxTaskDropTarget {
    let key: String
    let after: Bool
}

@MainActor
private struct InboxTaskDropDelegate: DropDelegate {
    let inboxes: RepositoryInboxStore
    let entry: RepositoryInboxStore.Entry
    let task: RepositoryInboxTask
    let key: String
    let height: CGFloat
    @Binding var draggedTask: InboxTaskDrag?
    @Binding var target: InboxTaskDropTarget?

    func validateDrop(info: DropInfo) -> Bool {
        guard !inboxes.isSaving, entry.editable, let drag = draggedTask,
              drag.repositoryID == entry.id, let document = entry.document,
              drag.revision == document.revision,
              inboxes.entries.contains(where: { $0.id == entry.id && $0.document?.revision == drag.revision }),
              (try? document.taskOrder(moving: drag.task, relativeTo: task, after: false)) != nil else { return false }
        return info.hasItemsConforming(to: [InboxTaskDrag.type])
    }

    func dropEntered(info: DropInfo) { updateTarget(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return DropProposal(operation: .forbidden) }
        updateTarget(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if target?.key == key { target = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info), let drag = draggedTask,
              let provider = info.itemProviders(for: [InboxTaskDrag.type]).first else { return false }
        let after = info.location.y > height / 2
        target = nil
        draggedTask = nil
        // Only this session's opaque token is accepted; external drops never change an inbox.
        provider.loadDataRepresentation(forTypeIdentifier: InboxTaskDrag.type.identifier) { data, _ in
            guard let data, String(data: data, encoding: .utf8) == drag.token else { return }
            Task { @MainActor in
                await inboxes.move(drag.task, relativeTo: task, after: after, entry: entry)
            }
        }
        return true
    }

    private func updateTarget(_ info: DropInfo) {
        guard validateDrop(info: info) else { return }
        target = InboxTaskDropTarget(key: key, after: info.location.y > height / 2)
    }
}
