import CryptoKit
import Foundation

/// A review belongs to one branch and one version of the working tree.
public struct RepositorySyncReview: Sendable {
    public let snapshot: RepositorySnapshot
    fileprivate let head: String
    fileprivate let remote: String
    fileprivate let remoteRef: String
    fileprivate let fetchURL: String
    fileprivate let pushURL: String
    fileprivate let fingerprint: Data
    fileprivate let paths: [String: [String]]
}

public enum RepositorySyncPhase: String, Sendable {
    case fetching = "Fetching…"
    case committing = "Committing…"
    case pulling = "Pulling…"
    case pushing = "Pushing…"
}

/// Explicit user actions only. Inspection and background refresh never call this service.
/// Run on a background task; every Git command has a bounded, noninteractive runner.
public enum RepositorySync {
    public static func review(at url: URL) throws -> RepositorySyncReview {
        try requireIdleRepository(url)
        let snapshot = try GitRepositoryScanner.scan(url, includeDetails: false)
        let target = try configuration(at: url)
        let head = try GitRunner.text(["rev-parse", "--verify", "HEAD"], at: url)
        let paths = try changedPaths(at: url)
        return RepositorySyncReview(snapshot: snapshot, head: head, remote: target.0, remoteRef: target.1,
                                    fetchURL: target.2, pushURL: target.3,
                                    fingerprint: try fingerprint(at: url), paths: paths)
    }

    /// Read only the changes selected for this reviewed commit. Never stage files or fetch refs.
    public static func commitMessageContext(_ review: RepositorySyncReview, selectedPaths: Set<String>,
                                           maximumBytes: Int = 196_608) throws -> String {
        guard maximumBytes >= 256, maximumBytes <= 196_608 else { throw GitError.failed("Invalid commit message context limit.") }
        try validate(review)
        guard !selectedPaths.isEmpty, selectedPaths.isSubset(of: Set(review.paths.keys)) else {
            throw GitError.failed("Select changed files from the current Sync review before generating a message.")
        }
        let url = review.snapshot.url
        let files = String(decoding: try JSONEncoder().encode(selectedPaths.sorted()), as: UTF8.self)
        let header = "Selected files: \(files)\n\nSelected changes:\n"
        let omitted = "\n[Additional diff content omitted. Summarize only the changes evidenced above.]\n"
        guard header.utf8.count < maximumBytes - omitted.utf8.count else {
            throw GitError.failed("Too many file names to generate a commit message. Select fewer files or write a message.")
        }
        var data = Data(header.utf8)
        let limit = maximumBytes - omitted.utf8.count
        var truncated = false
        func append(_ patch: Data) {
            let text = Data(String(decoding: patch, as: UTF8.self).utf8)
            let remaining = max(0, limit - data.count)
            data.append(text.prefix(remaining))
            if text.count > remaining { truncated = true }
        }
        let paths = Array(Set(selectedPaths.flatMap { review.paths[$0] ?? [] })).sorted()
        let options = ["--no-ext-diff", "--no-textconv", "--no-color", "--src-prefix=a/", "--dst-prefix=b/"]
        append(try GitRunner.run(["--literal-pathspecs", "diff"] + options + [review.head, "--"] + paths,
                                 at: url, maximumOutputBytes: 32 * 1_024 * 1_024))
        let untracked = try GitRunner.run(["ls-files", "--others", "--exclude-standard", "-z"], at: url)
            .split(separator: 0).map { String(decoding: $0, as: UTF8.self) }.filter { selectedPaths.contains($0) }.sorted()
        for path in untracked {
            if data.count >= limit { truncated = true; break }
            append(try GitRunner.run(["diff", "--no-index"] + options + ["--", "/dev/null", path],
                                     at: url, successfulExitCodes: [0, 1], maximumOutputBytes: 32 * 1_024 * 1_024))
        }
        // A changed review must not send a mixture of old and new file contents.
        try validate(review)
        // Drop a partial UTF-8 character at the bound rather than expanding it on decoding.
        while String(data: data, encoding: .utf8) == nil, !data.isEmpty { data.removeLast() }
        if truncated { data.append(Data(omitted.utf8)) }
        return String(decoding: data, as: UTF8.self)
    }

