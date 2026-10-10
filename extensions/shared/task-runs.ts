/**
 * shared/task-runs.ts — durable run records for BACKGROUND task dispatch (#1662).
 *
 * WHY THIS EXISTS
 * ---------------
 * `task` is synchronous at the caller: it `await`s the child to settle, so an
 * orchestrator that dispatches N lanes pays `max(lane)` wall-clock and cannot
 * react to anything until the slowest finishes (or the 6h `TASK_HARD_CAP_MS`
 * bound returns partials). #1662 adds a first-class `background: true` mode that
 * returns immediately with `{ run_id, pid, pgid, log_path }`, plus a
 * `task_status` / `task_collect` seam to observe and reap the lane later.
 *
 * This module owns the DURABLE half of that seam: one small JSON record per
 * background run (`<root>/<run_id>.json`) and one capture log
 * (`<root>/<run_id>.log`). The record is written:
 *   - at dispatch, before the child is spawned, with `status: "running"` —
 *     so `task_status` can always answer even if the parent dies mid-run; and
 *   - at settle, by the caller's `.then`, with the terminal status + the
 *     composed final result.
 * Writes are atomic (tmp + rename) so a reader never sees a half-written
 * record, and a missing/corrupt record reads as ABSENT (null), never as a
 * confident terminal state.
 *
 * ⚠️ NOT the dispatch ledger (#783). The append-only `dispatch*.jsonl` audit
 * population under `~/.pi/agent` is one row per spawn attempt. This is mutable
 * per-run STATE for a live caller. They are deliberately separate files with
 * separate lifecycles; this module never touches the ledger.
 *
 * The record carries no heartbeat parsing — that lives in builtin-tools
 * (`parseHeartbeatLine`), so this module stays dependency-free and
 * one-directional (builtin-tools imports it, never the reverse).
 */

import { randomUUID } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

/** `TASK_RUNS_ROOT` (tilde-expanded) or the default root. Tests/CI point this
 * at a tmpdir so real run records never accumulate under $HOME. Mirrors
 * `resolveTaskSessionRoot` (shared/session-id.ts). */
export const DEFAULT_TASK_RUNS_ROOT = join(homedir(), ".pi", "agent", "task-runs");

export function resolveTaskRunsRoot(
  env: Record<string, string | undefined> = process.env,
): string {
  const raw = env.TASK_RUNS_ROOT?.trim();
  if (!raw) return DEFAULT_TASK_RUNS_ROOT;
  if (raw === "~") return homedir();
  if (raw.startsWith("~/")) return join(homedir(), raw.slice(2));
  return raw;
}

/** `running` until the child settles; one of the terminal states after. */
export type TaskRunStatus = "running" | "done" | "failed" | "cut";

export interface TaskRunRecord {
  run_id: string;
  /** child pid (null only if the spawn never produced one). */
  pid: number | null;
  /** child's OWN process group (setsid leader ⇒ pgid === pid when detached). */
  pgid: number | null;
  /** the capture log — raw stdout+stderr, INCLUDING `[task-heartbeat]` markers. */
  log_path: string;
  started_at: number;
  /** set once the run reaches a terminal state. */
  settled_at?: number;
  model: string;
  provider: string;
  cwd: string;
  /** the dispatch's RESOLVED stream-stall bound (S) — the per-dispatch
   * `stream_stall_ms` override if given, else `TASK_STREAM_STALL_MS`, else the
   * 20-min default. This is the SAME value the watchdog applies, persisted so
   * `task_status` compares `tool_age_max_ms` against the bound that will
   * actually kill the lane instead of a compile-time constant (#1662 review). */
  stream_stall_ms?: number;
  /** per-dispatch `TASK_HEARTBEAT_NONCE` — lets `task_status` authenticate the
   * markers it replays out of the log (a foreign writer on the child's fd 2
   * must not forge life signs). */
  nonce: string | null;
  status: TaskRunStatus;
  /** child's exit code once terminal (null = signal death). */
  exit_code?: number | null;
  /** terminal discriminator (hard-cap / cut / heartbeat kill / spawn-error…). */
  reason?: string;
  /** the composed final tool result once terminal. */
  final_content?: Array<{ type: string; text: string }>;
  final_details?: Record<string, unknown>;
}

