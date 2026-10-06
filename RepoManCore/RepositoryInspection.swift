import Foundation

/// Additional detectors read through this context instead of adding fields to RepositorySnapshot.
/// One context per inspection shares bounded file reads across detectors.
public struct RepositoryInspectionContext: Sendable {
    public let snapshot: RepositorySnapshot
    let allowCachedRemoteMetadata: Bool
    let allowCachedModelChecks: Bool
    let allowCachedWebsiteChecks: Bool
    private let files = InspectionFileCache()
    private let git = InspectionGitCache()
    private let freshness = InspectionFreshness()
    let websiteProbes = WebsiteInspectionSession()
    public init(snapshot: RepositorySnapshot, allowCachedRemoteMetadata: Bool = false, allowCachedModelChecks: Bool = false,
                allowCachedWebsiteChecks: Bool = false) {
        self.snapshot = snapshot; self.allowCachedRemoteMetadata = allowCachedRemoteMetadata
        self.allowCachedModelChecks = allowCachedModelChecks
        self.allowCachedWebsiteChecks = allowCachedWebsiteChecks
    }
    func markCached(_ checkID: String) { freshness.insert(checkID) }
    var cachedChecks: Set<String> { freshness.values }
    public func readText(_ relativePath: String) throws -> String {
        try files.read(checkedURL(relativePath))
    }
    func readNotebook(_ relativePath: String) throws -> String {
        try files.read(checkedURL(relativePath), maximumBytes: 8_388_608)
    }
    /// Size checks never open large files. Directories (including submodules) are skipped.
    func regularFileSize(_ relativePath: String) throws -> Int? {
        let info = try checkedURL(relativePath).resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])
        if info.isDirectory == true { return nil }
        guard info.isRegularFile == true, let size = info.fileSize else {
            throw RepairError.blocked("Tracked path is not a regular file: " + relativePath)
        }
        return size
    }
    /// Binary files are outside text detectors' scope; oversized text stays unknown.
    func trackedText(_ relativePath: String) throws -> String? {
        guard let size = try regularFileSize(relativePath) else { return nil }
        let result = try files.readTracked(checkedURL(relativePath), size: size)
        let name = (relativePath as NSString).lastPathComponent.lowercased()
        let knownText = ["swift", "py", "js", "jsx", "ts", "tsx", "mjs", "cjs", "json", "toml", "yaml", "yml", "txt", "md", "markdown", "rst", "adoc", "ipynb", "pem", "key", "sh", "rb", "rs", "go", "c", "h", "cpp", "html", "css", "xml", "ini", "cfg"]
        if result == nil, knownText.contains((name as NSString).pathExtension) || name.hasPrefix(".env") || name == "dockerfile" {
            throw RepairError.blocked("Tracked text is not supported UTF-8: " + relativePath)
        }
        return result
    }
    func exists(_ relativePath: String) throws -> Bool {
        let url = try checkedURL(relativePath)
        do { _ = try url.resourceValues(forKeys: [.isDirectoryKey]); return true }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return false }
    }
    /// Only fixed read-only commands are exposed to detectors. Disable optional index writes and fsmonitor hooks.
    func gitRead(_ arguments: [String], successfulExitCodes: Set<Int32> = [0]) throws -> Data {
        try git.read(arguments, at: snapshot.url, successfulExitCodes: successfulExitCodes)
    }
    func trackedPaths(matching patterns: [String] = []) throws -> [String] {
        let data = try gitRead(["ls-files", "-z"] + (patterns.isEmpty ? [] : ["--"] + patterns))
        guard let text = String(data: data, encoding: .utf8) else { throw RepairError.blocked("Git paths are not UTF-8.") }
        let paths = text.split(separator: "\0").map(String.init)
        guard paths.count <= 20_000 else { throw RepairError.blocked("Too many tracked files to inspect.") }
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
        if !relativePath.hasPrefix("/"), snapshot.url.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath() == snapshot.url.standardizedFileURL.resolvingSymlinksInPath() { return true }
        return try exists(relativePath)
    }
    public func filenames(in relativeDirectory: String) throws -> [String] {
        let directory = relativeDirectory == "." ? snapshot.url.standardizedFileURL.resolvingSymlinksInPath() : try checkedURL(relativeDirectory)
        do {
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            guard names.count <= 200 else { throw RepairError.blocked("Too many directory entries to inspect.") }
            return names.sorted()
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
    }
    func isDirectory(_ relativePath: String) throws -> Bool {
        let url = relativePath == "." ? snapshot.url : try checkedURL(relativePath)
        do { return try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return false }
    }
    private func checkedURL(_ relativePath: String) throws -> URL {
        let root = snapshot.url.standardizedFileURL.resolvingSymlinksInPath()
        let file = root.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        guard !relativePath.hasPrefix("/"), file.path.hasPrefix(root.path + "/") else {
            throw RepairError.blocked("Inspection paths must remain inside the repository.")
        }
        return file
    }
}
private final class InspectionFreshness: @unchecked Sendable {
    private let lock = NSLock()
    private var checks: Set<String> = []
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
            guard cached.bytes <= 1_048_576 else { throw RepairError.blocked("Tracked text exceeds 1 MiB.") }
            return cached.text
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var data = try handle.read(upToCount: 8_192) ?? Data()
        sampledBytes += data.count
        guard sampledBytes <= 33_554_432 else { throw RepairError.blocked("Binary/text sampling exceeds the 32 MiB repository limit.") }
        if data.contains(0) || (data.count < 8_192 && String(data: data, encoding: .utf8) == nil) {
            binaryFiles.insert(file); return nil
        }
        guard size <= 1_048_576 else { throw RepairError.blocked("Tracked text exceeds 1 MiB.") }
        data.append(try handle.read(upToCount: 1_048_577 - data.count) ?? Data())
        guard data.count <= 1_048_576 else { throw RepairError.blocked("Tracked text exceeds 1 MiB.") }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { binaryFiles.insert(file); return nil }
        guard totalBytes + data.count <= 33_554_432 else { throw RepairError.blocked("Repository text inspection exceeds the 32 MiB shared limit.") }
        totalBytes += data.count
        values[file] = (text, data.count)
        return text
    }
    func read(_ file: URL, maximumBytes: Int = 1_048_576) throws -> String {
        lock.lock(); defer { lock.unlock() }
        if let cached = values[file] {
            guard cached.bytes <= maximumBytes else { throw RepairError.blocked("Cached file exceeds this detector's file limit.") }
            return cached.text
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes, let text = String(data: data, encoding: .utf8) else {
            throw RepairError.blocked("Inspection requires UTF-8 within the \(maximumBytes)-byte file limit.")
        }
        guard totalBytes + data.count <= 33_554_432 else { throw RepairError.blocked("Repository text inspection exceeds the 32 MiB shared limit.") }
        totalBytes += data.count
        values[file] = (text, data.count)
        return text
    }
}
public enum RepositoryCheckResult: Codable, Sendable {
    case findings([RepositoryFinding])
    case partial([RepositoryFinding], String)
    case unavailable(String)
    var detectedFindings: [RepositoryFinding] {
        switch self { case .findings(let findings), .partial(let findings, _): return findings; case .unavailable: return [] }
    }
}
public enum RepositoryCheckStatus: Sendable {
    case queued, running, passed, findings, incomplete
}

