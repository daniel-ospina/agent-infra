# http-pool-hygiene — dead-connection reuse defence (#1110)

Stops pi's keep-alive pool from handing a **dead socket** to the next request —
the defect that made every retry fail after a provider or load-balancer
connection kill (upstream "Issue B", `docs/upstream-pi-bugs.md`).

## The defect, precisely

`pi`'s `configureHttpDispatcher()` builds an `undici.EnvHttpProxyAgent` with
`allowH2`, `proxyTunnel`, `bodyTimeout`, `headersTimeout` and `connect` — and
**no keep-alive bounds**. undici's defaults therefore apply:

| option | default | where |
|---|---|---|
| `keepAliveTimeout` | 4 s | `undici/lib/dispatcher/client.js:266` |
| `keepAliveMaxTimeout` | **600 s** | `undici/lib/dispatcher/client.js:267` |
| `keepAliveTimeoutThreshold` | 2 s | `undici/lib/dispatcher/client.js:268` |

`keepAliveMaxTimeout` is the **ceiling on the server's own `Keep-Alive:
timeout=N` hint** (`client-h1.js:682-689`: `Math.min(hint - threshold,
keepAliveMaxTimeout)`). An edge that advertises a long idle TTL — Aliyun MaaS
does, and so do several managed proxies — therefore keeps the pooled socket
alive for **up to ten minutes**, far past the edge's real connection TTL. The
edge reaps first; the pool still offers the corpse to the next request; the
write dies with `ECONNRESET`; the OpenAI SDK wraps it as
`APIConnectionError("Connection error.")`; pi retries; the retry may meet
another corpse. Three parallel sessions die in the same window with three
failed retries — the reported signature.

## What this extension does

1. **Bounded hint ceiling.** Every request pi makes through the global `fetch`
   goes through a dispatcher with `keepAliveMaxTimeout` clamped (default **30 s**,
   `PI_HTTP_POOL_KEEPALIVE_MAX_MS`). (One deliberate exception: a re-entrant call,
   i.e. an adopted wrapper that delegates back into `globalThis.fetch`, passes
   straight through to the fetch below every wrapper layer — that is what stops
   the chain recursing, and it is detected per call via async context, so it can
   never be a *concurrent* request.) undici's own `keepAliveTimeout` (4 s, used
   when a server advertises *no* hint) is deliberately **not** overridden, so
   steady-state reuse on healthy endpoints is unchanged — only the "trust a lie
   for ten minutes" path is removed. `keepAliveTimeoutThreshold` is likewise
   left at undici's default: it is *subtracted* from a server hint, so raising
   it would make hint-bearing keep-alives **longer**, not shorter.
2. **Flush before retry.**
   - A transport failure seen by the fetch wrapper rotates the pool and retries
     the request **once** on a guaranteed-fresh connection. The retry is
     **scoped to LLM provider hosts** — derived from the providers configured
     in `models.json`, or set explicitly with `PI_HTTP_POOL_RETRY_HOSTS` —
     because a retry is a RE-SEND: another extension that POSTs a
     non-idempotent write through the same global fetch (e.g.
     `extensions/tortoise-capture/index.ts` creating a session) must never be
     silently duplicated. Non-provider traffic still gets the clamp and a fresh
     pool for its *next* request; it is never re-sent.
   - Within that scope, *replayable* means the body can be produced twice, not
     that the request is idempotent: a provider request whose bytes reached the
     server before the connection died can still be processed twice (one extra
     completion, one extra billing event). That is the same exposure pi's own
     provider retry already carries; this does not widen it.
   - A mid-stream kill cannot be caught by `fetch` (the response was already
     handed over), so a transport-class `stopReason: "error"` at `message_end`
     — e.g. `terminated` — rotates the pool **before pi's own retry**, which
     then starts from an empty pool.

Failures that are *not* transport-class (429, `overloaded`, quota text) never
rotate the pool: the classifier is deliberately narrower than pi-ai's
`RETRYABLE_PROVIDER_ERROR_PATTERN`.

## Configuration

| Env | Default | Meaning |
|---|---|---|
| `PI_HTTP_POOL_HYGIENE` | `1` | `0`/`false`/`disabled` disables the extension entirely (transport untouched) |
| `PI_HTTP_POOL_KEEPALIVE_MAX_MS` | `30000` | ceiling on a server-advertised keep-alive TTL |
| `PI_HTTP_POOL_IDLE_TIMEOUT_MS` | `httpIdleTimeoutMs` setting, else `300000` (pi's `DEFAULT_HTTP_IDLE_TIMEOUT_MS`) | mirrors pi's `headersTimeout`/`bodyTimeout` |
| `PI_HTTP_POOL_RETRY_HOSTS` | provider hosts from `models.json` | comma-separated allowlist for the transparent retry; `""` disables the retry (the pool is still clamped and flushed) |

The extension reads `httpIdleTimeoutMs` from `$PI_CODING_AGENT_DIR/settings.json`
(`~/.pi/agent/settings.json` by default) so the dispatcher mirrors pi's own
request budget instead of hardcoding one. `httpIdleTimeoutMs: 0` (pi's
"disabled") is passed through as `0`; that undici reads `0` as *no timeout* — not
as `abort immediately` — is asserted against real undici in the suite (P3.16),
not assumed from reading. Known limits: only the **global** settings file is
read (a project-level override pi's settings manager would merge is not), and a
provider with no explicit `baseUrl` in `models.json` is not on the retry
allowlist — name its host in `PI_HTTP_POOL_RETRY_HOSTS` to arm the re-send.

## Failure containment

- undici is resolved from **pi's own install** (so the dispatcher shares an
  instance with the fetch that consumes it). Resolution order: pi package root
  derived from `argv[1]`, then the pi-node install root
  (`$PI_NODE_ROOT`, default `~/.local/share/pi-node`), then this extension's own
  module graph.
- If undici cannot be resolved the extension **warns loudly** and installs
  nothing — pi's transport is left exactly as it was. It never throws, so pi
  startup is never blocked.
- The wrapper is re-asserted on `session_start`/`turn_start`. **The transport configuration is re-resolved on every one of those events, not only when `globalThis.fetch` was replaced** — pi rebuilds its *own* dispatcher when `httpIdleTimeoutMs` changes at runtime (the settings UI's `onHttpIdleTimeoutMsChange` → `configureHttpDispatcher(timeoutMs)`), but it deliberately never replaces `globalThis.fetch` once ours is installed (pi only re-installs its own fetch when it still sees the fetch *it* installed), so the re-assert is the only place that can notice. `reconfigure` is idempotent: an unchanged configuration does **not** rotate the pool, so this costs two small file reads per turn and no connection churn. This is what keeps a runtime `httpIdleTimeoutMs` change (including `0` = disabled) and a provider added to `models.json` after install from being pinned to whatever was current at install.
- If `globalThis.fetch` *was* replaced, the replacement is **adopted as the wrapper's new base** (`rebase`) rather than discarded, so instrumentation another extension installed after us survives. It is not clobbered by later `configureHttpDispatcher()` calls: pi only re-installs its own fetch when it still sees the fetch *it* installed.
- One deliberate limit: the wrapper is built on the fetch it is handed at install — pi's own `undici.fetch`. A fetch that another extension installed *before* this one loaded is recorded in `wrapper.previous` and then replaced; it is **not** adopted as the base, because the dispatcher we own is an instance of pi's undici, and handing it to a foreign (or Node-native) fetch relies on cross-instance duck-typing. Adoption applies to replacements that happen *after* install; nothing in this repo wraps `globalThis.fetch` before us.
- The dispatcher mirrors pi's `clientFactory`/`factory` wiring, so the no-op
  `error` listener that stops an inner `Client` error (emitted while tearing
  down a mid-stream fetch body) from crashing the process is preserved on every
  socket we own, not just on the top-level dispatcher.
- The first intercepted request is logged once, so a wrapper that is installed
  but silently bypassed is distinguishable in a session log.

## Testing

```bash
# zero-dep unit + integration suite (runs in the extensions/*/test*.mjs CI glob)
node extensions/http-pool-hygiene/test-pool-hygiene.mjs

# end-to-end: 3 concurrent REAL pi sessions against a reaping edge with a
# mid-stream kill (needs a pi install; not part of the CI glob)
node extensions/http-pool-hygiene/e2e-live-sessions.mjs
```

`lb-harness.mjs` is a deterministic TCP middlebox: after `idleReapMs` of
inactivity it *silently* forgets a connection (no FIN — a lost FIN, an LB
restart, or conntrack eviction all behave this way) and answers the next byte
with a RST. That reproduces the defect without depending on a timing race.

## Where the durable fix belongs

This is the **agent-infra-owned** half: it survives `pi update`. The upstream
fix is the same clamp inside `configureHttpDispatcher()` plus a flush hook in
the retry path; the gap is tracked in `docs/upstream-pi-bugs.md` (Issue B) and
the host issue #1110.

Related but *not* fixed here: a sustained reconnect throttle on the edge is a
backoff problem (#1088's bounded retry contract — 1-min capped ladder, 7
retries), not a pool problem. This extension makes the retry *able* to
succeed; it does not make a hostile edge accept connections. The finite budget
is what makes a sustained hostile edge terminate visibly instead of spinning.
