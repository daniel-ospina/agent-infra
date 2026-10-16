/**
 * pool-hygiene.mjs — dead-connection reuse defence for pi's HTTP transport.
 *
 * ── The defect (#1110 / docs/upstream-pi-bugs.md "Issue B") ──────────────────
 * pi's `configureHttpDispatcher()` (dist/core/http-dispatcher.js) installs an
 * `undici.EnvHttpProxyAgent` with `allowH2/proxyTunnel/bodyTimeout/
 * headersTimeout/connect` — and **no keep-alive bounds**. undici's defaults are
 * therefore in force:
 *
 *     keepAliveTimeout        = 4s      (client.js:266)
 *     keepAliveMaxTimeout     = 600s    (client.js:267)  ← the problem
 *     keepAliveTimeoutThreshold = 2s    (client.js:268)
 *
 * `keepAliveMaxTimeout` is the CEILING applied to a server's own
 * `Keep-Alive: timeout=N` response hint (client-h1.js:682-689:
 * `Math.min(hint - threshold, keepAliveMaxTimeout)`). So an edge that advertises
 * a long idle TTL — Aliyun MaaS does, and so do several managed proxies —
 * extends the pooled socket's life to **ten minutes**, far beyond the edge's
 * real connection TTL. When the edge reaps the connection first, undici still
 * offers the dead socket to the next request, and the request dies with
 * ECONNRESET → the OpenAI SDK wraps it as `APIConnectionError("Connection
 * error.")` → pi retries → the retry can hit another dead socket. That is the
 * "every retry fails" signature.
 *
 * ── The fix, in two halves ──────────────────────────────────────────────────
 * 1. **Bounded hint ceiling.** Every request is sent through a dispatcher whose
 *    `keepAliveMaxTimeout` is clamped (default 30s, `PI_HTTP_POOL_KEEPALIVE_MAX_MS`).
 *    undici's own `keepAliveTimeout` (4s, used when the server advertises no
 *    hint) is left untouched, so steady-state reuse on healthy endpoints is
 *    NOT reduced — only the "trust a lie for ten minutes" path is removed.
 * 2. **Flush before retry.** A connection-class failure observed by the wrapper
 *    rotates the pool immediately and retries the request once on a guaranteed
 *    fresh connection. A connection-class `stopReason: "error"` seen at
 *    `message_end` (a mid-stream `terminated` kill, which fetch cannot catch)
 *    rotates the pool so pi's own retry starts from a clean pool.
 *
 * Layer note: this is the agent-infra-owned half of the fix (survives
 * `pi update`). The durable upstream fix is the same clamp inside
 * `configureHttpDispatcher()` plus a flush hook in the retry loop — tracked in
 * `docs/upstream-pi-bugs.md` Issue B.
 */

import { EventEmitter } from "node:events";
import { AsyncLocalStorage } from "node:async_hooks";
import { createRequire } from "node:module";
import { existsSync, readFileSync, readdirSync, realpathSync } from "node:fs";
import { dirname, join } from "node:path";
import { homedir } from "node:os";

// ─────────────────────────────────────────────────────────────────────────────
// Configuration
// ─────────────────────────────────────────────────────────────────────────────

/** Kill switch: `PI_HTTP_POOL_HYGIENE=0` (or `false`/`disabled`) disables everything. */
export const DISABLE_ENV = "PI_HTTP_POOL_HYGIENE";

/** Ceiling applied to a server-advertised keep-alive TTL. */
export const KEEPALIVE_MAX_ENV = "PI_HTTP_POOL_KEEPALIVE_MAX_MS";

/**
 * Default hint ceiling. 30s sits well under the common load-balancer idle
 * timeouts (ALB/GCP/HAProxy default 60s; Aliyun MaaS ~8 min) and only ever
 * shortens a lifetime the server asked for — undici's own 4s default for
 * hint-less servers is already shorter than this.
 */
export const DEFAULT_KEEPALIVE_MAX_MS = 30_000;

/** Fallback for headers/body timeouts: pi's `DEFAULT_HTTP_IDLE_TIMEOUT_MS`
 *  (dist/core/http-dispatcher.js). pi's `httpIdleTimeoutMs` setting overrides it. */
