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
  sanitizeRemoteUrl,
  scopedTokenFilePath,
  loadSteps,
  CHECKPOINT_WHITESPACE_REJECT,
  _setTokenFileForTest,
  _setForceFileForTest,
  _setRepoForTest,
  _setAuditSinkForTest,
  _setAuditSessionIdForTest,
  _auditSessionIdForTest,
  _setBridgeDirForTest,
  _pushSkillForTest,
  _stackForTest,
  _resetStateForTest,
  _markerCountForTest,
  readEnforcementLog,
  enforcementLogFile,
  type EnforcementLogEntry,
  default as sequenceEnforcer,
  type Step,
} from "./index.js";
import { ok, equal, deepEqual } from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync, readFileSync, existsSync, chmodSync } from "node:fs";
import { tmpdir, homedir } from "node:os";
import { join, resolve } from "node:path";
import { execSync, execFileSync } from "node:child_process";

// #383 (Task 3): the repo root the suite runs from — used for the escape-matrix
// absolute-path positives and the AGENT_INFRA_PATH guidance fixtures (resolved
// at module load, before any test chdirs).
const REPO_ROOT = resolve(".");

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

// captured console.warn — the session_start argv-warn note is a console.warn
// (distinct from the captureStart console.log sink above).
let warns: string[] = [];
const origWarn = console.warn;
function warnCaptureStart() { warns = []; console.warn = (line: string) => { warns.push(String(line)); }; }
function warnCaptureStop() { console.warn = origWarn; }

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

// argv save/restore helper — the session_start argv-warn note and resolveMode()
// run with DEFAULT args (real process.argv), so the bare-shell `pi -p`
// scenario is simulated by mutating process.argv for the duration of fn.
async function withArgv(argv: string[], fn: () => void | Promise<void>) {
  const saved = process.argv;
  process.argv = argv;
  try { await fn(); }
  finally { process.argv = saved; }
}

// mode-file harness (#380 review P3): session_start reads the REAL MODE_FILE
// (/tmp/agent-sequence-mode) with default resolveMode() args — there is no
// test seam for it (deliberate: the file is the documented Change-Mode
// mechanism, not a test hook). The harness saves the file's current content,
// writes/deletes the scenario state, runs fn, then restores the original
// content (or removes the file if it was absent) in a finally. The mode file
// is routinely written by agents anyway; restore-in-finally keeps this safe.
const MODE_FILE_REAL = "/tmp/agent-sequence-mode";
async function withModeFile(content: string | null, fn: () => void | Promise<void>) {
  const had = existsSync(MODE_FILE_REAL);
  const saved = had ? readFileSync(MODE_FILE_REAL, "utf-8") : null;
  try {
    if (content === null) {
      try { rmSync(MODE_FILE_REAL); } catch { /* already absent */ }
    } else {
      writeFileSync(MODE_FILE_REAL, content, "utf-8");
    }
    await fn();
  } finally {
    try {
      if (had) writeFileSync(MODE_FILE_REAL, saved!, "utf-8");
      else { try { rmSync(MODE_FILE_REAL); } catch { /* already absent */ } }
    } catch { /* best-effort restore */ }
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

// #383 (Task 3): the token payload now carries a repo field by default (the
// checker's URL-form contract — `_apply_token` writes mode + repo); T-tests
// override it via ...extra and bind the enforcer side via
// _setRepoForTest(TEST_REPO) in the affected sections.
const TEST_REPO = "https://github.com/org/repo.git";
const OTHER_REPO = "https://github.com/other/repo.git";
function writeTokenPath(ts: unknown, extra: Record<string, unknown> = {}): string {
  const d = tmpDir("tok");
  const p = join(d, "token.json");
  writeFileSync(p, JSON.stringify({ verdict: "CLEAR", phase: "implement", ts, repo: TEST_REPO, ...extra }));
  _setTokenFileForTest(p);
  return p;
}
function writeToken(ts: unknown, extra: Record<string, unknown> = {}): void {
  writeTokenPath(ts, extra);
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

// #383 (Task 3) T16: this was "future-ts skew (now+300s) → ok until the skew
// passes (pinned)" — REVERSED with the tamper rationale: a future-ts token
// never TTL-expires, and in no-board mode where all phases CLEAR, ONE tampered
// token would satisfy every gate in a session. Symmetric with the force-file
// future-ts rejection (index.ts:767).
await test("future-ts real-token (now+300s) → named-reason BLOCK (T16 tamper rationale)", () => {
  try {
    writeToken(new Date(Date.now() + 300_000).toISOString());
    const r = checkpointTokenOk(makeStep({ gate: "checkpoint", token_phase: "implement" }));
    ok(!r.ok, "future ts = named-reason BLOCK (was ok-until-skew-passes)");
    ok(r.reason.includes("future"), "reason names the future-ts rejection");
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

// #383 (Task 3) escape-matrix positives — the two guidance-print forms MUST
// pass the escape regex (Task 4's skills rewrite tells agents to run exactly
// these forms; a false reject would make the printed guidance unexecutable at
// the gate). The env allowlist is GH_TOKEN|CHECKOUT_GUARD_ENFORCE|AGENT_INFRA_PATH
// — PARALLEL_CHECK_BIN is deliberately NOT in it.
await test("ALLOWED (escape-matrix positive): env CHECKOUT_GUARD_ENFORCE=1 <abs>/scripts/parallel_work_check.sh start", () => {
  const step = makeStep({ name: "check", gate: "checkpoint", token_phase: "start" });
  ok(!validateToolCall("bash", `env CHECKOUT_GUARD_ENFORCE=1 ${REPO_ROOT}/scripts/parallel_work_check.sh start`, step, "gate").block);
});

await test("ALLOWED (escape-matrix positive): env AGENT_INFRA_PATH=<abs> <abs>/scripts/parallel_work_check.sh plan", () => {
  ok(!validateToolCall("bash", `env AGENT_INFRA_PATH=${REPO_ROOT} ${REPO_ROOT}/scripts/parallel_work_check.sh plan`, checkpointStep(), "gate").block);
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
    _setRepoForTest(TEST_REPO); // #383 gate-mode binding: the fresh token must bind to TEST_REPO
    writeToken(new Date().toISOString(), { phase: "plan" });
    const r = validateToolCall("bash", "parallel_work_check.sh plan", checkpointStep(), "gate");
    ok(r.block, "checker re-run blocked at ok-checkpoint");
    ok((r.reason || "").includes("do NOT re-run"), "token_fresh guidance present");
  } finally { _setTokenFileForTest(null); _setRepoForTest(null); }
});

await test("read/loop_enforcer still allowed at an ok-checkpoint", () => {
  try {
    _setRepoForTest(TEST_REPO); // #383 gate-mode binding: the fresh token must bind to TEST_REPO
    writeToken(new Date().toISOString(), { phase: "plan" });
    ok(!validateToolCall("read", "", checkpointStep(), "gate").block);
    ok(!validateToolCall("loop_enforcer", "", checkpointStep(), "gate").block);
  } finally { _setTokenFileForTest(null); _setRepoForTest(null); }
});

await test("non-checker tool at a fresh-ok checkpoint → allowed (friction fix: the step already advanced; the next step validates)", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv({ PI_MODE: "print", AGENT_SEQUENCE_MODE: "gate", AGENT_STATE_MACHINE: undefined, ELDATO_STATE_MACHINE: undefined }, async () => {
      sequenceEnforcer(pi as any);
      _pushSkillForTest("/repo/skills/check/SKILL.md", checkpointSkillSteps(), 0);
      _setRepoForTest(TEST_REPO); // #383 gate-mode binding: fresh token must bind to TEST_REPO
      writeToken(new Date().toISOString(), { phase: "plan" });
      const res = await handlers.tool_call!({ toolName: "write", toolCallId: "w1", input: { path: "x", content: "y" } });
      ok(!res || !res.block, "write allowed at fresh-ok checkpoint (blocked-call rule already advanced)");
      equal(_stackForTest()[0]!.stepIndex, 1, "advance happened");
      ok(!auditEntries.some((x) => x.event === "blocked"), "no spurious blocked audit in the success path");
    });
  } finally { auditRelease(); _setTokenFileForTest(null); _setRepoForTest(null); }
});

await test("handler: checker re-run at a fresh-ok checkpoint → audit event checkpoint_token_fresh (the documented 4-event set)", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv({ PI_MODE: "print", AGENT_SEQUENCE_MODE: "gate", AGENT_STATE_MACHINE: undefined, ELDATO_STATE_MACHINE: undefined }, async () => {
      sequenceEnforcer(pi as any);
      _pushSkillForTest("/repo/skills/check/SKILL.md", checkpointSkillSteps(), 0);
      _setRepoForTest(TEST_REPO); // #383 gate-mode binding: fresh token must bind to TEST_REPO
      writeToken(new Date().toISOString(), { phase: "plan" });
      const res = await handlers.tool_call!({ toolName: "bash", toolCallId: "tf1", input: { command: "parallel_work_check.sh plan" } });
      ok(res && res.block, "checker re-run blocked at fresh-ok checkpoint");
      equal(_stackForTest()[0]!.stepIndex, 1, "advance still happened (blocked-call rule)");
      const fresh = auditEntries.filter((x) => x.event === "checkpoint_token_fresh");
      equal(fresh.length, 1, "distinct checkpoint_token_fresh event emitted");
      ok(!auditEntries.some((x) => x.event === "blocked" && x.tool === "bash"), "not logged as generic blocked");
      ok((fresh[0]!.reason as string).includes("do NOT re-run"), "reason carries the token_fresh guidance");
    });
  } finally { auditRelease(); _setTokenFileForTest(null); _setRepoForTest(null); }
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
      _setRepoForTest(TEST_REPO); // #383 gate-mode binding: fresh token must bind to TEST_REPO
      writeToken(new Date().toISOString(), { phase: "plan" });
      const res = await handlers.tool_call!({ toolName: "read", toolCallId: "c1", input: { path: "x" } });
      ok(!res || !res.block, "read allowed at ok-checkpoint");
      equal(_stackForTest()[0]!.stepIndex, 1, "advanced to implement step");
      await handlers.tool_result!({ toolName: "read", toolCallId: "c1" });
      equal(_stackForTest()[0]!.stepIndex, 1, "no double-advance via tool_result (ok marker suppression)");
    });
  } finally { auditRelease(); _setTokenFileForTest(null); _setRepoForTest(null); }
});

await test("producer-timing: escape tool_call allowed (no advance); token written; tool_result advances on ok-now", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv(GATE_ENV, async () => {
      sequenceEnforcer(pi as any);
      _pushSkillForTest("/repo/skills/check/SKILL.md", checkpointSkillSteps(), 0);
      _setRepoForTest(TEST_REPO); // #383 gate-mode binding: fresh token must bind to TEST_REPO
      const res = await handlers.tool_call!({ toolName: "bash", toolCallId: "e1", input: { command: "parallel_work_check.sh plan" } });
      ok(!res || !res.block, "escape allowed");
      equal(_stackForTest()[0]!.stepIndex, 0, "no advance at tool_call (token not ok yet)");
      writeToken(new Date().toISOString(), { phase: "plan" }); // checker completes, writes token
      await handlers.tool_result!({ toolName: "bash", toolCallId: "e1" });
      equal(_stackForTest()[0]!.stepIndex, 1, "advanced on !ok@call → ok@result transition");
    });
  } finally { auditRelease(); _setTokenFileForTest(null); _setRepoForTest(null); }
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
      _setRepoForTest(TEST_REPO); // #383 gate-mode binding: fresh token must bind to TEST_REPO
      writeToken(new Date().toISOString(), { phase: "plan" });
      await handlers.tool_call!({ toolName: "read", toolCallId: "a", input: { path: "x" } });
      equal(_stackForTest()[0]!.stepIndex, 1, "call A advanced check1 → check2");
      await handlers.tool_result!({ toolName: "read", toolCallId: "a" });
      equal(_stackForTest()[0]!.stepIndex, 1, "call A's tool_result did NOT advance check2");
      await handlers.tool_call!({ toolName: "read", toolCallId: "b", input: { path: "x" } });
      equal(_stackForTest()[0]!.stepIndex, 2, "call B advanced check2 → impl");
    });
  } finally { auditRelease(); _setTokenFileForTest(null); _setRepoForTest(null); }
});

await test("completion-order reversal: two sibling escape calls, token written → exactly ONE advance", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv(GATE_ENV, async () => {
      sequenceEnforcer(pi as any);
      _pushSkillForTest("/repo/skills/check/SKILL.md", checkpointSkillSteps(), 0);
      _setRepoForTest(TEST_REPO); // #383 gate-mode binding: fresh token must bind to TEST_REPO
      await handlers.tool_call!({ toolName: "bash", toolCallId: "e1", input: { command: "parallel_work_check.sh plan" } });
      await handlers.tool_call!({ toolName: "bash", toolCallId: "e2", input: { command: "parallel_work_check.sh plan" } });
      equal(_stackForTest()[0]!.stepIndex, 0, "both allowed, no advance yet");
      writeToken(new Date().toISOString(), { phase: "plan" });
      await handlers.tool_result!({ toolName: "bash", toolCallId: "e2" }); // e2 completes FIRST
      equal(_stackForTest()[0]!.stepIndex, 1, "e2 advanced (marker current)");
      await handlers.tool_result!({ toolName: "bash", toolCallId: "e1" }); // e1 late
      equal(_stackForTest()[0]!.stepIndex, 1, "e1 stale marker rejected — no second advance");
    });
  } finally { auditRelease(); _setTokenFileForTest(null); _setRepoForTest(null); }
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
      _setRepoForTest(TEST_REPO); // #383 gate-mode binding: fresh token must bind to TEST_REPO
      writeToken(new Date().toISOString(), { phase: "plan" });
      const a = await handlers.tool_call!({ toolName: "read", toolCallId: "a", input: { path: "x" } });
      ok(!a || !a.block, "A allowed at ok-checkpoint");
      equal(_stackForTest()[0]!.stepIndex, 1, "A advanced to the verifier step");
      const b = await handlers.tool_call!({ toolName: "bash", toolCallId: "b", input: { command: "rm -rf /" } });
      ok(b && b.block, "B blocked by the NEXT (verifier) step — not re-validated against the checkpoint");
      ok((b.reason as string).includes("verifier"), "B's reason is the verifier gate");
    });
  } finally { auditRelease(); _setTokenFileForTest(null); _setRepoForTest(null); }
});

