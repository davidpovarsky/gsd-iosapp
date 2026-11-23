# GSD Cloud Backend (PocketBase)
Server is user-owned Oracle. Uses PocketBase 0.40+ users/tasks schema and original GSDSync REST contract.
- All task records are scoped by owner and synchronized with GSDWire/GSDSync; GSD's local GRDB remains offline cache.
- Guarded update/delete routes require exact client_updated_at and atomic transaction, per-user isolation.
- Public signup and email/password authentication supported; OAuth plugin login uses the same account.
- Database, credentials and access tokens must never be committed.
- Acceptance gates: two accounts, cross-tenant isolation, offline sync, server-side task creation while iPad shut, and app convergence.
