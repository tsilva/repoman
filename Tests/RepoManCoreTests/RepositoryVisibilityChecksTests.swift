import Foundation
import XCTest
@testable import RepoManCore

final class RepositoryVisibilityChecksTests: XCTestCase {
    private let checkID = "github.privateVisibility"
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RepoManVisibility-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try GitRunner.run(["init", "-b", "main"], at: root)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func snapshot(_ remote: String? = "git@github.com:owner/private-project.git", name: String = "local-alias") throws -> RepositorySnapshot {
        let remotes = try GitRunner.text(["remote"], at: root).split(separator: "\n")
        for name in remotes { _ = try GitRunner.run(["remote", "remove", String(name)], at: root) }
        if let remote { _ = try GitRunner.run(["remote", "add", "origin", remote], at: root) }
        return RepositorySnapshot(url: root, name: name, branch: "main", upstream: nil, remoteURL: remote,
            ahead: nil, behind: nil, changes: [], staleBranches: [], worktrees: [], commits: [], rootFiles: [])
    }
    private func reference(_ remote: String = "git@github.com:owner/private-project.git") -> GitHubCI.Repository {
        GitHubCI.repository(remote)!
    }
    private func catalog(_ load: RepositoryMetadataChecks.VisibilityLoader? = nil) -> RepositoryIssueCatalog {
        RepositoryIssueCatalog(checks: RepositoryMetadataChecks.checks(loadVisibility: load).filter { $0.id == checkID })
    }

    func testPublicAndInternalPrivateNamedRemotesAreFlagged() async throws {
        for visibility in [GitHubRepositoryVisibility.public, .internal] {
            let report = await catalog { _ in visibility }.inspect(try snapshot())
            let finding = try XCTUnwrap(report.findings().first)
            XCTAssertEqual(finding.subject, "owner/private-project")
            XCTAssertEqual(finding.severity, .blocked)
            XCTAssertTrue(finding.evidence.contains(visibility.rawValue.lowercased()))
        }
        let uppercase = await catalog { _ in .public }.inspect(try snapshot("https://github.com/owner/PRIVATE-project.git"))
        XCTAssertEqual(uppercase.findings().count, 1)
    }

    func testOnlyPrivateVisibilityResolvesAndFailedReadsStayUnknown() async throws {
        let before = await catalog { _ in .public }.inspect(try snapshot())
        let finding = try XCTUnwrap(before.findings().first)
        let fixed = catalog { _ in .private }
        let after = await fixed.inspect(try snapshot())
        XCTAssertTrue(after.findings().isEmpty)
        if case .absent = fixed.verify(finding, in: after) {} else { XCTFail("Private visibility did not resolve") }
        let failed = catalog { _ in throw InspectionError.blocked("Authentication failed") }
        let unavailable = await failed.inspect(try snapshot())
        XCTAssertNotNil(unavailable.unavailableChecks[checkID])
        if case .unknown = failed.verify(finding, in: unavailable) {} else { XCTFail("Failed read resolved visibility") }
    }

    func testUnrelatedNamesAndNonGitHubRemotesWithoutLocalPrefixSkipRequests() async throws {
        let checks = catalog { _ in XCTFail("Skipped repositories must not query GitHub"); return .public }
        for remote in [nil, "https://gitlab.com/owner/private-project.git", "https://github.com/owner/project.git",
                       "https://github.com/owner/my-private-project.git", "https://github.com/owner/private.git"] {
            let report = await checks.inspect(try snapshot(remote))
            XCTAssertTrue(report.findings().isEmpty)
            XCTAssertTrue(report.unavailableChecks.isEmpty)
        }
    }

