import Foundation
import XCTest
@testable import RepoManCore

final class RepositoryMaintenanceGapsTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RepoManGaps-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-b", "main"])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testDisabledJobsStepsAndDependenciesNeverEstablishCoverage() {
        for guardValue in ["false", "${{ false }}", "'false'"] {
            XCTAssertEqual(WorkflowCoverage.analyze(workflow(job: "    if: \(guardValue)\n    steps:\n      - run: swift test")), .missing)
            for step in ["      - if: \(guardValue)\n        run: swift test", "      - run: swift test\n        if: \(guardValue)"] {
                XCTAssertEqual(WorkflowCoverage.analyze(workflow(job: "    steps:\n" + step)), .missing)
            }
        }
        XCTAssertEqual(WorkflowCoverage.analyze(workflow(job: "    if: ${{ github.event_name == 'push' }}\n    steps:\n      - run: swift test")), .unknown)
        XCTAssertEqual(WorkflowCoverage.analyze(workflow(job: "    steps:\n      - run: swift test\n        if: ${{ inputs.validate }}")), .unknown)
        let skipped = workflow(job: "    if: false\n    steps:\n      - run: echo setup")
        XCTAssertEqual(WorkflowCoverage.analyze(skipped + "\n  validate:\n    needs: test\n    steps:\n      - run: swift test"), .missing)
        XCTAssertEqual(WorkflowCoverage.analyze(skipped + "\n  validate:\n    steps:\n      - run: swift test"), .covered)
        XCTAssertEqual(WorkflowCoverage.analyze(workflow(job: "    if: true\n    steps:\n      - if: ${{ true }}\n        run: swift test")), .covered)
        let enabled = workflow(job: "    steps:\n      - run: echo setup")
        XCTAssertEqual(WorkflowCoverage.analyze(enabled + "\n  validate:\n    needs: [test]\n    steps:\n      - run: swift test"), .covered)
        XCTAssertEqual(WorkflowCoverage.analyze(enabled + "\n  validate:\n    needs: missing\n    steps:\n      - run: swift test"), .unknown)
        XCTAssertEqual(WorkflowCoverage.analyze(workflow(job: "    needs: test\n    steps:\n      - run: swift test")), .unknown)
    }
    func testTrackedGeneratedDirectoriesAndIntentionalAssets() async throws {
        let paths = [".build/debug/cache", "web/.next/server/cache", "nested/.ruff_cache/cache", ".venv/control", "dist/logo.svg", "src/next.swift"]
        for path in paths { try write(path, "fixture") }
        try write(".gitignore", ".build/\n.next/\n.ruff_cache/\n")
        try git(["add", "--force", "."])
        var report = try await inspect("files.generatedTracked")
        XCTAssertEqual(Set(report.findings().map(\.subject)), Set(paths.prefix(4)))
        try write(".repoman.json", #"{"version":1,"exceptions":{"files.generatedTracked":{".build/debug/cache":"Intentional fixture"}}}"#)
        report = try await inspect("files.generatedTracked")
        XCTAssertFalse(report.findings().contains { $0.subject == ".build/debug/cache" })
        XCTAssertTrue(report.unavailableChecks.isEmpty)
    }
    func testValidAccessUnboundProfilesAndPrivateCompleteLocalOverride() async throws {
        try write(".access.toml", shared)
        var report = try await inspect("access.configuration")
        XCTAssertTrue(report.findings().isEmpty)
        XCTAssertTrue(report.unavailableChecks.isEmpty)
        try write(".access.local.toml", binding)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent(".access.local.toml").path)
        try write(".gitignore", "/.access.local.toml\n")
        for id in ["access.configuration", "access.localPrivacy"] {
            report = try await inspect(id)
            XCTAssertTrue(report.findings().isEmpty, id)
            XCTAssertTrue(report.unavailableChecks.isEmpty, id)
        }
    }
    func testInvalidAccessSchemaAndValuesNeverLeak() async throws {
        for content in [shared.replacingOccurrences(of: "version = 1", with: "version = true"),
                        shared.replacingOccurrences(of: "['API_KEY']", with: "['API_KEY', 'API_KEY']"),
                        shared + "\n[bindings.tool]\nprovider = 'secret-canary'\n",
                        shared + "\n[unexpected]\nsecret = 'secret-canary'\n"] {
            try write(".access.toml", content)
            let report = try await inspect("access.configuration")
            XCTAssertFalse(report.findings().isEmpty)
            XCTAssertFalse(report.findings().map(\.evidence).joined().contains("secret-canary"))
        }
        // A valid local replacement cannot hide an invalid shared binding.
        try write(".access.toml", shared + binding.replacingOccurrences(of: "version = 1", with: "").replacingOccurrences(of: "infisical", with: "unsupported"))
        try write(".access.local.toml", binding)
        let report = try await inspect("access.configuration")
        XCTAssertFalse(report.findings().isEmpty)
        try write(".access.toml", shared)
        try write(".access.local.toml", "version = 1\n[bindings.tool]\nprovider = 'infisical'")
        let partial = try await inspect("access.configuration")
        XCTAssertTrue(partial.findings().first?.evidence.contains("whole shared bindings") == true)
    }
    func testLocalAccessMissingSharedTrackedPermissionsAndEscapingSymlink() async throws {
        try write(".access.local.toml", binding)
        var report = try await inspect("access.configuration")
        XCTAssertFalse(report.findings().isEmpty)
        try git(["add", ".access.local.toml"])
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: root.appendingPathComponent(".access.local.toml").path)
        report = try await inspect("access.localPrivacy")
        let evidence = try XCTUnwrap(report.findings().first).evidence
        for text in ["tracked", "not ignored", "0600"] { XCTAssertTrue(evidence.contains(text)) }
        try FileManager.default.removeItem(at: root.appendingPathComponent(".access.local.toml"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".access.local.toml"), withDestinationURL: root.deletingLastPathComponent().appendingPathComponent("external-access"))
        report = try await inspect("access.localPrivacy")
        XCTAssertTrue(report.findings().first?.evidence.contains("symbolic link") == true)
    }
    func testKnownSharedAccessProblemsSurviveUnsupportedLocalSyntax() async throws {
        try write(".access.toml", shared.replacingOccurrences(of: "version = 1", with: "version = true"))
        try write(".access.local.toml", "version = 1\n[bindings.\"tool\"]\nprovider = 'secret-canary'\n")
        let report = try await inspect("access.configuration")
        XCTAssertFalse(report.findings().isEmpty)
        XCTAssertNotNil(report.unavailableChecks["access.configuration"])
        XCTAssertFalse(report.unavailableChecks.values.joined().contains("secret-canary"))
    }
    func testUnsupportedAccessSyntaxIsIncompleteWithoutValues() async throws {
        try write(".access.toml", "version = 1\n[profiles.\"tool\"]\ndescription = '''secret-canary'''\n")
        let report = try await inspect("access.configuration")
        XCTAssertNotNil(report.unavailableChecks["access.configuration"])
        XCTAssertFalse(report.unavailableChecks.values.joined().contains("secret-canary"))
    }
    func testDependabotPaginationSeveritiesAndReadOnlyRequest() async throws {
        let first = page(alerts: [alert(1, "CRITICAL")], total: 2, next: "cursor-one")
        let last = page(alerts: [alert(2, "LOW")], total: 2)
        let loader = Pages([first, last])
        let report = await alertReport(loader)
        XCTAssertEqual(report.findings().count, 2)
        XCTAssertTrue(report.unavailableChecks.isEmpty)
        XCTAssertEqual(Set(report.findings().map(\.severity)), [.blocked, .attention])
        let requests = await loader.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[1].contains("cursor=cursor-one"))
        XCTAssertTrue(requests.allSatisfy { $0.prefix(2) == ["api", "graphql"] && $0.contains("github.com") && !$0.joined().contains("mutation") })
        XCTAssertTrue(RepositoryDependabotChecks.checks()[0].requiresRemoteAccess)
    }
    func testDependabotDisabledUnavailableMalformedAndEmpty() async throws {
        for data in [page(alerts: [], total: 0, enabled: false), Data(#"{"errors":[{"message":"secret-canary"}]}"#.utf8),
                     Data(#"{"data":{"repository":null}}"#.utf8), Data("malformed".utf8),
                     page(alerts: [NSNull()], total: 1), page(alerts: [alert(1, "UNKNOWN")], total: 1)] {
            let report = await alertReport(Pages([data]))
            XCTAssertNotNil(report.unavailableChecks[RepositoryDependabotChecks.id])
            XCTAssertFalse(report.unavailableChecks.values.joined().contains("secret-canary"))
        }
        let empty = await alertReport(Pages([page(alerts: [], total: 0)]))
        XCTAssertTrue(empty.findings().isEmpty)
        XCTAssertTrue(empty.unavailableChecks.isEmpty)
        let denied = await alertReport(Pages([]))
        XCTAssertNotNil(denied.unavailableChecks[RepositoryDependabotChecks.id])
        XCTAssertFalse(denied.unavailableChecks.values.joined().contains("secret-canary"))
    }
    func testDependabotPartialFailuresCountMismatchAndRepeatedCursorRetainKnownAlerts() async throws {
        let first = page(alerts: [alert(1, "HIGH")], total: 2, next: "cursor-one")
        for pages in [[first], [first, page(alerts: [alert(2, "LOW")], total: 2, next: "cursor-one")],
                      [first, page(alerts: [alert(1, "HIGH")], total: 2)], [page(alerts: [alert(1, "HIGH")], total: 2)]] {
            let report = await alertReport(Pages(pages))
            XCTAssertFalse(report.findings().isEmpty)
            XCTAssertNotNil(report.unavailableChecks[RepositoryDependabotChecks.id])
        }
        let pages = (1...10).map { page(alerts: [alert($0, "LOW")], total: 11, next: "cursor-\($0)") }
        let bounded = await alertReport(Pages(pages))
        XCTAssertEqual(bounded.findings().count, 10)
        XCTAssertTrue(bounded.unavailableChecks.values.joined().contains("10 pages"))
    }
    private func workflow(job: String) -> String { "on: [push, pull_request]\njobs:\n  test:\n" + job }
    private var shared: String { "version = 1\n[profiles.tool]\ndescription = 'Standalone tooling'\nvariables = ['API_KEY']\n" }
    private var binding: String { """
        version = 1
        [bindings.tool]
        provider = 'infisical'
        instance = 'https://example.com'
        project_id = '00000000-0000-4000-8000-000000000000'
        environment = 'dev'
        path = '/tool'
        """ }
    private func snapshot(remote: String? = nil) throws -> RepositorySnapshot {
        RepositorySnapshot(url: root, name: "fixture", branch: "main", upstream: nil, remoteURL: remote, ahead: nil, behind: nil,
            changes: [], staleBranches: [], worktrees: [], commits: [], checkedAt: Date(), rootFiles: try FileManager.default.contentsOfDirectory(atPath: root.path))
    }
    private func inspect(_ id: String) async throws -> RepositoryInspectionReport {
        await RepositoryIssueCatalog(checks: RepositoryIssueCatalog.standardChecks.filter { $0.id == id }).inspect(try snapshot())
    }
    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    private func git(_ arguments: [String]) throws { _ = try GitRunner.run(arguments, at: root) }
    private func alertReport(_ pages: Pages) async -> RepositoryInspectionReport {
        await RepositoryIssueCatalog(checks: RepositoryDependabotChecks.checks(request: { try await pages.load($0) })).inspect(try! snapshot(remote: "git@github.com:owner/project.git"))
    }
    private func alert(_ number: Int, _ severity: String) -> [String: Any] {
        ["number": number, "state": "OPEN", "vulnerableManifestPath": "uv.lock", "securityAdvisory": ["ghsaId": "GHSA-xxxx-yyyy-zzzz", "severity": severity],
         "securityVulnerability": ["package": ["name": "fixture-package", "ecosystem": "PIP"]]]
    }
    private func page(alerts: [Any], total: Int, next: String? = nil, enabled: Bool = true) -> Data {
        try! JSONSerialization.data(withJSONObject: ["data": ["repository": ["hasVulnerabilityAlertsEnabled": enabled,
            "vulnerabilityAlerts": ["totalCount": total, "nodes": alerts, "pageInfo": ["hasNextPage": next != nil, "endCursor": next as Any? ?? NSNull()]]]]])
    }
    private actor Pages {
        var pages: [Data]; var requests: [[String]] = []
        init(_ pages: [Data]) { self.pages = pages }
        func load(_ request: [String]) throws -> Data {
            requests.append(request)
            guard !pages.isEmpty else { throw InspectionError.blocked("secret-canary") }
            return pages.removeFirst()
        }
    }
}
