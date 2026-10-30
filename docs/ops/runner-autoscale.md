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

⛔ **OVER-CEILING IS REPORT-ONLY, AND IT NEVER CONVERGES DOWN.** The pass has exactly three actions
— `restart`, `repair`/re-register and `add` — and **no removal path of any kind**: no `stop`, no
deregister, no `DELETE /actions/runners/<id>`. Its own header states it (*"nothing here relabels,
removes, or re-ranks an existing runner"*, *"restart, relabel or remove a runner that is serving (or
may be serving) a job"*), and its over-ceiling branch ends `nothing removed`. So a box above its
ceiling — pi-cell-1 measured `live=5` against `ceiling=3` — prints `over-ceiling` every nine minutes
**for ever** and stays at 5 until a human removes the surplus by hand. A `SERVING` runner is **not**
removable either; that sentence used to appear here and was false about the code this timer
schedules. There is no convergence to wait for: arming the timer is not a remedy for an
over-ceiling box. Below the ceiling it grows through the provisioner
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
| hermetic suite | `scripts/install-runner-autoscale-timer.test.sh` — 256 assertions, `PASS=256 FAIL=0`; case-by-case below |

**Not verified here (no macOS host in this lane):** `launchctl bootstrap` on a real Mac, the
plist's `StartInterval` under `launchd`, and `gui/<uid>` behaviour on a logged-in GUI session. What
*is* verified on Linux is that the Darwin path renders, that the rendered plist **parses as XML**,
that its `ProgramArguments` resolve to files that exist, that its label is the reverse-DNS form of
the unit name, and that its interval equals the systemd one — the suite asserts all four (T12). The
`launchctl` verbs themselves are exercised against a shim, so a Mac operator should expect the
first `--install` to be the real test of that arm.

## The self-check, case by case

`scripts/install-runner-autoscale-timer.test.sh` — hermetic (a mktemp fixture root, stub scheduler
tools, a stub converger), 256 assertions, `PASS=256 FAIL=0`, no network, no real scheduler. What each
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
| T16 | a FAILED armed re-render NEVER leaves an armed artifact with no record: when the disarmed re-render also fails the record is KEPT and the verb says `STILL ARMED` (the one state the design forbids), because that record is the only on-disk statement that the box is converging. The complementary branch — disarmed render succeeds, so the record is removed and the verb says `NOT ARMED` — is not covered by a case: both renders share one template set, so a fixture cannot break one without the other |
| T17 | `%` is refused on the systemd arm (systemd expands it as a specifier at load time, so the rendered path silently differs and every tick 203/EXECs) and allowed on the launchd arm (a plist `<string>` is not expanded) |
| T6b | a VALID pinned interpreter is used verbatim — refusing a bad pin while quietly ignoring a good one is the same substitution one direction over |
| T18 | `--status` exits 1 when the artifact's INTERPRETER is gone, reporting `python_present=no` while still reporting `installed=yes` — the two are different questions |
| T19 | `--status` exits 1 and NAMES an unrecognised mode argument (`--apply`), instead of reporting `mode=converge (ARMED)` for an artifact the pass would reject on every tick |
| T20 | `--install`, `--arm`, `--disarm` AND `--uninstall` all refuse a sudo-invoked root run — the guard used to live in `--install` only, so `sudo … --arm` wrote a record in `/root` and installed an ARMEd `User=root` unit over the correct one. The guard now runs before each verb's FIRST write, so no record is written either |
| T22 | `--report-only` is refused with `--arm`, `--disarm` and `--uninstall` — it is a render flag for `--install` only, and with a writer it was measured minting a dated record and printing `ARMED` over a `--dry-run` unit, and performing a REAL removal under a preview flag |
| T23 | `--uninstall` LEAVES a valid arming record and says so, naming the date and the consequence (the next `--install` renders an ARMED unit). Measured: a bare uninstall + install re-armed from a record the operator believed was gone, while the `--status` remedy promised a DISARMED install. The record is not deleted by `--uninstall` — it is the operator's dated decision, and `--disarm` is the verb that revokes it |
| T24 | an `ExecStart=` DROP-IN under `$UNIT.d/*.conf` is an override, not a detail: `--status` reports `dropin_override=` and exits 1, and `--arm` refuses BEFORE the record exists. A drop-in that assigns no `ExecStart=` (e.g. `Nice=5`) is not an override — no false block |
| T24b | a BARE `ExecStart=` in a drop-in is the RESET directive, not a comment: it clears the exec list and systemd then refuses the unit ("Service has no ExecStart= … Refusing") while the base file still states one. Detecting the *value* missed it, so `--install` enabled and `--arm` signed a dated record for a unit that cannot start |
| T26 | a real switch's ABSOLUTE value is a value: `--root /opt --apply` is reported broken (the pass exits 2 on `--apply`), `--root /opt/x --dry-run` reads DISARMED, and a value-taking switch with no value is refused — both when it is LAST (`--dry-run --want`) and when another FLAG follows it (`--want --json`, `--root --dry-run`), which argparse rejects as `expected one argument`. The remainder used to be built by dropping every `/`-prefixed token, so `--root`'s value vanished and the orphaned flag swallowed the NEXT argument |
| T27 | the converger is read as TOKEN 2, not as "the argument ending in `.py`": a wrapper or console-script without the suffix installs (any executable regular file does), and the suffix rule then discarded every argument — reporting `mode=converge (ARMED)` over a DISARMED artifact while exiting 1 |
| T28 | a launchd removal that FAILED is not reported as uninstalled: a plist surviving in `LaunchAgents` is loaded again at the next login, resuming the pass, and a failed `launchctl list` reads the same as "not loaded" |
| T25 | `--status` accepts the pass's real switch vocabulary (`--status`, `--json`, `--want N`, `--root P`) and reds only an argument this installer never rendered. It used to red anything that was not exactly `--dry-run`, so a working `--want 3` schedule was reported as exiting 2 on every tick |
| T21 | a RELATIVE interpreter pin is refused: a scheduler resolves it against its own working directory, so the unit would 203/EXEC every tick while `list-timers` showed it scheduled |
| T29 | `--status` GATES on `enabled` instead of only printing it, and `static` fails too (no `[Install]` section ⇒ nothing links the timer into `timers.target`): an active-but-not-enabled timer does not come back at the next boot, so the readiness verb — the one an operator and the health sweep call LATER — was the lenient of two readers of one fact, while the install path already refused that state |
| T30 | on a USER target `--status` re-checks `linger`, because lingering can be cleared after the install by an operator or an image rebuild: without it the readiness verb certified a timer that stops firing at logout. (Reaching the user target in the suite needs two fixture facts: `SUDO=false` is the documented "skip the sudo probe" seam, and the `systemctl` shim has to model `systemctl --user <verb>`) |
| T31 | the launchd provisioner pin round-trips a shell-hostile path (`&`, `<`) and names a file that EXISTS. It used to be escaped twice — `provisioner_env_for` sed-escaped its value and `render` sed-escaped the composed `{{PROVISIONER_ENV}}` again — so the installed plist pinned `/…/inst\&x.sh`, literal backslashes on a path that does not exist; the plist still parsed and nothing compared the value, so the pass would have found no provisioner and exited 3 on every capacity tick. The same case asserts BOTH arms pin the identical path |
| T32 | `--status` reports `drift_artifact=no` on an untouched USER-scope artifact. The install path drops `User=` for that target (systemd rejects it there) and the drift render did not, so the two files could never match and the drift signal fired on every run — a signal that always fires is a signal nobody reads, and it came from the very `--status` the install hands the operator as its remedy |
| T37 | the drift comparison covers the artifact that carries the CADENCE. `--install` writes `…service` **and** `…timer`, and `--status` rendered and compared ONE (`…service`); the timer is where `OnBootSec=`/`OnUnitActiveSec=` live, and `{{INTERVAL_SEC}}` is rendered into the PLIST only, so the timer template is static text that nothing else compares. A hand-edited, foreign, or older-cadence timer fired at the wrong interval while the verb whose comment promises to catch "a changed interval" printed `drift_artifact=no` and exited 0 — and a timer that is MISSING (so nothing fires at all) printed the same. `drift_parts=service=… timer=…` attributes it, and `drift_artifact` is `no` only when BOTH were compared and matched and `unknown` when a render failed (a render failure is evidence of neither drift nor cleanliness). Same case: the drift RENDER must resolve what the install path resolved — `resolve_provisioner` decides whether the artifact carries an `Environment="RUNNER_AUTOSCALE_PROVISIONER=…"` line, `--install` called it and `--status` did not, so on every box that HAS a provisioner the two files could never match and the verdict was a permanent `yes` whose `--install` remedy answered `changed=0` |
| T39 | the timer's CADENCE has a drop-in route the drift `cmp` cannot see. systemd merges `$UNIT.d/*.conf` for every unit type, so a `…timer.d/*.conf` carrying `OnUnitActiveSec=1h` makes the pass fire hourly while the BASE artifact stays byte-identical to what this installer would write — `drift_artifact=no`, exit 0, the same false PASS moved one directory over. The service side has had this arm since T24; the cadence side now reports `timer_dropin=` and exits 1 for `OnBootSec`/`OnUnitActiveSec`/`OnCalendar`/`Persistent`/`Unit`, and the control pins that a drop-in touching no cadence key (`[Unit] Description=`) is NOT a false block |
| T38 | `--status` scans the SECOND scope and scopes its own claim. `choose_target` resolves the scope from sudo availability at THIS invocation, so a box installed into `/etc/systemd/system` by the bring-up answers a later `--status` run — where `sudo -n` fails — from the USER scope, and printed `installed=no` plus "this box has NO scheduled converger" over a box that IS converging, then handed the operator `--install`: the one action that creates the duplicate schedule T36 exists to report. The three writers always scanned; the readiness verb — the one an operator runs FIRST — did not. The note is advisory like theirs (a second scope can be legitimate, and removing it is the operator's call), the claim is now scoped (`no scheduled converger in THIS scope`) and the remedy is labelled scope-specific. The control asserts the note is ABSENT when no other scope carries the unit |
| T33 | exit 4 (STARVATION) is RED in `--status` on BOTH platforms, as the service unit renders it. `4` sat in the green set, so the readiness verb certified the one state the unit is best placed to catch; it has its own arm because "the pass completed and reported starvation" is a different fact from "the pass is not completing" |
| T34 | an interpreter that is present and executable but older than 3.12 is NOT a usable schedule: the pass refuses itself below 3.12 and the install path refuses such an interpreter, while `--status` checked only presence. The trigger is realistic — the installer pins an ABSOLUTE path and the resolver's own candidate list includes a per-lane venv, so a venv recreated on an older interpreter changes the version under a unit that never moved |
| T35 | `--status` refuses a sudo-invoked root run, like the four writers. Under `sudo` HOME is `/root`, so the ARMING RECORD and the last-tick log were read from /root's state dir beside an artifact whose absolute paths are the user's — an armed, ticking box reported `arm_record=absent (/root/…)` and `last_tick=none` |
| T36 | `--install` and `--arm` REPORT a unit pair already installed in another scope. The mutual exclusion the service template describes ("systemd will not start a second instance of an active oneshot") is PER-UNIT, not per-account, so a user-scope copy plus a system-scope copy are two different units and two passes race to restart and add the same runners. `--uninstall` always scanned for this; the writers did not, and the second install is reachable whenever sudo availability changes between invocations. `RUNNER_AUTOSCALE_SCOPE_SCAN` pins the scan list so the suite never reads the host's real unit dirs, and the control asserts the note is ABSENT when no other scope carries the unit |

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

`--uninstall` verifies the files are gone on BOTH arms and refuses when they are not (it will not
report a removal it could not perform) — on systemd by re-testing the unit paths, on launchd by
testing the surviving plist as well as the loaded label, because launchd reloads a plist that
survives in `LaunchAgents`. It deliberately does NOT delete the arming record: the record is a
dated decision and `--disarm` is the verb that revokes one. So a box that was armed stays ARMED —
`--uninstall` prints the record's date and says the next `--install` will render an armed unit. If
you want the box to come back disarmed, run `--disarm` before (or after) the uninstall.

## Why this pass, when #2403 names `ci_runner_pool.sh reconcile`

The issue names `ci_runner_pool.sh reconcile`, but the pass that states the capacity contract —
measure the box, derive a ceiling from cores/memory/disk, classify the pool against it, repair dead
runners and grow toward it — and that is reviewed and tested is
`scripts/orchestrator-harness/runner_autoscale.py` (#2877, #2900). This timer schedules THAT.

The two are not interchangeable, and they are not both safe to run on the same box:
`ci_runner_pool.sh` derives its own ceiling (cores plus a memory floor, no disk term) while the
converger's is `min(cores, memory, disk)`. On a box the converger now ticks every 9 minutes, a hand
`reconcile`/`add` can put the pool above the converger's measured ceiling and the next tick reports
`over-ceiling` — it will not remove anything (no runner is ever removed: not a busy one, and not an
idle one either — the pass has no removal path), but the two answers
disagree. So: **`runner_autoscale.py` is the scheduled capacity authority; `ci_runner_pool.sh` is
the manual/incumbent tool — do not hand-run `reconcile` on a converged box.** Reconciling the two
for good is filed as a follow-up (#3056), not resolved here.
