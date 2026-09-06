/**
 * provider-exhaustion.test.ts — unit tests for extensions/provider-exhaustion.ts
 * (#476 Phase 3 — in-session exhaustion detection + child marker emission).
 *
 * Covers: mode classification, child marker eligibility (nonce gate), session
 * model splitting, family detection, message_end turn classification
 * (canonical 402 / credit-balance-too-low / auth-permanent / healthy / quoted
 * / user-tool messages), child marker emission (once-per-process, exact
 * sB1-contract bytes, never-duplicated), interactive durable latch + notice +
 * setModel hop, session_start proactive hop (interactive only), turn_start
 * restore-to-primary, PROVIDER_FAILOVER_DISABLE kill switch, and hermetic
 * latch isolation (never touches the live latch).
 *
 * Harness: a fake `pi` capturing registered handlers + setModel calls; a
 * swappable stderr sink for the writeSync marker; hermetic PI_CODING_AGENT_DIR
 * tmp dirs per latch-touching test.
 *
 * Run: npx tsx extensions/provider-exhaustion.test.ts
 */

import { ok, equal, deepEqual, notEqual } from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import extension, {
  isChildMode,
  childMarkerEligible,
  splitSessionModel,
  sessionFamily,
  classifySessionTurn,
  modelParts,
  buildChildMarker,
  interactiveHopTarget,
  interactiveRestoreTarget,
  _resetPendingMarkerForTests,
  _resetLatchSeenFamiliesForTests,
  _pendingMarkerForTests,
  _setMarkerSinkForTests,
  _setBannerSinkForTests,
} from "./provider-exhaustion.js";
import { readLatchState, setExhausted, clearExhaustion } from "./shared/provider-failover.js";

let passed = 0;
let failed = 0;
const allTests: Array<{ name: string; fn: () => void | Promise<void> }> = [];

function test(name: string, fn: () => void | Promise<void>) {
  allTests.push({ name, fn });
}

function section(name: string) {
  console.log(`\n${name}:`);
}

// ── Fake pi harness ────────────────────────────────────────────────────

interface FakePi {
  handlers: Map<string, Array<(event: any, ctx: any) => Promise<void> | void>>;
  setModelCalls: Array<{ id: string; provider: string }>;
  setModelResult: boolean | undefined;
  on: (event: string, handler: (event: any, ctx: any) => Promise<void> | void) => void;
  emit: (event: string, eventData: any, ctx?: any) => Promise<void>;
  setModel: (model: { id: string; provider: string }) => Promise<boolean>;
}

/** Model-object fixtures (real pi ctx.model is a Model object — round-2 P0). */
const REG = {
  find: (provider: string, modelId: string) => ({ id: modelId, provider, api: "openai-completions", baseUrl: "https://example.invalid" }),
};
const ctx = (mode: string, model: any) => ({ mode, model, modelRegistry: REG });

function modelObj(provider: string, id: string) {
  return REG.find(provider, id);
}

function makeFakePi(): FakePi {
  const pi: FakePi = {
    handlers: new Map(),
    setModelCalls: [],
    setModelResult: undefined,
    on(event, handler) {
      const list = pi.handlers.get(event) ?? [];
      list.push(handler);
      pi.handlers.set(event, list);
    },
    async emit(event, eventData, ctx = {}) {
      for (const h of pi.handlers.get(event) ?? []) {
        await h(eventData, ctx);
      }
    },
    async setModel(model: { id: string; provider: string }) {
      pi.setModelCalls.push({ id: model.id, provider: model.provider });
      return pi.setModelResult === undefined ? true : pi.setModelResult;
    },
  };
  return pi;
}

/** Managed env keys the harness owns. */
const MANAGED_ENV_KEYS = [
  "TASK_HEARTBEAT",
  "TASK_HEARTBEAT_NONCE",
  "PI_CODING_AGENT_DIR",
  "PROVIDER_FAILOVER_DISABLE",
  "PI_FAILOVER_NO_HOP",
  "TASK_EXHAUSTION_BLOCK",
  "PROVIDER_FAILOVER_BLOCKED",
] as const;

/** Ambient values at import time (the harness may itself run inside a task
 * sub-agent with TASK_HEARTBEAT/NONCE set — see the outer session). Managed
 * keys restore to these, NOT to per-test `saved` snapshots (which would
 * resurrect ambient heartbeat vars and leak them into later tests). */
const AMBIENT: Record<string, string | undefined> = {};
for (const k of MANAGED_ENV_KEYS) AMBIENT[k] = process.env[k];

