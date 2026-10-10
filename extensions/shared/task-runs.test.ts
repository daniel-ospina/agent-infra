/**
 * task-runs.test.ts — unit tests for shared/task-runs.ts (#1662).
 * Run: npx tsx extensions/shared/task-runs.test.ts
 *
 * The durable half of background task dispatch: run-record I/O (atomic
 * tmp+rename, corrupt-reads-as-absent), the path-traversal gate, pid liveness,
 * and the runs-root resolution/mode. The integration seam (startBackgroundTask,
 * evaluateTaskRunStatus, collectTaskRun) is covered in
 * extensions/builtin-tools/builtin-tools.test.ts; this file keeps the module's
 * own contract pinned and satisfies scripts/check-untested-modules.cjs.
 */

import {
  DEFAULT_TASK_RUNS_ROOT,
  DEFAULT_TASK_RUNS_LOG_MAX_BYTES,
  createBoundedLogWriter,
  ensureTaskRunsRoot,
  logMtimeMs,
  mintRunId,
  pidAlive,
  pruneTaskRuns,
  readRunRecord,
  resolveTaskRunsLogMaxBytes,
  resolveTaskRunsPruneBounds,
  resolveTaskRunsRoot,
  runLogPath,
  runRecordPath,
  safeRunId,
  writeRunRecord,
  type TaskRunRecord,
} from "./task-runs.js";
import { ok, equal, deepEqual } from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, symlinkSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

let passed = 0, failed = 0;
function test(name: string, fn: () => void | Promise<void>) {
  const run = async () => {
    try { await fn(); passed++; console.log(`  ✅ ${name}`); }
    catch (err: any) { failed++; console.log(`  ❌ ${name}: ${err.message}`); }
  };
  run();
}
function section(name: string) { console.log(`\n${name}:`); }

const TMP_DIRS: string[] = [];
function tmpDir(name: string): string {
  const d = mkdtempSync(join(tmpdir(), `truns-${name}-`));
  TMP_DIRS.push(d);
  return d;
}

function record(overrides: Partial<TaskRunRecord> = {}): TaskRunRecord {
  const run_id = overrides.run_id ?? mintRunId();
  return {
    run_id,
    pid: 4242,
    pgid: 4242,
    log_path: runLogPath("/tmp/truns", run_id),
    started_at: 123,
    model: "deepseek-v4-flash",
    provider: "deepseek",
    cwd: "/tmp",
    nonce: "abc123",
    status: "running",
    ...overrides,
  };
}

section("resolveTaskRunsRoot");

test("defaults to ~/.pi/agent/task-runs; TASK_RUNS_ROOT wins; ~ expands", () => {
  equal(resolveTaskRunsRoot({}), DEFAULT_TASK_RUNS_ROOT, "default root");
  equal(resolveTaskRunsRoot({ TASK_RUNS_ROOT: "/tmp/x" }), "/tmp/x", "env override wins");
  equal(resolveTaskRunsRoot({ TASK_RUNS_ROOT: "   " }), DEFAULT_TASK_RUNS_ROOT, "whitespace-only is absent");
  equal(resolveTaskRunsRoot({ TASK_RUNS_ROOT: "~/sub" }), join(process.env.HOME ?? "", "sub"), "tilde expands");
  equal(resolveTaskRunsRoot({ TASK_RUNS_ROOT: "~" }), process.env.HOME ?? "", "bare tilde is the home dir");
});

section("mintRunId + safeRunId (path-traversal gate)");

test("a minted uuid is safe and unique", () => {
  const a = mintRunId(), b = mintRunId();
  ok(safeRunId(a) !== null, "minted id is a safe segment");
  ok(a !== b, "minted ids differ");
});

test("rejects path-escape shapes and non-strings", () => {
  equal(safeRunId("../escape"), null, "`..` segment");
  equal(safeRunId("/etc/passwd"), null, "absolute path");
  equal(safeRunId("a/b"), null, "slash");
  equal(safeRunId("a\\b"), null, "backslash");
  equal(safeRunId(""), null, "empty");
  equal(safeRunId("   "), null, "whitespace only");
  equal(safeRunId(undefined), null, "undefined");
  equal(safeRunId(null), null, "null");
  equal(safeRunId(42), null, "number");
});

