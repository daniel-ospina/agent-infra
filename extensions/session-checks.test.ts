/**
 * session-checks.test.ts — age-gate logic + orchestration for extensions/session-checks.ts
 * Run: npx tsx extensions/session-checks.test.ts   (from any agent-infra checkout)
 *
 * Uses temp state dirs + a recording exec seam — no real hub/oracle runs, no
 * network, no git (the installer suite + live session verification cover the
 * real execution path).
 */
import { ok, equal } from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, utimesSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";

import {
  due,
  lastRunEpoch,
  resolveHubRepos,
  runSessionChecks,
  clampPollMinutes,
  getPollIntervalMs,
  HUB_SIBLING_DEFAULT_NAMES,
  POLL_MIN_DEFAULT,
  POLL_MIN_FLOOR,
  POLL_MIN_MAX,
  type ExecFn,
  type ExecResult,
} from "./session-checks.js";
import sessionChecksHook from "./session-checks.js"; // default export = pi registration fn

let passed = 0;
let failed = 0;
async function test(name: string, fn: () => void | Promise<void>) {
  try {
    await fn();
    passed += 1;
    console.log(`  ✅ ${name}`);
  } catch (err) {
    failed += 1;
    console.error(`  ❌ ${name}\n     ${err instanceof Error ? err.message : String(err)}`);
  }
}

function tmp() {
  const d = mkdtempSync(join(tmpdir(), "session-checks-test-"));
  // Default hub resolution finds agent-infra (its own path) + the sibling hub
  // repos under the same parent dir — #615: agent-infra is no longer #99-exempt;
  // #619: the default list is tortoise/premise-labs/DMeer/eldato (existence-gated).
  // Tests exercise the same default the live extension sees (env unset in CI;
  // ambient env is harmless — exec is faked). tmp() seeds the tortoise sibling
  // only; tests that need more siblings call makeHubSiblings().
  mkdirSync(join(d, "tortoise"), { recursive: true });
  return { d, state: join(d, "state"), infra: join(d, "agent-infra") };
}

/** Seed the full #619 sibling-hub default set under the fixture root. */
function makeHubSiblings(d: string): void {
  for (const name of HUB_SIBLING_DEFAULT_NAMES) {
    mkdirSync(join(d, name), { recursive: true });
  }
}

/** Removes ambient repo env vars so a resolution test sees only its own setup. */
function withCleanRepoEnv<T>(fn: () => T): T {
  const prevT = process.env.TORTOISE_REPO;
  const prevS = process.env.SESSION_CHECKS_REPOS;
  delete process.env.TORTOISE_REPO;
  delete process.env.SESSION_CHECKS_REPOS;
  try {
    return fn();
  } finally {
    if (prevT === undefined) delete process.env.TORTOISE_REPO;
    else process.env.TORTOISE_REPO = prevT;
    if (prevS === undefined) delete process.env.SESSION_CHECKS_REPOS;
    else process.env.SESSION_CHECKS_REPOS = prevS;
  }
}

function makeInfra(infra: string): void {
  mkdirSync(join(infra, "scripts", "checkout-hygiene"), { recursive: true });
  mkdirSync(join(infra, "scripts"), { recursive: true });
  writeFileSync(join(infra, "scripts", "checkout-hygiene", "hub-state-check.sh"), "#!/usr/bin/env bash\n");
  writeFileSync(join(infra, "scripts", "cron-quality-gates.sh"), "#!/usr/bin/env bash\n");
}

/** Recording exec seam: logs invocations, returns a scripted result. */
function recordingExec(log: Array<{ name: string; cmd: string; args: string[] }>, result: Partial<ExecResult> & { code?: number } = { code: 0 }): ExecFn {
  return async (cmd, args, _opts) => {
    log.push({ name: cmd === "bash" && args[0]?.includes("hub-state-check") ? "hub" : "oracle", cmd, args });
    return { code: result.code ?? 0, stdout: result.stdout ?? "", stderr: result.stderr ?? "", timedOut: Boolean(result.timedOut) };
  };
}

const HOUR = 3600;

// ── hook-level env-knob layer (auto-sync fake-pi pattern) ──────────────
// Guards the exact bug class from review cycle 3 (env whitespace silently
// disabling a window) + the OFF/no-path wiring, at the real registration fn.
interface FakePi {
  on: (event: string, cb: () => Promise<void>) => void;
}

