# Canonical Watch and reminder payload regressions

The peer review of host candidate 57ee1480 found two concrete asynchronous scope faults. WatchSessionCoordinator builds a valid-scope snapshot from TaskStore.tasks, whose observation can lag a database/account replacement. LiveReminderScheduler builds content from a passed Task before resolving the current account; a canceled or old ReminderResyncer loop can retain that task across awaits. A shared imported ID makes stale content appear to belong to the new account.

The regression-only checkpoint retains production d450f93df31aea01c451814f2ec4fd84161092e5 unchanged.

## Exact standalone suites

The original 27 Watch fixture source remains byte-identical. Its verified synthetic guest prerequisite is now an explicit preparation option, enabled by default only for those legacy checks. The scope suite disables the prerequisite and its API adapters; missing storage executes the unchanged production fallback to WatchSnapshot.empty.

Scope21 preserves all original18 check bodies and adds:

- missing_snapshot_starts_without_verified_origin: no snapshot file, no fabricated guest, no capture or transfer.
- phone_snapshot_uses_current_canonical_rows: old observed A row and real read seam returning B with the same ID; payload must contain B.
- phone_snapshot_revalidates_scope_after_suspended_read: scope changes while a captured A read is suspended; no obsolete payload may be published, and a fresh B read must succeed.

Reminder8 compiles the exact app scheduler, actual TaskStore, GRDB repository, ReminderMath, WatchAccountScope and WatchMutationGate. Only UserNotifications transport is a recording double; UIKit application state is a platform stub. The repository decorator suspends one actual GRDB result or injects a read error. The cases verify canonical title/body/due/scope, missing-row removal, required configured identity, cancellation, post-read scope revalidation, read-failure preservation, paused admission, and gate ownership through asynchronous notification add.

Run the immutable driver with explicit --source-root and a new --output directory on the owned Mac runner. Source hashes before/after and the exact clean GRDB revision are required. No physical Watch, personal OAuth, system notification delivery, or native target compilation success is claimed by these fixtures. No Core test identity is added or changed.

## Host correction

The phone takes an admission ticket before its canonical fetchAllTasks read, keeps the real BackgroundDatabaseWindow open, and revalidates captured account generation after that await before building/sending a valid-scope snapshot. An unresolved account still sends an immediate empty snapshot without a read.

The scheduler is configured once after canonical identity setup with a weak TaskStore reference, the same gate and the live scope provider. Its bounded Observation generation invalidates synchronously, including A → unresolved → A. Each call checks cancellation, admits, reads the canonical row by ID, and revalidates before using only that row's content and due time. Its gate/window lease spans center.add. Missing rows cancel stale requests; read failures retain them. Original reminder math, quiet hours, stable request identifier and weekly sweep behavior remain.

A separate replay2 fixture uses actual phone capture, actual Trash/archive, the actual 200-entry ledger eviction, and a newly constructed coordinator. A lost-ack capture with no live row now queries retained Trash/archive through existing TaskStore APIs under the same scope/generation. Only a matching retained stable ID proves prior application and is acknowledged. Read errors remain unacknowledged. This is bounded by retained terminal records: permanently purged history cannot prove prior application, and no title/prefix heuristic is introduced. Existing unresolved legacy follow-up behavior remains.

Original27 source and original18 scope checks remain intact; scope21, reminder8, gate8 and replay2 are separate standalone inventories. Native execution and final merged-target compilation remain required.
