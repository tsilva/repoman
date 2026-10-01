import SwiftUI

struct RepositoryIssuesView: View {
    @EnvironmentObject private var store: RepositoryStore
    let repository: RepositorySnapshot?
    let checkID: String?
    @Binding var showsRepositoryChanges: Bool
    @State private var pinnedIssue: RepositoryIssueListItem?
    @State private var showsChanges = false
    private var issues: [RepositoryIssueListItem] {
        let visible = repository.map { store.issues(in: $0, includeCompleted: true) }
            ?? store.repositories.flatMap { store.issues(in: $0, includeCompleted: true) }
        return visible.filter { checkID == nil || $0.finding.checkID == checkID }
    }
    private var selected: RepositoryIssueListItem? {
        // Follow the conversation as its row changes from a finding to a finished occurrence.
        if let pinnedIssue {
            if let taskID = pinnedIssue.task?.id {
                return issues.first { $0.task?.id == taskID } ?? issues.first
            }
            return issues.first { $0.id == pinnedIssue.id } ?? issues.first
        }
        return issues.first
    }
    private func isSelected(_ issue: RepositoryIssueListItem) -> Bool {
        selected?.id == issue.id && selected?.task?.id == issue.task?.id
    }
    private var isChecking: Bool {
        repository.map { store.loadingRepositoryIDs.contains($0.id) }
            ?? (store.isScanning || store.isFetching || !store.loadingRepositoryIDs.isEmpty)
    }
    private var checkProgress: RepositoryCheckProgress? {
        if let repository { return store.repositoryCheckProgress[repository.id] }
        let progress = store.repositoryCheckProgress.values
        guard !progress.isEmpty else { return nil }
        return RepositoryCheckProgress(completed: progress.reduce(0) { $0 + $1.completed },
                                       total: progress.reduce(0) { $0 + $1.total })
    }

