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
 * Run: npx tsx extensions/task-heartbeat.orphan.test.ts
 */

import { spawn } from "node:child_process";
import { execSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import {
  orphanWatchdogActive,
  isOrphaned,
  armOrphanWatchdog,
  getOrphanIntervalMs,
  getOrphanMinUptimeMs,
  getOrphanGraceMs,
  orphanWatchdogHooks,
  _resetWatchdogArmedForTests,
} from "./task-heartbeat.js";
import { ok, equal } from "node:assert/strict";

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
  // Cleanup in case of failure:
  try { execSync(`kill -9 ${childPid} ${grandchildPid} 2>/dev/null || true`); } catch {}
  try { fs.rmSync(tmp, { recursive: true, force: true }); } catch {}
});

// ── Runner ───────────────────────────────────────────────────────────────

(async () => {
  for (const t of tests) await t();
  console.log(`\n${passed} passed, ${failed} failed`);
  process.exit(failed > 0 ? 1 : 0);
})();
