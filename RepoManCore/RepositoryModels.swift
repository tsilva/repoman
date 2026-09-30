import Foundation

public struct RepositorySnapshot: Identifiable, Sendable, Equatable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let branch: String
    public let upstream: String?
    public let remoteURL: String?
    public let ahead: Int?
    public let behind: Int?
    public let changes: [WorkingTreeChange]
    public let staleBranches: [String]
    public let worktrees: [String]
    public let commits: [RepositoryCommit]
    public let detailsLoaded: Bool
    /// Nil means root inspection failed; detectors must not interpret that as missing files.
    public let rootFiles: [String]?
    public let checkedAt: Date
    public var fetchedAt: Date?
    public var fetchError: String?

    public var changedFileCount: Int { changes.count }

    public init(
        url: URL,
        name: String,
        branch: String,
        upstream: String?,
        remoteURL: String?,
        ahead: Int?,
        behind: Int?,
        changes: [WorkingTreeChange],
        staleBranches: [String],
        worktrees: [String],
        commits: [RepositoryCommit],
        detailsLoaded: Bool = true,
        checkedAt: Date = Date(),
        fetchedAt: Date? = nil,
        fetchError: String? = nil,
        rootFiles: [String]? = nil
    ) {
        self.url = url
        self.name = name
        self.branch = branch
        self.upstream = upstream
        self.remoteURL = remoteURL
        self.ahead = ahead
        self.behind = behind
        self.changes = changes
        self.staleBranches = staleBranches
        self.worktrees = worktrees
        self.commits = commits
        self.detailsLoaded = detailsLoaded
        self.rootFiles = rootFiles
        self.checkedAt = checkedAt
        self.fetchedAt = fetchedAt
        self.fetchError = fetchError
    }

    public var remoteWebURL: URL? {
        guard var remoteURL else { return nil }
        if remoteURL.hasPrefix("git@"), let colon = remoteURL.firstIndex(of: ":") {
            let host = remoteURL.dropFirst(4)[..<colon]
            let path = remoteURL[remoteURL.index(after: colon)...]
            remoteURL = "https://\(host)/\(path)"
        }
        guard var components = URLComponents(string: remoteURL),
              ["https", "http"].contains(components.scheme?.lowercased() ?? "") else {
            return nil
        }
        if components.path.hasSuffix(".git") {
            components.path.removeLast(4)
        }
        return components.url
    }

    public var remoteDisplayName: String? {
        guard let remoteWebURL else { return remoteURL }
        let host = remoteWebURL.host ?? ""
        return host + remoteWebURL.path
    }
}

public struct WorkingTreeChange: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable {
        case modified
        case untracked
    }

    public var id: String { path }
    public let path: String
    public let kind: Kind
    public let added: Int?
    public let removed: Int?

    public init(path: String, kind: Kind, added: Int?, removed: Int?) {
        self.path = path
        self.kind = kind
        self.added = added
        self.removed = removed
    }
}

public struct RepositoryCommit: Identifiable, Sendable, Equatable {
    public var id: String { hash }
    public let hash: String
    public let subject: String
    public let relativeDate: String

    public init(hash: String, subject: String, relativeDate: String) {
        self.hash = hash
        self.subject = subject
        self.relativeDate = relativeDate
    }
}
