import SwiftUI

enum RepositorySyncState {
    case running(RepositorySyncPhase), succeeded(RepositorySyncResult), failed(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

struct RepositorySyncResult {
    let snapshot: RepositorySnapshot
    let committedFileCount: Int
    let message: String

    var hasRemainingWork: Bool {
        !snapshot.changes.isEmpty || (snapshot.ahead ?? 0) > 0 || (snapshot.behind ?? 0) > 0
    }
}

struct RepositoryGitStatus: View {
    let repository: RepositorySnapshot

    var body: some View {
        HStack(spacing: 8) {
            if let count = repository.behind, count > 0 { countLabel("↓", count, color: Theme.blue, title: "commits to pull") }
            if let count = repository.ahead, count > 0 { countLabel("↑", count, color: Theme.blue, title: "commits to push") }
            if repository.changedFileCount > 0 { countLabel("●", repository.changedFileCount, color: Theme.amber, title: "changed files") }
        }
        .font(.system(size: 11)).monospacedDigit().fixedSize()
    }

    private func countLabel(_ symbol: String, _ count: Int, color: Color, title: String) -> some View {
        HStack(spacing: 3) {
            Text(symbol).foregroundStyle(color)
            Text(count.formatted()).foregroundStyle(Theme.secondary)
        }
        .help("\(count) \(title)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) \(title)")
    }
}

struct RepositorySyncButton: View {
    @EnvironmentObject private var store: RepositoryStore
    let repository: RepositorySnapshot
    let showDiff: () -> Void
    @State private var isPresented = false
    @State private var isReviewing = false
    @State private var isDirectSync = false
    @State private var syncError: String?
    @State private var reviewTask: Task<Void, Never>?

    private var state: RepositorySyncState? { store.syncStates[repository.id] }

    private var title: String {
        if isReviewing { return "Checking…" }
        if isDirectSync {
            if case .running(let phase) = state { return phase.rawValue }
            if case .succeeded = state { return "Synced" }
        }
        return "Sync repository"
    }

    var body: some View {
        ToolbarActionButton(
            symbol: "arrow.up.arrow.down",
            title: title,
            isLoading: isReviewing || state?.isRunning == true,
            foregroundColor: Theme.primary,
            action: sync
        )
        .accessibilityLabel("Sync repository")
        .accessibilityIdentifier("repository-sync-button")
        .disabled(isReviewing || state?.isRunning == true)
        .onChange(of: state?.isRunning) { _, running in
            if isDirectSync, running != true, case .failed(let error) = state {
                syncError = error
            }
        }
        .onChange(of: repository.id) { _, _ in
            reviewTask?.cancel()
            isDirectSync = false
        }
        .onDisappear { reviewTask?.cancel() }
        .alert("Sync failed", isPresented: Binding(
            get: { syncError != nil },
            set: { if !$0 { syncError = nil } }
        )) {
            Button("OK", role: .cancel) { syncError = nil }
        } message: {
            Text(syncError ?? "")
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            RepositorySyncPopover(repository: repository) {
                isPresented = false
                showDiff()
            } dismiss: {
                isPresented = false
            }.environmentObject(store)
        }
    }

    private func sync() {
        guard !isReviewing, state?.isRunning != true else { return }
        isDirectSync = false
        if !repository.changes.isEmpty || store.isDemo {
            isPresented = true
            return
        }
        if let reason = store.syncUnavailableReason(for: repository) {
            syncError = reason
            return
        }
        // Check fresh Git status before bypassing the file and commit review.
        let repositoryID = repository.id
        let directory = repository.url
        isReviewing = true
        store.clearSyncResult(for: repositoryID)
        reviewTask = Task { @MainActor in
            defer { isReviewing = false; reviewTask = nil }
            let result = await Task.detached(priority: .userInitiated) {
                Result { try RepositorySync.review(at: directory) }
            }.value
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let review):
                if review.snapshot.changes.isEmpty {
                    isDirectSync = true
                    store.synchronize(review, selectedPaths: [], message: "")
                    if case .failed(let error) = state { syncError = error }
                } else {
                    isPresented = true
                }
            case .failure(let error):
                syncError = error.localizedDescription
            }
        }
    }
}

private struct RepositorySyncPopover: View {
    @EnvironmentObject private var store: RepositoryStore
    let repository: RepositorySnapshot
    let showDiff: () -> Void
    let dismiss: () -> Void
    @State private var review: RepositorySyncReview?
    @State private var error: String?
    @State private var loading = true
    @State private var selectedPaths: Set<String> = []
    @State private var message = ""
    @State private var expanded = false
    @State private var generationTask: Task<Void, Never>?
    @State private var generationID: UUID?
    @State private var generationError: String?

