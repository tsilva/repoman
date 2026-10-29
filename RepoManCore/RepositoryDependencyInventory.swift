import Foundation
import CryptoKit
import CoreFoundation

/// Full external lock inventories. Parsing does not install packages or execute repository code.
enum DependencyLockInventory {
    struct BundleParent: Sendable, Equatable, Hashable {
        let name: String
        let version: String
        let tarball: String
        let integrity: String
        let lockfile: String
        var identity: String { "npm:" + name + "@" + version }
    }
    struct BundleOrigin: Sendable, Equatable, Hashable {
        let parent: BundleParent
        let memberPath: String
    }
    struct Entry: Sendable, Equatable {
        let ecosystem: String
        let name: String
        let version: String
        let lockfile: String
        let source: String
        let integrity: String?
        let tarball: String?
        var sourceFingerprint: String? = nil
        var bundle: BundleOrigin? = nil
        var identity: String { ecosystem + ":" + name + "@" + version }
    }
    typealias Read = (String) throws -> String
    static let lockNames: Set<String> = ["package-lock.json", "npm-shrinkwrap.json", "pnpm-lock.yaml", "uv.lock"]
    static func isLock(_ path: String) -> Bool { lockNames.contains((path as NSString).lastPathComponent) }
    static func isManifest(_ path: String) -> Bool { ["package.json", "pyproject.toml"].contains((path as NSString).lastPathComponent) }
    static func paths(_ data: Data) throws -> [String] {
        guard let text = String(data: data, encoding: .utf8) else { throw failure("Dependency input paths are not UTF-8.") }
        let result = Set(text.split(separator: "\0").map(String.init)).sorted()
        guard result.count <= 20_000, result.allSatisfy(safePath) else { throw failure("Dependency path inventory is too large or unsupported.") }
        return result
    }
    static func workingPaths(_ context: RepositoryInspectionContext, includingRequirements: Bool = false) throws -> [String] {
        let listed = try paths(GitRunner.run(["--no-optional-locks", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
                                            at: context.snapshot.url, timeout: 10, maximumOutputBytes: 2_097_152))
        return try listed.filter {
            isLock($0) || isManifest($0) || $0 == ".repoman.json" || ($0 as NSString).lastPathComponent == "pnpm-workspace.yaml" ||
                (includingRequirements && ($0 as NSString).lastPathComponent == "requirements.txt")
        }.filter { try context.exists($0) }
    }

    static func parse(_ text: String, path: String, read: Read) throws -> [Entry] {
        guard text.utf8.count <= 1_048_576 else { throw failure("Lockfile exceeds the 1 MiB comparison limit.") }
        switch (path as NSString).lastPathComponent {
        case "package-lock.json", "npm-shrinkwrap.json": return try npm(text, path: path, read: read)
        case "pnpm-lock.yaml": return try pnpm(text, path: path)
        case "uv.lock": return try uv(text, path: path, read: read)
        default: throw failure("Unsupported lockfile format.")
        }
    }
    static func safePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") &&
        path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." } &&
        !path.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }
    static func boolean(_ raw: Any?) -> Bool? {
        guard let value = raw as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }
    static func normalizedName(_ raw: String, ecosystem: String) throws -> String {
        guard raw.count <= 214 else { throw failure("Dependency name exceeds the comparison limit.") }
        if ecosystem == "npm" {
            guard CheckSupport.matches(raw, #"^(?:@[A-Za-z0-9_~.-]+/)?[A-Za-z0-9_~.-]+$"#) else { throw failure("Unsupported npm package identity.") }
            return raw
        }
        guard CheckSupport.matches(raw, #"^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?$"#) else { throw failure("Unsupported Python package identity.") }
        return raw.lowercased().replacingOccurrences(of: "[-_.]+", with: "-", options: .regularExpression)
    }
    private static func entry(_ name: String, _ version: String, ecosystem: String, path: String,
                              source: String, integrity: String? = nil, tarball: String? = nil, sourceToken: String? = nil) throws -> Entry {
        let valid = ecosystem == "npm" ? #"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$"# : #"^[A-Za-z0-9][A-Za-z0-9.!+_-]*$"#
        guard version.count <= 128, CheckSupport.matches(version, valid) else { throw failure("Dependency does not have a supported exact version.") }
        var value = Entry(ecosystem: ecosystem, name: try normalizedName(name, ecosystem: ecosystem), version: version,
                          lockfile: path, source: source, integrity: integrity, tarball: tarball)
        if source == "unsupported", let sourceToken {
            value.sourceFingerprint = SHA256.hash(data: Data(sourceToken.utf8)).map { String(format:"%02x",$0) }.joined()
        }
        return value
    }
    static func publicNPMTarball(_ raw: String) -> Bool {
        guard let url = URL(string: raw), url.scheme == "https", url.host?.lowercased() == "registry.npmjs.org",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.port == nil || url.port == 443, url.path.hasSuffix(".tgz") else { return false }
        return !url.path.contains("/../")
    }
    private static func joined(_ path: String, _ relative: String) throws -> String {
        guard relative == "." || safePath(relative) else { throw failure("External or ambiguous workspace path needs review.") }
        let directory = (path as NSString).deletingLastPathComponent
        let parts = [directory, relative == "." ? "" : relative].filter { !$0.isEmpty }
        return parts.joined(separator: "/")
    }
    private static func workspace(_ raw: String, name: String, path: String, ecosystem: String, read: Read) throws {
        let root = try joined(path, raw), manifest = root + (root.isEmpty ? "" : "/") + (ecosystem == "npm" ? "package.json" : "pyproject.toml")
        let actual: String?
        if ecosystem == "npm" {
            actual = (try JSONSerialization.jsonObject(with: Data(read(manifest).utf8)) as? [String: Any])?["name"] as? String
        } else { actual = InspectionConfig.scalar(try InspectionConfig.toml(read(manifest)).values["project.name"]) }
        guard let actual, try normalizedName(actual, ecosystem: ecosystem) == normalizedName(name, ecosystem: ecosystem) else {
            throw failure("A local workspace member could not be verified against its manifest.")
        }
    }
    private static func literals(_ raw: String?) throws -> [String] {
        guard let raw else { return [] }
        guard let values = try JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.json5Allowed]) as? [String],
              values.count <= 128 else { throw failure("Unsupported workspace member declarations.") }
        return values
    }
    private static func patternSupported(_ pattern: String) -> Bool {
        safePath(pattern) && pattern.split(separator: "/").allSatisfy { component in
            component == "*" || !component.contains(where: { "*?[]{}".contains($0) })
        }
    }
    private static func memberMatches(_ path: String, _ patterns: [String]) -> Bool {
        let parts = path.split(separator: "/")
        return patterns.contains { pattern in
            guard patternSupported(pattern) else { return false }
            let wanted = pattern.split(separator: "/")
            return parts.count == wanted.count && zip(parts, wanted).allSatisfy { $0 == $1 || $1 == "*" }
        }
    }
    private static func npm(_ text: String, path: String, read: Read) throws -> [Entry] {
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let schema = object["lockfileVersion"] as? Int, [2, 3].contains(schema),
              let packages = object["packages"] as? [String: [String: Any]] else { throw failure("Comparison supports npm lockfile v2/v3 packages maps.") }
        var result: [Entry] = []
        for (location, item) in packages.sorted(by: { $0.key < $1.key }) where location.contains("node_modules/") {
            guard safePath(location), let marker = location.range(of: "node_modules/", options: .backwards) else { throw failure("Unsupported npm package location.") }
            let inferred = String(location[marker.upperBound...])
            if let raw = item["link"], boolean(raw) == nil { throw failure("npm workspace link markers must be JSON booleans.") }
            if boolean(item["link"]) == true {
                guard let target = item["resolved"] as? String, let member = packages[target] else {
                    throw failure("Unverified npm workspace link needs review.")
                }
                let prefix = (path as NSString).deletingLastPathComponent
                let rootManifest = (prefix.isEmpty ? "" : prefix + "/") + "package.json"
                guard let root = try JSONSerialization.jsonObject(with: Data(read(rootManifest).utf8)) as? [String: Any],
                      let members = root["workspaces"] as? [String], members.count <= 128, memberMatches(target, members) else {
                    throw failure("A local npm link is not a verified declared workspace member.")
                }
                try workspace(target, name: member["name"] as? String ?? inferred, path: path, ecosystem: "npm", read: read)
                continue
            }
            guard let version = item["version"] as? String else { throw failure("npm lock entry lacks an exact version.") }
            let resolved = item["resolved"] as? String
            let publicSource = resolved.map(publicNPMTarball) == true
            var value = try entry(item["name"] as? String ?? inferred, version, ecosystem: "npm", path: path,
                                  source: publicSource ? "npm" : "unsupported", integrity: item["integrity"] as? String,
                                  tarball: publicSource ? resolved : nil, sourceToken: (resolved ?? "missing-resolved") + "\n" + (item["integrity"] as? String ?? "missing-integrity"))
            // A bundle marker alone is not public provenance. Preserve a narrow candidate for
            // the advisory check to verify against the parent's registry metadata and archive.
            if !publicSource, item["resolved"] == nil, item["integrity"] == nil, boolean(item["inBundle"]) == true,
               value.name == inferred {
                let parentLocation = String(location[..<marker.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if let parent = packages[parentLocation], let parentMarker = parentLocation.range(of: "node_modules/", options: .backwards),
                   let parentVersion = parent["version"] as? String, let tarball = parent["resolved"] as? String, publicNPMTarball(tarball),
                   let integrity = parent["integrity"] as? String,
                   let declared = parent["bundleDependencies"] as? [String], declared.count <= 256, declared.contains(inferred),
                   let parentEntry = try? entry(parent["name"] as? String ?? String(parentLocation[parentMarker.upperBound...]), parentVersion,
                                                ecosystem: "npm", path: path, source: "npm", integrity: integrity, tarball: tarball) {
                    value.bundle = .init(parent: .init(name: parentEntry.name, version: parentEntry.version, tarball: tarball, integrity: integrity, lockfile: path),
                                         memberPath: "package/node_modules/" + inferred + "/package.json")
                    value.sourceFingerprint = SHA256.hash(data: Data((parentEntry.identity + "\n" + tarball + "\n" + integrity).utf8)).map { String(format: "%02x", $0) }.joined()
                }
            }
            result.append(value)
        }
        return result
    }
    private static func pnpm(_ text: String, path: String) throws -> [Entry] {
        // Reuse the shared YAML validator; block boundaries preserve dots inside package names/versions.
        let config = try InspectionConfig.yaml(text).values
        guard InspectionConfig.scalar(config["lockfileVersion"]) == "9.0", let packages = config["packages"], packages.isEmpty || packages == "{}" else {
            throw failure("Comparison supports pnpm v9 block-form packages maps.")
        }
        if packages == "{}" { return [] }
        let lines = text.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0.hasPrefix("packages:") && InspectionConfig.withoutComment($0) == "packages:" }) else {
            throw failure("Unsupported pnpm packages table.")
        }
        let tail = lines.dropFirst(start + 1)
        let section = Array(tail.prefix { $0.trimmingCharacters(in: .whitespaces).isEmpty || $0.hasPrefix(" ") || $0.hasPrefix("#") })
        let indices = section.indices.filter { index in
            let line = section[index]
            return line.hasPrefix("  ") && !line.hasPrefix("   ") && !InspectionConfig.withoutComment(line).isEmpty
        }
        var result: [Entry] = []
        for (offset, index) in indices.enumerated() {
            let line = InspectionConfig.withoutComment(section[index])
            guard line.hasSuffix(":"), let key = InspectionConfig.scalar(String(line.dropLast())) else { throw failure("Unsupported inline pnpm package metadata.") }
            let identity = key.components(separatedBy: "(")[0]
            guard let separator = identity.lastIndex(of: "@") else { throw failure("Unsupported pnpm package identity.") }
            let name = String(identity[..<separator]), version = String(identity[identity.index(after: separator)...])
            let end = offset + 1 < indices.count ? indices[offset + 1] : section.count
            let body = try InspectionConfig.yaml(section[(index + 1)..<end].joined(separator: "\n")).values
            let raw = body["resolution"] ?? ""
            let inline = CheckSupport.captures(raw, #"(?:^\{|,)\s*integrity\s*:\s*([^,}]+)"#)
            let integrity = InspectionConfig.scalar(body["resolution.integrity"]) ?? inline.first.flatMap { InspectionConfig.scalar($0[1]) }
            let onlyIntegrity = CheckSupport.matches(raw, #"^\{\s*integrity\s*:\s*[^,}]+\s*\}$"#) ||
                (raw.isEmpty && Set(body.keys.filter { $0.hasPrefix("resolution.") }) == ["resolution.integrity"])
            guard inline.count <= 1 else { throw failure("Duplicate pnpm resolution integrity.") }
            result.append(try entry(name, version, ecosystem: "npm", path: path,
                                    source: onlyIntegrity && integrity?.isEmpty == false ? "npm" : "unsupported", integrity: integrity,
                                    sourceToken: raw + "\n" + body.keys.filter { $0.hasPrefix("resolution.") }.sorted().map { $0 + "=" + body[$0]! }.joined(separator:"\n")))
        }
        guard !indices.isEmpty else { throw failure("pnpm package inventory is empty or unsupported; use an explicit empty packages map.") }
        return result
    }
    private static func uv(_ text: String, path: String, read: Read) throws -> [Entry] {
        let regex = try NSRegularExpression(pattern: #"(?m)^\[\[package\]\][ \t]*(?:#[^\n]*)?\r?$"#)
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty, let first = matches.first, let range = Range(first.range, in: text) else { throw failure("uv package inventory is missing.") }
        let header = try InspectionConfig.toml(String(text[..<range.lowerBound]), allSections: true).values
        guard InspectionConfig.scalar(header["version"]) == "1" else { throw failure("Comparison supports uv lockfile v1.") }
        var result: [Entry] = []
        for (index, match) in matches.enumerated() {
            guard let span = Range(match.range, in: text) else { throw failure("Invalid uv table boundary.") }
            let end = index + 1 < matches.count ? Range(matches[index + 1].range, in: text)!.lowerBound : text.endIndex
            let values = try InspectionConfig.toml(String(text[span.upperBound..<end]), allSections: true).values
            guard let name = InspectionConfig.scalar(values["name"]), let source = values["source"] else { throw failure("uv package source or name is missing.") }
            let location = CheckSupport.captures(source, #"^\{\s*(registry|editable|virtual)\s*=\s*["']([^"']+)["']\s*\}$"#).first
            if let location, ["editable", "virtual"].contains(location[1]) {
                if location[2] != "." {
                    let prefix = (path as NSString).deletingLastPathComponent
                    let project = try InspectionConfig.toml(read((prefix.isEmpty ? "" : prefix + "/") + "pyproject.toml")).values
                    let names = try literals(header["manifest.members"]).map { try normalizedName($0, ecosystem: "pypi") }
                    let patterns = try literals(project["tool.uv.workspace.members"]), excluded = try literals(project["tool.uv.workspace.exclude"])
                    guard names.contains(try normalizedName(name, ecosystem: "pypi")), memberMatches(location[2], patterns),
                          excluded.allSatisfy(patternSupported), !memberMatches(location[2], excluded) else {
                        throw failure("A local uv package is not a verified declared workspace member.")
                    }
                }
                try workspace(location[2], name: name, path: path, ecosystem: "pypi", read: read)
                continue
            }
            guard let version = InspectionConfig.scalar(values["version"]) else { throw failure("uv external dependency lacks an exact version.") }
            let registry = location?[2]
            let supported = location?[1] == "registry" && ["https://pypi.org/simple", "https://pypi.org/simple/"].contains(registry ?? "")
            result.append(try entry(name, version, ecosystem: "pypi", path: path, source: supported ? "pypi" : "unsupported", sourceToken: source))
        }
        return result
    }
    private static func failure(_ message: String) -> InspectionError { .blocked(message) }
}