    func testVisibilityReadNeedsNoDefaultBranchOrReadmeAndRejectsIncompleteData() throws {
        let result = try GitHubRepositoryVisibility.load(reference()) { arguments in
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

    func testLocalPrivatePrefixRequiresPrivateVisibilityForOrdinaryGitHubNames() async throws {
        for name in ["private-local-alias", "PRIVATE-local-alias"] {
            let repo = try snapshot("https://github.com/owner/ordinary.git", name: name)
            let failed = await catalog { _ in .public }.inspect(repo)
            let finding = try XCTUnwrap(failed.findings().first)
            XCTAssertEqual(finding.subject, "owner/ordinary")
            XCTAssertTrue(finding.evidence.contains("local folder name"))
            let passed = await catalog { _ in .private }.inspect(repo)
            XCTAssertTrue(passed.findings().isEmpty)
            XCTAssertTrue(passed.unavailableChecks.isEmpty)
        }
    }

    func testEveryFetchAndPushDestinationIsCheckedAndAliasesAreDeduplicated() async throws {
        let repo = try snapshot("https://github.com/owner/ordinary.git", name: "private-local")
        for arguments in [
            ["remote", "add", "backup", "git@github.com:OWNER/ORDINARY.git"],
            ["config", "--add", "remote.origin.url", "https://github.com/owner/secondary.git"],
            ["config", "--add", "remote.origin.pushurl", "ssh://git@github.com/owner/push-one.git"],
            ["config", "--add", "remote.origin.pushurl", "https://github.com/owner/push-two.git"]
        ] { _ = try GitRunner.run(arguments, at: root) }
        let calls = VisibilityCalls()
        let report = await catalog { repository in
            await calls.record(repository)
            return repository.name.lowercased() == "ordinary" ? .private : .public
        }.inspect(repo)
        let observed = await calls.subjects
        XCTAssertEqual(Set(observed), ["owner/ordinary", "owner/secondary", "owner/push-one", "owner/push-two"])
        XCTAssertEqual(observed.count, 4)
        XCTAssertEqual(Set(report.findings().map(\.subject)), ["owner/secondary", "owner/push-one", "owner/push-two"])
        XCTAssertTrue(report.unavailableChecks.isEmpty)
    }

    func testPrivateNamedSecondaryRemoteIsCheckedWithoutLocalPrefix() async throws {
        let repo = try snapshot("https://github.com/owner/ordinary.git")
        _ = try GitRunner.run(["remote", "add", "backup", "https://github.com/owner/private-backup.git"], at: root)
        let report = await catalog { repository in
            XCTAssertEqual(repository.name, "private-backup")
            return .internal
        }.inspect(repo)
        XCTAssertEqual(report.findings().map(\.subject), ["owner/private-backup"])
    }

    func testFailedLookupPreservesOtherRemoteFindings() async throws {
        let repo = try snapshot("https://github.com/owner/private-unreadable.git")
        _ = try GitRunner.run(["remote", "add", "backup", "https://github.com/owner/private-public.git"], at: root)
        let report = await catalog { repository in
            if repository.name == "private-unreadable" { throw InspectionError.blocked("Access denied") }
            return .public
        }.inspect(repo)
        XCTAssertEqual(report.findings().map(\.subject), ["owner/private-public"])
        XCTAssertNotNil(report.unavailableChecks[checkID])
    }

    func testLocalPrivateUnsupportedRemotesStayIncompleteWithoutExposingURLs() async throws {
        let repo = try snapshot("https://user:fixture-password@gitlab.com/owner/project.git", name: "private-local")
        _ = try GitRunner.run(["remote", "add", "backup", "https://github.com/owner/ordinary.git"], at: root)
        let report = await catalog { _ in .public }.inspect(repo)
        XCTAssertEqual(report.findings().map(\.subject), ["owner/ordinary"])
        let reason = try XCTUnwrap(report.unavailableChecks[checkID])
        XCTAssertTrue(reason.contains("not a supported GitHub remote"))
        XCTAssertFalse(reason.contains("fixture-password"))
        let noRemotes = await catalog { _ in XCTFail("No remotes must not query GitHub"); return .public }
            .inspect(try snapshot(nil, name: "private-local"))
        if case .notApplicable = noRemotes.results[checkID] {} else { XCTFail("Local-only repositories should be not applicable") }
    }

    func testDestinationChangesBypassPersistedCheckResults() async throws {
        let repo = try snapshot("https://github.com/owner/ordinary.git", name: "private-local")
        let cache = RepositoryInspectionCache(url: root.appendingPathComponent("inspection-cache.json"))
        let checks = catalog { _ in .public }
        let first = await checks.inspect(repo, cache: cache)
        XCTAssertEqual(first.findings().count, 1)
        _ = try GitRunner.run(["remote", "add", "backup", "https://github.com/owner/other.git"], at: root)
        let second = await checks.inspect(repo, cache: cache)
        XCTAssertEqual(Set(second.findings().map(\.subject)), ["owner/ordinary", "owner/other"])
        XCTAssertFalse(second.cachedChecks.contains(checkID))
    }

    func testPerDestinationExceptionsArePreserved() async throws {
        let repo = try snapshot()
        try #"{"version":1,"exceptions":{"github.privateVisibility":{"owner/private-project":"Approved fixture"}}}"#
            .write(to: root.appendingPathComponent(".repoman.json"), atomically: true, encoding: .utf8)
        let report = await catalog { _ in .public }.inspect(repo)
        XCTAssertTrue(report.findings().isEmpty)
        XCTAssertEqual(report.appliedExceptions[checkID]?["owner/private-project"], "Approved fixture")
    }

    func testActualFolderNameTriggersPolicyEvenWhenSnapshotNameDiffers() async throws {
        let repo = try snapshot("https://github.com/owner/ordinary.git")
        let folder = root.appendingPathComponent("PRIVATE-folder")
        _ = try GitRunner.run(["init", "-b", "main", folder.path], at: root)
        _ = try GitRunner.run(["remote", "add", "origin", "https://github.com/owner/ordinary.git"], at: folder)
        let aliased = RepositorySnapshot(url: folder, name: repo.name, branch: "main", upstream: nil,
            remoteURL: repo.remoteURL, ahead: nil, behind: nil, changes: [], staleBranches: [], worktrees: [], commits: [], rootFiles: [])
        let report = await catalog { _ in .public }.inspect(aliased)
        XCTAssertEqual(report.findings().map(\.subject), ["owner/ordinary"])
    }

    func testGitURLRewritesResolveFetchAndPushDestinations() async throws {
        let repo = try snapshot("fixture:owner/ordinary.git", name: "private-local")
        _ = try GitRunner.run(["config", "url.https://github.com/.insteadOf", "fixture:"], at: root)
        _ = try GitRunner.run(["config", "url.https://github.com/publisher/.pushInsteadOf", "fixture:owner/"], at: root)
        let report = await catalog { _ in .public }.inspect(repo)
        XCTAssertEqual(Set(report.findings().map(\.subject)), ["owner/ordinary", "publisher/ordinary"])
        XCTAssertTrue(report.unavailableChecks.isEmpty)
    }

    func testURLLessRemoteInPrivateFolderDoesNotHideKnownViolations() async throws {
        let repo = try snapshot(name: "private-local")
        _ = try GitRunner.run(["config", "remote.empty.fetch", "+refs/heads/*:refs/remotes/empty/*"], at: root)
        let report = await catalog { _ in .public }.inspect(repo)
        XCTAssertEqual(report.findings().map(\.subject), ["owner/private-project"])
        XCTAssertNotNil(report.unavailableChecks[checkID])
    }

    func testFailedRemoteInventoryRemainsIncomplete() async throws {
        let repo = try snapshot()
        try FileManager.default.removeItem(at: root.appendingPathComponent(".git"))
        let report = await catalog { _ in XCTFail("Unreadable inventory must not query GitHub"); return .public }.inspect(repo)
        XCTAssertNotNil(report.unavailableChecks[checkID])
        XCTAssertTrue(report.findings().isEmpty)
    }

    func testVisibilityCacheExpiresAndFreshInspectionBypassesIt() async throws {
        let cache = RepositoryVisibilityCache(), now = Date()
        let first = try await cache.load(reference(), allowCached: true, now: now, loader: { _ in .public })
        let reused = try await cache.load(reference(), allowCached: true, now: now.addingTimeInterval(30), loader: { _ in
            XCTFail("Cached visibility should avoid requests"); return .private
        })
        XCTAssertFalse(first.cached)
        XCTAssertTrue(reused.cached)
        XCTAssertEqual(reused.visibility, .public)
        let fresh = try await cache.load(reference(), allowCached: false, now: now.addingTimeInterval(40), loader: { _ in .private })
        XCTAssertFalse(fresh.cached)
        XCTAssertEqual(fresh.visibility, .private)
        let expired = try await cache.load(reference(), allowCached: true, now: now.addingTimeInterval(640), loader: { _ in .public })
        XCTAssertFalse(expired.cached)
        XCTAssertEqual(expired.visibility, .public)
        let different = try await cache.load(reference("git@github.com:another/private-project.git"), allowCached: true, now: now, loader: { _ in .internal })
        XCTAssertFalse(different.cached)
        XCTAssertEqual(different.visibility, .internal)
    }

    func testCachedPrivateVisibilityCannotVerifyAnEarlierFinding() async throws {
        let remote = "git@github.com:owner/private-" + UUID().uuidString + ".git"
        let repository = try snapshot(remote)
        let before = await catalog { _ in .public }.inspect(repository)
        let finding = try XCTUnwrap(before.findings().first)
        _ = try await RepositoryVisibilityCache.shared.load(reference(remote), allowCached: false, loader: { _ in .private })
        let checks = catalog()
        let after = await checks.inspect(repository, allowCachedRemoteMetadata: true)
        XCTAssertTrue(after.findings().isEmpty)
        XCTAssertEqual(after.cachedChecks, [checkID])
        if case .unknown = checks.verify(finding, in: after) {} else { XCTFail("Cached absence resolved visibility") }
    }
}

private actor VisibilityCalls {
    var subjects: [String] = []
    func record(_ repository: GitHubCI.Repository) {
        subjects.append((repository.owner + "/" + repository.name).lowercased())
    }
}
