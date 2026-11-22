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
        let engine = try HanlinAISDKAgentEngine(configuration: configuration)
        let persistence = try HanlinPrivateConversationStore(directory: conversationDirectory)
        let agent = HanlinAgentSession(
            identity: identity, host: host, engine: engine, store: persistence)
        // Provider approval means only "continue to host evaluation".
        // Actual writes are NEVER allowed without writeAuthorizer approval.
        agent.onProviderToolApproval = { _ in true }
        return .init(host: host, agent: agent, identity: identity)
    }
}
