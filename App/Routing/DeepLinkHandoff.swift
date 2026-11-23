import Foundation
import GSDStore
import GSDSnapshot

extension Notification.Name {
    static let gsdOpenDeepLink = Notification.Name("com.itorah.gsd.openDeepLink")
    static let gsdShowCommandPalette = Notification.Name("com.itorah.gsd.showCommandPalette")
    static let gsdShowAbout = Notification.Name("com.itorah.gsd.showAbout")
    static let gsdShowHelp = Notification.Name("com.itorah.gsd.showHelp")
    static let gsdShowFeedback = Notification.Name("com.itorah.gsd.showFeedback")
    static let gsdShowWhatsNew = Notification.Name("com.itorah.gsd.showWhatsNew")
    static let gsdSyncNow = Notification.Name("com.itorah.gsd.syncNow")
}

enum DeepLinkHandoff {
    private static let pendingURLKey = "pendingDeepLinkURL"

    @MainActor
    static func open(_ route: DeepLinkRoute) {
        open(route.url)
    }

    @MainActor
    static func open(_ url: URL) {
        AppGroupDefaults.shared.set(url.absoluteString, forKey: pendingURLKey)
        NotificationCenter.default.post(name: .gsdOpenDeepLink, object: url)
    }

    /// Call when the notification path handled the link live: the persisted copy exists
    /// only as a cold-launch fallback, and left behind it would replay on the next launch.
    @MainActor
    static func clearPendingURL() {
        AppGroupDefaults.shared.removeObject(forKey: pendingURLKey)
    }

    @MainActor
    static func consumePendingURL() -> URL? {
        guard let raw = AppGroupDefaults.shared.string(forKey: pendingURLKey),
              let url = URL(string: raw)
        else { return nil }
        AppGroupDefaults.shared.removeObject(forKey: pendingURLKey)
        return url
    }
}
