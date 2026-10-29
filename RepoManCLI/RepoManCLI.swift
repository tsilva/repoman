import Foundation
#if SWIFT_PACKAGE
import RepoManCore
#endif

@main
struct RepoManCLI {
    static let usage = """
    Usage: repoman check --repo PATH [--check ID ...] [--fetch] [--remote] [--base COMMIT] [--format text|json]
           repoman --list-checks

    Fresh repository checks using RepoManCore. Fetch refs only with --fetch; no install, commit, merge or push.
    Remote checks are skipped unless --remote permits read-only GitHub, public-registry and advisory requests.
    --base explicitly compares current npm/pnpm/uv locks and selected Go graphs with a Git commit; it never selects a baseline automatically.
    Exit: 0 = no actionable findings or incomplete checks (information is allowed),
          1 = actionable findings (coverage may also be incomplete), 2 = error,
          3 = incomplete verification without actionable findings.
    """
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["--help"] || arguments == ["-h"] { print(usage); return }
            if arguments == ["--list-checks"] {
                for check in RepositoryIssueCatalog.standardChecks {
                    print("\(check.id)\(check.requiresRemoteAccess ? " [remote]" : "")\t\(check.title)")
                }
                for check in RepositoryIssueCatalog.coverageCompatibilityChecks { print("\(check.id) [coverage alias]\t\(check.title)") }
                return
            }
            guard arguments.first == "check" else { throw CLIError.argument("Expected check command.") }
            var path: String?, base: String?, format = "text", remote = false, fetch = false, ids: Set<String> = []
            var index = 1
            var seen: Set<String> = []
            while index < arguments.count {
                let option = arguments[index]
                if option == "--remote" || option == "--fetch" {
                    guard seen.insert(option).inserted else { throw CLIError.argument("Duplicate \(option).") }
                    if option == "--remote" { remote = true } else { fetch = true }
                    index += 1; continue
                }
                guard ["--repo", "--check", "--format", "--base"].contains(option), index + 1 < arguments.count,
                      !arguments[index + 1].hasPrefix("--"), !arguments[index + 1].isEmpty else {
                    throw CLIError.argument("Invalid option or missing value: \(option)")
                }
                if option != "--check", !seen.insert(option).inserted { throw CLIError.argument("Duplicate \(option).") }
                let value = arguments[index + 1]
                switch option {
                case "--repo": path = value
                case "--check": ids.insert(value)
                case "--base": base = value
                default: format = value
                }
                index += 2
            }
            guard let path, ["text", "json"].contains(format) else { throw CLIError.argument("Provide --repo and a valid format.") }
            if ids.contains("dependencies.releaseAge"), base == nil { throw CLIError.argument("dependencies.releaseAge requires an explicit --base COMMIT.") }
            if base != nil, !remote { throw CLIError.argument("--base requires --remote for public registry evidence.") }
            if base != nil, !ids.isEmpty, !ids.contains("dependencies.releaseAge") { throw CLIError.argument("--base applies only to dependencies.releaseAge.") }
            let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
            let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let version = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
            let report = try await RepositoryChecker.run(at: URL(fileURLWithPath: path), checkIDs: ids, remote: remote, fetch: fetch, checkerVersion: version, comparisonBase: base)
            if format == "json" { FileHandle.standardOutput.write(try report.json()); print("") }
            else { print(report.text) }
            exit(report.exitCode)
        } catch {
            // Git/provider error output may contain authenticated remote URLs.
            let message = (error as? CLIError)?.message ?? "Repository checks could not start. Check the path, check IDs, remote opt-in and Git availability."
            FileHandle.standardError.write(Data(("repoman: " + message + "\n" + usage + "\n").utf8))
            exit(2)
        }
    }
    enum CLIError: Error {
        case argument(String)
        var message: String { switch self { case .argument(let value): value } }
    }
}
