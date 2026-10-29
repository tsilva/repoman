import Foundation
import CryptoKit

/// Public namespace/hosting proof precedes checksum lookups; checksum proof precedes advisory use.
enum GoPublicModuleEvidence {
    typealias Request = @Sendable (URL, TimeInterval) async throws -> Data
    struct Proof: Sendable {
        let verified: Bool
        let sourceURL: URL
        let zip: String?
        let module: String?
        let reason: String?
    }
    static func escaped(_ text: String) -> String {
        text.map { character -> String in
            character.isASCII && character.isUppercase ? "!" + character.lowercased() : String(character)
        }.joined()
    }
    static func unescaped(_ text: String) -> String? {
        var result = "", pending = false
        for character in text {
            if pending {
                guard character.isASCII && character.isLowercase else { return nil }
                result += character.uppercased(); pending = false
            } else if character == "!" { pending = true }
            else { result.append(character) }
        }
        return pending ? nil : result
    }
    static func checksumURL(_ entry: DependencyLockInventory.Entry) -> URL {
        URL(string: "https://sum.golang.org/lookup/" + escaped(entry.name) + "@" + escaped(entry.version))!
    }
    static func proxyURL(_ name: String, version: String? = nil, suffix: String = "info") -> URL {
        let path = version.map { "/@v/" + escaped($0) + "." + suffix } ?? "/@latest"
        return URL(string: "https://proxy.golang.org/cached-only/" + escaped(name) + path)!
    }
    static func repository(_ name: String) -> String? {
        guard name.hasPrefix("github.com/") else { return nil }
        let parts = name.split(separator: "/")
        guard parts.count >= 3 else { return nil }
        let value = parts[1] + "/" + parts[2]
        return GoPublicRepositoryClient.valid(String(value)) ? String(value) : nil
    }
    static func allowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil, url.fragment == nil else { return false }
        if url.host == "index.golang.org" {
            guard url.path == "/index", let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                  items.count == 3, Set(items.map(\.name)) == ["since", "limit", "include"],
                  items.first(where: { $0.name == "limit" })?.value == "2000",
                  items.first(where: { $0.name == "include" })?.value == "all",
                  let since = items.first(where: { $0.name == "since" })?.value,
                  RegistryReleaseEvidence.date(since) != nil else { return false }
            return true
        }
        guard url.query == nil else { return false }
        if url.host == "sum.golang.org", url.path.hasPrefix("/lookup/") {
            let raw = String(url.path.dropFirst("/lookup/".count))
            guard let at = raw.lastIndex(of: "@"), let name = unescaped(String(raw[..<at])),
                  let version = unescaped(String(raw[raw.index(after: at)...])),
                  GoModuleInventory.moduleName(name), GoModuleInventory.publicNamespace(name), GoModuleInventory.version(version) else { return false }
            let entry = DependencyLockInventory.Entry(ecosystem: "go", name: name, version: version, lockfile: "go.mod", source: "go", integrity: nil, tarball: nil)
            return checksumURL(entry).absoluteString == url.absoluteString
        }
        if url.host == "proxy.golang.org", url.path.hasPrefix("/cached-only/") {
            let raw = String(url.path.dropFirst("/cached-only/".count))
            if raw.hasSuffix("/@latest"), let name = unescaped(String(raw.dropLast("/@latest".count))),
               GoModuleInventory.moduleName(name), GoModuleInventory.publicNamespace(name) {
                return proxyURL(name).absoluteString == url.absoluteString
            }
            guard let boundary = raw.range(of: "/@v/"), let name = unescaped(String(raw[..<boundary.lowerBound])),
                  GoModuleInventory.moduleName(name), GoModuleInventory.publicNamespace(name) else { return false }
            let tail = String(raw[boundary.upperBound...]), suffix = tail.hasSuffix(".info") ? "info" : tail.hasSuffix(".mod") ? "mod" : ""
            guard !suffix.isEmpty, let version = unescaped(String(tail.dropLast(suffix.count + 1))), GoModuleInventory.version(version) else { return false }
            return proxyURL(name, version: version, suffix: suffix).absoluteString == url.absoluteString
        }
        return false
    }
    static func publicProof(_ entries: [DependencyLockInventory.Entry], repositories: [String: Bool],
                            request: Request, deadline: Date) async -> Proof {
        let fallback = URL(string: "https://sum.golang.org/")!
        guard let entry = entries.first, GoModuleInventory.moduleName(entry.name), GoModuleInventory.version(entry.version),
              GoModuleInventory.publicNamespace(entry.name) else {
            return .init(verified: false, sourceURL: fallback, zip: nil, module: nil, reason: "Go source is private, missing or unsupported; no public request was sent.")
        }
        let url = checksumURL(entry)
        func unknown(_ reason: String) -> Proof { .init(verified: false, sourceURL: url, zip: nil, module: nil, reason: reason) }
        guard entries.allSatisfy({ $0.ecosystem == "go" && $0.source == "go" && $0.identity == entry.identity }),
              GoModuleInventory.moduleName(entry.name), GoModuleInventory.version(entry.version),
              GoModuleInventory.publicNamespace(entry.name) else { return unknown("Go source is private or unsupported; no public request was sent.") }
        if entry.name.hasPrefix("github.com/") {
            guard let repo = repository(entry.name), repositories[repo] == true else {
                return unknown("GitHub did not prove this Go module's hosting repository public; the module was withheld from checksum, registry and advisory services.")
            }
        }
        guard let timeout = RepositoryVulnerabilityChecks.remaining(deadline) else { return unknown("Public Go identity deadline prevents complete verification.") }
        do {
            let data = try await request(url, timeout)
            let records = try checksumRecords(data, name: entry.name, version: entry.version)
            guard entries.allSatisfy({ entry in
                let hasHash = entry.integrity != nil || entry.goModIntegrity != nil
                return hasHash && (entry.integrity == nil || entry.integrity == records.zip) &&
                    (entry.goModIntegrity == nil || entry.goModIntegrity == records.module)
            }) else { return unknown("Locked Go checksums do not match the public checksum database.") }
            return .init(verified: true, sourceURL: url, zip: records.zip, module: records.module, reason: nil)
        } catch { return unknown("Public Go checksum evidence is unavailable, malformed or exceeds verification limits.") }
    }
    static func checksumRecords(_ data: Data, name: String, version: String) throws -> (zip: String?, module: String?) {
        guard data.count <= 262_144, let text = String(data: data, encoding: .utf8) else { throw failure() }
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.first, UInt64(first) != nil, let end = lines.dropFirst().firstIndex(of: ""), end > 1, end <= 3,
              lines.dropFirst(end + 1).first == "go.sum database tree" else { throw failure() }
        var zip: String?, module: String?
        for line in lines[1..<end] {
            let fields = line.split(separator: " ").map(String.init)
            guard fields.count == 3, fields[0] == name, GoModuleInventory.digest(fields[2]) else { throw failure() }
            if fields[1] == version && zip == nil { zip = fields[2] }
            else if fields[1] == version + "/go.mod" && module == nil { module = fields[2] }
            else { throw failure() }
        }
        guard zip != nil || module != nil else { throw failure() }
        return (zip, module)
    }
    static func moduleHash(_ text: String) -> String {
        let inner = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return "h1:" + Data(SHA256.hash(data: Data((inner + "  go.mod\n").utf8))).base64EncodedString()
    }
    private static func failure() -> InspectionError { .blocked("Public Go checksum records could not be bound to the requested version.") }
}

