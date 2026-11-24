# GSD 4.1.0 (48): signed owner TestFlight delivery

Apple accepted build **48** and its processing state is **VALID**. The verified owner is the only tester in the private internal **GSD Owner Testing** group, which contains this build. At 2026-11-24 13:42:44 UTC, Apple returned **IN_BETA_TESTING** and owner tester state **INVITED**. English and Hebrew What to Test notes were created only because they were missing, and exact text readback matched the approved notes.

## Evidence and immutable source

- Actual application source: [71b1b7ce](https://github.com/davidpovarsky/gsd-iosapp/commit/71b1b7ce4adf7bea2ddacfc683a69906d6acd6ae).
- Full native acceptance: [45397928701](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45397928701), four device/language profiles and 13 passed tests, zero failures/skips.
- Signed archive, IPA export and Apple upload: [45401779393](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45401779393).
- App Store Connect: [GSD TestFlight](https://appstoreconnect.apple.com/apps/6838520892/testflight).
- Build resource: 04715dbf-3b05-4d01-ba3d-d0b0e580d257.
- Apple team: NA6HPWARQ2, verified against the actual owner distribution certificate and all five profiles. The originally supplied team value was stale.
- Both runs use workflow head d0c5b9649a95e34aef0d4a641a28e2b7382bec0f; this is distinct from the checked-out application source.

The application, extensions, resources and dependencies are unchanged from reviewed candidate 168b59aff816e39555acbf8535aaefaec19ee195. The three subsequent commits change only UI test interaction/input and runtime selection. The previously failed 11/13 run remains failed historical evidence. The separately reviewed two-case recovery 40bb968 was not dispatched after this complete equivalent-source acceptance became available.

## Signing, distribution and scope

Both the archive and exported IPA were audited for all five bundle identities, version/build, Hebrew/English resources, actual signatures, team and profile UUIDs. Apple validation and upload returned success; the delivery UUID equals the processed build ID. The signed IPA remains on the existing release host rather than being republished in the public repository.

The owner group remains internal, manually selects builds and has no public invitation link. The API created only the verified owner's GSD-specific beta tester relationship; it did not reuse another app's beta record, change user roles or send a separate invitation request. Apple returned INVITED. That proves the distribution relationship and invitation state, not actual email delivery, acceptance or installation on a physical iPad.

Xcode 27.1 (27A9275) built the products; Xcode 27.0 (27A266a) drove XCTest against iOS 27.2 (24B8117). The thirteen-case receipt includes native Hebrew iPad signup, sign-out/sign-in, cloud changes while the app was closed, native-to-cloud writes, persistence and native account deletion with public structured rejection checks. Root separately verified the disposable owner's users/tasks/library rows were zero.

Watch launch and actual system-host WidgetKit/Share/Shortcuts/VoiceOver checks remain separate work; the app widget gallery is not WidgetKit timeline evidence. Personal Continue with ChatGPT eligibility and physical installation are not asserted.

## Retained machine-readable receipts

The adjacent evidence/testflight48-20261124 directory contains the exact signed archive/IPA audit receipts, active profile receipt, Apple processing receipt, sanitized upload result, owner availability readback and artifact hashes/source provenance. Private keys, API tokens, full owner email, invitation links and IPA bytes are excluded.
