import AppKit
import SwiftUI

struct RepositoryIssuesView: View {
    @EnvironmentObject private var store: RepositoryStore
    let repository: RepositorySnapshot?
    let checkID: String?
    @Binding var showsRepositoryChanges: Bool
    @State private var selectedIssueID: String?
    private var issues: [RepositoryIssueListItem] {
        let visible = repository.map { store.issues(in: $0) }
            ?? store.repositories.flatMap { store.issues(in: $0) }
        return RepositoryIssueListItem.sortedByCheckCategory(
            visible.filter { checkID == nil || $0.finding.checkID == checkID }, checks: store.issueCatalog.checks)
    }
    private var selected: RepositoryIssueListItem? { issues.first { $0.id == selectedIssueID } }
    private func select(_ issue: RepositoryIssueListItem) { selectedIssueID = issue.id }
    private func isSelected(_ issue: RepositoryIssueListItem) -> Bool { selected?.id == issue.id }
    private var isChecking: Bool {
        repository.map { store.loadingRepositoryIDs.contains($0.id) }
            ?? (store.isScanning || store.isFetching || !store.loadingRepositoryIDs.isEmpty)
    }
    private var checks: [RepositoryCheckListItem] {
        let visible = repository.map { store.checks(in: $0) }
            ?? store.repositories.flatMap { store.checks(in: $0) }
        return visible.filter { checkID == nil || $0.check.id == checkID }
    }
    private var activeChecks: [RepositoryCheckListItem] { checks.filter { $0.status == .running } + checks.filter { $0.status == .queued } }

    @ViewBuilder
    private var checkSections: some View {
        let skipped = checks.filter { $0.status == .skipped }
        if !skipped.isEmpty {
            Text("\(skipped.count) checks skipped by policy").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        let notApplicable = checks.filter { $0.status == .notApplicable }
        if !notApplicable.isEmpty {
            Text("\(notApplicable.count) checks not applicable")
                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .help(notApplicable.map { $0.check.title }.joined(separator: "\n"))
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
        let status = isRunning ? "Running" : "Queued"
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
                    Image(systemName: "circle")
                        .font(.system(size: 13)).frame(width: 14, height: 14)
                }
                Text(status).font(.system(size: 11))
            }.foregroundStyle(isRunning ? Theme.blue : Theme.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.repository.name), \(item.title)")
        .accessibilityValue(status)
        .accessibilityIdentifier("check.\(item.check.id).\(item.repository.id)")
    }

    private func issueSeparator() -> some View {
        Rectangle().fill(Theme.primary.opacity(0.06)).frame(height: 1)
            .padding(.horizontal, 12).allowsHitTesting(false).accessibilityHidden(true)
    }
    private func issueRow(_ issue: RepositoryIssueListItem) -> some View {
        Button { select(issue) } label: {
            RepositoryFindingRow(finding: issue.finding, isIncomplete: issue.isIncomplete)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                .background(isSelected(issue) ? Theme.selection : .clear)
        }.buttonStyle(.plain).accessibilityAddTraits(isSelected(issue) ? .isSelected : [])
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Panel {
                Text("Inspection results").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } content: {
                DashboardScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if issues.isEmpty && !isChecking {
                            VStack(spacing: 12) {
                                Image(systemName: "checkmark.circle").font(.system(size: 25)).foregroundStyle(Theme.green)
                                Text("No issues from available checks").foregroundStyle(Theme.secondary)
                                if let repository, !(store.ignoredChecks[repository.id] ?? []).isEmpty {
                                    Button("Restore ignored checks") { store.restoreChecks(for: repository) }.buttonStyle(RepositoryButtonStyle())
                                }
                            }.padding(24).frame(maxWidth: .infinity)
                        }
                        ForEach(RepositoryIssueStatus.allCases, id: \.self) { status in
                            let items = issues.filter { $0.status == status }
                            if !items.isEmpty {
                                Text(status.title).font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(status.color).padding(12)
                                ForEach(items) { issue in
                                    issueRow(issue).overlay(alignment: .bottom) {
                                        if issue.id != items.last?.id { issueSeparator() }
                                    }
                                }
                            }
                        }
                        checkSections
                    }.padding(8).padding(.trailing, 12)
                }
            }
            if let selected {
                RepositoryFindingDetail(issue: selected)
            } else {
                Panel {
                    Text("Result details").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } content: {
                    Text("No result selected").foregroundStyle(Theme.secondary).padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { if store.isDemo { selectedIssueID = issues.first?.id } }
        .onChange(of: repository?.id) { _, _ in clearSelection() }
        .onChange(of: checkID) { _, _ in clearSelection() }
        .onChange(of: issues) { _, _ in if selected == nil { selectedIssueID = nil } }
        .inspector(isPresented: $showsRepositoryChanges) {
            if let repository {
                RepositoryWorkingTreeSidebar(repository: repository) { showsRepositoryChanges = false }
                    .id(repository.id).padding(.leading, 12)
                    .background(Theme.background, ignoresSafeAreaEdges: [])
                    .inspectorColumnWidth(min: 440, ideal: 680, max: 1_000)
            }
        }
    }
    private func clearSelection() { selectedIssueID = nil }
}

