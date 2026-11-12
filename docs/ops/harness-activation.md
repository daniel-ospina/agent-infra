---
title: "Harness activation — what this repo ships on a clock, what is actually armed, and the one launcher that keeps it true"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-11-07
updated: 2026-11-07
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, activation, conflict-rebase, systemd-timers, launchd, harness-self-healing
---

# Harness activation — the inventory, the grid, and the launcher

**The question this answers (owner, 2026-11-07, verbatim).** *"of course we should arm it [the
conflict-rebase timer] and we should check whether everything we're shipping is fully wired in so the
harness self-heals and is bundled with a launcher — or basically check what system we need so if we
restart the harness we're not going to forget a key process from being activated."*

**The defect, stated once.** The fleet ships **capabilities that were never activated**, and every one
of them looks healthy from inside. A capability is written, tested and shipped *with an installer*; the
installer is never run, or was run on a box that has since been rebuilt. **A timer that does not exist
produces no error**, and `systemctl list-timers --all` renders a job that has never fired with the same
`-` as one that is merely idle.

`docs/ops/ACTIVATION-MATRIX.md` already answers a *different* question — files provisioned vs. active
(the `gh` shim, PATH, `keys.env`). This document is the **scheduled/daemon** axis: is the thing
*armed*, and has it *fired*.

---

## 1. The inventory — every scheduled/daemon capability this repo ships

Sources cross-referenced: `templates/systemd/*.{service,timer}`, `templates/launchd/*.plist` (plus the
`harness-apply/`, `reaper/`, `runner-autoscale/`, `conflict-rebase/` subdirectories), `scripts/install-*.sh`,
`scripts/*-timer.sh`, `pi-bootstrap/setup.sh` (`fleet_srcs`), `pi-bootstrap/cell-install.sh`, and
`scripts/cloud-cell-bringup.sh` (which installers the bring-up actually invokes).

**Read the columns literally.** "Signal" is what a reader must look at to tell *installed* from
*working*; `is-enabled` is deliberately NOT in that column, because it answers the wrong question.