    private var checkingFooter: some View {
        HStack(spacing: 10) {
            if let checkProgress {
                RepositoryCheckProgressRing(progress: checkProgress).frame(width: 20, height: 20)
                Text("Checking… \(checkProgress.remaining) checks remaining")
            } else {
                ProgressView().progressViewStyle(.circular).controlSize(.small)
                Text("Checking…")
            }
        }
        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Panel {
                HStack {
                    Text("Issues").font(.system(size: 17, weight: .semibold))
                    Spacer()
                    RepositoryIssueStatusBadges(counts: RepositoryIssueStatus.counts(in: issues))
                }.foregroundStyle(Theme.primary)
            } content: {
                if issues.isEmpty && !isChecking {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle").font(.system(size: 25)).foregroundStyle(Theme.green)
                        Text("No issues from available checks").foregroundStyle(Theme.secondary)
                        if let repository, !store.unavailableChecks(in: repository).isEmpty {
                            Text(store.unavailableChecks(in: repository).joined(separator: "\n"))
                                .font(.system(size: 11)).foregroundStyle(Theme.amber).textSelection(.enabled)
                        }
                        if let repository, !(store.ignoredChecks[repository.id] ?? []).isEmpty {
                            Button("Restore ignored checks") { store.restoreChecks(for: repository) }
                                .buttonStyle(RepositoryButtonStyle())
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    CodexScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(issues) { issue in
                                Button {
                                    pinnedIssue = issue
                                } label: {
                                    RepositoryFindingRow(finding: issue.finding, state: issue.task?.state)
                                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(isSelected(issue) ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel([issue.finding.title, issue.finding.subject].filter { !$0.isEmpty }.joined(separator: ", "))
                                .accessibilityAddTraits(isSelected(issue) ? .isSelected : [])
                            }
                            if isChecking { checkingFooter }
                        }.padding(8)
                    }
                }
            }
            if let selected, let target = store.repositories.first(where: { $0.id == selected.finding.repositoryID }) {
                RepositoryFindingDetail(finding: selected.finding, repository: target, taskID: selected.task?.id, onShowChanges: {
                    showsRepositoryChanges = false
                    showsChanges = true
                }) { id in
                    pinnedIssue = RepositoryIssueListItem(finding: selected.finding, task: store.tasks.first { $0.id == id })
                }.id(selected.task?.id.uuidString ?? selected.id)
            } else {
                Panel {
                    Text("Issue details").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } content: {
                    Text("Select an issue to inspect its evidence and choose repair instructions.")
                        .foregroundStyle(Theme.secondary).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .inspector(isPresented: Binding(
            get: { showsChanges || showsRepositoryChanges },
            set: { if !$0 { showsChanges = false; showsRepositoryChanges = false } }
        )) {
            Group {
                if showsRepositoryChanges, let repository {
                    RepositoryWorkingTreeSidebar(repository: repository) { showsRepositoryChanges = false }
                        .id(repository.id)
                } else if let task = selected?.task {
                    RepairDiffSidebar(source: task.diff) { showsChanges = false }
                }
            }
            .padding(.leading, 12)
            .background(Theme.background, ignoresSafeAreaEdges: [])
            .inspectorColumnWidth(min: 440, ideal: 680, max: 1_000)
        }
        .onChange(of: selected?.id) { _, _ in showsChanges = false }
        .onChange(of: selected?.task?.id) { _, _ in showsChanges = false }
        .onChange(of: showsRepositoryChanges) { _, visible in
            if visible { showsChanges = false }
        }
    }
}

struct RepositoryFindingRow: View {
    let finding: RepositoryFinding
    let state: RepairTaskState?
    private var status: RepositoryIssueStatus? { state.map { RepositoryIssueStatus(state: $0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: finding.symbol)
                    .foregroundStyle(status == .completed ? Theme.green : finding.severity == .blocked ? Theme.red : Theme.amber)
                    .frame(width: 18).padding(.top, 2)
                VStack(alignment: .leading, spacing: 5) {
                    Text(finding.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.primary)
                    if !finding.subject.isEmpty {
                        Text(finding.subject).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.primary)
                            .lineLimit(1).truncationMode(.middle).help(finding.subject)
                    }
                    Text(finding.evidence).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        .lineLimit(2).help(finding.evidence)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Theme.secondary)
            }
            if let status {
                HStack(spacing: 12) {
                    Group {
                        if status == .processing {
                            ProgressView().controlSize(.mini).tint(status.color)
                        } else {
                            Image(systemName: status.symbol).font(.system(size: 11))
                        }
                    }.frame(width: 18, height: 14).accessibilityHidden(true)
                    Text(status.title).font(.system(size: 10))
                }
                .foregroundStyle(status.color)
                .help(state?.title ?? status.title)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(status?.title ?? "No repair started")
    }
}

extension RepositoryIssueStatus {
    var title: String {
        switch self {
        case .pending: return "Not started"
        case .processing: return "Processing…"
        case .waiting: return "Waiting for you"
        case .completed: return "Completed"
        case .error: return "Error"
        }
    }

    var symbol: String {
        switch self {
        case .pending: return "exclamationmark.circle"
        case .processing: return "arrow.triangle.2.circlepath"
        case .waiting: return "person"
        case .completed: return "checkmark"
        case .error: return "exclamationmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .pending, .waiting: return Theme.amber
        case .processing: return Theme.blue
        case .completed: return Theme.green
        case .error: return Theme.red
        }
    }
}

struct RepositoryIssueStatusBadges: View {
    let counts: [RepositoryIssueStatus: Int]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(RepositoryIssueStatus.allCases, id: \.self) { status in
                if let count = counts[status], count > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: status.symbol).font(.system(size: 9, weight: .medium))
                        Text(count.formatted()).font(.system(size: 11, weight: .medium)).monospacedDigit()
                    }
                    .foregroundStyle(status.color)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Theme.control, in: Capsule())
                    .overlay { NativeTooltip(text: "\(status.title): \(count)") }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(status.title): \(count)")
                }
            }
        }.fixedSize()
    }
}

