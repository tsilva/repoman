import Foundation

enum RepositoryDependabotChecks {
    typealias Request = @Sendable ([String]) async throws -> Data
    static let id = "github.dependabotAlerts"
    static let query = """
    query($owner: String!, $name: String!, $cursor: String) {
      repository(owner: $owner, name: $name) {
        hasVulnerabilityAlertsEnabled
        vulnerabilityAlerts(first: 100, states: [OPEN], after: $cursor) {
          totalCount
          pageInfo { hasNextPage endCursor }
          nodes {
            number state vulnerableManifestPath
            securityAdvisory { ghsaId severity }
            securityVulnerability { package { name ecosystem } }
          }
        }
      }
    }
    """
    static func checks(request: @escaping Request = { arguments in
        try await Task.detached(priority: .utility) { try GitHubCLI.run(arguments) }.value
    }) -> [RepositoryCheck] {
        [RepositoryCheck(id: id, title: "Open Dependabot security alerts", category: .setup, symbol: "exclamationmark.shield", evaluate: { context in
            guard let repository = GitHubCI.repository(context.snapshot.remoteURL) else { return .findings([]) }
            let policy = try RepositoryCheckPolicy.load(context)
            var findings: [RepositoryFinding] = [], seen = Set<Int>(), cursors = Set<String>()
            var cursor: String?, expected: Int?
            let deadline = Date().addingTimeInterval(60)
            func incomplete(_ reason: String) -> RepositoryCheckResult {
                .partial(context.applyingExceptions(findings, policy: policy), reason)
            }
            for _ in 0..<10 {
                guard Date() < deadline else { return incomplete("Dependabot alert inspection reached its time limit; retained alerts are only a partial inventory.") }
                var arguments = ["api", "graphql", "--hostname", "github.com", "-f", "query=" + query,
                                 "-f", "owner=" + repository.owner, "-f", "name=" + repository.name]
                if let cursor { arguments += ["-f", "cursor=" + cursor] }
                let data: Data
                do { data = try await request(arguments) }
                catch { return incomplete("Dependabot alerts could not be read. Check gh authentication, security-alert access, API limits and connectivity. No alert-free result was established.") }
                let response: Response
                do { response = try JSONDecoder().decode(Response.self, from: data) }
                catch { return incomplete("GitHub returned an unsupported Dependabot response; alert coverage is incomplete.") }
                guard response.errors?.isEmpty != false, let repo = response.data?.repository,
                      let alerts = repo.vulnerabilityAlerts else {
                    return incomplete("GitHub did not provide complete Dependabot data. Repository or security-alert access may be unavailable.")
                }
                guard repo.hasVulnerabilityAlertsEnabled else { return incomplete("Dependabot alerts are disabled on GitHub; security-alert coverage could not be verified.") }
                guard alerts.nodes.count <= 100, alerts.totalCount >= 0,
                      expected == nil || expected == alerts.totalCount else {
                    return incomplete("Dependabot alert inventory changed during pagination or exceeded the response bounds. Refresh to obtain a consistent inventory.")
                }
                expected = alerts.totalCount
                for alert in alerts.nodes {
                    guard let alert, alert.number > 0, seen.insert(alert.number).inserted, alert.state == "OPEN",
                          let advisory = alert.securityAdvisory,
                          ["LOW", "MODERATE", "HIGH", "CRITICAL"].contains(advisory.severity),
                          CheckSupport.matches(advisory.ghsaId, #"^GHSA-[A-Za-z0-9-]+$"#),
                          let package = alert.securityVulnerability?.package,
                          safe(package.name), safe(package.ecosystem), safe(alert.vulnerableManifestPath) else {
                        return incomplete("Dependabot returned missing, duplicate or unsupported alert data. Known alerts are retained; the inventory is incomplete.")
                    }
                    let subject = repository.owner + "/" + repository.name + "#" + String(alert.number)
                    findings.append(RepositoryFinding(repositoryID: context.snapshot.id, checkID: id, subject: subject,
                        title: "Open Dependabot security alert #\(alert.number)",
                        evidence: "GitHub reports an open \(advisory.severity.lowercased()) alert for \(package.name) (\(package.ecosystem)) in \(alert.vulnerableManifestPath): \(advisory.ghsaId). This describes GitHub's published dependency graph, not an audit of uncommitted files or proof of exploitability. Review the advisory and upgrade path before editing dependencies.",
                        category: .setup, severity: ["HIGH", "CRITICAL"].contains(advisory.severity) ? .blocked : .attention,
                        symbol: "exclamationmark.shield", detailsURL: URL(string: "https://github.com/\(repository.owner)/\(repository.name)/security/dependabot/\(alert.number)")))
                }
                if !alerts.pageInfo.hasNextPage {
                    guard seen.count == alerts.totalCount else { return incomplete("GitHub's alert count did not match the retrieved inventory. Refresh to verify all open alerts.") }
                    return .findings(context.applyingExceptions(findings, policy: policy))
                }
                guard !alerts.nodes.isEmpty, let next = alerts.pageInfo.endCursor, !next.isEmpty, next.utf8.count <= 2048, cursors.insert(next).inserted else {
                    return incomplete("Dependabot pagination did not advance; the retained alert inventory is incomplete.")
                }
                cursor = next
            }
            return incomplete("Dependabot inspection reached its limit of 10 pages (1,000 alerts). Known alerts are retained; further alerts need review.")
        })]
    }
    private static func safe(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 512 && !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    private struct Response: Decodable { let data: Payload?; let errors: [APIError]? }
    private struct APIError: Decodable {} // Never surface server-controlled diagnostics.
    private struct Payload: Decodable { let repository: Repository? }
    private struct Repository: Decodable { let hasVulnerabilityAlertsEnabled: Bool; let vulnerabilityAlerts: Alerts? }
    private struct Alerts: Decodable { let nodes: [Alert?]; let totalCount: Int; let pageInfo: PageInfo }
    private struct PageInfo: Decodable { let hasNextPage: Bool; let endCursor: String? }
    private struct Alert: Decodable {
        let number: Int; let state: String; let vulnerableManifestPath: String
        let securityAdvisory: Advisory?; let securityVulnerability: Vulnerability?
    }
    private struct Advisory: Decodable { let ghsaId: String; let severity: String }
    private struct Vulnerability: Decodable { let package: Package? }
    private struct Package: Decodable { let name: String; let ecosystem: String }
}
