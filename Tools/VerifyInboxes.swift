import AppKit
import Foundation
import SwiftUI

@MainActor
private enum InboxVerificationState {
    static let inboxes = RepositoryInboxStore()
}

/// Exercises real native views with illustrative data and disposable source files only.
@main
struct VerifyInboxes: App {
    @NSApplicationDelegateAdaptor(InboxVerifier.self) private var delegate
    @StateObject private var store = RepositoryStore()

    init() {
        setbuf(stdout, nil)
        if let path = ProcessInfo.processInfo.environment["REPOMAN_VERIFICATION_ICON"], let icon = NSImage(contentsOfFile: path) {
            NSApplication.shared.applicationIconImage = icon
        }
        precondition(CommandLine.arguments.contains("--demo") && CommandLine.arguments.contains("--inboxes"))
        UserDefaults.standard.setVolatileDomain([
            "sidebarVisible": true, "sidebarWidth": 300.0, "repositoryFilter": "All",
            "repositorySort": "Name", "repositorySortAscending": true,
            "inboxSidebarOnlyOpen": true, "inboxSidebarSort": "Open todos", "inboxSidebarSortAscending": false
        ], forName: UserDefaults.argumentDomain)
    }

    var body: some Scene {
        WindowGroup("RepoMan inbox verification") {
            ContentView(inboxes: InboxVerificationState.inboxes).environmentObject(store)
                .frame(minWidth: 1180, minHeight: 720).preferredColorScheme(.dark)
        }
        .defaultSize(width: 1586, height: 990)
        .windowStyle(.hiddenTitleBar).windowToolbarStyle(.unified)
        .restorationBehavior(.disabled)
    }
}

