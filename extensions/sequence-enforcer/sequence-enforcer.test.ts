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
  isCheckpointEscape,
  validateToolCall,
  handleSequenceTimeout,
  checkpointTokenOk,
  parseTokenTs,
  loadSteps,
  CHECKPOINT_WHITESPACE_REJECT,
  _setTokenFileForTest,
  _setForceFileForTest,
  _setRepoForTest,
  _setAuditSinkForTest,
  _setBridgeDirForTest,
  _pushSkillForTest,
  _stackForTest,
  _resetStateForTest,
  _markerCountForTest,
  default as sequenceEnforcer,
  type Step,
} from "./index.js";
import { ok, equal, deepEqual } from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync, readFileSync, existsSync } from "node:fs";
import { tmpdir, homedir } from "node:os";
import { join } from "node:path";
import { execSync } from "node:child_process";

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
    token_phase: "",
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
let clearedTimers: unknown[] = [];
function installFakeTimers() {
  timerCbs = [];
  clearedTimers = [];
  (globalThis as any).setTimeout = (cb: () => void) => { timerCbs.push(cb); return timerCbs.length; };
  (globalThis as any).clearTimeout = (id: unknown) => { clearedTimers.push(id); };
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

// fake pi harness — multi-handler dispatch (Task 6 Step 0, pulled forward for
// #357 Task 3's F2 activation tests): pi delivers tool_call events to ALL
// registered handlers in registration order (read-tracker first, then
// enforcement). Previously only the last handler per event ran, making the
// read-handler/enforcement interplay untestable.
type Handler = (ev?: any, ctx?: any) => Promise<unknown>;
function fakePi(): { pi: any; handlers: Record<string, Handler> } {
  const registered: Record<string, Handler[]> = {};
  return {
    pi: {
      on: (ev: string, h: Handler) => { (registered[ev] ??= []).push(h); },
    },
    handlers: new Proxy({} as Record<string, Handler>, {
      // #357 review (Bug-scan P2): await each handler IN ORDER and return the
      // last settled result — pi's emitToolCall awaits handlers sequentially;
      // the previous fire-and-collect silently diverged the moment any handler
      // became genuinely async (enforcement must see the read-tracker's push).
      get: (_t, prop: string) => async (ev?: any, ctx?: any) => {
        let result: unknown;
        for (const h of registered[prop] ?? []) result = await h(ev, ctx);
        return result;
      },
    }),
  };
}

async function main() {

installFakeTimers();
_setBridgeDirForTest(tmpDir("bridge"));

// ── checkpointTokenOk — token acceptance matrix (#357 Task 2) ──
section("checkpointTokenOk — token acceptance matrix");

function writeToken(ts: unknown, extra: Record<string, unknown> = {}): void {
  const d = tmpDir("tok");
  writeFileSync(join(d, "token.json"), JSON.stringify({ verdict: "CLEAR", phase: "implement", ts, ...extra }));
  _setTokenFileForTest(join(d, "token.json"));
}

await test("parseTokenTs: ISO string → epoch ms", () => {
  const ms = parseTokenTs("2026-08-28T22:29:16.164Z");
  ok(typeof ms === "number" && Number.isFinite(ms), "ISO parsed to finite ms");
});

await test("parseTokenTs: numeric-ms number → as-is", () => {
  equal(parseTokenTs(Date.now()), Date.now());
});

await test("parseTokenTs: numeric-s (1.7e9) → ×1000 → ms", () => {
  const s = Math.floor(Date.now() / 1000);
  equal(parseTokenTs(s), s * 1000);
});

await test("parseTokenTs: garbage / null / undefined → null (fail-closed)", () => {
  equal(parseTokenTs("garbage"), null);
  equal(parseTokenTs(""), null);
  equal(parseTokenTs(null), null);
  equal(parseTokenTs(undefined), null);
  equal(parseTokenTs({}), null);
});

await test("ISO fresh CLEAR token → ok (the writer's actual contract)", () => {
  try {
    writeToken(new Date().toISOString());
    const r = checkpointTokenOk(makeStep({ name: "check", gate: "checkpoint", token_phase: "implement" }));
    ok(r.ok, r.reason);
  } finally { _setTokenFileForTest(null); }
});

await test("numeric epoch-ms fresh → ok", () => {
  try {
    writeToken(Date.now());
    ok(checkpointTokenOk(makeStep({ gate: "checkpoint", token_phase: "implement" })).ok);
  } finally { _setTokenFileForTest(null); }
});

await test("numeric epoch-s fresh → ok (<1e12 → ×1000)", () => {
  try {
    writeToken(Math.floor(Date.now() / 1000));
    ok(checkpointTokenOk(makeStep({ gate: "checkpoint", token_phase: "implement" })).ok);
  } finally { _setTokenFileForTest(null); }
});

await test("stale (>10 min) → block", () => {
  try {
    writeToken(new Date(Date.now() - 11 * 60 * 1000).toISOString());
    ok(!checkpointTokenOk(makeStep({ gate: "checkpoint", token_phase: "implement" })).ok, "stale must block");
  } finally { _setTokenFileForTest(null); }
});

await test("TTL boundary: now−599s → ok; now−601s → block", () => {
  try {
    writeToken(new Date(Date.now() - 599_000).toISOString());
    ok(checkpointTokenOk(makeStep({ gate: "checkpoint", token_phase: "implement" })).ok, "599s inside TTL");
    _setTokenFileForTest(null);
    writeToken(new Date(Date.now() - 601_000).toISOString());
    ok(!checkpointTokenOk(makeStep({ gate: "checkpoint", token_phase: "implement" })).ok, "601s outside TTL");
  } finally { _setTokenFileForTest(null); }
});

await test("future-ts skew (now+300s) → ok until the skew passes (pinned)", () => {
  try {
    writeToken(new Date(Date.now() + 300_000).toISOString());
    const r = checkpointTokenOk(makeStep({ gate: "checkpoint", token_phase: "implement" }));
    ok(r.ok, "future ts = negative elapsed = inside TTL (documented)");
  } finally { _setTokenFileForTest(null); }
});

await test("wrong verdict → block", () => {
  try {
    writeToken(new Date().toISOString(), { verdict: "UNKNOWN" });
    ok(!checkpointTokenOk(makeStep({ gate: "checkpoint", token_phase: "implement" })).ok);
  } finally { _setTokenFileForTest(null); }
});

await test("corrupt JSON → block", () => {
  try {
    const d = tmpDir("tokcorrupt");
    writeFileSync(join(d, "token.json"), "not json{{{}}");
    _setTokenFileForTest(join(d, "token.json"));
    ok(!checkpointTokenOk(makeStep({ gate: "checkpoint", token_phase: "implement" })).ok);
  } finally { _setTokenFileForTest(null); }
});

await test("NaN ts → block (the root-cause NaN path — Number(ISO) === NaN)", () => {
  try {
    writeToken("garbage-not-a-date");
    ok(!checkpointTokenOk(makeStep({ gate: "checkpoint", token_phase: "implement" })).ok);
  } finally { _setTokenFileForTest(null); }
});

// ── #357 Task 3: token_phase + env path + fail-closed + loadSteps paths + F2 ──
section("checkpointTokenOk — token_phase, env path, fail-closed");

await test("phase-match token → ok", () => {
  try {
    writeToken(new Date().toISOString(), { phase: "implement" });
    ok(checkpointTokenOk(makeStep({ gate: "checkpoint", token_phase: "implement" })).ok);
  } finally { _setTokenFileForTest(null); }
});

await test("phase-mismatch token → block", () => {
  try {
    writeToken(new Date().toISOString(), { phase: "scope" });
    const r = checkpointTokenOk(makeStep({ gate: "checkpoint", token_phase: "implement" }));
    ok(!r.ok, "wrong-phase must block");
    ok(r.reason.includes("≠ required"), "reason names the phase mismatch");
  } finally { _setTokenFileForTest(null); }
});

await test("missing token_phase on a checkpoint step → fail-closed block (clear message)", () => {
  try {
    // even with a perfectly valid token in place, the gate is unpassable-by-design
    writeToken(new Date().toISOString(), { phase: "implement" });
    const r = checkpointTokenOk(makeStep({ gate: "checkpoint", token_phase: "" }));
    ok(!r.ok, "missing token_phase blocks");
    ok(r.reason.includes("token_phase"), "reason names the missing declaration");
  } finally { _setTokenFileForTest(null); }
});

await test("PARALLEL_CHECK_TOKEN_FILE (PLAIN env name — writer's contract) honored", async () => {
  const d = tmpDir("tokenenv");
  const p = join(d, "token.json");
  writeFileSync(p, JSON.stringify({ verdict: "CLEAR", phase: "implement", ts: new Date().toISOString() }));
  await withEnv({ PARALLEL_CHECK_TOKEN_FILE: p }, () => {
    _setTokenFileForTest(null);
    try {
      ok(checkpointTokenOk(makeStep({ gate: "checkpoint", token_phase: "implement" })).ok,
        "env-path token must be honored");
    } finally { _setTokenFileForTest(null); }
  });
});

// ── loadSteps — token_phase through BOTH extraction paths (#357 Task 3) ──
section("loadSteps — token_phase extraction paths");

function fixtureSkill(dir: string): string {
  const p = join(dir, "SKILL.md");
  writeFileSync(p, `---\nname: fixture\nsteps:\n  - name: plan\n    type: skill\n    gate: auto\n  - name: check\n    type: skill\n    gate: checkpoint\n    token_phase: implement\n  - name: implement\n    type: skill\n    gate: auto\n---\n\n# Fixture\n`);
  return p;
}

await test("frontmatter path: token_phase survives loadSteps (the _try_frontmatter parse)", () => {
  _resetStateForTest();
  const d = tmpDir("fm");
  const skillPath = fixtureSkill(d);
  const steps = loadSteps(skillPath);
  ok(steps && steps.length === 3, "3 steps parsed");
  const check = steps!.find((s) => s.name === "check");
  ok(check && check.gate === "checkpoint", "checkpoint gate parsed");
  ok(check && check.token_phase === "implement", "token_phase survives frontmatter path");
});

await test("module path: normalization restores token_phase when the module drops it (eldato bridge)", () => {
  _resetStateForTest();
  const d = tmpDir("mod");
  const toolsDir = join(d, "tools");
  mkdirSync(toolsDir, { recursive: true });
  // eldato's skill_declaration.py does NOT emit token_phase (the dead-code root
  // cause) — the bridge normalization must re-read frontmatter and restore it.
  writeFileSync(join(toolsDir, "skill_declaration.py"), `
def extract_steps_from_skill(path):
    class Step:
        def __init__(self, name, gate):
            self.name = name; self.type = 'skill'; self.skill = ''
            self.requires = []; self.produces = []
            self.gate = gate
            self.retry = 1; self.timeout_seconds = 0
    return [Step('plan', 'auto'), Step('check', 'checkpoint'), Step('implement', 'auto')]
`);
  const skillPath = fixtureSkill(d);
  const saved = process.env.AGENT_TOOLS_PATH;
  process.env.AGENT_TOOLS_PATH = toolsDir;
  try {
    const steps = loadSteps(skillPath);
    ok(steps && steps.length === 3, "3 steps from module path");
    const check = steps!.find((s) => s.name === "check");
    ok(check && check.gate === "checkpoint", "checkpoint gate from module");
    ok(check && check.token_phase === "implement", "token_phase RESTORED by normalization (module dropped it)");
  } finally {
    if (saved === undefined) delete process.env.AGENT_TOOLS_PATH;
    else process.env.AGENT_TOOLS_PATH = saved;
  }
});

// #357 Task 3 F2: the read handler only activates the pipeline in a WORKTREE
// (the inWorktree check runs git rev-parse from cwd). Build a real throwaway
// git worktree fixture (mirrors auto-sync.test.ts temp-repo pattern) so the
// activation path actually fires in tests.
function makeWorktreeSkill(dir: string, content: string): { wt: string } {
  const common = join(dir, "bare.git");
  execSync(`git init --bare -q -b main "${common}"`);
  const seed = join(dir, "seed");
  execSync(`git clone -q "${common}" "${seed}"`);
  execSync(`git -C "${seed}" config user.email f2@test.local`);
  execSync(`git -C "${seed}" config user.name f2test`);
  writeFileSync(join(seed, "f.txt"), "x\n");
  execSync(`git -C "${seed}" add -A`);
  execSync(`git -C "${seed}" commit -q -m seed`);
  execSync(`git -C "${seed}" push -q origin main`);
  const wt = join(dir, "wt");
  execSync(`git -C "${seed}" worktree add -q "${wt}"`);
  writeFileSync(join(wt, "SKILL.md"), content);
  return { wt };
}

// ── F2: fail-closed warning at activation (#357 Task 3) ──
section("F2 — fail-closed warning at skill activation");

await test("checkpoint step missing token_phase → warning fires at activation", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  const d = tmpDir("f2bad");
  const { wt } = makeWorktreeSkill(d, `---\nname: badfixture\nsteps:\n  - name: check\n    type: skill\n    gate: checkpoint\n---\n`);
  const savedCwd = process.cwd();
  await withEnv(
    { PI_MODE: "print", AGENT_SEQUENCE_MODE: "warn", AGENT_STATE_MACHINE: undefined, ELDATO_STATE_MACHINE: undefined },
    async () => {
      sequenceEnforcer(pi as any);
      captureStart();
      try {
        process.chdir(wt);
        await handlers.tool_call!({ toolName: "read", input: { path: join(wt, "SKILL.md") } });
      } finally {
        process.chdir(savedCwd);
        captureStop();
      }
      ok(logs.some((l) => l.includes("F2") && l.includes("check")), "F2 warning lists the step");
    },
  );
});

await test("checkpoint step WITH token_phase → no F2 warning", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  const d = tmpDir("f2good");
  const { wt } = makeWorktreeSkill(d, `---\nname: goodfixture\nsteps:\n  - name: plan\n    type: skill\n    gate: auto\n  - name: check\n    type: skill\n    gate: checkpoint\n    token_phase: implement\n---\n`);
  const savedCwd = process.cwd();
  await withEnv(
    { PI_MODE: "print", AGENT_SEQUENCE_MODE: "warn", AGENT_STATE_MACHINE: undefined, ELDATO_STATE_MACHINE: undefined },
    async () => {
      sequenceEnforcer(pi as any);
      captureStart();
      try {
        process.chdir(wt);
        await handlers.tool_call!({ toolName: "read", input: { path: join(wt, "SKILL.md") } });
      } finally {
        process.chdir(savedCwd);
        captureStop();
      }
      ok(logs.some((l) => l.includes("📖 Activated")), "skill actually activated (real negative test)");
      ok(!logs.some((l) => l.includes("F2")), "no F2 warning for a well-declared skill");
    },
  );
});

