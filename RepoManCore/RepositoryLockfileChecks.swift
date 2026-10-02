import Foundation

enum RepositoryLockfileChecks {
    static func checks() -> [RepositoryCheck] {
        [CheckSupport.check("dependencies.lockfileDrift", "Manifest and lockfile disagree", .setup, "lock.trianglebadge.exclamationmark", inspect: { context, _ in
            var findings: [RepositoryFinding] = []
            for manifest in try CheckSupport.manifests(context) where !manifest.hasSuffix("requirements.txt") {
                let prefixes = try RepositoryDependencyChecks.lockPrefixes(context, manifest)
                let js = manifest.hasSuffix("package.json")
                let manager = js ? try RepositoryDependencyChecks.manager(context, manifest) : "uv"
                let names = js ? RepositoryDependencyChecks.lockNames(manager) : ["uv.lock"]
                var candidates: [String] = []
                for prefix in prefixes { for name in names where try context.exists(prefix + name) { candidates.append(prefix + name) } }
                // The separate lockfile detector handles absence and tracking.
                guard let lock = candidates.first else { throw RepairError.blocked("No lockfile is available to verify manifest synchronization: " + manifest) }
                let directory = (manifest as NSString).deletingLastPathComponent
                let lockDirectory = (lock as NSString).deletingLastPathComponent
                let relative = lockDirectory.isEmpty ? directory : String(directory.dropFirst(lockDirectory.count + 1))
                let reasons: [String]
                if js {
                    let expected = try json(context, manifest)
                    switch manager {
                    case "npm": reasons = try npm(expected, lock: json(context, lock), directory: relative)
                    case "pnpm": reasons = try pnpm(expected, lock: context.readText(lock), directory: relative)
                    case "bun":
                        guard lock.hasSuffix("bun.lock") else { throw RepairError.blocked("Binary bun.lockb cannot be inspected statically; use a text bun.lock for manifest synchronization checks.") }
                        reasons = try bun(expected, source: context.readText(lock), directory: relative)
                    default: throw RepairError.blocked("Static lockfile drift inspection supports npm v2/v3, pnpm v9, Bun text lockfiles and simple uv v1 projects; this manager needs manual review.")
                    }
                } else { reasons = try uv(project: context.readText(manifest), lock: context.readText(lock), directory: relative) }
                if !reasons.isEmpty {
                    findings.append(CheckSupport.finding(context, "dependencies.lockfileDrift", manifest, "Manifest and lockfile disagree",
                        "\(manifest) differs from \(lock): " + reasons.joined(separator: "; ") + ". No resolver or installer was run.", .setup, "lock.trianglebadge.exclamationmark"))
                }
            }
            return findings
        })]
    }
    static func json(_ context: RepositoryInspectionContext, _ path: String) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: Data(context.readText(path).utf8)) as? [String: Any] else {
            throw RepairError.blocked("Expected a JSON object in " + path)
        }
        return result
    }
    private static let dependencyTypes = ["dependencies", "devDependencies", "optionalDependencies", "peerDependencies"]
    private static func dependencies(_ object: [String: Any], _ type: String) throws -> [String: String] {
        guard let raw = object[type] else { return [:] }
        guard let map = raw as? [String: String] else { throw RepairError.blocked("Unsupported dependency map: " + type) }
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
            throw RepairError.blocked("Unsupported npm lockfile schema.")
        }
        guard let entry = packages[directory] else { return ["workspace package metadata is missing"] }
        let deps = try dependencies(expected, "dependencies"), optional = try dependencies(expected, "optionalDependencies")
        guard Set(deps.keys).isDisjoint(with: optional.keys) else { throw RepairError.blocked("Overlapping optional and regular dependencies need resolver review.") }
        return try dependencyTypes.flatMap { type in
            differences(try dependencies(expected, type), try dependencies(entry, type), label: type)
        }
    }
    private static func bun(_ expected: [String: Any], source: String, directory: String) throws -> [String] {
        // Foundation's JSON5 reader handles Bun's JSONC comments and trailing commas
        // without corrupting comment markers, URLs or commas inside dependency strings.
        guard #available(macOS 12.0, *) else { throw RepairError.blocked("Bun text lockfile inspection requires macOS 12 or later.") }
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: Data(source.utf8), options: [.json5Allowed]) }
        catch { throw RepairError.blocked("Malformed Bun text lockfile.") }
        guard let lock = object as? [String: Any], let version = lock["lockfileVersion"] as? Int,
              [0, 1].contains(version), let workspaces = lock["workspaces"] as? [String: [String: Any]],
              lock["packages"] is [String: Any] else { throw RepairError.blocked("Unsupported Bun text lockfile schema.") }
        if let configVersion = lock["configVersion"] {
            guard let version = configVersion as? Int, [0, 1].contains(version) else {
                throw RepairError.blocked("Unsupported Bun lockfile configuration version.")
            }
        }
        guard let entry = workspaces[directory] else { return ["workspace package metadata is missing"] }
        var result: [String] = []
        for type in dependencyTypes {
            let wanted = try dependencies(expected, type), actual = try dependencies(entry, type)
            guard !wanted.values.contains(where: { $0.hasPrefix("catalog:") }),
                  !actual.values.contains(where: { $0.hasPrefix("catalog:") }) else {
                throw RepairError.blocked("Bun catalogs need resolver review.")
            }
            result += differences(wanted, actual, label: type)
        }
        return result
    }
    private static func pnpm(_ expected: [String: Any], lock: String, directory: String) throws -> [String] {
        let values = try InspectionConfig.yaml(lock).values
        guard InspectionConfig.scalar(values["lockfileVersion"]) == "9.0" else { throw RepairError.blocked("Unsupported pnpm lockfile schema.") }
        guard try dependencies(expected, "peerDependencies").isEmpty else { throw RepairError.blocked("pnpm peer auto-install behavior needs resolver review.") }
        let prefix = "importers." + (directory.isEmpty ? "." : directory)
        guard let importer = values[prefix] else { return ["workspace importer is missing"] }
        guard importer.isEmpty || importer == "{}" else { throw RepairError.blocked("Inline pnpm importers need manual review.") }
        var result: [String] = []
        for type in dependencyTypes.dropLast() {
            let wanted = try dependencies(expected, type)
            guard !wanted.values.contains(where: { $0.hasPrefix("catalog:") }) else { throw RepairError.blocked("pnpm catalogs need resolver review.") }
            let start = prefix + "." + type + "."
            var actual: [String: String] = [:]
            for (key, raw) in values where key.hasPrefix(start) && key.hasSuffix(".specifier") {
                actual[String(key.dropFirst(start.count).dropLast(".specifier".count))] = InspectionConfig.scalar(raw)
            }
            if let raw = values[prefix + "." + type], !raw.isEmpty && raw != "{}" { throw RepairError.blocked("Inline pnpm dependency maps need manual review.") }
            // Every nonempty locked entry must contain a specifier, otherwise absence is unknown.
            for key in values.keys where key.hasPrefix(start) && !key.dropFirst(start.count).contains(".") {
                guard actual[String(key.dropFirst(start.count))] != nil else { throw RepairError.blocked("pnpm dependency metadata lacks a specifier.") }
            }
            result += differences(wanted, actual, label: type)
        }
        return result
    }
    private static func uv(project: String, lock: String, directory: String) throws -> [String] {
        let projectValues = try InspectionConfig.toml(project, allSections: true).values
        guard projectValues["project.dynamic"] == nil,
              !projectValues.keys.contains(where: { $0 == "dependency-groups" || $0.hasPrefix("dependency-groups.") || $0 == "tool.uv.sources" || $0.hasPrefix("tool.uv.sources.") || $0 == "tool.uv.dev-dependencies" }) else {
            throw RepairError.blocked("Dynamic Python metadata, dependency groups and custom sources need resolver review.")
        }
        var expected = ["": try pythonRequirements(projectValues["project.dependencies"] ?? "[]")]
        let optionalPrefix = "project.optional-dependencies."
        guard projectValues["project.optional-dependencies"] == nil else {
            throw RepairError.blocked("Inline Python optional dependency tables need manual review.")
        }
        for (key, raw) in projectValues where key.hasPrefix(optionalPrefix) {
            let group = try pythonName(String(key.dropFirst(optionalPrefix.count)))
            guard expected[group] == nil else { throw RepairError.blocked("Duplicate Python optional dependency groups.") }
            expected[group] = try pythonRequirements(raw)
        }
        let sections = lock.components(separatedBy: "[[package]]")
        let header = try InspectionConfig.toml(sections[0], allSections: true).values
        guard InspectionConfig.scalar(header["version"]) == "1" else { throw RepairError.blocked("Unsupported uv lockfile schema.") }
        let target = directory.isEmpty ? "." : directory
        var metadata: [String: String]?
        for section in sections.dropFirst() {
            let values = try InspectionConfig.toml(section, allSections: true).values
            let source = values["source"] ?? ""
            let locations = CheckSupport.captures(source, #"(?:editable|virtual)\s*=\s*["']([^"']+)["']"#).map { $0[1] }
            if locations == [target] {
                guard metadata == nil else { throw RepairError.blocked("Duplicate uv workspace metadata.") }
                metadata = values
            }
        }
        guard let metadata else { return ["workspace package metadata is missing"] }
        let extras = try pythonExtras(metadata["package.metadata.provides-extras"] ?? "[]")
        let actual = try lockedPythonRequirements(metadata["package.metadata.requires-dist"] ?? "[]", extras: extras)
        return Set(expected.keys).union(actual.keys).sorted().flatMap { group -> [String] in
            let label = group.isEmpty ? "dependencies" : "optional-dependencies." + group
            guard let wanted = expected[group], let locked = actual[group] else {
                return [label + " is missing or extra"]
            }
            return differences(wanted, locked, label: label)
        }
    }
    private static func pythonRequirements(_ raw: String) throws -> [String: String] {
        var result: [String: String] = [:]
        for item in try tomlElements(raw) {
            let requirement = try tomlString(item)
            let matches = CheckSupport.captures(requirement, #"^([A-Za-z0-9][A-Za-z0-9._-]*)\s*(?:\[([^\[\]]+)\])?\s*((?:(?:==|!=|>=|<=|>|<|~=)[0-9][0-9.*]*\s*,?\s*)*)$"#)
            guard let match = matches.first else { throw RepairError.blocked("Python markers, direct sources or unsupported version specifiers need resolver review.") }
            let name = try pythonName(match[1])
            let extras = try Set(match[2].isEmpty ? [] : match[2].components(separatedBy: ",").map { try pythonName($0.trimmingCharacters(in: .whitespaces)) })
            guard result[name] == nil else { throw RepairError.blocked("Duplicate Python requirements need resolver review.") }
            result[name] = pythonDeclaration(specifier: match[3], extras: extras)
        }
        return result
    }
    private static func lockedPythonRequirements(_ raw: String, extras: Set<String>) throws -> [String: [String: String]] {
        var result: [String: [String: String]] = ["": [:]]
        for extra in extras { result[extra] = [:] }
        for record in try tomlElements(raw) {
            var fields: [String: String] = [:]
            for pair in try tomlElements(record, opening: "{", closing: "}") {
                guard let equals = pair.firstIndex(of: "=") else { throw RepairError.blocked("Unsupported uv inline dependency metadata.") }
                let key = String(pair[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard fields[key] == nil else { throw RepairError.blocked("Duplicate uv dependency metadata fields.") }
                fields[key] = String(pair[pair.index(after: equals)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard Set(fields.keys).isSubset(of: ["name", "specifier", "extras", "marker"]), let rawName = fields["name"] else {
                throw RepairError.blocked("Python lock metadata needs resolver review.")
            }
            let name = try pythonName(tomlString(rawName))
            let specifier = try fields["specifier"].map { try tomlString($0) } ?? ""
            let dependencyExtras = try pythonExtras(fields["extras"] ?? "[]")
            let groups: Set<String>
            if let marker = fields["marker"] {
                // uv may combine a requirement shared by several extras into an OR marker.
                let terms = try tomlString(marker).components(separatedBy: " or ")
                groups = try Set(terms.map { term in
                    let matches = CheckSupport.captures(term, #"^\s*extra\s*==\s*(?:'([^']+)'|"([^"]+)")\s*$"#)
                    guard let match = matches.first else { throw RepairError.blocked("Python environment markers need resolver review.") }
                    let group = try pythonName(match[1].isEmpty ? match[2] : match[1])
                    guard extras.contains(group) else { throw RepairError.blocked("Python lock metadata references an undeclared extra.") }
                    return group
                })
            } else { groups = [""] }
            for group in groups {
                guard result[group]?[name] == nil else { throw RepairError.blocked("Duplicate locked Python requirements.") }
                result[group, default: [:]][name] = pythonDeclaration(specifier: specifier, extras: dependencyExtras)
            }
        }
        return result
    }
    private static func pythonDeclaration(specifier: String, extras: Set<String>) -> String {
        normalizeSpecifier(specifier) + "|" + extras.sorted().joined(separator: ",")
    }
    private static func pythonName(_ raw: String) throws -> String {
        guard CheckSupport.matches(raw, #"^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?$"#) else {
            throw RepairError.blocked("Unsupported Python package or extra name.")
        }
        return normalizeName(raw)
    }
    private static func pythonExtras(_ raw: String) throws -> Set<String> {
        try Set(tomlElements(raw).map { try pythonName(tomlString($0)) })
    }
    private static func tomlString(_ raw: String) throws -> String {
        guard raw.count >= 2, let quote = raw.first, quote == "\"" || quote == "'", raw.last == quote else {
            throw RepairError.blocked("Expected a Python metadata string.")
        }
        let value = String(raw.dropFirst().dropLast())
        guard !value.contains(quote), !value.contains("\\"), !value.contains("\n") else {
            throw RepairError.blocked("Escaped or multiline Python metadata strings need manual review.")
        }
        return value
    }
    /// Split a restricted TOML array/table without splitting quoted commas or nested extras arrays.
    private static func tomlElements(_ raw: String, opening: Character = "[", closing: Character = "]") throws -> [String] {
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.first == opening, raw.last == closing else { throw RepairError.blocked("Unsupported Python metadata collection.") }
        var result: [String] = [], current = "", quote: Character?, stack: [Character] = []
        for c in raw.dropFirst().dropLast() {
            if let q = quote {
                guard c != "\\" else { throw RepairError.blocked("Escaped Python metadata needs manual review.") }
                current.append(c)
                if c == q { quote = nil }
                continue
            }
            if c == "\"" || c == "'" { quote = c }
            else if c == "[" { stack.append("]") }
            else if c == "{" { stack.append("}") }
            else if c == "]" || c == "}" {
                guard stack.popLast() == c else { throw RepairError.blocked("Unbalanced Python metadata collection.") }
            } else if c == ",", stack.isEmpty {
                let item = current.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !item.isEmpty else { throw RepairError.blocked("Empty Python metadata entry.") }
                result.append(item); current = ""; continue
            }
            current.append(c)
        }
        guard quote == nil, stack.isEmpty else { throw RepairError.blocked("Incomplete Python metadata collection.") }
        let last = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty { result.append(last) }
        return result
    }
    private static func normalizeName(_ name: String) -> String { name.lowercased().replacingOccurrences(of: #"[-_.]+"#, with: "-", options: .regularExpression) }
    private static func normalizeSpecifier(_ spec: String) -> String { spec.replacingOccurrences(of: " ", with: "").split(separator: ",").sorted().joined(separator: ",") }
}
