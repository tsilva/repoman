import Foundation

struct PublishedRepositoryMetadata: Sendable {
    let description: String?
    let branch: String
    let sha: String
    let readme: String?
}

enum RepositoryMetadataChecks {
    typealias Loader = @Sendable (RepositorySnapshot) async throws -> PublishedRepositoryMetadata
    typealias VisibilityLoader = @Sendable (RepositorySnapshot) async throws -> GitHubRepositoryVisibility
    static func checks(load: Loader? = nil, loadVisibility: VisibilityLoader? = nil) -> [RepositoryCheck] {
        [CheckSupport.check("github.description", "GitHub description drift", .documentation, "text.bubble", inspect: { context, _ in
            guard let repository = GitHubCI.repository(context.snapshot.remoteURL) else { return [] }
            let metadata: PublishedRepositoryMetadata
            if let load { metadata = try await load(context.snapshot) }
            else {
                let result = try await PublishedMetadataCache.shared.load(context.snapshot, allowCached: context.allowCachedRemoteMetadata)
                metadata = result.metadata
                if result.cached { context.markCached("github.description") }
            }
            guard let readme = metadata.readme, let tagline = try GitHubTagline.tagline(readme) else { return [] }
            guard (metadata.description ?? "") != tagline else { return [] }
            return [CheckSupport.finding(context, "github.description", repository.owner + "/" + repository.name,
                "GitHub description drift", "Published README on \(metadata.branch) at \(metadata.sha.prefix(8)) declares: \(tagline)\nGitHub description: \(metadata.description ?? "(empty)"). Local and feature-branch README changes are not used.", .documentation, "text.bubble")]
        }), CheckSupport.check("github.privateVisibility", "Private repository visibility", .setup, "lock.shield", inspect: { context, _ in
            guard let repository = GitHubCI.repository(context.snapshot.remoteURL),
                  repository.name.lowercased().hasPrefix("private-") else { return [] }
            let visibility: GitHubRepositoryVisibility
            if let loadVisibility { visibility = try await loadVisibility(context.snapshot) }
            else {
                let result = try await RepositoryVisibilityCache.shared.load(context.snapshot, allowCached: context.allowCachedRemoteMetadata)
                visibility = result.visibility
                if result.cached { context.markCached("github.privateVisibility") }
            }
            guard visibility != .private else { return [] }
            let subject = repository.owner + "/" + repository.name
            return [CheckSupport.finding(context, "github.privateVisibility", subject,
                "Private-named repository is not private", "\(subject) starts with private- but its GitHub visibility is \(visibility.rawValue.lowercased()). Repositories with this prefix must be private.", .setup, "lock.shield", severity: .blocked)]
        })]
    }
}

enum GitHubRepositoryVisibility: String, Decodable, Sendable {
    case `private` = "PRIVATE", `public` = "PUBLIC", `internal` = "INTERNAL"

    static let query = """
    query($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) { visibility }
    }
    """
    static func load(_ snapshot: RepositorySnapshot, run: ([String]) throws -> Data = { try GitHubCLI.run($0) }) throws -> Self {
        guard let repository = GitHubCI.repository(snapshot.remoteURL) else { throw RepairError.blocked("A GitHub remote is required.") }
        return try decode(run(["api", "graphql", "--hostname", "github.com", "--raw-field", "query=" + query,
            "--raw-field", "owner=" + repository.owner, "--raw-field", "name=" + repository.name]))
    }
    static func decode(_ data: Data) throws -> Self {
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.errors?.isEmpty ?? true else {
            throw RepairError.blocked("GitHub visibility inspection failed: " + response.errors!.map(\.message).joined(separator: "; "))
        }
        guard let visibility = response.data?.repository?.visibility else {
            throw RepairError.blocked("GitHub repository visibility is unavailable. Check repository access and gh authentication.")
        }
        return visibility
    }
    private struct Response: Decodable { let data: Payload?; let errors: [APIError]? }
    private struct APIError: Decodable { let message: String }
    private struct Payload: Decodable { let repository: Repository? }
    private struct Repository: Decodable { let visibility: GitHubRepositoryVisibility? }
}

