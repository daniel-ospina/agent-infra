/**
 * shared/session-id.ts — child session identity for task dispatches (#783 Task 1).
 *
 * The task tool used to spawn every child with `--no-session` (in-memory
 * session, nothing persisted), so a capped/timed-out child left no transcript
 * to recover from. Task 1 replaces that with a fresh, durable
 * `--session-id <uuid> --session-dir <root>/<uuid>` per spawn.
 *
 * Why the grammar lives here: pi's `assertValidSessionId` is NOT re-exported
 * from the package index (dist/index.d.ts exports SessionManager only), so the
 * check is re-implemented against the same grammar
 * (dist/core/session-manager.js:15). An invalid id makes pi's
 * `validateSessionIdFlags` print an error and `process.exit(1)`
 * (dist/main.js:256) — which the task tool's exit taxonomy reads as a plain
 * `failed` result, and `shared/retry.ts` counts a `failed` composition as
 * success for retry purposes. A bad id must therefore be rejected BEFORE the
 * spawn, as a distinct non-retryable failure.
 *
 * Why a FRESH id per spawn (not one per dispatch, and never the parent's):
 * pi's duplicate-id path (`main.js:338-345`) silently re-opens an existing
 * session and APPENDS. Retry attempt 2 sharing attempt 1's id would merge the
 * two attempts into one transcript, and per-attempt recovery rows would be
 * indistinguishable. `--no-session` cannot be "supplemented" with an id —
 * it short-circuits into an in-memory session (`main.js:279-281`), so the id
 * is accepted and no file is ever written.
 */

import { randomUUID } from "node:crypto";
import { chmodSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

// ── Id grammar ────────────────────────────────────────────────────────────

/** pi's own grammar (dist/core/session-manager.js:15). */
const SESSION_ID_RE = /^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?$/;

export function isValidSessionId(id: string): boolean {
  return SESSION_ID_RE.test(id);
}

/** Throws with pi's own wording when the id would make pi `exit(1)`. */
export function assertValidSessionId(id: string): void {
  if (!isValidSessionId(id)) {
    throw new Error(
      "Session id must be non-empty, contain only alphanumeric characters, '-', '_', and '.', and start and end with an alphanumeric character",
    );
  }
}

/** A fresh child session id. uuid v4 — hyphens are in-grammar, so it always
 * validates; `assertValidSessionId` still gates it (internal-bug guard). */
export function mintChildSessionId(): string {
  return randomUUID();
}

// ── Session root ──────────────────────────────────────────────────────────

export const DEFAULT_TASK_SESSION_ROOT = join(homedir(), ".pi", "agent", "task-sessions");

/** `TASK_SESSION_ROOT` (tilde-expanded) or the default root. Tests/CI point
 * this at a tmpdir so real child session dirs never accumulate under $HOME. */
export function resolveTaskSessionRoot(
  env: Record<string, string | undefined> = process.env,
): string {
  const raw = env.TASK_SESSION_ROOT?.trim();
  if (!raw) return DEFAULT_TASK_SESSION_ROOT;
  if (raw === "~") return homedir();
  if (raw.startsWith("~/")) return join(homedir(), raw.slice(2));
  return raw;
}

export interface SessionRootStatus {
  ok: boolean;
  root: string;
  error?: string;
}

/**
 * Create the session root defensively, mode 0700. `mkdirSync`'s `mode` is a
 * NO-OP when the directory already exists (e.g. created earlier under a 0755
 * umask), so the explicit `chmodSync` is required — otherwise transcripts
 * (echoed commands + model output) stay world-readable on any upgrade box
 * while a fresh-box mode assertion passes.
 *
 * Never throws: a read-only/full $HOME degrades the dispatch to `--no-session`
 * (works, no transcript) instead of failing it — `--no-session` used to make
 * this impossible, so a persisted session introduces a new failure mode.
 */
export function ensureTaskSessionRoot(root: string): SessionRootStatus {
  try {
    mkdirSync(root, { recursive: true, mode: 0o700 });
    chmodSync(root, 0o700);
    return { ok: true, root };
  } catch (err) {
    return { ok: false, root, error: err instanceof Error ? err.message : String(err) };
  }
}

// ── Per-spawn arg vectors ─────────────────────────────────────────────────

export interface ChildSessionSpec {
  sessionId: string;
  dir: string;
  args: string[];
}

/**
 * Mint one attempt's session id and its `--session-id`/`--session-dir` pair.
 * MUST be called once per SPAWN ATTEMPT (inside the arg-builder function, not
 * hoisted into a shared const) — see the module header.
 *
 * `--session-dir` is keyed on the CHILD id: a parent id may be absent
 * (ephemeral / `--no-session` orchestrator), which would collapse every such
 * parent into one shared directory, and depth ≥2 keeps the files out of the
 * global resume picker (session-manager.js:1326-1340 iterates one level).
 */
export function newChildSession(
  root: string,
  mint: () => string = mintChildSessionId,
): ChildSessionSpec {
  const sessionId = mint();
  assertValidSessionId(sessionId);
  const dir = join(root, sessionId);
  return { sessionId, dir, args: ["--session-id", sessionId, "--session-dir", dir] };
}

/** Degrade vector when the session root cannot be created (fresh array each
 * call — never a shared mutable constant). */
export function degradedSessionArgs(): string[] {
  return ["--no-session"];
}
