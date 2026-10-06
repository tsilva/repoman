import Foundation
import WebKit

/// Bare hostnames in the root metadata opt a repository into production checks.
/// Deliberately restricted to the user's tsilva.eu zone; metadata cannot choose arbitrary URLs.
enum WebsiteDomains {
    static func load(_ context: RepositoryInspectionContext) throws -> [String] {
        guard try context.exists(".repo-metadata.toml") else { return [] }
        let config = try InspectionConfig.toml(context.readText(".repo-metadata.toml"), allSections: true)
        guard let raw = config.values["domains"] else { return [] }
        return try parse(raw)
    }

    static func parse(_ raw: String) throws -> [String] {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("["), value.hasSuffix("]") else {
            throw RepairError.blocked(".repo-metadata.toml domains must be an array of bare tsilva.eu hostnames.")
        }
        let body = value.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { return [] }
        var parts = body.components(separatedBy: ",")
        if parts.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { parts.removeLast() }
        guard parts.count <= 32 else { throw RepairError.blocked("At most 32 website domains can be inspected per repository.") }
        let domains = try parts.map { part -> String in
            let quoted = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard quoted.count >= 2, let quote = quoted.first, ["\"", "'"].contains(quote), quoted.last == quote else {
                throw RepairError.blocked("Website domains must be quoted, bare tsilva.eu hostnames.")
            }
            let host = String(quoted.dropFirst().dropLast()).lowercased()
            guard valid(host) else { throw RepairError.blocked("Website domains must be bare tsilva.eu hostnames, without schemes, paths, ports, or wildcards.") }
            return host
        }
        guard Set(domains).count == domains.count else { throw RepairError.blocked("Duplicate website domains in .repo-metadata.toml.") }
        return domains.sorted()
    }

    static func valid(_ host: String) -> Bool {
        guard host.count <= 253, host == "tsilva.eu" || host.hasSuffix(".tsilva.eu") else { return false }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            CheckSupport.matches(String($0), #"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$"#)
        }
    }

    static func permits(_ url: URL?, domains: Set<String>) -> Bool {
        guard let url, url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return domains.contains(host)
    }
}

struct WebsiteTelemetryEvidence: Sendable, Decodable {
    var configured = false
    var observed = false
    var accepted = false
    var rejected = false
    var disabled = false
}

struct WebsiteProbe: Sendable {
    var status: Int?
    // Evidence belongs to the requested hostname, even if its canonical destination differs.
    var cloudflare: Bool?
    var isHTML = false
    var transportFailure: String?
    var browserFailure: String?
    var consentGated = false
    var analytics = WebsiteTelemetryEvidence()
    var sentry = WebsiteTelemetryEvidence()
}

public enum RepositoryWebsiteChecks {
    typealias Loader = @Sendable (String, Set<String>) async -> WebsiteProbe

    public static func checks() -> [RepositoryCheck] { checks(load: nil) }

    static func checks(load: Loader?) -> [RepositoryCheck] {
        let definitions = [
            ("website.online", "Website availability", "network"),
            ("website.sentry", "Sentry reporting", "exclamationmark.bubble"),
            ("website.analytics", "Google Analytics collection", "chart.bar"),
            ("website.cloudflare", "Cloudflare proxy", "cloud")
        ]
        return definitions.map { id, title, symbol in
            RepositoryCheck(id: id, title: title, category: .setup, symbol: symbol, validityPeriod: 300, evaluate: { context in
                let domains = try WebsiteDomains.load(context)
                guard !domains.isEmpty else { return .findings([]) }
                let policy = try RepositoryCheckPolicy.load(context)
                var findings: [RepositoryFinding] = [], incomplete: [String] = []
                let selected = domains.filter { policy.exceptions[id]?[$0] == nil }
                let probes = await context.websiteProbes.loadAll(selected, domains: Set(domains),
                    allowCached: context.allowCachedWebsiteChecks, loader: load)
                for domain in selected {
                    guard let probe = probes[domain] else { continue }
                    if probe.cached { context.markCached(id) }
                    switch classify(probe.value, checkID: id) {
                    case .pass: break
                    case .issue(let reason):
                        findings.append(CheckSupport.finding(context, id, domain, title, "\(domain): \(reason)", .setup, symbol))
                    case .deliveryUnverified(let reason):
                        let name = id == "website.sentry" ? "Sentry" : "Google Analytics"
                        findings.append(CheckSupport.finding(context, id, domain, "\(name) delivery unverified",
                            "\(domain): \(reason)", .setup, symbol, severity: .information))
                    case .unknown(let reason): incomplete.append("\(domain): \(reason)")
                    }
                }
                return incomplete.isEmpty ? .findings(findings) : .partial(findings, incomplete.joined(separator: "\n"))
            })
        }
    }

