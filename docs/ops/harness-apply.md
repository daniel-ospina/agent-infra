---
title: "Harness apply — activation on the clock (#2416)"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-10-23
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-2416, harness-activation, cloud-cell-supervisor, sync, systemd, launchd
---

# Harness apply (#2416)

One scheduled pass — `scripts/harness-apply-pass.sh` — that puts a box's harness on
`origin/main`. It **owns no activation**: it calls the verb the box already has, behind
the safety predicates that decide whether the box may be moved at all.

| platform | activation verb (existing) | scheduled artifact | cadence |
|---|---|---|---|
| Linux cell | `scripts/cloud-cell-supervisor.sh apply` (`--pin-only` while a controller is live) | `eldato-harness-apply.service` + `.timer` | `OnUnitActiveSec=10min`, `OnBootSec=2min` |
| macOS | the checkout's own `./sync.sh` (fetch + `pull --ff-only` + config refresh + launchd) | `~/Library/LaunchAgents/com.eldato.harness-apply.plist` | `StartInterval=600` (+ one at load) |

Installed by `scripts/install-harness-apply-timer.sh` — one installer that renders and
converges, both platforms. `cloud-cell-bringup.sh --check` runs it, so a cell is never
certified `CELL READY` without an activation clock.

## Why it exists

The capability was built and correct (`apply` pins a per-commit worktree,
agent-infra#1745; `start` runs it before every launch). **Nothing scheduled it**, so a
box ran whatever code it had when it was last started. Measured 2026-10-23:

```
Mac   agent-infra HEAD ce97fe82 · origin/main c51630de · behind 91
      AGENT_SYNC_MODE=auto  -> yet 91 behind, because ONE modified tracked file
      (scripts/orchestrator-harness/install.sh) made sync.sh abort — and nothing said so
c1    HARNESS-PIN 54bbb0c6 while its checkout was ce987bb2      <- the pin lied
c3/c4 pin ce987bb2 while origin/main was c51630de               <- stale
```

A harness fix that merged but is not live on a cell **has fixed nothing**: the fleet
keeps executing the behaviour the fix removed. And the drift was invisible — the pin is
a file nothing re-read, `sync.sh` aborting is *correct* behaviour with no reporter above
it.

## The safety predicates (stated, and tested)

The pass refuses to move a box it must not move. Each predicate is a pair in
`scripts/harness-apply-timer.test.sh`: the refusal, and the same fixture moving once the
condition is gone.

- **AHEAD of the ref → REFUSED (exit 21), with the count.** Local commits may be a lane's
  only copy: c4 lost three unlanded commits on 2026-10-22, recovered only through
  `git cherry`. The count is in the message because "ahead" alone does not say whether it
  is worth keeping.
- **DIVERGED → REFUSED (exit 22).** Neither ancestor nor descendant: a rebase is an
  operator decision, not a scheduled one.
- **DIRTY → preserved BY NAME, then moved.** The bytes are written to
  `<state>/harness-apply-preserved/<UTC>/changes.patch`, every untracked file is copied
  under `untracked/`, and `MANIFEST` lists every path taken; each path is printed as it is
  saved. Only then are the tracked paths brought back to `HEAD` and the checkout advanced.
  If anything cannot be preserved, the pass REFUSES (exit 20) and touches nothing.
  This is the Mac defect: `sync.sh` aborting on a dirty tree is right — having no path
  that saves the work and finishes the advance is what cost 91 commits.
- **A RUNNING LANE IS NEVER SIGNALLED.** The pass contains no `kill`, `pkill`,
  `systemctl restart` or `launchctl kickstart` (a static assertion pins that; the only
  `kill` is the `kill -0` liveness probe). On a cell the advance is
  `apply --force --pin-only`: `--pin-only` keeps the scheduler out of `$O` (seeding is
  `start`'s job, and re-seeding under a live loop is the version skew
  `cloud-cell-supervisor.sh` refuses), and `--force` is what `apply` requires before it
  will touch a cell whose controller is live — with `--pin-only` alone it REFUSES, so a
  running cell would never advance. Together they create a NEW per-commit worktree and
  leave the running tree alone: a lane keeps the code it started with, and the restart is
  deferred to the next launch (`harness-refresh.sh`'s recorded design, honoured rather
  than re-decided).
- **THE READINGS ARE PRINTED EVERY PASS**: `head`, `deployed`, `ref`, `behind`, `ahead`,
  `dirty`, `pin`, `pin_tree`, the mode, and then the action. A verdict without the numbers
  behind it is not auditable, and "behind" is the number that was invisible for 91 commits.

## The pin must not lie

A pin is **two** records: `HARNESS-PIN` (a sha) and `.harness-path` (the tree the
controller execs). They can disagree, and a pin that disagrees with its checkout is a
false record of what is deployed — every reader then reports a commit nobody runs
(c1, 2026-10-23: `54bbb0c6` against a tree at `ce987bb2`).

After the move, the pass re-reads both. If the sha record does not name the tree's actual
`HEAD` it **repairs** it (`pin: REPAIRED <old> -> <new>`, exit 10); an absent or empty pin
is **mended** from the same reading (exit 11). `apply` is a no-op when the pin already
names the ref tip, which is exactly the state c1 was in — that is why the repair lives in
the pass and not in `apply`.

## The record, and who reads it

One `key=value` per line, written atomically to
`${HARNESS_APPLY_STATE_DIR:-$HOME/.pi/agent/state}/harness-apply.status`:

```
mode=pin
ok=1
rc=0
epoch=1750000000
at=2026-10-23T05:00:00Z
head=ce987bb2c1de            <- the CHECKOUT (a pin advance never moves it)
deployed=ce987bb2c1de        <- the commit this box RUNS (the pin tree); `behind` is measured from here
ref=c51630de1f2a
behind=0
ahead=0
dirty=0
pin=ce987bb2c1de
pin_tree=ce987bb2c1de
preserved=none
action=none
lanes=none-signalled
detail=current: pin already names origin/main (ce987bb2c1de) — nothing changed
```

⛔ `deployed` EXISTS BECAUSE THE CHECKOUT IS NOT THE DEPLOYMENT. A pin-per-commit cell
never moves its checkout, so `behind` measured there would be permanently non-zero and
the alarm un-clearable; measured from the deployed commit it is 0 exactly when the box
runs main. The record is written from the FINAL state, never from the readings taken
before the move (a record saying `behind=1` beside `action=advanced` alarms on the pass
that just fixed it).

`harness-apply-pass.sh --print-status` answers "did the last pass succeed", and applies a
staleness bound (`HARNESS_APPLY_STALE_SECONDS`, default 3600 = six cadences): a job that
stopped writing its record is an alarm, not a healthy silence.

⛔ **The Mac's silent failure is now loud on the fleet's own instrument.** `tools/fleet/fleet-health.py`
reads this record on every host — the same section that reads the disk reaper's — and
alarms when `behind>0` **even for a pass that exited cleanly**, because the number is a
reading about the checkout while the exit code is about the pass. A refusal (ahead,
unpreservable dirt) and a stale record alarm too. `fleet-health` exits non-zero on any of
them, so a scheduler can see it.

## Exit vocabulary

Adopted verbatim from `scripts/orchestrator-harness/harness-refresh.sh`, because both
answer the same question in the same fleet and two vocabularies for one fact is the defect
this repo keeps deleting.

| code | meaning | unit colour |
|---|---|---|
| 0 | `current` — the pin already names the ref tip; nothing changed | green |
| 10 | `advanced` — the materialiser ran and the pin moved (or a lying pin record was repaired) | green |
| 11 | `mended` — the pin was missing/empty; what the box actually runs was recorded | green |
| 20 | REFUSED dirty — the tree carries work that could not be preserved | **red** |
| 21 | REFUSED ahead — local commits are not on the ref's line | **red** |
| 22 | REFUSED diverged | **red** |
| 23 | REFUSED unknown — the ref/repo/HEAD cannot be resolved, the materialiser failed, or the pin record could not be written | **red** |
| 25 | behind, and this box has nothing that can advance it | **red** |

A red tick is deliberate: those are states a **human** must resolve, and the unit colour
is the only surface that reaches someone who is not tailing a log.

## Install, verify, disarm

Install on a cell (idempotent; a second run is byte-identical and prints `changed=0`):

```bash
bash scripts/install-harness-apply-timer.sh --install
```

Verify it is armed (exit 0 = armed **and** the last pass was healthy):

```bash
bash scripts/install-harness-apply-timer.sh --status
```

Disarm — one verb, no hand-edit of an installed file:

```bash
bash scripts/install-harness-apply-timer.sh --uninstall
# the platform's own fallback if the installer is unavailable:
systemctl disable --now eldato-harness-apply.timer
launchctl bootout "gui/$(id -u)/com.eldato.harness-apply"
```

`--dry-run` is a PREVIEW (renders and prints the artifact, writes nothing, enables
nothing) and is **not** a disarm.

`--status` is the readiness gate and it fails on all three legs: not installed, installed
but **inactive** (an enabled-but-inactive timer is not a schedule), and a pass record that
is refusing or stale. A fresh install whose first tick has not happened yet reports
`note=no pass has completed yet` rather than failing.

## Install targets

systemd, in this order, with the reason named in the output:

1. a **system** unit via passwordless sudo (`/etc/systemd/system`) — the cell's normal
   shape; the service runs as the invoking user, so the pass writes the lane user's state;
2. a **user** unit (`~/.config/systemd/user`) when the user manager answers — a cell
   without sudo still gets a clock. Lingering is **checked**, because a user timer without
   it fires while you are logged in and never again;
3. nothing — a **loud failure naming the remedy**, never a silent no-op.

macOS has one: a LaunchAgent in the user's GUI domain, started through the checkout's own
interpreter (`pi-reap-worktrees-launchd.py`) because TCC is per-binary — a
launchd-spawned `bash`/`git` cannot read a repo under `~/Documents`, so a `bash` job would
fail closed every ten minutes while `launchctl list` showed it healthy. No usable
interpreter is a refusal at install time.

## Declared limits

⛔ **An agent cannot execute the pass from a dirty checkout, by design.**
`main-worktree-guard` (#709) classifies the dirty-preserving restore — bringing tracked
paths back to `HEAD` from git content — as a REVERT, so `--print-status` and even
`bash -n` are refused from a checkout carrying uncommitted changes. That is the guard
doing its job on a shared checkout: under the scheduler there is no such guard, the
installer calls the pass through its own resolved path (so
`install-harness-apply-timer.sh --status` is unaffected), and an operator with a dirty
checkout can use the documented hatch. The same interaction is recorded for
`scripts/pi-cache-reap.test.sh` in `docs/ops/disk-reaper.md`.

## What this does not do

- **It does not change `apply`.** If `apply` has a defect, that is a separate issue, not a
  silent fix here.
- **It does not restart a controller or a lane.** The advance is pin-per-commit; the
  restart is the next launch's business (`restart-pending` is reported by `harness-up`).
- **It is not a second seeder, stamper or drift detector** — `seed_and_stamp`,
  `harness-refresh.sh` and `check-deployed-drift.sh` keep their jobs.

## Tests

`scripts/harness-apply-timer.test.sh` — 99 assertions, run by the `harness-apply-timer`
shard of `run-bash-shards.sh`:

| | |
|---|---|
| T1 | a box **AHEAD** of main is refused, with the ahead count in the message and in the record; the same fixture **BEHIND** advances (the control) |
| T2 | a **DIRTY** box preserves the modified tracked file and every untracked file BY NAME, names each path, fast-forwards, and leaves the patch + copies where the record says; a *converged* box preserves nothing (no per-tick pile-up) |
| T3 | two installs: `changed=0`, and the service and timer unit bytes are **identical** |
| T4 | a **lying pin** (`HARNESS-PIN` ≠ the tree's HEAD) is repaired to the tree's head; an absent pin is mended from it |
| T5 | a box with **no installable scheduler** exits non-zero, says so, and installs nothing |
| T6 | the pass is a **no-op** when the pin already names the ref tip (`action=none`, HEAD unmoved) |
| T7 | the pass **signals nothing** (static: no `pkill`/`killall`/restart/kickstart/SIGTERM/KILL; every `kill` is `kill -0`) |
| T7b | the advance calls the materialiser with **both** `--force` and `--pin-only` — a stub that enforces the supervisor's own refusal makes a regression that drops either flag go red |
| T8 | an enabled-but-**inactive** timer fails readiness; a record whose `rc` is a refusal fails it too |
| T9 | `--dry-run` moves nothing and reports what it *would* preserve |
| T10 | `--uninstall` disables and removes, and `--status` then reports not-installed |
| T11 | the same verb installs, reports and disarms the **macOS** artifact; no interpreter is a refusal |
| T12 | a unit rendered from **transient scratch** (`/tmp/tmp.XXXX`) is refused — the measured 127-every-tick unit |
| T13 | the cadence seam is validated (`abc`, `0`, `1441` refused); a value that does not divide the hour (7) is kept — the artifact states the cadence it keeps |
| T14 | a **stale** record (including one dated in the FUTURE) is an alarm, a non-numeric staleness bound is refused, and no record at all is `never`, not success |
| T15 | a dirty **tracked symlink** is restored as a symlink, and the clean file it pointed at is byte-for-byte untouched (this repo tracks 34 symlinks; writing the blob through the link corrupted the target) |

`tools/fleet/fleet_health.test.py` gained the `HARNESS:` leg for the record reader: no
record without a schedule is not an alarm, a scheduled box with no record is, `behind=91`
alarms on the number, an ahead refusal alarms, and stale / future-dated / epoch-less
records alarm.
