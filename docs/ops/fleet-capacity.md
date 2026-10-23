---
title: "Fleet capacity placement & the self-dispatch proof"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-10-21
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-2373, fleet, orchestrator-harness, runner-pool
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
- `place=<peer>` **and this box is at/above 4.00 load/cpu** → the item is **left unclaimed and
  un-consumed** (the #1909 yield semantics, driven by a measurement instead of a prior refusal), so the
  eligible box can take it on its next pass. Below 4.00 this box keeps its work — no fleet-wide
  stand-down.
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

## 8. The other half: the runner POOL is provisioned from this repo

Placement (§1–§7) decides **which box takes the next lane**. It says nothing about the boxes' CI
**runners** — the machines that execute the test jobs. Until `scripts/ci_runner_pool.sh` those had no
in-repo provisioning path at all: two scripts could do it and both lived only as untracked files in
one cloud cell's `/tmp` (agent-infra#2373), so a fresh cell could not provision a runner from the
repo, the scripts were one `rm` away from being lost, and every capacity change was a hand step.
Measured 2026-10-22 22:30–22:45Z: the pool went **6 → 12 online entirely by hand**; two runners
GitHub showed OFFLINE were not missing but had **dead listeners** (their `_diag` stopped with
`Deleting Runner Session`), and nothing in the repo could re-register one.

```bash
bash scripts/ci_runner_pool.sh status  --all        # rows + readings (--all is the same view: the
                                                   # default already lists every runner on THIS box)
bash scripts/ci_runner_pool.sh add     --name <n>   # floor- and ceiling-gated
bash scripts/ci_runner_pool.sh restart --name <n>   # bring a dead listener back
bash scripts/ci_runner_pool.sh reconcile            # the pass (idempotent; NOT yet scheduled)
```

Rules, each measured rather than preferred:

- **Which repo, and the token.** `RUNNER_POOL_REPO` (bare `owner/name`, default
`daniel-ospina/tortoise`) is **both** the registration-token's scope and the URL the runner registers
at; a URL form is `cannot-measure why=repo-unreadable`, not a runner. `add` needs `RUNNER_TOKEN` or an
authenticated `gh` (a token is single-use and expires in ~1h, so one is minted per add and never
stored) — ⛔ which is why a token supplied in the ENVIRONMENT serves exactly ONE add: `reconcile`
refuses to run its ADD arm with `RUNNER_TOKEN` set (`cannot-act why=runner-token-single-use`, rc 2)
rather than spend it on the first name and fail every later one as `name-failed`.
`bash scripts/ci_runner_pool.sh --help` prints every seam and the full EXIT contract.

- **The memory floor gates ADDING, never RESTARTING.** An add below `RUNNER_MEM_FLOOR_MB` (3584 =
the 3.5 GB the gate refused at) is REFUSED and **prints the reading it used** — the owner made that
a predicate, not a wish (agent-infra#2344, comment 6347825624: *"must refuse to add a runner when
free memory is below a stated floor, and must report the reading it used"*). A dead listener for an
EXISTING registration costs ~200 MB to bring back and is capacity the box already paid for; refusing
it on a low-memory box would leave the slot registered, advertised to GitHub and idle.
- **The SLOT ceiling is core-aware and per box**: `ceil(ncpu / RUNNER_CORES_PER_SLOT)` — 3 slots on an
8-core box, 2 on a 4-core box, the owner's sizing. A refusal names the core count, the ceiling, the
slot count **and** the memory reading. This bounds runner slots, not lanes, and does not touch §4's
ruling that there is no lane ceiling tied to cpu count.
- **One complete runner install per instance dir**, which is GitHub's own layout, not a preference:
  `config.sh` and `run.sh` resolve **their own** directory (`DIR="$(cd -P … )"; cd "$DIR"`), so
  `.runner` is written beside the script and the caller's cwd is ignored. `RUNNER_ROOT` defaults to
  the measured `/tmp/actions-runner`, `RUNNER_TEMPLATE` holds one pristine unpacked release, and each
  `add` **copies** it — a shared install with per-name dirs would register runners whose `.runner`
  never appears where the tool looks.
- **The pool is every runner ON THE BOX, not every directory under one root.** `RUNNER_ROOT` must be
the directory that **CONTAINS** the instance dirs (one level above them) — its default
`/tmp/actions-runner` is where this tool puts what it creates, and on a hand-provisioned box the
installs may live elsewhere (measured: three live listeners under `/opt/gh-runner-*` while the
default root held one dir). A listing under a root that excludes a LIVE listener is a **partial**
count of a per-BOX budget — memory and cores do not partition by directory — so the tool reads the
process table for instance dirs outside `RUNNER_ROOT` and refuses with
`cannot-measure why=pool-root-incomplete … outside=<dirs>`: `add` would otherwise put a fourth runner
on a three-slot box, and `restart` would call an existing registration "no registration … (add it
first)". Set `RUNNER_ROOT` to the parent (`RUNNER_ROOT=/opt` above) and the same box reports its real
slots and can restart its real registrations.
- **Liveness is the process table, not a pid file.** A pid file records a past state and is never
  revalidated; a recycled pid reads "live" forever, and on a box without `/proc` it cannot be
  revalidated at all. The runner's argv (`<dir>/bin/Runner.Listener run`) cannot go stale, and it is
  the only way the runners the old hand scripts started are visible — they wrote no pid file, and
  reading them as DEAD would double-start a listener on every pass. ⛔ **The table is read at full
  width** (`ps -ww`): procps truncates `args` to `$COLUMNS` (measured: every line exactly 80 chars
  under `COLUMNS=80`, the argv cut mid-`Runner.Li`) and BSD/macOS truncates unless `-w` is given, so
  a truncated read would report a LIVE listener as DEAD — and `restart`/`reconcile` would answer that
  by starting a SECOND one for the same registration.
- **The label describes the runner.** `ci_runner_gate.sh` selects the pool by `self-hosted-x64` /
  `self-hosted-arm64`. A runner registered without that marker is invisible to the gate forever —
  registered, advertised, idle. The marker is derived from the host's arch by default; an arch we
  cannot name is `cannot-measure`, not a jobless runner. Runner **names** are unique per repo, so the
  prefix defaults to `pi-runner-<host>` — two boxes' passes must not mint the same name.
- **`reconcile` is the point, not the one-shot verbs.** It starts every dead listener, adds only
  above the floor and below the ceiling, and a gate verdict ENDS the pass (the verdict is a
  measurement of the box, not a per-name accident) — while a taken **name** is skipped, because one
  stale directory must not cost the box the capacity it is entitled to. It is idempotent; a `cannot-act` makes the pass
  exit 2 — and so does a pass that ends short of the ceiling having registered nothing, because a
  per-name code must never be able to report a box that could register nothing as success. ⛔ An
  **unreadable capacity reading does not stop the restart arm**: bringing a dead listener back needs
  no memory or core reading, so the pass restarts first and only the ADD arm is gated — otherwise a
  box whose reading is broken (the box most likely to have dead listeners) would have every one of
  them left dead, with nothing in the output saying the restart arm was never reached. ⛔ **Nothing schedules it yet** —
  arming it (which boxes, which interval) is an operator decision, and this change deliberately does
  not self-arm a timer.

`status --all` is scoped to **this box**: nothing in this repo reports runners **per cell** —
`capacity.sh`'s probe knows host, cores, load, lanes and disk/memory and **nothing about runners**, and
neither does the fleet inventory. Nor does any tool list the GitHub-side registry:
`scripts/ci_runner_gate.sh --status` prints only the gate's mode (`mode=… repo=…`) and counts
`ubuntu-latest` runners without naming them. The per-cell runner report #2373's clause 2 words is **not**
delivered by this change; the registry itself is only readable directly, e.g.
`gh api repos/<owner/name>/actions/runners --jq '.runners[] | {name, status, busy}'`. Within this box the
table is complete, so a runner this box registered and
then lost the local evidence for is not in the table — that is why an add whose listener fails keeps
its `.runner` and says so. `--all` widens nothing: the default view already lists every runner on this
box, and the flag exists because #2373's clause names it.

`EXIT: 0 ok · 1 usage · 2 could-not-measure/could-not-act (nothing changed, except a registration the
message names) · 3 REFUSED, nothing changed — `add`: a gate verdict (floor/ceiling); `restart`: that
name has no registration under `RUNNER_ROOT`, or its directory exists but carries no `.runner` (NOT a
capacity verdict — in each case the message names the state and the action that clears it; "add it
first" is only said when there is no directory at all) · 3 `status`: the
report contains a DEAD listener · 4 name not available (that name is taken; try another) · 5 this
name could not be REGISTERED (config.sh failed, or left no `.runner` — a PER-NAME failure, so the pass
tries the next name instead of ending: `/tmp` is where `RUNNER_ROOT` lives, so a reboot erases every
local `.runner` while GitHub keeps every registration, and the first name minted after a reboot is
always taken). ⛔ **4 is checked before 3**: a name that is already taken reports 4 even on a box that
is also at a gate, because the name condition is a fact about the request, not about the box — a
caller that branches on 4 to try another name must be able to see it. `status`
exits 3 when a listener is DEAD (the verdict a caller branches on) and 2 — never 0, never 3 — when it
could not measure, which includes an unreadable **process table** AND an unreadable **pool listing**
AND a pool that only PARTLY matches `RUNNER_ROOT` (`pool-root-incomplete`):
they are the unreadable inputs whose absence would produce an action (a second listener; an add above a
ceiling counted from a listing that failed, or from one that excludes live runners elsewhere on the box)
instead of a refusal, so all fail closed. An unreadable
**instance dir** is counted as a slot and reported `cannot-measure why=instance-unreadable`, never DEAD
— the third unreadable input whose absence would produce an action (a start) instead of a refusal. A
root that exists but is **not a directory** is `cannot-measure why=runner-root-not-a-directory`, not an
empty pool.
Tests:
`scripts/ci_runner_pool.test.sh` (in both bash lanes), whose install stubs model GitHub's own cwd
contract and listener argv, and which includes a mutant with the floor comparison defused that must
stop refusing.
