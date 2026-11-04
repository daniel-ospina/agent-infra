/**
 * shared/spawn-capacity.ts — a reviewer spawn that produced NO VERDICT is a CAPACITY
 * fault, and it must never read as a compliance failure (#2665).
 *
 * THE DEFECT THIS NAMES. The review-enforcer's ≥1-dispatch floor counted `tool_result`
 * events for `task`/`subagent` and checked nothing else, so a spawn that returned
 * `status:"failed"` (retry exhaustion), `killed:true` (cut at a bound) or a pre-spawn
 * refusal (`invalid-cwd` / `invalid-session-id` / `circuit_open`) incremented the same
 * counter a real review does. Measured on `main` before this module existed:
 *
 *   [review-enforcer] 📊 Reviewer dispatch counted (total: 1)
 *   [review-enforcer] ✅ 1 reviewer dispatch(es) — allowing git op
 *
 * …for a `task` result carrying `details:{status:"failed"}` — i.e. the child session was
 * created and never produced a first message. Two faults at once:
 *
 *   1. FALSE PASS — the lane's `git push` was allowed with no reviewer verdict in hand.
 *      A gate reporting OK while the artifact is unreviewed (AGENTS.md §Product Over Process
 *      class A). `#1662` closed only the `background:true` dimension of this counting bug.
 *   2. CAPACITY READ AS COMPLIANCE — the lane on a box that could not serve the spawn was
 *      told "no reviewers dispatched", the sentence reserved for a lane that never tried.
 *      Those two states have DIFFERENT remedies (dispatch now / retry under less load), and
 *      the one that was printed sent the lane to the wrong one.
 *
 * WHAT THIS MODULE DECIDES, AND WHAT IT DOES NOT. It classifies a spawn RESULT into a
 * verdict or an attempt-without-verdict, and renders the capacity verdict's text. It does
 * NOT relax the reviewer requirement: an attempt without a verdict makes the floor refuse
 * HARDER (it no longer counts), never weaker. It also does not gate load — `scripts/
 * load-gate.mjs` owns that policy (2.5×/1.5× cores); this module only REPORTS the measured
 * ratio so the refusal states the machine it read rather than inviting the lane to guess.
 *
 * ⛔ ONLY THE FIELDS THE PRODUCER SETS. Every classification carries the `key=value` it
 * read, so a refusal can never assert a cause it did not observe (the #2349 discipline:
 * "a refusal says what it read"). The child SESSION ID is deliberately absent — it is on
 * the parent's `[task] child session <uuid>` console line, not in the tool result, and
 * inventing one here would be exactly the false-evidence shape this repo keeps paying for.
 *
 * ZERO-DEPENDENCY (stdlib only, no pi import): CI runs `extensions/shared/*.test.ts`
 * before the extensions' `npm ci`, so this file must stay importable without the pi SDK.
 */

import * as os from "node:os";

/** The token a monitor greps for. Emitted ONLY when the floor read ≥1 attempt with no verdict. */
export const SPAWN_UNSPAWNABLE_TOKEN = "REVIEW-GATE-UNSPAWNABLE";

/**
 * How many verdict-less attempts the gate will REPORT before it stops asking the lane to
 * retry (#2665: "state the cap and the backoff"). The cap does not change the block — the
 * floor refuses at every attempt count — it changes the ADVICE: below the cap a retry is a
 * reasonable action, at/above it the honest instruction is to stop and report the named
 * verdict, because a box that has failed every spawn is not fixed by a fourth try.
 *
 * 3 is calibrated against the retry wrapper's own budget (`extensions/builtin-tools`
 * re-spawns a zero-output child internally) — one visible attempt at the `task` level is
 * already several real spawns, so three visible attempts is generous.
 */
export const SPAWN_ATTEMPT_CAP = 3;

/** A spawn either produced a VERDICT (countable as a review) or it did not. */
export type SpawnOutcome = "verdict" | "refused" | "cut" | "failed";

/**
 * Statuses a spawn result can carry that mean "no reviewer reported".
 *
 * `invalid-cwd` / `invalid-session-id` / `circuit_open` / `failed` are `builtin-tools`'
 * own `FAILED_TASK_STATUS` set; `cut` is `shared/task-runs`' terminal status for a child
 * killed by a bound. Enumerated rather than "anything not ok" so an unrecognised status
 * stays a COUNTED dispatch — a future success status must not become a false failure
 * (the same rule, and the same reason, as `FAILED_TASK_STATUS`).
 */
