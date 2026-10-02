import Foundation

@MainActor
public final class RepairTaskQueue {
    public private(set) var tasks: [RepairTask]
    public private(set) var error: String?
    public var busyCommonDirectories: Set<String> { Set(commonDirectories.values) }
    public var onChange: (() -> Void)?
    public var onInspection: ((RepositoryInspectionReport) -> Void)?
    public var canRun: () -> Bool = { true }
    private let storage: RepairTaskStorage
    private let agentFactory: @MainActor () -> any RepairAgent
    private let catalog: RepositoryIssueCatalog
    private let inspect: @Sendable (URL) async throws -> RepositorySnapshot
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var agents: [UUID: any RepairAgent] = [:]
    private var commonDirectories: [UUID: String] = [:]
    private let maximumConcurrentTurns = 4
    private var cancellationRequested = Set<UUID>()
    private var responding = Set<String>()
    private var started = false
    private var logSave: Task<Void, Never>?

    public init(storage: RepairTaskStorage, agentFactory: @escaping @MainActor () -> any RepairAgent = { CodexAgent() }, catalog: RepositoryIssueCatalog = .init(),
                inspect: @escaping @Sendable (URL) async throws -> RepositorySnapshot = { try await RepairTaskQueue.inspectRepository($0) }) throws {
        self.storage = storage; self.agentFactory = agentFactory; self.catalog = catalog; self.inspect = inspect
        tasks = try storage.load()
        for i in tasks.indices where tasks[i].conversation == nil && !tasks[i].activity.isEmpty {
            tasks[i].conversation = [RepairConversationEntry(id: "legacy", kind: .assistant, text: tasks[i].activity)]
        }
        for i in tasks.indices {
            if let entries = tasks[i].conversation {
                tasks[i].conversation = RepairConversationEntry.removingRepeatedStatuses(from: entries)
            }
            // Completed asynchronous questions have no live server request to reconnect.
            // Their persisted metadata is enough to accept an answer immediately.
            if tasks[i].state == .needsInput, tasks[i].execution == .completed,
               tasks[i].interactionProtocolVersion == 1, tasks[i].threadID != nil,
               !tasks[i].interactions.isEmpty,
               tasks[i].interactions.allSatisfy({ $0.kind == .questions && $0.requiresFollowUp }) {
                continue
            }
            let needsQuestionRecovery = tasks[i].interactionProtocolVersion == nil && !tasks[i].isArchived
                && tasks[i].threadID != nil && tasks[i].turnID != nil
                && [.stillPresent, .couldntVerify, .failed].contains(tasks[i].state)
            guard needsQuestionRecovery || [.running, .needsInput, .checking].contains(tasks[i].state) else { continue }
            tasks[i].state = .interrupted
            tasks[i].interactions.removeAll { !$0.requiresFollowUp }
            tasks[i].message = "Reconciling saved session after interruption. The original prompt will not be resubmitted."
        }
        try saveTasks()
    }

    public nonisolated static func commonDirectory(at url: URL) throws -> String {
        let path = try GitRunner.text(["rev-parse", "--path-format=absolute", "--git-common-dir"], at: url)
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
    public nonisolated static func inspectRepository(_ url: URL) async throws -> RepositorySnapshot {
        try await Task.detached(priority: .utility) {
            var fetchError: String?
            // Fresh refs matter for both preflight and verification, including failed-remote findings.
            let initial = try GitRepositoryScanner.scan(url)
            if initial.upstream != nil || initial.remoteURL != nil {
                do { try GitRepositoryScanner.fetch(url) } catch { fetchError = error.localizedDescription }
            }
            var snapshot = try GitRepositoryScanner.scan(url)
            snapshot.fetchError = fetchError
            if initial.upstream != nil || initial.remoteURL != nil, fetchError == nil { snapshot.fetchedAt = Date() }
            if let fetchError { snapshot = snapshot.withInspectionError("comparison", fetchError) }
            return snapshot
        }.value
    }

    @discardableResult
    public func enqueue(finding: RepositoryFinding, repository: RepositorySnapshot, prompt: String, recipeID: String? = nil) throws -> UUID {
        guard error == nil else { throw RepairError.blocked(error!) }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RepairError.blocked("Enter repair instructions.") }
        guard finding.repositoryID == repository.id else { throw RepairError.blocked("The finding belongs to another repository.") }
        if let index = tasks.firstIndex(where: { $0.finding.id == finding.id && !$0.state.isClosed && !$0.isArchived }) {
            if tasks[index].state.isActive { return tasks[index].id }
            let previous = tasks
            tasks[index].pendingPrompt = prompt
            tasks[index].recipeID = recipeID
            tasks[index].state = .queued
            tasks[index].execution = nil
            tasks[index].verification = nil
            tasks[index].turnID = nil
            tasks[index].message = ""
            tasks[index].interactions = []
            tasks[index].updatedAt = Date()
            tasks[index].upsertConversation(RepairConversationEntry(id: UUID().uuidString, kind: .user, text: prompt))
            let id = tasks[index].id
            do { try saveTasks() } catch { tasks = previous; throw error }
            onChange?(); start()
            return id
        }
        let task = RepairTask(finding: finding, repository: repository, prompt: prompt, recipeID: recipeID)
        let previous = tasks
        tasks.append(task)
        do { try saveTasks() } catch { tasks = previous; throw error }
        onChange?(); start()
        return task.id
    }

