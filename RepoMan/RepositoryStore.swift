import AppKit
import Combine
import Foundation
import OSLog

@MainActor
final class RepositoryStore: ObservableObject {
    @Published private(set) var folder: URL?
    @Published private(set) var repositories: [RepositorySnapshot] = []
    @Published private(set) var selectedPath: String?
    @Published private(set) var isScanning = false
    @Published private(set) var isFetching = false
    @Published private(set) var loadingRepositoryIDs: Set<String> = []
    private var repositoryLoads: [String: Set<UUID>] = [:]
    @Published private(set) var repositoryCheckProgress: [String: RepositoryCheckProgress] = [:]
    private var checkProgressByLoad: [String: [UUID: RepositoryCheckProgress]] = [:]
    private struct CheckLoad {
        let checkIDs: Set<String>
        var report: RepositoryInspectionReport?
    }
    private var checksByLoad: [String: [UUID: CheckLoad]] = [:]
    private struct ProgressKey: Hashable { let path: String; let token: UUID }
    private struct PendingProgress {
        let report: RepositoryInspectionReport
        let generation: UUID
        let token: UUID
        let preservingFetchState: Bool
        let didFetch: Bool
        let sequence: Int
    }
    private var pendingProgress: [ProgressKey: PendingProgress] = [:]
    private var progressPublicationTask: Task<Void, Never>?
    private var progressSequence = 0
    @Published private(set) var errorMessage: String?

    private var inspectionReports: [String: RepositoryInspectionReport] = [:]
    private nonisolated static let inspectionCache = RepositoryInspectionCache()
    private var scheduledOverviewTask: Task<Void, Never>?
    private static let countsCacheKey = "githubRepositoryCounts.v1"
    @Published private var githubCounts: [String: GitHubRepositoryCountsEntry] = [:]
    private var countsRefreshTask: Task<Void, Never>?
    private var countsRetryAfter: [String: Date] = [:]
    private var countsServiceRetryAfter = Date.distantPast
    static let analyticsConfigurationURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/RepoMan/analytics.json")
    @Published private(set) var analyticsConfigurationError = false
    @Published private var trafficByRepository: [String: [GA4TrafficWindow: GA4TrafficReading]] = [:]
    private struct TrafficCacheEntry {
        let count: Int?
        let observedAt: Date?
        let retryAt: Date
        let failed: Bool
    }
    private var trafficCache: [GA4TrafficQuery: TrafficCacheEntry] = [:]
    private var trafficRefreshTask: Task<Void, Never>?
    private var scheduledTrafficTask: Task<Void, Never>?
    private var started = false
    private var generation = UUID()
    let issueCatalog = RepositoryIssueCatalog()
    @Published private(set) var ignoredChecks: [String: [String]] = UserDefaults.standard.dictionary(forKey: "ignoredRepositoryChecks") as? [String: [String]] ?? [:]
    @Published private(set) var disabledChecks = Set(UserDefaults.standard.stringArray(forKey: "disabledRepositoryChecks") ?? [])
    @Published private(set) var excludedRepositoryPaths = UserDefaults.standard.stringArray(forKey: "excludedRepositoryPaths") ?? []
    var isQuittingForUpdate = false
    var updateUnavailableReason: String? {
        if isScanning || isFetching || !loadingRepositoryIDs.isEmpty { return "Wait for repository checks to finish before updating." }
        return nil
    }

    func prepareForAppUpdate() throws {
        if let reason = updateUnavailableReason { throw AppUpdateError.message(reason) }
        isQuittingForUpdate = true
    }
    let isDemo = ProcessInfo.processInfo.arguments.contains("--demo")

    var selectedRepository: RepositorySnapshot? {
        repositories.first { $0.id == selectedPath }
    }

    func findings(in repository: RepositorySnapshot) -> [RepositoryFinding] {
        issues(in: repository).filter { $0.status == .finding }.map(\.finding)
    }

    func issues(in repository: RepositorySnapshot) -> [RepositoryIssueListItem] {
        guard !repository.branch.isEmpty else { return [] }
        let disabled = disabledChecks.union(ignoredChecks[repository.id] ?? []).union(RepositoryIssueCatalog.activityCheckIDs)
        let findings = inspectionReports[repository.id]?.findings(disabledChecks: disabled)
            ?? (isDemo ? issueCatalog.findings(in: repository, disabledChecks: disabled) : [])
        let items = RepositoryIssueListItem.items(findings: findings)
        let incomplete = inspectionReports[repository.id].map { issueCatalog.incompleteItems(in: $0, disabledChecks: disabled) } ?? []
        return items + incomplete
    }

    func checkObservation(for finding: RepositoryFinding) -> Date? {
        inspectionReports[finding.repositoryID]?.completedAt[finding.checkID]
    }

    var findings: [RepositoryFinding] { repositories.flatMap { findings(in: $0) } }

