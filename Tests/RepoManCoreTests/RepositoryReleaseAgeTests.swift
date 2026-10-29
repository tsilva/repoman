import Foundation
import XCTest
@testable import RepoManCore

final class RepositoryReleaseAgeTests: XCTestCase {
    private var root: URL!
    private let at=RegistryReleaseEvidence.date("2026-10-10T12:00:00Z")!
    private let lockedDigest="sha512-" + Data(repeating:1,count:64).base64EncodedString()
    override func setUpWithError() throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("RepoManAge-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        _=try GitRunner.run(["init","-b","main"],at:root)
        for (key,value) in [("user.name","Fixture"),("user.email","fixture@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try GitRunner.run(["config",key,value],at:root)}
        try write("README.md","Fixture\n");_=try commit()
    }
    override func tearDownWithError() throws {try FileManager.default.removeItem(at:root)}
    func testReleaseAgeComparisonIsRegisteredAndRequiresRemoteOptIn() {
        let check=RepositoryIssueCatalog.standardChecks.first{$0.id=="dependencies.releaseAge"}
        XCTAssertNotNil(check);XCTAssertEqual(check?.requiresRemoteAccess,true)
    }
    func testNoImplicitBaseOrRegistryRequest() async throws {
        let requests=AgeRequests(),capture=DependencyComparisonCapture()
        let report=try await inspect(nil,capture:capture,request:{url,_ in requests.append(url);throw InspectionError.blocked("Should not read")})
        XCTAssertEqual(report.status(for:RepositoryReleaseAgeChecks.id),.skipped);XCTAssertTrue(requests.urls.isEmpty);XCTAssertNil(capture.value)
        let invalid=try await inspect("main",capture:capture,request:{_,_ in throw InspectionError.blocked("Should not read")})
        XCTAssertEqual(invalid.status(for:RepositoryReleaseAgeChecks.id),.incomplete)
    }
    func testCompleteDiffFindsNewTransitiveVersionAndDeduplicatesCopies() async throws {
        try manifest();try write("package-lock.json",lock(["direct":"1.0.0","child":"1.0.0"]));let base=try commit()
        try write("package-lock.json",lock(["direct":"1.0.0","child":"2.0.0"],duplicate:"child"))
        let capture=DependencyComparisonCapture(),requests=AgeRequests(),bytes=try npm("child",versions:["2.0.0"],date:"2026-10-03T12:00:00Z")
        let report=try await inspect(base,capture:capture,request:{url,_ in requests.append(url);return bytes})
        XCTAssertEqual(report.status(for:RepositoryReleaseAgeChecks.id),.passed);XCTAssertEqual(requests.urls.count,1)
        let evidence=try XCTUnwrap(capture.value);XCTAssertEqual(evidence.baseCommit,base);XCTAssertTrue(evidence.includesWorkingTree)
        XCTAssertEqual(evidence.introduced.map(\.identity),["npm:child@2.0.0"]);XCTAssertEqual(evidence.introduced.first?.status,"eligible")
        XCTAssertEqual(evidence.inputs.filter{$0.path=="package-lock.json"}.count,2)
    }
    func testYoungReleaseCreatesExactVersionBlockedFinding() async throws {
        let base=try GitRunner.text(["rev-parse","HEAD"],at:root);try manifest();try write("package-lock.json",lock(["child":"1.0.0"]))
        let bytes=try npm("child",versions:["1.0.0"],date:"2026-10-09T00:00:00Z"),capture=DependencyComparisonCapture()
        let report=try await inspect(base,capture:capture,request:{_,_ in bytes})
        XCTAssertEqual(report.status(for:RepositoryReleaseAgeChecks.id),.findings)
        XCTAssertEqual(report.findings().map(\.subject),["npm:child@1.0.0#age"])
        XCTAssertEqual(report.findings().first?.severity,.blocked);XCTAssertEqual(capture.value?.introduced.first?.status,"too_young")
    }
    func testKnownYoungFindingSurvivesAnotherMissingRegistryResponse() async throws {
        let base=try GitRunner.text(["rev-parse","HEAD"],at:root);try manifest();try write("package-lock.json",lock(["a":"1.0.0","b":"1.0.0"]))
        let bytes=try npm("a",versions:["1.0.0"],date:"2026-10-09T00:00:00Z"),capture=DependencyComparisonCapture()
        let report=try await inspect(base,capture:capture,request:{url,_ in
            if url.lastPathComponent=="a" {return bytes};throw InspectionError.blocked("CANARY registry error")
        })
        XCTAssertEqual(report.status(for:RepositoryReleaseAgeChecks.id),.incomplete);XCTAssertEqual(report.findings().map(\.subject),["npm:a@1.0.0#age"])
        XCTAssertFalse(String(describing:capture.value).contains("CANARY"))
    }
    func testExactApprovedAgeExceptionDoesNotBypassDeprecatedRisk() async throws {
        let base=try GitRunner.text(["rev-parse","HEAD"],at:root);try manifest();try write("package-lock.json",lock(["child":"1.0.0"]))
        try write(".repoman.json",#"{"version":1,"exceptions":{"dependencies.releaseAge":{"npm:child@1.0.0#age":"Explicit exact-version fixture approval"}}}"#)
        let young=try npm("child",versions:["1.0.0"],date:"2026-10-09T00:00:00Z"),capture=DependencyComparisonCapture()
        let allowed=try await inspect(base,capture:capture,request:{_,_ in young})
        XCTAssertEqual(allowed.status(for:RepositoryReleaseAgeChecks.id),.passed);XCTAssertEqual(capture.value?.introduced.first?.status,"excepted")
        XCTAssertNotNil(capture.value?.introduced.first?.exceptionReason)
        let deprecated=try npm("child",versions:["1.0.0"],date:"2026-10-09T00:00:00Z",deprecated:true)
        let blocked=try await inspect(base,capture:capture,request:{_,_ in deprecated})
        XCTAssertEqual(blocked.findings().map(\.subject),["npm:child@1.0.0#deprecated"])
    }
    func testUVExactAgeExceptionCannotSuppressYankedArtifactRisk() async throws {
        let base=try GitRunner.text(["rev-parse","HEAD"],at:root)
        try write("pyproject.toml","[project]\nname='fixture'\nversion='1.0.0'\n")
        try write("uv.lock","version=1\n[[package]]\nname='fixture'\nversion='1.0.0'\nsource={virtual='.'}\n[[package]]\nname='Some_Package'\nversion='1.0.0'\nsource={registry='https://pypi.org/simple'}\n")
        try write(".repoman.json",#"{"exceptions":{"dependencies.releaseAge":{"pypi:some-package@1.0.0#age":"Explicit fixture approval"}}}"#)
        let bytes=try JSONSerialization.data(withJSONObject:["info":["name":"Some_Package","version":"1.0.0"],"urls":[["upload_time_iso_8601":"2026-10-09T00:00:00Z","yanked":true]]])
        let requests=AgeRequests(),capture=DependencyComparisonCapture()
        let report=try await inspect(base,capture:capture,request:{url,_ in requests.append(url);return bytes})
        XCTAssertEqual(report.findings().map(\.subject),["pypi:some-package@1.0.0#yanked"])
        XCTAssertEqual(requests.urls.first?.host,"pypi.org")
        XCTAssertEqual(capture.value?.introduced.first?.exceptionReason,"Explicit fixture approval")
    }
    func testWildcardAndRiskExceptionsCannotSuppressKnownViolations() async throws {
        let base=try GitRunner.text(["rev-parse","HEAD"],at:root);try manifest();try write("package-lock.json",lock(["child":"1.0.0"]))
        try write(".repoman.json",#"{"exceptions":{"dependencies.releaseAge":{"npm:*#age":"Not exact","npm:child@1.0.0#deprecated":"Not an age exception"}}}"#)
        let bytes=try npm("child",versions:["1.0.0"],date:"2026-10-09T00:00:00Z",deprecated:true),capture=DependencyComparisonCapture()
        let report=try await inspect(base,capture:capture,request:{_,_ in bytes})
        XCTAssertEqual(report.status(for:RepositoryReleaseAgeChecks.id),.incomplete)
        XCTAssertEqual(Set(report.findings().map(\.subject)),["npm:child@1.0.0#age","npm:child@1.0.0#deprecated"])
    }
    func testUnchangedUnsupportedSourceDoesNotObscureEligibleIntroducedVersion() async throws {
        try manifest()
        let before=try sourcedLock(["legacy":"1.0.0","child":"1.0.0"], legacyHost:"private.invalid")
        try write("package-lock.json",before);let base=try commit()
        let after=try sourcedLock(["legacy":"1.0.0","child":"2.0.0"], legacyHost:"private.invalid")
        try write("package-lock.json",after)
        let inventory=try DependencyLockInventory.parse(after,path:"package-lock.json",read:{_ in throw InspectionError.blocked("No workspace")})
        XCTAssertEqual(inventory.first(where:{$0.name=="legacy"})?.source,"unsupported")
        let bytes=try npm("child",versions:["2.0.0"],date:"2026-10-03T12:00:00Z"),capture=DependencyComparisonCapture()
        let report=try await inspect(base,capture:capture,request:{_,_ in bytes})
        XCTAssertEqual(report.status(for:RepositoryReleaseAgeChecks.id),.passed)
        XCTAssertEqual(capture.value?.introduced.map(\.identity),["npm:child@2.0.0"])
    }
    func testChangedPublicArtifactWithTheSameVersionDoesNotReuseBaselineEvidence() async throws {
        try manifest();try write("package-lock.json",lock(["child":"1.0.0"]));let base=try commit()
        var object=try JSONSerialization.jsonObject(with:Data(lock(["child":"1.0.0"]).utf8)) as! [String:Any]
        var packages=object["packages"] as! [String:Any],item=packages["node_modules/child"] as! [String:Any]
        item["resolved"]="https://registry.npmjs.org/other/-/other-1.0.0.tgz";packages["node_modules/child"]=item;object["packages"]=packages
        try write("package-lock.json",String(decoding:JSONSerialization.data(withJSONObject:object),as:UTF8.self))
        let bytes=try npm("child",versions:["1.0.0"],date:"2026-10-03T12:00:00Z"),capture=DependencyComparisonCapture()
        let report=try await inspect(base,capture:capture,request:{_,_ in bytes})
        XCTAssertEqual(report.status(for:RepositoryReleaseAgeChecks.id),.incomplete)
        XCTAssertEqual(capture.value?.introduced.first?.change,"origin")
    }
    func testChangedPublicDigestWithTheSameVersionNeedsFreshProvenance() async throws {
        try manifest();try write("package-lock.json",lock(["child":"1.0.0"]));let base=try commit()
        let changed="sha512-"+Data(repeating:2,count:64).base64EncodedString()
        let source=try lock(["child":"1.0.0"]).replacingOccurrences(of:lockedDigest,with:changed)
        // Mutate through JSON so slash escaping cannot invalidate the counterexample.
        var object=try JSONSerialization.jsonObject(with:Data(source.utf8)) as! [String:Any]
        var packages=object["packages"] as! [String:Any],item=packages["node_modules/child"] as! [String:Any]
        item["integrity"]=changed;packages["node_modules/child"]=item;object["packages"]=packages
        try write("package-lock.json",String(decoding:JSONSerialization.data(withJSONObject:object),as:UTF8.self))
        let bytes=try npm("child",versions:["1.0.0"],date:"2026-10-03T12:00:00Z"),capture=DependencyComparisonCapture()
        let report=try await inspect(base,capture:capture,request:{_,_ in bytes})
        XCTAssertEqual(report.status(for:RepositoryReleaseAgeChecks.id),.incomplete)
        XCTAssertEqual(capture.value?.introduced.first?.change,"origin")
    }
    func testChangedUnsupportedOriginWithTheSameVersionRemainsIncomplete() async throws {
        try manifest()
        try write("package-lock.json",lock(["legacy":"1.0.0"]).replacingOccurrences(of:"registry.npmjs.org",with:"old.invalid"));let base=try commit()
        try write("package-lock.json",lock(["legacy":"1.0.0"]).replacingOccurrences(of:"registry.npmjs.org",with:"new.invalid"))
        let capture=DependencyComparisonCapture(),requests=AgeRequests()
        let report=try await inspect(base,capture:capture,request:{url,_ in requests.append(url);throw InspectionError.blocked("Do not read")})
        XCTAssertEqual(report.status(for:RepositoryReleaseAgeChecks.id),.incomplete)
        XCTAssertTrue(requests.urls.isEmpty)
        XCTAssertEqual(capture.value?.introduced.count,1)
        XCTAssertEqual(capture.value?.introduced.first?.change,"origin")
    }
    func testUnsupportedSourceNeverFallsBackToPublicRegistry() async throws {
        let base=try GitRunner.text(["rev-parse","HEAD"],at:root);try manifest()
        try write("package-lock.json",lock(["child":"1.0.0"]).replacingOccurrences(of:"registry.npmjs.org",with:"user:CANARY@private.invalid"))
        let capture=DependencyComparisonCapture(),requests=AgeRequests()
        let report=try await inspect(base,capture:capture,request:{url,_ in requests.append(url);throw InspectionError.blocked("Unexpected public lookup")})
        XCTAssertEqual(report.status(for:RepositoryReleaseAgeChecks.id),.incomplete);XCTAssertTrue(requests.urls.isEmpty)
        XCTAssertFalse(String(describing:capture.value).contains("CANARY"))
    }
    func testNPMToPNPMMigrationWorksWithoutChangingTheRealIndex() async throws {
        try manifest();try write("package-lock.json",lock(["child":"1.0.0"]));let base=try commit()
        try FileManager.default.removeItem(at:root.appendingPathComponent("package-lock.json"))
        try write("pnpm-lock.yaml","lockfileVersion: '9.0'\npackages:\n  child@1.0.0:\n    resolution: {integrity: "+lockedDigest+"}\n")
        let before=try Data(contentsOf:root.appendingPathComponent(".git/index")),capture=DependencyComparisonCapture(),requests=AgeRequests()
        let report=try await inspect(base,capture:capture,request:{url,_ in requests.append(url);throw InspectionError.blocked("No introduced version")})
        XCTAssertEqual(report.status(for:RepositoryReleaseAgeChecks.id),.passed);XCTAssertTrue(requests.urls.isEmpty)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),before);XCTAssertTrue(capture.value?.introduced.isEmpty==true)
    }
    func testMissingComponentLockCannotHideBehindAnotherComponent() async throws {
        for component in ["api","web"] {try manifest(component+"/package.json");try write(component+"/package-lock.json",lock([:]))}
        let base=try commit();try FileManager.default.removeItem(at:root.appendingPathComponent("api/package-lock.json"))
        let report=try await inspect(base,capture:DependencyComparisonCapture(),request:{_,_ in throw InspectionError.blocked("No versions")})
        XCTAssertEqual(report.status(for:RepositoryReleaseAgeChecks.id),.incomplete)
    }
    func testDeclaredAncestorWorkspaceStillCoversItsJavaScriptMember() async throws {
        try write("package.json",#"{"name":"fixture","workspaces":["packages/*"]}"#)
        try write("packages/web/package.json",#"{"name":"web","version":"1.0.0"}"#)
        var object=try JSONSerialization.jsonObject(with:Data(lock(["child":"1.0.0"]).utf8)) as! [String:Any]
        var packages=object["packages"] as! [String:Any]
        packages["packages/web"]=["version":"1.0.0"];packages["node_modules/web"]=["resolved":"packages/web","link":true];object["packages"]=packages
        try write("package-lock.json",String(decoding:JSONSerialization.data(withJSONObject:object),as:UTF8.self));let base=try commit()
        let report=try await inspect(base,capture:DependencyComparisonCapture(),request:{_,_ in throw InspectionError.blocked("No new version")})
        XCTAssertEqual(report.status(for:RepositoryReleaseAgeChecks.id),.passed)
    }
    func testPythonRootLockCannotHideMissingJavaScriptComponentInventory() async throws {
        try write("pyproject.toml","[project]\nname='fixture'\nversion='1.0.0'\n")
        try write("uv.lock","version=1\n[[package]]\nname='fixture'\nversion='1.0.0'\nsource={virtual='.'}\n")
        try manifest("web/package.json");try write("web/package-lock.json",lock(["child":"1.0.0"]));let base=try commit()
        try FileManager.default.removeItem(at:root.appendingPathComponent("web/package-lock.json"))
        let report=try await inspect(base,capture:DependencyComparisonCapture(),request:{_,_ in throw InspectionError.blocked("No introduced registry identity")})
        XCTAssertEqual(report.status(for:RepositoryReleaseAgeChecks.id),.incomplete)
    }
    func testCandidateInputMutationDuringRegistryReadRemainsIncomplete() async throws {
        let base=try GitRunner.text(["rev-parse","HEAD"],at:root);try manifest();let original=try lock(["child":"1.0.0"]);try write("package-lock.json",original)
        let bytes=try npm("child",versions:["1.0.0"],date:"2026-10-03T12:00:00Z"),url=root.appendingPathComponent("package-lock.json")
        let report=try await inspect(base,capture:DependencyComparisonCapture(),request:{_,_ in try (original+"\n").write(to:url,atomically:true,encoding:.utf8);return bytes})
        XCTAssertEqual(report.status(for:RepositoryReleaseAgeChecks.id),.incomplete)
    }
    func testMissingBaseLockInventoryDoesNotBecomeAnEmptyBaseline() async throws {
        try manifest();try write("package-lock.json",#"{"lockfileVersion":3}"#);let base=try commit();try write("package-lock.json",lock([:]))
        let report=try await inspect(base,capture:DependencyComparisonCapture(),request:{_,_ in throw InspectionError.blocked("Do not request")})
        XCTAssertEqual(report.status(for:RepositoryReleaseAgeChecks.id),.incomplete)
    }
    func testMultipleIntroducedVersionsUseOneNPMMetadataRead() async throws {
        let base=try GitRunner.text(["rev-parse","HEAD"],at:root);try manifest()
        var source=try JSONSerialization.jsonObject(with:Data(lock(["child":"1.0.0"]).utf8)) as! [String:Any]
        var packages=source["packages"] as! [String:Any];packages["node_modules/parent/node_modules/child"]=["version":"2.0.0","resolved":"https://registry.npmjs.org/child/-/child-2.0.0.tgz","integrity":lockedDigest];source["packages"]=packages
        try write("package-lock.json",String(decoding:JSONSerialization.data(withJSONObject:source),as:UTF8.self))
        let bytes=try npm("child",versions:["1.0.0","2.0.0"],date:"2026-10-03T12:00:00Z"),requests=AgeRequests(),capture=DependencyComparisonCapture()
        let report=try await inspect(base,capture:capture,request:{url,_ in requests.append(url);return bytes})
        XCTAssertEqual(report.status(for:RepositoryReleaseAgeChecks.id),.passed);XCTAssertEqual(requests.urls.count,1);XCTAssertEqual(capture.value?.introduced.count,2)
    }
    func testGitReplacementCannotChangeTheExplicitBaseInventory() async throws {
        try manifest();try write("package-lock.json",lock(["child":"1.0.0"]));let base=try commit()
        try write("package-lock.json",lock(["child":"2.0.0"]));let candidate=try commit()
        _=try GitRunner.run(["replace",base,candidate],at:root)
        let bytes=try npm("child",versions:["2.0.0"],date:"2026-10-09T00:00:00Z"),capture=DependencyComparisonCapture()
        let report=try await inspect(base,capture:capture,request:{_,_ in bytes})
        XCTAssertEqual(report.findings().map(\.subject),["npm:child@2.0.0#age"])
    }
    func testComparisonJSONPreservesTheExplicitBaseAndPreciseClock() async throws {
        let base=try GitRunner.text(["rev-parse","HEAD"],at:root);try manifest();try write("package-lock.json",lock(["child":"1.0.0"]))
        let bytes=try npm("child",versions:["1.0.0"],date:"2026-10-03T12:00:00.123456Z"),capture=DependencyComparisonCapture()
        let report=try await inspect(base,capture:capture,request:{_,_ in bytes})
        let adapter=RepositoryCheckReport(report,head:base,checkerVersion:"fixture",dependencyComparison:capture.value)
        XCTAssertEqual(adapter.exitCode,1)
        let json=try JSONSerialization.jsonObject(with:adapter.json()) as! [String:Any]
        let evidence=try XCTUnwrap(json["dependencyComparison"] as? [String:Any])
        XCTAssertEqual(evidence["baseCommit"] as? String,base)
        let versions=try XCTUnwrap(evidence["introduced"] as? [[String:Any]])
        XCTAssertEqual(versions.first?["publishedAt"] as? String,"2026-10-03T12:00:00.123456Z")
        XCTAssertEqual(versions.first?["eligibleAt"] as? String,"2026-10-10T12:00:00.123456Z")
        XCTAssertTrue(adapter.text.contains(base))
    }
    private func inspect(_ base:String?,capture:DependencyComparisonCapture,request:@escaping RepositoryReleaseAgeChecks.Request) async throws -> RepositoryInspectionReport {
        let snapshot=try GitRepositoryScanner.scan(root,includeDetails:false)
        return await RepositoryIssueCatalog(checks:RepositoryReleaseAgeChecks.checks(base:base,at:at,request:request,record:{capture.record($0)})).inspect(snapshot)
    }
    private func manifest(_ path:String="package.json") throws {try write(path,#"{"name":"fixture","version":"1.0.0","packageManager":"npm@11.20.0"}"#)}
    private func write(_ path:String,_ source:String) throws {let url=root.appendingPathComponent(path);try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true);try source.write(to:url,atomically:true,encoding:.utf8)}
    private func commit() throws -> String {_=try GitRunner.run(["add","."],at:root);_=try GitRunner.run(["commit","-m","Fixture"],at:root);return try GitRunner.text(["rev-parse","HEAD"],at:root)}
    private func lock(_ versions:[String:String],duplicate:String?=nil) throws -> String {
        var packages:[String:Any]=["": ["name":"fixture","version":"1.0.0"]]
        for (name,version) in versions {let value:[String:Any]=["version":version,"resolved":"https://registry.npmjs.org/"+name+"/-/"+name+"-"+version+".tgz","integrity":lockedDigest];packages["node_modules/"+name]=value;if duplicate==name {packages["node_modules/direct/node_modules/"+name]=value}}
        return String(decoding:try JSONSerialization.data(withJSONObject:["lockfileVersion":3,"packages":packages]),as:UTF8.self)
    }
    private func sourcedLock(_ versions:[String:String], legacyHost:String) throws -> String {
        var object=try JSONSerialization.jsonObject(with:Data(lock(versions).utf8)) as! [String:Any]
        var packages=object["packages"] as! [String:Any],entry=packages["node_modules/legacy"] as! [String:Any]
        entry["resolved"]="https://"+legacyHost+"/legacy/-/legacy-1.0.0.tgz";packages["node_modules/legacy"]=entry;object["packages"]=packages
        return String(decoding:try JSONSerialization.data(withJSONObject:object),as:UTF8.self)
    }
    private func npm(_ name:String,versions:[String],date:String,deprecated:Bool=false) throws -> Data {
        var values:[String:Any]=[:],times:[String:String]=[:]
        for version in versions {var item:[String:Any]=["name":name,"version":version,"dist":["integrity":lockedDigest,"tarball":"https://registry.npmjs.org/"+name+"/-/"+name+"-"+version+".tgz"]];if deprecated {item["deprecated"]="Fixture deprecated"};values[version]=item;times[version]=date}
        return try JSONSerialization.data(withJSONObject:["name":name,"versions":values,"time":times])
    }
}
private final class AgeRequests:@unchecked Sendable {
    private let lock=NSLock();private var values:[URL]=[]
    func append(_ url:URL) {lock.lock();defer{lock.unlock()};values.append(url)}
    var urls:[URL] {lock.lock();defer{lock.unlock()};return values}
}
