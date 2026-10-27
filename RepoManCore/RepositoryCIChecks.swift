import Foundation

enum RepositoryCIChecks {
    typealias StatusLoader = @Sendable (RepositorySnapshot) async throws -> [CIBranchStatus]

    static func checks(loadStatus: @escaping StatusLoader = { snapshot in
        try await Task.detached(priority: .utility) { try GitHubCI.load(snapshot) }.value
    }) -> [RepositoryCheck] {
        [
            RepositoryCheck(id: "ci.failing", title: "CI failing", category: .ci, symbol: "xmark.seal", inspect: { context in
                guard let repository = GitHubCI.repository(context.snapshot.remoteURL) else { return [] }
                let branches = try await loadStatus(context.snapshot)
                var evidence: [String] = []
                var detailsURL: URL?
                var unknown: [String] = []
                for branch in branches {
                    let failures = branch.checks.filter(\.failed)
                    if !failures.isEmpty {
                        let failuresText = failures.map { "\($0.name): \($0.result.lowercased())" }.joined(separator: "; ")
                        evidence.append("Published commit \(branch.sha.prefix(8)) on \(branch.name): \(failuresText).")
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
            RepositoryCheck(id: "ci.coverage", title: "Missing CI coverage", category: .ci, symbol: "checkmark.shield", inspect: { context in
                guard let files = context.snapshot.rootFiles else {
                    throw InspectionError.blocked("Repository files could not be inspected.")
                }
                guard hasCode(files) else { return [] }
                if try files.contains(where: { [".gitlab-ci.yml", "Jenkinsfile", "azure-pipelines.yml", ".travis.yml"].contains($0) }) ||
                    !(try context.filenames(in: ".circleci")).isEmpty || !(try context.filenames(in: ".buildkite")).isEmpty {
                    throw InspectionError.blocked("External CI configuration is present; coverage inspection currently supports GitHub Actions.")
                }
                let names = try context.filenames(in: ".github/workflows").filter { ["yml", "yaml"].contains(($0 as NSString).pathExtension) }
                var uncertain = false
                for name in names {
                    switch WorkflowCoverage.analyze(try context.readText(".github/workflows/" + name)) {
                    case .covered: return []
                    case .unknown: uncertain = true
                    case .missing: break
                    }
                }
                if uncertain { throw InspectionError.blocked("Workflow coverage could not be determined. Conditional execution, custom scripts, reusable workflows, and unsupported YAML need review.") }
                return [RepositoryFinding(repositoryID: context.snapshot.id, checkID: "ci.coverage",
                    title: "Missing CI coverage",
                    evidence: names.isEmpty ? "No GitHub Actions workflows were found for this code project." :
                        "No build, test, lint, or type-check validation triggered by branch pushes or pull requests was recognized in \(names.joined(separator: ", ")). Tag-only releases and dependency review do not provide routine code validation.",
                    category: .ci, symbol: "checkmark.shield")]
            })
        ]
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
        let lines = source.components(separatedBy: .newlines).compactMap { raw -> Line? in
            let text = raw.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !text.hasPrefix("#") else { return nil }
            return Line(indent: raw.prefix(while: { $0 == " " }).count, text: text)
        }
        guard !source.contains("\t"), let onIndex = lines.firstIndex(where: { $0.indent == 0 && key($0.text) == "on" }),
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
                            if validationCommand(command) {
                                if state == .covered && stepState == .covered { return .covered }
                                uncertain = true
                            } else if matches(command, #"(?:\./|bash\s|sh\s|python\s|python3\s|uv run\s|npm run\s|pnpm (?:run\s)?|yarn\s|bun run\s)"#) { uncertain = true }
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
    static func validationCommand(_ text: String) -> Bool {
        // Require an executable command, not labels, comments, echo text, or setup steps.
        let patterns = [
            #"(?:npm|pnpm|yarn|bun)\s+(?:(?:run|exec|x)\s+)?(?:test|build|lint|typecheck|type-check|check|validate)(?:[\s:'\";]|$)"#,
            #"(?:pytest|ruff\s+check|mypy|pyright|flake8|pylint|tox|nox|tsc|eslint|vitest|jest)(?:[\s'\";]|$)"#,
            #"python(?:3)?\s+-m\s+(?:pytest|unittest|compileall)\b"#,
            #"(?:make\s+(?:test|check|lint|build)|bash\s+[^\s]*(?:test|check|lint|build)[^\s]*\.sh|\./[^\s]*(?:test|check|lint|build)[^\s]*\.sh)\b"#,
            #"(?:swift\s+(?:test|build)|xcodebuild|cargo\s+(?:test|build|check|clippy)|go\s+(?:test|build|vet)|(?:cmake\s+--build)|ctest|gradle[w]?\s+(?:test|build|check)|mvn\s+(?:test|verify)|bundle\s+exec\s+(?:rspec|rake))\b"#
        ]
        return text.components(separatedBy: .newlines).contains { raw in
            let line = raw.components(separatedBy: " #")[0].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            guard !line.hasPrefix("#"), !matches(line, #"^(echo|printf)\b"#) else { return false }
            let prefix = #"(?:^|&&\s*|;\s*|\buv run(?:\s+--(?:group|extra|python)\s+\S+|\s+--[\w-]+(?:=\S+)?)*\s+|\bpoetry run\s+|\b(?:pnpm exec|npm exec|yarn exec|npx)\s+|\b(?:bun x|bunx)(?:\s+--no-install)?\s+|\btimeout\s+\d+\s+)"#
            return patterns.contains { matches(line, prefix + $0) }
        }
    }
    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}
