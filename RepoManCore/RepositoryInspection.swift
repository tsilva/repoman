import Foundation

/// Additional detectors read through this context instead of adding fields to RepositorySnapshot.
/// One context per inspection shares bounded file reads across detectors.
public struct RepositoryInspectionContext: Sendable {
    public let snapshot: RepositorySnapshot
    let allowCachedRemoteMetadata: Bool
    private let files = InspectionFileCache()
    private let git = InspectionGitCache()
    private let parsing = InspectionParsingCache()
    private let ciStatus = InspectionCIStatusCache()
    private let freshness = InspectionFreshness()
    public init(snapshot: RepositorySnapshot, allowCachedRemoteMetadata: Bool = false) {
        self.snapshot = snapshot; self.allowCachedRemoteMetadata = allowCachedRemoteMetadata
    }
    func ciStatuses(load: @escaping @Sendable (RepositorySnapshot) async throws -> [CIBranchStatus]) async throws -> [CIBranchStatus] {
        let current = snapshot
        return try await ciStatus.value { try await load(current) }
    }
    var parsingComputationCount: Int { parsing.count }
    func toml(_ path: String, standaloneUV: Bool = false, allSections: Bool = false) throws -> InspectionConfig {
        let source = try readText(path)
        return try parsing.value("toml:\(standaloneUV):\(allSections):" + path, bytes: source.utf8.count) { try InspectionConfig.toml(source, standaloneUV: standaloneUV, allSections: allSections) }
    }
    func yaml(_ path: String) throws -> InspectionConfig {
        let source = try readText(path)
        return try parsing.value("yaml:" + path, bytes: source.utf8.count) { try InspectionConfig.yaml(source) }
    }
    func ini(_ path: String) throws -> InspectionConfig {
        let source = try readText(path)
        return try parsing.value("ini:" + path, bytes: source.utf8.count) { try InspectionConfig.ini(source) }
    }
    func propertyListObject(_ path: String) throws -> [String: Any] {
        let source = try readText(path)
        return try parsing.value("plist:" + path, bytes: source.utf8.count) {
            guard let object = try PropertyListSerialization.propertyList(from: Data(source.utf8), options: [], format: nil) as? [String: Any] else { throw InspectionError.blocked("Expected a project property list.") }
            return object
        }
    }
    func jsonObject(_ path: String) throws -> [String: Any] {
        let source = try readText(path)
        return try parsing.value("json:" + path, bytes: source.utf8.count) {
            guard let object = try JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: Any] else { throw InspectionError.blocked("Expected a JSON object in " + path) }
            return object
        }
    }
    func workflowLines(_ path: String) throws -> [WorkflowInspection.Line] {
        let source = try readText(path)
        return try parsing.value("workflow-lines:" + path, bytes: source.utf8.count) { try WorkflowInspection.lines(source) }
    }
    func workflowReferences(_ path: String) throws -> [String] {
        let lines = try workflowLines(path)
        return try parsing.value("workflow-references:" + path, bytes: 0) { try WorkflowInspection.references(lines) }
    }
    func workflowSteps(_ path: String, includeInputs: Bool = false, inputKeys: Set<String>? = nil, checkoutInputKeys: Set<String> = []) throws -> [WorkflowInspection.Step] {
        let lines = try workflowLines(path)
        let key = "workflow-steps:\(includeInputs):" + (inputKeys?.sorted().joined(separator: ",") ?? "*") + ":" + checkoutInputKeys.sorted().joined(separator: ",") + ":" + path
        return try parsing.value(key, bytes: 0) { try WorkflowInspection.steps(lines, includeInputs: includeInputs, inputKeys: inputKeys, checkoutInputKeys: checkoutInputKeys) }
    }
    func markCached(_ checkID: String) { freshness.insert(checkID) }
    var cachedChecks: Set<String> { freshness.values }
    var appliedExceptions: [String: [String: String]] { freshness.appliedExceptions }
    func applyingExceptions(_ findings: [RepositoryFinding], policy: RepositoryCheckPolicy) -> [RepositoryFinding] {
        findings.filter { finding in
            guard let reason = policy.exceptions[finding.checkID]?[finding.subject] else { return true }
            freshness.except(finding, reason: reason)
            return false
        }
    }
    public func readText(_ relativePath: String) throws -> String {
        try atPath(relativePath) { try files.read(checkedURL(relativePath)) }
    }
    func readNotebook(_ relativePath: String) throws -> String {
        try atPath(relativePath) { try files.read(checkedURL(relativePath), maximumBytes: 8_388_608) }
    }
    /// Size checks never open large files. Directories (including submodules) are skipped.
    func regularFileSize(_ relativePath: String) throws -> Int? {
        return try atPath(relativePath) {
            let info = try checkedURL(relativePath).resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])
            if info.isDirectory == true { return nil }
            guard info.isRegularFile == true, let size = info.fileSize else {
                throw InspectionError.blocked("Tracked path is not a regular file: " + relativePath)
            }
            return size
        }
    }
    /// Binary files are outside text detectors' scope; oversized text stays unknown.
    func trackedText(_ relativePath: String) throws -> String? {
        return try atPath(relativePath) {
            guard let size = try regularFileSize(relativePath) else { return nil }
            let result = try files.readTracked(checkedURL(relativePath), size: size)
            let name = (relativePath as NSString).lastPathComponent.lowercased()
            let knownText = ["swift", "py", "js", "jsx", "ts", "tsx", "mjs", "cjs", "json", "toml", "yaml", "yml", "txt", "md", "markdown", "rst", "adoc", "ipynb", "pem", "key", "sh", "rb", "rs", "go", "c", "h", "cpp", "html", "css", "xml", "ini", "cfg"]
            if result == nil, knownText.contains((name as NSString).pathExtension) || name.hasPrefix(".env") || name == "dockerfile" {
                throw InspectionError.blocked("Tracked text is not supported UTF-8: " + relativePath)
            }
            return result
        }
    }
    func exists(_ relativePath: String) throws -> Bool {
        return try atPath(relativePath) {
            let url = try checkedURL(relativePath)
            do { _ = try url.resourceValues(forKeys: [.isDirectoryKey]); return true }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { return false }
        }
    }
    /// Only fixed read-only commands are exposed to detectors. Disable optional index writes and fsmonitor hooks.
    func gitRead(_ arguments: [String], successfulExitCodes: Set<Int32> = [0]) throws -> Data {
        try git.read(arguments, at: snapshot.url, successfulExitCodes: successfulExitCodes)
    }
    func trackedPaths(matching patterns: [String] = []) throws -> [String] {
        let data = try gitRead(["ls-files", "-z"] + (patterns.isEmpty ? [] : ["--"] + patterns))
        guard let text = String(data: data, encoding: .utf8) else { throw InspectionError.blocked("Git paths are not UTF-8.") }
        let paths = text.split(separator: "\0").map(String.init)
        guard paths.count <= 20_000 else { throw InspectionError.blocked("Too many tracked files to inspect.") }
        return paths
    }
    func isTracked(_ relativePath: String) throws -> Bool {
        _ = try checkedURL(relativePath)
        let root = snapshot.url.standardizedFileURL
        let path = root.appendingPathComponent(relativePath).standardizedFileURL.path
        let normalized = String(path.dropFirst(root.path.count + 1))
        return !(try gitRead(["ls-files", "-z", "--", ":(literal)" + normalized])).isEmpty
    }
    func localTargetExists(_ relativePath: String) throws -> Bool {
        try atPath(relativePath) {
            let root = snapshot.url.standardizedFileURL.resolvingSymlinksInPath()
            let target = root.appendingPathComponent(relativePath).standardizedFileURL
            guard !relativePath.hasPrefix("/") else { throw InspectionError.blocked("Expected a relative documentation link.") }
            if target == root { return true }
            if target.path.hasPrefix(root.path + "/") { return try exists(relativePath) }

            // Only explicit links into a direct sibling Git working tree may leave
            // the root. Stat the target; never open sibling documentation contents.
            let parent = root.deletingLastPathComponent()
            guard target.path.hasPrefix(parent.path + "/") else {
                throw InspectionError.blocked("Documentation link leaves the repository and its direct siblings.")
            }
            let suffix = String(target.path.dropFirst(parent.path.count + 1))
            guard let name = suffix.split(separator: "/").first, !name.hasPrefix(".") else {
                throw InspectionError.blocked("Expected a visible sibling Git repository.")
            }
            let sibling = parent.appendingPathComponent(String(name)).standardizedFileURL
            guard sibling != root, sibling.resolvingSymlinksInPath() == sibling else {
                throw InspectionError.blocked("Sibling repository links must not redirect through symlinks.")
            }
            guard FileManager.default.fileExists(atPath: sibling.appendingPathComponent(".git").path) else {
                throw InspectionError.blocked("Sibling Git repository is unavailable; link could not be validated.")
            }
            let actual = String(decoding: try git.read(["rev-parse", "--show-toplevel"], at: sibling,
                successfulExitCodes: [0]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard URL(fileURLWithPath: actual).resolvingSymlinksInPath() == sibling else {
                throw InspectionError.blocked("Link does not identify a sibling Git working-tree root.")
            }
            let resolved = target.resolvingSymlinksInPath()
            guard resolved == sibling || resolved.path.hasPrefix(sibling.path + "/") else {
                throw InspectionError.blocked("Documentation target escapes its sibling repository through a symlink.")
            }
            do { _ = try resolved.resourceValues(forKeys: [.isDirectoryKey]); return true }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { return false }
        }
    }
    public func filenames(in relativeDirectory: String) throws -> [String] {
        return try atPath(relativeDirectory) {
            let directory = relativeDirectory == "." ? snapshot.url.standardizedFileURL.resolvingSymlinksInPath() : try checkedURL(relativeDirectory)
            do {
                let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                guard names.count <= 200 else { throw InspectionError.blocked("Too many directory entries to inspect.") }
                return names.sorted()
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        }
    }
    func isDirectory(_ relativePath: String) throws -> Bool {
        return try atPath(relativePath) {
            let url = relativePath == "." ? snapshot.url : try checkedURL(relativePath)
            do { return try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { return false }
        }
    }
    /// Keep diagnostics relative to the inspected repository, without exposing resolved symlink targets.
    private func atPath<T>(_ relativePath: String, _ operation: () throws -> T) throws -> T {
        let label = relativePath.hasPrefix("/") ? "Repository path" : relativePath
        do { return try operation() }
        catch let error as InspectionError {
            guard !error.localizedDescription.hasPrefix(label + ": ") else { throw error }
            throw InspectionError.blocked(label + ": " + error.localizedDescription)
        } catch {
            let error = error as NSError
            let missing = (error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)) ||
                (error.domain == NSPOSIXErrorDomain && error.code == 2)
            throw InspectionError.blocked(label + (missing ? ": Path is missing from the working tree." : ": Repository path could not be read."))
        }
    }
    private func checkedURL(_ relativePath: String) throws -> URL {
        let root = snapshot.url.standardizedFileURL.resolvingSymlinksInPath()
        let file = root.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        guard !relativePath.hasPrefix("/"), file.path.hasPrefix(root.path + "/") else {
            throw InspectionError.blocked("Inspection paths must remain inside the repository.")
        }
        return file
    }
}
private final class InspectionFreshness: @unchecked Sendable {
    private let lock = NSLock()
    private var checks: Set<String> = []
    private var exceptions: [String: [String: String]] = [:]
    func except(_ finding: RepositoryFinding, reason: String) {
        lock.lock(); defer { lock.unlock() }
        exceptions[finding.checkID, default: [:]][finding.subject] = reason
    }
    var appliedExceptions: [String: [String: String]] { lock.lock(); defer { lock.unlock() }; return exceptions }
    func insert(_ id: String) { lock.lock(); defer { lock.unlock() }; checks.insert(id) }
    var values: Set<String> { lock.lock(); defer { lock.unlock() }; return checks }
}
final class InspectionGitCache: @unchecked Sendable {
    private struct Key: Hashable {
        let directory: URL
        let arguments: [String]
        let successfulExitCodes: [Int32]
    }
    private let lock = NSLock()
    private var values: [Key: InspectionGitRead] = [:]
    private let run: @Sendable ([String], URL, Set<Int32>) throws -> Data
    init(run: @escaping @Sendable ([String], URL, Set<Int32>) throws -> Data = { arguments, directory, codes in
        try GitRunner.run(["--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false"] + arguments,
            at: directory, timeout: 10, successfulExitCodes: codes, maximumOutputBytes: 2_097_152)
    }) { self.run = run }
    func read(_ arguments: [String], at directory: URL, successfulExitCodes: Set<Int32>) throws -> Data {
        let key = Key(directory: directory, arguments: arguments, successfulExitCodes: successfulExitCodes.sorted())
        lock.lock()
        let entry = values[key] ?? InspectionGitRead()
        values[key] = entry
        lock.unlock()
        return try entry.read { try run(arguments, directory, successfulExitCodes) }
    }
}
/// Identical requests share one result (including failures); unrelated commands never wait on this lock.
private final class InspectionGitRead: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<Data, Error>?
    func read(_ load: () throws -> Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        if let value { return try value.get() }
        let result = Result(catching: load)
        value = result
        return try result.get()
    }
}
private final class InspectionFileCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URL: (text: String, bytes: Int)] = [:]
    private var totalBytes = 0
    private var sampledBytes = 0
    private var binaryFiles: Set<URL> = []
    func readTracked(_ file: URL, size: Int) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        if binaryFiles.contains(file) { return nil }
        if let cached = values[file] {
            guard cached.bytes <= 1_048_576 else { throw InspectionError.blocked("Tracked text exceeds 1 MiB.") }
            return cached.text
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var data = try handle.read(upToCount: 8_192) ?? Data()
        sampledBytes += data.count
        guard sampledBytes <= 33_554_432 else { throw InspectionError.blocked("Binary/text sampling exceeds the 32 MiB repository limit.") }
        if data.contains(0) || (data.count < 8_192 && String(data: data, encoding: .utf8) == nil) {
            binaryFiles.insert(file); return nil
        }
        guard size <= 1_048_576 else { throw InspectionError.blocked("Tracked text exceeds 1 MiB.") }
        data.append(try handle.read(upToCount: 1_048_577 - data.count) ?? Data())
        guard data.count <= 1_048_576 else { throw InspectionError.blocked("Tracked text exceeds 1 MiB.") }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { binaryFiles.insert(file); return nil }
        guard totalBytes + data.count <= 33_554_432 else { throw InspectionError.blocked("Repository text inspection exceeds the 32 MiB shared limit.") }
        totalBytes += data.count
        values[file] = (text, data.count)
        return text
    }
    func read(_ file: URL, maximumBytes: Int = 1_048_576) throws -> String {
        lock.lock(); defer { lock.unlock() }
        if let cached = values[file] {
            guard cached.bytes <= maximumBytes else { throw InspectionError.blocked("Cached file exceeds this detector's file limit.") }
            return cached.text
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes, let text = String(data: data, encoding: .utf8) else {
            throw InspectionError.blocked("Inspection requires UTF-8 within the \(maximumBytes)-byte file limit.")
        }
        guard totalBytes + data.count <= 33_554_432 else { throw InspectionError.blocked("Repository text inspection exceeds the 32 MiB shared limit.") }
        totalBytes += data.count
        values[file] = (text, data.count)
        return text
    }
}
public enum RepositoryCheckResult: Codable, Sendable {
    case findings([RepositoryFinding])
    case notApplicable(String)
    case skipped(String)
    case partial([RepositoryFinding], String)
    case unavailable(String)
    var detectedFindings: [RepositoryFinding] {
        switch self { case .findings(let findings), .partial(let findings, _): return findings; case .unavailable, .notApplicable, .skipped: return [] }
    }
}
public enum RepositoryCheckStatus: Sendable {
    case queued, running, passed, findings, incomplete, notApplicable, skipped
}

