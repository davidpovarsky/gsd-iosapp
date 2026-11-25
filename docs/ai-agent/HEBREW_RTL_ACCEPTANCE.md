# Hebrew and RTL acceptance

Historical localization/source checkpoint. Later native visual acceptance and the remaining system-surface gates are tracked in [the current delivery report](GSD_DELIVERY_CURRENT_20261124.md).

The implementation is in the isolated worktree for `feat/gsd-he-rtl-20261123`, based on `d44649ed9bb0cc0eab9fb0d12c9ec63a71cd41ca`. The source and catalog checks passed on Windows. Apple build, packaging, and visual acceptance are pending.

## Coverage

| Bundle or table | English/Hebrew keys | Direct Swift references checked |
| --- | ---: | ---: |
| App, including GSDKit presentation strings | 913 | 1,050 |
| iOS widgets | 10 | 10 |
| Share extension | 17 | 18 |
| Watch app | 46 | 53 |
| Watch widgets | 20 | 10 |
| App Shortcuts | 14 | 14 Siri phrases |

The five Localizable tables contain 937 distinct keys. References shared between bundles count once per bundle. The audit also checks 56 Apple release-note strings, AI tool titles and summaries, and both titles and subtitles of the two Home Screen quick actions. Brand names, technical acronyms, punctuation-only formats and the product website retain their original spelling. Ten app messages have Hebrew singular, dual and general forms. The watch catalog also includes two of these plural entries.

The translations cover onboarding, the field guide, matrix, task editor, browse, dashboard, settings, account errors, reminders, swipe actions and accessibility copy. Generated tool status, approval descriptions and chart series names are localized at the presentation boundary. The reset confirmation accepts the Hebrew word shown in its prompt. Release-note text is localized on display from the existing shared JSON.

## Presentation review

The system supplies the default reading direction. The Appearance picker overrides direction for the app independently of language. The iPad sidebar uses NavigationSplitView and semantic toolbar placements. Matrix columns keep their existing quadrant order in LazyVGrid. Native swipe actions use leading and trailing edges. The custom iPad reveal translates drag distance into distance from the reading edge and uses directional padding. Dashboard chart marks retain their time and category values, with localized axis labels, quadrant names and percentage formatting.

## Checks and remaining gaps

- `py -3 -X utf8 scripts/audit_hebrew_localization.py` passed. It checks direct UI literals, common plain-string assignments, catalog values, format arguments, shortcut phrases, quick actions and bundled release notes. An in-memory negative control detected a removed Settings key, a missing interpolation and a new untranslated error assignment.
- Windows `swiftc -frontend -parse` passed on the 29 modified Swift sources. `git diff --check` passed.
- The former English fallback-target gap is resolved: `Packages/GSDHanlinAgent/Sources/GSDHanlinAgent/GSDHanlinHost.swift` localizes “several tasks” and “current selection” before creating the approval request; the App catalog supplies “כמה משימות” and “הבחירה הנוכחית”. This path was verified in frozen ee5 source. A source scan cannot exercise every other computed string. Provider responses and unrecognized server error detail appear as received. User-entered titles, notes, tags, and prompts are preserved.
- Apple SDK type checking, catalog compilation, Siri phrase registration, VoiceOver speech, notification delivery, long-text fitting, chart rendering and RTL gestures on iPhone and iPad await Apple-side verification. The watch and share surfaces also await runtime checks.

## Coordinator integration

The existing XcodeGen specification already includes each target directory as a source root. Regenerate the project with English as the development language and include Hebrew among the known regions. The checked-in project at the base SHA lists only Base and English. Verify that each product embeds its own compiled Localizable table, that the app embeds its AppShortcuts and InfoPlist tables, and that both widget bundles include their Hebrew display names. GSDKit strings resolve in the consuming main bundle. Do not combine the five same-named catalogs into one target.

For visual acceptance, launch in Hebrew and English on iPhone and iPad. On iPad, check the sidebar and two-column matrix, complete and snooze from opposite edges, then switch the manual direction and repeat. On both devices, inspect a mixed Hebrew/Latin task title and a chart with dates and counts. Exercise a shortcut and a notification action in Hebrew, and open the share extension, widget gallery and watch app in their own processes.

## Continuation checkpoint ? 2026-11-23

The completed worker's 41 intended files were preserved in commit
`d99527b4977c70d23d39522c56c0c8b6ace2c793` on
`feat/gsd-he-rtl-20261123` and pushed to the owner's Git remote `fork`.
Normal Git access through the existing Windows connection succeeded; no permissions were changed.
The only edit before that commit was removal of an extra final blank line in the new audit script,
which the staged-file whitespace check caught. Original worker logs remain untracked.

A follow-up adds 16 cloud account labels/messages (including the corrected closed-app explanation)
and the two native Hanlin approval fallback labels. These cover the new cloud screen and its
current Settings/SessionStore copy; the account-source owner is responsible for its integration.
The assistant-view localization is frozen for the coordinator's SIWC work.

Check ownership: catalog audit and focused Windows Swift parse belong to the Hebrew lane.
The Apple lane alone owns XcodeGen generation, resource packaging, Xcode compilation and
Hebrew/English iPhone/iPad runtime screenshots and gestures. No new native-runtime pass is claimed.
