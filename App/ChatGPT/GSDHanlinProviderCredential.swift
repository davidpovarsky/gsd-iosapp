import Foundation
import Security

/// An opaque registration identifies the saved provider configuration. It is not
/// derived from the credential, and can safely contribute to a conversation scope.
struct GSDHanlinProviderCredential: Codable, Equatable, Sendable {
    let version: Int
    let registrationID: UUID
    let credential: String

    init(registrationID: UUID = UUID(), credential: String) {
        version = 1
        self.registrationID = registrationID
        self.credential = credential
    }

    func conversationAccountID(endpoint: String) -> String {
        registrationID.uuidString + ":" + endpoint
    }
}

enum GSDHanlinProviderCredentialError: Error { case invalidRecord }

/// The credential and its registration are one atomic Keychain value. The injected
/// byte operations also let acceptance exercise failures without reading real keys.
@MainActor
struct GSDHanlinProviderCredentialStore {
    var loadData: () throws -> Data?
    var saveData: (Data) throws -> Void
    var deleteData: () throws -> Void
    private static let prefix = Data("GSD-HANLIN-CREDENTIAL-V1\n".utf8)

    func read() throws -> GSDHanlinProviderCredential? {
        guard let (record, legacy) = try decoded() else { return nil }
        if legacy { try saveData(Self.encoded(record)) }
        return record
    }

    @discardableResult
    func save(_ credential: String) throws -> GSDHanlinProviderCredential? {
        guard !credential.isEmpty else {
            try deleteData()
            return nil
        }
        let previous = try decoded()?.0
        // Unchanged credentials keep their history across model-only edits. A different
        // credential gets an unrelated registration, even at the same endpoint.
        let record: GSDHanlinProviderCredential
        if let previous, previous.credential == credential {
            record = previous
        } else {
            record = GSDHanlinProviderCredential(credential: credential)
        }
        try saveData(Self.encoded(record))
        return record
    }

    private func decoded() throws -> (GSDHanlinProviderCredential, legacy: Bool)? {
        guard let bytes = try loadData(), !bytes.isEmpty else { return nil }
        if bytes.starts(with: Self.prefix) {
            let record = try JSONDecoder().decode(
                GSDHanlinProviderCredential.self, from: Data(bytes.dropFirst(Self.prefix.count)))
            guard record.version == 1, !record.credential.isEmpty else {
                throw GSDHanlinProviderCredentialError.invalidRecord
            }
            return (record, false)
        }
        guard let legacy = String(data: bytes, encoding: .utf8), !legacy.isEmpty else {
            throw GSDHanlinProviderCredentialError.invalidRecord
        }
        return (.init(credential: legacy), true)
    }

    private static func encoded(_ record: GSDHanlinProviderCredential) throws -> Data {
        prefix + (try JSONEncoder().encode(record))
    }
}

@MainActor
enum GSDHanlinProviderKeychain {
    private static let service = "com.itorah.gsd.hanlin-agent"
    private static let account = "current-provider-api-key"

    static var store: GSDHanlinProviderCredentialStore {
        .init(loadData: readData, saveData: saveData, deleteData: deleteData)
    }

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private static func readData() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return data
    }

    private static func saveData(_ data: Data) throws {
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private static func deleteData() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}
