import Foundation

/// Production sites declared in the repository's root RepoMan manifest.
/// Metadata declares tsilva.eu hosts. Vercel inventory can supply production aliases.
enum WebsiteDomains {
    static let manifest = RepoManManifest.legacyPath

    struct TelemetryPolicy {
        enum Expectation: String { case required, optional, disabled }
        var expectation: Expectation = .required
        var path = "/"
        var exceptionReason: String?
    }

    static func load(_ context: RepositoryInspectionContext) throws -> [String] {
        try inventory(context).keys.sorted()
    }

    static func projectID(_ context: RepositoryInspectionContext) throws -> String? {
        if let raw = try RepoManManifest.object(context)["vercel-project-id"] {
            guard let id = raw as? String, CheckSupport.matches(id, #"^prj_[A-Za-z0-9]{1,124}\z"#) else {
                throw InspectionError.blocked("Invalid Vercel project ID in .repoman.json.")
            }
            return id
        }
        guard try context.exists(manifest),
              let id = InspectionConfig.scalar(try context.yaml(manifest).values["vercel-project-id"]) else { return nil }
        guard CheckSupport.matches(id, #"^prj_[A-Za-z0-9]{1,124}\z"#) else {
            throw InspectionError.blocked("Invalid Vercel project ID in .repoman.yaml.")
        }
        return id
    }

