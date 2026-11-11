import AppKit
import SwiftUI

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

    private var selection: (RepositoryInboxStore.Entry, RepositoryInboxTask)? {
        let candidates = scoped.flatMap { entry in tasks(entry).map { (entry, $0) } }
        return candidates.first { key($0.1, $0.0) == inboxes.selectedTaskID }
            ?? (isDemo && inboxes.selectedTaskID == nil ? candidates.first { $0.1.title == "Clarify empty graph state" } : nil)
            ?? candidates.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(24)
            GeometryReader { geometry in
                HStack(spacing: 16) {
                    taskList.frame(width: max(320, (geometry.size.width - 16) * 0.51))
                    taskDetails.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
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
        HStack(alignment: .top, spacing: 9) {
            Button {
                inboxes.selectedTaskID = key(task, entry)
                Task { await inboxes.setComplete(!task.isComplete, task: task, entry: entry) }
            } label: {
                Image(systemName: task.isComplete ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15)).foregroundStyle(task.isComplete ? Theme.green : Theme.secondary)
            }
            .buttonStyle(.plain).disabled(inboxes.isSaving || !entry.editable)
            .accessibilityLabel(task.isComplete ? "Reopen \(task.title)" : "Complete \(task.title)")
            .accessibilityIdentifier("inbox-toggle-\(entry.name)-\(task.lineNumber)")
            Button { inboxes.selectedTaskID = key(task, entry) } label: {
                Text(inline(task.title)).strikethrough(task.isComplete)
                    .foregroundStyle(task.isComplete ? Theme.secondary : Theme.primary)
                    .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityIdentifier("inbox-select-\(entry.name)-\(task.lineNumber)")
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(selection.map { key($0.1, $0.0) == key(task, entry) } == true ? Theme.selection : .clear,
                    in: RoundedRectangle(cornerRadius: 3))
    }

    private var taskDetails: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let (entry, task) = selection {
                Text("\(entry.name) / INBOX.md").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(inline(task.title)).font(.system(size: 18, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !task.notes.isEmpty {
                            notes(task.notes)
                        } else { Text("No additional notes.").foregroundStyle(Theme.secondary) }
                        if !entry.editable {
                            Label(RepositoryInboxError.readOnly.localizedDescription, systemImage: "lock")
                                .font(.system(size: 11)).foregroundStyle(Theme.amber)
                        }
                    }
                    .textSelection(.enabled)
                }
                Spacer(minLength: 0)
                Button { openSource(entry) } label: { Label("Open source", systemImage: "arrow.up.right.square") }
                    .buttonStyle(.plain).foregroundStyle(Theme.blue).disabled(isDemo)
                    .help("Open INBOX.md in its default editor")
            } else {
                Spacer()
                Text("Select a task to read its notes.").foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .padding(22).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))
        .accessibilityIdentifier("inbox-task-details")
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
