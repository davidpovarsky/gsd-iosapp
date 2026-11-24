# GSD integration and delivery checkpoint — 2026-11-24

## Delivered build and verified source

**GSD 4.1.0 (48) has a real Apple Distribution archive and signed IPA, was uploaded successfully, and is VALID / IN_BETA_TESTING for the verified owner in App Store Connect.** This establishes owner TestFlight availability. Personal invitation acceptance, a physical installation and the two separate personal ChatGPT authorizations remain unobserved.

- [Full native validation 45397928701](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45397928701): **13 actual UI passes, zero failures, zero skips**, across iPhone/iPad and English/Hebrew, with successful package, build and resource gates.
- [Signed release 45401779393](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45401779393): **success**, completed 13:28:57 UTC.
- Actual app source: [71b1b7ce4adf7bea2ddacfc683a69906d6acd6ae](https://github.com/davidpovarsky/gsd-iosapp/commit/71b1b7ce4adf7bea2ddacfc683a69906d6acd6ae).
- The separate workflow head for both runs is `d0c5b9649a95e34aef0d4a641a28e2b7382bec0f`, branch `codex/gsd-build 48-scaleway`. It differs from the checked-out app source.
- [Apple delivery report and public receipts](https://github.com/davidpovarsky/gsd-iosapp/blob/9b451700949cfce26287b749ca1ffb4a1da411c8/docs/ai-agent/TESTFLIGHT_DELIVERY_20261124.md).
- [App Store Connect TestFlight](https://appstoreconnect.apple.com/apps/6838520892/testflight), app `6838520892`, build `04715dbf-3b05-4d01-ba3d-d0b0e580d257`.

Root independently compared the accepted source with prior candidate `168b59aff816e39555acbf8535aaefaec19ee195`. Three later commits change only `ScreenshotTests/GSDCloudReleaseUITests.swift` and `scripts/gsd_native_acceptance.py`. Production code, resources, dependencies and build configuration are identical. The reviewed test changes retain native signup and all acceptance assertions while correcting HE menu dismissal, waiting for readiness, using the native local-only clipboard for disposable passwords and recording the selected runtime. Clipboard content is cleared after entry.

The private owner distribution journal was independently read back at 13:42:44.875903 UTC. The existing manual internal group **GSD Owner Testing** contains exactly the accepted build and the verified owner's GSD-specific tester. The tester state is **INVITED / EMAIL**; the build state is **IN_BETA_TESTING**. Neither state proves email receipt, invitation acceptance or installation.

The integration branch remains at protected checkpoint `37764f1a56a0678e5c4cb4cbd683ab3f44eb2fdc` while isolated publication lanes finish. A later one-line Hebrew caption correction is published separately and **is not present in build 48**; runtime acceptance and a subsequent release remain pending.

## User acceptance criteria

| Criterion | Established evidence | Remaining acceptance |
|---|---|---|
| Full Hebrew and RTL | Five-target resources; all 13 selected EN/HE iPhone/iPad cases; scoped raw-image/geometry review | Published caption needs runtime/release; actual system surfaces and broader assistive behavior |
| Account creation and login on iPad | Real native HE-iPad signup, sign-out/sign-in, relaunch and deletion pass | Physical owner installation and personal account use |
| Bidirectional Oracle synchronization | GRDB/TaskStore/SyncEngine closed-instance, offline queue, new-store and isolation scenario; native closed-app server→UI and UI→server round trip | Physical second-device/radio observations |
| ChatGPT reads/creates while iPad is closed | All 22 public server tools execute independently of the iPad; native closed-app task delivery passes | Personal Plugin Connect and invocation through that grant |
| Normal plugin login without pairing | Private plugin 0.2.0 cloud OAuth; PKCE/refresh/revoke/isolation and localized login-form checks pass | Owner consent/grant inside ChatGPT |
| Hanlin and all 22 tools continue working | Current Hanlin consumer/contracts and real public tools pass; provider UI passes in four profiles | Personal ChatGPT-plan inference remains separate |
| Continue with ChatGPT or exact official blocker | Official direct-flow implementation and 13 contract tests pass; localized provider/account UI | Real browser startup, personal grant, eligibility and inference; no account-specific denial observed |
| Reports, charts and UI | Real reports/data tests, four navigation/chart cases, scoped 3/3/2/2 legend/non-overlap review | Caption runtime and actual system-host observations |
| Xcode / GitHub Actions pass | Successful full native and signed release runs for exact accepted source | Supplemental harnesses and changed caption require their own evidence |
| Apple IDs and profiles valid | All five IDs, App Group and Distribution profiles pass archive/export audits | No open build 48 signing blocker |
| Signed Release | Real Distribution archive and IPA; all five signatures audited | No open build 48 signing blocker |
| TestFlight accepted and available | VALID / IN_BETA_TESTING; exact group/build/owner readback | Owner acceptance and physical installation are separate |
| Asana reconciled | Apple task complete; Cloud/Hebrew/project updates preserve evidence and limits | Subsequent system/caption/personal outcomes before remaining closures |

Cloud, Plugin, Continue with ChatGPT, Hebrew and physical-device tasks remain open for these specific remaining observations. The Apple task is complete within its signing/upload/availability scope. Eight unrelated Lorvex tasks are outside this delivery's closure scope.

## Native acceptance and exact-owner cleanup

| Actual profile | Navigation/editor/charts/RTL | Widget view | Hanlin/provider UI | Live native account/cloud |
|---|---:|---:|---:|---:|
| iPhone English | 67.195s pass | 8.511s pass | 36.016s pass | Not selected |
| iPhone Hebrew | 65.985s pass | 8.556s pass | 36.047s pass | Not selected |
| iPad English | 201.846s pass | 8.766s pass | 37.770s pass | Not selected |
| iPad Hebrew | 198.262s pass | 7.633s pass | 37.851s pass | 110.990s pass |

All 13 unique executed cases are corroborated by the full receipt, four xcresult summaries and terminal logs. Compilation used **Xcode 27.1 / 27A9275**. The Scaleway host's XCTest driver used **Xcode 27.0 / 27A266a**. All four runtimes were **iOS 27.2 / 24B8117**. The entire execution is not described as Xcode 27.1.

The HE-iPad lifecycle created its disposable account through the actual native form, signed out and back in, asserted app.notRunning before creating a server task, pulled that task on launch, created another task through the UI and verified it on the server, relaunched and retained both tasks, and invoked native account deletion. It verified signed-out state and local task absence plus server record/authentication invalidation. Its success flag prevents fallback API deletion from being credited as native deletion.

Root used the actual successful public deletion marker `3leycx6ntg6uhsq` for a separate **read-only Oracle transaction at 13:37:06.917528 UTC**: **users 0 / tasks 0 / gsd_library 0**. [The exact-owner receipt](evidence/native-45397928701/oracle-owner-zero.json) binds this query to app 71b, validation 453979 and release 454017. No broad earlier database snapshot substitutes for it.

Root directly reviewed four unmodified HE-iPad PNGs and matching geometry: account created, closed-app cloud task, both round-trip tasks, and account deleted/signed out. App/window geometry was 1376×1032 with matching orientation. [The retained manifest](evidence/native-45397928701/manifest.json) preserves original image hashes and adjacent geometry.

| Evidence | Identity |
|---|---|
| Full native artifact |14923656158;90,068,222bytes;SHA256 `7a9982bc82a7f15fffcac133bdddebb238c35893cf219c8e6c2eebfec15e08a4` |
| Receipt ZIP |14924405431;SHA256 `57b0ec55d884f40f4842acd86a7c774bdafa70820a6c37e298b47ce6d8a8d278` |
| [Native receipt JSON](evidence/native-45397928701/native-acceptance.json) |SHA256 `f099c5115a52e521e61bdcca41499326372999ff540c9dbc4df6e5b7c2164cd7` |
| Compiled product artifact |14921503382;outerSHA256 `881712bd03e5e6fd3ef0649805fc2bf661ba5fa60d6982215eb8c2018b05c209` |
| Inner product archive |SHA256 `cfc50d90f996967ec968d967f56f656d128f1fe9d0d4be7d531fc72f0449428d` |
| Generated project |SHA256 `34a5cd5423a1ca6174b392a03a54487831bf893c3d7a899f6c74f8498a8be048` |
| Hanlin resolved dependency file |SHA256 `495a57ddb8dad31258234f16543a26e431a9e9880a38d9601b8b89b8b23ea045` |

Eight shutdown/delete command logs are empty and the runner reports no cleanup errors. No final independent simulator-membership inventory exists for this parent; that stronger observation is not invented. Simulator resource receipts have signed:false; their ad-hoc entitlement evidence is separate from the real Distribution receipts.

Current package gates passed: session 13, connectivity 8, Hanlin 7 XCTest plus 13 Swift Testing contracts, cloud 94 across 7 suites, timer 3, library 4, and deletion/recovery 18 across 2 suites. The live native GRDB cloud scenario passed in 5.739 s. Both resolved dependency files were retained for legitimate future evidence reuse.

## Candidate changes and preserved architecture

The accepted application preserves the existing GSDWire, GSDSync, SyncEngine, PocketBase and GRDB architecture, the native TaskStore, and the original Hanlin agent/tool layer. It incorporates these reviewed corrections:

- [706adb190e29d17b5e876a0ab89f71c8ce6b4de5](https://github.com/davidpovarsky/gsd-iosapp/commit/706adb190e29d17b5e876a0ab89f71c8ce6b4de5) passes the already-owned SessionStore into the normal onboarding cover. The previous normal startup logged a missing SessionStore fatal error; no second session store or demo bypass was introduced.
- [bada23baf43a4e08b21a79801711106927322d53](https://github.com/davidpovarsky/gsd-iosapp/commit/bada23baf43a4e08b21a79801711106927322d53) places the regular-width Dashboard assistant within the detail safe area and adds real legend visibility/count/non-overlap assertions.
- [4c7e048d7e50fc34fde8b29b45224cbcd711ebda](https://github.com/davidpovarsky/gsd-iosapp/commit/4c7e048d7e50fc34fde8b29b45224cbcd711ebda) makes asynchronous UI-validation failures unwind through ordinary throwing guards. Conditions, selectors, waits, operation order and cleanup requirements are preserved.
- [056e7e58f09f3d40927c0c49a5dabbe2ea6c02c1](https://github.com/davidpovarsky/gsd-iosapp/commit/056e7e58f09f3d40927c0c49a5dabbe2ea6c02c1) gives the HE-iPad live-cloud profile a measured 1,800-second command budget. Other profiles retain 1,200 seconds.
- [bea4134c3ca9b58f7fefef14a33638a843477803](https://github.com/davidpovarsky/gsd-iosapp/commit/bea4134c3ca9b58f7fefef14a33638a843477803) captures both existing resolved dependency files for future exact-evidence reuse.

Earlier canceled/failed runs retain their original outcomes. The successful full validation above supplies current acceptance for the immutable accepted source; earlier partial cases are not relabeled.

## Historical failed run and superseded recovery

[Run45380356237](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45380356237) on168b remains **failed**,11/13: HE-iPad context-menu dismissal and pre-submit signup readiness failed. It created no native account and did not establish the full UI cloud lifecycle. Its artifact14918938042 is66,691,915bytes, SHA256 `84d3bde819dc9960d6daa8a75664614f2763a914a558ad75227dfff15e7f87fc`.

Root's reviewed two-case recovery [40bb96877ce122e30b9f306e5a7594ccf5b7715e](https://github.com/davidpovarsky/gsd-iosapp/commit/40bb96877ce122e30b9f306e5a7594ccf5b7715e), including test-only9a791b8c/4ed8729b, was **never dispatched**. A pre-dispatch inventory found the existing full validation and active signed upload. Root verified production-source equivalence, actual receipts and outcomes, then reused that successful work. The recovery is superseded; it must not trigger duplicate testing or a second build 48 upload.

The Scaleway workflow head contains branch-specific routing and has not been blindly merged into integration, where those conditions could skip jobs.

## Cloud, accounts and the private plugin

Production cloud source `0e8911a33fc29eed8dfd969e43a0e6a86b63c9a4` serves the existing Oracle PocketBase/gateway deployment. [The public E2E log](https://github.com/davidpovarsky/gsd-iosapp/blob/cfe9470b6020c28474395ff97f0672d4a5c8f126/docs/ai-agent/evidence/cloud-20261124/public-e2e.txt) records nine real acceptance stages and execution of all 22 MCP tools, including read/create/update/delete/report operations, version conflicts, two-account isolation, PKCE, refresh rotation/replay rejection and revocation. [The transport receipt](https://github.com/davidpovarsky/gsd-iosapp/blob/cfe9470b6020c28474395ff97f0672d4a5c8f126/docs/ai-agent/evidence/cloud-20261124/public-e2e.json) records public TLS and synthetic cleanup.

The real native system scenario uses the existing GRDB/TaskStore/SyncEngine against the server. A new clean store represents a new device's data state; it is not a second physical iPad. The [8-test connectivity probe](SYNC_CONNECTIVITY_SCHEDULING_20261124.md) separately exercises actual coordinator scheduling, loss/return, duplicate suppression and lifecycle/account holds. It does not simulate every physical-radio or engine interleaving. The [13-test session observation report](SESSION_IDENTITY_OBSERVATION_20261124.md) also identifies its substituted platform dependencies; it is not independent OS-Keychain acceptance.

The private [GSD plugin](https://chatgpt.com/plugins/plugins_6b0396bab7888191a5a7386c54a8475f) is version **0.2.0**, release `pluginrel_6b04d42b006c81919d7c1f65c062159a`, with its existing private audience preserved. It uses normal GSD-account OAuth DCR at:

`https://torah-social.tail0a6c7d.ts.net:10000/gsd-cloud/mcp`

Scopes are `gsd.read gsd.write offline_access`. The native root no longer starts legacy pairing polling. [OAuth web acceptance](OAUTH_WEB_LOCALIZATION_ACCEPTANCE_20261124.md) records HE→EN→HE form behavior and origin/CSRF checks. That browser review entered no personal credentials and created no grant. Server protocol tests and plugin metadata are not proof that the owner has completed personal Connect consent inside ChatGPT.

The native deletion requirement is now satisfied by the actual source-bound marker and root's exact-owner Oracle zero transaction. Personal Plugin Connect remains separate from server protocol tests and in-app Continue with ChatGPT.

## Continue with ChatGPT

The canonical Hanlin SDK remains pinned to [caa4faa509ebf5ba4164408734bb6e0dd3662203](https://github.com/davidpovarsky/hanlin-ai/commit/caa4faa509ebf5ba4164408734bb6e0dd3662203). [SDK acceptance](CHATGPT_PLAN_SDK_ACCEPTANCE.md) records the consumer and official protocol contracts.

The current official [sign-in specification](https://developers.openai.com/siwc/token-sharing-open-source/sign-in.md) begins authorization with client_id=dynamic_agent_client, a stable host identity and the actual agent name. It does **not** begin with a separate DCR POST. Personal naming/consent returns the issued client identity. The host uses the system browser, a listener-first HTTP 127.0.0.1 callback, fresh state/nonce/PKCE, identity checks and scoped authorization before inference, with Keychain persistence and refresh/cancellation/account separation.

The [official preview limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations.md) define the direct Responses route. The engine uses array input, streaming and store=false and requires terminal response.completed before success. Client-executed tools remain separate from hosted MCP/tool-search capabilities on that route.

OpenRouter/OpenAI API remain available; no ChatGPT cookies, unauthorized private credentials or silent paid-API fallback are used. Four provider/account UI tests passed, but do not prove actual browser authorization startup or personal inference. A bounded pre-consent startup feasibility review is underway.

**No personal grant, account-plan eligibility or inference response has been observed.** No account-specific official rejection has been observed either. Personal authorization/live eligibility remain pending; the subscription is not claimed active or ineligible.

## Hebrew, RTL and system surfaces

Catalog reconciliation records **1,000 unique localized keys** across five targets: App 966 strings + 10 plurals, Widgets 10, Share 17, Watch 44 strings + 2 plurals, Watch Widgets 20, plus 14 App Shortcuts phrases. XcodeGen assigns target resources including new cloud/account/provider/error/consent UI. English remains available.

All four selected navigation/chart profiles pass. Scoped direct image review includes the Hebrew editor, context menu, dashboard, quadrant and browse destination with matching geometry. Legend counts remain 3/3/2/2, separate from the assistant. Account images and exact-owner cleanup prove their native account scope. These observations do not prove every system or assistive interaction.

A concrete Hebrew caption defect was found: total 10 above a singular active-task caption. [dec9fc3e02cf9c7a696e4bc422c57698156f1637](https://github.com/davidpovarsky/gsd-iosapp/commit/dec9fc3e02cf9c7a696e4bc422c57698156f1637), parent 71b, changes only that caption to existing count-independent **Tasks / משימות**. The heading, active count, chart data and accessibility semantics remain unchanged; the singular key remains for individual task cards. Swift syntax, localization audit and exact one-line review pass. **Runtime and subsequent release remain pending; the correction is not in build 48.**

The in-app widget view is not SpringBoard WidgetKit execution. Demo modes isolate stores, so actual Share/widget probes use normal startup and owned local tasks. Current supplemental lanes:

- Watch [1e2ac50ec297f68283138d47475341985e00b661](https://github.com/davidpovarsky/gsd-iosapp/commit/1e2ac50ec297f68283138d47475341985e00b661) pins accepted native/product evidence. Root's full published-file comparison and 17 focused controls pass. One paired EN/HE cold-launch/liveness/screenshot run is being dispatched; runtime is not yet claimed. It does not prove WatchConnectivity, complications, Siri or VoiceOver.
- System-surface Swift SHA256 `79bc4cc03c5047ea4d8843e21a6a86f32e4fc2a5fa3cda3643b460e39f87ba6c`; helper `dcb677bb6dea2070dac1611070f3372914ff3581626ea4a23c7e0a35f4d1e783`; 27 new focused controls pass. Root accepted the narrow delta; publication is authorized and simulator execution pending.
- The real text Share path requires compose/Add/Cancel, exactly one distinct added task, source preservation, relaunch persistence and no canceled insertion. Its description audit is limited to the actual compose host. URL sharing, WidgetKit add/refresh/tap, Shortcuts execution and VoiceOver focus/speech remain discovery-only or unknown until observed.

Global supplemental coverage remains false. Host discovery, compilation, a screenshot or one description audit cannot prove complete system interaction.

## Apple signing and TestFlight

The actual team is **NA6HPWARQ2**, established by the existing owner-controlled Lorvex Distribution certificate/profile and confirmed by all five GSD signatures. The original 52HVJ3VDSM value did not match that evidence and is historical. Existing certificates were preserved; no key values or private signing files are published.

App 6838520892 and App Group 77VDF9H5QW/group.com.itorah.gsd have all five expected IDs. Archive/IPA audits confirm version/build, profiles, entitlements, localizations and signatures:

| Bundle | Distribution profile UUID |
|---|---|
| com.itorah.gsd |07967a1f-d03d-480a-a385-971692fc9d7a|
| com.itorah.gsd.share |7181b8c1-5b75-4806-8c9d-6f1a08e2c8c6|
| com.itorah.gsd.widgets |8e6331b2-89e5-4196-9d63-05dae4cd013c|
| com.itorah.gsd.watchkitapp.widgets |87487730-eae7-410d-93df-7d9db785e651|
| com.itorah.gsd.watchkitapp |08eba580-912d-45a6-ae87-1a919681e002|

Apple returned VERIFY_SUCCEEDED; upload completed and processing returned VALID. Release artifact14924926887 is172,752bytes, SHA256 `5691be32c03fdab2e2c51df3bc71950a5b0a96cd8aaa0062dbecd4481422a49a`. The IPA remains on the existing private signing host.

Internal manual group 791ccd13-9b19-46c4-b1c6-380887f27edb contains the exact build and verified owner's GSD-specific tester 73170283-fec7-467a-8a27-77764393ec4a. Readback 13:42:44.875903 confirms INTERNAL_ONLY, IN_BETA_TESTING, expired=false and INVITED/EMAIL. Same-email records from other apps were not repurposed; no public link or broad tester audience was enabled. English/Hebrew test notes were created only when absent and read back exactly.

Public evidence commit 9b451700949cfce26287b749ca1ffb4a1da411c8 contains eight documentation/receipt files; it excludes personal email, invitation URLs, tokens, private keys and the IPA. [Apple Asana task](https://app.asana.com/0/1220770501963372/1220820292484722) completed 13:52:37 UTC after actual receipts, with history retained. Installation and personal authorizations remain separate. Any next caption/fix build needs a fresh number check and its own exact-source validation/release; build 48 must not be overwritten.

## Backups and Oracle operations

[Calendar backup acceptance](BACKUP_CALENDAR_ACCEPTANCE_20261124.md) records the successful Oracle invocation at 03:18:35 UTC and Windows execution at 03:35, encrypted storage and hash/manifest verification. The production snapshot contained one user and no task/library records. The Windows scheduler history did not establish the exact trigger cause, and DPAPI recovery depends on the existing available Windows user profile.

[Nonempty recovery at 540bde78](https://github.com/davidpovarsky/gsd-iosapp/blob/540bde78d1eb7b90de9eb12d20d319d1c439f1f4/docs/ai-agent/NONEMPTY_BACKUP_RECOVERY_ACCEPTANCE_20261124.md) separately passed at 07:08:46 UTC: real PocketBase, unchanged backup implementation, one user/task/library fixture, stopped source, separate restored instance, fresh authentication and exact full-record equality. Owned processes and temporary data were removed. This proves content recovery in an isolated same-host scenario, not a whole-production cutover, alternate Windows-profile recovery or OAuth-grant disaster recovery.

[Bounded provider expansion](https://github.com/davidpovarsky/gsd-iosapp/blob/2e15c12340abeb23627a4aae84ad57baae8b48f0/docs/ai-agent/OCI_BOUNDED_EXPANSION_EXECUTION_20261124.md) records two available FULL backups and validated boot/data filesystem growth with service continuity. It does not prove restoring those volumes or application-consistent recovery of other projects.

[Capacity admission](https://github.com/davidpovarsky/gsd-iosapp/blob/be0cb9301e24c1afccce89e1dbc0d8254e628db3/docs/ai-agent/CLOUD_CAPACITY_ADMISSION_20261124.md) records scoped operational thresholds: 512 MiB data / 768 MiB root before new phases, with a 256 MiB stop-admitting-new-scenarios threshold while preserving cleanup. These are operational bounds, not reserved space or protection from unlimited external writes.

Latest phase admission included here: **13:18:30.972815 UTC**, Sentinel job_356e17ffcbbc; data926,224,384bytes(883.32MiB), root2,047,856,640bytes(1,952.99MiB), six original service identities/listeners unchanged, both GSD health endpoints HTTP/body200. Fresh admission is required before a new live-account phase. Local-only Watch/Share probes do not create cloud fixtures. Volume changes were not attributed without evidence; no other-project files/data were deleted.

## Preserved work and historical evidence

Original preserved work includes cloud checkpoint `86794659ad55ad18033a0f8368fee114a2c97c0b`, Hebrew `d99527b4977c70d23d39522c56c0c8b6ace2c793` and Unicode repair `9fda3bae2f200e7b645b4f2b7ed8bcc39d896b3c`. Four dirty base-branch handoff files were separately committed as `b90d2a520978c00ee399c654472243b76c09b407`; unrelated backups/logs were preserved.

The integration already includes tested cloud work through `cd039e1b688c570fea005679af6549703ac827ad`, canonical SDK consumption `f62b1de4e1888ebb39459d60455fb463ee2c88f8`, native preparation `8cd9b2b7d2980e8487eaf622f6ace820e8ff139a` and the subsequent recorded fixes. The [original checkpoint](https://github.com/davidpovarsky/gsd-iosapp/blob/37764f1a56a0678e5c4cb4cbd683ab3f44eb2fdc/docs/ai-agent/GSD_INTEGRATION_20261124.md) retains the earlier timeline and failure boundaries.

[Run 45119548923](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45119548923) remains evidence for **GSD 4.0.1 (47)**. It is not reused as proof of new 4.1.0 behavior.

Original worktrees retain their observed local files and protected heads. Work proceeds in isolated lanes with one writer each. Historical failures and preserved diagnostics remain available without being confused with current successful receipts.

## Asana and next concrete completion work

Latest project status 1220860338096385, created 13:58:13.652 UTC, remains yellow/at risk: build 48 delivered, with system/caption/personal observations outstanding. Cloud notes read back exactly 13:55:25.467; Hebrew 14:01:32.728. Historical suffixes and private pre-update snapshots were preserved when rich-text limits required bounded status-prefix replacement.

Next autonomous work: owned Watch run, actual Share/system-host observations, official pre-consent startup probe if feasible, and one consolidated runtime-tested caption/fix candidate. Native remains the sole CI/Apple executor.

Remaining owner handoff: accept the GSD Owner Testing invitation and install the actual TestFlight build; use the normal GSD account on the physical iPad; complete the private Plugin's GSD OAuth consent; separately complete in-app Continue with ChatGPT consent so eligibility and an inference response can be observed. These distinct personal actions are not recorded as completed.