await test("concurrent cross-phase escape race: wrong-phase sibling blocked, exactly one advance, no strand", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv(GATE_ENV, async () => {
      sequenceEnforcer(pi as any);
      _pushSkillForTest("/repo/skills/check/SKILL.md", checkpointSkillSteps(), 0);
      _setRepoForTest(TEST_REPO); // #383 gate-mode binding: fresh token must bind to TEST_REPO
      const right = await handlers.tool_call!({ toolName: "bash", toolCallId: "r", input: { command: "parallel_work_check.sh plan" } });
      ok(!right || !right.block, "right-phase escape allowed");
      const wrong = await handlers.tool_call!({ toolName: "bash", toolCallId: "w", input: { command: "parallel_work_check.sh implement" } });
      ok(wrong && wrong.block, "wrong-phase sibling blocked (never writes a never-satisfying token)");
      writeToken(new Date().toISOString(), { phase: "plan" });
      await handlers.tool_result!({ toolName: "bash", toolCallId: "r" });
      equal(_stackForTest()[0]!.stepIndex, 1, "right-phase advance — no strand");
    });
  } finally { auditRelease(); _setTokenFileForTest(null); _setRepoForTest(null); }
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
      _setRepoForTest(TEST_REPO); // #383 gate-mode binding: fresh token must bind to TEST_REPO
      const res = await handlers.tool_call!({ toolName: "bash", toolCallId: "s1", input: { command: "parallel_work_check.sh plan" } });
      ok(!res || !res.block, "escape allowed (owner found via stack-walk)");
      writeToken(new Date().toISOString(), { phase: "plan" });
      await handlers.tool_result!({ toolName: "bash", toolCallId: "s1" });
      const stack = _stackForTest();
      equal(stack[0]!.stepIndex, 1, "PARENT (owner) advanced");
      equal(stack[1]!.stepIndex, 0, "sub-skill untouched");
    });
  } finally { auditRelease(); _setTokenFileForTest(null); _setRepoForTest(null); }
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
      _setRepoForTest(TEST_REPO); // #383 gate-mode binding: fresh token must bind to TEST_REPO
      writeToken(new Date().toISOString(), { phase: "plan" });
      captureStart();
      try {
        await handlers.tool_call!({ toolName: "read", toolCallId: "n1", input: { path: "x" } });
      } finally { captureStop(); }
      ok(logs.some((l) => l.includes("Checkpoint advanced")), "advance logged");
      ok(logs.some((l) => l.includes("🔒 Gate: verifier")), "announceGate fired for the next (verifier) step");
    });
  } finally { auditRelease(); _setTokenFileForTest(null); _setRepoForTest(null); }
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
        // #383 (Task 3) FLIP: the warn-mode consume emits NO force_pass audit —
        // warn auto-advances without HONORING the file, so the operator's file
        // never actually drove the pass (the mode-qualified viaForce criterion).
        equal(pass.length, 0, "warn-mode consume emits NO checkpoint_force_pass (was: audited — flipped)");
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

await test("state 1 (no-ok token): names the CLEAR-able invocation + escape tools + end-your-turn fallback, no placeholders", async () => {
  await withEnv({ AGENT_INFRA_PATH: REPO_ROOT }, () => {
    const g = gateGuidance(checkpointStep()); // token_phase "plan", no token
    ok(g.length > 0, "non-empty");
    ok(g.includes("parallel_work_check.sh plan"), "names the interpolated invocation (resolved bin + phase)");
    ok(g.includes("read") && g.includes("loop_enforcer"), "names the escape tools");
    ok(g.includes("end your turn and report"), "end-your-turn fallback present");
    ok(!g.includes("$"), "no $VAR — the escape regex rejects $");
    ok(!g.includes("<phase>") && !g.includes("<phase") && !g.includes(">"), "no placeholder brackets — < > fail the escape");
  });
});

await test("state 1 conformance: the emitted invocation passes isCheckpointEscape and is the parent/main-checkout form", async () => {
  await withEnv({ AGENT_INFRA_PATH: REPO_ROOT }, () => {
    const g = gateGuidance(checkpointStep());
    const cmd = g.split("run `")[1]!.split("` until")[0]!;
    ok(isCheckpointEscape("bash", cmd), "emitted invocation passes the escape check (criterion 14)");
    ok(!cmd.includes("--repo"), "primary command omits --repo (the DEFER-guaranteed worktree form)");
    ok(!cmd.includes("$") && !cmd.includes("<") && !cmd.includes(">"), "no $VAR / <phase> in the command");
    ok(cmd.startsWith("/"), "absolute path-resolvable form");
  });
});

await test("state 2 (fresh-ok token): 'do NOT re-run the checker, proceed' — no invocation named", () => {
  try {
    _setRepoForTest(TEST_REPO); // #383 gate-mode binding: the fresh token must bind to TEST_REPO
    writeToken(new Date().toISOString(), { phase: "plan" });
    const g = gateGuidance(checkpointStep());
    ok(g.includes("do NOT re-run the checker"), "fresh-token variant");
    ok(!g.includes("parallel_work_check.sh plan"), "no checker instruction that would clobber the token");
  } finally { _setTokenFileForTest(null); _setRepoForTest(null); }
});

