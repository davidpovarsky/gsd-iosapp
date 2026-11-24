# Supplemental validation of final local products

## Authorized scope and acceptance

Use the final successful Mac build-for-testing products without downloading a
previous CI archive or rebuilding the application. The coordinator owns the
standard 13 native UI assertions. This separate lane owns real text Share
Add/Cancel, the native ChatGPT sign-in start/cancel before consent, and ordinary
Watch launch in English and Hebrew. No account grant or inference is performed.

The two reviewed UI classes retain their behavioral assertions and now require
a canonical 40-character source SHA from the runner. That value is provenance,
not permission: the runner must verify it against a clean source checkout and
a manifest captured immediately after the successful final build. It must
also compare app, extensions, watch and XCTest product hashes before use.

Only new, uniquely named simulator devices may be created, paired, configured,
launched or deleted. Existing devices and data must remain untouched. The
compiler is Xcode 27.1; the XCTest/simulator driver is Xcode 27.0; iOS runtime
27.2 build 24B8117 and watchOS 27.0 build 24R362 are explicit requirements.

## Checks

- Capture actual git HEAD, clean source, SDK lock digest, generated project hash,
  compiler identity and the exact product/xctestrun tree in a local manifest.
- Reject stale, modified, mismatched or incomplete products before device creation.
- Run the actual system Share extension and verify one added task survives
  relaunch; Cancel creates none, including after relaunch.
- Open the ordinary native SIWC entry, observe official browser chrome, cancel
  without credentials or web-page consent, and remain signed out after relaunch.
- Keep authentication diagnostics private and export only allowlisted facts and
  disconnected native app screenshots. Never claim consent, entitlement or inference.
- Launch the exact Watch binary in both languages and verify process liveness
  and raw screenshots. This does not prove WatchConnectivity, Siri or VoiceOver.
- Verify exact test counts, unchanged product hashes and deletion of only owned
  simulators. A failure or unknown observation never becomes a passed receipt.

## Current state

The Swift test additions are ready for the final build-for-testing. Native
execution remains pending the coordinator's single Mac slot and final manifest.

## Local runner contract

`gsd_local_supplemental_validation.py` has two explicit modes. The build owner
runs `capture` immediately after its successful final `build-for-testing`, while
the source checkout is still unchanged. The original build exit code must be
passed, not inferred from a later command. The capture binds the actual source
SHA, SDK lock, generated project, successful build log, full product tree, five
embedded bundles, test source files and the sole xctestrun. It checks the
observed Xcode `__TESTROOT__` and `__TESTHOST__` paths remain inside Products.
Generated Xcode project files and App/Info.plist are the only permitted dirty
source paths; ignored build outputs do not count as source.

```sh
/opt/homebrew/bin/python3.12 -B scripts/gsd_local_supplemental_validation.py capture \
  --repo "$PWD" --products "$GSD_DERIVED_DATA/Build/Products" \
  --build-log "$GSD_OUTPUT/logs/build-for-testing.log" \
  --build-exit-code "$GSD_BUILD_EXIT_CODE" --build "$GSD_BUILD_NUMBER" \
  --compile-developer-dir "$GSD_COMPILE_DEVELOPER_DIR" \
  --output "$GSD_OUTPUT/local-products.json"

/opt/homebrew/bin/python3.12 -B scripts/gsd_local_supplemental_validation.py run \
  --repo "$PWD" --manifest "$GSD_OUTPUT/local-products.json" \
  --compile-developer-dir "$GSD_COMPILE_DEVELOPER_DIR" \
  --driver-developer-dir "$GSD_DRIVER_DEVELOPER_DIR" \
  --output "$GSD_OUTPUT/supplemental"
```

Use the verified Mac Python 3.12 executable above; its system Python is 3.9.
When invoking scripts through a wrapper, prepend
`/opt/homebrew/opt/python@3.12/libexec/bin:/opt/homebrew/bin` to PATH.
The runner disables bytecode writes so its own imports do not dirty the source.

The coordinator supplies the already verified absolute Xcode developer
directories; no global xcode-select change is made. `run` defaults to share,
preconsent and watch in order. An explicit `--suite` may select one bounded
probe when a prior result is invalidated. Each UI probe reuses the captured
xctestrun and requires the exact selected test count with no skipped or failed
tests. No product is rebuilt, resigned or downloaded by this runner.

Each lane removes its owned devices before the next lane starts. Watch uses the
explicit iOS/watchOS runtime pair and requires simctl pairing readback; an
unavailable or incompatible pair is an incomplete result, not a fallback to
unrecorded runtimes. All raw authentication logs and xcresults remain inside
the mode-0700 private directory. The public subdirectory contains only the
allowlisted receipt, native disconnected-state screenshots and Watch captures.
The whole output remains local; no automatic publication or upload occurs.

## Portable guard verification

`python3 scripts/test_gsd_local_supplemental_validation.py` passes 11 cases.
Coverage includes dirty/untracked source, mutated or symlinked products,
xctestrun path escape and the actual observed TestHost placeholder, exact test
counts, incomplete Share assertions, unproven consent/secret-bearing receipt
fields, pre-existing simulator exclusion, exact runtime builds and source/SDK
identity. These tests validate the harness; native acceptance remains pending
the final Mac execution and its receipts.
