---
title: "Plan: #286 — task sub-agents default to PI_MCP_SERVERS=none (no eager MCP connects)"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-08-16
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-286, builtin-tools, mcp-client, subagent, task-tool
---

# Plan: #286 — task sub-agents must NOT eagerly load the parent's MCP servers

## Goal

Task-tool sub-agents currently inherit the parent's `PI_MCP_SERVERS` (empty in most sessions) when the `mcp_servers` param is absent → the mcp-client eagerly connects ALL non-lazy servers (extensions/mcp-client/index.ts `classifyServers` treats a missing allowlist as "load all"). Cold MCP connects hang ~15min, block the child's extension startup, starve the heartbeat marker stream, and trigger false first-message cuts. Fix: children default to `PI_MCP_SERVERS=none` (zero eager connects) and opt into servers explicitly via the `mcp_servers` param or mid-run `mcp_load`.

## Edits

### 1. `extensions/builtin-tools/index.ts` (canonical live file — the worktree copy is a symlink to main)

**a. subAgentEnv MCP wiring (~L2100):** replace the conditional set with an unconditional default:

```ts
// #286: children default to PI_MCP_SERVERS=none — a missing allowlist makes
// mcp-client eagerly connect ALL non-lazy servers (classifyServers treats
// undefined as "load all"), and cold connects hang ~15min, blocking child
// startup and starving the heartbeat marker stream (false first-message cuts).
// Children opt into servers explicitly via the mcp_servers param or mid-run
// mcp_load (documented lazy path).
subAgentEnv.PI_MCP_SERVERS = params.mcp_servers ?? "none";
```

**b. `mcp_servers` param description (~L2032):** replace the false "inherits parent's PI_MCP_SERVERS by default — sub-agents get the eager core (exa+tortoise)" claim with the new contract: default is `none` (zero eager connects, deterministic fast startup); naming servers forces them eager; everything else loads mid-run via `mcp_load`.

### 2. `extensions/mcp-client/lifecycle.test.ts` — classifyServers "none" contract

Add a unit test: `classifyServers(servers, new Set(["none"]))` → `eager = []`, all servers excluded (the "none" sentinel is an empty allowlist; no code change needed — the existing exclusion branch handles it).

### 3. `extensions/builtin-tools/subagent-integration.test.ts` — source-level default contract

Add a test in the "#265 env pivot wiring" section (same source-read pattern as the existing `subAgentEnv` tests): assert the subAgentEnv MCP wiring line contains `params.mcp_servers ?? "none"` — the default is wired when the param is absent.

## Verification

1. `npx tsx extensions/builtin-tools/builtin-tools.test.ts` (worktree root) — all pass incl. no regression
2. `npx tsx extensions/builtin-tools/subagent-integration.test.ts` (worktree root) — all pass incl. new default-contract test
3. `npx tsx extensions/mcp-client/lifecycle.test.ts` — all pass incl. new "none" case
4. Real dispatch smoke: run the task tool ONCE with no `mcp_servers` param → child stderr shows zero eager MCP connects (fast startup) instead of hanging connects
