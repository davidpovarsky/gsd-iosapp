import Foundation
import GSDModel

/// One direct `create` of a task against PocketBase, for a process that has no store and no
/// sync engine: the Share Extension after the user taps Save (spec §10.3). On iOS the extension
/// never foregrounds the app, so without this the capture waited in the outbox until the next
/// open or background refresh; with it, the task is on the server (and on every other device,
/// over SSE) before the sheet dismisses.
///
/// Deliberately narrow. It never refreshes a token (the app does that; an expired token is a
/// skip), never retries a request, and never throws (the caller always writes the
/// outbox afterwards, with or without the record id). Its server generation stays fixed across
/// retries. `owner` comes from the JWT and `device_id`
/// from the shared App-Group identity, exactly as `SyncEngine.push` stamps them, so a record pushed
/// here is indistinguishable from one the app pushed.
public struct DirectTaskPush: Sendable {
    public enum SkipReason: Equatable, Sendable {
        case signedOut          // no token in the shared keychain
        case tokenExpired       // the app will refresh it; the outbox path covers this capture
        case malformedToken     // no `id` claim → no owner to stamp (SyncEngine refuses this too)
        case noDeviceIdentity   // the app has never written `deviceId` to the App Group
    }
    public enum Outcome: Equatable, Sendable {
        case pushed(recordID: String)
        case skipped(SkipReason)
        case failed(String)     // network / HTTP / decode — description only, for a log line
    }

    private let client: PocketBaseClient
    private let token: @Sendable () -> String?
    private let deviceID: @Sendable () -> String?
    private let now: @Sendable () -> Date
    private let defaultReminder: @Sendable () -> Int

    /// - Parameters:
    ///   - client: a `PocketBaseClient`; the extension passes one over a short-timeout session.
    ///   - token: the raw session JWT, or nil when signed out (`SharedTokenKeychain.load`).
    ///   - deviceID: the App-Group `deviceId`, or nil if the app has never set it.
    ///   - defaultReminder: this device's Default reminder in minutes; a shared task has no offset
    ///     of its own, and the wire always carries a number (D-10).
    public init(client: PocketBaseClient,
                token: @escaping @Sendable () -> String?,
                deviceID: @escaping @Sendable () -> String?,
                defaultReminder: @escaping @Sendable () -> Int,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.token = token
        self.deviceID = deviceID
        self.now = now
        self.defaultReminder = defaultReminder
    }

    /// Discovers the server generation once unless this capture already owns a durable binding.
    /// The required callback revalidates the sheet's origin and journals that exact generation
    /// before the first POST. A failed discovery or callback never falls back to an unbound create.
    public func attempt(
        _ task: Task,
        datasetGeneration: String? = nil,
        beforeCreate: @Sendable (String) async throws -> Void
    ) async -> Outcome {
        guard let frozenToken = token() else { return .skipped(.signedOut) }
        guard !JWT.expiresWithin(0, of: frozenToken, now: now()) else { return .skipped(.tokenExpired) }
        guard let owner = JWT.userId(frozenToken) else { return .skipped(.malformedToken) }
        guard let deviceID = deviceID(), !deviceID.isEmpty else { return .skipped(.noDeviceIdentity) }
        let record = TaskWireMapper.toWire(task, owner: owner, deviceId: deviceID, defaultReminder: defaultReminder())
        do {
            try _Concurrency.Task<Never, Never>.checkCancellation()
            let generation: String
            if let datasetGeneration {
                try DatasetIdentifier.validate(datasetGeneration, field: "generation")
                generation = datasetGeneration
            } else {
                generation = try await client.fetchDatasetGeneration(token: frozenToken)
            }
            try _Concurrency.Task<Never, Never>.checkCancellation()
            guard token()?.utf8.elementsEqual(frozenToken.utf8) == true else {
                throw PreparationError.credentialsChanged
            }
            guard !JWT.expiresWithin(0, of: frozenToken, now: now()) else { return .skipped(.tokenExpired) }
            try await beforeCreate(generation)
            try _Concurrency.Task<Never, Never>.checkCancellation()
            guard token()?.utf8.elementsEqual(frozenToken.utf8) == true else {
                throw PreparationError.credentialsChanged
            }
            guard !JWT.expiresWithin(0, of: frozenToken, now: now()) else { return .skipped(.tokenExpired) }
            return .pushed(recordID: try await client.createTask(
                record, datasetGeneration: generation, token: frozenToken))
        } catch {
            return .failed(String("\(error)".prefix(200)))
        }
    }

    private enum PreparationError: Error { case credentialsChanged }
}
