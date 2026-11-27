# Native Network pinch and selection acceptance

## Scope and source

This additive case was approved for the GSD final acceptance lane on 27 November 2026. It is based on app source `e484b310dcc4e56fbb905bed44168441e892617e` and the selected TaskVisualizationKit `6ca9c98a1115b7e33fa29855ae296a92c81e8eef`. It changes no application or shared-library source and leaves every original acceptance test untouched.

The original Workspace case physically pans the Network, uses Fit, and opens the canonical editor. It does not perform a two-finger pinch or compare canvas geometry before and after selection. The new library reserves the selected-title footer from its first render; selecting a task must therefore leave the current camera and canvas intact.

## One additive case, four configurations

Run `GSDNetworkGestureAcceptanceUITests/testNativePinchPreservesViewportAcrossTaskSelection` against the final verified product in phone portrait and tablet landscape, each in English and Hebrew. The existing native owner alone builds and executes it.

The test requires these explicit runner inputs:

| Variable | Required value |
|---|---|
| `GSD_SYSTEM_SURFACE_FRESH_SIMULATOR` | `1`; a fresh simulator owned by this run |
| `GSD_SYSTEM_SURFACE_APP_SOURCE` | Exact 40-character app commit, independently bound to the installed product by the runner |
| `GSD_SYSTEM_SURFACE_SIMULATOR_UDID` | Actual owned simulator UUID |
| `GSD_SYSTEM_SURFACE_ARTIFACTS` | Absolute artifact root with no existing child for this configuration |
| `GSD_TEST_LANGUAGE` | `en` or `he` |
| `GSD_NETWORK_DEVICE_FAMILY` | `phone` or `tablet`; checked against the actual native idiom |

The runner must retain its app/test-product hashes, dependency closure, source receipt, native log, xcresult and independent test identity/count validation. Environment strings are a recorded contract, not proof of installed product bytes. If the runner exposes `SIMULATOR_UDID`, it must match the declared simulator.

The case uses the existing `--demo-seed` in-memory fixture and real SwiftUI/native input. It neither edits task data nor claims disk persistence, personal account use, physical-device interaction, VoiceOver speech, Flow gestures or other system-surface acceptance. Original Workspace, ordinary Matrix disk acceptance, original31 plus history8 Agent tests, and all other final gates remain required.

## Assertions

1. Navigate through the actual Workspace entry and observed presentation strip, use native Fit, and obtain three consecutive stable native geometry snapshots, bounded to eight samples. Require at least three physically contained, actually hittable task nodes.
2. Perform one real `XCUIElement.pinch(withScale: 1.2, velocity: 1.0)` on the Network canvas. Measure all sufficiently separated pairs among at least three nodes hittable before and after the gesture. Require at least two pairs, each at least 64 points apart before the pinch, and every measured scale within 0.06 of 1.2. Canvas and native hit-region sizes must remain unchanged. This rejects no-op, pan-only, clamped and automatically fitted observations instead of counting a gesture command as success.
3. Choose two distinct actual task titles from those witnesses. For each, tap its original node, require the exact title in the canonical editor, use Cancel without editing, and require the exact selected-title footer after return. The footer must remain inside the app and below the canvas, unobscured by the tab bar.
4. Compare canvas and every witness node against the zoomed state, with a two-point coordinate/size tolerance, after both selections. This catches automatic Fit or resized canvas when a title first appears or changes.
5. Use the real Fit control and require the original canvas and witness frames to return within the same two-point tolerance.

Task button widths are fixed at 44 points in the original adapter; width scaling would be the wrong zoom metric. The library's Fit caps scale at 2 while magnification permits up to 8, so a 1.2 pinch from the fitted fixture should not clamp. The test still requires the actual observed scale; source reasoning alone is not a pass.

## Evidence and result status

Each configuration creates a new `network-native-<family>-<language>` child directory and refuses to overwrite one. It retains unmodified full-screen PNGs, raw AX descriptions, canvas/node measurements, exact selected titles, every measured pair scale and a JSON receipt. Both canonical-editor observations and both returned footer states are preserved. Failures retain the current UI and keep `passed: false`.

This commit supplies the supplemental test and its contract. Native compilation and all four executions are pending the final native owner. No original test was changed, no failure was waived, and no native job was launched by the author.
