import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: RepositoryStore
    @State private var search = ""
    @State private var showsRepositoryChanges = false
    @AppStorage("repositoryFilter") private var repositoryFilter: RepositoryFilter = .all
    @AppStorage("repositorySort") private var repositorySort: RepositorySort = .name
    @AppStorage("repositorySortAscending") private var sortAscending = true
    @AppStorage("sidebarWidth") private var sidebarWidth = 340.0
    @AppStorage("sidebarVisible") private var sidebarVisible = true
    @FocusState private var searchFocused: Bool

    private let toolbarLeadingInset: CGFloat = 96

    var body: some View {
        GeometryReader { geometry in
            let resizeHandleWidth: CGFloat = 9
            let maximumSidebarWidth = min(520, max(280, geometry.size.width - 800 - resizeHandleWidth))
            let visibleSidebarWidth = min(maximumSidebarWidth, max(280, sidebarWidth))
            HStack(spacing: 0) {
                if sidebarVisible {
                    sidebar
                        .frame(width: visibleSidebarWidth)
                    SidebarResizeHandle(width: visibleSidebarWidth, maximumWidth: maximumSidebarWidth) { width in
                        sidebarWidth = min(maximumSidebarWidth, max(280, width))
                    }
                    .frame(width: resizeHandleWidth)
                    .background {
                        HStack(spacing: 0) {
                            SidebarBackground()
                            Theme.background
                        }
                        .overlay {
                            Rectangle()
                                .fill(Theme.border.opacity(0.75))
                                .frame(width: 1)
                        }
                        .ignoresSafeArea(.container, edges: .top)
                    }
                }
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background, ignoresSafeAreaEdges: [])
            }
            .toolbar {
                // Recreate the native item on width changes so AppKit updates its minimum size.
                ToolbarItem(id: "repository-topbar-\(Int(geometry.size.width))", placement: .navigation) {
                    topBar(sidebarWidth: visibleSidebarWidth)
                        // The native toolbar reserves the leading space for window controls.
                        .frame(width: max(0, geometry.size.width - toolbarLeadingInset - 8))
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        .font(.system(size: 12))
        .containerBackground(.clear, for: .window)
        .toolbarBackground(.thickMaterial, for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .onAppear { store.start() }

    }

    private func topBar(sidebarWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                ToolbarActionButton(
                    symbol: "sidebar.left",
                    title: sidebarVisible ? "Hide sidebar" : "Show sidebar"
                ) {
                    sidebarVisible.toggle()
                }
                .accessibilityValue(sidebarVisible ? "Visible" : "Hidden")
                if sidebarVisible {
                    Spacer(minLength: 12)
                }
            }
            .frame(width: sidebarVisible ? max(0, sidebarWidth - toolbarLeadingInset) : 34)
            .padding(.trailing, sidebarVisible ? 9 : 12)

            HStack(spacing: 12) {
                if let repository = store.selectedRepository {
                    Text(repository.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(repository.name)
                        .frame(width: min(260, ceil((repository.name as NSString).size(
                            withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]
                        ).width)), alignment: .leading)
                        .layoutPriority(1)
                    if !repository.branch.isEmpty {
                        Text("/")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondary)
                            .accessibilityHidden(true)
                        branchMenu(repository)
                    }
                } else {
                    Text("RepoMan")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                }
                Spacer(minLength: 16)
                ToolbarActionButton(symbol: "folder", title: "Open in Finder") {
                    if let repository = store.selectedRepository {
                        NSWorkspace.shared.open(repository.url)
                    }
                }
                .disabled(store.selectedRepository == nil)
                ToolbarActionButton(symbol: "terminal", title: "Open in Terminal") {
                    store.openSelectedRepositoryInTerminal()
                }
                .disabled(store.selectedRepository == nil)
                ToolbarActionButton(
                    symbol: "doc.text.magnifyingglass",
                    title: showsRepositoryChanges ? "Hide uncommitted changes" : "Show uncommitted changes",
                    foregroundColor: showsRepositoryChanges ? Theme.primary : Theme.secondary
                ) {
                    showsRepositoryChanges.toggle()
                }
                .disabled(store.selectedRepository == nil)
                .accessibilityValue(showsRepositoryChanges ? "Visible" : "Hidden")
                .accessibilityIdentifier("repository-changes-button")
                Rectangle().fill(Theme.border).frame(width: 1, height: 20)
                ToolbarIconMenu(symbol: "ellipsis", title: "Repository options", value: "") {
                    repositoryOptions
                }
            }
            .padding(.leading, sidebarVisible ? 24 : 0)
        }
        .frame(height: 36)
    }

    private var repositoryListMenus: some View {
        HStack(spacing: 6) {
            ToolbarIconMenu(
                symbol: "line.3.horizontal.decrease",
                title: "Filter repositories",
                value: repositoryFilter.rawValue,
                isActive: repositoryFilter != .all
            ) {
                ForEach(RepositoryFilter.allCases, id: \.self) { filter in
                    Button {
                        repositoryFilter = filter
                    } label: {
                        menuChoice(filter.rawValue, isSelected: repositoryFilter == filter)
                    }
                    if filter == .all || filter == .needsAttention {
                        Divider()
                    }
                }
            }
            ToolbarIconMenu(
                symbol: "arrow.up.arrow.down",
                title: "Sort repositories",
                value: "\(repositorySort.rawValue), \(sortAscending ? "ascending" : "descending")"
            ) {
                ForEach(RepositorySort.allCases, id: \.self) { sort in
                    Button {
                        if repositorySort != sort {
                            repositorySort = sort
                            sortAscending = sort == .name
                        }
                    } label: {
                        menuChoice(sort.rawValue, isSelected: repositorySort == sort)
                    }
                }
                Divider()
                Button { sortAscending = true } label: {
                    menuChoice("Ascending", isSelected: sortAscending)
                }
                Button { sortAscending = false } label: {
                    menuChoice("Descending", isSelected: !sortAscending)
                }
            }
            ToolbarActionButton(
                symbol: "arrow.clockwise",
                title: "Refresh repository",
                isRotating: store.isFetching || store.isScanning,
                foregroundColor: Theme.primary
            ) {
                store.refreshSelected()
            }
            .disabled(store.selectedRepository == nil || store.isFetching || store.isScanning)
        }
    }

    private func branchMenu(_ repository: RepositorySnapshot) -> some View {
        let hasBranches = !repository.staleBranches.isEmpty

        return HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .fixedSize()
            Text(repository.branch)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            if hasBranches {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize()
                    .padding(.leading, 2)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.primary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.trailing, hasBranches ? 3 : 0)
        .frame(width: min(180, ceil((repository.branch as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: 12)]
        ).width) + (hasBranches ? 46 : 22)), height: 28, alignment: .leading)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Current branch")
        .accessibilityValue(repository.branch)
        .accessibilityHidden(hasBranches)
        // Cover the entire label, including its padding and chevron, with one native control.
        .overlay {
            if hasBranches {
                BranchMenuTrigger(branch: repository.branch, staleBranches: repository.staleBranches)
            }
        }
    }

    private var filteredRepositories: [RepositorySnapshot] {
        repositorySort.repositories(
            store.repositories,
            filter: .all,
            search: search,
            ascending: sortAscending
        ).filter {
            repositoryFilter != .needsAttention || store.loadingRepositoryIDs.contains($0.id)
                || !store.findings(in: $0).isEmpty
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Theme.secondary)
                    TextField("Search repos...", text: $search)
                        .textFieldStyle(.plain)
                        .foregroundStyle(Theme.primary)
                        .focused($searchFocused)
                        .accessibilityLabel("Search repositories")
                }
                .font(.system(size: 11.5))
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(searchFocused ? Theme.secondary : Theme.border, lineWidth: 1))
                repositoryListMenus
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 12)

            if let error = store.errorMessage, !store.repositories.isEmpty {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.amber)
                    .lineLimit(2)
                    .help(error)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
            }

            CodexScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredRepositories) { repository in
                        RepositoryRow(repository: repository, statusCounts: store.issueStatusCounts(in: repository),
                                      isLoading: store.loadingRepositoryIDs.contains(repository.id),
                                      checkProgress: store.repositoryCheckProgress[repository.id],
                                      isSelected: store.selectedPath == repository.id) { store.select(repository) }
                    }
                    if filteredRepositories.isEmpty, !store.repositories.isEmpty {
                        Text("No matching repositories")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondary)
                            .padding(20)
                        if repositoryFilter != .all {
                            Button("Clear filter") { repositoryFilter = .all }
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.blue)
                                .padding(.bottom, 12)
                        }
                    } else if store.folder != nil, store.repositories.isEmpty, !store.isScanning {
                        Text("No Git repositories found in this folder.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondary)
                            .padding(20)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }

            HStack(spacing: 8) {
                Button { store.chooseFolder() } label: {
                    Text(store.folder?.abbreviatedPath ?? "Choose a folder…")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help("Choose monitored folder")

                SettingsLink {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Settings (⌘,)")
                .accessibilityLabel("Open settings")
            }
            .padding(.leading, 24)
            .padding(.trailing, 16)
            .frame(height: 40)
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.border).frame(height: 1)
            }
        }
        .frame(maxHeight: .infinity)
        .background { SidebarBackground() }
    }

    @ViewBuilder
    private func menuChoice(_ title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    @ViewBuilder
    private var repositoryOptions: some View {
        Button("Choose Folder…", systemImage: "folder.badge.plus") { store.chooseFolder() }
        Button("Refresh All", systemImage: "arrow.clockwise") { store.refreshAll() }
            .disabled(store.folder == nil || store.isScanning || store.isFetching)
        SettingsLink {
            Label("Settings…", systemImage: "gearshape")
        }
        if let repository = store.selectedRepository, !(store.ignoredChecks[repository.id] ?? []).isEmpty {
            Button("Restore ignored checks") { store.restoreChecks(for: repository) }
        }
        if let repository = store.selectedRepository,
           let remoteURL = repository.remoteWebURL {
            Divider()
            Button("Open Remote Repository", systemImage: "network") {
                NSWorkspace.shared.open(remoteURL)
            }
        }
        if let folder = store.folder {
            Divider()
            Button("Open Monitored Folder", systemImage: "folder") {
                NSWorkspace.shared.open(folder)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let repository = store.selectedRepository {
            if repository.branch.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                RepositoryDetail(repository: repository, showsRepositoryChanges: $showsRepositoryChanges).id(repository.id)
            }
        } else if store.isScanning {
            ProgressView("Scanning repositories…")
                .tint(Theme.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "externaldrive")
                .font(.system(size: 28, weight: .thin))
                .foregroundStyle(Theme.secondary)
            Text(store.folder == nil ? "Monitor your repositories" : "No repositories to show")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.primary)
            Text(store.errorMessage ?? "Choose a folder containing your Git repositories.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
            Button("Choose Folder…") { store.chooseFolder() }
                .buttonStyle(RepositoryButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SidebarBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            if reduceTransparency {
                Theme.sidebar
            } else {
                SidebarVisualEffect()
                    .overlay(Theme.sidebar.opacity(0.45))
            }
        }
        .allowsHitTesting(false)
    }
}

private struct SidebarVisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        // Sample the desktop behind the window instead of the opaque detail pane.
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct BranchMenuTrigger: NSViewRepresentable {
    let branch: String
    let staleBranches: [String]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator,
                              action: #selector(Coordinator.showMenu(_:)))
        button.isBordered = false
        button.isTransparent = true
        button.setAccessibilityLabel("Current branch")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(withTitle: "Current branch: \(branch)", action: nil, keyEquivalent: "").isEnabled = false
        if !staleBranches.isEmpty {
            menu.addItem(.separator())
            menu.addItem(withTitle: "Stale branches", action: nil, keyEquivalent: "").isEnabled = false
            for title in staleBranches {
                menu.addItem(withTitle: title, action: nil, keyEquivalent: "").isEnabled = false
            }
        }
        button.menu = menu
        button.toolTip = "Current branch: \(branch)"
        button.setAccessibilityValue(branch)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: proposal.height ?? 28)
    }

    final class Coordinator: NSObject {
        @objc func showMenu(_ sender: NSButton) {
            guard let window = sender.window else { return }
            // Screen coordinates increase upward, regardless of whether the button's view is flipped.
            let buttonFrame = window.convertToScreen(sender.convert(sender.bounds, to: nil))
            sender.menu?.popUp(positioning: nil, at: NSPoint(x: buttonFrame.minX, y: buttonFrame.minY - 8),
                               in: nil)
        }
    }
}