@MainActor
private final class InboxVerifier: NSObject, NSApplicationDelegate {
    private enum Failure: Error { case failed(String) }
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let path = ProcessInfo.processInfo.environment["REPOMAN_VERIFICATION_ICON"], let icon = NSImage(contentsOfFile: path) {
            NSApplication.shared.applicationIconImage = icon
        }
        Task {
            do {
                try await verifyStore()
                try await settle()
                window = NSApp.windows.first(where: { $0.toolbar != nil })
                try require(window != nil, "No native window")
                NSApp.activate(ignoringOtherApps: true)
                try await capture(width: 1586, height: 950, name: "inboxes-wide.png")
                try require(InboxVerificationState.inboxes.entries.count == 4, "Inboxes view did not load")
                try await capture(width: 1180, height: 720, name: "inboxes-minimum.png")
                let dragEntry = InboxVerificationState.inboxes.entries.first { $0.name == "agentbridge" }!
                let originalOrder = dragEntry.document!.tasks.map(\.title)
                // The wide capture may extend beyond a laptop display; drag at the minimum size.
                let dragX = window.frame.width - 52
                try await drag(from: NSPoint(x: dragX, y: 202), to: NSPoint(x: dragX - 34, y: 250))
                try require(InboxVerificationState.inboxes.entries.first { $0.id == dragEntry.id }!.document!.tasks.map(\.title) == originalOrder.reversed(),
                            "Native drag did not reorder the todo rows")
                try await capture(width: 1180, height: 720, name: "inboxes-reordered.png")
                await InboxVerificationState.inboxes.undo()
                try await settle()
                try require(InboxVerificationState.inboxes.entries.first { $0.id == dragEntry.id }!.document!.tasks.map(\.title) == originalOrder,
                            "Native drag Undo did not restore todo order")
                try await drag(from: NSPoint(x: dragX, y: 202), to: NSPoint(x: dragX - 34, y: 350))
                try require(InboxVerificationState.inboxes.undoEdit == nil, "Cross-repository drag was accepted")
                window.setContentSize(NSSize(width: 1586, height: 950))
                try await settle()

                click("COMPLETE", x: 360, y: 338)
                try await settle()
                try require(InboxVerificationState.inboxes.undoEdit != nil, "Completing a task did not expose Undo")
                try await capture(width: 1586, height: 950, name: "inboxes-completed.png")
                click("UNDO", x: 596, y: 928)
                try await settle()
                try require(InboxVerificationState.inboxes.undoEdit == nil, "Undo did not clear the pending edit")
                click("ALL", x: 1526, y: 92)
                try await settle()
                try require(InboxVerificationState.inboxes.showAll, "All filter did not update")
                click("OPEN", x: 1462, y: 92)
                try await settle()
                try require(!InboxVerificationState.inboxes.showAll, "Open filter did not update")
                click("SEARCH", x: 1300, y: 92)
                try await settle()
                guard let editor = window.firstResponder as? NSTextView else { throw Failure.failed("Search is not editable") }
                editor.insertText("timezone", replacementRange: NSRange(location: 0, length: 0))
                try await settle()
                try require(InboxVerificationState.inboxes.search == "timezone", "Search did not update")
                click("TRAFFIC", x: 496, y: 26)
                try await settle()
                try await capture(width: 1586, height: 950, name: "traffic-preserved.png")
                click("REPOSITORIES", x: 410, y: 26)
                try await settle()
                try await capture(width: 1586, height: 950, name: "repositories-preserved.png")
                click("INBOXES", x: 568, y: 26)
                try await settle()
                try require(InboxVerificationState.inboxes.search == "timezone", "Tab switching lost inbox search")
                click("SEARCH", x: 1300, y: 92)
                try await settle()
                guard let restoredEditor = window.firstResponder as? NSTextView else { throw Failure.failed("Search did not restore") }
                restoredEditor.selectAll(nil)
                restoredEditor.insertText("", replacementRange: NSRange(location: 0, length: restoredEditor.string.utf16.count))
                try await settle()
                try await capture(width: 1586, height: 950, name: "inboxes-restored.png")
                guard let table = descendants(window.contentView!).compactMap({ $0 as? NSTableView }).first else {
                    throw Failure.failed("Repository table missing")
                }
                let point = table.convert(NSPoint(x: 140, y: table.rect(ofRow: 1).midY), to: nil)
                click("SCOPE", x: point.x, y: window.frame.height - point.y)
                try await settle()
                try require(InboxVerificationState.inboxes.repositoryID?.hasSuffix("/modelarchviz") == true, "Repository scope did not change")
                try await capture(width: 1586, height: 950, name: "inboxes-scoped.png")
                click("ALL_REPOS", x: 150, y: 134)
                try await settle()
                try require(InboxVerificationState.inboxes.repositoryID == nil, "All repositories did not restore combined inboxes")
                try await capture(width: 1586, height: 950, name: "inboxes-final.png")
                click("EXPAND", x: 520, y: 201)
                try await settle()
                try require(InboxVerificationState.inboxes.expandedTaskIDs.count == 1, "Long task did not expand inline")
                try await capture(width: 1586, height: 950, name: "inboxes-expanded.png")
                click("EXPAND", x: 520, y: 201)
                try await settle()
                try require(InboxVerificationState.inboxes.expandedTaskIDs.isEmpty, "Long task did not collapse")
                print("PASS: compact long-task summaries/inline expansion, source save/reorder/undo/conflict/refresh, native drag reorder/undo and cross-repository rejection, completion/undo, search/filters, retained state, all three modes, and wide/minimum captures")
                exit(0)
            } catch {
                fputs("Inbox verification failed: \(error)\n", stderr)
                exit(1)
            }
        }
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(700)) }
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
    private func click(_ control: String, x: CGFloat, y: CGFloat) {
        window.makeKeyAndOrderFront(nil)
        let environment = ProcessInfo.processInfo.environment
        let pointX = environment["REPOMAN_TEST_\(control)_X"].flatMap { Double($0) }.map { CGFloat($0) } ?? x
        let pointY = environment["REPOMAN_TEST_\(control)_Y"].flatMap { Double($0) }.map { CGFloat($0) } ?? y
        print("Click \(control) at \(pointX),\(pointY), window height \(window.frame.height), capture height \(window.contentView?.superview?.bounds.height ?? 0)")
        let location = NSPoint(x: pointX, y: window.frame.height - pointY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                window.sendEvent(event)
            }
        }
    }
    private func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure.failed(message) }
    }

    /// Exercise the native drag session in the foreground verifier, using illustrative data only.
    private func drag(from start: NSPoint, to end: NSPoint) async throws {
        try require(CGPreflightPostEventAccess(), "Native drag verification requires event-posting access")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await settle()
        try require(NSApp.isActive && window.isKeyWindow, "Native drag verifier did not become the active window")
        let screenTop = NSScreen.screens.first!.frame.maxY
        func screenPoint(_ point: NSPoint) -> CGPoint {
            CGPoint(x: window.frame.minX + point.x, y: screenTop - window.frame.maxY + point.y)
        }
        let source = screenPoint(start), destination = screenPoint(end)
        let previousCursor = CGEvent(source: nil)?.location
        defer { if let previousCursor { CGWarpMouseCursorPosition(previousCursor) } }
        await Task.detached {
            let eventSource = CGEventSource(stateID: .hidSystemState)
            eventSource?.localEventsSuppressionInterval = 0
            func post(_ type: CGEventType, at point: CGPoint) {
                CGWarpMouseCursorPosition(point)
                let event = CGEvent(mouseEventSource: eventSource, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
                event?.setIntegerValueField(.mouseEventClickState, value: 1)
                event?.post(tap: .cghidEventTap)
            }
            post(.mouseMoved, at: source)
            post(.leftMouseDown, at: source)
            try? await Task.sleep(for: .milliseconds(150))
            for _ in 0..<4 {
                post(.leftMouseDragged, at: destination)
                try? await Task.sleep(for: .milliseconds(150))
            }
            post(.leftMouseUp, at: destination)
        }.value
        try await settle()
    }

    private func verifyStore() async throws {
        let history = "Finish the sample workflow. " + String(repeating: "Earlier results remain available in the original source. ", count: 40)
        try require(RepositoryInboxesView.taskSummary(history) == "Finish the sample workflow.", "Long task history overwhelmed its summary")
        try require(RepositoryInboxesView.taskSummary("Keep original spacing and punctuation.") == "Keep original spacing and punctuation.", "Short task was rewritten")
        try require(RepositoryInboxesView.taskSummary(String(repeating: "word ", count: 200)).count <= 240, "Unpunctuated task summary is unbounded")
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("repoman-inbox-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try GitRunner.run(["init", "--quiet"], at: root)
        try "/INBOX.md\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        let file = root.appendingPathComponent("INBOX.md")
        let original = "# Inbox\n\n## Todos\n\n- [ ] First\n  Notes for the first task.\n"
        try original.write(to: file, atomically: true, encoding: .utf8)
        let repository = RepositorySnapshot(url: root, name: "fixture", branch: "main", upstream: nil,
            remoteURL: nil, ahead: nil, behind: nil, changes: [], staleBranches: [], worktrees: [], commits: [])
        let model = RepositoryInboxStore()
        await model.refresh(repositories: [repository], demo: false)
        try require(model.entries.count == 1 && model.entries[0].editable, "Source inbox not available for editing")
        try require(model.sidebarStatuses[repository.id] == .open(1), "Sidebar did not count open todos")
        let entry = model.entries[0]
        guard let task = entry.document?.tasks.first else { throw Failure.failed("Task not parsed") }
        await model.setComplete(true, task: task, entry: entry)
        try require(model.error == nil && (try String(contentsOf: file)).contains("[x] First"), "Completion was not written")
        try require(model.sidebarStatuses[repository.id] == .open(0), "Sidebar retained completed todo")
        try require(model.sidebarRepositories([repository], search: "", onlyOpen: true, sort: .openTasks, ascending: false).isEmpty,
                    "Open-only sidebar retained a completed inbox")
        await model.undo()
        try require(model.error == nil && (try String(contentsOf: file)) == original, "Undo did not restore source")
        try require(model.sidebarStatuses[repository.id] == .open(1), "Undo did not restore sidebar count")
        let stale = model.entries[0]
        let changed = original + "- [ ] External task\n"
        try changed.write(to: file, atomically: true, encoding: .utf8)
        await model.setComplete(true, task: task, entry: stale)
        try require(model.error != nil && (try String(contentsOf: file)) == changed, "Conflict overwrote external content")
        await model.refresh(repositories: [repository], demo: false)
        try require(model.entries[0].document?.tasks.count == 2, "External changes did not refresh")
        let beforeCompletion = model.entries[0]
        let originalTasks = beforeCompletion.document!.tasks
        model.expandedTaskIDs.insert("\(repository.id):\(originalTasks[0].id)")
        await model.setComplete(true, task: originalTasks[1], entry: beforeCompletion)
        let beforeMove = model.entries[0]
        let tasks = beforeMove.document!.tasks
        await model.move(tasks[0], relativeTo: tasks[1], after: true, entry: beforeMove)
        let reordered = model.entries[0].document!
        try require(model.error == nil && reordered.tasks.map(\.title) == ["External task", "First"], "Reordering was not saved")
        try require(try RepositoryInboxFile.read(at: root) == reordered, "Saved order differs from the visible order")
        try require(model.expandedTaskIDs.contains("\(repository.id):\(reordered.tasks[1].id)"), "Expansion followed a byte offset instead of its task")
        try require(model.recentlyCompleted.contains("\(repository.id):\(reordered.tasks[0].id)"), "Recent completion followed the wrong task")
        await model.undo()
        try require(model.error == nil && model.entries[0].document == beforeMove.document, "Reorder Undo did not restore the source")
        try require(model.expandedTaskIDs.contains("\(repository.id):\(tasks[0].id)"), "Undo lost task expansion")
        try require(model.recentlyCompleted.contains("\(repository.id):\(tasks[1].id)"), "Reorder Undo hid a recently completed task")
        await model.move(tasks[0], relativeTo: tasks[1], after: true, entry: model.entries[0])
        let externallyChanged = try String(contentsOf: file, encoding: .utf8) + "External edit after reorder\n"
        try externallyChanged.write(to: file, atomically: true, encoding: .utf8)
        await model.undo()
        try require(model.error != nil && (try String(contentsOf: file, encoding: .utf8)) == externallyChanged, "Reorder Undo overwrote an external edit")
        await model.refresh(repositories: [], demo: false)
        try require(model.entries.isEmpty, "Removed repository retained source data")

        let demo = RepositoryInboxStore()
        let repositories = ["repoman", "papertrail", "agentbridge", "modelarchviz", "missing"].map { name in
            RepositorySnapshot(url: URL(fileURLWithPath: "/demo/\(name)"), name: name, branch: "main", upstream: nil,
                remoteURL: nil, ahead: nil, behind: nil, changes: [], staleBranches: [], worktrees: [], commits: [])
        }
        await demo.refresh(repositories: repositories, demo: true)
        func names(search: String = "", onlyOpen: Bool = false,
                   sort: RepositoryInboxStore.SidebarSort = .openTasks, ascending: Bool = false) -> [String] {
            demo.sidebarRepositories(repositories, search: search, onlyOpen: onlyOpen, sort: sort, ascending: ascending).map(\.name)
        }
        try require(names() == ["agentbridge", "modelarchviz", "papertrail", "repoman", "missing"],
                    "Sidebar did not sort by open count with alphabetical ties")
        try require(names(onlyOpen: true) == ["agentbridge", "modelarchviz", "papertrail", "repoman"], "Open filter retained an unread inbox")
        try require(names(search: "PAPER", onlyOpen: true) == ["papertrail"], "Search did not combine with the open filter")
        try require(names(sort: .name, ascending: true) == ["agentbridge", "missing", "modelarchviz", "papertrail", "repoman"], "Name sort failed")
        try require(names(ascending: true).last == "papertrail", "Ascending count sort failed")
        let completed = demo.entries.first { $0.name == "repoman" }!
        try require(demo.sidebarStatuses[completed.id] == .open(1), "Completed sample task counted as open")
        demo.showAll = true
        try require(demo.sidebarStatuses[completed.id] == .open(1), "All task view changed open count")
    }

    private func capture(width: CGFloat, height: CGFloat, name: String) async throws {
        window.setContentSize(NSSize(width: width, height: height))
        try await settle()
        guard let toolbar = window.toolbar,
              let item = toolbar.items.first(where: { $0.itemIdentifier.rawValue == "repository-topbar" }),
              toolbar.visibleItems?.contains(where: { $0 === item }) == true,
              let frame = window.contentView?.superview,
              let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else {
            throw Failure.failed("Native toolbar or capture missing at width \(width)")
        }
        frame.layoutSubtreeIfNeeded()
        func display(_ view: NSView) {
            view.needsDisplay = true
            view.display()
            view.subviews.forEach(display)
        }
        display(frame)
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]),
              let directory = ProcessInfo.processInfo.environment["REPOMAN_SCREENSHOT_DIRECTORY"] else {
            throw Failure.failed("Missing capture output directory")
        }
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }
}
