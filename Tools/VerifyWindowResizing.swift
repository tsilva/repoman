import AppKit
import SwiftUI

@main
struct VerifyWindowResizing: App {
    @NSApplicationDelegateAdaptor(ResizeVerifier.self) private var delegate
    @StateObject private var store = RepositoryStore()

    init() {
        setbuf(stdout, nil)
        precondition(CommandLine.arguments.contains("--demo"), "Resize verification requires --demo")
        UserDefaults.standard.setVolatileDomain([
            "sidebarVisible": true, "sidebarWidth": 340.0,
            "repositoryFilter": "All", "repositorySortAscending": true
        ], forName: UserDefaults.argumentDomain)
    }

    var body: some Scene {
        WindowGroup("RepoMan resize verification") {
            ContentView().environmentObject(store)
                .frame(minWidth: 1_180, minHeight: 720)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1_320, height: 800)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .restorationBehavior(.disabled)
    }
}

@MainActor
final class ResizeVerifier: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.verify() }
    }

    private func settle(_ seconds: Double = 0.08) {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while Date() < deadline {
            if let event = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.005),
                                           inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
    }

    private func fail(_ message: String) -> Never {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }

    private func verify() {
        guard let window = NSApp.windows.first(where: { $0.toolbar != nil }), let screen = window.screen else {
            fail("Missing app window")
        }
        let start = NSRect(x: screen.visibleFrame.minX + 30, y: screen.visibleFrame.minY + 30,
                           width: 1_320, height: 800)
        window.setFrame(start, display: true)
        settle(0.3)
        var missing = 0
        var origins: [CGFloat] = []
        var items = Set<ObjectIdentifier>()
        var samples = 0
        var initialLeading: CGFloat?
        var initialTrailing: CGFloat?
        func controls(_ view: NSView) -> [NSView] {
            if String(describing: type(of: view)).contains("ControlView") { return [view] }
            return view.subviews.flatMap(controls)
        }
        func checkAnchors() {
            guard let view = window.toolbar?.items.first(where: {
                $0.itemIdentifier.rawValue.hasPrefix("repository-topbar")
            })?.view, let toolbarWindow = view.window else { fail("Toolbar missing") }
            let regions = controls(view).map {
                toolbarWindow.convertToScreen($0.convert($0.bounds, to: nil)).offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
            }.sorted { $0.minX < $1.minX }
            print("width=\(window.frame.width) toolbarWidth=\(view.bounds.width) controls=\(regions.map { $0.minX })")
            initialLeading = initialLeading ?? regions.first?.minX
            initialTrailing = initialTrailing ?? regions.last.map { window.frame.width - $0.maxX }
            guard regions.count == 6, abs(regions.first!.minX - initialLeading!) < 1,
                  abs(regions.last!.maxX - (window.frame.width - initialTrailing!)) < 1 else {
                fail("Toolbar controls moved away from their window-edge anchors")
            }
        }
        func sample() {
            samples += 1
            guard let item = window.toolbar?.items.first(where: {
                $0.itemIdentifier.rawValue.hasPrefix("repository-topbar")
            }), let view = item.view, view.window != nil, !view.isHidden,
                window.toolbar?.visibleItems?.contains(where: { $0 === item }) == true else {
                missing += 1
                return
            }
            items.insert(ObjectIdentifier(item))
            let origin = view.convert(view.bounds.origin, to: nil)
            origins.append(origin.x)
        }
        sample()
        checkAnchors()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
            MainActor.assumeIsolated { sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        for _ in 0..<3 {
            // Deliver the actual double-click to the app's local event monitor.
            let point = NSPoint(x: 700, y: window.frame.height - 22)
            let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 2, pressure: 1)!
            NSApp.postEvent(event, atStart: false)
            while let queued = NSApp.nextEvent(matching: .leftMouseDown, until: Date(timeIntervalSinceNow: 0.02),
                                               inMode: .default, dequeue: true) { NSApp.sendEvent(queued) }
            settle(0.3)
            guard abs(window.frame.width - screen.visibleFrame.width) < 1 else {
                fail("Double-click did not maximize the window: \(window.frame)")
            }
            checkAnchors()
            let restore = NSEvent.mouseEvent(with: .leftMouseDown,
                location: NSPoint(x: 700, y: window.frame.height - 22), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 2, clickCount: 2, pressure: 1)!
            NSApp.postEvent(restore, atStart: false)
            while let queued = NSApp.nextEvent(matching: .leftMouseDown, until: Date(timeIntervalSinceNow: 0.02),
                                               inMode: .default, dequeue: true) { NSApp.sendEvent(queued) }
            settle(0.3)
            guard abs(window.frame.width - start.width) < 1 else { fail("Double-click did not restore") }
            checkAnchors()
        }
        timer.invalidate()
        for width: CGFloat in [1_180, screen.visibleFrame.width, 1_180, 1_586, 1_320] {
            window.setFrame(NSRect(x: start.minX, y: start.minY, width: width, height: 800), display: true)
            settle(0.15)
            sample()
            checkAnchors()
        }
        print("samples=\(samples) missing=\(missing) distinctToolbarItems=\(items.count) originRange=\(origins.min() ?? -1)...\(origins.max() ?? -1)")
        let stable = missing == 0 && items.count == 1 && !origins.isEmpty
            && (origins.max()! - origins.min()!) < 1
        print(stable ? "PASS: toolbar remains attached and aligned through repeated double-click resizing" : "FAIL: toolbar jumps or is recreated during double-click resizing")
        exit(stable ? 0 : 1)
    }
}
