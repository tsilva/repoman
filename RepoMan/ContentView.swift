import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject private var updater = AppUpdateController.shared
    @EnvironmentObject private var store: RepositoryStore
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var search = ""
    @State private var showsRepositoryChanges = false
    @AppStorage("repositoryFilter") private var repositoryFilter: RepositoryFilter = .all
    @AppStorage("repositorySort") private var repositorySort: RepositorySort = .name
    @AppStorage("repositorySortAscending") private var sortAscending = true
    @AppStorage("sidebarWidth") private var sidebarWidth = 340.0
    @AppStorage("sidebarVisible") private var sidebarVisible = true
    @FocusState private var searchFocused: Bool

    @State private var toolbarLeadingInset: CGFloat = 96

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
            .background {
                TitleBarWindowZoom()
                ToolbarPositionReader { leadingInset in
                    if abs(toolbarLeadingInset - leadingInset) > 0.5 {
                        toolbarLeadingInset = leadingInset
                    }
                }
            }
            .toolbar {
                // Keep the native hosting view attached throughout window resize animations.
                ToolbarItem(id: "repository-topbar", placement: .navigation) {
                    topBar(sidebarWidth: visibleSidebarWidth)
                        // AppKit changes the space for window controls in fullscreen.
                        .frame(width: max(0, geometry.size.width - toolbarLeadingInset - 8))
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        .font(.system(size: 12))
        .containerBackground(.clear, for: .window)
        .toolbarBackground(Theme.topBar.opacity(reduceTransparency ? 1 : 0.98), for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .onAppear { store.start() }
        .alert("RepoMan Update", isPresented: Binding(get: { updater.errorMessage != nil },
                                                     set: { if !$0 { updater.errorMessage = nil } })) {
            Button("OK", role: .cancel) { updater.errorMessage = nil }
        } message: { Text(updater.errorMessage ?? "") }
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
                if !sidebarVisible { AppUpdateButton() }
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
                ToolbarActionButton(icon: .ide, title: "Open in Cursor") {
                    store.openSelectedRepositoryInCursor()
                }
                .disabled(store.selectedRepository == nil)
                .accessibilityIdentifier("open-in-cursor-button")
                ToolbarActionButton(
                    icon: .diff,
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
                Picker("Filter repositories", selection: $repositoryFilter) {
                    ForEach(RepositoryFilter.allCases, id: \.self) { filter in
                        Text(filter.rawValue).tag(filter)
                        if filter == .all || filter == .needsAttention {
                            Divider()
                        }
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
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
                title: "Refresh all repositories",
                isRotating: store.isFetching || store.isScanning,
                foregroundColor: Theme.primary
            ) {
                store.refreshAll()
            }
            .disabled(store.folder == nil || store.isFetching || store.isScanning)
            .accessibilityIdentifier("refresh-all-repositories-button")
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
                || !store.issues(in: $0).isEmpty
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

            repositoryList

            if updater.available != nil {
                HStack(spacing: 12) {
                    AppUpdateButton()
                    VStack(alignment: .leading, spacing: 3) {
                        Text(updater.phase ?? "Update available")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.primary)
                        Text(updater.phase == nil ? "Install \(updater.available?.version ?? "") and restart" : "RepoMan will reopen automatically")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
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
    private var repositoryList: some View {
        let repositories = filteredRepositories
        if !repositories.isEmpty {
            NativeRepositoryList(
                rows: repositories.map {
                    RepositoryListRow(repository: $0, isLoading: store.loadingRepositoryIDs.contains($0.id),
                                      checkProgress: store.repositoryCheckProgress[$0.id])
                },
                selectedPath: store.selectedPath,
                statusCounts: { store.issueStatusCounts(in: $0) },
                onSelect: { store.select($0) }
            )
        } else {
            CodexScrollView {
                VStack(spacing: 0) {
                    if !store.repositories.isEmpty {
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
                    } else if store.folder != nil, !store.isScanning {
                        Text("No Git repositories found in this folder.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondary)
                            .padding(20)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
        }
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

/// Handle the custom toolbar like a title bar, retaining the window's previous size.
private struct TitleBarWindowZoom: NSViewRepresentable {
    func makeNSView(context: Context) -> ZoomView { ZoomView() }
    func updateNSView(_ view: ZoomView, context: Context) {}

    static func dismantleNSView(_ view: ZoomView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class ZoomView: NSView {
        private var eventMonitor: Any?
        private var restoreFrame: NSRect?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            restoreFrame = nil
            guard window != nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self else { return event }
                return self.handleDoubleClick(event)
            }
        }

        func stopMonitoring() {
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            eventMonitor = nil
        }

        private func handleDoubleClick(_ event: NSEvent) -> NSEvent? {
            guard event.clickCount == 2, let window, event.window === window,
                  !window.styleMask.contains(.fullScreen), window.styleMask.contains(.resizable),
                  event.locationInWindow.y >= window.contentLayoutRect.maxY,
                  let screen = window.screen else { return event }

            // Toolbar controls and traffic-light buttons keep their normal clicks.
            if let frameView = window.contentView?.superview {
                func containsControl(_ view: NSView) -> Bool {
                    if view is TitleBarControlRegion.ControlView,
                       view.bounds.contains(view.convert(event.locationInWindow, from: nil)) {
                        return true
                    }
                    return view.subviews.contains(where: containsControl)
                }
                if containsControl(frameView) { return event }
                var hitView = frameView.hitTest(frameView.convert(event.locationInWindow, from: nil))
                while let view = hitView {
                    if view is NSControl { return event }
                    hitView = view.superview
                }
            }
            let target = screen.visibleFrame
            let current = window.frame
            let fillsScreen = abs(current.minX - target.minX) < 1
                && abs(current.minY - target.minY) < 1
                && abs(current.width - target.width) < 1
                && abs(current.height - target.height) < 1
            if fillsScreen, let restoreFrame {
                window.setFrame(window.constrainFrameRect(restoreFrame, to: screen), display: true, animate: true)
                self.restoreFrame = nil
            } else {
                restoreFrame = current
                window.setFrame(target, display: true, animate: true)
            }
            return nil
        }
    }
}

/// SwiftUI toolbar buttons share one hosting view, so mark their individual hit regions.
private struct TitleBarControlRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> ControlView { ControlView() }
    func updateNSView(_ view: ControlView, context: Context) {}

    final class ControlView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Keep the header aligned with the detail column using the native toolbar's origin.
private struct ToolbarPositionReader: NSViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> PositionView {
        let view = PositionView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: PositionView, context: Context) {
        view.onChange = onChange
        view.scheduleMeasurement()
    }

    final class PositionView: NSView {
        var onChange: ((CGFloat) -> Void)?
        private var measurementPending = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let window {
                for name in [NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification,
                             NSWindow.didExitFullScreenNotification] {
                    NotificationCenter.default.addObserver(self, selector: #selector(windowLayoutChanged),
                                                           name: name, object: window)
                }
            }
            scheduleMeasurement()
        }

        override func layout() {
            super.layout()
            scheduleMeasurement()
        }

        @objc private func windowLayoutChanged(_ notification: Notification) {
            scheduleMeasurement()
        }

        func scheduleMeasurement() {
            guard !measurementPending else { return }
            measurementPending = true
            // Read after AppKit lays out the toolbar, outside the SwiftUI update pass.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.measurementPending = false
                guard let window = self.window else { return }
                guard let toolbarView = window.toolbar?.items.first(where: {
                    $0.itemIdentifier.rawValue == "repository-topbar"
                })?.view, let toolbarWindow = toolbarView.window, toolbarView.bounds.width > 0 else {
                    // On fullscreen exit, AppKit may hide the wider item until it fits
                    // beside the window controls again. The content probe stays attached.
                    if !window.styleMask.contains(.fullScreen) { self.onChange?(96) }
                    return
                }
                // In fullscreen AppKit hosts the toolbar in a separate window.
                let origin = toolbarWindow.convertPoint(toScreen: toolbarView.convert(toolbarView.bounds.origin, to: nil))
                self.onChange?(max(0, origin.x - window.frame.minX))
            }
        }
    }
}

private struct SidebarBackground: View {
    var body: some View {
        Theme.sidebar
            .allowsHitTesting(false)
    }
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
        .background { TitleBarControlRegion() }
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

/// Row data changes with scans and selection, never with the scroll offset.
private struct RepositoryListRow: Equatable {
    let repository: RepositorySnapshot
    let isLoading: Bool
    let checkProgress: RepositoryCheckProgress?
}

/// NSTableView recycles a small set of independently hosted rows. Scrolling no
/// longer changes the SwiftUI layout graph for the entire repository sidebar.
private struct NativeRepositoryList: NSViewRepresentable {
    let rows: [RepositoryListRow]
    let selectedPath: String?
    let statusCounts: (RepositorySnapshot) -> [RepositoryIssueStatus: Int]
    let onSelect: (RepositorySnapshot) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        let scroller = RepositoryScroller()
        scroller.setAccessibilityLabel("Vertical scroll bar")
        scrollView.verticalScroller = scroller
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets.bottom = 12

        let table = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("repository"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.rowHeight = 52
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.setAccessibilityLabel("Repositories")
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        scrollView.documentView = table
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let table = scrollView.documentView as? NSTableView else { return }
        let coordinator = context.coordinator
        let previous = coordinator.parent
        coordinator.parent = self
        coordinator.synchronizingSelection = true
        defer { coordinator.synchronizingSelection = false }
        if previous.rows.map({ $0.repository.id }) != rows.map({ $0.repository.id }) || table.numberOfRows != rows.count {
            table.reloadData()
        } else {
            let visible = table.rows(in: table.visibleRect)
            for index in visible.location..<NSMaxRange(visible) where rows.indices.contains(index) {
                if let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? RepositoryCell {
                    coordinator.configure(cell, row: index)
                }
            }
        }
        let selectedIndex = rows.firstIndex { $0.repository.id == selectedPath }
        let selection = selectedIndex.map { IndexSet(integer: $0) } ?? IndexSet()
        if table.selectedRowIndexes != selection { table.selectRowIndexes(selection, byExtendingSelection: false) }
    }

    final class RepositoryCell: NSTableCellView {
        let hosting = NSHostingView(rootView: AnyView(EmptyView()))
        var data: RepositoryListRow?
        var statusCounts: [RepositoryIssueStatus: Int] = [:]
        var isSelected = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            hosting.sizingOptions = []
            hosting.translatesAutoresizingMaskIntoConstraints = false
            addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
                hosting.topAnchor.constraint(equalTo: topAnchor),
                hosting.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: NativeRepositoryList
        var synchronizingSelection = false

        init(parent: NativeRepositoryList) { self.parent = parent }

        func numberOfRows(in tableView: NSTableView) -> Int { parent.rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("RepositoryCell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? RepositoryCell
                ?? RepositoryCell(frame: .zero)
            cell.identifier = identifier
            configure(cell, row: row)
            return cell
        }

        func configure(_ cell: RepositoryCell, row: Int) {
            let data = parent.rows[row]
            let counts = parent.statusCounts(data.repository)
            let isSelected = data.repository.id == parent.selectedPath
            guard cell.data != data || cell.statusCounts != counts || cell.isSelected != isSelected else { return }
            cell.data = data
            cell.statusCounts = counts
            cell.isSelected = isSelected
            cell.hosting.rootView = AnyView(
                RepositoryRow(repository: data.repository, statusCounts: counts,
                              isLoading: data.isLoading, checkProgress: data.checkProgress,
                              isSelected: isSelected) { [weak self] in
                    self?.parent.onSelect(data.repository)
                }
                .padding(.horizontal, 14)
                .font(.system(size: 12))
                .preferredColorScheme(.dark)
            )
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !synchronizingSelection, let table = notification.object as? NSTableView,
                  parent.rows.indices.contains(table.selectedRow) else { return }
            parent.onSelect(parent.rows[table.selectedRow].repository)
        }
    }
}

/// AppKit owns thumb tracking and scroll offsets; drawing keeps the sidebar's
/// thin, trackless indicator without publishing offsets into SwiftUI.
private final class RepositoryScroller: NSScroller {
    private var isHovered = false
    private var hoverTracking: NSTrackingArea?
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    // Overlay scrollers draw the track separately from the knob.
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        guard knobProportion < 1 else { return }
        let knob = rect(for: .knob)
        let thumb = NSRect(x: knob.midX - Theme.scrollbarWidth / 2, y: knob.minY,
                           width: Theme.scrollbarWidth, height: knob.height)
        NSColor(isHovered || hitPart == .knob ? Theme.scrollbarHover : Theme.scrollbar).setFill()
        NSBezierPath(roundedRect: thumb, xRadius: Theme.scrollbarWidth / 2,
                     yRadius: Theme.scrollbarWidth / 2).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(tracking)
        hoverTracking = tracking
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }
}

private struct RepositoryRow: View {
    @State private var isHovered = false
    private let decorationInset: CGFloat = 12
    let repository: RepositorySnapshot
    let statusCounts: [RepositoryIssueStatus: Int]
    let isLoading: Bool
    let checkProgress: RepositoryCheckProgress?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                    Text(repository.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(repository.name)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    RepositoryIssueStatusBadges(counts: statusCounts)
                    }
                    if !repository.branch.isEmpty {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 10, weight: .medium))
                            Text(repository.branch)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(repository.branch)
                            Spacer(minLength: 8)
                            RepositoryGitStatus(repository: repository)
                                .padding(.trailing, statusCounts.values.contains(where: { $0 > 0 }) ? 6 : 0)
                        }
                        .layoutPriority(-1)
                        .font(.system(size: 11.5))
                        .foregroundStyle(isSelected ? Theme.primary.opacity(0.85) : Theme.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(-1)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 8, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .background {
                ZStack {
                    Rectangle()
                        .fill(isSelected ? Theme.selection : (isHovered ? Theme.control : .clear))
                    RepositoryScanProgressBackground(isLoading: isLoading, progress: checkProgress)
                        .id(repository.id)
                }
                .padding(.trailing, decorationInset)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .overlay {
            if isLoading { NativeTooltip(text: scanningHelp) }
        }
        .accessibilityValue(activityDescription)
        .accessibilityLabel("\(repository.name), \(repository.branch), \(repository.ahead ?? 0) to push, \(repository.behind ?? 0) to pull, \(repository.changedFileCount) changed files, \(repository.staleBranches.count) stale branches, \(repository.worktrees.count) worktrees")
        .overlay(alignment: .bottom) {
            if !isSelected {
                Rectangle()
                    .fill(Theme.border.opacity(0.55))
                    .frame(height: 1)
                    .padding(.horizontal, decorationInset)
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

private struct RepositoryScanProgressBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedFraction: Double
    let isLoading: Bool
    let progress: RepositoryCheckProgress?

    init(isLoading: Bool, progress: RepositoryCheckProgress?) {
        self.isLoading = isLoading
        self.progress = progress
        _displayedFraction = State(initialValue: min(1, max(0, progress?.fraction ?? 0)))
    }

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(Theme.primary.opacity(0.08))
                // Fetching and queued inspections have no completed checks yet.
                // Keep a visible marker without inventing completed progress.
                .frame(width: min(geometry.size.width, max(4, geometry.size.width * displayedFraction)))
            .clipShape(Rectangle())
            .opacity(isLoading ? 1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: isLoading)
        }
        .onChange(of: progress?.fraction) { _, fraction in
            // Keep the last width while a completed scan fades out.
            if isLoading, let fraction { displayedFraction = min(1, max(0, fraction)) }
        }
        .onChange(of: isLoading) { _, isLoading in
            if isLoading { displayedFraction = min(1, max(0, progress?.fraction ?? 0)) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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

enum RepositoryToolbarIcon: Shape {
    case ide
    case diff

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch self {
        case .ide:
            path.addRoundedRect(in: CGRect(x: 1, y: 2, width: 18, height: 16), cornerSize: CGSize(width: 2, height: 2))
            // Window chrome and a project sidebar make the code glyph read as an IDE.
            path.move(to: CGPoint(x: 1, y: 6))
            path.addLine(to: CGPoint(x: 19, y: 6))
            path.move(to: CGPoint(x: 6, y: 6))
            path.addLine(to: CGPoint(x: 6, y: 18))
            path.move(to: CGPoint(x: 11, y: 9))
            path.addLine(to: CGPoint(x: 9, y: 12))
            path.addLine(to: CGPoint(x: 11, y: 15))
            path.move(to: CGPoint(x: 14, y: 9))
            path.addLine(to: CGPoint(x: 16, y: 12))
            path.addLine(to: CGPoint(x: 14, y: 15))
        case .diff:
            // A folded document with explicit added and removed lines.
            path.move(to: CGPoint(x: 12, y: 1))
            for point in [CGPoint(x: 4, y: 1), CGPoint(x: 4, y: 19), CGPoint(x: 17, y: 19),
                          CGPoint(x: 17, y: 6), CGPoint(x: 12, y: 1), CGPoint(x: 12, y: 6),
                          CGPoint(x: 17, y: 6)] {
                path.addLine(to: point)
            }
            path.move(to: CGPoint(x: 6.5, y: 10))
            path.addLine(to: CGPoint(x: 10.5, y: 10))
            path.move(to: CGPoint(x: 8.5, y: 8))
            path.addLine(to: CGPoint(x: 8.5, y: 12))
            path.move(to: CGPoint(x: 12.5, y: 10))
            path.addLine(to: CGPoint(x: 14.5, y: 10))
            path.move(to: CGPoint(x: 6.5, y: 15))
            path.addLine(to: CGPoint(x: 10.5, y: 15))
            path.move(to: CGPoint(x: 12.5, y: 15))
            path.addLine(to: CGPoint(x: 14.5, y: 15))
        }
        return path.applying(CGAffineTransform(scaleX: rect.width / 20, y: rect.height / 20))
            .applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }
}

struct ToolbarActionButton: View {
    var symbol: String = ""
    var icon: RepositoryToolbarIcon? = nil
    let title: String
    var isRotating = false
    var isLoading = false
    var foregroundColor: Color = Theme.secondary
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Group {
                if isLoading {
                    ProgressView().controlSize(.mini)
                } else if let icon {
                    icon.stroke(style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .regular))
                        .symbolEffect(.rotate.clockwise, isActive: isRotating)
                }
            }
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background { TitleBarControlRegion() }
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
    var submitsOnReturn = true
    var isEditable = true

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, onSubmit: onSubmit, submitsOnReturn: submitsOnReturn) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false

        let editor = NSTextView(frame: scrollView.contentView.bounds)
        editor.isRichText = false
        editor.isEditable = isEditable
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
        context.coordinator.submitsOnReturn = submitsOnReturn
        guard let editor = scrollView.documentView as? NSTextView else { return }
        editor.isEditable = isEditable
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
        var submitsOnReturn: Bool
        init(text: Binding<String>, onSubmit: @escaping () -> Void, submitsOnReturn: Bool) {
            self.text = text
            self.onSubmit = onSubmit
            self.submitsOnReturn = submitsOnReturn
        }
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard submitsOnReturn, commandSelector == #selector(NSResponder.insertNewline(_:)),
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
