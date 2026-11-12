import AppKit
import SwiftUI

// The runner compiles this alongside WebsiteTrafficStore so fixtures can use
// private setters without exposing a production mutation API.
extension WebsiteTrafficStore {
    func loadScrollingFixture(count: Int) {
        loadDemo()
        let templates = sites
        sites = (0..<count).map { index in
            let template = templates[index % templates.count]
            let hostname = String(format: "site-%04d.example", index)
            let query = WebsiteTrafficQuery(reader: "/demo", propertyId: "1", hostname: hostname)
            if let source = template.query, let entry = cache[CacheKey(query: source, period: period)] {
                cache[CacheKey(query: query, period: period)] = entry
            }
            return WebsiteTrafficSite(repository: "example/site-\(index)", hostname: hostname, query: query)
        }
    }
}

@main
struct BenchmarkTrafficScrolling {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let traffic = WebsiteTrafficStore()
        traffic.period = .quarter
        let hosting = NSHostingView(rootView: WebsiteTrafficView(traffic: traffic, isDemo: true)
            .preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 720),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        settle(for: 0.3)
        let count = CommandLine.arguments.contains("--small") ? 8 : 150
        traffic.loadScrollingFixture(count: count)
        settle(for: 0.3)
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        guard let scroll = scrollViews(hosting).first, let document = scroll.documentView else {
            fail("Traffic scroll view missing")
        }
        let clip = scroll.contentView
        let maximumOffset = document.frame.height - clip.bounds.height
        guard maximumOffset > 100 else { fail("Traffic fixture is not scrollable") }
        var timings: [Double] = []
        var greatestOffset: CGFloat = 0
        for index in 0..<180 {
            let start = CFAbsoluteTimeGetCurrent()
            // Include the expensive chart entering/leaving the viewport each pass.
            let fraction = CGFloat(index % 60) / 59
            let offset = (index / 60) % 2 == 0 ? fraction : 1 - fraction
            clip.scroll(to: NSPoint(x: 0, y: offset * maximumOffset))
            scroll.reflectScrolledClipView(clip)
            settle(for: 0.001)
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if index >= 10 { timings.append((CFAbsoluteTimeGetCurrent() - start) * 1000) }
            greatestOffset = max(greatestOffset, clip.bounds.minY)
        }
        guard greatestOffset > 100 else { fail("Traffic viewport did not scroll") }
        timings.sort()
        let p95 = timings[Int(Double(timings.count - 1) * 0.95)]
        let frameBudget = 1000.0 / Double(NSScreen.main?.maximumFramesPerSecond ?? 60)
        print(String(format: "sites=%d days=90 median=%.2fms p95=%.2fms max=%.2fms budget=%.2fms",
                     count, timings[timings.count / 2], p95, timings.last!, frameBudget))
        guard p95 < frameBudget else { fail("Traffic scrolling exceeds the display frame budget") }
        print("PASS: traffic scrolling within frame budget")
        if CommandLine.arguments.contains("--verify-controls") {
            app.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            // Reflect native viewport movement into the indicator without relying
            // on synthetic drags, whose tracking depends on physical pointer state.
            for _ in 0..<2 {
                clip.scroll(to: .zero)
                scroll.reflectScrolledClipView(clip)
                settle(for: 0.03)
                guard let scroller = scroll.verticalScroller else { fail("Native traffic scrollbar missing") }
                let start = scroller.rect(for: .knob).minY
                clip.scroll(to: NSPoint(x: 0, y: maximumOffset / 2))
                scroll.reflectScrolledClipView(clip)
                settle(for: 0.03)
                guard scroller.rect(for: .knob).minY > start else { fail("Native scrollbar did not follow the viewport") }
            }
            clip.scroll(to: .zero)
            scroll.reflectScrolledClipView(clip)
            settle(for: 0.03)
            func clickFirstRow() {
                // The fixture's fixed 48-point rows have one-point separators,
                // followed by the 37-point footer and 24-point outer padding.
                let point = document.convert(NSPoint(x: 100, y: collapsedHeight - CGFloat(count * 49) - 36.5), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
                    window.sendEvent(event)
                }
            }
            let collapsedHeight = document.frame.height
            clickFirstRow()
            settle(for: 0.1)
            hosting.layoutSubtreeIfNeeded()
            guard document.frame.height > collapsedHeight + 50 else { fail("Website breakdown did not expand") }
            clickFirstRow()
            settle(for: 0.1)
            hosting.layoutSubtreeIfNeeded()
            guard abs(document.frame.height - collapsedHeight) < 1 else { fail("Website breakdown did not collapse") }
            window.setContentSize(NSSize(width: 900, height: 720))
            settle(for: 0.1)
            hosting.layoutSubtreeIfNeeded()
            guard document.frame.width <= clip.bounds.width + 1 else { fail("Resized traffic content exceeds viewport width") }
            traffic.period = .week
            settle(for: 0.1)
            guard traffic.sites.count == 8, traffic.reportingSites.first.flatMap({ traffic.report(for: $0) })?.days.count == 7
                else { fail("Period switching did not refresh the hosted traffic view") }
            print("PASS: native scrollbar tracking, row expansion/collapse, resizing, and period switching")
        }
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