function restoreEnv(): void {
  for (const k of MANAGED_ENV_KEYS) {
    const v = AMBIENT[k];
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
}

/** Apply a hermetic env: clear managed keys first (ambient heartbeat vars
 * must never leak into a test), then set env + per-test extras. */
function applyEnv(env: Record<string, string | undefined>, extra: Record<string, string> = {}): void {
  for (const k of MANAGED_ENV_KEYS) delete process.env[k];
  Object.assign(process.env, env, extra);
}

/** Hermetic env: fresh agent dir + stderr capture + banner capture sinks. */
function hermetic(): {
  env: Record<string, string | undefined>;
  cleanup: () => void;
  captured: string[];
  banners: Array<{ title: string; body: string }>;
} {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-pext-"));
  const env: Record<string, string | undefined> = { ...process.env, PI_CODING_AGENT_DIR: dir };
  delete env.PROVIDER_FAILOVER_DISABLE;
  delete env.PI_FAILOVER_NO_HOP;
  delete env.TASK_EXHAUSTION_BLOCK;
  delete env.TASK_HEARTBEAT;
  delete env.TASK_HEARTBEAT_NONCE;
  const captured: string[] = [];
  const banners: Array<{ title: string; body: string }> = [];
  _setMarkerSinkForTests((line) => captured.push(line));
  _setBannerSinkForTests((title, body) => banners.push({ title, body }));
  _resetPendingMarkerForTests();
  _resetLatchSeenFamiliesForTests();
  return {
    env,
    cleanup: () => {
      try { fs.rmSync(dir, { recursive: true, force: true }); } catch { /* ignore */ }
      _setMarkerSinkForTests((line: string) => fs.writeSync(2, line));
      _setBannerSinkForTests((title: string, body: string) => console.error(`\n⚠️  ${title}\n    ${body}\n`));
      _resetPendingMarkerForTests();
      _resetLatchSeenFamiliesForTests();
    },
    captured,
    banners,
  };
}

const canonical402 = { role: "assistant", stopReason: "error", errorMessage: "Error: 402 Insufficient Balance — prepaid credit exhausted" };
const lowBalanceMsg = { role: "assistant", stopReason: "error", errorMessage: "Error: credit balance too low, top up and retry" };
const authMsg = { role: "assistant", stopReason: "error", errorMessage: "Authentication Fails, Your api key: **** is invalid" };
const healthyMsg = { role: "assistant", stopReason: "end_turn", content: "all good" };
const quotedMsg = { role: "assistant", stopReason: "end_turn", content: 'the model said "Error: 402 Insufficient Balance"' };
const toolMsg = { role: "tool", errorMessage: "Error: 402 Insufficient Balance" };
const userMsg = { role: "user", errorMessage: "Error: 402 Insufficient Balance" };

// ── Pure helpers ───────────────────────────────────────────────────────

section("isChildMode / childMarkerEligible / splitSessionModel / sessionFamily");

test("isChildMode: print and json are children; tui is not", () => {
  equal(isChildMode("print"), true);
  equal(isChildMode("json"), true);
  equal(isChildMode("tui"), false);
  equal(isChildMode(undefined), false);
});

test("childMarkerEligible requires TASK_HEARTBEAT=1 AND a parent-injected nonce", () => {
  equal(childMarkerEligible({ TASK_HEARTBEAT: "1", TASK_HEARTBEAT_NONCE: "abc123" }), true);
  equal(childMarkerEligible({ TASK_HEARTBEAT: "1" }), false, "no nonce → no authenticating reader → never emit");
  equal(childMarkerEligible({ TASK_HEARTBEAT_NONCE: "abc123" }), false, "no TASK_HEARTBEAT → not a task child");
  equal(childMarkerEligible({ TASK_HEARTBEAT: "1", TASK_HEARTBEAT_NONCE: "" }), false);
  equal(childMarkerEligible({}), false);
});

test("splitSessionModel: #154 rules — first-slash split, claude default, else deepseek", () => {
  deepEqual(splitSessionModel("deepseek-v4-flash"), { provider: "deepseek", model: "deepseek-v4-flash" });
  deepEqual(splitSessionModel("claude-sonnet-4"), { provider: "anthropic", model: "claude-sonnet-4" });
  deepEqual(splitSessionModel("openrouter/deepseek/deepseek-v4-flash"), { provider: "openrouter", model: "deepseek/deepseek-v4-flash" });
  deepEqual(splitSessionModel("qwen-tp/deepseek-v4-flash-0731"), { provider: "qwen-tp", model: "deepseek-v4-flash-0731" });
  deepEqual(splitSessionModel(undefined), { provider: "deepseek", model: "" });
});

test("sessionFamily: alias-table detection incl. hop-leg model ids", () => {
  equal(sessionFamily("deepseek-v4-flash"), "deepseek-v4-flash");
  equal(sessionFamily("deepseek-v4-pro"), "deepseek-v4-pro");
  equal(sessionFamily("qwen-tp/deepseek-v4-flash-0731"), "deepseek-v4-flash", "qwen-tp rename maps onto the flash family");
  equal(sessionFamily("openrouter/deepseek/deepseek-v4-flash"), "deepseek-v4-flash", "openrouter slug maps onto the flash family");
  equal(sessionFamily("qwen3.8-max"), undefined);
});

section("modelParts — Model-object adapter (round-2 P0)");

test("modelParts: Model OBJECT provider/id win (openrouter slug id never split)", () => {
  deepEqual(modelParts(modelObj("openrouter", "deepseek/deepseek-v4-flash")), {
    provider: "openrouter",
    model: "deepseek/deepseek-v4-flash",
  });
  deepEqual(modelParts(modelObj("deepseek", "deepseek-v4-flash")), { provider: "deepseek", model: "deepseek-v4-flash" });
});

test("modelParts: string fallback (defensive) still applies #154 rules", () => {
  deepEqual(modelParts("deepseek-v4-flash"), { provider: "deepseek", model: "deepseek-v4-flash" });
  deepEqual(modelParts("qwen-tp/deepseek-v4-flash-0731"), { provider: "qwen-tp", model: "deepseek-v4-flash-0731" });
  deepEqual(modelParts(undefined), { provider: "deepseek", model: "" });
});

section("classifySessionTurn — message_end text classification");

test("canonical 402 errorMessage → exhaustion 402", () => {
  const c = classifySessionTurn(canonical402);
  equal(c.kind, "exhaustion");
  equal(c.reason, "402");
});

test("credit-balance-too-low → exhaustion low_balance", () => {
  const c = classifySessionTurn(lowBalanceMsg);
  equal(c.kind, "exhaustion");
  equal(c.reason, "low_balance");
});

test("auth-permanent key wording → blocked (never exhaustion)", () => {
  const c = classifySessionTurn(authMsg);
  equal(c.kind, "blocked");
  equal(c.reason, "blocked");
});

test("healthy / quoted-content assistant turns → null (never latch)", () => {
  equal(classifySessionTurn(healthyMsg).kind, null);
  equal(classifySessionTurn(quotedMsg).kind, null, "content quoting 402 with no error → never act");
});

test("user/tool messages quoting 402 → null (only assistant failing turns)", () => {
  equal(classifySessionTurn(toolMsg).kind, null);
  equal(classifySessionTurn(userMsg).kind, null);
  equal(classifySessionTurn(null).kind, null);
  equal(classifySessionTurn(undefined).kind, null);
});

section("buildChildMarker — sB1-contract bytes");

test("child marker fields + charset (self-hop; parent computes the real chain leg)", () => {
  const m = buildChildMarker({ provider: "deepseek", model: "deepseek-v4-flash", reason: "402", nonce: "abc123" });
  equal(m.kind, "provider-exhaustion");
  equal(m.provider, "deepseek");
  equal(m.model, "deepseek-v4-flash");
  equal(m.reason, "402");
  equal(m.hop, "deepseek->deepseek");
  equal(m.nonce, "abc123");
  const all = Object.values(m).join("");
  ok(/^[A-Za-z0-9_.:/\->+=-]+$/.test(all), "sB1 charset: no spaces/quotes/control bytes");
  ok(!all.includes(" "), "no interior spaces in any token");
});

// ── Extension end-to-end (fake pi + hermetic env) ──────────────────────

section("extension — child (print) message_end → shutdown marker emission");

test("child 402: marker pending after message_end, written EXACTLY ONCE at session_shutdown, latch untouched", async () => {
  const { env, cleanup, captured } = hermetic();
  applyEnv(env, { TASK_HEARTBEAT: "1", TASK_HEARTBEAT_NONCE: "child-nonce-1" });
  try {
    const pi = makeFakePi();
    extension(pi as any);
    await pi.emit("message_end", { message: canonical402 }, ctx("print", modelObj("deepseek", "deepseek-v4-flash")));
    ok(_pendingMarkerForTests(), "marker latched in-session");
    const once = _pendingMarkerForTests();
    await pi.emit("message_end", { message: canonical402 }, ctx("print", modelObj("deepseek", "deepseek-v4-flash")));
    equal(_pendingMarkerForTests(), once, "once-per-process — repeated failing turns do not duplicate");
    await pi.emit("session_shutdown", { reason: "quit" }, ctx("print", modelObj("deepseek", "deepseek-v4-flash")));
    equal(captured.length, 1, "marker written exactly once");
    ok(captured[0].startsWith("[provider-exhaustion] "), "prefix present");
    ok(captured[0].includes("reason=402"), "reason=402");
    ok(captured[0].includes("nonce=child-nonce-1"), "authentic nonce");
    ok(captured[0].endsWith("\n"), "\\n-terminated (sB1)");
    for (const tok of captured[0].trim().split(/\s+/)) {
      ok(/^[A-Za-z0-9_\[\].:/\->+=-]+$/.test(tok), `sB1 per-token charset: ${tok}`);
    }
    equal(pi.setModelCalls.length, 0, "children never setModel (CLI --model authoritative)");
    // CHILD NEVER WRITES THE LATCH — the parent decision loop is the writer.
    const state = readLatchState(env);
    deepEqual(state.primaries, {}, "child capture must not write the durable latch");
    equal(_pendingMarkerForTests(), null, "marker cleared after emission");
  } finally {
    restoreEnv();
    cleanup();
  }
});

test("child without a nonce never emits (no authenticating reader)", async () => {
  const { env, cleanup, captured } = hermetic();
  applyEnv(env, { TASK_HEARTBEAT: "1" });
  try {
    const pi = makeFakePi();
    extension(pi as any);
    await pi.emit("message_end", { message: canonical402 }, ctx("print", modelObj("deepseek", "deepseek-v4-flash")));
    await pi.emit("session_shutdown", { reason: "quit" }, ctx("print", modelObj("deepseek", "deepseek-v4-flash")));
    equal(captured.length, 0, "no nonce → no marker");
    equal(_pendingMarkerForTests(), null);
  } finally {
    restoreEnv();
    cleanup();
  }
});

test("child auth-permanent → blocked marker (excluded-with-alert semantics)", async () => {
  const { env, cleanup, captured } = hermetic();
  applyEnv(env, { TASK_HEARTBEAT: "1", TASK_HEARTBEAT_NONCE: "n2" });
  try {
    const pi = makeFakePi();
    extension(pi as any);
    await pi.emit("message_end", { message: authMsg }, ctx("print", modelObj("deepseek", "deepseek-v4-flash")));
    await pi.emit("session_shutdown", { reason: "quit" }, ctx("print", modelObj("deepseek", "deepseek-v4-flash")));
    equal(captured.length, 1);
    ok(captured[0].includes("reason=blocked"), "blocked marker");
  } finally {
    restoreEnv();
    cleanup();
  }
});

test("child healthy / quoted / user-tool turns → NO marker, NO pending state", async () => {
  const { env, cleanup, captured } = hermetic();
  applyEnv(env, { TASK_HEARTBEAT: "1", TASK_HEARTBEAT_NONCE: "n3" });
  try {
    const pi = makeFakePi();
    extension(pi as any);
    await pi.emit("message_end", { message: healthyMsg }, ctx("print", modelObj("deepseek", "deepseek-v4-flash")));
    await pi.emit("message_end", { message: quotedMsg }, ctx("print", modelObj("deepseek", "deepseek-v4-flash")));
    await pi.emit("message_end", { message: toolMsg }, ctx("print", modelObj("deepseek", "deepseek-v4-flash")));
    await pi.emit("session_shutdown", { reason: "quit" }, ctx("print", modelObj("deepseek", "deepseek-v4-flash")));
    equal(captured.length, 0, "falsification: healthy/quoted/user-tool never emit");
  } finally {
    restoreEnv();
    cleanup();
  }
});

section("extension — interactive (tui) message_end → durable latch + hop");

test("interactive 402: durable latch + notice + setModel hop onto the chain leg", async () => {
  const { env, cleanup } = hermetic();
  applyEnv(env);
  try {
    const pi = makeFakePi();
    extension(pi as any);
    await pi.emit("message_end", { message: canonical402 }, ctx("tui", modelObj("deepseek", "deepseek-v4-flash")));
    const state = readLatchState(env);
    const rec = state.primaries.deepseek;
    ok(rec, "root latched");
    equal(rec.status, "exhausted");
    equal(rec.reason, "402");
    equal(rec.source, "interactive");
    equal(rec.notice?.title, "Provider credit exhausted", "notice stored on the latch record");
    // qwen-tp blocked by default → hop = openrouter slug
    deepEqual(rec.families["deepseek-v4-flash"].activeLeg, { provider: "openrouter", model: "deepseek/deepseek-v4-flash" });
    equal(pi.setModelCalls.length, 1, "setModel called once");
    equal(pi.setModelCalls[0].provider, "openrouter");
    equal(pi.setModelCalls[0].id, "deepseek/deepseek-v4-flash", "next turn hops onto the openrouter leg (Model object)");
  } finally {
    restoreEnv();
    cleanup();
  }
});

test("interactive low-balance latches with reason low_balance", async () => {
  const { env, cleanup } = hermetic();
  applyEnv(env);
  try {
    const pi = makeFakePi();
    extension(pi as any);
    await pi.emit("message_end", { message: lowBalanceMsg }, ctx("tui", modelObj("deepseek", "deepseek-v4-flash")));
    const state = readLatchState(env);
    equal(state.primaries.deepseek.reason, "low_balance");
  } finally {
    restoreEnv();
    cleanup();
  }
});

test("interactive auth-permanent → blockedLegs record, NOT an exhaustion latch", async () => {
  const { env, cleanup } = hermetic();
  applyEnv(env);
  try {
    const pi = makeFakePi();
    extension(pi as any);
    await pi.emit("message_end", { message: authMsg }, ctx("tui", modelObj("deepseek", "deepseek-v4-flash")));
    const state = readLatchState(env);
    ok(state.blockedLegs.deepseek, "top-level auth block");
    equal(Object.keys(state.primaries).length, 0, "never an exhaustion record");
    equal(pi.setModelCalls.length, 0, "no hop for an auth block");
  } finally {
    restoreEnv();
    cleanup();
  }
});

test("interactive healthy turn → nothing latched, no hop", async () => {
  const { env, cleanup } = hermetic();
  applyEnv(env);
  try {
    const pi = makeFakePi();
    extension(pi as any);
    await pi.emit("message_end", { message: healthyMsg }, ctx("tui", modelObj("deepseek", "deepseek-v4-flash")));
    equal(pi.setModelCalls.length, 0);
    const state = readLatchState(env);
    deepEqual(state.primaries, {});
  } finally {
    restoreEnv();
    cleanup();
  }
});

test("HOP-OWN drain under a healthy root: own record + DIRECT return to the primary (no dead intermediate hop, round-3 P2-1)", async () => {
  const { env, cleanup } = hermetic();
  applyEnv(env);
  try {
    // Session explicitly on the openrouter hop leg; deepseek root NEVER
    // latched (healthy). openrouter's OWN credits drain (independent account).
    const pi = makeFakePi();
    extension(pi as any);
    await pi.emit("message_end", { message: canonical402 }, ctx("tui", modelObj("openrouter", "deepseek/deepseek-v4-flash")));
    const state = readLatchState(env);
    ok(state.primaries.openrouter !== undefined, "drain recorded under the DRAINED hop provider's own entry");
    ok(state.primaries.deepseek === undefined, "healthy root NOT latched on another account's evidence");
    equal(pi.setModelCalls.length, 1, "one model switch");
    equal(pi.setModelCalls[0].provider, "deepseek", "switch goes DIRECTLY to the family primary");
    equal(pi.setModelCalls[0].id, "deepseek-v4-flash");
    // No dead intermediate hop to a deeper leg, and the next turn_start must
    // NOT fire a restore (already on the primary — interactiveRestoreTarget
    // returns null when the session is already on the root leg).
    const n = pi.setModelCalls.length;
    await pi.emit("turn_start", { turnIndex: 1 }, ctx("tui", modelObj("deepseek", "deepseek-v4-flash")));
    equal(pi.setModelCalls.length, n, "already on the primary → no further restore");
  } finally {
    restoreEnv();
    cleanup();
  }
});

test("banner accuracy (round-4 P2-1): hop-own drain says 'drained its own credits' — never poller wording", async () => {
  const { env, cleanup, banners } = hermetic();
  applyEnv(env);
  try {
    const pi = makeFakePi();
    extension(pi as any);
    // hop-own drain on openrouter under a healthy (absent) root
    await pi.emit("message_end", { message: canonical402 }, ctx("tui", modelObj("openrouter", "deepseek/deepseek-v4-flash")));
    const drainBanner = banners.find((b) => b.title.startsWith("Hop provider drained"));
    ok(drainBanner, "hop-own drain banner fired");
    ok(drainBanner!.title.includes("Hop provider drained"), "title names the hop-own cause");
    ok(drainBanner!.body.includes("drained its own credits"), "body explains the independent-account drain");
    ok(drainBanner!.body.includes("deepseek/deepseek-v4-flash") || drainBanner!.body.includes("deepseek-v4-flash"), "body names the returning-to primary");
    ok(!banners.some((b) => b.title.includes("balance poller restores")), "never claims the poller is the restore path for a hop-own drain");
  } finally {
    restoreEnv();
    cleanup();
  }
});

test("banner accuracy (round-4 P2-1): genuine root drain + poller clear restores with 'Provider balance restored' (lastDrain reset)", async () => {
  const { env, cleanup, banners } = hermetic();
  applyEnv(env);
  try {
    const pi = makeFakePi();
    extension(pi as any);
    // hop-own drain first (session on openrouter, healthy root) → lastDrain hop-own
    await pi.emit("message_end", { message: canonical402 }, ctx("tui", modelObj("openrouter", "deepseek/deepseek-v4-flash")));
    const afterHopOwn = banners.length;
    // genuine ROOT drain: session (now restored to the primary) exhausts on deepseek
    // → lastDrain must RESET to kind:root
    await pi.emit("message_end", { message: canonical402 }, ctx("tui", modelObj("deepseek", "deepseek-v4-flash")));
    // chain hop happened (root drained → openrouter); the poller then clears the root
    clearExhaustion("deepseek", { env });
    // next turn on the openrouter hop leg → restore fires with the ROOT wording
    await pi.emit("turn_start", { turnIndex: 1 }, ctx("tui", modelObj("openrouter", "deepseek/deepseek-v4-flash")));
    const restore = banners.find((b) => b.title.includes("Provider balance restored") || b.title.includes("Returning to the primary"));
    ok(restore, "restore banner fired after the root-clear");
    ok(restore!.title.includes("Provider balance restored"), `genuine root-clear restore says 'Provider balance restored' (got: ${restore!.title})`);
    ok(!restore!.body.includes("drained its own credits"), "hop-own wording NOT reused for a genuine root restore");
  } finally {
    restoreEnv();
    cleanup();
  }
});

test("interactive 402 with registry MISS on the hop target → latch durable, NO fabricated setModel, no-hop notice (deep-review P2)", async () => {
  const { env, cleanup } = hermetic();
  applyEnv(env);
  try {
    // registry that resolves deepseek but NOT the openrouter hop target
    const partialReg = {
      find: (provider: string, modelId: string) =>
        provider === "deepseek" ? REG.find(provider, modelId) : undefined,
    };
    const pi = makeFakePi();
    extension(pi as any);
    const ctxMiss = { mode: "tui", model: modelObj("deepseek", "deepseek-v4-flash"), modelRegistry: partialReg };
    await pi.emit("message_end", { message: canonical402 }, ctxMiss);
    // latch IS durable (marker-less interactive path never depended on setModel)
    const rec = readLatchState(env).primaries.deepseek;
    ok(rec && rec.status === "exhausted", "root latched despite the registry miss");
    // no fabricated {id, provider} object was pushed to pi.setModel — a bare
    // object for an unconfigured provider would break the very next request
    equal(pi.setModelCalls.length, 0, "registry miss → no setModel call (never fabricate)");
  } finally {
    restoreEnv();
    cleanup();
  }
});

section("extension — session_start proactive hop + turn_start restore (interactive only)");

test("session_start on a latched family hops BEFORE the first prompt (tui); print children never hop", async () => {
  const { env, cleanup } = hermetic();
  applyEnv(env);
  try {
    setExhausted({
      primaryProvider: "deepseek",
      reason: "402",
      source: "poller",
      family: "deepseek-v4-flash",
      fromLeg: { provider: "deepseek", model: "deepseek-v4-flash" },
      env,
    });
    const pi = makeFakePi();
    extension(pi as any);
    await pi.emit("session_start", { reason: "startup" }, ctx("tui", modelObj("deepseek", "deepseek-v4-flash")));
    equal(pi.setModelCalls.length, 1, "tui hops at session start");
    equal(pi.setModelCalls[0].provider, "openrouter");
    equal(pi.setModelCalls[0].id, "deepseek/deepseek-v4-flash");
    const pi2 = makeFakePi();
    await pi2.emit("session_start", { reason: "startup" }, ctx("print", modelObj("deepseek", "deepseek-v4-flash")));
    equal(pi2.setModelCalls.length, 0, "print children never hop (CLI authoritative — sC3)");
  } finally {
    restoreEnv();
    cleanup();
  }
});

test("turn_start restores to the primary only after the poller cleared a latch SEEN this session", async () => {
  const { env, cleanup } = hermetic();
  applyEnv(env);
  try {
    const pi = makeFakePi();
    extension(pi as any);
    // Session latches the family (interactive 402) → the drain is recorded and
    // the session is now failover-managed (latch seen).
    await pi.emit("message_end", { message: canonical402 }, ctx("tui", modelObj("deepseek", "deepseek-v4-flash")));
    ok(pi.setModelCalls.length >= 1, "interactive 402 hopped onto the chain leg");
    // poller clears the root latch (verified positive balance)
    clearExhaustion("deepseek", { env });
    // next turn_start on the HOP leg, root record now absent → back to primary
    await pi.emit("turn_start", { turnIndex: 2 }, ctx("tui", modelObj("openrouter", "deepseek/deepseek-v4-flash")));
    const last = pi.setModelCalls[pi.setModelCalls.length - 1];
    ok(last && last.provider === "deepseek" && last.id === "deepseek-v4-flash", "cleared root (latch seen this session) → back to primary");

    // Root record still present (fresh latch) → stay on the hop leg
    setExhausted({
      primaryProvider: "deepseek",
      reason: "402",
      source: "marker",
      family: "deepseek-v4-flash",
      fromLeg: { provider: "deepseek", model: "deepseek-v4-flash" },
      env,
    });
    const pi2 = makeFakePi();
    await pi2.emit("message_end", { message: canonical402 }, ctx("tui", modelObj("openrouter", "deepseek/deepseek-v4-flash")));
    const n2 = pi2.setModelCalls.length;
    await pi2.emit("turn_start", { turnIndex: 3 }, ctx("tui", modelObj("openrouter", "deepseek/deepseek-v4-flash")));
    equal(pi2.setModelCalls.length, n2, "still-latched root → no restore");
    // Already on the primary → no restore
    await pi2.emit("turn_start", { turnIndex: 4 }, ctx("tui", modelObj("deepseek", "deepseek-v4-flash")));
    equal(pi2.setModelCalls.length, n2, "already on primary → no restore");
    // print children never restore
    await pi2.emit("turn_start", { turnIndex: 5 }, ctx("print", modelObj("openrouter", "deepseek/deepseek-v4-flash")));
    equal(pi2.setModelCalls.length, n2, "print children never restore");
  } finally {
    restoreEnv();
    cleanup();
  }
});

test("EXPLICIT hop-leg session (root NEVER latched) is never yanked back by turn_start", async () => {
  const { env, cleanup } = hermetic();
  applyEnv(env);
  try {
    // User starts the session explicitly on the openrouter hop leg (e.g.
    // `pi --provider openrouter --model deepseek/deepseek-v4-pro`) with a
    // HEALTHY root — no latch has EVER existed for this family.
    const pi = makeFakePi();
    extension(pi as any);
    await pi.emit("session_start", { reason: "startup" }, ctx("tui", modelObj("openrouter", "deepseek/deepseek-v4-flash")));
    equal(pi.setModelCalls.length, 0, "healthy root → no hop at session start");
    // turn_start fires every turn; the root record is absent (never latched —
    // not poller-cleared). The session must NOT be yanked to the primary with
    // a misleading "Provider balance restored" banner (deep-review P2).
    await pi.emit("turn_start", { turnIndex: 1 }, ctx("tui", modelObj("openrouter", "deepseek/deepseek-v4-flash")));
    await pi.emit("turn_start", { turnIndex: 2 }, ctx("tui", modelObj("openrouter", "deepseek/deepseek-v4-flash")));
    equal(pi.setModelCalls.length, 0, "never-latched explicit hop leg → session stays put");
  } finally {
    restoreEnv();
    cleanup();
  }
});

section("extension — kill switch + pure hop targets");

test("PROVIDER_FAILOVER_DISABLE=1 → factory registers NO handlers", () => {
  process.env.PROVIDER_FAILOVER_DISABLE = "1";
  try {
    const pi = makeFakePi();
    extension(pi as any);
    equal(pi.handlers.size, 0, "kill switch: extension inert");
  } finally {
    restoreEnv();
  }
});

test("interactiveHopTarget: latched root → first available leg; clear/terminal/non-family → null", () => {
  const { env, cleanup } = hermetic();
  applyEnv(env);
  try {
    equal(interactiveHopTarget({ provider: "deepseek", model: "deepseek-v4-flash" }, readLatchState(env), env), null, "clear state → no hop");
    equal(interactiveHopTarget({ provider: "qwen", model: "qwen3.8-max" }, readLatchState(env), env), null, "non-family → no hop");
    setExhausted({
      primaryProvider: "deepseek",
      reason: "402",
      source: "interactive",
      family: "deepseek-v4-flash",
      fromLeg: { provider: "deepseek", model: "deepseek-v4-flash" },
      env,
    });
    deepEqual(interactiveHopTarget({ provider: "deepseek", model: "deepseek-v4-flash" }, readLatchState(env), env), {
      provider: "openrouter",
      model: "deepseek/deepseek-v4-flash",
    });
    // same-leg: the session is ALREADY on the active (hop) leg → null
    equal(
      interactiveHopTarget({ provider: "openrouter", model: "deepseek/deepseek-v4-flash" }, readLatchState(env), env),
      null,
      "already on the active leg → no re-hop",
    );
    // TERMINAL state: latch from the terminal openrouter leg → halted → null
    setExhausted({
      primaryProvider: "deepseek",
      reason: "402",
      source: "interactive",
      family: "deepseek-v4-flash",
      fromLeg: { provider: "openrouter", model: "deepseek/deepseek-v4-flash" },
      env,
    });
    const term = readLatchState(env);
    ok(term.primaries.deepseek.families["deepseek-v4-flash"].terminal === true, "terminal flag set");
    equal(interactiveHopTarget({ provider: "deepseek", model: "deepseek-v4-flash" }, term, env), null, "terminal chain → no hop target");
  } finally {
    restoreEnv();
    cleanup();
  }
});

test("interactiveRestoreTarget: hop leg + absent root → root leg; root present / non-family / already-root → null", () => {
  const { env, cleanup } = hermetic();
  applyEnv(env);
  try {
    // hop leg, no root record (poller cleared) → back to the primary root leg
    deepEqual(interactiveRestoreTarget({ provider: "openrouter", model: "deepseek/deepseek-v4-flash" }, readLatchState(env), env), {
      provider: "deepseek",
      model: "deepseek-v4-flash",
    });
    // non-family → null
    equal(interactiveRestoreTarget({ provider: "qwen", model: "qwen3.8-max" }, readLatchState(env), env), null);
    // already on the primary → null
    equal(interactiveRestoreTarget({ provider: "deepseek", model: "deepseek-v4-flash" }, readLatchState(env), env), null);
    // root record PRESENT (fresh latch) → stay on the hop leg
    setExhausted({
      primaryProvider: "deepseek",
      reason: "402",
      source: "marker",
      family: "deepseek-v4-flash",
      fromLeg: { provider: "deepseek", model: "deepseek-v4-flash" },
      env,
    });
    equal(interactiveRestoreTarget({ provider: "openrouter", model: "deepseek/deepseek-v4-flash" }, readLatchState(env), env), null);
  } finally {
    restoreEnv();
    cleanup();
  }
});

test("audit-only billing text (no 402, no credit wording) → kind null, never acts (P2-2)", () => {
  const audit = { role: "assistant", stopReason: "error", errorMessage: "Monthly usage limit reached for the billing account" };
  equal(classifySessionTurn(audit).kind, null, "audit-only fuzzy billing → null at the turn layer");
  const audit2 = { role: "assistant", stopReason: "error", errorMessage: "billing quota exceeded for this workspace" };
  equal(classifySessionTurn(audit2).kind, null);
});

(async () => {
  for (const { name, fn } of allTests) {
    try {
      await fn();
      passed++;
      console.log(`  ✅ ${name}`);
    } catch (err: any) {
      failed++;
      console.log(`  ❌ ${name}: ${err.message}`);
    }
  }
  console.log(`\n=== Results: ${passed} passed, ${failed} failed ===`);
  if (failed > 0) {
    console.log("❌ SOME TESTS FAILED");
    process.exit(1);
  }
  console.log("✅ ALL TESTS PASSED");
})();