private struct RepositoryFindingDetail: View {
    @EnvironmentObject private var store: RepositoryStore
    let finding: RepositoryFinding
    let repository: RepositorySnapshot
    let taskID: UUID?
    let onShowChanges: () -> Void
    let onRun: (UUID) -> Void
    @State private var currentRunID: UUID?
    @State private var recipeID = "custom"
    @State private var prompt = ""
    @State private var editorHeight: CGFloat = 38
    private var recipes: [RepairRecipe] { store.recipeCatalog.recipes(for: finding) }
    private var currentTask: RepairTask? {
        if let id = currentRunID ?? taskID { return store.tasks.first { $0.id == id } }
        return store.task(for: finding)
    }
    private var canSubmit: Bool {
        !store.isDemo && currentTask?.state.isActive != true && currentTask?.state.isClosed != true &&
            !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var body: some View {
        Panel {
            HStack {
                Text("Issue details").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.primary)
                Spacer()
                if let task = currentTask {
                    ToolbarActionButton(symbol: "archivebox", title: task.state.isActive
                                        ? "Stop the repair before archiving" : "Archive conversation") {
                        _ = store.archiveTask(task.id)
                    }
                    .disabled(task.state.isActive)
                    .accessibilityIdentifier("archive-issue-conversation")
                }
                if let url = finding.detailsURL, url.scheme == "https" || url.scheme == "http" {
                    ToolbarActionButton(symbol: "arrow.up.right.square",
                                        title: finding.category == .ci ? "Open CI details" : "Open issue details") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        } content: {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    CodexScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(finding.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.primary)
                            if !finding.subject.isEmpty {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(finding.subject.hasPrefix(".github/workflows/") ? "Workflow" : "Applies to")
                                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                                    Text(finding.subject).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.primary)
                                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Text(finding.evidence).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            if let task = currentTask { RepositoryRepairTrajectoryView(task: task, onShowChanges: onShowChanges) }
                            Color.clear.frame(height: 1).id("trajectory-bottom")
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    }
                    .onChange(of: currentTask?.updatedAt) { _, _ in proxy.scrollTo("trajectory-bottom", anchor: .bottom) }
                    .onChange(of: currentTask?.interactions.count) { _, _ in proxy.scrollTo("trajectory-bottom", anchor: .bottom) }
                    .onAppear { if currentTask != nil { proxy.scrollTo("trajectory-bottom", anchor: .bottom) } }
                }
                if let error = store.taskError {
                    Text(error).font(.system(size: 11)).foregroundStyle(Theme.red).textSelection(.enabled)
                        .padding(.horizontal, 20).padding(.vertical, 8)
                }
                if currentTask?.state.isClosed != true {
                    // The composer stays outside the stream while user messages become immutable bubbles.
                    VStack(alignment: .leading, spacing: 10) {
                        if currentTask == nil {
                            CodexPresetPicker(selection: $recipeID,
                                options: recipes.map { ($0.id, $0.title) } + [("custom", "Custom instructions")])
                                .frame(maxWidth: .infinity).frame(height: 30)
                        }
                        VStack(spacing: 0) {
                            CodexScrollView {
                                CodexTextEditor(text: $prompt,
                                    accessibilityLabel: currentTask == nil ? "Repair instructions" : "Message Codex",
                                    onSubmit: submit)
                                    .padding(8)
                                    .overlay(alignment: .topLeading) {
                                        if prompt.isEmpty {
                                            Text("Message Codex…").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                                                .padding(.horizontal, 14).padding(.vertical, 13).allowsHitTesting(false)
                                        }
                                    }
                                    .fixedSize(horizontal: false, vertical: true)
                                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                                        if height > 0, abs(height - editorHeight) > 0.5 { editorHeight = height }
                                    }
                            }.frame(height: min(128, editorHeight))
                            HStack {
                                Spacer()
                                RepairComposerActionButton(isRunning: currentTask?.state.isActive == true,
                                    isEnabled: currentTask?.state.isActive == true
                                        ? !store.isDemo && currentTask?.state != .checking : canSubmit) {
                                    if let task = currentTask, task.state.isActive { store.cancelTask(task.id) }
                                    else { submit() }
                                }
                            }.padding(.horizontal, 10).padding(.bottom, 10).padding(.top, 2)
                        }.background(Theme.field, in: RoundedRectangle(cornerRadius: 8))
                        if store.isDemo { Text("Demo · agent execution is disabled").font(.system(size: 11)).foregroundStyle(Theme.secondary) }
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
                }
            }
        }
        .onAppear {
            if let task = currentTask {
                currentRunID = task.id
                recipeID = "custom"
                prompt = ""
                onRun(task.id)
            } else if let first = recipes.first { recipeID = first.id; prompt = first.prompt }
        }
        .onChange(of: recipeID) { _, id in
            if let recipe = recipes.first(where: { $0.id == id }) { prompt = recipe.prompt }
        }
    }
    private func submit() {
        guard canSubmit else { return }
        if let id = store.runRepair(finding: finding, repository: repository, prompt: prompt,
                                   recipeID: recipeID == "custom" ? nil : recipeID) {
            currentRunID = id
            prompt = ""
            recipeID = "custom"
            onRun(id)
        }
    }
}

/// Stays visible at the bottom of the input even while a long draft scrolls.
private struct RepairComposerActionButton: View {
    let isRunning: Bool
    let isEnabled: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isRunning ? "stop.fill" : "arrow.up")
                .font(.system(size: isRunning ? 10 : 14, weight: .semibold))
                .foregroundStyle(Theme.background)
                .frame(width: 30, height: 30)
                .background(Theme.primary.opacity(isHovered ? 0.85 : 1), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { isHovered = $0 }
        .keyboardShortcut(isRunning ? nil : KeyboardShortcut(.return, modifiers: .command))
        .accessibilityLabel(isRunning ? "Stop repair" : "Send message")
        .accessibilityIdentifier("repair-composer-action")
        .help(isRunning ? "Stop repair" : "Send message (Return or ⌘Return; Shift+Return for a newline)")
    }
}
