import AppKit
import SwiftUI

@MainActor
final class AppUpdateController: ObservableObject {
    static let shared = AppUpdateController()
    @Published private(set) var available: AppUpdateCandidate?
    @Published private(set) var isChecking = false
    @Published private(set) var phase: String?
    @Published private(set) var status = "Checks GitHub for new versions automatically."
    @Published var errorMessage: String?
    var prepareToQuit: (() throws -> Void)?
    var resumeAfterCancelledQuit: (() -> Void)?
    private let client = AppUpdateClient()
    private var schedule: Task<Void, Never>?
    private var lastCheck = Date.distantPast
    private var helper: Process?

    var isInstalling: Bool { phase != nil }
    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }
    var installationUnavailableReason: String? {
        if ProcessInfo.processInfo.arguments.contains("--demo") { return "Updates cannot be installed in demo mode." }
        #if DEBUG
        return "Updates can be installed in the downloaded app; development builds stay managed by Xcode."
        #else
        return nil
        #endif
    }
    static var errorFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RepoMan/update-error.txt")
    }

    func start() {
        guard schedule == nil, !ProcessInfo.processInfo.arguments.contains("--demo") else { return }
        if let previousError = try? String(contentsOf: Self.errorFile, encoding: .utf8) {
            errorMessage = previousError
            try? FileManager.default.removeItem(at: Self.errorFile)
        }
        schedule = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                do { try await Task.sleep(for: .seconds(6 * 60 * 60)) } catch { return }
            }
        }
    }

    func check(manually: Bool = false) async {
        guard !isChecking, !isInstalling,
              manually || Date().timeIntervalSince(lastCheck) >= 60 * 60 else { return }
        isChecking = true
        defer { isChecking = false }
        lastCheck = Date()
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        do {
            available = try await client.check(installed: version, architecture: architecture)
            status = available.map { "Version \($0.version) is available." } ?? "RepoMan is up to date."
        } catch {
            // Preserve an already discovered update through transient network failures.
            status = "Couldn’t check for updates. Try again later."
            if manually { errorMessage = error.localizedDescription }
        }
    }

    func install() {
        guard let update = available, !isInstalling else { return }
        if let reason = installationUnavailableReason { errorMessage = reason; return }
        phase = "Downloading update…"
        Task { [self] in
            var workspace: URL?
            var plan: AppUpdateInstaller.Plan?
            do {
                let work = try AppUpdateInstaller.workspace()
                workspace = work
                let dmg = try await client.download(update, to: work)
                phase = "Preparing update…"
                let target = Bundle.main.bundleURL
                let errorFile = Self.errorFile
                let prepared = try await Task.detached(priority: .utility) {
                    try AppUpdateInstaller.prepare(dmg: dmg, version: update.version, target: target,
                                                   workspace: work, errorFile: errorFile)
                }.value
                plan = prepared
                guard let prepareToQuit else { throw AppUpdateError.message("RepoMan is still starting. Try again shortly.") }
                // This rechecks running work and flushes conversations immediately before handing off.
                try prepareToQuit()
                phase = "Installing and restarting…"
                let process = try AppUpdateInstaller.launch(prepared, parentPID: ProcessInfo.processInfo.processIdentifier)
                helper = process
                process.terminationHandler = { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        self.helper = nil
                        self.phase = nil
                        self.resumeAfterCancelledQuit?()
                        self.errorMessage = "The update was cancelled because RepoMan did not quit. Try again."
                    }
                }
                NSApplication.shared.terminate(nil)
            } catch {
                plan?.discard()
                if let workspace { try? FileManager.default.removeItem(at: workspace) }
                resumeAfterCancelledQuit?()
                phase = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    /// The installer keeps the backup until the replacement has finished launching.
    static func acknowledgeRelaunch() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--repoman-update-complete"), arguments.indices.contains(index + 1) else { return }
        let workspace = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL.resolvingSymlinksInPath()
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard workspace.deletingLastPathComponent() == temporary,
              workspace.lastPathComponent.hasPrefix("RepoMan-update-"),
              FileManager.default.fileExists(atPath: workspace.appendingPathComponent("install.sh").path) else { return }
        try? Data().write(to: workspace.appendingPathComponent("launched"), options: .atomic)
    }
}

struct AppUpdateButton: View {
    @ObservedObject private var updater = AppUpdateController.shared
    @EnvironmentObject private var store: RepositoryStore

    var body: some View {
        if let update = updater.available {
            Button { updater.install() } label: {
                Group {
                    if updater.isInstalling { ProgressView().controlSize(.small).tint(.white) }
                    else { Image(systemName: "arrow.down.to.line").font(.system(size: 16, weight: .semibold)) }
                }
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color.blue, in: Circle())
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(updater.isInstalling || store.updateUnavailableReason != nil || updater.installationUnavailableReason != nil)
            .help(updater.phase ?? store.updateUnavailableReason ?? updater.installationUnavailableReason ?? "Install RepoMan \(update.version) and restart")
            .accessibilityLabel("Update RepoMan to version \(update.version) and restart")
            .accessibilityValue(updater.phase ?? "Update available")
            .accessibilityIdentifier("app-update-button")
        }
    }
}

struct AppUpdateStatusView: View {
    @ObservedObject private var updater = AppUpdateController.shared
    @EnvironmentObject private var store: RepositoryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("RepoMan \(updater.version)").font(.system(size: 13, weight: .medium))
                    Text(updater.phase ?? updater.status).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                if updater.available != nil {
                    Button("Update & Restart") { updater.install() }
                        .disabled(updater.isInstalling || store.updateUnavailableReason != nil || updater.installationUnavailableReason != nil)
                }
                Button(updater.isChecking ? "Checking…" : "Check for Updates") {
                    Task { await updater.check(manually: true) }
                }
                .disabled(updater.isChecking || updater.isInstalling)
            }
            if updater.available != nil, let reason = store.updateUnavailableReason ?? updater.installationUnavailableReason {
                Text(reason).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
        }
    }
}
