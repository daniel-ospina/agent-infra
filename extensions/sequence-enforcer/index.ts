// sequence-enforcer — blocks tool calls that violate skill step sequences.
// Epics #6944/#6948. Hooks tool_call, validates against YAML step declarations.
// 3 modes: warn (log) | gate (block destructive) | strict (block all non-expected).
// Kill switch: /tmp/agent-state-machine.kill or AGENT_STATE_MACHINE env var.
//
// ── WHY THIS EXISTS (READ BEFORE DISABLING) ──
// Workflow enforcement is the CORE of our agent system, not a hindrance.
// Every skill defines a step sequence (scope → plan → implement → verify with
// gates). Agents that skip steps introduced real bugs that human time had to
// fix. This enforcer exists to make skipping impossible — it is INTENTIONAL.
//
// It is designed to apply to BOTH top-level agents AND nested sub-agents.
// Sub-agents dispatched via task() inherit the same enforcement because they
// do the same work and are held to the same standard. Do NOT disable this for
// sub-agents to "fix" timeouts — that removes workflow enforcement and lets
// lazy agents bypass gates. Fix the root cause instead (gate-advance logic,
// timeout mismatches, untimed git calls).
// #201 carve-out (HISTORICAL — REVERSED by #357, see below): launcher-marked
// print sessions default to mode "warn" — verifier gates that require a task
// dispatch are structurally unresolvable in background workers, and the old
// timeout POP destroyed stage state. warn still counts reviewer dispatches
// and advances steps; the override escape hatches (AGENT_SEQUENCE_MODE /
// ELDATO_SEQUENCE_MODE / PI_ENFORCER_MODE / mode file) force gate/strict
// anywhere, including print. Interactive sessions are unchanged.
// #357 (Task 4): the carve-out is REVERSED — ALL `pi -p` sessions (env- OR
// argv-detected) default to warn. The checkpoint step-gate (#5039) is
// unsatisfiable AND inescapable in the bare-shell class (118/118 production
// blocks; a gate-mode worker at a checkpoint has no in-session escape).
// resolveMode uses isPrintMode(env, argv); explicit overrides still win.
//
// If a sub-agent appears stuck at a verifier gate, the bug is in gate
// advancement or the silence threshold vs provider timeout — not the
// enforcement itself.
//
// #201/#357 (print-mode default): in non-interactive `pi -p` sessions
// (epic-executor sub-agents, background workers) the DEFAULT mode is `warn`
// (never blocks). #357 (Task 4) widened the detection from PI_MODE env to
// argv (bare-shell `pi -p` with no PI_MODE included) — the checkpoint gate
// deadlock evidence (118/118 blocks) reversed the #201 carve-out. Explicit
// AGENT_SEQUENCE_MODE / PI_ENFORCER_MODE / mode-file overrides still force
// gate/strict in print; warn still tracks + advances + audits
// (warn_blocked, timeout_park). See skills/enforcement/SKILL.md.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { homedir } from "node:os";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync, appendFileSync, mkdirSync, unlinkSync, renameSync } from "node:fs";
import { resolve, join, dirname } from "node:path";
import { isIP } from "node:net"; // #383 (Task 3, P3-1 FINAL mechanical): true IPv6 mirror — zero-dep builtin
import { isPrintMode, isPrintModeEnv } from "../shared/print-mode.js";

// #357 (Task 1): inline copy of pi's `isToolCallEventType` — the suite runs in
// CI with ZERO node_modules (zero-dep route), so the runtime value import from
// @earendil-works/pi-coding-agent was replaced. Verified against the pi dist:
//   dist/core/extensions/types.js:45 `return event.toolName === toolName`
//   (pi-node v22.23.2-darwin-arm64 @earendil-works/pi-coding-agent). Drift guard:
//   if a pi upgrade changes this predicate, catch it in Task 13's audit window
//   (the only place the dep IS available) — the suite exercises only this copy.
function isToolCallEventType(toolName: string, event: unknown): boolean {
  return (event as { toolName?: unknown })?.toolName === toolName;
}

// Dual-support: check AGENT_* first, then ELDATO_* (Phase 1 — #7549)
function _getEnv(name: string): string | undefined {
  return process.env[`AGENT_${name}`] ?? process.env[`ELDATO_${name}`];
}
// Namespaced files (Phase 1 — #7549)
const KILL_SWITCH_FILE = "/tmp/agent-state-machine.kill";
const MODE_FILE = "/tmp/agent-sequence-mode";

// ── Types ────────────────────────────────────────────

export interface Step {
  name: string;
  type: string;
  skill: string;
  requires: string[];
  produces: string[];
  gate: string;
  retry: number;
  timeout_seconds: number;
  token_phase: string;
}

type Mode = "warn" | "gate" | "strict";

// ── Loop bridge (#7040) ────────────────────────────

let BRIDGE_DIR = join(homedir(), ".pi", "agent", "bridge");
let BRIDGE_FILE = join(BRIDGE_DIR, "loop-sequence.json");
// Test seam: redirect bridge writes away from the real ~/.pi bridge during
// unit tests (honored only under NODE_ENV=test, mirrors review-enforcer).
export function _setBridgeDirForTest(dir: string): void {
  if (process.env.NODE_ENV !== "test") return;
  BRIDGE_DIR = dir;
  BRIDGE_FILE = join(dir, "loop-sequence.json");
}

function writeBridgeState() {
  const top = topSkill();
  if (!top) return;
  const step = top.steps[top.stepIndex];
  // P2-3: guard against OOB stepIndex
  if (!step) return;
  try {
    mkdirSync(BRIDGE_DIR, { recursive: true });
    const payload = JSON.stringify({
      skill: top.path,
      stepIndex: top.stepIndex,
      stepCount: top.steps.length,
      stepName: step.name ?? null,
      gate: step.gate ?? "auto",
      startedAt: new Date(top.stepStartedAt).toISOString(),
      // ponytail: store startedAt only — loop-enforcer computes elapsed on read (P2-1)
      updatedAt: new Date().toISOString(),
    });
    // P0-1: atomic write via temp + rename to prevent truncated reads
    const tmp = BRIDGE_FILE + ".tmp";
    writeFileSync(tmp, payload);
    renameSync(tmp, BRIDGE_FILE);
  } catch (e) {
    console.log("[sequence-enforcer] bridge write failed:", (e as Error).message);
  }
}

function clearBridgeState() {
  try { if (existsSync(BRIDGE_FILE)) unlinkSync(BRIDGE_FILE); } catch { /* best-effort */ }
}

// ── State ────────────────────────────────────────────
// ponytail: skill stack replaces single activeSkill (#7265).
// Sub-skill reads during verifier gates push onto stack instead of
// replacing the parent, preserving dispatchedReviewers counters.
// When a skill completes all steps, it's popped to restore parent.

interface SkillState {
  path: string;
  steps: Step[];
  stepIndex: number;
  stepStartedAt: number;
  reviewers: Map<number, number>; // dispatched reviewer count per step
}

const stepCache = new Map<string, Step[] | null>();
let skillStack: SkillState[] = [];

function topSkill(): SkillState | undefined {
  return skillStack[skillStack.length - 1];
}

// ponytail: walk stack top-down to find the skill that owns the active
// verifier gate. Sub-skills pushed during a verifier gate should not
// intercept the parent's reviewer tracking (#7274, #7275).
function findVerifierGateOwner(): SkillState | undefined {
  for (let i = skillStack.length - 1; i >= 0; i--) {
    const skill = skillStack[i]!;
    const step = skill.steps[skill.stepIndex];
    if (step?.gate === "verifier") return skill;
  }
  return undefined;
}

// #357 (Task 7, c): checkpoint-owner resolution via stack-walk FIRST for
// checkpoint events — a verifier gate below must not hijack the child's
// checkpoint tool_result; mirrors findVerifierGateOwner.
function findCheckpointGateOwner(): SkillState | undefined {
  for (let i = skillStack.length - 1; i >= 0; i--) {
    const skill = skillStack[i]!;
    const step = skill.steps[skill.stepIndex];
    if (step?.gate === "checkpoint") return skill;
  }
  return undefined;
}

// #357 (Task 7, c): marker contract — `{skill, stepIndex, ok}` recorded ONLY
// for allowed calls at a checkpoint, keyed by toolCallId (pi executes sibling
// calls CONCURRENTLY — completion order interleaves; a FIFO would desync).
// tool_result advances iff marker.skill still on the stack ∧ stepIndex still
// current ∧ !marker.ok ∧ checkpointTokenOk(step).ok now. Blocked calls emit no
// tool_result → markers leak → cap/evict (insertion order, oldest first).
interface CheckpointMarker {
  skill: SkillState;
  stepIndex: number;
  ok: boolean;
}
const markers = new Map<string, CheckpointMarker>();
const MARKERS_MAX = 50;
function recordMarker(toolCallId: string, entry: CheckpointMarker): void {
  if (!toolCallId) return; // missing toolCallId → fail-closed: no marker
  if (markers.size >= MARKERS_MAX) {
    const oldest = markers.keys().next().value;
    if (oldest !== undefined) markers.delete(oldest);
  }
  markers.set(toolCallId, entry);
}

// #357 (Task 7, c): SINGLE advancement rule — advance stepIndex ONLY when the
// token is ok, at tool_call (blocked-call rule: advance FIRST, then validate)
// or at tool_result (!ok@call → ok@result transition via the marker). On any
// checkpoint advance: announceGate for the next step; completion pops the skill.
function advanceCheckpoint(skill: SkillState): void {
  const next = skill.stepIndex + 1;
  // #357 review (Bug-scan P2): capture the coalesce key BEFORE incrementing —
  // checkpointKey() reads skill.stepIndex, so deleting after the increment
  // cleared the NEW step's record while the pre-advance window lingered.
  const leavingKey = checkpointKey(skill);
  if (next < skill.steps.length) {
    skill.stepIndex = next;
    skill.stepStartedAt = Date.now();
    // #357 (Task 8, j): advance resets the block streak + audit coalescer.
    checkpointBlockStreak = null;
    auditCoalesce.delete(leavingKey);
    console.log(
      `[sequence-enforcer] ⏩ Checkpoint advanced → step ${next}/${skill.steps.length}: ${skill.steps[next]!.name}`,
    );
    announceGate(skill.steps[next]!);
    writeBridgeState();
    // (h) force-file consumption is done by the CALLERS (tool_call / tool_result
    // handlers, Task 10): any checkpoint advance consumes a present force file
    // (one-shot — it must never pass a same-phase adjacent checkpoint),
    // regardless of which token drove the advance (real token or force).
    return;
  }
  console.log(
    `[sequence-enforcer] ✅ All ${skill.steps.length} steps completed`,
  );
  const idx = skillStack.indexOf(skill);
  if (idx >= 0) skillStack.splice(idx);
  const parent = topSkill();
  if (parent) {
    console.log(`[sequence-enforcer] ↩ Restored parent: ${parent.path} (step ${parent.stepIndex}/${parent.steps.length})`);
    writeBridgeState();
  } else {
    clearBridgeState();
  }
}

// ── Sequence timeout — auto-clear stale sequences ─────

let sequenceTimeout: ReturnType<typeof setTimeout> | null = null;
const SEQUENCE_TIMEOUT_MS = 10 * 60 * 1000;

// #201: on 10-min idle, print-mode PARKS the skill (state preserved, timer
// re-armed) instead of popping. Previously blocked-spam workers never timed
// out at all (every blocked call re-armed the timer before validation) and a
// fire discarded stepIndex + reviewers mid-stage. Interactive mode keeps the
// established stale-cleanup pop.
export function handleSequenceTimeout(
  env: Record<string, string | undefined> = process.env,
  argv: string[] = process.argv,
): void {
  const top = topSkill();
  if (!top) return;
  // #357 (Task 8, j): checkpoint-stall PARK takes precedence over the 10-min POP
  // in ALL modes — a checkpoint is never popped (pop → re-read/re-pop loop +
  // silent enforcement loss). This is also the timer-driven path for a fully
  // idle session at an un-CLEAR-able checkpoint (the only trigger that fires
  // with ZERO further events). #357 review (Bug-scan P2): the owner is resolved
  // via the stack-walk — a checkpoint owner can sit BELOW a sub-skill frame
  // (read is an escape tool and pushes sub-skill frames); a top-only check
  // would pop the sub-skill instead of parking the owner.
  const owner = findCheckpointGateOwner();
  if (owner) {
    const step = owner.steps[owner.stepIndex];
    // (cycle 3): warn-mode sessions never park — the first call auto-advances,
    // so a park would be recovery-signal noise in a success path (mirrors the
    // handler's wall-clock guard). The re-arm stays unconditional.
    if (step?.gate === "checkpoint" && resolveMode(env, MODE_FILE, argv) !== "warn" && Date.now() - owner.stepStartedAt > WALL_CLOCK_STALL_MS) {
      parkCheckpoint(owner, "checkpoint stall (sequence timeout)");
    }
    // re-arm: parked state preserved; one-shot suppresses repeat parks
    sequenceTimeout = setTimeout(handleSequenceTimeout, SEQUENCE_TIMEOUT_MS);
    return;
  }
  // #357 (Task 4): park predicate is argv-aware — bare-shell `pi -p` (no
  // PI_MODE env) parks too; the audited mode uses the same (env, argv) seam so
  // it matches the parked behavior under test.
  if (isPrintMode(env, argv)) {
    console.log(`[sequence-enforcer] ⏰ Sequence timeout — parking "${top.path}" at step ${top.stepIndex} (10min no tool calls) — state preserved`);
    auditLog({ ts: new Date().toISOString(), event: "timeout_park", skill: top.path, step: top.stepIndex, mode: resolveMode(env, MODE_FILE, argv) });
    // park: keep stack/stepIndex/reviewers intact, re-arm the timer
    sequenceTimeout = setTimeout(handleSequenceTimeout, SEQUENCE_TIMEOUT_MS);
    return;
  }
  console.log(`[sequence-enforcer] ⏰ Sequence timeout — popping stale "${top.path}" (10min no tool calls)`);
  // ponytail: pop only the stale skill, preserve parent (#7276)
  skillStack.pop();
  const parent = topSkill();
  if (parent) {
    console.log(`[sequence-enforcer] ↩ Restored parent: ${parent.path} (step ${parent.stepIndex}/${parent.steps.length})`);
    writeBridgeState();
  } else {
    clearBridgeState();
  }
}

