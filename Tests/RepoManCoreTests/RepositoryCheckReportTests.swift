import XCTest
@testable import RepoManCore

final class RepositoryCheckReportTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try GitRunner.run(["init", "-b", "main"], at: root)
        for (key, value) in [("user.name", "Fixture"), ("user.email", "fixture@example.invalid"),
                             ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] {
            _ = try GitRunner.run(["config", key, value], at: root)
        }
        try write("package.json", #"{"name":"fixture","version":"1.0.0","packageManager":"npm@10.0.0"}"#)
        _ = try GitRunner.run(["add", "package.json"], at: root)
        _ = try GitRunner.run(["commit", "-m", "Fixture"], at: root)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func write(_ path: String, _ text: String) throws {
        try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    func testSharedCheckerMatchesDashboardAndLeavesGitStateUntouched() async throws {
        let ids: Set<String> = ["dependencies.safeguards", "dependencies.lockfile"]
        let paths = [".git/index", ".git/HEAD", ".git/config", "package.json"]
        let before = try paths.map { try Data(contentsOf: root.appendingPathComponent($0)) }
        let snapshot = try GitRepositoryScanner.scan(root, includeDetails: false)
        let dashboard = await RepositoryIssueCatalog(checks: RepositoryIssueCatalog.standardChecks.filter { ids.contains($0.id) }).inspect(snapshot)
        let report = try await RepositoryChecker.run(at: root, checkIDs: ids)
        XCTAssertEqual(Set(report.checks.flatMap(\.findings).map(\.id)), Set(dashboard.findings().map(\.id)))
        XCTAssertEqual(report.exitCode, 1)
        XCTAssertNotNil(report.head)
        XCTAssertEqual(try paths.map { try Data(contentsOf: root.appendingPathComponent($0)) }, before)
        let decoded = try JSONSerialization.jsonObject(with: report.json()) as! [String: Any]
        XCTAssertEqual(decoded["schemaVersion"] as? Int, 3)
        XCTAssertNotNil(decoded["observedAt"])
    }

    func testReasonedExceptionsAppearOnlyWhenTheySuppressARealFinding() async throws {
        let initial = try await RepositoryChecker.run(at: root, checkIDs: ["dependencies.safeguards"])
        let subject = try XCTUnwrap(initial.checks.first?.findings.first?.subject)
        let policy: [String: Any] = ["version": 1, "exceptions": ["dependencies.safeguards": [subject: "Controlled fixture", "unused": "Unused exception"]]]
        try JSONSerialization.data(withJSONObject: policy).write(to: root.appendingPathComponent(".repoman.json"))
        let report = try await RepositoryChecker.run(at: root, checkIDs: ["dependencies.safeguards"])
        XCTAssertEqual(report.exitCode, 0)
        XCTAssertEqual(report.checks.first?.exceptions, [subject: "Controlled fixture"])
        XCTAssertTrue(try XCTUnwrap(report.checks.first).findings.isEmpty)
    }

    func testLocalModeSkipsAllRemoteLoadersAndMalformedPolicyIsIncomplete() async throws {
        _ = try GitRunner.run(["remote", "add", "origin", "https://github.com/fixture/private-fixture.git"], at: root)
        let report = try await RepositoryChecker.run(at: root)
        for check in report.checks where check.id == "ci.failing" || check.id.hasPrefix("github.") {
            XCTAssertEqual(check.status, "skipped")
            XCTAssertNotNil(check.reason)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/FETCH_HEAD").path))
        try write(".repoman.json", "invalid")
        let invalid = try await RepositoryChecker.run(at: root, checkIDs: ["dependencies.safeguards"])
        XCTAssertEqual(invalid.checks.first?.status, "incomplete")
        XCTAssertEqual(invalid.exitCode, 3)
    }

    func testPartialResultsRetainFindingsAndCannotReportClean() throws {
        let snapshot = try GitRepositoryScanner.scan(root, includeDetails: false)
        let finding = RepositoryFinding(repositoryID: snapshot.id, checkID: "fixture", title: "Detected",
                                        evidence: "Observed", category: .setup, symbol: "circle")
        let inspection = RepositoryInspectionReport(snapshot: snapshot, results: ["fixture": .partial([finding], "Other evidence unavailable")], checkOrder: ["fixture"])
        let report = RepositoryCheckReport(inspection, head: nil, checkerVersion: "fixture")
        XCTAssertEqual(report.exitCode, 1)
        XCTAssertEqual(report.checks.first?.status, "incomplete")
        XCTAssertEqual(report.checks.first?.findings.first?.id, finding.id)
    }

    func testInformationalResultsDoNotFailAndKeepTheirEvidence() throws {
        let snapshot = try GitRepositoryScanner.scan(root, includeDetails: false)
        let info = RepositoryFinding(repositoryID: snapshot.id, checkID: "git.worktrees", title: "Linked worktrees",
            evidence: "A linked checkout exists.", category: .git, severity: .information, symbol: "square.on.square")
        let results: [String: RepositoryCheckResult] = ["git.worktrees": .findings([info])]
        let report = RepositoryCheckReport(RepositoryInspectionReport(snapshot: snapshot, results: results,
            checkOrder: ["git.worktrees"]), head: nil, checkerVersion: "fixture")
        XCTAssertEqual(report.exitCode, 0)
        XCTAssertEqual(report.checks.first?.status, "information")
        XCTAssertEqual(report.checks.first?.findings.first?.evidence, info.evidence)
        XCTAssertEqual(RepositoryIssueListItem(finding: info).status, .information)
        XCTAssertEqual(RepositoryIssueStatus.counts(in: [.init(finding: info)]), [.information: 1])
        let unknown = RepositoryCheckReport(RepositoryInspectionReport(snapshot: snapshot,
            results: ["git.worktrees": .partial([info], "Other worktrees unavailable")],
            checkOrder: ["git.worktrees"]), head: nil, checkerVersion: "fixture")
        XCTAssertEqual(unknown.exitCode, 3)
        XCTAssertEqual(unknown.checks.first?.status, "incomplete")
        let violation = RepositoryFinding(repositoryID: snapshot.id, checkID: "fixture", title: "Actual problem",
            evidence: "Violation", category: .setup, symbol: "circle")
        let mixed = RepositoryCheckReport(RepositoryInspectionReport(snapshot: snapshot,
            results: ["fixture": .partial([info, violation], "Other inputs unavailable")],
            checkOrder: ["fixture"]), head: nil, checkerVersion: "fixture")
        XCTAssertEqual(mixed.exitCode, 1)
        XCTAssertEqual(mixed.checks.first?.findings.count, 2)
    }

    func testPythonCoverageDiagnosticIdentifiesOnlyUnsupportedDeclarations() async throws {
        _ = try GitRunner.run(["rm", "package.json"], at: root)
        for (declaration, expected) in [
            ("[project]\nname = 'fixture'\ndynamic = ['dependencies']", "project.dynamic"),
            ("[tool.uv.sources]\nexample = { path = '../private-path' }", "tool.uv.sources"),
            ("[tool.uv]\ndev-dependencies = ['pytest']", "tool.uv.dev-dependencies")
        ] {
            try write("pyproject.toml", declaration)
            try write("uv.lock", "version = 1")
            _ = try GitRunner.run(["add", "pyproject.toml", "uv.lock"], at: root)
            let report = try await RepositoryChecker.run(at: root, checkIDs: ["dependencies.lockfileDrift"])
            let check = try XCTUnwrap(report.checks.first)
            XCTAssertEqual(check.status, "incomplete")
            XCTAssertEqual(report.exitCode, 3)
            let reason = try XCTUnwrap(check.reason)
            XCTAssertTrue(reason.hasPrefix("pyproject.toml:"), reason)
            XCTAssertTrue(reason.contains(expected), reason)
            XCTAssertTrue(reason.contains("uv lock --check"), reason)
            XCTAssertFalse(reason.contains("private-path"))
            for absent in ["project.dynamic", "dependency-groups", "tool.uv.sources", "tool.uv.dev-dependencies"] where absent != expected {
                XCTAssertFalse(reason.contains(absent), reason)
            }
        }
    }

    func testInvalidSelectionAndUnapprovedRemoteCheckAreRejected() async throws {
        for ids: Set<String> in [["unknown"], ["github.description"]] {
            do { _ = try await RepositoryChecker.run(at: root, checkIDs: ids); XCTFail("Expected rejection") }
            catch {}
        }
    }

    func testMaintenanceTaskQuotesPathsAndRequiresFreshEvidence() {
        let finding = RepositoryFinding(repositoryID: "/tmp/it's a repo", checkID: "github.description", subject: "README",
                                        title: "Drift", evidence: "Observed", category: .documentation, symbol: "circle")
        let task = RepositoryMaintenanceTask.text(for: finding, observedAt: nil)
        XCTAssertTrue(task.contains("'/tmp/it'\\''s a repo'"))
        XCTAssertTrue(task.contains("--remote --format json"))
        XCTAssertTrue(task.contains("does not authorize"))
    }

    func testUnsupportedEcosystemIsNotApplicableRatherThanPassed() async throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent("package.json"))
        _ = try GitRunner.run(["rm", "--cached", "package.json"], at: root)
        try write("Package.swift", "// Swift project")
        let ids: Set<String> = ["dependencies.safeguards", "dependencies.lockfile", "dependencies.lockfileDrift"]
        let report = try await RepositoryChecker.run(at: root, checkIDs: ids)
        XCTAssertEqual(report.exitCode, 0)
        XCTAssertTrue(report.checks.allSatisfy { $0.status == "not_applicable" && $0.reason?.contains("Other ecosystems") == true })
        let snapshot = try GitRepositoryScanner.scan(root, includeDetails: false)
        let catalog = RepositoryIssueCatalog(checks: RepositoryIssueCatalog.standardChecks.filter { ids.contains($0.id) })
        let dashboard = await catalog.inspect(snapshot)
        XCTAssertTrue(ids.allSatisfy { dashboard.status(for: $0) == .notApplicable })
        XCTAssertTrue(dashboard.unavailableChecks.isEmpty)
        XCTAssertTrue(dashboard.findings().isEmpty)
    }

    func testOnlyPipRequirementsDoNotSatisfyLockfileApplicability() async throws {
        _ = try GitRunner.run(["rm", "package.json"], at: root)
        try write("requirements.txt", "example==1.0")
        let report = try await RepositoryChecker.run(at: root, checkIDs: ["dependencies.lockfile", "dependencies.lockfileDrift"])
        XCTAssertTrue(report.checks.allSatisfy { $0.status == "not_applicable" })
    }

    func testUnfetchedComparisonsRetainLocalCountsWithoutClaimingRemoteHealth() async throws {
        _ = try GitRunner.run(["remote", "add", "origin", root.appendingPathComponent("unreachable-remote").path], at: root)
        _ = try GitRunner.run(["update-ref", "refs/remotes/origin/main", "HEAD"], at: root)
        _ = try GitRunner.run(["config", "branch.main.remote", "origin"], at: root)
        _ = try GitRunner.run(["config", "branch.main.merge", "refs/heads/main"], at: root)
        let noDifference = try await RepositoryChecker.run(at: root, checkIDs: ["git.push", "git.pull", "git.diverged"])
        XCTAssertEqual(noDifference.exitCode, 3)
        XCTAssertTrue(noDifference.checks.allSatisfy { $0.status == "incomplete" })
        _ = try GitRunner.run(["commit", "--allow-empty", "-m", "Local work"], at: root)
        let report = try await RepositoryChecker.run(at: root, checkIDs: ["git.push"])
        let finding = try XCTUnwrap(report.checks.first?.findings.first)
        XCTAssertTrue(finding.title.contains("provisional"))
        XCTAssertEqual(finding.severity, .information)
        XCTAssertTrue(finding.evidence.contains("1 commits"))
        XCTAssertTrue(finding.evidence.contains("local remote-tracking refs"))
        var snapshot = try GitRepositoryScanner.scan(root, includeDetails: false)
        snapshot.fetchedAt = Date()
        let catalog = RepositoryIssueCatalog(checks: RepositoryIssueCatalog.standardChecks.filter { $0.id == "git.push" })
        let fresh = await catalog.inspect(snapshot)
        XCTAssertEqual(fresh.status(for: "git.push"), .findings)
        XCTAssertEqual(fresh.findings().first?.severity, .attention)
        snapshot.fetchedAt = Date().addingTimeInterval(-301)
        XCTAssertFalse(snapshot.hasFreshRemoteComparison)
        let expired = await catalog.inspect(snapshot)
        XCTAssertEqual(expired.status(for: "git.push"), .incomplete)
        snapshot.fetchedAt = Date(); snapshot.fetchError = "Fetch failed"
        XCTAssertFalse(snapshot.hasFreshRemoteComparison)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/FETCH_HEAD").path))
    }

    func testMissingTrackedFileDiagnosticsCarryRelativePathAcrossChecks() async throws {
        let path = "docs/nested/SKILL.md"
        try FileManager.default.createDirectory(at: root.appendingPathComponent("docs/nested"), withIntermediateDirectories: true)
        try write(path, "Fixture")
        _ = try GitRunner.run(["add", path], at: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent(path))
        // Merge-marker inspection intentionally excludes Markdown documentation.
        let sourcePath = "docs/nested/openai.yaml"
        try write(sourcePath, "fixture: true")
        _ = try GitRunner.run(["add", sourcePath], at: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent(sourcePath))
        let ids: Set<String> = ["docs.brokenLinks", "files.secrets", "files.oversized", "files.mergeMarkers"]
        let report = try await RepositoryChecker.run(at: root, checkIDs: ids)
        for check in report.checks {
            XCTAssertEqual(check.status, "incomplete")
            XCTAssertTrue(check.reason?.contains(check.id == "files.mergeMarkers" ? sourcePath : path) == true)
        }
        XCTAssertTrue(report.checks.allSatisfy { $0.reason?.contains(root.path) == false })
    }

    func testFileChecksRetainRealViolationsWhenAnotherPathIsMissing() async throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try write("a-missing.py", "fixture")
        try write("docs/a-missing.md", "fixture")
        let token = "ghp_" + String(repeating: "a", count: 36)
        try write("z-issue.py", "token = '\(token)'\n<<<<<<< HEAD\nleft\n=======\nright\n>>>>>>> topic\n" + String(repeating: "#", count: 2048))
        try write("docs/z-issue.md", "[Missing](absent.md)")
        try write(".repoman.json", #"{"maximumTrackedFileBytes":1024}"#)
        _ = try GitRunner.run(["add", "."], at: root)
        for path in ["a-missing.py", "docs/a-missing.md"] { try FileManager.default.removeItem(at: root.appendingPathComponent(path)) }
        let ids: Set<String> = ["files.secrets", "files.oversized", "files.mergeMarkers", "docs.brokenLinks"]
        let before = try await RepositoryChecker.run(at: root, checkIDs: ids)
        XCTAssertEqual(before.exitCode, 1)
        for check in before.checks {
            XCTAssertEqual(check.status, "incomplete")
            XCTAssertEqual(check.findings.map(\.subject), [check.id == "docs.brokenLinks" ? "docs/z-issue.md" : "z-issue.py"])
            XCTAssertTrue(check.reason?.contains("missing") == true)
        }
        XCTAssertFalse(String(decoding: try before.json(), as: UTF8.self).contains(token))

        let snapshot = try GitRepositoryScanner.scan(root, includeDetails: false)
        let catalog = RepositoryIssueCatalog(checks: RepositoryIssueCatalog.standardChecks.filter { ids.contains($0.id) })
        let observed = await catalog.inspect(snapshot)
        let oldSecret = try XCTUnwrap(observed.findings().first { $0.checkID == "files.secrets" })
        guard case .present = catalog.verify(oldSecret, in: observed) else { return XCTFail("A readable finding must remain present despite partial coverage") }
        try write("z-issue.py", "print('clean')")
        try write("docs/z-issue.md", "No local links.")
        let partial = await catalog.inspect(try GitRepositoryScanner.scan(root, includeDetails: false))
        XCTAssertTrue(partial.findings().isEmpty)
        guard case .unknown = catalog.verify(oldSecret, in: partial) else { return XCTFail("Missing files must prevent claiming a complete clean scan") }
        for path in ["a-missing.py", "docs/a-missing.md"] { try write(path, "restored") }
        let complete = try await RepositoryChecker.run(at: root, checkIDs: ids)
        XCTAssertEqual(complete.exitCode, 0)
        XCTAssertTrue(complete.checks.allSatisfy { $0.status == "passed" })
    }

    func testFileCheckExceptionsDoNotHideIncompleteCoverage() async throws {
        try write("a-secret.pem", "-----BEGIN PRIVATE KEY-----\nfixture")
        try write("z-missing.py", "fixture")
        _ = try GitRunner.run(["add", "."], at: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("z-missing.py"))
        try write(".repoman.json", #"{"exceptions":{"files.secrets":{"a-secret.pem":"Deliberately invalid teaching fixture"}}}"#)
        let report = try await RepositoryChecker.run(at: root, checkIDs: ["files.secrets"])
        let check = try XCTUnwrap(report.checks.first)
        XCTAssertEqual(check.status, "incomplete")
        XCTAssertTrue(check.findings.isEmpty)
        XCTAssertEqual(check.exceptions["a-secret.pem"], "Deliberately invalid teaching fixture")
        XCTAssertTrue(check.reason?.contains("z-missing.py") == true)
        XCTAssertEqual(report.exitCode, 3)
    }

    func testFileCheckBoundsDiagnosticsWithoutLosingLaterFindings() async throws {
        for index in 0..<7 {
            try write("missing-\(index).py", "fixture")
            _ = try GitRunner.run(["add", "missing-\(index).py"], at: root)
            try FileManager.default.removeItem(at: root.appendingPathComponent("missing-\(index).py"))
        }
        try write("z-key.pem", "-----BEGIN PRIVATE KEY-----\nfixture")
        _ = try GitRunner.run(["add", "z-key.pem"], at: root)
        let report = try await RepositoryChecker.run(at: root, checkIDs: ["files.secrets"])
        let check = try XCTUnwrap(report.checks.first)
        XCTAssertEqual(check.status, "incomplete")
        XCTAssertEqual(check.findings.map(\.subject), ["z-key.pem"])
        XCTAssertTrue(check.reason?.contains("2 additional paths") == true)
        XCTAssertFalse(check.reason?.contains("missing-6.py") == true)
    }

    func testNotApplicableSurvivesCacheAndCannotConfirmAnOldFindingAbsent() async throws {
        let snapshot = try GitRepositoryScanner.scan(root, includeDetails: false)
        let check = RepositoryCheck(id: "example", title: "Example", category: .setup, symbol: "circle", inspect: { _ in
            throw InspectionError.notApplicable("No supported inputs.")
        })
        let catalog = RepositoryIssueCatalog(checks: [check])
        let cacheURL = root.appendingPathComponent("cache.json")
        let cache = RepositoryInspectionCache(url: cacheURL)
        let report = await catalog.inspect(snapshot, cache: cache)
        let restored = RepositoryInspectionCache(url: cacheURL)
        let reused = await restored.reusableResults(for: snapshot, checks: [check])
        guard case .notApplicable = reused["example"]?.result else { return XCTFail("Not-applicable result was not retained") }
        let original = RepositoryFinding(repositoryID: snapshot.id, checkID: "example", title: "Old finding",
                                         evidence: "Old evidence", category: .setup, symbol: "circle")
        guard case .unknown = catalog.verify(original, in: report) else { return XCTFail("Not applicable cannot establish absence") }
        var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as! [String: Any]
        legacy["version"] = 1
        try JSONSerialization.data(withJSONObject: legacy).write(to: cacheURL)
        let outdated = RepositoryInspectionCache(url: cacheURL)
        let invalidated = await outdated.reusableResults(for: snapshot, checks: [check])
        XCTAssertTrue(invalidated.isEmpty, "Legacy passes must be reevaluated under the new reporting rules")
    }

    func testSiblingTargetsSupportGitFilesWithoutOpeningContentsOrFollowingEscapes() throws {
        let parent = root.deletingLastPathComponent()
        let sibling = parent.appendingPathComponent("sibling-" + UUID().uuidString)
        let metadata = parent.appendingPathComponent("metadata-" + UUID().uuidString)
        let outside = parent.appendingPathComponent("private-" + UUID().uuidString)
        defer {
            for url in [sibling, metadata, outside] { try? FileManager.default.removeItem(at: url) }
        }
        _ = try GitRunner.run(["init", "--separate-git-dir", metadata.path, sibling.path], at: root)
        try "Private fixture contents".write(to: outside, atomically: true, encoding: .utf8)
        try "Sibling fixture".write(to: sibling.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: sibling.appendingPathComponent("escape.md"), withDestinationURL: outside)
        let context = RepositoryInspectionContext(snapshot: try GitRepositoryScanner.scan(root, includeDetails: false))
        let prefix = "../" + sibling.lastPathComponent
        XCTAssertTrue(try context.localTargetExists(prefix + "/README.md"))
        XCTAssertTrue(try context.localTargetExists(prefix))
        XCTAssertFalse(try context.localTargetExists(prefix + "/missing.md"))
        XCTAssertThrowsError(try context.readText(prefix + "/README.md"))
        XCTAssertThrowsError(try context.localTargetExists(prefix + "/escape.md")) { error in
            XCTAssertFalse(error.localizedDescription.contains(outside.path))
            XCTAssertFalse(error.localizedDescription.contains("Private fixture contents"))
        }
        XCTAssertThrowsError(try context.localTargetExists("../../outside.md"))
        XCTAssertThrowsError(try context.localTargetExists("../unavailable-" + UUID().uuidString + "/README.md"))
        let alias = root.appendingPathComponent("sibling-link")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: sibling)
        XCTAssertThrowsError(try context.localTargetExists("sibling-link/README.md"))
    }

    func testRemoteReportReflectsRefreshAndFailureWithoutExposingErrors() throws {
        var snapshot = try GitRepositoryScanner.scan(root, includeDetails: false)
        func report(_ snapshot: RepositorySnapshot) -> RepositoryCheckReport {
            RepositoryCheckReport(RepositoryInspectionReport(snapshot: snapshot, results: [:], checkOrder: []),
                                  head: nil, checkerVersion: "fixture")
        }
        XCTAssertTrue(report(snapshot).remoteRefs.contains("No configured Git remotes"))
        _ = try GitRunner.run(["remote", "add", "origin", root.appendingPathComponent("remote").path], at: root)
        snapshot = try GitRepositoryScanner.scan(root, includeDetails: false)
        XCTAssertTrue(report(snapshot).remoteRefs.contains("--fetch"))
        snapshot.fetchedAt = Date()
        XCTAssertTrue(report(snapshot).remoteRefs.contains("successfully refreshed"))
        snapshot.fetchError = "private-provider-error"
        XCTAssertTrue(report(snapshot).remoteRefs.contains("failed"))
        XCTAssertFalse(report(snapshot).remoteRefs.contains("private-provider-error"))
        let result = RepositoryCheck.result([], for: "git.push", snapshot: snapshot)
        guard case .partial(_, let reason) = result else { return XCTFail("A failed fetch cannot establish remote health") }
        XCTAssertTrue(reason.contains("failed"))
        XCTAssertFalse(reason.contains("private-provider-error"))
    }

    func testPathErrorsDoNotExposeResolvedSymlinkTargets() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("private-" + UUID().uuidString)
        try "Private fixture".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.md"), withDestinationURL: outside)
        let context = RepositoryInspectionContext(snapshot: try GitRepositoryScanner.scan(root, includeDetails: false))
        XCTAssertThrowsError(try context.readText("link.md")) { error in
            XCTAssertTrue(error.localizedDescription.contains("link.md:"))
            XCTAssertFalse(error.localizedDescription.contains(outside.path))
            XCTAssertFalse(error.localizedDescription.contains("Private fixture"))
        }
    }
    func testAbsentOptionalInputsAndDisabledNotebookChecksAreExplicit() async throws {
        let report = try await RepositoryChecker.run(at: root, checkIDs: ["access.configuration", "access.localPrivacy", "notebooks.hygiene", "ci.security"])
        XCTAssertEqual(report.exitCode, 0)
        XCTAssertEqual(report.checks.first { $0.id == "notebooks.hygiene" }?.status, "skipped")
        XCTAssertTrue(report.checks.filter { $0.id != "notebooks.hygiene" }.allSatisfy { $0.status == "not_applicable" && $0.reason != nil })
        try write(".repoman.json", #"{"notebooks":{"enabled":true}}"#)
        let enabled = try await RepositoryChecker.run(at: root, checkIDs: ["notebooks.hygiene"])
        XCTAssertEqual(enabled.checks.first?.status, "not_applicable")
        try write(".access.local.toml", "version = 1")
        let invalid = try await RepositoryChecker.run(at: root, checkIDs: ["access.configuration", "access.localPrivacy"])
        XCTAssertEqual(invalid.exitCode, 1)
        XCTAssertFalse(invalid.checks.contains { $0.status == "not_applicable" })
    }

    func testSkippedCheckDoesNotConfirmAnOldFindingAbsent() async throws {
        let snapshot = try GitRepositoryScanner.scan(root, includeDetails: false)
        let check = RepositoryCheck(id: "disabled", title: "Disabled", category: .setup, symbol: "circle", inspect: { _ in
            throw InspectionError.skipped("Explicit policy.")
        })
        let catalog = RepositoryIssueCatalog(checks: [check])
        let report = await catalog.inspect(snapshot)
        XCTAssertEqual(report.status(for: check.id), .skipped)
        let finding = RepositoryFinding(repositoryID: snapshot.id, checkID: check.id, title: "Old", evidence: "Old", category: .setup, symbol: "circle")
        guard case .unknown = catalog.verify(finding, in: report) else { return XCTFail("Disabled verification must remain unknown") }
    }

    func testPrerequisitesAreCoverageMetadataWithCompatibleSelectors() async throws {
        XCTAssertFalse(RepositoryIssueCatalog.standardChecks.contains { $0.id.hasPrefix("inspection.") })
        let alias = try await RepositoryChecker.run(at: root, checkIDs: ["inspection.files"])
        XCTAssertEqual(alias.checks.first?.status, "passed")
        XCTAssertEqual(alias.coverage.first { $0.id == "files" }?.status, "passed")
        _ = try GitRunner.run(["remote", "add", "origin", root.appendingPathComponent("missing-remote").path], at: root)
        _ = try GitRunner.run(["update-ref", "refs/remotes/origin/main", "HEAD"], at: root)
        _ = try GitRunner.run(["branch", "--set-upstream-to=origin/main"], at: root)
        let ids: Set<String> = ["git.push", "git.pull", "git.diverged"]
        let report = try await RepositoryChecker.run(at: root, checkIDs: ids)
        XCTAssertEqual(report.exitCode, 3)
        XCTAssertEqual(report.checks.count, 3)
        XCTAssertTrue(report.checks.allSatisfy { $0.status == "incomplete" })
        XCTAssertEqual(Set(report.coverage.first { $0.id == "remote" }!.affectedCheckIDs), ids)
        let catalog = RepositoryIssueCatalog(checks: RepositoryIssueCatalog.standardChecks.filter { ids.contains($0.id) })
        let observed = await catalog.inspect(try GitRepositoryScanner.scan(root, includeDetails: false))
        XCTAssertEqual(catalog.incompleteItems(in: observed).map { $0.finding.checkID }, ["inspection.remote"])
    }

    func testParsingIsSharedAcrossConcurrentDetectorsAndOptionsStaySeparate() async throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".github/workflows"), withIntermediateDirectories: true)
        try write(".github/workflows/check.yml", "on: [push]\njobs:\n  check:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v4\n      - run: swift test\n")
        let context = RepositoryInspectionContext(snapshot: try GitRepositoryScanner.scan(root, includeDetails: false))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<12 { group.addTask {
                XCTAssertEqual(try context.workflowReferences(".github/workflows/check.yml"), ["actions/checkout@v4"])
                XCTAssertEqual(try context.workflowSteps(".github/workflows/check.yml").count, 2)
            } }
            try await group.waitForAll()
        }
        XCTAssertEqual(context.parsingComputationCount, 3)
        try write("config.toml", "[custom]\nvalue = 1\n")
        XCTAssertTrue(try context.toml("config.toml").values.isEmpty)
        XCTAssertEqual(try context.toml("config.toml", allSections: true).values["custom.value"], "1")
        XCTAssertEqual(context.parsingComputationCount, 5)
    }

    func testParsingFailuresAndBoundsStayExplicit() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".github/workflows"), withIntermediateDirectories: true)
        try write(".github/workflows/bad.yml", "on: push\njobs: &dynamic\n")
        let context = RepositoryInspectionContext(snapshot: try GitRepositoryScanner.scan(root, includeDetails: false))
        for _ in 0..<2 { XCTAssertThrowsError(try context.workflowLines(".github/workflows/bad.yml")) }
        XCTAssertEqual(context.parsingComputationCount, 1)
        let cache = InspectionParsingCache(maximumEntries: 1, maximumBytes: 16)
        let value: String = try cache.value("one", bytes: 1) { "valid" }
        XCTAssertEqual(value, "valid")
        XCTAssertThrowsError(try cache.value("two", bytes: 1) { "overflow" })
    }

}
