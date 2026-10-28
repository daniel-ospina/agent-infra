# Lane signal forensics — who killed the child, and did the work survive?

**Status:** evidence recorded + instrument shipped (`extensions/task-signal-forensics.ts`); the
2026-10-27 mass kill itself remains **unattributable from logs** (proof below), which is exactly why
the instrument exists — and, since the #2934 review, **the instrument does not claim attribution it
cannot produce**: it records `ppid_at_signal` and says out loud that the sender is unrecorded.
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

A child-side extension — see the coverage list below for **which** children. On `SIGTERM` / `SIGINT` /
`SIGHUP` it appends **one JSON line**, then re-raises the signal so the exit code the harness records
is unchanged (still 143 / 130 / 129):

```json
{"event":"lane-signalled","signal":"SIGTERM","pid":18072,
 "ppid_at_signal":{"pid":17400,"argv":"…/node --require …/tsx/dist/preflight.cjs … sample.mts",
                   "comm":"…/bin/node","alive":true},
 "sender":"unrecorded",
 "sender_note":"ppid_at_signal is the PARENT at signal time, not the sender: a signal carries no
   sender identity through Node's API, so this record names the sender only when the parent was the
   sender — and otherwise shows only that the parent was alive with that argv, which cannot exclude
   any other process.",
 "pgid":16431,
 "cwd":"/private/var/folders/…/T/sample-repo-Aa19xG",
 "checkpoint":{"status":"saved","reason":"uncommitted-work",
   "ref":"refs/lane-checkpoints/2026-10-28T021930196Z-18072",
   "commit":"ded572e55fb9a60a3cb666a031035055cd0df40a","files":6,"elapsedMs":915},
 "ts":"2026-10-28T02:19:31.113Z"}
```

That sample is a real capture, not a mock — the argv and the `sender_note` are the only lines elided
(shown with `…`/wrapped); the record is otherwise verbatim. The lane was a temp repo with 6 dirty
files (3 modified, 3 new), it was TERMed the moment it announced readiness, and 915 ms later the work
was pinned by a ref carrying all 6 while `git status` still reported all 6 as uncommitted.

### ⛔ What the record can and CANNOT tell you — the #2934 review's P1

**`ppid_at_signal` is the process that FORKED the victim, and that is not the sender.** Anything can
send `SIGTERM` to a child whose parent is the supervisor, and the record will then name the
supervisor. This is not a missing feature to be added later: Node's signal API surfaces only the
signal's number — libuv never exposes the kernel's `siginfo.si_pid` — so **a sender identity is not
obtainable portably in this runtime**, and a field designed to look like one would have made the next
investigation confidently wrong.

So the field is named for what was measured (`ppid_at_signal`, not `ppid`), and every record carries
`sender: "unrecorded"` plus a `sender_note` saying the same thing where the record is read. A row
answers one of exactly two questions:

- **the parent WAS the sender** → `ppid_at_signal` names it (`argv`, `comm`, `alive`);
- **the parent was not the sender** → the record proves the parent was *alive with that argv* at that
  moment, and **names nobody**. A row reading `"comm":"pi"` is **not** an accusation against `pi`, and
  an external killer (jetsam, a parent-side sweep, a sibling lane, a human shell) leaves no trace here
  at all.

The second case is measured, not assumed: the suite has a **third process** — neither the victim nor
its parent — deliver the `SIGTERM`, and asserts that the record names the parent and that the real
sender appears in no pid field (`P1: a THIRD process's SIGTERM is recorded as the PARENT`). That test
is the guard against the claim drifting back: a later change that starts implying attribution reddens
there.

**What the record is still worth.** It rules the parent IN or OUT, at signal time, with the parent's
command line — which no post-mortem can reconstruct, because the parent may have exited or the pid may
have been reused. For a mass kill that is the difference between "17 unattributable 143s" and "17
deaths whose parent was a live innocent `pi`, therefore the sender was external", which is a real
narrowing even though it names nobody.

### Coverage — which `pi -p` children this arms in, exactly

