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
            return repository.fetchError != nil
                || [Self.toPush, .toPull, .changedFiles, .staleBranches, .worktrees]
                    .contains { $0.matches(repository) }
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
    case toPush = "To push"
    case toPull = "To pull"
    case changedFiles = "Changed files"
    case staleBranches = "Stale branches"
    case worktrees = "Worktrees"

    private func count(in repository: RepositorySnapshot) -> Int? {
        switch self {
        case .name: return nil
        case .toPush: return repository.ahead
        case .toPull: return repository.behind
        case .changedFiles: return repository.changedFileCount
        case .staleBranches: return repository.staleBranches.count
        case .worktrees: return repository.worktrees.count
        }
    }

    public func repositories(
        _ repositories: [RepositorySnapshot],
        filter: RepositoryFilter = .all,
        search: String = "",
        ascending: Bool = true
    ) -> [RepositorySnapshot] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return repositories.filter {
            filter.matches($0) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
        }.sorted { lhs, rhs in
            if self != .name {
                switch (count(in: lhs), count(in: rhs)) {
                case let (left?, right?) where left != right:
                    return ascending ? left < right : left > right
                case (nil, .some): return false
                case (.some, nil): return true
                default: break
                }
            }
            let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
            if nameOrder != .orderedSame {
                // Equal counts keep a predictable alphabetical order in either direction.
                return self == .name && !ascending
                    ? nameOrder == .orderedDescending : nameOrder == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }
}
