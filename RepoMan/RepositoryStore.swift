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
    @Published private(set) var scanProgress = ""
    @Published private(set) var errorMessage: String?

    private var started = false
    private var generation = UUID()
    private var monitoringTask: Task<Void, Never>?
    private var lastRemoteRefresh: Date?
    private let isDemo = ProcessInfo.processInfo.arguments.contains("--demo")

    var selectedRepository: RepositorySnapshot? {
        repositories.first { $0.id == selectedPath }
    }

    func start() {
        guard !started else { return }
        started = true
        if isDemo {
            folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("repos/tsilva")
            repositories = Self.demoRepositories()
            selectedPath = repositories.first?.id
            return
        }
        if let savedPath = UserDefaults.standard.string(forKey: "monitoredFolder"),
           FileManager.default.fileExists(atPath: savedPath) {
            let savedFolder = URL(fileURLWithPath: savedPath, isDirectory: true)
            folder = savedFolder
            selectedPath = UserDefaults.standard.string(forKey: "selectedRepoPath")
            Task { await scanFolder(savedFolder, fetchRemotes: true, clearFirst: true) }
        }
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                guard let self else { break }
                guard !Task.isCancelled, let folder = self.folder else { continue }
                guard !self.isScanning, !self.isFetching else { continue }
                await self.scanFolder(folder, fetchRemotes: false, clearFirst: false)
                if let lastRemoteRefresh = self.lastRemoteRefresh,
                   Date().timeIntervalSince(lastRemoteRefresh) >= 600 {
                    await self.fetchAllRemotes()
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
            generation = UUID()
            isScanning = false
            isFetching = false
            folder = url
            UserDefaults.standard.set(url.path, forKey: "monitoredFolder")
            selectedPath = nil
            UserDefaults.standard.removeObject(forKey: "selectedRepoPath")
            Task { await scanFolder(url, fetchRemotes: true, clearFirst: true) }
        }
    }

    func select(_ repository: RepositorySnapshot) {
        selectedPath = repository.id
        UserDefaults.standard.set(repository.id, forKey: "selectedRepoPath")
        if !repository.detailsLoaded, !isDemo {
            let currentGeneration = generation
            Task { await loadDetails(repository.url, generation: currentGeneration) }
        }
    }

    func refreshAll() {
        guard let folder, !isDemo else { return }
        Task { await scanFolder(folder, fetchRemotes: true, clearFirst: false) }
    }

    func refreshSelected() {
        guard let selectedRepository, !isDemo, !isFetching, !isScanning else { return }
        let currentGeneration = generation
        isFetching = true
        Task {
            let result: ScanResult
            if selectedRepository.upstream == nil {
                result = await Task.detached(priority: .utility) {
                    Self.scan(selectedRepository.url, includeDetails: true)
                }.value
            } else {
                result = await Self.fetchAndScan(selectedRepository.url, includeDetails: true)
            }
            guard generation == currentGeneration else { return }
            apply(result, preservingFetchState: false)
            isFetching = false
        }
    }

    private func scanFolder(_ url: URL, fetchRemotes: Bool, clearFirst: Bool) async {
        guard !isScanning else { return }
        generation = UUID()
        let currentGeneration = generation
        isScanning = true
        errorMessage = nil
        if clearFirst { repositories = [] }

        let discovery = await Task.detached(priority: .utility) {
            Result { try GitRepositoryScanner.repositories(in: url) }
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
        repositories.removeAll { !paths.contains($0.url.path) }
        if urls.isEmpty {
            selectedPath = nil
            isScanning = false
            scanProgress = ""
            return
        }

        var completed = 0
        for batch in urls.batches(of: 4) {
            let selected = selectedPath
            let results = await withTaskGroup(of: ScanResult.self) { group in
                for repoURL in batch {
                    group.addTask(priority: .utility) {
                        Self.scan(repoURL, includeDetails: repoURL.path == selected)
                    }
                }
                var values: [ScanResult] = []
                for await value in group { values.append(value) }
                return values
            }
            guard generation == currentGeneration else { return }
            for result in results { apply(result, preservingFetchState: true) }
            completed += results.count
            scanProgress = "Scanning \(completed) of \(urls.count)"
        }
        if selectedPath == nil || !repositories.contains(where: { $0.id == selectedPath }) {
            selectedPath = repositories.first?.id
        }
        isScanning = false
        scanProgress = ""
        if let selected = selectedRepository, !selected.detailsLoaded {
            await loadDetails(selected.url, generation: currentGeneration)
        }
        if fetchRemotes { await fetchAllRemotes() }
    }

    private func fetchAllRemotes() async {
        guard !isFetching, !isDemo else { return }
        let currentGeneration = generation
        isFetching = true
        for batch in repositories.filter({ $0.upstream != nil }).map(\.url).batches(of: 4) {
            let selected = selectedPath
            let results = await withTaskGroup(of: ScanResult.self) { group in
                for repoURL in batch {
                    group.addTask(priority: .utility) {
                        await Self.fetchAndScan(repoURL, includeDetails: repoURL.path == selected)
                    }
                }
                var values: [ScanResult] = []
                for await value in group { values.append(value) }
                return values
            }
            guard generation == currentGeneration else { return }
            for result in results { apply(result, preservingFetchState: false) }
        }
        lastRemoteRefresh = Date()
        isFetching = false
        if let selected = selectedRepository, !selected.detailsLoaded {
            await loadDetails(selected.url, generation: currentGeneration)
        }
    }

    private func loadDetails(_ url: URL, generation currentGeneration: UUID) async {
        let result = await Task.detached(priority: .utility) {
            Self.scan(url, includeDetails: true)
        }.value
        guard generation == currentGeneration, selectedPath == url.path else { return }
        apply(result, preservingFetchState: true)
    }

    private func apply(_ result: ScanResult, preservingFetchState: Bool) {
        guard var snapshot = result.snapshot else {
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
        repositories.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if selectedPath == nil { selectedPath = repositories.first?.id }
    }

    private nonisolated static func scan(_ url: URL, includeDetails: Bool) -> ScanResult {
        do {
            return ScanResult(url: url, snapshot: try GitRepositoryScanner.scan(url, includeDetails: includeDetails), fetchError: nil, didFetch: false)
        } catch {
            return ScanResult(url: url, snapshot: nil, fetchError: error.localizedDescription, didFetch: false)
        }
    }

    private nonisolated static func fetchAndScan(_ url: URL, includeDetails: Bool) async -> ScanResult {
        let fetchError: String?
        do {
            try GitRepositoryScanner.fetch(url)
            fetchError = nil
        } catch {
            fetchError = error.localizedDescription
        }
        do {
            return ScanResult(url: url, snapshot: try GitRepositoryScanner.scan(url, includeDetails: includeDetails), fetchError: fetchError, didFetch: true)
        } catch {
            return ScanResult(url: url, snapshot: nil, fetchError: fetchError ?? error.localizedDescription, didFetch: true)
        }
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
                fetchedAt: Date()
            )
        }
    }
}

private struct ScanResult: Sendable {
    let url: URL
    let snapshot: RepositorySnapshot?
    let fetchError: String?
    let didFetch: Bool
}

private extension Array {
    func batches(of size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { index in
            Array(self[index..<Swift.min(index + size, count)])
        }
    }
}