const HOOK_ENV_KEYS = ["AGENT_INFRA_PATH", "SESSION_CHECKS_OFF", "SESSION_CHECKS_STATE", "SESSION_CHECKS_HUB_H", "SESSION_CHECKS_ORACLE_H", "SESSION_CHECKS_POLL_MIN", "TORTOISE_REPO", "SESSION_CHECKS_REPOS"] as const;

/**
 * Full hook harness (#619): runs the real registration fn with a fake pi,
 * capturing session_start/session_shutdown handlers and the cadence poll
 * timer (setInterval/clearInterval stubbed) so tests can (a) assert timer
 * lifecycle and (b) fire a tick manually to prove the long-controller
 * re-check. Call cleanup() when done — restores console/env/timer globals.
 */
interface HookHandle {
  lines: string[];
  shutdownCb: (() => Promise<void>) | null;
  /** Registered cadence poll: { ms, cleared, tick } — tick fires the interval body. */
  timer: { ms: number; cleared: boolean; tick: () => Promise<void> } | null;
  cleanup: () => void;
}

async function runHookFull(env: Record<string, string | undefined>, opts: { print?: boolean } = {}): Promise<HookHandle> {
  const lines: string[] = [];
  const origLog = console.log;
  console.log = (msg?: unknown) => lines.push(String(msg));
  const saved: Record<string, string | undefined> = {};
  let startCb: (() => Promise<void>) | null = null;
  let shutdownCb: (() => Promise<void>) | null = null;
  const timer: { ms: number; cleared: boolean; tick: () => Promise<void> } = { ms: 0, cleared: false, tick: async () => {} };
  const origSetInterval = globalThis.setInterval;
  const origClearInterval = globalThis.clearInterval;
  (globalThis as any).setInterval = (fn: () => void, ms: number) => {
    timer.ms = ms;
    timer.tick = async () => { await fn(); };
    return { unref: () => {}, ref: () => {} } as unknown as ReturnType<typeof setInterval>;
  };
  (globalThis as any).clearInterval = () => { timer.cleared = true; };
  const pi: FakePi = {
    on: (event, cb) => {
      if (event === "session_start") startCb = cb;
      else if (event === "session_shutdown") shutdownCb = cb;
    },
  };
  let cleaned = false;
  const cleanup = () => {
    if (cleaned) return;
    cleaned = true;
    console.log = origLog;
    (globalThis as any).setInterval = origSetInterval;
    (globalThis as any).clearInterval = origClearInterval;
    for (const k of HOOK_ENV_KEYS) {
      if (saved[k] === undefined) delete process.env[k];
      else process.env[k] = saved[k];
    }
  };
  try {
    for (const k of HOOK_ENV_KEYS) {
      saved[k] = process.env[k];
      if (env[k] === undefined) delete process.env[k];
      else process.env[k] = env[k];
    }
    delete process.env.PI_MODE; // interactive-equivalent (pi never sets it)
    if (opts.print) process.env.PI_MODE = "print"; // sub-agent class
    sessionChecksHook(pi as never);
    if (startCb) await startCb();
    return { lines, shutdownCb, timer: timer.ms > 0 ? timer : null, cleanup };
  } catch (err) {
    cleanup();
    throw err;
  }
}

/** Convenience wrapper: lines only, auto-cleanup (pre-#619 hook tests). */
async function runHook(env: Record<string, string | undefined>): Promise<string[]> {
  const h = await runHookFull(env);
  try {
    return h.lines;
  } finally {
    h.cleanup();
  }
}


