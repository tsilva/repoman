import Foundation

struct GitHubRepositoryCounts: Codable, Equatable, Sendable {
    let stars: Int
    let forks: Int
}

struct GitHubRepositoryCountsEntry: Codable, Sendable {
    let counts: GitHubRepositoryCounts
    let fetchedAt: Date

    func isFresh(at date: Date) -> Bool {
        let age = date.timeIntervalSince(fetchedAt)
        return age >= 0 && age < 3600
    }
}

enum GitHubRepositoryCountsQuery {
    static let batchSize = 50

    static func key(for remote: String?) -> String? {
        GitHubCI.repository(remote).map { "\($0.owner)/\($0.name)".lowercased() }
    }

    // Each alias resolves independently: an inaccessible repository should not
    // prevent its neighbors in the batch from updating.
    static func load(_ keys: [String], executable: URL? = nil) throws -> [String: GitHubRepositoryCounts] {
        precondition(!keys.isEmpty && keys.count <= batchSize)
        var variables: [String] = []
        var fields: [String] = []
        var arguments: [String] = []
        for (index, key) in keys.enumerated() {
            let parts = key.split(separator: "/", maxSplits: 1)
            variables += ["$owner\(index): String!", "$name\(index): String!"]
            fields.append("r\(index): repository(owner: $owner\(index), name: $name\(index)) { stargazerCount forkCount }")
            arguments += ["-f", "owner\(index)=\(parts[0])", "-f", "name\(index)=\(parts[1])"]
        }
        let query = "query(\(variables.joined(separator: ", "))) { \(fields.joined(separator: " ")) }"
        let data = try GitHubCLI.run(["api", "graphql", "--hostname", "github.com", "-f", "query=" + query] + arguments,
                                     executable: executable, allowPartialOutput: true)
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let results = response.data else {
            throw InspectionError.blocked("GitHub did not return repository counts.")
        }
        var counts: [String: GitHubRepositoryCounts] = [:]
        for (index, key) in keys.enumerated() {
            if let result = results["r\(index)"] ?? nil {
                counts[key] = GitHubRepositoryCounts(stars: result.stargazerCount, forks: result.forkCount)
            }
        }
        return counts
    }

    private struct Response: Decodable {
        // GraphQL returns null aliases for repositories it could not resolve.
        let data: [String: Counts?]?
    }

    private struct Counts: Decodable {
        let stargazerCount: Int
        let forkCount: Int
    }
}
