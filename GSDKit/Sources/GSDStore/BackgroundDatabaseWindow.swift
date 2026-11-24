import Foundation

/// Owns a bounded background operation's access to the app database. Default windows share
/// one owner count with the app lifecycle. The last owner suspends only if the app is still
/// backgrounded, so overlapping intents, reminders and watch commands cannot close each
/// other's access. Catalyst callers report `false` because its database is never suspended.
@MainActor
public struct BackgroundDatabaseWindow {
    @MainActor
    private final class AccessState {
        private let resume: @MainActor () -> Void
        private let suspend: @MainActor () -> Void
        private var owners = 0
        private var resumedForBackground = false
        private var suspensionRequested = false

        init(resume: @escaping @MainActor () -> Void,
             suspend: @escaping @MainActor () -> Void) {
            self.resume = resume
            self.suspend = suspend
        }

        func begin(backgrounded: Bool) {
            owners += 1
            if backgrounded {
                resume()
                resumedForBackground = true
            }
        }

        func end(backgrounded: Bool) {
            precondition(owners > 0)
            owners -= 1
            guard owners == 0 else { return }
            let shouldSuspend = (resumedForBackground || suspensionRequested) && backgrounded
            resumedForBackground = false
            suspensionRequested = shouldSuspend
            if shouldSuspend { suspend() }
        }

        func requestSuspension() {
            suspensionRequested = true
            if owners == 0 { suspend() }
        }

        func resumeForForeground() {
            suspensionRequested = false
            resume()
        }
    }

    /// An idempotent owner for APIs with an explicit expiration callback. Ending one lease
    /// completes that operation once, even while another lease keeps the database resumed.
    @MainActor
    public final class Lease {
        public private(set) var isFinished = false
        private var onFinish: (@MainActor (Bool) -> Void)?

        fileprivate init(onFinish: @escaping @MainActor (Bool) -> Void) {
            self.onFinish = onFinish
        }

        @discardableResult
        public func finish(success: Bool = true) -> Bool {
            guard !isFinished else { return false }
            isFinished = true
            let finish = onFinish
            onFinish = nil
            finish?(success)
            return true
        }

        /// Call before and after awaited phases. Some system APIs return after expiration
        /// without honoring Task cancellation; a finished lease still rejects that work.
        public func checkCancellation() throws {
            if isFinished { throw CancellationError() }
            try _Concurrency.Task<Never, Never>.checkCancellation()
        }
    }

    private static let appDatabaseAccess = AccessState(
        resume: AppDatabase.resume, suspend: AppDatabase.suspend)

    private let isBackgrounded: @MainActor () -> Bool
    private let access: AccessState

    /// Default windows use one process-wide AppDatabase owner count. Supplying lifecycle
    /// callbacks creates an isolated scope; copies of that window retain the same scope.
    /// Tests can therefore suspend only their own DatabaseQueue, without global notifications.
    public init(isBackgrounded: @escaping @MainActor () -> Bool,
                resume: (@MainActor () -> Void)? = nil,
                suspend: (@MainActor () -> Void)? = nil) {
        self.isBackgrounded = isBackgrounded
        if resume == nil && suspend == nil {
            access = Self.appDatabaseAccess
        } else {
            access = AccessState(resume: resume ?? AppDatabase.resume,
                                 suspend: suspend ?? AppDatabase.suspend)
        }
    }

    /// Scene backgrounding requests suspension without closing an active owned operation.
    /// Its final exit, or explicit expiration, restores suspension if still backgrounded.
    public static func suspendAppDatabaseWhenIdle() {
        appDatabaseAccess.requestSuspension()
    }

    public static func resumeAppDatabaseForForeground() {
        appDatabaseAccess.resumeForForeground()
    }

    // The same lifecycle transitions on an isolated scope, used by real-queue tests.
    func suspendWhenIdle() { access.requestSuspension() }
    func resumeForForeground() { access.resumeForForeground() }

    public func begin(completion: (@MainActor (Bool) -> Void)? = nil) -> Lease {
        access.begin(backgrounded: isBackgrounded())
        return Lease { [access, isBackgrounded] success in
            access.end(backgrounded: isBackgrounded())
            completion?(success)
        }
    }

    public func run<R>(_ body: () async throws -> R) async rethrows -> R {
        let lease = begin()
        defer { lease.finish() }
        return try await body()
    }
}
