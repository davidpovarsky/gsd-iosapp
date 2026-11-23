/// Identifiers for the buttons on a reminder notification (B-17). Strings only, so the iPhone
/// app and the watch app can each build their `UNNotificationCategory` from one source without
/// this module importing `UserNotifications`. The values never change: reminders already
/// scheduled on a device match their category and actions by these strings.
public enum ReminderAction {
    public static let categoryID = "com.itorah.gsd.reminder"
    public static let completeID = "com.itorah.gsd.reminder.complete"
    public static let snoozeID = "com.itorah.gsd.reminder.snooze1h"
}
