import CryptoKit
import Foundation

/// Skill acceptance is data. Evidence collection and mechanical validators belong to each check.
public struct SkillAcceptanceContract: Codable, Equatable, Sendable {
    public struct Rule: Codable, Equatable, Sendable {
        public enum Evaluation: String, Codable, Sendable { case mechanical, semantic }
        public let id: String
        public let title: String
        public let condition: String
        public let evaluation: Evaluation
    }
    public let skill: String
    public let version: String
    public let scope: String
    public let rules: [Rule]

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 65_536 else { throw RepairError.blocked("Skill acceptance document exceeds 64 KiB.") }
        let contract = try JSONDecoder().decode(Self.self, from: data)
        guard !contract.skill.isEmpty, !contract.version.isEmpty, !contract.rules.isEmpty, contract.rules.count <= 64,
              Set(contract.rules.map(\.id)).count == contract.rules.count,
              contract.rules.allSatisfy({ !$0.title.isEmpty && !$0.condition.isEmpty &&
                  $0.id.range(of: #"^[a-zA-Z0-9_.-]+$"#, options: .regularExpression) != nil }) else {
            throw RepairError.blocked("Skill acceptance document has invalid or duplicate rules.")
        }
        return contract
    }
}

public struct SkillEvidenceDocument: Codable, Equatable, Sendable {
    public let id: String
    public let text: String
    public init(id: String, text: String) { self.id = id; self.text = text }
}

public struct SkillRuleDecision: Codable, Equatable, Sendable {
    public enum Verdict: String, Codable, Sendable { case pass, fail, uncertain, notApplicable = "not_applicable" }
    public let verdict: Verdict
    public let reason: String
    public let evidenceDocument: String
    public let evidenceQuote: String
    public init(_ verdict: Verdict, reason: String, evidenceDocument: String = "", evidenceQuote: String = "") {
        self.verdict = verdict; self.reason = reason; self.evidenceDocument = evidenceDocument; self.evidenceQuote = evidenceQuote
    }
}

public struct SkillModelRequest: Sendable {
    public let contract: SkillAcceptanceContract
    public let documents: [SkillEvidenceDocument]
    public let configuration: ModelCheckConfiguration
}

public struct SkillConsistencyReview: Codable, Equatable, Sendable {
    public let decisions: [String: SkillRuleDecision]
    public var violations: Set<String> { Set(decisions.filter { $0.value.verdict == .fail }.keys) }
    public var unknown: Set<String> { Set(decisions.filter { $0.value.verdict == .uncertain }.keys) }
}

/// The same evaluator works with any acceptance document and supplied evidence.
/// Cache keys include evidence, rules, prompt version, model, provider, reasoning and credentials.
public actor SkillConsistencyEvaluator {
    public typealias Inference = @Sendable (SkillModelRequest, String) async throws -> [String: SkillRuleDecision]
    public static let shared = SkillConsistencyEvaluator()
    static let promptVersion = "skill-consistency-v1"
    private struct Cached: Codable {
        let date: Date
        let review: SkillConsistencyReview
    }
    private var values: [String: Cached]
    private var pending: [String: Task<SkillConsistencyReview, Error>] = [:]
    private let cacheURL: URL?
    private let infer: Inference

    public init(cacheURL: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("RepoMan/model-check-cache.json"),
                infer: @escaping Inference = { request, token in try await OpenRouterClient().evaluate(request, token: token) }) {
        self.cacheURL = cacheURL; self.infer = infer
        if let cacheURL, let data = try? Data(contentsOf: cacheURL), data.count <= 4_194_304,
           let saved = try? JSONDecoder().decode([String: Cached].self, from: data) { values = saved }
        else { values = [:] }
    }

    public func review(_ contract: SkillAcceptanceContract, documents: [SkillEvidenceDocument],
                       configuration: ModelCheckConfiguration, token: String,
                       allowCached: Bool, now: Date = Date()) async throws -> (review: SkillConsistencyReview, cached: Bool) {
        try configuration.validate()
        guard !token.isEmpty else { throw RepairError.blocked("Add an OpenRouter API key in Settings → Providers.") }
        guard !documents.isEmpty, documents.count <= 32, Set(documents.map(\.id)).count == documents.count,
              documents.allSatisfy({ !$0.id.isEmpty }), documents.reduce(0, { $0 + $1.text.utf8.count }) <= 131_072 else {
            throw RepairError.blocked("Model-check evidence is missing, duplicated, or exceeds 128 KiB.")
        }
        // Credentials are never included in model inputs, diagnostics, or cache files.
        guard !documents.contains(where: { $0.text.contains(token) ||
            $0.text.range(of: #"sk-or-v1-[a-fA-F0-9]{48,}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"#, options: .regularExpression) != nil }) else {
            throw RepairError.blocked("Evidence contains a credential or private key; model review was skipped.")
        }
        let request = SkillModelRequest(contract: contract, documents: documents, configuration: configuration)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var input = try encoder.encode(contract)
        input.append(try encoder.encode(documents)); input.append(try encoder.encode(configuration))
        input.append(Data(Self.promptVersion.utf8))
        input.append(Data(SHA256.hash(data: Data(token.utf8))))
        let key = SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
        if allowCached, let value = values[key] {
            let age = now.timeIntervalSince(value.date)
            let lifetime: TimeInterval = value.review.unknown.isEmpty ? 86_400 : 300
            if age >= 0, age < lifetime {
                try Self.validate(value.review.decisions, request: request)
                return (value.review, true)
            }
        }
        if allowCached, let task = pending[key] { return (try await task.value, true) }
        let infer = self.infer
        let task = Task {
            let decisions = try await infer(request, token)
            try Self.validate(decisions, request: request)
            return SkillConsistencyReview(decisions: decisions)
        }
        if allowCached { pending[key] = task }
        defer { if allowCached { pending.removeValue(forKey: key) } }
        let review = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            // Shared refreshes may still need their request. Fresh repair checks have no other consumer.
            if !allowCached { task.cancel() }
        }
        try Task.checkCancellation()
        values[key] = Cached(date: now, review: review)
        if values.count > 500, let oldest = values.min(by: { $0.value.date < $1.value.date })?.key { values.removeValue(forKey: oldest) }
        persist()
        return (review, false)
    }

    private static func validate(_ decisions: [String: SkillRuleDecision], request: SkillModelRequest) throws {
        guard Set(decisions.keys) == Set(request.contract.rules.filter { $0.evaluation == .semantic }.map(\.id)) else {
            throw RepairError.blocked("Model response omitted rules or returned unexpected rule IDs.")
        }
        let sources = Dictionary(uniqueKeysWithValues: request.documents.map { ($0.id, $0.text) })
        for decision in decisions.values {
            guard !decision.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, decision.reason.utf8.count <= 1_024,
                  decision.evidenceQuote.utf8.count <= 2_048 else {
                throw RepairError.blocked("Model response has missing or oversized explanations.")
            }
            if decision.evidenceQuote.isEmpty {
                guard decision.verdict == .uncertain else {
                    throw RepairError.blocked("Model response made a judgment without verifiable evidence.")
                }
            } else {
                guard let source = sources[decision.evidenceDocument], source.contains(decision.evidenceQuote) else {
                    throw RepairError.blocked("Model response quoted evidence that could not be verified.")
                }
            }
        }
    }
    private func persist() {
        guard let cacheURL else { return }
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(values).write(to: cacheURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
        } catch {
            // A cache write failure never changes the freshly validated result.
        }
    }
}
