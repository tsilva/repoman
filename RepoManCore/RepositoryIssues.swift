import Foundation

public enum IssueCategory: String, CaseIterable, Codable, Sendable {
    case git = "Git"
    case documentation = "Documentation"
    case setup = "Repository setup"
    case inspection = "Inspection"
    case ci = "CI"
}

public enum IssueSeverity: String, Codable, Sendable {
    case information, attention, blocked
}

public struct RepositoryFinding: Identifiable, Equatable, Codable, Sendable {
    public var id: String { repositoryID + "::" + checkID + "::" + subject }
    public let repositoryID: String
    public let checkID: String
    public let subject: String
    public let title: String
    public let evidence: String
    public let category: IssueCategory
    public let severity: IssueSeverity
    public let symbol: String
    public let recipeIDs: [String]
    public let detailsURL: URL?

    public init(repositoryID: String, checkID: String, subject: String = "", title: String,
                evidence: String, category: IssueCategory, severity: IssueSeverity = .attention,
                symbol: String, recipeIDs: [String] = [], detailsURL: URL? = nil) {
        self.repositoryID = repositoryID
        self.checkID = checkID
        self.subject = subject
        self.title = title
        self.evidence = evidence
        self.category = category
        self.severity = severity
        self.symbol = symbol
        self.recipeIDs = recipeIDs
        self.detailsURL = detailsURL
    }
}

/// A detected issue, stored conversation, or incomplete check for the shared issue list.
public struct RepositoryIssueListItem: Identifiable, Equatable, Sendable {
    public let finding: RepositoryFinding
    public let task: RepairTask?
    /// Incomplete checks use finding metadata for presentation, but are not confirmed findings.
    public let incompleteReason: String?
    public var isIncomplete: Bool { incompleteReason != nil }
    public var isArchived: Bool { task?.isArchived == true }
    // Check availability is shown on the row; summary badges track repair state.
    public var status: RepositoryIssueStatus { RepositoryIssueStatus(state: task?.state) }
    // Recurrences share a detector identity, but each completed or archived conversation has its own identity.
    public var id: String {
        if isIncomplete { return "incomplete::" + finding.id }
        if let task, task.state.isClosed || task.isArchived { return "conversation::\(task.id)" }
        return finding.id
    }

    public init(finding: RepositoryFinding, task: RepairTask? = nil) {
        self.finding = finding; self.task = task
        incompleteReason = nil
    }

    public init(incompleteCheck check: RepositoryCheck, repositoryID: String, reason: String) {
        finding = RepositoryFinding(repositoryID: repositoryID, checkID: check.id,
            title: check.id == "dependencies.lockfileDrift" ? "Manifest and lockfile consistency" : check.title,
            evidence: "Could not finish: " + reason, category: check.category,
            symbol: check.id == "dependencies.lockfileDrift" ? "lock" : check.symbol)
        task = nil
        incompleteReason = reason
    }

    public static func items(findings: [RepositoryFinding], tasks: [RepairTask],
                             includeCompleted: Bool = false, includeArchived: Bool = false) -> [Self] {
        let unarchived = tasks.filter { !$0.isArchived }
        var items = findings.map { finding in
            Self(finding: finding, task: unarchived.last { $0.finding.id == finding.id && !$0.state.isClosed })
        }
        var visible = Set(findings.map(\.id))
        // An unavailable detector must not hide an unresolved conversation.
        for task in unarchived.reversed() where !task.state.isClosed {
            if visible.insert(task.finding.id).inserted { items.append(Self(finding: task.finding, task: task)) }
        }
        if includeCompleted || includeArchived {
            items += unarchived.filter { $0.state.isClosed }.map { Self(finding: $0.finding, task: $0) }
        }
        if includeArchived {
            items += tasks.filter(\.isArchived).map { Self(finding: $0.finding, task: $0) }
        }
        return items
    }
}

/// Shared row and badge categories; each visible issue belongs to exactly one status.
public enum RepositoryIssueStatus: String, CaseIterable, Sendable {
    case pending, processing, waiting, completed

    public init(state: RepairTaskState?) {
        switch state {
        case nil: self = .pending
        case .queued, .running, .checking, .interrupted: self = .processing
        case .needsInput, .stillPresent, .cancelled, .failed, .couldntVerify: self = .waiting
        case .resolved, .noLongerNeeded: self = .completed
        }
    }

    public static func counts(in items: [RepositoryIssueListItem]) -> [Self: Int] {
        items.filter { !$0.isArchived }.reduce(into: [:]) { $0[$1.status, default: 0] += 1 }
    }
}

