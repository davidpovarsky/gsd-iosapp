# Watch binary smoke — bounded additional acceptance

The auxiliary `watch-smoke` workflow mode requires a **completed, successful**
native acceptance run and uses the compiled artifact bound to its accepted app
source. It does not compile the app, rerun its package/UI suites, or modify
product source.

Run this mode from the isolated harness branch. The checkout is the workflow's
own immutable `github.sha`, because the accepted app source predates this
auxiliary script. The receipt records the harness commit/run separately from the
accepted app commit/run, compiled ZIP digest, executable digests, and bundle IDs.

Before installing anything, the script checks the successful full native receipt,
all four EN/HE iPhone/iPad results and the required HE-iPad cloud test; it rejects
partial or failed parent acceptance. It checks the compiled-product manifest,
archive digest and safe paths, simulator platforms, version/build, Watch companion
identity, and strict/deep signatures. The reused simulator helper must be byte
identical to the helper in the accepted app commit.

The smoke creates one new compatible iPhone/Watch simulator pair, reads the
pairing back, installs the original products, and launches normally in English
and Hebrew. Only standard Apple language/locale arguments are passed. Each Watch
PID must still match its executable after five seconds. Screenshots are raw
`simctl io screenshot` PNGs with pixel dimensions and SHA-256 in separate
geometry records. Actual image review is required and remains marked pending
until a person or visual-review agent inspects those images.

Cleanup attempts both newly created devices, verifies that neither remains, and
fails the receipt if cleanup fails. Existing devices and pairs are never selected
for shutdown, erasure, unpairing or deletion.

This supplies Watch process launch, short liveness and visible localization
evidence only. It does not establish WatchConnectivity, watch task delivery,
complication/widget timelines, Share Extension, Siri, VoiceOver or physical-device
operation. The signed iOS release continues to use its original strict native
receipt and original source SHA. Watch smoke may run alongside its Archive only
after that receipt, screenshot review and the disposable-account zero-row check
have passed.

## Composed acceptance for the interrupted GSD48 run

The ordinary path continues to require validation head equal to app source and
products from that same successful run. One explicit reviewed recovery is also
supported: app source `37764f1a56a0678e5c4cb4cbd683ab3f44eb2fdc`, validation harness
`c9ee902768fcbf5828d9cfc436e0b739b9ae8a6d`, original compiled-product run
`45343781703`. The successful validation run's head must equal the receipt's
`harness_sha`; its full four-profile, 13-test composition and per-profile source
and evidence-run bindings must pass. A running, failed, cancelled or partial
recovery does not authorize Watch execution.

Only then may the script read `compiled_product_run_id` from that verified receipt.
It accepts exactly product artifact `14897632059`, outer SHA-256
`0396371b6530b09d0d405df887291f248193813e58986f734a58b11bb87749c5`, and inner ZIP SHA-256
`14cd82477fd8956d9d4f173ee98aa10d26244857f1b5fd8b73a23ad4c1c6be9b`.
The original parent remains explicitly cancelled; it is the source of compiled
bytes and completed phone evidence, while the separate successful composed run
supplies the completed acceptance. Both run IDs, the validation harness commit,
the app commit and the Watch harness commit remain distinct in the new receipt.
The existing signature, platform, pairing, liveness and owned-device cleanup
checks remain unchanged. Root's image review and Oracle zero-row read are still
required before dispatch, and no physical device result is inferred.

This compatibility path is prepared for review; no Watch runtime PASS is claimed.
