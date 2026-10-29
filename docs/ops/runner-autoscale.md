---
title: "Runner pool autoscale — the converger on a clock (#2403)"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-10-29
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-2403, runner-autoscale, ci-runner-pool, systemd, launchd
---

# Runner pool autoscale (#2403)

One converger — `scripts/orchestrator-harness/runner_autoscale.py` — that measures a box, derives
its runner ceiling, and converges the local pool to it. It landed in #2877/#2900, fully reviewed
and tested, and **nothing ran it**: no unit, no timer, no installer reference. The file's own
header says so (`LANDING THIS FILE DOES NOT DEPLOY IT`). This page is the activation.

| platform | scheduled artifact | cadence | installer |
|---|---|---|---|
| Linux cell | `templates/systemd/eldato-runner-autoscale.service` + `.timer` | `OnUnitActiveSec=9min`, `OnBootSec=2min` | `scripts/install-runner-autoscale-timer.sh` |
| macOS | `templates/launchd/runner-autoscale/com.eldato.runner-autoscale.plist` | `StartInterval=540` (+ one at load) | the same installer |

## Why it exists

Owner ruling agent-infra#2344: fill every machine to **sustainable** capacity — 3 runners on
cell-1, 3 on cell-4, 2 on cell-3. The converger is what derives that number per box
(`ceiling()` = the strictest of cores, free memory and disk). Nothing scheduled it, so a box kept
whatever count it happened to have. Measured on pi-cell-1 (8 cores) before this change:

```
ncpu=8 mem_available_mb=8596 running=5 ceiling=3   → verdict=over-ceiling
tortoise queue at the same moment: 34 waiting runs, 1 in progress, no landing for 13h
```

2.3x the ceiling is the same failure at the other end as an empty box: the box is thrashing
between runners it cannot feed, and the queue waits anyway.

## What the pass will and will not do

The converger is **not** a killer. Per-runner classification is ordered so that nothing which may
be serving is ever touched (`OTHER-REPO` → `BUSY` → `ORPHANED` → `SERVING` → `DEAD`), and
`over-ceiling` is a **reported verdict**, never a removal:

> · over-ceiling: 5 live against a measured ceiling of 3 — … ; nothing removed (a runner that may
> be serving is never removed)

So a box that is above the ceiling **converges as its runners go idle** (a `SERVING` runner is
removable, a `BUSY` one is not), and a box below it grows through the provisioner
(`tools/install-ci-runner-x64.sh`, pinned into the unit when present). Without a provisioner the
pass still repairs and re-registers, and reports `no provisioner` (exit 3) rather than pretending
it grew.

