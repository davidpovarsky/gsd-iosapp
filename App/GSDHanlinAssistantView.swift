import Security
import SwiftUI
import Charts
import GSDStore
import GSDHanlinAgent

/// In-app Hanlin assistant for tasks. The model endpoint and model are user-configured.
/// API tokens stay in the device Keychain (not UserDefaults, project files or conversation logs).
struct GSDHanlinAssistantView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var assistant: GSDHanlinAssistantState
    let remoteBridge: GSDRemoteBridgeState?
    @State private var showRemoteBridgeSettings = false
    @State private var prompt = ""
    @State private var chartBreakdown = "quadrant"
    @State private var showModelSettings = false
    @State private var apiToken = ""
    @State private var configuredToken = ""
    @State private var configurationError: String?
    @AppStorage("gsd.hanlin.provider") private var provider = "OpenRouter"
    @AppStorage("gsd.hanlin.model") private var modelID = ""
    @AppStorage("gsd.hanlin.endpoint") private var endpoint = "https://openrouter.ai/api/v1"

    init(store: TaskStore, remoteBridge: GSDRemoteBridgeState?) {
        self.remoteBridge = remoteBridge
        _assistant = State(initialValue: GSDHanlinAssistantState(store: store))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if assistant.messages.isEmpty {
                    ContentUnavailableView {
                        Label("Task AI assistant", systemImage: "sparkles")
                    } description: {
                        Text("Ask for task summaries, planning, priority changes, or a dashboard. Writes require your approval.")
                    }
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(assistant.messages) { entry in
                                HStack {
                                    if entry.role == .user { Spacer(minLength: 36) }
                                    Text(entry.text)
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
                            if let dashboard = assistant.dashboard {
                                visualDashboard(dashboard)
                            }
                            if assistant.isRunning {
                                ProgressView("Working…")
                                    .font(.caption)
                                    .id("progress")
                            }
                        }.padding(15)
                    }
                    .onChange(of: assistant.messages.count) { _, _ in
                        if let last = assistant.messages.last?.id {
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
                        }
                    }
                }
                if let error = assistant.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal)
                }
                HStack(spacing: 10) {
                    TextField("Ask about your tasks…", text: $prompt, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.send)
                        .onSubmit(send)
                    if assistant.isRunning {
                        Button {
                            Task { await assistant.cancel() }
                        } label: { Image(systemName: "stop.circle") }
                            .accessibilityLabel("Stop AI")
                    } else {
                        Button(action: send) {
                            Image(systemName: "arrow.up.circle.fill").font(.title2)
                        }
                        .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("Send to AI")
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
                    Button("MCP", systemImage: "network") { showRemoteBridgeSettings = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Model", systemImage: "gearshape") { showModelSettings = true }
                }
            }
            .onAppear {
                apiToken = GSDHanlinKeychain.read()
                configuredToken = apiToken
                if modelID.isEmpty { showModelSettings = true }
            }
            .onDisappear {
                Task { await assistant.cancel() }
            }
            .sheet(isPresented: $showModelSettings) { settings }
            .sheet(isPresented: $showRemoteBridgeSettings) {
                if let remoteBridge {
                    GSDRemoteBridgeSettingsView(bridge: remoteBridge)
                } else {
                    ContentUnavailableView("MCP not ready", systemImage: "network.slash")
                }
            }
            .confirmationDialog(
                "Allow the AI to modify your tasks?",
                isPresented: Binding(
                    get: {
                        !showModelSettings && !showRemoteBridgeSettings && assistant.pendingApproval != nil
                    },
                    set: { presented in
                        if !presented {
                            // Let a button claim the approval before handling an outside-tap dismissal.
                            _Concurrency.Task { @MainActor in
                                if !showModelSettings && !showRemoteBridgeSettings &&
                                    assistant.pendingApproval != nil {
                                    assistant.resolveApproval(false)
                                }
                            }
                        }
                    }),
                titleVisibility: .visible
            ) {
                Button("Allow change") { assistant.resolveApproval(true) }
                Button("Deny", role: .cancel) { assistant.resolveApproval(false) }
            } message: {
                Text(assistant.pendingApproval?.description ?? "The requested change needs approval.")
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
                BarMark(x: .value("Group", bucket.name),
                        y: .value("Tasks", bucket.value))
                    .foregroundStyle(by: .value("Group", bucket.name))
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
                    Picker("Provider", selection: $provider) {
                        Text("OpenRouter").tag("OpenRouter")
                        Text("OpenAI").tag("OpenAI")
                        Text("Anthropic").tag("Anthropic")
                        Text("Google").tag("Google")
                        Text("Other compatible").tag("Other")
                    }
                    TextField("Model identifier", text: $modelID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("HTTPS API base URL", text: $endpoint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("API key", text: $apiToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("The API key is saved only in your device Keychain. An API provider may charge for usage. This is not ChatGPT account sign-in.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let configurationError {
                    Text(configurationError).foregroundStyle(.red)
                }
            }
            .navigationTitle("Hanlin model settings")
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
                        guard let url = URL(string: endpoint), url.scheme == "https", url.host != nil,
                              !modelID.isEmpty else {
                            configurationError = "Enter an HTTPS endpoint and a model identifier."
                            return
                        }
                        do {
                            try GSDHanlinKeychain.save(apiToken)
                            configuredToken = apiToken
                            configurationError = nil
                            showModelSettings = false
                            Task { await assistant.cancel() }
                        } catch {
                            configurationError = "Keychain could not securely store this credential."
                        }
                    }
                }
            }
        }
    }

    private func send() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !assistant.isRunning else { return }
        prompt = ""
        Task {
            await assistant.send(text, modelID: modelID, endpoint: endpoint,
                                 credential: configuredToken, provider: provider)
        }
    }
}

