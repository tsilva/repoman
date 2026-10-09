import Foundation
import Security
import LocalAuthentication

public struct ModelCheckConfiguration: Codable, Equatable, Sendable {
    public enum Service: String, Codable, CaseIterable, Sendable { case codex, openRouter }
    public var service: Service
    public enum Reasoning: String, Codable, CaseIterable, Sendable {
        case automatic, disabled, minimal, low
    }
    public var modelID: String
    /// OpenRouter endpoint tag. Empty delegates routing to OpenRouter.
    public var providerID: String
    public var reasoning: Reasoning

    public init(service: Service = .codex, modelID: String? = nil, providerID: String? = nil,
                reasoning: Reasoning? = nil) {
        self.service = service
        self.modelID = modelID ?? (service == .codex ? CodexStructuredTask.model : "deepseek/deepseek-v4.1-flash")
        self.providerID = providerID ?? (service == .codex ? "" : "wafer")
        self.reasoning = reasoning ?? (service == .codex ? .low : .disabled)
    }

    private enum CodingKeys: String, CodingKey { case service, modelID, providerID, reasoning }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Older preferences had no service selection. Adopt Codex for existing installs too.
        guard let service = try values.decodeIfPresent(Service.self, forKey: .service) else {
            self.init(); return
        }
        self.init(service: service, modelID: try values.decode(String.self, forKey: .modelID),
                  providerID: try values.decode(String.self, forKey: .providerID),
                  reasoning: try values.decode(Reasoning.self, forKey: .reasoning))
    }
    public func validate() throws {
        if service == .codex {
            guard modelID == CodexStructuredTask.model, providerID.isEmpty, reasoning == .low else {
                throw RepairError.blocked("Codex reviews use GPT-6.1 Sol with low reasoning. Restore defaults.")
            }
            return
        }
        let parts = modelID.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              modelID.count <= 150,
              modelID.range(of: #"^[A-Za-z0-9~_.:+-]+/[A-Za-z0-9_.:+-]+$"#, options: .regularExpression) != nil,
              providerID.count <= 150,
              providerID.isEmpty || providerID.range(of: #"^[A-Za-z0-9_./-]+$"#, options: .regularExpression) != nil else {
            throw RepairError.blocked("Choose a valid OpenRouter model and provider.")
        }
    }
}

/// Credentials stay in Keychain; preferences contain only model IDs and a revision counter.
public final class ModelCheckSettings: @unchecked Sendable {
    public static let shared = ModelCheckSettings()
    private let defaults: UserDefaults
    private let lock = NSLock()
    private let readToken: @Sendable () throws -> String?
    private let writeToken: @Sendable (String?) throws -> Void

    public init(defaults: UserDefaults = .standard,
                readToken: @escaping @Sendable () throws -> String? = {
                    if let token = ProcessInfo.processInfo.environment["AGENTBRIDGE_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty { return token }
                    return try AgentBridgeKeychain.read()
                },
                writeToken: @escaping @Sendable (String?) throws -> Void = { try AgentBridgeKeychain.write($0) }) {
        self.defaults = defaults; self.readToken = readToken; self.writeToken = writeToken
    }
    public func configuration(for checkID: String) -> ModelCheckConfiguration {
        lock.lock(); defer { lock.unlock() }
        guard let data = defaults.data(forKey: "modelCheckConfigurations"),
              let configs = try? JSONDecoder().decode([String: ModelCheckConfiguration].self, from: data) else { return .init() }
        return configs[checkID] ?? .init()
    }
    public func setConfiguration(_ configuration: ModelCheckConfiguration, for checkID: String) throws {
        try configuration.validate()
        lock.lock(); defer { lock.unlock() }
        var configs = defaults.data(forKey: "modelCheckConfigurations")
            .flatMap { try? JSONDecoder().decode([String: ModelCheckConfiguration].self, from: $0) } ?? [:]
        configs[checkID] = configuration
        defaults.set(try JSONEncoder().encode(configs), forKey: "modelCheckConfigurations")
        defaults.set(defaults.integer(forKey: "modelCheckRevision") + 1, forKey: "modelCheckRevision")
    }
    public var revision: Int {
        lock.lock(); defer { lock.unlock() }
        return defaults.integer(forKey: "modelCheckRevision")
    }
    public func token() throws -> String? { try readToken() }
    public func setToken(_ token: String?) throws {
        let cleaned = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cleaned, cleaned.isEmpty || cleaned.count > 512 || cleaned.contains(where: { $0.isWhitespace }) {
            throw RepairError.blocked("Enter an AgentBridge token without spaces.")
        }
        try writeToken(cleaned)
        lock.lock(); defer { lock.unlock() }
        defaults.set(defaults.integer(forKey: "modelCheckRevision") + 1, forKey: "modelCheckRevision")
    }
}

public enum AgentBridgeKeychain {
    private static let service = "com.tsilva.RepoMan.agentbridge"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "api-key", kSecAttrSynchronizable as String: false]
    }
    public static func read() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let authentication = LAContext()
        authentication.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = authentication
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
            throw RepairError.blocked("AgentBridge token could not be read from Keychain (\(status)).")
        }
        return key
    }
    public static func write(_ token: String?) throws {
        guard let token else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw RepairError.blocked("AgentBridge token could not be removed from Keychain (\(status)).")
            }
            return
        }
        let data = Data(token.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw RepairError.blocked("AgentBridge token could not be saved in Keychain (\(added)).") }
        } else if status != errSecSuccess {
            throw RepairError.blocked("AgentBridge token could not be saved in Keychain (\(status)).")
        }
    }
}
