/**
 * headless-lane.test.ts — #2965: a headless lane in a LINKED WORKTREE gets the
 * affordances `lane.sh` exports, however it was launched — and the HUB does not.
 *
 * Run: npx tsx extensions/shared/headless-lane.test.ts
 *      npx tsx extensions/shared/headless-lane.test.ts --mutations
 *
 * ── WHAT MAKES THIS NON-VACUOUS ────────────────────────────────────────────
 * The two arms are built from REAL repositories, not from a stubbed predicate:
 * a hub with one commit and two `git worktree add` links, so the structural
 * test (`--git-dir` ≠ `--git-common-dir`) is exercised against the geometry git
 * actually produces. Each arm is pinned at BOTH levels, because either alone
 * would leave the other free to regress silently:
 *
 *   derivation  the contract `deriveLaneContract` returns for that cwd
 *   wiring      the decision `skill-enforcer`'s `tool_call` handler actually
 *               makes about `git commit` — the command the measured failure
 *               blocked. Arm B uses the SHIPPED manifest
 *               (`enforcement/dangerous-ops.txt`), so the rule under test is the
 *               real `commit-workflow` hard rule and not a fixture.
 *
 * `--mutations` then reintroduces each defect into a TEMP copy of the module (or
 * inverts the contract through the test seam) and requires the paired assertion
 * to go RED, printing that assertion's failure verbatim. A pin that cannot fail
 * is not a pin.
 *
 * Zero-dep by construction: `node:*`, `./headless-lane.js`, `../skill-enforcer.js`
 * and git on PATH. No npm ci.
 */
import { ok, equal } from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

import {
  deriveLaneContract,
  applyLaneContract,
  _setLaneContractForTest,
  _resetLaneContractForTest,
  type LaneContract,
} from "./headless-lane.js";
import hook, { _setSkillReadsFileForTest } from "../skill-enforcer.js";

const HERE = resolve(import.meta.dirname);

let passed = 0;
let failed = 0;
const failures: string[] = [];
async function test(name: string, fn: () => void | Promise<void>) {
  try {
    await fn();
    passed += 1;
    console.log(`  ✅ ${name}`);
  } catch (err) {
    failed += 1;
    failures.push(name);
    console.log(`  ❌ ${name}\n     ${err instanceof Error ? err.message : String(err)}`);
  }
}
function section(name: string) {
  console.log(`\n${name}`);
}

const TMP: string[] = [];
function tmpDir(prefix: string): string {
  const d = realpathSync(mkdtempSync(join(tmpdir(), prefix)));
  TMP.push(d);
  return d;
}
function cleanup() {
  // One seam is enough: `_setLaneContractForTest(null)` and
  // `_resetLaneContractForTest()` are both `cached = null` — the first was a dead
  // no-op statement (review cycle 2, P2), the same class round 1 removed.
  _resetLaneContractForTest();
  for (const d of TMP) rmSync(d, { recursive: true, force: true });
}
function git(args: string[], cwd: string): string {
  return execFileSync("git", args, { cwd, encoding: "utf-8", stdio: ["ignore", "pipe", "pipe"] }).trim();
}

// ── The fixture geometry: a real hub with real linked worktrees ──────────────
const FIXTURE = (() => {
  const base = tmpDir("headless-lane-");
  const hub = join(base, "hub");
  mkdirSync(hub, { recursive: true });
  git(["init", "-q", "-b", "main"], hub);
  git(["config", "user.email", "lane-test@example.invalid"], hub);
  git(["config", "user.name", "lane test"], hub);
  writeFileSync(join(hub, "README.md"), "fixture\n");
  git(["add", "README.md"], hub);
  git(["commit", "-q", "-m", "fixture base"], hub);
  // `w-10137` + a branch carrying NO digits: the TAG can only come from the
  // worktree DIRECTORY name, which is how the fleet names them.
  const wtDirNamed = join(hub, ".worktrees", "w-10137");
  git(["worktree", "add", "-q", "-b", "fix/thing", wtDirNamed], hub);
  // `scratch` + a branch carrying the issue: the TAG can only come from the BRANCH.
  const wtBranchNamed = join(hub, ".worktrees", "scratch");
  git(["worktree", "add", "-q", "-b", "fix/20248-bump", wtBranchNamed], hub);
  // A checkout whose git dir is NOT `<top>/.git`: `--separate-git-dir` gives
  // `git-dir == git-common-dir` (so it is NOT a linked worktree, and it is NOT a
  // lane) while its top level resolves. Used by A5b: the guarded verdict must not
  // claim "the HUB" for a shape that is not the hub (review cycle 3, F1).
  const sepTop = join(base, "sep");
  const sepGit = join(base, "sep.git");
  mkdirSync(sepTop, { recursive: true });
  git(["init", "-q", "--separate-git-dir", sepGit, "-b", "main"], sepTop);
  // A MAIN checkout whose `.git` is a SYMLINK. `gitDir` is realpath'd, so a
  // comparison against an unresolved `<top>/.git` measured a real path against a
  // LINK path and named this a "non-worktree checkout" — same misreport as A5b, in
  // a narrower shape (review cycle 4, F2). Pinned by A5d.
  const symHub = join(base, "symhub");
  mkdirSync(symHub, { recursive: true });
  git(["init", "-q", "-b", "main"], symHub);
  execFileSync("mv", [join(symHub, ".git"), join(base, "realgit-sym")], { encoding: "utf-8" });
  execFileSync("ln", ["-s", join("..", "realgit-sym"), join(symHub, ".git")], { encoding: "utf-8" });
  return { base, hub, wtDirNamed, wtBranchNamed, sepTop, sepGit, symHub, wtGitDir: join(hub, ".git", "worktrees", "w-10137") };
})();

