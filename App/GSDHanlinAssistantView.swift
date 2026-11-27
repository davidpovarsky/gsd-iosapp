import SwiftUI
import Charts
import enum GSDModel.Quadrant
import GSDStore
import GSDHanlinAgent

/// In-app Hanlin assistant for tasks. The model endpoint and model are user-configured.
/// API tokens stay in the device Keychain (not UserDefaults, project files or conversation logs).
struct GSDHanlinAssistantView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var cloudSession
    @State private var chatGPT = GSDChatGPTAccountState.shared
    @State private var showChatGPTSettings = false
    @State private var isPreparingRequest = false
    @State private var sendTask: _Concurrency.Task<Void, Never>?
    @State private var requestID: UUID?
    @State private var assistant: GSDHanlinAssistantState
    @State private var loadedScope: GSDHanlinConversationScope?
    @State private var restorationFailed = false
    private let taskStore: TaskStore
    let remoteBridge: GSDRemoteBridgeState?
    @State private var showRemoteBridgeSettings = false
    @State private var prompt = ""
    @FocusState private var promptFocused: Bool
    @State private var chartBreakdown = "quadrant"
    @State private var expandedWorkspace: GSDWorkspaceSheet?
    @State private var showModelSettings = false
    @State private var apiToken = ""
    @State private var providerCredential: GSDHanlinProviderCredential?
    @State private var providerCredentialLoaded = false
    @State private var draftProvider = "OpenRouter"
    @State private var draftModelID = ""
    @State private var draftEndpoint = ""
    @State private var followsConversation = true
    @State private var conversationNearBottom = true
    @State private var userScrollingConversation = false
    @State private var configurationError: String?
    @AppStorage("gsd.hanlin.provider") private var provider = "OpenRouter"
    @AppStorage("gsd.hanlin.model") private var modelID = ""
    @AppStorage("gsd.hanlin.endpoint") private var endpoint = "https://openrouter.ai/api/v1"

    init(store: TaskStore, remoteBridge: GSDRemoteBridgeState?) {
        taskStore = store
        self.remoteBridge = remoteBridge
        _assistant = State(initialValue: GSDHanlinAssistantState(store: store))
    }

    private var configuredToken: String { providerCredential?.credential ?? "" }

    private var isNativeProviderFixture: Bool {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("--demo-seed") &&
            ProcessInfo.processInfo.arguments.contains("--gsd-native-hanlin-fixture")
        #else
        false
        #endif
    }

    private var conversationScope: GSDHanlinConversationScope {
        if isNativeProviderFixture {
            return .init(gsdAccountID: "native-fixture", provider: "OpenAI",
                         providerAccountID: "gsd-native-fixture")
        }
        return .init(
            gsdAccountID: cloudSession.currentUserID, provider: provider,
            providerAccountID: provider == "ChatGPT"
                ? (chatGPT.canUsePlan ? chatGPT.activeID : nil)
                : providerCredential?.conversationAccountID(endpoint: endpoint))
    }

    var body: some View {
        let isCurrentConversation = loadedScope == conversationScope
        let visibleMessages = isCurrentConversation ? assistant.messages : []
        let approvalOwner = assistant
        let approvalID = isCurrentConversation ? approvalOwner.pendingApprovalID : nil
        let approvalRequest = approvalOwner.pendingApproval
        NavigationStack {
            VStack(spacing: 0) {
                if visibleMessages.isEmpty {
                    ContentUnavailableView {
                        Label("Task AI assistant", systemImage: "sparkles")
                    } description: {
                        Text("Ask for task summaries, planning, priority changes, or a dashboard. Writes require your approval.")
                    }
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(visibleMessages) { entry in
                                HStack {
                                    if entry.role == .user { Spacer(minLength: 36) }
                                    Text(AssistantCopy.message(entry))
                                        .font(entry.role == .status ? .caption : .body)
                                        .foregroundStyle(entry.role == .status ? .secondary : .primary)
                                        .padding(11)
                                        .background(
                                            entry.role == .user ? Color.accentColor.opacity(0.12) :
                                            Color.secondary.opacity(0.08),
                                            in: RoundedRectangle(cornerRadius: 15))
                                    if entry.role != .user { Spacer(minLength: 36) }
                                }
                                .id(entry.id)
                            }
                            if isCurrentConversation, let dashboard = assistant.dashboard {
                                visualDashboard(dashboard)
                            }
                            if isCurrentConversation, let request = assistant.workspace {
                                VStack(alignment: .leading, spacing: 8) {
                                    GSDTaskWorkspaceView(store: taskStore, request: request)
                                        .id(request)
                                        .frame(height: 580)
                                        .clipShape(RoundedRectangle(cornerRadius: 16))
                                    Button("Expand task workspace", systemImage: "arrow.up.left.and.arrow.down.right") {
                                        expandedWorkspace = .init(request: request)
                                    }
                                    .accessibilityIdentifier("gsd.assistant.expand-workspace")
                                }
                            }
                            if assistant.isRunning {
                                ProgressView("Working…")
                                    .font(.caption)
                                    .id("progress")
                            }
                        }.padding(15)
                    }
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        let visibleBottom = geometry.contentOffset.y + geometry.containerSize.height
                        return visibleBottom >= geometry.contentSize.height + geometry.contentInsets.bottom - 80
                    } action: { _, nearBottom in
                        conversationNearBottom = nearBottom
                        if userScrollingConversation { followsConversation = nearBottom }
                    }
                    .onScrollPhaseChange { _, phase in
                        let wasUserScrolling = userScrollingConversation
                        userScrollingConversation = phase == .tracking || phase == .interacting ||
                            phase == .decelerating
                        if wasUserScrolling, phase == .idle {
                            followsConversation = conversationNearBottom
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("gsd.assistant.conversation")
                    .onChange(of: loadedScope) { _, _ in
                        if isCurrentConversation, let last = assistant.messages.last?.id {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                    .onChange(of: assistant.transcriptRevision) { _, _ in
                        if isCurrentConversation, followsConversation, !userScrollingConversation,
                           let last = assistant.messages.last?.id {
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
                        }
                    }
                }
                if isCurrentConversation, let failure = assistant.failure {
                    Text(GSDChatGPTCopy.error(failure)).font(.caption).foregroundStyle(.red).padding(.horizontal)
                } else if isCurrentConversation, let error = assistant.errorMessage {
                    Text(AssistantCopy.status(error)).font(.caption).foregroundStyle(.red).padding(.horizontal)
                }
                if let configurationError {
                    Text(configurationError).font(.caption).foregroundStyle(.red).padding(.horizontal)
                }
                if restorationFailed, !isPreparingRequest {
                    Button("Retry") { Task { await resetAssistantConversation() } }
                }
                if provider == "ChatGPT", chatGPT.canUsePlan {
                    HStack {
                        Text("Using ChatGPT plan")
                        Spacer()
                        Link("Manage usage", destination: URL(string: "https://chatgpt.com/settings/usage")!)
                    }.font(.caption).padding(.horizontal)
                }
                HStack(spacing: 10) {
                    TextField("Ask about your tasks…", text: $prompt, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.send)
                        .onSubmit(send)
                        .focused($promptFocused)
                        .accessibilityIdentifier("gsd.assistant.prompt")
                    if assistant.isRunning ||
                        (isPreparingRequest && isCurrentConversation && assistant.isConversationReady) {
                        Button {
                            guard assistant.isRunning ||
                                (isPreparingRequest && loadedScope == conversationScope &&
                                 assistant.isConversationReady) else { return }
                            cancelAssistantRequest()
                        } label: { Image(systemName: "stop.circle") }
                            .accessibilityLabel("Stop AI")
                    } else {
                        Button(action: send) {
                            Image(systemName: "arrow.up.circle.fill").font(.title2)
                        }
                        .disabled(!isCurrentConversation || !assistant.isConversationReady ||
                                  prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("Send to AI")
                        .accessibilityIdentifier("gsd.assistant.send")
                    }
                }
                .padding()
                .background(.regularMaterial)
            }
            .navigationTitle("Hanlin AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Task workspace", systemImage: "point.3.connected.trianglepath.dotted") {
                        expandedWorkspace = .init()
                    }
                    .accessibilityIdentifier("gsd.assistant.workspace")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("MCP", systemImage: "network") { showRemoteBridgeSettings = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Model", systemImage: "gearshape") { openModelSettings() }
                }
            }
            .onAppear {
                loadProviderCredential()
                if provider == "ChatGPT" ? !chatGPT.canUsePlan : modelID.isEmpty {
                    openModelSettings()
                }
            }
            .onChange(of: provider) { _, selected in
                if selected != "ChatGPT" {
                    cancelAssistantRequest()
                    loadProviderCredential()
                }
            }
            .task(id: conversationScope) {
                await resetAssistantConversation()
            }
            .onDisappear {
                cancelAssistantRequest()
                chatGPT.cancelSignIn()
            }
            .onChange(of: cloudSession.currentUserID) { _, _ in
                cancelAssistantRequest()
                dismiss()
            }
            .fullScreenCover(item: $expandedWorkspace) { sheet in
                GSDTaskWorkspaceSheet(store: taskStore, request: sheet.request)
            }
            .sheet(isPresented: $showModelSettings) { settings }
            .sheet(isPresented: $showRemoteBridgeSettings) {
                GSDCloudConnectionView().environment(cloudSession)
            }
            .confirmationDialog(
                "Allow the AI to modify your tasks?",
                isPresented: Binding(
                    get: {
                        !showModelSettings && !showRemoteBridgeSettings && approvalID != nil &&
                            approvalOwner.pendingApprovalID == approvalID
                    },
                    set: { presented in
                        if !presented, !showModelSettings, !showRemoteBridgeSettings, let approvalID {
                            // A delayed dismissal may only resolve the approval this dialog showed.
                            _Concurrency.Task { @MainActor [approvalOwner, approvalID] in
                                approvalOwner.resolveApproval(false, approvalID: approvalID)
                            }
                        }
                    }),
                titleVisibility: .visible
            ) {
                if let approvalID {
                    Button("Allow change") {
                        approvalOwner.resolveApproval(true, approvalID: approvalID)
                    }
                    .accessibilityIdentifier("gsd.assistant.allow-change")
                    Button("Deny", role: .cancel) {
                        approvalOwner.resolveApproval(false, approvalID: approvalID)
                    }
                }
            } message: {
                Text(approvalRequest.map { AssistantCopy.approval($0.description) } ?? String(localized: "The requested change needs approval."))
            }
            .gsdRemoteWriteApproval(bridge: remoteBridge, isActive: {
                !showModelSettings && !showRemoteBridgeSettings && assistant.pendingApproval == nil
            })
        }
    }

    @ViewBuilder
    private func visualDashboard(_ summary: GSDHanlinDashboard) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GSD task dashboard").font(.headline)
            HStack {
                Label("\(summary.open) open", systemImage: "circle.dotted")
                Spacer()
                Label("\(summary.completed) done", systemImage: "checkmark.circle")
            }.font(.caption)
            Picker("Chart breakdown", selection: $chartBreakdown) {
                Text("Priority matrix").tag("quadrant")
                Text("Status").tag("status")
            }
            .pickerStyle(.segmented)
            Chart(summary.buckets(mode: chartBreakdown)) { bucket in
                BarMark(x: .value(String(localized: "Group"), AssistantCopy.bucket(bucket.name)),
                        y: .value(String(localized: "Tasks"), bucket.value))
                    .foregroundStyle(by: .value(String(localized: "Group"), AssistantCopy.bucket(bucket.name)))
            }
            .chartLegend(.hidden)
            .frame(height: 180)
            .accessibilityLabel("Interactive task metrics")
            Text("\(summary.overdue) overdue · \(summary.estimatedOpenMinutes) estimated minutes remaining")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var settings: some View {
        NavigationStack {
            Form {
                Section("AI provider") {
                    Picker("Provider", selection: $draftProvider) {
                        Text("ChatGPT plan").tag("ChatGPT")
                        Text("OpenRouter").tag("OpenRouter")
                        Text("OpenAI").tag("OpenAI")
                        Text("Anthropic").tag("Anthropic")
                        Text("Google").tag("Google")
                        Text("Other compatible").tag("Other")
                    }
                    if draftProvider == "ChatGPT" {
                        Button("Continue with ChatGPT") { showChatGPTSettings = true }
                            .accessibilityIdentifier("hanlin.chatgpt.settings")
                        Text(chatGPT.status).font(.caption).foregroundStyle(.secondary)
                        if !chatGPT.selectedModelID.isEmpty {
                            LabeledContent("Model", value: chatGPT.selectedModelID)
                        }
                    } else {
                        TextField("Model identifier", text: $draftModelID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("HTTPS API base URL", text: $draftEndpoint)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        SecureField("API key", text: $apiToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Text("The API key is saved only in your device Keychain. An API provider may charge for usage. This is not ChatGPT account sign-in.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let configurationError {
                    Text(configurationError).foregroundStyle(.red)
                }
                if draftProvider != "ChatGPT", !providerCredentialLoaded {
                    if configurationError == nil {
                        Text("The device Keychain is unavailable. Unlock the device and reopen this screen.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Retry") { loadProviderCredential() }
                        .accessibilityIdentifier("gsd.assistant.retry-provider-credential")
                }
            }
            .navigationTitle("Hanlin model settings")
            .sheet(isPresented: $showChatGPTSettings) {
                GSDChatGPTSettingsView(account: chatGPT) {
                    await cancelAssistantRequest().value
                    await resetAssistantConversation()
                }
            }
            .gsdRemoteWriteApproval(bridge: remoteBridge)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        apiToken = configuredToken
                        showModelSettings = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if draftProvider == "ChatGPT" {
                            guard chatGPT.canUsePlan else {
                                configurationError = String(localized: "Connect ChatGPT and enable plan usage first.")
                                return
                            }
                            configurationError = nil
                            cancelAssistantRequest()
                            commitModelSettings()
                            showModelSettings = false
                            return
                        }
                        guard let url = URL(string: draftEndpoint), url.scheme == "https", url.host != nil,
                              !draftModelID.isEmpty else {
                            configurationError = String(localized: "Enter an HTTPS endpoint and a model identifier.")
                            return
                        }
                        cancelAssistantRequest()
                        do {
                            let saved = try GSDHanlinProviderKeychain.store.save(apiToken)
                            providerCredential = saved
                            providerCredentialLoaded = true
                            apiToken = saved?.credential ?? ""
                            configurationError = nil
                            commitModelSettings()
                            showModelSettings = false
                        } catch {
                            configurationError = String(localized: "Keychain could not securely store this credential.")
                        }
                    }
                    .disabled(draftProvider != "ChatGPT" && !providerCredentialLoaded && apiToken.isEmpty)
                }
            }
        }
    }

    @MainActor
    private func openModelSettings() {
        loadProviderCredential()
        draftProvider = provider
        draftModelID = modelID
        draftEndpoint = endpoint
        apiToken = configuredToken
        showModelSettings = true
    }

    @MainActor
    private func commitModelSettings() {
        provider = draftProvider
        modelID = draftModelID
        endpoint = draftEndpoint
    }

    @MainActor
    private func loadProviderCredential() {
        guard !isNativeProviderFixture else {
            providerCredentialLoaded = true
            return
        }
        do {
            providerCredential = try GSDHanlinProviderKeychain.store.read()
            providerCredentialLoaded = true
            apiToken = configuredToken
        } catch {
            providerCredentialLoaded = false
            providerCredential = nil
            apiToken = ""
            if provider != "ChatGPT" {
                configurationError = String(localized: "The device Keychain is unavailable. Unlock the device and reopen this screen.")
            }
        }
    }

    @MainActor
    @discardableResult
    private func cancelAssistantRequest() -> _Concurrency.Task<Void, Never> {
        // Revoke credential preparation before a delayed lookup can start an old request.
        requestID = nil
        sendTask?.cancel()
        sendTask = nil
        isPreparingRequest = false
        return assistant.cancelCurrentRequest()
    }

    @MainActor
    private func resetAssistantConversation() async {
        let scope = conversationScope
        if loadedScope == scope, assistant.isConversationReady { return }
        let previous = assistant
        let cancellation = cancelAssistantRequest()
        let resetID = UUID()
        requestID = resetID
        isPreparingRequest = true
        loadedScope = nil
        restorationFailed = false
        followsConversation = true
        conversationNearBottom = true
        userScrollingConversation = false
        prompt = ""
        expandedWorkspace = nil
        configurationError = nil
        defer {
            if requestID == resetID {
                requestID = nil
                isPreparingRequest = false
            }
        }
        await cancellation.value
        guard requestID == resetID, assistant === previous,
              conversationScope == scope, !Task.isCancelled else { return }
        do {
            let restored = try GSDHanlinAssistantState(store: taskStore, scope: scope)
            assistant = restored
            await restored.restoreConversation()
            guard requestID == resetID, assistant === restored,
                  conversationScope == scope, !Task.isCancelled else { return }
            loadedScope = scope
            restorationFailed = !restored.isConversationReady
        } catch {
            guard requestID == resetID, conversationScope == scope else { return }
            restorationFailed = true
            configurationError = String(localized: "The saved conversation could not be read. Its existing data has been preserved.")
        }
    }

    private func send() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = conversationScope
        guard !text.isEmpty, !assistant.isRunning, !isPreparingRequest,
              loadedScope == scope, assistant.isConversationReady else { return }
        let id = UUID()
        requestID = id
        isPreparingRequest = true
        followsConversation = true
        userScrollingConversation = false
        configurationError = nil
        prompt = ""
        promptFocused = false
        let sendingAssistant = assistant
        let nativeFixture = isNativeProviderFixture
        // The explicit simulator fixture never reads a real provider credential
        // into its request and never changes Keychain or saved model settings.
        let selectedProvider = nativeFixture ? "OpenAI" : provider
        let selectedModel = nativeFixture ? "gsd-native-fixture" : modelID
        let selectedEndpoint = nativeFixture ? "https://gsd-workspace-acceptance.invalid/v1" : endpoint
        let selectedCredential = nativeFixture ? "gsd-native-fixture" : configuredToken
        sendTask = Task { @MainActor in
            defer {
                if requestID == id { isPreparingRequest = false; sendTask = nil; requestID = nil }
            }
            do {
                if selectedProvider == "ChatGPT" {
                    let access = try await chatGPT.accessForInference()
                    try Task.checkCancellation()
                    guard requestID == id, assistant === sendingAssistant,
                          loadedScope == scope, conversationScope == scope else { return }
                    await sendingAssistant.send(text, modelID: access.modelID,
                        endpoint: "https://api.openai.com/v1/responses",
                        credential: access.token, provider: "ChatGPT")
                } else {
                    try Task.checkCancellation()
                    guard requestID == id, assistant === sendingAssistant,
                          loadedScope == scope, conversationScope == scope else { return }
                    await sendingAssistant.send(text, modelID: selectedModel, endpoint: selectedEndpoint,
                                                credential: selectedCredential, provider: selectedProvider)
                }
            } catch is CancellationError {
                if requestID == id, prompt.isEmpty { prompt = text }
            } catch {
                guard requestID == id, assistant === sendingAssistant,
                          loadedScope == scope, conversationScope == scope else { return }
                configurationError = String(format: String(localized: "ChatGPT access failed: %@"), GSDChatGPTCopy.error(error))
                if prompt.isEmpty { prompt = text }
            }
        }
    }
}

// Each presentation hosts its own dialog; only the foreground surface is active.
private struct GSDRemoteWriteApprovalModifier: ViewModifier {
    let bridge: GSDRemoteBridgeState?
    let isActive: @MainActor () -> Bool

    func body(content: Content) -> some View {
        let owner = bridge
        let approvalID = owner?.pendingApprovalID
        let request = owner?.pendingApproval
        content.confirmationDialog(
            "Allow this change from ChatGPT?",
            isPresented: Binding(
                get: { isActive() && approvalID != nil && owner?.pendingApprovalID == approvalID },
                set: { presented in
                    if !presented, isActive(), let owner, let approvalID {
                        _Concurrency.Task { @MainActor [owner, approvalID] in
                            owner.resolveApproval(false, approvalID: approvalID)
                        }
                    }
                }),
            titleVisibility: .visible
        ) {
            if let owner, let approvalID {
                Button("Allow change") { owner.resolveApproval(true, approvalID: approvalID) }
                Button("Deny", role: .cancel) { owner.resolveApproval(false, approvalID: approvalID) }
            }
        } message: {
            Text(request.map { AssistantCopy.approval($0.description) } ??
                 String(localized: "ChatGPT requests permission to modify GSD tasks."))
        }
    }
}

extension View {
    @MainActor
    func gsdRemoteWriteApproval(
        bridge: GSDRemoteBridgeState?,
        isActive: @escaping @MainActor () -> Bool = { true }
    ) -> some View {
        modifier(GSDRemoteWriteApprovalModifier(bridge: bridge, isActive: isActive))
    }
}

/// Only framework-generated labels enter these lookups. Task titles and chat content stay verbatim.
private enum AssistantCopy {
    private static func localized(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }

    static func toolName(_ alias: String) -> String {
        guard let spec = GSDHanlinToolCatalog.specs.first(where: { $0.alias == alias }) else { return alias }
        return localized(spec.title)
    }

    static func message(_ entry: GSDHanlinMessage) -> String {
        switch entry.role {
        case .status: return status(entry.text)
        case .assistant where entry.text == "No reply text. Review the tool activity or try again.":
            return String(localized: "No reply text. Review the tool activity or try again.")
        case .assistant where entry.text == "The AI request failed.":
            return String(localized: "The AI request failed.")
        default: return entry.text
        }
    }

    static func bucket(_ name: String) -> String {
        Quadrant(rawValue: name)?.title ?? localized(name)
    }

    static func approval(_ description: String) -> String {
        guard let separator = description.range(of: ": ") else { return localized(description) }
        let action = localized(String(description[..<separator.lowerBound]))
        let selection = String(description[separator.upperBound...])
        return String(localized: "\(action): \(selection)")
    }

    static func status(_ message: String) -> String {
        if let separator = message.range(of: ": ") {
            let prefix = message[..<separator.lowerBound]
            let detail = String(message[separator.upperBound...])
            switch prefix {
            case "Tool failed": return String(localized: "Tool failed: \(toolName(detail))")
            case "Tool completed": return String(localized: "Tool completed: \(toolName(detail))")
            case "Reviewing tool": return String(localized: "Reviewing tool: \(toolName(detail))")
            case "Bridge temporarily unavailable":
                return String(localized: "Bridge temporarily unavailable: \(localized(detail))")
            default: break
            }
        }
        let pairingPrompt = "Enter this code in ChatGPT connection (expires in "
        if message.hasPrefix(pairingPrompt), message.hasSuffix(" minutes)"),
           let minutes = Int(message.dropFirst(pairingPrompt.count).dropLast(" minutes)".count)) {
            return String(localized: "Enter this code in ChatGPT. It expires in \(minutes) minutes.")
        }
        if message.hasPrefix("Bridge HTTP "), let code = Int(message.dropFirst(12).prefix(while: \.isNumber)) {
            return code == 401
                ? String(localized: "Bridge error \(code). Pair the iPad again.")
                : String(localized: "Bridge error \(code).")
        }
        return localized(message)
    }
}
