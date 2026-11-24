# GSD system surface discovery — exact compiled app, separate test harness

## State and scope

This is an isolated, review-only supplemental harness draft. It is not a native
acceptance result or an instruction to publish a build. The immutable app is
71b1b7ce4adf7bea2ddacfc683a69906d6acd6ae, version 4.1.0 (48), compiled and
validated by successful run 45397928701. That parent has four profiles and
13 actual passing UI cases. Its workflow head is separately pinned to
d0c5b9649a95e34aef0d4a641a28e2b7382bec0f; workflow head and app source are
deliberately distinct. The earlier failed 45380356237 is not relabeled or reused
as a successful parent.

The existing main validation and signed-release workflows are unchanged.
Only the new self-contained GSDSystemSurfaceUITests source is compiled into a
temporary projection of the existing GSDScreenshotTests UI-testing target.
There is no application target, product dependency, package or app source in
that projection. Its DerivedData is separate from the preserved app products.
All test app handles use explicit bundle IDs. Apple documents that an existing
installed app is launched when no matching build is supplied by the test target,
scheme, or test build-products directory:
https://developer.apple.com/documentation/xcuiautomation/xcuiapplication/init(bundleidentifier:).md

The first run uses one owned Hebrew iPhone simulator. It observes actual
SpringBoard, Safari and Shortcuts availability and UI, and attempts the
source-defined real text Share extension path only when observed. The purpose
is to acquire supported system interaction evidence; host discovery is not
WidgetKit, Share, Shortcuts or VoiceOver acceptance.

## Commands and provenance

Run only on the isolated reviewed harness branch, not the frozen app branch:

    python3 scripts/gsd_system_surface_discovery.py --output dist/gsd-system-surfaces

The script creates a temporary test-only XcodeGen project and invokes:

    xcodebuild build-for-testing -project <test-only-project> \
      -scheme GSDSystemSurfaces -destination 'generic/platform=iOS Simulator' \
      -derivedDataPath <separate-test-derived-data> \
      -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
      ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES

It then uses test-without-building on exactly these methods:

- GSDScreenshotTests/GSDSystemSurfaceUITests/test00RecordSystemSurfaceDiscovery
- GSDScreenshotTests/GSDSystemSurfaceUITests/test01TextShareExtensionRoundTripAndCancellation

No original 13-method UI selection or package suite can enter the projected
target. No app, extension or package build dependency is allowed. The projected
project is checked before building and the actual target plan is checked after
the test-only build.

The parent run must have its exact workflow head, attempt, workflow and successful
full receipt for the separate exact app source. Artifact IDs and hashes are fixed:

| Input | Exact identity / SHA256 |
|---|---|
| Native receipt ZIP | 14924405431 / 57b0ec55d884f40f4842acd86a7c774bdafa70820a6c37e298b47ce6d8a8d278 |
| Native receipt JSON | f099c5115a52e521e61bdcca41499326372999ff540c9dbc4df6e5b7c2164cd7 |
| Compiled products ZIP | 14921503382 / 881712bd03e5e6fd3ef0649805fc2bf661ba5fa60d6982215eb8c2018b05c209 |
| Inner compiled products ZIP | cfc50d90f996967ec968d967f56f656d128f1fe9d0d4be7d531fc72f0449428d |
| New supplemental Swift, canonical LF bytes | 79bc4cc03c5047ea4d8843e21a6a86f32e4fc2a5fa3cda3643b460e39f87ba6c |

Git ancestry and changed-path checks require this isolated harness to descend
from the actual app source with only its new test/helper/workflow and evidence
documents changed. Frozen imported helpers must equal their source blobs, and
the new Swift must equal its reviewed hash before any product restoration.
The
existing compiled-resource auditor and the same simulator entitlement parser
verify all five bundle IDs, version, App Group, runtime identities and strict
code signatures. The entire app/embedded-target file tree must match before
and after test compilation and at installed-app readback; it must remain
unchanged at final cleanup. The managed xcode-27 supplement requires and records
its own default Xcode 27.1 (27A9275) for both the new test-runner build and XCTest,
plus iOS 27.2 runtime build 24B8117. It records the resolved xcodebuild path and
DEVELOPER_DIR without changing host selection or installing an SDK.

