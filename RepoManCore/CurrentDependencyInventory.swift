import Foundation
import CryptoKit

/// Complete current lock inputs, including unignored untracked files and unstaged removals.
struct CurrentDependencyInventory: Sendable {
    let paths: [String]
    let head: String?
    let inputs: [DependencyComparisonReport.Input]
    let bytes: [String: String]
    let entries: [DependencyLockInventory.Entry]
    let reasons: [String]
    let lockfiles: [String]
    let hasDeclarations: Bool

    static func capture(_ context: RepositoryInspectionContext) throws -> Self {
        let paths = try DependencyLockInventory.workingPaths(context, includingRequirements: true)
        let head = try? GitRunner.text(["rev-parse", "--verify", "HEAD"], at: context.snapshot.url)
        let locks = paths.filter(DependencyLockInventory.isLock)
        let manifests = paths.filter(DependencyLockInventory.isManifest)
        let requirements = paths.filter { ($0 as NSString).lastPathComponent == "requirements.txt" }
        var inputs: [String: DependencyComparisonReport.Input] = [:], bytes: [String: String] = [:]
        var reasons = Set<String>(), entries: [DependencyLockInventory.Entry] = []
        func read(_ path: String) throws -> String {
            let text = try context.readText(path)
            bytes[path] = text
            inputs[path] = .init(side: "candidate", path: path, sha256: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined())
            return text
        }
        for path in paths where !DependencyLockInventory.isLock(path) {
            do { _ = try read(path) }
            catch { reasons.insert(path + ": dependency input could not be read completely.") }
        }
        for path in requirements { reasons.insert(path + ": pip requirement inventories are outside supported npm/pnpm/uv lock auditing; equivalent audit evidence is needed.") }
        for path in manifests {
            do {
                let prefixes = try RepositoryDependencyChecks.lockPrefixes(context, path)
                let names: Set<String> = path.hasSuffix("package.json") ? ["package-lock.json", "npm-shrinkwrap.json", "pnpm-lock.yaml"] : ["uv.lock"]
                let matching = Set(prefixes.flatMap { prefix in names.map { prefix + $0 } })
                if !locks.contains(where: matching.contains) { reasons.insert(path + ": a complete supported lock inventory does not cover this component through its directory or declared workspace.") }
            } catch { reasons.insert(path + ": declared workspace lock coverage could not be established.") }
        }
        if locks.count > 128 { reasons.insert("Lock inventories exceed the 128-file inspection limit.") }
        else {
            for path in locks {
                do {
                    let parsed = try DependencyLockInventory.parse(read(path), path: path, read: read)
                    guard entries.count + parsed.count <= 20_000 else { reasons.insert("Dependency inventories exceed the 20,000-entry inspection limit."); break }
                    entries += parsed
                } catch { reasons.insert(path + ": the complete lock inventory could not be parsed or its local members verified.") }
            }
        }
        return Self(paths: paths, head: head, inputs: inputs.values.sorted { $0.path < $1.path }, bytes: bytes,
                    entries: entries, reasons: reasons.sorted(), lockfiles: locks, hasDeclarations: !manifests.isEmpty || !requirements.isEmpty)
    }
    func unchanged(_ context: RepositoryInspectionContext) -> Bool {
        do {
            guard try DependencyLockInventory.workingPaths(context, includingRequirements: true) == paths,
                  (try? GitRunner.text(["rev-parse", "--verify", "HEAD"], at: context.snapshot.url)) == head else { return false }
            for (path, original) in bytes where try context.readFreshText(path) != original { return false }
            return true
        } catch { return false }
    }
}
