import Foundation

/// Owned by one refresh so successful and failed reads are both shared by all repositories.
public actor SearchConsoleSitemapInventory {
    typealias Reader = @Sendable () async throws -> Set<String>
    private var task: Task<Set<String>, Error>?

    public init() {}

    func load(_ reader: @escaping Reader) async throws -> Set<String> {
        if let task { return try await task.value }
        let task = Task { try await reader() }
        self.task = task
        return try await task.value
    }

    static let endpoint = "https://www.googleapis.com/webmasters/v3/sites/sc-domain%3Atsilva.eu/sitemaps"

    static func read() async throws -> Set<String> {
        let path = ProcessInfo.processInfo.environment["REPOMAN_SEARCH_CONSOLE_READER"]
            ?? UserDefaults.standard.string(forKey: "searchConsoleReaderPath")
        guard let path, path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path),
              (try? URL(fileURLWithPath: path).resolvingSymlinksInPath()
                .resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw ReadError.readerUnavailable
        }
        let response: Data
        do {
            response = try await Task.detached(priority: .utility) {
                try GitHubCLI.run([endpoint], executable: URL(fileURLWithPath: path), timeout: 15)
            }.value
        } catch {
            throw ReadError.requestFailed
        }
        return try decode(response)
    }

    static func decode(_ data: Data) throws -> Set<String> {
        guard let response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let status = response["status"] as? Int else { throw ReadError.invalidResponse }
        guard status == 200 else { throw ReadError.requestFailed }
        guard let body = response["body"] as? [String: Any], body.keys.allSatisfy({ $0 == "sitemap" }) else {
            throw ReadError.invalidResponse
        }
        guard let entries = body["sitemap"] else { return [] }
        guard let sitemaps = entries as? [[String: Any]] else { throw ReadError.invalidResponse }
        return try Set(sitemaps.map { sitemap in
            guard let path = sitemap["path"] as? String,
                  let url = URLComponents(string: path), ["http", "https"].contains(url.scheme ?? ""),
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
                throw ReadError.invalidResponse
            }
            return path
        })
    }

    enum ReadError: LocalizedError {
        case readerUnavailable, requestFailed, invalidResponse

        var errorDescription: String? {
            switch self {
            case .readerUnavailable: "Search Console access is unverified. Configure an approved read-only Search Console reader."
            case .requestFailed: "Search Console could not list sitemaps for sc-domain:tsilva.eu. Check reader authentication, property access, and connectivity."
            case .invalidResponse: "Search Console returned an invalid sitemap inventory. Submission could not be verified."
            }
        }
    }
}

typealias WebsiteInventoryLoader = @Sendable () async throws -> [WebsiteProject]

struct WebsiteProject: Sendable {
    let id: String
    let repository: String?
    let domains: [String]
    var productionAliases: [String] = []
}

struct WebsiteDomainResolution: Sendable {
    let domains: [String]
    let reason: String?
    var cached = false
    var projectsWithoutDomain: [WebsiteProject] = []

