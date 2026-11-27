import Foundation
import Synchronization
import Observation
import UIKit
import UserNotifications
import GSDModel
import GSDStore
import GSDSnapshot

/// The live `ReminderScheduling` implementation (product spec §9). Lives in the App target —
/// the only layer that imports `UserNotifications`. Owns the scheduling math (`ReminderMath` +
/// quiet hours), reads `NotificationSettings` via an injected closure (so it needn't reach into
/// the store's internals), and uses the stable id `task-<id>` so a reschedule REPLACES rather
/// than stacks. `@unchecked Sendable`: `UNUserNotificationCenter.current()` is a thread-safe
/// singleton and injected closures are `@Sendable`; the once-bound actor context uses a Mutex.
final class LiveReminderScheduler: ReminderScheduling, @unchecked Sendable {
    private let center = UNUserNotificationCenter.current()
    private let settingsProvider: @Sendable () -> NotificationSettings
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    // SessionStore depends on TaskStore, which depends on this scheduler. GSDApp installs
    // the required context once, after construction and before any reminder operation.
    // The context holds the store weakly so the TaskStore -> scheduler relationship is not a cycle.
    private let scopeContext = Mutex<ScopeContext?>(nil)

    @MainActor
    private final class ScopeContext {
        weak var store: TaskStore?
        let mutationGate: WatchMutationGate
        let scopeProvider: @MainActor @Sendable () -> WatchAccountScope?
        private var observedScope: WatchAccountScope?
        private var scopeIsStable = false
        private(set) var generation: UInt64 = 0

        let databaseWindow = BackgroundDatabaseWindow(isBackgrounded: {
            #if targetEnvironment(macCatalyst)
            false
            #else
            UIApplication.shared.applicationState != .active
            #endif
        })

        init(store: TaskStore, mutationGate: WatchMutationGate,
             scopeProvider: @escaping @MainActor @Sendable () -> WatchAccountScope?) {
            self.store = store
            self.mutationGate = mutationGate
            self.scopeProvider = scopeProvider
            observeScope()
        }

        private func readScope() -> WatchAccountScope? {
            guard !mutationGate.isPaused, let dataset = mutationGate.identity?.datasetID,
                  let scope = scopeProvider(), scope.isValid, scope.datasetID == dataset else { return nil }
            return scope
        }

        var currentScope: WatchAccountScope? {
            guard scopeIsStable, let scope = readScope(), scope == observedScope else { return nil }
            return scope
        }

        func isCurrent(_ scope: WatchAccountScope, generation: UInt64) -> Bool {
            !_Concurrency.Task.isCancelled && generation == self.generation && currentScope == scope
        }

        private func observeScope() {
            observedScope = withObservationTracking {
                readScope()
            } onChange: { [weak self] in
                // All tracked inputs belong to the MainActor gate and canonical SessionStore.
                MainActor.assumeIsolated { self?.invalidateScope() }
            }
            scopeIsStable = true
        }

        private func invalidateScope() {
            generation &+= 1
            scopeIsStable = false
            _Concurrency.Task { @MainActor [weak self] in self?.observeScope() }
        }
    }

    init(settingsProvider: @escaping @Sendable () -> NotificationSettings,
         calendar: Calendar = .current,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.settingsProvider = settingsProvider
        self.calendar = calendar
        self.now = now
    }

    @MainActor
    func configureScope(store: TaskStore, mutationGate: WatchMutationGate,
                        scopeProvider: @escaping @MainActor @Sendable () -> WatchAccountScope?) {
        let context = ScopeContext(store: store, mutationGate: mutationGate, scopeProvider: scopeProvider)
        scopeContext.withLock { current in
            precondition(current == nil, "Reminder scope is installed once during app construction")
            current = context
        }
    }

    func schedule(_ task: Task) async {
        guard !_Concurrency.Task.isCancelled, let context = scopeContext.withLock({ $0 }) else { return }
        await schedule(taskID: task.id, context: context)
    }