private struct ToolbarIconMenu<Content: View>: View {
    let symbol: String
    let title: String
    let value: String
    var isActive = false
    @ViewBuilder let content: () -> Content
    @State private var isHovered = false

    var body: some View {
        Menu(content: content) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(isActive ? Theme.blue : Theme.secondary)
                .frame(width: 26, height: 26)
                .background(isHovered || isActive ? Theme.control : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovered = $0 }
        .help(value.isEmpty ? title : "\(title): \(value)")
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

private struct SidebarResizeHandle: NSViewRepresentable {
    let width: CGFloat
    let maximumWidth: CGFloat
    let onResize: (CGFloat) -> Void

    func makeNSView(context: Context) -> ResizeView {
        let view = ResizeView()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.splitter)
        view.setAccessibilityLabel("Resize repository sidebar")
        view.toolTip = "Drag to resize sidebar"
        return view
    }

    func updateNSView(_ view: ResizeView, context: Context) {
        view.sidebarWidth = width
        view.onResize = onResize
        view.setAccessibilityValue(width)
        view.setAccessibilityMinValue(280)
        view.setAccessibilityMaxValue(maximumWidth)
    }

    final class ResizeView: NSView {
        var sidebarWidth: CGFloat = 340
        var onResize: ((CGFloat) -> Void)?
        private var dragStart: (x: CGFloat, width: CGFloat)?

        override var mouseDownCanMoveWindow: Bool { false }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func mouseDown(with event: NSEvent) {
            dragStart = (event.locationInWindow.x, sidebarWidth)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let dragStart else { return }
            onResize?(dragStart.width + event.locationInWindow.x - dragStart.x)
        }

        override func mouseUp(with event: NSEvent) {
            mouseDragged(with: event)
            dragStart = nil
        }

        override func accessibilityPerformIncrement() -> Bool {
            onResize?(sidebarWidth + 20)
            return true
        }

        override func accessibilityPerformDecrement() -> Bool {
            onResize?(sidebarWidth - 20)
            return true
        }
    }
}

private struct RepositoryRow: View {
    @State private var isHovered = false
    let repository: RepositorySnapshot
    let statusCounts: [RepositoryIssueStatus: Int]
    let isLoading: Bool
    let checkProgress: RepositoryCheckProgress?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(repository.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(repository.name)
                    if !repository.branch.isEmpty || isLoading {
                        HStack(spacing: 6) {
                            if !repository.branch.isEmpty {
                                HStack(spacing: 5) {
                                    Image(systemName: "arrow.triangle.branch")
                                        .font(.system(size: 10, weight: .medium))
                                    Text(repository.branch)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .help(repository.branch)
                                }
                                .layoutPriority(-1)
                            }
                            if isLoading {
                                RepositoryActivityBadge(symbol: "magnifyingglass",
                                    value: checkProgress.map { "\($0.percentage)%" } ?? "…",
                                    color: Theme.blue, help: scanningHelp)
                            }
                        }
                        .font(.system(size: 11.5))
                        .foregroundStyle(isSelected ? Theme.primary.opacity(0.85) : Theme.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(-1)

                RepositoryIssueStatusBadges(counts: statusCounts)
                    .padding(.horizontal, 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 8, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .background(isSelected ? Theme.selection : (isHovered ? Theme.control : .clear), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityValue(activityDescription)
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

    private var scanningHelp: String {
        checkProgress.map {
            "Scanning for issues: \($0.percentage)%, \($0.completed) of \($0.total) checks completed, \($0.remaining) remaining"
        } ?? "Scanning for issues"
    }

    private var activityDescription: String {
        var descriptions = RepositoryIssueStatus.allCases.compactMap { status -> String? in
            guard let count = statusCounts[status], count > 0 else { return nil }
            return "\(status.title): \(count)"
        }
        if isLoading { descriptions.append(scanningHelp) }
        return descriptions.joined(separator: ", ")
    }
}

private struct RepositoryActivityBadge: View {
    let symbol: String
    let value: String
    let color: Color
    let help: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
            Text(value)
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(color.opacity(0.12), in: Capsule())
        .overlay { Capsule().strokeBorder(color.opacity(0.2), lineWidth: 1) }
        .fixedSize()
        .overlay { NativeTooltip(text: help) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help)
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
                .font(.system(size: symbol == "circle.fill" ? 8 : 11, weight: .medium))
                .frame(width: 13)
                .foregroundStyle(color)
            Text(value.formatted())
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.primary)
        }
        .accessibilityLabel("\(value) \(label)")
        .overlay {
            NativeTooltip(text: "\(value) \(label)")
        }
    }
}

/// Native tooltip tracking works for individual badges inside a SwiftUI button label.
struct NativeTooltip: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> TooltipView {
        let view = TooltipView()
        view.toolTip = text
        return view
    }

    func updateNSView(_ view: TooltipView, context: Context) {
        view.toolTip = text
    }

    final class TooltipView: NSView {
        // Tooltip tracking is independent of hit testing; clicks still select the row.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

private struct RepositoryDetail: View {
    let repository: RepositorySnapshot
    @Binding var showsRepositoryChanges: Bool

    var body: some View {
        RepositoryIssuesView(repository: repository, checkID: nil, showsRepositoryChanges: $showsRepositoryChanges)
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.background, ignoresSafeAreaEdges: [])
    }
}

struct ToolbarActionButton: View {
    let symbol: String
    let title: String
    var isRotating = false
    var foregroundColor: Color = Theme.secondary
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .regular))
                .symbolEffect(.rotate.clockwise, isActive: isRotating)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(foregroundColor)
        .background(isHovered ? Theme.control : .clear, in: RoundedRectangle(cornerRadius: 6))
        .onHover { isHovered = $0 }
        .accessibilityLabel(title)
        .help(title)
    }
}

