/**
 * sequence-enforcer.test.ts — unit tests for the print-mode gate deadlock +
 * stale-pop state loss fix (#201).
 *
 * Covers: resolveMode print-aware default matrix, timeout park-vs-pop,
 * audit context (allowed+hint on blocked, warn_blocked would-block-only),
 * and verifier-gate advancement still working under warn mode.
 *
 * Pattern: exported internals + NODE_ENV=test seams (mirrors
 * repo-freshness.test.ts / review-enforcer/index.test.ts).
 * Run: npx tsx extensions/sequence-enforcer/sequence-enforcer.test.ts
 */
process.env.NODE_ENV = "test";

import {
  resolveMode,
  getExpectedToolsForStep,
  gateGuidance,
  validateToolCall,
  handleSequenceTimeout,
  _setAuditSinkForTest,
  _setBridgeDirForTest,
  _pushSkillForTest,
  _stackForTest,
  _resetStateForTest,
  default as sequenceEnforcer,
  type Step,
} from "./index.js";
import { ok, equal, deepEqual } from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

let passed = 0, failed = 0;
async function test(name: string, fn: () => void | Promise<void>) {
  try { await fn(); passed++; console.log(`  ✅ ${name}`); }
  catch (err: any) { failed++; console.log(`  ❌ ${name}: ${err.message}`); }
}
function section(name: string) { console.log(`\n${name}:`); }

// ── fixtures ─────────────────────────────────────────
const TMP_DIRS: string[] = [];
function tmpDir(name: string): string {
  const d = mkdtempSync(join(tmpdir(), `seq-${name}-`));
  TMP_DIRS.push(d);
  return d;
}

function makeStep(overrides: Partial<Step> = {}): Step {
  return {
    name: "step",
    type: "skill",
    skill: "",
    requires: [],
    produces: [],
    gate: "auto",
    retry: 1,
    timeout_seconds: 0,
    ...overrides,
  };
}

function verifierSkillSteps(): Step[] {
  return [
    makeStep({ name: "scope", gate: "auto" }),
    makeStep({ name: "review", gate: "verifier" }),
    makeStep({ name: "implement", gate: "auto" }),
  ];
}

// captured console.log
let logs: string[] = [];
const origLog = console.log;
function captureStart() { logs = []; console.log = (line: string) => { logs.push(String(line)); }; }
function captureStop() { console.log = origLog; }

// audit sink capture — intercepts auditLog writes (test seam)
let auditEntries: Record<string, unknown>[] = [];
function auditCapture() { auditEntries = []; _setAuditSinkForTest((e) => auditEntries.push(e)); }
function auditRelease() { _setAuditSinkForTest(null); }

// fake timer capture — resetSequenceTimeout schedules a real
// setTimeout(…, 10min) which would hold the process open; stub it and fire
// the captured callback to exercise the timeout path (mirrors
// repo-freshness.test.ts setInterval stubbing).
const origSetTimeout = globalThis.setTimeout;
const origClearTimeout = globalThis.clearTimeout;
let timerCbs: Array<() => void> = [];
function installFakeTimers() {
  timerCbs = [];
  (globalThis as any).setTimeout = (cb: () => void) => { timerCbs.push(cb); return timerCbs.length; };
  (globalThis as any).clearTimeout = () => {};
}
function restoreTimers() {
  (globalThis as any).setTimeout = origSetTimeout;
  (globalThis as any).clearTimeout = origClearTimeout;
}

