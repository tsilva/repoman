import AppKit
import Foundation
import JavaScriptCore
import XCTest
@testable import RepoManCore

final class RepositoryWebsiteChecksTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RepoManWebsite-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func snapshot() -> RepositorySnapshot {
        RepositorySnapshot(url: root, name: "test", branch: "main", upstream: nil, remoteURL: nil,
            ahead: nil, behind: nil, changes: [], staleBranches: [], worktrees: [], commits: [], rootFiles: [])
    }
    private func metadata(_ source: String) throws {
        try source.write(to: root.appendingPathComponent(".repo-metadata.toml"), atomically: true, encoding: .utf8)
    }
    private actor Calls {
        var count = 0
        func record() { count += 1 }
        func value() -> Int { count }
    }
    private var healthy: WebsiteProbe {
        WebsiteProbe(status: 200, cloudflare: true, isHTML: true,
            analytics: WebsiteTelemetryEvidence(configured: true, observed: true, accepted: true),
            sentry: WebsiteTelemetryEvidence(configured: true, observed: true, accepted: true))
    }

    func testNoOptInMakesNoNetworkCallsAndNewChecksHaveRecipes() async throws {
        let calls = Calls()
        let checks = RepositoryWebsiteChecks.checks(load: { _, _ in await calls.record(); return WebsiteProbe() })
        let report = await RepositoryIssueCatalog(checks: checks).inspect(snapshot())
        XCTAssertTrue(report.findings().isEmpty)
        XCTAssertTrue(report.unavailableChecks.isEmpty)
        let count = await calls.value(); XCTAssertEqual(count, 0)
        XCTAssertEqual(Set(checks.map(\.id)).count, 4)
        for check in checks {
            XCTAssertTrue(RepositoryIssueCatalog().checks.contains { $0.id == check.id })
            XCTAssertTrue(RepairRecipeCatalog().recipes.contains { $0.id == check.id })
        }
    }

    func testDomainsSupportCommentsQuotesMultilineAndRejectAmbiguousOrUnsafeValues() throws {
        try metadata("""
        short-name = "example"
        domains = [
            "APP.tsilva.eu", # production
            'www.tsilva.eu',
        ]
        [unrelated]
        domain = "ignored.tsilva.eu"
        """)
        XCTAssertEqual(try WebsiteDomains.load(RepositoryInspectionContext(snapshot: snapshot())), ["app.tsilva.eu", "www.tsilva.eu"])
        for raw in ["\"app.tsilva.eu\"", "[\"eviltsilva.eu\"]", "[\"tsilva.eu.evil.test\"]", "[\"https://app.tsilva.eu\"]",
                    "[\"app.tsilva.eu:443\"]", "[\"*.tsilva.eu\"]", "[\"127.0.0.1\"]", "[\"-app.tsilva.eu\"]",
                    "[\"app..tsilva.eu\"]", "[\"a.tsilva.eu\",\"A.tsilva.eu\"]", "[true]", "[\"a.tsilva.eu\",,]"] {
            XCTAssertThrowsError(try WebsiteDomains.parse(raw), raw)
        }
        try metadata("domains = ['a.tsilva.eu']\ndomains = ['b.tsilva.eu']")
        XCTAssertThrowsError(try WebsiteDomains.load(RepositoryInspectionContext(snapshot: snapshot())))
    }

    func testFourChecksShareProbeAndMetadataChangesBypassPersistedResults() async throws {
        let calls = Calls(), healthy = healthy
        let checks = RepositoryWebsiteChecks.checks(load: { _, _ in await calls.record(); return healthy })
        let catalog = RepositoryIssueCatalog(checks: checks)
        let cache = RepositoryInspectionCache(url: root.appendingPathComponent("cache.json"))
        _ = await catalog.inspect(snapshot(), cache: cache)
        try metadata("domains = ['test.tsilva.eu']")
        let report = await catalog.inspect(snapshot(), cache: cache)
        XCTAssertTrue(report.unavailableChecks.isEmpty)
        XCTAssertTrue(report.findings().isEmpty)
        let count = await calls.value(); XCTAssertEqual(count, 1)
        try metadata("domains = []")
        _ = await catalog.inspect(snapshot(), cache: cache)
        let after = await calls.value(); XCTAssertEqual(after, 1)
    }

    func testPartialResultPreservesOfflineDomainFindingAndCannotVerifyUnknownDelivery() async throws {
        try metadata("domains = ['a.tsilva.eu', 'b.tsilva.eu']")
        let healthy = healthy
        let catalog = RepositoryIssueCatalog(checks: RepositoryWebsiteChecks.checks(load: { domain, _ in
            domain == "a.tsilva.eu" ? WebsiteProbe(transportFailure: "DNS lookup failed.") : healthy
        }))
        let report = await catalog.inspect(snapshot())
        XCTAssertEqual(report.findings().map(\.checkID), ["website.online"])
        XCTAssertEqual(report.findings().map(\.subject), ["a.tsilva.eu"])
        XCTAssertEqual(Set(report.unavailableChecks.keys), ["website.sentry", "website.analytics", "website.cloudflare"])
        let old = RepositoryFinding(repositoryID: snapshot().id, checkID: "website.sentry", subject: "a.tsilva.eu",
            title: "Sentry", evidence: "", category: .setup, symbol: "checkmark")
        if case .unknown = catalog.verify(old, in: report) {} else { XCTFail("Unknown delivery must not resolve a repair") }
    }

    func testConfigurationAndBeaconQueueingDoNotProveDeliveryOrMislabelConsent() {
        var probe = healthy
        probe.analytics.accepted = false
        probe.sentry.accepted = false; probe.sentry.observed = false
        if case .deliveryUnverified = RepositoryWebsiteChecks.classify(probe, checkID: "website.analytics") {} else { XCTFail("Queued beacon is not proof") }
        if case .deliveryUnverified = RepositoryWebsiteChecks.classify(probe, checkID: "website.sentry") {} else { XCTFail("Configured SDK is not proof") }
        probe.analytics.disabled = true; probe.consentGated = true
        if case .unknown = RepositoryWebsiteChecks.classify(probe, checkID: "website.analytics") {} else { XCTFail("Consent must remain unknown") }
        probe.consentGated = false
        if case .issue = RepositoryWebsiteChecks.classify(probe, checkID: "website.analytics") {} else { XCTFail("Disabled SDK should be reported") }
        probe = healthy; probe.sentry.rejected = true
        if case .issue = RepositoryWebsiteChecks.classify(probe, checkID: "website.sentry") {} else { XCTFail("Rejected telemetry should be reported") }
    }

    @MainActor
    func testProbeWaitsForDelayedSentryImport() async throws {
        var elapsed: UInt64 = 0
        let evidence = try await WebsiteBrowserProbe.collectEvidence(sample: {
            WebsiteBrowserProbe.Evidence(analytics: WebsiteTelemetryEvidence(configured: true, observed: true, accepted: true),
                sentry: WebsiteTelemetryEvidence(configured: elapsed >= 9_000_000_000))
        }, sleep: { elapsed += $0 })
        XCTAssertTrue(evidence.sentry.configured, "An eight-second boot timer plus an asynchronous import must be allowed to finish")
        XCTAssertLessThanOrEqual(elapsed, 20_000_000_000)
    }

    @MainActor
    func testProbeBoundsSilentPageAndFinishesEarlyOnlyWithBothDeliveries() async throws {
        var elapsed: UInt64 = 0
        _ = try await WebsiteBrowserProbe.collectEvidence(sample: { WebsiteBrowserProbe.Evidence() }, sleep: { elapsed += $0 })
        XCTAssertEqual(elapsed, 20_000_000_000)
        elapsed = 0
        let accepted = WebsiteTelemetryEvidence(observed: true, accepted: true)
        _ = try await WebsiteBrowserProbe.collectEvidence(sample: {
            WebsiteBrowserProbe.Evidence(analytics: accepted, sentry: accepted)
        }, sleep: { elapsed += $0 })
        XCTAssertEqual(elapsed, 1_000_000_000)
    }

    @MainActor
    func testSamplerRecognizesBundledScopesAndLegacyHubsWithoutSendingEvents() throws {
        for carrier in [
            "window.Sentry = {getClient: function(){return client;}}",
            "window.__SENTRY__ = {'10.45.0': {defaultCurrentScope: bound}}",
            "window.__SENTRY__ = {'10.45.0': {defaultCurrentScope: unbound, defaultIsolationScope: bound}}",
            "window.__SENTRY__ = {'10.45.0': {stack: {getScope: function(){return bound;}}}}",
            "window.__SENTRY__ = {hub: bound}"
        ] {
            let js = try XCTUnwrap(JSContext())
            js.evaluateScript(#"""
            var window = this;
            var document = {scripts: [], querySelectorAll: function(){return [];}};
            var options = {dsn:'PRIVATE-DSN', enabled:true};
            var client = {getOptions:function(){return options;}};
            var bound = {getClient:function(){return client;}}, unbound = {getClient:function(){return null;}};
            var empty = function(){return {configured:false,observed:false,accepted:false,rejected:false,disabled:false};};
            window.__repomanWebsiteEvidence = {analytics:empty(),sentry:empty()};
            """#)
            js.evaluateScript(carrier)
            func sample() throws -> WebsiteBrowserProbe.Evidence {
                let json = try XCTUnwrap(js.evaluateScript(WebsiteBrowserProbe.sample)?.toString())
                XCTAssertNil(js.exception)
                XCTAssertFalse(json.contains("PRIVATE"))
                return try JSONDecoder().decode(WebsiteBrowserProbe.Evidence.self, from: Data(json.utf8))
            }
            let evidence = try sample()
            XCTAssertTrue(evidence.sentry.configured, carrier)
            XCTAssertFalse(evidence.sentry.accepted, "Reading setup must never manufacture delivery")
            js.evaluateScript("options.enabled = false")
            XCTAssertTrue(try sample().sentry.disabled)
            js.evaluateScript("options.dsn = null")
            XCTAssertFalse(try sample().sentry.configured)
        }
    }

    func testInitializedSilentSentryOffersDeliveryVerificationWithoutIncompleteCheck() async throws {
        try metadata("domains = ['test.tsilva.eu']")
        var probe = healthy
        probe.sentry.observed = false; probe.sentry.accepted = false
        let sample = probe
        let catalog = RepositoryIssueCatalog(checks: RepositoryWebsiteChecks.checks(load: { _, _ in sample }))
        let report = await catalog.inspect(snapshot())
        XCTAssertNil(report.unavailableChecks["website.sentry"], "Successful setup inspection must not be labelled incomplete")
        let finding = try XCTUnwrap(report.findings().first { $0.checkID == "website.sentry" })
        XCTAssertEqual(finding.severity, .information)
        XCTAssertTrue(finding.evidence.contains("setup confirmed"))
        XCTAssertTrue(finding.evidence.contains("delivery unverified"))
        XCTAssertEqual(finding.recipeIDs, ["website.sentry"])
        if case .absent = catalog.verify(finding, in: report) { XCTFail("Setup alone must not resolve delivery verification") }
    }

    func testCloudflareEvidenceSurvivesFailureAndRedirectsRequireExplicitHost() {
        let probe = WebsiteProbe(status: 503, cloudflare: true, transportFailure: "TLS verification failed.")
        XCTAssertEqual(RepositoryWebsiteChecks.classify(probe, checkID: "website.cloudflare"), .pass)
        let hosts: Set<String> = ["test.tsilva.eu", "www.tsilva.eu"]
        XCTAssertTrue(WebsiteDomains.permits(URL(string: "https://www.tsilva.eu/"), domains: hosts))
        for url in ["http://test.tsilva.eu/", "https://evil.tsilva.eu/", "https://test.tsilva.eu:8443/", "https://user:secret@test.tsilva.eu/"] {
            XCTAssertFalse(WebsiteDomains.permits(URL(string: url), domains: hosts))
        }
    }

    func testExceptionsAreDomainSpecificAndSkipTheProbe() async throws {
        try metadata("domains = ['a.tsilva.eu', 'b.tsilva.eu']")
        try #"{"exceptions":{"website.online":{"a.tsilva.eu":"Deliberate private service"}}}"#
            .write(to: root.appendingPathComponent(".repoman.json"), atomically: true, encoding: .utf8)
        let calls = Calls()
        let checks = RepositoryWebsiteChecks.checks(load: { _, _ in await calls.record(); return WebsiteProbe(status: 404) })
        let report = await RepositoryIssueCatalog(checks: checks.filter { $0.id == "website.online" }).inspect(snapshot())
        XCTAssertEqual(report.findings().map(\.subject), ["b.tsilva.eu"])
        let count = await calls.value(); XCTAssertEqual(count, 1)
    }

    func testCacheReusesOrdinaryProbeAndFreshRepairBypassesIt() async {
        let cache = WebsiteProbeCache(), calls = Calls(), healthy = healthy
        let load: RepositoryWebsiteChecks.Loader = { _, _ in await calls.record(); return healthy }
        let start = Date(timeIntervalSince1970: 1000)
        let hosts: Set<String> = ["test.tsilva.eu"]
        _ = await cache.load("test.tsilva.eu", domains: hosts, allowCached: true, now: start, loader: load)
        let reused = await cache.load("test.tsilva.eu", domains: hosts, allowCached: true, now: start.addingTimeInterval(100), loader: load)
        XCTAssertTrue(reused.cached)
        let fresh = await cache.load("test.tsilva.eu", domains: hosts, allowCached: false, now: start.addingTimeInterval(101), loader: load)
        XCTAssertFalse(fresh.cached)
        let changed = await cache.load("test.tsilva.eu", domains: hosts.union(["www.tsilva.eu"]), allowCached: true, now: start.addingTimeInterval(102), loader: load)
        XCTAssertFalse(changed.cached)
        let count = await calls.value(); XCTAssertEqual(count, 3)
    }

    @MainActor
    func testBrowserObserverPreservesRequestsAndRedactsEvidence() throws {
        let js = try XCTUnwrap(JSContext())
        js.evaluateScript(#"""
        var window = this, location = {href:'https://test.tsilva.eu/'};
        var navigator = {sendBeacon: function(){return true;}};
        var fetchCalls = 0;
        var fetch = function(){fetchCalls++; return Promise.resolve({status:204});};
        function XMLHttpRequest() {}
        XMLHttpRequest.prototype.open = function(){};
        XMLHttpRequest.prototype.send = function(){};
        XMLHttpRequest.prototype.addEventListener = function(){};
        function URL(input) {
          this.hostname = input.split('/')[2]; this.pathname = '/' + input.split('/').slice(3).join('/').split('?')[0];
        }
        """#)
        js.evaluateScript(WebsiteBrowserProbe.observer)
        XCTAssertNil(js.exception)
        js.evaluateScript(#"navigator.sendBeacon('https://www.google-analytics.com/g/collect?tid=PRIVATE-ID', 'payload');"#)
        XCTAssertTrue(js.evaluateScript("__repomanWebsiteEvidence.analytics.observed").toBool())
        XCTAssertFalse(js.evaluateScript("__repomanWebsiteEvidence.analytics.accepted").toBool())
        js.evaluateScript(#"fetch('https://ingest.sentry.io/api/1/envelope/', {body:'{}\n{"type":"session"}\n{"secret":"PRIVATE-DSN"}'});"#)
        XCTAssertNil(js.exception)
        XCTAssertTrue(js.evaluateScript("__repomanWebsiteEvidence.sentry.observed").toBool())
        XCTAssertEqual(js.evaluateScript("fetchCalls").toInt32(), 1)
        let evidence = js.evaluateScript("JSON.stringify(__repomanWebsiteEvidence)").toString() ?? ""
        XCTAssertFalse(evidence.contains("PRIVATE")); XCTAssertFalse(evidence.contains("payload"))
    }

    /// Explicit opt-in exercises the exact production probe used by the app, with no synthetic events.
    @MainActor
    func testLiveProductionProbe() async throws {
        guard let path = ProcessInfo.processInfo.environment["REPOMAN_WEBSITE_AUDIT"] else {
            throw XCTSkip("Set REPOMAN_WEBSITE_AUDIT to an inventory JSON for a live production audit.")
        }
        _ = NSApplication.shared
        struct Site: Decodable { let project: String; let domains: [String] }
        let sites = try JSONDecoder().decode([Site].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        var rows: [[String: String]] = []
        for site in sites {
            for domain in site.domains {
                let probe = await WebsiteLiveProbe.load(domain, domains: Set(site.domains))
                let expected = ProcessInfo.processInfo.environment["REPOMAN_EXPECT_SENTRY_SETUP"]?.components(separatedBy: ",") ?? []
                if expected.contains(domain) {
                    XCTAssertTrue(probe.sentry.configured || probe.sentry.accepted, "Live Sentry startup missing: \(domain)")
                    XCTAssertFalse(probe.sentry.disabled, "Live Sentry disabled: \(domain)")
                }
                var row = ["project": site.project, "domain": domain]
                for id in ["website.online", "website.cloudflare", "website.analytics", "website.sentry"] {
                    switch RepositoryWebsiteChecks.classify(probe, checkID: id) {
                    case .pass: row[id] = "pass"
                    case .issue(let reason): row[id] = "issue: " + reason
                    case .deliveryUnverified(let reason): row[id] = "delivery unverified: " + reason
                    case .unknown(let reason): row[id] = "unverified: " + reason
                    }
                }
                rows.append(row)
                print("LIVE WEBSITE \(domain): online=\(row["website.online"]!), cloudflare=\(row["website.cloudflare"]!), analytics=\(row["website.analytics"]!), sentry=\(row["website.sentry"]!)")
            }
        }
        let output = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("live-results.json")
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
        XCTAssertEqual(rows.count, sites.reduce(0) { $0 + $1.domains.count })
    }
}
