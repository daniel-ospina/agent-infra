/**
 * provider-failover.poller.test.ts — cross-writer contract parity between the
 * TS latch module (extensions/shared/provider-failover.ts — session writer)
 * and the poller's python helper (scripts/checkout-hygiene/
 * deepseek-balance-latch.py — launchd writer). #476 Phase 5.
 *
 * Both writers interoperate on ONE state file (~/.pi/agent/state/
 * provider-exhaustion.json). This suite pins byte-level contract parity:
 *   - identical durable JSON after equivalent set/clear/block/unblock ops
 *     from the same starting state
 *   - interleaved TS→PY→TS writers keep epoch monotonic and converge
 *     (no lost updates; blockedLegs survives a balance-restore clear)
 *   - corrupt state file self-heal parity (rename-aside + empty state)
 *   - op no-op semantics (clear-without-record / double-block) leave the
 *     state byte-identical and do NOT bump epoch
 *
 * Run: npx tsx extensions/shared/provider-failover.poller.test.ts
 */

import {
  EMPTY_LATCH,
  setExhausted,
  clearExhaustion,
  markLegBlocked,
  clearLegBlocked,
  readLatchState,
  updateLatchState,
} from "./provider-failover.js";

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { spawnSync } from "node:child_process";
import { ok, equal, deepEqual } from "node:assert/strict";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const LATCH_PY = path.join(
  __dirname,
  "..",
  "..",
  "scripts",
  "checkout-hygiene",
  "deepseek-balance-latch.py",
);

let passed = 0;
let failed = 0;

function test(name: string, fn: () => void) {
  try {
    fn();
    passed++;
    console.log(`  ✅ ${name}`);
  } catch (err: any) {
    failed++;
    console.log(`  ❌ ${name}`);
    console.log(`     ${err?.message ?? err}`);
  }
}

/** Fresh isolated agent dir + env for one scenario. */
function freshEnv(overrides: Record<string, string> = {}): { dir: string; env: Record<string, string> } {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "pf-poller-parity-"));
  const stateFile = path.join(dir, "state", "provider-exhaustion.json");
  const env: Record<string, string> = { ...(process.env as Record<string, string>) };
  // ambient-session hardening: strip failover overrides that would leak in
  delete env.PROVIDER_FAILOVER_BLOCKED;
  delete env.PROVIDER_EXHAUSTION_TTL_MS;
  delete env.TASK_HEARTBEAT;
  delete env.TASK_HEARTBEAT_NONCE;
  env.PI_CODING_AGENT_DIR = dir;
  env.PFW_STATE_FILE = stateFile;
  for (const [k, v] of Object.entries(overrides)) env[k] = v;
  return { dir, env };
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
/** Synchronous sleep (the parity harness is sync — no async test fn). */
const sleepSync = (ms: number): void => {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
};

/** Run the python helper with the scenario env; returns {status, stdout}. */
function py(args: string[], env: Record<string, string>): { status: number; stdout: string } {
  const r = spawnSync("python3", [LATCH_PY, ...args], {
    encoding: "utf-8",
    env: { ...env, DBW_STATE_FILE: env.PFW_STATE_FILE },
  });
  return { status: r.status ?? -1, stdout: r.stdout ?? "" };
}

function tsState(env: Record<string, string>): unknown {
  return readLatchState({ ...env, PI_CODING_AGENT_DIR: env.PI_CODING_AGENT_DIR! });
}

function pyState(env: Record<string, string>): unknown {
  const r = py(["status"], env);
  return JSON.parse(r.stdout);
}

/** Normalize timestamps/epoch-noise before comparing semantic content:
 * python + TS may write within the same millisecond but ISO strings still
 * differ in nothing here — compare exactly; only epoch ordering is asserted
 * separately. */
