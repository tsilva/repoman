import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: RepositoryStore
    @State private var search = ""

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                sidebar
                    .frame(width: min(560, max(500, geometry.size.width * 0.34)))
                Rectangle()
                    .fill(Theme.border.opacity(0.75))
                    .frame(width: 1)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Theme.background)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Choose Folder…", systemImage: "folder.badge.plus") {
                        store.chooseFolder()
                    }
                    Button("Refresh All", systemImage: "arrow.clockwise") {
                        store.refreshAll()
                    }
                    .disabled(store.folder == nil || store.isScanning || store.isFetching)
                    if let folder = store.folder {
                        Divider()
                        Button("Open Monitored Folder", systemImage: "folder") {
                            NSWorkspace.shared.open(folder)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.secondary)
                }
                .help("Repository options")
            }
        }
        .onAppear { store.start() }
    }

    private var filteredRepositories: [RepositorySnapshot] {
        guard !search.isEmpty else { return store.repositories }
        return store.repositories.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.secondary)
                TextField("Search repositories…", text: $search)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Theme.primary)
                    .font(.system(size: 14))
                    .accessibilityLabel("Search repositories")
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border, lineWidth: 1))
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            if let error = store.errorMessage, !store.repositories.isEmpty {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.amber)
                    .lineLimit(1)
                    .help(error)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 7)
            }

            if store.isScanning, !store.scanProgress.isEmpty {
                Text(store.scanProgress)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.subtle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 7)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredRepositories) { repository in
                        RepositoryRow(
                            repository: repository,
                            isSelected: store.selectedPath == repository.id
                        ) {
                            store.select(repository)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.visible)

            if store.folder != nil, store.repositories.isEmpty, !store.isScanning {
                Text("No Git repositories found in this folder.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                    .padding(20)
            }
        }
        .frame(maxHeight: .infinity)
        .background(Theme.sidebar)
    }

    @ViewBuilder
    private var detail: some View {
        if let repository = store.selectedRepository {
            RepositoryDetail(repository: repository)
        } else if store.isScanning {
            ProgressView("Scanning repositories…")
                .tint(Theme.blue)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive")
                .font(.system(size: 42, weight: .thin))
                .foregroundStyle(Theme.blue)
            Text(store.folder == nil ? "Monitor your repositories" : "No repositories to show")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Theme.primary)
            Text(store.errorMessage ?? "Choose a folder containing your Git repositories.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
            Button("Choose Folder…") { store.chooseFolder() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.blue)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RepositoryRow: View {
    let repository: RepositorySnapshot
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(repository.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 11, weight: .medium))
                        Text(repository.branch)
                            .lineLimit(1)
                    }
                    .font(.system(size: 12.5))
                    .foregroundStyle(isSelected ? Theme.primary.opacity(0.85) : Theme.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 10) {
                    if let ahead = repository.ahead, ahead > 0 {
                        StatusBadge(symbol: "arrow.up", value: ahead, color: Theme.blue, label: "commits to push")
                    }
                    if let behind = repository.behind, behind > 0 {
                        StatusBadge(symbol: "arrow.down", value: behind, color: Theme.green, label: "commits to pull")
                    }
                    if repository.changedFileCount > 0 {
                        StatusBadge(symbol: "circle.fill", value: repository.changedFileCount, color: Theme.amber, label: "changed files")
                    }
                    if !repository.staleBranches.isEmpty {
                        StatusBadge(symbol: "arrow.triangle.branch", value: repository.staleBranches.count, color: Theme.purple, label: "stale branches")
                    }
                    if !repository.worktrees.isEmpty {
                        StatusBadge(symbol: "square.on.square", value: repository.worktrees.count, color: Theme.cyan, label: "worktrees")
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .padding(.trailing, 12)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 16, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .frame(height: 67)
            .background(isSelected ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(repository.name), \(repository.branch), \(repository.ahead ?? 0) to push, \(repository.behind ?? 0) to pull, \(repository.changedFileCount) changed files, \(repository.staleBranches.count) stale branches, \(repository.worktrees.count) worktrees")
        .overlay(alignment: .bottom) {
            if !isSelected {
                Rectangle()
                    .fill(Theme.border.opacity(0.55))
                    .frame(height: 1)
                    .padding(.horizontal, 12)
            }
        }
    }
}

private struct StatusBadge: View {
    let symbol: String
    let value: Int
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: symbol == "circle.fill" ? 9 : 13, weight: .medium))
                .frame(width: 13)
                .foregroundStyle(color)
            Text(value.formatted())
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.primary)
        }
        .accessibilityLabel("\(value) \(label)")
        .help("\(value) \(label)")
    }
}

