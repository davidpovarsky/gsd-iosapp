import Foundation
import GSDModel

/// Applies a tapped reminder button through `TaskStore`, the single mutation path, so the
/// change is stamped, enqueued for sync, and seen by widgets and Spotlight like any edit.
/// The notification's task may have changed since it was scheduled (completed on another
/// device, saved, deleted), so every action re-reads the persisted row and does nothing
/// when the button no longer applies. `toggleComplete` alone would UNcomplete a task that
/// is already done.
@MainActor
public struct ReminderActionHandler {
    public enum Outcome: Equatable, Sendable { case completed, snoozed, ignored }

    private let store: TaskStore
    private let databaseWindow: BackgroundDatabaseWindow

    public init(store: TaskStore,
                isBackgrounded: @escaping @MainActor () -> Bool = { false },
                resumeDatabase: (@MainActor () -> Void)? = nil,
                suspendDatabase: (@MainActor () -> Void)? = nil) {
        self.store = store
        databaseWindow = BackgroundDatabaseWindow(isBackgrounded: isBackgrounded,
                                                  resume: resumeDatabase, suspend: suspendDatabase)
    }

    public func handle(actionIdentifier: String, taskID: String) async throws -> Outcome {
        guard actionIdentifier == ReminderAction.completeID || actionIdentifier == ReminderAction.snoozeID else {
            return .ignored
        }
        // Use the same ownership as intents, watch commands and the app lifecycle.
        return try await databaseWindow.run {
            guard let task = try await store.fetchTask(id: taskID), !task.completed, !task.isSaved else {
                return .ignored
            }
            if actionIdentifier == ReminderAction.completeID {
                try await store.toggleComplete(task)
                return .completed
            }
            try await store.snooze(task, by: .oneHour)
            return .snoozed
        }
    }
}
