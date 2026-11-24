# Native ChatGPT pre-consent browser probe

This separate workflow uses the accepted immutable GSD build 48 products from app source `71b1b7ce4adf7bea2ddacfc683a69906d6acd6ae` and native acceptance run `45397928701`. It builds only the self-contained `GSDChatGPTPreConsentUITests` bundle. It does not rebuild the app, extensions or packages, and it does not repeat the 13 native acceptance tests.

The exact Swift source is `2595216a17ee577446d7eaa43be7ebd36969270a` and its SHA-256 is `01053bfaabfb167e01894f9749b3b1b7fb0462947aa99105b806c7345b9311b0`. The controller is the reviewed `311c9b91b96a63a1498b37b31921ce42ed0d4dbd` helper. Its original surface utility dependency is materialized outside the checkout from `93a46c1e029387d54df9fb8b9be793c378658d5e` and verified against full SHA-256 `dcb677bb6dea2070dac1611070f3372914ff3581626ea4a23c7e0a35f4d1e783` before import. No newer helper is substituted.

## Execution boundary

One unique, ephemeral GSD runner label on the existing authorized Mac executes one English iPhone simulator test serially after the prior GSD job and owned cleanup. The compiler is the existing staged Xcode 27.1 / 27A9275. XCTest and simulator commands use the existing default Xcode 27.0 / 27A266a. Both exact paths and versions are checked and recorded without changing global selection. The simulator runtime must be iOS 27.2 / 24B8117.

The one test opens the native Continue with ChatGPT path, observes official browser chrome if available, performs ordinary cancellation, and checks disconnected app state again after relaunch. It enters no personal credentials and grants no authorization. A successful probe does not verify sign-in page content, subscription eligibility, an authorization grant or inference. Unknown host presentation or a public error produces an honest incomplete/failure result.

## Publication boundary

Only the seven exact public files listed in the workflow can be uploaded: safe summary, cleanup, observation and manifest JSON plus three app-state PNGs. Raw XCTest logs, xcresult bundles, browser diagnostics and restored products stay in a separate mode-0700 private directory beneath RUNNER_TEMP. No browser screenshots or full hierarchy are requested by the probe, and no raw diagnostic path is uploaded. The controller validates the closed observation schema before export. The output never contains a full native acceptance or signed-release marker.

The test has a 600-second bounded invocation and a checked setup budget; individual restoration, build and cleanup operations retain their existing bounds. The workflow allows 75 minutes for those bounded stages and final safe artifact upload. Simulator creation, reconciliation and cleanup apply only to the exact owned UUID. Postrun runner deregistration and old-work-directory preservation remain separate executor checks.
