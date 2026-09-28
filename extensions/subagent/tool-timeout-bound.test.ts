/**
 * tool-timeout-bound.test.ts — #1500 Leg B: the injected `timeout` really
 * TERMINATES the process tree.
 *
 * Why this file lives under `extensions/subagent/`: it imports the REAL pi tool
 * implementation (`@earendil-works/pi-coding-agent`, a devDependency of this
 * package at the pinned 0.85.1), the same route `timeout-integration.test.ts`
 * and `subagent-parity.test.ts` already use. The gate suite in
 * `extensions/builtin-tools/builtin-tools.test.ts` can only prove that the
 * `tool_call` handler writes a finite positive number into `input.timeout`; it
 * cannot prove that pi acts on it. This file closes that gap — without it, the
 * child could be handed a bound that pi silently ignores, and every claim about
 * Leg B would rest on reading the source.
 *
 * Hermetic: no provider keys, no billed calls, no child `pi` process. Only
 * local `sleep`.
 *
 * Run: npx tsx extensions/subagent/tool-timeout-bound.test.ts
 */

import { createBashTool } from "@earendil-works/pi-coding-agent";
import { ok, equal } from "node:assert/strict";

function testAsync(name: string, fn: () => Promise<void>) {
  tests.push({ name, fn });
}
const tests: { name: string; fn: () => Promise<void> }[] = [];

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

testAsync("#1500 — an injected timeout TERMINATES the command at the bound, and says so", async () => {
  const tool = createBashTool(process.cwd(), { exposeSessionEnvironment: false });
  const started = Date.now();
  let rejected: unknown = null;
  try {
    // The shape a dispatched child's bash call has AFTER the `tool_call` guard
    // runs: `timeout` populated, command long-running.
    await tool.execute("tc-bound", { command: "sleep 30 && echo done", timeout: 2 }, undefined, undefined, {
      cwd: process.cwd(),
    } as any);
  } catch (error) {
    rejected = error;
  }
  const elapsed = Date.now() - started;

  ok(rejected !== null, "a bounded command that overruns MUST reject (not resolve with partial output)");
  const message = rejected instanceof Error ? rejected.message : String(rejected);
  // pi's own wording (dist/core/tools/bash.js). Pinned because the CHILD's
  // recovery depends on the model being able to tell a bound-kill from a crash.
  ok(
    /timed out after 2 seconds/i.test(message),
    `the rejection must name the bound so the model can recover: ${message}`,
  );
  // Proves TERMINATION, not just rejection: an unbounded implementation would
  // return at ~30 s. Generous slack for a loaded box, far below the command's
  // own lifetime.
  ok(elapsed < 15_000, `must terminate near the bound, not at the command's end (elapsed ${elapsed} ms)`);
});

testAsync("#1500 — a command WITHIN the bound is untouched (the bound is not a blanket cap)", async () => {
  const tool = createBashTool(process.cwd(), { exposeSessionEnvironment: false });
  const result = await tool.execute("tc-ok", { command: "echo hi", timeout: 30 }, undefined, undefined, {
    cwd: process.cwd(),
  } as any);
  const text = (result.content ?? []).map((c: any) => c.text ?? "").join("");
  ok(text.includes("hi"), `a command inside the bound returns normally: ${text}`);
});

testAsync("#1500 — an ABSENT timeout parks (the defect #1500 is about) and the bound is what prevents it", async () => {
  const tool = createBashTool(process.cwd(), { exposeSessionEnvironment: false });
  // The control arm: no `timeout` at all. We do not wait it out (that is the
  // 20-minute park); we assert only that the call is still running well past
  // where the bounded call above already rejected — i.e. absence really does
  // mean "no bound", so Leg A alone would not have bounded anything.
  const bounded = createBashTool(process.cwd(), { exposeSessionEnvironment: false });
  let boundedRejected = false;
  const boundedRun = bounded
    .execute("tc-b", { command: "sleep 30", timeout: 2 }, undefined, undefined, { cwd: process.cwd() } as any)
    .then(() => undefined, () => { boundedRejected = true; });
  let unboundedSettled = false;
  const unbounded = tool
    .execute("tc-n", { command: "sleep 30" }, undefined, undefined, { cwd: process.cwd() } as any)
    .then(() => { unboundedSettled = true; }, () => { unboundedSettled = true; });

  await sleep(6_000);
  ok(boundedRejected, "the BOUNDED twin must already have terminated by 6 s");
  equal(unboundedSettled, false, "an ABSENT timeout has no bound — this is exactly why Leg B exists");

  // Clean up the still-running uninstrumented command. (`treeKill`-equivalent:
  // pi's own executor is unreachable here, so signal the shell directly.)
  const { execSync } = await import("node:child_process");
  try {
    execSync("pkill -f 'sleep 30' || true", { stdio: "ignore" });
  } catch {
    /* best effort */
  }
  await Promise.allSettled([boundedRun, unbounded]);
});

(async () => {
  let failed = 0;
  for (const t of tests) {
    try {
      await t.fn();
      console.log(`  ✅ ${t.name}`);
    } catch (error) {
      failed++;
      console.log(`  ❌ ${t.name}`);
      console.log(`     ${error instanceof Error ? error.message : String(error)}`);
    }
  }
  console.log(`\n=== Results: ${tests.length - failed} passed, ${failed} failed ===`);
  if (failed > 0) {
    console.log("❌ SOME TESTS FAILED");
    process.exit(1);
  }
  console.log("✅ ALL TESTS PASSED");
})();
