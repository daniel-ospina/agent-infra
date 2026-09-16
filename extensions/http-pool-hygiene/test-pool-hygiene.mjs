/**
 * test-pool-hygiene.mjs — #1110 dead-connection reuse defence.
 *
 * Run:  node extensions/http-pool-hygiene/test-pool-hygiene.mjs
 * (part of the zero-dep `extensions/*\/test*.mjs` CI glob)
 *
 * Parts:
 *   1  classification + replayability + dispatcher options (pure)
 *   2  resilient-fetch mechanics against a scripted transport (pure)
 *   3  REAL undici + a load balancer that advertises a keep-alive TTL longer
 *      than it honours — the defect, and the fix, end to end
 *   4  the extension module itself: real index.ts load, factory install,
 *      message_end flush policy
 *   5  undici resolver (pi's own install, so fetch and dispatcher share a copy)
 *
 * Part 3 SKIPS (loudly) when no undici is resolvable — CI runners have no pi
 * install and no vendored copy; everything else still runs everywhere.
 */

import { createRequire } from "node:module";
import { once } from "node:events";
import { EventEmitter } from "node:events";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, readFileSync, realpathSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { register, registerHooks, stripTypeScriptTypes } from "node:module";

import {
  DEFAULT_KEEPALIVE_MAX_MS,
  DEFAULT_HTTP_IDLE_TIMEOUT_MS,
  KEEPALIVE_MAX_ENV,
  createHygienicDispatcher,
  createResilientFetch,
  findPiPackageRoot,
  installResilientFetch,
  isConnectionClassError,
  isConnectionClassMessage,
  isReplayableRequest,
  isWrapperInstalled,
  parseNonNegativeIntEnv,
  parsePositiveIntEnv,
  resolveDispatcherOptions,
  resolvePiUndici,
  resolveRetryHosts,
  hostOf,
  isRetryableHost,
  readIdleTimeoutFromSettings,
  undiciGateOutcome,
} from "./pool-hygiene.mjs";
import { postJson, startLoadBalancer, startUpstream, sleep } from "./lb-harness.mjs";

const HERE = fileURLToPath(new URL(".", import.meta.url));
let pass = 0, fail = 0, skip = 0;
function check(name, cond, detail = "") {
  console.log(`${cond ? "✅" : "❌"} ${name}${cond || !detail ? "" : ` — ${detail}`}`);
  cond ? pass++ : fail++;
}
function eq(name, got, expected) {
  const ok = got === expected;
  console.log(`${ok ? "✅" : "❌"} ${name}: ${got}${ok ? "" : ` (expected ${expected})`}`);
  ok ? pass++ : fail++;
}
function skipped(name, why) {
  console.log(`⏭️  ${name}: SKIPPED — ${why}`);
  skip++;
}

const SAVED_FETCH = globalThis.fetch;

// ─────────────────────────────────────────────────────────────────────────
console.log("── Part 1: classification, replayability, dispatcher options ──");

eq("P1.1 ECONNRESET code is transport-class", isConnectionClassError({ code: "ECONNRESET" }), true);
eq("P1.2 nested cause code is inspected", isConnectionClassError(Object.assign(new Error("fetch failed"), { cause: { code: "UND_ERR_SOCKET" } })), true);
eq("P1.3 OpenAI SDK 'Connection error.' is transport-class", isConnectionClassError(new Error("Connection error.")), true);
eq("P1.4 mid-stream 'terminated' is transport-class", isConnectionClassMessage("terminated"), true);
eq("P1.5 'socket hang up' is transport-class", isConnectionClassMessage("socket hang up"), true);
eq("P1.6 HTTP status text is NOT transport-class (429)", isConnectionClassMessage("429 Too Many Requests"), false);
eq("P1.7 quota text is NOT transport-class", isConnectionClassMessage("insufficient_quota"), false);
eq("P1.8 'overloaded' is NOT transport-class", isConnectionClassMessage("overloaded_error"), false);
eq("P1.9 empty message is not transport-class", isConnectionClassMessage(""), false);
eq("P1.10 undefined error is not transport-class", isConnectionClassError(undefined), false);

eq("P1.11 JSON string body is replayable", isReplayableRequest("/x", { method: "POST", body: '{"a":1}' }), true);
eq("P1.12 bodyless request is replayable", isReplayableRequest("/x", { method: "GET" }), true);
eq("P1.13 no init is replayable", isReplayableRequest("/x", undefined), true);
eq("P1.14 ReadableStream body is NOT replayable", isReplayableRequest("/x", { method: "POST", body: new ReadableStream() }), false);
eq("P1.15 aborted signal is NOT replayable", isReplayableRequest("/x", { signal: { aborted: true } }), false);
eq("P1.16 Uint8Array body is replayable", isReplayableRequest("/x", { body: new Uint8Array([1]) }), true);

const defaults = resolveDispatcherOptions({}, {});
eq("P1.17 default hint ceiling is 30s", defaults.keepAliveMaxTimeout, DEFAULT_KEEPALIVE_MAX_MS);
eq("P1.18 keepAliveTimeout is NOT overridden (no reuse regression)", "keepAliveTimeout" in defaults, false);
eq("P1.19 allowH2 false (matches pi)", defaults.allowH2, false);
eq("P1.20 proxyTunnel true (matches pi)", defaults.proxyTunnel, true);
eq("P1.21 we never override keepAliveTimeout or its threshold (only the ceiling)",
  "keepAliveTimeout" in defaults || "keepAliveTimeoutThreshold" in defaults, false);
eq("P1.22 idle timeout falls back to pi's DEFAULT_HTTP_IDLE_TIMEOUT_MS", defaults.bodyTimeout, DEFAULT_HTTP_IDLE_TIMEOUT_MS);
const withEnv = resolveDispatcherOptions({ [KEEPALIVE_MAX_ENV]: "5000" }, {});
eq("P1.23 env overrides the ceiling", withEnv.keepAliveMaxTimeout, 5000);
eq("P1.24 invalid env is ignored", resolveDispatcherOptions({ [KEEPALIVE_MAX_ENV]: "nope" }, {}).keepAliveMaxTimeout, DEFAULT_KEEPALIVE_MAX_MS);
eq("P1.25 settings idle timeout is mirrored", resolveDispatcherOptions({}, { settingsJson: { httpIdleTimeoutMs: 1234 } }).bodyTimeout, 1234);
eq("P1.26 parsePositiveIntEnv rejects negatives", parsePositiveIntEnv("-5", 7), 7);
eq("P1.27 httpIdleTimeoutMs 0 (disabled) is passed through as 0, not defaulted",
  resolveDispatcherOptions({}, { settingsJson: { httpIdleTimeoutMs: 0 } }).bodyTimeout, 0);
