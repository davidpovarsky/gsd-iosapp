# Third-party notices provenance — 2026-11-27

The app-bundled `THIRD_PARTY_NOTICES.md` now matches the dependency revisions selected for the final GSD candidate.
The source base is `e484b310dcc4e56fbb905bed44168441e892617e`. This change updates resource content and provenance only.

## Selected sources

- Original Hanlin SDK: `018981a3af55f4e524c3c3886003991eb243e7c3`, matching `HanlinSDK.lock.json`.
- TaskVisualizationKit: `6ca9c98a1115b7e33fa29855ae296a92c81e8eef`, matching `project.yml`.
- swift-ai-sdk: `abf0921c6e89e6521cc2b510ff11016b45a0ef08`, matching the native agent receipt and `Packages/GSDHanlinAgent/Package.resolved`.
- Newly attributed resolved packages: opentelemetry-swift-core 2.6.0 and swift-atomics 1.3.1.

## Native dependency evidence

The original dependency license bytes were read from the five actual Mac checkouts recorded in:

`/Users/m1/builds/gsd-visual-50-20261125/evidence/agent39-sdk018-3221776/receipt.json`

Native receipt SHA256: `1c1c55f7a42a260c5ac04433beff3ffe36178de39295fe1a1d996b79e75e6dff`.
Native agent source commit: `3221776c913a726115dad1c6c3279e864aea68dc`.
Original SDK source manifest SHA256: `59d8373834b732e96acbf55e0b9e41e869125f2608aa287fbe717df2833045d7`.

Each checkout's current HEAD matched the receipt revision. Each captured license file was byte-identical to
`git show <recorded-revision>:<license-path>`. Tracked LICENSE, NOTICE, COPYING and ThirdPartyNotices filenames
were inventoried; these five checkouts each had the one license file shown below and no separate tracked NOTICE file.
The Mac was read only; no compilation, resolution, checkout, source edit or cleanup was performed.

Checkout root:

`/Users/m1/builds/gsd-visual-50-20261125/client-red-b234ceb/build/checkouts`

The SDK license and JSON notices were read with `git show` at the exact original SDK revision from:

`/mnt/development/projects/worktrees/gsd-lorvex-sdk-integration-20261127`

The Kit license, bundled third-party notice and `Package.resolved` were read from the original immutable GitHub
revision. Their contents were verified against the returned Git blob SHA. The Kit's original SwiftFlow,
AdvancedKanban and ForceGraph pins are unchanged.

## Original file hashes

