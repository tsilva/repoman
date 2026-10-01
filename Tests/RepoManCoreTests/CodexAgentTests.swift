import Foundation
import XCTest
@testable import RepoManCore

final class CodexAgentTests: XCTestCase {
    private func fixture() throws -> (URL, RepairTask) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Codex fixture \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("fake-codex")
        try Self.script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let snapshot = RepositorySnapshot(url: root, name: "fixture", branch: "main", upstream: nil, remoteURL: nil,
            ahead: nil, behind: nil, changes: [], staleBranches: [], worktrees: [], commits: [])
        let finding = RepositoryFinding(repositoryID: snapshot.id, checkID: "files.readme", title: "README", evidence: "Missing", category: .documentation, symbol: "doc")
        var task = RepairTask(finding: finding, repository: snapshot, prompt: "Write a README")
        task.codexStorageVersion = 1
        return (executable, task)
    }
    private func agent(at path: URL) -> CodexAgent {
        CodexAgent(executable: { path.path }, storage: CodexStorage(homeDirectory: path.deletingLastPathComponent().appendingPathComponent("codex-home")))
    }

    func testSignedOutPrivateHomeShowsIsolatedLoginCommandBeforeCreatingThread() async throws {
        let (path, task) = try fixture()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let root = path.deletingLastPathComponent()
        try "signed-out".write(to: root.appendingPathComponent("settings"), atomically: true, encoding: .utf8)
        do {
            _ = try await agent(at: path).run(task) { _ in }
            XCTFail("Expected sign-in requirement")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Sign in to Codex for RepoMan"))
            XCTAssertTrue(error.localizedDescription.contains("env CODEX_HOME="))
            XCTAssertTrue(error.localizedDescription.contains(root.appendingPathComponent("codex-home").path))
            XCTAssertTrue(error.localizedDescription.contains("cli_auth_credentials_store=\"file\""))
        }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("requests"), encoding: .utf8), "account/read\n")
    }

    func testMigratedPaginatedTranscriptRebuildsPrivateTurnIndexWithoutInference() async throws {
        let (path, initial) = try fixture()
        let root = path.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try "migration".write(to: root.appendingPathComponent("settings"), atomically: true, encoding: .utf8)
        let legacy = root.appendingPathComponent("legacy-home")
        let sessions = legacy.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let header: [String: Any] = ["type": "session_meta", "payload": ["id": "fixture-thread", "cwd": root.path]]
        try JSONSerialization.data(withJSONObject: header).write(to: sessions.appendingPathComponent("rollout-fixture-thread.jsonl"))
        var task = initial; task.threadID = "fixture-thread"; task.turnID = "fixture-turn"; task.codexStorageVersion = nil
        let agent = CodexAgent(executable: { path.path }, storage: CodexStorage(homeDirectory: root.appendingPathComponent("codex-home"), legacyHomeDirectory: legacy))
        let outcome = try await agent.recover(task)
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("requests"), encoding: .utf8), "thread/read\nthread/resume\nthread/read\n")
    }

    func testPinnedModelRepositoryPermissionsAndDeniedEscalationsWithStreamingQuestionsAndDiff() async throws {
        let (path, task) = try fixture()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let agent = agent(at: path)
        let events = AgentEventCapture()
        let outcome = try await agent.run(task) { event in
            await events.append(event)
            if case .interaction(let interaction) = event {
                try? await agent.respond(to: interaction, answers: ["scope": "README"], approved: true)
            }
        }
        XCTAssertEqual(outcome, .completed)
        let captured = await events.values
        XCTAssertTrue(captured.contains { if case .session(let thread, let turn) = $0 { return thread == "fixture-thread" && turn == "fixture-turn" }; return false })
        XCTAssertTrue(captured.contains { if case .diff(let diff) = $0 { return diff.contains("README.md") }; return false })
        XCTAssertEqual(captured.filter { if case .interaction = $0 { return true }; return false }.count, 1)
        XCTAssertTrue(captured.contains {
            if case .activity(let message) = $0 { return message.contains("Blocked a request to expand") }; return false
        })
        let question = captured.compactMap { event -> AgentQuestion? in
            if case .interaction(let interaction) = event { return interaction.questions.first }; return nil
        }.first
        XCTAssertEqual(question?.header, "Scope")
        XCTAssertEqual(question?.optionDescriptions?["README"], "Update the project documentation.")
        let commands = captured.compactMap { event -> RepairConversationEntry? in
            if case .conversation(let entry) = event, entry.kind == .command { return entry }; return nil
        }
        XCTAssertEqual(commands.map(\.id), ["fixture-turn:shell-1", "fixture-turn:shell-2", "fixture-turn:shell-2", "fixture-turn:shell-1"])
        XCTAssertEqual(commands.last?.text, "git status --short")
        XCTAssertEqual(commands.last?.output, " M README.md\n")
        XCTAssertEqual(commands.last?.exitCode, 0)
        XCTAssertEqual(commands.first { $0.id == "fixture-turn:shell-2" && $0.status == "failed" }?.exitCode, 1)
        XCTAssertTrue(captured.contains {
            if case .conversationDelta(let id, let kind, let text) = $0 {
                return id == "fixture-turn:message-1" && kind == .assistant && text == "README created."
            }; return false
        })
        XCTAssertTrue(captured.contains {
            if case .conversationDelta(let id, let kind, let text) = $0 {
                return id == "fixture-turn:shell-1" && kind == .command && text == " M README.md\n"
            }; return false
        })
        XCTAssertTrue(captured.contains {
            if case .conversation(let entry) = $0 {
                return entry.id == "fixture-turn:message-1" && entry.kind == .assistant && entry.text == "**README created.**"
            }; return false
        })
    }
    func testFollowUpResumesTheSameThreadAndSendsOnlyTheNewUserRequest() async throws {
        let (path, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let firstEvents = AgentEventCapture()
        let agent = agent(at: path)
        _ = try await agent.run(original) { event in
            await firstEvents.append(event)
            if case .interaction(let interaction) = event {
                try? await agent.respond(to: interaction, answers: ["scope": "README"], approved: false)
            }
        }
        var task = original
        task.threadID = "fixture-thread"; task.pendingPrompt = "FOLLOWUP_ONLY"
        let events = AgentEventCapture()
        let outcome = try await agent.run(task) { event in
            await events.append(event)
            if case .interaction(let interaction) = event {
                try? await agent.respond(to: interaction, answers: ["scope": "README"], approved: false)
            }
        }
        XCTAssertEqual(outcome, .completed)
        let first = await firstEvents.values
        let second = await events.values
        let firstIDs = Set(first.compactMap { event -> String? in if case .conversation(let entry) = event { return entry.id }; return nil })
        let secondIDs = Set(second.compactMap { event -> String? in if case .conversation(let entry) = event { return entry.id }; return nil })
        XCTAssertFalse(firstIDs.isEmpty)
        XCTAssertTrue(firstIDs.isDisjoint(with: secondIDs), "Turn-scoped item IDs must retain both turns")
        let captured = await events.values
        XCTAssertTrue(captured.contains { if case .session(let id, let turn) = $0 { return id == "fixture-thread" && turn == "fixture-turn-2" }; return false })
    }
    func testNewChatsAreNamedBeforeInferenceAndFollowUpsKeepTheirTitle() async throws {
        let (path, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let root = path.deletingLastPathComponent()
        let agent = agent(at: path)
        for task in [original, { () -> RepairTask in
            var task = original
            task.threadID = "fixture-thread"; task.pendingPrompt = "FOLLOWUP_ONLY"
            return task
        }()] {
            _ = try await agent.run(task) { event in
                if case .interaction(let interaction) = event {
                    try? await agent.respond(to: interaction, answers: ["scope": "README"], approved: true)
                }
            }
        }
        let requests = try String(contentsOf: root.appendingPathComponent("requests"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(Array(requests.prefix(4)), ["account/read", "thread/start", "thread/name/set", "turn/start"])
        XCTAssertEqual(requests.filter { $0 == "thread/name/set" }.count, 1)
        let resume = try XCTUnwrap(requests.firstIndex(of: "thread/resume"))
        XCTAssertEqual(requests[resume + 1], "turn/start")
    }
    func testRepositoryBoundaryInstructionsAccompanySelectedPromptAndEveryFollowUp() async throws {
        let (path, original) = try fixture()
        let root = path.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = agent(at: path)
        var task = original
        task.pendingPrompt = "Write a README; search ../sibling for examples."
        let selectedPrompt = task.agentPrompt
        _ = try await agent.run(task) { event in
            if case .interaction(let interaction) = event {
                try? await agent.respond(to: interaction, answers: ["scope": "README"], approved: false)
            }
        }
        task.threadID = "fixture-thread"
        task.pendingPrompt = "FOLLOWUP_ONLY: update the README."
        let followUpPrompt = task.agentPrompt
        _ = try await agent.run(task) { event in
            if case .interaction(let interaction) = event {
                try? await agent.respond(to: interaction, answers: ["scope": "README"], approved: false)
            }
        }
        let turns = try String(contentsOf: root.appendingPathComponent("turn-requests"), encoding: .utf8)
            .split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        XCTAssertEqual(turns.count, 2)
        for (turn, prompt) in zip(turns, [selectedPrompt, followUpPrompt]) {
            XCTAssertEqual(turn["params"]["input"].array.first?["text"].string, prompt)
            let instructions = try XCTUnwrap(turn["params"]["collaborationMode"]["settings"]["developer_instructions"].string)
            XCTAssertTrue(instructions.hasPrefix("MANDATORY REPOSITORY BOUNDARY"))
            XCTAssertTrue(instructions.contains(root.resolvingSymlinksInPath().standardizedFileURL.path))
            XCTAssertTrue(instructions.contains("STRICTLY FORBIDDEN"))
            XCTAssertTrue(instructions.contains("reading, listing, searching"))
            XCTAssertTrue(instructions.contains("symlinks"))
            XCTAssertTrue(instructions.contains("STOP before that step and use request_user_input"))
            XCTAssertTrue(instructions.contains("Wait for the user's explicit approval"))
            XCTAssertTrue(instructions.contains("does not authorize bypassing the enforced permission profile"))
            XCTAssertFalse(instructions.contains("../sibling"), "The selected prompt must remain separate from mandatory instructions")
        }
    }
    func testNamingFailureDoesNotBlockRepair() async throws {
        let (path, task) = try fixture()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        try "name-error".write(to: path.deletingLastPathComponent().appendingPathComponent("settings"),
                               atomically: true, encoding: .utf8)
        let agent = agent(at: path)
        let events = AgentEventCapture()
        let outcome = try await agent.run(task) { event in
            await events.append(event)
            if case .interaction(let interaction) = event {
                try? await agent.respond(to: interaction, answers: ["scope": "README"], approved: true)
            }
        }
        XCTAssertEqual(outcome, .completed)
        let captured = await events.values
        XCTAssertTrue(captured.contains {
            if case .activity(let message) = $0 { return message.contains("Could not name the Codex chat") }; return false
        })
    }
    func testArchivedFollowUpUnarchivesAndResumesTheSameThreadOnce() async throws {
        let (path, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let root = path.deletingLastPathComponent()
        try "archived".write(to: root.appendingPathComponent("settings"), atomically: true, encoding: .utf8)
        var task = original
        task.threadID = "fixture-thread"; task.pendingPrompt = "FOLLOWUP_ONLY"
        let agent = agent(at: path)
        let events = AgentEventCapture()
        let outcome = try await agent.run(task) { event in
            await events.append(event)
            if case .interaction(let interaction) = event {
                try? await agent.respond(to: interaction, answers: ["scope": "README"], approved: true)
            }
        }
        XCTAssertEqual(outcome, .completed)
        let requests = try String(contentsOf: root.appendingPathComponent("requests"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(Array(requests.prefix(5)), ["account/read", "thread/resume", "thread/unarchive", "thread/resume", "turn/start"])
        XCTAssertEqual(requests.filter { $0 == "turn/start" }.count, 1)
        let captured = await events.values
        XCTAssertTrue(captured.contains { if case .session(let id, let turn) = $0 {
            return id == "fixture-thread" && turn == "fixture-turn-2"
        }; return false })
    }
    func testUnarchiveFailuresAreSurfacedWithoutRepeatedRetriesOrNewTurns() async throws {
        for (settings, hasThread, expectedRequests, expectedError) in [
            ("resume-error", true, ["thread/resume"], "Fixture resume failure"),
            ("unarchive-error", true, ["thread/resume", "thread/unarchive"], "Fixture unarchive failure"),
            ("still-archived", true, ["thread/resume", "thread/unarchive", "thread/resume"], "is archived"),
            ("archived", false, ["thread/start"], "is archived")
        ] {
            let (path, original) = try fixture()
            defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
            let root = path.deletingLastPathComponent()
            try settings.write(to: root.appendingPathComponent("settings"), atomically: true, encoding: .utf8)
            var task = original
            if hasThread { task.threadID = "fixture-thread"; task.pendingPrompt = "FOLLOWUP_ONLY" }
            do {
                _ = try await agent(at: path).run(task) { _ in }
                XCTFail("Expected failure for \(settings)")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(expectedError), error.localizedDescription)
            }
            let requests = try String(contentsOf: root.appendingPathComponent("requests"), encoding: .utf8)
                .split(separator: "\n").map(String.init)
            XCTAssertEqual(requests, ["account/read"] + expectedRequests, settings)
        }
    }
    func testRecoveryWithoutAcknowledgedTurnDoesNotMistakeAnOlderTurnForTheNewMessage() async throws {
        let (path, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        var task = original; task.threadID = "fixture-thread"; task.pendingPrompt = "Not acknowledged"
        let outcome = try await agent(at: path).recover(task)
        XCTAssertEqual(outcome, .notRun)
    }
    func testRejectsUnexpectedResolvedModelOrEffortBeforeInference() async throws {
        for settings in ["wrong-model", "wrong-effort"] {
            let (path, task) = try fixture()
            defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
            try settings.write(to: path.deletingLastPathComponent().appendingPathComponent("settings"),
                               atomically: true, encoding: .utf8)
            do {
                _ = try await agent(at: path).run(task) { _ in }
                XCTFail("Unexpected settings were accepted: \(settings)")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("GPT-6.1 Sol with high reasoning effort"), error.localizedDescription)
            }
        }
    }
    func testCancellationInterruptsTheActiveTurn() async throws {
        let (path, task) = try fixture()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let agent = agent(at: path)
        let outcome = try await agent.run(task) { event in
            if case .interaction = event { await agent.cancel() }
        }
        XCTAssertEqual(outcome, .cancelled)
    }
    func testFailedTurnReportsFailureSeparatelyFromActivity() async throws {
        let (path, initial) = try fixture()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let task = RepairTask(finding: initial.finding,
            repository: RepositorySnapshot(url: initial.repositoryURL, name: "fixture", branch: "main", upstream: nil,
                remoteURL: nil, ahead: nil, behind: nil, changes: [], staleBranches: [], worktrees: [], commits: []),
            prompt: "FORCE_FAILURE")
        let events = AgentEventCapture()
        let outcome = try await agent(at: path).run(task) { await events.append($0) }
        XCTAssertEqual(outcome, .failed)
        let captured = await events.values
        XCTAssertTrue(captured.contains { if case .failure(let message) = $0 { return message == "Fixture failure" }; return false })
    }

    func testRecoveryReadsSavedTurnWithoutStartingAnother() async throws {
        let (path, initial) = try fixture()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        var task = initial; task.threadID = "fixture-thread"; task.turnID = "fixture-turn"
        let agent = agent(at: path)
        let events = AgentEventCapture()
        let outcome = try await agent.recover(task) { await events.append($0) }
        XCTAssertEqual(outcome, .completed)
        let captured = await events.values
        XCTAssertTrue(captured.contains { if case .conversation(let entry) = $0 {
            return entry.id == "fixture-turn:recovered-message" && entry.text == "Saved final reply"
        }; return false })
    }
    func testAsyncQuestionsAreInteractiveDuringStreamingAndRecovery() async throws {
        for recovering in [false, true] {
            let (path, initial) = try fixture()
            let root = path.deletingLastPathComponent()
            defer { try? FileManager.default.removeItem(at: root) }
            try "async-question".write(to: root.appendingPathComponent("settings"), atomically: true, encoding: .utf8)
            var task = initial
            if recovering { task.threadID = "fixture-thread"; task.turnID = "fixture-turn" }
            let agent = agent(at: path)
            let events = AgentEventCapture()
            let outcome: RepairExecutionOutcome
            if recovering { outcome = try await agent.recover(task) { await events.append($0) } }
            else { outcome = try await agent.run(task) { await events.append($0) } }
            XCTAssertEqual(outcome, .completed)
            let captured = await events.values
            let interactions = captured.compactMap { event -> AgentInteraction? in
                if case .interaction(let interaction) = event { return interaction }; return nil
            }
            XCTAssertEqual(interactions.count, 1, "Async questions must not be flattened into prose or duplicated")
            let interaction = try XCTUnwrap(interactions.first)
            XCTAssertEqual(interaction.id, "fixture-turn:async-question")
            XCTAssertTrue(interaction.requiresFollowUp)
            XCTAssertEqual(interaction.questions.map(\.question), ["What should I do with this stash?", "Any other constraints?"])
            XCTAssertEqual(interaction.questions.first?.options, ["Keep the stash (Recommended)", "Delete only this stash"])
            XCTAssertEqual(Set(interaction.questions.map(\.id)).count, 2)
            let requests = try String(contentsOf: root.appendingPathComponent("requests"), encoding: .utf8)
            XCTAssertFalse(requests.contains("turn/steer"))
            if recovering { XCTAssertEqual(requests.trimmingCharacters(in: .whitespacesAndNewlines), "thread/read") }
        }
    }
    func testRecoveryDoesNotReopenAnsweredAsyncQuestion() async throws {
        let (path, initial) = try fixture()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        try "async-question".write(to: path.deletingLastPathComponent().appendingPathComponent("settings"), atomically: true, encoding: .utf8)
        var task = initial; task.threadID = "fixture-thread"; task.turnID = "fixture-turn"
        task.answeredQuestionIDs = ["fixture-turn:async-question"]
        let events = AgentEventCapture()
        _ = try await agent(at: path).recover(task) { await events.append($0) }
        let captured = await events.values
        XCTAssertFalse(captured.contains { if case .interaction = $0 { return true }; return false })
        XCTAssertTrue(captured.contains { if case .conversation(let entry) = $0 { return entry.id == "fixture-turn:async-question" }; return false })
    }
    func testRecoveryUpdatesLegacyItemsInPlace() async throws {
        let (path, initial) = try fixture()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        var task = initial; task.threadID = "fixture-thread"; task.turnID = "fixture-turn"
        task.conversation = [RepairConversationEntry(id: "recovered-message", kind: .assistant, text: "Partial")]
        let events = AgentEventCapture()
        _ = try await agent(at: path).recover(task) { await events.append($0) }
        let captured = await events.values
        XCTAssertTrue(captured.contains { if case .conversation(let entry) = $0 {
            return entry.id == "recovered-message" && entry.text == "Saved final reply"
        }; return false })
    }
    func testInvalidExecutableProducesActionableFailure() {
        XCTAssertThrowsError(try CodexAgent.locateExecutable(configured: "/not/a/codex"))
    }
    func testQuestionMetadataKeepsLegacySavedQuestionsReadable() throws {
        let legacy = Data(#"{"id":"scope","question":"Which file?","options":["README"]}"#.utf8)
        let question = try JSONDecoder().decode(AgentQuestion.self, from: legacy)
        XCTAssertNil(question.header)
        XCTAssertNil(question.optionDescriptions)
        let detailed = AgentQuestion(id: "scope", question: "Which file?", options: ["README"],
            header: "Scope", optionDescriptions: ["README": "Update documentation."])
        XCTAssertEqual(try JSONDecoder().decode(AgentQuestion.self, from: JSONEncoder().encode(detailed)), detailed)
        let legacyInteraction = Data(#"{"id":"request","kind":"questions","title":"Scope","details":"","questions":[{"id":"scope","question":"Which file?","options":["README"]}]}"#.utf8)
        let interaction = try JSONDecoder().decode(AgentInteraction.self, from: legacyInteraction)
        XCTAssertNil(interaction.delivery)
        XCTAssertFalse(interaction.requiresFollowUp)
    }
    func testEmptyAnswerLeavesQuestionPendingUntilExplicitReply() async throws {
        let (path, task) = try fixture()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let agent = agent(at: path)
        let outcome = try await agent.run(task) { event in
            if case .interaction(let interaction) = event {
                do {
                    try await agent.respond(to: interaction, answers: ["scope": "  "], approved: true)
                    XCTFail("A blank answer must not resolve the question")
                } catch {
                    XCTAssertTrue(error.localizedDescription.contains("Answer each agent question"))
                }
                try? await agent.respond(to: interaction, answers: ["scope": "README"], approved: false)
                do {
                    try await agent.respond(to: interaction, answers: ["scope": "README"], approved: false)
                    XCTFail("The request must only be answered once")
                } catch {
                    XCTAssertTrue(error.localizedDescription.contains("no longer active"))
                }
            }
        }
        XCTAssertEqual(outcome, .completed)
    }
    func testInstalledCodexReadOnlyHandshake() async throws {
        guard ProcessInfo.processInfo.environment["REPOMAN_VERIFY_CODEX"] == "1" else {
            throw XCTSkip("Opt in to a read-only check of the installed Codex app-server.")
        }
        let (path, initial) = try fixture()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        var task = initial; task.threadID = "repoman-nonexistent-\(UUID().uuidString)"; task.turnID = "missing-turn"
        do {
            _ = try await CodexAgent(storage: CodexStorage(homeDirectory: path.deletingLastPathComponent().appendingPathComponent("codex-home"))).recover(task)
            XCTFail("An invented thread unexpectedly existed")
        } catch {
            let message = error.localizedDescription.lowercased()
            XCTAssertTrue(message.contains("thread") || message.contains("rollout") || message.contains("session"), message)
            XCTAssertFalse(message.contains("disconnected during initialize"), message)
        }
    }

    func testInstalledCodexPrivateHomeBlocksUnauthenticatedInference() async throws {
        guard ProcessInfo.processInfo.environment["REPOMAN_VERIFY_CODEX"] == "1" else {
            throw XCTSkip("Opt in to an installed Codex check of isolated storage and sign-in preflight.")
        }
        let (path, task) = try fixture()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let home = path.deletingLastPathComponent().appendingPathComponent("codex-home")
        let agent = CodexAgent(storage: CodexStorage(homeDirectory: home))
        let events = AgentEventCapture()
        do {
            _ = try await agent.run(task) { await events.append($0) }
            XCTFail("An empty private home must require sign-in before inference")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Sign in to Codex for RepoMan"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains(home.path))
        }
        let captured = await events.values
        XCTAssertFalse(captured.contains { if case .session = $0 { return true }; return false })
    }

    func testMissingOrDifferentPermissionsBlockNewAndResumedThreadsBeforeInference() async throws {
        for setting in ["missing-profile", "wrong-profile", "wrong-approval", "wrong-cwd", "wrong-sandbox", "outside-root", "outside-temp"] {
            for resume in [false, true] {
                let (path, initial) = try fixture()
                let root = path.deletingLastPathComponent()
                defer { try? FileManager.default.removeItem(at: root) }
                try setting.write(to: root.appendingPathComponent("settings"), atomically: true, encoding: .utf8)
                var task = initial
                if resume { task.threadID = "fixture-thread"; task.pendingPrompt = "FOLLOWUP_ONLY" }
                do {
                    _ = try await agent(at: path).run(task) { _ in }
                    XCTFail("An unenforced permission profile must block inference")
                } catch {
                    XCTAssertTrue(error.localizedDescription.contains("permission profile"), error.localizedDescription)
                }
                let requests = try String(contentsOf: root.appendingPathComponent("requests"), encoding: .utf8)
                XCTAssertFalse(requests.contains("turn/start"))
                XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".repoman-runtime-") })
            }
        }
    }

    func testRunRemovesItsPrivateTemporaryDirectory() async throws {
        let (path, task) = try fixture()
        let root = path.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = agent(at: path)
        _ = try await agent.run(task) { event in
            if case .interaction(let interaction) = event {
                try? await agent.respond(to: interaction, answers: ["scope": "README"], approved: true)
            }
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".repoman-runtime-") })
    }

    func testInstalledSandboxAllowsRepositoryWorkAndDeniesOutsideFilesAndSymlinks() throws {
        guard ProcessInfo.processInfo.environment["REPOMAN_VERIFY_CODEX"] == "1" else {
            throw XCTSkip("Opt in to an OS-enforced check of installed Codex permissions.")
        }
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("RepoMan sandbox \(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let root = base.appendingPathComponent("repo with spaces = café")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for name in [".git", ".codex", ".agents"] {
            try fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false)
        }
        _ = try GitRunner.run(["init", "--quiet"], at: root)
        let outside = base.appendingPathComponent("outside")
        try "fixture".write(to: outside, atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        let binary = try CodexAgent.locateExecutable()
        let permissions = try CodexRepositoryPermissions(repositoryURL: root, executable: binary)
        defer { permissions.cleanUp() }
        let script = #"""
        set -eu
        printf allowed > inside
        printf allowed > .git/inside
        printf allowed > .codex/inside
        printf allowed > .agents/inside
        printf allowed > "$TMPDIR/inside"
        git add inside
        git -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false commit --no-verify -qm 'Sandbox fixture'
        for target in "$1" escape; do
            if cat "$target" >/dev/null 2>&1; then exit 10; fi
            if (printf forbidden > "$target") 2>/dev/null; then exit 11; fi
        done
        """#
        let result = try runSandbox(binary: binary, permissions: permissions, script: script, arguments: [outside.path])
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "fixture")
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("inside").path))
    }

    func testPermissionOverridesDoNotGrantOutsideTargetsOfProtectedDirectorySymlinks() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("RepoMan symlinks \(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let root = base.appendingPathComponent("repo")
        let outside = base.appendingPathComponent("outside")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: false)
        for name in [".git", ".codex", ".agents"] {
            try fm.createSymbolicLink(at: root.appendingPathComponent(name), withDestinationURL: outside)
        }
        let permissions = try CodexRepositoryPermissions(repositoryURL: root, executable: URL(fileURLWithPath: "/bin/sh"))
        defer { permissions.cleanUp() }
        let definition = try XCTUnwrap(permissions.arguments.first { $0.hasPrefix("permissions.") })
        XCTAssertFalse(definition.contains(outside.resolvingSymlinksInPath().path))
        for name in [".git", ".codex", ".agents"] { XCTAssertFalse(definition.contains("\"\(name)\"=")) }
        XCTAssertEqual(permissions.temporaryDirectory.deletingLastPathComponent(), root.resolvingSymlinksInPath())
    }

    func testUnsafeSandboxPathsFailBeforeCreatingRuntimeFiles() throws {
        for path in ["/tmp/repo\"quoted", "/tmp/repo\\path", "/tmp/repo\nnewline"] {
            XCTAssertThrowsError(try CodexRepositoryPermissions(repositoryURL: URL(fileURLWithPath: path),
                                                               executable: URL(fileURLWithPath: "/bin/sh"))) { error in
                XCTAssertTrue(error.localizedDescription.contains("cannot safely sandbox"))
            }
        }
    }

    private func runSandbox(binary: URL, permissions: CodexRepositoryPermissions, script: String,
                            arguments: [String] = []) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["sandbox", "-C", permissions.repositoryURL.path, "-P", permissions.id] + permissions.arguments +
            ["--", "/bin/sh", "-c", script, "repoman-permissions-test"] + arguments
        process.currentDirectoryURL = permissions.repositoryURL
        process.environment = ProcessInfo.processInfo.environment.merging(permissions.environment, uniquingKeysWith: { _, override in override })
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 20)
        timer.setEventHandler { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        timer.resume()
        defer { timer.cancel() }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    private static let script = #"""
#!/usr/bin/python3
import sys, json, os
from pathlib import Path
assert sys.argv[1:4] == ['app-server', '--listen', 'stdio://']
overrides = {}
for flag, entry in zip(sys.argv[4::2], sys.argv[5::2]):
    assert flag == '-c'
    key, value = entry.split('=', 1)
    overrides[key] = value
profile = json.loads(overrides['default_permissions']) if 'default_permissions' in overrides else None
assert json.loads(overrides['cli_auth_credentials_store']) == 'file'
codex_home = Path(os.environ['CODEX_HOME'])
assert codex_home.resolve() == (Path(__file__).parent / 'codex-home').resolve()
assert codex_home.stat().st_mode & 0o777 == 0o700
with (Path(__file__).parent / 'homes').open('a') as log:
    log.write(str(codex_home) + '\n')
if profile:
    assert profile.startswith('repoman-')
    assert json.loads(overrides['approval_policy']) == 'never'
    policy = overrides['permissions.' + profile]
    assert '\":minimal\"=\"read\"' in policy
    assert '\".\"=\"write\"' in policy
    assert '\"enabled\"=true' in policy
    assert 'extends' not in policy
    assert ':root' not in policy and ':tmpdir' not in policy and ':slash_tmp' not in policy
    assert any(alias in policy for alias in [str(Path(__file__).parent), str(Path(__file__).parent.resolve())])
    temporary = Path(os.environ['TMPDIR'])
    assert temporary.is_dir() and temporary.parent.resolve() == Path(__file__).parent.resolve()
    assert temporary.stat().st_mode & 0o777 == 0o700
    assert str(temporary) in overrides['shell_environment_policy.set']
def read():
    line = sys.stdin.readline()
    if not line: sys.exit(0)
    value = json.loads(line)
    if 'method' in value and value['method'] not in ['initialize', 'initialized']:
        with (Path(__file__).parent / 'requests').open('a') as log:
            log.write(value['method'] + '\n')
    return value
def send(value):
    print(json.dumps(value), flush=True)
def result(request, value):
    send({'id': request['id'], 'result': value})
settings_path = Path(__file__).parent / 'settings'
settings = settings_path.read_text() if settings_path.exists() else ''
async_question = {'id': 'async-question', 'type': 'agentMessage', 'text': 'What should I do with this stash?\n- Keep the stash (Recommended)\n- Delete only this stash', 'phase': 'final_answer', 'delivery': 'async', 'questions': [{'title': 'What should I do with this stash?', 'options': ['Keep the stash (Recommended)', 'Delete only this stash']}, {'title': 'Any other constraints?'}]}
request = read()
assert request['method'] == 'initialize'
assert request['params']['clientInfo']['name'] == 'repoman'
result(request, {})
assert read()['method'] == 'initialized'
request = read()
if request['method'] == 'thread/read':
    assert request['params']['threadId'] == 'fixture-thread'
    if settings == 'migration':
        result(request, {'thread': {'id': 'fixture-thread', 'historyMode': 'paginated', 'turns': []}})
        request = read()
        assert request['method'] == 'thread/resume'
        assert request['params']['approvalPolicy'] == 'never'
        assert request['params']['sandbox'] == 'read-only'
        assert request['params']['cwd'] == str(Path(__file__).parent)
        result(request, {'thread': {'id': 'fixture-thread'}})
        request = read()
        assert request['method'] == 'thread/read'
    item = async_question if settings == 'async-question' else {'id': 'recovered-message', 'type': 'agentMessage', 'text': 'Saved final reply'}
    result(request, {'thread': {'id': 'fixture-thread', 'turns': [{'id': 'fixture-turn', 'status': 'completed', 'items': [item]}]}})
    sys.exit(0)
assert request['method'] == 'account/read'
assert request['params'] == {'refreshToken': False}
result(request, {'account': None if settings == 'signed-out' else {'type': 'chatgpt'}, 'requiresOpenaiAuth': True})
request = read()
resuming = request['method'] == 'thread/resume'
assert request['method'] in ['thread/start', 'thread/resume']
if resuming:
    assert request['params']['threadId'] == 'fixture-thread'
else:
    assert request['params']['allowProviderModelFallback'] is False
assert request['params']['permissions'] == profile
assert 'sandbox' not in request['params']
assert request['params']['approvalPolicy'] == 'never'
assert request['params']['model'] == 'gpt-6.1-sol'
assert request['params']['config']['model_reasoning_effort'] == 'high'
assert request['params']['config']['features.default_mode_request_user_input'] is True
settings_path = Path(__file__).parent / 'settings'
settings = settings_path.read_text() if settings_path.exists() else ''
if settings == 'resume-error':
    send({'id': request['id'], 'error': {'code': -32000, 'message': 'Fixture resume failure'}})
    read()  # Any further request is a test failure.
    sys.exit(1)
if settings in ['archived', 'unarchive-error', 'still-archived']:
    archived_message = 'session fixture-thread is archived. Run `codex unarchive fixture-thread` to unarchive it first.'
    send({'id': request['id'], 'error': {'code': -32000, 'message': archived_message}})
    original_request = request
    request = read()
    assert resuming
    assert request['method'] == 'thread/unarchive'
    assert request['params'] == {'threadId': 'fixture-thread'}
    if settings == 'unarchive-error':
        send({'id': request['id'], 'error': {'code': -32000, 'message': 'Fixture unarchive failure'}})
        read()
        sys.exit(1)
    send({'method': 'thread/unarchived', 'params': {'threadId': 'fixture-thread'}})
    result(request, {'thread': {'id': 'fixture-thread'}})
    request = read()
    assert request['method'] == original_request['method']
    assert request['params'] == original_request['params']
    if settings == 'still-archived':
        send({'id': request['id'], 'error': {'code': -32000, 'message': archived_message}})
        read()
        sys.exit(1)
result(request, {'thread': {'id': 'fixture-thread'},
                 'model': 'other-model' if settings == 'wrong-model' else 'gpt-6.1-sol',
                 'activePermissionProfile': None if settings == 'missing-profile' else {'id': ':danger-full-access' if settings == 'wrong-profile' else profile},
                 'approvalPolicy': 'on-request' if settings == 'wrong-approval' else 'never',
                 'cwd': '/' if settings == 'wrong-cwd' else request['params']['cwd'],
                 'sandbox': {'type': 'dangerFullAccess' if settings == 'wrong-sandbox' else 'workspaceWrite',
                             'writableRoots': ['/'] if settings == 'outside-root' else [],
                             'excludeSlashTmp': settings != 'outside-temp', 'excludeTmpdirEnvVar': True},
                 'reasoningEffort': 'low' if settings == 'wrong-effort' else 'high'})
request = read()
if not resuming:
    assert request['method'] == 'thread/name/set'
    assert request['params'] == {'threadId': 'fixture-thread', 'name': '[fixture] Fix README'}
    if settings == 'name-error':
        send({'id': request['id'], 'error': {'code': -32601, 'message': 'Naming unavailable'}})
    else:
        send({'method': 'thread/name/updated', 'params': request['params']})
        result(request, {})
    request = read()
assert request['method'] == 'turn/start'
with (Path(__file__).parent / 'turn-requests').open('a') as log:
    log.write(json.dumps(request) + '\n')
assert request['params']['model'] == 'gpt-6.1-sol'
assert request['params']['effort'] == 'high'
assert request['params']['approvalPolicy'] == 'never'
assert request['params']['permissions'] == profile
assert 'sandboxPolicy' not in request['params']
mode = request['params']['collaborationMode']
assert mode['mode'] == 'default'
assert mode['settings']['model'] == 'gpt-6.1-sol'
assert mode['settings']['reasoning_effort'] == 'high'
assert 'request_user_input' in mode['settings']['developer_instructions']
assert 'confirmation' in mode['settings']['developer_instructions']
assert 'User instructions:' in request['params']['input'][0]['text']
assert 'Use request_user_input whenever you ask me a question' in request['params']['input'][0]['text']
if resuming:
    assert 'FOLLOWUP_ONLY' in request['params']['input'][0]['text']
    assert 'Write a README' not in request['params']['input'][0]['text']
turn_id = 'fixture-turn-2' if resuming else 'fixture-turn'
if 'FORCE_FAILURE' in request['params']['input'][0]['text']:
    result(request, {'turn': {'id': turn_id}})
    send({'method': 'turn/completed', 'params': {'turn': {'id': turn_id, 'status': 'failed', 'error': {'message': 'Fixture failure'}}}})
    sys.exit(0)
send({'method': 'turn/started', 'params': {'threadId': 'fixture-thread', 'turn': {'id': turn_id}}})
if settings == 'async-question':
    result(request, {'turn': {'id': turn_id}})
    send({'method': 'item/started', 'params': {'turnId': turn_id, 'item': async_question}})
    send({'method': 'item/completed', 'params': {'turnId': turn_id, 'item': async_question}})
    send({'method': 'turn/completed', 'params': {'turn': {'id': turn_id, 'status': 'completed'}}})
    read()  # Wait until the client consumes the completed turn before exiting.
    sys.exit(0)
# A server request can arrive before the turn/start response.
send({'id': 123, 'method': 'item/tool/requestUserInput', 'params': {'threadId': 'fixture-thread', 'turnId': turn_id, 'questions': [{'id': 'scope', 'header': 'Scope', 'question': 'Which file?', 'options': [{'label': 'README', 'description': 'Update the project documentation.'}]}]}})
result(request, {'turn': {'id': turn_id}})
response = read()
if response.get('method') == 'turn/interrupt':
    assert response['params']['turnId'] == turn_id
    result(response, {})
    send({'method': 'turn/completed', 'params': {'turn': {'id': turn_id, 'status': 'interrupted'}}})
    sys.exit(0)
assert response['id'] == 123
assert response['result']['answers']['scope']['answers'] == ['README']
send({'method': 'serverRequest/resolved', 'params': {'requestId': 123}})
send({'id': 'approval', 'method': 'item/commandExecution/requestApproval', 'params': {'reason': 'Run checks', 'command': 'swift test', 'cwd': '/fixture'}})
response = read()
assert response['id'] == 'approval'
assert response['result']['decision'] == 'decline'
send({'method': 'serverRequest/resolved', 'params': {'requestId': 'approval'}})
for method in ['item/fileChange/requestApproval', 'item/permissions/requestApproval']:
    permissions = {'network': {'enabled': True}}
    send({'id': method, 'method': method, 'params': {'permissions': permissions}})
    response = read()
    assert response['id'] == method
    if method == 'item/permissions/requestApproval':
        assert response['result'] == {'permissions': {}, 'scope': 'turn'}
    else:
        assert response['result']['decision'] == 'decline'
send({'method': 'item/started', 'params': {'item': {'id': 'message-1', 'type': 'agentMessage', 'text': ''}}})
send({'method': 'item/agentMessage/delta', 'params': {'itemId': 'message-1', 'delta': 'README created.'}})
send({'method': 'item/completed', 'params': {'item': {'id': 'message-1', 'type': 'agentMessage', 'text': '**README created.**'}}})
send({'method': 'item/started', 'params': {'item': {'id': 'shell-1', 'type': 'commandExecution', 'command': 'git status --short', 'status': 'inProgress'}}})
send({'method': 'item/started', 'params': {'item': {'id': 'shell-2', 'type': 'commandExecution', 'command': 'test -f LICENSE', 'status': 'inProgress'}}})
send({'method': 'item/commandExecution/outputDelta', 'params': {'itemId': 'shell-1', 'delta': ' M README.md\n'}})
send({'method': 'item/completed', 'params': {'item': {'id': 'shell-2', 'type': 'commandExecution', 'command': 'test -f LICENSE', 'status': 'failed', 'exitCode': 1}}})
send({'method': 'item/completed', 'params': {'item': {'id': 'shell-1', 'type': 'commandExecution', 'command': 'git status --short', 'aggregatedOutput': ' M README.md\n', 'status': 'completed', 'exitCode': 0}}})
send({'method': 'turn/diff/updated', 'params': {'diff': '+++ README.md\n+# Fixture'}})
send({'method': 'turn/completed', 'params': {'turn': {'id': turn_id, 'status': 'completed'}}})
"""#
}
private actor AgentEventCapture {
    var values: [RepairAgentEvent] = []
    func append(_ event: RepairAgentEvent) { values.append(event) }
}
