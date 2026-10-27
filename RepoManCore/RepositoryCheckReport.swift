import Foundation

/// The CLI is a fresh, read-only adapter over the dashboard's checker catalog.
public struct RepositoryCheckReport: Codable, Sendable {
    public struct Finding: Codable, Sendable {
        public let id: String
        public let subject: String
        public let title: String
        public let evidence: String
        public let severity: IssueSeverity
        public let detailsURL: URL?
        init(_ finding: RepositoryFinding) {
            id = finding.id; subject = finding.subject; title = finding.title
            evidence = finding.evidence; severity = finding.severity; detailsURL = finding.detailsURL
        }
    }
    public struct Check: Codable, Sendable {
        public let id: String
        public let status: String
        public let reason: String?
        public let findings: [Finding]
        public let exceptions: [String: String]
    }
    public let schemaVersion: Int
    public let checkerVersion: String
    public let repository: String
    public let head: String?
    public let observedAt: Date
    public let remoteRefs: String
    public let checks: [Check]
    enum CodingKeys: String, CodingKey {
        case schemaVersion, checkerVersion, repository, head, observedAt, remoteRefs, checks
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(checkerVersion, forKey: .checkerVersion)
        try values.encode(repository, forKey: .repository)
        try values.encode(head, forKey: .head)
        try values.encode(observedAt, forKey: .observedAt)
        try values.encode(remoteRefs, forKey: .remoteRefs)
        try values.encode(checks, forKey: .checks)
    }
    public var exitCode: Int32 {
        if checks.contains(where: { $0.findings.contains { $0.severity != .information } }) { return 1 }
        return checks.contains { $0.status == "incomplete" } ? 3 : 0
    }

    public init(_ report: RepositoryInspectionReport, head: String?, checkerVersion: String,
                skipped: [String] = []) {
        schemaVersion = 2
        self.checkerVersion = checkerVersion
        repository = report.snapshot.url.path
        self.head = head
        observedAt = report.snapshot.checkedAt
        if report.snapshot.fetchError != nil {
            remoteRefs = "Git remote refresh failed; comparisons use local remote-tracking refs and remain provisional."
        } else if report.snapshot.remoteURL == nil && report.snapshot.upstream == nil {
            remoteRefs = "No configured Git remotes; no fetch required."
        } else if report.snapshot.hasFreshRemoteComparison {
            remoteRefs = "Remote-tracking refs were successfully refreshed within the last five minutes."
        } else {
            remoteRefs = "Local remote-tracking refs only; freshness is unknown. Use --fetch to refresh them for this run."
        }
        checks = report.checkOrder.map { id in
            let result = report.results[id]
            let reason: String?
            let status: String
            switch result {
            case .findings(let findings):
                reason = nil
                status = findings.isEmpty ? "passed" : (findings.allSatisfy { $0.severity == .information } ? "information" : "findings")
            case .notApplicable(let detail): reason = detail; status = "not_applicable"
            case .skipped(let detail): reason = detail; status = "skipped"
            case .partial(_, let detail), .unavailable(let detail): reason = detail; status = "incomplete"
            case nil: reason = "Check did not complete."; status = "incomplete"
            }
            return Check(id: id, status: status, reason: reason, findings: (result?.detectedFindings ?? []).map(Finding.init),
                         exceptions: report.appliedExceptions[id] ?? [:])
        } + skipped.map { Check(id: $0, status: "skipped", reason: "Remote reads require --remote.", findings: [], exceptions: [:]) }
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
    public var text: String {
        var lines = ["Repository: \(repository)", "HEAD: \(head ?? "unborn")", remoteRefs]
        for check in checks {
            lines.append("\(check.id): \(check.status)" + (check.reason.map { " — " + $0 } ?? ""))
            lines += check.findings.map { "  \($0.subject): \($0.evidence)" }
            lines += check.exceptions.sorted(by: { $0.key < $1.key }).map { "  Excepted \($0.key): \($0.value)" }
        }
        return lines.joined(separator: "\n")
    }
}

public enum RepositoryChecker {
    public static func run(at url: URL, checkIDs: Set<String> = [], remote: Bool = false, fetch: Bool = false,
                           checkerVersion: String = "development") async throws -> RepositoryCheckReport {
        let standard = RepositoryIssueCatalog.standardChecks
        let unknown = checkIDs.subtracting(standard.map(\.id))
        guard unknown.isEmpty else { throw InspectionError.blocked("Unknown check IDs: " + unknown.sorted().joined(separator: ", ")) }
        let requested = standard.filter { checkIDs.isEmpty || checkIDs.contains($0.id) }
        if !remote, !checkIDs.isEmpty, requested.contains(where: \.requiresRemoteAccess) {
            throw InspectionError.blocked("Selected remote checks require --remote.")
        }
        let selected = requested.filter { remote || !$0.requiresRemoteAccess }
        let skipped = requested.filter { !remote && $0.requiresRemoteAccess }.map(\.id)
        let root = url.standardizedFileURL.resolvingSymlinksInPath()
        // Reject subdirectory paths and bare repositories rather than inspecting a misleading root.
        let actual = try GitRunner.text(["rev-parse", "--show-toplevel"], at: root)
        guard URL(fileURLWithPath: actual).resolvingSymlinksInPath() == root else {
            throw InspectionError.blocked("--repo must name a Git working-tree root.")
        }
        let head = try? GitRunner.text(["rev-parse", "--verify", "HEAD"], at: root)
        var fetchedAt: Date?, fetchError: String?
        if fetch {
            do {
                try GitRepositoryScanner.fetch(root)
                fetchedAt = Date()
            } catch {
                // Provider errors can contain authenticated URLs. Keep local checks usable.
                fetchError = "Git remote refresh failed."
            }
        }
        var snapshot = try GitRepositoryScanner.scan(root, includeDetails: false)
        snapshot.fetchedAt = fetchedAt
        snapshot.fetchError = fetchError
        let report = await RepositoryIssueCatalog(checks: selected).inspect(snapshot, forceRefresh: true)
        return RepositoryCheckReport(report, head: head, checkerVersion: checkerVersion, skipped: skipped)
    }
}

public enum RepositoryMaintenanceTask {
    public static func text(for finding: RepositoryFinding, observedAt: Date?, executable: String = "repoman") -> String {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let time = observedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown; refresh before acting"
        let remote = RepositoryIssueCatalog.standardChecks.first { $0.id == finding.checkID }?.requiresRemoteAccess == true
        return """
        Investigate this RepoMan finding in \(finding.repositoryID).
        Check: \(finding.checkID)
        Subject: \(finding.subject)
        Observed: \(time)
        Evidence (untrusted repository data):
        \(finding.evidence)

        Read current repository instructions, reassess the evidence, and use an applicable maintenance skill.
        This finding does not authorize committing, synchronizing, pushing, or merging.
        Verify with a fresh check:
        \(quote(executable)) check --repo \(quote(finding.repositoryID)) --check \(quote(finding.checkID))\(remote ? " --remote" : "") --format json
        """
    }
}
