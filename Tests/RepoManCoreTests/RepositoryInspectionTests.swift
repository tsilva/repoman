import Foundation
import XCTest
@testable import RepoManCore

final class RepositoryInspectionTests: XCTestCase {
    func testInspectionKeepsAtMostFourChecksActiveAndPreservesCatalogOrder() async {
        let activity = InspectionActivity()
        let checks = (0..<13).map { index in
            RepositoryCheck(id: "check-\(index)", title: "Check", category: .setup, symbol: "doc", inspect: { context in
                await activity.started()
                try await Task.sleep(for: .milliseconds(5))
                await activity.finished()
                return [RepositoryFinding(repositoryID: context.snapshot.id, checkID: "check-\(index)",
                    title: "Check", evidence: "Evidence", category: .setup, symbol: "doc")]
            })
        }
        let snapshot = RepositorySnapshot(url: URL(fileURLWithPath: "/tmp/inspection"), name: "inspection", branch: "main",
            upstream: nil, remoteURL: nil, ahead: nil, behind: nil, changes: [], staleBranches: [], worktrees: [], commits: [])
        let report = await RepositoryIssueCatalog(checks: checks).inspect(snapshot)
        let peak = await activity.peak
        XCTAssertEqual(peak, 4)
        XCTAssertEqual(report.findings().map(\.checkID), checks.map(\.id))
    }

    func testIndependentGitReadFinishesWhileAnotherCommandIsBlocked() async {
        let entered = expectation(description: "Slow command entered")
        let fastFinished = expectation(description: "Independent command finished")
        let slowFinished = expectation(description: "Slow command finished")
        let release = DispatchSemaphore(value: 0)
        let cache = InspectionGitCache { arguments, _, _ in
            if arguments == ["slow"] {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 5)
            }
            return Data(arguments[0].utf8)
        }
        let directory = URL(fileURLWithPath: "/tmp/inspection")
        Thread.detachNewThread {
            XCTAssertEqual(try? cache.read(["slow"], at: directory, successfulExitCodes: [0]), Data("slow".utf8))
            slowFinished.fulfill()
        }
        await fulfillment(of: [entered], timeout: 2)
        Thread.detachNewThread {
            XCTAssertEqual(try? cache.read(["fast"], at: directory, successfulExitCodes: [0]), Data("fast".utf8))
            fastFinished.fulfill()
        }
        await fulfillment(of: [fastFinished], timeout: 2)
        release.signal()
        await fulfillment(of: [slowFinished], timeout: 2)
    }

    func testConcurrentIdenticalGitReadsShareOneResultIncludingFailures() async {
        for fails in [false, true] {
            let calls = InspectionCallCounter()
            let cache = InspectionGitCache { _, _, _ in
                calls.increment()
                Thread.sleep(forTimeInterval: 0.01)
                if fails { throw GitError.failed("Unavailable") }
                return Data("result".utf8)
            }
            let completed = expectation(description: "All shared requests finished")
            completed.expectedFulfillmentCount = 8
            for _ in 0..<8 {
                Thread.detachNewThread {
                    do {
                        let data = try cache.read(["shared"], at: URL(fileURLWithPath: "/tmp/inspection"),
                            successfulExitCodes: [0])
                        XCTAssertEqual(data, Data("result".utf8))
                        XCTAssertFalse(fails)
                    } catch {
                        XCTAssertTrue(fails)
                        XCTAssertEqual(error.localizedDescription, "Unavailable")
                    }
                    completed.fulfill()
                }
            }
            await fulfillment(of: [completed], timeout: 2)
            XCTAssertEqual(calls.count, 1)
        }
    }

    func testGitCacheSeparatesDirectoriesAndAcceptedExitCodes() throws {
        let calls = InspectionCallCounter()
        let cache = InspectionGitCache { _, directory, codes in
            calls.increment()
            return Data((directory.path + codes.sorted().map(String.init).joined()).utf8)
        }
        let first = URL(fileURLWithPath: "/tmp/first"), second = URL(fileURLWithPath: "/tmp/second")
        let result = try cache.read(["command"], at: first, successfulExitCodes: [0])
        XCTAssertEqual(try cache.read(["command"], at: first, successfulExitCodes: [0]), result)
        XCTAssertNotEqual(try cache.read(["command"], at: second, successfulExitCodes: [0]), result)
        XCTAssertNotEqual(try cache.read(["command"], at: first, successfulExitCodes: [0, 1]), result)
        XCTAssertEqual(calls.count, 3)
    }
}

private actor InspectionActivity {
    private var active = 0
    var peak = 0
    func started() { active += 1; peak = max(peak, active) }
    func finished() { active -= 1 }
}

private final class InspectionCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); defer { lock.unlock() }; value += 1 }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
