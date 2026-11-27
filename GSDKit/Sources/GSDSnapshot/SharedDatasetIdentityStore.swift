import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The existing Watch identity codec is also used by the GRDB-free Share process.
public struct SharedDatasetIdentity: Codable, Equatable, Sendable {
    public let installationID: String
    public let datasetID: String

    public init(installationID: String, datasetID: String) {
        self.installationID = installationID
        self.datasetID = datasetID
    }

    public var isValid: Bool {
        UUID(uuidString: installationID) != nil && UUID(uuidString: datasetID) != nil
    }
}

public struct SharedDatasetIdentityStore: Sendable {
    public static let filename = "watch-dataset-identity.json"
    public let directory: URL?

    public init(directory: URL?) { self.directory = directory }

    public func read() throws -> SharedDatasetIdentity {
        guard let directory else { throw SharedScopeFileError.unavailable }
        let value = try JSONDecoder().decode(SharedDatasetIdentity.self,
            from: Data(contentsOf: directory.appendingPathComponent(Self.filename)))
        guard value.isValid else { throw SharedScopeFileError.invalid }
        return value
    }

    public func loadOrCreate() throws -> SharedDatasetIdentity {
        guard let directory else { throw SharedScopeFileError.unavailable }
        let url = directory.appendingPathComponent(Self.filename)
        if FileManager.default.fileExists(atPath: url.path) { return try read() }
        let fresh = SharedDatasetIdentity(installationID: UUID().uuidString, datasetID: UUID().uuidString)
        try AtomicSharedFile.createIfAbsent(try JSONEncoder().encode(fresh), at: url)
        // A concurrent first Share/app may have won. Always use the installed bytes.
        return try read()
    }

    /// The caller must hold the exclusive external-write lease and have drained local writes.
    public func replace(_ identity: SharedDatasetIdentity) throws {
        guard identity.isValid, let directory else { throw SharedScopeFileError.invalid }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(identity).write(
            to: directory.appendingPathComponent(Self.filename), options: .atomic)
    }
}

public enum SharedScopeFileError: Error, Sendable {
    case unavailable
    case invalid
    case timedOut
}

enum AtomicSharedFile {
    static func createIfAbsent(_ data: Data, at destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".scope-" + UUID().uuidString + ".tmp")
        try data.write(to: temporary, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let result = temporary.path.withCString { source in
            destination.path.withCString { target in link(source, target) }
        }
        guard result == 0 || errno == EEXIST else { throw SharedScopeFileError.unavailable }
    }
}