    private var isGenerating: Bool { generationID != nil }

    private var snapshot: RepositorySnapshot {
        if case .succeeded(let result) = state { return result.snapshot }
        return review?.snapshot ?? repository
    }
    private var state: RepositorySyncState? { store.syncStates[repository.id] }
    private var actionTitle: String {
        if case .running(let phase) = state { return phase.rawValue }
        return selectedPaths.isEmpty ? "Sync" : "Commit & Sync"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                Text(snapshot.branch).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                RepositoryGitStatus(repository: snapshot)
            }
            .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            .help("\(snapshot.branch) → \(snapshot.upstream ?? "No upstream")")

            if case .succeeded(let result) = state {
                RepositorySyncCompletionView(result: result, dismiss: dismiss) {
                    Task { await loadReview(clearDraft: true) }
                }
            } else {
                reviewForm
            }
        }
        .padding(12).frame(width: 280)
        .task { await loadReview() }
        .onDisappear { generationID = nil; generationTask?.cancel(); generationTask = nil }
    }

    @ViewBuilder private var reviewForm: some View {
        if loading {
            ProgressView("Reviewing changes…").controlSize(.small)
        } else if !snapshot.changes.isEmpty {
            HStack {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9))
                        Text("\(selectedPaths.count) files selected")
                    }
                }.buttonStyle(.plain)
                Spacer()
                Button("View diff", action: showDiff).buttonStyle(.link)
            }.font(.system(size: 12))
            if expanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Select all", isOn: Binding(
                            get: { selectedPaths.count == snapshot.changes.count },
                            set: { selectedPaths = $0 ? Set(snapshot.changes.map(\.path)) : [] }
                        ))
                        ForEach(snapshot.changes, id: \.path) { change in
                            Toggle(isOn: Binding(
                                get: { selectedPaths.contains(change.path) },
                                set: { if $0 { selectedPaths.insert(change.path) } else { selectedPaths.remove(change.path) } }
                            )) {
                                Text(change.path).lineLimit(1).truncationMode(.middle).help(change.path)
                            }
                        }
                    }.font(.system(size: 11)).toggleStyle(.checkbox)
                }.frame(height: min(180, CGFloat(snapshot.changes.count + 1) * 22))
                .disabled(state?.isRunning == true || isGenerating)
            }
            if !selectedPaths.isEmpty {
                RepositoryCommitMessageEditor(message: $message, isGenerating: isGenerating,
                    isEditable: state?.isRunning != true && !isGenerating,
                    canGenerate: (review != nil || store.isDemo) && !loading && state?.isRunning != true && !isFinished,
                    generate: generateMessage)
            }
        }

        if let error { statusText(error, color: Theme.red) }
        if let generationError { statusText(generationError, color: Theme.red) }
        if case .failed(let failure) = state {
            statusText(failure, color: Theme.red)
            Button("Review again") { Task { await loadReview() } }.buttonStyle(.link)
        } else if let reason = store.syncUnavailableReason(for: repository), state?.isRunning != true {
            statusText(reason, color: Theme.secondary)
        }

        Button {
            if let review { store.synchronize(review, selectedPaths: selectedPaths, message: message) }
        } label: {
            Text(actionTitle).frame(maxWidth: .infinity).padding(.vertical, 3)
        }
        .buttonStyle(RepositorySyncActionStyle())
        .disabled(loading || review == nil || store.syncUnavailableReason(for: repository) != nil ||
                  (!selectedPaths.isEmpty && message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ||
                  state?.isRunning == true || isGenerating || isFinished)
    }

    private var isFinished: Bool {
        switch state { case .succeeded, .failed: return true; default: return false }
    }

    private func statusText(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }

    @MainActor private func loadReview(clearDraft: Bool = false) async {
        guard state?.isRunning != true else { loading = false; return }
        store.clearSyncResult(for: repository.id)
        loading = true
        error = nil
        generationError = nil
        if clearDraft { message = "" }
        selectedPaths = []
        expanded = false
        review = nil
        if store.isDemo {
            selectedPaths = Set(repository.changes.map(\.path))
            loading = false
            if message.isEmpty { generateMessage() }
            return
        }
        let directory = repository.url
        let result = await Task.detached(priority: .userInitiated) {
            Result { try RepositorySync.review(at: directory) }
        }.value
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let fresh): review = fresh; selectedPaths = Set(fresh.snapshot.changes.map(\.path))
        case .failure(let failure): review = nil; error = failure.localizedDescription
        }
        loading = false
        if review != nil, message.isEmpty { generateMessage() }
    }

    @MainActor private func generateMessage() {
        guard !isGenerating, !selectedPaths.isEmpty else { return }
        generationError = nil
        let selection = selectedPaths
        let operation = UUID()
        generationID = operation
        generationTask = Task {
            defer {
                if generationID == operation { generationTask = nil; generationID = nil }
            }
            do {
                let draft: String
                if store.isDemo {
                    draft = "Add Git sync controls\n\nShow repository Git activity and let users review selected changes before syncing."
                } else {
                    guard let review else { throw RepairError.blocked("Reopen Sync to review the latest changes.") }
                    let context = try await Task.detached(priority: .userInitiated) {
                        try RepositorySync.commitMessageContext(review, selectedPaths: selection)
                    }.value
                    try Task.checkCancellation()
                    draft = try await CodexCommitMessageGenerator().generate(context: context)
                }
                try Task.checkCancellation()
                guard generationID == operation, selectedPaths == selection else { return }
                message = draft
            } catch is CancellationError {
                // Closing the popup cancels generation without changing the current draft.
            } catch {
                if !Task.isCancelled, generationID == operation { generationError = error.localizedDescription }
            }
        }
    }
}