private enum GSDHanlinKeychain {
    private static let service = "dev.vinny.gsd.hanlin-agent"
    private static let account = "current-provider-api-key"

    static func read() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let bytes = result as? Data, let text = String(data: bytes, encoding: .utf8)
        else { return "" }
        return text
    }

    static func save(_ value: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let previous = SecItemDelete(query as CFDictionary)
        guard previous == errSecSuccess || previous == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(previous))
        }
        guard !value.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let result = SecItemAdd(item as CFDictionary, nil)
        guard result == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(result))
        }
    }
}

/// User-driven OAuth linking. The iPad generates a private device credential,
/// registers its actual SDK tool catalog, and displays a short-lived one-time
/// code. No server-side copy of GSD's private database is created.
struct GSDRemoteBridgeSettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @Bindable var bridge: GSDRemoteBridgeState

  var body: some View {
    NavigationStack {
      Form {
        Section("Cloudflare / MCP bridge") {
          TextField("HTTPS bridge URL", text: $bridge.endpointText)
            .textContentType(.URL)
            .autocorrectionDisabled()
          Text("The address of your private GSD MCP relay. It must use HTTPS.")
            .font(.caption).foregroundStyle(.secondary)
          HStack {
            Image(systemName: bridge.linked ? "checkmark.shield.fill" : "network")
              .foregroundStyle(bridge.linked ? Color.green : Color.secondary)
            VStack(alignment: .leading) {
              Text(bridge.status)
                .font(.callout)
              if let last = bridge.lastTool {
                Text("Last tool: " + last).font(.caption).foregroundStyle(.secondary)
              }
            }
          }
          Button {
            Task { await bridge.pair() }
          } label: {
            if bridge.isPairing {
              ProgressView("Connectingâ€¦")
            } else {
              Label("Pair this iPad with ChatGPT", systemImage: "link")
            }
          }
          .disabled(bridge.isPairing || bridge.endpointText.isEmpty)
        }

        if let code = bridge.pairingCode {
          Section("One-time pairing code") {
            Text(code)
              .font(.system(.largeTitle, design: .monospaced, weight: .bold))
              .textSelection(.enabled)
              .accessibilityLabel("One-time ChatGPT pairing code: " + code)
            Text("In ChatGPT on the web, connect a custom MCP server at this HTTPS address with OAuth. When ChatGPT opens the GSD sign-in page, enter this code. The code expires after 10 minutes.")
              .font(.callout)
            Text("You do not need to share your GSD database, Apple ID or API keys with the bridge.")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        Section("When can ChatGPT use tools?") {
          Label("Keep GSD open in the foreground while ChatGPT uses the tools.", systemImage: "ipad")
          Label("Task changes require approval on this iPad.", systemImage: "checkmark.shield")
          Label("The server stores only device pairing and temporary requests, not your tasks.", systemImage: "lock.shield")
          if bridge.linked {
            Button("Disconnect ChatGPT and revoke access", role: .destructive) {
              Task { await bridge.disconnect() }
            }
          }
        }
      }
      .navigationTitle("ChatGPT MCP")
      .gsdRemoteWriteApproval(bridge: bridge)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }
}

// Each presentation hosts its own dialog; only the foreground surface is active.
private struct GSDRemoteWriteApprovalModifier: ViewModifier {
    let bridge: GSDRemoteBridgeState?
    let isActive: @MainActor () -> Bool

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Allow this change from ChatGPT?",
            isPresented: Binding(
                get: { isActive() && bridge?.pendingApproval != nil },
                set: { presented in
                    if !presented {
                        // A button action resolves synchronously; defer only no-choice dismissal.
                        _Concurrency.Task { @MainActor in
                            if isActive(), bridge?.pendingApproval != nil {
                                bridge?.resolveApproval(false)
                            }
                        }
                    }
                }),
            titleVisibility: .visible
        ) {
            Button("Allow change") { bridge?.resolveApproval(true) }
            Button("Deny", role: .cancel) { bridge?.resolveApproval(false) }
        } message: {
            Text(bridge?.pendingApproval?.description ??
                 "ChatGPT requests permission to modify GSD tasks.")
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
