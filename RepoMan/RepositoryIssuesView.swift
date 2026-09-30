import AppKit
import SwiftUI

struct RepositoryIssuesView: View {
    @EnvironmentObject private var store: RepositoryStore
    let repository: RepositorySnapshot?
    let checkID: String?
    @State private var selectedID: String?

    private var findings: [RepositoryFinding] {
        if let repository { return store.findings(in: repository) }
        return store.findings.filter { checkID == nil || $0.checkID == checkID }
    }

    private var selected: RepositoryFinding? {
        findings.first { $0.id == selectedID } ?? findings.first
    }

    private var batchAction: RepositoryActionDefinition? {
        guard repository == nil, findings.count > 1, let first = findings.first else { return nil }
        return first.actionIDs.compactMap { store.actionCatalog.action($0) }.first { action in
            action.supportsBatch && findings.allSatisfy { $0.actionIDs.contains(action.id) }
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Panel {
                HStack(spacing: 10) {
                    Text(repository == nil ? "Affected repositories" : "Issues needing attention")
                        .font(.system(size: 17, weight: .semibold))
                    Spacer()
                    Text(findings.count.formatted()).foregroundStyle(Theme.secondary)
                    if let batchAction {
                        Button("Preview all") {
                            let ids = Set(findings.map(\.repositoryID))
                            store.prepareAction(batchAction.id, repositories: store.repositories.filter { ids.contains($0.id) })
                        }
                        .buttonStyle(RepositoryButtonStyle())
                        .disabled(store.isActing || store.isScanning || store.isFetching)
                        .help("Prepare a separate preview for each repository")
                    }
                }
                .foregroundStyle(Theme.primary)
            } content: {
                if findings.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle").font(.system(size: 25)).foregroundStyle(Theme.green)
                        Text("No issues from enabled checks").foregroundStyle(Theme.secondary)
                        if let repository, !(store.ignoredChecks[repository.id] ?? []).isEmpty {
                            Button("Restore ignored checks") { store.restoreChecks(for: repository) }
                                .buttonStyle(RepositoryButtonStyle())
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    CodexScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(findings) { finding in
                                Button { selectedID = finding.id } label: {
                                    HStack(alignment: .top, spacing: 12) {
                                        Image(systemName: finding.symbol)
                                            .foregroundStyle(finding.severity == .blocked ? Theme.red : Theme.amber)
                                            .frame(width: 18).padding(.top, 2)
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(repository == nil ? name(for: finding) : finding.title)
                                                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.primary)
                                            Text(repository == nil ? finding.title : finding.evidence)
                                                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                                                .lineLimit(2).help(finding.evidence)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                                    }
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(selected?.id == finding.id ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(name(for: finding)): \(finding.title)")
                                .accessibilityAddTraits(selected?.id == finding.id ? .isSelected : [])
                            }
                        }
                        .padding(8)
                    }
                }
            }
            Panel {
                Text("Issue details").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } content: {
                if let selected, let target = store.repositories.first(where: { $0.id == selected.repositoryID }) {
                    RepositoryFindingDetail(finding: selected, repository: target)
                        .id(selected.id)
                } else {
                    Text("Select a finding to inspect its evidence and actions.")
                        .foregroundStyle(Theme.secondary).padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func name(for finding: RepositoryFinding) -> String {
        store.repositories.first { $0.id == finding.repositoryID }?.name ?? URL(fileURLWithPath: finding.repositoryID).lastPathComponent
    }
}

private struct RepositoryFindingDetail: View {
    @EnvironmentObject private var store: RepositoryStore
    let finding: RepositoryFinding
    let repository: RepositorySnapshot
    @State private var selectedPaths = Set<String>()
    @State private var message = ""
    @State private var license = "MIT"
    @State private var copyrightHolder = ""
    @State private var customLicense = ""

    private var actions: [RepositoryActionDefinition] {
        finding.actionIDs.compactMap { store.actionCatalog.action($0) }
    }

    var body: some View {
        CodexScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("\(finding.category.rawValue) · \(repository.name)", systemImage: finding.symbol)
                    .font(.system(size: 11.5)).foregroundStyle(Theme.amber)
                Text(finding.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.primary)
                Text(finding.evidence).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                ForEach(actions) { action in
                    actionInputs(action)
                    Button {
                        store.prepareAction(action.id, repositories: [repository], input: RepositoryActionInput(
                            paths: selectedPaths.sorted(), message: message, copyrightHolder: copyrightHolder,
                            license: license, customLicense: customLicense))
                    } label: {
                        Label(action.title, systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(RepositoryButtonStyle())
                    .disabled(store.isActing || store.isScanning || store.isFetching || !inputReady(action))
                }
                if actions.isEmpty {
                    Text("This finding has no automated action.").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
                Button("Open repository in Finder") { NSWorkspace.shared.open(repository.url) }
                    .buttonStyle(.plain).foregroundStyle(Theme.blue)
                Divider().overlay(Theme.border)
                Button("Ignore this check for this repository") { store.ignore(finding) }
                    .buttonStyle(.plain).foregroundStyle(Theme.secondary).font(.system(size: 11))
                Text("Ignore affects this check only. Other repository checks remain active.")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.subtle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .onAppear { selectedPaths = Set(repository.changes.map(\.path)) }
        .onChange(of: repository.changes) { _, changes in
            selectedPaths.formIntersection(Set(changes.map(\.path)))
        }
    }

    @ViewBuilder
    private func actionInputs(_ action: RepositoryActionDefinition) -> some View {
        switch action.inputKind {
        case .none: EmptyView()
        case .commit:
            VStack(alignment: .leading, spacing: 10) {
                Text("Files to include").font(.system(size: 12, weight: .medium))
                HStack {
                    Button("Select all") { selectedPaths = Set(repository.changes.map(\.path)) }
                    Button("Clear") { selectedPaths.removeAll() }
                }.buttonStyle(.plain).foregroundStyle(Theme.blue).font(.system(size: 11))
                ForEach(repository.changes) { change in
                    Toggle(isOn: Binding(get: { selectedPaths.contains(change.path) }, set: { included in
                        if included { selectedPaths.insert(change.path) } else { selectedPaths.remove(change.path) }
                    })) {
                        Text(change.path).font(.system(size: 11.5)).lineLimit(2).help(change.path)
                    }.toggleStyle(.checkbox)
                }
                TextField("Commit message", text: $message).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Commit message")
                Text("Selected files include their full current contents. Review the preview before committing.")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
        case .license:
            VStack(alignment: .leading, spacing: 10) {
                Picker("License", selection: $license) {
                    Text("MIT").tag("MIT")
                    Text("Custom text").tag("Custom")
                }.pickerStyle(.menu)
                if license == "MIT" {
                    TextField("Copyright holder", text: $copyrightHolder).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Copyright holder")
                } else {
                    TextEditor(text: $customLicense).font(.system(size: 11.5, design: .monospaced))
                        .frame(minHeight: 180).accessibilityLabel("Custom license text")
                }
                Text("Choose the license intentionally, or ignore this check for private projects.")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
        }
    }

    private func inputReady(_ action: RepositoryActionDefinition) -> Bool {
        switch action.inputKind {
        case .none: return true
        case .commit: return !selectedPaths.isEmpty && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .license: return !(license == "MIT" ? copyrightHolder : customLicense).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

struct RepositoryActionSheet: View {
    @EnvironmentObject private var store: RepositoryStore
    @State private var selectedPreviewID: UUID?

    private var session: RepositoryActionSession? { store.actionSession }
    private var selected: RepositoryActionPreview? {
        session?.previews.first { $0.id == selectedPreviewID } ?? session?.previews.first
    }
    private var action: RepositoryActionDefinition? { session.flatMap { store.actionCatalog.action($0.actionID) } }
    private var readyCount: Int {
        session?.previews.filter { $0.plan != nil && $0.error == nil && !$0.completed }.count ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(action?.title ?? "Action preview").font(.system(size: 19, weight: .semibold))
                    Text(store.isDemo ? "Demo preview · no repositories will be changed" : "Review each repository before applying the action")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                if store.isActing { ProgressView().controlSize(.small) }
            }.padding(22)
            Divider().overlay(Theme.border)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    if session?.isPreparing == true { Text("Preparing previews…").foregroundStyle(Theme.secondary).padding(12) }
                    CodexScrollView {
                        LazyVStack(spacing: 5) {
                            ForEach(session?.previews ?? []) { row in
                                Button { selectedPreviewID = row.id } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(row.repositoryName).font(.system(size: 12.5, weight: .medium))
                                        Text(row.status).font(.system(size: 11)).foregroundStyle(row.error == nil ? Theme.secondary : Theme.red)
                                            .lineLimit(3)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                    .background(selected?.id == row.id ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
                                }.buttonStyle(.plain)
                            }
                        }.padding(10)
                    }
                }.frame(width: 210)
                Rectangle().fill(Theme.border).frame(width: 1)
                VStack(alignment: .leading, spacing: 12) {
                    if let row = selected {
                        Text(row.repositoryURL.abbreviatedPath).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                            .textSelection(.enabled)
                        if let error = row.error {
                            Label(error, systemImage: "exclamationmark.circle").foregroundStyle(Theme.red)
                                .font(.system(size: 12)).textSelection(.enabled)
                        }
                        if let plan = row.plan {
                            Text(plan.title).font(.system(size: 16, weight: .semibold))
                            Text(plan.explanation).foregroundStyle(Theme.secondary).font(.system(size: 12))
                            if let path = plan.outputPath {
                                Label("New file: \(path)", systemImage: "doc.badge.plus").font(.system(size: 12)).foregroundStyle(Theme.green)
                                TextEditor(text: Binding(get: {
                                    store.actionSession?.previews.first { $0.id == row.id }?.plan?.content ?? ""
                                }, set: { store.editPreview(row.id, content: $0) }))
                                .font(.system(size: 12, design: .monospaced))
                                .scrollContentBackground(.hidden).background(Theme.field)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .accessibilityLabel("Draft for \(row.repositoryName)")
                                .disabled(store.isActing || row.completed || session?.finished == true)
                            } else {
                                CodexScrollView {
                                    Text(plan.preview).font(.system(size: 11.5, design: .monospaced))
                                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                }
                                .background(Theme.field, in: RoundedRectangle(cornerRadius: 6))
                            }
                        } else { Spacer() }
                        if row.completed {
                            Label(row.status, systemImage: "checkmark.circle").font(.system(size: 12)).foregroundStyle(Theme.green)
                        }
                    } else {
                        ProgressView("Preparing the first preview…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }.frame(maxHeight: .infinity)
            Divider().overlay(Theme.border)
            HStack(spacing: 12) {
                if session?.finished == true {
                    Text("\(session?.previews.filter(\.completed).count ?? 0) completed · \(session?.previews.filter { $0.error != nil }.count ?? 0) blocked or failed")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                } else {
                    Text("\(readyCount) ready · \(session?.previews.filter { $0.error != nil }.count ?? 0) blocked")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Button(session?.finished == true ? "Done" : "Close") { store.dismissAction() }
                    .buttonStyle(RepositoryButtonStyle()).disabled(store.isActing)
                if action?.mutatesRepository == true || session?.actionID == "git.refresh" {
                    Button(readyCount > 1 ? "Apply to \(readyCount) repositories" : (action?.applyTitle ?? "Apply")) { store.executeAction() }
                        .buttonStyle(RepositoryButtonStyle()).keyboardShortcut(.defaultAction)
                        .disabled(store.isDemo || store.isActing || store.isScanning || store.isFetching || readyCount == 0 || session?.finished == true)
                }
            }.padding(20)
        }
        .foregroundStyle(Theme.primary).background(Theme.background)
        .frame(width: 860, height: 650)
        .interactiveDismissDisabled(store.isActing)
    }
}
