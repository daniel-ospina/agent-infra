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
| hermetic suite | `scripts/install-runner-autoscale-timer.test.sh` — 433 assertions, `PASS=433 FAIL=0` (exit 0); case-by-case below |

**Not verified here (no macOS host in this lane):** `launchctl bootstrap` on a real Mac, the
plist's `StartInterval` under `launchd`, and `gui/<uid>` behaviour on a logged-in GUI session. What
*is* verified on Linux is that the Darwin path renders, that the rendered plist **parses as XML**,
that its `ProgramArguments` resolve to files that exist, that its label is the reverse-DNS form of
the unit name, and that its interval equals the systemd one — the suite asserts all four (T12). The
`launchctl` verbs themselves are exercised against a shim, so a Mac operator should expect the
first `--install` to be the real test of that arm.

## The self-check, case by case

`scripts/install-runner-autoscale-timer.test.sh` — hermetic (a mktemp fixture root, stub scheduler
tools, a stub converger), 433 assertions, `PASS=433 FAIL=0`, no network, no real scheduler. What each
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
| T11 | `--report-only` refuses while a record exists (it would look disarmed and the next routine install would silently re-arm). This case mints the record at the READER's default path, so reader and artifact agree; **T64** pins the same refusal for the one arrangement where they do not |
| T12 | the Darwin artifact renders, parses as XML, its `ProgramArguments` resolve to existing files, its label is the reverse-DNS form of the unit name, and its interval equals the systemd one |
| T13 | a second install of an unchanged tree changes nothing (bring-ups run this repeatedly) |
| T14 | an unpinned install resolves the repo's OWN converger, not a stub |
| T15 | `--disarm --dry-run` mutates NOTHING — the record survives and the artifact stays byte-identical (a preview that deletes the audit datum and leaves the pass converging is the one state the design forbids) |
| T16 | a FAILED armed re-render NEVER leaves an armed artifact with no record, and the record survives ONLY when an armed artifact backs it: the `--arm` failure branch asks `artifact_is_armed` — backed, the record is KEPT and the verb says `STILL ARMED` (T42); NOT backed, the record is DROPPED and the verb says `NOT ARMED`, because a record with nothing converging exists only to arm the box on the next routine `--install`. The one branch with no case is *disarmed render succeeds*: both renders share one template set, so a fixture cannot break one without the other |
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
| T39 | the timer's CADENCE has a drop-in route the drift `cmp` cannot see. systemd merges `$UNIT.d/*.conf` for every unit type, so a `…timer.d/*.conf` carrying `OnUnitActiveSec=1h` makes the pass fire hourly while the BASE artifact stays byte-identical to what this installer would write — `drift_artifact=no`, exit 0, the same false PASS moved one directory over. The service side has had this arm since T24; the cadence side now reports `timer_dropin=` and exits 1 for **every** elapse point (`On[A-Za-z]*Sec=` — a drop-in assignment ADDS a fire time, so `OnActiveSec=1min` sat unnoticed beside the template's own keys — plus `OnCalendar=`, `OnClockChange=` and `OnTimezoneChange=`, which carry no `Sec` and were missed by a first version of this list that its own comment claimed was exhaustive), and for `RandomizedDelaySec=` and `Unit=`. `Persistent=` is deliberately NOT in the list: it applies to `OnCalendar=` only and this unit carries none, so flagging it would be a false block — the control pins that a drop-in touching no cadence key (`[Unit] Description=`, `Persistent=true`) is NOT a false block. The same refusal is reachable from `--install` and `--arm`, not only from the readiness verb: a drop-in let them print `cadence=9min` and sign a dated record for a box firing hourly |
| T38 | `--status` scans the SECOND scope and scopes its own claim. `choose_target` resolves the scope from sudo availability at THIS invocation, so a box installed into `/etc/systemd/system` by the bring-up answers a later `--status` run — where `sudo -n` fails — from the USER scope, and printed `installed=no` plus "this box has NO scheduled converger" over a box that IS converging, then handed the operator `--install`: the one action that creates the duplicate schedule T36 exists to report. The three writers always scanned; the readiness verb — the one an operator runs FIRST — did not. The note is advisory like theirs (a second scope can be legitimate, and removing it is the operator's call), the claim is now scoped (`no scheduled converger in THIS scope`) and the remedy is labelled scope-specific. The control asserts the note is ABSENT when no other scope carries the unit |
| T33 | exit 4 (STARVATION) is RED in `--status` on BOTH platforms, as the service unit renders it. `4` sat in the green set, so the readiness verb certified the one state the unit is best placed to catch; it has its own arm because "the pass completed and reported starvation" is a different fact from "the pass is not completing" |
| T34 | an interpreter that is present and executable but older than 3.12 is NOT a usable schedule: the pass refuses itself below 3.12 and the install path refuses such an interpreter, while `--status` checked only presence. The trigger is realistic — the installer pins an ABSOLUTE path and the resolver's own candidate list includes a per-lane venv, so a venv recreated on an older interpreter changes the version under a unit that never moved |
| T35 | `--status` refuses a sudo-invoked root run, like the four writers. Under `sudo` HOME is `/root`, so the ARMING RECORD and the last-tick log were read from /root's state dir beside an artifact whose absolute paths are the user's — an armed, ticking box reported `arm_record=absent (/root/…)` and `last_tick=none` |
| T36 | `--install` and `--arm` REPORT a unit pair already installed in another scope. The mutual exclusion the service template describes ("systemd will not start a second instance of an active oneshot") is PER-UNIT, not per-account, so a user-scope copy plus a system-scope copy are two different units and two passes race to restart and add the same runners. `--uninstall` always scanned for this; the writers did not, and the second install is reachable whenever sudo availability changes between invocations. `RUNNER_AUTOSCALE_SCOPE_SCAN` pins the scan list so the suite never reads the host's real unit dirs, and the control asserts the note is ABSENT when no other scope carries the unit |
| T40 | a SECOND `ExecStart=` in the BASE file is a schedule `--status` must not certify. The read-back took `tail -1` and its comment called that line "the one systemd runs" — true of the default `Type=simple`, and FALSE of the `Type=oneshot` this template renders, where systemd.service(5) permits several and runs them **in sequence**. A base file a hand-edit left carrying a second command read as ARMED from the last line; `drift_artifact=yes` is advisory (`rc` unchanged), so `--status` exited **0** over a schedule whose FIRST command was a foreign binary. The drop-in arm cannot see it — the multiplicity is in the base file, which is the class no reader here could reach. `unit_exec_count` now reports `exec_start_count=N` and exits 1, `verify_installed_unit` refuses after the render, and `--arm` checks it in its **preflight** so no record is written for an artifact already refused (the reachable route is measured: `install(1)` can leave a pre-existing file in place on a failure while reporting success — the arm-time case stubs the write step to reach it) |
| T41 | this suite mutates the rendered artifact through `box_sed_i`, never a hand-rolled `sed -i`. On BSD sed the GNU spelling consumes the script as the backup suffix and edits **nothing** while reporting success, so all ten mutations that set up the cases only a Mac can validate were silent no-ops there: the artifact stayed healthy, `--status` correctly exited 0, and each case then failed its own `assert_eq "$RC" 1`. That is a false RED on the one platform the Darwin arm exists for, and the installer beside the suite already used a portable form — the two files disagreed about the same platform. The case asserts no bare invocation remains and that the shim is really loaded, so the guard is not vacuous |
| T42 | a KEPT arming record is backed by an actually-armed artifact. T16 proves the record is dropped when nothing converges; T42 proves the rule is not "always drop it" — deleting the record while an ARMED artifact remains would create the one state the design forbids. Before the guard, both branches kept it, which is how `--arm` could exit 1 saying "this box is converging" over a box with no artifact at all. The `--arm` failure branch now asks `artifact_is_armed` and keeps the record only when an armed artifact really backs it |
| T43 | `--status` in `ExecStart` is a MEASURE mode, not a benign switch. The classifier listed it among the switches that "change nothing about whether a tick CONVERGES"; the pass builds its run as `dry_run=opts.status or opts.dry_run`, so it changes exactly that. Classified benign, a hand-edited unit carrying `--status` reported `mode=converge (ARMED)` and exit 0 while every tick measured and repaired nothing — the `--apply` false PASS, in a word the pass accepts. It now classifies as `measure`, `--status` reports `mode=--status (MEASURE ONLY)` with the pass's own expression and exits 1, and the arm-time verifier refuses it as it refuses `--dry-run` |
| T44 | `--repo` is read back from the artifact's COMMAND LINE, not its environment. Both templates pass the repo as an argument, so `artifact_env_value RUNNER_AUTOSCALE_REPO` was empty on every box: `drift_inputs=repo` was dead code and an untouched artifact converged from a non-default pool reported `drift_artifact=yes` for ever — the "signal that always fires" class this block exists to remove. The artifact's declared value now drives the drift render and a reader/artifact difference is named in `drift_inputs=repo`. Because `--repo` has a DEFAULT there is no "unresolved" state to fall back on (unlike the provisioner), so a re-install that would REPOINT the pool reports which repo it is moving from and to rather than adopting silently |
| T45 | `OnCalendar=` is an elapse point too. `On[A-Za-z]*Sec` contains no `Sec` in `OnCalendar`, `OnClockChange` or `OnTimezoneChange`, so a `…timer.d/*.conf` adding `OnCalendar=hourly` left the base timer byte-identical and was certified a clean 9-minute box by both the readiness verb and the writers — the T39 false PASS, one key over, and the one key the timer template names as a deliberate design property. `Persistent=` stays out (it applies to `OnCalendar=` only, and the false-block control is unaffected) |
| T46 | a RECOGNISED non-converging action gets its own consequence instead of the "unrecognized arguments" text. The refusal listed five of the pass's nine switches and told the operator every other argument makes every tick exit 2 — false for `--install-unit` (which writes and enables a competing unit pair and exits, converging nothing) and for `--check-units` (which audits and exits 5). The message now names the full vocabulary and gives those actions their real consequence; hunting a failure that never appears is not a diagnosis. The INLINE `--flag=value` spelling of `--want`, `--root` and `--repo` is the SAME argument — argparse accepts it exactly as it accepts the space form — so it is no longer reported as one "this installer did not render" with the false "every tick exits 2" consequence; a value the pass cannot take stays reported — and that is MORE than the empty one: `--want` is argparse `type=int`, so `--want abc`, `--want=abc` and `--want=3x` all exit 2 (`invalid int value`) exactly as `--want=` does (T56), which the earlier wording of this row denied — while a real `--root`/`--repo=<slug>` value is configuration, dropped like its space pair. ⛔ THAT RULE APPLIES TO `--repo=` TOO: an EMPTY slug is not configuration — `--repo=` reaches the pass as the empty string, its pool read becomes `repos//actions/runners` and it exits 2 `UNMEASURABLE` on every tick (measured: `rc=2`, `gh: Not Found (HTTP 404)`), so dropping it certified `mode=converge (ARMED)` exit 0 over a schedule that is RED every nine minutes. All three follow the one rule now — an EMPTY value is reported, a real one is not — and the `other:` arm gained a case naming the empty-value class, because otherwise it told the operator a flag the pass plainly accepts was "unrecognised" |
| T47 | `--arm` NAMES why it cannot resolve a target. It called `choose_target \|\| return 1` bare, so the one verb an operator runs to make a box GROW exited 1 with zero bytes of output — indistinguishable from a crash. Every other call site (install, status, uninstall) already named the missing dependency; the arm now does too |
| T48 | the XML escaper is a LAUNCHD rule, never a systemd one. `render` put every placeholder through `xml_sed_repl` — the XML-entity escape PLUS the sed-replacement escape — on BOTH arms, and the XML half is correct only where the value lands in an XML text node (the plist). On the systemd arm it wrote the ENTITY into the unit, so `HOME=/home/a&b` rendered `Environment=HOME=/home/a&amp;b`, a path the installer never resolved. How that surfaced depended on the placeholder, and the two consequences differ: a value reaching `ExecStart=` (SCRIPT, PYTHON) made `verify_installed_unit` compare the rendered command against the real `$SCRIPT` and **REFUSE the install** — a loud but false block, so a box whose genuine path contains `&` simply could not be installed; a value reaching only `Environment=` (PATH, `RUNNER_AUTOSCALE_STATE_DIR`, and HOME when the checkout lives elsewhere) is compared by **nothing** — `refuse_unusable_target` refuses only a backslash, `refuse_systemd_unsafe_values` refuses only whitespace and `%`, and the drift render is fed the artifact's OWN declared values, so the unit installed, enabled and listed while the pass was handed a state dir that is not the resolved one. The escape is now chosen per ARM (`repl_for`), which also makes the placeholder family agree with the composed `{{PROVISIONER_ENV}}` family that T31 pins as sed-only on systemd. Both directions are asserted, so the asymmetry cannot collapse: the systemd unit carries the real value, the plist still entity-escapes it (a raw `&` there is malformed XML launchd refuses) and its PARSED value round-trips |
| T49 | `--status` refuses to certify an artifact the WRITERS refuse to create. `is_transient_scratch` is reachable only from `--install`/`--arm`/`--disarm` (via `refuse_unusable_target`), so an artifact whose declared paths sit in a `mktemp` tree was refused by the writers and then CERTIFIED by the readiness verb — and worse than unchecked: the drift render is fed the ARTIFACT's own values, so it compares the file to a render of itself, reports `drift_artifact=no` and exits 0, green over a unit that exits 127 on every tick once that tree is removed — exactly the window an operator is looking at it. Measured pre-fix on the same paths: the writer exits 1 with `REFUSING … transient scratch space` while the reader prints `drift_artifact=no` and exits 0. The writers refuse to CREATE this state, so a hand-edited, foreign or pre-fix artifact is how it is reached — which is when a readiness gate earns its keep. Both verbs now consult one predicate (the T34 `python_ok` pattern) |
| T50 | the launchd CADENCE is READ BACK from the plist, not restated from the constant. `StartInterval` is where that arm's cadence lives, and the status arm printed `cadence=StartInterval=$INTERVAL_SEC` — the value this installer WOULD write — deriving `next_run=`'s parenthetical from the same constant, so a box with a hand-edited or foreign interval (measured: `540` → `3600`) was told `cadence=StartInterval=540` over an hourly job, in the same output that flagged `drift_artifact=yes`, and exited 0. The systemd arm never had this defect — its `next_run` comes from `list-timers`, an authoritative read — so this is the T37/T39 "the timer is where the cadence lives" class, one platform over. The case asserts both the untouched control (`540`) and the edited artifact (`3600`), so restating the constant fails |
| T51 | the INSTALL path REFUSES a user timer that cannot survive logout. That refusal is the reason the lingering block exists at all, and NOTHING exercised it: `SHIM_LINGER` was set only by `envv_status_user`, which drives `--status` alone — so the writer's own gate, the one that stops the inert enforcer at CREATE time rather than a day later at read time, was asserted nowhere, and the `LOGINCTL` seam the case pins was therefore unprovable (reverting it kept the suite green). The case asserts the refusal, its own words, the absence of a `linger: enabled` claim, that `show-user` and `enable-linger` both went through the `LOGINCTL` seam — AND the discriminating control, where lingering IS available and the same install succeeds |
| T52 | `--arm`'s preflight ALLOW-LIST is pinned, and it was pinned by NOTHING. `case "$rc" in 0|4)` is a deliberate policy — 4 is STARVATION, which means the box WAS measured, so it is a reason to arm rather than a reason to refuse — but every `--arm` fixture exited 0 or 2, so reverting the arm to `0)` kept the suite green (`FAIL=0`). The policy decides whether a STARVED box can be armed at all, and a starved box is precisely the one this timer exists for. The case asserts both sides: a pass that FAILED (rc=3, the box was not measured) refuses and writes no record, and a STARVED pass (rc=4) arms and carries the ceiling it still measured. Reverted to `0)` the suite reports `PASS=361 FAIL=4`, exactly this case |
| T53 | the ARMING RECORD and the pass log are read from the directory the ARTIFACT declares, not from this shell's default. `STATE_DIR` is `$HOME/.pi/agent/state` unless `RUNNER_AUTOSCALE_STATE_DIR` says otherwise, and BOTH `ARM_FILE` and the last-tick log were derived from it ONCE, from the READER's environment — while the artifact EXPORTS the value it was installed with, and the service template states the invariant out loud: *"Exported so the scheduled pass and an operator's `--status` read ONE path, not two that look alike."* Two measured consequences for a box installed and armed WITH the seam and then read or re-installed by a routine invocation WITHOUT it: `--status` printed `mode=converge (ARMED)` beside `arm_record=absent (<the reader's dir>)` and `last_tick=none` — the readiness verb telling the operator the OPPOSITE of the truth about the two facts it exists to report (the contradiction the root guard closed for the `sudo` route, reached by its other one) — and a routine `--install` rendered `--dry-run`, SILENTLY disarming the box the owner had armed. The artifact is now the record of what was resolved, exactly as it already is for the provisioner pin (`adopt_installed_state_dir`); an EXPLICIT `RUNNER_AUTOSCALE_STATE_DIR`/`RUNNER_AUTOSCALE_ARM_FILE` still wins, and the verb says which path it honoured. The CONTROL is the part that keeps this from being "assume armed": an explicit seam pointing at a directory with no record still renders DISARMED, so a fresh box is never armed by adoption. Reverted (adoption removed) the suite reports `PASS=361 FAIL=4`, exactly this case's four assertions |
| T54 | `--status` refuses a record it cannot honour, and a declared value the WRITERS would refuse. Two one-fact-two-readers splits on the same verb. (a) **The record**: every writer asks `arm_record_valid` (BOTH `armed-by=` and `armed-date=` — the file's own rule, "BOTH LINES OR NOTHING", fail-closed), and the readiness verb asked `[ -f ]` and nothing else, so a half-written record — the exact state the rule exists to reject — was reported `arm_record=present`, while the next `--install` rendered DISARMED; and with a DISARMED artifact the same line read "present" over a box that is not armed at all. (b) **The declared values**: the writers refuse a `--repo` that is not a plain `owner/name` (`refuse_unusable_target`) and a `%` or whitespace in any rendered value on the systemd arm (`refuse_systemd_unsafe_values`), and `--status` judged none of them — while the drift `cmp` structurally CANNOT catch it, because the render is fed the artifact's OWN declared values, so it reproduces the bad value exactly and reports `drift_artifact=no`. Measured: an artifact hand-edited to `--repo "o/%h"` printed `mode=converge (ARMED)`, `drift_artifact=no`, exit 0, over a unit whose repo systemd expands to something else at load time — every tick then exits 2. That is T49's class, one key over. Reverted, each half is reported separately (`PASS=362 FAIL=3` for the record half, `PASS=363 FAIL=2` for the values half) |
| T55 | a VALUELESS `--repo` is not configuration. The strip runs BEFORE classification and removed the flag plus whatever token followed it, UNCONDITIONALLY — so `--repo` as the last token was dropped for having no value, and `--repo --dry-run` had its `--dry-run` EATEN as if it were the value. argparse rejects both (measured: `rc=2`, *argument --repo: expected one argument*), while `--status` reported `mode=converge (ARMED)` exit 0 — and `artifact_is_armed`, which tests the `--dry-run` SUBSTRING, said the opposite about the same line: two readers of one command line disagreeing, with the readiness verb on the wrong side. The value is now required before the pair may be treated as configuration (`pending` buffers one token so the next line is judged, not assumed), and a valueless `--repo` re-emits the flag for the classifier to report. Both shapes are asserted, and the control — the installer's own `--repo "o/r"` pair — stays green. Reverted, the suite reports `PASS=380 FAIL=3` |
| T56 | `--want` is argparse `type=int`, so "non-empty" is NOT the rule. The classifier tested emptiness, and the row above asserted the falsified reason (*an EMPTY value is precisely what the pass exits 2 on*): `--want abc`, `--want=abc`, `--want 3x` and `--want=3x` ALL exit 2 with *argument --want: invalid int value* (measured at this head), while `--status` certified each ARMED exit 0 over a unit that fails every tick. `want_value_ok` now requires a non-empty run of digits in BOTH spellings, and the `--want 3` control stays green because a whole number is what the flag accepts (T25 pins the intent that a real `--want` is legitimate; this case pins the shape). A value at or above the ceiling is deliberately NOT judged here — that is a REFUSAL (exit 1) only a measurement can decide. Reverted, `PASS=379 FAIL=4` |
| T57 | the reader applies the WRITERS' value rules to what it reads back. `refuse_systemd_unsafe_values` (`%` and whitespace) and `refuse_unusable_target`'s writability probe ran in `do_install_systemd`/`do_arm` and NOWHERE in `do_status`, while the drift `cmp` structurally cannot catch either — the render is fed the artifact's OWN declared values, so it compares the file to itself and reports `drift_artifact=no`. So the readiness verb certified green on facts its own writers refuse, including the `%` case the writers' comment claims `--status` *"cannot see"* (true only because it never looked). The guard covers `HOME`/`PATH`/`STATE_DIR`/`SCRIPT`/`PYTHON`/`REPO`/`PROVISIONER`, plus the `owner/name` slug rule and the exists-and-not-writable probe — that last one on the exact fact `last_tick=` depends on, since a state dir the pass cannot write makes that line `none` for ever while the verb stays green. The writability assertions are skipped as root (a 0500 directory stays writable there, so the premise cannot be expressed) and the pass/fail pair is emitted either way, so the count does not move between hosts. Reverted, `PASS=377 FAIL=6` |
| T58 | the ARTIFACT and the RECORD must AGREE, and `--status` gated neither direction. Both WRITERS refuse the disagreement after every render, so it is a state the installer refuses to CREATE — which is exactly when a readiness gate earns its keep, and the verb an operator runs AFTER a hand-edit, a partial restore or a foreign artifact judged none of it. Measured pre-fix, BOTH directions exited 0: an artifact hand-stripped of `--dry-run` with NO record (a box growing capacity with no dated owner decision — the one state the record's design exists to forbid) and a hand-reverted artifact beside a VALID record (every tick measures and repairs nothing while the box reads armed). The ABSENT case is strictly WEAKER than the INVALID record this verb already reds, so the old verdict was incoherent as well as lenient. It now reds both, naming `NO valid arming record` and `DISAGREE` respectively; the LAUNCHD arm answers the same question, so the two platforms cannot drift apart here. The CONTROL is what makes the pair meaningful: each red is produced by removing or adding ONE fact to a state that is otherwise green, so neither direction can pass by redding everything |
| T59 | `--workdir` is a CONVERGE argument, and an EMPTY `--workdir=` is not the exit-2 case. The inline arm copied the `--want=`/`--root=`/`--repo=` rule ("an EMPTY value is precisely what the pass exits 2 on") onto a switch that does not share its premise: `--workdir` is consumed only by `--install-unit`, the writers VALIDATE the value, and `unit_workdir_problem` maps `None`, the empty string and `%h` alike to the account home — so `--workdir=` parses (`rc=0` measured on the pass's own command line) and every tick converges. Reported, it reddened a working schedule with the false "did not render … every tick exits 2" reason. All three shapes are asserted, so the fix cannot over-correct into "anything `--workdir` is fine": the inline empty form and the `--workdir /srv/wd` space form are both green, and `--workdir` with NO value is still refused, naming the dangling switch |
| T60 | a DUPLICATE `--repo` is judged by its VALUE, not by its presence. Re-emitting every second pair red an EQUAL duplicate — the same pool stated twice, which argparse resolves to the pool the artifact declares — and said two false things about it ("every tick exits 2", and "converge a DIFFERENT pool"), while a false block on a working schedule is the class this file exists to remove. The value decides now: EQUAL is configuration and is dropped, DIFFERENT is a real re-point and gets the one true consequence (`DIFFERS from the first`), with the false reasons asserted ABSENT rather than merely outnumbered |
| T61 | a FAILED arm does NOT keep the record over an artifact that cannot converge — the other half of the invariant T16 and T42 pin. `runner_autoscale.py` has no `--apply`: converging is its DEFAULT, so an artifact carrying `--apply` exits 2 `INVALIDARGUMENT` on every tick and carries neither the `--dry-run` nor the converge substring a naive test keys on. The keep/drop decision has to read the artifact (`artifact_is_armed`), and it is the half that decides whether a record SURVIVES: reverted to the substring body, the suite stays `PASS=397 FAIL=0` without this case, so the record would be KEPT over an artifact that converges nothing. The fixture is hand-edited into that shape BEFORE the arm runs, because a pre-existing record would take the verb's already-armed early return and never consult the predicate at all (measured: the first draft did exactly that and proved nothing) |
| T62 | an artifact naming the script RELATIVELY is refused, not read as present. A scheduler resolves the command against a working directory this installer does not choose, so a relative path is `203/EXEC` on every tick while `list-timers` shows the job scheduled — the inert enforcer again, one field over. The verb reds it, says which rule it breaks (`NOT AN ABSOLUTE PATH`), and does NOT claim `script_present=yes` about a file it never resolved |
| T63 | the recognition filter is TOKEN-wise, so no argument is silently swallowed. The filter deleted the pass's own switch NAMES as SUBSTRINGS, so a merged token (`--install-unit--check-units`) lost both names and the verb exited 1 with NO diagnostic at all, while a suffixed one (`--check-unitsx`) was reported as the wrong argument (the leftover `x`). Both are named verbatim now, with the `did not render` diagnostic that was previously missing entirely |
| T64 | `--report-only` reads the arming record the ARTIFACT declares, not the reader's. `ARM_FILE` is frozen from the READER's `$STATE_DIR`, while the render that follows adopts the directory the ARTIFACT declares (`adopt_installed_state_dir`, T53's rule) — and the record guard ran at PARSE time, before any verb had adopted anything. So on a box installed and armed WITH `RUNNER_AUTOSCALE_STATE_DIR`, then read by a routine shell that does not export it, the guard found no record, the install went through, adopted the artifact's directory and rendered the FORCED `--dry-run` artifact — with the dated record SURVIVING beside it. That is the state T11's refusal exists to prevent (the very next routine `--install` re-arms from that record, so `--report-only` becomes a silent re-arm) and the state T58 has `--status` exit 1 on. T11 cannot see it: T11 mints its record at the reader's DEFAULT path, so reader and artifact agree there and the assertion passes for the wrong reason — which is why this case is the only one where the two paths differ. The guard now runs as `refuse_report_only_over_record`, from BOTH install verbs, after `choose_target` + `adopt_installed_state_dir` and before the render, and it keys on `REPORT_ONLY` (the CLI flag) rather than on `FORCE_MODE_FLAG`, because `do_disarm` deliberately forces a DISARMED render over a LIVE record (render first, delete the record only once the render was accepted) — keyed on the flag itself, the guard refused the disarm's own re-render and turned `--disarm` into exit 1 with the record stranded. Measured pre-fix on this case: `--report-only` exited **0** and left `--dry-run` in the artifact beside the live record, and `--status` then exited **1** on the wreckage; post-fix it exits **1** and names the record it actually read, the artifact is not re-rendered, and `--status` exits **0**. The control — the same invocation WITH the seam, T11's arrangement — still refuses, which is what makes the verdict a property of the BOX rather than of the invoking shell. Reverted (guard moved back to parse time), `PASS=428 FAIL=5`, exactly this case's five assertions |

The revert baselines quoted inside individual rows (`PASS=361 FAIL=4` in T52 and T53, `PASS=380 FAIL=3`
in T55, `PASS=379 FAIL=4` in T56, `PASS=377 FAIL=6` in T57, `PASS=428 FAIL=5` in T64) are the counts
measured **when that case landed**, against the suite as it stood then. What each row asserts is that the
revert reds exactly ITS assertions and no others; the absolute total moves whenever a later case is added,
so read the pairing and not the number. The live total is the one stated at the head of this section —
re-measure rather than adding to a history row.


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