eq("P1.28 the string 'disabled' is honoured", parseNonNegativeIntEnv("disabled", null), 0);
eq("P1.29 negative idle timeout falls back", resolveDispatcherOptions({}, { settingsJson: { httpIdleTimeoutMs: -1 } }).bodyTimeout, DEFAULT_HTTP_IDLE_TIMEOUT_MS);
// P1.30-32 — the CI gate control itself (an inert gate is a false PASS).
eq("P1.30 undici available → run", undiciGateOutcome({ undiciAvailable: true }), "run");
eq("P1.31 undici missing → skip by default", undiciGateOutcome({ undiciAvailable: false }), "skip");
eq("P1.32 undici REQUIRED but missing → fail, not a green skip", undiciGateOutcome({ undiciAvailable: false, requireUndici: true }), "fail");
// P1.33-36 — the classifier must not treat EVERY `fetch failed` as a dead
// socket: that generic message is what Node/undici attach to a TLS or DNS
// failure too, and matching it would rotate the pool and re-send for a failure
// the pool has nothing to do with. Classification is code-first; the generic
// message is only consulted when there is no cause code to classify on.
eq("P1.33 self-signed TLS failure is NOT transport-class",
  isConnectionClassError(Object.assign(new TypeError("fetch failed"), { cause: { code: "DEPTH_ZERO_SELF_SIGNED_CERT" } })), false);
eq("P1.34 DNS failure is NOT transport-class",
  isConnectionClassError(Object.assign(new TypeError("fetch failed"), { cause: { code: "ENOTFOUND" } })), false);
eq("P1.35 a 'fetch failed' with no cause CODE still is (nothing better to classify on)",
  isConnectionClassError(Object.assign(new TypeError("fetch failed"), { cause: {} })), true);
eq("P1.36 a transport cause code still wins over the generic message",
  isConnectionClassError(Object.assign(new TypeError("fetch failed"), { cause: { code: "ECONNRESET" } })), true);

// ─────────────────────────────────────────────────────────────────────────
console.log("\n── Part 2: resilient-fetch mechanics (scripted transport) ──");

// The transparent retry is allowlisted by host (a re-send is only safe for the
// provider traffic pi itself retries — see resolveRetryHosts). Part 2's URLs use
// the `x` host, so allowlist it explicitly; the deny path gets its own arm below.
const RETRY_HOSTS = new Set(["x"]);

class FakeAgent extends EventEmitter {
  constructor(options) { super(); this.options = options; this.closeCalls = 0; }
  close() { this.closeCalls++; return Promise.resolve(); }
}
class FakeClient extends EventEmitter {
  constructor(origin, options) { super(); this.origin = origin; this.options = options; }
  close() { return Promise.resolve(); }
}
class FakePool extends EventEmitter {
  constructor(origin, options) { super(); this.origin = origin; this.options = options; }
  close() { return Promise.resolve(); }
}
const fakeUndici = {
  EnvHttpProxyAgent: FakeAgent,
  Agent: FakeAgent,
  Client: FakeClient,
  Pool: FakePool,
  fetch: async () => new Response("ok"),
};

{
  // P2.0 — pi attaches a no-op 'error' listener to the dispatcher AND to every
  // Client/Pool it creates (clientFactory/factory); an Agent forwards only
  // drain/connect/disconnect/connectionError, so the inner guard is what stops
  // an internal socket 'error' during a mid-stream kill from crashing pi.
  const d = createHygienicDispatcher(fakeUndici, resolveDispatcherOptions({}, {}));
  eq("P2.0a the dispatcher itself carries an error guard", d.listenerCount("error") >= 1, true);
  const client = d.options.clientFactory("http://x", {});
  eq("P2.0b created Clients carry an error guard", client.listenerCount("error") >= 1, true);
  const pool = d.options.factory("http://x", { connections: 3 });
  eq("P2.0c created Pools carry an error guard", pool.listenerCount("error") >= 1, true);
  eq("P2.0d connections===1 path returns a guarded Client, not a Pool",
    d.options.factory("http://x", { connections: 1 }) instanceof FakeClient, true);
  // The guard must actually swallow an emitted error rather than rethrow.
  let threw = false;
  try { client.emit("error", new Error("socket teardown")); } catch { threw = true; }
  eq("P2.0e an emitted Client error is swallowed, not thrown", threw, false);
}

function scriptedTransport(behaviour) {
  const calls = [];
  const fetchImpl = async (input, init) => {
    const call = { input, init, dispatcher: init?.dispatcher };
    calls.push(call);
    const verdict = behaviour(calls.length, call);
    if (verdict instanceof Error) throw verdict;
    return verdict ?? new Response("ok");
  };
  return { fetchImpl, calls };
}

{
  const t = scriptedTransport(() => new Response("ok"));
  const w = createResilientFetch({ fetchImpl: t.fetchImpl, undici: fakeUndici, retryHosts: RETRY_HOSTS, options: resolveDispatcherOptions({}, {}) });
  await w.fetch("http://x/1", { method: "POST", body: "{}" });
  eq("P2.1 steady state sends every request through our dispatcher", t.calls[0].dispatcher instanceof FakeAgent, true);
  eq("P2.2 dispatcher carries the clamp", t.calls[0].dispatcher.options.keepAliveMaxTimeout, DEFAULT_KEEPALIVE_MAX_MS);
  eq("P2.3 no rotation without an error", w.snapshot().rotations, 0);
  eq("P2.4 no transparent retry without an error", w.snapshot().transparentRetries, 0);
}

{
  const t = scriptedTransport((n) => (n === 1 ? Object.assign(new Error("socket hang up"), { code: "ECONNRESET" }) : new Response("recovered")));
  const w = createResilientFetch({ fetchImpl: t.fetchImpl, undici: fakeUndici, retryHosts: RETRY_HOSTS, options: resolveDispatcherOptions({}, {}) });
  const res = await w.fetch("http://x/2", { method: "POST", body: "{}" });
  eq("P2.5 transport failure transparently retries", await res.text(), "recovered");
  eq("P2.6 call count = 1 failed + 1 retried", t.calls.length, 2);
  eq("P2.7 the retry used a FRESH dispatcher", t.calls[1].dispatcher !== t.calls[0].dispatcher, true);
  eq("P2.8 the poisoned dispatcher was closed", t.calls[0].dispatcher.closeCalls >= 1, true);
  eq("P2.9 one rotation recorded", w.snapshot().rotations, 1);
  eq("P2.10 dirty flag cleared after a clean retry", w.snapshot().dirty, false);
}

