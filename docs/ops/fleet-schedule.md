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
argument — that is the one place the two renderers could drift, so it fails closed.

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
  read as a running scheduler);
- a tick older than `max(3 × tick, 300 s)` (the process exists but is not passing);
- a job that is declared and runnable here but has **never run**;
- a job **overdue** by more than `max(2 × its interval, 3 × tick)` (the loop is alive and is not
  running it — e.g. its lock is held by a hung run);
- a template with no schedule at all, an unknown placeholder, a target **under
  `<home>/.pi/agent/`** that does not resolve (an incomplete farm), or a label that is in
  `RETIRED` while its template still exists. A target missing **anywhere else** — a tortoise
  checkout without its `.venv` — is a named `SKIP`, not a failure.

A `SKIP` is reported and counted, not fatal: no tortoise checkout is a legitimate per-machine
absence, and refusing the whole layer over it would block a cell that runs every other job. The
verdict line says both numbers — `SCHEDULE VERIFIED — N job(s) live on this machine …, M skipped
for a named reason`.

## Commands

```bash
python3 scripts/fleet-schedule.py --install   # converge, run the due jobs NOW, start the loop, verify
python3 scripts/fleet-schedule.py --status    # the table above
python3 scripts/fleet-schedule.py --verify    # exit 1 on any arm above
python3 scripts/fleet-schedule.py --start     # idempotent; clears the OFF switch
python3 scripts/fleet-schedule.py --stop      # OFF switch + SIGTERM
```

`FLEET_SCHEDULE_TICK` (60 s), `FLEET_SCHEDULE_JOB_TIMEOUT` (1800 s), `FLEET_SCHEDULE_STATE`,
`TEMPLATES_DIR`, `INFRA_ROOT` override the defaults. A killed job is stamped `rc=124` and logged —
a hung job must never wedge the loop.

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
