---
title: "The heartbeat's launch path — one versioned entry point, and a behaviour probe (#1867)"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-10-16
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-1867, heartbeat, launchd, cmux-socket, cloud-cell
---

# The heartbeat's launch path — one versioned entry point, and a behaviour probe (#1867)

**The launch path is part of the system, not an install detail.** This doc states it once, in the
repo, and names every place macOS and Linux legitimately differ.

## The defect this closes, in numbers

Measured 2026-10-16 on the Mac the fleet runs on:

```
launchd-spawned instance:   1,695 x "lane-status: DEGRADED"
                              210 x "lane-actions: REFUSING a DEGRADED snapshot"
                                0 x nudges delivered
snapshot:                    27/27 entries DEGRADED
```

The script documented its own cause in its header:

```
cmux send -> rc=1 :: Access denied - only processes started inside cmux can connect
```

`socketControlMode` is `cmuxOnly`. The cmux control socket gates on **launch-chain attribution**,
which macOS keeps for the process tree — **not on parentage**. A process that *started* inside a
cmux terminal keeps access after it is orphaned (`real_ppid=1`, verified 3/3), and so do its
children. A launchd job never had it.

So the launchd job ran, logged that error on every tick, and delivered nothing — **for its whole
life**. A heartbeat that fails this way is worse than no heartbeat, because **the log reads as
activity**. That is the false PASS this change exists to make impossible.

## The contract

| Verb | What it does | Exit |
|---|---|---|
| `heartbeat-launch.sh start` | start the detached loop, once | 0 started or already running · 1 refused |
| `heartbeat-launch.sh start --dry-run` | print the exact command, run nothing | 0 |
| `heartbeat-launch.sh stop` | write the loop's own kill file | 0 |
| `heartbeat-launch.sh status` | running? how stale is the last pass and the last fleet read? | 0 |
| `heartbeat-launch.sh check` | **behaviour probe** — see below | 0 OK · 1 DRIFT · 2 UNKNOWN |

⛔ **WHICH COPY THE OPERATOR RUNS.** `scripts/heartbeat-launch.sh` is **not** in
`pi-bootstrap/setup.sh`'s farm set, so the launcher you invoke is the **checkout-relative** one
(`bash <checkout>/scripts/heartbeat-launch.sh start`) — that is the versioned entry point, and it is
what this doc's table means everywhere else. The **loop** exists in two places: the same checkout
(`<checkout>/scripts/heartbeat-loop.sh`) and the farmed copy at
`$HOME/.pi/agent/scripts/heartbeat-loop.sh`. The launcher prefers the farmed loop when it is there,
so a box driven entirely from `$HOME/.pi/agent` has the loop and **not** the launcher; whatever
starts it must therefore name a checkout (`#1553` owns whether the loop should keep two homes).

`check` answers the question a content comparison cannot: **is the scheduled thing live *and fed*?**

- **0 OK** — the loop's pidfile names a process whose **own argv is the loop** (`pid_is_loop`:
  a bare "some process holds this number" check is not identity — the kernel reuses pids, so the
  number a reboot or a `SIGKILL` left in the pidfile can belong to a stranger) **and** the last
  published fleet read (`state/lane-status.last.json`) is fresh (default bound 900 s) and carries
  **zero** `degraded` rows.
- **1 DRIFT** — it is not running, has never published, is stale, published an **empty** row set,
  or its last read is DEGRADED. A **recycled** pid (alive, but not the loop) is DRIFT too: it says
  `recycled pid` rather than `OK loop alive`.
- **2 UNKNOWN** — the probe could not answer (no `python3`, no state dir, unreadable process
  table). **Never a pass.**

An empty snapshot is **not** a healthy fleet: `degraded` is a *per-row* flag, so on zero rows
`any(...)` is vacuously false — the same trap `lane-status.py`'s own publisher documents.

## The install honesty gate

`scripts/install-launchd.sh` **refuses, hard and non-zero,** any template whose `ProgramArguments`
name a script listed in `templates/launchd/LAUNCHD-INCOMPATIBLE` — and it names the documented
launch path instead of installing blindness. `--status` additionally reports an **installed plist
with no template** as `UNMANAGED` and exits non-zero: that was the blind heartbeat's exact shape, a
job on the box that the declared set no longer describes, so neither the status pass nor the content
drift check could see it.

Matching is by **repo-relative suffix**, not absolute prefix: the gate is a property of the script,
so `$HOME/.pi/agent/scripts/heartbeat-loop.sh` (the farmed copy a plist would actually name) and
`<worktree>/scripts/heartbeat-loop.sh` both refuse.