const PRINT_ENV = { PI_MODE: "print" } as Record<string, string | undefined>;
const INTERACTIVE_ENV = {} as Record<string, string | undefined>;
const BARE_ARGV = ["node", "pi"];

/** A guarded contract, for the gate-suite posture (mirrors skill-enforcer.test.ts). */
function guardedContract(): LaneContract {
  return {
    headless: false, linkedWorktree: false, lane: false, cwd: process.cwd(),
    topLevel: null, gitDir: null, commonDir: null, branch: null, kind: null, tag: null,
    why: "pinned by the suite",
  };
}

// ── fake pi host, and a fresh gate session ──────────────────────────────────
type Handler = (event: unknown, ctx: unknown) => unknown;
interface FakePi {
  on(name: string, fn: Handler): void;
  fire(name: string, event: unknown): Promise<any>;
}
function makePi(): FakePi {
  const handlers: Record<string, Handler[]> = {};
  return {
    on(name: string, fn: Handler) {
      (handlers[name] ??= []).push(fn);
    },
    async fire(name: string, event: unknown) {
      let last: unknown;
      for (const fn of handlers[name] ?? []) {
        const res = await fn(event, {});
        if (res && (res as { block?: boolean }).block) return res;
        if (res) last = res;
      }
      return last;
    },
  };
}

/**
 * A fresh, UNBYPASSED skill-enforcer session with `contract` pinned as the
 * process's derived contract. Every launcher affordance is scrubbed first, so
 * the only channel left is the derivation — the thing under test.
 */
async function newGate(contract: LaneContract): Promise<FakePi> {
  delete process.env.SKILL_ENFORCER_DISABLED;
  delete process.env.AGENT_ALLOW_MAIN_EDITS;
  delete process.env.ELDATO_ALLOW_MAIN_EDITS;
  _setSkillReadsFileForTest(join(tmpDir("hl-reads-"), "skill-reads.json"));
  _setLaneContractForTest(contract);
  const pi = makePi();
  hook(pi as never);
  await pi.fire("session_start", {});
  return pi;
}

/** Does the shipped manifest's `commit-workflow` gate refuse `git commit` here? */
async function commitDecision(contract: LaneContract): Promise<{ blocked: boolean; reason: string }> {
  const pi = await newGate(contract);
  const res = await pi.fire("tool_call", { toolName: "bash", input: { command: "git commit -m 'lane proof'" } });
  const blocked = Boolean(res && (res as { block?: boolean }).block);
  return { blocked, reason: blocked ? String((res as { reason?: string }).reason ?? "") : "" };
}

// ════════════════════════════════════════════════════════════════════════════
/**
 * Run one real `skill-enforcer` PROCESS in a linked worktree and return the lines
 * it logged. Two things make a child necessary: the announcement state
 * (`DERIVED_ANNOUNCED_AT_LOAD`) is module-level, and this suite imports that module
 * at startup — so in-process the load site has already run, with the RUNNER's cwd
 * and env, not the fixture's.
 *
 * Every launcher affordance is scrubbed unless `extraEnv` puts one back, so the
 * DERIVATION is the only thing that can lift the gates.
 */
function announceProbe(extraEnv: Record<string, string> = {}): { loadError: string | null; logs: string[]; status: number } {
  const dir = tmpDir("hl-announce-");
  const driver = join(dir, "driver.mjs");
  const reads = join(dir, "skill-reads.json");
  const modUrl = pathToFileURL(join(HERE, "..", "skill-enforcer.ts")).href;
  writeFileSync(
    driver,
    `
const logs = [];
const ol = console.log, oe = console.error;
console.log = (...a) => logs.push("log: " + a.join(" "));
console.error = (...a) => logs.push("err: " + a.join(" "));
let loadError = null;
(async () => {
  try {
    const ns = await import(${JSON.stringify(modUrl)});
    const hook = typeof ns.default === "function" ? ns.default : ns.default && ns.default.default;
    if (typeof ns._setSkillReadsFileForTest === "function") ns._setSkillReadsFileForTest(${JSON.stringify(reads)});
    const handlers = {};
    const pi = { on(n, fn) { (handlers[n] = handlers[n] || []).push(fn); } };
    hook(pi);
    for (const fn of handlers["session_start"] || []) await fn({}, {});
  } catch (e) { loadError = String((e && e.stack) || e); }
  console.log = ol; console.error = oe;
  process.stdout.write(JSON.stringify({ loadError, logs }));
})();
`,
  );
  const env: NodeJS.ProcessEnv = { ...process.env };
  for (const k of [
    "SKILL_ENFORCER_DISABLED",
    "LOOP_ENFORCER_DISABLED",
    "AGENT_ALLOW_MAIN_EDITS",
    "ELDATO_ALLOW_MAIN_EDITS",
    "KIND",
    "TAG",
    "TASK_HEARTBEAT",
    "AGENT_SKIP_REVIEW_GATE",
    "PI_MODE",
  ]) delete env[k];
  // print mode carries it: the child's argv has no `-p`, so `PI_MODE` is the only
  // channel.
  env.PI_MODE = "print";
  for (const [k, v] of Object.entries(extraEnv)) env[k] = v;
  const res = spawnSync("npx", ["tsx", driver], {
    cwd: FIXTURE.wtDirNamed,
    env,
    encoding: "utf8",
    timeout: 240000,
  });
  const stdout = res.stdout ?? "";
  const start = stdout.indexOf("{");
  if (start < 0) return { loadError: `no JSON report — status ${res.status}; stderr: ${(res.stderr ?? "").slice(0, 600)}`, logs: [], status: res.status ?? -1 };
  const report = JSON.parse(stdout.slice(start)) as { loadError: string | null; logs: string[] };
  return { ...report, status: res.status ?? -1 };
}