const REFUSED_STATUS = new Set(["invalid-cwd", "invalid-session-id", "circuit_open"]);
const FAILED_STATUS = new Set(["failed"]);
const CUT_STATUS = new Set(["cut"]);

/**
 * The `subagent` tool's failure predicate, mirrored from its own
 * `isFailedResult` (`extensions/subagent/index.ts`) rather than inferred from `isError`.
 * ⛔ WHY MIRRORED AND NOT READ FROM `isError`: the subagent tool sets `isError: true` on its
 * RETURNED result and carries no `status`/`killed` in `details` (which is `{mode, agentScope,
 * projectAgentsDir, results}`). Whether that `isError` reaches a `tool_result` handler depends on
 * extension load order and on pi's own result pipeline — and `subagent` is the MICRO tier's own
 * dispatch path, so a load-order accident there would be a silent false PASS. Reading the
 * per-result fields the tool itself decides on is self-sufficient.
 */
const SUBAGENT_FAILED_STOP = new Set(["error", "aborted", "timeout", "cut"]);

/** One `subagent` per-result entry, as `details.results[]` carries it. */
interface SubagentResultLike {
  exitCode?: unknown;
  stopReason?: unknown;
}

/**
 * A `results[]` entry is a failure exactly when the subagent tool would call it one: a non-zero
 * exit, or a stop reason that means the worker was killed or errored rather than done.
 */
function subagentResultFailed(r: SubagentResultLike): boolean {
  if (typeof r.exitCode === "number" && r.exitCode !== 0) return true;
  return typeof r.stopReason === "string" && SUBAGENT_FAILED_STOP.has(r.stopReason);
}

/** The subset of a pi `tool_result` event this module reads. Absent fields are normal. */
export interface SpawnResultLike {
  details?: Record<string, unknown> | null;
  isError?: unknown;
}

export interface SpawnClassification {
  outcome: SpawnOutcome;
  /** The field(s) the classification READ, as `key=value` — empty for `verdict`. */
  evidence: string;
}

/**
 * Classify one spawn result. PRECEDENCE: cut → refused → failed → (error) failed → verdict.
 *
 * `killed` is checked FIRST because it is the strongest statement a producer makes: the
 * parent KILLED this child (`composeAbnormalExit` sets `killed:true` on the hard-cap, the
 * cut clause, the backstop and the heartbeat kills). A killed child's partial output is not
 * a review verdict, even when the text happens to contain one — the reviewer did not run to
 * completion and the floor is not allowed to pretend it did.
 */