| Component | Revision | Original file | Original SHA256 |
|---|---|---|---|
| grdb.swift 7.12.0 | `92a554cd0d5e8d67cb18993c6054e73fe42c066c` | [LICENSE](https://github.com/groue/GRDB.swift/blob/92a554cd0d5e8d67cb18993c6054e73fe42c066c/LICENSE) | `9853f9dce81365fcc1d9b46004633354450164b8d17904e92e80c444545f7e87` |
| opentelemetry-swift-core 2.6.0 | `c6fcee77cfc21ba400366f12475217c7b6e1d605` | [LICENSE](https://github.com/open-telemetry/opentelemetry-swift-core/blob/c6fcee77cfc21ba400366f12475217c7b6e1d605/LICENSE) | `c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4` |
| swift-ai-sdk commit pin | `abf0921c6e89e6521cc2b510ff11016b45a0ef08` | [LICENSE](https://github.com/davidpovarsky/swift-ai-sdk/blob/abf0921c6e89e6521cc2b510ff11016b45a0ef08/LICENSE) | `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30` |
| swift-argument-parser 1.8.2 | `6a52f3251125d74daf04fcbd5e6f08a75d074382` | [LICENSE.txt](https://github.com/apple/swift-argument-parser/blob/6a52f3251125d74daf04fcbd5e6f08a75d074382/LICENSE.txt) | `770af8291f708538d8ff885a0bbc4e045cd700531741c4f99528d435c14d7f55` |
| swift-atomics 1.3.1 | `0442cb5a3f98ab802acb777929fdb446bda11a34` | [LICENSE.txt](https://github.com/apple/swift-atomics/blob/0442cb5a3f98ab802acb777929fdb446bda11a34/LICENSE.txt) | `770af8291f708538d8ff885a0bbc4e045cd700531741c4f99528d435c14d7f55` |
| Hanlin SDK / vendored JSON | `018981a3af55f4e524c3c3886003991eb243e7c3` | [LICENSE](https://github.com/davidpovarsky/hanlin-ai/blob/018981a3af55f4e524c3c3886003991eb243e7c3/LICENSE) | `2bdf2973d798073b983a9068a8e328400068c18d962e2059bfcde4042129f294` |
| Hanlin SDK / vendored JSON | `018981a3af55f4e524c3c3886003991eb243e7c3` | [Packages/HanlinAgentSDK/Vendor/Swift-JSON/LICENSE](https://github.com/davidpovarsky/hanlin-ai/blob/018981a3af55f4e524c3c3886003991eb243e7c3/Packages/HanlinAgentSDK/Vendor/Swift-JSON/LICENSE) | `c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4` |
| Hanlin SDK / vendored JSON | `018981a3af55f4e524c3c3886003991eb243e7c3` | [Packages/HanlinAgentSDK/Vendor/Swift-JSON/Licenses/RhoeJSON/LICENSE](https://github.com/davidpovarsky/hanlin-ai/blob/018981a3af55f4e524c3c3886003991eb243e7c3/Packages/HanlinAgentSDK/Vendor/Swift-JSON/Licenses/RhoeJSON/LICENSE) | `c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4` |
| Hanlin SDK / vendored JSON | `018981a3af55f4e524c3c3886003991eb243e7c3` | [Packages/HanlinAgentSDK/Vendor/Swift-JSON/Licenses/RhoeJSON/NOTICE](https://github.com/davidpovarsky/hanlin-ai/blob/018981a3af55f4e524c3c3886003991eb243e7c3/Packages/HanlinAgentSDK/Vendor/Swift-JSON/Licenses/RhoeJSON/NOTICE) | `147def951fc5e289d1621cc9d6ad814be88060f3f0430d1f2378ae67bae14ada` |
| TaskVisualizationKit | `6ca9c98a1115b7e33fa29855ae296a92c81e8eef` | [LICENSE](https://github.com/davidpovarsky/task-visualization-kit/blob/6ca9c98a1115b7e33fa29855ae296a92c81e8eef/LICENSE) | `8869099319696b017df9c997fbb04638975f4b735ed0ac78b71a2f820f43b0f9` |
| TaskVisualizationKit | `6ca9c98a1115b7e33fa29855ae296a92c81e8eef` | [Sources/TaskVisualizationKit/Resources/ThirdPartyNotices.txt](https://github.com/davidpovarsky/task-visualization-kit/blob/6ca9c98a1115b7e33fa29855ae296a92c81e8eef/Sources/TaskVisualizationKit/Resources/ThirdPartyNotices.txt) | `0c569281ebf40d464db3b562d393a9e1aa1e36da54d89d4321cc2e2fdcc5e5a5` |

## Content preservation and additions

All nine existing fenced license/notice bodies remain byte-for-byte unchanged. The dependency bodies checked
against the current original input files match after trimming only outer whitespace, which the existing
Markdown had already normalized. Existing ShipSwift attribution and notice text are preserved without alteration.

The two new sections include the complete original OpenTelemetry and Swift Atomics license bytes, including
the Swift.org runtime library exception for Atomics. Each new raw license byte sequence appears intact in the
updated notice file. Only the stale SDK, Kit and swift-ai-sdk revision references were replaced, and the Kit's
bundled third-party notice now has its own immutable source link.

## Retained evidence and output

- Original Mac license input bundle: `/mnt/development/projects/evidence/gsd-final-notices-20261127/original-mac-license-inputs.json`
  — SHA256 `ae86d31f2136e9e6baea450d435259a6a6a2d5136f5e9e2eeee01380a517bdd4`.
- Original SDK/Kit input bundle: `/mnt/development/projects/evidence/gsd-final-notices-20261127/original-sdk-kit-license-inputs.json`
  — SHA256 `a5fb0661b780134122447dc3ff04d074f45ee7667c5adbfce0d127a6da8e8d3d`.
- Updated `THIRD_PARTY_NOTICES.md`: SHA256 `8b485856685f2782e624dbea818d46a316963791b53faf095a643dc7752735f3`; 69882 bytes.
- Existing `project.yml` resource inclusion for `THIRD_PARTY_NOTICES.md` is unchanged.

The source content checks pass. Final generated-project resolution and built-app resource verification belong
to the native final build; this receipt does not claim those later actions have run.
