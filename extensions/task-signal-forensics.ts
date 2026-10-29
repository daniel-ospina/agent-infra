/**
 * task-signal-forensics — record what was knowable at signal time, and
 * checkpoint the work before the process dies (#2932).
 *
 * ⛔ IT DOES NOT RECORD WHO SIGNALLED, and the whole file is written so that
 * nobody can read it as if it did. What is recorded is `ppid_at_signal`: the
 * **parent** the victim was born with. Anything can send `SIGTERM` to a child
 * whose parent is the supervisor, and the record will then name the supervisor —
 * with no field, and no `ps` probe, able to tell that case from a kill by the
 * parent itself. Node's signal API carries no sender identity (the kernel's
 * `siginfo.si_pid` is not surfaced by libuv), so this is a property of the
 * instrument, not of the effort behind it.
 *
 * A record therefore answers ONE of two questions, and the `sender` field says
 * which one it can answer:
 *
 *   `sender: "unrecorded"`   always, today — the field exists so this stays a
 *                            MACHINE-READABLE statement rather than prose, and so
 *                            a future platform that can supply it has a home.
 *   `ppid_at_signal`         the parent at signal time. It **names the sender IFF
 *                            the parent was the sender**, and otherwise proves only
 *                            that the parent was still alive with that argv.
 *
 * Measured, not assumed: the suite spawns a victim whose parent is the suite and
 * has a THIRD process deliver the `SIGTERM`; the record then names the suite, not
 * the sender (`P1: a THIRD process's SIGTERM is recorded as the PARENT`).
 *
 * ── The failure this exists for ───────────────────────────────────────────────
 * On 2026-10-27, 17 dispatched `pi -p` children were SIGTERM'd inside 3 s
 * (15:35:02 → 15:35:05) across four repositories, and three worktrees were left
 * with 16 uncommitted files and 0 commits. Every run record said the same thing:
 *
 *     exit_code: 143,  reason: "non-zero-exit"
 *
 * and the child's own log ended with the markers a SUCCESSFUL run ends with
 * (`[task-heartbeat] session_end nonce=…` is emitted from `session_shutdown`, so
 * it is written on the way down however the process is going down). Nothing on
 * the box recorded who sent the signal: macOS logs no `kill(2)` sender, `log
 * show` has no `SIGTERM` event class, and the sender may have exited (or had its
 * pid reused) long before anyone looks.
 *
 * So the evidence is collected AT SIGNAL TIME, in the victim, from the only
 * facts that still exist then: `$PPID`, that parent's `ps` row, and the fact of
 * the signal itself. What that buys is a RULE-OUT, not an accusation.
 *
 * ── Arm 1 — the record ───────────────────────────────────────────────────────
 * One JSON line per death, appended to `~/.pi/agent/lane-signals.jsonl`
 * (override: `LANE_SIGNAL_LOG`):
 *
 *     {"event":"lane-signalled","signal":"SIGTERM","pid":63127,
 *      "ppid_at_signal":{"pid":1920,"argv":"pi","comm":"pi","alive":true},
 *      "sender":"unrecorded","sender_note":"…","pgid":63127,
 *      "cwd":"/…/.worktrees/w-drainer-fix",
 *      "checkpoint":{"status":"saved","ref":"refs/lane-checkpoints/…"},
 *      "ts":"2026-10-27T19:35:02.914Z"}
 *
 * The field is `ppid_at_signal` and not `ppid` because the qualifier is the whole
 * claim: it was the parent AT THAT MOMENT, read with `ps` before the process
 * died, and the parent relationship is the only thing the probe measures. Before
 * this rename the field, the stderr line and this header all said "sender",
 * which read as attribution of a fact the instrument cannot observe.
 *
 * A file rather than the run record on purpose: the run record belongs to the
 * PARENT, and a parent that is itself being killed cannot be relied on to write
 * it. The child writes this line before it dies, unconditionally.
 *
 * ── Arm 2 — checkpoint, so a death cannot cost the work ──────────────────────
 * On the same signal, uncommitted work in the cwd is captured as a **snapshot
 * commit pinned by a ref**, using plumbing against a TEMPORARY index.
 *
 * ⛔ WHY THIS IS NOT A CALL TO `scripts/bg-rescue-wip.sh` (the repo's existing
 * rescue, #2045) — the one line the #2934 review asked for, with the numbers:
 * that tool's guarantee is "reachable from `refs/wip/<slug>` on ORIGIN", and its
 * own bounds are `bounded 25 git fetch` + `bounded 45 git push`. Since agent-infra#2834
 * it is called at the END of `spawn-gate.sh`'s `run_agent`, at every terminal
 * transition of a harness lane (`lane.sh` / `fix-one.sh` / `nonblocking-dispatch.sh`)
 * — so it is reached only after the agent has STOPPED; it
 * also refuses any path that is not a worktree ROOT. Inside a victim whose parent
 * escalates `SIGTERM` → **5 s** → `SIGKILL`, a 25 s + 45 s tool cannot finish, and
 * the parent's `SIGKILL` would take arm 1's append with it. The other existing
 * capture, `cap_wip_snapshot` in `scripts/orchestrator-harness/spawn-gate.sh`, runs
 * AFTER `run_agent`'s cap kill has landed and hangs off `run_agent` — a `task`
 * child has no `run_agent`. So neither existing mechanism fires inside the window
 * or covers this population; arm 2 is the local, in-death leg, and its guarantee
 * is deliberately the weaker one that is REACHABLE in 1.5 s: the work is in the
 * object database, pinned by a ref. The recovery for a checkpointed lane is
 * documented (`docs/ops/lane-signal-forensics.md`), not implied.
 *
 * The mechanism:
 *
 *     GIT_INDEX_FILE=<tmp> git read-tree HEAD
 *     GIT_INDEX_FILE=<tmp> git add -A           ← untracked files included
 *     tree=$(GIT_INDEX_FILE=<tmp> git write-tree)
 *     commit=$(git commit-tree "$tree" -p HEAD -m …)
 *     git update-ref refs/lane-checkpoints/<iso>-<pid> "$commit"
 *
 * The branch, HEAD, the real index and the working tree are never touched, so
 * this cannot collide with a `git commit` the lane was running and cannot create
 * a merge conflict. Recovery is `git log refs/lane-checkpoints/*` or
 * `git cherry-pick <ref>`.
 *
 * ⛔ WHAT IT DOES NOT CAPTURE. The snapshot is built from the WORKTREE, so a file
 * whose staged content differs from its worktree content is captured as the
 * worktree version — the staged half is not separately preserved. That is a
 * deliberate trade (the worktree is what a kill actually loses, and the staged
 * version is recoverable from the real index for as long as the clone lives), but
 * it means "nothing is ever lost" would be an overstatement. `git add -A` also
 * follows normal git semantics, so ignored untracked files are not captured.
 *
 * ⛔ WHY NOT "make the lane's first action a commit". An empty first commit does
 * not save anything: the 16 files that died were created AFTER the lane's first
 * action, and an empty commit at minute 0 is worth nothing at minute 130. The
 * snapshot has to be taken at the END (the signal), which is the only moment
 * that knows what the lane had.
 *
 * ⛔ WHY NOT `git stash`. `git stash push` REMOVES the changes from the tree —
 * in a shared worktree whose lane may be resumed by a human, an emergency
 * handler must not also mutate what it is preserving. `stash create` does not
 * include untracked files, which is most of what a killed lane leaves behind.
 *
 * ── Gating, coverage, and non-behaviour-change ────────────────────────────
 * Armed only for a DISPATCH CHILD — `TASK_HEARTBEAT=1` + `PI_MODE=print`, a pair
 * that only the two in-process dispatchers set, and both set it unconditionally:
 * `extensions/builtin-tools` (`subAgentEnv`, the `task` tool) and
 * `extensions/subagent` (`childEnv`, the `subagent` tool).
 *
 * ⛔ COVERAGE, STATED AS A POPULATION LIST BECAUSE "armed in every dispatched
 * `pi -p` child" — what this header said before the #2934 review — IS FALSE.
 * Measured on this tree, the armed and unarmed `pi -p` populations are:
 *
 *   ARMED      `task`-tool children      TASK_HEARTBEAT=1 + PI_MODE=print are
 *              `subagent`-tool children  forced into the child env at the spawn
 *                                       site by both dispatchers
 *   NOT ARMED  harness lanes             `lane.sh` / `fix-one.sh` / `merge-one.sh`
 *              (`scripts/orchestrator-harness/`) run `pi -p --no-session` inside
 *                                       `spawn-gate.sh`'s `run_agent`, which sets
 *                                       NEITHER marker
 *              fleet sessions           `pi -p` with no PI_MODE, so
 *                                       `signalForensicsActive` is false
 *              `cloud-cell-bringup.sh`  a 120 s provider probe, not a dispatch
 *
 * #2932's victims were `task`-tool children — their `~/.pi/agent/task-runs/*.json`
 * records are what identified them — so the population that lost the work IS
 * covered. The harness lanes are NOT, and their capture is a DIFFERENT mechanism
 * with a DIFFERENT trigger (`cap_wip_snapshot` fires at the cap, not at a
 * signal), so a harness lane killed BELOW its cap is uncovered, and this header
 * says so instead of reading as complete. `merge-one.sh` carries its own
 * `run_agent` copy and has no snapshot at all.
 *
 * `TASK_SIGNAL_FORENSICS=0` disarms arm 1, `TASK_LANE_CHECKPOINT=0` disarms
 * arm 2 (the fleet-wide valves, same shape as `ORPHAN_WATCHDOG=0`).
 *
 * ⛔ THE EXIT CODE MUST NOT CHANGE. Node suppresses a signal's default action as
 * soon as any listener is registered, so a naive `process.on("SIGTERM", …)`
 * turns a killable child into one that ignores SIGTERM — an inert enforcer
 * pointed the other way. This module therefore re-raises after its work, but
 * ONLY when it is the sole listener for that signal: if anything else (pi's own
 * graceful-shutdown path, which is what writes `session_end`) is registered, the
 * lifecycle is that handler's to end and this one stays out of the way. Both
 * directions are pinned by the suite (exit 143 on the sole-listener path).
 *
 * ⛔ THE HANDLER DELAYS THE EXIT, SO IT IS BOUNDED, AND THE BOUND LIVES IN
 * `fire()`. This module arms at module load, so it is the FIRST `SIGTERM`
 * listener and its synchronous work runs BEFORE every later one — including pi's
 * graceful shutdown. Every millisecond it spends is a millisecond pi's shutdown
 * does not have, out of the parent's fixed 5 s, and that is why the window is
 * HALF that budget rather than "as much as we can get away with". Measured on
 * this box (2026-10-27, a tree the shape of #2932 — 3 modified + 13 untracked):
 * `SIGTERM` → exit took **1 153 ms** armed (median of 5; 757 ms of it the
 * checkpoint, the rest three `ps` probes) against **4 ms** disarmed. A 700-file
 * dirty tree measured 1.2–2.7 s. Past the snapshot budget the arm records
 * `failed/git-timeout` — honest, and it keeps the exit short.
 *
 * Best-effort by construction: every failure (no fs, no git, a budget overrun,
 * an in-progress merge) is recorded as a `skipped`/`failed` reason in the same
 * JSON line, never swallowed silently and never allowed to throw into the
 * signal path.
 */

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { spawnSync } from "node:child_process";
import { redactCommand } from "./shared/redact-command.js";

