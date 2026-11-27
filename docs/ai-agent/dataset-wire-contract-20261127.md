# Native dataset generation wire contract — 2026-11-27

Source base: c8ae263d455c80c3aa5c9a0562e55b4992248b63.

This slice adds only the GSDWire dataset GET/reset API and an optional task-create
generation header. The server contract is the external owner’s 2026-11-27 07:29
handoff (Asana story 1220945990527264). Share and the app sync/reset journal have
separate owners.

- GET /api/gsd/dataset returns a validated opaque generation.
- POST /api/gsd/dataset/reset carries caller-owned expected_generation and
  request_id. The returned request_id must match the exact submitted UTF-8 bytes.
- X-GSD-Dataset-Generation is optional on the package createTask API. Supplying
  it requires a nonempty value of at most 128 UTF-8 bytes, with no ASCII control
  characters (0x00–0x1F or 0x7F). The same limit applies to dataset identifiers.
  Values are not trimmed, normalized, regenerated, or silently replaced.
- Existing configured base prefixes and raw PocketBase Authorization values
  are preserved. A 409 PocketBase error envelope remains a PocketBaseError;
  there is no headerless or legacy-route retry.
- Reset receipt counts must be nonnegative integers. A Codable public receipt
  can be stored by the reset journal without making GSDStore depend on GSDWire.

The test-only checkpoint introduces 16 DatasetWireTests identities without
editing any original tests. New API symbols do not exist at the base commit;
that baseline is a missing-API compile condition, not a claimed behavioral RED.
The implementation must pass the unchanged new cases and the final native Core
gate. These injected-executor tests do not prove live server idempotency,
authentication, account isolation, or erase completion.

No Apple build or test is run by this source owner. The native acceptance owner
performs execution and records exact source/dependency manifests. The parent
integrates all protocol consumers before the final full Core run.
