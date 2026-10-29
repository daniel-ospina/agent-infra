/**
 * cron-rearm.test.ts — the cron tick must survive a session REPLACEMENT, not only a quit.
 *
 * Regression for agent-infra#2948. #2944 cleared `cronTimer` on `session_shutdown` (correct:
 * it is what lets a one-shot `pi -p` exit) and `unref`'d the interval (correct: the
 * load-bearing half of the exit fix). But pi emits `session_shutdown` on session
 * REPLACEMENT as well — `AgentSessionRuntime.teardownCurrent(reason)` with `"new"`,
 * `"resume"`, `"fork"` (pi's event reference: reason is `"quit" | "reload" | "new" |
 * "resume" | "fork"`) — and those flows do NOT re-run extension factories: `teardownCurrent()`
 * is followed by `createRuntime()`, which reuses the SAME `resourceLoader`
 * (`createAgentSession` only calls `resourceLoader.reload()` when it has to construct one).
 * So the factory closure survives while the timer does not. With nothing re-arming it, every
 * cron-type loop silently stopped firing after `/new`, `/resume` or `/fork` until a
 * `/reload` or a restart. This is the rule the repo states verbatim in
 * extensions/repo-freshness.ts: timers start in `session_start`, clear in `session_shutdown`.
 *
 * The fixture is THIS extension's real factory, driven through the real lifecycle events —
 * not a replica of the arming logic. Everything is observed from outside: a `setInterval`
 * spy captures the handle plus the tick callback the scheduler installed, so "armed" means a
 * live handle and "firing" means the captured callback, invoked, still delivers.
 *
 * Four arms, both directions (so neither side can silently become vacuous):
 *   1. `session_shutdown` reason "new"    → cleared, and the following `session_start` RE-ARMS.
 *   2. `session_shutdown` reason "resume" → same.
 *   3. `session_shutdown` reason "fork"   → same.
 *   4. `session_shutdown` reason "quit"   → cleared and STAYS cleared (no `session_start` follows).
 *   plus the re-armed tick is not merely present and unref'd — invoking it FIRES a due cron
 *   manifest through `pi.sendUserMessage`, so an "armed" that could never deliver cannot pass.
 *
 * Exit-probe arm (#2944 must not regress): a child process arms the scheduler through the real
 * factory + `session_start`, then ENDS — deliberately WITHOUT emitting `session_shutdown`, i.e.
 * the exit path where the teardown clear never runs. It must still exit. Only `unref` can make
 * that true, which is what makes this arm the one that reddens when the `unref` is removed.
 *
 * MUTATIONS (both verified):
 *   • delete the `pi.on("session_start", …)` re-arm → arms 1–3 redden (the tick is never
 *     re-created after the clear: "session_start('new') must RE-ARM the tick — got 1 capture(s)").
 *   • delete `scheduler.unref?.()` in scheduler.ts → the exit-probe arm reddens (the child
 *     hangs, `spawnSync` kills it at 15 s, status ≠ 0), and arm 1's `hasRef() === false` pin
 *     reddens in-process.
 *   • delete `if (cronTimer) { clearInterval(cronTimer); cronTimer = null; }` in `armCronScheduler`
 *     → the un-paired `session_start` pin reddens ("an un-paired session_start must CLEAR the
 *     still-live timer before arming …"): 30 passed, 1 failed. Arms 1–3 stay green, because they
 *     are paired and `cronTimer` is null when they re-arm — the leaked interval is only visible
 *     where no shutdown separates one arm from the next.
 *
 * Run: npx tsx extensions/loop-enforcer/cron-rearm.test.ts
 */

import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

let passed = 0;
let failed = 0;

function assert(condition: boolean, msg: string): void {
  if (condition) {
    passed++;
  } else {
    failed++;
    console.error(`  ❌ FAIL: ${msg}`);
  }
}

const HERE = dirname(fileURLToPath(import.meta.url));