public struct RepositoryInspectionReport: Sendable {
    public let snapshot: RepositorySnapshot
    public let results: [String: RepositoryCheckResult]
    public let checkOrder: [String]
    public var cachedChecks: Set<String> = []
    public var completedAt: [String: Date] = [:]
    public var runningCheckIDs: Set<String> = []
    public var appliedExceptions: [String: [String: String]] = [:]
    /// Missing results are queued unless the scheduler has actually started the check.
    public func status(for checkID: String) -> RepositoryCheckStatus? {
        guard checkOrder.contains(checkID) else { return nil }
        switch results[checkID] {
        case .findings(let findings): return findings.isEmpty ? .passed : .findings
        case .notApplicable: return .notApplicable
        case .skipped: return .skipped
        case .partial, .unavailable: return .incomplete
        case nil: return runningCheckIDs.contains(checkID) ? .running : .queued
        }
    }
    public var unavailableChecks: [String: String] {
        results.compactMapValues { result in
            switch result { case .unavailable(let reason), .partial(_, let reason): return reason; case .findings, .notApplicable, .skipped: return nil }
        }
    }
    /// Local refresh keeps prior fetch errors. Reevaluate cheap checks against that final snapshot.
    public func updatingSnapshot(_ snapshot: RepositorySnapshot, catalog: RepositoryIssueCatalog) -> Self {
        var updated = results
        for check in catalog.checks where !check.requiresExtendedInspection && !cachedChecks.contains(check.id) && results[check.id] != nil {
            if let reason = check.availability(snapshot) { updated[check.id] = .unavailable(reason) }
            else { updated[check.id] = RepositoryCheck.result(check.detect(snapshot), for: check.id, snapshot: snapshot) }
        }
        return Self(snapshot: snapshot, results: updated, checkOrder: checkOrder, cachedChecks: cachedChecks,
                    completedAt: completedAt, runningCheckIDs: runningCheckIDs, appliedExceptions: appliedExceptions)
    }
    /// Prerequisites explain verification failures once without counting them as maintenance checks.
    public var coverage: [RepositoryCheckReport.Coverage] {
        let comparisonIDs: Set<String> = ["git.push", "git.pull", "git.diverged", "git.unpublishedBranches", "git.upstream", "inspection.remote"]
        let selected = checkOrder.filter { comparisonIDs.contains($0) }
        let hasRemote = snapshot.remoteURL != nil || snapshot.upstream != nil
        let remoteStatus = selected.isEmpty || !hasRemote ? "not_applicable" : snapshot.hasFreshRemoteComparison ? "passed" : "incomplete"
        let remote = RepositoryCheckReport.Coverage(id: "remote", status: remoteStatus,
            reason: !hasRemote ? "No Git remotes require refreshing." : selected.isEmpty ? "No remote-tracking comparison selected." : remoteStatus == "passed" ? "Remote-tracking refs were freshly fetched." : "Remote refs are not verified fresh; affected comparisons remain provisional.",
            affectedCheckIDs: remoteStatus == "incomplete" ? selected : [])
        let syncIDs: Set<String> = ["git.push", "git.pull", "git.diverged", "inspection.comparison"]
        let sync = checkOrder.filter { syncIDs.contains($0) }
        let compareStatus = sync.isEmpty || snapshot.upstream == nil ? "not_applicable" : snapshot.ahead != nil && snapshot.behind != nil ? "passed" : "incomplete"
        let comparison = RepositoryCheckReport.Coverage(id: "comparison", status: compareStatus,
            reason: compareStatus == "not_applicable" ? "No selected upstream comparison applies." : compareStatus == "passed" ? "Local upstream counts are available; freshness is reported separately." : "Upstream refs could not be compared.", affectedCheckIDs: compareStatus == "incomplete" ? sync : [])
        let fileChecks = checkOrder.filter { id in
            if ["files.readme", "files.gitignore", "files.license", "inspection.files"].contains(id) { return true }
            return unavailableChecks[id]?.localizedCaseInsensitiveContains("repository root files") == true || unavailableChecks[id]?.localizedCaseInsensitiveContains("repository files") == true
        }
        let files = RepositoryCheckReport.Coverage(id: "files", status: snapshot.rootFiles != nil ? "passed" : fileChecks.isEmpty ? "not_applicable" : "incomplete",
            reason: snapshot.rootFiles != nil ? "Repository root listing is available." : "Repository root listing could not be inspected.", affectedCheckIDs: snapshot.rootFiles == nil ? fileChecks : [])
        return [remote, comparison, files]
    }
    public func findings(disabledChecks: Set<String> = []) -> [RepositoryFinding] {
        checkOrder.filter { !disabledChecks.contains($0) }.flatMap { key -> [RepositoryFinding] in
            results[key]?.detectedFindings ?? []
        }
    }
}