export const DEFAULT_HTTP_IDLE_TIMEOUT_MS = 300_000;

/**
 * Decide what a test/CI run must do when undici is not resolvable.
 *
 * The real-transport arms are the ONLY end-to-end evidence this module's fix
 * works. A bare `skip` exits 0, so in an environment without undici the gate is
 * inert — it reports green while testing nothing. `requireUndici` (set from
 * `PI_HTTP_POOL_REQUIRE_UNDICI=1`, which CI sets alongside a real undici
 * install) turns that into a failure instead.
 *
 * @returns {"run"|"fail"|"skip"}
 */
export function undiciGateOutcome({ undiciAvailable, requireUndici = false }) {
  if (undiciAvailable) return "run";
  return requireUndici ? "fail" : "skip";
}

/** Mirror of pi's `DEFAULT_AUTO_SELECT_FAMILY_ATTEMPT_TIMEOUT_MS`. */
export const AUTO_SELECT_FAMILY_ATTEMPT_TIMEOUT_MS = 2_000;

/** Env override for the headers/body timeout mirror. */
export const IDLE_TIMEOUT_ENV = "PI_HTTP_POOL_IDLE_TIMEOUT_MS";

/** Comma-separated host allowlist for the transparent retry; "" disables it. */
export const RETRY_HOSTS_ENV = "PI_HTTP_POOL_RETRY_HOSTS";

// ─────────────────────────────────────────────────────────────────────────────
// Error classification
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Transport-class failures only — a deliberately narrower set than pi-ai's
 * `RETRYABLE_PROVIDER_ERROR_PATTERN` (which also matches HTTP status text).
 * These are the errors for which "the socket is dead / the pool is suspect"
 * is true, so the pool is worth flushing.
 */
const TRANSPORT_ERROR_PATTERN = new RegExp(
  [
    "terminated",
    "connection.?error",
    "connection.?refused",
    "connection.?lost",
    "other side closed",
    "socket hang up",
    "socket connection was closed",
    "reset before headers",
    "premature close",
    "upstream.?connect",
    "network.?error",
    "fetch failed",
    "ECONNRESET",
    "ECONNREFUSED",
    "ECONNABORTED",
    "EPIPE",
    "ENETUNREACH",
    "EHOSTUNREACH",
    "UND_ERR_SOCKET",
    "UND_ERR_CLOSED",
    "UND_ERR_HEADERS_TIMEOUT",
    "UND_ERR_BODY_TIMEOUT",
    "UND_ERR_CONNECT_TIMEOUT",
    "connect.?timeout",
  ].join("|"),
  "i",
);

/**
 * True when a thrown error looks like a dead/severed connection.
 *
 * Classification is CODE-FIRST, deliberately. The bare `"fetch failed"`
 * alternative is the generic wrapper message Node/undici attach to EVERY fetch
 * network failure — a self-signed TLS failure and a DNS failure both read
 * `TypeError: fetch failed` (with `cause.code` `DEPTH_ZERO_SELF_SIGNED_CERT` /
 * `ENOTFOUND`). Matching that message when a cause code is available would
 * classify TLS/DNS failures as transport kills, rotate the pool, and re-send —
 * widening the retry scope the allowlist exists to narrow. So the message is
 * consulted ONLY when there is no cause code to classify on.
 */
export function isConnectionClassError(err) {
  if (!err) return false;
  const codes = [err.code, err.errno, err.cause?.code, err.cause?.errno];
  for (const code of codes) {
    if (typeof code === "string" && TRANSPORT_ERROR_PATTERN.test(code)) return true;
  }
  if (hasCauseCode(err)) return false;
  return isConnectionClassMessage(String(err.message ?? err));
}

/** True when the error carries a `cause` code we could have classified on. */
function hasCauseCode(err) {
  const cause = err?.cause;
  if (!cause || typeof cause !== "object") return false;
  return typeof cause.code === "string" || typeof cause.errno === "string";
}

/** True when an error STRING (e.g. pi's `errorMessage`) is transport-class. */
export function isConnectionClassMessage(message) {
  return typeof message === "string" && message.length > 0 && TRANSPORT_ERROR_PATTERN.test(message);
}

