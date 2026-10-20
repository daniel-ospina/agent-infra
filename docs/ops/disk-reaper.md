---
title: "Disk reaper — one scheduled pass over the three disk sinks (#2032)"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-10-18
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-2032, disk-reclaim, uv-cache, lane-venvs, worktrees, systemd
---

# Disk reaper (#2032)

One entry point — `scripts/disk-reaper.sh` — that runs, accounts for and reports
the three sinks that exhaust a cell's disk. It **owns no deletion rule**. Each
class has one owner, and the owners are the only code that deletes:

| class | owner (policy) | reclaims |
|---|---|---|
| `uv` | `scripts/pi-cache-reap.sh` (#1987) | machine-global uv/npm/pip caches, bounded **by size** (`CACHE_REAP_MAX_MB`, default 2048 per cache), prune-then-escalate |
| `venv` | `scripts/reap-lane-venvs.sh` (#1932 / #1949) | per-worktree `.venv`s whose lane is gone, proven by three liveness witnesses; fail-closed |
| `worktree` | `scripts/pi-reap-worktrees.sh` (#1095) | clean, reachable, holder-free checkouts; merged heads are exempt from the 7-day floor |

## Why one entry point

The fleet already reaped ad hoc in four places — `cloud-cell-supervisor.sh prune`,
the hourly cache pass inside `orch-loop.sh`, `pi-reap-worktrees-launchd.py` (macOS
only, so cells had nothing), and `cleanup-worktree.sh` at merge time. Four triggers
and no single answer to *"is this box being reaped, and how much did the last pass
free?"*. This is the consolidation: one scheduled pass, one pass record, one status
line, and the existing owners untouched except where a class needed a new policy
(the merged-head floor below).

Adding a fourth copy of a delete rule would have been the easy path and is
explicitly refused: `disk-reaper.sh` contains **no `rm` on a filesystem path** (its
only recursive delete is its own lock), and the test suite pins that
(`disk-reaper.test.sh` T6).

## Failure mode this exists for

Disk exhaustion is the **second** reason the cloud cells stopped working, and it
fails misleadingly: the controller keeps beating, the queue reads fine, and every
dispatch is refused because at ~97% used a `git worktree add` or a `uv sync`
cannot write.

Measured 2026-10-18, before any cleanup:

```
cell-3 1.7 GB free (95%) · cell-2 2.2 GB (97%) · lane-1 1.1 GB (97%) on 63 GB volumes
biggest single offender: a stale PR worktree, /tmp/wt-pr-8915 = 1.1 GB (its PR is MERGED)
/tmp/wt-pr-8839 = 291 MB (merged) · /tmp/cell-home = 524 MB
earlier on cell-3, ~/.cache/uv alone was 7.1 GB; clearing it freed 6-7 GB
```

## Byte accounting — two numbers, because one alone is a lie

* **dry-run**: per-candidate `du` (blocks occupied) for what *would* go. A
  per-worktree `.venv` **hardlinks** into the uv cache, so `du` counts the same cache
  blocks again for every venv that shares them and **over-states** what removal
  frees. Every such line says so, and the estimate is never reported as freed bytes.
* **apply**: the `df` delta across each class — what the filesystem actually got
  back. This is the number in the pass record and in the supervisor's status line.
  A zero or negative delta is reported as 0 for the status line, and the UNCLAMPED figure is
  printed beside it (`df_raw=…MB`) — a clamp that cannot be audited is indistinguishable from a
  measurement that never happened.

## Safety property

A live holder is **never** selected. The witnesses are mechanical and fail closed:

* `live-tmux-pane` — a tmux pane whose `pane_current_path` resolves inside the
  worktree (the lane is alive even between turns);
* `live-cwd` — any process whose cwd is inside the path (catches
  `bash -c 'cd <wt> && pytest'`, whose argv never names the path);
* `live-argv` — any process whose command line names the path.

A probe that cannot be evaluated is a refusal (`exit 3` **from the owner**), not a pass. Through the
entry point that refusal arrives as exit **6** with `ok=0` in the pass record and
`verdict=<class>=refused` — the unit stays green because the box is busy, and the RECORD is what
alarms (see **Exit codes** below). The worktree owner additionally requires the checkout to be
**clean** (uncommitted work is never destroyed), **reachable** (its commits survive the checkout's
deletion), and not an open-PR head.

`disk-reaper.test.sh` T2 is the load-bearing test: a real process cwd'd into a real
linked worktree is kept by both the worktree and venv classes, and the *same*
fixture is reclaimed once the holder is gone.

## Bounded execution — the pass cannot assume GNU `timeout` (#2046)

Every subprocess that reads the filesystem runs under a wall-clock bound, because a
reaper that hangs the box is worse than the disk it was reclaiming. That bound is
resolved **once**, by `scripts/lib/bounded.sh`, in one order:

1. `timeout` (GNU coreutils)
2. `gtimeout` (Homebrew coreutils)
3. an **internal background watchdog** — a `sleep`-timed subshell that SIGKILLs the
   child and writes a sentinel, so a real kill is distinguishable from a command
   that exited `137` on its own

All three report a timeout as **rc=124**, which every caller already treats as
fail-closed, so the class verdict does not depend on which mechanism bounded it.

**Why this is recorded as a defect and not a nicety.** macOS ships neither binary.
Before #2046 every call site in `disk-reaper.sh` died with
`timeout: command not found` (rc=127 → fail-closed → rc=3), and the pass *completed*,
printing `verdict=fail-closed` for all three classes with `candidates=0`. That is the
false PASS this whole feature exists to remove: measured on the laptop 2026-10-18,
`--dry-run` against `~/eldato/tortoise` reached `pass end verdict=3 freed_df=0MB —
NOTHING was removed` while every delegate was present and working.

**What the pass says now.** The resolved mechanism is recorded in the pass record as
`watchdog=timeout|gtimeout|internal`, and printed as one extra report line **only when
it is not GNU `timeout`** — so a host that has the real binary produces byte-identical
output to before, and a Mac says out loud which watchdog it used. Absence of the
*helper* (a partial deploy) is not a fallback: both reapers **refuse at startup** with
exit 3 and name the missing library, because without it no probe is bounded at all.
An explicit `TB_TIMEOUT_BIN` that cannot be executed is refused the same way rather
than silently ignored. `TB_TIMEOUT_FORCE_INTERNAL=1` pins the fallback for tests.

`pi-reap-worktrees.sh` already carried this watchdog as its `run_bounded` (#1095);
that implementation moved into the shared library, so the two reapers cannot drift
into bounding different probes. `reap-lane-venvs.sh` still carries its own copy — it
already works on macOS, and folding it in is a behaviour-neutral follow-up.

## Merged heads and the age floor

`pi-reap-worktrees.sh` requires a HEAD older than 7 days. For a **merged** head that
floor protects nothing — the merge is the proof the work landed, and the tree is
separately required to be clean — so `REAP_WT_MERGED_AGE_DAYS` (default `0`) governs
that row. Unmerged heads keep the blanket floor, where age still separates a stale
scratch checkout from work in progress. Setting it equal to `REAP_WT_AGED_DAYS`
restores the pre-exemption behaviour.

## Scheduling — installed by the bring-up, armed by owner instruction

`templates/systemd/eldato-disk-reaper.{service,timer}` — hourly
(`OnCalendar=hourly`, `Persistent=true`), installed and enabled by
`cloud-cell-bringup.sh --check` through
`scripts/install-disk-reaper-timer.sh` (idempotent: a second install is a no-op).
The installer tries a **system unit** via passwordless sudo, then a **user unit**,
and fails loudly when neither is available — an unscheduled reaper is the false PASS
this feature exists to remove.

**Arming.** The repo's general rule (#1678, owner ruling 2026-10-11) is that
deletion tools ship dry-run and arming is a separate, dated, reversible owner step.
This feature was explicitly instructed to run unattended on the cell, so BOTH artifacts carry
`--apply` through the installer's `{{MODE_FLAG}}`; the arming is visible in the installed file, not
hidden in an environment default.

⛔ **`--dry-run` is NOT a disarm — and this doc used to say it was.** It claimed
"re-run the installer with `--dry-run` to install a report-only unit". `--dry-run`
RENDERS AND PRINTS the unit and installs nothing (`do_install`'s DRY_RUN branch; T8
asserts that a `--install --dry-run` leaves a FRESH unit dir empty and enables nothing),
so an operator following that sentence to disarm a cell's hourly deletion pass got exit 0
and an unchanged, still-armed unit. On a deletion tool that is the worst kind of false
PASS, so it is stated plainly here. **To disarm, re-install through the one documented verb:**

```
scripts/install-disk-reaper-timer.sh --report-only --install
```

which renders the SAME artifact with `--dry-run` instead of `--apply` (and, for systemd, the
matching `SuccessExitStatus` — see the exit codes). Disarming by hand still works and is the
fallback when the installer is unavailable, and it must be recorded on the cell:

```
systemctl disable --now eldato-disk-reaper.timer
```

(`--dry-run` is a PREVIEW of what would be installed — nothing is written, nothing is
enabled, nothing is disarmed; `--install` is idempotent and a second run with unchanged
bytes changes nothing but `daemon-reload`.)

The timer's environment is rendered from this box (`HOME`, `PATH`, repos that git
confirms exist), so the pass never depends on a login shell. The venv and worktree
classes need a repo; a pass with none **fails closed** rather than scanning nothing.

## What this can and cannot do for cell capacity (#2159)

⛔ **THE REAPER CANNOT RAISE THE CELL'S CEILING.** It converts a DEAD lane's residue
into free space. It does not make a lane smaller. Measured: RAM is the cell ceiling
(~0.9 GB per lane), and disk is a *second, invisible* cap — one live worktree holds
~1.1 GB of `.venv` (11× the venv's apparent `du`, because a venv hardlinks into the uv
cache), so a box with 8 GB free can hold about seven live lanes no matter how
aggressively its dead residue is reaped.

Two consequences that are easy to get wrong, and that this pass deliberately does
not paper over:

* **A dispatch refusal must be memory-derived.** "The reaper ran and freed 6 GB, so we
  can dispatch" is not a valid inference. The disk floor is a *guard*, never a
  capacity signal (#1852).
* **The reaper must never trade a live lane's env for free space.** That is why the
  venv class is witness-based rather than size-based, and why the suite proves the
  dead-vs-live distinction in APPLY mode (T19) instead of only demonstrating that a
  stale-looking env can be removed.

`docs/ops/lane-venv-reaper-policy.md` owns the lane-level policy; the capacity
numbers and the dispatch floor are tracked in #2159 / #1852.

## Status — the supervisor answers "did it succeed, and how much did it free"

Every pass writes `$DISK_REAPER_STATE_DIR/disk-reaper.status` (default
`$HOME/.pi/agent/state`), atomically, as `key=value`:

```
mode=apply ok=0 rc=6 classes=uv,venv,worktree watchdog=internal
freed_mb=515 freed_mb_uv=1 freed_mb_venv=0 freed_mb_worktree=514
verdict_uv=deferred verdict_venv=ok verdict_worktree=ok
would_free_mb_* candidates_* repos=/tmp/cell-ai detail=pi-cache-reap.sh exited 7
freed_mb_unmeasured=
```

`rc=6` with `detail=… exited 7` is a **deferral**: `pi-cache-reap.sh` ran, found a live `uv` holding
the cache, declined to act and claimed nothing. The condition is recorded (`ok=0`,
`verdict_uv=deferred`) and the unit stays green — see **Exit codes**. `rc=` carries the PASS's code and
`detail=` names the DELEGATE's own, in every class, so an outcome is never reported under a code its
owner does not use. `classes=` and `repos=` answer "which sinks and which checkouts did this pass
actually cover" — the first question after `DISK_REAPER_REPOS` changes.

⛔ `freed_mb_<class>` reads **`unmeasured`** instead of a number when `df` could not answer for that
class, and **`not-run`** when the class never ran at all (a missing delegate, no repo to scan). Neither
is a zero: the pass prints `freed_df=unmeasured` and records the classes in `freed_mb_unmeasured=` plus
the `detail` line. A reader must treat both sentinels as "no measurement", never as a byte count (the
supervisor prints the raw value; the total is the sum of the classes that WERE measured).

`watchdog=` names the mechanism that bounded the pass (`timeout`, `gtimeout` or
`internal`, see **Bounded execution** above), so "the bound was real" is answerable
from the record on macOS too.

`cloud-cell-supervisor.sh status` prints the last pass, its age and the per-class
bytes. It prints `⛔` when the pass failed, is stale (older than
`DISK_REAPER_STALE_SECONDS`, default 7200) or has never run, and `⏸` when a delegate
DEFERRED the pass **and the record is fresh** — a deferred record that has aged past the
stale bound falls back to `⛔` with its age, because a timer that died after one deferral
must not read as a routine pause. (That arm names the last run by timestamp, `last=<iso>`; the ⏸ arm
additionally prints `(Ns ago)`.) A failure in one class does not hide the others'
reclaim — it names the class and its verdict.

Two lock properties the record's numbers rest on, each measured and pinned by a test:

* the token carries the owner's **pid**, parsed as a number — a contender that cannot
  prove the owner is alive may only break the lock once it is older than
  `LOCK_STALE_SECONDS`, and a live owner is never displaced (T9, T28);
* the lock's mtime is read from the **lock itself**, on GNU and BSD `stat` alike, so the
  staleness bound works when the pass was started as `bash -s` (T29).

`disk-reaper.sh --print-status` prints the same record; exit 0 ok, 3
failed/stale/never, 2 usage.

## Exit codes

⛔ Two different outcomes used to share exit 3 — "this reaper is broken" and "a delegate could not act
because the box is busy" — so the scheduled unit went **red every hour on a healthy cell** (measured:
`status=3/NOTIMPLEMENTED` on a pass that had reclaimed 441 MB). They are separate codes now, and the
systemd unit's `SuccessExitStatus` is written against this table (#2036). launchd has no success-exit
vocabulary, so on macOS the artifact's **last exit status** is the thing read against this table —
`fleet-health.py` maps it, and the pass record carries the alarm either way.

| code | meaning | unit `SuccessExitStatus` |
|---|---|---|
| 0 | pass completed, every selected class ok | accepted |
| 2 | usage — an unknown flag, an unknown `--only` class (including an EMPTY one), a non-numeric number, or a non-boolean `DISK_REAPER_DRY_RUN` | red |
| 3 | **fail-closed**: a delegate returned its own `3` (it could not measure, verify or reach a probe), a delegate is missing or a class had no repo to scan (per-class `verdict=misconfigured`, record `freed_mb_<class>=not-run`), the pass record could not be written, or a delegate could not run as asked (its `2` = bad arguments, `124` = timeout, `126`/`127` = no such binary). **Also a refusal at startup** when `scripts/lib/bounded.sh` is missing, `TB_TIMEOUT_BIN` is unusable, or a numeric seam (`DISK_REAPER_STALE_SECONDS`, `DISK_REAPER_LOCK_STALE_SECONDS`, the timeouts, the `du` budget) is not a number — or is a digit string too large for the shell to compare (`[ ... ]` parses with `strtoimax`, and an out-of-range value makes the COMPARISON error and take the `else` arm, so such a bound is refused rather than silently ignored: at most 9 digits, ~31 years) — no per-class line is printed there | red |
| 4 | a class completed but at least one removal FAILED; a lock directory that cannot be created at all; or the **pass record cannot be written** while the verdict was a green one (with no record there is no alarm channel, so 5/6 escalates to 4) | red |
| 5 | a class reported **work it would do but did not act on it** (over bound). In an APPLY pass it is ranked with a fail-closed class, because nothing was reclaimed for a real condition | red in apply (`0 5 6` is not the armed set), accepted in a `--report-only` render, where 5 IS the dry run's job |
| 6 | a **delegate DEFERRED** the pass: it ran, declined to act, and claimed nothing — a live tool holds the cache (`pi-cache-reap.sh` `7`), another cache pass holds its lock (`pi-cache-reap.sh` `4`) — or **this pass did not run because another disk-reaper holds the lock** (benign; no record is written and the previous one stands) | accepted |

Severity within one pass: **3 > 4 > 6 > 5 > 0** — encoded once, in `_rc_rank`. The unit's colour answers
*is a human needed now*; the **pass record** answers *is this box being reaped, and how much did the
last pass free* — and it is the record that the supervisor and `tools/fleet/fleet-health.py` alarm on.

**The mapping is PER CLASS, because the owners' exit vocabularies disagree.** `4` is the sharpest
example: in `pi-cache-reap.sh` it means *did not run, another pass holds the lock* (benign), while in
`reap-lane-venvs.sh` and `pi-reap-worktrees.sh` it means *a removal FAILED*. And `3` means
**fail-closed in all three** — never "the box was busy". So:

| delegate code | uv class | venv class | worktree class |
|---|---|---|---|
| `3` | 3 (red) | 3 (red) | 3 (red) |
| `4` | 6 (deferred) | 4 (red) | 4 (red) |
| `5` | 5 (kept) | 5 (kept) | 5 (kept) |
| `7` | 6 (deferred) | 3 (red) | 3 (red) |
| anything else | 3 (red) | 3 (red) | 3 (red) |

**Why 3 and 6 are different codes — and why that split had to be made in the OWNER.** Only a code that
means *"ran, declined, claimed nothing"* may be green. That includes the busy-cell deferral #2036 is
about, so `pi-cache-reap.sh` gained `7` for it rather than the reaper reinterpreting its `3`: treating
every delegate `3` as a refusal would reclassify genuine breakage as green, and a reaper that cannot
prove any lane dead would then read as a succeeding hourly job — the inert-enforcer false PASS this
whole feature exists to remove (measured: `PS_BIN=/nonexistent` → venv class `exit 3` → red, and it must
stay red). The pass **record** is the verdict channel in both cases (`ok=0`, and `--print-status` exits
3): the unit stays green for `6`, and `cloud-cell-supervisor.sh status` prints `⏸ … DEFERRED` for a
fresh deferral and `⛔ … NOT HEALTHY` for `3`/`4`.

⚠️ **`fleet-health.py` does NOT alarm on a fresh `5`/`6` record** — deliberate (it was the measured
false-red on every busy cell), so a delegate that refuses PERMANENTLY reads unit-green and
fleet-health-quiet, with the `⛔` only in `cloud-cell-supervisor.sh status`. The readiness gate in
`install-disk-reaper-timer.sh --status` applies the same allow-list and is what a bring-up reads.

⚠️ **This departs from issue #2036's literal fix, and the departure is deliberate.** #2036 proposed
`SuccessExitStatus=0 5 6` with `3 = misconfigured, 6 = a delegate refused`. That mapping assumed a
delegate's `3` means "the box was busy"; in all three owners it means "I could not do the work", so the
literal fix would have greened genuine breakage. What #2036 was actually about — a routine deferral on
a busy cell must not red the unit — is met by `6` alone. The same sentence sits in the unit template,
next to the directive it explains.

A delegate's `exit 5` — over the class's own floor — is **kept**, never dropped: in an apply pass it
means the condition the floor exists to surface is still present (and it is ranked with `3`, because
nothing was reclaimed); in a dry run it is informative (`ok=1`). In an apply pass it comes from
`reap-lane-venvs.sh`, which exits `5` when the pass finishes with free space **below its own free-disk
floor** (#1949); `pi-cache-reap.sh` gates its own `5` on dry-run. Before #2156 `worst_rc` DROPPED that
`5`, so the venv class recorded `rc=0 verdict=ok` for exactly the state the floor exists to make
visible.

## Scheduling — one install verb, both platforms (#2048 / #2058)

`scripts/install-disk-reaper-timer.sh` converges the SAME pass on whichever scheduler
the box has:

| platform | artifact | cadence |
|---|---|---|
| Linux | `eldato-disk-reaper.service` + `.timer` (systemd) | `OnCalendar=hourly`, `Persistent=true` |
| macOS | `~/Library/LaunchAgents/com.eldato.disk-reaper.plist` (launchd) | `StartInterval=3600` (+ one pass at load) |

On macOS the job is started with the checkout's own interpreter through
`pi-reap-worktrees-launchd.py`, not with `bash`: **TCC is per-binary**, and a
launchd-spawned `bash`/`git` cannot read a repo under `~/Documents`, so a `bash` agent
would fail the venv and worktree classes closed every hour while `launchctl list`
showed a healthy job. No usable interpreter is a **refusal at install time**, never a
degraded job.

The template lives in `templates/launchd/reaper/`, deliberately outside
`templates/launchd/` (which `install-launchd.sh` installs wholesale with no
arguments and a different placeholder set).

⛔ ON A MAC THIS INSTALLER IS RUN BY HAND TODAY. `pi-bootstrap/setup.sh` runs `install-launchd.sh` on
the Darwin path, and that installer deliberately does not own `templates/launchd/reaper/` (its
placeholder set differs) — so the consolidated pass reaches a Mac only when someone runs
`scripts/install-disk-reaper-timer.sh --install` there. Wiring it into the setup path is the follow-up
on #2048.

Both artifacts are rendered **armed** (`--apply`) — this feature was explicitly instructed to run
unattended — and `--report-only` renders `--dry-run` instead, so disarming is one verb rather than a
hand-edit that the next bring-up reverts (#1678). `--status` on BOTH platforms is the cell's readiness
gate: it exits non-zero when the job is not installed/loaded, when the timer is enabled but INACTIVE,
when the last run has never happened, and when the pass record's own `rc` is one a human must look at
(3/4) or is STALE — a stale record is an alarm even when its `rc` was benign.

## Tests

`scripts/disk-reaper.test.sh` — 375 assertions, run by the `disk-reaper` shard of
`run-bash-shards.sh`:

| | |
|---|---|
| T1–T4 | dry-run removes nothing and names every candidate with a byte count; a live-cwd worktree is never selected (and IS once its holder is gone); a merged checkout is selected; the size budget is honoured |
| T5 | a missing delegate is fail-closed and recorded as failed |
| T6 | the entry point deletes no sink itself (static pin: its only recursive delete is the lock) |
| T7 | the pass record answers "did it succeed, and how much did it free" without a log — including the VALUES of `classes=` and `repos=` (a label with an empty value used to pass), and an unparseable/absent `epoch=` is `stale`, never `ok` |
| T8 | the schedule installs, is idempotent, and is armed — and `--install --dry-run` leaves a FRESH unit dir empty and enables nothing (the doc's "there is no disarm flag" rests on that) |
| T9 | a pass that **loses** the lock never releases the live owner's lock |
| T10 | an `--only` list naming nothing is refused — including the explicitly EMPTY one, which the guard used to skip (a green, recorded pass over zero sinks) |
| T11 | a dry run records 0 bytes freed (it removed nothing) |
| T12 | the installer's `--dry-run` changes nothing; a set-but-missing `$DISK_REAPER` is refused |
| T13 | the bounded-execution resolution ORDER is pinned (`timeout` -> `gtimeout` -> internal watchdog) with a PATH holding only the case's own stub (#2046) |
| T14 | a host with neither binary still **classifies** (candidates found, rc=5) and names the fallback; a stub `timeout` on PATH is preferred, and then the report gains no provenance line (#2046) |
| T15 | a missing `scripts/lib/bounded.sh`, or an unusable `TB_TIMEOUT_BIN`, is a **refusal at startup** (exit 3, no per-class line, no pass record) — never per-class `fail-closed` (#2046) |
| T16 | a delegate's exit **5** is kept, never swallowed: an APPLY pass below the stated floor records `ok=0` and is RED (`rc=3`, ranked with a fail-closed class because nothing was reclaimed), while the same code in DRY-RUN stays informative (`ok=1`, pass 5) (#2156) |
| T17 | a delegate's fail-closed `3` stays RED, while a **missing** delegate is `misconfigured` with `freed_mb=<class>=not-run` — three different remedies, asserted as a set |
| T18 | a non-numeric `REAP_VENV_MIN_AGE_SECONDS` is refused by the owner (exit 2) and a non-numeric `DISK_REAPER_VENV_MIN_AGE`/`--min-age` is refused by the pass, reaping nothing (#2158) |
| T19 | **APPLY mode, one pass, two worktrees, one holder**: a dead lane's `.venv` is reclaimed and a live lane's is never; the live worktree survives and the owner names the witness (#2159/#1932) |
| T19b | an **unreadable liveness probe** fails the class closed and removes nothing — absence is never read as staleness |
| T20 | the same install verb converges the pass on **macOS** too: label, `--apply`, hourly, repo, pinned delegates, TCC launcher, bootstrap; `--report-only` disarms it; a missing interpreter is a refusal |
| T21 | a unit rendered from **transient scratch** (`/tmp/tmp.XXXX`) is refused at install time — the measured 127-every-tick unit |
| T22 | an agent that is **not loaded after install** is a failure, never a silent skip |
| T23 | the **uv family's exit 4 is "lock held"** (recorded `deferred`), not "a removal failed", while the venv owner's 4 still is — and neither mapping is flattened into the other |
| T24 | the macOS launch path (`bash -s`, **no `BASH_SOURCE`**) resolves the pinned bounded library and delegates, and refuses loudly when the pin is absent |
| T25 | `--status` exits **1** when the launchd agent is not installed (the cell's readiness gate reads that code) |
| T26 | an install whose reaper has **no sibling `lib/bounded.sh`** is refused — both artifacts pin it, and without it no class runs at all |
| T27 | `fleet-health.py` reads the **pass record on every host** (the launchd exit table alone is reported not-applicable where there is no launchd), so a refused or silent pass is an alarm on Linux cells too |
| T28 | a **live** lock holder is never displaced, even when the lock directory looks older than the staleness bound (the token's pid is parsed as a number) |
| T29 | `--help` and the staleness bound work under the `bash -s` start the macOS agent uses, where `$0` is the bash binary's path and `${BASH_SOURCE[0]}` is empty |
| T30 | `launchctl` that exists but **cannot answer** is an abstention alarm, never "no reapers" |
| T31 | the installed plist is **well-formed XML** (a doubled dash in a comment is refused, not shipped) |
| T32 | the **arming seam is validated**: `DISK_REAPER_DRY_RUN=true` is refused, never silently armed |
| T33 | a launchd **disarm is verified** — an agent still loaded after `bootout` is a failure, not "uninstalled" |
| T34 | a **stale pass record** (`epoch` past `DISK_REAPER_STALE_SECONDS`) is an alarm, not a healthy read |
| T35 | a bad env floor does not block `--print-status`, and a valid `--min-age` overrides it |
| T36 | an **empty** `--only` is refused (zero classes is a false PASS), while an empty *env* value falls back to the default list |
| T37 | the numeric seams are validated, and a record whose `epoch` cannot be read is **stale**, never ok |
| T38 | a **recycled lock pid** (same pid, different start time) does not block the pass for ever, while a matching start time is a live holder (exit 6, deferred) |
| T39 | an **enabled-but-inactive** timer does not certify readiness (`--status` exits 1), and a record whose `rc` is 3/4 — or that is stale — fails readiness while 5/6 do not |
| T40 | fleet-health survives an unreadable seam and an unageable record — both are alarms, not tracebacks |
| T41 | `--print-status` validates its OWN staleness seam before answering (a non-numeric bound must never read `ok`) |
| T42 | an unmeasurable reclaim is labelled (`freed_mb_unmeasured=`, `detail=`), never written as a measured 0 |
| T43 | a checkout under a path containing a space is measured at its real path, not truncated at the space |
| T44 | `--status` fails when the pass record **cannot be judged at all** (`--print-status` produced no status line), on both platforms |
| T45 | fleet-health reads the record at **`DISK_REAPER_STATE_DIR`**, not a hardcoded HOME path — one record, one verdict |
| T46 | a lock directory that **cannot be created at all** (full/read-only state dir) is a failure (4), never "another pass holds the lock" (6) |
| T47 | a class that could not be **set up** records `verdict=misconfigured` + `freed_mb=not-run`, never a measured 0 |
| T48 | a non-numeric `DISK_REAPER_WT_AGED_DAYS` is refused on the **Darwin** install path too |
| T49 | the pass leaves **no probe scratch** behind — neither on a completed pass nor on a startup refusal |
| T50 | the installer REFUSES a system unit rendered from transient scratch space (the cells' hourly `127`), still installs through the explicit test override, the installed `SuccessExitStatus` is exactly `{0, 6}` (3, 4 and 5 are each asserted absent, with a positive control), and the three `Environment=…_REAPER=` delegate pins are present and absolute |
| T51 | the USER install target — reachable only when the sudo probe fails, and it used to route its file copy through sudo (so it could never install): the files land in `~/.config/systemd/user` with no sudo, every `systemctl` call keeps `--user`, an unconfirmed `Linger` refuses with the exact remedy, and `--uninstall` really removes them |
| T52 | the **venv class alone** clears a GONE lane's `.venv` and never a LIVE one's: one fixture, two worktrees, both envs aged, `--min-age 0`, so the only difference is a real cwd holder (#2159) |
| T53 | a delegate's exit code is neither swallowed nor mis-coloured, **per class**: a delegate's `3` is RED (never 6); uv `7` and uv `4` are deferrals (pass 6, `ok=0`, `verdict_uv=deferred`, detail naming the delegate's own code); venv `4` is a RED removal failure, never a deferral; `5` is RED in apply and informative in dry-run; `2` is red; a fail-closed class outranks a removal failure across two repos in **both** `--repo` orders, with both codes named in `detail=`; a uv deferral cannot mask a venv removal failure across classes; and the `7` row is asserted on BOTH sides — uv `7` defers, a venv delegate's out-of-vocabulary `7` is RED (#2156, #2036) |
| T54 | the stale threshold and the help text: a non-numeric `DISK_REAPER_STALE_SECONDS` is refused on read (never a green `status=ok`), and `--help` still reaches the end of the header — it carries the DEFERRED exit-code bullet and the watchdog pin, so the derived range is what is printing |

⚠️ **Two shards cannot be relied on as a local green.** `scripts/reap-lane-venvs.test.sh` is
flaky (~4%: one invocation fail-closes with `tmux probe FAILED` and empty probe output, so every §B1
assertion misses at once — reproduced on `origin/main`, fail-CLOSED, no deletion). And
`scripts/pi-cache-reap.test.sh` cannot be executed from inside a linked worktree at all
(`main-worktree-guard` #709/#2175 refuses it as `script-indirection`), so **CI is the only instrument
for that shard**. A lane that runs the two suites that work and stops is not green — it is partially
verified.

`scripts/reap-lane-venvs.test.sh` §E1b/§E1c pin the path-boundary rule the dead-vs-live question rests
on — a holder one directory DOWN keeps the env, and a process one directory OVER (a sibling prefix) is
NOT a holder — and §H pins the age floor's validation: a non-numeric `REAP_VENV_MIN_AGE_SECONDS` is
refused (exit 2) with nothing removed, and the same fixture is kept by a valid floor and reaped with
the floor lifted — so the KEEP is the floor's doing rather than an inability to delete (#2158).

T9, T10 and T12 were each red on the build that preceded the fresh-context review
that found them.

## Deliberately out of scope

* **`node_modules`** — still reclaimed by the supervisor's existing sweep; it is not
  on the measured offenders and would need its own liveness proof.
* **The uv cache is never deleted wholesale** — the owner prunes and evicts entries
  under a size bound, because a venv hardlinks into it.
* **Removing branches** — `git worktree remove` deletes checkouts; branch refs are
  never deleted by any class.
* **Retiring the per-sink Mac jobs** — `com.tortoise.worktree-reaper` and
  `com.eldato.pi-cache-reap` keep their own launchd jobs. The consolidated pass is now
  scheduled alongside them (`com.eldato.disk-reaper`), and retiring them is a follow-up
  that needs a measured window on a Mac — which the Linux cells this was built for
  cannot provide.

## Measured evidence (2026-10-18, cell-3, this box)

Dry-run, `--repo /tmp/cell-t3`: `WOULD-PRUNE class=uv 5765MB -> 2048MB bound`,
12 worktree candidates on the agent-infra estate (364 MB `du`), nothing removed,
`df` unchanged (8317 MB free before and after).

Armed pass, `--repo /tmp/cell-t3 --repo /tmp/cell-ai`:

| class | outcome | bytes |
|---|---|---|
| worktree | 13 checkouts removed (12 agent-infra, 1 tortoise), branch refs retained | **+514 MB** (`df`) |
| venv | all live lanes kept (`live-cwd`), one env `too-recent` under the 30-min floor | 0 MB |
| uv | **refused**: a live `uv run pytest` held the cache, so nothing was evicted (the pre-PR label was `fail-closed`) | 0 MB |

`df` before `8317 MB` free → after `8833 MB` free (**+516 MB**), matching the
`freed_mb=515` record.

The **unattended** path was then proven end to end on the same box: the timer was
installed into `/etc/systemd/system`, enabled, and its service started directly
(`systemctl start eldato-disk-reaper.service`):

| class | outcome | bytes |
|---|---|---|
| venv | 2 lane envs reaped (`fix-8937`, lane finished; `fix-8969`, lane already in the merge chain, which runs in the main checkout) — the 5 live lanes kept | **+229 MB** (`df`) |
| worktree | 0 removed; every candidate preserved (`too-recent`, `dirty`, `live-process`) | +4 MB |
| uv | **refused**: a lane's `uv run pytest` held the cache, so nothing was evicted (the pre-PR label was `fail-closed`) | 0 MB |

`systemctl show -p ExecMainStatus` = `6` — **a delegate DEFERRED, so the unit is green and the
RECORD is the alarm** (see **Exit codes**) — and the pass record carried `freed_mb=233`,
`ok=0`, `verdict_uv=deferred detail=pi-cache-reap.sh exited 7`. (That measurement predates the
`7`/`deferred` split: the same run then recorded `verdict_uv=fail-closed` and exit 3, which painted
the unit red hourly on a healthy cell — that is #2036.)

⛔ **On a busy cell, expect `verdict_uv=deferred` (pass `6`, `ok=0`).** The cache owner declines while
any `uv` process is live (it cannot know what that process is resolving against — #1987) and says so
with its own `7`; lanes run `uv run pytest` continuously, so the bound is enforced in the gaps between
lanes, not on every hourly tick. ⚠️ `verdict_uv=fail-closed` in such a record is a DIFFERENT thing and
must not be read as the expected background: it means the cache could not be measured or verified, or
its safe half FAILED — the cache is not merely busy.

The uv class then ran in a gap, and it is the clearest evidence for the accounting
rule in this document:

| | |
|---|---|
| uv cache apparent size | 5761 MB → **1 MB** (prune + escalation under the 2048 MB bound) |
| `df` actually gained | **+74 MB** (`9860 MB` → `9936 MB` free) |
| verdict | `refused` (the pre-PR label was `fail-closed`) — the owner **refuses to claim** a 5761 MB reclaim when the filesystem gained under 50% of it |

That gap is the hardlink rule: the cache's blocks were already owned by the live lane
venvs, so emptying the cache freed almost nothing real (and the next `uv sync` will
copy rather than hardlink). A reaper that reported the `du` number would have claimed
5.7 GB for 74 MB. The class-1 bound itself is proven with real bytes by
`disk-reaper.test.sh` T4/T7 on a fixture cache that has no hardlinks.

Safety on live estate, both passes: `live-process` and `live-cwd` rows were preserved
(including the running controller's own harness pin and every active lane worktree);
the only venv reaped under a live lane belonged to one already in the merge chain,
which runs in the main checkout and needs no env. A fixer that is merely *between
commands* has no witness by construction (#1949's declared limit): its env is
regenerable with `uv sync`, and its WORKTREE is never touched (open PR + dirty gates).
