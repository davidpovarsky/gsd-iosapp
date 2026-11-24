# GSD native authentication guard and populated recovery — 2026-11-24

The four-line native password guard was deployed and verified at **20:23:00 UTC** from [published commit `e74abb292cfb10b43cf5dfa11fac5167caa98cad`](https://github.com/davidpovarsky/gsd-iosapp/commit/e74abb292cfb10b43cf5dfa11fac5167caa98cad). It enforces the existing **22-request / 15-minute per-IP pattern** before proxying `POST /api/collections/users/auth-with-password`, returning PocketBase's standard message envelope with HTTP 429 and `Retry-After: 900`.

Tested and active gateway SHA-256: `4bcc55288e28576aaacf24cd6657f254e6703637f732929b139ca78645b2a598`. Base commit: `b746c080473439708defc285ceee43e9165aa636`. The published tree is `733c19e396a3e5700a94aeb2f6a7cb358d0bca84`; fetched source bytes, tested bytes and the running service's file match.

## Why this repair is needed

The existing gateway limited signup and OAuth, while native password authentication streamed directly to PocketBase. A narrowly selected, read-only live configuration check at 19:53:54 UTC found PocketBase's limiter disabled. Only rate-limit fields were selected by SQL; no account rows or other settings were returned. An isolated instance of the exact PocketBase 0.40.6 binary and deployed code reproduced 24 failed native logins followed by a successful correct-password login without throttling.

GSD and Lorvex require different identity handling. Real isolated GSD account requests showed that this PocketBase collection accepts distinct case-sensitive email identities and rejects surrounding whitespace. PocketBase also supports multiple request-body bindings. The repair leaves that interpretation and streaming entirely with PocketBase. It adds no canonicalization, account-key parser, request buffering or new body-size policy.

Lorvex's own store explicitly trims and lowercases account email, so its existing account buckets now share that canonicalization and retain fixed-size hashes. Copying that identity rule into GSD would join distinct valid accounts.

## Focused HTTP verification

The **same six limiter tests** passed four and failed two against the exact deployed gateway snapshot. The repaired candidate passed **21/21 tests**: six limiter cases and fifteen affected OAuth, localization, persistent-grant and MCP contracts.

The new tests exercise actual HTTP requests and upstream-call counts, rather than assigning limiter counters. They cover:

- Seven real OAuth failures per pending grant; a blocked attempt never reaches the account service.
- The shared OAuth IP window across fresh grants, and signup's separate hourly window.
- Native attempts across JSON, form, multipart, XML, malformed/ambiguous bodies and a Unicode payload with 128 KiB of extra content.
- Exact original body-byte and content-type forwarding for every allowed request.
- Native HTTP 429 before upstream dispatch, independent fixture IP budgets, the exact cooldown boundary and recovery.
- Unchanged refresh, signup, CRUD and OAuth budgets while the native budget is exhausted.

The fixture uses a loopback account-response stub to count dispatches; the gateway and its clock/limiter implementation are real. Clock advancement occurs only in the fixture. Normal native authentication is independently covered against the actual PocketBase binary in the populated restore probe below.

Fixed log SHA-256: `c6dd4b280f81cba5bb3439bbe195f613c015469ff59485146438d2c8cffb569d`.

From `cloud/gateway`:

```sh
node --test --test-concurrency=1 --test-reporter=tap rate-limit.test.mjs gateway-security.test.mjs oauth-localization.test.mjs mcp-auth.test.mjs
```

The guard is explicitly per-IP. Successful and failed password attempts share its fixed window; it does not promise a distributed or per-account limit. The existing trusted-IP derivation is reused. Native refresh is excluded, so an active session is not forced through this login budget.

## Verified ingress boundary

The installed client and running daemon both report Tailscale 1.104.5, commit `78838476328d1a97dc05400ad23086a9dbe616da`. Current Serve/Funnel configuration routes HTTPS `/gsd-cloud` directly to the gateway's loopback listener `127.0.0.1:8770`. The gateway does not listen on an external interface.

The [exact installed Tailscale source](https://github.com/tailscale/tailscale/blob/78838476328d1a97dc05400ad23086a9dbe616da/ipn/ipnlocal/serve.go) passes the connection source address through its HTTP context. The reverse proxy's `Rewrite` calls `addProxyForwardedHeaders`, which uses `Header.Set` to replace `X-Forwarded-For` with that address. The configured ingress therefore overwrites an incoming client-supplied value before the existing gateway rate helper reads it. This conclusion binds the installed version and current configuration; it does not generalize to other proxies or privileged local callers. No production authentication attempt or header logging was used for this check.

## Populated online recovery with real account services

`cloud/test_backup_acceptance.py` runs the exact deployed gateway, hooks, migrations and backup code with the actual PocketBase 0.40.6 binary. Every listener, SQLite file, account, key and log belongs to a temporary fixture; the production database and credentials are not used.

The source stays running with committed WAL while `backup.py` produces and verifies its archive. The fixture holds **two users, two tasks and two library views**, together with **three OAuth clients, one pending grant, two access sessions and two refresh sessions**. All thirteen SQLite tables and the complete schema preserve their logical digest on initial restore. The gateway key and state file preserve exact bytes.

After starting the restored services, existing native sessions still authenticate and see only their own task. Existing MCP sessions decrypt their stored upstream credential and read the correct account. Refresh rotates successfully and rejects replay. Replaying the saved versioned view writes returns 412 without duplicates.

Candidate-run results:

| Receipt | Value |
|---|---|
| SQLite integrity | ok |
| Logical database SHA-256 | `174751db6a0a7ff7e1737f7645bcde562e36f2b8d6bbb5f3ca4c08fc0656d5af` |
| Archive SHA-256 | `c7140a93ac3a5a738b05b59625d3aa271dfa29f6d389b01c9ac2e53015db477e` |
| Archive size | 34,795 bytes |
| Restored database size | 196,608 bytes |
| Backup script SHA-256 | `efea842528ce51a2f8a358c47216419b97bab5c8f46520720e690352f09e4e4a` |
| Full test log SHA-256 | `dda5b9516d9fbea9d908d15e6e5d7ef44457ee9e7a62b812d35cf7ea2961bb4d` |

The backup directory is mode 0700 and the archive mode 0600. Archive and extraction size caps bound fixture storage. Processes and synthetic data are removed on completion.

```sh
python3 -B cloud/test_backup_acceptance.py --pocketbase <path-to-pocketbase-0.40.6>
```

The previous populated recovery proof at [`540bde78`](https://github.com/davidpovarsky/gsd-iosapp/commit/540bde78d1eb7b90de9eb12d20d319d1c439f1f4) remains valid evidence. This new probe extends it with preserved encrypted OAuth state and actual use of restored access/refresh/native credentials. It is not a provider-volume restore or a physical-device migration.

## Live deployment and current operations

Only `cloud/gateway/server.mjs` was replaced, with a protected rollback copy, preserved ownership/mode, a staged syntax check and one successful service restart. The process restarted and the active source hash matches the published tested file. Public health returned 200; issuer/protected-resource discovery, MCP protocol 2025-11-25, protected catalog 401 and the unauthenticated `invalid_token` linking challenge passed.

There were **zero production password-authentication requests** in the deployment verification. PocketBase settings, database/configuration and native checkout were not changed. The deployment receipt SHA-256 is `de34f33fd0ebcd248a74d20c6e5da71db7fac0ed857e996221443cae4a186b22`.

At **20:23:49 UTC**, Lorvex Cloud, the GSD gateway and PocketBase were active/running and enabled. Both public health endpoints returned 200/ok. Both backup timers were active/waiting and enabled; their next observed triggers were **2026-11-25 03:22:53 UTC for Lorvex** and **03:23:05 UTC for GSD**.

| Filesystem | Available bytes | Available MiB |
|---|---:|---:|
| Root | 1,052,016,640 | 1,003.281 |
| Data | 1,999,716,352 | 1,907.078 |

Those point-in-time measurements exceed the previously recorded 768 MiB root and 512 MiB data admission thresholds. They are not a capacity reservation or prediction. No backup, restore or cleanup was repeated for this operations check. The full safe [operations readback](evidence/cloud-auth-backup-20261124/operations-readback.json) preserves timer dates and capacity measurements.

## Client behavior and remaining acceptance

The existing native PocketBase client decodes the standard 429 message envelope into its typed error. The sign-in state cancels preparation and shows the existing localized, credential-safe generic failure message. Tokens are saved only after success. This server change requires no native source or binary edit.

Personal-device installation, migration and personal ChatGPT Cloud consent remain separate acceptance criteria. Complete source hashes, baseline/fixed counts and both original/candidate restore receipts are in [the JSON evidence](evidence/cloud-auth-backup-20261124/acceptance.json).
