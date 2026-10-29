import Foundation
import XCTest
@testable import RepoManCore

final class GoModuleInventoryTests: XCTestCase {
    private let sum = "h1:" + Data(repeating: 0, count: 32).base64EncodedString()
    private func document(_ modules: [[String: Any]], patterns: [String] = []) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["modules": modules, "privatePatterns": patterns])
    }
    private var main: [String: Any] { ["Path": "local-fixture", "Main": true] }
    private func selected(_ name: String = "golang.org/x/crypto", version: String = "v0.31.0") -> [String: Any] {
        ["Path": name, "Version": version, "Sum": sum, "GoModSum": sum]
    }
    private func sums(_ name: String = "golang.org/x/crypto", version: String = "v0.31.0") -> String {
        name + " " + version + " " + sum + "\n" + name + " " + version + "/go.mod " + sum + "\n"
    }
    func testSelectedGraphDoesNotTurnHistoricalOrUnusedSumsIntoDependencies() throws {
        let data = try document([main, selected()])
        let historical = sums() + sums(version: "v0.20.0") + sums("github.com/example/unused", version: "v1.0.0") + sums("git.sr.ht/~owner/unused", version: "v1.0.0")
        let value = try GoModuleInventory.parse(data, sums: historical, path: "component/go.mod")
        XCTAssertEqual(value.entries.map(\.identity), ["go:golang.org/x/crypto@v0.31.0"])
        XCTAssertEqual(value.entries[0].lockfile, "component/go.mod")
        XCTAssertEqual(value.entries[0].integrity, sum)
        XCTAssertEqual(value.entries[0].goModIntegrity, sum)
        XCTAssertTrue(value.reasons.isEmpty)
    }
    func testModOnlyLockedChecksumStillBindsTheSelectedIdentity() throws {
        let module: [String: Any] = ["Path": "golang.org/x/crypto", "Version": "v0.31.0", "GoModSum": sum]
        let value = try GoModuleInventory.parse(document([main, module]), sums: "golang.org/x/crypto v0.31.0/go.mod " + sum, path: "go.mod")
        XCTAssertNil(value.entries[0].integrity)
        XCTAssertEqual(value.entries[0].goModIntegrity, sum)
    }
    func testMissingAndContradictoryChecksumsAreUnknown() throws {
        let data = try document([main, selected()])
        XCTAssertThrowsError(try GoModuleInventory.parse(data, sums: "", path: "go.mod"))
        let other = "h1:" + Data(repeating: 1, count: 32).base64EncodedString()
        XCTAssertThrowsError(try GoModuleInventory.parse(data, sums: sums().replacingOccurrences(of: sum, with: other), path: "go.mod"))
        XCTAssertThrowsError(try GoModuleInventory.parse(data, sums: sums() + "golang.org/x/crypto v0.31.0 " + other, path: "go.mod"))
    }
    func testPrivateUnknownHostAndUnsupportedPatternsWithholdPublicQueries() throws {
        for patterns in [["golang.org/x/*"], ["*"], ["[a-z]*"]] {
            let value = try GoModuleInventory.parse(document([main, selected()], patterns: patterns), sums: sums(), path: "go.mod")
            XCTAssertEqual(value.entries[0].source, "unsupported")
            XCTAssertFalse(value.reasons.isEmpty)
        }
        let name = "private.example.invalid/internal"
        let value = try GoModuleInventory.parse(document([main, selected(name)]), sums: sums(name), path: "go.mod")
        XCTAssertEqual(value.entries[0].source, "unsupported")
    }
    func testPrivatePrefixMatchingUsesSegmentsAndConservativeUnsupportedSyntax() {
        XCTAssertEqual(GoModuleInventory.privateMatch("github.com/company/private/sub", pattern: "github.com/company/*"), true)
        XCTAssertEqual(GoModuleInventory.privateMatch("github.com/company/private", pattern: "github.com/other"), false)
        XCTAssertEqual(GoModuleInventory.privateMatch("corp.example/module", pattern: "*.example"), true)
        XCTAssertNil(GoModuleInventory.privateMatch("github.com/owner/repo", pattern: "github.com/[abc]"))
        XCTAssertEqual(GoModuleInventory.privateMatch("github.com/company2/repo", pattern: "github.com/company"), false)
    }
    func testReplacementsErrorsDuplicatesAndMainAmbiguityAreRejected() throws {
        var replaced = selected(); replaced["Replace"] = ["Path": "../other"]
        var failed = selected(); failed["Error"] = ["Err": "PRIVATE_CANARY"]
        var malformed = main; malformed["Main"] = 1
        for list in [[main, replaced], [main, failed], [main, selected(), selected()], [selected()], [main, main, selected()], [malformed, selected()]] {
            XCTAssertThrowsError(try GoModuleInventory.parse(document(list), sums: sums(), path: "go.mod"))
        }
    }
    func testCaptureRejectsWorkspaceAndReplacementWithoutInvokingGo() {
        let count = GoCalls()
        let request: GoModuleInventory.Request = { _, _, _, _ in count.increment(); return Data() }
        let workspace = GoModuleInventory.capture(paths: ["go.mod", "go.work"], root: URL(fileURLWithPath: "/"), read: { _ in "" }, request: request)
        XCTAssertFalse(workspace.reasons.isEmpty)
        let replacement = GoModuleInventory.capture(paths: ["go.mod", "go.sum"], root: URL(fileURLWithPath: "/"), read: { path in
            path == "go.mod" ? "module fixture\nreplace example.invalid/a => ../a\n" : ""
        }, request: request)
        XCTAssertFalse(replacement.reasons.isEmpty)
        XCTAssertEqual(count.value, 0)
    }
    func testIndependentComponentsRetainSuccessfulEvidenceBesideMissingCache() throws {
        let bytes = try document([main, selected()]), sumText = sums()
        let result = GoModuleInventory.capture(paths: ["a/go.mod", "a/go.sum", "b/go.mod", "b/go.sum"], root: URL(fileURLWithPath: "/tmp"), read: { path in
            path.hasSuffix("go.sum") ? sumText : (path.hasPrefix("a/") ? "module good" : "module bad")
        }, request: { module, _, _, _ in
            if module.contains("bad") { throw InspectionError.blocked("PRIVATE_CANARY") }
            return bytes
        })
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.reasons.count, 1)
        XCTAssertFalse(result.reasons.joined().contains("PRIVATE_CANARY"))
    }
    func testExpiredAndOversizedComponentInventoriesDoNotInvokeGo() {
        let count = GoCalls()
        let request: GoModuleInventory.Request = { _, _, _, _ in count.increment(); return Data() }
        let expired = GoModuleInventory.capture(paths: ["go.mod"], root: URL(fileURLWithPath: "/"), read: { _ in "" }, request: request, deadline: .distantPast)
        XCTAssertFalse(expired.reasons.isEmpty)
        let oversized = GoModuleInventory.capture(paths: (0..<17).map { "\($0)/go.mod" }, root: URL(fileURLWithPath: "/"), read: { _ in "" }, request: request)
        XCTAssertFalse(oversized.reasons.isEmpty)
        XCTAssertEqual(count.value, 0)
    }
    func testIgnoredOrAncestorWorkspaceAlsoBlocksAnOfflineIndependentGraph() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("repoman-go-work-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("go 1.25\nuse ./child\n".utf8).write(to: directory.appendingPathComponent("go.work"))
        let count = GoCalls()
        let result = GoModuleInventory.capture(paths: ["go.mod"], root: directory.appendingPathComponent("child"), read: { _ in "" },
                                               request: { _, _, _, _ in count.increment(); return Data() })
        XCTAssertFalse(result.reasons.isEmpty)
        XCTAssertEqual(count.value, 0)
    }
    func testStreamDecoderHandlesQuotedBracesEscapesAndRejectsTruncation() throws {
        let stream = Data(#"{"Path":"root","Main":true} {"Path":"example.invalid/{quoted}\"","Version":"v1.0.0"}"#.utf8)
        XCTAssertEqual(try GoModuleClient.objects(stream).count, 2)
        for bad in ["", "[]", "{} trailing", "{\"Path\":", "{\"x\":\"unterminated}"] {
            XCTAssertThrowsError(try GoModuleClient.objects(Data(bad.utf8)))
        }
    }
    func testModulePathAndVersionGuardsRejectTraversalAndOptionInjection() {
        for bad in ["../private", "--module", "https://private.invalid/a", "github.com/owner/../private", "private\nCANARY"] {
            XCTAssertFalse(GoModuleInventory.moduleName(bad))
        }
        for good in ["golang.org/x/crypto", "github.com/Azure/azure-sdk-for-go", "gopkg.in/yaml.v3", "go.opencensus.io", "git.sr.ht/~owner/unused"] { XCTAssertTrue(GoModuleInventory.moduleName(good)) }
        for good in ["v0.31.0", "v1.2.3+incompatible", "v0.0.0-20261010120000-abcdef123456"] { XCTAssertTrue(GoModuleInventory.version(good)) }
        for bad in ["latest", "../private", "v01.2.3", "1.2.3", "v1.2.3\nPRIVATE"] { XCTAssertFalse(GoModuleInventory.version(bad)) }
    }
    func testInstalledNativeGoReadsOnlyTemporaryMetadataForAnEmptyModule() throws {
        XCTAssertNil(GoModuleClient.executable(excluding: URL(fileURLWithPath: "/")))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("repoman-go-native-" + UUID().uuidString)
        try XCTSkipIf(GoModuleClient.executable(excluding: root) == nil, "A compatible installed native Go tool is not available.")
        let input = "module repoman-fixture\n\ngo 1.18\n"
        let data = try GoModuleClient.read(input, "", root, 10)
        let graph = try GoModuleInventory.parse(data, sums: "", path: "go.mod")
        XCTAssertTrue(graph.entries.isEmpty)
        XCTAssertTrue(graph.reasons.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    func testInstalledNativeGoUsesOnlyPreexistingCachedMetadataAndPreservesFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("repoman-go-cache-" + UUID().uuidString)
        try XCTSkipIf(GoModuleClient.executable(excluding: root) == nil, "A compatible installed native Go tool is not available.")
        let cache = root.appendingPathComponent("cache"), version = cache.appendingPathComponent("cache/download/golang.org/x/sys/@v")
        try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mod = "module golang.org/x/sys\n\ngo 1.18\n"
        let info = #"{"Version":"v0.28.0","Time":"2024-12-02T00:00:00Z"}"#
        try Data(mod.utf8).write(to: version.appendingPathComponent("v0.28.0.mod"))
        try Data(info.utf8).write(to: version.appendingPathComponent("v0.28.0.info"))
        let sums = "golang.org/x/sys v0.28.0 h1:Fksou7UEQUWlKvIdsqzJmUmCX3cZuD2+P3XyyzwMhlA=\ngolang.org/x/sys v0.28.0/go.mod h1:/VUhepiaJMQUp4+oa/7Zr1D23ma6VTLIYjOOTFZPUcA=\n"
        var environment = ProcessInfo.processInfo.environment
        environment.merge(["GOMODCACHE": cache.path, "GOCACHE": root.appendingPathComponent("build").path, "GOENV": "off",
                           "GOPROXY": "https://private.invalid/SHOULD_NOT_REQUEST", "GOPRIVATE": "", "GONOPROXY": "", "GONOSUMDB": ""]) { _, value in value }
        let bytes = try GoModuleClient.read("module fixture\n\ngo 1.18\nrequire golang.org/x/sys v0.28.0\n", sums, root.appendingPathComponent("source"), 10, environment: environment)
        let parsed = try GoModuleInventory.parse(bytes, sums: sums, path: "go.mod")
        XCTAssertEqual(parsed.entries.map(\.identity), ["go:golang.org/x/sys@v0.28.0"])
        XCTAssertTrue(parsed.reasons.isEmpty)
        XCTAssertEqual(try Data(contentsOf: version.appendingPathComponent("v0.28.0.mod")), Data(mod.utf8))
        XCTAssertEqual(try Data(contentsOf: version.appendingPathComponent("v0.28.0.info")), Data(info.utf8))
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: cache.path).filter { !$0.hasSuffix("/") }.sorted(),
                       ["cache", "cache/download", "cache/download/golang.org", "cache/download/golang.org/x", "cache/download/golang.org/x/sys", "cache/download/golang.org/x/sys/@v", "cache/download/golang.org/x/sys/@v/v0.28.0.info", "cache/download/golang.org/x/sys/@v/v0.28.0.mod"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("build").path))
    }
}

private final class GoCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
}
