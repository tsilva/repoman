import Foundation

/// Inspects repository metadata only; never launches Runbox or reads machine approvals.
enum RepositoryAccessChecks {
    static let path = ".runbox.yaml"
    static func checks() -> [RepositoryCheck] {
        [
            RepositoryCheck(id: "access.configuration", title: "Runbox access inventory", category: .setup, symbol: "key", evaluate: { context in
                let policy = try RepositoryCheckPolicy.load(context)
                let rootFiles = try context.snapshot.rootFiles ?? FileManager.default.contentsOfDirectory(atPath: context.snapshot.url.path)
                let retired = rootFiles.filter {
                    [".access.toml", ".access.local.toml", ".keyenv.toml", ".infisical.json"].contains($0)
                    || ($0.hasPrefix(".infisical") && ($0.hasSuffix(".yaml") || $0.hasSuffix(".yml")))
                }
                var findings = retired.sorted().map {
                    finding(context, $0, "Retired access configuration remains. Review and retire this setup; never execute it or copy credentials into Runbox metadata.")
                }
                guard rootFiles.contains(path) else {
                    if !findings.isEmpty { return .findings(context.applyingExceptions(findings, policy: policy)) }
                    throw InspectionError.notApplicable("No optional root .runbox.yaml inventory is present.")
                }
                do {
                    // Reuse the existing contained, no-follow bounded regular-file reader.
                    let data = try context.readBrandingFile(path, maximumBytes: 65_536)
                    guard let source = String(data: data, encoding: .utf8) else { throw unsupported() }
                    let problems = try inventoryProblems(source)
                    if !problems.isEmpty { findings.append(finding(context, path, problems.joined(separator: "\n"))) }
                    return .findings(context.applyingExceptions(findings, policy: policy))
                } catch {
                    return .partial(context.applyingExceptions(findings, policy: policy),
                        "Runbox inventory could not be fully inspected. Require a contained regular UTF-8 file up to 64 KiB and supported block YAML inventory syntax. Values are withheld. Full execution/provider schema and machine approval checks belong to an explicitly selected external Runbox check.")
                }
            }),
            // Preserve the public check ID for saved policies and CLI callers.
            CheckSupport.check("access.localPrivacy", "Machine-local access approvals", .setup, "lock", inspect: { _, _ in
                throw InspectionError.notApplicable("Runbox machine approvals live outside the repository and are not inspected. The optional .runbox.yaml contains shareable metadata, not a private local override.")
            })
        ]
    }

    private static func finding(_ context: RepositoryInspectionContext, _ subject: String, _ reason: String) -> RepositoryFinding {
        CheckSupport.finding(context, "access.configuration", subject, "Invalid service access inventory", reason, .setup, "key")
    }
    private static func unsupported() -> InspectionError {
        .blocked("Unsupported Runbox inventory syntax; values are withheld.")
    }
    private static func identifier(_ value: String) -> Bool {
        CheckSupport.matches(value, #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$"#)
    }

    /// Read only the root version/default and names of block-mapped inventory entries.
    /// Nested execution/provider values are opaque: this is not a full YAML/schema validator.
    static func inventoryProblems(_ source: String) throws -> [String] {
        guard !source.contains("\t") else { throw unsupported() }
        var roots: Set<String> = [], entries: [String: Set<String>] = [:]
        var section: String?, entryIndent: Int?, version: String?, defaultName: String?
        var problems: Set<String> = [], started = false
        let mappings: Set<String> = ["profiles", "bindings", "brokers"]
        for raw in source.components(separatedBy: .newlines) {
            let line = InspectionConfig.withoutComment(raw, requiresSeparator: true)
            if line.isEmpty { continue }
            if line == "---", !started { started = true; continue }
            if line == "---" || line == "..." { throw unsupported() }
            started = true
            // Anchors/tags are not supported by Runbox; never resolve them here.
            if CheckSupport.matches(line, #"^(?:<<:|[^#\n]*:\s*[&*!])"#) { throw unsupported() }
            let indent = raw.prefix { $0 == " " }.count
            if indent == 0 {
                guard let colon = line.firstIndex(of: ":") else { throw unsupported() }
                let key = InspectionConfig.scalar(String(line[..<colon])) ?? ""
                guard identifier(key) else { throw unsupported() }
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                guard roots.insert(key).inserted else { throw unsupported() }
                section = nil; entryIndent = nil
                switch key {
                case "version": version = value
                case "default": defaultName = InspectionConfig.scalar(value)
                case "profiles", "bindings", "brokers":
                    entries[key] = []
                    if value.isEmpty { section = key }
                    else if value != "{}" { throw unsupported() }
                default: problems.insert("Runbox inventory contains unsupported root fields.")
                }
            } else if let section {
                if entryIndent == nil { entryIndent = indent }
                guard indent >= entryIndent! else { throw unsupported() }
                if indent == entryIndent {
                    guard let colon = line.firstIndex(of: ":") else { throw unsupported() }
                    let name = InspectionConfig.scalar(String(line[..<colon])) ?? ""
                    let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    guard identifier(name), value.isEmpty || value == "{}",
                          entries[section, default: []].insert(name).inserted else { throw unsupported() }
                }
            } else { throw unsupported() }
        }
        if version != "1" { problems.insert("Runbox metadata requires integer version: 1.") }
        if mappings.allSatisfy({ entries[$0, default: []].isEmpty }) {
            problems.insert("Runbox inventory requires named profiles, bindings or brokers.")
        }
        let profiles = entries["profiles", default: []]
        if profiles.count > 64 { problems.insert("Runbox supports at most 64 command profiles.") }
        if !profiles.isEmpty {
            if defaultName.map({ profiles.contains($0) }) != true {
                problems.insert("Runbox default must name a declared command profile.")
            }
        } else if defaultName != nil { problems.insert("A default requires a declared command profile.") }
        return problems.sorted()
    }
}
