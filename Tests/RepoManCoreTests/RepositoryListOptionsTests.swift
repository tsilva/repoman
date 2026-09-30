import Foundation
import XCTest
@testable import RepoManCore

final class RepositoryListOptionsTests: XCTestCase {
    func testFiltersIncludeOnlyTheirMatchingStatus() {
        let repositories = [
            snapshot("clean"),
            snapshot("push", ahead: 2),
            snapshot("pull", behind: 1),
            snapshot("changed", changes: 3),
            snapshot("stale", staleBranches: 1),
            snapshot("worktree", worktrees: 1),
            snapshot("fetch-error", fetchError: "Remote unavailable"),
            snapshot("no-upstream", ahead: nil, behind: nil)
        ]
        let expected: [RepositoryFilter: Set<String>] = [
            .all: Set(repositories.map(\.name)),
            .needsAttention: ["push", "pull", "changed", "stale", "worktree", "fetch-error"],
            .toPush: ["push"], .toPull: ["pull"], .changedFiles: ["changed"],
            .staleBranches: ["stale"], .worktrees: ["worktree"]
        ]
        for filter in RepositoryFilter.allCases {
            XCTAssertEqual(Set(repositories.filter(filter.matches).map(\.name)), expected[filter], filter.rawValue)
        }
    }

    func testSearchCombinesWithFilterAndCanProduceAnEmptyList() {
        let repositories = [snapshot("AgentBox", changes: 2), snapshot("agentbridge"), snapshot("repoman", changes: 1)]
        XCTAssertEqual(
            RepositorySort.name.repositories(repositories, filter: .changedFiles, search: " AGENT ").map(\.name),
            ["AgentBox"]
        )
        XCTAssertTrue(RepositorySort.name.repositories(repositories, filter: .toPull).isEmpty)
        XCTAssertTrue(RepositorySort.name.repositories(repositories, search: "missing").isEmpty)
    }

    func testNameSortUsesNaturalOrderInBothDirections() {
        let repositories = [snapshot("repo10"), snapshot("repo2"), snapshot("repo1")]
        XCTAssertEqual(RepositorySort.name.repositories(repositories).map(\.name), ["repo1", "repo2", "repo10"])
        XCTAssertEqual(
            RepositorySort.name.repositories(repositories, ascending: false).map(\.name),
            ["repo10", "repo2", "repo1"]
        )
    }

    func testStatusSortsUseCountsAndAlphabeticalTies() {
        let repositories = [
            snapshot("zero"),
            snapshot("beta", ahead: 2, behind: 2, changes: 2, staleBranches: 2, worktrees: 2),
            snapshot("alpha", ahead: 2, behind: 2, changes: 2, staleBranches: 2, worktrees: 2),
            snapshot("many", ahead: 10, behind: 10, changes: 10, staleBranches: 10, worktrees: 10)
        ]
        for sort in RepositorySort.allCases where sort != .name {
            XCTAssertEqual(
                sort.repositories(repositories, ascending: false).map(\.name),
                ["many", "alpha", "beta", "zero"], sort.rawValue
            )
            XCTAssertEqual(
                sort.repositories(repositories, ascending: true).map(\.name),
                ["zero", "alpha", "beta", "many"], sort.rawValue
            )
        }
    }

    func testUnknownDivergenceSortsAfterKnownValuesInEitherDirection() {
        let repositories = [snapshot("unknown", ahead: nil, behind: nil), snapshot("zero"), snapshot("ahead", ahead: 3, behind: 3)]
        for sort in [RepositorySort.toPush, .toPull] {
            XCTAssertEqual(sort.repositories(repositories).map(\.name), ["zero", "ahead", "unknown"])
            XCTAssertEqual(sort.repositories(repositories, ascending: false).map(\.name), ["ahead", "zero", "unknown"])
        }
    }

    func testEqualNamesUsePathToKeepOrderingStable() {
        let repositories = [snapshot("same", directory: "z"), snapshot("same", directory: "a")]
        for sort in RepositorySort.allCases {
            XCTAssertEqual(sort.repositories(repositories).map(\.url.path), ["/a/same", "/z/same"])
        }
    }

    private func snapshot(
        _ name: String,
        directory: String = "repos",
        ahead: Int? = 0,
        behind: Int? = 0,
        changes: Int = 0,
        staleBranches: Int = 0,
        worktrees: Int = 0,
        fetchError: String? = nil
    ) -> RepositorySnapshot {
        RepositorySnapshot(
            url: URL(fileURLWithPath: "/\(directory)/\(name)"), name: name,
            branch: "main", upstream: name == "no-upstream" ? nil : "origin/main", remoteURL: nil,
            ahead: ahead, behind: behind,
            changes: (0..<changes).map { WorkingTreeChange(path: "file\($0)", kind: .modified, added: nil, removed: nil) },
            staleBranches: (0..<staleBranches).map { "branch\($0)" },
            worktrees: (0..<worktrees).map { "worktree\($0)" },
            commits: [], fetchError: fetchError, rootFiles: ["README.md", ".gitignore", "LICENSE"]
        )
    }
}
