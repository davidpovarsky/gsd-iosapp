# Share process lease and atomic identity qualification

Seven standalone controls execute the actual SharedMutationLease, SharedDatasetIdentityStore and WatchMutationGate implementations. The runner launches separate copies of its native executable, with at most eight small child processes at once. All files are created in owned temporary directories; no personal credentials, task dataset or network request is used.

The checks require: simultaneous shared leases; an exclusive reset that leaves MainActor responsive and waits for both shared holders; an independently running Share lease that blocks dataset rotation and the destructive marker; cancellation before admission; release after a throwing body; eight simultaneous first creators choosing exactly one persistent identity; preservation of corrupt/legacy identity bytes; and automatic OS lease release after an owned child process dies. Related assertions are grouped into seven exact case identities in the driver.

The lock inode must remain unchanged. Parent cleanup terminates only Process objects created by this fixture. Lease waits use the actual nonblocking asynchronous production API. These checks qualify process coordination and persistence ordering; actual TaskStore mutation/drain behavior remains covered by the separate gate8 and Share16 fixtures.

This is not proof of remote HTTP ordering after a timeout or crashed process. The receipt explicitly leaves remoteLateCommitOrderingAcceptance and nativeShareSheetAcceptance false.

Only the native acceptance owner compiles or executes the Swift fixture. Oracle prepare-only output is a source manifest and packaging check, not acceptance. Preserve every prior output; require exactly the seven unique identities, no missing/duplicate checks, and unchanged source hashes before and after execution.