    static func inventory(_ context: RepositoryInspectionContext) throws -> [String: [String: TelemetryPolicy]] {
        if let raw = try RepoManManifest.object(context)["websites"] {
            return try jsonInventory(raw)
        }
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

    private static func jsonInventory(_ raw: Any) throws -> [String: [String: TelemetryPolicy]] {
        let invalid = InspectionError.blocked("Invalid .repoman.json website inventory or telemetry policy.")
        guard let sites = raw as? [String: [String: String]], sites.count <= 32 else { throw invalid }
        let allowed: Set<String> = ["url", "checked-on", "redirect-to", "availability", "ga4", "sentry",
            "ga4-expectation", "ga4-verification-path", "ga4-exception-reason",
            "sentry-expectation", "sentry-verification-path", "sentry-exception-reason"]
        var result: [String: [String: TelemetryPolicy]] = [:]
        for (domain, fields) in sites {
            guard valid(domain), Set(fields.keys).isSubset(of: allowed),
                  fields["url"] == "https://\(domain)" || fields["url"] == "https://\(domain)/" else { throw invalid }
            var policies: [String: TelemetryPolicy] = [:]
            for service in ["ga4", "sentry"] {
                if let status = fields[service] {
                    guard ["accepted", "observed", "tag-detected", "source-detected", "unverified"].contains(status) else { throw invalid }
                }
                let expectation = fields[service + "-expectation"] ?? "required"
                let path = fields[service + "-verification-path"] ?? "/"
                let reason = fields[service + "-exception-reason"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let value = TelemetryPolicy.Expectation(rawValue: expectation), validPath(path),
                      value == .required ? reason == nil : reason.map({ (1...240).contains($0.count) }) == true else { throw invalid }
                policies[service] = TelemetryPolicy(expectation: value, path: path, exceptionReason: reason)
            }
            if let date = fields["checked-on"], !CheckSupport.matches(date, #"^\d{4}-\d{2}-\d{2}$"#) { throw invalid }
            if let state = fields["availability"], !["reachable", "unavailable", "unverified"].contains(state) { throw invalid }
            if let redirect = fields["redirect-to"] {
                guard sites.keys.contains(where: { $0 != domain && (redirect == "https://\($0)" || redirect == "https://\($0)/") }) else { throw invalid }
            }
            result[domain] = policies
        }
        return result
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
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy(validLabel)
    }

    static func validVercelAlias(_ host: String) -> Bool {
        let suffix = ".vercel.app"
        return host.hasSuffix(suffix) && validLabel(host.dropLast(suffix.count))
    }

    /// Used only for verified hostnames assigned to a matched Vercel project.
    static func validProductionHost(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard host.count <= 253, labels.count >= 2, let suffix = labels.last,
              CheckSupport.matches(String(suffix), #"^(?:[a-z]{2,63}|xn--[a-z0-9-]{2,59})\z"#),
              !["local", "internal", "localhost", "test", "example", "invalid", "onion", "arpa"].contains(suffix) else { return false }
        return labels.allSatisfy(validLabel)
    }

    private static func validLabel(_ label: Substring) -> Bool {
        CheckSupport.matches(String(label), #"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z"#)
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
    var finalHost: String?
    var hasSitemapXML: Bool?
    var sitemapURL: String?

    var isPubliclyReachable: Bool {
        transportFailure == nil && status.map { (200..<300).contains($0) } == true
    }
}

public enum RepositoryWebsiteChecks {
    typealias Loader = @Sendable (String, String, Set<String>) async -> WebsiteProbe

    public static func checks() -> [RepositoryCheck] {
        checks(load: nil, inventory: nil, searchConsole: { try await SearchConsoleSitemapInventory.read() })
    }

    static func checks(load: Loader?, inventory: WebsiteInventoryLoader?,
                       visibility: RepositoryMetadataChecks.VisibilityLoader? = nil,
                       searchConsole: SearchConsoleSitemapInventory.Reader? = nil) -> [RepositoryCheck] {
        var definitions = [
            ("website.domains", "Production website coverage", "globe"),
            ("website.sentry", "Sentry reporting", "exclamationmark.bubble"),
            ("website.analytics", "Google Analytics collection", "chart.bar"),
            ("website.sitemap", "Production XML sitemap", "map"),
            ("website.lighthouseCI", "Lighthouse CI coverage", "gauge")
        ]
        if searchConsole != nil {
            definitions.append(("website.sitemapSubmission", "Search Console sitemap submission", "magnifyingglass"))
        }
        return definitions.map { id, title, symbol in
            RepositoryCheck(id: id, title: title, category: .setup, symbol: symbol, validityPeriod: 300, evaluate: { context in
                let websiteInventory = try WebsiteDomains.inventory(context)
                let declared = websiteInventory.keys.sorted()
                let resolution = try await context.websites.domains(context, declared: declared, loader: inventory)
                if resolution.cached { context.markCached(id) }
                let submission = id == "website.sitemapSubmission"
                let sitemap = id == "website.sitemap" || submission
                let lighthouse = id == "website.lighthouseCI"
                let domains = sitemap || lighthouse ? resolution.domains.filter(WebsiteDomains.valid) : resolution.domains
                guard !domains.isEmpty || resolution.reason != nil else {
                    return .notApplicable("No supported production domains found for this repository in accessible Vercel teams or root metadata.")
                }
                if lighthouse {
                    return try lighthouseCoverage(context, domains: domains, inventoryReason: resolution.reason, id: id, symbol: symbol)
                }
                if sitemap && !domains.isEmpty {
                    guard let repository = GitHubCI.repository(context.snapshot.remoteURL) else {
                        return .unavailable("A GitHub remote is required to verify public repository visibility.")
                    }
                    let repositoryVisibility: GitHubRepositoryVisibility
                    do {
                        if let visibility {
                            repositoryVisibility = try await visibility(repository)
                        } else {
                            let result = try await RepositoryVisibilityCache.shared.load(repository, allowCached: context.allowCachedRemoteMetadata)
                            repositoryVisibility = result.visibility
                            if result.cached { context.markCached(id) }
                        }
                    } catch {
                        return .unavailable("Public GitHub repository visibility could not be verified. Check repository access and gh authentication.")
                    }
                    guard repositoryVisibility == .public else {
                        return .notApplicable("The GitHub repository is not public.")
                    }
                }
                var policy = try RepositoryCheckPolicy.load(context)
                var findings: [RepositoryFinding] = [], incomplete = resolution.reason.map { [$0] } ?? []
                if id == "website.domains" {
                    for domain in domains where WebsiteDomains.valid(domain) && !declared.contains(domain) {
                        findings.append(CheckSupport.finding(context, id, domain, "Production domain missing from metadata",
                            "\(domain): Vercel assigns this production domain to this repository, but the repository website inventory does not declare it. Add it to .repoman.json. Telemetry checks include it automatically.", .setup, symbol))
                    }
                    let aliases = Set(resolution.projectsWithoutDomain.flatMap(\.productionAliases))
                    let paths = Dictionary(uniqueKeysWithValues: aliases.map { ($0, "/") })
                    let probes = await context.websites.loadAll(paths, domains: Set(domains), allowCached: context.allowCachedWebsiteChecks, loader: load)
                    for project in resolution.projectsWithoutDomain {
                        let results = project.productionAliases.compactMap { alias in probes[alias].map { (alias, $0) } }
                        if results.contains(where: { $0.1.cached }) { context.markCached(id) }
                        if let (host, _) = results.first(where: { alias, probe in
                            probe.value.isPubliclyReachable && project.productionAliases.contains(probe.value.finalHost ?? alias)
                        }) {
                            findings.append(CheckSupport.finding(context, id, project.id, "Public Vercel project missing a tsilva.eu domain",
                                "\(host) serves public production traffic. Assign a production tsilva.eu domain to this Vercel project.", .setup, symbol))
                        } else {
                            incomplete.append("\(project.productionAliases.joined(separator: ", ")): Public production access could not be verified.")
                        }
                    }
                    findings = context.applyingExceptions(findings, policy: policy)
                } else {
                    let service = id == "website.sentry" ? "sentry" : "ga4"
                    var paths: [String: String] = [:]
                    for domain in domains {
                        if policy.exceptions[id]?[domain] != nil { continue }
                        if sitemap {
                            paths[domain] = "/sitemap.xml"
                            continue
                        }
                        let telemetry = websiteInventory[domain]?[service] ?? WebsiteDomains.TelemetryPolicy()
                        if let reason = telemetry.exceptionReason {
                            policy.exceptions[id, default: [:]][domain] = "\(telemetry.expectation.rawValue.capitalized): \(reason)"
                        } else {
                            paths[domain] = telemetry.path
                        }
                    }
                    let probes = await context.websites.loadAll(paths, domains: Set(domains), allowCached: context.allowCachedWebsiteChecks, sitemap: sitemap, loader: load)
                    var verifiedSitemaps: [String: String] = [:]
                    for domain in paths.keys.sorted() {
                        let target = domain + (paths[domain] ?? "/")
                        guard let probe = probes[domain] else { incomplete.append("\(domain): No probe result."); continue }
                        if probe.cached { context.markCached(id) }
                        switch classify(probe.value, checkID: sitemap ? "website.sitemap" : id) {
                        case .pass:
                            if submission {
                                guard let url = probe.value.sitemapURL else {
                                    incomplete.append("\(target): The final sitemap URL could not be verified.")
                                    continue
                                }
                                if verifiedSitemaps[url] == nil { verifiedSitemaps[url] = domain }
                            }
                        case .issue(let reason):
                            if submission {
                                incomplete.append("\(target): A live XML sitemap could not be verified.")
                            } else {
                                findings.append(CheckSupport.finding(context, id, domain, title, "\(target): \(reason)", .setup, symbol))
                            }
                        case .deliveryUnverified(let reason), .unknown(let reason):
                            incomplete.append("\(target): \(reason)")
                        }
                    }
                    if submission, let searchConsole, !verifiedSitemaps.isEmpty {
                        do {
                            let submitted = try await context.searchConsole.load(searchConsole)
                            for url in verifiedSitemaps.keys.sorted() where !submitted.contains(url) {
                                guard let domain = verifiedSitemaps[url] else { continue }
                                findings.append(CheckSupport.finding(context, id, domain, "Sitemap missing from Search Console",
                                    "\(url) was not submitted under sc-domain:tsilva.eu.", .setup, symbol))
                            }
                        } catch {
                            let failure = error as? SearchConsoleSitemapInventory.ReadError ?? .requestFailed
                            incomplete.append(failure.localizedDescription)
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

    private static func lighthouseCoverage(_ context: RepositoryInspectionContext, domains: [String],
                                           inventoryReason: String?, id: String, symbol: String) throws -> RepositoryCheckResult {
        let policy = try RepositoryCheckPolicy.load(context)
        let candidates = domains.map { domain in
            CheckSupport.finding(context, id, domain, "Lighthouse CI is missing",
                "\(domain): Add a Lighthouse CI job for this site under .github/workflows/.", .setup, symbol)
        }
        let required = context.applyingExceptions(candidates, policy: policy)
        var incomplete = inventoryReason.map { [$0] } ?? []
        guard !required.isEmpty else {
            return incomplete.isEmpty ? .findings([]) : .partial([], incomplete.joined(separator: "\n"))
        }
        guard GitHubCI.repository(context.snapshot.remoteURL) != nil else {
            incomplete.append("A GitHub remote is required to check Lighthouse CI coverage.")
            return .partial([], incomplete.joined(separator: "\n"))
        }

        var uncovered = required
        var uncertain = false
        for path in try CheckSupport.workflowPaths(context) {
            do {
                let evidence = try WorkflowInspection.lighthouseEvidence(context.workflowLines(path))
                uncertain = uncertain || evidence.unresolvedTarget || (evidence.localBuild && domains.count > 1)
                uncovered.removeAll { evidence.hosts.contains($0.subject) || (evidence.localBuild && domains.count == 1) }
                if uncovered.isEmpty { break }
            } catch {
                uncertain = true
            }
        }
        if uncertain && !uncovered.isEmpty {
            incomplete.append("Lighthouse CI coverage could not be determined for \(uncovered.map(\.subject).joined(separator: ", ")). Review unsupported workflow syntax or audit targets that could not be mapped to a site.")
            uncovered.removeAll()
        }
        return incomplete.isEmpty ? .findings(uncovered) : .partial(uncovered, incomplete.joined(separator: "\n"))
    }

    enum Verdict: Equatable { case pass, issue(String), deliveryUnverified(String), unknown(String) }
    static func classify(_ probe: WebsiteProbe, checkID: String) -> Verdict {
        if let reason = probe.transportFailure {
            return .unknown("Website could not be reached; \(reason)")
        }
        guard let status = probe.status else { return .unknown("No HTTPS response was available.") }
        if checkID == "website.sitemap" {
            if status == 404 || status == 410 {
                return .issue("Publish an XML sitemap at /sitemap.xml (HTTP \(status)).")
            }
            if status == 200 {
                guard let hasSitemapXML = probe.hasSitemapXML else {
                    return .unknown("The sitemap response exceeded the inspection limit.")
                }
                return hasSitemapXML ? .pass : .issue("Serve an XML sitemap or sitemap index at /sitemap.xml.")
            }
        }
        guard checkID != "website.sitemap", (200..<300).contains(status) else {
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
    func loadAll(_ paths: [String: String], domains: Set<String>, allowCached: Bool, sitemap: Bool = false,
                 loader: RepositoryWebsiteChecks.Loader?) async -> [String: WebsiteProbeResult] {
        // Each repository has at most four probes in flight. The global limiter
        // also bounds probes across simultaneous repository inspections.
        await withTaskGroup(of: (String, WebsiteProbeResult).self) { group in
            var pending = paths.keys.sorted().makeIterator(), result: [String: WebsiteProbeResult] = [:]
            func enqueue(_ domain: String) {
                let path = paths[domain] ?? "/"
                group.addTask { (domain, await self.load(domain, path: path, domains: domains, allowCached: allowCached, sitemap: sitemap, loader: loader)) }
            }
            for _ in 0..<4 { if let domain = pending.next() { enqueue(domain) } }
            for await (domain, probe) in group {
                result[domain] = probe
                if let next = pending.next() { enqueue(next) }
            }
            return result
        }
    }
    private func load(_ domain: String, path: String, domains: Set<String>, allowCached: Bool, sitemap: Bool,
                      loader: RepositoryWebsiteChecks.Loader?) async -> WebsiteProbeResult {
        let target = (sitemap ? "sitemap:" : "") + domain + path
        if let task = tasks[target] { return await task.value }
        let task = Task {
            if let loader {
                await WebsiteProbeLimiter.shared.acquire()
                let probe = await loader(domain, path, domains)
                await WebsiteProbeLimiter.shared.release()
                return WebsiteProbeResult(value: probe)
            }
            return await WebsiteProbeCache.shared.load(domain, path: path, domains: domains, allowCached: allowCached, sitemap: sitemap)
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
              sitemap: Bool = false, loader: RepositoryWebsiteChecks.Loader? = nil) async -> WebsiteProbeResult {
        let key = ([(sitemap ? "sitemap:" : "") + domain + path] + domains.sorted()).joined(separator: "\n")
        if allowCached, let (date, probe) = values[key], (0..<300).contains(now.timeIntervalSince(date)) {
            return WebsiteProbeResult(value: probe, cached: true)
        }
        if let task = tasks[key] { return WebsiteProbeResult(value: await task.value) }
        let task = Task {
            await WebsiteProbeLimiter.shared.acquire()
            let probe: WebsiteProbe
            if let loader { probe = await loader(domain, path, domains) }
            else { probe = await WebsiteLiveProbe.load(domain, path: path, domains: domains, sitemap: sitemap) }
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

/// A bounded HTTPS read. Telemetry probes visit successful HTML responses in an isolated browser.
enum WebsiteLiveProbe {
    private static let byteLimit = 2_097_152

    static func load(_ domain: String, path: String, domains: Set<String>, sitemap: Bool = false) async -> WebsiteProbe {
        guard WebsiteDomains.validProductionHost(domain),
              WebsiteDomains.validPath(path), domains.contains(domain),
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
            let redirect = redirects.evidence
            var result = WebsiteProbe(status: response.statusCode, isHTML: response.mimeType?.lowercased() == "text/html",
                                      finalHost: response.url?.host?.lowercased())
            if redirect.blocked { result.transportFailure = "The site redirects outside the declared HTTPS domains, or exceeds five redirects."; return result }
            if sitemap {
                guard response.statusCode == 200 else { return result }
                var body = Data()
                for try await byte in bytes {
                    guard body.count < byteLimit else { return result }
                    body.append(byte)
                }
                result.hasSitemapXML = SitemapDocument.matches(body)
                if let final = response.url, WebsiteDomains.permits(final, domains: domains),
                   let components = URLComponents(url: final, resolvingAgainstBaseURL: false),
                   components.percentEncodedQuery == nil, components.fragment == nil,
                   WebsiteDomains.validPath(components.percentEncodedPath) {
                    result.sitemapURL = final.absoluteString
                }
                return result
            }
            guard (200..<300).contains(response.statusCode), result.isHTML else { return result }
            var count = 0
            for try await _ in bytes {
                count += 1
                if count > byteLimit {
                    result.browserFailure = "Website response exceeded the inspection limit."
                    return result
                }
            }
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

final class SitemapDocument: NSObject, XMLParserDelegate {
    private var isSitemap: Bool?

    static func matches(_ data: Data) -> Bool {
        let document = SitemapDocument()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = document
        return parser.parse() && document.isSitemap == true
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        guard isSitemap == nil else { return }
        isSitemap = namespaceURI == "http://www.sitemaps.org/schemas/sitemap/0.9"
            && (elementName == "urlset" || elementName == "sitemapindex")
        if isSitemap == false { parser.abortParsing() }
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
