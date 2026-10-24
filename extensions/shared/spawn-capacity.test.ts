/**
 * spawn-capacity.test.ts — unit tests for shared/spawn-capacity.ts (#2665)
 * Run: npx tsx extensions/shared/spawn-capacity.test.ts
 *
 * These pin the CLASSIFICATION (which spawn results are verdicts) and the RENDERING
 * (what the capacity refusal says), because the integration pins in
 * `extensions/review-enforcer/index.test.ts` can only assert that SOME refusal fired —
 * the classification's precedence and the "unknown never 0" machine rendering are
 * properties of this module alone.
 */

import {
  classifySpawnOutcome,
  describeSpawnCapacity,
  spawnFaultClass,
  attemptClass,
  readMachineCapacity,
  _setMachineCapacityOverride,
  SPAWN_ATTEMPT_CAP,
  SPAWN_UNSPAWNABLE_TOKEN,
  type SpawnAttempt,
} from "./spawn-capacity.js";
import { ok, equal } from "node:assert/strict";

let passed = 0, failed = 0;
function test(name: string, fn: () => void | Promise<void>) {
  const run = async () => {
    try { await fn(); passed++; console.log(`  ✅ ${name}`); }
    catch (err: any) { failed++; console.log(`  ❌ ${name}: ${err.message}`); }
  };
  run();
}

function section(name: string) { console.log(`\n${name}:`); }

// ── Classification ────────────────────────────────────

section("classifySpawnOutcome — a verdict is counted, an attempt without one is not");

test("a completed reviewer (details with no failure field) IS a verdict", () => {
  const c = classifySpawnOutcome({ details: { model: "m", provider: "p" } });
  equal(c.outcome, "verdict");
  equal(c.evidence, "", "a verdict asserts no failure evidence");
});

test("absent/undefined details — the legacy `fire('tool_result', {toolName:'task'})` shape — stays a verdict", () => {
  // The pre-#2665 counting behaviour is preserved for results that carry NO failure
  // marker: this pin is the over-block guard for every existing producer.
  equal(classifySpawnOutcome(undefined).outcome, "verdict");
  equal(classifySpawnOutcome({}).outcome, "verdict");
  equal(classifySpawnOutcome({ details: null }).outcome, "verdict");
});

test("`status: failed` (retry exhaustion — the measured case) is FAILED, and names the field", () => {
  const c = classifySpawnOutcome({ details: { status: "failed" } });
  equal(c.outcome, "failed");
  equal(c.evidence, "status=failed", "the refusal must be able to print what it read");
});

test("a pre-spawn refusal is REFUSED", () => {
  for (const status of ["invalid-cwd", "invalid-session-id", "circuit_open"]) {
    equal(classifySpawnOutcome({ details: { status } }).outcome, "refused", status);
  }
});

test("`killed: true` is a CUT — and the reason it carries is preserved", () => {
  const c = classifySpawnOutcome({ details: { killed: true, reason: "first-message-stall" } });
  equal(c.outcome, "cut");
  ok(c.evidence.includes("first-message-stall"), `names the bound: ${c.evidence}`);
});

test("killed with NO reason says `unreported` — never a guess about the clause", () => {
  equal(classifySpawnOutcome({ details: { killed: true } }).evidence, "killed=true reason=unreported");
});

test("PRECEDENCE: killed wins over a status field (a killed child's text is not a verdict)", () => {
  const c = classifySpawnOutcome({ details: { killed: true, reason: "cut", status: "done" } });
  equal(c.outcome, "cut", "the strongest producer statement decides");
});

test("terminal run status `cut` (shared/task-runs vocabulary) is a CUT", () => {
  equal(classifySpawnOutcome({ details: { status: "cut" } }).outcome, "cut");
});

test("an explicit tool error with no status is FAILED, and says so", () => {
  const c = classifySpawnOutcome({ isError: true });
  equal(c.outcome, "failed");
  equal(c.evidence, "isError=true status=none");
});

test("an UNRECOGNISED status stays a verdict (a future success status must not become a failure)", () => {
  equal(classifySpawnOutcome({ details: { status: "running" } }).outcome, "verdict");
  equal(classifySpawnOutcome({ details: { status: "banana" } }).outcome, "verdict");
});

// ── the OTHER producer failure shapes (P1 of the code review of #2665) ─────────────────
// The floor may not depend on builtin-tools' #1508 `isError` hook having run FIRST: extension
// order is a readdir, so on one box the hook is upstream and on another it is downstream. These
// pin that the CLASSIFIER reads the producer's own fields, order-independently.
section("classifySpawnOutcome — the producer's other failure shapes (order-independent)");

