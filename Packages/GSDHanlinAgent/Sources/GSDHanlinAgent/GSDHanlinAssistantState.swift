import Foundation
import Observation
import GSDStore
import HanlinAgentCore
import HanlinChatCore
import HanlinHostContracts

public struct GSDHanlinMessage: Identifiable, Sendable {
    public enum Role: String, Sendable { case user, assistant, status }
    public let id: UUID
    public let role: Role
    public var text: String
    public init(id: UUID = UUID(), role: Role, text: String) {
        self.id = id; self.role = role; self.text = text
    }
}

/// Typed chart data from GSD's canonical get_dashboard tool.
public struct GSDHanlinDashboard: Decodable, Sendable {
    public struct Bucket: Identifiable, Sendable {
        public let name: String
        public let value: Int
        public var id: String { name }
        public init(name: String, value: Int) { self.name = name; self.value = value }
    }
    public let total: Int
    public let open: Int
    public let completed: Int
    public let overdue: Int
    public let saved: Int
    public let estimatedOpenMinutes: Int
    public let byQuadrant: [String: Int]

    public func buckets(mode: String) -> [Bucket] {
        if mode == "status" {
            return [
                .init(name: "Open", value: open),
                .init(name: "Completed", value: completed),
                .init(name: "Saved", value: saved)
            ]
        }
        return byQuadrant.map { .init(name: $0.key, value: $0.value) }
            .sorted { $0.name < $1.name }
    }
}

/// Native UI state backed by the ACTUAL HanlinAgentSession streaming agent.
/// The GSD UI must present and resolve pending write approvals; the default is deny.
@MainActor @Observable
public final class GSDHanlinAssistantState {
    public private(set) var messages: [GSDHanlinMessage] = []
    public private(set) var isRunning = false
    public private(set) var errorMessage: String?
    public private(set) var pendingApproval: GSDHanlinWriteRequest?
    public private(set) var dashboard: GSDHanlinDashboard?

    @ObservationIgnored private let store: TaskStore
    @ObservationIgnored private var bundle: GSDHanlinAgentBundle?
    @ObservationIgnored private var currentModelKey: String?
    @ObservationIgnored private var approvalContinuation: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private let conversationID: UUID

    public init(store: TaskStore, conversationID: UUID = UUID()) {
        self.store = store
        self.conversationID = conversationID
    }

    public func resolveApproval(_ allowed: Bool) {
        let continuation = approvalContinuation
        approvalContinuation = nil
        pendingApproval = nil
        continuation?.resume(returning: allowed)
    }

    private func authorize(_ request: GSDHanlinWriteRequest) async -> Bool {
        guard pendingApproval == nil, approvalContinuation == nil, !_Concurrency.Task<Never, Never>.isCancelled else { return false }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            pendingApproval = request
            approvalContinuation = continuation
        }
    }

    public func cancel() async {
        resolveApproval(false)
        if let bundle { await bundle.agent.invalidate() }
        bundle = nil
        currentModelKey = nil
        isRunning = false
    }

    /// Credentials belong to the host app's Keychain, never the transcript or the task database.
    public func send(_ prompt: String, modelID: String, endpoint: String,
                     credential: String, provider: String) async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, !trimmed.isEmpty else { return }
        guard !modelID.isEmpty, !credential.isEmpty,
              let endpointURL = URL(string: endpoint), endpointURL.scheme == "https",
              endpointURL.host != nil else {
            errorMessage = "Configure an HTTPS endpoint, model and API key first."
            return
        }

        isRunning = true
        errorMessage = nil
        messages.append(.init(role: .user, text: trimmed))
        let responseID = UUID()
        messages.append(.init(id: responseID, role: .assistant, text: ""))
        defer { isRunning = false }

        do {
            // Do not retain a raw API key in a string fingerprint.
            let fingerprint = "\(provider)|\(endpoint)|\(modelID)"
            if bundle == nil || fingerprint != currentModelKey {
                if let old = bundle { await old.agent.invalidate() }
                let configuration = HanlinChatModelConfiguration(
                    modelID: modelID, company: provider,
                    apiType: provider == "Anthropic" ? "Anthropic" :
                             provider == "Google" ? "Gemini" : "OpenAI",
                    endpoint: endpointURL, apiKey: credential, maxTokens: 2048,
                    supportsToolUse: true)
                let applicationSupport = FileManager.default.urls(
                    for: .applicationSupportDirectory, in: .userDomainMask)[0]
                let directory = applicationSupport.appending(
                    path: "GSDHanlinConversations", directoryHint: .isDirectory)
                bundle = try GSDHanlinAgentFactory.make(
                    store: store, configuration: configuration, accountID: "device-local",
                    conversationDirectory: directory, conversationID: conversationID,
                    writeAuthorizer: { [weak self] request in
                        guard let self else { return false }
                        return await self.authorize(request)
                    })
                currentModelKey = fingerprint
            }

            guard let bundle else { throw HanlinHostError.invalidContext }
            let transcript: [HanlinAISDKMessage] = messages
                .filter { $0.role != .status && $0.id != responseID }
                .map {
                    HanlinAISDKMessage(
                        role: $0.role == .user ? .user : .assistant,
                        text: $0.text)
                }
            let events = try await bundle.agent.stream(
                messages: transcript,
                systemPrompt: "You are a GSD task manager assistant. Use only advertised GSD tools. "
                    + "Request user approval for changes and never claim a modification before host confirmation.",
                modelReference: .init(provider: provider, modelID: modelID),
                maxSteps: 8)
            for try await item in events {
                switch item.event {
                case .textDelta(let delta):
                    if let index = messages.firstIndex(where: { $0.id == responseID }) {
                        messages[index].text += delta
                    }
                case .toolResult(_, let name, let jsonText, _, let failed):
                    if !failed, name == "get_dashboard",
                       let data = jsonText.data(using: .utf8),
                       let decoded = try? JSONDecoder().decode(GSDHanlinDashboard.self, from: data) {
                        dashboard = decoded
                    }
                    messages.append(.init(role: .status,
                        text: (failed ? "Tool failed: " : "Tool completed: ") + name))
                case .toolApprovalRequest(let request):
                    messages.append(.init(role: .status,
                        text: "Reviewing tool: " + request.toolName))
                default: break
                }
            }
            if let index = messages.firstIndex(where: { $0.id == responseID }),
               messages[index].text.isEmpty {
                messages[index].text = "No reply text. Review the tool activity or try again."
            }
        } catch {
            errorMessage = error.localizedDescription
            if let index = messages.firstIndex(where: { $0.id == responseID }),
               messages[index].text.isEmpty {
                messages[index].text = "The AI request failed."
            }
        }
    }
}
