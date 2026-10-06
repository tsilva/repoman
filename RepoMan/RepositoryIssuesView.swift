import SwiftUI

struct RepositoryIssuesView: View {
    @EnvironmentObject private var store: RepositoryStore
    let repository: RepositorySnapshot?
    let checkID: String?
    @Binding var showsRepositoryChanges: Bool
    @State private var pinnedIssue: RepositoryIssueListItem?
    @State private var selectedGroupID: String?
    @State private var showsChanges = false
    @State private var expandedGroups: Set<String> = []
    @State private var selectedInstanceIDs: Set<String> = []
    @State private var showsPassedChecks = false
    private var groups: [RepositoryIssueGroup] {
        let groups = RepositoryIssueGroup.groups(orderedIssues)
        return groups.filter { $0.items.count > 1 } + groups.filter { $0.items.count == 1 }
    }
    private var selectedGroup: RepositoryIssueGroup? { groups.first { $0.id == selectedGroupID } }
    private var repairSelection: [RepositoryIssueListItem] {
        orderedIssues.filter { selectedInstanceIDs.contains($0.id) && !$0.isIncomplete &&
            $0.status != .completed && $0.task?.state.isActive != true }
    }
    private func repairSelection(for issue: RepositoryIssueListItem) -> [RepositoryIssueListItem] {
        guard issue.status != .completed else { return [] }
        return repairSelection.filter { $0.finding.repositoryID == issue.finding.repositoryID &&
            $0.finding.checkID == issue.finding.checkID }
    }
    private func select(_ issue: RepositoryIssueListItem) {
        selectedGroupID = nil
        pinnedIssue = issue
    }
    private func selectGroup(_ group: RepositoryIssueGroup) {
        selectedGroupID = group.id
        expandedGroups.insert(group.id)
        showsChanges = false
    }
    private func canSelect(_ issue: RepositoryIssueListItem) -> Bool {
        !issue.isIncomplete && issue.task?.state.isActive != true
    }
    private func toggleSelection(_ issue: RepositoryIssueListItem) {
        guard canSelect(issue) else { return }
        selectedGroupID = nil
        if selectedInstanceIDs.contains(issue.id) { selectedInstanceIDs.remove(issue.id) }
        else { selectedInstanceIDs.insert(issue.id) }
        pinnedIssue = issue
    }
    private func selectGroupForRepair(_ group: RepositoryIssueGroup) {
        selectedGroupID = nil
        let ids = Set(group.selectableItems.map(\.id))
        selectedInstanceIDs.formUnion(ids)
        if let first = group.selectableItems.first { pinnedIssue = first }
        expandedGroups.insert(group.id)
    }
    private var issues: [RepositoryIssueListItem] {
        let visible = repository.map { store.issues(in: $0, includeCompleted: true) }
            ?? store.repositories.flatMap { store.issues(in: $0, includeCompleted: true) }
        return visible.filter { checkID == nil || $0.finding.checkID == checkID }
    }
    private var orderedIssues: [RepositoryIssueListItem] {
        let visible = issues
        return [RepositoryIssueStatus.waiting, .completed, .processing, .pending].flatMap { status in
            visible.filter { $0.status == status }
        }
    }
    private var selected: RepositoryIssueListItem? {
        // Follow the same instance as a shared session changes verification state.
        // Archiving or removing it leaves the details panel empty until another explicit selection.
        guard let pinnedIssue else { return nil }
        if let taskID = pinnedIssue.task?.id {
            return issues.first { $0.task?.id == taskID && $0.finding.id == pinnedIssue.finding.id }
        }
        return issues.first { $0.id == pinnedIssue.id }
    }
    private func isSelected(_ issue: RepositoryIssueListItem) -> Bool {
        selectedGroup == nil && selected?.id == issue.id && selected?.task?.id == issue.task?.id
    }
    private var isChecking: Bool {
        repository.map { store.loadingRepositoryIDs.contains($0.id) }
            ?? (store.isScanning || store.isFetching || !store.loadingRepositoryIDs.isEmpty)
    }
    private var checks: [RepositoryCheckListItem] {
        let visible = repository.map { store.checks(in: $0) }
            ?? store.repositories.flatMap { store.checks(in: $0) }
        return visible.filter { checkID == nil || $0.check.id == checkID }
    }
    private var passedChecks: [RepositoryCheckListItem] { checks.filter { $0.status == .passed } }
    private var activeChecks: [RepositoryCheckListItem] {
        checks.filter { $0.status == .running } + checks.filter { $0.status == .queued }
    }

