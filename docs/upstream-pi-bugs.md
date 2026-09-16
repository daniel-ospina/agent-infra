---
title: "Upstream pi bug reports — drafts awaiting filing"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-08-11
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, pi-coding-agent, pi-ai, issue-637, issue-1114, issue-1115
---

# Upstream pi bug reports — drafts awaiting filing

> **Status:** DRAFT — filing attempted 2026-08-11 via `gh api`, **BLOCKED**
> (HTTP 403: this account lacks issue-create permission on the
> `earendil-works/pi` repo). The drafts below are complete and unchanged from
> the qwen-reliability work; they remain ready to file manually — via the
> browser UI, or with an account that has issue-create permission on the repo.
> Keep the draft bodies intact.
>
> **Re-verification (2026-09-09, #637):** the `#`-comment finding below was re-probed against
> pi v0.85.1 + yaml 2.9.0 during the pi 0.84.3 → 0.85.1 bump — **zero drift** (identical
> `loadSkillsFromDir` results). Recorded HERE rather than inside the draft body, so the drafts
> stay byte-intact and no new hand-synced version stamp enters an unguarded draft body; this file
> is a deliberately-excluded residual in #643.

---

## Issue A: Process exit hang after MCP disconnect timeouts

**Repo:** pi-core (`@earendil-works/pi-coding-agent`)
**Severity:** Medium — strands parent processes; 30-min watchdog rescue in agent-infra

### Symptom
After a session completes with `stopReason: "stop"` (successful completion), the
`pi` process stays alive indefinitely in state `S` (interruptible sleep) with
zero active TCP connections. The session file is fully flushed; cleanup events
are written to the log — the process just never exits.

### Evidence
Session files at `2026-08-10T17-31-09-*Z` (`~/.pi/agent/sessions/--Users-danielospina-Documents-GitHub-tortoise--/`):

- 3 sessions, all `stopReason: "stop"`, all with 70–120 messages, all hung on exit
- Log tails show the cleanup sequence ran but left the process alive:

```
[cmux-pi-extension] cmux hook command failed (status 1)
[mcp-client] Disconnected from 'exa'
[mcp-client] Disconnected from 'playwright-browser'
[reflect-hook] Hosted tortoise not configured...
[slack-bridge] final:true failed after 3 retries
[mcp-client] Disconnect from 'exa' timed out after 5000ms — forcing
[mcp-client] Disconnect from 'playwright-browser' timed out after 5000ms — forcing
```

Additional log tails: `/tmp/tortoise-audit/qwen-304.log`, `/tmp/tortoise-audit/qwen-765.log`, `/tmp/tortoise-audit/qwen-855.log`.

### Repro
1. Run a long `pi -p` session (~30+ min, many tool calls) with MCP servers
   `exa` and `playwright-browser` connected.
2. Let the session complete normally (`stopReason: "stop"`).
3. Observe the process: does not exit. `lsof -p <pid> -i` shows no TCP connections; `ps` shows state S.

### Suspected cause
MCP client transport cleanup Promises left unresolved after a forced disconnect
(`timed out after 5000ms — forcing`). If the transport's internal timers /
intervals are not cleared, the event loop retains a reference and never drains.
The slack-bridge retry-exhaustion (`final:true failed after 3 retries`) and the
cmux hook failure (status 1) may also contribute open handles.

### Expected behavior
After session completion and cleanup, `pi` exits promptly (within a few seconds)
regardless of MCP disconnect timeouts / hook failures. Forced disconnects must
resolve (or be detached) so the event loop can drain.

### Mitigation in agent-infra (already shipped)
Tier-3 exit watchdog in `extensions/builtin-tools/index.ts`: when both stdio
streams EOF but the process is still alive after `TASK_EXIT_GRACE_MS` (default
120s), kill it (SIGTERM → SIGKILL, tree-kill) so the parent gets the
already-captured output instead of waiting out the 30-min heartbeat window.

**#191 extension (shipped):** the hang class where stdio NEVER EOFs (a live
child stuck in MCP disconnect cleanup) was invisible to the EOF watchdog. The
task-heartbeat extension now emits a `session_end` completion marker from its
`session_shutdown` hook (pi emits the event on normal print-mode teardown); the
task tool latches it and arms a short completion watchdog
(`TASK_EXIT_COMPLETE_GRACE_MS`, default 15s) that kills the lingering child and
returns the captured stdout as SUCCESS (`killedAfterCompletion: true` in
details) — completed sub-agents never surface as "Subagent was aborted".
Absent the marker (older pi / heartbeat disabled) behavior is unchanged.

---

## Issue B: Dead connection reuse in OpenAI-compatible provider

**Repo:** pi-ai (`@earendil-works/pi-ai`)
**Severity:** High — concurrent sessions die together; defeats per-request retry

### Symptom
Mid-stream error `"terminated"` followed by 3 retries that all fail with
`"Connection error."` (empty content). All concurrent sessions using the same
endpoint die within the same ~14-second window.

### Evidence
Session files at `2026-08-10T15-49-07-*Z` (3 parallel sessions):

```
15:55:32 — Last successful toolResult
15:57:15 — stopReason: "error", errorMessage: "terminated"
15:57:17 — Retry 1: stopReason: "error", errorMessage: "Connection error." (content: [])
15:57:21 — Retry 2: stopReason: "error", errorMessage: "Connection error." (content: [])
15:57:29 — Retry 3: stopReason: "error", errorMessage: "Connection error." (content: [])
→ Session ends
```

