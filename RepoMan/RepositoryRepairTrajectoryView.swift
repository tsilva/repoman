import SwiftUI

/// The selected issue's stored conversation, including its completed turns and verification.
struct RepositoryRepairTrajectoryView: View {
    let task: RepairTask
    var onShowChanges: () -> Void = {}
    @State private var parsedDiff = RepairDiff("")
    private var entries: [RepairConversationEntry] {
        task.conversation ?? (task.activity.isEmpty ? [] : [RepairConversationEntry(id: "legacy", kind: .assistant, text: task.activity)])
    }
    private var progressTitle: String? {
        switch task.state {
        case .queued: return "Queued…"
        case .running:
            if task.message.hasPrefix("Cancelling") { return "Stopping…" }
            return entries.contains { [.command, .fileChange].contains($0.kind) && $0.status == "inProgress" }
                ? "Working…" : "Thinking…"
        case .checking: return "Checking issue…"
        case .interrupted: return "Restoring conversation…"
        default: return nil
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            RepairUserMessage(text: task.prompt)
            ForEach(entries) { entry in
                switch entry.kind {
                case .user: RepairUserMessage(text: entry.text)
                case .assistant:
                    if !entry.text.isEmpty, !task.interactions.contains(where: { $0.id == entry.id && $0.kind == .questions }) {
                        Text((try? AttributedString(markdown: entry.text,
                            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(entry.text))
                            .font(.system(size: 12)).lineSpacing(3).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .command:
                    RepairCommandView(entry: entry, isActive: task.execution == nil && [.running, .needsInput].contains(task.state))
                case .status:
                    Label(entry.text, systemImage: ["resolved", "noLongerNeeded"].contains(entry.status ?? "") ? "checkmark.circle" : "info.circle")
                        .font(.system(size: 11)).foregroundStyle(["resolved", "noLongerNeeded"].contains(entry.status ?? "") ? Theme.green : Theme.secondary)
                        .textSelection(.enabled)
                case .fileChange:
                    Label(entry.text.isEmpty ? "Updated files" : entry.text, systemImage: "doc.badge.gearshape")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary).textSelection(.enabled)
                }
            }
            if !task.diff.isEmpty {
                RepairChangesBadge(diff: parsedDiff, action: onShowChanges)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 12)
            }
            ForEach(task.interactions.filter { $0.kind == .questions }) { interaction in
                RepairInteractionView(taskID: task.id, interaction: interaction).id(interaction.id)
            }
            if let progressTitle { RepairProgressIndicator(title: progressTitle) }
            if !task.state.isActive, !entries.contains(where: { $0.kind == .status }) {
                Label(task.message, systemImage: task.state == .resolved ? "checkmark.circle" : "info.circle")
                    .font(.system(size: 11)).foregroundStyle(task.state == .resolved ? Theme.green : Theme.secondary)
                    .textSelection(.enabled)
            }
        }.foregroundStyle(Theme.primary)
            .task(id: task.diff) {
                let source = task.diff
                let parsed = await Task.detached(priority: .userInitiated) { RepairDiff(source) }.value
                guard !Task.isCancelled else { return }
                parsedDiff = parsed
            }
    }
}

/// A quiet live status in the assistant stream, including before its first message arrives.
private struct RepairProgressIndicator: View {
    let title: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bright = false

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini)
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                .opacity(reduceMotion || bright ? 1 : 0.5)
                .animation(reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: bright)
        }
        .onAppear { bright = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

private struct RepairUserMessage: View {
    let text: String
    var body: some View {
        HStack {
            Spacer(minLength: 24)
            Text(text).font(.system(size: 12)).lineSpacing(2).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true).padding(12)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 12))
        }.frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct RepairCommandView: View {
    let entry: RepairConversationEntry
    let isActive: Bool
    @State private var expanded = false
    private var running: Bool { isActive && entry.status == "inProgress" }
    private var failed: Bool { entry.status == "failed" || (entry.exitCode.map { $0 != 0 } ?? false) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 7) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .semibold))
                    Image(systemName: "terminal").font(.system(size: 11))
                    Text(entry.text).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if running { ProgressView().controlSize(.mini) }
                    else if failed {
                        Text(entry.exitCode.map { "Exit \($0)" } ?? "Failed").font(.system(size: 10)).foregroundStyle(Theme.amber)
                    } else if entry.status == "completed" {
                        Image(systemName: "checkmark").font(.system(size: 9)).foregroundStyle(Theme.secondary)
                    }
                }.foregroundStyle(Theme.secondary).contentShape(Rectangle())
            }.buttonStyle(.plain).help(entry.text)
                .accessibilityLabel("Shell command: " + entry.text)
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    Text(entry.text).foregroundStyle(Theme.primary)
                    if let output = entry.output, !output.isEmpty {
                        Divider().overlay(Theme.border)
                        Text(output).foregroundStyle(Theme.secondary)
                    }
                }.font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .background(Theme.field, in: RoundedRectangle(cornerRadius: 6))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RepairInteractionView: View {
    @EnvironmentObject private var store: RepositoryStore
    let taskID: UUID
    let interaction: AgentInteraction
    @State private var answers: [String: String] = [:]
    @State private var submitting = false
    @State private var submissionError: String?
    private var canSubmit: Bool {
        !interaction.questions.isEmpty && interaction.questions.allSatisfy {
            !(answers[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(interaction.title, systemImage: "questionmark.bubble")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.amber)
            if !interaction.details.isEmpty { Text(interaction.details).textSelection(.enabled) }
            ForEach(interaction.questions) { question in
                VStack(alignment: .leading, spacing: 8) {
                    if let header = question.header, !header.isEmpty {
                        Text(header).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.secondary)
                    }
                    Text(question.question).font(.system(size: 12, weight: .medium)).textSelection(.enabled)
                    if !question.options.isEmpty {
                        ForEach(question.options, id: \.self) { option in
                            Button { answers[question.id] = option } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: answers[question.id] == option ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(answers[question.id] == option ? Theme.blue : Theme.secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(option).foregroundStyle(Theme.primary)
                                        if let description = question.optionDescriptions?[option], !description.isEmpty {
                                            Text(description).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.padding(10).contentShape(Rectangle())
                                    .background(answers[question.id] == option ? Theme.selection : Theme.field,
                                                in: RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6)
                                        .stroke(answers[question.id] == option ? Theme.blue : Theme.border, lineWidth: 1))
                            }.buttonStyle(.plain)
                                .accessibilityLabel(option)
                                .accessibilityValue(answers[question.id] == option ? "Selected" : "Not selected")
                        }
                    }
                    TextField(question.options.isEmpty ? "Your answer" : "Or type your own answer", text: Binding(
                        get: { answers[question.id] ?? "" }, set: { answers[question.id] = $0 }))
                        .textFieldStyle(.roundedBorder).accessibilityLabel("Answer: " + question.question)
                }
            }
            if let submissionError { Text(submissionError).font(.system(size: 11)).foregroundStyle(Theme.red) }
            HStack {
                Text("Waiting for your answer").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                Spacer()
                Button(submitting ? "Sending…" : "Send answers") { respond() }
                    .buttonStyle(RepositoryButtonStyle()).disabled(!canSubmit)
            }
        }.font(.system(size: 12)).disabled(store.isDemo || submitting).padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.control, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
    }
    private func respond() {
        guard canSubmit, !submitting else { return }
        submitting = true
        submissionError = nil
        store.respondToTask(taskID, interaction: interaction, answers: answers, approved: false) { error in
            submitting = false
            submissionError = error
        }
    }
}