    static func load(_ context: RepositoryInspectionContext, declared: [String], loader: WebsiteInventoryLoader?) async throws -> Self {
        let github = GitHubCI.repository(context.snapshot.remoteURL).map { ($0.owner + "/" + $0.name).lowercased() }
        let manifestID = try WebsiteDomains.projectID(context)
        var linkedID = manifestID
        if try context.exists(".vercel/project.json") {
            let link = try context.jsonObject(".vercel/project.json")
            guard let id = link["projectId"] as? String, WebsiteDomainInventory.identifier(id) else {
                throw InspectionError.blocked("Invalid Vercel project link; production domain coverage is unknown.")
            }
            guard manifestID == nil || manifestID == id else {
                throw InspectionError.blocked("RepoMan and the local Vercel link name different projects.")
            }
            linkedID = id
        }
        guard github != nil || linkedID != nil else {
            return Self(domains: declared, reason: declared.isEmpty ? nil : "No supported GitHub remote or Vercel project link; additional production domains could not be discovered.")
        }
        do {
            let projects: [WebsiteProject], cached: Bool
            if let loader { projects = try await loader(); cached = false }
            else {
                let value = try await WebsiteInventoryCache.shared.load()
                projects = value.projects; cached = value.cached
            }
            // The remote is authoritative for Git-backed projects. A stale local
            // project link cannot bind another repository's domains to this one.
            let matched = projects.filter {
                if let repository = $0.repository { return repository == github }
                return linkedID != nil && $0.id == linkedID
            }
            let missingDomain = matched.filter { $0.domains.isEmpty && !$0.productionAliases.isEmpty }
            let domains = Set(declared).union(matched.flatMap(\.domains))
                .union(missingDomain.flatMap(\.productionAliases)).sorted()
            guard domains.count <= 32 else { throw InspectionError.blocked("More than 32 production domains mapped to this repository.") }
            let reason = linkedID != nil && !matched.contains(where: { $0.id == linkedID })
                ? "The configured Vercel project was not matched in the accessible production inventory."
                : nil
            return Self(domains: domains, reason: reason, cached: cached, projectsWithoutDomain: missingDomain)
        } catch {
            return Self(domains: declared, reason: "Vercel production-domain inventory is unavailable. Install the Vercel CLI, sign in, and check access to all intended teams. Declared domains are still inspected; full coverage remains unverified.")
        }
    }
}

/// One bounded, read-only account inventory shared across the repository scan.
/// Explicit dashboard refreshes invalidate it; fresh CLI processes have no cache.
actor WebsiteInventoryCache {
    static let shared = WebsiteInventoryCache()
    private var task: Task<[WebsiteProject], Error>?
    private var startedAt: Date?

    func invalidate() { task = nil; startedAt = nil }

    func load(now: Date = Date(), loader: @escaping WebsiteInventoryLoader = { try WebsiteDomainInventory.load() }) async throws -> (projects: [WebsiteProject], cached: Bool) {
        if let task, let startedAt, (0..<300).contains(now.timeIntervalSince(startedAt)) {
            return (try await task.value, true)
        }
        let fresh = Task.detached(priority: .utility) { try await loader() }
        task = fresh; startedAt = now
        return (try await fresh.value, false)
    }
}

enum WebsiteDomainInventory {
    typealias Command = ([String]) throws -> Data

