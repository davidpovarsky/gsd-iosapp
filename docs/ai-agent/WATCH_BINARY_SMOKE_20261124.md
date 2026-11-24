# Watch binary smoke — bounded additional acceptance

The auxiliary `watch-smoke` workflow mode uses the already compiled simulator
artifact from a **completed, successful** native acceptance run. It does not
compile the app, rerun its package/UI suites, or modify product source.

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
