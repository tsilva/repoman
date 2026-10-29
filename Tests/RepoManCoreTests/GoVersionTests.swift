import Foundation
import XCTest
@testable import RepoManCore

final class GoVersionTests: XCTestCase {
    func testStableBuildMetadataAndNumericPrereleaseOrdering() throws {
        XCTAssertEqual(GoVersion("v2.0.0"), GoVersion("v2.0.0+incompatible"))
        XCTAssertLessThan(try XCTUnwrap(GoVersion("v1.0.0-9")), try XCTUnwrap(GoVersion("v1.0.0-10")))
        XCTAssertLessThan(try XCTUnwrap(GoVersion("v1.0.0-10")), try XCTUnwrap(GoVersion("v1.0.0-alpha")))
        XCTAssertLessThan(try XCTUnwrap(GoVersion("v1.0.0-beta.2")), try XCTUnwrap(GoVersion("v1.0.0-beta.11")))
        XCTAssertLessThan(try XCTUnwrap(GoVersion("v1.0.0-rc.1")), try XCTUnwrap(GoVersion("v1.0.0")))
    }
    func testPseudoVersionsRemainBelowTheirFinalReleaseAndOrderByRevisionTime() throws {
        let first = try XCTUnwrap(GoVersion("v0.0.0-20261010120000-abcdef123456"))
        let second = try XCTUnwrap(GoVersion("v0.0.0-20261011120000-abcdef123456"))
        XCTAssertLessThan(first, second)
        XCTAssertLessThan(second, try XCTUnwrap(GoVersion("v0.0.0")))
        for bad in ["v1.0.0-alpha..1", "v1.0.0-01", "v999999999999999999999.0.0", "1.2.3", "v1.2.3+private"] {
            XCTAssertNil(GoVersion(bad))
        }
    }
    func testCanonicalRangesIncludeTrueMatchesAndKeepUnknownAlternativesConservative() {
        XCTAssertEqual(GoVersion.contains("v0.31.0", range: "< 0.32.0"), true)
        XCTAssertEqual(GoVersion.contains("v0.32.0", range: "< v0.32.0"), false)
        XCTAssertEqual(GoVersion.contains("v2.0.0", range: ">= 0, < 1.0.0 || >= 2.0.0, < 3.0.0"), true)
        XCTAssertEqual(GoVersion.contains("v2.0.0", range: "< 1.0.0 || dynamic"), nil)
        XCTAssertEqual(GoVersion.contains("v0.5.0", range: "< 1.0.0 || dynamic"), true)
        XCTAssertNil(GoVersion.contains("v1.0.0", range: ">=0.5.0,"))
    }
    func testNativeManifestRisksRejectWrongIdentityAndUnsupportedRetractionRanges() throws {
        let data = try JSONSerialization.data(withJSONObject: ["Module": ["Path": "golang.org/x/fixture", "Deprecated": "fixture"], "Retract": [["Low": "v1.0.0", "High": "v1.2.0"]]])
        XCTAssertEqual(try GoVersion.risks("v1.1.0", module: "golang.org/x/fixture", manifest: data), ["deprecated", "retracted"])
        XCTAssertEqual(try GoVersion.risks("v1.3.0", module: "golang.org/x/fixture", manifest: data), ["deprecated"])
        XCTAssertThrowsError(try GoVersion.risks("v1.1.0", module: "private.invalid/other", manifest: data))
        let malformed = try JSONSerialization.data(withJSONObject: ["Module": ["Path": "golang.org/x/fixture"], "Retract": [["Low": "v2.0.0", "High": "v1.0.0"]]])
        XCTAssertThrowsError(try GoVersion.risks("v1.1.0", module: "golang.org/x/fixture", manifest: malformed))
    }
    func testInstalledGoParsesRetractionAndDeprecationWithoutChangingOrExecutingSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("repoman-go-parse-fixture-" + UUID().uuidString)
        try XCTSkipIf(GoModuleClient.executable(excluding: root) == nil, "A compatible installed native Go tool is not available.")
        let source = "// Deprecated: fixture only.\nmodule golang.org/x/fixture\n\ngo 1.18\nretract [v1.0.0, v1.2.0]\n"
        let data = try GoModuleClient.manifest(source, excluding: root, timeout: 10)
        XCTAssertEqual(try GoVersion.risks("v1.1.0", module: "golang.org/x/fixture", manifest: data), ["deprecated", "retracted"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}
