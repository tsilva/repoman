import Foundation

/// Go commit times are never publication evidence. An old public-index observation
/// proves a minimum age; a recent observation alone cannot prove a young release.
enum GoReleaseEvidence {
    typealias Manifest = @Sendable (String, URL, TimeInterval) throws -> Data
    static func indexURL(since: Date) -> URL {
        var parts = URLComponents(string: "https://index.golang.org/index")!
        parts.queryItems = [.init(name: "since", value: RegistryReleaseEvidence.timestamp(since)),
                            .init(name: "limit", value: "2000"), .init(name: "include", value: "all")]
        return parts.url!
    }
    static func info(_ data: Data, version: String? = nil) throws -> (version: String, commit: Date) {
        guard data.count <= 262_144, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let selected = object["Version"] as? String, GoModuleInventory.version(selected),
              version == nil || selected == version, let time = object["Time"] as? String,
              let commit = RegistryReleaseEvidence.date(time) else { throw failure() }
        return (selected, commit)
    }
    static func page(_ data: Data, name: String, version: String, since: Date, at: Date) throws -> (seen: Date?, next: Date?, count: Int) {
        guard data.count <= 2_097_152, let text = String(data: data, encoding: .utf8) else { throw failure() }
        let lines = text.split(separator: "\n")
        guard lines.count <= 2_000 else { throw failure() }
        var previous = since, seen: Date?
        for line in lines {
            guard let item = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let path = item["Path"] as? String, path.utf8.count <= 1_024,
                  let selected = item["Version"] as? String, selected.utf8.count <= 256,
                  !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !selected.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  let time = item["Timestamp"] as? String, let date = RegistryReleaseEvidence.date(time),
                  date >= previous, date <= at else { throw failure() }
            previous = date
            if path == name && selected == version { seen = min(seen ?? date, date) }
        }
        return (seen, lines.isEmpty ? nil : previous, lines.count)
    }
    static func evaluate(_ entries: [DependencyLockInventory.Entry], repositories: [String: Bool], root: URL, at: Date,
                         request: @escaping GoPublicModuleEvidence.Request,
                         manifest: Manifest = { try GoModuleClient.manifest($0, excluding: $1, timeout: $2) },
                         deadline: Date) async -> RegistryReleaseEvidence.Verdict {
        let proof = await GoPublicModuleEvidence.publicProof(entries, repositories: repositories, request: request, deadline: deadline)
        guard proof.verified, let entry = entries.first else { return .init(unknownReason: proof.reason ?? "Public Go provenance is unknown.") }
        var result = RegistryReleaseEvidence.Verdict(evidenceURL: proof.sourceURL.absoluteString)
        var phase = "latest-version metadata"
        func read(_ url: URL) async throws -> Data {
            guard let remaining = RepositoryVulnerabilityChecks.remaining(deadline) else { throw failure() }
            return try await request(url, remaining)
        }
        do {
            // Use the current proxy-selected version's checksum-bound manifest for
            // retractions/deprecation, rather than trusting a version's old manifest.
            let latest = try info(await read(GoPublicModuleEvidence.proxyURL(entry.name)))
            phase = "latest-version public checksums"
            let sums = try GoPublicModuleEvidence.checksumRecords(await read(GoPublicModuleEvidence.checksumURL(
                .init(ecosystem: "go", name: entry.name, version: latest.version, lockfile: entry.lockfile, source: "go", integrity: nil, tarball: nil))), name: entry.name, version: latest.version)
            phase = "latest-version manifest provenance"
            let bytes = try await read(GoPublicModuleEvidence.proxyURL(entry.name, version: latest.version, suffix: "mod"))
            guard bytes.count <= 1_048_576, let text = String(data: bytes, encoding: .utf8),
                  GoPublicModuleEvidence.moduleHash(text) == sums.module,
                  let remaining = RepositoryVulnerabilityChecks.remaining(deadline) else { throw failure() }
            phase = "native retraction/deprecation parsing"
            result.risks = try GoVersion.risks(entry.version, module: entry.name, manifest: manifest(text, root, remaining))
            phase = "selected-version metadata"
            let selected = try info(await read(GoPublicModuleEvidence.proxyURL(entry.name, version: entry.version)), version: entry.version)
            // A cursor based on commit time only bounds the search. It grants no age.
            var cursor = selected.commit.addingTimeInterval(-1), found = false
            for _ in 0..<4 {
                phase = "public-index page evidence"
                let url = indexURL(since: cursor)
                let value = try page(await read(url), name: entry.name, version: entry.version, since: cursor, at: at)
                if let seen = value.seen {
                    result.firstSeenAt = seen; result.evidenceURL = url.absoluteString
                    let eligible = seen.addingTimeInterval(7 * 86_400)
                    result.eligibleAt = eligible
                    if eligible <= at { result.ageEligible = true }
                    else { result.unknownReason = "The Go index first observed this version within seven days; this does not establish its actual publication age." }
                    found = true; break
                }
                guard value.count == 2_000, let next = value.next, next > cursor else { break }
                cursor = next
            }
            if !found { result.unknownReason = "No matching Go public-index timestamp was found within four bounded pages; commit time is not publication evidence." }
        } catch {
            result.unknownReason = "Go " + phase + " is unavailable, unsupported or exceeds inspection limits. Commit time was not used as publication time."
        }
        return result
    }
    private static func failure() -> InspectionError { .blocked("Go public availability evidence could not be verified.") }
}