The parent's retained logs independently show app compilation with staged
Xcode 27.1 (27A9275) and XCTest execution with that host's Xcode 27.0 (27A266a).
That parent-specific split is recorded as a provenance reference, not assumed
to describe this different managed runner. The original app is never rebuilt.

The receipt separately records app source, compiled-product run and hashes,
new harness SHA, test Swift SHA-256, projected project hash, and newly compiled
test runner tree. It never emits native-acceptance.json, a native-release
profile, or GSD_NATIVE_UI_ALL_FOUR_PASS.

## Real stores, language and safety

The app uses its normal launch, local GRDB database and App Group. No --demo
argument, in-memory task engine, account, API fixture or auth token is supplied.
Only synthetic local task text is created in the owned simulator.

The created device is checked by UUID and its reported dataPath before its
global preference file is updated to Hebrew/Israel, preserving other keys.
The booted OS language/locale are read back separately; app language arguments
alone are not evidence of OS host localization. Installed system bundle IDs
come from that same device. Raw screenshots precede uncertain accessibility
queries. Missing hosts or unknown controls stay explicitly incomplete; they
never count as passing surface coverage.

Every selected test must have a unique terminal result agreeing with xcresult.
A discovery result may finish while a real surface remains unavailable or
skipped; coverage_complete and full_acceptance remain false. An actual assertion,
crash, timeout, ambiguous result, product change or cleanup failure fails the
harness. The existing exact-mask diagnostic sanitizer runs on every exit before
artifact upload.

Before simulator creation, the unique requested name and all existing UUIDs are
recorded. An uncertain create is reconciled once by exact name, exact runtime and
a new UUID absent from that set; there is no second create or broad cleanup. A
successful create response saves its owned UUID before the following inventory
read, so a failed read does not discard ownership. An absent or ambiguous
reconciliation remains a failed, unresolved outcome.

Shutdown and delete are independent attempts on the one proven owned UUID,
including a reconciled uncertain-create outcome, followed by an inventory
proving its removal. No other simulator is modified.
Setup must finish within 2,400 seconds before UI starts; the UI command is
bounded to 1,200 seconds plus the existing 25-second termination allowance.
Summary/cleanup commands remain bounded, and the 75-minute diagnostic job
leaves headroom after the admitted UI stage. This is not a timeout extension
for any current canonical test.

## Remaining scope

shareWebURL, widgetKit, shortcuts and voiceOver are discovery-only in this
source. The helper rejects a passed status for any of those four surfaces.
Actual WidgetKit add/refresh/tap, true URL share from Safari, Shortcuts action
execution and VoiceOver focus/speech require separate functional evidence.

The accessibility status has a narrower executed meaning: the pinned Swift
sets it to passed only after the throwing sufficientElementDescription audit
returns on the actual visible Share compose host. The helper requires that exact
scope, extensionOpenedForAdd=true, discoveryOnly=false and
voiceOverFocusOrSpeechVerified=false. A later unavailable Share action may leave
the Share test skipped while this already completed scoped audit remains valid.
A full text Share pass requires all eight existing assertion bits and the actual
passing selected Share test, including its compose audit. No extra audit bit or
business/UI behavior was added. coverageComplete and full_acceptance stay false.

Watch belongs to the separate Native lane and is not repeated here.

Private owner TestFlight distribution remains governed by the unchanged full
native receipt, independent visual review, Oracle deletion proof, official
signature and App Store Connect processing gates. This supplement does not
replace any of them.

## Focused guard evidence

The original 19-control receipt remains bound to its original 29e9c4 draft;
the subsequent eight schema controls remain bound to 705ba3. Neither historical
receipt is relabeled as a test of this follow-up. New focused controls cover only
the revised fixed provenance, ownership reconciliation and honest surface-status
boundaries. They are controlled Python checks, not a simulator or Share result.
Actual supplemental execution remains pending the separate root-reviewed CI gate.

Follow-up result: **27/27 controlled checks passed** at 2026-11-24 14:05:38 UTC,
with Python syntax passing, for helper SHA256
`dcb677bb6dea2070dac1611070f3372914ff3581626ea4a23c7e0a35f4d1e783`.
The receipt is `evidence/SYSTEM_SURFACE_FOLLOWUP_CHECKS_20261124.json`.
No simulator, subprocess command, network request, account or product build ran
inside those controlled checks.
