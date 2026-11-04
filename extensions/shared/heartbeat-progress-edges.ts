/**
 * heartbeat-progress-edges.ts — the ONE declaration of what counts as progress (#1068).
 *
 * WHY THIS FILE EXISTS
 * --------------------
 * The input to every stall bound in this repo is a classification: which events
 * count as progress. Before this module that classification was declared
 * independently by each producer — the child clock in
 * `extensions/task-heartbeat.ts` (in-process pi events → `touchActivity()`) and
 * the parent's parsed-marker latches in `extensions/builtin-tools/index.ts`
 * (`everSawRealActivity` / `everSawMsg` / `everSawTool` / `firstActivityAt`) —
 * with the wire FORMAT drift-guarded (E14) but the edge SEMANTICS unasserted. A
 * new edge added to one side was silently absent from the other.
 *
 * THE INVARIANT IS *NOT* "THE TWO SIDES ARE EQUAL"
 * ------------------------------------------------
 * They legitimately differ, and this table records exactly how:
 *   · `session_start` advances the child's clock but `ready` deliberately does
 *     NOT latch real activity (a session that only started has not worked);
 *   · `turn_start` sets `everSawWork` but NOT `everSawRealActivity` — the #279
 *     footgun guard, recorded here as a DECLARED, ASSERTED exception rather than
 *     an in-code comment;
 *   · `tool_end` sets `everSawRealActivity` and resets the parent's stream age,
 *     but never sets `everSawWork`.
 * Encoding equality would have been wrong. Encoding EACH SIDE'S EFFECT PER EDGE
 * is the contract; the tests assert each side implements its row.
 *
 * WHAT IS CONSUMED WHERE
 * ----------------------
 *   · `extensions/task-heartbeat.ts` imports `ACTIVITY_EDGE_EVENTS`,
 *     `LIFECYCLE_EVENTS`, `CLOCK_RESET_EVENT` and the `ActivityEdge` type, and
 *     routes every clock advance through the declared edge name.
 *   · `extensions/builtin-tools/index.ts` derives `KNOWN_MARKER_KINDS` from
 *     `MARKER_KINDS` and `HeartbeatKillReason` from `HEARTBEAT_KILL_REASONS`.
 *   · `extensions/shared/heartbeat-progress-edges.test.ts` consumes `isActivityEdge`
 *     and `childRegisteredEvents` and asserts table ↔ source parity in BOTH
 *     directions, including the stall-term registry against its owner files.
 *
 * WHAT THIS FILE DOES NOT DO
 * --------------------------
 * It holds NO `stall_threshold` value. That bound is owned by #847
 * (`extensions/loop-enforcer/tier-config-parity.test.ts`, `STALL_THRESHOLD_SURFACES`);
 * `STALL_THRESHOLD` appears here only as a POINTER with `value: null`, and the
 * test asserts no registered term matching `/stall_?threshold/i` carries a value.
 *
 * ZERO-DEPENDENCY IMPORT CONTRACT: this module (and everything it imports) is
 * `node:*`-only, because the per-PR `ci.yml` `verify` job runs the shared suites
 * with NO `npm ci`.
 */

import { collectFiles, type ScanSpec, type StallTerm, type Exemption, type ProgressDriver } from "./declared-surface.js";
import * as path from "node:path";

// ── the progress-edge classification ────────────────────────────────────────

/** pi events that advance the child's stream-age clock (`touchActivity`). */
export const ACTIVITY_EDGE_EVENTS = [
  "turn_start",
  "turn_end",
  "tool_execution_start",
  "tool_execution_update",
  "tool_execution_end",
  "message_start",
  "message_update",
] as const;

/** pi lifecycle events the child registers — NOT activity/progress edges. */
export const LIFECYCLE_EVENTS = ["session_start", "session_shutdown"] as const;

export type ActivityEdge = (typeof ACTIVITY_EDGE_EVENTS)[number];
export type LifecycleEvent = (typeof LIFECYCLE_EVENTS)[number];

/**
 * The lifecycle event that RESETS the child clock (sets it to now without being
 * an activity edge — a session that merely started has not worked, which is why
 * its wire kind `ready` does not latch the parent's real-activity flag).
 *
 * NOTE: a reset is a CLOCK effect, distinct from "is a progress edge" —
 * `session_start` advances the clock (the child calls
 * `touchActivity(CLOCK_RESET_EVENT)`) while not being one of
 * `ACTIVITY_EDGE_EVENTS`. The two terms are not synonyms.
 */
export const CLOCK_RESET_EVENT = "session_start" as const;

/** The axes a registered term answers to. Declared so a typo cannot hide one. */
export const STALL_AXES = [
  "kill",
  "loop-exit",
  "gate",
  "reap",
  "retention",
  "hygiene",
  "heartbeat",
] as const;

export type StallAxis = (typeof STALL_AXES)[number];

/**
 * Registered terms whose NAMES are not in-family — camelCase accessors and
 * constants like `FIRST_OUTPUT_TIMEOUT_MS` whose name carries no stall/silence
 * family token (see `inFamily`). `scanDeclarations` never sees them, so neither
 * the reverse check nor the owners check can cover them. Listed explicitly so a
 * NEW out-of-family term FAILS the registry test instead of silently escaping
 * both directions.
 *
 * This list is NOT the only guard for these: every bound a DECLARED kill clause
 * names must also resolve to a registry entry (the clause→bound closure test),
 * which is what keeps `FIRST_OUTPUT_TIMEOUT_MS` and `DEFAULT_HARD_CAP_MS` — both
 * named only in clause prose — from drifting silently. What remains uncovered is
 * DISCLOSED, not detected: a brand-new out-of-family bound that NO clause names
 * and that nobody lists here is invisible to both scan directions. The tests can
 * only enforce `registered ⇒ in-family or listed here`; they cannot see a term
 * that was never registered at all.
 */
export const OUT_OF_FAMILY_TERMS = [
  "getSubagentBackstopFreshMs",
  "getToolStallMs",
  "getStreamStallMs",
  // #1030: camelCase (not `_MS`), so the name scan cannot see it — listed
  // deliberately, with its own value+behaviour pin in builtin-tools.test.ts.
  "resolveStreamStallMs",
  "getFirstMessageMs",
  "getFirstOutputTimeoutMs",
  "getTaskMaxDispatchMs",
  "getCutGapMs",
  "getEffectiveCutGapMs",
  "getCpuStallMs",
  // #5195: camelCase (not `_MS`), so the name scan cannot see it — listed
  // deliberately, with its own value+behaviour pin in builtin-tools.test.ts.
  "getProgressAgeMs",
  "getTaskBackstopMs",
  "FIRST_OUTPUT_TIMEOUT_MS",
  "DEFAULT_HARD_CAP_MS",
  // agent-infra#2229: the origination reader's in-flight/dead bound. No family token in `RUNNING`,
  // so the name scan cannot see it; listed deliberately, with its value pinned by the registration
  // above and its BEHAVIOUR pinned by origination-funnel.test.sh §5c (young ⇒ in flight, past the
  // bound ⇒ BLOCKED, unreadable `at=` ⇒ BLOCKED).
  "RUNNING_STALE_MIN",
  "DEFAULT_MAX_DISPATCH_MS",
  // #1167: the merge rail's two surviving re-run bounds. Their shell symbols
  // carry no stall-family token (the STALLED threshold is now the DERIVED
  // per-shard bound, so the FLOOR and the fail-safe are the operator-reachable
  // constants). Listed deliberately, with their value pins in this registry and
  // their behaviour pinned by tests/admin-merge/run.sh §41.
  "RERUN_FLOOR",
  "FAILSAFE_RERUN_TIMEOUT",
  // #1500 Leg B: the dispatched child's default bash bound, and the getter that
  // resolves it. Neither name carries a stall-family TOKEN (`_S` IS a bound
  // suffix — `SCAN_BOUND_SUFFIXES` — but `inFamily` needs token AND suffix), so
  // the name scan cannot see them. `getToolTimeoutSeconds` is a FUNCTION and is
  // registered below as well, because every name in this list must also be a
  // registry entry.
  "DEFAULT_TOOL_TIMEOUT_S",
  "getToolTimeoutSeconds",
  // #2026: four of the five bounds behind the fleet supervisor's liveness table
  // (`scripts/lib/fleet-inventory.sh`). Their symbols' distinctive words
  // (`CONTROLLER`/`CADENCE`/`LANDER`/`JOB`) are none of them in
  // `SCAN_NAME_FAMILIES`, so `inFamily` cannot match them even though `_S` IS a
  // bound suffix — the name scan never sees them. Do NOT add those words to
  // `SCAN_NAME_FAMILIES` to "cover" them: the registration below is what covers
  // them, and widening the family list would silently pull in unrelated bounds.
  // The fifth, `FLEET_HEARTBEAT_LATE_S`, IS in-family (the `HEARTBEAT` token) and
  // is registered as such, which is how this file was found at all — the scan
  // found one declaration in it, not the file. Listed here so the whole table is
  // declared rather than half-covered: each is a real liveness bound with
  // seam-moving arms in `scripts/fleet-inventory.test.sh`.
  "FLEET_CONTROLLER_LATE_S",
  "FLEET_CADENCE_LATE_S",
  "FLEET_LANDER_BOUND_S",
  "FLEET_JOB_SLACK_S",
  // #1932 (review of PR #1949): the venv reaper's STATED free-disk floor. Its
  // name carries the `REAP` family TOKEN but `_MB` is not one of
  // `SCAN_BOUND_SUFFIXES`, so `inFamily` cannot see it and the reverse scan would
  // never demand the entry it now has. Registered deliberately rather than left
  // exempt: it bounds how much of the box the fleet may consume, and a bound only
  // the reaper knows about is invisible to the audit that exists to notice exactly
  // that. Value pinned by this registry's forward scan; BEHAVIOUR pinned by
  // `scripts/reap-lane-venvs.test.sh` §H (below the floor ⇒ `floor_ok=no` + exit 5;
  // unreadable `df` ⇒ `floor_ok=unknown`, never a pass).
  "REAP_VENV_FREE_FLOOR_MB",
] as const;

/** The wire marker vocabulary. Single source for the parent's `KNOWN_MARKER_KINDS`. */
export const MARKER_KINDS = [
  "ready",
  "tool_start",
  "tool_end",
  "turn_start",
  "turn_end",
  "tick",
  "session_end",
] as const;

export type MarkerKind = (typeof MARKER_KINDS)[number];

export function isActivityEdge(event: string): event is ActivityEdge {
  return (ACTIVITY_EDGE_EVENTS as readonly string[]).includes(event);
}

/** #783 §6.6 / #1505: the events the dispatch child registers that are not
 * activity or lifecycle edges — a `tool_call` handler (#1500 Leg B) mutates
 * `input.timeout` before a bash call runs and feeds no clock, so it belongs to
 * neither table. Declared here so `childRegisteredEvents()` stays the single
 * source of the child's registration set and the parity test keeps its bite. */
export const PREVENTION_EVENTS = ["tool_call"] as const;

/** Every `pi.on(...)` event the dispatch child registers. */
export function childRegisteredEvents(): string[] {
  return [...ACTIVITY_EDGE_EVENTS, ...LIFECYCLE_EVENTS, ...PREVENTION_EVENTS];
}

/**
 * One row: one classified edge (activity, lifecycle, or synthetic), and EACH
 * SIDE's declared effect on it.
 *
 * Field meanings (one falsifiable meaning each — no field is a label):
 *   advancesClock ........ child: `lastActivityAt = Date.now()`
 *   feedsToolUpdates ..... child: adds `toolCallId` to `updatedToolIds`, which
 *                          `computeToolUpdates` folds into the tick's
 *                          `tool_updates` field
 *   setsEverSawWork ...... parent: sets `everSawWork = true`. NOT a claim about
 *                          `everSawRealActivity` — the `tool-start` row sets
 *                          both, and the #279 guard is expressed by
 *                          `realActivity: false` on the `turn-start` row
 *                          (asserted as the ABSENCE of
 *                          `everSawRealActivity = true` in that arm)
 *   realActivity ......... parent: sets `everSawRealActivity = true` directly
 *   resetsStreamAge ...... parent: `state.streamAgeMs = 0`
 *   resetsToolAge ........ parent: `state.toolAgeMaxMs = 0`
 *   drivesToolUpdates .... parent: writes `state.toolUpdates` from the wire
 *   resetsToolUpdates .... parent: conditionally clears `state.toolUpdates`
 */
export interface ProgressEdge {
  id: string;
  /** The child pi event, or `null` for a synthetic row (the tick timer). */
  event: ActivityEdge | LifecycleEvent | null;
  /** True when the row has no pi event and must be excluded from the child loop. */
  synthetic: boolean;
  /** The wire marker kind emitted for this edge, if any. */
  wireKind: MarkerKind | null;
  advancesClock: boolean;
  /** Pre-condition on the child clock advance. */
  advancesClockCondition?: string;
  feedsToolUpdates: boolean;
  setsEverSawWork: boolean;
  realActivity: boolean;
  resetsStreamAge: boolean;
  resetsToolAge: boolean;
  drivesToolUpdates: boolean;
  resetsToolUpdates: boolean;
  /** The tick's conditional real-activity latch. */
  realActivityCondition?: string;
}

