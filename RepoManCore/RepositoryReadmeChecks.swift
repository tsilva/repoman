import Foundation

enum RepositoryReadmeChecks {
    static let id = "docs.readmeConsistency"
    /// Carry the shipped criteria into the repair, without requiring an installed skill.
    static let repairRecipe: RepairRecipe = {
        let requirements: String
        do {
            requirements = try contract().rules.map { "- \($0.title): \($0.condition)" }.joined(separator: "\n")
        } catch {
            requirements = "The bundled README acceptance criteria could not be loaded. Report this limitation and repair only the explicitly reported findings using repository evidence."
        }
        return RepairRecipe(id: id, title: "Repair README consistency", prompt: """
        Inspect the reported README consistency findings and bring the root Markdown README into conformance with the requirements below. Verify setup and usage commands against the actual repository. Preserve useful information and unrelated changes. Use existing logo and architecture assets; report missing prerequisites instead of generating assets or inserting broken references. Leave changes uncommitted; do not push or publish. The README will be independently checked again afterwards.

        README requirements:
        \(requirements)
        """)
    }()

    static func contract() throws -> SkillAcceptanceContract {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "optimize-readme.acceptance", withExtension: "json") else {
            throw RepairError.blocked("The optimize-readme acceptance document is missing from RepoMan.")
        }
        return try SkillAcceptanceContract.decode(Data(contentsOf: url))
    }
    static func checks(settings: ModelCheckSettings = .shared, evaluator: SkillConsistencyEvaluator = .shared,
                       loadContract: @escaping @Sendable () throws -> SkillAcceptanceContract = { try contract() }) -> [RepositoryCheck] {
        [RepositoryCheck(id: id, title: "README consistency", category: .documentation, symbol: "doc.text.magnifyingglass",
                         configurationKind: .model, evaluate: { context in
            let policy = try RepositoryCheckPolicy.load(context)
            let contract = try loadContract()
            let names = try CheckSupport.rootFiles(context).filter(RepositoryIssueCatalog.isReadme).sorted()
            guard names.count <= 8 else { throw RepairError.blocked("More than eight root READMEs need review.") }
            // The existing Missing README check owns absent files.
            guard !names.isEmpty else { return .findings([]) }
            var findings: [RepositoryFinding] = [], unknown: [String] = []
            for name in names {
                try Task.checkCancellation()
                guard ["", "md", "markdown"].contains((name as NSString).pathExtension.lowercased()) else {
                    unknown.append("\(name): semantic consistency currently requires a Markdown README.")
                    continue
                }
                let input = try ReadmeInspection(context, path: name)
                var decisions = try input.mechanicalDecisions(contract)
                let revision = settings.revision
                do {
                    let configuration = settings.configuration(for: id)
                    let token = try settings.token() ?? ""
                    let result = try await evaluator.review(contract, documents: input.documents,
                        configuration: configuration, token: token, allowCached: context.allowCachedModelChecks)
                    guard settings.revision == revision else { throw RepairError.blocked("Model settings changed during review. Refresh this check.") }
                    let current = try ReadmeInspection(RepositoryInspectionContext(snapshot: context.snapshot), path: name)
                    guard current.documents == input.documents else { throw RepairError.blocked("README evidence changed during review. Refresh this check.") }
                    decisions.merge(result.review.decisions) { _, new in new }
                    if result.cached { context.markCached(id) }
                } catch {
                    for rule in contract.rules where rule.evaluation == .semantic {
                        decisions[rule.id] = SkillRuleDecision(.uncertain, reason: error.localizedDescription)
                    }
                }
                for rule in contract.rules {
                    let subject = name + " · " + rule.id
                    if policy.exceptions[id]?[subject] != nil { continue }
                    guard let decision = decisions[rule.id] else { unknown.append(name + ": missing verdict for " + rule.id); continue }
                    switch decision.verdict {
                    case .fail:
                        let quote = decision.evidenceQuote.isEmpty ? "" : "\nEvidence: " + decision.evidenceQuote
                        findings.append(CheckSupport.finding(context, id, subject, rule.title,
                            decision.reason + quote, .documentation, "doc.text.magnifyingglass"))
                    case .uncertain: unknown.append(name + " — " + rule.title + ": " + decision.reason)
                    case .pass, .notApplicable: break
                    }
                }
            }
            if !unknown.isEmpty { return .partial(findings, Array(Set(unknown)).sorted().joined(separator: "\n")) }
            return .findings(findings)
        })]
    }
}