test("accepts an interior dot but never a `..` sequence", () => {
  equal(safeRunId("a.b_c-D9"), "a.b_c-D9", "in-grammar interior punctuation");
  equal(safeRunId("..hidden"), null, "leading dots rejected");
});

section("ensureTaskRunsRoot");

test("creates the root mode 0700 and is idempotent", () => {
  const base = tmpDir("root");
  const root = join(base, "nested", "runs");
  const st = ensureTaskRunsRoot(root);
  equal(st.ok, true, "created");
  equal(statSync(root).mode & 0o777, 0o700, "root is owner-only");
  equal(ensureTaskRunsRoot(root).ok, true, "idempotent");
});

test("degrades (ok:false, never throws) when the path is unwritable", () => {
  const base = tmpDir("unwritable");
  const file = join(base, "not-a-dir");
  writeFileSync(file, "x");
  const st = ensureTaskRunsRoot(join(file, "child"));
  equal(st.ok, false, "ok:false instead of a throw");
  ok(typeof st.error === "string" && st.error.length > 0, "error surfaced");
});

section("run records — atomic round-trip + corrupt reads as ABSENT");

test("write/read round-trips the exact record and leaves no tmp file", () => {
  const dir = tmpDir("roundtrip");
  const rec = record();
  const w = writeRunRecord(dir, rec);
  equal(w.ok, true, `write succeeded: ${w.error ?? ""}`);
  deepEqual(readRunRecord(dir, rec.run_id), rec, "exact round-trip");
  const leftovers = readdirSync(dir).filter((f) => f.endsWith(".tmp"));
  deepEqual(leftovers, [], "atomic tmp+rename leaves no partial file");
  equal(statSync(w.path).mode & 0o777, 0o600, "record is owner-only 0600");
});

test("corrupt / malformed / missing records read as null", () => {
  const dir = tmpDir("corrupt");
  const id = mintRunId();
  writeFileSync(join(dir, `${id}.json`), "{not json", "utf-8");
  equal(readRunRecord(dir, id), null, "unparseable JSON");
  writeFileSync(join(dir, `${id}.json`), JSON.stringify({ foo: 1 }), "utf-8");
  equal(readRunRecord(dir, id), null, "missing run_id/status");
  writeFileSync(join(dir, `${id}.json`), JSON.stringify({ run_id: id }), "utf-8");
  equal(readRunRecord(dir, id), null, "missing status");
  equal(readRunRecord(dir, "does-not-exist"), null, "missing file");
  equal(readRunRecord(dir, "../escape"), null, "unsafe id is never read");
});

test("writeRunRecord reports ok:false (never throws) for an unwritable root", () => {
  const base = tmpDir("writefail");
  const file = join(base, "not-a-dir");
  writeFileSync(file, "x");
  const w = writeRunRecord(join(file, "child"), record());
  equal(w.ok, false, "ok:false instead of a throw");
  ok(typeof w.error === "string" && w.error.length > 0, "error surfaced for the caller");
});

test("runRecordPath/runLogPath are siblings under the root", () => {
  const dir = "/tmp/truns";
  const id = "abc-123";
  equal(runRecordPath(dir, id), join(dir, `${id}.json`));
  equal(runLogPath(dir, id), join(dir, `${id}.log`));
});

section("pidAlive + logMtimeMs");

test("pidAlive: our pid is alive; dead/invalid/init are not", () => {
  equal(pidAlive(process.pid), true, "our own pid");
  equal(pidAlive(999_999_999), false, "out-of-range pid");
  equal(pidAlive(null), false, "null");
  equal(pidAlive(undefined), false, "undefined");
  equal(pidAlive(1), false, "pid 1 is never probed");
  equal(pidAlive(0), false, "pid 0 is never probed");
});

test("logMtimeMs: a number when present, null when missing", () => {
  const dir = tmpDir("mtime");
  const log = runLogPath(dir, mintRunId());
  equal(logMtimeMs(log), null, "missing log");
  writeFileSync(log, "hello", "utf-8");
  ok(typeof logMtimeMs(log) === "number" && (logMtimeMs(log) as number) > 0, "existing log has an mtime");
});

section("bounded capture log (#1662 review)");

