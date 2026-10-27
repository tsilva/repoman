import Foundation

/// Repository-owned preferences are data, never executable configuration.
struct RepositoryCheckPolicy: Decodable, Sendable {
    var version = 1
    var exceptions: [String: [String: String]] = [:]
    var stashAgeDays = 30
    var maximumTrackedFileBytes = 10_485_760
    var notebooks = NotebookPolicy()
    var ci = CIPolicy()

    struct CIPolicy: Decodable, Sendable {
        struct Component: Decodable, Sendable {
            let path: String
            var ecosystem = "generic"
            var requires = ["any"]
            enum CodingKeys: String, CodingKey { case path, ecosystem, requires }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                let raw = try c.decode(String.self, forKey: .path)
                guard !raw.split(separator: "/").contains("..") else { throw InspectionError.blocked("CI component paths cannot contain parent traversal.") }
                path = (raw as NSString).standardizingPath
                ecosystem = try c.decodeIfPresent(String.self, forKey: .ecosystem) ?? "generic"
                requires = try c.decodeIfPresent([String].self, forKey: .requires) ?? ["any"]
            }
        }
        struct ExpectedCheck: Decodable, Sendable {
            let name: String
            let workflow: String?
            let event: String?
            let app: String?
            let acceptedConclusions: [String]
            enum CodingKeys: String, CodingKey { case name, workflow, event, app, acceptedConclusions }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                name = try c.decode(String.self, forKey: .name)
                workflow = try c.decodeIfPresent(String.self, forKey: .workflow)
                event = try c.decodeIfPresent(String.self, forKey: .event)
                app = try c.decodeIfPresent(String.self, forKey: .app)
                acceptedConclusions = try c.decodeIfPresent([String].self, forKey: .acceptedConclusions) ?? ["SUCCESS"]
            }
        }
        var components: [Component]?
        var expectedChecks: [ExpectedCheck] = []
        enum CodingKeys: String, CodingKey { case components, expectedChecks }
        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            components = try c.decodeIfPresent([Component].self, forKey: .components)
            expectedChecks = try c.decodeIfPresent([ExpectedCheck].self, forKey: .expectedChecks) ?? []
        }
        func validate() throws {
            let kinds: Set<String> = ["any", "test", "build", "lint", "typecheck"]
            guard expectedChecks.count <= 64, components.map({ !$0.isEmpty && $0.count <= 64 }) ?? true,
                  components?.allSatisfy({ !$0.path.isEmpty && !$0.path.hasPrefix("/") && !$0.path.split(separator: "/").contains("..") && !$0.path.contains(where: { "$*?\\{}~".contains($0) }) && ["generic", "python", "javascript", "swift"].contains($0.ecosystem) && !$0.requires.isEmpty && Set($0.requires).isSubset(of: kinds) }) ?? true,
                  expectedChecks.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 200 && !$0.acceptedConclusions.isEmpty && Set($0.acceptedConclusions).isSubset(of: ["SUCCESS", "SKIPPED", "NEUTRAL"]) && [$0.workflow, $0.event, $0.app].allSatisfy { $0.map { !$0.isEmpty && $0.count <= 200 } ?? true } }) else {
                throw InspectionError.blocked("Invalid CI component or expected-check policy.")
            }
            let componentIDs = components?.map { $0.path + "#" + $0.ecosystem } ?? []
            guard Set(componentIDs).count == componentIDs.count else { throw InspectionError.blocked("Duplicate CI component identity.") }
            let identities = expectedChecks.map { [$0.name, $0.workflow ?? "*", $0.event ?? "*", $0.app ?? "*"].joined(separator: "\u{1f}") }
            guard Set(identities).count == identities.count else { throw InspectionError.blocked("Duplicate expected CI check identity.") }
        }
    }
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
    enum CodingKeys: String, CodingKey { case version, exceptions, stashAgeDays, maximumTrackedFileBytes, notebooks, ci }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        exceptions = try c.decodeIfPresent([String: [String: String]].self, forKey: .exceptions) ?? [:]
        stashAgeDays = try c.decodeIfPresent(Int.self, forKey: .stashAgeDays) ?? 30
        maximumTrackedFileBytes = try c.decodeIfPresent(Int.self, forKey: .maximumTrackedFileBytes) ?? 10_485_760
        notebooks = try c.decodeIfPresent(NotebookPolicy.self, forKey: .notebooks) ?? NotebookPolicy()
        ci = try c.decodeIfPresent(CIPolicy.self, forKey: .ci) ?? CIPolicy()
    }
    static func load(_ context: RepositoryInspectionContext) throws -> Self {
        guard try context.exists(".repoman.json") else { return Self() }
        let data = Data(try context.readText(".repoman.json").utf8)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["version", "exceptions", "stashAgeDays", "maximumTrackedFileBytes", "notebooks", "ci"]),
              (object["notebooks"] as? [String: Any]).map({ Set($0.keys).isSubset(of: ["enabled", "maximumOutputBytes"]) }) ?? true else {
            throw InspectionError.blocked("Unsupported .repoman.json fields.")
        }
        if let ci = object["ci"] as? [String: Any] {
            guard Set(ci.keys).isSubset(of: ["components", "expectedChecks"]),
                  (ci["components"] as? [[String: Any]])?.allSatisfy({ Set($0.keys).isSubset(of: ["path", "ecosystem", "requires"]) }) ?? true,
                  (ci["expectedChecks"] as? [[String: Any]])?.allSatisfy({ Set($0.keys).isSubset(of: ["name", "workflow", "event", "app", "acceptedConclusions"]) }) ?? true else { throw InspectionError.blocked("Unsupported CI policy fields.") }
        }
        let policy = try JSONDecoder().decode(Self.self, from: data)
        guard policy.version == 1, (1...3650).contains(policy.stashAgeDays),
              (1024...1_073_741_824).contains(policy.maximumTrackedFileBytes),
              (1024...8_388_608).contains(policy.notebooks.maximumOutputBytes),
              policy.exceptions.values.allSatisfy({ $0.values.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }) else {
            throw InspectionError.blocked("Invalid .repoman.json version, threshold, or exception reason.")
        }
        try policy.ci.validate()
        return policy
    }
}