    func checks(in repository: RepositorySnapshot) -> [RepositoryCheckListItem] {
        let excluded = disabledChecks.union(ignoredChecks[repository.id] ?? []).union(RepositoryIssueCatalog.activityCheckIDs)
        let loads = Array((checksByLoad[repository.id] ?? [:]).values)
        return issueCatalog.checks.compactMap { check in
            guard !excluded.contains(check.id) else { return nil }
            let activeLoads = loads.filter { $0.checkIDs.contains(check.id) }
            let statuses = activeLoads.compactMap { load -> RepositoryCheckStatus? in
                guard let report = load.report else { return .queued }
                return report.status(for: check.id)
            }
            let status: RepositoryCheckStatus?
            if statuses.contains(.running) { status = .running }
            else if statuses.contains(.queued) { status = .queued }
            else {
                let latest = activeLoads.compactMap(\.report).filter { $0.results[check.id] != nil }
                    .max { ($0.completedAt[check.id] ?? .distantPast) < ($1.completedAt[check.id] ?? .distantPast) }
                status = (latest ?? inspectionReports[repository.id])?.status(for: check.id)
            }
            guard let status else { return nil }
            return RepositoryCheckListItem(repository: repository, check: check, status: status)
        }
    }

    func ignore(_ finding: RepositoryFinding) {
        var checks = Set(ignoredChecks[finding.repositoryID] ?? [])
        checks.insert(finding.checkID)
        ignoredChecks[finding.repositoryID] = checks.sorted()
        if !isDemo { UserDefaults.standard.set(ignoredChecks, forKey: "ignoredRepositoryChecks") }
    }

    func restoreChecks(for repository: RepositorySnapshot) {
        ignoredChecks.removeValue(forKey: repository.id)
        if !isDemo { UserDefaults.standard.set(ignoredChecks, forKey: "ignoredRepositoryChecks") }
    }

    func setCheck(_ id: String, enabled: Bool) {
        if enabled { disabledChecks.remove(id) } else { disabledChecks.insert(id) }
        if !isDemo { UserDefaults.standard.set(disabledChecks.sorted(), forKey: "disabledRepositoryChecks") }
    }

    func addExcludedRepositoryPath(_ entry: String) {
        let path = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !excludedRepositoryPaths.contains(path) else { return }
        setExcludedRepositoryPaths(excludedRepositoryPaths + [path])
    }

    func removeExcludedRepositoryPath(_ path: String) {
        setExcludedRepositoryPaths(excludedRepositoryPaths.filter { $0 != path })
    }

    private func setExcludedRepositoryPaths(_ paths: [String]) {
        excludedRepositoryPaths = paths
        if !isDemo { UserDefaults.standard.set(paths, forKey: "excludedRepositoryPaths") }
        guard let folder else { return }
        let blacklist = RepositoryPathBlacklist(paths: paths, relativeTo: folder)
        repositories.removeAll { blacklist.contains($0.url) }
        if !repositories.contains(where: { $0.id == selectedPath }) {
            selectedPath = repositories.first?.id
            if !isDemo { UserDefaults.standard.set(selectedPath, forKey: "selectedRepoPath") }
        }
        guard !isDemo else { return }
        // Invalidate in-flight results before discovering the newly allowed repositories.
        discardPendingProgress()
        generation = UUID()
        isScanning = false
        isFetching = false
        Task { await refreshOverview(in: folder) }
    }

    func issueStatusCounts(in repository: RepositorySnapshot) -> [RepositoryIssueStatus: Int] {
        RepositoryIssueStatus.counts(in: issues(in: repository))
    }