/// Register another check without adding cases to the repository or issue views.
public struct RepositoryCheck: Identifiable, Sendable {
    public enum ConfigurationKind: Sendable { case model }
    public let id: String
    public let title: String
    public let category: IssueCategory
    public let symbol: String
    public let detect: @Sendable (RepositorySnapshot) -> [RepositoryFinding]
    public let validityPeriod: TimeInterval
    public let requiresExtendedInspection: Bool
    public let inspect: @Sendable (RepositoryInspectionContext) async throws -> [RepositoryFinding]
    public let availability: @Sendable (RepositorySnapshot) -> String?
    public let configurationKind: ConfigurationKind?
    /// Content-cached checks must read fresh inputs before deciding whether a paid request is due.
    public let usesContentCache: Bool
    public let evaluate: @Sendable (RepositoryInspectionContext) async throws -> RepositoryCheckResult

    public init(id: String, title: String, category: IssueCategory, symbol: String,
                validityPeriod: TimeInterval? = nil,
                availability: @escaping @Sendable (RepositorySnapshot) -> String? = { _ in nil },
                detect: @escaping @Sendable (RepositorySnapshot) -> [RepositoryFinding]) {
        self.id = id
        self.title = title
        self.category = category
        self.symbol = symbol
        self.validityPeriod = validityPeriod ?? Self.defaultValidityPeriod(for: id)
        self.requiresExtendedInspection = false
        self.detect = detect
        self.availability = availability
        configurationKind = nil; usesContentCache = false
        self.inspect = { context in
            if let reason = availability(context.snapshot) { throw RepairError.blocked(reason) }
            return detect(context.snapshot)
        }
        self.evaluate = { context in
            if let reason = availability(context.snapshot) { throw RepairError.blocked(reason) }
            return .findings(detect(context.snapshot))
        }
    }

    /// Use for checks needing content or asynchronous inspection. No UI or runner changes are needed.
    public init(id: String, title: String, category: IssueCategory, symbol: String,
                validityPeriod: TimeInterval? = nil,
                inspect: @escaping @Sendable (RepositoryInspectionContext) async throws -> [RepositoryFinding]) {
        self.id = id; self.title = title; self.category = category; self.symbol = symbol
        self.validityPeriod = validityPeriod ?? Self.defaultValidityPeriod(for: id)
        self.requiresExtendedInspection = true
        self.inspect = inspect
        detect = { _ in [] }
        availability = { _ in "This detector requires extended inspection." }
        configurationKind = nil; usesContentCache = false
        evaluate = { context in .findings(try await inspect(context)) }
    }

    public init(id: String, title: String, category: IssueCategory, symbol: String,
                validityPeriod: TimeInterval = 3_600, configurationKind: ConfigurationKind,
                evaluate: @escaping @Sendable (RepositoryInspectionContext) async throws -> RepositoryCheckResult) {
        self.id = id; self.title = title; self.category = category; self.symbol = symbol
        self.validityPeriod = validityPeriod; self.configurationKind = configurationKind
        self.evaluate = evaluate; usesContentCache = true; requiresExtendedInspection = true
        detect = { _ in [] }; availability = { _ in "This detector requires extended inspection." }
        inspect = { context in
            switch try await evaluate(context) {
            case .findings(let findings): return findings
            case .partial(_, let reason), .unavailable(let reason): throw RepairError.blocked(reason)
            }
        }
    }

    private static func defaultValidityPeriod(for id: String) -> TimeInterval {
        switch id {
        case "git.staleBranches", "git.oldStashes", "github.description": return 86_400
        case "ci.failing": return 300
        default:
            if id.hasPrefix("git.") || id.hasPrefix("inspection.") { return 300 }
            return 3_600
        }
    }

