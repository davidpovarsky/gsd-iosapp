# GSD 4.1.0 (48): native and Apple release gate

## Scope and current evidence

This lane began from cloud checkpoint 86794659ad55ad18033a0f8368fee114a2c97c0b in the isolated branch feat/gsd-apple-release-20261123. Existing native/Hanlin acceptance run [45119548923](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45119548923) remains prior-release evidence; it does not validate the new account/sync/localization/ChatGPT changes.

Preparation completed:

- The five GSD bundle IDs have been created in the actual owner's team, with APP_GROUPS capability enabled. Public resource IDs and verification facts are in GSD_APPLE_PROVISIONING_20261123.json.
- The source team 52HVJ3VDSM was stale. The existing, verified Lorvex App Store profile and Apple Distribution certificate both belong to David Povarsky's team NA6HPWARQ2. The user-authorized existing owner signing route is reused; no Apple certificate was revoked or replaced.
- Six GitHub secret names are provisioned: APPLE_CERTIFICATE_P12_B64, APPLE_CERTIFICATE_PASSWORD, APPLE_TEAM_ID, ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8. Values and private files are absent from the repository and public receipts.
- XcodeGen source declares English/Hebrew in all five target Info.plists, enables string catalogs, references the original pinned Hanlin SDK, and gives every Release target its own manual App Store profile.
- The Catalyst sandbox permits the local OAuth callback listener used by the official ChatGPT authentication integration.
- The ten portable artifact/profile rejection tests passed on Windows. The new UI test source passed Swift frontend syntax parsing. These are not Xcode compilation or simulator-runtime evidence.

Remaining portal prerequisites are deliberately enforced by the release scripts: associate group.com.itorah.gsd with all five App IDs, create the App Store Connect app record for com.itorah.gsd, and create/verify the five corresponding App Store profiles. A build-number preflight checks Apple before archiving. A signed IPA or TestFlight availability has not yet been established by this preparation commit.

## Single native CI workflow

Use the existing registered workflow .github/workflows/gsd-hanlin-agent-ios.yml with an exact integrated 40-character source SHA. There are two explicit workflow_dispatch modes.

### validate

1. Verify the source commit and Xcode 27.
2. Check the public cloud endpoint.
3. Run the canonical Hanlin SDK installer and its integrity check.
4. Generate Xcode targets and assert English/Hebrew/Base regions.
5. Run the complete GSDHanlinAgent consumer suite, including the new official ChatGPT contract tests.
6. Run focused account/sync/cloud system tests in GSDKit.
7. Build the universal simulator app, four embedded targets and native UI runner once.
8. Inspect compiled localization resources inside each target.
9. Run real UI acceptance on disposable English/Hebrew iPhone/iPad simulators. The iPad passes log in using the actual account sheet, terminate the app before a cloud write, relaunch and assert the task appears, capture a local task and verify the Oracle record, then relaunch to confirm persistence.
10. Save localized screenshots, test summaries, sanitized logs and a success receipt only when all required gates pass.

Test credentials are generated for disposable accounts and removed by test teardown. No production user account is used. The evidence artifact excludes raw xcresult activity archives; screenshot PNGs and exported summaries are sufficient for review without retaining credential-entry activity. Simulator evidence must never be described as a physical iPad/TestFlight device test.

### release

The caller must supply validation_run from a successful validate run for the exact same source and build number. The release job verifies the run status, workflow path, receipt identity, regenerated project digest and SDK lock digest. Tests are reused only after this check.

The job then checks the real App Store app/build list, creates a temporary keychain from the existing distribution identity, validates and installs all five profiles, produces a Release archive, verifies every embedded signature and entitlement, exports a signed App Store IPA, verifies the exported IPA again, validates/uploads through Apple, and records App Store Connect processing and actual beta state.

The API receipt distinguishes processingState=VALID from availability to a particular beta tester. A processed build with no correct group membership must not be reported as distributed. Final delivery still requires group/tester availability evidence and, where requested, a real device check.

CI cleanup restores the prior keychain search list and removes its temporary signing materials and installed GSD profiles. Private API/P12 material and full profiles are not evidence artifacts.

## Commands

Run portable safety checks:

    python3 scripts/test_verify_gsd_release_bundle.py -v

After the portal has associated the App Group, provision using the owner's secure ASC environment:

    python3 scripts/gsd_appstore_connect.py profiles --create --output <public-receipt.json>

Dispatch source validation:

    gh workflow run gsd-hanlin-agent-ios.yml --repo davidpovarsky/gsd-iosapp --ref <integration-branch> -f mode=validate -f source_ref=<exact-sha> -f build_number=48

Dispatch signed release only after that run succeeds:

    gh workflow run gsd-hanlin-agent-ios.yml --repo davidpovarsky/gsd-iosapp --ref <integration-branch> -f mode=release -f source_ref=<same-exact-sha> -f build_number=48 -f validation_run=<successful-run-id>

Do not run duplicate native suites or start a parallel watcher. Generated project/plist artifacts are saved for comparison and later source reconciliation; they are produced by XcodeGen, not edited manually.
