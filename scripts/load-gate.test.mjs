/**
 * load-gate.test.mjs — unit tests for scripts/load-gate.mjs (#209)
 *
 * Covers: per-core config defaults + env overrides, ordering clamp,
 * shouldSuspend/shouldResume boundary equality, CLI exit-code contract
 * (0 go / 2 usage / 3 deferred), CLI-level hysteresis wiring (F2 — plain
 * `check` gates on shouldSuspend, `check --deferred` gates on shouldResume),
 * deterministic defer via LOAD_SUSPEND_THRESHOLD=0, LOAD_GATE_FORCE=1/--force
 * bypass, --json shape.
 *
 * Run: node scripts/load-gate.test.mjs
 *
 * Real load is NEVER read — the load getter is injected through `run()`'s
 * deps (the injectable seam; no global state).
 */

import { strict as assert } from "node:assert";
import os from "node:os";
import { run, configFromEnv, shouldSuspend, shouldResume, check } from "./load-gate.mjs";

let passed = 0;
let failed = 0;

function test(name, fn) {
  try {
    fn();
    passed++;
    console.log(`  ✅ ${name}`);
  } catch (err) {
    failed++;
    console.log(`  ❌ ${name}: ${err.message}`);
  }
}

function section(name) {
  console.log(`\n${name}:`);
}

const silentLog = () => {};
const argv = (...a) => ["node", "load-gate.mjs", ...a];
// Explicit 10-core operating point (suspend 25 / resume 15) — NOT
// core-count dependent.
const env10 = { LOAD_SUSPEND_THRESHOLD: "25", LOAD_RESUME_THRESHOLD: "15" };

section("configFromEnv — per-core defaults, env overrides, ordering clamp");

test("per-core defaults — 2.5× / 1.5× cores", () => {
  const dSuspend = Math.round(2.5 * os.cpus().length);
  const dResume = Math.round(1.5 * os.cpus().length);
  const cfg = configFromEnv({});
  assert.equal(cfg.suspend, dSuspend);
  assert.equal(cfg.resume, dResume);
});

test("env overrides; garbage/negative → default; 0 valid", () => {
  const dSuspend = Math.round(2.5 * os.cpus().length);
  const dResume = Math.round(1.5 * os.cpus().length);
  assert.equal(configFromEnv({ LOAD_SUSPEND_THRESHOLD: "30" }).suspend, 30);
  assert.equal(configFromEnv({ LOAD_RESUME_THRESHOLD: "10" }).resume, 10);
  assert.equal(configFromEnv({ LOAD_SUSPEND_THRESHOLD: "0" }).suspend, 0, "0 valid — deterministic-defer hook");
  assert.equal(configFromEnv({ LOAD_RESUME_THRESHOLD: "0" }).resume, 0, "0 valid");
  assert.equal(configFromEnv({ LOAD_SUSPEND_THRESHOLD: "abc" }).suspend, dSuspend, "garbage → default");
  assert.equal(configFromEnv({ LOAD_SUSPEND_THRESHOLD: "-5" }).suspend, dSuspend, "negative → default");
  assert.equal(configFromEnv({ LOAD_RESUME_THRESHOLD: "abc" }).resume, dResume, "garbage → default");
  assert.equal(configFromEnv({ LOAD_RESUME_THRESHOLD: "" }).resume, dResume, "empty → default");
});

test("ordering clamp — resume > suspend → resume clamped to suspend (safe direction)", () => {
  const cfg = configFromEnv({ LOAD_RESUME_THRESHOLD: "999" });
  assert.equal(cfg.resume, cfg.suspend, "resume clamps DOWN to suspend");
  // deterministic-defer hook preserved: suspend=0 → resume clamps to 0
  const zero = configFromEnv({ LOAD_SUSPEND_THRESHOLD: "0" });
  assert.equal(zero.suspend, 0);
  assert.equal(zero.resume, 0);
});

section("pure verdict functions — boundary equality");

test("shouldSuspend — load1 ≥ suspend suspends; boundary equality", () => {
  const cfg = { suspend: 25, resume: 15 };
  assert.equal(shouldSuspend(25, cfg), true, "load1 = suspend → suspend");
  assert.equal(shouldSuspend(24.9, cfg), false);
  assert.equal(shouldSuspend(60, cfg), true);
});

test("shouldResume — load1 < resume resumes; boundary equality", () => {
  const cfg = { suspend: 25, resume: 15 };
  assert.equal(shouldResume(15 - 0.001, cfg), true, "load1 = resume − ε → resume");
  assert.equal(shouldResume(15, cfg), false, "load1 = resume → still deferred (strictly below)");
  assert.equal(shouldResume(5, cfg), true);
});

