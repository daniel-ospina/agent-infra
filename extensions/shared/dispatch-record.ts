/**
 * shared/dispatch-record.ts — durable per-spawn-attempt OUTCOME row (#783 Task 4).
 *
 * WHY THIS EXISTS: a `task` dispatch that is killed (hard cap / heartbeat /
 * backstop / exit-path cut) left no machine-readable outcome anywhere on the
 * dispatch path. The only `task`-side sink was the double-gated usage ledger
 * (`TASK_USAGE_LEDGER=1`) — usage, not outcomes — so "how did this dispatch
 * end, and can I count the class" was answerable only by scraping the parent's
 * session transcript. This module owns the row CONTRACT and the write+confirm.
 *
 * WHERE THE ROW GOES — the EXISTING dispatch ledger, never a new file.
 * `appendLedger` (shared/provider-failover.ts) appends JSONL to
 * `<agentDir>/audit/provider-failover.jsonl`, and that file already carries the
 * #512 `dispatch-usage` rows and the #476 failover/`venice-route` rows keyed by
 * `dispatchId = TASK_HEARTBEAT_NONCE`. The outcome row is written through the
 * SAME call with `event="dispatch-outcome"`, so #796 and the failover ledger
 * JOIN on the same key in the same file. A second sink would fragment the join.
 *
 * APPEND-ONLY + IMMUTABLE: `appendLedger` has no update primitive, so a written
 * line can never be amended. This module therefore records only values known
 * AT SETTLE, and the dispatch path's acceptance is "exactly one row per spawn
 * ATTEMPT". A later reader that needs to AMEND an outcome must append a
 * follow-up row keyed by `dispatchId`+`childSessionId`+`attempt` — that is
 * #840's obligation (the opt-in WIP commit), not this module's.
 *
 * WHY THE WRITE IS CONFIRMED: `appendLedger` returns `void` and swallows every
 * exception ("audit must never break the gate path", provider-failover.ts), so
 * it cannot back a `{ok,error}` contract — a full/unwritable ledger would be
 * indistinguishable from success, and the parent's payload would name a path
 * nothing was written to. `recordDispatchOutcome` therefore writes, then READS
 * BACK the appended byte range and reports whether OUR row is really there.
 *
 * GATE: `DISPATCH_LEDGER`, and it DEFAULTS ON. The shipped dispatch path must
 * produce rows (issue indicator 3 makes both the hard-cap and no-progress
 * populations countable), so an opt-in gate would make the indicator false on
 * the shipped config. Tests isolate by pointing `PI_CODING_AGENT_DIR` at a
 * tmpdir; when the gate is explicitly off the writer reports `skipped` and the
 * payload carries NO `record` field at all (it must not advertise a path, nor
 * claim a failure the operator asked for).
 */

import { closeSync, openSync, readdirSync, readSync, statSync } from "node:fs";
import { join } from "node:path";
import { appendLedger, auditLedgerFile } from "./provider-failover.js";

/** JSONL event name for the outcome row. One row per spawn ATTEMPT. */
export const DISPATCH_RECORD_EVENT = "dispatch-outcome";

/** The extension that owns the `task` dispatch path — a stable discriminator
 * for #796 readers that may later see outcome rows from other dispatchers. */
export const DISPATCH_RECORD_EXTENSION = "builtin-tools";

/** Fallback `dispatchClass` — a builtin `task` child. */
export const DEFAULT_DISPATCH_CLASS = "task";

/** The row contract. Every key is always present; unknown-at-settle values are
 * `null` (or `[]`), never omitted, so a reader destructures without branching.
 * Fields may be ABSENT in rows written by OTHER versions — readers must
 * tolerate missing identity fields (the plan's tolerance rule). */
export interface DispatchOutcomeRow {
  /** ISO-8601 write timestamp (stamped by this module, not by appendLedger). */
  ts: string;
  event: typeof DISPATCH_RECORD_EVENT;
  extension: string;
  /** The per-dispatch `TASK_HEARTBEAT_NONCE` (shared with the #512 usage rows
   * and the #476 failover/venice-route rows). `null` only when the heartbeat
   * path was off, in which case retry attempts cannot be joined. */
  dispatchId: string | null;
  parentSessionId: string | null;
  /** The child's own pi session id, read from the spawned arg vector. */
  childSessionId: string | null;
  /** 1-based spawn-attempt ordinal (retry() respawns). REQUIRED: a dispatch
   * that retried writes N rows sharing one `dispatchId`. */
  attempt: number;
  cwd: string;
  branch: string | null;
  headSha: string | null;
  dirty: boolean | null;
  /** Dirty paths, or null when the status probe FAILED (#783 §6.6). NULL IS
   * NOT `[]`: `[]` is a confident "zero dirty paths" that a machine consumer
   * would read as a clean tree, which is exactly what repo-freshness refuses to
   * report (it returns `paths: null` for the same reason). Only the human
   * renderer had been corrected before; this aligns the row with it. */
  dirtyPaths: string[] | null;
  /** Why the attempt ended: "hard-cap" | "cut" | "backstop" | "failed" |
   * the heartbeat `decision.reason`. */
  reason: string;
  toolAgeMaxMs: number | null;
  toolsInFlight: number | null;
  everSawTool: boolean;
  /** Best-known locator for the child's transcript: the session `.jsonl` when
   * it already exists, else the child's session DIRECTORY (a zero-output kill
   * can beat the child's first write). `null` on the `--no-session` degrade. */
  transcriptPath: string | null;
  /** Child exit code — `null` when the attempt was killed (no exit) or the
   * settle was a no-partial kill. */
  exitCode: number | null;
  /** Dispatch class — `"task"` (default) or a caller-declared reviewer/eval
   * class via `TASK_DISPATCH_CLASS`. */
  dispatchClass: string;
}

