---
title: "Fleet capacity placement & the self-dispatch proof"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-10-21
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, fleet, orchestrator-harness
---

# Fleet capacity placement & the self-dispatch proof

Two halves of ONE measured defect, and the two artifacts that close it:
`scripts/orchestrator-harness/capacity.sh` (which box takes the next lane) and
`scripts/orchestrator-harness/cycle-record.sh` + `bin/harness status` (proof the controller is
cycling at all).

## 1. The measurement (2026-10-21 09:45)

| box | load | cpu | load/cpu | `pi` procs | sessions |
|---|---|---|---|---|---|
| cell-1 | 29.82 | 8 | 3.73 | 105 | 5 |
| cell-3 | 8.14 | 4 | 2.04 | 67 | — |
| cell-4 | 0.56 | 8 | 0.07 | 23 | 5 |

One box saturated while a box **twice its size** sat idle, and nothing moved the work. Separately
the controller log on cell-1 was **37h stale** and on the other two cells **no controller log was
found at its expected path** — so "the controller is looping" was UNPROVEN.

## 2. Why nothing moved: the assignment point

There is no fixed box→lane assignment to preserve. A lane was placed by **first-come claim**
(`claims.sh`'s `claim_issue_acquire`, an atomic CAS on `refs/claims/issue-<N>`): whichever box's
controller reached a candidate first won it, with no measurement of either box. Every admission gate
(`load=$L>=max_load`, `lanes=`, `swap_free=`, `mem_avail=`) reads only the box it runs on, and the one
cross-box signal — `capacity_yield_live()` (#1909) — fires only *after* a box has refused. A box at
half its ceiling never refuses, so the fleet never learns its neighbour is idle.

The single recorded box→repo pin is the heartbeat's own standing order (FA3, "advance agent-infra
(cell-2 owns it)"). That is a **repo ownership** statement and this work does not touch it — the
placement rule chooses a box for a *lane dispatch*, never re-assigns a repo. FA2 in the same order
("dispatch locally if the local machine has room, on a cloud VM if it is idle") is the order this is
the missing half of.

## 3. The probe — one record per box

`bash capacity.sh probe` prints one line; peers publish the same line to the shared origin.

```
host=cell-4 ncpu=8 load1=56 lpc=7 lanes=0 disk_free_mb=120000 mem_free_mb=14000 at=1792598400 procs=412 procs_max=15641 fork=1 src=uid
```

- `lpc` — **load per CPU, in integer hundredths** (bash 3.2 has no floats). This is the number the
  rule compares, so boxes of different sizes are comparable.
- `lanes` — lane worktrees on the box. **Reported, never a ceiling** (see §4).
- `disk_free_mb` — free space on the filesystem the repo lives on: the volume that actually fills.
- `mem_free_mb` — the same helper the controller's own memory gate uses.
- `at` — the epoch of the reading. A record with no age is a stale flag waiting to be read as
  current.
- `procs` / `procs_max` / `fork` — fork headroom (§4). `procs_max=0` means **no ceiling was found**
  (unbounded), never "zero headroom". `src` is the arm that answered (`uid` or `cgroup`) and is local
  to the box: it is printed by `probe`, not transported in the ref name.

The fork fields are **appended** to the record and the ref name
(`refs/boxes/<host>/<at>-<ncpu>-<load1>-<lanes>-<disk>-<mem>-<procs>-<max>-<fork>`), so a peer on an
older tree still parses the leading fields; a six-slot legacy ref is refused as `fork_unknown` rather
than read as healthy, and it self-heals on that box's next publish.

Transport: the fleet's only shared channel is the queue repo's origin, so a box publishes its
reading as `refs/boxes/<host>/<reading>` and every box reads the whole fleet with **one**
`git ls-remote --refs refs/boxes/*` — the same channel and the same read primitive `claims.sh`
already uses. No new daemon, no new credential, no per-box RPC.

## 4. The order: FORK HEADROOM, then disk, then load

**Measured 2026-10-21 19:50–20:10 UTC (#2293).** Cloud **cell-4** (8 vCPU) could not spawn at all:

```
/bin/bash: fork: Resource temporarily unavailable
spawn /bin/bash EAGAIN          (rc 128; persistent over 75 s)
last good reading: load=2.54/8 (0.32x)  lanes=11  pi_procs=16
```

The Mac hit the same wall minutes later, and there it is provable in isolation: `echo ok` (a shell
builtin, no fork) worked while every spawn failed. So the binding resource was **process/fork
headroom** — invisible to load average, to memory, and to any lane counter. A 12th lane placed by a
load-only rule lands on a box with **no pids left**, and that failure is not graceful: the box cannot
be probed from inside, nothing can be cleaned up locally, and every retry by an already-placed lane
forks more.

The probe therefore reads, in this order, and refuses by the FIRST bound it hits:

1. **fork headroom** — `procs` (live process count) against `procs_max` (the smallest of `ulimit -u`,
   `kern.maxprocperuid`, and the cgroup `pids.max`), plus a **two-fork probe** (`fork=1|0`). Below
   `CAP_MIN_FORK_HEADROOM=200` spare processes the box is refused.
   The cgroup arm reads **the caller's own cgroup**, resolved from `/proc/self/cgroup` (walking up to
   the mount root), not just the mount root — measured on a fleet cell, `/sys/fs/cgroup/pids.max` does
   not exist while `/system.slice/<svc>.service/pids.max` is `4692`, so a root-only read reports
   `src=uid` and never sees the ceiling the box is actually bound by. The resolution uses builtins
   only (`read`, parameter expansion), because it runs on the path whose whole purpose is a box that
   cannot fork.
2. **disk** — as §4's floors describe.
3. **load** — last, because on a box that dies at fork before it gets CPU-busy it is the least
   informative of the three.

Why the order matters: the remedies differ and so do their time scales. A fork refusal **never clears
by waiting** — the remedy is an external restart or letting the box drain. A disk refusal clears by
pruning. Only a load refusal clears on its own. Reporting `load=` for a box that cannot fork sends an
operator to wait for an event that cannot arrive.

**A fork failure is fatal to the process that attempts it.** Measured on this tree's bash (5.2.21):
`ulimit -u 5; ( exit 0 )` prints `fork: retry: …` four times, then `fork: Resource temporarily
unavailable`, and **the script exits 254** — a `while` loop dies on its first failed fork. That is why
`bash capacity.sh probe` exits **254** when it could not fork (a named answer, not a crash), why the
probe runs inside a child, and why the controller treats 254 as `fork_exhausted` and stops forking for
that cycle.

**The controller survives it.** Measured: the local `com.eldato.orchestrator-loop` recorded a last exit
of **128** and never came back — launchd's relaunch needs the very fork that is failing. So
`orch-loop.sh` reads fork headroom **first** (before `date`, `git`, `gh` — before anything that spawns),
and when a box is starved it takes a builtin-only path: it writes a cycle record (`nothing=fork_exhausted`,
`fork=starved`) and naps on a FIFO opened at startup (`read -t` — no child process), then retries. The
box still cannot be repaired from inside; what changes is that it is **alive and named** instead of
vanishing into a respawn loop that cannot start.

That path is builtins-only in the WRITER too: `cycle_record_write` builds its path and sanitises every
field with parameter expansion (no `$( )`, no `tr`, no `mkdir` when the state dir already exists).
Driven: `( ulimit -u 1; cycle_record_write … )` returns 0 and the record is on disk, where a
substitution-based writer exits **254** having written nothing. A cycle whose clock cannot be read
without a fork (bash 3.2 has no `printf '%(…)T`) records `start=0`, and `harness status` reports that
record **UNREADABLE** — never `DEGRADED`-stale, which would tell an operator to restart a controller
that is alive and writing.

`bin/harness status` gains the verdict for that state:

| verdict | rc | meaning |
|---|---|---|
| `FORK-STARVED` | 1 | the controller is fresh and alive, and its own fork reading says the box cannot spawn |

The refusal names the read (`bound=fork_headroom` / `fork_probe` / `fork_unknown`), so "no box is
eligible" is never a bare fact: `fork_headroom` is a box that needs an external restart, `fork_probe` is
a box whose own probe refused, `fork_unknown` is a peer that published no fork reading at all.

## 5. The ceiling: 8.00 load per CPU — and what it protects

`CAP_LPC_CEILING=800` (hundredths). Measured, not derived: the fleet's own incident data puts the
saturation point at **8–10× cpu load**, and the controller's local hard gate is `ncpu*10` (`MAX_LOAD`),
so 8× is the "do not ADD work here" line one notch under "do not start anything at all".

There is a **second, lower line** — `CAP_YIELD_AT_LPC=400` (4.00 load/cpu) — the *prefer-elsewhere*
line. `place=<peer>` alone would be a thrash machine: every box would stand down for any box that
happens to be 1% idler, and the fleet would dispatch nothing while all of it was healthy. So a box
**below** 4.00 load/cpu takes its work whoever else is idle; **at or above** it, the candidate is left
for the least-loaded eligible peer. Both lines are load-per-cpu, and both appear in the verdict.

**It is not a lane cap, and there is deliberately no lane ceiling tied to cpu count** — the owner
ruled on 2026-10-17 that dispatch is gated on capacity, not on a lane count, and a lane count cannot
see the two things that actually bind:

- **`gh` serialisation per box.** Four boxes act as ONE GitHub account and `gh-limit` keeps ONE `gh`
  call in flight per box (#1988/#1910), so every lane added to a box lengthens every other lane's
  `gh` wait on that box. This is the real bottleneck under concurrency; it scales with lanes, and it
  is protected by refusing to pile work onto a box whose load-per-cpu says its queue is already deep,
  and by moving the work to the least-loaded eligible box.
- **Disk** — ~1.1 GB per live worktree before its venv (#2159): a box can have every core idle and
  no room. Floor `CAP_MIN_DISK_MB=500` (the same floor `spawn-gate.sh` enforces before a spawn).
- **Memory** — swap pressure is how a box dies rather than slows (#1985/#1961). Floor
  `CAP_MIN_MEM_MB=512`.

Every refusal names **which** bound it hit, because the remedies differ:

| `bound=` | meaning | remedy |
|---|---|---|
| `load_per_cpu` | every box is past 8× cpu | the fleet needs more boxes |
| `fork_headroom` | spare processes below `CAP_MIN_FORK_HEADROOM` (200) | **external restart or drain** — it cannot be cleaned from inside (#2293) |
| `fork_probe` | the box's two-fork probe refused | the same: the box cannot spawn at all |
| `fork_unknown` | a peer published no fork reading (a pre-#2293 record) | upgrade that box; it is ineligible until it republishes |
| `disk` | free space below the floor | `cloud-cell-supervisor.sh prune` on that box |
| `memory` | available memory below the floor | a leak somewhere on that box |
| `probe_stale` | a record older than `CAP_PROBE_TTL` (900 s) | that box's controller is not publishing |
| `probe_unreadable` / `no_probe` | an absent or unparseable record | an instrument failure — never "idle" |

Relation to `docs/ops/load-policy.md`: that policy's per-core thresholds (2.5× / 1.5×) **suspend
background batches** on a host; `MAX_LOAD` (10×, `spawn-gate.sh`) refuses a *local* spawn; this 8×
ceiling decides **cross-box placement**. Three different decisions, three numbers, each named.

## 6. The rule, and the fail-closed direction

`cap_place <this-box> <records…>` (or records on stdin) →

- `place=<host> lpc=<x100> evaluated=<n> eligible=<n>` — the **least-loaded eligible** box. Ties break
  on more free disk, then host name, so the decision is deterministic.
- `refuse bound=<bound> detail=<host>:<bound>… ceiling_lpc=…` (rc 1) — **no eligible box**.

**An unreadable box is never eligible**: an absent record, an unparseable one, or one older than the
TTL is not "probably fine". **If no box is eligible the dispatch is refused** with the measured
reason — never placed blind on the saturated box just because that is the box asking.

In the controller the verdict has three outcomes, and only two of them stop work:

- `place=<this box>` → dispatch as before.
- `place=<peer>` **and this box is at/above 4.00 load/cpu** → the item is **left unclaimed and
  un-consumed** (the #1909 yield semantics, driven by a measurement instead of a prior refusal), so the
  eligible box can take it on its next pass. Below 4.00 this box keeps its work — no fleet-wide
  stand-down.
- `refuse` → `GATE_WHY="capacity-placement(bound=…)"`: nothing is placed, and the bound is named.

## 7. The self-dispatch proof

`orch-loop.sh` appends **one line per cycle** to `$O/state/cycles`:

```
start=… end=… cycle=… interval=240 selected=issue:#2216 selected_n=1 dispatched=1 ids=#2216
nothing=none placement=place placed_on=cell-1 bound=none lpc_self=7 fork=ok fork_procs=412 fork_max=15641
```

`bin/harness status` prints the last N and grades the **newest** record:

| verdict | rc | meaning |
|---|---|---|
| `HEALTHY` | 0 | newest record younger than **two** of the box's own cycles |
| `DEGRADED` | 1 | older than that — the controller is not cycling |
| `ABSENT` | 2 | no record at all — **never** healthy, never "nothing to do" |
| `UNREADABLE` | 2 | the record cannot be parsed, or the clock cannot be read |

One missed cycle is ordinary (`CYC` is 240 s with jitter); two is a controller that is not cycling.
The interval comes from the record itself, so a box configured `CYC=600` is judged by its own clock.
**A record count is never freshness** — a long history whose newest line is 37h old is exactly the
state that read as fine on cell-1.

This is what answers "is it self-dispatching" without a human reading a pane: a live pane shows a
*process*, a fresh record shows a *cycle*.

## 8. Tests

`scripts/orchestrator-harness/capacity-placement.test.sh` (in `scripts/run-bash-shards.sh`, so both
CI lanes run it): the saturated box skipped and the least-loaded eligible box chosen; an
unreadable/stale/absent record never chosen; no eligible box ⇒ refusal naming the bound; a controller
with no record in more than two cycles is `DEGRADED` and one with no record at all is `ABSENT` — never
`HEALTHY`. Hermetic: clock/host seams, and a local bare repo as the shared origin (real pushes, real
`ls-remote`).