await test("state 2 viaForce (P3-4): operator force-pass named, no 'fresh token' premise, no no-board-skip mislabel", () => {
  try {
    _setRepoForTest("test-repo");
    const d = tmpDir("guidance-viaforce");
    const p = join(d, "force.json");
    writeFileSync(p, JSON.stringify({ verdict: "CLEAR", phase: "plan", operator: "daniel", origin: "shell", repo: "test-repo", ts: new Date().toISOString() }));
    _setForceFileForTest(p);
    writeToken(new Date(Date.now() - 11 * 60 * 1000).toISOString(), { phase: "plan", repo: "test-repo", mode: "no-board-skip" }); // STALE no-board token
    const g = gateGuidance(checkpointStep()); // plan checkpoint, gate mode
    ok(g.includes("operator force-pass"), "force-driven pass named as operator force-pass");
    ok(!g.includes("do NOT re-run the checker"), "no stale fresh-token premise on a force-driven pass (a re-run would succeed)");
    ok(!g.includes("no-board-skip token"), "no-board-skip note gated on !viaForce (a force advance never consumed a skip token)");
  } finally { _setForceFileForTest(null); _setTokenFileForTest(null); _setRepoForTest(null); }
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
    await withEnv({ ...GATE_ENV, AGENT_INFRA_PATH: REPO_ROOT }, async () => {
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
  await withEnv({ PARALLEL_CHECK_TOKEN_FILE: p, AGENT_INFRA_PATH: REPO_ROOT }, () => {
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

await test("P3-2 (FINAL senior): credential-bearing force-file repo → sanitized comparison passes; divergent repo still rejected", async () => {
  // Hand-written force file whose repo was copied RAW from `git remote get-url
  // origin` on a token-auth checkout (https://user:pass@host/…) — currentRepo()
  // sanitizes, so the old raw `f.repo === repoNow` mismatched → rejected.
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    _setRepoForTest("https://host/org/repo.git");
    writeForceFile({ ...FORCE_GOOD, repo: "https://user:pass@host/org/repo.git" });
    await withEnv(GATE_ENV, async () => {
      sequenceEnforcer(pi as any);
      _pushSkillForTest("/repo/skills/p32/SKILL.md", checkpointSkillSteps(), 0);
      const res = await handlers.tool_call!({ toolName: "read", toolCallId: "p32a", input: { path: "x" } });
      ok(!res || !res.block, "credential-bearing force repo + sanitized binding → comparison passes");
      equal(_stackForTest()[0]!.stepIndex, 1, "advanced past the checkpoint");
      const pass = auditEntries.filter((x) => x.event === "checkpoint_force_pass");
      equal(pass.length, 1, "checkpoint_force_pass audited");
      equal(pass[0]!.repo, "https://host/org/repo.git", "audit repo field is the SANITIZED form (no credentials leak)");
      ok(!existsSync(forceFilePath()), "force file consumed (one-shot)");
    });
  } finally { auditRelease(); _setForceFileForTest(null); _setRepoForTest(null); }
  // divergent credential-bearing force repo → STILL rejected (binding intact)
  _resetStateForTest();
  try {
    _setRepoForTest("https://host/org/repo.git");
    writeForceFile({ ...FORCE_GOOD, repo: "https://user:pass@other.example/org/repo.git" });
    const r = checkpointTokenOk(makeStep({ gate: "checkpoint", token_phase: "plan" }));
    ok(!r.ok, "divergent credential-bearing force repo still BLOCKs");
    ok(r.reason.includes("exists but is rejected"), "reason names the rejected force file");
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

// ── #380 review (P3, last deliberate gap): the modeFileWarn branch of the
// session_start argv-warn note. When a session resolves warn via argv-detected
// print (bare-shell `pi -p`, no PI_MODE env), the extension logs a console.warn
// telling the session-log reader the verifier-step allow-list is NOT enforced.
// Cycle-3/4 fix: a mode-file "warn" (the documented operator Change-Mode
// mechanism) counts as an EXPLICIT override — the note must NOT fire for a
// deliberate operator file. session_start calls resolveMode() with DEFAULT
// args (reads the REAL MODE_FILE), so these tests drive the file directly via
// withModeFile + withArgv (save/restore in finally; audit captured via sink).
const ARGV_WARN_NOTE = "warn default via argv-detected print";

await test("session_start: mode-file warn suppresses the argv-detected-print console.warn (explicit operator override wins)", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  warnCaptureStart();
  try {
    await withModeFile("warn", async () => {
      await withArgv(["pi", "-p"], async () => {
        await withEnv(
          { AGENT_SEQUENCE_MODE: undefined, ELDATO_SEQUENCE_MODE: undefined, PI_ENFORCER_MODE: undefined, PI_MODE: undefined, AGENT_STATE_MACHINE: undefined, ELDATO_STATE_MACHINE: undefined },
          async () => {
            sequenceEnforcer(pi as any);
            await handlers.session_start!();
            ok(!warns.some((w) => w.includes(ARGV_WARN_NOTE)),
              "mode-file warn is an explicit override — the argv-default misdiagnosis note must NOT fire");
            const startup = auditEntries.find((x) => x.event === "startup");
            ok(startup && startup.mode === "warn", "startup audited as warn (mode file drives the mode)");
          },
        );
      });
    });
  } finally { warnCaptureStop(); auditRelease(); }
});

await test("session_start CONTROL: NO mode file + bare-shell pi -p → the argv-detected-print console.warn DOES fire (non-vacuous)", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  warnCaptureStart();
  try {
    await withModeFile(null, async () => {
      await withArgv(["pi", "-p"], async () => {
        await withEnv(
          { AGENT_SEQUENCE_MODE: undefined, ELDATO_SEQUENCE_MODE: undefined, PI_ENFORCER_MODE: undefined, PI_MODE: undefined, AGENT_STATE_MACHINE: undefined, ELDATO_STATE_MACHINE: undefined },
          async () => {
            sequenceEnforcer(pi as any);
            await handlers.session_start!();
            const fired = warns.filter((w) => w.includes(ARGV_WARN_NOTE));
            equal(fired.length, 1, "no mode file: bare-shell argv -p with no PI_MODE is a warn DEFAULT — the note MUST fire exactly once");
            const startup = auditEntries.find((x) => x.event === "startup");
            ok(startup && startup.mode === "warn", "control also resolves warn (via the argv default)");
          },
        );
      });
    });
  } finally { warnCaptureStop(); auditRelease(); }
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
      writeToken(new Date().toISOString(), { phase: "plan", repo: "test-repo" }); // REAL token ALSO fresh AND repo-bound
      await handlers.tool_call!({ toolName: "read", toolCallId: "rw1", input: { path: "x" } });
      equal(_stackForTest()[0]!.stepIndex, 1, "advanced via the real token");
      ok(!existsSync(forceFilePath()), "force file consumed despite the real-token advance (must never pass a same-phase adjacent checkpoint)");
      const pass = auditEntries.filter((x) => x.event === "checkpoint_force_pass");
      // #383 (Task 3) FLIP: the REAL token drove the advance — the force file
      // was consumed (one-shot invariant) but never HONORED, so no force_pass
      // audit (the viaForce criterion: emit ONLY when the file actually passed).
      equal(pass.length, 0, "real-token-wins consume emits NO checkpoint_force_pass (was: audited — flipped)");
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
      writeToken(new Date().toISOString(), { phase: "plan", repo: "test-repo" }); // real plan token advances check1
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
        writeToken(new Date().toISOString(), { phase: "plan", repo: "test-repo" }); // REAL token drives the advance
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
      writeToken(new Date().toISOString(), { phase: "plan", repo: "test-repo" });
      await handlers.tool_call!({ toolName: "read", toolCallId: "fv2", input: { path: "x" } });
      equal(_stackForTest()[0]!.stepIndex, 1, "malformed: advanced via the real token");
      ok(!existsSync(forceFilePath()), "malformed: file cleaned up on the advance (never passable — no trap left)");
      ok(!auditEntries.some((x) => x.event === "checkpoint_force_pass"), "malformed: no force-pass audit (it never passed anything)");
    });
  } finally { auditRelease(); _setForceFileForTest(null); _setTokenFileForTest(null); _setRepoForTest(null); }
});


// ── #383 Task 3: enforcer repo binding + no-board-skip audit (T1–T16) ──
section("T-series — #383 Task 3: repo binding + no-board-skip audit");

// The frozen old-contract proxy (T10a): a minimal reader that consumes ONLY
// phase/verdict/ts — the additive-contract regression net. New token fields
// (mode, repo, unknown extras) must never break a reader that predates them.
function minimalOldContractReader(tokenPath: string, requiredPhase: string): { ok: boolean } {
  let t: any;
  try { t = JSON.parse(readFileSync(tokenPath, "utf-8")); } catch { return { ok: false }; }
  if (t.verdict !== "CLEAR") return { ok: false };
  const ts = parseTokenTs(t.ts);
  if (ts === null || Date.now() - ts > 600_000 || ts > Date.now()) return { ok: false };
  if (t.phase !== requiredPhase) return { ok: false };
  return { ok: true };
}

// The checker's `_is_no_board` signal set (B23's 14 names — shared constants).
// T11 execs the REAL vendored checker with these cleared so the exec env is a
// genuine no-board tenant.
const NOBOARD_SIGNAL_NAMES = [
  "PARALLEL_CHECK_SB_URL", "SUPABASE_URL_ORG_DATA", "SUPABASE_URL",
  "PARALLEL_CHECK_SB_KEY", "SUPABASE_SERVICE_ROLE_KEY_ORG_DATA", "SUPABASE_SERVICE_ROLE_KEY",
  "SUPABASE_ANON_KEY_ORG_DATA", "SUPABASE_ANON_KEY",
  "SWARM_CARD_ID", "CARD_ID", "AGENT_ID", "SWARM_AGENT_ID",
  "SWARM_TOUCHED_PATHS", "TOUCHED_PATHS",
];

// A real-ish consumer git repo for T11's joint checker→enforcer test: bare
// origin + seeded main (backdated commit so the guard's foreign-activity
// recency check passes deterministically).
function makeNoBoardRepo(dir: string): { seed: string; originUrl: string } {
  const common = join(dir, "bare.git");
  execSync(`git init --bare -q -b main "${common}"`);
  const seed = join(dir, "seed");
  execSync(`git clone -q "${common}" "${seed}"`);
  execSync(`git -C "${seed}" config user.email noboard@test.local`);
  execSync(`git -C "${seed}" config user.name noboard`);
  writeFileSync(join(seed, "f.txt"), "x\n");
  execSync(`git -C "${seed}" add -A`);
  execSync(`git -C "${seed}" commit -q -m seed`, {
    env: { ...process.env, GIT_AUTHOR_DATE: "2020-01-01T00:00:00Z", GIT_COMMITTER_DATE: "2020-01-01T00:00:00Z" },
  });
  execSync(`git -C "${seed}" push -q origin main`);
  const originUrl = execSync(`git -C "${seed}" remote get-url origin`, { encoding: "utf-8" }).trim();
  return { seed, originUrl };
}

// ── #383 (Task 3) P2-1/P3-1: sanitizeRemoteUrl — Python urlsplit parity battery ──
// Mirrors test_b26_credential_userinfo_sanitized in
// scripts/test_parallel_work_check.py (urlsplit: ANY userinfo stripped via
// rsplit("@",1); scp-form/plain https byte-identical; unbalanced-bracket
// netloc → urlsplit ValueError → "unknown"; scheme LOWERCASED on rebuild).
section("sanitizeRemoteUrl — Python urlsplit parity (P2-1/P3-1)");

await test("P2-1: uppercase-scheme credential URL → scheme LOWERCASED + userinfo stripped (urlsplit parity)", () => {
  equal(sanitizeRemoteUrl("HTTPS://TOKEN@github.com/org/repo.git"), "https://github.com/org/repo.git");
});

await test("P2-1: bare-PAT userinfo (no colon — the P2 gap) → stripped", () => {
  equal(sanitizeRemoteUrl("https://ghp_FAKETOKEN@github.com/daniel-ospina/consumer.git"), "https://github.com/daniel-ospina/consumer.git");
});

await test("P2-1: user:pass@ userinfo → stripped, URL form preserved", () => {
  equal(sanitizeRemoteUrl("https://x-access-token:ghp_FAKETOKEN@github.com/daniel-ospina/consumer.git"), "https://github.com/daniel-ospina/consumer.git");
});

await test("P2-1: ssh://git@ → userinfo stripped to host:port", () => {
  equal(sanitizeRemoteUrl("ssh://git@github.com/daniel-ospina/consumer.git"), "ssh://github.com/daniel-ospina/consumer.git");
});

await test("P2-1: scp-form (no scheme) → byte-identical (the normal ssh remote)", () => {
  equal(sanitizeRemoteUrl("git@github.com:daniel-ospina/consumer.git"), "git@github.com:daniel-ospina/consumer.git");
});

await test("P2-1: plain https (no userinfo) → untouched (case preserved like Python's raw return)", () => {
  equal(sanitizeRemoteUrl("https://github.com/daniel-ospina/consumer.git"), "https://github.com/daniel-ospina/consumer.git");
});

await test("P2-1: IPv6 + port preserved through the userinfo strip", () => {
  equal(sanitizeRemoteUrl("https://user@[::1]:8443/org/repo.git"), "https://[::1]:8443/org/repo.git");
});

await test("P3-1: unbalanced-bracket netloc → 'unknown' (urlsplit ValueError parity), with and without userinfo", () => {
  equal(sanitizeRemoteUrl("https://user@[::1/org/repo.git"), "unknown");
  equal(sanitizeRemoteUrl("https://[::1/org/repo.git"), "unknown");
  equal(sanitizeRemoteUrl("https://user@host]/org/repo.git"), "unknown");
});

await test("P3-1 (FINAL senior): balanced-but-invalid bracketed host → 'unknown' (Python 3.12 urlsplit ValueError parity)", () => {
  // https://[notanip]/org/repo.git → Python ValueError ("does not appear to be
  // an IPv4 or IPv6 address") → checker writes "unknown"; the old XOR check
  // passed the mangled netloc through verbatim → spurious cross-repo BLOCK.
  equal(sanitizeRemoteUrl("https://[notanip]/org/repo.git"), "unknown");
  // bracketed IPv4 → Python "An IPv4 address cannot be in brackets" → unknown
  equal(sanitizeRemoteUrl("https://[127.0.0.1]:8080/org/repo.git"), "unknown");
  // bare hex (no colon) / empty brackets → Python ipaddress ValueError → unknown
  equal(sanitizeRemoteUrl("https://[deadbeef]/org/repo.git"), "unknown");
  equal(sanitizeRemoteUrl("https://[]/org/repo.git"), "unknown");
  // real IPv6 forms stay PRESERVED (the battery's https://[::1]:8080 case
  // stays — kept above at P2-1 — and the IPv4-mapped form too)
  equal(sanitizeRemoteUrl("https://[2001:db8::1]/org/repo.git"), "https://[2001:db8::1]/org/repo.git");
  equal(sanitizeRemoteUrl("https://[::ffff:192.0.2.1]/org/repo.git"), "https://[::ffff:192.0.2.1]/org/repo.git");
  equal(sanitizeRemoteUrl("https://[ABCD::EF01]/org/repo.git"), "https://[ABCD::EF01]/org/repo.git");
});

await test("P3-1 (FINAL mechanical): loose-regex survivors Python urlsplit rejects → 'unknown' (net.isIP === 6 mirror)", () => {
  // The old character-class regex (/^[0-9a-fA-F:.]+$/ + ≥1 colon) PRESERVED
  // all of these; Python 3.12 urlsplit raises ValueError (checker writes
  // "unknown") while the enforcer bound the raw URL → spurious cross-repo
  // BLOCK. Node net.isIP returns 0 for every shape → "unknown", matching.
  equal(sanitizeRemoteUrl("https://[:1]/o.git"), "unknown");
  equal(sanitizeRemoteUrl("https://[1:2]/o.git"), "unknown");
  equal(sanitizeRemoteUrl("https://[::::]/o.git"), "unknown");
  equal(sanitizeRemoteUrl("https://[1:2:3:4:5:6:7:8:9]/o.git"), "unknown");
  equal(sanitizeRemoteUrl("https://[12345::1]/o.git"), "unknown");
  equal(sanitizeRemoteUrl("https://[a:b]/o.git"), "unknown");
});

await test("P3-1 (FINAL mechanical): zone-ID bracketed host → PRESERVED (Node ≥22 isIP accepts zone-IDs, matching Python 3.12)", () => {
  // Verified parity on the pi runtime: Python 3.12.13 urlsplit preserves
  // [fe80::1%eth0] AND Node v22.23.2 net.isIP("fe80::1%eth0") === 6 — the
  // isIP mirror is COMPLETE here (the pre-22 Node behavior — isIP 0 for
  // zone-IDs — would fail CLOSED to "unknown", a spurious BLOCK, never a
  // silent pass). This test pins the v22 behavior so a Node downgrade is
  // caught by the suite instead of silently diverging.
  equal(sanitizeRemoteUrl("https://[fe80::1%eth0]/o.git"), "https://[fe80::1%eth0]/o.git");
});

// T1 — core binding matrix: match / mismatch / both-unknown / unknown-vs-remote
await test("T1: token repo match → ok; mismatch → named BLOCK (gate binding)", () => {
  try {
    _setRepoForTest(TEST_REPO);
    writeToken(new Date().toISOString(), { phase: "plan", repo: TEST_REPO });
    ok(checkpointTokenOk(checkpointStep(), { enforceBinding: true }).ok, "matching repo binds");
    _setTokenFileForTest(null);
    writeToken(new Date().toISOString(), { phase: "plan", repo: OTHER_REPO });
    const bad = checkpointTokenOk(checkpointStep(), { enforceBinding: true });
    ok(!bad.ok, "repo mismatch BLOCKs");
    ok(bad.reason.includes("repo") && bad.reason.includes("does not match"), "named-reason repo mismatch");
  } finally { _setTokenFileForTest(null); _setRepoForTest(null); }
});

await test("T1: both-'unknown' → pass (no-remote parity); unknown-vs-remote → BLOCK", () => {
  try {
    _setRepoForTest("unknown");
    writeToken(new Date().toISOString(), { phase: "plan", repo: "unknown" });
    ok(checkpointTokenOk(checkpointStep(), { enforceBinding: true }).ok, "both-unknown binds (no-remote parity)");
    _setTokenFileForTest(null);
    writeToken(new Date().toISOString(), { phase: "plan", repo: TEST_REPO });
    ok(!checkpointTokenOk(checkpointStep(), { enforceBinding: true }).ok, "token remote vs binding unknown → BLOCK");
  } finally { _setTokenFileForTest(null); _setRepoForTest(null); }
});

await test("T1: binding-free without opts — direct-call default unchanged (existing callers)", () => {
  try {
    writeToken(new Date().toISOString(), { phase: "plan" });
    ok(checkpointTokenOk(checkpointStep()).ok, "no opts → binding-free");
  } finally { _setTokenFileForTest(null); }
});

await test("T1: legacy repo-less token under enforced binding → named BLOCK (deploy-window reverse edge)", () => {
  try {
    _setRepoForTest(TEST_REPO);
    writeToken(new Date().toISOString(), { phase: "plan", repo: undefined as any }); // no repo field (pre-#383 reader)
    const r = checkpointTokenOk(checkpointStep(), { enforceBinding: true });
    ok(!r.ok, "repo-less legacy token BLOCKs under binding");
    ok(r.reason.includes("repo"), "named repo reason — remedy: re-run the checker once");
  } finally { _setTokenFileForTest(null); _setRepoForTest(null); }
});

await test("T1: legacy fixture — pre-#383 abspath-form repo (repo_path) BLOCKs vs URL-form binding", () => {
  try {
    _setRepoForTest(TEST_REPO);
    writeToken(new Date().toISOString(), { phase: "plan", repo: "/Users/danielospina/swarm" }); // old _apply_token wrote the abspath
    const r = checkpointTokenOk(checkpointStep(), { enforceBinding: true });
    ok(!r.ok, "abspath-form token BLOCKs vs URL-form binding");
    ok(r.reason.includes("repo"), "named repo reason");
  } finally { _setTokenFileForTest(null); _setRepoForTest(null); }
});

await test("T1: mode tolerance — a mode:'no-board-skip' token binds like a board token; mode surfaced on the result", () => {
  try {
    _setRepoForTest(TEST_REPO);
    writeToken(new Date().toISOString(), { phase: "plan", repo: TEST_REPO, mode: "no-board-skip" });
    const r = checkpointTokenOk(checkpointStep(), { enforceBinding: true });
    ok(r.ok, "skip-mode token binds");
    equal(r.mode, "no-board-skip", "token mode surfaced on the result");
  } finally { _setTokenFileForTest(null); _setRepoForTest(null); }
});

await test("P3-3 (FINAL senior): binding-fail reason echoes the SANITIZED token repo (no credential leak; repo still named)", () => {
  try {
    _setRepoForTest(OTHER_REPO);
    // tampered credential-bearing token (the checker sanitizes token.repo, so
    // this needs a tampered token — ~nil exposure, but the reason must not
    // interpolate raw credentials; the skip-audit's repo is already sanitized)
    writeToken(new Date().toISOString(), { phase: "plan", repo: "https://user:pass@github.com/org/repo.git" });
    const r = checkpointTokenOk(checkpointStep(), { enforceBinding: true });
    ok(!r.ok, "divergent credential-bearing token BLOCKs (host differs from the binding)");
    ok(r.reason.includes('token repo "https://github.com/org/repo.git"'), "reason names the SANITIZED repo (userinfo stripped, host survives)");
    ok(!r.reason.includes("user:pass"), "credentials never leak into the reason / console output");
    ok(r.reason.includes("does not match"), "named-repo mismatch retained");
  } finally { _setTokenFileForTest(null); _setRepoForTest(null); }
});

// T2 — skip audit at the real-token advance site (T6(d) field contract merged)
await test("T2: skip-mode token advance (real-token site) → exactly ONE checkpoint_no_board_skip with mode-domain fields", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    _setRepoForTest(TEST_REPO);
    await withEnv(GATE_ENV, async () => {
      sequenceEnforcer(pi as any);
      _pushSkillForTest("/repo/skills/t2/SKILL.md", checkpointSkillSteps(), 0);
      writeToken(new Date().toISOString(), { phase: "plan", repo: TEST_REPO, mode: "no-board-skip" });
      await handlers.tool_call!({ toolName: "read", toolCallId: "t2", input: { path: "x" } });
      equal(_stackForTest()[0]!.stepIndex, 1, "advanced");
      const skip = auditEntries.filter((x) => x.event === "checkpoint_no_board_skip");
      equal(skip.length, 1, "exactly ONE skip audit");
      const e = skip[0]!;
      equal(e.token_mode, "no-board-skip", "token_mode field (mode domain — distinct from enforcer mode)");
      equal(e.mode, "gate", "enforcer mode field");
      equal(e.phase, "plan", "phase field (Task 4 tripwire data contract)");
      equal(e.repo, TEST_REPO, "repo field (Task 4 tripwire data contract)");
      equal(e.step, "check", "step named");
    });
  } finally { auditRelease(); _setTokenFileForTest(null); _setRepoForTest(null); }
});

// T3 — skip audit at the tool_result-marker advance (T6(e))
await test("T3: skip audit fires on the tool_result-marker advance (canonical no-board flow)", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    _setRepoForTest(TEST_REPO);
    await withEnv(GATE_ENV, async () => {
      sequenceEnforcer(pi as any);
      _pushSkillForTest("/repo/skills/t3/SKILL.md", checkpointSkillSteps(), 0);
      const res = await handlers.tool_call!({ toolName: "bash", toolCallId: "t3", input: { command: "parallel_work_check.sh plan" } });
      ok(!res || !res.block, "escape allowed");
      equal(_stackForTest()[0]!.stepIndex, 0, "no advance at tool_call (pending)");
      writeToken(new Date().toISOString(), { phase: "plan", repo: TEST_REPO, mode: "no-board-skip" }); // checker produced the token
      await handlers.tool_result!({ toolName: "bash", toolCallId: "t3" });
      equal(_stackForTest()[0]!.stepIndex, 1, "marker advanced");
      const skip = auditEntries.filter((x) => x.event === "checkpoint_no_board_skip");
      equal(skip.length, 1, "skip audit on the marker advance");
      equal(skip[0]!.token_mode, "no-board-skip", "token_mode field");
      equal(skip[0]!.phase, "plan", "phase field");
    });
  } finally { auditRelease(); _setTokenFileForTest(null); _setRepoForTest(null); }
});

