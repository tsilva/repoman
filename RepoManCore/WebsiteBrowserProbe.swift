import Foundation
import WebKit

/// No saved logins, cookies, consent overrides, or service credentials.
/// Synthetic events require an explicitly selected delivery-test preset.
/// Hooks only observe requests the page itself sends; no payloads or identifiers leave the web view.
@MainActor
final class WebsiteBrowserProbe: NSObject, WKNavigationDelegate {
    struct Evidence: Sendable, Decodable {
        var failure: String?
        var consentGated = false
        var analytics = WebsiteTelemetryEvidence()
        var sentry = WebsiteTelemetryEvidence()
        var test = WebsiteTelemetryEvidence()
        var testAttempted = false
    }
    private let domains: Set<String>
    private let testService: String?
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Evidence, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var sampleTask: Task<Void, Never>?
    private var latestEvidence: Evidence?
    private var redirects = 0
    private var didAttemptTest = false

    private init(domains: Set<String>, testService: String?) { self.domains = domains; self.testService = testService }

    static func visit(_ url: URL, domains: Set<String>, testService: String? = nil) async -> Evidence {
        guard WebsiteDomains.permits(url, domains: domains), testService == nil || ["analytics", "sentry"].contains(testService!) else {
            return Evidence(failure: "Invalid website verification scope.")
        }
        let probe = WebsiteBrowserProbe(domains: domains, testService: testService)
        return await probe.run(url)
    }

