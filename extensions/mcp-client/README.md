# mcp-client

Connects pi to MCP servers declared in `.mcp.json` and registers each tool as
`mcp__<server>__<tool>`. Since #199, server lifecycle is **decoupled from the
session lifecycle**: a small eager core is pre-loaded, everything else is
discoverable via a catalog and loads on demand, then idle-stops.

## Server tiers

Each entry in `.mcp.json` (`mcpServers`) supports optional lifecycle metadata:

```json
"playwright-browser": {
  "command": "npx", "args": ["@playwright/mcp@latest"],
  "lazy": true,               // skip at startup; load on demand via mcp_load
  "idleTimeoutMs": 900000,    // idle-stop threshold (default 30 min)
  "purpose": "Browser automation",
  "whenToLoad": "verify/UX phases only",
  "cost": "~170MB pair while loaded"
}
```

- `lazy: true` → NOT connected at startup (one log line); loadable on demand.
- `idleTimeoutMs` → how long a lazy server can sit unused before the idle sweep
  disconnects it (default `30 * 60 * 1000`).
- `purpose` / `whenToLoad` / `cost` → catalog metadata, no connect needed.

`PI_MCP_SERVERS` still filters the eager set. Explicitly naming a lazy server
there (e.g. the `task` tool's `mcp_servers` param passes `gemini,cloudinary`)
**forces** it to load eagerly for that session.

### OAuth for remote servers (#595)

Remote HTTP MCP servers that require OAuth 2.1 authorization can be configured
with the `oauth` flag instead of a static `Authorization` header:

```json
"tortoise": {
  "url": "https://tortoise.example.com/mcp",
  "oauth": true,
  "purpose": "Semantic/epistemic memory graph",
  "cost": "FalkorDB"
}
```

When `oauth: true` is set, the extension performs RFC 9728 discovery on the
server's `/.well-known/oauth-protected-resource/<transport>` endpoint, follows
Dynamic Client Registration (RFC 7591) if supported, and completes an
authorization-code PKCE flow (RFC 7636).

For pre-registered public clients, you can supply a `clientId`:

```json
"my-server": {
  "url": "https://my-server.example.com/mcp",
  "oauth": { "clientId": "my-public-client" }
}
```

**Token storage:** Tokens are stored per-server under
`~/.pi/mcp-tokens/<origin>/` with `chmod 600` — never written to `.mcp.json`
or environment variables. The extension reuses the SDK's `OAuthClientProvider`
interface, which handles transparent refresh-token rotation on expiry.

**Re-authorization:** If a refresh fails (e.g. token revoked), the
`UnauthorizedError` surfaces a clear re-auth signal in the tool response.
Use `mcp_finish_auth {server, authorizationCode}` to complete the flow after
the user authorizes in their browser.

### Mixing auth modes

You can mix OAuth, static-header, and stdio servers in the same `.mcp.json`.
Each server's transport is selected independently:

| Config | Transport | Auth mechanism |
|--------|-----------|----------------|
| `url` + `headers` | HTTP (streamable) | Static header |
| `url` + `oauth` | HTTP (streamable) | PKCE+OAuth (auto-refresh) |
| `command` + `args` | stdio | None (inherits parent env) |

## Tools this extension registers

- `mcp_catalog` — list every declared server: name, tier (core/lazy), status
  (loaded / sleeping / not-loaded), purpose, when-to-load, rough cost.
- `mcp_load {server}` — start a lazy server on first use and register its tools
  (returns the `mcp__…` names — call them on the **next** turn).
- `mcp_finish_auth {server, authorizationCode}` — complete an OAuth PKCE
  authorization flow after the user authorizes in their browser.

Once a lazy server's tools are registered, they **self-heal**: if the idle sweep
stops the server, the next tool call transparently reconnects it.

## Pre-loaded core

`tortoise` (memory graph) is the only always-eager core server. `exa` (semantic search) was demoted to lazy (#419) — Perplexity is the primary search source; Exa loads on demand via `mcp_load` for semantic/scholarly/entity discovery. `tortoise` is launched
with `${TORTOISE_HOME}/.venv/bin/python3` (the venv has `fastmcp`; global
python3 does not).

## Cold-start retry (#802)

Eager connect makes **one initial attempt + one retry** per server. A remote
server is cold on its first request after idle — measured against the hosted
Tortoise MCP: first request after ~45s idle took **15.55s** (right at the 15s
default budget), after ~100s idle it stalled **35.4s** then returned a zero-byte
503, while warm latency was **0.30s**. The cold path therefore straddles the
default budget by design, so a single timeout is not an outage. Attempt 1 wakes
the server; attempt 2 (250ms later) lands on the warm path.

The retry is bounded to **2 attempts** so startup can never exceed ~2× the
per-server budget (15s default → ≤30s worst case, before transport teardown).
Deterministic config errors (e.g. a server with neither `command` nor `url`) are
not retried.

`timeoutMs` is the per-attempt cold-start budget knob and applies to **both**
attempts — set it higher for a server that reliably needs longer than 15s (e.g.
30s warm-up). If a server is still unavailable, the startup log names the
recovery command:

```
[mcp-client] MCP server 'tortoise' unavailable — continuing without it. Recover with: mcp_load tortoise (or raise "timeoutMs" in .mcp.json for a slow cold start).
```

`mcp_load <server>` reconnects on demand and registers the server's tools for
the rest of the session — the manual escape hatch when even the retry loses the
race.

## Tests

```
npx tsx extensions/mcp-client/resolution.test.ts
npx tsx extensions/mcp-client/lifecycle.test.ts
npx tsx extensions/mcp-client/oauth.test.ts
npx tsx extensions/mcp-client/eager-retry.test.ts
npx tsx extensions/mcp-client/oauth-refresh.integration.test.ts
npx tsx extensions/mcp-client/mcp-load.integration.test.ts
```

Run from the repo root — `resolution.test.ts` resolves `templates/.mcp.base.json`
via `process.cwd()`.