struct RepositoryFindingRow: View {
    let finding: RepositoryFinding
    var isIncomplete = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: finding.symbol).foregroundStyle(Theme.secondary).frame(width: 18, height: 16)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 5) {
                Text(finding.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.primary)
                if !finding.subject.isEmpty {
                    Text(finding.subject).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.primary)
                        .lineLimit(1).truncationMode(.middle).help(finding.subject)
                }
                Text(finding.evidence).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(2).help(finding.evidence)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if isIncomplete { IncompleteCheckBadge() }
            else if finding.severity == .information {
                Text("Information").font(.system(size: 10)).foregroundStyle(Theme.secondary)
            }
            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Theme.secondary)
        }.accessibilityElement(children: .combine)
            .accessibilityValue(isIncomplete ? "Coverage limit; result unknown" : (finding.severity == .information ? "Information" : "Actionable issue"))
    }
}

private struct IncompleteCheckBadge: View {
    var body: some View {
        Text("Coverage limit").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3).background(Theme.secondary.opacity(0.1), in: Capsule())
            .fixedSize().help("This check could not complete. Its result is unknown.")
    }
}

extension RepositoryIssueStatus {
    var title: String {
        switch self {
        case .finding: return "Actionable issues"
        case .incomplete: return "Coverage limits"
        case .information: return "Information"
        }
    }
    var symbol: String {
        switch self {
        case .finding: return "exclamationmark.circle"
        case .incomplete: return "questionmark.circle"
        case .information: return "info.circle"
        }
    }
    var color: Color { self == .finding ? Theme.amber : Theme.secondary }
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
                    }.foregroundStyle(status.color).padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Theme.control, in: Capsule())
                        .overlay { NativeTooltip(text: "\(status.title): \(count)") }
                        .accessibilityElement(children: .ignore).accessibilityLabel("\(status.title): \(count)")
                }
            }
        }.fixedSize()
    }
}

struct RepositoryFindingDetail: View {
    @EnvironmentObject private var store: RepositoryStore
    let issue: RepositoryIssueListItem
    private var finding: RepositoryFinding { issue.finding }
    var body: some View {
        Panel {
            HStack {
                Text("Result details").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.primary)
                Spacer()
                ToolbarActionButton(symbol: "doc.on.clipboard", title: "Copy maintenance task") {
                    let observed = store.checkObservation(for: finding)
                    NSPasteboard.general.clearContents()
                    let cli = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/repoman").path
                    NSPasteboard.general.setString(RepositoryMaintenanceTask.text(for: finding, observedAt: observed, executable: cli), forType: .string)
                }.accessibilityIdentifier("issue.copy-maintenance-task")
                if let url = finding.detailsURL, ["http", "https"].contains(url.scheme ?? "") {
                    ToolbarActionButton(symbol: "arrow.up.right.square", title: "Open issue details") { NSWorkspace.shared.open(url) }
                }
            }
        } content: {
            DashboardScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(finding.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.primary)
                    if issue.isIncomplete { IncompleteCheckBadge() }
                    if !finding.subject.isEmpty {
                        Text(finding.subject).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.primary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(finding.evidence).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text(finding.category.rawValue + " · " + finding.checkID)
                        .font(.system(size: 11)).foregroundStyle(Theme.subtle).textSelection(.enabled)
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.accessibilityIdentifier("issue-details-evidence")
    }
}
