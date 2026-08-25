<!-- research-path: none (live process audit + code read of extensions/mcp-client + builtin-tools; counts recorded 2026-08-13) -->

# fix(extensions/mcp-client): config-driven MCP tiering — core eager, rest lazy/on-demand, idle sweep, catalog (#199)

**Goal:** Decouple MCP server lifecycle from pi session lifecycle. Idle sessions/sub-agents hold only a small eager core (`exa` + `tortoise`); heavy servers (`playwright-browser`, `gemini`, `brave-search`) are discoverable via a catalog and load on demand, then stop after an idle timeout. Recovers ~3.7 GB on this machine today (35 pi sessions → 74 MCP procs: 50 exa + 24 playwright, ≈3.7 GB RSS).

**Team:** organisation-design-team
**Status:** SCOPED + PLANNED (implementation pending)

---

## Problem Statement

`extensions/mcp-client/index.ts` `connectAll()` eagerly connects to every server declared in `.mcp.json` at each pi process startup. `extensions/builtin-tools/index.ts` `task` spawn copies `...process.env` into the child, so sub-agents inherit no `PI_MCP_SERVERS` and each child pi re-loads all 5 servers — 1:1 per session, chains 3-deep. Servers stay alive while the session is idle (only `session_shutdown` disconnects). Three of the five declared servers are dead on every launch: `tortoise` (global `/usr/bin/python3` lacks `fastmcp`; the tortoise `.venv` has fastmcp 3.4.6 and `tortoise.mcp_server` imports clean), `gemini` (npx cache permission), `brave-search` (package renamed). The same 5-server set is declared in 3 places (agent-infra `./.mcp.json`, tortoise `./.mcp.json`, `templates/.mcp.base.json` → `~/.pi/agent/.mcp.json` via `pi-bootstrap/setup.sh`; the fallback is currently missing on this machine).

## Design

### 1. Config-driven tier metadata

Each `.mcp.json` server entry gains optional fields (ignored by older extensions, so per-repo configs stay compatible):

```json
"playwright-browser": {
  "command": "npx", "args": ["@playwright/mcp@latest"],
  "lazy": true,
  "idleTimeoutMs": 900000,
  "purpose": "Browser automation (navigate/click/screenshot)",
  "whenToLoad": "verify/UX phases only",
  "cost": "~170MB pair while loaded"
}
```

- `lazy: true` → NOT connected at startup; connectable on demand.
- `idleTimeoutMs` → idle-stop threshold (default 30 min; playwright set lower).
- `purpose` / `whenToLoad` / `cost` → catalog metadata (no connect needed).
- Base template (`templates/.mcp.base.json`) marks `playwright-browser`, `gemini`, `brave-search` lazy; `exa` + `tortoise` stay eager (core). Agent-infra `./.mcp.json` mirrors it. `PI_MCP_SERVERS` remains the eager-only filter; servers absent from it but declared become lazy (no connect, still in catalog).

### 2. On-demand load — `mcp_load` tool

New tool registered by the mcp-client extension (available to interactive sessions AND sub-agents, print mode included):

