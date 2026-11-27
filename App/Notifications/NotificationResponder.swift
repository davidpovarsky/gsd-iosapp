import UIKit
import UserNotifications
import GSDModel
import GSDSnapshot
import GSDStore

/// Routes reminder actions and taps with their scheduled account and dataset. The scoped
/// inbox retains cold-launch taps until ContentView can validate and present them; ordinary
/// user-authored URLs continue through DeepLinkHandoff independently.
// `@preconcurrency`: `UNUserNotificationCenterDelegate` isn't `@MainActor`-annotated in the SDK,
// but its callbacks are delivered on the main thread, so the @MainActor `AppDelegate` can satisfy
// it safely (the compiler inserts a main-actor check at the dispatch boundary).
extension AppDelegate: @preconcurrency UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().setNotificationCategories([Self.reminderCategory])
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        guard let taskID = response.notification.request.content.userInfo["taskID"] as? String else {
            completionHandler()
            return
        }
        let scope = WatchAccountScope.fromNotification(response.notification.request.content.userInfo)
        switch response.actionIdentifier {
        case ReminderAction.completeID, ReminderAction.snoozeID:
            // The system keeps a background launch alive until this handler is called, so hold it
            // until the store write lands.
            ReminderActionInbox.deliver(action: response.actionIdentifier, taskID: taskID,
                                        scope: scope, done: completionHandler)
        case UNNotificationDefaultActionIdentifier:
            // Only a tap opens the task. A swipe-away dismiss must not navigate.
            ReminderActionInbox.requestOpen(taskID: taskID, scope: scope)
            completionHandler()
        default:
            completionHandler()
        }
    }

    /// The buttons under a reminder: Complete and Snooze 1 hour (B-17). No `.foreground`, so
    /// neither opens the app; both act in place through `ReminderActionInbox`.
    private static var reminderCategory: UNNotificationCategory {
        UNNotificationCategory(
            identifier: ReminderAction.categoryID,
            actions: [
                UNNotificationAction(identifier: ReminderAction.completeID,
                                     title: String(localized: "Complete"), options: []),
                UNNotificationAction(identifier: ReminderAction.snoozeID,
                                     title: String(localized: "Snooze 1 hour"), options: []),
            ],
            intentIdentifiers: [])
    }
}