// ─────────────────────────────────────────────────────────────────────────────
// Request replayability
// ─────────────────────────────────────────────────────────────────────────────

/**
 * A transparent retry re-sends the request; that is only safe when the body can
 * be produced twice. The OpenAI SDK sends a JSON string (replayable) — but a
 * caller may hand us a stream, and re-sending a consumed stream is corruption.
 *
 * A `Request` instance carries its own (already-consumed) body, so it is only
 * replayable when the method has no body semantics; otherwise the retry would
 * throw "body used already" and mask the real transport error.
 */
export function isReplayableRequest(input, init) {
  if (typeof Request !== "undefined" && input instanceof Request) {
    return init == null && (input.method === "GET" || input.method === "HEAD");
  }
  if (!init) return true;
  if (init.signal?.aborted) return false;
  const body = init.body;
  if (body === undefined || body === null) return true;
  if (typeof body === "string") return true;
  if (typeof body === "object") {
    if (body instanceof ArrayBuffer) return true;
    if (ArrayBuffer.isView(body)) return true;
    if (typeof URLSearchParams !== "undefined" && body instanceof URLSearchParams) return true;
    if (typeof Blob !== "undefined" && body instanceof Blob) return true;
  }
  return false;
}

// ─────────────────────────────────────────────────────────────────────────────
// undici resolution — pi's OWN copy, so dispatchers and fetch share an instance
// ─────────────────────────────────────────────────────────────────────────────

const PI_PACKAGE_NAME = "@earendil-works/pi-coding-agent";

/** Walk up from a file until the pi coding-agent package root is found. */
export function findPiPackageRoot(startFile) {
  if (!startFile) return null;
  let dir;
  try {
    dir = dirname(realpathSync(startFile));
  } catch {
    return null;
  }
  for (let i = 0; i < 12; i++) {
    const pkgJson = join(dir, "package.json");
    if (existsSync(pkgJson)) {
      try {
        const pkg = JSON.parse(readFileSync(pkgJson, "utf8"));
        if (pkg?.name === PI_PACKAGE_NAME) return dir;
      } catch {
        /* keep walking */
      }
    }
    const parent = dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
  return null;
}

/**
 * Locate pi-coding-agent package roots under a pi-node install root. Needed
 * when `argv[1]` is not pi's bundle (SDK/RPC embedding, wrappers, tests) and
 * as a general belt-and-braces: the same discovery `scripts/patch-pi-retry.sh`
 * performs for its own patch targets.
 */
export function findPiPackageRootsInNodeRoot(
  nodeRoot = process.env.PI_NODE_ROOT || join(homedir(), ".local/share/pi-node"),
) {
  const roots = [];
  let entries;
  try {
    entries = readdirSync(nodeRoot, { withFileTypes: true });
  } catch {
    return roots;
  }
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    for (const layout of [join("lib", "node_modules"), "node_modules"]) {
      const candidate = join(nodeRoot, entry.name, layout, PI_PACKAGE_NAME);
      if (existsSync(join(candidate, "package.json"))) roots.push(candidate);
    }
  }
  return roots;
}

/**
 * Resolve undici from pi's own install. Sharing the instance matters: the
 * dispatcher we build is handed to pi's globally-installed fetch, and a
 * cross-instance dispatcher relies on undocumented duck-typing.
 *
 * @returns {{ undici: object|null, path: string|null, source: string }}
 */
export function resolvePiUndici({
  argv = process.argv,
  requireFrom = import.meta.url,
  nodeRoots = findPiPackageRootsInNodeRoot(),
} = {}) {
  const candidates = [];
  const piRoot = findPiPackageRoot(argv?.[1]);
  if (piRoot) candidates.push({ from: join(piRoot, "package.json"), source: "pi-package" });
  if (argv?.[1]) candidates.push({ from: argv[1], source: "argv-realpath" });
  for (const root of nodeRoots) {
    candidates.push({ from: join(root, "package.json"), source: "pi-node-root" });
  }
  candidates.push({ from: requireFrom, source: "extension-own" });

  for (const candidate of candidates) {
    try {
      const require = createRequire(candidate.from);
      const resolved = require.resolve("undici");
      const mod = require(resolved);
      if (mod?.EnvHttpProxyAgent && mod?.Agent && mod?.fetch) {
        return { undici: mod, path: resolved, source: candidate.source };
      }
    } catch {
      /* try the next candidate */
    }
  }
  return { undici: null, path: null, source: "unresolved" };
}

