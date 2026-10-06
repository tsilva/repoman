import AppKit
import Foundation
import JavaScriptCore
import XCTest
@testable import RepoManCore

final class WebsiteDeliveryTestTests: XCTestCase {
    @MainActor
    private func runtime() throws -> JSContext {
        let js = try XCTUnwrap(JSContext())
        js.evaluateScript(#"""
        var window = this, location = {href:'https://test.tsilva.eu/'};
        var document = {scripts:[], querySelectorAll:function(){return [];}};
        var navigator = {sendBeacon:function(){return true;}};
        var status = 204, calls = 0;
        var fetch = function(){calls++; return {then:function(done){done({status:status});}};};
        function XMLHttpRequest() {}
        XMLHttpRequest.prototype.open = function(){};
        XMLHttpRequest.prototype.send = function(){};
        XMLHttpRequest.prototype.addEventListener = function(){};
        function URLSearchParams(query) {
          this.get = function(key) {
            var parts = query.replace(/^\?/, '').split('&');
            for (var part of parts) {var pair = part.split('='); if (pair[0] === key) return pair[1];}
            return null;
          };
        }
        function URL(input) {
          this.hostname = input.split('/')[2];
          this.pathname = '/' + input.split('/').slice(3).join('/').split('?')[0];
          this.searchParams = new URLSearchParams(input.split('?')[1] || '');
        }
        var crypto = {getRandomValues:function(bytes){for(var i=0;i<bytes.length;i++) bytes[i]=i;}};
        var options = {dsn:'PRIVATE-DSN', enabled:true};
        var client = {getOptions:function(){return options;},captureEvent:function(event){
          fetch('https://ingest.sentry.io/api/1/envelope/', {body:'{}\n{"type":"event"}\n'+JSON.stringify(event)});
        },flush:function(){return false;}};
        window.__SENTRY__ = {'10.45.0':{defaultCurrentScope:{getClient:function(){return client;}}}};
        window.gtag = function(command, name, params) {
          navigator.sendBeacon('https://www.google-analytics.com/g/collect?en='+name+'&ep.repoman_verification='+params.repoman_verification);
        };
        """#)
        js.evaluateScript(WebsiteBrowserProbe.observer)
        XCTAssertNil(js.exception)
        return js
    }

    @MainActor
    private func sample(_ js: JSContext) throws -> WebsiteBrowserProbe.Evidence {
        let json = try XCTUnwrap(js.evaluateScript(WebsiteBrowserProbe.sample)?.toString())
        XCTAssertNil(js.exception)
        XCTAssertFalse(json.contains("PRIVATE-DSN"))
        return try JSONDecoder().decode(WebsiteBrowserProbe.Evidence.self, from: Data(json.utf8))
    }

    @MainActor
    func testSentrySDKEventIsCorrelatedAndOnlySentOnce() throws {
        let js = try runtime()
        _ = try sample(js)
        let script = WebsiteBrowserProbe.sendTest.replacingOccurrences(of: "__SERVICE__", with: "sentry")
        XCTAssertTrue(js.evaluateScript(script).toBool())
        let evidence = try sample(js)
        XCTAssertTrue(evidence.testAttempted)
        XCTAssertTrue(evidence.test.accepted)
        XCTAssertFalse(js.evaluateScript(script).toBool())
        XCTAssertEqual(js.evaluateScript("calls").toInt32(), 1)
        XCTAssertTrue(WebsiteDeliveryTest.summary(evidence, domain: "test.tsilva.eu").contains("Dashboard receipt was not checked"))
    }

    @MainActor
    func testSentryNativeTransportBypassingWindowFetchStillConfirmsCorrelatedResponse() throws {
        let js = try runtime()
        js.evaluateScript(#"""
        var hooks = {};
        client.on = function(name, callback) {hooks[name] = callback; return function(){delete hooks[name];};};
        client.captureEvent = function(event) {
          // The real SDK uses nativeFetch, bypassing RepoMan's window.fetch wrapper.
          if (hooks.beforeSendEvent) hooks.beforeSendEvent(event);
          if (hooks.afterSendEvent) hooks.afterSendEvent(event, {statusCode:200});
        };
        """#)
        _ = try sample(js)
        _ = js.evaluateScript(WebsiteBrowserProbe.sendTest.replacingOccurrences(of: "__SERVICE__", with: "sentry"))
        XCTAssertTrue(try sample(js).test.accepted, "An accepted SDK transport response must not leave delivery unverified")
        XCTAssertEqual(js.evaluateScript("calls").toInt32(), 0)
    }

    @MainActor
    func testUnrelatedAcceptedSentrySessionCannotVerifyTestAndRejectionIsReported() throws {
        let js = try runtime()
        _ = try sample(js)
        js.evaluateScript(#"client.captureEvent = function(){};"#)
        _ = js.evaluateScript(WebsiteBrowserProbe.sendTest.replacingOccurrences(of: "__SERVICE__", with: "sentry"))
        js.evaluateScript(#"fetch('https://ingest.sentry.io/api/1/envelope/', {body:'{}\n{"type":"session"}\n{}'});"#)
        XCTAssertTrue(try sample(js).sentry.accepted)
        XCTAssertFalse(try sample(js).test.accepted)
        js.evaluateScript(#"status=429; fetch('https://ingest.sentry.io/api/1/envelope/', {body:'{}\n{"type":"event"}\n'+JSON.stringify({event_id:__repomanWebsiteEvidence.testToken})});"#)
        XCTAssertTrue(try sample(js).test.rejected)
    }

    @MainActor
    func testGAQueuedBeaconNeedsCorrelatedResponseAndDoesNotChangeConsent() throws {
        let js = try runtime()
        _ = try sample(js)
        let script = WebsiteBrowserProbe.sendTest.replacingOccurrences(of: "__SERVICE__", with: "analytics")
        XCTAssertTrue(js.evaluateScript(script).toBool())
        var evidence = try sample(js)
        XCTAssertTrue(evidence.test.observed)
        XCTAssertFalse(evidence.test.accepted)
        js.evaluateScript(#"fetch('https://www.google-analytics.com/g/collect?en=page_view');"#)
        XCTAssertFalse(try sample(js).test.accepted)
        js.evaluateScript(#"fetch('https://www.google-analytics.com/g/collect?en=repoman_delivery_check&ep.repoman_verification='+__repomanWebsiteEvidence.testToken);"#)
        evidence = try sample(js)
        XCTAssertTrue(evidence.test.accepted)
        XCTAssertFalse(js.evaluateScript(script).toBool())
        let denied = try runtime()
        denied.evaluateScript(#"dataLayer=[['consent','default',{analytics_storage:'denied'}]];"#)
        _ = try sample(denied)
        XCTAssertFalse(denied.evaluateScript(script).toBool())
        XCTAssertFalse(try sample(denied).testAttempted)
        XCTAssertEqual(denied.evaluateScript("dataLayer[0][2].analytics_storage").toString(), "denied")
    }

    @MainActor
    func testDisabledSDKCannotSendAndSummaryDoesNotConfuseFlushWithDelivery() throws {
        let js = try runtime()
        js.evaluateScript("options.enabled=false")
        _ = try sample(js)
        XCTAssertFalse(js.evaluateScript(WebsiteBrowserProbe.sendTest.replacingOccurrences(of: "__SERVICE__", with: "sentry")).toBool())
        XCTAssertEqual(js.evaluateScript("calls").toInt32(), 0)
        let queued = WebsiteBrowserProbe.Evidence(testAttempted: true)
        XCTAssertTrue(WebsiteDeliveryTest.summary(queued, domain: "test.tsilva.eu").contains("unverified"))
    }

    @MainActor
    func testSentryLifecycleIgnoresUnrelatedEventsAndFlushIsNotAcceptance() throws {
        let js = try runtime()
        js.evaluateScript(#"""
        var hooks = {};
        client.on = function(name, callback) {hooks[name] = callback; return function(){delete hooks[name];};};
        client.captureEvent = function(event) {
          hooks.afterSendEvent({event_id:'unrelated'}, {statusCode:200});
          if (hooks.beforeSendEvent) hooks.beforeSendEvent(event);
          hooks.afterSendEvent(event, {statusCode:429});
        };
        client.flush = function(){return true;};
        """#)
        _ = try sample(js)
        _ = js.evaluateScript(WebsiteBrowserProbe.sendTest.replacingOccurrences(of: "__SERVICE__", with: "sentry"))
        let evidence = try sample(js)
        XCTAssertTrue(evidence.test.observed)
        XCTAssertTrue(evidence.test.rejected)
        XCTAssertFalse(evidence.test.accepted)
    }

    func testReceiptsCannotOverrideStaleMetadataCachedEvidenceOrLiveFailures() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try GitRunner.run(["init", "-b", "main"], at: root)
        try "domains = ['test.tsilva.eu']".write(to: root.appendingPathComponent(".repo-metadata.toml"), atomically: true, encoding: .utf8)
        let snapshot = try GitRepositoryScanner.scan(root)
        let catalog = RepositoryIssueCatalog(checks: RepositoryWebsiteChecks.checks(load: { _, _ in
            WebsiteProbe(status: 200, cloudflare: true, isHTML: true, sentry: WebsiteTelemetryEvidence(configured: true))
        }))
        let report = await catalog.inspect(snapshot)
        let finding = try XCTUnwrap(report.findings().first { $0.checkID == "website.sentry" })
        let now = Date()
        let receipt = WebsiteDeliveryReceipt(repositoryID: snapshot.id, checkID: finding.checkID,
            domain: finding.subject, declaredDomains: [finding.subject], acceptedAt: now)
        XCTAssertNotNil(receipt.verification(for: finding, in: report, domains: [finding.subject], now: now))
        XCTAssertNil(receipt.verification(for: finding, in: report, domains: [], now: now))
        XCTAssertNil(receipt.verification(for: finding, in: report, domains: [finding.subject], now: now.addingTimeInterval(300)))
        XCTAssertNil(receipt.verification(for: finding, in: report, domains: [finding.subject], now: now.addingTimeInterval(-1)))
        let cached = RepositoryInspectionReport(snapshot: snapshot, results: report.results,
            checkOrder: report.checkOrder, cachedChecks: [finding.checkID], completedAt: report.completedAt)
        XCTAssertNil(receipt.verification(for: finding, in: cached, domains: [finding.subject], now: now))
        let failureCatalog = RepositoryIssueCatalog(checks: RepositoryWebsiteChecks.checks(load: { _, _ in
            WebsiteProbe(status: 200, cloudflare: true, isHTML: true, sentry: WebsiteTelemetryEvidence(configured: true, rejected: true))
        }))
        let failure = await failureCatalog.inspect(snapshot)
        XCTAssertNil(receipt.verification(for: finding, in: failure, domains: [finding.subject], now: now))
    }

    @MainActor
    func testLiveSentryDelivery() async throws {
        guard let domain = ProcessInfo.processInfo.environment["REPOMAN_LIVE_SENTRY_TEST"], WebsiteDomains.valid(domain) else {
            throw XCTSkip("Set REPOMAN_LIVE_SENTRY_TEST to an explicitly authorized domain for one synthetic event.")
        }
        _ = NSApplication.shared
        let evidence = await WebsiteBrowserProbe.visit(try XCTUnwrap(URL(string: "https://" + domain + "/")), domains: [domain], testService: "sentry")
        print(WebsiteDeliveryTest.summary(evidence, domain: domain))
        XCTAssertNil(evidence.failure)
        XCTAssertTrue(evidence.testAttempted)
        XCTAssertTrue(evidence.test.accepted, "The real site's SDK response must confirm ingestion")
        XCTAssertFalse(evidence.test.rejected)
    }

    func testRetryRecoversLostPresetOnlyFromExplicitOriginalAuthorization() throws {
        let snapshot = RepositorySnapshot(url: URL(fileURLWithPath: "/fixture"), name: "fixture", branch: "main",
            upstream: nil, remoteURL: nil, ahead: nil, behind: nil, changes: [], staleBranches: [], worktrees: [], commits: [])
        for id in ["website.sentry", "website.analytics"] {
            let recipe = try XCTUnwrap(RepositoryWebsiteChecks.recipes.first { $0.id == id })
            let finding = RepositoryFinding(repositoryID: snapshot.id, checkID: id, subject: "test.tsilva.eu",
                title: "Delivery", evidence: "", category: .setup, symbol: "network")
            var task = RepairTask(finding: finding, repository: snapshot, prompt: recipe.prompt)
            task.pendingPrompt = "try again"; task.threadID = "existing-thread"
            task = try JSONDecoder().decode(RepairTask.self, from: JSONEncoder().encode(task))
            XCTAssertEqual(WebsiteDeliveryTest.service(for: task), id == "website.sentry" ? "sentry" : "analytics")
            let unauthorized = RepairTask(finding: finding, repository: snapshot,
                prompt: "Run the available browser delivery test, but ask before sending events")
            XCTAssertNil(WebsiteDeliveryTest.service(for: unauthorized))
            task.recipeID = id == "website.sentry" ? "website.analytics" : "website.sentry"
            XCTAssertNil(WebsiteDeliveryTest.service(for: task))
        }
    }

    func testToolScopeRequiresNewPresetReportedDomainAndCurrentRootMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try GitRunner.run(["init", "-b", "main"], at: root)
        let snapshot = try GitRepositoryScanner.scan(root)
        let finding = RepositoryFinding(repositoryID: snapshot.id, checkID: "website.sentry", subject: "test.tsilva.eu",
            title: "Sentry", evidence: "", category: .setup, symbol: "network")
        let recipe = try XCTUnwrap(RepositoryWebsiteChecks.recipes.first { $0.id == "website.sentry" })
        let task = RepairTask(finding: finding, repository: snapshot, prompt: recipe.prompt, recipeID: recipe.id)
        let legacy = RepairTask(finding: finding, repository: snapshot, prompt: "Ask before sending synthetic events", recipeID: recipe.id)
        XCTAssertNil(WebsiteDeliveryTest.service(for: legacy))
        XCTAssertThrowsError(try WebsiteDeliveryTest.domains(for: task, domain: "test.tsilva.eu"))
        try "domains = ['test.tsilva.eu', 'other.tsilva.eu']".write(to: root.appendingPathComponent(".repo-metadata.toml"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try WebsiteDeliveryTest.domains(for: task, domain: "test.tsilva.eu"), ["test.tsilva.eu", "other.tsilva.eu"])
        XCTAssertThrowsError(try WebsiteDeliveryTest.domains(for: task, domain: "other.tsilva.eu"))
        XCTAssertThrowsError(try WebsiteDeliveryTest.domains(for: task, domain: "https://test.tsilva.eu/"))
        try "domains = []".write(to: root.appendingPathComponent(".repo-metadata.toml"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try WebsiteDeliveryTest.domains(for: task, domain: "test.tsilva.eu"))
    }
}
