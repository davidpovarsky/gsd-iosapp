# GSD integration checkpoint — 2026-11-24

## Exact scope

Integration branch: `feat/gsd-integration-20261123`. Preserved starting work includes cloud checkpoint `86794659ad55ad18033a0f8368fee114a2c97c0b`, Hebrew `d99527b4977c70d23d39522c56c0c8b6ace2c793` and Unicode repair `9fda3bae2f200e7b645b4f2b7ed8bcc39d896b3c`. The former base branch's four dirty handoff files were separately committed as `b90d2a520978c00ee399c654472243b76c09b407`; unrelated backups and logs were preserved.

The integration merges the tested cloud changes through `cd039e1b688c570fea005679af6549703ac827ad`, canonical SDK consumer commit `f62b1de4e1888ebb39459d60455fb463ee2c88f8`, and native/signing preparation `8cd9b2b7d2980e8487eaf622f6ace820e8ff139a`. Head before the host review fixes was `86cccffaf6422ec5f8487c288cc72e4572134465`.

## Production cloud and private plugin

Production Oracle source `0e8911a33fc29eed8dfd969e43a0e6a86b63c9a4` was deployed through the existing authorized Windows SSH account. The two GSD service restarts used its existing sudo rights. SentinelX policies were not changed. The pre-existing Lorvex services and legacy bridge stayed healthy.

The public endpoint passed nine real PocketBase/OAuth/MCP acceptance checkpoints, including all 22 tools, PKCE, refresh/revoke, version conflicts and two-account isolation. The public ingress test used normal TLS verification and cleaned synthetic accounts. This is server evidence; it does not prove native-device synchronization.

The existing private plugin was updated and read back as version `0.2.0`, release `pluginrel_6b04d42b006c81919d7c1f65c062159a`. Identity, author and private audience were preserved. It uses OAuth DCR at:

https://torah-social.tail0a6c7d.ts.net:10000/gsd-cloud/mcp

Scopes: `gsd.read gsd.write offline_access`. The in-app connection sheet now explains normal GSD-account login. The root UI no longer starts the legacy device-pairing polling loop.

Plugin: https://chatgpt.com/plugins/plugins_6b0396bab7888191a5a7386c54a8475f

A user's actual Connect consent inside ChatGPT remains unverified.

## Native ChatGPT plan connection

The host adds official Continue with ChatGPT, a bounded loopback listener on 127.0.0.1, a shared account manager, atomic Keychain persistence, multiple registration mappings, model selection, refresh rotation, sign-out/revocation and permission disclosure. OpenRouter and other API options remain available. There is no cookie-based authentication or automatic paid API fallback.

The canonical Hanlin SDK is pinned to `caa4faa509ebf5ba4164408734bb6e0dd3662203`; the original installer verifies the lock. Provider requests use the official Responses transport and preserve the original 22-tool agent.

Focused review found and fixed:
- stale browser/listener/cancellation callbacks completing a later sign-in attempt;
- persisting an exchange response after the user canceled sign-in;
- concurrent account managers rotating the same stored registration;
- retained assistant transcripts crossing ChatGPT account changes;
- early refresh attempts before earliest_refresh_at;
- local inference continuing after a failed Keychain sign-out write.

No actual personal ChatGPT grant, model response or account-plan eligibility has been verified. The real system-browser to loopback flow remains a live acceptance requirement. The implementation must not be described as verified subscription usage merely because it compiles.

Official contract: https://developers.openai.com/siwc/token-sharing-open-source

## Hebrew and RTL source evidence

The catalog now contains **1,000 unique keys** across the five Localizable tables, including 976 app keys and 14 additional App Shortcuts phrases. The latest audit checks 1,126 app literal references plus the widget, share and watch references. New account screens, sign-in states, Keychain failures, provider error wrappers, consent text and callback completion copy have Hebrew translations. Diagnostic codes and user-entered content remain verbatim.

The settings email value uses LTR text inside the inherited RTL row, and chart axis descriptors are localized. All five target catalogs remain separate. XcodeGen owns generated resource configuration.

Evidence from SentinelX `job_e14237b0d146`:
- eight changed host Swift files passed direct frontend syntax parsing;
- localization audit passed, including placeholder and Unicode checks;
- 1,000 unique keys were counted from the actual integration catalogs.

The Windows Swift driver timed out during an earlier attempt; the existing direct frontend succeeded. A later narrow parse attempt after environment-injection modifiers also timed out during process execution; the final Apple gate must compile those modifiers. The timeout is not a pass and is not an Xcode result. English/Hebrew iPhone/iPad runtime screenshots, accessibility, gestures and compiled bundle resources remain owned by the single native CI lane.

## Apple release state

The verified owner route uses team `NA6HPWARQ2`, confirmed by the existing Lorvex distribution certificate and profile. Source value `52HVJ3VDSM` did not match that evidence. Five GSD App IDs and six protected GitHub secret names were prepared; secret values are not in source or receipts.

Subsequent evidence from the authorized INT lane supersedes the earlier portal blocker: App Store Connect app `6838520892` and App Group `77VDF9H5QW` (`group.com.itorah.gsd`) were created and associated with all five bundle IDs. Readiness run [45292829536](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45292829536) succeeded; every generated profile contained the signed App Group entitlement. The current lane's earlier canceled browser password request did not establish this; the separate successful Apple readiness receipt does.

Native run [45293412602](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45293412602) passed all 13 ChatGPT contract tests after `cddebd06288b462deafa7fa9b26c340705f7c86d` fixed a throwing Swift Testing assertion. It then found a private-email registration decode failure. Fix `5be3a394d05bf58f6ffbe70feea5cc29654797ab` decodes the registration ID and reads the email only from authenticated login; both fixes are being preserved in this integration. Its follow-up run [45294577877](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45294577877) failed downloading a GRDB SQLite submodule before runtime acceptance. These prior runs did not contain the new host ChatGPT account UI and cannot validate it.

No signed IPA, App Store Connect processed build or TestFlight tester availability is claimed. Version 4.1.0 (48) remains proposed until the Apple app/build preflight succeeds.

## Remaining acceptance gates

1. One exact-commit Xcode/SDK/sync/UI validation run, including CloudLibraryOrderingTests.
2. Real native bidirectional sync, closed-app cloud write and two-account separation.
3. Review English/Hebrew iPhone/iPad screenshots and runtime behavior.
4. Personal ChatGPT OAuth grant and inference eligibility; actual plugin Connect consent.
5. Fresh Apple build-number/profile preflight, signed archive/export, upload and TestFlight processing/tester availability. Portal prerequisites now have a successful readiness receipt.
6. Record the corresponding receipts in Asana before closing any task.

The prior successful run 45119548923 is preserved as evidence for GSD 4.0.1 (47), not reused as proof of the new changes.