// env set/restore helper — undefined value deletes the key
async function withEnv(kv: Record<string, string | undefined>, fn: () => void | Promise<void>) {
  const saved: Record<string, string | undefined> = {};
  for (const [k, v] of Object.entries(kv)) {
    saved[k] = process.env[k];
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
  try { await fn(); }
  finally {
    for (const [k, v] of Object.entries(saved)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  }
}

// fake pi harness — last handler per event wins (enforcement handler
// registers after the read handler)
type Handler = (ev?: any, ctx?: any) => Promise<unknown>;
function fakePi(): { pi: any; handlers: Record<string, Handler> } {
  const handlers: Record<string, Handler> = {};
  return { pi: { on: (ev: string, h: Handler) => { handlers[ev] = h; } }, handlers };
}

async function main() {

installFakeTimers();
_setBridgeDirForTest(tmpDir("bridge"));

// ── resolveMode — print-aware default ────────────────
section("resolveMode — print-aware default");

await test("print + no override → warn (the #201 default)", () => {
  equal(resolveMode({ PI_MODE: "print" }, "/nonexistent/mode-file"), "warn");
});

await test("print + AGENT_SEQUENCE_MODE=gate → gate (env wins over print default)", () => {
  equal(resolveMode({ PI_MODE: "print", AGENT_SEQUENCE_MODE: "gate" }, "/nonexistent/mode-file"), "gate");
});

await test("print + ELDATO_SEQUENCE_MODE=strict → strict (dual-support)", () => {
  equal(resolveMode({ PI_MODE: "print", ELDATO_SEQUENCE_MODE: "strict" }, "/nonexistent/mode-file"), "strict");
});

await test("print + PI_ENFORCER_MODE=warn → warn", () => {
  equal(resolveMode({ PI_MODE: "print", PI_ENFORCER_MODE: "warn" }, "/nonexistent/mode-file"), "warn");
});

await test("print + MODE_FILE=strict → strict (file beats print default)", () => {
  const d = tmpDir("modefile");
  writeFileSync(join(d, "mode"), "strict\n");
  equal(resolveMode({ PI_MODE: "print" }, join(d, "mode")), "strict");
});

await test("print + env=gate + MODE_FILE=warn → gate (env beats file)", () => {
  const d = tmpDir("modefile2");
  writeFileSync(join(d, "mode"), "warn\n");
  equal(resolveMode({ PI_MODE: "print", AGENT_SEQUENCE_MODE: "gate" }, join(d, "mode")), "gate");
});

await test("print + invalid env value → falls through to file, then warn default", () => {
  const d = tmpDir("modefile3");
  writeFileSync(join(d, "mode"), "gate\n");
  equal(resolveMode({ PI_MODE: "print", AGENT_SEQUENCE_MODE: "bogus" }, join(d, "mode")), "gate");
  equal(resolveMode({ PI_MODE: "print", AGENT_SEQUENCE_MODE: "bogus" }, "/nonexistent/mode-file"), "warn");
});

await test("interactive + no override → gate (unchanged)", () => {
  equal(resolveMode({}, "/nonexistent/mode-file"), "gate");
});

await test("interactive + env=warn → warn", () => {
  equal(resolveMode({ AGENT_SEQUENCE_MODE: "warn" }, "/nonexistent/mode-file"), "warn");
});

await test("interactive + MODE_FILE=strict → strict (file beats interactive default)", () => {
  const d = tmpDir("modefile4");
  writeFileSync(join(d, "mode"), "strict\n");
  equal(resolveMode({}, join(d, "mode")), "strict");
});

// ── getExpectedToolsForStep + gateGuidance ───────────
section("getExpectedToolsForStep + gateGuidance");

await test("verifier gate → allow [task, subagent, read, loop_enforcer], block everything else", () => {
  const { allow, block } = getExpectedToolsForStep(makeStep({ gate: "verifier" }));
  deepEqual(allow, ["task", "subagent", "read", "loop_enforcer"]);
  ok(block.length === 1 && block[0]!.test("bash"));
});

await test("human_approval gate → read/search/fetch/loop_enforcer only", () => {
  const { allow } = getExpectedToolsForStep(makeStep({ gate: "human_approval" }));
  deepEqual(allow, ["read", "web_search", "web_fetch", "loop_enforcer"]);
});

await test("auto gate → no allow, no block", () => {
  const { allow, block } = getExpectedToolsForStep(makeStep({ gate: "auto" }));
  deepEqual(allow, []);
  deepEqual(block, []);
});

await test("no gate → destructive git/mcp ops blocked", () => {
  const { allow, block } = getExpectedToolsForStep(makeStep({ gate: "" }));
  deepEqual(allow, []);
  ok(block.length === 2);
  ok(block[0]!.test("git push origin main"));
  ok(block[1]!.test("delete table users"));
});

await test("gateGuidance(verifier) → dispatch-a-task hint", () => {
  const g = gateGuidance(makeStep({ gate: "verifier" }));
  ok(g.includes("Allowed tools: task, subagent, read, loop_enforcer"));
  ok(g.includes("dispatch a task sub-agent"));
});

// ── validateToolCall — audit context ─────────────────
section("validateToolCall — audit context");

await test("gate mode + non-allowed tool at verifier → blocked, audit has allowed+hint", () => {
  auditCapture();
  try {
    const step = makeStep({ name: "review", gate: "verifier" });
    const r = validateToolCall("bash", "rm -rf /", step, "gate");
    ok(r.block, "blocked");
    const e = auditEntries.find((x) => x.event === "blocked");
    ok(e, "blocked audit entry written");
    ok(typeof e!.reason === "string" && (e!.reason as string).includes("blocks this operation"), "reason preserved");
    ok(Array.isArray(e!.allowed) && (e!.allowed as string[]).includes("task"), "allowed list present");
    ok(typeof e!.hint === "string" && (e!.hint as string).includes("dispatch a task sub-agent"), "hint present");
    equal(e!.step, "review");
  } finally { auditRelease(); }
});

await test("gate mode + allowed tool at verifier → not blocked, no blocked audit", () => {
  auditCapture();
  try {
    const r = validateToolCall("task", "", makeStep({ gate: "verifier" }), "gate");
    ok(!r.block);
    ok(!auditEntries.some((x) => x.event === "blocked"));
  } finally { auditRelease(); }
});

await test("strict mode + non-allowed tool → blocked (pattern branch; handler writes the audit)", () => {
  auditCapture();
  try {
    const r = validateToolCall("bash", "", makeStep({ gate: "verifier" }), "strict");
    ok(r.block);
    ok((r.reason || "").includes("strict"), "strict reason present");
    // strict pattern-blocks don't audit from validateToolCall itself — the
    // extension handler writes that entry (enriched with allowed+hint).
    ok(!auditEntries.some((x) => x.event === "blocked"));
  } finally { auditRelease(); }
});

await test("warn mode + would-block call → warn_blocked audit (allowed+hint), never blocks", () => {
  auditCapture();
  try {
    const step = makeStep({ name: "review", gate: "verifier" });
    const r = validateToolCall("bash", "git commit -m x", step, "warn");
    ok(!r.block, "warn never blocks");
    const e = auditEntries.find((x) => x.event === "warn_blocked");
    ok(e, "warn_blocked audit written for would-block call");
    deepEqual(e!.allowed, ["task", "subagent", "read", "loop_enforcer"]);
    ok((e!.hint as string).includes("dispatch a task sub-agent"));
    equal(e!.step, "review");
  } finally { auditRelease(); }
});

await test("warn mode + allowed call → no warn_blocked audit", () => {
  auditCapture();
  try {
    const r = validateToolCall("task", "", makeStep({ gate: "verifier" }), "warn");
    ok(!r.block);
    ok(!auditEntries.some((x) => x.event === "warn_blocked"));
  } finally { auditRelease(); }
});

await test("warn mode + destructive call at auto step → no warn_blocked (would not block under gate)", () => {
  auditCapture();
  try {
    const r = validateToolCall("bash", "rm -rf /tmp/x", makeStep({ gate: "auto" }), "warn");
    ok(!r.block);
    ok(!auditEntries.some((x) => x.event === "warn_blocked"));
  } finally { auditRelease(); }
});

// ── sequence timeout — park (print) vs pop (interactive) ──
section("sequence timeout — park (print) vs pop (interactive)");

await test("print mode → parks: stack/step preserved, timeout_park audit, timer re-armed", async () => {
  _resetStateForTest();
  auditCapture();
  try {
    const beforeTimers = timerCbs.length;
    _pushSkillForTest("/repo/skills/demo/SKILL.md", verifierSkillSteps(), 1);
    await withEnv({ PI_MODE: "print", AGENT_SEQUENCE_MODE: "warn" }, () => {
      captureStart();
      try {
        handleSequenceTimeout();
      } finally {
        captureStop();
      }
      const stack = _stackForTest();
      equal(stack.length, 1, "stack untouched");
      equal(stack[0]!.stepIndex, 1, "stepIndex preserved");
      const e = auditEntries.find((x) => x.event === "timeout_park");
      ok(e, "timeout_park audit written");
      equal(e!.skill, "/repo/skills/demo/SKILL.md");
      equal(e!.step, 1);
      equal(e!.mode, "warn");
      ok(logs.some((l) => l.includes("parking")), "parking log line");
      ok(!logs.some((l) => l.includes("popping")), "no pop in print mode");
      ok(timerCbs.length === beforeTimers + 1, "timer re-armed after park");
    });
  } finally { auditRelease(); }
});

await test("interactive mode → pops stale skill, restores parent", async () => {
  _resetStateForTest();
  _pushSkillForTest("/repo/skills/parent/SKILL.md", [makeStep({ name: "a" }), makeStep({ name: "b" })], 0);
  _pushSkillForTest("/repo/skills/child/SKILL.md", verifierSkillSteps(), 1);
  await withEnv({ PI_MODE: undefined }, () => {
    captureStart();
    try {
      handleSequenceTimeout();
    } finally {
      captureStop();
    }
    const stack = _stackForTest();
    equal(stack.length, 1, "child popped");
    equal(stack[0]!.path, "/repo/skills/parent/SKILL.md", "parent restored");
    ok(logs.some((l) => l.includes("popping stale")), "pop log line");
    ok(!logs.some((l) => l.includes("parking")), "no park in interactive mode");
  });
});

// ── verifier gate advancement under warn (fake pi) ───
section("verifier gate advancement under warn (fake pi)");

await test("task tool_call → reviewer counted; tool_result → advances to next step under warn", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv(
      { PI_MODE: "print", AGENT_SEQUENCE_MODE: "warn", AGENT_STATE_MACHINE: undefined, ELDATO_STATE_MACHINE: undefined },
      async () => {
        sequenceEnforcer(pi as any);
        _pushSkillForTest("/repo/skills/task-workflow-standard/SKILL.md", verifierSkillSteps(), 1);

        // dispatch reviewer — warn mode never blocks task
        await handlers.tool_call!({ toolName: "task" });
        const stack = _stackForTest();
        equal(stack[0]!.reviewers.get(1), 1, "reviewer dispatch counted at verifier step");
        const allowed = auditEntries.find((x) => x.event === "allowed");
        ok(allowed && allowed.tool === "task" && allowed.step === "review", "allowed audit for task dispatch");

        // reviewer returns — verifier gate advances despite warn mode
        await handlers.tool_result!({ toolName: "task" });
        equal(_stackForTest()[0]!.stepIndex, 2, "advanced past verifier gate to implement step");
      },
    );
  } finally { auditRelease(); }
});

await test("timeout wiring — firing the scheduled timer callback parks in print mode", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv(
      { PI_MODE: "print", AGENT_SEQUENCE_MODE: "warn", AGENT_STATE_MACHINE: undefined, ELDATO_STATE_MACHINE: undefined },
      async () => {
        sequenceEnforcer(pi as any);
        _pushSkillForTest("/repo/skills/demo/SKILL.md", verifierSkillSteps(), 1);
        const before = timerCbs.length;
        await handlers.tool_call!({ toolName: "read" });
        equal(timerCbs.length, before + 1, "tool_call re-armed the sequence timer");
        const cb = timerCbs[timerCbs.length - 1]!;
        cb(); // fire the 10-min idle timeout
        const stack = _stackForTest();
        equal(stack.length, 1, "parked, not popped");
        equal(stack[0]!.stepIndex, 1, "step preserved across timeout");
        ok(auditEntries.some((x) => x.event === "timeout_park"), "timeout_park audited via real timer path");
      },
    );
  } finally { auditRelease(); }
});

// ── cleanup + summary ────────────────────────────────
for (const d of TMP_DIRS) {
  try { rmSync(d, { recursive: true, force: true }); } catch { /* best-effort */ }
}
restoreTimers();
console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);

}

main();
