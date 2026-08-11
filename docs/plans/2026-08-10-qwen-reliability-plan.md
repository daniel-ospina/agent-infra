# Plan — Issues #152 + #153: Qwen3.8-Max Provider Reliability

**Repo:** agent-infra · **Date:** 2026-08-10 · **Mode:** SCOPE + PLAN ONLY (no implementation, no file edits beyond this doc)

---

## 0. Executive summary

Two distinct failure modes on the same aliyuncs compatible-mode endpoint (`ws-t54s8opy1qoqvnrc.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1`), accessed via two different API keys with identical pi provider code paths:

| | #152 — Connection Error | #153 — Silent Stall |
|---|---|---|
| **Provider** | `qwen` ($QWEN_WS_API_KEY) | `qwen-tp` ($QWEN_TOKEN_PLAN_API_KEY) |
| **Failure** | Mid-stream death → 3 retry fails → session ends | Process hangs on exit after successful completion |
| **Session lifespan** | ~8 min (15:49→15:57 UTC) | 10–20 min (17:31→17:41–17:51 UTC) |
| **stopReason** | `error` / `Connection error.` ×3 | `stop` (completes normally) |
| **Evidence** | 3 parallel sessions all die simultaneously at 15:57 | Session files complete; process stays alive (state S), no TCP, 45+ min |
| **Fix surface** | agent-infra (task-tool retry/fallback) + UPSTREAM (pi-core connection management) | agent-infra (task-tool exit watchdog) + UPSTREAM (pi-core event loop drain) |

---

## 1. Root-cause analysis

### 1.1 #152 — Connection Error: mid-stream termination + connection rejection

**Evidence from session files** (3 parallel sessions at `2026-08-10T15-49-07-*Z`):

```
15:49:07 — Session starts
15:55:32 — Last successful toolResult (27 assistant turns, 24 tool calls)
15:57:15 — Assistant thinking + toolCall, stopReason: "error", errorMessage: "terminated"
15:57:17 — Retry 1: stopReason: "error", errorMessage: "Connection error." (content: [])
15:57:21 — Retry 2: stopReason: "error", errorMessage: "Connection error." (content: []) 
15:57:29 — Retry 3: stopReason: "error", errorMessage: "Connection error." (content: [])
→ Session ends
```

All 3 parallel sessions die within the same ~14-second window (15:57:15–15:57:29). Two smaller sessions at 15:51 and 15:54 (1 turn each, `stopReason: "stop"`) — these were single-turn recovery attempts that succeeded because they were brief enough.

**Root cause:** The aliyuncs compatible-mode endpoint kills connections under concurrent load and/or has a connection TTL (~8 minutes). When a connection is killed mid-stream, pi's OpenAI-compatible streaming layer emits `"terminated"` (matches `RETRYABLE_PROVIDER_ERROR_PATTERN`). The retry mechanism attempts 3 new connections with exponential backoff (2s → 4s → 8s), but all retries also fail with `"Connection error."` — meaning the endpoint is either:

1. **Rate-limiting reconnections** from the same source IP within a short window (~15 seconds after connection termination)
2. **Experiencing a brief endpoint-wide outage** (all 3 concurrent sessions fail simultaneously)
3. **Using connection pools with dead sockets** — Node's undici-based `fetch` keeps HTTP/1.1 connections alive. If the server killed a connection, the next `fetch` might briefly try the dead socket before establishing a new one. Combined with a short retry window, retries 2–3 may also hit the dead pool.

**Why deepseek-v4-pro works:** The DeepSeek endpoint (api.deepseek.com) doesn't exhibit this behavior — it handles long sessions with tool-call gaps gracefully. It's a more mature/production-grade API endpoint.