/// README-specific evidence and syntax stay outside the generic evaluator and provider adapter.
private struct ReadmeInspection {
    let context: RepositoryInspectionContext
    let path: String
    let text: String
    let roots: [String]
    let manifests: [String: String]
    let package: [String: Any]?
    let images: [String]
    let localImages: [String: Bool]
    let profile: Bool
    let commandSurface: Bool
    let pythonDescription: Bool
    let licenses: [String]
    let documents: [SkillEvidenceDocument]

    init(_ context: RepositoryInspectionContext, path: String) throws {
        self.context = context; self.path = path
        text = try context.readText(path)
        guard text.utf8.count <= 65_536 else { throw RepairError.blocked("\(path) exceeds the 64 KiB README review limit.") }
        roots = try context.filenames(in: ".").filter { $0 != ".git" }
        var selected: [String: String] = [:]
        for file in ["package.json", "pyproject.toml", "setup.cfg", "setup.py", "Cargo.toml", "Package.swift", "go.mod", "Makefile"] where roots.contains(file) {
            let source = try context.readText(file)
            guard source.utf8.count <= 32_768 else { throw RepairError.blocked("\(file) exceeds the 32 KiB model evidence limit.") }
            selected[file] = source
        }
        manifests = selected
        if let json = selected["package.json"] {
            guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
                throw RepairError.blocked("package.json cannot be inspected.")
            }
            package = object
        } else { package = nil }
        commandSurface = !selected.isEmpty || roots.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") })
        let remote = GitHubCI.repository(context.snapshot.remoteURL)
        profile = remote.map { $0.owner.lowercased() == $0.name.lowercased() } == true && !commandSurface
        licenses = try roots.filter { name in
            guard RepositoryIssueCatalog.isLicense(name) else { return false }
            return try !context.isDirectory(name)
        }
        images = Self.imageSources(text)
        guard images.count <= 64 else { throw RepairError.blocked("More than 64 README images need inspection.") }
        var targets: [String: Bool] = [:]
        for source in images where !Self.external(source) {
            let local = source.components(separatedBy: "#")[0].components(separatedBy: "?")[0].removingPercentEncoding ?? source
            targets[source] = try context.localTargetExists(local) && !context.isDirectory(local)
        }
        localImages = targets
        var published = false
        if let toml = selected["pyproject.toml"] {
            let config = try InspectionConfig.toml(toml, allSections: true)
            published = ["project.readme", "project.readme.file", "tool.poetry.readme"].contains { key in
                config.values[key].map { $0.localizedCaseInsensitiveContains(path) } == true
            }
        }
        for file in ["setup.cfg", "setup.py"] {
            if let source = selected[file], source.localizedCaseInsensitiveContains(path),
               source.contains("long_description") { published = true }
        }
        pythonDescription = published
        var facts = "Repository: \(context.snapshot.name)\nREADME: \(path)\nProfile repository: \(profile)\nCommand surface: \(commandSurface)\nPublished as Python package description: \(published)\n"
        facts += "Root entries: " + roots.joined(separator: ", ") + "\n"
        for source in images {
            facts += "Image \(source): " + (targets[source].map { $0 ? "local file present" : "local file missing" } ?? "remote URL, not fetched") + "\n"
        }
        documents = [SkillEvidenceDocument(id: path, text: text), SkillEvidenceDocument(id: "repository-facts", text: facts)]
            + selected.keys.sorted().map { SkillEvidenceDocument(id: $0, text: selected[$0]!) }
    }

    func mechanicalDecisions(_ contract: SkillAcceptanceContract) throws -> [String: SkillRuleDecision] {
        var result: [String: SkillRuleDecision] = [:]
        for rule in contract.rules where rule.evaluation == .mechanical {
            guard let decision = try decision(for: rule.id) else { throw RepairError.blocked("No mechanical validator is registered for " + rule.id) }
            result[rule.id] = decision
        }
        return result
    }
    private var header: String? {
        CheckSupport.captures(text.trimmingCharacters(in: .whitespacesAndNewlines),
            #"(?is)^<(p|div)\b[^>]*\balign\s*=\s*["']center["'][^>]*>.*?</\1\s*>"#).first?.first
    }
    private func decision(for id: String) throws -> SkillRuleDecision? {
        func answer(_ pass: Bool, _ success: String, _ failure: String) -> SkillRuleDecision {
            SkillRuleDecision(pass ? .pass : .fail, reason: pass ? success : failure)
        }
        switch id {
        case "opening.logo":
            guard let header, let image = Self.imageSources(header).first else {
                return SkillRuleDecision(.fail, reason: "\(path) must begin with a centered block containing a logo.")
            }
            let valid = localImages[image] != false && !Self.badge(image) &&
                !CheckSupport.matches(header, #"(?i)alt=["'][^"']*(?:screenshot|demo animation)[^"']*["']"#)
            return answer(valid, "Centered logo reference is present.", "The opening image is missing or is presented as a badge or screenshot.")
        case "tagline.markers":
            let start = "<!-- repo-tagline:start -->", end = "<!-- repo-tagline:end -->"
            guard text.components(separatedBy: start).count == 2, text.components(separatedBy: end).count == 2,
                  CheckSupport.captures(text, #"<!--\s*repo-tagline\b"#).count == 2,
                  let header, let a = header.range(of: start), let b = header.range(of: end), a.upperBound <= b.lowerBound,
                  let content = CheckSupport.captures(String(header[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines),
                    #"(?s)^<strong>([^<>]*)</strong>$"#).first?[1], !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (try? Self.decodeEntities(content)) != nil else {
                return SkillRuleDecision(.fail, reason: "Use exactly one tagline marker pair enclosing a plain-text <strong> tagline inside the opening header, including across examples.")
            }
            return SkillRuleDecision(.pass, reason: "One valid tagline marker pair encloses the header tagline.")
        case "tagline.format":
            guard let header, let raw = CheckSupport.captures(header, #"(?s)<strong>([^<>]*)</strong>|\*\*([^*\n]+)\*\*"#).first,
                  let title = try? Self.decodeEntities(raw[1].isEmpty ? raw[2] : raw[1]),
                  !title.contains("\n"), !title.contains("\r"), let first = title.first, let last = title.last,
                  Self.emoji(first), Self.emoji(last) else {
                return SkillRuleDecision(.fail, reason: "Place a bold, single-line tagline with an emoji at each edge directly beneath the logo.")
            }
            let phrase = title.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
            let words = phrase.split(whereSeparator: \.isWhitespace).count
            let prefix = String(header.prefix(upTo: header.range(of: raw[0])!.lowerBound))
            let withoutComments = prefix.replacingOccurrences(of: #"(?s)<!--.*?-->"#, with: "", options: .regularExpression)
            let afterImage = withoutComments.replacingOccurrences(of: #"(?is)^.*(?:<img\b[^>]*>|!\[[^\]]*\]\([^)]*\))"#, with: "", options: .regularExpression)
            let visible = afterImage.replacingOccurrences(of: #"(?is)<br\s*/?>|</?(?:a|p|div|picture)\b[^>]*>"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            return answer((1...10).contains(words) && !phrase.hasSuffix(".") && visible.isEmpty,
                "Tagline formatting and word count meet the contract.",
                "The tagline has \(words) words; it must have 1–10 words, no trailing period and no visible content between the logo and tagline.")
        case "badges.structure":
            let badges = images.filter(Self.badge)
            guard !badges.isEmpty else { return SkillRuleDecision(.notApplicable, reason: "No status badges are present.") }
            guard let header, let end = text.range(of: header) else { return SkillRuleDecision(.fail, reason: "Status badges need a separate centered row after the logo/tagline header.") }
            let rest = String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let row = CheckSupport.captures(rest, #"(?is)^<(p|div)\b[^>]*align\s*=\s*["']center["'][^>]*>.*?</\1\s*>"#).first?.first ?? ""
            let linked = CheckSupport.captures(row, #"(?is)<a\b[^>]*href\s*=.*?<img\b|\[!\[[^\]]*\]\([^)]*\)\]\([^)]*\)"#).count
            let vanity = badges.contains { CheckSupport.matches($0, #"(?i)(?:stars|downloads|followers|badge/-(?:linkedin|twitter|github)|badge/(?:react|typescript|javascript|swift)-)"#) }
            return answer(badges.count <= 4 && !vanity && Self.imageSources(row).filter(Self.badge).count == badges.count && linked >= badges.count,
                "Linked status badges occupy a separate compact row.", "Keep at most four useful, linked status badges in a separate centered row directly after the header; omit decorative badges.")
        case "header.links":
            guard let header else { return SkillRuleDecision(.pass, reason: "No centered text link row is present.") }
            let links = CheckSupport.captures(header, #"(?is)<a\b[^>]*href\s*=["'][^"']+["'][^>]*>(.*?)</a>|(?<!!)\[([^\]]+)\]\([^)]*\)"#)
                .map { $0[1].isEmpty ? $0[2] : $0[1] }
                .map { $0.replacingOccurrences(of: #"(?s)<[^>]+>"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return answer(links.isEmpty || (links.count == 1 && links[0].lowercased() == "live demo"),
                "The header has no decorative text links.", "Remove decorative header text links; only a single Live Demo link belongs after the tagline.")
        case "usage.setup":
            guard commandSurface && !profile else { return SkillRuleDecision(.notApplicable, reason: "No installable command surface was supplied.") }
            let body = Self.withoutFences(text)
            let section = CheckSupport.matches(body, #"(?im)^#{1,3}\s+(?:install(?:ation)?|setup|quick\s*start|getting started|use|usage|run|build|development)\b"#)
            let commands = CheckSupport.matches(text, #"(?m)^\s*```(?:bash|sh|shell|console|zsh|powershell|text)\s*$"#)
            let use = CheckSupport.matches(text, #"(?i)\b(?:open|run|execute|launch|start|use|prints?|writes?)\b"#)
            return answer(section && commands && use, "A setup/use section contains commands and a use instruction.", "Add a short setup/use section with labeled command fences and what to run or open.")
        case "commands.supported":
            guard let package else { return SkillRuleDecision(.notApplicable, reason: "No package.json script surface is present.") }
            let scripts = package["scripts"] as? [String: Any] ?? [:]
            let builtin: Set<String> = ["install", "i", "ci", "add", "remove", "uninstall", "update", "upgrade", "exec", "dlx", "create", "init", "publish", "pack", "link", "unlink", "audit", "outdated", "list", "ls", "why", "config", "cache", "version", "help", "info", "view", "rebuild", "prune", "dedupe", "fetch", "set", "setup", "import", "approve-builds", "check", "test", "start", "stop", "restart"]
            var missing: [String] = []
            for block in CheckSupport.captures(text, #"(?ms)^\s*```[^\n]*\n(.*?)^\s*```"#) {
                for match in CheckSupport.captures(block[1], #"(?m)(?:^|[;&|]\s*)\s*(npm|pnpm|yarn|bun)\s+(?:(run|run-script)\s+)?([A-Za-z][A-Za-z0-9:_-]*)"#) {
                    let manager = match[1], explicit = !match[2].isEmpty, name = match[3]
                    let requiresScript = explicit || (["pnpm", "yarn", "bun"].contains(manager) && !builtin.contains(name)) ||
                        (manager != "bun" && (name == "test" || name == "start"))
                    if requiresScript && scripts[name] == nil { missing.append(manager + " " + (explicit ? "run " : "") + name) }
                }
                for match in CheckSupport.captures(block[1], #"(?m)^\s*node\s+([A-Za-z0-9_./-]+\.(?:mjs|cjs|js))\b"#) {
                    if try !context.localTargetExists(match[1]) { missing.append("node " + match[1]) }
                }
            }
            return answer(missing.isEmpty, "Named package scripts and direct node paths are declared.", "These documented commands are not declared or their file is missing: " + Set(missing).sorted().joined(separator: ", "))
        case "architecture.position":
            let sections = Self.sections(text)
            guard let index = sections.firstIndex(where: { $0.title.lowercased() == "architecture" }) else {
                return SkillRuleDecision(.fail, reason: "Include an Architecture section containing an existing image.")
            }
            let expectedLast = licenseDeclared ? sections.count - 2 : sections.count - 1
            let sources = Self.imageSources(sections[index].body)
            return answer(index == expectedLast && !sources.isEmpty && sources.allSatisfy { localImages[$0] != false },
                "Architecture image is in the final content section.", "Architecture must contain an existing image and be immediately before License, or last when no license is declared.")
        case "license.link":
            guard licenseDeclared else { return SkillRuleDecision(.notApplicable, reason: "No license is declared in supplied files.") }
            let sections = Self.sections(text)
            guard let last = sections.last, last.title.lowercased() == "license" else {
                return SkillRuleDecision(.fail, reason: "Finish the README with a License section linking to the license file.")
            }
            let links = CheckSupport.captures(last.body, #"(?i)\[[^\]]+\]\(([^\s)]+)(?:\s+[^)]*)?\)|<a\b[^>]*href=["']([^"']+)"#).map { $0[1].isEmpty ? $0[2] : $0[1] }
            let valid = try links.contains { target in
                let clean = target.components(separatedBy: "#")[0].removingPercentEncoding ?? target
                guard !Self.external(clean), RepositoryIssueCatalog.isLicense((clean as NSString).lastPathComponent) else { return false }
                return try context.localTargetExists(clean)
            }
            return answer(valid, "Final License section links to an existing license file.", "The final License section needs a link to an existing license file; a bare license name is insufficient.")
        case "pypi.markup":
            guard pythonDescription else { return SkillRuleDecision(.notApplicable, reason: "This README is not declared as a Python package description.") }
            let invalidImage = images.contains { !$0.hasPrefix("https://") || CheckSupport.matches($0, #"(?i)^https://(?:www\.)?github\.com/[^/]+/[^/]+/blob/"#) }
            let validHeader = header.map { $0.lowercased().hasPrefix("<p") && $0.contains("<img") && $0.contains("<strong>") && CheckSupport.matches($0, #"(?i)<br\s*/>"#) && !$0.contains("**") } == true
            return answer(!invalidImage && validHeader && !CheckSupport.matches(text, #"(?i)<div\b[^>]*align=["']center"#),
                "Declared PyPI README uses absolute image URLs and supported header markup.", "PyPI README images need absolute HTTPS direct-image URLs; use p/img/br/strong centered markup, not div or Markdown bold inside HTML.")
        default: return nil
        }
    }
    private var licenseDeclared: Bool {
        !licenses.isEmpty || package?["license"] != nil || manifests["pyproject.toml"].map { CheckSupport.matches($0, #"(?m)^license(?:-files)?\s*="#) } == true
    }
    private static func imageSources(_ source: String) -> [String] {
        CheckSupport.captures(source, #"(?i)<img\b[^>]*\bsrc\s*=\s*["']([^"']+)["']|!\[[^\]]*\]\(<?([^\s)>]+)>?(?:\s+[^)]*)?\)"#)
            .map { $0[1].isEmpty ? $0[2] : $0[1] }
    }
    private static func external(_ source: String) -> Bool {
        source.hasPrefix("//") || source.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) != nil
    }
    private static func badge(_ source: String) -> Bool {
        CheckSupport.matches(source, #"(?i)shields\.io|badge\.svg|badgen\.net|badge\.fury\.io|badge/"#)
    }
    private static func emoji(_ value: Character) -> Bool {
        value.unicodeScalars.contains { $0.properties.isEmojiPresentation } ||
            (value.unicodeScalars.contains { $0.value == 0xFE0F || $0.value == 0x20E3 } && value.unicodeScalars.contains { $0.properties.isEmoji })
    }
    private static func decodeEntities(_ raw: String) throws -> String {
        var text = raw
        let regex = try NSRegularExpression(pattern: #"&(#x[0-9a-fA-F]+|#\d+|[a-z]+);"#)
        let entities = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]
        // Reject raw ampersands instead of silently interpreting malformed HTML.
        let stripped = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        guard !stripped.contains("&") else { throw RepairError.blocked("Escape ampersands in the marked tagline.") }
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let key = String(text[Range(match.range(at: 1), in: text)!])
            let replacement: String?
            if key.hasPrefix("#") {
                let number = key.hasPrefix("#x") ? UInt32(key.dropFirst(2), radix: 16) : UInt32(key.dropFirst())
                replacement = number.flatMap(UnicodeScalar.init).map(String.init)
            } else { replacement = entities[key] }
            guard let replacement else { throw RepairError.blocked("Unsupported tagline HTML entity.") }
            text.replaceSubrange(Range(match.range, in: text)!, with: replacement)
        }
        return text
    }
    private static func withoutFences(_ source: String) -> String {
        var fence: String?, lines: [String] = []
        for line in source.components(separatedBy: .newlines) {
            let trim = line.trimmingCharacters(in: .whitespaces)
            if let active = fence { if trim.hasPrefix(active) { fence = nil }; continue }
            if trim.hasPrefix("```") { fence = "```"; continue }
            if trim.hasPrefix("~~~") { fence = "~~~"; continue }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
    private static func sections(_ source: String) -> [(title: String, body: String)] {
        let lines = withoutFences(source).components(separatedBy: .newlines)
        var result: [(title: String, body: String)] = []
        for line in lines {
            if let title = CheckSupport.captures(line, #"^##\s+(.+?)\s*#*\s*$"#).first?[1] { result.append((title, "")) }
            else if !result.isEmpty { result[result.count - 1].body += line + "\n" }
        }
        return result
    }
}