// ── constants ───────────────────────────────────────────────────────────────

export const DEFAULT_SIGNAL_LOG = path.join(os.homedir(), ".pi", "agent", "lane-signals.jsonl");
export const CHECKPOINT_REF_PREFIX = "refs/lane-checkpoints/";
export const SIGNAL_LOG_MAX_BYTES = 8 * 1024 * 1024;
export const ARGV_MAX_CHARS = 400;
export const GIT_CMD_TIMEOUT_MS = 1_500;
/** ⛔ THE WHOLE HANDLER IS BOUNDED BY THE PARENT'S ESCALATION, not just the
 * snapshot: the task harness's exit watchdogs run `SIGTERM` → `setTimeout(…,
 * 5_000)` → `SIGKILL` (extensions/builtin-tools `armExitWatchdog` /
 * `armCompletionWatchdog`), so ANY handler work still running at 5 s is killed,
 * and the record is the work that would be lost with it.
 *
 * Two mistakes are recorded here, both found in review. (1) Budgeting only the
 * snapshot: the handler also spends up to 2 × `PS_TIMEOUT_MS` probing the parent
 * and one more on its own pgid, which with a 3 s snapshot is ~7.5 s, so under the
 * load that produced this incident the slow path lost arm 1 entirely. `fire()`
 * derives every step's budget from ONE deadline, so the sum cannot exceed this
 * window. (2) Setting the window NEAR the parent's bound (it was 4 500 ms): the
 * handler runs BEFORE pi's own shutdown listener, so a 4.5 s handler left pi
 * 0.5 s of the parent's 5 s — the trap would have guaranteed that the SIGKILL
 * landed mid-shutdown on every killed child, truncating the `session_shutdown`
 * path that files the capture. HALF the budget leaves pi ≥ 2.5 s, and the
 * measurement in the header says the incident's own shape needs ~1.2 s.
 */