**Key code paths in pi-core (READ-ONLY):**
- `@earendil-works/pi-ai/dist/api/openai-completions.js`: `createClient()` → `new OpenAI({ baseURL, apiKey, fetch })` with NO custom HTTP agent/keepalive configuration
- `@earendil-works/pi-ai/dist/utils/retry.js`: `retryAssistantCall()` retries on `isRetryableAssistantError()`, which matches `"connection.?error"` and `"terminated"`. Max retries from settings: `retry.provider.maxRetries` (default 3). 
- `@earendil-works/pi-ai/dist/utils/provider-retry.js`: `retryProviderRequest()` — per-request retry with exponential backoff capped at 8s. Handles 408/409/429/5xx plus `x-should-retry` header.
- `dist/core/sdk.js`: streams use `httpIdleTimeoutMs` (settings: 600000 = 10 min, DEFAULT: 300000 = 5 min) as per-request `timeout`. On timeout, OpenAI SDK throws — classified as `"timed? out"` → retryable.
- `dist/core/settings-manager.js`: `getProviderRetrySettings()` returns `{ timeoutMs, maxRetries, maxRetryDelayMs }` from settings.json `retry.provider.*` (currently `timeoutMs: 600000`, no `maxRetries`/`maxRetryDelayMs` set → defaults: 3 retries, 60s max delay).

### 1.2 #153 — Silent Stall: process exit hang after successful completion

**Evidence from session files** (3 sessions at `2026-08-10T17-31-09-*Z`):

All three sessions completed successfully:
- 263 file: 99 messages, last at 17:40:56, `stopReason: "stop"`
- 245 file (de): 72 messages, last at 17:41:40, `stopReason: "stop"`  
- 245 file (fa): 120 messages, last at 17:51:17, `stopReason: "stop"`

Timing shows large tool-execution gaps (30–210s between messages), all survived — the endpoint handles long idle periods fine for qwen-tp.

The session files contain full cleanup events at the tail:
```
[cmux-pi-extension] cmux hook command failed (status 1)
[mcp-client] Disconnected from 'exa'
[mcp-client] Disconnected from 'playwright-browser'
[reflect-hook] Hosted tortoise not configured...
[slack-bridge] final:true failed after 3 retries
[mcp-client] Disconnect from 'exa' timed out after 5000ms — forcing
[mcp-client] Disconnect from 'playwright-browser' timed out after 5000ms — forcing
```

The session writes are flushed. **The pi process itself does not exit** — it hangs in state S (interruptible sleep) with zero active TCP connections.

**Root cause:** pi's event loop fails to drain after session completion. Likely culprits:

1. **MCP client transport leak:** The MCP disconnect timeouts (5000ms, then forced) suggest the MCP transport cleanup is not fully resolving. If `mcp-client` disconnect Promises are left unresolved or the transport's internal timers/intervals aren't cleared, the event loop retains a reference.
2. **Slack bridge retry exhaustion:** `slack-bridge final:true failed after 3 retries` — if the slack bridge's internal state machine doesn't transition to a terminal state after exhausting retries, it may hold an open handle.
3. **cmux hook failure:** The cmux (connection multiplexer) exit hook fails with status 1 — if cmux has internal cleanup that doesn't complete on error, it could block process exit.

**Why qwen-tp but not qwen?** Not a provider difference — rather, sessions that reach `stopReason: "stop"` (successful completion) trigger the full shutdown sequence. #152 sessions die with errors before reaching this path, so the exit-hang code is never reached. Qwen-tp sessions complete successfully → trigger shutdown → hang.

**Why deepseek works?** DeepSeek sessions complete and exit normally. The hang may be timing-sensitive (race condition in MCP disconnect) or related to specific MCP servers being connected (exa, playwright-browser). Different sessions may have different MCP server sets active.

### 1.3 Why this matters for sub-agents (the task tool angle)

When the task tool dispatches a sub-agent (`pi -p`), it spawns a child process and waits for `proc.on("close")`:

```
Parent pi → task tool → spawnSubAgent() → pi -p (child process)
                                              ↓
                                         Session completes, writes file
                                              ↓
                                         Event loop hangs → process never exits
                                              ↓
Parent: proc.on("close") never fires → STALL
```