/// Visibility does not depend on a README or a published default branch (empty repositories are checked too).
actor RepositoryVisibilityCache {
    static let shared = RepositoryVisibilityCache()
    private var values: [String: (date: Date, visibility: GitHubRepositoryVisibility)] = [:]
    func load(_ snapshot: RepositorySnapshot, allowCached: Bool, now: Date = Date(),
              loader: RepositoryMetadataChecks.VisibilityLoader = { snapshot in
                  try await Task.detached(priority: .utility) { try GitHubRepositoryVisibility.load(snapshot) }.value
              }) async throws -> (visibility: GitHubRepositoryVisibility, cached: Bool) {
        guard let repository = GitHubCI.repository(snapshot.remoteURL) else { throw RepairError.blocked("A GitHub remote is required.") }
        let key = repository.owner + "/" + repository.name
        if allowCached, let value = values[key], (0..<600).contains(now.timeIntervalSince(value.date)) { return (value.visibility, true) }
        let visibility = try await loader(snapshot)
        if values.count >= 500, values[key] == nil, let oldest = values.min(by: { $0.value.date < $1.value.date })?.key { values.removeValue(forKey: oldest) }
        values[key] = (now, visibility)
        return (visibility, false)
    }
}

/// Background refresh may reuse metadata for ten minutes; repair preflight and verification always bypass it.
actor PublishedMetadataCache {
    static let shared = PublishedMetadataCache()
    private var values: [String: (date: Date, metadata: PublishedRepositoryMetadata)] = [:]
    func load(_ snapshot: RepositorySnapshot, allowCached: Bool, now: Date = Date(),
              loader: RepositoryMetadataChecks.Loader = { snapshot in
                  try await Task.detached(priority: .utility) { try GitHubTagline.load(snapshot) }.value
              }) async throws -> (metadata: PublishedRepositoryMetadata, cached: Bool) {
        guard let repository = GitHubCI.repository(snapshot.remoteURL) else { throw RepairError.blocked("A GitHub remote is required.") }
        let key = repository.owner + "/" + repository.name
        if allowCached, let value = values[key], (0..<600).contains(now.timeIntervalSince(value.date)) { return (value.metadata, true) }
        let metadata = try await loader(snapshot)
        if values.count >= 500, values[key] == nil, let oldest = values.min(by: { $0.value.date < $1.value.date })?.key { values.removeValue(forKey: oldest) }
        values[key] = (now, metadata)
        return (metadata, false)
    }
}