// ── auditLog — NODE_ENV=test sink hygiene (#357 Task 8, landed early) ──
section("auditLog — no production writes under NODE_ENV=test without a sink");

await test("auditLog with no sink under NODE_ENV=test → ZERO production writes (probe-hygiene)", async () => {
  const auditPath = join(homedir(), ".pi", "agent", "audit", "enforcement.jsonl");
  const before = existsSync(auditPath) ? readFileSync(auditPath, "utf-8") : "";
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  _setAuditSinkForTest(null); // NO sink — without the NODE_ENV=test guard this WOULD write the production log
  try {
    await withEnv(
      { PI_MODE: "print", AGENT_SEQUENCE_MODE: "gate", AGENT_STATE_MACHINE: undefined, ELDATO_STATE_MACHINE: undefined },
      async () => {
        sequenceEnforcer(pi as any);
        // a real handler path: blocked call at a pending checkpoint — auditLog
        // (event: blocked) fires; it must NOT reach the production file.
        _pushSkillForTest("/repo/skills/check/SKILL.md", [makeStep({ name: "check", gate: "checkpoint", token_phase: "plan" })], 0);
        await handlers.tool_call!({ toolName: "bash", toolCallId: "hyg1", input: { command: "rm -rf /" } });
        // and a warn-mode checkpoint_skipped_warn path
        await withEnv(
          { PI_MODE: "print", AGENT_SEQUENCE_MODE: "warn", AGENT_STATE_MACHINE: undefined, ELDATO_STATE_MACHINE: undefined },
          async () => {
            await handlers.tool_call!({ toolName: "bash", toolCallId: "hyg2", input: { command: "rm -rf /" } });
          },
        );
      },
    );
  } finally {
    _setAuditSinkForTest(null);
  }
  const after = existsSync(auditPath) ? readFileSync(auditPath, "utf-8") : "";
  equal(after, before, "no entries appended to the production audit log");
});

// ── #357 Task 6: checkpoint escape-hatch matrix ───────
section("checkpoint escape-hatch (d) — matrix");

function checkpointStep() {
  return makeStep({ name: "check", gate: "checkpoint", token_phase: "plan" });
}

// pending checkpoint (no token file) → escape applies
await test("ALLOWED: parallel_work_check.sh plan (sole command)", () => {
  ok(!validateToolCall("bash", "parallel_work_check.sh plan", checkpointStep(), "gate").block);
});

await test("ALLOWED: python3 /path/parallel_work_check.py plan (.py suffix)", () => {
  ok(!validateToolCall("bash", "python3 /repo/operations/coordination/parallel_work_check.py plan", checkpointStep(), "gate").block);
});

await test("ALLOWED: env GH_TOKEN=x parallel_work_check.sh plan (positive allowlist)", () => {
  ok(!validateToolCall("bash", "env GH_TOKEN=abc123 parallel_work_check.sh plan", checkpointStep(), "gate").block);
});

await test("ALLOWED: uv run parallel_work_check.sh plan", () => {
  ok(!validateToolCall("bash", "uv run parallel_work_check.sh plan", checkpointStep(), "gate").block);
});

await test("ALLOWED: read + loop_enforcer (the #7470 escape, never blocked)", () => {
  ok(!validateToolCall("read", "", checkpointStep(), "gate").block);
  ok(!validateToolCall("loop_enforcer", "", checkpointStep(), "gate").block);
});

await test("BLOCKED: bare name (no phase arg)", () => {
  ok(validateToolCall("bash", "parallel_work_check.sh", checkpointStep(), "gate").block);
});

await test("BLOCKED: rm -rf / (unrelated destructive command)", () => {
  ok(validateToolCall("bash", "rm -rf /", checkpointStep(), "gate").block);
});

await test("BLOCKED: git commit && parallel_work_check.sh plan (chain)", () => {
  ok(validateToolCall("bash", "git commit -m x && parallel_work_check.sh plan", checkpointStep(), "gate").block);
});

await test("BLOCKED: parallel_work_check.sh plan & (background)", () => {
  ok(validateToolCall("bash", "parallel_work_check.sh plan &", checkpointStep(), "gate").block);
});

await test("BLOCKED: embedded newline", () => {
  ok(validateToolCall("bash", "parallel_work_check.sh plan\necho pwned", checkpointStep(), "gate").block);
});

await test("BLOCKED: tab whitespace", () => {
  ok(validateToolCall("bash", "parallel_work_check.sh\tplan", checkpointStep(), "gate").block);
});

await test("BLOCKED: NBSP (U+00A0) whitespace", () => {
  ok(validateToolCall("bash", "parallel_work_check.sh\u00a0plan", checkpointStep(), "gate").block);
});

await test("BLOCKED: Ogham space (U+1680) whitespace", () => {
  ok(validateToolCall("bash", "parallel_work_check.sh\u1680plan", checkpointStep(), "gate").block);
});

await test("BLOCKED: env value injection $(rm -rf /)", () => {
  ok(validateToolCall("bash", "env GH_TOKEN=$(rm -rf /) parallel_work_check.sh plan", checkpointStep(), "gate").block);
});

await test("BLOCKED: sudo env GH_TOKEN=x parallel_work_check.sh plan (env-before-sudo order)", () => {
  ok(validateToolCall("bash", "sudo env GH_TOKEN=x parallel_work_check.sh plan", checkpointStep(), "gate").block);
});