test("a subagent FAILED result is read from details.results[] (the micro tier's own path)", () => {
  // extensions/subagent sets `isError` on its RETURNED result and carries no status/killed in
  // details — so before this arm, a failed `subagent` reviewer was COUNTED as a review.
  const failed = classifySpawnOutcome({
    details: { mode: "single", agentScope: "user", projectAgentsDir: null, results: [{ exitCode: 1, stopReason: "error" }] },
  });
  equal(failed.outcome, "failed");
  ok(failed.evidence.startsWith("results[]"), `names the per-result field: ${failed.evidence}`);
  // A SUCCESSFUL subagent result stays a verdict — the guard against a blanket over-block.
  equal(
    classifySpawnOutcome({ details: { results: [{ exitCode: 0, stopReason: "stop" }] } }).outcome,
    "verdict",
  );
  // …including each of the stop reasons the subagent tool itself treats as a failure.
  for (const stopReason of ["error", "aborted", "timeout", "cut"]) {
    equal(
      classifySpawnOutcome({ details: { results: [{ exitCode: 0, stopReason }] } }).outcome,
      "failed",
      `stopReason=${stopReason} is a failure to the producer too`,
    );
  }
});

test("a non-zero exitCode is FAILED (composeTaskResult's failure branch carries no status)", () => {
  const c = classifySpawnOutcome({ details: { model: "m", provider: "p", exitCode: 1 } });
  equal(c.outcome, "failed");
  equal(c.evidence, "exitCode=1");
});

test("`exitCode` present is a NO-OUTPUT settle — 0 (clean-empty) and null (signal death) are not verdicts", () => {
  // Third review of #2665: `details.exitCode` is emitted ONLY on a non-clean composition, so its
  // presence — at any value — means the child produced no readable result. `exitCode: 0` is the
  // "SUCCESS-but-SILENT" settle (`reason: clean-empty`), which for a review gate is no verdict.
  equal(classifySpawnOutcome({ details: { exitCode: 0 } }).outcome, "cut");
  equal(classifySpawnOutcome({ details: { exitCode: null } }).outcome, "cut");
  // …EXCEPT the success branch that only adds exitCode after the completion watchdog reaped it.
  equal(
    classifySpawnOutcome({ details: { model: "m", provider: "p", exitCode: 0, killedAfterCompletion: true } }).outcome,
    "verdict",
    "a reaped-after-completion success still carries its verdict",
  );
});

test("a failing FALLBACK leg (`fallbackStatus`) is read, in both refused and failed forms", () => {
  equal(classifySpawnOutcome({ details: { fallbackStatus: "failed" } }).outcome, "failed");
  equal(classifySpawnOutcome({ details: { fallbackStatus: "circuit_open" } }).outcome, "refused");
  equal(classifySpawnOutcome({ details: { fallbackStatus: "done" } }).outcome, "verdict");
});

test("failoverHalt splits: a PRE-SPAWN halt is REFUSED, a halt after an attempt is FAILED", () => {
  const pre = classifySpawnOutcome({ details: { failoverHalt: true, haltAttempted: false, haltReason: "blocked" } });
  equal(pre.outcome, "refused", "no child existed, so it cannot be a capacity retry");
  ok(pre.evidence.includes("haltAttempted=false"), "carries the field that decided it");
  equal(classifySpawnOutcome({ details: { failoverHalt: true, haltAttempted: true } }).outcome, "failed");
});

test("`failoverHopSpawnFailed` and `details.isError` are FAILED", () => {
  equal(classifySpawnOutcome({ details: { failoverHopSpawnFailed: true } }).outcome, "failed");
  equal(classifySpawnOutcome({ details: { isError: true } }).outcome, "failed");
});

test("an EMPTY `results: []` is a REFUSAL, not a verdict (the subagent tool's no-work arms)", () => {
  // Review of #2665: invalid mode / too-many-parallel / missing agent-or-task all return
  // `results: []` with no status and no isError — a request that never ran. Counting it as a
  // review is the same false PASS the module exists to close. A legitimate run always has ≥1.
  const c = classifySpawnOutcome({
    details: { mode: "single", agentScope: "user", projectAgentsDir: null, results: [] },
  });
  equal(c.outcome, "refused");
  equal(c.evidence, "results=[]");
});