    public static func synchronize(_ review: RepositorySyncReview, selectedPaths: Set<String>, message: String,
                                   onProgress: @Sendable (RepositorySyncPhase) -> Void = { _ in }) throws -> RepositorySnapshot {
        let url = review.snapshot.url
        try validate(review)
        guard selectedPaths.isSubset(of: Set(review.paths.keys)) else {
            throw GitError.failed("The file selection changed. Reopen Sync to review the latest changes.")
        }
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selectedPaths.isEmpty, message.isEmpty { throw GitError.failed("Enter a message for the selected files.") }

        onProgress(.fetching)
        try GitRepositoryScanner.fetch(url)
        try validate(review)
        let fresh = try GitRepositoryScanner.scan(url, includeDetails: false)
        guard fresh.ahead != nil, let behind = fresh.behind else {
            throw GitError.failed("The upstream branch is unavailable. Check its remote configuration, then retry Sync.")
        }
        // Pulling cannot silently stash or discard files excluded from the commit.
        if behind > 0, selectedPaths != Set(review.paths.keys) {
            throw GitError.failed("Incoming commits require a clean working tree. Select all changed files or commit the remaining files before syncing.")
        }
        if !selectedPaths.isEmpty {
            onProgress(.committing)
            let paths = selectedPaths.sorted().flatMap { review.paths[$0] ?? [] }
            try commit(review, paths: Array(Set(paths)).sorted(), message: message)
        }

        if behind > 0 {
            guard try changedPaths(at: url).isEmpty else {
                throw GitError.failed("The commit was saved, but local changes remain. Review them before pulling.")
            }
            onProgress(.pulling)
            // Pin the fetched upstream and merge; never rebase, force reset or auto-stash.
            let upstream = try GitRunner.text(["rev-parse", "--verify", "@{upstream}"], at: url)
            do {
                _ = try GitRunner.run(["-c", "merge.autoStash=false", "merge", "--no-edit", upstream], at: url,
                                      timeout: 45, environmentOverrides: ["GIT_MERGE_AUTOEDIT": "no", "GIT_EDITOR": "/usr/bin/true"])
            } catch {
                throw GitError.failed("Pull stopped: \(error.localizedDescription)\nResolve and finish any merge in your editor or Terminal, then retry Sync. Local commits and files are preserved.")
            }
        }
        // Hooks or external tools may have changed the branch while we were committing/merging.
        let target = try configuration(at: url)
        guard target.0 == review.remote, target.1 == review.remoteRef,
              target.2 == review.fetchURL, target.3 == review.pushURL,
              try GitRunner.text(["symbolic-ref", "--short", "HEAD"], at: url) == review.snapshot.branch else {
            throw GitError.failed("The branch or upstream changed. Reopen Sync before pushing.")
        }
        let ready = try GitRepositoryScanner.scan(url, includeDetails: false)
        if (ready.ahead ?? 0) > 0 {
            onProgress(.pushing)
            do {
                // Explicit upstream destination avoids push.default, mirror and additional refspecs.
                _ = try GitRunner.run(["push", "--porcelain", "--no-follow-tags", "--recurse-submodules=no",
                                       "--", review.remote, "HEAD:\(review.remoteRef)"],
                                      at: url, timeout: 45)
            } catch {
                throw GitError.failed("Push stopped: \(error.localizedDescription)\nLocal commits are saved. Retry Sync after resolving the remote error.")
            }
        }
        var result = try GitRepositoryScanner.scan(url, includeDetails: false)
        result.fetchedAt = Date()
        return result
    }

    private static func configuration(at url: URL) throws -> (String, String, String, String) {
        guard let branch = try? GitRunner.text(["symbolic-ref", "--short", "HEAD"], at: url) else {
            throw GitError.failed("HEAD is detached. Switch to a branch in your editor or Terminal before syncing.")
        }
        guard let remote = try? GitRunner.text(["config", "--get", "branch.\(branch).remote"], at: url),
              remote != ".", !remote.isEmpty,
              let ref = try? GitRunner.text(["config", "--get", "branch.\(branch).merge"], at: url),
              ref.hasPrefix("refs/heads/") else {
            throw GitError.failed("This branch has no remote upstream. Set its upstream in your editor or Terminal, then retry Sync.")
        }
        let fetchURL = try GitRunner.text(["remote", "get-url", "--", remote], at: url)
        let pushURLs = try GitRunner.text(["remote", "get-url", "--push", "--all", "--", remote], at: url)
            .split(separator: "\n").map(String.init)
        guard pushURLs.count == 1, let pushURL = pushURLs.first else {
            throw GitError.failed("This remote has multiple push destinations. Configure one destination before syncing.")
        }
        return (remote, ref, fetchURL, pushURL)
    }