    /// Hide an idle conversation without deleting its history or changing detector results.
    public func archive(_ id: UUID) throws {
        guard error == nil else { throw RepairError.blocked(error!) }
        guard let index = tasks.firstIndex(where: { $0.id == id }) else {
            throw RepairError.blocked("This conversation is no longer available.")
        }
        guard !tasks[index].isArchived else { return }
        guard !tasks[index].state.isActive, workers[id] == nil else {
            throw RepairError.blocked("Stop the repair before archiving its conversation.")
        }
        let previous = tasks
        tasks[index].archivedAt = Date()
        tasks[index].updatedAt = Date()
        do { try saveTasks() } catch { tasks = previous; throw error }
        onChange?()
    }

    /// Each issue owns its agent connection; only turns within the same issue are serialized.
    /// Reconciliation never replays a prompt and takes priority over new queued work.
    public func start() {
        started = true
        guard error == nil else { return }
        let canStartTurn = canRun()
        // Reading saved history does not start a repair and must not wait for a full scan.
        let candidates = tasks.filter {
            !$0.isArchived && workers[$0.id] == nil && ($0.state == .interrupted || ($0.state == .queued && canStartTurn))
        }
            .sorted { $0.state == .interrupted && $1.state != .interrupted }
        for task in candidates.prefix(max(0, maximumConcurrentTurns - workers.count)) {
            let agent = agentFactory()
            agents[task.id] = agent
            workers[task.id] = Task { [weak self] in
                guard let self else { return }
                // Cancellation may arrive before this task gets its first actor turn.
                if let current = self.tasks.first(where: { $0.id == task.id }), [.queued, .interrupted].contains(current.state) {
                    await self.perform(current, agent: agent)
                }
                self.finishWorker(task.id)
            }
        }
    }
    private func finishWorker(_ id: UUID) {
        workers.removeValue(forKey: id)
        agents.removeValue(forKey: id)
        commonDirectories.removeValue(forKey: id)
        cancellationRequested.remove(id)
        if error == nil, tasks.contains(where: { $0.id == id && $0.pendingQuestionResponse != nil && $0.state != .cancelled }) {
            update(id) { Self.prepareQuestionFollowUp(&$0) }
        }
        onChange?()
        if started { start() }
    }
    public func cancel(_ id: UUID) {
        guard let task = tasks.first(where: { $0.id == id }), task.state.isActive, task.state != .checking else { return }
        cancellationRequested.insert(id)
        if workers[id] == nil || task.state == .queued {
            update(id) {
                $0.state = .cancelled; $0.execution = .notRun
                $0.message = $0.interactions.isEmpty ? "Cancelled before execution." : "Stopped waiting for answers."
                $0.interactions = []; $0.pendingQuestionResponse = nil
                Self.recordCheck(&$0)
            }
            if workers[id] == nil { cancellationRequested.remove(id) }
        } else {
            update(id) { $0.message = "Cancelling; any partial changes will be checked." }
            if let agent = agents[id] { Task { await agent.cancel() } }
        }
    }
    public func respond(taskID: UUID, interaction: AgentInteraction, answers: [String: String] = [:], approved: Bool = false,
                        completion: @escaping @MainActor (String?) -> Void = { _ in }) {
        let responseID = "\(taskID):\(interaction.id)"
        guard error == nil else { completion(error); return }
        guard tasks.contains(where: { $0.id == taskID && !$0.isArchived && $0.interactions.contains(interaction) }),
              !cancellationRequested.contains(taskID) else {
            completion("This agent request is no longer active.")
            return
        }
        if interaction.requiresFollowUp {
            do { try respondToAsyncQuestion(taskID: taskID, interaction: interaction, answers: answers); completion(nil) }
            catch { completion(error.localizedDescription) }
            return
        }
        guard let agent = agents[taskID] else { completion("This agent request is no longer active."); return }
        guard responding.insert(responseID).inserted else {
            completion("These answers are already being sent.")
            return
        }
        Task {
            defer { responding.remove(responseID) }
            do {
                try await agent.respond(to: interaction, answers: answers, approved: approved)
                update(taskID) {
                    for question in interaction.questions {
                        if let answer = answers[question.id] {
                            $0.activity += "\nYou: \(answer)\n"
                            $0.upsertConversation(RepairConversationEntry(id: UUID().uuidString, kind: .user, text: answer))
                        }
                    }
                    if $0.activity.count > 200_000 { $0.activity = String($0.activity.suffix(200_000)) }
                    guard $0.state == .needsInput || $0.state == .running else { return }
                    $0.interactions.removeAll { $0.id == interaction.id }
                    $0.state = $0.interactions.isEmpty ? .running : .needsInput
                }
                completion(nil)
            } catch {
                update(taskID) { $0.message = error.localizedDescription }
                completion(error.localizedDescription)
            }
        }
    }
    /// Async question tools have already returned. Persist the answer before scheduling a new turn,
    /// allowing the current turn to finish and release its writer before resuming the same thread.
    private func respondToAsyncQuestion(taskID: UUID, interaction: AgentInteraction, answers: [String: String]) throws {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }), tasks[index].threadID != nil,
              tasks[index].state != .interrupted, !interaction.questions.isEmpty else {
            throw RepairError.blocked("This question is not ready for an answer. Wait for session recovery.")
        }
        let response = try interaction.questions.map { question in
            guard let answer = answers[question.id], !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RepairError.blocked("Answer each agent question before continuing.")
            }
            return "Question: \(question.question)\nAnswer: \(answer)"
        }.joined(separator: "\n\n")
        let previous = tasks
        let message = "Answers to Codex questions:\n\n" + response
        tasks[index].pendingQuestionResponse = [tasks[index].pendingQuestionResponse, message].compactMap { $0 }.joined(separator: "\n\n")
        tasks[index].answeredQuestionIDs = (tasks[index].answeredQuestionIDs ?? []) + [interaction.id]
        tasks[index].interactions.removeAll { $0.id == interaction.id }
        tasks[index].upsertConversation(RepairConversationEntry(id: UUID().uuidString, kind: .user, text: response))
        tasks[index].updatedAt = Date()
        if workers[taskID] == nil { Self.prepareQuestionFollowUp(&tasks[index]) }
        else {
            tasks[index].state = tasks[index].interactions.isEmpty ? .running : .needsInput
            tasks[index].message = "Answer saved; continuing this chat when the current turn finishes."
        }
        do { try saveTasks() } catch { tasks = previous; throw error }
        onChange?(); start()
    }
    private static func prepareQuestionFollowUp(_ task: inout RepairTask) {
        guard let response = task.pendingQuestionResponse else { return }
        task.pendingPrompt = response; task.pendingQuestionResponse = nil
        task.state = .queued; task.execution = nil; task.verification = nil; task.turnID = nil
        task.message = ""; task.updatedAt = Date()
    }
    public func recheck(_ id: UUID) {
        guard workers[id] == nil, workers.count < maximumConcurrentTurns, error == nil, canRun(),
              let task = tasks.first(where: { $0.id == id }), !task.isArchived, !task.state.isActive, !task.state.isClosed else { return }
        update(id) { $0.state = .checking }
        workers[id] = Task {
            await verify(task)
            finishWorker(id)
        }
    }
    /// Regular inspections can close an idle issue chat, without starting agent work.
    public func acceptInspection(_ report: RepositoryInspectionReport) {
        for task in tasks where !task.isArchived && !task.state.isActive && !task.state.isClosed && task.finding.repositoryID == report.snapshot.id {
            let snapshot = report.snapshot
            guard snapshot.branch == task.branch, snapshot.upstream == task.upstream,
                  task.remoteURL == nil || snapshot.remoteURL == task.remoteURL else { continue }
            if case .absent(let reason) = catalog.verify(task.finding, in: report) {
                update(task.id) {
                    $0.state = .resolved; $0.verification = .absent(reason); $0.message = reason
                    Self.recordCheck(&$0)
                }
            }
        }
    }
    /// Persist buffered streaming events synchronously before the application exits.
    public func flush() throws {
        logSave?.cancel()
        logSave = nil
        do { try saveTasks() }
        catch {
            reportSaveFailure(error)
            onChange?()
            throw error
        }
    }
    private func saveTasks() throws { try storage.save(tasks) }
    private func reportSaveFailure(_ error: Error) {
        self.error = "Could not save repair tasks: \(error.localizedDescription)"
        let activeAgents = Array(agents.values)
        Task { for agent in activeAgents { await agent.cancel() } }
    }
    private static func recordCheck(_ task: inout RepairTask) {
        if let previous = task.conversation?.last, previous.kind == .status,
           previous.text == task.message, previous.status == task.state.rawValue { return }
        task.upsertConversation(RepairConversationEntry(id: UUID().uuidString, kind: .status,
            text: task.message, status: task.state.rawValue))
    }
    private func update(_ id: UUID, persist: Bool = true, _ mutate: (inout RepairTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        mutate(&tasks[index]); tasks[index].updatedAt = Date()
        do { if persist { try saveTasks() } } catch {
            reportSaveFailure(error)
        }
        onChange?()
    }
    private func assessment(_ task: RepairTask, _ snapshot: RepositorySnapshot) async -> RepairVerification {
        let report = await catalog.inspect(snapshot)
        onInspection?(report)
        guard snapshot.branch == task.branch, snapshot.upstream == task.upstream,
              task.remoteURL == nil || snapshot.remoteURL == task.remoteURL else {
            return .unknown("The branch, upstream, or remote changed. Review the repository before submitting another repair.")
        }
        return catalog.verify(task.finding, in: report)
    }
    private func perform(_ task: RepairTask, agent: any RepairAgent) async {
        do {
            commonDirectories[task.id] = try await Task.detached { try Self.commonDirectory(at: task.repositoryURL) }.value
            onChange?()
            if cancellationRequested.contains(task.id) {
                update(task.id) { $0.execution = .notRun; $0.state = .cancelled }
                return
            }
            if task.state == .interrupted {
                let outcome: RepairExecutionOutcome
                do {
                    outcome = try await agent.recover(task) { [weak self] event in await self?.receive(event, taskID: task.id) }
                    update(task.id) { $0.interactionProtocolVersion = 1 }
                }
                catch {
                    update(task.id) { $0.message = "Session recovery: \(error.localizedDescription)" }
                    outcome = .interrupted
                }
                update(task.id) {
                    $0.execution = cancellationRequested.contains(task.id) ? .cancelled : outcome
                    if !$0.message.hasPrefix("Session recovery:") {
                        $0.message = outcome == .completed ? "Recovered completed agent turn." : "The saved agent turn stopped before completion."
                    }
                }
                await verify(task)
                return
            }
            let snapshot = try await inspect(task.repositoryURL)
            if cancellationRequested.contains(task.id) {
                update(task.id) { $0.execution = .notRun; $0.state = .cancelled }
                return
            }
            // Explicit follow-ups must reach the agent even if the detector is inconclusive
            // or the issue has disappeared. Still require the original repository context.
            let isFollowUp = task.pendingPrompt != nil && snapshot.branch == task.branch && snapshot.upstream == task.upstream
                && (task.remoteURL == nil || snapshot.remoteURL == task.remoteURL)
            switch await assessment(task, snapshot) {
            case .absent(let reason) where !isFollowUp:
                update(task.id) { $0.execution = .notRun; $0.verification = .absent(reason); $0.state = .noLongerNeeded; $0.message = reason; Self.recordCheck(&$0) }
                return
            case .unknown(let reason) where !isFollowUp:
                update(task.id) { $0.execution = .notRun; $0.verification = .unknown(reason); $0.state = .couldntVerify; $0.message = reason; Self.recordCheck(&$0) }
                return
            case .absent(let evidence), .unknown(let evidence), .present(let evidence):
                update(task.id) { $0.latestEvidence = evidence }
            }
            guard error == nil, !cancellationRequested.contains(task.id) else { return }
            update(task.id) { $0.state = .running; $0.interactionProtocolVersion = 1; $0.message = "Running with \($0.agentName)…" }
            let outcome: RepairExecutionOutcome
            do {
                var freshTask = task
                freshTask = tasks.first { $0.id == task.id } ?? freshTask
                outcome = try await agent.run(freshTask) { [weak self] event in await self?.receive(event, taskID: task.id) }
            } catch {
                update(task.id) { $0.message = error.localizedDescription }
                outcome = .failed
            }
            update(task.id) { $0.execution = cancellationRequested.contains(task.id) ? .cancelled : outcome }
            await verify(task)
        } catch {
            update(task.id) { $0.execution = .notRun; $0.verification = .unknown(error.localizedDescription); $0.state = .couldntVerify; $0.message = error.localizedDescription; Self.recordCheck(&$0) }
        }
    }
    private func verify(_ task: RepairTask) async {
        update(task.id) {
            $0.state = .checking
            $0.interactions.removeAll { !$0.requiresFollowUp || $0.kind != .questions }
            if $0.execution == .cancelled { $0.interactions = []; $0.pendingQuestionResponse = nil }
            if var entries = $0.conversation {
                for i in entries.indices where entries[i].kind == .command && entries[i].status == "inProgress" {
                    entries[i].status = $0.execution == .completed ? "completed" : "interrupted"
                }
                $0.conversation = entries
            }
        }
        let result: RepairVerification
        do {
            let snapshot = try await inspect(task.repositoryURL)
            result = await assessment(task, snapshot)
        } catch { result = .unknown(error.localizedDescription) }
        update(task.id) {
            $0.verification = result
            switch result {
            case .absent: $0.state = .resolved
            case .unknown: $0.state = .couldntVerify
            case .present:
                switch $0.execution {
                case .cancelled: $0.state = .cancelled
                case .failed: $0.state = .failed
                case .interrupted: $0.state = .failed
                default: $0.state = .stillPresent
                }
            }
            if $0.execution == .cancelled { $0.message = "Agent stopped. " + result.evidence }
            else if $0.execution == .interrupted, !$0.message.hasPrefix("Session recovery:") {
                $0.message = "Agent run was interrupted. " + result.evidence
            } else if $0.execution == .completed || $0.message.isEmpty { $0.message = result.evidence }
            if !$0.interactions.isEmpty {
                $0.state = .needsInput
                $0.message = "Waiting for your answer."
            }
            Self.recordCheck(&$0)
        }
    }
    private func receive(_ event: RepairAgentEvent, taskID: UUID) {
        let isActivity: Bool
        switch event {
        case .activity, .conversationDelta: isActivity = true
        default: isActivity = false
        }
        update(taskID, persist: !isActivity) {
            switch event {
            case .session(let threadID, let turnID):
                $0.threadID = threadID; $0.codexStorageVersion = 1
                if let turnID { $0.turnID = turnID }
            case .activity(let text):
                $0.activity += text
                if $0.activity.count > 200_000 { $0.activity = String($0.activity.suffix(200_000)) }
                let id = $0.conversation?.last.flatMap { $0.kind == .assistant ? $0.id : nil } ?? UUID().uuidString
                $0.appendConversationDelta(id: id, kind: .assistant, text: text)
            case .conversation(let entry): $0.upsertConversation(entry)
            case .conversationDelta(let id, let kind, let text): $0.appendConversationDelta(id: id, kind: kind, text: text)
            case .failure(let message): $0.message = message
            case .diff(let diff): $0.diff = diff
            case .interaction(let interaction):
                guard !($0.answeredQuestionIDs ?? []).contains(interaction.id) else { return }
                for question in interaction.questions { $0.activity += "\nCodex: \(question.question)\n" }
                if !interaction.questions.isEmpty {
                    $0.upsertConversation(RepairConversationEntry(id: interaction.id, kind: .assistant,
                        text: interaction.questions.map(\.question).joined(separator: "\n\n")))
                }
                if $0.activity.count > 200_000 { $0.activity = String($0.activity.suffix(200_000)) }
                $0.interactions.removeAll { $0.id == interaction.id }
                $0.interactions.append(interaction); $0.state = .needsInput
            case .interactionResolved(let id):
                $0.interactions.removeAll { $0.id == id }; $0.state = $0.interactions.isEmpty ? .running : .needsInput
            }
        }
        if isActivity, logSave == nil {
            logSave = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 500_000_000) }
                catch { return }
                guard let self else { return }
                self.update(taskID) { _ in }
                self.logSave = nil
            }
        }
    }
}

private extension RepositorySnapshot {
    func withInspectionError(_ key: String, _ error: String) -> Self {
        var errors = inspectionErrors; errors[key] = error
        return Self(url: url, name: name, branch: branch, upstream: upstream, remoteURL: remoteURL,
                    ahead: ahead, behind: behind, changes: changes, staleBranches: staleBranches, worktrees: worktrees,
                    commits: commits, detailsLoaded: detailsLoaded, checkedAt: checkedAt, fetchedAt: fetchedAt,
                    fetchError: fetchError, rootFiles: rootFiles, inspectionErrors: errors)
    }
}