    static func identifier(_ value: String) -> Bool {
        CheckSupport.matches(value, #"^[A-Za-z0-9_-]{1,128}$"#)
    }

    static func load(command: Command = { try run($0) }) throws -> [WebsiteProject] {
        let deadline = Date().addingTimeInterval(120)
        var requests = 0
        func request(_ arguments: [String]) throws -> [String: Any] {
            requests += 1
            guard requests <= 256, Date() < deadline else {
                throw InspectionError.blocked("Vercel inventory exceeded its inspection budget.")
            }
            guard let object = try JSONSerialization.jsonObject(with: command(arguments)) as? [String: Any], object["error"] == nil else {
                throw InspectionError.blocked("Invalid Vercel inventory response.")
            }
            return object
        }
        func pages(_ endpoint: String, key: String, scope: String? = nil) throws -> [[String: Any]] {
            var cursor: String?, seen: Set<String> = [], all: [[String: Any]] = []
            let cursorKey = key == "projects" ? "from" : "until"
            for _ in 0..<32 {
                let path = endpoint + (endpoint.contains("?") ? "&" : "?") + "limit=100" + (cursor.map { "&" + cursorKey + "=" + $0 } ?? "")
                let arguments = ["api", path, "--raw"] + (scope.map { ["--scope", $0] } ?? [])
                let object = try request(arguments)
                guard let items = object[key] as? [[String: Any]] else { throw InspectionError.blocked("Incomplete Vercel inventory response.") }
                all += items
                guard all.count <= 4096 else { throw InspectionError.blocked("Vercel inventory is too large.") }
                guard let pagination = object["pagination"] as? [String: Any], let next = pagination["next"] else {
                    throw InspectionError.blocked("Vercel pagination is missing or invalid.")
                }
                if next is NSNull { return all }
                let text = String(describing: next)
                guard CheckSupport.matches(text, #"^[0-9]{1,20}$"#), seen.insert(text).inserted else {
                    throw InspectionError.blocked("Invalid or repeated Vercel pagination cursor.")
                }
                cursor = text
            }
            throw InspectionError.blocked("Vercel pagination limit reached.")
        }
        let teams = try pages("/v2/teams", key: "teams")
        guard !teams.isEmpty, teams.count <= 16 else { throw InspectionError.blocked("No accessible Vercel teams or team limit reached.") }
        var result: [WebsiteProject] = [], seen: Set<String> = []
        for team in teams {
            guard let scope = team["slug"] as? String, identifier(scope) else { throw InspectionError.blocked("Invalid Vercel team identity.") }
            for project in try pages("/v9/projects", key: "projects", scope: scope) {
                guard let id = project["id"] as? String, identifier(id), seen.insert(id).inserted else {
                    throw InspectionError.blocked("Invalid or duplicate Vercel project identity.")
                }
                var repository: String?
                if let link = project["link"], !(link is NSNull) {
                    guard let link = link as? [String: Any], let type = link["type"] as? String else { throw InspectionError.blocked("Invalid Vercel repository link.") }
                    if type == "github" {
                        guard let owner = link["org"] as? String, let name = link["repo"] as? String,
                              let parsed = GitHubCI.repository("https://github.com/" + owner + "/" + name) else {
                            throw InspectionError.blocked("Invalid GitHub project binding.")
                        }
                        repository = (parsed.owner + "/" + parsed.name).lowercased()
                    } else { repository = "unsupported-provider" }
                }
                let assigned = try pages("/v9/projects/" + id + "/domains?production=true", key: "domains", scope: scope)
                var domains: Set<String> = [], productionAliases: Set<String> = []
                for domain in assigned {
                    guard let name = domain["name"] as? String else { throw InspectionError.blocked("Invalid Vercel domain response.") }
                    let host = name.lowercased()
                    // Branch and custom-environment domains are outside Production.
                    if let branch = domain["gitBranch"], !(branch is NSNull) { continue }
                    if let environment = domain["customEnvironmentId"], !(environment is NSNull) { continue }
                    if domain["verified"] as? Bool == false { continue }
                    if WebsiteDomains.valid(host) {
                        domains.insert(host)
                    } else if WebsiteDomains.validVercelAlias(host) ||
                                (domain["verified"] as? Bool == true && WebsiteDomains.validProductionHost(host)) {
                        productionAliases.insert(host)
                    } else if host == "tsilva.eu" || host.hasSuffix(".tsilva.eu") || host.hasSuffix(".vercel.app") {
                        throw InspectionError.blocked("Invalid production domain hostname.")
                    }
                }
                result.append(WebsiteProject(id: id, repository: repository, domains: domains.sorted(),
                                             productionAliases: productionAliases.sorted()))
            }
        }
        return result
    }

    private static func run(_ arguments: [String]) throws -> Data {
        let directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let paths = directories.map { $0 + "/vercel" } + ["/opt/homebrew/bin/vercel", "/usr/local/bin/vercel"]
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw InspectionError.blocked("Vercel CLI is unavailable.")
        }
        // Reuse the existing bounded subprocess runner, never its provider diagnostics.
        // Native CLI authentication is retained; tokens and env values are never read.
        do { return try GitHubCLI.run(arguments + ["--non-interactive"], executable: URL(fileURLWithPath: path), timeout: 15) }
        catch { throw InspectionError.blocked("Vercel inventory failed; check CLI authentication and team access.") }
    }
}
