import SwiftUI

struct AgentBridgeSettingsView: View {
    @EnvironmentObject private var store: RepositoryStore
    @State private var token = ""
    @State private var connectionMessage: String?
    @State private var testing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("AgentBridge").font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            Text("Model reviews use AgentBridge. Codex reviews retain GPT-6.1 Sol with low reasoning; OpenRouter models retain their saved model and provider. An optional gateway token stays in Keychain. Set AGENTBRIDGE_BASE_URL for another gateway.")
                .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label(store.hasAgentBridgeToken ? "Gateway token configured" : "No gateway token needed locally",
                  systemImage: store.hasAgentBridgeToken ? "checkmark.circle" : "key")
                .font(.system(size: 13)).foregroundStyle(store.hasAgentBridgeToken ? Theme.green : Theme.secondary)
                .accessibilityIdentifier("settings.openrouter.status")
            HStack {
                SecureField(store.hasAgentBridgeToken ? "Replace API key" : "AgentBridge token", text: $token)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("AgentBridge token")
                    .accessibilityIdentifier("settings.openrouter.token")
                Button("Save key") {
                    if store.saveAgentBridgeToken(token) { token = ""; connectionMessage = "Key saved. README reviews run on the next refresh." }
                }
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isDemo)
                .accessibilityIdentifier("settings.openrouter.save")
            }
            HStack(spacing: 14) {
                Button(testing ? "Testing…" : "Test connection") {
                    testing = true; connectionMessage = nil
                    Task {
                        defer { testing = false }
                        do {
                            let key = try ModelCheckSettings.shared.token() ?? ""
                            try await AgentBridgeClient().testConnection(token: key)
                            connectionMessage = "AgentBridge connection succeeded."
                        } catch { connectionMessage = error.localizedDescription }
                    }
                }
                .disabled(testing || store.isDemo)
                .accessibilityIdentifier("settings.openrouter.test")
                if store.hasAgentBridgeToken {
                    Button("Remove key", role: .destructive) {
                        if store.saveAgentBridgeToken(nil) { token = ""; connectionMessage = "API key removed." }
                    }
                    .disabled(testing || store.isDemo)
                    .accessibilityIdentifier("settings.openrouter.remove")
                }
            }
            if let message = store.agentBridgeSettingsError ?? connectionMessage {
                Text(message).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if store.isDemo {
                Text("Demo mode does not save credentials.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(Theme.border, lineWidth: 1) }
        .onAppear { store.refreshAgentBridgeStatus() }
        .onDisappear { token = "" }
    }
}

/// A single settings sheet is shared by every model-backed check.
struct ModelCheckSettingsView: View {
    @EnvironmentObject private var store: RepositoryStore
    @Environment(\.dismiss) private var dismiss
    let check: RepositoryCheck
    let openProviderSettings: () -> Void
    @State private var configuration: ModelCheckConfiguration
    @State private var models: [OpenRouterModel] = []
    @State private var providers: [OpenRouterProvider] = []
    @State private var search = ""
    @State private var loadingModels = false
    @State private var loadingProviders = false
    @State private var modelError: String?
    @State private var providerError: String?
    @State private var saveError: String?

    init(check: RepositoryCheck, openProviderSettings: @escaping () -> Void) {
        self.check = check; self.openProviderSettings = openProviderSettings
        _configuration = State(initialValue: ModelCheckSettings.shared.configuration(for: check.id))
    }
    private var matchingModels: [OpenRouterModel] {
        models.filter { search.isEmpty || ($0.name + " " + $0.id).localizedStandardContains(search) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(check.title).font(.system(size: 22, weight: .semibold))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Close check configuration")
            }
            Text("Choose how this check reviews rules that need a model’s judgment.")
                .foregroundStyle(Theme.secondary)
            Form {
                Picker("Model family", selection: $configuration.service) {
                    Text("Codex (default)").tag(ModelCheckConfiguration.Service.codex)
                    Text("OpenRouter via AgentBridge").tag(ModelCheckConfiguration.Service.openRouter)
                }
                .accessibilityIdentifier("settings.model.service")
                if configuration.service == .codex {
                    LabeledContent("Account") { Text("AgentBridge Codex login") }
                    LabeledContent("Model") { Text("GPT-6.1 Sol") }
                    LabeledContent("Reasoning") { Text("Low") }
                } else {
                    LabeledContent("Gateway token") {
                        HStack {
                            Text(store.hasAgentBridgeToken ? "Saved in Keychain" : "Optional")
                            Button("Provider settings…", action: openProviderSettings)
                                .accessibilityIdentifier("settings.model.providerSettings")
                        }
                    }
                    TextField("Find model", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("settings.model.search")
                    Picker("Model", selection: $configuration.modelID) {
                        if !matchingModels.contains(where: { $0.id == configuration.modelID }) {
                            Text(configuration.modelID).tag(configuration.modelID)
                        }
                        ForEach(matchingModels) { model in Text(model.name).tag(model.id) }
                    }
                    .accessibilityIdentifier("settings.model.selection")
                    Picker("Model provider", selection: $configuration.providerID) {
                        Text("OpenRouter routing").tag("")
                        if !configuration.providerID.isEmpty && !providers.contains(where: { $0.id == configuration.providerID }) {
                            Text(configuration.providerID == "wafer" ? "Wafer" : configuration.providerID).tag(configuration.providerID)
                        }
                        ForEach(providers) { provider in Text(provider.name + " (" + provider.id + ")").tag(provider.id) }
                    }
                    .disabled(loadingProviders)
                    .accessibilityIdentifier("settings.model.endpoint")
                    Picker("Reasoning", selection: $configuration.reasoning) {
                        Text("Model default").tag(ModelCheckConfiguration.Reasoning.automatic)
                        Text("Off").tag(ModelCheckConfiguration.Reasoning.disabled)
                        Text("Minimal").tag(ModelCheckConfiguration.Reasoning.minimal)
                        Text("Low").tag(ModelCheckConfiguration.Reasoning.low)
                    }
                    .accessibilityIdentifier("settings.model.reasoning")
                }
            }
            .formStyle(.grouped)
            Text(configuration.service == .codex
                 ? "Reviews use AgentBridge’s Codex login. Only supplied README evidence is reviewed."
                 : configuration.providerID.isEmpty
                 ? "OpenRouter chooses a compatible provider. Reviews may use different providers."
                 : "Reviews use this provider only. If it is unavailable, the check stays incomplete.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if loadingModels || loadingProviders {
                HStack { ProgressView().controlSize(.small); Text("Loading OpenRouter catalog…") }
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            if let error = saveError ?? providerError ?? modelError {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Restore defaults") { configuration = .init(); search = "" }
                    .accessibilityIdentifier("settings.model.defaults")
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do { try store.saveModelCheckConfiguration(configuration, for: check.id); dismiss() }
                    catch { saveError = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(loadingProviders)
                .accessibilityIdentifier("settings.model.save")
            }
        }
        .padding(24).frame(width: 600)
        .foregroundStyle(Theme.primary).background(Theme.background).preferredColorScheme(.dark)
        .onChange(of: configuration.service) { _, service in
            configuration = .init(service: service)
            search = ""; saveError = nil; modelError = nil; providerError = nil
        }
        .task(id: configuration.service) {
            models = []; modelError = nil; loadingModels = false
            guard configuration.service == .openRouter else { return }
            store.refreshAgentBridgeStatus()
            loadingModels = true
            defer { loadingModels = false }
            do {
                let available = try await AgentBridgeClient().models()
                try Task.checkCancellation()
                models = available
            }
            catch { if !Task.isCancelled { modelError = "Catalog unavailable. Your saved model is retained. " + error.localizedDescription } }
        }
        .onChange(of: configuration.modelID) { _, model in
            guard configuration.service == .openRouter else { return }
            configuration.providerID = model == ModelCheckConfiguration(service: .openRouter).modelID ? "wafer" : ""
            configuration.reasoning = model == ModelCheckConfiguration(service: .openRouter).modelID ? .disabled : .automatic
            saveError = nil
        }
        .task(id: configuration.service.rawValue + configuration.modelID) {
            providers = []; providerError = nil; loadingProviders = false
            guard configuration.service == .openRouter else { return }
            let model = configuration.modelID
            loadingProviders = true; providers = []; providerError = nil
            defer { if model == configuration.modelID { loadingProviders = false } }
            do {
                let available = try await AgentBridgeClient().providers(for: model)
                try Task.checkCancellation()
                providers = available
            } catch {
                if !Task.isCancelled { providerError = "Providers unavailable. Your saved selection is retained. " + error.localizedDescription }
            }
        }
    }
}
