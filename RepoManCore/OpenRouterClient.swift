import Foundation

public struct OpenRouterModel: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
}
public struct OpenRouterProvider: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let supportedParameters: Set<String>
}

/// OpenRouter is an adapter for the generic skill evaluator. No repository-specific logic lives here.
public struct OpenRouterClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let transport: Transport
    private let catalog: OpenRouterProviderCatalog
    public init(transport: Transport? = nil) {
        catalog = transport == nil ? .shared : OpenRouterProviderCatalog()
        self.transport = transport ?? { request in
            let (data, response) = try await OpenRouterSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw RepairError.blocked("OpenRouter returned an invalid HTTP response.") }
            return (data, response)
        }
    }

    public func models() async throws -> [OpenRouterModel] {
        let data = try await send(path: "models", maximumBytes: 8_388_608)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["data"] as? [[String: Any]], models.count <= 4_000 else {
            throw RepairError.blocked("OpenRouter model catalog could not be read.")
        }
        return models.compactMap { entry in
            guard let id = entry["id"] as? String, let parameters = entry["supported_parameters"] as? [String],
                  parameters.contains("structured_outputs"), parameters.contains("response_format"),
                  (try? ModelCheckConfiguration(service: .openRouter, modelID: id).validate()) != nil else { return nil }
            return OpenRouterModel(id: id, name: entry["name"] as? String ?? id)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public func providers(for modelID: String) async throws -> [OpenRouterProvider] {
        try await catalog.load(modelID) { try await fetchProviders(for: modelID) }
    }
    private func fetchProviders(for modelID: String) async throws -> [OpenRouterProvider] {
        try ModelCheckConfiguration(service: .openRouter, modelID: modelID).validate()
        let data = try await send(path: "models/" + modelID + "/endpoints", maximumBytes: 2_097_152)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = object["data"] as? [String: Any], let endpoints = model["endpoints"] as? [[String: Any]], endpoints.count <= 200 else {
            throw RepairError.blocked("OpenRouter providers could not be read.")
        }
        var seen = Set<String>()
        return endpoints.compactMap { entry in
            guard let id = entry["tag"] as? String, let name = entry["provider_name"] as? String,
                  let parameters = entry["supported_parameters"] as? [String],
                  parameters.contains("structured_outputs"), parameters.contains("response_format"),
                  seen.insert(id).inserted else { return nil }
            return OpenRouterProvider(id: id, name: name, supportedParameters: Set(parameters))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public func testConnection(token: String) async throws { _ = try await send(path: "key", token: token) }

    public func evaluate(_ input: SkillModelRequest, token: String) async throws -> [String: SkillRuleDecision] {
        try input.configuration.validate()
        guard input.configuration.service == .openRouter else { throw RepairError.blocked("Choose OpenRouter for this review.") }
        let rules = input.contract.rules.filter { $0.evaluation == .semantic }
        guard !rules.isEmpty else { return [:] }
        let endpoints = try await providers(for: input.configuration.modelID)
        let selected = input.configuration.providerID.isEmpty ? endpoints : endpoints.filter { $0.id == input.configuration.providerID }
        guard !selected.isEmpty else { throw RepairError.blocked("The selected OpenRouter provider does not offer structured reviews for this model.") }
        if input.configuration.reasoning != .automatic, !selected.contains(where: { $0.supportedParameters.contains("reasoning") }) {
            throw RepairError.blocked("This model provider does not support reasoning settings. Choose Model default reasoning.")
        }
        let schema = try JSONSerialization.jsonObject(with: JSONEncoder().encode(input.outputSchema))
        var preferences: [String: Any] = ["require_parameters": true]
        if !input.configuration.providerID.isEmpty {
            preferences["only"] = [input.configuration.providerID]
            preferences["allow_fallbacks"] = false
        }
        var body: [String: Any] = ["model": input.configuration.modelID, "max_tokens": 2_000,
            "provider": preferences,
            "response_format": ["type": "json_schema", "json_schema": ["name": "skill_consistency", "strict": true, "schema": schema]],
            "messages": [["role": "system", "content": input.instructions],
                         ["role": "user", "content": try input.context()]]]
        if selected.contains(where: { $0.supportedParameters.contains("temperature") }) { body["temperature"] = 0 }
        switch input.configuration.reasoning {
        case .automatic: break
        case .disabled: body["reasoning"] = ["enabled": false]
        case .minimal, .low: body["reasoning"] = ["effort": input.configuration.reasoning.rawValue]
        }
        let data = try await send(path: "chat/completions", token: token, body: JSONSerialization.data(withJSONObject: body))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]], choices.count == 1,
              choices[0]["finish_reason"] as? String == "stop",
              let message = choices[0]["message"] as? [String: Any], message["refusal"] == nil || message["refusal"] is NSNull,
              let content = message["content"] as? String, let json = content.data(using: .utf8),
              let result = try JSONSerialization.jsonObject(with: json) as? [String: Any], Set(result.keys) == ["rules"],
              let answers = result["rules"] as? [String: Any], Set(answers.keys) == Set(rules.map(\.id)),
              answers.values.allSatisfy({ value in
                  guard let answer = value as? [String: Any] else { return false }
                  return Set(answer.keys) == ["verdict", "reason", "evidenceDocument", "evidenceQuote"]
              }) else { throw RepairError.blocked("OpenRouter returned an incomplete or invalid review; the result is unknown.") }
        return try JSONDecoder().decode(ReviewResponse.self, from: json).rules
    }
    private struct ReviewResponse: Decodable { let rules: [String: SkillRuleDecision] }

    private func send(path: String, token: String? = nil, body: Data? = nil, maximumBytes: Int = 2_097_152) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/" + path)!)
        request.timeoutInterval = 30
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("RepoMan", forHTTPHeaderField: "X-Title")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let response: (Data, HTTPURLResponse)
        let outbound = request
        do { response = try await OpenRouterRequestLimiter.shared.run { try await transport(outbound) } }
        catch is CancellationError { throw CancellationError() }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw RepairError.blocked("OpenRouter could not be reached. Check the connection and retry.")
        }
        guard (200..<300).contains(response.1.statusCode) else {
            // Never echo remote error bodies: they may contain credentials or request content.
            let message: String
            switch response.1.statusCode {
            case 401, 403: message = "OpenRouter authentication failed. Check the saved API key and account access."
            case 402: message = "OpenRouter has insufficient credits."
            case 429: message = "OpenRouter rate limit reached. Retry later."
            case 400, 404: message = "OpenRouter rejected the model, provider or review settings. Check this rule’s configuration."
            default: message = "OpenRouter request failed (HTTP \(response.1.statusCode)). Retry later."
            }
            throw RepairError.blocked(message)
        }
        guard response.0.count <= maximumBytes else { throw RepairError.blocked("OpenRouter response exceeded the inspection limit.") }
        return response.0
    }
}