The earlier version of this file said "armed in every dispatched `pi -p` child". **That was false**
(#2934 review, P2.1). The gate is `TASK_HEARTBEAT=1` **and** `PI_MODE=print`, and only the two
in-process dispatchers set that pair, both unconditionally:

| population | armed? | why |
|---|---|---|
| `task`-tool children | **yes** | `subAgentEnv` in `extensions/builtin-tools/index.ts` forces the pair |
| `subagent`-tool children | **yes** | `childEnv` in `extensions/subagent/index.ts` forces the pair (`TASK_HEARTBEAT_DISABLE=1` silences the *emitter*, not the trap) |
| harness lanes — `lane.sh`, `fix-one.sh`, `merge-one.sh` | **no** | they run `pi -p --no-session` through `spawn-gate.sh`'s `run_agent`, which sets **neither** marker |
| fleet / interactive sessions | **no** | no `PI_MODE`, so the gate is false by construction |
| `cloud-cell-bringup.sh` | **no** | a 120 s provider reachability probe, not a dispatch |

#2932's victims were `task`-tool children — their `~/.pi/agent/task-runs/*.json` records are what
identified them — so **the population that lost the work is covered**. The harness lanes are **not**,
and this file must not be read as saying they are. Their capture hangs off `run_agent` in
`spawn-gate.sh`, which a `task` child does not have, and since #2834 its trigger is **every terminal
agent transition** — the cap (`cap_wip_snapshot`, a LOCAL patch + archive under `$O/wip/`) and the
ordinary end of the turn (`terminal_wip_rescue`, the shipped `scripts/bg-rescue-wip.sh`, which puts the
work on **origin** under `refs/wip/<slug>`). Two residuals stay true and are not claimed away:
  * a harness lane **killed by a signal below its cap** is still uncovered here — its wrapper never
    reaches the end of `run_agent`, which is exactly the window arms 1 and 2 exist for; and
  * `merge-one.sh` carries its own `run_agent` copy with no snapshot and no rescue at all (its agent is
    a reviewer, which lands a comment + a signed record, not uncommitted worktree work).

### Why this is not simply a call to `bg-rescue-wip.sh`

There are already two capture mechanisms in this repo, and neither can fire here. The #2934 review
(P2.2) is right that a second rescue is bureaucracy unless it is the *only* one that fits, so here is
the measurement rather than a preference:

| | trigger | guarantee | reachable inside the death window? |
|---|---|---|---|
| `scripts/bg-rescue-wip.sh` (#2045) | the **dispatcher**, *before* the TERM | reachable from `refs/wip/<slug>` on **origin** | **no** — its own bounds are `bounded 25 git fetch` + `bounded 45 git push`, and the parent escalates `SIGTERM` → **5 s** → `SIGKILL`. A 25 s + 45 s tool cannot finish, and the SIGKILL would take arm 1's record with it. It also refuses any path that is not the worktree **root**. |
| `cap_wip_snapshot` (`spawn-gate.sh`) | `run_agent`, **after** the cap kill landed | a patch + archive directory under `$O/state` | **no** — it runs after the kill, and it hangs off `run_agent`, which a `task` child does not have |
| `terminal_wip_rescue` → `scripts/bg-rescue-wip.sh` (`spawn-gate.sh`, #2834) | `run_agent`, on **any** terminal transition — the cap **and** an ordinary end of turn | a commit reachable from `refs/wip/<slug>` on **origin** | **no** — same window problem, and for the same reason: it runs after `wait`, so a wrapper killed by a signal never reaches it |
| arm 2 (here) | **inside the victim**, on the signal | the work is in this clone's **object database**, pinned by a ref | yes — 0.6–0.9 s for the incident's shape (bounded at 1.5 s) |

So this is a second mechanism because it is the only one that runs *in the dying process*, and it
makes a deliberately **weaker** guarantee than either of them — local objects, not the remote — because
that is the guarantee that fits in the window. The stated cost is real: a checkpoint in a worktree that
is then reaped with its clone is gone. The strong guarantee stays where it belongs, with the
dispatcher, before the kill.

The second arm — the one nothing above can replace — checkpoints uncommitted work before the
process dies, so a killed lane's tree is recoverable even when the lane never committed. It is a **snapshot commit pinned by a ref**, built
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

### The shutdown delay, measured, and the bound it is held to (P3)

The trap **delays the exit**, and that is a real cost: this module arms at module load, so it is the
first `SIGTERM` listener and its synchronous work runs *before* pi's own graceful shutdown. A trap
that stalls invites `kill -9`, which would lose the very work it protects.

Measured on this box (macOS, 2026-10-27, `npx tsx`, real spawned lane, real `SIGTERM`), tree = the
shape of #2932 (3 modified + 13 untracked files):

| | `SIGTERM` → exit |
|---|---|
| trap **disarmed** (`TASK_SIGNAL_FORENSICS=0`) | **4 ms** (median of 5) |
| trap armed | **1 153 ms** (median of 5; range 1 017–1 222 ms) |
| … of which the checkpoint | 757 ms (`checkpoint.elapsedMs`) |
| … of which three `ps` probes | ~0.1 s each (~105 ms per `ps -o` on this box) |

The snapshot alone, on progressively dirtier trees (median of 3, `read-tree` + `add -A` + `write-tree`
+ `commit-tree` + `update-ref`):

| dirty tree | snapshot | outcome |
|---|---|---|
| 16 files (the incident) | **0.63–0.85 s** | `saved` |
| 700 files | 2.0–2.7 s | `saved` at the old 3 s budget; **`git-timeout` at the current 1.5 s** |
| 2 000 modified + 5 000 untracked | >2.4 s | `failed/git-timeout` |
| 20 000 untracked (`node_modules`-scale) | >2.2 s | `failed/git-timeout` |

**The bound, and why it is where it is.** The parent's watchdogs escalate `SIGTERM` → **5 s** →
`SIGKILL` (`armExitWatchdog` / `armCompletionWatchdog` in `extensions/builtin-tools`). That 5 s is the
whole budget for *our handler plus pi's own shutdown*, and pi's shutdown is what files the capture. So:

- `SIGNAL_WINDOW_MS = 2 500` — the handler's ceiling, **half** the parent's budget, leaving pi ≥ 2.5 s.
  (An earlier version used 4 500 ms, which left pi 0.5 s and would have guaranteed the SIGKILL landed
  inside `session_shutdown` on every killed child — a defect introduced by *this* extension, found in
  the #2934 review.)
- one deadline governs every step, minus `APPEND_RESERVE_MS` (100 ms) for the record;
- probes ≤ 3 × `PS_TIMEOUT_MS` (500 ms each) — deliberately less than the window, so the probes cannot
  starve the snapshot of its turn;
- snapshot ≤ `CHECKPOINT_BUDGET_MS` (1 500 ms), and no single git step may exceed it
  (`GIT_CMD_TIMEOUT_MS` = 1 500 ms) — one wedged `git add` cannot consume the window.

If the probes consume the window, the snapshot is **not attempted** and the record says
`skipped/window-exhausted`; the record is written regardless, which is the property being bought. A
tree too large to snapshot in what remains records `failed/git-timeout`, equally honest. Both bounds
and the end-to-end delay are pinned by the suite (`P3: the handler budget…`, and the E2E's measured
`SIGTERM` → exit assertion), so the numbers cannot drift away from the constants.

### Why not "make the lane's first action a commit"

An empty checkpoint commit at minute 0 does not save anything: the 16 files that died were created
*after* the lane's first action, and only the signal knows what the lane had accumulated. The
snapshot has to be taken at the end.

## Verification — the TERM test and its two mutations

`extensions/task-signal-forensics.test.ts` (19 assertion groups, CI-wired) spawns a **real lane**: a
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
| **A — trap removed** | `process.on(signal, handler)` → a no-op | RED; the named failure is **`arm 1: the signal log has exactly one record`** |
| **B — checkpoint arm disabled** | `checkpoint = doCheckpoint ? snapshot() :` → `checkpoint = false ? snapshot() :` | RED; the named failure is **`arm 2: the checkpoint was SAVED`**, and arm 1 stays green (the two arms are independently load-bearing) |

Baseline: `19 passed, 0 failed`. The exact counts for A and B are printed by the driver on every run
rather than pinned here, because they move whenever an assertion group is added — the *named failing
assertion* is the contract, and it is checked by name. The driver also refuses (a) a mutation whose anchor does not match
exactly once, (b) a mutant that reddens everything (the suite crashed instead of asserting), and
(c) any run that leaves the tracked source modified.

## What this does NOT do, deliberately

- **It does not identify the 2026-10-27 sender, and it cannot identify the NEXT one either.** The
  record names the **parent**, and only when the parent happens to be the killer. A sender identity is
  not obtainable in this runtime (see the P1 section), so what the NEXT incident gets is a rule-out:
  the parent's pid, argv and liveness at signal time.
- **It does not arm in harness lanes** (`lane.sh` / `fix-one.sh` / `merge-one.sh`) — see the coverage
  table. They are a different population with a different capture, and the gap is stated there rather
  than left to be inferred.
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
