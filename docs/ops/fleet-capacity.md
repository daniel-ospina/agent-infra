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

The fork fields are **appended** to the record (`procs`, `max`, `fork`, then `boxid`/`boot`), so a peer
that parses the record by KEY still reads the leading fields. ⛔ That tolerance does NOT extend to the ref
NAME: the `<boxid>` path segment is part of the key, so a pre-#2707 reader drops a 3-segment ref entirely
and falls to `bound=no_probe` (refuse, never guess), and a pre-#2707 WRITER host-prunes and deletes those
refs — upgrade a whole hostname group together (§Identity and pruning below). A two-segment ref from before
#2707 (no `boxid`) is read as `box_unknown` and a six-slot one likewise (`box_unknown`, because identity is
checked BEFORE fork) — neither is ever read as healthy, and both self-heal on that box's next publish.

Transport: the fleet's only shared channel is the queue repo's origin, so a box publishes its
reading as `refs/boxes/<host>/<boxid>/<reading>` and every box reads the whole fleet with **one**
`git ls-remote --refs refs/boxes/*` — the same channel and the same read primitive `claims.sh`
already uses. No new daemon, no new credential, no per-box RPC.

Identity and pruning (#2707, measured 2026-10-24). `hostname` is NOT the key: all three cells are named
`cmux`, so a hostname-keyed ref plus a host-scoped prune made each box delete its peers' records and the
fleet read as one box (`cap_place` answering `place=<self>`). A record is keyed `<host>/<boxid>`, where
`boxid` comes from the box's own network identity — Darwin `kern.uuid`, Linux the routable IPv4 — the two
sources **measured to differ** across the cells. `/etc/machine-id` and `/proc/…/boot_id` are measured
IDENTICAL on all three (cloned image), so neither is a fallback: a box with no derivable identity
**refuses to publish** (`why=no-box-identity`) instead of manufacturing an attribution, and its peers
never see a record they cannot attribute. `CAP_BOXID` pins one explicitly for a deploy that must.

A box deletes a ref only when (a) a **local authorship ledger** proves this box wrote that exact ref
(recorded at publish time under `CAP_STATE_DIR`, default `${TMPDIR:-/tmp}/pi-capacity`, one file per
repo, ring-bounded at `CAP_LEDGER_KEEP=32` refs and one filesystem per box), or (b) the record is STALE.
A wiped `TMPDIR` therefore degrades pruning to STALE-only — refs leak for at most `CAP_PROBE_TTL` (900 s)
and are then collected; it never causes a delete.
Anything else is a peer's and is kept; a fresh record under this box's own key that it cannot prove it
wrote is counted `foreign=<n>`. When two fresh refs under one key disagree on `ncpu` or on `boot`, the
reader marks the key `collide=1` and `cap_place` REFUSES (`bound=identity_collision`) rather than placing
on a box the fleet cannot name. `foreign>0` alone is a *reading*, not a refusal: a box's own unprovable
prior ref (a wiped `TMPDIR`) raises it without any collision. ⛔ `(key, boot)` equality
is NOT authorship — a mis-keyed peer satisfies it, and reading it as proof deleted live peer records
(reproduced; see `capacity.sh`'s header).

## 4. The order: FORK HEADROOM, then disk, then load

⛔ Two bounds precede these, in this order: **`probe_stale`/`probe_unreadable`** (the reading's age is
checked first) and **`box_unknown`** (a record that names no box is not judged on its numbers at all —
`cap_bound_hit` checks identity before fork, because every other bound is a statement *about a box*).

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
bash scripts/ci_runner_pool.sh reclaim [--name <n>] [--dry-run]
                                                   # RETIRE a registration GitHub deleted
bash scripts/ci_runner_pool.sh reconcile            # the pass (idempotent; NOT yet scheduled)
                                                   # restart -> reclaim -> add, one pass, that order
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
- **The pool is every LIVE runner ON THE BOX, not every directory under one root.** `RUNNER_ROOT` must be
the directory that **CONTAINS** the instance dirs (one level above them) — its default
`/tmp/actions-runner` is where this tool puts what it creates, and on a hand-provisioned box the
installs may live elsewhere (measured: three live listeners under `/opt/gh-runner-*` while the
default root held one dir). A listing under a root that excludes a LIVE listener is a **partial**
count of a per-BOX budget — memory and cores do not partition by directory — so the tool reads the
process table for instance dirs outside `RUNNER_ROOT` and refuses with
`cannot-measure why=pool-root-incomplete … outside=<dirs>`: `add` would otherwise put a fourth runner
on a three-slot box, and `restart` would call an existing registration "no registration … (add it
first)". Set `RUNNER_ROOT` to the parent that contains **every** instance dir (`RUNNER_ROOT=/opt`
above) and the same box reports its real slots and can restart its real registrations.
  ⚠️ **The reading is the process table, so it holds LIVE listeners only**, and the report says so
  (`pool_read=process-table-live-only`): an instance dir outside `RUNNER_ROOT` whose listener is
  **DEAD** is invisible to it, so `status` cannot count it and `restart` cannot find it — the refusal
  names that limitation instead of asserting the registration does not exist. That is the one class
  this read cannot close, and it is why the parents should be **consolidated under one directory**:
  pointing the root at `/opt` on a box that also keeps an install under `/tmp` strands the other one,
  and the refusal names the dirs it found rather than guessing which parent was meant. A listener
  started through a wrapper (`nohup`, `env K=V`, `bash`, a service shim) is still read as a listener:
  the instance dir is the **argv word that carries the binary**, with wrapper tokens stripped one at a
  time (an instance dir may contain a space), and a dir that does not RESOLVE is
  `cannot-measure why=instance-dir-unresolvable` (rc 2) — never judged by its spelling, and never
  dropped. A **symlinked** instance inside the root is still in-pool: `run.sh` resolves its own dir
  with `cd -P`, so argv carries the target, while the listing counts the name.
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
- **`slots=` is CAPACITY, not a directory count, and `reclaim` is the verb that repairs a
  registration GitHub deleted.** Measured on `pi-cell-4` (2026-10-27): `slots=5` against `ceiling=3`
  on a box with two live listeners — the other three "slots" were a registration GitHub had deleted
  server-side, a directory with no registration in it, and `/opt/containerd` — so the ADD arm could
  never run and the box sat one runner short of its own ceiling. `status`/`reconcile` now print
  `registrations=` (directories), `orphaned=` and `quarantine=` beside `slots=`, and `slots = live +
  revivable + uninspectable`, DEDUPED BY `agentName` (two directories carrying one `agentName` are one
  registration, so starting both is not twice the capacity). A registration GitHub deleted is neither
  capacity nor a startable slot — `restart` starts a listener, the session is refused, and it exits
  **rc 6** — which is why the repair is `reclaim`: it verifies the refusal IN THIS PASS (under a clock
  it measured, bounded by `RUNNER_MAX_SKEW_S`) and only then renames the install to
  `<name>.retired-<stamp>` and removes it. ⛔ **Rename-then-delete is not tidiness**: a bare `rm -rf`
  that fails halfway has already unlinked `.runner`, leaving bytes no verb can see (measured: 6.9 GB
  named by nothing), so the pool loses the registration in one step and the leftover keeps a name —
  `status` reports it as `QUARANTINE` (and `LIVE-QUAR` if a listener is somehow running on it) until
  the bytes are gone, and `.retired-` is a RESERVED suffix `add` refuses. ⛔ **rc 6 is not rc 2**: "this
  registration is gone server-side, run `reclaim`" and "I could not act, re-run" lead an operator to
  opposite next steps, so the code is passed through rather than folded. ⛔ And the evidence `reclaim`
  acts on is a refusal it dated itself, **never an old log line** — a skewed clock prints the same
  "registration has been deleted" text and exits permanently (actions/runner#4648), so an install can
  be DEAD with a HEALTHY registration. An `ORPHANED` row in `status` therefore means "the newest
  evidence says deleted, a blind restart cannot be assumed to clear it", not "proven gone", and the
  exit code routes the caller to `reclaim`, the one verb that settles it.
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
message names) · 3 REFUSED, nothing changed — `add`: a gate verdict (floor/ceiling); `restart`: no
registration for that name under `RUNNER_ROOT`, or something that is not a usable instance sits on it
(a directory without `.runner`, a file, a dangling symlink) (NOT a capacity verdict — the message names
the state and the action that clears it: "clear it, or pick another name" — and, for the "no
registration" arm, that the reading is the **process table**, so an instance dir outside `RUNNER_ROOT`
whose listener is DEAD is invisible there) · 3 `status`: the
report contains a DEAD listener, an ORPHANED registration, or a `defect tmpdir-missing` row · 4 name
not available (that name is taken; try another) · 5 this
name could not be REGISTERED (config.sh failed, or left no `.runner` — a PER-NAME failure, so the pass
tries the next name instead of ending: `/tmp` is where `RUNNER_ROOT` lives, so a reboot erases every
local `.runner` while GitHub keeps every registration, and the first name minted after a reboot is
always taken) · 6 PROVABLY ORPHANED — the listener started and GitHub refused the session because the
registration no longer exists server-side (`restart`, `reconcile`); nothing was measured wrongly and no
gate refused it, so a scheduler can branch on "repair with `reclaim`". ⛔ **4 is checked before 3**: a name that is already taken reports 4 even on a box that
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