// ── Hermetic HOME ──────────────────────────────────────────────────────
// `scheduler.ts` and `manifest.ts` both compute LOOPS_DIR from `homedir()` at IMPORT time,
// so HOME must be redirected BEFORE the extension is imported — hence the dynamic import in
// main(). The fire fixture then lands in a throwaway dir, never in the real ~/.pi.
const REAL_HOME = process.env.HOME;
const TMP = mkdtempSync(join(tmpdir(), "cron-rearm-"));
process.env.HOME = TMP;
delete process.env.LOOP_ENFORCER_DISABLED;
// Expected, harmless fixture noise: `PATTERNS_PATH` and `SESSION_FILE` also live under the
// hermetic HOME, so the factory logs `⚠️ Failed to load patterns.json` and resumes with no
// session context. Patterns govern loop EXIT detection, not the cron arming lifecycle.
const LOOPS_DIR = join(TMP, ".pi", "agent", "loops");

// ── setInterval spy ────────────────────────────────────────────────────
// Observation only: the scheduler calls the global `setInterval`, so wrapping it tells us
// (a) that a tick was installed, (b) its handle, (c) the callback — which we can invoke
// directly instead of waiting 60 s, so "firing" is a real delivery assertion and not a
// 60-second sleep.
interface Capture {
  fn: () => void;
  ms: number;
  handle: any;
}
const captures: Capture[] = [];
const realSetInterval = globalThis.setInterval;

function installIntervalSpy(): void {
  (globalThis as any).setInterval = ((fn: any, ms: any, ...rest: any[]) => {
    const handle = (realSetInterval as any)(fn, ms, ...rest);
    captures.push({ fn, ms: Number(ms), handle });
    return handle;
  }) as any;
}
function restoreIntervalSpy(): void {
  (globalThis as any).setInterval = realSetInterval;
}

/** True only for a handle `clearInterval()` has actually destroyed. The public `hasRef()`
 * cannot answer this: `unref`'d AND destroyed handles both report `false`, so a cleared
 * timer would look identical to a live one and the "quit clears it" arm would be vacuous.
 * Guarded by a type check so a Node-internals change FAILS instead of silently passing. */
function isCleared(handle: any): boolean {
  return typeof handle?._destroyed === "boolean" && handle._destroyed === true;
}

// ── Fake pi + ctx ──────────────────────────────────────────────────────
interface Sent { msg: string; opts?: { deliverAs?: string } }

function makeFakePi() {
  const handlers = new Map<string, Array<(event: any, ctx: any) => any>>();
  const sent: Sent[] = [];
  const pi = {
    handlers,
    sent,
    on(event: string, handler: (event: any, ctx: any) => any) {
      const list = handlers.get(event) ?? [];
      list.push(handler);
      handlers.set(event, list);
    },
    async emit(event: string, data: any = {}, ctx: any = makeCtx()) {
      for (const h of handlers.get(event) ?? []) await h(data, ctx);
    },
    sendUserMessage(msg: string, opts?: { deliverAs?: string }) {
      sent.push({ msg, opts });
    },
    appendEntry() { /* no-op */ },
    registerTool() { /* no-op */ },
    registerCommand() { /* no-op */ },
    registerShortcut() { /* no-op */ },
  };
  return pi;
}

function makeCtx() {
  return {
    cwd: TMP,
    ui: { setStatus() { /* no-op */ } },
    sessionManager: { getSessionId: () => "cron-rearm-test", getEntries: () => [] },
  };
}

/** A cron manifest as the scheduler itself reads one: `.yaml`-named file, JSON content
 * (scheduler.ts filters on the extension and then `JSON.parse`s — its own convention). */
function writeDueCronManifest(slug: string): void {
  mkdirSync(LOOPS_DIR, { recursive: true });
  writeFileSync(
    join(LOOPS_DIR, `${slug}.yaml`),
    JSON.stringify({ loop_type: "cron", status: "running", schedule: "hourly", goal: "fixture goal" }, null, 2),
  );
}