The task tool's existing heartbeat watchdog (`TASK_HEARTBEAT_TIMEOUT_MS = 30 min`) monitors **stdout/stderr activity**. When the sub-agent finishes its agent loop but hangs on shutdown, stdout/stderr stop producing data. After 30 minutes, the heartbeat fires and kills the sub-agent, returning partial results. But:

- **30 minutes is extremely long** for an agent that finished its work 29 minutes ago
- **The parent has no way to distinguish** "sub-agent doing productive work with no console output" from "sub-agent hung on exit" — both look like stdout/stderr silence
- **For #152**: if the sub-agent dies with connection errors, the `proc.on("close")` fires normally (with exit code ≠ 0), so the parent gets an error response — this works, just with a failed result
- **For #153**: the stall is 30 min before heartbeat rescue, wasting resources and blocking the parent's progress

---

## 2. Fix classification

### 2.1 Fixable in agent-infra

| Fix | Issue | Surface | Effort |
|-----|-------|---------|--------|
| **Task-tool exit watchdog** | #153: sub-agent hangs on exit | `extensions/builtin-tools/index.ts` — add tier-3 watchdog that monitors process liveness (not just stdout) | Small |
| **Provider fallback on connection failure** | #152: recover from dead endpoint | `extensions/builtin-tools/index.ts` — after 2 consecutive "Connection error." failures, auto-switch to `deepseek-v4-pro` | Small |
| **Settings tuning for qwen providers** | #152: give retries more time | `~/.pi/agent/settings.json` — provider-specific retry config (longer backoff, more retries) | Tiny |
| **Custom qwen provider wrapper** | #152: connection health, pre-warm | New `extensions/custom-provider-qwen/` with keepalive tuning, pre-request liveness probe, retry with fresh client | Medium |
| **Sub-agent retry with provider rotation** | #152: recover from dead provider | `extensions/builtin-tools/index.ts` — retry wrapper rotates provider on connection errors | Small |

### 2.2 UPSTREAM (pi-core bugs to file)

| Bug | Issue | Location | Mitigation in agent-infra |
|-----|-------|----------|--------------------------|
| **Process exit hang after session** | #153 | pi-core event loop drain / MCP cleanup | Exit watchdog (kill after N sec idle) |
| **OpenAI client dead-connection reuse** | #152 | `openai-completions.js:createClient()` — no HTTP agent with `keepAlive: false` or connection sanitization | Custom provider with tuned HTTP agent |
| **MCP disconnect timeout → unresolved promise** | #153 | MCP transport layer — forced disconnect doesn't resolve | Exit watchdog catches this |
| **Stream termination error classification** | #152 | `retry.js` — `"terminated"` is too broad; doesn't distinguish server-kill from network blip | Provider fallback detects pattern |

---

## 3. Concrete mitigations design

### 3.1 Mitigation A: Task-tool tier-3 exit watchdog (agent-infra, #153)

Add a third tier to the existing heartbeat system in `spawnSubAgent()`:

```
Tier 1: FIRST_OUTPUT_TIMEOUT (60s) — no output ever → retryable undefined
Tier 2: HEARTBEAT_TIMEOUT (30 min) — silence too long → partial results
Tier 3: EXIT_WATCHDOG_TIMEOUT (120s) — process alive but no stdout/stderr after close event expected
```

**Logic:** When the sub-agent process's stdout and stderr both emit `"end"` (streams closed) but `proc.on("close")` hasn't fired within 120 seconds, the process is hung on exit. Kill it (SIGTERM → 5s → SIGKILL) and return whatever stdout was captured.

**Env override:** `TASK_EXIT_WATCHDOG_TIMEOUT_MS` (default 120_000).

**Key implementation detail:** Listen for `"end"` events on both stdout and stderr streams. When both have ended, start a 120s timer. If `close` fires first, clear the timer. If the timer fires, kill the process.