## 9. The required-check reservation — so the ONE required status never queues behind advisory work

`agent-infra` has exactly one required status context (branch protection =
`["pipeline-compliance"]`, measured). That job is ~9 s of work. On 2026-10-24 it was measured
queueing **13 minutes** for those 9 seconds, behind 66 queued runs (~1,650 jobs) of *advisory*
work — `bash-suites` alone is an 8-job matrix. A `pipeline-compliance` that is `queued` is
indistinguishable from a broken gate, so merges stall for hours while every recorded, green
candidate PR sits there.

The fix is a **reservation**, not a new gate: a small number of runner slots that carry a dedicated
label `required-check`, which only `pipeline-compliance` asks for. Same check, same commit, same
assertions — it simply does not wait behind 1,600 advisory jobs.

### 9.1 The job side (this repo)

`.github/workflows/pipeline-compliance.yml` routes **only** the `pipeline-compliance` job through
the `PIPELINE_COMPLIANCE_RUNS_ON` variable, whose default is `ubuntu-latest` (the reservation value
is declared in that job's comment block). It also carries `timeout-minutes: 20` (#2055): a hung
step on a reserved slot would otherwise hold a runner and silently park the only required check.

Every other job keeps `ubuntu-latest`. `tests/required-check-reservation/run.sh` pins all three
properties, including a mutation that moves one more job onto the reservation (it must fail).

**The default is the fallback, deliberately.** GitHub Actions has no fallback/OR in `runs-on`:
labels are ANDed, and a job whose labels match no online runner does not run at all — it waits
`queued` until GitHub cancels it (the self-hosted **job-queue limit is 24 h**: *"A job can be in
the queue for 24 hours before it is automatically cancelled"*). An unconditional
`[self-hosted, Linux, X64, required-check]` would therefore make the repo's *only* required check
unsatisfiable until a runner is labelled — worse than the queue — and would deadlock every
consumer reusing this file via `workflow_call`. With the variable unset the job runs exactly as it
does today; the reservation is one command to engage and the same one to release.

That 24 h cancel is **not a safe place to wait**, which is the second half of the same argument: a
`cancelled` check is in the rail's `NON_RED_CONC` allow-list (`scripts/admin-merge.sh`), so a reservation that was
engaged but never labelled would end as a **non-red** required check instead of a visibly `queued`
one — the rail's own fail-open class (#2474). Hence §9.3's release deadline.

A second job or a matrix arm is **not** an option: branch protection requires the context to be
named exactly `pipeline-compliance`, and a matrix arm renames it (`pipeline-compliance ([...])`)
while a second job reports a different context. Either way the required context is never
satisfied and every PR blocks.

### 9.2 Applying the label — the exact, reproducible call

Do this **before** engaging the variable, then verify. `<id>` is a runner id from the listing.

1. List the runners and pick the slots to reserve:

```bash
gh api --paginate repos/daniel-ospina/agent-infra/actions/runners \
  --jq '.runners[] | {id, name, status, busy, labels: [.labels[].name]}'
```

2. Add `required-check` to each reserved runner and remove `ubuntu-latest` from it. Use the
   non-destructive pair — **`PUT …/labels` REPLACES every custom label on the runner** (it is
   documented as *"Remove all previous custom labels and set the new custom labels"*), so using it
   here would silently delete any other custom label a fleet cell carries and leave work that
   targets that label unrunnable:

```bash
# add the reservation label (additive; POST does not touch the rest)
gh api -X POST repos/daniel-ospina/agent-infra/actions/runners/ID/labels \
  -f 'labels[]=required-check'

# then remove ONLY the label that leaks the reservation back to advisory work
gh api -X DELETE repos/daniel-ospina/agent-infra/actions/runners/ID/labels/ubuntu-latest
```

If you do use `PUT` (e.g. to rebuild a mislabelled runner in one call), you must pass the
**complete surviving CUSTOM label set** — and that set is **`self-hosted-x64` plus `required-check`**,
which is the live listing's custom labels MINUS `ubuntu-latest`. Do **not** copy step 1's listing
verbatim: it includes `ubuntu-latest`, and re-adding it would revert this reservation to advisory
work while you believe you followed this doc. Do **not** list `self-hosted`/`Linux`/`X64`: those are
AUTOMATIC labels GitHub stamps from the host, they are not part of the custom set `PUT` replaces,
and `scripts/ci_runner_gate.sh` excludes them from its own body for exactly that reason.

Removing `ubuntu-latest` is part of the reservation, not a detail: a reserved runner that still
carries `ubuntu-latest` keeps accepting advisory jobs, so the reservation is advisory too. Keep
`self-hosted-x64` — the pool marker is what makes the runner selectable at all, and dropping it
strands a registered-but-jobless runner (#2373).

3. Verify the reservation is visible to the scheduler (THE ARTIFACT, not the send):

```bash
gh api --paginate repos/daniel-ospina/agent-infra/actions/runners \
  --jq '.runners[] | select([.labels[].name] | index("required-check")) | "\(.id) \(.name) status=\(.status) labels=\([.labels[].name]|join(","))"'
```

### 9.3 Engaging and releasing the reservation

```bash
# ENGAGE — the required check now uses the reserved slots.
gh variable set PIPELINE_COMPLIANCE_RUNS_ON --repo daniel-ospina/agent-infra \
  --body '["self-hosted","Linux","X64","required-check"]'

# RELEASE (the fallback) — back to exactly today's behaviour, immediately.
gh variable delete PIPELINE_COMPLIANCE_RUNS_ON --repo daniel-ospina/agent-infra
```

`RELEASE` is the documented fallback and it is always available: it is what keeps a dead or
unlabelled reservation from being an outage of the only required check.

**⛔ RELEASE WITHIN 24 HOURS of a reservation going dark.** Tell-tale: the required check is sitting
`queued` on the engaged label. Do not wait it out. GitHub's self-hosted **job-queue limit is 24 h**,
and the job is then `cancelled` — which `scripts/admin-merge.sh` treats as **non-red**
(`NON_RED_CONC`), so past that point the required context stops being a visible obstruction and
becomes a silent one. Release the variable first, then repair the label; verify the required check
is neither `queued` nor `cancelled` on the head before trusting the rail.

### 9.4 Residuals, stated because they are not fixed here

- **A `cancelled` REQUIRED check is non-red in the rail** (`NON_RED_CONC` allow-list in `scripts/admin-merge.sh`,
  `{success, neutral, skipped, cancelled, stale}`). This is pre-existing and is the same class as
  #2474 (a cancelled guard leg satisfying a completeness check with no verdict); the reservation
  makes it *reachable* via the 24 h queue cancel, which is why §9.3 carries a deadline. The rail
  fix — a `cancelled` context that is REQUIRED must not be non-red — belongs to #2474, not here.

- **The label is not durable on its own.** `scripts/ci_runner_gate.sh` preserves custom labels it
  did not add, so it will not strip `required-check` — but on its fallback arm it *adds*
  `ubuntu-latest` to the pool, which leaks reserved slots back to advisory work. Re-assert §9.2
  after a fallback flip. (Do **not** try to solve this by taking the reserved runners out of that
  gate's pool: `self-hosted-x64` is the pool selector the gate resolves (`POOL_LABEL_X64`), so
  dropping it strands the whole x86 arm — the #2373 failure §9.2 warns about. The leak is repaired
  by re-asserting §9.2, not by removing the marker.)
- **A dead reserved listener is a single point of failure** for the only required check. This is
  #2682 blocker 2 (the `ai-runner-*` restart loop) and it is *why* the fallback in §9.3 exists.
- **#2682 blocker 1 is still open.** It recorded: keep the required check off self-hosted capacity
  until a dedicated, ephemeral, credential-free runner exists. The runners available today are
  persistent fleet cells and this repo is public, so engaging the reservation runs the PR's own
  `scripts/check-pipeline-compliance.sh` on a fleet machine. Engaging it is therefore an operator
  decision — the change ships **off** by default for exactly that reason.
- The starvation engine is that the pool advertises `ubuntu-latest` at all (the standing-rule
  violation in #2344/#2656, whose blast radius #2589 measured). The durable fix is that the pool
  stops advertising it, as `daniel-ospina/tortoise`'s pool does. The reservation reduces the blast
  radius; it does not remove it.
