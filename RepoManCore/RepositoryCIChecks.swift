import Foundation

enum RepositoryCIChecks {
    typealias StatusLoader = @Sendable (RepositorySnapshot) async throws -> [CIBranchStatus]

    static func checks(loadStatus: @escaping StatusLoader = { snapshot in
        try await Task.detached(priority: .utility) { try GitHubCI.load(snapshot) }.value
    }) -> [RepositoryCheck] {
        [
            RepositoryCheck(id: "ci.failing", title: "CI failing", category: .ci, symbol: "xmark.seal", inspect: { context in
                guard let repository = GitHubCI.repository(context.snapshot.remoteURL) else { throw InspectionError.notApplicable("No supported GitHub remote.") }
                let branches = try await context.ciStatuses(load: loadStatus)
                guard !branches.isEmpty else { throw InspectionError.blocked("No published branch CI results were returned.") }
                var evidence: [String] = []
                var detailsURL: URL?
                var unknown: [String] = []
                for branch in branches {
                    let failures = branch.checks.filter(\.failed)
                    if !failures.isEmpty {
                        let failuresText = failures.map { "\($0.name): \($0.result.lowercased())" }.joined(separator: "; ")
                        evidence.append("Published commit \(branch.sha.prefix(8)) on \(branch.name): \(failuresText).")
                        for failure in failures {
                            evidence += failure.locations.map { "\(failure.name): \($0.path):\($0.line) [\($0.rule)]. Matched content withheld." }
                            if failure.locationsTruncated { evidence.append("Additional annotation locations may exist; open the job for details.") }
                        }
                        detailsURL = detailsURL ?? failures.first?.url
                    } else if branch.checks.isEmpty {
                        unknown.append("No CI results are available for \(branch.name) at \(branch.sha.prefix(8)).")
                    } else if branch.checks.contains(where: { !$0.finished }) {
                        unknown.append("CI is running or incomplete on \(branch.name) at \(branch.sha.prefix(8)).")
                    }
                }
                // A pending run must not resolve an earlier failure. Keep known failures visible.
                if evidence.isEmpty, !unknown.isEmpty { throw InspectionError.blocked(unknown.joined(separator: " ")) }
                guard !evidence.isEmpty else { return [] }
                return [RepositoryFinding(repositoryID: context.snapshot.id, checkID: "ci.failing",
                    subject: repository.owner + "/" + repository.name, title: "CI failing",
                    evidence: (evidence + unknown).joined(separator: "\n"), category: .ci, severity: .blocked,
                    symbol: "xmark.seal", detailsURL: detailsURL)]
            }),
            RepositoryCheck(id: "ci.expectedChecks", title: "Expected CI validation", category: .ci, symbol: "checkmark.shield", evaluate: { context in
                let policy = try RepositoryCheckPolicy.load(context)
                guard !policy.ci.expectedChecks.isEmpty else { return .notApplicable("No expected CI checks are declared in .repoman.json.") }
                guard GitHubCI.repository(context.snapshot.remoteURL) != nil else { return .notApplicable("No supported GitHub remote.") }
                let branches = try await context.ciStatuses(load: loadStatus)
                guard !branches.isEmpty else { throw InspectionError.blocked("No published branch CI results were returned.") }
                var findings: [RepositoryFinding] = [], unknown: [String] = []
                for branch in branches {
                    for expected in policy.ci.expectedChecks {
                        let named = branch.checks.filter { $0.name == expected.name }
                        let matching = named.filter { check in
                            (expected.workflow == nil || check.workflow == expected.workflow) && (expected.event == nil || check.event == expected.event) && (expected.app == nil || check.app == expected.app)
                        }
                        let identity: [String?] = [expected.name, expected.workflow, expected.event, expected.app]
                        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
                        let subject = branch.name + "#expected:" + identity.map { $0?.addingPercentEncoding(withAllowedCharacters: allowed) ?? "*" }.joined(separator: "/")
                        if matching.isEmpty {
                            if named.contains(where: { expected.workflow != nil && $0.workflow == nil || expected.event != nil && $0.event == nil || expected.app != nil && $0.app == nil }) {
                                unknown.append("Publisher/workflow identity is unavailable for expected check \(expected.name) on \(branch.name).")
                            } else {
                                findings.append(CheckSupport.finding(context, "ci.expectedChecks", subject, "Expected CI check is missing", "Expected \(expected.name) is absent on \(branch.name) at \(branch.sha.prefix(8)). Enable the expected job or review its declared identity.", .ci, "checkmark.shield"))
                            }
                            continue
                        }
                        guard matching.count == 1 else { unknown.append("Expected CI identity \(expected.name) is ambiguous on \(branch.name); declare workflow, event and app."); continue }
                        let check = matching[0]
                        if expected.acceptedConclusions.contains(check.result) { continue }
                        if !check.finished && !check.failed { unknown.append("Expected check \(expected.name) is pending or incomplete on \(branch.name).") }
                        else if check.failed { unknown.append("Expected check \(expected.name) failed on \(branch.name); see ci.failing.") }
                        else { findings.append(CheckSupport.finding(context, "ci.expectedChecks", subject, "Expected validation did not execute successfully", "Expected \(expected.name) returned \(check.result.lowercased()) on \(branch.name). Its policy accepts \(expected.acceptedConclusions.joined(separator: ", ")); skipped/neutral results do not prove execution.", .ci, "checkmark.shield")) }
                    }
                }
                findings = context.applyingExceptions(findings, policy: policy)
                return unknown.isEmpty ? .findings(findings) : .partial(findings, unknown.prefix(10).joined(separator: " "))
            }),
            RepositoryCheck(id: "ci.coverage", title: "Routine validation coverage", category: .ci, symbol: "checkmark.shield", evaluate: { context in
                let policy = try RepositoryCheckPolicy.load(context)
                let files = try CheckSupport.rootFiles(context)
                let components = try coverageComponents(context, policy: policy)
                guard !components.isEmpty || hasCode(files) else { return .notApplicable("No recognized code components.") }
                if try files.contains(where: { [".gitlab-ci.yml", "Jenkinsfile", "azure-pipelines.yml", ".travis.yml"].contains($0) }) || !(try context.filenames(in: ".circleci")).isEmpty || !(try context.filenames(in: ".buildkite")).isEmpty {
                    throw InspectionError.blocked("External CI configuration is present; component coverage supports GitHub Actions.")
                }
                let workflows = try CheckSupport.workflows(context)
                var findings: [RepositoryFinding] = [], uncertain: [String] = []
                var scriptSources: [String: WorkflowCoverage.Result] = [:]
                let scriptSteps = Dictionary(uniqueKeysWithValues: workflows.map { path, _ in
                    (path, (try? PythonUnittestInspection.candidates(context, workflow: path)) ?? [:])
                })
                let targets = components.isEmpty ? [CoverageComponent(path: ".", ecosystem: "generic", requires: ["any"])] : components
                for component in targets {
                    var missing: [String] = []
                    for kind in component.requires {
                        var covered = false, unknown = false
                        for (path, _) in workflows {
                            do {
                                switch WorkflowCoverage.analyze(try context.workflowLines(path), componentPath: component.path, kind: kind, ecosystem: component.ecosystem, scriptValidation: { job, step, command in
                                    guard ["python", "generic"].contains(component.ecosystem),
                                          let candidate = scriptSteps[path]?[.init(job: job, number: step)],
                                          PythonUnittestInspection.literalScript(command) == candidate.argument else { return .missing }
                                    guard let sourcePath = candidate.path else { return .unknown }
                                    if let cached = scriptSources[sourcePath] { return cached }
                                    guard scriptSources.count < 32 else { return .unknown }
                                    let result = PythonUnittestInspection.validate(context, path: sourcePath)
                                    scriptSources[sourcePath] = result
                                    return result
                                }) {
                                case .covered: covered = true
                                case .unknown: unknown = true
                                case .missing: break
                                }
                            } catch { unknown = true }
                        }
                        if !covered {
                            if unknown { uncertain.append("\(component.path) (\(component.ecosystem)): \(kind) validation could not be established statically.") }
                            else { missing.append(kind) }
                        }
                    }
                    if !missing.isEmpty {
                        findings.append(CheckSupport.finding(context, "ci.coverage", component.path + "#" + component.ecosystem, "Component validation is missing", "No routine \(missing.joined(separator: ", ")) validation was recognized for \(component.path) (\(component.ecosystem)). Configure a branch-push/PR job in that component's working directory; tag-only releases do not count. Workflows inspected: \(workflows.map { $0.0 }.joined(separator: ", ")).", .ci, "checkmark.shield"))
                    }
                }
                findings = context.applyingExceptions(findings, policy: policy)
                return uncertain.isEmpty ? .findings(findings) : .partial(findings, uncertain.prefix(10).joined(separator: " "))
            })
        ]
    }

