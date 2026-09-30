import CryptoKit
import Foundation

public enum RepositoryActionInputKind: Sendable {
    case none, commit, license
}

public struct RepositoryActionInput: Sendable {
    public var paths: [String]
    public var message: String
    public var copyrightHolder: String
    public var license: String
    public var customLicense: String

    public init(paths: [String] = [], message: String = "", copyrightHolder: String = "",
                license: String = "MIT", customLicense: String = "") {
        self.paths = paths
        self.message = message
        self.copyrightHolder = copyrightHolder
        self.license = license
        self.customLicense = customLicense
    }
}

public struct RepositoryActionPlan: Identifiable, Sendable {
    public let id = UUID()
    public let repositoryURL: URL
    public let actionID: String
    public let title: String
    public let explanation: String
    public let preview: String
    public let outputPath: String?
    public var content: String?
    public let input: RepositoryActionInput
    public var isDemonstration = false
    fileprivate let state: ActionState

    public static func capture(at url: URL, actionID: String, title: String, explanation: String,
                               preview: String, outputPath: String? = nil, content: String? = nil,
                               input: RepositoryActionInput = .init()) throws -> RepositoryActionPlan {
        RepositoryActionPlan(repositoryURL: url, actionID: actionID, title: title, explanation: explanation,
                             preview: preview, outputPath: outputPath, content: content, input: input,
                             state: try ActionState.read(url, paths: input.paths))
    }
}

public struct RepositoryActionResult: Sendable {
    public let message: String
    public let snapshot: RepositorySnapshot

    public init(message: String, snapshot: RepositorySnapshot) {
        self.message = message
        self.snapshot = snapshot
    }
}

/// Both the UI and runner use registered metadata and handlers, never detector-specific screens.
public struct RepositoryActionDefinition: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let applyTitle: String
    public let inputKind: RepositoryActionInputKind
    public let supportsBatch: Bool
    public let mutatesRepository: Bool
    public let refreshRemoteBeforePreview: Bool
    public let prepare: @Sendable (URL, RepositoryActionInput) throws -> RepositoryActionPlan
    public let execute: @Sendable (RepositoryActionPlan) throws -> RepositoryActionResult

    public init(id: String, title: String, applyTitle: String, inputKind: RepositoryActionInputKind = .none,
                supportsBatch: Bool = false, mutatesRepository: Bool = true, refreshRemoteBeforePreview: Bool = false,
                prepare: @escaping @Sendable (URL, RepositoryActionInput) throws -> RepositoryActionPlan,
                execute: @escaping @Sendable (RepositoryActionPlan) throws -> RepositoryActionResult) {
        self.id = id
        self.title = title
        self.applyTitle = applyTitle
        self.inputKind = inputKind
        self.supportsBatch = supportsBatch
        self.mutatesRepository = mutatesRepository
        self.refreshRemoteBeforePreview = refreshRemoteBeforePreview
        self.prepare = prepare
        self.execute = execute
    }
}

public struct RepositoryActionCatalog: Sendable {
    public let actions: [RepositoryActionDefinition]

    public init(actions: [RepositoryActionDefinition] = Self.standardActions) {
        precondition(Set(actions.map(\.id)).count == actions.count, "Action IDs must be unique")
        self.actions = actions
    }

    public func action(_ id: String) -> RepositoryActionDefinition? { actions.first { $0.id == id } }

    public func prepare(_ id: String, at url: URL, input: RepositoryActionInput = .init()) throws -> RepositoryActionPlan {
        guard let action = action(id) else { throw RepositoryActionError.unavailable }
        return try withRepositoryLock(url) {
            if action.refreshRemoteBeforePreview { try GitRepositoryScanner.fetch(url) }
            let before = try ActionState.read(url, paths: input.paths)
            let plan = try action.prepare(url, input)
            guard plan.actionID == id, plan.repositoryURL.standardizedFileURL == url.standardizedFileURL else {
                throw RepositoryActionError.blocked("The prepared action does not match the requested repository or action.")
            }
            guard before == plan.state else {
                throw RepositoryActionError.blocked("The repository changed while preparing the preview. Try again.")
            }
            return plan
        }
    }