// ─────────────────────────────────────────────────────────────────────────────
// Transparent-retry scope
// ─────────────────────────────────────────────────────────────────────────────

/** Host of a URL string / URL / Request, lowercased; null when unparseable. */
export function hostOf(input) {
  const url = typeof input === "string" || input instanceof URL ? String(input) : input?.url;
  try {
    return new URL(String(url)).host.toLowerCase();
  } catch {
    return null;
  }
}

/**
 * Resolve the HOSTS whose requests the wrapper may re-send.
 *
 * A retry is a re-send, and only pi's own provider calls are safe to re-send
 * (pi already retries them, and the failure this module exists for is a provider
 * one). Other extensions POST non-idempotent writes through the same global
 * fetch — `extensions/tortoise-capture/index.ts:329` creates a session that way
 * — so an unconditional retry would silently duplicate THEIR work. The allowlist
 * is therefore not a hardcoded provider list: it is derived from the providers
 * the user already configured in `models.json` (exactly the traffic pi itself
 * would retry), overridable with `PI_HTTP_POOL_RETRY_HOSTS` (empty = never
 * retry — the pool is still clamped and still flushed).
 */
export function resolveRetryHosts({ env = process.env, modelsJson = null } = {}) {
  const hosts = new Set();
  const explicit = env?.[RETRY_HOSTS_ENV];
  if (explicit !== undefined && explicit !== null) {
    for (const entry of String(explicit).split(",")) {
      const host = entry.trim().toLowerCase();
      if (host) hosts.add(host);
    }
    return hosts;
  }
  for (const provider of Object.values(modelsJson?.providers ?? {})) {
    for (const key of ["baseUrl", "baseURL"]) {
      const host = hostOf(provider?.[key]);
      if (host) hosts.add(host);
    }
  }
  return hosts;
}

/** True when a request URL's host is on the retry allowlist. */
export function isRetryableHost(input, retryHosts) {
  if (!retryHosts || retryHosts.size === 0) return false;
  const host = hostOf(input);
  return host !== null && retryHosts.has(host);
}

// ─────────────────────────────────────────────────────────────────────────────
// Dispatcher construction
// ─────────────────────────────────────────────────────────────────────────────

/** Parse a positive integer env value; returns `fallback` when absent/invalid. */
export function parsePositiveIntEnv(value, fallback) {
  if (value === undefined || value === null || String(value).trim() === "") return fallback;
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? Math.floor(parsed) : fallback;
}

/**
 * Parse a non-negative integer (0 is meaningful — pi's `httpIdleTimeoutMs: 0`
 * means "disabled", and undici treats `headersTimeout`/`bodyTimeout` 0 as no
 * timeout; verified). Returns `fallback` when absent/invalid.
 */
export function parseNonNegativeIntEnv(value, fallback) {
  if (value === undefined || value === null || String(value).trim() === "") return fallback;
  if (String(value).trim().toLowerCase() === "disabled") return 0;
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? Math.floor(parsed) : fallback;
}

/**
 * Resolve the dispatcher options. `keepAliveTimeout` is deliberately ABSENT:
 * undici's 4s default already handles hint-less servers, and shortening it
 * would reduce steady-state reuse without buying anything the ceiling does not.
 */
export function resolveDispatcherOptions(env = process.env, { settingsJson = null } = {}) {
  const keepAliveMaxMs = parsePositiveIntEnv(env[KEEPALIVE_MAX_ENV], DEFAULT_KEEPALIVE_MAX_MS);
  const settingsIdle = parseNonNegativeIntEnv(settingsJson?.httpIdleTimeoutMs, null);
  const idleTimeoutMs =
    parseNonNegativeIntEnv(env[IDLE_TIMEOUT_ENV], settingsIdle) ?? DEFAULT_HTTP_IDLE_TIMEOUT_MS;
  return {
    allowH2: false,
    proxyTunnel: true,
    keepAliveMaxTimeout: keepAliveMaxMs,
    headersTimeout: idleTimeoutMs,
    bodyTimeout: idleTimeoutMs,
    connect: { autoSelectFamilyAttemptTimeout: AUTO_SELECT_FAMILY_ATTEMPT_TIMEOUT_MS },
  };
}

