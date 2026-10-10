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
  closeSync,
  existsSync,
  ftruncateSync,
  lstatSync,
  mkdirSync,
  openSync,
  readdirSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
  writeSync,
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

// ── bounded capture log (#1662 review) ─────────────────────────────────
//
// The capture tee writes the child's RAW stdout+stderr to disk so
// `task_status`/`task_collect` can read it back. Nothing capped it: a chatty
// child could fill the disk before any retention sweep ran. This writer keeps
// the file bounded while keeping its mtime FRESH (liveness derives from the log
// write clock, so a silent cap that stopped writing would make a live lane read
// `wedged`). On overflow it truncates and keeps going — the most recent chunk
// survives, and the normal path still hands the full final message back from
// the run record's `final_content`.

export const DEFAULT_TASK_RUNS_LOG_MAX_BYTES = 16 * 1024 * 1024;

/** Parse a positive integer env value; null when absent/invalid. */
function positiveInt(raw: string | undefined): number | null {
  if (raw === undefined) return null;
  const n = Number(raw);
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : null;
}

export function resolveTaskRunsLogMaxBytes(
  env: Record<string, string | undefined> = process.env,
): number {
  return positiveInt(env.TASK_RUNS_LOG_MAX_BYTES) ?? DEFAULT_TASK_RUNS_LOG_MAX_BYTES;
}

export interface BoundedLogWriter {
  /** Append a chunk; bounded by maxBytes. Never throws. */
  write(chunk: Buffer | string): void;
  /** Close the underlying fd. Idempotent. */
  close(): void;
  /** Bytes currently in the file (approximate after a truncation). */
  size(): number;
  /** True once an overflow truncated the log at least once. */
  truncated(): boolean;
}

/** Open a bounded append-only log. Returns null when the file cannot be
 * opened (the caller must treat capture as degraded, never crash). */
export function createBoundedLogWriter(
  path: string,
  maxBytes: number = DEFAULT_TASK_RUNS_LOG_MAX_BYTES,
): BoundedLogWriter | null {
  const cap = Number.isFinite(maxBytes) && maxBytes > 0 ? Math.floor(maxBytes) : DEFAULT_TASK_RUNS_LOG_MAX_BYTES;
  let fd: number | null = null;
  try {
    fd = openSync(path, "a", 0o600);
  } catch {
    return null;
  }
  let bytes = 0;
  try {
    bytes = statSync(path).size;
  } catch {
    bytes = 0;
  }
  let didTruncate = false;
  return {
    write(chunk: Buffer | string): void {
      if (fd === null) return;
      let buf = typeof chunk === "string" ? Buffer.from(chunk) : chunk;
      if (buf.length === 0) return;
      // A single chunk larger than the whole cap would otherwise empty the log
      // on truncation; keep its tail so the newest output survives.
      if (buf.length > cap) buf = buf.subarray(buf.length - cap);
      try {
        bytes += writeSync(fd, buf);
        if (bytes > cap) {
          ftruncateSync(fd, 0);
          bytes = 0;
          didTruncate = true;
        }
      } catch {
        // A capture tee must never break the dispatch it observes.
      }
    },
    close(): void {
      if (fd !== null) {
        try {
          closeSync(fd);
        } catch {
          // already closed
        }
        fd = null;
      }
    },
    size(): number {
      return bytes;
    },
    truncated(): boolean {
      return didTruncate;
    },
  };
}

// ── retention sweep (#1662 review) ─────────────────────────────────────
//
// Every background dispatch leaves a durable `<run_id>.json` (which carries the
// composed final content) plus `<run_id>.log`, and NOTHING pruned the tree — it
// grew without limit. This is the bound: age OR total bytes, whichever binds
// first, evicting the OLDEST non-live run first. Mirrors the sibling
// `scripts/pi-task-session-prune.sh` contract for `$TASK_SESSION_ROOT`.
//
// Liveness — the part that has to be right: a run is NEVER evicted while its
// record is `running` and its pid is alive. A `running` record whose pid is
// gone (a parent that died mid-run) is evicted only after `SETTLE_GRACE_MS`, so
// an in-flight settle write cannot lose its record. Fail-safe: this function
// never throws into the dispatch path; a missing/unreadable root is a no-op.

export const DEFAULT_TASK_RUNS_MAX_BYTES = 2 * 1024 * 1024 * 1024; // 2 GiB
const DEFAULT_TASK_RUNS_MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000; // 7 days
const SETTLE_GRACE_MS = 5 * 60 * 1000;
const RUN_FILE_RE = /\.(json|log)$/;