    public func execute(_ plan: RepositoryActionPlan) throws -> RepositoryActionResult {
        guard !plan.isDemonstration else { throw RepositoryActionError.blocked("Demo previews cannot change repositories.") }
        guard let action = action(plan.actionID) else { throw RepositoryActionError.unavailable }
        return try withRepositoryLock(plan.repositoryURL) {
            try Self.validate(plan)
            return try action.execute(plan)
        }
    }

    public func demonstrationPlan(_ id: String, snapshot: RepositorySnapshot, input: RepositoryActionInput) throws -> RepositoryActionPlan {
        guard let action = action(id) else { throw RepositoryActionError.unavailable }
        let path = ["files.readme": "README.md", "files.gitignore": ".gitignore", "files.license": "LICENSE"][id]
        let content: String?
        switch id {
        case "files.readme": content = Self.readmeDraft(snapshot)
        case "files.gitignore": content = Self.ignoreDraft(snapshot.rootFiles ?? [])
        case "files.license": content = input.license == "Custom" ? input.customLicense : Self.mitLicense(holder: input.copyrightHolder)
        default: content = nil
        }
        var plan = RepositoryActionPlan(repositoryURL: snapshot.url, actionID: id, title: action.title,
                                        explanation: "Illustrative preview. Demo mode never changes repositories.",
                                        preview: id == "git.commit" ? (["Commit: " + input.message] + input.paths).joined(separator: "\n") : "Review the proposed action for " + snapshot.name,
                                        outputPath: path, content: content, input: input,
                                        state: ActionState(head: nil, branch: nil, upstream: nil, target: nil, status: Data(), files: [:]))
        plan.isDemonstration = true
        return plan
    }