// T4 — negative audits: (a) mode:"" CLEAR → NO skip audit; (b) skip-mode repo mismatch → BLOCK + NO skip audit
await test("T4: mode:'' CLEAR advance → NO skip audit; skip-mode repo-mismatch → BLOCK + NO skip audit", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    _setRepoForTest(TEST_REPO);
    await withEnv(GATE_ENV, async () => {
      sequenceEnforcer(pi as any);
      _pushSkillForTest("/repo/skills/t4a/SKILL.md", checkpointSkillSteps(), 0);
      writeToken(new Date().toISOString(), { phase: "plan", repo: TEST_REPO, mode: "" });
      await handlers.tool_call!({ toolName: "read", toolCallId: "t4a", input: { path: "x" } });
      equal(_stackForTest()[0]!.stepIndex, 1, "board-mode token advances");
      ok(!auditEntries.some((x) => x.event === "checkpoint_no_board_skip"), "NO skip audit for a mode:'' token");
    });
  } finally { auditRelease(); _setTokenFileForTest(null); _setRepoForTest(null); }
  _resetStateForTest();
  const { pi: pi4b, handlers: handlers4b } = fakePi();
  auditCapture();
  try {
    _setRepoForTest(TEST_REPO);
    await withEnv(GATE_ENV, async () => {
      sequenceEnforcer(pi4b as any);
      _pushSkillForTest("/repo/skills/t4b/SKILL.md", checkpointSkillSteps(), 0);
      writeToken(new Date().toISOString(), { phase: "plan", repo: OTHER_REPO, mode: "no-board-skip" });
      const res = await handlers4b.tool_call!({ toolName: "bash", toolCallId: "t4b", input: { command: "rm -rf /" } });
      ok(res && res.block, "mismatched-repo skip token BLOCKs");
      ok((res.reason as string).includes("repo"), "named repo reason");
      equal(_stackForTest()[0]!.stepIndex, 0, "no advance");
      ok(!auditEntries.some((x) => x.event === "checkpoint_no_board_skip"), "no skip audit on the blocked call");
    });
  } finally { auditRelease(); _setTokenFileForTest(null); _setRepoForTest(null); }
});

// T5 — the viaForce criterion: force-driven advance with a stale no-board token →
// force_pass audited, NO skip audit (T6(h)); marker advance with a present force
// file (real token wins) → consumed, NO force_pass (T6(g)).
await test("T5: VIAFORCE-driven advance (real token FAILS) with a stale no-board token → force_pass audited, NO skip audit", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    _setRepoForTest("test-repo");
    await withEnv(GATE_ENV, async () => {
      sequenceEnforcer(pi as any);
      _pushSkillForTest("/repo/skills/t5/SKILL.md", checkpointSkillSteps(), 0);
      writeForceFile(FORCE_GOOD); // repo test-repo, phase plan, fresh
      writeToken(new Date(Date.now() - 11 * 60 * 1000).toISOString(), { phase: "plan", repo: "test-repo", mode: "no-board-skip" }); // STALE skip token
      await handlers.tool_call!({ toolName: "read", toolCallId: "t5", input: { path: "x" } });
      equal(_stackForTest()[0]!.stepIndex, 1, "advanced via the force file");
      const pass = auditEntries.filter((x) => x.event === "checkpoint_force_pass");
      equal(pass.length, 1, "checkpoint_force_pass audited — the force file DROVE the pass");
      ok(!auditEntries.some((x) => x.event === "checkpoint_no_board_skip"), "no spurious skip audit on a force-driven advance");
    });
  } finally { auditRelease(); _setForceFileForTest(null); _setTokenFileForTest(null); _setRepoForTest(null); }
});

await test("T5: marker advance with a present force file (real token wins) → consumed, NO checkpoint_force_pass", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    _setRepoForTest("test-repo");
    await withEnv(GATE_ENV, async () => {
      sequenceEnforcer(pi as any);
      _pushSkillForTest("/repo/skills/t5m/SKILL.md", checkpointSkillSteps(), 0);
      // force file appears AFTER the escape call (at call time the checkpoint is
      // pending — otherwise the tool_call branch would force-advance and the
      // marker would never fire); at result time the REAL token wins.
      const res = await handlers.tool_call!({ toolName: "bash", toolCallId: "t5m", input: { command: "parallel_work_check.sh plan" } });
      ok(!res || !res.block, "escape allowed");
      writeForceFile(FORCE_GOOD);
      writeToken(new Date().toISOString(), { phase: "plan", repo: "test-repo" }); // REAL token appears
      await handlers.tool_result!({ toolName: "bash", toolCallId: "t5m" });
      equal(_stackForTest()[0]!.stepIndex, 1, "marker advanced via the real token");
      ok(!existsSync(forceFilePath()), "force file consumed on the marker advance (one-shot)");
      ok(!auditEntries.some((x) => x.event === "checkpoint_force_pass"), "no force_pass — the real token drove the advance");
    });
  } finally { auditRelease(); _setForceFileForTest(null); _setTokenFileForTest(null); _setRepoForTest(null); }
});

// T6 — emission count (T6(f)): exactly ONE skip audit per advance; guidance
// renders and blocked calls emit none (the audit lives ONLY at the two
// token-driven advance branches, never inside checkpointTokenOk).
await test("T6: exactly ONE skip audit per advance — none on blocked calls or guidance renders", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    _setRepoForTest(TEST_REPO);
    await withEnv(GATE_ENV, async () => {
      sequenceEnforcer(pi as any);
      _pushSkillForTest("/repo/skills/t6/SKILL.md", checkpointSkillSteps(), 0);
      writeToken(new Date().toISOString(), { phase: "plan", repo: TEST_REPO, mode: "no-board-skip" });
      const res = await handlers.tool_call!({ toolName: "bash", toolCallId: "t6a", input: { command: "parallel_work_check.sh plan" } });
      ok(res && res.block, "checker re-run blocked at ok-checkpoint");
      equal(_stackForTest()[0]!.stepIndex, 1, "advance still happened (blocked-call rule)");
      let skip = auditEntries.filter((x) => x.event === "checkpoint_no_board_skip");
      equal(skip.length, 1, "exactly ONE skip audit for the advance");
      // guidance renders (State-2 fresh-token and State-1 pending) must not emit
      gateGuidance(checkpointStep());
      gateGuidance(makeStep({ gate: "checkpoint", token_phase: "plan" }), "gate");
      equal(auditEntries.filter((x) => x.event === "checkpoint_no_board_skip").length, 1, "guidance renders emit no skip audit");
    });
  } finally { auditRelease(); _setTokenFileForTest(null); _setRepoForTest(null); }
});

// T7 — audit-sink WRITE failure (T6(i)): no throw escapes to the fail-open
// catch, the advance outcome is unchanged, the failure is surfaced (console.warn).
await test("T7: audit-sink WRITE failure at EACH token-driven advance → no throw, advance unchanged, failure surfaced", async () => {
  for (const label of ["real-token", "marker"]) {
    _resetStateForTest();
    const { pi, handlers } = fakePi();
    warnCaptureStart();
    try {
      _setAuditSinkForTest(() => { throw new Error("simulated sink write failure"); });
      _setRepoForTest(TEST_REPO);
      await withEnv(GATE_ENV, async () => {
        sequenceEnforcer(pi as any);
        _pushSkillForTest("/repo/skills/t7/SKILL.md", checkpointSkillSteps(), 0);
        if (label === "real-token") {
          writeToken(new Date().toISOString(), { phase: "plan", repo: TEST_REPO, mode: "no-board-skip" });
          await handlers.tool_call!({ toolName: "read", toolCallId: "t7a", input: { path: "x" } });
          equal(_stackForTest()[0]!.stepIndex, 1, "advance unchanged despite the sink failure");
        } else {
          const res = await handlers.tool_call!({ toolName: "bash", toolCallId: "t7b", input: { command: "parallel_work_check.sh plan" } });
          ok(!res || !res.block, "escape allowed");
          writeToken(new Date().toISOString(), { phase: "plan", repo: TEST_REPO, mode: "no-board-skip" });
          await handlers.tool_result!({ toolName: "bash", toolCallId: "t7b" });
          equal(_stackForTest()[0]!.stepIndex, 1, "marker advance unchanged despite the sink failure");
        }
      });
    } finally {
      warnCaptureStop();
      _setAuditSinkForTest(null);
      _setTokenFileForTest(null);
      _setRepoForTest(null);
    }
    ok(warns.some((w) => w.includes("audit") && w.includes("failed")), `${label}: sink failure surfaced via console.warn (never silent)`);
    warns = [];
  }
});