    func start() {
        guard !started else { return }
        started = true
        if isDemo {
            folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("repos/tsilva")
            repositories = Self.demoRepositories()
            githubCounts = Dictionary(uniqueKeysWithValues: repositories.enumerated().compactMap { index, repository in
                guard let key = GitHubRepositoryCountsQuery.key(for: repository.remoteURL) else { return nil }
                let counts = GitHubRepositoryCounts(stars: [128, 0, 1_240, 67][index % 4], forks: [12, 0, 81, 4][index % 4])
                return (key, GitHubRepositoryCountsEntry(counts: counts, fetchedAt: Date()))
            })
            for (index, repository) in repositories.enumerated() {
                guard let key = GA4TrafficConfiguration.repositoryKey(for: repository.remoteURL) else { continue }
                trafficByRepository[key] = [
                    .sevenDays: GA4TrafficReading(count: [436, 0, 1280, 92][index % 4], observedAt: Date(), isStale: false),
                    .realtime: GA4TrafficReading(count: [8, 0, 24, 2][index % 4], observedAt: Date(), isStale: false)
                ]
            }
            selectedPath = repositories.first?.id
            if ProcessInfo.processInfo.arguments.contains("--check-progress") { startDemoCheckProgress() }
            return
        }
        if let saved = UserDefaults.standard.data(forKey: Self.countsCacheKey),
           let entries = try? JSONDecoder().decode([String: GitHubRepositoryCountsEntry].self, from: saved) {
            githubCounts = entries
        }
        scheduledOverviewTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.scheduleCountsRefresh()
                guard let folder = self.folder, !self.isScanning, !self.isFetching, !self.isQuittingForUpdate else { continue }
                await self.refreshOverview(in: folder)
            }
        }
        scheduledTrafficTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let self, !self.isQuittingForUpdate else { return }
                self.refreshTraffic()
            }
        }
        if let savedPath = UserDefaults.standard.string(forKey: "monitoredFolder"),
           FileManager.default.fileExists(atPath: savedPath) {
            let savedFolder = URL(fileURLWithPath: savedPath, isDirectory: true)
            folder = savedFolder
            selectedPath = UserDefaults.standard.string(forKey: "selectedRepoPath")
            Task { await refreshOverview(in: savedFolder, clearFirst: true) }
        }
    }

    func counts(for repository: RepositorySnapshot) -> GitHubRepositoryCounts? {
        guard let key = GitHubRepositoryCountsQuery.key(for: repository.remoteURL) else { return nil }
        return githubCounts[key]?.counts
    }

    func traffic(for repository: RepositorySnapshot) -> [GA4TrafficWindow: GA4TrafficReading]? {
        guard let key = GA4TrafficConfiguration.repositoryKey(for: repository.remoteURL) else { return nil }
        return trafficByRepository[key]
    }

    private func refreshTraffic(force: Bool = false) {
        guard !isDemo, !isQuittingForUpdate, trafficRefreshTask == nil, !repositories.isEmpty else { return }
        let keys = Set(repositories.compactMap { GA4TrafficConfiguration.repositoryKey(for: $0.remoteURL) })
        guard !keys.isEmpty else { return }
        let url = Self.analyticsConfigurationURL
        trafficRefreshTask = Task {
            defer { trafficRefreshTask = nil }
            let result = await Task.detached(priority: .utility) {
                Result { try GA4TrafficConfiguration.load(from: url) }
            }.value
            guard !isQuittingForUpdate else { return }
            let config = try? result.get()
            let configurationFailed: Bool
            if case .failure = result { configurationFailed = true }
            else { configurationFailed = false }
            if analyticsConfigurationError != configurationFailed {
                analyticsConfigurationError = configurationFailed
            }
            let configuredKeys = keys.filter { config?.repositories[$0] != nil }
            let bindings = Dictionary(uniqueKeysWithValues: configuredKeys.map { key in
                (key, Dictionary(uniqueKeysWithValues: GA4TrafficWindow.allCases.compactMap { window in
                    config?.query(for: key, window: window).map { (window, $0) }
                }))
            })
            let queries = Set(bindings.values.flatMap(\.values))
            trafficCache = trafficCache.filter { queries.contains($0.key) }
            publishTraffic(bindings)
            let now = Date()
            let due = queries.filter { force || (trafficCache[$0]?.retryAt ?? .distantPast) <= now }
                .sorted { ($0.window.refreshInterval, $0.propertyId) < ($1.window.refreshInterval, $1.propertyId) }
            await withTaskGroup(of: (GA4TrafficQuery, Int?).self) { group in
                var pending = due.makeIterator()
                for _ in 0..<4 {
                    guard let query = pending.next() else { break }
                    group.addTask(priority: .utility) { (query, try? query.load()) }
                }
                for await (query, count) in group {
                    guard !isQuittingForUpdate else { group.cancelAll(); continue }
                    let now = Date()
                    let previous = trafficCache[query]
                    trafficCache[query] = TrafficCacheEntry(count: count ?? previous?.count,
                        observedAt: count == nil ? previous?.observedAt : now,
                        retryAt: now.addingTimeInterval(count == nil ? 300 : query.window.refreshInterval),
                        failed: count == nil)
                    publishTraffic(bindings)
                    if let next = pending.next() {
                        group.addTask(priority: .utility) { (next, try? next.load()) }
                    }
                }
            }
        }
    }

    private func publishTraffic(_ bindings: [String: [GA4TrafficWindow: GA4TrafficQuery]]) {
        let now = Date()
        let readings = bindings.mapValues { windows in
            Dictionary(uniqueKeysWithValues: GA4TrafficWindow.allCases.map { window in
                guard let query = windows[window], let entry = trafficCache[query], let observedAt = entry.observedAt else {
                    return (window, GA4TrafficReading.unavailable)
                }
                return (window, GA4TrafficReading(count: entry.count, observedAt: observedAt,
                    isStale: entry.failed || now.timeIntervalSince(observedAt) >= window.refreshInterval))
            })
        }
        if readings != trafficByRepository { trafficByRepository = readings }
    }

    private func dueCountsKeys(at now: Date) -> [String] {
        guard !isQuittingForUpdate, now >= countsServiceRetryAfter else { return [] }
        let keys = Set(repositories.compactMap { GitHubRepositoryCountsQuery.key(for: $0.remoteURL) })
        return keys.filter { countsAreDue(for: $0, at: now) }.sorted()
    }

    private func countsAreDue(for key: String, at now: Date) -> Bool {
        githubCounts[key]?.isFresh(at: now) != true && now >= (countsRetryAfter[key] ?? .distantPast)
    }

    private func scheduleCountsRefresh(discoveredKey: String? = nil) {
        let now = Date()
        guard !isDemo, !isQuittingForUpdate, countsRefreshTask == nil, now >= countsServiceRetryAfter,
              discoveredKey.map({ countsAreDue(for: $0, at: now) }) ?? !dueCountsKeys(at: now).isEmpty else { return }
        countsRefreshTask = Task { [weak self] in
            // Scans publish repositories incrementally. Let several arrive before
            // starting a query, and allow at most one request at a time.
            try? await Task.sleep(for: .seconds(3))
            guard let self else { return }
            defer { self.countsRefreshTask = nil }
            while !Task.isCancelled {
                let keys = Array(self.dueCountsKeys(at: Date()).prefix(GitHubRepositoryCountsQuery.batchSize))
                guard !keys.isEmpty else { return }
                let counts = await Task.detached(priority: .utility) {
                    try? GitHubRepositoryCountsQuery.load(keys)
                }.value
                let now = Date()
                let retryAfter = now.addingTimeInterval(600)
                guard let counts else {
                    // An offline client or an expired login affects the whole batch.
                    self.countsServiceRetryAfter = retryAfter
                    return
                }
                var updated = self.githubCounts
                for key in keys {
                    if let value = counts[key] {
                        updated[key] = GitHubRepositoryCountsEntry(counts: value, fetchedAt: now)
                        self.countsRetryAfter.removeValue(forKey: key)
                    } else {
                        self.countsRetryAfter[key] = retryAfter
                    }
                }
                guard !counts.isEmpty else { continue }
                self.githubCounts = updated
                if let data = try? JSONEncoder().encode(updated) {
                    UserDefaults.standard.set(data, forKey: Self.countsCacheKey)
                }
            }
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Monitor Folder"
        panel.message = "Choose the folder containing your Git repositories."
        if panel.runModal() == .OK, let url = panel.url {
            discardPendingProgress()
            generation = UUID()
            isScanning = false
            isFetching = false
            repositoryLoads = [:]
            loadingRepositoryIDs = []
            checkProgressByLoad = [:]
            checksByLoad = [:]
            repositoryCheckProgress = [:]
            folder = url
            UserDefaults.standard.set(url.path, forKey: "monitoredFolder")
            selectedPath = nil
            UserDefaults.standard.removeObject(forKey: "selectedRepoPath")
            Task { await refreshOverview(in: url, clearFirst: true) }
        }
    }

    func select(_ repository: RepositorySnapshot) {
        // Navigation uses cached findings; only refreshes should run repository checks.
        selectedPath = repository.id
        UserDefaults.standard.set(repository.id, forKey: "selectedRepoPath")
    }

    func openSelectedRepositoryInTerminal() {
        guard let repository = selectedRepository else { return }
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            errorMessage = "Terminal could not be found."
            return
        }
        NSWorkspace.shared.open([repository.url], withApplicationAt: terminal, configuration: .init()) { [weak self] _, error in
            if let error {
                Task { @MainActor in self?.errorMessage = "Could not open Terminal: \(error.localizedDescription)" }
            }
        }
    }

    func openSelectedRepositoryInCursor() {
        guard let repository = selectedRepository else { return }
        guard let cursor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.todesktop.230313mzl4w4u92") else {
            errorMessage = "Cursor could not be found. Install Cursor to open this repository."
            return
        }
        let launcher = cursor.appendingPathComponent("Contents/Resources/app/bin/cursor")
        guard FileManager.default.isExecutableFile(atPath: launcher.path) else {
            errorMessage = "Cursor's IDE launcher could not be found. Reinstall Cursor to open this repository."
            return
        }
        // Finder-style folder opens can route to the last active Agent window.
        // The bundled CLI forwards --classic even when Cursor is already running.
        let process = Process()
        process.executableURL = launcher
        process.arguments = ["--classic", repository.url.path]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "VSCODE_IPC_HOOK_CLI")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            guard process.terminationStatus != 0 else { return }
            let status = process.terminationStatus
            Task { @MainActor in self?.errorMessage = "Could not open Cursor IDE (exit code \(status))." }
        }
        do {
            try process.run()
        } catch {
            errorMessage = "Could not open Cursor IDE: \(error.localizedDescription)"
        }
    }

    func hasIssueResults(for repository: RepositorySnapshot) -> Bool {
        isDemo || !(inspectionReports[repository.id]?.results.isEmpty ?? true)
    }

    func refreshAll() {
        guard let folder, !isDemo, !isScanning, !isFetching, !isQuittingForUpdate else { return }
        refreshTraffic(force: true)
        Task { await refreshOverview(in: folder) }
    }

    func scanIssues(for repository: RepositorySnapshot) {
        guard !repository.branch.isEmpty, !isDemo, !isFetching, !isScanning, !isQuittingForUpdate else { return }
        let currentGeneration = generation
        isFetching = true
        let loadingToken = beginLoading([repository.url])
        let onProgress = progressHandler(generation: currentGeneration, token: loadingToken, preservingFetchState: false,
                                         didFetch: repository.remoteURL != nil)
        Task {
            defer { endLoading(repository.url, token: loadingToken) }
            await WebsiteInventoryCache.shared.invalidate()
            let result: ScanResult
            result = await Task.detached(priority: .utility) {
                await Self.inspect(repository.url, onProgress: onProgress)
            }.value
            guard generation == currentGeneration else { return }
            apply(result, preservingFetchState: false)
            isFetching = false
            if let error = await Self.inspectionCache.persistenceError { errorMessage = error }
        }
    }

    /// Tokens keep overlapping refreshes from clearing each other's loading indicator.
    @discardableResult
    private func beginLoading(_ urls: [URL], token: UUID = UUID()) -> UUID {
        for url in urls {
            repositoryLoads[url.path, default: []].insert(token)
            loadingRepositoryIDs.insert(url.path)
            let excluded = disabledChecks.union(ignoredChecks[url.path] ?? [])
            let checks = Set(issueCatalog.checks.filter { !excluded.contains($0.id) }.map(\.id))
            checksByLoad[url.path, default: [:]][token] = CheckLoad(checkIDs: checks)
            checkProgressByLoad[url.path, default: [:]][token] = RepositoryCheckProgress(completed: 0, total: checks.count)
            updateCheckProgress(for: url.path)
        }
        return token
    }
    private func endLoading(_ url: URL, token: UUID) {
        guard var tokens = repositoryLoads[url.path], tokens.remove(token) != nil else { return }
        pendingProgress.removeValue(forKey: ProgressKey(path: url.path, token: token))
        checkProgressByLoad[url.path]?.removeValue(forKey: token)
        checksByLoad[url.path]?.removeValue(forKey: token)
        if checksByLoad[url.path]?.isEmpty == true { checksByLoad.removeValue(forKey: url.path) }
        if checkProgressByLoad[url.path]?.isEmpty == true { checkProgressByLoad.removeValue(forKey: url.path) }
        updateCheckProgress(for: url.path)
        if tokens.isEmpty {
            repositoryLoads.removeValue(forKey: url.path)
            loadingRepositoryIDs.remove(url.path)
        } else { repositoryLoads[url.path] = tokens }
    }
    private func updateCheckProgress(for path: String) {
        guard let loads = checkProgressByLoad[path], !loads.isEmpty else {
            repositoryCheckProgress.removeValue(forKey: path)
            return
        }
        repositoryCheckProgress[path] = RepositoryCheckProgress(
            completed: loads.values.reduce(0) { $0 + $1.completed },
            total: loads.values.reduce(0) { $0 + $1.total })
    }

    private func progressHandler(generation currentGeneration: UUID, token: UUID,
                                 preservingFetchState: Bool, didFetch: Bool = false) -> @Sendable (RepositoryInspectionReport) async -> Void {
        { [weak self] report in
            await self?.queueProgress(report, generation: currentGeneration, token: token,
                                      preservingFetchState: preservingFetchState, didFetch: didFetch)
        }
    }

    private func queueProgress(_ report: RepositoryInspectionReport, generation currentGeneration: UUID,
                               token: UUID, preservingFetchState: Bool, didFetch: Bool) {
        guard generation == currentGeneration, repositoryLoads[report.snapshot.id]?.contains(token) == true else { return }
        progressSequence += 1
        pendingProgress[ProgressKey(path: report.snapshot.id, token: token)] = PendingProgress(
            report: report, generation: currentGeneration, token: token,
            preservingFetchState: preservingFetchState, didFetch: didFetch, sequence: progressSequence)
        guard progressPublicationTask == nil else { return }
        // Reports contain every completed check. Publish the newest report per load
        // together instead of rebuilding the window for each detector completion.
        progressPublicationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.publishPendingProgress()
        }
    }

    private func publishPendingProgress() {
        let updates = pendingProgress.values.sorted { $0.sequence < $1.sequence }
        pendingProgress.removeAll(keepingCapacity: true)
        progressPublicationTask = nil
        for update in updates {
            applyProgress(update.report, generation: update.generation, token: update.token,
                          preservingFetchState: update.preservingFetchState, didFetch: update.didFetch)
        }
    }

    private func discardPendingProgress() {
        progressPublicationTask?.cancel()
        progressPublicationTask = nil
        pendingProgress.removeAll()
    }

    private func applyProgress(_ report: RepositoryInspectionReport, generation currentGeneration: UUID,
                               token: UUID, preservingFetchState: Bool, didFetch: Bool) {
        let path = report.snapshot.id
        guard generation == currentGeneration, repositoryLoads[path]?.contains(token) == true else { return }
        checkProgressByLoad[path]?[token] = RepositoryCheckProgress(completed: report.results.count, total: report.checkOrder.count)
        checksByLoad[path]?[token]?.report = report
        // Keep previous findings until their detector finishes this inspection.
        let results = (inspectionReports[path]?.results ?? [:]).merging(report.results) { _, fresh in fresh }
        let previous = inspectionReports[path]
        let cached = Set((previous?.results ?? [:]).keys).subtracting(report.results.keys).union(report.cachedChecks)
        let dates = (previous?.completedAt ?? [:]).merging(report.completedAt) { _, fresh in fresh }
        let visibleReport = RepositoryInspectionReport(snapshot: report.snapshot, results: results, checkOrder: report.checkOrder,
                                                       cachedChecks: cached, completedAt: dates)
        apply(ScanResult(url: report.snapshot.url, snapshot: report.snapshot, fetchError: report.snapshot.fetchError,
                         didFetch: didFetch || report.snapshot.fetchedAt != nil, report: visibleReport),
              preservingFetchState: preservingFetchState && report.snapshot.fetchedAt == nil && report.snapshot.fetchError == nil)
        updateCheckProgress(for: path)
    }

    private func refreshOverview(in url: URL, clearFirst: Bool = false) async {
        guard !isScanning, !isFetching, !isQuittingForUpdate, folder == url else { return }
        let started = ContinuousClock.now
        defer { ScanTiming.record("overview", since: started) }
        discardPendingProgress()
        generation = UUID()
        let currentGeneration = generation
        isScanning = true
        errorMessage = nil
        if clearFirst { repositories = []; inspectionReports = [:] }
        repositoryLoads = [:]
        loadingRepositoryIDs = []
        checkProgressByLoad = [:]
        checksByLoad = [:]
        repositoryCheckProgress = [:]

        let exclusions = excludedRepositoryPaths
        let discovery = await Task.detached(priority: .utility) {
            Result { try ScanTiming.measure("discovery") {
                try GitRepositoryScanner.repositories(in: url, excludingPaths: exclusions)
            } }
        }.value
        guard generation == currentGeneration else { return }
        let urls: [URL]
        switch discovery {
        case .success(let found):
            urls = found
        case .failure(let error):
            errorMessage = error.localizedDescription
            isScanning = false
            return
        }

        let paths = Set(urls.map(\.path))
        repositories.removeAll { !paths.contains($0.id) }
        inspectionReports = inspectionReports.filter { paths.contains($0.key) }
        let existing = Set(repositories.map(\.id))
        repositories += urls.filter { !existing.contains($0.path) }.map { repoURL in
            RepositorySnapshot(url: repoURL, name: repoURL.lastPathComponent, branch: "", upstream: nil, remoteURL: nil,
                ahead: nil, behind: nil, changes: [], staleBranches: [], worktrees: [], commits: [], detailsLoaded: false)
        }
        repositories.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !repositories.contains(where: { $0.id == selectedPath }) { selectedPath = repositories.first?.id }

        await withTaskGroup(of: ScanResult.self) { group in
            var pending = urls.makeIterator()
            @MainActor func enqueue(_ url: URL) {
                let includeDetails = url.path == selectedPath
                group.addTask(priority: .utility) {
                    do {
                        let snapshot = try ScanTiming.measure("snapshot") {
                            try GitRepositoryScanner.scan(url, includeDetails: includeDetails)
                        }
                        return ScanResult(url: url, snapshot: snapshot, fetchError: nil, didFetch: false)
                    } catch {
                        return ScanResult(url: url, snapshot: nil, fetchError: error.localizedDescription, didFetch: false)
                    }
                }
            }
            for _ in 0..<4 { if let url = pending.next() { enqueue(url) } }
            for await result in group {
                guard generation == currentGeneration else { group.cancelAll(); break }
                if let url = pending.next() { enqueue(url) }
                var overview = result
                if let snapshot = result.snapshot {
                    let previous = inspectionReports[snapshot.id]?.snapshot
                    if previous?.branch != snapshot.branch || previous?.upstream != snapshot.upstream
                        || previous?.remoteURL != snapshot.remoteURL {
                        let excluded = disabledChecks.union(ignoredChecks[snapshot.id] ?? [])
                        let checks = issueCatalog.checks.filter { !excluded.contains($0.id) }
                        let reusable = await Self.inspectionCache.reusableResults(for: snapshot, checks: checks)
                        guard generation == currentGeneration else { group.cancelAll(); break }
                        inspectionReports.removeValue(forKey: snapshot.id)
                        if !reusable.isEmpty {
                            overview.report = RepositoryInspectionReport(snapshot: snapshot, results: reusable.mapValues(\.result),
                                checkOrder: checks.map(\.id).filter { reusable[$0] != nil },
                                cachedChecks: Set(reusable.keys), completedAt: reusable.mapValues(\.completedAt))
                        }
                    }
                }
                apply(overview, preservingFetchState: true)
            }
        }
        guard generation == currentGeneration else { return }
        if !repositories.contains(where: { $0.id == selectedPath }) { selectedPath = repositories.first?.id }
        isScanning = false
        refreshTraffic()
    }

    private func apply(_ result: ScanResult, preservingFetchState: Bool) {
        if let folder,
           RepositoryPathBlacklist(paths: excludedRepositoryPaths, relativeTo: folder).contains(result.url) { return }
        guard var snapshot = result.snapshot else {
            repositories.removeAll { $0.id == result.url.path && $0.branch.isEmpty }
            errorMessage = "Could not read \(result.url.lastPathComponent): \(result.fetchError ?? "unknown Git error")"
            return
        }
        let index = repositories.firstIndex(where: { $0.id == snapshot.id })
        let previousRemote = index.flatMap { repositories[$0].remoteURL }
        if let index {
            if preservingFetchState {
                snapshot.fetchedAt = repositories[index].fetchedAt
                snapshot.fetchError = repositories[index].fetchError
            } else {
                snapshot.fetchedAt = result.didFetch && result.fetchError == nil
                    ? Date() : repositories[index].fetchedAt
                snapshot.fetchError = result.fetchError
            }
            repositories[index] = snapshot
        } else {
            snapshot.fetchError = result.fetchError
            snapshot.fetchedAt = result.didFetch && result.fetchError == nil ? Date() : nil
            repositories.append(snapshot)
        }
        if let report = result.report {
            let freshReport = report.updatingSnapshot(snapshot, catalog: issueCatalog)
            inspectionReports[snapshot.id] = freshReport
        }
        repositories.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if selectedPath == nil { selectedPath = repositories.first?.id }
        if snapshot.remoteURL != previousRemote, let key = GitHubRepositoryCountsQuery.key(for: snapshot.remoteURL) {
            scheduleCountsRefresh(discoveredKey: key)
        }
    }

    private nonisolated static func inspect(
        _ url: URL,
        onProgress: @escaping @Sendable (RepositoryInspectionReport) async -> Void
    ) async -> ScanResult {
        var didFetch = false
        var fetchError: String?
        do {
            var snapshot = try ScanTiming.measure("snapshot") {
                try GitRepositoryScanner.scan(url)
            }
            let catalog = RepositoryIssueCatalog()
            if snapshot.remoteURL != nil {
                didFetch = true
                do { try ScanTiming.measure("fetch") { try GitRepositoryScanner.fetch(url) } }
                catch { fetchError = error.localizedDescription }
                snapshot = try ScanTiming.measure("post-fetch snapshot") {
                    try GitRepositoryScanner.scan(url)
                }
                snapshot.fetchError = fetchError
                snapshot.fetchedAt = fetchError == nil ? Date() : nil
            }
            let disabled = Set(UserDefaults.standard.stringArray(forKey: "disabledRepositoryChecks") ?? [])
            let ignored = UserDefaults.standard.dictionary(forKey: "ignoredRepositoryChecks") as? [String: [String]] ?? [:]
            let inspectionStarted = ContinuousClock.now
            let report = await catalog.inspect(snapshot, cache: inspectionCache, forceRefresh: true,
                excludingChecks: disabled.union(ignored[snapshot.id] ?? []), onProgress: onProgress)
            ScanTiming.record("inspection", since: inspectionStarted)
            return ScanResult(url: url, snapshot: snapshot, fetchError: fetchError, didFetch: didFetch, report: report)
        } catch {
            return ScanResult(url: url, snapshot: nil, fetchError: error.localizedDescription, didFetch: didFetch)
        }
    }

    private func startDemoCheckProgress() {
        guard let repository = repositories.first else { return }
        let active = ["docs.brokenLinks", "dependencies.safeguards", "dependencies.lockfileDrift", "github.description", "files.secrets"]
        let passed = ["files.readme", "files.gitignore", "git.upstream", "git.checkoutIntegrity", "ci.coverage",
                      "ci.mutableActions", "files.projectReferences", "docs.brokenLinks"]
        let findings = issueCatalog.findings(in: repository).filter { !RepositoryIssueCatalog.activityCheckIDs.contains($0.checkID) }
        var results: [String: RepositoryCheckResult] = Dictionary(uniqueKeysWithValues: passed.map { ($0, .findings([])) })
        for (id, items) in Dictionary(grouping: findings, by: \.checkID) { results[id] = .findings(items) }
        let order = issueCatalog.checks.filter { active.contains($0.id) || results[$0.id] != nil }.map(\.id)
        let report = RepositoryInspectionReport(snapshot: repository, results: results, checkOrder: order,
            runningCheckIDs: Set(active.prefix(2)))
        inspectionReports[repository.id] = report
        checksByLoad[repository.id] = [UUID(): CheckLoad(checkIDs: Set(order), report: report)]
        loadingRepositoryIDs.insert(repository.id)
        repositoryCheckProgress[repository.id] = RepositoryCheckProgress(completed: results.count, total: order.count)
    }

    private static func demoRepositories() -> [RepositorySnapshot] {
        let names = [
            "repoman", "obsidian-agents-plugin", "sandbox-transformers", "curriculum-vitae",
            "mcp-imagetools", "parsemedicalexams", "agentbridge", "notebook2md",
            "modelarchviz", "gmail2obsidian", "papertrail", "private-homeassistant"
        ]
        let values: [(Int, Int, Int, Int, Int)] = [
            (2, 0, 3, 2, 1), (1, 2, 0, 1, 0), (0, 1, 4, 0, 0), (1, 0, 1, 0, 0),
            (3, 1, 2, 1, 1), (0, 0, 0, 0, 0), (2, 1, 1, 0, 1), (0, 1, 3, 1, 0),
            (1, 0, 2, 0, 1), (0, 0, 1, 1, 0), (1, 3, 0, 0, 2), (0, 1, 1, 0, 0)
        ]
        let commits = [
            RepositoryCommit(hash: "a3f9c2e", subject: "Add repository scanning for nested folders", relativeDate: "2 hours ago"),
            RepositoryCommit(hash: "7d1e8b4", subject: "Improve status indicators and error handling", relativeDate: "1 day ago"),
            RepositoryCommit(hash: "5c6d9a1", subject: "Refactor git service and simplify API", relativeDate: "2 days ago"),
            RepositoryCommit(hash: "9b2f4e7", subject: "Add settings window and folder chooser", relativeDate: "3 days ago"),
            RepositoryCommit(hash: "c1e0d3b", subject: "Initial commit", relativeDate: "6 days ago")
        ]
        let demoChanges = [
            WorkingTreeChange(path: "Sources/RepoScanner.swift", kind: .modified, added: 42, removed: 11),
            WorkingTreeChange(path: "Sources/StatusIndicator.swift", kind: .modified, added: 18, removed: 5),
            WorkingTreeChange(path: "README.draft.md", kind: .untracked, added: 27, removed: nil)
        ]
        return zip(names, values).map { name, value in
            RepositorySnapshot(
                url: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("repos/tsilva/\(name)"),
                name: name,
                branch: name == "mcp-imagetools" ? "develop" : "main",
                upstream: "origin/main",
                remoteURL: "git@github.com:tsilva/\(name).git",
                ahead: value.0,
                behind: value.1,
                changes: name == "repoman" ? demoChanges : (0..<value.2).map {
                    WorkingTreeChange(path: "Changed-\($0 + 1).swift", kind: .modified, added: nil, removed: nil)
                },
                staleBranches: (0..<value.3).map { "old-branch-\($0 + 1)" },
                worktrees: (0..<value.4).map { "worktree-\($0 + 1)" },
                commits: name == "repoman" ? commits : [],
                checkedAt: Date(),
                fetchedAt: Date(),
                rootFiles: name == "repoman" ? ["Package.swift", "README.md"] : (name == "notebook2md" ? ["pyproject.toml"] : ["package.json", "LICENSE"])
            )
        }
    }
}

