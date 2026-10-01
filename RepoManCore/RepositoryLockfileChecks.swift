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
                    default: throw RepairError.blocked("Static lockfile drift inspection supports npm v2/v3, pnpm v9 and simple uv v1 projects; this manager needs manual review.")
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
              !projectValues.keys.contains(where: { $0.hasPrefix("project.optional-dependencies.") || $0.hasPrefix("dependency-groups.") || $0.hasPrefix("tool.uv.sources.") || $0 == "tool.uv.dev-dependencies" }) else {
            throw RepairError.blocked("Dynamic Python metadata, extras, groups and custom sources need resolver review.")
        }
        let expected = try pythonRequirements(projectValues["project.dependencies"] ?? "[]")
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
        let actual = try lockedPythonRequirements(metadata["package.metadata.requires-dist"] ?? "[]")
        return differences(expected, actual, label: "dependencies")
    }
    private static func pythonRequirements(_ raw: String) throws -> [String: String] {
        let captures = CheckSupport.captures(raw, #"["']([^"'\\]*)["']"#)
        var leftover = raw
        for capture in captures { leftover = leftover.replacingOccurrences(of: capture[0], with: "") }
        guard leftover.allSatisfy({ "[], \n\r\t".contains($0) }) else { throw RepairError.blocked("Unsupported Python dependency array.") }
        var result: [String: String] = [:]
        for capture in captures {
            let matches = CheckSupport.captures(capture[1], #"^([A-Za-z0-9][A-Za-z0-9._-]*)\s*((?:(?:==|!=|>=|<=|>|<|~=)[0-9][0-9.*]*\s*,?\s*)*)$"#)
            guard let match = matches.first else { throw RepairError.blocked("Python extras, markers or direct sources need resolver review.") }
            let name = normalizeName(match[1])
            guard result[name] == nil else { throw RepairError.blocked("Duplicate Python requirements need resolver review.") }
            result[name] = normalizeSpecifier(match[2])
        }
        return result
    }
    private static func lockedPythonRequirements(_ raw: String) throws -> [String: String] {
        let records = CheckSupport.captures(raw, #"\{([^{}]*)\}"#)
        var leftover = raw, result: [String: String] = [:]
        for record in records {
            leftover = leftover.replacingOccurrences(of: record[0], with: "")
            let pairs = CheckSupport.captures(record[1], #"([a-z-]+)\s*=\s*["']([^"'\\]*)["']"#)
            let remaining = pairs.reduce(record[1]) { $0.replacingOccurrences(of: $1[0], with: "") }
            guard remaining.allSatisfy({ $0.isWhitespace || $0 == "," }), Set(pairs.map { $0[1] }).count == pairs.count else {
                throw RepairError.blocked("Unsupported uv inline dependency metadata.")
            }
            let fields = Dictionary(uniqueKeysWithValues: pairs.map { ($0[1], $0[2]) })
            guard Set(fields.keys).isSubset(of: ["name", "specifier"]), let name = InspectionConfig.scalar(fields["name"]) else {
                throw RepairError.blocked("Python lock metadata needs resolver review.")
            }
            let normalized = normalizeName(name)
            guard result[normalized] == nil else { throw RepairError.blocked("Duplicate locked Python requirements.") }
            result[normalized] = normalizeSpecifier(InspectionConfig.scalar(fields["specifier"]) ?? "")
        }
        guard leftover.allSatisfy({ "[], \n\r\t".contains($0) }) else { throw RepairError.blocked("Unsupported uv dependency metadata.") }
        return result
    }
    private static func normalizeName(_ name: String) -> String { name.lowercased().replacingOccurrences(of: #"[-_.]+"#, with: "-", options: .regularExpression) }
    private static func normalizeSpecifier(_ spec: String) -> String { spec.replacingOccurrences(of: " ", with: "").split(separator: ",").sorted().joined(separator: ",") }
}