/** Operator bounds for the retention sweep (env-tunable). Mirrors the sibling
 * `TASK_SESSION_MAX_AGE_DAYS` / `TASK_SESSION_MAX_BYTES` contract. */
export function resolveTaskRunsPruneBounds(
  env: Record<string, string | undefined> = process.env,
): { maxAgeMs: number; maxBytes: number } {
  const days = positiveInt(env.TASK_RUNS_MAX_AGE_DAYS);
  return {
    maxAgeMs: days !== null ? days * 24 * 60 * 60 * 1000 : DEFAULT_TASK_RUNS_MAX_AGE_MS,
    maxBytes: positiveInt(env.TASK_RUNS_MAX_BYTES) ?? DEFAULT_TASK_RUNS_MAX_BYTES,
  };
}

export interface TaskRunsPruneOptions {
  maxAgeMs?: number;
  maxBytes?: number;
  now?: number;
}

export interface TaskRunsPruneResult {
  /** distinct run ids with at least one file present. */
  examined: number;
  /** run ids fully evicted (record + log). */
  pruned: number;
  freedBytes: number;
  /** runs kept because they are provably live. */
  keptLive: number;
  errors: string[];
}

interface RunGroup {
  files: string[];
  bytes: number;
  mtime: number;
  live: boolean;
}

/** A run is live (must not be evicted) when its record says `running` and its
 * pid is alive; or when it is `running`, its pid is gone, and its log was
 * written within the settle grace window (a parent about to persist). A
 * terminal record is never live. */
function runIsLive(root: string, runId: string, now: number): boolean {
  const rec = readRunRecord(root, runId);
  if (!rec) {
    // No record yet (a dispatch in its millisecond write window) or a corrupt
    // one. Conservative: keep a very fresh log, else evictable.
    const mt = logMtimeMs(runLogPath(root, runId));
    return mt !== null && now - mt < SETTLE_GRACE_MS;
  }
  if (rec.status !== "running") return false;
  if (pidAlive(rec.pid)) return true;
  const mt = logMtimeMs(rec.log_path);
  return mt !== null && now - mt < SETTLE_GRACE_MS;
}

export function pruneTaskRuns(
  root: string,
  opts: TaskRunsPruneOptions = {},
): TaskRunsPruneResult {
  const maxAgeMs = opts.maxAgeMs ?? DEFAULT_TASK_RUNS_MAX_AGE_MS;
  const maxBytes = opts.maxBytes ?? DEFAULT_TASK_RUNS_MAX_BYTES;
  const now = opts.now ?? Date.now();
  const result: TaskRunsPruneResult = { examined: 0, pruned: 0, freedBytes: 0, keptLive: 0, errors: [] };
  let entries: string[];
  try {
    entries = readdirSync(root);
  } catch {
    return result; // absent/unreadable root: nothing to do, never throw
  }
  const groups = new Map<string, RunGroup>();
  for (const name of entries) {
    if (!RUN_FILE_RE.test(name)) continue;
    const id = safeRunId(name.replace(RUN_FILE_RE, ""));
    if (!id) continue;
    if (`${id}.json` !== name && `${id}.log` !== name) continue;
    const full = join(root, name);
    let st: ReturnType<typeof lstatSync>;
    try {
      st = lstatSync(full);
    } catch {
      continue;
    }
    if (!st.isFile()) continue; // never follow a symlink or descend a dir
    let g = groups.get(id);
    if (!g) {
      g = { files: [], bytes: 0, mtime: st.mtimeMs, live: false };
      groups.set(id, g);
    }
    g.files.push(full);
    g.bytes += st.size;
    g.mtime = Math.min(g.mtime, st.mtimeMs);
  }
  result.examined = groups.size;
  let total = 0;
  for (const g of groups.values()) total += g.bytes;
  // Liveness FIRST — a live run's bytes count toward the tree size but never
  // enter the eviction set.
  const evictable: Array<[string, RunGroup]> = [];
  for (const [id, g] of groups) {
    g.live = runIsLive(root, id, now);
    if (g.live) result.keptLive++;
    else evictable.push([id, g]);
  }
  evictable.sort((a, b) => a[1].mtime - b[1].mtime); // oldest first
  const cutoff = now - maxAgeMs;
  let freed = 0;
  for (const [, g] of evictable) {
    const evict = g.mtime < cutoff || total - freed > maxBytes;
    if (!evict) continue;
    let ok = true;
    for (const f of g.files) {
      try {
        rmSync(f, { force: true });
      } catch (err) {
        ok = false;
        result.errors.push(`${f}: ${err instanceof Error ? err.message : String(err)}`);
      }
    }
    if (ok) {
      freed += g.bytes;
      result.pruned++;
    }
  }
  result.freedBytes = freed;
  return result;
}