private enum ScanTiming {
    private static let logger = Logger(subsystem: "com.tsilva.repoman", category: "Scanning")
    @TaskLocal static var observer: (@Sendable (String, Duration) -> Void)?

    static func measure<T>(_ phase: String, work: () throws -> T) rethrows -> T {
        let started = ContinuousClock.now
        defer { record(phase, since: started) }
        return try work()
    }

    static func record(_ phase: String, since started: ContinuousClock.Instant) {
        let elapsed = started.duration(to: .now)
        observer?(phase, elapsed)
        let parts = elapsed.components
        let milliseconds = Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
        logger.debug("\(phase, privacy: .public) took \(milliseconds, format: .fixed(precision: 2), privacy: .public) ms")
    }
}

private struct ScanResult: Sendable {
    let url: URL
    let snapshot: RepositorySnapshot?
    let fetchError: String?
    let didFetch: Bool
    var report: RepositoryInspectionReport? = nil
}

struct RepositoryCheckListItem: Identifiable {
    let repository: RepositorySnapshot
    let check: RepositoryCheck
    let status: RepositoryCheckStatus
    var id: String { repository.id + "::" + check.id }
    var title: String {
        switch check.id {
        case "git.staleBranches": return "Stale branches"
        case "git.worktrees": return "Linked worktrees"
        case "git.unpublishedBranches": return "Unpublished branch work"
        case "git.upstream": return "Upstream branch"
        case "git.checkoutIntegrity": return "Submodule and LFS checkout"
        case "git.oldStashes": return "Old stashes"
        case "git.unfinishedOperation": return "Git operation status"
        case "files.readme": return "README file"
        case "files.gitignore": return "Git ignore file"
        case "files.license": return "License file"
        case "files.secrets": return "Exposed secrets"
        case "files.oversized": return "Tracked file sizes"
        case "files.mergeMarkers": return "Merge markers"
        case "files.generatedTracked": return "Tracked generated files"
        case "files.projectReferences": return "Project references"
        case "docs.brokenLinks": return "Local documentation links"
        case "ci.failing": return "CI status"
        case "ci.coverage": return "CI coverage"
        case "ci.mutableActions": return "Actions reference pinning"
        case "ci.suppressedFailures": return "Validation failure handling"
        case "ci.security": return "Actions workflow security"
        case "dependencies.manager": return "Package-manager consistency"
        case "dependencies.safeguards": return "Dependency safeguards"
        case "dependencies.lockfile": return "Tracked lockfiles"
        case "dependencies.sources": return "Dependency sources"
        case "dependencies.runtime": return "Runtime version consistency"
        case "dependencies.lockfileDrift": return "Manifest and lockfile consistency"
        case "github.description": return "Repository description"
        case "inspection.remote": return "Remote availability"
        case "inspection.comparison": return "Upstream comparison"
        case "inspection.files": return "Repository file inspection"
        default: return check.title
        }
    }
}

struct RepositoryCheckProgress: Equatable {
    let completed: Int
    let total: Int
    var remaining: Int { max(0, total - completed) }
    var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
    var percentage: Int {
        guard total > 0 else { return 0 }
        let completed = min(total, max(0, completed))
        return Int((Double(completed) * 100 / Double(total)).rounded(.down))
    }
}