```typescript
// Pseudocode
let stdoutEnded = false;
let stderrEnded = false;
let exitWatchdog: NodeJS.Timeout | null = null;

const checkExitWatchdog = () => {
  if (stdoutEnded && stderrEnded && !settled) {
    exitWatchdog = setTimeout(() => {
      console.error(`[task] sub-agent hung on exit for ${EXIT_WATCHDOG_TIMEOUT_MS / 1000}s — killing`);
      proc.kill("SIGTERM");
      // ... SIGKILL fallback after 5s
    }, EXIT_WATCHDOG_TIMEOUT_MS);
  }
};

proc.stdout.on("end", () => { stdoutEnded = true; checkExitWatchdog(); });
proc.stderr.on("end", () => { stderrEnded = true; checkExitWatchdog(); });
proc.on("close", () => { if (exitWatchdog) clearTimeout(exitWatchdog); /* existing logic */ });
```

### 3.2 Mitigation B: Provider fallback on connection failure (agent-infra, #152)

In the task tool's retry wrapper, detect connection-error patterns and rotate providers:

```typescript
// After 2 consecutive "Connection error." failures on the same provider,
// switch to deepseek-v4-pro for the next retry
let consecutiveConnectionErrors = 0;
const result = await retry(
  async () => {
    const effectiveProvider = consecutiveConnectionErrors >= 2 ? "deepseek" : provider;
    const effectiveModel = consecutiveConnectionErrors >= 2 ? "deepseek-v4-pro" : model;
    return spawnSubAgent(effectiveModel, effectiveProvider, subAgentEnv, args);
  },
  {
    maxAttempts: 4,  // +1 to allow for fallback
    onRetry: (attempt, delayMs) => {
      // ... check if last failure was connection error, increment counter
    }
  }
);
```

**Also apply at the parent level:** When pi's main loop gets 3 consecutive `stopReason: "error"` with `"Connection error."`, the session could auto-switch to a fallback provider. This requires an extension hook — the `after_provider_response` hook fires per-request. An extension could track consecutive connection errors and modify the model for the next turn.

### 3.3 Mitigation C: Settings tuning for qwen providers

In `~/.pi/agent/settings.json`, add provider-specific overrides:

```json
{
  "retry": {
    "provider": {
      "timeoutMs": 600000,
      "maxRetries": 3,
      "maxRetryDelayMs": 60000
    }
  },
  "providers": {
    "qwen": {
      "retry": {
        "maxRetries": 5,
        "maxRetryDelayMs": 30000
      }
    },
    "qwen-tp": {
      "retry": {
        "maxRetries": 5,
        "maxRetryDelayMs": 30000
      }
    }
  }
}
```

**Note:** pi-core may not support per-provider retry settings. Check `settings-manager.js:getProviderRetrySettings()` — it reads global `retry.provider.*` only. If per-provider is unsupported, this becomes an UPSTREAM feature request.

### 3.4 Mitigation D: Custom qwen provider extension with tuned HTTP agent (agent-infra, #152)

Create `extensions/custom-provider-qwen/index.ts` following the `custom-provider-openrouter/` pattern, with:

1. **Custom `fetch` with connection hygiene:**
   ```typescript
   // Use undici agent with keepAlive disabled or very short timeout
   // to avoid dead-connection reuse after server-side connection kills
   const agent = new Agent({ keepAliveTimeout: 10_000, keepAliveMaxTimeout: 10_000 });
   ```

2. **Pre-request liveness probe:** Before retrying on connection error, do a cheap GET to the base URL `/health` or just a new connection test to flush the connection pool.