test("createBoundedLogWriter: caps the file while keeping the mtime fresh", () => {
  const dir = tmpDir("tee");
  const log = runLogPath(dir, "tee");
  const w = createBoundedLogWriter(log, 1000);
  ok(w !== null, "writer opens");
  if (!w) return;
  const before = logMtimeMs(log);
  for (let i = 0; i < 10; i++) w.write("x".repeat(400));
  ok(statSync(log).size <= 1000, `file stays within the cap (got ${statSync(log).size})`);
  equal(w.truncated(), true, "overflow was recorded");
  ok(readFileSync(log, "utf-8").length > 0, "recent output survives the truncation");
  const after = logMtimeMs(log);
  ok(after !== null && before !== null && after >= before, "the log mtime stays fresh (liveness clock)");
  w.close();
  w.close(); // idempotent
});

test("createBoundedLogWriter: a single oversized chunk keeps only its tail", () => {
  const dir = tmpDir("tee-oversize");
  const log = runLogPath(dir, "oversize");
  const w = createBoundedLogWriter(log, 1000);
  ok(w !== null, "writer opens");
  if (!w) return;
  w.write("y".repeat(5000));
  ok(statSync(log).size <= 1000, `oversized write is capped (got ${statSync(log).size})`);
  const body = readFileSync(log, "utf-8");
  equal(body.length, 1000, "the tail of the chunk survives, not nothing");
  w.close();
});

test("createBoundedLogWriter: an unopenable path returns null and never throws", () => {
  const dir = tmpDir("tee-fail");
  equal(createBoundedLogWriter(join(dir, "missing", "run.log"), 100), null, "null when it cannot open");
});

test("resolveTaskRunsLogMaxBytes: default + env override + invalid fallback", () => {
  equal(resolveTaskRunsLogMaxBytes({}), DEFAULT_TASK_RUNS_LOG_MAX_BYTES, "default cap");
  equal(resolveTaskRunsLogMaxBytes({ TASK_RUNS_LOG_MAX_BYTES: "2048" }), 2048, "env override");
  equal(resolveTaskRunsLogMaxBytes({ TASK_RUNS_LOG_MAX_BYTES: "bad" }), DEFAULT_TASK_RUNS_LOG_MAX_BYTES, "invalid falls back");
  equal(resolveTaskRunsLogMaxBytes({ TASK_RUNS_LOG_MAX_BYTES: "-1" }), DEFAULT_TASK_RUNS_LOG_MAX_BYTES, "non-positive falls back");
});

section("retention sweep (#1662 review)");

const DAY = 24 * 60 * 60 * 1000;

/** Seed a run record + log and backdate BOTH mtimes by ageMs. */
function seedRun(
  dir: string,
  opts: { status?: TaskRunRecord["status"]; pid?: number | null; ageMs?: number; logBytes?: number } = {},
): { id: string; logPath: string; recPath: string } {
  const id = mintRunId();
  const logPath = runLogPath(dir, id);
  writeFileSync(logPath, "L".repeat(opts.logBytes ?? 10), "utf-8");
  const rec = record({
    run_id: id,
    pid: opts.pid === undefined ? 999_999_999 : opts.pid,
    pgid: null,
    log_path: logPath,
    status: opts.status ?? "done",
  });
  const recPath = runRecordPath(dir, id);
  writeRunRecord(dir, rec);
  if (opts.ageMs) {
    const t = new Date(Date.now() - opts.ageMs);
    utimesSync(logPath, t, t);
    utimesSync(recPath, t, t);
  }
  return { id, logPath, recPath };
}

test("pruneTaskRuns: age-expired non-live runs are evicted (record + log); young ones survive", () => {
  const dir = tmpDir("prune-age");
  const old = seedRun(dir, { ageMs: 9 * DAY });
  const young = seedRun(dir, { ageMs: 1000 });
  const r = pruneTaskRuns(dir, { maxAgeMs: 7 * DAY, maxBytes: 1_000_000_000, now: Date.now() });
  equal(r.pruned, 1, "exactly the age-expired run");
  equal(existsSync(old.logPath), false, "old capture log removed");
  equal(existsSync(old.recPath), false, "old record removed");
  equal(existsSync(young.logPath), true, "young log survives");
  equal(existsSync(young.recPath), true, "young record survives");
  ok(r.freedBytes > 0, "freed bytes reported");
});