    enum Verdict: Equatable { case pass, issue(String), deliveryUnverified(String), unknown(String) }
    static func classify(_ probe: WebsiteProbe, checkID: String) -> Verdict {
        if checkID == "website.cloudflare", let proxied = probe.cloudflare {
            return proxied ? .pass : .issue("The requested domain's HTTPS response has no Cloudflare CF-Ray header. Check that its DNS record is proxied.")
        }
        if let reason = probe.transportFailure {
            return checkID == "website.online" ? .issue(reason) : .unknown("Website could not be reached; \(reason)")
        }
        guard let status = probe.status else { return .unknown("No HTTPS response was available.") }
        guard (200..<300).contains(status) else {
            let reason = "HTTPS returned HTTP \(status). Authentication, bot protection, or an unavailable deployment may need review."
            return checkID == "website.online" ? .issue(reason) : .unknown(reason)
        }
        if checkID == "website.online" { return .pass }
        guard probe.isHTML else { return .unknown("The domain did not return an HTML page; browser telemetry could not be verified.") }
        if let reason = probe.browserFailure { return .unknown(reason) }
        let evidence = checkID == "website.sentry" ? probe.sentry : probe.analytics
        let name = checkID == "website.sentry" ? "Sentry" : "Google Analytics"
        if evidence.rejected { return .issue("\(name) collection returned an error; check the live SDK configuration and ingestion service.") }
        if evidence.disabled { return probe.consentGated ? .unknown("\(name) is consent-gated; consent was not changed.") : .issue("The live \(name) client is disabled or has no runtime configuration.") }
        if evidence.accepted { return .pass }
        if probe.consentGated { return .unknown("\(name) collection is consent-gated; consent was not changed.") }
        if evidence.configured {
            let setup = checkID == "website.sentry" ? "Sentry setup confirmed; delivery unverified. The live client is configured and enabled" : "Google tag detected; delivery unverified"
            return .deliveryUnverified("\(setup), but no successful collection response was observed. Verify an event in the service dashboard.")
        }
        if evidence.observed { return .deliveryUnverified("A live \(name) collection request was observed; delivery unverified because its response status was unavailable. Verify receipt in the service dashboard.") }
        return .unknown("No live \(name) initialization or collection was observed on the public landing page. Review missing instrumentation, server-only SDKs, consent, or custom telemetry routes.")
    }

    static let recipes: [RepairRecipe] = [
        RepairRecipe(id: "website.online", title: "Restore website availability", prompt: "Inspect the declared domain in the root .repo-metadata.toml and its current Vercel deployment, DNS, TLS, redirects and HTTP response. Restore the intended site using repository evidence. Preserve legitimate access controls. Verify the live domain. Leave source changes uncommitted; do not push, deploy or change DNS without my explicit authorization."),
        RepairRecipe(id: "website.sentry", title: "Send Sentry test event", prompt: deliveryTestPrompt(service: "Sentry")),
        RepairRecipe(id: "website.analytics", title: "Send Google Analytics test event", prompt: deliveryTestPrompt(service: "Google Analytics")),
        RepairRecipe(id: "website.cloudflare", title: "Verify Cloudflare proxying", prompt: "Inspect the reported domain's Cloudflare DNS record, proxy setting and HTTPS response. Preserve the Vercel domain assignment, TLS and canonical redirects. Confirm CF-Ray on the requested domain, not just a redirect destination. Explain any intentional DNS-only setup. Ask before changing DNS or external configuration; do not publish source changes.")
    ]