export const PROGRESS_EDGE_TABLE: readonly ProgressEdge[] = [
  {
    id: "session-start",
    event: "session_start",
    synthetic: false,
    wireKind: "ready",
    advancesClock: true,
    feedsToolUpdates: false,
    setsEverSawWork: false,
    realActivity: false,
    resetsStreamAge: false,
    resetsToolAge: false,
    drivesToolUpdates: false,
    resetsToolUpdates: false,
  },
  {
    id: "turn-start",
    event: "turn_start",
    synthetic: false,
    wireKind: "turn_start",
    advancesClock: true,
    feedsToolUpdates: false,
    // #279: the declared, asserted exception — everSawWork yes, everSawRealActivity no.
    setsEverSawWork: true,
    realActivity: false,
    resetsStreamAge: true,
    resetsToolAge: true,
    drivesToolUpdates: false,
    resetsToolUpdates: false,
  },
  {
    id: "turn-end",
    event: "turn_end",
    synthetic: false,
    wireKind: "turn_end",
    advancesClock: true,
    feedsToolUpdates: false,
    setsEverSawWork: false,
    realActivity: false,
    resetsStreamAge: true,
    resetsToolAge: true,
    drivesToolUpdates: false,
    resetsToolUpdates: false,
  },
  {
    id: "tool-start",
    event: "tool_execution_start",
    synthetic: false,
    wireKind: "tool_start",
    advancesClock: true,
    feedsToolUpdates: false,
    setsEverSawWork: true,
    realActivity: true,
    resetsStreamAge: false,
    resetsToolAge: false,
    drivesToolUpdates: false,
    resetsToolUpdates: true,
  },
  {
    id: "tool-update",
    event: "tool_execution_update",
    synthetic: false,
    // No marker of its own — it rides the tick's `stream_age_ms` / `tool_updates`.
    wireKind: null,
    advancesClock: true,
    feedsToolUpdates: true,
    setsEverSawWork: false,
    realActivity: false,
    resetsStreamAge: false,
    resetsToolAge: false,
    drivesToolUpdates: false,
    resetsToolUpdates: false,
  },
  {
    id: "tool-end",
    event: "tool_execution_end",
    synthetic: false,
    wireKind: "tool_end",
    advancesClock: true,
    feedsToolUpdates: false,
    // everSawRealActivity yes; everSawWork NO (it is latched only by tool_start / turn_start).
    setsEverSawWork: false,
    realActivity: true,
    resetsStreamAge: true,
    resetsToolAge: false,
    drivesToolUpdates: false,
    resetsToolUpdates: true,
  },
  {
    id: "message-start",
    event: "message_start",
    synthetic: false,
    wireKind: null,
    advancesClock: true,
    advancesClockCondition: 'message.role === "assistant"',
    feedsToolUpdates: false,
    setsEverSawWork: false,
    realActivity: false,
    resetsStreamAge: false,
    resetsToolAge: false,
    drivesToolUpdates: false,
    resetsToolUpdates: false,
  },
  {
    id: "message-update",
    event: "message_update",
    synthetic: false,
    wireKind: null,
    advancesClock: true,
    feedsToolUpdates: false,
    setsEverSawWork: false,
    realActivity: false,
    resetsStreamAge: false,
    resetsToolAge: false,
    drivesToolUpdates: false,
    resetsToolUpdates: false,
  },
  {
    id: "session-shutdown",
    event: "session_shutdown",
    synthetic: false,
    wireKind: "session_end",
    advancesClock: false,
    feedsToolUpdates: false,
    setsEverSawWork: false,
    realActivity: false,
    resetsStreamAge: false,
    resetsToolAge: false,
    drivesToolUpdates: false,
    resetsToolUpdates: false,
  },
  {
    id: "child-tick",
    event: null,
    synthetic: true,
    wireKind: "tick",
    advancesClock: false,
    feedsToolUpdates: false,
    setsEverSawWork: false,
    realActivity: false,
    resetsStreamAge: false,
    resetsToolAge: false,
    drivesToolUpdates: true,
    resetsToolUpdates: false,
    realActivityCondition: "toolsInFlight > 0 || turnSawMessage || turnSawTool",
  },
];

// ── kill reasons (the clause vocabulary) ────────────────────────────────────

/**
 * The `HeartbeatKillReason` members, each with the bound that drives it. The
 * union TYPE is derived from this list — a new clause cannot be added to the
 * parent without appearing here.
 */
export const HEARTBEAT_KILL_REASONS = [
  "zero-output",
  "silence-threshold",
  "stream-stall",
  "tool-silence",
  "tool-dead",
  "tool-stall",
  "first-message-stall",
  "max-dispatch",
  "cut",
  "no-progress",
] as const;

export type HeartbeatKillReasonName = (typeof HEARTBEAT_KILL_REASONS)[number];

/** clause → the bound constant that gates it. */
export const KILL_REASON_BOUNDS: Readonly<Record<HeartbeatKillReasonName, string>> = {
  "zero-output": "FIRST_OUTPUT_TIMEOUT_MS — the tier-1 deadline that populates the entry's `firstOutputTimeoutMs`",
  "silence-threshold": "HEARTBEAT_TIMEOUT_MS (T)",
  "stream-stall": "max(60 s, TASK_STREAM_STALL_MS) override (env), else max(60 s, DEFAULT_STREAM_STALL_MS) (S) — resolvable PER DISPATCH from the task tool's stream_stall_ms arg (#1030) via resolveStreamStallMs, 60 s floor on every path",
  // Shares S with stream-stall: one constant, two conditions. Naming them as one
  // term would be wrong; naming them as two unrelated bounds would be wrong too.
  "tool-silence": "max(60 s, TASK_STREAM_STALL_MS) override (env), else max(60 s, DEFAULT_STREAM_STALL_MS) (S) — same bound as stream-stall, different condition; the dispatch override (stream_stall_ms, #1030) moves this clause too. Since #5389 it fires CONJUNCTIVELY with C as well (positive no-progress evidence from the CPU channel), so `TASK_CPU_STALL_MS=0` stands it down too and at the shipped defaults the binding condition is max(S, C) = C",
  // #928: the CPU-liveness bound (C) for a SILENT in-flight tool. The effective
  // value is resolved by getCpuStallMs (env override, 60 s floor, blank → the
  // default — never disabled by a typo), and 0 is the explicit off switch.
  "tool-dead": "max(60 s, TASK_CPU_STALL_MS) override (env) — 0 = OFF (explicit off switch), else DEFAULT_CPU_STALL_MS = 30 min (C); effective bound resolved by getCpuStallMs. Fires conjunctively with S, so the binding condition is max(S, C) = C",

  // The EFFECTIVE bound is max(60 s, TASK_TOOL_STALL_MS) when the env override
  // is a positive finite number; otherwise max(60 s, fraction × cap). Recording
  // only the fraction would let the bound move through a path the registry
  // cannot see, and omitting the 60 s floor would record a bound that does not
  // exist (#1068 review; the same shape PR #873 / #991 caught).
  "tool-stall": "max(60 s, TASK_TOOL_STALL_MS) override (env), else max(60 s, TASK_TOOL_STALL_FRACTION × effective hard cap from DEFAULT_HARD_CAP_MS) (L) — floored further by HEARTBEAT_TIMEOUT_MS while no turn is active",
  "first-message-stall": "max(60 s, TASK_FIRST_MESSAGE_MS) override (env), else max(60 s, DEFAULT_FIRST_MESSAGE_MS) (M) — then load-scaled and latched at the dispatch site",
  "max-dispatch": "max(60 s, TASK_MAX_DISPATCH_MS) override (env), else OFF — DEFAULT_MAX_DISPATCH_MS = 0 disables the cap (D)",
  // #5195: the ONLY progress-keyed bound. Not load-scaled and not latched — a
  // bound that WIDENS is how the class this clause catches escaped every other
  // clause, so widening is exactly what it must not do. 0 = explicit off.
  "no-progress": "max(60 s, 3 × the effective heartbeat interval, TASK_PROGRESS_AGE_MS) override (env) — 0 = OFF (explicit off switch, never a typo), else DEFAULT_PROGRESS_AGE_MS (45 min), both floored at the REPORTING CADENCE (the parent can only see progress when the child reports it, and the tick interval is operator-settable to 300 s). Deliberately NOT load-scaled and NOT latched; measured against PROGRESS (a completed unit of work or content-grounded child progress), never against elapsed dispatch time",
  "cut": "getEffectiveCutGapMs() / getCutGapMs() / TASK_HEARTBEAT_CUT_GAP_MS",
};

// ── independent drivers of "what counts as progress" ───────────────────────

/**
 * Every implementation that classifies progress, registered so the declaration
 * covers all of them. A driver that does NOT consume the shared classification
 * must state why (checked by `driverViolations`).
 */
export const PROGRESS_DRIVERS: readonly ProgressDriver[] = [
  {
    id: "child-clock",
    owner: "extensions/task-heartbeat.ts",
    mechanism: "in-process pi events → touchActivity() → stream_age_ms on the wire",
    sharesDeclaration: true,
  },
  {
    id: "parent-latches",
    owner: "extensions/builtin-tools/index.ts",
    mechanism: "parsed child marker kinds → everSawRealActivity/everSawMsg/everSawTool/firstActivityAt",
    sharesDeclaration: true,
  },
  {
    id: "child-content-progress",
    owner: "extensions/task-heartbeat.ts",
    mechanism:
      "assistantMessageEvent content inspection → `progress=<0|1>` on the tick; the parent stamps lastProgressAt from it (and from a parsed tool_end)",
    sharesDeclaration: false,
    reason:
      "#5195 — this is deliberately a SECOND, independent classifier, and it does NOT consume the edge table above. The edge table answers 'which pi events are LIFE SIGNS' (and every edge advances the child's activity clock). This driver answers a different question — 'did a unit of work COMPLETE, or did the model produce real CONTENT' — and it must NOT share the life-sign table, because sharing it is the bug: a tick/life-sign-only classification is forgeable by a process that is alive but doing nothing, which is exactly how the empty-turn loop and the drip stream escaped all nine existing clauses. Registered here so the divergence is DECLARED rather than accidental (the #1068 discipline: a driver that does not share the classification must say why).",
  },
  {
    id: "checkpoint-gate",
    owner: "extensions/sequence-enforcer/index.ts",
    mechanism: "wall-clock since the current checkpoint step last advanced",
    sharesDeclaration: false,
    reason:
      "gate axis: the input is checkpoint-step progress, not agent activity; it shares the stall vocabulary via this registry but not the edge classification.",
  },
  {
    id: "loop-exit",
    owner: "extensions/loop-enforcer/termination.ts",
    mechanism: "issue-fingerprint recurrence ratio between review cycles",
    sharesDeclaration: false,
    reason:
      "loop-exit axis: a fingerprint-recurrence ratio over cycles, not a time-since-progress clock; the value is owned by #847 and referenced here only as a pointer.",
  },
  {
    id: "fleet-reaper",
    owner: "scripts/pi-reap-idle.sh",
    mechanism: "process probe + pi session-JSONL last-entry age + cmux lifecycle veto",
    sharesDeclaration: false,
    reason:
      "reap axis: the input is a filesystem/process probe of a live session, not an in-session event stream; it cannot consume an in-process edge table.",
  },
  {
    id: "measurement-lane",
    owner: "scripts/time-to-first-activity-sweep.ts",
    mechanism: "session-log forensics (T0 = session event, first assistant message with content, first toolCall)",
    sharesDeclaration: false,
    reason:
      "measurement-only lane (#282): T0 is derived from persisted session JSONL, a different input shape; it must not share the child clock's implementation, only this declaration.",
  },
];

// ── the stall-term registry ─────────────────────────────────────────────────

const SCAN_OWNER = "extensions/shared/heartbeat-progress-edges.test.ts (forward assertion)";
const E14_PIN = "extensions/builtin-tools/builtin-tools.test.ts literal pin";
const SUBAGENT_PARITY = "extensions/subagent/subagent-parity.test.ts literal pin";
const SUBAGENT_TEST = "extensions/subagent/index.test.ts value+behaviour pin";
const BT_TEST = "extensions/builtin-tools/builtin-tools.test.ts value+behaviour pin";
const NONE = "declared and asserted by this registry (was unguarded before #1068)";
const FLEET_SUITE =
  "scripts/fleet-inventory.test.sh §9t (heartbeat, controller, cadence, job-slack) + §9e (lander) — each of these five seams moved on its own, BOTH directions, so a row can only flip because the BOUND moved and not because an age tripped any bound; this registry's forward check pins the VALUE";

/**
 * The stall / liveness / staleness bound vocabulary, with each term's owner
 * file(s), the fragment of its declaration line that carries the value, and who
 * guards it TODAY. `value: null` means the value is not a local literal: a
 * POINTER to another guard, DERIVED from other bounds, or resolved by a FUNCTION
 * (an env override). Its presence is still asserted, in declaration shape.
 *
 * SCOPE — what the two scan directions can and cannot see. The reverse scan
 * matches NAMES (`inFamily`), so a bound whose name carries no family token is
 * invisible to it unless it is registered in `OUT_OF_FAMILY_TERMS`. Two guards
 * keep that from being silent: (a) every bound a DECLARED kill clause names must
 * resolve to a registry entry (the clause→registry closure test), and (b) every
 * name listed in `OUT_OF_FAMILY_TERMS` must be registered in both directions.
 * What remains uncovered is DISCLOSED: a brand-new out-of-family bound that no
 * clause names and nobody registers is not detected. This registry is a
 * maintained vocabulary with a drift gate, not a proof of completeness.
 */
