import Foundation

enum RepositoryHygieneChecks {
    static func checks() -> [RepositoryCheck] {
        [
            CheckSupport.check("files.generatedTracked", "Generated files tracked", .setup, "trash.slash", inspect: { context, _ in
                let directories = ["node_modules", "__pycache__", ".venv", "DerivedData", ".DS_Store", ".pytest_cache", ".mypy_cache"]
                let patterns = directories.flatMap { [":(glob)**/" + $0, ":(glob)**/" + $0 + "/**"] } + [":(glob)**/*.pyc", ":(glob)**/*.pyo"]
                return try context.trackedPaths(matching: patterns).filter { path in
                    let components = path.split(separator: "/").map(String.init)
                    return components.contains { ["node_modules", "__pycache__", ".venv", "DerivedData", ".DS_Store", ".pytest_cache", ".mypy_cache"].contains($0) } || path.hasSuffix(".pyc") || path.hasSuffix(".pyo")
                }.map { path in
                    CheckSupport.finding(context, "files.generatedTracked", path, "Generated files tracked", "Git tracks \(path). Ignore rules do not remove files already in the index; review whether this is intentional.", .setup, "trash.slash")
                }
            }),
            CheckSupport.check("git.oldStashes", "Old stashes", .git, "archivebox", inspect: { context, policy in
                let output = try context.gitRead(["stash", "list", "--format=%H%x09%ct"])
                let lines = String(decoding: output, as: UTF8.self).split(separator: "\n")
                guard lines.count <= 100 else { throw RepairError.blocked("More than 100 stashes need review.") }
                var findings: [RepositoryFinding] = []
                for line in lines {
                    let parts = line.split(separator: "\t")
                    guard parts.count == 2, CheckSupport.matches(String(parts[0]), #"^[a-f0-9]{40,64}$"#), let timestamp = TimeInterval(parts[1]), timestamp.isFinite, (0...4_102_444_800).contains(timestamp) else { throw RepairError.blocked("Git returned invalid stash metadata.") }
                    let date = Date(timeIntervalSince1970: timestamp)
                    let days = Int(context.snapshot.checkedAt.timeIntervalSince(date) / 86_400)
                    guard days >= policy.stashAgeDays else { continue }
                    let sha = String(parts[0])
                    guard findings.count < 20 else { throw RepairError.blocked("More than 20 old stashes need review.") }
                    let paths = String(decoding: try context.gitRead(["stash", "show", "--no-ext-diff", "--no-textconv", "--include-untracked", "--name-only", "-z", sha]), as: UTF8.self).split(separator: "\0").prefix(10).joined(separator: ", ")
                    findings.append(CheckSupport.finding(context, "git.oldStashes", sha, "Old stash", "Stash \(sha.prefix(8)) is \(days) days old (threshold: \(policy.stashAgeDays)). Files: \(paths.isEmpty ? "none listed" : paths). Review it before restoring or deleting anything.", .git, "archivebox", severity: .information))
                }
                return findings
            }),
            CheckSupport.check("git.unfinishedOperation", "Git operation unfinished", .git, "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90", inspect: { context, _ in
                var findings: [RepositoryFinding] = []
                let unmerged = try context.gitRead(["ls-files", "--unmerged", "-z"])
                if !unmerged.isEmpty { findings.append(CheckSupport.finding(context, "git.unfinishedOperation", "conflicts", "Unmerged files", "The index contains unresolved merge entries. Preserve both sides while reviewing conflicts.", .git, "exclamationmark.triangle", severity: .blocked)) }
                for (marker, name) in [("MERGE_HEAD", "merge"), ("rebase-merge", "rebase"), ("rebase-apply", "rebase or am"), ("CHERRY_PICK_HEAD", "cherry-pick"), ("REVERT_HEAD", "revert"), ("sequencer", "sequencer")] {
                    let path = String(decoding: try context.gitRead(["rev-parse", "--git-path", marker]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !path.isEmpty else { throw RepairError.blocked("Git returned an empty operation marker path.") }
                    let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : context.snapshot.url.appendingPathComponent(path)
                    do {
                        _ = try url.resourceValues(forKeys: [.isDirectoryKey])
                        findings.append(CheckSupport.finding(context, "git.unfinishedOperation", marker, "Git operation unfinished", "Git metadata indicates an unfinished \(name). Review progress before continuing or aborting it.", .git, "exclamationmark.triangle", severity: .blocked))
                    } catch let error as CocoaError where error.code == .fileReadNoSuchFile { continue }
                }
                let branch = try context.gitRead(["symbolic-ref", "--quiet", "--short", "HEAD"], successfulExitCodes: [0, 1])
                if branch.isEmpty { findings.append(CheckSupport.finding(context, "git.unfinishedOperation", "HEAD", "Detached HEAD", "HEAD is detached. Inspect commits and choose how to preserve them before changing branches.", .git, "arrow.triangle.branch", severity: .information)) }
                return findings
            }),
            CheckSupport.check("docs.brokenLinks", "Broken local documentation links", .documentation, "link", inspect: { context, _ in
                try documentationFindings(context)
            }),
            CheckSupport.check("notebooks.hygiene", "Notebook hygiene", .documentation, "book.closed", inspect: { context, policy in
                guard policy.notebooks.enabled else { return [] }
                let paths = try context.trackedPaths(matching: [":(glob)**/*.ipynb"])
                guard paths.count <= 250 else { throw RepairError.blocked("More than 250 notebooks need inspection.") }
                var findings: [RepositoryFinding] = [], totalBytes = 0
                for path in paths {
                    let text = try context.readNotebook(path)
                    totalBytes += text.utf8.count
                    guard totalBytes <= 33_554_432 else { throw RepairError.blocked("Notebook inspection exceeds the 32 MiB repository limit.") }
                    guard let notebook = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                          (notebook["nbformat"] as? Int) == 4, let cells = notebook["cells"] as? [[String: Any]] else {
                        throw RepairError.blocked("Unsupported notebook format in " + path)
                    }
                    var outputBytes = 0, errors = 0
                    for cell in cells where (cell["cell_type"] as? String) == "code" {
                        guard let outputs = cell["outputs"] as? [[String: Any]] else { throw RepairError.blocked("Invalid notebook outputs in " + path) }
                        outputBytes += try JSONSerialization.data(withJSONObject: outputs).count
                        errors += outputs.filter { ($0["output_type"] as? String) == "error" }.count
                    }
                    if errors > 0 || outputBytes > policy.notebooks.maximumOutputBytes {
                        findings.append(CheckSupport.finding(context, "notebooks.hygiene", path, "Notebook hygiene", "\(path) has \(errors) saved error outputs and \(outputBytes) bytes of serialized outputs (limit: \(policy.notebooks.maximumOutputBytes)). Preserve intentional teaching examples or record an exception.", .documentation, "book.closed", severity: .information))
                    }
                }
                return findings
            })
        ]
    }
    private static func documentationFindings(_ context: RepositoryInspectionContext) throws -> [RepositoryFinding] {
        let root = try CheckSupport.rootFiles(context)
        let paths = Set(root.filter { RepositoryIssueCatalog.isReadme($0) || $0 == "AGENTS.md" } + (try context.trackedPaths(matching: [":(glob)**/SKILL.md", ":(glob)docs/**/*.md"])).filter {
            $0.hasSuffix("SKILL.md") || $0 == "docs/README.md" || ($0.hasPrefix("docs/") && $0.hasSuffix(".md"))
        }).sorted()
        guard paths.count <= 100 else { throw RepairError.blocked("More than 100 documentation files need inspection.") }
        var findings: [RepositoryFinding] = []
        for path in paths {
            let text = markdownProse(try context.readText(path))
            let links = text.replacingOccurrences(of: #"`[^`\n]*`"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"(?s)<!--.*?-->"#, with: "", options: .regularExpression)
            var targets = CheckSupport.captures(links, #"\]\(\s*(<[^>]+>|[^\s)]+)(?:\s+[^)]*)?\)"#).map { $0[1] }
            targets += CheckSupport.captures(links, #"(?m)^\s*\[[^\]]+\]:\s*(<[^>]+>|\S+)"#).map { $0[1] }
            targets += CheckSupport.captures(links, #"(?i)(?:src|href)\s*=\s*["']([^"']+)["']"#).map { $0[1] }
            if (path as NSString).lastPathComponent == "AGENTS.md" {
                targets += CheckSupport.captures(text, #"`((?:\./)?(?:\.agents|\.codex)/[^`\n]+/SKILL\.md)`"#).map { $0[1] }
            }
            var missing: [String] = []
            for raw in Set(targets).sorted() {
                let target = raw.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                guard !target.isEmpty, !target.hasPrefix("#"), !target.hasPrefix("/"), !target.hasPrefix("//"),
                      !CheckSupport.matches(target, #"^[a-zA-Z][a-zA-Z0-9+.-]*:"#), !target.contains("${"), !target.contains("{{") else { continue }
                let file = target.components(separatedBy: CharacterSet(charactersIn: "?#"))[0]
                guard let decoded = file.removingPercentEncoding, !decoded.isEmpty else { throw RepairError.blocked("Invalid local link encoding in " + path) }
                let directory = (path as NSString).deletingLastPathComponent
                let relative = directory.isEmpty ? decoded : directory + "/" + decoded
                if !(try context.localTargetExists(relative)) { missing.append(target) }
            }
            if !missing.isEmpty { findings.append(CheckSupport.finding(context, "docs.brokenLinks", path, "Broken local documentation links", "\(path) references missing local targets: \(missing.joined(separator: ", ")). Fenced code samples and external URLs are skipped.", .documentation, "link")) }
        }
        return findings
    }
    private static func markdownProse(_ source: String) -> String {
        var fence: String?, result: [String] = []
        for raw in source.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = String(trimmed.prefix(3))
                if fence == marker { fence = nil } else if fence == nil { fence = marker }
                continue
            }
            guard fence == nil, !raw.hasPrefix("    "), !raw.hasPrefix("\t") else { continue }
            result.append(raw)
        }
        return result.joined(separator: "\n")
    }
}
