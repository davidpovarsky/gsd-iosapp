---
name: gsd-planning
description: Use when asked to inspect or manage tasks, Eisenhower quadrants, due dates, saved views, task timers, or dashboards in the user-connected GSD Cloud account.
---

# Working with GSD Cloud

Use the authenticated GSD MCP tools to read and manage the linked user's GSD Cloud account. GSD Cloud stores account-owned data on Oracle and synchronizes it with the app's existing task store. The iPad does not need to be open for cloud operations. Never invent task details, due dates, completion status, or statistics.

Connect through GSD's normal account sign-in page using OAuth. Do not ask for a device-pairing code, device approval, API key, or GSD password in chat. A connection grants access only to that GSD account. This connection is separate from Continue with ChatGPT inside the app's Hanlin AI assistant.

For planning, use list_tasks and get_dashboard, then get_task for specific context. Carry out writes requested by the user through the tools. Claim success only when the actual tool result confirms the change. Report tool errors, conflicts, unsupported actions, or incomplete results accurately. A timeout is an unknown outcome; inspect the affected records and retain the original write intent.

Use the server's IDs, versions and time-zone data, preserve fields that the user has not requested to change, and use specific filters for large task sets. Keep credentials out of responses and logs. Cloud success does not by itself prove that a particular offline device has completed its next sync.

## Write receipts and recovery

For every write whose advertised schema includes `request_id`, create one opaque ID for the logical operation and preserve it together with the exact tool name and arguments. Retry that same intent with the same ID and unchanged arguments. Never reuse an ID for a different change, retry through another account, or replace an ID merely because a response was lost. Honor ChatGPT's required action approvals.

Treat `request_id_conflict` as an inconsistent retry. For `request_reconciliation_required` or `request_receipt_expired`, inspect the authoritative records and versions before deciding what happened. A matching title or current value alone does not prove that the original write committed. If the exposed reads cannot establish the outcome, report it as unresolved and do not submit a fresh write automatically. Report `request_ledger_capacity` without attempting to remove server receipts. Preserve partial-success details from bulk tools; never describe a partly failed batch as fully completed.
