# Ordinary Hebrew startup: confirmed missing SessionStore

The unchanged GSD application from source `37764f1a56a0678e5c4cb4cbd683ab3f44eb2fdc`
emitted a fatal SwiftUI error during ordinary Hebrew startup:

> Fatal error: No Observable object of type SessionStore found.

This is actual process console evidence from PID 13949, not a source-only
hypothesis. No owned `.ips` report or backtrace was captured. Source review
identifies the normal-only onboarding presentation as the proposed injection
boundary; that view attribution is an inference from the code, not a captured
stack frame.

## Evidence

- [Diagnostic run 45369072859](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45369072859)
  used harness `f341d359d8cbc9a7759370b4dd26975ddf2c8ebe`.
- [Artifact 14908093497](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45369072859/artifacts/14908093497)
  contains 7,658,592 bytes; its verified SHA-256 is
  `decccace4374d951bb0c64603057752c5209d9621ae492ff2e2a972e00b4845d`.
- The exact 217-byte [normal console](evidence/startup-45369072859/normal-console.log)
  is retained with the [diagnostic report](evidence/startup-45369072859/startup-diagnostic.json),
  [redaction receipt](evidence/startup-45369072859/diagnostic-redaction.json) and
  [provenance](evidence/startup-45369072859/provenance.json).

Strict restoration verified the original application, embedded targets and UI
test binaries, full Xcode version, runtime, signatures and resources. Installation
completed in about 56.9 seconds. The ordinary launch used only
`-AppleLanguages (he) -AppleLocale he_IL`; its first recorded liveness sample
was false about 10.8 seconds after launch. The demo console eventually reported
PID 8023, but the helper had not observed that PID within its launch window, so
this run does not establish demo liveness.

## Cleanup and limits

The workflow conclusion remains **failure**. Normal-app termination exceeded
20 seconds, GSD-only log collection exceeded 30 seconds, and simulator shutdown
exceeded 30 seconds. The independent checked delete succeeded. The final
inventory verifies that owned simulator
`C1CB6C5E-925F-416E-B6EA-A4359C19FBD2` is absent; its inventory digest is retained
in provenance. These facts do not convert the timed-out operations into passes.

Both screenshots record portrait dimensions. This diagnostic did not execute
XCTest, create a cloud account, submit credentials or perform account API writes.
It does not clear the original landscape UI failure, cloud lifecycle acceptance,
physical-device behavior or release gates. Every diagnostic receipt retains
`full_acceptance:false` and `passed:false`.

The justified next product change is to provide the same application-owned
SessionStore to the required presentation hierarchy, then validate the resulting
candidate. No second account store or optional fallback is warranted by this
evidence.
