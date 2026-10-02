import Foundation
import XCTest
@testable import RepoManCore

@MainActor
final class RepairTaskQueueTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private var storage: RepairTaskStorage { RepairTaskStorage(url: root.appendingPathComponent("tasks.json")) }
    // Queue tests must never use the developer's Keychain or paid model endpoints.
    // Keep the README detector's mechanical coverage with explicitly absent credentials.
    private var testCatalog: RepositoryIssueCatalog {
        let settings = ModelCheckSettings(readToken: { nil }, writeToken: { _ in })
        return RepositoryIssueCatalog(checks: RepositoryIssueCatalog.standardChecks.filter {
            $0.id != "docs.readmeConsistency"
        } + RepositoryReadmeChecks.checks(settings: settings))
    }
    private func makeQueue(storage: RepairTaskStorage,
                           agentFactory: @escaping @MainActor () -> any RepairAgent,
                           catalog: RepositoryIssueCatalog? = nil,
                           inspect: @escaping @Sendable (URL) async throws -> RepositorySnapshot = {
                               try await RepairTaskQueue.inspectRepository($0)
                           }) throws -> RepairTaskQueue {
        try RepairTaskQueue(storage: storage, agentFactory: agentFactory,
                            catalog: catalog ?? testCatalog, inspect: inspect)
    }
    private func repository(_ name: String = "repo") throws -> RepositorySnapshot {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        _ = try GitRunner.run(["init", "-b", "main"], at: url)
        return try GitRepositoryScanner.scan(url)
    }
    private func finding(_ snapshot: RepositorySnapshot) throws -> RepositoryFinding {
        try XCTUnwrap(testCatalog.findings(in: snapshot).first { $0.checkID == "files.readme" })
    }
    private func waitForCompletion(_ queue: RepairTaskQueue) async throws {
        for _ in 0..<500 {
            if !queue.tasks.contains(where: { $0.state.isActive }) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Task did not finish: \(queue.tasks.map(\.state))")
    }
    private func waitForQuestion(_ queue: RepairTaskQueue) async throws -> AgentInteraction {
        for _ in 0..<500 {
            if let interaction = queue.tasks.first?.interactions.first, queue.tasks.first?.execution == .completed,
               queue.tasks.first?.state == .needsInput, queue.busyCommonDirectories.isEmpty { return interaction }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw RepairError.blocked("Async question did not survive completion")
    }
    func testCompletedQuestionRemainsAnswerableOnRestartWhileRepairsArePaused() throws {
        let snapshot = try repository()
        var saved = RepairTask(finding: try finding(snapshot), repository: snapshot, prompt: "Inspect first")
        saved.state = .needsInput; saved.execution = .completed
        saved.threadID = "saved-thread"; saved.turnID = "saved-turn"
        let interaction = AgentInteraction(id: "saved-turn:question", kind: .questions, title: "Scope", details: "",
            questions: [AgentQuestion(id: "scope", question: "Which action?", options: ["Keep unchanged"])], delivery: .followUp)
        saved.interactions = [interaction]
        try storage.save([saved])
        let queue = try makeQueue(storage: storage, agentFactory: { TestRepairAgent() })
        queue.canRun = { false }
        queue.start()
        XCTAssertEqual(queue.tasks.first?.state, .needsInput, "A completed question must not get stuck restoring while scanning")
        var responseError: String?
        queue.respond(taskID: saved.id, interaction: interaction, answers: ["scope": "Keep unchanged"]) { responseError = $0 }
        XCTAssertNil(responseError)
        XCTAssertEqual(queue.tasks.first?.state, .queued)
        XCTAssertEqual(queue.tasks.first?.threadID, saved.threadID)
    }
    func testReadOnlyRecoveryStartsWhileNewRepairsArePaused() async throws {
        let snapshot = try repository()
        var saved = RepairTask(finding: try finding(snapshot), repository: snapshot, prompt: "Do not replay")
        saved.state = .running; saved.threadID = "saved-thread"; saved.turnID = "saved-turn"
        try storage.save([saved])
        let agent = TestRepairAgent()
        let queue = try makeQueue(storage: storage, agentFactory: { agent }, inspect: { _ in snapshot })
        queue.canRun = { false }
        queue.start()
        try await waitForCompletion(queue)
        let recoveries = await agent.recoveries
        let runs = await agent.runs
        XCTAssertEqual(recoveries, 1)
        XCTAssertEqual(runs, 0)
        XCTAssertEqual(queue.tasks.first?.state, .stillPresent)
    }
    func testAsyncQuestionSurvivesCompletionAndRestartAndAnswerContinuesSameChat() async throws {
        let snapshot = try repository()
        let agent = AsyncQuestionRepairAgent()
        let queue = try makeQueue(storage: storage, agentFactory: { agent })
        let id = try queue.enqueue(finding: finding(snapshot), repository: snapshot, prompt: "Inspect first")
        let interaction = try await waitForQuestion(queue)
        XCTAssertEqual(queue.tasks.first?.state, .needsInput)
        XCTAssertEqual(try storage.load().first?.interactions, [interaction])

        let reopened = try makeQueue(storage: storage, agentFactory: { agent })
        reopened.start()
        let restored = try await waitForQuestion(reopened)
        XCTAssertEqual(restored, interaction)
        reopened.canRun = { false }
        var responseError: String?
        reopened.respond(taskID: id, interaction: restored, answers: ["scope": "  "]) { responseError = $0 }
        XCTAssertNotNil(responseError)
        XCTAssertEqual(reopened.tasks.first?.interactions, [interaction])
        reopened.respond(taskID: id, interaction: restored, answers: ["scope": "Write README"]) { responseError = $0 }
        XCTAssertNil(responseError)
        XCTAssertEqual(reopened.tasks.first?.state, .queued)
        XCTAssertTrue(reopened.tasks.first?.interactions.isEmpty == true)
        XCTAssertTrue(reopened.tasks.first?.currentPrompt.contains("Which action?") == true)
        XCTAssertTrue(reopened.tasks.first?.currentPrompt.contains("Write README") == true)
        reopened.respond(taskID: id, interaction: restored, answers: ["scope": "Delete files"]) { responseError = $0 }
        XCTAssertNotNil(responseError, "An answered question must not send another turn")
        reopened.canRun = { true }; reopened.start()
        try await waitForCompletion(reopened)
        let submissions = await agent.submissions
        XCTAssertEqual(submissions.count, 2)
        XCTAssertEqual(submissions.last?.threadID, "async-thread")
        XCTAssertEqual(reopened.tasks.first?.state, .resolved)
        XCTAssertEqual(try storage.load(), reopened.tasks)
        let responseCalls = await agent.responseCalls
        XCTAssertEqual(responseCalls, 0, "Async answers must not respond to a nonexistent blocking request")
    }
    func testAsyncAnswerDuringLiveTurnIsSavedAndSentOnlyAfterTurnEnds() async throws {
        let snapshot = try repository()
        let agent = AsyncQuestionRepairAgent(holdFirstTurn: true)
        let queue = try makeQueue(storage: storage, agentFactory: { agent })
        let id = try queue.enqueue(finding: finding(snapshot), repository: snapshot, prompt: "Inspect first")
        for _ in 0..<500 {
            if await agent.isWaiting { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let interaction = try XCTUnwrap(queue.tasks.first?.interactions.first)
        queue.respond(taskID: id, interaction: interaction, answers: ["scope": "Write README"])
        XCTAssertTrue(try storage.load().first?.pendingQuestionResponse?.contains("Write README") == true)
        let before = await agent.submissions
        XCTAssertEqual(before.count, 1)
        await agent.finishTurn()
        try await waitForCompletion(queue)
        let after = await agent.submissions
        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(after.last?.threadID, "async-thread")
        XCTAssertEqual(queue.tasks.first?.state, .resolved)
    }
    func testLegacyCompletedSessionRecoversAsyncQuestionWithoutResubmittingPrompt() async throws {
        let snapshot = try repository()
        var saved = RepairTask(finding: try finding(snapshot), repository: snapshot, prompt: "Inspect first")
        saved.state = .stillPresent; saved.execution = .completed
        saved.threadID = "async-thread"; saved.turnID = "async-turn"
        saved.interactionProtocolVersion = nil
        try storage.save([saved])
        let agent = AsyncQuestionRepairAgent()
        let queue = try makeQueue(storage: storage, agentFactory: { agent })
        XCTAssertEqual(queue.tasks.first?.state, .interrupted)
        queue.start()
        _ = try await waitForQuestion(queue)
        let submissions = await agent.submissions
        XCTAssertTrue(submissions.isEmpty)
        XCTAssertEqual(queue.tasks.first?.state, .needsInput)
        XCTAssertEqual(queue.tasks.first?.interactionProtocolVersion, 1)
    }
    func testAsyncAnswerSavedBeforeInterruptionIsResumedWithoutReopeningQuestion() async throws {
        let snapshot = try repository()
        let agent = AsyncQuestionRepairAgent()
        var saved = RepairTask(finding: try finding(snapshot), repository: snapshot, prompt: "Inspect first")
        saved.state = .running; saved.threadID = "async-thread"; saved.turnID = "async-turn"
        saved.pendingQuestionResponse = "Question: Which action?\nAnswer: Write README"
        saved.answeredQuestionIDs = ["async-turn:question"]
        try storage.save([saved])
        let queue = try makeQueue(storage: storage, agentFactory: { agent })
        queue.start()
        try await waitForCompletion(queue)
        let submissions = await agent.submissions
        XCTAssertEqual(submissions.count, 1)
        XCTAssertEqual(submissions.first?.threadID, "async-thread")
        XCTAssertEqual(submissions.first?.currentPrompt, saved.pendingQuestionResponse)
        XCTAssertTrue(queue.tasks.first?.interactions.isEmpty == true)
        XCTAssertNil(queue.tasks.first?.pendingQuestionResponse)
        XCTAssertEqual(queue.tasks.first?.state, .resolved)
    }
    func testAsyncAnswerSaveFailureKeepsQuestionAndDoesNotStartFollowUp() async throws {
        let snapshot = try repository()
        let agent = AsyncQuestionRepairAgent()
        let queue = try makeQueue(storage: storage, agentFactory: { agent })
        let id = try queue.enqueue(finding: finding(snapshot), repository: snapshot, prompt: "Inspect first")
        let interaction = try await waitForQuestion(queue)
        let before = queue.tasks
        try FileManager.default.removeItem(at: storage.url)
        try FileManager.default.createDirectory(at: storage.url, withIntermediateDirectories: true)
        var responseError: String?
        queue.respond(taskID: id, interaction: interaction, answers: ["scope": "Write README"]) { responseError = $0 }
        XCTAssertNotNil(responseError)
        XCTAssertEqual(queue.tasks, before)
        let submissions = await agent.submissions
        XCTAssertEqual(submissions.count, 1)
    }
    func testStoppingIdleAsyncQuestionDismissesItWithoutStartingFollowUp() async throws {
        let snapshot = try repository()
        let agent = AsyncQuestionRepairAgent()
        let queue = try makeQueue(storage: storage, agentFactory: { agent })
        let id = try queue.enqueue(finding: finding(snapshot), repository: snapshot, prompt: "Inspect first")
        let interaction = try await waitForQuestion(queue)
        queue.cancel(id)
        XCTAssertEqual(queue.tasks.first?.state, .cancelled)
        XCTAssertTrue(queue.tasks.first?.interactions.isEmpty == true)
        var responseError: String?
        queue.respond(taskID: id, interaction: interaction, answers: ["scope": "Write README"]) { responseError = $0 }
        XCTAssertNotNil(responseError)
        let submissions = await agent.submissions
        XCTAssertEqual(submissions.count, 1)
        try queue.enqueue(finding: finding(snapshot), repository: snapshot, prompt: "Answer: Write README")
        try await waitForCompletion(queue)
        XCTAssertEqual(queue.tasks.first?.state, .resolved, "Stopping an idle question must allow a later explicit follow-up")
    }
    func testArchivingCompletedConversationHidesItAndPreservesHistoryAcrossRestart() throws {
        let snapshot = try repository()
        var task = RepairTask(finding: try finding(snapshot), repository: snapshot, prompt: "Write README")
        task.state = .resolved
        task.threadID = "completed-thread"
        task.conversation = [RepairConversationEntry(id: "reply", kind: .assistant, text: "Done")]
        try storage.save([task])
        let queue = try makeQueue(storage: storage, agentFactory: { TestRepairAgent() })
        XCTAssertEqual(RepositoryIssueListItem.items(findings: [], tasks: queue.tasks, includeCompleted: true).count, 1)
        var notifications = 0
        queue.onChange = { notifications += 1 }
        try queue.archive(task.id)
        XCTAssertEqual(notifications, 1)
        try queue.archive(task.id)
        XCTAssertEqual(notifications, 1, "Archiving twice should be idempotent")
        let reloaded = try makeQueue(storage: storage, agentFactory: { TestRepairAgent() })
        let saved = try XCTUnwrap(reloaded.tasks.first)
        XCTAssertTrue(saved.isArchived)
        XCTAssertEqual(saved.state, .resolved)
        XCTAssertEqual(saved.threadID, task.threadID)
        XCTAssertEqual(saved.conversation, task.conversation)
        let visible = RepositoryIssueListItem.items(findings: [], tasks: reloaded.tasks, includeCompleted: true)
        XCTAssertTrue(visible.isEmpty)
        XCTAssertTrue(RepositoryIssueStatus.counts(in: visible).isEmpty)
        let archived = RepositoryIssueListItem.items(findings: [], tasks: reloaded.tasks, includeArchived: true)
        XCTAssertEqual(archived.first?.task, saved)
        XCTAssertTrue(RepositoryIssueStatus.counts(in: archived).isEmpty)
    }

    func testArchivedUnresolvedConversationDoesNotHideFindingOrReceiveFollowUp() throws {
        let snapshot = try repository()
        let issue = try finding(snapshot)
        var task = RepairTask(finding: issue, repository: snapshot, prompt: "Old instructions")
        task.state = .stillPresent
        task.threadID = "old-thread"
        try storage.save([task])
        let queue = try makeQueue(storage: storage, agentFactory: { TestRepairAgent() })
        queue.canRun = { false }
        try queue.archive(task.id)
        let visible = RepositoryIssueListItem.items(findings: [issue], tasks: queue.tasks, includeCompleted: true)
        XCTAssertEqual(visible.map(\.finding), [issue])
        XCTAssertNil(visible.first?.task)
        XCTAssertEqual(visible.first?.status, .pending)
        let newID = try queue.enqueue(finding: issue, repository: snapshot, prompt: "New instructions")
        XCTAssertNotEqual(newID, task.id)
        XCTAssertEqual(queue.tasks.first?.threadID, "old-thread")
        XCTAssertTrue(queue.tasks.first?.isArchived == true)
        XCTAssertEqual(queue.tasks.last?.state, .queued)
    }

    func testActiveConversationCannotBeArchivedAndFailedSaveRestoresVisibility() throws {
        let snapshot = try repository()
        var task = RepairTask(finding: try finding(snapshot), repository: snapshot, prompt: "Repair")
        for state: RepairTaskState in [.queued, .running, .needsInput, .checking, .interrupted] {
            task.state = state
            try storage.save([task])
            let queue = try makeQueue(storage: storage, agentFactory: { TestRepairAgent() })
            XCTAssertThrowsError(try queue.archive(task.id))
            XCTAssertFalse(queue.tasks.first?.isArchived == true)
        }
        task.state = .resolved
        try storage.save([task])
        let queue = try makeQueue(storage: storage, agentFactory: { TestRepairAgent() })
        try FileManager.default.removeItem(at: storage.url)
        try FileManager.default.createDirectory(at: storage.url, withIntermediateDirectories: true)
        XCTAssertThrowsError(try queue.archive(task.id))
        XCTAssertEqual(queue.tasks, [task])
        XCTAssertEqual(RepositoryIssueListItem.items(findings: [], tasks: queue.tasks, includeCompleted: true).count, 1)
    }

    func testEveryVisibleIssueHasOneStatusAndCompletedOccurrencesHaveSeparateCounts() throws {
        let snapshot = try repository()
        let issue = try finding(snapshot)
        let states: [RepairTaskState] = [.queued, .running, .checking, .interrupted, .needsInput,
                                        .stillPresent, .cancelled, .resolved, .noLongerNeeded, .failed, .couldntVerify]
        let expected: [RepositoryIssueStatus] = [.processing, .processing, .processing, .processing, .waiting,
                                               .waiting, .waiting, .completed, .completed, .waiting, .waiting]
        for (state, status) in zip(states, expected) {
            var task = RepairTask(finding: issue, repository: snapshot, prompt: "Repair")
            task.state = state
            let items = RepositoryIssueListItem.items(findings: state.isClosed ? [] : [issue], tasks: [task], includeCompleted: true)
            XCTAssertEqual(RepositoryIssueStatus.counts(in: items), [status: 1], "State: \(state)")
        }
        var first = RepairTask(finding: issue, repository: snapshot, prompt: "First occurrence")
        first.state = .resolved
        var second = RepairTask(finding: issue, repository: snapshot, prompt: "Second occurrence")
        second.state = .noLongerNeeded
        let items = RepositoryIssueListItem.items(findings: [issue], tasks: [first, second], includeCompleted: true)
        XCTAssertEqual(Set(items.map(\.id)).count, 3)
        XCTAssertEqual(RepositoryIssueStatus.counts(in: items), [.pending: 1, .completed: 2])
        first.archivedAt = Date()
        XCTAssertEqual(RepositoryIssueStatus.counts(in: RepositoryIssueListItem.items(findings: [issue], tasks: [first, second], includeCompleted: true)), [.pending: 1, .completed: 1])
    }

    func testRecipeRepairIsVerifiedAndCreatesAnotherFinding() async throws {
        let snapshot = try repository()
        let agent = TestRepairAgent { task in
            try "# Actual project\n".write(to: task.repositoryURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        }
        let queue = try makeQueue(storage: storage, agentFactory: { agent })
        try queue.enqueue(finding: finding(snapshot), repository: snapshot, prompt: "Write README; leave it uncommitted.")
        try await waitForCompletion(queue)
        XCTAssertEqual(queue.tasks.first?.state, .resolved)
        XCTAssertEqual(queue.tasks.first?.execution, .completed)
        let after = try GitRepositoryScanner.scan(snapshot.url)
        XCTAssertTrue(testCatalog.findings(in: after).contains { $0.checkID == "git.changes" })
        XCTAssertFalse(testCatalog.findings(in: after).contains { $0.checkID == "files.readme" })
        XCTAssertEqual(try storage.load(), queue.tasks)
    }
    func testStructuredConversationKeepsInterleavedToolOutputSeparateAndDoesNotDuplicateFinalText() async throws {
        let snapshot = try repository()
        let queue = try makeQueue(storage: storage, agentFactory: { ConversationRepairAgent() })
        try queue.enqueue(finding: finding(snapshot), repository: snapshot, prompt: "Inspect the checkout")
        try await waitForCompletion(queue)
        let task = try XCTUnwrap(queue.tasks.first)
        let entries = try XCTUnwrap(task.conversation)
        XCTAssertEqual(entries.prefix(4).map(\.id), ["intro", "status", "test", "result"])
        XCTAssertEqual(entries.map(\.kind), [.assistant, .command, .command, .assistant, .status])
        XCTAssertEqual(entries[0].text, "I’ll inspect **this checkout**.")
        XCTAssertEqual(entries[1].output, " M notes.txt\n")
        XCTAssertEqual(entries[1].exitCode, 0)
        XCTAssertEqual(entries[2].output, "first\nsecond\n")
        XCTAssertEqual(entries[2].exitCode, 1)
        XCTAssertEqual(entries[3].text, "The check failed; no files changed.")
        XCTAssertEqual(task.prompt, "Inspect the checkout")
        XCTAssertEqual(task.state, .stillPresent)
        XCTAssertEqual(try storage.load(), queue.tasks)
    }
    func testConversationContentIsKeptInFullAcrossStorageRoundTrip() throws {
        let snapshot = try repository()
        var task = RepairTask(finding: try finding(snapshot), repository: snapshot, prompt: "Initial request")
        let large = String(repeating: "streamed output\n", count: 20_000)
        task.appendConversationDelta(id: "long-command", kind: .command, text: large)
        task.upsertConversation(RepairConversationEntry(id: "reply", kind: .assistant, text: "Final reply"))
        try storage.save([task])
        let restored = try XCTUnwrap(storage.load().first)
        XCTAssertEqual(restored.conversation?.first?.output, large)
        XCTAssertEqual(restored.conversation?.last?.text, "Final reply")
    }
    func testRepeatedRechecksDoNotAppendUnchangedStatus() async throws {
        let snapshot = try repository()
        let queue = try makeQueue(storage: storage, agentFactory: { TestRepairAgent() }, inspect: { _ in snapshot })
        let id = try queue.enqueue(finding: finding(snapshot), repository: snapshot, prompt: "Inspect only")
        try await waitForCompletion(queue)
        let originalEntries = try XCTUnwrap(queue.tasks.first?.conversation)
        XCTAssertEqual(originalEntries.filter { $0.kind == .status }.count, 1)
        for _ in 0..<2 {
            queue.recheck(id)
            try await waitForCompletion(queue)
        }
        XCTAssertEqual(queue.tasks.first?.conversation, originalEntries)
        XCTAssertEqual(try storage.load(), queue.tasks)
    }
    func testSavedDuplicateStatusesAreRemovedWithoutLosingTurnHistoryOrChangedResults() throws {
        let snapshot = try repository()
        var task = RepairTask(finding: try finding(snapshot), repository: snapshot, prompt: "Inspect only")
        task.state = .stillPresent
        let evidence = "1 commit on main is ahead of origin/main."
        task.conversation = [
            RepairConversationEntry(id: "first", kind: .status, text: evidence, status: "stillPresent"),
            RepairConversationEntry(id: "duplicate", kind: .status, text: evidence, status: "stillPresent"),
            RepairConversationEntry(id: "follow-up", kind: .user, text: "What happened?"),
            RepairConversationEntry(id: "reply", kind: .assistant, text: "Push was blocked."),
            RepairConversationEntry(id: "second", kind: .status, text: evidence, status: "stillPresent"),
            RepairConversationEntry(id: "second-duplicate", kind: .status, text: evidence, status: "stillPresent"),
            RepairConversationEntry(id: "failed", kind: .status, text: evidence, status: "failed"),
            RepairConversationEntry(id: "changed", kind: .status, text: "2 commits ahead.", status: "failed"),
            RepairConversationEntry(id: "resolved", kind: .status, text: "No commits to push.", status: "resolved")
        ]
        try storage.save([task])
        let queue = try makeQueue(storage: storage, agentFactory: { TestRepairAgent() })
        XCTAssertEqual(queue.tasks.first?.conversation?.map(\.id), ["first", "follow-up", "reply", "second", "failed", "changed", "resolved"])
        XCTAssertEqual(try storage.load(), queue.tasks)
        let reopened = try makeQueue(storage: storage, agentFactory: { TestRepairAgent() })
        XCTAssertEqual(reopened.tasks, queue.tasks)
    }
    func testLegacyActiveTaskWithoutStructuredConversationStillLoads() throws {
        let snapshot = try repository()
        var task = RepairTask(finding: try finding(snapshot), repository: snapshot, prompt: "Original prompt")
        task.state = .running; task.activity = "Previously streamed text"
        let encoded = try JSONEncoder().encode(task)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "conversation")
        json.removeValue(forKey: "archivedAt")
        json.removeValue(forKey: "interactionProtocolVersion")
        json.removeValue(forKey: "pendingQuestionResponse")
        json.removeValue(forKey: "answeredQuestionIDs")
        let decoded = try JSONDecoder().decode(RepairTask.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.conversation)
        XCTAssertNil(decoded.interactionProtocolVersion)
        XCTAssertNil(decoded.pendingQuestionResponse)
        XCTAssertNil(decoded.answeredQuestionIDs)
        XCTAssertFalse(decoded.isArchived)
        XCTAssertEqual(decoded.activity, task.activity)
        XCTAssertEqual(decoded.prompt, task.prompt)
        try storage.save([decoded])
        let queue = try makeQueue(storage: storage, agentFactory: { TestRepairAgent() })
        XCTAssertEqual(queue.tasks.first?.conversation?.first?.text, task.activity)
        XCTAssertEqual(try storage.load().first?.conversation?.first?.text, task.activity)
    }
    func testClosedConversationAndQueuedWorkAreBothRestored() throws {
        let snapshot = try repository()
        let other = try repository("other")
        var old = RepairTask(finding: try finding(snapshot), repository: snapshot, prompt: "Old repair")
        old.state = .resolved
        old.threadID = "archived-thread"
        old.activity = "Archived conversation remains available"
        let queued = RepairTask(finding: try finding(other), repository: other, prompt: "Still queued")
        try storage.save([old, queued])
        let queue = try makeQueue(storage: storage, agentFactory: { TestRepairAgent() })
        XCTAssertEqual(queue.tasks.map(\.id), [old.id, queued.id])
        XCTAssertEqual(try storage.load().map(\.id), [old.id, queued.id])
        XCTAssertTrue(queue.tasks.first?.state.isClosed == true)
        XCTAssertEqual(queue.tasks.first?.threadID, old.threadID)
        XCTAssertEqual(queue.tasks.first?.conversation?.first?.text, old.activity)
        let active = RepositoryIssueListItem.items(findings: [], tasks: queue.tasks)
        XCTAssertEqual(active.map { $0.task?.id }, [queued.id])
        let includingArchived = RepositoryIssueListItem.items(findings: [], tasks: queue.tasks, includeCompleted: true)
        XCTAssertEqual(includingArchived.map { $0.task?.id }, [queued.id, old.id])
        XCTAssertEqual(includingArchived.map(\.isArchived), [false, false])
        XCTAssertEqual(includingArchived.last?.task?.conversation?.first?.text, old.activity)
    }
    func testNoLongerNeededConversationUsesTheSameArchiveFilterAndStorage() throws {
        let snapshot = try repository()
        var task = RepairTask(finding: try finding(snapshot), repository: snapshot, prompt: "Repair README")
        task.state = .noLongerNeeded
        task.verification = .absent("Already repaired externally")
        task.upsertConversation(RepairConversationEntry(id: "notice", kind: .status,
            text: "Already repaired externally", status: task.state.rawValue))
        try storage.save([task])
        let queue = try makeQueue(storage: storage, agentFactory: { TestRepairAgent() })
        XCTAssertTrue(RepositoryIssueListItem.items(findings: [], tasks: queue.tasks).isEmpty)
        let archived = RepositoryIssueListItem.items(findings: [], tasks: queue.tasks, includeCompleted: true)
        XCTAssertEqual(archived.first?.task, task)
        XCTAssertFalse(archived.first?.isArchived == true)
        XCTAssertEqual(try storage.load(), [task])
    }
    func testFollowUpKeepsTheConversationAndClosedConversationRemainsStored() async throws {
        let snapshot = try repository()
        let agent = MultiTurnRepairAgent()
        let queue = try makeQueue(storage: storage, agentFactory: { agent })
        let original = try queue.enqueue(finding: finding(snapshot), repository: snapshot, prompt: "Inspect only; do not write.")
        try await waitForCompletion(queue)
        let first = try XCTUnwrap(queue.tasks.first)
        XCTAssertEqual(first.state, .stillPresent)
        XCTAssertEqual(first.threadID, "issue-thread")
        XCTAssertEqual(try storage.load(), [first])

        // Idle conversations survive restart without silently running another turn.
        let restored = try makeQueue(storage: storage, agentFactory: { agent })
        restored.start()
        try await Task.sleep(nanoseconds: 30_000_000)
        let runsBeforeFollowUp = await agent.submissions.count
        XCTAssertEqual(runsBeforeFollowUp, 1)
        let continued = try restored.enqueue(finding: finding(snapshot), repository: snapshot, prompt: "Finish README now.")
        XCTAssertEqual(continued, original)
        try await waitForCompletion(restored)
        let finished = try XCTUnwrap(restored.tasks.first)
        XCTAssertEqual(finished.state, .resolved)
        XCTAssertEqual(finished.threadID, first.threadID)
        XCTAssertNotEqual(finished.turnID, first.turnID)
        XCTAssertEqual(finished.prompt, first.prompt)
        let submitted = await agent.submissions
        XCTAssertEqual(submitted.map(\.currentPrompt), ["Inspect only; do not write.", "Finish README now."])
        XCTAssertEqual(submitted.last?.threadID, "issue-thread")
        XCTAssertFalse(submitted.last?.agentPrompt.contains("Inspect only; do not write.") == true)
        XCTAssertEqual(finished.conversation?.filter { $0.kind == .user }.map(\.text), ["Finish README now."])
        XCTAssertEqual(finished.conversation?.filter { $0.kind == .status }.count, 2)
        XCTAssertEqual(try storage.load(), restored.tasks)
        let reopened = try makeQueue(storage: storage, agentFactory: { agent })
        XCTAssertEqual(reopened.tasks, restored.tasks)

        // Recurrence gets a new conversation; the closed conversation stays completed.
        try FileManager.default.removeItem(at: snapshot.url.appendingPathComponent("README.md"))
        reopened.canRun = { false }
        let fresh = try GitRepositoryScanner.scan(snapshot.url)
        let recurrence = try reopened.enqueue(finding: finding(fresh), repository: fresh, prompt: "New occurrence")
        XCTAssertNotEqual(recurrence, original)
        XCTAssertEqual(reopened.tasks.first, finished)
        XCTAssertEqual(reopened.tasks.count, 2)
        XCTAssertEqual(try storage.load(), reopened.tasks)
        let currentFinding = try finding(fresh)
        let active = RepositoryIssueListItem.items(findings: [currentFinding], tasks: reopened.tasks)
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.task?.id, recurrence)
        let includingArchived = RepositoryIssueListItem.items(findings: [currentFinding], tasks: reopened.tasks, includeCompleted: true)
        XCTAssertEqual(includingArchived.count, 2)
        XCTAssertEqual(Set(includingArchived.map(\.id)).count, 2)
        XCTAssertEqual(includingArchived.last?.task, finished)
    }
    func testFollowUpReachesTheSameThreadWhenDetectorIsUnavailable() async throws {
        let snapshot = try repository()
        let originalFinding = try finding(snapshot)
        var saved = RepairTask(finding: originalFinding, repository: snapshot, prompt: "Repair")
        saved.state = .couldntVerify; saved.execution = .completed
        saved.threadID = "issue-thread"; saved.turnID = "previous-turn"
        saved.upsertConversation(RepairConversationEntry(id: "previous-reply", kind: .assistant, text: "Previous result"))
        try storage.save([saved])
        let unavailable = RepositorySnapshot(url: snapshot.url, name: snapshot.name, branch: snapshot.branch,
            upstream: snapshot.upstream, remoteURL: snapshot.remoteURL, ahead: nil, behind: nil,
            changes: [], staleBranches: [], worktrees: [], commits: [])
        let agent = MultiTurnRepairAgent()
        let queue = try makeQueue(storage: storage, agentFactory: { agent }, inspect: { _ in unavailable })
        let id = try queue.enqueue(finding: originalFinding, repository: snapshot, prompt: "what happened")
        try await waitForCompletion(queue)

        let submissions = await agent.submissions
        XCTAssertEqual(id, saved.id)
        XCTAssertEqual(submissions.count, 1)
        XCTAssertEqual(submissions.first?.threadID, saved.threadID)
        XCTAssertEqual(submissions.first?.currentPrompt, "what happened")
        XCTAssertEqual(queue.tasks.first?.execution, .completed)
        XCTAssertEqual(queue.tasks.first?.state, .couldntVerify, "An agent reply must not falsely resolve an unavailable detector")
        XCTAssertEqual(queue.tasks.first?.conversation?.filter { $0.kind == .assistant }.map(\.text), ["Previous result", "Turn 1"])
        XCTAssertEqual(try storage.load(), queue.tasks)
    }
    func testFollowUpStillReachesAgentWhenFindingHasDisappeared() async throws {
        let snapshot = try repository()
        let originalFinding = try finding(snapshot)
        let agent = MultiTurnRepairAgent()
        let queue = try makeQueue(storage: storage, agentFactory: { agent })
        let id = try queue.enqueue(finding: originalFinding, repository: snapshot, prompt: "Inspect only")
        try await waitForCompletion(queue)
        try "# README".write(to: snapshot.url.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let continued = try queue.enqueue(finding: originalFinding, repository: snapshot, prompt: "Explain the result")
        try await waitForCompletion(queue)

        let submissions = await agent.submissions
        XCTAssertEqual(continued, id)
        XCTAssertEqual(submissions.count, 2)
        XCTAssertEqual(submissions.last?.currentPrompt, "Explain the result")
        XCTAssertEqual(submissions.last?.threadID, "issue-thread")
        XCTAssertEqual(queue.tasks.first?.execution, .completed)
        XCTAssertEqual(queue.tasks.first?.state, .resolved)
    }
    func testFollowUpRemainsBlockedWhenBranchUpstreamOrRemoteChanges() async throws {
        let snapshot = try repository()
        let originalFinding = try finding(snapshot)
        let original = RepositorySnapshot(url: snapshot.url, name: snapshot.name, branch: "main", upstream: "origin/main",
            remoteURL: "https://github.com/owner/project.git", ahead: 0, behind: 0,
            changes: [], staleBranches: [], worktrees: [], commits: [], rootFiles: [])
        for (branch, upstream, remote) in [
            ("other", "origin/main", "https://github.com/owner/project.git"),
            ("main", "origin/other", "https://github.com/owner/project.git"),
            ("main", "origin/main", "https://github.com/owner/other.git")
        ] {
            var saved = RepairTask(finding: originalFinding, repository: original, prompt: "Inspect only")
            saved.state = .stillPresent; saved.threadID = "issue-thread"
            try storage.save([saved])
            let changed = RepositorySnapshot(url: snapshot.url, name: snapshot.name, branch: branch, upstream: upstream,
                remoteURL: remote, ahead: 0, behind: 0, changes: [], staleBranches: [], worktrees: [], commits: [], rootFiles: [])
            let agent = MultiTurnRepairAgent()
            let queue = try makeQueue(storage: storage, agentFactory: { agent }, inspect: { _ in changed })
            try queue.enqueue(finding: originalFinding, repository: changed, prompt: "what happened")
            try await waitForCompletion(queue)
            let submissions = await agent.submissions
            XCTAssertTrue(submissions.isEmpty)
            XCTAssertEqual(queue.tasks.first?.execution, .notRun)
            XCTAssertEqual(queue.tasks.first?.state, .couldntVerify)
            XCTAssertTrue(queue.tasks.first?.message.contains("branch, upstream, or remote changed") == true)
        }
    }
    func testOrdinaryInspectionClosesAnIdleConversationOnlyOnConfirmedAbsence() async throws {
        let snapshot = try repository()
        let queue = try makeQueue(storage: storage, agentFactory: { TestRepairAgent() })
        try queue.enqueue(finding: finding(snapshot), repository: snapshot, prompt: "Inspect")
        try await waitForCompletion(queue)
        let unavailable = RepositorySnapshot(url: snapshot.url, name: snapshot.name, branch: snapshot.branch, upstream: nil,
            remoteURL: nil, ahead: nil, behind: nil, changes: [], staleBranches: [], worktrees: [], commits: [])
        queue.acceptInspection(await testCatalog.inspect(unavailable))
        XCTAssertEqual(queue.tasks.first?.state, .stillPresent)
        XCTAssertEqual(RepositoryIssueListItem.items(findings: [], tasks: queue.tasks).first?.task, queue.tasks.first)
        try "# README".write(to: snapshot.url.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        queue.acceptInspection(await testCatalog.inspect(try GitRepositoryScanner.scan(snapshot.url)))
        XCTAssertEqual(queue.tasks.first?.state, .resolved)
        XCTAssertEqual(try storage.load(), queue.tasks)
        XCTAssertTrue(RepositoryIssueListItem.items(findings: [], tasks: queue.tasks).isEmpty)
        XCTAssertEqual(RepositoryIssueListItem.items(findings: [], tasks: queue.tasks, includeCompleted: true).first?.task, queue.tasks.first)
    }
    func testFollowUpSaveFailurePreservesThePreviousConversation() async throws {
        let snapshot = try repository()
        let agent = MultiTurnRepairAgent()
        let queue = try makeQueue(storage: storage, agentFactory: { agent })
        try queue.enqueue(finding: finding(snapshot), repository: snapshot, prompt: "Inspect only")
        try await waitForCompletion(queue)
        let previous = queue.tasks
        try FileManager.default.removeItem(at: storage.url)
        try FileManager.default.createDirectory(at: storage.url, withIntermediateDirectories: true)
        XCTAssertThrowsError(try queue.enqueue(finding: finding(snapshot), repository: snapshot, prompt: "Follow up"))
        XCTAssertEqual(queue.tasks, previous)
        let submissions = await agent.submissions.count
        XCTAssertEqual(submissions, 1)
    }
    func testAgentCompletionDoesNotResolveAnUnchangedFinding() async throws {
        let snapshot = try repository()
        let queue = try makeQueue(storage: storage, agentFactory: { TestRepairAgent() })
        try queue.enqueue(finding: finding(snapshot), repository: snapshot, prompt: "Repair")
        try await waitForCompletion(queue)
        XCTAssertEqual(queue.tasks.first?.state, .stillPresent)
        XCTAssertEqual(queue.tasks.first?.execution, .completed)
    }
    func testDisappearedQueuedFindingSkipsAgentAndDeduplicates() async throws {
        let snapshot = try repository()
        let agent = TestRepairAgent()
        let queue = try makeQueue(storage: storage, agentFactory: { agent })
        queue.canRun = { false }
        let original = try queue.enqueue(finding: finding(snapshot), repository: snapshot, prompt: "Original")
        let duplicate = try queue.enqueue(finding: finding(snapshot), repository: snapshot, prompt: "Different")
        XCTAssertEqual(original, duplicate)
        XCTAssertEqual(queue.tasks.first?.prompt, "Original")
        try "# README".write(to: snapshot.url.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        queue.canRun = { true }; queue.start()
        try await waitForCompletion(queue)
        XCTAssertEqual(queue.tasks.first?.state, .noLongerNeeded)
        let runs = await agent.runs
        XCTAssertEqual(runs, 0)
    }
    func testUnavailableDetectorNeverCountsAsResolved() async throws {
        let snapshot = try repository()
        let queue = try makeQueue(storage: storage, agentFactory: { TestRepairAgent() }, inspect: { url in
            RepositorySnapshot(url: url, name: "repo", branch: "main", upstream: nil, remoteURL: nil,
                               ahead: nil, behind: nil, changes: [], staleBranches: [], worktrees: [], commits: [])
        })
        try queue.enqueue(finding: finding(snapshot), repository: snapshot, prompt: "Repair")
        try await waitForCompletion(queue)
        XCTAssertEqual(queue.tasks.first?.state, .couldntVerify)
        XCTAssertEqual(queue.tasks.first?.execution, .notRun)
    }
    func testVerificationFailureAfterAgentSuccessStaysUnknown() async throws {
        let snapshot = try repository()
        let inspector = SequencedInspector(snapshot: snapshot)
        let queue = try makeQueue(storage: storage, agentFactory: { TestRepairAgent() }, inspect: { _ in try await inspector.next() })
        try queue.enqueue(finding: finding(snapshot), repository: snapshot, prompt: "Repair")
        try await waitForCompletion(queue)
        XCTAssertEqual(queue.tasks.first?.state, .couldntVerify)
        XCTAssertEqual(queue.tasks.first?.execution, .completed)
    }
    func testChangedBranchDoesNotHideOriginalFinding() async throws {
        let snapshot = try repository()
        let agent = TestRepairAgent { task in _ = try GitRunner.run(["symbolic-ref", "HEAD", "refs/heads/other"], at: task.repositoryURL) }
        let queue = try makeQueue(storage: storage, agentFactory: { agent })
        try queue.enqueue(finding: finding(snapshot), repository: snapshot, prompt: "Repair")
        try await waitForCompletion(queue)
        XCTAssertEqual(queue.tasks.first?.state, .couldntVerify)
    }
    func testRestartReconcilesSessionWithoutResubmittingPrompt() async throws {
        let snapshot = try repository()
        var saved = RepairTask(finding: try finding(snapshot), repository: snapshot, prompt: "Do not replay")
        saved.state = .running; saved.threadID = "existing-thread"; saved.turnID = "existing-turn"
        try storage.save([saved])
        try "# Fixed while interrupted".write(to: snapshot.url.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let agent = TestRepairAgent()
        let queue = try makeQueue(storage: storage, agentFactory: { agent })
        XCTAssertEqual(queue.tasks.first?.state, .interrupted)
        queue.start()
        try await waitForCompletion(queue)
        let runs = await agent.runs; let recoveries = await agent.recoveries
        XCTAssertEqual(runs, 0); XCTAssertEqual(recoveries, 1)
        XCTAssertEqual(queue.tasks.first?.state, .resolved)
        XCTAssertEqual(queue.tasks.first?.threadID, "existing-thread")
    }
    func testQuitFlushPreservesBufferedConversationAndResumesTheSameThreadAfterRelaunch() async throws {
        let snapshot = try repository()
        let agent = BufferedConversationRepairAgent()
        let queue = try makeQueue(storage: storage, agentFactory: { agent })
        let id = try queue.enqueue(finding: finding(snapshot), repository: snapshot, prompt: "Inspect the project")
        for _ in 0..<500 {
            if await agent.isWaiting { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let waiting = await agent.isWaiting
        XCTAssertTrue(waiting)
        try queue.flush()
        let saved = try XCTUnwrap(storage.load().first)
        XCTAssertEqual(saved.state, .running)
        XCTAssertEqual(saved.threadID, "persistent-thread")
        XCTAssertEqual(saved.turnID, "persistent-turn")
        XCTAssertEqual(saved.conversation?.first?.text, "Reading the project")
        XCTAssertEqual(saved.conversation?.last?.output, "first line\nlast buffered line\n")
        XCTAssertEqual(saved, queue.tasks.first)

        // Freeze the flushed disk contents to simulate quitting while this test's agent is held open.
        let relaunchedStorage = RepairTaskStorage(url: root.appendingPathComponent("relaunched/tasks.json"))
        try relaunchedStorage.save(storage.load())
        queue.cancel(id)
        try await waitForCompletion(queue)

        let resumedAgent = MultiTurnRepairAgent()
        let relaunched = try makeQueue(storage: relaunchedStorage, agentFactory: { resumedAgent })
        XCTAssertEqual(relaunched.tasks.first?.state, .interrupted)
        XCTAssertEqual(relaunched.tasks.first?.id, id)
        XCTAssertEqual(relaunched.tasks.first?.conversation, saved.conversation)
        relaunched.start()
        try await waitForCompletion(relaunched)
        let submissionsBeforeFollowUp = await resumedAgent.submissions
        XCTAssertTrue(submissionsBeforeFollowUp.isEmpty, "Recovery must not replay the original request")
        XCTAssertEqual(relaunched.tasks.first?.threadID, saved.threadID)
        XCTAssertEqual(relaunched.tasks.first?.turnID, saved.turnID)
        let continued = try relaunched.enqueue(finding: finding(snapshot), repository: snapshot, prompt: "Continue inspecting")
        XCTAssertEqual(continued, id)
        try await waitForCompletion(relaunched)
        let submission = await resumedAgent.submissions.first
        XCTAssertEqual(submission?.threadID, saved.threadID)
        XCTAssertEqual(submission?.currentPrompt, "Continue inspecting")
        XCTAssertEqual(submission?.conversation?.prefix(2).map(\.id), saved.conversation?.map(\.id))
        XCTAssertEqual(submission?.conversation?.first?.text, saved.conversation?.first?.text)
        XCTAssertEqual(submission?.conversation?.dropFirst().first?.output, saved.conversation?.last?.output)
        XCTAssertEqual(try relaunchedStorage.load(), relaunched.tasks)
    }
    func testQuitFlushFailureIsReportedWithoutDiscardingConversations() throws {
        let snapshot = try repository()
        let queue = try makeQueue(storage: storage, agentFactory: { TestRepairAgent() })
        queue.canRun = { false }
        try queue.enqueue(finding: finding(snapshot), repository: snapshot, prompt: "Saved request")
        let before = queue.tasks
        try FileManager.default.removeItem(at: storage.url)
        try FileManager.default.createDirectory(at: storage.url, withIntermediateDirectories: true)
        XCTAssertThrowsError(try queue.flush())
        XCTAssertEqual(queue.tasks, before)
        XCTAssertNotNil(queue.error)
    }
    func testCancelledQueuedTaskNeverRuns() async throws {
        let snapshot = try repository()
        let other = try repository("other")
        let agent = TestRepairAgent()
        let queue = try makeQueue(storage: storage, agentFactory: { agent })
        queue.canRun = { false }
        try queue.enqueue(finding: finding(snapshot), repository: snapshot, prompt: "First")
        let cancelled = try queue.enqueue(finding: finding(other), repository: other, prompt: "Cancel")
        queue.cancel(cancelled)
        let third = try repository("third")
        try queue.enqueue(finding: finding(third), repository: third, prompt: "Third")
        queue.canRun = { true }; queue.start()
        try await waitForCompletion(queue)
        let runs = await agent.runs
        XCTAssertEqual(runs, 2)
        XCTAssertEqual(queue.tasks.first { $0.id == cancelled }?.state, .cancelled)
    }
    func testSameRepositoryIssuesHaveConcurrentIndependentSessionsAndCancellation() async throws {
        let snapshot = try repository()
        let readme = try finding(snapshot)
        let ignore = try XCTUnwrap(testCatalog.findings(in: snapshot).first { $0.checkID == "files.gitignore" })
        let firstAgent = HeldRepairAgent(label: "README chat", file: "README.md")
        let secondAgent = HeldRepairAgent(label: "Ignore chat", file: ".gitignore")
        var created = 0
        let queue = try makeQueue(storage: storage, agentFactory: {
            created += 1
            return created == 1 ? firstAgent : secondAgent
        })
        let first = try queue.enqueue(finding: readme, repository: snapshot, prompt: "Fix README")
        let second = try queue.enqueue(finding: ignore, repository: snapshot, prompt: "Fix ignore rules")
        for _ in 0..<500 {
            let firstWaiting = await firstAgent.isWaiting
            let secondWaiting = await secondAgent.isWaiting
            if firstWaiting && secondWaiting { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(created, 2)
        XCTAssertEqual(queue.tasks.map(\.state), [.needsInput, .needsInput])
        XCTAssertEqual(Set(queue.tasks.compactMap(\.threadID)).count, 2)
        XCTAssertEqual(queue.tasks[0].conversation?.first?.text, "README chat")
        XCTAssertEqual(queue.tasks[1].conversation?.first?.text, "Ignore chat")
        XCTAssertEqual(try storage.load(), queue.tasks)
        let common = try RepairTaskQueue.commonDirectory(at: snapshot.url)
        XCTAssertEqual(queue.busyCommonDirectories, [common])
        queue.cancel(first)
        for _ in 0..<500 {
            if queue.tasks.first(where: { $0.id == first })?.state == .cancelled { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(queue.tasks.first(where: { $0.id == second })?.state, .needsInput)
        XCTAssertEqual(queue.busyCommonDirectories, [common], "Finishing one chat must not unmark another chat's busy checkout")
        let interaction = try XCTUnwrap(queue.tasks.first(where: { $0.id == second })?.interactions.first)
        queue.respond(taskID: second, interaction: interaction, answers: ["scope": "Ignore only"])
        try await waitForCompletion(queue)
        XCTAssertEqual(queue.tasks.map(\.state), [.cancelled, .resolved])
        let firstAnswers = await firstAgent.answers; let secondAnswers = await secondAgent.answers
        XCTAssertTrue(firstAnswers.isEmpty)
        XCTAssertEqual(secondAnswers, ["Ignore only"])
        XCTAssertEqual(queue.busyCommonDirectories, [])
        XCTAssertEqual(try storage.load(), queue.tasks)
    }
    func testConcurrentTurnLimitAndQueuedWorkStartsAsEachSessionFinishes() async throws {
        let snapshots = try (0..<6).map { try repository("repo-\($0)") }
        var agents: [HeldRepairAgent] = []
        let queue = try makeQueue(storage: storage, agentFactory: {
            let agent = HeldRepairAgent(label: "Chat \(agents.count)", file: "README.md")
            agents.append(agent)
            return agent
        })
        queue.canRun = { false }
        for snapshot in snapshots { try queue.enqueue(finding: finding(snapshot), repository: snapshot, prompt: "Write README") }
        queue.canRun = { true }; queue.start(); queue.start()
        for _ in 0..<500 {
            if queue.tasks.filter({ $0.state == .needsInput }).count == 4 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(agents.count, 4, "Repeated scheduling must not launch duplicate workers")
        XCTAssertEqual(queue.tasks.filter { $0.state == .queued }.count, 2)
        XCTAssertEqual(queue.busyCommonDirectories.count, 4)
        for _ in 0..<500 {
            for task in queue.tasks where task.state == .needsInput {
                if let interaction = task.interactions.first {
                    queue.respond(taskID: task.id, interaction: interaction, answers: ["scope": "README"])
                }
            }
            if queue.tasks.allSatisfy({ $0.state.isClosed }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(agents.count, 6)
        XCTAssertTrue(queue.tasks.allSatisfy { $0.state == .resolved })
        XCTAssertEqual(queue.busyCommonDirectories, [])
    }
    func testFailureDoesNotDiscardTheNextQueuedTask() async throws {
        let first = try repository()
        let second = try repository("second")
        let agent = TestRepairAgent { task in
            if task.repositoryName == "repo" { throw RepairError.blocked("Repair failed") }
            try "# README".write(to: task.repositoryURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        }
        let queue = try makeQueue(storage: storage, agentFactory: { agent })
        queue.canRun = { false }
        try queue.enqueue(finding: finding(first), repository: first, prompt: "First")
        try queue.enqueue(finding: finding(second), repository: second, prompt: "Second")
        queue.canRun = { true }; queue.start()
        try await waitForCompletion(queue)
        XCTAssertEqual(queue.tasks.map(\.state), [.failed, .resolved])
        XCTAssertEqual(queue.tasks.first?.execution, .failed)
    }

    func testAgentQuestionsContinueSameSession() async throws {
        let snapshot = try repository()
        let agent = InteractiveRepairAgent()
        let queue = try makeQueue(storage: storage, agentFactory: { agent })
        let id = try queue.enqueue(finding: finding(snapshot), repository: snapshot, prompt: "Ask me first")
        for _ in 0..<200 where queue.tasks.first?.state != .needsInput { try await Task.sleep(nanoseconds: 10_000_000) }
        let interaction = try XCTUnwrap(queue.tasks.first?.interactions.first)
        XCTAssertEqual(queue.tasks.first?.threadID, "same-thread")
        queue.respond(taskID: id, interaction: interaction, answers: ["scope": "README"], approved: false)
        try await waitForCompletion(queue)
        XCTAssertEqual(queue.tasks.first?.threadID, "same-thread")
        XCTAssertEqual(queue.tasks.first?.state, .resolved)
        XCTAssertTrue(queue.tasks.first?.activity.contains("You: README") == true)
    }
    func testFailedQuestionSubmissionReportsErrorAndCanBeRetried() async throws {
        let snapshot = try repository()
        let agent = InteractiveRepairAgent(rejectFirstResponse: true)
        let queue = try makeQueue(storage: storage, agentFactory: { agent })
        let id = try queue.enqueue(finding: finding(snapshot), repository: snapshot, prompt: "Ask me first")
        for _ in 0..<200 where queue.tasks.first?.state != .needsInput { try await Task.sleep(nanoseconds: 10_000_000) }
        let interaction = try XCTUnwrap(queue.tasks.first?.interactions.first)
        var responseError: String?
        queue.respond(taskID: id, interaction: interaction, answers: ["scope": "README"]) { responseError = $0 }
        for _ in 0..<200 where responseError == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(responseError, "Fixture response failure")
        XCTAssertEqual(queue.tasks.first?.state, .needsInput)
        XCTAssertEqual(queue.tasks.first?.interactions, [interaction])
        XCTAssertFalse(queue.tasks.first?.activity.contains("You: README") == true)
        var completed = false
        queue.respond(taskID: id, interaction: interaction, answers: ["scope": "README"]) { error in
            XCTAssertNil(error)
            completed = true
        }
        try await waitForCompletion(queue)
        XCTAssertTrue(completed)
        XCTAssertEqual(queue.tasks.first?.state, .resolved)
        XCTAssertEqual(queue.tasks.first?.conversation?.filter { $0.kind == .user && $0.text == "README" }.count, 1)
    }
    func testCancellationVerifiesPartialChanges() async throws {
        let snapshot = try repository()
        let agent = InteractiveRepairAgent(writeBeforeWaiting: true)
        let queue = try makeQueue(storage: storage, agentFactory: { agent })
        let id = try queue.enqueue(finding: finding(snapshot), repository: snapshot, prompt: "Repair")
        for _ in 0..<200 where queue.tasks.first?.state != .needsInput { try await Task.sleep(nanoseconds: 10_000_000) }
        queue.cancel(id)
        try await waitForCompletion(queue)
        XCTAssertEqual(queue.tasks.first?.execution, .cancelled)
        XCTAssertEqual(queue.tasks.first?.state, .resolved)
    }
    func testCorruptStorageAndFailedWriteDoNotStartAgent() async throws {
        try Data("invalid".utf8).write(to: storage.url)
        XCTAssertThrowsError(try makeQueue(storage: storage, agentFactory: { TestRepairAgent() }))
        try FileManager.default.removeItem(at: storage.url)
        let queue = try makeQueue(storage: storage, agentFactory: { TestRepairAgent() })
        let snapshot = try repository()
        try FileManager.default.removeItem(at: storage.url)
        try FileManager.default.createDirectory(at: storage.url, withIntermediateDirectories: true)
        XCTAssertThrowsError(try queue.enqueue(finding: finding(snapshot), repository: snapshot, prompt: "Repair"))
        XCTAssertTrue(queue.tasks.isEmpty)
    }
    func testLinkedWorktreesShareTheSchedulingIdentity() throws {
        let snapshot = try repository()
        _ = try GitRunner.run(["config", "user.name", "Test"], at: snapshot.url)
        _ = try GitRunner.run(["config", "user.email", "test@example.invalid"], at: snapshot.url)
        _ = try GitRunner.run(["-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "--allow-empty", "-m", "Initial"], at: snapshot.url)
        let linked = root.appendingPathComponent("linked")
        _ = try GitRunner.run(["worktree", "add", "-b", "linked", linked.path], at: snapshot.url)
        XCTAssertEqual(try RepairTaskQueue.commonDirectory(at: snapshot.url), try RepairTaskQueue.commonDirectory(at: linked))
    }
    func testContentDetectorAndPromptRecipeNeedNoRunnerChanges() async throws {
        let snapshot = try repository()
        try "TODO".write(to: snapshot.url.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let detector = RepositoryCheck(id: "custom.notes", title: "Unfinished notes", category: .documentation, symbol: "doc", inspect: { context in
            let content = try context.readText("notes.txt")
            return content.contains("TODO") ? [RepositoryFinding(repositoryID: context.snapshot.id, checkID: "custom.notes",
                subject: "notes.txt", title: "Unfinished notes", evidence: "TODO remains", category: .documentation, symbol: "doc", recipeIDs: ["custom.finish"])] : []
        })
        let catalog = RepositoryIssueCatalog(checks: [detector])
        let report = await catalog.inspect(snapshot)
        let finding = try XCTUnwrap(report.findings().first)
        let recipe = RepairRecipe(id: "custom.finish", title: "Finish notes", prompt: "Finish the notes.")
        XCTAssertEqual(RepairRecipeCatalog(recipes: [recipe]).recipes(for: finding), [recipe])
        let queue = try makeQueue(storage: storage, agentFactory: { TestRepairAgent { task in
            try "Complete".write(to: task.repositoryURL.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        } }, catalog: catalog)
        try queue.enqueue(finding: finding, repository: snapshot, prompt: recipe.prompt, recipeID: recipe.id)
        try await waitForCompletion(queue)
        XCTAssertEqual(queue.tasks.first?.state, .resolved)
    }
    func testPreservingFetchErrorKeepsInspectionFindingVisible() async throws {
        var snapshot = try repository()
        let catalog = testCatalog
        let report = await catalog.inspect(snapshot)
        snapshot.fetchError = "Fetch failed earlier"
        let updated = report.updatingSnapshot(snapshot, catalog: catalog)
        XCTAssertTrue(updated.findings().contains { $0.checkID == "inspection.remote" })
        XCTAssertEqual(updated.checkOrder, catalog.checks.map(\.id))
    }

    func testInspectionContextRejectsEscapingSymlinksAndPaths() throws {
        let snapshot = try repository()
        let context = RepositoryInspectionContext(snapshot: snapshot)
        XCTAssertThrowsError(try context.readText("../tasks.json"))
        try FileManager.default.createSymbolicLink(at: snapshot.url.appendingPathComponent("escape"), withDestinationURL: root)
        XCTAssertThrowsError(try context.readText("escape/tasks.json"))
    }

    func testMissingDetectorAndInspectionErrorsRemainUnknown() throws {
        let snapshot = try repository()
        let original = try finding(snapshot)
        if case .unknown = RepositoryIssueCatalog(checks: []).verify(original, in: snapshot) {} else { XCTFail("Missing detector was treated as success") }
        let worktreeFinding = RepositoryFinding(repositoryID: snapshot.id, checkID: "git.worktrees", subject: "main", title: "Worktrees", evidence: "One", category: .git, symbol: "square")
        let unavailable = RepositorySnapshot(url: snapshot.url, name: "repo", branch: "main", upstream: nil, remoteURL: nil,
            ahead: nil, behind: nil, changes: [], staleBranches: [], worktrees: [], commits: [], rootFiles: [],
            inspectionErrors: ["worktrees": "Git inspection failed"])
        if case .unknown = testCatalog.verify(worktreeFinding, in: unavailable) {} else { XCTFail("Failed inspection was treated as absence") }
    }
}

private actor SequencedInspector {
    let snapshot: RepositorySnapshot
    var calls = 0
    init(snapshot: RepositorySnapshot) { self.snapshot = snapshot }
    func next() throws -> RepositorySnapshot {
        calls += 1
        if calls > 1 { throw RepairError.blocked("Inspection unavailable") }
        return snapshot
    }
}
private actor AsyncQuestionRepairAgent: RepairAgent {
    var submissions: [RepairTask] = []
    var responseCalls = 0
    let holdFirstTurn: Bool
    var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }
    let interaction = AgentInteraction(id: "async-turn:question", kind: .questions, title: "Scope", details: "",
        questions: [AgentQuestion(id: "scope", question: "Which action?", options: ["Write README", "Keep unchanged"])], delivery: .followUp)
    init(holdFirstTurn: Bool = false) { self.holdFirstTurn = holdFirstTurn }
    func run(_ task: RepairTask, event: @escaping @Sendable (RepairAgentEvent) async -> Void) async throws -> RepairExecutionOutcome {
        submissions.append(task)
        await event(.session(threadID: task.threadID ?? "async-thread", turnID: "async-turn"))
        if task.currentPrompt.contains("Answer: Write README") {
            try "# README".write(to: task.repositoryURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        } else {
            await event(.interaction(interaction))
            if holdFirstTurn { await withCheckedContinuation { continuation = $0 } }
        }
        return .completed
    }
    func recover(_ task: RepairTask) async throws -> RepairExecutionOutcome { .completed }
    func recover(_ task: RepairTask, event: @escaping @Sendable (RepairAgentEvent) async -> Void) async throws -> RepairExecutionOutcome {
        await event(.interaction(interaction)); return .completed
    }
    func respond(to interaction: AgentInteraction, answers: [String: String], approved: Bool) async throws { responseCalls += 1 }
    func finishTurn() { continuation?.resume(); continuation = nil }
    func cancel() async { finishTurn() }
}

private actor TestRepairAgent: RepairAgent {
    var runs = 0; var recoveries = 0; var active = 0; var maxActive = 0
    let operation: @Sendable (RepairTask) throws -> Void
    init(operation: @escaping @Sendable (RepairTask) throws -> Void = { _ in }) { self.operation = operation }
    func run(_ task: RepairTask, event: @escaping @Sendable (RepairAgentEvent) async -> Void) async throws -> RepairExecutionOutcome {
        runs += 1; active += 1; maxActive = max(maxActive, active)
        defer { active -= 1 }
        await event(.session(threadID: "test", turnID: "turn"))
        try await Task.sleep(nanoseconds: 20_000_000)
        try operation(task)
        return .completed
    }
    func recover(_ task: RepairTask) async throws -> RepairExecutionOutcome { recoveries += 1; return .completed }
    func respond(to interaction: AgentInteraction, answers: [String: String], approved: Bool) async throws {}
    func cancel() async {}
}
private actor InteractiveRepairAgent: RepairAgent {
    let writeBeforeWaiting: Bool
    var rejectFirstResponse: Bool
    var continuation: CheckedContinuation<RepairExecutionOutcome, Never>?
    init(writeBeforeWaiting: Bool = false, rejectFirstResponse: Bool = false) {
        self.writeBeforeWaiting = writeBeforeWaiting; self.rejectFirstResponse = rejectFirstResponse
    }
    func run(_ task: RepairTask, event: @escaping @Sendable (RepairAgentEvent) async -> Void) async throws -> RepairExecutionOutcome {
        if writeBeforeWaiting { try write(task) }
        await event(.session(threadID: "same-thread", turnID: "same-turn"))
        await event(.interaction(AgentInteraction(id: "question", kind: .questions, title: "Scope", details: "", questions: [AgentQuestion(id: "scope", question: "Which file?")])))
        let result = await withCheckedContinuation { continuation = $0 }
        if result == .completed { try write(task) }
        return result
    }
    func write(_ task: RepairTask) throws { try "# README".write(to: task.repositoryURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8) }
    func respond(to interaction: AgentInteraction, answers: [String: String], approved: Bool) async throws {
        if rejectFirstResponse { rejectFirstResponse = false; throw RepairError.blocked("Fixture response failure") }
        continuation?.resume(returning: .completed); continuation = nil
    }
    func cancel() async { continuation?.resume(returning: .cancelled); continuation = nil }
    func recover(_ task: RepairTask) async throws -> RepairExecutionOutcome { .interrupted }
}

private actor ConversationRepairAgent: RepairAgent {
    func run(_ task: RepairTask, event: @escaping @Sendable (RepairAgentEvent) async -> Void) async throws -> RepairExecutionOutcome {
        await event(.conversationDelta(id: "intro", kind: .assistant, text: "I’ll inspect "))
        await event(.conversationDelta(id: "intro", kind: .assistant, text: "this checkout."))
        await event(.conversation(RepairConversationEntry(id: "intro", kind: .assistant, text: "I’ll inspect **this checkout**.", status: "completed")))
        await event(.conversation(RepairConversationEntry(id: "status", kind: .command, text: "git status --short", status: "inProgress")))
        await event(.conversation(RepairConversationEntry(id: "test", kind: .command, text: "swift test", status: "inProgress")))
        await event(.conversationDelta(id: "status", kind: .command, text: " M notes.txt\n"))
        await event(.conversationDelta(id: "test", kind: .command, text: "first\n"))
        await event(.conversationDelta(id: "test", kind: .command, text: "second\n"))
        await event(.conversation(RepairConversationEntry(id: "test", kind: .command, text: "swift test", status: "failed", exitCode: 1)))
        await event(.conversation(RepairConversationEntry(id: "status", kind: .command, text: "git status --short", output: " M notes.txt\n", status: "completed", exitCode: 0)))
        await event(.conversationDelta(id: "result", kind: .assistant, text: "The check failed; no files changed."))
        return .completed
    }
    func recover(_ task: RepairTask) async throws -> RepairExecutionOutcome { .completed }
    func respond(to interaction: AgentInteraction, answers: [String: String], approved: Bool) async throws {}
    func cancel() async {}
}

private actor BufferedConversationRepairAgent: RepairAgent {
    private var continuation: CheckedContinuation<RepairExecutionOutcome, Never>?
    var isWaiting: Bool { continuation != nil }
    func run(_ task: RepairTask, event: @escaping @Sendable (RepairAgentEvent) async -> Void) async throws -> RepairExecutionOutcome {
        await event(.session(threadID: "persistent-thread", turnID: "persistent-turn"))
        await event(.conversationDelta(id: "persistent-turn:reply", kind: .assistant, text: "Reading the project"))
        await event(.conversation(RepairConversationEntry(id: "persistent-turn:command", kind: .command,
            text: "git status --short", status: "inProgress")))
        await event(.conversationDelta(id: "persistent-turn:command", kind: .command, text: "first line\n"))
        await event(.conversationDelta(id: "persistent-turn:command", kind: .command, text: "last buffered line\n"))
        return await withCheckedContinuation { continuation = $0 }
    }
    func recover(_ task: RepairTask) async throws -> RepairExecutionOutcome { .interrupted }
    func respond(to interaction: AgentInteraction, answers: [String: String], approved: Bool) async throws {}
    func cancel() async { continuation?.resume(returning: .cancelled); continuation = nil }
}

private actor MultiTurnRepairAgent: RepairAgent {
    var submissions: [RepairTask] = []
    func run(_ task: RepairTask, event: @escaping @Sendable (RepairAgentEvent) async -> Void) async throws -> RepairExecutionOutcome {
        submissions.append(task)
        await event(.session(threadID: task.threadID ?? "issue-thread", turnID: "turn-\(submissions.count)"))
        await event(.conversation(RepairConversationEntry(id: "reply-\(submissions.count)", kind: .assistant, text: "Turn \(submissions.count)")))
        if task.currentPrompt == "Finish README now." {
            try "# README".write(to: task.repositoryURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        }
        return .completed
    }
    func recover(_ task: RepairTask) async throws -> RepairExecutionOutcome { .completed }
    func respond(to interaction: AgentInteraction, answers: [String: String], approved: Bool) async throws {}
    func cancel() async {}
}

/// Holds sessions open so concurrency, routing, and cancellation assertions never depend on run speed.
private actor HeldRepairAgent: RepairAgent {
    let label: String
    let file: String
    var answers: [String] = []
    var continuation: CheckedContinuation<RepairExecutionOutcome, Never>?
    var isWaiting: Bool { continuation != nil }
    init(label: String, file: String) { self.label = label; self.file = file }
    func run(_ task: RepairTask, event: @escaping @Sendable (RepairAgentEvent) async -> Void) async throws -> RepairExecutionOutcome {
        await event(.session(threadID: label, turnID: "turn"))
        await event(.conversation(RepairConversationEntry(id: "same-item", kind: .assistant, text: label)))
        await event(.interaction(AgentInteraction(id: "same-request", kind: .questions, title: "Scope", details: "",
            questions: [AgentQuestion(id: "scope", question: "Which file?")])))
        let result = await withCheckedContinuation { continuation = $0 }
        if result == .completed {
            try "Ready\n".write(to: task.repositoryURL.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        return result
    }
    func recover(_ task: RepairTask) async throws -> RepairExecutionOutcome { .interrupted }
    func respond(to interaction: AgentInteraction, answers: [String: String], approved: Bool) async throws {
        if let answer = answers["scope"] { self.answers.append(answer) }
        continuation?.resume(returning: .completed); continuation = nil
    }
    func cancel() async { continuation?.resume(returning: .cancelled); continuation = nil }
}
