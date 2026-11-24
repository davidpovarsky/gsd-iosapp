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
    public private(set) var failure: (any Error)?
    public private(set) var pendingApproval: GSDHanlinWriteRequest?
    public private(set) var pendingApprovalID: UUID?
    public private(set) var dashboard: GSDHanlinDashboard?
    public private(set) var workspace: GSDTaskWorkspaceRequest?

    @ObservationIgnored private let store: TaskStore
    @ObservationIgnored private var bundle: GSDHanlinAgentBundle?
    @ObservationIgnored private var approvalContinuation: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private let conversationID: UUID
    @ObservationIgnored private var activeRequestID: UUID?
    @ObservationIgnored private var bundleFactory: BundleFactory?

    typealias BundleFactory = @MainActor (
        HanlinChatModelConfiguration, @escaping GSDHanlinHost.WriteAuthorizer
    ) throws -> GSDHanlinAgentBundle

    public init(store: TaskStore, conversationID: UUID = UUID()) {
        self.store = store
        self.conversationID = conversationID
    }

    convenience init(store: TaskStore, conversationID: UUID = UUID(),
                     bundleFactory: @escaping BundleFactory) {
        self.init(store: store, conversationID: conversationID)
        self.bundleFactory = bundleFactory
    }

    public func resolveApproval(_ allowed: Bool, approvalID: UUID) {
        guard pendingApprovalID == approvalID else { return }
        finishApproval(allowed)
    }

    private func finishApproval(_ allowed: Bool) {
        let continuation = approvalContinuation
        approvalContinuation = nil
        pendingApproval = nil
        pendingApprovalID = nil
        continuation?.resume(returning: allowed)
    }

    private func authorize(_ request: GSDHanlinWriteRequest, requestID: UUID) async -> Bool {
        guard activeRequestID == requestID, pendingApproval == nil, approvalContinuation == nil,
              !_Concurrency.Task<Never, Never>.isCancelled else { return false }
        let allowed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            pendingApprovalID = UUID()
            pendingApproval = request
            approvalContinuation = continuation
        }
        return allowed && activeRequestID == requestID && !_Concurrency.Task<Never, Never>.isCancelled
    }

    /// Revoke the current turn synchronously; delayed cleanup owns only its detached bundle.
    @discardableResult
    public func cancelCurrentRequest() -> _Concurrency.Task<Void, Never> {
        activeRequestID = nil
        finishApproval(false)
        let previous = bundle
        bundle = nil
        isRunning = false
        return _Concurrency.Task { @MainActor [previous] in
            if let previous { await previous.agent.invalidate() }
        }
    }

    public func cancel() async {
        await cancelCurrentRequest().value
    }

    /// Credentials belong to the host app's Keychain, never the transcript or the task database.
    public func send(_ prompt: String, modelID: String, endpoint: String,
                     credential: String, provider: String) async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, !trimmed.isEmpty else { return }
        guard !modelID.isEmpty, !credential.isEmpty,
              let endpointURL = URL(string: endpoint), endpointURL.scheme == "https",
              endpointURL.host != nil else {
            failure = nil
            errorMessage = "Configure an HTTPS endpoint, model and API key first."
            return
        }

        let requestID = UUID()
        activeRequestID = requestID
        isRunning = true
        errorMessage = nil
        failure = nil
        messages.append(.init(role: .user, text: trimmed))
        let responseID = UUID()
        messages.append(.init(id: responseID, role: .assistant, text: ""))
        defer {
            if activeRequestID == requestID {
                activeRequestID = nil
                isRunning = false
                finishApproval(false)
            }
        }

        do {
            // Every turn owns its host authorizer and agent session. Reusing a
            // closure from a previous turn would retain its revoked request ID.
            if let previous = bundle { await previous.agent.invalidate() }
            guard activeRequestID == requestID else { return }
            try _Concurrency.Task<Never, Never>.checkCancellation()
            let usesChatGPTPlan = provider == "ChatGPT"
            let configuration = HanlinChatModelConfiguration(
                modelID: modelID, company: usesChatGPTPlan ? "OpenAI" : provider,
                apiType: usesChatGPTPlan ? "openai-chatgpt-plan" : provider == "Anthropic" ? "Anthropic" :
                         provider == "Google" ? "Gemini" : "OpenAI",
                endpoint: endpointURL, apiKey: credential, maxTokens: 2048,
                supportsToolUse: true)
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let directory = applicationSupport.appending(
                path: "GSDHanlinConversations", directoryHint: .isDirectory)
            let authorizer: GSDHanlinHost.WriteAuthorizer = { [weak self] request in
                guard let self else { return false }
                return await self.authorize(request, requestID: requestID)
            }
            if let bundleFactory {
                bundle = try bundleFactory(configuration, authorizer)
            } else {
                bundle = try GSDHanlinAgentFactory.make(
                    store: store, configuration: configuration, accountID: "device-local",
                    conversationDirectory: directory, conversationID: conversationID,
                    writeAuthorizer: authorizer)
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
                    + "Request user approval for changes and never claim a modification before host confirmation. "
                    + "For task plans or dependencies, call show_task_workspace to display the real interactive tasks. "
                    + "After creating tasks and their dependency links, show their IDs in the workspace; do not invent task IDs.",
                modelReference: .init(provider: provider, modelID: modelID),
                maxSteps: 8)
            for try await item in events {
                guard activeRequestID == requestID else { return }
                try _Concurrency.Task<Never, Never>.checkCancellation()
                switch item.event {
                case .textDelta(let delta):
                    if let index = messages.firstIndex(where: { $0.id == responseID }) {
                        messages[index].text += delta
                    }
                case .toolResult(_, let name, let jsonText, _, let failed):
                    if !failed, name == "show_task_workspace",
                       let data = jsonText.data(using: .utf8),
                       let decoded = try? JSONDecoder().decode(GSDTaskWorkspaceRequest.self, from: data) {
                        workspace = decoded
                    }
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
            guard activeRequestID == requestID else { return }
            if let index = messages.firstIndex(where: { $0.id == responseID }),
               messages[index].text.isEmpty {
                messages[index].text = "No reply text. Review the tool activity or try again."
            }
        } catch {
            guard activeRequestID == requestID else { return }
            if error is CancellationError || _Concurrency.Task<Never, Never>.isCancelled { return }
            failure = error
            errorMessage = error.localizedDescription
            if let index = messages.firstIndex(where: { $0.id == responseID }),
               messages[index].text.isEmpty {
                messages[index].text = "The AI request failed."
            }
        }
    }
}