export const SIGNAL_WINDOW_MS = 2_500;
/** Reserved inside the window for the append itself, which is never optional. */
export const APPEND_RESERVE_MS = 100;
/** Per-`ps` timeout. Two are used for the parent and one for the pgid, so the
 * probes can spend at most 3 × this — kept below the window on purpose, because
 * a probe that could eat the whole budget would leave no snapshot at all.
 * Measured: one `ps -o args=` costs ~105 ms on this box. */
export const PS_TIMEOUT_MS = 500;
/** Total time the snapshot may spend, and also the per-step ceiling: no single
 * `git` call may outlast the whole snapshot budget, so one wedged `git add`
 * cannot consume the window and take the record with it. A worktree too large to
 * snapshot in this time records `failed/git-timeout` instead, which is honest.
 * Measured (`read-tree` + `add -A` + `write-tree` + `commit-tree` + `update-ref`
 * on this box): 0.6–0.9 s for the incident's 16-file shape, 1.2–2.7 s for 700
 * files, past 2 s at ~2 000+. */
export const CHECKPOINT_BUDGET_MS = 1_500;

export const HANDLED_SIGNALS = ["SIGTERM", "SIGINT", "SIGHUP"] as const;
export type HandledSignal = (typeof HANDLED_SIGNALS)[number];