    @MainActor
    private func schedule(taskID: String, context: ScopeContext) async {
        guard !_Concurrency.Task.isCancelled, let store = context.store else { return }
        guard let scope = context.currentScope, let ticket = context.mutationGate.admit() else { return }
        let generation = context.generation
        defer { context.mutationGate.finish(ticket) }
        await context.databaseWindow.run {
            guard context.isCurrent(scope, generation: generation) else { return }
            let canonical: Task?
            do { canonical = try await store.fetchTask(id: taskID) }
            catch { return } // a failed read must not remove a previously scheduled reminder
            guard context.isCurrent(scope, generation: generation) else { return }
            guard let canonical else {
                center.removePendingNotificationRequests(withIdentifiers: [identifier(for: taskID)])
                return
            }
            // The passed Task may belong to an older resync/account. Only the canonical row
            // read inside this identity lease supplies notification content and timing.
            await scheduleCanonical(canonical, scope: scope)
        }
    }

    @MainActor
    private func scheduleCanonical(_ task: Task, scope: WatchAccountScope) async {
        let id = identifier(for: task.id)
        guard !task.isSaved else {
            center.removePendingNotificationRequests(withIdentifiers: [id])
            return
        }
        let settings = settingsProvider()
        let inputs = ReminderMath.Inputs(masterEnabled: settings.enabled, defaultReminder: settings.defaultReminder)
        guard let deferred = ReminderMath.nextFire(for: task, inputs: inputs,
                                                   quietStart: settings.quietHoursStart,
                                                   quietEnd: settings.quietHoursEnd,
                                                   now: now(), calendar: calendar) else {
            // Nothing to fire → ensure no stale pending request lingers.
            center.removePendingNotificationRequests(withIdentifiers: [id])
            return
        }

        let content = UNMutableNotificationContent()
        content.title = task.title
        if !task.description.isEmpty { content.body = task.description }
        content.sound = settings.soundEnabled ? .default : nil
        content.userInfo = ["taskID": task.id]
        guard let value = scope.notificationValue else { return }
        content.userInfo[WatchAccountScope.notificationKey] = value
        content.categoryIdentifier = ReminderAction.categoryID

        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: deferred)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

        // Replace any existing pending request for this id, then add.
        center.removePendingNotificationRequests(withIdentifiers: [id])
        do { try await center.add(request) } catch { /* delivery is best-effort; ignore add failure */ }
    }

    func cancel(taskID: String) async {
        center.removePendingNotificationRequests(withIdentifiers: [identifier(for: taskID)])
    }

    func cancelAll() async {
        center.removeAllPendingNotificationRequests()
    }

    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool {
        let current = await center.notificationSettings()
        switch current.authorizationStatus {
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            return granted
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    /// The weekly sweep reminder (spec-weekly-sweep section 6): one repeating calendar trigger from the
    /// stored setting. Fixed words, no count, no task content. It fires whether or not cards exist,
    /// and quiet hours don't defer it because the user picked the time.
    func rescheduleSweepReminder() async {
        let id = Self.sweepIdentifier
        center.removePendingNotificationRequests(withIdentifiers: [id])
        let reminder = WeeklySweepSettings.reminder()
        guard reminder.enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = NSString.localizedUserNotificationString(forKey: "Weekly sweep", arguments: nil)
        content.body = NSString.localizedUserNotificationString(forKey: "A few minutes to clear what’s gone quiet.", arguments: nil)
        content.sound = settingsProvider().soundEnabled ? .default : nil
        var when = DateComponents()
        when.weekday = reminder.calendarWeekday
        when.hour = reminder.hour
        when.minute = reminder.minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: when, repeats: true)
        do { try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger)) }
        catch { /* delivery is best-effort; ignore add failure */ }
    }

    static let sweepIdentifier = "weekly-sweep"

    func setBadge(_ count: Int) async {
        try? await center.setBadgeCount(count)
    }

    private func identifier(for taskID: String) -> String { "task-\(taskID)" }
}
