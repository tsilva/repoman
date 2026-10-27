import Foundation

/// Static native-project inspection. Never evaluates Package.swift, resolves packages or runs Xcode.
enum RepositorySwiftChecks {
    private struct Requirement { let location: String; let kind: String; let value: String; var upper: String? = nil }
    private struct Manifest {
        var requirements: [Requirement] = []
        var paths: [(String, Bool)] = []
        var leaf = false
    }
    static func checks() -> [RepositoryCheck] {
        [RepositoryCheck(id: "dependencies.swiftResolution", title: "Swift package resolution", category: .setup, symbol: "shippingbox", evaluate: {
            try evaluate($0, references: false)
        }), RepositoryCheck(id: "files.swiftProjectReferences", title: "Swift and Xcode references", category: .setup, symbol: "link", evaluate: {
            try evaluate($0, references: true)
        })]
    }
    private static func inputs(_ context: RepositoryInspectionContext) throws -> [String] {
        var paths = try context.trackedPaths(matching: [":(glob)**/Package.swift", ":(glob)**/*.xcodeproj/project.pbxproj"])
        let files = try CheckSupport.rootFiles(context)
        if files.contains("Package.swift") { paths.append("Package.swift") }
        paths += files.filter { $0.hasSuffix(".xcodeproj") }.map { $0 + "/project.pbxproj" }
        paths = Set(paths.filter { !$0.split(separator: "/").contains(where: { [".build", "DerivedData", "vendor", "node_modules"].contains(String($0)) }) }).sorted()
        guard paths.count <= 64 else { throw InspectionError.blocked("More than 64 native manifests need inspection.") }
        return paths
    }
    private static func evaluate(_ context: RepositoryInspectionContext, references: Bool) throws -> RepositoryCheckResult {
        let policy = try RepositoryCheckPolicy.load(context)
        let paths = try inputs(context)
        guard !paths.isEmpty else { return .notApplicable("No Swift package or Xcode project manifests were found.") }
        let id = references ? "files.swiftProjectReferences" : "dependencies.swiftResolution"
        var findings: [RepositoryFinding] = [], reasons: [String] = []
        var applicable = references, failures = 0
        for path in paths {
            do {
                let native = path.hasSuffix("Package.swift") ? try package(context, path) : try project(context, path)
                if references {
                    var visitedTargets = Set<String>()
                    for (target, packageRoot) in native.paths {
                        let actual = packageRoot ? target + "/Package.swift" : target
                        guard visitedTargets.insert(actual).inserted else { continue }
                        if !(try context.localTargetExists(actual)) {
                            findings.append(CheckSupport.finding(context, id, path + "#" + actual, "Native project reference is missing", "\(path) references missing local path \(actual).", .setup, "link"))
                        }
                    }
                } else if !native.requirements.isEmpty {
                    let lock: String
                    if path.hasSuffix("Package.swift") { lock = beside(path, "Package.resolved") }
                    else { lock = (path as NSString).deletingLastPathComponent + "/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" }
                    if !(try context.exists(lock)) {
                        if native.leaf {
                            if path.hasSuffix("project.pbxproj"), try context.filenames(in: parentProject(path)).contains(where: { $0.hasSuffix(".xcworkspace") }) {
                                throw InspectionError.blocked("An external workspace may own resolution; select and review its Package.resolved separately.")
                            }
                            applicable = true
                            findings.append(CheckSupport.finding(context, id, path, "Swift resolution file is missing", "\(path) declares external packages for a leaf app/executable but \(lock) is missing. Resolve with the repository's normal tooling and commit the resulting file.", .setup, "shippingbox"))
                        }
                        continue
                    }
                    applicable = true
                    if !(try context.isTracked(lock)) {
                        findings.append(CheckSupport.finding(context, id, lock, "Swift resolution is not tracked", "Commit \(lock) so supported leaf builds share the resolved revisions.", .setup, "shippingbox"))
                    }
                    let object = try context.jsonObject(lock)
                    guard let version = object["version"] as? Int, [1, 2, 3].contains(version),
                          let pins = object["pins"] as? [[String: Any]] ?? (object["object"] as? [String: Any])?["pins"] as? [[String: Any]], pins.count <= 512 else {
                        throw InspectionError.blocked("Unsupported Swift resolution schema in " + lock)
                    }
                    for requirement in native.requirements {
                        let matches = try pins.filter { pin in
                            guard let location = pin["location"] as? String ?? pin["repositoryURL"] as? String else { throw InspectionError.blocked("Swift pin has no supported location.") }
                            return try normalized(location) == normalized(requirement.location)
                        }
                        guard matches.count <= 1 else { throw InspectionError.blocked("Duplicate native package pins in " + lock) }
                        var agrees = false
                        if let pin = matches.first, let state = pin["state"] as? [String: Any], let revision = state["revision"] as? String,
                           CheckSupport.matches(revision, #"^(?:[a-fA-F0-9]{40}|[a-fA-F0-9]{64})$"#) {
                            agrees = try satisfies(requirement, state: state)
                        }
                        if !agrees {
                            findings.append(CheckSupport.finding(context, id, path + "#" + identity(requirement.location), "Swift declaration and resolution disagree", "\(lock) has no matching valid revision satisfying a declared package in \(path). Package identity: \(identity(requirement.location)). Review the manifest and regenerate the lock with repository tooling.", .setup, "shippingbox"))
                        }
                    }
                }
            } catch {
                failures += 1
                if reasons.count < 5 { reasons.append(path + ": Native inputs could not be fully inspected. " + ((error as? InspectionError)?.localizedDescription ?? "Check file readability and supported syntax.")) }
            }
        }
        findings = context.applyingExceptions(findings, policy: policy)
        if failures > 0 { return .partial(findings, reasons.joined(separator: "\n") + (failures > reasons.count ? "\nAdditional native inputs could not be inspected." : "")) }
        return applicable ? .findings(findings) : .notApplicable("Native manifests declare no external packages needing a leaf resolution file. Library-only packages do not impose a lockfile on consumers.")
    }
    private static func beside(_ path: String, _ target: String) -> String {
        let directory = (path as NSString).deletingLastPathComponent
        return directory.isEmpty ? target : directory + "/" + target
    }
    private static func parentProject(_ path: String) -> String {
        let directory = ((path as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        return directory.isEmpty ? "." : directory
    }
    private static func identity(_ location: String) -> String {
        let name = (location.split(separator: "/").last.map(String.init) ?? "package").replacingOccurrences(of: ".git", with: "")
        return CheckSupport.matches(name, #"^[A-Za-z0-9_.-]{1,100}$"#) ? name : "package"
    }
    private static func normalized(_ location: String) throws -> String {
        var value = location
        if value.hasPrefix("git@"), let colon = value.firstIndex(of: ":") { value = "ssh://" + value[..<colon] + "/" + value[value.index(after: colon)...] }
        guard let url = URL(string: value), let host = url.host, url.query == nil, url.fragment == nil, ["https", "http", "ssh", "git"].contains(url.scheme ?? "") else { throw InspectionError.blocked("Unsupported native package location.") }
        var path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix(".git") { path = String(path.dropLast(4)) }
        if host.lowercased() == "github.com" { path = path.lowercased() }
        return host.lowercased() + "/" + path
    }
    private static func satisfies(_ requirement: Requirement, state: [String: Any]) throws -> Bool {
        switch requirement.kind {
        case "revision":
            guard CheckSupport.matches(requirement.value, #"^[a-fA-F0-9]{7,64}$"#) else { throw InspectionError.blocked("Symbolic Swift revisions need manual resolution review.") }
            return (state["revision"] as? String)?.lowercased().hasPrefix(requirement.value.lowercased()) == true
        case "branch": return state["branch"] as? String == requirement.value
        default:
            guard let declared = version(requirement.value) else { throw InspectionError.blocked("Native version constraint needs manual review.") }
            guard let raw = state["version"] as? String, let resolved = version(raw) else { throw InspectionError.blocked("Native pin needs a supported stable semantic version.") }
            switch requirement.kind {
            case "exact": return resolved == declared
            case "major": return !resolved.lexicographicallyPrecedes(declared) && resolved.lexicographicallyPrecedes([declared[0] + 1, 0, 0])
            case "minor": return !resolved.lexicographicallyPrecedes(declared) && resolved.lexicographicallyPrecedes([declared[0], declared[1] + 1, 0])
            case "range", "closedRange":
                guard let upper = requirement.upper.flatMap(version) else { throw InspectionError.blocked("Unsupported native version range.") }
                return !resolved.lexicographicallyPrecedes(declared) && (resolved.lexicographicallyPrecedes(upper) || requirement.kind == "closedRange" && resolved == upper)
            default: throw InspectionError.blocked("Unsupported native package requirement.")
            }
        }
    }
    private static func version(_ value: String) -> [Int]? {
        guard CheckSupport.matches(value, #"^\d{1,8}\.\d{1,8}\.\d{1,8}$"#) else { return nil }
        return value.split(separator: ".").compactMap { Int($0) }
    }
    private static func package(_ context: RepositoryInspectionContext, _ path: String) throws -> Manifest {
        let fullSource = try cleanSwift(context.readText(path))
        guard let binding = fullSource.range(of: #"(?m)^(?:let|var)\s+package(?:\s*:\s*Package)?\s*=\s*Package\s*\("#, options: .regularExpression) else {
            throw InspectionError.blocked("A literal top-level package binding is required for static Swift inspection.")
        }
        let source = "Package(" + (try callContents(fullSource, from: binding.upperBound)) + ")"
        guard !fullSource.contains("#if"), !source.contains("\\("), !source.contains("\"\"\""),
              !CheckSupport.matches(fullSource, #"\.dependencies\s*(?:=|\+=|\.append)"#),
              CheckSupport.captures(source, #"\b(?:dependencies|products|targets)\s*:\s*([^\s])"#).allSatisfy({ $0[1] == "[" }) else {
            throw InspectionError.blocked("Computed or conditional Package.swift declarations need manual review; the manifest was not executed.")
        }
        var manifest = Manifest(leaf: CheckSupport.matches(source, #"\.executable(?:Target)?\s*\("#))
        for match in CheckSupport.captures(source, #"\bpath\s*:\s*\"([^\"\\]*)\""#) { manifest.paths.append((beside(path, match[1]), false)) }
        let regex = try NSRegularExpression(pattern: #"\.package\s*\("#)
        let matches = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
        guard matches.count <= 64 else { throw InspectionError.blocked("Too many declared Swift packages.") }
        for match in matches {
            let end = source.index(source.startIndex, offsetBy: (source as NSString).substring(to: match.range.location + match.range.length).count)
            let call = try callContents(source, from: end)
            if let local = CheckSupport.captures(call, #"\bpath\s*:\s*\"([^\"\\]*)\""#).first?[1] { manifest.paths.append((beside(path, local), true)); continue }
            guard let url = CheckSupport.captures(call, #"\burl\s*:\s*\"([^\"\\]*)\""#).first?[1] else { throw InspectionError.blocked("Swift package URLs must be supported literal strings.") }
            _ = try normalized(url)
            var found: Requirement?
            for (kind, pattern) in [("exact", #"(?:exact\s*:|\.exact\s*\()\s*\"([^\"\\]+)\""#), ("branch", #"(?:branch\s*:|\.branch\s*\()\s*\"([^\"\\]+)\""#), ("revision", #"(?:revision\s*:|\.revision\s*\()\s*\"([^\"\\]+)\""#), ("minor", #"\.upToNextMinor\s*\(\s*from\s*:\s*\"([^\"\\]+)\""#), ("major", #"\bfrom\s*:\s*\"([^\"\\]+)\""#)] {
                if let value = CheckSupport.captures(call, pattern).first?[1] { found = Requirement(location: url, kind: kind, value: value); break }
            }
            if found == nil, let range = CheckSupport.captures(call, #"\"([^\"\\]+)\"\s*(\.\.<|\.\.\.)\s*\"([^\"\\]+)\""#).first { found = Requirement(location: url, kind: range[2] == "..<" ? "range" : "closedRange", value: range[1], upper: range[3]) }
            guard let found else { throw InspectionError.blocked("Unsupported or computed Swift dependency requirement.") }
            manifest.requirements.append(found)
        }
        return manifest
    }
    private static func callContents(_ source: String, from start: String.Index) throws -> String {
        var depth = 1, quoted = false, escaped = false
        for index in source.indices[start...] {
            let c = source[index]
            if escaped { escaped = false; continue }
            if quoted && c == "\\" { escaped = true; continue }
            if c == "\"" { quoted.toggle(); continue }
            if !quoted {
                if c == "(" { depth += 1 }
                if c == ")" { depth -= 1; if depth == 0 { return String(source[start..<index]) } }
            }
        }
        throw InspectionError.blocked("Unbalanced Swift dependency declaration.")
    }
    private static func cleanSwift(_ source: String) throws -> String {
        let chars = Array(source); var i = 0, block = 0, line = false, quote = false, escaped = false, result = ""
        while i < chars.count {
            let c = chars[i], next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if line { if c == "\n" { line = false; result.append(c) }; i += 1; continue }
            if block > 0 {
                if c == "/" && next == "*" { block += 1; guard block <= 8 else { throw InspectionError.blocked("Swift comment nesting exceeds limits.") }; i += 2 }
                else if c == "*" && next == "/" { block -= 1; i += 2 }
                else { if c == "\n" { result.append(c) }; i += 1 }; continue
            }
            if quote { result.append(c); if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { quote = false }; i += 1; continue }
            if c == "/" && next == "/" { line = true; i += 2; continue }
            if c == "/" && next == "*" { block = 1; result.append(" "); i += 2; continue }
            if c == "\"" { quote = true }; result.append(c); i += 1
        }
        guard block == 0, !quote else { throw InspectionError.blocked("Unterminated Swift comment or string.") }
        return result
    }
    private static func strings(_ object: [String: Any], key: String) throws -> [String] {
        guard let value = object[key] else { return [] }
        guard let strings = value as? [String], strings.count <= 20_000 else { throw InspectionError.blocked("Unsupported Xcode reference list.") }
        return strings
    }
    private static func project(_ context: RepositoryInspectionContext, _ path: String) throws -> Manifest {
        let plist = try context.propertyListObject(path)
        guard let objects = plist["objects"] as? [String: [String: Any]], objects.count <= 20_000,
              let root = plist["rootObject"] as? String, objects[root]?["isa"] as? String == "PBXProject", let main = objects[root]?["mainGroup"] as? String else { throw InspectionError.blocked("Unsupported Xcode object graph.") }
        var manifest = Manifest()
        for id in try strings(objects[root]!, key: "targets") {
            guard let object = objects[id] else { throw InspectionError.blocked("Xcode target reference is missing.") }
            if let product = object["productType"] as? String, product.contains("application") || product.contains("tool") { manifest.leaf = true }
        }
        for id in try strings(objects[root]!, key: "packageReferences") {
            guard let object = objects[id], object["isa"] as? String == "XCRemoteSwiftPackageReference" else { throw InspectionError.blocked("Unsupported or missing Xcode package reference.") }
            guard let url = object["repositoryURL"] as? String, let requirement = object["requirement"] as? [String: String], let kind = requirement["kind"] else { throw InspectionError.blocked("Unsupported Xcode package declaration.") }
            _ = try normalized(url)
            let map = ["upToNextMajorVersion": ("major", "minimumVersion"), "upToNextMinorVersion": ("minor", "minimumVersion"), "exactVersion": ("exact", "version"), "branch": ("branch", "branch"), "revision": ("revision", "revision"), "versionRange": ("range", "minimumVersion")]
            guard let mapped = map[kind], let value = requirement[mapped.1] else { throw InspectionError.blocked("Unsupported Xcode version requirement.") }
            manifest.requirements.append(Requirement(location: url, kind: mapped.0, value: value, upper: requirement["maximumVersion"]))
        }
        var visiting = Set<String>(), visits = 0
        func walk(_ id: String, base: String, depth: Int) throws {
            visits += 1
            guard depth <= 32, visits <= 20_000, !visiting.contains(id), let object = objects[id], let kind = object["isa"] as? String else { throw InspectionError.blocked("Invalid, cyclic or excessive Xcode references.") }
            visiting.insert(id); defer { visiting.remove(id) }
            guard object["sourceTree"] == nil || object["sourceTree"] is String, object["path"] == nil || object["path"] is String else { throw InspectionError.blocked("Malformed Xcode source path.") }
            let tree = object["sourceTree"] as? String ?? "<group>"
            if ["SDKROOT", "BUILT_PRODUCTS_DIR", "DEVELOPER_DIR", "DERIVED_FILE_DIR"].contains(tree) { return }
            guard ["<group>", "SOURCE_ROOT"].contains(tree) else { throw InspectionError.blocked("Unsupported Xcode source-tree variable.") }
            let value = object["path"] as? String ?? (kind == "PBXFileReference" ? object["name"] as? String : nil)
            if let value, value.hasPrefix("/") || value.contains("$(") || value.contains("${") { throw InspectionError.blocked("Absolute or dynamic Xcode file reference needs review.") }
            let parent = tree == "SOURCE_ROOT" ? parentProject(path) : base
            let target = value.map { parent == "." ? $0 : parent + "/" + $0 } ?? parent
            if kind == "PBXFileReference" { guard value != nil else { throw InspectionError.blocked("Xcode file reference has no supported path.") }; manifest.paths.append((target, false)); return }
            if ["PBXGroup", "PBXVariantGroup", "PBXFileSystemSynchronizedRootGroup"].contains(kind) {
                if kind == "PBXFileSystemSynchronizedRootGroup", value != nil { manifest.paths.append((target, false)) }
                for child in try strings(object, key: "children") { try walk(child, base: target, depth: depth + 1) }
                return
            }
            throw InspectionError.blocked("Unsupported Xcode group reference type.")
        }
        try walk(main, base: parentProject(path), depth: 0)
        return manifest
    }
}
