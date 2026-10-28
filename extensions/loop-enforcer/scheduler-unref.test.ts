/**
 * scheduler-unref.test.ts — the cron interval must never hold the host's event loop open.
 *
 * Regression for agent-infra#2935. Measured on two cloud cells: `pi -p` printed its answer and
 * then never exited — killed at 75 s / 200 s / 240 s. The model call was fine (the answer was on
 * stdout, the provider, key and auth all checked out); what kept the process alive was this
 * module's `setInterval`. A Node interval is a REF'd handle: it holds the event loop open until it
 * is cleared, and nothing cleared it. Bisected on the cell — `loop-enforcer` ALONE reproduced the
 * hang, and `scheduler.unref?.()` alone fixed it (control HANGS >30 s; patched exits rc=0 in
 * 6 s / 5 s / 6 s).
 *
 * The assertion is `hasRef() === false`, which is exactly the property that matters and is
 * timing-free: `hasRef()` is true for a handle that keeps the process alive.
 *
 * MUTATION: delete `scheduler.unref?.()` from scheduler.ts and this test reddens — it does NOT
 * rely on a timeout, so the mutation fails immediately rather than hanging the suite.
 *
 * Run: npx tsx extensions/loop-enforcer/scheduler-unref.test.ts
 */

import { startScheduler } from "./scheduler.js";

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

const timer = startScheduler(() => {
  /* no-op: we assert on the handle, never on a tick */
});

assert(typeof (timer as any).hasRef === "function", "startScheduler returns a Node Timeout handle");
assert(
  (timer as any).hasRef() === false,
  "the cron interval is unref'd — it must NOT keep the host process alive (a ref'd interval is what hung every cell lane, #2935)",
);

clearInterval(timer);

console.log(`\nscheduler-unref: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
