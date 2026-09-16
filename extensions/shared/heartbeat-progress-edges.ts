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
 * Registered terms whose NAMES are not in-family (camelCase function names, not
 * `FAMILY_TOKEN_MS`), so `scanDeclarations` never sees them — and therefore
 * neither the reverse check nor the owners check can cover them. Listed
 * explicitly so a NEW non-in-family term FAILS the registry test instead of
 * silently escaping both directions, and so a reader can see which terms rest on
 * their own value+behaviour pin (`guardedBy`) for the duplicate-declaration case.
 */
export const FUNCTION_SHAPED_TERMS = ["getSubagentBackstopFreshMs", "getToolStallMs"] as const;

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
  "zero-output": "first-output timeout (`firstOutputTimeoutMs`, tier-1)",
  "silence-threshold": "HEARTBEAT_TIMEOUT_MS (T)",
  "stream-stall": "DEFAULT_STREAM_STALL_MS (S)",
  // Shares S with stream-stall: one constant, two conditions. Naming them as one
  // term would be wrong; naming them as two unrelated bounds would be wrong too.
  "tool-silence": "DEFAULT_STREAM_STALL_MS (S) — same bound as stream-stall, different condition",
  // The EFFECTIVE bound is max(60 s, TASK_TOOL_STALL_MS) when the env override
  // is a positive finite number; otherwise max(60 s, fraction × cap). Recording
  // only the fraction would let the bound move through a path the registry
  // cannot see, and omitting the 60 s floor would record a bound that does not
  // exist (#1068 review; the same shape PR #873 / #991 caught).
  "tool-stall": "max(60 s, TASK_TOOL_STALL_MS) override (env), else max(60 s, TASK_TOOL_STALL_FRACTION × effective hard cap) (L)",
  "first-message-stall": "DEFAULT_FIRST_MESSAGE_MS (M)",
  "max-dispatch": "TASK_MAX_DISPATCH_MS",
  cut: "getCutGapMs() / TASK_HEARTBEAT_CUT_GAP_MS",
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
 * Every stall / liveness / staleness bound in the repo, with its owner file(s),
 * the fragment of its declaration line that carries the value, and who guards
 * it TODAY. `value: null` means the value is not a local literal: a POINTER to
 * another guard, DERIVED from other bounds, or resolved by a FUNCTION (an env
 * override). Its presence is still asserted, in declaration shape.
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
    note: "S — gates BOTH stream-stall and tool-silence",
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
    note: "M — before #1068 only self-compared, so any value passed",
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
  // — reap axis (interactive session reaper) —
  {
    name: "REAP_IDLE_HOURS",
    owners: ["scripts/pi-reap-idle.sh"],
    value: "${REAP_IDLE_HOURS:-24}",
    axis: "reap",
    guardedBy: NONE,
  },
  {
    name: "REAP_STUCK_HOURS",
    owners: ["scripts/pi-reap-idle.sh"],
    value: null,
    axis: "reap",
    guardedBy: NONE,
    note: "DERIVED: defaults to 3× REAP_IDLE_HOURS, resolved at runtime",
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
  },
  {
    name: "REAP_WT_AGED_DAYS",
    owners: ["scripts/pi-reap-worktrees.sh"],
    value: "${REAP_WT_AGED_DAYS:-7}",
    axis: "retention",
    guardedBy: NONE,
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