await test("BLOCKED: cd /tmp && parallel_work_check.sh plan", () => {
  ok(validateToolCall("bash", "cd /tmp && parallel_work_check.sh plan", checkpointStep(), "gate").block);
});

await test("BLOCKED: python3 -m parallel_work_check plan (module flag)", () => {
  ok(validateToolCall("bash", "python3 -m parallel_work_check plan", checkpointStep(), "gate").block);
});

await test("BLOCKED: /usr/bin/python3 absolute interpreter", () => {
  ok(validateToolCall("bash", "/usr/bin/python3 parallel_work_check.py plan", checkpointStep(), "gate").block);
});

await test("BLOCKED: task tool (not an escape tool)", () => {
  ok(validateToolCall("task", "", checkpointStep(), "gate").block);
});

await test("U+0020-not-rejected regression: the reject-set does NOT match a plain space", () => {
  ok(!CHECKPOINT_WHITESPACE_REJECT.test(" "), "plain space must NOT be rejected");
  ok(CHECKPOINT_WHITESPACE_REJECT.test("\t"), "tab rejected");
  ok(CHECKPOINT_WHITESPACE_REJECT.test("\n"), "newline rejected");
  ok(CHECKPOINT_WHITESPACE_REJECT.test("\u00a0"), "NBSP rejected");
  ok(CHECKPOINT_WHITESPACE_REJECT.test("\u200b"), "zero-width rejected");
});

await test("malformed bash events → fail-closed BLOCK, no throw (input:{} / undefined / 42 / null)", () => {
  const step = checkpointStep();
  // handler converts nullish → "" before validateToolCall (?? ""); 42 passes
  // through as a non-string and hits the type-guard.
  const rNull = validateToolCall("bash", null as any, step, "gate");
  ok(rNull.block, "null blocked (type-guard, fail-closed)");
  const r42 = validateToolCall("bash", 42 as any, step, "gate");
  ok(r42.block, "numeric command blocked (type-guard)");
  ok((r42.reason || "").includes("malformed"), "malformed reason present for 42");
  const rUndef = validateToolCall("bash", undefined as any, step, "gate");
  ok(rUndef.block, "undefined blocked (type-guard, fail-closed)");
  const rEmpty = validateToolCall("bash", "", step, "gate");
  ok(rEmpty.block, "empty string blocked (no escape match)");
  ok(!(rEmpty.reason || "").includes("malformed"), "empty string → token reason (not malformed)");
});

await test("malformed bash EVENTS through the real handler → blocked, no exception escapes", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv(
      { PI_MODE: "print", AGENT_SEQUENCE_MODE: "gate", AGENT_STATE_MACHINE: undefined, ELDATO_STATE_MACHINE: undefined },
      async () => {
        sequenceEnforcer(pi as any);
        _pushSkillForTest("/repo/skills/check/SKILL.md", [checkpointStep()], 0);
        const res1 = await handlers.tool_call!({ toolName: "bash", input: {} });
        ok(res1 && res1.block, "input:{} blocked");
        const res2 = await handlers.tool_call!({ toolName: "bash", input: { command: undefined } });
        ok(res2 && res2.block, "command:undefined blocked");
        const res3 = await handlers.tool_call!({ toolName: "bash", input: { command: 42 } });
        ok(res3 && res3.block, "command:42 blocked");
        const res4 = await handlers.tool_call!({ toolName: "bash", input: { command: null } });
        ok(res4 && res4.block, "command:null blocked");
        const blocked = auditEntries.filter((x) => x.event === "blocked");
        ok(blocked.length >= 4, "all four malformed calls audited (no exception escaped)");
      },
    );
  } finally { auditRelease(); }
});

await test("escape at an ok-checkpoint → BLOCKED by the checkpoint_token_fresh execution guard", () => {
  try {
    writeToken(new Date().toISOString(), { phase: "plan" });
    const r = validateToolCall("bash", "parallel_work_check.sh plan", checkpointStep(), "gate");
    ok(r.block, "checker re-run blocked at ok-checkpoint");
    ok((r.reason || "").includes("do NOT re-run"), "token_fresh guidance present");
  } finally { _setTokenFileForTest(null); }
});

await test("read/loop_enforcer still allowed at an ok-checkpoint", () => {
  try {
    writeToken(new Date().toISOString(), { phase: "plan" });
    ok(!validateToolCall("read", "", checkpointStep(), "gate").block);
    ok(!validateToolCall("loop_enforcer", "", checkpointStep(), "gate").block);
  } finally { _setTokenFileForTest(null); }
});

await test("non-checker tool at a fresh-ok checkpoint → allowed (friction fix: the step already advanced; the next step validates)", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv({ PI_MODE: "print", AGENT_SEQUENCE_MODE: "gate", AGENT_STATE_MACHINE: undefined, ELDATO_STATE_MACHINE: undefined }, async () => {
      sequenceEnforcer(pi as any);
      _pushSkillForTest("/repo/skills/check/SKILL.md", checkpointSkillSteps(), 0);
      writeToken(new Date().toISOString(), { phase: "plan" });
      const res = await handlers.tool_call!({ toolName: "write", toolCallId: "w1", input: { path: "x", content: "y" } });
      ok(!res || !res.block, "write allowed at fresh-ok checkpoint (blocked-call rule already advanced)");
      equal(_stackForTest()[0]!.stepIndex, 1, "advance happened");
      ok(!auditEntries.some((x) => x.event === "blocked"), "no spurious blocked audit in the success path");
    });
  } finally { auditRelease(); _setTokenFileForTest(null); }
});

await test("handler: checker re-run at a fresh-ok checkpoint → audit event checkpoint_token_fresh (the documented 4-event set)", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv({ PI_MODE: "print", AGENT_SEQUENCE_MODE: "gate", AGENT_STATE_MACHINE: undefined, ELDATO_STATE_MACHINE: undefined }, async () => {
      sequenceEnforcer(pi as any);
      _pushSkillForTest("/repo/skills/check/SKILL.md", checkpointSkillSteps(), 0);
      writeToken(new Date().toISOString(), { phase: "plan" });
      const res = await handlers.tool_call!({ toolName: "bash", toolCallId: "tf1", input: { command: "parallel_work_check.sh plan" } });
      ok(res && res.block, "checker re-run blocked at fresh-ok checkpoint");
      equal(_stackForTest()[0]!.stepIndex, 1, "advance still happened (blocked-call rule)");
      const fresh = auditEntries.filter((x) => x.event === "checkpoint_token_fresh");
      equal(fresh.length, 1, "distinct checkpoint_token_fresh event emitted");
      ok(!auditEntries.some((x) => x.event === "blocked" && x.tool === "bash"), "not logged as generic blocked");
      ok((fresh[0]!.reason as string).includes("do NOT re-run"), "reason carries the token_fresh guidance");
    });
  } finally { auditRelease(); _setTokenFileForTest(null); }
});

await test("escape works under strict mode too", () => {
  ok(!validateToolCall("bash", "parallel_work_check.sh plan", checkpointStep(), "strict").block);
  ok(validateToolCall("bash", "rm -rf /", checkpointStep(), "strict").block);
});

await test("wrong-phase checker at a pending checkpoint → BLOCKED (would write a never-satisfying token)", () => {
  const r = validateToolCall("bash", "parallel_work_check.sh implement", checkpointStep(), "gate");
  ok(r.block, "wrong-phase escape blocked");
  ok((r.reason || "").includes("requires phase \"plan\""), "guidance names the correct phase");
});

// ── #357 Task 7: mode-independent advancement + marker contract ──
section("checkpoint advancement (c) — marker contract");

function checkpointSkillSteps(): Step[] {
  return [
    makeStep({ name: "check", gate: "checkpoint", token_phase: "plan" }),
    makeStep({ name: "implement", gate: "auto" }),
  ];
}

const GATE_ENV = { PI_MODE: "print", AGENT_SEQUENCE_MODE: "gate", AGENT_STATE_MACHINE: undefined, ELDATO_STATE_MACHINE: undefined };

await test("valid-token-advance: tool_call at an ok-checkpoint advances (blocked-call rule), tool_result does NOT re-advance", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv(GATE_ENV, async () => {
      sequenceEnforcer(pi as any);
      _pushSkillForTest("/repo/skills/check/SKILL.md", checkpointSkillSteps(), 0);
      writeToken(new Date().toISOString(), { phase: "plan" });
      const res = await handlers.tool_call!({ toolName: "read", toolCallId: "c1", input: { path: "x" } });
      ok(!res || !res.block, "read allowed at ok-checkpoint");
      equal(_stackForTest()[0]!.stepIndex, 1, "advanced to implement step");
      await handlers.tool_result!({ toolName: "read", toolCallId: "c1" });
      equal(_stackForTest()[0]!.stepIndex, 1, "no double-advance via tool_result (ok marker suppression)");
    });
  } finally { auditRelease(); _setTokenFileForTest(null); }
});

await test("producer-timing: escape tool_call allowed (no advance); token written; tool_result advances on ok-now", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv(GATE_ENV, async () => {
      sequenceEnforcer(pi as any);
      _pushSkillForTest("/repo/skills/check/SKILL.md", checkpointSkillSteps(), 0);
      const res = await handlers.tool_call!({ toolName: "bash", toolCallId: "e1", input: { command: "parallel_work_check.sh plan" } });
      ok(!res || !res.block, "escape allowed");
      equal(_stackForTest()[0]!.stepIndex, 0, "no advance at tool_call (token not ok yet)");
      writeToken(new Date().toISOString(), { phase: "plan" }); // checker completes, writes token
      await handlers.tool_result!({ toolName: "bash", toolCallId: "e1" });
      equal(_stackForTest()[0]!.stepIndex, 1, "advanced on !ok@call → ok@result transition");
    });
  } finally { auditRelease(); _setTokenFileForTest(null); }
});