async function main() {

// ── 1. due() gate math ─────────────────────────────────────────────────
await test("due: fresh run is not due", () => {
  const now = 1_000_000;
  equal(due(now, now - 60, 6), false, "ran 1 min ago → not due (6h window)");
});
await test("due: exactly at the window boundary is due", () => {
  const now = 1_000_000;
  equal(due(now, now - 6 * HOUR, 6), true, "ran 6h ago → due");
});
await test("due: hours <= 0 disables the window", () => {
  equal(due(1_000_000, 0, 0), false);
  equal(due(1_000_000, 0, -1), false);
});
await test("due: never-ran is due", () => {
  equal(due(1_000_000, 0, 6), true);
});

await test("hub window 0 (disabled) → never auto-runs even when never-ran", async () => {
  const { d, state, infra } = tmp();
  makeInfra(infra);
  const calls: Array<{ name: string; cmd: string; args: string[] }> = [];
  const s = await runSessionChecks({ infraPath: infra, state, nowSec: 1_000_000, hubHours: 0, oracleHours: 24, exec: recordingExec(calls) });
  equal(s.ran.length, 1, "only oracle ran (hub disabled)");
  equal(calls.filter((c) => c.name === "hub").length, 0, "hub never invoked");
  rmSync(d, { recursive: true, force: true });
});

// ── 2. lastRunEpoch ────────────────────────────────────────────────────
await test("lastRunEpoch: missing file → 0", () => {
  const { d, state } = tmp();
  equal(lastRunEpoch(state, "hub-state-check"), 0);
  rmSync(d, { recursive: true, force: true });
});
await test("lastRunEpoch: reads epoch + ignores garbage", () => {
  const { d, state } = tmp();
  mkdirSync(state, { recursive: true });
  writeFileSync(join(state, "hub-state-check.last"), "12345");
  equal(lastRunEpoch(state, "hub-state-check"), 12345);
  writeFileSync(join(state, "hub-state-check.last"), "not-a-number");
  equal(lastRunEpoch(state, "hub-state-check"), 0, "garbage → 0 (never ran)");
  rmSync(d, { recursive: true, force: true });
});

// ── 3. repo resolution ─────────────────────────────────────────────────
await test("resolveHubRepos: agent-infra + sibling tortoise; absent siblings skipped (#615/#619)", () => {
  withCleanRepoEnv(() => {
    const { d, infra } = tmp();
    makeInfra(infra); // sibling tortoise already created by tmp()
    const repos = resolveHubRepos(infra);
    equal(repos.length, 2, "default = agent-infra + the one present sibling (tortoise)");
    ok(repos.includes(infra), "agent-infra included (hub discipline exemption #99 removed, #615)");
    ok(repos.includes(join(dirname(infra), "tortoise")), "sibling tortoise resolved");
    for (const name of ["premise-labs", "DMeer", "eldato"]) {
      ok(!repos.includes(join(dirname(infra), name)), `${name} absent → not checked (existence-gated, #619)`);
    }
    rmSync(d, { recursive: true, force: true });
  });
});
await test("resolveHubRepos: all sibling hub defaults resolve when present (#619)", () => {
  withCleanRepoEnv(() => {
    const { d, infra } = tmp();
    makeInfra(infra);
    makeHubSiblings(d); // tortoise + premise-labs + DMeer + eldato
    const repos = resolveHubRepos(infra);
    equal(repos.length, 1 + HUB_SIBLING_DEFAULT_NAMES.length, "agent-infra + all 4 sibling hubs");
    for (const name of HUB_SIBLING_DEFAULT_NAMES) {
      ok(repos.includes(join(dirname(infra), name)), `sibling ${name} resolved (#619)`);
    }
    ok(repos.includes(infra), "agent-infra first (#615)");
    rmSync(d, { recursive: true, force: true });
  });
});
await test("resolveHubRepos: TORTOISE_REPO env + extras, dedupe, skip nonexistent", () => {
  withCleanRepoEnv(() => {
    const { d, infra } = tmp();
    makeInfra(infra);
    process.env.TORTOISE_REPO = join(dirname(infra), "env-tortoise");
    mkdirSync(process.env.TORTOISE_REPO, { recursive: true });
    process.env.SESSION_CHECKS_REPOS = `${join(dirname(infra), "extra-repo")} /nonexistent ${join(dirname(infra), "env-tortoise")}`;
    mkdirSync(join(dirname(infra), "extra-repo"), { recursive: true });
    const repos = resolveHubRepos(infra);
    // agent-infra + env tortoise + sibling tortoise + extra — nonexistent skipped, env duplicate deduped
    equal(repos.length, 4, "infra + env + sibling + extra");
    ok(repos.includes(infra), "agent-infra included (#615)");
    ok(repos.includes(process.env.TORTOISE_REPO));
    ok(repos.includes(join(dirname(infra), "tortoise")));
    ok(repos.includes(join(dirname(infra), "extra-repo")));
    rmSync(d, { recursive: true, force: true });
  });
});
await test("resolveHubRepos: nothing found → empty (orchestrator skips hub leg)", () => {
  withCleanRepoEnv(() => {
    const { d, infra } = tmp();
    makeInfra(infra);
    rmSync(join(dirname(infra), "tortoise"), { recursive: true, force: true });
    rmSync(infra, { recursive: true, force: true }); // no agent-infra either (#615)
    equal(resolveHubRepos(infra).length, 0, "no repos when no infra/sibling/env");
    rmSync(d, { recursive: true, force: true });
  });
});

// ── 4. orchestration: due + fresh + lock ──────────────────────────────
await test("ran recently (state seeded) → nothing runs (silent)", async () => {
  const { d, state, infra } = tmp();
  makeInfra(infra);
  mkdirSync(state, { recursive: true });
  const now = 1_000_000;
  // Seed recent run epochs → both checks fresh → zero exec.
  writeFileSync(join(state, "hub-state-check.last"), String(now - 60));
  writeFileSync(join(state, "skill-lint-oracle.last"), String(now - 60));
  const calls: Array<{ name: string; cmd: string; args: string[] }> = [];
  const s = await runSessionChecks({ infraPath: infra, state, nowSec: now, hubHours: 6, oracleHours: 24, exec: recordingExec(calls) });
  equal(s.ran.length, 0, "no checks ran");
  equal(calls.length, 0, "no exec at all");
  rmSync(d, { recursive: true, force: true });
});

await test("never-ran → hub + oracle both run once, epochs recorded", async () => {
  const { d, state, infra } = tmp();
  makeInfra(infra);
  const calls: Array<{ name: string; cmd: string; args: string[] }> = [];
  const now = 1_000_000;
  const s = await runSessionChecks({ infraPath: infra, state, nowSec: now, hubHours: 6, oracleHours: 24, exec: recordingExec(calls) });
  equal(s.ran.length, 2, "both ran");
  const names = calls.map((c) => c.name).sort();
  equal(names.join(","), "hub,oracle", "hub then oracle");
  const hubCall = calls.find((c) => c.name === "hub")!;
  ok(hubCall.args.some((a) => a.includes("hub-state-check.sh")), "hub invoked its script");
  ok(hubCall.args.includes("--gh-report"), "hub runs with --gh-report");
  equal(lastRunEpoch(state, "hub-state-check"), now, "hub epoch recorded");
  equal(lastRunEpoch(state, "skill-lint-oracle"), now, "oracle epoch recorded");
  ok(s.lines.some((l) => l.startsWith("hub-state-check: PASS")), "PASS summary line");
  ok(s.lines.some((l) => l.startsWith("skill-lint-oracle: PASS")), "oracle PASS line");
  rmSync(d, { recursive: true, force: true });
});

await test("within window after a run → silent again", async () => {
  const { d, state, infra } = tmp();
  makeInfra(infra);
  const calls: Array<{ name: string; cmd: string; args: string[] }> = [];
  const now = 1_000_000;
  await runSessionChecks({ infraPath: infra, state, nowSec: now, hubHours: 6, oracleHours: 24, exec: recordingExec(calls) });
  const calls2: Array<{ name: string; cmd: string; args: string[] }> = [];
  const s2 = await runSessionChecks({ infraPath: infra, state, nowSec: now + 600, hubHours: 6, oracleHours: 24, exec: recordingExec(calls2) });
  equal(s2.ran.length, 0, "fresh again");
  equal(calls2.length, 0, "no second exec");
  rmSync(d, { recursive: true, force: true });
});

await test("hub FAIL still records epoch (bounded re-runs on cadence)", async () => {
  const { d, state, infra } = tmp();
  makeInfra(infra);
  const now = 1_000_000;
  const failExec = recordingExec([], { code: 1, stderr: "⚠️  agent-infra dirty\n" });
  const s = await runSessionChecks({ infraPath: infra, state, nowSec: now, hubHours: 6, oracleHours: 24, exec: failExec });
  equal(s.ran.length, 2, "both attempted despite hub FAIL");
  ok(s.lines.some((l) => l.startsWith("hub-state-check: FAIL rc=1")), "FAIL surfaced");
  equal(lastRunEpoch(state, "hub-state-check"), now, "attempt epoch recorded despite FAIL");
  // next session within the window: no re-run (bounded)
  const calls2: Array<{ name: string; cmd: string; args: string[] }> = [];
  const s2 = await runSessionChecks({ infraPath: infra, state, nowSec: now + 60, hubHours: 6, oracleHours: 24, exec: recordingExec(calls2) });
  equal(s2.ran.length, 0, "no immediate re-run after FAIL");
  rmSync(d, { recursive: true, force: true });
});

await test("lock contention: concurrent session skips; stale lock taken over", async () => {
  const { d, state, infra } = tmp();
  makeInfra(infra);
  mkdirSync(join(state, "locks"), { recursive: true });
  const now = 1_000_000;
  // Fresh lock held by another session → hub skipped, oracle still runs.
  mkdirSync(join(state, "locks", "hub-state-check.lock"));
  const calls: Array<{ name: string; cmd: string; args: string[] }> = [];
  const s = await runSessionChecks({ infraPath: infra, state, nowSec: now, hubHours: 6, oracleHours: 24, exec: recordingExec(calls) });
  equal(calls.filter((c) => c.name === "hub").length, 0, "hub skipped under foreign lock");
  ok(s.lines.some((l) => l.includes("hub-state-check: skipped (another session")), "skip line surfaced");
  equal(calls.filter((c) => c.name === "oracle").length, 1, "oracle unaffected by hub lock");
  // Stale lock (>30 min — LOCK_STALE_MS) → taken over.
  const old = new Date(Date.now() - 35 * 60 * 1000);
  utimesSync(join(state, "locks", "hub-state-check.lock"), old, old);
  const s2 = await runSessionChecks({ infraPath: infra, state, nowSec: now, hubHours: 6, oracleHours: 24, exec: recordingExec(calls) });
  equal(calls.filter((c) => c.name === "hub").length, 1, "stale lock taken over → hub ran");
  rmSync(d, { recursive: true, force: true });
});

await test("oracle FAIL tail surfaced + bounded", async () => {
  const { d, state, infra } = tmp();
  makeInfra(infra);
  const now = 1_000_000;
  const log: Array<{ name: string; cmd: string; args: string[] }> = [];
  let oracleCalls = 0;
  const exec: ExecFn = async (cmd, args) => {
    if (cmd === "bash" && args[0]?.includes("hub-state-check")) return { code: 0, stdout: "", stderr: "", timedOut: false };
    oracleCalls += 1;
    log.push({ name: "oracle", cmd, args });
    return { code: 2, stdout: "", stderr: "❌ oracle environment failure (pi not found?)\n", timedOut: false };
  };
  const s = await runSessionChecks({ infraPath: infra, state, nowSec: now, hubHours: 6, oracleHours: 24, exec });
  equal(oracleCalls, 1, "oracle ran once");
  ok(s.lines.some((l) => l.startsWith("skill-lint-oracle: FAIL rc=2")), "rc=2 surfaced");
  equal(lastRunEpoch(state, "skill-lint-oracle"), now, "attempt recorded on env failure (bounded)");
  const s2 = await runSessionChecks({ infraPath: infra, state, nowSec: now + 60, hubHours: 6, oracleHours: 24, exec });
  equal(oracleCalls, 1, "no immediate re-run");
  rmSync(d, { recursive: true, force: true });
});

await test("no repos resolved → hub leg skipped loudly, oracle still runs", async () => {
  const { d, state, infra } = tmp();
  makeInfra(infra);
  const calls: Array<{ name: string; cmd: string; args: string[] }> = [];
  const now = 1_000_000;
  const s = await runSessionChecks({
    infraPath: infra, state, nowSec: now, hubHours: 6, oracleHours: 24, exec: recordingExec(calls),
    repos: [], // explicit empty (defaults always include agent-infra now, #615)
  });
  equal(calls.filter((c) => c.name === "hub").length, 0, "hub never invoked without a repo");
  ok(s.lines.some((l) => l.includes("no repos")), "skip note surfaced");
  equal(calls.filter((c) => c.name === "oracle").length, 1, "oracle unaffected");
  equal(lastRunEpoch(state, "skill-lint-oracle"), now, "oracle epoch recorded");
  rmSync(d, { recursive: true, force: true });
});

await test("oracle DEFERRED (load gate rc=3) → no epoch burn; re-probes next session", async () => {
  const { d, state, infra } = tmp();
  makeInfra(infra);
  const now = 1_000_000;
  let oracleCalls = 0;
  let oracleEnv: Record<string, string | undefined> | undefined;
  const exec: ExecFn = async (cmd, args, opts) => {
    if (cmd === "bash" && args[0]?.includes("hub-state-check")) return { code: 0, stdout: "", stderr: "", timedOut: false };
    oracleCalls += 1;
    oracleEnv = opts?.env;
    return { code: 3, stdout: "", stderr: "system too loaded — deferred\n", timedOut: false };
  };
  const s = await runSessionChecks({ infraPath: infra, state, nowSec: now, hubHours: 6, oracleHours: 24, exec });
  equal(oracleCalls, 1, "oracle attempted");
  equal(oracleEnv?.LOAD_GATE_MAX_WAIT_MIN, "0", "defer-immediately env passed (no 10-min inline poll)");
  ok(s.lines.some((l) => l.startsWith("skill-lint-oracle: DEFERRED")), "DEFERRED label (not FAIL)");
  equal(s.ran.includes("skill-lint-oracle"), true, "attempt listed");
  equal(lastRunEpoch(state, "skill-lint-oracle"), 0, "NO epoch recorded — deferral burns nothing");
  const s2 = await runSessionChecks({ infraPath: infra, state, nowSec: now + 60, hubHours: 6, oracleHours: 24, exec });
  equal(oracleCalls, 2, "next session re-probes (still due)");
  rmSync(d, { recursive: true, force: true });
});

await test("missing scripts under infra → skip, no exec", async () => {
  const { d, state, infra } = tmp();
  mkdirSync(join(infra, "scripts"), { recursive: true }); // scripts present but not the two
  const calls: Array<{ name: string; cmd: string; args: string[] }> = [];
  const s = await runSessionChecks({ infraPath: infra, state, nowSec: 1_000_000, hubHours: 6, oracleHours: 24, exec: recordingExec(calls) });
  equal(calls.length, 0, "no exec");
  ok(s.lines.some((l) => l.includes("scripts missing")), "missing-scripts note surfaced");
  rmSync(d, { recursive: true, force: true });
});

await test("timed-out exec surfaced as TIMEOUT/ERROR", async () => {
  const { d, state, infra } = tmp();
  makeInfra(infra);
  const now = 1_000_000;
  const exec: ExecFn = async () => ({ code: -1, stdout: "", stderr: "", timedOut: true });
  const s = await runSessionChecks({ infraPath: infra, state, nowSec: now, hubHours: 6, oracleHours: 24, exec });
  ok(s.lines.some((l) => l.includes("TIMEOUT/ERROR")), "timeout surfaced");
  equal(s.ran.length, 2, "both attempted");
  rmSync(d, { recursive: true, force: true });
});

await test("hook: no AGENT_INFRA_PATH → silent, no crash", async () => {
  const lines = await runHook({});
  equal(lines.length, 0, "no output when unconfigured");
});

await test("hook: SESSION_CHECKS_OFF=1 → silent even when due", async () => {
  const { d, state, infra } = tmp();
  makeInfra(infra);
  const lines = await runHook({ AGENT_INFRA_PATH: infra, SESSION_CHECKS_STATE: state, SESSION_CHECKS_OFF: "1", TORTOISE_REPO: infra });
  equal(lines.length, 0, "OFF silences everything");
  rmSync(d, { recursive: true, force: true });
});

await test("hook: fresh epochs (recent runs) → silent", async () => {
  const { d, state, infra } = tmp();
  makeInfra(infra);
  mkdirSync(state, { recursive: true });
  const nowSec = Math.floor(Date.now() / 1000);
  writeFileSync(join(state, "hub-state-check.last"), String(nowSec - 60));
  writeFileSync(join(state, "skill-lint-oracle.last"), String(nowSec - 60));
  const lines = await runHook({ AGENT_INFRA_PATH: infra, SESSION_CHECKS_STATE: state, TORTOISE_REPO: infra });
  equal(lines.length, 0, "silent when both fresh (real exec path untouched)");
  rmSync(d, { recursive: true, force: true });
});

await test("hook: whitespace SESSION_CHECKS_HUB_H falls back to 6h (cycle-3 bug guard)", async () => {
  const { d, state, infra } = tmp();
  makeInfra(infra);
  mkdirSync(state, { recursive: true });
  const nowSec = Math.floor(Date.now() / 1000);
  writeFileSync(join(state, "hub-state-check.last"), String(nowSec - 8 * HOUR)); // due at 6h window
  writeFileSync(join(state, "skill-lint-oracle.last"), String(nowSec - 60)); // oracle fresh
  const lines = await runHook({ AGENT_INFRA_PATH: infra, SESSION_CHECKS_STATE: state, SESSION_CHECKS_HUB_H: "  ", TORTOISE_REPO: infra });
  ok(lines.some((l) => l.includes("hub-state-check:")), "hub ran (blank knob did NOT disable → fallback 6h)");
  ok(!lines.some((l) => l.includes("skill-lint-oracle:")), "oracle stayed silent (fresh)");
  rmSync(d, { recursive: true, force: true });
});

await test("hook: SESSION_CHECKS_HUB_H=0 disables the hub window", async () => {
  const { d, state, infra } = tmp();
  makeInfra(infra);
  mkdirSync(state, { recursive: true });
  const nowSec = Math.floor(Date.now() / 1000);
  writeFileSync(join(state, "hub-state-check.last"), String(nowSec - 8 * HOUR)); // would be due at 6h
  writeFileSync(join(state, "skill-lint-oracle.last"), String(nowSec - 60));
  const lines = await runHook({ AGENT_INFRA_PATH: infra, SESSION_CHECKS_STATE: state, SESSION_CHECKS_HUB_H: "0", TORTOISE_REPO: infra });
  ok(!lines.some((l) => l.includes("hub-state-check:")), "hub never auto-runs at 0");
  rmSync(d, { recursive: true, force: true });
});

// ── 5. cadence poll for long-running controllers (#619) ────────────────
/** Poll a predicate until true or timeout (the interval body fires-and-forgets runChecks). */
async function waitFor(pred: () => boolean, timeoutMs = 3000): Promise<boolean> {
  const start = Date.now();
  while (!pred()) {
    if (Date.now() - start > timeoutMs) return false;
    await new Promise((r) => setTimeout(r, 25));
  }
  return true;
}
await test("clampPollMinutes: default on junk, floor at 5, cap at max", () => {
  equal(clampPollMinutes(NaN), POLL_MIN_DEFAULT);
  equal(clampPollMinutes(0), POLL_MIN_DEFAULT);
  equal(clampPollMinutes(-3), POLL_MIN_DEFAULT);
  equal(clampPollMinutes(2), POLL_MIN_FLOOR, "below-floor clamps UP to the floor");
  equal(clampPollMinutes(17), 17);
  equal(clampPollMinutes(100_000), POLL_MIN_MAX, "runaway knob clamps DOWN to the max (review #635 P2)");
  equal(clampPollMinutes(POLL_MIN_MAX), POLL_MIN_MAX, "exactly at the cap passes through");
});
await test("getPollIntervalMs: env knob (minutes) → ms; default 30 min; over-cap clamped", () => {
  equal(getPollIntervalMs({}), POLL_MIN_DEFAULT * 60_000);
  equal(getPollIntervalMs({ SESSION_CHECKS_POLL_MIN: "10" }), 10 * 60_000);
  equal(getPollIntervalMs({ SESSION_CHECKS_POLL_MIN: "2" }), POLL_MIN_FLOOR * 60_000, "clamped to floor");
  equal(getPollIntervalMs({ SESSION_CHECKS_POLL_MIN: "junk" }), POLL_MIN_DEFAULT * 60_000, "invalid → default");
  equal(getPollIntervalMs({ SESSION_CHECKS_POLL_MIN: "600000" }), POLL_MIN_MAX * 60_000, "ms-unit input (600000) clamps to 6h max — no 1ms hot loop");
});
await test("hook: interactive session registers an unref'd cadence poll (timer lifecycle)", async () => {
  const { d, state, infra } = tmp();
  makeInfra(infra);
  mkdirSync(state, { recursive: true });
  const nowSec = Math.floor(Date.now() / 1000);
  writeFileSync(join(state, "hub-state-check.last"), String(nowSec - 60)); // fresh → silent start pass
  writeFileSync(join(state, "skill-lint-oracle.last"), String(nowSec - 60));
  const h = await runHookFull({ AGENT_INFRA_PATH: infra, SESSION_CHECKS_STATE: state, TORTOISE_REPO: infra });
  try {
    equal(h.lines.length, 0, "fresh start pass stays silent");
    ok(h.timer !== null, "cadence poll registered on interactive session_start");
    equal(h.timer?.ms, POLL_MIN_DEFAULT * 60_000, "default poll = 30 min");
    equal(h.timer?.cleared, false, "not cleared before shutdown");
    await h.shutdownCb?.();
    equal(h.timer?.cleared, true, "poll cleared on session_shutdown");
  } finally {
    h.cleanup();
    rmSync(d, { recursive: true, force: true });
  }
});
await test("hook: SESSION_CHECKS_POLL_MIN knob sets the poll interval", async () => {
  const { d, state, infra } = tmp();
  makeInfra(infra);
  const h = await runHookFull({ AGENT_INFRA_PATH: infra, SESSION_CHECKS_STATE: state, SESSION_CHECKS_POLL_MIN: "7", TORTOISE_REPO: infra });
  try {
    equal(h.timer?.ms, 7 * 60_000, "poll honors the knob");
  } finally {
    h.cleanup();
    rmSync(d, { recursive: true, force: true });
  }
});
await test("hook: print mode (sub-agent) registers NO timer and runs nothing", async () => {
  const { d, state, infra } = tmp();
  makeInfra(infra);
  const h = await runHookFull({ AGENT_INFRA_PATH: infra, SESSION_CHECKS_STATE: state, TORTOISE_REPO: infra }, { print: true });
  try {
    equal(h.lines.length, 0, "no output in print mode");
    equal(h.timer, null, "no cadence poll in print mode (sub-agents stay silent)");
  } finally {
    h.cleanup();
    rmSync(d, { recursive: true, force: true });
  }
});
await test("hook: disabled (SESSION_CHECKS_OFF=1) registers NO timer", async () => {
  const { d, state, infra } = tmp();
  makeInfra(infra);
  const h = await runHookFull({ AGENT_INFRA_PATH: infra, SESSION_CHECKS_STATE: state, SESSION_CHECKS_OFF: "1", TORTOISE_REPO: infra });
  try {
    equal(h.lines.length, 0, "OFF silences the start pass");
    equal(h.timer, null, "OFF → no cadence poll");
  } finally {
    h.cleanup();
    rmSync(d, { recursive: true, force: true });
  }
});
await test("hook: poll tick re-checks on cadence after the window lapses (long-running controller)", async () => {
  const { d, state, infra } = tmp();
  makeInfra(infra);
  mkdirSync(state, { recursive: true });
  const nowSec = Math.floor(Date.now() / 1000);
  writeFileSync(join(state, "hub-state-check.last"), String(nowSec - 8 * HOUR)); // hub due (6h window)
  writeFileSync(join(state, "skill-lint-oracle.last"), String(nowSec - 60)); // oracle fresh
  const h = await runHookFull({ AGENT_INFRA_PATH: infra, SESSION_CHECKS_STATE: state, TORTOISE_REPO: infra });
  try {
    const hubCount = () => h.lines.filter((l) => l.includes("hub-state-check:")).length;
    equal(hubCount(), 1, "start pass ran the due hub check");
    // Simulate the 6h window lapsing again while the SAME session lives.
    writeFileSync(join(state, "hub-state-check.last"), String(Math.floor(Date.now() / 1000) - 8 * HOUR));
    await h.timer?.tick();
    ok(await waitFor(() => hubCount() >= 2), "poll tick re-probed the hub check on cadence (#619)");
    // Fresh again → a tick stays silent (no epoch burn, no output).
    const linesBefore = h.lines.length;
    await h.timer?.tick();
    await new Promise((r) => setTimeout(r, 150)); // give a would-be run time to surface
    equal(h.lines.length, linesBefore, "fresh poll tick stays silent");
  } finally {
    h.cleanup();
    rmSync(d, { recursive: true, force: true });
  }
});

  console.log("");
  console.log(`── Summary ──────────────────────────────────────────────────`);
  console.log(`  PASS=${passed} FAIL=${failed}`);
  if (failed > 0) {
    console.log("  ❌ FAILURES — fix and re-run");
    process.exit(1);
  }
  console.log("  ✅ all checks passed");
}

main();
