import Foundation
import XCTest
@testable import RepoManCore

final class RepositoryActionsPolicyTests: XCTestCase {
    private var root: URL!
    private let pin = String(repeating: "a", count: 40)
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RepoManActionsPolicy-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try GitRunner.run(["init", "-b", "main"], at: root)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testActionsPolicyIsRegisteredAsRemoteCheck() {
        let check = RepositoryIssueCatalog.standardChecks.first { $0.id == "ci.allowedActions" }
        XCTAssertNotNil(check)
        XCTAssertEqual(check?.requiresRemoteAccess, true)
    }
    func testExactSelectedPinPassesAndMissingEntryIsBlocked() async throws {
        try workflow(["actions/setup-node@" + pin])
        let allowed = await inspect(patterns: ["actions/setup-node@" + pin])
        XCTAssertEqual(allowed.status(for: "ci.allowedActions"), .passed)
        let blocked = await inspect(patterns: ["actions/checkout@" + pin])
        XCTAssertEqual(blocked.status(for: "ci.allowedActions"), .findings)
        XCTAssertTrue(blocked.findings().first?.evidence.contains("actions/setup-node@" + pin) == true)
        XCTAssertEqual(blocked.findings().first?.severity, .blocked)
    }
    func testWildcardsAndFinalNegativeExclusions() async throws {
        try workflow(["third-party/tool@" + pin])
        let wildcard = await inspect(patterns: ["third-party/*"])
        XCTAssertEqual(wildcard.status(for: "ci.allowedActions"), .passed)
        let denied = await inspect(patterns: ["*", "!third-party/tool@*"])
        XCTAssertEqual(denied.status(for: "ci.allowedActions"), .findings)
        let reordered = await inspect(patterns: ["!third-party/tool@*", "*"])
        XCTAssertEqual(reordered.status(for: "ci.allowedActions"), .incomplete)
    }
    func testOwnRepositoriesAndLocalActionsAreAllowed() async throws {
        try workflow(["owner/tool@" + pin, "./.github/actions/local", "$/local"])
        let report = await inspect(patterns: [])
        XCTAssertEqual(report.status(for: "ci.allowedActions"), .passed)
    }
    func testGitHubOwnedFlagAndPublicExclusion() async throws {
        try workflow(["actions/setup-node@" + pin])
        let allowed = await inspect(patterns: [], github: true)
        XCTAssertEqual(allowed.status(for: "ci.allowedActions"), .passed)
        let excluded = await inspect(patterns: ["!actions/setup-node@*"], github: true)
        XCTAssertEqual(excluded.status(for: "ci.allowedActions"), .findings)
    }
    func testVerifiedCreatorAndPrivateAccessStayUnknown() async throws {
        try workflow(["third-party/tool@" + pin])
        let verified = await inspect(patterns: [], verified: true)
        XCTAssertEqual(verified.status(for: "ci.allowedActions"), .incomplete)
        let privateSource = await inspect(patterns: ["*"], sourcePrivate: true)
        XCTAssertEqual(privateSource.status(for: "ci.allowedActions"), .incomplete)
    }
    func testSHARequirementAppliesToActionsButReusableTagsRemainPlatformLegal() async throws {
        try workflow(["actions/setup-node@v7"])
        let action = await inspect(mode: "all")
        XCTAssertEqual(action.status(for: "ci.allowedActions"), .findings)
        XCTAssertTrue(action.findings().first?.subject.hasSuffix("#pin") == true)
        try write(".github/workflows/ci.yml", "on: push\njobs:\n  call:\n    uses: other/project/.github/workflows/ci.yml@v1\n")
        let reusable = await inspect(mode: "all")
        XCTAssertEqual(reusable.status(for: "ci.allowedActions"), .passed)
    }
    func testDisabledActionsAreAConcreteBlock() async throws {
        try workflow(["actions/setup-node@" + pin])
        let report = await inspect(enabled: false)
        XCTAssertEqual(report.status(for: "ci.allowedActions"), .findings)
        XCTAssertTrue(report.findings().first?.subject.hasSuffix("#disabled") == true)
    }
    func testLocalOnlyBlocksExternalButAllowsOwner() async throws {
        try workflow(["actions/setup-node@" + pin])
        let external = await inspect(mode: "local_only")
        XCTAssertEqual(external.status(for: "ci.allowedActions"), .findings)
        try workflow(["owner/tool@" + pin])
        let own = await inspect(mode: "local_only")
        XCTAssertEqual(own.status(for: "ci.allowedActions"), .passed)
    }
    func testInheritedOrganizationPolicyIsIncompleteAndKeepsRepositoryBlocks() async throws {
        try workflow(["actions/setup-node@" + pin])
        let allowed = await inspect(mode: "all", organization: true)
        XCTAssertEqual(allowed.status(for: "ci.allowedActions"), .incomplete)
        let blocked = await inspect(patterns: [], organization: true)
        XCTAssertEqual(blocked.status(for: "ci.allowedActions"), .incomplete)
        XCTAssertEqual(blocked.findings().count, 1)
    }
    func testWorkflowLockfilesDoNotBecomeFalseDeclaredReferenceFindings() async throws {
        try workflow(["actions/setup-node@v7"])
        try write(".github/workflows/actions.lock", "version: 'v0.0.3'\n")
        let report = await inspect(patterns: [])
        XCTAssertEqual(report.status(for: "ci.allowedActions"), .incomplete)
        XCTAssertTrue(report.findings().isEmpty)
    }
    func testUnsupportedReferenceKeepsProvenBlockInSameWorkflow() async throws {
        try workflow(["actions/setup-node@" + pin, "${{ matrix.action }}"])
        let report = await inspect(patterns: [])
        XCTAssertEqual(report.status(for: "ci.allowedActions"), .incomplete)
        XCTAssertEqual(report.findings().count, 1)
    }
    func testProviderFailuresAndMalformedPoliciesDoNotLeakDiagnostics() async throws {
        try workflow(["actions/setup-node@" + pin])
        let unavailable = await report(FixtureAPI([:]))
        XCTAssertEqual(unavailable.status(for: "ci.allowedActions"), .incomplete)
        XCTAssertFalse(unavailable.unavailableChecks.values.joined().contains("private-error-canary"))
        let malformed = await report(FixtureAPI(["repos/owner/project/actions/permissions": Data("private-error-canary".utf8)]))
        XCTAssertEqual(malformed.status(for: "ci.allowedActions"), .incomplete)
        XCTAssertFalse(malformed.unavailableChecks.values.joined().contains("private-error-canary"))
        let unsupported = await inspect(mode: "future-mode")
        XCTAssertEqual(unsupported.status(for: "ci.allowedActions"), .incomplete)
    }
    func testUnknownPatternsAndDockerReferencesStayIncomplete() async throws {
        try workflow(["actions/setup-node@" + pin])
        let pattern = await inspect(patterns: ["actions/[a-z]*@*"])
        XCTAssertEqual(pattern.status(for: "ci.allowedActions"), .incomplete)
        try workflow(["docker://alpine:3.20"])
        let docker = await inspect(mode: "all")
        XCTAssertEqual(docker.status(for: "ci.allowedActions"), .incomplete)
    }
    func testReadOnlyRequestsAndDuplicateActionMetadataAreBounded() async throws {
        try workflow(["actions/setup-node@" + pin])
        try write(".github/workflows/other.yml", "on: push\njobs:\n  test:\n    steps:\n      - uses: actions/setup-node@\(pin)\n")
        let fixture = fixtures(patterns: ["actions/*"])
        let report = await report(fixture)
        XCTAssertEqual(report.status(for: "ci.allowedActions"), .passed)
        let calls = await fixture.calls
        XCTAssertEqual(calls.filter { $0.last == "repos/actions/setup-node" }.count, 1)
        XCTAssertTrue(calls.allSatisfy { $0.prefix(5) == ["api", "--hostname", "github.com", "--method", "GET"] })
    }
    func testRepeatedWildcardsRemainBoundedAndCaseSensitiveRefsDoNotMerge() async throws {
        let pattern = String(repeating: "*a", count: 100) + "b"
        try workflow(["third-party/tool@" + String(repeating: "a", count: 150)])
        let repeated = await inspect(patterns: [pattern])
        XCTAssertEqual(repeated.status(for: "ci.allowedActions"), .findings)
        try workflow(["actions/setup-node@Release"])
        let wrongCase = await inspect(patterns: ["actions/setup-node@release"])
        XCTAssertTrue(wrongCase.findings().contains { $0.subject.hasSuffix("#policy") })
    }
    func testUncommittedWorkflowAndLockInputsArePartOfThePreflight() async throws {
        try workflow(["actions/setup-node@v7"])
        _ = try GitRunner.run(["rm", "--cached", ".github/workflows/ci.yml"], at: root)
        let proposed = await inspect(patterns: [])
        XCTAssertFalse(proposed.findings().isEmpty)
        let lock = root.appendingPathComponent(".github/workflows/actions.lock")
        try "version: 'v0.0.3'\n".write(to: lock, atomically: true, encoding: .utf8)
        let locked = await inspect(patterns: [])
        XCTAssertEqual(locked.status(for: "ci.allowedActions"), .incomplete)
        XCTAssertTrue(locked.findings().isEmpty)
    }
    func testUnreadableWorkflowDoesNotDiscardAnotherKnownBlock() async throws {
        try workflow(["actions/setup-node@" + pin])
        let link = root.appendingPathComponent(".github/workflows/bad.yml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString))
        let report = await inspect(patterns: [])
        XCTAssertEqual(report.status(for: "ci.allowedActions"), .incomplete)
        XCTAssertEqual(report.findings().count, 1)
    }
    private func inspect(mode: String = "selected", patterns: [String] = [], enabled: Bool = true,
                         github: Bool = false, verified: Bool = false, organization: Bool = false,
                         sourcePrivate: Bool = false) async -> RepositoryInspectionReport {
        await report(fixtures(mode: mode, patterns: patterns, enabled: enabled, github: github,
                              verified: verified, organization: organization, sourcePrivate: sourcePrivate))
    }
    private func fixtures(mode: String = "selected", patterns: [String] = [], enabled: Bool = true,
                          github: Bool = false, verified: Bool = false, organization: Bool = false,
                          sourcePrivate: Bool = false) -> FixtureAPI {
        func data(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
        var documents = [
            "repos/owner/project/actions/permissions": data(["enabled": enabled, "allowed_actions": mode, "sha_pinning_required": true]),
            "repos/owner/project": data(["owner": ["login": "owner", "type": organization ? "Organization" : "User"]]),
            "repos/owner/project/actions/permissions/selected-actions": data(["github_owned_allowed": github, "verified_allowed": verified, "patterns_allowed": patterns])
        ]
        for name in ["actions/setup-node", "actions/checkout", "third-party/tool", "owner/tool"] {
            documents["repos/" + name] = data(["full_name": name, "private": sourcePrivate])
        }
        return FixtureAPI(documents)
    }
    private func report(_ fixture: FixtureAPI) async -> RepositoryInspectionReport {
        let snapshot = RepositorySnapshot(url: root, name: "fixture", branch: "main", upstream: nil,
            remoteURL: "https://github.com/owner/project.git", ahead: nil, behind: nil, changes: [],
            staleBranches: [], worktrees: [], commits: [], rootFiles: [".github"])
        return await RepositoryIssueCatalog(checks: RepositoryActionsPolicyChecks.checks(request: { args, timeout in
            XCTAssertGreaterThan(timeout, 0)
            XCTAssertLessThanOrEqual(timeout, 15)
            return try await fixture.load(args)
        })).inspect(snapshot)
    }
    private func workflow(_ references: [String]) throws {
        try write(".github/workflows/ci.yml", "on: push\njobs:\n  test:\n    steps:\n" + references.map { "      - uses: " + $0 }.joined(separator: "\n") + "\n")
    }
    private func write(_ path: String, _ source: String) throws {
        let target = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try source.write(to: target, atomically: true, encoding: .utf8)
        _ = try GitRunner.run(["add", "--", path], at: root)
    }
    private actor FixtureAPI {
        let documents: [String: Data]; var calls: [[String]] = []
        init(_ documents: [String: Data]) { self.documents = documents }
        func load(_ args: [String]) throws -> Data {
            calls.append(args)
            guard let path = args.last, let value = documents[path] else { throw InspectionError.blocked("private-error-canary") }
            return value
        }
    }
}
