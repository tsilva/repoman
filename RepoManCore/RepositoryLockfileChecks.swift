import Foundation

enum RepositoryLockfileChecks {
    static func checks() -> [RepositoryCheck] {
        [RepositoryCheck(id: "dependencies.lockfileDrift", title: "Manifest and lockfile disagree", category: .setup, symbol: "lock.trianglebadge.exclamationmark", evaluate: { context in
            let policy = try RepositoryCheckPolicy.load(context)
            var findings: [RepositoryFinding] = []
            var unknown: [String] = []
            for manifest in try CheckSupport.applicableManifests(context, names: ["package.json", "pyproject.toml"]) {
                do {
                    let prefixes = try RepositoryDependencyChecks.lockPrefixes(context, manifest)
                    let js = manifest.hasSuffix("package.json")
                    let manager = js ? try RepositoryDependencyChecks.manager(context, manifest) : "uv"
                    let names = js ? RepositoryDependencyChecks.lockNames(manager) : ["uv.lock"]
                    var candidates: [String] = []
                    for prefix in prefixes { for name in names where try context.exists(prefix + name) { candidates.append(prefix + name) } }
                    // The separate lockfile detector handles absence and tracking.
                    guard let lock = candidates.first else { throw InspectionError.blocked("No lockfile is available to verify manifest synchronization: " + manifest) }
                    let directory = (manifest as NSString).deletingLastPathComponent
                    let lockDirectory = (lock as NSString).deletingLastPathComponent
                    let relative = lockDirectory.isEmpty ? directory : String(directory.dropFirst(lockDirectory.count + 1))
                    let reasons: [String]
                    if js {
                        let expected = try json(context, manifest)
                        switch manager {
                        case "npm": reasons = try npm(expected, lock: json(context, lock), directory: relative)
                        case "pnpm":
                            let configuration = try pnpmConfiguration(context, prefixes: prefixes, lockDirectory: lockDirectory)
                            let comparison = try pnpm(expected, lock: context.readText(lock), directory: relative,
                                               overrides: resolvedPNPMOverrides(configuration.overrides, root: configuration.root),
                                               supportsQualifiedOverrides: CheckSupport.matches(configuration.root["packageManager"] as? String ?? "", #"^pnpm@10\.[0-9]+\.[0-9]+(?:\+[^\s]+)?$"#))
                            reasons = comparison.reasons
                            unknown += comparison.unknown.map { manifest + ": " + $0 }
                        case "bun":
                            guard lock.hasSuffix("bun.lock") else { throw InspectionError.blocked("Binary bun.lockb cannot be inspected statically; use a text bun.lock for manifest synchronization checks.") }
                            reasons = try bun(expected, source: context.readText(lock), directory: relative)
                        default: throw InspectionError.blocked("Static lockfile drift inspection supports npm v2/v3, pnpm v9, Bun text lockfiles and simple uv v1 projects; this manager needs manual review.")
                        }
                    } else { reasons = try uv(project: context.readText(manifest), lock: context.readText(lock), directory: relative, manifest: manifest) }
                    if !reasons.isEmpty {
                        findings.append(CheckSupport.finding(context, "dependencies.lockfileDrift", manifest, "Manifest and lockfile disagree",
                            "\(manifest) differs from \(lock): " + reasons.joined(separator: "; ") + ". No resolver or installer was run.", .setup, "lock.trianglebadge.exclamationmark"))
                    }
                } catch { unknown.append(manifest + ": " + error.localizedDescription) }
            }
            let applicable = context.applyingExceptions(findings, policy: policy)
            return unknown.isEmpty ? .findings(applicable) : .partial(applicable, unknown.prefix(10).joined(separator: "\n"))
        })]
    }
    static func json(_ context: RepositoryInspectionContext, _ path: String) throws -> [String: Any] {
        try context.jsonObject(path)
    }
    private static let dependencyTypes = ["dependencies", "devDependencies", "optionalDependencies", "peerDependencies"]
    private static func dependencies(_ object: [String: Any], _ type: String) throws -> [String: String] {
        guard let raw = object[type] else { return [:] }
        guard let map = raw as? [String: String] else { throw InspectionError.blocked("Unsupported dependency map: " + type) }
        return map
    }
    private static func differences(_ expected: [String: String], _ actual: [String: String], label: String) -> [String] {
        Set(expected.keys).union(actual.keys).sorted().compactMap { key in
            guard expected[key] != actual[key] else { return nil }
            // Dependency values can include authenticated URLs; names only are safe evidence.
            return "\(label).\(key) has a missing, extra or changed declaration"
        }
    }
    private static func npm(_ expected: [String: Any], lock: [String: Any], directory: String) throws -> [String] {
        guard let version = lock["lockfileVersion"] as? Int, [2, 3].contains(version),
              let packages = lock["packages"] as? [String: [String: Any]] else {
            throw InspectionError.blocked("Unsupported npm lockfile schema.")
        }
        guard let entry = packages[directory] else { return ["workspace package metadata is missing"] }
        let deps = try dependencies(expected, "dependencies"), optional = try dependencies(expected, "optionalDependencies")
        guard Set(deps.keys).isDisjoint(with: optional.keys) else { throw InspectionError.blocked("Overlapping optional and regular dependencies need resolver review.") }
        return try dependencyTypes.flatMap { type in
            differences(try dependencies(expected, type), try dependencies(entry, type), label: type)
        }
    }
    private static func bun(_ expected: [String: Any], source: String, directory: String) throws -> [String] {
        // Foundation's JSON5 reader handles Bun's JSONC comments and trailing commas
        // without corrupting comment markers, URLs or commas inside dependency strings.
        guard #available(macOS 12.0, *) else { throw InspectionError.blocked("Bun text lockfile inspection requires macOS 12 or later.") }
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: Data(source.utf8), options: [.json5Allowed]) }
        catch { throw InspectionError.blocked("Malformed Bun text lockfile.") }
        guard let lock = object as? [String: Any], let version = lock["lockfileVersion"] as? Int,
              [0, 1].contains(version), let workspaces = lock["workspaces"] as? [String: [String: Any]],
              lock["packages"] is [String: Any] else { throw InspectionError.blocked("Unsupported Bun text lockfile schema.") }
        if let configVersion = lock["configVersion"] {
            guard let version = configVersion as? Int, [0, 1].contains(version) else {
                throw InspectionError.blocked("Unsupported Bun lockfile configuration version.")
            }
        }
        guard let entry = workspaces[directory] else { return ["workspace package metadata is missing"] }
        var result: [String] = []
        for type in dependencyTypes {
            let wanted = try dependencies(expected, type), actual = try dependencies(entry, type)
            guard !wanted.values.contains(where: { $0.hasPrefix("catalog:") }),
                  !actual.values.contains(where: { $0.hasPrefix("catalog:") }) else {
                throw InspectionError.blocked("Bun catalogs need resolver review.")
            }
            result += differences(wanted, actual, label: type)
        }
        return result
    }
    private static func pnpmConfiguration(_ context: RepositoryInspectionContext, prefixes: [String], lockDirectory: String) throws -> (overrides: [String: String], root: [String: Any]) {
        var rootPrefix = lockDirectory.isEmpty ? "" : lockDirectory + "/"
        for prefix in prefixes where try context.exists(prefix + "pnpm-workspace.yaml") {
            rootPrefix = prefix
            break
        }
        let root = try context.exists(rootPrefix + "package.json") ? json(context, rootPrefix + "package.json") : [:]
        var manifestOverrides: [String: String] = [:]
        if let raw = root["pnpm"] {
            guard let settings = raw as? [String: Any] else { throw InspectionError.blocked("Unsupported pnpm manifest settings.") }
            manifestOverrides = try dependencies(settings, "overrides")
        }
        var workspaceOverrides: [String: String] = [:]
        if try context.exists(rootPrefix + "pnpm-workspace.yaml") {
            workspaceOverrides = try pnpmOverrideMap(context.yaml(rootPrefix + "pnpm-workspace.yaml").values)
        }
        guard manifestOverrides.isEmpty || workspaceOverrides.isEmpty || manifestOverrides == workspaceOverrides else {
            throw InspectionError.blocked("Multiple pnpm override sources need resolver review.")
        }
        return (workspaceOverrides.isEmpty ? manifestOverrides : workspaceOverrides, root)
    }
    private static func pnpmOverrideMap(_ values: [String: String]) throws -> [String: String] {
        if let raw = values["overrides"], !raw.isEmpty && raw != "{}" {
            throw InspectionError.blocked("Inline pnpm overrides need resolver review.")
        }
        var result: [String: String] = [:]
        for (key, raw) in values where key.hasPrefix("overrides.") {
            guard let value = InspectionConfig.scalar(raw), !value.isEmpty,
                  !value.hasPrefix("{"), !value.hasPrefix("[") else {
                throw InspectionError.blocked("Unsupported pnpm override declaration.")
            }
            result[String(key.dropFirst("overrides.".count))] = value
        }
        return result
    }
    private static func resolvedPNPMOverrides(_ overrides: [String: String], root: [String: Any]) throws -> [String: String] {
        try overrides.mapValues { override in
            guard override.hasPrefix("$") else { return override }
            let reference = String(override.dropFirst())
            let declarations = try Set(dependencyTypes.dropLast().compactMap { try dependencies(root, $0)[reference] })
            guard declarations.count == 1, let value = declarations.first, !value.hasPrefix("$") else {
                throw InspectionError.blocked("A pnpm override reference needs resolver review.")
            }
            return value
        }
    }
    private static func pnpm(_ expected: [String: Any], lock: String, directory: String, overrides: [String: String], supportsQualifiedOverrides: Bool) throws -> (reasons: [String], unknown: [String]) {
        let values = try InspectionConfig.yaml(lock).values
        guard InspectionConfig.scalar(values["lockfileVersion"]) == "9.0" else { throw InspectionError.blocked("Unsupported pnpm lockfile schema.") }
        guard try pnpmOverrideMap(values) == overrides else { return (["pnpm override declarations differ from lockfile metadata"], []) }
        guard try dependencies(expected, "peerDependencies").isEmpty else { throw InspectionError.blocked("pnpm peer auto-install behavior needs resolver review.") }
        let prefix = "importers." + (directory.isEmpty ? "." : directory)
        guard let importer = values[prefix] else { return (["workspace importer is missing"], []) }
        guard importer.isEmpty || importer == "{}" else { throw InspectionError.blocked("Inline pnpm importers need manual review.") }
        var result: [String] = [], unknown: [String] = []
        for type in dependencyTypes.dropLast() {
            var wanted = try dependencies(expected, type)
            guard !wanted.values.contains(where: { $0.hasPrefix("catalog:") }) else { throw InspectionError.blocked("pnpm catalogs need resolver review.") }
            let start = prefix + "." + type + "."
            var actual: [String: String] = [:]
            for (key, raw) in values where key.hasPrefix(start) && key.hasSuffix(".specifier") {
                actual[String(key.dropFirst(start.count).dropLast(".specifier".count))] = InspectionConfig.scalar(raw)
            }
            if let raw = values[prefix + "." + type], !raw.isEmpty && raw != "{}" { throw InspectionError.blocked("Inline pnpm dependency maps need manual review.") }
            // Every nonempty locked entry must contain a specifier, otherwise absence is unknown.
            for key in values.keys where key.hasPrefix(start) && !key.dropFirst(start.count).contains(".") {
                guard actual[String(key.dropFirst(start.count))] != nil else { throw InspectionError.blocked("pnpm dependency metadata lacks a specifier.") }
            }
            var uncertain = Set<String>()
            for name in wanted.keys {
                do {
                    let declared = wanted[name]!
                    var applicable = Set(overrides[name].map { [$0] } ?? [])
                    for (selector, target) in overrides where selector.hasPrefix(name + "@") {
                        guard supportsQualifiedOverrides,
                              let range = NPMVersionRange.parse(String(selector.dropFirst(name.count + 1))),
                              let requirement = NPMVersionRange.parse(declared) else {
                            throw InspectionError.blocked("This pnpm version-qualified override needs resolver review; static applicability requires pnpm 10 and supported stable numeric ranges.")
                        }
                        if range.overlaps(requirement) { applicable.insert(target) }
                    }
                    guard applicable.count <= 1 else { throw InspectionError.blocked("Competing applicable pnpm overrides need resolver review.") }
                    if let override = applicable.first {
                        guard override != "-" else { throw InspectionError.blocked("Removing direct dependencies through pnpm overrides needs resolver review.") }
                        wanted[name] = override
                    }
                    if overrides.keys.contains(where: {
                        $0.hasSuffix(">" + name) || $0.contains(">" + name + "@")
                    }) {
                        throw InspectionError.blocked("A parent-qualified pnpm override needs resolver review.")
                    }
                } catch {
                    uncertain.insert(name)
                    unknown.append(type + "." + name + ": " + error.localizedDescription)
                }
            }
            for name in uncertain { wanted.removeValue(forKey: name); actual.removeValue(forKey: name) }
            result += differences(wanted, actual, label: type)
        }
        return (result, unknown)
    }
    private static func uv(project: String, lock: String, directory: String, manifest: String) throws -> [String] {
        let projectValues = try InspectionConfig.toml(project, allSections: true).values
        var unsupported: [String] = []
        if projectValues["project.dynamic"] != nil { unsupported.append("project.dynamic") }
        for section in ["tool.uv.sources", "tool.uv.dev-dependencies"] {
            if projectValues.keys.contains(where: { $0 == section || $0.hasPrefix(section + ".") }) {
                unsupported.append(section)
            }
        }
        if !unsupported.isEmpty {
            throw InspectionError.blocked(manifest + ": static lockfile verification does not support "
                + unsupported.joined(separator: ", ") + ". Verify separately with uv lock --check using the repository's resolver settings; no resolver was run.")
        }
        let groups = try pythonDependencyGroups(projectValues, source: project)
        var expected = ["": try pythonRequirements(projectValues["project.dependencies"] ?? "[]")]
        let optionalPrefix = "project.optional-dependencies."
        guard projectValues["project.optional-dependencies"] == nil else {
            throw InspectionError.blocked("Inline Python optional dependency tables need manual review.")
        }
        for (key, raw) in projectValues where key.hasPrefix(optionalPrefix) {
            let group = try pythonName(String(key.dropFirst(optionalPrefix.count)))
            guard expected[group] == nil else { throw InspectionError.blocked("Duplicate Python optional dependency groups.") }
            expected[group] = try pythonRequirements(raw)
        }
        let sections = lock.components(separatedBy: "[[package]]")
        let header = try InspectionConfig.toml(sections[0], allSections: true).values
        guard InspectionConfig.scalar(header["version"]) == "1" else { throw InspectionError.blocked("Unsupported uv lockfile schema.") }
        let target = directory.isEmpty ? "." : directory
        var metadata: [String: String]?, metadataSource = ""
        for section in sections.dropFirst() {
            let values = try InspectionConfig.toml(section, allSections: true).values
            let source = values["source"] ?? ""
            let locations = CheckSupport.captures(source, #"(?:editable|virtual)\s*=\s*["']([^"']+)["']"#).map { $0[1] }
            if locations == [target] {
                guard metadata == nil else { throw InspectionError.blocked("Duplicate uv workspace metadata.") }
                metadata = values
                metadataSource = section
            }
        }
        guard let metadata else { return ["workspace package metadata is missing"] }
        let extras = try pythonExtras(metadata["package.metadata.provides-extras"] ?? "[]")
        let actual = try lockedPythonRequirements(metadata["package.metadata.requires-dist"] ?? "[]", extras: extras)
        try validatePythonGroupTableShape(metadataSource, header: "package.metadata.requires-dev")
        let lockedGroups = try pythonGroupTable(metadata, prefix: "package.metadata.requires-dev")
        var actualGroups: [String: PythonRequirements] = [:]
        for (group, raw) in lockedGroups {
            let requirements = try lockedPythonRequirements(raw, extras: [], allowDuplicates: true)
            actualGroups[group] = requirements[""]
        }
        let dependencyReasons = Set(expected.keys).union(actual.keys).sorted().flatMap { group -> [String] in
            let label = group.isEmpty ? "dependencies" : "optional-dependencies." + group
            guard let wanted = expected[group], let locked = actual[group] else {
                return [label + " is missing or extra"]
            }
            return pythonDifferences(wanted, locked, label: label)
        }
        return dependencyReasons + Set(groups.keys).union(actualGroups.keys).sorted().flatMap { group -> [String] in
            let label = "dependency-groups." + group
            guard let wanted = groups[group], let locked = actualGroups[group] else {
                return [label + " is missing or extra"]
            }
            return pythonDifferences(wanted, locked, label: label)
        }
    }
    private typealias PythonRequirements = [String: Set<String>]
    private static func pythonDifferences(_ wanted: PythonRequirements, _ locked: PythonRequirements, label: String) -> [String] {
        // Marker expressions and dependency values never appear in evidence.
        let names = Set(wanted.keys).union(locked.keys).filter { wanted[$0] != locked[$0] }
            .map { $0.components(separatedBy: "\u{1F}")[0] }
        return Set(names).sorted().map { label + "." + $0 + " has a missing, extra or changed declaration" }
    }
    private static func pythonRequirements(_ raw: String, allowDuplicates: Bool = false) throws -> PythonRequirements {
        var result: PythonRequirements = [:]
        for item in try tomlElements(raw) {
            let requirement = try tomlString(item)
            let parts = requirement.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            let marker = parts.count == 2 ? try pythonMarker(String(parts[1])) : nil
            guard marker?.extraGroups == nil else { throw InspectionError.blocked("Extra markers inside requirement declarations need resolver review.") }
            let matches = CheckSupport.captures(String(parts[0]), #"^([A-Za-z0-9][A-Za-z0-9._-]*)\s*(?:\[([^\[\]]+)\])?\s*(.*)$"#)
            guard let match = matches.first else { throw InspectionError.blocked("Unsupported Python requirement declaration.") }
            let name = try pythonName(match[1])
            let extras = try Set(match[2].isEmpty ? [] : match[2].components(separatedBy: ",").map { try pythonName($0.trimmingCharacters(in: .whitespaces)) })
            let specifier = match[3].trimmingCharacters(in: .whitespaces)
            try validatePythonSpecifier(specifier)
            let key = name + (marker.map { "\u{1F}" + $0.canonical } ?? "")
            guard allowDuplicates || result[key] == nil else { throw InspectionError.blocked("Duplicate Python requirements need resolver review.") }
            result[key, default: []].insert(pythonDeclaration(specifier: specifier, extras: extras))
        }
        return result
    }
    private static func validatePythonSpecifier(_ specifier: String) throws {
        guard !specifier.isEmpty else { return }
        for term in specifier.split(separator: ",", omittingEmptySubsequences: false) {
            // PEP 440 numeric, prerelease, postrelease, dev and local versions; no direct sources.
            let pattern = #"(?i)^\s*(==|!=|>=|<=|>|<|~=)\s*(?:[0-9]+!)?[0-9]+(?:\.[0-9]+)*(?:[-_.]?(?:a|b|rc)[0-9]+)?(?:[-_.]?post[0-9]+)?(?:[-_.]?dev[0-9]+)?(?:\+[a-z0-9]+(?:[-_.][a-z0-9]+)*)?(\.\*)?\s*$"#
            guard let match = CheckSupport.captures(String(term), pattern).first,
                  match[2].isEmpty || ["==", "!="].contains(match[1]) else {
                throw InspectionError.blocked("Direct sources or unsupported Python version specifiers need resolver review.")
            }
        }
    }
    private static func pythonInlineTable(_ raw: String) throws -> [String: String] {
        var result: [String: String] = [:]
        for entry in try tomlElements(raw, opening: "{", closing: "}") {
            guard let equal = entry.firstIndex(of: "=") else { throw InspectionError.blocked("Unsupported Python inline table.") }
            let rawKey = String(entry[..<equal]).trimmingCharacters(in: .whitespacesAndNewlines)
            let key = rawKey.hasPrefix("\"") || rawKey.hasPrefix("'") ? try tomlString(rawKey) : rawKey
            guard !key.isEmpty, result[key] == nil else { throw InspectionError.blocked("Duplicate Python inline table fields.") }
            result[key] = String(entry[entry.index(after: equal)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }
    private static func pythonGroupTable(_ values: [String: String], prefix: String) throws -> [String: String] {
        var raw: [String: String] = [:]
        if let inline = values[prefix] { raw = try pythonInlineTable(inline) }
        for (key, value) in values where key.hasPrefix(prefix + ".") {
            let name = String(key.dropFirst(prefix.count + 1))
            guard raw[name] == nil else { throw InspectionError.blocked("Duplicate Python dependency group declarations.") }
            raw[name] = value
        }
        var result: [String: String] = [:]
        for (name, value) in raw {
            let normalized = try pythonName(name)
            guard result[normalized] == nil else { throw InspectionError.blocked("Duplicate normalized Python dependency group names.") }
            result[normalized] = value
        }
        guard result.count <= 64 else { throw InspectionError.blocked("Python dependency-group count exceeds the inspection limit.") }
        return result
    }
    private static func validatePythonGroupTableShape(_ source: String, header: String) throws {
        var inside = false
        for raw in source.components(separatedBy: .newlines) {
            let line = InspectionConfig.withoutComment(raw)
            if line.hasPrefix("[") {
                if line.hasPrefix("[" + header + ".") {
                    throw InspectionError.blocked("Nested Python dependency-group tables need manual review.")
                }
                inside = line == "[" + header + "]"
            } else if inside, CheckSupport.matches(line, #"^[A-Za-z0-9_-]+\.[A-Za-z0-9_.-]+\s*="#) {
                throw InspectionError.blocked("Nested Python dependency-group keys need manual review.")
            }
        }
    }
    private static func pythonDependencyGroups(_ values: [String: String], source: String) throws -> [String: PythonRequirements] {
        try validatePythonGroupTableShape(source, header: "dependency-groups")
        let raw = try pythonGroupTable(values, prefix: "dependency-groups")
        var memo: [String: PythonRequirements] = [:], budget = 4096
        func resolve(_ group: String, path: Set<String>) throws -> PythonRequirements {
            guard !path.contains(group), path.count < 32 else { throw InspectionError.blocked("Cyclic or excessively deep dependency-group includes.") }
            if let cached = memo[group] { return cached }
            guard let entries = raw[group] else { throw InspectionError.blocked("A dependency-group include references a missing group.") }
            var result: PythonRequirements = [:]
            for entry in try tomlElements(entries) {
                budget -= 1
                guard budget >= 0 else { throw InspectionError.blocked("Dependency-group expansion exceeds the inspection limit.") }
                let requirements: PythonRequirements
                if entry.hasPrefix("{") {
                    let include = try pythonInlineTable(entry)
                    guard Set(include.keys) == ["include-group"], let name = include["include-group"] else {
                        throw InspectionError.blocked("Unsupported dependency-group include fields.")
                    }
                    requirements = try resolve(pythonName(tomlString(name)), path: path.union([group]))
                } else { requirements = try pythonRequirements("[" + entry + "]", allowDuplicates: true) }
                for (name, declarations) in requirements { result[name, default: []].formUnion(declarations) }
                guard result.values.reduce(0, { $0 + $1.count }) <= 4096 else {
                    throw InspectionError.blocked("Dependency-group expansion exceeds the inspection limit.")
                }
            }
            memo[group] = result
            return result
        }
        for group in raw.keys.sorted() { _ = try resolve(group, path: []) }
        return memo
    }
    private static func lockedPythonRequirements(_ raw: String, extras: Set<String>, allowDuplicates: Bool = false) throws -> [String: PythonRequirements] {
        var result: [String: PythonRequirements] = ["": [:]]
        for extra in extras { result[extra] = [:] }
        for record in try tomlElements(raw) {
            var fields: [String: String] = [:]
            for pair in try tomlElements(record, opening: "{", closing: "}") {
                guard let equals = pair.firstIndex(of: "=") else { throw InspectionError.blocked("Unsupported uv inline dependency metadata.") }
                let key = String(pair[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard fields[key] == nil else { throw InspectionError.blocked("Duplicate uv dependency metadata fields.") }
                fields[key] = String(pair[pair.index(after: equals)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard Set(fields.keys).isSubset(of: ["name", "specifier", "extras", "marker"]), let rawName = fields["name"] else {
                throw InspectionError.blocked("Python lock metadata needs resolver review.")
            }
            let name = try pythonName(tomlString(rawName))
            let specifier = try fields["specifier"].map { try tomlString($0) } ?? ""
            let dependencyExtras = try pythonExtras(fields["extras"] ?? "[]")
            try validatePythonSpecifier(specifier)
            let marker = try fields["marker"].map { try pythonMarker(tomlString($0)) }
            let groups = marker?.extraGroups ?? [""]
            guard marker?.extraGroups == nil || (!allowDuplicates && groups.isSubset(of: extras)) else {
                throw InspectionError.blocked("Python lock metadata references an undeclared extra.")
            }
            let environmentMarker = marker?.extraGroups == nil ? marker?.canonical : nil
            let key = name + (environmentMarker.map { "\u{1F}" + $0 } ?? "")
            for group in groups {
                guard allowDuplicates || result[group]?[key] == nil else { throw InspectionError.blocked("Duplicate locked Python requirements.") }
                result[group, default: [:]][key, default: []].insert(pythonDeclaration(specifier: specifier, extras: dependencyExtras))
            }
        }
        return result
    }
    private indirect enum PythonMarker {
        case comparison(String, String, String)
        case all([PythonMarker])
        case any([PythonMarker])
        var canonical: String {
            switch self {
            case let .comparison(left, op, right):
                // uv serializes minor-version upper bounds with python_full_version.
                // Do not conflate equality or patch-level bounds: those have different meanings.
                let normalized = left == "v:python_version" && op == "<" && CheckSupport.matches(right, #"^s:[0-9]+\.[0-9]+$"#)
                    ? "v:python_full_version" : left
                return "\(normalized.utf8.count):\(normalized)\(op)\(right.utf8.count):\(right)"
            case .all(let nodes):
                let flattened = nodes.flatMap { $0.terms(conjunction: true) }
                return "and[" + Set(flattened.map(\.canonical)).sorted().map { "\($0.utf8.count):\($0)" }.joined() + "]"
            case .any(let nodes):
                let flattened = nodes.flatMap { $0.terms(conjunction: false) }
                return "or[" + Set(flattened.map(\.canonical)).sorted().map { "\($0.utf8.count):\($0)" }.joined() + "]"
            }
        }
        private func terms(conjunction: Bool) -> [PythonMarker] {
            switch self {
            case .all(let nodes) where conjunction: return nodes.flatMap { $0.terms(conjunction: true) }
            case .any(let nodes) where !conjunction: return nodes.flatMap { $0.terms(conjunction: false) }
            default: return [self]
            }
        }
        var mentionsExtra: Bool {
            switch self {
            case let .comparison(left, _, right): return left == "v:extra" || right == "v:extra"
            case .all(let nodes), .any(let nodes): return nodes.contains { $0.mentionsExtra }
            }
        }
        var extraGroups: Set<String>? {
            switch self {
            case let .comparison(left, op, right):
                guard op == "==" else { return nil }
                if left == "v:extra", right.hasPrefix("s:") { return [normalizeName(String(right.dropFirst(2)))] }
                if right == "v:extra", left.hasPrefix("s:") { return [normalizeName(String(left.dropFirst(2)))] }
                return nil
            case .any(let nodes):
                var result: Set<String> = []
                for node in nodes { guard let names = node.extraGroups else { return nil }; result.formUnion(names) }
                return result
            case .all: return nil
            }
        }
    }
    /// Parse marker declarations for comparison only; never evaluate the host environment.
    private static func pythonMarker(_ source: String) throws -> PythonMarker {
        let variables: Set<String> = ["python_version", "python_full_version", "os_name", "sys_platform", "platform_release",
            "platform_system", "platform_version", "platform_machine", "platform_python_implementation",
            "implementation_name", "implementation_version", "extra"]
        let chars = Array(source), operators: Set<String> = ["==", "!=", "<=", ">=", "<", ">", "~=", "===", "in", "not in"]
        guard chars.count <= 8192 else { throw InspectionError.blocked("Python marker exceeds the inspection limit.") }
        var tokens: [String] = [], cursor = 0
        while cursor < chars.count {
            let c = chars[cursor]
            if c.isWhitespace { cursor += 1; continue }
            if c == "'" || c == "\"" {
                let quote = c; cursor += 1; var value = ""
                while cursor < chars.count, chars[cursor] != quote {
                    guard chars[cursor] != "\\" else { throw InspectionError.blocked("Escaped Python markers need resolver review.") }
                    value.append(chars[cursor]); cursor += 1
                }
                guard cursor < chars.count else { throw InspectionError.blocked("Unterminated Python marker string.") }
                tokens.append("s:" + value); cursor += 1
            } else if c == "(" || c == ")" { tokens.append(String(c)); cursor += 1 }
            else if c.isLetter || c == "_" {
                let start = cursor
                while cursor < chars.count, chars[cursor].isLetter || chars[cursor].isNumber || chars[cursor] == "_" { cursor += 1 }
                let word = String(chars[start..<cursor])
                guard variables.contains(word) || ["and", "or", "in", "not"].contains(word) else {
                    throw InspectionError.blocked("Unsupported Python marker variable or operator.")
                }
                tokens.append(variables.contains(word) ? "v:" + word : word)
            } else {
                let start = cursor
                while cursor < chars.count, "=!<>~".contains(chars[cursor]) { cursor += 1 }
                let op = String(chars[start..<cursor])
                guard cursor > start, operators.contains(op) else { throw InspectionError.blocked("Unsupported Python marker syntax.") }
                tokens.append(op)
            }
            guard tokens.count <= 256 else { throw InspectionError.blocked("Python marker token limit exceeded.") }
        }
        var index = 0
        func operand() throws -> String {
            guard index < tokens.count, tokens[index].hasPrefix("v:") || tokens[index].hasPrefix("s:") else {
                throw InspectionError.blocked("Invalid Python marker operand.")
            }
            defer { index += 1 }; return tokens[index]
        }
        func atom(_ depth: Int) throws -> PythonMarker {
            guard depth < 32, index < tokens.count else { throw InspectionError.blocked("Incomplete or excessively deep Python marker.") }
            if tokens[index] == "(" {
                index += 1; let node = try expression(depth + 1)
                guard index < tokens.count, tokens[index] == ")" else { throw InspectionError.blocked("Unbalanced Python marker parentheses.") }
                index += 1; return node
            }
            let left = try operand()
            guard index < tokens.count else { throw InspectionError.blocked("Missing Python marker operator.") }
            var op = tokens[index]; index += 1
            if op == "not", index < tokens.count, tokens[index] == "in" { op = "not in"; index += 1 }
            guard operators.contains(op) else { throw InspectionError.blocked("Invalid Python marker operator.") }
            return .comparison(left, op, try operand())
        }
        func conjunction(_ depth: Int) throws -> PythonMarker {
            var nodes = [try atom(depth)]
            while index < tokens.count, tokens[index] == "and" { index += 1; nodes.append(try atom(depth)) }
            return nodes.count == 1 ? nodes[0] : .all(nodes)
        }
        func expression(_ depth: Int) throws -> PythonMarker {
            var nodes = [try conjunction(depth)]
            while index < tokens.count, tokens[index] == "or" { index += 1; nodes.append(try conjunction(depth)) }
            return nodes.count == 1 ? nodes[0] : .any(nodes)
        }
        let result = try expression(0)
        guard index == tokens.count else { throw InspectionError.blocked("Trailing Python marker syntax.") }
        guard !result.mentionsExtra || result.extraGroups != nil else {
            throw InspectionError.blocked("Combined optional-extra and environment markers need resolver review.")
        }
        return result
    }
    private static func pythonDeclaration(specifier: String, extras: Set<String>) -> String {
        normalizeSpecifier(specifier) + "|" + extras.sorted().joined(separator: ",")
    }
    private static func pythonName(_ raw: String) throws -> String {
        guard CheckSupport.matches(raw, #"^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?$"#) else {
            throw InspectionError.blocked("Unsupported Python package or extra name.")
        }
        return normalizeName(raw)
    }
    private static func pythonExtras(_ raw: String) throws -> Set<String> {
        try Set(tomlElements(raw).map { try pythonName(tomlString($0)) })
    }
    private static func tomlString(_ raw: String) throws -> String {
        guard raw.count >= 2, let quote = raw.first, quote == "\"" || quote == "'", raw.last == quote else {
            throw InspectionError.blocked("Expected a Python metadata string.")
        }
        let value = String(raw.dropFirst().dropLast())
        guard !value.contains(quote), !value.contains("\\"), !value.contains("\n") else {
            throw InspectionError.blocked("Escaped or multiline Python metadata strings need manual review.")
        }
        return value
    }
    /// Split a restricted TOML array/table without splitting quoted commas or nested extras arrays.
    private static func tomlElements(_ raw: String, opening: Character = "[", closing: Character = "]") throws -> [String] {
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.first == opening, raw.last == closing else { throw InspectionError.blocked("Unsupported Python metadata collection.") }
        var result: [String] = [], current = "", quote: Character?, stack: [Character] = []
        for c in raw.dropFirst().dropLast() {
            if let q = quote {
                guard c != "\\" else { throw InspectionError.blocked("Escaped Python metadata needs manual review.") }
                current.append(c)
                if c == q { quote = nil }
                continue
            }
            if c == "\"" || c == "'" { quote = c }
            else if c == "[" { stack.append("]") }
            else if c == "{" { stack.append("}") }
            else if c == "]" || c == "}" {
                guard stack.popLast() == c else { throw InspectionError.blocked("Unbalanced Python metadata collection.") }
            } else if c == ",", stack.isEmpty {
                let item = current.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !item.isEmpty else { throw InspectionError.blocked("Empty Python metadata entry.") }
                result.append(item); current = ""; continue
            }
            current.append(c)
        }
        guard quote == nil, stack.isEmpty else { throw InspectionError.blocked("Incomplete Python metadata collection.") }
        let last = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty { result.append(last) }
        return result
    }
    private static func normalizeName(_ name: String) -> String { name.lowercased().replacingOccurrences(of: #"[-_.]+"#, with: "-", options: .regularExpression) }
    private static func normalizeSpecifier(_ spec: String) -> String { spec.replacingOccurrences(of: " ", with: "").split(separator: ",").sorted().joined(separator: ",") }
}

/// Bounded stable numeric npm ranges for override applicability and advisory consistency.
/// OR, hyphen ranges, prereleases, tags, aliases and exotic sources stay unknown.
struct NPMVersionRange: Sendable {
    var lower = 0
    var upper = Int.max
    func overlaps(_ other: Self) -> Bool { max(lower, other.lower) < min(upper, other.upper) }

    static func parse(_ source: String) -> Self? {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["*", "x", "X"].contains(text) { return Self() }
        let term = #"(>=|<=|>|<|=|\^|~)?\s*v?([0-9]+)(?:\.([0-9]+|[xX*]))?(?:\.([0-9]+|[xX*]))?"#
        guard CheckSupport.matches(text, "^" + term + "(?:\\s+" + term + ")*$") else { return nil }
        let matches = CheckSupport.captures(text, term)
        guard !matches.isEmpty, matches.count <= 16 else { return nil }
        var residue = text, result = Self()
        for match in matches {
            residue = residue.replacingOccurrences(of: match[0], with: "")
            for part in match[2...4] where !part.isEmpty && Int(part) != nil {
                guard part == "0" || !part.hasPrefix("0"), let number = Int(part), number < 1000 else { return nil }
            }
            guard let major = Int(match[2]), major < 1000 else { return nil }
            let minor = Int(match[3]), patch = Int(match[4])
            guard minor != nil || patch == nil else { return nil }
            let value = major * 1_000_000 + (minor ?? 0) * 1000 + (patch ?? 0)
            let partialUpper = minor == nil ? (major + 1) * 1_000_000 : patch == nil ? major * 1_000_000 + (minor! + 1) * 1000 : value + 1
            switch match[1] {
            case ">=": result.lower = max(result.lower, value)
            case ">": result.lower = max(result.lower, partialUpper)
            case "<": result.upper = min(result.upper, value)
            case "<=": result.upper = min(result.upper, partialUpper)
            case "^":
                result.lower = max(result.lower, value)
                let upper = major > 0 || minor == nil ? (major + 1) * 1_000_000
                    : minor! > 0 || patch == nil ? (minor! + 1) * 1000 : value + 1
                result.upper = min(result.upper, upper)
            case "~":
                result.lower = max(result.lower, value)
                result.upper = min(result.upper, minor == nil ? (major + 1) * 1_000_000 : major * 1_000_000 + (minor! + 1) * 1000)
            default: result.lower = max(result.lower, value); result.upper = min(result.upper, partialUpper)
            }
        }
        guard residue.allSatisfy(\.isWhitespace), result.lower < result.upper else { return nil }
        return result
    }
}
