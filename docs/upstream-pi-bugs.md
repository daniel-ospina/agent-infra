---
title: "Upstream pi bug reports — drafts awaiting filing"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-08-11
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, pi-coding-agent, pi-ai
---

# Upstream pi bug reports — drafts awaiting filing

> **Status:** DRAFT — filing attempted 2026-08-11 via `gh api`, **BLOCKED**
> (HTTP 403: this account lacks issue-create permission on the
> `earendil-works/pi` repo). The drafts below are complete and unchanged from
> the qwen-reliability work; they remain ready to file manually — via the
> browser UI, or with an account that has issue-create permission on the repo.
> Keep the draft bodies intact.

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

### Mitigation in agent-infra (already shipped)
Provider auto-fallback in `extensions/builtin-tools/index.ts`: when a qwen
sub-agent dies with connection-error signatures, the task tool retries the
dispatch ONCE on `TASK_FALLBACK_MODEL` (default `deepseek-v4-pro`), which uses
the stable DeepSeek endpoint. Env: `TASK_FALLBACK_MODEL`, `TASK_FALLBACK_DISABLE=1`.

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