function resetSequenceTimeout() {
  if (sequenceTimeout) clearTimeout(sequenceTimeout);
  sequenceTimeout = setTimeout(handleSequenceTimeout, SEQUENCE_TIMEOUT_MS);
}


// ── Kill switch ──────────────────────────────────────

function isKillSwitchActive(): boolean {
  if (_getEnv("STATE_MACHINE")) return true;
  try { return existsSync(KILL_SWITCH_FILE); } catch { return false; }
}

// ── Mode ─────────────────────────────────────────────

// #201: print-aware default. Order is unchanged — explicit env → MODE_FILE →
// fallback — but the fallback now branches on PI_MODE: `pi -p` sessions
// (sub-agents, background workers) default to `warn` so a verifier gate can
// never deadlock a worker; interactive sessions keep `gate`. Explicit
// overrides always win — ops force gate/strict in print via env or file.
// The env/modeFile params are test seams (mirrors repo-freshness exported
// internals pattern); runtime callers use the defaults.
export function resolveMode(
  env: Record<string, string | undefined> = process.env,
  modeFile: string = MODE_FILE,
  argv: string[] = process.argv,
): Mode {
  const envMode = (env.AGENT_SEQUENCE_MODE ?? env.ELDATO_SEQUENCE_MODE) || env.PI_ENFORCER_MODE;
  if (envMode === "warn" || envMode === "gate" || envMode === "strict") return envMode;
  // ponytail: mode override via dedicated file (decoupled from kill switch)
  try {
    const line = readFileSync(modeFile, "utf-8").split("\n")[0]!.trim();
    if (line === "warn" || line === "gate" || line === "strict") return line;
  } catch { /* file doesn't exist or unreadable */ }
  // #357 (Task 4): argv-aware fallback — the #201 documented bare-shell carve-out
  // is REVERSED: `pi -p` with no PI_MODE env (the worker-spawner class that
  // resolves gate and deadlocks at checkpoints) now defaults to warn. Env flag
  // (PI_MODE=print) still wins; explicit overrides above always win.
  return isPrintMode(env, argv) ? "warn" : "gate";
}
// ── Audit logging ──────────────────────────────────

// #377: session attribution for audit entries. The pi session id is captured
// from the event ctx (ctx.sessionManager.getSessionId — the authoritative
// in-process source) and stamped onto every enforcement entry, so probe/test
// pollution is attributable and the positive-audit gate (#357 criterion 16)
// can name exactly which sessions started after a deploy.
let auditSessionId: string | null = null;
// Test seam: force a deterministic session id (honored only under
// NODE_ENV=test — mirrors _setAuditSinkForTest / _setForceFileForTest / other
// sibling seams where null DEACTIVATES the override). With an override active,
// capture short-circuits ctx resolution, so tests can drive the no-ctx audit
// paths (timeout/timer) deterministically.
let auditSessionOverride: { active: boolean; id: string | null } = { active: false, id: null };
export function _setAuditSessionIdForTest(id: string | null): void {
  if (process.env.NODE_ENV !== "test") return;
  auditSessionOverride = { active: id !== null, id };
  if (id !== null) auditSessionId = id;
}

// Test getter: read the captured session id under NODE_ENV=test (mirrors
// _stackForTest / _markerCountForTest) so tests can assert capture semantics
// (ctx-first resolution, override precedence, shutdown drop) directly.
export function _auditSessionIdForTest(): string | null {
  return process.env.NODE_ENV === "test" ? auditSessionId : null;
}

// Resolve the session id from the event ctx. ctx is the SOLE authoritative
// source — there is deliberately NO process.env.PI_SESSION_ID fallback
// (#377 scope + code review P2): pi injects PI_SESSION_ID into bash-tool child
// envs (and create-harness execution envs), so a nested pi launched inside an
// outer session's bash tool inherits the OUTER id; falling back to it would
// stamp the outer session on the nested stream — the exact probe-misattribution
// failure this issue exists to close (loop-enforcer precedent: ctx-only,
// null when unresolvable; an unattributed entry beats a misattributed one).
// ctx.sessionManager is a lazy getter in pi's runner that can throw when the
// runner is stale (assertActive) — the try/catch keeps captureAuditSession
// throw-free at every call site (#383 P3-2 "never let an external surface
// throw" convention).
function resolveSessionId(ctx: { sessionManager?: { getSessionId?: () => string } } | undefined): string | null {
  try {
    return ctx?.sessionManager?.getSessionId?.() ?? null;
  } catch {
    return null; // stale runner ctx — keep prior captured id, never throw
  }
}

let sessionIdWarned = false;

// Capture at an event boundary. Under test with an override installed, the
// override wins so direct helper/timer audit paths are deterministic. Never
// throws (resolveSessionId swallows; override path is pure assignment).
function captureAuditSession(ctx: { sessionManager?: { getSessionId?: () => string } } | undefined): void {
  if (process.env.NODE_ENV === "test" && auditSessionOverride.active) {
    auditSessionId = auditSessionOverride.id;
    return;
  }
  auditSessionId = resolveSessionId(ctx);
  // Loud-diagnosis convention (#383): a systemic inability to attribute must
  // not be silent (the downstream gate reads null as "no session"). One-time
  // warn per process, production only (tests drive ctx fixtures / override).
  if (auditSessionId === null && process.env.NODE_ENV !== "test" && !sessionIdWarned) {
    sessionIdWarned = true;
    try { console.warn("[sequence-enforcer] ⚠️ audit session_id unresolvable (ctx.sessionManager absent) — entries stamped null"); } catch { /* last resort */ }
  }
}

// Test seam: tests inject a sink to capture entries without writing to the
// real enforcement.jsonl (honored only under NODE_ENV=test).
let auditSink: ((entry: Record<string, unknown>) => void) | null = null;
export function _setAuditSinkForTest(sink: ((entry: Record<string, unknown>) => void) | null): void {
  if (process.env.NODE_ENV !== "test") return;
  auditSink = sink;
}

function auditLog(entry: Record<string, unknown>) {
  // #377: stamp the session id on the single choke point — every entry type
  // (startup, blocked, allowed, warn_blocked, checkpoint_*, timeout_park,
  // handler_error, bypassed) carries it. Always-present key (string | null)
  // so group-by consumers never split on missing-vs-null; pre-#377 lines have
  // no key and are treated as null by the reader.
  const stamped = { ...entry, session_id: auditSessionId };
  if (auditSink) {
    try { auditSink(stamped); } catch (e) {
      // #383 (Task 3) T6(i): a raising sink (write failure injected by the test)
      // must NOT escape into the tool_call handler's fail-open catch — the
      // advance outcome is unchanged, but the failure is surfaced deterministically
      // (never silent: the post-merge lag tripwire cannot distinguish "event never
      // emitted" from "sink failed").
      // #383 (Task 3) P3-2 (code-quality): the T6(i) intent holds only while
      // console.warn itself doesn't throw — a throwing warn would escape
      // auditLog into the tool_call handler's fail-open catch (converting the
      // advance outcome). Defensive last resort: never let auditLog throw.
      try { console.warn(`[sequence-enforcer] ⚠️ audit sink failed: ${String(e)}`); } catch { /* last resort */ }
    }
    return;
  }
  // #357 (Task 8, landed early — Batch-1 verifier P1): under NODE_ENV=test with
  // no sink installed, do NOT fall through to the production log — test runs
  // must never pollute ~/.pi/agent/audit/enforcement.jsonl (probe-pollution
  // incident class; the scope doc's 20:33:28 artifacts).
  if (process.env.NODE_ENV === "test") return;
  const auditPath = enforcementLogFile();
  try {
    mkdirSync(dirname(auditPath), { recursive: true });
    appendFileSync(auditPath, JSON.stringify(stamped) + "\n");
  } catch (e) {
    // #383 (Task 3): the old silent catch (`/* fail silently */`) is gone — a
    // sink failure must be surfaced, never silent. Still non-throwing: an audit
    // throw must never reach the tool_call handler's fail-open catch.
    // #383 (Task 3) P3-2 (code-quality): throw-proof the production-log failure
    // surface too — a throwing console.warn must never escape auditLog.
    try { console.warn(`[sequence-enforcer] ⚠️ audit write failed: ${String(e)}`); } catch { /* last resort */ }
  }
}

// ── enforcement.jsonl path + reader (#377) ─────────

// Lazy path resolution (mirrors shared/audit-log.ts gateEventsFile()):
// resolved per call, not at module load, so a $HOME change (tests, alternate
// agent dirs) takes effect.
export function enforcementLogFile(): string {
  return join(homedir(), ".pi", "agent", "audit", "enforcement.jsonl");
}

export interface EnforcementLogEntry {
  ts: string;
  session_id?: string | null;
  event: string;
  [key: string]: unknown;
}

export interface ReadEnforcementLogOptions {
  /** Explicit file path (default: enforcementLogFile()). */
  file?: string;
  /** Only entries whose ts >= since (ISO-8601, inclusive). */
  since?: string;
  /** Only entries whose event name is in this list. */
  events?: string[];
  /** Only entries from this exact session id. */
  sessionId?: string;
  /** Cap: return only the `limit` most recent matching entries. */
  limit?: number;
}

export interface ReadEnforcementLogResult {
  entries: EnforcementLogEntry[];
  /** Lines skipped because they were not parseable JSON (blank lines ignored). */
  skipped: number;
}

// Small enforcement.jsonl reader (the enforcement SKILL.md "reader is a
// swarm-side follow-up" note). Tolerant on DATA (missing file → empty,
// malformed lines skipped and counted, never throws) but fail-closed on
// FILTER INPUT: an unparseable `since`, or a non-positive `limit`, returns an
// empty result rather than silently dropping the filter and over-reporting
// (the #357-16 gate must never answer "every startup session since the
// beginning of the log" on a typo'd ts). Entries return in file order
// (append-only → chronological). Missing session_id (pre-#377 lines) equals
// null under a sessionId filter — excluded, never a crash.
// Semantics: events: [] or undefined = no event filter; limit: undefined = no
// cap, limit <= 0 = empty result; since: undefined = no filter.
export function readEnforcementLog(opts: ReadEnforcementLogOptions = {}): ReadEnforcementLogResult {
  const file = opts.file ?? enforcementLogFile();
  // Fail-closed on filter input before touching the file.
  if (opts.limit !== undefined && opts.limit <= 0) return { entries: [], skipped: 0 };
  const sinceMs = opts.since !== undefined ? Date.parse(opts.since) : NaN;
  if (opts.since !== undefined && Number.isNaN(sinceMs)) return { entries: [], skipped: 0 };
  let raw: string;
  try {
    raw = readFileSync(file, "utf-8");
  } catch {
    return { entries: [], skipped: 0 }; // absent / unreadable → empty
  }
  const entries: EnforcementLogEntry[] = [];
  let skipped = 0;
  for (const line of raw.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    let parsed: unknown;
    try {
      parsed = JSON.parse(trimmed);
    } catch {
      skipped++;
      continue;
    }
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      skipped++;
      continue;
    }
    const entry = parsed as EnforcementLogEntry;
    if (typeof entry.ts !== "string" || typeof entry.event !== "string") {
      skipped++;
      continue;
    }
    if (opts.events && opts.events.length > 0 && !opts.events.includes(entry.event)) continue;
    if (opts.sessionId !== undefined && entry.session_id !== opts.sessionId) continue;
    if (!Number.isNaN(sinceMs)) {
      const tsMs = Date.parse(entry.ts);
      if (Number.isNaN(tsMs) || tsMs < sinceMs) continue;
    }
    entries.push(entry);
  }
  if (opts.limit !== undefined && entries.length > opts.limit) {
    return { entries: entries.slice(entries.length - opts.limit), skipped };
  }
  return { entries, skipped };
}


// ── Python bridge ────────────────────────────────────

