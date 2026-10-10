import Foundation

/// Runs only after the user requests an update. All preparation leaves the current app intact.
enum AppUpdateInstaller {
    struct Plan: Sendable {
        let target: URL
        let stagingDirectory: URL
        let workspace: URL
        let errorFile: URL
        var stagedApp: URL { stagingDirectory.appendingPathComponent("RepoMan.app") }
        var backup: URL { stagingDirectory.appendingPathComponent("Previous.app") }
        func discard() {
            try? FileManager.default.removeItem(at: stagingDirectory)
            try? FileManager.default.removeItem(at: workspace)
        }
    }

    static func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RepoMan-update-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }

    static func prepare(dmg: URL, version: String, target: URL, workspace: URL, errorFile: URL) throws -> Plan {
        let fm = FileManager.default
        let target = target.standardizedFileURL
        guard target.pathExtension == "app", target == target.resolvingSymlinksInPath(),
              !target.path.hasPrefix("/Volumes/"), !target.path.contains("/AppTranslocation/"),
              fm.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw AppUpdateError.message("Move RepoMan to a writable Applications folder before updating (for example, ~/Applications).")
        }
        let staging = target.deletingLastPathComponent().appendingPathComponent(".RepoMan-update-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let plan = Plan(target: target, stagingDirectory: staging, workspace: workspace, errorFile: errorFile)
        var prepared = false
        defer { if !prepared { try? fm.removeItem(at: staging) } }
        let mount = workspace.appendingPathComponent("mount")
        try fm.createDirectory(at: mount, withIntermediateDirectories: false)
        var detached = false
        defer {
            if !detached { _ = try? UpdateCommand.run("/usr/bin/hdiutil", ["detach", "-force", mount.path], timeout: 20) }
        }
        _ = try UpdateCommand.run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, dmg.path], timeout: 60)
        let source = mount.appendingPathComponent("RepoMan.app")
        try validateBundle(source, version: version)
        _ = try UpdateCommand.run("/usr/bin/ditto", [source.path, plan.stagedApp.path], timeout: 120)
        try validateBundle(plan.stagedApp, version: version)
        _ = try UpdateCommand.run("/usr/bin/hdiutil", ["detach", mount.path], timeout: 20)
        detached = true
        try fm.createDirectory(at: errorFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        prepared = true
        return plan
    }

    static func validateBundle(_ url: URL, version: String) throws {
        guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw AppUpdateError.message("The update app cannot be a symbolic link.")
        }
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "com.tsilva.RepoMan",
              info["CFBundleShortVersionString"] as? String == version,
              info["CFBundleExecutable"] as? String == "RepoMan",
              FileManager.default.isExecutableFile(atPath: url.appendingPathComponent("Contents/MacOS/RepoMan").path) else {
            throw AppUpdateError.message("The DMG does not contain the expected RepoMan version.")
        }
        if let minimum = info["LSMinimumSystemVersion"] as? String {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            let current = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
            guard minimum.compare(current, options: .numeric) != .orderedDescending else {
                throw AppUpdateError.message("This update requires macOS \(minimum) or later.")
            }
        }
        // Framework symlinks inside the bundle are valid; escaping the bundle is not.
        let root = url.resolvingSymlinksInPath().path + "/"
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            throw AppUpdateError.message("The update app cannot be read.")
        }
        for case let entry as URL in enumerator {
            if try entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true,
               !entry.resolvingSymlinksInPath().path.hasPrefix(root) {
                throw AppUpdateError.message("The update contains a link outside its app bundle.")
            }
        }
        _ = try UpdateCommand.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", url.path], timeout: 30)
    }

    static func launch(_ plan: Plan, parentPID: Int32) throws -> Process {
        let script = plan.workspace.appendingPathComponent("install.sh")
        try helperScript.write(to: script, atomically: true, encoding: .utf8)
        let log = plan.workspace.appendingPathComponent("installer.log")
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // No paths or release values are interpolated into executable shell text.
        process.arguments = [script.path, String(parentPID), plan.target.path, plan.stagingDirectory.path,
                             plan.workspace.path, plan.errorFile.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = try FileHandle(forWritingTo: log)
        process.standardError = process.standardOutput
        try process.run()
        return process
    }

    /// A separate process survives app termination. Same-volume renames never overwrite a running binary.
    static let helperScript = #"""
    set -eu
    parent_pid="$1"
    target="$2"
    staging="$3"
    workspace="$4"
    error_file="$5"
    staged="$staging/RepoMan.app"
    backup="$staging/Previous.app"
    parent_exited=0
    succeeded=0
    cleanup() {
        if [ "$succeeded" -eq 0 ] && [ -d "$backup" ]; then
            if [ -e "$target" ]; then /bin/mv "$target" "$staging/Failed.app" || return; fi
            if /bin/mv "$backup" "$target"; then
                printf '%s\n' 'RepoMan could not install or reopen the update. The previous version was restored. Try updating again.' > "$error_file"
                /usr/bin/open -n "$target" || true
            else
                printf 'Update failed. Your previous app is saved at %s\n' "$backup" > "$error_file"
                return
            fi
        elif [ "$succeeded" -eq 0 ] && [ "$parent_exited" -eq 1 ]; then
            printf '%s\n' 'RepoMan could not replace the app. The previous version was kept. Check folder permissions and try again.' > "$error_file"
            /usr/bin/open -n "$target" || true
        fi
        /bin/rm -rf "$staging" "$workspace"
    }
    trap cleanup EXIT
    trap 'exit 1' HUP INT TERM
    attempts=0
    while /bin/kill -0 "$parent_pid" 2>/dev/null; do
        attempts=$((attempts + 1))
        # A cancelled Quit must never replace the running app.
        if [ "$attempts" -ge 60 ]; then exit 1; fi
        /bin/sleep 1
    done
    parent_exited=1
    /bin/mv "$target" "$backup"
    /bin/mv "$staged" "$target"
    /usr/bin/open -n "$target" --args --repoman-update-complete "$workspace"
    attempts=0
    while [ ! -f "$workspace/launched" ]; do
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 30 ]; then exit 1; fi
        /bin/sleep 1
    done
    succeeded=1
    /bin/rm -f "$error_file"
    """#
}

enum UpdateCommand {
    /// File-backed output avoids pipe deadlocks. Called on a background task, never on the main actor.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> Data {
        let directory = try AppUpdateInstaller.workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("output")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if done.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
            throw AppUpdateError.message("The update operation timed out. Please try again.")
        }
        let data = try Data(contentsOf: output)
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: data.prefix(2_048), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw AppUpdateError.message("The update could not be prepared. \(detail)")
        }
        return data
    }
}
