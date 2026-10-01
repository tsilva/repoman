import Foundation
import Darwin

struct CIBranchStatus: Sendable {
    let name: String
    let sha: String
    let checks: [CICheckStatus]
}
struct CICheckStatus: Sendable {
    let name: String
    let result: String
    let url: URL?
    var failed: Bool { ["FAILURE", "ERROR", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE"].contains(result) }
    var finished: Bool { failed || ["SUCCESS", "NEUTRAL", "SKIPPED"].contains(result) }
}

enum GitHubCI {
    struct Repository: Equatable { let owner: String; let name: String }

    static func repository(_ remote: String?) -> Repository? {
        guard let remote else { return nil }
        let url: URL?
        if remote.hasPrefix("git@github.com:") {
            url = URL(string: "https://github.com/" + remote.dropFirst("git@github.com:".count))
        } else { url = URL(string: remote) }
        guard let url, url.host?.lowercased() == "github.com", ["https", "http", "ssh"].contains(url.scheme) else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }
        let name = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        guard !name.isEmpty, !parts[0].isEmpty, (parts[0] + name).unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return Repository(owner: parts[0], name: name)
    }

    // One read-only query gathers Checks API and legacy status results for both branch tips.
    static let query = """
    query($owner: String!, $name: String!, $ref: String!) {
      repository(owner: $owner, name: $name) {
        defaultBranchRef { ...BranchCI }
        currentBranch: ref(qualifiedName: $ref) { ...BranchCI }
      }
    }
    fragment BranchCI on Ref {
      name
      target {
        ... on Commit {
          oid
          statusCheckRollup {
            contexts(first: 100) {
              pageInfo { hasNextPage }
              nodes {
                __typename
                ... on CheckRun {
                  name status conclusion detailsUrl startedAt
                  checkSuite { createdAt app { slug } workflowRun { runNumber event workflow { name } } }
                }
                ... on StatusContext { context state targetUrl createdAt }
              }
            }
          }
        }
      }
    }
    """

    static func load(_ snapshot: RepositorySnapshot) throws -> [CIBranchStatus] {
        guard let repository = repository(snapshot.remoteURL) else { return [] }
        let branch = snapshot.upstream.flatMap { upstream -> String? in
            let parts = upstream.split(separator: "/", maxSplits: 1)
            return parts.count == 2 ? String(parts[1]) : nil
        } ?? snapshot.branch
        let arguments = ["api", "graphql", "--hostname", "github.com", "--raw-field", "query=" + query,
            "--raw-field", "owner=" + repository.owner, "--raw-field", "name=" + repository.name,
            "--raw-field", "ref=refs/heads/" + branch]
        return try decode(GitHubCLI.run(arguments), requiresCurrentBranch: snapshot.upstream != nil)
    }

    static func decode(_ data: Data, requiresCurrentBranch: Bool = false) throws -> [CIBranchStatus] {
        let response = try JSONDecoder().decode(Response.self, from: data)
        if let errors = response.errors, !errors.isEmpty { throw RepairError.blocked("GitHub CI inspection failed: " + errors.map(\.message).joined(separator: "; ")) }
        guard let repository = response.data?.repository, let defaultBranch = repository.defaultBranchRef else {
            throw RepairError.blocked("GitHub has no readable default branch. Check repository access and gh authentication.")
        }
        if requiresCurrentBranch, repository.currentBranch == nil {
            throw RepairError.blocked("The tracked branch is unavailable on GitHub; CI could not be verified.")
        }
        var branches = [defaultBranch]
        if let current = repository.currentBranch, current.name != defaultBranch.name { branches.append(current) }
        return try branches.map { branch in
            guard let target = branch.target, !target.oid.isEmpty else { throw RepairError.blocked("GitHub did not return a branch commit.") }
            guard target.statusCheckRollup?.contexts.pageInfo.hasNextPage != true else {
                throw RepairError.blocked("More than 100 CI results exist on \(branch.name); inspection is incomplete.")
            }
            // Reruns replace earlier results with the same provider/workflow/job identity.
            var latest: [String: Context] = [:]
            for context in target.statusCheckRollup?.contexts.nodes ?? [] {
                let identity = [context.__typename, context.checkSuite?.app?.slug ?? "", context.checkSuite?.workflowRun?.workflow.name ?? "",
                    context.checkSuite?.workflowRun?.event ?? "", context.name ?? context.context ?? ""].joined(separator: "\u{1f}")
                if let old = latest[identity] {
                    if old.runNumber > context.runNumber { continue }
                    if old.runNumber == context.runNumber {
                        // A queued rerun has no start date yet; it must supersede the old completion.
                        if old.__typename == "CheckRun", old.status != "COMPLETED", old.startedAt == nil { continue }
                        if context.__typename == "CheckRun", context.status != "COMPLETED", context.startedAt == nil { latest[identity] = context; continue }
                        if old.date > context.date { continue }
                    }
                }
                latest[identity] = context
            }
            let checks = try latest.keys.sorted().map { key -> CICheckStatus in
                let context = latest[key]!
                let name = context.name ?? context.context
                guard let name, !name.isEmpty else { throw RepairError.blocked("GitHub returned a CI result without a name.") }
                let result: String
                if context.__typename == "CheckRun" {
                    guard let status = context.status else { throw RepairError.blocked("GitHub returned an incomplete check run.") }
                    result = status == "COMPLETED" ? (context.conclusion ?? "UNKNOWN") : status
                } else if context.__typename == "StatusContext", let state = context.state { result = state }
                else { throw RepairError.blocked("GitHub returned an unsupported CI result.") }
                let url = (context.detailsUrl ?? context.targetUrl).flatMap(URL.init(string:))
                return CICheckStatus(name: name, result: result, url: url)
            }
            return CIBranchStatus(name: branch.name, sha: target.oid, checks: checks)
        }
    }

    private struct Response: Decodable { let data: Payload?; let errors: [APIError]? }
    private struct APIError: Decodable { let message: String }
    private struct Payload: Decodable { let repository: RemoteRepository? }
    private struct RemoteRepository: Decodable { let defaultBranchRef: Branch?; let currentBranch: Branch? }
    private struct Branch: Decodable { let name: String; let target: Commit? }
    private struct Commit: Decodable { let oid: String; let statusCheckRollup: Rollup? }
    private struct Rollup: Decodable { let contexts: Contexts }
    private struct Contexts: Decodable { let pageInfo: PageInfo; let nodes: [Context] }
    private struct PageInfo: Decodable { let hasNextPage: Bool }
    private struct Context: Decodable {
        let __typename: String
        let name: String?; let context: String?
        let status: String?; let conclusion: String?; let state: String?
        let detailsUrl: String?; let targetUrl: String?
        let startedAt: String?; let createdAt: String?
        let checkSuite: Suite?
        var date: String { startedAt ?? createdAt ?? checkSuite?.createdAt ?? "" }
        var runNumber: Int { checkSuite?.workflowRun?.runNumber ?? 0 }
    }
    private struct Suite: Decodable { let createdAt: String?; let app: App?; let workflowRun: WorkflowRun? }
    private struct App: Decodable { let slug: String? }
    private struct WorkflowRun: Decodable { let runNumber: Int?; let event: String?; let workflow: Workflow }
    private struct Workflow: Decodable { let name: String }
}

/// GUI launches often have a minimal PATH. Reuse gh's login without reading credentials.
enum GitHubCLI {
    static func executable() throws -> URL {
        let directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let paths = directories.map { $0 + "/gh" } + ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw RepairError.blocked("GitHub CLI was not found. Install gh and run gh auth login to inspect CI.")
        }
        return URL(fileURLWithPath: path)
    }
    static func run(_ arguments: [String], executable configured: URL? = nil, timeout: TimeInterval = 15) throws -> Data {
        let process = Process()
        process.executableURL = try configured ?? executable()
        process.arguments = arguments
        // Do not let the selected repository's gh configuration or hooks affect inspection.
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_PAGER"] = "cat"
        environment["GH_DEBUG"] = nil
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output; process.standardError = errors
        try process.run()
        let state = Capture()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler {
            guard process.isRunning else { return }
            state.markTimedOut()
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        timer.resume()
        let group = DispatchGroup()
        group.enter()
        Thread.detachNewThread {
            state.error = drain(errors.fileHandleForReading)
            group.leave()
        }
        let data = drain(output.fileHandleForReading)
        process.waitUntilExit(); group.wait(); timer.cancel()
        if state.timedOut { throw RepairError.blocked("GitHub CI inspection timed out. Try refreshing again.") }
        guard process.terminationStatus == 0 else {
            let message = String(decoding: state.error.prefix(2048), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw RepairError.blocked("GitHub CI inspection failed. Check gh authentication, repository access, and API limits. \(message)")
        }
        guard data.count < 2_097_152 else { throw RepairError.blocked("GitHub CI response exceeded the inspection limit.") }
        return data
    }
    private static func drain(_ handle: FileHandle) -> Data {
        var data = Data()
        while let chunk = try? handle.read(upToCount: 65536), !chunk.isEmpty {
            if data.count < 2_097_152 { data.append(chunk.prefix(2_097_152 - data.count)) }
        }
        return data
    }
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var didTimeOut = false
        // Written by the drain task and read only after DispatchGroup.wait().
        var error = Data()
        var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return didTimeOut }
        func markTimedOut() { lock.lock(); defer { lock.unlock() }; didTimeOut = true }
    }
}
