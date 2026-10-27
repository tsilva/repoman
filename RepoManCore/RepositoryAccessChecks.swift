import Foundation
import Darwin

/// Validates metadata only. Never resolves a binding, contacts a provider, or echoes values.
enum RepositoryAccessChecks {
    static func checks() -> [RepositoryCheck] {
        [
            RepositoryCheck(id: "access.configuration", title: "Service access configuration", category: .setup, symbol: "key", evaluate: { context in
                let policy = try RepositoryCheckPolicy.load(context)
                var documents: [String: Document] = [:], presentFiles = Set<String>(), reasons: [String] = []
                for path in [".access.toml", ".access.local.toml"] {
                    do {
                        if try present(context, path) {
                            presentFiles.insert(path)
                            documents[path] = try parse(context.readText(path))
                        }
                    } catch { reasons.append(path + ": Access metadata could not be fully read or parsed. Supported TOML uses bare table/key names, scalar strings and string arrays; inspect syntax and regular-file containment. Values are withheld.") }
                }
                guard !presentFiles.isEmpty || !reasons.isEmpty else { throw InspectionError.notApplicable("No repository access metadata files are present.") }
                var findings: [RepositoryFinding] = []
                if !presentFiles.contains(".access.toml"), presentFiles.contains(".access.local.toml"), reasons.isEmpty {
                    findings.append(finding(context, ".access.local.toml", "A local access file requires a shared .access.toml inventory."))
                }
                if let inventory = documents[".access.toml"] {
                    let problems = validate(inventory, local: false, declared: [])
                    if !problems.isEmpty { findings.append(finding(context, ".access.toml", problems.joined(separator: "\n"))) }
                    if let overrides = documents[".access.local.toml"] {
                        let problems = validate(overrides, local: true, declared: profileNames(inventory))
                        if !problems.isEmpty { findings.append(finding(context, ".access.local.toml", problems.joined(separator: "\n"))) }
                    }
                }
                findings = context.applyingExceptions(findings, policy: policy)
                return reasons.isEmpty ? .findings(findings) : .partial(findings, reasons.joined(separator: "\n"))
            }),
            CheckSupport.check("access.localPrivacy", "Local access file privacy", .setup, "lock", inspect: { context, _ in
                let path = ".access.local.toml"
                var problems: [String] = []
                if !(try context.gitRead(["ls-files", "-z", "--", ":(literal)" + path])).isEmpty { problems.append("Local access metadata is tracked by Git. Remove it from the index while preserving the local file.") }
                let attributes: [FileAttributeKey: Any]
                do { attributes = try FileManager.default.attributesOfItem(atPath: context.snapshot.url.appendingPathComponent(path).path) }
                catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                    if problems.isEmpty { throw InspectionError.notApplicable("No local access metadata file is present.") }
                    return [privacyFinding(context, problems.joined(separator: "\n"))]
                }
                guard attributes[.type] as? FileAttributeType == .typeRegular else {
                    problems.append("Local access metadata must be a regular owner-only file, not a directory or symbolic link.")
                    return [privacyFinding(context, problems.joined(separator: "\n"))]
                }
                if try context.gitRead(["check-ignore", "--no-index", "--", path], successfulExitCodes: [0, 1]).isEmpty {
                    problems.append("Local access metadata is not ignored by Git. Add /.access.local.toml to .gitignore.")
                }
                guard let mode = attributes[.posixPermissions] as? NSNumber, let owner = attributes[.ownerAccountID] as? NSNumber else {
                    throw InspectionError.blocked("Local access file permissions could not be inspected.")
                }
                if mode.intValue & 0o7777 != 0o600 || owner.uint32Value != geteuid() {
                    problems.append("Local access metadata must belong to the current operator and have mode 0600.")
                }
                return problems.isEmpty ? [] : [privacyFinding(context, problems.joined(separator: "\n"))]
            })
        ]
    }
    private static func present(_ context: RepositoryInspectionContext, _ path: String) throws -> Bool {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: context.snapshot.url.appendingPathComponent(path).path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw InspectionError.blocked(path + ": Access metadata must be a regular file; symbolic links are not inspected.")
            }
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return false }
    }
    private static func finding(_ context: RepositoryInspectionContext, _ subject: String, _ reason: String) -> RepositoryFinding {
        CheckSupport.finding(context, "access.configuration", subject, "Invalid service access configuration", reason, .setup, "key")
    }
    private static func privacyFinding(_ context: RepositoryInspectionContext, _ reason: String) -> RepositoryFinding {
        CheckSupport.finding(context, "access.localPrivacy", ".access.local.toml", "Local access file privacy", reason, .setup, "lock")
    }
    struct Document {
        var values: [String: String]
        var tables: Set<String>
    }
    /// Restrict recognition to bare table/key syntax. Other TOML forms stay
    /// incomplete rather than being flattened into a misleading schema pass.
    static func parse(_ source: String) throws -> Document {
        var tables = Set<String>()
        var inArray = false
        for raw in source.components(separatedBy: .newlines) {
            let line = InspectionConfig.withoutComment(raw)
            if line.isEmpty { continue }
            if !inArray && line.hasPrefix("[") {
                guard CheckSupport.matches(line, #"^\[[a-zA-Z0-9_.-]+\]$"#) else { throw unsupported() }
                let table = String(line.dropFirst().dropLast())
                guard tables.insert(table).inserted else { throw unsupported() }
            } else if !inArray {
                guard CheckSupport.matches(line, #"^[a-zA-Z0-9_-]+\s*="#) else { throw unsupported() }
                let value = line.split(separator: "=", maxSplits: 1).last.map(String.init) ?? ""
                if value.trimmingCharacters(in: .whitespaces).hasPrefix("{") { throw unsupported() }
                inArray = value.trimmingCharacters(in: .whitespaces).hasPrefix("[") && !value.trimmingCharacters(in: .whitespaces).hasSuffix("]")
            } else if line.hasSuffix("]") { inArray = false }
        }
        do { return Document(values: try InspectionConfig.toml(source, allSections: true).values, tables: tables) }
        catch { throw unsupported() }
    }
    private static func unsupported() -> InspectionError {
        .blocked("Access metadata could not be fully parsed. Supported TOML uses bare table/key names, scalar strings and string arrays; review syntax with a full TOML parser. Values are withheld.")
    }
    static func profileNames(_ document: Document) -> Set<String> {
        Set(document.tables.compactMap { table in
            let parts = table.split(separator: ".")
            return parts.count == 2 && parts[0] == "profiles" ? String(parts[1]) : nil
        })
    }
    static func validate(_ document: Document, local: Bool, declared: Set<String>) -> [String] {
        var errors: [String] = []
        func invalid(_ reason: String) { if !errors.contains(reason) { errors.append(reason) } }
        if document.values["version"] != "1" { invalid("Access metadata requires integer version = 1.") }
        let profiles = local ? declared : profileNames(document)
        if !local && profiles.isEmpty { invalid("The shared access inventory requires a nonempty profiles table.") }
        if local && !document.tables.contains(where: { $0 == "bindings" || $0.hasPrefix("bindings.") }) { invalid("Local access metadata requires a bindings table.") }
        for table in document.tables {
            let parts = table.split(separator: ".").map(String.init)
            if table == "bindings" || (!local && table == "profiles") { continue }
            guard parts.count == 2, ["profiles", "bindings"].contains(parts[0]), !(local && parts[0] == "profiles") else {
                invalid("Access metadata contains unsupported or unexpected tables."); continue
            }
            let name = parts[1], prefix = table + "."
            let fields = document.values.filter { $0.key.hasPrefix(prefix) }
            if !CheckSupport.matches(name, #"^[a-z][a-z0-9_-]*$"#) { invalid("Access profile names are invalid.") }
            if parts[0] == "profiles" {
                let expected: Set<String> = [prefix + "description", prefix + "variables"]
                if Set(fields.keys) != expected { invalid("Each profile requires exactly description and variables.") }
                if string(fields[prefix + "description"])?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { invalid("Profile descriptions must be nonempty strings.") }
                if let variables = strings(fields[prefix + "variables"]), !variables.isEmpty,
                   variables.count == Set(variables).count, variables.allSatisfy({ CheckSupport.matches($0, #"^[A-Z_][A-Z0-9_]*$"#) }) {} else {
                    invalid("Profile variables must be a nonempty list of distinct environment variable names.")
                }
            } else {
                if !profiles.contains(name) { invalid("A provider binding names an undeclared profile.") }
                let keys = ["provider", "instance", "project_id", "environment", "path"]
                if Set(fields.keys) != Set(keys.map { prefix + $0 }) { invalid("Each provider binding must contain exactly all five required fields; local bindings replace whole shared bindings.") }
                let values = Dictionary(uniqueKeysWithValues: keys.compactMap { key -> (String, String)? in
                    guard let value = string(fields[prefix + key]), !value.isEmpty else { return nil }
                    return (key, value)
                })
                if values.count != 5 { invalid("Provider binding fields must be nonempty strings.") }
                if values["provider"] != "infisical" { invalid("The access metadata provider is unsupported; version 1 supports Infisical.") }
                if let instance = values["instance"], let url = URLComponents(string: instance), url.scheme == "https",
                   url.host?.isEmpty == false, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil {} else { invalid("The provider instance must be an absolute HTTPS URL without credentials, query or fragment.") }
                if values["project_id"].flatMap(UUID.init(uuidString:)) == nil { invalid("The provider project ID must be a UUID.") }
                if !CheckSupport.matches(values["environment"] ?? "", #"^[a-z][a-z0-9-]*$"#) { invalid("The provider environment name is invalid.") }
                if !CheckSupport.matches(values["path"] ?? "", #"^(?:/|/[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*)$"#) { invalid("The provider folder path must be absolute, with no traversal or empty segments.") }
            }
        }
        for key in document.values.keys where key != "version" {
            let parts = key.split(separator: ".")
            if parts.count != 3 || !document.tables.contains(parts.dropLast().joined(separator: ".")) {
                invalid("Access metadata contains unexpected keys or unsupported structure. Credential values must never be stored in access files.")
            }
        }
        return errors.sorted()
    }
    private static func string(_ raw: String?) -> String? {
        guard let raw, raw.count >= 2 else { return nil }
        if raw.hasPrefix("'"), raw.hasSuffix("'"), !raw.dropFirst().dropLast().contains("'") { return String(raw.dropFirst().dropLast()) }
        if raw.hasPrefix("\"") { return try? JSONDecoder().decode(String.self, from: Data(raw.utf8)) }
        return nil
    }
    private static func strings(_ raw: String?) -> [String]? {
        guard let raw, raw.hasPrefix("["), raw.hasSuffix("]") else { return nil }
        let body = String(raw.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { return [] }
        // Environment names cannot contain a comma or quotes, so this bounded
        // parser accepts ordinary TOML arrays and rejects compound values.
        var parts = body.components(separatedBy: ",")
        if parts.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { parts.removeLast() }
        var values: [String] = []
        for part in parts {
            guard let value = string(part.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
            values.append(value)
        }
        return values
    }
}
