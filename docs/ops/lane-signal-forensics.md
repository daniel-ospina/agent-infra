# Lane signal forensics — who killed the child, and did the work survive?

**Status:** evidence recorded + instrument shipped (`extensions/task-signal-forensics.ts`); the
2026-10-27 mass kill itself remains **unattributable from logs** (proof below), which is exactly why
the instrument exists.
**Issue:** agent-infra#2932.

## The question this file answers

When a `task`-dispatched child dies by signal, nothing on this box records *who sent it*. The run
record carries `exit_code: 143` and the child's log ends with a normal-looking `session_end`, so a
mass kill reads exactly like a fleet of independent non-zero exits. This file records what was ruled
out and why, and what the harness now records so the next one names its sender.

## 2026-10-27 15:35 — the measurement

`~/.pi/agent/task-runs/*.json` read in full (not the 5 runs the issue was filed with):

| runs | window | exit | reason field | wall span |
|---|---|---|---|---|
| **17** | 15:35:02.0 → 15:35:05.8 | 143 | `non-zero-exit` (17/17) | 15 m – 279 m |

Four repositories (agent-infra, tortoise, DMeer, premise-labs) and two `/tmp` fixtures. The issue's
five are a subset; twelve more died in the same 3 s.

### Why `reason` is the discriminator

Across all 711 run records on this box:

```
reason=non-zero-exit  47   (27 with exit 143, 20 with exit 1)   ← child died, harness decided nothing
reason=cut            21   ← harness killed it
reason=stream-stall    4   ← harness killed it
reason=hard-cap        2   ← harness killed it
reason=zero-output     1   ← harness killed it
```