    public func isDue(result: RepositoryCheckResult?, completedAt: Date?, now: Date = Date()) -> Bool {
        guard let result, let completedAt else { return true }
        let age = now.timeIntervalSince(completedAt)
        let period: TimeInterval
        switch result {
        case .unavailable, .partial: period = min(validityPeriod, 300)
        case .findings: period = validityPeriod
        }
        return age < 0 || age >= period
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

    /// Keep incomplete checks separate from detector findings and repair conversations.
    public func incompleteItems(in report: RepositoryInspectionReport, disabledChecks: Set<String> = []) -> [RepositoryIssueListItem] {
        let unavailable = report.unavailableChecks
        return checks.compactMap { check in
            guard !disabledChecks.contains(check.id), let reason = unavailable[check.id] else { return nil }
            return RepositoryIssueListItem(incompleteCheck: check, repositoryID: report.snapshot.id, reason: reason)
        }
    }

    /// Verification always uses the registered detector, independently of display filters.
    public func verify(_ finding: RepositoryFinding, in snapshot: RepositorySnapshot) -> RepairVerification {
        guard snapshot.id == finding.repositoryID else { return .unknown("Repository identity changed.") }
        guard let check = checks.first(where: { $0.id == finding.checkID }) else {
            return .unknown("The original detector is no longer registered.")
        }
        if let reason = check.availability(snapshot) { return .unknown(reason) }
        if let current = check.detect(snapshot).first(where: { $0.id == finding.id }) {
            return .present(current.evidence)
        }
        return .absent("Fresh inspection confirms this finding is absent.")
    }

    public static let standardChecks: [RepositoryCheck] = [
        check("git.changes", "Uncommitted changes", .git, "circle.fill") { s in
            guard !s.changes.isEmpty else { return nil }
            return ("\(s.changedFileCount) files have local changes on \(s.branch).", .information, ["git.commit"])
        },
        check("git.diverged", "Branch has diverged", .git, "arrow.triangle.branch", inspections: ["comparison"]) { s in
            guard let ahead = s.ahead, let behind = s.behind, ahead > 0, behind > 0 else { return nil }
            return ("\(s.branch) is \(ahead) commits ahead and \(behind) behind \(s.upstream ?? "its upstream"). Review both histories before reconciling them.", .blocked, ["git.inspect"])
        },
        check("git.push", "Commits to push", .git, "arrow.up", inspections: ["comparison"]) { s in
            guard let ahead = s.ahead, let behind = s.behind, ahead > 0, behind == 0 else { return nil }
            return ("\(ahead) commits on \(s.branch) are ahead of \(s.upstream ?? "its upstream").", .attention, ["git.push"])
        },
        check("git.pull", "Commits to pull", .git, "arrow.down", inspections: ["comparison"]) { s in
            guard let ahead = s.ahead, let behind = s.behind, behind > 0, ahead == 0 else { return nil }
            return ("\(behind) commits are available from \(s.upstream ?? "its upstream").", .attention, ["git.pull"])
        },
        check("git.staleBranches", "Stale branches", .git, "arrow.triangle.branch", inspections: ["branches"]) { s in
            guard !s.staleBranches.isEmpty else { return nil }
            return ("\(s.staleBranches.count) local branches have been inactive for 90 days: \(s.staleBranches.joined(separator: ", ")).", .information, ["git.staleBranches"])
        },
        check("git.worktrees", "Linked worktrees", .git, "square.on.square", inspections: ["worktrees"]) { s in
            guard !s.worktrees.isEmpty else { return nil }
            return ("\(s.worktrees.count) additional linked worktrees: \(s.worktrees.joined(separator: ", ")).", .information, ["git.worktrees"])
        },
        check("files.readme", "Missing README", .documentation, "doc.text", inspections: ["files"]) { s in
            guard let files = s.rootFiles, !files.contains(where: isReadme) else { return nil }
            return ("No README file was found at the repository root.", .attention, ["files.readme"])
        },
        check("files.gitignore", "Missing .gitignore", .setup, "doc.badge.gearshape", inspections: ["files"]) { s in
            guard let files = s.rootFiles, !files.contains(".gitignore") else { return nil }
            return ("No root .gitignore file was found. Review suggested rules for this project.", .information, ["files.gitignore"])
        },
        check("files.license", "Missing license file", .setup, "text.badge.checkmark", inspections: ["files"]) { s in
            guard let files = s.rootFiles, !files.contains(where: isLicense) else { return nil }
            return ("No LICENSE, LICENCE, or COPYING file was found. Choose a license only if you intend to license this project.", .information, ["files.license.mit", "files.license"])
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
    ] + RepositoryCIChecks.checks() + RepositoryDependencyChecks.checks() + RepositoryWorkflowChecks.checks()
        + RepositoryHygieneChecks.checks() + RepositoryMetadataChecks.checks()
        + RepositoryGitHealthChecks.checks() + RepositoryContentChecks.checks() + RepositoryLockfileChecks.checks()
        + RepositoryRuntimeChecks.checks() + RepositoryWorkflowSecurityChecks.checks() + RepositoryProjectReferenceChecks.checks()
        + RepositoryReadmeChecks.checks()

    public static func isReadme(_ filename: String) -> Bool {
        let name = filename.lowercased()
        return ["readme", "readme.md", "readme.markdown", "readme.rst", "readme.txt", "readme.adoc"].contains(name)
    }

    public static func isLicense(_ filename: String) -> Bool {
        let stem = filename.lowercased().split(separator: ".").first.map(String.init) ?? ""
        return ["license", "licence", "copying"].contains(stem)
    }

    private static func check(_ id: String, _ title: String, _ category: IssueCategory, _ symbol: String,
                              inspections: [String] = [], evaluate: @escaping @Sendable (RepositorySnapshot) -> (String, IssueSeverity, [String])?) -> RepositoryCheck {
        RepositoryCheck(id: id, title: title, category: category, symbol: symbol, availability: { s in
            for inspection in inspections {
                if let error = s.inspectionErrors[inspection] { return error }
                if inspection == "files", s.rootFiles == nil { return "Repository files could not be inspected." }
                if inspection == "comparison", s.upstream != nil,
                   s.ahead == nil || s.behind == nil { return "Upstream comparison is unavailable." }
            }
            return nil
        }) { snapshot in
            guard let (evidence, severity, actions) = evaluate(snapshot) else { return [] }
            return [RepositoryFinding(repositoryID: snapshot.id, checkID: id, subject: category == .git ? snapshot.branch : "",
                                      title: title, evidence: evidence, category: category, severity: severity,
                                      symbol: symbol, recipeIDs: actions)]
        }
    }
}
