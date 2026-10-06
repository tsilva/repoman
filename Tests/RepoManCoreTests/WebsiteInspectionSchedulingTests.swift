import Foundation
import XCTest
@testable import RepoManCore

final class WebsiteInspectionSchedulingTests: XCTestCase {
    private actor Activity {
        var domains: [String] = []
        var active = 0
        var peak = 0
        var waiting: [CheckedContinuation<Void, Never>] = []
        var released = false
        func enter(_ domain: String) { domains.append(domain); active += 1; peak = max(peak, active) }
        func leave() { active -= 1 }
        func pause() async {
            if released { return }
            await withCheckedContinuation { waiting.append($0) }
        }
        func release() { released = true; waiting.forEach { $0.resume() }; waiting = [] }
        func state() -> (domains: [String], peak: Int) { (domains, peak) }
    }

    private func fixture(_ count: Int) throws -> RepositorySnapshot {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WebsiteScheduling-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let domains = (0..<count).map { "'site\($0).tsilva.eu'" }.joined(separator: ", ")
        try "domains = [\(domains)]".write(to: root.appendingPathComponent(".repo-metadata.toml"), atomically: true, encoding: .utf8)
        return RepositorySnapshot(url: root, name: "test", branch: "main", upstream: nil, remoteURL: nil,
            ahead: nil, behind: nil, changes: [], staleBranches: [], worktrees: [], commits: [], rootFiles: [])
    }

    func testThreeDomainsStartWithoutWaitingForFirstProbeAndShareAcrossFourChecks() async throws {
        let snapshot = try fixture(3)
        defer { try? FileManager.default.removeItem(at: snapshot.url) }
        let activity = Activity()
        let started = expectation(description: "All three domains start before any probe finishes")
        started.expectedFulfillmentCount = 3
        let checks = RepositoryWebsiteChecks.checks(load: { domain, _ in
            await activity.enter(domain)
            started.fulfill()
            await activity.pause()
            await activity.leave()
            return WebsiteProbe(transportFailure: "Offline")
        })
        let inspection = Task { await RepositoryIssueCatalog(checks: checks).inspect(snapshot) }
        await fulfillment(of: [started], timeout: 1)
        await activity.release()
        let report = await inspection.value
        let state = await activity.state()
        XCTAssertEqual(state.domains.count, 3, "Four checks must share each domain's probe")
        XCTAssertEqual(state.peak, 3)
        XCTAssertEqual(report.results.count, 4)
        XCTAssertEqual(report.findings().filter { $0.checkID == "website.online" }.count, 3)
    }

    func testManyDomainsKeepAtMostFourProbesActiveAndRunEachOnlyOnce() async throws {
        let snapshot = try fixture(9)
        defer { try? FileManager.default.removeItem(at: snapshot.url) }
        let activity = Activity()
        let checks = RepositoryWebsiteChecks.checks(load: { domain, _ in
            await activity.enter(domain)
            try? await Task.sleep(for: .milliseconds(20))
            await activity.leave()
            return WebsiteProbe(transportFailure: "Offline")
        })
        let report = await RepositoryIssueCatalog(checks: checks).inspect(snapshot)
        let state = await activity.state()
        XCTAssertEqual(state.domains.count, 9)
        XCTAssertEqual(Set(state.domains).count, 9)
        XCTAssertEqual(state.peak, 4)
        XCTAssertEqual(report.results.count, 4)
    }
}