/** Everything the row needs that is NOT derivable inside the writer. */
export interface DispatchOutcomeInput {
  extension?: string;
  dispatchId: string | null;
  parentSessionId: string | null;
  childSessionId: string | null;
  attempt: number;
  cwd: string;
  branch: string | null;
  headSha: string | null;
  dirty: boolean | null;
  dirtyPaths: string[] | null;
  reason: string;
  toolAgeMaxMs: number | null;
  toolsInFlight: number | null;
  everSawTool: boolean;
  transcriptPath: string | null;
  exitCode: number | null;
  dispatchClass: string;
}

/** Result of a write attempt. `skipped` means the gate was explicitly off —
 * distinct from a failure, so the payload can stay silent rather than claim
 * `failed: …`. */
export interface RecordWriteResult {
  ok: boolean;
  path: string;
  error?: string;
  skipped?: boolean;
}

/** Per-SPAWN identity the dispatcher threads into `spawnSubAgent`. NOT derivable
 * inside the spawn closure: `attempt` is retry()'s ordinal and `parentSessionId`
 * comes from the tool's extension context. `childSessionId` is deliberately NOT
 * here — it is read from the arg vector, the source of truth for what spawned. */
export interface DispatchRecordContext {
  /** 1-based spawn-attempt ordinal. REQUIRED for a joinable row: `dispatchId`
   * alone cannot separate retry attempt 1 from attempt 2. */
  attempt: number;
  parentSessionId?: string | null;
  /** Overrides `resolveDispatchClass(env)` when set. */
  dispatchClass?: string;
}

// ── Gate ──────────────────────────────────────────────────────────────────

/** `DISPATCH_LEDGER`, DEFAULT ON. Only an explicit falsy value disables it
 * ("0" / "false" / "no" / "off"). Anything else — including unset — writes. */
export function dispatchLedgerEnabled(
  env: Record<string, string | undefined> = process.env,
): boolean {
  const raw = env.DISPATCH_LEDGER?.trim().toLowerCase();
  if (raw === undefined || raw === "") return true;
  return !(raw === "0" || raw === "false" || raw === "no" || raw === "off");
}

// ── Dispatch class ────────────────────────────────────────────────────────

const DISPATCH_CLASS_RE = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;

/**
 * Resolve `dispatchClass` from the dispatch env.
 *
 * There is NO existing runtime reviewer/eval discriminator to reuse. A review
 * dispatch is an ordinary `task` tool call (the review-enforcer counts ANY
 * `task`/`subagent` tool_result and keeps no class concept; its only
 * "reviewer/eval dispatch class" reference is a usage-ledger comment). The
 * class is therefore CALLER-declared via `TASK_DISPATCH_CLASS` — the same
 * shape as every other parent-side dispatch knob. Unset / malformed values
 * fall back to `"task"` (a builtin task child), never a throw.
 *
 * KNOWN NUANCE: the var rides the child env (like the other TASK_* knobs), so a
 * nested dispatch from inside a child inherits its parent's class. That is a
 * reasonable default (the whole subtree is one dispatch purpose) and is
 * recorded rather than silently special-cased.
 */
export function resolveDispatchClass(
  env: Record<string, string | undefined> = process.env,
): string {
  const raw = env.TASK_DISPATCH_CLASS?.trim();
  if (!raw || !DISPATCH_CLASS_RE.test(raw)) return DEFAULT_DISPATCH_CLASS;
  return raw;
}

// ── Arg-vector identity ───────────────────────────────────────────────────

/** The value after the first `<flag> <value>` pair in a spawned arg vector, or
 * null. The ARGS are the source of truth for what was actually spawned, so a
 * caller/args mismatch cannot mis-attribute a row to a session never opened. */
export function sessionArgFromArgs(args: string[], flag: string): string | null {
  for (let i = 0; i < args.length - 1; i++) {
    if (args[i] === flag) return args[i + 1] ?? null;
  }
  return null;
}

/**
 * Best-known transcript locator at settle. pi names the transcript
 * `<sessionDir>/<fileTimestamp>_<childId>.jsonl` (session-manager), but the
 * timestamp is minted by the CHILD at startup — unknown to the parent, and
 * absent entirely when a zero-output kill beats the first write. So: prefer a
 * `.jsonl` already in the session dir, else the dir itself, else null.
 */
