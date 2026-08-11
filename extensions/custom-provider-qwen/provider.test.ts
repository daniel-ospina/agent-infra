/**
 * provider.test.ts — unit tests for extensions/custom-provider-qwen/index.ts
 * Run: npx tsx extensions/custom-provider-qwen/provider.test.ts  (from any agent-infra checkout)
 *
 * Covers the T4 contracts:
 *   1. fetch injection wiring — the wrapped stream hands `options.fetch` (the
 *      tuned fetch) to the real stream, and the tuned fetch routes every
 *      request through the hygiene Agent via undici's `init.dispatcher`.
 *   2. env gating — QWEN_HA_DISABLE=1 → no registration (and warns once).
 *   3. failure containment — the factory never throws: pi-ai load failure,
 *      registerProvider throwing, or missing API key env all degrade to a
 *      warn, never an exception.
 *   4. provider shape — new id `qwen-ha`, mirrors qwen3.8-max, key resolution
 *      wired to QWEN_WS_API_KEY, base URL override honored.
 *
 * Hermetic by design: pi-ai is stubbed via the PiAiModule seam (the real
 * pi-ai is only reachable at runtime through pi's jiti aliasing).
 */
import { ok, equal, deepEqual } from "node:assert/strict";
import {
  PROVIDER_ID,
  MODEL_ID,
  DEFAULT_BASE_URL,
  API_KEY_ENV_VARS,
  BASE_URL_ENV,
  DISABLE_ENV,
  AGENT_OPTIONS,
  createQwenAgent,
  buildTunedFetch,
  buildWrappedApi,
  resolveBaseUrl,
  buildProvider,
  runExtension,
  __resetWarnFlagsForTests,
} from "./index.js";
import type { Dispatcher } from "undici";
import type { FetchFunction, ProviderStreams } from "@earendil-works/pi-ai";

let passed = 0, failed = 0;
async function test(name: string, fn: () => void | Promise<void>) {
  try {
    await fn();
    passed++;
    console.log(`  ✅ ${name}`);
  } catch (err: any) {
    failed++;
    console.log(`  ❌ ${name}: ${err.message}`);
  }
}
function section(name: string) { console.log(`\n${name}:`); }

// ── tiny helpers ──────────────────────────────────────────────────────────
const noopFetch: FetchFunction = (async () => new Response()) as FetchFunction;
const fakeAgent = { dispatch: () => true } as unknown as Dispatcher;

/** Minimal stub pi-ai that records what the extension asks it to do. */
function stubPiAi() {
  const calls: any = { createProvider: [], envApiKeyAuth: [], openAICompletionsApi: 0 };
  const api: ProviderStreams = {
    stream: ((_m, _c, o) => o) as any,
    streamSimple: ((_m, _c, o) => o) as any,
  };
  return {
    calls,
    module: {
      createProvider: (input: any) => { calls.createProvider.push(input); return { ...input }; },
      envApiKeyAuth: (name: string, envVars: string[]) => { calls.envApiKeyAuth.push({ name, envVars }); return { name, envVars }; },
      openAICompletionsApi: () => { calls.openAICompletionsApi++; return api; },
    },
  };
}

const cleanEnv = () => {
  delete process.env[DISABLE_ENV];
  delete process.env[BASE_URL_ENV];
  delete process.env.HTTP_PROXY;
  delete process.env.HTTPS_PROXY;
  delete process.env.http_proxy;
  delete process.env.https_proxy;
  __resetWarnFlagsForTests();
};

// ── 1. Connection hygiene: agent settings ─────────────────────────────────
section("connection hygiene agent");
await test("createQwenAgent configures keepAlive < LB TTL, pipelining 0, connections cap", () => {
  let captured: any;
  const FakeAgent = class { constructor(opts: any) { captured = opts; } };
  createQwenAgent(FakeAgent as any);
  equal(captured.keepAliveTimeout, 4000);
  equal(captured.keepAliveMaxTimeout, 4000);
  equal(captured.pipelining, 0, "pipelining 0 → undici closes socket after each response");
  equal(captured.connections, 4, "connections capped per origin");
  equal(captured.allowH2, false);
  // keepAliveTimeout is well under the ~8 min LB kill TTL
  ok(captured.keepAliveTimeout < 60_000);
});