private struct RepositoryDetail: View {
    @EnvironmentObject private var store: RepositoryStore
    let repository: RepositorySnapshot
    @State private var showAllCommits = false
    @State private var showModified = true
    @State private var showUntracked = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            HStack(spacing: 16) {
                SummaryCard(title: "To push", value: repository.ahead, unit: repository.upstream == nil ? "no upstream" : "commits", symbol: "arrow.up", accent: Theme.blue)
                SummaryCard(title: "To pull", value: repository.behind, unit: repository.upstream == nil ? "no upstream" : "commits", symbol: "arrow.down", accent: Theme.green)
                SummaryCard(title: "Working tree", value: repository.changedFileCount, unit: "changed files", symbol: "circle.fill", accent: Theme.amber)
            }
            .frame(height: 128)

            HStack(spacing: 16) {
                SummaryCard(title: "Stale branches", value: repository.staleBranches.count, unit: nil, symbol: "arrow.triangle.branch", accent: Theme.purple, compact: true)
                    .help("Local branches inactive for 90 days, excluding main, master, and branches checked out in worktrees")
                SummaryCard(title: "Worktrees", value: repository.worktrees.count, unit: nil, symbol: "square.on.square", accent: Theme.cyan, compact: true)
                    .help("Additional linked Git worktrees")
            }
            .frame(height: 94)

