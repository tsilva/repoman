import Foundation
import XCTest
@testable import RepoManCore

final class RepositoryCIChecksTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RepoManCI-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testNoWorkflowsAndReleaseOrDependencyReviewOnlyHaveMissingCoverage() async throws {
        let catalog = coverageCatalog()
        var report = await catalog.inspect(snapshot())
        XCTAssertEqual(report.findings().map(\.checkID), ["ci.coverage"])
        try workflow("release.yml", """
        on:
          push:
            tags: ['v*']
        jobs:
          release:
            steps:
              - run: swift test
        """)
        try workflow("dependencies.yaml", """
        on: [push, pull_request]
        jobs:
          dependencies:
            steps:
              - uses: actions/checkout@sha
              - uses: actions/dependency-review-action@sha
        """)
        report = await catalog.inspect(snapshot())
        XCTAssertEqual(report.findings().count, 1)
        XCTAssertTrue(report.findings()[0].evidence.contains("release.yml"))
        XCTAssertTrue(report.unavailableChecks.isEmpty)
    }

    func testValidationCommandsOnRoutineEventsProvideCoverage() {
        let commands = ["uv run pytest", "uv run --frozen --group dev pytest", "pnpm exec tsc --noEmit", "bunx --no-install tsc --noEmit", "bun x --no-install tsc --noEmit", "pnpm run typecheck", "npm test", "swift test", "xcodebuild -scheme App build",
            "cargo clippy", "go test ./...", "python -m unittest", "ruff check .", "pnpm lint && pnpm build", "make test", "bash tools/check.sh"]
        for command in commands {
            XCTAssertEqual(WorkflowCoverage.analyze("""
            on:
              pull_request:
              push:
                branches: [main]
            jobs:
              validate:
                steps:
                  - uses: actions/checkout@sha
                  - run: |
                      \(command)
            """), .covered, command)
        }
    }

    func testTriggerVariantsAndManualOnlyWorkflows() {
        for trigger in ["push", "[push, pull_request]", "\n  pull_request:", "\n  push:\n    paths: ['src/**']"] {
            XCTAssertEqual(WorkflowCoverage.analyze("on: \(trigger)\njobs:\n  tests:\n    steps:\n      - run: npm test"), .covered, trigger)
        }
        for trigger in ["workflow_dispatch", "[workflow_dispatch, schedule]", "\n  push:\n    tags: ['v*']", "\n  push:\n    tags-ignore: ['v*']"] {
            XCTAssertEqual(WorkflowCoverage.analyze("on: \(trigger)\njobs:\n  tests:\n    steps:\n      - run: npm test"), .missing, trigger)
        }
        XCTAssertEqual(WorkflowCoverage.analyze("'on': [push]\njobs:\n  test:\n    steps:\n      - run: swift test"), .covered)
    }

    func testLabelsEchoAndCommentsDoNotCountAsValidation() {
        XCTAssertEqual(WorkflowCoverage.analyze("""
        name: Build and test
        on: push
        jobs:
          tests:
            name: pytest
            steps:
              - uses: actions/setup-python@sha
              # - run: pytest
              - run: |
                  # npm test
                  echo 'swift test'
                  printf 'pytest'
                  echo 'bunx --no-install tsc --noEmit'
                  pip install -r requirements.txt
                  pip install -r requirements.txt # && pytest
        """), .missing)
    }

    func testCustomExecutionAndUnsupportedYAMLStayUnknown() {
        for job in ["    uses: owner/repo/.github/workflows/ci.yml@main", "    steps:\n      - run: ./tools/verify-custom",
                    "    steps:\n      - uses: owner/custom-check@sha", "    steps:\n      - uses: actions/github-script@sha", "    <<: *template"] {
            XCTAssertEqual(WorkflowCoverage.analyze("on: push\njobs:\n  validate:\n" + job), .unknown, job)
        }
        XCTAssertEqual(WorkflowCoverage.analyze("on: {push: {branches: [main]}}\njobs: {}"), .unknown)
        XCTAssertEqual(WorkflowCoverage.analyze("broken YAML"), .unknown)
    }

    func testDocsOnlyAndExternalCIProjectsDoNotGetMissingCoverageFinding() async {
        var report = await coverageCatalog().inspect(snapshot(files: ["README.md"]))
        XCTAssertTrue(report.findings().isEmpty)
        XCTAssertTrue(report.unavailableChecks.isEmpty)
        report = await coverageCatalog().inspect(snapshot(files: ["pyproject.toml", ".gitlab-ci.yml"]))
        XCTAssertTrue(report.findings().isEmpty)
        XCTAssertNotNil(report.unavailableChecks["ci.coverage"])
    }

    func testUnknownFilesAndEscapingWorkflowDirectoryRemainUnavailable() async throws {
        var report = await coverageCatalog().inspect(snapshot(files: nil))
        XCTAssertNotNil(report.unavailableChecks["ci.coverage"])
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".github"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".github/workflows"), withDestinationURL: root.deletingLastPathComponent())
        report = await coverageCatalog().inspect(snapshot())
        XCTAssertTrue(report.findings().isEmpty)
        XCTAssertNotNil(report.unavailableChecks["ci.coverage"])
    }

    func testAddingRoutineValidationResolvesCoverageFinding() async throws {
        let catalog = coverageCatalog()
        let before = await catalog.inspect(snapshot())
        let finding = try XCTUnwrap(before.findings().first)
        try workflow("ci.yml", "on: pull_request\njobs:\n  test:\n    steps:\n      - run: uv run pytest")
        let after = await catalog.inspect(snapshot())
        if case .absent = catalog.verify(finding, in: after) {} else { XCTFail("Coverage was not verified") }
        XCTAssertEqual(RepairRecipeCatalog().recipes(for: finding).map(\.id), ["ci.coverage"])
    }

    func testBunTypecheckWithNoInstallResolvesCoverageDespiteSetupAction() async throws {
        let catalog = coverageCatalog()
        let before = await catalog.inspect(snapshot())
        let finding = try XCTUnwrap(before.findings().first)
        try workflow("ci.yml", """
        on:
          push:
            branches: ['**']
          pull_request:
          merge_group:
        jobs:
          typecheck:
            steps:
              - uses: actions/checkout@sha
              - uses: oven-sh/setup-bun@sha
              - run: bun install --frozen-lockfile --ignore-scripts
              - run: bunx --no-install tsc --noEmit
        """)
        let after = await catalog.inspect(snapshot())
        XCTAssertTrue(after.unavailableChecks.isEmpty)
        if case .absent = catalog.verify(finding, in: after) {} else { XCTFail("Bun typecheck was not recognized as CI coverage") }
    }

    func testFailedCIIdentitySurvivesNewCommitsAndPendingNeverResolvesIt() async throws {
        let fixture = StatusFixture()
        let catalog = RepositoryIssueCatalog(checks: [RepositoryCIChecks.checks(loadStatus: { _ in await fixture.status() })[0]])
        let before = await catalog.inspect(snapshot(remote: "git@github.com:owner/project.git"))
        let finding = try XCTUnwrap(before.findings().first)
        XCTAssertEqual(finding.severity, .blocked)
        XCTAssertEqual(finding.detailsURL?.absoluteString, "https://github.com/owner/project/actions/runs/1")
        XCTAssertTrue(finding.evidence.contains("main"))
        await fixture.set("IN_PROGRESS", sha: "bbbbbbbb", branch: "feature")
        var after = await catalog.inspect(snapshot(remote: "git@github.com:owner/project.git"))
        XCTAssertNotNil(after.unavailableChecks["ci.failing"])
        if case .unknown = catalog.verify(finding, in: after) {} else { XCTFail("Pending CI resolved a failure") }
        await fixture.set("FAILURE", sha: "bbbbbbbb", branch: "feature")
        after = await catalog.inspect(snapshot(remote: "git@github.com:owner/project.git"))
        XCTAssertEqual(after.findings().first?.id, finding.id)
        await fixture.set("SUCCESS", sha: "cccccccc", branch: "feature")
        after = await catalog.inspect(snapshot(remote: "git@github.com:owner/project.git"))
        if case .absent = catalog.verify(finding, in: after) {} else { XCTFail("Passing CI did not resolve") }
    }

    func testEmptyCancelledAndAuthenticationFailuresRemainUnavailable() async {
        for checks in [[], [CICheckStatus(name: "tests", result: "CANCELLED", url: nil)]] {
            let catalog = RepositoryIssueCatalog(checks: [RepositoryCIChecks.checks(loadStatus: { _ in
                [CIBranchStatus(name: "main", sha: "aaaa", checks: checks)]
            })[0]])
            let report = await catalog.inspect(snapshot(remote: "https://github.com/owner/project"))
            XCTAssertTrue(report.findings().isEmpty)
            XCTAssertNotNil(report.unavailableChecks["ci.failing"])
        }
        let catalog = RepositoryIssueCatalog(checks: [RepositoryCIChecks.checks(loadStatus: { _ in
            throw RepairError.blocked("Authentication failed")
        })[0]])
        let report = await catalog.inspect(snapshot(remote: "https://github.com/owner/project"))
        XCTAssertEqual(report.unavailableChecks["ci.failing"], "Authentication failed")
        let local = await catalog.inspect(snapshot())
        XCTAssertTrue(local.unavailableChecks.isEmpty)
    }

    func testGitHubRemoteFormatsAndUnsupportedHosts() {
        for url in ["git@github.com:owner/project.git", "https://github.com/owner/project", "ssh://git@github.com/owner/project.git"] {
            XCTAssertEqual(GitHubCI.repository(url), GitHubCI.Repository(owner: "owner", name: "project"))
        }
        for url in ["/tmp/repo.git", "git@gitlab.com:owner/project.git", "https://github.com/owner/project/extra"] {
            XCTAssertNil(GitHubCI.repository(url))
        }
    }

    func testGraphQLDecodesBothKindsAndUsesLatestRerunOnExactBranchCommit() throws {
        let nodes: [[String: Any]] = [
            checkNode("FAILURE", started: "2026-09-29T01:00:00Z"), checkNode("SUCCESS", started: "2026-09-30T01:00:00Z"),
            ["__typename": "StatusContext", "context": "external-ci", "state": "FAILURE", "createdAt": "2026-09-30T01:00:00Z", "targetUrl": "https://ci.example.com/run/1"]
        ]
        let branches = try GitHubCI.decode(response(nodes: nodes))
        XCTAssertEqual(branches.count, 1)
        XCTAssertEqual(branches[0].sha, "1234567890abcdef")
        XCTAssertEqual(branches[0].checks.filter(\.failed).map(\.name), ["external-ci"])
        XCTAssertTrue(branches[0].checks.allSatisfy(\.finished))
    }

    func testGraphQLErrorsPaginationAndMissingTrackedBranchStayUnknown() throws {
        XCTAssertThrowsError(try GitHubCI.decode(response(nodes: [], hasNextPage: true)))
        XCTAssertThrowsError(try GitHubCI.decode(response(nodes: [], current: false), requiresCurrentBranch: true))
        XCTAssertThrowsError(try GitHubCI.decode(Data(#"{"data":null,"errors":[{"message":"rate limited"}]}"#.utf8)))
        XCTAssertThrowsError(try GitHubCI.decode(Data(#"{"data":{"repository":null}}"#.utf8)))
        XCTAssertThrowsError(try GitHubCI.decode(Data("not JSON".utf8)))
    }

    func testNewerStatusAndQueuedRerunReplaceOldFailures() throws {
        let statuses: [[String: Any]] = [
            ["__typename": "StatusContext", "context": "ci", "state": "FAILURE", "createdAt": "2026-09-29T01:00:00Z"],
            ["__typename": "StatusContext", "context": "ci", "state": "SUCCESS", "createdAt": "2026-09-30T01:00:00Z"]
        ]
        XCTAssertEqual(try GitHubCI.decode(response(nodes: statuses))[0].checks.first?.result, "SUCCESS")
        var queued = checkNode("", started: "")
        queued["status"] = "QUEUED"
        queued["startedAt"] = NSNull()
        queued["conclusion"] = NSNull()
        let old = checkNode("FAILURE", started: "2026-09-30T01:00:00Z")
        for nodes in [[old, queued], [queued, old]] {
            let check = try XCTUnwrap(GitHubCI.decode(response(nodes: nodes))[0].checks.first)
            XCTAssertEqual(check.result, "QUEUED")
            XCTAssertFalse(check.finished)
        }
    }

    func testLatestWorkflowRunWinsEvenIfOlderRunStartedLater() throws {
        var old = checkNode("FAILURE", started: "2026-09-30T02:00:00Z")
        old["checkSuite"] = ["app": ["slug": "github-actions"], "workflowRun": ["runNumber": 1, "event": "push", "workflow": ["name": "CI"]]]
        var new = checkNode("SUCCESS", started: "2026-09-30T01:00:00Z")
        new["checkSuite"] = ["app": ["slug": "github-actions"], "workflowRun": ["runNumber": 2, "event": "push", "workflow": ["name": "CI"]]]
        XCTAssertEqual(try GitHubCI.decode(response(nodes: [new, old]))[0].checks.first?.result, "SUCCESS")
    }

    func testSummaryScanUsesTrackedRemoteRatherThanOrigin() throws {
        _ = try GitRunner.run(["init", "-b", "main"], at: root)
        _ = try GitRunner.run(["remote", "add", "origin", "https://github.com/owner/other.git"], at: root)
        _ = try GitRunner.run(["remote", "add", "upstream", "git@github.com:owner/project.git"], at: root)
        _ = try GitRunner.run(["config", "branch.main.remote", "upstream"], at: root)
        XCTAssertEqual(try GitRepositoryScanner.scan(root, includeDetails: false).remoteURL, "git@github.com:owner/project.git")
    }

    func testFindingURLRoundTripsAndLegacyStoredFindingsDecode() throws {
        let finding = RepositoryFinding(repositoryID: "repo", checkID: "ci.failing", title: "CI failing", evidence: "failure",
            category: .ci, symbol: "xmark", detailsURL: URL(string: "https://github.com/owner/project/actions"))
        let data = try JSONEncoder().encode(finding)
        XCTAssertEqual(try JSONDecoder().decode(RepositoryFinding.self, from: data), finding)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "detailsURL")
        XCTAssertNil(try JSONDecoder().decode(RepositoryFinding.self, from: JSONSerialization.data(withJSONObject: legacy)).detailsURL)
    }

    func testCLITimeoutIsBoundedWhenProcessIgnoresTermination() throws {
        let script = root.appendingPathComponent("gh-fixture")
        try "#!/bin/sh\ntrap '' TERM\nwhile :; do :; done\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let start = Date()
        XCTAssertThrowsError(try GitHubCLI.run([], executable: script, timeout: 0.1)) { error in
            XCTAssertTrue(error.localizedDescription.contains("timed out"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }

    private func coverageCatalog() -> RepositoryIssueCatalog { RepositoryIssueCatalog(checks: [RepositoryCIChecks.checks()[1]]) }
    private func snapshot(files: [String]? = ["pyproject.toml"], remote: String? = nil) -> RepositorySnapshot {
        RepositorySnapshot(url: root, name: "project", branch: "main", upstream: nil, remoteURL: remote,
            ahead: nil, behind: nil, changes: [], staleBranches: [], worktrees: [], commits: [], rootFiles: files)
    }
    private func workflow(_ name: String, _ text: String) throws {
        let directory = root.appendingPathComponent(".github/workflows")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    private func checkNode(_ conclusion: String, started: String) -> [String: Any] {
        ["__typename": "CheckRun", "name": "tests", "status": "COMPLETED", "conclusion": conclusion, "startedAt": started,
         "checkSuite": ["app": ["slug": "github-actions"], "workflowRun": ["workflow": ["name": "CI"]]]]
    }
    private func response(nodes: [[String: Any]], hasNextPage: Bool = false, current: Bool = true) throws -> Data {
        let branch: [String: Any] = ["name": "main", "target": ["oid": "1234567890abcdef", "statusCheckRollup": ["contexts": [
            "nodes": nodes, "pageInfo": ["hasNextPage": hasNextPage]]]]]
        return try JSONSerialization.data(withJSONObject: ["data": ["repository": ["defaultBranchRef": branch,
            "currentBranch": current ? branch as Any : NSNull()]]])
    }
}

private actor StatusFixture {
    private var result = "FAILURE", sha = "aaaaaaaa", branch = "main"
    func set(_ result: String, sha: String, branch: String) { self.result = result; self.sha = sha; self.branch = branch }
    func status() -> [CIBranchStatus] {
        [CIBranchStatus(name: branch, sha: sha, checks: [CICheckStatus(name: "tests", result: result,
            url: URL(string: "https://github.com/owner/project/actions/runs/1"))])]
    }
}
