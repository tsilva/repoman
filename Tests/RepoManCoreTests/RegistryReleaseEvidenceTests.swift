import Foundation
import XCTest
@testable import RepoManCore

final class RegistryReleaseEvidenceTests: XCTestCase {
    private let now = RegistryReleaseEvidence.date("2026-10-10T12:00:00Z")!
    private let integrity = "sha512-" + Data(repeating: 1, count: 64).base64EncodedString()
    private func entry(_ ecosystem: String = "npm", name: String = "child", version: String = "1.0.0", integrity: String? = nil) -> DependencyLockInventory.Entry {
        .init(ecosystem: ecosystem, name: name, version: version, lockfile: ecosystem == "npm" ? "pnpm-lock.yaml" : "uv.lock",
              source: ecosystem, integrity: ecosystem == "npm" ? (integrity ?? self.integrity) : nil, tarball: nil)
    }
    private func npm(published: String = "2026-10-03T12:00:00Z", deprecated: Any? = nil) -> [String: Any] {
        var version: [String: Any] = ["name":"child", "version":"1.0.0", "dist":["integrity":integrity, "tarball":"https://registry.npmjs.org/child/-/child-1.0.0.tgz"]]
        if let deprecated { version["deprecated"] = deprecated }
        return ["name":"child", "time":["1.0.0":published], "versions":["1.0.0":version]]
    }
    private func pypi(_ times: [String] = ["2026-10-03T12:00:00Z"], yanked: Bool = false) -> [String: Any] {
        ["info":["name":"Some_Package", "version":"1.0.0"], "urls":times.map { ["upload_time_iso_8601":$0, "yanked":yanked] as [String: Any] }]
    }
    func testExactSevenDayBoundaryIsEligibleAndOneSecondBeforeIsTooYoung() {
        let old = RegistryReleaseEvidence.evaluate([entry()], document: npm(), at: now)
        XCTAssertEqual(old.ageEligible, true); XCTAssertEqual(old.eligibleAt, now)
        XCTAssertEqual(RegistryReleaseEvidence.evaluate([entry()], document: npm(), at: now.addingTimeInterval(-1)).ageEligible, false)
    }
    func testPublicIdentityDoesNotBorrowReleaseAgeOrRiskPolicy() {
        let document = npm(published: "invalid", deprecated: "Review release")
        XCTAssertTrue(RegistryReleaseEvidence.publicIdentity([entry()], document: document))
        XCTAssertNotNil(RegistryReleaseEvidence.evaluate([entry()], document: document, at: now).unknownReason)
        XCTAssertTrue(RegistryReleaseEvidence.publicIdentity([entry("pypi", name: "some-package")], document: pypi(["invalid"], yanked: true)))
    }
    func testPublicIdentityRejectsUnsupportedSourcesAndMismatchedArtifacts() {
        var unsupported = entry(); unsupported = .init(ecosystem: unsupported.ecosystem, name: unsupported.name,
            version: unsupported.version, lockfile: unsupported.lockfile, source: "unsupported", integrity: nil, tarball: nil)
        XCTAssertFalse(RegistryReleaseEvidence.publicIdentity([unsupported], document: npm()))
        XCTAssertFalse(RegistryReleaseEvidence.publicIdentity([entry(version: "2.0.0")], document: npm()))
        XCTAssertFalse(RegistryReleaseEvidence.publicIdentity([entry(integrity: "sha512-" + Data(repeating: 2, count: 64).base64EncodedString())], document: npm()))
        XCTAssertFalse(RegistryReleaseEvidence.publicIdentity([entry("pypi", name: "other")], document: pypi()))
        XCTAssertFalse(RegistryReleaseEvidence.publicIdentity([entry("pypi", name: "some-package")], document: pypi([])))
    }
    func testPyPINumericReleaseZeroPaddingDoesNotChangeIdentityOrBypassAge() {
        let locked = entry("pypi", name: "some-package", version: "13.0.3.0")
        var document = pypi(); document["info"] = ["name": "Some_Package", "version": "13.0.3"]
        XCTAssertTrue(RegistryReleaseEvidence.publicIdentity([locked], document: document))
        XCTAssertEqual(RegistryReleaseEvidence.evaluate([locked], document: document, at: now).ageEligible, true)
        document["urls"] = [["upload_time_iso_8601": "2026-10-09T00:00:00Z", "yanked": false]]
        XCTAssertEqual(RegistryReleaseEvidence.evaluate([locked], document: document, at: now).ageEligible, false)
        for wrong in ["13.0.4", "13.0.3.post1", "13.0.3+local", "13.0.3rc1", "13.0.3.1"] {
            document["info"] = ["name": "Some_Package", "version": wrong]
            XCTAssertFalse(RegistryReleaseEvidence.publicIdentity([locked], document: document), wrong)
        }
    }
    func testPublicationFractionBeyondMillisecondsIsNotRoundedDown() {
        let observed = RegistryReleaseEvidence.date("2026-10-10T12:00:00Z")!.addingTimeInterval(0.123)
        let verdict = RegistryReleaseEvidence.evaluate([entry()], document: npm(published:"2026-10-03T12:00:00.123456Z"), at: observed)
        XCTAssertEqual(verdict.ageEligible, false)
    }
    func testMissingMalformedTimezoneFreeAndFutureDatesRemainUnknown() {
        for date in ["missing", "2026-10-03T12:00:00", "2026-10-11T12:00:00Z"] {
            let verdict = RegistryReleaseEvidence.evaluate([entry()], document: npm(published: date), at: now)
            XCTAssertNil(verdict.ageEligible); XCTAssertNotNil(verdict.unknownReason)
        }
        XCTAssertNotNil(RegistryReleaseEvidence.date("2026-10-03T13:00:00.123+01:00"))
    }
    func testNPMDeprecatedRiskSurvivesMissingPublicationEvidence() {
        let verdict = RegistryReleaseEvidence.evaluate([entry()], document: npm(published:"invalid", deprecated:"Untrusted explanation CANARY"), at: now)
        XCTAssertEqual(verdict.risks, ["deprecated"]); XCTAssertNotNil(verdict.unknownReason)
        XCTAssertFalse(String(describing: verdict).contains("CANARY"))
    }
    func testNPMWrongPackageVersionOrArtifactCannotBorrowOldTimestamp() {
        var wrongName = npm(); wrongName["name"] = "other"
        XCTAssertNotNil(RegistryReleaseEvidence.evaluate([entry()], document: wrongName, at: now).unknownReason)
        let wrongVersion = entry(version:"2.0.0")
        XCTAssertNotNil(RegistryReleaseEvidence.evaluate([wrongVersion], document: npm(), at: now).unknownReason)
        let wrongHash = entry(integrity:"sha512-" + Data(repeating:2,count:64).base64EncodedString())
        XCTAssertNotNil(RegistryReleaseEvidence.evaluate([wrongHash], document: npm(), at: now).unknownReason)
        XCTAssertNotNil(RegistryReleaseEvidence.evaluate([entry(),wrongHash], document: npm(), at: now).unknownReason)
    }
    func testNPMLegacyTarballIdentityStillRequiresPublicMetadataMatch() {
        let exact = DependencyLockInventory.Entry(ecosystem:"npm",name:"child",version:"1.0.0",lockfile:"package-lock.json",source:"npm",integrity:nil,tarball:"https://registry.npmjs.org/child/-/child-1.0.0.tgz")
        XCTAssertEqual(RegistryReleaseEvidence.evaluate([exact], document:npm(), at:now).ageEligible,true)
        let wrong = DependencyLockInventory.Entry(ecosystem:"npm",name:"child",version:"1.0.0",lockfile:"package-lock.json",source:"npm",integrity:nil,tarball:"https://registry.npmjs.org/other/-/other-1.0.0.tgz")
        XCTAssertNotNil(RegistryReleaseEvidence.evaluate([wrong],document:npm(),at:now).unknownReason)
    }
    func testAnExplicitTarballCannotBorrowAnotherPackagesAgeEvenWithTheSameDigest() {
        let wrong = DependencyLockInventory.Entry(ecosystem:"npm",name:"child",version:"1.0.0",lockfile:"package-lock.json",source:"npm",integrity:integrity,tarball:"https://registry.npmjs.org/other/-/other-1.0.0.tgz")
        XCTAssertNotNil(RegistryReleaseEvidence.evaluate([wrong],document:npm(),at:now).unknownReason)
    }
    func testExtraOrInvalidIntegrityAlternativesCannotBorrowVerifiedArtifactEvidence() {
        let alternate="sha512-"+Data(repeating:2,count:64).base64EncodedString()
        for locked in [integrity+" "+alternate,integrity+" invalid-digest"] {
            XCTAssertNotNil(RegistryReleaseEvidence.evaluate([entry(integrity:locked)],document:npm(),at:now).unknownReason)
        }
    }
    func testNPMInvalidIntegrityOrDeprecationShapeCannotPass() {
        XCTAssertNotNil(RegistryReleaseEvidence.evaluate([entry(integrity:"sha512-not-a-digest")], document:npm(), at:now).unknownReason)
        XCTAssertNotNil(RegistryReleaseEvidence.evaluate([entry()], document:npm(deprecated:true), at:now).unknownReason)
    }
    func testPyPIUsesLatestArtifactAndConservativeYankedRisk() {
        let e=entry("pypi",name:"some-package")
        XCTAssertEqual(RegistryReleaseEvidence.evaluate([e],document:pypi(),at:now).ageEligible,true)
        let fresh=RegistryReleaseEvidence.evaluate([e],document:pypi(["2026-10-01T00:00:00Z","2026-10-09T00:00:00Z"]),at:now)
        XCTAssertEqual(fresh.ageEligible,false)
        let yanked=RegistryReleaseEvidence.evaluate([e],document:pypi(yanked:true),at:now)
        XCTAssertEqual(yanked.risks,["yanked"])
    }
    func testPyPIMissingOrWrongEvidenceCannotBecomeEligible() {
        let e=entry("pypi",name:"some-package")
        for doc in [pypi([]),["info":["name":"other","version":"1.0.0"],"urls":[]],pypi(["invalid"]) ] as [[String:Any]] {
            let result=RegistryReleaseEvidence.evaluate([e],document:doc,at:now)
            XCTAssertNil(result.ageEligible);XCTAssertNotNil(result.unknownReason)
        }
        var doc=pypi();doc["urls"]=[["upload_time_iso_8601":"2026-10-01T00:00:00Z"]]
        XCTAssertNotNil(RegistryReleaseEvidence.evaluate([e],document:doc,at:now).unknownReason)
    }
    func testNumericPyPIYankedFlagsCannotBeMistakenForBooleanEvidence() throws {
        for number in [0,1] {
            var doc=pypi();doc["urls"]=[["upload_time_iso_8601":"2026-10-03T12:00:00Z","yanked":number]]
            let parsed=try JSONSerialization.jsonObject(with:JSONSerialization.data(withJSONObject:doc)) as! [String:Any]
            XCTAssertNotNil(RegistryReleaseEvidence.evaluate([entry("pypi",name:"some-package")],document:parsed,at:now).unknownReason)
        }
    }
    func testUnsupportedSourcesAndEmptyInputsCannotBeMistakenForVerifiedEvidence() {
        let e=DependencyLockInventory.Entry(ecosystem:"npm",name:"child",version:"1.0.0",lockfile:"package-lock.json",source:"unsupported",integrity:nil,tarball:nil)
        XCTAssertNotNil(RegistryReleaseEvidence.evaluate([e],document:npm(),at:now).unknownReason)
        XCTAssertNotNil(RegistryReleaseEvidence.evaluate([],document:[:],at:now).unknownReason)
    }
    func testRegistryURLsEncodeIdentitiesWithoutQueryOrCredentials() {
        let npm=RegistryReleaseEvidence.url(entry(name:"@scope/child"))
        XCTAssertEqual(npm.host,"registry.npmjs.org");XCTAssertTrue(npm.absoluteString.contains("%2F"))
        XCTAssertNil(npm.user);XCTAssertNil(npm.query)
        let py=RegistryReleaseEvidence.url(entry("pypi",name:"some-package",version:"1.0+cpu"))
        XCTAssertTrue(py.absoluteString.contains("1.0%2Bcpu"));XCTAssertEqual(py.host,"pypi.org")
    }
    func testAnonymousTransportReadsOnlyExpectedBodyAndStripsCredentials() async throws {
        RegistryFixtureProtocol.configure(status:200,body:Data("{}".utf8))
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[RegistryFixtureProtocol.self]
        config.httpAdditionalHeaders=["Authorization":"CANARY","Cookie":"CANARY"]
        let data=try await PublicRegistryRequest.read(URL(string:"https://registry.npmjs.org/fixture")!,configuration:config)
        XCTAssertEqual(data,Data("{}".utf8))
        let headers=RegistryFixtureProtocol.request()?.allHTTPHeaderFields ?? [:]
        XCTAssertFalse(headers.keys.contains { ["authorization","cookie"].contains($0.lowercased()) })
    }
    func testStreamingTransportRejectsOversizedAndErrorResponses() async {
        for status in [200,404] {
            RegistryFixtureProtocol.configure(status:status,body:Data(repeating:1,count:1024))
            let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[RegistryFixtureProtocol.self]
            do { _=try await PublicRegistryRequest.read(URL(string:"https://registry.npmjs.org/fixture")!,maximumBytes:32,configuration:config);XCTFail("Expected bounded response rejection") }
            catch { XCTAssertFalse(String(describing:error).contains("CANARY")) }
        }
    }
    func testUnsupportedTransportHostsAndCredentialURLsAreRejectedBeforeRequests() async {
        for raw in ["http://registry.npmjs.org/x","https://private.invalid/x","https://user:CANARY@registry.npmjs.org/x","https://pypi.org/x?token=CANARY"] {
            do { _=try await PublicRegistryRequest.read(URL(string:raw)!);XCTFail("Expected unsupported URL rejection") }
            catch { XCTAssertFalse(String(describing:error).contains("CANARY")) }
        }
    }
    private func advisoryQuery() throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.osv.dev/v1/querybatch")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["queries": [
            ["package": ["ecosystem": "npm", "name": "child"], "version": "1.0.0"]
        ]])
        return request
    }
    func testAdvisoryTransportPostsTypedQueriesWithoutAmbientCredentials() async throws {
        RegistryFixtureProtocol.configure(status: 200, body: Data("{\"results\":[{}]}".utf8))
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RegistryFixtureProtocol.self]
        config.httpAdditionalHeaders = ["Authorization": "CANARY", "Cookie": "CANARY"]
        _ = try await PublicRegistryRequest.advisory(advisoryQuery(), configuration: config)
        let request = try XCTUnwrap(RegistryFixtureProtocol.request())
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.osv.dev/v1/querybatch")
        XCTAssertFalse((request.allHTTPHeaderFields ?? [:]).keys.contains { ["authorization", "cookie"].contains($0.lowercased()) })
    }
    func testAdvisoryTransportReadsOnlyFixedDetailPaths() async throws {
        RegistryFixtureProtocol.configure(status: 200, body: Data("{}".utf8))
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RegistryFixtureProtocol.self]
        let request = URLRequest(url: URL(string: "https://api.osv.dev/v1/vulns/GHSA-fixture")!)
        _ = try await PublicRegistryRequest.advisory(request, configuration: config)
        XCTAssertEqual(RegistryFixtureProtocol.request()?.httpMethod, "GET")
        do { _ = try await PublicRegistryRequest.read(request.url!); XCTFail("Registry-only access must stay registry-only") }
        catch { XCTAssertFalse(String(describing: error).contains("CANARY")) }
    }
    func testAdvisoryTransportRejectsOtherDestinationsPayloadFieldsAndCredentialsBeforeSending() async throws {
        var requests: [URLRequest] = []
        for raw in ["http://api.osv.dev/v1/querybatch", "https://private.invalid/v1/querybatch", "https://user:CANARY@api.osv.dev/v1/querybatch", "https://api.osv.dev/v1/querybatch?token=CANARY", "https://api.osv.dev/v1/vulns/a%2Fb"] {
            var request = try advisoryQuery(); request.url = URL(string: raw)!; requests.append(request)
        }
        var credential = try advisoryQuery(); credential.setValue("CANARY", forHTTPHeaderField: "Authorization"); requests.append(credential)
        var method = try advisoryQuery(); method.httpMethod = "DELETE"; requests.append(method)
        for path in ["https://api.osv.dev/v1/vulns/a%2Fb", "https://api.osv.dev/v1/vulns/GHSA-fixture%0A", "https://api.osv.dev/v1/querybatch"] {
            requests.append(URLRequest(url: URL(string: path)!))
        }
        var control = try advisoryQuery()
        control.httpBody = try JSONSerialization.data(withJSONObject: ["queries": [["package": ["ecosystem": "npm", "name": "child"], "version": "1.0.0\n"]]])
        requests.append(control)
        var extra = try advisoryQuery()
        extra.httpBody = Data("{\"queries\":[{\"package\":{\"ecosystem\":\"npm\",\"name\":\"child\"},\"version\":\"1.0.0\",\"repository\":\"CANARY\"}]}".utf8)
        requests.append(extra)
        var empty = try advisoryQuery(); empty.httpBody = Data("{\"queries\":[]}".utf8); requests.append(empty)
        var token = try advisoryQuery()
        token.httpBody = try JSONSerialization.data(withJSONObject: ["queries": [["package": ["ecosystem": "PyPI", "name": "child"], "version": "1.0.0", "page_token": String(repeating: "x", count: 1_025)]]])
        requests.append(token)
        for request in requests {
            RegistryFixtureProtocol.configure(status: 200, body: Data("{}".utf8))
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RegistryFixtureProtocol.self]
            do { _ = try await PublicRegistryRequest.advisory(request, configuration: config); XCTFail("Expected unsupported request rejection") }
            catch { XCTAssertFalse(String(describing: error).contains("CANARY")) }
            XCTAssertNil(RegistryFixtureProtocol.request())
        }
    }
    func testAdvisoryTransportKeepsStreamingBounds() async throws {
        RegistryFixtureProtocol.configure(status: 200, body: Data(repeating: 1, count: 128))
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RegistryFixtureProtocol.self]
        do { _ = try await PublicRegistryRequest.advisory(advisoryQuery(), maximumBytes: 32, configuration: config); XCTFail("Expected response limit") }
        catch { XCTAssertFalse(String(describing: error).contains("CANARY")) }
    }
}

private final class RegistryFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock=NSLock()
    private static var body=Data(),status=200,lastRequest:URLRequest?
    static func configure(status:Int,body:Data) { lock.lock();defer{lock.unlock()};self.status=status;self.body=body;lastRequest=nil }
    static func request()->URLRequest? { lock.lock();defer{lock.unlock()};return lastRequest }
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        Self.lock.lock();Self.lastRequest=request;let body=Self.body,status=Self.status;Self.lock.unlock()
        let response=HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"application/json"])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:body);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
