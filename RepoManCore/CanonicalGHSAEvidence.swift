import Foundation

/// Independent canonical range evidence; a provider disagreement is never an unaffected verdict.
enum CanonicalGHSAEvidence {
    struct Verdict: Sendable {
        let status: String
        let ranges: [String]
        let updatedAt: String?
        let reason: String?
    }
    static func inspect(_ data: Data, id: String, entry: DependencyLockInventory.Entry, at: Date) -> Verdict {
        func unknown(_ reason: String) -> Verdict { .init(status: "unavailable", ranges: [], updatedAt: nil, reason: reason) }
        guard id.hasPrefix("GHSA-"), OSVAdvisoryEvidence.validID(id), data.count < 2_097_152,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["ghsa_id"] as? String == id,
              let updated = object["updated_at"] as? String, RegistryReleaseEvidence.date(updated) != nil else {
            return unknown("Canonical GHSA identity or metadata could not be verified.")
        }
        if let raw = object["withdrawn_at"], !(raw is NSNull) {
            guard let text = raw as? String, let date = RegistryReleaseEvidence.date(text), date <= at else { return unknown("Canonical GHSA withdrawal state is unsupported.") }
            return .init(status: "disagreement", ranges: [], updatedAt: updated, reason: "OSV retains an active match but the canonical GHSA is withdrawn.")
        }
        guard let records = object["vulnerabilities"] as? [[String: Any]], !records.isEmpty, records.count <= 256 else {
            return unknown("Canonical GHSA package ranges are missing or exceed verification limits.")
        }
        var ranges: [String] = [], unsupported = false
        for record in records {
            guard let package = record["package"] as? [String: Any], let ecosystem = package["ecosystem"] as? String,
                  let name = package["name"] as? String else { unsupported = true; continue }
            let expected = entry.ecosystem == "npm" ? "npm" : "pip"
            guard ecosystem == expected, (try? DependencyLockInventory.normalizedName(name, ecosystem: entry.ecosystem)) == entry.name else { continue }
            guard let range = record["vulnerable_version_range"] as? String, !range.isEmpty, range.utf8.count <= 2_048,
                  !range.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { unsupported = true; continue }
            ranges.append(range)
        }
        guard !ranges.isEmpty else { return unknown("Canonical GHSA did not establish a range for the matched package identity.") }
        var matches = false
        for range in ranges {
            if let result = contains(entry.version, range: range, ecosystem: entry.ecosystem) { matches = matches || result }
            else { unsupported = true }
        }
        // A complete supported inclusion proves consistency even beside an unsupported alternative.
        if matches { return .init(status: "consistent", ranges: Array(Set(ranges)).sorted(), updatedAt: updated, reason: nil) }
        if unsupported { return .init(status: "unavailable", ranges: Array(Set(ranges)).sorted(), updatedAt: updated, reason: "Canonical GHSA range semantics or package entries are unsupported; the OSV finding is retained.") }
        return .init(status: "disagreement", ranges: Array(Set(ranges)).sorted(), updatedAt: updated,
                     reason: "OSV matches the locked version but complete supported canonical GHSA ranges exclude it; independent review is required.")
    }
    static func contains(_ version: String, range: String, ecosystem: String) -> Bool? {
        if ecosystem == "npm" {
            guard CheckSupport.matches(version, #"^[0-9]+\.[0-9]+\.[0-9]+$"#), let point = NPMVersionRange.parse(version) else { return nil }
            let alternatives = range.components(separatedBy: "||")
            guard alternatives.count <= 16 else { return nil }
            var unsupported = false
            for alternative in alternatives {
                let terms = alternative.components(separatedBy: ",")
                guard terms.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }), let parsed = NPMVersionRange.parse(terms.joined(separator: " ")) else { unsupported = true; continue }
                if parsed.overlaps(point) { return true }
            }
            return unsupported ? nil : false
        }
        guard ecosystem == "pypi", let candidate = pythonRelease(version) else { return nil }
        let terms = range.components(separatedBy: ",")
        guard !terms.isEmpty, terms.count <= 16 else { return nil }
        var result = true
        for term in terms {
            let matches = CheckSupport.captures(term.trimmingCharacters(in: .whitespacesAndNewlines), #"^(>=|<=|==|!=|>|<)\s*([0-9]+(?:\.[0-9]+)*)$"#)
            guard let match = matches.first, let boundary = pythonRelease(match[2]) else { return nil }
            let comparison = candidate.lexicographicallyPrecedes(boundary) ? -1 : boundary.lexicographicallyPrecedes(candidate) ? 1 : 0
            switch match[1] {
            case ">=": result = result && comparison >= 0
            case ">": result = result && comparison > 0
            case "<=": result = result && comparison <= 0
            case "<": result = result && comparison < 0
            case "==": result = result && comparison == 0
            case "!=": result = result && comparison != 0
            default: return nil
            }
        }
        return result
    }
    private static func pythonRelease(_ raw: String) -> [Int]? {
        guard raw.count <= 128, CheckSupport.matches(raw, #"^[0-9]+(?:\.[0-9]+)*$"#) else { return nil }
        let parts = raw.split(separator: "."); guard parts.count <= 8 else { return nil }
        let values = parts.compactMap { Int($0) }
        guard values.count == parts.count, values.allSatisfy({ $0 <= 1_000_000 }) else { return nil }
        return values + Array(repeating: 0, count: 8 - values.count)
    }
}

/// Fixed public advisory endpoint; no repository content, API mutation or provider output is exposed.
enum CanonicalGHSAClient {
    typealias Request = @Sendable (String, TimeInterval) async throws -> Data
    struct Response: Sendable {
        let id: String
        let data: Data?
        let reason: String?
    }
    static func read(_ id: String, timeout: TimeInterval) async throws -> Data {
        guard id.hasPrefix("GHSA-"), OSVAdvisoryEvidence.validID(id), timeout > 0 else {
            throw InspectionError.blocked("Unsupported canonical advisory request.")
        }
        return try await Task.detached(priority: .utility) {
            try GitHubCLI.run(["api", "--hostname", "github.com", "--method", "GET", "/advisories/" + id,
                               "-H", "Accept: application/vnd.github+json", "-H", "X-GitHub-Api-Version: 2026-03-10"], timeout: min(15, timeout))
        }.value
    }
    static func fetch(_ ids: Set<String>, request: @escaping Request, deadline: Date) async -> [String: Response] {
        guard ids.count <= 64 else {
            return Dictionary(uniqueKeysWithValues: ids.map { ($0, Response(id: $0, data: nil, reason: "Canonical GHSA identities exceed the 64-advisory verification limit; OSV findings are retained.")) })
        }
        let values = await RepositoryVulnerabilityChecks.boundedMap(ids.sorted()) { id -> Response in
            guard id.hasPrefix("GHSA-"), OSVAdvisoryEvidence.validID(id), let timeout = RepositoryVulnerabilityChecks.remaining(deadline) else {
                return .init(id: id, data: nil, reason: "Canonical GHSA request identity, deadline or cancellation prevents complete verification.")
            }
            do {
                let data = try await request(id, min(15, timeout))
                guard data.count < 2_097_152 else { return .init(id: id, data: nil, reason: "Canonical GHSA response exceeds verification limits; the OSV finding is retained.") }
                return .init(id: id, data: data, reason: nil)
            } catch {
                return .init(id: id, data: nil, reason: "Canonical GHSA evidence is unavailable. Check the existing gh login/API access; the OSV finding is retained.")
            }
        }
        return Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
    }
}
