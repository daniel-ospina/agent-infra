---
title: "Provider reliability guide — qwen + the task tool"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-08-14
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, builtin-tools, custom-provider-qwen, custom-provider-openrouter, provider-failover, issue-284, issue-476
---

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

### Second-model gate (`$SECOND_MODEL` — issue #284)

The pipeline's "second-model" review gates (issue-scoping §5.6, code-review §6.6,
plan-review §4.5, subagent-driven-development final reviewer) dispatch with
`model` = `$SECOND_MODEL` (env), **default `deepseek/deepseek-v4-pro`**
(provider-qualified — the bare id is ambiguous across providers). When the
configured second model is set-but-unresolvable or unset-with-unresolvable-
default, dispatch the tool default and annotate `[SECOND-MODEL-GATE] stand-in`
(never silently substitute). Pricing decision + rationale: issue #284.

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

## 6. Offline-resume retry — survive network outages, don't stop (#318)

By default pi retries a failed LLM turn 3 times (2s → 4s → 8s exponential
backoff) and then **ends the session** with the error. On a wifi drop that
means a session stops dead; when the network returns nothing resumes. The
agent-infra offline-resume patch changes the policy to: quick retries first,
then keep retrying **every 5 minutes indefinitely** until connectivity
returns. The session pauses, the user's laptop can sleep through a dead
connection, and work resumes automatically — nothing is lost, nothing needs
re-running.

### What changed

| Surface | Change | Where |
|---|---|---|
| Agent-turn retry (the visible "Retry N/M" path) | Backoff capped at 5 min | patched `dist/core/agent-session.js` in the installed pi |
| Compaction / branch-summary retry | Same 5-min cap (same no-cap backoff) | patched `pi-ai/dist/utils/retry.js` |
| Retry budget | `retry.maxRetries: 10000` (≈34 days at 5-min intervals = effectively infinite) | `~/.pi/agent/settings.json` + `pi-bootstrap/pi-config/settings.json` |
| Task sub-agents | Network-aware kill suppression — while the network is unreachable AND the child is alive (fresh heartbeat markers), the stall clauses (stream-stall / silence / first-message) don't kill it; it survives in retry | `extensions/builtin-tools/index.ts` (`heartbeatKillDecision` + probe in the heartbeat loop) |

### The patch lifecycle

The pi dist patch is **not** a normal repo file — it lives in the installed
package and would be wiped by `pi update`. `scripts/patch-pi-retry.sh`
applies it idempotently (no-op when already patched, fails loudly if a pi
upgrade changed the target code so the patch must be re-based). It is wired
into `pi-bootstrap/setup.sh`, which auto-sync runs at every session start, so
a pi update is re-patched automatically on the next sync. Verify anytime:

```bash
scripts/patch-pi-retry.sh --check
```

### Behavior

- Network dies mid-turn: 3 quick retries (2s/4s/8s), then retries at
  16s → 32s → 64s → 128s → 256s → **every 300s (5 min) indefinitely**.
- Abort anytime with Esc (RPC `abort_retry`); `retry.enabled: false` in
  settings disables retrying entirely (setup.sh deep-merges the `retry` block
  per-key, so a local `enabled: false` survives every sync). Note: with the
  huge budget, a persistent retryable failure (sustained 5xx) retries for
  days instead of ending the session loudly — the abort path and
  `enabled: false` are the escapes.
- A task sub-agent in retry is not killed by the parent while the network is
  down — but ONLY for kills the pure decision would suppress (network down
  AND fresh heartbeat markers; a never-initialized child or a dead child with
  stale markers is still killed, outage or not). The hard cap
  (`TASK_HARD_CAP_MS`, 6h default) still bounds each dispatch as the last
  resort — the opt-in `TASK_MAX_DISPATCH_MS` wall-clock cap is also
  suppressed during an outage (the child is waiting, not drip-streaming; the
  hard cap is the outage bound). The suppression is ON by default (behavior
  change for task sub-agents); `TASK_NETWORK_WAIT=0` disables it (fail-open
  legacy).
- Env knobs: `PI_MAX_RETRY_DELAY_MS` (patch cap, default 300000),
  `TASK_NETWORK_PROBE_URL` (probe target, default = provider baseUrl from
  models.json), `TASK_NETWORK_PROBE_TIMEOUT_MS` (default 5000, clamped ≤ 9s
  so ticks never overlap), `TASK_NETWORK_PROBE_CACHE_MS` (default 15000).

Upstream gap (no configurable agent-level retry delay cap) is drafted in
`docs/upstream-pi-bugs.md` as Issue D.

## 7. Provider-exhaustion failover (#476)

