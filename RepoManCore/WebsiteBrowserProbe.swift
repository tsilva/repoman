import Foundation
import WebKit
import AppKit

/// No saved logins, cookies, consent overrides, or service credentials.
/// This passive observer never manufactures an event or changes consent.
/// Hooks only observe requests the page itself sends; no payloads or identifiers leave the web view.
@MainActor
final class WebsiteBrowserProbe: NSObject, WKNavigationDelegate {
    struct Evidence: Sendable, Decodable {
        var failure: String?
        var consentGated = false
        var analytics = WebsiteTelemetryEvidence()
        var sentry = WebsiteTelemetryEvidence()
    }
    private let domains: Set<String>
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Evidence, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var sampleTask: Task<Void, Never>?
    private var latestEvidence: Evidence?
    private var redirects = 0

    private init(domains: Set<String>) { self.domains = domains }

    static func visit(_ url: URL, domains: Set<String>) async -> Evidence {
        guard WebsiteDomains.permits(url, domains: domains) else {
            return Evidence(failure: "Invalid website verification scope.")
        }
        let probe = WebsiteBrowserProbe(domains: domains)
        return await withTaskCancellationHandler(operation: {
            guard !Task.isCancelled else { return Evidence(failure: "Website inspection cancelled.") }
            return await probe.run(url)
        }, onCancel: { Task { @MainActor in probe.finish(Evidence(failure: "Website inspection cancelled.")) } })
    }

    private func run(_ url: URL) async -> Evidence {
        _ = NSApplication.shared
        return await withCheckedContinuation { continuation in
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
                self.finish(Evidence(failure: "Browser telemetry inspection timed out; delivery remains unverified."))
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
                          let data = json.data(using: .utf8) else { throw InspectionError.blocked("No browser evidence.") }
                    let evidence = try JSONDecoder().decode(Evidence.self, from: data)
                    self.latestEvidence = evidence
                    return evidence
                })
                self.finish(evidence)
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
      const state = {analytics:empty(), sentry:empty()};
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
              if ((host === 'sentry.io' || host.endsWith('.sentry.io')) &&
                  /^\/api\/[0-9]+\/envelope\/?$/.test(u.pathname) &&
                  ['event','transaction','session','sessions'].includes(item.type)) return 'sentry';
            }
          }
        } catch (_) {}
        return null;
      };
      const record = (service, status) => {
        if (!service) return;
        const e = state[service]; e.observed = true;
        if (status >= 200 && status < 300) e.accepted = true;
        else if (status >= 400) e.rejected = true;
      };
      const fetchOriginal = window.fetch;
      window.fetch = function(input, init) {
        const service = kind(input, init && init.body);
        if (service) record(service, 0);
        const request = fetchOriginal.apply(this, arguments);
        if (service) request.then(r => record(service, r.status), () => {state[service].rejected = true;});
        return request;
      };
      const openOriginal = XMLHttpRequest.prototype.open, sendOriginal = XMLHttpRequest.prototype.send;
      const urls = new WeakMap();
      XMLHttpRequest.prototype.open = function(method, url) {
        urls.set(this, url); return openOriginal.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function(body) {
        const service = kind(urls.get(this), body);
        if (service) {
          record(service, 0);
          this.addEventListener('loadend', () => {
            record(service, this.status);
            if (this.status === 0) {state[service].rejected = true;}
          }, {once:true});
        }
        return sendOriginal.apply(this, arguments);
      };
      const beaconOriginal = navigator.sendBeacon;
      if (beaconOriginal) navigator.sendBeacon = function(url, data) {
        const service = kind(url, data);
        const queued = beaconOriginal.apply(this, arguments);
        if (service) {record(service, 0); if (!queued) {state[service].rejected = true;}}
        return queued;
      };
      // Resource timing can confirm GA beacons when the browser exposes responseStatus.
      const resources = entries => {
        for (const entry of entries) {
          const service = kind(entry.name, null);
          if (service) record(service, entry.responseStatus || 0);
        }
      };
      try {new PerformanceObserver(list => resources(list.getEntries())).observe({type:'resource', buffered:true});} catch (_) {}
      Object.defineProperty(window, '__repomanWebsiteEvidence', {value:state});
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
      let denied = false;
      for (const entry of layers) {
        if (entry && entry[0] === 'consent' && entry[2] && entry[2].analytics_storage) {
          denied = entry[2].analytics_storage !== 'granted';
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
          // Modern Sentry transports may use native fetch from a clean realm.
          // Observe its lifecycle callback without generating or flushing events.
          if (!state.sentryHooked && !options.tunnel && options.dsn && typeof client.on === 'function') {
            const dsn = new URL(options.dsn);
            if (dsn.hostname === 'sentry.io' || dsn.hostname.endsWith('.sentry.io')) {
              state.sentryHooked = true;
              client.on('afterSendEvent', (event, response) => {
                if (!event || !event.event_id || !response || typeof response.statusCode !== 'number') return;
                state.sentry.observed = true;
                if (response.statusCode >= 200 && response.statusCode < 300) state.sentry.accepted = true;
                else if (response.statusCode >= 400) state.sentry.rejected = true;
              });
            }
          }
        }
      } catch (_) {}
      const consentGated = denied || Array.from(document.querySelectorAll('button,[role="dialog"]')).some(e => {
        const r = e.getBoundingClientRect();
        return r.width > 0 && r.height > 0 && /cookie|consent/i.test(e.textContent || '');
      });
      return JSON.stringify({failure:null, consentGated, analytics:state.analytics, sentry:state.sentry});
    })()
    """#
}
