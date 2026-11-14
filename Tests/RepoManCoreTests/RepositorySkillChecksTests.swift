import Foundation
import XCTest
@testable import RepoManCore

final class RepositorySkillChecksTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RepoManSkills-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try GitRunner.run(["init", "-b", "main"], at: root)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testCatalogIncludesLocalCheckAndNoSkillsIsNotApplicable() async throws {
        XCTAssertTrue(RepositoryIssueCatalog.standardChecks.contains { $0.id == RepositorySkillChecks.id && !$0.requiresRemoteAccess })
        let report = try await inspect()
        XCTAssertEqual(report.status(for: RepositorySkillChecks.id), .notApplicable)
    }

    func testReusableSkillsRequireOwnerPrefixAndFrontmatterIdentity() async throws {
        try skill("skills/inbox-capture", name: "inbox-capture")
        try skill("skills/private-skills_inbox-flush", name: "private-workflow_inbox-flush")
        let report = try await inspect(remote: "git@github.com:tsilva/private-skills.git")
        XCTAssertEqual(report.findings().count, 2)
        XCTAssertTrue(report.findings().contains { $0.evidence.contains("private-skills_") })
        XCTAssertTrue(report.findings().contains { $0.subject.hasSuffix("#name") })
    }

    func testValidMetadataOverridesRemoteAndNestedMetadataIsIgnored() async throws {
        try write(".repo-metadata.toml", "short-name = 'Compact_Label'\n[nested]\nshort-name = 'wrong'\n")
        try skill(".codex/skills/compact-label_run-checks", name: "compact-label_run-checks")
        try write(".codex/skills/compact-label_run-checks/agents/openai.yaml", "interface:\n  default_prompt: \"Use $compact-label_run-checks for this task.\"\n")
        try await expectStatus(.passed)
        try write(".repo-metadata.toml", "[nested]\nshort-name = 'wrong'\n")
        try await expectStatus(.findings)
    }

    func testInvalidMetadataFallsBackToRemoteInsteadOfTemporaryFolder() async throws {
        try write(".repo-metadata.toml", "short-name = 123\n")
        try skill("skills/fixture_do-work", name: "fixture_do-work")
        try await expectStatus(.passed, remote: "https://github.com/user/fixture.git")
        try write(".repo-metadata.toml", "short-name = 'broken\n")
        try await expectStatus(.passed)
    }

    func testAllSourceLayoutsAndUntrackedFilesAreInspectedButIgnoredVendorsAreNot() async throws {
        for folder in ["skills/fixture_one", ".agents/skills/fixture_two", "agent/.agents/skills/fixture_three", ".codex/skills/fixture_four"] {
            try skill(folder, name: (folder as NSString).lastPathComponent)
        }
        try skill("vendor/third-party/.agents/skills/bad", name: "bad")
        try skill(".codex/skills/.system/bad", name: "bad")
        try skill("fixtures/skills/bad", name: "bad")
        try skill("skills/ignored", name: "ignored")
        try write(".gitignore", "skills/ignored/\n")
        try await expectStatus(.passed)
    }

    func testNameFormatAndLengthBoundaries() async throws {
        let valid = "fixture_" + String(repeating: "a", count: 56)
        try skill("skills/" + valid, name: valid)
        try await expectStatus(.passed)
        for invalid in [valid + "a", "fixture_two_parts", "fixture_Bad", "fixture_bad--name"] {
            try skill("skills/" + invalid, name: invalid)
        }
        let report = try await inspect()
        XCTAssertEqual(Set(report.findings().map { $0.subject.components(separatedBy: "#")[0] }).count, 4)
    }

    func testMissingNameAndStaleDefaultPromptAreFindings() async throws {
        try write("skills/fixture_one/SKILL.md", "---\ndescription: Example\n---\n")
        try skill("skills/fixture_two", name: "fixture_two")
        try write("skills/fixture_two/agents/openai.yaml", "interface:\n  default_prompt: 'Use $old-name for this task.'\n")
        let report = try await inspect()
        XCTAssertEqual(report.findings().count, 2)
        XCTAssertTrue(report.findings().contains { $0.subject.hasSuffix("openai.yaml") })
    }

    func testUnreadableOrDuplicateSourcePreservesOtherFindings() async throws {
        try skill("skills/fixture_missing", name: "fixture_missing")
        _ = try GitRunner.run(["add", "."], at: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("skills/fixture_missing/SKILL.md"))
        try write("skills/fixture_duplicate/SKILL.md", "---\nname: fixture_duplicate\nname: fixture_other\n---\n")
        try skill("skills/invalid", name: "invalid")
        let report = try await inspect()
        XCTAssertEqual(report.status(for: RepositorySkillChecks.id), .incomplete)
        XCTAssertFalse(report.findings().isEmpty)
        XCTAssertTrue(report.unavailableChecks[RepositorySkillChecks.id]?.contains("fixture_missing") == true)
        XCTAssertTrue(report.unavailableChecks[RepositorySkillChecks.id]?.contains("Duplicate") == true)
    }

    func testLocalDiscoveryLinksMatchTheirCanonicalDirectory() async throws {
        try skill("agent/.agents/skills/fixture_one", name: "fixture_one")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".agents/skills"), withIntermediateDirectories: true)
        for name in ["fixture_one", "wrong"] {
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(".agents/skills/" + name).path,
                withDestinationPath: "../../agent/.agents/skills/fixture_one")
        }
        let report = try await inspect()
        XCTAssertEqual(report.findings().map(\.subject), [".agents/skills/wrong"])
    }

    func testExternalDiscoveryLinkDoesNotReadOrRenameProviderSkill() async throws {
        let external = FileManager.default.temporaryDirectory.appendingPathComponent("external-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: external) }
        // Invalid content would be flagged if RepoMan opened this external source.
        try "provider-owned content".write(to: external.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".agents/skills"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".agents/skills/" + external.lastPathComponent), withDestinationURL: external)
        let report = try await inspect()
        XCTAssertEqual(report.status(for: RepositorySkillChecks.id), .passed)
        XCTAssertEqual(try String(contentsOf: external.appendingPathComponent("SKILL.md")), "provider-owned content")
    }

    func testLongRepositoryNameCannotInventAnAbbreviation() async throws {
        try skill("skills/fixture_one", name: "fixture_one")
        let report = try await inspect(remote: "https://github.com/user/a-repository-name-longer-than-twenty.git")
        XCTAssertEqual(report.status(for: RepositorySkillChecks.id), .incomplete)
        XCTAssertTrue(report.findings().isEmpty)
    }

    func testNoRemoteUsesGitRootNameAndNormalizesUnderscores() async throws {
        // Use a short actual Git-root directory, not the snapshot's display/worktree name.
        let short = root.appendingPathComponent("Repo_Label")
        try FileManager.default.createDirectory(at: short, withIntermediateDirectories: true)
        _ = try GitRunner.run(["init", "-b", "main"], at: short)
        let parent = root!
        root = short
        defer { root = parent }
        try skill("skills/repo-label_work", name: "repo-label_work")
        try await expectStatus(.passed, remote: nil)
    }

    func testBrokenLinkAndUnsupportedPromptCannotPass() async throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".codex/skills"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(".codex/skills/fixture_missing").path,
            withDestinationPath: "../../missing")
        try skill("skills/fixture_work", name: "fixture_work")
        try write("skills/fixture_work/agents/openai.yaml", "interface:\n  default_prompt: >-\n    Use $fixture_work.\n")
        let report = try await inspect()
        XCTAssertEqual(report.status(for: RepositorySkillChecks.id), .incomplete)
        XCTAssertTrue(report.unavailableChecks[RepositorySkillChecks.id]?.contains("Discovery target") == true)
    }

    func testPreciseExceptionsAndInspectionLeaveFilesAndIndexUntouched() async throws {
        try skill("skills/unprefixed", name: "unprefixed")
        try write(".repoman.json", #"{"version":1,"exceptions":{"skills.naming":{"skills/unprefixed/SKILL.md":"External compatibility contract","skills/unprefixed/SKILL.md#name":"External compatibility contract"}}}"#)
        _ = try GitRunner.run(["add", "."], at: root)
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let source = try Data(contentsOf: root.appendingPathComponent("skills/unprefixed/SKILL.md"))
        let report = try await inspect()
        XCTAssertEqual(report.status(for: RepositorySkillChecks.id), .passed)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("skills/unprefixed/SKILL.md")), source)
    }

    private func skill(_ directory: String, name: String) throws {
        try write(directory + "/SKILL.md", "---\nname: \(name)\ndescription: A useful fixture.\n---\n# Fixture\n")
    }
    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    private func expectStatus(_ status: RepositoryCheckStatus, remote: String? = "https://github.com/user/fixture.git") async throws {
        let report = try await inspect(remote: remote)
        XCTAssertEqual(report.status(for: RepositorySkillChecks.id), status)
    }
    private func inspect(remote: String? = "https://github.com/user/fixture.git") async throws -> RepositoryInspectionReport {
        let snapshot = RepositorySnapshot(url: root, name: "temporary-worktree", branch: "main", upstream: nil, remoteURL: remote,
            ahead: nil, behind: nil, changes: [], staleBranches: [], worktrees: [], commits: [], checkedAt: Date(),
            rootFiles: try FileManager.default.contentsOfDirectory(atPath: root.path))
        return await RepositoryIssueCatalog(checks: RepositorySkillChecks.checks()).inspect(snapshot)
    }
    func testJSONShortNameSharesThePolicyManifest() async throws {
        try write(".repoman.json", #"{"version":1,"short-name":"Compact_Label","stashAgeDays":90}"#)
        try skill("skills/compact-label_run-checks", name: "compact-label_run-checks")
        try await expectStatus(.passed, remote: "https://github.com/user/long-repository-name-for-fixture.git")
    }

}
