import Foundation

enum RepositoryContentChecks {
    static func checks() -> [RepositoryCheck] {
        [
            CheckSupport.check("files.secrets", "Potential tracked secrets", .setup, "key.slash", inspect: { context, _ in
                var findings: [RepositoryFinding] = []
                for path in try context.trackedPaths() {
                    guard let source = try context.trackedText(path) else { continue }
                    var locations: [String] = []
                    for (index, line) in source.components(separatedBy: .newlines).enumerated() {
                        let range = NSRange(line.startIndex..., in: line)
                        for (kind, pattern) in secretPatterns where pattern.firstMatch(in: line, range: range) != nil {
                            // Never include source lines, matches or token fragments in evidence.
                            locations.append("\(kind) at line \(index + 1)")
                        }
                    }
                    if !locations.isEmpty {
                        findings.append(CheckSupport.finding(context, "files.secrets", path, "Potential tracked secret",
                            "\(path): " + locations.prefix(20).joined(separator: "; ") + ". Values are redacted. Verify whether these are fixtures; exposed credentials require rotation.", .setup, "key.slash", severity: .blocked))
                    }
                }
                return findings
            }),
            CheckSupport.check("files.oversized", "Oversized tracked files", .setup, "doc.badge.ellipsis", inspect: { context, policy in
                try context.trackedPaths().compactMap { path in
                    guard let size = try context.regularFileSize(path), size > policy.maximumTrackedFileBytes else { return nil }
                    return CheckSupport.finding(context, "files.oversized", path, "Oversized tracked file",
                        "\(path) is \(size) bytes; the repository threshold is \(policy.maximumTrackedFileBytes). Review intentional assets, external storage or LFS.", .setup, "doc.badge.ellipsis", severity: .information)
                }
            }),
            CheckSupport.check("files.mergeMarkers", "Merge markers left in files", .git, "exclamationmark.triangle", inspect: { context, _ in
                var findings: [RepositoryFinding] = []
                for path in try context.trackedPaths() {
                    // Documentation frequently teaches conflict resolution; opt-in examples via exceptions elsewhere.
                    guard !["md", "markdown", "rst", "adoc", "ipynb"].contains((path as NSString).pathExtension.lowercased()),
                          let source = try context.trackedText(path) else { continue }
                    let lines = source.components(separatedBy: .newlines)
                    var start: Int?, separator = false, matches: [Int] = []
                    for (index, line) in lines.enumerated() {
                        // Ordinary source lines cannot be markers; avoid running a regex for them.
                        guard let firstCharacter = line.first, "<=>".contains(firstCharacter) else { continue }
                        let range = NSRange(line.startIndex..., in: line)
                        if firstCharacter == "<", conflictStart.firstMatch(in: line, range: range) != nil { start = index + 1; separator = false }
                        else if firstCharacter == "=", start != nil, conflictSeparator.firstMatch(in: line, range: range) != nil { separator = true }
                        else if firstCharacter == ">", let first = start, separator, conflictEnd.firstMatch(in: line, range: range) != nil { matches.append(first); start = nil; separator = false }
                    }
                    if !matches.isEmpty {
                        findings.append(CheckSupport.finding(context, "files.mergeMarkers", path, "Merge markers left in file",
                            "\(path) contains complete conflict marker blocks starting at lines \(matches.prefix(20).map(String.init).joined(separator: ", ")). Review intentional fixtures before editing.", .git, "exclamationmark.triangle", severity: .blocked))
                    }
                }
                return findings
            })
        ]
    }
    // High-confidence shapes only. This is a current tracked-file scan, not a history audit.
    private static let conflictStart = try! NSRegularExpression(pattern: #"^<{7,}(?:\s.*)?$"#)
    private static let conflictSeparator = try! NSRegularExpression(pattern: #"^={7,}\s*$"#)
    private static let conflictEnd = try! NSRegularExpression(pattern: #"^>{7,}(?:\s.*)?$"#)
    private static let secretPatterns: [(String, NSRegularExpression)] = [
        ("Private key", #"^[ \t]*-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----[ \t\r]*$"#),
        ("GitHub token", #"\bgh[pousr]_[A-Za-z0-9]{36}\b|\bgithub_pat_[A-Za-z0-9_]{82}\b"#),
        ("AWS access key ID", #"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"#),
        ("Slack token", #"\bxox[baprs]-[0-9]{10,13}-[0-9]{10,13}-[A-Za-z0-9]{20,}\b"#),
        ("Stripe live secret", #"\b(?:sk|rk)_live_[A-Za-z0-9]{24,}\b"#),
        ("Hugging Face token", #"\bhf_[A-Za-z0-9]{34}\b"#)
    ].map { ($0.0, try! NSRegularExpression(pattern: $0.1)) }
}
