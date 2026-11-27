import Foundation
import Observation

/// Admission for Watch writes and dataset replacement. A pause closes admission synchronously,
/// then waits for complete TaskStore operations, including their internal repository awaits.
/// Nested/overlapping pauses share the hold count; cancellation cannot release another hold.
@MainActor @Observable
final class WatchMutationGate {
    struct Identity: Codable, Equatable {
        let installationID: String
        let datasetID: String

        var isValid: Bool {
            UUID(uuidString: installationID) != nil && UUID(uuidString: datasetID) != nil
        }
    }

    private(set) var identity: Identity?
    private(set) var isPaused = false
    @ObservationIgnored private let identityURL: URL?
    @ObservationIgnored private var pauses = 0
    @ObservationIgnored private var admitted: Set<UUID> = []
    @ObservationIgnored private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    /// No identity means no Watch admission. The app can still run, while a later dataset
    /// replacement retries the durable identity write before erasing any local data.
    init(directory: URL?) {
        identityURL = directory?.appendingPathComponent("watch-dataset-identity.json")
        if let identityURL {
            do {
                if FileManager.default.fileExists(atPath: identityURL.path) {
                    let saved = try JSONDecoder().decode(Identity.self, from: Data(contentsOf: identityURL))
                    guard saved.isValid else { return }
                    identity = saved
                } else {
                    let fresh = Identity(installationID: UUID().uuidString, datasetID: UUID().uuidString)
                    try Self.write(fresh, to: identityURL)
                    identity = fresh
                }
            } catch {
                // Fail closed. Do not overwrite unreadable identity data during initialization.
            }
        }
    }

    func admit() -> UUID? {
        guard !isPaused, identity != nil else { return nil }
        let ticket = UUID()
        admitted.insert(ticket)
        return ticket
    }

    func finish(_ ticket: UUID) {
        guard admitted.remove(ticket) != nil, admitted.isEmpty else { return }
        let waiters = drainWaiters
        drainWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    /// Only transition/erase callers use this method, never an admitted Watch operation.
    /// Awaiting one's own ticket would deadlock; the coordinator only admits and finishes.
    func withPaused<T>(_ operation: @MainActor () async throws -> T) async rethrows -> T {
        pauses += 1
        if !isPaused { isPaused = true }
        defer {
            pauses -= 1
            if pauses == 0 { isPaused = false }
        }
        if !admitted.isEmpty {
            await withCheckedContinuation { drainWaiters.append($0) }
        }
        return try await operation()
    }

    /// Rotate before the destructive body, after old writes drain. Commands outside the admitted
    /// set keep their old dataset id and cannot recreate erased tasks after the pause ends.
    /// A failed durable write prevents the local replacement from starting.
    func replacingDataset<T>(_ operation: @MainActor () async throws -> T) async throws -> T {
        try await withPaused {
            guard let identityURL else { throw IdentityError.unavailable }
            let fresh = Identity(installationID: identity?.installationID ?? UUID().uuidString,
                                 datasetID: UUID().uuidString)
            try Self.write(fresh, to: identityURL)
            identity = fresh
            return try await operation()
        }
    }

    private static func write(_ identity: Identity, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
        try JSONEncoder().encode(identity).write(to: url, options: .atomic)
    }

    private enum IdentityError: Error { case unavailable }
}