    private func withRepositoryLock<T>(_ url: URL, _ operation: () throws -> T) throws -> T {
        let common = try GitRunner.text(["rev-parse", "--git-common-dir"], at: url)
        let path = common.hasPrefix("/") ? URL(fileURLWithPath: common) : url.appendingPathComponent(common)
        let lock = RepositoryMutationLocks.lock(for: path.standardizedFileURL.resolvingSymlinksInPath().path)
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    public static let standardActions: [RepositoryActionDefinition] = [
        fileAction("files.readme", "Draft README", "Create README", path: "README.md") { s, _ in
            guard let files = s.rootFiles, !files.contains(where: RepositoryIssueCatalog.isReadme) else {
                throw RepositoryActionError.blocked("A README already exists, or file checks are unavailable.")
            }
            return readmeDraft(s)
        },
        fileAction("files.gitignore", "Preview .gitignore", "Create .gitignore", path: ".gitignore") { s, _ in
            guard let files = s.rootFiles, !files.contains(".gitignore") else {
                throw RepositoryActionError.blocked("A .gitignore already exists, or file checks are unavailable.")
            }
            return ignoreDraft(files)
        },
        fileAction("files.license", "Choose license", "Create LICENSE", path: "LICENSE", inputKind: .license) { s, input in
            guard let files = s.rootFiles, !files.contains(where: RepositoryIssueCatalog.isLicense) else {
                throw RepositoryActionError.blocked("A license file already exists, or file checks are unavailable.")
            }
            if input.license == "Custom" {
                guard !input.customLicense.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw RepositoryActionError.blocked("Enter the license text to preview.")
                }
                return input.customLicense
            }
            guard input.license == "MIT", !input.copyrightHolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RepositoryActionError.blocked("Choose a license and enter its copyright holder.")
            }
            return mitLicense(holder: input.copyrightHolder)
        },
        RepositoryActionDefinition(id: "git.commit", title: "Review and commit", applyTitle: "Commit selected files", inputKind: .commit,
                                   prepare: { try prepareCommit($0, $1) }, execute: { try executeCommit($0) }),
        RepositoryActionDefinition(id: "git.pull", title: "Review pull", applyTitle: "Pull with fast-forward", refreshRemoteBeforePreview: true,
                                   prepare: { try preparePull($0, $1) }, execute: { try executePull($0) }),
        RepositoryActionDefinition(id: "git.push", title: "Review push", applyTitle: "Push commits", refreshRemoteBeforePreview: true,
                                   prepare: { try preparePush($0, $1) }, execute: { try executePush($0) }),
        RepositoryActionDefinition(id: "git.inspect", title: "Inspect divergence", applyTitle: "Inspection only", mutatesRepository: false,
                                   prepare: { try prepareInspection($0, $1) }, execute: { plan in
            RepositoryActionResult(message: "History inspected; choose how to reconcile it in your Git editor.", snapshot: try GitRepositoryScanner.scan(plan.repositoryURL))
        }),
        RepositoryActionDefinition(id: "git.refresh", title: "Retry checks", applyTitle: "Refresh repository", mutatesRepository: false,
                                   prepare: { url, input in
            let s = try GitRepositoryScanner.scan(url)
            return try makePlan(url, "git.refresh", "Retry repository checks", "Fetch remote-tracking refs and inspect local status. Working files are not changed.", "Fetch and scan \(s.name)", input: input)
        }, execute: { plan in
            do {
                try GitRepositoryScanner.fetch(plan.repositoryURL)
            } catch {
                var snapshot = try GitRepositoryScanner.scan(plan.repositoryURL)
                snapshot.fetchError = error.localizedDescription
                return RepositoryActionResult(message: "Local status refreshed; remote check failed: \(error.localizedDescription)", snapshot: snapshot)
            }
            var snapshot = try GitRepositoryScanner.scan(plan.repositoryURL)
            snapshot.fetchedAt = Date()
            return RepositoryActionResult(message: "Repository checks refreshed.", snapshot: snapshot)
        })
    ]

    private static func fileAction(_ id: String, _ title: String, _ applyTitle: String, path: String,
                                   inputKind: RepositoryActionInputKind = .none,
                                   draft: @escaping @Sendable (RepositorySnapshot, RepositoryActionInput) throws -> String) -> RepositoryActionDefinition {
        RepositoryActionDefinition(id: id, title: title, applyTitle: applyTitle, inputKind: inputKind,
                                   supportsBatch: inputKind == .none, prepare: { url, input in
            if (try? FileManager.default.attributesOfItem(atPath: url.appendingPathComponent(path).path)) != nil {
                throw RepositoryActionError.blocked("An entry named \(path) already exists. It will not be overwritten.")
            }
            let snapshot = try GitRepositoryScanner.scan(url)
            let content = try draft(snapshot, input)
            return try makePlan(url, id, "Create \(path)", "Creates one untracked file. Review and edit the draft; commit and push are separate actions.",
                                "New file: \(path)", path: path, content: content, input: input)
        }, execute: { plan in
            try validate(plan)
            // Repeat the file detector so a README/LICENSE with another extension also blocks creation.
            _ = try draft(GitRepositoryScanner.scan(plan.repositoryURL), plan.input)
            guard plan.outputPath == path, let content = plan.content,
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RepositoryActionError.blocked("The draft is empty or the output path changed.")
            }
            let target = plan.repositoryURL.appendingPathComponent(path)
            try Data(content.utf8).write(to: target, options: .withoutOverwriting)
            let snapshot = try GitRepositoryScanner.scan(plan.repositoryURL)
            return RepositoryActionResult(message: "Created \(path). The new file is ready to review and commit.", snapshot: snapshot)
        })
    }

    private static func prepareCommit(_ url: URL, _ input: RepositoryActionInput) throws -> RepositoryActionPlan {
        let snapshot = try GitRepositoryScanner.scan(url)
        guard (try? GitRunner.text(["symbolic-ref", "--quiet", "HEAD"], at: url)) != nil else {
            throw RepositoryActionError.blocked("Check out a branch in your Git editor before committing.")
        }
        guard !input.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RepositoryActionError.blocked("Enter a commit message.")
        }
        guard !input.paths.isEmpty, Set(input.paths).count == input.paths.count,
              Set(input.paths).isSubset(of: Set(snapshot.changes.map(\.path))) else {
            throw RepositoryActionError.blocked("Select changed files to commit.")
        }
        for path in input.paths { try validatePath(path) }
        try requireNormalGitState(url)
        // Renames need both paths; committing only the destination would leave a staged deletion behind.
        let status = try GitRunner.run(["status", "--porcelain=v1", "-z"], at: url)
        let entries = status.split(separator: 0, omittingEmptySubsequences: true)
        if entries.contains(where: { $0.prefix(2).contains(UInt8(ascii: "R")) || $0.prefix(2).contains(UInt8(ascii: "C")) }) {
            throw RepositoryActionError.blocked("Review staged renames or copies in your Git editor before using selected-file commits.")
        }
        let diff: String
        if snapshot.branch == "No commits" || (try? GitRunner.text(["rev-parse", "--verify", "HEAD"], at: url)) == nil {
            diff = try GitRunner.text(["--literal-pathspecs", "diff", "--no-ext-diff", "--no-textconv", "--"] + input.paths, at: url)
            // --only cannot preserve an unrelated index in an unborn repository.
            let staged = try GitRunner.run(["diff", "--cached", "--name-only", "-z"], at: url)
            let stagedPaths = Set(staged.split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
            guard stagedPaths.isSubset(of: Set(input.paths)) else {
                throw RepositoryActionError.blocked("An initial commit must include all files already staged. Add those files to the selection.")
            }
        } else {
            diff = try GitRunner.text(["--literal-pathspecs", "diff", "HEAD", "--no-ext-diff", "--no-textconv", "--"] + input.paths, at: url)
        }
        let untracked = try snapshot.changes.filter { input.paths.contains($0.path) && $0.kind == .untracked }.map { change -> String in
            let file = url.appendingPathComponent(change.path)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                return "New symlink: \(change.path) → \(try FileManager.default.destinationOfSymbolicLink(atPath: file.path))"
            }
            let size = attributes[.size] as? Int ?? 0
            guard size <= 100_000, let data = try? Data(contentsOf: file), !data.contains(0),
                  let text = String(data: data, encoding: .utf8) else {
                return "New binary or large file: \(change.path) (\(size) bytes; content not displayed)"
            }
            return "New file: \(change.path)\n" + text.split(separator: "\n", omittingEmptySubsequences: false).map { "+" + $0 }.joined(separator: "\n")
        }
        let preview = (["Commit: \(input.message)", "Files:"] + input.paths + untracked + [String(diff.prefix(100_000))]).joined(separator: "\n")
        return try makePlan(url, "git.commit", "Commit selected files", "Branch: \(snapshot.branch). Includes the full current contents of selected files, including unstaged edits. Other staged files stay staged. If a commit fails, selected files may remain staged.", preview, input: input)
    }

    private static func executeCommit(_ plan: RepositoryActionPlan) throws -> RepositoryActionResult {
        try validate(plan)
        try requireNormalGitState(plan.repositoryURL)
        _ = try GitRunner.run(["--literal-pathspecs", "add", "--"] + plan.input.paths, at: plan.repositoryURL)
        let arguments: [String]
        if plan.state.head == nil {
            arguments = ["commit", "-m", plan.input.message]
        } else {
            arguments = ["--literal-pathspecs", "commit", "--only", "-m", plan.input.message, "--"] + plan.input.paths
        }
        _ = try GitRunner.run(arguments, at: plan.repositoryURL, timeout: 45)
        let snapshot = try GitRepositoryScanner.scan(plan.repositoryURL)
        guard (try? GitRunner.text(["rev-parse", "HEAD"], at: plan.repositoryURL)) != plan.state.head else {
            throw RepositoryActionError.blocked("Git did not create a commit. Refresh and review the result.")
        }
        return RepositoryActionResult(message: "Committed \(plan.input.paths.count) selected files. \(snapshot.changedFileCount) files still have local changes.", snapshot: snapshot)
    }

    private static func preparePull(_ url: URL, _ input: RepositoryActionInput) throws -> RepositoryActionPlan {
        let snapshot = try GitRepositoryScanner.scan(url)
        try requireNormalGitState(url)
        guard snapshot.upstream != nil, snapshot.ahead == 0, let behind = snapshot.behind, behind > 0,
              snapshot.changes.isEmpty else {
            throw RepositoryActionError.blocked("Fast-forward pull requires incoming commits, no outgoing commits, and a clean working tree.")
        }
        let commits = try GitRunner.text(["log", "--oneline", "HEAD..@{upstream}"], at: url)
        return try makePlan(url, "git.pull", "Pull \(behind) commits", "Fast-forward \(snapshot.branch) from \(snapshot.upstream ?? "upstream"). This updates the local branch and working files.", commits, input: input)
    }

    private static func executePull(_ plan: RepositoryActionPlan) throws -> RepositoryActionResult {
        try validate(plan)
        try GitRepositoryScanner.fetch(plan.repositoryURL)
        try validate(plan) // A changed upstream requires a new preview.
        try requireNormalGitState(plan.repositoryURL)
        _ = try GitRunner.run(["merge", "--ff-only", "--no-edit", "@{upstream}"], at: plan.repositoryURL, timeout: 45)
        var snapshot = try GitRepositoryScanner.scan(plan.repositoryURL)
        snapshot.fetchedAt = Date()
        guard snapshot.behind == 0 else { throw RepositoryActionError.blocked("Pull completed, but incoming commits remain. Refresh to review.") }
        return RepositoryActionResult(message: "Pulled commits with fast-forward. Working tree refreshed.", snapshot: snapshot)
    }

    private static func preparePush(_ url: URL, _ input: RepositoryActionInput) throws -> RepositoryActionPlan {
        let snapshot = try GitRepositoryScanner.scan(url)
        try requireNormalGitState(url)
        guard let ahead = snapshot.ahead, ahead > 0, snapshot.behind == 0 else {
            throw RepositoryActionError.blocked("Push requires outgoing commits and no incoming commits. Review divergence first.")
        }
        let target = try pushTarget(url)
        let commits = try GitRunner.text(["log", "--oneline", "@{upstream}..HEAD"], at: url)
        return try makePlan(url, "git.push", "Push \(ahead) commits", "Publish \(snapshot.branch) to \(target.remote)/\(target.branch). No force push is used.", commits, input: input)
    }

    private static func executePush(_ plan: RepositoryActionPlan) throws -> RepositoryActionResult {
        try validate(plan)
        try GitRepositoryScanner.fetch(plan.repositoryURL)
        try validate(plan)
        try requireNormalGitState(plan.repositoryURL)
        let target = try pushTarget(plan.repositoryURL)
        _ = try GitRunner.run(["push", "--porcelain", "--", target.remote, "HEAD:refs/heads/" + target.branch], at: plan.repositoryURL, timeout: 45)
        // A successful publication remains successful even if the subsequent fetch fails.
        var snapshot = try GitRepositoryScanner.scan(plan.repositoryURL)
        do {
            try GitRepositoryScanner.fetch(plan.repositoryURL)
            snapshot = try GitRepositoryScanner.scan(plan.repositoryURL)
            snapshot.fetchedAt = Date()
        } catch { snapshot.fetchError = error.localizedDescription }
        return RepositoryActionResult(message: snapshot.fetchError == nil ? "Pushed commits to \(target.remote)/\(target.branch)." : "Push succeeded; subsequent remote verification failed. Refresh to verify counts.", snapshot: snapshot)
    }

    private static func prepareInspection(_ url: URL, _ input: RepositoryActionInput) throws -> RepositoryActionPlan {
        let snapshot = try GitRepositoryScanner.scan(url)
        guard snapshot.upstream != nil else { throw RepositoryActionError.blocked("No upstream is configured.") }
        let log = try GitRunner.text(["log", "--left-right", "--graph", "--oneline", "HEAD...@{upstream}"], at: url)
        return try makePlan(url, "git.inspect", "Review divergence", "< marks local commits; > marks upstream commits. Reconcile the histories in your Git editor, then refresh.", log, input: input)
    }

    private static func pushTarget(_ url: URL) throws -> (remote: String, branch: String) {
        let branch = try GitRunner.text(["symbolic-ref", "--quiet", "--short", "HEAD"], at: url)
        let remote = try GitRunner.text(["config", "--get", "branch.\(branch).remote"], at: url)
        let merge = try GitRunner.text(["config", "--get", "branch.\(branch).merge"], at: url)
        guard remote != ".", !remote.isEmpty, merge.hasPrefix("refs/heads/") else {
            throw RepositoryActionError.blocked("Push requires a configured remote branch upstream.")
        }
        return (remote, String(merge.dropFirst("refs/heads/".count)))
    }

    private static func makePlan(_ url: URL, _ action: String, _ title: String, _ explanation: String, _ preview: String,
                                 path: String? = nil, content: String? = nil, input: RepositoryActionInput) throws -> RepositoryActionPlan {
        RepositoryActionPlan(repositoryURL: url, actionID: action, title: title, explanation: explanation,
                             preview: preview, outputPath: path, content: content, input: input,
                             state: try ActionState.read(url, paths: input.paths))
    }

    private static func validate(_ plan: RepositoryActionPlan) throws {
        guard try ActionState.read(plan.repositoryURL, paths: plan.input.paths) == plan.state else {
            throw RepositoryActionError.blocked("The repository changed since this preview. Prepare a new preview before applying it.")
        }
    }

    fileprivate static func validatePath(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
              path.split(separator: "/").first != ".git" else {
            throw RepositoryActionError.blocked("Selected file paths must be inside the repository.")
        }
    }

    private static func requireNormalGitState(_ url: URL) throws {
        for marker in ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply", "BISECT_LOG"] {
            let gitPath = try GitRunner.text(["rev-parse", "--git-path", marker], at: url)
            let path = gitPath.hasPrefix("/") ? gitPath : url.appendingPathComponent(gitPath).path
            if FileManager.default.fileExists(atPath: path) {
                throw RepositoryActionError.blocked("Finish the active merge, rebase, or other Git operation in your Git editor first.")
            }
        }
        let conflicts = try GitRunner.run(["diff", "--name-only", "--diff-filter=U", "-z"], at: url)
        guard conflicts.isEmpty else { throw RepositoryActionError.blocked("Resolve merge conflicts before running this action.") }
    }

    private static func readmeDraft(_ snapshot: RepositorySnapshot) -> String {
        let files = Set(snapshot.rootFiles ?? [])
        let setup: String
        if files.contains("Package.swift") { setup = "```sh\nswift build\nswift test\n```" }
        else if files.contains("package.json") { setup = "Review package.json for the project's installation and run commands." }
        else if files.contains("pyproject.toml") { setup = "Review pyproject.toml for the project's environment and entry points." }
        else { setup = "Describe the prerequisites and setup steps for this project." }
        return "# \(snapshot.name)\n\nDescribe what this project does and who it is for.\n\n## Getting started\n\n\(setup)\n\n## Usage\n\nAdd a minimal example of the main workflow.\n"
    }

    private static func ignoreDraft(_ files: [String]) -> String {
        let names = Set(files)
        var rules = ["# macOS", ".DS_Store"]
        if names.contains("Package.swift") || files.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
            rules += ["", "# Swift / Xcode", ".build/", "DerivedData/", "*.xcuserstate", "xcuserdata/"]
        }
        if names.contains("package.json") { rules += ["", "# JavaScript", "node_modules/", "dist/", ".env.local"] }
        if names.contains("pyproject.toml") || names.contains("requirements.txt") || files.contains(where: { $0.hasSuffix(".py") }) {
            rules += ["", "# Python", "__pycache__/", "*.py[cod]", ".venv/", ".pytest_cache/"]
        }
        if names.contains("Cargo.toml") { rules += ["", "# Rust", "target/"] }
        return rules.joined(separator: "\n") + "\n"
    }

    private static func mitLicense(holder: String) -> String {
        """
        MIT License

        Copyright (c) \(Calendar.current.component(.year, from: Date())) \(holder)

        Permission is hereby granted, free of charge, to any person obtaining a copy
        of this software and associated documentation files (the "Software"), to deal
        in the Software without restriction, including without limitation the rights
        to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
        copies of the Software, and to permit persons to whom the Software is
        furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all
        copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
        IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
        FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
        AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
        LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
        OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
        SOFTWARE.

        """
    }
}