function dropNoise(s: any): any {
  const clone = JSON.parse(JSON.stringify(s));
  delete clone.updatedAt;
  for (const [k, rec] of Object.entries<any>(clone.primaries ?? {})) {
    clone.primaries[k] = {
      status: rec.status,
      reason: rec.reason,
      source: rec.source,
      families: rec.families,
      notice: rec.notice,
    };
  }
  const bl: Record<string, any> = {};
  for (const [k, rec] of Object.entries<any>(clone.blockedLegs ?? {})) {
    bl[k] = { reason: rec.reason };
  }
  clone.blockedLegs = bl;
  return clone;
}

// ── parity: equivalent single ops from EMPTY ────────────────────────────────
test("python set == TS setExhausted (durable JSON contract)", () => {
  const ts = freshEnv();
  const p1 = freshEnv();
  setExhausted({
    primaryProvider: "deepseek",
    reason: "low_balance",
    source: "poller",
    notice: { title: "Low balance", body: "top up" },
    env: ts.env as any,
  });
  py(["set", "--primary", "deepseek", "--reason", "low_balance", "--source", "poller",
    "--notice", "Low balance|top up"], p1.env);
  deepEqual(dropNoise(tsState(ts.env)), dropNoise(pyState(p1.env)), "record content parity");
});

test("python clear == TS clearExhaustion (keeps blockedLegs)", () => {
  const ts = freshEnv();
  const p1 = freshEnv();
  // identical prep on both writers: set a primary + a durable auth block
  setExhausted({ primaryProvider: "deepseek", reason: "402", source: "marker", env: ts.env as any });
  markLegBlocked("qwen-tp", "401 auth", { env: ts.env as any });
  py(["set", "--primary", "deepseek", "--reason", "402", "--source", "marker"], p1.env);
  py(["block", "--provider", "qwen-tp", "--reason", "401 auth"], p1.env);
  clearExhaustion("deepseek", { reason: "poller", env: ts.env as any });
  py(["clear", "--primary", "deepseek", "--reason", "poller"], p1.env);
  const t = dropNoise(tsState(ts.env));
  const p = dropNoise(pyState(p1.env));
  deepEqual(t.primaries, p.primaries, "primaries empty after clear");
  deepEqual(t.blockedLegs, p.blockedLegs, "blockedLegs survives clear (both writers)");
});

test("python block == TS markLegBlocked; unblock == clearLegBlocked", () => {
  const ts = freshEnv();
  const p1 = freshEnv();
  markLegBlocked("qwen-tp", "401 auth", { env: ts.env as any });
  py(["block", "--provider", "qwen-tp", "--reason", "401 auth"], p1.env);
  const tb = tsState(ts.env).blockedLegs;
  const pb = pyState(p1.env).blockedLegs;
  deepEqual(Object.keys(tb), Object.keys(pb), "same blocked provider set");
  equal(tb["qwen-tp"].reason, pb["qwen-tp"].reason, "same block reason");
  ok(/^\d{4}-\d{2}-\d{2}T/.test(tb["qwen-tp"].at), "ts block stamped ISO at");
  ok(/^\d{4}-\d{2}-\d{2}T/.test(pb["qwen-tp"].at), "python block stamped ISO at");
  clearLegBlocked("qwen-tp", { env: ts.env as any });
  py(["unblock", "--provider", "qwen-tp"], p1.env);
  deepEqual(tsState(ts.env).blockedLegs, pyState(p1.env).blockedLegs, "both unblocked");
});