{
  const t = scriptedTransport((n) => (n === 1 ? Object.assign(new Error("terminated"), { code: "ECONNRESET" }) : new Response("ok")));
  const w = createResilientFetch({ fetchImpl: t.fetchImpl, undici: fakeUndici, retryHosts: RETRY_HOSTS, options: resolveDispatcherOptions({}, {}) });
  let threw = null;
  try { await w.fetch("http://x/3", { method: "POST", body: new ReadableStream() }); } catch (e) { threw = e; }
  eq("P2.11 non-replayable body is NOT transparently retried", t.calls.length, 1);
  check("P2.12 the original error still propagates", threw?.code === "ECONNRESET", `threw=${threw?.message}`);
  eq("P2.13 pool marked dirty for the next request", w.snapshot().dirty, true);
  const before = t.calls.length;
  await w.fetch("http://x/4", { method: "POST", body: "{}" });
  eq("P2.14 next request uses a fresh dispatcher", t.calls[before].dispatcher !== t.calls[0].dispatcher, true);
  eq("P2.15 pre-retry flush counted as a rotation", w.snapshot().rotations >= 1, true);
}

{
  const t = scriptedTransport(() => Object.assign(new Error("429 rate limit"), { code: "RATE_LIMIT" }));
  const w = createResilientFetch({ fetchImpl: t.fetchImpl, undici: fakeUndici, retryHosts: RETRY_HOSTS, options: resolveDispatcherOptions({}, {}) });
  let threw = null;
  try { await w.fetch("http://x/5", { method: "POST", body: "{}" }); } catch (e) { threw = e; }
  eq("P2.16 non-transport error is not retried", t.calls.length, 1);
  eq("P2.17 non-transport error does not rotate the pool", w.snapshot().rotations, 0);
  check("P2.18 non-transport error propagates unchanged", threw?.code === "RATE_LIMIT", `threw=${threw?.message}`);
}

{
  const t = scriptedTransport(() => new Response("ok"));
  const w = createResilientFetch({ fetchImpl: t.fetchImpl, undici: fakeUndici, retryHosts: RETRY_HOSTS, options: resolveDispatcherOptions({}, {}) });
  await w.fetch("http://x/6", { method: "POST", body: "{}" });
  const before = t.calls[0].dispatcher;
  w.flush("test");
  await w.fetch("http://x/7", { method: "POST", body: "{}" });
  eq("P2.19 flush() forces the next request onto a new dispatcher", t.calls[1].dispatcher !== before, true);
  eq("P2.20 flush() counted", w.snapshot().flushCalls, 1);
}

{
  const t = scriptedTransport(() => new Response("ok"));
  const w = createResilientFetch({ fetchImpl: t.fetchImpl, undici: fakeUndici, retryHosts: RETRY_HOSTS, options: resolveDispatcherOptions({}, {}) });
  const owned = new FakeAgent({});
  await w.fetch("http://x/8", { method: "POST", body: "{}", dispatcher: owned });
  eq("P2.21 a caller-supplied dispatcher is respected", t.calls[0].dispatcher === owned, true);
}

{
  // P2.25 — rebase: if another extension replaces globalThis.fetch, the wrapper
  // must adopt the new fetch as its base instead of discarding it.
  const calls = [];
  const first = async () => { calls.push("first"); return new Response("first"); };
  const second = async () => { calls.push("second"); return new Response("second"); };
  const w = createResilientFetch({ fetchImpl: first, undici: fakeUndici, options: resolveDispatcherOptions({}, {}) });
  await w.fetch("http://x/9", { method: "POST", body: "{}" });
  w.rebase(second);
  const res = await w.fetch("http://x/10", { method: "POST", body: "{}" });
  eq("P2.25a rebase re-points the wrapper at the replacement fetch", await res.text(), "second");
  eq("P2.25b the original fetch is not used after rebase", JSON.stringify(calls), JSON.stringify(["first", "second"]));
}

{
  // P2.26 — visibility: the first intercepted request is logged once, so an
  // installed-but-bypassed wrapper is distinguishable in a session log.
  const logs = [];
  const t = scriptedTransport(() => new Response("ok"));
  const w = createResilientFetch({ fetchImpl: t.fetchImpl, undici: fakeUndici, retryHosts: RETRY_HOSTS, options: resolveDispatcherOptions({}, {}), log: (m) => logs.push(m) });
  await w.fetch("http://x/11", { method: "POST", body: "{}" });
  await w.fetch("http://x/12", { method: "POST", body: "{}" });
  eq("P2.26a first interception logged exactly once", logs.filter((l) => /first request intercepted/.test(l)).length, 1);
  eq("P2.26b interception counter tracks requests", w.snapshot().intercepted, 2);
}

{
  // P2.27 — the P1 finding: a re-send is only safe for pi's provider traffic.
  // A transport error on a NON-allowlisted host must still rotate the pool (so
  // the next request is clean) but must NEVER re-send the request — otherwise a
  // sibling extension's non-idempotent POST would be silently duplicated.
  const t = scriptedTransport(() => Object.assign(new Error("socket hang up"), { code: "ECONNRESET" }));
  const w = createResilientFetch({ fetchImpl: t.fetchImpl, undici: fakeUndici, retryHosts: RETRY_HOSTS, options: resolveDispatcherOptions({}, {}) });
  let threw = null;
  try {
    await w.fetch("http://not-a-provider/8", { method: "POST", body: "{}" });
  } catch (err) {
    threw = err;
  }
  check("P2.27a the error still surfaces (no silent swallow)", threw !== null, String(threw));
  eq("P2.27b no re-send to a non-allowlisted host", t.calls.length, 1);
  eq("P2.27c no transparent retry counted", w.snapshot().transparentRetries, 0);
  eq("P2.27d the pool is still marked dirty for the next request", w.snapshot().dirty, true);
  await w.fetch("http://not-a-provider/9", { method: "POST", body: "{}" }).catch(() => {});
  eq("P2.27e the next request got a fresh pool despite no retry", w.snapshot().rotations >= 1, true);
}

{
  // P2.28 — a failed retry must leave the pool dirty (the module's stated
  // invariant: the next request after ANY transport failure gets a fresh pool).
  const t = scriptedTransport(() => Object.assign(new Error("terminated"), { code: "UND_ERR_SOCKET" }));
  const w = createResilientFetch({ fetchImpl: t.fetchImpl, undici: fakeUndici, retryHosts: RETRY_HOSTS, options: resolveDispatcherOptions({}, {}) });
  await w.fetch("http://x/13", { method: "POST", body: "{}" }).catch(() => {});
  eq("P2.28a the retry was attempted", w.snapshot().transparentRetries, 1);
  eq("P2.28b the pool is left dirty after a doubly-failed pool", w.snapshot().dirty, true);
}