export const STALL_TERM_REGISTRY: readonly StallTerm[] = [
  // — kill axis: child heartbeat protocol —
  {
    name: "HEARTBEAT_INTERVAL_MIN_MS",
    owners: ["extensions/builtin-tools/index.ts", "extensions/task-heartbeat.ts"],
    value: "= 5_000;",
    axis: "kill",
    guardedBy: E14_PIN,
    note: "declared in BOTH the child and the parent — the duplicate E14 keeps equal",
  },
  {
    name: "HEARTBEAT_INTERVAL_MAX_MS",
    owners: ["extensions/builtin-tools/index.ts", "extensions/task-heartbeat.ts"],
    value: "= 300_000;",
    axis: "kill",
    guardedBy: E14_PIN,
  },
  {
    name: "DEFAULT_HEARTBEAT_INTERVAL_MS",
    owners: ["extensions/builtin-tools/index.ts", "extensions/task-heartbeat.ts"],
    value: "= 30_000;",
    axis: "kill",
    guardedBy: E14_PIN,
  },
  {
    name: "HEARTBEAT_TIMEOUT_MS",
    owners: ["extensions/builtin-tools/index.ts"],
    value: "|| 1_800_000",
    axis: "kill",
    guardedBy: NONE,
    note: "the `silence-threshold` clause bound (T); configurable via TASK_HEARTBEAT_TIMEOUT_MS",
  },
  // — kill axis: task-path bounds —
  {
    name: "DEFAULT_STREAM_STALL_MS",
    owners: ["extensions/builtin-tools/index.ts"],
    value: "= 1_200_000;",
    axis: "kill",
    guardedBy: NONE,
    note: "S — gates BOTH stream-stall and tool-silence; the EFFECTIVE bound is resolved by getStreamStallMs (a positive finite env override, else the default; FAIL-CLOSED, 60 s floor), or PER DISPATCH by resolveStreamStallMs (#1030)",
  },
  {
    name: "DEFAULT_TOOL_STALL_MS",
    owners: ["extensions/builtin-tools/index.ts"],
    value: "= 21_600_000;",
    axis: "kill",
    guardedBy: E14_PIN,
    note: "FROZEN 6h; the subagent backstop derives from it",
  },
  {
    name: "TASK_TOOL_STALL_FRACTION",
    owners: ["extensions/builtin-tools/index.ts"],
    value: "= 2 / 3;",
    axis: "kill",
    guardedBy: SUBAGENT_PARITY,
    note: "L is DERIVED: max(60 s, fraction × effective hard cap) — SUPERSEDED by the TASK_TOOL_STALL_MS env override when that is positive finite; BOTH paths floor at 60 s (see getToolStallMs)",
  },
  {
    name: "DEFAULT_FIRST_MESSAGE_MS",
    owners: ["extensions/builtin-tools/index.ts"],
    value: "= 300_000;",
    axis: "kill",
    guardedBy: NONE,
    note: "M — before #1068 only self-compared, so any value passed; the EFFECTIVE bound is resolved by getFirstMessageMs (env override, 60 s floor)",
  },
  {
    name: "DEFAULT_BACKSTOP_MARGIN_MS",
    owners: ["extensions/builtin-tools/index.ts", "extensions/subagent/index.ts"],
    value: "= 1_800_000;",
    axis: "kill",
    guardedBy: E14_PIN,
    note: "30 min over the frozen tool-stall bound",
  },
  {
    name: "DEFAULT_SUBAGENT_BACKSTOP_MARGIN_MS",
    owners: ["extensions/subagent/index.ts"],
    value: "= 900_000;",
    axis: "kill",
    guardedBy: SUBAGENT_PARITY,
  },
  {
    name: "HEARTBEAT_MS",
    owners: ["extensions/subagent/index.ts", "extensions/slack-bridge/socket-mode.ts"],
    value: "= 30_000;",
    axis: "heartbeat",
    guardedBy: NONE,
    note: "liveness CADENCE, not a stall bound: the subagent keep-alive emission interval and the slack-bridge socket keepalive. Two INDEPENDENT intervals that happen to share a name and a value. The shared forward assertion is deliberate — if either moves, this registry must be updated together (if they should diverge, split this into two terms with separate notes).",
  },
  // — loop-exit axis (pointer: #847 owns the value) —
  {
    name: "STALL_THRESHOLD",
    owners: ["extensions/loop-enforcer/termination.ts"],
    value: null,
    axis: "loop-exit",
    guardedBy: "extensions/loop-enforcer/tier-config-parity.test.ts (#847 STALL_THRESHOLD_SURFACES, 7 surfaces)",
    note: "POINTER ONLY — this registry deliberately holds no `stall_threshold` value",
  },
  // — hygiene axis: the lane's merge-phase marker (#2029) —
  {
    name: "_PHASE_AGE",
    owners: ["scripts/orchestrator-harness/chain-merge.sh"],
    value: null,
    axis: "hygiene",
    guardedBy:
      "scripts/orchestrator-harness/chain-merge-verdict.test.sh (case 4b: a marker older than the lane's wall limit is called STALE, reviewed immediately and removed) + this registry's presence check",
    note: "DERIVED, not a bound: the age in SECONDS of state/lanemerge-<PR>.phase, computed as now minus the epoch the marker itself carries. It belongs in this vocabulary because it answers a staleness question ('is this marker still a claim about the present'), but there is no local literal for the forward check to pin — the value is a subtraction of a value read at runtime — hence `value: null`. Its partner `_PHASE_STALE_AFTER` is the comparison bound and is deliberately NOT registered: it is not a local literal either (it is `LANE_TIMEOUT + 60s`, a pointer to the lane's own declared wall clock), and registering a pointer-to-a-pointer would imply an independence that does not exist.",
  },
  // — gate axis —
  {
    name: "WALL_CLOCK_STALL_MS",
    owners: ["extensions/sequence-enforcer/index.ts"],
    value: "= 5 * 60 * 1000;",
    axis: "gate",
    guardedBy: NONE,
    note: "checkpoint park trigger — parks state, kills nothing",
  },
  {
    name: "RERUN_FLOOR",
    owners: ["scripts/admin-merge.sh"],
    value: "${ADMIN_MERGE_RERUN_FLOOR:-1200}",
    axis: "gate",
    guardedBy: NONE,
    note: "the merge gate's re-run bound FLOOR (#1167): the bound is max(FLOOR, 2 × max(green duration) for the shard), and that DERIVED per-shard bound is the rail's ONLY STALLED threshold — a remote run exposes no within-job activity signal, so there is no second window to order against it. The FLOOR only ever RAISES a bound, so it cannot false-block a healthy run. Env seam ADMIN_MERGE_RERUN_FLOOR; shipped default 1200 s; behaviour pinned by tests/admin-merge/run.sh §41.",
  },
  {
    name: "FAILSAFE_RERUN_TIMEOUT",
    owners: ["scripts/admin-merge.sh"],
    value: "${ADMIN_MERGE_RERUN_TIMEOUT_FALLBACK:-3900}",
    axis: "gate",
    guardedBy: NONE,
    note: "the merge gate's derivation FAIL-SAFE (#1167): the bound used when the per-shard derivation is unavailable. The shipped default (3900 s) is deliberately well above RERUN_FLOOR's 1200, because a derivation that failed must never produce a SMALL bound. Env seam ADMIN_MERGE_RERUN_TIMEOUT_FALLBACK; behaviour pinned by tests/admin-merge/run.sh §41.",
  },
  {
    name: "QUEUE_STUCK_AFTER_S",
    owners: ["scripts/ci_runner_gate.sh"],
    value: "${CI_GATE_QUEUE_STUCK_AFTER_S:-1800}",
    axis: "gate",
    guardedBy:
      "scripts/ci_runner_gate.test.sh (#2904: a stalled queue takes the fallback path, a deep-but-serving queue and a young queue take NO action, an unreadable floor exits 2, plus the age-only mutant that proves the conjunction is load-bearing) + this registry's forward check pins the shipped default",
    note: "the CI runner gate's ABSORPTION floor (agent-infra#2904): how long a QUEUED run may wait while NOTHING is executing before GitHub-hosted is called unhealthy and the gate takes its own existing fallback path. The clock is QUEUE WAIT — `now - created_at` of a still-queued run — NOT run duration: `run_started_at` is not a dispatch marker for a queued run (measured, run 40508520800: created 13:01:55Z, run_started_at 13:01:55Z, first job dispatched 13:23:59Z). Shipped default 1800 s, drawn from the same repo's own measurements: 12,624 of 13,000 sampled runs waited 0 s, and the longest gap between run starts while runs were still being created was 920 s. ⛔ IT IS DELIBERATELY NOT NAMED `*_STALL_THRESHOLD`: that phrase is #847's single authority, and the boundary test above refuses a term carrying `/stall_?threshold/i` WHILE holding a value here — this bound is owned HERE, so the honest option is a name the reverse scan can still see (`STUCK` is a declared family token, `_S` a declared bound suffix) and a registered value, not a `value: null` pointer that would falsely claim #847 owns it.",
  },
  // — reap axis (interactive session reaper) —
  {
    name: "REAP_IDLE_HOURS",
    owners: ["scripts/pi-reap-idle.sh"],
    value: "${REAP_IDLE_HOURS:-24}",
    axis: "reap",
    guardedBy: NONE,
    overrides: ['REAP_IDLE_HOURS="$2"', "10#${REAP_IDLE_HOURS}"],
    note: "the owner re-assigns it twice more (a `--hours` CLI override, then a base-10 coercion) — both lines are recorded so a third assignment cannot shadow the default unnoticed",
  },
  {
    name: "REAP_STUCK_HOURS",
    owners: ["scripts/pi-reap-idle.sh"],
    value: null,
    axis: "reap",
    guardedBy: NONE,
    overrides: ['REAP_STUCK_HOURS="$2"', "REAP_IDLE_HOURS * 3", "10#${REAP_STUCK_HOURS}"],
    note: "DERIVED: defaults to 3× REAP_IDLE_HOURS, resolved at runtime; the three further assignments are the CLI override, the derivation and the coercion",
  },
  {
    name: "CR_MIN_AGE",
    owners: ["scripts/orchestrator-harness/claim-reaper.sh"],
    value: "=10800",
    axis: "reap",
    guardedBy: NONE,
    overrides: ['CR_MIN_AGE="${1:-}"'],
    note: "#2246 — the age FLOOR below which a claim is never released however dead its holder looks (default 10800 s = CLAIM_ISSUE_TTL, the longest shipped lease). It is the belt that makes holder-absence evidence a FLOOR rather than a proof: `claim-reaper.sh` releases nothing on age alone (`TOO-YOUNG` is a verdict), and this floor is what bounds the damage when an absence probe is wrong. The `--min-age` flag re-assigns it, so both lines are recorded. Only a magnitude of at most 18 digits is accepted (`cr_int`), because an overflowing bound makes `[ -lt ]` ERROR and an errored test is FALSE — the gate would fail OPEN. Behaviour pinned by scripts/orchestrator-harness/claim-reaper.test.sh case A (a young claim is TOO-YOUNG and survives `--release`) and case E (an overflowing `--min-age` is refused, exit 3).",
  },
  {
    name: "REAP_GRACE_SECONDS",
    owners: ["scripts/pi-reap-idle.sh"],
    value: "${REAP_GRACE_SECONDS:-5}",
    axis: "reap",
    guardedBy: NONE,
    note: "post-signal settle grace before the survivor re-check",
  },
  {
    name: "REAP_MAX_HOURS",
    owners: ["scripts/pi-reap-idle.sh"],
    value: "${REAP_MAX_HOURS:-1000000}",
    axis: "reap",
    guardedBy: NONE,
    overrides: ["10#${REAP_MAX_HOURS}"],
  },
  {
    name: "REAP_LOCK_STALE_SECONDS",
    owners: ["scripts/pi-reap-idle.sh"],
    value: "${REAP_LOCK_STALE_SECONDS:-1800}",
    axis: "reap",
    guardedBy: NONE,
  },
  // — reap axis: the ORPHAN reaper (scripts/pi-reap-orphans.sh, #1862). The
  //   reverse scan found FIVE the moment the reaper was versioned, exactly as it
  //   did for the heartbeat bounds in #1552; the SIXTH, the active-CPU floor,
  //   ends in `_CENTISECONDS`, which the suffix set did not carry until #1863 —
  //   it was invisible to the name scan, not absent. Registered rather than
  //   exempted: each IS a real liveness bound governing whether a candidate may
  //   be signalled. The two properties the issue requires live here and in the
  //   ancestry gate: an ACTIVE CPU advance (never a PARKED test, cf. #1343) on an
  //   AGE FLOOR, and a POSITIVE human-ancestry refusal.
  {
    name: "REAP_ORPHAN_SAMPLE_SECONDS",
    owners: ["scripts/pi-reap-orphans.sh"],
    value: "${REAP_ORPHAN_SAMPLE_SECONDS:-3}",
    axis: "reap",
    guardedBy: NONE,
    overrides: ['REAP_ORPHAN_SAMPLE_SECONDS="$2"'],
    note: "the two-`ps`-snapshot window the CPU-time delta is measured over; the second assignment is the `--sample-seconds` CLI override",
  },
  {
    name: "REAP_ORPHAN_MIN_CPU_CENTISECONDS",
    owners: ["scripts/pi-reap-orphans.sh"],
    value: "${REAP_ORPHAN_MIN_CPU_CENTISECONDS:-1}",
    axis: "reap",
    guardedBy: NONE,
    overrides: ['REAP_ORPHAN_MIN_CPU_CENTISECONDS="$2"'],
    note: "the ACTIVE-CPU floor: cpu-time must advance by at least this many CENTISECONDS across the sample window (1 = any measurable advance; 100 = one CPU-second). CPU time stays in centiseconds because `ps -o time` prints MM:SS.ss and integer-second truncation read a sustained 10%-of-a-core leak as 0 -> 0 (`cpu-idle`). The `--min-cpu-centiseconds` CLI override is the second assignment.",
  },
  {
    name: "REAP_ORPHAN_MIN_ELAPSED_SECONDS",
    owners: ["scripts/pi-reap-orphans.sh"],
    value: "${REAP_ORPHAN_MIN_ELAPSED_SECONDS:-60}",
    axis: "reap",
    guardedBy: NONE,
    overrides: ['REAP_ORPHAN_MIN_ELAPSED_SECONDS="$2"'],
    note: "the AGE FLOOR: a process younger than this is never signalled (the leak class outlives its harness by minutes, and a fresh reparented child is still being set up). Active-CPU advance is the other half of the pair — a PARKED process is never a candidate (#1343).",
  },
  {
    name: "REAP_ORPHAN_TERM_GRACE_SECONDS",
    owners: ["scripts/pi-reap-orphans.sh"],
    value: "${REAP_ORPHAN_TERM_GRACE_SECONDS:-5}",
    axis: "reap",
    guardedBy: NONE,
    note: "post-SIGTERM settle grace before the re-probe escalates to SIGKILL; a death that cannot be re-verified counts as STILL ALIVE",
  },
  {
    name: "REAP_ORPHAN_BUDGET_SECONDS",
    owners: ["scripts/pi-reap-orphans.sh"],
    value: "${REAP_ORPHAN_BUDGET_SECONDS:-300}",
    axis: "reap",
    guardedBy: NONE,
    note: "the pass wall-clock budget: classification stops and DEFERS the remainder rather than holding the host it exists to unload",
  },
  {
    name: "REAP_ORPHAN_LOCK_STALE_SECONDS",
    owners: ["scripts/pi-reap-orphans.sh"],
    value: "${REAP_ORPHAN_LOCK_STALE_SECONDS:-1800}",
    axis: "reap",
    guardedBy: NONE,
    note: "how old a reaper lock must be before a DEAD owner's lock is broken; a LIVE owner holds it outright whatever the directory age",
  },
  {
    name: "REAP_MIN_S",
    owners: ["scripts/orchestrator-harness/cloud-cell-doctor.sh"],
    value: "${REAP_MIN_S:-2700}",
    axis: "reap",
    guardedBy:
      "scripts/orchestrator-harness/cloud-cell-doctor.test.sh §reap — a lane younger than the floor is NOT killed, and one past it is; the value is asserted by THIS registry's forward check, since the suite drives its own REAP_MIN_S in the environment",
    note: "how long a worker lane must have been idle before the cell's reap role may kill it (45 min). The cell reaps on a schedule, so the floor is what stops a scheduled pass from killing a lane that is merely between tool calls — the same class `REAP_IDLE_HOURS` bounds for the interactive reaper, at the far shorter cadence a cloud cell runs at.",
  },
  {
    name: "REAP_SAMPLE_S",
    owners: ["scripts/orchestrator-harness/cloud-cell-doctor.sh"],
    value: "${REAP_SAMPLE_S:-15}",
    axis: "reap",
    guardedBy:
      "scripts/orchestrator-harness/cloud-cell-doctor.test.sh §reap — the two-observation gate: a lane that is BUSY on the second sample is not reaped, and an unreadable first sample is cannot-verify rather than dead",
    note: "the spacing between the reap role's two observations of a candidate lane's CPU. Two samples are what separate an idle lane from one that is mid-command (a single snapshot cannot), so this is the width of that gate — NOT a bound on how long work may take.",
  },
  {
    name: "HYGIENE_TMP_MIN_AGE_S",
    owners: ["scripts/orchestrator-harness/cloud-cell-doctor.sh"],
    value: "${HYGIENE_TMP_MIN_AGE_S:-3600}",
    axis: "reap",
    guardedBy:
      "scripts/orchestrator-harness/cloud-cell-doctor.hygiene.test.sh §temp — a dir whose embedded pid is dead AND whose mtime is past this floor is reaped, while a FRESH one (dead pid, written seconds ago) is KEPT with its reason; the `> 0` bound is refused at load by cloud-cell-doctor.sh's numeric validation, because a zero floor leaves a recycled pid as the only proof a temp dir is idle",
    note: "#2573 — how long a `cloud-cell-<pid>.<rand>` temp dir must have been untouched before the hygiene role may reclaim it, once its embedded pid is provably gone. The pid is the primary proof; this floor is the SECOND gate that covers pid RECYCLING (the name's pid can be dead now and have belonged to something else by the time the dir was written). A zero floor makes the recycling hole unbounded, which is why the loader refuses it by name rather than silently accepting a vacuous bound.",
  },
  {
    name: "LANE_IDLE_MIN",
    owners: ["scripts/orchestrator-harness/lane-reap.sh"],
    value: "${LANE_REAP_IDLE_MIN:-120}",
    axis: "reap",
    guardedBy:
      "scripts/orchestrator-harness/lane-reap.test.sh §idle — a lane whose log has not advanced past the bound is a reap candidate, and one that HAS keeps it; the value is asserted by THIS registry's forward check, since the suite drives its own LANE_REAP_IDLE_MIN in the environment",
    overrides: ["LANE_IDLE_MIN=120"],
    note: "#2163 — how long a lane's own activity log must have gone untouched before the reaper treats the lane as finished (2 h), in MINUTES. Deliberately NOT named `IDLE_MIN`: that symbol is a REGISTERED term owned by `scripts/orchestrator-heartbeat.sh` (a 9-minute spinner-absent classification bound, declared-not-read), and sharing the name made one authority out of two unrelated numbers — exactly the divergence this registry exists to surface. This one is READ (it decides a kill), and it is the log-evidence gate that outranks age: a lane with no log takes the 12 h `NO_LOG_H` path instead, and a lane whose log advanced inside this window is never signalled.",
  },
  {
    name: "MAX_AGE",
    owners: ["scripts/monitor-worker.sh"],
    value: "${2:-60}",
    axis: "reap",
    guardedBy: NONE,
    note: "worker-log freshness bound — an AGED, not family-named, bound",
  },
  {
    name: "SWEEP_MAX_AGE",
    owners: ["scripts/orchestrator-harness/orch-loop.sh"],
    value: '"${SWEEP_MAX_AGE:-600}"',
    axis: "hygiene",
    guardedBy:
      "scripts/orchestrator-harness/sweep-quota.test.sh behaviour + non-vacuity pin (fixtures 5, 11 and 13 drive the staleness floor: a stale stamp forces the fetch, a future stamp and a >10-digit stamp are both dropped); the VALUE is asserted by THIS registry's forward check, not by the suite — the suite sets its own SWEEP_MAX_AGE in the environment it drives",
    overrides: ["SWEEP_MAX_AGE=600"],
    note: "how long a 304 may serve a cached PR listing before `If-None-Match` is DROPPED and a full sweep forced (#1762). A FRESHNESS bound, not a kill bound: a completed check run does NOT reliably bump the listing ETag (measured), so without this floor a green PR could sit unmerged behind a cached \"unchanged\" forever — the cell-cannot-merge-reads-as-idle failure the bound exists to remove. The second declaration is the is_limit coercion; it is recorded so a third assignment cannot shadow the default unnoticed.",
  },
  // — hygiene axis: the claim snapshot's FRESHNESS bound (#2466) —
  //
  // A cache-freshness bound, not a kill bound: `$O/state/claims-snapshot` is rewritten each cycle
  // so `claim_live()` pays no per-PR network call, and this is how long a read may be believed
  // before the file is refused as `claim-unreadable`. Without it the cache is an unfalsifiable
  // answer — a claim published since the last good fetch would be INVISIBLE, and two cells would
  // select the same PR. The reverse scan caught its absence here: a new stall-family declaration
  // that nobody classified is exactly how an unbounded bound reappears, so it is registered on
  // introduction rather than after the first incident.
  {
    name: "CLAIM_SNAPSHOT_MAX_AGE",
    owners: ["scripts/orchestrator-harness/claims.sh"],
    value: '"${CLAIM_SNAPSHOT_MAX_AGE:-900}"',
    axis: "hygiene",
    guardedBy:
      "scripts/orchestrator-harness/test-gates.sh — \"a snapshot OLDER than the age bound is NOT ownership (a claim published since would be invisible)\" drives the shipped reader with a snapshot 100000 s old and asserts UNOWNED; the value itself is asserted by THIS registry's forward check, not by the suite, because the suite ages the FILE rather than setting the bound",
    overrides: [
      "''|*[!0-9]*|0*) CLAIM_SNAPSHOT_MAX_AGE=900 ;;",
      "[ \"${#CLAIM_SNAPSHOT_MAX_AGE}\" -le 9 ] || CLAIM_SNAPSHOT_MAX_AGE=900 ;;",
    ],
    note: "#2466 — how stale a claim snapshot may be and still be believed (900 s ≈ 3.75 cycles at the shipped CYC=240). THREE shapes reach `claim-unreadable` and the bound governs only the third: no file at all, a header whose own fetch field says `failed` (refused at ANY age, because that test is the `if` and the age test only the `elif` — the bound must never be read as re-admitting a failed read), and an `ok` header older than this bound. The second declaration is the is_limit-style coercion that drops a zero/overflowing value back to 900, so an overflowing bound cannot make `[ -gt ]` error and turn the age test FALSE — an errored test is FALSE, which here would fail OPEN by believing every snapshot forever; it is recorded so a third assignment cannot shadow the default unnoticed.",
  },
  {
    name: "LANE_ARM_SNAPSHOT_MAX_AGE",
    owners: ["scripts/lane-arm.sh"],
    value: "\"${LANE_ARM_SNAPSHOT_MAX_AGE_OPT:-$(( BUDGET * 2 + 60 ))}\"",
    axis: "hygiene",
    guardedBy: NONE,
    note: "how old the reading a lane-arm pass publishes may be WHEN IT BECOMES CURRENT (default 2 x --budget + 60 s, i.e. 540 s at the shipped 240 s budget), reachable as `--max-snapshot-age`. Applied twice: after the sample (cheap refusal) and again at PUBLISH, which is the binding arm because it also covers the renderer's own bounded run — the stamp in the queue header is rewritten to that same number, so the field and the gate cannot disagree. ⛔ DERIVED, NOT A LITERAL, AND THAT WAS THE FIX (2026-10-31 review): over a 240 s sampler budget a literal 900 was a bound the code could not reach — the sample is hard-killed at its budget, so `sa` is always < BUDGET — i.e. an inert enforcer advertising protection it never gave. ⛔ AND THE `+ 60` IS NOT DECORATION either (review cycle 2): `2 x BUDGET` alone modelled only the two bounded legs and left NO headroom for the pass's own python/awk/rename work, so a legitimate pass (1.9 s sample + 1.9 s render under `--budget 2`) was refused as stale — measured. The margin is the same one LANE_ARM_LOCK_REAP_S uses, and it makes the gate fire on an OVERRUN rather than on the overhead its own legs are entitled to. Deliberately NOT named `MAX_AGE`: that symbol is a REGISTERED term owned by `scripts/monitor-worker.sh` (a worker-log freshness bound at `${2:-60}`), and the reverse scan refused the collision — one name over two unrelated numbers is the divergence this registry exists to surface. Co-owner registration instead would be a lie: the forward check requires the SAME value in every owner. The `_OPT` suffix on the CLI variable keeps this the ONE declaration of the term.",
  },
  {
    name: "LANE_ARM_LOCK_REAP_S",
    owners: ["scripts/lane-arm.sh"],
    value: "$(( BUDGET * 2 + 60 ))",
    axis: "reap",
    guardedBy: NONE,
    note: "how old a lane-arm pass's LOCK file may be before the next pass reaps it, default 2 x --budget + 60 s. ⛔ THE INEQUALITY IS THE POINT (2026-10-31 review): this bound must EXCEED the longest legitimate pass (2 x BUDGET, sample plus renderer), or a second fire reaps a LIVE lock and the two passes interleave their artefacts — one pass's snapshot published beside the other's queue. A fixed 900 against a `--budget 1200` pass (2400 s worst case) did exactly that, measured; deriving it from the budget makes the inequality structural instead of a constant an operator can outgrow. ⛔ LOCK OWNERSHIP IS A PID, NOT THIS AGE: the lock records its holder and a pid that no longer exists is stale IMMEDIATELY, so a SIGKILLed pass no longer makes every fire for the whole window print 'skipping' and exit 0 (under Type=oneshot, SUCCESS with nothing produced — the no-op-gate shape). This bound is only the last resort for a lock whose holder this pass cannot identify at all.",
  },
  // — gate axis: the merge-priority gate's measured EVIDENCE AGES (#2040) —
  //
  // These are not kill bounds. They are the two readings the bounded
  // merge-priority gate compares against its age window, and the failure they
  // exist to prevent is the gate that can never open: "drain the unowned PRs
  // first" is a condition no unattended lane can clear, so an UNBOUNDED gate
  // stops dispatch forever while every cycle reports success. Registering them
  // here is what stops a future lane from re-introducing an unbounded form
  // unnoticed: the reverse scan refuses a new stall/liveness-family
  // declaration that nobody classified, which is exactly how an unbounded
  // bound reappears.
  {
    name: "LAND_AGE",
    owners: ["scripts/orchestrator-harness/orch-loop.sh"],
    value: '""',
    axis: "gate",
    guardedBy:
      "test-gates.sh: the value is driven from a REAL backdated state/merged-<PR>.done marker and read back through mp_recent_land (a fresh stamp yields a small age, a stale one a large age); the no-marker case is an empty value, which the [cap] line renders as '?'",
    overrides: ["$(( (_now_a - (10#$LAND_EPOCH)) / 60 ))"],
    note: "age (minutes) of the last LAND seen by this box; the second declaration is the derived value from LAND_EPOCH. Empty means 'no land observed'. It is DISPLAY ONLY (#2099): it feeds the `[cap] last_land=` field and the DRAIN STALLED diagnostic, and it deliberately gates NOTHING — an empty or large age must never open the issue path, because 'PRs are not landing' is a land/capacity problem to fix, not a licence to dispatch new work (the age-based RELEASE #2038 proposed was rejected as a reversal of the owner's ruling and is pinned absent in test-gates.sh).",
  },
  // — gate axis: the ORIGINATION funnel's one liveness bound (agent-infra#2229) —
  //
  // `refresh-candidates.sh` writes a `result=running` tombstone at entry and its outcome at
  // exit, so a record that still says `running` cannot distinguish a pass that is WORKING from
  // one that DIED. The reader separates them by AGE against this bound, and the SAME constant
  // bounds the stale-`.refresh.lock` guard — one number, two uses, so the beat and the
  // controller cannot disagree about when a pass is dead. Registered here because a bound the
  // beat acts on but no audit knows about is exactly the invisibility #1068 exists to remove.
  {
    name: "REFRESH_STALE_LOCK_MIN",
    owners: ["scripts/orchestrator-harness/orch-loop.sh"],
    value: '"${REFRESH_STALE_LOCK_MIN:-20}"',
    overrides: ["REFRESH_STALE_LOCK_MIN=20"],
    axis: "gate",
    guardedBy:
      "scripts/orchestrator-harness/origination-funnel.test.sh §5c drives the shipped gate block: a start marker YOUNGER than the bound reads as in flight (`deferred (` / `nothing to defer`), a marker PAST it reads `BLOCKED`, and an unreadable `at=` reads `BLOCKED`",
    note: "the in-flight/dead bound for an ORIGINATION pass (20 min default, env seam REFRESH_STALE_LOCK_MIN): younger ⇒ a pass is working (the ordinary state on a short backlog, because the refresh only runs while the queue is short — never `BLOCKED`); older ⇒ it DIED (SIGKILL, OOM, cycle timeout, uncaught error) and nothing but a finishing pass will replace the marker. Reused deliberately as the stale-`.refresh.lock` bound so there is ONE number, not two that can drift.",
  },
  {
    name: "RUNNING_STALE_MIN",
    owners: ["scripts/orchestrator-harness/orch-loop.sh"],
    value: '"${REFRESH_RUNNING_STALE_MIN:-$REFRESH_STALE_LOCK_MIN}"',
    overrides: ['RUNNING_STALE_MIN="$REFRESH_STALE_LOCK_MIN"'],
    axis: "gate",
    guardedBy:
      "scripts/orchestrator-harness/origination-funnel.test.sh §5c — the reader's in-flight/dead split (see REFRESH_STALE_LOCK_MIN)",
    note: "DERIVED alias of REFRESH_STALE_LOCK_MIN, kept as its own symbol so the reader can be re-pointed without touching the lock guard. `inFamily` cannot see it (no family token in `RUNNING`), so it is registered rather than left to the reverse scan — the audit should know every bound the beat acts on.",
  },
  // — retention axis —
  {
    name: "MAX_AGE_DAYS",
    owners: ["scripts/pi-task-session-prune.sh"],
    value: "${TASK_SESSION_MAX_AGE_DAYS:-7}",
    axis: "retention",
    guardedBy: NONE,
  },
  {
    name: "IDLE_DAYS",
    owners: ["scripts/stale-worktrees.sh"],
    value: "=14",
    axis: "retention",
    guardedBy: NONE,
    overrides: ['IDLE_DAYS="$2"'],
    note: "the owner takes a CLI override in a `case` arm (`--idle-days)`), which is why the shell extraction accepts a name= after any non-identifier character",
  },
  {
    name: "REAP_WT_AGED_DAYS",
    owners: ["scripts/pi-reap-worktrees.sh"],
    value: "${REAP_WT_AGED_DAYS:-7}",
    axis: "retention",
    guardedBy: NONE,
    overrides: ['REAP_WT_AGED_DAYS="$2"'],
  },
  {
    name: "REAP_WT_MERGED_AGE_DAYS",
    owners: ["scripts/pi-reap-worktrees.sh"],
    value: "${REAP_WT_MERGED_AGE_DAYS:-0}",
    axis: "retention",
    guardedBy: NONE,
    note: "#2032 — the age floor applied to a MERGED worktree head (default 0: merged is reclaimed the same day, because the merge is the proof the work landed and the tree is separately required to be clean). It REPLACES REAP_WT_AGED_DAYS for that row only; an UNMERGED head keeps the blanket floor, where age still separates a stale scratch checkout from work in progress. Set it equal to REAP_WT_AGED_DAYS to restore the pre-exemption behaviour. Without it the measured biggest reclaimable checkout on cell-3 (5.7 GB, merged, clean, holder-free) was held for a week while the box sat at 87% used: the merge proves the work landed, and the tree is separately required to be clean, so age has nothing left to protect. Without it the measured biggest reclaimable checkout on cell-3 (5.7 GB, merged, clean, holder-free) was held for a week while the box sat at 87% used. An UNMERGED head keeps the blanket floor — there age still separates a stale scratch checkout from work in progress. 0 restores the pre-exemption behaviour, so the exemption is visible and reversible rather than baked in.",
  },
  {
    name: "REAP_WT_SCRATCH_AGE_DAYS",
    owners: ["scripts/pi-reap-worktrees.sh"],
    value: "${REAP_WT_SCRATCH_AGE_DAYS:-1}",
    axis: "retention",
    guardedBy: NONE,
    note: "#2354 — the age floor for a LANE SCRATCH checkout (`wt-*` / `cell-wt-*` at any depth), 1 day. A dead lane's scratch dir is a throwaway, not the 7-day review surface a named issue branch is; the 7-day blanket floor held it (and its disk) for a week after the lane was gone, which is why the reaper reclaimed zero. It only ever CAPS DOWN (a value above the floor in force has no effect, so 14 cannot mean 'keep longer'), it never replaces a merged/patch-equivalent floor, and it touches AGE ONLY — every survival gate (clean / no live holder / no open PR / ref-holding) is unchanged, so a young-but-finished scratch dir is still reclaimed and an old-but-dirty one is not. Registered rather than exempted because it IS a retention bound in the same family as REAP_WT_AGED_DAYS/REAP_WT_MERGED_AGE_DAYS above, and a reader must be able to see the floor move.",
  },
  {
    name: "REAP_WT_MAX_DAYS",
    owners: ["scripts/pi-reap-worktrees.sh"],
    value: "${REAP_WT_MAX_DAYS:-1000000}",
    axis: "retention",
    guardedBy: NONE,
  },
  {
    name: "REAP_WT_BUDGET_SECONDS",
    owners: ["scripts/pi-reap-worktrees.sh"],
    value: "${REAP_WT_BUDGET_SECONDS:-300}",
    axis: "retention",
    guardedBy: NONE,
  },
  {
    name: "REAP_WT_LOCK_STALE_SECONDS",
    owners: ["scripts/pi-reap-worktrees.sh"],
    value: "${REAP_WT_LOCK_STALE_SECONDS:-1800}",
    axis: "retention",
    guardedBy: NONE,
    overrides: ['REAP_WT_LOCK_STALE_SECONDS="$REAP_WT_LOCK_STALE_CLAMPED"'],
    note: "#2541 review P2 — the lock horizon is RAISED to 4x REAP_WT_BUDGET_SECONDS when the two are configured the wrong way round (a stale-lock age test that ignores the budget breaks a LIVE owner's lock). It is registered as an override, not left unrecorded, because it is a second, value-CHANGING assignment to the same bound: the effective horizon in force is then the clamped one, so an unrecorded clamp is a green gate over a wrong effective value. The clamp is never silent — it is reported as a WARN before the lock is taken, so the artifact always names the horizon actually in force.",
  },
  {
    name: "VENV_MIN_AGE",
    owners: ["scripts/disk-reaper.sh"],
    value: "${DISK_REAPER_VENV_MIN_AGE:-1800}",
    axis: "retention",
    guardedBy: NONE,
    overrides: ['VENV_MIN_AGE="$2"'],
    note: "#2032 — the entry point's pass-through of the venv GC age floor to its owner (reap-lane-venvs.sh, whose own REAP_VENV_MIN_AGE_SECONDS is registered above). It exists here so the scheduled cell pass can tune the floor WITHOUT editing the owner, and it is registered because a floor that only the scheduler knows about is invisible to the audit that exists to notice exactly that. Unset means the owner's 1800 s.",
  },
  {
    name: "REAP_VENV_MIN_AGE_SECONDS",
    owners: ["scripts/reap-lane-venvs.sh"],
    value: "${REAP_VENV_MIN_AGE_SECONDS:-1800}",
    axis: "retention",
    guardedBy: NONE,
    overrides: ['REAP_VENV_MIN_AGE_SECONDS="${1:-}"'],
    note: "#1932 — the GC-only age FLOOR on a lane venv (30 min): a venv whose newest mtime is younger is KEPT regardless of liveness, so a lane that has not yet started work cannot lose its env to a sweep that ran between its `uv sync` and its first command. It is a floor, never a rule — the delete decision is the three live witnesses, and liveness outranks age in BOTH directions (a venv older than the floor is still kept while any witness names a holder). The `--worktree` (lane-exit) mode bypasses it by construction: there the caller declares the lane dead. The floor is registered rather than exempted because it IS a retention bound in the same family as REAP_WT_* above, and a reader must be able to see it move.",
  },
  {
    name: "REAP_VENV_FREE_FLOOR_MB",
    owners: ["scripts/reap-lane-venvs.sh"],
    value: "${REAP_VENV_FREE_FLOOR_MB:-2048}",
    axis: "hygiene",
    guardedBy: NONE,
    note: "#1932 (review of PR #1949) — the STATED free-disk floor the reaper's per-pass capacity line asserts against (2 GiB = one MEASURED lane env, ~1.85 GB of real non-shared disk per lane), so 'above the floor' means 'one more lane still fits'. Registered rather than left as a bare constant because it bounds how much of the box the fleet may consume, and a bound only the reaper knows about is invisible to the audit that exists to notice exactly that. It ASSERTS, it does not reclaim: a breach exits 5 (the reaper's own `over-bound` code — `disk-reaper.sh` KEEPS that 5 since agent-infra#2156 landed, so an apply pass records `rc=3 verdict_venv=fail-closed` and a dry run records `rc=5 verdict_venv=over-bound`; the old `worst_rc` drop of 5 that recorded `rc=0 verdict=ok` is gone, do not restate it) and is named on the report, and no live lane's env is ever deleted to get back above it. Unlike the age floor this is a SPACE bound, so it answers to the hygiene axis (disk reapers that are not agent-stall detectors), not retention.",
  },
  // — heartbeat axis: the laptop-only orchestrator heartbeat's lane-classifier
  //   bounds (scripts/orchestrator-heartbeat.sh, landed from the laptop layer in
  //   #1552). They classify a lane as idle / free capacity; they are liveness
  //   thresholds, not kill switches, so they answer to the heartbeat axis. The
  //   reverse scan found all four the moment the file landed — registered here
  //   rather than exempted, because each IS a real liveness bound.
  //   DISCLOSED, not silently skipped: the same file's `STALE_MIN` (12 m),
  //   `MIN_GAP_MIN` (4 m), `PULSE_MIN` (5 m) and `SCAN_INTERVAL_S` (2700 s) carry no
  //   family token, so the name scan cannot see them and neither scan direction can go
  //   red on them — the coverage limit documented at `OUT_OF_FAMILY_TERMS`. They are
  //   named here because each IS a bound in this file, and a reader who trusts the
  //   registry to hold every bound in it should know it does not. They are NOT added to
  //   `OUT_OF_FAMILY_TERMS`: that list's invariant is that every name in it is also a
  //   registry entry.
  {
    name: "IDLE_MIN",
    owners: ["scripts/orchestrator-heartbeat.sh"],
    value: "=9",
    axis: "heartbeat",
    guardedBy: NONE,
    note: "DECLARED, NOT READ — the same shape as SCAN_MAX_AGE_S below, and its sibling `STALE_MIN` (:60, 12 m) is inert the same way. The name describes a real classification rule, but no code path in its owner script, `scripts/orchestrator-heartbeat.sh`, expands either symbol: a word-boundary grep there returns the two declarations and nothing else, and neither is exported. The threshold that actually decides is implemented elsewhere and with a different number — `lane-status.py`'s `stale > 600` and `turn-end.py`'s `IDLE_MIN_S = 600`, i.e. 10 minutes, not 9. Registered so the DECLARED bound is in the vocabulary; the divergence is recorded on #1811 rather than silently relied on.",
  },
  {
    name: "CAP_IDLE_MIN",
    owners: ["scripts/orchestrator-heartbeat.sh"],
    value: "=20",
    axis: "heartbeat",
    guardedBy: NONE,
    note: "the FREE-CAPACITY eligibility bound, in MINUTES: a lane must be stale at least this long before it is a candidate for the free list (a lane merely BETWEEN steps is the measured false positive the clause's 9 m sibling is meant to avoid). Eligibility is not an offer — WHEN the live-record set is non-empty, a candidate with no live pi OF ITS OWN (the pid record, or a pane probe when the record is silent) is then DROPPED, never offered, because a dead pane still carries its last session file and would otherwise read as idle-forever. (The precondition is real: if `cmux sessions list` returns nothing at all the record set is empty, the filter is skipped, and the candidate falls through to the offer — disclosed in the PR body, not fixed here.) A lane with a child in flight is filtered out earlier and never reaches this bound at all. Deliberately above IDLE_MIN.",
  },
  {
    name: "SCAN_MAX_AGE_S",
    owners: ["scripts/orchestrator-heartbeat.sh"],
    value: "${SCAN_MAX_AGE_S:-10800}",
    axis: "heartbeat",
    guardedBy: NONE,
    note: "the ask-scan cache's DECLARED absolute freshness ceiling (3 h), the outer bound of the reuse window SCAN_INTERVAL_S (45 min); both are env-overridable. ⚠️ Declared, not read: the only comparison the script performs is `ASK_AGE < SCAN_INTERVAL_S`, and with the shipped defaults that subsumes this value, so a stamp older than 3 h does re-run the scan — by way of the reuse window, not by reading this one. Registering it keeps the declared ceiling in the vocabulary; nothing expands it (filed as a separate defect rather than silently relied on).",
  },
  {
    name: "ASK_AGE",
    owners: ["scripts/orchestrator-heartbeat.sh"],
    value: null,
    axis: "heartbeat",
    guardedBy: NONE,
    note: "DERIVED at runtime: now − the cache stamp, compared against SCAN_INTERVAL_S to decide cache reuse. Registered (not value-pinned) so the reuse decision's age input is in the vocabulary.",
  },
  // — heartbeat axis: the fleet supervisor's component-liveness table
  //   (scripts/lib/fleet-inventory.sh, #2026). These are the bounds a `status`
  //   row calls LATE on: the process is alive and its OWN freshness signal is
  //   older than this, which is the "silently off" state the file exists to
  //   name. Liveness thresholds, not kill switches — nothing here terminates a
  //   process, so they answer to the heartbeat axis.
  //   Only FLEET_HEARTBEAT_LATE_S is name-visible to the reverse scan; its four
  //   siblings are declared in OUT_OF_FAMILY_TERMS for the same reason.
  {
    name: "FLEET_CONTROLLER_LATE_S",
    owners: ["scripts/lib/fleet-inventory.sh"],
    value: "${FLEET_CONTROLLER_LATE_S:-1800}",
    axis: "heartbeat",
    guardedBy: FLEET_SUITE,
    note: "the controller row's freshness bound on `$O/heartbeat`. `orch-loop.sh` sleeps its `CYC` budget (240 s default, minus a jitter share) plus each cycle's own work, so 1800 s of silence is many cycles; the count is deliberately not stated as a NUMBER because a cycle's work is unbounded and nothing pins a multiple. A live controller whose heartbeat is older is WEDGED (alive, dispatching nothing), which is a LATE row, not a healthy one.",
  },
  {
    name: "FLEET_HEARTBEAT_LATE_S",
    owners: ["scripts/lib/fleet-inventory.sh"],
    value: "${FLEET_HEARTBEAT_LATE_S:-2700}",
    axis: "heartbeat",
    guardedBy: FLEET_SUITE,
    note: "the heartbeat-loop row's bound on its own log — ~45 min, about FIVE passes of the loop's own ~9 min total-pass budget (`TARGET=540`; the sleep is target-minus-elapsed, not a fixed interval added on top). Deliberately ABOVE its sibling FLEET_CONTROLLER_LATE_S (1800 s), because a loop a few passes behind is slow, not late. NOT the \"9-11 min pass\" figure `cadence-timer.sh`'s header still quotes from the pre-budget design — that figure is stale, and a bound derived from it would be wrong by minutes. THIS is the term the reverse scan found (the `HEARTBEAT` token makes it in-family), and that finding is what registered the whole table.",
  },
  {
    name: "FLEET_CADENCE_LATE_S",
    owners: ["scripts/lib/fleet-inventory.sh"],
    value: "${FLEET_CADENCE_LATE_S:-1800}",
    axis: "heartbeat",
    guardedBy: FLEET_SUITE,
    note: "the cadence-timer row's bound on `cadence-timer.beat`. At the shipped defaults this is four of the timer's own 450 s intervals (1800 s), but the RELATIONSHIP is not enforced anywhere: `CADENCE_TIMER_INTERVAL` is pinned by no gate and is not its own registry term, so moving that default silently changes the multiplier (300 s → 6x, 600 s → 3x) while every suite stays green. Named here as the unguarded input, the same way the IDLE_MIN note names its downstream divergence rather than asserting a coupling nothing enforces. Reads the timer's OWN beacon, never the sibling heartbeat loop's log (which is appended every pass and masked the one state the row exists for).",
  },
  {
    name: "FLEET_LANDER_BOUND_S",
    owners: ["scripts/lib/fleet-inventory.sh"],
    value: "${FLEET_LANDER_BOUND_S:-9000}",
    axis: "heartbeat",
    guardedBy: FLEET_SUITE,
    note: "a lander's expiry bound: `chain-merge.sh` waits at most 90 min for a PR to exist (90 x a 60 s poll) and then runs the merge, so 150 min is a PLANNING ALLOCATION on top of that wait — NOT the sum of two named bounds. The merge path's own tail (`merge-one.sh`'s 1800 s review bound, plus the rail's re-run fail-safe) is not bounded by the remaining 60 min, so a busy chain-merge can outlive this and read EXPIRED; that direction is deliberate, since over-reporting a busy lander costs a look while under-reporting IS the parked-green-PR state this row exists for. Past it a waiter is EXPIRED, not merely slow. Zero landers is normal (demand-driven), so the failure is an AGE, never an absence.",
  },
  {
    name: "FLEET_JOB_SLACK_S",
    owners: ["scripts/lib/fleet-inventory.sh"],
    value: "${FLEET_JOB_SLACK_S:-300}",
    axis: "heartbeat",
    guardedBy: FLEET_SUITE,
    note: "tolerated scheduling slack added on top of 2× a launchd job's OWN StartInterval before its output counts as stale. Asymmetric on purpose: too small false-flags a correctly-configured job as LATE, too large hides a job that stopped being scheduled.",
  },
  // — hygiene axis (idle reapers that are NOT agent-stall detectors) —
  {
    name: "DEFAULT_IDLE_TIMEOUT_MS",
    owners: ["extensions/mcp-client/index.ts"],
    value: "= 30 * 60 * 1000;",
    axis: "hygiene",
    guardedBy: NONE,
    note: "MCP client idle teardown",
  },
  {
    name: "IDLE_SWEEP_INTERVAL_MS",
    owners: ["extensions/mcp-client/index.ts"],
    value: "= 60 * 1000;",
    axis: "hygiene",
    guardedBy: NONE,
  },
  {
    name: "DEFAULT_HTTP_IDLE_TIMEOUT_MS",
    owners: ["extensions/http-pool-hygiene/pool-hygiene.mjs"],
    value: "= 300_000;",
    axis: "hygiene",
    guardedBy: NONE,
    note: "mirrors pi's own DEFAULT_HTTP_IDLE_TIMEOUT_MS",
  },
  {
    name: "HTTP_IDLE_TIMEOUT_MS",
    owners: ["scripts/check-cost-config.sh"],
    value: "=300000",
    axis: "hygiene",
    guardedBy: "tests/cost-config/run.sh exact-value + derived-window pin",
    note: "the SILENT-HANG ceiling (#1088) — undici's idle timeout, pinned to pi's own 300000 by the #1088 contract; the reverse scan caught this one the moment the branch rebased onto the commit that introduced it",
  },
  {
    name: "DEFAULT_LOCK_AGE_MS",
    owners: ["extensions/shared/branch-ownership.mjs"],
    value: "= 10 * 60_000;",
    axis: "hygiene",
    guardedBy: NONE,
  },
  // — repo-freshness staleness bounds (extensions/repo-freshness.ts) —
  {
    name: "DEFAULT_FRESHNESS_INTERVAL_MS",
    owners: ["extensions/repo-freshness.ts"],
    value: "= 1_200_000;",
    axis: "hygiene",
    guardedBy: NONE,
    note: "staleness bound on the SOURCE TREE, not on agent liveness: the default interval between repo-freshness checks (20 min). Found by the fixed comment stripper — before it, a `/*` inside a line comment in this file hid it from the scan.",
  },
  {
    name: "MIN_FRESHNESS_INTERVAL_MS",
    owners: ["extensions/repo-freshness.ts"],
    value: "= 300_000;",
    axis: "hygiene",
    guardedBy: NONE,
    note: "floor the configured freshness interval is clamped up to (5 min)",
  },
  // — subagent byte-freshness backstop (class 2: value+behaviour pinned) —
  {
    name: "getSubagentBackstopFreshMs",
    owners: ["extensions/subagent/index.ts"],
    value: null,
    axis: "kill",
    guardedBy: SUBAGENT_TEST,
    note: "FUNCTION, not a const: default 60 min, floor 60 s — declared here so the axis is not invisible to the registry",
  },
  {
    name: "getToolStallMs",
    owners: ["extensions/builtin-tools/index.ts"],
    value: null,
    axis: "kill",
    guardedBy: BT_TEST,
    note: "FUNCTION, not a const: the EFFECTIVE tool-stall bound (L) — max(60 s, TASK_TOOL_STALL_MS) when the env override is positive finite, else max(60 s, TASK_TOOL_STALL_FRACTION × effective hard cap). Declared so the env path AND its 60 s safety floor are visible to the registry rather than only the fraction literal.",
  },
  {
    name: "getStreamStallMs",
    owners: ["extensions/builtin-tools/index.ts"],
    value: null,
    axis: "kill",
    guardedBy: BT_TEST,
    note: "FUNCTION, not a const: the EFFECTIVE stream-stall/tool-silence bound (S) — max(60 s, TASK_STREAM_STALL_MS) when the override is a POSITIVE FINITE number, else MAX(60 s, DEFAULT_STREAM_STALL_MS). A non-finite or non-positive override (`Infinity`, `1e400`, `NaN`, `0`, negative) fails CLOSED to the default rather than being clamped up — the same inert-enforcer guard getToolStallMs and getTaskHardCapMs carry, added here in #1030's review cycle 1 (before it, `Number(env) || DEFAULT` let `TASK_STREAM_STALL_MS=Infinity` disarm the silence clauses, and the per-dispatch resolver's own fail-closed fallback inherited that). Registered for the same reason as getToolStallMs: without it the env path and the 60 s floor are invisible and only the literal is recorded.",
  },
  {
    name: "resolveStreamStallMs",
    owners: ["extensions/builtin-tools/index.ts"],
    value: null,
    axis: "kill",
    guardedBy: BT_TEST,
    note: "FUNCTION, not a const: the PER-DISPATCH resolver for S (#1030) — a positive finite override is honoured VERBATIM above a 60 s floor (never load-rescaled, per docs/ops/load-policy.md §3), and every bad shape (Infinity, 1e400, NaN, 0, negative, non-numeric) falls back to getStreamStallMs(). Registered for the same reason as its two sources: this is a THIRD path by which the silence bound moves, and a reader who saw only the env path and the literal would believe S cannot be raised per dispatch. A value at or above the age backstop is WARNED about (streamStallInertWarning), never clamped.",
  },
  {
    name: "getFirstMessageMs",
    owners: ["extensions/builtin-tools/index.ts"],
    value: null,
    axis: "kill",
    guardedBy: BT_TEST,
    note: "FUNCTION, not a const: the EFFECTIVE first-message bound (M) — max(60 s, TASK_FIRST_MESSAGE_MS) when set, else max(60 s, DEFAULT_FIRST_MESSAGE_MS).",
  },
  {
    name: "getFirstOutputTimeoutMs",
    owners: ["extensions/builtin-tools/index.ts"],
    value: null,
    axis: "kill",
    guardedBy: BT_TEST,
    note: "FUNCTION, not a const: the EFFECTIVE tier-1 FIRST-OUTPUT bound (#1073) — max(60 s, TASK_FIRST_OUTPUT_TIMEOUT_MS) when the override is a positive finite number, else 60 s; a non-finite override fails CLOSED to 60 s so `1e400` cannot disarm the zero-output detector. The 60 s default is the literal the getter body carries (pinned against §3 of docs/ops/load-policy.md by load-scale-contract.test.ts); this entry exists so the effective bound is in the vocabulary, like every other env-overridable getter here.",
  },
  {
    name: "getTaskMaxDispatchMs",
    owners: ["extensions/builtin-tools/index.ts"],
    value: null,
    axis: "kill",
    guardedBy: BT_TEST,
    note: "FUNCTION, not a const: the EFFECTIVE total-dispatch cap (D) — max(60 s, TASK_MAX_DISPATCH_MS) when the override is positive finite, else DEFAULT_MAX_DISPATCH_MS = 0, which DISABLES the cap (NOT floored: 0 means off, and the floor only applies to an env-supplied cap).",
  },
  // — kill axis: bounds a DECLARED clause names, whose NAME is out of the
  // reverse scan's family vocabulary (`inFamily` needs a family token or an age
  // suffix). They are registered explicitly so the clause→bound closure test can
  // hold: every bound a clause NAMES must be in this registry. A brand-new
  // out-of-family bound that no clause names is still invisible to the reverse
  // scan — that is the disclosed limit of a name-shaped scan.
  {
    name: "FIRST_OUTPUT_TIMEOUT_MS",
    owners: ["extensions/builtin-tools/index.ts"],
    // #1073 — this used to be the local literal `= 60_000;`. The bound is now
    // READ from the env-aware getter, so the registry records the DERIVATION
    // (that the clause's deadline keeps resolving through the getter, i.e. the
    // documented TASK_FIRST_OUTPUT_TIMEOUT_MS override stays live) rather than
    // a literal the declaration no longer carries. The 60 s number itself is
    // pinned by the getter's own body — builtin-tools.test.ts
    // value+behaviour pin, plus load-scale-contract.test.ts's §3-doc pin — and
    // the effective bound is registered separately as `getFirstOutputTimeoutMs`.
    value: "= getFirstOutputTimeoutMs();",
    axis: "kill",
    guardedBy: BT_TEST,
    note: "the tier-1 FIRST-OUTPUT deadline (zero-output clause), per-dispatch and DERIVED from getFirstOutputTimeoutMs() so TASK_FIRST_OUTPUT_TIMEOUT_MS is live (#1073 — before that wiring the doc named an env var nothing read). Function-local, and its name carries no stall/silence family token, so only the clause→bound closure test plus this entry keep it visible.",
  },
  {
    name: "DEFAULT_HARD_CAP_MS",
    owners: ["extensions/builtin-tools/index.ts"],
    value: "= 21_600_000;",
    axis: "kill",
    guardedBy: BT_TEST,
    note: "6h base of the EFFECTIVE hard cap (TASK_HARD_CAP_MS overrides it, 60 s floor) — the cap the tool-stall (L) derivation multiplies by 2/3.",
  },
  {
    name: "DEFAULT_TOOL_TIMEOUT_S",
    owners: ["extensions/task-heartbeat.ts"],
    value: "= 7200;",
    axis: "kill",
    guardedBy: BT_TEST,
    note: "#1500 Leg B: the default wall-clock bound on a DISPATCHED child's `bash` call, filled in by the `tool_call` handler only when the caller supplied no `timeout`. Derived from the measured completed-call tail (max 5417.8 s over 658,981 calls; 0 > 7200 s) — deliberately NOT from the killed population, which is absent from a completed-call corpus by construction.",
  },
  {
    name: "getToolTimeoutSeconds",
    owners: ["extensions/task-heartbeat.ts"],
    value: null,
    axis: "kill",
    guardedBy: BT_TEST,
    note: "FUNCTION, not a const: env override TASK_TOOL_TIMEOUT_S — absent → DEFAULT_TOOL_TIMEOUT_S (7200 s); non-positive / non-finite / unparseable → null = DISARMED, with a once-only warning from toolTimeoutDisarmWarning; a finite positive value is CLAMPED to floor(2147483647/1000) s so pi's own resolveTimeoutMs does not reject the call (`Invalid timeout: maximum is 2147483.647 seconds`) rather than letting a Node timer overflow. Mirrors getToolStallMs.",
  },
  {
    name: "DEFAULT_MAX_DISPATCH_MS",
    owners: ["extensions/builtin-tools/index.ts"],
    value: "= 0;",
    axis: "kill",
    guardedBy: NONE,
    note: "0 = the max-dispatch cap is OFF unless TASK_MAX_DISPATCH_MS supplies a positive finite value. Pinned by the registry's forward assertion (BT_TEST pins the getter's behaviour with a literal, not this constant).",
  },
  {
    name: "getEffectiveCutGapMs",
    owners: ["extensions/builtin-tools/index.ts"],
    value: null,
    axis: "kill",
    guardedBy: BT_TEST,
    note: "FUNCTION, not a const: the EFFECTIVE cut deadline the parser actually uses — getCutGapMs() scaled by system load (1×/2×/3× bands via loadScaledBound) and latched per dispatch. Registered separately from getCutGapMs because the runtime reads this one; recording only the base would record a bound up to 3× smaller than the effective one.",
  },
  {
    name: "getTaskBackstopMs",
    owners: ["extensions/builtin-tools/index.ts"],
    value: null,
    axis: "kill",
    guardedBy: BT_TEST,
    note: "FUNCTION, not a const: the parent's detector-dead backstop (23.4 h default = DEFAULT_TOOL_STALL_MS + DEFAULT_BACKSTOP_MARGIN_MS), TASK_BACKSTOP_MS override, 0 = OFF explicitly. Out-of-family name, so only this entry keeps it visible.",
  },
  {
    name: "getCutGapMs",
    owners: ["extensions/builtin-tools/index.ts"],
    value: null,
    axis: "kill",
    guardedBy: BT_TEST,
    note: "FUNCTION, not a const: the cut clause's marker-gap deadline — 1.25× the tick interval from getHeartbeatIntervalMs, 15 s floor, TASK_HEARTBEAT_CUT_GAP_MS override.",
  },
  {
    name: "DEFAULT_CPU_STALL_MS",
    owners: ["extensions/builtin-tools/index.ts"],
    value: "= 1_800_000;",
    axis: "kill",
    guardedBy: BT_TEST,
    note: "#928 (C) — the shipped CPU-stall bound of the `tool-dead` clause: 30 min of flat CPU, admitted ONLY for a tool that has DEMONSTRATED CPU work this round (`cpu_advanced`) and is silent past S. The EFFECTIVE bound is resolved by getCpuStallMs (env override, 60 s floor, 0 = OFF). Calibrated to cover a tool that burned CPU and is now blocked on I/O, without re-creating the #363/#489 kill-productive-agents class.",
  },
  {
    name: "getCpuStallMs",
    owners: ["extensions/builtin-tools/index.ts"],
    value: null,
    axis: "kill",
    guardedBy: BT_TEST,
    note: "FUNCTION, not a const: the EFFECTIVE `tool-dead` CPU-stall bound (C) — max(60 s, TASK_CPU_STALL_MS) when the override is a positive finite number; the VALUE 0 disables the clause outright; blank/whitespace/negative/non-finite fall back to DEFAULT_CPU_STALL_MS so a launcher typo cannot silently disarm a kill path. Registered separately from the literal for the same reason as its siblings: without it the env path, its 60 s floor and its off switch are invisible to the registry.",
  },
  {
    name: "DEFAULT_PROGRESS_AGE_MS",
    owners: ["extensions/builtin-tools/index.ts"],
    value: "= 2_700_000;",
    axis: "kill",
    guardedBy: BT_TEST,
    note: "#5195 (X) — the shipped bound of the `no-progress` clause, and the ONLY bound in the family keyed on PROGRESS rather than liveness: 45 min with no COMPLETED unit of work (`tool_end`) or content-grounded child progress (`progress=1`) while no tool is in flight. Deliberately NOT load-scaled and NOT latched — a bound that WIDENS is how the class this clause catches (`#363` hard cap 2h→6h, `ea22897` making S per-dispatch) escaped every other clause. The EFFECTIVE bound is resolved by getProgressAgeMs (env override; 0 = OFF; floored at the REPORTING CADENCE, `max(60 s, 3 x the heartbeat interval)`, because the parent can only see progress when the child reports it). 45 min is the repo's own declared ceiling for the child's retry/hang window (`HANG_WINDOW_CEILING_MS = 2700000` in scripts/check-cost-config.sh:198; docs/ops/cost-config-policy.md:102-103 derives the real 43.0 min window and requires it <= that ceiling) — set BELOW it, X would pre-empt a chattering retrying child's own bounded visible recovery. Still ~8x below the 6h hard-cap backstop.",
  },
  {
    name: "getProgressAgeMs",
    owners: ["extensions/builtin-tools/index.ts"],
    value: null,
    axis: "kill",
    guardedBy: BT_TEST,
    note: "FUNCTION, not a const: the EFFECTIVE `no-progress` bound (X) — max(reporting-cadence floor, TASK_PROGRESS_AGE_MS) when the override is a positive finite number; the VALUE 0 disables the clause outright; blank/whitespace/negative/non-finite fall back to DEFAULT_PROGRESS_AGE_MS, so a launcher typo cannot silently disarm the one clause that bounds the content-free-loop class. The floor is the REPORTING CADENCE — `max(60 s, 3 x the effective heartbeat interval)` — NOT a bare 60 s: the parent can only see progress when the child reports it, so a bound below the cadence fires before the evidence it waits for and would cut a genuinely progressing content-only child (TASK_PROGRESS_AGE_MS=60000 with a 300 s interval is the worked case; caught in review). Registered separately from the literal for the same reason as its siblings: otherwise the env path, its floor and its off switch are invisible to the registry.",
  },
  // — reap axis: the cloud cell's reclaim AGE FLOORS —
  // #2850 landed the pre-dispatch disk floor, #2756 the worktree reaper decision and #2868/#2870 the
  // lane test-DB container reaper. All three introduced age floors the reverse scan reads and none
  // registered them, so `reverseViolations` went RED on main and stayed red for every PR whose base
  // carried them (measured 2026-10-27: identical FOUR violations on #2751 and #2851, two unrelated
  // diffs — three before #2870 landed, four after).
  // Registered here rather than exempted: these ARE stall/reclaim bounds and a value change must be
  // visible. Note HOW the scan reaches them: none carries a SCAN_NAME_FAMILIES token, so they are
  // caught by their AGE SHAPE (`_AGE_S`/`_AGE` suffix) through `inFamily`'s first branch — which is
  // why they were invisible to a reader looking for a family token and can never be invisible to the
  // scan.
  // ⚠️ THE `value` FRAGMENT PINS ONLY THE DEFAULT LITERAL. It does not model the env seam or the
  // coercion: `="$(echo 86400)"` or `="$(disk_floor_num "" 86400)"` would still carry it while
  // destroying the override. Those two properties are pinned by the `guardedBy` polarities below,
  // not here — the split is deliberate, and each half is claimed only where it is enforced.
  {
    name: "DISK_FLOOR_COPY_MIN_AGE_S",
    owners: ["scripts/orchestrator-harness/disk-floor.sh"],
    value: "86400",
    axis: "reap",
    guardedBy: "scripts/orchestrator-harness/disk-floor.test.sh — the age-seam polarities (genuinely unset, set-but-empty, unusable, literal 0, leading-zero 0400, valid override)",
    note: "age floor for the STALE-COPY class inside disk_floor_num(): the 86400 in the declaration line IS the default, and it is what makes a copy eligible for reclaim. `value` here is a bare fragment because a syntax-bearing one (`86400)`) false-alarms on a pure reformat — the registry's contract is that formatting stays free while the bound does not. Env-overridable; a non-numeric or leading-zero value falls back to the default rather than to 0, because a 0 age floor would make every copy instantly reclaimable.",
  },
  {
    name: "DISK_FLOOR_SCRATCH_MIN_AGE_S",
    owners: ["scripts/orchestrator-harness/disk-floor.sh"],
    value: "86400",
    axis: "reap",
    guardedBy: "scripts/orchestrator-harness/disk-floor.test.sh — the age-seam polarities (genuinely unset, set-but-empty, unusable, literal 0, leading-zero 0400, valid override)",
    note: "age floor for the LANE-SCRATCH class, resolved by the same disk_floor_num() coercion and therefore with the same never-0 contract. Kept a separate term from the stale-copy floor above because the two classes are reclaimed by different sweeps (`disk_floor_reclaim_copies` vs `disk_floor_reclaim_scratch`) and one can move without the other.",
  },
  {
    name: "REAP_WT_MIN_AGE_MINUTES",
    owners: ["scripts/pi-reap-worktrees.sh"],
    value: "${REAP_WT_MIN_AGE_MINUTES:-45}",
    axis: "reap",
    guardedBy: "scripts/pi-reap-worktrees.test.sh G6e + G6f (rule 7, too-young)",
    note: "the reaper's too-young rule: NOTHING younger than this is removable, whatever else the rules say. It is the one clause that protects work a lane is actively writing, so it outranks the merged/aged/classification rules rather than being weighed beside them (#2756). NOTE the citation is deliberately only pi-reap-worktrees.test.sh: scripts/disk-reaper.test.sh:170 sets REAP_WT_MIN_AGE_MINUTES=0 in its own wrapper, i.e. it DISABLES rule 7 so its fixtures are not gated by it — it neither pins the 45 nor the behaviour, and citing it here would be a guard claim that reads backwards.",
  },
  {
    name: "MIN_AGE",
    owners: ["scripts/orchestrator-harness/lane-container-reap.sh"],
    value: "${LANE_CONTAINER_MIN_AGE:-14400}",
    overrides: ['--min-age) MIN_AGE="${2:-$MIN_AGE}"'],
    axis: "reap",
    guardedBy: "scripts/orchestrator-harness/lane-container-reap.test.sh — case B keeps a container YOUNGER than the floor and case A reaps one past it (the too-young rule, not the default value; the default is pinned by `value` above)",
    note: "#2868/#2870 lane test-DB containers: a container younger than four hours is never reaped, which is what stops the sweep from killing a test database a lane is still using. The bare name `MIN_AGE` is in-family by SHAPE, and registering it makes the gate STRICTER, not blind: `reverseViolations` matches name AND owner, so a future script reusing the bare name fails the reverse scan by design — the correct fix then is to rename that declaration (`X_MIN_AGE`, as `CR_MIN_AGE`/`VENV_MIN_AGE` already do), NOT to add the new file to this term's owners, which would demand it carry this exact default and declaration count.",
  },
  // — the #1881 fix lane: three MORE reverse-scan reds inherited from main —
  // Measured 2026-10-29 at `890544aff` (the #1881 head, whose base carried them): `verify` went RED
  // with FOUR violations — `IDLE_S`, `MIN_SESSION_AGE_S` and `TRIGGER_BACKSTOP_S` in two files — all
  // of them byte-identical to `origin/main`, i.e. unattributable to the diff that inherited them and
  // red for every PR cut from that base. Registered, not exempted: each IS a liveness/stall bound
  // whose value a change must be visible on. HOW the scan reaches them differs, and that is the point
  // of recording them here — `IDLE_S` carries a family token (`IDLE`) plus a bound suffix, while
  // `MIN_SESSION_AGE_S` and `TRIGGER_BACKSTOP_S` are caught by SHAPE (`_AGE_S`) and by
  // `BACKSTOP`+`_S`, so none of the three can be found by grepping for the family alone.
  {
    name: "TRIGGER_BACKSTOP_S",
    owners: ["scripts/install-repair-service.sh", "scripts/pr-repair-loop.sh"],
    value: "REPAIR_TRIGGER_BACKSTOP_S:-1800",
    axis: "gate",
    guardedBy: NONE,
    note: "the repair actuator's BACKSTOP: the demoted timer that fires a `--trigger` pass when the event-driven front end has not run for 30 minutes (#2732). Both owners declare it from ONE env var with the same default — the installer writes the systemd unit that sets the timer, and the loop reads it — so they are registered as co-owners rather than exempted as a duplicate: a divergence between them is exactly the drift the reverse scan exists to catch. Registered rather than exempted because a 0 here would make the backstop fire continuously and a huge value would retire the sweep silently. DISCLOSED, not modelled: `scripts/pr-doctor-trigger.py:257` holds a THIRD copy of the number as the `--backstop` argparse default, and the declaration scan cannot see it AT ALL — its corpus is `extensions/**/*.{ts,mjs}` plus `scripts/**/*.{sh,ts,mjs}` (`stallScanFiles`), so no Python declaration is ever read, in any form (`BACKSTOP_S = 1800` would be equally invisible); the loop always passes the value explicitly, so a drift there is observable only when something runs the trigger without a backstop.",
  },
  {
    name: "IDLE_S",
    owners: ["scripts/orchestrator-harness/lane-bound.sh"],
    value: "IDLE_S=\"\"",
    overrides: ['IDLE_S="$2"', 'IDLE_S="$(num_or "${LANE_BOUND_IDLE_S:-}" 1200)"'],
    axis: "kill",
    guardedBy: NONE,
    note: "lane-bound's idle bound — the `stalled` clause that kills a lane whose output has not grown and whose CPU has not advanced for this long. THREE declaration lines, and the REGISTERED DEFAULT IS THE THIRD: the first is the empty initializer (kept first so `-n` can distinguish \"unset by any seam\" from \"explicitly empty\"), the second is the `--idle` CLI override, and the third resolves the env seam `LANE_BOUND_IDLE_S` against the 1200 s literal — which is why `value` pins the initializer and the two seams are recorded as overrides. `guardedBy: NONE` is deliberate and not a gap: the CLI/env seam is exercised by the lane-bound suite through its ENV spelling (`LANE_BOUND_IDLE_S=2`), which never mentions the bare symbol, so citing that file here would be the exact misattribution the citation test refuses. The literals and the declaration count are pinned by this registry's forward check.",
  },
  {
    name: "MIN_SESSION_AGE_S",
    owners: ["scripts/orchestrator-harness/orphaned-harness.sh"],
    value: "MIN_SESSION_AGE_S:-600",
    axis: "reap",
    guardedBy:
      "scripts/orchestrator-harness/orphaned-harness.test.sh — OH1/OH2 (a dead harness lane PAST the floor is named with its PR; a live one is not), OH8 (a just-spawned session with no `pi` descendant YET is NOT named — the too-young direction, which NOTHING drove before: `NEW` was computed and documented 'must NOT be named' from the day the suite landed, so a floor lowered to 0 stayed GREEN), and OH9 (a session armed at `NOW - 300` is NOT named, so any floor lowered to five minutes or less is caught — because the comparison is `-ge`, a 300 s floor names it and OH9 reds; the report reads its own clock at read time, so what it sees is `300 + elapsed` and a 301 s floor reds OH9 as soon as one second has elapsed rather than leaving it reliably green). What the three cases do NOT pin is the exact `600`: OH8 and OH1 bracket it by a factor of 200 and OH9 pins only its magnitude, so the exact value is pinned by `value` above, in the `MIN_AGE` row's precedent, and NOT by a boundary case — the report reads the wall clock, so a fixture 599 s old is 600 s old one second later and cannot pin an integer boundary without making the suite flaky. The two MUTANTS: M1 deletes the `dead && age >= floor` clause and turns OH1 RED; M3 replaces the floor OPERAND with a literal past every fixture and turns OH1 RED with the clause intact — i.e. M3 pins the COMPARISON, not the default's value, and is not a `Constant Replacement` mutant.",
    note: "the orphan REPORT's AGE FLOOR: a harness session whose panes hold NO live `pi` descendant is 'dead', and naming requires BOTH that AND age >= the floor. A worker that has just been spawned holds no `pi` YET, so without this floor a lane would be reported as an orphan during its LAUNCH window — from spawn until the agent exists, which is short but is not the floor's business — and the report would be unreadable exactly when an operator is hunting the real ones. The 600 s is a GRACE, not the length of that exposure: a lane that HOLDS a live `pi` is never named at any age (OH2's 1000 s-old live session is not named), so the coverage the floor actually adds past the launch window is a session whose agent has already exited — genuinely dead, merely between incarnations. It decides REPORTABILITY only, and the script is READ-ONLY (`orphaned-harness.sh` stops nothing, kills nothing, deletes nothing). ⚠️ NO ACTUATOR CONSUMES THIS FLOOR TODAY, stated so the row does not read as remediated: `scripts/orphan-reap.py` reaps a different class (ppid-1 test/tooling orphans) and its gate 2 lists `tmux` among the KEEP-HUMAN ancestors, so it refuses a dead `merge-*` session outright and never touches the unit surface at all, and nothing else reads this report's output. A 0 here therefore names a freshly-spawned lane during its launch window; it does not cause any reaping. Caught by the reverse scan by SHAPE (`_AGE_S`) — the name carries no family token. The age is the session's own `session_created` delta, so an UNREADABLE age is 'cannot tell' and is never named — the absence of a reading is not a verdict.",
  },
];

