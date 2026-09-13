/**
 * Self-check: termination.test.ts
 * Run: npx tsx extensions/loop-enforcer/termination.test.ts
 */

import { evaluateTermination, STALL_THRESHOLD, type CycleData } from "./termination.ts";

let passed = 0;
let failed = 0;
function assert(cond: boolean, label: string) { cond ? passed++ : (failed++, console.error(`❌ ${label}`)); }

function cycle(n: number, issues: number, verdict = "NEEDS_FIX", fingerprint?: string, issuesFixed = 0): CycleData {
  return { cycleNumber: n, issuesFound: issues, issuesFixed, verdict, fingerprint, filesChanged: 0, wallClockMs: 0 };
}

// ── L1: quality gate ──────────────────────────────────
{
  // CLEAN + 0 → exit
  const r = evaluateTermination([cycle(1, 0, "CLEAN")]);
  assert(r.shouldExit && r.reason === "L1-quality-gate", "L1: CLEAN+0 → exit");
}
{
  // NEEDS_FIX + 0 → continue (CLEAN is what matters)
  const r = evaluateTermination([cycle(1, 0, "NEEDS_FIX")]);
  assert(!r.shouldExit, "L1: NEEDS_FIX+0 → continue");
}
{
  // CLEAN but issues > 0 → continue (shouldn't happen, but guard)
  const r = evaluateTermination([cycle(1, 3, "CLEAN")]);
  assert(!r.shouldExit, "L1: CLEAN+3 → continue");
}

// ── L2: convergence — REMOVED (never exits) ───────────
{
  // Issue count declining → continue (L2 no longer exits)
  const r = evaluateTermination([cycle(1, 5), cycle(2, 3)]);
  assert(!r.shouldExit, "L2: declining → continue (not an exit)");
}
{
  // Issue count going up → continue
  const r = evaluateTermination([cycle(1, 3), cycle(2, 5)]);
  assert(!r.shouldExit, "L2: increasing → continue");
}

// ── L3: plateau ───────────────────────────────────────
{
  // Same count 3 cycles → escalate. Assert the MESSAGE too: `reason` alone is
  // produced by both L3 branches, so it cannot distinguish plateau from
  // fingerprint-stall.
  const r = evaluateTermination([
    cycle(1, 4, "NEEDS_FIX", undefined, 2),
    cycle(2, 4, "NEEDS_FIX", undefined, 1),
    cycle(3, 4, "NEEDS_FIX", undefined, 1),
  ], 10);
  assert(r.shouldExit && r.reason === "L3-deadlock" && r.escalate, "L3: plateau 3 cycles → escalate");
  assert(r.message.startsWith("Plateau"), "L3: plateau message names the plateau branch");
}
{
  // Same count but only 2 cycles → no trigger
  const r = evaluateTermination([
    cycle(1, 4, "NEEDS_FIX", undefined, 1),
    cycle(2, 4, "NEEDS_FIX", undefined, 1),
  ], 10);
  assert(!r.shouldExit, "L3: plateau 2 cycles → continue");
}
{
  // Same count 3 but at 0 → L5 catches it (diminishing returns, not plateau)
  const r = evaluateTermination([
    cycle(1, 0, "CLEAN", undefined, 0),
    cycle(2, 0, "NEEDS_FIX", undefined, 0),
    cycle(3, 0, "NEEDS_FIX", undefined, 0),
  ], 10);
  assert(r.shouldExit && r.reason === "L5-diminishing-returns", "L5: 0-issue cycles → diminishing returns");
}
{
  // Fingerprint-stall — the canonical case: the SAME fingerprint across the
  // window. `issuesFound` is deliberately NON-constant so `allSameCount` is
  // false and the plateau branch CANNOT fire; the only path to L3-deadlock is
  // the fingerprint branch. The message assertion pins that, and is what makes
  // this test able to fail: delete the fingerprint block and it goes red.
  const r = evaluateTermination([
    cycle(1, 3, "NEEDS_FIX", "bugA", 1),
    cycle(2, 5, "NEEDS_FIX", "bugA", 1),
    cycle(3, 4, "NEEDS_FIX", "bugA", 1),
  ], 10);
  assert(r.shouldExit && r.reason === "L3-deadlock" && r.escalate, "L3: recurring fingerprint → escalate");
  assert(r.message.startsWith("Fingerprint-stall"), "L3: fingerprint-stall message names the fingerprint branch");
}
{
  // ⛔ Direction pin (the defect this replaced): mostly-DIFFERENT fingerprints
  // are progress, not a stall. `allSameCount` is false here too, so nothing
  // else can fire L3 — this cell is exactly what the inverted `uniqueness >=
  // 0.8` predicate terminated a live loop on.
  const r = evaluateTermination([
    cycle(1, 3, "NEEDS_FIX", "bugA", 1),
    cycle(2, 5, "NEEDS_FIX", "bugB", 1),
    cycle(3, 4, "NEEDS_FIX", "bugC", 1),
  ], 10);
  assert(!r.shouldExit, "L3: novel fingerprints each cycle → continue (not a stall)");
}
{
  // Boundary: one repeated transition out of two (1/2 = 0.5) is BELOW the
  // threshold — the window must be substantially recurrent to fire.
  const r = evaluateTermination([
    cycle(1, 3, "NEEDS_FIX", "bugA", 1),
    cycle(2, 5, "NEEDS_FIX", "bugA", 1),
    cycle(3, 4, "NEEDS_FIX", "bugB", 1),
  ], 10);
  assert(!r.shouldExit, `L3: 1/2 recurrence (< ${STALL_THRESHOLD}) → continue`);
}
{
  // Unpopulated fingerprints carry no signal → never fire the fingerprint branch.
  // (Non-constant counts so plateau cannot stand in for it.)
  const r = evaluateTermination([
    cycle(1, 3, "NEEDS_FIX", undefined, 1),
    cycle(2, 5, "NEEDS_FIX", undefined, 1),
    cycle(3, 4, "NEEDS_FIX", undefined, 1),
  ], 10);
  assert(!r.shouldExit, "L3: absent fingerprints → no fingerprint-stall");
}
{
  // Fingerprints not populated → skip fingerprint check, plateau may catch it
  const r = evaluateTermination([
    cycle(1, 4, "NEEDS_FIX", undefined, 1),
    cycle(2, 4, "NEEDS_FIX", undefined, 1),
    cycle(3, 4, "NEEDS_FIX", undefined, 1),
  ], 10);
  assert(r.reason === "L3-deadlock", "L3: no fingerprints → plateau check fires");
}