export function classifySpawnOutcome(result: SpawnResultLike | null | undefined): SpawnClassification {
  const details = (result?.details ?? {}) as Record<string, unknown>;
  const status = typeof details.status === "string" ? details.status : null;
  if (details.killed === true) {
    const reason = typeof details.reason === "string" && details.reason ? details.reason : "unreported";
    return { outcome: "cut", evidence: `killed=true reason=${reason}` };
  }
  if (status !== null && REFUSED_STATUS.has(status)) {
    return { outcome: "refused", evidence: `status=${status}` };
  }
  if (status !== null && FAILED_STATUS.has(status)) {
    return { outcome: "failed", evidence: `status=${status}` };
  }
  if (status !== null && CUT_STATUS.has(status)) {
    return { outcome: "cut", evidence: `status=${status}` };
  }
  // ── the other producer failure shapes (review of #2665, P1) ────────────────────────────
  // `builtin-tools` computes this SAME predicate for its own #1508 `isError` hook
  // (`extensions/builtin-tools/index.ts`, "the INNER SPAWN adds a nonzero exit code …"). The
  // floor may not depend on that hook having run FIRST: `emitToolResult` folds each handler's
  // `isError` in for LATER extensions only, and extension order is a readdir — so on one box the
  // hook is upstream and on another it is downstream. Reading the producer's own fields is
  // order-independent.
  const fallbackStatus = typeof details.fallbackStatus === "string" ? details.fallbackStatus : null;
  if (fallbackStatus !== null && REFUSED_STATUS.has(fallbackStatus)) {
    return { outcome: "refused", evidence: `fallbackStatus=${fallbackStatus}` };
  }
  if (fallbackStatus !== null && (FAILED_STATUS.has(fallbackStatus) || CUT_STATUS.has(fallbackStatus))) {
    return { outcome: "failed", evidence: `fallbackStatus=${fallbackStatus}` };
  }
  if (details.failoverHalt === true) {
    // `haltAttempted === false` is a PRE-SPAWN halt: no child ever existed, so it is a refusal and
    // the remedy is not "wait for a child".
    const attempted = details.haltAttempted === true;
    return {
      outcome: attempted ? "failed" : "refused",
      evidence: `failoverHalt=true haltAttempted=${attempted} haltReason=${typeof details.haltReason === "string" ? details.haltReason : "unreported"}`,
    };
  }
  if (details.failoverHopSpawnFailed === true) {
    return { outcome: "failed", evidence: "failoverHopSpawnFailed=true" };
  }
  if (typeof details.exitCode === "number" && details.exitCode !== 0) {
    return { outcome: "failed", evidence: `exitCode=${details.exitCode}` };
  }
  // ⛔ `exitCode` IS ONLY EMITTED ON A NON-CLEAN COMPOSITION (review of #2665, third round).
  // `builtin-tools` writes `details.exitCode` in exactly three places: the non-clean
  // composition (`{model, provider, exitCode: code}` — "a SUCCESS-but-SILENT child that exited 0
  // with empty stdout", labelled `reason: "clean-empty"`), `composeTaskResult`'s failure branch
  // (`{model, provider, exitCode}` — `null` on signal death), and the success branch guarded by
  // `killedAfterCompletion === true`. A CLEAN success carries `{model, provider}` and NO
  // `exitCode`. So a present `exitCode` that is NOT the reaped-after-completion case is a child
  // that produced no readable result — regardless of the exit status it happens to have.
  // (Before this arm, `exitCode: 0` and `exitCode: null` both counted as reviewer verdicts.)
  if (details.exitCode === null) {
    return { outcome: "cut", evidence: "exitCode=null (signal death, no output)" };
  }
  if (typeof details.exitCode === "number" && details.exitCode === 0 && details.killedAfterCompletion !== true) {
    return { outcome: "cut", evidence: "exitCode=0 clean-empty (no output)" };
  }
  if (Array.isArray(details.results)) {
    const results = details.results as SubagentResultLike[];
    // ⛔ AN EMPTY `results` IS NOT A VERDICT (review of #2665). The subagent tool emits
    // `results: []` on its NO-WORK arms (invalid mode, too many parallel tasks, missing
    // agent/task) — a request that never ran. Every legitimate run yields at least one result,
    // so an empty array is a spawn-side refusal, not a review. Without this arm those arms were
    // COUNTED as reviewer dispatches, the same false PASS this module exists to close.
    if (results.length === 0) {
      return { outcome: "refused", evidence: "results=[]" };
    }
    const bad = results.find((r) => r && typeof r === "object" && subagentResultFailed(r));
    if (bad) {
      // ⚠️ DECLARED DIVERGENCE, kept fail-CLOSED (non-blocking finding on #2665). `subagent`'s
      // PARALLEL mode returns SUCCESS when only SOME workers fail, so a batch that yielded two real
      // reviewer verdicts and one flaky worker is refused here as "0 reviewer verdicts counted" —
      // stricter than the producer, deliberately: this gate cannot tell which entry carried the
      // verdict, and counting the batch would re-open the false PASS the module exists to close.
      // The cost is a re-dispatch, not an unreviewed push. Closing it needs per-entry prompt
      // identity from the producer (the same missing marker as #2665's residual), not a guess here.
      const why =
        typeof bad.exitCode === "number" && bad.exitCode !== 0
          ? `exitCode=${bad.exitCode}`
          : `stopReason=${String(bad.stopReason)}`;
      return { outcome: "failed", evidence: `results[].${why}` };
    }
  }
  if (details.isError === true) {
    return { outcome: "failed", evidence: "details.isError=true" };
  }
  // An explicit tool error with no recognised status: the tool did not produce a result the
  // gate can read as a verdict. Treated as `failed` (the weakest of the three claims) rather
  // than `verdict`, because "the call raised" is not "a reviewer reported".
  if (result?.isError === true) {
    return { outcome: "failed", evidence: "isError=true status=none" };
  }
  return { outcome: "verdict", evidence: "" };
}

