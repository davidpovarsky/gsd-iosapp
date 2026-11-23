# GSD MCP subpath correction — 23 November 2026

## Problem and scope

The public GSD bridge is mounted at
`https://torah-social.tail0a6c7d.ts.net:10000/gsd`; the same host's `/`
route serves another app. GSD's consent form previously used the absolute
action `/oauth/approve`, which sent the approval to the other service.
The form now uses the relative action `approve`, which resolves beside
the authorization page as `/gsd/oauth/approve`. No native app, task data,
credentials, or other app files change.

OAuth issuer discovery has a separate deployment requirement. For issuer
`https://torah-social.tail0a6c7d.ts.net:10000/gsd`, RFC 8414 section 3 requires
`https://torah-social.tail0a6c7d.ts.net:10000/.well-known/oauth-authorization-server/gsd`.
The path-appended `/gsd/.well-known/oauth-authorization-server` endpoint
alone does not meet that requirement. The three standard MCP discovery
candidates returned 404 during the read-only production probe.

Sources:

- https://www.rfc-editor.org/rfc/rfc8414.html#section-3
- https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization

## Additive deployment routes

The release owner must deploy `bridge/server.mjs` to the GSD service and
restart only `gsd-mcp-bridge.service`. Add these routes without resetting
Funnel or replacing the `/` or `/gsd` handlers:

```sh
sudo -n tailscale funnel --yes --bg --https=10000 \
  --set-path=/.well-known/oauth-authorization-server/gsd \
  http://127.0.0.1:8768/.well-known/oauth-authorization-server

sudo -n tailscale funnel --yes --bg --https=10000 \
  --set-path=/.well-known/oauth-protected-resource/gsd/mcp \
  http://127.0.0.1:8768/.well-known/oauth-protected-resource
```

The first alias is necessary for RFC 8414 discovery. The second supports
the canonical resource-metadata fallback. The existing `WWW-Authenticate`
metadata URL remains valid and unchanged. Installed `tailscale funnel
--help` explicitly supports a full target URL including a path.

After applying, inspect the actual Funnel configuration, verify the
canonical metadata returns 200 with the exact GSD issuer, and exercise
OAuth using the form's rendered action. Confirm the root app's health and
metadata remain unchanged. The worker did not change live routes or deploy.

## Verification receipt

Owner: GSD subpath worker. Base:
`57cc1b14ee875a6fa340b2788d67ea0f78a5f131`.

`MCP-SUBPATH-RED`: added a prefix-stripping reverse-proxy regression test,
then ran `node --test bridge/server.test.mjs` against the unchanged server.
The original direct-origin test passed. The new test failed at the consent
POST with **418 rather than 302** because it reached the intentionally
unrelated root service.

`MCP-SUBPATH-GREEN`: after the relative-action fix, the same command passed
both tests with no failures, cancellations, or skips. Environment: Windows,
Node v22.17.0.

The new test checks the actual `WWW-Authenticate` challenge, canonical
resource and issuer metadata routed to the GSD backend, dynamic client
registration, the browser-resolved consent-form action, PKCE code exchange,
authenticated tool discovery, and a synthetic dashboard request through
the device polling/result transport. It asserts that no GSD request
escapes to the unrelated root service. The proxy and synthetic credentials
exist only in the isolated local test and are removed on exit.

Live public OAuth completion and physical iPad pairing remain release
checks; this local regression receipt does not claim they passed.