enum GitHubTagline {
    // Discover the published README path without requesting nonexistent files (GitHub treats those as errors).
    static let query = """
    query($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        description
        defaultBranchRef {
          name
          target { ... on Commit {
            oid
            tree { entries { name type } }
          } }
        }
      }
    }
    """
    static let readmeQuery = """
    query($owner: String!, $name: String!, $path: String!) {
      repository(owner: $owner, name: $name) {
        description
        defaultBranchRef {
          name
          target { ... on Commit {
            oid
            readme: file(path: $path) { object { ... on Blob { text byteSize isBinary } } }
          } }
        }
      }
    }
    """
    static func load(_ snapshot: RepositorySnapshot, run: ([String]) throws -> Data = { try GitHubCLI.run($0) }) throws -> PublishedRepositoryMetadata {
        guard let repository = GitHubCI.repository(snapshot.remoteURL) else { throw RepairError.blocked("A GitHub remote is required.") }
        let arguments = ["api", "graphql", "--hostname", "github.com", "--raw-field", "owner=" + repository.owner, "--raw-field", "name=" + repository.name]
        let discovery = try run(arguments + ["--raw-field", "query=" + query])
        let response = try JSONDecoder().decode(Response.self, from: discovery)
        let metadata = try decode(discovery)
        guard let entries = response.data?.repository?.defaultBranchRef?.target?.tree?.entries, entries.count <= 200 else {
            throw RepairError.blocked("Published README discovery is unavailable or exceeds 200 root entries.")
        }
        let names = entries.filter { $0.type == "blob" && RepositoryIssueCatalog.isReadme($0.name) }.map(\.name).sorted {
            if ($0 == "README.md") != ($1 == "README.md") { return $0 == "README.md" }
            return $0 < $1
        }
        guard let path = names.first else { return metadata }
        // This request reads description and README from the same latest default-branch commit.
        let latest = try decode(run(arguments + ["--raw-field", "query=" + readmeQuery, "--raw-field", "path=" + path]))
        guard latest.readme != nil else { throw RepairError.blocked("Published README changed or became unreadable during inspection.") }
        return latest
    }
    static func decode(_ data: Data) throws -> PublishedRepositoryMetadata {
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.errors?.isEmpty ?? true else { throw RepairError.blocked("GitHub metadata inspection failed: " + response.errors!.map(\.message).joined(separator: "; ")) }
        guard let repository = response.data?.repository, let branch = repository.defaultBranchRef,
              let target = branch.target, !target.oid.isEmpty else { throw RepairError.blocked("GitHub has no readable published default branch.") }
        let entries = [target.readme].compactMap { $0 }
        var readme: String?
        for entry in entries {
            guard let blob = entry.object, blob.isBinary == false, let size = blob.byteSize, size <= 1_048_576, let text = blob.text else {
                throw RepairError.blocked("Published README is binary, unreadable, or exceeds 1 MiB.")
            }
            if text.contains("repo-tagline:") { readme = text; break }
            if readme == nil { readme = text }
        }
        return PublishedRepositoryMetadata(description: repository.description, branch: branch.name, sha: target.oid, readme: readme)
    }
    static func tagline(_ readme: String) throws -> String? {
        let start = "<!-- repo-tagline:start -->", end = "<!-- repo-tagline:end -->"
        let fragments = CheckSupport.captures(readme, #"<!--\s*repo-tagline\b|repo-tagline\s*:\s*(?:start|end)\s*-->"#)
        guard !fragments.isEmpty else { return nil }
        guard readme.components(separatedBy: start).count == 2, readme.components(separatedBy: end).count == 2,
              fragments.count == 2, let a = readme.range(of: start), let b = readme.range(of: end), a.upperBound <= b.lowerBound else {
            throw RepairError.blocked("Published README has invalid or duplicate tagline markers.")
        }
        let prefix = String(readme[..<a.lowerBound])
        guard CheckSupport.matches(readme.trimmingCharacters(in: .whitespacesAndNewlines), #"^<p\s+align="center"\s*>"#),
              let headerEnd = readme.range(of: "</p>"), b.upperBound <= headerEnd.lowerBound,
              prefix.contains("<img "), !prefix.contains("```"), !prefix.contains("~~~") else {
            throw RepairError.blocked("Published tagline must follow the logo inside the opening centered header.")
        }
        let block = String(readme[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = CheckSupport.captures(block, #"^<strong>([^<>]*)</strong>$"#).first else {
            throw RepairError.blocked("Published tagline must contain one plain-text strong element.")
        }
        var text = match[1]
        let entities = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]
        let entityPattern = try NSRegularExpression(pattern: #"&(#x[0-9a-fA-F]+|#\d+|[a-z]+);"#)
        let entityMatches = entityPattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in entityMatches.reversed() {
            guard let keyRange = Range(match.range(at: 1), in: text), let range = Range(match.range, in: text) else {
                throw RepairError.blocked("Invalid entity range in published tagline.")
            }
            let key = String(text[keyRange])
            let replacement: String?
            if key.hasPrefix("#") {
                let number = key.hasPrefix("#x") ? UInt32(key.dropFirst(2), radix: 16) : UInt32(key.dropFirst())
                replacement = number.flatMap(UnicodeScalar.init).map(String.init)
            } else { replacement = entities[key] }
            guard let replacement else { throw RepairError.blocked("Unsupported HTML entity in published tagline.") }
            text.replaceSubrange(range, with: replacement)
        }
        text = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        guard !text.isEmpty, text.unicodeScalars.count <= 350, !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw RepairError.blocked("Published tagline is empty, contains controls, or exceeds GitHub's 350-character limit.")
        }
        return text
    }
    private struct Response: Decodable { let data: Payload?; let errors: [APIError]? }
    private struct APIError: Decodable { let message: String }
    private struct Payload: Decodable { let repository: Repository? }
    private struct Repository: Decodable { let description: String?; let defaultBranchRef: Branch? }
    private struct Branch: Decodable { let name: String; let target: Commit? }
    private struct Commit: Decodable { let oid: String; let readme: Entry?; let tree: Tree? }
    private struct Tree: Decodable { let entries: [TreeEntry] }
    private struct TreeEntry: Decodable { let name: String; let type: String }
    private struct Entry: Decodable { let object: Blob? }
    private struct Blob: Decodable { let text: String?; let byteSize: Int?; let isBinary: Bool? }
}
