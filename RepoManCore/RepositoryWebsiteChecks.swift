import Foundation

/// Production sites declared in the repository's root RepoMan manifest.
/// Deliberately restricted to the user's tsilva.eu zone; metadata cannot choose arbitrary URLs.
enum WebsiteDomains {
    static let manifest = RepoManManifest.path

    struct TelemetryPolicy {
        enum Expectation: String { case required, optional, disabled }
        var expectation: Expectation = .required
        var path = "/"
        var exceptionReason: String?
    }

    static func load(_ context: RepositoryInspectionContext) throws -> [String] {
        try inventory(context).keys.sorted()
    }

    static func inventory(_ context: RepositoryInspectionContext) throws -> [String: [String: TelemetryPolicy]] {
        if try context.exists(manifest) {
            let config = try context.yaml(manifest)
            if config.values["websites"] != nil || config.values.keys.contains(where: { $0.hasPrefix("websites.") }) {
                return try manifestInventory(config)
            }
            guard config.values["version"] == "1" else {
                throw InspectionError.blocked("Unsupported .repoman.yaml version.")
            }
        }
        guard try context.exists(".repo-metadata.toml") else { return [:] }
        let config = try InspectionConfig.toml(context.readText(".repo-metadata.toml"), allSections: true)
        guard let raw = config.values["domains"] else { return [:] }
        return Dictionary(uniqueKeysWithValues: try parse(raw).map { ($0, [:]) })
    }

