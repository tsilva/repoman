import AppKit
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
                        ConversationMarkdownView(entry.text)
                    }
                case .command:
                    RepairCommandView(entry: entry, isActive: task.execution == nil && [.running, .needsInput].contains(task.state))
                case .status:
                    RepairStatusMessage(message: entry.text,
                        symbol: ["resolved", "noLongerNeeded"].contains(entry.status ?? "") ? "checkmark.circle" : "info.circle",
                        color: ["resolved", "noLongerNeeded"].contains(entry.status ?? "") ? Theme.green : Theme.secondary)
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
            if let progressTitle { RepairProgressIndicator(title: progressTitle) }
            if !task.state.isActive, !entries.contains(where: { $0.kind == .status }) {
                RepairStatusMessage(message: task.message,
                    symbol: task.state == .resolved ? "checkmark.circle" : "info.circle",
                    color: task.state == .resolved ? Theme.green : Theme.secondary)
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

/// Recognizes the stored sign-in error so existing conversations get the same command UI.
struct RepairStatusMessage: View {
    let message: String
    var symbol = "info.circle"
    var color = Theme.secondary

    private var signInCommand: String? {
        guard message.hasPrefix("Sign in to Codex for RepoMan.") else { return nil }
        let parts = message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let command = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return command.hasPrefix("env CODEX_HOME=") ? command : nil
    }

    var body: some View {
        if let command = signInCommand {
            RepairSignInPrompt(command: command)
        } else {
            Label(message, systemImage: symbol)
                .font(.system(size: 11)).foregroundStyle(color).textSelection(.enabled)
        }
    }
}

struct RepairSignInPrompt: View {
    let command: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Sign in to Codex", systemImage: "key")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary)
            Text("Copy and paste this command into Terminal to sign in for RepoMan.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label("Terminal", systemImage: "terminal")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                    Spacer()
                    Button {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        copied = pasteboard.setString(command, forType: .string)
                    } label: {
                        Label(copied ? "Copied" : "Copy command", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(copied ? Theme.green : Theme.primary)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Theme.selection, in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("copy-codex-sign-in-command")
                    .help("Copy the complete command to paste into Terminal")
                }.padding(.horizontal, 12).padding(.vertical, 8)
                Rectangle().fill(Theme.border).frame(height: 1)
                HStack(alignment: .top, spacing: 10) {
                    Text("$").foregroundStyle(Theme.subtle).accessibilityHidden(true)
                    Text(verbatim: command).foregroundStyle(Theme.primary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Sign-in command: " + command)
                }
                .font(.system(size: 11, design: .monospaced)).lineSpacing(4).padding(12)
            }
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1) }
            Text("Once signed in, retry your message here.")
                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: command) { _, _ in copied = false }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}

/// A quiet live status in the assistant stream, including before its first message arrives.
private struct RepairProgressIndicator: View {
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini)
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                .fixedSize()
        }
        // Keep status changes from interpolating the text's glyphs or layout.
        .transaction { $0.animation = nil }
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

struct RepairInteractionView: View {
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
            Label("Input required", systemImage: "questionmark.bubble")
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
                    } else {
                        TextField("Your answer", text: Binding(
                            get: { answers[question.id] ?? "" }, set: { answers[question.id] = $0 }))
                            .textFieldStyle(.roundedBorder).accessibilityLabel("Answer: " + question.question)
                    }
                }
            }
            if let submissionError { Text(submissionError).font(.system(size: 11)).foregroundStyle(Theme.red) }
            HStack {
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