| # | capability | what installs it | where | liveness signal | ships | missing = silent? |
|---|---|---|---|---|---|---|
| 1 | **controller** `eldato-orchestrator.service` | `scripts/install-controller-service.sh` ← `templates/systemd/eldato-orchestrator.service`; bring-up `check_controller_service` | cells | unit `ActiveState` + `$O/heartbeat` | **armed** | **yes** — a cell with no controller dispatches nothing and the only symptom is a quiet queue |
| 2 | **harness apply** `eldato-harness-apply.timer` | `scripts/install-harness-apply-timer.sh`; `templates/launchd/harness-apply/`; bring-up `check_harness_apply` | both | `state/harness-apply.status` + `LastTriggerUSec` | **armed** | **yes** — merged code is inert, and a stale box still reads `auto` |
| 3 | **cell self-pin** `cell-self-pin.timer` | `scripts/cell-self-pin.sh --install [--takeover]` | cells | unit state only | **not auto-installed**; MUTUALLY EXCLUSIVE with #2 (one actuator per pin) | **yes** |
| 4 | **disk reaper** `eldato-disk-reaper.timer` | `scripts/install-disk-reaper-timer.sh` ← `templates/{systemd,launchd/reaper}`; bring-up `check_disk_reaper` | both | `state/disk-reaper.status` + `.log` | **armed** (`--apply` rendered; owner-instructed) | **yes** — the disk floor arrives as a threshold and every dispatch starts failing |
| 5 | **ai drainer** `eldato-ai-drainer.timer` | `scripts/orchestrator-harness/install-drainer-timer.sh` | cells | `state/ai-drainer.beat` | **armed** | **yes** |
| 6 | **controller watchdog** `eldato-controller-watchdog.timer` | `scripts/install-cell-timers.sh`; bring-up `check_cell_timers` | cells | `LastTriggerUSec` | armed **and INERT — see §3** | **yes** |
| 7 | **objective reminder** `eldato-objective-reminder.timer` | `scripts/install-cell-timers.sh`; bring-up `check_cell_timers` | cells | `LastTriggerUSec` | armed **and INERT — see §3** | **yes** |
| 8 | **runner autoscale** `eldato-runner-autoscale.timer` | `scripts/install-runner-autoscale-timer.sh` | both | `state/ci-runner-gate.state` | **DISARMED by design** (`--dry-run`), `--arm` is a dated owner step (#2403) | yes — but deliberate |
| 9 | **conflict rebase** `eldato-conflict-rebase.timer` | **`scripts/install-conflict-rebase-timer.sh` (NEW, this PR)** ← `templates/systemd/eldato-conflict-rebase.{service,timer}` + `templates/launchd/conflict-rebase/` | both | `state/conflict-rebase/timer.beat` + `last-failure` | **armed 2026-11-07** (owner instruction) | **yes — and it was: 0 boxes scheduled it** |
| 10 | **PR repair** `eldato-pr-repair.service` | `scripts/install-repair-service.sh` | cells | unit `ActiveState` **+ the loop's own last pass** (`$O/state/pr-repair.status.json` `decision`, agent-infra#4010) | **armed** (bring-up does not install it — see §6) | **yes** |
| 11 | **worker supply** `eldato-worker-supply.service` (cells) / `com.eldato.worker-supply.plist` (mac) | `scripts/install-worker-supply.sh` ← `templates/systemd/eldato-worker-supply.service` — **Linux only; it REFUSES on Darwin** and points at the launchd half. The mac side is the launchd set in row 15, not this installer | cells (unit `ActiveState`, **row added by this PR**); mac (log mtime, via row 15) | unit `ActiveState` + `UnitFileState` | **armed** | **yes — and it was until the row existed**: the unit ships with no `.timer`, so the derivation loop could not see it and no explicit row named it; a cell with no supervisor printed `ACTIVATION COMPLETE` at rc 0 while `pr-doctor` refused every order |
| 12 | **lane arm** `eldato-lane-arm.timer` | `scripts/install-lane-arm-timer.sh` | both | `state/lane-arm.log` | installs (the arm only MEASURES; its consumer is a controller) | yes |
| 13 | **claim reaper** (controller's clock) | `scripts/cloud-cell-supervisor.sh` (`#2048`), pass = `scripts/orchestrator-harness/claim-reaper-pass.sh` | cells | `$O/state/claim-reaper.armed` (arming record) + `$O/state/claim-reaper.last` (pass record, written every pass) | **DISARMED unless `state/claim-reaper.armed` exists** (#2094 decision (e), #1678) | yes |
| 14 | **portable scheduler** `fleet-schedule.py --loop` | `scripts/fleet-schedule.py --install`; bring-up `check_schedule` | cells | `state/fleet-schedule/tick` + per-job run stamps | **armed by bring-up** | **yes** — with no loop nothing on the cell is scheduled at all (#1864) |
| 15 | **the launchd set** (`com.eldato.{ai-drainer,ai-multi-repo,controller-watchdog,corruption-canary,deepseek-balance-watch,fleet-cost-weekly,lane-liveness,objective-reminder,pi-cache-reap,pi-reap-orphans,pi-session-reaper,pi-task-session-prune,provider-latency-tripwire,worker-supply}`, `com.tortoise.{branch-reaper,ci-runner-gate,pr-doctor,worktree-hygiene,worktree-reaper}`) | `scripts/install-launchd.sh` (renders every top-level `templates/launchd/*.plist`; `templates/launchd/RETIRED` is unloaded+removed) | mac | each plist's own `StandardOutPath` mtime, bounded by its own `StartInterval` | **armed**, except the two that ship a disarming flag (below) | **yes** |
| 16 | **the reapers whose ACTION is disarmed** — `com.tortoise.worktree-reaper`, `com.eldato.pi-cache-reap` | `scripts/install-launchd.sh`, templates carry `<string>--dry-run</string>` in argv | mac | as above | **DELIBERATELY disarmed** (#1678). The SCHEDULE is required; the ACTION is the operator's call | yes |
| 17 | **box-local timers that are NOT shipped here** — `cell-reclaim.timer`, `box-cache-guard.timer` | hand-installed on pi-cell-1 (`/etc/systemd/system`, `cell-reclaim.service.d/10-cell-env.conf` records the 2026-10-25 repair) | cells (some) | `LastTriggerUSec` | n/a — not part of this repo's declaration | yes — which is why they are reported as `extra`, never as required |

**Deliberately absent from the table:** anything that is not on a clock and not a daemon. Process
liveness is `scripts/lib/fleet-inventory.sh`'s question, and its reader is
`scripts/orchestrator-bringup.sh`; this document does not re-decide it (§5).

---

## 2. The armed-state matrix — measured

**Measured on `pi-cell-1` (`vm-efa6cc8f…`) on 2026-11-07 between 18:47 and 19:50 UTC**, with
`bash scripts/activate-harness.sh --check`, and cross-checked by hand against
`systemctl is-enabled` / `is-active` / `show -p LastTriggerUSec`.

**ABSTENTION — the other five boxes were NOT measured, and this is not a "zero".** The lane ran on
`pi-cell-1`; the four peer cells are reachable only through `cmux vm exec`, and that path is **broken
on this image**: `/usr/local/bin/cmux-tui` is a symlink to `/home/cmux/.cmux/bin/cmux-tui`, which does
not exist, so every peer verb fails with *"cmux-tui daemon binary not found at /root/.cmux/bin/cmux-tui"*.
There is no ssh key on the box, and `cmux vm ls` does not list the operator's Mac at all (it is the
cmux *client*, not a peer). So the cells 2–5 and Mac columns read **ABSTAIN — not read**, which is the
abstention doctrine in `docs/ops/fleet-liveness.md` applied literally: a read that did not happen is
never recorded as an absence.

To fill the row on any box, run exactly this (read-only, changes nothing):

```bash
# cells
bash <checkout>/scripts/activate-harness.sh --check      # the human grid   (--tsv for one row per line)
# mac
bash <checkout>/scripts/activate-harness.sh --check
```

| capability | cell-1 | cell-2 | cell-3 | cell-4 | cell-5 | mac |
|---|---|---|---|---|---|---|
| `eldato-harness-apply` | **FAILING** (rc=24, `action=farm-drift`) | ABSTAIN | ABSTAIN | ABSTAIN | ABSTAIN | ABSTAIN |
| `eldato-disk-reaper` | **armed**, fired 2 647 s ago | ABSTAIN | ABSTAIN | ABSTAIN | ABSTAIN | ABSTAIN |
| `eldato-conflict-rebase` | **armed** (this PR), beacon advancing | ABSTAIN | ABSTAIN | ABSTAIN | ABSTAIN | ABSTAIN |
| `eldato-ai-drainer` | **FAILING** (`Result=exit-code`, `ExecMainStatus=1`) | ABSTAIN | ABSTAIN | ABSTAIN | ABSTAIN | ABSTAIN |
| `eldato-controller-watchdog` | **installed-not-firing** (never triggered) | ABSTAIN | ABSTAIN | ABSTAIN | ABSTAIN | ABSTAIN |
| `eldato-objective-reminder` | **installed-not-firing** (never triggered) | ABSTAIN | ABSTAIN | ABSTAIN | ABSTAIN | ABSTAIN |
| `eldato-runner-autoscale` | armed (optional row; `--arm` taken here 2026-10-29) | ABSTAIN | ABSTAIN | ABSTAIN | ABSTAIN | ABSTAIN |
| `eldato-orchestrator.service` | **FAILING** — `failed` since 04:25, restart counter exhausted | ABSTAIN | ABSTAIN | ABSTAIN | ABSTAIN | n/a |
| `eldato-pr-repair.service` | **FAILING** — `status=203/EXEC` | ABSTAIN | ABSTAIN | ABSTAIN | ABSTAIN | n/a |
| pin actuators | **CONFLICT** — `cell-self-pin` AND `eldato-harness-apply` both enabled | ABSTAIN | ABSTAIN | ABSTAIN | ABSTAIN | n/a |
| `fleet-schedule` loop | **FAILING** — loop not running, never ticked, 18 declarations broken | ABSTAIN | ABSTAIN | ABSTAIN | ABSTAIN | n/a |
| `claim-reaper` | unarmed (no `state/claim-reaper.armed`) | ABSTAIN | ABSTAIN | ABSTAIN | ABSTAIN | n/a |
| `cell-reclaim`, `box-cache-guard` | present, firing — **not shipped by this repo** | ABSTAIN | ABSTAIN | ABSTAIN | ABSTAIN | n/a |

### What the grid found (each item is a claim with the reading behind it)

1. **`eldato-objective-reminder.timer` and `eldato-controller-watchdog.timer` have NEVER FIRED.**
   Both are `enabled`, both are `active`, both have `LastTriggerUSec` **empty**, and
   `systemctl list-timers --all` prints them with no next elapse. Cause: the template's `[Timer]`
   carries **`OnUnitActiveSec=` with no `OnBootSec=`/`OnCalendar=`/`OnStartupSec=`** — systemd has no
   first elapse to be relative to, so nothing ever arms the monotonic cycle. This is an **inert
   enforcer**: the unit exists, is enabled, prints green, and can never fire. (`templates/systemd/eldato-objective-reminder.timer`,
   `eldato-controller-watchdog.timer`.) **Not fixed in this PR** — it changes behaviour for two
   capabilities and deserves its own change with its own test. Filed as **#3714** — the arming
   directive (`OnBootSec=`) is the remedy, and a template-wide gate is the non-vacuity proof.
2. **The controller and the PR-repair service were `failed` for 14 hours** (`eldato-orchestrator.service`
   since 04:25 UTC, "Start request repeated too quickly"; `eldato-pr-repair.service` `status=203/EXEC`,
   a missing executable). Nothing read either. On that box the harness had **no dispatcher and no PR
   repair loop**, while five other timers kept firing and every screen looked alive.
3. **Two pin actuators are enabled at once** — `cell-self-pin.timer` and `eldato-harness-apply.timer`
   both `active`. `cell-self-pin.sh:78-95` says in as many words that this is a race, not redundancy,
   and that the state **returns by itself** because bring-up re-arms `eldato-harness-apply` on every
   run. So this is not one bad hand-install; it is a missing invariant in the bring-up. The launcher
   now reports it as a single `pin-actuators` row, judged from the PAIR.
4. **`eldato-harness-apply` is firing and failing**: `rc=24`, `detail="farm: DRIFT — /home/cmux/.pi/agent/scripts is NOT the code origin/main ships"`.
   That is the instrument working correctly (a stale farm), and it is why the launcher's
   `--install` must not be the only thing an operator trusts.
5. **`fleet-schedule.py --verify` fails with 18 problems** — the loop is not running, it has never
   ticked, the staged scheduler differs from the checkout, and one declaration is a **broken target**:
   `/home/cmux/.pi/agent/scripts/pr-doctor-machine.sh does not resolve — the farm is INCOMPLETE`.
   So the cell-side portable schedule is *declared* and *not running*. (This is `#1864`'s layer; the
   launcher reports its `--verify` verdict rather than a second opinion.)
6. **`claim-reaper` is unarmed on this box** — correct-by-design (no `state/claim-reaper.armed`), and
   reported as `UNARMED`, not as a gap.
7. **Two live timers are not shipped by this repo** (`cell-reclaim`, `box-cache-guard`). They are
   reported as `extra` so that a reader never mistakes a hand-installed box for a shipped one.

---

## 3. The launcher — `scripts/activate-harness.sh`

```
bash scripts/activate-harness.sh --check     # the grid. Reads only. Changes NOTHING.
bash scripts/activate-harness.sh --install   # converge every MUST row, then VERIFY. Idempotent.
bash scripts/activate-harness.sh --tsv       # --check, one row per line, for a fleet sweep
bash scripts/activate-harness.sh --help
```

**Exit codes** (the same 0/1/2 contract `orchestrator-bringup.sh` uses): `0` every required row is
armed and fresh · `1` a required row is not (`MISSING`/`NEVER-FIRED`/`FAILING`/`LATE`), or an
`UNEXPECTED` one is · `2` a row could not be **read** — which is never a pass.

### The declaration is data, in one place

* **Cells:** every `templates/systemd/*.timer` is **derived into a row**. Adding a capability is adding
  a template. `row_meta()` gives it a class and a cadence; `installer_for()` must map it, and a
  template with **no mapped installer is a `DECLARATION ERROR`** that fails the run by name — which is
  literally how `conflict-rebase` shipped unscheduled for weeks.
* **Mac:** every top-level `templates/launchd/*.plist` is a row (that glob IS `install-launchd.sh`'s
  own declaration, so the two cannot drift), plus the four subdirectory plists that their own
  installers own.
* **Rows that are not a template** (the controller, PR repair, **worker supply**, the `fleet-schedule` loop, the claim
  reaper, the pin-actuator pair) are declared explicitly, because they have no template of their own.

### The four classes — because "not armed" is not one thing

| class | meaning | `--install` | an armed instance |
|---|---|---|---|
| `must` | required on this box | **arms it** | — |
| `optional` | armed by a dated owner decision that has not been taken here (`eldato-runner-autoscale`, #2403) | **never** | reported, not failed |
| `unarmed` | deliberately disarmed, with the issue that decided it | **never** | **`UNEXPECTED` — a failure** |
| `exclusive` | one-of-a-pair (`cell-self-pin` vs `eldato-harness-apply`) | **never** | judged from the PAIR |

### ⛔ The contradiction test, run first (#1678)

The owner ruling of 2026-10-11 makes **arming a deletion tool** a separate dated step and says the
tracked template must keep shipping `--dry-run`. The launcher therefore:

* **never arms** `com.tortoise.worktree-reaper` or `com.eldato.pi-cache-reap` (`--install` skips them);
* **never edits a template's mode flag** — it has no code path that does;
* **reddens if a tracked template has lost its flag — on BOTH platforms** (the templates are tracked
  files in every checkout, so a cell must notice that edit too, not only a Mac). "The launcher did not arm it" is only half the
  invariant; the other half is "nobody quietly edited the template to armed", because that arms the
  job on **every box at once** on the next install, with no dated decision and nothing in the log.
  Only the two templates that carry `<string>--dry-run</string>` **in argv** are guarded — that set is
  measured, not assumed (`grep -c '<string>--dry-run</string>' templates/launchd/*.plist`), so the
  guard is not vacuous;
* **does not touch** `scripts/install-launchd.test.sh`'s assertion that the reaper ships unarmed.

### One verdict vocabulary, borrowed not invented

`OK` · `LATE` · `NEVER-FIRED` · `FAILING` · `MISSING` · `UNARMED` · `UNEXPECTED` · `SKIPPED` ·
`UNKNOWN` — the state names come from `scripts/lib/fleet-inventory.sh`, so one screen has one
vocabulary (`docs/ops/fleet-liveness.md` §"one verdict function").

### It is not a second liveness authority

It answers *"is this capability scheduled, enabled, and has it fired inside its own cadence?"* It does
**not** answer *"is this process alive, singleton, and fresh?"* — that is `lib/fleet-inventory.sh`,
read by `scripts/orchestrator-bringup.sh`.

**Where it consumes an owner's verdict, and where it does not — stated exactly, because an earlier
draft of this section claimed both and that was false for one of them.**

| row family | whose verdict | note |
|---|---|---|
| `fleet-schedule` | **`fleet-schedule.py --verify`'s exit code**, consumed verbatim (0/1/2/3 mapped, nothing re-derived) | one authority |
| systemd timer / service rows | **the unit's own** `UnitFileState` / `ActiveState` / `Result` / `LastTriggerUSec` | one authority — systemd's |
| `claim-reaper` | **the pass's own** arming record + pass record (`$O/state/claim-reaper.{armed,last}`) | one authority |
| launchd rows | **this tool's own read** of `launchctl print` + the installed plist | ⛔ **two authorities exist and the repo's other one is NOT consumed**: `install-launchd.sh --status` answers installed/loaded/version/drift for the same set, and it measures *no* freshness. Since freshness is the axis this grid adds, the row is this tool's read, and it says so on its face. Reconciling them (one verdict, two callers) is a follow-up, not a claim. |

⛔ **The launchd freshness half is the weakest row in this grid and is labelled as such**: `launchctl
print` gives a reliable *run count* (so `runs=0` is a true `NEVER-FIRED`), but **age** needs a log
path, and most shipped plists declare none. Those rows print `AGE UNMEASURED` and the summary counts
them, so "ACTIVATION COMPLETE" can never be read as "everything was measured".

---

## 4. Conflict-rebase, armed — and the evidence

### What was missing

`scripts/conflict-rebase.py` (the bot) and `scripts/conflict-rebase-timer.sh` (the clock) had shipped,
been reviewed, and were **farmed to no box, scheduled by no box and installable by no verb**:
`grep -n conflict-rebase pi-bootstrap/setup.sh` returned nothing. So on the night this audit was
opened, 8 PRs sat `CONFLICTING` and an operator hand-dispatched 8 rebase lanes to do what an hourly
timer would have done.

### What this PR adds

* `templates/systemd/eldato-conflict-rebase.{service,timer}` — 30-minute monotonic timer
  (`OnBootSec=5min` arms the cycle, `RandomizedDelaySec=120` spreads the fleet, no `Persistent=`
  because it is meaningless for a monotonic timer);
* `templates/launchd/conflict-rebase/com.eldato.conflict-rebase.plist` — the Mac side, in a
  **subdirectory** so `install-launchd.sh`'s glob and `fleet-schedule.py`'s top-level glob cannot
  double-schedule it beside the systemd timer;
* `scripts/install-conflict-rebase-timer.sh` — one verb, both platforms, idempotent, `--status`,
  `--uninstall`, `--dry-run` (preview) and `--report-only` (the same artifact rendered with the
  observation flag, so disarming is never a hand-edit);
* `pi-bootstrap/setup.sh::fleet_srcs` — the bot, the wrapper and the installer are now **farmed**, all
  three, because the wrapper resolves its bot as `<its own dir>/conflict-rebase.py`.

### ⛔ Four real defects were found while arming it

1. **The brake did not hold on the shape the fleet schedules.** `conflict-rebase-timer.sh pause`
   creates `state/conflict-rebase/PAUSED`, and only the **detached loop** honoured it: `start --once`
   — the form a systemd timer and a launchd job call — did not, so an operator's brake was ignored by
   exactly the path that runs unattended. Fixed (`start --once` refuses and exits 0; it does **not**
   stamp the beacon, because the beacon means *a pass completed*), and pinned by the suite (T8).
2. **The state dir was not a seam.** The wrapper hardcoded `$HOME/.pi/agent/state/conflict-rebase`
   while the unit exports `CONFLICT_REBASE_STATE`, so the artifact would have stated one path while
   the beacon, log, brake and `last-failure` were written to another — and a `pause` written to the
   exported path would not have been seen by the pass that reads the hardcoded one. Fixed with
   `${CONFLICT_REBASE_STATE:-…}`. (The pollution this caused during this lane's own test is preserved
   under `~/.pi/agent/state/conflict-rebase/pre-seam-pollution/` rather than deleted: a beacon is
   evidence. (Outside the repo by construction — a beacon lives in the box's state dir, so the pointer
   is an absolute path, not a repo path.))
3. **The first rendered service had no `ExecStart=`.** systemd accepted the file, then refused the
   timer that triggers it (`unit … to trigger not loaded`), and `enable --now` printed `Job failed`
   while both files looked perfect. The installer now reads the rendered artifact and refuses a
   service with no `ExecStart=` **before** installing it — and the installer's own after-arming
   verification is what surfaced it (it reported `is-active=inactive` instead of claiming success).
4. **`--status`'s timestamp was GNU-only.** It rendered the last-pass time with
   `date -u -d "@<epoch>"`, so on a Mac every `status` printed
   `last pass: 1794081048 (…) -> ?` — the human-readable half of the line degraded to a question mark
   while the numeric half stayed correct, which is why nothing ever reddened. Now an inline probe that
   tries **GNU first** (`-d @<epoch>`, which cannot be confused with a file), then the BSD arm **only
   when it round-trips exactly** (`date -r <epoch>`; on coreutils `-r` means "reference FILE", so
   without the round-trip check a file named like the epoch answers with its own mtime — measured), and
   degrades to the raw epoch rather than to `?`. A first attempt at this fix shipped a worse bug: the
   ISO arm's stdout was never captured, so on a real BSD `date` the function printed **two lines**.
   ⛔ **It cannot source `box_epoch_to_iso`**, and that is the point: this wrapper is **farmed** and
   `scripts/lib/box.sh` is deliberately not farmed, so a sourced path would resolve in the checkout and
   404 on every cell — the same constraint `scripts/portability-baseline.tsv` already records for
   `cloud-cell-supervisor.sh`'s `box_ncpu`. The shim's **probe order** is mirrored.
   ⛔ **And its `date-d-gnu` baseline row was restored, not removed.** An earlier revision deleted it
   with the reasoning "a row that no longer exists is headroom" — which is backwards here: the trap
   detector's carve-out blesses `date -d @<e> || date -r <e>` **in one command unit**, and this fix puts
   the fallback in a separate `if` body, so with the row gone the gate goes **RED on code that is
   portable** (measured: `baseline=0 live=1`). A grandfathered row whose justification is "portable as
   written; the detector does not model this shape" is honest; deleting it would have made a false red
   look like a fix.

### The review-record question (the brief asked; the answer is in the code, not the comment)
The bot **must not** leave a stale attestation standing silently. It does not: after every push it
re-reads the gate's own diff hash (`record-review.sh --print-diff-hash`, read-only),
and

* **diff unchanged** → the record is **kept** and the PR comment names the hash;
* **diff changed** → the record is **moved aside** (`<name>.superseded-<oldhead>`) and any
  review-asserting label is removed;
* **diff unreadable** (the pushed head never became visible) → the record is superseded
  **unverified** and the comment says so;
* it **never edits the PR body** and always states the new head, so no reader can mistake it for the
  reviewed one.

Verified at `scripts/conflict-rebase.py` `record_state()` / `strip_review_labels()` and the post-push
call site — not from its header. **Residual, declared:** if `record-review.sh` is absent on a box,
`diff_hash()` returns `unavailable` and a *valid* record is superseded (fail-closed, and it says
`UNVERIFIED` in the comment). Wrong direction for convenience, right direction for safety — the
launcher's `must` baseline `harness-apply` plus the farm declaration keep `record-review.sh` on the box.

### Evidence

```
$ systemctl list-timers eldato-conflict-rebase.timer
NEXT                         LEFT     LAST                         PASSED   UNIT
Sat 2026-11-07 20:20:48 UTC  7min     Sat 2026-11-07 19:50:06 UTC  23min    eldato-conflict-rebase.timer

$ grep -E 'BEGIN|END' ~/.pi/agent/state/conflict-rebase/timer.log
2026-11-07T18:48:19Z BEGIN once   → END rc=0  beacon 1794077299   (install-time fire — proves INSTALL)
2026-11-07T19:19:54Z BEGIN once   → END rc=0  beacon 1794079255   (ADVANCE 1 — proves SCHEDULE)
2026-11-07T19:50:06Z BEGIN once   → END rc=0  beacon 1794081048   (ADVANCE 2 — proves PERIOD)
                    next elapse 20:20:48
```

**Two consecutive advances, not one.** One fire proves the unit was installed and its environment is
sane; only a *second* one, at the period the timer declares, proves the schedule exists at all — and
that is the distinction this whole audit is about, because an install-time fire is exactly what a
one-shot `systemctl start` also produces.

A pass's own log:

```
[conflict-rebase] census: open=10 conflicting=1 candidates=1 max=3 dry_run=False
[conflict-rebase] fleet-state speaks for daniel-ospina/tortoise, not daniel-ospina/agent-infra — board arm ignored
[conflict-rebase] #3235 SKIP ci-main-shard: live lane (held by the claim registry (refs/claims/3235-7373c4844116))
[conflict-rebase] done: acted=0 refused=0 skipped=9 conflicting_before=1
```

**The lane-hold guard demonstrably works on live data** — that pass refused the one conflicting PR
because a live lane held it.

**Its brake path** (recorded here because the brief asked for it, and because a brake nobody can find
is not a brake):

| what | path |
|---|---|
| pause / resume | `~/.pi/agent/state/conflict-rebase/PAUSED` — create it with `conflict-rebase-timer.sh pause`, remove with `resume` |
| beacon (epoch of the last COMPLETED pass) | `~/.pi/agent/state/conflict-rebase/timer.beat` |
| per-pass log | `~/.pi/agent/state/conflict-rebase/timer.log` |
| last failure (rc + time) | `~/.pi/agent/state/conflict-rebase/last-failure` |
| disarm the schedule | `install-conflict-rebase-timer.sh --uninstall`, or `systemctl disable --now eldato-conflict-rebase.timer` |
| observe without acting | `install-conflict-rebase-timer.sh --report-only` (re-renders with `CONFLICT_REBASE_DRY_RUN=1`) |

---

## 5. What a fresh box needs — the thing to read before rebuilding a cell

Ordered, and every step is a verb that exists in this repo (nothing here is "remember to…"):

1. **Clone + the operational layer** — `git clone … /tmp/cell-ai && bash /tmp/cell-ai/pi-bootstrap/cell-install.sh`
   (installs extensions, skills, the `gh` shim, and **farms `scripts/`**, which is what makes every
   pass below resolvable).
2. **Bring-up** — `HOME=/tmp/cell-home bash scripts/cloud-cell-bringup.sh --check` → `CELL READY`. It
   installs: the controller service, the disk reaper timer, the harness-apply timer, the objective
   reminder + controller watchdog pair, and the `fleet-schedule` loop.
3. **`bash scripts/activate-harness.sh --install`** — converges the rows bring-up does **not** cover
   (today: `eldato-conflict-rebase`, `eldato-ai-drainer`) and then **verifies every row**, naming
   anything that did not come up. A box is not done until this exits 0 (or every remaining row is an
   explained `UNARMED`/`SKIPPED`).
   * ⛔ **`eldato-pr-repair.service` and `eldato-worker-supply.service` are `must` rows with NO install
     path anywhere** — `--install` iterates `*.timer` templates only, `installer_for()` has no entry for
     either, and **bring-up does not call `install-repair-service.sh` or `install-worker-supply.sh`
     either** (verified). So on a fresh box those two rows can only go green by hand, and step 3's
     "until this exits 0" is unreachable for them. That is a **declared gap**, listed in §8, not a step
     you can follow.
   * `eldato-orchestrator.service` **is** installed by bring-up (`check_controller_service`), so the
   controller is fine on a fresh box; only PR repair and worker supply are orphaned. The supply row is
   new in this PR and it **verifies**, it never installs: the capability shipped, was installable, and
   nothing in the grid could see it missing (§1 row 11).
4. **`bash scripts/activate-harness.sh --check`** — the read-back. Keep it in the rebuild checklist.

**Not needed, and deliberately:** `eldato-runner-autoscale` (`--arm` is a dated owner step),
`com.tortoise.worktree-reaper`, `com.eldato.pi-cache-reap` (ship disarmed, #1678), `claim-reaper`
(needs `state/claim-reaper.armed`), `cell-self-pin` (an alternative pin actuator; installing it means
retiring `eldato-harness-apply` with `--takeover`, not adding a second actor).

**Known traps on a rebuild** (each measured, each with a source): `gh` shim absent → the merge gate
runs degraded (`docs/ops/ACTIVATION-MATRIX.md` row 1); `capture` extension blocking turns →
`tortoise-capture` moved aside (#2147); `AGENT_INFRA_PATH` unset → `session-checks`/`auto-sync` silently
skip (row 11); a cell with no `keys.env` has no `MAX_LOAD` (row 9).

---

## 6. The launcher's own self-check, case by case

`bash scripts/activate-harness.test.sh` — 143 assertions, hermetic (fixture HOME, fixture checkout,
fake `systemctl`/`launchctl`, a stubbed bot). The count is kept honest by re-reading the suite's last
line, which is the only place it is stated: a figure in prose re-stales silently, and that is the class
this whole document is about.

| case | what it proves | why it exists |
|---|---|---|
| **T1** | a fully armed box exits **0** and prints `ACTIVATION COMPLETE` | a grid that can never be green is as useless as one that is always green |
| **T2** | **NON-VACUITY** — remove one unit file and `--check` exits **1**, grades it `MISSING`, and names it in the summary | this is the whole point: a launcher that reports success over a missing unit is the fail-open this repo keeps filing issues about |
| **T3** | an installed, enabled, active timer with an empty `LastTriggerUSec` is `NEVER-FIRED`, not `OK` | the measured inert-enforcer state (§2.1); `is-enabled` cannot see it |
| **T4** | a shipped `*.timer` with **no mapped installer** is a `DECLARATION ERROR` (exit 2), named | the exact shape that made conflict-rebase invisible |
| **T5** | `--install` runs **every** must row's own installer, and **never** `install-runner-autoscale-timer.sh` (optional) or `cell-self-pin.sh` (exclusive) | pins `do_install`'s case to the grid's `installer_for()`, and pins the #1678/#2403 discipline |
| **T6** | `--install` still exits **1** (and says `ACTIVATION INCOMPLETE`) when a row did not come up | verify-after-arming is not decorative |
| **T7** | a reaper template that **loses** its `--dry-run` is `UNEXPECTED`; one that keeps it is not | the #1678 invariant, guarded in the repo rather than only in the launcher's behaviour |
| **T8** | `start --once` with `PAUSED` exits 0, says `PAUSED`, and **stamps no beacon**; unpaused, it runs the pass and stamps one | the brake must hold on the shape the fleet schedules |
| **T9** | an **armed** `optional` row that is broken (`OPTIONAL NOT OK: …`) while the exit stays 0; an intact one prints nothing | the `optional` class is a decision about the EXIT CODE, not about visibility — a broken optional row used to increment a counter nothing printed, and the "prints nothing" half is what proves the note is not always-on |
| **T10** | a required timer stamped **6 days ago** is `LATE` **and the run exits 1**; the summary never says COMPLETE | nothing pinned `LATE` — the gate's primary verdict. A mutant that made every age "now" kept the suite fully green (review finding) |
| **T11** | under `TZ=Asia/Tokyo` a freshly-fired box is green **and** a JST-stamped timer **2 h old** is still `LATE` | `LastTriggerUSec` renders in the **box's local zone**; parsing it as UTC makes the age negative east of UTC, clamps to 0, and **a dead timer reads OK**. The 2 h stamp is the only window that discriminates (it is over the 5400 s cadence and far under the 9 h offset) |
| **T12** | a mac with every plist installed+loaded+`runs=3` reaches `ACTIVATION COMPLETE`, the launchd arm is **actually reached** (the install log carries `install-launchd.sh`), and the installer is never passed `--install` | no test drove a **green** mac grid, which is how two mac false-reds shipped (a broken plist read, and a verb `install-launchd.sh` does not have). ⛔ The second half of that assertion was **vacuous** until review cycle 11: the fixture never created `install-launchd.sh`, so the arm's own `[ -f … ]` gate was false and the log line it asserted absent could not be written — restoring the `--install` defect left the suite green (measured). The positive control is what makes the absence attributable |
| **T13** | a templates dir that exists but holds **no** `*.timer` exits **2** and says `examined ZERO` | "I examined nothing" was a pass — the same rule as the unmapped-template error, applied to the SET |
| **T14** | an unsupported platform (`FreeBSD`) exits **2** and names it | the old `else` sent every non-Linux platform down the macOS grid |
| **T15** | an **armed** claim reaper (record at `$O/state/…`) makes the run FAIL | the probe read `~/.pi/agent/state/…`, which nothing writes, so an armed #1678 deletion tool graded `UNARMED`, exit 0 |
| **T16** | a **braked** conflict-rebase row prints `PAUSED`, and the beacon line replaces the tick line | `LastTriggerUSec` says the *timer ticked*, not that a *pass did anything* — a brake was invisible to the instrument built to see it |
| **T17** | a launchd job with `runs = 0` is `NEVER-FIRED` and fails the run | the launchd analogue of an empty `LastTriggerUSec`; the arm existed and no test reached it |
| **T18** | a conflict-rebase **beacon** three hours old is `LATE` | the arm that justifies moving the row off `LastTriggerUSec` — a beacon that stops advancing is the whole point, and T16 only checked the wording |
| **T19** | a **weekly** `StartCalendarInterval` job with a 30-day-old log is `LATE`, and green once the log is fresh | a calendar job has no `StartInterval`, so the old bound was 24 h and its own weekly log reddened it six days in seven — making `ACTIVATION COMPLETE` unreachable on a healthy Mac |
| **T20** | `AGE UNMEASURED` appears on the row **and** the summary counts it | a green grid must never imply everything was measured |
| **T21** | conflict-rebase's state dir comes from **the unit's `Environment`, read in the unit's own scope** (one timer moved to the user manager, a non-default `CONFLICT_REBASE_STATE`) | `sysd_show` is only valid while `SC_PREFIX` matches the unit; the read happened *before* this row resolved its scope, so it went through the previous row's manager and a healthy box read `NEVER-FIRED` |
| **T22** | `SYSTEMCTL=/nonexistent/systemctl` ⇒ **every** systemd probe is `UNKNOWN` and the run exits **2** — including `pin-actuators` | a guard on one probe out of three turned a failed read into claims about the box ("not installed", "NEITHER pin actuator is enabled") |
| **T23** | an `optional` row that is absent reads `UNARMED`, exit 0, no NOTE | `optional` had no way to express its own documented normal state |
| **T24** | a **cell** also guards the tracked reaper template, and an armed-in-the-repo template fails the cell run | the #1678 template guard ran only on the macOS grid |
| **T25/T26** | a mac `PAUSED` row says PAUSED, and a mac beacon five days old is LATE (exit 1) | the mac conflict-rebase row read only `runs` + log, so the SAME state read LATE on a cell and `OK … AGE UNMEASURED` on the Mac |
| **T27/T28** | the bound follows the timer's declared `OnUnitActiveSec` (5 h is fine at 120 min; `08min` parses as decimal and still produces a row) | a constant bound read a long-cadence box LATE forever, and a leading zero aborted the arithmetic so the row **vanished** while the summary said COMPLETE |
| **T29** | a calendar key that exists only as an XML **comment** does not widen the bound to 8 days | a `\|\| grep` fallback cannot tell a declaration from a mention, and would certify a dead job green |
| **T30** | a non-string `*_STATE` value is unreadable, never a `NEVER-FIRED` claim built from a Python repr | a malformed plist became a hard claim about whether any pass had ever completed |
| **T31** | a unit whose period cannot be read says `cadence UNREADABLE … assumed 1800 s` on the OK row, and stays green | the disclosure was computed, passed as a parameter, and rendered by **none** of the four beacon emits — the only branch that row reaches — so an assumed bound printed identically to a measured one. A disclosure no state renders is not a disclosure |
| **T31b–T31d** | the same disclosure appears on the `NEVER-FIRED` and `LATE` rows, and is **absent** when the period *was* read (`30min` ⇒ 8400 s, undressed) | after T31 the note was still a comment on three of four arms — and those are the states an operator actually meets (a freshly built box, a stopped one). The negative case is the other half: a disclosure printed always is as useless as one printed never. The `UNKNOWN-mtime` arm is the one use **no test can pin** (breaking `stat` portably is not a thing a fixture can do), and the code says so |
| **T32** | the repair pool's **supply half** is a row on a cell: no supervisor ⇒ exit **1** + `NOT ARMED: eldato-worker-supply.service`; installed-but-**disabled** and enabled-but-**failed** each fail it; enabled+active is green | `templates/systemd/eldato-worker-supply.service` ships with its own Linux installer and carries no `.timer`, so the derivation loop could not see it and no explicit row named it — a cell with no supply half printed `ACTIVATION COMPLETE` at rc 0 while `pr-doctor` refused every order (review cycle 11, F2). Deleting the row takes the first case to rc 0, so the case is the row's only pin |
| **T33** | `conflict-rebase-timer.sh status` renders the beacon's epoch as an ISO date through the **BSD** arm (a stub `date` that rejects `-d @…`, exactly as coreutils-less macOS does), never prints `-> ?`, and degrades to the **raw epoch** when no mechanism works at all | review P1-3: the portable `_iso` replaced `date -u -d "@$beat" … \|\| echo '?'` — which printed `-> ?` on every Mac — and NOTHING pinned it. T8 is the only case that runs the real wrapper and never invokes `status`; `conflict-rebase.test.sh` "pins" status with a text grep that cannot see `_iso`. Restoring the pre-fix line reddens four of these assertions |
| **T34** | the **review stage** is graded on the repair loop's OWN pass record, never on `ActiveState`: a `dispatched` record is green (naming the pass and the `cap`), `refusing` is **FAILING** with the loop's own `reason` + a pasteable remedy, a record that never existed is `NEVER written a pass record`, a stale green one is `LATE` (bound 3 × the unit's `REPAIR_INTERVAL_S`, floored at 1800 s), and the record is read from the UNIT's `O=` rather than this launcher's default | measured on a cloud cell 2026-11-12: `active (running)` for three days while every pass wrote `decision: refusing — env-file-unreadable:…`, and the grid printed `OK … active` over it. `pr-repair-loop.sh --loop` CONTINUES on a refusal, so the restart policy never fires and `ActiveState` cannot see the state — the epic whose child this is advertises “deployed AND activated” on exactly that signal. Restoring `probe_systemd_service … "-" 0` at the call site takes the suite from 143/0 to 132/11 |

`bash scripts/install-conflict-rebase-timer.test.sh` — 51 assertions, the installer's own fixture suite
(fixture HOME/checkout/install dirs, `systemctl`/`launchctl` shims that record every call). Before it
existed the installer was executed by **nothing**: the launcher suite replaces it with a two-line stub and
every other gate gave it `bash -n`, so deleting the file left the whole suite green. It pins the two
platform paths end to end (including F3 — `--report-only` must land `CONFLICT_REBASE_DRY_RUN` **inside**
`EnvironmentVariables` and be readable back), the `ExecStart=` and cadence refusals, `--status`,
`--uninstall`, the Darwin/systemd whitespace asymmetry (`PLATFORM`, not the not-yet-assigned `TARGET`),
and the brake's state-dir resolution (`pause`/`resume` write the directory the INSTALLED unit exports,
and an ambient value that disagrees is REFUSED rather than written where nothing looks).

## 7. The review record
**Eight** fresh-context review cycles ran against these files. Issues found per cycle: **18, 12, 7, 6, 3,
1, 1, then `NO ISSUES FOUND`** — the seventh of which was that cycle 6's own fix was pinned on **one of
the four** arms it patched. Zero P0 from cycle 2 onward. The counts are not progress; the *class* of finding is: cycle 1's five P0s were all in the **instrument** (a plist read whose `sed` delimiter collided with
its own alternation and therefore matched nothing on either platform; an `install-launchd.sh --install`
verb that has never existed; a report-only flag written to the wrong plist dictionary; a
`LastTriggerUSec` age parsed as UTC and clamped negative, so a dead timer read `OK` east of UTC; and the
claim reaper's arming record read from a path nothing writes, so an ARMED deletion tool graded `UNARMED`
with exit 0). A launcher with any one of those is worse than no launcher: it is a false PASS with a
green grid behind it.

Every later finding was the same shape one level down — an arm that existed but that no test reached.
Every finding from cycles 4 and 5 is now pinned by a **revert-mutant**: each fix was reverted in a
scratch copy and the suite was required to redden. A fix whose revert leaves the suite green is not a
fix, it is a comment — and three of cycle 4's findings were exactly that, plus a cycle-5 finding that
was worse: **T26 called `assert_exit`, which did not exist**, so the call printed `command not found`
and contributed nothing to PASS/FAIL while the suite reported 98/98. An assertion helper that is not
defined cannot fail. That is why the review of the *tests* is not ceremony.

⛔ **One invariant is pinned by mutation only, and it is named rather than implied:** the `ROW_N`
reconciliation (`activate-harness.sh`, the "emitted NO row" arm) fires when a probe returns without
emitting. Nothing this launcher can be *given* provokes that — the bug it guards was an arithmetic abort
at its own call site, which is gone. So its proof is `: ;;` on the conflict-rebase arm: the suite then
goes broadly RED and the run exits **2** with that row `UNKNOWN`. A future edit that deletes the
reconciliation would ship silently; the mutant is the defence, and this paragraph is the record of it.

---

## 8. What this PR does not do (residuals, declared)

1. **The other five boxes are unmeasured** (§2). The launcher is the instrument; running it there is
   the follow-up; the peer-exec failure is recorded as evidence on **#2345** (the existing root for
   "cross-cell work is impossible from a cell"), not as a new issue.
2. **The two inert timers are reported, not fixed** (§2.1). Changing `OnUnitActiveSec`-only templates
   to carry an arming trigger changes behaviour for two capabilities; it gets its own change + test —
   **#3714**.
3. **`cloud-cell-bringup.sh` does not call the launcher yet.** It installs four of the capabilities
   directly, and calling the launcher's `--install` from it would (a) re-run those installers and
   (b) pass no `DISK_REAPER_REPOS`, which that installer correctly refuses on. The wiring is a
   scoped follow-up, not a one-liner; until then step 3 of §5 is a checklist item, not a gate.
4. **The two pin actuators are reported, not reconciled.** Retiring one is an operator decision
   (`cell-self-pin.sh --install --takeover`) and the bring-up must then be made to respect it — the
   second half is why the state returns by itself, and it is on the board.
5. **`eldato-pr-repair.service` has no install path** anywhere in the rebuild (§5 step 3): no timer
   template, no `installer_for()` entry, and bring-up does not call `install-repair-service.sh`. The
   row is `must`, so a fresh box cannot reach a green grid without a hand step. Declared, not papered.
   **The same is now true of `eldato-worker-supply.service`**, which this PR gave a row: its installer
   exists (`scripts/install-worker-supply.sh`, Linux-only, it REFUSES on Darwin) but `--install` cannot
   reach it (the cell branch iterates timer templates), bring-up does not call it, and it is not in
   `pi-bootstrap/setup.sh`'s `fleet_srcs` — so on a cell it lives only inside a checkout. The row makes
   that state VISIBLE on every `--check`; wiring it into `--install` is a separate change with its own
   tests (it needs sudo, a rendered PATH and a unit write), not something to smuggle in with a row.
   ⛔ **AND THE ROW IS WEAKER THAN IT LOOKS — #3766.** It is judged on `ActiveState` alone, and
   `worker-supply.sh --loop` is designed never to exit on a pass verdict (`refused`/`unreadable`/
   `deferred` all continue — *"a loop that exits on a single rc=3 is a supply path that stops about the
   first refusal it meets"*). So a supervisor that is enabled, active and re-offering **nothing** every
   60 s reads exactly what a healthy one reads, while `pr-doctor` still refuses every order — the same
   quiet repair pool this row exists to surface, one layer in. The beacon was NOT used because the
   record is `ts=`-keyed and the beacon arm reads the file's CONTENT as an epoch (coercing `ts=…` to 0 →
   permanent LATE); the fix is the record's **mtime**, the signal `probe_recorded` already falls back to.
   Declared here with its issue number rather than left for a reader to rediscover.
6. **The launchd rows are this tool's own read, not `install-launchd.sh --status`'s** — two authorities
   for one set, and only this one measures freshness (§3). Reconciling them is a follow-up.
7. **`AGE UNMEASURED` on a Mac is a known headroom:** `launchctl print` proves a job has run, but not
   that it is still running at its cadence when the plist declares no log path. Counted in the summary
   so it cannot be mistaken for a full certification.
8. **`conflict-rebase` is armed on `pi-cell-1` only.** Every other box gets it from
   `install-conflict-rebase-timer.sh --install`, which is now a `must` row the launcher runs — so a
   rebuilt box cannot forget it, which is the owner's actual requirement.
