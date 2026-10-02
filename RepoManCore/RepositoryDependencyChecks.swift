import Foundation

enum RepositoryDependencyChecks {
    static func checks() -> [RepositoryCheck] {
        [
            CheckSupport.check("dependencies.manager", "Package-manager mismatch", .setup, "shippingbox", inspect: { context, _ in
                try managerFindings(context)
            }),
            CheckSupport.check("dependencies.safeguards", "Dependency safeguards missing", .setup, "checkmark.shield", inspect: { context, _ in
                try safeguardFindings(context)
            }),
            CheckSupport.check("dependencies.lockfile", "Missing or untracked lockfile", .setup, "lock.doc", inspect: { context, _ in
                try lockfileFindings(context)
            }),
            CheckSupport.check("dependencies.sources", "Dependency exceptions need review", .setup, "shippingbox", inspect: { context, _ in
                try sourceFindings(context)
            })
        ]
    }
    private static func json(_ context: RepositoryInspectionContext, _ path: String) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: Data(context.readText(path).utf8)) as? [String: Any] else {
            throw RepairError.blocked("Expected a JSON object in " + path)
        }
        return result
    }
    private static func beside(_ manifest: String, _ file: String) -> String {
        let directory = (manifest as NSString).deletingLastPathComponent
        return directory.isEmpty ? file : directory + "/" + file
    }
    private static func ancestors(_ manifest: String) -> [String] {
        var directory = (manifest as NSString).deletingLastPathComponent, result = [String]()
        while !directory.isEmpty { result.append(directory + "/"); directory = (directory as NSString).deletingLastPathComponent }
        return result + [""]
    }
    static func manager(_ context: RepositoryInspectionContext, _ path: String) throws -> String {
        let object = try json(context, path)
        if let declared = object["packageManager"] as? String {
            guard let name = declared.split(separator: "@").first, ["pnpm", "npm", "yarn", "bun"].contains(String(name)) else {
                throw RepairError.blocked("Unsupported package manager in " + path)
            }
            return String(name)
        }
        if path != "package.json", try context.exists("package.json") { return try manager(context, "package.json") }
        for (name, locks) in [("pnpm", ["pnpm-lock.yaml"]), ("yarn", ["yarn.lock"]), ("bun", ["bun.lock", "bun.lockb"]), ("npm", ["package-lock.json", "npm-shrinkwrap.json"])] {
            for prefix in ancestors(path) { for lock in locks where try context.exists(prefix + lock) { return name } }
        }
        return "npm"
    }
    static func lockNames(_ manager: String) -> [String] {
        switch manager {
        case "pnpm": return ["pnpm-lock.yaml"]
        case "yarn": return ["yarn.lock"]
        case "bun": return ["bun.lock", "bun.lockb"]
        default: return ["package-lock.json", "npm-shrinkwrap.json"]
        }
    }
    static func lockPrefixes(_ context: RepositoryInspectionContext, _ manifest: String) throws -> [String] {
        let prefixes = ancestors(manifest)
        var result = [prefixes[0]]
        for prefix in prefixes.dropFirst() {
            let directory = (manifest as NSString).deletingLastPathComponent
            let relative = String(directory.dropFirst(prefix.count))
            var patterns: [String] = []
            if manifest.hasSuffix("package.json") {
                if try context.exists(prefix + "pnpm-workspace.yaml") {
                    let config = try InspectionConfig.yaml(context.readText(prefix + "pnpm-workspace.yaml"))
                    patterns = workspacePatterns(config.values["packages"] ?? "")
                } else if try context.exists(prefix + "package.json") {
                    let workspace = (try json(context, prefix + "package.json"))["workspaces"]
                    patterns = workspace as? [String] ?? (workspace as? [String: Any])?["packages"] as? [String] ?? []
                }
            } else if try context.exists(prefix + "pyproject.toml") {
                let config = try InspectionConfig.toml(context.readText(prefix + "pyproject.toml"))
                patterns = workspacePatterns(config.values["tool.uv.workspace.members"] ?? "")
                let excludes = workspacePatterns(config.values["tool.uv.workspace.exclude"] ?? "")
                if excludes.contains(where: { glob($0, matches: relative) }) { continue }
            }
            let include = patterns.filter { !$0.hasPrefix("!") }.contains { glob($0, matches: relative) }
            let exclude = patterns.filter { $0.hasPrefix("!") }.contains { glob(String($0.dropFirst()), matches: relative) }
            if include && !exclude { result.append(prefix) }
        }
        return result
    }
    private static func workspacePatterns(_ raw: String) -> [String] {
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") {
            return CheckSupport.captures(raw, #"["']([^"']+)["']"#).map { $0[1] }
        }
        return raw.split(separator: "\n").compactMap { InspectionConfig.scalar(String($0)) }.filter { !$0.isEmpty }
    }
    private static func glob(_ pattern: String, matches path: String) -> Bool {
        let normalized = pattern.hasPrefix("./") ? String(pattern.dropFirst(2)) : pattern
        var regex = "", index = normalized.startIndex
        while index < normalized.endIndex {
            let char = normalized[index], next = normalized.index(after: index)
            if char == "*", next < normalized.endIndex, normalized[next] == "*" {
                regex += ".*"; index = normalized.index(after: next); continue
            }
            regex += char == "*" ? "[^/]*" : char == "?" ? "[^/]" : NSRegularExpression.escapedPattern(for: String(char))
            index = next
        }
        return CheckSupport.matches(path, "^" + regex + "$" )
    }
    private static func managerFindings(_ context: RepositoryInspectionContext) throws -> [RepositoryFinding] {
        var findings: [RepositoryFinding] = []
        for path in try CheckSupport.manifests(context) where path.hasSuffix("package.json") {
            let object = try json(context, path), name = try manager(context, path)
            var reasons: [String] = []
            if let declared = object["packageManager"] as? String {
                if !CheckSupport.matches(declared, #"^(?:pnpm|npm|yarn|bun)@\d+\.\d+\.\d+(?:[-+].*)?$"#) {
                    reasons.append("packageManager does not pin an exact tool version.")
                }
                let other = ["pnpm-lock.yaml", "package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "bun.lock", "bun.lockb"].filter { !lockNames(name).contains($0) }
                for file in other where try context.exists(beside(path, file)) { reasons.append("\(declared) is declared, but \(file) is present.") }
            } else if path == "package.json" { reasons.append("No packageManager version is declared; \(name) was inferred from local files.") }
            if path == "package.json" {
                for (workflow, source) in try CheckSupport.workflows(context) {
                    for step in try WorkflowInspection.steps(source) where step.workingDirectory == nil || step.workingDirectory == "." {
                        for command in step.commands {
                            for installed in ["npm", "pnpm", "yarn", "bun"] where installed != name {
                                if CheckSupport.matches(command, "^" + installed + #"\s+(?:ci|install)(?:\s|$)"#),
                                   !CheckSupport.matches(command, #"(?:--global|\s-g\b)"#) {
                                    reasons.append("\(workflow) installs with \(installed), while the project uses \(name).")
                                }
                            }
                        }
                    }
                }
            }
            if !reasons.isEmpty { findings.append(CheckSupport.finding(context, "dependencies.manager", path, "Package-manager mismatch", Array(Set(reasons)).sorted().joined(separator: "\n"), .setup, "shippingbox")) }
        }
        return findings
    }
    private static func lockfileFindings(_ context: RepositoryInspectionContext) throws -> [RepositoryFinding] {
        var findings: [RepositoryFinding] = []
        for path in try CheckSupport.manifests(context) where !path.hasSuffix("requirements.txt") {
            let locks = path.hasSuffix("package.json") ? lockNames(try manager(context, path)) : ["uv.lock"]
            var candidates: [String] = []
            for prefix in try lockPrefixes(context, path) { for name in locks where try context.exists(prefix + name) { candidates.append(prefix + name) } }
            var tracked = false
            for candidate in candidates where try context.isTracked(candidate) { tracked = true }
            guard !tracked else { continue }
            findings.append(CheckSupport.finding(context, "dependencies.lockfile", path, "Missing or untracked lockfile",
                candidates.isEmpty ? "\(path) has no matching \(locks.joined(separator: " or ")) in its directory or workspace ancestors. Review intentional library or experiment exceptions." :
                    "Matching lockfile \(candidates.joined(separator: ", ")) exists but is not tracked by Git.", .setup, "lock.doc"))
        }
        return findings
    }
    private static func uvConfig(_ context: RepositoryInspectionContext, _ path: String) throws -> InspectionConfig {
        // uv.toml supersedes [tool.uv] at the same level; nested projects inherit workspace policy.
        for prefix in ancestors(path) {
            if try context.exists(prefix + "uv.toml") {
                let config = try InspectionConfig.toml(context.readText(prefix + "uv.toml"), standaloneUV: true)
                return InspectionConfig(values: Dictionary(uniqueKeysWithValues: config.values.map { ("tool.uv." + $0.key, $0.value) }))
            }
            if try context.exists(prefix + "pyproject.toml") {
                let config = try InspectionConfig.toml(context.readText(prefix + "pyproject.toml"))
                if prefix == "" || config.values.keys.contains(where: { $0.hasPrefix("tool.uv.") }) { return config }
            }
        }
        return InspectionConfig(values: [:])
    }
    private static func safeCutoff(_ value: String?, now: Date) -> Bool {
        guard let value = InspectionConfig.scalar(value) else { return false }
        if let duration = CheckSupport.captures(value, #"^(\d+)\s+(hours?|days?|weeks?)$"#).first, let count = Double(duration[1]), count.isFinite {
            let hours = count * (duration[2].hasPrefix("week") ? 168 : duration[2].hasPrefix("day") ? 24 : 1)
            return hours >= 168
        }
        if value == "P7D" { return true }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return now.timeIntervalSince(date) >= 7 * 86_400 }
        let dateOnly = DateFormatter(); dateOnly.dateFormat = "yyyy-MM-dd"; dateOnly.locale = Locale(identifier: "en_US_POSIX"); dateOnly.timeZone = TimeZone(secondsFromGMT: 0)
        return dateOnly.date(from: value).map { now.timeIntervalSince($0) >= 7 * 86_400 } ?? false
    }
    private static func safeguardFindings(_ context: RepositoryInspectionContext) throws -> [RepositoryFinding] {
        var findings: [RepositoryFinding] = []
        for path in try CheckSupport.manifests(context) {
            var reasons: [String] = []
            if path.hasSuffix("package.json") {
                let name = try manager(context, path)
                guard ["npm", "pnpm", "bun"].contains(name) else { throw RepairError.blocked("Supply-chain policy for \(name) needs manual review.") }
                if name == "bun" {
                    reasons += try bunSafeguards(context, manifest: path)
                } else {
                    var rc: [String: String] = [:], workspace: [String: String] = [:]
                    // Ancestor settings are overridden by nearer project settings.
                    for prefix in ancestors(path).reversed() {
                        if try context.exists(prefix + ".npmrc") { rc.merge(try InspectionConfig.ini(context.readText(prefix + ".npmrc")).values) { _, new in new } }
                        if try context.exists(prefix + "pnpm-workspace.yaml") { workspace.merge(try InspectionConfig.yaml(context.readText(prefix + "pnpm-workspace.yaml")).values) { _, new in new } }
                    }
                    if name == "pnpm" {
                        if (Int(InspectionConfig.scalar(workspace["minimumReleaseAge"]) ?? "") ?? 0) < 10080 { reasons.append("pnpm-workspace.yaml lacks minimumReleaseAge >= 10080.") }
                        if InspectionConfig.scalar(workspace["blockExoticSubdeps"]) != "true" { reasons.append("pnpm-workspace.yaml lacks blockExoticSubdeps: true.") }
                        var declared = (try json(context, path))["packageManager"] as? String
                        if declared == nil, try context.exists("package.json") { declared = (try json(context, "package.json"))["packageManager"] as? String }
                        if declared?.hasPrefix("pnpm@10.") == true {
                            if (Int(InspectionConfig.scalar(rc["minimum-release-age"]) ?? "") ?? 0) < 10080 { reasons.append("pnpm 10 .npmrc lacks minimum-release-age >= 10080.") }
                            if InspectionConfig.scalar(rc["block-exotic-subdeps"]) != "true" { reasons.append("pnpm 10 .npmrc lacks block-exotic-subdeps=true.") }
                        }
                    } else {
                        if (Int(InspectionConfig.scalar(rc["min-release-age"]) ?? "") ?? 0) < 10080 { reasons.append("npm .npmrc lacks min-release-age >= 10080.") }
                        if InspectionConfig.scalar(rc["ignore-scripts"]) != "true" { reasons.append("npm lifecycle scripts are enabled; document an exception if they are required.") }
                    }
                }
            } else if path.hasSuffix("pyproject.toml") {
                let config = try uvConfig(context, path)
                if !safeCutoff(config.values["tool.uv.exclude-newer"], now: context.snapshot.checkedAt) { reasons.append("Effective uv configuration lacks a dependency cutoff of at least seven days.") }
                if let pipCutoff = config.values["tool.uv.pip.exclude-newer"], !safeCutoff(pipCutoff, now: context.snapshot.checkedAt) {
                    reasons.append("The uv pip cutoff overrides the seven-day dependency policy.")
                }
                let constraints = config.values["tool.uv.constraint-dependencies"] ?? ""
                let exclusions = Set(CheckSupport.captures(constraints, #"(["'])(.*?)\1"#).map { $0[2].replacingOccurrences(of: " ", with: "") })
                for item in ["mistralai!=2.4.6", "guardrails-ai!=0.10.1"] where !exclusions.contains(item) {
                    reasons.append("Effective uv constraints do not exclude \(item). Review applicability or document an exception.")
                }
            } else {
                let source = try context.readText(path)
                let directory = (path as NSString).deletingLastPathComponent
                let references = CheckSupport.captures(source, #"(?m)^\s*(?:-c\s*|--constraint(?:=|\s+))([^\s#]+)"#).map { $0[1] }
                if references.isEmpty { reasons.append("Pip requirements do not reference checked-in constraints with -c.") }
                for reference in references {
                    let target = directory.isEmpty ? reference : directory + "/" + reference
                    let exists = try context.exists(target), tracked = try context.isTracked(target)
                    if !exists || !tracked { reasons.append("Constraint file \(target) is missing or untracked.") }
                }
            }
            if (path as NSString).deletingLastPathComponent.isEmpty {
                for (workflow, source) in try CheckSupport.workflows(context) {
                    for step in try WorkflowInspection.steps(source) {
                        for command in step.commands {
                            if CheckSupport.matches(command, #"\b(?:npm|pnpm)\s+(?:ci|install)\b"#) {
                                for age in CheckSupport.captures(command, #"--min(?:imum)?-release-age(?:=|\s+)(\d+)"#) where (Int(age[1]) ?? 0) < 10080 {
                                    reasons.append("\(workflow) overrides the dependency age below seven days.")
                                }
                                if CheckSupport.matches(command, #"--(?:block-exotic-subdeps|ignore-scripts)=false\b"#) {
                                    reasons.append("\(workflow) explicitly disables dependency installation safeguards.")
                                }
                            }
                            if CheckSupport.matches(command, #"\buv\s+(?:sync|lock|add|pip\s+install)\b"#) {
                                for age in CheckSupport.captures(command, #"--exclude-newer(?:=|\s+)("[^"]+"|'[^']+'|\S+)"#) where !safeCutoff(age[1], now: context.snapshot.checkedAt) {
                                    reasons.append("\(workflow) overrides the uv dependency age below seven days.")
                                }
                                if CheckSupport.matches(command, #"--no-config\b"#) { reasons.append("\(workflow) disables repository-owned uv configuration.") }
                            }
                            if CheckSupport.matches(command, #"\bbun\s+(?:ci|install|add|update)\b"#) {
                                for age in CheckSupport.captures(command, #"--minimum-release-age(?:=|\s+)(\d+)"#) where (Int(age[1]) ?? 0) < 604800 {
                                    reasons.append("\(workflow) overrides the Bun dependency age below seven days.")
                                }
                                if CheckSupport.matches(command, #"--ignore-scripts=false\b"#) {
                                    reasons.append("\(workflow) explicitly enables Bun lifecycle scripts.")
                                }
                                if CheckSupport.matches(command, #"--config(?:=|\s)"#) {
                                    reasons.append("\(workflow) overrides repository-owned Bun configuration; review its safeguards.")
                                }
                            }
                        }
                    }
                }
            }
            if !reasons.isEmpty { findings.append(CheckSupport.finding(context, "dependencies.safeguards", path, "Dependency safeguards missing", Array(Set(reasons)).sorted().joined(separator: "\n"))) }
        }
        return findings
    }
    private static func bunSafeguards(_ context: RepositoryInspectionContext, manifest: String) throws -> [String] {
        let prefixes = try lockPrefixes(context, manifest)
        var installPrefix = prefixes.last ?? ""
        // Workspace installs use the configuration beside their lockfile. An independent
        // nested project must not borrow an unrelated ancestor's Bun configuration.
        for prefix in prefixes {
            if try context.exists(prefix + "bun.lock") || context.exists(prefix + "bun.lockb") {
                installPrefix = prefix; break
            }
        }
        let configPath = installPrefix + "bunfig.toml"
        let config = try context.exists(configPath) ? InspectionConfig.toml(context.readText(configPath), allSections: true).values : [:]
        let rcPath = installPrefix + ".npmrc"
        let rc = try context.exists(rcPath) ? InspectionConfig.ini(context.readText(rcPath)).values : [:]
        var reasons: [String] = []
        // Bun uses seconds, whereas npm and pnpm use minutes. TOML permits digit separators.
        let rawAge = config["install.minimumReleaseAge"] ?? "0"
        guard CheckSupport.matches(rawAge, #"^\d(?:_?\d)*$"#) else { throw RepairError.blocked("Unsupported Bun minimumReleaseAge value.") }
        let age = rawAge.replacingOccurrences(of: "_", with: "")
        if (Int(age) ?? 0) < 604800 { reasons.append("bunfig.toml lacks install.minimumReleaseAge >= 604800 seconds (seven days).") }
        let ignoreScripts = config["install.ignoreScripts"] ?? rc["ignore-scripts"]
        if ignoreScripts != "true" {
            reasons.append("Bun lifecycle scripts are not disabled with install.ignoreScripts = true or .npmrc ignore-scripts=true; document an exception if they are required.")
        }
        if let excludes = config["install.minimumReleaseAgeExcludes"],
           !CheckSupport.matches(excludes, #"^\[\s*\]$"#) {
            reasons.append("Bun minimumReleaseAgeExcludes bypasses the seven-day dependency policy; review and document exceptions.")
        }
        return reasons
    }
    private static func sourceFindings(_ context: RepositoryInspectionContext) throws -> [RepositoryFinding] {
        var findings: [RepositoryFinding] = []
        for path in try CheckSupport.manifests(context) {
            var reasons: [String] = []
            if path.hasSuffix("package.json") {
                let object = try json(context, path)
                for field in ["dependencies", "devDependencies", "optionalDependencies", "overrides", "resolutions"] {
                    if let dependencies = object[field] as? [String: Any] {
                        for (name, value) in dependencies.sorted(by: { $0.key < $1.key }) {
                            // Workspace references stay local; every other non-registry source needs an exception.
                            let text = String(describing: value)
                            if CheckSupport.matches(text, #"(?:https?://|git(?:\+|://|@)|github:|gitlab:|bitbucket:|file:|link:|\.\./|^\./|^[\w.-]+/[\w.-]+(?:#|$))"#) {
                                reasons.append("\(field).\(name) uses a non-registry source. Review it and record an approved exception if intentional.")
                            }
                        }
                    }
                }
            } else if path.hasSuffix("pyproject.toml") {
                let manifest = try InspectionConfig.toml(context.readText(path))
                let config = try uvConfig(context, path)
                for (key, value) in manifest.values.sorted(by: { $0.key < $1.key }) where key.hasPrefix("project.") && key.contains("dependencies") {
                    if CheckSupport.matches(value, #"(?:\s@\s*(?:https?://|git\+|file:)|git\+|https?://)"#) { reasons.append("\(key) contains direct URL or Git dependencies.") }
                }
                for (key, value) in config.values.sorted(by: { $0.key < $1.key }) {
                    if key.hasPrefix("tool.uv.sources."), !CheckSupport.matches(value, #"^\{\s*workspace\s*=\s*true\s*,?\s*\}$"#) {
                        reasons.append("\(key) overrides the package source; review path, Git, URL, or index access.")
                    } else if key.hasPrefix("tool.uv.index."), key.hasSuffix(".url"), InspectionConfig.scalar(value) != "https://pypi.org/simple" {
                        reasons.append("\(key) configures an alternate package index.")
                    } else if key.contains("exclude-newer-package"), value != "{}" { reasons.append("\(key) changes the global dependency age policy.") }
                    else if ["tool.uv.index-url", "tool.uv.extra-index-url", "tool.uv.find-links"].contains(key) { reasons.append("\(key) configures a custom dependency source.") }
                }
            } else {
                for line in try context.readText(path).components(separatedBy: .newlines) {
                    let value = InspectionConfig.withoutComment(line)
                    if CheckSupport.matches(value, #"(?:https?://|git\+|file:|^-e\s|^--(?:extra-index-url|index-url|find-links)|^\.{1,2}/)"#) {
                        reasons.append("Requirements include a direct source, editable install, or custom index.")
                    }
                }
            }
            for prefix in ancestors(path) {
                for file in [".npmrc", "pnpm-workspace.yaml"] {
                    guard path.hasSuffix("package.json"), try context.exists(prefix + file) else { continue }
                    let source = try context.readText(prefix + file)
                    let config = try (file == ".npmrc" ? InspectionConfig.ini(source) : InspectionConfig.yaml(source))
                    for (key, raw) in config.values {
                        let value = InspectionConfig.scalar(raw) ?? ""
                        if ["minimumReleaseAgeExclude", "minimum-release-age-exclude", "min-release-age-exclude", "trustPolicyExclude"].contains(key),
                           !["", "[]", "{}", "null"].contains(value) { reasons.append("\(prefix + file) contains dependency-policy exclusions.") }
                        if key == "registry" || key.hasSuffix(":registry"), value.trimmingCharacters(in: CharacterSet(charactersIn: "/")) != "https://registry.npmjs.org" {
                            reasons.append("\(prefix + file) configures an alternate npm registry.")
                        }
                        if key.hasPrefix("overrides."), CheckSupport.matches(raw, #"(?:https?://|git\+|github:|file:|link:)"#) {
                            reasons.append("\(prefix + file) contains a non-registry dependency override.")
                        }
                    }
                }
            }
            if !reasons.isEmpty { findings.append(CheckSupport.finding(context, "dependencies.sources", path, "Dependency exceptions need review", Array(Set(reasons)).sorted().joined(separator: "\n"))) }
        }
        return findings
    }
}