{
  // P2.29 — re-entrancy: if the adopted fetch delegates back to the global
  // fetch (a composing wrapper — the standard pattern), the wrapper must not
  // recurse. It passes the request straight through to the fetch below it.
  const t = scriptedTransport(() => new Response("ok"));
  const w = createResilientFetch({ fetchImpl: t.fetchImpl, undici: fakeUndici, retryHosts: RETRY_HOSTS, options: resolveDispatcherOptions({}, {}) });
  const previousFetch = globalThis.fetch;
  const composing = async (input, init) => w.fetch(input, init); // delegates back into the wrapper
  w.rebase(composing);
  globalThis.fetch = w.fetch;
  try {
    const res = await w.fetch("http://x/14", { method: "POST", body: "{}" });
    eq("P2.29a a self-delegating fetch does not recurse", await res.text(), "ok");
    eq("P2.29b exactly one underlying request was made", t.calls.length, 1);
  } finally {
    globalThis.fetch = previousFetch;
  }
}

{
  // P2.30 — a Request instance carries an already-consumed body, so a POST is
  // NOT replayable through it; retrying would throw "body used already" and mask
  // the real transport error.
  eq("P2.30a a POST Request is not replayable", isReplayableRequest(new Request("http://x/15", { method: "POST", body: "{}" }), undefined), false);
  eq("P2.30b a GET Request is replayable", isReplayableRequest(new Request("http://x/16"), undefined), true);
}

{
  // P2.31 — rotation must not kill in-flight requests: `close()`, never
  // `destroy()`. A request already in flight on the poisoned pool finishes.
  let release;
  const gate = new Promise((r) => { release = r; });
  const t = scriptedTransport(async () => {
    await gate;
    return new Response("in-flight-ok");
  });
  const w = createResilientFetch({ fetchImpl: t.fetchImpl, undici: fakeUndici, retryHosts: RETRY_HOSTS, options: resolveDispatcherOptions({}, {}) });
  const inflight = w.fetch("http://x/17", { method: "POST", body: "{}" });
  eq("P2.31a the request is counted as in flight", w.snapshot().activeRequests, 1);
  await w.flush("concurrent-rotation");
  release();
  const res = await inflight;
  eq("P2.31b rotation does not abort an in-flight request", await res.text(), "in-flight-ok");
  eq("P2.31c in-flight count returns to zero", w.snapshot().activeRequests, 0);
  eq("P2.31d the rotation still happened", w.snapshot().rotations, 1);
}

{
  // P2.32 — reconfigure: pi rebuilds the dispatcher when httpIdleTimeoutMs
  // changes at runtime; a stale option set must not be pinned over the new one.
  const t = scriptedTransport(() => new Response("ok"));
  const w = createResilientFetch({ fetchImpl: t.fetchImpl, undici: fakeUndici, retryHosts: RETRY_HOSTS, options: resolveDispatcherOptions({}, {}) });
  eq("P2.32a initial idle timeout mirrored", w.snapshot().bodyTimeout, DEFAULT_HTTP_IDLE_TIMEOUT_MS);
  w.reconfigure(resolveDispatcherOptions({}, { settingsJson: { httpIdleTimeoutMs: 4200 } }));
  eq("P2.32b reconfigure adopts the new timeout", w.snapshot().bodyTimeout, 4200);
  eq("P2.32c reconfigure rotates onto a fresh pool", w.snapshot().rotations, 1);
}

{
  // P2.33-36 — retry allowlist derivation (the P1 finding's control surface).
  const derived = resolveRetryHosts({ env: {}, modelsJson: { providers: { a: { baseUrl: "https://api.example.com/v1" }, b: { baseURL: "http://localhost:8080" } } } });
  eq("P2.33 hosts derive from configured provider base URLs", [...derived].sort().join(","), "api.example.com,localhost:8080");
  eq("P2.34 an explicit env allowlist overrides the derivation",
    [...resolveRetryHosts({ env: { PI_HTTP_POOL_RETRY_HOSTS: "One.Example, two.example" }, modelsJson: { providers: { a: { baseUrl: "https://api.example.com" } } } })].join(","),
    "one.example,two.example");
  eq("P2.35 an explicitly EMPTY allowlist disables the retry", resolveRetryHosts({ env: { PI_HTTP_POOL_RETRY_HOSTS: "" }, modelsJson: { providers: { a: { baseUrl: "https://api.example.com" } } } }).size, 0);
  eq("P2.36 no configuration → no host is retryable",
    isRetryableHost("https://api.example.com/v1/chat", resolveRetryHosts({ env: {}, modelsJson: null })), false);
  eq("P2.37 an allowlisted host matches including its port", isRetryableHost("http://localhost:8080/v1", derived), true);
  eq("P2.38 host comparison is case/URL-safe", hostOf("HTTPS://API.Example.COM/x"), "api.example.com");
}

{
  // P2.41 — CONCURRENCY (the cycle-3 P1): re-entrancy detection must be per
  // call, not a process-wide counter. Two overlapping requests must BOTH go
  // through our clamped dispatcher; a counter would mistake the second for a
  // re-entrant call and silently bypass the whole fix.
  let release;
  const gate = new Promise((r) => { release = r; });
  const t = scriptedTransport(async () => {
    await gate;
    return new Response("ok");
  });
  const w = createResilientFetch({ fetchImpl: t.fetchImpl, undici: fakeUndici, retryHosts: RETRY_HOSTS, options: resolveDispatcherOptions({}, {}) });
  const first = w.fetch("http://x/18", { method: "POST", body: "{}" });
  const second = w.fetch("http://x/19", { method: "POST", body: "{}" });
  release();
  await Promise.all([first, second]);
  eq("P2.41a both concurrent requests ran", t.calls.length, 2);
  eq("P2.41b no concurrent request was mistaken for a re-entrant call", w.snapshot().bypassed, 0);
  check("P2.41c both concurrent requests got OUR dispatcher",
    t.calls.every((c) => c.dispatcher && typeof c.dispatcher.close === "function"),
    JSON.stringify(t.calls.map((c) => Boolean(c.dispatcher))));
  eq("P2.41d both were counted as intercepted", w.snapshot().intercepted, 2);
}

{
  // P2.42-43 — reconfigure can refresh the retry allowlist, so a provider added
  // after install is not permanently un-retryable.
  const t = scriptedTransport(() => Object.assign(new Error("socket hang up"), { code: "ECONNRESET" }));
  const w = createResilientFetch({ fetchImpl: t.fetchImpl, undici: fakeUndici, retryHosts: RETRY_HOSTS, options: resolveDispatcherOptions({}, {}) });
  eq("P2.42 a non-allowlisted host is not retried", await w.fetch("http://new-provider/20", { method: "POST", body: "{}" }).then(() => "ok", () => "threw"), "threw");
  w.reconfigure(resolveDispatcherOptions({}, {}), new Set(["new-provider"]));
  await w.fetch("http://new-provider/21", { method: "POST", body: "{}" }).catch(() => {});
  eq("P2.43 reconfigure refreshes the allowlist", w.snapshot().retryHosts.join(","), "new-provider");
}

