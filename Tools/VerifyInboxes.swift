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
            "repositorySort": "Name", "repositorySortAscending": true
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
                click("SCOPE", x: 150, y: 384)
                try await settle()
                try require(InboxVerificationState.inboxes.repositoryID?.hasSuffix("/modelarchviz") == true, "Repository scope did not change")
                try await capture(width: 1586, height: 950, name: "inboxes-scoped.png")
                click("ALL_REPOS", x: 150, y: 134)
                try await settle()
                try require(InboxVerificationState.inboxes.repositoryID == nil, "All repositories did not restore combined inboxes")
                try await capture(width: 1586, height: 950, name: "inboxes-final.png")
                print("PASS: source save/undo/conflict/refresh, native completion/undo, search/filters, retained state, all three modes, and wide/minimum captures")
                exit(0)
            } catch {
                fputs("Inbox verification failed: \(error)\n", stderr)
                exit(1)
            }
        }
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(700)) }
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

    private func verifyStore() async throws {
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
        let entry = model.entries[0]
        guard let task = entry.document?.tasks.first else { throw Failure.failed("Task not parsed") }
        await model.setComplete(true, task: task, entry: entry)
        try require(model.error == nil && (try String(contentsOf: file)).contains("[x] First"), "Completion was not written")
        await model.undo()
        try require(model.error == nil && (try String(contentsOf: file)) == original, "Undo did not restore source")
        let stale = model.entries[0]
        let changed = original + "- [ ] External task\n"
        try changed.write(to: file, atomically: true, encoding: .utf8)
        await model.setComplete(true, task: task, entry: stale)
        try require(model.error != nil && (try String(contentsOf: file)) == changed, "Conflict overwrote external content")
        await model.refresh(repositories: [repository], demo: false)
        try require(model.entries[0].document?.tasks.count == 2, "External changes did not refresh")
        await model.refresh(repositories: [], demo: false)
        try require(model.entries.isEmpty, "Removed repository retained source data")
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
