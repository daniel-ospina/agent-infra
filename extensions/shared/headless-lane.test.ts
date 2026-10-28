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
import { execFileSync } from "node:child_process";
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
  _setLaneContractForTest(null);
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
  return { base, hub, wtDirNamed, wtBranchNamed };
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
async function main() {
  applyLaneContract; // imported for the KIND/TAG legs below

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
