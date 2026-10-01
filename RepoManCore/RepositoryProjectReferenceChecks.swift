import Foundation

enum RepositoryProjectReferenceChecks {
    static func checks() -> [RepositoryCheck] {
        [CheckSupport.check("files.projectReferences", "Broken project references", .setup, "link.badge.plus", inspect: { context, _ in
            var evidence: [String: Set<String>] = [:]
            func missing(_ subject: String, _ path: String, generated: Bool = false) throws {
                guard !path.contains("$") && !path.contains("~") else { throw RepairError.blocked("Dynamic project paths need manual review.") }
                if generated {
                    let components = path.split(separator: "/")
                    if components.contains(where: { ["dist", "build", "out", ".next", "target"].contains(String($0)) }) { return }
                    // Ignore rules distinguish build entry points from missing tracked source.
                    if !(try context.gitRead(["check-ignore", "--no-index", "--", path], successfulExitCodes: [0, 1])).isEmpty { return }
                }
                if path.contains("*") {
                    let matches = try expand(path, context: context)
                    if matches.isEmpty { evidence[subject, default: []].insert("No local target matches \(path).") }
                } else if !(try context.localTargetExists(path)) {
                    evidence[subject, default: []].insert("Local target \(path) is missing.")
                }
            }
            for manifest in try CheckSupport.manifests(context) where !manifest.hasSuffix("requirements.txt") {
                let directory = (manifest as NSString).deletingLastPathComponent
                func beside(_ path: String) -> String { directory.isEmpty ? path : directory + "/" + path }
                if manifest.hasSuffix("package.json") {
                    let json = try RepositoryLockfileChecks.json(context, manifest)
                    var patterns: [String] = []
                    if let workspace = json["workspaces"] {
                        guard let list = workspace as? [String] ?? (workspace as? [String: Any])?["packages"] as? [String] else {
                            throw RepairError.blocked("Unsupported workspace member syntax.")
                        }
                        patterns = list
                    }
                    let pnpm = beside("pnpm-workspace.yaml")
                    if try context.exists(pnpm) {
                        let raw = try InspectionConfig.yaml(context.readText(pnpm)).values["packages"]
                        if let raw { patterns += try stringArray(raw, yaml: true) }
                    }
                    try workspace(patterns, excludes: [], manifest: manifest, directory: directory, filename: "package.json", context: context, evidence: &evidence)
                    for field in ["main", "module", "types", "typings", "bin", "exports"] {
                        for target in try targets(json[field]) {
                            if field == "exports" && !target.hasPrefix("./") { continue }
                            try missing(manifest, beside(target), generated: true)
                        }
                    }
                    if let scripts = json["scripts"] as? [String: String] {
                        for command in scripts.values { for path in try scriptPaths(command) { try missing(manifest, beside(path)) } }
                    }
                } else {
                    let values = try InspectionConfig.toml(context.readText(manifest), allSections: true).values
                    let members = try stringArray(values["tool.uv.workspace.members"] ?? "[]")
                    let excluded = try stringArray(values["tool.uv.workspace.exclude"] ?? "[]")
                    try workspace(members, excludes: excluded, manifest: manifest, directory: directory, filename: "pyproject.toml", context: context, evidence: &evidence)
                }
            }
            for (path, source) in try CheckSupport.workflows(context) {
                for reference in try WorkflowInspection.references(source) where reference.hasPrefix("./") {
                    if reference.hasSuffix(".yml") || reference.hasSuffix(".yaml") { try missing(path, reference) }
                    else if try !context.exists(reference + "/action.yml") && !context.exists(reference + "/action.yaml") {
                        evidence[path, default: []].insert("Local action \(reference) has no action.yml or action.yaml.")
                    }
                }
                for step in try WorkflowInspection.steps(source, includeInputs: true, inputKeys: ["node-version-file", "python-version-file"]) {
                    let directory = step.workingDirectory ?? "."
                    if directory != "." { try missing(path, directory) }
                    for command in step.commands { for target in try scriptPaths(command) {
                        guard !CheckSupport.matches(step.commands.joined(separator: "\n"), #"(?:^|[;&\n])\s*cd\s"#) else {
                            throw RepairError.blocked("Shell directory changes need manual reference review.")
                        }
                        try missing(path, directory == "." ? target : directory + "/" + target)
                    } }
                    for key in ["node-version-file", "python-version-file"] { if let file = step.inputs[key] { try missing(path, file) } }
                }
            }
            return evidence.keys.sorted().map { subject in
                CheckSupport.finding(context, "files.projectReferences", subject, "Broken project references",
                    evidence[subject]!.sorted().joined(separator: "\n"), .setup, "link.badge.plus")
            }
        })]
    }
    private static func targets(_ value: Any?) throws -> [String] {
        guard let value else { return [] }
        if let target = value as? String { return [target] }
        if value is NSNull { return [] }
        if let object = value as? [String: Any] { return try object.values.flatMap { try targets($0) } }
        if let array = value as? [Any] { return try array.flatMap { try targets($0) } }
        throw RepairError.blocked("Unsupported package entry point syntax.")
    }
    private static func stringArray(_ raw: String, yaml: Bool = false) throws -> [String] {
        if yaml, !raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") {
            return raw.split(separator: "\n").compactMap { InspectionConfig.scalar(String($0)) }
        }
        let matches = CheckSupport.captures(raw, #"["']([^"'\\]*)["']"#)
        let residue = matches.reduce(raw) { $0.replacingOccurrences(of: $1[0], with: "") }
        guard residue.allSatisfy({ "[], \n\r\t".contains($0) }) else { throw RepairError.blocked("Unsupported workspace member syntax.") }
        return matches.map { $0[1] }
    }
    private static func workspace(_ patterns: [String], excludes: [String], manifest: String, directory: String, filename: String,
                                  context: RepositoryInspectionContext, evidence: inout [String: Set<String>]) throws {
        let exclusions = excludes + patterns.filter { $0.hasPrefix("!") }.map { String($0.dropFirst()) }
        for pattern in patterns where !pattern.hasPrefix("!") {
            let prefixed = directory.isEmpty ? pattern : directory + "/" + pattern
            let paths = try expand(prefixed, context: context)
            if paths.isEmpty, !exclusions.contains(pattern) { evidence[manifest, default: []].insert("Workspace member \(prefixed) matches no local directory.") }
            for path in paths {
                let relative = directory.isEmpty ? path : String(path.dropFirst(directory.count + 1))
                if exclusions.contains(where: { glob($0, relative) }) { continue }
                if try !context.isDirectory(path) || !context.exists(path + "/" + filename) {
                    evidence[manifest, default: []].insert("Workspace member \(path) has no \(filename).")
                }
            }
        }
    }
    private static func scriptPaths(_ source: String) throws -> [String] {
        // Recognize explicit script invocations; never infer arbitrary shell arguments as paths.
        let direct = #"(?:^|[;&|\n])\s*(\./[^\s;|&<>"']+)(?:\s|$|[;&|])"#
        let interpreted = #"(?:^|[;&|\n])\s*(?:python[0-9.]*|node|bash|sh|zsh|ruby)\s+(?:--?[A-Za-z-]+\s+)*["']?([^\s;|&<>"']+\.(?:py|js|mjs|cjs|sh|rb))["']?(?:\s|$|[;&|])"#
        let paths = (CheckSupport.captures(source, direct) + CheckSupport.captures(source, interpreted)).map { $0[1] }.filter { !$0.hasPrefix("http") }
        if !paths.isEmpty, CheckSupport.matches(source, #"(?:^|[;&|\n])\s*cd\s"#) {
            throw RepairError.blocked("Shell directory changes need manual reference review.")
        }
        if CheckSupport.matches(source, #"(?:^|[;&|\n])\s*(?:python[0-9.]*|node|bash|sh|zsh|ruby)\s+["']?[^\s"']*[$~]"#) {
            throw RepairError.blocked("Dynamic script paths need manual reference review.")
        }
        return paths
    }
    private static func glob(_ pattern: String, _ path: String) -> Bool {
        var regex = NSRegularExpression.escapedPattern(for: pattern)
        regex = regex.replacingOccurrences(of: #"\*\*"#, with: ".*").replacingOccurrences(of: #"\*"#, with: "[^/]*")
        return CheckSupport.matches(path, "^" + regex + "$")
    }
    /// Expand bounded local patterns without following directories outside the repository.
    private static func expand(_ pattern: String, context: RepositoryInspectionContext) throws -> [String] {
        guard !pattern.hasPrefix("/"), !pattern.contains("$"), !pattern.contains("?"), !pattern.contains("{"), !pattern.contains("["),
              !pattern.split(separator: "/").contains("..") else { throw RepairError.blocked("Unsupported or escaping workspace pattern.") }
        let parts = pattern.split(separator: "/").map(String.init).filter { $0 != "." }
        var visited = 0
        func walk(_ directory: String, _ index: Int, _ depth: Int) throws -> [String] {
            visited += 1
            guard visited <= 256, depth <= 8 else { throw RepairError.blocked("Project reference expansion exceeds inspection limits.") }
            if index == parts.count { return try context.localTargetExists(directory) ? [directory] : [] }
            let part = parts[index]
            if !part.contains("*") {
                let path = directory == "." ? part : directory + "/" + part
                guard try context.localTargetExists(path) else { return [] }
                if index + 1 < parts.count, !(try context.isDirectory(path)) { return [] }
                return try walk(path, index + 1, depth + 1)
            }
            guard try context.isDirectory(directory) else { return [] }
            var matches = part == "**" ? try walk(directory, index + 1, depth + 1) : []
            for name in try context.filenames(in: directory) where ![".git", "node_modules", ".venv", "DerivedData"].contains(name) {
                let path = directory == "." ? name : directory + "/" + name
                if part == "**" {
                    if try context.isDirectory(path) { matches += try walk(path, index, depth + 1) }
                } else if glob(part, name) { matches += try walk(path, index + 1, depth + 1) }
            }
            return Array(Set(matches)).sorted()
        }
        return try walk(".", 0, 0)
    }
}