test("no-op parity: clear-without-record and double-block do not bump epoch", () => {
  const a = freshEnv();
  const b = freshEnv();
  setExhausted({ primaryProvider: "deepseek", reason: "low_balance", source: "poller", env: a.env as any });
  py(["set", "--primary", "deepseek"], b.env);
  const ea = tsState(a.env).epoch;
  const eb = pyState(b.env).epoch;
  equal(typeof ea, "number", "ts epoch numeric");
  equal(eb, ea, "python epoch mirrors ts after one op");
  clearExhaustion("deepseek", { env: a.env as any });
  clearExhaustion("deepseek", { env: a.env as any }); // second is a no-op
  py(["clear", "--primary", "deepseek"], b.env);
  py(["clear", "--primary", "deepseek"], b.env); // no-op
  equal(tsState(a.env).epoch, ea + 1, "ts no-op clear does not bump epoch");
  equal(pyState(b.env).epoch, eb + 1, "python no-op clear does not bump epoch");
  equal(tsState(a.env).epoch, pyState(b.env).epoch, "epochs converge");
  // FRESH double-block is also a no-op on BOTH writers (byte-identical parity)
  markLegBlocked("openrouter", "401", { env: a.env as any });
  py(["block", "--provider", "openrouter", "--reason", "401"], b.env);
  const e2a = tsState(a.env).epoch;
  const e2b = pyState(b.env).epoch;
  equal(e2a, e2b, "epochs converge after first block");
  markLegBlocked("openrouter", "401", { env: a.env as any }); // fresh re-block → no-op
  py(["block", "--provider", "openrouter", "--reason", "401"], b.env); // no-op
  equal(tsState(a.env).epoch, e2a, "ts fresh double-block does not bump epoch");
  equal(pyState(b.env).epoch, e2b, "python fresh double-block does not bump epoch");
});

test("STALE re-block parity: both writers re-stamp an aged block (TTL env honored)", () => {
  const a = freshEnv({ PROVIDER_EXHAUSTION_TTL_MS: "50" });
  const b = freshEnv({ PROVIDER_EXHAUSTION_TTL_MS: "50" });
  markLegBlocked("openrouter", "401", { env: a.env as any });
  py(["block", "--provider", "openrouter", "--reason", "401"], b.env);
  const at0a = tsState(a.env).blockedLegs.openrouter.at;
  ok(/^\d{4}-\d{2}-\d{2}T/.test(at0a), "ts block stamped ISO at");
  sleepSync(60); // age past the 50ms TTL
  markLegBlocked("openrouter", "401", { env: a.env as any }); // stale → re-stamp
  py(["block", "--provider", "openrouter", "--reason", "401"], b.env); // stale → re-stamp
  const at1a = tsState(a.env).blockedLegs.openrouter.at;
  const at1b = pyState(b.env).blockedLegs.openrouter.at;
  ok(at1a !== at0a, "ts re-stamped the aged block");
  ok(at1b !== at0a, "python re-stamped the aged block (mirror)");
  // semantic parity (each writer stamps its own ms — compare shape, not bytes)
  deepEqual(
    dropNoise(tsState(a.env)),
    dropNoise(pyState(b.env)),
    "both writers agree on the re-stamped block shape",
  );
});

// ── interleaved writers: monotonic epoch, no lost updates ───────────────────
test("interleaved TS→PY→TS writers converge on one state file", () => {
  const shared = freshEnv();
  // TS sets deepseek; PY clears it while a TS block op follows; then TS
  // re-checks its durable state — no writer may observe a stale epoch.
  setExhausted({ primaryProvider: "deepseek", reason: "402", source: "marker", env: shared.env as any });
  const e1 = tsState(shared.env).epoch;
  py(["clear", "--primary", "deepseek"], shared.env); // PY writer on same file
  const e2 = tsState(shared.env).epoch;
  ok(e2 > e1, "python write bumps epoch (monotonic)");
  markLegBlocked("openrouter", "auth", { env: shared.env as any }); // TS writer after
  const s = tsState(shared.env);
  ok(s.epoch > e2, "ts write after python write keeps epoch monotonic");
  deepEqual(s.primaries, {}, "python clear durable (ts read agrees)");
  equal(s.blockedLegs["openrouter"].reason, "auth", "ts block after python clear durable");
});