/** POSIX exit status for a process that died from each signal (128 + n). */
const SIGNAL_EXIT_CODE: Record<HandledSignal, number> = { SIGHUP: 129, SIGINT: 130, SIGTERM: 143 };

// ── gates ───────────────────────────────────────────────────────────────────

/** Arm 1 gate: a dispatch child, unless the valve is set. */
export function signalForensicsActive(env: Record<string, string | undefined> = process.env): boolean {
  return env.TASK_HEARTBEAT === "1" && env.PI_MODE === "print" && env.TASK_SIGNAL_FORENSICS !== "0";
}

/** Arm 2 gate: arm 1's population, unless the checkpoint valve is set. */
export function checkpointActive(env: Record<string, string | undefined> = process.env): boolean {
  return signalForensicsActive(env) && env.TASK_LANE_CHECKPOINT !== "0";
}

// ── arm 1: the record ───────────────────────────────────────────────────────

/** What is knowable about the PARENT of this process at signal time.
 *
 * ⛔ NOT the sender. Renamed from `SenderFacts` in the #2934 review because the
 * name asserted the one thing the probe cannot measure: `$PPID` names the process
 * that FORKED this one, and any other process can signal this one without
 * appearing anywhere in these fields. See `SENDER_NOTE`.
 */
export interface PpidAtSignal {
  /** `$PPID` at signal time. */
  pid: number;
  /** `ps -o args= -p <ppid>` at signal time — "" when the parent is already gone. */
  argv: string;
  /** `ps -o comm= -p <ppid>` — the executable name, which survives a NULL argv. */
  comm: string;
  /** Whether the parent pid still names a live process (kill(ppid, 0)). */
  alive: boolean;
}

/** ⛔ STORED IN EVERY RECORD, not only in the doc. The limitation is the part a
 * reader will get wrong, and this fleet's own lesson is that a caveat living in a
 * document away from the artifact is invisible at the point the artifact is read.
 * One sentence, next to the field it qualifies. */
export const SENDER_NOTE =
  "ppid_at_signal is the PARENT at signal time, not the sender: a signal carries no sender identity " +
  "through Node's API, so this record names the sender only when the parent was the sender — and " +
  "otherwise shows only that the parent was alive with that argv, which cannot exclude any other process.";

export interface LaneSignalRecord {
  event: "lane-signalled";
  signal: HandledSignal;
  /** The victim. */
  pid: number;
  /** ⛔ The PARENT. Not the sender — see `sender` / `sender_note`. */
  ppid_at_signal: PpidAtSignal;
  /** Always `"unrecorded"` today, and always PRESENT: a reader that greps this
   * field never has to infer attribution from the absence of one. A platform that
   * can supply a real sender changes this field's type, not the record's shape. */
  sender: "unrecorded";
  sender_note: string;
  pgid: number | null;
  cwd: string;
  checkpoint: CheckpointResult;
  ts: string;
}

/** Clamp a `ps` command line so one row cannot dominate the log. */
export function clampArgv(raw: string): string {
  const one = raw.replace(/[\r\n]+/g, " ").trim();
  if (one.length <= ARGV_MAX_CHARS) return one;
  return `${one.slice(0, ARGV_MAX_CHARS - 1)}…`;
}

/** Pure record builder — the suite asserts this shape without a process. */
export function buildSignalRecord(input: {
  signal: HandledSignal;
  pid: number;
  facts: PpidAtSignal;
  pgid?: number | null;
  cwd: string;
  checkpoint: CheckpointResult;
  now: number;
}): LaneSignalRecord {
  return {
    event: "lane-signalled",
    signal: input.signal,
    pid: input.pid,
    ppid_at_signal: {
      pid: input.facts.pid,
      // Redaction at the point the value ENTERS the record, never at the sink: this
      // is a shell command line, the exact shape the shared seam exists for
      // (inline `GH_TOKEN=…` / `ghp_…`), and the log outlives the process that
      // wrote it. `redactCommand` is imported rather than re-implemented so the two
      // other command-recording sinks (verification-gate, review-enforcer) and this
      // one cannot drift (#966, #1492).
      argv: redactCommand(clampArgv(input.facts.argv)),
      comm: input.facts.comm.trim(),
      alive: input.facts.alive,
    },
    sender: "unrecorded",
    sender_note: SENDER_NOTE,
    pgid: input.pgid ?? null,
    cwd: input.cwd,
    checkpoint: input.checkpoint,
    ts: new Date(input.now).toISOString(),
  };
}