The declared set is resolved **recursively**: `templates/launchd/<subdir>/<label>.plist` is a
template too, so the four jobs this repo ships one directory down (`conflict-rebase`,
`harness-apply`, `disk-reaper`, `runner-autoscale` — each installed into `~/Library/LaunchAgents`
by its own installer) are its **own** jobs, not strays. Counting only the flat templates made
`--status` exit 1 and print the `bootout && rm -f` remedy for three owner-armed jobs on the
reference Mac. And `--status` exits **2 (UNKNOWN)** when `~/Library/LaunchAgents` exists but cannot
be enumerated: "I could not look" is a different answer from "nothing to report", and it is never
reported as clean.

Two label classes are **declared** and therefore never reported as `UNMANAGED`, because an alarm that
is red on a healthy box is one operators learn to ignore:

- `templates/launchd/RETIRED` — pending retirement; `retire_pass` unloads and removes it. The blind
  job itself (`com.tortoise.heartbeat-loop`, hand-installed, no template ever named it) is listed
  there, so **the same change that diagnoses it removes it** — otherwise `--status` stayed red until
  a human hand-deleted a plist, since `--uninstall` iterates templates and nothing describes it.
- `templates/launchd/OWNED-BY-OTHER-INSTALLERS` — installed by **another surface of this repo**. The
  harness controller `com.eldato.orchestrator-loop` is rendered by
  `scripts/orchestrator-harness/install.sh` from its own template, so it is not this installer's set
  to describe; flagging it made `--status` exit 1 forever on the reference Mac, and
  `scripts/fleet-schedule.py` turns that into `SCHEDULE NOT VERIFIED`. The list is drift-gated by
  `install-launchd.test.sh` §18, which pins every entry to the declaring installer's own `LABEL=`.

A job **nobody** declares is still `UNMANAGED`, and the report now names the exact command that
removes it.

## ⛔ What is NOT the fix

**Do not relax `automation.socketControlMode` from `cmuxOnly` to `automation`.** That widens "only
processes started inside cmux" to "any process by this user" **for the whole machine**. It is an
**owner decision**, it is argued on its own issue, and it is not something to smuggle in through a
bug fix.

## macOS / Linux — the divergence, stated once

The default is **parity**. The differences below are the whole list; each one is here because the
platform genuinely lacks the mechanism, not because it was easier.

| | macOS | Linux (cloud cell) |
|---|---|---|
| Launcher | `heartbeat-launch.sh start`, once, from a cmux-attributed shell | same script, run under the cell's `tmux` lifetime |
| Scheduled layer | `install-launchd.sh` (launchd) | `scripts/fleet-schedule.py` (#1864) — the **same** plist declarations |
| cmux socket gate | **present** (`cmuxOnly`) → a launchd job is blind, hence `LAUNCHD-INCOMPATIBLE` | **absent** (no cmux desktop app) → the same loop is legitimate here |
| `check` | identical | identical |

The cmux gate is the **only** behavioural difference, and it is on the launch path rather than on
the code: the loop is the same file, with the same contract, on both.

**Reboot does not restart the loop** on either platform. Re-run `heartbeat-launch.sh start` after a
reboot; that is a property of "detached launched-once loop" and it is why `check` exists — a loop
that died is reported as DRIFT rather than silently believed alive.

⛔ **A PID IN THE PIDFILE IS NOT AN IDENTITY.** The loop's pidfile holds a bare `$$`, written once
and removed by an EXIT trap — so a `SIGKILL`, an OOM kill or a reboot leaves the old number on disk,
and the kernel reuses it. `kill -0` alone therefore answers "somebody holds this number", which is
how `start` came to print `already running` and exit 0 **without launching** (nothing else starts a
launched-once loop) and how `check` printed `OK loop alive` over a dead heartbeat. All three verbs
therefore cross-check the pid against its **own argv** (`pid_is_loop`, the same rule
`docs/ops/fleet-liveness.md` records for this pidfile): a stranger holding the number reads
`stale pidfile` in `start`, `DRIFT` in `check`, and `alive: no (… another process)` in `status`. An
unreadable process table is UNKNOWN in `check` and a loud refusal in `start` — never a pass, and
never a second loop.

## Related

- **#1864** — the cells' scheduled layer (the *scheduler's* portability; delivered by
  `fleet-schedule.py`). This issue is the *heartbeat's launch path + install honesty*.
- **#1914** — `lane-actions` idle classification (`idle` is reachable only through Step 2), the
  stale-binding half of the same blind-fleet problem.
- **#1862** / **#1863** — the orphan reaper, restored and versioned.