{
  // P2.39-40 — the settings path must preserve pi's `0` = disabled.
  const dir = mkdtempSync(join(tmpdir(), "pool-hygiene-settings-"));
  try {
    const file = join(dir, "settings.json");
    writeFileSync(file, JSON.stringify({ httpIdleTimeoutMs: 0 }));
    eq("P2.39 httpIdleTimeoutMs 0 survives the settings read", readIdleTimeoutFromSettings(file), 0);
    writeFileSync(file, JSON.stringify({ httpIdleTimeoutMs: 1234 }));
    eq("P2.40 a positive setting survives the settings read", readIdleTimeoutFromSettings(file), 1234);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

{
  const prev = globalThis.fetch;
  const t = scriptedTransport(() => new Response("ok"));
  const w = createResilientFetch({ fetchImpl: t.fetchImpl, undici: fakeUndici, retryHosts: RETRY_HOSTS, options: resolveDispatcherOptions({}, {}) });
  const r1 = installResilientFetch(w);
  eq("P2.22 install reports installed", r1.installed, true);
  eq("P2.23 globalThis.fetch is the wrapper", isWrapperInstalled(w), true);
  const r2 = installResilientFetch(w);
  eq("P2.24 re-install is idempotent", r2.reason, "already-installed");
  globalThis.fetch = prev;
}

// ─────────────────────────────────────────────────────────────────────────
console.log("\n── Part 3: real undici + lying keep-alive edge ──");

function resolveUndiciForTest() {
  const fromPi = resolvePiUndici();
  if (fromPi.undici) return fromPi;
  for (const from of [join(HERE, "package.json"), join(HERE, "..", "custom-provider-qwen", "package.json")]) {
    try {
      const resolved = createRequire(from).resolve("undici");
      const mod = createRequire(from)(resolved);
      if (mod?.EnvHttpProxyAgent && mod?.fetch) return { undici: mod, path: resolved, source: "vendored" };
    } catch { /* next */ }
  }
  return { undici: null, path: null, source: "unresolved" };
}

const real = resolveUndiciForTest();
const gate = undiciGateOutcome({
  undiciAvailable: Boolean(real.undici),
  requireUndici: process.env.PI_HTTP_POOL_REQUIRE_UNDICI === "1",
});
if (gate !== "run") {
  const why = "no undici resolvable (no pi install, no vendored copy) — the p3 real-transport arms (including the RED baseline and the keepAliveMaxTimeout falsifier) did not run; Part 1/2/4/5 still cover the logic";
  if (gate === "fail") {
    check(`P3: real-transport integration REQUIRED but unavailable — ${why}`, false, "PI_HTTP_POOL_REQUIRE_UNDICI=1 is set, so a missing undici is a gate failure, not a skip");
  } else {
    console.log(`⚠️  P3: real-transport integration NOT RUN — ${why}`);
    skipped("P3: real-transport integration", why);
  }
} else {
  console.log(`     undici: ${real.source} (${real.path})`);
  const undici = real.undici;
  const options = resolveDispatcherOptions({ [KEEPALIVE_MAX_ENV]: "1000" }, {});

  // A: the defect. A pi-shaped dispatcher (no ceiling) trusts the edge's
  // advertised TTL and reuses a socket the edge already reaped.
  {
    const up = await startUpstream();
    const lb = await startLoadBalancer({ upstreamPort: up.port, idleReapMs: 1500, advertiseKeepAlive: true });
    const url = `http://127.0.0.1:${lb.port}/v1/chat`;
    const piShaped = new undici.EnvHttpProxyAgent({
      allowH2: false, proxyTunnel: true, bodyTimeout: 600000, headersTimeout: 600000,
      connect: { autoSelectFamilyAttemptTimeout: 2000 },
    });
    const post = async () => {
      try { const r = await undici.fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body: '{"a":1}', dispatcher: piShaped }); await r.text(); return { ok: true }; }
      catch (e) { return { ok: false, code: e?.cause?.code ?? e?.code, message: String(e?.message ?? e) }; }
    };
    await post();
    await sleep(1800);
    const poisoned = await post();
    eq("P3.1 RED: pi-shaped dispatcher reuses a reaped socket (ECONNRESET)", poisoned.ok, false);
    eq("P3.2 RED: it really was a reuse of a reaped socket", lb.stats.rstOnReuse >= 1, true);
    await piShaped.close().catch(() => {});
    await lb.close(); await up.close();
  }

  // B: the fix. Bounded hint ceiling → the idle socket is dropped client-side
  // before the edge can reap it, so the next request opens a fresh connection.
  {
    const up = await startUpstream();
    const lb = await startLoadBalancer({ upstreamPort: up.port, idleReapMs: 1500, advertiseKeepAlive: true });
    const url = `http://127.0.0.1:${lb.port}/v1/chat`;
    const w = createResilientFetch({
      fetchImpl: (input, init) => undici.fetch(input, init),
      undici, options,
    });
    const post = async () => {
      try { const r = await w.fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body: '{"a":1}' }); await r.text(); return { ok: true }; }
      catch (e) { return { ok: false, code: e?.cause?.code ?? e?.code, message: String(e?.message ?? e) }; }
    };
    const first = await post();
    const rstsBefore = lb.stats.rstOnReuse;
    const connsBefore = lb.stats.clientConnections;
    await sleep(1800);
    const afterIdle = await post();
    eq("P3.3 first request succeeds", first.ok, true);
    eq("P3.4 FIX: request after the edge's TTL still succeeds", afterIdle.ok, true);
    eq("P3.5 FIX: no write onto a reaped socket", lb.stats.rstOnReuse - rstsBefore, 0);
    eq("P3.6 FIX: it opened a new connection (fresh socket)", lb.stats.clientConnections > connsBefore, true);
    // P3.16 — headers/body timeout 0 is pi's "disabled" value. Assert against
    // REAL undici (not a reading) that 0 means "no timeout" rather than
    // "abort immediately", because the extension passes the user's 0 through.
    {
      const up = await startUpstream({ delayMs: 250 });
      const lb = await startLoadBalancer({ upstreamPort: up.port });
      const url = `http://127.0.0.1:${lb.port}/v1/chat`;
      const zero = createHygienicDispatcher(undici, { ...options, headersTimeout: 0, bodyTimeout: 0 });
      let status = null;
      try {
        const r = await undici.fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body: '{"a":1}', dispatcher: zero });
        status = r.status;
        await r.text();
      } catch (err) {
        status = `ERR ${err?.cause?.code ?? err?.code ?? err?.message}`;
      }
      eq("P3.16 timeouts=0 means no timeout (a slow response still completes)", status, 200);
      await zero.close().catch(() => {});
      await lb.close(); await up.close();
    }

    eq("P3.7 no transparent retry was needed", w.snapshot().transparentRetries, 0);
    await w.flush("test-cleanup");
    await lb.close(); await up.close();
  }

  // B2: the FALSIFIER for the operative knob. `keepAliveTimeout` alone does not
  // help — the server's own hint overrides it (`client-h1.js:682-689`), which is
  // why the ceiling must be clamped. This arm is what makes `keepAliveMaxTimeout`
  // the evidenced knob rather than a guess.
  {
    const up = await startUpstream();
    const lb = await startLoadBalancer({ upstreamPort: up.port, idleReapMs: 1500, advertiseKeepAlive: true });
    const url = `http://127.0.0.1:${lb.port}/v1/chat`;
    const shortTimeoutOnly = new undici.EnvHttpProxyAgent({
      allowH2: false, proxyTunnel: true,
      bodyTimeout: 600000, headersTimeout: 600000,
      keepAliveTimeout: 1000, keepAliveTimeoutThreshold: 200,
      connect: { autoSelectFamilyAttemptTimeout: 2000 },
    });
    const post = async () => {
      try { const r = await undici.fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body: '{"a":1}', dispatcher: shortTimeoutOnly }); await r.text(); return { ok: true }; }
      catch (e) { return { ok: false, code: e?.cause?.code ?? e?.code }; }
    };
    await post();
    await sleep(1800);
    const after = await post();
    eq("P3.15 FALSIFIER: keepAliveTimeout=1s alone still reuses the reaped socket", after.ok, false);
    await shortTimeoutOnly.close().catch(() => {});
    await lb.close(); await up.close();
  }

  // C: healthy endpoint — steady-state reuse must survive the clamp.
  {
    const up = await startUpstream();
    const lb = await startLoadBalancer({ upstreamPort: up.port }); // no reaping, no hint
    const url = `http://127.0.0.1:${lb.port}/v1/chat`;
    const w = createResilientFetch({ fetchImpl: (i, init) => undici.fetch(i, init), undici, options });
    for (let i = 0; i < 6; i++) {
      const r = await w.fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body: '{"a":1}' });
      await r.text();
    }
    check("P3.8 keep-alive reuse preserved on a healthy endpoint", lb.stats.clientConnections < 6,
      `connections=${lb.stats.clientConnections} for 6 requests — keepalive appears disabled`);
    eq("P3.9 no reaps on a healthy endpoint", lb.stats.rstOnReuse, 0);
    eq("P3.10 no spurious rotations", w.snapshot().rotations, 0);
    await w.flush("test-cleanup");
    await lb.close(); await up.close();
  }

  // D: flush-before-retry. An edge that reaps between requests: the wrapper
  // must recover on a fresh connection rather than hand pi's retry a dead one.
  // The LB stands in for the provider, so its host IS allowlisted for the
  // re-send — this arm exercises the provider-traffic path (a non-allowlisted
  // host must never be re-sent; P2.27 pins that).
  {
    const up = await startUpstream();
    const lb = await startLoadBalancer({ upstreamPort: up.port, idleReapMs: 20 });
    const url = `http://127.0.0.1:${lb.port}/v1/chat`;
    const w = createResilientFetch({
      fetchImpl: (i, init) => undici.fetch(i, init),
      undici,
      options,
      retryHosts: new Set([`127.0.0.1:${lb.port}`]),
    });
    const post = () => postJson((i, init) => w.fetch(i, init), url, { a: 1 });
    const first = await post();
    eq("P3.11 first request succeeds", first.ok, true);
    // Idle past the edge's reap window, then reuse: the pooled socket is dead.
    await sleep(60);
    const second = await post();
    eq("P3.12 recovery request succeeds without operator action", second.ok, true);
    const snap = w.snapshot();
    check("P3.13 a transport kill triggered recovery (rotation or retry)",
      snap.transparentRetries >= 1 || snap.rotations >= 1,
      `rotations=${snap.rotations} retries=${snap.transparentRetries} reaps=${lb.stats.reaps} rsts=${lb.stats.rstOnReuse}`);
    const third = await post();
    eq("P3.14 pool is not left poisoned (next request still succeeds)", third.ok, true);
    await w.flush("test-cleanup");
    await lb.close(); await up.close();
  }
}

