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

    /// The sheet, rather than the network helper, owns the immutable server binding.
    /// Preparation runs on the sheet's actor and must succeed before a direct create.
    public struct PushAuthorization: Sendable {
        public let datasetGeneration: String?
        private let preparation: @MainActor @Sendable (String) throws -> Void

        fileprivate init(
            datasetGeneration: String?,
            preparation: @escaping @MainActor @Sendable (String) throws -> Void
        ) {
            self.datasetGeneration = datasetGeneration
            self.preparation = preparation
        }

        @MainActor
        public func prepare(_ generation: String) throws {
            try preparation(generation)
        }
    }
    public let origin: WatchAccountScope?
    private let publicationNonce: String?
    private let credential: Credential
    private let readCredential: @MainActor () -> Credential
    private let publication: ShareScopePublicationStore
    private let outbox: ShareOutboxStore
    private let push: @MainActor (GSDModel.Task, String, PushAuthorization) async -> String?
    private let captureTaskID = IDGenerator.generate(size: IDGenerator.Size.task)
    private let journalID = UUID()
    private var didAttemptPush = false
    private var boundServerGeneration: String?
    private var firstSubmittedInput: SharedCapture?

    public init(outbox: ShareOutboxStore, directory: URL?,
                credential: @escaping @MainActor () -> Credential,
                push: @escaping @MainActor (GSDModel.Task, String, PushAuthorization) async -> String?) {
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
        capture.serverDatasetGeneration = boundServerGeneration
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
            let journalCapture = capture
            let authorization = PushAuthorization(datasetGeneration: boundServerGeneration) { [self] generation in
                try _Concurrency.Task<Never, Never>.checkCancellation()
                guard isCurrent() else { throw PreparationError.staleOrigin }
                guard !generation.isEmpty, generation.utf8.count <= 128,
                      !generation.utf8.contains(where: { $0 < 0x20 || $0 == 0x7F }) else {
                    throw PreparationError.invalidGeneration
                }
                if let boundServerGeneration,
                   !boundServerGeneration.utf8.elementsEqual(generation.utf8) {
                    throw PreparationError.changedGeneration
                }
                // Remember the authority even if this journal rewrite fails. No POST may
                // start until the bound payload is durable, and retries never discover anew.
                boundServerGeneration = generation
                var boundCapture = journalCapture
                boundCapture.serverDatasetGeneration = generation
                try outbox.writeInFlight(boundCapture, id: journalID)
            }
            capture.remoteRecordID = await push(task, frozenToken, authorization)
            capture.serverDatasetGeneration = boundServerGeneration
        }
        // Retry after any outbox failure still uses the same task ID, takes no second POST,
        // and queues current edits through create rather than claiming the first remote fields.
        try outbox.write(capture)
        outbox.removeInFlight(id: journalID)
        let verified = isCurrent() && (try? publication.read())?.guestBootstrap == false
        let hasRequiredBinding = origin?.kind != "account" || capture.serverDatasetGeneration != nil
        return verified && hasRequiredBinding ? .queued : .held
    }
    private enum PreparationError: Error { case staleOrigin, invalidGeneration, changedGeneration }
}