/** Append one line, bounded: past the ceiling the log is rotated once (not
 * silently dropped, and never by an unbounded rewrite from a dying process). */
export function appendSignalRecord(logPath: string, record: LaneSignalRecord): void {
  const line = `${JSON.stringify(record)}\n`;
  try {
    fs.mkdirSync(path.dirname(logPath), { recursive: true, mode: 0o700 });
  } catch {
    /* the append below is the operation that matters */
  }
  try {
    const st = fs.statSync(logPath);
    if (st.size > SIGNAL_LOG_MAX_BYTES) fs.renameSync(logPath, `${logPath}.1`);
  } catch {
    /* absent or unreadable: the append creates it */
  }
  fs.appendFileSync(logPath, line, { encoding: "utf8", mode: 0o600 });
}

// ── arm 2: the checkpoint ───────────────────────────────────────────────────

export interface CheckpointResult {
  status: "saved" | "skipped" | "failed";
  /** Machine-readable why — always present, including on success. */
  reason: string;
  ref?: string;
  commit?: string;
  files?: number;
  elapsedMs?: number;
}

/** One bounded git invocation. Injectable so the suite can drive it without a
 * repo, and so a mutant that removes a step reddens a named assertion. */
export type GitRunner = (
  args: string[],
  extraEnv: Record<string, string>,
  timeoutMs: number,
  cwd: string,
) => { ok: boolean; out: string; timedOut: boolean };

export const defaultGitRunner: GitRunner = (args, extraEnv, timeoutMs, cwd) => {
  const res = spawnSync("git", args, {
    cwd,
    encoding: "utf8",
    timeout: timeoutMs,
    killSignal: "SIGKILL",
    env: { ...process.env, ...extraEnv },
    stdio: ["ignore", "pipe", "pipe"],
  });
  const out = `${res.stdout ?? ""}${res.stderr ?? ""}`.trim();
  const timedOut = res.error != null && (res.error as NodeJS.ErrnoException & { code?: string }).code === "ETIMEDOUT";
  return { ok: res.status === 0, out, timedOut };
};

/** Worktree-level git state that makes a HEAD-based snapshot unsafe: a repository
 * operation in flight. A snapshot built from `HEAD` would silently drop the
 * staged half of a conflicted merge, and presenting that as "your work is saved"
 * is worse than saying it was not.
 *
 * ⛔ `index.lock` is DELIBERATELY NOT a member (#2934 review P1). It was one, and
 * that made this arm self-disabling in the exact state it exists for: the
 * snapshot never reads or writes the lane's real index — every step runs with
 * `GIT_INDEX_FILE` pointed at a temporary file — so a held index lock cannot make
 * the snapshot unsafe. Worse, a killed `git` leaves `.git/index.lock` behind, and
 * a mass kill leaves one in every affected worktree, after which every later
 * death recorded `skipped/git-op-in-progress:index.lock` and pinned no ref.
 * Measured: with a stale lock and no git process alive, `checkpointWorktree`
 * returned `skipped` and saved nothing; with the marker removed it returns
 * `saved`. The MERGE_HEAD/rebase markers stay, because those DO make a
 * HEAD-based snapshot incomplete. */
const IN_PROGRESS_MARKERS = [
  "MERGE_HEAD",
  "CHERRY_PICK_HEAD",
  "REVERT_HEAD",
  "rebase-merge",
  "rebase-apply",
];

export function gitOpInProgress(gitDir: string): string | null {
  for (const marker of IN_PROGRESS_MARKERS) {
    try {
      if (fs.existsSync(path.join(gitDir, marker))) return marker;
    } catch {
      return "unreadable";
    }
  }
  return null;
}

/** `refs/lane-checkpoints/<yyyymmddThhmmssZ>-<pid>` — valid as a ref (no `:`,
 * no spaces), and sortable so the newest checkpoint of a worktree is last. */
export function checkpointRefName(now: number, pid: number): string {
  const iso = new Date(now).toISOString().replace(/[:.]/g, "");
  return `${CHECKPOINT_REF_PREFIX}${iso}-${pid}`;
}

/**
 * Capture the worktree's uncommitted state as a snapshot commit pinned by
 * `${CHECKPOINT_REF_PREFIX}…`. Never throws: the caller is inside a signal
 * handler.
 */
