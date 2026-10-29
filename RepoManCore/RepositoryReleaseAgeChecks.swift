import Foundation
import CryptoKit

/// Additive schema-3 comparison evidence. A successful age check covers these exact locked inputs only.
public struct DependencyComparisonReport: Codable, Sendable {
    public struct Input: Codable, Sendable {
        public let side: String
        public let path: String
        public let sha256: String
    }
    public struct Version: Codable, Sendable {
        public let identity: String
        public let change: String
        public let lockfiles: [String]
        public let status: String
        public let evidenceURL: String?
        public let publishedAt: String?
        public let eligibleAt: String?
        public let risks: [String]
        public let unknownReason: String?
        public let exceptionReason: String?
        public var firstSeenAt: String? = nil
    }
    public let baseCommit: String
    public let candidateHead: String?
    public let includesWorkingTree: Bool
    public let checkedAt: String
    public let minimumAgeDays: Int
    public let inputs: [Input]
    public let introduced: [Version]
    public let incompleteReasons: [String]
}

final class DependencyComparisonCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var report: DependencyComparisonReport?
    func record(_ report: DependencyComparisonReport) { lock.lock(); defer { lock.unlock() }; self.report = report }
    var value: DependencyComparisonReport? { lock.lock(); defer { lock.unlock() }; return report }
}

