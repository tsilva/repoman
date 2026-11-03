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
    private func snapshot(remote: String? = "https://github.com/fixture/site.git") -> RepositorySnapshot {
        RepositorySnapshot(url: root, name: "test", branch: "main", upstream: nil, remoteURL: remote,
            ahead: nil, behind: nil, changes: [], staleBranches: [], worktrees: [], commits: [], rootFiles: [])
    }
    private func write(_ name: String, _ source: String) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(name).deletingLastPathComponent(), withIntermediateDirectories: true)
        try source.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    private var projects: [WebsiteProject] {
        [WebsiteProject(id: "prj_site", repository: "fixture/site", domains: ["site.tsilva.eu"])]
    }
    private var healthy: WebsiteProbe {
        let accepted = WebsiteTelemetryEvidence(configured: true, observed: true, accepted: true)
        return WebsiteProbe(status: 200, isHTML: true, analytics: accepted, sentry: accepted)
    }
    private actor Calls {
        var count = 0
        func record() { count += 1 }
        func value() -> Int { count }
    }

    func testRemoteChecksAreRegisteredAndCannotRunWithoutRemoteOptIn() async throws {
        for id in ["website.domains", "website.sentry", "website.analytics"] {
            XCTAssertTrue(try XCTUnwrap(RepositoryIssueCatalog.standardChecks.first { $0.id == id }).requiresRemoteAccess)
        }
        _ = try GitRunner.run(["init", "-b", "main"], at: root)
        do { _ = try await RepositoryChecker.run(at: root, checkIDs: ["website.sentry"]); XCTFail("Expected remote opt-in") } catch {}
        let report = try await RepositoryChecker.run(at: root)
        XCTAssertTrue(report.checks.filter { $0.id.hasPrefix("website.") }.allSatisfy { $0.status == "skipped" })
    }

    func testInventoryDiscoversMissingMetadataAndBothServicesShareOneProbe() async throws {
        let calls = Calls(), inventories = Calls(), projects = projects, healthy = healthy
        let checks = RepositoryWebsiteChecks.checks(load: { domain, _, _ in
            XCTAssertEqual(domain, "site.tsilva.eu"); await calls.record(); return healthy
        }, inventory: { await inventories.record(); return projects })
        let report = await RepositoryIssueCatalog(checks: checks).inspect(snapshot())
        XCTAssertEqual(report.findings().map(\.checkID), ["website.domains"])
        XCTAssertEqual(report.findings().map(\.subject), ["site.tsilva.eu"])
        XCTAssertTrue(report.unavailableChecks.isEmpty)
        let count = await calls.value(), inventoryCount = await inventories.value()
        XCTAssertEqual(count, 1); XCTAssertEqual(inventoryCount, 1)
    }

    func testEmptySuccessfulInventoryIsNotApplicableAndDoesNotVisitSite() async throws {
        let calls = Calls()
        let checks = RepositoryWebsiteChecks.checks(load: { _, _, _ in await calls.record(); return WebsiteProbe() }, inventory: { [] })
        let report = await RepositoryIssueCatalog(checks: checks).inspect(snapshot())
        XCTAssertTrue(checks.allSatisfy { report.status(for: $0.id) == .notApplicable })
        let count = await calls.value(); XCTAssertEqual(count, 0)
    }

    func testUnavailableInventoryStillProbesDeclaredDomainsWithoutClaimingCompleteCoverage() async throws {
        try write(".repo-metadata.toml", "domains = ['site.tsilva.eu']")
        let calls = Calls(), healthy = healthy
        let checks = RepositoryWebsiteChecks.checks(load: { _, _, _ in await calls.record(); return healthy }, inventory: {
            throw InspectionError.blocked("PRIVATE-PROVIDER-ERROR")
        })
        let report = await RepositoryIssueCatalog(checks: checks).inspect(snapshot())
        XCTAssertEqual(Set(report.unavailableChecks.keys), Set(checks.map(\.id)))
        XCTAssertFalse(report.unavailableChecks.values.joined().contains("PRIVATE"))
        let count = await calls.value(); XCTAssertEqual(count, 1)
        let cli = RepositoryCheckReport(report, head: nil, checkerVersion: "fixture")
        XCTAssertEqual(cli.exitCode, 3)
    }

    func testSilentSDKsRemainIncompleteAndFailuresBeatSuccess() async throws {
        try write(".repo-metadata.toml", "domains = ['site.tsilva.eu']")
        var probe = healthy
        probe.sentry.accepted = false; probe.analytics.accepted = false
        let silent = probe, projects = projects
        let checks = RepositoryWebsiteChecks.checks(load: { _, _, _ in silent }, inventory: { projects })
        let report = await RepositoryIssueCatalog(checks: checks).inspect(snapshot())
        XCTAssertEqual(Set(report.unavailableChecks.keys), ["website.sentry", "website.analytics"])
        XCTAssertEqual(RepositoryCheckReport(report, head: nil, checkerVersion: "fixture").exitCode, 3)
        for id in ["website.sentry", "website.analytics"] {
            if case .deliveryUnverified = RepositoryWebsiteChecks.classify(probe, checkID: id) {} else { XCTFail("SDK setup is not collection proof") }
        }
        probe = healthy; probe.sentry.rejected = true
        if case .issue = RepositoryWebsiteChecks.classify(probe, checkID: "website.sentry") {} else { XCTFail("Rejection beats accepted traffic") }
        probe = healthy; probe.consentGated = true
        if case .unknown = RepositoryWebsiteChecks.classify(probe, checkID: "website.analytics") {} else { XCTFail("Cookieless consent pings must not pass") }
        probe = healthy; probe.sentry.disabled = true
        if case .issue = RepositoryWebsiteChecks.classify(probe, checkID: "website.sentry") {} else { XCTFail("Disabled SDK must fail") }
    }

    func testMixedDomainsRetainRejectedFindingAndIncompleteEvidence() async throws {
        let healthy = healthy
        let projects = [WebsiteProject(id: "prj_site", repository: "fixture/site", domains: ["a.tsilva.eu", "b.tsilva.eu"])]
        let checks = RepositoryWebsiteChecks.checks(load: { domain, _, _ in
            if domain.hasPrefix("a.") {
                var probe = healthy; probe.sentry.rejected = true; return probe
            }
            return WebsiteProbe(transportFailure: "TLS verification failed.")
        }, inventory: { projects })
        let report = await RepositoryIssueCatalog(checks: checks.filter { $0.id == "website.sentry" }).inspect(snapshot())
        XCTAssertEqual(report.findings().map(\.subject), ["a.tsilva.eu"])
        XCTAssertTrue(report.unavailableChecks["website.sentry"]?.contains("b.tsilva.eu") == true)
        XCTAssertEqual(RepositoryCheckReport(report, head: nil, checkerVersion: "fixture").exitCode, 1)
    }

    func testDomainSpecificExceptionSkipsProbeAndAppearsInReport() async throws {
        try write(".repoman.json", #"{"exceptions":{"website.sentry":{"site.tsilva.eu":"Server-only reporting"}}}"#)
        let calls = Calls(), projects = projects
        let checks = RepositoryWebsiteChecks.checks(load: { _, _, _ in await calls.record(); return WebsiteProbe() }, inventory: { projects })
        let report = await RepositoryIssueCatalog(checks: checks.filter { $0.id == "website.sentry" }).inspect(snapshot())
        XCTAssertEqual(report.appliedExceptions["website.sentry"], ["site.tsilva.eu": "Server-only reporting"])
        let count = await calls.value(); XCTAssertEqual(count, 0)
    }

    func testMetadataIsFreshAndRejectsUnsafeAmbiguousOrNestedDomains() async throws {
        try write(".repo-metadata.toml", "short-name='site'\ndomains=[\n 'SITE.tsilva.eu', # production\n]\n[website]\ndomains=['ignored.tsilva.eu']")
        XCTAssertEqual(try WebsiteDomains.load(RepositoryInspectionContext(snapshot: snapshot())), ["site.tsilva.eu"])
        for raw in ["'site.tsilva.eu'", "['eviltsilva.eu']", "['tsilva.eu.evil.test']", "['https://site.tsilva.eu']", "['site.tsilva.eu:443']", "['*.tsilva.eu']", "['127.0.0.1']", "['a..tsilva.eu']", "['a.tsilva.eu','A.tsilva.eu']", "[true]", "['a.tsilva.eu',,]"] {
            XCTAssertThrowsError(try WebsiteDomains.parse(raw), raw)
        }
        try write(".repo-metadata.toml", "domains=['a.tsilva.eu']\ndomains=['b.tsilva.eu']")
        XCTAssertThrowsError(try WebsiteDomains.load(RepositoryInspectionContext(snapshot: snapshot())))
        let hosts: Set<String> = ["site.tsilva.eu"]
        XCTAssertTrue(WebsiteDomains.permits(URL(string: "https://site.tsilva.eu/"), domains: hosts))
        for url in ["http://site.tsilva.eu/", "https://other.tsilva.eu/", "https://site.tsilva.eu:8443/", "https://user:secret@site.tsilva.eu/"] {
            XCTAssertFalse(WebsiteDomains.permits(URL(string: url), domains: hosts))
        }
    }

    func testYAMLInventoryTakesPrecedenceAndRejectsMismatchedURL() throws {
        try write(".repo-metadata.toml", "domains = ['legacy.tsilva.eu']")
        try write(".repoman.yaml", "version: 1\ntagline: 'Ship safely'\ngithub-url: https://example.com/\n")
        XCTAssertEqual(try WebsiteDomains.load(RepositoryInspectionContext(snapshot: snapshot())), ["legacy.tsilva.eu"])
        let manifest = """
        version: 1
        tagline: "Ship safely"
        websites:
          site.tsilva.eu:
            url: https://site.tsilva.eu/
            ga4: observed
            sentry: unverified
            checked-on: 2026-11-03
          www.site.tsilva.eu:
            url: https://www.site.tsilva.eu/
            redirect-to: https://site.tsilva.eu/
        """
        try write(".repoman.yaml", manifest)
        XCTAssertEqual(try WebsiteDomains.load(RepositoryInspectionContext(snapshot: snapshot())),
                       ["site.tsilva.eu", "www.site.tsilva.eu"])
        try write(".repoman.yaml", manifest.replacingOccurrences(of: "url: https://site", with: "url: https://other"))
        XCTAssertThrowsError(try WebsiteDomains.load(RepositoryInspectionContext(snapshot: snapshot())))
    }

    func testTelemetryPolicyUsesServicePathAndReportsExceptions() async throws {
        let manifest = """
        version: 1
        websites:
          site.tsilva.eu:
            url: https://site.tsilva.eu/
            ga4-expectation: required
            ga4-verification-path: /chat
            sentry-expectation: optional
            sentry-exception-reason: Server telemetry reviewed separately.
          alias.tsilva.eu:
            url: https://alias.tsilva.eu/
            redirect-to: https://site.tsilva.eu/
            ga4-expectation: disabled
            ga4-exception-reason: Redirect alias.
            sentry-expectation: disabled
            sentry-exception-reason: Redirect alias.
        """
        try write(".repoman.yaml", manifest)
        let calls = Calls(), healthy = healthy, projects = projects
        let checks = RepositoryWebsiteChecks.checks(load: { domain, path, _ in
            XCTAssertEqual(domain, "site.tsilva.eu")
            XCTAssertEqual(path, "/chat")
            await calls.record()
            return healthy
        }, inventory: { projects })
        let report = await RepositoryIssueCatalog(checks: checks).inspect(snapshot())
        XCTAssertTrue(report.findings().isEmpty)
        XCTAssertTrue(report.unavailableChecks.isEmpty)
        XCTAssertEqual(report.appliedExceptions["website.analytics"], ["alias.tsilva.eu": "Disabled: Redirect alias."])
        XCTAssertEqual(report.appliedExceptions["website.sentry"], [
            "alias.tsilva.eu": "Disabled: Redirect alias.",
            "site.tsilva.eu": "Optional: Server telemetry reviewed separately."
        ])
        let count = await calls.value()
        XCTAssertEqual(count, 1)

        for path in ["https://outside.example/", "//outside.example/", "/a/../b", "/a%2fb", "/a?secret=1", "/a#fragment"] {
            try write(".repoman.yaml", manifest.replacingOccurrences(of: "/chat", with: path))
            XCTAssertThrowsError(try WebsiteDomains.load(RepositoryInspectionContext(snapshot: snapshot())), path)
        }
        try write(".repoman.yaml", manifest.replacingOccurrences(of: "    sentry-exception-reason: Server telemetry reviewed separately.\n", with: ""))
        XCTAssertThrowsError(try WebsiteDomains.load(RepositoryInspectionContext(snapshot: snapshot())))
    }

    func testStaleLocalVercelLinkCannotOverrideGitRepositoryBinding() async throws {
        try write(".vercel/project.json", #"{"projectId":"prj_other"}"#)
        let projects = [WebsiteProject(id: "prj_other", repository: "fixture/other", domains: ["other.tsilva.eu"]),
                        WebsiteProject(id: "prj_site", repository: "fixture/site", domains: ["site.tsilva.eu"])]
        let resolution = try await WebsiteDomainResolution.load(RepositoryInspectionContext(snapshot: snapshot()), declared: [], loader: { projects })
        XCTAssertEqual(resolution.domains, ["site.tsilva.eu"])
    }

    @MainActor
    func testDelayedSDKGetsFullObservationWindow() async throws {
        var elapsed: UInt64 = 0
        let evidence = try await WebsiteBrowserProbe.collectEvidence(sample: {
            WebsiteBrowserProbe.Evidence(sentry: WebsiteTelemetryEvidence(configured: elapsed >= 9_000_000_000))
        }, sleep: { elapsed += $0 })
        XCTAssertTrue(evidence.sentry.configured)
        XCTAssertEqual(elapsed, 20_000_000_000)
    }

    @MainActor
    func testObserverDoesNotSendEventsAndQueuedBeaconsNeverProveAcceptance() throws {
        let js = try XCTUnwrap(JSContext())
        js.evaluateScript(#"""
        var window=this, location={href:'https://site.tsilva.eu/'};
        var calls=0, navigator={sendBeacon:function(){calls++;return true;}};
        var fetch=function(){calls++;return Promise.resolve({status:204});};
        function XMLHttpRequest(){};
        XMLHttpRequest.prototype.open=function(){};
        XMLHttpRequest.prototype.send=function(){};
        XMLHttpRequest.prototype.addEventListener=function(){};
        function URL(input){this.hostname=input.split('/')[2];this.pathname='/' + input.split('/').slice(3).join('/').split('?')[0];}
        """#)
        js.evaluateScript(WebsiteBrowserProbe.observer)
        XCTAssertNil(js.exception)
        XCTAssertEqual(js.evaluateScript("calls").toInt32(), 0)
        js.evaluateScript(#"navigator.sendBeacon('https://www.google-analytics.com/g/collect?tid=PRIVATE-ID','PRIVATE-PAYLOAD');"#)
        XCTAssertTrue(js.evaluateScript("__repomanWebsiteEvidence.analytics.observed").toBool())
        XCTAssertFalse(js.evaluateScript("__repomanWebsiteEvidence.analytics.accepted").toBool())
        js.evaluateScript(#"fetch('https://ingest.sentry.io/api/123/envelope/', {body:'{}\n{"type":"session"}\n{"secret":"PRIVATE-DSN"}'});"#)
        XCTAssertTrue(js.evaluateScript("__repomanWebsiteEvidence.sentry.observed").toBool())
        let output = js.evaluateScript("JSON.stringify(__repomanWebsiteEvidence)").toString() ?? "PRIVATE"
        XCTAssertFalse(output.contains("PRIVATE"))
        XCTAssertFalse(output.contains("PAYLOAD"))
        js.evaluateScript("__repomanWebsiteEvidence.sentry.observed=false;")
        js.evaluateScript(#"fetch('https://evil.test/api/123/envelope/',{body:'{"dsn":"PRIVATE-DSN"}\n{"type":"event"}\n{}'});"#)
        XCTAssertFalse(js.evaluateScript("__repomanWebsiteEvidence.sentry.observed").toBool(), "Arbitrary tunnel success is not upstream Sentry acceptance")
        XCTAssertNil(js.exception)
    }
    @MainActor
    func testSamplerFindsBundledClientObservesTransportAndPreservesDeniedConsent() throws {
        let js = try XCTUnwrap(JSContext())
        js.evaluateScript(#"""
        var window=this;
        var document={scripts:[],querySelectorAll:function(){return [];}};
        var empty=function(){return {configured:false,observed:false,accepted:false,rejected:false,disabled:false};};
        window.__repomanWebsiteEvidence={analytics:empty(),sentry:empty()};
        window.dataLayer=[['consent','default',{analytics_storage:'denied'}]];
        var listener, captures=0;
        var client={getOptions:function(){return {dsn:'https://PRIVATE-KEY@o1.ingest.sentry.io/123',enabled:true};},
          on:function(name, callback){if(name==='afterSendEvent')listener=callback;},
          captureEvent:function(){captures++;}};
        window.__SENTRY__={'10.45.0':{defaultCurrentScope:{getClient:function(){return null;}},
          defaultIsolationScope:{getClient:function(){return client;}}}};
        function URL(input){this.hostname=input.split('/')[2].split('@').pop();}
        """#)
        let initial = try XCTUnwrap(js.evaluateScript(WebsiteBrowserProbe.sample).toString())
        XCTAssertNil(js.exception)
        let evidence = try JSONDecoder().decode(WebsiteBrowserProbe.Evidence.self, from: Data(initial.utf8))
        XCTAssertTrue(evidence.sentry.configured)
        XCTAssertFalse(evidence.sentry.accepted)
        XCTAssertTrue(evidence.consentGated)
        XCTAssertEqual(js.evaluateScript("captures").toInt32(), 0)
        js.evaluateScript("listener({event_id:'PRIVATE-ID'}, {statusCode:200});")
        XCTAssertTrue(js.evaluateScript("__repomanWebsiteEvidence.sentry.accepted").toBool())
        js.evaluateScript("listener({event_id:'PRIVATE-ID'}, {statusCode:429});")
        XCTAssertTrue(js.evaluateScript("__repomanWebsiteEvidence.sentry.rejected").toBool())
        let result = try XCTUnwrap(js.evaluateScript(WebsiteBrowserProbe.sample).toString())
        XCTAssertFalse(result.contains("PRIVATE"))
        XCTAssertEqual(js.evaluateScript("captures").toInt32(), 0)
    }

}