enum CheckSupport {
    typealias Inspector = @Sendable (RepositoryInspectionContext, RepositoryCheckPolicy) async throws -> [RepositoryFinding]
    static func check(_ id: String, _ title: String, _ category: IssueCategory, _ symbol: String,
                      inspect: @escaping Inspector) -> RepositoryCheck {
        RepositoryCheck(id: id, title: title, category: category, symbol: symbol, inspect: { context in
            let policy = try RepositoryCheckPolicy.load(context)
            return context.applyingExceptions(try await inspect(context, policy), policy: policy)
        })
    }
    /// A failure on one path must not discard evidence from other readable files.
    static func fileCheck(_ id: String, _ title: String, _ category: IssueCategory, _ symbol: String,
                          paths: @escaping @Sendable (RepositoryInspectionContext) throws -> [String] = { try $0.trackedPaths() },
                          inspect: @escaping @Sendable (RepositoryInspectionContext, RepositoryCheckPolicy, String) throws -> [RepositoryFinding]) -> RepositoryCheck {
        fileCheck(id, title, category, symbol, paths: paths, evaluate: { context, policy, path in
            .findings(try inspect(context, policy, path))
        })
    }
    /// Some documents can contain both known broken links and targets outside coverage.
    static func fileCheck(_ id: String, _ title: String, _ category: IssueCategory, _ symbol: String,
                          paths: @escaping @Sendable (RepositoryInspectionContext) throws -> [String],
                          evaluate: @escaping @Sendable (RepositoryInspectionContext, RepositoryCheckPolicy, String) throws -> RepositoryCheckResult) -> RepositoryCheck {
        RepositoryCheck(id: id, title: title, category: category, symbol: symbol, evaluate: { context in
            let policy = try RepositoryCheckPolicy.load(context)
            let paths = try paths(context)
            var findings: [RepositoryFinding] = [], reasons: [String] = [], failedPaths = 0
            for path in paths {
                do {
                    let result = try evaluate(context, policy, path)
                    findings += result.detectedFindings
                    switch result {
                    case .findings: break
                    case .partial(_, let reason), .unavailable(let reason), .notApplicable(let reason), .skipped(let reason):
                        failedPaths += 1
                        if reasons.count < 5 { reasons.append(reason) }
                    }
                }
                catch {
                    failedPaths += 1
                    if reasons.count < 5 { reasons.append(error.localizedDescription) }
                }
            }
            findings = context.applyingExceptions(findings, policy: policy)
            guard failedPaths > 0 else { return .findings(findings) }
            let remainder = failedPaths > reasons.count ? "\n\(failedPaths - reasons.count) additional paths could not be inspected." : ""
            return .partial(findings, reasons.joined(separator: "\n") + remainder)
        })
    }
    static func finding(_ context: RepositoryInspectionContext, _ id: String, _ subject: String, _ title: String,
                        _ evidence: String, _ category: IssueCategory = .setup, _ symbol: String = "checkmark.shield",
                        severity: IssueSeverity = .attention) -> RepositoryFinding {
        RepositoryFinding(repositoryID: context.snapshot.id, checkID: id, subject: subject, title: title,
                          evidence: evidence, category: category, severity: severity, symbol: symbol)
    }
    static func rootFiles(_ context: RepositoryInspectionContext) throws -> [String] {
        guard let files = context.snapshot.rootFiles else { throw InspectionError.blocked("Repository root files could not be inspected.") }
        return files
    }
    static func manifests(_ context: RepositoryInspectionContext) throws -> [String] {
        let roots = try rootFiles(context).filter { ["package.json", "pyproject.toml", "requirements.txt"].contains($0) }
        let nested = try context.trackedPaths(matching: [":(glob)**/package.json", ":(glob)**/pyproject.toml", ":(glob)**/requirements.txt"]).filter {
            ["package.json", "pyproject.toml", "requirements.txt"].contains(($0 as NSString).lastPathComponent) &&
            !$0.split(separator: "/").contains(where: { ["node_modules", ".venv", "vendor"].contains(String($0)) })
        }
        let paths = Set(roots + nested).sorted()
        guard paths.count <= 64 else { throw InspectionError.blocked("More than 64 dependency manifests need inspection.") }
        return paths
    }
    static func applicableManifests(_ context: RepositoryInspectionContext,
                                    names: Set<String> = ["package.json", "pyproject.toml", "requirements.txt"]) throws -> [String] {
        let paths = try manifests(context).filter { names.contains(($0 as NSString).lastPathComponent) }
        guard !paths.isEmpty else {
            throw InspectionError.notApplicable("No supported manifests found (" + names.sorted().joined(separator: ", ") + "). Other ecosystems are outside this check's scope.")
        }
        return paths
    }
    static func applicableWorkflows(_ context: RepositoryInspectionContext) throws -> [(String, String)] {
        let files = try workflows(context)
        guard !files.isEmpty else { throw InspectionError.notApplicable("No GitHub Actions workflows are present.") }
        return files
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
                guard line.hasSuffix("]") else { throw InspectionError.blocked("Unsupported TOML table syntax.") }
                if line.hasPrefix("[[") {
                    guard line.hasSuffix("]]") else { throw InspectionError.blocked("Unsupported TOML table syntax.") }
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
            guard let equals = pending.firstIndex(of: "=") else { throw InspectionError.blocked("Unsupported TOML configuration.") }
            let key = String(pending[..<equals]).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            let value = String(pending[pending.index(after: equals)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty, !value.contains("\"\"\""), !value.contains("'''"), !key.contains(" ") else {
                throw InspectionError.blocked("Unsupported TOML value syntax.")
            }
            let qualified = section.isEmpty ? key : section + "." + key
            guard values[qualified] == nil else { throw InspectionError.blocked("Duplicate TOML setting: " + qualified) }
            values[qualified] = value
            pending = ""
        }
        guard pending.isEmpty else { throw InspectionError.blocked("Incomplete TOML value.") }
        return Self(values: values)
    }
    static func yaml(_ source: String) throws -> Self {
        guard !source.contains("\t"), !CheckSupport.matches(source, #"(?m)^\s*(?:<<:|[^#\n]*:\s*[&*])"#) else {
            throw InspectionError.blocked("YAML anchors or tabs require manual review.")
        }
        var values: [String: String] = [:], parents: [(Int, String)] = []
        for raw in source.components(separatedBy: .newlines) {
            let line = withoutComment(raw)
            guard !line.isEmpty, line != "---" else { continue }
            let indent = raw.prefix { $0 == " " }.count
            while parents.last.map({ $0.0 >= indent }) == true { parents.removeLast() }
            if line.hasPrefix("- ") {
                guard let parent = parents.last else { throw InspectionError.blocked("Unsupported YAML sequence.") }
                values[parent.1, default: ""] += "\n" + String(line.dropFirst(2))
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { throw InspectionError.blocked("Unsupported YAML setting.") }
            let key = String(line[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            let path = (parents.last.map { $0.1 + "." } ?? "") + key
            guard values[path] == nil else { throw InspectionError.blocked("Duplicate YAML setting: " + path) }
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
            guard let equals = line.firstIndex(of: "=") else { throw InspectionError.blocked("Unsupported npm configuration.") }
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            guard values[key] == nil else { throw InspectionError.blocked("Duplicate npm setting: " + key) }
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
