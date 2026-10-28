import Foundation

enum RepositoryRuntimeChecks {
    private struct Declaration {
        let path: String
        let value: String
        let range: VersionRange
        let ci: Bool
    }
    static func checks() -> [RepositoryCheck] {
        [CheckSupport.check("dependencies.runtime", "Runtime version mismatch", .setup, "gearshape.2", inspect: { context, _ in
            var findings: [RepositoryFinding] = []
            for manifest in try CheckSupport.applicableManifests(context, names: ["package.json", "pyproject.toml"]) {
                let node = manifest.hasSuffix("package.json"), language = node ? "Node" : "Python"
                let directory = (manifest as NSString).deletingLastPathComponent
                var declarations: [Declaration] = []
                func add(_ path: String, _ value: String?, ci: Bool = false) throws {
                    guard let value, !value.isEmpty else { return }
                    do { declarations.append(Declaration(path: path, value: value, range: try VersionRange.parse(value), ci: ci)) }
                    catch { throw InspectionError.blocked(path + ": " + error.localizedDescription) }
                }
                if node {
                    let json = try RepositoryLockfileChecks.json(context, manifest)
                    try add(manifest + " engines.node", runtimeValue(json, field: "engines"))
                    try add(manifest + " volta.node", runtimeValue(json, field: "volta"))
                } else {
                    let values = try context.toml(manifest, allSections: true).values
                    try add(manifest + " requires-python", InspectionConfig.scalar(values["project.requires-python"]))
                }
                let versionNames = node ? [".nvmrc", ".node-version"] : [".python-version"]
                for name in versionNames {
                    if let path = try nearest(name, directory: directory, context: context) {
                        try add(path, context.readText(path).trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
                if let path = try nearest(".tool-versions", directory: directory, context: context) {
                    for raw in try context.readText(path).components(separatedBy: .newlines) {
                        let fields = InspectionConfig.withoutComment(raw).split(whereSeparator: \.isWhitespace)
                        if fields.first == (node ? "nodejs" : "python") {
                            guard fields.count == 2 else { throw InspectionError.blocked("Multiple tool versions need manual review.") }
                            try add(path, String(fields[1]))
                        }
                    }
                }
                let docker = directory.isEmpty ? "Dockerfile" : directory + "/Dockerfile"
                if try context.exists(docker) {
                    for row in CheckSupport.captures(try context.readText(docker), #"(?im)^\s*FROM\s+(?:--platform=\S+\s+)?(node|python):([^\s@]+)"#) where row[1].lowercased() == (node ? "node" : "python") {
                        // Image variant suffixes (alpine, slim, bookworm) do not alter the runtime version.
                        try add(docker, String(row[2].split(separator: "-").first ?? ""))
                    }
                }
                if directory.isEmpty {
                    for (path, source) in try CheckSupport.workflows(context) {
                        _ = try context.workflowReferences(path)
                        for step in try context.workflowSteps(path, includeInputs: true,
                            inputKeys: ["node-version", "python-version", "node-version-file", "python-version-file"]) where
                            step.uses?.hasPrefix(node ? "actions/setup-node@" : "actions/setup-python@") == true &&
                            (step.workingDirectory == nil || step.workingDirectory == ".") {
                            let key = node ? "node-version" : "python-version"
                            if let file = step.inputs[key + "-file"] {
                                guard !file.contains("${{") else { throw InspectionError.blocked("Dynamic runtime version files need manual review.") }
                                let contents = try context.readText(file).trimmingCharacters(in: .whitespacesAndNewlines)
                                if (file as NSString).lastPathComponent == "package.json" {
                                    try add(path, (try RepositoryLockfileChecks.json(context, file)["engines"] as? [String: String])?["node"], ci: true)
                                } else if (file as NSString).lastPathComponent == "pyproject.toml" {
                                    let values = try InspectionConfig.toml(contents).values
                                    try add(path, InspectionConfig.scalar(values["project.requires-python"]), ci: true)
                                } else { try add(path, contents, ci: true) }
                            }
                            for value in try literalWorkflowRuntimes(step.inputs[key], source: source, job: step.job) {
                                try add(path + " " + key, value, ci: true)
                            }
                        }
                    }
                }
                var evidence: [String] = []
                let multipleCIVersions = Set(declarations.filter(\.ci).map(\.value)).count > 1
                for i in declarations.indices {
                    for j in declarations.indices where j > i && !(declarations[i].ci && declarations[j].ci) {
                        let a = declarations[i], b = declarations[j]
                        // A multi-version CI suite is judged against manifest support constraints,
                        // not the developer's single selected interpreter.
                        if multipleCIVersions, a.ci || b.ci {
                            let local = a.ci ? b : a
                            if local.path != manifest + " engines.node" && local.path != manifest + " requires-python" { continue }
                        }
                        if !a.range.overlaps(b.range) { evidence.append("\(a.path) and \(b.path) declare incompatible \(language) versions.") }
                    }
                }
                if !evidence.isEmpty {
                    findings.append(CheckSupport.finding(context, "dependencies.runtime", manifest, "Runtime version mismatch",
                        Array(Set(evidence)).sorted().joined(separator: "\n"), .setup, "gearshape.2"))
                }
            }
            return findings
        })]
    }
    /// Resolve a literal matrix axis in this job only. Includes, excludes,
    /// expressions and unsupported YAML stay unknown rather than guessed.
    private static func literalWorkflowRuntimes(_ value: String?, source: String, job: String) throws -> [String] {
        guard let value else { return [] }
        guard let match = CheckSupport.captures(value, #"^\$\{\{\s*matrix\.([A-Za-z_][A-Za-z0-9_-]*)\s*\}\}$"#).first else {
            return try literalWorkflowRuntime(value, source: source).map { [$0] } ?? []
        }
        let all = try WorkflowInspection.lines(source)
        guard let jobsIndex = all.firstIndex(where: { $0.indent == 0 && $0.field == "jobs" }) else { return [value] }
        let jobs = WorkflowInspection.block(all, jobsIndex)
        guard let jobIndent = jobs.first?.indent,
              jobs.filter({ $0.indent == jobIndent && $0.field == job }).count == 1,
              let index = jobs.firstIndex(where: { $0.indent == jobIndent && $0.field == job }) else { return [value] }
        let fields = WorkflowInspection.block(jobs, index)
        guard let indent = fields.first?.indent,
              let strategy = fields.firstIndex(where: { $0.indent == indent && $0.field == "strategy" }), fields[strategy].value.isEmpty else { return [value] }
        let settings = WorkflowInspection.block(fields, strategy)
        guard let matrix = settings.firstIndex(where: { $0.indent == indent + 2 && $0.field == "matrix" }), settings[matrix].value.isEmpty else { return [value] }
        let axes = WorkflowInspection.block(settings, matrix)
        let starts = axes.indices.filter { axes[$0].indent == indent + 4 }
        guard !starts.isEmpty, starts.count <= 16 else { return [value] }
        var values: [String: [String]] = [:]
        for start in starts {
            let field = axes[start]
            guard !["include", "exclude"].contains(field.field), values[field.field] == nil else { return [value] }
            let raw: String
            if field.value.isEmpty {
                let items = WorkflowInspection.block(axes, start)
                guard !items.isEmpty, items.allSatisfy({ $0.indent == indent + 6 && $0.text.hasPrefix("- ") }) else { return [value] }
                raw = "[" + items.map { String($0.text.dropFirst(2)) }.joined(separator: ",") + "]"
            } else { raw = field.value }
            let strings = CheckSupport.captures(raw, #"(["'])([^"'\\\r\n]+)\1"#)
            let residue = strings.reduce(raw) { $0.replacingOccurrences(of: $1[0], with: "") }
            let item = #"(?:"[^"\\\r\n]+"|'[^'\\\r\n]+')"#
            let array = #"^\[\s*"# + item + #"(?:\s*,\s*"# + item + #")*\s*,?\s*\]$"#
            // Quoted strings avoid YAML numeric coercion (3.10 becoming 3.1).
            guard CheckSupport.matches(raw, array), !strings.isEmpty, strings.count <= 32,
                  residue.allSatisfy({ "[], \t".contains($0) }), !strings.contains(where: { $0[2].contains("${{") }) else { return [value] }
            values[field.field] = strings.map { $0[2] }
        }
        return values[match[1]] ?? [value]
    }
    /// Resolve only an unambiguous literal workflow-level env value. Overrides,
    /// chained expressions and aliases remain outside static coverage.
    private static func literalWorkflowRuntime(_ value: String?, source: String) throws -> String? {
        guard let value, let match = CheckSupport.captures(value,
            #"^\$\{\{\s*env\.([A-Za-z_][A-Za-z0-9_]*)\s*\}\}$"#).first else { return value }
        let lines = try WorkflowInspection.lines(source), name = match[1]
        guard let env = lines.firstIndex(where: { $0.indent == 0 && $0.field == "env" }),
              lines[env].value.isEmpty,
              lines.filter({ $0.field == name }).count == 1,
              let field = WorkflowInspection.block(lines, env).first(where: { $0.indent == 2 && $0.field == name }),
              let literal = InspectionConfig.scalar(field.value), !literal.contains("${{") else { return value }
        return literal
    }
    private static func runtimeValue(_ json: [String: Any], field: String) throws -> String? {
        guard let raw = json[field] else { return nil }
        guard let values = raw as? [String: Any] else { throw InspectionError.blocked("Unsupported runtime declaration object.") }
        guard let node = values["node"] else { return nil }
        guard let value = node as? String else { throw InspectionError.blocked("Runtime version declarations must be strings.") }
        return value
    }
    private static func nearest(_ filename: String, directory: String, context: RepositoryInspectionContext) throws -> String? {
        var current = directory
        while true {
            let path = current.isEmpty ? filename : current + "/" + filename
            if try context.exists(path) { return path }
            if current.isEmpty { return nil }
            current = (current as NSString).deletingLastPathComponent
        }
    }
}

/// Numeric runtime selectors and intersections only. Aliases, OR, exclusions, prereleases and expressions stay unknown.
private struct VersionRange {
    var lower = 0
    var upper = Int.max
    func overlaps(_ other: Self) -> Bool { max(lower, other.lower) < min(upper, other.upper) }
    static func parse(_ source: String) throws -> Self {
        let cleaned = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"(>=|<=|==|~=|>|<|=|\^|~)?\s*v?([0-9]+)(?:\.([0-9]+|x|\*))?(?:\.([0-9]+|x|\*))?"#
        let captures = CheckSupport.captures(cleaned, pattern)
        var residue = cleaned, result = Self()
        guard !captures.isEmpty else { throw InspectionError.blocked("Unsupported runtime version selector.") }
        for match in captures {
            residue = residue.replacingOccurrences(of: match[0], with: "")
            guard let major = Int(match[2]), major < 1000 else { throw InspectionError.blocked("Unsupported runtime version.") }
            let minor = Int(match[3]), patch = Int(match[4])
            guard (minor ?? 0) < 1000, (patch ?? 0) < 1000 else { throw InspectionError.blocked("Unsupported runtime version.") }
            let value = major * 1_000_000 + (minor ?? 0) * 1000 + (patch ?? 0)
            let selectorUpper = minor == nil ? (major + 1) * 1_000_000 : patch == nil ? major * 1_000_000 + (minor! + 1) * 1000 : value + 1
            switch match[1] {
            case ">=": result.lower = max(result.lower, value)
            case ">": result.lower = max(result.lower, value + 1)
            case "<": result.upper = min(result.upper, value)
            case "<=": result.upper = min(result.upper, value + 1)
            case "^":
                result.lower = max(result.lower, value)
                result.upper = min(result.upper, major > 0 ? (major + 1) * 1_000_000 : (minor ?? 0) > 0 ? ((minor ?? 0) + 1) * 1000 : value + 1)
            case "~", "~=":
                result.lower = max(result.lower, value)
                let bound = match[1] == "~=" && patch == nil ? (major + 1) * 1_000_000 : minor == nil ? (major + 1) * 1_000_000 : major * 1_000_000 + (minor! + 1) * 1000
                result.upper = min(result.upper, bound)
            default: result.lower = max(result.lower, value); result.upper = min(result.upper, selectorUpper)
            }
        }
        guard residue.allSatisfy({ $0.isWhitespace || $0 == "," }), result.lower < result.upper else {
            throw InspectionError.blocked("Unsupported or empty runtime version range.")
        }
        return result
    }
}