    @ViewBuilder
    private var checkSections: some View {
        if !passedChecks.isEmpty {
            issueSeparator()
            Button { showsPassedChecks.toggle() } label: {
                HStack(spacing: 10) {
                    Image(systemName: showsPassedChecks ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.secondary)
                        .frame(width: 8)
                    Image(systemName: "checkmark.circle").font(.system(size: 16)).foregroundStyle(Theme.green)
                    Text("Passed checks").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.primary)
                    Text("\(passedChecks.count)").font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.secondary).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Theme.control, in: Capsule())
                    Spacer()
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(showsPassedChecks ? "Collapse" : "Expand") passed checks, \(passedChecks.count)")
            .accessibilityIdentifier("checks.passed.disclosure")
            if showsPassedChecks {
                ForEach(passedChecks) { check in checkRow(check) }
            }
        }
        if !activeChecks.isEmpty {
            issueSeparator()
            HStack(spacing: 8) {
                Text("Checks in progress").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.primary)
                Text("\(activeChecks.filter { $0.status == .running }.count) running · \(activeChecks.filter { $0.status == .queued }.count) queued")
                    .font(.system(size: 10)).foregroundStyle(Theme.secondary)
            }.padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 6)
            ForEach(activeChecks) { check in
                checkRow(check)
                    .overlay(alignment: .bottom) {
                        if check.id != activeChecks.last?.id { issueSeparator() }
                    }
            }
        }
    }

    private func checkRow(_ item: RepositoryCheckListItem) -> some View {
        let isRunning = item.status == .running
        let isPassed = item.status == .passed
        let status = isRunning ? "Running" : (isPassed ? "Passed" : "Queued")
        return HStack(spacing: 10) {
            Image(systemName: item.check.symbol).font(.system(size: 14)).foregroundStyle(Theme.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 12)).foregroundStyle(Theme.primary)
                if repository == nil {
                    Text(item.repository.name).font(.system(size: 10)).foregroundStyle(Theme.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                if isRunning {
                    Image(systemName: "circle.dotted").font(.system(size: 13))
                        .symbolEffect(.rotate.clockwise, isActive: true)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: isPassed ? "checkmark.circle" : "circle")
                        .font(.system(size: 13)).frame(width: 14, height: 14)
                }
                Text(status).font(.system(size: 11))
            }.foregroundStyle(isRunning ? Theme.blue : (isPassed ? Theme.green : Theme.secondary))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.repository.name), \(item.title)")
        .accessibilityValue(status)
        .accessibilityIdentifier("check.\(item.check.id).\(item.repository.id)")
    }

    @ViewBuilder
    private func issueGroup(_ group: RepositoryIssueGroup) -> some View {
        if group.items.count == 1, let issue = group.items.first {
            issueRow(issue, in: group, child: false)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Button {
                        if expandedGroups.contains(group.id) { expandedGroups.remove(group.id) }
                        else { expandedGroups.insert(group.id) }
                    } label: {
                        Image(systemName: expandedGroups.contains(group.id) ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // Keep the large hit target from adding space above the first text line.
                    .padding(-8)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    .accessibilityLabel("\(expandedGroups.contains(group.id) ? "Collapse" : "Expand") \(group.title)")
                    Button { selectGroup(group) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.primary)
                            Text(groupSummary(group)).font(.system(size: 10)).foregroundStyle(Theme.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open \(group.title) group")
                }
                .padding(12)
                .background(selectedGroupID == group.id ? Theme.selection : .clear)
                if expandedGroups.contains(group.id) {
                    ForEach(group.items) { issue in
                        issueRow(issue, in: group, child: true)
                            .overlay(alignment: .bottom) {
                                if issue.id != group.items.last?.id { issueSeparator(child: true) }
                            }
                    }
                }
            }
        }
    }
    private func issueSeparator(child: Bool = false) -> some View {
        Rectangle().fill(Theme.primary.opacity(0.06)).frame(height: 1)
            .padding(.leading, child ? 38 : 12).padding(.trailing, 12)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
    private func groupSummary(_ group: RepositoryIssueGroup) -> String {
        var parts: [String] = []
        if repository == nil, let name = store.repositories.first(where: { $0.id == group.items[0].finding.repositoryID })?.name {
            parts.append(name)
        }
        let active = group.items.filter { $0.status == .processing || $0.status == .waiting && $0.task?.state.isActive == true }.count
        if group.resolvedCount > 0 { parts.append("\(group.resolvedCount) resolved") }
        if active > 0 { parts.append("\(active) active") }
        let remaining = group.items.count - group.resolvedCount - active
        if remaining > 0 { parts.append("\(remaining) remaining") }
        return parts.joined(separator: " · ")
    }
    private func issueRow(_ issue: RepositoryIssueListItem, in group: RepositoryIssueGroup, child: Bool) -> some View {
        let isSelectable = canSelect(issue)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            IssueSelectionCheckbox(isSelected: selectedInstanceIDs.contains(issue.id),
                isEnabled: isSelectable,
                label: "Select \(issue.finding.subject.isEmpty ? issue.finding.title : issue.finding.subject)") {
                    toggleSelection(issue)
                }.disabled(!isSelectable)
                .frame(width: 16, height: 16)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Button { select(issue) } label: {
                RepositoryFindingRow(finding: issue.finding, state: issue.task.map { $0.state(for: issue.finding) },
                    isIncomplete: issue.isIncomplete, isChild: child)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            .accessibilityAddTraits(isSelected(issue) ? .isSelected : [])
        }
        .padding(12)
        .padding(.leading, child ? 26 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected(issue) ? Theme.selection : .clear)
        .overlay(alignment: .leading) {
            if child { Rectangle().fill(Theme.border).frame(width: 1).padding(.leading, 20) }
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Panel {
                HStack {
                    Text("Issues").font(.system(size: 17, weight: .semibold))
                    Spacer()
                    if let repository {
                        ToolbarActionButton(
                            symbol: "arrow.clockwise",
                            title: "Refresh selected repository issues",
                            isRotating: isChecking,
                            foregroundColor: Theme.primary
                        ) {
                            store.refreshSelected()
                        }
                        .disabled(store.isScanning || store.isFetching || store.isSyncing || isChecking)
                        .accessibilityIdentifier("refresh-repository-issues-button")
                        RepositorySyncButton(repository: repository) { showsRepositoryChanges = true }
                    }
                }.foregroundStyle(Theme.primary)
            } content: {
                CodexScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if issues.isEmpty && !isChecking {
                            VStack(spacing: 12) {
                                Image(systemName: "checkmark.circle")
                                    .font(.system(size: 25)).foregroundStyle(Theme.green)
                                Text("No issues from available checks").foregroundStyle(Theme.secondary)
                                if let repository, !(store.ignoredChecks[repository.id] ?? []).isEmpty {
                                    Button("Restore ignored checks") { store.restoreChecks(for: repository) }
                                        .buttonStyle(RepositoryButtonStyle())
                                }
                            }.padding(24).frame(maxWidth: .infinity)
                        }
                        ForEach(groups) { group in
                            issueGroup(group)
                                .overlay(alignment: .bottom) {
                                    if group.id != groups.last?.id { issueSeparator() }
                                }
                        }
                        checkSections
                    }.padding(8).padding(.trailing, 12)
                }
            }
            if let group = selectedGroup {
                RepositoryIssueGroupDetail(group: group, onSelect: select, onRepair: { selectGroupForRepair(group) }, onShowChanges: { issue in
                    select(issue)
                    showsRepositoryChanges = false
                    showsChanges = true
                })
                .id(group.id)
            } else if let selected, let target = store.repositories.first(where: { $0.id == selected.finding.repositoryID }) {
                let scope = repairSelection(for: selected)
                RepositoryFindingDetail(finding: selected.finding,
                    selectedFindings: scope.isEmpty ? [selected.finding] : scope.map(\.finding),
                    startsNewSession: !scope.isEmpty,
                    repository: target, taskID: scope.isEmpty ? selected.task?.id : nil,
                    isIncomplete: selected.isIncomplete, onShowChanges: {
                    showsRepositoryChanges = false
                    showsChanges = true
                }) { id in
                    selectedInstanceIDs.subtract(scope.map(\.id))
                    pinnedIssue = RepositoryIssueListItem(finding: selected.finding, task: store.tasks.first { $0.id == id })
                }.id(scope.isEmpty ? (selected.task?.id.uuidString ?? selected.id) + selected.finding.id
                     : "selection::" + selected.finding.repositoryID + "::" + selected.finding.checkID)
            } else {
                Panel {
                    Text("Issue details").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } content: {
                    Text("No issue selected")
                        .foregroundStyle(Theme.secondary).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: repository?.id) { _, _ in showsPassedChecks = false }
        .onChange(of: checkID) { _, _ in showsPassedChecks = false }
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
        .onChange(of: issues) { _, items in
            let available = items.filter { canSelect($0) }
            let retained = selectedInstanceIDs.intersection(Set(available.map(\.id)))
            if retained != selectedInstanceIDs { selectedInstanceIDs = retained }
            if selected == nil { pinnedIssue = nil }
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
    var isIncomplete = false
    var isChild = false
    private var status: RepositoryIssueStatus { RepositoryIssueStatus(state: state) }
    private var errorTitle: String? {
        switch state {
        case .failed: return "Repair failed"
        case .couldntVerify: return "Couldn’t verify"
        default: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if !isChild {
                    Image(systemName: finding.symbol)
                        .foregroundStyle(status.color)
                        .frame(width: 18, height: 16)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                }
                VStack(alignment: .leading, spacing: 5) {
                    if !isChild || finding.subject.isEmpty {
                        Text(finding.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.primary)
                    }
                    if !finding.subject.isEmpty {
                        Text(finding.subject).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.primary)
                            .lineLimit(1).truncationMode(.middle).help(finding.subject)
                    }
                    Text(finding.evidence).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        .lineLimit(2).help(finding.evidence)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if isIncomplete { IncompleteCheckBadge() }
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                    .frame(height: 16)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            }
            if status != .pending {
                HStack(spacing: 12) {
                    Group {
                        if status == .processing {
                            ProgressView().controlSize(.mini).tint(status.color)
                        } else {
                            Image(systemName: status.symbol).font(.system(size: 11))
                        }
                    }.frame(width: 18, height: 14).accessibilityHidden(true)
                    Text(status.title).font(.system(size: 10, weight: .medium))
                    if let errorTitle {
                        Label(errorTitle, systemImage: "exclamationmark.circle")
                            .font(.system(size: 10)).foregroundStyle(Theme.red)
                    }
                }
                .foregroundStyle(status.color)
                .help(state?.title ?? status.title)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isIncomplete ? "Check incomplete; result unknown" : (status == .pending ? "" : status.title))
    }
}

private struct IncompleteCheckBadge: View {
    var body: some View {
        Text("Check incomplete")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Theme.secondary.opacity(0.1), in: Capsule())
            .overlay { Capsule().strokeBorder(Theme.secondary.opacity(0.25), lineWidth: 1) }
            .fixedSize()
            .help("This check could not complete. Its result is unknown.")
    }
}

extension RepositoryIssueStatus {
    var title: String {
        switch self {
        case .pending: return "No activity"
        case .processing: return "Processing…"
        case .waiting: return "Needs your input"
        case .completed: return "Completed · review & archive"
        }
    }

    var symbol: String {
        switch self {
        case .pending: return "circle.dashed"
        case .processing: return "arrow.triangle.2.circlepath"
        case .waiting: return "person.crop.circle"
        case .completed: return "checkmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .pending: return Theme.secondary
        case .waiting: return Theme.amber
        case .processing: return Theme.blue
        case .completed: return Theme.green
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

/// Group navigation works independently of whether any child is eligible for a new repair.
private struct RepositoryIssueGroupDetail: View {
    @EnvironmentObject private var store: RepositoryStore
    let group: RepositoryIssueGroup
    let onSelect: (RepositoryIssueListItem) -> Void
    let onRepair: () -> Void
    let onShowChanges: (RepositoryIssueListItem) -> Void
    private var sessions: [RepairTask] {
        var seen = Set<UUID>()
        return group.items.compactMap(\.task).filter { seen.insert($0.id).inserted }
    }
    var body: some View {
        Panel {
            Text("Issue group · \(group.items.count) instances")
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } content: {
            VStack(spacing: 0) {
                CodexScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(group.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.primary)
                        Text("\(group.resolvedCount) resolved · \(group.items.count - group.resolvedCount) remaining")
                            .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        ForEach(group.items) { issue in
                            Button { onSelect(issue) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(alignment: .top) {
                                        Text(issue.finding.subject.isEmpty ? issue.finding.title : issue.finding.subject)
                                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.primary)
                                        Spacer()
                                        if issue.isIncomplete {
                                            Text("Check incomplete").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                                        } else if let state = issue.task?.state(for: issue.finding), issue.status != .pending {
                                            Text(state.title).font(.system(size: 10)).foregroundStyle(issue.status.color)
                                        }
                                        Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                                    }
                                    if issue.status != .completed {
                                        Text(issue.finding.evidence).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                                            .lineLimit(2)
                                    }
                                }.padding(8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            .accessibilityLabel("Open \(issue.finding.subject.isEmpty ? issue.finding.title : issue.finding.subject)")
                        }
                        if !group.selectableItems.isEmpty {
                            Button("Select available instances to repair", action: onRepair)
                                .buttonStyle(RepositoryButtonStyle())
                        }
                        ForEach(sessions) { session in
                            Divider().overlay(Theme.border)
                            HStack {
                                Text(sessions.count == 1 ? "Shared conversation" : "Conversation · \(session.findings.count) instances")
                                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.primary)
                                Spacer()
                                if let issue = group.items.first(where: { $0.task?.id == session.id }) {
                                    Button("Open conversation") { onSelect(issue) }
                                        .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(Theme.secondary)
                                }
                            }
                            RepositoryRepairTrajectoryView(task: session, onShowChanges: {
                                if let issue = group.items.first(where: { $0.task?.id == session.id }) { onShowChanges(issue) }
                            })
                        }
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }
                if let error = store.taskError {
                    RepairStatusMessage(message: error, symbol: "exclamationmark.circle", color: Theme.red)
                        .padding(.horizontal, 20).padding(.vertical, 8)
                }
                if !group.completedSessionIDs.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Review the completed results and changes, then archive their conversations together.")
                            .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        Button("Confirm & archive all completed", systemImage: "archivebox") {
                            _ = store.archiveCompletedSessions(group.completedSessionIDs)
                        }
                        .buttonStyle(RepositoryButtonStyle())
                        .accessibilityIdentifier("confirm-and-archive-completed-group")
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.green.opacity(0.06))
                    .padding(.horizontal, 20).padding(.vertical, 12)
                }
            }
        }
    }
}

private struct RepositoryFindingDetail: View {
    @EnvironmentObject private var store: RepositoryStore
    @Environment(\.openSettings) private var openSettings
    let finding: RepositoryFinding
    let selectedFindings: [RepositoryFinding]
    let startsNewSession: Bool
    let repository: RepositorySnapshot
    let taskID: UUID?
    let isIncomplete: Bool
    let onShowChanges: () -> Void
    let onRun: (UUID) -> Void
    @State private var currentRunID: UUID?
    @State private var startsFresh = false
    @State private var recipeID = "custom"
    @State private var prompt = ""
    @State private var editorHeight: CGFloat = 38
    @State private var questionsHeight: CGFloat = 360
    private var recipes: [RepairRecipe] { store.recipeCatalog.recipes(for: finding) }
    private var currentTask: RepairTask? {
        guard !isIncomplete else { return nil }
        if let id = currentRunID { return store.tasks.first { $0.id == id } }
        if startsNewSession || startsFresh { return nil }
        if let id = taskID { return store.tasks.first { $0.id == id } }
        return store.task(for: finding)
    }
    private var canSubmit: Bool {
        !isIncomplete && !store.isDemo && currentTask?.state.isActive != true && currentTask?.state.isClosed != true && currentTask?.isArchived != true && currentTask?.hasSupersededInstances != true &&
            !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var scope: [RepositoryFinding] { currentTask?.findings ?? selectedFindings }
    private var history: [RepairTask] { store.tasks.filter { $0.contains(finding) }.reversed() }
    private var scopeTitle: String { scope.count > 1 ? "Shared repair · \(scope.count) instances" : "Issue details" }
    private var pendingQuestions: [AgentInteraction] {
        currentTask?.interactions.filter { $0.kind == .questions } ?? []
    }
    var body: some View {
        Panel {
            HStack {
                Text(scopeTitle).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.primary)
                Spacer()
                if store.issueCatalog.checks.first(where: { $0.id == finding.checkID })?.configurationKind != nil {
                    ToolbarActionButton(symbol: "gearshape", title: "Configure this check") {
                        store.requestedSettingsCheckID = finding.checkID
                        openSettings()
                    }
                    .accessibilityIdentifier("issue.configure.\(finding.checkID)")
                }
                if let task = currentTask, !task.state.isClosed && !task.isArchived {
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
                            if isIncomplete { IncompleteCheckBadge() }
                            if scope.count > 1 {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(currentTask == nil ? "Selected instances · one shared conversation" : "Thread scope · one shared conversation")
                                        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                                    ForEach(scope) { instance in
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack {
                                                Text(instance.subject.isEmpty ? instance.title : instance.subject)
                                                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.primary)
                                                Spacer()
                                                if let task = currentTask {
                                                    Text(task.state(for: instance).title).font(.system(size: 10))
                                                        .foregroundStyle(RepositoryIssueStatus(state: task.state(for: instance)).color)
                                                }
                                            }
                                            Text(currentTask?.verification(for: instance)?.evidence ?? instance.evidence)
                                                .font(.system(size: 11)).foregroundStyle(Theme.secondary).textSelection(.enabled)
                                        }
                                        .padding(8)
                                        .background(currentTask != nil && instance.id == finding.id ? Theme.selection : .clear)
                                    }
                                }
                            } else {
                                Text(finding.evidence).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                            if !history.isEmpty {
                                Menu {
                                    ForEach(history) { session in
                                        Button("\(session.findings.count) instance(s) · \(session.state.title)\(session.isArchived ? " · Archived" : (session.hasSupersededInstances ? " · Earlier" : "")) · \(session.createdAt.formatted(date: .abbreviated, time: .shortened))") {
                                            currentRunID = session.id
                                            startsFresh = false
                                            recipeID = "custom"
                                            prompt = ""
                                        }
                                    }
                                    Divider()
                                    Button("New repair session") {
                                        currentRunID = nil
                                        startsFresh = true
                                        prompt = recipes.first?.prompt ?? ""
                                        recipeID = recipes.first?.id ?? "custom"
                                    }
                                    .disabled(history.contains { $0.state.isActive && !$0.isArchived })
                                } label: {
                                    Label("Conversation history (\(history.count))", systemImage: "clock.arrow.circlepath")
                                        .font(.system(size: 11))
                                }
                                .menuStyle(.borderlessButton).fixedSize()
                            }
                            if isIncomplete {
                                Text(finding.checkID == "files.secrets"
                                    ? "Result unknown. No secret has been confirmed."
                                    : "Result unknown. This check has not confirmed a problem.")
                                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                            if let task = currentTask { RepositoryRepairTrajectoryView(task: task, onShowChanges: onShowChanges) }
                            Color.clear.frame(height: 1).id("trajectory-bottom")
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    }
                    .onChange(of: currentTask?.updatedAt) { _, _ in proxy.scrollTo("trajectory-bottom", anchor: .bottom) }
                    .onChange(of: currentTask?.interactions.count) { _, _ in proxy.scrollTo("trajectory-bottom", anchor: .bottom) }
                    .onAppear { if currentTask != nil { proxy.scrollTo("trajectory-bottom", anchor: .bottom) } }
                }
                if let task = currentTask, task.state.isClosed || task.isArchived || task.hasSupersededInstances {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(task.hasSupersededInstances ? "Earlier conversation" : (task.isArchived ? "Archived conversation" : RepositoryIssueStatus.completed.title),
                              systemImage: task.isArchived ? "archivebox" : RepositoryIssueStatus.completed.symbol)
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.green)
                        Text(task.hasSupersededInstances ? "A newer repair session covers some of these instances. This conversation is preserved as read-only history." : task.isArchived ? "This conversation is preserved in history." : "Review the result and any changes, then confirm to archive this conversation.")
                            .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        if !task.isArchived {
                        Button("Confirm & archive", systemImage: "archivebox") {
                            _ = store.archiveTask(task.id)
                        }
                        .buttonStyle(RepositoryButtonStyle())
                        .accessibilityIdentifier("confirm-and-archive-issue")
                        }
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                    .padding(.horizontal, 20).padding(.vertical, 12)
                }
                if !isIncomplete, let error = store.taskError {
                    RepairStatusMessage(message: error, symbol: "exclamationmark.circle", color: Theme.red)
                        .padding(.horizontal, 20).padding(.vertical, 8)
                }
                if !isIncomplete && currentTask?.state.isClosed != true && currentTask?.isArchived != true && currentTask?.hasSupersededInstances != true {
                    if let task = currentTask, !pendingQuestions.isEmpty {
                        CodexScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(pendingQuestions) { interaction in
                                    RepairInteractionView(taskID: task.id, interaction: interaction).id(interaction.id)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                                if height > 0, abs(height - questionsHeight) > 0.5 { questionsHeight = height }
                            }
                        }
                        .frame(height: min(360, questionsHeight))
                        .padding(20)
                        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
                    } else {
                        // Pending questions replace the composer until their answers are submitted.
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
                                    if scope.count > 1 {
                                        Text("\(scope.count) instances · one thread").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                                    }
                                    Spacer()
                                    if currentTask == nil && scope.count > 1 {
                                        Button("Fix \(scope.count) together", systemImage: "arrow.up", action: submit)
                                            .buttonStyle(RepositoryButtonStyle()).disabled(!canSubmit)
                                            .keyboardShortcut(.return, modifiers: .command)
                                    } else {
                                    RepairComposerActionButton(isRunning: currentTask?.state.isActive == true,
                                        isEnabled: currentTask?.state.isActive == true
                                            ? !store.isDemo && currentTask?.state != .checking : canSubmit) {
                                        if let task = currentTask, task.state.isActive { store.cancelTask(task.id) }
                                        else { submit() }
                                    }
                                    }
                                }.padding(.horizontal, 10).padding(.bottom, 10).padding(.top, 2)
                            }.background(Theme.composer, in: RoundedRectangle(cornerRadius: 8))
                            if store.isDemo { Text("Demo · agent execution is disabled").font(.system(size: 11)).foregroundStyle(Theme.secondary) }
                        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
                    }
                }
            }
        }
        .onAppear {
            guard !isIncomplete else { return }
            if let task = currentTask {
                currentRunID = task.id
                recipeID = "custom"
                prompt = ""
            } else if let first = recipes.first { recipeID = first.id; prompt = first.prompt }
        }
        .onChange(of: recipeID) { _, id in
            if let recipe = recipes.first(where: { $0.id == id }) { prompt = recipe.prompt }
        }
    }
    private func submit() {
        guard canSubmit else { return }
        if let id = store.runRepair(findings: scope, repository: repository, prompt: prompt,
                                   recipeID: recipeID == "custom" ? nil : recipeID, sessionID: currentTask?.id) {
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

/// Individual instance checkboxes toggle only between checked and unchecked.
private struct IssueSelectionCheckbox: NSViewRepresentable {
    let isSelected: Bool
    let isEnabled: Bool
    let label: String
    let action: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: context.coordinator, action: #selector(Coordinator.toggle(_:)))
        button.allowsMixedState = false
        button.state = isSelected ? .on : .off
        button.isEnabled = isEnabled
        button.controlSize = .small
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self
        let state: NSControl.StateValue = isSelected ? .on : .off
        // Avoid redundant native redraws when only the inspected issue or conversation changes.
        NSAnimationContext.runAnimationGroup { animation in
            animation.duration = 0
            animation.allowsImplicitAnimation = false
            if button.state != state { button.state = state }
            if button.isEnabled != isEnabled { button.isEnabled = isEnabled }
        }
        if button.accessibilityLabel() != label { button.setAccessibilityLabel(label) }
    }
    final class Coordinator: NSObject {
        var parent: IssueSelectionCheckbox
        init(_ parent: IssueSelectionCheckbox) { self.parent = parent }
        @objc func toggle(_ button: NSButton) {
            guard parent.isEnabled else {
                button.state = parent.isSelected ? .on : .off
                return
            }
            parent.action()
        }
    }
}