    private static func deliveryTestPrompt(service: String) -> String {
        """
        Run the available browser delivery test for \(service) on the reported domains using test_website_delivery. I authorize one labelled synthetic test event per reported domain in this verification turn, through the site's existing loaded SDK. This may appear in production telemetry; no additional confirmation is needed for this bounded test. Respect consent gates and disabled clients. Do not bypass consent, create direct ingestion requests, load a replacement SDK, or invent credentials. The tool uses an isolated native browser and needs no external browser runtime or service credentials.
        First call the tool for each reported domain. Report the returned evidence: a correlated 2xx ingestion response confirms test collection acceptance; SDK queueing, a flush result, or unrelated session traffic does not. An accepted test completes this ingestion verification; the host records structured proof for the repair check. Dashboard processing is separate and optional for this task. Do not request dashboard access or stop for user input merely because it is unavailable. State that dashboard receipt was not checked without treating that as failure.
        If the test confirms acceptance, report success and finish; do not install browser tooling, run unrelated typechecks, or inspect other source. If the test is blocked or rejected, inspect the root .repo-metadata.toml, the exact production deployment source, \(service) initialization, production configuration, consent and CSP. Prepare any missing instrumentation and run relevant local tests. Do not print measurement IDs, DSNs, credentials, payloads, or request URLs. Leave source changes uncommitted; ask before deploying or changing external configuration. If this existing chat has no delivery tool, explain that a new delivery-test session is needed; do not substitute raw network calls.
        """
    }

}

/// One probe per domain per inspection, shared by the four independently configurable checks.
actor WebsiteInspectionSession {
    private var tasks: [String: Task<(value: WebsiteProbe, cached: Bool), Never>] = [:]
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Different checks may exempt different domains. Bound the shared session,
    /// so overlapping batches still run no more than four actual probes.
    func loadAll(_ selected: [String], domains: Set<String>, allowCached: Bool,
                 loader: RepositoryWebsiteChecks.Loader?) async -> [String: (value: WebsiteProbe, cached: Bool)] {
        await withTaskGroup(of: (String, WebsiteProbe, Bool).self) { group in
            for domain in selected {
                group.addTask {
                    let result = await self.load(domain, domains: domains, allowCached: allowCached, loader: loader)
                    return (domain, result.value, result.cached)
                }
            }
            var results: [String: (value: WebsiteProbe, cached: Bool)] = [:]
            for await (domain, value, cached) in group { results[domain] = (value, cached) }
            return results
        }
    }

    private func acquireSlot() async {
        if active < 4 { active += 1 }
        else { await withCheckedContinuation { waiting.append($0) } }
    }
    private func releaseSlot() {
        if waiting.isEmpty { active -= 1 }
        else { waiting.removeFirst().resume() }
    }
    func load(_ domain: String, domains: Set<String>, allowCached: Bool, loader: RepositoryWebsiteChecks.Loader?) async -> (value: WebsiteProbe, cached: Bool) {
        if let task = tasks[domain] { return await task.value }
        let task = Task {
            await acquireSlot()
            defer { releaseSlot() }
            if let loader { return (value: await loader(domain, domains), cached: false) }
            return await WebsiteProbeCache.shared.load(domain, domains: domains, allowCached: allowCached)
        }
        tasks[domain] = task
        return await task.value
    }
}

actor WebsiteProbeCache {
    static let shared = WebsiteProbeCache()
    private var values: [String: (date: Date, probe: WebsiteProbe)] = [:]
    func load(_ domain: String, domains: Set<String>, allowCached: Bool, now: Date = Date(),
              loader: RepositoryWebsiteChecks.Loader = { await WebsiteLiveProbe.load($0, domains: $1) }) async -> (value: WebsiteProbe, cached: Bool) {
        let key = ([domain] + domains.sorted()).joined(separator: "\n")
        if allowCached, let saved = values[key] {
            let period: TimeInterval = saved.probe.transportFailure == nil && saved.probe.browserFailure == nil ? 300 : 60
            if (0..<period).contains(now.timeIntervalSince(saved.date)) { return (saved.probe, true) }
        }
        let probe = await loader(domain, domains)
        if values.count >= 256, let oldest = values.min(by: { $0.value.date < $1.value.date })?.key { values.removeValue(forKey: oldest) }
        values[key] = (now, probe)
        return (probe, false)
    }
}