struct RepositoryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.primary)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(configuration.isPressed ? Theme.selection : Theme.control, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}

struct Panel<Header: View, Content: View>: View {
    @ViewBuilder let header: Header
    @ViewBuilder let content: Content

    init(@ViewBuilder header: () -> Header, @ViewBuilder content: () -> Content) {
        self.header = header()
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 18)
                .frame(height: 46)
            Rectangle().fill(Theme.border.opacity(0.7)).frame(height: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border, lineWidth: 1))
    }
}

/// Keeps native scrolling while using the thin, trackless indicators of the Codex theme.
struct CodexScrollView<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var position = ScrollPosition()
    // Keep a stable reference without observing it here. Scroll offsets must only
    // invalidate the indicator, not rebuild the scroll container every frame.
    @State private var scrollbar = ScrollbarState()

    var body: some View {
        ScrollView {
            content
        }
        // `.hidden` can still show native scrollers when macOS is set to Always.
        .scrollIndicators(.never)
        .scrollPosition($position)
        .onScrollGeometryChange(for: ScrollbarMetrics.self) { geometry in
            ScrollbarMetrics(
                contentHeight: geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom,
                viewportHeight: geometry.containerSize.height,
                offset: geometry.contentOffset.y + geometry.contentInsets.top,
                topInset: geometry.contentInsets.top
            )
        } action: { _, newValue in
            scrollbar.metrics = newValue
        }
        .overlay(alignment: .trailing) {
            CodexScrollbar(state: scrollbar, position: $position)
        }
    }
}