// ── Exit probe (a real child process) ──────────────────────────────────
function runExitProbe(): { status: number | null; signal: string | null; stdout: string; stderr: string; timedOut: boolean } {
  const indexUrl = pathToFileURL(join(HERE, "index.ts")).href;
  const probeFile = join(TMP, "exit-probe.ts");
  writeFileSync(probeFile, `
async function main() {
  const idx = await import(${JSON.stringify(indexUrl)});
  const handlers = new Map();
  const CTX = { cwd: process.env.HOME, ui: { setStatus() {} }, sessionManager: { getSessionId: () => "exit-probe", getEntries: () => [] } };
  const pi = {
    on(ev, h) { const l = handlers.get(ev) || []; l.push(h); handlers.set(ev, l); },
    async emit(ev, data) { for (const h of handlers.get(ev) || []) await h(data, CTX); },
    sendUserMessage() {}, appendEntry() {}, registerTool() {}, registerCommand() {}, registerShortcut() {},
  };
  let ticks = 0;
  const realSetInterval = globalThis.setInterval;
  globalThis.setInterval = function (fn, ms, ...rest) { ticks++; return realSetInterval(fn, ms, ...rest); };
  idx.default(pi);
  await pi.emit("session_start", { reason: "startup" });
  process.stdout.write("ARMED ticks=" + ticks + "\\n");
  // END. Deliberately NO session_shutdown: this is the exit path where the teardown clear
  // never runs, so only the unref in scheduler.ts can let the process exit.
}
main().catch((e) => { console.error("EXIT-PROBE ERROR", (e && e.stack) || e); process.exit(3); });
`);

  const env: Record<string, string> = {};
  for (const [k, v] of Object.entries(process.env)) if (v !== undefined) env[k] = v as string;
  env.HOME = TMP;
  delete env.LOOP_ENFORCER_DISABLED;

  const r = spawnSync(process.execPath, [...process.execArgv, probeFile], {
    env,
    encoding: "utf8",
    timeout: 15_000,
  });
  const timedOut = r.error != null && (r.error as any).code === "ETIMEDOUT";
  return {
    status: r.status,
    signal: r.signal,
    stdout: r.stdout ?? "",
    stderr: r.stderr ?? "",
    timedOut: timedOut || (r.status === null && r.signal != null),
  };
}

