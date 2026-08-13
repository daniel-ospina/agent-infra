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

## Tools this extension registers

- `mcp_catalog` — list every declared server: name, tier (core/lazy), status
  (loaded / sleeping / not-loaded), purpose, when-to-load, rough cost.
- `mcp_load {server}` — start a lazy server on first use and register its tools
  (returns the `mcp__…` names — call them on the **next** turn).

Once a lazy server's tools are registered, they **self-heal**: if the idle sweep
stops the server, the next tool call transparently reconnects it.

## Pre-loaded core

`exa` (search) and `tortoise` (memory graph) stay eager. `tortoise` is launched
with `${TORTOISE_HOME}/.venv/bin/python3` (the venv has `fastmcp`; global
python3 does not).

## Tests

```
npx tsx extensions/mcp-client/resolution.test.ts
npx tsx extensions/mcp-client/lifecycle.test.ts
npx tsx extensions/mcp-client/mcp-load.integration.test.ts
```