private final class ScrollbarState: ObservableObject {
    @Published var metrics = ScrollbarMetrics()
}

private struct CodexScrollbar: View {
    @ObservedObject var state: ScrollbarState
    @Binding var position: ScrollPosition
    @State private var dragStartOffset: CGFloat?
    @State private var isHovered = false

    private var metrics: ScrollbarMetrics { state.metrics }

    var body: some View {
        if metrics.maximumOffset > 0 {
            GeometryReader { geometry in
                let trackHeight = max(0, geometry.size.height - 8)
                let thumbHeight = min(trackHeight, max(28, trackHeight * metrics.viewportHeight / metrics.contentHeight))
                let travel = trackHeight - thumbHeight
                let thumbOffset = travel * metrics.progress

                ZStack(alignment: .top) {
                    Color.clear
                    Capsule()
                        .fill(isHovered || dragStartOffset != nil ? Theme.scrollbarHover : Theme.scrollbar)
                        .frame(width: Theme.scrollbarWidth, height: thumbHeight)
                        .offset(y: thumbOffset)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard travel > 0 else { return }
                            if dragStartOffset == nil {
                                let startY = value.startLocation.y - 4
                                let isOnThumb = startY >= thumbOffset && startY <= thumbOffset + thumbHeight
                                dragStartOffset = isOnThumb
                                    ? metrics.clampedOffset
                                    : min(metrics.maximumOffset, max(0, (startY - thumbHeight / 2) / travel * metrics.maximumOffset))
                            }
                            scroll(to: (dragStartOffset ?? 0) + value.translation.height / travel * metrics.maximumOffset)
                        }
                        .onEnded { _ in dragStartOffset = nil }
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Vertical scroll bar")
                .accessibilityValue("\(Int(metrics.progress * 100)) percent")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: scroll(to: metrics.clampedOffset + metrics.viewportHeight * 0.8)
                    case .decrement: scroll(to: metrics.clampedOffset - metrics.viewportHeight * 0.8)
                    @unknown default: break
                    }
                }
            }
            .frame(width: 12)
            .padding(.trailing, 2)
        }
    }

    private func scroll(to offset: CGFloat) {
        position.scrollTo(y: min(metrics.maximumOffset, max(0, offset)) - metrics.topInset)
    }
}

