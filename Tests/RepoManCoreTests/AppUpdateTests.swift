import CryptoKit
import Foundation
import XCTest
@testable import RepoManCore

final class AppUpdateTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("Update tests ' \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func release(version: String = "v0.1.10", prerelease: Bool = false, draft: Bool = false,
                         url: String? = nil, includeChecksum: Bool = true, digest: String? = nil,
                         size: Int = 3) throws -> AppUpdateRelease {
        let name = "RepoMan-\(version)-macOS-arm64-adhoc.dmg"
        var dmg: [String: Any] = ["name": name, "size": size,
                                "browser_download_url": url ?? "https://github.com/tsilva/repoman/releases/download/\(version)/\(name)"]
        if let digest { dmg["digest"] = digest }
        var assets = [dmg]
        if includeChecksum {
            assets.append(["name": name + ".sha256", "size": 103,
                           "browser_download_url": "https://github.com/tsilva/repoman/releases/download/\(version)/\(name).sha256"])
        }
        let data = try JSONSerialization.data(withJSONObject: ["tag_name": version, "draft": draft,
                                                              "prerelease": prerelease, "assets": assets])
        return try JSONDecoder().decode(AppUpdateRelease.self, from: data)
    }

    func testVersionAndAssetSelection() throws {
        XCTAssertNotNil(try release().update(after: "0.1.9", architecture: "arm64"))
        XCTAssertNil(try release().update(after: "0.2.0", architecture: "arm64"))
        XCTAssertNil(try release().update(after: "0.1.10", architecture: "arm64"))
        XCTAssertNil(try release(prerelease: true).update(after: "0.1.9", architecture: "arm64"))
        XCTAssertNil(try release(draft: true).update(after: "0.1.9", architecture: "arm64"))
        XCTAssertNil(try release(version: "v0.2.0-beta").update(after: "0.1.9", architecture: "arm64"))
        XCTAssertNil(AppVersion("1.2"))
        XCTAssertNil(AppVersion("1.٢.3"))
        XCTAssertThrowsError(try release().update(after: "0.1.9", architecture: "x86_64"))
        XCTAssertThrowsError(try release(includeChecksum: false).update(after: "0.1.9", architecture: "arm64"))
        XCTAssertThrowsError(try release(url: "https://example.com/update.dmg").update(after: "0.1.9", architecture: "arm64"))
        XCTAssertThrowsError(try release(size: 600_000_000).update(after: "0.1.9", architecture: "arm64"))
    }

    func testChecksumRejectsCorruptionWrongFilenameSizeAndGitHubDigest() throws {
        let file = root.appendingPathComponent("download.dmg")
        let data = Data("abc".utf8)
        try data.write(to: file)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let update = try XCTUnwrap(release(digest: "sha256:" + hash).update(after: "0.1.9", architecture: "arm64"))
        let checksum = Data("\(hash)  \(update.dmg.name)\n".utf8)
        try update.verify(dmgURL: file, checksumData: checksum)
        XCTAssertThrowsError(try update.verify(dmgURL: file, checksumData: Data("\(hash)  different.dmg".utf8)))
        XCTAssertThrowsError(try update.verify(dmgURL: file, checksumData: checksum + checksum))
        let badDigest = try XCTUnwrap(release(digest: "sha256:" + String(repeating: "0", count: 64)).update(after: "0.1.9", architecture: "arm64"))
        XCTAssertThrowsError(try badDigest.verify(dmgURL: file, checksumData: checksum))
        try Data("abd".utf8).write(to: file)
        XCTAssertThrowsError(try update.verify(dmgURL: file, checksumData: checksum))
        try Data("ab".utf8).write(to: file)
        XCTAssertThrowsError(try update.verify(dmgURL: file, checksumData: checksum))
    }

    func testHTTPFailuresAndNoPublishedRelease() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UpdateURLProtocol.self]
        let client = AppUpdateClient(session: URLSession(configuration: config))
        UpdateURLProtocol.status = 404
        let result = try await client.check(installed: "0.1.4", architecture: "arm64")
        XCTAssertNil(result)
        UpdateURLProtocol.status = 403
        do { _ = try await client.check(installed: "0.1.4", architecture: "arm64"); XCTFail("Expected rate limit failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("GitHub")) }
        UpdateURLProtocol.status = 200
        do { _ = try await client.check(installed: "0.1.4", architecture: "arm64"); XCTFail("Expected invalid JSON failure") }
        catch { XCTAssertTrue(error is DecodingError) }
    }

    func testInstallerPreparesSignedDMGAndRejectsWrongVersionWithoutChangingCurrentApp() throws {
        let volume = root.appendingPathComponent("volume")
        let source = volume.appendingPathComponent("RepoMan.app")
        try makeSignedApp(source)
        let target = root.appendingPathComponent("Installed RepoMan.app")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try Data("old".utf8).write(to: target.appendingPathComponent("marker"))
        let dmg = root.appendingPathComponent("fixture.dmg")
        _ = try UpdateCommand.run("/usr/bin/hdiutil", ["create", "-srcfolder", volume.path, "-format", "UDZO", dmg.path], timeout: 60)
        let work = try AppUpdateInstaller.workspace()
        defer { try? FileManager.default.removeItem(at: work) }
        let errorFile = root.appendingPathComponent("error")
        let plan = try AppUpdateInstaller.prepare(dmg: dmg, version: "0.1.10", target: target, workspace: work, errorFile: errorFile)
        defer { plan.discard() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.stagedApp.appendingPathComponent("Contents/MacOS/RepoMan").path))
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("marker")), "old")
        XCTAssertThrowsError(try AppUpdateInstaller.prepare(dmg: dmg, version: "0.1.11", target: target, workspace: work, errorFile: errorFile))
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("marker")), "old")
        XCTAssertThrowsError(try AppUpdateInstaller.prepare(dmg: dmg, version: "0.1.10", target: URL(fileURLWithPath: "/Volumes/RepoMan/RepoMan.app"), workspace: work, errorFile: errorFile))
    }

    func testBundleRejectsExternalLinksAndInvalidSignature() throws {
        let app = root.appendingPathComponent("RepoMan.app")
        try makeSignedApp(app)
        try AppUpdateInstaller.validateBundle(app, version: "0.1.10")
        try FileManager.default.createSymbolicLink(at: app.appendingPathComponent("escape"), withDestinationURL: root)
        XCTAssertThrowsError(try AppUpdateInstaller.validateBundle(app, version: "0.1.10"))
        try FileManager.default.removeItem(at: app.appendingPathComponent("escape"))
        try Data("broken".utf8).write(to: app.appendingPathComponent("Contents/MacOS/RepoMan"))
        XCTAssertThrowsError(try AppUpdateInstaller.validateBundle(app, version: "0.1.10"))
    }

    func testHelperInstallsAndCleansUpAfterLaunchAcknowledgement() throws { try runHelper(mode: "success") }
    func testHelperRestoresOldAppAfterLaunchFailure() throws { try runHelper(mode: "failure") }
    func testHelperRestoresOldAppIfNewAppDoesNotFinishLaunching() throws { try runHelper(mode: "no-ack") }
    func testHelperRestoresOldAppIfReplacementCannotBeMoved() throws { try runHelper(mode: "missing-stage") }
    func testHelperLeavesRunningAppIntactWhenQuitIsCancelled() throws { try runHelper(mode: "cancel") }

    private func makeSignedApp(_ app: URL) throws {
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appendingPathComponent("RepoMan"))
        let info = ["CFBundleIdentifier": "com.tsilva.RepoMan", "CFBundleShortVersionString": "0.1.10",
                    "CFBundleVersion": "1", "CFBundleExecutable": "RepoMan", "CFBundlePackageType": "APPL",
                    "LSMinimumSystemVersion": "13.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        _ = try UpdateCommand.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path], timeout: 20)
    }

    private func runHelper(mode: String) throws {
        let target = root.appendingPathComponent("RepoMan ; $(touch SHOULD_NOT_EXIST).app")
        let staging = root.appendingPathComponent("staging")
        let work = root.appendingPathComponent("work")
        for directory in [target, staging.appendingPathComponent("RepoMan.app"), work] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("old".utf8).write(to: target.appendingPathComponent("marker"))
        try Data("new".utf8).write(to: staging.appendingPathComponent("RepoMan.app/marker"))
        if mode == "missing-stage" { try FileManager.default.removeItem(at: staging.appendingPathComponent("RepoMan.app")) }
        let errorFile = root.appendingPathComponent("error")
        // Stub only LaunchServices so the real swap/rollback logic runs on disposable app directories.
        let launcher = root.appendingPathComponent("open-stub")
        let stub = """
        #!/bin/sh
        if [ "$(cat "$2/marker")" = old ]; then exit 0; fi
        if [ '\(mode)' = failure ]; then exit 1; fi
        if [ '\(mode)' = success ]; then touch "$5/launched"; fi
        exit 0
        """
        try stub.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        let escaped = "'" + launcher.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = AppUpdateInstaller.helperScript.replacingOccurrences(of: "/usr/bin/open", with: escaped)
            .replacingOccurrences(of: "/bin/sleep 1", with: "/bin/sleep 0.01")
        let scriptURL = root.appendingPathComponent("install.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let pid = mode == "cancel" ? String(ProcessInfo.processInfo.processIdentifier) : "2147483647"
        let arguments = [scriptURL.path, pid, target.path, staging.path, work.path, errorFile.path]
        if mode == "success" { _ = try UpdateCommand.run("/bin/sh", arguments, timeout: 10) }
        else { XCTAssertThrowsError(try UpdateCommand.run("/bin/sh", arguments, timeout: 10)) }
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("marker")), mode == "success" ? "new" : "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
        XCTAssertEqual(FileManager.default.fileExists(atPath: errorFile.path), ["failure", "no-ack", "missing-stage"].contains(mode))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("SHOULD_NOT_EXIST").path))
    }
}

private final class UpdateURLProtocol: URLProtocol {
    static var status = 200
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("invalid".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
