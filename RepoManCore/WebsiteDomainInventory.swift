import Foundation

typealias WebsiteInventoryLoader = @Sendable () async throws -> [WebsiteProject]

struct WebsiteProject: Sendable {
    let id: String
    let repository: String?
    let domains: [String]
}

struct WebsiteDomainResolution: Sendable {
    let domains: [String]
    let reason: String?
    var cached = false

    static func load(_ context: RepositoryInspectionContext, declared: [String], loader: WebsiteInventoryLoader?) async throws -> Self {
        let github = GitHubCI.repository(context.snapshot.remoteURL).map { ($0.owner + "/" + $0.name).lowercased() }
        var linkedID: String?
        if try context.exists(".vercel/project.json") {
            let link = try context.jsonObject(".vercel/project.json")
            guard let id = link["projectId"] as? String, WebsiteDomainInventory.identifier(id) else {
                throw InspectionError.blocked("Invalid Vercel project link; production domain coverage is unknown.")
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
            let domains = Set(declared).union(matched.flatMap(\.domains)).sorted()
            guard domains.count <= 32 else { throw InspectionError.blocked("More than 32 production domains mapped to this repository.") }
            return Self(domains: domains, reason: nil, cached: cached)
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
                var domains: Set<String> = []
                for domain in assigned {
                    guard let name = domain["name"] as? String else { throw InspectionError.blocked("Invalid Vercel domain response.") }
                    let host = name.lowercased()
                    guard host == "tsilva.eu" || host.hasSuffix(".tsilva.eu") else { continue }
                    guard WebsiteDomains.valid(host) else { throw InspectionError.blocked("Invalid production domain hostname.") }
                    // Branch and custom-environment domains are outside Production.
                    if let branch = domain["gitBranch"], !(branch is NSNull) { continue }
                    if let environment = domain["customEnvironmentId"], !(environment is NSNull) { continue }
                    domains.insert(host)
                }
                result.append(WebsiteProject(id: id, repository: repository, domains: domains.sorted()))
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