private struct ScrollbarMetrics: Equatable {
    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0
    var offset: CGFloat = 0
    var topInset: CGFloat = 0

    var maximumOffset: CGFloat { max(0, contentHeight - viewportHeight) }
    var clampedOffset: CGFloat { min(maximumOffset, max(0, offset)) }
    var progress: CGFloat { maximumOffset > 0 ? clampedOffset / maximumOffset : 0 }
}

/// Plain-text editing that fits wrapped content; the surrounding panel handles scrolling.
struct CodexTextEditor: NSViewRepresentable {
    @Binding var text: String
    let accessibilityLabel: String
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, onSubmit: onSubmit) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false

        let editor = NSTextView(frame: scrollView.contentView.bounds)
        editor.isRichText = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 12)
        editor.textColor = NSColor(Theme.primary)
        editor.insertionPointColor = NSColor(Theme.primary)
        editor.textContainerInset = NSSize(width: 4, height: 4)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.delegate = context.coordinator
        editor.setAccessibilityLabel(accessibilityLabel)
        editor.string = text
        scrollView.documentView = editor
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
        guard let editor = scrollView.documentView as? NSTextView else { return }
        if editor.string != text {
            editor.string = text
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            editor.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0,
              let editor = nsView.documentView as? NSTextView else { return nil }
        let font = editor.font ?? .systemFont(ofSize: 12)
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(
            width: max(1, width - editor.textContainerInset.width * 2), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = editor.textContainer?.lineFragmentPadding ?? 5
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let contentHeight = max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)
        let height = ceil(max(layout.defaultLineHeight(for: font), contentHeight) + editor.textContainerInset.height * 2)
        return CGSize(width: width, height: height)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onSubmit: () -> Void
        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            self.text = text
            self.onSubmit = onSubmit
        }
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)),
                  NSApp.currentEvent?.modifierFlags.contains(.shift) != true,
                  !textView.hasMarkedText() else { return false }
            text.wrappedValue = textView.string
            onSubmit()
            return true
        }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            text.wrappedValue = editor.string
        }
    }
}

/// A native popup that accepts the full width proposed by its SwiftUI container.
struct CodexPresetPicker: NSViewRepresentable {
    @Binding var selection: String
    let options: [(id: String, title: String)]

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.font = .systemFont(ofSize: 12)
        button.controlSize = .large
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectPreset(_:))
        button.setAccessibilityLabel("Repair preset")
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        if button.itemArray.map({ $0.representedObject as? String }) != options.map({ Optional($0.id) }) ||
            button.itemTitles != options.map(\.title) {
            button.removeAllItems()
            for option in options {
                button.addItem(withTitle: option.title)
                button.lastItem?.representedObject = option.id
            }
        }
        if let index = options.firstIndex(where: { $0.id == selection }) { button.selectItem(at: index) }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: 30)
    }
    final class Coordinator: NSObject {
        var selection: Binding<String>
        init(selection: Binding<String>) { self.selection = selection }
        @objc func selectPreset(_ sender: NSPopUpButton) {
            if let id = sender.selectedItem?.representedObject as? String { selection.wrappedValue = id }
        }
    }
}