await test("fail-open guard: failing checker run leaves token non-ok → NO advance", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv(GATE_ENV, async () => {
      sequenceEnforcer(pi as any);
      _pushSkillForTest("/repo/skills/check/SKILL.md", checkpointSkillSteps(), 0);
      await handlers.tool_call!({ toolName: "bash", toolCallId: "e2", input: { command: "parallel_work_check.sh plan" } });
      // checker FAILED (e.g. UNKNOWN) — token absent: tool_result must NOT advance
      await handlers.tool_result!({ toolName: "bash", toolCallId: "e2" });
      equal(_stackForTest()[0]!.stepIndex, 0, "no advance — token still non-ok (fail-open guard)");
    });
  } finally { auditRelease(); _setTokenFileForTest(null); }
});

await test("back-to-back checkpoint pair: exactly ONE advance per call (same-call suppression)", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv(GATE_ENV, async () => {
      sequenceEnforcer(pi as any);
      const pair = [
        makeStep({ name: "check1", gate: "checkpoint", token_phase: "plan" }),
        makeStep({ name: "check2", gate: "checkpoint", token_phase: "plan" }),
        makeStep({ name: "impl", gate: "auto" }),
      ];
      _pushSkillForTest("/repo/skills/pair/SKILL.md", pair, 0);
      writeToken(new Date().toISOString(), { phase: "plan" });
      await handlers.tool_call!({ toolName: "read", toolCallId: "a", input: { path: "x" } });
      equal(_stackForTest()[0]!.stepIndex, 1, "call A advanced check1 → check2");
      await handlers.tool_result!({ toolName: "read", toolCallId: "a" });
      equal(_stackForTest()[0]!.stepIndex, 1, "call A's tool_result did NOT advance check2");
      await handlers.tool_call!({ toolName: "read", toolCallId: "b", input: { path: "x" } });
      equal(_stackForTest()[0]!.stepIndex, 2, "call B advanced check2 → impl");
    });
  } finally { auditRelease(); _setTokenFileForTest(null); }
});

await test("completion-order reversal: two sibling escape calls, token written → exactly ONE advance", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv(GATE_ENV, async () => {
      sequenceEnforcer(pi as any);
      _pushSkillForTest("/repo/skills/check/SKILL.md", checkpointSkillSteps(), 0);
      await handlers.tool_call!({ toolName: "bash", toolCallId: "e1", input: { command: "parallel_work_check.sh plan" } });
      await handlers.tool_call!({ toolName: "bash", toolCallId: "e2", input: { command: "parallel_work_check.sh plan" } });
      equal(_stackForTest()[0]!.stepIndex, 0, "both allowed, no advance yet");
      writeToken(new Date().toISOString(), { phase: "plan" });
      await handlers.tool_result!({ toolName: "bash", toolCallId: "e2" }); // e2 completes FIRST
      equal(_stackForTest()[0]!.stepIndex, 1, "e2 advanced (marker current)");
      await handlers.tool_result!({ toolName: "bash", toolCallId: "e1" }); // e1 late
      equal(_stackForTest()[0]!.stepIndex, 1, "e1 stale marker rejected — no second advance");
    });
  } finally { auditRelease(); _setTokenFileForTest(null); }
});

await test("distinct-sibling-after-advance (1C): sibling B validated against the NEXT step after A advanced", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv(GATE_ENV, async () => {
      sequenceEnforcer(pi as any);
      const steps = [
        makeStep({ name: "check", gate: "checkpoint", token_phase: "plan" }),
        makeStep({ name: "review", gate: "verifier" }),
      ];
      _pushSkillForTest("/repo/skills/sib/SKILL.md", steps, 0);
      writeToken(new Date().toISOString(), { phase: "plan" });
      const a = await handlers.tool_call!({ toolName: "read", toolCallId: "a", input: { path: "x" } });
      ok(!a || !a.block, "A allowed at ok-checkpoint");
      equal(_stackForTest()[0]!.stepIndex, 1, "A advanced to the verifier step");
      const b = await handlers.tool_call!({ toolName: "bash", toolCallId: "b", input: { command: "rm -rf /" } });
      ok(b && b.block, "B blocked by the NEXT (verifier) step — not re-validated against the checkpoint");
      ok((b.reason as string).includes("verifier"), "B's reason is the verifier gate");
    });
  } finally { auditRelease(); _setTokenFileForTest(null); }
});

await test("concurrent cross-phase escape race: wrong-phase sibling blocked, exactly one advance, no strand", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv(GATE_ENV, async () => {
      sequenceEnforcer(pi as any);
      _pushSkillForTest("/repo/skills/check/SKILL.md", checkpointSkillSteps(), 0);
      const right = await handlers.tool_call!({ toolName: "bash", toolCallId: "r", input: { command: "parallel_work_check.sh plan" } });
      ok(!right || !right.block, "right-phase escape allowed");
      const wrong = await handlers.tool_call!({ toolName: "bash", toolCallId: "w", input: { command: "parallel_work_check.sh implement" } });
      ok(wrong && wrong.block, "wrong-phase sibling blocked (never writes a never-satisfying token)");
      writeToken(new Date().toISOString(), { phase: "plan" });
      await handlers.tool_result!({ toolName: "bash", toolCallId: "r" });
      equal(_stackForTest()[0]!.stepIndex, 1, "right-phase advance — no strand");
    });
  } finally { auditRelease(); _setTokenFileForTest(null); }
});

await test("marker cap/evict: sustained allowed calls with no tool_result → map bounded, evicted marker's late result does NOT advance", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv(GATE_ENV, async () => {
      sequenceEnforcer(pi as any);
      _pushSkillForTest("/repo/skills/check/SKILL.md", checkpointSkillSteps(), 0);
      for (let i = 0; i < 60; i++) {
        await handlers.tool_call!({ toolName: "bash", toolCallId: `evict-${i}`, input: { command: "parallel_work_check.sh plan" } });
      }
      ok(_markerCountForTest() <= 50, `marker map bounded (got ${_markerCountForTest()})`);
      equal(_stackForTest()[0]!.stepIndex, 0, "no advance — no token yet");
      // a late tool_result for an EVICTED (oldest) marker must not advance
      await handlers.tool_result!({ toolName: "bash", toolCallId: "evict-0" });
      equal(_stackForTest()[0]!.stepIndex, 0, "evicted marker's tool_result does not advance");
    });
  } finally { auditRelease(); _setTokenFileForTest(null); }
});

await test("sub-skill-read ordering: checkpoint-owner via stack-walk — sub-skill above does NOT hijack the owner's advance", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv(GATE_ENV, async () => {
      sequenceEnforcer(pi as any);
      _pushSkillForTest("/repo/skills/parent/SKILL.md", checkpointSkillSteps(), 0); // parent at checkpoint
      _pushSkillForTest("/repo/skills/sub/SKILL.md", [makeStep({ name: "auto1" })], 0); // sub-skill above
      const res = await handlers.tool_call!({ toolName: "bash", toolCallId: "s1", input: { command: "parallel_work_check.sh plan" } });
      ok(!res || !res.block, "escape allowed (owner found via stack-walk)");
      writeToken(new Date().toISOString(), { phase: "plan" });
      await handlers.tool_result!({ toolName: "bash", toolCallId: "s1" });
      const stack = _stackForTest();
      equal(stack[0]!.stepIndex, 1, "PARENT (owner) advanced");
      equal(stack[1]!.stepIndex, 0, "sub-skill untouched");
    });
  } finally { auditRelease(); _setTokenFileForTest(null); }
});

await test("warn first-call advance: checkpoint_skipped_warn is the ONLY audit, no warn_blocked / allowed double-entry", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv({ PI_MODE: "print", AGENT_SEQUENCE_MODE: "warn", AGENT_STATE_MACHINE: undefined, ELDATO_STATE_MACHINE: undefined }, async () => {
      sequenceEnforcer(pi as any);
      _pushSkillForTest("/repo/skills/check/SKILL.md", checkpointSkillSteps(), 0);
      await handlers.tool_call!({ toolName: "bash", toolCallId: "w1", input: { command: "rm -rf /" } });
      equal(_stackForTest()[0]!.stepIndex, 1, "warn advances on first call regardless of tool");
      const skipped = auditEntries.filter((x) => x.event === "checkpoint_skipped_warn");
      equal(skipped.length, 1, "exactly ONE checkpoint_skipped_warn");
      equal(skipped[0]!.token_state, "none", "token_state recorded");
      ok(!auditEntries.some((x) => x.event === "warn_blocked" && x.tool === "bash"), "no warn_blocked for the advancing call");
      ok(!auditEntries.some((x) => x.event === "allowed"), "no allowed entry for the advancing call");
    });
  } finally { auditRelease(); }
});

await test("announceGate fires on checkpoint advance (next step gate announced)", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv(GATE_ENV, async () => {
      sequenceEnforcer(pi as any);
      const steps = [
        makeStep({ name: "check", gate: "checkpoint", token_phase: "plan" }),
        makeStep({ name: "review", gate: "verifier" }),
      ];
      _pushSkillForTest("/repo/skills/ann/SKILL.md", steps, 0);
      writeToken(new Date().toISOString(), { phase: "plan" });
      captureStart();
      try {
        await handlers.tool_call!({ toolName: "read", toolCallId: "n1", input: { path: "x" } });
      } finally { captureStop(); }
      ok(logs.some((l) => l.includes("Checkpoint advanced")), "advance logged");
      ok(logs.some((l) => l.includes("🔒 Gate: verifier")), "announceGate fired for the next (verifier) step");
    });
  } finally { auditRelease(); _setTokenFileForTest(null); }
});

// ── #357 Task 12: full-skill warn E2E ──
section("full-skill warn E2E (harness + stack-walk owner advancement)");