// ─────────────────────────────────────────────────────────────────────────
console.log("\n── Part 4: the extension module itself ──");

{
  const hooks = await import(new URL("./module-load-hooks.mjs", import.meta.url).href);
  if (typeof stripTypeScriptTypes !== "function" || (typeof register !== "function" && typeof registerHooks !== "function")) {
    skipped("P4: real index.ts load", `node ${process.versions.node} lacks type-stripping hooks (needs Node >= 22.13)`);
  } else {
    if (typeof registerHooks === "function") registerHooks({ resolve: hooks.resolve, load: hooks.load });
    else register(new URL("./module-load-hooks.mjs", import.meta.url), import.meta.url);

    const prevFetch = globalThis.fetch;
    const prevDisable = process.env.PI_HTTP_POOL_HYGIENE;
    process.env.PI_HTTP_POOL_HYGIENE = "1";
    let mod;
    try {
      mod = await import(pathToFileURL(join(HERE, "index.ts")).href);
      eq("P4.1 index.ts default export is the extension factory", typeof mod.default, "function");

      const handlers = new Map();
      const fakePi = { on(name, fn) { if (!handlers.has(name)) handlers.set(name, []); handlers.get(name).push(fn); } };
      const logs = [];
      const resolved = { undici: fakeUndici, path: "/fake/undici", source: "fake" };
      await mod.runExtension(fakePi, {
        resolveUndici: () => resolved,
        readSettings: () => ({ httpIdleTimeoutMs: 600000 }),
        readModels: () => ({ providers: { mock: { baseUrl: "http://127.0.0.1:8081/v1" } } }),
        log: (...a) => logs.push(a.join(" ")),
      });
      const handle = mod.getHygieneHandle();
      eq("P4.2 factory installed the hygiene wrapper", handle.status, "installed");
      eq("P4.3 wrapper is globalThis.fetch", isWrapperInstalled(handle.wrapper), true);
      // P4.16-18 — the retry allowlist is derived from models.json, and the
      // install line names it (so an operator can see whether a re-send is armed).
      eq("P4.16 provider hosts from models.json become the retry allowlist", handle.retryHosts.join(","), "127.0.0.1:8081");
      check("P4.17 the install log names the retry hosts", logs.some((l) => /transparent retry hosts=127\.0\.0\.1:8081/.test(l)), logs[0]);
      check("P4.4 it registers session_start / turn_start / message_end", ["session_start", "turn_start", "message_end"].every((e) => handlers.has(e)),
        `registered: ${[...handlers.keys()].join(", ")}`);

      const before = handle.wrapper.snapshot().rotations;
      const messageEnd = handlers.get("message_end")[0];
      await messageEnd({ type: "message_end", message: { role: "assistant", stopReason: "error", errorMessage: "terminated" } });
      eq("P4.5 mid-stream 'terminated' flushes the pool before pi's retry", handle.wrapper.snapshot().rotations, before + 1);
      await messageEnd({ type: "message_end", message: { role: "assistant", stopReason: "error", errorMessage: "429 Too Many Requests" } });
      eq("P4.6 non-transport errors do not flush", handle.wrapper.snapshot().rotations, before + 1);
      await messageEnd({ type: "message_end", message: { role: "assistant", stopReason: "stop" } });
      eq("P4.7 successful turns do not flush", handle.wrapper.snapshot().rotations, before + 1);

      const turnStart = handlers.get("turn_start")[0];
      const foreignFetch = async () => new Response("foreign");
      globalThis.fetch = foreignFetch;
      await turnStart();
      eq("P4.8 turn_start re-asserts the wrapper when something replaced it", isWrapperInstalled(handle.wrapper), true);
      eq("P4.9 the replacement fetch was ADOPTED as the wrapper's base, not discarded",
        handle.wrapper.rebase() === foreignFetch, true);
      eq("P4.9b a single re-assert call is not double-wrapped", mod.reassertFetchWrapper(handle.wrapper, () => {}), false);

      eq("P4.10 flush policy helper agrees", mod.shouldFlushOnMessageEnd({ stopReason: "error", errorMessage: "socket hang up" }), true);
      eq("P4.11 flush policy ignores non-errors", mod.shouldFlushOnMessageEnd({ stopReason: "stop" }), false);

      // P4.18 — the transport options mirror the settings file, and a RE-ASSERT
      // refreshes them, so a runtime httpIdleTimeoutMs change is not pinned by
      // our stale copy. (Runs last: it installs a replacement wrapper.)
      const idleBefore = handle.wrapper.snapshot().bodyTimeout;
      globalThis.fetch = prevFetch;
      mod.__resetHygieneForTests();
      mod.installHygiene({
        resolveUndici: () => resolved,
        readSettings: () => ({ httpIdleTimeoutMs: 42 }),
        env: { PI_HTTP_POOL_HYGIENE: "1" },
        log: () => {},
        warn: () => {},
      });
      const refreshed = mod.getHygieneHandle().wrapper;
      check("P4.18 install mirrors the settings idle timeout", refreshed?.snapshot().bodyTimeout === 42,
        `before=${idleBefore} after=${refreshed?.snapshot().bodyTimeout}`);
      globalThis.fetch = async () => new Response("foreign");
      mod.reassertFetchWrapper(refreshed, () => {}, () => ({
        options: resolveDispatcherOptions({ PI_HTTP_POOL_KEEPALIVE_MAX_MS: "999" }, { settingsJson: { httpIdleTimeoutMs: 43 } }),
        retryHosts: new Set(["provider.example"]),
      }));
      check("P4.19 re-assert rebuilds the dispatcher from refreshed settings",
        refreshed.snapshot().bodyTimeout === 43 && refreshed.snapshot().keepAliveMaxTimeout === 999,
        `bodyTimeout=${refreshed.snapshot().bodyTimeout} ceiling=${refreshed.snapshot().keepAliveMaxTimeout}`);
      eq("P4.20 re-assert also refreshes the retry allowlist", refreshed.snapshot().retryHosts.join(","), "provider.example");

      // P4.25 — THE REAL pi PATH (the cycle-1 P1). pi's settings UI calls
      // `configureHttpDispatcher(timeoutMs)` at runtime, but it does NOT replace
      // `globalThis.fetch` once ours is installed (`shouldInstallGlobals` is
      // false), so the old `if (!wrapper || isWrapperInstalled(wrapper)) return`
      // early-return made the reconfigure path UNREACHABLE and silently pinned
      // whatever was resolved at install. This arm drives that exact shape —
      // wrapper still installed, NO fetch replacement — and pins both halves:
      // the change is picked up, and an unchanged config does not churn the pool.
      mod.__resetHygieneForTests();
      globalThis.fetch = prevFetch;
      const reHandles = new Map();
      const rePi = { on(name, fn) { if (!reHandles.has(name)) reHandles.set(name, []); reHandles.get(name).push(fn); } };
      let liveIdle = 1111;
      await mod.runExtension(rePi, {
        resolveUndici: () => resolved,
        readSettings: () => ({ httpIdleTimeoutMs: liveIdle }),
        readModels: () => ({ providers: { mock: { baseUrl: "http://127.0.0.1:8081/v1" } } }),
        env: { PI_HTTP_POOL_HYGIENE: "1" },
        log: () => {},
        warn: () => {},
      });
      const reHandle = mod.getHygieneHandle();
      eq("P4.25a install mirrors the settings timeout", reHandle.wrapper.snapshot().bodyTimeout, 1111);
      const rotationsAtInstall = reHandle.wrapper.snapshot().rotations;
      // The user changes the timeout. pi reconfigures its OWN dispatcher; it does
      // NOT touch globalThis.fetch (that is the whole point of this arm).
      liveIdle = 2222;
      check("P4.25b the wrapper is STILL installed (pi did not replace fetch)", isWrapperInstalled(reHandle.wrapper), true);
      await reHandles.get("turn_start")[0]();
      eq("P4.25c a runtime settings change IS picked up without a fetch replacement",
        reHandle.wrapper.snapshot().bodyTimeout, 2222);
      eq("P4.25d it rotated exactly once", reHandle.wrapper.snapshot().rotations, rotationsAtInstall + 1);
      // Idempotence: an unchanged configuration must not rotate (a per-turn
      // rotation would churn connections and undo steady-state reuse).
      await reHandles.get("turn_start")[0]();
      eq("P4.25e an unchanged configuration does NOT rotate the pool",
        reHandle.wrapper.snapshot().rotations, rotationsAtInstall + 1);
      // Disabled must remain a no-op in the enabled path.
      liveIdle = 0;
      await reHandles.get("turn_start")[0]();
      eq("P4.25f httpIdleTimeoutMs 0 (disabled) is honoured on reconfigure",
        reHandle.wrapper.snapshot().bodyTimeout, 0);

      // Disabled path must be inert and loud, not silently half-installed.
      globalThis.fetch = prevFetch;
      mod.__resetHygieneForTests();
      process.env.PI_HTTP_POOL_HYGIENE = "0";
      const disabledHandle = mod.installHygiene({ resolveUndici: () => resolved, env: { PI_HTTP_POOL_HYGIENE: "0" }, log: () => {}, warn: () => {} });
      eq("P4.12 kill switch leaves the transport untouched", disabledHandle.status, "disabled");
      eq("P4.13 kill switch does not install a wrapper", globalThis.fetch === prevFetch, true);
      // P4.26 — the spelling the extension's own announcement uses. A kill switch
      // that silently ignores a documented value reads as armed while the
      // extension stays on.
      for (const spelling of ["disabled", "DISABLED", "false", "FALSE", "0"]) {
        mod.__resetHygieneForTests();
        const h = mod.installHygiene({ resolveUndici: () => resolved, env: { PI_HTTP_POOL_HYGIENE: spelling }, log: () => {}, warn: () => {} });
        eq(`P4.26 kill switch spelling ${JSON.stringify(spelling)} disables`, h.status, "disabled");
      }
      for (const spelling of ["1", "true", "yes", ""]) {
        mod.__resetHygieneForTests();
        const h = mod.installHygiene({ resolveUndici: () => resolved, env: { PI_HTTP_POOL_HYGIENE: spelling }, log: () => {}, warn: () => {} });
        check(`P4.27 spelling ${JSON.stringify(spelling)} does NOT disable`, h.status !== "disabled", `status=${h.status}`);
      }

      // Unresolved undici must WARN (fail loud, never silent).
      const warnings = [];
      mod.__resetHygieneForTests();
      mod.installHygiene({
        resolveUndici: () => ({ undici: null, path: null, source: "unresolved" }),
        env: {},
        log: () => {},
        warn: (...a) => warnings.push(a.join(" ")),
      });
      eq("P4.14 unresolved undici is reported loudly", warnings.length, 1);
      check("P4.15 the warning names the consequence", /protection is OFF|#1110/.test(warnings[0] ?? ""), warnings[0]);

      // P4.21-23 — the PRODUCTION settings path (no injected reader): the real
      // settings.json must be consulted by BOTH install and re-assert. The
      // cycle-3 P1 was that re-assert called `deps.readSettings?.()` — undefined
      // in production — so it silently reset the user's `httpIdleTimeoutMs`
      // (including `0` = disabled) to the 300 s default.
      const agentDir = mkdtempSync(join(tmpdir(), "pool-hygiene-agentdir-"));
      const prevAgentDir = process.env.PI_CODING_AGENT_DIR;
      try {
        writeFileSync(join(agentDir, "settings.json"), JSON.stringify({ httpIdleTimeoutMs: 0 }));
        writeFileSync(join(agentDir, "models.json"), JSON.stringify({ providers: { mock: { baseUrl: "http://127.0.0.1:8081/v1" } } }));
        process.env.PI_CODING_AGENT_DIR = agentDir;
        process.env.PI_HTTP_POOL_HYGIENE = "1"; // the disabled-path test above turned it off
        globalThis.fetch = prevFetch;
        mod.__resetHygieneForTests();
        const prodHandlers = new Map();
        const prodPi = { on(name, fn) { if (!prodHandlers.has(name)) prodHandlers.set(name, []); prodHandlers.get(name).push(fn); } };
        await mod.runExtension(prodPi, { resolveUndici: () => resolved, log: () => {}, warn: () => {} });
        const prod = mod.getHygieneHandle();
        eq("P4.21 production install reads the real settings file (0 = disabled)", prod.wrapper?.snapshot().bodyTimeout, 0);
        eq("P4.22 production install reads the real models.json for retry hosts", prod.retryHosts.join(","), "127.0.0.1:8081");
        // Something replaced globalThis.fetch → the re-assert must re-read the
        // real files, not fall back to defaults.
        globalThis.fetch = async () => new Response("foreign");
        await prodHandlers.get("turn_start")[0]();
        eq("P4.23 re-assert PRESERVES the user's disabled timeout (not reset to 300000)",
          mod.getHygieneHandle().wrapper?.snapshot().bodyTimeout, 0);
        eq("P4.24 re-assert preserves the derived retry hosts",
          mod.getHygieneHandle().wrapper?.snapshot().retryHosts.join(","), "127.0.0.1:8081");
      } finally {
        if (prevAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR; else process.env.PI_CODING_AGENT_DIR = prevAgentDir;
        rmSync(agentDir, { recursive: true, force: true });
      }
    } finally {
      globalThis.fetch = prevFetch;
      if (prevDisable === undefined) delete process.env.PI_HTTP_POOL_HYGIENE; else process.env.PI_HTTP_POOL_HYGIENE = prevDisable;
      mod?.__resetHygieneForTests?.();
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────
console.log("\n── Part 5: undici resolver ──");

{
  const tmp = realpathSync(mkdtempSync(join(tmpdir(), "pool-hygiene-resolver-")));
  try {
    const pkgDir = join(tmp, "lib", "node_modules", "@earendil-works", "pi-coding-agent");
    mkdirSync(join(pkgDir, "dist", "bundle"), { recursive: true });
    writeFileSync(join(pkgDir, "package.json"), JSON.stringify({ name: "@earendil-works/pi-coding-agent", version: "0.0.0" }));
    const entry = join(pkgDir, "dist", "bundle", "cli.js");
    writeFileSync(entry, "// stub\n");
    eq("P5.1 findPiPackageRoot locates the package root", findPiPackageRoot(entry), pkgDir);
    eq("P5.2 findPiPackageRoot is null for a non-pi file", findPiPackageRoot(join(tmp, "nope.js")), null);
    const unresolved = resolvePiUndici({ argv: [process.execPath, entry], requireFrom: join(tmp, "no-such.js"), nodeRoots: [] });
    check("P5.3 an unresolvable undici degrades with a named source", unresolved.undici === null && unresolved.source === "unresolved",
      `source=${unresolved.source}`);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }

  const fromPi = resolvePiUndici();
  if (fromPi.undici) {
    // Any NAMED source is valid — "extension-own" is a legitimate candidate (the
    // copy bundled next to this extension, e.g. the CI install); the contract is
    // "a usable undici from a named candidate", not "from pi's install".
    check("P5.4 resolver names the source it resolved from",
      typeof fromPi.source === "string" && fromPi.source !== "unresolved" && fromPi.source.length > 0,
      `source=${fromPi.source}`);
    check("P5.5 resolved copy is a usable undici", Boolean(fromPi.undici.EnvHttpProxyAgent && fromPi.undici.fetch), true);
    // When invoked the way pi invokes it (argv[1] = pi's own bundle), the
    // resolver must pick that install first rather than scanning the node root.
    const piRoot = fromPi.path ? findPiPackageRoot(fromPi.path) : null;
    const bundle = piRoot ? join(piRoot, "dist", "bundle", "cli.js") : null;
    if (bundle && existsSync(bundle)) {
      eq("P5.6 argv[1]=pi bundle wins (same copy pi's fetch uses)", resolvePiUndici({ argv: [process.execPath, bundle] }).source, "pi-package");
    } else {
      skipped("P5.6 argv[1]=pi bundle wins", "pi bundle layout not found for the resolved copy");
    }
  } else {
    skipped("P5.4/P5.5/P5.6 real pi resolution", "no pi install on this machine");
  }
}

globalThis.fetch = SAVED_FETCH;
console.log(`\n${fail === 0 ? "✅" : "❌"} test-pool-hygiene: ${pass} passed, ${fail} failed, ${skip} skipped`);
process.exit(fail === 0 ? 0 : 1);