    private static func manifestInventory(_ config: InspectionConfig) throws -> [String: [String: TelemetryPolicy]] {
        let values = config.values
        func invalid() -> InspectionError {
            .blocked("Invalid .repoman.yaml website inventory. Use version 1 and a websites mapping with one HTTPS root URL per tsilva.eu hostname.")
        }
        guard values["version"] == "1",
              let websites = values["websites"], websites.isEmpty || websites == "{}" else { throw invalid() }
        let prefix = "websites."
        let urlSuffix = ".url"
        let entries = values.keys.filter { $0.hasPrefix(prefix) }
        let domains = entries.filter { $0.hasSuffix(urlSuffix) }.map {
            String($0.dropFirst(prefix.count).dropLast(urlSuffix.count))
        }.sorted()
        guard domains.count <= 32, websites.isEmpty ? !domains.isEmpty : entries.isEmpty else { throw invalid() }
        var supportedKeys: Set<String> = []
        var inventory: [String: [String: TelemetryPolicy]] = [:]
        for domain in domains {
            let entry = prefix + domain
            let url = InspectionConfig.scalar(values[entry + urlSuffix])
            guard valid(domain), values[entry] == "",
                  url == "https://\(domain)" || url == "https://\(domain)/" else { throw invalid() }
            supportedKeys.formUnion([entry, entry + urlSuffix])
            var policies: [String: TelemetryPolicy] = [:]
            for service in ["ga4", "sentry"] {
                let key = entry + "." + service
                if let status = InspectionConfig.scalar(values[key]) {
                    guard ["accepted", "observed", "tag-detected", "source-detected", "unverified"].contains(status) else { throw invalid() }
                    supportedKeys.insert(key)
                }
                let expectationKey = key + "-expectation"
                let pathKey = key + "-verification-path"
                let reasonKey = key + "-exception-reason"
                let rawExpectation = InspectionConfig.scalar(values[expectationKey]) ?? "required"
                let path = InspectionConfig.scalar(values[pathKey]) ?? "/"
                let reason = InspectionConfig.scalar(values[reasonKey])?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let expectation = TelemetryPolicy.Expectation(rawValue: rawExpectation), validPath(path),
                      expectation == .required ? reason == nil : reason.map({ (1...240).contains($0.count) }) == true else {
                    throw InspectionError.blocked("Invalid .repoman.yaml telemetry policy for \(domain) (\(service)). Use a site-relative verification path and provide a reason for optional or disabled checks.")
                }
                policies[service] = TelemetryPolicy(expectation: expectation, path: path, exceptionReason: reason)
                supportedKeys.formUnion([expectationKey, pathKey, reasonKey].filter { values[$0] != nil })
            }
            if let checked = InspectionConfig.scalar(values[entry + ".checked-on"]) {
                guard CheckSupport.matches(checked, #"^\d{4}-\d{2}-\d{2}$"#) else { throw invalid() }
                supportedKeys.insert(entry + ".checked-on")
            }
            if let availability = InspectionConfig.scalar(values[entry + ".availability"]) {
                guard ["reachable", "unavailable", "unverified"].contains(availability) else { throw invalid() }
                supportedKeys.insert(entry + ".availability")
            }
            if let redirect = InspectionConfig.scalar(values[entry + ".redirect-to"]) {
                guard let destination = URL(string: redirect), let host = destination.host, domains.contains(host),
                      host != domain, redirect == "https://\(host)" || redirect == "https://\(host)/" else { throw invalid() }
                supportedKeys.insert(entry + ".redirect-to")
            }
            inventory[domain] = policies
        }
        guard Set(entries) == supportedKeys else { throw invalid() }
        return inventory
    }

    static func validPath(_ path: String) -> Bool {
        path.count <= 256 && CheckSupport.matches(path, #"^/(?:[A-Za-z0-9._~-]+/)*[A-Za-z0-9._~-]*\z"#)
            && !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }

    static func parse(_ raw: String) throws -> [String] {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("["), value.hasSuffix("]") else {
            throw InspectionError.blocked(".repo-metadata.toml domains must be an array of bare tsilva.eu hostnames.")
        }
        let body = value.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { return [] }
        var parts = body.components(separatedBy: ",")
        if parts.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { parts.removeLast() }
        guard parts.count <= 32 else { throw InspectionError.blocked("At most 32 website domains can be inspected per repository.") }
        let domains = try parts.map { part -> String in
            let quoted = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard quoted.count >= 2, let quote = quoted.first, ["\"", "'"].contains(quote), quoted.last == quote else {
                throw InspectionError.blocked("Website domains must be quoted, bare tsilva.eu hostnames.")
            }
            let host = String(quoted.dropFirst().dropLast()).lowercased()
            guard valid(host) else { throw InspectionError.blocked("Website domains must be bare tsilva.eu hostnames, without schemes, paths, ports, or wildcards.") }
            return host
        }
        guard Set(domains).count == domains.count else { throw InspectionError.blocked("Duplicate website domains in .repo-metadata.toml.") }
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
    var isHTML = false
    var transportFailure: String?
    var browserFailure: String?
    var consentGated = false
    var analytics = WebsiteTelemetryEvidence()
    var sentry = WebsiteTelemetryEvidence()
}

public enum RepositoryWebsiteChecks {
    typealias Loader = @Sendable (String, String, Set<String>) async -> WebsiteProbe

    public static func checks() -> [RepositoryCheck] { checks(load: nil, inventory: nil) }

    static func checks(load: Loader?, inventory: WebsiteInventoryLoader?) -> [RepositoryCheck] {
        let definitions = [
            ("website.domains", "Production website coverage", "globe"),
            ("website.sentry", "Sentry reporting", "exclamationmark.bubble"),
            ("website.analytics", "Google Analytics collection", "chart.bar")
        ]
        return definitions.map { id, title, symbol in
            RepositoryCheck(id: id, title: title, category: .setup, symbol: symbol, validityPeriod: 300, evaluate: { context in
                let websiteInventory = try WebsiteDomains.inventory(context)
                let declared = websiteInventory.keys.sorted()
                let resolution = try await context.websites.domains(context, declared: declared, loader: inventory)
                if resolution.cached { context.markCached(id) }
                let domains = resolution.domains
                guard !domains.isEmpty || resolution.reason != nil else {
                    return .notApplicable("No production tsilva.eu domains found for this repository in accessible Vercel teams or root metadata.")
                }
                var policy = try RepositoryCheckPolicy.load(context)
                var findings: [RepositoryFinding] = [], incomplete = resolution.reason.map { [$0] } ?? []
                if id == "website.domains" {
                    for domain in domains where !declared.contains(domain) {
                        findings.append(CheckSupport.finding(context, id, domain, "Production domain missing from metadata",
                            "\(domain): Vercel assigns this production domain to this repository, but the repository website inventory does not declare it. Add it to .repoman.yaml. Telemetry checks include it automatically.", .setup, symbol))
                    }
                    findings = context.applyingExceptions(findings, policy: policy)
                } else {
                    let service = id == "website.sentry" ? "sentry" : "ga4"
                    var paths: [String: String] = [:]
                    for domain in domains {
                        let telemetry = websiteInventory[domain]?[service] ?? WebsiteDomains.TelemetryPolicy()
                        if policy.exceptions[id]?[domain] != nil { continue }
                        if let reason = telemetry.exceptionReason {
                            policy.exceptions[id, default: [:]][domain] = "\(telemetry.expectation.rawValue.capitalized): \(reason)"
                        } else {
                            paths[domain] = telemetry.path
                        }
                    }
                    let probes = await context.websites.loadAll(paths, domains: Set(domains), allowCached: context.allowCachedWebsiteChecks, loader: load)
                    for domain in paths.keys.sorted() {
                        let target = domain + (paths[domain] ?? "/")
                        guard let probe = probes[domain] else { incomplete.append("\(domain): No probe result."); continue }
                        if probe.cached { context.markCached(id) }
                        switch classify(probe.value, checkID: id) {
                        case .pass: break
                        case .issue(let reason):
                            findings.append(CheckSupport.finding(context, id, domain, title, "\(target): \(reason)", .setup, symbol))
                        case .deliveryUnverified(let reason), .unknown(let reason):
                            incomplete.append("\(target): \(reason)")
                        }
                    }
                    // Exceptions skip network probes, but are still visible in reports.
                    let excepted = domains.filter { policy.exceptions[id]?[$0] != nil }.map {
                        CheckSupport.finding(context, id, $0, title, "Domain explicitly excepted.", .setup, symbol)
                    }
                    _ = context.applyingExceptions(excepted, policy: policy)
                }
                return incomplete.isEmpty ? .findings(findings) : .partial(findings, incomplete.joined(separator: "\n"))
            })
        }
    }

    enum Verdict: Equatable { case pass, issue(String), deliveryUnverified(String), unknown(String) }
    static func classify(_ probe: WebsiteProbe, checkID: String) -> Verdict {
        if let reason = probe.transportFailure {
            return .unknown("Website could not be reached; \(reason)")
        }
        guard let status = probe.status else { return .unknown("No HTTPS response was available.") }
        guard (200..<300).contains(status) else {
            let reason = "HTTPS returned HTTP \(status). Authentication, bot protection, or an unavailable deployment may need review."
            return .unknown(reason)
        }
        guard probe.isHTML else { return .unknown("The domain did not return an HTML page; browser telemetry could not be verified.") }
        if let reason = probe.browserFailure { return .unknown(reason) }
        let evidence = checkID == "website.sentry" ? probe.sentry : probe.analytics
        let name = checkID == "website.sentry" ? "Sentry" : "Google Analytics"
        if evidence.rejected { return .issue("\(name) collection returned an error; check the live SDK configuration and ingestion service.") }
        if evidence.disabled { return probe.consentGated ? .unknown("\(name) is consent-gated; consent was not changed.") : .issue("The live \(name) client is disabled or has no runtime configuration.") }
        if probe.consentGated { return .unknown("\(name) collection is consent-gated; consent was not changed.") }
        if evidence.accepted && evidence.observed { return .pass }
        if evidence.configured {
            let setup = checkID == "website.sentry" ? "Sentry setup confirmed; delivery unverified. The live client is configured and enabled" : "Google tag detected; delivery unverified"
            return .deliveryUnverified("\(setup), but no successful collection response was observed. Verify an event in the service dashboard. Ingestion acceptance is separate from dashboard processing.")
        }
        if evidence.observed { return .deliveryUnverified("A live \(name) collection request was observed; delivery unverified because its response status was unavailable. Verify receipt in the service dashboard.") }
        return .unknown("No live \(name) initialization or collection was observed on the verification page. Review missing instrumentation, server-only SDKs, consent, or custom telemetry routes.")
    }

}

/// One passive probe per domain and path per inspection, shared by both services.
actor WebsiteInspectionSession {
    private var tasks: [String: Task<WebsiteProbeResult, Never>] = [:]
    private var domainTask: Task<WebsiteDomainResolution, Error>?
    func domains(_ context: RepositoryInspectionContext, declared: [String], loader: WebsiteInventoryLoader?) async throws -> WebsiteDomainResolution {
        if let domainTask { return try await domainTask.value }
        let task = Task { try await WebsiteDomainResolution.load(context, declared: declared, loader: loader) }
        domainTask = task
        return try await task.value
    }
    func loadAll(_ paths: [String: String], domains: Set<String>, allowCached: Bool, loader: RepositoryWebsiteChecks.Loader?) async -> [String: WebsiteProbeResult] {
        // Each repository has at most four probes in flight. The global limiter
        // also bounds probes across simultaneous repository inspections.
        await withTaskGroup(of: (String, WebsiteProbeResult).self) { group in
            var pending = paths.keys.sorted().makeIterator(), result: [String: WebsiteProbeResult] = [:]
            func enqueue(_ domain: String) {
                let path = paths[domain] ?? "/"
                group.addTask { (domain, await self.load(domain, path: path, domains: domains, allowCached: allowCached, loader: loader)) }
            }
            for _ in 0..<4 { if let domain = pending.next() { enqueue(domain) } }
            for await (domain, probe) in group {
                result[domain] = probe
                if let next = pending.next() { enqueue(next) }
            }
            return result
        }
    }
    private func load(_ domain: String, path: String, domains: Set<String>, allowCached: Bool, loader: RepositoryWebsiteChecks.Loader?) async -> WebsiteProbeResult {
        let target = domain + path
        if let task = tasks[target] { return await task.value }
        let task = Task {
            if let loader {
                await WebsiteProbeLimiter.shared.acquire()
                let probe = await loader(domain, path, domains)
                await WebsiteProbeLimiter.shared.release()
                return WebsiteProbeResult(value: probe)
            }
            return await WebsiteProbeCache.shared.load(domain, path: path, domains: domains, allowCached: allowCached)
        }
        tasks[target] = task
        return await task.value
    }
}

struct WebsiteProbeResult: Sendable {
    let value: WebsiteProbe
    var cached = false
}

actor WebsiteProbeCache {
    static let shared = WebsiteProbeCache()
    private var values: [String: (Date, WebsiteProbe)] = [:]
    private var tasks: [String: Task<WebsiteProbe, Never>] = [:]
    func load(_ domain: String, path: String = "/", domains: Set<String>, allowCached: Bool, now: Date = Date(),
              loader: @escaping RepositoryWebsiteChecks.Loader = { await WebsiteLiveProbe.load($0, path: $1, domains: $2) }) async -> WebsiteProbeResult {
        let key = ([domain + path] + domains.sorted()).joined(separator: "\n")
        if allowCached, let (date, probe) = values[key], (0..<300).contains(now.timeIntervalSince(date)) {
            return WebsiteProbeResult(value: probe, cached: true)
        }
        if let task = tasks[key] { return WebsiteProbeResult(value: await task.value) }
        let task = Task {
            await WebsiteProbeLimiter.shared.acquire()
            let probe = await loader(domain, path, domains)
            await WebsiteProbeLimiter.shared.release()
            return probe
        }
        tasks[key] = task
        let probe = await task.value
        tasks[key] = nil
        if values.count >= 256, let oldest = values.min(by: { $0.value.0 < $1.value.0 })?.key { values[oldest] = nil }
        values[key] = (now, probe)
        return WebsiteProbeResult(value: probe)
    }
}

actor WebsiteProbeLimiter {
    static let shared = WebsiteProbeLimiter()
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if active < 4 { active += 1 }
        else { await withCheckedContinuation { waiting.append($0) } }
    }
    func release() {
        if waiting.isEmpty { active -= 1 }
        else { waiting.removeFirst().resume() }
    }
}

/// A small HTTPS read, followed by an isolated browser visit only for successful HTML responses.
enum WebsiteLiveProbe {
    static func load(_ domain: String, path: String, domains: Set<String>) async -> WebsiteProbe {
        guard WebsiteDomains.valid(domain), WebsiteDomains.validPath(path), domains.contains(domain),
              let url = URL(string: "https://" + domain + path) else {
            return WebsiteProbe(transportFailure: "Invalid declared website verification target.")
        }
        let redirects = WebsiteRedirects(domain: domain, domains: domains)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 15
        config.httpCookieStorage = nil; config.urlCache = nil; config.urlCredentialStorage = nil; config.httpShouldSetCookies = false
        let session = URLSession(configuration: config, delegate: redirects, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.setValue("RepoMan/1.0 WebsiteCheck", forHTTPHeaderField: "User-Agent")
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { return WebsiteProbe(transportFailure: "No HTTPS response was available.") }
            var count = 0
            for try await _ in bytes { count += 1; if count > 2_097_152 { return WebsiteProbe(transportFailure: "Website response exceeded the inspection limit.") } }
            let redirect = redirects.evidence
            var result = WebsiteProbe(status: response.statusCode, isHTML: response.mimeType?.lowercased() == "text/html")
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
            return WebsiteProbe(transportFailure: reason)
        }
    }
}

private final class WebsiteRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let domain: String, domains: Set<String>
    private let lock = NSLock()
    private var blocked = false, count = 0
    init(domain: String, domains: Set<String>) { self.domain = domain; self.domains = domains }
    var evidence: (blocked: Bool, count: Int) { lock.lock(); defer { lock.unlock() }; return (blocked, count) }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        count += 1
        let allowed = count <= 5 && WebsiteDomains.permits(request.url, domains: domains)
        if !allowed { blocked = true }
        lock.unlock()
        completionHandler(allowed ? request : nil)
    }
}