DeepSeek-official prepaid credit drains to `402 {"message":"Insufficient Balance"}`
repeatedly (25× in 30d, Sep 2026 census — including an 11-concurrent-session kill
in ~94s). pi has no re-drive-after-terminal-error API, so agent-infra ships a
role-guarded hop to independent balances serving name-compatible deepseek models,
with automatic return after balance restore.

### Components

- `extensions/shared/provider-failover.ts` — the latch single-source-of-truth:
  durable state at `~/.pi/agent/state/provider-exhaustion.json`
  (`{version: 1, epoch, updatedAt, primaries, blockedLegs}`), alias-family chain
  table, exhaustion signature classifier (canonical 402 + "credit balance too
  low"; 401/healthy never latch), O_EXCL pidfile lock + epoch CAS + atomic
  writes. Ships a CLI: `npx tsx extensions/shared/provider-failover.ts --status | --clear <primary|*>`.
- `extensions/builtin-tools` — resolveProviderModel/dispatch wiring: pre-tool-call
  re-dispatch onto the next chain leg, per-leg circuit breaker, structured HALT
  when every leg is blocked (never a silent fallthrough to a latched default).
- `extensions/provider-exhaustion.ts` — session extension: child (print/json)
  marker emission on `session_shutdown`, interactive (tui-only) latch + hop
  (`pi.setModel`) + restore, session_start pre-prompt hop for latched families.
- `scripts/checkout-hygiene/deepseek-balance-watch.sh` + `deepseek-balance-latch.py`
  — the SINGLE restore authority (launchd, 15 min): zero-token probes
  (`/user/balance`, openrouter `/auth/key`), SET at balance ≤ LOW, CLEAR only on
  verified positive balance AND a 5-token chat probe, hysteresis band, 401/403
  never latch, defer+escalate after 3 consecutive failures.
- `scripts/checkout-hygiene/deepseek-balance-latch.py` mirrors the TS module's
  durable JSON contract so poller + sessions interoperate on one state file.

### Behavior contract

- Marker-only latch trigger (fail-closed nonce auth on the child marker).
- Alias-family hop chains: `deepseek-v4-flash → qwen-tp/deepseek-v4-flash-0731
  → openrouter/deepseek/deepseek-v4-flash` (qwen-tp is env-blocked until its
  401 remediation; default chain while blocked: deepseek → openrouter).
- Env knobs: `PROVIDER_FAILOVER_DISABLE=1` (kill switch), `PI_FAILOVER_NO_HOP=1`
  (must-stay), `PROVIDER_EXHAUSTION_TTL_MS` (latch TTL, default 24h — the poller
  is the real clear authority; a stale latch self-heals in one TTL at the
  DISPATCH level (resolution returns the primary once the record is stale),
  but an interactive TUI session already on a hop leg stays put until the
  poller clears — TTL expiry alone does not yank the session back),
  `PROVIDER_FAILOVER_BLOCKED` (provider block list; empty string = re-enable),
  `TASK_EXHAUSTION_BLOCK=1` (fail fast instead of hopping).
- Account-of-record (deep-review): a drain records under the family ROOT only
  when it continues an in-flight root exhaustion (root latch FRESH at write)
  or IS the root leg; a hop-leg drain with the root stale/absent records under
  the DRAINED provider's own entry (its independent balance drained) so a
  healthy root is never re-latched on another account's evidence. Consequence:
  a hop-own record is NOT cleared by the deepseek-only poller — it self-heals
  by TTL, or `latch clear --primary <hop>` removes it immediately.
  Auth-blocks (blockedLegs) are likewise read-side TTL-bounded (self-heal on
  key remediation; a still-broken key is re-armed fresh by the next 401/403).
- Hop cost metadata is honest (catalog-authority rates in `models-store.json`),
  or the leg is `costUnknown` and FLAGS.

## 8. Venice cold-class routing — cache-cold verification traffic (#512)

Cache-cold **test/verification** traffic (fresh-context reviewer/eval dispatches
that would otherwise burn deepseek-official credits on a cold prompt cache) can
be routed through the **venice** leg — same model id (`deepseek-v4-flash`),
served by api.venice.ai at venice list pricing, with prompt-cache reads served
to cold traffic (live sample 2026-09-06: a first-ever curl to a short prompt
reported `cache_read_input_tokens=1536` of 1721 prompt tokens).

### The seam (default OFF — inert)

**`COLD_CLASS_PROVIDER`** is an OPERATOR-exported env convention read by
reviewer/eval dispatch-site texts (code-review, plan-review, test-review,
issue-scoping, subagent-driven-development skills) — extension code NEVER
reads it. Unset (the default) the seam is inert — no seam dispatch site
routes venice. When an operator exports
`COLD_CLASS_PROVIDER=venice`, eligible cache-cold one-shot dispatches MAY
launch through the venice leg (`--provider venice --model deepseek-v4-flash`).
Interactive/default traffic NEVER routes venice (warm sessions keep their
cache; only explicitly-opt-in cold-class dispatches burn venice credits).
Note the code-level truth: an EXPLICIT `venice/…` provider/model ask at the
task tool (a manual dispatch or a future extension — the seam texts are the
only in-repo askers today, and they are COLD_CLASS_PROVIDER-gated) routes
venice whenever `VENICE_API_KEY` is present and venice is not durably
auth-blocked — `COLD_CLASS_PROVIDER` does not stop that ask; removing the
key does (kill switch #2 below).

The seam is **per-dispatch**, never a family-table edit: `ALIAS_FAMILIES`
(the #476 chain table) has NO venice leg (drift-pinned), so warm traffic and
family resolution are untouched. venice is an independent provider — a drain
on its account records under `primaries["venice"]`, never re-latching or
advancing the deepseek root on another account's evidence.

### Fallback + kill switches

- **Exhaustion fallback** (venice 402/`low_balance`): the #476 machinery hops
  venice → deepseek official → openrouter via the independent-provider
  discriminator (account-of-record: the drain records under `primaries["venice"]`,
  never re-latching the deepseek root). A canceled/empty venice account does
  NOT auto-hop in-dispatch (401/403 = annotation-only `return` + durable
  block, amendment-1 P1-1); the block then gates SUBSEQUENT cold dispatches to
  the default leg pre-spawn (next bullet).
- Kill switches, in order: unset `COLD_CLASS_PROVIDER` (full revert of the
  SEAM — every dispatch-site text stops asking venice; note this env is read
  by the skill texts, not by extension code, so an explicit `venice/…` ask
  at the task tool still routes on key presence — for code-level
  enforcement use the next bullet), remove/unset `VENICE_API_KEY`
  (missing-key → the task-tool gate resolves the dispatch to the default
  deepseek leg BEFORE any spawn), and — while the #476
  machinery is ACTIVE — a durable venice auth-block (`blockedLegs["venice"]`,
  24h TTL) makes the same gate send subsequent cold dispatches to the default
  leg; the block self-heals on key remediation.
- ⛔ `PROVIDER_FAILOVER_DISABLE=1` is NOT a cold-class kill switch (A1 P3): it
  only disables the #476 fallback machinery — the alternate-leg gate and the
  venice leg ignore it, so cold venice routing stays ACTIVE with NO automatic
  recovery (a venice 402 then strands the dispatch; and because the
  marker→`blockedLegs` conversion runs inside the #476 decision loop, NO
  NEW durable auth-block can form either — a 401/403 venice child is
  re-attempted on every dispatch, bounded only by the retry policy; the one
  exception is a PRE-EXISTING block written before FAILOVER_DISABLE was set
  (within its 24h TTL), which the alternate-leg gate still honors). Full
  revert requires unsetting `COLD_CLASS_PROVIDER` (and removing
  `VENICE_API_KEY`).

### Measurement (the 0a gate)

Production cold-class routing stays OFF until a ≥2-week prospective usage
window validates the burn economics. Per-dispatch measurement is
**default-off**:

- `TASK_USAGE_CAPTURE=1` must reach the CHILD env (task children inherit it;
  a non-task `pi -p` process with the var exported never emits — the
  emission requires a task identity, `TASK_HEARTBEAT=1` + nonce, round-2 P2).
  The child accumulates message_end usage across healthy turns and emits ONE
  `[task-usage]` stderr line at session_shutdown (nonce-authenticated;
  provider attribution from the CLI leg — a venice child never mislabels
  itself deepseek).
- The parent attaches `details.dispatchUsage` to the settled result whenever
  the child emitted (CAPTURE reached the child). `TASK_USAGE_LEDGER=1`
  (parent env) ADDITIONALLY appends the durable `event=dispatch-usage` row to
  `audit/provider-failover.jsonl` (the 0a window reads the ledger).
- A real venice dispatch appends an `event=venice-route` row to the same
  audit file (attributable credit burn without scraping session files).
  `venice-route` and `dispatch-usage` rows share the per-dispatch
  `dispatchId` (the TASK_HEARTBEAT_NONCE hex), so route rows and per-leg
  usage rows are joinable per dispatch.

### Registry

Venice is registered flash-ONLY in `pi-bootstrap/pi-config/models.json`
(`baseUrl https://api.venice.ai/api/v1`, `$VENICE_API_KEY`,
cost 0.14/0.28 input/output + 0.03 cacheRead, contextWindow 300000). The
**#284 carve-out**: `COLD_CLASS_PROVIDER` is an operator override SEPARATE
from `$SECOND_MODEL` — second-model gates never route venice unless
`$SECOND_MODEL` itself says so; cold-class applies only to the default-leg
(flash) reviewer/eval dispatches an operator has explicitly opted in.