private enum OpenRouterSession {
    static let shared: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 45
        config.httpMaximumConnectionsPerHost = 4
        config.httpShouldSetCookies = false
        return URLSession(configuration: config, delegate: OpenRouterRedirectPolicy(), delegateQueue: nil)
    }()
}
private final class OpenRouterRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
private actor OpenRouterRequestLimiter {
    static let shared = OpenRouterRequestLimiter()
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func run(_ operation: @Sendable () async throws -> (Data, HTTPURLResponse)) async throws -> (Data, HTTPURLResponse) {
        if active < 4 { active += 1 }
        else { await withCheckedContinuation { waiting.append($0) } }
        defer {
            if waiting.isEmpty { active -= 1 }
            else { waiting.removeFirst().resume() }
        }
        try Task.checkCancellation()
        return try await operation()
    }
}

private actor OpenRouterProviderCatalog {
    static let shared = OpenRouterProviderCatalog()
    private var values: [String: (Date, [OpenRouterProvider])] = [:]
    private var pending: [String: Task<[OpenRouterProvider], Error>] = [:]
    func load(_ model: String, fetch: @escaping @Sendable () async throws -> [OpenRouterProvider]) async throws -> [OpenRouterProvider] {
        if let value = values[model], (0..<1_800).contains(Date().timeIntervalSince(value.0)) { return value.1 }
        if let task = pending[model] { return try await task.value }
        let task = Task { try await fetch() }
        pending[model] = task
        defer { pending.removeValue(forKey: model) }
        let providers = try await task.value
        if values.count >= 100, let oldest = values.min(by: { $0.value.0 < $1.value.0 })?.key { values.removeValue(forKey: oldest) }
        values[model] = (Date(), providers)
        return providers
    }
}
