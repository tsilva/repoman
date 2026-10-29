import Foundation

/// Read-only preflight for action references declared in working-tree workflow files.
/// This checks repository restrictions, not successful execution or transitive action code.
enum RepositoryActionsPolicyChecks {
    static let id = "ci.allowedActions"
    typealias Request = @Sendable ([String], TimeInterval) async throws -> Data

    static func checks(request: @escaping Request = { arguments, timeout in
        try await Task.detached(priority: .utility) { try GitHubCLI.run(arguments, timeout: timeout) }.value
    }) -> [RepositoryCheck] {
        [RepositoryCheck(id: id, title: "Workflow actions blocked by repository policy", category: .ci, symbol: "hand.raised", evaluate: { context in
            let workflows = try CheckSupport.workflowPaths(context)
            guard !workflows.isEmpty else { return .notApplicable("No GitHub Actions workflows require a policy preflight.") }
            guard let remote = context.snapshot.remoteURL else { return .notApplicable("No remote identifies a GitHub repository for Actions policy inspection.") }
            guard let repository = GitHubCI.repository(remote) else {
                if let url = URL(string: remote), let host = url.host, host.lowercased() != "github.com", ["https", "http"].contains(url.scheme ?? "") {
                    return .notApplicable("The configured remote is not GitHub.com; its Actions policy was not inspected.")
                }
                return .unavailable("The remote could not be resolved as GitHub.com. Review its host alias or URL; no Actions-policy compliance was established.")
            }
            let root = repository.owner + "/" + repository.name
            let policy = try RepositoryCheckPolicy.load(context)
            var findings: [RepositoryFinding] = [], reasons = Set<String>()
            let deadline = Date().addingTimeInterval(60)
            var requests = 0
            func read<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
                guard Date() < deadline, requests < 70 else { throw InspectionError.blocked("Actions policy inspection limit reached.") }
                requests += 1
                let data = try await request(["api", "--hostname", "github.com", "--method", "GET", path], min(15, deadline.timeIntervalSinceNow))
                guard data.count <= 1_048_576 else { throw InspectionError.blocked("Actions policy response exceeds inspection limits.") }
                return try JSONDecoder().decode(type, from: data)
            }
            func finish() -> RepositoryCheckResult {
                let retained = context.applyingExceptions(findings, policy: policy)
                return reasons.isEmpty ? .findings(retained) : .partial(retained, reasons.sorted().joined(separator: "\n"))
            }
            func finding(_ subject: String, _ evidence: String) {
                findings.append(CheckSupport.finding(context, id, subject, "Workflow action is blocked by repository policy", evidence, .ci, "hand.raised", severity: .blocked))
            }
            let permissions: Permissions
            do { permissions = try await read("repos/" + root + "/actions/permissions", as: Permissions.self) }
            catch { return .unavailable("GitHub Actions permissions could not be read. Check gh authentication and Administration read access; no policy-compliant result was established.") }
            guard permissions.enabled else {
                finding(root + "#disabled", "GitHub reports Actions disabled for this repository, which contains workflows. Review whether disabling execution is intentional.")
                return finish()
            }
            guard let mode = permissions.allowed_actions, ["all", "local_only", "selected"].contains(mode) else {
                return .unavailable("GitHub returned an unsupported Actions policy mode; execution permissions remain unverified.")
            }
            var owner: String?
            do {
                let metadata = try await read("repos/" + root, as: RepositoryMetadata.self)
                guard safeName(metadata.owner.login), ["User", "Organization"].contains(metadata.owner.type) else {
                    throw InspectionError.blocked("Unsupported repository owner.")
                }
                owner = metadata.owner.login
                if metadata.owner.type == "Organization" {
                    reasons.insert("Inherited organization or enterprise restrictions require separate verification; repository-level blocks are retained.")
                }
            } catch { reasons.insert("Repository ownership and inherited restrictions could not be verified; repository-level pinning violations are retained.") }
            let selected: Selection?
            if mode == "selected" {
                do {
                    let value = try await read("repos/" + root + "/actions/permissions/selected-actions", as: Selection.self)
                    guard value.patterns_allowed.count <= 1_000 else { throw InspectionError.blocked("Too many Actions policy patterns.") }
                    selected = value
                } catch {
                    selected = nil
                    reasons.insert("Selected Actions rules could not be read completely; declared references were not assumed allowed.")
                }
            } else { selected = nil }
            let hasLock = try context.exists(".github/workflows/actions.lock")
            var visibility: [String: Visibility] = [:]
            var count = 0
            for path in workflows {
                let inspection: WorkflowInspection.ReferenceInspection
                do { inspection = WorkflowInspection.referenceInspection(try context.workflowLines(path)) }
                catch { reasons.insert(path + ": Unsupported workflow structure prevents complete action-reference inspection."); continue }
                for reason in inspection.reasons { reasons.insert(path + ": " + reason) }
                for raw in Set(inspection.references).sorted() {
                    count += 1
                    guard count <= 256 else { reasons.insert("Workflow action references exceed the 256-reference inspection limit."); return finish() }
                    if raw.hasPrefix("./") || raw.hasPrefix("$/") { continue }
                    guard let reference = Reference(raw) else {
                        reasons.insert(path + ": An unsupported action reference needs review; its contents were not included in diagnostics.")
                        continue
                    }
                    if hasLock && !reference.reusable {
                        reasons.insert(path + ": Workflow dependency lockfiles can change executed action identities; locked action-policy evaluation is not yet supported.")
                        continue
                    }
                    if !reference.reusable && !reference.pinned {
                        if permissions.sha_pinning_required == true {
                            finding(path + "#" + raw + "#pin", "GitHub requires full commit-SHA pins for actions, but " + raw + " is not pinned. Reusable workflow calls have separate platform pinning semantics.")
                        } else if permissions.sha_pinning_required == nil {
                            reasons.insert(path + ": GitHub did not report whether full action-SHA pinning is required.")
                        }
                    }
                    let decision: Decision
                    if mode == "all" { decision = .allowed }
                    else if mode == "local_only" {
                        if let owner { decision = reference.owner.caseInsensitiveCompare(owner) == .orderedSame ? .allowed : .blocked }
                        else { decision = .unknown }
                    } else if let selected {
                        let intrinsic = owner.map { reference.owner.caseInsensitiveCompare($0) == .orderedSame } == true ||
                            (selected.github_owned_allowed && ["actions", "github"].contains(reference.owner.lowercased()))
                        let source: Visibility
                        let cacheKey = reference.repository.lowercased()
                        if let cached = visibility[cacheKey] { source = cached }
                        else {
                            do {
                                let metadata = try await read("repos/" + reference.repository, as: ActionMetadata.self)
                                guard metadata.full_name.caseInsensitiveCompare(reference.repository) == .orderedSame else { throw InspectionError.blocked("Action identity redirected.") }
                                source = metadata.private ? .privateSource : .publicSource
                            } catch { source = .unknown }
                            visibility[cacheKey] = source
                        }
                        switch source {
                        case .publicSource: decision = selected.decision(reference, intrinsicallyAllowed: intrinsic, publicSource: true)
                        case .privateSource: decision = intrinsic ? .allowed : .unknown
                        case .unknown: decision = intrinsic ? selected.decision(reference, intrinsicallyAllowed: true, publicSource: false) : .unknown
                        }
                    } else { decision = .unknown }
                    switch decision {
                    case .allowed: break
                    case .blocked:
                        finding(path + "#" + raw + "#policy", "GitHub's " + mode + " Actions policy does not permit " + raw + ". Review the exact reference or request a narrowly approved policy change; RepoMan never edits permissions.")
                    case .unknown:
                        reasons.insert(path + ": Policy eligibility for " + raw + " could not be established. Private access, verified-creator status, exclusions or unsupported policy syntax may require review.")
                    }
                }
            }
            return finish()
        })]
    }

    private enum Visibility { case publicSource, privateSource, unknown }
    enum Decision { case allowed, blocked, unknown }
    struct Reference {
        let raw: String; let owner: String; let repository: String; let reusable: Bool; let pinned: Bool
        init?(_ raw: String) {
            guard raw.utf8.count <= 512, CheckSupport.matches(raw, #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_./-]+)?@[A-Za-z0-9_./-]+$"#) else { return nil }
            let pieces = raw.split(separator: "@", maxSplits: 1).map(String.init)
            let path = pieces[0].split(separator: "/").map(String.init)
            guard !path.contains(".."), ![".", ".."].contains(path[0]), ![".", ".."].contains(path[1]) else { return nil }
            self.raw = raw; owner = path[0]; repository = path.prefix(2).joined(separator: "/")
            reusable = path.count >= 5 && path[2] == ".github" && path[3] == "workflows" && (path.last!.hasSuffix(".yml") || path.last!.hasSuffix(".yaml"))
            pinned = CheckSupport.matches(pieces[1], #"^[0-9a-fA-F]{40}$"#)
        }
        var normalized: String { Self.normalize(raw) }
        static func normalize(_ value: String) -> String {
            let parts = value.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2 else { return value }
            // Repository/owner names are case insensitive; refs and subpaths retain their spelling.
            let second = parts[1].split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            return parts[0].lowercased() + "/" + second[0].lowercased() + (second.count == 2 ? "@" + second[1] : "") + (parts.count == 3 ? "/" + parts[2] : "")
        }
    }
    struct Selection: Decodable {
        let github_owned_allowed: Bool; let verified_allowed: Bool; let patterns_allowed: [String]
        func decision(_ reference: Reference, intrinsicallyAllowed: Bool, publicSource: Bool) -> Decision {
            var positive = intrinsicallyAllowed, lastPositive = -1, lastNegative = -1, unsupported = false
            var workBudget = 1_000_000
            let candidate = Array(reference.normalized.utf8)
            for (index, item) in patterns_allowed.enumerated() {
                let negative = item.hasPrefix("!")
                let pattern = negative ? String(item.dropFirst()) : item
                guard !pattern.isEmpty, pattern.utf8.count <= 512,
                      CheckSupport.matches(pattern, #"^[A-Za-z0-9_./@*:-]+$"#) else { unsupported = true; continue }
                guard let matches = Self.glob(candidate, Array(Reference.normalize(pattern).utf8), budget: &workBudget) else { return .unknown }
                // Unknown source visibility must not turn a possibly applicable exclusion into a pass.
                guard publicSource else {
                    if negative && matches { unsupported = true }
                    continue
                }
                if matches {
                    if negative { lastNegative = index }
                    else { positive = true; lastPositive = index }
                }
            }
            guard !unsupported else { return .unknown }
            if lastNegative >= 0 { return lastPositive > lastNegative ? .unknown : .blocked }
            if positive { return .allowed }
            return verified_allowed ? .unknown : .blocked
        }
        /// Only '*' is supported. A bounded greedy matcher avoids regex backtracking on policy data.
        private static func glob(_ text: [UInt8], _ pattern: [UInt8], budget: inout Int) -> Bool? {
            var i = 0, j = 0, retry = 0
            var star: Int?
            while i < text.count {
                budget -= 1
                guard budget >= 0 else { return nil }
                if j < pattern.count && pattern[j] != 42 && text[i] == pattern[j] { i += 1; j += 1 }
                else if j < pattern.count && pattern[j] == 42 { star = j; j += 1; retry = i }
                else if let previous = star { retry += 1; i = retry; j = previous + 1 }
                else { return false }
            }
            while j < pattern.count && pattern[j] == 42 {
                budget -= 1
                guard budget >= 0 else { return nil }
                j += 1
            }
            return j == pattern.count
        }
    }
    private static func safeName(_ value: String) -> Bool { CheckSupport.matches(value, #"^[A-Za-z0-9_.-]{1,100}$"#) }
    private struct Permissions: Decodable { let enabled: Bool; let allowed_actions: String?; let sha_pinning_required: Bool? }
    private struct RepositoryMetadata: Decodable { let owner: Owner }
    private struct Owner: Decodable { let login: String; let type: String }
    private struct ActionMetadata: Decodable { let full_name: String; let `private`: Bool }
}
