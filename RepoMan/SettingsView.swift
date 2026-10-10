import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: RepositoryStore
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var section: SettingsSection = .issueChecks
    @State private var search = ""
    @State private var excludedPath = ""
    @State private var configuringCheck: RepositoryCheck?

    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                sidebar
                    .frame(width: min(326, max(240, geometry.size.width * 0.195)))
                Rectangle().fill(Theme.border).frame(width: 1)
                CodexScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        header
                        if query.isEmpty {
                            if section == .general { generalSettings }
                            else if section == .providers { AgentBridgeSettingsView() }
                            else { issueChecks }
                        } else {
                            if matchesGeneral { generalSettings }
                            if matches("Providers OpenRouter API key token models") { AgentBridgeSettingsView() }
                            issueChecks
                            if !matchesGeneral && !matches("Providers OpenRouter API key token models") && matchingGroups.isEmpty {
                                ContentUnavailableView.search(text: query)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .frame(maxWidth: 800, alignment: .leading)
                    .padding(.horizontal, 48)
                    .padding(.top, 24)
                    .padding(.bottom, 40)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .id(query.isEmpty ? section.rawValue : "search")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
            }
        }
        .font(.system(size: 14))
        .foregroundStyle(Theme.primary)
        .background(Theme.background)
        .background { SettingsWindowToolbar() }
        .preferredColorScheme(.dark)
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ToolbarActionButton(symbol: "chevron.left", title: "Back to repositories") {
                    dismissWindow()
                }
                .keyboardShortcut(.cancelAction)
                .help("Back to repositories (Esc)")
                .accessibilityLabel("Back to repositories")
                .accessibilityIdentifier("settings.back")
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .sheet(item: $configuringCheck) { check in
            ModelCheckSettingsView(check: check) {
                configuringCheck = nil
                section = .providers
                search = ""
            }
            .environmentObject(store)
        }
        .onAppear { showRequestedCheck() }
        .onChange(of: store.requestedSettingsCheckID) { _, _ in showRequestedCheck() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(.system(size: 20, weight: .semibold))
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 16)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.secondary)
                TextField("Search settings", text: $search)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search settings")
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Theme.selection, in: Capsule())
            .padding(.horizontal, 12)
            .padding(.bottom, 20)

            ForEach(SettingsSection.allCases) { item in
                Button {
                    search = ""
                    section = item
                } label: {
                    Label(item.rawValue, systemImage: item.symbol)
                        .labelStyle(.titleAndIcon)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .frame(height: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(query.isEmpty && section == item ? Theme.selection : .clear,
                            in: RoundedRectangle(cornerRadius: 10))
                .accessibilityAddTraits(query.isEmpty && section == item ? .isSelected : [])
                .padding(.horizontal, 12)
                .padding(.bottom, 2)
            }

            Spacer(minLength: 24)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.sidebar)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(query.isEmpty ? section.rawValue : "Search results")
                .font(.system(size: 28, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            if !query.isEmpty || section == .issueChecks {
                Text("Choose which issues appear across all repositories.")
                    .foregroundStyle(Theme.secondary)
                Text("Changes save automatically. Active repairs continue.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
            } else if section == .providers {
                Text("Connect providers used by configurable issue checks.")
                    .foregroundStyle(Theme.secondary)
            } else {
                Text("Choose the folder RepoMan monitors for repositories.")
                    .foregroundStyle(Theme.secondary)
            }
        }
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            settingsGroup("App updates") {
                AppUpdateStatusView().padding(20)
            }
            settingsGroup("Repositories") {
                HStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Monitored folder")
                        Text("Visible Git repositories directly inside this folder appear in RepoMan.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(store.folder?.abbreviatedPath ?? "No folder selected")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .help(store.folder?.path ?? "Choose a folder to start monitoring repositories.")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Change…") { store.chooseFolder() }
                        .controlSize(.regular)
                        .accessibilityLabel("Change monitored folder")
                }
                .padding(18)
            }
            settingsGroup("Path blacklist") {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Repositories in these folders are excluded, including through symlinks. Changes save and apply automatically.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondary)
                    Text("Use a folder name such as .archived to match anywhere, or a full path to exclude a specific folder and everything beneath it. Relative paths start at the monitored folder.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(store.excludedRepositoryPaths, id: \.self) { path in
                        HStack {
                            Text(path)
                                .font(.system(size: 13, design: .monospaced))
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .help(path)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button { store.removeExcludedRepositoryPath(path) } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove excluded path \(path)")
                        }
                    }
                    HStack {
                        TextField(".archived or ~/repos/archived", text: $excludedPath)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { addExcludedPath() }
                            .accessibilityLabel("Excluded repository path")
                            .accessibilityIdentifier("settings.excludedPath")
                        Button("Add") { addExcludedPath() }
                            .disabled(excludedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityLabel("Add excluded repository path")
                    }
                }
                .padding(18)
            }
        }
    }

    private func addExcludedPath() {
        store.addExcludedRepositoryPath(excludedPath)
        excludedPath = ""
    }

    private var matchesGeneral: Bool {
        matches("General App updates GitHub version Check for Updates Update Restart Repositories Monitored folder Visible Git repositories directly inside this folder Path blacklist excluded paths folders symlinks .archived "
                + (store.folder?.path ?? "") + " " + store.excludedRepositoryPaths.joined(separator: " "))
    }

    private var matchingGroups: [SettingsCheckGroup] {
        SettingsCheckGroup.all.filter { !checks(in: $0).isEmpty }
    }

    private func checks(in group: SettingsCheckGroup) -> [RepositoryCheck] {
        store.issueCatalog.checks.filter { check in
            group.categories.contains(check.category)
                && !RepositoryIssueCatalog.syncCheckIDs.contains(check.id)
                && matches("Issue checks \(group.title) \(check.title) \(check.settingsDescription)")
        }
    }

    private func matches(_ text: String) -> Bool {
        query.isEmpty || text.localizedStandardContains(query)
    }

    private var issueChecks: some View {
        ForEach(matchingGroups) { group in
            let checks = checks(in: group)
            settingsGroup(group.title) {
                VStack(spacing: 0) {
                    ForEach(checks) { check in
                        HStack(spacing: 12) {
                            Toggle(isOn: Binding(
                                get: { !store.disabledChecks.contains(check.id) },
                                set: { store.setCheck(check.id, enabled: $0) }
                            )) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(check.title)
                                    Text(check.settingsDescription)
                                        .font(.system(size: 13))
                                        .foregroundStyle(Theme.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .tint(Theme.blue)
                            .accessibilityLabel(check.title)
                            .accessibilityHint(check.settingsDescription)
                            .accessibilityIdentifier("settings.check.\(check.id)")
                            if check.configurationKind != nil {
                                Button { configuringCheck = check } label: {
                                    Image(systemName: "gearshape").foregroundStyle(Theme.secondary)
                                        .frame(width: 28, height: 28)
                                }
                                .buttonStyle(.plain)
                                .help("Configure \(check.title)")
                                .accessibilityLabel("Configure \(check.title)")
                                .accessibilityIdentifier("settings.configure.\(check.id)")
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .frame(minHeight: 54)

                        if check.id != checks.last?.id {
                            Rectangle().fill(Theme.border).frame(height: 1)
                                .padding(.horizontal, 18)
                        }
                    }
                }
            }
        }
    }

    private func showRequestedCheck() {
        guard let id = store.requestedSettingsCheckID else { return }
        store.requestedSettingsCheckID = nil
        configuringCheck = store.issueCatalog.checks.first { $0.id == id && $0.configurationKind != nil }
        section = .issueChecks
        search = ""
    }

    private func settingsGroup<Content: View>(_ title: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .accessibilityAddTraits(.isHeader)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14).stroke(Theme.border, lineWidth: 1)
                }
        }
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case issueChecks = "Issue checks"
    case providers = "Providers"
    var id: Self { self }
    var symbol: String {
        switch self { case .general: "gearshape"; case .issueChecks: "checkmark.circle"; case .providers: "key" }
    }
}