export function checkpointWorktree(opts: {
  cwd: string;
  now: number;
  pid?: number;
  env?: Record<string, string | undefined>;
  run?: GitRunner;
  budgetMs?: number;
  gitCmdTimeoutMs?: number;
}): CheckpointResult {
  const startedAt = Date.now();
  const run = opts.run ?? defaultGitRunner;
  const budgetMs = opts.budgetMs ?? CHECKPOINT_BUDGET_MS;
  const cmdTimeout = opts.gitCmdTimeoutMs ?? GIT_CMD_TIMEOUT_MS;
  const pid = opts.pid ?? process.pid;
  const elapsed = () => Date.now() - startedAt;
  const remaining = () => budgetMs - elapsed();

  const done = (r: CheckpointResult): CheckpointResult => ({ ...r, elapsedMs: elapsed() });

  const step = (args: string[], extraEnv: Record<string, string> = {}) => {
    const left = remaining();
    if (left <= 0) return { ok: false, out: "", timedOut: true };
    const res = run(args, extraEnv, Math.min(cmdTimeout, left), opts.cwd);
    return res;
  };

  try {
    const gitDirRes = step(["rev-parse", "--absolute-git-dir"]);
    if (!gitDirRes.ok) {
      return done({ status: "skipped", reason: gitDirRes.timedOut ? "git-timeout" : "not-a-repo" });
    }
    const gitDir = gitDirRes.out.split("\n")[0].trim();
    if (!gitDir) return done({ status: "skipped", reason: "not-a-repo" });

    const busy = gitOpInProgress(gitDir);
    if (busy) return done({ status: "skipped", reason: `git-op-in-progress:${busy}` });

    const headRes = step(["rev-parse", "--verify", "--quiet", "HEAD"]);
    if (!headRes.ok) {
      return done(
        headRes.timedOut ? { status: "failed", reason: "git-timeout" } : { status: "skipped", reason: "no-head" },
      );
    }
    const head = headRes.out.split("\n")[0].trim();
    if (!head) return done({ status: "skipped", reason: "no-head" });

    const headTreeRes = step(["rev-parse", `${head}^{tree}`]);
    if (!headTreeRes.ok) {
      return done(
        headTreeRes.timedOut
          ? { status: "failed", reason: "git-timeout" }
          : { status: "skipped", reason: "no-head-tree" },
      );
    }
    const headTree = headTreeRes.out.split("\n")[0].trim();

    const tmpIndex = path.join(os.tmpdir(), `pi-lane-ckpt-${pid}-${opts.now}.index`);
    const indexEnv = { GIT_INDEX_FILE: tmpIndex };
    try {
      const readTree = step(["read-tree", head], indexEnv);
      if (!readTree.ok) return done({ status: "failed", reason: "read-tree-failed" });

      // `add -A` from the worktree root: untracked files are most of what a
      // killed lane leaves behind, and a snapshot without them would be a
      // false "saved" claim (the failure mode this whole file exists to end).
      const add = step(["add", "-A"], indexEnv);
      if (!add.ok) return done({ status: "failed", reason: add.timedOut ? "git-timeout" : "add-failed" });

      const writeTree = step(["write-tree"], indexEnv);
      if (!writeTree.ok) return done({ status: "failed", reason: "write-tree-failed" });
      const tree = writeTree.out.split("\n")[0].trim();
      if (!tree) return done({ status: "failed", reason: "empty-tree" });

      if (tree === headTree) return done({ status: "skipped", reason: "clean" });

      const changed = step(["diff-tree", "--name-only", "-r", headTree, tree]);
      const files = changed.ok ? changed.out.split("\n").filter((l) => l.trim() !== "").length : undefined;

      const identity = {
        GIT_AUTHOR_NAME: "pi-lane-checkpoint",
        GIT_AUTHOR_EMAIL: "lane-checkpoint@invalid",
        GIT_COMMITTER_NAME: "pi-lane-checkpoint",
        GIT_COMMITTER_EMAIL: "lane-checkpoint@invalid",
      };
      const message = `lane checkpoint: work captured at SIGTERM before the process exited\n\nRecover: git diff HEAD ${CHECKPOINT_REF_PREFIX}…  (or git cherry-pick it)\n`;
      const commitRes = step(["commit-tree", tree, "-p", head, "-m", message], identity);
      if (!commitRes.ok) return done({ status: "failed", reason: "commit-tree-failed" });
      const commit = commitRes.out.split("\n")[0].trim();
      if (!commit) return done({ status: "failed", reason: "empty-commit" });

      const ref = checkpointRefName(opts.now, pid);
      const updateRef = step(["update-ref", ref, commit]);
      if (!updateRef.ok) return done({ status: "failed", reason: "update-ref-failed", commit });

      return done({ status: "saved", reason: "uncommitted-work", ref, commit, files });
    } finally {
      try {
        fs.unlinkSync(tmpIndex);
      } catch {
        /* never created, or already gone */
      }
    }
  } catch (err) {
    return done({ status: "failed", reason: `exception:${(err as Error)?.message?.slice(0, 80) ?? "unknown"}` });
  }
}