await test("T7-ext: auditLog is throw-proof — a THROWING console.warn inside the sink-failure catch does NOT escape into the fail-open catch", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  const origWarn = console.warn;
  try {
    // sink failure AND a broken console.warn — the P3-2 hazard: without the
    // defensive try/catch, the warn throw would escape auditLog → land in the
    // handler's fail-open catch → a second broken warn → propagate OUT of the
    // handler (the tool chain would see an error where a plain block was due).
    _setAuditSinkForTest(() => { throw new Error("simulated sink write failure"); });
    console.warn = () => { throw new Error("console.warn itself broken"); };
    _setRepoForTest(TEST_REPO);
    await withEnv(GATE_ENV, async () => {
      sequenceEnforcer(pi as any);
      _pushSkillForTest("/repo/skills/t7x/SKILL.md", checkpointSkillSteps(), 0);
      writeToken(new Date().toISOString(), { phase: "plan", repo: TEST_REPO, mode: "no-board-skip" });
      const res = await handlers.tool_call!({ toolName: "read", toolCallId: "t7x", input: { path: "x" } });
      ok(!res || !res.block, "advancing call not blocked");
      equal(_stackForTest()[0]!.stepIndex, 1, "advance unchanged — auditLog's warn throw did NOT escape");
    });
  } finally {
    console.warn = origWarn;
    _setAuditSinkForTest(null);
    _setTokenFileForTest(null);
    _setRepoForTest(null);
  }
});

// T8 — same-repo DIFFERENT URL format → named BLOCK (Task 4's doc must match:
// same-repo-different-format fails too — re-run from the same checkout form).
await test("T8: same-repo DIFFERENT URL format → named-reason BLOCK (https vs scp of the same bare origin)", () => {
  const d = tmpDir("t8");
  const bare = join(d, "bare.git");
  execSync(`git init --bare -q -b main "${bare}"`);
  const seed = join(d, "seed");
  execSync(`git clone -q "${bare}" "${seed}"`);
  execSync(`git -C "${seed}" config user.email t8@test.local`);
  execSync(`git -C "${seed}" config user.name t8`);
  writeFileSync(join(seed, "f.txt"), "x\n");
  execSync(`git -C "${seed}" add -A`);
  execSync(`git -C "${seed}" commit -q -m seed`);
  execSync(`git -C "${seed}" push -q origin main`);
  const c1 = join(d, "c1"); const c2 = join(d, "c2");
  execSync(`git clone -q "${bare}" "${c1}"`);
  execSync(`git clone -q "${bare}" "${c2}"`);
  const httpsUrl = "https://example.com/org/repo.git";
  const scpUrl = "git@example.com:org/repo.git";
  execSync(`git -C "${c1}" remote set-url origin "${httpsUrl}"`);
  execSync(`git -C "${c2}" remote set-url origin "${scpUrl}"`);
  _setRepoForTest(execSync(`git -C "${c1}" remote get-url origin`, { encoding: "utf-8" }).trim());
  try {
    // a token written from c2 (scp form) — the SAME repo, different URL format
    writeToken(new Date().toISOString(), { phase: "plan", repo: scpUrl });
    const r = checkpointTokenOk(checkpointStep(), { enforceBinding: true });
    ok(!r.ok, "same-repo different URL format → named-reason BLOCK");
    ok(r.reason.includes("repo"), "named repo reason");
  } finally { _setTokenFileForTest(null); _setRepoForTest(null); }
});

// T9 — State-1 guidance at a binding-fail start-phase step: ENFORCE prefix +
// resolved absolute path (the escape-regex-safe print form).
await test("T9: State-1 guidance at binding-fail — start phase emits env CHECKOUT_GUARD_ENFORCE=1 + resolved abs path; plan phase has no prefix", async () => {
  _setRepoForTest(OTHER_REPO);
  try {
    writeToken(new Date().toISOString(), { phase: "start", repo: TEST_REPO, mode: "no-board-skip" }); // repo mismatch → binding-fail
    await withEnv({ AGENT_INFRA_PATH: REPO_ROOT }, () => {
      const g = gateGuidance(makeStep({ name: "check", gate: "checkpoint", token_phase: "start" }));
      ok(g.includes("env CHECKOUT_GUARD_ENFORCE=1"), "State-1 start → ENFORCE prefix emitted");
      ok(g.includes(`${REPO_ROOT}/scripts/parallel_work_check.sh start`), "resolved absolute path form");
      ok(isCheckpointEscape("bash", g.split("run `")[1]!.split("` until")[0]!), "emitted form passes the escape regex");
      const g2 = gateGuidance(checkpointStep()); // plan phase — the start token above is also phase-mismatched → State-1
      ok(!g2.includes("CHECKOUT_GUARD_ENFORCE"), "no ENFORCE prefix for plan phase");
      ok(g2.includes("parallel_work_check.sh plan"), "plan form printed");
    });
  } finally { _setTokenFileForTest(null); _setRepoForTest(null); }
});

// T10 — frozen old-contract proxy + partial-write fixtures (T10a–T10e)
await test("T10a: frozen old-contract proxy — minimal reader (phase/verdict/ts only) advances on a mode+repo+unknown-fields token", () => {
  const d = tmpDir("t10a");
  const p = join(d, "token.json");
  writeFileSync(p, JSON.stringify({ verdict: "CLEAR", phase: "implement", ts: new Date().toISOString(), mode: "no-board-skip", repo: TEST_REPO, card_id: "c1", symbol: "S", future_field: 42 }));
  ok(minimalOldContractReader(p, "implement").ok, "old-contract reader survives additive fields (mode/repo/unknown)");
});

await test("T10b: truncate/partial-write token → named corrupt-token reason + no advance", () => {
  const d = tmpDir("t10b");
  const p = join(d, "token.json");
  writeFileSync(p, '{"verdict":"CLEAR","phase":"plan","ts":'); // truncated mid-write
  _setTokenFileForTest(p);
  _setRepoForTest(TEST_REPO);
  try {
    const r = checkpointTokenOk(checkpointStep(), { enforceBinding: true });
    ok(!r.ok, "truncated token blocks");
    ok(r.reason.includes("corrupt"), "named corrupt reason");
  } finally { _setTokenFileForTest(null); _setRepoForTest(null); }
});

await test("T10c: garbage/truncated FORCE file → named handling + no throw + no checkpoint_force_pass + gate does NOT ALLOW", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    _setRepoForTest(TEST_REPO);
    await withEnv(GATE_ENV, async () => {
      sequenceEnforcer(pi as any);
      _pushSkillForTest("/repo/skills/t10c/SKILL.md", checkpointSkillSteps(), 0);
      writeForceFile("{not json");
      const res = await handlers.tool_call!({ toolName: "bash", toolCallId: "t10c", input: { command: "rm -rf /" } });
      ok(res && res.block, "gate does NOT ALLOW with a garbage force file (a parse-throw would land in the fail-open catch)");
      ok((res.reason as string).includes("malformed"), "reason names the malformed force file");
      equal(_stackForTest()[0]!.stepIndex, 0, "no advance");
      ok(!auditEntries.some((x) => x.event === "checkpoint_force_pass"), "no force_pass (it never passed anything)");
    });
  } finally { auditRelease(); _setForceFileForTest(null); _setRepoForTest(null); }
});

await test("T10d: chmod-000 (unreadable) token file → named corrupt/unreadable reason, NOT a throw reaching the fail-open catch", () => {
  const d = tmpDir("t10d");
  const p = join(d, "token.json");
  writeFileSync(p, JSON.stringify({ verdict: "CLEAR", phase: "plan", ts: new Date().toISOString() }));
  chmodSync(p, 0o000);
  _setTokenFileForTest(p);
  _setRepoForTest(TEST_REPO);
  try {
    const r = checkpointTokenOk(checkpointStep(), { enforceBinding: true });
    ok(!r.ok, "unreadable token blocks");
    ok(r.reason.includes("unreadable") || r.reason.includes("corrupt"), "named corrupt/unreadable reason");
  } finally {
    try { chmodSync(p, 0o600); } catch { /* already gone */ }
    _setTokenFileForTest(null); _setRepoForTest(null);
  }
});

await test("T10d-ext: chmod-000 (unreadable) FORCE file → named malformed handling (NOT silent 'none'), no throw, gate does NOT ALLOW", () => {
  const d = tmpDir("t10d-force");
  const p = join(d, "force.json");
  writeFileSync(p, JSON.stringify({ verdict: "CLEAR", phase: "plan", operator: "daniel", origin: "shell", repo: TEST_REPO, ts: new Date().toISOString() }));
  chmodSync(p, 0o000);
  _setForceFileForTest(p);
  _setRepoForTest(TEST_REPO);
  try {
    // no real token + an UNREADABLE force file: the gate must stay fail-closed
    // and NAME the file (P3-3) — the old read-catch silently returned "none",
    // hiding the operator's bypass from the block reason.
    const r = checkpointTokenOk(checkpointStep(), { enforceBinding: true });
    ok(!r.ok, "unreadable force file does not silently ALLOW");
    ok(r.reason.includes("malformed"), "reason names the malformed force file");
    ok(r.reason.includes(p), "reason names the force file path");
  } finally {
    try { chmodSync(p, 0o600); } catch { /* already gone */ }
    _setForceFileForTest(null); _setRepoForTest(null);
  }
});

await test("T10e: valid-JSON-wrong-SHAPE tokens (null/[]/scalar/{}) → NAMED corrupt reason, no throw, no advance", async () => {
  const shapes: Array<{ label: string; value: unknown }> = [
    { label: "null", value: null },
    { label: "array", value: [] },
    { label: "scalar", value: 42 },
    { label: "empty object", value: {} },
  ];
  for (const s of shapes) {
    const d = tmpDir("t10e");
    const p = join(d, "token.json");
    writeFileSync(p, JSON.stringify(s.value));
    _setTokenFileForTest(p);
    _setRepoForTest(TEST_REPO);
    try {
      const r = checkpointTokenOk(checkpointStep(), { enforceBinding: true });
      ok(!r.ok, `${s.label} → blocks`);
      ok(r.reason.includes("corrupt"), `${s.label} → NAMED corrupt reason (was an empty-reason BLOCK for null)`);
    } finally { _setTokenFileForTest(null); _setRepoForTest(null); }
  }
});

// T11 — JOINT cross-language test: exec the REAL vendored checker (no-board env
// + temp token file) → feed its ACTUAL token to the REAL checkpointTokenOk →
// ok + the no-board-skip audit path; repo-mismatch variant → named BLOCK; and
// through the T10 minimal old-contract reader → advance (the deploy-window
// WRITE-side contract — token-shape drift goes CI-red independent of manifest).
await test("T11: JOINT checker→enforcer — real vendored checker token advances the real gate + skip audit; mismatch BLOCKs; old-contract reader advances", async () => {
  const d = tmpDir("t11");
  const { seed, originUrl } = makeNoBoardRepo(d);
  const tokenPath = join(d, "token.json");
  const sh = join(REPO_ROOT, "scripts", "parallel_work_check.sh");
  // no-board exec env: clear ALL 14 signal names + symbol/search overrides;
  // PYTHON_BIN=python3.12 is CRITICAL — the wrapper defaults to `python3`
  // (system 3.9.6) which cannot run the checker's type-hinted code.
  const execEnv: Record<string, string> = { ...(process.env as Record<string, string>) };
  for (const name of NOBOARD_SIGNAL_NAMES) delete execEnv[name];
  for (const name of ["PARALLEL_CHECK_SYMBOL", "GH_TOKEN", "GH_API_BASE", "GH_REPOSITORY", "PARALLEL_CHECK_REPO_SLUG"]) delete execEnv[name];
  execEnv.PYTHON_BIN = "python3.12";
  execEnv.PARALLEL_CHECK_TOKEN_FILE = tokenPath;
  execEnv.PARALLEL_CHECK_REPO = seed; // ops-target chain: --repo → PARALLEL_CHECK_REPO → cwd
  execEnv.CHECKOUT_GUARD_SWARM_ROOT = REPO_ROOT; // a real-ish repo for the guard's foreign-checkout policy
  execEnv.CHECKOUT_GUARD_LOG = join(d, "guard.log");
  execEnv.PARALLEL_CHECK_TIMEOUT_SECS = "20";
  const out = execFileSync("bash", [sh, "start"], { env: execEnv, encoding: "utf-8", timeout: 90_000 }).trim();
  ok(out.includes("C1: CLEAR"), `checker verdict CLEAR (got: ${out})`);
  ok(out.includes("no-board-skip"), "distinguishable skip advisory on the verdict line");
  const token = JSON.parse(readFileSync(tokenPath, "utf-8"));
  equal(token.verdict, "CLEAR");
  equal(token.phase, "start");
  equal(token.mode, "no-board-skip", "token carries the no-board mode field");
  ok(typeof token.repo === "string" && token.repo.length > 0, "token carries the URL-form repo");
  // feed the real token to the real gate (binding via the seed's origin URL)
  _setTokenFileForTest(tokenPath);
  _setRepoForTest(originUrl);
  try {
    const r = checkpointTokenOk(makeStep({ gate: "checkpoint", token_phase: "start" }), { enforceBinding: true });
    ok(r.ok, r.reason);
    equal(r.mode, "no-board-skip", "mode surfaced");
    // skip-audit path through the real handler (token-driven advance)
    _resetStateForTest();
    _setTokenFileForTest(tokenPath); // _resetStateForTest clears the overrides — restore them
    _setRepoForTest(originUrl);
    const { pi, handlers } = fakePi();
    auditCapture();
    try {
      await withEnv(GATE_ENV, async () => {
        sequenceEnforcer(pi as any);
        _pushSkillForTest("/repo/skills/t11/SKILL.md", [
          makeStep({ name: "check", gate: "checkpoint", token_phase: "start" }),
          makeStep({ name: "impl", gate: "auto" }),
        ], 0);
        await handlers.tool_call!({ toolName: "read", toolCallId: "j1", input: { path: "x" } });
        equal(_stackForTest()[0]!.stepIndex, 1, "advanced via the real checker's token");
        const skip = auditEntries.filter((x) => x.event === "checkpoint_no_board_skip");
        equal(skip.length, 1, "skip audit emitted");
        equal(skip[0]!.token_mode, "no-board-skip");
        equal(skip[0]!.phase, "start");
        equal(skip[0]!.repo, originUrl, "audit repo = the seed's origin URL (sanitized)");
      });
    } finally { auditRelease(); }
    // repo-mismatch variant → named-reason BLOCK
    _setRepoForTest("https://other.example/org/repo.git");
    const m = checkpointTokenOk(makeStep({ gate: "checkpoint", token_phase: "start" }), { enforceBinding: true });
    ok(!m.ok, "repo-mismatch BLOCK");
    ok(m.reason.includes("repo"), "named repo reason");
    // the T10 minimal old-contract reader advances on the checker's ACTUAL token
    ok(minimalOldContractReader(tokenPath, "start").ok, "old-contract reader advances on the real token");
  } finally { _setTokenFileForTest(null); _setRepoForTest(null); }
});