export function loadSteps(skillPath: string): Step[] | null {
  if (stepCache.has(skillPath)) return stepCache.get(skillPath)!;

  const absPath = resolve(skillPath);
  if (!existsSync(absPath)) { stepCache.set(skillPath, null); return null; }

  try {
    // ponytail: execFileSync bypasses shell — absPath via argv, no injection vector
    //
    // skill_declaration.py is an eldato-era tool that was never vendored into
    // agent-infra (extension extracted in #7549 without its Python dep). Rather
    // than fail-closed on the phantom module, the bridge tries it first (in case
    // a repo vendors operations/tools/), then falls back to parsing the `steps:`
    // list from the SKILL.md frontmatter directly — same Step schema, no missing
    // module dependency. This eliminates the boot-time ModuleNotFoundError
    // noise in sub-agent stderr (#489 class).
    const json = execFileSync(process.env.AGENT_PYTHON3 || "python3", [
      "-c",
      [
        "import sys, os, json",
        "def _find_tools_dir():",
        "    candidates = [",
        "        os.environ.get('AGENT_TOOLS_PATH',''),",
        "        os.environ.get('PYTHONPATH',''),",
        "        os.path.join(os.environ.get('AGENT_INFRA_PATH',''), 'operations', 'tools'),",
        "    ]",
        "    for c in candidates:",
        "        for part in c.split(os.pathsep):",
        "            if part and os.path.isfile(os.path.join(part, 'skill_declaration.py')):",
        "                return part",
        "    return ''",
        "def _try_module(path):",
        "    _tools = _find_tools_dir()",
        "    if _tools: sys.path.insert(0, _tools)",
        "    try:",
        "        from skill_declaration import extract_steps_from_skill",
        "        steps = extract_steps_from_skill(path)",
        "        return [{k: v for k, v in s.__dict__.items() if not k.startswith('_')} for s in (steps or [])]",
        "    except ImportError:",
        "        return None  # module not vendored — fall back to frontmatter parse",
        "def _try_frontmatter(path):",
        "    import re",
        "    try:",
        "        import yaml",
        "    except ImportError:",
        "        return []",
        "    try:",
        "        text = open(path, encoding='utf-8').read()",
        "    except OSError:",
        "        return []",
        "    m = re.match(r'\\A---\\n(.*?)\\n---', text, re.DOTALL)",
        "    if not m:",
        "        return []",
        "    try:",
        "        fm = yaml.safe_load(m.group(1)) or {}",
        "    except yaml.YAMLError:",
        "        return []",
        "    steps = fm.get('steps') or []",
        "    if not isinstance(steps, list):",
        "        return []",
        "    out = []",
        "    for s in steps:",
        "        if not isinstance(s, dict):",
        "            continue",
        "        out.append({",
        "            'name': s.get('name', ''),",
        "            'type': s.get('type', 'skill'),",
        "            'skill': s.get('skill', ''),",
        "            'requires': s.get('requires', []) or [],",
        "            'produces': s.get('produces', []) or [],",
        "            'gate': s.get('gate', 'auto'),",
        "            'retry': s.get('retry', 1),",
        "            'timeout_seconds': s.get('timeout_seconds', 0),",
        "            'token_phase': s.get('token_phase', ''),",
        "        })",
        "    return out",
        "_steps = _try_module(sys.argv[1])",
        "if _steps is None:",
        "    _steps = _try_frontmatter(sys.argv[1])",
        "else:",
        "    # #357 (Task 3): eldato's skill_declaration.py does NOT emit token_phase",
        "    # (the dead-code root cause) — normalize INSIDE the bridge (yaml is loaded",
        "    # here): for checkpoint steps missing token_phase, re-read the frontmatter",
        "    # and fill it from the same-named step. Never in TS (zero-dep CI).",
        "    _fm = _try_frontmatter(sys.argv[1])",
        "    _by_name = {s.get('name'): s for s in _fm}",
        "    for _s in _steps:",
        "        if _s.get('gate') == 'checkpoint' and not _s.get('token_phase'):",
        "            _f = _by_name.get(_s.get('name'))",
        "            if _f and _f.get('token_phase'):",
        "                _s['token_phase'] = _f.get('token_phase')",
        "print(json.dumps(_steps))",
      ].join("\n"),
      absPath,
    ], {
      encoding: "utf-8",
      timeout: 5000,  // ponytail: 5s for cold Python import (yaml)
    }).trim();
    const steps: Step[] = JSON.parse(json);
    stepCache.set(skillPath, steps.length > 0 ? steps : null);
    return steps.length > 0 ? steps : null;
  } catch (e) {
    // #357 review (Security "Needs verification"): a bridge failure (python
    // missing, vendored skill_declaration.py crashing, 5s timeout) must NOT be
    // silent — a silent null cache disables ALL gate enforcement on that skill
    // read (fail-open, no signal). Log loudly AND skip caching so the next read
    // retries (transient failures self-heal instead of pinning the skill dead).
    console.warn(`[sequence-enforcer] ⚠️ python bridge failed for ${skillPath}: ${String(e)} — gate enforcement off for this read (frontmatter steps will load on retry)`);
    return null;
  }
}

// ── Tool validation ──────────────────────────────────

// #357 (Task 6, d): in-session escape at a pending checkpoint. The gate must
// never block its own escape (#7470): read + loop_enforcer are always allowed,
// and bash ONLY for the sole-command parallel_work_check invocation (the
// CLEAR-able form). The regex is the mechanically-verified 17/17 matrix from
// the #357 scoping doc — see the escape matrix tests. Structure: new RegExp
// (not a literal) per the scope; `[^\S\u0020]` reject-set keeps U+0020 as the
// ONLY allowed whitespace (tab/NBSP/zero-width rejected); explicit env
// allowlist; safe-class values; mandatory `.sh|.py` suffix + ≥1 argument.
const CHECKPOINT_ESCAPE_RE = new RegExp(
  "^(?:env[ ]+(?:(?:GH_TOKEN|CHECKOUT_GUARD_ENFORCE|AGENT_INFRA_PATH)=[A-Za-z0-9_./:=-]+[ ]+)+)?" +
  "(?:sudo[ ]+)?(?:python3[ ]+|uv[ ]+run[ ]+)?" +
  "(?:[./\\w-]+\\/)*parallel_work_check\\.(?:sh|py)[ ]+[A-Za-z0-9_./:=-]+(?:[ ]+[A-Za-z0-9_./:=-]+)*$",
);
// Whitespace + metachar pre-check: any non-U+0020 whitespace (tab, NBSP, Ogham,
// line breaks) or zero-width char (U+200B-U+200D, U+2060, U+0085) → reject.
// Plain U+0020 must NOT match (regression-pinned).
export const CHECKPOINT_WHITESPACE_REJECT = /[^\S\u0020]|[\u200B-\u200D\u2060\u0085]/u;

// #357 (d): non-bash escape tools + bash sole-command checker. Malformed bash
// input (non-string/missing command) is NOT the escape (fail-closed).
export function isCheckpointEscape(toolName: string, command: unknown): boolean {
  if (toolName === "read" || toolName === "loop_enforcer") return true;
  if (toolName !== "bash") return false;
  if (typeof command !== "string") return false;
  if (CHECKPOINT_WHITESPACE_REJECT.test(command)) return false;
  return CHECKPOINT_ESCAPE_RE.test(command);
}

// #357 (Task 7): extract the checker's phase argument (the first positional arg
// after the script) from a validated escape command — used by the wrong-phase
// guard so a checker that would write a wrong-phase token is blocked.
function checkpointEscapePhase(command: string): string | null {
  const stripped = command
    .replace(/^env(?:[ ]+[A-Za-z0-9_./:=-]+=[A-Za-z0-9_./:=-]+)+[ ]+/, "")
    .replace(/^sudo[ ]+/, "")
    .replace(/^(?:python3[ ]+|uv[ ]+run[ ]+)/, "")
    .replace(/^(?:[./\w-]+\/)+/, "");
  const parts = stripped.split(" ");
  return parts.length >= 2 ? (parts[1] ?? null) : null;
}

const GIT_OP = /(^|\s)(git\s+(commit|push|merge|add)|gh\s+pr\s+(create|merge))/;
const DESTRUCTIVE_MCP = /\b(?:delete|remove|reset|revoke|drop|truncate|merge|rebase|purge|destroy|invalidate)\b/i;

// Enforcement A (issue #5039): the checkpoint step-gate requires a FRESH
// phase-correct CLEAR token from parallel_work_check before the step may
// proceed. Fail-closed: missing/stale/wrong-phase/non-CLEAR/corrupt → BLOCK
// (retry + the operator force-pass are the escape). The token is written by
// parallel_work_check ONLY on CLEAR — never on UNKNOWN — so a phase gate can
// never silently pass on infra failure.
const CHECKPOINT_TOKEN_FILE = "/tmp/parallel-check-token.json";
const CHECKPOINT_TOKEN_TTL_MS = 600_000; // 10 min (plan §4)

// #357 (Task 10, h): operator force-pass — a scoped, documented, one-shot
// bypass distinct from the kill switch. Formalizes the proven hand-token
// practice for gate-mode interactive worktree sessions where the checker
// CANNOT CLEAR by design (C1 DEFER on any non-main worktree branch).
const FORCE_FILE = "/tmp/parallel-check-force.json";
const FORCE_TTL_MS = 60 * 60 * 1000; // operator TTL — session-scoped, > token TTL

// Repo identity for the force file's repo binding (a force file written in repo
// A must NOT pass repo B's checkpoint). Resolved once per session from the git
// remote; test seam for unit tests.
let FORCE_FILE_OVERRIDE: string | null = null;
export function _setForceFileForTest(path: string | null): void {
  if (process.env.NODE_ENV !== "test") return;
  FORCE_FILE_OVERRIDE = path;
}
function forceFile(): string {
  if (FORCE_FILE_OVERRIDE !== null) return FORCE_FILE_OVERRIDE;
  // #357 review (cycle 3): under NODE_ENV=test, never touch the REAL /tmp
  // force file — mirrors the tokenFile() guard. A real operator file must not
  // be read, consumed, or unlinked by the suite (probe-pollution class; the
  // hygiene + session_start tests run consumeForceFile/unlink without an
  // override).
  if (process.env.NODE_ENV === "test") return "/tmp/sequence-enforcer-test-none/force.json";
  return FORCE_FILE;
}
let currentRepoCache: { cwd: string; repo: string } | null = null;
let repoTestOverride: string | null = null;
export function _setRepoForTest(repo: string | null): void {
  if (process.env.NODE_ENV !== "test") return;
  repoTestOverride = repo;
}