/** One verdict-less attempt, as the durable audit row and the refusal render it. */
export interface SpawnAttempt {
  /** `task` | `subagent` | `task_collect` — the tool whose result carried this. */
  tool: string;
  outcome: Exclude<SpawnOutcome, "verdict">;
  /** The producer field(s) read, `key=value`. Never invented. */
  evidence: string;
}

/** The machine the floor measured, rendered so a refusal states the box it read. */
export interface MachineCapacity {
  /** 1-min loadavg, or `null` when the probe failed (never a confident 0). */
  load1: number | null;
  cores: number;
  /** `load1 / cores`, or `null` when the probe failed or cores is 0. */
  ratio: number | null;
}

let machineOverride: MachineCapacity | null = null;

/** Test seam (mirrors `_setPrDiffHashOverride`): force the measured capacity. */
export function _setMachineCapacityOverride(next: MachineCapacity | null): void {
  machineOverride = next;
}

/**
 * Measure the box. `load1` is `os.loadavg()[0]` — the SAME signal every load-scaled bound
 * in the fleet reads, I/O-inclusive and trailing by design (docs/ops/load-policy.md §1).
 *
 * The RATIO, not the raw figure, is what makes it interpretable: the cells are not the same
 * size (4 vCPU on cell-3, 8 elsewhere), so a fixed lane or load cap is not a capacity
 * measure. A failed probe renders `null` — an unread channel must not be reported as a
 * healthy `0` (`#1485`).
 */
export function readMachineCapacity(): MachineCapacity {
  if (machineOverride) return machineOverride;
  let load1: number | null = null;
  try {
    const v = os.loadavg()[0];
    load1 = Number.isFinite(v) && v >= 0 ? Math.round(v * 100) / 100 : null;
  } catch {
    load1 = null;
  }
  let cores = 0;
  try {
    cores = os.cpus().length;
  } catch {
    cores = 0;
  }
  const ratio = load1 !== null && cores > 0 ? Math.round((load1 / cores) * 100) / 100 : null;
  return { load1, cores, ratio };
}

/** Rendering helper: a null measurement stays `unknown`, never `0`. */
function num(v: number | null): string {
  return v === null ? "unknown" : String(v);
}

/**
 * Which fault the ledger supports — ONE definition, consumed by the renderer AND by the
 * caller's header, so the two cannot disagree (review of #2665: the header said CAPACITY while
 * the body said "SPAWN-SIDE refusal", in the same message).
 *
 * Per-attempt CLASSES, never a first-match: a ledger can hold a cut child AND a breaker refusal,
 * and a first-match rule made one of them unreachable (measured by review: `[failed,
 * circuit_open]` rendered the breaker as an argument to fix).
 *
 * ⛔ FOUR classes, not three, and `latch` is one of them (review of #2665, P2). A provider-latch
 * halt (`failoverHalt` with `haltReason: "halt" | "blocked"`) is emitted BEFORE a child exists
 * for every dispatch while a provider family is latched/exhausted. Routing it with the other
 * pre-spawn refusals produced "fix the refused argument (cwd / session id) — the IDENTICAL
 * dispatch is refused again", which is false on both halves: the cause is a durable latch, and
 * the identical dispatch SUCCEEDS once it clears. `circuit_open` had already been split out for
 * exactly this reason; the latch is the more common shape (balance / leg exhaustion).
 */
export type SpawnFaultClass = "capacity" | "breaker" | "latch" | "refusal" | "mixed";

/** The class ONE attempt belongs to — the single definition both the class-set and the caller's
 *  bounded ledger use, so "which class survives the window" cannot drift from "which class
 *  decides the remedy". */
export function attemptClass(a: SpawnAttempt): "capacity" | "breaker" | "latch" | "refusal" {
  // ⛔ The PRODUCER'S marker outranks the outcome label (review of #2665, P2): `failoverHalt` is
  // set exclusively on the halt paths (pre-spawn halt, and a halt after an attempt = legs/family
  // exhausted), so a `failed` carrying it is a durable-latch failure, not a cut child. Testing
  // the generic outcome first filed the mid-loop halt as CAPACITY and told the lane to retry it on
  // "a less loaded moment", which the halt cause does not support.
  if (/failoverHalt=true/.test(a.evidence)) return "latch";
  if (a.outcome === "cut" || a.outcome === "failed") return "capacity";
  if (a.outcome === "refused" && /circuit_open/.test(a.evidence)) return "breaker";
  return "refusal";
}