Endpoint: `ws-t54s8opy1qoqvnrc.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1`
(aliyuncs compatible mode, accessed via pi's standard `openai-completions` path).

### Repro
1. Run 3+ concurrent `pi` sessions against the aliyuncs compatible-mode endpoint
   (provider `qwen` / `qwen-tp`).
2. Keep them going past ~8 minutes with regular tool calls.
3. Observe all sessions terminate with `"terminated"` then 3× `"Connection error."`
   retry failures within ~14 seconds of each other.

### Suspected cause
Node's undici-based `fetch` keeps HTTP/1.1 connections alive in a pool.
`createClient()` (`api/openai-completions.js`) builds `new OpenAI({ baseURL,
apiKey, fetch })` with **no custom HTTP agent / keepalive configuration**. When
the server kills connections (load-balancer TTL or concurrent-load eviction),
dead sockets stay in the pool; the next request can hit a dead socket before
establishing a fresh one. Combined with server-side reconnection throttling in
the retry window (~15s), all retries fail.

### Expected behavior
- A server-side connection kill must not poison the client's connection pool:
  either configure the OpenAI client with an HTTP agent that has
  `keepAlive: false` / short `keepAliveTimeout`, or flush/recreate the pool
  before retrying after a `"terminated"` / `"Connection error."`.
- Retries should have a chance to succeed: if the pool holds dead sockets, the
  retry backoff (2s → 4s → 8s) is insufficient — a fresh connection must be
  guaranteed per retry.

### Suggested fix
`createClient()` in `@earendil-works/pi-ai/dist/api/openai-completions.js`:
accept a `fetch`/`httpAgent` override (or default to an undici `Agent` with
`keepAliveTimeout` tuned for providers with aggressive connection TTLs); add a
connection-pool flush on `"terminated"` before the next retry.

### Root cause — confirmed and narrowed (#1110, 2026-09-15)

The suspected cause above is right in spirit but wrong in the detail that
matters, and the wrong detail is why the fix was not obvious. pi *does*
configure an HTTP dispatcher — `configureHttpDispatcher()` installs an
`undici.EnvHttpProxyAgent` with `allowH2: false`, `proxyTunnel: true`,
`bodyTimeout`/`headersTimeout = httpIdleTimeoutMs` and
`connect.autoSelectFamilyAttemptTimeout`. What it does **not** set is any
keep-alive bound, so undici's defaults are in force:

| option | default | source |
|---|---|---|
| `keepAliveTimeout` | 4 s | `undici/lib/dispatcher/client.js:266` |
| `keepAliveMaxTimeout` | **600 s** | `undici/lib/dispatcher/client.js:267` |
| `keepAliveTimeoutThreshold` | 2 s | `undici/lib/dispatcher/client.js:268` |

`keepAliveMaxTimeout` is the **ceiling applied to the server's own
`Keep-Alive: timeout=N` hint** (`client-h1.js:682-689`:
`Math.min(hint - threshold, keepAliveMaxTimeout)`). An edge that advertises a
long idle TTL — Aliyun MaaS, and several managed proxies — therefore keeps the
pooled socket alive for **up to ten minutes**, far beyond its real connection
TTL. The edge reaps first, the pool still offers the corpse to the next
request, the write dies with `ECONNRESET`, and the OpenAI SDK reports it as
`APIConnectionError` → `"Connection error."`.

Two corrections to the original write-up, both load-bearing:

- `httpIdleTimeoutMs` does **not** bound keep-alive. It maps to
  `headersTimeout`/`bodyTimeout` only. Raising it (the fleet runs 300000) does
  not touch pooled-socket lifetime.
- `keepAliveTimeout` alone is not the fix: a server hint overrides it. Only
  `keepAliveMaxTimeout` caps the hint — verified by measurement, not by
  reading: with a 1.8 s idle gap against an edge advertising
  `Keep-Alive: timeout=3600` and reaping at 1.5 s,
  `keepAliveTimeout: 1000` still produced `ECONNRESET`, while
  `keepAliveMaxTimeout: 1000` did not. The negative arm is committed as
  `test-pool-hygiene.mjs` P3.15 ("FALSIFIER"), and OUR OWN knobs are guarded by
  P3.4/P3.5 (the fixed arm uses the extension's dispatcher, so a refactor back
  to `keepAliveTimeout` turns that arm red); P3.15 pins undici's underlying
  behaviour so the reasoning behind the clamp cannot quietly become folklore.

**Reproduced deterministically** (`extensions/http-pool-hygiene/lb-harness.mjs`
— a TCP middlebox that silently forgets a connection after `idleReapMs` and
RSTs the next byte), and end-to-end with three concurrent `pi -p` sessions
against a reaping edge with a mid-stream kill. The E2E's acceptance checks count
`[http-pool-hygiene] rotated connection pool (message_end…` lines directly
(checks A9/A10) rather than inferring the flush from a log regex that pi's own
retry lines also satisfy:

```
CONTROL (hygiene OFF)  reaps=12  requests written onto a reaped socket=9   sessions exited 0
FIXED   (hygiene ON)   reaps=3   requests written onto a reaped socket=0   sessions exited 0, mid-stream kill recovered 3/3
```

Read those as **one observed run of a timing-dependent harness** (a 150 ms
reap and 0.4 s between turns), not as deterministic constants — the committed
checks assert `rstOnReuse > 0` / `=== 0`, not the counts. Note also what the
FIXED arm does and does not establish: with the clamp (100 ms) below the reap
(150 ms), the client drops the idle socket *before* the edge can, so
`rstOnReuse === 0` holds by construction and cannot on its own distinguish the
clamp from keep-alive-disabled. The complementary property — that steady-state
reuse on a **healthy** endpoint survives the clamp — is asserted separately and
against real undici in `test-pool-hygiene.mjs` P3.8 (6 back-to-back requests,
far fewer than 6 connections, no reaps, no rotations).

The control's sessions survived only because undici drops a socket once a
request on it has failed — i.e. the retry is what absorbs the defect, one
provider call at a time. When the edge also throttles reconnects (the
condition the issue attributes to the 2s→4s→8s window), the retry budget is
spent on corpses.

### What the durable fix should be (upstream ask)

1. In `configureHttpDispatcher()`, clamp the server hint:
   `keepAliveMaxTimeout` (≈30 s is well under the common 60 s LB idle timeout
   and under Aliyun's ~8 min), leaving `keepAliveTimeout` at its 4 s default so
   hint-less endpoints do not lose reuse.
2. Expose a pool flush for the retry path, or flush on a transport-class
   `stopReason: "error"` before the next attempt — the bounded retry
   contract (#1088) only pays off if the retry can land on a fresh connection.

### Mitigation in agent-infra (shipped)

`extensions/http-pool-hygiene/` (#1110) is the agent-infra-owned half — it
survives `pi update`:

- every request goes through a dispatcher with `keepAliveMaxTimeout` clamped
  (default 30 s, `PI_HTTP_POOL_KEEPALIVE_MAX_MS`), `keepAliveTimeout` untouched;
- a transport failure rotates the pool and retries once on a fresh connection
  (replayable bodies only), and a transport-class `message_end` (e.g.
  `terminated`) flushes the pool **before** pi's own retry;
- non-transport failures (429, `overloaded`, quota text) never rotate the pool;
- `PI_HTTP_POOL_HYGIENE=0` disables it; an unresolvable undici degrades to a
  loud warning with pi's transport untouched.

The earlier workaround remains in place and is no longer the only recovery
path: provider auto-fallback in `extensions/builtin-tools/index.ts`
(`TASK_FALLBACK_MODEL`, `TASK_FALLBACK_DISABLE=1`) and the `qwen-ha` provider
(`extensions/custom-provider-qwen/`) both predate this fix. `qwen-ha`'s
`pipelining: 0` (close-after-every-response) remains a deliberate per-provider
trade-off, not the general fix.

---

## Issue C: "terminated" error too coarse for retry classification

**Repo:** pi-ai (`@earendil-works/pi-ai`)
**Severity:** Low — improvement; makes retry vs fallback decisions possible in-tree

### Symptom
`"terminated"` matches `RETRYABLE_PROVIDER_ERROR_PATTERN`, so pi retries — but it
doesn't distinguish a server-side connection kill (retry may help) from
persistent endpoint unavailability (retry won't help, a provider fallback would).

### Evidence
Same session files as Issue B: `"terminated"` at 15:57:15 → 3 retries, all
`"Connection error."`. From the retry classifier's perspective the state after
retry 1 is indistinguishable from a transient blip, so all 3 retries burn ~14s
before the session dies.

### Repro
Trigger a persistent endpoint outage on any OpenAI-compatible provider; observe
the 3 retries consume the full retry budget without a provider-level fallback
option.

### Suspected cause
`dist/utils/retry.js` classifies by regex only
(`isRetryableAssistantError()` matches `"terminated"` / `"connection.?error"`),
with no sub-classification or consecutive-failure escalation.

### Expected behavior
Add sub-classification so callers can escalate:
- `"connection_reset"` — server killed the connection → retry with backoff
- `"connection_refused"` — endpoint down → exponential backoff + provider fallback
- `"stream_terminated"` — mid-stream end → retry immediately
- Optionally: after N consecutive connection-class failures, expose a
  `providerFallback` signal (or throw a non-retryable error) so higher layers
  (extension hooks / session loop) can switch providers.

### Mitigation in agent-infra (already shipped)
`connectionErrorDetected()` in `extensions/builtin-tools/index.ts` recognizes
`Connection error` / `stopReason: "error"` / `terminated` signatures and routes
qwen dispatches to the fallback provider regardless of sub-classification.

## Issue D: agent-level retry backoff has no delay cap — network outages kill sessions

**Repo:** pi-core (`@earendil-works/pi-coding-agent`)
**Severity:** Medium — a session dies on any network outage longer than the
quick-retry window; there is no "pause and wait for connectivity" mode.

### Symptom
On a network drop, the agent-level retry (the "Retry N/3" path) runs 3 quick
attempts (2s → 4s → 8s with the defaults) and then the session **ends with an
error**. When the network returns minutes later, nothing resumes. There is no
supported way to say "after the quick retries, keep trying at a fixed cadence
until connectivity returns" — `retry.maxRetries` can be raised, but the
backoff `baseDelayMs * 2^(attempt-1)` then grows unboundedly (17 min, 34 min,
68 min, … gaps), so a laptop left on through an overnight outage waits hours
after the network returns.

### Suspected cause
`dist/core/agent-session.js` `_prepareRetry()` computes
`delayMs = settings.baseDelayMs * 2 ** (this._retryAttempt - 1)` with **no cap**, and
`@earendil-works/pi-ai/dist/utils/retry.js` `retryAssistantCall()` (used by
compaction / branch-summary) does the same. `retry.provider.maxRetryDelayMs`
caps only the SDK-level `retryProviderRequest()` path, not the agent-level
retry.

### Expected behavior
Add a configurable agent-level max retry delay, e.g. `retry.maxDelayMs`
(default: none → current exponential behavior), so
`delayMs = min(baseDelayMs * 2^(attempt-1), maxDelayMs)`. This yields "quick
retries, then every N seconds" for a **finite, operator-chosen** budget — a
session pauses through a short outage and resumes automatically when
connectivity returns, and terminates visibly (rather than spinning) once the
budget is spent. The retry should stay abortable (Esc / `abort_retry`), and
long retry sleeps should not block compaction/summarization lifecycle events.
A wall-clock deadline (`retry.deadlineMs`) would be better still than an
attempt count: an attempt count cannot express "give up after N minutes" when
each attempt may itself burn the full provider timeout (#1088).

### Mitigation in agent-infra (already shipped)
- `scripts/patch-pi-retry.sh` caps the backoff in both files (the cap value is
  in `docs/ops/cost-config-policy.md` §2 and read out of that script by the
  guard) (wired
  into `pi-bootstrap/setup.sh`, re-applied on every sync; see
  `docs/providers.md §6`).
- `retry.maxRetries: 7` + `httpIdleTimeoutMs: 300000` in the shipped
  `pi-bootstrap/pi-config/settings.json` → a bounded no-progress window (the
  derived durations are stated, computed and asserted in
  `docs/ops/cost-config-policy.md` §2, which is the single source for them —
  they are deliberately not restated here). Asserted (not just documented) by
  `scripts/check-cost-config.sh`, and `tests/cost-config/run.sh` test 25 fails
  if a summary doc restates one of the derived figures. The budget is finite because #1110
  (below) makes retries able to *succeed* again.
- `extensions/builtin-tools/index.ts` suppresses task-tool sub-agent kills
  while the network is unreachable (fresh heartbeat markers prove the child is
  alive and retrying, not wedged).

---

## Issue E: auto-compaction retry has no attempt cap — a session wedges unreachable by input

**Repo:** pi-core (`@earendil-works/pi-coding-agent`)
**Severity:** High — the session becomes **input-unreachable**: the operator's
own input re-arms the retry loop, so the wedge cannot be escaped from the
keyboard. Observed wedging three sessions in one working session (agent-infra
#943).

**Verified against:** pi v0.85.1, `dist/core/agent-session.js` (line numbers
below are that file). Note: this install also carries agent-infra's own
bounded-retry patch (`scripts/patch-pi-retry.sh`), so a pristine upstream
install may carry these lines shifted by a few — verify by code, not by line
number.

### Symptom

At high context (observed **98.2%**), compaction fails:

```
Context overflow recovery failed: Summarization failed: generation hit the token cap
  and the summary is incomplete
⠸ Auto-compacting... (escape to cancel)
```

Escape aborts the attempt (`Auto-compaction failed: Turn prefix summarization
failed: This operation was aborted`) and it retries again on the next inbound or
queued message. Context *grew* across attempts (98.2% → 98.9%), so each failure
makes the next harder.
Escape, repeated Ctrl+C and `/exit` all failed to break it — `/exit` was even
swallowed as a **steering message**. No terminal state is ever offered. Only
killing and respawning the process recovers the session.

Input sent to a wedged turn is delivered only as a *chat/steering* message and
is never processed as a command. But its delivery is itself a `message_start`
event for a `user` message — which clears the flag at :364 and re-arms the loop
(see Evidence). So the escape attempt **sustains** the wedge instead of
breaking it, and the spinner keeps showing healthy "working" with frozen token
counters.

### Evidence

The overflow recovery is bounded by a **single boolean**,
`_overflowRecoveryAttempted` (:99). It is set at **:1690**, immediately before
the compact-and-retry, and consulted at **:1667** to refuse a second attempt
(producing the "…after one compact-and-retry attempt" message at :1669).

It is then **reset** in two places:

| line | reset trigger |
|---|---|
| **:364** | `message_start` where `message.role === "user"` — **any inbound user message** |
| **:406** | any assistant message whose `stopReason` is neither `error` nor `length` |

So the bound is neither global nor per-wedge: it is re-armed by ordinary
session activity. **This is why the documented escape hatches fail** — input
sent to break out *is a user message*, delivery hits :364, the flag clears, and
the overflow recovery re-arms against the same un-compactable context. The
operator's own escape attempt re-triggers the loop that traps them.

No attempt counter bounds this loop, and there is no progress test. (An attempt
counter does exist in `pi-ai/dist/utils/retry.js`, but it only retries
`stopReason === "error"` and this failure is a `length` stop, so it never
engages; and nothing compares the context size before and after an attempt to
detect a non-converging retry.) The sharpest symptom: the only terminal message
(**:1669**) is **unreachable in this state**, because the guard that gates it is
the thing being repeatedly cleared.

The failure path (:1867-1889) emits `compaction_end` with `errorMessage` and
`willRetry: false`, then `return false` — an error event, but **no terminal
state**, and the turn is left open (which is what keeps the session
input-unreachable).

### Repro

1. Drive a session to ~98% context (a long single turn, e.g. a large review).
2. Force the summarizer to hit its output cap (a context large enough that the
   summary cannot complete within the token cap).
3. Observe: the recovery fails, Escape aborts one attempt, and it retries
   immediately — repeatedly, with context growing.
4. Attempt to escape with Escape / Ctrl+C / `/exit`: all fail; `/exit` is
   queued as steering and never runs.

### Suspected cause

`_overflowRecoveryAttempted` is a **boolean** rather than a monotonic counter,
and its two reset sites (:364, :406) are reached by the normal traffic the loop
generates. A retry cap alone would not fix this — the reset at :364 has to stop
clearing the bound (or the bound has to become a counter that ordinary user
messages cannot reset).

### Expected behavior

1. **Cap the retry count monotonically.** Once overflow recovery has failed, it
   must not be re-armed by inbound user messages or by unrelated assistant
   messages. A counter that only a *successful compaction* resets.
2. **On exhaustion, enter an explicit terminal state** that says so — e.g.
   *"cannot compact: context too large to summarize — start a new session."*
   Today the only message that says anything like this is unreachable.
3. **Do not retry while context is growing.** A recovery attempt that leaves
   context at or above its previous size is guaranteed not to converge; it
   should terminate rather than loop.
4. The wedged turn should be **force-abortable** so queued input can be
   delivered, rather than requiring the operator to kill the process.

### Suggested fix

```js
// :99 — a counter, not a boolean
_overflowRecoveryAttempts = 0;

// :1690 — increment, and never reset on user-message activity
this._overflowRecoveryAttempts += 1;
// …and on exhaustion, emit a TERMINAL state rather than :1669's compact-and-retry refusal
```

and remove the reset at **:364** (or scope it to "a successful compaction
completed", which is the only event that actually invalidates the bound).

### Mitigation in agent-infra

- **None yet.** No local patch has been written — this path is a
  session-safety mechanism, and a bad patch to `agent-session.js` would affect
  every session, so it is deliberately not patched on the
  `scripts/patch-pi-retry.sh` model without an explicit decision (see
  `docs/upstream-pi-bugs.md` Issue D for that model). Filing upstream is
  blocked (403 — no issue-create permission), so this draft awaits manual
  filing.
- Detectable-side mitigation is tracked separately in agent-infra #943
  (outcome 2) and #928 (the `toolUpdates` / no-progress bound).

---

## Issue #360: skill silently dropped when frontmatter description is missing/empty — warning is emitted but never surfaced

**Repo:** pi-core (`@earendil-works/pi-coding-agent`)
**Severity:** Medium — an author ships a SKILL.md with a missing or empty `description:` and the skill silently dies in pi (the #242 incident class: CI green, skill dead).

### Symptom
`loadSkillFromFile` (dist/core/skills.js:232-233, 252) drops the skill when
`typeof description !== "string" || description.trim() === ""`. The loader DOES
emit a warning diagnostic ("description is required" via `validateDescription`)
— but that diagnostic is a return value of `loadSkillsFromDir`, and no surface
consumes it in the normal agent flow. The author sees nothing; the skill just
never appears in `available_skills`.

### Evidence
- `skills.js:232` — `const hasDescription = typeof description === "string" && description.trim() !== ""`
- `skills.js:233` — `if (!isDeclaredSkill && !hasDescription) return { skill: null, diagnostics }`
- `skills.js:252` — `if (!hasDescription) return { skill: null, diagnostics }`
- A SKILL.md with `description: null` / `description: ""` / no description key
  → `loadSkillsFromDir` returns zero skills for that file + one warning that is
  not surfaced.

### Expected behavior
A declared skill (`basename === "SKILL.md"`) with a missing/empty description
should produce a user-visible error at load time (or the diagnostics should be
surfaced through the session log / a startup warning), so a dead skill is
never silent.

### Mitigation in agent-infra (shipped, #254)
- The dep-free validator flags it as P0 `gate-description-nonstring` (pi drops
  → the skill is dead) — CI fails, the author fixes it before merge.
- The pre-commit hook (scripts/check-staged-skill-frontmatter.mjs) blocks the
  commit at authoring time.

---

## Issue #361: unquoted ` #` in a plain-scalar value silently truncates the value with zero diagnostic

**Repo:** pi-core (`@earendil-works/pi-coding-agent`)
**Severity:** Low-Medium — silent value corruption: the skill LOADS, so nobody
notices the description was cut at the first ` #`.

### Symptom
A plain scalar value containing ` #` (whitespace-preceded hash — the YAML
comment indicator) is truncated by the parser. `description: Build skills # with
care` loads as `"Build skills"`. yaml parses this per spec (the `#` starts a
comment), but the corruption is author-invisible: no diagnostic, no warning,
and the skill loads — only the DESCRIPTION is wrong.

### Evidence
- Probe (pi v0.84.3, yaml 2.9.0): `description: foo # bar` → `loadSkillsFromDir`
  loads the skill with `description: "foo"`. `foo#bar` (no space) → intact
  `"foo#bar"`. `foo #bar` (space before #) → `"foo"`.
- Whitespace-precedence rule verbatim: ` #` preceded by whitespace starts a
  comment; `#` immediately after a non-space character is literal.

### Expected behavior
No diagnostic exists for this class — a lint/authoring tool should flag
unquoted ` #` in plain values (P1: pi loads but silently corrupts the value).

### Mitigation in agent-infra (shipped, #254)
- The validator flags it as P1 `truncate-unquoted-hash` (any finding fails the
  lint) — the author is told to quote the value.
- Documented in docs/plans/2026-08-28-issue-254-skill-lint-yaml.md §2
  (truncate-classes) and §5.4 R3 (acknowledged-drift register).

---

## Issue #1115: idle `pi` TUI burns 6–26% of a core per session — the render frame loop is the mechanism; the driver on a silent session is unidentified

**Repo:** pi-core (`@earendil-works/pi-coding-agent`)
**Version probed:** pi 0.85.1 — pi-node v22.23.2, macOS 27.0 (26A428), arm64 (Apple M5, 10-core)
**Severity:** High for a multi-session host — this is a load ceiling, not a
cosmetic bug. Aggregate **177.5% of one core** across 39 `pi` processes. A
sub-population of **20 processes whose session transcripts had been silent for
more than 120 s** (in fact 132 s to ~5.8 days) alone accounted for
**43.82 s / 30 s = 146.1%** of a core. It drove this host to swap-thrash and
forced a fleet-wide reboot that lost 3 live session threads (#1114).

That 20-process subset is **not** the same set as the table's 11 rows: 10 of
the 11 are in it (pid 64580, silence 1.0 m, is not), and the other 10 are
near-idle ~0.1% processes inside the table's residual bucket. The two figures
are stated separately and must not be added.

**Status of this report:** the measurement, the profile and the per-frame cost
law below are *measured*. The pump's **mechanism** is identified — the render
frame loop is a `setTimeout` callback (`scheduleRender()` → `doRender()`), which
is why the samples land in `uv__run_timers`. Its **driver on a silent session is
not identified**, and the cost law is a *conditional upper bound*, **not** a
bracket on the observed burn. What remains open: which size-dependent component
re-sets its text on which frames, and what requests those frames while the
transcript is silent — see *What is still open*. Two earlier drafts were each an
over-read in opposite directions and are corrected below.

### Symptom

A `pi` TUI consumes multi-percent CPU **indefinitely while its own session is
idle** — no turn in flight, no transcript write, no socket flow, no
asynchronously-spawned tool child — and its rendered screen is **byte-identical
between samples 12 s apart**. (A *synchronous* child is a separate matter: see
the `spawnSync` finding in the profile.)

### Measurement (2026-09-16, ~16:55 EST)

`ps -o pid,time` sampled 30 s apart, all 39 `pi` processes on the host.
"silence" = age of the process's own session `.jsonl` at sample time.

| pid | ΔCPU / 30 s | % of one core | transcript silence |
|---|---|---|---|
| 3312 | +7.88 s | **26.3%** | 8.6 m |
| 2848 | +6.71 s | **22.4%** | 52.9 m |
| 2684 | +5.93 s | 19.8% | 174.0 m |
| 3399 | +5.51 s | 18.4% | 209.5 m |
| 70130 | +5.44 s | 18.1% | 203.1 m |
| 64580 | +4.48 s | 14.9% | 1.0 m |
| 2743 | +3.29 s | 11.0% | 12.1 m |
| 3462 | +2.41 s | 8.0% | 7.5 m |
| 3357 | +2.31 s | 7.7% | 8.6 m |
| 70144 | +2.12 s | 7.1% | 2.2 m |
| 3244 | +1.93 s | 6.4% | 158.3 m |
| **subtotal (these 11)** | **+48.01 s** | **160.0%** | |
| residual 28 procs — 10 more with silence > 120 s at ~0.1% each, plus 18 child/ephemeral `pi` procs whose silence could not be mapped | +5.25 s | 17.5% | |
| **TOTAL (39 procs)** | **+53.26 s** | **177.5%** | |

`load average` 24.06 → 26.42 over the window (10 cores).

`ΔCPU` comes from `ps -o time`; the `%` column is `ΔCPU / 30 s`. The table
reconciles: the 11 rows sum to +48.01 s and the residual 28 procs to +5.25 s,
for +53.26 s total. Silences in the residual bucket are not shown; the ~0.1%-CPU rows are the clean
control against which the 6–26% rows are abnormal.

### Confound ruled out

One further null result, and its scope limitation. The fleet's own extensions
were checked as a possible pump: a scoped search of `~/.pi/agent/extensions/`
(the installed extension set) found **no `setInterval`, no recurring
`spawnSync`/`execSync`, and no `fs.watch`/`watchFile`** — the only `spawnSync`
hits were `search-guard` test fixtures. Caveat, on the record: that scan covered
those three shapes, **not** recursive `setTimeout` self-re-arm or
`process.nextTick` chains — which is precisely the shape pi's render loop
turned out to have. So the null result does **not** exclude an extension driving
frames via a recursive `setTimeout`; it excludes the flat-interval and
subprocess-loop shapes only.

The pre-reboot handoff also blamed `opendirectoryd` / `automountd` FS churn.
Re-sampled over the **identical** 30 s window on the same interval:
`automountd` +2.18 s (7.3% of a core), `opendirectoryd` ≈ 0. So non-`pi`
FS/mount/UI churn is **7.3% against pi's 177.5% — pi is 24× the confound.**
The burn is pi's own.

### Profile — `sample <pid> 20` (`/usr/bin/sample`)

Two independent burners were profiled: **pid 3312** (26.3% of a core, silence
8.6 m) and **pid 70130** (18.1%, silence 203.1 m — the fleet's `stale-stuck`
process). Counts below are **samples accumulated per symbol inside the timer
subtree**, so nested frames make them non-additive — read them as a
*signature*, not a budget.

| | pid 3312 | pid 70130 |
|---|---|---|
| samples in the whole report (main thread) | 14080 | — |
| samples under `uv__run_timers` → `node::Environment::RunTimers` → `v8::Function::Call` → JS | **8573 (61% of the main thread)** | 4217 |
| `Builtin_SegmentIteratorPrototypeNext` (ICU grapheme) | 911 | 234 |
| `JSSegmentIterator::Next` (ICU grapheme) | 798 | 225 |
| `StringIndexOf` | 2348 | 1488 |
| `Runtime_StringEqual` | 1289 | 477 |
| `String::SlowEquals` | 1264 | 465 |
| `Heap::CollectGarbage` | *not quotable — see note* | *not quotable* |
| `RegExpPrototypeTestFast` | 387 | 151 |
| `FindOrderedHashMapEntry` | 269 | 109 |
| **`node::SyncProcessRunner::Spawn`** (see note) | **262** | **198** |
| `uv__try_write` (writes to the terminal) | **13** | **10** |

One deliberately unquoted row: `Heap::CollectGarbage` appears in **three nested
frames per collection** (`SetMarkerAndCallbackImpl<…Heap::CollectGarbage…>` plus
two nested `Heap::CollectGarbage` frames), so every occurrence of the symbol is
the *same* samples seen again — any sum double- or triple-counts. It is plainly
present in both profiles (allocation pressure is real), but no honest number can
be attached to it without first defining which of the three frames counts, so it
is not quoted. It was 1659/12 in an earlier revision of this report; that figure
was an artifact of substring-matching all three frames.

Less severely, three other rows contain mild re-entrant nesting (the same symbol
appearing again on a nested frame within one stack). Counting only the topmost
occurrence per path gives `StringIndexOf` 2342 / 1474,
`RegExpPrototypeTestFast` 374 / 145 and `FindOrderedHashMapEntry` 243 / 95 —
so `StringIndexOf` and `RegExpPrototypeTestFast` exceed their topmost-only
values by under 5%, and `FindOrderedHashMapEntry` by ~11–15% (269 vs 243 =
+10.7%, 109 vs 95 = +14.7%).
The difference is immaterial to the profile's conclusion, but the rows are
sums-over-occurrences, not topmost-only counts.

Two conclusions that survive scrutiny:

1. **The loop writes essentially nothing to the terminal.** 13 `uv__try_write`
   samples for pid 3312 (three frames, 4+4+5) against 8573 in the callback —
   0.15% — and 10 for pid 70130 against 4217. pi-tui renders *differentially*
   (`dist/tui.js` — "Minimal TUI implementation with differential rendering"),
   so an unchanged frame emits zero bytes. That is why the screen is static and
   why the burn is invisible to `cmux read-screen` and `ps`-style inspection.
2. **Syntax dominates: ICU grapheme segmentation plus string compare/search
   plus Map/object allocation churn.** Plus (see below) a *synchronous*
   subprocess spawn.

**Not mentioned in the original filing — `spawnSync` runs on this timer.**
`SyncProcessRunner` is `child_process`'s **synchronous** API
(`spawnSync`/`execSync`). Its `Spawn` symbol appears on **two distinct stacks**
(191 + 71 samples for pid 3312; 143 + 55 for 70130), accumulating 262 / 198
samples in the timer subtree — i.e. **at least two synchronous spawns happened
during the 20 s sample**; the profile establishes no cadence either way. (The wider
`Spawn`/`Run`/`TryInitializeAndRunLoop` family sums to 783 / 594 because those
frames nest inside each spawn; the row quotes the `Spawn` symbol's own frames.)
Its nested `uv_run` → `uv__io_poll` → `kevent` frames
sit *inside* the `uv__run_timers` branch, confirming the spawn happens from a
timer callback. A **synchronous `exec` therefore runs inside the timer loop**
as well as the string work, which is a lead worth instrumenting before anything
else. (The profile gives no *rate* for it — 262/198 are accumulated samples, not
call counts, so the cadence is not derivable and is not claimed.)

### Correction: the pump's *mechanism* is the render frame loop — its *driver* on a silent session is not identified

An earlier draft of this report concluded "the pumping timer was not
identified". That was **half** wrong, and the half that was wrong matters.
`sample` showed 61% of main-thread samples inside
`uv__run_timers` → `RunTimers` → `Function::Call`, and the draft read that as
"one special timer is pumping". Inferring a *mystery* timer from it was a non
sequitur: **the render frame itself is a `setTimeout` callback.**

`TuiBase.scheduleRender()` (`pi-tui/dist/tui.js:636-651`) arms
`this.renderTimer = setTimeout(…, Math.max(0, MIN_RENDER_INTERVAL_MS - elapsed))`
with `MIN_RENDER_INTERVAL_MS = 16` (`tui.js:169`); the callback runs
`doRender()` and **re-arms itself** while `renderRequested` is set. Anything
that calls `requestRender()` — the 80 ms `Working` loader
(`pi-tui/dist/components/loader.js`), a 1 Hz `countdown-timer`, and the 1 Hz
`context.invalidate()` armed by `bash.js` — therefore drives a *frame*, and
every **throttled** frame executes inside `uv__run_timers` (the forced path
`requestImmediateRender()` runs `doRender()` in a `process.nextTick`, and
`renderNow(force)` runs it synchronously — `tui.js:592-628` — so the "every
frame" form would be false). So "61% of the main thread is in a timer
callback" is **consistent with a continuously-repainting TUI** and needed no
unknown timer; reading it as proof of one was a non sequitur.

**But the correction must not be over-read in the other direction.**
`scheduleRender()` only re-arms while `renderRequested` is set, and **nothing
inside `doRender()` sets it** — a frame exists only because something external
keeps calling `requestRender()`. On a genuinely silent session no such caller
has been identified: pi-tui's `IdleStatus` renders two static lines with no
interval (`status-indicator.js`), and every recurring driver found is
**turn-scoped** (the `Loader`'s 80 ms tick, the 1 Hz countdown/retry, the 1 Hz
`bash.js` partial-call interval). The issue's own clean cases — pids 3462/3046
with cmux `runtimeStatus: idle` burning ~22% — are therefore **not yet
reconciled** with a turn-scoped driver. So:

- **Identified:** the *mechanism* — frames are timer callbacks, and a frame
  renders the whole tree.
- **Not identified:** the *driver* that requests frames while the transcript is
  silent. This is the same open question as the "it is not idle at all — queued
  auto-continuation work" framing, which is **not falsified**. The
  high-frequency-timer framing is therefore **re-expressed, not falsified** —
  its driver question is still open.

`doRender()` renders the **whole tree**: `TuiMainScreen.render()` walks
every component (`Container.render`, `tui.js:114-118`, maps all children
through `child.render(width)`). Per-frame costs found:

- **The footer is un-memoised.** `FooterComponent.invalidate()` is a literal
  no-op and `render()` has no cache check
  (`dist/modes/interactive/components/footer.js:65,75`), so it recomputes on
  every frame, and its demonstrated per-frame cost is `getEntries()` — a fresh
  filtered array plus a scan of every session entry
  (`session-manager.js:995`). Its `getContextUsage()` path reaches
  `estimateTokens`'s `JSON.stringify(block.arguments)` per assistant `toolCall`
  **only for messages after the last assistant message carrying usage**
  (`dist/core/compaction/compaction.js:132-149,188-215`) — normally *none* in a
  finished idle session, so that branch is not the steady per-frame cost.
- **Text re-wrapping is O(size).** pi-tui's `Text` memoises on `(text, width)`,
  so an *unchanged* component is genuinely free (0.00 ms measured) — but any
  large component whose text is re-set pays in full on that frame.
- **The scrollback diff is O(#lines).** Measured with distinct-but-equal line
  strings: 0.07 / 0.65 / 0.92 / 2.77 ms per frame at 1 000 / 10 000 / 50 000 /
  200 000 lines (0.08% / 0.81% / 1.15% / **3.47%** at 12.5 fps).

### Per-frame cost law — an upper bound, *not* a bracket

Measured on the host (node v22.23.2, arm64), using pi-tui's own primitives. The
**re-set** column is the load-bearing one — a large component whose text
changes re-wraps in full:

```
Text.render(width=200), component re-set then rendered   # per frame
    5 KB -> 0.44 ms      50 KB -> 2.04 ms
  200 KB -> 5.51 ms     600 KB -> 16.64 ms
  unchanged text (memoised):     0.00 ms  -- a *cached* render is free
```

**This does not bracket the observation, and an earlier draft of this
correction wrongly said it did.** With two free parameters — the content size
and how often a large component actually re-sets — the curve can be tuned to
hit almost any target, so "it brackets" is not a claim that can fail:

| cadence | 5 KB | 50 KB | 200 KB | 600 KB |
|---|---|---|---|---|
| 80 ms (12.5 fps; the `Loader` tick) | 0.6% | 2.5% | 6.9% | **20.8%** |
| 16 ms (`MIN_RENDER_INTERVAL_MS`, 62.5 fps) | 2.8% | 12.8% | **34.4%** | **104%** |

At the report's own re-sampled maximum (**26.3%**, pid 3312) the 12.5 fps column
tops out *below* it (20.8%); at 62.5 fps the same law contains it only
vacuously. And the issue's filed range is wider still (**10–38%**, peak
**37.7%**), which this report's 16:55 re-sample narrowed to 6–26% — that
narrowing must not be used to make the law look like a fit.

The honest reading of the table: **if a session holds a few-hundred-KB
component that re-sets its text on most frames, the per-frame cost is of the
order observed — and no such component has been demonstrated to exist.**
Which component does, and how often, is the missing measurement (see *What is
still open*). The sizes 5/50/200/600 KB are **illustrative**, chosen to span the
plausible range of a large tool output; **no session's actual content size,
heap, entry count or scrollback length was ever measured** — that absence is
precisely the gap.

The whole-scrollback diff, with distinct-but-equal line strings:

```
doRender() scrollback diff, distinct refs                      # per frame
   1000 lines  0.07 ms     10000 lines 0.65 ms
  50000 lines  0.92 ms (@12.5 fps = 1.2%)  200000 lines 2.77 ms (@12.5 fps = 3.5%)
```

*(An earlier draft printed `50000 lines 2.55 ms` and `200000 lines 0.63 ms` —
non-monotonic and wrong: that harness compared a line against itself, i.e. an
identical string *reference*, which short-circuits to a pointer compare. The
distinct-ref measurement above is the real one and is monotonic in #lines.)*

Separately, the real `bash.js` call:

```
truncateToVisualLines(ANSI-styled output, 5, width=200)   # the real bash.js call
  100 KB -> 4.4 ms      250 KB -> 9.7 ms
  500 KB -> 19.1 ms    1000 KB -> 40.7 ms
```

`truncateToVisualLines` (`dist/modes/interactive/components/visual-truncate.js`)
constructs `new Text(text, …)` and calls `Text.render(width)` — it renders and
wraps the **entire** string, keeping the last `n` lines. These figures are
*repeatable on the same string*, so pi-tui's 512-entry `widthCache` does not
rescue a re-wrap of a large output.

`visibleWidth` (`pi-tui/dist/utils.js`) is **input-class sensitive** and must
not be quoted as a flat rate: it returns `str.length` on a pure-printable-ASCII
fast path (`isPrintableAscii`, i.e. 0x20–0x7E — **note `\n` fails it**), and
otherwise memoises into `widthCache`. Two distinct costs, easy to conflate:

- **Fast path:** ~0.7 ms for 200 KB of pure ASCII — but this is a full
  character scan of the string, paid on **every** call, and never memoised. So
  it is not free at this size.
- **Cold slow path** (any `\n`, ANSI escape, or non-ASCII — i.e. `\x1b`-styled
  terminal text, which is all real tool output): **≈ 0.6–0.8 µs/char**, i.e.
  ~120–160 ms for 200 KB. A **warm repeat** of the identical string measured
  ~0 ms via `widthCache` — which is why a single warm measurement must not be
  quoted as the cost; wrapping produces many distinct substrings and thrashes
  the 512-entry cache.

### Calibration (what was ruled out)

Two controls were run to bound the cause before profiling. Method: an
interactive `pi` spawned under a pty (`pty.fork`, 200×50, output drained), CPU
read from `ps -o time`. Windows differ per control and are stated with each:

- **Fresh idle TUI**: `pi --offline` in a scratch directory, no prompt sent —
  **0.24 s / 30 s = 0.8%** of a core, one 30 s window after a 25 s settle. So
  the burn is *not* intrinsic to an idle `pi` TUI.
- **Visible spinner + ticking bash call**: prompt `sleep 900` accepted, the bash
  row rendering `Elapsed Ns` while the `Working` spinner animates — five
  consecutive 15 s windows after a 30 s settle: **0.48, 0.17, 0.14, 0.14,
  0.18 s (3.2%, 1.1%, 0.9%, 0.9%, 1.2%)**. Window 1 is the outlier because the
  turn was still streaming into the transcript; from window 2 on, the settled
  cost is **0.14–0.18 s / 15 s ≈ 0.9–1.2%**. So the 1 Hz
  `context.invalidate()` interval *and* the 80 ms spinner, together, cost ~1%
  at steady state when there is no large tool output to re-measure.

Together these bounds rule out two explanations — "an idle `pi` TUI just costs
this" and "the spinner/countdown cadence *alone* costs this". Neither exceeds
**3.2% even in its worst window**, and the spinner control's steady state is
~1% — both far below the observed 6–26%.

**But these controls do not test the variable that matters, and this report
initially over-read them.** Both controls held **content size at ~zero** — a
near-empty scrollback, a handful of session entries, a small heap, and no large
tool output — while the two burning processes profiled had physical footprints
of **612.0 MB** and **255.5 MB**. The spinner control's own caveat says it:
the ~1% figure is the cost "when there is no large tool output to re-measure".
That caveat is the disproof of the conclusion drawn from it. These controls vary
the *cadence* and hold *size* constant, so they are blind along exactly the axis
the cost law above says is live. They establish that the burn is not intrinsic
to an idle `pi` and that cadence alone does not produce it — they do **not**
establish that the frame loop is cheap, because they were never given anything
large to render.

A second over-read: the null result was measured on a **later, calmer window**
(`automountd` 7.3%, `opendirectoryd` ≈0) than the window in which the machine
died. The pre-reboot handoff for the fatal window reports `opendirectoryd`
**91%** + `automountd` **36%** + a `find` at **54%** ≈ **181% of a core —
statistically equal to pi's entire 177.5%** (see
`~/.pi/agent/state/RESTART-HANDOFF-2026-09-16.md` and #1115's own body; those
figures are **not** from the table above). Excluding the confound for the calmer
window does not exclude it for the fatal one; those are separate claims on
separate windows.
And because Unix load average counts **blocked** as well as runnable processes,
the chain "pi CPU → load 15.94 → swap → reboot" is under-supported: with 39
`pi` processes at 255–670 MB each against 32 GB, **memory pressure** is at least
as plausible a cause of the swap thrash. That is a separate issue from the CPU
burn, but it belongs in the ceiling arithmetic.

### The `bash.js` interval (measured, and bounded)

`bash.js` arms

```js
if (state.startedAt !== undefined && options.isPartial && !state.interval) {
    state.interval = setInterval(() => context.invalidate(), 1000);
}
```

for an in-flight bash call (cleared on a later `renderResult` with
`!options.isPartial || context.isError`), and `renderResult` is driven from
`ToolExecutionComponent.updateDisplay()` — **not** from `render()` — so a plain
render pass does *not* re-invoke it.

### What is still open

At that 1 Hz cadence the `bash.js` re-wrap alone is only 0.4–4.1% of a core, so
it is not by itself the whole 6–26%. What is established is the *shape*: frames
are `setTimeout` callbacks, a frame renders the whole component tree, and at
least one component (the footer) is recomputed every frame. What is **not** yet
pinned down is **which size-dependent component's text is re-set on which
frames, and what requests frames at all while the transcript is silent** — i.e.
which of these dominates:

0. **the unnamed driver** — `doRender()` does not call `requestRender()`, so a
   frame requires an external caller; on a silent session none has been
   identified. Until this is resolved the observed burn is not fully explained;
   this is the open "not idle at all" framing, and the issue's own clean cases
   (cmux `runtimeStatus: idle`, ~22% CPU) are not reconciled with a turn-scoped
   driver;
1. the un-memoised footer — its demonstrated per-frame cost is `getEntries()`
   (fresh filtered array + scan of every entry), measured ~0.24–0.82 ms/frame
   for 200–20 000 entries: real and per-frame but not sufficient alone;
2. the 1 Hz `bash.js` re-wrap of a large output (0.4–4.1%);
3. the scrollback line diff (1.2% at 50 000 lines, 3.5% at 200 000);
4. some other component re-setting its text each frame.

Two earlier draft claims were withdrawn in review and are recorded here so they
are not re-derived:

- that `renderResult` runs on *every* render pass — false; it is
  `updateDisplay()`, not `render()`;
- that the 80 ms `Loader` spinner explains the magnitude — withdrawn on the
  grounds that the spinner calls `requestRender()`, a render pass, which does
  not re-invoke `renderResult`. **That reasoning refuted the wrong proposition.**
  It correctly shows the spinner does not re-run *bash's* renderer; it does not
  show the spinner's render pass is cheap — and the render pass is what
  `doRender()` runs over the whole tree. The loader tick was therefore reinstated
  as *a* frame cadence in the cost law above (as a cadence, not as the driver).

One measurement-definition caveat: "idle" is used here in the **transcript
sense** (no JSONL write for N minutes), which is what the sampling table
records. The issue's clean cases used the **session-state sense** (cmux
`runtimeStatus: idle`). The two are not the same predicate, and the canonical
operational definition is #469's — idle as of the last complete JSONL entry.

So the honest statement is: **the pump's mechanism is the render frame loop; its
driver on a silent session is unidentified; and the cost law is a conditional
upper bound, not a fit.** The remaining unknown is the driver first, the paying
component second — and both are addressed by the same missing measurement (the
per-process size column in step 1 below).

### Why this was not patched downstream

There is **no renderer-only seam**: `dist/core/extensions/types.d.ts` exposes
`registerMessageRenderer` (CustomMessageEntry) and `registerEntryRenderer`
(CustomEntry) only — nothing that overrides a builtin tool's `renderResult`.
An extension *can* shadow a builtin by registering a full same-named tool
definition (`_refreshToolRegistry` in `dist/core/agent-session.js` does
`definitionRegistry.set(tool.definition.name, …)`, and
`withBuiltInRenderers` resolves `definition.renderResult ?? builtIn.renderResult`),
but that means reimplementing `bash` end-to-end — execute, parameters, all
renderers — and it would rot on every `pi update`.

That is a **judgement**, not an impossibility: a local same-named-tool patch
was rejected as a fragile, unfalsifiable shadow of a builtin, not as
technically unreachable. Patching `dist/` directly remains wiped by `pi update`.

### Prior art — and why it matters for the fix

This shape is **not a pi-specific slip**; it is the standard architecture of a
React-style terminal renderer. Ink — the renderer behind most agent CLIs —
exposes `maxFps` with a **default of 30** (a throttle interval derived from it)
and `incrementalRendering`, **default `false`**, which updates only changed
lines instead of redrawing everything
([Ink README](https://github.com/vadimdemedes/ink),
[npm](https://www.npmjs.com/package/ink),
[Render Options](https://deepwiki.com/vadimdemedes/ink/3.2-render-options),
[Rendering Lifecycle](https://deepwiki.com/vadimdemedes/ink/8.1-rendering-lifecycle)).
pi's `MIN_RENDER_INTERVAL_MS = 16` plus a `previousLines` diff is the same
pattern — pi's throttle is even tighter than Ink's default.

That matters for the recommendation: if the throttled whole-tree frame is a
**class** characteristic, then finding and re-stating it is not the fix. The
candidate root causes are pi's **deviations from the class**:

- pi's line diff is computed over the **entire** scrollback every frame, rather
  than only the changed region;
- the footer is recomputed every frame (Ink components re-render too, but pi's
  per-frame footer work is an un-memoised full entry scan);
- `truncateToVisualLines` is O(whole output) rather than O(tail).

So the upstream ask should be framed as "make each frame cheap and bounded",
not "remove the throttle". The falsifier a maintainer should run first: does an
Ink-based TUI with a large mounted output also burn under the same profile?

### Suggested next steps (upstream, in order)

1. **Name the driver, then the component — and collect the missing size column.**
   `doRender()` does not call `requestRender()`, so something external is
   requesting frames on a session whose transcript has not moved. Attach
   `--cpu-prof` to a long-lived, large session and read the JS frame names
   (`sample` cannot — every JS frame in it is `???`). At the same time record a
   **size column** — heapUsed, footprint, entry count and scrollback line count
   for each session — cross-plotted against its CPU. No session's content size
   was ever measured, so today the cost law has a free parameter and cannot be
   falsified; this column is what makes it a claim. That single column separates
   "large sessions burn" from "a cadence burns", and it is cheap.
2. **Memoise the footer.** `FooterComponent.invalidate()` is a no-op and
   `render()` has no cache, so it recomputes per frame; the demonstrated
   per-frame cost is `getEntries()` (a fresh filtered array plus a scan of every
   session entry). Cache on the branch/last-entry identity, and stop walking
   every entry to build a fresh array per frame.
3. **Make frames cheap and windowed** (the issue's ask 2). Note the ask as
   filed — "make the idle path event-driven" — is **insufficient as stated and
   is not adopted here without re-derivation**: an animated indicator (`Working`
   / `Retry` / `Compaction`) is periodic *by nature*, so event-driven
   *scheduling* does not stop frames while one is mounted. The evidence points
   instead at making each frame cheap and bounded: a content-hash short-circuit
   before the tree walk, so an unchanged frame costs nothing instead of
   O(lines), plus windowed/incremental rendering rather than a full-tree walk.
4. **Make `truncateToVisualLines` O(tail) rather than O(whole output)** — wrap
   from the end, or memoise on `(text, width, maxVisualLines)`.
5. **Clear any per-row interval on *every* terminal state** (including abort and
   row disposal), not only on a later `updateDisplay()`.

**Re-check mechanism (so step 1 does not rot):** this report defers its decisive
measurement, and a deferral with no trip is silent rot. The trip is: the
agent-infra half (next section) samples per-pid `ΔCPU` against transcript
silence on its existing cadence, so the burn is re-measured mechanically; the
re-measure below is dated, and if the fleet's next restart shows the spin gone,
that is evidence for the "not idle at all — queued auto-continuation" framing
rather than against it. Trigger: the next time any `pi` process exceeds ~5% of a
core with a transcript silent > 120 s.

### Mitigation available in agent-infra (the issue's ask 3)

The issue's ask 3 — warn/throttle when a session's CPU advances while its
transcript has not changed — is **not addressed by this report** and is the one
part agent-infra controls. It is also **not** currently covered by the existing
substrate, and that was verified rather than assumed:

- `~/.pi/agent/state/stale-stuck.py` correlates burn against transcript
  idleness but reads only `ps -o command=`, `ps -o etime=` and `ps -o ppid=` —
  it **never measures CPU**, so it cannot see this failure mode.
- The idle reaper (`scripts/pi-reap-idle.sh`, policy in
  `docs/ops/pi-idle-repl-reaper-policy.md`, #469) classifies **purely** by
  transcript idleness (`REAP_IDLE_HOURS`, `REAP_STUCK_HOURS`) and likewise
  contains no CPU measurement. Every process in the table above is 1–210 min
  silent, so all of them are *retained indefinitely* by that policy while
  burning 6–26% of a core.

The natural fix is one comparison added to an existing mechanism, not a new
subsystem: a ΔCPU-per-window column joined to #469's existing transcript-silence
predicate (WARN by default; never kill — a false positive destroys an in-memory
session thread, which is the #1114 failure mode). That is deliberately left as a
**separate agent-infra issue**, not folded into this upstream report.

### Honest status of this report

Measured: the fleet burn, the confound isolation, the `sample` attribution
(61% of the main thread in the frame callback, with negligible terminal writes
— 13/8573 = 0.15% for pid 3312, 10/4217 for pid 70130), the `spawnSync`
presence, the per-frame cost law above (the **re-set** column, with its cadence
dependence stated), the un-memoised footer, the frame loop's `setTimeout`
re-arm, and the calibration that a fresh idle TUI costs 0.8% of a core while a
visible spinner plus a ticking bash call costs ~1%.

**Identified:** the *mechanism* — frames are timer callbacks and a frame renders
the whole tree, with one demonstrably un-memoised component. **Not established:**
(a) the *driver* that requests frames while the transcript is silent, and (b)
which component re-sets its text on which frames — and therefore the magnitude
attributable to any site. The cost law is a **conditional upper bound**, not a
fit: at 12.5 fps its 600 KB entry (20.8%) falls *below* the observed maximum
(26.3%), and at 62.5 fps the same law contains the observed range only
vacuously.

Two earlier drafts of this section were each an over-read in opposite
directions, and both are recorded so they are not re-derived: the first called
the pump unidentified and the magnitude unexplained (an over-read of calibration
controls that held content size at zero); the second called the pump identified
and claimed the cost law *brackets* the observation (an over-read of a curve
with two free parameters). The state above is the defensible one.

Two measurement caveats a filer should carry:

- `ps -o time` on macOS measures the process's **own** CPU and does **not** fold
  in reaped children (verified by direct experiment: a parent that burned
  1.03 s while waiting on a 3 s child reported `0:01.03`). So the 177.5% is
  pi's own CPU, not accumulated subprocess time — the `spawnSync` is not the
  explanation.
- It *does* count all threads, and the same sample files show V8 collection
  running **off the main thread** — nine `PlatformWorkerThread` branches carry
  `DefaultJobWorker::Run`, `ScavengerCollector::JobTask::Run` (110+ in one
  subtree) and `ConcurrentMarking::RunMajor`, with
  `Scavenger::EvacuateShortcutCandidate<…, ConsString, …>` present throughout.
  So "61% of the *main thread*" is not the whole process burn, and the extra is
  allocation-driven — consistent with a render path that allocates and flattens
  strings, and additive to it. (These are subtree sums from a
  `recursive counted multiple` section, so they are order-of-magnitude evidence,
  not quotable call counts — the same reason the `Heap::CollectGarbage` row was
  withheld.)

A filer should treat step 1 above as the first action, and should collect the
missing **size column** for every process at the same time.
