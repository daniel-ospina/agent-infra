/**
 * task-signal-forensics.test.ts — #2932.
 *
 * Two arms, and each one is proven by a REAL process receiving a REAL SIGTERM:
 *
 *   arm 1  the victim records WHO signalled it (pid + the parent's `ps` row),
 *          into a file it writes itself, before it dies;
 *   arm 2  the victim's uncommitted work survives the death, as a snapshot
 *          commit pinned by `refs/lane-checkpoints/…`, with the branch, HEAD,
 *          the real index and the working tree untouched.
 *
 * Non-vacuity controls (a guard nobody can validate is inert by construction):
 *   • the fixture must be provably ALIVE and dirty before the signal, or the
 *     "work survived" assertion would pass on a lane that never had work;
 *   • the exit status must still be SIGTERM/143 — an instrument that rescues the
 *     work but makes the child unkillable trades one defect for a worse one;
 *   • `git status --porcelain` and `HEAD` must be IDENTICAL before and after, so
 *     "the work survived" cannot be satisfied by writing it into the branch.
 *
 * The fixture is a REAL process: a temp `.mjs` bootstrap that imports the
 * extension source by its own path, arms it, and idles. It is a direct child of
 * this suite (so `ppid` is this process, which is what arm 1 asserts) and it
 * receives a real SIGTERM. Nothing is copied, so a mutant that removes the trap
 * reddens these assertions rather than a fixture's re-implementation of them.
 *
 * Run: npx tsx extensions/task-signal-forensics.test.ts
 */

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { pathToFileURL } from "node:url";
import { spawn, execFileSync } from "node:child_process";
import { ok, equal, deepEqual } from "node:assert/strict";

import {
  CHECKPOINT_REF_PREFIX,
  SIGNAL_LOG_MAX_BYTES,
  appendSignalRecord,
  buildSignalRecord,
  checkpointActive,
  checkpointRefName,
  checkpointWorktree,
  clampArgv,
  defaultGitRunner,
  gitOpInProgress,
  installSignalForensics,
  signalForensicsActive,
  _resetArmedForTests,
  type CheckpointResult,
  type GitRunner,
  type LaneSignalRecord,
} from "./task-signal-forensics.js";

const EXTENSION_SOURCE = path.resolve(path.dirname(new URL(import.meta.url).pathname), "task-signal-forensics.ts");
/** The one shared module the extension imports (see `spawnLane`'s bridge below). */
const SHARED_REDACT_SOURCE = path.resolve(
  path.dirname(new URL(import.meta.url).pathname),
  "shared/redact-command.ts",
);

// ── suite harness ───────────────────────────────────────────────────────────

let passed = 0;
let failed = 0;
const tests: Array<[string, () => void | Promise<void>]> = [];
function test(name: string, fn: () => void | Promise<void>): void {
  tests.push([name, fn]);
}
const cleanups: Array<() => void> = [];

function tmpDir(prefix: string): string {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  cleanups.push(() => fs.rmSync(d, { recursive: true, force: true }));
  return d;
}

