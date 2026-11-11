import Foundation

public enum RepositoryFilter: String, CaseIterable, Sendable {
    case all = "All repositories"
    case needsAttention = "Needs attention"
    case toPush = "To push"
    case toPull = "To pull"
    case changedFiles = "Changed files"
    case staleBranches = "Stale branches"
    case worktrees = "Worktrees"

    public func matches(_ repository: RepositorySnapshot) -> Bool {
        switch self {
        case .all: return true
        case .needsAttention:
            return repository.fetchError != nil || RepositoryIssueCatalog().findings(in: repository).contains { $0.severity != .information }
        case .toPush: return (repository.ahead ?? 0) > 0
        case .toPull: return (repository.behind ?? 0) > 0
        case .changedFiles: return repository.changedFileCount > 0
        case .staleBranches: return !repository.staleBranches.isEmpty
        case .worktrees: return !repository.worktrees.isEmpty
        }
    }
}

public enum RepositorySort: String, CaseIterable, Sendable {
    case name = "Name"
    case lastActivity = "Last activity"
    case toPush = "To push"
    case toPull = "To pull"
    case changedFiles = "Changed files"
    case staleBranches = "Stale branches"
    case worktrees = "Worktrees"
    case stars = "Stars"
    case forks = "Forks"

    case activeUsersSevenDays = "GA4 active users · 7 days"
    case activeUsersRealtime = "GA4 active users · 30 minutes"

    var trafficWindow: GA4TrafficWindow? {
        switch self {
        case .activeUsersSevenDays: return .sevenDays
        case .activeUsersRealtime: return .realtime
        default: return nil
        }
    }

    private func value(
        in repository: RepositorySnapshot,
        githubCounts: (RepositorySnapshot) -> (stars: Int, forks: Int)?,
        activeUsers: (RepositorySnapshot) -> Int?
    ) -> Double? {
        switch self {
        case .name: return nil
        case .lastActivity: return repository.lastCommitAt?.timeIntervalSince1970
        case .toPush: return repository.ahead.map { Double($0) }
        case .toPull: return repository.behind.map { Double($0) }
        case .changedFiles: return Double(repository.changedFileCount)
        case .staleBranches: return Double(repository.staleBranches.count)
        case .worktrees: return Double(repository.worktrees.count)
        case .stars: return githubCounts(repository).map { Double($0.stars) }
        case .forks: return githubCounts(repository).map { Double($0.forks) }
        case .activeUsersSevenDays, .activeUsersRealtime: return activeUsers(repository).map(Double.init)
        }
    }

    public func repositories(
        _ repositories: [RepositorySnapshot],
        filter: RepositoryFilter = .all,
        search: String = "",
        ascending: Bool = true,
        githubCounts: (RepositorySnapshot) -> (stars: Int, forks: Int)? = { _ in nil },
        activeUsers: (RepositorySnapshot) -> Int? = { _ in nil }
    ) -> [RepositorySnapshot] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return repositories.filter {
            filter.matches($0) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
        }.map { repository in
            (repository: repository, value: value(in: repository, githubCounts: githubCounts, activeUsers: activeUsers))
        }.sorted { left, right in
            if self != .name {
                switch (left.value, right.value) {
                case let (left?, right?) where left != right:
                    return ascending ? left < right : left > right
                case (nil, .some): return false
                case (.some, nil): return true
                default: break
                }
            }
            let nameOrder = left.repository.name.localizedStandardCompare(right.repository.name)
            if nameOrder != .orderedSame {
                // Equal values keep a predictable alphabetical order in either direction.
                return self == .name && !ascending
                    ? nameOrder == .orderedDescending : nameOrder == .orderedAscending
            }
            return left.repository.id < right.repository.id
        }.map(\.repository)
    }
}
