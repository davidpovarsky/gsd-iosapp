import CryptoKit
import Foundation
import HanlinHostContracts
import HanlinPersistenceAdapters

/// Stable, opaque identity for one GSD account and one provider account.
/// Credentials never contribute to the identifier or the saved conversation.
public struct GSDHanlinConversationScope: Hashable, Sendable {
    public let accountID: String
    public let conversationID: UUID = UUID(uuidString: "560F6465-2467-47E1-8DA5-60262D81B6AD")!

    public init(gsdAccountID: String?, provider: String, providerAccountID: String?) {
        var input = Data("gsd-assistant-scope-v1".utf8)
        for component in [gsdAccountID, Optional(provider), providerAccountID] {
            guard let component else { input.append(0); continue }
            input.append(1)
            let bytes = Data(component.utf8)
            var count = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &count) { input.append(contentsOf: $0) }
            input.append(bytes)
        }
        accountID = "assistant-v1-" + SHA256.hash(data: input)
            .map { String(format: "%02x", $0) }.joined()
    }

    var displayNamespace: HanlinConversationNamespace {
        get throws {
            try HanlinConversationNamespace(
                app: "gsd", account: accountID, workspace: "local", space: "assistant-display-v1")
        }
    }
}

/// Display state only. No executable tool requests, credentials, grants or approvals are restored.
struct GSDHanlinConversationSnapshot: Codable, Equatable, Sendable {
    let version: Int
    let messages: [GSDHanlinMessage]
    let workspace: GSDTaskWorkspaceRequest?

    init(messages: [GSDHanlinMessage], workspace: GSDTaskWorkspaceRequest? = nil) {
        version = 1
        self.messages = messages
        self.workspace = workspace
    }
}

enum GSDHanlinHistoryError: LocalizedError {
    case invalidSnapshot

    var errorDescription: String? {
        "The saved conversation could not be read. Its existing data has been preserved."
    }
}

/// Uses the original Hanlin private store, in a separate display-only namespace.
/// The agent's execution journal remains authoritative and is never rewritten here.
@MainActor
final class GSDHanlinConversationHistory {
    let scope: GSDHanlinConversationScope
    let store: any HanlinConversationStore
    let directory: URL
    private var owner: UUID?
    private var pendingSave: _Concurrency.Task<Void, Error>?
    private static let marker = "gsd.assistant.display.v1"

    init(scope: GSDHanlinConversationScope, store: any HanlinConversationStore, directory: URL) {
        self.scope = scope
        self.store = store
        self.directory = directory
    }

    func isOwned(by owner: UUID) -> Bool { self.owner == owner }

    /// A newly opened sheet owns future writes. Already queued writes finish before its load.
    func activate(owner: UUID) async throws -> GSDHanlinConversationSnapshot? {
        self.owner = owner
        if let pendingSave { _ = await pendingSave.result }
        guard self.owner == owner else { throw CancellationError() }
        let record = try await store.load(scope.conversationID, namespace: scope.displayNamespace)
        guard self.owner == owner else { throw CancellationError() }
        return try record.map(Self.decode)
    }

    /// Queue synchronously so a dismissed sheet cannot enqueue a late write after a new owner.
    func save(_ snapshot: GSDHanlinConversationSnapshot, owner: UUID) -> _Concurrency.Task<Void, Error> {
        guard self.owner == owner else {
            return _Concurrency.Task { throw CancellationError() }
        }
        let previous = pendingSave
        let store = store
        let scope = scope
        let operation = _Concurrency.Task { @MainActor in
            if let previous { _ = await previous.result }
            let namespace = try scope.displayNamespace
            let current = try await store.load(scope.conversationID, namespace: namespace)
            if let current {
                _ = try Self.decode(current)
                guard current.revision < UInt64.max else { throw HanlinHostError.storageLimitExceeded }
            }
            let bytes = try JSONEncoder().encode(snapshot)
            guard let text = String(data: bytes, encoding: .utf8) else {
                throw GSDHanlinHistoryError.invalidSnapshot
            }
            let record = HanlinConversationRecord(
                namespace: namespace, conversationID: scope.conversationID,
                revision: current.map { $0.revision + 1 } ?? 0,
                entries: [
                    .init(runID: scope.conversationID, step: 0, sequence: 0,
                          payload: .presentationReference(version: 1, opaqueReference: Self.marker)),
                    .init(runID: scope.conversationID, step: 0, sequence: 1, payload: .text(text))
                ])
            try await store.save(record, replacing: current?.revision)
        }
        pendingSave = operation
        return operation
    }

    private static func decode(_ record: HanlinConversationRecord) throws -> GSDHanlinConversationSnapshot {
        guard record.entries.count == 2,
              case .presentationReference(let version, let reference) = record.entries[0].payload,
              version == 1, reference == marker,
              case .text(let text) = record.entries[1].payload,
              let data = text.data(using: .utf8) else { throw GSDHanlinHistoryError.invalidSnapshot }
        let snapshot = try JSONDecoder().decode(GSDHanlinConversationSnapshot.self, from: data)
        guard snapshot.version == 1,
              Set(snapshot.messages.map(\.id)).count == snapshot.messages.count else {
            throw GSDHanlinHistoryError.invalidSnapshot
        }
        return snapshot
    }
}

/// One store actor per directory and one write queue per conversation in this process.
@MainActor
enum GSDHanlinConversationHistoryRegistry {
    private struct Directory {
        let store: HanlinPrivateConversationStore
        var histories: [GSDHanlinConversationScope: GSDHanlinConversationHistory] = [:]
    }
    private static var directories: [String: Directory] = [:]

    static func history(scope: GSDHanlinConversationScope, directory: URL) throws -> GSDHanlinConversationHistory {
        // Foundation can add a directory hint after the first save and shorten
        // Darwin's /private aliases. Neither changes ownership of the private store.
        var key = directory.standardizedFileURL.path(percentEncoded: false)
        while key.count > 1, key.hasSuffix("/") { key.removeLast() }
        #if canImport(Darwin)
        for alias in ["/var", "/tmp", "/etc"]
            where key == "/private" + alias || key.hasPrefix("/private" + alias + "/") {
            key.removeFirst("/private".count)
            break
        }
        #endif
        if let history = directories[key]?.histories[scope] { return history }
        var entry: Directory
        if let existing = directories[key] {
            entry = existing
        } else {
            entry = Directory(store: try HanlinPrivateConversationStore(directory: directory))
        }
        let history = GSDHanlinConversationHistory(scope: scope, store: entry.store, directory: directory)
        entry.histories[scope] = history
        directories[key] = entry
        return history
    }
}
