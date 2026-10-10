---
title: "Detached lane dispatch — running long sub-agent lanes out of band"
type: engineering
domain: operations
doc_status: live
created: 2026-10-10
aboutSubjects: organisation-design-team
aboutObjects: agent-infra
---

# Detached lane dispatch

`scripts/detached-lane-dispatch.sh`

A watchdog-free way to run long, full-workflow sub-agent lanes without wedging the
parent session. Use it when a lane is expected to run for more than ~10 minutes and
the builtin `task` tool is killing it.

## The problem it solves

The builtin `task` tool spawns:

```
pi -p --provider <p> --model <m> --no-session <prompt>
```

with two watchdogs (`extensions/builtin-tools/index.ts`):

| constant | value | effect |
|---|---|---|
| `FIRST_OUTPUT_TIMEOUT_MS` | 60 s | zero output → SIGTERM, retry |
| `HEARTBEAT_TIMEOUT_MS` | **660 s** | **no stdout/stderr for 11 min → SIGTERM + SIGKILL** |

`-p` (print mode) buffers its output until the final assistant message, so a healthy
lane doing a long test run or a large read emits **nothing** for the whole window and
is indistinguishable from a hung one.

**Measured 2026-10-09:** a batch of 6 full-workflow lanes (worktree → install → scope
→ implement → test → commit → push → PR) was dispatched in parallel; **5 of 6 were
killed at exactly 660 s**, leaving worktrees with uncommitted edits and no report. Re-run
as detached processes, all 5 completed.

Note `extensions/subagent/index.ts` spawns with `--mode json -p`, which streams
events and never trips a silence watchdog. Fixing `task` to do the same is the
cheapest systemic fix (tracked in agent-infra#1648); this script is the workaround
until then.

## How it works

1. **Dispatch** — `nohup env <gate env> pi -p … > <run-dir>/<issue>.log 2>&1 &`
   Detached, no watchdog, parent returns immediately. Launches are **staggered**
   (`DETACHED_STAGGER`, default 45 s) because N concurrent dependency installs on one
   box is an IO storm, and capped (`--max-concurrent`).
2. **Status** — reports each lane `ALIVE (working)` / `ALIVE (HUNG?)` / `DONE` from
   `ps -o %cpu=,etime=`.
3. **Reap** — kills lanes that are `0.0 % CPU` and sleeping past `--max-age-min`.
   This is the failure mode this pattern *introduces*: pi sometimes never exits after
   its work is done (observed twice — process in state `S` at 0 % CPU long after its
   PR was open). Always run `reap` on a timer.
4. **Watch** — polls for each lane's PR and hands it to a fresh-context reviewer, then
   fixer, then re-review. **This is the review gate** (see below).

## ⛔ The three rules

The children are launched with:

```
AGENT_SKIP_REVIEW_GATE=1  ELDATO_SKIP_VGATE=1
AGENT_ALLOW_MAIN_EDITS=1  ELDATO_ALLOW_MAIN_EDITS=1
```

This is **required** — a lane has no `task` tool, so it can never satisfy the
verification or review gates itself, and leaving them on deadlocks the lane. It is also
**dangerous**:

1. **The parent must run the review gate.** The child cannot. If you do not run
   `watch` (or review the PRs yourself), unreviewed code ships.
2. **Every lane prompt must forbid editing the main checkout.** `AGENT_ALLOW_MAIN_EDITS=1`
   disables the main-checkout guard *in the child*, so "work only in your own worktree"
   is the only thing standing between a lane and the shared hub.
3. **This is not `cmux_dispatch.py`.** Use `cmux_dispatch.py` for lanes that must live in
   a cmux pane (it verifies the *artifact* — the message became a conversation message —
   not the send). Use this for headless lanes.

## What you give up vs `task`

| | `task` | detached |
|---|---|---|
| killed by silence watchdog | yes | no |
| blocks the parent | yes | no |
| structured result | yes | no — parse the log tail |
| gate enforcement | forced on | **you must re-impose it** |
| concurrency cap | 8 tasks / 4 concurrent | manual (`--max-concurrent`) |
| process cleanup | handled | **manual (`reap`)** |

For minutes-long lanes, `task` is still the better tool. Use detached only when a lane
genuinely needs to run long.

## Quick reference

```bash
scripts/detached-lane-dispatch.sh start  --issue 123 --issue 456 --repo /path/to/repo
scripts/detached-lane-dispatch.sh status --run-dir /tmp/pi-lanes/<stamp>
scripts/detached-lane-dispatch.sh reap   --run-dir /tmp/pi-lanes/<stamp> --max-age-min 180
scripts/detached-lane-dispatch.sh watch  --run-dir /tmp/pi-lanes/<stamp> --hours 5
```

`run-dir` holds `p-<issue>.txt` (the prompt actually used), `<issue>.log` (the lane's
output), and `launched.txt` (`issue pid`). Treat `/tmp` as volatile — copy anything you
need to keep.
