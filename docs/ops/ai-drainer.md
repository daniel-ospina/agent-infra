---
title: "The AI drainer and the second controller — scheduled dispatch for a repo no controller drains"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-10-24
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-2281, ai-drainer, multi-repo-controller, fleet-inventory, orchestrator-bringup, systemd
---

# The AI drainer and the second controller

Two scheduled things that exist because **a repo with open PRs and no controller bound to it gets no
automatic dispatch at all** (agent-infra #2281). Both ship in this repo; both are **inert until an
operator activates them on a box**, and both are in the fleet inventory so their absence is visible.

| artefact | what it is | schedule |
|---|---|---|
| `scripts/orchestrator-harness/ai-drainer.sh` | fills the box to its **measured** lane capacity: each tick dispatches `target − alive` bounded lanes that make PRs mergeable and merge what goes green | 20 min (both platforms) |
| `scripts/orchestrator-harness/multi-repo-controller.sh` | a SECOND controller bound to another repo, with its own state dir and pin | 900 s **top-up** on macOS (it no-ops when the controller is alive); a **named SKIP on a cell** — the plist declares `FleetResident`, because its body never returns |
| `templates/launchd/com.eldato.ai-drainer.plist`, `com.eldato.ai-multi-repo.plist` | macOS jobs | rendered by `scripts/install-launchd.sh` |
| `templates/systemd/eldato-ai-drainer.{service,timer}` | the cell's clock | rendered by `scripts/orchestrator-harness/install-drainer-timer.sh` |

## What they are not

- **Not a second funnel.** The drainer does not pick candidates from the controller's queue; it walks
  a PR list and does the work. The real fix for #2281 (one dispatch that serves several repos) is
  still unbuilt, and this is the smallest thing that keeps a backlog moving while it is.
- **Not a second controller on the same state dir.** Two controllers on one `$O` fight over
  `.orch.lock`, `candidates.txt` and the lane registry; `multi-repo-controller.sh` refuses that by
  name (and refuses the primary's `HARNESS_PIN` for the same reason).
- **Not installed by the PR, and not installed by a plain `install-launchd.sh`.** Both plists render
  from **env-only** placeholders, so an unset variable makes the installer SKIP the template with a
  loud warning (the same convention `{{SWARM_ROOT}}` uses). That is deliberate: `install-launchd.sh`
  with no arguments installs *every* template, and `pi-bootstrap/setup.sh` runs exactly that on every
  Darwin box — a default here would put a lane **dispatcher** on the whole fleet and a **second
  controller** on every box.

## The target, the guards, and why the lock's scope changed

`ai-drainer.sh` dispatches nothing unless every guard holds, and each writes one line to
`$AI/logs/ai-drainer.log` saying **which** reading refused (a skip is the tick correctly doing
nothing, and it exits 0):

1. **the target is a measurement, not a number.** Per tick:

       target = min( cpu_ceiling , mem_ceiling )
       cpu_ceiling = MAX_LANES = floor(ncpu × 5/2)          ← the fleet's 2026-10-17 lane ruling
       mem_ceiling = floor( (MemAvailable − MIN_MEM_FREE_MB) × MEM_BUDGET_PCT/100 ÷ LANE_MEM_MB )

   `MIN_MEM_FREE_MB` (512) is the **same** floor the controller's own spawn gate uses, so the two
   cannot disagree; `MEM_BUDGET_PCT` (75) stops the target at the boundary instead of consuming the
   last megabyte; `LANE_MEM_MB` (512) is the measured resident budget of one lane (a `pi -p` host idles
   at 77–85 MB; the fleet measures ~250–400 MB per working pass). Two arms refuse to *add* work on top
   of the target: **load ≥ 8 × ncpu** (`LPC_CEILING`, the fleet's "do not place here" line) and the
   **swap arm** — which is a *different gate on each platform*, because the two `free` numbers are
   different quantities:

   * **Linux** — swap is a fixed partition/volume, so `SwapFree` **is** headroom: `swap_free <
     MIN_SWAP_MB` (700) refuses. Only where swap EXISTS: a cell ships with no swap, so `SwapFree = 0`
     there means *absent*, never *exhausted*: folding the two made every tick on every cell skip, i.e.
     an installed job that dispatched nothing and exited 0.
   * **Darwin** — there is **no free-swap floor**, and the kernel's own verdict refuses instead:
     `kern.memorystatus_vm_pressure_level` (1 normal, 2 warning, 4 critical) at or above
     `MAX_MEM_PRESSURE_LEVEL` (default 2). Only 2, 3 and 4 are accepted: **`1` is rejected**, because
     it is the kernel's NORMAL level and the comparison is `>=`, so a threshold of 1 would refuse
     every box — for ever — while each tick exited 0. A deliberate stop is `MAX_LANES=0` /
     `TARGET_LANES=0`, never a threshold; an unusable value warns and falls back to the shipped
     default. macOS grows its swap files **on demand**, so `total` is the sum of
     the files the kernel has created so far and `free = total − used` is low *because the kernel grew
     the file*, not because the box cannot take a lane; `used` is a high-water mark it does not
     release. Measured 2026-10-29: `free = 412 MB of 3072 MB` refused every tick while the pressure
     level read **1 = normal** and `memory_pressure -Q` read **52 % free** — a latch that can never
     reopen. (Same root as agent-infra#2016, which corrected the identical reading in `orch-loop.sh`'s
     `[cap]` gate.)

   An unreadable **load / memory / swap / Darwin-pressure** probe **fails closed** — a guard that
   could not be evaluated must not look like an idle box. A box whose platform cannot be identified is
   one of those cases: the two swap arms are different gates, so choosing one on a guess is refused by
   name (`DRAINER_OS` overrides `uname -s`; it is the suite's seam). The **cores**
   probe is the one exception, and it does not fail closed: it is the CPU *ceiling* only, so an
   unreadable one warns and assumes 4 cores, which under-reports the ceiling (the conservative
   direction) instead of stopping the job.
2. **top-up, not one-shot.** Each tick counts the lanes already alive and dispatches `target − alive`
   of them, so the number of lanes converges on the measured capacity instead of on one per 20
   minutes. Zero when already at target, and the line prints the same arithmetic either way:
   `target=… alive=… dispatching N`.
3. **the census counts both populations.** Dispatcher lanes (`$O/bg/*.pid`, matched by **argv shape**
   — both shipped dispatchers record the pid of a *backgrounded subshell* whose command line is
   `bash …/nonblocking-dispatch.sh …`, so a test for "the command line starts with `pi`" counts
   **zero**) **plus** the launcher's workers (`wt_table`/`wt_count` in `worker-terminal.sh`, which is
   the only census that sees **durable-terminal** lanes — no pidfile names them and `pgrep` cannot see
   them). A stale module is named (`launcher census unavailable: …`) rather than read as "no workers".
   ⛔ The launcher half is an **upper bound**, clamped to the lanes actually present
   (`launcher = min(wt_count, lane roots − the dispatcher's share of them)`), because `wt_count`
   counts the cmux daemon's
   `terminals[].running` — *a shell is running in that terminal*, i.e. UI liveness — so a `wt-*`
   terminal whose `pi` has exited counted as a live lane **for ever** and the tick stood down with exit
   0 on a box with idle capacity (measured 2026-11-10 on pi-cell-3: `alive=36 (dispatcher=2
   launcher=34)` against **9** live `pi` processes — agent-infra#3882). When the clamp fires it is its
   own line, `census-mismatch launcher=34 pi=9 clamped=9 disp=0`, so the drift is visible without reading
   code (`pi=` is the whole box's lane **roots**, not the launcher's share; `disp=` is the overlap
   removed). ⛔ `pi=` counts lane ROOTS, not lane-shaped processes: every lane this box runs contributes
   the `bash …/lane.sh` wrapper **and** the `pi` it execs, so only a lane process whose PARENT is not
   itself a lane process is counted — otherwise the reading is ~2× the lane count and the tick stands a
   10-lane cell down at 18 with a slot free (agent-infra#3886 review round 4; the same over-count
   direction the overlap subtraction below exists to remove, at twice the size). ⛔ The two halves are **disjoint**: the process count covers the dispatcher's own
   `bash …/nonblocking-dispatch.sh` subshells too, so `alive = dispatcher + launcher` is only a lane
   count because the launcher clamp subtracts the overlap — an unsubtracted sum counted every live
   dispatcher lane twice and stood a 10-lane cell down at 11 with a slot free (agent-infra#3886). The
   overlap is the INTERSECTION of the two halves and is measured with the predicate that actually counted
   the lane (`_counts_as_lane`, the narrower one): measured with the broader rule, a lane the dispatcher
   half rejected was subtracted from the launcher's share and added to neither — one live lane read as
   none. A dispatcher lane's own root is the dispatcher's half, so it is removed from the launcher's via
   that overlap; the child rule above is what keeps a lane's `pi` from adding a second lane anywhere.
   ⛔ When the **process** count is unreadable the clamp does **not** apply and `wt_count` stands
   unchanged: the fleet's polarity is *unknown is alive*, and the census is the only thing bounding the
   lane total, so an unreadable probe must never read as "no lanes" (that is the over-dispatch
   direction; it dispatched 7 lanes in the suite's mutant of exactly that change). "Unreadable" means
   `ps` **failed**, exited 0 having printed **no output at all**, or answered with something that is not
   a process table — the probe reads `ps -A -o pid=,ppid=,command=` and requires pid-prefixed rows, so
   usage/error text written to stdout (a real `ps` failure shape) reads UNREADABLE, not "no lanes". A
   table that IS a process table and contains no lane in it reads **0**, which is the direction this fix
   exists for.
   ⛔ The clamp is one-sided in the sense that it cannot **invent** a lane, but it **can lower a real
   count**, and that is the deliberate price of the fix: a probe that answers with a view omitting the
   lanes (`hidepid=2` for another uid, a PID namespace, a filtered `$PS` wrapper) reads 0 and the clamp
   then lowers a real count — the over-dispatch direction. The alternative, treating every answered
   probe as unreadable, restores the original bug.
4. **rotation advances per LANE, not per tick.** Each dispatched lane gets its own slice offset and its
   own brief; the cursor advances inside the loop (a tick killed mid-loop must not re-issue the slices
   it already handed out), and the count is clamped to `SLICE_TOTAL/SLICE_WIDTH` distinct windows so a
   large target can never put two lanes on the same PRs — **including across ticks**: a lane keeps its
   window for up to `LANE_TIMEOUT`, so the windows LIVE lanes hold are read from their records and
   skipped, and a tick whose ring is fully held dispatches nothing and says so. ⛔ Consequence an
   operator must know: the achievable concurrency is `min(target, distinct windows)`. At the shipped
   `SLICE_TOTAL=70` / `SLICE_WIDTH=10` that is **7** lanes, so a box whose memory would carry 12 tops up
   to 7 until it dies down. Widen the ring (`SLICE_WIDTH=5` on the same list is 14 windows) if the ring,
   rather than the box, is what binds.
5. **single instance — and the lock's scope is the TICK, not the LANE.** ⛔ This is the correction of
   #2639, which held the lock for the *lane's* lifetime because "the dispatcher returns immediately, so
   releasing here would let the next tick start a SECOND lane while the first still runs". That
   conflated two questions. *May two ticks compute `target − alive` at the same time?* **No** — each
   would dispatch the full remainder. That is what the lock is for, and it covers **one tick's critical
   section** (settle → census → target → dispatch), ending when the dispatch work ends. *May another
   lane exist beside this one?* **Yes**, up to the target — and the **census** answers it, so it needs
   no lock: the next tick counts the lane in `alive` and dispatches only the remainder. **The count is
   the guard.** Holding the lock for a lane's lifetime is precisely what let a 20-minute tick dispatch
   once an hour on a 34-PR backlog.

Two more properties are part of the same contract, because each is a way for a tick to look successful
while nothing happened:

- **the lane's exit status is the verdict — read by the NEXT tick.** The tick never waits for a lane,
  so each dispatch records `$AI/state/lanes/<name>.pid`; a later tick settles every record whose pid is
  dead: `DONE` for rc=0, `FAIL` for a non-zero rc, `FAIL` for a lane that vanished with no status and
  no dispatcher capable of writing one, `WARN` (not a failure) where the dispatcher records no `.rc` at
  all — `bg-dispatch.sh`, the first preference and the dispatcher in use on the box tonight, writes
  none. A record is deleted once settled, so a lane is reported exactly once. An unreadable lane
  pidfile at dispatch time is a **failure**, not a zero-length wait: a lane whose liveness can never be
  established is a lane that can never be counted or reaped.
- **the beat is written by every tick that ran**, including a skip — a skip is the normal steady state,
  and a beat written only after a dispatch would make a correctly-idle job read `LATE` for ever.
- **a worktree is removed only when nothing is still working in it.** A signal to the TICK says nothing
  about the lanes (a `bootout`, a reboot, a Ctrl-C on a hand-run copy), and the tick backgrounds them
  before it returns — so the normal path is *leave*, and the next tick's settle removes the tree.
  ⛔ **A DEAD PIDFILE IS NOT A DEAD LANE** (agent-infra#2787, MEASURED 2026-10-25): a tick removed a
  lane's checkout TWO MINUTES after launching it into a `cap=3000s` lane, and the worker kept running
  with `getcwd: cannot access parent directories`. The recorded pid
  (`$AI/state/lanes/<name>.pid`, and `<wt>.lane-pid` beside the tree) is whatever process the
  DISPATCHER chose to name — a fact about that process, never about the lane — so removal now needs the
  reaper's own proof first, exactly as `scripts/pi-reap-worktrees.sh` requires for its own reclaim:
  * a process whose **argv names the checkout**, or whose **cwd is inside it** (`wt_live_holders`, from
    `wt-lifecycle.sh` — resolved `$O` first, then beside the drainer, and a missing/stale module is
    *named*, never read as "no holders");
  * plus a `/proc/<pid>/cwd` witness where `/proc` exists. This is not redundant: a real holder is a
    `pi -p … <brief>` lane whose argv never names the checkout, which only the cwd witness sees — and a
    cell without `lsof` installs one witness fewer.

  A tree that is still held is **kept**, and the lane is **not settled**: the tick logs
  `KEEP: … (pid N) still holds it`, the record stands (so the verdict is still reported exactly once,
  when the lane truly ends) and a later tick retries. A probe that **cannot be evaluated** keeps the
  tree too — an unproven removal is the one thing this pass may not do. The same verdict is reused
  rather than re-derived: those lanes count as **live** in the census (`held=N(pid-gone-checkout-held)`,
  its own named instrument beside `dispatcher=`/`launcher=`) and keep their slice window, so a second
  lane cannot be dispatched onto the same PRs. A tree with **no** sidecar is UNKNOWN and left alone.
  A fresh checkout per lane with nothing removing it is ~72/day on a box that has been disk-bound, so
  the reaper is not optional — and a reaper that guesses is worse than none.
- **the seed is a tick precondition, proven before the first lane.** `SEED_REPO` is checked once
  (`git rev-parse --git-dir`, then the `SEED_REF`), and a missing seed or ref refuses the tick **before**
  any brief, worktree, sidecar or record exists — so nothing is half-dispatched. The incident's tick
  both destroyed a live checkout and could not rebuild one, from a seed that was simply gone. The
  per-lane check remains: the seed can vanish between that line and the Nth lane, which is a race and a
  different fact.

`ai-drainer.test.sh` drives the shipped script against all of it, and every arm that matters is
asserted against a **mutation**: the top-up loop is re-run with `n=1` injected (`one lane per tick`, the
#2639 shape) and arm (a) — 0 alive + target 3 → 3 lanes — MUST fail there, or its three lanes are
proving nothing; the lock is re-run with the lock block deleted and two ticks must then BOTH dispatch.
A second lock arm drives the *reclaim* path directly (three ticks racing over one STALE lock dispatch
from exactly one), which is the arm that catches a non-atomic reclaim. The capacity formula is
asserted on injected probes (cpu binds / memory binds / load refuses / **no swap still dispatches** /
the **swap arm per platform** — the measured `412MB/3072MB` reading REFUSES on Linux and DISPATCHES on
Darwin at normal pressure while critical pressure refuses there too, and the threshold's own two bad
ends, `9` and the never-open `1`, are both rejected loudly / an unreadable probe fails closed), the
census is asserted against a stubbed launcher module and against
an unreadable `ps` (unknown is ALIVE), the generated brief is piped through the dispatcher's own
`brief-gate.sh` (plus a non-vacuity arm in which the stripped brief MUST be refused), a lane's window is
never re-issued while it is live (paired with a mutation that ignores the held set and must then
re-issue it), an aborted launcher table fails the tick instead of reading as zero workers, and a settled
lane's failure survives an at-target SKIP.

Arm (i2) is the #2787 register: a live worker whose cwd is in the checkout, with a **dead** recorded pid.
The tick must keep the tree, keep the record, count the lane (`held=1`), keep its window, and reclaim it
once the holder exits — and the arm carries its own non-vacuity twin in which the holder gate is deleted
from a copy of the script, where the live worker's checkout MUST be removed. Arm (i3) pins the
fail-closed direction (both witnesses unavailable keeps the tree and names the gap; a stale
`wt-lifecycle.sh` on a Linux box is not a permanent block, because the `/proc` witness still answers).

## Activate on macOS

```bash
# 1. the drainer (per repo, one box): where it dispatches, and where its own state lives
AI_DRAINER_O=$HOME/orchestrator AI_DRAINER_STATE=$HOME/orchestrator-ai \
  bash scripts/install-launchd.sh           # renders + bootstraps com.eldato.ai-drainer

# 2. the second controller: render the job, then create its identity ONCE
AI_MULTI_REPO_SLUG=daniel-ospina/agent-infra \
AI_MULTI_REPO_REPO=$HOME/agent-infra-main \
AI_MULTI_REPO_STATE=$HOME/orchestrator-ai \
  bash scripts/install-launchd.sh           # renders com.eldato.ai-multi-repo

OR=daniel-ospina/agent-infra REPO=$HOME/agent-infra-main O=$HOME/orchestrator-ai \
  HARNESS_PIN=$HOME/orchestrator-ai/state/HARNESS-PIN \
  bash scripts/orchestrator-harness/multi-repo-controller.sh --init     # state dir + own pin
launchctl kickstart gui/$(id -u)/com.eldato.ai-multi-repo                 # start it once
```

`install-launchd.sh --status` lists both jobs with their drift; `install-launchd.sh --uninstall`
boots them out. The installer never creates the state dir — `--init` is the one deliberate step that
does, and the launcher REFUSES to run without it.

## Activate on a cell

A cell has no launchd. **The choice: systemd, by the same installer pattern the disk reaper already
uses** (`scripts/install-disk-reaper-timer.sh` renders `templates/systemd/*` and
`systemctl enable --now`s them). It is NOT a fifth role of the cell doctor loop, for two reasons: a role
is ONE cell's controller and the backlog the drainer exists for may belong to a repo that controller is
not bound to; and the fleet already schedules a periodic one-shot this way. ⛔ The reason this section
used to give is **withdrawn**: "the drainer's lock must outlive its own pass (it waits up to
`LANE_TIMEOUT` for the lane it dispatched), so a role would block the loop for ~50 minutes" described
#2639's lock scope. The tick no longer waits for a lane — its critical section ends when dispatching
ends — so the drainer is not a long pass any more. The timer is kept because the *role/ownership*
reasons stand, not because the pass blocks.

```bash
# on the cell — user unit if a user manager answers, system unit with passwordless sudo otherwise
DRAINER_O=$HOME/orchestrator DRAINER_STATE=$HOME/orchestrator-ai \
  DRAINER_REPO_SLUG=daniel-ospina/agent-infra DRAINER_SEED_REPO=$HOME/agent-infra-main \
  bash scripts/orchestrator-harness/install-drainer-timer.sh          # --dry-run to preview
bash scripts/orchestrator-harness/install-drainer-timer.sh --status   # installed? active? next run?
```

The timer is `OnUnitActiveSec=20min` (not `OnCalendar`) so the next tick is a fixed distance from the
last real attempt instead of bunching skipped ticks. The installer **aborts** on
every failed pre-flight (a rendered unit is rejected if it is empty, has no `ExecStart`, or keeps a
`{{placeholder}}`), reads the timer's `is-active` back after enabling it, and refuses a **user** unit
whose manager will not linger — a user timer that stops with the last ssh session is an installed job
that schedules nothing. `cloud-cell-bringup.sh` does **not** install it: a lane dispatcher is per-repo
and costs model spend, so it is an explicit, per-cell operator step — the same shape as the disk
reaper's arming.

The second controller on a cell is the cell supervisor's business (`cloud-cell-supervisor.sh start`
with `OR`/`O` for that repo); it needs no timer at all, and its inventory row says so
(`no launchctl` → SKIPPED on a cell) rather than pretending to check a launchd job. ⛔ That split is
ENFORCED, not described: the plist carries `FleetResident`, so `fleet-schedule.py` reports it as a
named SKIP on a cell even when an operator sets its three identity values there — the alternative was
the tick loop starting it and killing it at `FLEET_SCHEDULE_JOB_TIMEOUT`, every ceiling.

## Verify

```bash
bash scripts/orchestrator-bringup.sh status
```

Two rows matter, and both are calibrated against the failure they exist for:

| row | OK means | the state that is NOT OK |
|---|---|---|
| `ai-drainer` | job loaded, last exit 0, its own **beat** fresh within 2×1200s | `LATE` = installed and not running (nothing dispatches, nothing goes red); `MISSING` = the code is present and no job installs it |
| `second-controller` | job loaded, ONE `orch-loop.sh` for its own state dir, heartbeat fresh | `MISSING` = loaded with nothing cycling, or a controller identity with no job (hand-run, ends at reboot); `DUPLICATE` = two controllers on one dir |

Two details of that row are deliberate. Its state dir comes from the **job's own `O`**, not from the
seam (an operator who activated it elsewhere would otherwise be judged against a directory the job
does not use); and "a second controller was set up here" is evidenced by the `--init` artefact
(`state/HARNESS-PIN`), **not** by the directory existing — `$HOME/orchestrator-ai` is also the
drainer's default state dir, so the weaker test turned activating *only the drainer* into a red row
instructing the operator to install a second controller.

The drainer's freshness file is `$AI/state/ai-drainer.beat`, written as soon as the tick owns the lock
— including on every path that then skips — not its log, because the normal steady state on a full or
swap-bound box is a skip, and a beat written only after a dispatch would read `LATE` for ever. That is also why the plist declares **no**
`StandardOutPath`: the inventory prefers a plist's capture path over the row's own file, and this
script writes nothing to stdout on any normal path, so declaring one would date an untouched file and
mark a healthy drainer `LATE` for ever.

## Known remaining gap (owned elsewhere)

The second controller does see the backlog — 72 rows — but **spawns nothing**, with the reason
`no per-PR read this cycle (the open-PR listing w…)`. The drainer is what keeps work moving until that
funnel is fixed; it is not a fix for it.