export function resolveTranscriptPath(
  sessionDir: string | null,
  sessionId: string | null = null,
): string | null {
  if (!sessionDir) return null;
  try {
    const files = readdirSync(sessionDir).filter((f) => f.endsWith(".jsonl")).sort();
    if (files.length > 0) {
      // Prefer THIS child's transcript (`<timestamp>_<childId>.jsonl`) when the
      // id is known; the sorted-last fallback covers a dir with a single file.
      const exact = sessionId ? files.filter((f) => f.includes(sessionId)) : [];
      return join(sessionDir, exact.length > 0 ? exact[exact.length - 1] : files[files.length - 1]);
    }
  } catch {
    /* dir absent / unreadable — fall through to the dir (still the locator) */
  }
  return sessionDir;
}

// ── Row construction / rendering ──────────────────────────────────────────

/** Build the contract row. Pure — timestamped here so the contract (not
 * appendLedger's own `ts`) is the row's owner. */
export function buildDispatchOutcomeRow(
  input: DispatchOutcomeInput,
  now: Date = new Date(),
): DispatchOutcomeRow {
  return {
    ts: now.toISOString(),
    event: DISPATCH_RECORD_EVENT,
    extension: input.extension ?? DISPATCH_RECORD_EXTENSION,
    dispatchId: input.dispatchId,
    parentSessionId: input.parentSessionId,
    childSessionId: input.childSessionId,
    attempt: input.attempt,
    cwd: input.cwd,
    branch: input.branch,
    headSha: input.headSha,
    dirty: input.dirty,
    dirtyPaths: input.dirtyPaths,
    reason: input.reason,
    toolAgeMaxMs: input.toolAgeMaxMs,
    toolsInFlight: input.toolsInFlight,
    everSawTool: input.everSawTool,
    transcriptPath: input.transcriptPath,
    exitCode: input.exitCode,
    dispatchClass: input.dispatchClass,
  };
}

/** The parent payload's `record` value: the ledger path on success, or an
 * explicit `failed: <err>` string. NEVER a bare path when nothing was
 * written — the parent must be able to tell "there is a record" from
 * "recording failed". */
export function renderRecordField(result: RecordWriteResult): string {
  if (result.ok) return result.path;
  return `failed: ${result.error ?? "unknown"}`;
}

// ── Write + confirm ───────────────────────────────────────────────────────

const CONFIRM_WINDOW_CAP = 256 * 1024;

/** Size of `file`, or 0 when absent/unstattable. */
function sizeOf(file: string): number {
  try {
    return statSync(file).size;
  } catch {
    return 0;
  }
}

/** Read `[from, to)` of `file` (bounded) and return the parsed lines. */
function readAppendedLines(file: string, from: number, to: number): unknown[] {
  const len = Math.min(Math.max(to - from, 0), CONFIRM_WINDOW_CAP);
  if (len <= 0) return [];
  const buf = Buffer.alloc(len);
  const fd = openSync(file, "r");
  try {
    const read = readSync(fd, buf, 0, len, from);
    return buf
      .subarray(0, read)
      .toString("utf-8")
      .split("\n")
      .filter((l) => l.trim().length > 0)
      .map((l) => {
        try {
          return JSON.parse(l);
        } catch {
          return null;
        }
      })
      .filter((v) => v !== null);
  } finally {
    closeSync(fd);
  }
}

/**
 * Write the outcome row through the SHARED ledger, then CONFIRM it landed.
 *
 * `appendLedger` swallows all exceptions, so success cannot be inferred from
 * it. Confirmation scans the byte range appended during this call for a line
 * matching OUR identity (event + dispatchId + attempt + reason) — robust to a
 * concurrent sibling appending around us, which "is it the last line?" is not.
 */
export function recordDispatchOutcome(
  row: DispatchOutcomeRow,
  env: Record<string, string | undefined> = process.env,
): RecordWriteResult {
  const path = auditLedgerFile(env);
  if (!dispatchLedgerEnabled(env)) return { ok: false, path, skipped: true };
  const before = sizeOf(path);
  appendLedger(row, DISPATCH_RECORD_EVENT, env);
  try {
    const after = sizeOf(path);
    if (after <= before) {
      return { ok: false, path, error: "ledger did not grow after append" };
    }
    const lines = readAppendedLines(path, before, after) as Array<Record<string, unknown>>;
    const found = lines.some(
      (l) =>
        l.event === DISPATCH_RECORD_EVENT &&
        l.dispatchId === row.dispatchId &&
        l.attempt === row.attempt &&
        l.reason === row.reason,
    );
    if (!found) return { ok: false, path, error: "appended row not found on read-back" };
    return { ok: true, path };
  } catch (err) {
    return { ok: false, path, error: err instanceof Error ? err.message : String(err) };
  }
}
