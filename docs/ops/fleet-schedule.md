---
title: "The fleet's scheduled layer — one declaration, a portable runtime (#1864)"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-10-17
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-1864, scheduled-layer, launchd, cloud-cell, reapers
---

# The fleet's scheduled layer — one declaration, a portable runtime (#1864)

Every recurring job in this repo is declared **once**, as a plist under
`templates/launchd/`. This doc says how that declaration reaches a machine that has no launchd,
where the runtime lives, and how "scheduled" is checked rather than believed.

## The defect this closes, in numbers

Measured 2026-10-16 across the fleet:

| | local Mac | cell-1 | cell-2 | cell-3 |
|---|---|---|---|---|
| scheduled fleet jobs | 24 | 0 | 0 | 0 |
| reap scripts present | 4 | 0 | 0 | 0 |
| heartbeat | running | DEAD | DEAD | DEAD |

The ten job templates existed, the Mac ran them, and the cells received **none of it** — not
because a fix was lost, but because `scripts/install-launchd.sh` needs launchd
(`~/Library/LaunchAgents`, `launchctl bootstrap`, `gui/<uid>`) and a Linux cell has neither.
Nothing announced the gap, because the instrument that would have announced it (the liveness
job) was itself one of the missing jobs.

## The mechanism, decided once

**A supervised in-session loop — `scripts/fleet-schedule.py` — which READS THE SAME PLISTS.**

Not cron and not systemd timers, on measured evidence from a cmux cloud cell
(Ubuntu 24.04, uid 1000 `cmux`, `HOME=/tmp/cell-home`), 2026-10-17:

```
command -v crontab        → absent (the `cron` package is not installed)
systemctl --user status   → "Failed to connect to bus: No medium found"
                            (no user bus, no lingering) — while systemd IS pid 1 in SYSTEM mode
```

A crontab entry or an enabled user timer would therefore be installed-and-inert, which is exactly
the false PASS this issue is about. A system-scope timer would work but needs root on every cell
and writes machine state outside the repo. The one surface a cell is guaranteed to have is the one
it already runs lanes on: tmux. So the schedule lives in a loop under the cell's own lifetime.

**No second copy of the logic.** The runtime parses `templates/launchd/*.plist`
(`Label`, `ProgramArguments`, `EnvironmentVariables`, `StartInterval`/`StartCalendarInterval`,
`StandardOutPath`/`StandardErrorPath`) and renders the same `{{PLACEHOLDER}}` set as
`install-launchd.sh`. A placeholder it does not know is a **loud refusal**, never an empty
argument.

⛔ **The two placeholder lists ARE the contract, and they drifted once — at the cost of a whole
cell** (agent-infra#2908, and #2804 for the placeholder half, measured 2026-10-27 on
`vm-ce2c2fc9fd844a32851d46c3723b903e`). #2639 added
`{{AI_DRAINER_O}}` / `{{AI_DRAINER_STATE}}` (and the three `AI_MULTI_REPO_*`) to
`install-launchd.sh` only, where an unset value is the designed **SKIP**; the runtime's
`PLACEHOLDERS` tuple did not know them, where the same template is a hard **ERROR**. cell4's
`systemctl start eldato-orchestrator` then came up `active (activating)` with `MainPID=0`: the
runtime refused the whole set, so the cell ran **no controller, no reaping, no liveness detection
and no canary**. The refusal is correct — the *input* was wrong.

So: `install-launchd.sh` declares the names once (`PLIST_PLACEHOLDERS`) and both `render()` and its
unset-placeholder check read that one array; `scripts/fleet-schedule.py` holds the tuple (it is
farmed to cells as a SINGLE file, so it cannot read a sibling manifest); and
`scripts/fleet-schedule.test.sh` **compares three lists** — the installer's array, the runtime's
tuple, and the `{{NAME}}` tokens actually present in `templates/launchd/*.plist` — with floors so a
truncated parse cannot read as agreement, and a **mutation arm** that removes `AI_DRAINER_O` from a
copy of the tuple and requires the comparison to REDDEN. Add a name in both files, or the suite
fails.

**Two declaration shapes the tick loop cannot run, both NAMED skips:**

- an **unset identity placeholder** (`{{AI_DRAINER_O}}`, `{{AI_MULTI_REPO_SLUG}}`, …) — env-only with
  no default on purpose: a default would put a lane dispatcher and a second controller on every box
  in the fleet;