    private static func requireIdleRepository(_ url: URL) throws {
        for name in ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply", "sequencer"] {
            let path = try GitRunner.text(["rev-parse", "--path-format=absolute", "--git-path", name], at: url)
            if FileManager.default.fileExists(atPath: path) {
                throw GitError.failed("A merge, rebase or cherry-pick is in progress. Finish it in your editor or Terminal, then retry Sync.")
            }
        }
        guard try GitRunner.run(["ls-files", "--unmerged", "-z"], at: url).isEmpty else {
            throw GitError.failed("Resolve the conflicting files before syncing.")
        }
    }

    private static func validate(_ review: RepositorySyncReview) throws {
        let url = review.snapshot.url
        try requireIdleRepository(url)
        let target = try configuration(at: url)
        guard try GitRunner.text(["symbolic-ref", "--short", "HEAD"], at: url) == review.snapshot.branch,
              try GitRunner.text(["rev-parse", "HEAD"], at: url) == review.head,
              target.0 == review.remote, target.1 == review.remoteRef,
              target.2 == review.fetchURL, target.3 == review.pushURL,
              try fingerprint(at: url) == review.fingerprint else {
            throw GitError.failed("The branch, index or files changed since review. Reopen Sync to review the latest changes.")
        }
    }

    /// Include both names of a rename so selecting it cannot leave its deletion behind.
    private static func changedPaths(at url: URL) throws -> [String: [String]] {
        let status = try GitRunner.run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], at: url)
        let entries = status.split(separator: 0)
        var result: [String: [String]] = [:]
        var index = 0
        while index < entries.count {
            let entry = entries[index]
            guard entry.count >= 4 else { index += 1; continue }
            let path = String(decoding: entry.dropFirst(3), as: UTF8.self)
            var paths = [path]
            if entry.prefix(2).contains(UInt8(ascii: "R")) || entry.prefix(2).contains(UInt8(ascii: "C")) {
                index += 1
                if index < entries.count { paths.append(String(decoding: entries[index], as: UTF8.self)) }
            }
            result[path] = paths
            index += 1
        }
        return result
    }

    private static func fingerprint(at url: URL) throws -> Data {
        var hash = SHA256()
        for arguments in [["status", "--porcelain=v1", "-z", "--untracked-files=all"],
                          ["diff", "--no-ext-diff", "--no-textconv", "--binary", "HEAD", "--"],
                          ["diff", "--no-ext-diff", "--no-textconv", "--binary", "--cached", "--"]] {
            hash.update(data: try GitRunner.run(arguments, at: url, maximumOutputBytes: 32 * 1_024 * 1_024))
        }
        let untracked = try GitRunner.run(["ls-files", "--others", "--exclude-standard", "-z"], at: url)
        for path in untracked.split(separator: 0) {
            hash.update(data: Data(path))
            let name = String(decoding: path, as: UTF8.self)
            let file = url.appendingPathComponent(name)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            hash.update(data: Data(String(describing: attributes[.type]).utf8))
            hash.update(data: Data(String(describing: attributes[.posixPermissions]).utf8))
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                hash.update(data: Data(try FileManager.default.destinationOfSymbolicLink(atPath: file.path).utf8))
            } else {
                hash.update(data: try GitRunner.run(["hash-object", "--no-filters", "--", name], at: url))
            }
        }
        return Data(hash.finalize())
    }

    private static func commit(_ review: RepositorySyncReview, paths: [String], message: String) throws {
        let url = review.snapshot.url
        let staged = try GitRunner.text(["--literal-pathspecs", "ls-files", "--stage", "--"] + paths, at: url)
        guard !staged.split(separator: "\n").contains(where: { $0.hasPrefix("160000 ") }) else {
            throw GitError.failed("Commit submodule changes inside the submodule before syncing this repository.")
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let isolated = temporary.appendingPathComponent("commit-index")
        let env = ["GIT_INDEX_FILE": isolated.path]
        _ = try GitRunner.run(["read-tree", review.head], at: url, environmentOverrides: env)
        let pathspec = temporary.appendingPathComponent("paths")
        try Data(paths.flatMap { Array($0.utf8) + [0] }).write(to: pathspec)
        _ = try GitRunner.run(["--literal-pathspecs", "add", "--all", "--pathspec-from-file=\(pathspec.path)", "--pathspec-file-nul"],
                              at: url, environmentOverrides: env)
        // Reserve the real index before creating the commit. Other staged files remain untouched.
        let indexPath = try GitRunner.text(["rev-parse", "--path-format=absolute", "--git-path", "index"], at: url)
        let index = URL(fileURLWithPath: indexPath)
        let lock = URL(fileURLWithPath: indexPath + ".lock")
        do { try Data().write(to: lock, options: .withoutOverwriting) }
        catch { throw GitError.failed("The Git index is busy. Wait for the other Git operation, then retry Sync.") }
        defer { try? FileManager.default.removeItem(at: lock) }
        try validate(review)
        let originalIndex = try Data(contentsOf: index)
        _ = try GitRunner.run(["commit", "-m", message], at: url, timeout: 45, environmentOverrides: env)
        // Reconcile only selected paths against the new HEAD using a copy of the real index.
        // Atomically install it; excluded staged files and their staged contents survive.
        let reconciled = temporary.appendingPathComponent("reconciled-index")
        do {
            try originalIndex.write(to: reconciled)
            _ = try GitRunner.run(["--literal-pathspecs", "reset", "--quiet", "--pathspec-from-file=\(pathspec.path)",
                                   "--pathspec-file-nul", "HEAD"],
                                  at: url, environmentOverrides: ["GIT_INDEX_FILE": reconciled.path])
            try Data(contentsOf: reconciled).write(to: lock)
            guard rename(lock.path, index.path) == 0 else { throw GitError.failed("Could not install the updated index.") }
        } catch {
            throw GitError.failed("The commit was saved, but the index could not be updated: \(error.localizedDescription). Review the index in Terminal before retrying.")
        }
    }
}