/**
 * Explicit carve-outs from the reverse scan. Each MUST carry a substantive
 * rationale: the point of the exemption list is that a reader can see WHY a
 * family-matching identifier is not a stall bound.
 */
export const STALL_SCAN_EXEMPTIONS: readonly Exemption[] = [
  {
    symbol: "EDGE_REAP_MS",
    rationale:
      "live e2e harness socket-close delay in a load-balancer test script, not a session-liveness bound",
    owner: "#1068",
  },
  {
    symbol: "CR_AGE",
    rationale:
      "a MEASURED age in seconds (the claim commit's own %ct subtracted from now), never a bound: the `_AGE` suffix rule matches the accumulator's initializer line, but the value is read from the claim commit and compared against the registered CR_MIN_AGE floor. Registering it as a term would put a measurement in a vocabulary of bounds",
    owner: "#2246",
  },
  {
    symbol: "CIQ_AGE",
    rationale:
      "a MEASURED age in seconds — how old the cached CI-queue reading is (0 on a fresh read, the record's own `at=` delta on a cache hit) — printed in the verdict token so an operator can judge it. It is never a bound: the freshness DECISION is `CIQ_STALE_MAX`/`CIQ_TTL`, and the age is compared against them, not used as one. The `_AGE` suffix rule matches its initializer/assignment lines. Registering it as a term would put a measurement in a vocabulary of bounds, exactly as CR_AGE is exempted (#2333 review)",
    owner: "#2426",
  },
  {
    symbol: "LANE_ARM_SNAPSHOT_AGE",
    rationale:
      "a MEASURED age in seconds — the wall time a lane-arm pass spent obtaining its own sample, exported to the queue renderer and stamped into the queue header as `snapshot_age=<N>s` so a reader can judge the datum's currency. It is never a bound: the freshness DECISION is LANE_ARM_SNAPSHOT_MAX_AGE (registered on its own row above), and this age is what that bound is COMPARED AGAINST. The `_AGE` suffix rule matches the `export LANE_ARM_SNAPSHOT_AGE` line. Registering it as a term would put a measurement in a vocabulary of bounds, exactly as CR_AGE and CIQ_AGE are exempted — the failure this exemption guards against is a stamp that reads zero seconds on every row because it was arithmetic rather than a measurement, which is fixed by measuring it, never by registering it",
    owner: "#1567",
  },
  {
    symbol: "DEFAULT_TASK_RUNS_MAX_AGE_MS",
    rationale:
      "durable task-run RECORD retention age (7 days) in shared/task-runs.ts — a disk-retention backstop for the run-record/log tree, not a session or child liveness bound (the byte cap binds first in practice); paired with the live-pid / settle-grace guard so it never evicts an in-flight lane",
    owner: "#1662",
  },
];

