import Foundation
import XCTest
@testable import RepoManCore

final class GitHubRepositoryCountsTests: XCTestCase {
    func testCloneURLsShareOneCacheKey() {
        let ssh = GitHubRepositoryCountsQuery.key(for: "git@github.com:Owner/Repo.git")
        let https = GitHubRepositoryCountsQuery.key(for: "https://github.com/owner/repo")
        XCTAssertEqual(ssh, "owner/repo")
        XCTAssertEqual(ssh, https)
        XCTAssertNil(GitHubRepositoryCountsQuery.key(for: "https://gitlab.com/owner/repo"))
        XCTAssertNil(GitHubRepositoryCountsQuery.key(for: nil))
    }

    func testBatchKeepsZeroAndSuccessfulCountsWhenAnotherRepositoryIsUnavailable() throws {
        let executable = try stubGH("""
        for argument in "$@"; do
          case "$argument" in
            owner0=owner) owner0=1 ;;
            name1=unavailable) name1=1 ;;
            owner2=other) owner2=1 ;;
            query=*r0:*r1:*r2:*stargazerCount*forkCount*) query=1 ;;
          esac
        done
        [ "$owner0$name1$owner2$query" = "1111" ] || exit 2
        cat <<'JSON'
        {"data":{"r0":{"stargazerCount":0,"forkCount":0},"r1":null,"r2":{"stargazerCount":182,"forkCount":14}},"errors":[{"message":"Could not resolve repository","path":["r1"]}]}
        JSON
        exit 1
        """)
        let result = try GitHubRepositoryCountsQuery.load(["owner/empty", "owner/unavailable", "other/project"], executable: executable)
        XCTAssertEqual(result, [
            "owner/empty": GitHubRepositoryCounts(stars: 0, forks: 0),
            "other/project": GitHubRepositoryCounts(stars: 182, forks: 14)
        ])
    }

    func testServiceFailureDoesNotProduceZeroCounts() throws {
        let executable = try stubGH("""
        printf '%s\\n' '{"data":null,"errors":[{"message":"Rate limit exceeded"}]}'
        exit 1
        """)
        XCTAssertThrowsError(try GitHubRepositoryCountsQuery.load(["owner/repo"], executable: executable))
    }

    func testPersistedCountsExpireWithoutLosingLastKnownValues() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let entry = GitHubRepositoryCountsEntry(counts: .init(stars: 12, forks: 3), fetchedAt: now)
        let restored = try JSONDecoder().decode(GitHubRepositoryCountsEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertTrue(restored.isFresh(at: now.addingTimeInterval(86_399)))
        XCTAssertFalse(restored.isFresh(at: now.addingTimeInterval(86_400)))
        XCTAssertEqual(restored.counts, entry.counts)
    }

    private func stubGH(_ body: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("gh")
        try ("#!/bin/sh\n" + body + "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }
}
