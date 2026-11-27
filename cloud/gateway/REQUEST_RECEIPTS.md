# Cloud write receipt contract

Cloud MCP write tools accept an optional `request_id` of 1–128 characters. A
client retries the same intent with the same ID and exactly the same arguments.
The existing native tool catalog and calls without the ID stay compatible.

An ID belongs to one authenticated GSD account. A different tool or payload with
that ID returns `request_id_conflict`. Authorization and scope checks precede
receipt lookup. Concurrent duplicate calls share the first execution. The
gateway persists and flushes an intent before contacting PocketBase, encrypts
the result using its existing AES-GCM key, and durably saves the result before
returning success. Successful receipts replay across process restarts, including
subtask toggles and task deletion.

PocketBase remains the authority for owner isolation, task transactions and
optimistic version checks. Gateway persistence and the upstream transaction are
separate. If the upstream response is lost, or the process exits with a pending
intent, a retry returns `request_reconciliation_required` without repeating the
write. Read the account state and resolve the uncertain result before submitting
a new intent. This is fail-closed retry protection, not a distributed exactly-once
transaction. Bulk writes preserve their existing partial-success semantics.

Encrypted results replay for 30 days. After that a retained fingerprint rejects
reuse with `request_receipt_expired`; an old ID is never silently treated as new.
The ledger retains up to 50,000 IDs and fails closed with
`request_ledger_capacity` when full. Capacity must be monitored and archived by
an explicit maintenance decision; deleting receipts re-enables old IDs. The last
10,000 write audit events retain only hashed account/request identifiers, tool,
status and timestamp. No task text, password or bearer token is logged.

Receipts and audit metadata reside in the existing encrypted-session state
directory and are included in `cloud/backup.py` archives together with the key.
Restore the state and PocketBase snapshot from the same verified backup. Preserve
the legacy device bridge until native migration acceptance is complete.

Acceptance covers concurrent create, restart replay, changed-payload rejection,
account isolation, nonidempotent toggle, controlled deletion, lost upstream
response, read-only scope rejection and encrypted persisted results. The focused
HTTP suite uses the real gateway and OAuth/PKCE against a controlled account
service. Deployment acceptance additionally exercises separate synthetic
accounts against the live PocketBase service.