/**
 * Stable signature of the dispatcher options this module owns — the idempotence
 * key for `reconfigure`, so a re-resolved-but-identical configuration is a no-op.
 */
function dispatcherOptionsSignature(o) {
  return [
    o?.allowH2,
    o?.proxyTunnel,
    o?.keepAliveMaxTimeout,
    o?.headersTimeout,
    o?.bodyTimeout,
    o?.connect?.autoSelectFamilyAttemptTimeout,
  ].join("|");
}

/** Set equality for the retry-host allowlist. */
function sameHostSet(a, b) {
  if (!a || !b || a.size !== b.size) return false;
  for (const host of a) if (!b.has(host)) return false;
  return true;
}

// Undici can emit an internal Client/Pool "error" while terminating a socket
// (notably a mid-stream fetch body — the exact kill this module targets).
// EventEmitter's unhandled-'error' special case would crash the pi process, so
// pi's own `configureHttpDispatcher` attaches a no-op listener to the
// dispatcher AND to every Client/Pool it creates via `clientFactory`/`factory`.
// We now mirror that wiring exactly: an Agent forwards only drain/connect/
// disconnect/connectionError, so a listener on the top-level dispatcher alone
// does NOT cover an inner Client's 'error'.
const ignoreDispatcherError = () => {};
function withUndiciErrorListener(dispatcher, EventEmitterCtor = EventEmitter) {
  if (dispatcher instanceof EventEmitterCtor) {
    EventEmitterCtor.prototype.on.call(dispatcher, "error", ignoreDispatcherError);
  }
  return dispatcher;
}

/** Build a hygienic dispatcher from pi's undici copy (error-guard wiring
 *  mirrors pi's `configureHttpDispatcher`). */