await test("worker completes a multi-checkpoint skill end-to-end under warn (both checkpoints skip, skill completes, stack popped)", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv(
      { PI_MODE: "print", AGENT_SEQUENCE_MODE: "warn", AGENT_STATE_MACHINE: undefined, ELDATO_STATE_MACHINE: undefined },
      async () => {
        sequenceEnforcer(pi as any);
        const steps = [
          makeStep({ name: "check1", gate: "checkpoint", token_phase: "plan" }),
          makeStep({ name: "check2", gate: "checkpoint", token_phase: "implement" }),
        ];
        _pushSkillForTest("/repo/skills/warn-e2e/SKILL.md", steps, 0);
        await handlers.tool_call!({ toolName: "bash", toolCallId: "e1", input: { command: "echo work" } });
        equal(_stackForTest()[0]!.stepIndex, 1, "first checkpoint warn-advanced");
        await handlers.tool_call!({ toolName: "bash", toolCallId: "e2", input: { command: "echo more" } });
        equal(_stackForTest().length, 0, "skill completed — stack popped (all steps done)");
        const skips = auditEntries.filter((x) => x.event === "checkpoint_skipped_warn");
        equal(skips.length, 2, "both checkpoints audited with checkpoint_skipped_warn");
        equal(skips[0]!.step, "check1");
        equal(skips[1]!.step, "check2");
      },
    );
  } finally { auditRelease(); }
});

await test("warn-mode advance consumes a present force file (one-shot invariant under warn too)", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    _setRepoForTest("test-repo");
    const forcePath = join(tmpDir("force-warn"), "force.json");
    writeFileSync(forcePath, JSON.stringify({ verdict: "CLEAR", phase: "plan", operator: "daniel", origin: "shell", repo: "test-repo", ts: new Date().toISOString() }));
    _setForceFileForTest(forcePath);
    await withEnv(
      { PI_MODE: "print", AGENT_SEQUENCE_MODE: "warn", AGENT_STATE_MACHINE: undefined, ELDATO_STATE_MACHINE: undefined },
      async () => {
        sequenceEnforcer(pi as any);
        _pushSkillForTest("/repo/skills/check/SKILL.md", checkpointSkillSteps(), 0);
        await handlers.tool_call!({ toolName: "bash", toolCallId: "w1", input: { command: "rm -rf /" } });
        equal(_stackForTest()[0]!.stepIndex, 1, "warn advanced");
        ok(!existsSync(forcePath), "force file consumed on the warn advance (never passes a later same-phase gate)");
        const pass = auditEntries.filter((x) => x.event === "checkpoint_force_pass");
        equal(pass.length, 1, "checkpoint_force_pass audited for the consumed file");
      },
    );
  } finally { auditRelease(); _setForceFileForTest(null); _setRepoForTest(null); }
});

// ── #357 Task 8: park-only checkpoint recovery (j) ──
section("checkpoint recovery (j) — park-only");

function backdateCheckpoint(minutes: number): void {
  const stack = _stackForTest();
  if (stack.length > 0) stack[0]!.stepStartedAt = Date.now() - minutes * 60 * 1000;
}

await test("block-spam → park immediately at ≥3 consecutive blocked calls, frame survives", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv(GATE_ENV, async () => {
      sequenceEnforcer(pi as any);
      _pushSkillForTest("/repo/skills/check/SKILL.md", checkpointSkillSteps(), 0);
      await handlers.tool_call!({ toolName: "bash", toolCallId: "b1", input: { command: "rm -rf /" } });
      await handlers.tool_call!({ toolName: "bash", toolCallId: "b2", input: { command: "rm -rf /" } });
      await handlers.tool_call!({ toolName: "bash", toolCallId: "b3", input: { command: "rm -rf /" } });
      const rec = auditEntries.filter((x) => x.event === "checkpoint_block_recovery");
      equal(rec.length, 1, "parked once");
      equal(_stackForTest().length, 1, "frame survives (state preserved)");
      equal(_stackForTest()[0]!.stepIndex, 0, "stepIndex preserved");
    });
  } finally { auditRelease(); _setTokenFileForTest(null); }
});

await test("one-shot suppression: 4th+ blocked calls do NOT re-park the same checkpoint", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv(GATE_ENV, async () => {
      sequenceEnforcer(pi as any);
      _pushSkillForTest("/repo/skills/check/SKILL.md", checkpointSkillSteps(), 0);
      for (let i = 1; i <= 8; i++) {
        await handlers.tool_call!({ toolName: "bash", toolCallId: `s${i}`, input: { command: "rm -rf /" } });
      }
      const rec = auditEntries.filter((x) => x.event === "checkpoint_block_recovery");
      equal(rec.length, 1, "parked exactly once (one-shot per checkpoint)");
    });
  } finally { auditRelease(); _setTokenFileForTest(null); }
});

await test("wall-clock stall: backdated checkpoint parks on the next tool_call (reads reset the streak)", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv(GATE_ENV, async () => {
      sequenceEnforcer(pi as any);
      _pushSkillForTest("/repo/skills/check/SKILL.md", checkpointSkillSteps(), 0);
      // mixed spam: allowed read resets the streak, blocked bash never reaches 3
      await handlers.tool_call!({ toolName: "read", toolCallId: "r1", input: { path: "x" } });
      await handlers.tool_call!({ toolName: "bash", toolCallId: "m1", input: { command: "rm -rf /" } });
      await handlers.tool_call!({ toolName: "read", toolCallId: "r2", input: { path: "x" } });
      ok(!auditEntries.some((x) => x.event === "checkpoint_block_recovery"), "no park yet (streak reset by reads)");
      backdateCheckpoint(6); // > 5-min wall-clock threshold
      await handlers.tool_call!({ toolName: "bash", toolCallId: "m2", input: { command: "rm -rf /" } });
      const rec = auditEntries.filter((x) => x.event === "checkpoint_block_recovery");
      equal(rec.length, 1, "wall-clock park fired");
      ok((rec[0]!.reason as string).includes("wall-clock"), "reason is the wall-clock stall");
      equal(_stackForTest()[0]!.stepIndex, 0, "state preserved");
    });
  } finally { auditRelease(); _setTokenFileForTest(null); }
});

await test("auto-advance restarts the checkpoint stall clock (no spurious wall-clock park on first call at the checkpoint)", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv(GATE_ENV, async () => {
      sequenceEnforcer(pi as any);
      const steps = [
        makeStep({ name: "a1", gate: "auto" }),
        makeStep({ name: "check", gate: "checkpoint", token_phase: "plan" }),
      ];
      _pushSkillForTest("/repo/skills/auto/SKILL.md", steps, 0);
      _stackForTest()[0]!.stepStartedAt = Date.now() - 6 * 60 * 1000; // stale clock from a long auto phase
      // reading ANOTHER skill's SKILL.md auto-advances the top past `a1` into `check`
      await handlers.tool_call!({ toolName: "read", toolCallId: "r1", input: { path: "/repo/skills/other/SKILL.md" } });
      equal(_stackForTest()[0]!.stepIndex, 1, "auto-advanced into the checkpoint");
      await handlers.tool_call!({ toolName: "read", toolCallId: "r2", input: { path: "x" } }); // first call AT the checkpoint
      ok(!auditEntries.some((x) => x.event === "checkpoint_block_recovery"), "no spurious wall-clock park — the clock restarted at checkpoint entry");
    });
  } finally { auditRelease(); _setTokenFileForTest(null); }
});

await test("timer-driven park: ZERO further events after the arming call → sequence timer parks an idle checkpoint", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv(GATE_ENV, async () => {
      sequenceEnforcer(pi as any);
      _pushSkillForTest("/repo/skills/check/SKILL.md", checkpointSkillSteps(), 0);
      const before = timerCbs.length;
      await handlers.tool_call!({ toolName: "bash", toolCallId: "idle1", input: { command: "rm -rf /" } });
      equal(timerCbs.length, before + 1, "sequence timer armed");
      backdateCheckpoint(6); // stall > 5 min
      timerCbs[timerCbs.length - 1]!(); // fire — NO further events dispatched
      const rec = auditEntries.filter((x) => x.event === "checkpoint_block_recovery");
      equal(rec.length, 1, "idle checkpoint parked via the timer (timer-driven, not event-driven)");
      equal(_stackForTest().length, 1, "parked, never popped");
      equal(_stackForTest()[0]!.stepIndex, 0, "state preserved");
    });
  } finally { auditRelease(); _setTokenFileForTest(null); }
});

await test("timeout parks a checkpoint owner BELOW a sub-skill frame (owner via stack-walk, not top-only)", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv(GATE_ENV, async () => {
      sequenceEnforcer(pi as any);
      _pushSkillForTest("/repo/skills/owner/SKILL.md", checkpointSkillSteps(), 0); // owner at its checkpoint
      _pushSkillForTest("/repo/skills/sub/SKILL.md", [makeStep({ name: "sub" })], 0); // sub-skill ABOVE the owner
      _stackForTest()[0]!.stepStartedAt = Date.now() - 6 * 60 * 1000; // backdate the OWNER's clock
      handleSequenceTimeout(process.env, ["pi"]);
      const parks = auditEntries.filter((x) => x.event === "checkpoint_block_recovery");
      equal(parks.length, 1, "owner parked despite sitting below the top frame");
      equal(_stackForTest().length, 2, "stack preserved (park, never pop)");
    });
  } finally { auditRelease(); _setTokenFileForTest(null); }
});

await test("verifier-gate block-spam unaffected: no checkpoint recovery for verifier gates", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv(GATE_ENV, async () => {
      sequenceEnforcer(pi as any);
      _pushSkillForTest("/repo/skills/review/SKILL.md", verifierSkillSteps(), 1); // verifier step
      for (let i = 1; i <= 5; i++) {
        await handlers.tool_call!({ toolName: "bash", toolCallId: `v${i}`, input: { command: "rm -rf /" } });
      }
      ok(!auditEntries.some((x) => x.event === "checkpoint_block_recovery"), "verifier spam never parks");
      equal(_stackForTest()[0]!.stepIndex, 1, "verifier step untouched");
    });
  } finally { auditRelease(); _setTokenFileForTest(null); }
});

