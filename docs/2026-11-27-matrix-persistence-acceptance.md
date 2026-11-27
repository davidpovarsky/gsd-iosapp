# Matrix native persistence acceptance

The original native 13 and workspace four-case suite remain unchanged. The workspace fixture uses the canonical TaskStore with an in-memory database; the original Matrix movie demonstrates a drag without a persistence assertion. This supplemental case closes that specific acceptance gap.

Run GSDMatrixPersistenceUITests/testNativeMatrixDragPersistsAfterRelaunch on fresh, owned iPad simulators in English and Hebrew using the final installed product. Supply the existing source/UDID/artifact/fresh-simulator contract from the system-surface runner. Do not pass --demo-seed or a harness-isolation flag.

The case creates two uniquely named tasks through the ordinary capture UI, checks their distinct canonical IDs and localized quadrants, performs the original one-second native Matrix lift across the two observed panes, reads the changed quadrant in the canonical editor without saving, terminates GSD, and verifies the same task ID and quadrant after a normal disk-backed relaunch. The destination task must remain intact. Original screenshots and AX attachments are preserved. The runner must bind product/source/locale hashes; the JSON can become passed only after all four check groups finish.

This case is simulator touch and app database evidence. It is not physical iPad, VoiceOver speech, live cloud, or personal ChatGPT evidence.
