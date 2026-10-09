import Foundation
import XCTest
@testable import RepoManCore

final class RepositoryVisibilityChecksTests: XCTestCase {
    private let checkID = "github.privateVisibility"
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RepoManVisibility-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func snapshot(_ remote: String? = "git@github.com:owner/private-project.git", name: String = "local-alias") -> RepositorySnapshot {
        RepositorySnapshot(url: root, name: name, branch: "main", upstream: nil, remoteURL: remote,
            ahead: nil, behind: nil, changes: [], staleBranches: [], worktrees: [], commits: [], rootFiles: [])
    }
    private func catalog(_ load: RepositoryMetadataChecks.VisibilityLoader? = nil) -> RepositoryIssueCatalog {
        RepositoryIssueCatalog(checks: RepositoryMetadataChecks.checks(loadVisibility: load).filter { $0.id == checkID })
    }

    func testPublicAndInternalPrivateNamedRemotesAreFlagged() async throws {
        for visibility in [GitHubRepositoryVisibility.public, .internal] {
            let report = await catalog { _ in visibility }.inspect(snapshot())
            let finding = try XCTUnwrap(report.findings().first)
            XCTAssertEqual(finding.subject, "owner/private-project")
            XCTAssertEqual(finding.severity, .blocked)
            XCTAssertEqual(finding.recipeIDs, [checkID])
            XCTAssertTrue(finding.evidence.contains(visibility.rawValue.lowercased()))
        }
        let uppercase = await catalog { _ in .public }.inspect(snapshot("https://github.com/owner/PRIVATE-project.git"))
        XCTAssertEqual(uppercase.findings().count, 1)
    }

    func testOnlyPrivateVisibilityResolvesAndFailedReadsStayUnknown() async throws {
        let before = await catalog { _ in .public }.inspect(snapshot())
        let finding = try XCTUnwrap(before.findings().first)
        let fixed = catalog { _ in .private }
        let after = await fixed.inspect(snapshot())
        XCTAssertTrue(after.findings().isEmpty)
        if case .absent = fixed.verify(finding, in: after) {} else { XCTFail("Private visibility did not resolve") }
        let failed = catalog { _ in throw RepairError.blocked("Authentication failed") }
        let unavailable = await failed.inspect(snapshot())
        XCTAssertNotNil(unavailable.unavailableChecks[checkID])
        if case .unknown = failed.verify(finding, in: unavailable) {} else { XCTFail("Failed read resolved visibility") }
    }

    func testUnrelatedNamesAndNonGitHubRemotesSkipRequests() async throws {
        let checks = catalog { _ in XCTFail("Skipped repositories must not query GitHub"); return .public }
        for remote in [nil, "https://gitlab.com/owner/private-project.git", "https://github.com/owner/project.git",
                       "https://github.com/owner/my-private-project.git", "https://github.com/owner/private.git"] {
            let report = await checks.inspect(snapshot(remote, name: "private-local-alias"))
            XCTAssertTrue(report.findings().isEmpty)
            XCTAssertTrue(report.unavailableChecks.isEmpty)
        }
    }

    func testVisibilityReadNeedsNoDefaultBranchOrReadmeAndRejectsIncompleteData() throws {
        let result = try GitHubRepositoryVisibility.load(snapshot()) { arguments in
            XCTAssertTrue(arguments.contains("owner=owner"))
            XCTAssertTrue(arguments.contains("name=private-project"))
            XCTAssertTrue(arguments.contains("--hostname"))
            XCTAssertFalse(GitHubRepositoryVisibility.query.contains("defaultBranchRef"))
            return Data(#"{"data":{"repository":{"visibility":"PUBLIC"}}}"#.utf8)
        }
        XCTAssertEqual(result, .public)
        for json in [#"{"data":{"repository":null}}"#, #"{"data":{"repository":{}}}"#,
                     #"{"data":{"repository":{"visibility":"UNKNOWN"}}}"#,
                     #"{"data":{"repository":{"visibility":"PRIVATE"}},"errors":[{"message":"Access denied"}]}"#] {
            XCTAssertThrowsError(try GitHubRepositoryVisibility.decode(Data(json.utf8)))
        }
    }

    func testVisibilityCacheExpiresAndFreshInspectionBypassesIt() async throws {
        let cache = RepositoryVisibilityCache(), now = Date()
        let first = try await cache.load(snapshot(), allowCached: true, now: now, loader: { _ in .public })
        let reused = try await cache.load(snapshot(), allowCached: true, now: now.addingTimeInterval(30), loader: { _ in
            XCTFail("Cached visibility should avoid requests"); return .private
        })
        XCTAssertFalse(first.cached)
        XCTAssertTrue(reused.cached)
        XCTAssertEqual(reused.visibility, .public)
        let fresh = try await cache.load(snapshot(), allowCached: false, now: now.addingTimeInterval(40), loader: { _ in .private })
        XCTAssertFalse(fresh.cached)
        XCTAssertEqual(fresh.visibility, .private)
        let expired = try await cache.load(snapshot(), allowCached: true, now: now.addingTimeInterval(640), loader: { _ in .public })
        XCTAssertFalse(expired.cached)
        XCTAssertEqual(expired.visibility, .public)
        let different = try await cache.load(snapshot("git@github.com:another/private-project.git"), allowCached: true, now: now, loader: { _ in .internal })
        XCTAssertFalse(different.cached)
        XCTAssertEqual(different.visibility, .internal)
    }

    func testCachedPrivateVisibilityCannotVerifyAnEarlierFinding() async throws {
        let remote = "git@github.com:owner/private-" + UUID().uuidString + ".git"
        let repository = snapshot(remote)
        let before = await catalog { _ in .public }.inspect(repository)
        let finding = try XCTUnwrap(before.findings().first)
        _ = try await RepositoryVisibilityCache.shared.load(repository, allowCached: false, loader: { _ in .private })
        let checks = catalog()
        let after = await checks.inspect(repository, allowCachedRemoteMetadata: true)
        XCTAssertTrue(after.findings().isEmpty)
        XCTAssertEqual(after.cachedChecks, [checkID])
        if case .unknown = checks.verify(finding, in: after) {} else { XCTFail("Cached absence resolved visibility") }
    }
}