// T12 — shared-token semantics = contract, not accident: checkpointTokenOk
// NEVER unlinks the token (only the force file is one-shot).
await test("T12: shared-token semantics — token file still EXISTS after an ok-advance; a second same-phase/same-repo checkpoint advances on the same file", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    _setRepoForTest(TEST_REPO);
    await withEnv(GATE_ENV, async () => {
      sequenceEnforcer(pi as any);
      const pair = [
        makeStep({ name: "check1", gate: "checkpoint", token_phase: "plan" }),
        makeStep({ name: "check2", gate: "checkpoint", token_phase: "plan" }),
        makeStep({ name: "impl", gate: "auto" }),
      ];
      const tokenPath = writeTokenPath(new Date().toISOString(), { phase: "plan", repo: TEST_REPO });
      _pushSkillForTest("/repo/skills/t12/SKILL.md", pair, 0);
      await handlers.tool_call!({ toolName: "read", toolCallId: "t12a", input: { path: "x" } });
      equal(_stackForTest()[0]!.stepIndex, 1, "check1 advanced");
      ok(existsSync(tokenPath), "token file still EXISTS after the ok-advance (never unlinked)");
      await handlers.tool_call!({ toolName: "read", toolCallId: "t12b", input: { path: "x" } });
      equal(_stackForTest()[0]!.stepIndex, 2, "check2 advanced on the SAME token (last-writer-wins shared semantics)");
      ok(existsSync(tokenPath), "token survives both advances");
    });
  } finally { auditRelease(); _setTokenFileForTest(null); _setRepoForTest(null); }
});

// T13 — interleaved plan→implement: last-writer-wins PHASE semantics.
await test("T13: interleaved plan→implement — the plan gate BLOCKs on the implement token; the implement gate passes", () => {
  try {
    _setRepoForTest(TEST_REPO);
    writeToken(new Date().toISOString(), { phase: "implement", repo: TEST_REPO }); // OTHER session wrote implement
    const plan = checkpointTokenOk(makeStep({ gate: "checkpoint", token_phase: "plan" }), { enforceBinding: true });
    ok(!plan.ok, "plan gate BLOCKs on the implement token (phase)");
    ok(plan.reason.includes("≠ required"), "named phase reason");
    const impl = checkpointTokenOk(makeStep({ gate: "checkpoint", token_phase: "implement" }), { enforceBinding: true });
    ok(impl.ok, "implement gate passes on the other session's token");
  } finally { _setTokenFileForTest(null); _setRepoForTest(null); }
});

// T14 — repo env/flag edge + resolveRepo bad-path contract
await test("T14: empty PARALLEL_CHECK_REPO → currentRepo() (never a bound ''); checker --repo X vs enforcer cwd Y → named BLOCK + PARALLEL_CHECK_REPO remediation", async () => {
  _setRepoForTest(TEST_REPO);
  try {
    await withEnv({ PARALLEL_CHECK_REPO: "" }, () => {
      writeToken(new Date().toISOString(), { phase: "plan", repo: TEST_REPO });
      ok(checkpointTokenOk(checkpointStep(), { enforceBinding: true }).ok, "empty env falls through to currentRepo()");
    });
    _setTokenFileForTest(null);
    // --repo X from cwd Y (no env): the enforcer never learns the flag → binds Y
    writeToken(new Date().toISOString(), { phase: "plan", repo: OTHER_REPO }); // token bound to X (the checker ran with --repo X)
    const r = checkpointTokenOk(checkpointStep(), { enforceBinding: true });
    ok(!r.ok, "checker --repo X vs enforcer cwd Y → named BLOCK");
    ok(r.reason.includes("PARALLEL_CHECK_REPO"), "remediation names set PARALLEL_CHECK_REPO to the checkout path");
  } finally { _setTokenFileForTest(null); _setRepoForTest(null); }
});

await test("T14: resolveRepo bad paths (nonexistent / plain file / non-git dir) → 'unknown', binding passes via both-'unknown' (a throw would convert BLOCK→ALLOW)", () => {
  const d = tmpDir("t14");
  const nonexistent = join(d, "missing-repo");
  const plainFile = join(d, "file.txt");
  writeFileSync(plainFile, "x");
  const nonGitDir = join(d, "plain-dir");
  mkdirSync(nonGitDir, { recursive: true });
  for (const bad of [nonexistent, plainFile, nonGitDir]) {
    const saved = process.env.PARALLEL_CHECK_REPO;
    process.env.PARALLEL_CHECK_REPO = bad;
    try {
      _setRepoForTest(null); // bindingRepo must fall to resolveRepo(PARALLEL_CHECK_REPO)
      writeToken(new Date().toISOString(), { phase: "plan", repo: "unknown" });
      const r = checkpointTokenOk(checkpointStep(), { enforceBinding: true });
      ok(r.ok, `${bad}: resolveRepo → 'unknown' → both-'unknown' passes (no throw)`);
    } finally {
      _setTokenFileForTest(null);
      _setRepoForTest(null);
      if (saved === undefined) delete process.env.PARALLEL_CHECK_REPO;
      else process.env.PARALLEL_CHECK_REPO = saved;
    }
  }
});

// T14-extension (spec-compliance P1) — the resolveRepo POSITIVE contract:
// PARALLEL_CHECK_REPO is documented as a PATH while token.repo carries the URL
// form; resolveRepo must run `git -C <path> remote get-url origin` and bind
// identically to the checker's GitOps.remote_url. The pre-existing tests only
// pinned the NEGATIVE contract (bad paths → 'unknown'); a regression in
// real-path resolution would go CI-green today without this parity pin.
await test("T14: path-valued PARALLEL_CHECK_REPO → origin-URL parity: matching token passes; divergent-repo token BLOCKs (resolveRepo POSITIVE contract)", async () => {
  const d = tmpDir("t14path");
  const { seed, originUrl } = makeNoBoardRepo(d);
  const saved = process.env.PARALLEL_CHECK_REPO;
  process.env.PARALLEL_CHECK_REPO = seed; // PATH form — the documented contract
  try {
    _setRepoForTest(null); // bindingRepo must fall to resolveRepo(PARALLEL_CHECK_REPO)
    // token.repo = the path's `git remote get-url origin` value (URL form) —
    // the exact value the checker's GitOps.remote_url() would write.
    writeToken(new Date().toISOString(), { phase: "plan", repo: originUrl });
    ok(checkpointTokenOk(checkpointStep(), { enforceBinding: true }).ok,
      "path-valued PARALLEL_CHECK_REPO + matching token.repo → ok (pins resolveRepo path→URL contract)");
    _setTokenFileForTest(null);
    // divergent-repo token (a DIFFERENT origin's URL) → named-reason BLOCK
    writeToken(new Date().toISOString(), { phase: "plan", repo: OTHER_REPO });
    const r = checkpointTokenOk(checkpointStep(), { enforceBinding: true });
    ok(!r.ok, "path-resolved binding vs divergent token → named-reason BLOCK");
    ok(r.reason.includes("repo"), "named repo reason");
  } finally {
    _setTokenFileForTest(null);
    _setRepoForTest(null);
    if (saved === undefined) delete process.env.PARALLEL_CHECK_REPO;
    else process.env.PARALLEL_CHECK_REPO = saved;
  }
});

// T14-variant (#383 Task 3 P3, code-quality) — resolveRepo cache invalidation:
// the cache is keyed on the env VALUE AND the cwd. With a RELATIVE
// PARALLEL_CHECK_REPO (`.`, the natural operator shorthand) the `git -C .`
// binding is cwd-relative, so a mid-session chdir MUST re-resolve — else the
// enforcer stays pinned to the OLD repo while the checker binds the NEW one →
// spurious cross-repo BLOCK. The cache mirrors currentRepo's cwd-keyed
// invalidation: with the old env-only cache, the token for B would BLOCK
// against the cached A binding — this test FAILS on that regression.
await test("T14: RELATIVE PARALLEL_CHECK_REPO=. re-resolves on chdir (cache invalidates with cwd: A's token passes in A; after chdir B's token passes, A's BLOCKs)", async () => {
  const d = tmpDir("t14chdir");
  const repoA = makeNoBoardRepo(join(d, "a"));
  const repoB = makeNoBoardRepo(join(d, "b"));
  const savedCwd = process.cwd();
  const saved = process.env.PARALLEL_CHECK_REPO;
  process.env.PARALLEL_CHECK_REPO = "."; // RELATIVE path — binding is cwd-relative
  try {
    _setRepoForTest(null); // bindingRepo must fall to resolveRepo(PARALLEL_CHECK_REPO)
    // cwd = repo A → resolveRepo(".") binds A
    process.chdir(repoA.seed);
    writeToken(new Date().toISOString(), { phase: "plan", repo: repoA.originUrl });
    ok(checkpointTokenOk(checkpointStep(), { enforceBinding: true }).ok,
      "cwd A: RELATIVE env binds A → matching token passes");
    // chdir to repo B → the cache MUST invalidate (cwd key) and re-resolve to B
    process.chdir(repoB.seed);
    _setTokenFileForTest(null);
    writeToken(new Date().toISOString(), { phase: "plan", repo: repoB.originUrl });
    ok(checkpointTokenOk(checkpointStep(), { enforceBinding: true }).ok,
      "chdir → cache invalidates: RELATIVE env re-binds B → B's token passes (the cached-A binding is gone)");
    // A's token now BLOCKs against the B binding — the old cache would have passed it
    _setTokenFileForTest(null);
    writeToken(new Date().toISOString(), { phase: "plan", repo: repoA.originUrl });
    const r = checkpointTokenOk(checkpointStep(), { enforceBinding: true });
    ok(!r.ok, "chdir → re-resolved to B: A's token BLOCKs (env-only cache regression would have passed it)");
  } finally {
    process.chdir(savedCwd);
    _setTokenFileForTest(null);
    _setRepoForTest(null);
    if (saved === undefined) delete process.env.PARALLEL_CHECK_REPO;
    else process.env.PARALLEL_CHECK_REPO = saved;
  }
});

// T14-extension (spec-compliance P2) — cross-cwd worktree pass: a token bound
// to an origin passes when the enforcer's binding resolves from a DIFFERENT
// cwd of the SAME repo (linked worktrees share the origin remote — the
// mechanism currentRepo() provides). The pre-existing tests covered
// different-repo BLOCK, one-sided overrides, unknown-unknown, unknown-vs-remote,
// and the T8 divergent-URL-format BLOCK — but NOT the same-repo cross-cwd PASS;
// a per-cwd resolution regression would go CI-green today.
await test("T14: cross-cwd worktree pass — token from the seed's origin passes when binding resolves from a linked worktree's cwd (worktrees share the origin URL)", async () => {
  const d = tmpDir("t14wt");
  const bare = join(d, "bare.git");
  execSync(`git init --bare -q -b main "${bare}"`);
  const seed = join(d, "seed");
  execSync(`git clone -q "${bare}" "${seed}"`);
  execSync(`git -C "${seed}" config user.email wt@test.local`);
  execSync(`git -C "${seed}" config user.name wt`);
  writeFileSync(join(seed, "f.txt"), "x\n");
  execSync(`git -C "${seed}" add -A`);
  execSync(`git -C "${seed}" commit -q -m seed`);
  execSync(`git -C "${seed}" push -q origin main`);
  const wt = join(d, "wt");
  execSync(`git -C "${seed}" worktree add -q "${wt}"`); // linked worktree — SAME origin remote as the seed
  const originUrl = execSync(`git -C "${seed}" remote get-url origin`, { encoding: "utf-8" }).trim();
  equal(execSync(`git -C "${wt}" remote get-url origin`, { encoding: "utf-8" }).trim(), originUrl,
    "worktree shares the origin URL (the currentRepo() mechanism)");
  const savedCwd = process.cwd();
  try {
    // no PARALLEL_CHECK_REPO in play — bindingRepo must fall to currentRepo() (cwd)
    await withEnv({ PARALLEL_CHECK_REPO: undefined }, async () => {
      _setRepoForTest(null); // real cwd resolution: currentRepo() from the wt cwd
      writeToken(new Date().toISOString(), { phase: "plan", repo: originUrl }); // token written/bound from the seed's remote
      process.chdir(wt); // enforcer resolves the binding from a DIFFERENT cwd of the SAME repo
      ok(checkpointTokenOk(checkpointStep(), { enforceBinding: true }).ok,
        "same origin URL → PASS across cwds (per-cwd resolution regression would go CI-green today)");
    });
  } finally {
    process.chdir(savedCwd);
    _setTokenFileForTest(null);
    _setRepoForTest(null);
  }
});

