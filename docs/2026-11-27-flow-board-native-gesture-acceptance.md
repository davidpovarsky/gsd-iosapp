# Native Flow and Board gesture acceptance

This additive case closes two specific gaps in the original Workspace acceptance:
the original case does not pinch or pan Flow, and its lane-menu action occurs in Table,
not the Board card menu.

Case: GSDFlowAndBoardGestureAcceptanceUITests/testFlowPinchPanEditingAndBoardMenuMutation

Run on fresh owned iPhone portrait and iPad landscape simulators, each in English and Hebrew.
Preserve the original Native13, Workspace4, Share2/8, Matrix persistence and Network gates separately.

Required environment:
- GSD_SYSTEM_SURFACE_FRESH_SIMULATOR=1
- GSD_SYSTEM_SURFACE_APP_SOURCE: exact final 40-character app source SHA
- GSD_SYSTEM_SURFACE_SIMULATOR_UDID: actual owned simulator UUID
- GSD_SYSTEM_SURFACE_ARTIFACTS: new absolute evidence root
- GSD_TEST_LANGUAGE=en|he
- GSD_FLOW_BOARD_DEVICE_FAMILY=phone|tablet

The runner binds declared source to the actual installed products and full dependency closure.
The test does not self-certify product source.

The actual Flow Fit control establishes a stable measured baseline. A real 1.2x two-finger
pinch must scale every measured separated witness pair by 1.2 +/- 0.06 with at least three
hittable tasks and two distinct pairs. Flow frames scale with cards; the Network fixed
44pt hit-region invariant intentionally does not apply.

The native background pan starts at an observed free point derived from title, completion,
port and toolbar frames, with conservative node exclusion rectangles. At least three
hittable witnesses must translate coherently by more than 24pt in the actual gesture direction;
pair distances and card sizes must remain unchanged. Task identities, titles and completion
values must remain unchanged during viewport gestures. A node drag or no-op cannot pass.

The test then taps an actually transformed witness and edits its title through the ordinary
canonical editor. The same task ID and exact saved title must appear in Table. It selects
that task's real Board card menu and moves to a different lane, then verifies the same task
in Table and the selected quadrant in the canonical editor.

Six check groups must complete exactly once before passed=true. Raw PNG, AX, geometry,
pinch pair ratios, pan translations, task IDs and before/after canonical values remain
append-only in flow-board-native-<family>-<language>/flow-board-native-acceptance.json.

The existing --demo-seed fixture uses an in-memory canonical TaskStore. This case proves
real native gestures and canonical mutations, not cold disk persistence, personal accounts,
physical devices or model inference. Dedicated persistence and account gates remain separate.

The source identifiers were inspected in qualified Kit6ca. Recheck the public Flow/Board
identifiers against the qualified final presentation-state Kit before source freeze.
Original acceptance files and product/shared sources remain unchanged.
