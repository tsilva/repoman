import AppKit
import SwiftUI

/// Synthetic state checks and a native-window capture, without account access or saved settings changes.
@main
struct VerifyTrafficOverview: App {
    @NSApplicationDelegateAdaptor(TrafficVerifier.self) private var delegate
    @StateObject private var store = RepositoryStore()

    init() {
        precondition(CommandLine.arguments.contains("--demo") && CommandLine.arguments.contains("--traffic"))
        UserDefaults.standard.setVolatileDomain(["sidebarVisible": true, "sidebarWidth": 300.0,
            "repositoryFilter": "All", "repositorySortAscending": true,
            "AppleShowScrollBars": "Always"], forName: UserDefaults.argumentDomain)
    }

    var body: some Scene {
        WindowGroup("RepoMan traffic verification") {
            ContentView(initialTraffic: !CommandLine.arguments.contains("--repositories")).environmentObject(store)
                .frame(minWidth: 1180, minHeight: 720).preferredColorScheme(.dark)
        }
        .defaultSize(width: 1586, height: 990)
        .windowStyle(.hiddenTitleBar).windowToolbarStyle(.unified)
        .restorationBehavior(.disabled)
    }
}

@MainActor
private final class TrafficVerifier: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon = NSImage(contentsOfFile: "image-assets/icon/icon-1024.png") {
            NSApplication.shared.applicationIconImage = icon
        }
        Task {
            do {
                try await verifyStates()
                if CommandLine.arguments.contains("--live") { try await verifyLive() }
                try await Task.sleep(for: .seconds(1))
                guard let window = NSApp.windows.first(where: { $0.toolbar != nil }) else {
                    throw VerificationError.failed("No native window")
                }
                for (width, name) in [(1586.0, "traffic-wide.png"), (1180.0, "traffic-minimum.png")] {
                    window.setContentSize(NSSize(width: width, height: width > 1200 ? 950 : 720))
                    try await Task.sleep(for: .seconds(1))
                    if !CommandLine.arguments.contains("--repositories"), let content = window.contentView {
                        let scrollers = nativeScrollViews(in: content)
                        try check(!scrollers.contains { $0.hasHorizontalScroller }, "Horizontal scroller present")
                        try check(!scrollers.contains { scroll in
                            guard let document = scroll.documentView else { return false }
                            return document.frame.width > scroll.contentView.bounds.width + 1
                        }, "Scroll content exceeds viewport width")
                    }
                    let items = window.toolbar?.items ?? []
                    print("TOOLBAR width=\(window.frame.width) items=\(items.map { $0.itemIdentifier.rawValue }) visible=\((window.toolbar?.visibleItems ?? []).map { $0.itemIdentifier.rawValue }) frames=\(items.map { $0.view?.frame ?? .zero })")
                    guard let frame = window.contentView?.superview,
                          let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else {
                        throw VerificationError.failed("Could not capture window")
                    }
                    frame.displayIfNeeded()
                    frame.cacheDisplay(in: frame.bounds, to: bitmap)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else {
                        throw VerificationError.failed("Could not encode capture")
                    }
                    if let directory = ProcessInfo.processInfo.environment["REPOMAN_SCREENSHOT_DIRECTORY"] {
                        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
                    }
                    guard let item = items.first(where: { $0.itemIdentifier.rawValue.hasPrefix("repository-topbar") }),
                          window.toolbar?.visibleItems?.contains(where: { $0 === item }) == true else {
                        throw VerificationError.failed("Traffic toolbar is hidden at width \(width)")
                    }
                }
                print("PASS: traffic cache, unavailable/stale states, period switching, and native window capture")
                exit(0)
            } catch {
                fputs("Traffic verification failed: \(error)\n", stderr)
                exit(1)
            }
        }
    }

    private enum VerificationError: Error { case failed(String) }
    private func nativeScrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { nativeScrollViews(in: $0) }
    }
    private func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw VerificationError.failed(message) }
    }

    private func verifyLive() async throws {
        let start = Date()
        let traffic = WebsiteTrafficStore()
        await traffic.refresh(demo: false, force: true)
        print("LIVE: \(traffic.reportingSites.count)/\(traffic.sites.count) configured sites returned fresh reports in \(String(format: "%.1f", Date().timeIntervalSince(start))) seconds")
        let unavailable = traffic.sites.filter { traffic.report(for: $0) == nil }.map(\.hostname)
        if !unavailable.isEmpty { print("LIVE unavailable: " + unavailable.joined(separator: ", ")) }
        try check(!traffic.reportingSites.isEmpty, "No live reports available")
        if let site = traffic.reportingSites.first(where: { (traffic.report(for: $0)?.current.sessions ?? 0) > 0 }), let query = site.query {
            _ = try await Task.detached {
                (try query.breakdown(period: .month, dimension: "sessionDefaultChannelGroup"),
                 try query.breakdown(period: .month, dimension: "landingPagePlusQueryString"))
            }.value
            print("LIVE: source and landing-page reports decoded successfully")
        }
    }

    private func verifyStates() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("repoman-traffic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = directory.appendingPathComponent("reader")
        let configuration = directory.appendingPathComponent("analytics.json")
        let script = #"""
        #!/usr/bin/python3
        import json,sys
        body=json.load(sys.stdin)
        result={'metricHeaders':body['metrics'],'metadata':{'timeZone':'Europe/Lisbon'}}
        if body['dimensions'][0]['name']=='date':
            result.update(dimensionHeaders=body['dimensions'],rowCount=0)
        else:
            result.update(dimensionHeaders=body['dimensions'],rowCount=1,rows=[{'dimensionValues':[{'value':'site.example'}],'metricValues':[{'value':str(n)} for n in [42,100,220,60]]}])
        print(json.dumps(result))
        """#
        try script.write(to: reader, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: reader.path)
        let body: [String: Any] = ["reportReader": reader.path, "repositories": ["owner/site": ["propertyId": "123", "hostnames": ["site.example"]]]]
        try JSONSerialization.data(withJSONObject: body).write(to: configuration)
        let traffic = WebsiteTrafficStore(configurationURL: configuration)
        await traffic.refresh(demo: false)
        try check(traffic.reportingSites.count == 1 && traffic.totals.sessions == 100, "Successful report not published")
        try check(traffic.totals.engagement == 0.6, "Engagement numerator/denominator incorrect")
        let site = traffic.sites[0]
        try check(traffic.report(for: site)?.days.count == 30, "Wrong daily window")
        try "#!/bin/sh\nexit 1\n".write(to: reader, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: reader.path)
        await traffic.refresh(demo: false, force: true)
        try check(traffic.report(for: site)?.current.sessions == 100 && traffic.isStale(site), "Failed refresh discarded last good report")
        try check(!traffic.hasReports && traffic.totals.sessions == 0, "Stale data included in fresh portfolio totals")
        traffic.period = .week
        await traffic.refresh(demo: false, force: true)
        try check(traffic.report(for: site) == nil && !traffic.isStale(site), "Different period reused old report")
        traffic.period = .month
        try check(traffic.report(for: site)?.current.sessions == 100, "Switching period lost cached report")
        try Data("invalid".utf8).write(to: configuration)
        await traffic.refresh(demo: false, force: true)
        try check(traffic.configurationMessage != nil && traffic.sites.isEmpty, "Invalid configuration left apparently valid coverage")
    }
}
