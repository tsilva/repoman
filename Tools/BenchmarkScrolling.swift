import AppKit
import SwiftUI

/// Compiled in the same source file as RepositoryStore by benchmark-scrolling.sh,
/// so the fixture can use its private setters without adding a production test API.
extension RepositoryStore {
    func loadScrollingFixture(count: Int) {
        precondition(isDemo)
        start()
        let templates = repositories
        repositories = (0..<count).map { index in
            let source = templates[index % templates.count]
            let name = String(format: "repository-%04d", index)
            return RepositorySnapshot(
                url: URL(fileURLWithPath: "/repoman-scrolling-fixture/\(name)"),
                name: name, branch: source.branch, upstream: source.upstream,
                remoteURL: source.remoteURL, ahead: source.ahead, behind: source.behind,
                changes: source.changes, staleBranches: source.staleBranches,
                worktrees: source.worktrees, commits: source.commits,
                checkedAt: source.checkedAt, rootFiles: source.rootFiles
            )
        }
        selectedPath = repositories.first?.id
    }

    func advanceScrollingFixtureProgress(_ completed: Int) {
        let active = Array(repositories.prefix(4))
        let token = repositoryLoads[active[0].id]?.first ?? beginLoading(active.map(\.url))
        let order = issueCatalog.checks.map(\.id)
        let results = Dictionary(uniqueKeysWithValues: order.prefix(completed).map { ($0, RepositoryCheckResult.findings([])) })
        for repository in active {
            queueProgress(RepositoryInspectionReport(snapshot: repository, results: results, checkOrder: order),
                          generation: generation, token: token, preservingFetchState: true, didFetch: false)
        }
    }

    func finishScrollingFixtureProgress() {
        for token in Set(repositoryLoads.values.flatMap { $0 }) { endLoading(token: token) }
    }
}

@main
struct BenchmarkScrolling {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        UserDefaults.standard.setVolatileDomain([
            "repositoryFilter": RepositoryFilter.all.rawValue,
            "repositorySort": RepositorySort.name.rawValue,
            "repositorySortAscending": true,
            "sidebarVisible": true, "sidebarWidth": 340.0
        ], forName: UserDefaults.argumentDomain)
        let store = RepositoryStore()
        guard store.isDemo else { fail("Benchmark requires --demo") }
        store.loadScrollingFixture(count: 300)
        let hosting = NSHostingView(rootView: ContentView().environmentObject(store).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1586, height: 916),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0..<10 {
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            settle(for: 0.02)
        }
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        guard let scrollView = scrollViews(hosting).first(where: { $0.frame.width < 500 }),
              let document = scrollView.documentView else { fail("Sidebar scroll view missing") }
        let clip = scrollView.contentView
        guard document.frame.height - clip.bounds.height > 10_000 else { fail("Fixture is not scrollable") }
        let displayHz = NSScreen.main?.maximumFramesPerSecond ?? 60
        let frameBudget = 1000.0 / Double(displayHz)
        print("repositories=\(store.repositories.count) displayHz=\(displayHz)")
        var timings: [Double] = []
        var greatestOffset: CGFloat = 0
        for index in 0..<180 {
            let start = CFAbsoluteTimeGetCurrent()
            let offset = CGFloat(index % 90) / 89 * 10_000
            clip.scroll(to: NSPoint(x: 0, y: offset))
            scrollView.reflectScrolledClipView(clip)
            // Include work SwiftUI schedules after the native viewport moves.
            settle(for: 0.001)
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if index >= 10 { timings.append((CFAbsoluteTimeGetCurrent() - start) * 1000) }
            greatestOffset = max(greatestOffset, clip.bounds.minY)
        }
        guard greatestOffset > 1000 else { fail("Scroll events did not move the list") }
        timings.sort()
        let p95 = timings[Int(Double(timings.count - 1) * 0.95)]
        print(String(format: "scroll median=%.2fms p95=%.2fms max=%.2fms budget=%.2fms",
                     timings[timings.count / 2], p95, timings.last!, frameBudget))
        guard p95 < frameBudget else { fail("Scrolling exceeds the display's frame budget") }

        // Drag the actual custom indicator twice, with a native scroll in between.
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<2 {
            clip.scroll(to: .zero)
            scrollView.reflectScrolledClipView(clip)
            settle(for: 0.03)
            guard let scroller = scrollView.verticalScroller else { fail("Native scrollbar missing") }
            let knob = scroller.rect(for: .knob)
            let dragStart = scroller.convert(NSPoint(x: knob.midX, y: knob.midY), to: nil)
            let dragEnd = NSPoint(x: dragStart.x, y: dragStart.y - scrollView.bounds.height / 4)
            for (index, type) in [NSEvent.EventType.leftMouseDown, .leftMouseDragged, .leftMouseUp].enumerated() {
                let event = NSEvent.mouseEvent(with: type, location: index == 0 ? dragStart : dragEnd,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + Double(index) * 0.05,
                    windowNumber: window.windowNumber, context: nil, eventNumber: index, clickCount: 1, pressure: 1)!
                app.postEvent(event, atStart: false)
            }
            while let event = app.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.01),
                                           inMode: .default, dequeue: true) {
                app.sendEvent(event)
            }
            settle(for: 0.03)
            guard clip.bounds.minY > clip.bounds.height else { fail("Scrollbar drag did not move the list") }
        }
        print("PASS: repeated custom scrollbar dragging")
        if let table = document as? NSTableView {
            table.selectRowIndexes(IndexSet(integer: 42), byExtendingSelection: false)
            settle(for: 0.03)
            guard store.selectedPath == store.repositories[42].id else { fail("Native row selection did not select the repository") }
            print("PASS: native repository selection")
        }
        var progressTimings: [Double] = []
        for index in 0..<60 {
            let start = CFAbsoluteTimeGetCurrent()
            store.advanceScrollingFixtureProgress(index)
            clip.scroll(to: NSPoint(x: 0, y: CGFloat(index) * 120))
            scrollView.reflectScrolledClipView(clip)
            settle(for: 0.001)
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if index >= 5 { progressTimings.append((CFAbsoluteTimeGetCurrent() - start) * 1000) }
        }
        progressTimings.sort()
        let progressP95 = progressTimings[Int(Double(progressTimings.count - 1) * 0.95)]
        print(String(format: "scroll during progress p95=%.2fms", progressP95))
        settle(for: 0.12)
        guard store.repositoryCheckProgress[store.repositories[0].id]?.completed == min(59, store.issueCatalog.checks.count)
            else { fail("Latest inspection progress was not published") }
        store.advanceScrollingFixtureProgress(60)
        store.finishScrollingFixtureProgress()
        settle(for: 0.12)
        guard store.repositoryCheckProgress.isEmpty, store.loadingRepositoryIDs.isEmpty
            else { fail("Pending progress restored a finished inspection") }
        print("PASS: latest inspection progress and completed-load cleanup")
        guard progressP95 < frameBudget else { fail("Scrolling during scans exceeds the display's frame budget") }
        print("PASS: native scrolling within frame budget")
    }

    @MainActor
    private static func settle(for seconds: TimeInterval) {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while Date() < deadline { _ = RunLoop.current.run(mode: .default, before: deadline) }
    }

    private static func fail(_ message: String) -> Never {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}