test("check — plain verdict = shouldSuspend", () => {
  const cfg = { suspend: 25, resume: 15 };
  assert.equal(check(20, cfg), "go");
  assert.equal(check(25, cfg), "suspend");
  assert.equal(check(60, cfg), "suspend");
});

section("CLI — exit codes 0/2/3, hysteresis at the CLI, force bypass");

test("injected load 60 ≥ suspend 25 → exit 3 (deferred)", () => {
  assert.equal(run(argv("check"), { env: env10, getLoad1: () => 60, log: silentLog }), 3);
});

test("injected load 5 < suspend → exit 0 (go)", () => {
  assert.equal(run(argv("check"), { env: env10, getLoad1: () => 5, log: silentLog }), 0);
});

test("hysteresis wired at the CLI (F2) — check --deferred resumes only below resume", () => {
  // 20 and 16 are BELOW suspend=25 but still ≥ resume=15 → still deferred:
  // a single-sample dip between suspend and resume never thrash-resumes.
  for (const load of [25, 20, 16]) {
    const code = run(argv("check", "--deferred"), { env: env10, getLoad1: () => load, log: silentLog });
    assert.equal(code, 3, `load ${load}: still deferred (below suspend but ≥ resume)`);
  }
  assert.equal(run(argv("check", "--deferred"), { env: env10, getLoad1: () => 14, log: silentLog }), 0, "load 14 < resume → go");
  // contrast case: plain check at 20 → exit 0 (go while load < suspend) —
  // proves the CLI dispatches shouldSuspend vs shouldResume by mode
  assert.equal(run(argv("check"), { env: env10, getLoad1: () => 20, log: silentLog }), 0, "plain check at 20 → go (load < suspend)");
});

test("--deferred accepted and changes the verdict rule as specified", () => {
  // plain check defers at ≥ suspend; --deferred stays deferred until < resume
  assert.equal(run(argv("check"), { env: env10, getLoad1: () => 20, log: silentLog }), 0);
  assert.equal(run(argv("check", "--deferred"), { env: env10, getLoad1: () => 20, log: silentLog }), 3);
});

test("LOAD_SUSPEND_THRESHOLD=0 → always exit 3 (deterministic defer)", () => {
  const env = { LOAD_SUSPEND_THRESHOLD: "0" };
  assert.equal(run(argv("check"), { env, getLoad1: () => 0.5, log: silentLog }), 3);
  assert.equal(run(argv("check", "--deferred"), { env, getLoad1: () => 0.5, log: silentLog }), 3, "deferred mode also defers (resume clamps to 0)");
});

test("LOAD_GATE_FORCE=1 and --force → exit 0 unconditionally", () => {
  assert.equal(run(argv("check"), { env: { ...env10, LOAD_GATE_FORCE: "1" }, getLoad1: () => 60, log: silentLog }), 0, "env bypass");
  assert.equal(run(argv("check", "--force"), { env: env10, getLoad1: () => 60, log: silentLog }), 0, "--force sets the same bypass");
});

test("unknown flag / unknown subcommand → exit 2 (usage error)", () => {
  assert.equal(run(argv("check", "--bogus"), { env: env10, getLoad1: () => 5, log: silentLog }), 2);
  assert.equal(run(argv("bogus"), { env: env10, getLoad1: () => 5, log: silentLog }), 2);
});

section("--json output shape");

test("--json prints {load1, suspend, resume, verdict, thresholds} on stdout; exit 0 on go", () => {
  const out = [];
  const origLog = console.log;
  console.log = (s) => out.push(s);
  try {
    const code = run(argv("check", "--json"), { env: env10, getLoad1: () => 20, log: silentLog });
    assert.equal(code, 0);
    const parsed = JSON.parse(out.join(""));
    assert.equal(parsed.load1, 20);
    assert.equal(parsed.suspend, 25);
    assert.equal(parsed.resume, 15);
    assert.equal(parsed.verdict, "go");
    assert.deepEqual(parsed.thresholds, { suspend: 25, resume: 15 });
  } finally {
    console.log = origLog;
  }
});

test("--json deferred verdict + exit 3", () => {
  const out = [];
  const origLog = console.log;
  console.log = (s) => out.push(s);
  try {
    const code = run(argv("check", "--json"), { env: env10, getLoad1: () => 60, log: silentLog });
    assert.equal(code, 3);
    const parsed = JSON.parse(out.join(""));
    assert.equal(parsed.verdict, "deferred");
    assert.equal(parsed.load1, 60);
  } finally {
    console.log = origLog;
  }
});

console.log(`\nload-gate.test.mjs: ${passed} passed, ${failed} failed`);
if (failed > 0) {
  console.error("❌ SOME TESTS FAILED");
  process.exit(1);
}
console.log("✅ ALL TESTS PASSED");