/// Existing native gh login; private/unknown GitHub module names never leave their host.
enum GoPublicRepositoryClient {
    typealias Request = @Sendable (String, TimeInterval) async throws -> Data
    static func valid(_ value: String) -> Bool {
        CheckSupport.matches(value, #"^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$"#) &&
        !value.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }
    static func read(_ repository: String, timeout: TimeInterval) async throws -> Data {
        guard valid(repository), timeout > 0 else { throw InspectionError.blocked("Unsupported GitHub public-module identity request.") }
        return try await Task.detached(priority: .utility) {
            try GitHubCLI.run(["api", "--hostname", "github.com", "--method", "GET", "/repos/" + repository,
                               "-H", "Accept: application/vnd.github+json", "-H", "X-GitHub-Api-Version: 2026-03-10"], timeout: min(15, timeout))
        }.value
    }
    static func verify(_ data: Data, repository: String) -> Bool {
        guard valid(repository), data.count <= 1_048_576,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["full_name"] as? String, name.lowercased() == repository.lowercased(),
              DependencyLockInventory.boolean(object["private"]) == false,
              object["visibility"] as? String == "public" else { return false }
        return true
    }
    static func fetch(_ entries: [DependencyLockInventory.Entry], request: @escaping Request,
                      deadline: Date) async -> [String: Bool] {
        let names = Set(entries.filter { $0.ecosystem == "go" && $0.source == "go" }.compactMap { GoPublicModuleEvidence.repository($0.name) })
        guard names.count <= 64 else { return [:] }
        let values = await RepositoryVulnerabilityChecks.boundedMap(names.sorted()) { name -> (String, Bool) in
            guard let timeout = RepositoryVulnerabilityChecks.remaining(deadline) else { return (name, false) }
            do { return (name, verify(try await request(name, min(15, timeout)), repository: name)) }
            catch { return (name, false) }
        }
        return Dictionary(uniqueKeysWithValues: values)
    }
}