test("PRECEDENCE: a cut still outranks every later field", () => {
  equal(
    classifySpawnOutcome({ details: { killed: true, exitCode: 1, results: [{ exitCode: 1 }] } }).outcome,
    "cut",
  );
});

// ── Machine capacity ──────────────────────────────────

section("readMachineCapacity — measures the box, never invents a number");

test("real probe returns a finite ratio or an honest null (never a confident 0 for a failed read)", () => {
  _setMachineCapacityOverride(null);
  const m = readMachineCapacity();
  if (m.load1 !== null) ok(Number.isFinite(m.load1), "load1 is finite when read");
  if (m.cores > 0) {
    ok(m.ratio !== null, "cores known ⇒ a ratio exists");
  } else {
    equal(m.ratio, null, "no cores ⇒ no ratio");
  }
});

test("the override seam renders the operator's cell (4 vCPU, ratio 2.17)", () => {
  _setMachineCapacityOverride({ load1: 8.46, cores: 4, ratio: 2.12 });
  try {
    const m = readMachineCapacity();
    equal(m.cores, 4);
    equal(m.ratio, 2.12);
  } finally {
    _setMachineCapacityOverride(null);
  }
});

// ── Rendering ─────────────────────────────────────────

section("describeSpawnCapacity — the CAPACITY verdict says what it read");

const ATTEMPTS: SpawnAttempt[] = [
  { tool: "task", outcome: "failed", evidence: "status=failed" },
  { tool: "task", outcome: "cut", evidence: "killed=true reason=first-message-stall" },
];

function render(attempts: SpawnAttempt[]) {
  _setMachineCapacityOverride({ load1: 8.46, cores: 4, ratio: 2.12 });
  try { return describeSpawnCapacity(attempts).join("\n"); }
  finally { _setMachineCapacityOverride(null); }
}

test("carries the greppable token and the attempt count", () => {
  const t = render(ATTEMPTS);
  ok(t.includes(SPAWN_UNSPAWNABLE_TOKEN), "the token a monitor greps");
  ok(/2 sub-agent spawn ATTEMPT\(s\), 0 reviewer verdicts counted/.test(t), "counts attempts AND counted verdicts");
});

test("says CAPACITY and refuses the compliance reading", () => {
  const t = render(ATTEMPTS);
  ok(t.includes("CAPACITY fault, NOT a compliance one"), "names the fault class");
  ok(!/No reviewers were dispatched/.test(t), "must NOT print the never-tried sentence");
});

test("renders the machine with the ratio, and the load-scaling bands that explain it", () => {
  const t = render(ATTEMPTS);
  ok(t.includes("load1=8.46 cores=4 ratio=2.12"), `the measured box: ${t}`);
  ok(/1x \(<8\), 2x \(8-15\), 3x \(>=16\)/.test(t), "the bands the bounds actually use");
});

test("names each attempt oldest-first with the evidence it read", () => {
  const t = render(ATTEMPTS);
  const i1 = t.indexOf("1. task FAILED — status=failed");
  const i2 = t.indexOf("2. task CUT — killed=true reason=first-message-stall");
  ok(i1 >= 0 && i2 > i1, "ordered, and each carries its own producer field");
});

test("BELOW the cap: the remedy is a RETRY and names the attempt number", () => {
  const t = render([ATTEMPTS[0]]);
  ok(/RETRY \(attempt 1 of 3\)/.test(t), "states the cap and where this attempt sits");
  ok(!/CAP REACHED/.test(t), "does not tell a retrying lane to stop");
});

