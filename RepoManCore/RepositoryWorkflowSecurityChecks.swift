import Foundation

enum RepositoryWorkflowSecurityChecks {
    static func checks() -> [RepositoryCheck] {
        [CheckSupport.check("ci.security", "Risky Actions workflow", .ci, "exclamationmark.shield", inspect: { context, _ in
            var findings: [RepositoryFinding] = []
            for (path, source) in try CheckSupport.workflows(context) {
                _ = try WorkflowInspection.references(source)
                let lines = try WorkflowInspection.lines(source)
                let steps = try WorkflowInspection.steps(source, includeInputs: true, inputKeys: ["ref", "repository"])
                var evidence: [String] = []
                let jobsIndex = lines.firstIndex(where: { $0.indent == 0 && $0.field == "jobs" })!
                let jobFieldIndent = WorkflowInspection.block(lines, jobsIndex).first.map { $0.indent + 2 }
                // Only permissions fields outside run scalars, at the workflow or job level.
                var scalarIndent: Int?
                for index in lines.indices {
                    let line = lines[index]
                    if let indent = scalarIndent {
                        if line.indent > indent { continue }; scalarIndent = nil
                    }
                    if line.value.hasPrefix("|") || line.value.hasPrefix(">") { scalarIndent = line.indent; continue }
                    guard line.field == "permissions", line.indent == 0 || (index > jobsIndex && line.indent == jobFieldIndent) else { continue }
                    let value = InspectionConfig.scalar(line.value) ?? ""
                    if value == "write-all" { evidence.append("Token permissions grant write-all access.") }
                    else if value.isEmpty || value.hasPrefix("{") {
                        let settings: [String: String]
                        if value.hasPrefix("{") {
                            let pairs = CheckSupport.captures(value, #"([a-z-]+)\s*:\s*(read|write|none)"#)
                            let residue = pairs.reduce(value) { $0.replacingOccurrences(of: $1[0], with: "") }
                            guard residue.allSatisfy({ "{}, \t".contains($0) }) else { throw RepairError.blocked("Unsupported token permission syntax.") }
                            settings = Dictionary(pairs.map { ($0[1], $0[2]) }, uniquingKeysWith: { _, newest in newest })
                        } else {
                            let fields = WorkflowInspection.block(lines, index)
                            guard fields.allSatisfy({ ["read", "write", "none"].contains($0.value) }) else { throw RepairError.blocked("Dynamic token permissions need manual review.") }
                            settings = Dictionary(fields.map { ($0.field, $0.value) }, uniquingKeysWith: { _, newest in newest })
                        }
                        if line.indent == 0, settings.values.contains("write") {
                            evidence.append("Workflow-wide write permissions apply to every job; review whether writes can be scoped to the jobs that need them.")
                        }
                    } else if value != "read-all" { throw RepairError.blocked("Dynamic token permissions need manual review.") }
                }
                for (number, step) in steps.enumerated() {
                    if CheckSupport.matches(step.commands.joined(separator: "\n"), #"\$\{\{[^}\n]*(?:github\.head_ref|github\.event\.(?:pull_request\.(?:title|body|head\.(?:ref|label))|issue\.(?:title|body)|comment\.body))[^}\n]*\}\}"#) {
                        evidence.append("Step \(number + 1) interpolates untrusted event text directly into a run script. Pass it through an environment variable and quote its use.")
                    }
                }
                let onLines = triggerLines(lines)
                if CheckSupport.matches(onLines, #"\bpull_request_target\b"#), steps.contains(where: { step in
                    (step.uses?.hasPrefix("actions/checkout@") == true) &&
                    ["ref", "repository"].contains { key in
                        CheckSupport.matches(step.inputs[key] ?? "", #"github\.head_ref|github\.event\.pull_request\.(?:head\.|merge_commit_sha|number)|refs/pull/"#)
                    }
                }) {
                    evidence.append("pull_request_target checks out the contributor's head in a privileged workflow. Review execution of PR code and exposure of credentials.")
                }
                if !evidence.isEmpty {
                    findings.append(CheckSupport.finding(context, "ci.security", path, "Risky Actions workflow",
                        Array(Set(evidence)).sorted().joined(separator: "\n"), .ci, "exclamationmark.shield", severity: .blocked))
                }
            }
            return findings
        })]
    }
    private static func triggerLines(_ lines: [WorkflowInspection.Line]) -> String {
        guard let index = lines.firstIndex(where: { $0.indent == 0 && $0.field == "on" }) else { return "" }
        return ([lines[index]] + WorkflowInspection.block(lines, index)).map(\.text).joined(separator: "\n")
    }
}