// ── L5: diminishing returns ───────────────────────────
{
  // issuesFixed = 0 for last 3, NOT CLEAN → L5 fires
  const r = evaluateTermination([
    cycle(1, 5, "NEEDS_FIX", undefined, 0),
    cycle(2, 4, "NEEDS_FIX", undefined, 0),
    cycle(3, 3, "NEEDS_FIX", undefined, 0),
  ], 10);
  assert(r.shouldExit && r.reason === "L5-diminishing-returns", "L5: 0 fixes for 3 cycles → exit");
}

// ── L7: error threshold ───────────────────────────────
{
  const r = evaluateTermination([], 10, Infinity, Date.now(), Infinity, 3);
  assert(r.shouldExit && r.reason === "L7-error-threshold" && r.escalate, "L7: 3 failures → escalate");
}
{
  const r = evaluateTermination([], 10, Infinity, Date.now(), Infinity, 2);
  assert(!r.shouldExit, "L7: 2 failures → continue");
}

// ── L9: abort ─────────────────────────────────────────
{
  const r = evaluateTermination([], 10, Infinity, Date.now(), Infinity, 0, 0, 100_000, true);
  assert(r.shouldExit && r.reason === "L9-external-abort", "L9: user aborted → exit");
}

// ── L10: max cycles ───────────────────────────────────
{
  const c = Array.from({ length: 10 }, (_, i) => cycle(i + 1, 2, "NEEDS_FIX", undefined, 1));
  const r = evaluateTermination(c, 10);
  assert(r.shouldExit && r.reason === "L10-max-cycles" && r.escalate, "L10: 10 cycles → escalate");
}
{
  const c = Array.from({ length: 9 }, (_, i) => cycle(i + 1, Math.max(1, 9 - i), "NEEDS_FIX", undefined, 1));
  const r = evaluateTermination(c, 10);
  assert(!r.shouldExit, "L10: 9 cycles → continue");
}
{
  // tier override: micro → 0 max cycles → immediate L10
  const r = evaluateTermination([cycle(1, 1)], 10, Infinity, Date.now(), Infinity, 0, 0, 100_000, false, "micro");
  assert(r.shouldExit && r.reason === "L10-max-cycles", "L10: micro tier → immediate cap");
}

// ── Continue (no trigger) ─────────────────────────────
{
  const r = evaluateTermination([
    cycle(1, 5, "NEEDS_FIX", undefined, 2),
    cycle(2, 3, "NEEDS_FIX", undefined, 1),
    cycle(3, 2, "NEEDS_FIX", undefined, 1),
  ], 10);
  assert(!r.shouldExit, "continue: declining toward zero, keep going");
}

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed > 0 ? 1 : 0);