// ── scan specification ──────────────────────────────────────────────────────

/**
 * Name families whose bounds belong in the registry. `REAP` is included because
 * the fleet reaper's staleness bounds are stall terms in the issue's own
 * vocabulary; the `boundSuffixes` shape rule is what keeps the worktree
 * reaper's subprocess timeouts (`REAP_WT_*_TIMEOUT`) out.
 */
export const SCAN_NAME_FAMILIES = [
  "STALL",
  "SILENCE",
  "IDLE",
  "STUCK",
  "REAP",
  "FRESH",
  "BACKSTOP",
  "FIRST_MESSAGE",
  "HEARTBEAT",
] as const;

/** Bound shapes — a family token alone is not enough (see `inFamily`). */
export const SCAN_BOUND_SUFFIXES = [
  "_MS",
  "_S",
  "_SEC",
  "_SECONDS",
  // The orphan reaper's active-CPU floor is measured in CENTISECONDS (`ps -o
  // time` resolution); without this the reverse name scan could not see it at
  // all (#1863 F9).
  "_CENTISECONDS",
  "_MIN",
  "_MINUTES",
  "_HOURS",
  "_DAYS",
  "_THRESHOLD",
  "_FRACTION",
  "_RATIO",
] as const;

/** Age-shaped bounds carry no family token at all (`MAX_AGE`, `MAX_AGE_DAYS`). */
export const SCAN_AGE_SUFFIXES = ["_AGE", "_AGE_MS", "_AGE_S", "_AGE_HOURS", "_AGE_DAYS"] as const;

/** Files the registry is asserted over. Excludes tests — they are not producers. */
export function stallScanFiles(root: string, errors?: string[]): string[] {
  const isTest = (n: string) => /\.test\./i.test(n) || /^test-/i.test(n);
  return [
    ...collectFiles(root, "extensions", (n) => /\.(ts|mjs)$/.test(n) && !isTest(n), 6, errors),
    ...collectFiles(root, "scripts", (n) => /\.(sh|ts|mjs)$/.test(n) && !isTest(n), 6, errors),
  ];
}

/** The scan spec consumed by the registry test. */
export function stallScanSpec(root: string): ScanSpec {
  const walkErrors: string[] = [];
  return {
    files: stallScanFiles(root, walkErrors),
    families: SCAN_NAME_FAMILIES,
    boundSuffixes: SCAN_BOUND_SUFFIXES,
    ageSuffixes: SCAN_AGE_SUFFIXES,
    walkErrors,
  };
}

/** Repo root from a module-relative path. */
export function repoRoot(moduleDir: string): string {
  return path.resolve(moduleDir, "../..");
}