    private struct CoverageComponent { let path: String; let ecosystem: String; let requires: [String] }
    private static func coverageComponents(_ context: RepositoryInspectionContext, policy: RepositoryCheckPolicy) throws -> [CoverageComponent] {
        if let explicit = policy.ci.components { return explicit.map { CoverageComponent(path: $0.path == "./" ? "." : $0.path, ecosystem: $0.ecosystem, requires: $0.requires) } }
        var discovered: [String: CoverageComponent] = [:]
        func add(_ path: String, _ ecosystem: String) {
            let directory = (path as NSString).deletingLastPathComponent
            let root = directory.isEmpty ? "." : directory
            discovered[root + "#" + ecosystem] = CoverageComponent(path: root, ecosystem: ecosystem, requires: ["any"])
        }
        for path in try CheckSupport.manifests(context) { add(path, path.hasSuffix("package.json") ? "javascript" : "python") }
        let native = try context.trackedPaths(matching: [":(glob)**/Package.swift", ":(glob)**/*.xcodeproj/project.pbxproj"])
        for path in native where !path.split(separator: "/").contains(where: { [".build", "DerivedData", "vendor", "node_modules"].contains(String($0)) }) {
            if path.hasSuffix("project.pbxproj") {
                let parent = ((path as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
                add(parent.isEmpty ? "Package.swift" : parent + "/Package.swift", "swift")
            } else { add(path, "swift") }
        }
        if try CheckSupport.rootFiles(context).contains("Package.swift") { add("Package.swift", "swift") }
        guard discovered.count <= 64 else { throw InspectionError.blocked("More than 64 CI components need inspection.") }
        return discovered.keys.sorted().map { discovered[$0]! }
    }

    private static func hasCode(_ files: [String]) -> Bool {
        let manifests: Set<String> = ["package.json", "pyproject.toml", "requirements.txt", "setup.py", "setup.cfg", "Package.swift",
            "Cargo.toml", "go.mod", "CMakeLists.txt", "Makefile", "Gemfile", "pom.xml", "build.gradle", "build.gradle.kts", "composer.json"]
        let extensions: Set<String> = ["xcodeproj", "xcworkspace", "swift", "py", "js", "ts", "tsx", "jsx", "rs", "go", "c", "cpp", "cs", "java", "rb"]
        return files.contains { manifests.contains($0) || extensions.contains(($0 as NSString).pathExtension) }
    }
}

/// Conservative recognizer, not a YAML interpreter. Unknown custom execution stays unavailable.
enum WorkflowCoverage {
    enum Result { case covered, missing, unknown }
    private struct Line {
        let indent: Int
        let text: String
    }
    static func analyze(_ source: String) -> Result {
        guard let parsed = try? WorkflowInspection.lines(source) else { return .unknown }
        return analyze(parsed)
    }
    static func analyze(_ parsed: [WorkflowInspection.Line], componentPath: String? = nil, kind: String? = nil, ecosystem: String? = nil,
                        scriptValidation: ((String, Int, String) -> Result)? = nil) -> Result {
        let lines = parsed.map { Line(indent: $0.indent, text: $0.text) }
        guard let onIndex = lines.firstIndex(where: { $0.indent == 0 && key($0.text) == "on" }),
              let jobsIndex = lines.firstIndex(where: { $0.indent == 0 && key($0.text) == "jobs" }) else { return .unknown }
        let on = block(lines, at: onIndex)
        let trigger = value(lines[onIndex].text)
        let routine: Bool
        if !trigger.isEmpty {
            // Simple event names and event lists are supported; flow mappings require review.
            guard !trigger.contains("{") && !trigger.contains("&") && !trigger.contains("*") else { return .unknown }
            routine = matches(trigger, #"\b(push|pull_request|pull_request_target)\b"#)
        } else {
            guard let eventIndent = on.first?.indent else { return .unknown }
            let events = on.indices.filter { on[$0].indent == eventIndent }
            var hasRoutine = false
            for index in events {
                let event = key(on[index].text)
                if event == "pull_request" || event == "pull_request_target" { hasRoutine = true }
                if event == "push" {
                    let config = block(on, at: index)
                    let inline = value(on[index].text)
                    if inline.contains("{") { return .unknown }
                    // With only tags/tags-ignore filters, GitHub does not run branch pushes.
                    let hasTags = config.contains { ["tags", "tags-ignore"].contains(key($0.text)) }
                    let hasBranches = config.contains { ["branches", "branches-ignore"].contains(key($0.text)) }
                    if !hasTags || hasBranches { hasRoutine = true }
                }
            }
            routine = hasRoutine
        }
        guard routine else { return .missing }
        let jobs = block(lines, at: jobsIndex)
        guard !jobs.isEmpty else { return .unknown }
        if jobs.contains(where: { $0.text.hasPrefix("<<:") || matches($0.text, #":\s*&\w"#) || value($0.text).hasPrefix("*") }) { return .unknown }
        guard let jobIndent = jobs.first?.indent else { return .unknown }
        let starts = jobs.indices.filter { jobs[$0].indent == jobIndent }
        let namedJobs = Dictionary(grouping: starts, by: { key(jobs[$0].text) })
        guard namedJobs.values.allSatisfy({ $0.count == 1 }) else { return .unknown }
        // A literal false guard disables execution. Expressions we cannot evaluate
        // stay unknown, including guards inherited through a job's dependencies.
        func condition(_ body: [Line], indent: Int) -> Result {
            let guards = body.filter { $0.indent == indent && key($0.text) == "if" }
            guard guards.count <= 1 else { return .unknown }
            guard let guardLine = guards.first else { return .covered }
            var expression = value(guardLine.text).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if expression.hasPrefix("${{"), expression.hasSuffix("}}") {
                expression = String(expression.dropFirst(3).dropLast(2)).trimmingCharacters(in: .whitespaces)
            }
            if expression == "false" { return .missing }
            return expression == "true" ? .covered : .unknown
        }
        func jobState(_ index: Int, visited: Set<Int> = []) -> Result {
            guard !visited.contains(index), visited.count < 100 else { return .unknown }
            let body = block(jobs, at: index)
            guard let indent = body.first?.indent else { return .unknown }
            let state = condition(body, indent: indent)
            if state == .missing { return .missing }
            var unknown = state == .unknown
            for needs in body.indices where body[needs].indent == indent && key(body[needs].text) == "needs" {
                let text = value(body[needs].text)
                let names: [String]
                if text.isEmpty {
                    names = block(body, at: needs).map { $0.text.replacingOccurrences(of: "- ", with: "") }
                } else { names = text.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).components(separatedBy: ",") }
                guard !names.isEmpty else { return .unknown }
                for raw in names {
                    let name = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                    guard let dependency = namedJobs[name]?.first else { return .unknown }
                    let dependencyState = jobState(dependency, visited: visited.union([index]))
                    // An unknown explicit condition could override GitHub's default
                    // dependency skipping; do not claim it is definitely disabled.
                    if dependencyState == .missing { return state == .covered ? .missing : .unknown }
                    if dependencyState == .unknown { unknown = true }
                }
            }
            return unknown ? .unknown : .covered
        }
        var uncertain = false
        for job in starts {
            let state = jobState(job)
            if state == .missing { continue }
            let body = block(jobs, at: job)
            guard let fieldIndent = body.first?.indent else { uncertain = true; continue }
            if body.contains(where: { $0.indent == fieldIndent && key($0.text) == "uses" }) { uncertain = true }
            for steps in body.indices where body[steps].indent == fieldIndent && key(body[steps].text) == "steps" {
                let stepLines = block(body, at: steps)
                guard let stepIndent = stepLines.first?.indent else { uncertain = true; continue }
                let stepStarts = stepLines.indices.filter { stepLines[$0].indent == stepIndent && stepLines[$0].text.hasPrefix("- ") }
                for (offset, start) in stepStarts.enumerated() {
                    let end = offset + 1 < stepStarts.count ? stepStarts[offset + 1] : stepLines.count
                    var fields = Array(stepLines[start..<end])
                    fields[0] = Line(indent: stepIndent + 2, text: String(fields[0].text.dropFirst(2)))
                    let stepState = condition(fields, indent: stepIndent + 2)
                    if stepState == .missing { continue }
                    for index in fields.indices where fields[index].indent == stepIndent + 2 {
                        let field = key(fields[index].text), text = value(fields[index].text)
                        if field == "uses" {
                            if !matches(text, #"^(actions/(?:checkout|setup-[a-z0-9-]+|cache|upload-artifact|download-artifact|dependency-review-action)@|github/codeql-action/|astral-sh/setup-uv@|docker/setup-|pnpm/action-setup@|ruby/setup-ruby@|dtolnay/rust-toolchain@)"#) { uncertain = true }
                        }
                        if field == "run" {
                            let command = text.hasPrefix("|") || text.hasPrefix(">") ? block(fields, at: index).map(\.text).joined(separator: "\n") : text
                            let script = scriptValidation?(key(jobs[job].text), offset, command) ?? .missing
                            if validationCommand(command) || script == .covered {
                                if let componentPath {
                                    guard script == .covered || languageMatches(command, ecosystem ?? "generic") else { continue }
                                    if matches(command, #"(?:^|[;&\n])\s*cd\s"#) { uncertain = true; continue }
                                    func defaultsDirectory(_ scope: [Line], indent: Int) -> String? {
                                        guard let defaults = scope.indices.first(where: { scope[$0].indent == indent && key(scope[$0].text) == "defaults" }) else { return nil }
                                        let declaration = value(scope[defaults].text)
                                        if !declaration.isEmpty && declaration != "{}" { return "${{ unsupported }}" }
                                        let defaultsBlock = block(scope, at: defaults)
                                        guard let run = defaultsBlock.indices.first(where: { key(defaultsBlock[$0].text) == "run" }) else { return nil }
                                        if !value(defaultsBlock[run].text).isEmpty && value(defaultsBlock[run].text) != "{}" { return "${{ unsupported }}" }
                                        return block(defaultsBlock, at: run).first(where: { key($0.text) == "working-directory" }).map { value($0.text) }
                                    }
                                    let declared = fields.first(where: { $0.indent == stepIndent + 2 && key($0.text) == "working-directory" }).map { value($0.text) }
                                        ?? defaultsDirectory(Array(body.prefix(steps)), indent: fieldIndent)
                                        ?? defaultsDirectory(Array(lines.prefix(jobsIndex)), indent: 0) ?? "."
                                    guard let directory = normalizedDirectory(declared), let expected = normalizedDirectory(componentPath) else { uncertain = true; continue }
                                    guard directory == expected else { continue }
                                    let kinds: Set<String> = script == .covered ? ["test"] : validationKinds(command)
                                    if let kind, kind != "any", !kinds.contains(kind) {
                                        if matches(command, #"\b(check|validate)\b"#) { uncertain = true }
                                        continue
                                    }
                                }
                                if state == .covered && stepState == .covered { return .covered }
                                uncertain = true
                            } else if script == .unknown || matches(command, #"(?:\./|bash\s|sh\s|python\s|python3\s|uv run\s|npm run\s|pnpm (?:run\s)?|yarn\s|bun run\s)"#) { uncertain = true }
                        }
                    }
                }
            }
        }
        return uncertain ? .unknown : .missing
    }
    private static func block(_ lines: [Line], at index: Int) -> [Line] {
        Array(lines.dropFirst(index + 1).prefix { $0.indent > lines[index].indent })
    }
    private static func key(_ text: String) -> String {
        let text = text.hasPrefix("- ") ? String(text.dropFirst(2)) : text
        return String(text.split(separator: ":", maxSplits: 1).first ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
    }
    private static func value(_ text: String) -> String {
        guard let colon = text.firstIndex(of: ":") else { return "" }
        return String(text[text.index(after: colon)...]).components(separatedBy: " #")[0].trimmingCharacters(in: .whitespaces)
    }
    static func normalizedDirectory(_ source: String) -> String? {
        let raw = InspectionConfig.scalar(source) ?? source
        guard !raw.isEmpty, !raw.hasPrefix("/"), !raw.contains(where: { "$~{}*?".contains($0) }) else { return nil }
        var parts: [String] = []
        for part in raw.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { guard !parts.isEmpty else { return nil }; parts.removeLast() }
            else { parts.append(String(part)) }
        }
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }
    private static func languageMatches(_ command: String, _ ecosystem: String) -> Bool {
        switch ecosystem {
        case "swift": return matches(command, #"\b(swift\s+(test|build)|xcodebuild)\b"#)
        case "python": return matches(command, #"\b(pytest|unittest|ruff|mypy|pyright|flake8|pylint|tox|nox|python[0-9.]*\s+-m\s+(build|compileall))\b"#)
        case "javascript": return matches(command, #"\b(npm|pnpm|yarn|bun|bunx|vitest|jest|tsc|eslint)\b|\bnode\s+--test(?:[=\s]|$)"#)
        default: return true
        }
    }
    static func validationKinds(_ command: String) -> Set<String> {
        var result = Set<String>()
        if matches(command, #"\b(test|pytest|unittest|vitest|jest|rspec|ctest)\b"#) { result.insert("test") }
        if matches(command, #"\b(build|xcodebuild|compileall)\b"#) { result.insert("build") }
        if matches(command, #"\b(lint|eslint|ruff|flake8|pylint|clippy|vet)\b"#) { result.insert("lint") }
        if matches(command, #"\b(typecheck|type-check|tsc|mypy|pyright)\b"#) { result.insert("typecheck") }
        return result
    }
    static func validationCommand(_ text: String) -> Bool {
        // Require an executable command, not labels, comments, echo text, or setup steps.
        let patterns = [
            #"node\s+--test(?:[=\s]|$)"#,
            #"(?:npm|pnpm|yarn|bun)\s+(?:(?:run|exec|x)\s+)?(?:test|build|lint|typecheck|type-check|check|validate)(?:[\s:'\";]|$)"#,
            #"(?:pytest|ruff\s+check|mypy|pyright|flake8|pylint|tox|nox|tsc|eslint|vitest|jest)(?:[\s'\";]|$)"#,
            #"python(?:3)?\s+-m\s+(?:pytest|unittest|compileall)\b"#,
            #"(?:make\s+(?:test|check|lint|build)|bash\s+[^\s]*(?:test|check|lint|build)[^\s]*\.sh|\./[^\s]*(?:test|check|lint|build)[^\s]*\.sh)\b"#,
            #"(?:swift\s+(?:test|build)|xcodebuild|cargo\s+(?:test|build|check|clippy)|go\s+(?:test|build|vet)|(?:cmake\s+--build)|ctest|gradle[w]?\s+(?:test|build|check)|mvn\s+(?:test|verify)|bundle\s+exec\s+(?:rspec|rake))\b"#
        ]
        return text.components(separatedBy: .newlines).contains { raw in
            let line = raw.components(separatedBy: " #")[0].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            guard !line.hasPrefix("#"), !matches(line, #"^(echo|printf)\b"#), !matches(line, #"^xcodebuild\s+-(version|list|showBuildSettings|resolvePackageDependencies)\b"#) else { return false }
            // Literal config paths are data; variables, shell operators, escapes and
            // missing option values must not be mistaken for executed validation.
            let configValue = #"(?:'(?!-)[^'\r\n\\;&|$`<>*?()~]+'|"(?!-)[^"\r\n\\;&|$`<>*?()~]+"|(?!-)[^\s"'\\;&|$`<>*?()~]+)"#
            let flags = CheckSupport.captures(raw, #"(?:^|\s)--config-file(?=[=\s]|$)"#).count
            let literals = CheckSupport.captures(raw, #"(?:^|\s)--config-file(?:=|\s+)"# + configValue + #"(?=\s|$)"#).count
            guard flags == literals else { return false }
            let uvOptions = #"(?:\s+--(?:group|extra|python)\s+\S+|\s+--config-file(?:=|\s+)"# + configValue + #"|\s+(?!--config-file(?:[=\s]|$))--[\w-]+(?:=\S+)?)*\s+"#
            let globalUV = #"(?:^|&&\s*|;\s*)uv\s+--config-file(?:=|\s+)"# + configValue + #"\s+run"# + uvOptions
            let prefix = #"(?:^|&&\s*|;\s*|\buv run"# + uvOptions + "|" + globalUV + #"|\bpoetry run\s+|\b(?:pnpm exec|npm exec|yarn exec|npx)\s+|\b(?:bun x|bunx)(?:\s+--no-install)?\s+|\btimeout\s+\d+\s+)"#
            return patterns.contains { matches(line, prefix + $0) }
        }
    }
    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}

/// Bounded metadata inspection only. Neither Python source nor workflow commands are executed.
enum PythonUnittestInspection {
    struct StepKey: Hashable { let job: String; let number: Int }
    struct Candidate { let argument: String; let path: String? }

    static func literalScript(_ command: String) -> String? {
        let expression = #"^\s*python(?:3(?:\.[0-9]+)?)?\s+(?:'([^'\n]+\.py)'|\"([^\"\n]+\.py)\"|([^\s]+\.py))\s*$"#
        guard let regex = try? NSRegularExpression(pattern: expression),
              let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) else { return nil }
        for index in 1...3 {
            if let range = Range(match.range(at: index), in: command) {
                let path = String(command[range])
                guard !path.hasPrefix("-"), !path.contains(where: { "$~;&|<>*?()[]#\\`\"'".contains($0) }),
                      WorkflowCoverage.normalizedDirectory(path) != nil else { return nil }
                return path
            }
        }
        return nil
    }

    static func candidates(_ context: RepositoryInspectionContext, workflow: String) throws -> [StepKey: Candidate] {
        let remote = GitHubCI.repository(context.snapshot.remoteURL)
        let repository = remote.map { $0.owner + "/" + $0.name }
        var counters: [String: Int] = [:], checkouts: [String: Bool] = [:], result: [StepKey: Candidate] = [:]
        for step in try context.workflowSteps(workflow, includeInputs: true, inputKeys: [], checkoutInputKeys: ["repository", "ref", "path", "sparse-checkout"]) {
            let number = counters[step.job, default: 0]
            counters[step.job] = number + 1
            if step.uses?.lowercased().hasPrefix("actions/checkout@") == true {
                checkouts[step.job] = WorkflowInspection.isCurrentRepositoryCheckout(step, repository: repository) &&
                    WorkflowCoverage.normalizedDirectory(step.inputs["path"] ?? ".") == "."
            }
            guard step.commands.count == 1, let argument = literalScript(step.commands[0]) else { continue }
            let path = checkouts[step.job] == true && !step.toleratesFailure &&
                (step.shell == nil || ["bash", "sh"].contains(step.shell!))
                ? WorkflowCoverage.normalizedDirectory((step.workingDirectory ?? ".") + "/" + argument) : nil
            result[StepKey(job: step.job, number: number)] = Candidate(argument: argument, path: path)
        }
        return result
    }

    static func validate(_ context: RepositoryInspectionContext, path: String, interpreter: String = "/usr/bin/python3") -> WorkflowCoverage.Result {
        do {
            guard try context.isTracked(path), let size = try context.regularFileSize(path), size <= 262_144 else { return .unknown }
            let source = try context.readText(path)
            guard let imports = importsIfUnittest(source, interpreter: interpreter) else { return .unknown }
            let directory = (path as NSString).deletingLastPathComponent
            // Script-directory and workspace imports can shadow the modules established by the parser.
            for root in Set(["", directory]) {
                for name in imports {
                    let prefix = root.isEmpty ? name : root + "/" + name
                    if try context.exists(prefix + ".py") || context.exists(prefix) { return .unknown }
                }
            }
            return .covered
        } catch { return .unknown }
    }

    static func importsIfUnittest(_ source: String, interpreter: String = "/usr/bin/python3") -> [String]? {
        guard source.utf8.count <= 262_144, FileManager.default.isExecutableFile(atPath: interpreter) else { return nil }
        let process = Process(), input = Pipe(), output = Pipe(), done = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: interpreter)
        process.arguments = ["-I", "-S", "-B", "-c", parser]
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        let written = DispatchGroup()
        written.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { try? input.fileHandleForWriting.close(); written.leave() }
            try? input.fileHandleForWriting.write(contentsOf: Data(source.utf8))
        }
        if done.wait(timeout: .now() + 3) == .timedOut {
            process.terminate()
            if done.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
            return nil
        }
        guard written.wait(timeout: .now() + 1) == .success, process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard data.count <= 4096 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String]
    }

    // A deliberately small, auditable AST subset. Parsing occurs in isolated system Python,
    // with source on stdin and only module-name metadata returned. Unsupported forms stay unknown.
    private static let parser = #"""
import ast, json, sys

def inspect(source):
    tree = ast.parse(source)
    body = tree.body
    if not body or not isinstance(body[-1], ast.If): return None
    guard = body[-1]
    expected = ast.parse("__name__ == '__main__'", mode='eval').body
    reverse = ast.parse("'__main__' == __name__", mode='eval').body
    if ast.dump(guard.test) not in (ast.dump(expected), ast.dump(reverse)): return None
    if guard.orelse or len(guard.body) != 1: return None
    call = guard.body[0]
    if not isinstance(call, ast.Expr) or ast.dump(call.value) != ast.dump(ast.parse('unittest.main()', mode='eval').body): return None
    allowed = set('unittest pathlib json os pty select signal time shutil subprocess sys tempfile math re collections itertools functools typing dataclasses contextlib io asyncio enum datetime copy random string hashlib socket struct textwrap logging types abc statistics csv glob urllib platform threading queue warnings weakref inspect importlib'.split())
    imports, names, tests, unittest_import = set(), set(), False, False
    def doc(node): return isinstance(node, ast.Expr) and isinstance(node.value, ast.Constant) and isinstance(node.value.value, str)
    def function(node):
        if not isinstance(node, ast.FunctionDef) or node.decorator_list or node.returns: return False
        args = node.args
        if any(not literal(v) for v in args.defaults) or any(v is not None and not literal(v) for v in args.kw_defaults): return False
        return all(a.annotation is None for a in args.posonlyargs + args.args + args.kwonlyargs + ([args.vararg] if args.vararg else []) + ([args.kwarg] if args.kwarg else []))
    def literal(node):
        if isinstance(node, ast.Constant): return True
        if isinstance(node, (ast.List, ast.Tuple, ast.Set)): return all(literal(v) for v in node.elts)
        if isinstance(node, ast.Dict): return all(k is not None and literal(k) and literal(v) for k,v in zip(node.keys,node.values))
        if isinstance(node, ast.UnaryOp) and isinstance(node.op,(ast.USub,ast.UAdd)): return isinstance(node.operand,ast.Constant) and isinstance(node.operand.value,(int,float))
        return False
    for node in body[:-1]:
        if doc(node): continue
        if isinstance(node,(ast.Import, ast.ImportFrom)):
            if isinstance(node,ast.ImportFrom) and (node.level or not node.module): return None
            modules = [a.name.split('.')[0] for a in node.names] if isinstance(node,ast.Import) else [node.module.split('.')[0]]
            if any(m not in allowed for m in modules): return None
            imports.update(modules)
            for alias in node.names:
                name = alias.asname or (alias.name.split('.')[0] if isinstance(node,ast.Import) else alias.name)
                if name in names or name in ('__name__','load_tests') or alias.name == '*': return None
                names.add(name)
                if name == 'unittest':
                    if not isinstance(node,ast.Import) or alias.name != 'unittest' or alias.asname: return None
                    unittest_import = True
                if name == 'Path' and (not isinstance(node,ast.ImportFrom) or node.module != 'pathlib' or alias.name != 'Path' or alias.asname): return None
        elif isinstance(node,ast.Assign):
            if not all(isinstance(t,ast.Name) and t.id not in names and t.id not in ('unittest','__name__','load_tests','Path') for t in node.targets): return None
            path_value = 'Path' in names and ast.dump(node.value) == ast.dump(ast.parse('Path(__file__).resolve().parents[1]',mode='eval').body)
            if not literal(node.value) and not path_value: return None
            names.update(t.id for t in node.targets)
        elif isinstance(node,ast.ClassDef):
            if not unittest_import or node.name in names or node.name in ('load_tests','unittest','Path','__name__') or node.decorator_list or node.keywords or len(node.bases)!=1: return None
            if ast.dump(node.bases[0]) != ast.dump(ast.parse('unittest.TestCase',mode='eval').body): return None
            methods = set()
            for member in node.body:
                if doc(member) or isinstance(member,ast.Pass): continue
                if not function(member) or member.name in methods or member.name in ('__init__','run','__call__'): return None
                methods.add(member.name)
            if not any(m.startswith('test') for m in methods): return None
            tests = True
            names.add(node.name)
        elif function(node):
            if node.name in names or node.name in ('unittest','Path','load_tests','__name__'): return None
            names.add(node.name)
        else: return None
    return sorted(imports) if tests and unittest_import else None

try:
    result = inspect(sys.stdin.read())
except (SyntaxError, ValueError, TypeError, RecursionError, MemoryError):
    result = None
print(json.dumps(result))
"""#
}