/// A small HTTPS read, followed by an isolated browser visit only for successful HTML responses.
enum WebsiteLiveProbe {
    static func load(_ domain: String, domains: Set<String>) async -> WebsiteProbe {
        guard WebsiteDomains.valid(domain), domains.contains(domain), let url = URL(string: "https://" + domain + "/") else {
            return WebsiteProbe(transportFailure: "Invalid declared website domain.")
        }
        let redirects = WebsiteRedirects(domain: domain, domains: domains)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 15
        config.httpCookieStorage = nil; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: redirects, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.setValue("RepoMan/1.0 WebsiteCheck", forHTTPHeaderField: "User-Agent")
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { return WebsiteProbe(transportFailure: "No HTTPS response was available.") }
            var count = 0
            for try await _ in bytes { count += 1; if count > 2_097_152 { break } }
            let redirect = redirects.evidence
            let proxied = redirect.cloudflare ?? (response.value(forHTTPHeaderField: "CF-Ray")?.isEmpty == false)
            var result = WebsiteProbe(status: response.statusCode, cloudflare: proxied, isHTML: response.mimeType?.lowercased() == "text/html")
            if redirect.blocked { result.transportFailure = "The site redirects outside the declared HTTPS domains, or exceeds five redirects."; return result }
            guard (200..<300).contains(response.statusCode), result.isHTML else { return result }
            let browser = await WebsiteBrowserProbe.visit(url, domains: domains)
            result.browserFailure = browser.failure; result.consentGated = browser.consentGated
            result.analytics = browser.analytics; result.sentry = browser.sentry
            return result
        } catch {
            // Network errors may contain URL query strings. Keep persisted evidence credential-free.
            let reason: String
            switch (error as NSError).code {
            case NSURLErrorTimedOut: reason = "HTTPS request timed out."
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: reason = "DNS lookup failed."
            case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate, NSURLErrorSecureConnectionFailed: reason = "TLS verification failed."
            default: reason = "HTTPS connection failed."
            }
            return WebsiteProbe(cloudflare: redirects.evidence.cloudflare, transportFailure: reason)
        }
    }
}

private final class WebsiteRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let domain: String, domains: Set<String>
    private let lock = NSLock()
    private var cloudflare: Bool?, blocked = false, count = 0
    init(domain: String, domains: Set<String>) { self.domain = domain; self.domains = domains }
    var evidence: (cloudflare: Bool?, blocked: Bool) { lock.lock(); defer { lock.unlock() }; return (cloudflare, blocked) }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        if count == 0, response.url?.host?.lowercased() == domain { cloudflare = response.value(forHTTPHeaderField: "CF-Ray")?.isEmpty == false }
        count += 1
        let allowed = count <= 5 && WebsiteDomains.permits(request.url, domains: domains)
        if !allowed { blocked = true }
        lock.unlock()
        completionHandler(allowed ? request : nil)
    }
}


/// A client-owned tool; model arguments cannot expand its domain or service scope.
/// Kept separate from passive inspection and its cache: synthetic proof is reported in the chat.
enum WebsiteDeliveryTest {
    static let toolName = "test_website_delivery"
    static let definition: JSONValue = .object([
        "type": .string("function"), "name": .string(toolName),
        "description": .string("Send one labelled test event through the live site's existing SDK in an isolated browser. Only for the selected delivery-test preset and reported metadata domains. Returns correlated ingestion evidence, not dashboard receipt. Does not change consent or use service credentials."),
        "inputSchema": .object(["type": .string("object"), "properties": .object([
            "domain": .object(["type": .string("string"), "description": .string("Reported bare domain from root metadata.")])
        ]), "required": .array([.string("domain")]), "additionalProperties": .bool(false)])
    ])