public extension RepositoryIssueCatalog {
    /// Keep at most four inspections active, replacing each completed check immediately.
    func inspect(
        _ snapshot: RepositorySnapshot,
        allowCachedRemoteMetadata: Bool = false,
        cache: RepositoryInspectionCache? = nil,
        forceRefresh: Bool = false,
        excludingChecks: Set<String> = [],
        now: @escaping @Sendable () -> Date = { Date() },
        onProgress: (@Sendable (RepositoryInspectionReport) async -> Void)? = nil
    ) async -> RepositoryInspectionReport {
        let activeChecks = checks.filter { !excludingChecks.contains($0.id) }
        let context = RepositoryInspectionContext(snapshot: snapshot, allowCachedRemoteMetadata: allowCachedRemoteMetadata && !forceRefresh)
        let reusable = forceRefresh ? [:] : await cache?.reusableResults(for: snapshot, checks: activeChecks, now: now()) ?? [:]
        var results = reusable.mapValues(\.result)
        var completedAt = reusable.mapValues(\.completedAt)
        let reusedChecks = Set(reusable.keys)
        let order = activeChecks.map(\.id)
        await withTaskGroup(of: (String, RepositoryCheckResult).self) { group in
            var pending = activeChecks.filter { !reusedChecks.contains($0.id) }.makeIterator()
            var running: Set<String> = []
            func enqueue(_ check: RepositoryCheck) {
                running.insert(check.id)
                group.addTask {
                    do {
                        let result = try await check.evaluate(context)
                        let findings = result.detectedFindings
                        guard findings.allSatisfy({ $0.repositoryID == snapshot.id && $0.checkID == check.id }),
                              Set(findings.map(\.id)).count == findings.count else {
                            return (check.id, .unavailable("Detector returned invalid or duplicate finding identities."))
                        }
                        return (check.id, result)
                    } catch InspectionError.notApplicable(let reason) { return (check.id, .notApplicable(reason)) }
                    catch InspectionError.skipped(let reason) { return (check.id, .skipped(reason)) }
                    catch { return (check.id, .unavailable(error.localizedDescription)) }
                }
            }
            for _ in 0..<4 { if let check = pending.next() { enqueue(check) } }
            await onProgress?(RepositoryInspectionReport(snapshot: snapshot, results: results, checkOrder: order,
                cachedChecks: reusedChecks, completedAt: completedAt, runningCheckIDs: running))
            for await (id, result) in group {
                running.remove(id)
                results[id] = result
                completedAt[id] = now()
                if let check = pending.next() { enqueue(check) }
                await onProgress?(RepositoryInspectionReport(snapshot: snapshot, results: results, checkOrder: order,
                    cachedChecks: reusedChecks.union(context.cachedChecks), completedAt: completedAt, runningCheckIDs: running))
            }
        }
        let report = RepositoryInspectionReport(snapshot: snapshot, results: results, checkOrder: order,
            cachedChecks: reusedChecks.union(context.cachedChecks), completedAt: completedAt,
            appliedExceptions: context.appliedExceptions)
        await cache?.store(report)
        return report
    }
    func verify(_ finding: RepositoryFinding, in report: RepositoryInspectionReport) -> InspectionVerification {
        guard report.snapshot.id == finding.repositoryID else { return .unknown("Repository identity changed.") }
        if report.cachedChecks.contains(finding.checkID) { return .unknown("Cached check results cannot confirm absence; a fresh inspection is required.") }
        guard let result = report.results[finding.checkID] else { return .unknown("The original detector is no longer registered.") }
        switch result {
        case .notApplicable(let reason): return .unknown("Check is not applicable: " + reason)
        case .skipped(let reason): return .unknown("Check was skipped: " + reason)
        case .unavailable(let reason): return .unknown(reason)
        case .partial(let findings, let reason):
            if let current = findings.first(where: { $0.id == finding.id }) { return .present(current.evidence) }
            return .unknown(reason)
        case .findings(let findings):
            if let current = findings.first(where: { $0.id == finding.id }) { return .present(current.evidence) }
            return .absent("Fresh inspection confirms this finding is absent.")
        }
    }
}

