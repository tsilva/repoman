import XCTest
@testable import RepoManCore

final class WebsiteDomainInventoryTests: XCTestCase {
    private func json(_ value: Any) throws -> Data {
        var object = value as! [String: Any]
        if object["pagination"] == nil { object["pagination"] = ["next":NSNull()] }
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testEveryTeamAndProjectPageIncludesOldProductionDomainsAndExcludesPreviews() throws {
        var visited: [[String]] = []
        let projects = try WebsiteDomainInventory.load { arguments in
            visited.append(arguments)
            switch arguments[1] {
            case "/v2/teams?limit=100":
                return try json(["teams": [["slug":"team-a"], ["slug":"team-b"]], "pagination":["next":NSNull()]])
            case "/v9/projects?limit=100":
                if arguments.contains("team-b") { return try json(["projects":[]]) }
                return try json(["projects":[["id":"prj_old", "link":["type":"github", "org":"Fixture", "repo":"Site"]]], "pagination":["next":42]])
            case "/v9/projects?limit=100&from=42":
                return try json(["projects":[["id":"prj_cli"]], "pagination":["next":NSNull()]])
            case "/v9/projects/prj_old/domains?production=true&limit=100":
                return try json(["domains":[["name":"SITE.tsilva.eu"], ["name":"site.vercel.app"],
                    ["name":"preview.vercel.app", "gitBranch":"feature"],
                    ["name":"staging.vercel.app", "customEnvironmentId":"env_staging"],
                    ["name":"unverified.vercel.app", "verified":false],
                    ["name":"preview.tsilva.eu", "gitBranch":"feature"],
                    ["name":"staging.tsilva.eu", "customEnvironmentId":"env_staging"]]])
            case "/v9/projects/prj_cli/domains?production=true&limit=100":
                return try json(["domains":[["name":"cli.tsilva.eu", "gitBranch":NSNull()]]])
            default: XCTFail("Unexpected endpoint"); return try json([:])
            }
        }
        XCTAssertEqual(projects.count, 2)
        XCTAssertEqual(projects[0].repository, "fixture/site")
        XCTAssertEqual(projects[0].domains, ["site.tsilva.eu"])
        XCTAssertEqual(projects[0].productionAliases, ["site.vercel.app"])
        XCTAssertNil(projects[1].repository)
        XCTAssertEqual(projects[1].domains, ["cli.tsilva.eu"])
        XCTAssertTrue(visited.contains { $0.contains("team-b") })
        XCTAssertFalse(visited.joined().contains { $0.contains("/env") })
    }

    func testPaginationFailureNeverReturnsACompleteLookingPartialInventory() throws {
        for mode in ["repeated-cursor", "missing-items", "provider-error", "full-without-pagination"] {
            var calls = 0
            XCTAssertThrowsError(try WebsiteDomainInventory.load { arguments in
                calls += 1
                if arguments[1].hasPrefix("/v2/teams") { return try json(["teams":[["slug":"team-a"]]]) }
                switch mode {
                case "repeated-cursor": return try json(["projects":[], "pagination":["next":1]])
                case "missing-items": return try json(["pagination":["next":NSNull()]])
                case "provider-error": return try json(["error":["message":"PRIVATE-PROVIDER-ERROR"]])
                default: return try JSONSerialization.data(withJSONObject:["projects":Array(repeating:["id":"prj_duplicate"], count:100)])
                }
            }, mode)
            XCTAssertLessThan(calls, 5, mode)
        }
    }

    func testFailedTeamListingDoesNotSilentlyFallBackToMetadataOrOneTeam() throws {
        for teams: Any in [[], [["slug":"bad/scope"]], "invalid"] {
            XCTAssertThrowsError(try WebsiteDomainInventory.load { _ in try json(["teams":teams]) })
        }
    }

    func testProbeCacheHonorsFreshRunsDomainChangesAndExpiry() async {
        let cache = WebsiteProbeCache(), calls = Calls()
        let loader: RepositoryWebsiteChecks.Loader = { _, _, _ in await calls.record(); return WebsiteProbe(status:200, isHTML:true) }
        let now = Date(), hosts: Set<String> = ["site.tsilva.eu"]
        _ = await cache.load("site.tsilva.eu", domains:hosts, allowCached:true, now:now, loader:loader)
        let reused = await cache.load("site.tsilva.eu", domains:hosts, allowCached:true, now:now.addingTimeInterval(1), loader:loader)
        XCTAssertTrue(reused.cached)
        let differentPath = await cache.load("site.tsilva.eu", path: "/chat", domains: hosts, allowCached: true, now: now.addingTimeInterval(1), loader: loader)
        XCTAssertFalse(differentPath.cached)
        let fresh = await cache.load("site.tsilva.eu", domains:hosts, allowCached:false, now:now.addingTimeInterval(2), loader:loader)
        XCTAssertFalse(fresh.cached)
        _ = await cache.load("site.tsilva.eu", domains:hosts.union(["www.tsilva.eu"]), allowCached:true, now:now.addingTimeInterval(3), loader:loader)
        _ = await cache.load("site.tsilva.eu", domains:hosts, allowCached:true, now:now.addingTimeInterval(400), loader:loader)
        let count = await calls.value(); XCTAssertEqual(count, 5)
    }

    func testInventoryCacheIsSharedButExplicitRefreshInvalidatesIt() async throws {
        let cache = WebsiteInventoryCache(), calls = Calls()
        let loader: WebsiteInventoryLoader = { await calls.record(); return [] }
        _ = try await cache.load(loader:loader)
        let reused = try await cache.load(loader:loader)
        XCTAssertTrue(reused.cached)
        await cache.invalidate()
        let fresh = try await cache.load(loader:loader)
        XCTAssertFalse(fresh.cached)
        let count = await calls.value(); XCTAssertEqual(count, 2)
    }
    private actor Calls {
        var count = 0
        func record() { count += 1 }
        func value() -> Int { count }
    }
}
