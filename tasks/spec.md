# Saved on iOS

## Goal and authority

Implement the approved Saved behavior from the web app and the owner's request
for the iOS follow-up: short notes, return to matrix and bidirectional web sync.
The approved design covers this spec, plan and implementation in one pass.

## Inputs and outputs

- Add optional `Task.savedAt: Date?`, persisted on existing task rows and carried
  as `savedAt` in backups and `saved_at` in PocketBase. Missing means active;
  return writes an empty wire string to clear placement remotely.
- Move an incomplete task to Saved with its identity, notes, dates, flags, tags,
  subtasks, recurrence and dependencies intact. Reject a running timer.
- Expose Saved in iPhone Browse and the regular-width Library sidebar. Search
  titles and notes, edit short notes in the existing description (600 UTF-16
  units, matching web), and return after reviewing quadrant and optional date.
- Keep Saved outside the matrix, active smart views, analytics, widgets, badges,
  reminders, Spotlight active suggestions and active App Intent results. Retain
  the full stored graph for dependency checks, backup, reset/import and sync.

## Constraints and edge cases

- Offline-first; sync remains optional. No new backend schema or production
  mutations. The deployed additive Saved field is already available.
- Save and return are placement transitions, never completion or deletion; no
  recurrence is spawned. Completion and timers require return to matrix first.
- Read current stored state before transitions and note writes. Do not resurrect
  deleted rows or overwrite unrelated edits made through web sync. Ordinary edits
  must retain current Saved placement. Handle stale editors and remote returns.
- Preserve Saved in trash/restore and JSON round trips. Migrate existing local
  data without changing records. Saved prerequisites continue to block work.
- Use existing SwiftUI navigation, colors, typography, error handling and isolated
  demo/test infrastructure. Respect Dynamic Type, Reduce Motion and VoiceOver.

## Out of scope

Long-form notes, new organization systems, Android changes, App Store upload,
production data probes and unrelated refactors.

## Acceptance criteria and test stubs

1. Legacy tasks and databases migrate as active; saved tasks survive restart,
   backup, restore and trash. Model/store/migration/backup tests.
2. Saving and returning preserve context and enqueue the corresponding sync
   payload; invalid/stale actions fail safely. Store transition and timer tests.
3. Native notes obey the web limit and change only description on the latest
   row. Empty, Unicode, over-limit and concurrent-edit tests.
4. Active surfaces omit Saved; dependency checks retain Saved prerequisites.
   Filter, analytics, reminder, widget and mutation tests.
5. Web wire payload -> iOS pull -> native notes/return -> outgoing web-compatible
   payload retains identity and placement. Mapper, pull/push and cross-client
   fixture tests, plus a disposable local PocketBase round trip where available.
6. A native UI walk saves a task, edits notes, finds it, returns it to the selected
   quadrant and observes the same identity. Verify iPhone/iPad light and dark,
   compile Mac Catalyst, and capture fresh simulator evidence.

## Task workspace extension — 2026-11-25

Authorized by the owner's current request to plan, implement, integrate and deliver both apps to TestFlight. This is a non-trivial UI/host integration; the parent coordinator owns shared-kit implementation, native verification, branch integration and releases.

Goal: show and edit the existing GSD tasks in interactive graph, quadrant board, due-date timeline, dependency network and table views. The same native view must be reachable from app navigation and Hanlin tool results.

Input/output: existing TaskStore snapshots and stable task IDs; all changes call TaskStore's mutation methods. A read-only show_task_workspace tool validates its mode and selected IDs and supplies presentation intent. Explicit selections include prerequisite closure. Omitted IDs mean all current matrix tasks, including future additions. Saved prerequisites remain visible and read-only; their actual state still blocks dependents.

Constraints: no second task database; no model or sync migration; no copied upstream source; external SwiftPM package pinned to a revision; preserve existing tab indices and adaptive-navigation continuity; English/Hebrew labels. GSD's recurrence parentTaskId is not a dependency or a hierarchy. The board moves tasks between real quadrants. No fabricated in-progress status or planned/start date.

Edge cases: missing or deleted selections; cycle/self/missing dependency rejection; Saved references; duplicate selections; empty databases; action failures; concurrent updates; successful completion followed by recurrence; due-date edits preserve other fields.

Acceptance:
- Workspace opens on iPhone and iPad and carries through compact/regular transitions.
- Open/create uses the normal editor. Completion, quadrant moves, due edits and dependencies persist through TaskStore and enqueue through the existing sync path.
- References preserve true blocking state; selected graph is live after later mutations.
- Hanlin can request any supported presentation; failed or invalid tools do not replace a successful workspace with fabricated data.
- Focused unit tests verify selector semantics and actual repository mutations; a simulator UI flow opens workspace, completes a real seeded task, verifies completion in an alternate view, and opens the normal editor.
- Root runner must compile, run the declared tests and native UI acceptance before release. No build/upload is claimed by this source implementation lane.

Out of scope for this lane: shared TaskVisualizationKit implementation, production account changes, build-number allocation, SDK update and TestFlight publication (owned by coordinator).
