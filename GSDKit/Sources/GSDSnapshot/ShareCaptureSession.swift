import Foundation
import GSDModel

/// One compose sheet owns one task ID, credential snapshot and immutable capture origin.
@MainActor
public final class ShareCaptureSession {
    public enum Credential: Sendable, Equatable {
        case account(token: String, ownerID: String)
        case signedOut
        case unavailable
    }
    public enum SaveResult: Sendable, Equatable { case queued, held }
    public let origin: WatchAccountScope?
    private let publicationNonce: String?
    private let credential: Credential
    private let readCredential: @MainActor () -> Credential
    private let publication: ShareScopePublicationStore
    private let outbox: ShareOutboxStore
    private let push: @MainActor (GSDModel.Task, String) async -> String?
    private let captureTaskID = IDGenerator.generate(size: IDGenerator.Size.task)
    private let journalID = UUID()
    private var didAttemptPush = false
    private var firstSubmittedInput: SharedCapture?

    public init(outbox: ShareOutboxStore, directory: URL?,
                credential: @escaping @MainActor () -> Credential,
                push: @escaping @MainActor (GSDModel.Task, String) async -> String?) {
        self.outbox = outbox
        self.publication = ShareScopePublicationStore(directory: directory)
        self.readCredential = credential
        self.credential = credential()
        self.push = push
        var record = try? publication.read()
        if record == nil, self.credential == .signedOut {
            // No metadata + absent shared item is only an unpushed guest bootstrap.
            // The main app may have a private token fallback and must resolve it itself.
            record = try? publication.bootstrapGuestIfAbsent()
        }
        if let record, let scope = record.scope, publication.matches(scope),
           Self.credential(self.credential, matches: scope) {
            origin = scope
            publicationNonce = record.nonce
        } else {
            origin = nil
            publicationNonce = nil
        }
    }

    private static func credential(_ credential: Credential, matches scope: WatchAccountScope) -> Bool {
        switch credential {
        case .account(_, let owner): scope.kind == "account" && scope.identifier == owner
        case .signedOut: scope.kind == "guest"
        case .unavailable: false
        }
    }

    private func isCurrent() -> Bool {
        guard let origin, let publicationNonce,
              publication.matches(origin, nonce: publicationNonce),
              readCredential() == credential else { return false }
        return true
    }

    /// The retry fact follows authored fields, never timestamps or mutable server metadata.
    private static func sameAuthoredInput(_ lhs: SharedCapture, _ rhs: SharedCapture) -> Bool {
        lhs.title == rhs.title && lhs.urls == rhs.urls && lhs.urgent == rhs.urgent
            && lhs.important == rhs.important && lhs.tags == rhs.tags
    }

    public func save(_ input: SharedCapture) async throws -> SaveResult {
        let lease = try await SharedMutationLease.acquire(directory: publication.directory, mode: .shared)
        defer { lease.release() }
        try _Concurrency.Task<Never, Never>.checkCancellation()
        var capture = input
        capture.taskID = captureTaskID
        capture.origin = origin
        capture.remoteRecordID = nil
        if let firstSubmittedInput {
            capture.isEditedRetry = Self.sameAuthoredInput(firstSubmittedInput, input) ? nil : true
        } else {
            firstSubmittedInput = input
            capture.isEditedRetry = nil
        }
        // A process death or ambiguous HTTP failure must retain the chosen identity.
        // Recovery waits for this lease before treating a journal as an abandoned write.
        try outbox.writeInFlight(capture, id: journalID)
        if !didAttemptPush, isCurrent(),
           let record = try? publication.read(), !record.guestBootstrap,
           case .account(let frozenToken, _) = credential, let task = capture.pushedTask() {
            didAttemptPush = true
            capture.remoteRecordID = await push(task, frozenToken)
        }
        // Retry after any outbox failure still uses the same task ID, takes no second POST,
        // and queues current edits through create rather than claiming the first remote fields.
        try outbox.write(capture)
        outbox.removeInFlight(id: journalID)
        let verified = isCurrent() && (try? publication.read())?.guestBootstrap == false
        return verified ? .queued : .held
    }
}
