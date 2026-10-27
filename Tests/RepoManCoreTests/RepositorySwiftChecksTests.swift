import XCTest
@testable import RepoManCore

final class RepositorySwiftChecksTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("NativeChecks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try GitRunner.run(["init", "-b", "main"], at: root)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func write(_ path: String, _ text: String) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }
    private func track(_ paths: String...) throws { _ = try GitRunner.run(["add", "--"] + paths, at: root) }
    private func inspect(_ id: String) async throws -> RepositoryCheckReport { try await RepositoryChecker.run(at: root, checkIDs: [id]) }
    private func package(executable: Bool = true, requirement: String = "from: \"1.2.3\"") -> String {
        "import PackageDescription\nlet package = Package(name: \"Demo\", products: [" + (executable ? ".executable(name: \"Demo\", targets: [\"Demo\"])" : ".library(name: \"Demo\", targets: [\"Demo\"])") + "], dependencies: [.package(url: \"https://github.com/example/Dependency.git\", " + requirement + ")], targets: [])"
    }
    private func lock(_ version: String = "1.4.0", schema: Int = 3) throws -> String {
        let pin: [String: Any] = [schema == 1 ? "repositoryURL" : "location": "https://github.com/example/Dependency.git", "identity": "dependency", "state": ["version": version, "revision": String(repeating: "a", count: 40)]]
        let object: [String: Any] = schema == 1 ? ["version": 1, "object": ["pins": [pin]]] : ["version": schema, "pins": [pin]]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
    func testLeafResolutionMustExistBeTrackedAndSatisfyTheDeclaration() async throws {
        try write("Package.swift", package()); try track("Package.swift")
        var report = try await inspect("dependencies.swiftResolution")
        XCTAssertEqual(report.exitCode, 1)
        XCTAssertTrue(report.checks[0].findings[0].title.contains("missing"))
        try write("Package.resolved", lock())
        report = try await inspect("dependencies.swiftResolution")
        XCTAssertEqual(report.exitCode, 1)
        XCTAssertTrue(report.checks[0].findings[0].title.contains("not tracked"))
        try track("Package.resolved")
        let before = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        report = try await inspect("dependencies.swiftResolution")
        XCTAssertEqual(report.exitCode, 0)
        XCTAssertEqual(report.checks[0].status, "passed")
        XCTAssertEqual(before, try Data(contentsOf: root.appendingPathComponent(".git/index")))
        try write("Package.swift", package(requirement: "exact: \"1.2.3\""))
        report = try await inspect("dependencies.swiftResolution")
        XCTAssertEqual(report.exitCode, 1)
        XCTAssertTrue(report.checks[0].findings.contains { $0.title.contains("disagree") })
        for schema in [1, 2, 3] {
            try write("Package.resolved", lock("1.2.3", schema: schema))
            let fixed = try await inspect("dependencies.swiftResolution")
            XCTAssertEqual(fixed.exitCode, 0)
        }
    }
    func testLibrariesDoNotImposeResolutionAndComputedManifestsAreNeverExecuted() async throws {
        try write("Package.swift", package(executable: false)); try track("Package.swift")
        var report = try await inspect("dependencies.swiftResolution")
        XCTAssertEqual(report.checks[0].status, "not_applicable")
        let marker = root.appendingPathComponent("MUST_NOT_EXIST")
        try write("Package.swift", "import PackageDescription\nimport Foundation\nlet package = Package(name: \"Computed\", dependencies: computeDependencies())\nFileManager.default.createFile(atPath: \"" + marker.path + "\", contents: nil)")
        report = try await inspect("dependencies.swiftResolution")
        XCTAssertEqual(report.exitCode, 3)
        XCTAssertEqual(report.checks[0].status, "incomplete")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
    private let project = """
    // !$*UTF8*$!
    { archiveVersion = 1; objects = {
        P = { isa = PBXProject; mainGroup = G; };
        G = { isa = PBXGroup; children = (F,); sourceTree = "<group>"; };
        F = { isa = PBXFileReference; path = Missing.swift; sourceTree = "<group>"; };
      }; rootObject = P; }
    """
    func testXcodeReferencesUseGroupsAndRetainRealProblemsBesideUnsupportedInputs() async throws {
        try write("Demo.xcodeproj/project.pbxproj", project); try track("Demo.xcodeproj/project.pbxproj")
        var report = try await inspect("files.swiftProjectReferences")
        XCTAssertEqual(report.exitCode, 1)
        XCTAssertTrue(report.checks[0].findings[0].subject.contains("Missing.swift"))
        try write("Package.swift", "let package = Package(name: \"Demo\", dependencies: computeDependencies())"); try track("Package.swift")
        report = try await inspect("files.swiftProjectReferences")
        XCTAssertEqual(report.exitCode, 1)
        XCTAssertEqual(report.checks[0].status, "incomplete")
        XCTAssertEqual(report.checks[0].findings.count, 1)
        try write("Missing.swift", "// Source fixture")
        try write("Package.swift", "import PackageDescription\nlet package = Package(name: \"Demo\", targets: [])")
        report = try await inspect("files.swiftProjectReferences")
        XCTAssertEqual(report.exitCode, 0)
        try write("Demo.xcodeproj/project.pbxproj", project.replacingOccurrences(of: "children = (F,)", with: "children = (G,)"))
        report = try await inspect("files.swiftProjectReferences")
        XCTAssertEqual(report.exitCode, 3)
    }
    func testXcodeLeafUsesItsEmbeddedWorkspaceResolution() async throws {
        let graph: [String: Any] = ["rootObject": "P", "objects": [
            "P": ["isa": "PBXProject", "mainGroup": "G", "targets": ["T"], "packageReferences": ["R"]], "G": ["isa": "PBXGroup", "sourceTree": "<group>", "children": []],
            "T": ["isa": "PBXNativeTarget", "productType": "com.apple.product-type.application"],
            "R": ["isa": "XCRemoteSwiftPackageReference", "repositoryURL": "https://github.com/example/Dependency.git", "requirement": ["kind": "exactVersion", "version": "1.2.3"]]]]
        let plist = try PropertyListSerialization.data(fromPropertyList: graph, format: .xml, options: 0)
        try write("Demo.xcodeproj/project.pbxproj", String(decoding: plist, as: UTF8.self)); try track("Demo.xcodeproj/project.pbxproj")
        var report = try await inspect("dependencies.swiftResolution")
        XCTAssertEqual(report.exitCode, 1)
        let path = "Demo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        try write(path, lock("1.2.3")); try track(path)
        report = try await inspect("dependencies.swiftResolution")
        XCTAssertEqual(report.exitCode, 0)
        try write(path, lock("2.0.0"))
        report = try await inspect("dependencies.swiftResolution")
        XCTAssertEqual(report.exitCode, 1)
    }
    func testLocalPackagePathsRequireTheirManifestAndUnsupportedPinsStayIncomplete() async throws {
        try write("Package.swift", "import PackageDescription\nlet package = Package(name: \"Demo\", dependencies: [.package(path: \"Local\")], targets: [])"); try track("Package.swift")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Local"), withIntermediateDirectories: true)
        var report = try await inspect("files.swiftProjectReferences")
        XCTAssertEqual(report.exitCode, 1)
        try write("Local/Package.swift", "import PackageDescription\nlet package = Package(name: \"Local\", targets: [])")
        report = try await inspect("files.swiftProjectReferences")
        XCTAssertEqual(report.exitCode, 0)
        try write("Package.swift", package()); try write("Package.resolved", lock("1.2.3-beta.1")); try track("Package.resolved")
        report = try await inspect("dependencies.swiftResolution")
        XCTAssertEqual(report.exitCode, 3)
    }
    func testMalformedProjectListsCannotBecomePasses() async throws {
        try write("Demo.xcodeproj/project.pbxproj", project.replacingOccurrences(of: "children = (F,)", with: "children = invalid")); try track("Demo.xcodeproj/project.pbxproj")
        let report = try await inspect("files.swiftProjectReferences")
        XCTAssertEqual(report.exitCode, 3)
        XCTAssertEqual(report.checks[0].status, "incomplete")
    }

}