await test("audit-volume bound: 1k blocked calls → blocked entries coalesced (bounded), NODE_ENV=test sink hygiene", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv(GATE_ENV, async () => {
      sequenceEnforcer(pi as any);
      _pushSkillForTest("/repo/skills/check/SKILL.md", checkpointSkillSteps(), 0);
      for (let i = 0; i < 1000; i++) {
        await handlers.tool_call!({ toolName: "bash", toolCallId: `vol-${i}`, input: { command: "rm -rf /" } });
      }
      const blocked = auditEntries.filter((x) => x.event === "blocked");
      ok(blocked.length <= 21, `blocked entries bounded by the coalesce ceiling (got ${blocked.length})`);
      ok(blocked.length > 0, "signal preserved (ceiling not zero)");
    });
  } finally { auditRelease(); _setTokenFileForTest(null); }
});

// ── #357 Task 9: reachable checkpoint guidance (e) — 3 states ──
section("checkpoint guidance (e) — 3 states + conformance");

await test("state 1 (no-ok token): names the CLEAR-able invocation + escape tools + end-your-turn fallback, no placeholders", () => {
  const g = gateGuidance(checkpointStep()); // token_phase "plan", no token
  ok(g.length > 0, "non-empty");
  ok(g.includes("parallel_work_check.sh plan"), "names the interpolated invocation (resolved bin + phase)");
  ok(g.includes("read") && g.includes("loop_enforcer"), "names the escape tools");
  ok(g.includes("end your turn and report"), "end-your-turn fallback present");
  ok(!g.includes("$"), "no $VAR — the escape regex rejects $");
  ok(!g.includes("<phase>") && !g.includes("<phase") && !g.includes(">"), "no placeholder brackets — < > fail the escape");
});

await test("state 1 conformance: the emitted invocation passes isCheckpointEscape and is the parent/main-checkout form", () => {
  const g = gateGuidance(checkpointStep());
  const cmd = g.split("run `")[1]!.split("` until")[0]!;
  ok(isCheckpointEscape("bash", cmd), "emitted invocation passes the escape check (criterion 14)");
  ok(!cmd.includes("--repo"), "primary command omits --repo (the DEFER-guaranteed worktree form)");
  ok(!cmd.includes("$") && !cmd.includes("<") && !cmd.includes(">"), "no $VAR / <phase> in the command");
  ok(cmd.startsWith("/"), "absolute path-resolvable form");
});

await test("state 2 (fresh-ok token): 'do NOT re-run the checker, proceed' — no invocation named", () => {
  try {
    writeToken(new Date().toISOString(), { phase: "plan" });
    const g = gateGuidance(checkpointStep());
    ok(g.includes("do NOT re-run the checker"), "fresh-token variant");
    ok(!g.includes("parallel_work_check.sh plan"), "no checker instruction that would clobber the token");
  } finally { _setTokenFileForTest(null); }
});

await test("state 3 (missing token_phase): unpassable — contact operator, no invocation named", () => {
  const g = gateGuidance(makeStep({ name: "check", gate: "checkpoint", token_phase: "" }));
  ok(g.includes("unpassable"), "fail-closed variant");
  ok(g.includes("contact the operator"), "operator guidance");
  ok(!g.includes("parallel_work_check.sh"), "no invocation (empty phase would produce a no-arg command the escape rejects)");
});

await test("warn-mode variant: 'auto-advancing past checkpoint (audit-only)' — no checker run instruction", () => {
  const g = gateGuidance(checkpointStep(), "warn");
  ok(g.includes("auto-advancing"), "warn-aware guidance");
  ok(!g.includes("parallel_work_check.sh plan"), "no run-the-checker instruction in warn mode (wasted run + token churn)");
});

await test("blocked checkpoint entries carry allowed + hint naming the escape (guidance reachable)", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv(GATE_ENV, async () => {
      sequenceEnforcer(pi as any);
      _pushSkillForTest("/repo/skills/check/SKILL.md", checkpointSkillSteps(), 0);
      await handlers.tool_call!({ toolName: "bash", toolCallId: "g1", input: { command: "rm -rf /" } });
      const e = auditEntries.find((x) => x.event === "blocked");
      ok(e, "blocked entry written");
      ok(typeof e!.hint === "string" && (e!.hint as string).length > 0, "hint non-empty (was '' before the fix)");
      ok((e!.hint as string).includes("parallel_work_check.sh plan"), "hint names the CLEAR-able invocation");
      ok(Array.isArray(e!.allowed) && (e!.allowed as string[]).includes("read"), "allowed includes the escape tools");
    });
  } finally { auditRelease(); _setTokenFileForTest(null); }
});

await test("PARALLEL_CHECK_TOKEN_FILE env active: guidance still emits an escape-conformant command (env-consistency)", async () => {
  const d = tmpDir("guidance");
  const p = join(d, "token.json");
  await withEnv({ PARALLEL_CHECK_TOKEN_FILE: p }, () => {
    const g = gateGuidance(checkpointStep());
    const cmd = g.split("run `")[1]!.split("` until")[0]!;
    ok(isCheckpointEscape("bash", cmd), "command stays escape-conformant with the env override active");
    ok(!cmd.includes("env "), "no env interpolation into the command (PARALLEL_CHECK_TOKEN_FILE is NOT in the escape allowlist)");
    // the checker inherits the session env (which has the override) — both sides
    // honor PARALLEL_CHECK_TOKEN_FILE, so the guidance's command writes where the
    // enforcer reads.
  });
});

// ── #357 Task 10: operator force-pass (h) ──
section("operator force-pass (h)");

let lastForcePath = "";
function writeForceFile(obj: unknown): void {
  const d = tmpDir("force");
  const p = join(d, "force.json");
  writeFileSync(p, JSON.stringify(obj));
  _setForceFileForTest(p);
  lastForcePath = p;
}
function forceFilePath(): string {
  return lastForcePath;
}

const FORCE_GOOD = {
  verdict: "CLEAR",
  phase: "plan",
  operator: "daniel",
  origin: "shell",
  repo: "test-repo",
  ts: new Date().toISOString(),
};

await test("force pass (phase match + repo match) → checkpoint advances, checkpoint_force_pass event, file consumed (one-shot)", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    _setRepoForTest("test-repo");
    writeForceFile(FORCE_GOOD);
    await withEnv(GATE_ENV, async () => {
      sequenceEnforcer(pi as any);
      _pushSkillForTest("/repo/skills/check/SKILL.md", checkpointSkillSteps(), 0);
      const res = await handlers.tool_call!({ toolName: "read", toolCallId: "f1", input: { path: "x" } });
      ok(!res || !res.block, "force-driven advance not blocked");
      equal(_stackForTest()[0]!.stepIndex, 1, "advanced past the checkpoint");
      const pass = auditEntries.filter((x) => x.event === "checkpoint_force_pass");
      equal(pass.length, 1, "checkpoint_force_pass event emitted");
      equal(pass[0]!.operator, "daniel", "operator recorded");
      ok(!existsSync(forceFilePath()), "force file consumed (deleted) — one-shot per checkpoint");
    });
  } finally { auditRelease(); _setForceFileForTest(null); _setRepoForTest(null); }
});

await test("force wrong-phase → block (a plan force never passes the implement checkpoint)", async () => {
  _resetStateForTest();
  try {
    _setRepoForTest("test-repo");
    writeForceFile({ ...FORCE_GOOD, phase: "implement" });
    const r = checkpointTokenOk(makeStep({ gate: "checkpoint", token_phase: "plan" }));
    ok(!r.ok, "wrong-phase force blocked");
    ok(r.reason.includes("exists but is rejected"), "reason names the rejected force file (no silent strand)");
    ok(r.reason.includes('phase "implement" ≠ "plan"'), "reason names the phase mismatch");
  } finally { _setForceFileForTest(null); _setRepoForTest(null); }
});

await test("force repo-mismatch → block (a force written in repo A never passes repo B)", async () => {
  _resetStateForTest();
  try {
    _setRepoForTest("test-repo");
    writeForceFile({ ...FORCE_GOOD, repo: "other-repo" });
    const r = checkpointTokenOk(makeStep({ gate: "checkpoint", token_phase: "plan" }));
    ok(!r.ok, "repo-mismatch force blocked");
    ok(r.reason.includes('repo "other-repo" ≠ "test-repo"'), "reason names the repo mismatch");
  } finally { _setForceFileForTest(null); _setRepoForTest(null); }
});

await test("force TTL: >60 min stale force → block (operator TTL re-checked per call)", async () => {
  _resetStateForTest();
  try {
    _setRepoForTest("test-repo");
    writeForceFile({ ...FORCE_GOOD, ts: new Date(Date.now() - 61 * 60 * 1000).toISOString() });
    ok(!checkpointTokenOk(makeStep({ gate: "checkpoint", token_phase: "plan" })).ok);
  } finally { _setForceFileForTest(null); _setRepoForTest(null); }
});

await test("force future-ts → rejected (a clock-skewed ts must not grant an infinite operator TTL)", async () => {
  _resetStateForTest();
  try {
    _setRepoForTest("test-repo");
    writeForceFile({ ...FORCE_GOOD, ts: new Date(Date.now() + 5 * 60 * 1000).toISOString() });
    const r = checkpointTokenOk(makeStep({ gate: "checkpoint", token_phase: "plan" }));
    ok(!r.ok, "future-ts force blocked");
    ok(r.reason.includes("future ts"), "reason names the future-ts rejection");
  } finally { _setForceFileForTest(null); _setRepoForTest(null); }
});

await test("malformed force file (truncated / {} / missing fields / NaN ts) → fail-closed block, reason names the malformed file", async () => {
  _resetStateForTest();
  const cases: Array<{ label: string; obj: unknown }> = [
    { label: "truncated JSON", obj: "{not json" },
    { label: "empty object", obj: {} },
    { label: "missing operator", obj: { ...FORCE_GOOD, operator: undefined } },
    { label: "missing origin", obj: { ...FORCE_GOOD, origin: undefined } },
    { label: "missing repo", obj: { ...FORCE_GOOD, repo: undefined } },
    { label: "NaN ts", obj: { ...FORCE_GOOD, ts: "garbage" } },
  ];
  for (const c of cases) {
    try {
      _setRepoForTest("test-repo");
      writeForceFile(c.obj);
      const r = checkpointTokenOk(makeStep({ gate: "checkpoint", token_phase: "plan" }));
      ok(!r.ok, `${c.label} → fail-closed block`);
      ok(r.reason.includes("malformed"), `${c.label} → reason names the malformed force file`);
    } finally { _setForceFileForTest(null); }
  }
});

