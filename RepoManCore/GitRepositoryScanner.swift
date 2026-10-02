import Foundation

public enum GitRepositoryScanner {
    public static func repositories(in folder: URL, excludingPaths: [String] = []) throws -> [URL] {
        let blacklist = RepositoryPathBlacklist(paths: excludingPaths, relativeTo: folder)
        guard !blacklist.contains(folder) else { return [] }
        let children = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return children.filter { child in
            guard !blacklist.contains(child) else { return false }
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return false
            }
            var isGitDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: child.appendingPathComponent(".git").path,
                isDirectory: &isGitDirectory
            ) else { return false }
            if isGitDirectory.boolValue { return true }

            // A .git file can identify either a linked worktree or a primary
            // repository with separate metadata. Only linked worktrees have
            // different per-worktree and common Git directories.
            // Discovery only reads metadata; never wait for a Git subprocess here.
            guard let pointer = try? metadataText(at: child.appendingPathComponent(".git")),
                  pointer.hasPrefix("gitdir: ") else { return false }
            let path = String(pointer.dropFirst("gitdir: ".count))
            guard !path.isEmpty else { return false }
            let directory = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: child.path, isDirectory: true))
                .standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  FileManager.default.fileExists(atPath: directory.appendingPathComponent("HEAD").path) else { return false }
            let commonFile = directory.appendingPathComponent("commondir")
            guard FileManager.default.fileExists(atPath: commonFile.path) else { return true }
            guard let commonPath = try? metadataText(at: commonFile), !commonPath.isEmpty else { return false }
            let common = URL(fileURLWithPath: commonPath, relativeTo: URL(fileURLWithPath: directory.path, isDirectory: true))
                .standardizedFileURL.resolvingSymlinksInPath()
            return directory.path == common.path
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private static func metadataText(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 4_097) ?? Data()
        guard data.count <= 4_096, let text = String(data: data, encoding: .utf8) else {
            throw GitError.failed("Invalid Git directory metadata.")
        }
        return text.trimmingCharacters(in: .newlines)
    }

    public static func scan(
        _ url: URL,
        now: Date = Date(),
        includeDetails: Bool = true
    ) throws -> RepositorySnapshot {
        var inspectionErrors: [String: String] = [:]
        func inspect(_ key: String, _ arguments: [String]) -> String {
            do { return try GitRunner.text(arguments, at: url) }
            catch { inspectionErrors[key] = error.localizedDescription; return "" }
        }
        let branch = (try? GitRunner.text(["symbolic-ref", "--quiet", "--short", "HEAD"], at: url))
            ?? (try? GitRunner.text(["rev-parse", "--short", "HEAD"], at: url))
            ?? "No commits"
        let upstream = try? GitRunner.text(
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], at: url
        )
        let divergence = upstream.flatMap { _ -> (Int, Int)? in
            guard let output = try? GitRunner.text(["rev-list", "--left-right", "--count", "HEAD...@{upstream}"], at: url) else {
                return nil
            }
            let values = output.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
            return values.count == 2 ? (values[0], values[1]) : nil
        }

        let status = try GitRunner.run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], at: url)
        var trackedStats = Data()
        var fallbackStagedStats = Data()
        if includeDetails {
            if let fullDiff = try? GitRunner.run(["diff", "HEAD", "--numstat", "-z"], at: url) {
                trackedStats = fullDiff
            } else {
                // Unborn repositories have no HEAD; combine staged and unstaged changes.
                trackedStats = (try? GitRunner.run(["diff", "--numstat", "-z"], at: url)) ?? Data()
                fallbackStagedStats = (try? GitRunner.run(["diff", "--cached", "--numstat", "-z"], at: url)) ?? Data()
            }
        }
        let changes = workingTreeChanges(
            status: status,
            unstagedStats: trackedStats,
            stagedStats: fallbackStagedStats,
            directory: url,
            includeLineCounts: includeDetails
        )

        let worktreeText = inspect("worktrees", ["worktree", "list", "--porcelain"])
        let allWorktrees = worktreeText.split(separator: "\n")
            .filter { $0.hasPrefix("worktree ") }
            .map { String($0.dropFirst("worktree ".count)) }
        let occupiedBranches = Set(worktreeText.split(separator: "\n")
            .filter { $0.hasPrefix("branch refs/heads/") }
            .map { String($0.dropFirst("branch refs/heads/".count)) })
        let linkedWorktrees = Array(allWorktrees.dropFirst()).map { URL(fileURLWithPath: $0).lastPathComponent }

        let branchText = inspect("branches", ["for-each-ref", "--format=%(refname:short)%09%(committerdate:unix)", "refs/heads"])
        let staleCutoff = now.addingTimeInterval(-90 * 24 * 60 * 60).timeIntervalSince1970
        let staleBranches = branchText.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let timestamp = TimeInterval(parts[1]),
                  timestamp < staleCutoff else { return nil }
            let name = String(parts[0])
            guard name != branch, name != "main", name != "master", !occupiedBranches.contains(name) else {
                return nil
            }
            return name
        }

        // Summary scans need HEAD's date for sorting, without loading the full history.
        let log = (try? GitRunner.run(
            ["log", "-n", includeDetails ? "8" : "1", "--format=%h%x1f%s%x1f%cr%x1f%ct%x1e"], at: url
        )) ?? Data()
        let history = parseHistory(log)
        // CI checks also run during summary scans. Use the tracked remote when available.
        let remote = (try? GitRunner.text(["config", "--get", "branch.\(branch).remote"], at: url)) ?? "origin"
        let configuredURL = try? GitRunner.text(["config", "--get", "remote.\(remote).url"], at: url)
        let remoteNames = (try? GitRunner.text(["remote"], at: url))?.split(separator: "\n").map(String.init) ?? []
        let remoteURL = configuredURL ?? remoteNames.first.flatMap { try? GitRunner.text(["config", "--get", "remote.\($0).url"], at: url) }

        return RepositorySnapshot(
            url: url,
            name: url.lastPathComponent,
            branch: branch,
            upstream: upstream,
            remoteURL: remoteURL,
            ahead: divergence?.0,
            behind: divergence?.1,
            changes: changes,
            staleBranches: staleBranches.sorted(),
            worktrees: linkedWorktrees.sorted(),
            commits: includeDetails ? history.commits : [],
            detailsLoaded: includeDetails,
            checkedAt: now,
            rootFiles: try? rootFiles(at: url),
            inspectionErrors: inspectionErrors,
            lastCommitAt: history.lastCommitAt
        )
    }

    private static func rootFiles(at url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { entry in
                let directory = try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                return !directory || ["xcodeproj", "xcworkspace"].contains(entry.pathExtension.lowercased())
            }
            .map(\.lastPathComponent)
    }

    public static func fetch(_ url: URL) throws {
        let remotes = try GitRunner.text(["remote"], at: url).split(separator: "\n").map(String.init)
        guard remotes.count <= 16 else { throw GitError.failed("More than 16 remotes need refreshing.") }
        let deadline = Date().addingTimeInterval(45)
        for remote in remotes {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw GitError.failed("Remote refresh exceeded its 45-second limit.") }
            // Explicit destinations keep custom/mirror fetch settings from updating local branches or tags.
            _ = try GitRunner.run(
                ["-c", "http.lowSpeedLimit=1000", "-c", "http.lowSpeedTime=15",
                 "fetch", "--quiet", "--prune", "--no-prune-tags", "--no-tags", "--no-recurse-submodules", "--refmap=",
                 "--", remote, "+refs/heads/*:refs/remotes/\(remote)/*"],
                at: url, timeout: remaining
            )
        }
    }

    private static func workingTreeChanges(
        status: Data,
        unstagedStats: Data,
        stagedStats: Data,
        directory: URL,
        includeLineCounts: Bool
    ) -> [WorkingTreeChange] {
        var stats = parseNumstat(unstagedStats)
        for (path, value) in parseNumstat(stagedStats) {
            if let existing = stats[path] {
                stats[path] = (sum(existing.0, value.0), sum(existing.1, value.1))
            } else {
                stats[path] = value
            }
        }

        let entries = status.split(separator: 0, omittingEmptySubsequences: true)
        var changes: [WorkingTreeChange] = []
        var index = 0
        while index < entries.count {
            let entry = entries[index]
            defer { index += 1 }
            guard entry.count >= 4 else { continue }
            let code = Array(entry.prefix(2))
            let path = String(decoding: entry.dropFirst(3), as: UTF8.self)
            if code.contains(UInt8(ascii: "R")) || code.contains(UInt8(ascii: "C")) {
                index += 1 // The second NUL-terminated path is the original name.
            }
            let kind: WorkingTreeChange.Kind = code == [63, 63] ? .untracked : .modified
            let lineCounts: (Int?, Int?)
            if kind == .untracked, includeLineCounts {
                lineCounts = (untrackedLineCount(directory.appendingPathComponent(path)), nil)
            } else {
                lineCounts = stats[path] ?? (nil, nil)
            }
            changes.append(WorkingTreeChange(
                path: path,
                kind: kind,
                added: lineCounts.0,
                removed: lineCounts.1
            ))
        }
        return changes.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func parseNumstat(_ data: Data) -> [String: (Int?, Int?)] {
        let entries = data.split(separator: 0, omittingEmptySubsequences: false)
        var results: [String: (Int?, Int?)] = [:]
        var index = 0
        while index < entries.count {
            let fields = entries[index].split(separator: 9, maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { index += 1; continue }
            let added = Int(String(decoding: fields[0], as: UTF8.self))
            let removed = Int(String(decoding: fields[1], as: UTF8.self))
            var path = String(decoding: fields[2], as: UTF8.self)
            if path.isEmpty, index + 2 < entries.count {
                path = String(decoding: entries[index + 2], as: UTF8.self)
                index += 2
            }
            if !path.isEmpty { results[path] = (added, removed) }
            index += 1
        }
        return results
    }

    private static func parseHistory(_ data: Data) -> (commits: [RepositoryCommit], lastCommitAt: Date?) {
        let records = String(decoding: data, as: UTF8.self).split(separator: "\u{1e}")
        let timestamp = records.first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\u{1f}", omittingEmptySubsequences: false).last
            .flatMap { TimeInterval($0) }
        let commits = records.compactMap { record -> RepositoryCommit? in
            let fields = record.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard fields.count == 4 else { return nil }
            return RepositoryCommit(
                hash: String(fields[0]),
                subject: String(fields[1]),
                relativeDate: String(fields[2])
            )
        }
        return (commits, timestamp.map { Date(timeIntervalSince1970: $0) })
    }

    private static func untrackedLineCount(_ url: URL) -> Int? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 1_000_000,
              let data = try? Data(contentsOf: url),
              !data.contains(0) else { return nil }
        guard !data.isEmpty else { return 0 }
        let newlines = data.reduce(into: 0) { count, byte in
            if byte == 10 { count += 1 }
        }
        return newlines + (data.last == 10 ? 0 : 1)
    }

    private static func sum(_ lhs: Int?, _ rhs: Int?) -> Int? {
        guard let lhs, let rhs else { return nil }
        return lhs + rhs
    }
}

