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
  "getTaskBackstopMs",
  "FIRST_OUTPUT_TIMEOUT_MS",
  "DEFAULT_HARD_CAP_MS",
  "DEFAULT_MAX_DISPATCH_MS",
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

/** Every child-registered pi event (activity + lifecycle). */
export function childRegisteredEvents(): string[] {
  return [...ACTIVITY_EDGE_EVENTS, ...LIFECYCLE_EVENTS];
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
  "tool-stall",
  "first-message-stall",
  "max-dispatch",
  "cut",
] as const;

export type HeartbeatKillReasonName = (typeof HEARTBEAT_KILL_REASONS)[number];

/** clause → the bound constant that gates it. */
export const KILL_REASON_BOUNDS: Readonly<Record<HeartbeatKillReasonName, string>> = {
  "zero-output": "FIRST_OUTPUT_TIMEOUT_MS — the tier-1 deadline that populates the entry's `firstOutputTimeoutMs`",
  "silence-threshold": "HEARTBEAT_TIMEOUT_MS (T)",
  "stream-stall": "max(60 s, TASK_STREAM_STALL_MS) override (env), else max(60 s, DEFAULT_STREAM_STALL_MS) (S) — resolvable PER DISPATCH from the task tool's stream_stall_ms arg (#1030) via resolveStreamStallMs, 60 s floor on every path",
  // Shares S with stream-stall: one constant, two conditions. Naming them as one
  // term would be wrong; naming them as two unrelated bounds would be wrong too.
  "tool-silence": "max(60 s, TASK_STREAM_STALL_MS) override (env), else max(60 s, DEFAULT_STREAM_STALL_MS) (S) — same bound as stream-stall, different condition; the dispatch override (stream_stall_ms, #1030) moves this clause too",
  // The EFFECTIVE bound is max(60 s, TASK_TOOL_STALL_MS) when the env override
  // is a positive finite number; otherwise max(60 s, fraction × cap). Recording
  // only the fraction would let the bound move through a path the registry
  // cannot see, and omitting the 60 s floor would record a bound that does not
  // exist (#1068 review; the same shape PR #873 / #991 caught).
  "tool-stall": "max(60 s, TASK_TOOL_STALL_MS) override (env), else max(60 s, TASK_TOOL_STALL_FRACTION × effective hard cap from DEFAULT_HARD_CAP_MS) (L) — floored further by HEARTBEAT_TIMEOUT_MS while no turn is active",
  "first-message-stall": "max(60 s, TASK_FIRST_MESSAGE_MS) override (env), else max(60 s, DEFAULT_FIRST_MESSAGE_MS) (M) — then load-scaled and latched at the dispatch site",
  "max-dispatch": "max(60 s, TASK_MAX_DISPATCH_MS) override (env), else OFF — DEFAULT_MAX_DISPATCH_MS = 0 disables the cap (D)",
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
    note: "S — gates BOTH stream-stall and tool-silence; the EFFECTIVE bound is resolved by getStreamStallMs (env override, 60 s floor), or PER DISPATCH by resolveStreamStallMs (#1030)",
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
    name: "RERUN_STALL_SECONDS",
    owners: ["scripts/admin-merge.sh"],
    value: "${ADMIN_MERGE_STALL_SECONDS:-600}",
    axis: "gate",
    guardedBy: NONE,
    note: "the merge gate's re-run progress window (#3756): a main-lane re-run whose status never reaches completed AND whose updatedAt never moves for this long is STALLED and the gate refuses the merge. A still-running job is NOT a failure — only a STALL is. The value is an env seam for tests only (ADMIN_MERGE_STALL_SECONDS); the shipped default is 600 s.",
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
  {
    name: "MAX_AGE",
    owners: ["scripts/monitor-worker.sh"],
    value: "${2:-60}",
    axis: "reap",
    guardedBy: NONE,
    note: "worker-log freshness bound — an AGED, not family-named, bound",
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
    note: "FUNCTION, not a const: the EFFECTIVE stream-stall/tool-silence bound (S) — max(60 s, TASK_STREAM_STALL_MS) when the override is set, else max(60 s, DEFAULT_STREAM_STALL_MS). Registered for the same reason as getToolStallMs: without it the env path and the 60 s floor are invisible and only the literal is recorded.",
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