test("AT the cap (>=3): stop retrying and report the named verdict", () => {
  const three = [ATTEMPTS[0], ATTEMPTS[1], ATTEMPTS[0]];
  const t = render(three);
  ok(/CAP REACHED \(3 >= 3\)/.test(t), "the cap is stated with the count that reached it");
  ok(/stop retrying/.test(t), "the instruction changes at the cap");
  ok(/still REQUIRED/.test(t), "…and the requirement is never withdrawn");
  ok(!/RETRY \(attempt/.test(t), "no retry advice past the cap");
});

test("a failed machine probe renders `unknown`, never a confident 0", () => {
  _setMachineCapacityOverride({ load1: null, cores: 0, ratio: null });
  try {
    const t = describeSpawnCapacity([ATTEMPTS[0]]).join("\n");
    ok(t.includes("load1=unknown cores=unknown ratio=unknown"), `unread is unknown: ${t}`);
  } finally { _setMachineCapacityOverride(null); }
});

test("a REFUSAL-only history is NOT blamed on load, and gets the remedy that fits it", () => {
  // Review of #2665 (unproven claim): the load paragraph printed verbatim for a refused spawn
  // (`status=invalid-cwd` — a bad cwd), recommending "a less loaded moment" for a fault load does
  // not cause. The load explanation is now CONDITIONED on a cut/failed outcome being observed.
  const refusedOnly: SpawnAttempt[] = [
    { tool: "task", outcome: "refused", evidence: "status=invalid-cwd" },
  ];
  const belowCap = render(refusedOnly);
  ok(!/legitimately stretches every attempt/.test(belowCap), "the load-scaling paragraph is withheld");
  ok(/No attempt in this ledger was cut or exhausted/.test(belowCap), "says load is not the cause");
  ok(/REFUSAL OBSERVED \(status=invalid-cwd\)/.test(belowCap), "names the refusal it read");
  ok(/refused again/.test(belowCap), "says retrying the same argument will not help");
  // F1 (review of #2665): the RETRY branch must not carry the load/child advice either — there
  // was no child, and nothing was cut. Both halves are pinned by ABSENCE.
  ok(!/less loaded moment/.test(belowCap), "no `less loaded moment` remedy for a refusal");
  ok(!/the child needs a/.test(belowCap), "does not claim a child existed");
  ok(!/cut child/.test(belowCap), "does not advise about a cut that did not happen");
  ok(/fix the refused argument named above/.test(belowCap), "the remedy that fits: fix the argument");
  // F2: and the CAP branch keys its advice on the same predicate.
  const atCapRefused = render([refusedOnly[0], refusedOnly[0], refusedOnly[0]]);
  ok(/CAP REACHED/.test(atCapRefused), "the cap still fires");
  ok(!/load-gate/.test(atCapRefused), "no load-gate advice for a refusal ledger");
  ok(/first fix the refused argument/.test(atCapRefused), "the cap advice names the argument instead");
  ok(!/re-dispatch the reviewer/.test(belowCap + atCapRefused), "F3: no intent claim in the remedy");
});

test("F1-residual: the HEADER is conditioned too — no refusal-only ledger claims a child existed", () => {
  // The header used to be unconditional ("its child never returned a verdict") while the same
  // block said no child existed. Pinned as an ABSENCE of the word "child" across the WHOLE
  // refusal-ledger render, which is stronger than the three exact phrases the last review caught.
  const t = render([{ tool: "task", outcome: "refused", evidence: "status=invalid-cwd" }]);
  // The contradiction was the HEADER claiming a child came back ("its child never returned a
  // verdict") beside "no child existed". "child" legitimately appears where it says there was
  // none, so the pin is on the CLAIM, not the word.
  ok(!/child never returned a verdict/.test(t), `header must not claim a returned child: ${t.replace(/\n/g, " | ")}`);
  ok(/refused BEFORE a child existed/.test(t), "says the refusal happened before a child existed");
  ok(/SPAWN-SIDE refusal/.test(t), "names the fault class it can support");
  ok(!/CAPACITY fault/.test(t), "and does not relabel it CAPACITY");
});

test("F6: `circuit_open` is BREAKER state, not an argument to fix", () => {
  const breakerOnly: SpawnAttempt[] = [
    { tool: "task", outcome: "refused", evidence: "status=circuit_open" },
  ];
  const below = render(breakerOnly);
  ok(/SPAWN-PATH fault \(dispatch breaker open\)/.test(below), "names the breaker");
  ok(/BREAKER OBSERVED \(status=circuit_open\)/.test(below), "carries the evidence");
  ok(/closes on its own schedule/.test(below), "says it is state that closes on its own");
  ok(!/refused again/.test(below), "does not claim a retry is refused again — the gate did not read that");
  ok(!/fix the refused argument/.test(below), "does not send the lane to fix an argument");
  const atCapBreaker = render([breakerOnly[0], breakerOnly[0], breakerOnly[0]]);
  ok(/WAIT for the breaker to close/i.test(atCapBreaker), "the cap advice names the breaker, not an argument");
  ok(!/fix the refused argument/.test(atCapBreaker), "…and not an argument either");
});

test("MIXED ledger: breaker state is never rendered as an argument to fix (F6 precedence)", () => {
  // Review of #2665: `remedy = capacity ? … : breaker ? …` made the breaker branch UNREACHABLE as
  // soon as one cut/failed attempt was present, so a mixed ledger told the lane the breaker was "a
  // pre-spawn refusal (cwd / session id) … refused again". The classes are now computed per attempt
  // (faultClasses), independently, and every observed class gets its own evidence line.
  const mixed: SpawnAttempt[] = [
    { tool: "task", outcome: "failed", evidence: "status=failed" },
    { tool: "task", outcome: "refused", evidence: "status=circuit_open" },
  ];
  equal(spawnFaultClass(mixed), "mixed", "two classes are present");
  const t = render(mixed);
  ok(/BREAKER OBSERVED \(status=circuit_open\)/.test(t), "the breaker IS reported in a mixed ledger");
  ok(/circuit breaker is OPEN, which is\s+state rather than an argument/.test(t), "the ACTION is breaker-first: wait, do not edit");
  // The forbidden claim: the breaker described as an argument that will be refused again.
  ok(!/REFUSAL OBSERVED \(status=circuit_open\)/.test(t), "circuit_open is never filed as an argument refusal");
  ok(/MACHINE/.test(t) && /legitimately stretches every attempt/.test(t), "the capacity half is still explained");
});

test("F7: a PROVIDER LATCH halt is durable state, never 'fix the argument' (review of #2665, P2)", () => {
  // A pre-spawn halt (`failoverHalt` with `haltReason` halt|blocked) is emitted for EVERY dispatch
  // while a provider family is latched/exhausted. Grouped with the other pre-spawn refusals it
  // rendered "fix the refused argument (cwd / session id) … the IDENTICAL dispatch is refused
  // again" — false twice over: the cause is a latch, and the identical dispatch SUCCEEDS once it
  // clears. Both shapes (pre-spawn halt, mid-loop halt) must route to the latch remedy.
  const pre: SpawnAttempt = {
    tool: "task",
    outcome: "refused",
    evidence: "failoverHalt=true haltAttempted=false haltReason=halt",
  };
  equal(spawnFaultClass([pre]), "latch", "a pre-spawn halt is its own class");
  const below = render([pre]);
  ok(/provider latch \/ leg exhaustion/.test(below), "names the latch");
  ok(/LATCH OBSERVED \(failoverHalt=true haltAttempted=false/.test(below), "carries the evidence");
  ok(/SUSPEND AND POLL \(attempt 1 of 3\)/.test(below), "the ACTION is wait-and-poll, not retry the same call");
  ok(/SUCCEEDS once the latch clears|succeeds once the latch clears/.test(below), "says the identical dispatch succeeds later");
  ok(!/fix the refused argument/.test(below), "never sends the lane to fix an argument");
  ok(!/refused again/.test(below), "never claims a retry is refused again");
  ok(!/less loaded moment/.test(below), "and never blames load for a durable latch");
  ok(/HALTED before a child existed/.test(below), "the pre-spawn clause is backed by haltAttempted=false");
  // Mid-loop halt (a child existed, legs exhausted during failover) is the same CLASS — but it must
  // NOT inherit the pre-spawn CLAUSE (VGATE round 9, P1): the producer states `attempted: true`
  // means a leg actually dispatched, so "HALTED before a child existed" would be a claim beside an
  // evidence line that says the opposite.
  const mid: SpawnAttempt = { tool: "task", outcome: "failed", evidence: "failoverHalt=true haltAttempted=true" };
  equal(attemptClass(mid), "latch", "the mid-loop halt is the same class");
  const midText = render([mid]);
  ok(/AFTER a leg ran and exhausted it/.test(midText), "says a leg DID run");
  ok(!/before a child existed/.test(midText), "and never claims no child existed");
  ok(/SUSPEND AND POLL/.test(midText), "same durable-state remedy");
  const atCap = render([pre, pre, pre]);
  ok(/wait for the latch to clear/.test(atCap), "the cap advice names the latch");
  ok(!/fix the refused argument/.test(atCap), "…and not an argument");
  // A latch outranks a cut child: the latch is the gating condition, so retrying is still wrong.
  const mixedLatch = render([
    { tool: "task", outcome: "cut", evidence: "killed=true" },
    pre,
  ]);
  ok(/SUSPEND AND POLL/.test(mixedLatch), "a mixed ledger with a latch waits rather than retrying");
});

test("the refusal gloss is derived from the EVIDENCE, not assumed (review of #2665)", () => {
  const invalidReq = render([{ tool: "subagent", outcome: "refused", evidence: "results=[]" }]);
  ok(/invalid subagent REQUEST/.test(invalidReq), "results=[] is diagnosed as an invalid request");
  ok(!/cwd \/ session id/.test(invalidReq), "…and not as a cwd/session-id refusal");
  const cwd = render([{ tool: "task", outcome: "refused", evidence: "status=invalid-cwd" }]);
  ok(/cwd \/ session id/.test(cwd), "a real pre-spawn refusal keeps the cwd/session-id gloss");
});

test("an ARGUMENT refusal (invalid-cwd) still gets the argument remedy — the split is not a blanket", () => {
  const t = render([{ tool: "task", outcome: "refused", evidence: "status=invalid-cwd" }]);
  ok(/fix the refused argument named above/.test(t), "argument remedy retained");
  ok(!/dispatch breaker OPEN/.test(t), "and the breaker text is not borrowed");
});

test("a CUT/FAILED history DOES get the load explanation (the condition is not just off)", () => {
  ok(/legitimately stretches every attempt/.test(render(ATTEMPTS)), "the other branch still explains load");
});

test("the cap says this SESSION's attempts failed, not `every spawn from this box`", () => {
  const t = render([ATTEMPTS[0], ATTEMPTS[1], ATTEMPTS[0]]);
  ok(/Every spawn ATTEMPT in this/.test(t), "scoped to what the gate observed");
  ok(!/from this box/.test(t), "no claim the gate cannot make about the machine");
});

test("a storm is bounded: only the tail is rendered, the TOTAL is not understated", () => {
  const storm: SpawnAttempt[] = Array.from({ length: 12 }, () => ({
    tool: "task", outcome: "failed" as const, evidence: "status=failed",
  }));
  const t = render(storm);
  ok(t.includes("12 sub-agent spawn ATTEMPT(s)"), "the total is the real count");
  ok(t.includes(`last ${SPAWN_ATTEMPT_CAP + 2} of 12`), "the rendering is bounded");
  // The head is DROPPED, not renumbered: the last 5 of 12 are 8..12, so no `1.`/`7.` line exists
  // (assert on the numbered prefix, since "11. task" would contain the substring "1. task").
  ok(!t.includes("7. task"), "the dropped head is not renumbered");
  ok(t.includes("8. task") && t.includes("12. task"), "the tail keeps its REAL ordinals");
});

test("an EXPLICIT total outranks the retained window — a bounded ledger is not a fact about the box", () => {
  // `SPAWN_ATTEMPT_KEEP` truncates the session's ledger; the verdict must still report the
  // true attempt count, or a lane retrying past the window is told it tried 10 times when it
  // tried 14 (the review of #2665 caught the code comment claiming otherwise).
  _setMachineCapacityOverride({ load1: 8.46, cores: 4, ratio: 2.12 });
  try {
    const t = describeSpawnCapacity(ATTEMPTS, readMachineCapacity(), 14).join("\n");
    ok(t.includes("14 sub-agent spawn ATTEMPT(s)"), `the true total: ${t.split("\n")[0]}`);
    ok(t.includes("last 2 of 14"), "the window is still bounded");
    ok(/CAP REACHED \(14 >= 3\)/.test(t), "and the cap advice keys on the true total");
  } finally { _setMachineCapacityOverride(null); }
});

test("says what it could NOT see: the prompt, i.e. which failed dispatch was the reviewer", () => {
  ok(/COULD NOT SEE: which PROMPT/.test(render(ATTEMPTS)),
    "a gate that reads a spawn RESULT must not claim to know the dispatch's intent");
});

test("does not claim the reviewer IDENTITY it cannot see (the review of #2665 caught this)", () => {
  const t = render(ATTEMPTS);
  // The gate reads a spawn RESULT, not its prompt. "A reviewer WAS dispatched" is a claim about
  // intent; the honest form is that a dispatch was ATTEMPTED. Pinned as an ABSENCE of the claim,
  // because a positive assertion alone passes on text that says both.
  ok(!/reviewer WAS dispatched/i.test(t), `must not assert the dispatch's intent: ${t.split("\n")[1]}`);
  // F3 residual (review of #2665): the count line itself must not call it a REVIEWER spawn — the
  // gate never saw the prompt.
  ok(!/reviewer spawn (ATTEMPT|produced)/i.test(t), "the count line does not name an intent either");
  ok(/dispatch WAS\s+ATTEMPTED/.test(t), "says what it can prove (the line wraps)");
});

// ── Summary ───────────────────────────────────────────
// The runner above is async per test but scheduled in order; the summary is printed from a
// microtask-free settle so this file needs no top-level `await` (the shared suites run under
// the repo's cjs tsx default).
const summary = () => {
  console.log(`\n${passed} passed, ${failed} failed`);
  if (failed > 0) process.exit(1);
};
setTimeout(summary, 0);
