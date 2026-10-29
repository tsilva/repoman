import Foundation
import XCTest
@testable import RepoManCore

final class DependencyLockInventoryTests: XCTestCase {
    private func parse(_ source: String, _ path: String = "package-lock.json", files: [String: String] = [:]) throws -> [DependencyLockInventory.Entry] {
        try DependencyLockInventory.parse(source, path: path, read: { name in
            guard let value = files[name] else { throw InspectionError.blocked("Fixture manifest missing") }
            return value
        })
    }
    private func npm(_ packages: [String: Any], schema: Int = 3) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["lockfileVersion": schema, "packages": packages]), as: UTF8.self)
    }
    func testNPMIncludesTransitivesNestedCopiesAndActualAliasNames() throws {
        let packages: [String: Any] = ["": ["name": "root"],
            "node_modules/direct": ["version": "1.0.0", "resolved": "https://registry.npmjs.org/direct/-/direct-1.0.0.tgz"],
            "node_modules/direct/node_modules/@scope/child": ["version": "2.1.0", "resolved": "https://registry.npmjs.org/@scope/child/-/child-2.1.0.tgz"],
            "node_modules/alias": ["name": "real-name", "version": "3.0.0", "resolved": "https://registry.npmjs.org/real-name/-/real-name-3.0.0.tgz"]]
        let entries = try parse(npm(packages))
        XCTAssertEqual(Set(entries.map(\.identity)), ["npm:direct@1.0.0", "npm:@scope/child@2.1.0", "npm:real-name@3.0.0"])
        XCTAssertTrue(entries.allSatisfy { $0.source == "npm" })
    }
    func testDeclaredBundleCandidateRetainsPublicParentButIsNotYetTrusted() throws {
        let packages: [String: Any] = ["node_modules/parent": ["version": "1.0.0", "resolved": "https://registry.npmjs.org/parent/-/parent-1.0.0.tgz", "integrity": "sha512-fixture", "bundleDependencies": ["@scope/child"]],
                                      "node_modules/parent/node_modules/@scope/child": ["version": "2.0.0", "inBundle": true]]
        let value = try XCTUnwrap(parse(npm(packages)).first { $0.name == "@scope/child" })
        XCTAssertEqual(value.source, "unsupported"); XCTAssertEqual(value.bundle?.parent.identity, "npm:parent@1.0.0")
        XCTAssertEqual(value.bundle?.parent.lockfile, "package-lock.json")
        XCTAssertEqual(value.bundle?.memberPath, "package/node_modules/@scope/child/package.json")
    }
    func testPrivateUndeclaredAndExplicitSourceBundlesNeverAcquirePublicParentCandidates() throws {
        let publicParent: [String: Any] = ["version": "1.0.0", "resolved": "https://registry.npmjs.org/parent/-/parent-1.0.0.tgz", "integrity": "sha512-fixture", "bundleDependencies": ["child"]]
        for change in [0, 1, 2, 3] {
            var parent = publicParent, child: [String: Any] = ["version": "2.0.0", "inBundle": true]
            if change == 0 { parent["resolved"] = "https://user:CANARY@private.invalid/parent.tgz" }
            if change == 1 { parent["bundleDependencies"] = ["other"] }
            if change == 2 { child["resolved"] = "https://private.invalid/child.tgz" }
            if change == 3 { child["inBundle"] = 1 }
            let value = try XCTUnwrap(parse(npm(["node_modules/parent": parent, "node_modules/parent/node_modules/child": child])).first { $0.name == "child" })
            XCTAssertNil(value.bundle); XCTAssertEqual(value.source, "unsupported")
            XCTAssertFalse(String(describing: value).contains("CANARY"))
        }
    }
    func testChangedBundleParentCannotReuseAnUnsupportedSourceFingerprint() throws {
        func source(_ version: String) throws -> String {
            try npm(["node_modules/parent": ["version": version, "resolved": "https://registry.npmjs.org/parent/-/parent-" + version + ".tgz", "integrity": "sha512-fixture", "bundleDependencies": ["child"]],
                     "node_modules/parent/node_modules/child": ["version": "1.0.0", "inBundle": true]])
        }
        let a = try XCTUnwrap(parse(source("1.0.0")).first { $0.name == "child" })
        let b = try XCTUnwrap(parse(source("2.0.0")).first { $0.name == "child" })
        XCTAssertNotEqual(a.sourceFingerprint, b.sourceFingerprint)
    }
    func testExistingLegacyNPMCapitalizationPreservesPackageIdentity() throws {
        let source=try npm(["node_modules/JSONStream":["version":"1.3.5","resolved":"https://registry.npmjs.org/JSONStream/-/JSONStream-1.3.5.tgz"]])
        XCTAssertEqual(try parse(source).map(\.identity),["npm:JSONStream@1.3.5"])
    }
    func testNumericWorkspaceLinkMarkerIsNotABoolean() throws {
        let source=try npm(["packages/member":["version":"1.0.0"],"node_modules/member":["link":1,"resolved":"packages/member"]])
        XCTAssertThrowsError(try parse(source,files:["package.json":#"{"name":"root","workspaces":["packages/*"]}"#,"packages/member/package.json":#"{"name":"member"}"#]))
    }
    func testNPMCustomAndCredentialBearingSourcesAreNotExposedOrAssumedPublic() throws {
        let entries = try parse(npm(["node_modules/a": ["version": "1.0.0", "resolved": "https://user:CANARY@private.invalid/a.tgz"],
                                    "node_modules/b": ["version": "1.0.0", "resolved": "https://registry.npmjs.org.evil.invalid/b.tgz"]]))
        XCTAssertTrue(entries.allSatisfy { $0.source == "unsupported" && $0.tarball == nil })
        XCTAssertFalse(String(describing: entries).contains("CANARY"))
    }
    func testNPMOnlyVerifiedLocalWorkspaceLinksAreExcluded() throws {
        let source = try npm(["packages/member": ["version": "1.0.0"], "node_modules/member": ["link": true, "resolved": "packages/member"]])
        XCTAssertTrue(try parse(source, files: ["package.json": #"{"name":"root","workspaces":["packages/*"]}"#, "packages/member/package.json": #"{"name":"member","version":"1.0.0"}"#]).isEmpty)
        XCTAssertThrowsError(try parse(source))
        XCTAssertThrowsError(try parse(source.replacingOccurrences(of: "packages/member", with: "../outside"), files: ["../outside/package.json": #"{"name":"member"}"#]))
    }
    func testInRepoLocalDependenciesAreNotAutomaticallyWorkspaceMembers() throws {
        let npmSource=try npm(["packages/member":["version":"1.0.0"],"node_modules/member":["link":true,"resolved":"packages/member"]])
        XCTAssertThrowsError(try parse(npmSource,files:["package.json":#"{"name":"root"}"#,"packages/member/package.json":#"{"name":"member"}"#]))
        let uvSource="version=1\n[[package]]\nname='member'\nversion='1'\nsource={editable='packages/member'}\n"
        XCTAssertThrowsError(try parse(uvSource,"uv.lock",files:["pyproject.toml":"[project]\nname='root'\n","packages/member/pyproject.toml":"[project]\nname='member'\n"]))
    }
    func testNPMMalformedInventoryCannotBecomeAnEmptyPass() throws {
        for source in [#"{"lockfileVersion":3}"#, #"{"lockfileVersion":1,"packages":{}}"#, #"{"lockfileVersion":3,"packages":{"node_modules/a":{}}}"#] {
            XCTAssertThrowsError(try parse(source))
        }
        XCTAssertTrue(try parse(npm([:])).isEmpty)
    }
    func testPNPMV9CapturesScopedPackagesAndNestedPeerMetadata() throws {
        let source = """
        lockfileVersion: '9.0'
        importers:
          .: {}
        packages:
          '@scope/a@1.2.3':
            resolution: {integrity: sha512-fixture}
            peerDependencies:
              react: '>=18'
          b@2.0.0:
            resolution:
              integrity: sha512-other
        snapshots:
          '@scope/a@1.2.3(react@19.0.0)': {}
        """
        let entries = try parse(source, "pnpm-lock.yaml")
        XCTAssertEqual(Set(entries.map(\.identity)), ["npm:@scope/a@1.2.3", "npm:b@2.0.0"])
        XCTAssertTrue(entries.allSatisfy { $0.source == "npm" && $0.integrity != nil })
    }
    func testPNPMExoticResolutionIsExplicitlyUnsupported() throws {
        let source = "lockfileVersion: '9.0'\npackages:\n  a@1.2.3:\n    resolution: {tarball: https://private.invalid/a.tgz}\n"
        let entries = try parse(source, "pnpm-lock.yaml")
        XCTAssertEqual(entries.first?.source, "unsupported")
        XCTAssertNil(entries.first?.tarball)
    }
    func testPNPMEmptyMissingAndUnsupportedPackageTablesStayDistinct() throws {
        XCTAssertTrue(try parse("lockfileVersion: '9.0'\npackages: {}\n", "pnpm-lock.yaml").isEmpty)
        for source in ["lockfileVersion: '9.0'\n", "lockfileVersion: '6.0'\npackages: {}\n", "lockfileVersion: '9.0'\npackages:\n", "lockfileVersion: '9.0'\npackages: &anchor {}\n"] {
            XCTAssertThrowsError(try parse(source, "pnpm-lock.yaml"))
        }
    }
    func testUVIncludesNormalizedExternalPackagesAndVerifiesWorkspaceMembers() throws {
        let source = """
        version = 1
        [manifest]
        members = ["root", "child"]
        [[package]]
        name = "root"
        version = "0.1.0"
        source = { virtual = "." }
        [[package]]
        name = "child"
        version = "0.1.0"
        source = { editable = "packages/child" }
        [[package]]
        name = "Some_Package"
        version = "1.0.0"
        source = { registry = "https://pypi.org/simple" }
        [package.metadata]
        requires-dist = []
        """
        let entries = try parse(source, "uv.lock", files: ["pyproject.toml": "[project]\nname='root'\n[tool.uv.workspace]\nmembers=['packages/*']\n", "packages/child/pyproject.toml": "[project]\nname='child'\n"])
        XCTAssertEqual(entries.map(\.identity), ["pypi:some-package@1.0.0"])
        XCTAssertEqual(entries.first?.source, "pypi")
        XCTAssertThrowsError(try parse(source, "uv.lock"))
    }
    func testUVExternalEditablesAndMismatchedWorkspaceNamesStayUnknown() throws {
        for location in ["../outside", "/outside", "packages/child"] {
            let source = "version=1\n[[package]]\nname='child'\nversion='1'\nsource={editable='" + location + "'}\n"
            XCTAssertThrowsError(try parse(source, "uv.lock", files: ["packages/child/pyproject.toml": "[project]\nname='other'\n"]))
        }
    }
    func testUVAlternateIndexesRemainUnsupportedWithoutLeakingURLs() throws {
        let source = "version=1\n[[package]]\nname='child'\nversion='1'\nsource={registry='https://user:CANARY@private.invalid/simple'}\n"
        let entries = try parse(source, "uv.lock")
        XCTAssertEqual(entries.first?.source, "unsupported")
        XCTAssertFalse(String(describing: entries).contains("CANARY"))
    }
    func testUVUnrecognizedSchemaAndMissingInventoryAreNotEmptyPasses() throws {
        for source in ["version=1\n", "version=2\n[[package]]\nname='a'\nversion='1'\nsource={registry='https://pypi.org/simple'}\n"] {
            XCTAssertThrowsError(try parse(source, "uv.lock"))
        }
    }
    func testManagerMigrationPreservesVersionIdentity() throws {
        let before = try parse(npm(["node_modules/a": ["version":"1.2.3", "resolved":"https://registry.npmjs.org/a/-/a-1.2.3.tgz"]]))
        let after = try parse("lockfileVersion: '9.0'\npackages:\n  a@1.2.3:\n    resolution: {integrity: sha512-fixture}\n", "pnpm-lock.yaml")
        XCTAssertEqual(Set(before.map(\.identity)), Set(after.map(\.identity)))
    }
    func testInventoryLimitsAndUnsafePathsDoNotReadExternalFiles() throws {
        XCTAssertThrowsError(try parse(String(repeating:" ", count:1_048_577)))
        for path in ["../x", "/x", "x/../y", "x//y", "x/./y", "x\n"] { XCTAssertFalse(DependencyLockInventory.safePath(path)) }
        XCTAssertTrue(DependencyLockInventory.safePath("web/pnpm-lock.yaml"))
    }
}
