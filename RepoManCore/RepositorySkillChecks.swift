import Foundation

/// Local custom skill identities only; never executes a skill or opens external skill contents.
enum RepositorySkillChecks {
    static let id = "skills.naming"

    static func checks() -> [RepositoryCheck] {
        [RepositoryCheck(id: id, title: "Skill naming rules", category: .setup, symbol: "tag", evaluate: { context in
            let policy = try RepositoryCheckPolicy.load(context)
            let paths = try inventory(context)
            guard !paths.isEmpty else { return .notApplicable("No local custom skill entrypoints or discovery links were found.") }
            var findings: [RepositoryFinding] = [], reasons: [String] = [], inspected = Set<String>()
            let prefix: String?
            do { prefix = try expectedPrefix(context) }
            catch {
                prefix = nil
                reasons.append(".repo-metadata.toml: Repository label could not be inspected.")
            }
            for path in paths {
                do {
                    let source: String
                    if path.hasSuffix("/SKILL.md") { source = path }
                    else {
                        let link = context.snapshot.url.appendingPathComponent(path)
                        let attributes = try FileManager.default.attributesOfItem(atPath: link.path)
                        guard attributes[.type] as? FileAttributeType == .typeSymbolicLink else { continue }
                        let target = link.resolvingSymlinksInPath()
                        if link.lastPathComponent != target.lastPathComponent {
                            findings.append(finding(context, path, "Discovery-link basename must match its target skill directory."))
                        }
                        do {
                            let entrypoint = try target.appendingPathComponent("SKILL.md").resourceValues(forKeys: [.isRegularFileKey])
                            guard entrypoint.isRegularFile == true else {
                                throw InspectionError.blocked("Discovery target has no regular SKILL.md entrypoint.")
                            }
                        } catch {
                            throw InspectionError.blocked("Discovery target entrypoint could not be verified.")
                        }
                        let root = context.snapshot.url.standardizedFileURL.resolvingSymlinksInPath()
                        // Externally owned/provider skills keep their own identities. Do not read their sources.
                        guard target.path.hasPrefix(root.path + "/") else { continue }
                        source = String(target.path.dropFirst(root.path.count + 1)) + "/SKILL.md"
                    }
                    guard inspected.insert(source).inserted else { continue }
                    let text = try context.readText(source)
                    let directory = ((source as NSString).deletingLastPathComponent as NSString).lastPathComponent
                    var problems: [String] = []
                    if !validName(directory) {
                        problems.append("Skill directory must use <repo>_<skill>: lowercase letters/digits and hyphens, exactly one underscore, at most 64 characters.")
                    }
                    if let prefix, !directory.hasPrefix(prefix + "_") {
                        problems.append("Expected owning-repository prefix \(prefix)_; reusable skills require it too.")
                    }
                    // An indexed but locally deleted entrypoint cannot establish a current naming violation.
                    if !problems.isEmpty { findings.append(finding(context, source, problems.joined(separator: "\n"))) }
                    let name = try frontmatterName(text)
                    if name == nil {
                        findings.append(finding(context, source + "#name", "SKILL.md requires a name in a closed YAML frontmatter block."))
                    } else if name != directory {
                        findings.append(finding(context, source + "#name", "Frontmatter name must exactly match the skill directory and satisfy <repo>_<skill> naming (maximum 64 characters)."))
                    }
                    let ui = (source as NSString).deletingLastPathComponent + "/agents/openai.yaml"
                    if try context.exists(ui) {
                        let document = try context.yaml(ui)
                        if let raw = document.values["interface.default_prompt"] {
                            guard let prompt = simpleString(raw), !["|", ">", "|-", ">-"].contains(prompt) else {
                                throw InspectionError.blocked(ui + ": Unsupported default_prompt scalar; review its invocation manually.")
                            }
                            let invocations = CheckSupport.captures(prompt, #"\$([A-Za-z0-9_-]+)"#).map { $0[1] }
                            if !invocations.contains(directory) {
                                findings.append(finding(context, ui, "interface.default_prompt must explicitly invoke $\(directory)."))
                            }
                        }
                    }
                } catch {
                    if reasons.count < 8 {
                        let reason = error.localizedDescription
                        reasons.append(reason.hasPrefix(path + ":") ? reason : path + ": " + reason)
                    }
                }
            }
            if prefix == nil { reasons.append("Owning repository label cannot be resolved unambiguously within 20 characters; provide a valid root .repo-metadata.toml short-name. Format and identity checks still ran.") }
            findings = context.applyingExceptions(findings, policy: policy)
            return reasons.isEmpty ? .findings(findings) : .partial(findings, reasons.joined(separator: "\n"))
        })]
    }

    private static func finding(_ context: RepositoryInspectionContext, _ subject: String, _ evidence: String) -> RepositoryFinding {
        CheckSupport.finding(context, id, subject, "Skill naming rules", evidence, .setup, "tag")
    }

    private static func validName(_ name: String) -> Bool {
        name.utf8.count <= 64 && CheckSupport.matches(name, #"^[a-z0-9]+(?:-[a-z0-9]+)*_[a-z0-9]+(?:-[a-z0-9]+)*$"#)
    }

    private static func inventory(_ context: RepositoryInspectionContext) throws -> [String] {
        let patterns = [":(glob)**/SKILL.md", ":(glob)**/.agents/skills/*", ":(glob)**/.codex/skills/*"]
        let data = try context.gitRead(["ls-files", "--cached", "--others", "--exclude-standard", "-z", "--"] + patterns)
        guard let text = String(data: data, encoding: .utf8) else { throw InspectionError.blocked("Skill paths are not UTF-8.") }
        let paths = Set(text.split(separator: "\0").map(String.init)).filter { path in
            let parts = path.split(separator: "/").map(String.init)
            guard !parts.contains(where: { [".system", "node_modules", "vendor", "third-party", "third_party", "plugins", "fixtures", ".git"].contains($0) }) else { return false }
            if path.hasSuffix("/SKILL.md"), parts.count >= 3 {
                let parent = Array(parts.dropLast(2))
                return parent == ["skills"] || (parent.count >= 2 && parent.last == "skills" && [".agents", ".codex"].contains(parent[parent.count - 2]))
            }
            return parts.count >= 3 && parts[parts.count - 2] == "skills" && [".agents", ".codex"].contains(parts[parts.count - 3])
        }.sorted()
        guard paths.count <= 500 else { throw InspectionError.blocked("More than 500 skill entrypoints/discovery links need inspection.") }
        return paths
    }

    private static func expectedPrefix(_ context: RepositoryInspectionContext) throws -> String? {
        if try context.exists(".repo-metadata.toml") {
            let source = try context.readText(".repo-metadata.toml")
            if let metadata = try? InspectionConfig.toml(source, allSections: true),
               let raw = metadata.values["short-name"], raw.first == "\"" || raw.first == "'",
               let label = simpleString(raw), (1...20).contains(label.utf8.count),
               CheckSupport.matches(label, #"^[A-Za-z0-9_-]+$"#), let prefix = normalizedLabel(label) {
                return prefix
            }
        }
        let name: String
        if let remote = context.snapshot.remoteURL, !remote.isEmpty {
            if let repository = GitHubCI.repository(remote) { name = repository.name }
            else {
                guard !remote.contains(where: { $0.isWhitespace }), !remote.contains("?"), !remote.contains("#"),
                      let last = remote.split(separator: "/").last?.split(separator: ":").last else { return nil }
                let component = String(last)
                name = component.hasSuffix(".git") ? String(component.dropLast(4)) : component
            }
        } else { name = context.snapshot.url.lastPathComponent }
        guard name.utf8.count <= 20 else { return nil }
        return normalizedLabel(name)
    }

    private static func normalizedLabel(_ label: String) -> String? {
        let label = label.lowercased().replacingOccurrences(of: "_", with: "-")
        return CheckSupport.matches(label, #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#) ? label : nil
    }

    /// Read only the root name field; unrelated folded descriptions need no YAML interpreter.
    private static func frontmatterName(_ text: String) throws -> String? {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }) else { return nil }
        let names = lines[1..<end].filter { CheckSupport.matches($0, #"^(?:name|\"name\"|'name')\s*:"#) }
        guard names.count <= 1 else { throw InspectionError.blocked("Duplicate frontmatter name fields require review.") }
        guard let line = names.first, let colon = line.firstIndex(of: ":") else { return nil }
        let raw = InspectionConfig.withoutComment(String(line[line.index(after: colon)...]))
        guard let name = simpleString(raw), !name.isEmpty else { return nil }
        guard !CheckSupport.matches(name, #"^[!&*|>{\[]"#) else { throw InspectionError.blocked("Unsupported frontmatter name scalar requires review.") }
        return name
    }

    private static func simpleString(_ raw: String) -> String? {
        let raw = InspectionConfig.withoutComment(raw)
        if raw.first == "\"" {
            return (try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed])) as? String
        }
        if raw.first == "'" {
            guard raw.count >= 2, raw.last == "'" else { return nil }
            return String(raw.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return raw
    }
}
