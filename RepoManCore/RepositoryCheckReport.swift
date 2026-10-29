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
    public struct Coverage: Codable, Sendable {
        public let id: String
        public let status: String
        public let reason: String
        public let affectedCheckIDs: [String]
    }
    public let coverage: [Coverage]
    public let schemaVersion: Int
    public let checkerVersion: String
    public let repository: String
    public let head: String?
    public let observedAt: Date
    public let remoteRefs: String
    public let checks: [Check]
    public let dependencyComparison: DependencyComparisonReport?
    public let dependencyVulnerabilities: DependencyVulnerabilityReport?
    enum CodingKeys: String, CodingKey {
        case schemaVersion, checkerVersion, repository, head, observedAt, remoteRefs, checks, coverage, dependencyComparison, dependencyVulnerabilities
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
        try values.encode(coverage, forKey: .coverage)
        try values.encodeIfPresent(dependencyComparison, forKey: .dependencyComparison)
        try values.encodeIfPresent(dependencyVulnerabilities, forKey: .dependencyVulnerabilities)
    }
    public var exitCode: Int32 {
        if checks.contains(where: { $0.findings.contains { $0.severity != .information } }) { return 1 }
        return (checks.contains { $0.status == "incomplete" } || coverage.contains { $0.status == "incomplete" }) ? 3 : 0
    }

    public init(_ report: RepositoryInspectionReport, head: String?, checkerVersion: String,
                skipped: [String] = [], dependencyComparison: DependencyComparisonReport? = nil,
                dependencyVulnerabilities: DependencyVulnerabilityReport? = nil) {
        schemaVersion = 3
        self.dependencyComparison = dependencyComparison
        self.dependencyVulnerabilities = dependencyVulnerabilities
        coverage = report.coverage
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
        if let advisory = dependencyVulnerabilities {
            lines.append("Locked advisory snapshot: \(advisory.versions.count) versions; provider \(advisory.provider); observed \(advisory.checkedAt)")
        }
        if let comparison = dependencyComparison {
            lines.append("Comparison base: \(comparison.baseCommit); includes working tree; observed \(comparison.checkedAt)")
            lines.append("Introduced locked versions: \(comparison.introduced.count); minimum age: \(comparison.minimumAgeDays) days")
            for version in comparison.introduced {
                lines.append("  \(version.identity): \(version.status)" + (version.eligibleAt.map { " — eligible " + $0 } ?? ""))
            }
        }
        for item in coverage { lines.append("Verification \(item.id): \(item.status) — \(item.reason)") }
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
                           checkerVersion: String = "development", comparisonBase: String? = nil) async throws -> RepositoryCheckReport {
        let standard = RepositoryIssueCatalog.standardChecks + RepositoryIssueCatalog.coverageCompatibilityChecks
        let unknown = checkIDs.subtracting(standard.map(\.id))
        guard unknown.isEmpty else { throw InspectionError.blocked("Unknown check IDs: " + unknown.sorted().joined(separator: ", ")) }
        let requested = checkIDs.isEmpty ? RepositoryIssueCatalog.standardChecks : standard.filter { checkIDs.contains($0.id) }
        if !remote, !checkIDs.isEmpty, requested.contains(where: \.requiresRemoteAccess) {
            throw InspectionError.blocked("Selected remote checks require --remote.")
        }
        if comparisonBase != nil, !remote { throw InspectionError.blocked("Release-age comparisons require --remote.") }
        if checkIDs.contains(RepositoryReleaseAgeChecks.id), comparisonBase == nil {
            throw InspectionError.blocked("The release-age check requires an explicit --base COMMIT.")
        }
        if comparisonBase != nil, !requested.contains(where: { $0.id == RepositoryReleaseAgeChecks.id }) {
            throw InspectionError.blocked("--base applies only to dependencies.releaseAge.")
        }
        var selected = requested.filter { remote || !$0.requiresRemoteAccess }
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
        let capture = DependencyComparisonCapture()
        let vulnerabilities = DependencyVulnerabilityCapture()
        selected = selected.map { check in
            check.id == RepositoryVulnerabilityChecks.id ? RepositoryVulnerabilityChecks.checks(record: { vulnerabilities.record($0) })[0] : check
        }
        if let comparisonBase {
            let bytes = try GitRunner.run(["rev-parse", "--verify", "--end-of-options", comparisonBase + "^{commit}"], at: root,
                                          timeout: 10, maximumOutputBytes: 256,
                                          environmentOverrides: ["GIT_NO_REPLACE_OBJECTS":"1", "GIT_NO_LAZY_FETCH":"1"])
            let base = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard CheckSupport.matches(base, #"^(?:[0-9a-f]{40}|[0-9a-f]{64})$"#) else { throw InspectionError.blocked("The selected Git base did not resolve to one commit.") }
            selected = selected.map { check in
                check.id == RepositoryReleaseAgeChecks.id ? RepositoryReleaseAgeChecks.checks(base: base, record: { capture.record($0) })[0] : check
            }
        }
        var snapshot = try GitRepositoryScanner.scan(root, includeDetails: false)
        snapshot.fetchedAt = fetchedAt
        snapshot.fetchError = fetchError
        let report = await RepositoryIssueCatalog(checks: selected).inspect(snapshot, forceRefresh: true)
        return RepositoryCheckReport(report, head: head, checkerVersion: checkerVersion, skipped: skipped,
                                     dependencyComparison: capture.value, dependencyVulnerabilities: vulnerabilities.value)
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
