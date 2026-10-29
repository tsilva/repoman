import Foundation
import CryptoKit

/// Public bundle claims require a verified parent's literal archive, not just an inBundle flag.
enum NPMBundleEvidence {
    struct Verified: Sendable {
        let origin: DependencyLockInventory.BundleOrigin
        let identity: String
        let metadataSHA256: String
    }
    struct Result: Sendable {
        var verified: [DependencyLockInventory.BundleOrigin: Verified] = [:]
        var reasons: [DependencyLockInventory.BundleOrigin: String] = [:]
    }
    static func verify(_ entries: [DependencyLockInventory.Entry], registry: @escaping RepositoryVulnerabilityChecks.RegistryRequest,
                       archive: @escaping RepositoryVulnerabilityChecks.RegistryRequest, deadline: Date) async -> Result {
        let bundled = entries.filter { $0.bundle != nil }
        let groups = Dictionary(grouping: bundled, by: { $0.bundle!.parent })
        guard groups.count <= 16 else {
            return Result(reasons: Dictionary(uniqueKeysWithValues: Set(bundled.compactMap(\.bundle)).map { ($0, "Public bundle parents exceed the 16-archive verification limit.") }))
        }
        let parents = groups.keys.sorted { ($0.lockfile, $0.identity, $0.tarball) < ($1.lockfile, $1.identity, $1.tarball) }
        let results = await RepositoryVulnerabilityChecks.boundedMap(parents) { parent -> Result in
            let children = groups[parent]!, origins = Set(children.compactMap(\.bundle))
            func unavailable(_ reason: String) -> Result { Result(reasons: Dictionary(uniqueKeysWithValues: origins.map { ($0, reason) })) }
            guard parent.integrity.hasPrefix("sha512-"), let digest = Data(base64Encoded: String(parent.integrity.dropFirst(7))), digest.count == 64,
                  DependencyLockInventory.publicNPMTarball(parent.tarball) else { return unavailable("Public bundle archive lacks a supported SHA-512 integrity binding.") }
            let entry = DependencyLockInventory.Entry(ecosystem: "npm", name: parent.name, version: parent.version, lockfile: parent.lockfile,
                                                     source: "npm", integrity: parent.integrity, tarball: parent.tarball)
            guard let timeout = RepositoryVulnerabilityChecks.remaining(deadline) else { return unavailable("Public bundle registry verification time limit reached.") }
            do {
                let response = try await registry(RepositoryVulnerabilityChecks.publicVersionURL(entry), timeout)
                guard response.count <= 2_097_152, let metadata = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                      RegistryReleaseEvidence.publicIdentity([entry], document: ["name": metadata["name"] ?? NSNull(), "versions": [parent.version: metadata]]),
                      let declared = metadata["bundleDependencies"] as? [String] ?? metadata["bundledDependencies"] as? [String], declared.count <= 256,
                      children.allSatisfy({ declared.contains($0.name) }) else { return unavailable("Public registry evidence does not verify this parent or its declared bundle members.") }
                guard let timeout = RepositoryVulnerabilityChecks.remaining(deadline) else { return unavailable("Public bundle archive verification time limit reached.") }
                let bytes = try await archive(URL(string: parent.tarball)!, timeout)
                guard bytes.count <= NPMBundleArchive.maximumCompressedBytes, Data(SHA512.hash(data: bytes)) == digest else { return unavailable("Public bundle archive bytes do not match the locked and registry-verified SHA-512.") }
                let paths = Set(origins.map(\.memberPath)).union(["package/package.json"])
                let manifests = try NPMBundleArchive.manifests(bytes, paths: paths)
                guard let rootBytes = manifests["package/package.json"], let root = try JSONSerialization.jsonObject(with: rootBytes) as? [String: Any],
                      root["name"] as? String == parent.name, root["version"] as? String == parent.version,
                      let archiveDeclared = root["bundleDependencies"] as? [String] ?? root["bundledDependencies"] as? [String], archiveDeclared.count <= 256,
                      children.allSatisfy({ archiveDeclared.contains($0.name) }) else { return unavailable("The verified archive does not establish this parent identity and its bundle declarations.") }
                var result = Result()
                for child in children {
                    let origin = child.bundle!
                    guard let raw = manifests[origin.memberPath], let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                          object["name"] as? String == child.name, object["version"] as? String == child.version else {
                        result.reasons[origin] = "Bundled package metadata does not match the locked name/version."; continue
                    }
                    result.verified[origin] = Verified(origin: origin, identity: child.identity,
                        metadataSHA256: SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined())
                }
                return result
            } catch { return unavailable("Public bundle provenance is unavailable, malformed, unsupported or exceeds verification limits.") }
        }
        var result = Result()
        for item in results {
            result.verified.merge(item.verified) { a, _ in a }; result.reasons.merge(item.reasons) { a, _ in a }
        }
        return result
    }
}
