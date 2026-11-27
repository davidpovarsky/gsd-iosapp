import Foundation
import Synchronization
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Cooperating processes keep this inode permanently. Never unlink it or upgrade a lease.
public final class SharedMutationLease: Sendable {
    public enum Mode: Sendable, Equatable { case shared, exclusive }
    public static let filename = "external-mutation.lock"
    private let descriptor: Mutex<Int32?>

    private init(descriptor: Int32) { self.descriptor = Mutex(descriptor) }

    /// LOCK_NB never parks MainActor or an actor needed by the current lease holder.
    /// Cancellation affects acquisition only; an acquired body owns its lease until it settles.
    public static func acquire(directory: URL?, mode: Mode,
                               timeout: Duration = .seconds(8)) async throws -> SharedMutationLease {
        try _Concurrency.Task<Never, Never>.checkCancellation()
        guard let directory else { throw SharedScopeFileError.unavailable }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(filename)
        let fd = url.path.withCString { open($0, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600)) }
        guard fd >= 0 else { throw SharedScopeFileError.unavailable }
        var transferred = false
        defer { if !transferred { close(fd) } }
        let operation = (mode == .shared ? LOCK_SH : LOCK_EX) | LOCK_NB
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            try _Concurrency.Task<Never, Never>.checkCancellation()
            if flock(fd, operation) == 0 {
                transferred = true
                return SharedMutationLease(descriptor: fd)
            }
            guard errno == EWOULDBLOCK || errno == EAGAIN else { throw SharedScopeFileError.unavailable }
            guard ContinuousClock.now < deadline else { throw SharedScopeFileError.timedOut }
            try await _Concurrency.Task.sleep(for: .milliseconds(10))
        }
    }

    public func release() {
        descriptor.withLock { fd in
            guard let owned = fd else { return }
            fd = nil
            _ = flock(owned, LOCK_UN)
            close(owned)
        }
    }

    deinit { release() }
}
