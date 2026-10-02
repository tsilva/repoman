import Foundation

/// Repository-owned preferences are data, never executable configuration.
struct RepositoryCheckPolicy: Decodable, Sendable {
    var version = 1
    var exceptions: [String: [String: String]] = [:]
    var stashAgeDays = 30
    var maximumTrackedFileBytes = 10_485_760
    var notebooks = NotebookPolicy()

    struct NotebookPolicy: Decodable, Sendable {
        var enabled = false
        var maximumOutputBytes = 262_144
        enum CodingKeys: String, CodingKey { case enabled, maximumOutputBytes }
        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            maximumOutputBytes = try c.decodeIfPresent(Int.self, forKey: .maximumOutputBytes) ?? 262_144
        }
    }
    enum CodingKeys: String, CodingKey { case version, exceptions, stashAgeDays, maximumTrackedFileBytes, notebooks }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        exceptions = try c.decodeIfPresent([String: [String: String]].self, forKey: .exceptions) ?? [:]
        stashAgeDays = try c.decodeIfPresent(Int.self, forKey: .stashAgeDays) ?? 30
        maximumTrackedFileBytes = try c.decodeIfPresent(Int.self, forKey: .maximumTrackedFileBytes) ?? 10_485_760
        notebooks = try c.decodeIfPresent(NotebookPolicy.self, forKey: .notebooks) ?? NotebookPolicy()
    }
    static func load(_ context: RepositoryInspectionContext) throws -> Self {
        guard try context.exists(".repoman.json") else { return Self() }
        let data = Data(try context.readText(".repoman.json").utf8)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["version", "exceptions", "stashAgeDays", "maximumTrackedFileBytes", "notebooks"]),
              (object["notebooks"] as? [String: Any]).map({ Set($0.keys).isSubset(of: ["enabled", "maximumOutputBytes"]) }) ?? true else {
            throw RepairError.blocked("Unsupported .repoman.json fields.")
        }
        let policy = try JSONDecoder().decode(Self.self, from: data)
        guard policy.version == 1, (1...3650).contains(policy.stashAgeDays),
              (1024...1_073_741_824).contains(policy.maximumTrackedFileBytes),
              (1024...8_388_608).contains(policy.notebooks.maximumOutputBytes),
              policy.exceptions.values.allSatisfy({ $0.values.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }) else {
            throw RepairError.blocked("Invalid .repoman.json version, threshold, or exception reason.")
        }
        return policy
    }
}

enum CheckSupport {
    typealias Inspector = @Sendable (RepositoryInspectionContext, RepositoryCheckPolicy) async throws -> [RepositoryFinding]
    static func check(_ id: String, _ title: String, _ category: IssueCategory, _ symbol: String,
                      inspect: @escaping Inspector) -> RepositoryCheck {
        RepositoryCheck(id: id, title: title, category: category, symbol: symbol, inspect: { context in
            let policy = try RepositoryCheckPolicy.load(context)
            return try await inspect(context, policy).filter { policy.exceptions[id]?[$0.subject] == nil }
        })
    }
    static func finding(_ context: RepositoryInspectionContext, _ id: String, _ subject: String, _ title: String,
                        _ evidence: String, _ category: IssueCategory = .setup, _ symbol: String = "checkmark.shield",
                        severity: IssueSeverity = .attention) -> RepositoryFinding {
        RepositoryFinding(repositoryID: context.snapshot.id, checkID: id, subject: subject, title: title,
                          evidence: evidence, category: category, severity: severity, symbol: symbol, recipeIDs: [id])
    }
    static func rootFiles(_ context: RepositoryInspectionContext) throws -> [String] {
        guard let files = context.snapshot.rootFiles else { throw RepairError.blocked("Repository root files could not be inspected.") }
        return files
    }
    static func manifests(_ context: RepositoryInspectionContext) throws -> [String] {
        let roots = try rootFiles(context).filter { ["package.json", "pyproject.toml", "requirements.txt"].contains($0) }
        let nested = try context.trackedPaths(matching: [":(glob)**/package.json", ":(glob)**/pyproject.toml", ":(glob)**/requirements.txt"]).filter {
            ["package.json", "pyproject.toml", "requirements.txt"].contains(($0 as NSString).lastPathComponent) &&
            !$0.split(separator: "/").contains(where: { ["node_modules", ".venv", "vendor"].contains(String($0)) })
        }
        let paths = Set(roots + nested).sorted()
        guard paths.count <= 64 else { throw RepairError.blocked("More than 64 dependency manifests need inspection.") }
        return paths
    }
    static func workflows(_ context: RepositoryInspectionContext) throws -> [(String, String)] {
        try context.filenames(in: ".github/workflows").filter { ["yaml", "yml"].contains(($0 as NSString).pathExtension) }
            .map { name in let path = ".github/workflows/" + name; return (path, try context.readText(path)) }
    }
    static func matches(_ text: String, _ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
    static func captures(_ text: String, _ pattern: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (0..<match.numberOfRanges).map { index in Range(match.range(at: index), in: text).map { String(text[$0]) } ?? "" }
        }
    }
}

