/**
 * task-heartbeat.orphan.test.ts — unit + integration tests for the #385
 * child-side parent-death watchdog in extensions/task-heartbeat.ts.
 *
 * Covers: the orphanWatchdogActive gate matrix (DISABLE-agnostic arming for
 * both dispatch classes, swarm + user-one-shot exemption, ORPHAN_WATCHDOG=0
 * valve); the isOrphaned truth table (unchanged, subreaper-change, ppid==1
 * boot race); the arm/poll mechanics (double-confirm, min-uptime, fired latch,
 * unref'd timer); the self-termination fire sequence via injected hooks
 * (grace resolution, exit(137) reached even when the kill hook throws —
 * try/finally); and ONE real end-to-end integration test: a detached child
 * (tsx, watchdog armed) with a grandchild is orphaned when its fixture parent
 * is SIGKILLed → ppid==1 → the watchdog's real descendant kill reaps the
 * grandchild and the child self-terminates.
 *
 * ALSO COVERS THE SILENCE DEFECT: an actuator that destroys without recording
 * makes "killed by our watchdog", "thought it was done" and "never started"
 * indistinguishable. So: the settle ROW is written BEFORE the kill (asserted by
 * ORDER, so deleting the write turns the suite red), it names the killed pids,
 * the parent pid, the status `orphan-killed` and the dispatch identity, a
 * record FAILURE is diagnosed without ever blocking the kill/exit, and the
 * end-to-end fixture proves the row really lands in the ledger when a real
 * parent is SIGKILLed.
 *
 * Run: npx tsx extensions/task-heartbeat.orphan.test.ts
 */

