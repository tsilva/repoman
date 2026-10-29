import Foundation
import CryptoKit

/// Selected module versions come from offline native Go metadata, never all historical sums.
enum GoModuleInventory {
    typealias Request = @Sendable (String, String, URL, TimeInterval) throws -> Data
    struct Result: Sendable {
        var entries: [DependencyLockInventory.Entry] = []
        var reasons: [String] = []
    }
    static let names: Set<String> = ["go.mod", "go.sum", "go.work", "go.work.sum"]
    static func isInput(_ path: String) -> Bool { names.contains((path as NSString).lastPathComponent) }
    static func isModule(_ path: String) -> Bool { (path as NSString).lastPathComponent == "go.mod" }
    static func moduleName(_ value: String) -> Bool {
        value.utf8.count <= 500 && value.split(separator: "/").count <= 32 &&
        CheckSupport.matches(value, #"^[A-Za-z0-9][A-Za-z0-9.-]*(?:/[A-Za-z0-9._~-]+)*$"#) &&
        value.contains(".") && value.split(separator: "/").allSatisfy { $0 != "." && $0 != ".." && !$0.hasSuffix(".") }
    }
    static func version(_ value: String) -> Bool {
        value.count <= 128 && CheckSupport.matches(value, #"^v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?(?:\+incompatible)?$"#)
    }
    static func digest(_ value: String) -> Bool {
        value.hasPrefix("h1:") && Data(base64Encoded: String(value.dropFirst(3)))?.count == 32
    }
    static func publicNamespace(_ name: String) -> Bool {
        ["golang.org/x/", "google.golang.org/", "cloud.google.com/go", "go.opentelemetry.io/", "go.opencensus.io/", "gopkg.in/", "github.com/"].contains {
            name == $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) || name.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/")
        }
    }
    static func capture(paths: [String], root: URL, read: DependencyLockInventory.Read,
                        request: Request = { try GoModuleClient.read($0, $1, $2, $3) },
                        deadline: Date = Date().addingTimeInterval(30)) -> Result {
        let modules = paths.filter(isModule).sorted()
        guard !modules.isEmpty else {
            return .init(reasons: paths.contains(where: { isInput($0) }) ? ["Go input files have no corresponding go.mod; selected module coverage is unknown."] : [])
        }
        guard modules.count <= 16 else { return .init(reasons: ["Go modules exceed the 16-component metadata limit."]) }
        if hasWorkspace(paths: paths, root: root) {
            return .init(reasons: ["Go workspaces are unsupported; no workspace graph or historical sum inventory was assumed."])
        }
        var result = Result()
        for path in modules {
            guard Date() < deadline, !Task.isCancelled else {
                result.reasons.append(path + ": Go metadata deadline or cancellation prevents complete selected-module evidence."); continue
            }
            do {
                let text = try read(path)
                guard text.utf8.count <= 1_048_576, !CheckSupport.matches(text, #"(?m)^[ \t]*(?:replace|exclude)[ \t(]"#) else {
                    throw failure("Go replacement/exclusion directives require review.")
                }
                let directory = (path as NSString).deletingLastPathComponent
                let sumPath = (directory.isEmpty ? "" : directory + "/") + "go.sum"
                let sums = paths.contains(sumPath) ? try read(sumPath) : ""
                let metadata = try request(text, sums, root, min(10, deadline.timeIntervalSinceNow))
                guard !hasWorkspace(paths: paths, root: root) else { throw failure("Go workspace changed.") }
                let entries = try parse(metadata, sums: sums, path: path)
                result.entries += entries.entries
                result.reasons += entries.reasons
            } catch {
                result.reasons.append(path + ": complete offline Go metadata is unavailable or unsupported. An installed compatible Go tool and cached graph are required; replacements, malformed inputs and missing checksums cannot establish coverage.")
            }
        }
        return result
    }
    static func hasWorkspace(paths: [String], root: URL) -> Bool {
        if paths.contains(where: { ["go.work", "go.work.sum"].contains(($0 as NSString).lastPathComponent) }) { return true }
        if let configured = ProcessInfo.processInfo.environment["GOWORK"], !configured.isEmpty, configured != "off" { return true }
        for path in paths.filter(isModule) {
            var directory = root.appendingPathComponent((path as NSString).deletingLastPathComponent).standardizedFileURL
            for _ in 0..<128 {
                let workspace = directory.appendingPathComponent("go.work").path
                if FileManager.default.fileExists(atPath: workspace) || (try? FileManager.default.destinationOfSymbolicLink(atPath: workspace)) != nil { return true }
                let parent = directory.deletingLastPathComponent()
                if parent.path == directory.path { break }
                directory = parent
            }
        }
        return false
    }
    static func parse(_ data: Data, sums text: String, path: String) throws -> Result {
        guard data.count <= 2_097_152, text.utf8.count <= 2_097_152,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["modules", "privatePatterns"],
              let modules = object["modules"] as? [[String: Any]], !modules.isEmpty, modules.count <= 2_048,
              let patterns = object["privatePatterns"] as? [String], patterns.count <= 192,
              patterns.allSatisfy({ $0.count <= 512 && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else {
            throw failure("Unsupported Go graph metadata.")
        }
        var sums: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count == 3, moduleName(fields[0]), digest(fields[2]) else { throw failure("Unsupported Go checksum record.") }
            let raw = fields[1], plain = raw.hasSuffix("/go.mod") ? String(raw.dropLast(7)) : raw
            guard version(plain) else { throw failure("Unsupported Go checksum version.") }
            let key = fields[0] + "@" + raw
            if let old = sums[key], old != fields[2] { throw failure("Conflicting Go checksums.") }
            sums[key] = fields[2]
        }
        var result = Result(), seen = Set<String>(), mains = 0
        for item in modules {
            guard item["Error"] == nil, item["Replace"] == nil, let name = item["Path"] as? String,
                  !name.isEmpty, name.utf8.count <= 500, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw failure("Go graph errors or replacements prevent complete coverage.")
            }
            if let raw = item["Main"] {
                guard let value = DependencyLockInventory.boolean(raw) else { throw failure("Unsupported Go main-module marker.") }
                if value { mains += 1; continue }
            }
            guard moduleName(name), let selected = item["Version"] as? String, version(selected),
                  seen.insert(name).inserted else { throw failure("Go selected module identity is ambiguous.") }
            let key = name + "@" + selected, zip = sums[key], mod = sums[key + "/go.mod"]
            guard zip != nil || mod != nil else { throw failure("Selected Go module has no locked checksum.") }
            for (field, expected) in [("Sum", zip), ("GoModSum", mod)] {
                if let raw = item[field] {
                    guard let value = raw as? String, value == expected else { throw failure("Go metadata and locked checksums disagree.") }
                }
            }
            let privacy = patterns.map { privateMatch(name, pattern: $0) }
            let supported = publicNamespace(name) && !privacy.contains(where: { $0 == true || $0 == nil })
            var entry = DependencyLockInventory.Entry(ecosystem: "go", name: name, version: selected, lockfile: path,
                                                       source: supported ? "go" : "unsupported", integrity: zip, tarball: nil)
            entry.goModIntegrity = mod
            if !supported {
                entry.sourceFingerprint = SHA256.hash(data: Data((name + "\n" + selected + "\n" + (zip ?? "") + "\n" + (mod ?? "")).utf8)).map { String(format: "%02x", $0) }.joined()
                result.reasons.append(path + ": a private, unknown-host or unsupported privacy-pattern module was withheld from public services.")
            }
            result.entries.append(entry)
        }
        guard mains == 1 else { throw failure("Go metadata did not establish exactly one main module.") }
        return result
    }
    /// A bounded subset of Go path.Match prefix patterns; ambiguous patterns withhold identity.
    static func privateMatch(_ name: String, pattern: String) -> Bool? {
        if pattern.isEmpty { return false }
        guard !pattern.contains(where: { "[]\\".contains($0) }),
              CheckSupport.matches(pattern, #"^[A-Za-z0-9._/*?~-]+$"#) else { return nil }
        let wanted = pattern.split(separator: "/", omittingEmptySubsequences: false)
        let actual = name.split(separator: "/")
        guard wanted.count <= actual.count, wanted.allSatisfy({ !$0.isEmpty }) else { return false }
        let prefix = actual.prefix(wanted.count).joined(separator: "/")
        let regex = "^" + pattern.map { character -> String in
            if character == "*" { return "[^/]*" }
            if character == "?" { return "[^/]" }
            return NSRegularExpression.escapedPattern(for: String(character))
        }.joined() + "$"
        return CheckSupport.matches(prefix, regex)
    }
    private static func failure(_ reason: String) -> InspectionError { .blocked(reason) }
}