export function faultClasses(attempts: readonly SpawnAttempt[]): {
  capacity: boolean;
  breaker: boolean;
  latch: boolean;
  refusal: boolean;
  /** The last attempt of each class, for the evidence line. */
  breakerAt: SpawnAttempt | null;
  latchAt: SpawnAttempt | null;
  refusalAt: SpawnAttempt | null;
} {
  let breakerAt: SpawnAttempt | null = null;
  let latchAt: SpawnAttempt | null = null;
  let refusalAt: SpawnAttempt | null = null;
  let capacity = false;
  for (const a of attempts) {
    const cls = attemptClass(a);
    if (cls === "capacity") capacity = true;
    else if (cls === "breaker") breakerAt = a;
    else if (cls === "latch") latchAt = a;
    else refusalAt = a;
  }
  return {
    capacity,
    breaker: breakerAt !== null,
    latch: latchAt !== null,
    refusal: refusalAt !== null,
    breakerAt,
    latchAt,
    refusalAt,
  };
}

/** The single fault class this ledger supports. */
export function spawnFaultClass(attempts: readonly SpawnAttempt[]): SpawnFaultClass {
  const c = faultClasses(attempts);
  const present = [c.capacity, c.breaker, c.latch, c.refusal].filter(Boolean).length;
  if (present > 1) return "mixed";
  if (c.capacity) return "capacity";
  if (c.breaker) return "breaker";
  if (c.latch) return "latch";
  return "refusal";
}

/** The class as a phrase that is TRUE for the outcomes observed. */
export function spawnFaultLabel(cls: SpawnFaultClass): string {
  switch (cls) {
    case "capacity":
      return "CAPACITY fault";
    case "breaker":
      return "SPAWN-PATH fault (dispatch breaker open)";
    case "latch":
      return "SPAWN-PATH fault (provider latch / leg exhaustion)";
    case "refusal":
      return "SPAWN-SIDE refusal (refused before a child existed)";
    case "mixed":
      return "SPAWN-PATH fault (mixed: several spawn classes failed — see ATTEMPTS)";
  }
}

/**
 * The capacity/refusal/breaker verdict's lines — a DISTINCT block message (#2665), not an extra
 * sentence on the compliance one, because the two are different faults with different remedies and
 * a lane that reads the wrong one retries the wrong thing.
 *
 * `attempts` is oldest-first and may be longer than the cap; the rendering shows the last
 * `SPAWN_ATTEMPT_CAP + 2` so a storm cannot flood the refusal.
 */