            HStack(alignment: .top, spacing: 16) {
                commitsPanel
                workingTreePanel
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(repository.name)
                        .font(.system(size: 33, weight: .bold))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)
                    Text(repository.url.abbreviatedPath)
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 16)
                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 10) {
                        IconButton(symbol: "arrow.clockwise", label: "Refresh repository") {
                            store.refreshSelected()
                        }
                        .disabled(store.isFetching || store.isScanning)
                        IconButton(symbol: "folder", label: "Open in Finder") {
                            NSWorkspace.shared.open(repository.url)
                        }
                    }
                    Text(statusText)
                        .font(.system(size: 12.5))
                        .foregroundStyle(repository.fetchError == nil ? Theme.secondary : Theme.amber)
                        .lineLimit(1)
                        .help(repository.fetchError ?? "Repository status checked locally")
                }
            }
            HStack(spacing: 14) {
                Menu {
                    Text("Current branch: \(repository.branch)")
                    if !repository.staleBranches.isEmpty {
                        Divider()
                        Text("Stale branches")
                        ForEach(repository.staleBranches, id: \.self) { branch in
                            Text(branch)
                        }
                    }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "arrow.triangle.branch")
                        Text(repository.branch).lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.leading, 6)
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.primary)
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(Theme.control, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                if let remote = repository.remoteDisplayName, let remoteURL = repository.remoteWebURL {
                    Button {
                        NSWorkspace.shared.open(remoteURL)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "network")
                                .font(.system(size: 17))
                                .foregroundStyle(Theme.primary)
                            Text(remote)
                                .lineLimit(1)
                                .foregroundStyle(Theme.secondary)
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.secondary)
                        }
                        .font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                    .help("Open remote repository")
                }
            }
        }
    }

    private var statusText: String {
        if store.isFetching { return "Checking remotes…" }
        if repository.fetchError != nil { return "Remote unavailable · local status shown" }
        let minutes = Int(Date().timeIntervalSince(repository.checkedAt) / 60)
        return minutes < 1 ? "Checked just now" : "Checked \(minutes) min ago"
    }

    private var commitsPanel: some View {
        Panel {
            HStack {
                Text("Commits")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                Spacer()
                if repository.commits.count > 4 {
                    Button(showAllCommits ? "Show less" : "View all") {
                        showAllCommits.toggle()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.blue)
                    .font(.system(size: 13))
                }
            }
        } content: {
            if !repository.detailsLoaded {
                ProgressView("Loading commits…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if repository.commits.isEmpty {
                EmptyPanelText(text: "No commits yet")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(repository.commits.prefix(showAllCommits ? 8 : 5))) { commit in
                            HStack(alignment: .center, spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(commit.hash)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(Theme.secondary)
                                    Text(commit.subject)
                                        .font(.system(size: 13))
                                        .foregroundStyle(Theme.primary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Text(commit.relativeDate)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.secondary)
                                    .lineLimit(1)
                            }
                            .frame(minHeight: 62)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(Theme.border.opacity(0.55)).frame(height: 1)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
    }

    private var workingTreePanel: some View {
        Panel {
            Text("Working tree")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } content: {
            if !repository.detailsLoaded {
                ProgressView("Loading file changes…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if repository.changes.isEmpty {
                EmptyPanelText(text: "Working tree is clean")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ChangeGroup(
                            title: "Modified",
                            changes: repository.changes.filter { $0.kind == .modified },
                            isExpanded: $showModified
                        )
                        ChangeGroup(
                            title: "Untracked",
                            changes: repository.changes.filter { $0.kind == .untracked },
                            isExpanded: $showUntracked
                        )
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
            }
        }
    }
}

private struct IconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.primary)
                .frame(width: 44, height: 40)
                .background(Theme.control, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}

private struct SummaryCard: View {
    let title: String
    let value: Int?
    let unit: String?
    let symbol: String
    let accent: Color
    var compact = false

    var body: some View {
        HStack(alignment: compact ? .center : .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: compact ? 24 : 25, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: compact ? 49 : 54, height: compact ? 49 : 54)
                .background(accent.opacity(0.13), in: Circle())
            VStack(alignment: .leading, spacing: compact ? 2 : 4) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                Text(value.map(String.init) ?? "—")
                    .font(.system(size: compact ? 29 : 32, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                if let unit, !compact {
                    Text(unit)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(compact ? 18 : 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(accent.opacity(0.065), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(accent.opacity(0.26), lineWidth: 1))
    }
}

private struct Panel<Header: View, Content: View>: View {
    @ViewBuilder let header: Header
    @ViewBuilder let content: Content

    init(@ViewBuilder header: () -> Header, @ViewBuilder content: () -> Content) {
        self.header = header()
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .frame(height: 54)
            Rectangle().fill(Theme.border.opacity(0.7)).frame(height: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
    }
}

private struct EmptyPanelText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Theme.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ChangeGroup: View {
    let title: String
    let changes: [WorkingTreeChange]
    @Binding var isExpanded: Bool

    var body: some View {
        if !changes.isEmpty {
            VStack(spacing: 0) {
                Button { isExpanded.toggle() } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        Text(title)
                            .font(.system(size: 14, weight: .medium))
                        Text("\(changes.count)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.secondary)
                            .padding(.horizontal, 8)
                            .frame(height: 25)
                            .background(Theme.control, in: Capsule())
                        Spacer()
                    }
                    .foregroundStyle(Theme.primary)
                    .frame(height: 38)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if isExpanded {
                    ForEach(changes) { change in
                        HStack(spacing: 10) {
                            Image(systemName: "doc")
                                .font(.system(size: 17, weight: .light))
                                .foregroundStyle(Theme.blue)
                                .frame(width: 20)
                            Text(change.path)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 3)
                            if let added = change.added, added > 0 {
                                Text("+\(added)")
                                    .foregroundStyle(Theme.green)
                            }
                            if let removed = change.removed, removed > 0 {
                                Text("−\(removed)")
                                    .foregroundStyle(Theme.red)
                            }
                        }
                        .font(.system(size: 12.5, design: .monospaced))
                        .frame(height: 43)
                        .padding(.leading, 27)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(Theme.border.opacity(0.48)).frame(height: 1)
                        }
                    }
                }
            }
        }
    }
}