3. **Provider definition:**
   ```typescript
   pi.registerProvider("qwen-custom", {
     name: "Qwen (Custom)",
     baseUrl: "https://ws-t54s8opy1qoqvnrc.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1",
     api: "openai-completions",
     apiKey: "$QWEN_WS_API_KEY",
     compat: { thinkingFormat: "qwen", supportsDeveloperRole: false },
     models: [
       {
         id: "qwen3.8-max",
         name: "Qwen3.8 Max",
         reasoning: true,
         input: ["text", "image"],
         contextWindow: 1000000,
         maxTokens: 131072,
         thinkingLevelMap: { minimal: null, low: "low", medium: "medium", high: null, xhigh: "xhigh", max: null }
       }
     ]
   });
   ```

**Risk:** pi-core may ignore the custom `fetch` in the provider definition — the `createClient` function constructs `new OpenAI({ fetch, ... })` where `fetch` comes from `options?.fetch` (passed through from the model runtime). If the custom provider extension can inject a fetch override, this works. If not, the keepalive tuning needs to happen at a different layer (global undici dispatcher config or environment variable).

### 3.5 Mitigation E: Session-file mtime monitoring (quick heuristic)

For the task tool: before killing a sub-agent on silence, check the session file's mtime. If the session file has been modified within the last 60 seconds, the sub-agent is still doing productive work (even if stdout is buffered). If the session file hasn't been touched in `HEARTBEAT_TIMEOUT_MS`, the sub-agent is truly stalled.

```typescript
// In the tier-2 heartbeat check, add:
const sessionFile = `${agentDir}/sessions/${safePath}/${sessionId}.jsonl`;
const sessionMtime = fs.statSync(sessionFile).mtimeMs;
if (Date.now() - sessionMtime < HEARTBEAT_TIMEOUT_MS) {
  // Session file is being written — agent is active, reset heartbeat
  lastHeartbeat = Date.now();
  return;
}
```

This requires knowing the session file path in the task tool, which isn't currently available. Could be inferred from the sub-agent's `--no-session` flag → no session file. Better: check ANY recent file writes in the working directory.

---

## 4. Ordered implementation tasks

Each task sized for fast (≤30 min) implementation, independently verifiable.

| # | Task | Issue | Surface | Verification |
|---|------|-------|---------|-------------|
| **T1** | Tier-3 exit watchdog in task tool | #153 | `extensions/builtin-tools/index.ts` | Spawn sub-agent that hangs on exit; confirm it's killed after 120s |
| **T2** | Provider fallback on connection error | #152 | `extensions/builtin-tools/index.ts` retry wrapper | Mock connection failures; verify deepseek fallback activates |
| **T3** | Settings tuning: qwen retry config | #152 | `~/.pi/agent/settings.json` + doc | Run qwen session; verify retry attempts increase to 5 |
| **T4** | Custom qwen provider extension | #152 | New `extensions/custom-provider-qwen/` | Register provider; run session; verify connection hygiene |
| **T5** | File UPSTREAM bugs | Both | pi-core repo issues | Links in this doc |
| **T6** | Integration smoke test | Both | Run tortoise plan tasks with qwen/qwen-tp | Verify sessions complete or gracefully fall back |
| **T7** | Documentation: provider reliability guide | Both | `docs/providers.md` | Documents qwen quirks, fallback behavior, env override vars |

