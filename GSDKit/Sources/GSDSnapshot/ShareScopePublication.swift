import Foundation

public struct ShareScopePublication: Codable, Equatable, Sendable {
    public let version: Int
    public let nonce: String
    public let scope: WatchAccountScope?
    public let guestBootstrap: Bool

    public init(scope: WatchAccountScope?, nonce: String = UUID().uuidString,
                guestBootstrap: Bool = false) {
        self.version = 1
        self.nonce = nonce
        self.scope = scope
        self.guestBootstrap = guestBootstrap
    }

    public var isValid: Bool {
        version == 1 && UUID(uuidString: nonce) != nil
            && (scope == nil || scope?.isValid == true)
            && (!guestBootstrap || scope?.kind == "guest")
    }
}

/// Publication is separate from the lease inode. Atomic invalidation never waits on a lease.
public struct ShareScopePublicationStore: Sendable {
    public static let filename = "share-scope-publication.json"
    public let directory: URL?
    public init(directory: URL?) { self.directory = directory }

    public func read() throws -> ShareScopePublication? {
        guard let directory else { throw SharedScopeFileError.unavailable }
        let url = directory.appendingPathComponent(Self.filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let record = try JSONDecoder().decode(ShareScopePublication.self, from: Data(contentsOf: url))
        guard record.isValid else { throw SharedScopeFileError.invalid }
        return record
    }

    public func publish(_ record: ShareScopePublication) throws {
        guard record.isValid, let directory else { throw SharedScopeFileError.invalid }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(
            to: directory.appendingPathComponent(Self.filename), options: .atomic)
    }

    /// Only a definitely absent shared Keychain item permits this local, unpushed bootstrap.
    /// A private app-token fallback may still exist: only canonical guest resolution can ingest it.
    public func bootstrapGuestIfAbsent() throws -> ShareScopePublication {
        guard let directory else { throw SharedScopeFileError.unavailable }
        if let existing = try read() { return existing }
        let identity = try SharedDatasetIdentityStore(directory: directory).loadOrCreate()
        let fresh = ShareScopePublication(
            scope: .guest(installationID: identity.installationID, datasetID: identity.datasetID),
            guestBootstrap: true)
        try AtomicSharedFile.createIfAbsent(try JSONEncoder().encode(fresh),
                                           at: directory.appendingPathComponent(Self.filename))
        guard let installed = try read() else { throw SharedScopeFileError.unavailable }
        return installed
    }

    public func matches(_ scope: WatchAccountScope, nonce: String? = nil) -> Bool {
        guard scope.isValid,
              let identity = try? SharedDatasetIdentityStore(directory: directory).read(),
              identity.datasetID == scope.datasetID,
              let record = try? read(), record.scope == scope else { return false }
        if scope.kind == "guest", identity.installationID != scope.identifier { return false }
        return nonce == nil || nonce == record.nonce
    }
}
