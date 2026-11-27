import Foundation

/// Nonsecret origin for a Watch action. Dataset identity changes before a confirmed reset,
/// independently of the cloud account, so an old queued capture cannot resurrect erased data.
/// Unknown metadata decodes intact but is invalid for admission; old payloads omit this field.
public struct WatchAccountScope: Codable, Equatable, Hashable, Sendable {
    public let kind: String
    public let identifier: String
    public let datasetID: String?

    private init(kind: String, identifier: String, datasetID: String) {
        self.kind = kind
        self.identifier = identifier
        self.datasetID = datasetID
    }

    public static func account(userID: String, datasetID: String) -> Self {
        Self(kind: "account", identifier: userID, datasetID: datasetID)
    }

    public static func guest(installationID: String, datasetID: String) -> Self {
        Self(kind: "guest", identifier: installationID, datasetID: datasetID)
    }

    public var isValid: Bool {
        guard let datasetID, UUID(uuidString: datasetID) != nil else { return false }
        switch kind {
        case "guest":
            return UUID(uuidString: identifier) != nil
        case "account":
            return !identifier.isEmpty && identifier.utf8.count <= 160
                && identifier == identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            return false
        }
    }

    /// A property-list-safe JSON string carried with local notifications on phone and Watch.
    public static let notificationKey = "gsd.watchAccountScope"

    public var notificationValue: String? {
        guard isValid, let data = try? JSONEncoder().encode(self) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func fromNotification(_ userInfo: [AnyHashable: Any]) -> Self? {
        guard let value = userInfo[notificationKey] as? String,
              let scope = try? JSONDecoder().decode(Self.self, from: Data(value.utf8)),
              scope.isValid else { return nil }
        return scope
    }
}
