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
host=cell-4 ncpu=8 load1=56 lpc=7 lanes=0 disk_free_mb=120000 mem_free_mb=14000 at=1792598400
```

- `lpc` — **load per CPU, in integer hundredths** (bash 3.2 has no floats). This is the number the
  rule compares, so boxes of different sizes are comparable.
- `lanes` — lane worktrees on the box. **Reported, never a ceiling** (see §4).
- `disk_free_mb` — free space on the filesystem the repo lives on: the volume that actually fills.
- `mem_free_mb` — the same helper the controller's own memory gate uses.
- `at` — the epoch of the reading. A record with no age is a stale flag waiting to be read as
  current.

Transport: the fleet's only shared channel is the queue repo's origin, so a box publishes its
reading as `refs/boxes/<host>/<reading>` and every box reads the whole fleet with **one**
`git ls-remote --refs refs/boxes/*` — the same channel and the same read primitive `claims.sh`
already uses. No new daemon, no new credential, no per-box RPC.

## 4. The ceiling: 8.00 load per CPU — and what it protects

`CAP_LPC_CEILING=800` (hundredths). Measured, not derived: the fleet's own incident data puts the
saturation point at **8–10× cpu load**, and the controller's local hard gate is `ncpu*10` (`MAX_LOAD`),
so 8× is the "do not ADD work here" line one notch under "do not start anything at all".

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
| `disk` | free space below the floor | `cloud-cell-supervisor.sh prune` on that box |
| `memory` | available memory below the floor | a leak somewhere on that box |
| `probe_stale` | a record older than `CAP_PROBE_TTL` (900 s) | that box's controller is not publishing |
| `probe_unreadable` / `no_probe` | an absent or unparseable record | an instrument failure — never "idle" |

Relation to `docs/ops/load-policy.md`: that policy's per-core thresholds (2.5× / 1.5×) **suspend
background batches** on a host; `MAX_LOAD` (10×, `spawn-gate.sh`) refuses a *local* spawn; this 8×
ceiling decides **cross-box placement**. Three different decisions, three numbers, each named.

## 5. The rule, and the fail-closed direction

`cap_place <this-box> <records…>` (or records on stdin) →

- `place=<host> lpc=<x100> evaluated=<n> eligible=<n>` — the **least-loaded eligible** box. Ties break
  on more free disk, then host name, so the decision is deterministic.
- `refuse bound=<bound> detail=<host>:<bound>… ceiling_lpc=…` (rc 1) — **no eligible box**.

**An unreadable box is never eligible**: an absent record, an unparseable one, or one older than the
TTL is not "probably fine". **If no box is eligible the dispatch is refused** with the measured
reason — never placed blind on the saturated box just because that is the box asking.

In the controller the verdict has three outcomes, and only two of them stop work:

- `place=<this box>` → dispatch as before.
- `place=<peer>` → the item is **left unclaimed and un-consumed** (the #1909 yield semantics, driven
  by a measurement instead of a prior refusal), so the eligible box can take it on its next pass.
- `refuse` → `GATE_WHY="capacity-placement(bound=…)"`: nothing is placed, and the bound is named.

## 6. The self-dispatch proof

`orch-loop.sh` appends **one line per cycle** to `$O/state/cycles`:

```
start=… end=… cycle=… interval=240 selected=issue:#2216 selected_n=1 dispatched=1 ids=#2216
nothing=none placement=place placed_on=cell-1 bound=none lpc_self=7
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

## 7. Tests

`scripts/orchestrator-harness/capacity-placement.test.sh` (in `scripts/run-bash-shards.sh`, so both
CI lanes run it): the saturated box skipped and the least-loaded eligible box chosen; an
unreadable/stale/absent record never chosen; no eligible box ⇒ refusal naming the bound; a controller
with no record in more than two cycles is `DEGRADED` and one with no record at all is `ABSENT` — never
`HEALTHY`. Hermetic: clock/host seams, and a local bare repo as the shared origin (real pushes, real
`ls-remote`).
