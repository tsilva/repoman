import Foundation
import XCTest
@testable import RepoManCore

final class GoPublicModuleEvidenceTests: XCTestCase {
    // Independently retrieved from proxy.golang.org and sum.golang.org for x/sys v0.28.0.
    private let zip = "h1:Fksou7UEQUWlKvIdsqzJmUmCX3cZuD2+P3XyyzwMhlA="
    private let mod = "h1:/VUhepiaJMQUp4+oa/7Zr1D23ma6VTLIYjOOTFZPUcA="
    private var lookup: Data { Data(("32453494\ngolang.org/x/sys v0.28.0 " + zip + "\ngolang.org/x/sys v0.28.0/go.mod " + mod + "\n\ngo.sum database tree\n70402709\n").utf8) }
    private func entry(_ name: String = "golang.org/x/sys", source: String = "go") -> DependencyLockInventory.Entry {
        var value = DependencyLockInventory.Entry(ecosystem: "go", name: name, version: "v0.28.0", lockfile: "go.mod", source: source, integrity: zip, tarball: nil)
        value.goModIntegrity = mod
        return value
    }
    func testRealGoModHashMatchesPublicChecksumDatabase() throws {
        XCTAssertEqual(GoPublicModuleEvidence.moduleHash("module golang.org/x/sys\n\ngo 1.18\n"), mod)
        let records = try GoPublicModuleEvidence.checksumRecords(lookup, name: "golang.org/x/sys", version: "v0.28.0")
        XCTAssertEqual(records.zip, zip); XCTAssertEqual(records.module, mod)
    }
    func testPublicChecksumProofAndChangedOrMissingHashes() async {
        let bytes = lookup
        let good = await GoPublicModuleEvidence.publicProof([entry()], repositories: [:], request: { _, _ in bytes }, deadline: Date().addingTimeInterval(10))
        XCTAssertTrue(good.verified)
        var altered = entry(); altered.goModIntegrity = "h1:" + Data(repeating: 1, count: 32).base64EncodedString()
        let bad = await GoPublicModuleEvidence.publicProof([altered], repositories: [:], request: { _, _ in bytes }, deadline: Date().addingTimeInterval(10))
        XCTAssertFalse(bad.verified)
        var missing = entry(); missing.goModIntegrity = nil
        missing = .init(ecosystem: "go", name: missing.name, version: missing.version, lockfile: "go.mod", source: "go", integrity: nil, tarball: nil)
        let absent = await GoPublicModuleEvidence.publicProof([missing], repositories: [:], request: { _, _ in bytes }, deadline: Date().addingTimeInterval(10))
        XCTAssertFalse(absent.verified)
    }
    func testPrivateUnknownAndUnprovedGitHubModulesSendNoPublicRequests() async {
        let calls = EvidenceCalls()
        let request: GoPublicModuleEvidence.Request = { _, _ in calls.increment(); return Data() }
        for entries in [[], [entry("private.example.invalid/secret")], [entry(source: "unsupported")], [entry("github.com/company/secret")]] {
            let result = await GoPublicModuleEvidence.publicProof(entries, repositories: [:], request: request, deadline: Date().addingTimeInterval(10))
            XCTAssertFalse(result.verified)
        }
        XCTAssertEqual(calls.value, 0)
    }
    func testGitHubProofRequiresExactPublicRepositoryAndRealBoolean() throws {
        for object: [String: Any] in [
            ["full_name": "owner/repo", "private": true, "visibility": "private"],
            ["full_name": "other/repo", "private": false, "visibility": "public"],
            ["full_name": "owner/repo", "private": 0, "visibility": "public"],
            ["full_name": "owner/repo", "private": false]
        ] { XCTAssertFalse(GoPublicRepositoryClient.verify(try JSONSerialization.data(withJSONObject: object), repository: "owner/repo")) }
        XCTAssertTrue(GoPublicRepositoryClient.verify(try JSONSerialization.data(withJSONObject: ["full_name": "Owner/Repo", "private": false, "visibility": "public"]), repository: "owner/repo"))
    }
    func testChecksumParserRejectsWrongIdentityDuplicatesAndMalformedRecords() {
        for bytes in [Data(), Data("1\n\ngo.sum database tree\n".utf8),
                      Data(String(decoding: lookup, as: UTF8.self).replacingOccurrences(of: "v0.28.0", with: "v0.27.0").utf8),
                      Data(("1\ngolang.org/x/sys v0.28.0 " + zip + "\ngolang.org/x/sys v0.28.0 " + zip + "\n\ngo.sum database tree\n").utf8)] {
            XCTAssertThrowsError(try GoPublicModuleEvidence.checksumRecords(bytes, name: "golang.org/x/sys", version: "v0.28.0"))
        }
    }
    func testPublicURLAllowlistRejectsCredentialsTraversalArbitraryQueriesAndUncachedFetches() {
        for text in ["https://proxy.golang.org/golang.org/x/sys/@v/v0.28.0.mod", "https://sum.golang.org/lookup/private.invalid/secret@v1.0.0",
                     "https://user@sum.golang.org/lookup/golang.org/x/sys@v0.28.0", "https://index.golang.org/index?since=2026-01-01T00:00:00Z&limit=2001&include=all",
                     "https://proxy.golang.org/cached-only/golang.org/x/sys/@v/v0.28.0.zip", "https://sum.golang.org/lookup/golang.org/x/sys@v0.28.0?extra=1"] {
            XCTAssertFalse(GoPublicModuleEvidence.allowed(URL(string: text)!))
        }
        XCTAssertTrue(GoPublicModuleEvidence.allowed(GoPublicModuleEvidence.checksumURL(entry())))
        XCTAssertTrue(GoPublicModuleEvidence.allowed(GoPublicModuleEvidence.proxyURL("github.com/Azure/azure-sdk-for-go", version: "v1.0.0", suffix: "mod")))
        XCTAssertTrue(GoPublicModuleEvidence.allowed(URL(string: "https://index.golang.org/index?since=2026-01-01T00:00:00Z&limit=2000&include=all")!))
    }
}

private final class EvidenceCalls: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
}
