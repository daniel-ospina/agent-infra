/**
 * kill-switch.ts — the SINGLE home for the sequence-enforcer bypasses.
 *
 * There are TWO, and they are deliberately different things:
 *
 *   1. THE KILL SWITCH (`KILL_SWITCH_FILE`, machine-global, set by a HUMAN).
 *      A safety valve. `skills/enforcement/SKILL.md:11` is unambiguous: "agents
 *      must NEVER engage it autonomously … do NOT touch the kill switch". An
 *      agent reaching a deadlock escalates or uses (2) — it must not reach for
 *      the human's machine-wide valve, because setting it bypasses every gate in
 *      every session on the box.
 *
 *   2. THE SESSION ESCAPE (process-local, set by an AGENT).
 *      `loop_enforcer` is one of exactly two tools allowed at a `checkpoint` gate
 *      (the other is `read`), so it is BY DESIGN the agent-side escape from a
 *      checkpoint deadlock (#357 (d), "escape-hatch guarantee at checkpoint").
 *      It bypasses THIS session only.
 *
 * WHY BOTH LIVE HERE. The escape used to be a module-local const in
 * `sequence-enforcer/index.ts` while `loop-enforcer/index.ts` referenced the
 * identifier WITHOUT defining or importing it (5 sites: 693, 701, 748, 757, 786).
 * Every write raised `ReferenceError`, the write's own `catch` swallowed it into
 * `killWritten = false`, and the escape was INERT — while still printing a
 * message about a guarantee it could not provide (#1419). One home, imported by
 * both, and the effect and its wording testable as one unit, is what stops that
 * recurring.
 *
 * WHY THE AGENT PATH IS SESSION-LOCAL, NOT THE FILE. Writing the machine-global
 * file from `loop_enforcer stop` reads well ("the escape fires!") and is wrong
 * twice over. It contradicts the recorded human-only rule above; and it does not
 * even work, because #7470 has every `session_start` clear the file for hygiene —
 * and a `task` sub-agent is a separate `pi -p` process, so on a fleet that
 * dispatches sub-agents continuously, a sibling boot clears the escaping
 * session's bypass within seconds of it being set. The escape would be granted
 * and revoked before the blocked session could spend it. Process-local state
 * cannot be cleared by another process, so the escape holds for exactly as long
 * as the session that needs it.
 *
 * ⚠️ NOT a security boundary. The trust boundary recorded in the #357 scope is
 * workflow-enforcement against honest-but-lazy agents: an agent that can write
 * files can forge the switch path directly. The gate's real protection is the
 * phase/sequence structure plus the audit trail — and every bypass is logged
 * (`event: "bypassed"` with a `reason` that distinguishes the two).
 */

import { existsSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";

/**
 * The machine-global kill-switch path.
 *
 * ⚠️ Deliberately unchanged since #7549 — do NOT "tidy" it: a path change
 * silently strands every already-running session's escape, and both extensions
 * read this one constant.
 */
export const KILL_SWITCH_FILE = "/tmp/agent-state-machine.kill";

/** The env-var bypass, which sits alongside the file. Namespaced like every
 *  other gate env (see `_getEnv` — the `AGENT_`/`ELDATO_` prefixes). */
export function killSwitchEnvValue(
  env: Record<string, string | undefined> = process.env,
): string | undefined {
  return env.AGENT_STATE_MACHINE ?? env.ELDATO_STATE_MACHINE;
}

/** Is the HUMAN switch set — by the env bypass, or by the file? */
export function isKillSwitchSet(
  env: Record<string, string | undefined> = process.env,
  path: string = KILL_SWITCH_FILE,
): boolean {
  if (killSwitchEnvValue(env)) return true;
  try {
    return existsSync(path);
  } catch {
    return false;
  }
}

// ── The session escape (the AGENT's, process-local) ──────────────────────
//
// ⛔ THE STATE MUST LIVE ON `globalThis`, NOT IN THIS MODULE'S SCOPE.
// pi's extension loader builds a SEPARATE module graph per extension —
// `loadExtensionModule` constructs a new jiti with `moduleCache: false` for each
// extension path (pi dist `core/extensions/loader.js`). A `let` here is therefore
// instantiated TWICE: `loop-enforcer` would set its own copy while
// `sequence-enforcer` — the extension that owns the gates — reads a DIFFERENT,
// always-null copy. The escape would be inert again, and `diagnose` would report
// "Session escape: ACTIVE" from the granting copy while the gate stayed closed:
// #1419's defect, wearing the fix's clothes. (Measured, not theorised: loading
// this module through two jiti instances with `moduleCache: false` gave
// `loop-enforcer sees true` / `gate sees false`.) `globalThis` is per-REALM, so it
// is shared across the loader's module graphs while staying per-PROCESS — which is
// exactly the scope the escape wants: a `task` sub-agent is a separate process and
// inherits nothing. The same trap already bit `extensions/shared/health.ts` (its
// `registry` Map is invisible across extensions).
const SESSION_ESCAPE_KEY = Symbol.for("pi.agent-infra.session-escape");

interface SessionEscapeCell {
  ts: string | null;
}

function cell(): SessionEscapeCell {
  const g = globalThis as unknown as Record<symbol, SessionEscapeCell | undefined>;
  return (g[SESSION_ESCAPE_KEY] ??= { ts: null });
}

/** Grant this session a bypass. */
export function markSessionEscaped(now: Date = new Date()): string {
  cell().ts = now.toISOString();
  return cell().ts!;
}

/** Is THIS session escaped? */
export function isSessionEscaped(): boolean {
  return cell().ts !== null;
}

/** When this session's escape was granted, or null. */
export function sessionEscapeStatus(): string | null {
  return cell().ts;
}

/**
 * Revoke this session's escape. Returns whether one was set, so the caller can
 * log the transition rather than guess at it.
 */
export function clearSessionEscape(): boolean {
  const had = cell().ts !== null;
  cell().ts = null;
  return had;
}

/** The registry key the escape lives under — exported so the suite can prove the
 *  state is process-global rather than module-local (the P0 above). */
export const SESSION_ESCAPE_CELL_KEY = SESSION_ESCAPE_KEY;

/**
 * Is enforcement bypassed for THIS session — by the human's switch (file or env,
 * machine-global) or by this session's own escape?
 *
 * This is what the gates ask. `isKillSwitchSet` alone answers the narrower
 * "is the machine-wide valve open", which is what `diagnose` must report
 * separately, because the two have different consequences and different owners.
 */
export function isEnforcementBypassed(
  env: Record<string, string | undefined> = process.env,
  path: string = KILL_SWITCH_FILE,
): boolean {
  return isKillSwitchSet(env, path) || isSessionEscaped();
}

/**
 * Read the switch without throwing.
 *
 * `set` is decided by EXISTENCE, exactly like `isKillSwitchSet` — an
 * unreadable-but-present switch file still means enforcement is bypassed, and
 * `diagnose` reporting "NOT SET" in that state would be a lie. `ts` is
 * best-effort and null when the file cannot be read.
 *
 * `source` names WHERE the bypass came from. Consulting the file alone would let
 * `diagnose` print "NOT SET" while `AGENT_STATE_MACHINE=1` bypassed every gate —
 * the inversion this function exists to prevent, and it was live until the env
 * branch was folded in here.
 */
export function killSwitchStatus(
  env: Record<string, string | undefined> = process.env,
  path: string = KILL_SWITCH_FILE,
): { set: boolean; path: string; ts: string | null; source: "env" | "file" | null } {
  const envValue = killSwitchEnvValue(env);
  if (envValue) return { set: true, path, ts: null, source: "env" };
  let present = false;
  try {
    present = existsSync(path);
  } catch {
    present = false;
  }
  if (!present) return { set: false, path, ts: null, source: null };
  try {
    const ts = readFileSync(path, "utf-8").trim();
    return { set: true, path, ts: ts || null, source: "file" };
  } catch {
    return { set: true, path, ts: null, source: "file" };
  }
}

/**
 * Set the switch. NEVER throws — the caller reports the failure, because a
 * swallowed failure is exactly how the escape went inert (#1419 fault 1).
 *
 * ⛔ HUMAN path. An agent must not call this (`skills/enforcement/SKILL.md:11`);
 * the agent escape is `loopStopEscape`, which is session-local.
 *
 * `path` is a testability seam only; every production caller takes the default.
 */
export function setKillSwitch(
  now: Date = new Date(),
  path: string = KILL_SWITCH_FILE,
): { ok: boolean; path: string; error?: string } {
  try {
    writeFileSync(path, now.toISOString());
    return { ok: true, path };
  } catch (e) {
    return { ok: false, path, error: e instanceof Error ? e.message : String(e) };
  }
}

/**
 * Clear the switch. Used by session-start hygiene (a stale switch must not
 * silently bypass a NEW session) and by the tests.
 */
export function clearKillSwitch(path: string = KILL_SWITCH_FILE): boolean {
  try {
    if (!existsSync(path)) return false;
    unlinkSync(path);
    return true;
  } catch {
    return false;
  }
}

/**
 * The agent's escape — its EFFECT and its wording as one testable unit.
 *
 * `slug` may be null, and that is the ordinary case: a session blocked at a
 * checkpoint has no active loop, and it is precisely the session the escape
 * exists for. The escape is therefore granted BEFORE any "nothing to stop"
 * return (#1419 fault 2) — returning "No active loop to stop." was the escape
 * refusing to fire in the only situation it was written for.
 *
 * It never writes the machine-global file: see the module header. The text says
 * what actually happened, and names the human's valve for the fleet-wide case
 * without inviting the agent to operate it.
 */
export function loopStopEscape(slug: string | null): { text: string; ts: string } {
  const ts = markSessionEscaped();
  const head = slug ? `Loop '${slug}' stopped.` : "No active loop to stop.";
  const bypass = `Sequence enforcement bypassed for THIS session (session escape set at ${ts}).`;
  const boundary =
    `Other sessions are unaffected. A machine-wide bypass is the human's kill switch, ` +
    `not an agent action: touch ${KILL_SWITCH_FILE}`;
  return { text: `${head} ${bypass} ${boundary}`, ts };
}
