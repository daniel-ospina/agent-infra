---
title: "Upstream pi bug reports — drafts awaiting filing"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-08-11
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, pi-coding-agent, pi-ai, issue-637
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
  `headersTimeout`/`bodyTimeout` only. Raising it (the fleet runs 600000) does
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
   `stopReason: "error"` before the next attempt — the 5-minute capped retry
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
supported way to say "after the quick retries, keep trying every 5 minutes
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
`delayMs = min(baseDelayMs * 2^(attempt-1), maxDelayMs)`. With
`retry.maxRetries` raised this yields "quick retries, then every N seconds
indefinitely" — a session pauses through an outage and resumes automatically
when connectivity returns. The retry should stay abortable (Esc /
`abort_retry`), and long retry sleeps should not block compaction/summarization
lifecycle events.

### Mitigation in agent-infra (already shipped)
- `scripts/patch-pi-retry.sh` caps the backoff at 5 min in both files (wired
  into `pi-bootstrap/setup.sh`, re-applied on every sync; see
  `docs/providers.md §6`).
- `retry.maxRetries: 10000` in `~/.pi/agent/settings.json`.
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
offline-resume patch (`scripts/patch-pi-retry.sh`), so a pristine upstream
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