await test("force-driven advance consumes the file on ANY call outcome (one-shot invariant)", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    _setRepoForTest("test-repo");
    // back-to-back SAME-phase checkpoints — the exact hazard class: a leftover
    // file could pass the adjacent checkpoint if consumption lagged the advance.
    const pair = [
      makeStep({ name: "check1", gate: "checkpoint", token_phase: "plan" }),
      makeStep({ name: "check2", gate: "checkpoint", token_phase: "plan" }),
    ];
    await withEnv(GATE_ENV, async () => {
      sequenceEnforcer(pi as any);
      _pushSkillForTest("/repo/skills/pair/SKILL.md", pair, 0);
      // (a) non-escape call at the force-driven advance → BLOCKED, but the
      // force file is consumed BEFORE the block-return (consume-before-block).
      writeForceFile(FORCE_GOOD);
      const blocked = await handlers.tool_call!({ toolName: "bash", toolCallId: "fc1", input: { command: "rm -rf /" } });
      ok(blocked && blocked.block, "non-escape call blocked at the force-driven advance");
      ok(!existsSync(forceFilePath()), "force file consumed despite the block");
      equal(_stackForTest()[0]!.stepIndex, 1, "advance happened before the block");
    });
    // (b) checker re-run at a SECOND force-driven advance → allowed as the escape
    // (the file is consumed first, so the checkpoint is no longer ok → escape),
    // but the file is STILL consumed — a fresh one is needed for check2.
    _resetStateForTest();
    _setRepoForTest("test-repo");
    const { pi: pi2, handlers: handlers2 } = fakePi();
    auditCapture();
    writeForceFile(FORCE_GOOD);
    await withEnv(GATE_ENV, async () => {
      sequenceEnforcer(pi2 as any);
      _pushSkillForTest("/repo/skills/pair/SKILL.md", pair, 0);
      const res = await handlers2.tool_call!({ toolName: "bash", toolCallId: "fc2", input: { command: "parallel_work_check.sh plan" } });
      ok(!res || !res.block, "checker re-run allowed as the escape once the force file is consumed");
      ok(!existsSync(forceFilePath()), "force file consumed on the checker-re-run path too");
    });
  } finally { auditRelease(); _setForceFileForTest(null); _setRepoForTest(null); }
});

await test("session_start cleanup: a lingering force file is unlinked at session start", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  try {
    writeForceFile(FORCE_GOOD);
    ok(existsSync(forceFilePath()), "force file present before session_start");
    sequenceEnforcer(pi as any);
    await handlers.session_start!();
    ok(!existsSync(forceFilePath()), "session_start unlinked the lingering force file (documented hazard)");
  } finally { _setForceFileForTest(null); }
});

await test("session_start does NOT unlink on a mid-session reload (operator's file for the CURRENT session survives)", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  try {
    writeForceFile(FORCE_GOOD);
    sequenceEnforcer(pi as any);
    await handlers.session_start!({ type: "session_start", reason: "reload" } as any);
    ok(existsSync(forceFilePath()), "reload leaves the operator's force-pass file in place");
  } finally { _setForceFileForTest(null); }
});

await test("session_start resets recovery state (a prior session's one-shot park does NOT suppress the next session's signal)", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv(GATE_ENV, async () => {
      sequenceEnforcer(pi as any);
      // Session 1: 3 consecutive blocks → park (one-shot per checkpoint)
      _pushSkillForTest("/repo/skills/check/SKILL.md", checkpointSkillSteps(), 0);
      for (let i = 0; i < 3; i++) {
        await handlers.tool_call!({ toolName: "bash", toolCallId: `s1b${i}`, input: { command: "rm -rf /" } });
      }
      let parks = auditEntries.filter((x) => x.event === "checkpoint_block_recovery");
      equal(parks.length, 1, "session 1 parked once");
      // Session 2 begins — the park and the partial streak must be forgotten
      await handlers.session_start!();
      await handlers.session_shutdown!();
      _pushSkillForTest("/repo/skills/check/SKILL.md", checkpointSkillSteps(), 0);
      for (let i = 0; i < 3; i++) {
        await handlers.tool_call!({ toolName: "bash", toolCallId: `s2b${i}`, input: { command: "rm -rf /" } });
      }
      parks = auditEntries.filter((x) => x.event === "checkpoint_block_recovery");
      equal(parks.length, 2, "session 2 parks again — the one-shot suppression did NOT leak across sessions");
    });
  } finally { auditRelease(); _setTokenFileForTest(null); }
});

await test("session_start clears the armed sequence timer (a stale timer never fires into a new session)", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  try {
    await withEnv(GATE_ENV, async () => {
      sequenceEnforcer(pi as any);
      _pushSkillForTest("/repo/skills/check/SKILL.md", checkpointSkillSteps(), 0);
      await handlers.tool_call!({ toolName: "bash", toolCallId: "st1", input: { command: "rm -rf /" } }); // arms the 10-min timer
      ok(timerCbs.length >= 1, "timer armed by the tool_call");
      clearedTimers.length = 0;
      await handlers.session_start!();
      ok(clearedTimers.length >= 1, "session_start cleared the armed timer (cycle-2 Extension-safety)");
    });
  } finally { _setTokenFileForTest(null); }
});

await test("cross-session isolation: A's one-shot advance consumes only the file A's checkpoint consumed (phase/repo binding)", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    _setRepoForTest("test-repo");
    // session A advances via a force file for ITS phase
    writeForceFile(FORCE_GOOD);
    await withEnv(GATE_ENV, async () => {
      sequenceEnforcer(pi as any);
      _pushSkillForTest("/repo/skills/check/SKILL.md", checkpointSkillSteps(), 0);
      await handlers.tool_call!({ toolName: "read", toolCallId: "a1", input: { path: "x" } });
      equal(_stackForTest()[0]!.stepIndex, 1, "A advanced");
      ok(!existsSync(forceFilePath()), "force file consumed by A's advance");
      // ONE-SHOT: one file per checkpoint — A's advance consumed the plan file; a
      // SECOND checkpoint needs a FRESH file (the operator writes one per step).
      writeForceFile({ ...FORCE_GOOD, phase: "implement" });
      const r = checkpointTokenOk(makeStep({ gate: "checkpoint", token_phase: "implement" }));
      ok(r.ok, "a fresh right-phase force passes the next checkpoint (operator writes one per checkpoint)");
      ok(existsSync(forceFilePath()), "second file untouched until ITS checkpoint advances (one-shot per checkpoint)");
    });
  } finally { auditRelease(); _setForceFileForTest(null); _setRepoForTest(null); }
});

await test("real-token-wins advance consumes a present force file (one-shot invariant across token paths)", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    _setRepoForTest("test-repo");
    await withEnv(GATE_ENV, async () => {
      sequenceEnforcer(pi as any);
      _pushSkillForTest("/repo/skills/check/SKILL.md", checkpointSkillSteps(), 0);
      writeForceFile(FORCE_GOOD);
      writeToken(new Date().toISOString(), { phase: "plan" }); // REAL token ALSO fresh
      await handlers.tool_call!({ toolName: "read", toolCallId: "rw1", input: { path: "x" } });
      equal(_stackForTest()[0]!.stepIndex, 1, "advanced via the real token");
      ok(!existsSync(forceFilePath()), "force file consumed despite the real-token advance (must never pass a same-phase adjacent checkpoint)");
      const pass = auditEntries.filter((x) => x.event === "checkpoint_force_pass");
      equal(pass.length, 1, "checkpoint_force_pass audited — the operator's file was present at the advance");
    });
  } finally { auditRelease(); _setForceFileForTest(null); _setTokenFileForTest(null); _setRepoForTest(null); }
});

await test("mismatched-phase force file is LEFT for its own checkpoint (phase-aware consumption)", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    _setRepoForTest("test-repo");
    await withEnv(GATE_ENV, async () => {
      sequenceEnforcer(pi as any);
      _pushSkillForTest("/repo/skills/check/SKILL.md", checkpointSkillSteps(), 0); // plan checkpoint
      writeForceFile({ ...FORCE_GOOD, phase: "implement" }); // operator pre-wrote the IMPLEMENT file
      writeToken(new Date().toISOString(), { phase: "plan" }); // real plan token advances check1
      await handlers.tool_call!({ toolName: "read", toolCallId: "mm1", input: { path: "x" } });
      equal(_stackForTest()[0]!.stepIndex, 1, "advanced via the real plan token");
      ok(existsSync(forceFilePath()), "implement-phase file survives the plan advance — it is for ITS checkpoint");
      ok(!auditEntries.some((x) => x.event === "checkpoint_force_pass"), "no false force-pass claim at the wrong step");
    });
  } finally { auditRelease(); _setForceFileForTest(null); _setTokenFileForTest(null); _setRepoForTest(null); }
});