**Order:** T5 first (file upstream issues so they're tracked) → T1 (exit watchdog, no dependencies) → T2 (provider fallback) → T3 (settings) → T4 (custom provider, depends on investigating pi-core fetch override capability) → T6 (integration) → T7 (docs)

---

## 5. Risks + open questions

| # | Risk / Question | Impact |
|---|-----------------|--------|
| **Q1** | Can pi-core custom providers override the `fetch` used by the OpenAI SDK? If not, Mitigation D can't tune keepalive at the provider level — would need global undici dispatcher config via env vars or an UPSTREAM change. | Mitigation D scope |
| **Q2** | Does pi-core support per-provider retry settings? `getProviderRetrySettings()` reads global only. If not, Mitigation C only affects global retry behavior, not per-provider. | Mitigation C scope |
| **Q3** | Why does qwen-tp survive long tool gaps (210s) while qwen dies at ~8 min? Is it the API key tier, concurrent load, or time-of-day? Need more data across different times of day. | Root cause certainty |
| **Q4** | Is the #152 pattern reproducible on demand, or intermittent? If intermittent, verification of T2/T3/T4 needs a way to simulate or wait for natural occurrence. | Verification strategy |
| **Q5** | The 30-min heartbeat timeout in TASK_HEARTBEAT_TIMEOUT_MS was raised in #489 to avoid killing productive agents. T1's exit watchdog avoids this by ONLY triggering after streams end — but the 30-min tier-2 heartbeat remains as a safety net. Is 30 min still appropriate for qwen sub-agents? | Sub-agent responsiveness |
| **Q6** | When the parent detects a sub-agent failure and falls back to deepseek-v4-pro, does the context/prompt need adjustment? DeepSeek has different system prompt expectations (developer role not supported in qwen compat). The models.json compat flags handle this, but worth smoke-testing. | Fallback correctness |
| **R1** | Exit watchdog false-positive: if a sub-agent closes stdout/stderr but continues work asynchronously (writing to a different output), the watchdog kills it prematurely. Low risk since pi -p writes final output to stdout. | Data loss |
| **R2** | Provider fallback could create cost surprises if deepseek-v4-pro is more expensive than qwen3.8-max. Mitigation: only fallback after explicit connection failures, not on slow response. | Cost |
| **R3** | Custom provider extension adds maintenance burden — must keep models.json and extension in sync when model capabilities change. | Maintenance |

---

## 6. UPSTREAM issues to file

### Issue A: Process exit hang after MCP disconnect timeouts

**Repo:** pi-core (`@earendil-works/pi-coding-agent`)
**Symptom:** After session completes with `stopReason: "stop"`, pi process stays alive (state S), 0 TCP connections, indefinitely.
**Evidence:** Session files at `2026-08-10T17-31-09-*Z` show cleanup events written but process never exits. MCP disconnect logs show `"timed out after 5000ms — forcing"`.
**Suspected cause:** MCP client transport cleanup Promises are unresolved after forced disconnect; event loop retains reference.
**Mitigation in agent-infra:** Tier-3 exit watchdog (T1) — kills hung process after 120s.

### Issue B: Dead connection reuse in OpenAI-compatible provider

**Repo:** pi-ai (`@earendil-works/pi-ai`)
**Symptom:** Mid-stream error `"terminated"` followed by 3 `"Connection error."` retries that all fail. All concurrent sessions using the same endpoint die simultaneously.
**Evidence:** Session files at `2026-08-10T15-49-07-*Z`.
**Suspected cause:** Node's undici-based `fetch` keeps HTTP/1.1 connections alive. When the server kills connections (load balancer TTL), dead sockets remain in the pool. Next request may hit a dead socket before establishing a new one. Combined with server-side reconnection throttling, all retries fail.
**Suggested fix:** Configure OpenAI client with `httpAgent` that has `keepAlive: false` or very short `keepAliveTimeout` for providers known to have aggressive connection TTLs. Alternatively, add a pre-retry connection pool flush.
**Mitigation in agent-infra:** Provider fallback (T2), custom provider with tuned fetch (T4).

### Issue C: "terminated" error too coarse for retry classification

**Repo:** pi-ai (`@earendil-works/pi-ai`)
**Symptom:** `"terminated"` matches `RETRYABLE_PROVIDER_ERROR_PATTERN` but doesn't distinguish server-side connection kill (retry may help) from persistent endpoint unavailability (retry won't help).
**Suggested fix:** Add sub-classification: `"connection_reset"` (server killed connection → retry with backoff), `"connection_refused"` (endpoint down → retry with exponential backoff + provider fallback), `"stream_terminated"` (mid-stream end → retry immediately).
**Mitigation in agent-infra:** Provider fallback (T2) handles this by rotating providers after consecutive failures regardless of sub-classification.

---

