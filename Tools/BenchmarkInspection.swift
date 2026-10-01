import Foundation

// Run from the repository root:
// swiftc -O -parse-as-library RepoManCore/*.swift Tools/BenchmarkInspection.swift -o .build/benchmark-inspection
// .build/benchmark-inspection /path/to/repository
@main
struct BenchmarkInspection {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            print("Usage: benchmark-inspection /path/to/repository")
            return
        }
        let repository = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        // Network latency is separate from local inspection performance. Do not fetch or request GitHub metadata.
        let catalog = RepositoryIssueCatalog(checks: RepositoryIssueCatalog.standardChecks.filter {
            !["ci.failing", "github.description"].contains($0.id)
        })
        var durations: [TimeInterval] = []
        for iteration in 1...3 {
            let start = ContinuousClock.now
            let snapshot = try GitRepositoryScanner.scan(repository, includeDetails: false)
            let scanned = ContinuousClock.now
            let report = await catalog.inspect(snapshot)
            let elapsed = seconds(scanned.duration(to: .now))
            durations.append(elapsed)
            print(String(format: "Run %d: snapshot %.3fs, local inspection %.3fs (%d findings, %d unavailable)",
                iteration, seconds(start.duration(to: scanned)), elapsed, report.findings().count, report.unavailableChecks.count))
        }
        print(String(format: "Median local inspection: %.3fs", durations.sorted()[1]))
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
