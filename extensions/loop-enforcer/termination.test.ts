/**
 * Self-check: termination.test.ts
 * Run: npx tsx extensions/loop-enforcer/termination.test.ts
 */

import { evaluateTermination, STALL_THRESHOLD, type CycleData } from "./termination.ts";

let passed = 0;
let failed = 0;
function assert(cond: boolean, label: string) { cond ? passed++ : (failed++, console.error(`❌ ${label}`)); }

function cycle(n: number, issues: number, verdict = "NEEDS_FIX", fingerprints?: string[], issuesFixed = 0): CycleData {
  return { cycleNumber: n, issuesFound: issues, issuesFixed, verdict, fingerprints, filesChanged: 0, wallClockMs: 0 };
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

// ── L3a: honest-stuck (count non-decreasing ×3) ──────
//
// Canonical (`code-review/SKILL.md` §Stuckness detection): NON-DECREASING over
// 3 consecutive cycles, independent of recurrence. The constant-count case is a
// subset, so a test that only pins 4,4,4 cannot see the difference between this
// layer and the "plateau" it replaced.
{
  // Non-decreasing AND constant → escalate, labelled `honest-stuck`.
  const r = evaluateTermination([
    cycle(1, 4, "NEEDS_FIX", undefined, 2),
    cycle(2, 4, "NEEDS_FIX", undefined, 1),
    cycle(3, 4, "NEEDS_FIX", undefined, 1),
  ], 10);
  assert(r.shouldExit && r.reason === "L3-deadlock" && r.escalate, "L3: count non-decreasing ×3 → escalate");
  assert(r.detector === "honest-stuck", "L3: constant count → detector is honest-stuck");
  assert(r.message.startsWith("honest-stuck"), "L3: honest-stuck message names the detector");
}
{
  // ⛔ The case the equality test missed: CHURN. Every issue fixed, a new one
  // appearing in its place — 3→4→5 is non-decreasing but never constant. The
  // canonical layer fires here (it is exactly the regression its prose records);
  // the plateau predicate this replaced did not.
  const r = evaluateTermination([
    cycle(1, 3, "NEEDS_FIX", undefined, 1),
    cycle(2, 4, "NEEDS_FIX", undefined, 1),
    cycle(3, 5, "NEEDS_FIX", undefined, 1),
  ], 10);
  assert(r.shouldExit && r.detector === "honest-stuck", "L3: churn 3→4→5 (non-decreasing, not constant) → honest-stuck");
}
{
  // ⛔ WINDOW POSITION on the honest-stuck arm — only the LAST three cycles may
  // count. Counts 5,4,3 then 3,4,5: DECLINING on the first triple, non-decreasing
  // on the final one. The canonical layer fires on the last three; a
  // `cycles.slice(0, 3)` window reads the opening decline and never fires. Every
  // other assertion in this file passes under that mutant (all the arm's other
  // fixtures are n=3, or non-monotonic on both triples), so this cell is the one
  // that pins the window — and the arm is LIVE, unlike the fingerprint detector.
  const r = evaluateTermination([
    cycle(1, 5, "NEEDS_FIX", undefined, 1),
    cycle(2, 4, "NEEDS_FIX", undefined, 1),
    cycle(3, 3, "NEEDS_FIX", undefined, 1),
    cycle(4, 3, "NEEDS_FIX", undefined, 1),
    cycle(5, 4, "NEEDS_FIX", undefined, 1),
    cycle(6, 5, "NEEDS_FIX", undefined, 1),
  ], 10);
  assert(r.shouldExit && r.detector === "honest-stuck", "L3: honest-stuck window is the LAST three cycles, not the first");
}
{
  // Shrinking count → the loop IS converging; neither detector may fire.
  const r = evaluateTermination([
    cycle(1, 5, "NEEDS_FIX", ["m"], 1),
    cycle(2, 4, "NEEDS_FIX", ["n"], 1),
    cycle(3, 3, "NEEDS_FIX", ["o"], 1),
  ], 10);
  assert(!r.shouldExit, "L3: shrinking count + novel fingerprints → continue");
}
{
  // Same count but only 2 cycles → the count signal needs 3.
  const r = evaluateTermination([
    cycle(1, 4, "NEEDS_FIX", undefined, 1),
    cycle(2, 4, "NEEDS_FIX", undefined, 1),
  ], 10);
  assert(!r.shouldExit, "L3: non-decreasing count over 2 cycles → continue");
}
{
  // Same count 3 but at 0 → delegated, not honest-stuck: L5 owns the
  // zero-progress count class (and `issuesFound > 0` would have excluded it).
  const r = evaluateTermination([
    cycle(1, 0, "CLEAN", undefined, 0),
    cycle(2, 0, "NEEDS_FIX", undefined, 0),
    cycle(3, 0, "NEEDS_FIX", undefined, 0),
  ], 10);
  assert(r.shouldExit && r.reason === "L5-diminishing-returns", "L5: 0-issue cycles → diminishing returns");
}

// ── L3b: fingerprint-stall (|current ∩ prev| / |prev|) ───
{
  // The canonical case: the same issue set recurs. `issuesFound` is deliberately
  // NON-monotonic so honest-stuck cannot stand in — the only path to L3 is the
  // recurrence detector. Delete the fingerprint block and this goes red.
  const r = evaluateTermination([
    cycle(1, 3, "NEEDS_FIX", ["bugA"], 1),
    cycle(2, 5, "NEEDS_FIX", ["bugA"], 1),
    cycle(3, 4, "NEEDS_FIX", ["bugA"], 1),
  ], 10);
  assert(r.shouldExit && r.reason === "L3-deadlock" && r.escalate, "L3: recurring fingerprint → escalate");
  assert(r.detector === "fingerprint-stall", "L3: recurrence → detector is fingerprint-stall");
  assert(r.message.startsWith("fingerprint-stall"), "L3: fingerprint-stall message names the detector");
}
{
  // ⛔ SUPERSET RECURRENCE — the case a whole-set digest scores 0.0 and the
  // canonical predicate scores 1.0. prev={a,b,c}, curr={a,b,c,d}: nothing was
  // resolved and a new issue appeared. Recurrence = 3/3 = 1.0 → FIRE. (For THIS
  // cell the forbidden symmetric denominator reads 3/max(4,3) = 0.75 — still
  // below 0.8, so the point stands; the skills' 0.67 illustration is their
  // 10-prior-plus-5-new cycle, not this one. The whole-set-digest form read it
  // as 0.00.)
  const r = evaluateTermination([
    cycle(1, 3, "NEEDS_FIX", ["a", "b", "c"], 1),
    cycle(2, 4, "NEEDS_FIX", ["a", "b", "c", "d"], 1),
  ], 10);
  assert(r.shouldExit && r.detector === "fingerprint-stall", "L3: superset recurrence scores 1.0 → fingerprint-stall");
}
{
  // Fires from the SECOND cycle — one transition is enough (canonical), and the
  // `|prev|` denominator is what makes an exact repeat score 1.0 here.
  const r = evaluateTermination([
    cycle(1, 4, "NEEDS_FIX", ["x", "y"], 1),
    cycle(2, 3, "NEEDS_FIX", ["x", "y"], 1),
  ], 10);
  assert(r.shouldExit && r.detector === "fingerprint-stall", "L3: identical set on cycle 2 → fingerprint-stall (no one-cycle lag)");
}
{
  // ⛔ THRESHOLD BOUNDARY at exactly 0.8: 4 of the previous 5 issues recurred.
  // This is why the per-issue SET matters — 0.8 is unreachable when the only
  // computable quantity is "identical / not identical". Pins `>=` against `>`.
  const r = evaluateTermination([
    cycle(1, 5, "NEEDS_FIX", ["a", "b", "c", "d", "e"], 1),
    cycle(2, 4, "NEEDS_FIX", ["a", "b", "c", "d"], 1),
  ], 10);
  assert(r.shouldExit && r.detector === "fingerprint-stall", `L3: recurrence exactly ${STALL_THRESHOLD} → fire (threshold is inclusive)`);
}
{
  // Below the threshold: 3 of 5 = 0.6. The loop is still making progress.
  const r = evaluateTermination([
    cycle(1, 5, "NEEDS_FIX", ["a", "b", "c", "d", "e"], 1),
    cycle(2, 3, "NEEDS_FIX", ["a", "b", "c"], 1),
  ], 10);
  assert(!r.shouldExit, `L3: recurrence 0.6 (< ${STALL_THRESHOLD}) → continue`);
}
{
  // ⛔ WINDOW POSITION — only the LAST PAIR counts. [p,p,q,q]: the repeat sits on
  // the final transition. A 3-cycle window would score the diluted 1/2 = 0.5 and
  // continue; the canonical per-cycle recurrence scores the last pair 1.0.
  const r = evaluateTermination([
    cycle(1, 3, "NEEDS_FIX", ["p"], 1),
    cycle(2, 4, "NEEDS_FIX", ["p"], 1),
    cycle(3, 3, "NEEDS_FIX", ["q"], 1),
    cycle(4, 4, "NEEDS_FIX", ["q"], 1),
  ], 10);
  assert(r.shouldExit && r.detector === "fingerprint-stall", "L3: repeat on the last transition → fingerprint-stall");
}
{
  // The mirror image: the window contains repeats but the LAST pair differs, so
  // there is no current stall. (Counts are non-monotonic so honest-stuck cannot
  // mask this.)
  const r = evaluateTermination([
    cycle(1, 4, "NEEDS_FIX", ["q"], 1),
    cycle(2, 3, "NEEDS_FIX", ["q"], 1),
    cycle(3, 4, "NEEDS_FIX", ["q"], 1),
    cycle(4, 3, "NEEDS_FIX", ["s"], 1),
  ], 10);
  assert(!r.shouldExit, "L3: no recurrence on the last pair → continue");
}
{
  // ⛔ Direction pin (the defect this replaced): mostly-DIFFERENT fingerprints
  // are progress, not a stall. The inverted `uniqueness >= 0.8` predicate would
  // have terminated a loop on exactly this input — had the field ever been
  // populated. Nothing populates `fingerprints` today, so this pins the
  // DIRECTION, not a reproduced live mis-fire.
  const r = evaluateTermination([
    cycle(1, 3, "NEEDS_FIX", ["bugA"], 1),
    cycle(2, 5, "NEEDS_FIX", ["bugB"], 1),
    cycle(3, 4, "NEEDS_FIX", ["bugC"], 1),
  ], 10);
  assert(!r.shouldExit, "L3: novel fingerprints each cycle → continue (not a stall)");
}
{
  // ⛔ SET SEMANTICS on BOTH sides (canonical: `len(current_fps & prev_fps) /
  // len(prev_fps)` over SETS). A repeated digest must not count twice on either
  // side. prev=[a,a,b] is the set {a,b}; curr=[a,b] is the same set ⇒ 2/2 = 1.0
  // ⇒ FIRE. Counting the previous side as a list scored this 2/3 = 0.667 and
  // CONTINUED — a missed stall, the dangerous direction.
  const r = evaluateTermination([
    cycle(1, 4, "NEEDS_FIX", ["a", "a", "b"], 1),
    cycle(2, 3, "NEEDS_FIX", ["a", "b"], 1),
  ], 10);
  assert(r.shouldExit && r.detector === "fingerprint-stall", "L3: a duplicated digest in prev does not dilute recurrence → fingerprint-stall");
}
{
  // ⛔ NUMERATOR ITERATION — the intersection must be counted over the CURRENT
  // set. Canonically `|curr ∩ prev| / |prev|`; the natural misreading of the
  // skill's prose ("what fraction of LAST cycle's issues came back") iterates the
  // PREVIOUS set instead. The two are equal whenever prev is a set (an
  // intersection is symmetric), and differ only when prev has a REPEATED digest
  // that the current cycle does not re-mention — reachable, because
  // `sha256(location + ":" + severity)` collapses two defects sharing both.
  // prev={a,b} (from the list [a,a,b]), curr={a}: canon 1/2 = 0.5 → CONTINUE;
  // iterating prevFps counts `a` twice → 2/2 = 1.0 → false escalation.
  const r = evaluateTermination([
    cycle(1, 4, "NEEDS_FIX", ["a", "a", "b"], 1),
    cycle(2, 1, "NEEDS_FIX", ["a"], 1),
  ], 10);
  assert(!r.shouldExit, "L3: recurrence is counted over the current set — a repeated prev digest the current cycle dropped does not inflate it");
}
{
  // The other direction: curr=[a,a] is the set {a}, so recurrence is 1/2 = 0.5
  // ⇒ continue. Counting the current side as a list scored 2/2 = 1.0 and FIRED,
  // i.e. a false escalation on a cycle where half the prior issues were resolved
  // — the #847 defect class in the opposite direction.
  const r = evaluateTermination([
    cycle(1, 4, "NEEDS_FIX", ["a", "b"], 1),
    cycle(2, 3, "NEEDS_FIX", ["a", "a"], 1),
  ], 10);
  assert(!r.shouldExit, "L3: a duplicated digest in curr does not inflate recurrence → continue");
}
{
  // The ratio must stay inside [0,1]: list-multiplicity let the numerator exceed
  // the denominator and printed "recurrence 300%". Canonically prev={a} and
  // curr={a} is 1/1 = 1.0.
  const r = evaluateTermination([
    cycle(1, 4, "NEEDS_FIX", ["a"], 1),
    cycle(2, 3, "NEEDS_FIX", ["a", "a", "a"], 1),
  ], 10);
  assert(r.shouldExit && r.detector === "fingerprint-stall", "L3: repeated current digests → fingerprint-stall at 100%, never above");
  assert(!r.message.includes("300%"), "L3: recurrence never exceeds 100%");
}
{
  // The legacy empty-string sentinel (`""` = "this cycle has no fingerprint") is
  // DROPPED, not treated as a maximally-recurring digest: a set of them carries
  // no signal, so the fingerprint detector must stay silent (the old code
  // guarded this with `every(f => f !== "")`). Counts are non-monotonic so
  // honest-stuck cannot stand in.
  const r = evaluateTermination([
    cycle(1, 4, "NEEDS_FIX", ["", ""], 1),
    cycle(2, 3, "NEEDS_FIX", ["", ""], 1),
  ], 10);
  assert(!r.shouldExit, "L3: empty-string sentinels carry no signal → continue");
}
{
  // Same guard on the other side, so a partially-sentinel cycle cannot fire.
  const r = evaluateTermination([
    cycle(1, 4, "NEEDS_FIX", ["", ""], 1),
    cycle(2, 3, "NEEDS_FIX", ["", "a"], 1),
  ], 10);
  assert(!r.shouldExit, "L3: an all-sentinel previous cycle gives no recurrence → continue");
}
{
  // A sentinel beside a REAL digest must be dropped from the previous side's SET,
  // not counted as an extra member: `["", "a"]` is the set {a}, so curr=["a"]
  // gives 1/1 = 1.0 → FIRE. Counting the sentinel scored 1/2 = 0.5 and continued
  // — a missed stall, and the case that discriminates the `filter(Boolean)`.
  // (The symmetric curr-side filter is defence in depth: its removal alone is not
  // independently observable, because a stray `""` can only ever be absent from
  // the previous set — noted rather than chased.)
  const r = evaluateTermination([
    cycle(1, 4, "NEEDS_FIX", ["", "a"], 1),
    cycle(2, 3, "NEEDS_FIX", ["a"], 1),
  ], 10);
  assert(r.shouldExit && r.detector === "fingerprint-stall", "L3: a sentinel beside a real digest does not dilute the previous set");
}
{
  // No fingerprints on the previous cycle ⇒ no recurrence is computable ⇒ the
  // fingerprint detector stays silent (fail open for the loop). Non-decreasing
  // counts are absent too, so nothing fires.
  const r = evaluateTermination([
    cycle(1, 5, "NEEDS_FIX", undefined, 1),
    cycle(2, 4, "NEEDS_FIX", ["a"], 1),
  ], 10);
  assert(!r.shouldExit, "L3: no previous fingerprints → no recurrence, no fire");
}
{
  // Absent fingerprints must not swallow the INDEPENDENT count signal: churn
  // with no fingerprints still escalates, as honest-stuck.
  const r = evaluateTermination([
    cycle(1, 3, "NEEDS_FIX", undefined, 1),
    cycle(2, 4, "NEEDS_FIX", undefined, 1),
    cycle(3, 5, "NEEDS_FIX", undefined, 1),
  ], 10);
  assert(r.shouldExit && r.detector === "honest-stuck", "L3: absent fingerprints → honest-stuck still fires");
}
{
  // ⛔ LABEL PRECEDENCE (canon, `fixer-loop.md`:
  // `print('honest-stuck' if honest else 'fingerprint-stall')`): when BOTH
  // signals hold, the count label wins — the skills record the detector because
  // "why did this loop exit" must stay answerable.
  const r = evaluateTermination([
    cycle(1, 4, "NEEDS_FIX", ["a", "b"], 1),
    cycle(2, 4, "NEEDS_FIX", ["a", "b"], 1),
    cycle(3, 4, "NEEDS_FIX", ["a", "b"], 1),
  ], 10);
  assert(r.shouldExit && r.detector === "honest-stuck", "L3: both detectors hold → honest-stuck label wins");
}
{
  // At the cap, L10 owns the exit (it escalates too). Reporting L3 here would
  // spend an extra Ralph-loop recovery on a loop that is already out of cycles.
  const r = evaluateTermination([
    cycle(1, 4, "NEEDS_FIX", ["a"], 1),
    cycle(2, 4, "NEEDS_FIX", ["a"], 1),
    cycle(3, 4, "NEEDS_FIX", ["a"], 1),
    cycle(4, 4, "NEEDS_FIX", ["a"], 1),
  ], 4);
  assert(r.shouldExit && r.reason === "L10-max-cycles", "L3: stall at the cap → L10 owns the exit");
}
{
  // LOCAL literal pin. This assertion CANNOT fail on a skills edit — the
  // cross-artifact check is `tier-config-parity.test.ts`, which parses the
  // declaration out of every live skill surface. Stated as a literal pin so the
  // label does not claim a guard this line does not provide (#723 cycle-2
  // rejected exactly that shape: a constant asserted against itself under a name
  // claiming to pin the live value).
  assert(STALL_THRESHOLD === 0.8, `L3: STALL_THRESHOLD is the literal 0.8 (got ${STALL_THRESHOLD}) — skill parity is pinned in tier-config-parity.test.ts`);
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
