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
