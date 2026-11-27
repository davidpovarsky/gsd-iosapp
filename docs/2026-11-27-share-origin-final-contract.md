# Share origin, retry and reset contract

The Share sheet captures one stable task ID, one immutable account/installation/dataset scope, a publication nonce, and an exact credential snapshot. Every direct POST rechecks publication and exact credentials after acquiring the shared external-write lease. A token replacement for the same owner invalidates the open sheet. A missing or inaccessible Keychain item is distinguished from a verified signed-out state. First-ever Share may queue an unpushed guest-bootstrap draft; only the main app's matching canonical guest scope may ingest it.

The sheet journals the chosen task identity and origin before attempting the POST. The lease stays held through the complete POST and durable outbox write. Recovery takes the exclusive file lease before a local mutation ticket, and the ordinary app drain validates stable origin under the same gate used by Watch, notifications and App Intents. Publication nonce invalidation controls old open sheets; it does not strand valid offline captures on a normal cold relaunch.

A creation replay with an existing live, trashed or archived ID never rewrites that canonical record or emits a new sync item. When the user changes a failed sheet submission, the session records an explicit authored-change fact. A distinct edited retry remains durable for explicit review if its ID already exists. Identical timestamps cannot erase that distinction. An empty-store retry still creates the edited payload under the same ID, preserving the original four Share retry assertions. The app never infers permission to overwrite from capturedAt/updatedAt ordering.

Saved-share detail presentation uses the verified account/dataset and observation generation captured when the item was selected. Unresolved transitions, another account, and A → unresolved → A invalidate that old detail immediately. Returning to the list allows an explicit new selection. Review clearly says that sharing to GSD creates a new task; the existing task and retained copy stay unchanged.

The permanent external-mutation.lock inode coordinates live app and extension processes. Reset closes and drains local mutation admission, asynchronously obtains the exclusive lease, durably rotates dataset identity, and only then begins destructive work. The whole account-deletion operation uses that boundary and releases it before a later local reset. Admitted app writes never acquire the file lease; no shared-to-exclusive upgrade or nested exclusive acquisition is allowed. Cancellation only aborts lease acquisition; an acquired lease is released after its operation settles.

This local ordering does not establish the fate of an HTTP operation that times out, is cancelled, or outlives a crashed process. Stable IDs/origins remain durable, and the server lane owns remote late-commit/reset ordering.

## Acceptance binding

Original Share4 and native Share2/all eight remain required. The actual-store Share16 fixture preserves the original12 assertions; extension10 preserves the original9 and adds explicit retry metadata production. Separate real-process lease/atomic-identity controls qualify the cross-process boundary. Oracle preparation and source review are not Apple execution or personal/system acceptance. Each final result must be bound to exact product, fixture, driver and dependency hashes.

The temporary GSD_SHARE_INPUT diagnostic calls and helper were removed without changing decoding branches.
