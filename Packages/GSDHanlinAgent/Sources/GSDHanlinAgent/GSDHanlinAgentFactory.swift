import Foundation
import GSDStore
import HanlinAgentCore
import HanlinChatCore
import HanlinHostContracts
import HanlinPersistenceAdapters

/// One real Hanlin agent engine, one GSD authority and one private conversation
/// store. The caller owns credentials and user consent UI. No hard-coded secrets.
@MainActor
public struct GSDHanlinAgentBundle {
    public let host: GSDHanlinHost
    public let agent: HanlinAgentSession
    public let identity: HanlinHostSession

    public init(host: GSDHanlinHost, agent: HanlinAgentSession, identity: HanlinHostSession) {
        self.host = host; self.agent = agent; self.identity = identity
    }
}

@MainActor
public enum GSDHanlinAgentFactory {
    public static func make(
        store: TaskStore,
        configuration: HanlinChatModelConfiguration,
        accountID: String,
        conversationDirectory: URL,
        conversationID: UUID = UUID(),
        sceneID: UUID = UUID(),
        writeAuthorizer: @escaping GSDHanlinHost.WriteAuthorizer = { _ in false }
    ) throws -> GSDHanlinAgentBundle {
        let namespace = try HanlinConversationNamespace(
            app: "gsd", account: accountID, workspace: "local", space: "tasks")
        let context = HanlinHostContext(
            namespace: namespace, sceneID: sceneID, generation: UUID(),
            objectReference: "gsd-tasks", localeIdentifier: Locale.current.identifier)
        let identity = HanlinHostSession(conversationID: conversationID, context: context)
        let host = GSDHanlinHost(store: store, context: context, writeAuthorizer: writeAuthorizer)
        let engine: HanlinAISDKAgentEngine
        #if DEBUG && targetEnvironment(simulator)
        if GSDNativeHanlinProviderFixture.isEnabled {
            // Only the provider HTTP response is deterministic. The SDK stream,
            // host authorization, tool execution and result events stay real.
            engine = try HanlinAISDKAgentEngine(configuration: configuration, fetch: { request in
                let response = try GSDNativeHanlinProviderFixture.response(for: request)
                return .init(body: .data(response.data), urlResponse: response.http)
            })
        } else {
            engine = try HanlinAISDKAgentEngine(configuration: configuration)
        }
        #else
        engine = try HanlinAISDKAgentEngine(configuration: configuration)
        #endif
        let persistence = try HanlinPrivateConversationStore(directory: conversationDirectory)
        let agent = HanlinAgentSession(
            identity: identity, host: host, engine: engine, store: persistence)
        // Provider approval means only "continue to host evaluation".
        // Actual writes are NEVER allowed without writeAuthorizer approval.
        agent.onProviderToolApproval = { _ in true }
        return .init(host: host, agent: agent, identity: identity)
    }
}

#if DEBUG && targetEnvironment(simulator)
/// Explicit simulator-only provider fixture. It cannot run in an archive, outside
/// demo storage, or against a real provider. It never manufactures a tool result.
private enum GSDNativeHanlinProviderFixture {
    static let taskTitle = "Hanlin native workspace acceptance"
    static let createCallID = "gsd_native_create_task"
    static let workspaceCallID = "gsd_native_show_workspace"

    static var isEnabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--demo-seed") && arguments.contains("--gsd-native-hanlin-fixture")
    }

    static func response(for request: URLRequest) throws -> (data: Data, http: HTTPURLResponse) {
        guard isEnabled,
              request.url?.host == "gsd-workspace-acceptance.invalid",
              let url = request.url, let bytes = request.httpBody,
              let body = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              body["stream"] as? Bool == true,
              let tools = body["tools"] as? [[String: Any]],
              let messages = body["messages"] as? [[String: Any]] else {
            throw URLError(.badServerResponse)
        }
        let names = tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        guard names.filter({ $0 == "create_task" }).count == 1,
              names.filter({ $0 == "show_task_workspace" }).count == 1 else {
            throw URLError(.badServerResponse)
        }
        let results = messages.filter { $0["role"] as? String == "tool" }
        let createResults = results.filter { $0["tool_call_id"] as? String == createCallID }
        let workspaceResults = results.filter { $0["tool_call_id"] as? String == workspaceCallID }
        let delta: [String: Any]
        let finishReason: String
        if results.isEmpty {
            delta = try toolDelta(name: "create_task", id: createCallID,
                                  arguments: ["title": taskTitle, "important": true])
            finishReason = "tool_calls"
        } else {
            guard createResults.count == 1,
                  let created = try resultObject(createResults[0]),
                  let createdID = created["id"] as? String, !createdID.isEmpty,
                  created["title"] as? String == taskTitle else {
                throw URLError(.badServerResponse)
            }
            if workspaceResults.isEmpty {
                guard results.count == 1 else { throw URLError(.badServerResponse) }
                delta = try toolDelta(name: "show_task_workspace", id: workspaceCallID,
                                      arguments: ["presentation": "table", "ids": [createdID],
                                                  "title": "Hanlin created task"])
                finishReason = "tool_calls"
            } else {
                guard results.count == 2, workspaceResults.count == 1,
                      let workspace = try resultObject(workspaceResults[0]),
                      workspace["presentation"] as? String == "table",
                      workspace["taskIDs"] as? [String] == [createdID] else {
                    throw URLError(.badServerResponse)
                }
                delta = ["role": "assistant", "content": "Hanlin native workspace ready."]
                finishReason = "stop"
            }
        }
        let first = try event(delta: delta, finishReason: nil)
        let last = try event(delta: [:], finishReason: finishReason)
        guard let http = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                        headerFields: ["Content-Type": "text/event-stream"]) else {
            throw URLError(.badServerResponse)
        }
        return (Data((first + last + "data: [DONE]\n\n").utf8), http)
    }

    private static func resultObject(_ message: [String: Any]) throws -> [String: Any]? {
        guard let text = message["content"] as? String, let data = text.data(using: .utf8) else {
            return nil
        }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func toolDelta(name: String, id: String, arguments: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else { throw URLError(.badServerResponse) }
        return ["role": "assistant", "tool_calls": [
            ["index": 0, "id": id, "type": "function", "function": ["name": name, "arguments": text]]
        ]]
    }

    private static func event(delta: [String: Any], finishReason: String?) throws -> String {
        let object: [String: Any] = [
            "id": "gsd-native-fixture", "object": "chat.completion.chunk", "created": 0,
            "model": "gsd-native-fixture", "choices": [
                ["index": 0, "delta": delta, "finish_reason": finishReason.map { $0 as Any } ?? NSNull()]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else { throw URLError(.badServerResponse) }
        return "data: " + text + "\n\n"
    }
}
#endif