await test("non-passable force file (expired / wrong-repo / future-ts) survives a real-token advance; malformed is cleaned without a force_pass audit", async () => {
  const variants: Array<{ label: string; obj: unknown }> = [
    { label: "expired", obj: { ...FORCE_GOOD, ts: new Date(Date.now() - 61 * 60 * 1000).toISOString() } },
    { label: "wrong-repo", obj: { ...FORCE_GOOD, repo: "other-repo" } },
    { label: "future-ts", obj: { ...FORCE_GOOD, ts: new Date(Date.now() + 5 * 60 * 1000).toISOString() } },
  ];
  for (const v of variants) {
    _resetStateForTest();
    const { pi, handlers } = fakePi();
    auditCapture();
    try {
      _setRepoForTest("test-repo");
      await withEnv(GATE_ENV, async () => {
        sequenceEnforcer(pi as any);
        _pushSkillForTest("/repo/skills/check/SKILL.md", checkpointSkillSteps(), 0);
        writeForceFile(v.obj);
        writeToken(new Date().toISOString(), { phase: "plan" }); // REAL token drives the advance
        await handlers.tool_call!({ toolName: "read", toolCallId: "fv1", input: { path: "x" } });
        equal(_stackForTest()[0]!.stepIndex, 1, `${v.label}: advanced via the real token`);
        ok(existsSync(forceFilePath()), `${v.label}: non-passable force file survives the advance (never consumed — it could not pass this checkpoint)`);
        ok(!auditEntries.some((x) => x.event === "checkpoint_force_pass"), `${v.label}: no false force-pass audit`);
      });
    } finally { auditRelease(); _setForceFileForTest(null); _setTokenFileForTest(null); _setRepoForTest(null); }
  }
  // malformed: cleaned up on the advance, but WITHOUT a force_pass audit (it never passed anything)
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    _setRepoForTest("test-repo");
    await withEnv(GATE_ENV, async () => {
      sequenceEnforcer(pi as any);
      _pushSkillForTest("/repo/skills/check/SKILL.md", checkpointSkillSteps(), 0);
      writeForceFile("{not json");
      writeToken(new Date().toISOString(), { phase: "plan" });
      await handlers.tool_call!({ toolName: "read", toolCallId: "fv2", input: { path: "x" } });
      equal(_stackForTest()[0]!.stepIndex, 1, "malformed: advanced via the real token");
      ok(!existsSync(forceFilePath()), "malformed: file cleaned up on the advance (never passable — no trap left)");
      ok(!auditEntries.some((x) => x.event === "checkpoint_force_pass"), "malformed: no force-pass audit (it never passed anything)");
    });
  } finally { auditRelease(); _setForceFileForTest(null); _setTokenFileForTest(null); _setRepoForTest(null); }
});


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

// ── #357 Task 4: argv-aware print default (bare-shell `pi -p`) ──
section("resolveMode — argv-aware print default (#357 Task 4)");

await test("bare-shell `pi -p` (argv flag, NO PI_MODE env) → warn (the #201 carve-out reversal)", () => {
  equal(resolveMode({}, "/nonexistent/mode-file", ["pi", "-p", "task"]), "warn");
});

await test("argv --print long flag → warn", () => {
  equal(resolveMode({}, "/nonexistent/mode-file", ["pi", "--print"]), "warn");
});

await test("no print flag in argv + no PI_MODE → gate (interactive unchanged)", () => {
  equal(resolveMode({}, "/nonexistent/mode-file", ["pi"]), "gate");
});

await test("PI_MODE=print env wins even without argv flag → warn", () => {
  equal(resolveMode({ PI_MODE: "print" }, "/nonexistent/mode-file", ["pi"]), "warn");
});

await test("explicit env override beats argv print flag → gate/strict wins", () => {
  equal(resolveMode({ AGENT_SEQUENCE_MODE: "gate" }, "/nonexistent/mode-file", ["pi", "-p"]), "gate");
  equal(resolveMode({ ELDATO_SEQUENCE_MODE: "strict" }, "/nonexistent/mode-file", ["pi", "-p"]), "strict");
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

await test("gate mode + non-allowed tool at verifier → blocked, EXACTLY ONE handler-side audit (allowed+hint)", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv(
      { PI_MODE: "print", AGENT_SEQUENCE_MODE: "gate", AGENT_STATE_MACHINE: undefined, ELDATO_STATE_MACHINE: undefined },
      async () => {
        sequenceEnforcer(pi as any);
        _pushSkillForTest("/repo/skills/review/SKILL.md", verifierSkillSteps(), 1);
        const res = await handlers.tool_call!({ toolName: "bash", input: { command: "rm -rf /" } });
        ok(res && res.block, "handler blocked the call");
        const blocked = auditEntries.filter((x) => x.event === "blocked");
        equal(blocked.length, 1, "EXACTLY ONE blocked entry (single-audit #357 Task 5)");
        ok(typeof blocked[0]!.reason === "string" && (blocked[0]!.reason as string).includes("blocks this operation"), "reason preserved");
        ok(Array.isArray(blocked[0]!.allowed) && (blocked[0]!.allowed as string[]).includes("task"), "allowed list present");
        ok(typeof blocked[0]!.hint === "string" && (blocked[0]!.hint as string).includes("dispatch a task sub-agent"), "hint present");
        equal(blocked[0]!.step, "review");
        ok(!auditEntries.some((x) => x.event === "allowed"), "no separate allowed entry for a blocked call");
      },
    );
  } finally { auditRelease(); }
});

await test("gate mode + allowed tool at verifier → pure contract: not blocked", () => {
  const r = validateToolCall("task", "", makeStep({ gate: "verifier" }), "gate");
  ok(!r.block);
});

await test("strict mode + non-allowed tool → pure contract: blocked, no audit from validateToolCall", () => {
  const r = validateToolCall("bash", "", makeStep({ gate: "verifier" }), "strict");
  ok(r.block);
  ok((r.reason || "").includes("strict"), "strict reason present");
});

await test("warn mode + would-block call → EXACTLY ONE warn_blocked (no allowed), never blocks", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv(
      { PI_MODE: "print", AGENT_SEQUENCE_MODE: "warn", AGENT_STATE_MACHINE: undefined, ELDATO_STATE_MACHINE: undefined },
      async () => {
        sequenceEnforcer(pi as any);
        _pushSkillForTest("/repo/skills/review/SKILL.md", verifierSkillSteps(), 1);
        const res = await handlers.tool_call!({ toolName: "bash", input: { command: "git commit -m x" } });
        ok(!res, "warn never blocks");
        const wb = auditEntries.filter((x) => x.event === "warn_blocked");
        equal(wb.length, 1, "EXACTLY ONE warn_blocked entry (would-block single-entry #357 Task 5)");
        deepEqual(wb[0]!.allowed, ["task", "subagent", "read", "loop_enforcer"]);
        ok((wb[0]!.hint as string).includes("dispatch a task sub-agent"));
        equal(wb[0]!.step, "review");
        ok(!auditEntries.some((x) => x.event === "allowed"), "no allowed entry for a would-block call");
      },
    );
  } finally { auditRelease(); }
});

await test("warn mode + allowed call → pure contract: not blocked, not would-block", () => {
  const r = validateToolCall("task", "", makeStep({ gate: "verifier" }), "warn");
  ok(!r.block, "not blocked");
  ok(!r.wouldBlock, "not would-block (allowed tool)");
});

await test("warn mode + destructive call at auto step → pure contract: not would-block (auto allows)", () => {
  const r = validateToolCall("bash", "rm -rf /tmp/x", makeStep({ gate: "auto" }), "warn");
  ok(!r.block);
  ok(!r.wouldBlock, "auto gate would not block under gate mode");
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

await test("warn mode: sequence timer does NOT park a backdated checkpoint owner (park is gate/strict-only; re-arm persists)", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv(
      { PI_MODE: "print", AGENT_SEQUENCE_MODE: "warn", AGENT_STATE_MACHINE: undefined, ELDATO_STATE_MACHINE: undefined },
      async () => {
        sequenceEnforcer(pi as any);
        _pushSkillForTest("/repo/skills/check/SKILL.md", checkpointSkillSteps(), 0);
        backdateCheckpoint(6); // stall > 5 min
        const before = timerCbs.length;
        handleSequenceTimeout(process.env, ["-p"]);
        ok(!auditEntries.some((x) => x.event === "checkpoint_block_recovery"), "warn mode: no park — recovery-signal noise in a success path (warn auto-advances)");
        equal(timerCbs.length, before + 1, "timer re-armed");
      },
    );
  } finally { auditRelease(); _setTokenFileForTest(null); }
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

// ── #229 review P2-4: checkpoint warn branch + override-park + empty-stack ──
section("review-229: checkpoint warn, gate-override park, empty-stack no-op");

await test("verifier step under warn emits warn_blocked with mode (was mislabeled 'checkpoint step' — it exercises verifierSkillSteps at stepIndex 1)", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv(
      { PI_MODE: "print", PI_ENFORCER_MODE: "warn", AGENT_STATE_MACHINE: undefined, ELDATO_STATE_MACHINE: undefined },
      async () => {
        sequenceEnforcer(pi as any);
        _pushSkillForTest("/repo/skills/check/SKILL.md", verifierSkillSteps(), 1);
        await handlers.tool_call!({ toolName: "bash" });
        ok(auditEntries.some((x) => x.event === "warn_blocked" && x.mode === "warn"),
          "warn_blocked audited with mode:warn");
      },
    );
  } finally { auditRelease(); }
});

await test("print + explicit gate override: timeout still parks, never pops", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv(
      { PI_MODE: "print", AGENT_SEQUENCE_MODE: "gate", AGENT_STATE_MACHINE: undefined, ELDATO_STATE_MACHINE: undefined },
      async () => {
        sequenceEnforcer(pi as any);
        _pushSkillForTest("/repo/skills/demo/SKILL.md", verifierSkillSteps(), 1);
        const before = timerCbs.length;
        await handlers.tool_call!({ toolName: "read" });
        equal(timerCbs.length, before + 1, "gate-override print still arms the timer");
        timerCbs[timerCbs.length - 1]!();
        const stack = _stackForTest();
        equal(stack.length, 1, "print+gate override parks, not pops");
        ok(auditEntries.some((x) => x.event === "timeout_park" && x.mode === "gate"),
          "timeout_park audited with mode:gate");
      },
    );
  } finally { auditRelease(); }
});

await test("empty-stack timeout fires harmlessly", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv(
      { PI_MODE: "print", AGENT_SEQUENCE_MODE: undefined, AGENT_STATE_MACHINE: undefined, ELDATO_STATE_MACHINE: undefined },
      async () => {
        sequenceEnforcer(pi as any);
        const before = timerCbs.length;
        await handlers.tool_call!({ toolName: "read" });
        equal(timerCbs.length, before, "no timer armed with empty stack (no active skill)");
        ok(true, "empty-stack tool_call completed without throwing");
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