Exit codes are part of the contract (`runner_autoscale.py::main`): `0` a **capacity answer** —
converged, at-ceiling, under-target, **over-ceiling** (it measured the box and changed nothing it
could have changed); `1` refused; `2` unmeasurable (a pool or queue read failed); `3` action-failed /
guard-conflict — this is where **no provisioner** lands, on every pass with `live < target`; `4`
**starvation** (`queued>0`, every online runner idle — the alarm #2875 exists for). `4` is the one
exit that must page a human, and reading it as "over-ceiling" would treat a starved box as benign
capacity news. `provisioner-refused` is a `0` as well (the box answered the capacity question and
declined to grow), while `5` is reserved for `--check-units` findings — a verb this timer does not
run, so it never appears here. The unit carries **no** `SuccessExitStatus=` and no `-` prefix on `ExecStart`, so every
non-zero exit is a RED unit, not a green one.

## DISARMED by default — arming is a dated owner step

Two separate acts, deliberately:

1. `--install` renders the artifact in **dry-run** mode and enables the timer. Every tick measures
   and logs its plan; nothing is changed. `/etc/systemd/system/eldato-runner-autoscale.service`
   then carries `--dry-run` and the launchd plist carries the matching `<string>--dry-run</string>`.
2. `--arm --reason '<why>'` writes the arming record
   (`$HOME/.pi/agent/state/runner-autoscale.armed`: `armed-by`, `armed-date`, `armed-host`,
   `repo`, `ceiling`, `reading`, `reason`) and re-renders the artifact so the flag is **absent** —
   converging is the converger's default. The record must carry **both** `armed-by=` and
   `armed-date=`; half a record is treated as DISARMED.

`--arm` refuses unless it can run the pass's own `--status --json` and read a real `ceiling` out
of it, so a box that cannot measure can never be armed. `--disarm` removes the record and
re-renders; `--report-only` is the same neutral artifact but refuses while a record exists (it
would look disarmed and the next routine install would silently re-arm).

## Why the timer is not `fleet-schedule.py`

`docs/ops/fleet-schedule.md` keeps the fleet's recurring jobs in **one declaration**
(`templates/launchd/*.plist`, top level) read by `scripts/fleet-schedule.py`. This job is not in
it, for the same reason `templates/launchd/reaper/` and `templates/launchd/harness-apply/` are
not: those are the **installer-owned timer jobs**, each rendering its own placeholder set and
installing through its own script, and putting them in the top-level glob would ask
`install-launchd.sh` to render placeholders it does not carry. The subdirectory is the existing
convention, not a new one.

## Verified on this box, and what was not

Measured on **pi-cell-1** (Linux, 8 cores, systemd 255) on 2026-10-29:

| step | evidence |
|---|---|
| install | `installed: target=system dir=/etc/systemd/system changed=1`; timer `enabled`, `active` |
| schedule | `systemctl list-timers eldato-runner-autoscale.timer` → `NEXT … 15:54:44`, `LAST 15:45:44` |
| tick | `last_tick=at=2026-10-29T15:45:51Z verdict=over-ceiling ceiling=3 ncpu=8 mem_available_mb=8725 live=5` |
| ceiling derivation | `--status`: `by_cores=3 by_memory=9 by_disk=5 bound=cores ceiling=3` from `ncpu=8`, `mem_available_mb=8596` |
| arm | record written with `ceiling=3`, `reading=ncpu=8 mem_available_mb=8316 ceiling=3` |
| idempotence | a second `--install` printed `changed=1` only when the artifact was stale, kept the arming record, and left `drift_artifact=no` |
| hermetic suite | `scripts/install-runner-autoscale-timer.test.sh` — 107 assertions, `PASS=107 FAIL=0`; case-by-case below |

**Not verified here (no macOS host in this lane):** `launchctl bootstrap` on a real Mac, the
plist's `StartInterval` under `launchd`, and `gui/<uid>` behaviour on a logged-in GUI session. What
*is* verified on Linux is that the Darwin path renders, that the rendered plist **parses as XML**,
that its `ProgramArguments` resolve to files that exist, that its label is the reverse-DNS form of
the unit name, and that its interval equals the systemd one — the suite asserts all four (T12). The
`launchctl` verbs themselves are exercised against a shim, so a Mac operator should expect the
first `--install` to be the real test of that arm.

## The self-check, case by case

`scripts/install-runner-autoscale-timer.test.sh` — hermetic (a mktemp fixture root, stub scheduler
tools, a stub converger), 107 assertions, `PASS=107 FAIL=0`, no network, no real scheduler. What each
case pins, and why it exists:

| case | what it proves |
|---|---|
| T0 | the three artifacts exist and agree: the timer activates the service it is named after, and the service carries NO `WorkingDirectory=` directive |
| T1 | the unarmed default really renders `--dry-run`, and NOTHING an operator can export arms it |
| T2 | a record carrying BOTH `armed-by=` and `armed-date=` arms it; a HALF-written record does not (fail-closed) |
| T3 | no affirmative mode flag can be emitted at all — the armed artifact carries NO mode argument (a literal one made every tick exit 2 on pi-cell-1) |
| T4 | `--arm` preflights the converger and refuses a box it cannot measure, and refuses a record with no `ceiling` (arming on an unread number is arming blind) |
| T5 | a script inside a transient `mktemp` tree is refused — the measured inert enforcer: 127 on every tick while `list-timers` shows the job healthy |
| T6 | an interpreter older than 3.12 never reaches the artifact (the pass refuses itself at 3.12, so the unit would be red for a reason the installer already knew) |
| T7 | whitespace is refused on the systemd arm and allowed on the launchd arm — a plist `<string>` is not a whitespace-split field, so refusing there would be a false block |
| T8 | an unresolved `{{PLACEHOLDER}}` is refused and nothing is installed |
| T9 | `--status` on a box with nothing installed exits 1 (a success answer is the false PASS this family removes), and a hand-edited artifact is reported as drift |
| T10 | `--uninstall` verifies the files are gone and refuses when they are not |
| T11 | `--report-only` refuses while a record exists (it would look disarmed and the next routine install would silently re-arm) |
| T12 | the Darwin artifact renders, parses as XML, its `ProgramArguments` resolve to existing files, its label is the reverse-DNS form of the unit name, and its interval equals the systemd one |
| T13 | a second install of an unchanged tree changes nothing (bring-ups run this repeatedly) |
| T14 | an unpinned install resolves the repo's OWN converger, not a stub |
| T15 | `--disarm --dry-run` mutates NOTHING — the record survives and the artifact stays byte-identical (a preview that deletes the audit datum and leaves the pass converging is the one state the design forbids) |
| T16 | a FAILED armed re-render removes the record and says `NOT ARMED` — a record that outlives a failed `--arm` would silently re-arm the box on the next routine `--install` |
| T17 | `%` is refused on the systemd arm (systemd expands it as a specifier at load time, so the rendered path silently differs and every tick 203/EXECs) and allowed on the launchd arm (a plist `<string>` is not expanded) |
| T18 | `--status` exits 1 when the artifact's INTERPRETER is gone, reporting `python_present=no` while still reporting `installed=yes` — the two are different questions |

The case list lives here, not in the suite's header: the working-tree guard tokenises a script's
text, and a long prose header ahead of the code made it read the suite body as an unverifiable
heredoc and refuse to execute the suite at all (#709, measured twice). The suite is executable; the
documentation is documentation.

## Two bugs this lane found in itself (kept as evidence, not history)

- **`--apply` does not exist.** The converger has no `--apply`; converging is the default and
  `--dry-run` is the only switch. The first armed render emitted `--apply`, and systemd logged
  `unrecognized arguments: --apply` → exit 2 `INVALIDARGUMENT` on every tick: an inert enforcer
  that *looked* scheduled. The armed render now emits the empty string, and the launchd template
  uses an element-or-nothing `{{MODE_ARG}}` (an empty `<string>` would be a positional argument).
- **`WorkingDirectory=%h` on a SYSTEM unit is `/root`.** Measured `status=200/CHDIR` on every tick.
  The directive is gone: every path in the pass is absolute and the provisioner is pinned, so the
  service does not need a working directory. The suite pins the absence (T0).

## Reversing it

```
bash scripts/install-runner-autoscale-timer.sh --disarm        # stop acting, keep the schedule
bash scripts/install-runner-autoscale-timer.sh --uninstall     # remove the artifact + disable
```

`--uninstall` verifies the files are gone and refuses when they are not (it will not report a
removal it could not perform).
