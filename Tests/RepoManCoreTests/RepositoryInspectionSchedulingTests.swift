import XCTest
@testable import RepoManCore

final class RepositoryInspectionSchedulingTests: XCTestCase {
    private actor Calls {
        var ids: [String] = []
        func record(_ id: String) { ids.append(id) }
        func values() -> [String] { ids }
    }
    private func snapshot(_ path: URL, branch: String = "main", remote: String? = nil) -> RepositorySnapshot {
        RepositorySnapshot(url: path, name: path.lastPathComponent, branch: branch, upstream: nil, remoteURL: remote,
            ahead: nil, behind: nil, changes: [], staleBranches: [], worktrees: [], commits: [], rootFiles: [])
    }
    private func check(_ id: String, period: TimeInterval, calls: Calls, fails: Bool = false) -> RepositoryCheck {
        RepositoryCheck(id: id, title: id, category: .setup, symbol: "checkmark", validityPeriod: period, inspect: { _ in
            await calls.record(id)
            if fails { throw RepairError.blocked("Offline") }
            return []
        })
    }

    func testRestartReusesCleanResultsWithoutExtendingExpiryAndRunsOnlyExpiredChecks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cache.json")
        let calls = Calls()
        let catalog = RepositoryIssueCatalog(checks: [check("fast", period: 300, calls: calls), check("slow", period: 3_600, calls: calls)])
        let repo = snapshot(root.appendingPathComponent("repo"))
        let start = Date(timeIntervalSince1970: 1_000)
        let cache = RepositoryInspectionCache(url: url)
        let first = await catalog.inspect(repo, cache: cache, now: { start })
        XCTAssertEqual(first.results.count, 2)
        let restarted = RepositoryInspectionCache(url: url)
        let valid = await catalog.inspect(repo, cache: restarted, now: { start.addingTimeInterval(299) })
        XCTAssertEqual(valid.cachedChecks, ["fast", "slow"])
        XCTAssertEqual(valid.completedAt, first.completedAt)
        var ids = await calls.values()
        XCTAssertEqual(ids.count, 2)
        let expired = await catalog.inspect(repo, cache: restarted, now: { start.addingTimeInterval(300) })
        XCTAssertEqual(expired.cachedChecks, ["slow"])
        XCTAssertEqual(expired.completedAt["slow"], start)
        ids = await calls.values()
        XCTAssertEqual(ids.filter { $0 == "fast" }.count, 2)
        XCTAssertEqual(ids.filter { $0 == "slow" }.count, 1)
    }

    func testForcedProjectRefreshBypassesEveryCheckerAndLeavesOtherProjectsValid() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = RepositoryInspectionCache(url: root.appendingPathComponent("cache.json"))
        let calls = Calls()
        let catalog = RepositoryIssueCatalog(checks: [check("one", period: 3_600, calls: calls), check("two", period: 86_400, calls: calls)])
        let repos = [snapshot(root.appendingPathComponent("a")), snapshot(root.appendingPathComponent("b"))]
        let start = Date(timeIntervalSince1970: 1_000)
        for repo in repos { _ = await catalog.inspect(repo, cache: cache, now: { start }) }
        let forced = await catalog.inspect(repos[0], cache: cache, forceRefresh: true, now: { start.addingTimeInterval(1) })
        XCTAssertTrue(forced.cachedChecks.isEmpty)
        XCTAssertEqual(forced.completedAt.values.sorted(), [start.addingTimeInterval(1), start.addingTimeInterval(1)])
        let other = await catalog.inspect(repos[1], cache: cache, now: { start.addingTimeInterval(2) })
        XCTAssertEqual(other.cachedChecks, ["one", "two"])
        var ids = await calls.values()
        XCTAssertEqual(ids.count, 6)
        for repo in repos { _ = await catalog.inspect(repo, cache: cache, forceRefresh: true, now: { start.addingTimeInterval(3) }) }
        ids = await calls.values()
        XCTAssertEqual(ids.count, 10)
    }

    func testUnavailableChecksRetrySoonerAndCachedResultsCannotVerifyRepairs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = RepositoryInspectionCache(url: root.appendingPathComponent("cache.json"))
        let calls = Calls()
        let catalog = RepositoryIssueCatalog(checks: [check("offline", period: 86_400, calls: calls, fails: true), check("clean", period: 3_600, calls: calls)])
        let repo = snapshot(root)
        let start = Date(timeIntervalSince1970: 1_000)
        _ = await catalog.inspect(repo, cache: cache, now: { start })
        let reused = await catalog.inspect(repo, cache: cache, now: { start.addingTimeInterval(299) })
        XCTAssertEqual(reused.unavailableChecks["offline"], "Offline")
        let finding = RepositoryFinding(repositoryID: repo.id, checkID: "clean", title: "Old issue", evidence: "", category: .setup, symbol: "checkmark")
        guard case .unknown = catalog.verify(finding, in: reused) else { return XCTFail("Cached absence must not resolve repairs") }
        let retry = await catalog.inspect(repo, cache: cache, now: { start.addingTimeInterval(300) })
        XCTAssertEqual(retry.cachedChecks, ["clean"])
        let fresh = await catalog.inspect(repo, now: { start.addingTimeInterval(301) })
        guard case .absent = catalog.verify(finding, in: fresh) else { return XCTFail("Repair inspection must remain fresh") }
    }

    func testNewCheckerIdentityChangesAndClockRollbackInvalidateResults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = RepositoryInspectionCache(url: root.appendingPathComponent("cache.json"))
        let calls = Calls()
        let original = check("original", period: 3_600, calls: calls)
        let catalog = RepositoryIssueCatalog(checks: [original])
        let repo = snapshot(root)
        let start = Date(timeIntervalSince1970: 1_000)
        _ = await catalog.inspect(repo, cache: cache, now: { start })
        let extended = RepositoryIssueCatalog(checks: [original, check("new", period: 3_600, calls: calls)])
        let added = await extended.inspect(repo, cache: cache, now: { start.addingTimeInterval(1) })
        XCTAssertEqual(added.cachedChecks, ["original"])
        let rollback = await cache.reusableResults(for: repo, checks: extended.checks, now: start.addingTimeInterval(-1))
        XCTAssertTrue(rollback.isEmpty)
        let changedBranch = await cache.reusableResults(for: snapshot(root, branch: "feature"), checks: extended.checks, now: start.addingTimeInterval(2))
        XCTAssertTrue(changedBranch.isEmpty)
        let changedRemote = await cache.reusableResults(for: snapshot(root, remote: "git@github.com:owner/other.git"), checks: extended.checks, now: start.addingTimeInterval(2))
        XCTAssertTrue(changedRemote.isEmpty)
    }

    func testCorruptCacheRecoversAndEveryRegisteredCheckerHasPositiveValidity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cache.json")
        try Data("corrupt".utf8).write(to: url)
        let cache = RepositoryInspectionCache(url: url)
        let calls = Calls()
        let catalog = RepositoryIssueCatalog(checks: [check("clean", period: 300, calls: calls)])
        let report = await catalog.inspect(snapshot(root), cache: cache)
        XCTAssertTrue(report.cachedChecks.isEmpty)
        let error = await cache.persistenceError
        XCTAssertNil(error)
        XCTAssertTrue(RepositoryIssueCatalog.standardChecks.allSatisfy { $0.validityPeriod > 0 })
    }

    func testFindingsSurviveRestartAndSnapshotUpdatesDoNotRerunCachedDetectors() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cache.json")
        let check = RepositoryCheck(id: "snapshot", title: "Snapshot", category: .inspection, symbol: "checkmark", detect: { repo in
            [RepositoryFinding(repositoryID: repo.id, checkID: "snapshot", title: "Evidence", evidence: repo.fetchError ?? "none",
                               category: .inspection, symbol: "checkmark")]
        })
        let catalog = RepositoryIssueCatalog(checks: [check])
        let start = Date(timeIntervalSince1970: 1_000)
        var repo = snapshot(root)
        repo.fetchError = "Original evidence"
        let original = await catalog.inspect(repo, cache: RepositoryInspectionCache(url: url), now: { start })
        repo.fetchError = "Changed evidence"
        let restored = await catalog.inspect(repo, cache: RepositoryInspectionCache(url: url), now: { start.addingTimeInterval(1) })
        XCTAssertEqual(restored.findings(), original.findings())
        XCTAssertEqual(restored.updatingSnapshot(repo, catalog: catalog).findings(), original.findings())
        let forced = await catalog.inspect(repo, cache: RepositoryInspectionCache(url: url), forceRefresh: true, now: { start.addingTimeInterval(2) })
        XCTAssertEqual(forced.findings().first?.evidence, "Changed evidence")
    }

    func testForcedRefreshAlsoBypassesUnderlyingMetadataCache() async {
        let check = RepositoryCheck(id: "remote", title: "Remote", category: .documentation, symbol: "checkmark", inspect: { context in
            if context.allowCachedRemoteMetadata { throw RepairError.blocked("Allowed underlying cache") }
            return []
        })
        let catalog = RepositoryIssueCatalog(checks: [check])
        let report = await catalog.inspect(snapshot(URL(fileURLWithPath: "/fixture")), allowCachedRemoteMetadata: true, forceRefresh: true)
        XCTAssertTrue(report.unavailableChecks.isEmpty)
    }
}
