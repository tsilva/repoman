import Foundation

public enum GitRepositoryScanner {
    public static func repositories(in folder: URL) throws -> [URL] {
        let children = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return children.filter { child in
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return false
            }
            return FileManager.default.fileExists(atPath: child.appendingPathComponent(".git").path)
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    public static func scan(
        _ url: URL,
        now: Date = Date(),
        includeDetails: Bool = true
    ) throws -> RepositorySnapshot {
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

        let worktreeText = (try? GitRunner.text(["worktree", "list", "--porcelain"], at: url)) ?? ""
        let allWorktrees = worktreeText.split(separator: "\n")
            .filter { $0.hasPrefix("worktree ") }
            .map { String($0.dropFirst("worktree ".count)) }
        let occupiedBranches = Set(worktreeText.split(separator: "\n")
            .filter { $0.hasPrefix("branch refs/heads/") }
            .map { String($0.dropFirst("branch refs/heads/".count)) })
        let linkedWorktrees = Array(allWorktrees.dropFirst()).map { URL(fileURLWithPath: $0).lastPathComponent }

        let branchText = (try? GitRunner.text(
            ["for-each-ref", "--format=%(refname:short)%09%(committerdate:unix)", "refs/heads"], at: url
        )) ?? ""
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

        let log = includeDetails
            ? ((try? GitRunner.run(
                ["log", "-n", "8", "--format=%h%x1f%s%x1f%cr%x1e"], at: url
            )) ?? Data()) : Data()
        let commits = parseCommits(log)
        let remoteURL = includeDetails
            ? (try? GitRunner.text(["config", "--get", "remote.origin.url"], at: url)) : nil

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
            commits: commits,
            detailsLoaded: includeDetails,
            checkedAt: now
        )
    }

    public static func fetch(_ url: URL) throws {
        let upstream = try? GitRunner.text(
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], at: url
        )
        let remote = upstream?.split(separator: "/").first.map(String.init) ?? "origin"
        _ = try GitRunner.run(
            ["-c", "http.lowSpeedLimit=1000", "-c", "http.lowSpeedTime=15",
             "fetch", "--quiet", "--no-tags", remote],
            at: url,
            timeout: 45
        )
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

    private static func parseCommits(_ data: Data) -> [RepositoryCommit] {
        String(decoding: data, as: UTF8.self)
            .split(separator: "\u{1e}")
            .compactMap { record in
                let fields = record.trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: "\u{1f}", omittingEmptySubsequences: false)
                guard fields.count == 3 else { return nil }
                return RepositoryCommit(
                    hash: String(fields[0]),
                    subject: String(fields[1]),
                    relativeDate: String(fields[2])
                )
            }
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