## 7. Appendix: evidence inventory

### Session files (#152 — Connection Error)
- `~/.pi/agent/sessions/--Users-danielospina-Documents-GitHub-tortoise--/2026-08-10T15-49-07-873Z_...jsonl` — 75 lines, 27 turns, dies at 15:57:29
- `~/.pi/agent/sessions/--Users-danielospina-Documents-GitHub-tortoise--/2026-08-10T15-49-07-885Z_...jsonl` — 54 lines, 20 turns, dies at 15:56:51
- `~/.pi/agent/sessions/--Users-danielospina-Documents-GitHub-tortoise--/2026-08-10T15-49-07-895Z_...jsonl` — 68 lines, 23 turns, dies at 15:57:29

All show: `"terminated"` → 3× `"Connection error."` → end.

### Session files (#153 — Silent Stall)
- `~/.pi/agent/sessions/--Users-danielospina-Documents-GitHub-tortoise--/2026-08-10T17-31-09-245Z_...jsonl` (de) — 72 messages, `stopReason: "stop"`, gaps up to 128s
- `~/.pi/agent/sessions/--Users-danielospina-Documents-GitHub-tortoise--/2026-08-10T17-31-09-245Z_...jsonl` (fa) — 120 messages, `stopReason: "stop"`, gaps up to 210s
- `~/.pi/agent/sessions/--Users-danielospina-Documents-GitHub-tortoise--/2026-08-10T17-31-09-263Z_...jsonl` — 99 messages, `stopReason: "stop"`, gaps up to 142s

All show cleanup events written, process hung on exit.

### Logs
- `/tmp/tortoise-audit/qwen-304.log` — session tail with MCP disconnect timeouts, slack bridge failures
- `/tmp/tortoise-audit/qwen-765.log` — session tail with same cleanup pattern
- `/tmp/tortoise-audit/qwen-855.log` — session tail with same cleanup pattern

### Configuration
- `~/.pi/agent/settings.json`: `httpIdleTimeoutMs: 600000`, `retry.provider.timeoutMs: 600000`, `defaultProvider: "deepseek"`
- `~/.pi/agent/models.json`: qwen → `$QWEN_WS_API_KEY`, qwen-tp → `$QWEN_TOKEN_PLAN_API_KEY`, both use `api: "openai-completions"` with base URL `ws-t54s8opy1qoqvnrc.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1`

### pi-core key files (READ-ONLY)
- `@earendil-works/pi-ai/dist/api/openai-completions.js`: stream + createClient + buildParams — per-request timeout via `options.timeoutMs`, OpenAI SDK with `maxRetries: 0` (retry handled by `retryProviderRequest` + `retryAssistantCall`)
- `@earendil-works/pi-ai/dist/utils/retry.js`: `retryAssistantCall()` — max retries from policy, `isRetryableAssistantError()` matches `"terminated"` and `"connection.?error"`
- `@earendil-works/pi-ai/dist/utils/provider-retry.js`: `retryProviderRequest()` — 408/409/429/5xx + undef status retryable, exponential backoff capped at 8s
- `dist/core/sdk.js`: streamFn uses `httpIdleTimeoutMs` as `timeoutMs`, `providerRetrySettings` for `maxRetries`/`maxRetryDelayMs`
- `dist/core/settings-manager.js`: `DEFAULT_HTTP_IDLE_TIMEOUT_MS = 300_000`, `getProviderRetrySettings()` reads global settings
- `dist/core/http-dispatcher.js`: `DEFAULT_HTTP_IDLE_TIMEOUT_MS = 300_000`, choices: 30s/1m/2m/5m/disabled

### agent-infra task tool
- `extensions/builtin-tools/index.ts`: spawnSubAgent with TASK_HEARTBEAT_TIMEOUT_MS (30min default), FIRST_OUTPUT_TIMEOUT_MS (60s), tier-2 silence watchdog. Retry wrapper with 3 attempts + circuit breaker.
