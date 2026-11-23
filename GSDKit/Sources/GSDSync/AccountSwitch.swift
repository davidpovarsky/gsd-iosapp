import Foundation

/// Pure decision for the cross-account guard (design 2026-06-10 Fix C): the §7.4 first-sync
/// seed would silently upload the PREVIOUS account's local tasks into a DIFFERENT account —
/// that needs explicit user consent. `public` — the App's SessionStore routes on it.
public enum AccountSwitch {
    public enum Decision: Equatable, Sendable { case proceed, prompt }

    /// `.prompt` only when a previous owner is known, the new owner differs, and there are
    /// local account data to upload. The caller includes active tasks, archives, trash and custom views.
    /// First-ever sign-in (no recorded owner) and same-account
    /// re-auth keep today's behavior.
    public static func evaluate(lastOwnerId: String?, newOwnerId: String,
                                hasLocalActiveTasks: Bool) -> Decision {
        guard let lastOwnerId, lastOwnerId != newOwnerId, hasLocalActiveTasks else { return .proceed }
        return .prompt
    }
}
