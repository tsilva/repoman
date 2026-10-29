import Foundation
import XCTest
@testable import RepoManCore

final class GoDependencyChecksTests: XCTestCase {
    private var root: URL!
    private let at = RegistryReleaseEvidence.date("2026-10-29T18:00:00Z")!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("repoman-go-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        _ = try GitRunner.run(["init", "-b", "main"], at: root)
        for (key, value) in [("user.name", "Fixture"), ("user.email", "fixture@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] {
            _ = try GitRunner.run(["config", key, value], at: root)
        }
        try write("README.md", "Fixture\n"); _ = try commit()
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func write(_ path: String, _ text: String) throws { try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8) }
    private func commit() throws -> String {
        _ = try GitRunner.run(["add", "."], at: root); _ = try GitRunner.run(["commit", "-m", "Fixture"], at: root)
        return try GitRunner.text(["rev-parse", "HEAD"], at: root)
    }
    private func fixture(_ version: String = "v0.28.0") throws {
        try write("go.mod", "module fixture\n\ngo 1.18\nrequire golang.org/x/sys " + version + "\n")
        try write("go.sum", GoEvidenceFixture.sums(version))
    }
    private func inspect(_ checks: [RepositoryCheck]) async throws -> RepositoryInspectionReport {
        await RepositoryIssueCatalog(checks: checks).inspect(try GitRepositoryScanner.scan(root, includeDetails: false), forceRefresh: true)
    }
    func testGoAdvisoryQueryUsesSelectedVersionsAndFindsRealMatch() async throws {
        try fixture(); try write("go.sum", GoEvidenceFixture.sums() + GoEvidenceFixture.sums("v0.27.0"))
        let capture = DependencyVulnerabilityCapture()
        let checks = RepositoryVulnerabilityChecks.checks(registry: GoEvidenceFixture.registry(), advisory: { request, _ in
            if request.httpMethod == "POST" {
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                let queries = body["queries"] as! [[String: Any]]
                XCTAssertEqual(queries.count, 1); XCTAssertEqual(queries[0]["version"] as? String, "v0.28.0")
                XCTAssertEqual((queries[0]["package"] as? [String: String])?["ecosystem"], "Go")
                return Data(#"{"results":[{"vulns":[{"id":"GO-2026-fixture"}]}]}"#.utf8)
            }
            return Data(#"{"id":"GO-2026-fixture","modified":"2026-10-01T00:00:00Z","affected":[{"package":{"ecosystem":"Go","name":"golang.org/x/sys"}}],"summary":"Fixture advisory","database_specific":{"severity":"HIGH"}}"#.utf8)
        }, go: GoEvidenceFixture.graph, record: { capture.record($0) })
        let report = try await inspect(checks)
        XCTAssertEqual(report.status(for: RepositoryVulnerabilityChecks.id), .findings)
        XCTAssertEqual(report.findings().map(\.subject), ["go:golang.org/x/sys@v0.28.0#GO-2026-fixture"])
        XCTAssertEqual(capture.value?.versions.map(\.status), ["vulnerable"])
        XCTAssertEqual(Set(capture.value!.inputs.map(\.path)), ["go.mod", "go.sum"])
    }
    func testUnaffectedGraphPassesAndMissingCacheStaysIncompleteWithoutPublicCalls() async throws {
        try fixture()
        let good = try await inspect(RepositoryVulnerabilityChecks.checks(registry: GoEvidenceFixture.registry(), advisory: { _, _ in Data(#"{"results":[{}]}"#.utf8) }, go: GoEvidenceFixture.graph))
        XCTAssertEqual(good.status(for: RepositoryVulnerabilityChecks.id), .passed)
        let unavailable = try await inspect(RepositoryVulnerabilityChecks.checks(registry: { _, _ in XCTFail("No unverified module requests"); return Data() },
            advisory: { _, _ in XCTFail("No advisory request without complete graph"); return Data() },
            go: { _, _, _, _ in throw InspectionError.blocked("PRIVATE_CANARY") }))
        XCTAssertEqual(unavailable.status(for: RepositoryVulnerabilityChecks.id), .incomplete)
    }
    func testPrivateSelectedGraphIsWithheldFromAllPublicClients() async throws {
        try fixture()
        let report = try await inspect(RepositoryVulnerabilityChecks.checks(registry: { _, _ in XCTFail("Private identity leaked"); return Data() },
            advisory: { _, _ in XCTFail("Private identity leaked to OSV"); return Data() }, go: { module, sums, root, timeout in
                var object = try JSONSerialization.jsonObject(with: GoEvidenceFixture.graph(module, sums, root, timeout)) as! [String: Any]
                object["privatePatterns"] = ["golang.org/x/*"]
                return try JSONSerialization.data(withJSONObject: object)
            }, goRepository: { _, _ in XCTFail("No private hosting lookup"); return Data() }))
        XCTAssertEqual(report.status(for: RepositoryVulnerabilityChecks.id), .incomplete)
    }
    func testComparisonUsesExactBaseAndBindsBothModuleAndSumFiles() async throws {
        try fixture("v0.27.0"); let base = try commit(); try fixture()
        let capture = DependencyComparisonCapture()
        let report = try await inspect(RepositoryReleaseAgeChecks.checks(base: base, at: at, request: GoEvidenceFixture.registry(), go: GoEvidenceFixture.graph,
            goManifest: GoEvidenceFixture.manifest, record: { capture.record($0) }))
        XCTAssertEqual(report.status(for: RepositoryReleaseAgeChecks.id), .passed)
        XCTAssertEqual(capture.value?.baseCommit, base)
        XCTAssertEqual(capture.value?.introduced.map(\.identity), ["go:golang.org/x/sys@v0.28.0"])
        XCTAssertNil(capture.value?.introduced.first?.publishedAt)
        XCTAssertNotNil(capture.value?.introduced.first?.firstSeenAt)
        XCTAssertEqual(capture.value?.inputs.filter { ["go.mod", "go.sum"].contains($0.path) }.count, 4)
        XCTAssertEqual(try GitRunner.text(["rev-parse", "HEAD"], at: root), base)
    }
    func testMissingBaseGraphCannotInventAnIntroducedSetOrReadPublicServices() async throws {
        try fixture("v0.27.0"); let base = try commit(); try fixture()
        let capture = DependencyComparisonCapture()
        let report = try await inspect(RepositoryReleaseAgeChecks.checks(base: base, at: at, request: { _, _ in XCTFail("No requests with unknown baseline"); return Data() },
            go: { module, sums, root, timeout in
                if module.contains("v0.27.0") { throw InspectionError.blocked("Missing cache") }
                return try GoEvidenceFixture.graph(module, sums, root, timeout)
            }, record: { capture.record($0) }))
        XCTAssertEqual(report.status(for: RepositoryReleaseAgeChecks.id), .incomplete)
        XCTAssertEqual(capture.value?.introduced.count, 0)
    }
    func testUnchangedVersionAndHistoricalSumAdditionNeedNoAgeRequest() async throws {
        try fixture(); let base = try commit(); try write("go.sum", GoEvidenceFixture.sums() + GoEvidenceFixture.sums("v0.27.0"))
        let capture = DependencyComparisonCapture()
        let report = try await inspect(RepositoryReleaseAgeChecks.checks(base: base, at: at, request: { _, _ in XCTFail("No new selected versions"); return Data() },
            go: GoEvidenceFixture.graph, record: { capture.record($0) }))
        XCTAssertEqual(report.status(for: RepositoryReleaseAgeChecks.id), .passed)
        XCTAssertTrue(capture.value!.introduced.isEmpty)
    }
    func testWorkspaceAndReplacementAreIncompleteBeforePublicOrGoCalls() async throws {
        try fixture(); let base = try commit()
        try write("go.work", "go 1.25\nuse .\n")
        for checks in [RepositoryReleaseAgeChecks.checks(base: base, request: { _, _ in XCTFail(); return Data() }, go: { _, _, _, _ in XCTFail(); return Data() }),
                       RepositoryVulnerabilityChecks.checks(registry: { _, _ in XCTFail(); return Data() }, go: { _, _, _, _ in XCTFail(); return Data() })] {
            let result = try await inspect(checks)
            XCTAssertEqual(result.status(for: checks[0].id), .incomplete)
        }
        try FileManager.default.removeItem(at: root.appendingPathComponent("go.work"))
        try write("go.mod", "module fixture\nreplace golang.org/x/sys => ../private\n")
        let report = try await inspect(RepositoryVulnerabilityChecks.checks(registry: { _, _ in XCTFail(); return Data() }, go: { _, _, _, _ in XCTFail(); return Data() }))
        XCTAssertEqual(report.status(for: RepositoryVulnerabilityChecks.id), .incomplete)
    }
    func testCanonicalGoRangesPreserveMatchesAndSurfaceDisagreements() throws {
        let entry = GoEvidenceFixture.entry
        for (range, status) in [("< 0.29.0", "consistent"), ("< 0.27.0", "disagreement"), ("~0.28.0", "unavailable")] {
            let data = try JSONSerialization.data(withJSONObject: ["ghsa_id": "GHSA-fixture", "updated_at": "2026-10-01T00:00:00Z",
                "vulnerabilities": [["package": ["ecosystem": "go", "name": entry.name], "vulnerable_version_range": range]]])
            XCTAssertEqual(CanonicalGHSAEvidence.inspect(data, id: "GHSA-fixture", entry: entry, at: at).status, status)
        }
    }
}

final class GoReleaseEvidenceTests: XCTestCase {
    private let at = RegistryReleaseEvidence.date("2026-10-29T18:00:00Z")!
    private func evaluate(_ request: @escaping GoPublicModuleEvidence.Request, manifest: GoReleaseEvidence.Manifest = GoEvidenceFixture.manifest) async -> RegistryReleaseEvidence.Verdict {
        await GoReleaseEvidence.evaluate([GoEvidenceFixture.entry], repositories: [:], root: URL(fileURLWithPath: "/tmp/fixture"), at: at,
            request: request, manifest: manifest, deadline: Date().addingTimeInterval(20))
    }
    func testOldCommitWithRecentIndexObservationDoesNotProveAgeOrYoungPublication() async {
        let value = await evaluate(GoEvidenceFixture.registry(seen: "2026-10-28T00:00:00Z"))
        XCTAssertNil(value.ageEligible); XCTAssertNil(value.publishedAt); XCTAssertNotNil(value.unknownReason)
    }
    func testOldPublicObservationProvesMinimumAgeWithoutInventingPublicationTime() async {
        let value = await evaluate(GoEvidenceFixture.registry())
        XCTAssertEqual(value.ageEligible, true); XCTAssertNil(value.publishedAt)
        XCTAssertEqual(value.firstSeenAt, RegistryReleaseEvidence.date("2024-12-03T00:00:00Z"))
        XCTAssertEqual(URL(string: value.evidenceURL!)?.host, "index.golang.org")
    }
    func testMissingIndexEvidenceCannotFallbackToOldCommitDate() async {
        let value = await evaluate(GoEvidenceFixture.registry(seen: nil))
        XCTAssertNil(value.ageEligible); XCTAssertNotNil(value.unknownReason)
    }
    func testRetractedAndDeprecatedVersionsNeedReviewEvenWhenOld() async {
        let value = await evaluate(GoEvidenceFixture.registry(), manifest: { _, _, _ in
            Data(#"{"Module":{"Path":"golang.org/x/sys","Deprecated":"Use successor"},"Retract":[{"Low":"v0.28.0","High":"v0.28.0"}]}"#.utf8)
        })
        XCTAssertEqual(Set(value.risks), ["retracted", "deprecated"]); XCTAssertEqual(value.ageEligible, true)
    }
    func testKnownRetractionSurvivesMissingAgeEvidence() async {
        let value = await evaluate(GoEvidenceFixture.registry(seen: nil), manifest: { _, _, _ in
            Data(#"{"Module":{"Path":"golang.org/x/sys"},"Retract":[{"Low":"v0.28.0","High":"v0.28.0"}]}"#.utf8)
        })
        XCTAssertEqual(value.risks, ["retracted"]); XCTAssertNotNil(value.unknownReason)
    }
    func testUnsupportedRetractionEvidenceAndModifiedPublicManifestRemainUnknown() async {
        let unsupported = await evaluate(GoEvidenceFixture.registry(), manifest: { _, _, _ in Data(#"{"Module":{"Path":"wrong"}}"#.utf8) })
        XCTAssertNotNil(unsupported.unknownReason); XCTAssertNil(unsupported.ageEligible)
        let original = GoEvidenceFixture.registry()
        let altered = await evaluate({ url, timeout in
            if url.path.hasSuffix(".mod") { return Data("module wrong\n".utf8) }
            return try await original(url, timeout)
        })
        XCTAssertNotNil(altered.unknownReason); XCTAssertNil(altered.ageEligible)
    }
    func testIndexRejectsOutOfOrderFutureAndWrongShapeRows() {
        for text in [#"{"Path":"golang.org/x/sys","Version":"v0.28.0","Timestamp":"2099-01-01T00:00:00Z"}"#,
                     #"{"Path":"golang.org/x/sys","Version":"v0.28.0","Timestamp":"2023-01-01T00:00:00Z"}"#, "{}"] {
            XCTAssertThrowsError(try GoReleaseEvidence.page(Data(text.utf8), name: "golang.org/x/sys", version: "v0.28.0", since: RegistryReleaseEvidence.date("2024-01-01T00:00:00Z")!, at: at))
        }
    }
    func testUnrelatedPublicIndexNamespacesDoNotInvalidateASelectedMatch() throws {
        let text = #"{"Path":"git.sr.ht/~owner/module","Version":"v1.0.0+other","Timestamp":"2024-12-03T00:00:00Z"}"# + "\n" +
                   #"{"Path":"golang.org/x/sys","Version":"v0.28.0","Timestamp":"2024-12-03T01:00:00Z"}"#
        let page = try GoReleaseEvidence.page(Data(text.utf8), name: "golang.org/x/sys", version: "v0.28.0", since: RegistryReleaseEvidence.date("2024-12-02T00:00:00Z")!, at: at)
        XCTAssertEqual(page.seen, RegistryReleaseEvidence.date("2024-12-03T01:00:00Z")); XCTAssertEqual(page.count, 2)
    }
}

private enum GoEvidenceFixture {
    static let zip = "h1:Fksou7UEQUWlKvIdsqzJmUmCX3cZuD2+P3XyyzwMhlA="
    static let mod = "h1:/VUhepiaJMQUp4+oa/7Zr1D23ma6VTLIYjOOTFZPUcA="
    static let manifestText = "module golang.org/x/sys\n\ngo 1.18\n"
    static var entry: DependencyLockInventory.Entry {
        var value = DependencyLockInventory.Entry(ecosystem: "go", name: "golang.org/x/sys", version: "v0.28.0", lockfile: "go.mod", source: "go", integrity: zip, tarball: nil)
        value.goModIntegrity = mod; return value
    }
    static func sums(_ version: String = "v0.28.0") -> String { "golang.org/x/sys " + version + " " + zip + "\ngolang.org/x/sys " + version + "/go.mod " + mod + "\n" }
    static let graph: GoModuleInventory.Request = { module, sum, root, timeout in
        let version = module.contains("v0.27.0") ? "v0.27.0" : "v0.28.0"
        return try JSONSerialization.data(withJSONObject: ["privatePatterns": [], "modules": [["Path": "fixture", "Main": true],
            ["Path": "golang.org/x/sys", "Version": version, "Sum": zip, "GoModSum": mod]]])
    }
    static let manifest: GoReleaseEvidence.Manifest = { _, _, _ in Data(#"{"Module":{"Path":"golang.org/x/sys"},"Retract":null}"#.utf8) }
    static func registry(seen: String? = "2024-12-03T00:00:00Z") -> GoPublicModuleEvidence.Request {
        { url, _ in
            if url.host == "sum.golang.org" { return Data(("32453494\n" + sums() + "\ngo.sum database tree\n70402709\n").utf8) }
            if url.path.hasSuffix(".mod") { return Data(manifestText.utf8) }
            if url.host == "proxy.golang.org" { return Data(#"{"Version":"v0.28.0","Time":"2024-12-02T00:00:00Z"}"#.utf8) }
            if url.host == "index.golang.org" {
                guard let seen else { return Data() }
                return try JSONSerialization.data(withJSONObject: ["Path": "golang.org/x/sys", "Version": "v0.28.0", "Timestamp": seen])
            }
            throw InspectionError.blocked("Unexpected public request")
        }
    }
}