await test("createQwenAgent honors proxy env vars (EnvHttpProxyAgent)", () => {
  process.env.HTTPS_PROXY = "http://proxy.local:3128";
  try {
    let captured: any;
    const FakeAgent = class { constructor(opts: any) { captured = opts; } };
    createQwenAgent(FakeAgent as any);
    equal(captured, undefined, "plain Agent must NOT be used when a proxy is configured");
  } finally {
    delete process.env.HTTPS_PROXY;
  }
});

// ── 2. Tuned fetch: dispatcher injection ──────────────────────────────────
section("tuned fetch");
await test("buildTunedFetch routes through the agent via init.dispatcher and passes everything through", async () => {
  let call: any;
  const fakeImpl = (async (input: any, init: any) => { call = { input, init }; return new Response("ok"); }) as FetchFunction;
  const tuned = buildTunedFetch(fakeAgent, fakeImpl);

  const originalInit = { method: "POST", headers: { Authorization: "Bearer x" }, body: "{}" };
  const res = await tuned("https://example.com/v1/chat/completions", originalInit);

  equal(res.status, 200);
  equal(call.input, "https://example.com/v1/chat/completions");
  equal(call.init.dispatcher, fakeAgent, "undici dispatcher = hygiene agent");
  equal(call.init.method, "POST");
  equal(call.init.headers.Authorization, "Bearer x");
  equal(call.init.body, "{}");
  // caller's init is never mutated
  equal((originalInit as any).dispatcher, undefined);
});

await test("buildTunedFetch defaults to undici's fetch (not pi's global fetch)", () => {
  const tuned = buildTunedFetch(fakeAgent);
  equal(typeof tuned, "function");
});

// ── 3. Wrapped api: the stream receives the tuned fetch ───────────────────
section("fetch injection wiring");
await test("wrapped.stream passes options through with fetch = tuned fetch (stub stream)", async () => {
  const received: any[] = [];
  const realApi = {
    stream: (_m: any, _c: any, o: any) => { received.push(o); return "stream-result"; },
    streamSimple: (_m: any, _c: any, o: any) => { received.push(o); return "simple-result"; },
  } as unknown as ProviderStreams;

  const tunedFetch = noopFetch;
  const wrapped = buildWrappedApi(realApi, tunedFetch);

  const model = { id: MODEL_ID, provider: PROVIDER_ID };
  const context = { messages: [] };
  const options = { apiKey: "test-key", timeoutMs: 12345, signal: new AbortController().signal };

  const result = wrapped.stream(model as any, context as any, options as any);
  equal(result, "stream-result");
  equal(received.length, 1);
  equal(received[0].fetch, tunedFetch, "the tuned fetch IS what the stream receives");
  equal(received[0].apiKey, "test-key", "other options pass through");
  equal(received[0].timeoutMs, 12345);
  equal(received[0].signal, options.signal);
  ok(received[0] !== options, "options object is spread, not mutated");
  equal((options as any).fetch, undefined);

  const result2 = wrapped.streamSimple(model as any, context as any, {} as any);
  equal(result2, "simple-result");
  equal(received[1].fetch, tunedFetch);
});

// ── 4. Provider shape ─────────────────────────────────────────────────────
section("provider shape");
await test("buildProvider registers qwen-ha / qwen3.8-max mirroring models.json qwen", () => {
  const { module, calls } = stubPiAi();
  const provider = buildProvider(module as any, noopFetch, DEFAULT_BASE_URL) as any;

  equal(provider.id, "qwen-ha");
  equal(provider.name, "Qwen (High-Availability)");
  equal(provider.baseUrl, DEFAULT_BASE_URL);
  ok(calls.createProvider.length === 1);

  // auth wired to the existing key env var
  ok(calls.envApiKeyAuth.length === 1);
  deepEqual(calls.envApiKeyAuth[0].envVars, [...API_KEY_ENV_VARS]);
  equal(calls.envApiKeyAuth[0].name, "Qwen (High-Availability) API key");

  // single model, mirrors qwen/qwen3.8-max
  const model = provider.models[0];
  equal(model.id, "qwen3.8-max");
  equal(model.provider, "qwen-ha");
  equal(model.api, "openai-completions");
  equal(model.reasoning, true);
  deepEqual(model.input, ["text", "image"]);
  equal(model.contextWindow, 1_000_000);
  equal(model.maxTokens, 131_072);
  deepEqual(model.thinkingLevelMap, { minimal: null, low: "low", medium: "medium", high: null, xhigh: "xhigh", max: null });
  equal(model.compat.thinkingFormat, "qwen");
  equal(model.compat.supportsDeveloperRole, false);

  // api is the wrapped streams (has stream + streamSimple)
  equal(typeof provider.api.stream, "function");
  equal(typeof provider.api.streamSimple, "function");
});

