import Combine
import Foundation

@MainActor
final class RepositoryInboxStore: ObservableObject {
    @Published var search = ""
    @Published var showAll = false
    @Published var selectedTaskID: String?
    @Published var repositoryID: String?
    struct Entry: Identifiable, Sendable {
        let repositoryID: String
        let name: String
        var document: RepositoryInbox?
        var editable = false
        var error: String?
        var missing = false
        var id: String { repositoryID }
    }

    struct UndoEdit {
        let previous: RepositoryInbox
        let document: RepositoryInbox
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var isSaving = false
    @Published private(set) var message: String?
    @Published private(set) var error: String?
    @Published private(set) var undoEdit: UndoEdit?
    @Published private(set) var recentlyCompleted: Set<String> = []
    private var refreshID = UUID()
    private var demo = false
    private var policyCheckedAt: [String: Date] = [:]

    func refresh(repositories: [RepositorySnapshot], demo: Bool, force: Bool = false) async {
        guard !isSaving else { return }
        let token = UUID()
        refreshID = token
        self.demo = demo
        isRefreshing = true
        defer { if refreshID == token { isRefreshing = false } }
        if demo {
            if repositories.isEmpty { entries = []; return }
            if entries.isEmpty {
                entries = Self.demoEntries(repositories)
                recentlyCompleted = Set(entries.flatMap { entry in
                    (entry.document?.tasks ?? []).filter(\.isComplete).map { "\(entry.id):\($0.id)" }
                })
            }
            return
        }
        let previous = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        let checkedAt = force ? [:] : policyCheckedAt
        let values = await withTaskGroup(of: Entry.self, returning: [Entry].self) { group in
            var pending = repositories.makeIterator()
            func enqueue(_ repository: RepositorySnapshot) {
                group.addTask(priority: .utility) {
                    var entry = Entry(repositoryID: repository.id, name: repository.name)
                    do {
                        let document = try RepositoryInboxFile.read(at: repository.url)
                        entry.document = document
                        if let old = previous[repository.id], old.document?.revision == document.revision,
                           let checked = checkedAt[repository.id], Date().timeIntervalSince(checked) < 60 {
                            entry.editable = old.editable
                        } else {
                            entry.editable = RepositoryInboxFile.editingAllowed(at: repository.url)
                        }
                    } catch RepositoryInboxError.missing { entry.missing = true }
                    catch { entry.error = error.localizedDescription }
                    return entry
                }
            }
            for _ in 0..<4 { if let repository = pending.next() { enqueue(repository) } }
            var result: [Entry] = []
            for await entry in group {
                guard !Task.isCancelled else { group.cancelAll(); break }
                result.append(entry)
                if let repository = pending.next() { enqueue(repository) }
            }
            return result
        }
        guard !Task.isCancelled, refreshID == token, !isSaving else { return }
        entries = values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if force { error = nil; message = nil }
        policyCheckedAt = Dictionary(uniqueKeysWithValues: entries.map {
            let old = previous[$0.id]
            let checked = checkedAt[$0.id]
            let reused = old?.document?.revision == $0.document?.revision && checked.map { Date().timeIntervalSince($0) < 60 } == true
            return ($0.id, reused ? checked! : Date())
        })
        if let undoEdit, !entries.contains(where: { $0.document?.revision == undoEdit.document.revision && $0.id == undoEdit.document.repositoryURL.path }) {
            self.undoEdit = nil
        }
    }

    func setComplete(_ complete: Bool, task: RepositoryInboxTask, entry: Entry) async {
        guard !isSaving, entry.editable, let document = entry.document,
              entries.contains(where: { $0.id == entry.id && $0.document?.revision == document.revision }) else { return }
        isSaving = true
        // A refresh that started before this edit must not republish an older snapshot.
        refreshID = UUID()
        isRefreshing = false
        error = nil
        defer { isSaving = false }
        do {
            let updated: RepositoryInbox
            if demo {
                updated = try document.settingComplete(complete, task: task)
            } else {
                updated = try await Task.detached(priority: .userInitiated) {
                    try RepositoryInboxFile.setComplete(complete, task: task, in: document)
                }.value
            }
            guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
            entries[index].document = updated
            let key = "\(entry.id):\(task.id)"
            if complete { recentlyCompleted.insert(key) } else { recentlyCompleted.remove(key) }
            undoEdit = UndoEdit(previous: document, document: updated)
            message = demo ? "Sample change · \(entry.name)/INBOX.md" : "Saved to \(entry.name)/INBOX.md"
        } catch {
            self.error = error.localizedDescription
            message = nil
            undoEdit = nil
        }
    }

    func undo() async {
        guard let edit = undoEdit,
              let entry = entries.first(where: { $0.id == edit.document.repositoryURL.path }),
              entry.document?.revision == edit.document.revision else {
            undoEdit = nil
            error = "The inbox changed. Refresh before making another edit."
            return
        }
        guard !isSaving else { return }
        isSaving = true
        refreshID = UUID()
        isRefreshing = false
        defer { isSaving = false }
        do {
            let restored = demo ? edit.previous : try await Task.detached(priority: .userInitiated) {
                try RepositoryInboxFile.undo(previous: edit.previous, current: edit.document)
            }.value
            if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index].document = restored }
            recentlyCompleted = recentlyCompleted.filter { !$0.hasPrefix(entry.id + ":") }
            undoEdit = nil
            error = nil
            message = demo ? "Sample change undone" : "Change undone"
        } catch { self.error = error.localizedDescription; undoEdit = nil; message = nil }
    }

    func clearRecentCompletions() { recentlyCompleted = [] }

    private static func demoEntries(_ repositories: [RepositorySnapshot]) -> [Entry] {
        let examples: [(String, String)] = [
            ("agentbridge", "- [ ] Improve keyboard navigation\n- [ ] Add loading state\n"),
            ("modelarchviz", "- [ ] Clarify empty graph state\n\nExplain why no graph is visible and help the user take the next step.\n\n- Keep the selected model visible.\n- Offer a clear way to reset filters.\n\n- [ ] Improve export preview\n"),
            ("papertrail", "- [ ] Support multiline notes\n- [ ] Check timezone handling\n"),
            ("repoman", "- [ ] Refine repository filtering\n- [x] Fix toolbar spacing\n")
        ]
        return examples.compactMap { name, source in
            let url = repositories.first(where: { $0.name == name })?.url
                ?? URL(fileURLWithPath: "/demo/\(name)")
            guard let document = try? RepositoryInbox(repositoryURL: url, source: Data(("# Inbox\n\n## Todos\n\n" + source).utf8)) else { return nil }
            return Entry(repositoryID: url.path, name: name, document: document, editable: true)
        }
    }
}
