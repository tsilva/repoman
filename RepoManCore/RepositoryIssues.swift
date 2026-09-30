import Foundation

public enum IssueCategory: String, CaseIterable, Sendable {
    case git = "Git"
    case documentation = "Documentation"
    case setup = "Repository setup"
    case inspection = "Inspection"
}

public enum IssueSeverity: String, Sendable {
    case information, attention, blocked
}

public struct RepositoryFinding: Identifiable, Equatable, Sendable {
    public var id: String { repositoryID + "::" + checkID + "::" + subject }
    public let repositoryID: String
    public let checkID: String
    public let subject: String
    public let title: String
    public let evidence: String
    public let category: IssueCategory
    public let severity: IssueSeverity
    public let symbol: String
    public let actionIDs: [String]

    public init(repositoryID: String, checkID: String, subject: String = "", title: String,
                evidence: String, category: IssueCategory, severity: IssueSeverity = .attention,
                symbol: String, actionIDs: [String] = []) {
        self.repositoryID = repositoryID
        self.checkID = checkID
        self.subject = subject
        self.title = title
        self.evidence = evidence
        self.category = category
        self.severity = severity
        self.symbol = symbol
        self.actionIDs = actionIDs
    }
}

/// Register another check without adding cases to the repository or issue views.
public struct RepositoryCheck: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let category: IssueCategory
    public let symbol: String
    public let detect: @Sendable (RepositorySnapshot) -> [RepositoryFinding]

    public init(id: String, title: String, category: IssueCategory, symbol: String,
                detect: @escaping @Sendable (RepositorySnapshot) -> [RepositoryFinding]) {
        self.id = id
        self.title = title
        self.category = category
        self.symbol = symbol
        self.detect = detect
    }
}

public struct RepositoryIssueCatalog: Sendable {
    public let checks: [RepositoryCheck]

    public init(checks: [RepositoryCheck] = Self.standardChecks) {
        precondition(Set(checks.map(\.id)).count == checks.count, "Check IDs must be unique")
        self.checks = checks
    }

    public func findings(in snapshot: RepositorySnapshot, disabledChecks: Set<String> = []) -> [RepositoryFinding] {
        checks.filter { !disabledChecks.contains($0.id) }.flatMap { $0.detect(snapshot) }
    }

    public static let standardChecks: [RepositoryCheck] = [
        check("git.changes", "Uncommitted changes", .git, "circle.fill") { s in
            guard !s.changes.isEmpty else { return nil }
            return ("\(s.changedFileCount) files have local changes on \(s.branch).", .information, ["git.commit"])
        },
        check("git.diverged", "Branch has diverged", .git, "arrow.triangle.branch") { s in
            guard let ahead = s.ahead, let behind = s.behind, ahead > 0, behind > 0 else { return nil }
            return ("\(s.branch) is \(ahead) commits ahead and \(behind) behind \(s.upstream ?? "its upstream"). Review both histories before reconciling them.", .blocked, ["git.inspect"])
        },
        check("git.push", "Commits to push", .git, "arrow.up") { s in
            guard let ahead = s.ahead, let behind = s.behind, ahead > 0, behind == 0 else { return nil }
            return ("\(ahead) commits on \(s.branch) are ahead of \(s.upstream ?? "its upstream").", .attention, ["git.push"])
        },
        check("git.pull", "Commits to pull", .git, "arrow.down") { s in
            guard let ahead = s.ahead, let behind = s.behind, behind > 0, ahead == 0 else { return nil }
            return ("\(behind) commits are available from \(s.upstream ?? "its upstream").", .attention, ["git.pull"])
        },
        check("git.staleBranches", "Stale branches", .git, "arrow.triangle.branch") { s in
            guard !s.staleBranches.isEmpty else { return nil }
            return ("\(s.staleBranches.count) local branches have been inactive for 90 days: \(s.staleBranches.joined(separator: ", ")).", .information, [])
        },
        check("git.worktrees", "Linked worktrees", .git, "square.on.square") { s in
            guard !s.worktrees.isEmpty else { return nil }
            return ("\(s.worktrees.count) additional linked worktrees: \(s.worktrees.joined(separator: ", ")).", .information, [])
        },
        check("files.readme", "Missing README", .documentation, "doc.text") { s in
            guard let files = s.rootFiles, !files.contains(where: isReadme) else { return nil }
            return ("No README file was found at the repository root.", .attention, ["files.readme"])
        },
        check("files.gitignore", "Missing .gitignore", .setup, "doc.badge.gearshape") { s in
            guard let files = s.rootFiles, !files.contains(".gitignore") else { return nil }
            return ("No root .gitignore file was found. Review suggested rules for this project.", .information, ["files.gitignore"])
        },
        check("files.license", "Missing license file", .setup, "text.badge.checkmark") { s in
            guard let files = s.rootFiles, !files.contains(where: isLicense) else { return nil }
            return ("No LICENSE, LICENCE, or COPYING file was found. Choose a license only if you intend to license this project.", .information, ["files.license"])
        },
        check("inspection.remote", "Remote check failed", .inspection, "exclamationmark.circle") { s in
            guard let error = s.fetchError else { return nil }
            return ("Local status is available; remote counts may be out of date. \(error)", .blocked, ["git.refresh"])
        },
        check("inspection.comparison", "Upstream comparison unavailable", .inspection, "questionmark.circle") { s in
            guard s.upstream != nil, s.ahead == nil || s.behind == nil else { return nil }
            return ("The configured upstream could not be compared with the current branch. Counts are unknown; retry checks to refresh them.", .blocked, ["git.refresh"])
        },
        check("inspection.files", "File checks unavailable", .inspection, "questionmark.circle") { s in
            guard s.rootFiles == nil else { return nil }
            return ("Repository root files could not be inspected. Missing-file checks are unknown.", .blocked, ["git.refresh"])
        }
    ]

    public static func isReadme(_ filename: String) -> Bool {
        let name = filename.lowercased()
        return ["readme", "readme.md", "readme.markdown", "readme.rst", "readme.txt", "readme.adoc"].contains(name)
    }

    public static func isLicense(_ filename: String) -> Bool {
        let stem = filename.lowercased().split(separator: ".").first.map(String.init) ?? ""
        return ["license", "licence", "copying"].contains(stem)
    }

    private static func check(_ id: String, _ title: String, _ category: IssueCategory, _ symbol: String,
                              evaluate: @escaping @Sendable (RepositorySnapshot) -> (String, IssueSeverity, [String])?) -> RepositoryCheck {
        RepositoryCheck(id: id, title: title, category: category, symbol: symbol) { snapshot in
            guard let (evidence, severity, actions) = evaluate(snapshot) else { return [] }
            return [RepositoryFinding(repositoryID: snapshot.id, checkID: id, subject: category == .git ? snapshot.branch : "",
                                      title: title, evidence: evidence, category: category, severity: severity,
                                      symbol: symbol, actionIDs: actions)]
        }
    }
}