test("pruneTaskRuns: a LIVE running run is never evicted, even when ancient", () => {
  const dir = tmpDir("prune-live");
  const live = seedRun(dir, { status: "running", pid: process.pid, ageMs: 99 * DAY });
  const r = pruneTaskRuns(dir, { maxAgeMs: 1, maxBytes: 1, now: Date.now() });
  equal(r.pruned, 0, "live run kept");
  equal(r.keptLive, 1, "counted live");
  equal(existsSync(live.recPath), true, "live record survives");
  equal(existsSync(live.logPath), true, "live log survives");
});

test("pruneTaskRuns: a dead-pid running run is kept only while its log is fresh (settle grace)", () => {
  const dir = tmpDir("prune-settle");
  const fresh = seedRun(dir, { status: "running", pid: 999_999_999, ageMs: 0 });
  const stale = seedRun(dir, { status: "running", pid: 999_999_999, ageMs: 30 * 60_000 });
  const r = pruneTaskRuns(dir, { maxAgeMs: 1, maxBytes: 1_000_000_000, now: Date.now() });
  equal(existsSync(fresh.recPath), true, "settle-pending (fresh log) run survives the grace");
  equal(existsSync(stale.recPath), false, "stale settle-lost run is evictable and pruned");
  equal(r.pruned, 1, "only the stale run");
});

test("pruneTaskRuns: the byte cap evicts oldest non-live first; live bytes count but are never evicted", () => {
  const dir = tmpDir("prune-size");
  const a = seedRun(dir, { ageMs: 3000, logBytes: 600 });
  const b = seedRun(dir, { ageMs: 2000, logBytes: 600 });
  const live = seedRun(dir, { status: "running", pid: process.pid, ageMs: 10, logBytes: 600 });
  const r = pruneTaskRuns(dir, { maxAgeMs: 365 * DAY, maxBytes: 1000, now: Date.now() });
  equal(r.pruned, 2, "both non-live runs evicted to get under the cap");
  equal(existsSync(a.recPath), false, "oldest evicted first");
  equal(existsSync(b.recPath), false, "next-oldest evicted");
  equal(existsSync(live.recPath), true, "live run's bytes counted but never evicted");
  ok(r.freedBytes > 0, "freed bytes reported");
});

test("pruneTaskRuns: a symlinked run file is never followed or deleted", () => {
  const dir = tmpDir("prune-symlink");
  const outside = join(dir, "outside.txt");
  writeFileSync(outside, "PRECIOUS", "utf-8");
  symlinkSync(outside, join(dir, `${mintRunId()}.json`));
  const r = pruneTaskRuns(dir, { maxAgeMs: 1, maxBytes: 1, now: Date.now() });
  equal(existsSync(outside), true, "symlink target untouched");
  equal(readFileSync(outside, "utf-8"), "PRECIOUS", "target unmodified");
  equal(r.pruned, 0, "a symlink is not a run");
});

test("pruneTaskRuns: an absent root is a clean no-op", () => {
  const r = pruneTaskRuns(join(tmpDir("prune-absent"), "nope"), { maxAgeMs: 1, maxBytes: 1 });
  deepEqual(r, { examined: 0, pruned: 0, freedBytes: 0, keptLive: 0, errors: [] });
});

test("resolveTaskRunsPruneBounds: 7-day/2-GiB defaults + env overrides + invalid fallback", () => {
  const d = resolveTaskRunsPruneBounds({});
  equal(d.maxBytes, 2 * 1024 * 1024 * 1024, "2 GiB default");
  equal(d.maxAgeMs, 7 * DAY, "7 day default");
  const o = resolveTaskRunsPruneBounds({ TASK_RUNS_MAX_AGE_DAYS: "1", TASK_RUNS_MAX_BYTES: "1024" });
  equal(o.maxAgeMs, DAY, "1 day override");
  equal(o.maxBytes, 1024, "byte override");
  equal(resolveTaskRunsPruneBounds({ TASK_RUNS_MAX_BYTES: "bad" }).maxBytes, 2 * 1024 * 1024 * 1024, "invalid falls back");
});

// ── Results ─────────────────────────────────────────────

setTimeout(() => {
  for (const d of TMP_DIRS) { try { rmSync(d, { recursive: true, force: true }); } catch {} }
  console.log(`\n=== Results: ${passed} passed, ${failed} failed ===`);
  if (failed > 0) { console.log("❌ SOME TESTS FAILED"); process.exit(1); }
  console.log("✅ ALL TESTS PASSED");
}, 500);