/// A deliberately limited configuration reader. Unsupported relevant syntax stays unavailable.
/// It handles scalar values, multiline arrays and inline tables, retaining the raw values for review.
struct InspectionConfig {
    let values: [String: String]
    static func withoutComment(_ text: String) -> String {
        var quote: Character?, escaped = false, result = ""
        for c in text {
            if escaped { result.append(c); escaped = false; continue }
            if c == "\\", quote == "\"" { escaped = true; result.append(c); continue }
            if let q = quote { if c == q { quote = nil } }
            else if c == "\"" || c == "'" { quote = c }
            else if c == "#" { break }
            result.append(c)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func toml(_ source: String, standaloneUV: Bool = false, allSections: Bool = false) throws -> Self {
        var values: [String: String] = [:], section = "", pending = "", arrayCounts: [String: Int] = [:]
        for raw in source.components(separatedBy: .newlines) {
            let line = withoutComment(raw)
            guard !line.isEmpty else { continue }
            if pending.isEmpty, line.hasPrefix("[") {
                guard line.hasSuffix("]") else { throw RepairError.blocked("Unsupported TOML table syntax.") }
                if line.hasPrefix("[[") {
                    guard line.hasSuffix("]]") else { throw RepairError.blocked("Unsupported TOML table syntax.") }
                    let name = String(line.dropFirst(2).dropLast(2))
                    let count = arrayCounts[name, default: 0]; arrayCounts[name] = count + 1
                    section = name + "." + String(count)
                } else { section = String(line.dropFirst().dropLast()) }
                continue
            }
            // These are the only sections interpreted by dependency checks.
            guard allSections || standaloneUV || section.isEmpty || section == "project" || section.hasPrefix("project.optional-dependencies") || section.hasPrefix("tool.uv") else { continue }
            pending += (pending.isEmpty ? "" : "\n") + line
            guard balanced(pending) else { continue }
            guard let equals = pending.firstIndex(of: "=") else { throw RepairError.blocked("Unsupported TOML configuration.") }
            let key = String(pending[..<equals]).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            let value = String(pending[pending.index(after: equals)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty, !value.contains("\"\"\""), !value.contains("'''"), !key.contains(" ") else {
                throw RepairError.blocked("Unsupported TOML value syntax.")
            }
            let qualified = section.isEmpty ? key : section + "." + key
            guard values[qualified] == nil else { throw RepairError.blocked("Duplicate TOML setting: " + qualified) }
            values[qualified] = value
            pending = ""
        }
        guard pending.isEmpty else { throw RepairError.blocked("Incomplete TOML value.") }
        return Self(values: values)
    }
    static func yaml(_ source: String) throws -> Self {
        guard !source.contains("\t"), !CheckSupport.matches(source, #"(?m)^\s*(?:<<:|[^#\n]*:\s*[&*])"#) else {
            throw RepairError.blocked("YAML anchors or tabs require manual review.")
        }
        var values: [String: String] = [:], parents: [(Int, String)] = []
        for raw in source.components(separatedBy: .newlines) {
            let line = withoutComment(raw)
            guard !line.isEmpty, line != "---" else { continue }
            let indent = raw.prefix { $0 == " " }.count
            while parents.last.map({ $0.0 >= indent }) == true { parents.removeLast() }
            if line.hasPrefix("- ") {
                guard let parent = parents.last else { throw RepairError.blocked("Unsupported YAML sequence.") }
                values[parent.1, default: ""] += "\n" + String(line.dropFirst(2))
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { throw RepairError.blocked("Unsupported YAML setting.") }
            let key = String(line[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            let path = (parents.last.map { $0.1 + "." } ?? "") + key
            guard values[path] == nil else { throw RepairError.blocked("Duplicate YAML setting: " + path) }
            values[path] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            parents.append((indent, path))
        }
        return Self(values: values)
    }
    static func ini(_ source: String) throws -> Self {
        var values: [String: String] = [:]
        for raw in source.components(separatedBy: .newlines) {
            let line = withoutComment(raw)
            guard !line.isEmpty, !line.hasPrefix(";") else { continue }
            guard let equals = line.firstIndex(of: "=") else { throw RepairError.blocked("Unsupported npm configuration.") }
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            guard values[key] == nil else { throw RepairError.blocked("Duplicate npm setting: " + key) }
            values[key] = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        }
        return Self(values: values)
    }
    static func scalar(_ raw: String?) -> String? {
        guard var raw else { return nil }
        raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.count >= 2, (raw.first == "\"" && raw.last == "\"") || (raw.first == "'" && raw.last == "'") {
            return String(raw.dropFirst().dropLast())
        }
        return raw
    }
    private static func balanced(_ text: String) -> Bool {
        var quote: Character?, escaped = false, depth = 0
        for c in text {
            if escaped { escaped = false; continue }
            if c == "\\", quote == "\"" { escaped = true; continue }
            if let q = quote { if c == q { quote = nil }; continue }
            if c == "\"" || c == "'" { quote = c }
            else if c == "[" || c == "{" { depth += 1 }
            else if c == "]" || c == "}" { depth -= 1 }
        }
        return quote == nil && depth == 0
    }
}

/// Presets only compose instructions. Sending a repair remains an explicit user action.
enum ExtendedRepairRecipes {
    static let recipes: [RepairRecipe] = [
        RepairRecipe(id: "dependencies.manager", title: "Align the package manager", prompt: "Inspect the manifest, lockfiles, workspace layout, CI and repository instructions. Align the declared package manager and its pinned version with the intended lockfile and installation commands. Preserve dependency age protections and required lifecycle-script exceptions. Ask if the intended manager is ambiguous. Leave changes uncommitted; do not push or trigger workflows."),
        RepairRecipe(id: "dependencies.safeguards", title: "Restore dependency safeguards", prompt: "Inspect the effective dependency configuration, including uv.toml, bunfig.toml, workspace files, .npmrc, CI overrides and documented exceptions. Restore the repository's seven-day dependency age policy and relevant bad-package exclusions. For pnpm preserve exotic dependency blocking; for npm disable lifecycle scripts unless required. For Bun use install.minimumReleaseAge >= 604800 seconds and disable lifecycle scripts with install.ignoreScripts or .npmrc unless an exception is required; review age exclusions and preserve justified trust exceptions. For pip use committed constraints. Preserve legitimate GPU indexes and project-specific build requirements. Document justified exceptions in .repoman.json with reasons. Leave changes uncommitted; do not upgrade dependencies unnecessarily."),
        RepairRecipe(id: "dependencies.lockfile", title: "Add the intended lockfile", prompt: "Determine whether this project requires a lockfile and which manager owns it. Generate or repair the appropriate lockfile using existing dependency policy without upgrading dependencies unnecessarily. If this is an intentional library or experiment exception, explain it and record a reason in .repoman.json. Leave changes uncommitted and do not change unrelated staged files."),
        RepairRecipe(id: "dependencies.sources", title: "Review dependency exceptions", prompt: "Inspect the reported custom sources and policy exclusions. Explain their purpose and check prior authorization in repository instructions. Preserve legitimate workspace dependencies and GPU wheel indexes. Remove unintended exceptions; ask me before approving new external sources, indexes or age-policy exceptions. Record intentional exceptions with reasons in .repoman.json. Do not expose credentials from configuration. Leave changes uncommitted."),
        RepairRecipe(id: "ci.mutableActions", title: "Pin Actions references", prompt: "Inspect each reported external action, reusable workflow or Docker action. Replace mutable references with verified full commit hashes from the original action repository, or immutable Docker digests, preserving the intended release and workflow behavior. Keep readable version comments. Validate the workflow. Leave changes uncommitted; do not publish or trigger workflows."),
        RepairRecipe(id: "ci.suppressedFailures", title: "Review suppressed validation", prompt: "Inspect the reported validation steps and why failures are tolerated. Make required validation fail CI correctly while preserving intentionally optional diagnostics. Document justified exceptions with reasons in .repoman.json. Do not disable checks or weaken assertions. Validate relevant commands and leave changes uncommitted; do not trigger remote workflows."),
        RepairRecipe(id: "files.generatedTracked", title: "Remove generated files from tracking", prompt: "Review the reported tracked paths and verify they are generated rather than intentional fixtures or source. Add appropriate ignore rules and remove only confirmed generated paths from the Git index while keeping local working files. Preserve unrelated staged changes. Record intentional fixtures as .repoman.json exceptions with reasons. Leave changes uncommitted."),
        RepairRecipe(id: "git.oldStashes", title: "Review old stashes", prompt: "Inspect the identified stash by its commit hash, including tracked and untracked files. Explain what it contains and whether the work exists elsewhere. Ask me before restoring or deleting it; preserve the current working tree and all other stashes. Do not automatically pop, apply or drop a stash."),
        RepairRecipe(id: "git.unfinishedOperation", title: "Inspect unfinished Git work", prompt: "Inspect the reported Git operation, conflicts or detached HEAD and explain how to preserve the work. Ask me whether to continue, abort or preserve detached commits before changing history or branches. Do not discard files, abort operations or switch branches without my explicit instruction. Preserve unrelated staged and working changes."),
        RepairRecipe(id: "github.description", title: "Sync the published tagline", prompt: "Read the latest published default-branch README and validate its marked tagline using the repository's existing push/description-sync instructions. Update only the actual destination GitHub repository description if my gh login controls it. Use no uncommitted or feature-branch tagline text. Skip absent markers and report invalid markers or missing access. Do not push, edit the published README or change Actions automation."),
        RepairRecipe(id: "docs.brokenLinks", title: "Repair local documentation links", prompt: "Inspect the missing local documentation targets and skill references. Correct stale paths or restore genuinely missing documentation or images using repository evidence. Preserve example paths and code samples. Verify the links without running project scripts. Leave changes uncommitted."),
        RepairRecipe(id: "notebooks.hygiene", title: "Review notebook outputs", prompt: "Inspect saved errors and large outputs in the reported notebook. Preserve deliberate teaching examples and reproducibility evidence; ask if intent is unclear. Clear only unwanted outputs without executing notebook cells or changing source and metadata unnecessarily. Record intentional exceptions with reasons in .repoman.json. Leave changes uncommitted.")
    ]
}