// ── Suite ──────────────────────────────────────────────────────────────
async function main(): Promise<void> {
  // Import AFTER HOME is redirected: LOOPS_DIR is fixed at module load.
  assert(homedir() === TMP, "hermetic HOME is in effect before the extension is imported");
  const { default: extension } = await import(pathToFileURL(join(HERE, "index.ts")).href);

  const pi = makeFakePi();
  installIntervalSpy();
  try {
    extension(pi as any);

    // ── 0. Factory load arms exactly one 1-minute tick ──
    console.log("\nArm 0 — factory load:");
    assert(captures.length === 1, `factory load arms the cron tick exactly once (captured ${captures.length})`);
    const boot = captures[0]!;
    assert(boot.ms === 60_000, `the tick is the 1-minute cron interval (got ${boot.ms}ms)`);
    assert(
      boot.handle.hasRef() === false,
      "the interval is unref'd at creation — it must NOT hold the host process open (#2935)",
    );

    // ── 1–3. Replacement flows: cleared by shutdown, RE-ARMED by session_start ──
    for (const reason of ["new", "resume", "fork"] as const) {
      console.log(`\nArm — session_shutdown reason="${reason}" then session_start reason="${reason}":`);
      const before = captures.length;
      await pi.emit("session_shutdown", { reason });
      const cleared = captures[captures.length - 1]!;
      assert(isCleared(cleared.handle), `shutdown("${reason}") clears the cron tick`);
      assert(
        captures.length === before,
        `shutdown("${reason}") does not itself arm a new tick (captured ${captures.length}, expected ${before})`,
      );

      await pi.emit("session_start", { reason });
      assert(
        captures.length === before + 1,
        `session_start("${reason}") must RE-ARM the tick after the clear — got ${captures.length - before} new capture(s), expected 1 (#2948)`,
      );
      const rearmed = captures[captures.length - 1]!;
      assert(rearmed.handle !== cleared.handle, `session_start("${reason}") creates a NEW handle, not a resurrected one`);
      assert(
        rearmed.handle.hasRef() === false,
        `the re-armed tick is unref'd too — re-arming must not reintroduce the #2935 exit hang`,
      );
      assert(rearmed.ms === 60_000, `the re-armed tick keeps 1-minute granularity (got ${rearmed.ms}ms)`);
    }

    // ── Firing: the re-armed tick still DELIVERS a due cron trigger ──
    // "Armed" is only worth asserting if the thing that is armed can still do its job: an
    // interval that exists but whose callback is dead would pass a handle-only check.
    console.log("\nArm — the re-armed tick fires a due cron manifest:");
    // This `session_start` is deliberately UN-PAIRED — no `session_shutdown` between it and
    // the re-arm that preceded it, so `cronTimer` still points at a LIVE handle. Arms 1–3 are
    // paired, so they cannot exercise the clear-then-set half of the arm path (`cronTimer` is
    // already null when they re-arm); this is the only pairing that does. Delete
    // `if (cronTimer) clearInterval(cronTimer)` from `armCronScheduler` and every other arm
    // stays green while one interval leaks (probe: captured=5, live=2) — hence this pin.
    const priorHandle = captures[captures.length - 1]!;
    await pi.emit("session_start", { reason: "startup" });
    const live = captures[captures.length - 1]!;
    assert(
      isCleared(priorHandle.handle),
      "an un-paired session_start must CLEAR the still-live timer before arming: a re-arm that only sets leaks one interval per extra session_start (clear-then-set is what makes the double call safe)",
    );
    assert(
      !isCleared(live.handle),
      "the tick we fire is the LIVE handle, not a cleared/retired one — otherwise this arm would pass on a dead timer",
    );
    writeDueCronManifest("cron-rearm-fixture");
    const sentBefore = pi.sent.length;
    live.fn(); // the real tick, invoked instead of waiting 60 s
    const fired = pi.sent.slice(sentBefore);
    assert(
      fired.some((s) => s.msg.includes("[loop-enforcer] Cron trigger: cron-rearm-fixture")),
      `the re-armed tick delivers the cron trigger to pi.sendUserMessage (got ${JSON.stringify(fired.map((s) => s.msg))})`,
    );
    assert(
      fired.some((s) => s.opts?.deliverAs === "followUp"),
      "the trigger is delivered as a follow-up (it must reach the CURRENT session, which is what the shared runtime rebinds)",
    );

    // ── 4. Quit: cleared, and it STAYS cleared ──
    console.log('\nArm — session_shutdown reason="quit":');
    const beforeQuit = captures.length;
    await pi.emit("session_shutdown", { reason: "quit" });
    const quitCleared = captures[captures.length - 1]!;
    assert(isCleared(quitCleared.handle), 'shutdown("quit") clears the cron tick');
    assert(
      captures.length === beforeQuit,
      `nothing is armed after a quit — no session_start follows (captured ${captures.length}, expected ${beforeQuit})`,
    );
  } finally {
    restoreIntervalSpy();
  }

  // ── Exit probe: #2944's fix must not regress ──
  console.log("\nArm — one-shot exit with the scheduler ARMED (no shutdown clear):");
  const probe = runExitProbe();
  assert(
    probe.stdout.includes("ARMED") && /ARMED ticks=(\d+)/.test(probe.stdout),
    `the exit probe reached the armed state before exiting (stdout: ${JSON.stringify(probe.stdout.trim())}, stderr: ${JSON.stringify(probe.stderr.slice(-400))})`,
  );
  const ticks = Number((probe.stdout.match(/ARMED ticks=(\d+)/) ?? [])[1] ?? 0);
  assert(ticks >= 1, `the exit probe really armed a tick (ticks=${ticks}) — otherwise the exit assertion is vacuous`);
  assert(
    probe.status === 0 && !probe.timedOut,
    `a process that armed the cron tick must still exit (status=${probe.status}, signal=${probe.signal}, timedOut=${probe.timedOut}) — a ref'd interval is what hung every cell lane (#2935)`,
  );
}

main()
  .catch((err) => {
    failed++;
    console.error(`  ❌ FAIL: suite threw: ${err?.stack ?? err}`);
  })
  .finally(() => {
    process.env.HOME = REAL_HOME;
    try { rmSync(TMP, { recursive: true, force: true }); } catch { /* best effort */ }
    console.log(`\ncron-rearm: ${passed} passed, ${failed} failed`);
    if (failed > 0) process.exit(1);
  });
