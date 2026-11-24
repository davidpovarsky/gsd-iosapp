# Existing Mac route for the unchanged Watch smoke

This routing follow-up uses the existing authorized Scaleway Mac. It does not create a host, rebuild GSD, alter application or test products, or repeat the accepted native suites.

## Exact inputs

- Application source: `71b1b7ce4adf7bea2ddacfc683a69906d6acd6ae`, GSD 4.1.0 (48).
- Successful native producer: [45397928701](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45397928701).
- Previous reviewed Watch harness: `1e2ac50ec297f68283138d47475341985e00b661`.
- The Watch helper and its accepted source/artifact/hash/cleanup gates remain byte-identical.
- Only the Watch job's runner label and explicit process-scoped developer directory change. Other jobs, shared concurrency, read permissions, timeout and artifact policy remain unchanged.

## Existing environment and the missing component

The selected global Xcode remains `/Applications/Xcode.app/Contents/Developer`, version 27.0 / 27A266a. The previously staged 27.1 / 27A9275 compiler remains available for separate iOS test projections; it is not needed to rebuild anything for this Watch launch.

The initial Mac inventory had compatible iOS 27.0 / 24A434 but no watchOS runtime. Apple's official simulator catalog identified the final arm64 watchOS 27.0 / 24R362 package, 3,825,263,104 bytes. One documented command installed that runtime:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -downloadPlatform watchOS -buildVersion 27.0 -architectureVariant arm64
```

Actual post-install inventory at 2026-11-24 14:45:10 UTC reports watchOS 27.0 / 24R362 available. The matching iOS runtime remains available, global selection is unchanged, and free storage is 368,117,493,760 bytes. The action monitored a 20 GiB free-space floor, used an owned log/receipt directory, and required no personal or legal consent. See the adjacent runtime receipt.

## One owned execution

The job uses only the unique `gsd-watch-scaleway-20261124` label. Registration must use the existing unregistered GitHub runner software, an ephemeral GSD-repository registration and a new owned work directory. Existing prior work directories and signing material are preserved. Registration credentials are transferred in process memory over the already authorized SSH route and never included in repository files or public logs.

The helper selects the already available matching phone/watch 27.0 pair, creates only its owned simulators, restores the pinned accepted binaries, and records normal English/Hebrew launch, five-second process liveness, raw screenshots and cleanup. It does not establish WatchConnectivity, widget timelines, physical Watch installation, Siri or VoiceOver.

The earlier managed-route request [45411887071](https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45411887071) failed while its Watch job was cancelled without an assigned runner or any executed steps at 14:29:34 UTC. The cause is unknown. This routing follow-up is a separate attempt; no runtime success is inferred from that cancelled history or from the runtime installation itself.

Official references: [Apple component installation](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components), [Apple simulator catalog](https://devimages-cdn.apple.com/downloads/xcode/simulators/index2.dvtdownloadableindex), [GitHub ephemeral runners](https://docs.github.com/en/actions/reference/runners/self-hosted-runners).
