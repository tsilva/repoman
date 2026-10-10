import AppKit
import Foundation

/// Compile with RepoManCore/AppUpdate*.swift and pass the freshly built Debug app.
/// Uses disposable copies and demo mode; never replaces the installed or development app.
@main
struct VerifyAppUpdate {
    @MainActor
    static func main() async {
        do { try await verify() }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }

    @MainActor
    private static func verify() async throws {
        guard CommandLine.arguments.count == 2 else { throw AppUpdateError.message("Pass the Debug RepoMan.app path") }
        let fm = FileManager.default
        let original = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("RepoMan update verification " + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let target = root.appendingPathComponent("Installed RepoMan.app")
        let source = root.appendingPathComponent("volume/RepoMan.app")
        for app in [target, source] {
            _ = try UpdateCommand.run("/usr/bin/ditto", [original.path, app.path], timeout: 30)
            // Isolate LaunchServices registration from the real RepoMan installation.
            let plist = app.appendingPathComponent("Contents/Info.plist")
            var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as! [String: Any]
            info["CFBundleIdentifier"] = "com.tsilva.RepoMan.UpdateVerification"
            info["CFBundleShortVersionString"] = app == target ? "0.0.1" : "0.0.2"
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist)
            _ = try UpdateCommand.run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", app.path], timeout: 30)
        }
        // DMG identity/verification is covered by AppUpdateTests. This exercises the production
        // helper with the actual SwiftUI app, including its termination and relaunch acknowledgement.
        let work = try AppUpdateInstaller.workspace()
        let staging = root.appendingPathComponent(".RepoMan-update-stage")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let plan = AppUpdateInstaller.Plan(target: target, stagingDirectory: staging, workspace: work,
                                           errorFile: root.appendingPathComponent("update-error.txt"))
        defer { plan.discard() }
        _ = try UpdateCommand.run("/usr/bin/ditto", [source.path, plan.stagedApp.path], timeout: 30)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--demo"]
        configuration.createsNewApplicationInstance = true
        let old = try await NSWorkspace.shared.openApplication(at: target, configuration: configuration)
        defer {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.tsilva.RepoMan.UpdateVerification")
                .forEach { $0.terminate() }
        }
        try await Task.sleep(for: .seconds(2))
        guard !old.isTerminated else { throw AppUpdateError.message("The initial app did not launch") }
        // Add only the demo argument at the LaunchServices boundary, keeping the real installer
        // and app acknowledgement logic. The replacement must also avoid real repository work.
        let script = work.appendingPathComponent("install.sh")
        try AppUpdateInstaller.helperScript.replacingOccurrences(of: "--args --repoman-update-complete", with: "--args --demo --repoman-update-complete")
            .write(to: script, atomically: true, encoding: .utf8)
        let log = work.appendingPathComponent("installer.log")
        fm.createFile(atPath: log.path, contents: nil)
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [script.path, String(old.processIdentifier), target.path, staging.path, work.path, plan.errorFile.path]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = try FileHandle(forWritingTo: log)
        helper.standardError = helper.standardOutput
        try helper.run()
        guard old.terminate() else { throw AppUpdateError.message("Could not request termination of the disposable app") }
        let deadline = Date().addingTimeInterval(45)
        while helper.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }
        guard !helper.isRunning, helper.terminationStatus == 0 else {
            let detail = (try? String(contentsOf: work.appendingPathComponent("installer.log"), encoding: .utf8)) ?? "No installer log"
            throw AppUpdateError.message("Update helper did not finish successfully: \(detail)")
        }
        let updatedInfo = try PropertyListSerialization.propertyList(from: Data(contentsOf: target.appendingPathComponent("Contents/Info.plist")), format: nil) as! [String: Any]
        let replacements = NSRunningApplication.runningApplications(withBundleIdentifier: "com.tsilva.RepoMan.UpdateVerification")
        guard let replacement = NSRunningApplication.runningApplications(withBundleIdentifier: "com.tsilva.RepoMan.UpdateVerification")
            .first(where: { !$0.isTerminated && $0.bundleURL?.resolvingSymlinksInPath().path == target.path }),
              replacement.processIdentifier != old.processIdentifier,
              updatedInfo["CFBundleShortVersionString"] as? String == "0.0.2",
              !fm.fileExists(atPath: staging.path), !fm.fileExists(atPath: work.path),
              !fm.fileExists(atPath: plan.errorFile.path) else {
            throw AppUpdateError.message("The replacement app or cleanup could not be verified: apps=\(replacements.map { ($0.processIdentifier, $0.bundleURL?.path ?? "nil") }), version=\(updatedInfo["CFBundleShortVersionString"] ?? "nil")")
        }
        print("PASS: closed old app, replaced bundle, reopened new app, acknowledged launch, and removed backup.")
        replacement.terminate()
        while !replacement.isTerminated && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
    }
}