async function main() {
  // ── A. the derivation itself: what a process can observe about itself ─────
  section("A. derivation — headless + LINKED worktree is a lane; the hub is not");

  await test("A1 — headless in a LINKED worktree derives the lane contract (structural, not a path match)", () => {
    const c = deriveLaneContract({ env: PRINT_ENV, argv: BARE_ARGV, cwd: FIXTURE.wtDirNamed });
    ok(c.headless, `headless: expected true (PI_MODE=print), got ${c.headless}`);
    ok(
      c.linkedWorktree,
      `linkedWorktree: expected true for ${FIXTURE.wtDirNamed}, got false — git-dir=${c.gitDir} common-dir=${c.commonDir}`,
    );
    ok(c.lane, `lane: expected true (headless in a linked worktree), got false — ${c.why}`);
    equal(c.kind, "lane", "kind: a derived lane reports KIND=lane");
  });

  await test("A2 — the same headless run in the HUB checkout derives NO lane (the guarded arm)", () => {
    const c = deriveLaneContract({ env: PRINT_ENV, argv: BARE_ARGV, cwd: FIXTURE.hub });
    ok(c.headless, "headless: expected true — the hub arm must be reached by a HEADLESS run, not by an interactive one");
    equal(c.linkedWorktree, false, `linkedWorktree: expected false for the hub ${FIXTURE.hub}, got true — git-dir=${c.gitDir}`);
    equal(c.lane, false, `lane: expected false — a headless run in the HUB has no lane contract, got true (${c.why})`);
    ok(/HUB/.test(c.why), `why: the guarded verdict must NAME the hub so an operator can check it, got ${JSON.stringify(c.why)}`);
  });

  await test("A3 — an INTERACTIVE session in a linked worktree is not a lane either (mode, not just directory)", () => {
    const c = deriveLaneContract({ env: INTERACTIVE_ENV, argv: BARE_ARGV, cwd: FIXTURE.wtDirNamed });
    equal(c.headless, false, "headless: expected false for an interactive argv with no PI_MODE");
    equal(c.lane, false, "lane: an interactive session in a worktree is not a lane");
    // Review cycle 3, F3: the fields are UNMEASURED for an interactive session (no
    // git is spawned — that is the documented cost decision). Pin that, so a
    // consumer (#2966) cannot read `linkedWorktree: false` as "not a worktree".
    equal(
      c.linkedWorktree,
      false,
      "linkedWorktree: an interactive session reports false — UNMEASURED, because no probe runs; consumers must gate on headless/lane, never on this field alone",
    );
    equal(c.topLevel, null, "topLevel: an interactive session is unmeasured, so this is null — not `no top level exists`");
    equal(c.gitDir, null, "gitDir: an interactive session is unmeasured, so this is null");
  });

  await test("A5b — a checkout whose git dir is NOT <top>/.git is guarded, and the verdict does NOT claim it is the HUB", () => {
    const c = deriveLaneContract({ env: PRINT_ENV, argv: BARE_ARGV, cwd: FIXTURE.sepTop });
    equal(c.lane, false, `lane: expected false for a --separate-git-dir checkout (git-dir ${c.gitDir} == common-dir ${c.commonDir}), got true`);
    ok(c.topLevel, `topLevel: expected the checkout to resolve, got ${c.topLevel} — this arm must not be the "no checkout" one`);
    equal(
      /HUB/.test(c.why),
      false,
      `why: must not name ${FIXTURE.sepTop} as the HUB — HUB is reserved for a MAIN checkout, where the git dir IS <top>/.git (review cycle 3, F1). Got ${JSON.stringify(c.why)}`,
    );
    ok(/non-worktree checkout/.test(c.why), `why: the guarded verdict must name the shape it measured, got ${JSON.stringify(c.why)}`);
  });

  await test("A5c — a cwd inside a linked worktree's GIT DIR derives the lane, and its `why` prints no literal `null`", () => {    const c = deriveLaneContract({ env: PRINT_ENV, argv: BARE_ARGV, cwd: FIXTURE.wtGitDir });
    // The structural test is git-dir ≠ common-dir; both halves resolve here, so the
    // arm is the lane one and the process can act on that worktree's branch. Only
    // `--show-toplevel` is unavailable (there is no working tree), and it is
    // NAMING-ONLY — never part of the predicate (review cycle 3, F2).
    equal(c.lane, true, `lane: expected true inside a linked worktree's git dir (git-dir ${c.gitDir} ≠ common-dir ${c.commonDir}), got false — ${c.why}`);
    equal(c.topLevel, null, "topLevel: git reports no working tree from a git dir, so this is null");
    equal(
      /\bnull\b/.test(c.why),
      false,
      `why: the operator-facing line must not interpolate a null top level, got ${JSON.stringify(c.why)}`,
    );
    ok(/no working tree to name/.test(c.why), `why: it must say WHY there is no path, got ${JSON.stringify(c.why)}`);
  });

  await test("A5d — a MAIN checkout whose `.git` is a SYMLINK is still named the HUB", () => {
    // `gitDir` is realpath'd, so the `HUB` comparison must be too: `<top>/.git` here
    // is a LINK to `<base>/realgit-sym`, and comparing against the unresolved path
    // called a genuine main checkout a "non-worktree checkout" (review cycle 4, F2).
    const c = deriveLaneContract({ env: PRINT_ENV, argv: BARE_ARGV, cwd: FIXTURE.symHub });
    equal(c.lane, false, `lane: expected false — a main checkout is not a lane, got true (${c.why})`);
    ok(
      /HUB/.test(c.why),
      `why: a main checkout whose .git is a symlink is STILL the hub, got ${JSON.stringify(c.why)} — git-dir=${c.gitDir}`,
    );
  });

  await test("A4 — a bare `pi -p` (no PI_MODE) is headless via argv, which is the shape that failed", () => {
    const c = deriveLaneContract({ env: INTERACTIVE_ENV, argv: ["node", "pi", "-p", "--provider", "deepseek"], cwd: FIXTURE.wtDirNamed });
    ok(c.headless, "headless: expected true from argv `-p` alone (pi never sets PI_MODE)");
    ok(c.lane, `lane: expected true for a bare \`pi -p\` in a linked worktree — ${c.why}`);
  });

  await test("A5 — a non-git cwd fails CLOSED: headless, but not a lane", () => {
    const plain = tmpDir("hl-plain-");
    const c = deriveLaneContract({ env: PRINT_ENV, argv: BARE_ARGV, cwd: plain });
    equal(c.linkedWorktree, false, "linkedWorktree: a directory that is not a git checkout is not a linked worktree");
    equal(c.lane, false, "lane: expected false (fail closed) — an unknown checkout is the guarded arm");
  });

  await test("A6 — TAG is inferred from the worktree DIRECTORY when the branch carries no issue", () => {
    const c = deriveLaneContract({ env: PRINT_ENV, argv: BARE_ARGV, cwd: FIXTURE.wtDirNamed });
    equal(c.tag, "10137", `tag: expected 10137 from worktree dir "w-10137" (branch ${c.branch} has no digits)`);
  });

  await test("A7 — TAG falls back to the BRANCH when the worktree directory names nothing", () => {
    const c = deriveLaneContract({ env: PRINT_ENV, argv: BARE_ARGV, cwd: FIXTURE.wtBranchNamed });
    equal(c.tag, "20248", `tag: expected 20248 from branch ${c.branch} (dir "scratch" carries no issue)`);
  });

  await test("A8 — a launcher-set KIND/TAG WINS over the inference, and a guarded session gets neither", () => {
    const env: Record<string, string | undefined> = { PI_MODE: "print", KIND: "fixer", TAG: "9999" };
    const c = deriveLaneContract({ env, argv: BARE_ARGV, cwd: FIXTURE.wtDirNamed });
    equal(c.kind, "fixer", "kind: the launcher's KIND must not be overwritten by the derivation");
    equal(c.tag, "9999", "tag: the launcher's TAG must not be overwritten by the derivation");
    const applied = applyLaneContract(env, c);
    equal(applied.kind, null, "applyLaneContract: nothing is applied when the launcher already set both");
    // …and the guarded arm never writes anything, even when both are empty.
    const guardedEnv: Record<string, string | undefined> = { PI_MODE: "print" };
    const hub = deriveLaneContract({ env: guardedEnv, argv: BARE_ARGV, cwd: FIXTURE.hub });
    equal(applyLaneContract(guardedEnv, hub).kind, null, "applyLaneContract: the HUB arm must write no KIND");
    equal(guardedEnv.KIND, undefined, `applyLaneContract: the HUB arm must leave KIND unset, got ${guardedEnv.KIND}`);
  });

  await test("A9 — a SUPERVISED child (TASK_HEARTBEAT=1) keeps the bypass but is given NO lane audience", () => {
    const childEnv: Record<string, string | undefined> = { PI_MODE: "print", TASK_HEARTBEAT: "1" };
    const c = deriveLaneContract({ env: childEnv, argv: BARE_ARGV, cwd: FIXTURE.wtDirNamed });
    ok(c.lane, "lane: a supervised child in a linked worktree still derives the bypass (never dependent on an ambient var being ABSENT)");
    ok(/NOT inferred/.test(c.why), `why: the verdict must say KIND/TAG were not inferred, got ${JSON.stringify(c.why)}`);
    // The CONTRACT must not claim the inference it withholds: a `kind: "lane"`
    // here would contradict `why` in the same log line, and would be an audience
    // the child is not disclosed to. Asserted as a FIELD, not as prose.
    equal(c.kind, null, `kind: expected null for a supervised child (no audience inferred), got ${JSON.stringify(c.kind)}`);
    equal(c.tag, null, `tag: expected null for a supervised child (no audience inferred), got ${JSON.stringify(c.tag)}`);
    equal(applyLaneContract(childEnv, c).kind, null, "applyLaneContract: a supervised child must not be relabelled KIND=lane");
    equal(childEnv.KIND, undefined, `a supervised child must keep KIND unset, got ${childEnv.KIND}`);
    equal(childEnv.TAG, undefined, `a supervised child must keep TAG unset, got ${childEnv.TAG}`);
  });

  await test("A9b — an INHERITED KIND (the child of a derived lane) is KEPT as observed, and still not inferred", () => {
    // Review cycle 1, P1: `builtin-tools` spreads `process.env` into a child's
    // env, so a `task` child of a DERIVED lane already carries the parent's
    // `KIND=lane`/`TAG` — a shape A9 (which builds the child env from scratch)
    // can never produce. Pinned here so nobody reads A9 as covering inheritance.
    //
    // The distinction is deliberate and load-bearing: A8 says a launcher-set
    // value WINS, and this value was set by the launcher (the parent process).
    // So `kind` reports what was OBSERVED and `why` truthfully says nothing was
    // INFERRED — the two agree. What the child is then DISCLOSED as is
    // `review-enforcer`'s audience model, which is agent-infra#2966's subject and
    // is NOT decided here; this leg exists so the composition is visible.
    const inheritedEnv: Record<string, string | undefined> = {
      PI_MODE: "print",
      TASK_HEARTBEAT: "1",
      KIND: "lane",
      TAG: "10137",
    };
    const c = deriveLaneContract({ env: inheritedEnv, argv: BARE_ARGV, cwd: FIXTURE.wtDirNamed });
    equal(c.kind, "lane", "kind: an INHERITED KIND is OBSERVED and kept (a launcher-set value always wins — A8)");
    equal(c.tag, "10137", "tag: an INHERITED TAG is kept, not replaced by the inferred one");
    ok(/NOT inferred/.test(c.why), `why: nothing was INFERRED, which stays true beside an observed kind, got ${JSON.stringify(c.why)}`);
    equal(applyLaneContract(inheritedEnv, c).kind, null, "applyLaneContract: still writes nothing over an inherited value");
  });

  await test("A10 — a supervised child in the HUB is STILL guarded (the marker never touches the lane predicate)", async () => {
    // The fail-open this pins: "supervised ⇒ lane:true regardless of checkout"
    // would lift the hub gate for every task child in the hub, while A9 only
    // covers the linked-worktree arm and A2/B2 use a non-child env — so all
    // three could stay green over it.
    const childEnv: Record<string, string | undefined> = { PI_MODE: "print", TASK_HEARTBEAT: "1" };
    const c = deriveLaneContract({ env: childEnv, argv: BARE_ARGV, cwd: FIXTURE.hub });
    equal(c.linkedWorktree, false, `linkedWorktree: expected false for the hub ${FIXTURE.hub}, got true`);
    equal(c.lane, false, `lane: expected false — TASK_HEARTBEAT must not make the HUB a lane, got true (${c.why})`);
    const { blocked } = await commitDecision(c);
    ok(blocked, "expected `git commit` to be blocked for a supervised child in the HUB — the hub gate was lifted");
  });

  // ── A11 — `GIT_*` cannot relocate the answer (T1, review cycle 1 P0) ──────
  await test("A11 — an exported GIT_DIR at a linked worktree's gitdir does NOT turn the HUB into a lane", () => {
    // The window A2 does not cover: `git rev-parse` honours an exported
    // `GIT_DIR`, which OVERRIDES the cwd. Measured with real git from the hub —
    // `--git-dir` = <hub>/.git/worktrees/w-10137, `--git-common-dir` = <hub>/.git,
    // `--show-toplevel` = <hub> — so an UNSCRUBBED probe derives `lane: true` for
    // a process sitting in the hub and lifts every skill gate there. The vector is
    // proved real below before the derivation is asserted against it, so this
    // test cannot pass by being vacuous.
    const gitDir = join(FIXTURE.hub, ".git", "worktrees", "w-10137");
    const saved = { GIT_DIR: process.env.GIT_DIR, PI_MODE: process.env.PI_MODE };
    process.env.GIT_DIR = gitDir;
    process.env.PI_MODE = "print";
    try {
      const raw = (flag: string) =>
        execFileSync("git", ["rev-parse", flag], {
          cwd: FIXTURE.hub,
          env: { ...process.env, GIT_DIR: gitDir } as NodeJS.ProcessEnv,
          encoding: "utf-8",
          stdio: ["ignore", "pipe", "ignore"],
        }).trim();
      const rawGitDir = realpathSync(resolve(FIXTURE.hub, raw("--git-dir")));
      const rawCommonDir = realpathSync(resolve(FIXTURE.hub, raw("--git-common-dir")));
      ok(
        rawGitDir !== rawCommonDir,
        `VECTOR NOT REAL: git under GIT_DIR=${gitDir} must report two DIFFERENT dirs from the hub, got ${rawGitDir} and ${rawCommonDir} — this test proves nothing unless it does`,
      );
      // …and the derivation must still refuse to call the HUB a lane. It reads
      // process.env here (no `env` passed) because THAT is the real call site.
      const c = deriveLaneContract({ argv: BARE_ARGV, cwd: FIXTURE.hub });
      equal(
        c.linkedWorktree,
        false,
        `linkedWorktree: expected false for the hub with GIT_DIR=${gitDir} exported — the probe must not be relocatable (git-dir=${c.gitDir} common=${c.commonDir})`,
      );
      equal(c.lane, false, `lane: expected false — an exported GIT_DIR must not derive a lane in the HUB, got true (${c.why})`);
      // The same vector must not land through the TEST SEAM either: `options.env`
      // has to be the env the probes actually run with, or the pin above is the
      // only thing between an inherited GIT_DIR and the hub gate.
      const viaSeam = deriveLaneContract({ env: { ...PRINT_ENV, GIT_DIR: gitDir }, argv: BARE_ARGV, cwd: FIXTURE.hub });
      equal(viaSeam.lane, false, `lane: expected false with GIT_DIR supplied through options.env, got true (${viaSeam.why})`);
    } finally {
      if (saved.GIT_DIR === undefined) delete process.env.GIT_DIR;
      else process.env.GIT_DIR = saved.GIT_DIR;
      if (saved.PI_MODE === undefined) delete process.env.PI_MODE;
      else process.env.PI_MODE = saved.PI_MODE;
    }
  });

  await test("A12 — the derived-lane announcement is ONE line per process: the LOAD site, and never also `session_start`", () => {
    // ⛔ Why this has to be a CHILD PROCESS (review cycle 3, F4): the announcement
    // state (`DERIVED_ANNOUNCED_AT_LOAD`) is module-level in skill-enforcer, and this
    // suite imports that module at startup — so in-process the load site has already
    // run, with the RUNNER's cwd and env, not the fixture's. Only a child, started in
    // a linked worktree, exercises both sites as one process's log.
    //
    // The defect this pins is the round-2 one: both sites interpolated the same `why`,
    // so a raw `pi -p` in a linked worktree printed the identical sentence twice (#172
    // is the class). The assertions below discriminate in BOTH failure directions — a
    // flag that is never set leaves 2 lines (assert 2), a flag that is INVERTED leaves
    // 1 line but the wrong SITE (asserts 3 and 4). Both were measured RED against a
    // mutated `skill-enforcer.ts` before this pin was committed: dropping
    // `DERIVED_ANNOUNCED_AT_LOAD = true` → `A12 ❌` (2 lines); flipping the
    // `session_start` condition to `else if (DERIVED_ANNOUNCED_AT_LOAD)` → `A12 ❌`
    // (one line, wrong site). A pin that cannot fail is not a pin.
    const report = announceProbe();
    ok(!report.loadError, `the child failed to load skill-enforcer: ${report.loadError}`);
    const logs = report.logs;
    const why = logs.filter((l) => /headless in linked worktree/.test(l));
    equal(
      why.length,
      1,
      `the same derivation line must appear EXACTLY ONCE in one process's log (a flag that is never set prints it twice), got ${why.length}:\n     ${why.join("\n     ")}\n   full log:\n     ${logs.join("\n     ")}`,
    );
    ok(
      /^err: .*Lane contract DERIVED/.test(why[0]),
      `the ONE line must be the module-load site (\`Lane contract DERIVED\`, stderr) — an INVERTED flag leaves one line at the wrong site. Got ${JSON.stringify(why[0])}`,
    );
    equal(
      logs.filter((l) => /Disabled — derived lane contract/.test(l)).length,
      0,
      `\`session_start\` must NOT repeat the derived \`why\` when the load site already announced it. Full log:\n     ${logs.join("\n     ")}`,
    );
  });

  await test("A12b — a launcher affordance WITHOUT KIND/TAG still prints ONE line (the round-4 duplicate)", () => {
    // ⛔ The shape round 3's pin could not see (review cycle 4, F1): the load site
    // fires because it INFERRED `KIND=lane`, and `session_start` ALSO fires because
    // the bypass is true via an env var — two lines for one process. `lane.sh`,
    // `fix-one.sh` and `merge-one.sh` all export KIND/TAG so they never hit it, but a
    // hand-run `pi -p` using the escape hatch this module prints DOES. The load line
    // already says the gates are off for this process, so a second, barer line adds
    // nothing — it is the #172 added-startup-line class.
    //
    // Measured RED against a mutated `skill-enforcer.ts` (the `viaEnv` branch restored
    // ahead of the `DERIVED_ANNOUNCED_AT_LOAD` guard): `A12b ❌` on the bare-`Disabled`
    // assertion. It also caught this pin's own first attempt — a regex containing the
    // pause glyph, whose bytes had been mangled in transit, matched nothing and passed
    // vacuously. The match is ASCII-only (`/Disabled$/`) for that reason.
    const report = announceProbe({ SKILL_ENFORCER_DISABLED: "1" });
    ok(!report.loadError, `the child failed to load skill-enforcer: ${report.loadError}`);
    const logs = report.logs;
    const why = logs.filter((l) => /headless in linked worktree/.test(l));
    equal(
      why.length,
      1,
      `expected the derived announcement EXACTLY ONCE, got ${why.length}. Full log:\n     ${logs.join("\n     ")}`,
    );
    equal(
      logs.filter((l) => /Disabled$/.test(l)).length,
      0,
      `a bare \`Disabled\` line must not be added when the load site already named the derivation. Full log:\n     ${logs.join("\n     ")}`,
    );
  });

  await test("A13 — the GIT_* scrub list has THREE copies, and they AGREE (drift here is the M3 fail-open returned)", () => {
    // The list cannot be shared across TypeScript, Python and shell, so the module
    // comment names every copy. A comment cannot go red; this can. A new relocating
    // variable added to one copy and not the others restores the measured fail-open
    // (hub + exported `GIT_DIR` ⇒ `lane: true`), so the three are compared here.
    // Measured RED by dropping `GIT_COMMON_DIR` from box-status.sh's `unset` line.
    const repo = resolve(HERE, "..", "..");
    const names = (src: string, re: RegExp, what: string): string[] => {
      const block = src.match(re);
      ok(block, `the ${what} copy of the GIT_* list no longer matches this pin's anchor (${re}) — reformatting it silently disables the drift gate`);
      const found = [...block![1].matchAll(/["']([A-Z][A-Z0-9_]*)["']/g)].map((m) => m[1]);
      ok(found.length > 0, `the ${what} copy of the GIT_* list parsed as EMPTY — a gate over nothing certifies nothing`);
      return found;
    };
    const ts = names(readFileSync(join(HERE, "headless-lane.ts"), "utf8"), /const GIT_ENV_DROP = \[([\s\S]*?)\] as const/, "headless-lane.ts");
    const py = names(
      readFileSync(join(repo, "scripts", "orchestrator-harness", "merge-reminder.py"), "utf8"),
      /GIT_ENV_DROP\s*=\s*\(([\s\S]*?)\)/,
      "merge-reminder.py",
    );
    const shSrc = readFileSync(join(repo, "scripts", "orchestrator-harness", "box-status.sh"), "utf8");
    const unsetLines = [...shSrc.matchAll(/^unset\s+((?:GIT_[A-Z0-9_]+\s*)+)$/gm)];
    equal(unsetLines.length, 1, `expected exactly one \`unset GIT_*\` line in box-status.sh, got ${unsetLines.length}`);
    const sh = unsetLines[0][1].trim().split(/\s+/);
    const norm = (l: string[]) => [...new Set(l)].sort();
    const want = norm(ts).join(" ");
    equal(norm(py).join(" "), want, `merge-reminder.py's GIT_ENV_DROP drifted from headless-lane.ts — update BOTH (the copies are listed in the module comment)`);
    equal(norm(sh).join(" "), want, `box-status.sh's \`unset\` list drifted from headless-lane.ts — update BOTH (the copies are listed in the module comment)`);
  });

  await test("A14 — the hub-write guard's SECOND copy of this predicate is still UN-SCRUBBED (known gap #2993) — flipping this pin means the gap closed", () => {
    // A13 keeps the relocation list in step; it says nothing about the file that
    // re-implements this predicate with NO list at all, so it can never catch that
    // copy. Pinning the GAP (not a guarantee) is the point: `headless-lane.ts`
    // scrubs, `main-worktree-guard/classify-git.mjs` does not, and a reader who
    // reads only the first would conclude the vector is closed repo-wide.
    //
    // Measured for #2993 (real git, throwaway repo): from the HUB with
    // `GIT_DIR=<hub>/.git/worktrees/w1`, `--git-dir` → the worktree's git dir and
    // `--git-common-dir` → `<hub>/.git`, i.e. two different directories, so that
    // copy answers "linked worktree" for the hub and `isWorktreeCwdWrite` returns
    // true — the hub-write gate returns early. This assertion is deliberately
    // RED-when-fixed: when #2993 lands, delete it, close the issue, and correct the
    // `headless-lane.ts` header paragraph that names it.
    const repo = resolve(HERE, "..", "..");
    const src = readFileSync(join(repo, "extensions", "main-worktree-guard", "classify-git.mjs"), "utf8");
    const block = src.match(/export function gitCheckoutIsLinkedWorktree\(cwd\) \{([\s\S]*?)\n\}/);
    ok(
      block,
      "gitCheckoutIsLinkedWorktree is no longer in classify-git.mjs — if it was moved or removed, re-measure it and update BOTH this pin and #2993 (do not just delete the assertion)",
    );
    const body = block![1];
    ok(body.includes("git rev-parse --git-dir"), "the pinned function no longer runs the `--git-dir` probe this gap is about — re-anchor the pin before trusting it");
    ok(body.includes("git rev-parse --git-common-dir"), "the pinned function no longer runs the `--git-common-dir` probe this gap is about — re-anchor the pin before trusting it");
    equal(
      /\benv\s*:/.test(body),
      false,
      "classify-git.mjs's gitCheckoutIsLinkedWorktree now passes an `env:` — the #2993 gap looks CLOSED: delete this pin, correct the headless-lane.ts header paragraph that names it, and close #2993",
    );
    // A disclosure nobody re-reads is the same drift, one level up: the header
    // paragraph is the only place a reader learns the scope of the scrub.
    const header = readFileSync(join(HERE, "headless-lane.ts"), "utf8");
    ok(/gitCheckoutIsLinkedWorktree/.test(header), "the module header no longer names classify-git.mjs's un-scrubbed copy — the scrub's scope reads as repo-wide again");
    ok(/#2993/.test(header), "the module header no longer cites #2993 — a tracked gap that loses its issue number is indistinguishable from an accepted one");
  });

  // ── B. the wiring: what the enforcer actually decides about `git commit` ──
  section("B. wiring — the shipped commit-workflow gate, with the real manifest");

  await test("B0 (control) — with NO bypass the gate still refuses `git commit` (so B1 is not vacuous)", async () => {
    const { blocked, reason } = await commitDecision(guardedContract());
    ok(
      blocked,
      "expected `git commit` to be BLOCKED with every launcher affordance scrubbed and no derived lane — the gate is inert, so every arm below proves nothing",
    );
    ok(/commit-workflow/.test(reason), `the refusal must name commit-workflow/SKILL.md, got ${JSON.stringify(reason.slice(0, 160))}`);
  });

  await test("B1 — WORKTREE arm: a derived lane contract lets `git commit` through (the #2965 fix)", async () => {
    const wt = deriveLaneContract({ env: PRINT_ENV, argv: BARE_ARGV, cwd: FIXTURE.wtDirNamed });
    const { blocked, reason } = await commitDecision(wt);
    ok(
      !blocked,
      `expected NO block for a derived lane (headless in ${FIXTURE.wtDirNamed}), got one: ${JSON.stringify(reason.slice(0, 160))}`,
    );
  });

  await test("B2 — HUB arm: the same headless run in the hub is STILL refused (the hub is not weakened)", async () => {
    const hub = deriveLaneContract({ env: PRINT_ENV, argv: BARE_ARGV, cwd: FIXTURE.hub });
    const { blocked, reason } = await commitDecision(hub);
    ok(
      blocked,
      `expected \`git commit\` to STILL be blocked with cwd=${FIXTURE.hub} (a headless run in the hub derives no lane) — it was allowed`,
    );
    ok(/commit-workflow/.test(reason), `the hub refusal must name commit-workflow/SKILL.md, got ${JSON.stringify(reason.slice(0, 160))}`);
  });

  // ── C. mutation evidence ──────────────────────────────────────────────────
  if (process.argv.includes("--mutations")) {
    section("C. mutation evidence — each arm's pin must be able to FAIL");

    const SRC = readFileSync(join(HERE, "headless-lane.ts"), "utf8");
    const mutRoot = tmpDir("hl-mut-");

    /** Write a mutated copy of the module (with its one dependency) and import it. */
    async function mutatedModule(label: string, from: string, to: string) {
      ok(SRC.includes(from), `mutation anchor for ${label} is stale — it does not appear in headless-lane.ts`);
      const dir = join(mutRoot, label.replace(/\W+/g, "-"));
      mkdirSync(dir, { recursive: true });
      writeFileSync(join(dir, "headless-lane.ts"), SRC.replace(from, to));
      writeFileSync(join(dir, "print-mode.ts"), readFileSync(join(HERE, "print-mode.ts"), "utf8"));
      return import(pathToFileURL(join(dir, "headless-lane.ts")).href) as Promise<typeof import("./headless-lane.js")>;
    }

    /** Run a paired assertion and require it to go RED; report its message verbatim. */
    async function expectRed(label: string, paired: () => void | Promise<void>) {
      try {
        await paired();
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        console.log(`  ✅ ${label} — went RED as required; the paired assertion, verbatim:\n     ${msg}`);
        passed += 1;
        return;
      }
      failed += 1;
      failures.push(label);
      console.log(`  ❌ ${label} — the paired assertion still PASSED, so the pin is not discriminating`);
    }

    // M1: the WORKTREE arm's derivation. Revert "a linked worktree derives a lane".
    await test("M1a — the worktree arm's derivation mutation is applied", async () => {
      const mod = await mutatedModule("m1", "    lane: true,\n", "    lane: false,\n");
      const c = mod.deriveLaneContract({ env: PRINT_ENV, argv: BARE_ARGV, cwd: FIXTURE.wtDirNamed });
      ok(!c.lane, "sanity: the mutated copy should no longer derive a lane");
    });
    await expectRed("M1b — worktree arm (derivation)", async () => {
      const mod = await mutatedModule("m1", "    lane: true,\n", "    lane: false,\n");
      const c = mod.deriveLaneContract({ env: PRINT_ENV, argv: BARE_ARGV, cwd: FIXTURE.wtDirNamed });
      ok(c.lane, `lane: expected true (headless in a LINKED worktree must derive the lane contract), got false — ${c.why}`);
    });
    await expectRed("M1c — worktree arm (wiring)", async () => {
      const wt = deriveLaneContract({ env: PRINT_ENV, argv: BARE_ARGV, cwd: FIXTURE.wtDirNamed });
      const { blocked, reason } = await commitDecision({ ...wt, lane: false });
      ok(
        !blocked,
        `expected NO block for a derived lane (headless in ${FIXTURE.wtDirNamed}), got one: ${JSON.stringify(reason.slice(0, 160))}`,
      );
    });

    // M2: the HUB arm. Reintroduce the historical path-insensitive fail-open: treat
    // EVERY checkout as a linked worktree (#618/#621's shape — isMain lost).
    await expectRed("M2a — hub arm (derivation)", async () => {
      const mod = await mutatedModule(
        "m2",
        "return { topLevel, gitDir, commonDir, linkedWorktree: gitDir !== commonDir };",
        "return { topLevel, gitDir, commonDir, linkedWorktree: true };",
      );
      const c = mod.deriveLaneContract({ env: PRINT_ENV, argv: BARE_ARGV, cwd: FIXTURE.hub });
      equal(c.lane, false, `lane: expected false — a headless run in the HUB has no lane contract, got true (${c.why})`);
    });
    await expectRed("M2b — hub arm (wiring)", async () => {
      const hub = deriveLaneContract({ env: PRINT_ENV, argv: BARE_ARGV, cwd: FIXTURE.hub });
      const { blocked } = await commitDecision({ ...hub, lane: true });
      ok(
        blocked,
        `expected \`git commit\` to STILL be blocked with cwd=${FIXTURE.hub} (a headless run in the hub derives no lane) — it was allowed`,
      );
    });

    // M3: the GIT_* scrub (review cycle 1, P0). Reintroduce the defect by handing
    // the probes the RAW environment, so an exported GIT_DIR relocates the read
    // and the HUB derives a lane.
    await expectRed("M3 — hub arm vs an exported GIT_DIR (the scrub is reverted)", async () => {
      const mod = await mutatedModule("m3", "const gitEnv = scrubbedGitEnv(env);", "const gitEnv = env as Record<string, string>;");
      const gitDir = join(FIXTURE.hub, ".git", "worktrees", "w-10137");
      const c = mod.deriveLaneContract({ env: { ...PRINT_ENV, GIT_DIR: gitDir }, argv: BARE_ARGV, cwd: FIXTURE.hub });
      equal(c.lane, false, `lane: expected false — an exported GIT_DIR must not derive a lane in the HUB, got true (${c.why})`);
    });
  }

  console.log(`\n${failed === 0 ? "✅" : "❌"} ${passed} passed, ${failed} failed`);
  if (failed > 0) {
    console.log("failed:\n  - " + failures.join("\n  - "));
    cleanup();
    process.exit(1);
  }
  cleanup();
}

main().catch((err) => {
  console.error(err);
  cleanup();
  process.exit(1);
});
