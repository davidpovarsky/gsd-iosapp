# Real GSD system-surface acceptance — 24 November 2026

This is a bounded test-only lane. Production source is ee5e95f536c375cfdbfa13cb6c812dcef8987a5f and its five bundles must remain byte-identical to the accepted production manifest. Source edits are confined to the separate native system acceptance test and this plan. Existing system/Share/preconsent tests belong to the core acceptance owner.

## Required evidence

1. Use a fresh owned Hebrew iPhone simulator and the normal guest application, with no demo fixtures, direct database writes, clock changes, account grants, or security settings.
2. Observe and invoke CreateTaskIntent through the actual Shortcuts application while GSD is backgrounded. A unique title plus !! must appear once in Do First, preserve its task identity after normal termination/relaunch, and retain the parser's normal behavior.
3. If native placement is available, install Today's Focus on SpringBoard using its observed medium-widget control. Require a synthetic real task, change its title through the ordinary editor, observe the installed widget update through the app snapshot/WidgetKit path, and tap that row into the exact task editor.
4. Keep discovery/editor navigation distinct from action invocation. Record false/incomplete for uncovered scope. No Siri, VoiceOver speech, physical-device, personal Cloud, or WatchConnectivity claims.

## Existing evidence reused

Owned test02 discovery passed 1/1 at 20:54:58 UTC on iPhone17Pro / iOS27.2 build24B8117, with the 94dd2e6 test runner composed with unchanged ee5 production bundles. It observed Shortcuts' search/action picker and SpringBoard's native medium-widget button. The first keyboard introduction is identified narrowly by UIContinuousPathIntroductionView and its exact Hebrew explanation. Dismissing that ordinary introduction does not change TCC or Settings.

## Verification sequence

Compile only this isolated test source with the existing pinned dependency graph and Xcode27.1. Compose the new runner with exact original ee5 products and re-audit hashes. Drive the existing Xcode27.0 simulator runtime harness on owned devices. Capture native UI hierarchies and screenshots before making new selector assumptions. The first action-editor walk is explicitly discovery-only; only a subsequent actual invocation and persistence proof can complete Shortcut acceptance.

Use the existing runner's bounded process timeouts, fresh-device inventory, verified installation, source/product checks, and owned cleanup. Coordinate every native slot with the core acceptance owner.

## Full registered Shortcut invocation case

The separate test02RunRegisteredCreateTaskShortcutAndVerifyPersistence case targets the registered Add Task App Shortcut in the native Shortcuts app. It terminates GSD before invocation, selects the production-defined GSD/Add Task controls, enters a unique title with the Do First shorthand into the one native required text field, submits through the keyboard, and requires GSD to remain outside the foreground. It then checks the unique parsed task in the ordinary app and requires the same task identifier after termination and normal relaunch. Optional quadrant/date parameters stay unset.

Input selection uses native role/ownership, never the expected input value or invented system accessibility identifiers. Unavailable or ambiguous native controls produce owned-device screenshots and accessibility diagnostics and fail the case. The direct registered-action parameter UI still requires native observation; source preparation and Swift 6 parsing do not establish invocation acceptance.

This test checkout is based on final production 9f2736d3e071d2ceb4a6dfada1a2c3767c9906be. Its production source trees are unchanged. The test file retains the four previously generated XcodeGen registrations; a new isolated runner build and exact five-bundle composition are required. Editor-only test00 remains historical discovery and is excluded from acceptance dispatch.