enum RepositoryReleaseAgeChecks {
    static let id = "dependencies.releaseAge"
    typealias Request = @Sendable (URL, TimeInterval) async throws -> Data
    static func checks(base: String? = nil, at: Date? = nil,
                       request: @escaping Request = { try await PublicRegistryRequest.read($0, timeout: $1, maximumBytes: GoPublicModuleEvidence.allowed($0) ? 2_097_152 : 67_108_864) },
                       go: @escaping GoModuleInventory.Request = { try GoModuleClient.read($0, $1, $2, $3) },
                       goRepository: @escaping GoPublicRepositoryClient.Request = { try await GoPublicRepositoryClient.read($0, timeout: $1) },
                       goManifest: @escaping GoReleaseEvidence.Manifest = { try GoModuleClient.manifest($0, excluding: $1, timeout: $2) },
                       record: @escaping @Sendable (DependencyComparisonReport) -> Void = { _ in }) -> [RepositoryCheck] {
        [RepositoryCheck(id: id, title: "Introduced dependency release age", category: .setup, symbol: "clock.badge.checkmark", evaluate: { context in
            guard let base else { return .skipped("No explicit comparison base was selected. Use --base COMMIT and --remote to check newly selected npm, pnpm, uv and Go versions.") }
            guard CheckSupport.matches(base, #"^(?:[0-9a-f]{40}|[0-9a-f]{64})$"#) else { return .unavailable("Comparison requires a resolved Git commit, not an inferred baseline.") }
            let checkedAt = at ?? context.snapshot.checkedAt
            let candidateHead = try? String(decoding: context.gitRead(["rev-parse", "--verify", "HEAD"]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let policy = try RepositoryCheckPolicy.load(context)
            var inputs: [String: DependencyComparisonReport.Input] = [:], candidateBytes: [String: String] = [:]
            var reasons = Set<String>(), findings: [RepositoryFinding] = [], versions: [DependencyComparisonReport.Version] = []
            func input(_ text: String, _ path: String, side: String) {
                inputs[side + ":" + path] = .init(side: side, path: path, sha256: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined())
            }
            func readCandidate(_ path: String) throws -> String {
                let text = try context.readText(path); input(text, path, side: "candidate"); candidateBytes[path] = text; return text
            }
            func readObject(_ arguments: [String]) throws -> Data {
                try GitRunner.run(["--no-optional-locks"] + arguments, at: context.snapshot.url, timeout: 10,
                                  maximumOutputBytes: 2_097_152,
                                  environmentOverrides: ["GIT_NO_REPLACE_OBJECTS":"1", "GIT_NO_LAZY_FETCH":"1"])
            }
            func readBase(_ path: String) throws -> String {
                guard DependencyLockInventory.safePath(path) else { throw InspectionError.blocked("Unsupported comparison input path.") }
                let data = try readObject(["show", base + ":" + path])
                guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8) else { throw InspectionError.blocked("Base comparison input is too large or is not UTF-8.") }
                input(text, path, side: "base"); return text
            }
            func evidence() {
                record(.init(baseCommit: base, candidateHead: candidateHead, includesWorkingTree: true, checkedAt: RegistryReleaseEvidence.timestamp(checkedAt),
                             minimumAgeDays: 7, inputs: inputs.values.sorted { ($0.side, $0.path) < ($1.side, $1.path) },
                             introduced: versions.sorted { $0.identity < $1.identity }, incompleteReasons: reasons.sorted()))
            }
            func finish() -> RepositoryCheckResult {
                evidence()
                return reasons.isEmpty ? .findings(findings) : .partial(findings, reasons.sorted().joined(separator: "\n"))
            }
            let basePaths: [String], candidatePaths: [String]
            do {
                basePaths = try paths(readObject(["ls-tree", "-r", "--name-only", "-z", base]))
                candidatePaths = try workingPaths(context)
            } catch { reasons.insert("Complete base and candidate file inventories could not be read."); return finish() }
            if candidatePaths.contains(".repoman.json") { _ = try readCandidate(".repoman.json") }
            let beforeLocks = basePaths.filter(isLock), afterLocks = candidatePaths.filter(isLock)
            let beforeGo = basePaths.filter(GoModuleInventory.isInput), afterGo = candidatePaths.filter(GoModuleInventory.isInput)
            let goWorkspace = GoModuleInventory.hasWorkspace(paths: candidatePaths, root: context.snapshot.url)
            guard !afterLocks.isEmpty || !afterGo.isEmpty else {
                if !beforeLocks.isEmpty || !beforeGo.isEmpty || candidatePaths.contains(where: isManifest) {
                    reasons.insert("No supported candidate lock inventory is available for declared JavaScript/Python dependencies; removed or unsupported locks cannot establish release-age compliance.")
                    return finish()
                }
                evidence(); return .notApplicable("No npm, pnpm, uv or Go module inventories are present. Other ecosystems are outside this comparison's scope.")
            }
            guard beforeLocks.count <= 128, afterLocks.count <= 128 else { reasons.insert("Lock inventories exceed the 128-file comparison limit."); return finish() }
            // Reuse the ordinary lock detector's declared-workspace lookup; a Python lock
            // cannot cover a JavaScript component, or an unrelated ancestor project.
            for path in candidatePaths where isManifest(path) || (path as NSString).lastPathComponent == "pnpm-workspace.yaml" {
                _ = try readCandidate(path)
            }
            for manifest in candidatePaths.filter(isManifest) {
                do {
                    let prefixes = try RepositoryDependencyChecks.lockPrefixes(context, manifest)
                    let names: Set<String> = manifest.hasSuffix("package.json") ? ["package-lock.json", "npm-shrinkwrap.json", "pnpm-lock.yaml"] : ["uv.lock"]
                    let matching = Set(prefixes.flatMap { prefix in names.map { prefix + $0 } })
                    if !afterLocks.contains(where: matching.contains) {
                        reasons.insert(manifest + ": no matching supported lock inventory covers this component through its directory or declared workspace.")
                    }
                } catch { reasons.insert(manifest + ": declared workspace lock coverage could not be established.") }
            }
            var before: [DependencyLockInventory.Entry] = [], after: [DependencyLockInventory.Entry] = []
            var baselineComplete = true
            for path in beforeLocks {
                do { before += try DependencyLockInventory.parse(readBase(path), path: path, read: readBase) }
                catch { baselineComplete = false; reasons.insert(path + ": the complete base lock inventory could not be parsed or its local members verified.") }
            }
            for path in afterLocks {
                do { after += try DependencyLockInventory.parse(readCandidate(path), path: path, read: readCandidate) }
                catch { reasons.insert(path + ": the complete candidate lock inventory could not be parsed or its local members verified.") }
            }
            // Read both complete selected graphs independently. Historical sums are not
            // a substitute for an unavailable baseline and must not invent new versions.
            for path in afterGo { _ = try readCandidate(path) }
            let oldGo = GoModuleInventory.capture(paths: beforeGo, root: context.snapshot.url, read: readBase, request: go)
            let newGo = GoModuleInventory.capture(paths: afterGo, root: context.snapshot.url, read: readCandidate, request: go)
            before += oldGo.entries; after += newGo.entries
            if !oldGo.reasons.isEmpty { baselineComplete = false }
            reasons.formUnion(oldGo.reasons.map { "Base: " + $0 }); reasons.formUnion(newGo.reasons.map { "Candidate: " + $0 })
            guard baselineComplete else { return finish() }
            let baseline = Dictionary(grouping: before, by: \.identity)
            let introduced = Dictionary(grouping: after.filter { changedOrigin($0, before: baseline[$0.identity] ?? []) }, by: \.identity)
            for entry in introduced.values.flatMap({ $0 }) where entry.source == "unsupported" {
                reasons.insert(entry.lockfile + ": a newly introduced or changed unsupported dependency source prevents complete release-age verification; source contents are withheld.")
            }
            guard introduced.count <= 2_048 else { reasons.insert("Introduced versions exceed the 2,048-identity comparison limit."); return finish() }
            let exceptionMap = policy.exceptions[id] ?? [:]
            let validExceptions = exceptionMap.count <= 128 && exceptionMap.keys.allSatisfy(validException)
            if !validExceptions { reasons.insert("Release-age exceptions must name an exact npm/PyPI name and version with the #age suffix; risks and unknown evidence cannot be excepted.") }
            let supported = introduced.keys.filter { key in introduced[key]!.allSatisfy { $0.source != "unsupported" } }
            let groups = Dictionary(grouping: supported.sorted()) { key in
                let entry = introduced[key]!.first!
                return entry.ecosystem == "npm" ? "npm:" + entry.name : entry.identity
            }.values.map { $0.sorted() }.sorted { $0[0] < $1[0] }
            let deadline = Date().addingTimeInterval(180)
            let repositories = await GoPublicRepositoryClient.fetch(introduced.values.flatMap { $0 }, request: goRepository, deadline: deadline)
            let candidateRoot = context.snapshot.url
            var documents: [String: [String: RegistryReleaseEvidence.Verdict]] = [:]
            // At most four anonymous reads execute concurrently. Only reduced verdicts are retained.
            await withTaskGroup(of: (String, [String: RegistryReleaseEvidence.Verdict]).self) { group in
                var next = 0
                func schedule(_ keys: [String]) {
                    group.addTask {
                        let entry = introduced[keys[0]]!.first!
                        if entry.ecosystem == "go" {
                            let value = await GoReleaseEvidence.evaluate(introduced[keys[0]]!, repositories: repositories, root: candidateRoot,
                                at: checkedAt, request: request, manifest: goManifest, deadline: deadline)
                            return (keys[0], [keys[0]: value])
                        }
                        let url = RegistryReleaseEvidence.url(entry)
                        var verdicts: [String: RegistryReleaseEvidence.Verdict] = [:]
                        guard Date() < deadline, !Task.isCancelled else {
                            for key in keys { verdicts[key] = .init(unknownReason: "Registry inspection time limit reached.") }; return (keys[0], verdicts)
                        }
                        do {
                            let bytes = try await request(url, min(20, deadline.timeIntervalSinceNow))
                            guard bytes.count <= 67_108_864, let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw InspectionError.blocked("Unsupported registry response.") }
                            for key in keys { verdicts[key] = RegistryReleaseEvidence.evaluate(introduced[key]!, document: object, at: checkedAt) }
                        } catch {
                            for key in keys { verdicts[key] = .init(unknownReason: "Public registry evidence is unavailable, malformed or exceeds inspection limits.") }
                        }
                        return (keys[0], verdicts)
                    }
                }
                while next < min(4, groups.count) { schedule(groups[next]); next += 1 }
                while let (key, values) = await group.next() {
                    documents[key] = values
                    if next < groups.count { schedule(groups[next]); next += 1 }
                }
            }
            let verdicts = documents.values.reduce(into: [String: RegistryReleaseEvidence.Verdict]()) { $0.merge($1) { _, new in new } }
            for key in introduced.keys.sorted() {
                let entries = introduced[key]!, entry = entries[0]
                let supportedSource = entries.allSatisfy { $0.source != "unsupported" }
                let verdict = verdicts[key] ?? .init(unknownReason: supportedSource ? "Registry evidence did not complete." : "Dependency source is unsupported; no public-registry fallback was used.")
                if let unknown = verdict.unknownReason { reasons.insert(key + ": " + unknown) }
                for risk in verdict.risks {
                    findings.append(CheckSupport.finding(context, id, key + "#" + risk, "Introduced dependency release needs review",
                        key + " is " + risk + " in its public registry. Age exceptions do not bypass this risk.", .setup, "clock.badge.exclamationmark", severity: .blocked))
                }
                var exception: String?
                if verdict.ageEligible == false {
                    let finding = CheckSupport.finding(context, id, key + "#age", "Introduced dependency is younger than seven days",
                        key + " was published at " + iso(verdict.publishedAt!) + "; eligible at " + iso(verdict.eligibleAt!) + ". Compared with " + base + " at " + iso(checkedAt) + ".", .setup, "clock.badge.exclamationmark", severity: .blocked)
                    let kept = validExceptions ? context.applyingExceptions([finding], policy: policy) : [finding]
                    if kept.isEmpty { exception = exceptionMap[finding.subject] } else { findings += kept }
                }
                let status = !verdict.risks.isEmpty ? "review_required" : (verdict.unknownReason != nil || verdict.ageEligible == nil ? "unknown" : (exception != nil ? "excepted" : (verdict.ageEligible == true ? "eligible" : "too_young")))
                versions.append(.init(identity: key, change: baseline[key] == nil ? "version" : "origin", lockfiles: Set(entries.map(\.lockfile)).sorted(), status: status,
                                      evidenceURL: supportedSource ? (verdict.evidenceURL ?? (entry.ecosystem == "go" ? nil : RegistryReleaseEvidence.url(entry).absoluteString)) : nil, publishedAt: verdict.publishedAt.map(RegistryReleaseEvidence.timestamp),
                                      eligibleAt: verdict.eligibleAt.map(RegistryReleaseEvidence.timestamp), risks: verdict.risks, unknownReason: verdict.unknownReason, exceptionReason: exception,
                                      firstSeenAt: verdict.firstSeenAt.map(RegistryReleaseEvidence.timestamp)))
            }
            do {
                guard try workingPaths(context) == candidatePaths,
                      GoModuleInventory.hasWorkspace(paths: candidatePaths, root: context.snapshot.url) == goWorkspace,
                      try GitRunner.text(["rev-parse", "--verify", "HEAD"], at: context.snapshot.url) == candidateHead else {
                    throw InspectionError.blocked("Candidate changed.")
                }
                for (path, original) in candidateBytes where try context.readFreshText(path) != original { throw InspectionError.blocked("Candidate changed.") }
            } catch { reasons.insert("Candidate HEAD, file inventory or inspected input bytes changed during comparison. Rerun against the intended candidate; observed findings remain bound to the recorded input hashes.") }
            return finish()
        })]
    }
    private static func changedOrigin(_ entry: DependencyLockInventory.Entry, before: [DependencyLockInventory.Entry]) -> Bool {
        let same = before.filter { $0.source == entry.source }
        guard !same.isEmpty else { return true }
        if entry.source == "unsupported" { return !same.contains { $0.sourceFingerprint == entry.sourceFingerprint } }
        if let digest = entry.integrity {
            let previous = same.compactMap(\.integrity)
            if !previous.isEmpty, !previous.contains(digest) { return true }
        }
        if let digest = entry.goModIntegrity {
            let previous = same.compactMap(\.goModIntegrity)
            if !previous.isEmpty, !previous.contains(digest) { return true }
        }
        if let tarball = entry.tarball {
            let previous = same.compactMap(\.tarball).compactMap { URL(string:$0)?.path }
            if !previous.isEmpty, !previous.contains(URL(string:tarball)?.path ?? "") { return true }
        }
        return false
    }
    private static func validException(_ subject: String) -> Bool {
        guard subject.hasSuffix("#age"), subject.count <= 400 else { return false }
        let identity = String(subject.dropLast(4)), parts = identity.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, ["npm", "pypi"].contains(parts[0]), let at = parts[1].lastIndex(of: "@") else { return false }
        let name = String(parts[1][..<at]), version = String(parts[1][parts[1].index(after: at)...])
        return (try? DependencyLockInventory.normalizedName(name, ecosystem: parts[0])) == name &&
            CheckSupport.matches(version, #"^[A-Za-z0-9][A-Za-z0-9.!+_-]*$"#)
    }
    private static func iso(_ date: Date) -> String { RegistryReleaseEvidence.timestamp(date) }
    private static func isLock(_ path: String) -> Bool { DependencyLockInventory.lockNames.contains((path as NSString).lastPathComponent) }
    private static func isManifest(_ path: String) -> Bool { ["package.json", "pyproject.toml"].contains((path as NSString).lastPathComponent) }
    private static func paths(_ data: Data) throws -> [String] {
        try DependencyLockInventory.paths(data)
    }
    private static func workingPaths(_ context: RepositoryInspectionContext) throws -> [String] {
        try DependencyLockInventory.workingPaths(context)
    }

}
