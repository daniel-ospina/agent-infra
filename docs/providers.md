# Provider reliability guide — qwen + the task tool

Covers the failure taxonomy, the agent-infra mitigations for #152 (connection
errors) and #153 (silent stall), and the env overrides that tune them. Written
as part of the qwen-reliability work (2026-08-10); the full evidence analysis is
in `docs/plans/2026-08-10-qwen-reliability-plan.md`.

---

## 1. Failure taxonomy

Both failures were observed on the same aliyuncs compatible-mode endpoint
(`ws-t54s8opy1qoqvnrc.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1`)
via two different API keys with identical pi provider code paths.

| Class | Symptom | Where it shows up | Who fixes it |
|-------|---------|-------------------|--------------|
| **Connection-error storm** (#152) | Mid-stream death → `stopReason: "error"`, `errorMessage: "terminated"` → 3 retries fail with `"Connection error."` → session ends | Session files (`stopReason: "error"`), retry logs | agent-infra: task-tool provider fallback; **upstream**: dead-socket pool reuse in `openai-completions.js` (Issue B), coarse `"terminated"` classification (Issue C) |
| **Silent stall** (#153) | Session completes (`stopReason: "stop"`, file flushed) but `pi` process hangs on exit — event loop won't drain (MCP disconnect leaks, slack-bridge retry exhaustion, cmux hook failure) | `ps` shows state S, 0 TCP connections; cleanup events logged but process never exits | agent-infra: task-tool tier-3 exit watchdog; **upstream**: event-loop drain after MCP forced disconnects (Issue A) |

### Why qwen but not deepseek

- **#152**: the DeepSeek endpoint handles long sessions with tool-call gaps
  gracefully; the aliyuncs endpoint kills connections under concurrent load
  and/or has a ~8-minute connection TTL. DeepSeek is the stable fallback target.
- **#153**: not actually a provider difference — sessions that reach
  `stopReason: "stop"` (successful completion) trigger the full shutdown
  sequence where the hang lives. #152 sessions die with errors before reaching
  that path. DeepSeek sessions complete and exit normally because the hang is a
  timing/MCP-server-set race, not provider-specific.

## 2. Where the mitigations live (agent-infra)

`extensions/builtin-tools/index.ts` — the `task` tool's sub-agent dispatch:

### Tier 3 — exit watchdog (#153)

When a sub-agent's `stdout` and `stderr` both emit `"end"` (streams closed = the
child finished writing) but `proc.on("close")` has not fired within the grace
period, the process is hung on exit. The watchdog kills it
(SIGTERM via tree-kill → SIGKILL after 5s) and the parent gets the
already-captured output immediately instead of waiting out the tier-2 30-minute
heartbeat window.

- Default grace: **120s**
- Env override: `TASK_EXIT_GRACE_MS` (clamped ≥ 1000ms)
- Kills via `extensions/shared/tree-kill.ts` (reaps orphaned MCP server
  processes too, same pattern as the subagent extension #137)

### Provider fallback (#152)

The existing retry wrapper only re-runs on *zero-output* failures. A
connection-error death returns a *defined* result (non-zero exit + error text),
so it exits the retry loop as "success". The fallback step detects that
signature — `connectionErrorDetected()` recognizes `Connection error`,
`stopReason: "error"`, and `"terminated"` in the output/stderr — and, when the
provider is a **qwen variant**, retries the dispatch **once** on the fallback
model.

- Default fallback model: **deepseek-v4-pro**
- Env overrides: `TASK_FALLBACK_MODEL`, `TASK_FALLBACK_DISABLE=1` (off)
- Max 1 fallback — the fallback dispatch is not itself eligible, so no loop
- Logged clearly: `[builtin-tools] provider fallback: qwen → deepseek-v4-pro after connection error`
- Clean exits whose output merely *mentions* the phrase (e.g. research content
  about connection errors) do **not** trigger a fallback (exit-code guarded)

## 3. Env var reference

| Var | Default | Meaning |
|-----|---------|---------|
| `TASK_EXIT_GRACE_MS` | `120000` | Exit-watchdog grace: stream EOF → forced kill of a hung-on-exit sub-agent |
| `TASK_FALLBACK_MODEL` | `deepseek-v4-pro` | Model used for the one-shot fallback dispatch after a qwen connection-error death |
| `TASK_FALLBACK_DISABLE` | unset | `1` turns the provider fallback off |
| `TASK_HEARTBEAT_TIMEOUT_MS` | `1800000` (30 min) | Tier-2 silence threshold (pre-existing #489) |
| `QWEN_HA_DISABLE` | unset | `1` (or `true`) disables the qwen-ha provider extension entirely (registers nothing, warns once) |
| `QWEN_WS_BASE_URL` | aliyuncs compatible-mode/v1 (models.json default) | Endpoint override for the qwen-ha provider (§5) |
| `QWEN_WS_API_KEY` | — | API key for qwen-ha — same key the existing `qwen` provider uses |

## 4. Design decisions + open questions

- **Why kill at 120s and not immediately on stream EOF?** A process may still
  be flushing final buffers / running legitimate shutdown between EOF and exit.
  The grace period distinguishes "briefly finishing" from "hung on exit".
- **Why qwen-only fallback?** Only qwen exhibits the #152 storm; falling back on
  every provider would hide genuine deepseek failures and add cost (deepseek-v4-pro
  may be pricier than qwen3.8-max).
- **Upstream follow-ups** (drafted in `docs/upstream-pi-bugs.md`): event-loop
  drain (Issue A), dead-socket pool reuse (Issue B), `"terminated"` classification
  (Issue C). Filed by the orchestrator; the agent-infra mitigations make these
  non-blocking.
- **Settings tuning (plan T3) — APPLIED (global only).** The orchestrator
  applied `retry.provider.maxRetries` globally in `~/.pi/agent/settings.json`
  alongside the pre-existing `retry.provider.timeoutMs: 600000`. Per-provider
  retry blocks (`providers.qwen.retry.*`) are **not supported**: pi's
  settings-manager `getProviderRetrySettings()` reads global `retry.provider.*`
  only (Q2 answered — verified in `dist/core/settings-manager.js`), so retry
  tuning is global for every provider, not qwen-specific.
- **Custom qwen provider wrapper (plan T4) — SHIPPED** as
  `extensions/custom-provider-qwen/` (new provider id `qwen-ha`, §5). Q1
  answered: pi-ai **does** accept a per-request `fetch` override —
  `StreamOptions.fetch` flows into `createClient()` → `new OpenAI({ fetch })`
  (verified in `dist/api/openai-completions.js`), so connection hygiene is
  expressible at the provider level with no upstream change required.

## 5. qwen-ha — high-availability provider (plan T4)

`extensions/custom-provider-qwen/index.ts` registers a NEW provider `qwen-ha`
serving `qwen3.8-max` on the same aliyuncs compatible-mode endpoint, with
connection hygiene aimed at the #152 dead-socket failure. It is a drop-in for
`qwen`/`qwen3.8-max`: same key (`$QWEN_WS_API_KEY`), same base URL, same model
capabilities/compat — only the HTTP layer differs.

### Why a new provider id

pi's legacy `registerProvider("qwen", { … })` form cannot inject a custom
`fetch` (its `api` field is a string). The native form —
`registerProvider(createProvider({ api }))` with a wrapped `ProviderStreams`
object — can. Registering under `qwen-ha` (instead of overriding `qwen`) keeps
the existing wiring untouched and gives the task-tool fallback work (#152/#154)
an explicit target: `TASK_FALLBACK_MODEL=qwen-ha/qwen3.8-max` or provider
`qwen-ha`.

### Connection hygiene

All qwen-ha requests go through a tuned undici `Agent` (the extension bundles
its own `undici@8.9.0` copy — the same version pi ships):

- `pipelining: 0` — undici closes the socket after every response; no socket
  outlives a turn, so the LB never gets a chance to hold a socket the pool
  still thinks is alive.
- `keepAliveTimeout: 4000` — backstop: idle sockets die client-side at ~4s,
  well under the endpoint's ~8-minute kill TTL, so dead-socket reuse is
  impossible.
- `connections: 4` — cap on concurrent sockets per origin; parallel pi
  sessions share the pool.
- Honors `HTTP(S)_PROXY` env vars by switching to `EnvHttpProxyAgent` when set.

Tradeoff: every turn pays a fresh TCP+TLS handshake (~100–300 ms on this
route) — noise against LLM streaming time, bought for #152 immunity.

### Verified against pi 0.84.1 internals (Q1)

`dist/api/openai-completions.js`: `stream()` passes `options?.fetch` into
`createClient()` (line 128) → `new OpenAI({ apiKey, baseURL, fetch, … })`
(line 514); `StreamOptions.fetch?: FetchFunction` is part of the public type.
So `{ ...options, fetch: tunedFetch }` in a wrapped `ProviderStreams` is all
that is needed — no upstream change. The extension factory is
failure-contained: it never throws (any setup error → warn + no registration),
so pi startup cannot be blocked.