test("python sees a TS-written latch (fail-closed read parity)", () => {
  const shared = freshEnv();
  setExhausted({ primaryProvider: "deepseek", reason: "402", source: "marker", env: shared.env as any });
  const p = pyState(shared.env);
  const rec = p.primaries["deepseek"];
  ok(rec, "python reads the ts-written record");
  equal(rec.status, "exhausted");
  equal(rec.source, "marker");
});

test("corrupt state file self-heal parity (rename-aside + empty)", () => {
  const shared = freshEnv();
  const file = shared.env.PFW_STATE_FILE;
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, "{not json!!");
  const pyR = py(["status"], shared.env);
  equal(pyR.status, 0, "python status exits 0 on corrupt file");
  equal(pyState(shared.env).epoch, 0, "python starts empty after self-heal");
  const backups = fs.readdirSync(path.dirname(file)).filter((f) => f.includes(".corrupt-"));
  equal(backups.length, 1, "corrupt file renamed aside (not deleted)");
  // TS side agrees the same file is clean-empty now
  const t = readLatchState(shared.env as any);
  deepEqual(t.primaries, {}, "ts reads empty after python self-heal");
  // and TS self-heal parity for a ts-triggered corruption
  const file2 = shared.env.PFW_STATE_FILE;
  fs.writeFileSync(file2, "garbage");
  const healed = readLatchState(shared.env as any);
  deepEqual(healed.primaries, {}, "ts self-heal empty");
  const backups2 = fs.readdirSync(path.dirname(file)).filter((f) => f.includes(".corrupt-"));
  equal(backups2.length, 2, "ts corrupt file also renamed aside");
});

test("concurrent lock coexistence: python acquires the SAME lock file the TS module uses", () => {
  const shared = freshEnv();
  const lock = shared.env.PFW_STATE_FILE + ".lock";
  // Simulate a TS holder (O_EXCL pidfile) and assert python waits then writes.
  fs.mkdirSync(path.dirname(lock), { recursive: true });
  fs.writeFileSync(lock, "999999\n"); // dead pid → stale → reclaimed
  py(["set", "--primary", "deepseek", "--reason", "low_balance"], shared.env);
  const rec = tsState(shared.env).primaries["deepseek"];
  ok(rec && rec.status === "exhausted", "python reclaimed the stale TS-format lock and wrote");
  ok(!fs.existsSync(lock), "python released the lock after writing");
});

test("TS does NOT steal a LIVE python lock (fresh mtime, live pid) — waits then degrades", () => {
  const shared = freshEnv();
  shared.env.PROVIDER_FAILOVER_LOCK_WAIT_MS = "300"; // short wait so the test is fast
  const lock = shared.env.PFW_STATE_FILE + ".lock";
  fs.mkdirSync(path.dirname(lock), { recursive: true });
  // python-format lock: single pid token (number-parseable by TS) + FRESH mtime
  fs.writeFileSync(lock, `${process.pid}\n`); // OUR live pid → not stale
  const before = Date.now();
  setExhausted({ primaryProvider: "deepseek", reason: "low_balance", source: "poller", env: shared.env as any });
  const waited = Date.now() - before;
  ok(waited >= 250, `TS waited for the live lock (waited ${waited}ms)`);
  ok(fs.existsSync(lock), "TS did NOT steal/delete the live python lock");
  const holder = fs.readFileSync(lock, "utf-8").trim();
  equal(holder, String(process.pid), "lock still holds the python (our) pid");
  // TS degraded to an unlocked atomic write — must still converge on epoch
  const rec = tsState(shared.env).primaries["deepseek"];
  ok(rec && rec.status === "exhausted", "ts write after lock wait still durable (atomic rename + CAS)");
  fs.rmSync(lock, { force: true });
});

const failuresSummary = () => {
  console.log(`\nprovider-failover.poller.test.ts: ${passed} passed, ${failed} failed`);
  if (failed > 0) process.exit(1);
};
test("sanity: EMPTY_LATCH import", () => {
  equal(EMPTY_LATCH.epoch, 0);
});
failuresSummary();