public enum RepositoryActionError: Error, LocalizedError {
    case unavailable
    case blocked(String)
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "This action is unavailable."
        case .blocked(let message): return message
        }
    }
}

fileprivate struct ActionState: Equatable, Sendable {
    let head: String?
    let branch: String?
    let upstream: String?
    let target: String?
    let status: Data
    let files: [String: Data]

    static func read(_ url: URL, paths: [String]) throws -> ActionState {
        var files: [String: Data] = [:]
        for path in paths {
            try RepositoryActionCatalog.validatePath(path)
            let file = url.appendingPathComponent(path)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path) else {
                files[path] = Data("missing".utf8)
                continue
            }
            if attrs[.type] as? FileAttributeType == .typeSymbolicLink {
                files[path] = Data(try FileManager.default.destinationOfSymbolicLink(atPath: file.path).utf8)
                continue
            }
            guard attrs[.type] as? FileAttributeType == .typeRegular, let stream = InputStream(url: file) else {
                throw RepositoryActionError.blocked("Review directory or submodule changes in your Git editor.")
            }
            stream.open()
            defer { stream.close() }
            var hash = SHA256()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count == 0 { break }
                guard count > 0 else { throw stream.streamError ?? RepositoryActionError.blocked("Could not read \(path).") }
                hash.update(data: Data(buffer.prefix(count)))
            }
            files[path] = Data(hash.finalize())
        }
        let branch = try? GitRunner.text(["symbolic-ref", "--quiet", "--short", "HEAD"], at: url)
        let target: String?
        if let branch {
            let remote = try? GitRunner.text(["config", "--get", "branch.\(branch).remote"], at: url)
            let merge = try? GitRunner.text(["config", "--get", "branch.\(branch).merge"], at: url)
            let remoteURL = remote.flatMap { try? GitRunner.text(["config", "--get", "remote.\($0).url"], at: url) }
            let pushURL = remote.flatMap { try? GitRunner.text(["config", "--get", "remote.\($0).pushurl"], at: url) }
            target = [remote ?? "", merge ?? "", remoteURL ?? "", pushURL ?? ""].joined(separator: "\n")
        } else { target = nil }
        return ActionState(head: try? GitRunner.text(["rev-parse", "--verify", "HEAD"], at: url), branch: branch,
                           upstream: try? GitRunner.text(["rev-parse", "--verify", "@{upstream}"], at: url), target: target,
                           status: try GitRunner.run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], at: url), files: files)
    }
}

private enum RepositoryMutationLocks {
    private static let guardLock = NSLock()
    private static var locks: [String: NSLock] = [:]
    static func lock(for path: String) -> NSLock {
        guardLock.lock()
        defer { guardLock.unlock() }
        if let lock = locks[path] { return lock }
        let lock = NSLock()
        locks[path] = lock
        return lock
    }
}
