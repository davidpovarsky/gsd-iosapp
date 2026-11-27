import CryptoKit
import Foundation

/// Nonsecret denial state survives a failed Keychain clear and an unconfirmed remote revoke.
/// Only hashes of registration identifiers are stored; credentials and account labels are absent.
struct GSDChatGPTLocalSignOutStore: Sendable {
    static let fileName = "sign-outs-v1.json"
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "GSDChatGPTLocalState", directoryHint: .isDirectory)
    }

    private struct Document: Codable {
        let version: Int
        let registrationHashes: [String]
    }

    enum StoreError: Error { case invalidDocument }

    static func registrationHash(_ registrationID: String) -> String {
        SHA256.hash(data: Data(("gsd-chatgpt-signout-v1\u{0}" + registrationID).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    func deniedRegistrationHashes() throws -> Set<String> {
        let data: Data
        do { data = try Data(contentsOf: directory.appendingPathComponent(Self.fileName)) }
        catch {
            let value = error as NSError
            if value.domain == NSCocoaErrorDomain &&
                [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(value.code) { return [] }
            throw error
        }
        let document = try JSONDecoder().decode(Document.self, from: data)
        let unique = Set(document.registrationHashes)
        guard document.version == 1, unique.count == document.registrationHashes.count,
              unique.allSatisfy({ $0.count == 64 && $0.allSatisfy { "0123456789abcdef".contains($0) } }) else {
            throw StoreError.invalidDocument
        }
        return unique
    }

    func markSignedOut(_ registrationID: String) throws {
        var hashes = try deniedRegistrationHashes()
        guard hashes.insert(Self.registrationHash(registrationID)).inserted else { return }
        try write(hashes)
    }

    /// Called only after a newly verified sign-in has been saved to the Keychain.
    func clearAfterSignIn(_ registrationID: String) throws {
        var hashes = try deniedRegistrationHashes()
        guard hashes.remove(Self.registrationHash(registrationID)) != nil else { return }
        try write(hashes)
    }

    private func write(_ hashes: Set<String>) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let document = Document(version: 1, registrationHashes: hashes.sorted())
        try JSONEncoder().encode(document)
            .write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }
}