/// Folder names match any path component; other paths exclude a folder and its descendants.
/// Check both the visible path and its resolved target so symlinks cannot bypass exclusions.
public struct RepositoryPathBlacklist: Sendable {
    private let names: Set<String>
    private let roots: [[String]]

    public init(paths: [String], relativeTo folder: URL) {
        var names = Set<String>()
        var roots: [[String]] = []
        for entry in paths {
            let path = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { continue }
            if !path.contains("/"), !path.hasPrefix("~"), path != ".", path != ".." {
                names.insert(path)
            } else {
                let expanded = (path as NSString).expandingTildeInPath
                let url = expanded.hasPrefix("/")
                    ? URL(fileURLWithPath: expanded, isDirectory: true)
                    : folder.appendingPathComponent(expanded, isDirectory: true)
                roots.append(url.standardizedFileURL.pathComponents)
                roots.append(url.standardizedFileURL.resolvingSymlinksInPath().pathComponents)
            }
        }
        self.names = names
        self.roots = roots
    }

    public func contains(_ url: URL) -> Bool {
        guard !names.isEmpty || !roots.isEmpty else { return false }
        let paths = [url.standardizedFileURL.pathComponents,
                     url.standardizedFileURL.resolvingSymlinksInPath().pathComponents]
        return paths.contains { components in
            !names.isDisjoint(with: components) || roots.contains { components.starts(with: $0) }
        }
    }
}