export function createHygienicDispatcher(undici, options) {
  const clientFactory = (origin, clientOptions) =>
    withUndiciErrorListener(new undici.Client(origin, clientOptions));
  const factory = (origin, clientOptions) => {
    if (clientOptions?.connections === 1) return clientFactory(origin, clientOptions);
    return withUndiciErrorListener(
      new undici.Pool(origin, { ...clientOptions, factory: clientFactory }),
    );
  };
  return withUndiciErrorListener(
    new undici.EnvHttpProxyAgent({ ...options, clientFactory, factory }),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// The resilient fetch wrapper
// ─────────────────────────────────────────────────────────────────────────────

export const installMarker = Symbol.for("agent-infra.http-pool-hygiene.installed");

/**
 * Wrap a fetch so that:
 *  - every request goes through OUR dispatcher (bounded hint ceiling), and
 *  - a transport failure rotates the pool, and
 *  - a transport failure on an allowlisted provider host retries once on a
 *    fresh socket (never a re-send to any other host — see `resolveRetryHosts`),
 *  - the *next* request after any transport failure also gets a fresh pool.
 *
 * Steady state is preserved: no extra retries on success, no keepalive
 * disabling, no per-request socket churn.
 */
export function createResilientFetch({
  fetchImpl,
  undici,
  options,
  retryHosts = new Set(),
  log = () => {},
  retryDelayMs = 0,
  now = () => Date.now(),
} = {}) {
  let dispatcher = createHygienicDispatcher(undici, options);
  let dirty = false;
  let rotations = 0;
  let activeRequests = 0;
  let retryHostSet = retryHosts;
  // The wrapper is built on the fetch it was HANDED (in production, pi's own
  // `undici.fetch`), not on the ambient `globalThis.fetch`. If something replaces
  // `globalThis.fetch` later, `rebase` re-points the wrapper at the NEW fetch
  // instead of discarding it (see index.ts).
  let baseFetch = fetchImpl;
  // The fetch BELOW every wrapper layer that has ever adopted us. Used to break
  // re-entrancy: if an adopted fetch delegates back into `globalThis.fetch`
  // (which is us), calling `nativeFetch` runs the request once, below the stack
  // — instead of recursing forever.
  const nativeFetch = fetchImpl;
  // Re-entrancy detection is PER CALL, via async context — NOT a process-wide
  // counter. A counter is a concurrency bug: while request A awaits, the counter
  // is non-zero, so a CONCURRENT request B would be mistaken for a re-entrant
  // call and silently bypass the clamped dispatcher (and the retry) entirely.
  const reentrancy = new AsyncLocalStorage();
  let observability = { firstRequestLogged: false, intercepted: 0, bypassed: 0 };
  const stats = { transparentRetries: 0, connectionErrors: 0, flushCalls: 0, lastErrorAt: null };

  const rotate = (reason) => {
    const previous = dispatcher;
    dispatcher = createHygienicDispatcher(undici, options);
    rotations++;
    dirty = false;
    // Best-effort teardown of the poisoned pool. Never await: a dispatcher that
    // refuses to close must not stall the request path. `close()` (not
    // `destroy()`) is deliberate — in-flight requests on the old pool are
    // allowed to finish; only new ones move to the fresh pool.
    try {
      Promise.resolve(previous.close()).catch(() => {});
    } catch {
      /* ignore */
    }
    log(`[http-pool-hygiene] rotated connection pool (${reason}; rotation #${rotations})`);
    return dispatcher;
  };

  const resilient = async (input, init) => {
    // Re-entrancy: an adopted fetch that delegates to `globalThis.fetch` calls
    // back into us *within this call's async context*. Pass the request straight
    // through to the fetch below all wrapper layers — no retry, no dispatcher
    // override — so one request cannot recurse through the wrapper chain. A
    // concurrent, unrelated request has no store and is handled normally.
    if (reentrancy.getStore() !== undefined) {
      observability.bypassed++;
      return nativeFetch(input, init);
    }
    return reentrancy.run(true, () => handleCall(input, init));
  };

  const handleCall = async (input, init) => {
    // Visibility guard against silent inertness: if the wrapper is installed but
    // pi (or a future pi version) routes provider traffic around
    // `globalThis.fetch`, NOTHING hits this wrapper and every counter stays at
    // zero. Log the first interception once so a session log distinguishes
    // "working" from "installed but bypassed".
    observability.intercepted++;
    if (!observability.firstRequestLogged) {
      observability.firstRequestLogged = true;
      log(`[http-pool-hygiene] first request intercepted (fetch wrapper is live)`);
    }
    // A caller that supplies its own dispatcher (undici's `init.dispatcher`
    // extension) owns its transport; we still guard the retry.
    const callerDispatcher = init?.dispatcher;
    const useDispatcher = callerDispatcher ?? (dirty ? rotate("pre-retry-flush") : dispatcher);
    activeRequests++;
    try {
      return await baseFetch(input, { ...init, dispatcher: useDispatcher });
    } catch (err) {
      if (!isConnectionClassError(err)) throw err;
      stats.connectionErrors++;
      stats.lastErrorAt = now();
      dirty = true;
      // Only pi's own provider traffic may be re-sent.
      if (callerDispatcher || !isReplayableRequest(input, init) || !isRetryableHost(input, retryHostSet)) {
        throw err;
      }
      if (retryDelayMs > 0) await new Promise((r) => setTimeout(r, retryDelayMs));
      const fresh = rotate("transparent-retry");
      stats.transparentRetries++;
      try {
        const response = await baseFetch(input, { ...init, dispatcher: fresh });
        dirty = false;
        return response;
      } catch (err2) {
        // The retry is the LAST attempt. A non-transport failure on the fresh
        // pool means the POOL was not the problem (leave it clean); a transport
        // failure means it still is — the next request must not be offered a
        // pool that just failed twice.
        dirty = isConnectionClassError(err2);
        throw err2;
      }
    } finally {
      activeRequests--;
    }
  };

  /** Re-point the wrapper at a newly-installed base fetch (never discards it). */
  const rebase = (nextBaseFetch) => {
    if (typeof nextBaseFetch === "function") baseFetch = nextBaseFetch;
    return baseFetch;
  };

  /**
   * Rebuild the dispatcher when the transport configuration changes — at
   * runtime (`httpIdleTimeoutMs`) or because providers were added/removed.
   * `nextRetryHosts` refreshes the re-send allowlist, which would otherwise be
   * frozen at install time (a provider added to `models.json` later would never
   * get the transparent retry, with nothing in the log to say so).
   */
  const reconfigure = (nextOptions, nextRetryHosts) => {
    const next = nextOptions ?? options;
    const optionsChanged = dispatcherOptionsSignature(next) !== dispatcherOptionsSignature(options);
    const hostsChanged = nextRetryHosts ? !sameHostSet(nextRetryHosts, retryHostSet) : false;
    options = next;
    if (nextRetryHosts) retryHostSet = nextRetryHosts;
    // IDEMPOTENT: this runs on every `session_start`/`turn_start` (pi rebuilds
    // its OWN dispatcher on a runtime `httpIdleTimeoutMs` change but never
    // replaces `globalThis.fetch`, so the re-assert is the only place that can
    // notice). An unchanged configuration must NOT rotate the pool — rotating
    // per turn would churn connections and undo the steady-state reuse the
    // clamp deliberately preserves.
    if (!optionsChanged && !hostsChanged) return dispatcher;
    return rotate("reconfigure");
  };

  /** Force the next request (and any retry) onto a fresh pool. */
  const flush = (reason = "manual") => {
    stats.flushCalls++;
    return rotate(reason);
  };

  return {
    fetch: resilient,
    flush,
    rebase,
    reconfigure,
    snapshot: () => ({
      rotations,
      dirty,
      activeRequests,
      intercepted: observability.intercepted,
      bypassed: observability.bypassed,
      retryHosts: [...retryHostSet],
      ...stats,
      keepAliveMaxTimeout: options.keepAliveMaxTimeout,
      headersTimeout: options.headersTimeout,
      bodyTimeout: options.bodyTimeout,
    }),
  };
}

/**
 * Install `wrapper` as `globalThis.fetch`, idempotently, without fighting pi's
 * own installer.
 *
 * pi's `configureHttpDispatcher()` replaces `globalThis.fetch` only when it
 * still sees the fetch IT installed (`shouldInstallGlobals` in
 * dist/core/http-dispatcher.js — bundle chunk-JVUZSMYM.js). Once our wrapper is
 * in place that test is false, so `pi update`-era reconfigures set the global
 * dispatcher without clobbering the wrapper. We still re-assert on
 * `session_start` in case something else replaced it, and say so loudly.
 */
export function installResilientFetch(wrapper) {
  const existing = globalThis.fetch;
  if (existing?.[installMarker] === wrapper) return { installed: false, reason: "already-installed" };
  if (typeof wrapper?.fetch !== "function") return { installed: false, reason: "no-fetch" };
  const fn = wrapper.fetch;
  Object.defineProperty(fn, installMarker, { value: wrapper, enumerable: false });
  wrapper.previous = existing;
  wrapper.installedAt = Date.now();
  globalThis.fetch = fn;
  return { installed: true, reason: "installed", previous: existing };
}

/** True when `globalThis.fetch` is currently our wrapper. */
export function isWrapperInstalled(wrapper) {
  return globalThis.fetch?.[installMarker] === wrapper;
}

/** Read `httpIdleTimeoutMs` from the agent settings file (best effort).
 *
 * `0` is pi's "timeouts disabled" value and MUST survive this read — parsing it
 * with the *positive*-int helper silently turned "disabled" into "unset" (and
 * then into the 300 s fallback), i.e. it re-armed the very timeouts the user
 * switched off. */
export function readIdleTimeoutFromSettings(settingsPath) {
  if (!settingsPath || !existsSync(settingsPath)) return null;
  try {
    const parsed = JSON.parse(readFileSync(settingsPath, "utf8"));
    return parseNonNegativeIntEnv(parsed?.httpIdleTimeoutMs, null);
  } catch {
    return null;
  }
}
