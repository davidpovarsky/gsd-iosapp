import Foundation
import os
import GSDModel
import GSDSnapshot
import GSDStore
import UIKit

/// Notification requests retain their scheduled account and dataset. They never inherit the
/// account that happens to be active when a cold launch or an earlier action finally finishes.
@MainActor
enum ReminderActionInbox {
    private struct Pending {
        let action: String
        let taskID: String
        let scope: WatchAccountScope
        let done: () -> Void
    }

    @MainActor private final class Context {
        let store: TaskStore
        let handler: ReminderActionHandler
        let mutationGate: WatchMutationGate
        let scopeProvider: @MainActor () -> WatchAccountScope?

        init(store: TaskStore, mutationGate: WatchMutationGate,
             scopeProvider: @escaping @MainActor () -> WatchAccountScope?) {
            self.store = store
            self.handler = ReminderActionHandler(store: store, isBackgrounded: ReminderActionInbox.isBackgrounded)
            self.mutationGate = mutationGate
            self.scopeProvider = scopeProvider
        }
    }

    /// Separate from user-authored URLs: a delayed reminder must carry its original scope.
    struct OpenRequest: Codable, Equatable, Sendable {
        let id: UUID
        let taskID: String
        let scope: WatchAccountScope
    }

    static let openNotification = Notification.Name("gsdOpenScopedReminderTask")
    private static let pendingOpenKey = "pendingScopedReminderTask.v1"
    private static let log = Logger(subsystem: "com.itorah.gsd", category: "reminder-actions")
    private static var context: Context?
    private static var waiting: [Pending] = []
    private static var lastAction: _Concurrency.Task<Void, Never>?

    static func attach(store: TaskStore, mutationGate: WatchMutationGate,
                       scopeProvider: @escaping @MainActor () -> WatchAccountScope?) {
        context = Context(store: store, mutationGate: mutationGate, scopeProvider: scopeProvider)
        let queued = waiting
        waiting.removeAll()
        queued.forEach(run)
    }

    private static func isBackgrounded() -> Bool {
        #if targetEnvironment(macCatalyst)
        false
        #else
        UIApplication.shared.applicationState != .active
        #endif
    }

    static func deliver(action: String, taskID: String, scope: WatchAccountScope?,
                        done: @escaping () -> Void) {
        guard let scope, scope.isValid, !taskID.isEmpty else {
            done()
            return
        }
        let item = Pending(action: action, taskID: taskID, scope: scope, done: done)
        if context == nil { waiting.append(item) } else { run(item) }
    }

    private static func run(_ item: Pending) {
        let previous = lastAction
        lastAction = _Concurrency.Task { @MainActor in
            await previous?.value
            defer { item.done() }
            // Read the live attachment and scope after the serial wait, not before it.
            guard let context, isCurrent(item.scope, in: context),
                  let ticket = context.mutationGate.admit() else { return }
            defer { context.mutationGate.finish(ticket) }
            do {
                // The ticket spans the handler's internal fetch, queue and repository awaits.
                _ = try await context.handler.handle(actionIdentifier: item.action, taskID: item.taskID)
            } catch {
                log.error("Reminder action \(item.action, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @discardableResult
    static func requestOpen(taskID: String, scope: WatchAccountScope?,
                            defaults: UserDefaults = AppGroupDefaults.shared) -> OpenRequest? {
        guard let scope, scope.isValid, !taskID.isEmpty else { return nil }
        let request = OpenRequest(id: UUID(), taskID: taskID, scope: scope)
        guard let data = try? JSONEncoder().encode(request) else { return nil }
        defaults.set(data, forKey: pendingOpenKey)
        NotificationCenter.default.post(name: openNotification, object: request.id)
        return request
    }

    /// Consume once, including a cold-launch fallback. A late live delivery cannot clear a
    /// newer request. Invalid/legacy records are refused instead of acquiring the current scope.
    static func consumePendingOpen(matching id: UUID? = nil,
                                   defaults: UserDefaults = AppGroupDefaults.shared) -> OpenRequest? {
        guard let data = defaults.data(forKey: pendingOpenKey) else { return nil }
        guard let request = try? JSONDecoder().decode(OpenRequest.self, from: data),
              request.scope.isValid, !request.taskID.isEmpty else {
            defaults.removeObject(forKey: pendingOpenKey)
            return nil
        }
        guard id == nil || request.id == id else { return nil }
        defaults.removeObject(forKey: pendingOpenKey)
        return request
    }

    /// Keep admission through the actual read and the synchronous presentation decision.
    /// Returning an unscoped task for a caller to present after another await would reopen
    /// the account-switch race, so the presentation callback runs inside this lease.
    @discardableResult
    static func resolveOpen(_ request: OpenRequest,
                            present: @MainActor (GSDModel.Task) -> Void) async -> Bool {
        guard let context, isCurrent(request.scope, in: context),
              let ticket = context.mutationGate.admit() else { return false }
        defer { context.mutationGate.finish(ticket) }
        let databaseLease = BackgroundDatabaseWindow(isBackgrounded: isBackgrounded).begin()
        defer { databaseLease.finish() }
        #if !targetEnvironment(macCatalyst)
        if !isBackgrounded() {
            BackgroundDatabaseWindow.resumeAppDatabaseForForeground()
        }
        #endif
        do {
            guard let task = try await context.store.fetchTask(id: request.taskID),
                  isCurrent(request.scope, in: context),
                  !_Concurrency.Task<Never, Never>.isCancelled else { return false }
            present(task)
            return true
        } catch {
            log.error("Reminder task could not be opened: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static func isCurrent(_ scope: WatchAccountScope, in candidate: Context) -> Bool {
        context === candidate && scope.isValid && !candidate.mutationGate.isPaused
            && scope.datasetID == candidate.mutationGate.identity?.datasetID
            && candidate.scopeProvider() == scope
    }
}