// ── the signal path ─────────────────────────────────────────────────────────

export interface SignalForensicsOptions {
  env?: Record<string, string | undefined>;
  logPath?: string;
  now?: () => number;
  run?: GitRunner;
  /** Injected by the suite; the real install uses `process` and `ps`. */
  pid?: number;
  ppid?: number;
  cwd?: string;
  ppidProbe?: (ppid: number) => PpidAtSignal;
  checkpoint?: (cwd: string, now: number, pid: number) => CheckpointResult;
  appendRecord?: (logPath: string, record: LaneSignalRecord) => void;
  stderr?: (line: string) => void;
  /** Called instead of the re-raise; lets a unit test assert the decision. */
  raiseSignal?: (pid: number, signal: HandledSignal) => void;
  /** Called instead of the fallback exit. */
  exitProcess?: (code: number) => void;
}

/** Read the parent's argv/comm. `ps` is bounded and the failure modes are
 * distinct: a gone parent is a FACT (`alive: false`) and an empty argv is not the
 * same thing as a dead parent.
 *
 * ⛔ NAMED FOR WHAT IT MEASURES. This was `probeSender`, which read as
 * attribution; it probes `$PPID`, and the returned value is only the sender when
 * the parent is the sender. */
export function probePpidAtSignal(ppid: number, timeoutMs: number = PS_TIMEOUT_MS): PpidAtSignal {
  let parentAlive = true;
  try {
    process.kill(ppid, 0);
  } catch (err) {
    parentAlive = (err as NodeJS.ErrnoException)?.code !== "ESRCH";
  }
  // A non-positive budget means the window is already spent: return the facts we
  // hold (ppid + liveness) rather than blocking on a `ps` that would push the
  // append past the parent's SIGKILL.
  if (timeoutMs <= 0) return { pid: ppid, argv: "", comm: "", alive: parentAlive };
  const one = (args: string[]): string => {
    const res = spawnSync("ps", args, {
      encoding: "utf8",
      timeout: timeoutMs,
      killSignal: "SIGKILL",
      stdio: ["ignore", "pipe", "pipe"],
    });
    return res.status === 0 ? `${res.stdout ?? ""}`.trim() : "";
  };
  return {
    pid: ppid,
    argv: one(["-o", "args=", "-p", String(ppid)]),
    comm: one(["-o", "comm=", "-p", String(ppid)]),
    alive: parentAlive,
  };
}

/** `pgid` of this process — `ps` rather than `getpgid(2)` because Node exposes
 * no portable binding (`process.pid` is the pgid only when the child was
 * spawned detached, which is the case the harness guarantees but not the one we
 * should assume while recording evidence). */
function ownPgid(pid: number, timeoutMs: number = PS_TIMEOUT_MS): number | null {
  if (timeoutMs <= 0) return null;
  try {
    const res = spawnSync("ps", ["-o", "pgid=", "-p", String(pid)], {
      encoding: "utf8",
      timeout: timeoutMs,
      killSignal: "SIGKILL",
      stdio: ["ignore", "pipe", "pipe"],
    });
    if (res.status !== 0) return null;
    const n = Number(`${res.stdout ?? ""}`.trim());
    return Number.isInteger(n) && n > 0 ? n : null;
  } catch {
    return null;
  }
}

let armed = false;

/** Test-only reset (NODE_ENV=test gated, the repo's #212 convention). */
export function _resetArmedForTests(): void {
  if (process.env.NODE_ENV === "test") armed = false;
}

/**
 * Arm the signal handlers. Module-load scope (the extension factory calls it),
 * because a child that is killed before its first turn still has to record.
 */