const RUN_ID_RE = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;

/** A fresh run id. uuid v4 — in-grammar for `RUN_ID_RE`, so it is always a
 * safe single path segment. */
export function mintRunId(): string {
  return randomUUID();
}

export interface RunsRootStatus {
  ok: boolean;
  root: string;
  error?: string;
}

/** Create the runs root defensively, mode 0700 (the records name processes and
 * carry child output). Idempotent; a failure is reported, never thrown — a
 * background dispatch must still be able to fall back rather than crash. */
export function ensureTaskRunsRoot(root: string): RunsRootStatus {
  try {
    mkdirSync(root, { recursive: true, mode: 0o700 });
    return { ok: true, root };
  } catch (err) {
    const error = err instanceof Error ? err.message : String(err);
    return { ok: false, root, error };
  }
}

/** Reject a run id that could escape the root. Returns null when unsafe. */
export function safeRunId(runId: unknown): string | null {
  if (typeof runId !== "string") return null;
  const trimmed = runId.trim();
  if (!trimmed || !RUN_ID_RE.test(trimmed) || trimmed.includes("..")) return null;
  return trimmed;
}

export function runRecordPath(root: string, runId: string): string {
  return join(root, `${runId}.json`);
}

export function runLogPath(root: string, runId: string): string {
  return join(root, `${runId}.log`);
}

/** Atomic write (tmp + rename) so a concurrent reader never sees a partial
 * record. Returns a status rather than throwing: a failed persist is reported
 * to the caller but never blocks a dispatch. */
export function writeRunRecord(
  root: string,
  record: TaskRunRecord,
): { ok: boolean; path: string; error?: string } {
  const path = runRecordPath(root, record.run_id);
  const tmp = `${path}.${process.pid}.tmp`;
  try {
    mkdirSync(root, { recursive: true, mode: 0o700 });
    writeFileSync(tmp, JSON.stringify(record, null, 2), { mode: 0o600 });
    renameSync(tmp, path);
    return { ok: true, path };
  } catch (err) {
    const error = err instanceof Error ? err.message : String(err);
    return { ok: false, path, error };
  }
}

/** Read a run record. Anything unreadable/unparseable/malformed reads as
 * ABSENT (null) — a corrupt record must never render as a confident terminal
 * state. */
export function readRunRecord(root: string, runId: string): TaskRunRecord | null {
  const safe = safeRunId(runId);
  if (!safe) return null;
  const path = runRecordPath(root, safe);
  if (!existsSync(path)) return null;
  try {
    const parsed = JSON.parse(readFileSync(path, "utf-8")) as TaskRunRecord;
    if (!parsed || typeof parsed !== "object" || typeof parsed.run_id !== "string") return null;
    if (typeof parsed.status !== "string") return null;
    return parsed;
  } catch {
    return null;
  }
}

/** `process.kill(pid, 0)` liveness: true when the pid exists OR exists but is
 * not ours to signal (EPERM — still alive). Never throws. */
export function pidAlive(pid: number | null | undefined): boolean {
  if (typeof pid !== "number" || !Number.isInteger(pid) || pid <= 1) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return (err as NodeJS.ErrnoException | undefined)?.code === "EPERM";
  }
}

/** mtime of the capture log in epoch ms, or null when it does not exist yet.
 * This is the WRITE-freshness clock (any stdout/stderr byte, marker or not) —
 * deliberately NOT `%CPU`, which reads 0 for a lane legitimately blocked in a
 * long tool call (docs/ops/fleet-liveness.md). */
export function logMtimeMs(logPath: string): number | null {
  try {
    return statSync(logPath).mtimeMs;
  } catch {
    return null;
  }
}
