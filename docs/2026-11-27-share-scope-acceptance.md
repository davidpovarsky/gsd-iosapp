# Share origin and reset acceptance — 2026-11-27

## Approved scope

The extension sheet, durable outbox and delayed title enrichment must keep the account and dataset in which capture occurred. Legacy or unverifiable captures remain recoverable and are never silently assigned to a new account. The first-ever Share can queue an unpushed guest bootstrap; the main app must resolve the same guest installation/dataset before automatic ingest.

The final successor reuses the shared WatchAccountScope and mutation gate. A separate advisory file lease orders cooperating app/extension processes: the extension holds a shared lease through revalidation, its frozen-token POST and durable outbox write; reset/deletion closes and drains local tickets before acquiring an exclusive lease. No admitted local handler waits on that file lease. Acquisition is nonblocking with cancellable bounded waiting. The lock inode is permanent; no lock upgrades.

Dataset identity keeps the exact existing JSON codec and uses atomic load-or-create. A separate publication nonce invalidates an open sheet across A → unresolved → A, while durable outbox ownership remains account/dataset. Shared Keychain absence, inaccessible data and a valid token are distinct. Missing metadata never authorizes token-derived direct POST.

Before POST, the stable task identity and origin are journaled. Recovery acquires an exclusive file lease before local ticket admission, folds retained journals into the ordinary outbox, and releases the lease before TaskStore work. Original Share4 retry assertions remain unchanged.

A local lease cannot rule out a server commit after HTTP timeout or process death. That uncertainty keeps the task ID and origin; strict server epoch fencing is outside this client-only change.

## Actual-store regression suite

The 12 separately named checks invoke the actual inbox/drainer/title operation and actual TaskStore, GRDB and sync queue. A repository decorator suspends real reads or writes. UIKit application state is doubled. The existing fire-and-forget baseline title method exposes its original Task handle only in fixture preparation so the test can await completion; its complete async body is unchanged.

Expected baseline: current-scope create/ingest control passes; the 11 missing origin/reset/title/terminal guards fail. A compilation/setup failure is not a behavioral RED.

No original Core, original Agent, Share4 or native Share2 assertion is weakened or replaced. This standalone fixture is not native Share-sheet or live-cloud acceptance. The native owner executes both immutable RED and GREEN on Apple hardware with exact dependency pins.

## Additional extension/lease gate

A separate focused fixture will cover exact frozen credentials, unavailable Keychain, first-ever bootstrap, concurrent identity creation, publication invalidation, shared/exclusive wait ordering, cancellation/error release and crash-journal recovery. The native owner requalifies affected Watch gate and final original source suites after this shared helper changes.

## Resuming

This first commit contains only the regression fixture, driver and approved contract. Product source is unchanged from the qualified Intent/Watch baseline.
