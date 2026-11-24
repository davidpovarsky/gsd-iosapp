# Hebrew normal-startup crash diagnostic

This is a diagnostic-only continuation of run
[45354255968](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45354255968).
Its iPad English tests passed; the Hebrew GSD process received signal 5 before
native signup, followed by an XCTest async interruption stall. The preserved
logs confirm the crash but contain no `.ips` stack. An absent SessionStore
environment in the normal-only onboarding presentation is a source hypothesis,
not an established cause.

## Immutable inputs and limited execution

Application and compiled test source remain
`37764f1a56a0678e5c4cb4cbd683ab3f44eb2fdc`. The existing reviewed recovery
verifier restores the exact three pinned artifacts from run45343781703,
validates their metadata/content hashes, full Xcode27.1 build27A9275, original
compiled app/test binaries, signatures, target resources and iOS27.2 runtime.
None of those checks is removed. The diagnostic branch returns before cloud
health, native XCTest execution or full receipt composition.

The diagnostic installs the restored app on one newly created iPad simulator.
It runs exactly the Hebrew demo arguments for15seconds, terminates that app,
then runs the Hebrew ordinary arguments for up to60seconds. It neither submits
an account form nor executes CloudFixture or personal authentication.

Apple documents Simulator console capture through `simctl launch --console-pty`
in [Getting the Most Out of Simulator](https://developer.apple.com/videos/play/wwdc2019/418/).
The installed Simulator help is also checked before this flag is used. Combined
app stdout/stderr are retained; they are never printed as unfiltered tool output.
Raw full-screen PNG dimensions record the actual orientation. A portrait
nonreproduction does not clear the original landscape/XCTest failure.

## Crash ownership and cleanup

Only new GSD `.ips`/`.crash` reports matching the owned device UUID in the process
path, bundle identifier, capture time and observed PID are copied. When launch
fails before a PID is reported, the device-path/bundle/phase binding is still
required. Transient per-file I/O or encoding problems record counts/categories
and continue within the bounded scan. A delayed ReportCrash write may be awaited
for at most90seconds per phase. Previously verified copied reports remain in the
receipt by digest if their source is later rotated. Observation-end time remains
fixed; collection and cleanup timestamps are separate.

The script captures only GSD-process logging from the owned simulator and
collects crash reports before independent shutdown/delete attempts. Final
inventory must prove the owned UUID is absent. Other simulators and reports are
never deleted. Known fixture-mask sanitization is mandatory before diagnostic
artifact upload; sanitization failure blocks that upload.

## Observed installation boundary

Run [45366992566](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45366992566)
restored the exact products in12.04seconds, then the first simulator boot-status
command completed after about97.7seconds. Installation exceeded its original
60-second limit before either app launch. The artifact is14908375102,16725bytes,
SHA256 `773979899f27abffd04dde68d73db2212438cce37b7d01814d07a7b29b4e01d9`.
The report has no phases and no account fixture. Shutdown was attempted without
a timeout (its exit code was not recorded); checked deletion succeeded and the
final inventory proves the owned simulator absent. This is infrastructure
boundary evidence, not a startup cause or native acceptance result.

Only installation now allows up to300seconds. All app observation, crash capture,
ownership, redaction and cleanup behavior is unchanged. The original13-control
receipt is retained unchanged; a separate delta receipt verifies only this
installation allowance, the diagnostic-job budget and unchanged remaining paths.

## Budget and interpretation

The workflow ceiling is35minutes. If strict restoration takes more than300seconds,
the diagnostic stops before creating a simulator. Subsequent command and wait
allowances total at most1550seconds, including the existing command runner's
TERM15/KILL10 timeout cleanup, both final5-second scans, and checked simulator
cleanup. This leaves250seconds for checkout, redaction, artifact upload and
scheduling. The healthy path is much shorter; this changes no full-UI timeout.

Every diagnostic receipt has `diagnostic_only:true`, `full_acceptance:false` and
`passed:false`. No native-acceptance receipt or release marker is emitted.
Collected evidence can confirm a startup cause; successful startup alone does
not establish Hebrew layout, cloud lifecycle, full native acceptance or release.

Thirteen offline controls cover strict report ownership, pre-PID capture,
transient and delayed reports, retained copies after rotation, frozen observation
boundaries, bounded launcher cleanup, simulator cleanup failures and unchanged
existing workflow/restoration paths. They are not a Mac runtime result.