// T15 — unset / nonexistent AGENT_INFRA_PATH guidance fail-open guard
await test("T15: AGENT_INFRA_PATH UNSET at a blocked call → guidance does NOT throw + 'set AGENT_INFRA_PATH' (a TypeError would fail-open the gate)", async () => {
  let g: string = "";
  await withEnv({ AGENT_INFRA_PATH: undefined, PARALLEL_CHECK_BIN: undefined }, () => {
    g = gateGuidance(checkpointStep()); // pending checkpoint, gate mode default
  });
  ok(g.includes("set AGENT_INFRA_PATH"), "instruction present, no throw");
  // handler-level: the blocked call STAYS blocked — the fail-open catch never fires
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv({ ...GATE_ENV, AGENT_INFRA_PATH: undefined, PARALLEL_CHECK_BIN: undefined }, async () => {
      sequenceEnforcer(pi as any);
      _pushSkillForTest("/repo/skills/t15/SKILL.md", checkpointSkillSteps(), 0);
      const res = await handlers.tool_call!({ toolName: "bash", toolCallId: "t15", input: { command: "rm -rf /" } });
      ok(res && res.block, "gate still BLOCKs with AGENT_INFRA_PATH unset (no fail-open conversion)");
      ok(!auditEntries.some((x) => x.event === "handler_error"), "no handler_error — gateGuidance did not throw");
    });
  } finally { auditRelease(); }
});

await test("T15: AGENT_INFRA_PATH SET-but-NONEXISTENT → no throw, runnable form + explicit 'path does not exist' hint", async () => {
  const d = tmpDir("t15b");
  const ghost = join(d, "ghost-agent-infra");
  await withEnv({ AGENT_INFRA_PATH: ghost, PARALLEL_CHECK_BIN: undefined }, () => {
    const g = gateGuidance(checkpointStep());
    ok(g.includes("parallel_work_check.sh plan"), "runnable form still printed");
    ok(g.includes("does not exist"), "explicit path-does-not-exist hint distinguishes it from the unset state");
  });
});

await test("T15-ext (P3-5): PARALLEL_CHECK_BIN SET-but-NONEXISTENT → 'path does not exist' hint fires too, source named generically", async () => {
  const d = tmpDir("t15bin");
  const ghost = join(d, "ghost-checker.sh");
  await withEnv({ AGENT_INFRA_PATH: REPO_ROOT, PARALLEL_CHECK_BIN: ghost }, () => {
    const g = gateGuidance(checkpointStep());
    ok(g.includes(ghost), "runnable form names the PARALLEL_CHECK_BIN path");
    ok(g.includes("does not exist"), "explicit path-does-not-exist hint fires for a ghost PARALLEL_CHECK_BIN too (was: silent unexecutable path)");
    ok(g.includes("PARALLEL_CHECK_BIN"), "hint names the source generically (PARALLEL_CHECK_BIN / AGENT_INFRA_PATH)");
  });
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

// ── #377: audit session_id schema + enforcement.jsonl reader ──
section("#377 session attribution (audit session_id)");

await test("session_start captures ctx session id and startup audit entry carries it", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv(
      { PI_SESSION_ID: undefined, PI_MODE: "print", AGENT_SEQUENCE_MODE: "warn", AGENT_STATE_MACHINE: undefined, ELDATO_STATE_MACHINE: undefined },
      async () => {
        sequenceEnforcer(pi as any);
        // ctx with sessionManager.getSessionId() → authoritative in-process source.
        const ctx = { sessionManager: { getSessionId: () => "sess-377a" } };
        await handlers.session_start!({ type: "session_start", reason: "startup" }, ctx);
        const startup = auditEntries.find((x) => x.event === "startup");
        ok(startup, "startup entry emitted");
        equal(startup!.session_id, "sess-377a", "startup entry carries the ctx session id");
        equal(_auditSessionIdForTest(), "sess-377a", "module captured id from ctx (ctx-first)");
      },
    );
  } finally { auditRelease(); }
});

await test("no ctx → session_id is null on entries (always-present key)", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv(
      { PI_SESSION_ID: undefined, PI_MODE: "print", AGENT_SEQUENCE_MODE: "warn", AGENT_STATE_MACHINE: undefined, ELDATO_STATE_MACHINE: undefined },
      async () => {
        sequenceEnforcer(pi as any);
        await handlers.session_start!(); // no ctx → no session id
        const startup = auditEntries.find((x) => x.event === "startup");
        ok(startup, "startup entry emitted");
        ok("session_id" in startup!, "session_id key always present");
        equal(startup!.session_id, null, "unresolvable session → null, not missing-key ambiguity");
      },
    );
  } finally { auditRelease(); }
});

await test("env PI_SESSION_ID is NOT consulted (ctx-only — closes the inherited-env misattribution channel)", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv(
      // Host env carries an (inherited, outer-session) id; no ctx → must NOT
      // stamp it (a nested pi inside an outer bash tool inherits the outer id).
      { PI_SESSION_ID: "sess-env-outer", PI_MODE: "print", AGENT_SEQUENCE_MODE: "warn", AGENT_STATE_MACHINE: undefined, ELDATO_STATE_MACHINE: undefined },
      async () => {
        sequenceEnforcer(pi as any);
        await handlers.session_start!(); // no ctx
        const startup = auditEntries.find((x) => x.event === "startup");
        equal(startup!.session_id, null, "env PI_SESSION_ID is never used as a fallback (probe-misattribution channel closed)");
      },
    );
  } finally { auditRelease(); }
});

await test("blocked/allowed entries carry the ctx session id at the tool_call boundary", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv(
      { PI_SESSION_ID: undefined, PI_MODE: "print", AGENT_SEQUENCE_MODE: "gate", AGENT_STATE_MACHINE: undefined, ELDATO_STATE_MACHINE: undefined },
      async () => {
        sequenceEnforcer(pi as any);
        const ctx = { sessionManager: { getSessionId: () => "sess-377b" } };
        await handlers.session_start!({ type: "session_start", reason: "startup" }, ctx);
        // blocked at a pending checkpoint
        _pushSkillForTest("/repo/skills/check/SKILL.md", [makeStep({ name: "check", gate: "checkpoint", token_phase: "plan" })], 0);
        await handlers.tool_call!({ toolName: "bash", toolCallId: "s1", input: { command: "rm -rf /" } }, ctx);
        const blocked = auditEntries.filter((x) => x.event === "blocked");
        ok(blocked.length >= 1, "blocked entry present");
        ok(blocked.every((x) => x.session_id === "sess-377b"), "blocked entries carry the ctx session id");
      },
    );
  } finally { auditRelease(); }
});

await test("captureAuditSession never throws on a throwing ctx.sessionManager getter (stale runner)", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv(
      { PI_SESSION_ID: undefined, PI_MODE: "print", AGENT_SEQUENCE_MODE: "warn", AGENT_STATE_MACHINE: undefined, ELDATO_STATE_MACHINE: undefined },
      async () => {
        sequenceEnforcer(pi as any);
        // pi's ctx.sessionManager is a lazy getter that can throw (assertActive
        // on a stale runner) — capture must swallow, never propagate.
        const staleCtx = { get sessionManager() { throw new Error("stale runner"); } };
        await handlers.session_start!({ type: "session_start", reason: "startup" }, staleCtx as any);
        const startup = auditEntries.find((x) => x.event === "startup");
        ok(startup, "startup entry STILL emitted despite throwing ctx getter");
        equal(startup!.session_id, null, "unresolvable (throwing) ctx → null, no throw");
        // subsequent ctx-less handler also does not throw
        await handlers.session_shutdown!();
        ok(true, "session_shutdown with no ctx completed without throwing");
      },
    );
  } finally { auditRelease(); }
});

await test("module-level captured session id is dropped at session_shutdown (no cross-session bleed)", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv(
      { PI_SESSION_ID: undefined, PI_MODE: "print", AGENT_SEQUENCE_MODE: "gate", AGENT_STATE_MACHINE: undefined, ELDATO_STATE_MACHINE: undefined },
      async () => {
        sequenceEnforcer(pi as any);
        const ctx = { sessionManager: { getSessionId: () => "sess-shutdown" } };
        await handlers.session_start!({ type: "session_start", reason: "startup" }, ctx);
        equal(_auditSessionIdForTest(), "sess-shutdown", "captured before shutdown");
        await handlers.session_shutdown!();
        equal(_auditSessionIdForTest(), null, "dropped at shutdown — a stale write can never be misattributed");
      },
    );
  } finally { auditRelease(); }
});

await test("_setAuditSessionIdForTest(null) deactivates the override (sibling-seam convention)", async () => {
  _resetStateForTest();
  _setAuditSessionIdForTest("sess-override-1");
  equal(_auditSessionIdForTest(), "sess-override-1", "override captured");
  _setAuditSessionIdForTest(null);
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv(
      { PI_SESSION_ID: undefined, PI_MODE: "print", AGENT_SEQUENCE_MODE: "warn", AGENT_STATE_MACHINE: undefined, ELDATO_STATE_MACHINE: undefined },
      async () => {
        sequenceEnforcer(pi as any);
        await handlers.session_start!(); // ctx-less, override deactivated
        const startup = auditEntries.find((x) => x.event === "startup");
        equal(startup!.session_id, null, "null deactivates — a ctx-less session_start resolves to null, not a forced value");
      },
    );
  } finally { auditRelease(); _resetStateForTest(); }
});

await test("_resetStateForTest clears the session override + captured id (reset contract)", async () => {
  _resetStateForTest();
  _setAuditSessionIdForTest("sess-override-1");
  equal(_auditSessionIdForTest(), "sess-override-1", "override captured");
  _resetStateForTest();
  equal(_auditSessionIdForTest(), null, "reset drops captured id");
});

await test("audit sink override forces a deterministic session id (test seam)", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  try {
    await withEnv(
      { PI_SESSION_ID: undefined, PI_MODE: "print", AGENT_SEQUENCE_MODE: "warn", AGENT_STATE_MACHINE: undefined, ELDATO_STATE_MACHINE: undefined },
      async () => {
        _setAuditSessionIdForTest("sess-forced");
        sequenceEnforcer(pi as any);
        await handlers.session_start!();
        const startup = auditEntries.find((x) => x.event === "startup");
        equal(startup!.session_id, "sess-forced", "override drives a deterministic id for no-ctx test paths");
      },
    );
  } finally { auditRelease(); _setAuditSessionIdForTest(null); _resetStateForTest(); }
});

section("#378 per-session token-file scoping");

// #378: the token default is per-session — /tmp/parallel-check-token.json →
// /tmp/parallel-check-token.<sid>.json (sid = the ctx session id, the SAME
// value pi injects as PI_SESSION_ID into the checker's bash child env). The
// vendored checker (python + .sh) sanitizes identically (byte-wise), so
// writer and reader agree; these tests pin the enforcer side + the isolation
// property (session A's token never satisfies session B and vice versa).

await test("scopedTokenFilePath: null/empty/whitespace session → unscoped base (fallback contract)", () => {
  equal(scopedTokenFilePath(null), "/tmp/parallel-check-token.json");
  equal(scopedTokenFilePath(""), "/tmp/parallel-check-token.json");
  equal(scopedTokenFilePath("   "), "/tmp/parallel-check-token.json");
});

await test("scopedTokenFilePath: session suffix inserted before the extension — distinct per session", () => {
  equal(scopedTokenFilePath("sess-378a"), "/tmp/parallel-check-token.sess-378a.json");
  equal(scopedTokenFilePath("sess-378b"), "/tmp/parallel-check-token.sess-378b.json");
  ok(scopedTokenFilePath("sess-378a") !== scopedTokenFilePath("sess-378b"), "two sessions never share a path");
  // a custom base is respected (used by the checker-parity + test-mode wiring tests)
  equal(scopedTokenFilePath("s1", "/x/y/token.json"), "/x/y/token.s1.json");
  equal(scopedTokenFilePath("s1", "/x/y/token"), "/x/y/token.s1", "extension-less base gains a trailing .<sid>");
  equal(scopedTokenFilePath(null, "/x/y/custom.json"), "/x/y/custom.json");
});

await test("scopedTokenFilePath: hostile session ids are byte-sanitized (no path separator can ever reach the filename)", () => {
  // the BASE path legitimately contains separators — the assertion is that the
  // SCOPED suffix injects none: the last path segment carries only safe chars.
  equal(scopedTokenFilePath("sess/../../etc"), "/tmp/parallel-check-token.sess_.._.._etc.json");
  const last = scopedTokenFilePath("../evil").split("/").pop()!;
  ok(!last.includes("/"), "no separator reaches the filename segment");
  equal(scopedTokenFilePath("../evil"), "/tmp/parallel-check-token..._evil.json");
  equal(scopedTokenFilePath("a b"), "/tmp/parallel-check-token.a_b.json");
  equal(scopedTokenFilePath("sess\tid"), "/tmp/parallel-check-token.sess_id.json");
});

await test("scopedTokenFilePath: NON-ASCII input is BYTE-wise (multi-byte char → one '_' per utf-8 byte, checker tr parity)", () => {
  // 'é' = 0xC3 0xA9 → 2 bytes → 2 underscores. A code-point regex would emit
  // ONE underscore and drift from the checker's byte-wise tr — the #378 parity
  // contract pins two.
  equal(scopedTokenFilePath("sessé"), "/tmp/parallel-check-token.sess__.json");
});