// #383 (Task 3): mirror the checker's GitOps.remote_url() userinfo
// sanitization EXACTLY (Python urlsplit vs Node URL parsing differ — this is a
// pure string transformation, byte-identical to Python's
// `parts._replace(netloc=…).geturl()`). Strip ALL userinfo from
// scheme-bearing URLs — BOTH the bare-PAT form (`https://TOKEN@host/…`, no
// colon — common for GitHub PATs-as-username) AND the `user:pass@` form;
// host:port survive exactly (last-`@` split, like Python's rsplit("@",1)).
// scp-form `git@host:org/repo.git` has no scheme → no netloc in urlsplit →
// byte-identical untouched. No match / no userinfo → unchanged. Empty → "unknown".
export function sanitizeRemoteUrl(raw: string): string {
  const trimmed = raw.trim();
  if (!trimmed) return "unknown";
  const m = /^([a-zA-Z][a-zA-Z0-9+.-]*):\/\/([^/?#]*)/.exec(trimmed);
  if (!m) return trimmed;
  // #383 (Task 3) P3-1 (code-quality): urlsplit raises ValueError on an
  // UNBALANCED-bracket netloc (`https://user@[::1/org/repo.git` → Python
  // "unknown"); the regex would accept the mangled netloc and pass it through
  // verbatim → spurious cross-repo BLOCK. A netloc containing a `[` XOR `]`
  // returns "unknown", matching Python's urlsplit bracket ValueError.
  // #383 (Task 3) P3-1 (FINAL mechanical round): the balanced-but-invalid
  // check is now a TRUE IPv6 mirror — Node's built-in `net.isIP` (zero deps),
  // mirroring Python 3.12 urlsplit's bracketed-host ipaddress check: the
  // bracketed host is preserved IFF `isIP(inner) === 6`. This rejects
  // everything urlsplit's ValueError rejects — letters ("notanip"), bare hex
  // ("deadbeef"), empty "[]", bracketed IPv4 ("[127.0.0.1]" → isIP 4 ≠ 6),
  // and the loose-regex survivors (`[:1]`, `[1:2]`, `[::::]`, 9-hextet,
  // 5-digit hextet, `[a:b]` — all isIP 0). Zone-IDs: Node ≥22's isIP accepts
  // `fe80::1%eth0` (isIP 6), which Python 3.12 ALSO preserves — so on the pi
  // runtime (v22.23.2) the mirror is COMPLETE, no residue. On a pre-22 Node
  // (isIP 0 for zone-IDs) the direction is fail-closed: spurious BLOCK, never
  // a silent pass. Brackets live in the host part — slice after the last `@`
  // so userinfo is excluded.
  if (m[2].includes("[") || m[2].includes("]")) {
    const hostPart = m[2].slice(m[2].lastIndexOf("@") + 1);
    const open = hostPart.indexOf("[");
    const close = hostPart.indexOf("]");
    if (open === -1 || close === -1 || close < open) return "unknown"; // unbalanced → urlsplit ValueError parity
    const inner = hostPart.slice(open + 1, close);
    if (isIP(inner) !== 6) return "unknown"; // balanced-but-invalid → urlsplit ValueError parity
  }
  if (!m[2].includes("@")) return trimmed;
  // #383 (Task 3) P2-1 (code-quality): Python's urlsplit LOWERCASES the scheme
  // (parts.scheme); the old regex preserved case — `git remote add origin
  // HTTPS://TOKEN@host/…` is stored verbatim, so the enforcer bound
  // `HTTPS://…` vs the checker's lowercased `https://…` → spurious cross-repo
  // BLOCK. Lowercase the scheme on the rebuilt URL (the no-userinfo path stays
  // case-preserved like Python's raw return).
  return m[1].toLowerCase() + "://" + m[2].slice(m[2].lastIndexOf("@") + 1) + trimmed.slice(m[0].length);
}

// #383 (Task 3): PARALLEL_CHECK_REPO is documented as a PATH while token.repo
// carries the URL form — resolveRepo runs the SAME `git -C <v> remote get-url
// origin` the checker's GitOps.remote_url() runs (trimmed, fail → "unknown"),
// so a path-valued env binds identically to the checker's resolution. Bad
// paths (nonexistent / plain file / non-git dir) → "unknown" — NEVER a throw
// (a throw here would land in the tool_call handler's fail-open catch and
// convert BLOCK→ALLOW — the T14/T15 hazard class).
// #383 (Task 3) P2-2/P3 (code-quality): resolveRepo is memoized keyed on the
// env VALUE AND the cwd — this cache MIRRORS currentRepo's cwd-keyed cache
// exactly (same key shape, same invalidation). With a RELATIVE
// PARALLEL_CHECK_REPO (`.`, the natural operator shorthand) the `git -C <v>`
// binding is cwd-relative, so a mid-session chdir MUST re-resolve, else the
// enforcer stays pinned to the OLD repo while the checker binds the NEW one →
// spurious cross-repo BLOCK (fail-closed, but a regression for relative-path
// configs). bindingRepo() runs at every checkpoint tool_call (token check +
// the skip-audit's binding), and an uncached `git -C` spawn per call was 2–3
// subprocesses per tool call; the operator's PARALLEL_CHECK_REPO is
// session-stable and the cwd is stable within a resolution burst, so
// same-value/same-cwd re-resolution (e.g. the skip-audit binding right after
// the token check) reuses the already-resolved binding — no re-spawn.
let envRepoCache: { v: string | undefined; cwd: string; repo: string } | null = null;
function resolveRepo(v: string): string {
  if (envRepoCache && envRepoCache.v === v && envRepoCache.cwd === process.cwd()) return envRepoCache.repo;
  let repo: string;
  try {
    const url = execFileSync("git", ["-C", v, "remote", "get-url", "origin"], { encoding: "utf-8", timeout: 5000 }).trim();
    repo = sanitizeRemoteUrl(url || "unknown");
  } catch {
    repo = "unknown";
  }
  envRepoCache = { v, cwd: process.cwd(), repo };
  return repo;
}

// #383 (Task 3): the checkpoint binding repo — resolveRepo(PARALLEL_CHECK_REPO)
// (PATH form; empty/whitespace falls through, never presence-keyed — T14)
// || currentRepo() (cwd). The enforcer NEVER learns a `--repo X` flag the
// checker ran with — T14 pins the named-mismatch BLOCK + the
// PARALLEL_CHECK_REPO remediation.
function bindingRepo(): string {
  const envRepo = process.env.PARALLEL_CHECK_REPO;
  if (envRepo && envRepo.trim()) return resolveRepo(envRepo);
  return currentRepo();
}

function currentRepo(): string {
  if (repoTestOverride) return sanitizeRemoteUrl(repoTestOverride);
  // #357 review (Bug-scan P2): the cache is keyed on cwd — agents cd between
  // repos routinely; a session-start remote would weaken the force-file repo
  // binding. Only re-resolves on cwd change (the git call is 5s-throttled).
  const cwd = process.cwd();
  if (currentRepoCache && currentRepoCache.cwd === cwd) return currentRepoCache.repo;
  try {
    const url = execFileSync("git", ["remote", "get-url", "origin"], { encoding: "utf-8", timeout: 5000 }).trim();
    // #383 (Task 3) CRITICAL PARITY: the cached value is SANITIZED through the
    // same userinfo-strip as the checker's remote_url — a credential-bearing
    // origin must bind identically on both sides, else a sanitized checker
    // token vs raw enforcer repo → spurious cross-repo BLOCK.
    currentRepoCache = { cwd, repo: sanitizeRemoteUrl(url || "unknown") };
  } catch {
    currentRepoCache = { cwd, repo: "unknown" };
  }
  return currentRepoCache.repo;
}

// Read + validate the force file. Malformed (truncated JSON, {} , missing
// required fields, NaN/string ts) → { status: "malformed" } — the checkpoint
// stays fail-closed and the block reason names the malformed file.
function readForceFile(): { status: "none" | "malformed" | "ok"; data?: Record<string, unknown> } {
  const file = forceFile();
  try {
    if (!existsSync(file)) return { status: "none" };
    let raw: string;
    try {
      raw = readFileSync(file, "utf-8");
    } catch {
      // #383 (Task 3) P3-3 (code-quality): a PRESENT-but-unreadable force file
      // (chmod 000) is NOT "none found" — mirror T10d's token-file handling:
      // name it malformed (the malformed note names the file; cleanup on
      // advance still applies via consumeForceFile). A silent "none" would
      // mislabel an operator bypass as absent.
      return existsSync(file) ? { status: "malformed" } : { status: "none" };
    }
    let f: unknown;
    try {
      f = JSON.parse(raw);
    } catch {
      return { status: "malformed" };
    }
    if (!f || typeof f !== "object") return { status: "malformed" };
    const d = f as Record<string, unknown>;
    if (
      d.verdict !== "CLEAR" ||
      typeof d.phase !== "string" ||
      typeof d.operator !== "string" ||
      typeof d.origin !== "string" ||
      typeof d.repo !== "string" ||
      (typeof d.ts !== "string" && typeof d.ts !== "number") ||
      parseTokenTs(d.ts) === null
    ) {
      return { status: "malformed" };
    }
    // #383 (Task 3) P3-2 (FINAL senior round): the force-file repo comparison
    // (`f.repo === repoNow` at the checkpointTokenOk force branch AND the
    // consumeForceFile passable check) read f.repo RAW while currentRepo() is
    // SANITIZED → a hand-written force file carrying a credential-bearing repo
    // (copied from `git remote get-url origin` on a token-auth checkout) now
    // mismatches → rejected (fail-closed, diagnosable). Sanitize HERE — the
    // single read site feeds BOTH comparisons AND the checkpoint_force_pass
    // audit's repo field (a raw credential-bearing repo would leak into the
    // audit; the skip-audit's repo already comes from the sanitized
    // bindingRepo()). Mirrors the token path (the checker sanitizes token.repo
    // before writing).
    d.repo = sanitizeRemoteUrl(d.repo);
    return { status: "ok", data: d };
  } catch {
    // P3-3: same present-but-unreadable guard for any unexpected throw in the
    // validation block — an existing file is malformed, never silently "none".
    return existsSync(file) ? { status: "malformed" } : { status: "none" };
  }
}

// Consume the force file (one-shot per checkpoint): audit the human-read-only
// checkpoint_force_pass event ONLY when the operator's file actually DROVE the
// pass, then unlink so a single file can never pass two checkpoints.
// #357 review (cycle 2, Bug-scan P2): PHASE-AWARE — only a file that could
// have passed THIS checkpoint is consumed + audited. #383 (Task 3) ONE pinned
// criterion: checkpoint_force_pass is emitted iff ctx.viaForce && mode !==
// "warn" — a real-token-wins consume or a warn-mode consume (which auto-
// advances WITHOUT honoring the file) unlinks but never claims a force pass
// (flipped real-token-wins + warn-mode-consume tests; the warn site passes a
// force-suppressed context).
function consumeForceFile(skill: SkillState, stepName: string, mode: Mode, requiredPhase: string, ctx: { viaForce: boolean }): void {
  const f = readForceFile();
  // #357 review: no file present → no-op. Callers invoke consumption on ANY
  // checkpoint advance (real-token-wins and warn-mode included) — an absent
  // file must not spam a checkpoint_force_pass audit.
  if (f.status === "none") return;
  // A well-formed file is consumed ONLY if it could have passed THIS checkpoint
  // — the SAME predicates checkpointTokenOk uses (phase + repo + parseable,
  // non-future ts within the operator TTL). An expired / wrong-repo / future-ts
  // file is left alone (it can never pass this step; consuming it would
  // silently destroy the operator's in-progress write and emit a false
  // force_pass — cycle-3 Bug-scan P2). A malformed file is cleaned up WITHOUT
  // a checkpoint_force_pass audit (the event means "an operator CLEAR passed
  // this step" — it never did).
  if (f.status === "ok") {
    const forceTs = parseTokenTs(f.data!.ts);
    const repoNow = currentRepo();
    const passable =
      f.data!.phase === requiredPhase &&
      f.data!.repo === repoNow &&
      forceTs !== null &&
      forceTs <= Date.now() &&
      Date.now() - forceTs <= FORCE_TTL_MS;
    if (!passable) return;
  }
  if (f.status === "malformed") {
    try { if (existsSync(forceFile())) unlinkSync(forceFile()); } catch { /* best-effort */ }
    return;
  }
  if (ctx.viaForce && mode !== "warn") {
    auditLog({
      ts: new Date().toISOString(),
      event: "checkpoint_force_pass",
      skill: skill.path,
      step: stepName,
      mode,
      phase: f.status === "ok" ? f.data!.phase : "?",
      operator: f.status === "ok" ? f.data!.operator : "?",
      origin: f.status === "ok" ? f.data!.origin : "?",
      repo: f.status === "ok" ? f.data!.repo : "?",
    });
  }
  try {
    if (existsSync(forceFile())) unlinkSync(forceFile());
  } catch { /* best-effort */ }
}

// Test seam: redirect token-file reads away from the real /tmp path during
// unit tests (mirrors _setBridgeDirForTest; honored only under NODE_ENV=test).
let TOKEN_FILE_OVERRIDE: string | null = null;
export function _setTokenFileForTest(path: string | null): void {
  if (process.env.NODE_ENV !== "test") return;
  TOKEN_FILE_OVERRIDE = path;
}

// #357 (Task 2): the swarm writer emits an ISO string; `Number(ts)` → NaN → a
// fresh CLEAR token was ALWAYS judged stale (the never-passable contract).
// Accept ISO 8601 (Date.parse), numeric epoch-ms, and numeric epoch-seconds
// (< 1e12 → ×1000). Returns null for unparseable/non-finite input (fail-closed).
export function parseTokenTs(ts: unknown): number | null {
  let ms: number | null = null;
  if (typeof ts === "string") {
    const t = ts.trim();
    if (t === "") return null;
    // ISO 8601 (the writer's contract): "2026-08-28T22:29:16.164Z"
    if (/^\d{4}-\d{2}-\d{2}T/.test(t)) {
      const p = Date.parse(t);
      ms = Number.isFinite(p) ? p : null;
    } else {
      const n = Number(t);
      ms = Number.isFinite(n) ? n : null;
    }
  } else if (typeof ts === "number") {
    ms = Number.isFinite(ts) ? ts : null;
  }
  if (ms === null) return null;
  // numeric epoch-seconds → ms (values < 1e12 are seconds, not milliseconds)
  return ms < 1e12 ? ms * 1000 : ms;
}

function tokenFile(): string {
  // #357 (Task 3): read the PLAIN env name FIRST — the swarm writer honors
  // PARALLEL_CHECK_TOKEN_FILE; _getEnv() would read AGENT_/ELDATO_ prefixed
  // names and never see the writer's contract. Aliases are optional fallback.
  if (TOKEN_FILE_OVERRIDE !== null) return TOKEN_FILE_OVERRIDE;
  const envPath = process.env.PARALLEL_CHECK_TOKEN_FILE;
  if (envPath) return envPath;
  // #357 review (Bug-scan P2): under NODE_ENV=test, never fall through to the
  // REAL /tmp token file — a machine with a fresh phase-correct token would
  // flip not-ok escape tests to the ok-token path (probe-pollution — the exact
  // class this PR eliminates). Mirrors the audit-sink NODE_ENV=test guard.
  if (process.env.NODE_ENV === "test") return "/tmp/sequence-enforcer-test-none/token.json";
  return CHECKPOINT_TOKEN_FILE;
}

// #383 (Task 3): mode-aware, binding-aware token check. opts.enforceBinding is
// TRUE only in gate/strict (warn is binding-free — a warn session auto-advances
// audit-only and must never be gated by a repo mismatch). Returns the token's
// mode ("no-board-skip" for skip tokens, "" for board CLEAR) so the advance
// sites can emit the distinct checkpoint_no_board_skip audit keyed on
// ok && mode === "no-board-skip" && !viaForce.
export function checkpointTokenOk(
  step: Step,
  opts: { enforceBinding?: boolean } = {},
): { ok: boolean; reason: string; viaForce?: boolean; mode?: string } {
  const enforceBinding = opts.enforceBinding === true;
  const requiredPhase = step.token_phase || "";
  // #357 (Task 3): a checkpoint step WITHOUT token_phase is unpassable-by-design
  // — any-phase CLEAR would satisfy a meaningless phase check. Fail-closed FIRST
  // (before reading the token) so the diagnostic is clear regardless of token state.
  if (!requiredPhase) {
    return { ok: false, reason: `⛔ checkpoint gate — step "${step.name}" is checkpoint-gated but declares NO token_phase (frontmatter \`token_phase:\` missing) — unpassable-by-design. Fix the skill declaration or use the operator force-pass.` };
  }
  const file = tokenFile();
  let raw = "";
  let unreadable = false;
  try {
    raw = readFileSync(file, "utf-8");
  } catch {
    // #383 (Task 3) T10d: a PRESENT-but-unreadable file (chmod 000) is NOT
    // "none found" — a named corrupt/unreadable reason, never a silent empty
    // read collapsing into the none-found message.
    unreadable = existsSync(file);
  }
  let reason = "";
  let realOk = false;
  let tokenMode = "";
  if (raw) {
    let token: { phase?: string; verdict?: string; ts?: unknown; repo?: unknown; mode?: unknown } | null = null;
    try {
      const parsed: unknown = JSON.parse(raw);
      // #383 (Task 3) T10e: valid-JSON-but-wrong-SHAPE (null/[]/scalar) must
      // get a NAMED corrupt reason — the old `if (token)` falsy path left
      // reason EMPTY (an empty-reason BLOCK — the diagnosability hole T10 pins).
      if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
        reason = `⛔ checkpoint gate — step "${step.name}" token is corrupt/unreadable (wrong shape) — BLOCK`;
      } else {
        token = parsed as typeof token;
      }
    } catch {
      reason = `⛔ checkpoint gate — step "${step.name}" token is corrupt/unreadable — BLOCK`;
    }
    if (token) {
      if (typeof token.verdict !== "string") {
        // #383 (Task 3) T10e: an object WITHOUT a verdict field is a wrong-shape
        // token (the old code reported `verdict is "?"` — same block, but not a
        // corrupt classification; T10e pins the named corrupt reason for {} too).
        reason = `⛔ checkpoint gate — step "${step.name}" token is corrupt/unreadable (missing verdict field) — BLOCK`;
      } else if (token.verdict !== "CLEAR") {
        reason = `⛔ checkpoint gate — step "${step.name}" token verdict is "${token.verdict ?? "?"}" — only CLEAR passes; UNKNOWN never writes a token (fail-closed)`;
      } else {
        tokenMode = typeof token.mode === "string" ? token.mode : "";
        const ts = parseTokenTs(token.ts);
        if (ts === null || Date.now() - ts > CHECKPOINT_TOKEN_TTL_MS) {
          reason = `⛔ checkpoint gate — step "${step.name}" token is stale (>10 min TTL) — re-run \`parallel_work_check <phase>\``;
        } else if (ts > Date.now()) {
          // #383 (Task 3) T16: reject future ts with a NAMED reason (mirrors the
          // force-file rejection below) — a clock-skewed/edited token never
          // TTL-expires and, in no-board mode where all phases CLEAR, ONE
          // tampered token would satisfy every gate in a session.
          reason = `⛔ checkpoint gate — step "${step.name}" token ts is in the future — BLOCK (clock skew or tampered token — re-run \`parallel_work_check ${requiredPhase}\`)`;
        } else if (requiredPhase && token.phase !== requiredPhase) {
          reason = `⛔ checkpoint gate — step "${step.name}" token phase "${token.phase ?? "?"}" ≠ required "${requiredPhase}" — BLOCK`;
        } else if (enforceBinding) {
          const bind = bindingRepo();
          const tokenRepo = typeof token.repo === "string" ? token.repo : "";
          if (tokenRepo !== bind) {
            // #383 (Task 3): repo binding — token.repo (URL form, sanitized by
            // the checker's GitOps.remote_url) must match this checkout's repo.
            // CRITICAL PARITY: bindingRepo() mirrors the checker's userinfo
            // sanitization so a credential-bearing origin binds identically on
            // both sides. both-"unknown" passes (no-remote parity); a legacy
            // abspath-form / missing repo BLOCKs (deploy-window reverse edge).
            // #383 (Task 3) P3-3 (FINAL senior round): echo the SANITIZED token
            // repo in the block reason — the old interpolation leaked a raw
            // credential-bearing token.repo into the audit reason + console
            // output (exposure ~nil — the checker sanitizes before writing; a
            // credential-bearing value needs a tampered token — but the
            // skip-audit's repo is already sanitized via bindingRepo()). The
            // host survives sanitization, so the reason still names the repo
            // meaningfully.
            reason = `⛔ checkpoint gate — step "${step.name}" token repo "${sanitizeRemoteUrl(tokenRepo)}" does not match this checkout's repo "${bind}" — BLOCK (re-run the checker from this checkout, or set PARALLEL_CHECK_REPO to the checker's checkout path)`;
          } else {
            realOk = true;
          }
        } else {
          realOk = true;
        }
      }
    }
  } else if (unreadable) {
    // #383 (Task 3) T10d: named unreadable-file reason (never a throw into the
    // fail-open catch).
    reason = `⛔ checkpoint gate — step "${step.name}" token file is unreadable (${file}) — BLOCK (fix permissions or re-run the checker)`;
  } else {
    reason = `⛔ checkpoint gate — step "${step.name}" requires a fresh parallel_work_check PASS token (${file}) — none found. Run \`parallel_work_check <phase>\` to produce one.`;
  }

  if (realOk) return { ok: true, reason: "", mode: tokenMode };

  // #357 (Task 10, h): operator force-pass — honored ONLY when the real token
  // fails. verdict CLEAR + phase match + repo binding + operator TTL.
  const force = readForceFile();
  if (force.status === "ok") {
    const f = force.data!;
    const forceTs = parseTokenTs(f.ts);
    const repoNow = currentRepo();
    if (
      f.phase === requiredPhase &&
      f.repo === repoNow &&
      forceTs !== null &&
      forceTs <= Date.now() && // #357 review (Bug-scan P2): reject future ts — a skew/typo must not grant an infinite operator TTL
      Date.now() - forceTs <= FORCE_TTL_MS
    ) {
      // #383 (Task 3): the return carries the (failed) token's mode so the
      // advance sites' skip-audit guard (`!viaForce`) never emits a spurious
      // checkpoint_no_board_skip on a force-driven advance (T6(h)).
      return { ok: true, reason: "", viaForce: true, mode: tokenMode };
    }
    // #357 review (Bug-scan P2): a present-but-rejected force file must not
    // silently strand the session — name the mismatch (mirrors the malformed
    // note; silent-strand was the exact class the malformed note was added for).
    const why =
      forceTs === null ? "unparseable ts"
      : f.phase !== requiredPhase ? `phase "${f.phase}" ≠ "${requiredPhase}"`
      : f.repo !== repoNow ? `repo "${f.repo}" ≠ "${repoNow}"`
      : forceTs > Date.now() ? "future ts"
      : "TTL expired (>60 min)";
    reason += ` (note: force file ${forceFile()} exists but is rejected — ${why}; fix or delete it)`;
  }
  // fail-closed: the real-token reason, plus a malformed-force note when present
  // (diagnose, don't let a broken force file silently strand the session).
  const note = force.status === "malformed" ? ` (note: force file ${forceFile()} exists but is malformed — fix or delete it)` : "";
  return { ok: false, reason: reason + note };
}

// Constructive guidance for blocked tools — tells the agent what IS allowed
// so they don't spin in circles after hitting a gate (#7459 follow-up).
// #357 (Task 9, e): the checkpoint branch was UNREACHABLE (the allow.length === 0
// early-return fired first — audit showed hint:""). Now covers ALL THREE
// checkpoint states with CONCRETE interpolated values — never `$VAR` or `<phase>`
// placeholders (the escape regex rejects `$`/`<`/`>`; a verbatim run would
// report a false "escape dead").
export function gateGuidance(step: Step, mode: Mode = "gate"): string {
  const gate = step.gate || "";
  if (gate === "checkpoint") {
    const requiredPhase = step.token_phase || "";
    // State 3: fail-closed — checkpoint step missing token_phase is
    // unpassable-by-design; no checker invocation can clear it.
    if (!requiredPhase) {
      return `→ Checkpoint "${step.name}" is unpassable (missing token_phase in the skill frontmatter) — contact the operator. No parallel_work_check invocation can clear it.`;
    }
    const tokenState = checkpointTokenOk(step, { enforceBinding: mode !== "warn" });
    if (tokenState.ok) {
      // State 2: fresh phase-correct token — do NOT re-run the checker
      // (a re-run can REMOVE the token on UNKNOWN, stranding the session).
      // #383 (Task 3): name a no-board-skip token (State-2 note) so the agent
      // understands the skip semantics it advanced on.
      // #383 (Task 3) P3-4 (code-quality): a FORCE-driven pass (viaForce) must
      // NOT be mislabeled as "a fresh token" — the force file drove the advance
      // (a re-run would SUCCEED once the file is consumed; the "do NOT re-run"
      // premise holds only for a real token). Name the operator force-pass; the
      // no-board-skip note is gated on !viaForce (a force advance never
      // consumed a skip token).
      if (tokenState.viaForce) {
        return `→ Checkpoint "${step.name}" passed via an operator force-pass (no fresh token — the force file is consumed on advance). A checker re-run would now succeed; run \`parallel_work_check ${requiredPhase}\` if you want a real token. Proceed with the next step.`;
      }
      const nbNote = tokenState.mode === "no-board-skip" ? " (no-board-skip token — the vendored checker skipped pure-board sub-checks)" : "";
      return `→ Checkpoint "${step.name}" already has a fresh phase-${requiredPhase} token${nbNote} — do NOT re-run the checker. Proceed with the next step.`;
    }
    // State 1: no-ok token — name a CLEAR-able invocation. The PRIMARY command is
    // the parent/main-checkout run (omit --repo: checkout_guard C1 DEFERs on any
    // non-main worktree branch, so --repo <own-worktree> is GUARANTEED to DEFER
    // and must NOT be the primary form). #383 (Task 3) L814 intent: resolve
    // `$AGENT_INFRA_PATH` — a REQUIRED prerequisite per AGENTS.md — there is NO
    // `$HOME/agent-infra` default fiction (agent-infra lives at
    // $HOME/Documents/GitHub/agent-infra here; pointing at a nonexistent default
    // path is worse than saying so). Guidance says 'set AGENT_INFRA_PATH' when
    // unset.
    if (mode === "warn") {
      return `→ Checkpoint "${step.name}" — warn: auto-advancing past checkpoint (audit-only). No checker run needed.`;
    }
    // #383 (Task 3): THROW-SAFE canonical resolution — PARALLEL_CHECK_BIN
    // (internal bin-location override) first, else
    // $AGENT_INFRA_PATH/scripts/parallel_work_check.sh. The printed command
    // NEVER carries an `env PARALLEL_CHECK_BIN=…` prefix — the escape-regex
    // allowlist is GH_TOKEN|CHECKOUT_GUARD_ENFORCE|AGENT_INFRA_PATH;
    // PARALLEL_CHECK_BIN is NOT allowed, so an env-prefixed print would be
    // unexecutable at the gate (Task 4's skills rewrite says the same). When
    // BOTH are absent, emit the 'set AGENT_INFRA_PATH' instruction — a
    // TypeError here would land in the tool_call handler's fail-open catch
    // (~1495-1516) and convert the pending-checkpoint BLOCK into an ALLOW,
    // silently ungating exactly the no-board consumer population this plan
    // targets (T15).
    const bin = process.env.PARALLEL_CHECK_BIN;
    const infraPath = process.env.AGENT_INFRA_PATH;
    const resolvedBin = bin || (infraPath && join(infraPath, "scripts", "parallel_work_check.sh"));
    if (!resolvedBin) {
      return `→ To proceed: set AGENT_INFRA_PATH (a required prerequisite per AGENTS.md), then run \`…/scripts/parallel_work_check.sh ${requiredPhase}\` until the verdict is CLEAR (writes the PASS token).
→ Escape tools available: read, loop_enforcer
→ If the check cannot CLEAR in this environment, the checkpoint is unpassable — end your turn and report`;
    }
    // #383 (Task 3) State-1: ENFORCE-prefix emission for the start phase (C1 is
    // the checkout_guard entry — CHECKOUT_GUARD_ENFORCE is on the escape
    // allowlist); other phases print the bare resolved path.
    const enforcePrefix = requiredPhase === "start" ? "env CHECKOUT_GUARD_ENFORCE=1 " : "";
    // T15 SET-but-NONEXISTENT variant: name the broken path, distinguishing it
    // from the unset state (the runnable form is still printed).
    // #383 (Task 3) P3-5 (code-quality): the hint ALSO fires for a ghost
    // PARALLEL_CHECK_BIN — the old `!bin` guard only covered the
    // AGENT_INFRA_PATH derivation, silently printing an unexecutable bin path.
    // `resolvedBin &&` covers BOTH sources; the note names them generically.
    const ghostHint = resolvedBin && !existsSync(resolvedBin)
      ? " (note: the resolved path does not exist — check PARALLEL_CHECK_BIN / AGENT_INFRA_PATH)"
      : "";
    return `→ To proceed: run \`${enforcePrefix}${resolvedBin} ${requiredPhase}\`${ghostHint} until the verdict is CLEAR (writes the PASS token).
→ Escape tools available: read, loop_enforcer
→ If the check cannot CLEAR in this environment, the checkpoint is unpassable — end your turn and report`;
  }
  const { allow } = getExpectedToolsForStep(step);
  if (allow.length === 0) return "";
  const tools = allow.join(", ");
  if (gate === "verifier" || gate === "ai_review") {
    return `→ Allowed tools: ${tools}
→ To proceed: dispatch a task sub-agent to review this stage, or read the sub-skill SKILL.md`;
  }
  if (gate === "human_approval" || gate === "human_review") {
    return `→ Allowed tools: ${tools}
→ To proceed: present findings to the user for approval
→ Or: end your turn to auto-advance this gate, or use /loop stop`;
  }
  return "";
}

// Proactive gate announcement — tells the agent the rules BEFORE they hit the gate.
// Called at every step transition so agents never need to guess what's allowed.
function announceGate(step: Step): void {
  const gate = step.gate || "";
  if (gate === "auto" || !gate) return;
  // #357 (Task 9): mode-aware — a warn session at a checkpoint must NOT see a
  // "run the checker" instruction (it would cause a wasted run + token churn;
  // warn auto-advances audit-only).
  const guid = gateGuidance(step, resolveMode());
  if (!guid) return;
  console.log(`[sequence-enforcer] 🔒 Gate: ${gate} — ${guid.replace(/\n→ /g, ' | ')}`);
}

export function getExpectedToolsForStep(step: Step): { allow: string[]; block: RegExp[] } {
  const gate = step.gate || "";

  // auto: allow everything, block nothing
  // ponytail: empty allow = skip allow-check (RegExp here broke strict mode + types, #7470)
  if (gate === "auto") {
    return { allow: [], block: [] };
  }
  // verifier (also matches legacy "ai_review"): only task/subagent during review
  // loop_enforcer always allowed — the gate must never block its own escape hatch (#7470)
  if (gate === "verifier" || gate === "ai_review") {
    return { allow: ["task", "subagent", "read", "loop_enforcer"], block: [/.*/] };
  }
  // human_approval (also matches legacy "human_review"): only read/search/fetch during approval
  if (gate === "human_approval" || gate === "human_review") {
    return { allow: ["read", "web_search", "web_fetch", "loop_enforcer"], block: [/.*/] };
  }
  // checkpoint (issue #5039): token-gated — validateToolCall blocks everything
  // until a fresh phase-correct CLEAR token exists, EXCEPT the #357 (d) escape
  // (read/loop_enforcer/sole-command checker). The allow list here mirrors the
  // escape so audit entries reflect what an agent may actually use at the gate.
  if (gate === "checkpoint") {
    return { allow: ["read", "loop_enforcer"], block: [] };
  }
  // No gate or unknown — standard work phase. Block destructive ops.
  return { allow: [], block: [GIT_OP, DESTRUCTIVE_MCP] };
}

// #201: does this call satisfy gate-mode blocking semantics? Shared by gate
// mode (actual block) and warn mode (would-block audit). allow-list wins —
// prevents deadlock when a gate blocks its own resolution tools.
function wouldBlockUnderGate(
  toolName: string,
  command: unknown,
  expected: { allow: string[]; block: RegExp[] },
): boolean {
  if (expected.allow.length > 0 && expected.allow.includes(toolName)) return false;
  const target = typeof command === "string" ? command : String(command ?? "") || toolName;
  for (const pattern of expected.block) {
    if (pattern.test(target)) return true;
  }
  return false;
}

// #201: audit context for blocked/would-block entries — `allowed` lists the
// permitted tools and `hint` carries gate guidance, so orchestrators reading
// enforcement.jsonl can see WHY a worker is stuck and what the exit is.
// `reason` is preserved from the original blocked entries (backward-compat).
function blockAuditEntry(event: string, toolName: string, step: Step, mode: Mode, reason = ""): Record<string, unknown> {
  const expected = getExpectedToolsForStep(step);
  return {
    ts: new Date().toISOString(),
    event,
    skill: topSkill()?.path,
    step: step.name,
    tool: toolName,
    mode,
    reason,
    allowed: expected.allow,
    hint: gateGuidance(step, mode),
  };
}

export function validateToolCall(
  toolName: string, command: unknown, step: Step, mode: Mode,
): { block: boolean; reason?: string; wouldBlock?: boolean; freshTokenBlock?: boolean } {
  // #357 (Task 5): validateToolCall is PURE — it never writes audit. The
  // handler owns every audit write (single-audit: one entry per blocked /
  // would-block / allowed call). wouldBlock signals warn-mode would-block so
  // the handler can write ONE warn_blocked entry and skip the allowed entry.
  // checkpoint gate (issue #5039): fail-closed token validation. A missing,
  // stale, wrong-phase, non-CLEAR, or corrupt token blocks the step entirely
  // (retry + the operator force-pass are the documented escape). Computed up front
  // so warn mode can report would-block for checkpoint steps too. #383 (Task 3):
  // the mode-aware wrapper — binding is enforced in gate/strict only (warn is
  // binding-free; a warn session auto-advances audit-only).
  const checkpoint = step.gate === "checkpoint" ? checkpointTokenOk(step, { enforceBinding: mode !== "warn" }) : null;

  if (mode === "warn") {
    // #201: warn_blocked ONLY when the call would have been blocked under gate
    // mode — orchestrator signal without per-call spam.
    const wouldBlock = checkpoint
      ? !checkpoint.ok
      : wouldBlockUnderGate(toolName, command, getExpectedToolsForStep(step));
    console.log(
      `[sequence-enforcer] ⚠️ warn: ${toolName} | step="${step.name}" gate="${step.gate || "none"}"${wouldBlock ? " — would block under gate mode" : ""}`,
    );
    return { block: false, wouldBlock };
  }

  // #357 (Task 6, d): checkpoint escape + guards (gate/strict only — warn never
  // blocks). EVALUATION ORDER (P1): the HANDLER evaluates the (c) token-ok
  // advancement FIRST (blocked-call rule, Task 7) and validates this call
  // against the CAPTURED pre-advance step object. So at an ok-checkpoint the
  // (d) guards below run against the step the call was made at — a checker
  // re-run is blocked (token_fresh; the step has already moved) while
  // non-checker tools proceed; at a pending checkpoint the escape is the only
  // pass.
  if (step.gate === "checkpoint" && (mode === "gate" || mode === "strict")) {
    // Defensive type-guard (P1): a non-string / missing bash command is a
    // fail-closed BLOCK — never throw into the handler (a throw could fail-open
    // the gate or take down the enforcement chain).
    if (toolName === "bash" && typeof command !== "string") {
      return { block: true, reason: `⛔ checkpoint gate — step "${step.name}" bash call is malformed (command missing or non-string) — BLOCK (fail-closed)` };
    }
    if (checkpoint?.ok) {
      // Fresh phase-correct token in place: read/loop_enforcer stay allowed
      // (the gate must never block its own escape, #7470); a checker re-run is
      // BLOCKED by the checkpoint_token_fresh execution guard — re-running
      // can REMOVE the valid token (checker writes only on CLEAR; UNKNOWN
      // deletes it), stranding the session.
      // #357 review (Historical-context P2): NON-checker tools are NOT blocked
      // here — the handler's blocked-call rule has ALREADY advanced the step
      // (the fresh token satisfied the gate), so this call proceeds and the
      // NEXT call is validated against the next step. Blocking the advancing
      // call would contradict step-entry guidance ("proceed with the next
      // step") and burn a blocked audit entry in the success path.
      if (toolName === "read" || toolName === "loop_enforcer") return { block: false };
      if (toolName === "bash" && CHECKPOINT_ESCAPE_RE.test(command)) {
        return { block: true, freshTokenBlock: true, reason: `⛔ checkpoint gate — step "${step.name}" already has a fresh phase-correct token — do NOT re-run the checker (a re-run can REMOVE the token on UNKNOWN)` };
      }
      return { block: false };
    }
    // No fresh token — the escape is the ONLY way out: read, loop_enforcer,
    // or the sole-command checker invocation (CLEAR-able). Everything else
    // fails closed with the token reason + escape guidance.
    if (isCheckpointEscape(toolName, command)) {
      // #357 (Task 7): wrong-phase guard (checkpoint_token_fresh extension) —
      // a checker bash whose phase ≠ this step's token_phase would write a
      // token that can NEVER satisfy this checkpoint → block with guidance
      // (prevents the wrong-phase strand at a pending checkpoint).
      if (toolName === "bash" && typeof command === "string") {
        const phase = checkpointEscapePhase(command);
        if (phase !== null && step.token_phase && phase !== step.token_phase) {
          return { block: true, reason: `⛔ checkpoint gate — step "${step.name}" requires phase "${step.token_phase}" but the checker would write phase "${phase}" — run \`parallel_work_check ${step.token_phase}\` instead` };
        }
      }
      return { block: false };
    }
    return { block: true, reason: checkpoint?.reason ?? `⛔ checkpoint gate — step "${step.name}" requires a fresh parallel_work_check PASS token` };
  }

  if (checkpoint && !checkpoint.ok) {
    return { block: true, reason: checkpoint.reason };
  }

  const expected = getExpectedToolsForStep(step);

  if (mode === "strict") {
    // strict = gate's destructive blocking + allow-list enforcement for gated steps
    for (const pattern of expected.block) {
      const target = command || toolName;
      if (pattern.test(target)) {
        return {
          block: true,
          reason: `⛔ strict — step "${step.name}" (gate: ${step.gate}) blocks this operation`,
        };
      }
    }
    if (expected.allow.length > 0 && !expected.allow.includes(toolName)) {
      return {
        block: true,
        reason: `⛔ strict — step "${step.name}" (gate: ${step.gate}) only allows: ${expected.allow.join(", ")}`,
      };
    }
    return { block: false };
  }

  // gate mode: allow-list takes precedence, then destructive blocking
  if (wouldBlockUnderGate(toolName, command, expected)) {
    return {
      block: true,
      reason: `⛔ gate — step "${step.name}" (gate: ${step.gate}) blocks this operation`,
    };
  }

  return { block: false };
}

// #357 (Task 7, c): test seam for the marker-map bound (cap/evict under
// sustained blocked calls — blocked calls emit no tool_result → markers leak).
export function _markerCountForTest(): number {
  return process.env.NODE_ENV === "test" ? markers.size : 0;
}

// #357 (Task 8, j): park-only checkpoint recovery. A gate-mode session at an
// un-CLEAR-able checkpoint retries forever (blocked calls re-arm the 10-min
// timer; a read-spamming worker never accumulates a consecutive-block streak).
// Recovery = PARK (state preserved — never pop: pop → re-read/re-pop loop +
// silent enforcement loss), one-shot per checkpoint (keyed path#stepIndex).
// Triggers: ≥3 consecutive blocked calls OR a wall-clock stall (> 5 min current
// without advance) — wall-clock is the AUTHORITATIVE trigger (reads reset the
// streak; a fully idle session still parks via the sequence timer).
const CHECKPOINT_BLOCK_STREAK_LIMIT = 3;
const WALL_CLOCK_STALL_MS = 5 * 60 * 1000;
let checkpointBlockStreak: { key: string; count: number } | null = null;
const parkedCheckpoints = new Set<string>();

// Audit-volume bound (#357 Task 8): a relentless retry loop writes one blocked
// entry per call (~86k/day at 1s cadence) into a human-read JSONL. Coalesce:
// for the same (skill.path, stepIndex), only the first 20 blocked entries per
// 60s window are written; the rest are skipped (the signal is already there).
const auditCoalesce = new Map<string, { count: number; windowStart: number }>();
const AUDIT_COALESCE_LIMIT = 20;
const AUDIT_COALESCE_WINDOW_MS = 60_000;
function shouldCoalesceBlocked(key: string): boolean {
  const now = Date.now();
  const rec = auditCoalesce.get(key);
  if (!rec || now - rec.windowStart > AUDIT_COALESCE_WINDOW_MS) {
    auditCoalesce.set(key, { count: 1, windowStart: now });
    return false;
  }
  rec.count++;
  return rec.count > AUDIT_COALESCE_LIMIT;
}

function checkpointKey(skill: SkillState): string {
  return `${skill.path}#${skill.stepIndex}`;
}

// Park: preserve stack/stepIndex/reviewers, audit the recovery event, one-shot.
function parkCheckpoint(skill: SkillState, reason: string): void {
  const key = checkpointKey(skill);
  if (parkedCheckpoints.has(key)) return; // one-shot per checkpoint
  parkedCheckpoints.add(key);
  console.log(`[sequence-enforcer] 🅿️ Checkpoint recovery — parking "${skill.path}" at step ${skill.stepIndex} (${reason}) — state preserved`);
  auditLog({ ts: new Date().toISOString(), event: "checkpoint_block_recovery", skill: skill.path, step: skill.stepIndex, reason });
}

// ── Test seams (honored only under NODE_ENV=test) ─────

export function _pushSkillForTest(path: string, steps: Step[], stepIndex = 0): void {
  if (process.env.NODE_ENV !== "test") return;
  skillStack.push({ path, steps, stepIndex, stepStartedAt: Date.now(), reviewers: new Map() });
}

export function _stackForTest(): SkillState[] {
  return process.env.NODE_ENV === "test" ? skillStack : [];
}

export function _resetStateForTest(): void {
  if (process.env.NODE_ENV !== "test") return;
  skillStack = [];
  stepCache.clear();
  // #357 (Task 8): reset recovery state — a prior test's park (one-shot) or
  // streak must not bleed into the next test (same skill path → same key).
  checkpointBlockStreak = null;
  parkedCheckpoints.clear();
  auditCoalesce.clear();
  markers.clear();
  currentRepoCache = null;
  envRepoCache = null; // #383 (Task 3) P2-2/P3: reset the env+cwd-keyed repo cache with the rest
  repoTestOverride = null;
  FORCE_FILE_OVERRIDE = null;
  TOKEN_FILE_OVERRIDE = null; // #357 review (Historical P3): reset-contract completeness — a stale token path must not leak into the next test
  // #377: reset-contract completeness — a session id captured by one test must
  // not bleed into the next (the override is cleared to its inactive default;
  // the captured id is dropped so the next session_start/ctx re-resolves).
  auditSessionOverride = { active: false, id: null };
  auditSessionId = null;
  if (sequenceTimeout) { clearTimeout(sequenceTimeout); sequenceTimeout = null; }
}

// ── Extension ────────────────────────────────────────

export default function (pi: ExtensionAPI) {
  // ── session_start ──────────────────────────────
  pi.on("session_start", async (event, _ctx) => {
    stepCache.clear();
    skillStack = [];
    // #377: capture the pi session id BEFORE the startup audit write so the
    // first entry of every session is attributable. ctx.sessionManager is the
    // authoritative in-process source.
    captureAuditSession(_ctx);
    // #357 review (Extension-safety P1): the module-level recovery state is
    // per-session — pi reuses the module scope across /new /resume /fork, so a
    // parked checkpoint, a partial block-streak, a coalesce window, or stale
    // markers MUST NOT bleed into the next session (one-shot suppression would
    // silently swallow the recovery signal; a 1-2 streak would pre-park).
    markers.clear();
    parkedCheckpoints.clear();
    checkpointBlockStreak = null;
    auditCoalesce.clear();
    if (sequenceTimeout) { clearTimeout(sequenceTimeout); sequenceTimeout = null; } // cycle 2: a stale timer must never fire into a new session
    // ponytail: kill switch is a single-session escape — clear stale switches so new
    // sessions don't start silently bypassed (#7470). Env var bypass is unaffected.
    try {
      if (existsSync(KILL_SWITCH_FILE)) {
        unlinkSync(KILL_SWITCH_FILE);
        console.log("[sequence-enforcer] 🧹 Cleared stale kill switch from previous session");
      }
      // #357 (Task 10, h): session_start cleanup mirrors the kill-switch hygiene.
      // Documented machine-shared hazard: any new session's start unlinks a
      // lingering operator force file (per-session scoping is the filed issue).
      // #357 review (Extension-safety P2): scoped to NEW sessions — a mid-session
      // /reload must not discard the operator's bypass for the CURRENT session.
      if (existsSync(forceFile())) {
        if ((event as any)?.reason === "reload") {
          console.log("[sequence-enforcer] ⏸️  session reload — leaving operator force-pass file in place");
        } else {
          unlinkSync(forceFile());
          console.log("[sequence-enforcer] 🧹 Cleared stale force-pass file from previous session");
        }
      }
    } catch { /* best-effort */ }
    if (isKillSwitchActive()) {
      console.log("[sequence-enforcer] ⏸️  Kill switch active — all enforcement bypassed");
    } else {
      const mode = resolveMode();
      auditLog({ ts: new Date().toISOString(), event: "startup", mode });
      console.log(`[sequence-enforcer] ✅ Loaded — mode: ${mode}`);
      // #357 review (pr-comment-history P2): when a session resolves warn via
      // ARGV (bare-shell `pi -p`, no PI_MODE env — the #201 carve-out reversal
      // class), name the enforcement now audit-only so the session log reader
      // knows the verifier-step allow-list is not enforced and how to restore it.
      // (cycle 2): skip when an EXPLICIT warn override is set — that warn is
      // deliberate, not an argv-detected default. (cycle 3): mode-file warn
      // counts as explicit too (a deliberate operator file is misdiagnosed
      // as an argv default).
      const modeFileWarn = (() => {
        try { return readFileSync(MODE_FILE, "utf-8").split("\n")[0]!.trim() === "warn"; } catch { return false; }
      })();
      const explicitOverride = !!(process.env.AGENT_SEQUENCE_MODE || process.env.ELDATO_SEQUENCE_MODE || process.env.PI_ENFORCER_MODE) || modeFileWarn;
      if (mode === "warn" && !explicitOverride && !isPrintModeEnv(process.env) && isPrintMode(process.env, process.argv)) {
        console.warn("[sequence-enforcer] ⚠️ warn default via argv-detected print (bare-shell pi -p, no PI_MODE) — verifier-step allow-list NOT enforced; AGENT_SEQUENCE_MODE=gate restores it");
      }
    }
  });

  // ── session_shutdown ───────────────────────────
  pi.on("session_shutdown", async (_event, _ctx) => {
    // #377: session ended — drop the captured id so a hypothetical stale write
    // between sessions can never be misattributed to the previous session.
    auditSessionId = null;
    stepCache.clear();
    skillStack = [];
    // #357 review: same per-session hygiene as session_start.
    markers.clear();
    parkedCheckpoints.clear();
    checkpointBlockStreak = null;
    auditCoalesce.clear();
    if (sequenceTimeout) { clearTimeout(sequenceTimeout); sequenceTimeout = null; }
    clearBridgeState();
  });

  // ── agent_end ──────────────────────────────────
  // ponytail: advance past human_review gates (resolved between turns), preserve state
  pi.on("agent_end", async (_event, _ctx) => {
    // #377: refresh at the agent boundary — a session may be forked/restored
    // between turns without a fresh session_start; ctx is always authoritative.
    captureAuditSession(_ctx);
    const top = topSkill();
    if (!top) return;
    const step = top.steps[top.stepIndex];
    // ponytail: human_approval and human_review are aliases everywhere else — advance both (#7470)
    if (step?.gate === "human_review" || step?.gate === "human_approval") {
      const next = top.stepIndex + 1;
      if (next < top.steps.length) {
        top.stepIndex = next;
        top.stepStartedAt = Date.now();
        console.log(
          `[sequence-enforcer] ⏩ Advanced past human_review → step ${next}/${top.steps.length}: ${top.steps[next]!.name}`,
        );
        announceGate(top.steps[next]!);
        writeBridgeState();
      } else {
        console.log(
          `[sequence-enforcer] ✅ All ${top.steps.length} steps completed`,
        );
        // ponytail: pop completed skill, restore parent (#7265)
        skillStack.pop();
        const parent = topSkill();
        if (parent) {
          console.log(`[sequence-enforcer] ↩ Restored parent: ${parent.path}`);
          writeBridgeState();
        } else {
          clearBridgeState();
        }
      }
    }
  });

  // ── tool_call: track skill reads ───────────────
  pi.on("tool_call", async (event, _ctx) => {
    if (!isToolCallEventType("read", event)) return undefined;
    const path = String((event.input as any)?.path ?? "");
    if (!path.includes("SKILL.md")) return undefined;

    const top = topSkill();
    // ponytail: if same skill is already on top, preserve state (human_review advancement across turns)
    if (top && top.path === path) return undefined;

    // Auto-advance current top past remaining auto-gated steps (#7222)
    if (top) {
      let advanced = 0;
      for (let i = top.stepIndex; i < top.steps.length; i++) {
        if (top.steps[i]!.gate === "auto") {
          advanced++;
        } else {
          break; // stop at first non-auto gate
        }
      }
      if (advanced > 0) {
        top.stepIndex += advanced;
        // #357 review (Bug-scan P2): auto-advancing into a checkpoint step must
        // restart its stall clock — otherwise auto steps spanning >5 min of wall
        // time leave a stale stepStartedAt and the FIRST call at the freshly-
        // reached checkpoint fires a spurious wall-clock park.
        top.stepStartedAt = Date.now();
        // If all steps are now completed (past last step):
        if (top.stepIndex >= top.steps.length) {
          console.log(
            `[sequence-enforcer] ⏩ Auto-advanced ${advanced} step(s) → completed "${top.path}"`,
          );
          skillStack.pop();
          const parent = topSkill();
          if (parent) {
            console.log(`[sequence-enforcer] ↩ Restored parent: ${parent.path}`);
            writeBridgeState();
          } else {
            clearBridgeState();
          }
        } else {
          console.log(
            `[sequence-enforcer] ⏩ Auto-advanced ${advanced} step(s) → now at step ${top.stepIndex}/${top.steps.length}: ${top.steps[top.stepIndex]!.name}`,
          );
          announceGate(top.steps[top.stepIndex]!);
          writeBridgeState();
        }
      }
    }

    const steps = loadSteps(path);
    // ponytail: skills with no steps are reference docs — don't affect stack (#7265)
    if (!steps) { writeBridgeState(); return undefined; }

    // ponytail: in main checkout, track the read but don't activate the pipeline.
    // Skill maintainers reading a SKILL.md are editing, not executing (#7487).
    // Detection: in a worktree, git-common-dir is the shared .git; the
    // worktree's top/.git is a separate file — they differ. In main they match.
    const inWorktree = (() => {
      try {
        const top = execFileSync("git", ["rev-parse", "--show-toplevel"], { encoding: "utf-8", timeout: 5000 }).trim();
        const common = resolve(execFileSync("git", ["rev-parse", "--git-common-dir"], { encoding: "utf-8", timeout: 5000 }).trim());
        return `${top}/.git` !== common;
      } catch { return true; } // if git fails, assume worktree (safer: let pipeline run)
    })();
    if (!inWorktree) {
      console.log(`[sequence-enforcer] 📖 Read ${path} (main checkout — pipeline not activated)`);
      writeBridgeState();
      return undefined;
    }

    // Push new skill onto stack (replace if top was completed & popped above)
    skillStack.push({ path, steps, stepIndex: 0, stepStartedAt: Date.now(), reviewers: new Map() });
    // #357 (Task 3) F2: lazily warn when a skill activates with checkpoint
    // steps that will fail-closed (missing token_phase) — diagnose, don't let
    // the hard-block be the only signal. Fires at activation (stack/stepCache
    // are empty at session_start; a full-scan would python-spawn per skill).
    const failClosed = steps.filter((s) => s.gate === "checkpoint" && !s.token_phase);
    if (failClosed.length > 0) {
      console.log(
        `[sequence-enforcer] ⚠️ F2: ${path} has checkpoint step(s) missing token_phase — fail-closed: ${failClosed.map(s => s.name).join(", ")}`,
      );
    }
    console.log(
      `[sequence-enforcer] 📖 Activated: ${path} (${steps.length} steps: ${steps.map(s => s.name).join(" → ")})`,
    );
    if (steps.length > 0) announceGate(steps[0]!);
    writeBridgeState();
    return undefined;
  });

  // ── tool_call: enforce step sequence ───────────
  // Deployment-order assumption (#357 review, Extension-safety P2): extensions
  // load in OS directory order (loader.js discoverExtensionsInDir) — a blocker
  // registered BEFORE this handler (main-worktree-guard, review-enforcer) may
  // intercept a call before checkpoint advancement/audit. That only DELAYS the
  // advance (fail-safe — the next unblocked call advances), never bypasses the
  // gate. The read-tracker above is guaranteed FIRST within this file by
  // registration order.
  pi.on("tool_call", async (event, _ctx) => {
    // #357 review (Extension-safety P1): emitToolCall has NO per-handler
    // try/catch (runner.js) — a throw would error the tool call AND skip every
    // remaining tool_call blocker (skill-enforcer, verification-gate, ...). The
    // body is type-guarded fail-closed, but belt-and-suspenders: on an
    // unexpected throw, audit handler_error and fail open (allow) so the tool
    // chain survives; the other blockers still run.
    try {
    // #377: refresh the session id at the audit-writing boundary (a session
    // can fork/restore mid-process without session_start).
    captureAuditSession(_ctx);
    const top = topSkill();
    const toolName = (event as any).toolName ?? event.toolName ?? "";
    if (isKillSwitchActive()) {
      auditLog({ ts: new Date().toISOString(), event: "bypassed", reason: "kill_switch", tool: toolName });
      return undefined;
    }
    if (!top) return undefined;
    resetSequenceTimeout();

    const step = top.steps[top.stepIndex];
    if (!step) return undefined;
    // #357 (Task 6): pass the RAW command shape (no String() coercion) so the
    // checkpoint branch's malformed-event type-guard can distinguish a missing /
    // non-string command and fail closed instead of throwing.
    const command = isToolCallEventType("bash", event)
      ? (event.input as any)?.command ?? ""
      : "";

    const mode = resolveMode();

    // #357 (Task 7, c): checkpoint branch — mode-independent advancement + marker
    // contract. SINGLE advancement rule: token-ok drives advancement, never
    // call-type. Owner via stack-walk FIRST (a sub-skill read sits above the
    // owner; top's step may be auto while the owner waits at its checkpoint).
    const checkpointOwner = findCheckpointGateOwner();
    if (checkpointOwner) {
      const target = checkpointOwner;
      const ownerStep = target.steps[target.stepIndex];
      if (!ownerStep || ownerStep.gate !== "checkpoint") return undefined;
      const toolCallId = (event as any).toolCallId ?? "";
      // #383 (Task 3): the mode-aware wrapper — binding is enforced in
      // gate/strict only (warn is binding-free).
      const tokenState = checkpointTokenOk(ownerStep, { enforceBinding: mode !== "warn" });
      const checkpointIndex = target.stepIndex;

      // #357 (Task 8, j): wall-clock is the AUTHORITATIVE trigger — evaluated per
      // tool_call against stepStartedAt (allowed reads reset the consecutive-block
      // streak; only the wall-clock catches a worker that never accumulates blocks).
      // (cycle 2): skipped in warn mode — the first call auto-advances anyway, so
      // a park would be recovery-signal noise in a success path.
      if (mode !== "warn" && Date.now() - target.stepStartedAt > WALL_CLOCK_STALL_MS) {
        parkCheckpoint(target, "wall-clock stall (>5 min current without advance)");
      }

      // Warn precedence: the FIRST call at a checkpoint advances regardless of
      // tool (warn is audit-only); checkpoint_skipped_warn is the ONLY audit for
      // the call (advance precedes would-block evaluation — no double
      // warn_blocked + checkpoint_skipped_warn).
      if (mode === "warn") {
        // #357 review: consume a present passable force file on a warn-mode
        // advance too — warn auto-advances without honoring it, but the one-shot
        // invariant must not leave the operator's file to pass a later same-phase
        // gate. Consumed BEFORE advanceCheckpoint (cycle 3, announceGate accuracy).
        // #383 (Task 3): the warn site passes a FORCE-SUPPRESSED context — warn
        // auto-advances without honoring the file, so the force file never
        // actually DROVE the pass (the mode-qualified viaForce criterion; flipped
        // warn-mode-consume test: consumed, no checkpoint_force_pass audit).
        consumeForceFile(target, ownerStep.name, mode, ownerStep.token_phase ?? "", { viaForce: false });
        advanceCheckpoint(target);
        auditLog({ ts: new Date().toISOString(), event: "checkpoint_skipped_warn", skill: target.path, step: ownerStep.name, tool: toolName, mode, token_state: tokenStateLabel(tokenState.reason), hint: gateGuidance(ownerStep, "warn") });
        return undefined;
      }

      if (tokenState.ok) {
        // Blocked-call rule (pinned): advancement is evaluated FIRST (token-ok at
        // tool_call); the call is THEN validated against the CAPTURED checkpoint
        // step — a blocked call at an ok-checkpoint has already advanced (the
        // token satisfied the gate), and the advancing call is never re-validated
        // against the next step.
        // #357 (Task 10, h): a checkpoint advance consumes a PRESENT passable
        // force file (one-shot invariant: the file can never pass a same-phase
        // adjacent checkpoint). Consumed BEFORE advanceCheckpoint (cycle 3):
        // announceGate(next) must not claim "fresh token" for the next
        // checkpoint based on a file deleted microseconds later. The call is
        // STILL validated against the captured step: with a force consumed and
        // no real token, the pending-checkpoint escape semantics apply; with a
        // real token, the ok-checkpoint token_fresh guard.
        // #383 (Task 3): viaForce context — a real-token-wins consume unlinks
        // but emits NO checkpoint_force_pass (the force file did not drive the
        // pass; flipped real-token-wins test).
        consumeForceFile(target, ownerStep.name, mode, ownerStep.token_phase ?? "", { viaForce: tokenState.viaForce === true });
        // #383 (Task 3): the skip audit is emitted AT the token-driven advance
        // branch, keyed on the MODE-AWARE token check's result — ok && mode ===
        // "no-board-skip" && !viaForce. NEVER inside checkpointTokenOk (it runs
        // at all four call sites → 2-4× per advance + on non-advancing calls;
        // T6(f) pins exactly ONE per advance). A force-driven advance (viaForce)
        // must not emit a spurious skip audit (T6(h)); a board-mode token
        // (mode "") must not (T6(a)).
        if (tokenState.ok && tokenState.mode === "no-board-skip" && !tokenState.viaForce) {
          auditLog({
            ts: new Date().toISOString(),
            event: "checkpoint_no_board_skip",
            skill: target.path,
            step: ownerStep.name,
            tool: toolName,
            mode,
            token_mode: tokenState.mode,
            phase: ownerStep.token_phase ?? "",
            repo: bindingRepo(),
          });
        }
        advanceCheckpoint(target);
        const result = validateToolCall(toolName, command, ownerStep, mode);
        if (result.block) {
          const trail = target.steps
            .map((s, i) => i === checkpointIndex ? `[${s.name}]` : s.name)
            .join(" → ");
          console.log(`[sequence-enforcer] 🚫 Blocked ${toolName}: ${result.reason}`);
          const guidance = gateGuidance(ownerStep);
          // #357 review (cycle 2): the coalesce key must reference the step the
          // call was made at — checkpointKey(target) AFTER advanceCheckpoint
          // would key the NEXT step (checkpointKey reads skill.stepIndex). The
          // captured checkpointIndex is the pre-advance step.
          const key = `${target.path}#${checkpointIndex}`;
          if (!shouldCoalesceBlocked(key)) {
            auditLog({ ts: new Date().toISOString(), event: result.freshTokenBlock ? "checkpoint_token_fresh" : "blocked", skill: target.path, step: ownerStep.name, tool: toolName, mode, reason: result.reason, allowed: getExpectedToolsForStep(ownerStep).allow, hint: guidance });
          }
          return {
            block: true,
            reason: `${result.reason}\n  → Sequence: ${trail}${guidance ? "\n" + guidance : ""}`,
          };
        }
        // allowed at an ok-checkpoint → ok marker (same-call suppression: its
        // tool_result must NOT re-advance — the step already moved).
        recordMarker(toolCallId, { skill: target, stepIndex: checkpointIndex, ok: true });
        auditLog({ ts: new Date().toISOString(), event: "allowed", skill: target.path, step: ownerStep.name, tool: toolName, mode });
        return undefined;
      }

      // token NOT ok — the escape is the only way out; record an ok:false marker
      // for allowed calls so a producer-timing tool_result (!ok@call → ok@result)
      // can advance. Blocked calls never advance and emit no marker.
      const result = validateToolCall(toolName, command, ownerStep, mode);
      if (result.block) {
        const key = checkpointKey(target);
        // #357 (Task 8, j): consecutive-block streak — ≥3 → park immediately.
        if (checkpointBlockStreak?.key === key) checkpointBlockStreak.count++;
        else checkpointBlockStreak = { key, count: 1 };
        if (checkpointBlockStreak.count >= CHECKPOINT_BLOCK_STREAK_LIMIT) {
          parkCheckpoint(target, `${checkpointBlockStreak.count} consecutive blocked calls`);
        }
        const trail = target.steps
          .map((s, i) => i === checkpointIndex ? `[${s.name}]` : s.name)
          .join(" → ");
        console.log(`[sequence-enforcer] 🚫 Blocked ${toolName}: ${result.reason}`);
        const guidance = gateGuidance(ownerStep);
        if (!shouldCoalesceBlocked(key)) {
          auditLog({ ts: new Date().toISOString(), event: "blocked", skill: target.path, step: ownerStep.name, tool: toolName, mode, reason: result.reason, allowed: getExpectedToolsForStep(ownerStep).allow, hint: guidance });
        }
        return {
          block: true,
          reason: `${result.reason}\n  → Sequence: ${trail}${guidance ? "\n" + guidance : ""}`,
        };
      }
      // allowed escape call → resets the consecutive-block streak (mixed spam).
      checkpointBlockStreak = null;
      recordMarker(toolCallId, { skill: target, stepIndex: checkpointIndex, ok: false });
      auditLog({ ts: new Date().toISOString(), event: "allowed", skill: target.path, step: ownerStep.name, tool: toolName, mode });
      return undefined;
    }

    const result = validateToolCall(toolName, command, step, mode);

    if (result.block) {
      const trail = top.steps
        .map((s, i) => i === top.stepIndex ? `[${s.name}]` : s.name)
        .join(" → ");
      console.log(`[sequence-enforcer] 🚫 Blocked ${toolName}: ${result.reason}`);
      const guidance = gateGuidance(step);
      // #357 (Task 5): handler owns the single blocked audit entry
      // (#201: enriched with allowed/hint gate context).
      auditLog({ ts: new Date().toISOString(), event: "blocked", skill: top.path, step: step.name, tool: toolName, mode, reason: result.reason, allowed: getExpectedToolsForStep(step).allow, hint: guidance });
      return {
        block: true,
        reason: `${result.reason}\n  → Sequence: ${trail}${guidance ? "\n" + guidance : ""}`,
      };
    }

    // #357 (Task 5): warn-mode would-block — ONE warn_blocked entry, and skip
    // the unconditional allowed entry (single-audit at every gate).
    if (result.wouldBlock) {
      auditLog(blockAuditEntry("warn_blocked", toolName, step, mode, `would block under gate mode (gate: ${step.gate || "none"})`));
      const guidance = gateGuidance(step);
      if (guidance) console.log(`[sequence-enforcer] ${guidance.replace(/\n/g, "\n[sequence-enforcer] ")}`);
      return undefined;
    }

    // Track verifier dispatches: count task/subagent calls for verifier gate.
    // Must use findVerifierGateOwner() — not top — because a sub-skill read
    // by a sub-agent sits above the verifier gate on the stack. top's step
    // would be auto-gated, causing the dispatch to never be counted (#66).
    if (toolName === "task" || toolName === "subagent") {
      const gateOwner = findVerifierGateOwner();
      if (gateOwner) {
        const current = gateOwner.reviewers.get(gateOwner.stepIndex) || 0;
        gateOwner.reviewers.set(gateOwner.stepIndex, current + 1);
      }
    }

    auditLog({ ts: new Date().toISOString(), event: "allowed", skill: top.path, step: step.name, tool: toolName, mode });
    return undefined;
    } catch (e) {
      // #357 review (cycle 2, Bug-scan P2): fail-open is DELIBERATE — a
      // fail-closed block here would (a) skip the later tool_call blockers
      // (emitToolCall stops at the first {block:true}: skill-enforcer,
      // verification-gate never run) and (b) recreate the #357 deadlock class
      // if the throw persisted (every call blocked with no in-session escape,
      // read included). All internal I/O is guarded (writeBridgeState,
      // checkpointTokenOk, readForceFile, auditLog are try/caught), so the
      // realistic throw surface is ~zero; the handler_error audit + this
      // console.warn make any unexpected throw loud, and the other tool_call
      // blockers still run.
      console.warn(`[sequence-enforcer] ⚠️ enforcement handler_error: ${String(e)}`);
      auditLog({ ts: new Date().toISOString(), event: "handler_error", handler: "enforcement", error: String(e) });
      return undefined; // fail-safe allow + loud audit; other blockers still run
    }
  });

  // #357 (Task 7, c): classify the token state for checkpoint_skipped_warn audits.
function tokenStateLabel(reason: string): string {
  if (!reason) return "ok";
  if (reason.includes("stale")) return "stale";
  if (reason.includes("token_phase") || reason.includes("≠ required")) return "missing-or-wrong-phase";
  if (reason.includes("corrupt")) return "corrupt";
  if (reason.includes("none found")) return "none";
  return "other";
}

// ── tool_result: advance step on gate fulfillment ──
  pi.on("tool_result", async (event, _ctx) => {
    // #377: refresh the session id at the audit-writing boundary.
    captureAuditSession(_ctx);
    const top = topSkill();
    if (isKillSwitchActive()) {
      auditLog({ ts: new Date().toISOString(), event: "bypassed", reason: "kill_switch", tool: event.toolName });
      return undefined;
    }
    if (!top) return undefined;
    resetSequenceTimeout();

    // #357 (Task 7, c): checkpoint advancement via the marker contract — the
    // producer-timing case: an escape call (or operator-written token) transitions
    // !ok@call → ok@result; its tool_result advances the checkpoint owner. Stale
    // markers (owner popped, or a sibling already advanced past the marker's
    // stepIndex) are rejected — no double-advance.
    const toolCallId = (event as any).toolCallId ?? "";
    if (toolCallId && markers.has(toolCallId)) {
      const marker = markers.get(toolCallId)!;
      markers.delete(toolCallId);
      if (skillStack.indexOf(marker.skill) === -1) return undefined; // owner popped
      if (marker.skill.stepIndex !== marker.stepIndex) return undefined; // sibling advanced
      const ownerStep = marker.skill.steps[marker.skill.stepIndex];
      if (!ownerStep || ownerStep.gate !== "checkpoint") return undefined;
      // #383 (Task 3): the mode-aware wrapper (binding in gate/strict only).
      const markerMode = resolveMode();
      const st = checkpointTokenOk(ownerStep, { enforceBinding: markerMode !== "warn" });
      if (!marker.ok && st.ok) {
        // #357 review: same any-advance consumption (real-token-wins included);
        // consumed BEFORE advanceCheckpoint so announceGate(next) sees the
        // post-consumption token state (cycle-3 P3).
        // #383 (Task 3): viaForce context + the skip audit — the canonical
        // gate-mode no-board flow (pending checkpoint → checker run as the
        // escape call → token produced → marker advance). The ~1550 site gets
        // the same viaForce criterion (T6(g)) and the same skip-audit key
        // (ok && mode === "no-board-skip" && !viaForce).
        consumeForceFile(marker.skill, ownerStep.name, markerMode, ownerStep.token_phase ?? "", { viaForce: st.viaForce === true });
        if (st.ok && st.mode === "no-board-skip" && !st.viaForce) {
          auditLog({
            ts: new Date().toISOString(),
            event: "checkpoint_no_board_skip",
            skill: marker.skill.path,
            step: ownerStep.name,
            tool: String((event as any)?.toolName ?? ""),
            mode: markerMode,
            token_mode: st.mode,
            phase: ownerStep.token_phase ?? "",
            repo: bindingRepo(),
          });
        }
        advanceCheckpoint(marker.skill); // token produced by this call's completion
      }
      return undefined;
    }

    // ponytail: find gate owner for verifier advancement (#7274, #7275).
    // Task results must advance the skill that owns the verifier gate,
    // not necessarily the top of the stack.
    const gateOwner = findVerifierGateOwner();
    const step = gateOwner
      ? gateOwner.steps[gateOwner.stepIndex]!
      : top.steps[top.stepIndex];
    if (!step) return undefined;

    const targetSkill = gateOwner ?? top;

    // Count dispatched reviewers for verifier gate
    if (
      step.gate === "verifier" &&
      (event.toolName === "task" || event.toolName === "subagent")
    ) {
      const current = targetSkill.reviewers.get(targetSkill.stepIndex) || 0;
      if (current > 0) {
        const count = current - 1;
        if (count > 0) {
          targetSkill.reviewers.set(targetSkill.stepIndex, count);
          return undefined; // Still waiting for other reviewers
        }
        targetSkill.reviewers.delete(targetSkill.stepIndex);
        
        const next = targetSkill.stepIndex + 1;
        if (next < targetSkill.steps.length) {
          targetSkill.stepIndex = next;
          targetSkill.stepStartedAt = Date.now();
          console.log(
            `[sequence-enforcer] ⏩ Step ${next}/${targetSkill.steps.length}: ${targetSkill.steps[next]!.name}`,
          );
          announceGate(targetSkill.steps[next]!);
          writeBridgeState();
        } else {
          console.log(
            `[sequence-enforcer] ✅ All ${targetSkill.steps.length} steps completed`,
          );
          // ponytail: pop completed skill, restore parent (#7265)
          // Remove targetSkill from stack (may not be top if sub-skills above)
          const idx = skillStack.indexOf(targetSkill);
          if (idx >= 0) {
            // Remove targetSkill and everything above it (sub-skills)
            skillStack.splice(idx);
          }
          const parent = topSkill();
          if (parent) {
            console.log(`[sequence-enforcer] ↩ Restored parent: ${parent.path} (step ${parent.stepIndex}/${parent.steps.length})`);
            writeBridgeState();
          } else {
            clearBridgeState();
          }
        }
      }
    }

    return undefined;
  });

  // #5672: suppress banner in print mode (task sub-agent output)
  if (!isPrintMode()) {
    if (isKillSwitchActive()) {
      console.log("[sequence-enforcer] ⏸️  Loaded — kill switch active, all enforcement bypassed");
    } else {
      console.log(`[sequence-enforcer] ✅ Loaded — mode: ${resolveMode()} — enforcing step sequences`);
    }
  }
}