Every harness kill path writes **its own reason** (`{...kill("silence-threshold")}` →
`doResolve(..., { reason })` → the record's `reason`). None of the 27 exit-143 records carries one.
`final_details` is `{model, provider, exitCode, sawTools}` — no `stopReason`, no
`killedAfterCompletion`. So the task harness's watchdogs did not kill these children: the child died
before any parent-side decision.

### Ruled out, from evidence

| Candidate | Why it cannot be it |
|---|---|
| **jetsam / RunningBoard** | jetsam delivers SIGKILL (137). `log show 15:35:00–15:35:20` contains no jetsam record for any victim; the only `[com.apple.runningboard:jetsam]` lines are `memorystatus_control` argument errors while registering `siriactionsd` (pid 81813), a different process. |
| **`com.eldato.controller-watchdog`** (300 s → `watchdog-loop.sh`) | **INERT.** `launchctl list` shows exit status **126**; `/tmp/controller-watchdog.launchd.err` is that failure repeated (`…watchdog-loop.sh: Operation not permitted`), and it never reached `main()`. Its kill path only restarts the *controller* (`kill -TERM "$controller_pid"`, a single pid from `ctrl_stdout_path`); it has no lane population at all. |
| **`com.eldato.pi-reap-orphans`** (hourly) | candidate filter is literal `awk -F'\t' '$2 == 1'` (`ppid == 1`); the victims' parent was a live `pi`. It also ships `REAP_ORPHAN_DRY_RUN=1`. It could not see these pids in principle, not merely in this pass. |
| **`com.eldato.pi-session-reaper`** (hourly → `pi-reap-idle.sh`) | population is interactive REPL sessions keyed on a session JSONL (`session_file_for`, `jsonl_epoch_for`, progress on a tty); a `pi -p` child has no REPL record, so it fails `no-jsonl-proof` (fail-closed) before any gate that can signal. |
| **`com.eldato.swarm-watchdog`** (120 s) | never ran: `StandardOutPath /tmp/swarm-watchdog.log` does not exist. |
| **The task harness's settle sweep** | `sweepProcessGroup(childPgid, {detached, spawnedPid})` runs **after** a child exits (it reaps survivors in the child's own detached group), and it writes a `reason`. It cannot TERM a live child, and it never reached a parent group here (`TASK_DETACHED` default 1 → each victim had `pid == pgid`). |
| **The child-side orphan watchdog (#385)** | `~/.pi/agent/orphan-watchdog.log` mtime **01:48**, no entry in the window; it requires `ppid == 1` and exits **137**, not 143. |
| **An agent's shell** | `~/.pi/agent/audit/audit.jsonl` for 19:30–19:40Z contains no `pkill`/`killall`/`kill -…` tool call, and no tool call anywhere references any victim pid in a signalling context. |
| **A human's shell** | `~/.zsh_history` mtime **15:17** — no shell command at 15:35. |
| **A re-run of a stray `*.test.ts` through an extension reload** (`#2841`: the farm carries 10 test suites pi would EXECUTE) | Two independent refutations. (1) The word `reload` appears **0 times** in all five victim logs — no `ctx.reload()` happened, so nothing was re-imported at 15:35. (2) The farm's test files contain no signal primitives at all: `process.kill` / `SIGTERM` / `SIGKILL` appear **zero** times across all ten. |

### What the logs physically cannot answer

macOS logs signal *delivery* to nobody by default: `log show` restricted to the five pids over
15:34:45–15:35:40 yields only `com.apple.network:path` libinfo lines, the last at **15:35:02.004**.
There is no `kill(2)` audit trail, and `sudo log show --predicate 'process == "kernel"'` has no
`SIGTERM` event class. **Attribution from this box's logs is impossible, and that is a property of
the instrument, not of the incident.**

### The child's own log cannot answer it either

All 17 victims' logs end with

```
[task-heartbeat] session_end nonce=<n>
[tortoise-capture] capture FAILED for session … (HTTP 402 …)
```

`session_end` is emitted **once at `session_shutdown`** (`extensions/task-heartbeat.ts`), and a
*successful* run's log ends with the same two lines. So the marker says "the process went through
pi's shutdown hook", which is true of both a natural exit and a TERM the runtime handled before
dying by the signal. It is not an attribution signal, and the harness's `sessionEnded` latch reads
it as one.

### Timeline, for the next investigator

```
15:34:28  audit: session_start (a new pi session)
15:34:49  ~/.pi/agent/state/ORCHESTRATION-BOARD-….md modified
15:34:50  launchd starts ~/orchestrator/launchd-controller.sh (writes logs/launchd.err)
15:35:02  it creates the tmux session `orch-controller` (pid 88852)
15:35:02  ← 17 children begin dying (143); last settle 15:35:05.8
15:35:13  ~/orchestrator/.orch.lock written (controller takes the lock)
15:35:39  controller's first cycle line in logs/orch-loop.log (load=231, lanes=0)
```

The coincidence is recorded, **not** claimed as cause: the kill begins in the same second the
controller session is created, but nothing in `launchd-controller.sh` or `orch-loop.sh`'s startup
path enumerates `pi -p` children, and the controller's own reaper is worker-name-scoped
(`merge-*|lane-*|fix-*` from `wt_table`). What the timeline does establish is that **a 3 s kill of
every in-flight dispatch on the box overlapped a controller (re)start, and nothing on the box
recorded the sender.**

## The instrument

A child-side extension, armed in every dispatched `pi -p` child (`PI_MODE=print` +
`TASK_HEARTBEAT=1`, the established sub-agent identity pair). On `SIGTERM` / `SIGINT` / `SIGHUP` it
appends **one JSON line** recording the parent, then re-raises the signal so the exit code the harness
records is unchanged (still 143 / 130 / 129):

```json
{"event":"lane-signalled","signal":"SIGTERM","pid":7180,"ppid":7112,
 "parent_argv":"/bin/bash -c export PATH=\"…\" … git status --porcelain | head -3 …",
 "parent_comm":"/bin/bash","parent_alive":true,"pgid":7107,
 "cwd":"/Users/danielospina/Documents/GitHub/agent-infra/.worktrees/fix-2932",
 "checkpoint":{"status":"saved","reason":"uncommitted-work",
   "ref":"refs/lane-checkpoints/2026-10-27T211405712Z-7180",
   "commit":"1db689d847ec115ba36a84c346e1a46297960f44","files":6,"elapsedMs":672},
 "ts":"2026-10-27T21:14:06.404Z"}
```

That sample is a real capture, not a mock: the lane was this worktree (6 files — 3 modified, 3
new), it was TERMed 2 s after arming, and 672 ms later the work was pinned by a ref whose tree
contained every one of the 6 files while `git status` still reported all 6 as uncommitted. The
`parent_argv` is the whole point: it records the parent's command line at signal time, which no post-mortem
reconstruction could have produced.

⛔ **What this can and cannot answer, stated precisely** (the earlier wording here said "names the
sender", which overstates it). `$PPID` is the **parent**, and the parent is the sender only when the
parent is the sender. So a record answers one of two things:

- if the parent is the killer, `parent_argv` **names it**;
- if the parent is alive and innocent — which is this incident's own scenario, where every remaining
  candidate is external (jetsam, a parent-side sweep, something outside the inventory) — the record
  **proves the sender was not the parent** and names nobody. It records the parent's `ppid` and argv,
  so the next investigator can rule the parent in or out, but a row reading `"parent_argv":"pi"` is
  *not* an accusation against `pi`.

The record shape already carries the distinction (`parent_alive`, `parent_argv`); it is the prose
that was wrong, not the mechanism.

`parent_argv` is read with `ps -o args= -p $PPID` at signal time — the one fact no post-mortem can
reconstruct, because the parent may have exited by then or the pid may have been reused.

A second arm checkpoints uncommitted work before the process dies, so a killed lane's tree is
recoverable even when the lane never committed. It is a **snapshot commit pinned by a ref**, built
against a temporary index, so the branch, `HEAD`, the real index and the working tree are never
touched:

```
GIT_INDEX_FILE=<tmp> git read-tree HEAD
GIT_INDEX_FILE=<tmp> git add -A     (untracked files included)
GIT_INDEX_FILE=<tmp> git write-tree
git commit-tree <tree> -p HEAD -m "lane checkpoint: …"
git update-ref refs/lane-checkpoints/<iso>-<pid> <commit>
```

Recovery: `git log --oneline refs/lane-checkpoints/*`, `git diff HEAD <ref>`, `git cherry-pick <ref>`.
The record carries the outcome — `saved` / `skipped` (`clean`, `not-a-repo`, `no-head`,
`git-op-in-progress:<marker>`, `window-exhausted`) / `failed` (`git-timeout`, `read-tree-failed`, …)
— so a lane that could not be saved says so instead of reading as saved.

### Why the WHOLE handler is bounded at 4.5 s

The task harness's own watchdogs escalate `SIGTERM` → **5 s** → `SIGKILL`
(`armExitWatchdog` / `armCompletionWatchdog` in `extensions/builtin-tools`). A handler still running
at 5 s is SIGKILLed, and the **append is the last thing it does**, so the attribution line is what
would be lost.

Bounding only the snapshot is not enough, and that earlier mistake is worth recording: the handler
also spends up to 2 × 1.5 s probing the parent (`ps -o args=`, `ps -o comm=`) and a third 1.5 s on
its own pgid, so the worst case was **~7.5 s** — over the window, with arm 1's output last. Under
the load that produced this incident that slow path is the likely path.

So one deadline governs every step: `SIGNAL_WINDOW_MS` (4.5 s, leaving 0.5 s of margin before the
SIGKILL) minus `APPEND_RESERVE_MS` for the append. Each step takes its budget from what is left —
the probes are capped at `PS_TIMEOUT_MS` (1.5 s) or the remainder, the snapshot at
`CHECKPOINT_BUDGET_MS` (3 s) or the remainder, one git step at `GIT_CMD_TIMEOUT_MS` (2 s). If the
probes consume the window, the snapshot is **not attempted** and the record says
`skipped/window-exhausted` — the record is written regardless, which is the property being bought.
A worktree too large to snapshot in what remains records `failed/git-timeout`, equally honest.

### Why not "make the lane's first action a commit"

An empty checkpoint commit at minute 0 does not save anything: the 16 files that died were created
*after* the lane's first action, and only the signal knows what the lane had accumulated. The
snapshot has to be taken at the end.

## Verification — the TERM test and its two mutations

`extensions/task-signal-forensics.test.ts` (16 assertion groups, CI-wired) spawns a **real lane**: a
temporary `.mjs` bootstrap that imports the extension source, arms it, announces readiness and
idles in a deliberately dirty git repo (one modified tracked file, one untracked file). The suite
sends that process a real `SIGTERM` and asserts, in this order:

1. the process died by `SIGTERM` (or exit 143) — an instrument must not make a child unkillable;
2. **arm 1** — exactly one record, naming the victim `pid`, the real `ppid`, the parent's command
   line read at signal time, the cwd and an ISO timestamp;
3. **arm 2** — `checkpoint.status == saved`, the ref resolves to the recorded commit, the snapshot
   contains the modified file **and** the untracked file;
4. controls — `HEAD` did not move and `git status --porcelain` is byte-identical before/after, so
   "the work survived" cannot be satisfied by writing it into the branch or by stashing it away.

`tests/lane-signal-forensics/run.sh` (a bash shard, discovered by `scripts/run-bash-shards.sh`) runs
the suite **twice more against a mutated copy** — the tracked source is never modified; the mutant
is applied to a temp copy that the suite then imports and spawns:

| mutant | change | result |
|---|---|---|
| **A — trap removed** | `process.on(signal, handler)` → a no-op | RED: `12 passed, 4 failed`; the named failure is **`arm 1: the signal log has exactly one record`** |
| **B — checkpoint arm disabled** | `checkpoint = doCheckpoint ? snapshot() :` → `checkpoint = false ? snapshot() :` | RED: `14 passed, 2 failed`; the named failure is **`arm 2: the checkpoint was SAVED`**, and arm 1 stays green (the two arms are independently load-bearing) |

Baseline: `16 passed, 0 failed`. The driver also refuses (a) a mutation whose anchor does not match
exactly once, (b) a mutant that reddens everything (the suite crashed instead of asserting), and
(c) any run that leaves the tracked source modified.

## What this does NOT do, deliberately

- **It does not identify the 2026-10-27 sender.** Attribution needs a victim that survives long
  enough to write, and every one of the 17 died to a signal it did not record. The instrument is
  retroactive-free by construction: it can only answer the NEXT one.
- **It does not touch `lane.sh` / `fix-one.sh` / `merge-one.sh`.** They are a different population
  (tmux lanes that commit through their own wrapper) and this incident's victims were not among
  them. Nothing here replaces `lane-merge.sh`'s round cap or its own kill path.
- **It does not add a reaper, a watchdog, or a timer.** A mass kill has just been shown to be
  unattributable; adding another killer-shaped instrument before the recorder exists would make the
  next incident worse, not better.
- **It does not repoint the harness's `sessionEnded` latch.** That `session_end` is written on every
  shutdown is a real defect in the parent's completion signal (#191's latch reads a teardown as a
  completion), but changing a latch that the whole settle path depends on is a separate change with
  its own blast radius; it is recorded here so the next lane inherits the finding.