await test("tokenFile default scopes to the CAPTURED session id (test-mode base; observed via the none-found reason)", () => {
  _resetStateForTest();
  try {
    _setAuditSessionIdForTest("sess-scope-1");
    _setTokenFileForTest(null);
    const r = checkpointTokenOk(makeStep({ name: "check", gate: "checkpoint", token_phase: "plan" }));
    ok(!r.ok, "no token at the scoped path → block");
    ok(r.reason.includes("test-none/token.sess-scope-1.json"), "read default is the SESSION-scoped test-mode path (reason: " + r.reason + ")");
  } finally { _setTokenFileForTest(null); _resetStateForTest(); }
});

await test("tokenFile default WITHOUT a session id → unscoped test-mode base (no-session fallback)", () => {
  _resetStateForTest();
  try {
    _setTokenFileForTest(null);
    const r = checkpointTokenOk(makeStep({ name: "check", gate: "checkpoint", token_phase: "plan" }));
    ok(!r.ok, "no token → block");
    ok(r.reason.includes("test-none/token.json") && !r.reason.includes("test-none/token.sess-"),
      "no session id → unscoped read (reason: " + r.reason + ")");
  } finally { _setTokenFileForTest(null); _resetStateForTest(); }
});

await test("tokenFile: an explicit PARALLEL_CHECK_TOKEN_FILE env override is honored VERBATIM (never session-scoped)", async () => {
  _resetStateForTest();
  const d = tmpDir("tok378env");
  const p = join(d, "custom.json");
  writeFileSync(p, JSON.stringify({ verdict: "CLEAR", phase: "plan", repo: "test-repo", ts: new Date().toISOString() }));
  try {
    _setAuditSessionIdForTest("sess-scope-env");
    await withEnv({ PARALLEL_CHECK_TOKEN_FILE: p }, () => {
      _setTokenFileForTest(null);
      _setRepoForTest("test-repo");
      const r = checkpointTokenOk(makeStep({ name: "check", gate: "checkpoint", token_phase: "plan" }), { enforceBinding: true });
      ok(r.ok, "verbatim env-override token satisfies the checkpoint despite the captured session id");
    });
  } finally { _setTokenFileForTest(null); _setRepoForTest(null); _resetStateForTest(); }
});

await test("#378 cross-session isolation: A's scoped token does NOT satisfy B; B's own token does (no shared-path pass or clobber)", async () => {
  _resetStateForTest();
  const { pi, handlers } = fakePi();
  auditCapture();
  const dir = "/tmp/sequence-enforcer-test-none";
  const fileA = join(dir, "token.sess-378-A.json");
  const fileB = join(dir, "token.sess-378-B.json");
  try {
    await withEnv(GATE_ENV, async () => {
      sequenceEnforcer(pi as any);
      _setRepoForTest("test-repo");
      mkdirSync(dir, { recursive: true });
      // ── session A: a fresh gate session on the same machine ──
      const ctxA = { sessionManager: { getSessionId: () => "sess-378-A" } };
      await handlers.session_start!({ type: "session_start", reason: "startup" }, ctxA);
      _pushSkillForTest("/repo/skills/a/SKILL.md", checkpointSkillSteps(), 0);
      // A's checker run produced a CLEAR token at A's SCOPED default path.
      writeFileSync(fileA, JSON.stringify({ verdict: "CLEAR", phase: "plan", repo: "test-repo", ts: new Date().toISOString() }));
      const resA = await handlers.tool_call!({ toolName: "read", toolCallId: "a1", input: { path: "x" } }, ctxA);
      ok(!(resA && resA.block), "session A advances on ITS OWN scoped token");
      equal(_stackForTest()[0]!.stepIndex, 1, "A advanced past the checkpoint");
      // ── session B starts (fresh session_start resets stack state — mirrors a new process) ──
      const ctxB = { sessionManager: { getSessionId: () => "sess-378-B" } };
      await handlers.session_start!({ type: "session_start", reason: "startup" }, ctxB);
      _pushSkillForTest("/repo/skills/b/SKILL.md", checkpointSkillSteps(), 0);
      // A's token STILL lingers at A's scoped path — B must never see it.
      const blocked = await handlers.tool_call!({ toolName: "bash", toolCallId: "b1", input: { command: "rm -rf /" } }, ctxB);
      ok(blocked && blocked.block, "session B is BLOCKED — A's scoped token does not satisfy B (no cross-session pass)");
      ok(String(blocked.reason).includes("sess-378-B"), "the block reason names B's scoped path, not A's");
      equal(_stackForTest()[0]!.stepIndex, 0, "B did NOT advance on A's token");
      // B writes ITS OWN token → advances (same-repo concurrency both hold tokens, no clobber).
      writeFileSync(fileB, JSON.stringify({ verdict: "CLEAR", phase: "plan", repo: "test-repo", ts: new Date().toISOString() }));
      const resB = await handlers.tool_call!({ toolName: "read", toolCallId: "b2", input: { path: "x" } }, ctxB);
      ok(!(resB && resB.block), "session B advances on ITS OWN scoped token");
      equal(_stackForTest()[0]!.stepIndex, 1, "B advanced past the checkpoint on its own token");
    });
  } finally {
    try { rmSync(fileA, { force: true }); } catch { /* best-effort */ }
    try { rmSync(fileB, { force: true }); } catch { /* best-effort */ }
    auditRelease(); _setRepoForTest(null); _setTokenFileForTest(null); _resetStateForTest();
  }
});

section("#377 enforcement.jsonl reader");

function writeFixture(file: string, lines: string[]) {
  writeFileSync(file, lines.join("\n") + "\n", "utf-8");
}

await test("enforcementLogFile() resolves the real audit path via os.homedir()", () => {
  equal(enforcementLogFile(), join(homedir(), ".pi", "agent", "audit", "enforcement.jsonl"));
  ok(enforcementLogFile().startsWith(homedir()), "derived from os.homedir()");
});

await test("missing file → empty result, zero skipped (tolerant)", () => {
  const r = readEnforcementLog({ file: join(tmpDir("reader-missing"), "enforcement.jsonl") });
  equal(r.entries.length, 0);
  equal(r.skipped, 0);
});

await test("parses valid lines in file order; blank + malformed lines counted as skipped", () => {
  const file = join(tmpDir("reader-parse"), "enforcement.jsonl");
  writeFixture(file, [
    JSON.stringify({ ts: "2026-08-30T01:00:00.000Z", event: "startup", mode: "warn", session_id: "s1" }),
    "",
    "not-json{{{",
    JSON.stringify({ ts: "2026-08-30T02:00:00.000Z", event: "blocked", skill: "/x", session_id: "s2" }),
    JSON.stringify({ ts: "2026-08-30T03:00:00.000Z", event: "allowed", session_id: null }),
  ]);
  const r = readEnforcementLog({ file });
  equal(r.skipped, 1, "only the malformed line is skipped (blank ignored)");
  equal(r.entries.length, 3, "three valid lines parsed");
  equal(r.entries[0]!.event, "startup");
  equal(r.entries[1]!.session_id, "s2");
  equal(r.entries[2]!.session_id, null);
  ok(r.entries[0]!.ts < r.entries[1]!.ts, "file order preserved (chronological)");
});

await test("events filter narrows to the named event(s)", () => {
  const file = join(tmpDir("reader-events"), "enforcement.jsonl");
  writeFixture(file, [
    JSON.stringify({ ts: "2026-08-30T01:00:00.000Z", event: "startup", session_id: "s1" }),
    JSON.stringify({ ts: "2026-08-30T02:00:00.000Z", event: "warn_blocked", session_id: "s1" }),
    JSON.stringify({ ts: "2026-08-30T03:00:00.000Z", event: "blocked", session_id: "s1" }),
  ]);
  const r = readEnforcementLog({ file, events: ["startup", "blocked"] });
  equal(r.entries.length, 2);
  ok(r.entries.every((x) => x.event === "startup" || x.event === "blocked"));
});

await test("events: [] is documented as NO event filter (returns all)", () => {
  const file = join(tmpDir("reader-events-empty"), "enforcement.jsonl");
  writeFixture(file, [
    JSON.stringify({ ts: "2026-08-30T01:00:00.000Z", event: "startup", session_id: "s1" }),
    JSON.stringify({ ts: "2026-08-30T02:00:00.000Z", event: "blocked", session_id: "s2" }),
  ]);
  const r = readEnforcementLog({ file, events: [] });
  equal(r.entries.length, 2, "empty events array = unfiltered (documented semantics)");
});

await test("fail-closed filter input: limit <= 0 and unparseable since return empty (never silently unfiltered)", () => {
  const file = join(tmpDir("reader-failclosed"), "enforcement.jsonl");
  writeFixture(file, [
    JSON.stringify({ ts: "2026-08-30T01:00:00.000Z", event: "startup", session_id: "a" }),
    JSON.stringify({ ts: "2026-08-30T02:00:00.000Z", event: "startup", session_id: "b" }),
  ]);
  // limit 0 / negative → empty, never "no cap"
  equal(readEnforcementLog({ file, limit: 0 }).entries.length, 0, "limit 0 → empty");
  equal(readEnforcementLog({ file, limit: -3 }).entries.length, 0, "negative limit → empty");
  equal(readEnforcementLog({ file, limit: NaN }).entries.length, 0, "limit NaN → empty (NaN <= 0 is false — bare <= 0 would silently drop the cap)");
  equal(readEnforcementLog({ file, limit: Infinity }).entries.length, 0, "limit Infinity → empty (Infinity > 0 is true — requires an isFinite guard)");
  equal(readEnforcementLog({ file, limit: -Infinity }).entries.length, 0, "limit -Infinity → empty");
  // unparseable since → empty, never "every entry since the beginning"
  const bad = readEnforcementLog({ file, since: "not-a-date" });
  equal(bad.entries.length, 0, "unparseable since → empty (fail-closed for the #357-16 gate)");
  equal(bad.skipped, 0);
});

await test("sessionId filter includes exact matches and excludes null + pre-#377 (missing key) lines", () => {
  const file = join(tmpDir("reader-session"), "enforcement.jsonl");
  writeFixture(file, [
    JSON.stringify({ ts: "2026-08-30T01:00:00.000Z", event: "startup", session_id: "want-1" }),
    JSON.stringify({ ts: "2026-08-30T02:00:00.000Z", event: "startup", session_id: null }),
    // pre-#377 line: no session_id key at all
    JSON.stringify({ ts: "2026-08-30T03:00:00.000Z", event: "startup" }),
    JSON.stringify({ ts: "2026-08-30T04:00:00.000Z", event: "startup", session_id: "other" }),
  ]);
  const r = readEnforcementLog({ file, sessionId: "want-1" });
  equal(r.entries.length, 1);
  equal(r.entries[0]!.session_id, "want-1");
});

await test("since filter is inclusive on ISO ts", () => {
  const file = join(tmpDir("reader-since"), "enforcement.jsonl");
  writeFixture(file, [
    JSON.stringify({ ts: "2026-08-30T01:00:00.000Z", event: "startup", session_id: "a" }),
    JSON.stringify({ ts: "2026-08-30T02:00:00.000Z", event: "startup", session_id: "b" }),
  ]);
  const r = readEnforcementLog({ file, since: "2026-08-30T02:00:00.000Z" });
  equal(r.entries.length, 1);
  equal(r.entries[0]!.session_id, "b", "boundary ts included (inclusive since)");
});

await test("limit returns the most recent N matching entries", () => {
  const file = join(tmpDir("reader-limit"), "enforcement.jsonl");
  writeFixture(file, [
    JSON.stringify({ ts: "2026-08-30T01:00:00.000Z", event: "startup", session_id: "a" }),
    JSON.stringify({ ts: "2026-08-30T02:00:00.000Z", event: "startup", session_id: "b" }),
    JSON.stringify({ ts: "2026-08-30T03:00:00.000Z", event: "startup", session_id: "c" }),
    JSON.stringify({ ts: "2026-08-30T04:00:00.000Z", event: "startup", session_id: "d" }),
  ]);
  const r = readEnforcementLog({ file, limit: 2 });
  equal(r.entries.length, 2);
  equal(r.entries[0]!.session_id, "c", "limit keeps the most recent entries");
  equal(r.entries[1]!.session_id, "d");
});

await test("reader is the swarm-side positive-audit gate primitive: startup sessions since a ts", () => {
  const file = join(tmpDir("reader-gate"), "enforcement.jsonl");
  writeFixture(file, [
    JSON.stringify({ ts: "2026-08-30T01:00:00.000Z", event: "startup", mode: "gate", session_id: "pre" }),
    JSON.stringify({ ts: "2026-08-30T02:00:00.000Z", event: "startup", mode: "warn", session_id: "post1" }),
    JSON.stringify({ ts: "2026-08-30T03:00:00.000Z", event: "startup", mode: "warn", session_id: "post2" }),
  ]);
  // #357 criterion 16: name exactly which sessions started after a deploy ts.
  const r = readEnforcementLog({ file, since: "2026-08-30T02:00:00.000Z", events: ["startup"] });
  const ids = r.entries.map((x) => x.session_id).sort();
  deepEqual(ids, ["post1", "post2"], "post-deploy startup sessions are named exactly");
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
