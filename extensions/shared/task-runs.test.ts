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
  ensureTaskRunsRoot,
  logMtimeMs,
  mintRunId,
  pidAlive,
  readRunRecord,
  resolveTaskRunsRoot,
  runLogPath,
  runRecordPath,
  safeRunId,
  writeRunRecord,
  type TaskRunRecord,
} from "./task-runs.js";
import { ok, equal, deepEqual } from "node:assert/strict";
import { mkdtempSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
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

// ── Results ─────────────────────────────────────────────

setTimeout(() => {
  for (const d of TMP_DIRS) { try { rmSync(d, { recursive: true, force: true }); } catch {} }
  console.log(`\n=== Results: ${passed} passed, ${failed} failed ===`);
  if (failed > 0) { console.log("❌ SOME TESTS FAILED"); process.exit(1); }
  console.log("✅ ALL TESTS PASSED");
}, 500);
