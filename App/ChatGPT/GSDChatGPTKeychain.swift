import Foundation
import HanlinChatCore
import Security

struct GSDChatGPTRegistration: Codable {
    let clientID: String
    let subject: String
    let email: String?
    var credentials: HanlinChatGPTPlanCredentials?
    var modelID: String
    var hasShownPlanWelcome: Bool

    init(credentials: HanlinChatGPTPlanCredentials) {
        clientID = credentials.clientID
        subject = credentials.subject
        email = credentials.email
        self.credentials = credentials
        modelID = ""
        hasShownPlanWelcome = false
    }
}

struct GSDChatGPTSnapshot: Codable {
    var hostID: String
    var accounts: [GSDChatGPTRegistration]
    var activeID: String?

    static func empty() -> Self {
        .init(hostID: HanlinChatGPTPlanClient.makeHostID(), accounts: [], activeID: nil)
    }
}

enum GSDChatGPTKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.itorah.gsd.chatgpt.plan",
         kSecAttrAccount as String: "registrations"]
    }

    static func load() throws -> GSDChatGPTSnapshot? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return try JSONDecoder().decode(GSDChatGPTSnapshot.self, from: data)
    }

    static func save(_ snapshot: GSDChatGPTSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        let attributes = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
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
}
