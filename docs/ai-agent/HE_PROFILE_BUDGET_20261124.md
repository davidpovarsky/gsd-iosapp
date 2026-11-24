# Hebrew iPad acceptance time budget

The full Hebrew iPad profile contains the three localized UI checks plus the
same-account native signup, logout/login, closed-app server mutation, upload,
relaunch and account-deletion flow. Run 45354255968 observed approximately 550 seconds
of Hebrew test-runner bootstrap. Its English iPad common three-test summary was
approximately 617 seconds. A 1200-second command ceiling left only 33 seconds for the
additional account lifecycle. That limit is insufficient even after the confirmed
application startup crash is fixed.

Only the live-cloud Hebrew iPad command receives 1800 seconds. The other three
full profiles, and every AI-settings-only profile, retain 1200 seconds. The selected
methods, conditions, source/build provenance and successful-result requirements
are unchanged. Each profile records commandTimeoutSeconds in its receipt.

The native-acceptance job ceiling becomes 180 minutes. A conservative sum of the
existing configured command limits is:

| Part | Seconds |
| --- | ---: |
| Three 1200-second test commands plus one 1800-second command | 5400 |
| Four create/boot/bootstatus groups (120+120+300) | 2160 |
| Four summary/shutdown/delete groups (120+120+120) | 1440 |
| Initial simulator inventory | 120 |
| Late failure path: one command plus three cleanup commands, each TERM 15/KILL 10 | 100 |
| Total configured UI and cleanup envelope | 9220 |
| Remaining from the 10800-second job ceiling | 1580 |

The remaining 26 minutes 20 seconds cover pre-UI setup/build and artifact handling.
These are configured timeout envelopes, not a claim that operating-system
scheduling has a precise worst-case duration. Healthy execution does not wait
for a ceiling. Native-resume, startup-diagnostic and signed-release job limits
are unchanged; no retries or additional tests are introduced.

Crashes, thrown errors, unfinished XCTest outcomes, provenance errors and failed
cleanup still abort acceptance. Completed assertion failures remain false in the
full receipt. This budget change must be combined with the reviewed throwing
failure path for the async cloud test; it does not repair or conceal the startup
crash or the prior XCTest interruption stall.

The focused receipt covers Python syntax, exact reversible source changes and
budget arithmetic only. Runtime evidence remains required on the new immutable
application candidate.

