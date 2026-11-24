# GSD phone UI acceptance — 24 November 2026

The completed iPhone English and Hebrew profiles passed **six selected UI tests in total**. The parent workflow was **cancelled during the iPad English phase**. Its original full receipt remains `passed: false`; this report does not authorize release or establish iPad/cloud acceptance.

This documentation checkpoint preserves nine selected original screenshots and their supporting evidence. It changes no application, tests, workflow or signing configuration and does not rerun any test.

## Exact source and provenance

| Item | Evidence |
|---|---|
| Executed source | [37764f1a56a0678e5c4cb4cbd683ab3f44eb2fdc](https://github.com/davidpovarsky/gsd-iosapp/commit/37764f1a56a0678e5c4cb4cbd683ab3f44eb2fdc) |
| Parent workflow | [45343781703](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45343781703), cancelled |
| Downloaded artifact | [14898584445](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45343781703/artifacts/14898584445), 12,178,171 bytes |
| Verified archive SHA-256 | `483af6eb599df092919fafdea691ada6419967a9f0f1d3bb60f0be639e0047e9` |
| Simulator | iPhone 17 Pro, iOS Simulator 27.2, one English and one Hebrew profile |
| Original full acceptance receipt | [native-ui-receipt.json](evidence/phone-20261124/ui/native-ui-receipt.json), `passed: false` |
| Preserved metadata | [artifact provenance](evidence/phone-20261124/artifact-provenance.json), [cancellation scope](evidence/phone-20261124/cancellation-scope.json) |
| File integrity inventory | [evidence-manifest.json](evidence/phone-20261124/evidence-manifest.json) |

The cancellation-scope file is the Native owner's retained observation at collection time. It records no completed iPad result and does not establish who caused the cancellation. Neither the phone review nor this documentation step initiated a CI cancellation or rerun.

## Completed tests and review scope

Both [English](evidence/phone-20261124/ui/iphone-en/test-summary.json) and [Hebrew](evidence/phone-20261124/ui/iphone-he/test-summary.json) summaries report three passed tests, zero failed, zero skipped, and no test failures:

- `test01LocalizedNavigationEditorChartsAndRTL`
- `test03LocalizedWidgetView`
- `test04LocalizedHanlinProvidersAndChatGPTAccount`

The two profiles contain **36 saved PNGs, representing 30 unique images**. All 30 unique images were visually inspected. In each locale, Matrix diagnostic/final, Browse diagnostic/final, and ChatGPT-account diagnostic/final captures are byte-identical pairs. The manifest records all 36 hashes and these six duplicate groups. Only the nine selected PNGs below are copied into this documentation checkpoint; the full image set remains in the workflow artifact.

All **36 original geometry sidecars** are preserved. Each records `XCUIScreen.main`, raw and displayed dimensions of 1206 × 2622, `imageOrientation: 0`, app frame 402 × 874 at (0, 0), and `orientationMatchesApp: true`. No phone crop or rotation defect was visible. These portrait-phone results provide no proof of iPad landscape capture correctness.

## Observed results

| Surface | Observed current-source result |
|---|---|
| Matrix, editor and context menu | English and Hebrew text is readable; Hebrew navigation, controls and alignment mirror correctly. Editor Save is enabled and the strict enabled/hittable check passed. |
| Dashboard | The actual Dashboard opens. Diagnostic and final images show the selected interval changing from 7 to 30 days, with changed chart data and date range. Hebrew labels and legend render correctly. |
| Browse and Recurring Tasks | The row name, count and chevron remain visible above the reserved AI strip. Strict hittability and nonintersection checks pass, and the actual Recurring Tasks destination opens in both languages. |
| Settings | The explanatory account footer is fully readable in both languages above the reserved AI strip. The overlap observed in the earlier source is resolved in these current images. |
| GSD Cloud sign-in form | Titles, mode selector, fields and explanations render in both languages with correct RTL. The screenshot contains an empty form, not a completed account authorization. |
| Hanlin model settings and assistant | Provider options remain present; Hebrew copy is readable, the URL remains LTR, and assistant toolbar/composer positions mirror correctly. |
| ChatGPT account | The correct signed-out prompt is visible, without the earlier Keychain-unavailable message. No personal authorization or inference was attempted. |
| Cloud connection screen | The inline title fits in both languages. Instructions distinguish the GSD Cloud connection from use of the ChatGPT plan for AI requests. |
| Widget rendering | The localized card is readable in the in-app rendering harness. This does not establish an actual WidgetKit timeline. |

No new blocking visual defect was found within these completed phone surfaces. This is a scoped observation, not a claim that every screen, gesture, accessibility mode or device configuration was exercised.

## Hebrew accessibility evidence

The preserved [Hebrew raw AX receipt](evidence/phone-20261124/ui/iphone-he/screenshots/05-recurring-accessibility-label.json) records the actual `browse-view-recurring` label and its Unicode scalars. Written with escaped direction controls, it is:

```text
\u2068משימות חוזרות\u2069, מספר המשימות: 1
```

`U+2068` is FSI and `U+2069` is PDI. Removing only the already-approved bidi control set leaves the complete visible expected label, `משימות חוזרות, מספר המשימות: 1`. Its translated name, punctuation and count are retained; no English fallback or partial-prefix match is used. The current strict equality, hittability, nonintersection and destination checks all passed. The [English raw receipt](evidence/phone-20261124/ui/iphone-en/screenshots/05-recurring-accessibility-label.json) records `Recurring Tasks, 1 tasks`.

This establishes the actual controls present in the current run. The earlier failing run did not save its raw AX label, so this report does not claim direct observation of those older bytes.

## Selected original screenshots

Filenames and PNG bytes are preserved exactly as captured. There is no crop, redraw, rotation, recompression or annotation. These screens contain seeded demo tasks or signed-out forms, with no personal account credentials or OAuth grants.

| Screenshot | Evidence |
|---|---|
| Hebrew Matrix | [01-matrix.png](evidence/phone-20261124/ui/iphone-he/screenshots/01-matrix.png) |
| English Matrix | [01-matrix.png](evidence/phone-20261124/ui/iphone-en/screenshots/01-matrix.png) |
| Hebrew 30-day Dashboard | [04-dashboard.png](evidence/phone-20261124/ui/iphone-he/screenshots/04-dashboard.png) |
| Hebrew Browse | [05-browse.png](evidence/phone-20261124/ui/iphone-he/screenshots/05-browse.png) |
| Hebrew Settings footer | [06-settings.png](evidence/phone-20261124/ui/iphone-he/screenshots/06-settings.png) |
| English Settings footer | [06-settings.png](evidence/phone-20261124/ui/iphone-en/screenshots/06-settings.png) |
| Hebrew Cloud sign-in | [07-account-sign-in.png](evidence/phone-20261124/ui/iphone-he/screenshots/07-account-sign-in.png) |
| Hebrew ChatGPT signed out | [14-chatgpt-account-before-consent.png](evidence/phone-20261124/ui/iphone-he/screenshots/14-chatgpt-account-before-consent.png) |
| Hebrew Cloud connection | [16-cloud-plugin-connection.png](evidence/phone-20261124/ui/iphone-he/screenshots/16-cloud-plugin-connection.png) |

## Acceptance still missing from this run

- Neither iPad profile has a completed UI summary or screenshot set. The English iPad booted, but no completed test result or images survived. Hebrew iPad did not start. Sidebar direction and full landscape geometry remain unverified here.
- The Hebrew-iPad live test did not create its disposable account. Native signup, sign-out/login, closed-app pull, offline/push recovery, persistence and native deletion are therefore unproved by this run. There is no owner/deletion marker or consequent database-absence proof for it.
- The phone sign-in screenshots do not establish successful authentication. Personal Continue with ChatGPT consent, plan inference and the user's actual Plugin Connect remain separate unperformed authorizations.
- Widget images cover an in-app view harness. Actual WidgetKit timeline/Home Screen installation, Share extension invocation, Watch/watch-widget runtime, Siri invocation and physical-iPad behavior need their own evidence.
- The sufficient-element-description accessibility audit is not VoiceOver speech/focus-navigation testing. Not every gesture, menu action, chart interaction, system message or Dynamic Type setting was exercised.
- The cancelled full receipt does not establish a signed release archive, App Store Connect processing or TestFlight availability.

The Hebrew Asana task remains open. The next owner is Native for the outstanding tablet/live-cloud acceptance, followed by review of those exact-source images. This checkpoint preserves the completed phone evidence without replacing or rewriting the original failed/full receipt.