    static func service(for task: RepairTask) -> String? {
        // Older plain-text retries erased recipeID. Recover only the explicitly
        // authorized service from the original user prompt and unchanged findings.
        let id = task.recipeID ?? task.finding.checkID
        guard ["website.analytics", "website.sentry"].contains(id),
              task.findings.allSatisfy({ $0.checkID == id }) else { return nil }
        let name = id == "website.sentry" ? "Sentry" : "Google Analytics"
        let authorization = "Run the available browser delivery test for \(name) on the reported domains using \(toolName). I authorize one labelled synthetic test event per reported domain"
        guard task.prompt.hasPrefix(authorization) else { return nil }
        return id == "website.sentry" ? "sentry" : "analytics"
    }

    static func domains(for task: RepairTask, domain: String) throws -> Set<String> {
        guard service(for: task) != nil, task.findings.contains(where: { $0.subject == domain }) else {
            throw RepairError.blocked("This domain or service is outside the selected delivery-test preset.")
        }
        let snapshot = try GitRepositoryScanner.scan(task.repositoryURL)
        let declared = Set(try WebsiteDomains.load(RepositoryInspectionContext(snapshot: snapshot)))
        guard declared.contains(domain), WebsiteDomains.valid(domain) else {
            throw RepairError.blocked("The reported domain is no longer declared in root metadata.")
        }
        return declared
    }

    static func run(_ task: RepairTask, domain: String) async throws -> String {
        try await perform(task, domain: domain).summary
    }

    static func perform(_ task: RepairTask, domain: String) async throws -> (summary: String, receipt: WebsiteDeliveryReceipt?) {
        let declared = try domains(for: task, domain: domain)
        guard let service = service(for: task), let url = URL(string: "https://" + domain + "/") else {
            throw RepairError.blocked("Invalid delivery-test scope.")
        }
        let evidence = await WebsiteBrowserProbe.visit(url, domains: declared, testService: service)
        let receipt: WebsiteDeliveryReceipt?
        if evidence.failure == nil, !evidence.consentGated, evidence.test.accepted, !evidence.test.rejected {
            receipt = WebsiteDeliveryReceipt(repositoryID: task.finding.repositoryID, checkID: "website." + service,
                domain: domain, declaredDomains: declared.sorted(), acceptedAt: Date())
        } else { receipt = nil }
        return (summary(evidence, domain: domain), receipt)
    }

    static func summary(_ evidence: WebsiteBrowserProbe.Evidence, domain: String) -> String {
        let result: String
        if let failure = evidence.failure { result = failure }
        else if evidence.consentGated { result = "Consent-gated; no synthetic event was sent." }
        else if evidence.test.rejected { result = "The labelled test collection failed or was rejected." }
        else if evidence.test.accepted { result = "A correlated labelled test event received a 2xx ingestion response; test collection accepted." }
        else if evidence.testAttempted {
            result = evidence.test.observed ? "Test collection observed; response status unavailable, so delivery remains unverified." : "The SDK was asked to send a test event; no correlated collection response was observed. Delivery remains unverified."
        } else { result = "No test event sent: the loaded SDK is unavailable, disabled, consent-gated, or unsupported." }
        return "\(domain): \(result) Dashboard receipt was not checked."
    }
}


/// Credential-free proof produced only by the host's correlated SDK transport response.
public struct WebsiteDeliveryReceipt: Codable, Equatable, Sendable {
    public let repositoryID: String
    public let checkID: String
    public let domain: String
    public let declaredDomains: [String]
    public let acceptedAt: Date

    func verification(for finding: RepositoryFinding, in report: RepositoryInspectionReport,
                      domains: [String], now: Date = Date()) -> RepairVerification? {
        guard repositoryID == report.snapshot.id, repositoryID == finding.repositoryID,
              checkID == finding.checkID, domain == finding.subject,
              declaredDomains == domains.sorted(), (0..<300).contains(now.timeIntervalSince(acceptedAt)),
              !report.cachedChecks.contains(checkID), let result = report.results[checkID] else { return nil }
        let findings: [RepositoryFinding]
        switch result {
        case .findings(let values), .partial(let values, _): findings = values
        case .unavailable: return nil
        }
        // Fresh failures or disabled clients take precedence; only silent setup is resolved by proof.
        guard let current = findings.first(where: { $0.id == finding.id }), current.severity == .information else { return nil }
        return .absent("\(domain): The labelled test event received a correlated 2xx ingestion response. Delivery verified; dashboard processing was not checked.")
    }
}