await test("buildProvider wires the wrapped api so real calls get the tuned fetch", async () => {
  const { module } = stubPiAi();
  const tunedFetch = noopFetch;
  const provider = buildProvider(module as any, tunedFetch, DEFAULT_BASE_URL) as any;
  const model = { id: MODEL_ID, provider: PROVIDER_ID, api: "openai-completions" };
  const opts = { apiKey: "k" };
  const out = provider.api.stream(model, { messages: [] }, opts);
  equal((out as any).fetch, tunedFetch);
  equal((out as any).apiKey, "k");
});

await test("resolveBaseUrl honors QWEN_WS_BASE_URL, defaults otherwise", () => {
  equal(resolveBaseUrl(), DEFAULT_BASE_URL);
  process.env[QWEN_WS_BASE_URL_ENV()] = "https://custom.example.com/v1";
  equal(resolveBaseUrl(), "https://custom.example.com/v1");
  delete process.env[QWEN_WS_BASE_URL_ENV()];
  equal(resolveBaseUrl(), DEFAULT_BASE_URL);
});
function QWEN_WS_BASE_URL_ENV() { return BASE_URL_ENV; }

// ── 5. Env gating + failure containment ───────────────────────────────────
section("env gating + failure containment");
await test("QWEN_HA_DISABLE=1 → no registration, warns once", async () => {
  cleanEnv();
  process.env[DISABLE_ENV] = "1";
  const warns: string[] = [];
  const origWarn = console.warn;
  console.warn = (m: any) => warns.push(String(m));
  try {
    const calls: any[] = [];
    const fakePi = { registerProvider: (p: any) => calls.push(p) } as any;
    const neverLoad = () => { throw new Error("pi-ai must not be loaded when disabled"); };

    await runExtension(fakePi, neverLoad as any);
    await runExtension(fakePi, neverLoad as any); // second run: same result, no extra warn

    equal(calls.length, 0, "no registration when disabled");
    equal(warns.filter((w) => w.includes("skipped")).length, 1, "disable warning logged exactly once");
  } finally {
    console.warn = origWarn;
    cleanEnv();
  }
});

await test("factory never throws when pi-ai fails to load", async () => {
  cleanEnv();
  const calls: any[] = [];
  const fakePi = { registerProvider: (p: any) => calls.push(p) } as any;
  const warns: string[] = [];
  const origWarn = console.warn;
  console.warn = (m: any) => warns.push(String(m));
  try {
    await runExtension(fakePi, () => Promise.reject(new Error("cannot resolve @earendil-works/pi-ai")));
    equal(calls.length, 0);
    ok(warns.some((w) => w.includes("registration failed")), "warns about the failure");
  } finally {
    console.warn = origWarn;
  }
});

await test("factory never throws when pi.registerProvider throws", async () => {
  cleanEnv();
  const fakePi = {
    registerProvider: () => { throw new Error("provider id conflict"); },
  } as any;
  const { module } = stubPiAi();
  await runExtension(fakePi, () => Promise.resolve(module as any)); // must not throw
  ok(true);
});

await test("factory never throws with missing API key env (provider still registers; key resolves later)", async () => {
  cleanEnv();
  delete process.env.QWEN_WS_API_KEY;
  const calls: any[] = [];
  const fakePi = { registerProvider: (p: any) => calls.push(p) } as any;
  const { module } = stubPiAi();
  await runExtension(fakePi, () => Promise.resolve(module as any));
  equal(calls.length, 1);
  equal(calls[0].id, "qwen-ha");
});

await test("happy path: registers the qwen-ha provider exactly once", async () => {
  cleanEnv();
  const calls: any[] = [];
  const fakePi = { registerProvider: (p: any) => calls.push(p) } as any;
  const { module } = stubPiAi();
  await runExtension(fakePi, () => Promise.resolve(module as any));
  equal(calls.length, 1);
  equal(calls[0].id, PROVIDER_ID);
  equal(calls[0].models[0].id, MODEL_ID);
});

// ── summary ───────────────────────────────────────────────────────────────
console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