import { spawn } from "node:child_process";
import { execSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import {
  orphanWatchdogActive,
  isOrphaned,
  armOrphanWatchdog,
  getOrphanIntervalMs,
  getOrphanMinUptimeMs,
  getOrphanGraceMs,
  orphanWatchdogHooks,
  buildOrphanSettleRow,
  safeCwd,
  ORPHAN_KILLED_REASON,
  ORPHAN_KILLED_EXIT_CODE,
  _resetWatchdogArmedForTests,
} from "./task-heartbeat.js";
import { ok, equal, deepEqual } from "node:assert/strict";

// ── Hermeticity (#783 precedent: tests isolate via PI_CODING_AGENT_DIR) ────
// The settle row is now written by this suite's fire sequences. Point the agent
// dir at a tmpdir BEFORE any test runs, so the operator's real
// `<agentDir>/audit/provider-failover.jsonl` is never appended to from a test.
const TEST_AGENT_DIR = fs.mkdtempSync(os.tmpdir() + "/orphan-watchdog-agent-");
process.env.PI_CODING_AGENT_DIR = TEST_AGENT_DIR;
const LEDGER_PATH = path.join(TEST_AGENT_DIR, "audit", "provider-failover.jsonl");
// The attribution LINE is the other surface (it is documented as greppable by
// `status=orphan-killed`), so a test run must not forge lines into the real
// `~/.pi/agent/orphan-watchdog.log` either — the fixture child uses the default
// appendLog. The seam redirects both.
process.env.ORPHAN_WATCHDOG_LOG = path.join(TEST_AGENT_DIR, "orphan-watchdog.log");

function ledgerRows(): any[] {
  if (!fs.existsSync(LEDGER_PATH)) return [];
  return fs
    .readFileSync(LEDGER_PATH, "utf8")
    .split("\n")
    .filter((l) => l.trim().length > 0)
    .map((l) => JSON.parse(l));
}

let passed = 0;
let failed = 0;
const tests: Array<() => void | Promise<void>> = [];

function test(name: string, fn: () => void | Promise<void>) {
  tests.push(async () => {
    try {
      await fn();
      passed++;
      console.log(`  ✅ ${name}`);
    } catch (err: any) {
      failed++;
      console.log(`  ❌ ${name}: ${err.message}`);
    }
  });
}

function section(name: string) {
  console.log(`\n${name}:`);
}

const setPairEnv = () => {
  process.env.TASK_HEARTBEAT = "1";
  process.env.PI_MODE = "print";
};
const clearPairEnv = () => {
  delete process.env.TASK_HEARTBEAT;
  delete process.env.PI_MODE;
  delete process.env.ORPHAN_WATCHDOG_MIN_UPTIME_MS;
  delete process.env.ORPHAN_WATCHDOG_GRACE_MS;
};
// The #212 convention gates test-only hooks on NODE_ENV=test.
process.env.NODE_ENV = "test";

// ── Gate matrix ─────────────────────────────────────────────────────────

section("orphanWatchdogActive gate matrix (#385 plan Step 2)");

test("task-tool child env (TASK_HEARTBEAT=1 + PI_MODE=print) → armed", () => {
  equal(orphanWatchdogActive({ TASK_HEARTBEAT: "1", PI_MODE: "print" }), true);
});

test("subagent-extension child (pair + TASK_HEARTBEAT_DISABLE=1) → armed (DISABLE-agnostic shift)", () => {
  equal(
    orphanWatchdogActive({ TASK_HEARTBEAT: "1", PI_MODE: "print", TASK_HEARTBEAT_DISABLE: "1" }),
    true,
  );
});

test("swarm_daemon worker (PI_MODE=print only, no pair) → NOT armed (class-3 exemption)", () => {
  equal(orphanWatchdogActive({ PI_MODE: "print" }), false);
});

test("bare `pi -p` run (no env at all) → NOT armed (user one-shot exemption)", () => {
  equal(orphanWatchdogActive({}), false);
});

test("ORPHAN_WATCHDOG=0 valve → disarmed even with the pair", () => {
  equal(orphanWatchdogActive({ TASK_HEARTBEAT: "1", PI_MODE: "print", ORPHAN_WATCHDOG: "0" }), false);
});

test("ORPHAN_WATCHDOG unset with the pair → armed (default on)", () => {
  equal(orphanWatchdogActive({ TASK_HEARTBEAT: "1", PI_MODE: "print" }), true);
});

// ── isOrphaned truth table ───────────────────────────────────────────────

section("isOrphaned predicate truth table");

test("unchanged non-1 ppid → false", () => {
  equal(isOrphaned(4242, 4242), false);
});

test("changed ppid (subreaper adoption to a non-1 pid) → true", () => {
  equal(isOrphaned(777, 4242), true);
});

test("ppid===1 with unchanged original → true (launchd adoption / boot race)", () => {
  equal(isOrphaned(1, 1), true);
  equal(isOrphaned(1, 4242), true);
});

// ── Constants ────────────────────────────────────────────────────────────

section("watchdog constants");

test("interval default 15s, floor 5s", () => {
  equal(getOrphanIntervalMs({}), 15_000);
  equal(getOrphanIntervalMs({ ORPHAN_WATCHDOG_INTERVAL_MS: "1" }), 5_000);
  equal(getOrphanIntervalMs({ ORPHAN_WATCHDOG_INTERVAL_MS: "60000" }), 60_000);
});

test("min-uptime default 60s, 0 allowed", () => {
  equal(getOrphanMinUptimeMs({}), 60_000);
  equal(getOrphanMinUptimeMs({ ORPHAN_WATCHDOG_MIN_UPTIME_MS: "0" }), 0);
});

test("grace default 4s, floor 1s", () => {
  equal(getOrphanGraceMs({}), 4_000);
  equal(getOrphanGraceMs({ ORPHAN_WATCHDOG_GRACE_MS: "100" }), 1_000);
});

// ── Arm/poll mechanics with injected hooks ───────────────────────────────

section("arm + poll mechanics (injected hooks, NODE_ENV=test)");

test("single positive poll does NOT fire (double-confirm); fired latch prevents re-fire", async () => {
  const real = { ...orphanWatchdogHooks };
  setPairEnv();
  process.env.ORPHAN_WATCHDOG_MIN_UPTIME_MS = "0";
  const exitCodes: number[] = [];
  try {
    orphanWatchdogHooks.ppidGetter = () => 1; // orphaned immediately
    orphanWatchdogHooks.nowGetter = () => 0;
    orphanWatchdogHooks.killDescendants = async () => {};
    orphanWatchdogHooks.exitProcess = (code: number) => { exitCodes.push(code); };
    orphanWatchdogHooks.appendLog = () => {};
    _resetWatchdogArmedForTests();
    const handle = armOrphanWatchdog();
    ok(handle !== null, "watchdog should arm");
    handle!.poll(); // first positive — not enough
    equal(exitCodes.length, 0, "single confirm must not fire");
    handle!.poll(); // second positive — fires (async fire sequence)
    await new Promise((r) => setTimeout(r, 20)); // let fireSequence complete
    equal(exitCodes.length, 1, "double-confirm must fire exactly once");
    equal(exitCodes[0], 137);
    handle!.poll(); // latch — no re-fire
    await new Promise((r) => setTimeout(r, 20));
    equal(exitCodes.length, 1, "fired latch must prevent re-fire");
  } finally {
    Object.assign(orphanWatchdogHooks, real);
    clearPairEnv();
  }
});

test("min-uptime blocks a fire before the floor", async () => {
  const real = { ...orphanWatchdogHooks };
  setPairEnv();
  process.env.ORPHAN_WATCHDOG_MIN_UPTIME_MS = "60000";
  let fired = 0;
  try {
    orphanWatchdogHooks.ppidGetter = () => 1;
    orphanWatchdogHooks.nowGetter = () => 0; // uptime 0 at arm time
    orphanWatchdogHooks.killDescendants = async () => {};
    orphanWatchdogHooks.exitProcess = () => { fired++; };
    orphanWatchdogHooks.appendLog = () => {};
    _resetWatchdogArmedForTests();
    const handle = armOrphanWatchdog();
    handle!.poll();
    handle!.poll();
    equal(fired, 0, "min-uptime must block at 0s uptime");
    orphanWatchdogHooks.nowGetter = () => 61_000; // past the floor (61s uptime)
    handle!.poll();
    handle!.poll();
    await new Promise((r) => setTimeout(r, 20)); // let fireSequence complete
    equal(fired, 1, "must fire once past the floor");
  } finally {
    Object.assign(orphanWatchdogHooks, real);
    clearPairEnv();
  }
});

test("killDescendants is invoked with the resolved grace before exit (TERM→grace→SIGKILL contract)", async () => {
  const real = { ...orphanWatchdogHooks };
  setPairEnv();
  process.env.ORPHAN_WATCHDOG_MIN_UPTIME_MS = "0";
  process.env.ORPHAN_WATCHDOG_GRACE_MS = "2000";
  const calls: number[] = [];
  let exited = false;
  try {
    orphanWatchdogHooks.ppidGetter = () => 1;
    orphanWatchdogHooks.nowGetter = () => 0;
    orphanWatchdogHooks.killDescendants = async (graceMs: number) => {
      calls.push(graceMs);
      await new Promise((r) => setTimeout(r, 10));
    };
    orphanWatchdogHooks.exitProcess = () => { exited = true; };
    orphanWatchdogHooks.appendLog = () => {};
    _resetWatchdogArmedForTests();
    const handle = armOrphanWatchdog();
    handle!.poll();
    handle!.poll();
    // fireSequence is async (void) — allow the microtask + grace hook to run
    await new Promise((r) => setTimeout(r, 50));
    equal(calls.length, 1, "killDescendants called exactly once");
    equal(calls[0], 2_000, "grace resolved from ORPHAN_WATCHDOG_GRACE_MS");
    equal(exited, true, "exit(137) called after the kill hook resolves");
  } finally {
    Object.assign(orphanWatchdogHooks, real);
    clearPairEnv();
  }
});

test("exit(137) is reached even when killDescendants throws (try/finally regression)", async () => {
  const real = { ...orphanWatchdogHooks };
  setPairEnv();
  process.env.ORPHAN_WATCHDOG_MIN_UPTIME_MS = "0";
  let exited = false;
  let exitCode = 0;
  try {
    orphanWatchdogHooks.ppidGetter = () => 1;
    orphanWatchdogHooks.nowGetter = () => 0;
    orphanWatchdogHooks.killDescendants = async () => {
      throw new Error("boom");
    };
    orphanWatchdogHooks.exitProcess = (code: number) => { exited = true; exitCode = code; };
    orphanWatchdogHooks.appendLog = () => {};
    _resetWatchdogArmedForTests();
    const handle = armOrphanWatchdog();
    handle!.poll();
    handle!.poll();
    await new Promise((r) => setTimeout(r, 30));
    equal(exited, true, "exit must run despite a throwing kill hook");
    equal(exitCode, 137);
  } finally {
    Object.assign(orphanWatchdogHooks, real);
    clearPairEnv();
  }
});

test("the poll timer is unref'd (must never hold the event loop open — #153 class)", async () => {
  const real = { ...orphanWatchdogHooks };
  setPairEnv();
  try {
    _resetWatchdogArmedForTests();
    const handle = armOrphanWatchdog();
    ok(handle !== null);
    equal(handle!.timer.hasRef(), false, "timer must be unref'd");
    handle!.timer.unref();
  } finally {
    Object.assign(orphanWatchdogHooks, real);
    clearPairEnv();
  }
});

test("arm returns null when the gate is off", () => {
  const prev = { ...process.env };
  delete process.env.TASK_HEARTBEAT;
  delete process.env.PI_MODE;
  try {
    equal(armOrphanWatchdog(), null);
  } finally {
    Object.assign(process.env, prev);
  }
});

// ── Settle record: the actuator must not destroy without recording ──────

section("settle record — an orphan kill is RECORDED (status, pids, parent, ts)");

test("fireSequence writes the row BEFORE the kill and exits 137 (order: record → log → kill → exit)", async () => {
  const real = { ...orphanWatchdogHooks };
  setPairEnv();
  process.env.ORPHAN_WATCHDOG_MIN_UPTIME_MS = "0";
  const order: string[] = [];
  const rows: any[] = [];
  let exitCode = 0;
  let livePpid = 4321;
  try {
    orphanWatchdogHooks.ppidGetter = () => livePpid; // real parent at arm time
    orphanWatchdogHooks.nowGetter = () => 0;
    orphanWatchdogHooks.ownPgidGetter = () => null;
    orphanWatchdogHooks.enumerateKillTargets = () => [111, 222];
    orphanWatchdogHooks.recordSettle = (row) => {
      order.push("record");
      rows.push(row);
      return { ok: true, path: "/tmp/fake-ledger.jsonl" };
    };
    orphanWatchdogHooks.killDescendants = async () => {
      order.push("kill");
    };
    orphanWatchdogHooks.exitProcess = (code: number) => {
      order.push("exit");
      exitCode = code;
    };
    orphanWatchdogHooks.appendLog = () => {
      // The log line is the human-greppable half of the record, so its POSITION
      // is part of the contract: it must come AFTER the settle row (a line that
      // announces `status=orphan-killed` before anything was written is the
      // "we said we killed but recorded nothing" shape) and BEFORE the kill.
      order.push("log");
    };
    _resetWatchdogArmedForTests();
    const handle = armOrphanWatchdog();
    ok(handle !== null, "watchdog should arm");
    livePpid = 1; // parent disappeared
    handle!.poll();
    handle!.poll();
    await new Promise((r) => setTimeout(r, 50));

    equal(
      order.join(","),
      "record,log,kill,exit",
      "the settle record must be written BEFORE the descendant kill (and the log line after the record, before the kill), and the exit must still follow",
    );
    equal(rows.length, 1, "exactly one settle row per firing");
    const row = rows[0];
    equal(row.reason, ORPHAN_KILLED_REASON, "status is `orphan-killed`, never `done`, never absent");
    equal(row.reason, "orphan-killed");
    equal(row.parentPid, 4321, "names the parent whose disappearance caused the kill");
    deepEqual(row.killedPids, [111, 222], "names the pids the kill was about to signal");
    equal(row.exitCode, ORPHAN_KILLED_EXIT_CODE, "row and process agree on 137");
    ok(!Number.isNaN(Date.parse(row.ts)), "carries a parseable timestamp");
    equal(exitCode, 137, "the process still exits non-zero");
  } finally {
    Object.assign(orphanWatchdogHooks, real);
    clearPairEnv();
  }
});

test("the DEFAULT writer lands a real ledger row with the dispatch identity joined from env + argv", async () => {
  // No recordSettle override: this drives the shipped writer into the
  // hermetic ledger. dispatchId comes from the dispatch nonce, childSessionId
  // from the child's own --session-id arg vector.
  const real = { ...orphanWatchdogHooks };
  setPairEnv();
  process.env.ORPHAN_WATCHDOG_MIN_UPTIME_MS = "0";
  process.env.TASK_HEARTBEAT_NONCE = "orphannonce01";
  const before = ledgerRows().length;
  let exited = 0;
  try {
    orphanWatchdogHooks.ppidGetter = () => 1;
    orphanWatchdogHooks.nowGetter = () => 0;
    orphanWatchdogHooks.ownPgidGetter = () => null;
    orphanWatchdogHooks.enumerateKillTargets = () => [4242];
    orphanWatchdogHooks.killDescendants = async () => {};
    orphanWatchdogHooks.exitProcess = (code: number) => { exited = code; };
    orphanWatchdogHooks.appendLog = () => {};
    _resetWatchdogArmedForTests();
    const handle = armOrphanWatchdog();
    handle!.poll();
    handle!.poll();
    await new Promise((r) => setTimeout(r, 50));

    const added = ledgerRows().slice(before);
    equal(added.length, 1, `exactly one durable row appended (got ${added.length})`);
    const row = added[0];
    equal(row.event, "dispatch-outcome", "the repo's ONE outcome-row event (no second format)");
    equal(row.extension, "task-heartbeat", "the row's writer is named");
    equal(row.reason, "orphan-killed");
    equal(row.dispatchId, "orphannonce01", "joins the #512/#476 rows on the dispatch nonce");
    equal(row.parentPid, 1);
    deepEqual(row.killedPids, [4242]);
    equal(row.exitCode, 137);
    equal(row.cwd, process.cwd(), "names the worktree the killed child was running in");
    equal(exited, 137, "recording must not replace the exit");
  } finally {
    Object.assign(orphanWatchdogHooks, real);
    delete process.env.TASK_HEARTBEAT_NONCE;
    clearPairEnv();
  }
});

test("buildOrphanSettleRow: unknown-at-settle values stay null/[] — never a confident guess", () => {
  const row = buildOrphanSettleRow({
    parentPid: 777,
    killedPids: [10, 11],
    now: new Date("2026-11-02T22:00:00.000Z"),
    env: { TASK_HEARTBEAT_NONCE: " nonce-x ", TASK_DISPATCH_ATTEMPT: "3", TASK_DISPATCH_CLASS: "reviewer" },
    argv: ["pi", "-p", "--session-id", "sess-abc", "--session-dir", "/tmp/s"],
    cwd: "/w/tree",
  });
  equal(row.ts, "2026-11-02T22:00:00.000Z", "ts is stamped once, by the row");
  equal(row.dispatchId, "nonce-x", "nonce is trimmed");
  equal(row.childSessionId, "sess-abc", "read from the child's own arg vector");
  equal(row.attempt, 3, "the per-leg ordinal travels in the child env");
  equal(row.dispatchClass, "reviewer");
  equal(row.cwd, "/w/tree");
  equal(row.branch, null, "branch is UNKNOWN in a dying process, not a guess");
  equal(row.headSha, null);
  equal(row.dirty, null, "a failed/absent probe must not become a confident clean tree");
  equal(row.dirtyPaths, null, "null is not [] (unknown is not zero dirty paths)");
  equal(row.everSawTool, null, "a process killed mid-tool must not claim it never ran one");
  equal(
    row.transcriptPath,
    "/tmp/s",
    "the transcript locator is RESOLVED from the child's own --session-dir, never left null by omission",
  );
  equal(row.parentSessionId, null);
  equal(row.parentPid, 777);
  deepEqual(row.killedPids, [10, 11]);
  equal(row.reason, "orphan-killed");
  equal(row.exitCode, 137);
  // Absent identity must degrade, not throw.
  const bare = buildOrphanSettleRow({ parentPid: 1, killedPids: [], env: {}, argv: ["pi"] });
  equal(bare.dispatchId, null);
  equal(bare.childSessionId, null);
  equal(bare.transcriptPath, null, "null means the --no-session degrade, not 'we did not look'");
  equal(bare.attempt, 1, "the contract's parent-side default when no dispatcher exported one");
  equal(bare.dispatchClass, "task");
});

test("a DELETED cwd (the reaped-worktree case) never discards the settle row", () => {
  // `process.cwd()` throws ENOENT once its directory is gone, and a dying
  // dispatch child's cwd IS its worktree — which `scripts/pi-reap-worktrees.sh`
  // deletes. An unguarded call would throw inside the fire sequence's try and
  // discard the WHOLE row (reason, parentPid, killedPids, identity) on exactly
  // the population this record exists for. So: the resolver is guarded, and the
  // row still lands, with `""` as the documented unknown.
  const throwing = () => {
    const err = new Error("ENOENT: no such file or directory, uv_cwd") as Error & { code?: string };
    err.code = "ENOENT";
    throw err;
  };
  equal(safeCwd(throwing), "", "an unresolvable cwd reads as unknown, never as a guess");
  equal(safeCwd(() => "/w/tree"), "/w/tree", "and a resolvable one is passed through (the guard is not a bypass)");
  const row = buildOrphanSettleRow({
    parentPid: 4321,
    killedPids: [11],
    env: { TASK_HEARTBEAT_NONCE: "nonce-cwd" },
    argv: ["pi"],
    getCwd: throwing,
  });
  equal(row.cwd, "", "cwd is the documented unknown value");
  equal(row.reason, "orphan-killed", "⛔ the ROW SURVIVES — that is the whole point");
  equal(row.parentPid, 4321, "who: the parent whose disappearance caused the kill");
  deepEqual(row.killedPids, [11], "who: the pids enumerated for the kill");
  equal(row.dispatchId, "nonce-cwd", "and the dispatch identity is still joinable");
});

test("a FAILED settle record is diagnosed and never blocks the kill or the exit", async () => {
  const real = { ...orphanWatchdogHooks };
  setPairEnv();
  process.env.ORPHAN_WATCHDOG_MIN_UPTIME_MS = "0";
  const logs: string[] = [];
  let killed = false;
  let exitCode = 0;
  try {
    orphanWatchdogHooks.ppidGetter = () => 1;
    orphanWatchdogHooks.nowGetter = () => 0;
    orphanWatchdogHooks.ownPgidGetter = () => null;
    orphanWatchdogHooks.enumerateKillTargets = () => [];
    orphanWatchdogHooks.recordSettle = () => ({ ok: false, path: "/ro/ledger.jsonl", error: "EACCES" });
    orphanWatchdogHooks.killDescendants = async () => { killed = true; };
    orphanWatchdogHooks.exitProcess = (code: number) => { exitCode = code; };
    orphanWatchdogHooks.appendLog = (line: string) => { logs.push(line); };
    _resetWatchdogArmedForTests();
    const handle = armOrphanWatchdog();
    handle!.poll();
    handle!.poll();
    await new Promise((r) => setTimeout(r, 50));
    equal(killed, true, "an unwritable ledger must never stop the cleanup");
    equal(exitCode, 137, "nor the exit");
    ok(
      logs.some((l) => l.includes("settle=FAILED") && l.includes("EACCES")),
      `the unrecorded kill must be DIAGNOSED, not silent: ${logs.join(" | ")}`,
    );
  } finally {
    Object.assign(orphanWatchdogHooks, real);
    clearPairEnv();
  }
});

test("default enumeration names the REAL descendants and never the enum probe itself", async () => {
  // The probe forks `pgrep`, which is itself a child at read time — a naive
  // single read records a pid that is never signalled. The tell is that two
  // consecutive reads differ (the probe pid is new each time).
  const child = spawn(process.execPath, ["-e", "setInterval(()=>{},1000)"], { stdio: "ignore" });
  try {
    await new Promise((r) => setTimeout(r, 400)); // let it appear in the table
    const first = orphanWatchdogHooks.enumerateKillTargets();
    const second = orphanWatchdogHooks.enumerateKillTargets();
    ok(first.includes(child.pid!), `names the real descendant (got [${first.join(",")}])`);
    ok(!first.includes(process.pid), "never records self");
    deepEqual(
      first,
      second,
      `the enum probe's own pid must never leak in (two reads must agree: [${first.join(",")}] vs [${second.join(",")}])`,
    );
  } finally {
    try { child.kill("SIGKILL"); } catch {}
  }
});

// ── Real end-to-end integration test ─────────────────────────────────────

section("integration: orphaned detached child self-terminates + kills its grandchild");

/** A zombie (stat Z) counts as gone for our purposes — it holds no memory
 * and cannot be killed; launchd/PID 1 reaps it promptly on macOS. */
function isGoneOrZombie(pid: number): boolean {
  try {
    const stat = execSync(`ps -o stat= -p ${pid}`, { encoding: "utf-8" }).trim();
    return stat === "Z" || stat === "";
  } catch {
    return true; // ps could not find it — gone
  }
}

test("real reparenting: orphan watchdog reaps child + grandchild after parent SIGKILL", async () => {
  // Fixture graph: test parent → fixture (plain node, stays alive) → detached
  // child (tsx, watchdog armed, TASK_HEARTBEAT=1 + PI_MODE=print) →
  // grandchild (plain node, setInterval — stays alive). The test SIGKILLs the
  // fixture → the detached child reparents to PID 1 → its own polls detect
  // ppid==1 → the watchdog's REAL killDescendants (TERM→grace→SIGKILL + pgid
  // catch-net) reaps the grandchild, then the child self-terminates.

  const heartbeatPath = `${process.cwd()}/extensions/task-heartbeat.ts`;
  // The watchdog process must be a DIRECT child of the killed fixture — npx
  // wrappers (npm exec → node) would orphan the wrapper, not the watchdog.
  // Spawn node with tsx's preflight hook (the same mechanism `npx tsx` uses —
  // exposed via process.execArgv) so the child loads .ts directly.
  const tsxPreflight = process.execArgv.find((a) => a.includes("tsx") && a.endsWith("preflight.cjs"));
  ok(tsxPreflight, "tsx preflight hook resolvable from process.execArgv");
  const tmp = fs.mkdtempSync(os.tmpdir() + "/orphan-watchdog-int-");
  const childFile = `${tmp}/watchdog-child.ts`;
  fs.writeFileSync(
    childFile,
    `
    import { armOrphanWatchdog } from ${JSON.stringify(heartbeatPath)};
    import { spawn } from "node:child_process";
    const grandchild = spawn(process.execPath, ["-e", "setInterval(()=>{},1000)"], {
      stdio: ["ignore", "ignore", "ignore"],
    });
    const handle = armOrphanWatchdog();
    if (!handle) { console.error("no-arm"); process.exit(99); }
    console.error("GRANDCHILD=" + grandchild.pid);
    // The watchdog's own interval floor is 5s; drive polls manually for a
    // deterministic fast test. After the fixture parent is SIGKILLed the
    // child reparents → ppid==1 → double-confirm (200ms cadence) fires.
    setInterval(() => handle.poll(), 200);
    setTimeout(() => { process.exit(98); }, 30000); // backstop — never reached
  `,
  );

  const fixtureScript = `
    (async () => {
      const { spawn } = require("node:child_process");
      const child = spawn(process.execPath, ["--require", ${JSON.stringify(tsxPreflight)}, ${JSON.stringify(childFile)}], {
        detached: true,
        stdio: ["ignore", "pipe", "pipe"],
        env: {
          ...process.env,
          TASK_HEARTBEAT: "1",
          PI_MODE: "print",
          ORPHAN_WATCHDOG_MIN_UPTIME_MS: "0",
          ORPHAN_WATCHDOG_GRACE_MS: "1000",
          // Identity the settle row must carry (the dispatch nonce join key and
          // the per-leg ordinal the parent exports).
          TASK_HEARTBEAT_NONCE: "orphanintnonce",
          TASK_DISPATCH_ATTEMPT: "2",
        },
      });
      let out = "";
      child.stderr.on("data", (d) => { out += d.toString(); });
      child.stdout.on("data", (d) => { out += d.toString(); });
      const started = Date.now();
      while (Date.now() - started < 8000) {
        const m = out.match(/GRANDCHILD=(\\d+)/);
        if (m) { console.log("CHILDPID=" + child.pid + " " + m[1]); process.exit(0); }
        await new Promise((r) => setTimeout(r, 100));
      }
      console.error("fixture timeout waiting for grandchild pid");
      process.exit(97);
    })();
  `;
  const fixture = spawn(process.execPath, ["-e", fixtureScript], {
    stdio: ["ignore", "pipe", "pipe"],
  });
  let fixtureOut = "";
  fixture.stdout.on("data", (d) => { fixtureOut += d.toString(); });
  fixture.stderr.on("data", (d) => { fixtureOut += d.toString(); });

  const started = Date.now();
  let childPid = 0;
  let grandchildPid = 0;
  while (Date.now() - started < 15000) {
    const m = fixtureOut.match(/CHILDPID=(\d+) (\d+)/);
    if (m) { childPid = Number(m[1]); grandchildPid = Number(m[2]); break; }
    await new Promise((r) => setTimeout(r, 100));
  }
  ok(childPid > 0, `fixture reported the child pid (out: ${fixtureOut.slice(0, 300)})`);
  ok(grandchildPid > 0, "fixture reported the grandchild pid");
  ok(!isGoneOrZombie(childPid), "child alive before parent kill");
  ok(!isGoneOrZombie(grandchildPid), "grandchild alive before parent kill");

  // SIGKILL the fixture parent — the detached child reparents to PID 1.
  fixture.kill("SIGKILL");
  await new Promise((r) => setTimeout(r, 400));

  // The child's watchdog must fire (ppid→1, double-confirm via its 200ms
  // polls, min-uptime 0) and reap BOTH the grandchild and itself.
  const deadline = Date.now() + 12000;
  let childGone = false;
  let grandchildGone = false;
  while (Date.now() < deadline) {
    if (isGoneOrZombie(childPid)) childGone = true;
    if (isGoneOrZombie(grandchildPid)) grandchildGone = true;
    if (childGone && grandchildGone) break;
    await new Promise((r) => setTimeout(r, 200));
  }
  ok(grandchildGone, "grandchild must be reaped by the descendant kill");
  ok(childGone, "orphaned child must self-terminate");

  // ⛔ THE LIVE PROOF: the kill left a record naming who died and why. Without
  // it, this exact event is indistinguishable from "the lane thought it was
  // done" or "the lane never started" — which is how three lanes vanished.
  const orphanRows = ledgerRows().filter((r) => r.dispatchId === "orphanintnonce");
  equal(orphanRows.length, 1, `exactly one settle row for the killed child (got ${orphanRows.length})`);
  const row = orphanRows[0];
  equal(row.event, "dispatch-outcome");
  equal(row.reason, "orphan-killed", "status the fleet reads — never `done`, never an absence");
  equal(row.parentPid, fixture.pid, "names the parent whose SIGKILL caused the termination");
  equal(row.attempt, 2, "the per-leg ordinal travelled in the child env");
  ok(
    row.killedPids.includes(grandchildPid),
    `names the grandchild the kill signalled (row ${JSON.stringify(row.killedPids)}, grandchild ${grandchildPid})`,
  );
  ok(!row.killedPids.includes(childPid), "never names the process it was running IN");
  equal(row.exitCode, 137);
  equal(row.cwd, process.cwd());
  // Cleanup in case of failure:
  try { execSync(`kill -9 ${childPid} ${grandchildPid} 2>/dev/null || true`); } catch {}
  try { fs.rmSync(tmp, { recursive: true, force: true }); } catch {}
});

// ── #1074: the catch-net's unmeasured paths must be DIAGNOSED, not silent ──

test("#1074: default kill-descendants warns + skips when the own pgid is unmeasured", async () => {
  // `getPgid` null covers "ps failed/timed out" as well as "no such pid"; the
  // catch-net is skipped either way (fail-closed), but the miss must be
  // audible. Calls the REAL default implementation (the module's own hook
  // object holds it), with no children of our own to walk.
  const real = { ...orphanWatchdogHooks };
  const warns: string[] = [];
  const origWarn = console.warn;
  console.warn = (m: unknown) => { warns.push(String(m)); };
  try {
    orphanWatchdogHooks.ownPgidGetter = () => null;
    await orphanWatchdogHooks.killDescendants(0);
    ok(
      warns.some((w) => w.includes("own pgid unmeasured")),
      `the skipped catch-net must be diagnosed: ${warns.join(" | ")}`,
    );
  } finally {
    console.warn = origWarn;
    Object.assign(orphanWatchdogHooks, real);
  }
});

// ── Runner ───────────────────────────────────────────────────────────────

(async () => {
  for (const t of tests) await t();
  console.log(`\n${passed} passed, ${failed} failed`);
  process.exit(failed > 0 ? 1 : 0);
})();
