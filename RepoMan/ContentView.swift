import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: RepositoryStore
    @State private var search = ""
    @State private var repositoryFilter: RepositoryFilter = .all
    @State private var repositorySort: RepositorySort = .name
    @State private var sortAscending = true
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
                            Theme.sidebar
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
            }
            .background(Theme.background)
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
        .toolbarBackground(Theme.sidebar, for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .onAppear { store.start() }
        .sheet(isPresented: Binding(get: { store.actionSession != nil }, set: { if !$0 { store.dismissAction() } })) {
            RepositoryActionSheet().environmentObject(store)
        }
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
                    branchMenu(repository)
                    Text(repository.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(repository.name)
                        .frame(maxWidth: 260, alignment: .leading)
                        .layoutPriority(1)
                } else {
                    Text("RepoMan")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                }
                Spacer(minLength: 16)
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .help(statusText)
                ToolbarActionButton(
                    symbol: "arrow.clockwise",
                    title: "Refresh repository",
                    isRotating: store.isFetching || store.isScanning
                ) {
                    store.refreshSelected()
                }
                .disabled(store.selectedRepository == nil || store.isFetching || store.isScanning || store.isActing)
                ToolbarActionButton(symbol: "folder", title: "Open in Finder") {
                    if let repository = store.selectedRepository {
                        NSWorkspace.shared.open(repository.url)
                    }
                }
                .disabled(store.selectedRepository == nil)
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
        }
    }

    private func branchMenu(_ repository: RepositorySnapshot) -> some View {
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
            Label(repository.branch, systemImage: "arrow.triangle.branch")
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .labelStyle(.titleAndIcon)
        .foregroundStyle(Theme.primary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.trailing, 18)
        .frame(width: min(180, ceil((repository.branch as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: 12)]
        ).width) + 76), height: 28, alignment: .leading)
        // Native Menu normalizes its label, so draw the single chevron outside it.
        .overlay(alignment: .trailing) {
            Image(systemName: "chevron.down")
                .font(.system(size: 9))
                .foregroundStyle(Theme.secondary)
                .padding(.trailing, 3)
                .allowsHitTesting(false)
        }
        .help("Current branch: \(repository.branch)")
        .accessibilityLabel("Current branch")
        .accessibilityValue(repository.branch)
    }

    private var statusText: String {
        if store.isFetching { return "Checking remotes…" }
        if store.isScanning { return "Checking repositories…" }
        guard let repository = store.selectedRepository else { return "" }
        let minutes = Int(Date().timeIntervalSince(repository.checkedAt) / 60)
        return minutes < 1 ? "Last checked just now" : "Last checked \(minutes) min ago"
    }

    private var filteredRepositories: [RepositorySnapshot] {
        repositorySort.repositories(
            store.repositories,
            filter: repositoryFilter == .needsAttention ? .all : repositoryFilter,
            search: search,
            ascending: sortAscending
        ).filter { repositoryFilter != .needsAttention || !store.findings(in: $0).isEmpty }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Theme.secondary)
                    TextField("Search repositories…", text: $search)
                        .textFieldStyle(.plain)
                        .foregroundStyle(Theme.primary)
                        .font(.system(size: 11.5))
                        .focused($searchFocused)
                        .accessibilityLabel("Search repositories")
                }
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

            if store.isScanning, !store.scanProgress.isEmpty {
                Text(store.scanProgress)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.subtle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
            }

            CodexScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredRepositories) { repository in
                        RepositoryRow(repository: repository, issueCount: store.findings(in: repository).count,
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
            .padding(.horizontal, 24)
            .frame(height: 40)
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.border).frame(height: 1)
            }
        }
        .frame(maxHeight: .infinity)
        .background(Theme.sidebar)
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
            .disabled(store.isActing)
        Button("Refresh All", systemImage: "arrow.clockwise") { store.refreshAll() }
            .disabled(store.folder == nil || store.isScanning || store.isFetching || store.isActing)
        Menu("Enabled checks") {
            ForEach(store.issueCatalog.checks) { check in
                Toggle(check.title, isOn: Binding(get: { !store.disabledChecks.contains(check.id) },
                                                 set: { store.setCheck(check.id, enabled: $0) }))
            }
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
            RepositoryDetail(repository: repository).id(repository.id)
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
    let issueCount: Int
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
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 10, weight: .medium))
                        Text(repository.branch)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(repository.branch)
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(isSelected ? Theme.primary.opacity(0.85) : Theme.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(-1)

                if issueCount > 0 {
                    Text(issueCount.formatted())
                        .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(Theme.amber)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Theme.control, in: Capsule())
                        .help("\(issueCount) findings from enabled checks")
                        .padding(.trailing, 8)
                }

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
        .accessibilityLabel("\(repository.name), \(repository.branch), \(issueCount) findings, \(repository.ahead ?? 0) to push, \(repository.behind ?? 0) to pull, \(repository.changedFileCount) changed files, \(repository.staleBranches.count) stale branches, \(repository.worktrees.count) worktrees")
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
private struct NativeTooltip: NSViewRepresentable {
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

    var body: some View {
        RepositoryIssuesView(repository: repository, checkID: nil)
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.background)
    }
}

private struct ToolbarActionButton: View {
    let symbol: String
    let title: String
    var isRotating = false
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
        .foregroundStyle(Theme.secondary)
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
    @State private var metrics = ScrollbarMetrics()
    @State private var dragStartOffset: CGFloat?
    @State private var isHovered = false

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
            metrics = newValue
        }
        .overlay(alignment: .trailing) {
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
                            .frame(width: 6, height: thumbHeight)
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