export function describeSpawnCapacity(
  attempts: readonly SpawnAttempt[],
  machine: MachineCapacity = readMachineCapacity(),
  /** The session's TRUE attempt total. Required when `attempts` is the retained window
   * (`SPAWN_ATTEMPT_KEEP`), because the count in the verdict must never understate how many
   * spawns were made — a bounded ledger is a rendering limit, not a fact about the box. */
  total: number = attempts.length,
): string[] {
  const n = Math.max(total, attempts.length);
  const shown = attempts.slice(-(SPAWN_ATTEMPT_CAP + 2));
  const atCap = n >= SPAWN_ATTEMPT_CAP;
  const cls = spawnFaultClass(attempts);
  const c = faultClasses(attempts);
  // The remedy branch: the class that names the next ACTION. A breaker must be WAITED for before
  // anything else is worth trying, so it outranks a retry; with capacity present the load/retry
  // story is then the honest one. The per-class EVIDENCE lines below are emitted independently of
  // this choice, so a mixed ledger reports every class it observed.
  // Priority is the gating CONDITION, not frequency: a latch and a breaker are durable STATE that
  // must clear before a retry is worth spending, then capacity owns the retry, and the argument
  // class is last because it is the only one the lane can fix directly.
  const remedy: "capacity" | "breaker" | "latch" | "argument" =
    cls === "latch" || (cls === "mixed" && c.latch)
      ? "latch"
      : cls === "breaker" || (cls === "mixed" && c.breaker)
        ? "breaker"
        : c.capacity
          ? "capacity"
          : "argument";
  // ⛔ `haltAttempted` SPLITS THE LATCH SENTENCE (VGATE round 9, P1). The producer's own contract
  // (builtin-tools' HaltDispatchResult) is that `attempted: true` marks a halt AFTER a leg actually
  // dispatched — its text then reports the leg that ran instead of claiming no dispatch. So a
  // mid-loop latch must NOT be told "before a child existed": `haltAttempted=false` is the only
  // shape that supports the pre-spawn clause. This module renders a claim only where the evidence
  // line it printed beside it says the same thing (the #2349 discipline).
  const latchAttempted = /haltAttempted=true/.test(c.latchAt?.evidence ?? "");
  const latchClause = latchAttempted
    ? "AFTER a leg ran and exhausted it"
    : "before a child existed";
  const latchClauseLower = latchAttempted
    ? "after a leg ran and exhausted it"
    : "before a child existed";
  // The header states the fault class the LEDGER supports — conditioned on the same classes, so a
  // refusal-only ledger cannot be told its child came back, a latch-only one cannot be told
  // "several classes failed", and a mixed one claims neither (review of #2665: the header and the
  // label disagreed on a latch-only ledger).
  const headline =
    cls === "capacity"
      ? "a `task`/`subagent` dispatch WAS ATTEMPTED and its child never returned a verdict"
      : cls === "refusal"
        ? "a `task`/`subagent` dispatch WAS ATTEMPTED and refused BEFORE a child existed"
        : cls === "breaker"
          ? "a `task`/`subagent` dispatch WAS ATTEMPTED and the dispatch breaker refused it before a child existed"
          : cls === "latch"
            ? `a \`task\`/\`subagent\` dispatch WAS HALTED ${latchClause} because a provider family is latched/exhausted`
            : "a `task`/`subagent` dispatch WAS ATTEMPTED and produced no reviewer verdict — several spawn classes failed (see ATTEMPTS)";
  const lines = [
    `${SPAWN_UNSPAWNABLE_TOKEN} — ${n} sub-agent spawn ATTEMPT(s), 0 reviewer verdicts counted.`,
    `   → This is a ${spawnFaultLabel(cls)}, NOT a compliance one: ${headline},`,
    "     so re-running the blocked git operation cannot satisfy this floor — the datum it needs is a",
    "     reviewer VERDICT, not a retry of the same command.",
    "     THIS REFUSAL blocked THIS call, so THAT command did not run.",
    "   → WHAT THIS GATE COULD NOT SEE: which PROMPT a failed dispatch carried. It reads the spawn",
    "     RESULT, so an intended reviewer and any other sub-agent are the same event here — the tool",
    "     and the evidence above are all it has.",
  ];
  if (n > shown.length) {
    lines.push(`   → ATTEMPTS (last ${shown.length} of ${n}, oldest first):`);
  } else {
    lines.push(`   → ATTEMPTS (oldest first):`);
  }
  shown.forEach((a, i) => {
    const idx = n - shown.length + i + 1;
    lines.push(`     ${idx}. ${a.tool} ${a.outcome.toUpperCase()} — ${a.evidence}`);
  });
  lines.push(
    `   → MACHINE: load1=${num(machine.load1)} cores=${machine.cores > 0 ? String(machine.cores) : "unknown"} ratio=${num(machine.ratio)}` +
      " — reviewer bounds are load-scaled 1x (<8), 2x (8-15), 3x (>=16)."
  );
  // ── per-class EVIDENCE, each emitted only when that class was observed ──────────────
  if (remedy === "latch") {
    lines.push(
      "     A provider family is latched/exhausted: that is durable STATE, and it clears on its own",
      "     schedule — it is not load, and it is not an argument you can fix."
    );
  } else if (c.capacity) {
    lines.push(
      "     A loaded box legitimately stretches every attempt: a spawn that never gets a first",
      "     message is what load does to a provider request, not evidence that the reviewer was skipped."
    );
  } else {
    lines.push("     No attempt in this ledger was cut or exhausted, so load scaling is NOT the cause here.");
  }
  if (c.latch) {
    lines.push(
      `   → LATCH OBSERVED (${c.latchAt?.evidence ?? "failoverHalt=true"}): the dispatch was HALTED ${latchClauseLower}`,
      "     because the provider family is latched/exhausted. The IDENTICAL dispatch",
      "     succeeds once the latch clears (the balance poller clears it on verified positive balance)."
    );
  }
  if (c.breaker) {
    lines.push(
      `   → BREAKER OBSERVED (${c.breakerAt?.evidence ?? "status=circuit_open"}): the breaker is STATE, not an`,
      "     argument — changing the prompt or cwd does not close it, and it reopens on its own schedule."
    );
  }
  if (c.refusal) {
    // The gloss is derived from the EVIDENCE, not assumed (review of #2665): the refusal class also
    // holds `results=[]` (an invalid subagent request), and telling a lane to fix "the cwd / session
    // id" for that is the wrong-remedy failure this module exists to remove.
    const gloss = /results=\[\]/.test(c.refusalAt?.evidence ?? "")
      ? "an invalid subagent REQUEST (mode / parallel count / agent name) — no child was ever intended"
      : "a pre-spawn refusal (cwd / session id) — NOT a load effect, and re-dispatching the SAME argument is refused again";
    lines.push(`   → REFUSAL OBSERVED (${c.refusalAt?.evidence ?? "status=refused"}): ${gloss}`);
  }
  lines.push(
    "   → WHAT THIS GATE READ: the `task`/`subagent` result DETAILS of this session (the `key=value`",
    "     above). It does NOT see the child session id (that is the parent's `[task] child session",
    "     <uuid>` console line) and it does not see why the box was loaded."
  );
  // ── the ACTION ──────────────────────────────────────────────────────────────────────
  if (atCap) {
    lines.push(
      `   → ⛔ CAP REACHED (${n} >= ${SPAWN_ATTEMPT_CAP}): stop retrying. Every spawn ATTEMPT in this`,
      "     session has failed, so a further one spends another bound for the same result. Report",
      `     ${SPAWN_UNSPAWNABLE_TOKEN} with the ATTEMPTS + MACHINE lines above and hand the lane back.`
    );
    lines.push(
      remedy === "latch"
        ? "     The review is still REQUIRED: whoever re-dispatches must wait for the latch to clear"
        : remedy === "breaker"
          ? "     The review is still REQUIRED: whoever re-dispatches must WAIT for the breaker to close"
          : remedy === "capacity"
            ? "     The review is still REQUIRED: whoever re-dispatches must place it where a child can"
            : "     The review is still REQUIRED: whoever re-dispatches must first fix the refused argument"
    );
    lines.push(
      remedy === "latch"
        ? "     (or move the dispatch to a provider family that is not exhausted), then dispatch again."
        : remedy === "breaker"
          ? "     (state, not an argument), then dispatch again."
          : remedy === "capacity"
            ? "     get a first message (load-gate: scripts/load-gate.mjs)."
            : "     named above (cwd / session id)."
    );
  } else if (remedy === "latch") {
    lines.push(
      `   → SUSPEND AND POLL (attempt ${n} of ${SPAWN_ATTEMPT_CAP}): the dispatch was halted ${latchClauseLower}`,
      "     because the provider family is latched/exhausted. The identical dispatch succeeds",
      "     once the latch clears — do NOT edit the argument, and do NOT retry in a loop (the",
      "     balance poller clears the latch on verified positive balance)."
    );
  } else if (remedy === "breaker") {
    lines.push(
      `   → RETRY (attempt ${n} of ${SPAWN_ATTEMPT_CAP}): the dispatch circuit breaker is OPEN, which is`,
      "     state rather than an argument. It closes on its own schedule — wait for it to close, then",
      "     dispatch again. Editing the prompt or cwd will not reopen it."
    );
  } else if (remedy === "argument") {
    lines.push(
      `   → RETRY (attempt ${n} of ${SPAWN_ATTEMPT_CAP}): fix the refused argument named above, then`,
      "     dispatch a fresh sub-agent. A retry of the IDENTICAL dispatch is refused again — there is",
      "     no child to wait for."
    );
  } else {
    lines.push(
      `   → RETRY (attempt ${n} of ${SPAWN_ATTEMPT_CAP}): re-dispatch the sub-agent — the child needs a`,
      "     first message, so a fresh spawn on a less loaded moment can succeed where the cut one did not.",
      "     Do NOT push on a partial or cut child's output: its text is not a verdict.",
      `     Below the cap this is a RETRY; at ${SPAWN_ATTEMPT_CAP} attempts this gate will tell you to stop.`
    );
  }
  return lines;
}