    private func run(_ url: URL) async -> Evidence {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
            configuration.userContentController.addUserScript(WKUserScript(source: Self.observer,
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 800), configuration: configuration)
            view.navigationDelegate = self
            webView = view
            timeoutTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 35_000_000_000) } catch { return }
                guard let self else { return }
                self.finish(self.latestEvidence ?? Evidence(failure: "Browser telemetry inspection timed out; delivery remains unverified."))
            }
            view.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15))
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.targetFrame?.isMainFrame != false {
            guard WebsiteDomains.permits(navigationAction.request.url, domains: domains) else {
                decisionHandler(.cancel)
                finish(Evidence(failure: "The browser left the declared HTTPS domains; telemetry remains unverified."))
                return
            }
            redirects += 1
            guard redirects <= 6 else {
                decisionHandler(.cancel)
                finish(Evidence(failure: "Too many browser navigations; telemetry remains unverified."))
                return
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame, let response = navigationResponse.response as? HTTPURLResponse,
           !(200..<300).contains(response.statusCode) {
            decisionHandler(.cancel)
            finish(Evidence(failure: "Browser received HTTP \(response.statusCode); authentication or bot protection may prevent telemetry verification."))
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        sampleTask?.cancel()
        sampleTask = Task { [weak self] in
            guard let self, let view = self.webView else { return }
            do {
                let evidence = try await Self.collectEvidence(sample: {
                    guard let json = try await view.evaluateJavaScript(Self.sample) as? String,
                          let data = json.data(using: .utf8) else { throw RepairError.blocked("No browser evidence.") }
                    let evidence = try JSONDecoder().decode(Evidence.self, from: data)
                    self.latestEvidence = evidence
                    return evidence
                })
                guard let service = self.testService, !evidence.consentGated, !self.didAttemptTest else { self.finish(evidence); return }
                self.didAttemptTest = true
                // Initialization has had its full observation window. Only use the site's loaded SDK.
                let script = Self.sendTest.replacingOccurrences(of: "__SERVICE__", with: service)
                _ = try await view.evaluateJavaScript(script)
                var result = evidence
                for _ in 0..<10 {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    guard let json = try await view.evaluateJavaScript(Self.sample) as? String else { break }
                    result = try JSONDecoder().decode(Evidence.self, from: Data(json.utf8))
                    self.latestEvidence = result
                    if result.test.accepted || result.test.rejected || !result.testAttempted { break }
                }
                self.finish(result)
            } catch is CancellationError {
                return
            } catch {
                self.finish(Evidence(failure: "Live browser telemetry evidence was unavailable; delivery remains unverified."))
            }
        }
    }

    static func collectEvidence(sample: () async throws -> Evidence,
                                sleep: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) async throws -> Evidence {
        // An idle boot timer may itself take eight seconds, followed by a dynamic import.
        // Keep observing ordinary delivery after initialization; never manufacture an event.
        var latest = Evidence()
        for _ in 0..<20 {
            try Task.checkCancellation()
            try await sleep(1_000_000_000)
            latest = try await sample()
            if latest.analytics.accepted && latest.sentry.accepted { break }
        }
        return latest
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(Evidence(failure: "Browser navigation failed; telemetry remains unverified."))
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(Evidence(failure: "Browser navigation or TLS verification failed; telemetry remains unverified."))
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(Evidence(failure: "Browser process stopped; telemetry remains unverified."))
    }
    private func finish(_ evidence: Evidence) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel(); sampleTask?.cancel()
        webView?.navigationDelegate = nil; webView?.stopLoading(); webView = nil
        continuation.resume(returning: evidence)
    }

    static let observer = #"""
    (() => {
      const empty = () => ({configured:false, observed:false, accepted:false, rejected:false, disabled:false});
      const state = {analytics:empty(), sentry:empty(), test:empty(), testAttempted:false};
      const kind = (input, body) => {
        try {
          const u = new URL(typeof input === 'string' ? input : input.url, location.href);
          const host = u.hostname.toLowerCase();
          if ((host === 'google-analytics.com' || host.endsWith('.google-analytics.com') ||
               host === 'analytics.google.com' || host.endsWith('.analytics.google.com')) &&
              u.pathname === '/g/collect') return 'analytics';
          // Only normal SDK events/sessions/transactions qualify, not client reports or replays.
          if (typeof body === 'string' && body.length <= 1048576) {
            const lines = body.split('\n', 3);
            if (lines.length >= 3) {
              const envelope = JSON.parse(lines[0]), item = JSON.parse(lines[1]);
              if ((host === 'sentry.io' || host.endsWith('.sentry.io') || envelope.dsn) &&
                  ['event','transaction','session','sessions'].includes(item.type)) return 'sentry';
            }
          }
        } catch (_) {}
        return null;
      };
      const isTest = (input, body, service) => {
        if (!service || !state.testToken) return false;
        try {
          if (service === 'analytics') {
            const u = new URL(typeof input === 'string' ? input : input.url, location.href);
            const matches = params => params.get('en') === 'repoman_delivery_check' &&
              params.get('ep.repoman_verification') === state.testToken;
            return matches(u.searchParams) || (typeof body === 'string' && body.length <= 1048576 &&
              body.split('\n').some(line => matches(new URLSearchParams(line))));
          }
          if (typeof body === 'string' && body.length <= 1048576) {
            const lines = body.split('\n');
            for (let i = 1; i + 1 < lines.length; i += 2) {
              const item = JSON.parse(lines[i]), event = JSON.parse(lines[i + 1]);
              if (item.type === 'event' && event.event_id === state.testToken) return true;
            }
          }
        } catch (_) {}
        return false;
      };
      const record = (service, status, test = false) => {
        if (!service) return;
        const e = state[service]; e.observed = true;
        if (test) {state.test.observed = true; if (status >= 200 && status < 300) state.test.accepted = true; else if (status >= 400) state.test.rejected = true;}
        if (status >= 200 && status < 300) e.accepted = true;
        else if (status >= 400) e.rejected = true;
      };
      const fetchOriginal = window.fetch;
      window.fetch = function(input, init) {
        const service = kind(input, init && init.body), test = isTest(input, init && init.body, service);
        if (service) record(service, 0, test);
        const request = fetchOriginal.apply(this, arguments);
        if (service) request.then(r => record(service, r.status, test), () => {state[service].rejected = true; if (test) state.test.rejected = true;});
        return request;
      };
      const openOriginal = XMLHttpRequest.prototype.open, sendOriginal = XMLHttpRequest.prototype.send;
      const urls = new WeakMap();
      XMLHttpRequest.prototype.open = function(method, url) {
        urls.set(this, url); return openOriginal.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function(body) {
        const service = kind(urls.get(this), body), test = isTest(urls.get(this), body, service);
        if (service) {
          record(service, 0, test);
          this.addEventListener('loadend', () => {
            record(service, this.status, test);
            if (this.status === 0) {state[service].rejected = true; if (test) state.test.rejected = true;}
          }, {once:true});
        }
        return sendOriginal.apply(this, arguments);
      };
      const beaconOriginal = navigator.sendBeacon;
      if (beaconOriginal) navigator.sendBeacon = function(url, data) {
        const service = kind(url, data), test = isTest(url, data, service);
        const queued = beaconOriginal.apply(this, arguments);
        if (service) {record(service, 0, test); if (!queued) {state[service].rejected = true; if (test) state.test.rejected = true;}}
        return queued;
      };
      // Resource timing can confirm GA beacons when the browser exposes responseStatus.
      const resources = entries => {
        for (const entry of entries) {
          const service = kind(entry.name, null);
          if (service) record(service, entry.responseStatus || 0, isTest(entry.name, null, service));
        }
      };
      try {new PerformanceObserver(list => resources(list.getEntries())).observe({type:'resource', buffered:true});} catch (_) {}
      Object.defineProperty(window, '__repomanWebsiteEvidence', {value:state});
    })()
    """#


    static let sendTest = #"""
    (() => {
      const state = window.__repomanWebsiteEvidence;
      if (!state || state.testAttempted) return false;
      const service = '__SERVICE__';
      if (!state[service].configured || state[service].disabled) return false;
      const bytes = new Uint8Array(16); crypto.getRandomValues(bytes);
      const token = Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');
      if (service === 'analytics') {
        if (typeof window.gtag !== 'function') return false;
        // Preserve any denied Consent Mode state, even when the banner is no longer visible.
        let denied = false;
        for (const entry of (Array.isArray(window.dataLayer) ? window.dataLayer : [])) {
          if (entry && entry[0] === 'consent' && entry[2] && entry[2].analytics_storage) {
            denied = entry[2].analytics_storage !== 'granted';
          }
        }
        if (denied) return false;
        state.testToken = token; state.testAttempted = true;
        window.gtag('event', 'repoman_delivery_check', {debug_mode:true, repoman_verification:token});
        return true;
      }
      try {
        const carrier = window.__SENTRY__ || {};
        const scopes = [carrier, ...Object.values(carrier)].filter(x => x && typeof x === 'object');
        let client = window.Sentry && typeof window.Sentry.getClient === 'function' ? window.Sentry.getClient() : null;
        let activeScope;
        for (const scope of scopes) {
          const candidates = [scope.defaultCurrentScope, scope.defaultIsolationScope];
          if (scope.stack && typeof scope.stack.getScope === 'function') candidates.push(scope.stack.getScope());
          if (scope.hub && typeof scope.hub.getClient === 'function') candidates.push(scope.hub);
          for (const current of candidates) {
            if (!client && current && typeof current.getClient === 'function') {
              client = current.getClient(); if (client) activeScope = current;
            }
          }
        }
        if (!client || typeof client.captureEvent !== 'function') return false;
        state.testToken = token; state.testAttempted = true;
        // Sentry obtains native fetch from a clean realm, bypassing window.fetch hooks.
        // Its lifecycle callback reports the actual transport response, including tunnels.
        if (typeof client.on === 'function') {
          const cleanup = [];
          const record = (event, response) => {
            if (!event || event.event_id !== token || !response || typeof response.statusCode !== 'number') return;
            state.test.observed = true; state.sentry.observed = true;
            const status = response && response.statusCode;
            if (status >= 200 && status < 300) {state.test.accepted = true; state.sentry.accepted = true;}
            else if (status >= 400) {state.test.rejected = true; state.sentry.rejected = true;}
            if (response) for (const remove of cleanup) if (typeof remove === 'function') remove();
          };
          cleanup.push(client.on('afterSendEvent', (event, response) => record(event, response)));
        }
        client.captureEvent({event_id:token, message:'RepoMan delivery verification', level:'info',
          tags:{repoman_verification:'true'}}, {}, activeScope);
        if (typeof client.flush === 'function') client.flush(5000);
        return true;
      } catch (_) { return false; }
    })()
    """#

    static let sample = #"""
    (() => {
      const state = window.__repomanWebsiteEvidence;
      if (!state) return null;
      const scripts = Array.from(document.scripts);
      state.analytics.configured = scripts.some(s => /googletagmanager\.com\/(gtag\/js|gtm\.js)/.test(s.src)) ||
        typeof window.gtag === 'function' || Boolean(window.google_tag_manager);
      const layers = Array.isArray(window.dataLayer) ? window.dataLayer : [];
      for (const entry of layers) {
        if (entry && entry[0] === 'config' && typeof entry[1] === 'string' && /^G-/.test(entry[1])) {
          if (window['ga-disable-' + entry[1]] === true) state.analytics.disabled = true;
        }
      }
      // Bundled Sentry SDKs expose versioned global scopes, even without window.Sentry.
      try {
        const carrier = window.__SENTRY__ || {};
        const scopes = [carrier, ...Object.values(carrier)].filter(x => x && typeof x === 'object');
        let client = window.Sentry && typeof window.Sentry.getClient === 'function' ? window.Sentry.getClient() : null;
        for (const scope of scopes) {
          const candidates = [scope.defaultCurrentScope, scope.defaultIsolationScope];
          if (scope.stack && typeof scope.stack.getScope === 'function') candidates.push(scope.stack.getScope());
          if (scope.hub && typeof scope.hub.getClient === 'function') candidates.push(scope.hub);
          for (const current of candidates) {
            if (!client && current && typeof current.getClient === 'function') client = current.getClient();
          }
        }
        if (client && typeof client.getOptions === 'function') {
          const options = client.getOptions();
          state.sentry.configured = Boolean(options.dsn);
          state.sentry.disabled = options.enabled === false || !options.dsn;
        }
      } catch (_) {}
      const consentGated = Array.from(document.querySelectorAll('button,[role="dialog"]')).some(e => {
        const r = e.getBoundingClientRect();
        return r.width > 0 && r.height > 0 && /cookie|consent/i.test(e.textContent || '');
      });
      return JSON.stringify({failure:null, consentGated, analytics:state.analytics, sentry:state.sentry, test:state.test || {configured:false,observed:false,accepted:false,rejected:false,disabled:false}, testAttempted:state.testAttempted || false});
    })()
    """#
}
