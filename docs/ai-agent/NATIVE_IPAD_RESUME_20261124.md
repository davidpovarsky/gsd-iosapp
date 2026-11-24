# Exact-source iPad acceptance recovery

This harness resumes the two missing iPad profiles from run
https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45343781703 .
The application and compiled UI tests remain at
`37764f1a56a0678e5c4cb4cbd683ab3f44eb2fdc`, GSD 4.1.0 (48).
The workflow harness commit is recorded separately. No product, Swift test,
dependency, build setting, provisioning profile or release gate changes.

## Preserved evidence and interruption

The parent job passed its immutable-source/Xcode check, 13 session-observation
cases, eight connectivity cases, seven Hanlin XCTest cases, 13 official ChatGPT
contract cases, timer 3, cloud/sync 94, library 4, deletion/recovery 18, the full
five-target simulator build, localization audit and runtime entitlement audit.
Both current iPhone profiles passed all three selected tests; retained summaries,
per-test terminal markers and successful cleanup agree. Current phone images and
geometry were independently reviewed.

The parent was cancelled at 07:36:50 UTC during iPad EN after its simulator boot.
There is no observed iPad test result, screenshot, or explicit simctl shutdown or
delete result. HE iPad was never entered by the sequential runner, so its native
signup/cloud/deletion fixture does not exist. The cancellation actor and cause
remain unknown. No native-owner cancellation or retry was issued.

GitHub job/check metadata identifies hosted runner 1000025605, group GitHub Actions,
image xcode-27-arm64/MacCloud. Its completed job log records termination of the
orphan xcodebuild process. Generic hosted-runner documentation is context only:
https://docs.github.com/en/actions/reference/runners/github-hosted-runners .
Historical simctl cleanup and VM disposal remain unobserved; the documentation
is not a per-job lifecycle receipt. The old
UUID 19670EF8-3F9F-4208-A0DF-241D4842AA04 is never targeted on another runner.
Fresh recovery profiles must complete their own checked cleanup successfully.

## Fixed provenance contract

The helper accepts only that exact source, build, parent run/attempt, native job,
three artifact IDs and their reviewed SHA-256 values. It checks the parent's
successful gate names/outcomes and cancelled UI outcome, then verifies every
downloaded artifact file against a pinned whole-file-tree digest and count.
The preserved Products ZIP is independently checked against its inner hash and
manifest, constrained paths and entry/expanded-size limits.

| Artifact | ID | GitHub archive SHA-256 |
| --- | --- | --- |
| Native evidence | 14898584445 | 483af6eb599df092919fafdea691ada6419967a9f0f1d3bb60f0be639e0047e9 |
| Compiled products | 14897632059 | 0396371b6530b09d0d405df887291f248193813e58986f734a58b11bb87749c5 |
| Generated project | 14898449718 | ad039051907ef0b84eb3c7bd8dc5b8635fefee539bbe2c422509baa0dc5a8961 |

Inner Products ZIP SHA-256:
`14cd82477fd8956d9d4f173ee98aa10d26244857f1b5fd8b73a23ad4c1c6be9b`.
Generated project SHA-256:
`c2b6eac9e7526b9a07f46f4d4820b1eaaae20a024c5f0ec0742115fc5807cc10`.

The full current toolchain must be exactly `Xcode 27.1 / Build version 27A9275`.
The parent full job log reported both lines at 06:53:23 UTC, and its retained build
log has a unique compiler `--xcode-version 27A9275`. All five GSD targets and the
compiled screenshot-test bundle independently carry that same DTXcodeBuild.
Apple's prebuilt XCTest runner wrapper carries 27A9272; its original bytes are
preserved, audited and recorded rather than falsely attributed to recompilation.
The same installed iOS 27.2 / 24B8117 runtime is required. `ditto` restores executable
permissions, and strict/deep signatures plus compiled versions/localizations are
checked before either iPad runs. No install of the SDK or build is performed.

## Partial execution and complete receipt

`gsd_native_acceptance.py --family iPad` selects the existing three tests on
English iPad and the same three plus the existing live account lifecycle test on
Hebrew iPad. It uses the unchanged compiled UI runner and original XCTest test
names. It performs no phone test or package suite. The family-only receipt always
has `passed:false`, profile `native-release-partial`, and distinct subset markers;
it cannot authorize release by itself. Failure, cancellation, missing tests or
cleanup failure leaves the whole acceptance incomplete.

Only the fixed-parent composer can combine verified parent phone 6 with newly
verified iPad 7 into the existing full `native-release` schema. It requires four
unique device/language profiles, all 13 selected tests passed once, zero skipped
or expected failures, matching xcresult summaries, both fresh cleanup logs, and
the precise HE-iPad public deletion owner marker. Each profile records its actual
evidence run and common compiled-source SHA. The parent remains explicitly
cancelled; only its completed gates and phones are inherited. The new successful
workflow run is the composed receipt's run ID, with the original product run and
SHA retained separately.

The existing signed-release job is unchanged. It still requires a successful
same-workflow validation run, exact app source/build, complete four-profile
receipt and the named HE-iPad cloud test. It regenerates and compares the project
and SDK lock before a real Apple Distribution Archive/export/upload. Root's
independent current-image review and Oracle users/tasks/library 0,0,0 read remain
required before dispatching that release. Personal ChatGPT consent, physical
installation and system WidgetKit/Siri/VoiceOver coverage are not inferred.

## Dispatch after review

Dispatch the registered native workflow on the reviewed isolated harness branch,
mode `resume-native`, source_ref `37764f1a56a0678e5c4cb4cbd683ab3f44eb2fdc`, build 48.
The checkout is the immutable harness commit; app source and parent are fixed by
the helper. The current-source code branch remains frozen. Fresh active-run
inventory and root dispatch clearance precede the single recovery run.

This document records a reviewed recovery design, not an executed iPad PASS.