/// Results and their original completion times survive app restarts. Manual refresh
/// bypasses cached results; only fresh inspection can confirm absence.
public actor RepositoryInspectionCache {
    public struct Entry: Codable, Sendable {
        public let result: RepositoryCheckResult
        public let completedAt: Date
    }
    private struct RepositoryEntry: Codable {
        let identity: String
        var checks: [String: Entry]
    }
    private struct Storage: Codable {
        var version = 3
        var repositories: [String: RepositoryEntry] = [:]
    }
    private var storage: Storage
    private let url: URL
    public private(set) var persistenceError: String?

    public init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("RepoMan/inspection-cache.json")) {
        self.url = url
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Storage.self, from: data), saved.version == 3 {
            storage = saved
        } else { storage = Storage() }
    }

    private func identity(_ snapshot: RepositorySnapshot) -> String {
        // A replacement checkout, branch switch, or remote change invalidates its results.
        let git = snapshot.url.appendingPathComponent(".git")
        let created = (try? git.resourceValues(forKeys: [.creationDateKey]))?.creationDate?.timeIntervalSince1970
        return [snapshot.branch, snapshot.upstream ?? "", snapshot.remoteURL ?? "", created.map { String($0) } ?? ""]
            .joined(separator: "\0")
    }

    public func reusableResults(for snapshot: RepositorySnapshot, checks: [RepositoryCheck], now: Date = Date()) -> [String: Entry] {
        guard let repository = storage.repositories[snapshot.id], repository.identity == identity(snapshot) else { return [:] }
        return checks.reduce(into: [:]) { entries, check in
            guard !check.usesContentCache, let entry = repository.checks[check.id],
                  !check.isDue(result: entry.result, completedAt: entry.completedAt, now: now) else { return }
            entries[check.id] = entry
        }
    }

    public func invalidate(checkIDs: Set<String>) {
        for key in storage.repositories.keys {
            for id in checkIDs { storage.repositories[key]?.checks.removeValue(forKey: id) }
        }
        do { try JSONEncoder().encode(storage).write(to: url, options: .atomic) }
        catch { persistenceError = "Could not save issue check preferences: \(error.localizedDescription)" }
    }

    public func store(_ report: RepositoryInspectionReport) {
        guard report.results.keys.contains(where: { !report.cachedChecks.contains($0) && report.completedAt[$0] != nil }) else { return }
        let key = report.snapshot.id
        let identity = identity(report.snapshot)
        var repository = storage.repositories[key].flatMap { $0.identity == identity ? $0 : nil }
            ?? RepositoryEntry(identity: identity, checks: [:])
        for (id, result) in report.results where !report.cachedChecks.contains(id) {
            guard let date = report.completedAt[id], repository.checks[id].map({ $0.completedAt <= date }) ?? true else { continue }
            repository.checks[id] = Entry(result: result, completedAt: date)
        }
        storage.repositories[key] = repository
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(storage).write(to: url, options: .atomic)
            persistenceError = nil
        } catch { persistenceError = "Could not save issue check results: \(error.localizedDescription)" }
    }
}

