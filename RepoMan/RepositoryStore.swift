import AppKit
import Combine
import Foundation

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
    private var scheduledInspectionTask: Task<Void, Never>?
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
        issues(in: repository).filter { !$0.isIncomplete }.map(\.finding)
    }

    func issues(in repository: RepositorySnapshot) -> [RepositoryIssueListItem] {
        guard !repository.branch.isEmpty else { return [] }
        let disabled = disabledChecks.union(ignoredChecks[repository.id] ?? []).union(RepositoryIssueCatalog.activityCheckIDs)
        let findings = inspectionReports[repository.id]?.findings(disabledChecks: disabled)
            ?? issueCatalog.findings(in: repository, disabledChecks: disabled)
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
        Task { await scanFolder(folder, fetchRemotes: false, clearFirst: false) }
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
            selectedPath = repositories.first?.id
            if ProcessInfo.processInfo.arguments.contains("--check-progress") { startDemoCheckProgress() }
            return
        }
        scheduledInspectionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                guard let self, let folder = self.folder, !self.isScanning, !self.isFetching, !self.isQuittingForUpdate else { continue }
                await self.scanFolder(folder, fetchRemotes: true, clearFirst: false, dueOnly: true)
            }
        }
        if let savedPath = UserDefaults.standard.string(forKey: "monitoredFolder"),
           FileManager.default.fileExists(atPath: savedPath) {
            let savedFolder = URL(fileURLWithPath: savedPath, isDirectory: true)
            folder = savedFolder
            selectedPath = UserDefaults.standard.string(forKey: "selectedRepoPath")
            // Startup restores valid checker results and only runs missing or expired checks.
            Task { await scanFolder(savedFolder, fetchRemotes: true, clearFirst: true) }
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
            Task { await scanFolder(url, fetchRemotes: true, clearFirst: true) }
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

    func refreshAll() {
        guard let folder, !isDemo, !isScanning, !isFetching, !isQuittingForUpdate else { return }
        Task { await scanFolder(folder, fetchRemotes: true, clearFirst: false, forceRefresh: true) }
    }

    func refreshSelected() {
        guard let selectedRepository, !isDemo, !isFetching, !isScanning, !isQuittingForUpdate else { return }
        let currentGeneration = generation
        isFetching = true
        let loadingToken = beginLoading([selectedRepository.url])
        let onProgress = progressHandler(generation: currentGeneration, token: loadingToken, preservingFetchState: false,
                                         didFetch: selectedRepository.remoteURL != nil)
        Task {
            defer { endLoading(selectedRepository.url, token: loadingToken) }
            let result: ScanResult
            result = await Task.detached(priority: .utility) {
                await Self.scan(selectedRepository.url, includeDetails: true,
                                fetchRemotes: true, forceRefresh: true, onProgress: onProgress)
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

    private func endLoading(token: UUID) {
        for path in Array(repositoryLoads.keys) { endLoading(URL(fileURLWithPath: path), token: token) }
    }

    private func scanFolder(_ url: URL, fetchRemotes: Bool, clearFirst: Bool,
                            forceRefresh: Bool = false, dueOnly: Bool = false) async {
        guard !isScanning else { return }
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
        let loadingToken = beginLoading(dueOnly ? [] : repositories.map(\.url))
        defer { endLoading(token: loadingToken) }

        let exclusions = excludedRepositoryPaths
        let discovery = await Task.detached(priority: .utility) {
            Result { try GitRepositoryScanner.repositories(in: url, excludingPaths: exclusions) }
        }.value
        guard generation == currentGeneration else { return }
        let urls: [URL]
        switch discovery {
        case .success(let found):
            urls = dueOnly ? found.filter { path in
                guard let report = inspectionReports[path.path] else { return true }
                let excluded = disabledChecks.union(ignoredChecks[path.path] ?? [])
                return issueCatalog.checks.contains { !excluded.contains($0.id) && $0.isDue(result: report.results[$0.id], completedAt: report.completedAt[$0.id]) }
            } : found
        case .failure(let error):
            errorMessage = error.localizedDescription
            isScanning = false
            return
        }

        let paths = Set(urls.map(\.path))
        if !dueOnly { repositories.removeAll { !paths.contains($0.url.path) } }
        if urls.isEmpty {
            if !dueOnly { selectedPath = nil }
            isScanning = false
            return
        }

        beginLoading(urls, token: loadingToken)
        let existing = Set(repositories.map(\.id))
        repositories += urls.filter { !existing.contains($0.path) }.map { repoURL in
            RepositorySnapshot(url: repoURL, name: repoURL.lastPathComponent, branch: "", upstream: nil, remoteURL: nil,
                ahead: nil, behind: nil, changes: [], staleBranches: [], worktrees: [], commits: [], detailsLoaded: false)
        }
        repositories.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if selectedPath == nil { selectedPath = repositories.first?.id }
        let onProgress = progressHandler(generation: currentGeneration, token: loadingToken, preservingFetchState: true)
        await withTaskGroup(of: ScanResult.self) { group in
            var pending = urls.makeIterator()
            @MainActor func enqueue(_ repoURL: URL) {
                let selected = selectedPath
                group.addTask(priority: .utility) {
                    await Self.scan(repoURL, includeDetails: repoURL.path == selected,
                                    fetchRemotes: fetchRemotes, forceRefresh: forceRefresh,
                                    onProgress: onProgress)
                }
            }
            for _ in 0..<4 { if let repoURL = pending.next() { enqueue(repoURL) } }
            for await result in group {
                guard generation == currentGeneration else { group.cancelAll(); continue }
                if let repoURL = pending.next() { enqueue(repoURL) }
                apply(result, preservingFetchState: !result.didFetch)
                endLoading(result.url, token: loadingToken)
            }
        }
        guard generation == currentGeneration else { return }
        if selectedPath == nil || !repositories.contains(where: { $0.id == selectedPath }) {
            selectedPath = repositories.first?.id
        }
        isScanning = false
        if let error = await Self.inspectionCache.persistenceError { errorMessage = error }
    }

    private func apply(_ result: ScanResult, preservingFetchState: Bool) {
        if let folder,
           RepositoryPathBlacklist(paths: excludedRepositoryPaths, relativeTo: folder).contains(result.url) { return }
        guard var snapshot = result.snapshot else {
            repositories.removeAll { $0.id == result.url.path && $0.branch.isEmpty }
            errorMessage = "Could not read \(result.url.lastPathComponent): \(result.fetchError ?? "unknown Git error")"
            return
        }
        if let index = repositories.firstIndex(where: { $0.id == snapshot.id }) {
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
    }

    private nonisolated static func scan(
        _ url: URL, includeDetails: Bool,
        fetchRemotes: Bool = false, forceRefresh: Bool = false,
        onProgress: (@Sendable (RepositoryInspectionReport) async -> Void)? = nil
    ) async -> ScanResult {
        var didFetch = false
        var fetchError: String?
        do {
            var snapshot = try GitRepositoryScanner.scan(url, includeDetails: includeDetails)
            let catalog = RepositoryIssueCatalog()
            let remoteChecks = catalog.checks.filter { ["git.pull", "git.push", "git.diverged", "inspection.remote"].contains($0.id) }
            let reusable = await inspectionCache.reusableResults(for: snapshot, checks: remoteChecks)
            if fetchRemotes, snapshot.remoteURL != nil, forceRefresh || reusable.count < remoteChecks.count {
                didFetch = true
                do { try GitRepositoryScanner.fetch(url) }
                catch { fetchError = error.localizedDescription }
                snapshot = try GitRepositoryScanner.scan(url, includeDetails: includeDetails)
                snapshot.fetchError = fetchError
                snapshot.fetchedAt = fetchError == nil ? Date() : nil
            }
            // Scheduling owns freshness; even forced checks bypass underlying metadata caches.
            let disabled = Set(UserDefaults.standard.stringArray(forKey: "disabledRepositoryChecks") ?? [])
            let ignored = UserDefaults.standard.dictionary(forKey: "ignoredRepositoryChecks") as? [String: [String]] ?? [:]
            let report = await catalog.inspect(snapshot, cache: inspectionCache, forceRefresh: forceRefresh,
                excludingChecks: disabled.union(ignored[snapshot.id] ?? []), onProgress: onProgress)
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