public struct RepositoryInspectionReport: Sendable {
    public let snapshot: RepositorySnapshot
    public let results: [String: RepositoryCheckResult]
    public let checkOrder: [String]
    public var cachedChecks: Set<String> = []
    public var completedAt: [String: Date] = [:]
    public var runningCheckIDs: Set<String> = []
    /// Missing results are queued unless the scheduler has actually started the check.
    public func status(for checkID: String) -> RepositoryCheckStatus? {
        guard checkOrder.contains(checkID) else { return nil }
        switch results[checkID] {
        case .findings(let findings): return findings.isEmpty ? .passed : .findings
        case .partial, .unavailable: return .incomplete
        case nil: return runningCheckIDs.contains(checkID) ? .running : .queued
        }
    }
    public var unavailableChecks: [String: String] {
        results.compactMapValues { result in
            switch result { case .unavailable(let reason), .partial(_, let reason): return reason; case .findings: return nil }
        }
    }
    /// Local refresh keeps prior fetch errors. Reevaluate cheap checks against that final snapshot.
    public func updatingSnapshot(_ snapshot: RepositorySnapshot, catalog: RepositoryIssueCatalog) -> Self {
        var updated = results
        for check in catalog.checks where !check.requiresExtendedInspection && !cachedChecks.contains(check.id) && results[check.id] != nil {
            if let reason = check.availability(snapshot) { updated[check.id] = .unavailable(reason) }
            else { updated[check.id] = .findings(check.detect(snapshot)) }
        }
        return Self(snapshot: snapshot, results: updated, checkOrder: checkOrder, cachedChecks: cachedChecks,
                    completedAt: completedAt, runningCheckIDs: runningCheckIDs)
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
        let context = RepositoryInspectionContext(snapshot: snapshot, allowCachedRemoteMetadata: allowCachedRemoteMetadata && !forceRefresh,
            allowCachedModelChecks: cache != nil && !forceRefresh, allowCachedWebsiteChecks: cache != nil && !forceRefresh)
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
                    } catch { return (check.id, .unavailable(error.localizedDescription)) }
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
            cachedChecks: reusedChecks.union(context.cachedChecks), completedAt: completedAt)
        await cache?.store(report)
        return report
    }
    func verify(_ finding: RepositoryFinding, in report: RepositoryInspectionReport) -> RepairVerification {
        guard report.snapshot.id == finding.repositoryID else { return .unknown("Repository identity changed.") }
        if report.cachedChecks.contains(finding.checkID) { return .unknown("Cached check results cannot verify a repair; a fresh inspection is required.") }
        guard let result = report.results[finding.checkID] else { return .unknown("The original detector is no longer registered.") }
        switch result {
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

/// Results and their original completion times survive app restarts. Repair inspection
/// omits this cache, so cached findings can never establish that a repair succeeded.
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
        var version = 1
        var repositories: [String: RepositoryEntry] = [:]
    }
    private var storage: Storage
    private let url: URL
    public private(set) var persistenceError: String?

    public init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("RepoMan/inspection-cache.json")) {
        self.url = url
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Storage.self, from: data), saved.version == 1 {
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
