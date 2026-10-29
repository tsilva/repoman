import Foundation

enum RepositoryWorkflowChecks {
    static func checks() -> [RepositoryCheck] {
        [
            CheckSupport.check("ci.mutableActions", "Actions references are mutable", .ci, "lock.shield", inspect: { context, _ in
                var findings: [RepositoryFinding] = []
                for (path, source) in try CheckSupport.applicableWorkflows(context) {
                    let references = try context.workflowReferences(path)
                    let mutable = references.filter { reference in
                        if reference.hasPrefix("./") { return false }
                        if reference.hasPrefix("docker://") { return !CheckSupport.matches(reference, #"@sha256:[0-9a-fA-F]{64}$"#) }
                        return !CheckSupport.matches(reference, #"@[0-9a-fA-F]{40}$"#)
                    }
                    if !mutable.isEmpty { findings.append(CheckSupport.finding(context, "ci.mutableActions", path, "Actions references are mutable",
                        "External actions or reusable workflows lack immutable commit hashes: " + Set(mutable).sorted().joined(separator: ", "), .ci, "lock.shield")) }
                }
                return findings
            }),
            CheckSupport.check("ci.suppressedFailures", "Validation failures are suppressed", .ci, "exclamationmark.shield", inspect: { context, _ in
                var findings: [RepositoryFinding] = []
                for (path, source) in try CheckSupport.applicableWorkflows(context) {
                    var evidence: [String] = []
                    for step in try context.workflowSteps(path) {
                        let command = step.commands.joined(separator: "\n")
                        guard WorkflowCoverage.validationCommand(command) else { continue }
                        if step.toleratesFailure || CheckSupport.matches(command, #"(?:\|\|\s*(?:true\b|exit\s+0\b)|set\s+\+e\b|(?:^|[;\n])\s*exit\s+0\b)"#) {
                            evidence.append("\(step.label) runs validation while allowing a failure. Review whether this is an intentional optional diagnostic.")
                        }
                    }
                    if !evidence.isEmpty { findings.append(CheckSupport.finding(context, "ci.suppressedFailures", path, "Validation failures are suppressed", evidence.joined(separator: "\n"), .ci, "exclamationmark.shield")) }
                }
                return findings
            })
        ]
    }
}

/// A structural reader for block-form Actions jobs and steps; it never executes YAML or scripts.
/// Unsupported flow jobs, anchors, or conditional failure/working-directory settings stay unknown.
enum WorkflowInspection {
    struct Line {
        let indent: Int
        let text: String
        var field: String {
            String(text.split(separator: ":", maxSplits: 1).first ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "- \"'"))
        }
        var value: String {
            guard let colon = text.firstIndex(of: ":") else { return "" }
            return String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
    }
    struct Step {
        let job: String
        let label: String
        let commands: [String]
        let workingDirectory: String?
        let toleratesFailure: Bool
        let uses: String?
        let inputs: [String: String]
        let conditional: Bool
        var shell: String? = nil
    }
    static func isCurrentRepositoryCheckout(_ step: Step, repository: String?) -> Bool {
        let declared = step.inputs["repository"]
        let same = declared == nil || declared == "${{ github.repository }}" ||
            (repository != nil && declared?.lowercased() == repository?.lowercased())
        let ref = step.inputs["ref"]
        return same && (ref == nil || ref == "" || ref == "${{ github.sha }}") &&
            step.inputs["sparse-checkout"] == nil && !step.conditional
    }
    static func lines(_ source: String) throws -> [Line] {
        var lines: [Line] = [], scalarIndent: Int?
        for raw in source.components(separatedBy: .newlines) {
            let text = InspectionConfig.withoutComment(raw)
            guard !text.isEmpty else { continue }
            let indent = raw.prefix { $0 == " " }.count
            if let scalar = scalarIndent, indent <= scalar { scalarIndent = nil }
            if scalarIndent == nil {
                guard !raw.prefix(while: { $0.isWhitespace }).contains("\t"),
                      !CheckSupport.matches(text, #"^(?:<<:|[^:]+:\s*[&*])"#) else {
                    throw InspectionError.blocked("Workflow YAML anchors or tabs require manual review.")
                }
            }
            let line = Line(indent: indent, text: text)
            lines.append(line)
            if scalarIndent == nil, line.value.hasPrefix("|") || line.value.hasPrefix(">") { scalarIndent = indent }
        }
        guard let jobs = lines.first(where: { $0.indent == 0 && $0.field == "jobs" }), jobs.value.isEmpty || jobs.value == "{}" else {
            throw InspectionError.blocked("Workflow jobs need supported block YAML.")
        }
        return lines
    }
    static func block(_ lines: [Line], _ index: Int) -> [Line] {
        Array(lines.dropFirst(index + 1).prefix { $0.indent > lines[index].indent })
    }
    private static func failurePolicy(_ lines: [Line], indent: Int) throws -> Bool {
        guard let raw = lines.first(where: { $0.indent == indent && $0.field == "continue-on-error" })?.value else { return false }
        guard ["true", "false"].contains(raw) else { throw InspectionError.blocked("Conditional continue-on-error needs manual review.") }
        return raw == "true"
    }
    private static func workingDirectory(_ lines: [Line]) throws -> String? {
        guard let raw = lines.first(where: { $0.field == "working-directory" })?.value else { return nil }
        guard !raw.contains("${{"), !raw.hasPrefix("{") else { throw InspectionError.blocked("Dynamic workflow working-directory needs manual review.") }
        return InspectionConfig.scalar(raw)
    }
    static func references(_ source: String) throws -> [String] {
        return try references(lines(source))
    }
    struct ReferenceInspection { let references: [String]; let reasons: [String] }
    static func references(_ lines: [Line]) throws -> [String] {
        let inspection = referenceInspection(lines)
        guard inspection.reasons.isEmpty else { throw InspectionError.blocked(inspection.reasons.joined(separator: " ")) }
        return inspection.references
    }
    /// Retain proven literal references when another step uses unsupported syntax.
    static func referenceInspection(_ lines: [Line]) -> ReferenceInspection {
        var references: [String] = [], reasons: [String] = [], scalarIndent: Int?
        for line in lines {
            if let indent = scalarIndent {
                if line.indent > indent { continue }
                scalarIndent = nil
            }
            if line.value.hasPrefix("|") || line.value.hasPrefix(">") { scalarIndent = line.indent; continue }
            if line.field == "uses" {
                if let reference = InspectionConfig.scalar(line.value), !reference.isEmpty, !reference.contains("${{") {
                    references.append(reference)
                } else { reasons.append("Dynamic or empty action reference needs manual review.") }
            }
            if line.text.hasPrefix("- {") || (line.field == "steps" && !line.value.isEmpty && line.value != "[]") {
                reasons.append("Inline workflow steps require manual review.")
            }
        }
        return ReferenceInspection(references: references, reasons: reasons)
    }
    static func steps(_ source: String, includeInputs: Bool = false, inputKeys: Set<String>? = nil) throws -> [Step] {
        return try steps(lines(source), includeInputs: includeInputs, inputKeys: inputKeys)
    }
    static func steps(_ all: [Line], includeInputs: Bool = false, inputKeys: Set<String>? = nil, checkoutInputKeys: Set<String> = []) throws -> [Step] {
        guard let jobsIndex = all.firstIndex(where: { $0.indent == 0 && $0.field == "jobs" }) else { return [] }
        let jobs = block(all, jobsIndex)
        guard let jobIndent = jobs.first?.indent else { return [] }
        let global = Array(all.prefix(jobsIndex))
        let globalDirectory = try workingDirectory(global.filter { $0.field == "working-directory" })
        var result: [Step] = []
        for index in jobs.indices where jobs[index].indent == jobIndent {
            guard jobs[index].value.isEmpty else { throw InspectionError.blocked("Inline jobs require manual review.") }
            let job = block(jobs, index)
            let fieldIndent = job.first?.indent ?? jobIndent + 2
            let tolerates = try failurePolicy(job, indent: fieldIndent)
            guard let stepsIndex = job.firstIndex(where: { $0.indent == fieldIndent && $0.field == "steps" }) else { continue }
            guard job[stepsIndex].value.isEmpty || job[stepsIndex].value == "[]" else { throw InspectionError.blocked("Inline workflow steps require manual review.") }
            let defaults = Array(job.prefix(stepsIndex))
            let jobDirectory = try workingDirectory(defaults) ?? globalDirectory
            let lines = block(job, stepsIndex)
            guard let stepIndent = lines.first?.indent else { continue }
            var number = 0
            for start in lines.indices where lines[start].indent == stepIndent {
                guard lines[start].text.hasPrefix("- "), !lines[start].text.hasPrefix("- {") else { throw InspectionError.blocked("Unsupported workflow step syntax.") }
                number += 1
                let content = [Line(indent: stepIndent + 2, text: String(lines[start].text.dropFirst(2)))] + block(lines, start)
                let properties = content.filter { $0.indent == stepIndent + 2 }
                let label = InspectionConfig.scalar(properties.first { $0.field == "name" }?.value) ?? "\(jobs[index].field) step \(number)"
                let failure = try failurePolicy(properties, indent: stepIndent + 2) || tolerates
                var commands: [String] = []
                for runIndex in content.indices where content[runIndex].indent == stepIndent + 2 && content[runIndex].field == "run" {
                    let value = content[runIndex].value
                    if value.hasPrefix(">") { commands.append(block(content, runIndex).map(\.text).joined(separator: " ")) }
                    else if value.hasPrefix("|") { commands += block(content, runIndex).map(\.text) }
                    else { commands.append(InspectionConfig.scalar(value) ?? value) }
                }
                var inputs: [String: String] = [:]
                let uses = InspectionConfig.scalar(properties.first { $0.field == "uses" }?.value)
                let selectedKeys = uses?.lowercased().hasPrefix("actions/checkout@") == true ? inputKeys.map { $0.union(checkoutInputKeys) } : inputKeys
                if includeInputs, let withIndex = content.firstIndex(where: { $0.indent == stepIndent + 2 && $0.field == "with" }) {
                    let value = content[withIndex].value
                    let relevant = selectedKeys == nil || selectedKeys!.contains(where: { value.contains($0) })
                    guard value.isEmpty || !relevant else { throw InspectionError.blocked("Inline workflow action inputs need manual review.") }
                    let fields = block(content, withIndex).filter { $0.indent == stepIndent + 4 && (selectedKeys == nil || selectedKeys!.contains($0.field)) }
                    guard fields.allSatisfy({ !$0.value.hasPrefix("|") && !$0.value.hasPrefix(">") }) else {
                        throw InspectionError.blocked("Unsupported workflow action input syntax.")
                    }
                    for field in fields {
                        guard inputs[field.field] == nil else { throw InspectionError.blocked("Duplicate workflow action input.") }
                        inputs[field.field] = InspectionConfig.scalar(field.value)
                    }
                }
                result.append(Step(job: jobs[index].field, label: label, commands: commands, workingDirectory: try workingDirectory(properties) ?? jobDirectory,
                                   toleratesFailure: failure, uses: uses, inputs: inputs,
                                   conditional: job.contains { $0.indent == fieldIndent && $0.field == "if" } || properties.contains { $0.field == "if" },
                                   shell: InspectionConfig.scalar(properties.first { $0.field == "shell" }?.value ?? defaults.first { $0.field == "shell" }?.value ?? global.first { $0.field == "shell" }?.value)))
            }
        }
        return result
    }
}
