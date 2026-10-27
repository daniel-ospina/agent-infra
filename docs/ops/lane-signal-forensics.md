# Lane signal forensics — who killed the child, and did the work survive?

**Status:** instrument shipped; the 2026-10-27 mass kill is **unattributable from logs** (proof below).
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

Three repositories (agent-infra, tortoise, DMeer, premise-labs) and two `/tmp` fixtures. The issue's
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

`extensions/task-signal-forensics.ts` — child-side, armed in every dispatched `pi -p` child
(`PI_MODE=print` + `TASK_HEARTBEAT=1`, the established sub-agent identity pair). On `SIGTERM` /
`SIGINT` / `SIGHUP` it appends **one JSON line** naming the sender:

```json
{"event":"lane-signalled","signal":"SIGTERM","pid":63127,"ppid":1920,
 "parent_argv":"pi","parent_comm":"pi","parent_alive":true,
 "cwd":"/…/.worktrees/w-drainer-fix","pgid":63127,"ts":"2026-10-27T19:35:02.914Z"}
```

`parent_argv` is read with `ps -o args= -p $PPID` at signal time — the one fact no post-mortem can
reconstruct, because the parent may have exited or the pid may have been reused.

See `docs/ops/lane-signal-forensics.md` §verify-run for the TERM test and its mutations.