/// Replace the commit form with a receipt using the status returned by Git.
struct RepositorySyncCompletionView: View {
    let result: RepositorySyncResult
    let dismiss: () -> Void
    let reviewAgain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22)).foregroundStyle(Theme.green)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Synced").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.primary)
                    Text(remoteStatus)
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityIdentifier("repository-sync-completed")

            if result.committedFileCount > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(result.committedFileCount) \(result.committedFileCount == 1 ? "file" : "files") committed")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    Text(result.message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.primary)
                        .lineLimit(3).help(result.message)
                }
                .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.control, in: RoundedRectangle(cornerRadius: 8))
            }

            if !result.snapshot.changes.isEmpty {
                Label("\(result.snapshot.changedFileCount) local \(result.snapshot.changedFileCount == 1 ? "change remains" : "changes remain")",
                      systemImage: "doc")
                    .font(.system(size: 11)).foregroundStyle(Theme.amber)
            }

            if result.hasRemainingWork {
                Button(result.snapshot.changes.isEmpty ? "Review again" : "Review remaining changes", action: reviewAgain)
                    .buttonStyle(.link).font(.system(size: 12))
                    .accessibilityIdentifier("repository-sync-review-remaining")
            }
            Button(action: dismiss) {
                Text("Done").frame(maxWidth: .infinity).padding(.vertical, 3)
            }
            .buttonStyle(RepositorySyncActionStyle())
            .accessibilityIdentifier("repository-sync-done")
        }
    }

    private var remoteStatus: String {
        if result.snapshot.ahead == 0, result.snapshot.behind == 0,
           let upstream = result.snapshot.upstream {
            return "Up to date with \(upstream)"
        }
        return "Remote sync completed"
    }
}

/// A compact multiline message editor, using the same native sizing as the repair composer.
struct RepositoryCommitMessageEditor: View {
    @Binding var message: String
    let isGenerating: Bool
    let isEditable: Bool
    let canGenerate: Bool
    let generate: () -> Void
    @State private var editorHeight: CGFloat = 24

    var body: some View {
        HStack(alignment: .top, spacing: 2) {
            CodexScrollView {
                CodexTextEditor(text: isGenerating ? .constant("") : $message,
                                accessibilityLabel: "Commit message", onSubmit: {},
                                submitsOnReturn: false, isEditable: isEditable && !isGenerating)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        if height > 0, abs(height - editorHeight) > 0.5 { editorHeight = height }
                    }
            }
            .frame(height: min(160, max(24, editorHeight)))
            .overlay(alignment: .topLeading) {
                if isGenerating || message.isEmpty {
                    Text(isGenerating ? "Generating commit message..." : "Describe your changes")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        .padding(.leading, 9).padding(.top, 4).allowsHitTesting(false)
                }
            }
            Group {
                if isGenerating {
                    ProgressView().controlSize(.mini)
                        .accessibilityLabel("Generating commit message")
                        .accessibilityIdentifier("commit-message-generation-progress")
                } else {
                    Button(action: generate) {
                        Image(systemName: "wand.and.stars").font(.system(size: 12))
                            .frame(width: 24, height: 24)
                            .contentShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.secondary)
                    .disabled(!canGenerate)
                    .help("Generate commit message with Codex (GPT-6.1 Sol, low reasoning)")
                    .accessibilityLabel("Generate commit message")
                    .accessibilityIdentifier("generate-commit-message-button")
                }
            }
            .frame(width: 24, height: 24)
        }
        .padding(4)
        .background(Theme.control, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
    }
}

private struct RepositorySyncActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.primary)
            .frame(height: 34)
            .background(Theme.blue.opacity(configuration.isPressed ? 0.35 : 0.22), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.blue.opacity(0.35), lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}
