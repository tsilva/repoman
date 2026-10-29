import Foundation
import XCTest
@testable import RepoManCore

final class CanonicalGHSAEvidenceTests: XCTestCase {
    private let id = "GHSA-fixture"
    private var entry: DependencyLockInventory.Entry { .init(ecosystem: "npm", name: "sandbox", version: "3.4.0", lockfile: "pnpm-lock.yaml", source: "npm", integrity: nil, tarball: nil) }
    private func document(_ ranges: [String], name: String = "sandbox", id: String = "GHSA-fixture", withdrawn: String? = nil) throws -> Data {
        var value: [String: Any] = ["ghsa_id": id, "updated_at": "2000-01-01T00:00:00Z", "vulnerabilities": ranges.map { ["package": ["ecosystem": "npm", "name": name], "vulnerable_version_range": $0] }]
        if let withdrawn { value["withdrawn_at"] = withdrawn }
        return try JSONSerialization.data(withJSONObject: value)
    }
    func testCanonicalHistoricalBoundProducesDisagreementRatherThanAnUnaffectedPass() throws {
        let verdict = CanonicalGHSAEvidence.inspect(try document([">= 0.0.0, < 1.0.0"]), id: id, entry: entry, at: Date())
        XCTAssertEqual(verdict.status, "disagreement"); XCTAssertEqual(verdict.ranges, [">= 0.0.0, < 1.0.0"])
    }
    func testCanonicalAffectedRangeConfirmsTheExistingVersionMatch() throws {
        XCTAssertEqual(CanonicalGHSAEvidence.inspect(try document([">=3.0.0, <4.0.0"]), id: id, entry: entry, at: Date()).status, "consistent")
    }
    func testMismatchedIdentityMissingPackageAndMalformedRangesStayUnavailable() throws {
        for data in [try document(["*"], id: "GHSA-other"), try document(["*"], name: "other"), try document(["<1.0.0 || dynamic"]), Data("invalid".utf8)] {
            XCTAssertEqual(CanonicalGHSAEvidence.inspect(data, id: id, entry: entry, at: Date()).status, "unavailable")
        }
    }
    func testWithdrawnCanonicalRecordIsAConflictAndInvalidWithdrawalIsUnknown() throws {
        XCTAssertEqual(CanonicalGHSAEvidence.inspect(try document(["*"], withdrawn: "2000-01-01T00:00:00Z"), id: id, entry: entry, at: Date()).status, "disagreement")
        XCTAssertEqual(CanonicalGHSAEvidence.inspect(try document(["*"], withdrawn: "invalid"), id: id, entry: entry, at: Date()).status, "unavailable")
    }
    func testNPMBoundsUnionAndUnsupportedAlternativesAreConservative() {
        let examples: [(String, String, Bool?)] = [("3.4.0", ">=0.0.0, <1.0.0", false), ("0.8.2", ">=0.0.0, <1.0.0", true),
            ("1.0.0", "<1.0.0", false), ("1.0.0", "<=1.0.0", true), ("2.0.0", "<1.0.0 || >=2.0.0, <3.0.0", true),
            ("3.4.0", "<1.0.0 || unsupported", nil), ("0.8.2", "<1.0.0 || unsupported", true),
            ("3.4.0", "<1.0.0,", nil), ("3.4.0", "", nil), ("3.4.0-beta.1", "<4.0.0", nil)]
        for (version, range, expected) in examples { XCTAssertEqual(CanonicalGHSAEvidence.contains(version, range: range, ecosystem: "npm"), expected, version + " " + range) }
    }
    func testClientCapAndExpiredDeadlineDoNotStartRequestsOrCertifyEvidence() async {
        let calls = CanonicalRequests()
        let capped = await CanonicalGHSAClient.fetch(Set((0..<65).map { "GHSA-fixture-" + String($0) }), request: { id, _ in calls.append(id); return Data() }, deadline: Date().addingTimeInterval(10))
        XCTAssertEqual(capped.count, 65); XCTAssertTrue(capped.values.allSatisfy { $0.data == nil && $0.reason != nil })
        let expired = await CanonicalGHSAClient.fetch(["GHSA-fixture"], request: { id, _ in calls.append(id); return Data() }, deadline: .distantPast)
        XCTAssertNil(expired["GHSA-fixture"]?.data); XCTAssertTrue(calls.values.isEmpty)
    }
    func testOversizedAndFailedClientResponsesStayUnknownWithoutProviderOutput() async {
        let oversized = await CanonicalGHSAClient.fetch(["GHSA-fixture"], request: { _, _ in Data(repeating: 65, count: 2_097_152) }, deadline: Date().addingTimeInterval(10))
        XCTAssertNil(oversized["GHSA-fixture"]?.data)
        let failed = await CanonicalGHSAClient.fetch(["GHSA-fixture"], request: { _, _ in throw InspectionError.blocked("PRIVATE_CANARY") }, deadline: Date().addingTimeInterval(10))
        XCTAssertNil(failed["GHSA-fixture"]?.data); XCTAssertFalse(failed["GHSA-fixture"]!.reason!.contains("PRIVATE_CANARY"))
    }
    func testDefaultClientRejectsPathAndOptionInjectionBeforeLaunchingGH() async {
        for value in ["../private", "GHSA-../../private", "GHSA-private\nCANARY", "--hostname=private.invalid"] {
            do { _ = try await CanonicalGHSAClient.read(value, timeout: 1); XCTFail("Invalid advisory request was accepted") }
            catch { }
        }
    }
    func testPythonStableZeroPaddingAndUnsupportedPublicVersions() {
        XCTAssertEqual(CanonicalGHSAEvidence.contains("5.6.3", range: "<= 5.6.3", ecosystem: "pypi"), true)
        XCTAssertEqual(CanonicalGHSAEvidence.contains("5.6.4", range: "<= 5.6.3", ecosystem: "pypi"), false)
        XCTAssertEqual(CanonicalGHSAEvidence.contains("1.0.0.0", range: "== 1.0", ecosystem: "pypi"), true)
        XCTAssertEqual(CanonicalGHSAEvidence.contains("1.0", range: ">= 0.5, != 1.0", ecosystem: "pypi"), false)
        for version in ["1.0rc1", "1.0.post1", "1.0+local"] { XCTAssertNil(CanonicalGHSAEvidence.contains(version, range: "<2", ecosystem: "pypi")) }
        XCTAssertNil(CanonicalGHSAEvidence.contains("1.0", range: "~=1.0", ecosystem: "pypi"))
    }
}

private final class CanonicalRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    func append(_ id: String) { lock.lock(); defer { lock.unlock() }; ids.append(id) }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return ids }
}
