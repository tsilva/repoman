import Foundation
import XCTest
@testable import RepoManCore

final class RepositoryManifestTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RepoManManifest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func write(_ source: String) throws {
        try source.write(to: root.appendingPathComponent(".repoman.json"), atomically: true, encoding: .utf8)
    }
    private func context() -> RepositoryInspectionContext {
        RepositoryInspectionContext(snapshot: RepositorySnapshot(url: root, name: "fixture", branch: "main", upstream: nil,
            remoteURL: nil, ahead: nil, behind: nil, changes: [], staleBranches: [], worktrees: [], commits: [], rootFiles: []))
    }

    func testSingleManifestPreservesMetadataWebsitesAndCheckPolicy() throws {
        try write(#"""
        {"version":1,"short-name":"fixture","tagline":"Build & ship","github-url":null,
         "vercel-project-id":"prj_fixture","stashAgeDays":90,
         "ci":{"components":[{"path":".","ecosystem":"swift","requires":["test","build"]}]},
         "exceptions":{"website.analytics":{"alias.tsilva.eu":"Reviewed redirect"}},
         "websites":{"site.tsilva.eu":{"url":"https://site.tsilva.eu/","ga4-verification-path":"/chat",
           "sentry-expectation":"optional","sentry-exception-reason":"Server-only \"capture\".","checked-on":"2026-11-03"},
           "alias.tsilva.eu":{"url":"https://alias.tsilva.eu/","redirect-to":"https://site.tsilva.eu/"}}}
        """#)
        let context = context(), policy = try RepositoryCheckPolicy.load(context)
        XCTAssertEqual(policy.stashAgeDays, 90)
        XCTAssertEqual(policy.ci.components?.first?.requires, ["test", "build"])
        XCTAssertEqual(policy.exceptions["website.analytics"]?["alias.tsilva.eu"], "Reviewed redirect")
        XCTAssertEqual(try RepoManManifest.metadata("tagline", in: context), "Build & ship")
        XCTAssertEqual(try RepoManManifest.metadata("github-url", in: context), "")
        XCTAssertEqual(try WebsiteDomains.projectID(context), "prj_fixture")
        let sites = try WebsiteDomains.inventory(context)
        XCTAssertEqual(sites.keys.sorted(), ["alias.tsilva.eu", "site.tsilva.eu"])
        XCTAssertEqual(sites["site.tsilva.eu"]?["ga4"]?.path, "/chat")
        XCTAssertEqual(sites["site.tsilva.eu"]?["sentry"]?.exceptionReason, "Server-only \"capture\".")
    }

    func testExplicitEmptyInventoryAndNullDifferFromOmission() throws {
        try "domains=['legacy.tsilva.eu']".write(to: root.appendingPathComponent(".repo-metadata.toml"), atomically: true, encoding: .utf8)
        try write(#"{"version":1,"websites":{},"github-url":null}"#)
        XCTAssertEqual(try WebsiteDomains.load(context()), [])
        XCTAssertEqual(try RepoManManifest.metadata("github-url", in: context()), "")
        try write(#"{"version":1}"#)
        XCTAssertNil(try RepoManManifest.metadata("github-url", in: context()))
        XCTAssertEqual(try WebsiteDomains.load(context()), ["legacy.tsilva.eu"])
    }

    func testMalformedDuplicateAndUnsupportedVersionsCannotSupplyPolicy() throws {
        for source in [#"{"version":2}"#, #"{"version":true}"#, #"{"version":1,"version":1}"#,
                       #"{"exceptions":{"a":{"subject":"first","\u0073ubject":"second"}}}"#,
                       #"{"ci":{"components":[]},"ci":{}}"#, "[]", "{"] {
            try write(source)
            XCTAssertThrowsError(try RepositoryCheckPolicy.load(context()), source)
        }
    }

    func testInvalidMetadataAndWebsitePoliciesRemainIncomplete() throws {
        for value in ["null", "[]", "true", "7", #""/relative""#, #""null""#] {
            try write("{\"tagline\":\(value),\"github-url\":\(value)}")
            if value != #""/relative""# && value != #""null""# { XCTAssertThrowsError(try RepoManManifest.metadata("tagline", in: context())) }
            if value != "null" { XCTAssertThrowsError(try RepoManManifest.metadata("github-url", in: context())) }
        }
        for fields in [#"{"url":"https://other.tsilva.eu/"}"#, #"{"url":"https://site.tsilva.eu/","ga4-expectation":"disabled"}"#,
                       #"{"url":"https://site.tsilva.eu/","ga4-verification-path":"/../secret"}"#,
                       #"{"url":"https://site.tsilva.eu/","checked-on":2026}"#,
                       #"{"url":"https://site.tsilva.eu/","unknown":"value"}"#] {
            try write("{\"websites\":{\"site.tsilva.eu\":\(fields)}}")
            XCTAssertThrowsError(try WebsiteDomains.load(context()))
        }
    }
}