- Param `server` (name from catalog). Connects via the existing `connectServer()` path (same 15s/`timeoutMs` + orphan cleanup), then `listTools()` and `pi.registerTool()` each tool under the real `mcp__<server>__<tool>` name — naming convention preserved because skills and `skill-enforcer` reference `mcp__*` literally.
- Returns the list of registered tool names so the model can call them on the next turn (pi's per-turn tool snapshot).
- `registerTools()` is refactored into a per-server method shared by eager connect and `mcp_load`.

### 3. Catalog — `mcp_catalog` tool + startup line

- `mcp_catalog` returns a table of all declared servers: name, tier (core/lazy), purpose, whenToLoad, cost, status (loaded | idle | sleeping). Static from config; no connection required.
- Startup logs one catalog line per lazy server skipped (replaces today's silent load).

### 4. Idle sweep

- 60s `setInterval` in the manager: for connected lazy servers with no tool execution within `idleTimeoutMs`, disconnect via the **existing** per-server close path — `client.close()` with the #36 5s forced timeout + #92 orphan-kill. **No new teardown code.**
- Every lazy-server tool execution resets a `lastUsed` timestamp (wrapper in the tool execute closure).
- On next `mcp_load`, the server reconnects fresh.

### 5. Sub-agents (option B)

- No builtin-tools code change required: the child inherits `PI_MCP_SERVERS` (now the parent's core list) and the same tiered config, so it eagerly loads only exa+tortoise and gets `mcp_catalog`/`mcp_load` for everything else.
- The `task` tool's existing `mcp_servers` param still forces eager load for skills that need it up front (e.g. carousel-b2b-images passes `gemini,cloudinary`) — update its description to note lazy servers can also be loaded mid-run via `mcp_load`.

### 6. Dead-entry fixes

- `tortoise`: entry → `command: "${TORTOISE_HOME:-${HOME}/Documents/GitHub/tortoise}/.venv/bin/python3"` (verified: venv has fastmcp 3.4.6; `tortoise.mcp_server` imports). Same edit needed in tortoise repo's own `./.mcp.json` (cross-repo note).
- `brave-search`: → `@brave/brave-search-mcp-server` (new package name) in base template; keep `BRAVE_API_KEY` env.
- `gemini`: chmod the stale npx cache dir + verify a fresh `npx -y @houtini/gemini-mcp` launches; if still broken, drop from base template (keep in repo-local configs for those who fix it).

## Wiring

| Component | File | Change |
|---|---|---|
| Tier parsing, lazy skip, `mcp_load`, `mcp_catalog`, idle sweep, per-server close refactor | `extensions/mcp-client/index.ts` | ~200–250 lines; `connectAll` filter + new tools + interval; `registerTools` → per-server |
| Unit tests: tier parse, `mcp_load` register, idle sweep (fake timers) | `extensions/mcp-client/lifecycle.test.ts` (new) | follows `resolution.test.ts` conventions (tsx, assert/strict, no framework) |
| Integration: real stdio mock server — lazy absent at startup → load → call → idle disconnect → reload | `extensions/mcp-client/mcp-load.integration.test.ts` (new) | |
| Base config: tier fields + tortoise venv python + brave rename | `templates/.mcp.base.json` | |
| Repo-local parity | `.mcp.json` (agent-infra root) | same tier fields |
| Re-install base config path | `pi-bootstrap/setup.sh` | unchanged logic; re-run note in README |
| Task tool description | `extensions/builtin-tools/index.ts` | doc-only: mcp_servers param note (lazy vs eager) |
| Docs | `extensions/mcp-client/README.md` (or MEMORY.md line) | tier fields, catalog, mcp_load usage |
| Cross-repo (out of agent-infra PR) | tortoise `./.mcp.json` | venv python + tier fields (note + tortoise issue) |

## Sequencing vs #191 (sub-agent exit hang on MCP disconnect timeouts)

Both touch `extensions/mcp-client/index.ts`. **Contract with #191:**
1. Do NOT modify `disconnectAll`'s forced-close semantics, the 5s `DISCONNECT_TIMEOUT_MS`, or `buildMcpServerEnv`/`getAllowedServers` (test-pinned).
2. Idle-stop MUST reuse the exact same per-server close path #191 is hardening (client.close + #36 timeout + #92 orphan-kill) — a shared `closeServer(name)` helper is the natural seam.
3. Recommended order: **#191 merges first** (it makes shutdown reliable), then #199's per-server close refactor lands on top; if parallel, both implement `closeServer(name)` against the same semantics and merge-tests will catch drift.
4. Share the real-sub-agent test harness between #191's e2e (exit timing) and #199's mcp-load integration (load/disconnect) to avoid two bespoke sub-agent spawn rigs.

## Test Plan

| Surface | Test Layer | Expected |
|---|---|---|
| Idle MCP count | smoke (`ps` on live session) | idle session/sub-agent holds exa+tortoise only |
| Lazy skip at startup | unit | lazy servers not connected; log line per skipped server |
| On-demand load | integration | `mcp_load playwright-browser` → `mcp__playwright-browser__*` registered + callable |
| Idle sweep | unit (fake timers) | server disconnects after `idleTimeoutMs` without calls; timer resets on call |
| Reload | integration | after idle disconnect, `mcp_load` reconnects and works |
| Catalog | unit | lists all declared servers with tier/purpose/cost/status |
| Sub-agent spawn | smoke (`ps` under child pid) | 0 playwright procs under child unless loaded |
| Startup | config-validation | clean logs, no failed-launch noise (dead entries fixed) |
| Tortoise MCP | integration | `mcp__tortoise__tortoise_query` answers after load (venv python fix) |
| Regression | existing `resolution.test.ts` | unchanged resolution + env semantics |

## Risks

- **`pi.registerTool` mid-session:** new tools may only appear in the LLM's tool snapshot on the NEXT turn after `mcp_load` returns. Mitigation: `mcp_load` returns the registered names explicitly; spike-test dynamic registration first (smallest risk item, done in implementation step 1).
- **Idle sweep vs #191 hang:** mitigated by the shared close-path contract above.
- **Base template change reaches other machines only on next `setup.sh` run** — re-run documented; repo-local `.mcp.json` unaffected until edited.
- **Configs in other repos (tortoise) drift** — cross-repo note + tortoise issue; agent-infra sessions get the fix via base template regardless.
- **Skills that expect eager heavy servers** (carousel passes `gemini,cloudinary` to `task`) — still supported via `mcp_servers` param; doc note only.

## Verification

- `npx tsx extensions/mcp-client/resolution.test.ts` — existing, must stay green.
- `npx tsx extensions/mcp-client/lifecycle.test.ts` + `mcp-load.integration.test.ts` — new suites green.
- Manual smoke: start pi with base config → `ps` shows exa+tortoise only; `mcp_load playwright-browser` → pair appears; wait past idleTimeoutMs → pair gone; `mcp_load` again → works.
- Dispatch a `task` sub-agent → child process tree has 0 playwright (unless loaded in prompt).
- Clean startup log: no `Failed to connect to MCP server` lines for tortoise/brave-search/gemini after fixes.