public enum InspectionVerification: Codable, Equatable, Sendable {
    case absent(String), present(String), unknown(String)
    public var evidence: String {
        switch self { case .absent(let s), .present(let s), .unknown(let s): return s }
    }
    /// Shared verification often returns the same reason for each instance. Keep one copy in summaries.
    public static func conciseEvidence(_ evidence: String) -> String {
        var seen = Set<String>()
        return evidence.components(separatedBy: "\n").filter {
            $0.isEmpty || seen.insert($0).inserted
        }.joined(separator: "\n")
    }
}

public enum InspectionError: Error, LocalizedError {
    case blocked(String)
    case notApplicable(String)
    case skipped(String)
    public var errorDescription: String? { switch self { case .blocked(let message), .notApplicable(let message), .skipped(let message): return message } }
}

/// Per-inspection immutable parse results and failures; never a cross-repository or persistent cache.
final class InspectionParsingCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Result<Any, Error>] = [:]
    private var bytes = 0
    private let maximumEntries: Int
    private let maximumBytes: Int
    init(maximumEntries: Int = 256, maximumBytes: Int = 67_108_864) {
        self.maximumEntries = maximumEntries; self.maximumBytes = maximumBytes
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
    func value<T>(_ key: String, bytes cost: Int, load: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        if let value = values[key] {
            guard let typed = try value.get() as? T else { throw InspectionError.blocked("Inspection parse-cache type mismatch.") }; return typed
        }
        guard values.count < maximumEntries, bytes + cost <= maximumBytes else { throw InspectionError.blocked("Shared parsing exceeds inspection limits.") }
        bytes += cost
        let result = Result<Any, Error> { try load() }
        values[key] = result
        guard let typed = try result.get() as? T else { throw InspectionError.blocked("Inspection parse-cache type mismatch.") }; return typed
    }
}