- a **RESIDENT body** — a declaration that the job is a long-lived service. launchd supervises it and
  restarts it; the loop supervises nothing, so it would start the process and kill it at
  `FLEET_SCHEDULE_JOB_TIMEOUT` — a restart every ceiling, not a service. It is a valid declaration,
  so it is a skip rather than an error: refusing the entire layer over it is what went dark above.
  A resident job on a cell belongs to the cell's own supervisor, not to this loop. Which keys declare
  it, and why residency is DECIDED BEFORE the schedule:

  | key | when it means "resident" |
  |---|---|
  | `KeepAlive` | `<true/>`, or a non-empty condition DICT (`{"SuccessfulExit": false}`, `{"Crashed": true}`, `PathState`, `NetworkState`, `OtherJobEnabled`) — launchd documents both forms and the runtime reads both, plus the integer `1` a round-tripped plist carries. An EMPTY dict declares no condition and is not a resident declaration. **A `KeepAlive` job is a skip whether or not it also carries a schedule:** a schedule must not mask the declaration, or a resident body with `StartInterval` becomes a job started and killed every ceiling. |
  | `FleetResident` | this runtime's own key (launchd ignores keys it does not know), for a resident body that **must** keep its schedule — `com.eldato.ai-multi-repo` is the one: the 900 s top-up is correct on the Mac, and the same plist is a named SKIP on a cell, even with its identity set. |
  | `RunAtLoad` | **only when the template has no schedule at all** (`com.eldato.worker-supply`): then the load start is the only thing that ever starts it. With an interval it means "also run once at load" on a bounded pass (`com.tortoise.ci-runner-gate` here, and the `reaper/` + `harness-apply/` templates another installer reads), so reading it as residency would silently take those jobs off every cell. |

  A template with **neither** a schedule nor a resident declaration is still a hard **ERROR** — on
  launchd that shape loads silently and never runs, which is the original defect (#1864). `FleetResident`
  alone does not rescue it: nothing would ever start the job, on either backend.

## Lifecycle

| where | what happens |
|---|---|
| `pi-bootstrap/setup.sh` (`fleet_srcs`) | farms `fleet-schedule.py` to `$DEST/scripts/` on every box |
| `pi-bootstrap/cell-install.sh --install/--verify` | byte-verifies that farmed copy, like every other farmed script |
| `cloud-cell-bringup.sh --check` | `check_schedule()`: `--install` (converge + run the due jobs now + verify). **Fatal** — a cell is not `CELL READY` on an unproven schedule |
| `cloud-cell-supervisor.sh start` | `scheduler_ensure()`: `--start` (idempotent). A loop that died while the controller lived is brought back by the cell's own start |
| macOS | every subcommand delegates to `scripts/install-launchd.sh`. There is no second scheduler on the Mac |

State lives in `$HOME/.pi/agent/state/fleet-schedule/`:

```
loop.pid              the loop process (its COMMAND LINE is checked, not just the pid)
tick                  epoch of the last completed pass
OFF                   kill switch: the loop exits while it exists. `--start` removes it;
                      `--install` REFUSES rather than silently reversing a decision
templates-dir         where the declarations were installed from (so a later `--start` finds the same set)
loop.log              every run, skip, timeout and error
jobs/<label>.json     per-job run stamp: {started, finished, rc, duration}
logs/<label>.log      default job log when the plist declares no StandardOutPath
locks/<label>.lock    per-job lock (a dead holder is stolen; a live one is respected)
```

## Reading the per-machine truth

```bash
python3 ~/.pi/agent/scripts/fleet-schedule.py --status
```

```
fleet-schedule — surface=linux templates=/tmp/cell/agent-infra/templates/launchd
  loop=running(pid=4183) last_tick=12s ago jobs=10
  ok     com.eldato.pi-session-reaper        every 1h    last=3m ago rc=0 next=in 57m log=…
  ok     com.eldato.lane-liveness            every 30m   last=3m ago rc=0 next=in 27m log=…
  SKIP   com.tortoise.worktree-reaper        every 6h    unresolved placeholder(s) {{TORTOISE_REPO}} — absent on this machine
```

A job is **either** `ok` (with a last run, its rc and its next due time), **or** `SKIP` with the
reason it cannot run here, **or** `ERROR` with what is broken about the declaration. There is no
fourth state and no silent absence: this table is what makes "deployed" checkable.

`--verify` is the gate. It fails on:

- no loop, or a `loop.pid` whose pid is **not** `fleet-schedule --loop` (a recycled pid must not
  read as a running scheduler — and `--start` REPLACES such a pid rather than reporting it);
- a tick older than `max(3 × tick, 300 s)` while **no job is running** (the process exists but is
  not passing). A job that is running announces itself in `state/busy/<label>.json` with an
  expiring deadline, so a job the templates budget 1800 s for is reported `BUSY`, not `stale` —
  and the exemption ends with that deadline, so a job killed at its ceiling cannot mask a wedge.
  That deadline is **self-declared**, so it is clamped to `started + JOB_TIMEOUT + 3 × tick`: a
  marker written under a larger budget (or left by a loop that later ran with one) cannot excuse a
  wedged tick for longer than the ceiling this verifier would itself have enforced. A marker with no
  usable `started` is **dropped** rather than trusted, because an exemption that cannot be dated
  cannot expire;
- a job that is declared and runnable here but has **never run**;
- a job whose calendar can **never** come due again (no occurrence found within the search window
  — a `Month`/`Day` calendar searches 400 days, including the entries of a multi-entry
  `StartCalendarInterval` array);
- an **empty** declarations dir: a schedule with ZERO jobs is refused (exit 1), never certified as
  `0 job(s) live` — and the same is true, by a longer route, when **every** declared job is a
  named `SKIP`. A host where nothing is live runs no reaper, no liveness report and no canary
  whatever the reason, so `NOT ONE is live` is a refusal, not a verified schedule. Skips are
  non-fatal only while **at least one** job is live;
- a job **overdue** by more than `max(2 × its interval, 3 × tick)` while **no job is running** (the
  loop is alive and is not running it — e.g. its lock is held by a hung run). The busy exemption
  is the same one the tick arm uses, so a calendar job that comes due while a long job is executing
  is reported `BUSY`, not `OVERDUE`: the loop is single-threaded, and a busy loop is a late loop;
- a template with no schedule at all, an unknown placeholder, a `Label` that is not a safe file
  name (it names that job's stamp, lock and default log, so only letters, digits, `.`, `_` and `-`
  are accepted), a target **under `<home>/.pi/agent/`** that does not resolve (an incomplete
  farm), an `argv[0]` that **exists but is not executable** (a target that lost its `+x` bit, or
  whose shebang interpreter is gone, fails every run with `rc=127` and would otherwise be stamped
  as a live job), or a label that is in `RETIRED` while its template still exists. Only `argv[0]`
  is held to the execute bit — the remaining arguments are data, and a plist may legitimately point
  one at a non-executable file. Like a missing target, the execute-bit refusal follows the layer
  split: inside `<home>/.pi/agent/` it is fatal (that farm is ours to install), anywhere else it is
  a named `SKIP` — a tortoise `.venv` that lost its mode bits must not refuse `CELL READY` on every
  cell any more than an absent one does. A target missing **anywhere else** — a tortoise checkout
  without its `.venv` — is a named `SKIP`, not a failure.
  On macOS the whole gate is the delegate's: `install-launchd.sh --status` must exit **0** AND
  print no `NOT INSTALLED`/`DRIFTED`/`not loaded` line (`--verify` reads its exit status too, so
  a delegate failure with unfamiliar wording is not certified green).

A `SKIP` is reported and counted, not fatal: no tortoise checkout is a legitimate per-machine
absence, and refusing the whole layer over it would block a cell that runs every other job. The
verdict line says both numbers — `SCHEDULE VERIFIED — N job(s) live on this machine …, M skipped
for a named reason`. It is only printed when `N ≥ 1`.

A stamp records a **completed** run. Two shapes are therefore NOT evidence, and `--verify` refuses
both rather than counting them:

- a job interrupted by `--stop` (the loop's `SIGTERM` handler raises `SystemExit` through
  `run_job`) writes **no** stamp, so it keeps its previous real stamp — or stays honestly
  `NEVER RUN` — instead of certifying itself with an `rc` of `null`;
- a job the runtime could not even **execute** (the spawn raised `OSError`, e.g. a target without
  its execute bit) writes no stamp either and is logged as `NOT-RUN`, never `RAN rc=127`.

A stamp already on disk whose `rc` is `null` — written by an older copy of this runtime, or by the
old exec-failure path — is read back as `NEVER RUN` for the same reason. A stamp whose `started` is
in the **future** fails too: `due_at` is `last + interval`, so a clock that stepped back (a resumed
VM, an NTP correction of a fast RTC) or a state dir restored from a skewed box would leave that job
not-due for ever while a stamp made it look live. `--verify` names it and prints the stamp path to
clear.

`--start` reads the declarations before it spawns. No declarations at all, a remembered
`templates-dir` that no longer resolves, and a dir holding no `*.plist` all exit **3** (the code
`cloud-cell-supervisor.sh start` keys on to warn rather than die), so `start` can never report a
running loop over a schedule it could not read. A job set the runtime cannot run in full (a broken
target inside the layer) is exit **1** there too.

## Commands

```bash
python3 scripts/fleet-schedule.py --check     # DECLARATIONS only: exit 1 if this runtime cannot run the shipped set
python3 scripts/fleet-schedule.py --install   # converge, run the due jobs NOW, start the loop, verify
python3 scripts/fleet-schedule.py --status    # the table above
python3 scripts/fleet-schedule.py --verify    # exit 1 on any arm above
python3 scripts/fleet-schedule.py --start     # idempotent; clears the OFF switch, replaces a recycled pid
python3 scripts/fleet-schedule.py --stop      # OFF switch + SIGTERM (creates the state dir if needed)
```

**`--check` runs on EVERY platform, including macOS** — deliberately *before* the launchd delegation
that every other verb takes. It is the only verb that grades the shipped declaration set on the
machine that authors it (a Mac), needs no loop, no state and no lock, and does not grade target
EXISTENCE: whether `<home>/.pi/agent/scripts` is farmed is a fact about the host, graded by
`--install`/`--verify`, and grading it in CI (where no farm exists) would refuse a good template
set. It prints the same `ERROR`/`SKIP`/`ok` table and ends with `DECLARATIONS OK — …` or
`DECLARATIONS BROKEN — …`; a set that is entirely skips is refused as `DECLARATIONS INERT`.

⛔ **Why it exists: the previous guard was blind, so a broken set reached main green.** The old
assertion in `scripts/fleet-schedule.test.sh` grepped `--status` output for the runtime's own
"does not know" wording — on macOS `--status` delegates to `install-launchd.sh`, which has no notion
of that contract, so the check was structurally vacuous on the machine where templates are written;
and the suite was **not in the shard list at all** when the drift landed (the list was hand-
enumerated then: `git show 427f64950:scripts/run-bash-shards.sh | grep fleet-schedule` → nothing,
while the 21,778-line `script-validate` log of that very commit never mentions the suite). The list
is DERIVED now, so the suite runs; the assertion is a verdict on the parsed declarations, so it can
fail.

### The staged copy — why a checkout fix does not reach a running cell

A cell does **not** run this file from the checkout. The supervisor executes
`$CELL_HOME/.pi/agent/scripts/fleet-schedule.py`, farmed there by `pi-bootstrap/setup.sh`
(`fleet_srcs`) and byte-verified by `pi-bootstrap/cell-install.sh --verify`. So the refresh path is
that one installer — there is no second one. What was missing was the scheduler SAYING so:

- `--check` prints a `DRIFT` line when the file it is running is outside the checkout and differs
  from `<INFRA_ROOT>/scripts/fleet-schedule.py` (never fatal — a Mac's farmed copy legitimately lags
  a working tree);
- `--verify` counts it as a **failure**, because a cell certifying a layer while running a copy that
  is not the checkout's is precisely the state in which "I fixed it and it did not take" is true.

Measured cause: a checkout fix for the placeholder drift did nothing on a running cell until the
farm was refreshed. Refresh with
`bash <checkout>/pi-bootstrap/cell-install.sh --install`, then `fleet-schedule.py --verify`.

`FLEET_SCHEDULE_TICK` (60 s), `FLEET_SCHEDULE_JOB_TIMEOUT` (1800 s), `FLEET_SCHEDULE_STATE`,
`TEMPLATES_DIR`, `INFRA_ROOT` override the defaults. A killed job is stamped `rc=124` and logged —
a hung job must never wedge the loop. One malformed declaration cannot stop the loop either: it is
reported by name and the pass continues with the rest of the set (`--install`/`--verify` refuse,
which is where a broken set must be caught).

Exit codes: `0` ok · `1` a broken job set or a schedule that did not verify · **`3` no job
declarations found** (nothing to read and no remembered pointer). 3 is distinct on purpose: the
cell's own start path warns on it rather than taking the controller down over a layer that bring-up
installs, while `1` is fatal there.

## Boundaries, stated rather than discovered

- **The loop lives as long as the cell's scheduler process.** Stop the cell and the reapers stop;
  the next `start`/`--install` runs the first pass for everything that has gone due, so a stopped
  cell catches up. Deliberate: a stopped cell runs no lanes, so there is nothing to reap.
- **The first pass at install is the proof** and costs one run of each due job (a fresh cell runs
  all ten). That is the trade for asserting a run instead of a loaded unit. A re-run is a no-op.
- **The worktree and branch reapers need a tortoise checkout** (`{{TORTOISE_REPO}}` + its venv) and
  report `SKIP` on a cell without one. Installing one is a cell-provisioning question, not this
  layer's.
- **The heartbeat is NOT in this layer.** `orchestrator-heartbeat.sh` drives `cmux`, which a cell
  has no access to; what a cell-side heartbeat should be is an owner decision and is still open.
  What this layer does deliver is the instrument gap that made the silence undetectable here: the
  liveness job's run stamp and log are now present on a cell.
- **Checkout freshness is not this layer's** (`#1760`): the loop reads the declarations from the
  checkout it was installed from, exactly as the Mac reads `$AGENT_INFRA_PATH`. A stale checkout
  schedules a stale set — visibly, since `--status` prints the path it read.