export function installSignalForensics(opts: SignalForensicsOptions = {}): boolean {
  const env = opts.env ?? process.env;
  if (!signalForensicsActive(env)) return false;
  if (armed) return false;
  armed = true;

  const logPath = opts.logPath ?? env.LANE_SIGNAL_LOG ?? DEFAULT_SIGNAL_LOG;
  const doCheckpoint = checkpointActive(env);
  const now = opts.now ?? (() => Date.now());
  const append = opts.appendRecord ?? appendSignalRecord;
  const stderr = opts.stderr ?? ((line: string) => {
    try {
      console.error(line);
    } catch {
      /* EPIPE to a dead parent is expected here */
    }
  });
  const exitProcess = opts.exitProcess ?? ((code: number) => process.exit(code));
  const raiseSignal =
    opts.raiseSignal ??
    ((targetPid: number, signal: HandledSignal): void => {
      process.kill(targetPid, signal);
    });

  let latched = false;

  const fire = (signal: HandledSignal, listeners: Array<[HandledSignal, () => void]>): void => {
    if (latched) return;
    latched = true;

    // ⛔ ONE deadline for the whole handler. Every step below takes its budget
    // from what is LEFT of the window, so the sum of the probes, the snapshot and
    // the append can never exceed it. Without this the probes plus a full
    // snapshot overran the parent's SIGKILL by ~2.5 s (#2934 review), and the
    // append — arm 1's entire output — is last, so that is what got lost.
    const windowStart = now();
    const remainingWindow = (): number => SIGNAL_WINDOW_MS - (now() - windowStart) - APPEND_RESERVE_MS;

    const pid = opts.pid ?? process.pid;
    const ppid = opts.ppid ?? process.ppid;
    const cwd = opts.cwd ?? process.cwd();

    let facts: PpidAtSignal;
    try {
      facts = (opts.ppidProbe ??
        ((parent: number) => probePpidAtSignal(parent, Math.min(PS_TIMEOUT_MS, remainingWindow()))))(ppid);
    } catch {
      facts = { pid: ppid, argv: "", comm: "", alive: false };
    }

    // Own pgid is read BEFORE the snapshot, so a slow snapshot cannot starve it
    // and it cannot starve the append.
    const pgid = ownPgid(pid, Math.min(PS_TIMEOUT_MS, remainingWindow()));

    const snapshot = (): CheckpointResult => {
      if (opts.checkpoint) return opts.checkpoint(cwd, now(), pid);
      const budgetMs = Math.min(CHECKPOINT_BUDGET_MS, remainingWindow());
      if (budgetMs <= 0) return { status: "skipped", reason: "window-exhausted", elapsedMs: 0 };
      return checkpointWorktree({
        cwd,
        now: now(),
        pid,
        env,
        run: opts.run,
        budgetMs,
        gitCmdTimeoutMs: Math.max(1, Math.min(GIT_CMD_TIMEOUT_MS, budgetMs)),
      });
    };

    let checkpoint: CheckpointResult;
    try {
      checkpoint = doCheckpoint ? snapshot() : { status: "skipped", reason: "valve:TASK_LANE_CHECKPOINT=0" };
    } catch (err) {
      checkpoint = { status: "failed", reason: `exception:${(err as Error)?.message?.slice(0, 80) ?? "unknown"}` };
    }

    // ⛔ LAST step, and the only one with a reserved budget: if the window was
    // exhausted above, the record is still written, saying so.
    const record = buildSignalRecord({ signal, pid, facts, pgid, cwd, checkpoint, now: now() });
    try {
      append(logPath, record);
    } catch {
      /* a log we cannot write must not stop the exit */
    }
    // ⛔ THE OPERATOR-FACING LINE CARRIES THE SAME LIMITATION AS THE RECORD. It
    // used to read `sender=<comm>`, which is the single most misleading token this
    // instrument could print: it appeared in a terminal, next to an incident, and
    // named a process that may have had nothing to do with the kill. `sender=` is
    // now the literal `unrecorded` and the parent is named by its own field.
    stderr(
      `[lane-signal] ${signal} pid=${record.pid} ppid_at_signal=${record.ppid_at_signal.pid}` +
        ` comm=${record.ppid_at_signal.comm || "?"} sender=${record.sender}` +
        ` checkpoint=${record.checkpoint.status}/${record.checkpoint.reason}` +
        `${record.checkpoint.ref ? ` ref=${record.checkpoint.ref}` : ""} log=${logPath}`,
    );

    // ⛔ See the header: never convert a killable child into an unkillable one.
    // Another listener means pi owns the lifecycle (its graceful shutdown is what
    // writes `session_end` and files the capture) — leave the process to it.
    const others = process.listenerCount(signal) - 1;
    for (const [sig, handler] of listeners) process.removeListener(sig, handler);
    if (others > 0) return;
    try {
      raiseSignal(pid, signal);
    } catch {
      exitProcess(SIGNAL_EXIT_CODE[signal]);
    }
    // The re-raise kills us immediately; if a blocked/ignored signal lets it
    // through, exit with the SAME status the harness would have recorded.
    setTimeout(() => exitProcess(SIGNAL_EXIT_CODE[signal]), 250);
  };

  const installed: Array<[HandledSignal, () => void]> = [];
  for (const signal of HANDLED_SIGNALS) {
    const handler = (): void => fire(signal, installed);
    try {
      process.on(signal, handler);
      installed.push([signal, handler]);
    } catch {
      /* a platform without this signal simply gets one fewer arm */
    }
  }
  return installed.length > 0;
}

export default function (pi: unknown): void {
  // `pi` is unused: the whole instrument is the process's signal surface, so it
  // must arm at module-load time rather than behind a lifecycle hook.
  void pi;
  try {
    installSignalForensics();
  } catch {
    /* an extension that throws here would break EVERY dispatch child */
  }
}