private struct SettingsCheckGroup: Identifiable {
    let title: String
    let categories: [IssueCategory]
    var id: String { title }

    static let all: [Self] = [
        Self(title: "Git", categories: [.git]),
        Self(title: "Repository files", categories: [.documentation, .setup]),
        Self(title: "Automated checks (CI)", categories: [.ci]),
        Self(title: "Inspection", categories: [.inspection])
    ]
}

/// Settings scenes override the scene toolbar style with AppKit's centered preferences style.
/// Apply the unified style after the native window attaches so navigation sits by the traffic lights.
private struct SettingsWindowToolbar: NSViewRepresentable {
    func makeNSView(context: Context) -> ToolbarView { ToolbarView() }
    func updateNSView(_ view: ToolbarView, context: Context) {}

    final class ToolbarView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                self?.window?.toolbarStyle = .unified
            }
        }
    }
}

private extension RepositoryCheck {
    var settingsDescription: String {
        switch id {
        case "git.changes": "Files have been edited, added, or deleted, but those changes have not been saved in a Git commit."
        case "git.diverged": "Your current branch and the branch it tracks (its upstream) each have commits the other is missing."
        case "git.push": "Your current branch has commits that have not been sent to the branch it tracks, usually on a remote such as GitHub."
        case "git.pull": "The branch your current branch tracks has new commits that are not yet in your local branch."
        case "git.staleBranches": "Local branches whose latest commit is over 90 days old. Excludes main, master, and branches in use in any working folder."
        case "git.worktrees": "Additional working folders for the same repository, often used to work on different branches."
        case "git.oldStashes": "Uncommitted changes saved for later with Git stash at least 30 days ago. The age limit can be changed in .repoman.json."
        case "git.unfinishedOperation": "Git has unresolved conflicts or an unfinished merge, rebase, or similar operation, or a commit is checked out without a branch (detached HEAD)."
        case "git.unpublishedBranches": "Local branches not in use in any working folder have commits that are absent from every fetched remote branch."
        case "git.upstream": "Your current branch has no branch configured to track, or a local branch tracks a branch that can no longer be found. Applies to repositories with remotes."
        case "git.checkoutIntegrity": "A nested Git repository (submodule) is missing or at an unexpected commit, or a Git LFS file contains a placeholder instead of its actual content."
        case "files.mergeMarkers": "Git conflict markers such as <<<<<<< remain in tracked source files, indicating a merge conflict may not have been fully resolved."
        case "files.readme": "No README was found in the repository's top-level folder to explain the project and how to use it."
        case "docs.readmeConsistency": "Checks README layout and clarity against optimize-readme. Uses your RepoMan Codex login for clarity judgments by default; configure the service with the cog."
        case "files.gitignore": "No .gitignore was found in the top-level folder to tell Git which local files to leave untracked."
        case "files.license": "No LICENSE, LICENCE, or COPYING file was found in the top-level folder to explain how others may use the project."
        case "files.generatedTracked": "Git tracks files usually created by tools, such as dependency folders, caches, or build output."
        case "files.secrets": "Tracked files contain patterns that look like private keys or access tokens. Checks current files, not Git history, and never displays secret values."
        case "files.oversized": "Git tracks files larger than 10 MiB, which can make the repository heavy to download. The size limit can be changed in .repoman.json."
        case "files.projectReferences": "Project or workflow settings refer to local files or folders that cannot be found, such as workspace packages, scripts, or action files."
        case "dependencies.manager": "The declared package manager, lockfiles, or automated install commands are missing or inconsistent, so dependencies may be installed differently."
        case "dependencies.safeguards": "Dependency settings lack required protections, such as waiting seven days before using new releases or blocking risky package sources and install scripts."
        case "dependencies.lockfile": "A dependency list has no matching lockfile tracked by Git. Lockfiles record exact package versions so installs can be repeated."
        case "dependencies.sources": "Dependencies use Git repositories, URLs, local paths, custom package registries, or exceptions to the release-age rule that need review."
        case "dependencies.lockfileDrift": "The project's dependency list and lockfile specify different packages or versions, so installs may not match the declared requirements."
        case "dependencies.runtime": "Node.js or Python version requirements conflict across project settings, version files, containers, or automated checks."
        case "github.description": "The description on GitHub differs from the marked tagline in the README published on the default branch. Local README edits do not count."
        case "github.privateVisibility": "A GitHub repository whose name starts with private- must have private visibility. Public and internal repositories with this prefix need attention."
        case "website.online": "Checks HTTPS availability for the tsilva.eu domains declared in .repo-metadata.toml. DNS, TLS, HTTP errors, and redirects outside the declared domains need attention."
        case "website.sentry": "Visits the public site in an isolated browser and looks for accepted Sentry events. Configuration alone stays unverified; no synthetic errors are sent."
        case "website.analytics": "Looks for Google Analytics collection in an isolated browser. Queued beacons and configured tags stay unverified until successful delivery is observed. Consent is not changed."
        case "website.cloudflare": "Checks for Cloudflare's CF-Ray header on the requested domain's HTTPS response, including canonical redirects."
        case "docs.brokenLinks": "Documentation links or agent skill references point to local files that cannot be found. External websites are not checked."
        case "notebooks.hygiene": "Jupyter notebooks contain saved errors or more than 256 KiB of output by default. Enable this per repository in .repoman.json; cells are never run."
        case "ci.failing": "Automated GitHub checks, such as builds or tests, have failed on published commits."
        case "ci.coverage": "No GitHub Actions workflow was found that routinely builds, tests, lints, or checks types."
        case "ci.mutableActions": "GitHub Actions uses external actions or workflows pinned to a changeable tag or branch instead of an exact commit, or Docker actions without an exact image digest."
        case "ci.suppressedFailures": "A build, test, lint, or type-check step is configured to allow errors, so the workflow may pass even when that check fails."
        case "ci.security": "A GitHub Actions workflow uses potentially unsafe event text, broad write permissions, or pull-request code in a privileged run."
        case "inspection.remote": "Fetching remote updates failed. Local status is still available, but remote commit counts may be out of date."
        case "inspection.comparison": "Git could not compare your current branch with the branch it tracks, so commits to push or pull are unknown."
        case "inspection.files": "RepoMan could not read the repository's top-level folder, so it cannot tell whether required files are missing."
        default: "Show these issues across all repositories."
        }
    }
}