function git(cwd: string, args: string[]): string {
  return execFileSync("git", args, { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
}

/** A repo with one commit and a deliberately dirty tree: one modified tracked
 * file and one untracked file (the untracked half is what a `stash create`
 * checkpoint silently drops). */
function dirtyRepo(): string {
  const dir = tmpDir("lane-sig-repo-");
  git(dir, ["init", "-q"]);
  git(dir, ["config", "user.email", "suite@invalid"]);
  git(dir, ["config", "user.name", "suite"]);
  git(dir, ["config", "commit.gpgsign", "false"]);
  fs.writeFileSync(path.join(dir, "tracked.txt"), "original\n");
  git(dir, ["add", "tracked.txt"]);
  git(dir, ["commit", "-q", "-m", "base"]);
  fs.writeFileSync(path.join(dir, "tracked.txt"), "MODIFIED AFTER COMMIT\n");
  fs.writeFileSync(path.join(dir, "untracked.txt"), "NEW FILE THAT MUST SURVIVE\n");
  return dir;
}

function readRecords(logPath: string): LaneSignalRecord[] {
  if (!fs.existsSync(logPath)) return [];
  return fs
    .readFileSync(logPath, "utf8")
    .split("\n")
    .filter((l) => l.trim() !== "")
    .map((l) => JSON.parse(l) as LaneSignalRecord);
}

/**
 * The lane fixture, written fresh per spawn: import the extension source, arm
 * it, announce readiness, then idle forever.
 *
 * The source is copied to a `.mts` path first because this repo's package.json
 * declares `"type": "commonjs"`, so a `.ts` file is CJS to Node and ESM syntax
 * is refused — `.mts` is unambiguously ESM and needs no transpiler. The copy is
 * BYTE-IDENTICAL to the tracked source, made per spawn, so the code under test
 * is the real one and a mutant (which patches the source before this runs)
 * reaches the child.
 */
const LANE_FIXTURE_SOURCE = `
const extensionUrl = process.env.LANE_EXT_URL;
if (!extensionUrl) { console.error('LANE_EXT_URL missing'); process.exit(9); }
const mod = await import(extensionUrl);
mod.default(undefined);
process.stdout.write('READY ' + process.pid + ' cwd=' + process.cwd() + '\\n');
setInterval(() => {}, 60000);
`;

/** Spawn the lane fixture in `repoDir`, wait for READY, hand back the handle. */
function spawnLane(repoDir: string, logPath: string): Promise<{
  child: ReturnType<typeof spawn>;
  pid: number;
  stop: () => Promise<{ code: number | null; signal: string | null }>;
  stderr: () => string;
}> {
  return new Promise((resolve, reject) => {
    const work = tmpDir("lane-sig-fixture-");
    const fixture = path.join(work, "lane-fixture.mjs");
    fs.writeFileSync(fixture, LANE_FIXTURE_SOURCE);
    const extensionCopy = path.join(work, "task-signal-forensics.mts");
    fs.copyFileSync(EXTENSION_SOURCE, extensionCopy);
    // ── the `.js`→`.ts` bridge, for RAW node only ────────────────────────────
    // The extension imports the repo's shared redaction seam as
    // `./shared/redact-command.js` (the repo's convention — pi's loader and tsx
    // both resolve that specifier to the `.ts` source), but this fixture spawns
    // the lane under bare `node --experimental-strip-types`, which does NOT
    // rewrite a `.js` specifier to `.ts` (measured). So the fixture reproduces
    // the import graph itself: the REAL module is copied next to the lane, and a
    // two-line plain-JS shim gives bare node the name its resolver insists on.
    //
    // ⛔ The shim RE-EXPORTS the real module; it must never carry a copy of the
    // redaction rules. A second redactor is the exact drift the shared seam exists
    // to prevent (#966), and a fixture that graded a copy would prove nothing
    // about the module production loads.
    const sharedDir = path.join(work, "shared");
    fs.mkdirSync(sharedDir, { recursive: true });
    fs.copyFileSync(SHARED_REDACT_SOURCE, path.join(sharedDir, "redact-command.ts"));
    fs.writeFileSync(
      path.join(sharedDir, "redact-command.js"),
      'export { redactCommand } from "./redact-command.ts";\n',
    );
    const child = spawn(process.execPath, ["--experimental-strip-types", fixture], {
      cwd: fs.realpathSync(repoDir),
      env: {
        ...process.env,
        TASK_HEARTBEAT: "1",
        PI_MODE: "print",
        LANE_SIGNAL_LOG: logPath,
        TASK_LANE_CHECKPOINT: "1",
        TASK_SIGNAL_FORENSICS: "1",
        LANE_EXT_URL: pathToFileURL(extensionCopy).href,
        NODE_ENV: "production", // keep the extension's test-only resets off
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let out = "";
    let err = "";
    child.stdout?.on("data", (b: Buffer) => {
      out += b.toString();
      if (out.includes("READY ")) {
        resolve({
          child,
          pid: child.pid as number,
          stderr: () => err,
          stop: () =>
            new Promise((res) => {
              child.on("close", (code, signal) => res({ code, signal }));
            }),
        });
      }
    });
    child.stderr?.on("data", (b: Buffer) => {
      err += b.toString();
    });
    child.on("error", reject);
    child.on("close", (code, signal) => {
      if (!out.includes("READY ")) reject(new Error(`lane fixture died before READY (code=${code} signal=${signal}) stderr=${err}`));
    });
  });
}

// ── arm 1 + arm 2: the end-to-end proof ─────────────────────────────────────

test("E2E: a TERMed lane records its signaller and keeps its work (arms 1 + 2)", async () => {
  const repo = dirtyRepo();
  const logPath = path.join(tmpDir("lane-sig-log-"), "lane-signals.jsonl");

  // Controls BEFORE the signal: the fixture is dirty and has a HEAD to point at.
  const statusBefore = git(repo, ["status", "--porcelain"]);
  const headBefore = git(repo, ["rev-parse", "HEAD"]);
  ok(statusBefore.includes("tracked.txt"), "fixture control: the worktree is dirty before the signal (non-vacuity)");

  const lane = await spawnLane(repo, logPath);
  ok(lane.pid > 0, "fixture control: the lane process exists before the signal (non-vacuity)");

  lane.child.kill("SIGTERM");
  const { code, signal } = await lane.stop();

  // ── exit status: an instrument must never make a child unkillable ────────
  const diedBySignal = signal === "SIGTERM" || code === 143;
  ok(
    diedBySignal,
    `exit status preserved (SIGTERM/143) — got code=${code} signal=${signal} stderr=${lane.stderr().slice(-400)}`,
  );

  // ── arm 1: WHO ──────────────────────────────────────────────────────────
  const records = readRecords(logPath);
  equal(records.length, 1, `arm 1: the signal log has exactly one record (got ${records.length})`);
  const rec = records[0];
  equal(rec.event, "lane-signalled", "arm 1: record carries the event name");
  equal(rec.signal, "SIGTERM", "arm 1: record names the signal");
  equal(rec.pid, lane.pid, "arm 1: record names the VICTIM pid");
  equal(rec.ppid, process.pid, "arm 1: record names the real parent pid (this test process)");
  equal(rec.parent_alive, true, "arm 1: the parent was still alive when the signal landed");
  ok(rec.parent_argv.length > 0, `arm 1: the parent's command line was read at signal time (got ${JSON.stringify(rec.parent_argv)})`);
  ok(
    /task-signal-forensics\.test\.ts/.test(rec.parent_argv),
    `arm 1: parent_argv identifies THIS test's command line (got ${JSON.stringify(rec.parent_argv.slice(0, 160))})`,
  );
  equal(rec.cwd, fs.realpathSync(repo), "arm 1: record names the victim's cwd");
  ok(typeof rec.ts === "string" && !Number.isNaN(Date.parse(rec.ts)), "arm 1: record is timestamped ISO-8601");

  // ── arm 2: the work ─────────────────────────────────────────────────────
  equal(rec.checkpoint.status, "saved", `arm 2: the checkpoint was SAVED (got ${rec.checkpoint.status}/${rec.checkpoint.reason})`);
  const ref = rec.checkpoint.ref ?? "";
  ok(ref.startsWith(CHECKPOINT_REF_PREFIX), `arm 2: the ref lives under ${CHECKPOINT_REF_PREFIX} (got ${ref})`);
  const refCommit = git(repo, ["rev-parse", "--verify", ref]);
  equal(refCommit, rec.checkpoint.commit ?? "", "arm 2: the pinned ref resolves to the recorded commit");
  equal(
    git(repo, ["show", `${ref}:tracked.txt`]),
    "MODIFIED AFTER COMMIT",
    "arm 2: the snapshot carries the modified tracked file",
  );
  equal(
    git(repo, ["show", `${ref}:untracked.txt`]),
    "NEW FILE THAT MUST SURVIVE",
    "arm 2: the snapshot carries the UNTRACKED file (stash-create would have dropped it)",
  );

  // ── arm 2 must not be satisfied by touching the branch ──────────────────
  equal(git(repo, ["rev-parse", "HEAD"]), headBefore, "arm 2 control: HEAD did not move (no commit was made)");
  equal(git(repo, ["status", "--porcelain"]), statusBefore, "arm 2 control: the working tree is byte-identical (nothing was stashed away)");
});

// ── gates ───────────────────────────────────────────────────────────────────

test("gate: arm 1 arms only for a dispatch child", () => {
  ok(signalForensicsActive({ TASK_HEARTBEAT: "1", PI_MODE: "print" }), "armed for the dispatch-child pair");
  ok(!signalForensicsActive({ TASK_HEARTBEAT: "1" }), "NOT armed without PI_MODE=print");
  ok(!signalForensicsActive({ PI_MODE: "print" }), "NOT armed without TASK_HEARTBEAT=1");
  ok(!signalForensicsActive({ TASK_HEARTBEAT: "1", PI_MODE: "interactive" }), "NOT armed in an interactive session");
  ok(!signalForensicsActive({ TASK_HEARTBEAT: "1", PI_MODE: "print", TASK_SIGNAL_FORENSICS: "0" }), "valve disarms arm 1");
  ok(checkpointActive({ TASK_HEARTBEAT: "1", PI_MODE: "print" }), "arm 2 follows arm 1's population");
  ok(
    !checkpointActive({ TASK_HEARTBEAT: "1", PI_MODE: "print", TASK_LANE_CHECKPOINT: "0" }),
    "TASK_LANE_CHECKPOINT=0 disarms arm 2 alone",
  );
});

test("arm 1: the record shape is bounded and typed", () => {
  const long = `${"-".repeat(600)}\nwith-a-newline`;
  ok(clampArgv(long).length <= 400, `clampArgv bounds a long command line (got ${clampArgv(long).length})`);
  ok(!clampArgv(long).includes("\n"), "clampArgv collapses newlines so one record stays one line");

  const rec = buildSignalRecord({
    signal: "SIGINT",
    pid: 42,
    facts: { ppid: 7, parentArgv: "pi", parentComm: "pi", parentAlive: true },
    pgid: 42,
    cwd: "/x",
    checkpoint: { status: "skipped", reason: "clean" },
    now: 1793133305000,
  });
  equal(rec.event, "lane-signalled", "event name");
  equal(rec.ppid, 7, "ppid");
  equal(rec.pgid, 42, "pgid");
  equal(rec.ts, new Date(1793133305000).toISOString(), "ts is the ISO form of the injected clock");
  ok(JSON.stringify(rec).includes('"reason":"clean"'), "the checkpoint reason travels inside the record");
});

test("arm 1: a credential on the parent's command line never reaches the log", () => {
  // The recorded value is a shell command line, the exact shape that carries an
  // inline `GH_TOKEN=…` / `ghp_…`. Both classes are asserted, because the shared
  // seam has one pattern per class and a test on only one would let the other
  // regress silently.
  const build = (parentArgv: string) =>
    buildSignalRecord({
      signal: "SIGTERM",
      pid: 43,
      facts: { ppid: 7, parentArgv, parentComm: "/bin/bash", parentAlive: true },
      cwd: "/x",
      checkpoint: { status: "skipped", reason: "clean" },
      now: 1_793_133_305_000,
    });

  const inlineEnv = build("/bin/bash -c export GH_TOKEN=ghp_liveSecretValue123 && pi -p").parent_argv;
  ok(
    !/ghp_liveSecretValue123/.test(inlineEnv),
    `arm 1: an inline GH_TOKEN=… is redacted before it is persisted (got ${JSON.stringify(inlineEnv)})`,
  );

  const bareToken = build("pi -p --flag ghp_bareTokenValue456");
  ok(
    !/ghp_bareTokenValue456/.test(bareToken.parent_argv),
    `arm 1: a bare token body is redacted whole, not up to the underscore (got ${JSON.stringify(bareToken.parent_argv)})`,
  );
  equal(
    bareToken.parent_argv,
    "pi -p --flag ghp_***",
    "arm 1: the redaction is the shared seam's own rule, not a second copy",
  );
});

test("arm 1: the log is append-only and rotates at the ceiling", () => {
  const dir = tmpDir("lane-sig-append-");
  const log = path.join(dir, "signals.jsonl");
  const rec = (n: number) =>
    buildSignalRecord({
      signal: "SIGTERM",
      pid: n,
      facts: { ppid: 1, parentArgv: "p", parentComm: "p", parentAlive: true },
      cwd: "/x",
      checkpoint: { status: "skipped", reason: "clean" },
      now: 1_793_133_305_000,
    });
  appendSignalRecord(log, rec(1));
  appendSignalRecord(log, rec(2));
  equal(readRecords(log).length, 2, "two deaths append two records (never overwrite)");

  fs.writeFileSync(log, "x".repeat(SIGNAL_LOG_MAX_BYTES + 10));
  appendSignalRecord(log, rec(3));
  ok(fs.existsSync(`${log}.1`), "the ceiling rotates the log to .1 rather than discarding history");
  equal(readRecords(log).length, 1, "the rotated log starts clean with the new record");
});

// ── arm 2 unit legs ─────────────────────────────────────────────────────────

test("arm 2: a clean worktree records `skipped/clean` and creates no ref", () => {
  const repo = dirtyRepo();
  git(repo, ["checkout", "--", "tracked.txt"]);
  fs.rmSync(path.join(repo, "untracked.txt"));
  const r = checkpointWorktree({ cwd: repo, now: Date.now(), pid: 99 });
  equal(r.status, "skipped", "nothing to save");
  equal(r.reason, "clean", "and it says why");
  equal(git(repo, ["for-each-ref", CHECKPOINT_REF_PREFIX]), "", "a clean worktree pins no ref");
});

test("arm 2: outside a repo it skips instead of throwing", () => {
  const dir = tmpDir("lane-sig-norepo-");
  const r = checkpointWorktree({ cwd: dir, now: Date.now(), pid: 99 });
  equal(r.status, "skipped", "not-a-repo is a skip, not a crash");
  equal(r.reason, "not-a-repo", "and it names the reason");
});

test("arm 2: a repo operation in flight is refused BY NAME, not silently skipped", () => {
  const repo = dirtyRepo();
  const gitDir = git(repo, ["rev-parse", "--absolute-git-dir"]);
  fs.writeFileSync(path.join(gitDir, "MERGE_HEAD"), "0".repeat(40) + "\n");
  equal(gitOpInProgress(gitDir), "MERGE_HEAD", "the in-progress marker is detected");
  const r = checkpointWorktree({ cwd: repo, now: Date.now(), pid: 99 });
  equal(r.status, "skipped", "no snapshot is claimed during a merge");
  equal(r.reason, "git-op-in-progress:MERGE_HEAD", "the marker is named in the reason");
  fs.rmSync(path.join(gitDir, "MERGE_HEAD"));
});

test("arm 2: a failing git step is reported as failed, never as saved", () => {
  const repo = dirtyRepo();
  // The identity probes answer for real; every mutating step fails. The failure
  // therefore lands on `read-tree`, not on "this is not a repo".
  const failing: GitRunner = (args, extraEnv, timeoutMs, cwd) =>
    args[0] === "rev-parse"
      ? defaultGitRunner(args, extraEnv, timeoutMs, cwd)
      : { ok: false, out: "", timedOut: false };
  const r = checkpointWorktree({ cwd: repo, now: Date.now(), pid: 99, run: failing });
  equal(r.status, "failed", "a broken git must not read as success");
  equal(r.reason, "read-tree-failed", "and the failing step is named");
});

test("arm 2: an exhausted budget stops the snapshot instead of overrunning", () => {
  const repo = dirtyRepo();
  // The repo identity is answered for real; the HEAD probe reports a timeout, so
  // the arm must classify a TIMEOUT as failed (a skipped "no-head" would read as
  // "there was nothing to save" when the truth is "we ran out of time").
  const slow: GitRunner = (args, extraEnv, timeoutMs, cwd) => {
    if (args[0] === "rev-parse" && args[1] === "--absolute-git-dir") {
      return { ok: true, out: git(cwd, ["rev-parse", "--absolute-git-dir"]), timedOut: false };
    }
    return { ok: false, out: "", timedOut: true };
  };
  const r = checkpointWorktree({ cwd: repo, now: Date.now(), pid: 99, run: slow, budgetMs: 1_000 });
  equal(r.status, "failed", "a timed-out step fails the arm");
  equal(r.reason, "git-timeout", "and names the timeout");
});

test("arm 2: two deaths in one worktree pin two distinct refs", () => {
  const repo = dirtyRepo();
  const a = checkpointWorktree({ cwd: repo, now: 1_793_133_300_000, pid: 1 });
  const b = checkpointWorktree({ cwd: repo, now: 1_793_133_305_000, pid: 2 });
  equal(a.status, "saved", "first saved");
  equal(b.status, "saved", "second saved");
  ok(a.ref !== b.ref, "the ref name carries the clock and the pid, so two deaths cannot collide");
  equal(checkpointRefName(1_793_133_300_000, 7), `${CHECKPOINT_REF_PREFIX}${new Date(1_793_133_300_000).toISOString().replace(/[:.]/g, "")}-7`, "ref name shape");
  ok(
    /^refs\/lane-checkpoints\/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]+Z-7$/.test(checkpointRefName(1_793_133_300_000, 7)),
    "ref name is a valid, sortable refname (no colon, no space)",
  );
});

// ── the signal path without a process ───────────────────────────────────────

test("arm 1: install returns false when the gate is off, and records nothing", () => {
  _resetArmedForTests();
  const dir = tmpDir("lane-sig-gate-");
  const log = path.join(dir, "signals.jsonl");
  equal(installSignalForensics({ env: { TASK_HEARTBEAT: "1", PI_MODE: "interactive" }, logPath: log }), false, "gate off");
  equal(readRecords(log).length, 0, "nothing was written");
});

test("arm 1: the re-raise is skipped when another owner holds the lifecycle", () => {
  _resetArmedForTests();
  const dir = tmpDir("lane-sig-owner-");
  const log = path.join(dir, "signals.jsonl");
  const raised: Array<[number, string]> = [];
  const exits: number[] = [];
  let otherCalls = 0;
  const other = (): void => {
    otherCalls += 1;
  };
  process.on("SIGTERM", other);
  try {
    ok(
      installSignalForensics({
        env: { TASK_HEARTBEAT: "1", PI_MODE: "print" },
        logPath: log,
        senderProbe: () => ({ ppid: 1, parentArgv: "pi", parentComm: "pi", parentAlive: true }),
        checkpoint: () => ({ status: "skipped", reason: "clean" }),
        raiseSignal: (pid, sig) => void raised.push([pid, sig]),
        exitProcess: (code) => void exits.push(code),
      }),
      "installed",
    );
    process.emit("SIGTERM");
    equal(readRecords(log).length, 1, "the record is still written when someone else owns the exit");
    equal(otherCalls, 1, "the other listener ran — this arm never suppresses it");
    deepEqual(raised, [], "NO re-raise: pi's graceful shutdown owns the lifecycle (session_end, capture)");
  } finally {
    process.removeListener("SIGTERM", other);
    process.removeAllListeners("SIGTERM");
    _resetArmedForTests();
  }
});

test("arm 1: as the SOLE listener it re-raises the same signal", () => {
  _resetArmedForTests();
  const dir = tmpDir("lane-sig-sole-");
  const log = path.join(dir, "signals.jsonl");
  const raised: Array<[number, string]> = [];
  const exits: number[] = [];
  ok(
    installSignalForensics({
      env: { TASK_HEARTBEAT: "1", PI_MODE: "print" },
      logPath: log,
      senderProbe: () => ({ ppid: 1, parentArgv: "pi", parentComm: "pi", parentAlive: false }),
      checkpoint: () => ({ status: "skipped", reason: "clean" }),
      raiseSignal: (pid, sig) => void raised.push([pid, sig]),
      exitProcess: (code) => void exits.push(code),
    }),
    "installed",
  );
  process.emit("SIGTERM");
  equal(raised.length, 1, "exactly one re-raise");
  equal(raised[0][0], process.pid, "the re-raise targets this process");
  equal(raised[0][1], "SIGTERM", "with the same signal, so the exit status is unchanged");
  const rec = readRecords(log)[0];
  equal(rec.parent_alive, false, "a parent that is gone is recorded as gone, not as an empty argv");
  process.removeAllListeners("SIGTERM");
  _resetArmedForTests();
});

// ── runner ──────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  // The install latches process-wide; the suite drives more than one install, so
  // it uses the extension's NODE_ENV=test reset seam (#212 convention).
  process.env.NODE_ENV = "test";
  process.stdout.write("== task-signal-forensics (#2932) ==\n");
  for (const [name, fn] of tests) {
    try {
      await fn();
      passed += 1;
      process.stdout.write(`   ✅ ${name}\n`);
    } catch (err) {
      failed += 1;
      const msg = (err as Error)?.message ?? String(err);
      process.stdout.write(`   ❌ ${name}\n      ${msg}\n`);
    }
  }
  for (const c of cleanups) {
    try {
      c();
    } catch {
      /* best effort */
    }
  }
  process.stdout.write(`\ntests: ${passed} passed, ${failed} failed\n`);
  process.exit(failed === 0 ? 0 : 1);
}

void main().catch((err) => {
  process.stderr.write(`suite crashed: ${(err as Error)?.stack ?? err}\n`);
  process.exit(1);
});
