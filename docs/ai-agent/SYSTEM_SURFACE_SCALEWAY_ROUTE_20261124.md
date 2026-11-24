# Existing Mac route for GSD system-surface discovery

The app and embedded targets remain the immutable products from source `71b1b7ce4adf7bea2ddacfc683a69906d6acd6ae`, accepted by native run `45397928701`. The supplemental Swift and helper are the reviewed source on `760ba0763fceb5d756801f78aa722bb67d662470`. This route changes only the workflow's runner label, compiler process environment and explicit XCTest driver argument.

- Runner label: `gsd-system-surfaces-scaleway-20261124`; one GSD-only ephemeral registration with no default labels, using a new owned work directory on the existing authorized Mac.
- Test-runner compiler: `/Users/m1/builds/xcode-27.1.Zoqh5zoP/Xcode.app/Contents/Developer`, Xcode 27.1 / 27A9275.
- XCTest, simulator and cleanup driver: `/Applications/Xcode.app/Contents/Developer`, Xcode 27.0 / 27A266a, passed through the helper's reviewed optional driver argument.
- Global Xcode selection stays unchanged. Existing runner work directories and unrelated projects remain outside this run's ownership.
- Only the self-contained supplemental UI test bundle is built. Restored app and extension bytes remain immutable and all five bundle audits are enforced.
- This is a single Hebrew iPhone system-surface discovery and text Share Add/Cancel check. WidgetKit, web-URL Share, Shortcuts and VoiceOver cannot be promoted from discovery to functional acceptance.
- The existing safe-diagnostic sanitizer and exact public artifact paths remain unchanged. Full native acceptance and signing are not rerun by this workflow.

The prior Watch smoke `45423742737` completed successfully. Independent postrun readback at 2026-11-24 15:23:07 UTC confirmed its two owned simulator UUIDs and pair absent, its ephemeral runner deregistered, its local runner configuration removed, and original work directories preserved. A fresh own-runner and active-work guard is still required before this separate supplemental registration and dispatch.
