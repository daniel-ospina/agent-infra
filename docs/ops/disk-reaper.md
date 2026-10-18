---
title: "Disk reaper — one scheduled pass over the three disk sinks (#2032)"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-10-18
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-2032, issue-2048, disk-reclaim, uv-cache, lane-venvs, worktrees, systemd, launchd, macos
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
  A zero or negative delta is reported as 0 with the raw delta, never hidden.

## Safety property

A live holder is **never** selected. The witnesses are mechanical and fail closed:

* `live-tmux-pane` — a tmux pane whose `pane_current_path` resolves inside the
  worktree (the lane is alive even between turns);
* `live-cwd` — any process whose cwd is inside the path (catches
  `bash -c 'cd <wt> && pytest'`, whose argv never names the path);
* `live-argv` — any process whose command line names the path.

A probe that cannot be evaluated is a refusal (`exit 3`), not a pass. The worktree
owner additionally requires the checkout to be **clean** (uncommitted work is never
destroyed), **reachable** (its commits survive the checkout's deletion), and not an
open-PR head.

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

## Scheduling — ONE install verb, TWO schedulers (#2032, #2048)

`scripts/install-disk-reaper-schedule.sh` installs the pass on **both** platforms the fleet runs on.
It is one verb because the fleet is one system: a Mac and a cell differ in *what* wakes the pass, not
in what the pass is.

| platform | artifact | installed by | interval |
|---|---|---|---|
| Linux cell | `templates/systemd/eldato-disk-reaper.{service,timer}` → `eldato-disk-reaper.timer` | `cloud-cell-bringup.sh --check` (which passes `--apply`) | hourly, `Persistent=true` |
| macOS | `templates/launchd/com.eldato.disk-reaper.plist.tmpl` → `~/Library/LaunchAgents/com.eldato.disk-reaper.plist` | `pi-bootstrap/setup.sh` on Darwin | hourly, `StartInterval=3600`, `RunAtLoad` |

Both run **the same entry point with the same flags** (`disk-reaper.sh` + one mode flag). The only
other platform difference is the *binary-resolution seam*: a launchd-spawned `bash` cannot read a
script, or a repo, under `~/Documents` (TCC is per-binary — #427, and the control experiment is in
#1095), so the Darwin job starts the checkout's own interpreter on the farmed launcher
`pi-reap-worktrees-launchd.py`, which hands **the same pass file** to bash on stdin. Without it the
Mac's venv and worktree classes would fail closed on every pass.

The macOS template is named `*.plist.tmpl` on purpose: `install-launchd.sh` renders
`templates/launchd/*.plist`, and this job needs machine state that installer does not carry (the pass
path, the mode flag, the state dir, the repos). The suffix keeps the job out of that glob, so it
cannot be bootstrapped half-rendered with a literal placeholder as its argument — **one installer owns
each job**.

Idempotency: a second install compares the rendered artifact byte for byte and changes nothing
(systemd additionally `daemon-reload`s, which is free). An unscheduled box is a **FAIL the bring-up
reports** — `--status` exits 1, and on the Mac `pi-bootstrap/setup.sh` finishes with a non-zero exit
naming the remedy. A box with neither scheduler fails loudly with the remedy; a scheduled-but-never-run
reaper is exactly the false PASS this feature removes.

### Arming is a separate, visible step (#1678, owner ruling 2026-10-11)

The installer **ships report-only**: with no mode flag the installed job carries the pass's dry-run
flag, and `--status` reports `armed=dry-run`. `--apply` installs the armed job, and the flag lands
*inside* the unit/plist, so the answer is readable from the scheduled artifact — never from an
environment default, and never inferred from the command that built it. Re-running with `--dry-run`
puts the report-only mode back: reversible, one copy, nothing to drift.

The cell's bring-up passes `--apply` **explicitly** (that feature was instructed to run unattended, and
the arming is now one visible line in `cloud-cell-bringup.sh` plus the `ExecStart` it renders). A Mac
ships report-only until the owner arms it.

### A changed pass reloads its job (#1738)

An edit to a script a scheduled job runs is silent until that job is reloaded — the loaded job keeps
the program and environment it was bootstrapped with, which is how an armed reaper becomes inert while
still reporting itself installed. So the installer stamps the pass's **SHA-256** in
`$DISK_REAPER_STATE_DIR/disk-reaper.schedule` and forces a reload when the bytes change, even when the
unit text is byte-identical:

```
pass_changed=yes reload_reason=pass-changed     # launchd: bootout + bootstrap; systemd: daemon-reload + restart
pass_changed=no  reload_reason=none             # a true no-op
```

`--status` prints `pass_sha=`, `pass_drift=in-sync|CHANGED since install|no-stamp` so a stale install
is visible on the box instead of being inferred from a log.

## Status — the supervisor answers "did it succeed, and how much did it free"

Every pass writes `$DISK_REAPER_STATE_DIR/disk-reaper.status` (default
`$HOME/.pi/agent/state`), atomically, as `key=value`:

```
mode=apply ok=0 rc=3 classes=uv,venv,worktree watchdog=internal
freed_mb=515 freed_mb_uv=1 freed_mb_venv=0 freed_mb_worktree=514
verdict_uv=fail-closed verdict_venv=ok verdict_worktree=ok
would_free_mb_* candidates_* detail=pi-cache-reap.sh exited 3
```

`watchdog=` names the mechanism that bounded the pass (`timeout`, `gtimeout` or
`internal`, see **Bounded execution** above), so "the bound was real" is answerable
from the record on macOS too.

`cloud-cell-supervisor.sh status` prints the last pass, its age and the per-class
bytes, and prints a `⛔` line when the pass failed, is stale (older than
`DISK_REAPER_STALE_SECONDS`, default 7200) or has never run. A failure in one class
does not hide the others' reclaim — it names the class and its verdict.

`install-disk-reaper-schedule.sh --status` answers the *scheduling* half in one vocabulary on both
platforms, then prints that same record:

```
platform=darwin|linux        scheduler=launchd|systemd     job=<label|unit>
installed=yes|no             enabled=enabled|disabled      active=active|inactive
armed=apply|dry-run          interval_seconds=3600         next_run=<...>|unknown
last_exit=<n>|unknown        pass=</path/to/disk-reaper.sh>
pass_sha=<...>               pass_drift=in-sync|CHANGED since install
--- pass record ---
  status=ok|stale|failed|never  mode=apply|dry-run  freed_mb=<n>  ...
pass_status_rc=0|3
```

Exit codes: `0` scheduled and loaded · `1` not scheduled (the bring-up's FAIL). Whether the last pass
was *clean* is reported in `pass_status_rc` and the record, **not** folded into this verb's exit code:
a fresh box whose first pass has not fired yet is scheduled and healthy at the scheduling question.

`disk-reaper.sh --print-status` prints the same record; exit 0 ok, 3
failed/stale/never, 2 usage.

## Exit codes

| code | meaning |
|---|---|
| 0 | pass completed, every selected class ok |
| 2 | usage |
| 3 | fail-closed: a delegate is missing, failed closed, or a class had no repo — nothing is claimed for it; **also a refusal at startup** when `scripts/lib/bounded.sh` is missing or `TB_TIMEOUT_BIN` is unusable (no per-class line is printed in that case) |
| 4 | a class completed but at least one removal failed (or another pass holds the lock) |
| 5 | dry-run only: a class reported work it would do |

## Tests

`scripts/disk-reaper.test.sh` — 94 assertions, run by the `disk-reaper` shard of
`run-bash-shards.sh`:

| | |
|---|---|
| T1–T4 | dry-run removes nothing and names every candidate with a byte count; a live-cwd worktree is never selected (and IS once its holder is gone); a merged checkout is selected; the size budget is honoured |
| T5 | a missing delegate is fail-closed and recorded as failed |
| T6 | the entry point deletes no sink itself (static pin: its only recursive delete is the lock) |
| T7 | the pass record answers "did it succeed, and how much did it free" without a log |
| T8 | the schedule installs, is idempotent, and is armed |
| T9 | a pass that **loses** the lock never releases the live owner's lock |
| T10 | an `--only` list naming nothing is refused (never a healthy no-op) |
| T11 | a dry run records 0 bytes freed (it removed nothing) |
| T12 | the installer's `--preview` changes nothing; a set-but-missing `$DISK_REAPER` is refused |
| T13 | the bounded-execution resolution ORDER is pinned (`timeout` -> `gtimeout` -> internal watchdog) with a PATH holding only the case's own stub (#2046) |
| T14 | a host with neither binary still **classifies** (candidates found, rc=5) and names the fallback; a stub `timeout` on PATH is preferred, and then the report gains no provenance line (#2046) |
| T15 | a missing `scripts/lib/bounded.sh`, or an unusable `TB_TIMEOUT_BIN`, is a **refusal at startup** (exit 3, no per-class line, no pass record) — never per-class `fail-closed` (#2046) |

`scripts/install-disk-reaper-schedule.test.sh` — 120 assertions, its own `run-bash-shards.sh` shard —
owns the SCHEDULE (`disk-reaper.test.sh` owns the pass):

| | |
|---|---|
| T1 | one verb, two schedulers: both backends are rendered in one run and their **mode flags are compared**, so "same flags" is checked, not claimed |
| T2 | idempotent on both — a second install is a no-op **and reloads nothing** (a bootstrap per bring-up would re-run the pass) |
| T3 | report-only by default; `--apply` arms; `--status` reads the arming off the **installed** artifact; `--dry-run` reverts |
| T4 | a changed pass reloads its job (#1738) on both backends, with `reload_reason=pass-changed` |
| T5 | one status vocabulary: the `key=` set is identical on both platforms and the **pass record block is byte-identical** |
| T6 | every impossible state is a loud refusal: no scheduler, temp HOME on Darwin (#446), missing pass, unresolved placeholder, malformed plist |
| T7 | the Mac does not get a second pass: the job's target is the pass, no per-class script is named, and the `*.plist.tmpl` suffix keeps the job out of `install-launchd.sh`'s glob |
| T8 | `--uninstall` is reversible and removes the stamp; `--status` then exits 1 |
| T9 | static pins: every `rm -rf` in the installer removes only a mktemp dir it made, and the shipped default is the report-only flag |

T9, T10 and T12 were each red on the build that preceded the fresh-context review
that found them.

## Deliberately out of scope

* **`node_modules`** — still reclaimed by the supervisor's existing sweep; it is not
  on the measured offenders and would need its own liveness proof.
* **The uv cache is never deleted wholesale** — the owner prunes and evicts entries
  under a size bound, because a venv hardlinks into it.
* **Removing branches** — `git worktree remove` deletes checkouts; branch refs are
  never deleted by any class.
* **The per-class macOS jobs** — `com.eldato.pi-cache-reap` (the `uv` class) and
  `com.tortoise.worktree-reaper` (the `worktree` class) are **RETIRED** in favour of the
  consolidated job, which runs the same owners through this pass (#2048). Each ran the same
  owner script, so no delete rule changed — only how many clocks ran it, and how many report
  formats existed. `com.tortoise.branch-reaper` (local branch refs) and
  `com.eldato.pi-session-reaper` (idle pi processes) are **not** disk-sink classes and keep
  their own jobs: one owner per class, and no second implementation of any of them.

## Measured evidence (2026-10-18, cell-3, this box)

Dry-run, `--repo /tmp/cell-t3`: `WOULD-PRUNE class=uv 5765MB -> 2048MB bound`,
12 worktree candidates on the agent-infra estate (364 MB `du`), nothing removed,
`df` unchanged (8317 MB free before and after).

Armed pass, `--repo /tmp/cell-t3 --repo /tmp/cell-ai`:

| class | outcome | bytes |
|---|---|---|
| worktree | 13 checkouts removed (12 agent-infra, 1 tortoise), branch refs retained | **+514 MB** (`df`) |
| venv | all live lanes kept (`live-cwd`), one env `too-recent` under the 30-min floor | 0 MB |
| uv | **fail-closed**: a live `uv run pytest` held the cache, so nothing was evicted | 0 MB |

`df` before `8317 MB` free → after `8833 MB` free (**+516 MB**), matching the
`freed_mb=515` record.

The **unattended** path was then proven end to end on the same box: the timer was
installed into `/etc/systemd/system`, enabled, and its service started directly
(`systemctl start eldato-disk-reaper.service`):

| class | outcome | bytes |
|---|---|---|
| venv | 2 lane envs reaped (`fix-8937`, lane finished; `fix-8969`, lane already in the merge chain, which runs in the main checkout) — the 5 live lanes kept | **+229 MB** (`df`) |
| worktree | 0 removed; every candidate preserved (`too-recent`, `dirty`, `live-process`) | +4 MB |
| uv | **fail-closed**: a lane's `uv run pytest` held the cache, so nothing was evicted | 0 MB |

`systemctl show -p ExecMainStatus` = `3` (the pass is not reported as clean while a
class failed closed), and the pass record carried `freed_mb=233`,
`verdict_uv=fail-closed detail=pi-cache-reap.sh exited 3`.

⛔ **Expect `verdict_uv=fail-closed` on a busy cell.** The cache owner preserves the
whole cache while any `uv` process is live (it cannot know what that process is
resolving against — #1987). Lanes run `uv run pytest` continuously, so the bound is
enforced in the gaps between lanes, not on every hourly tick.

The uv class then ran in a gap, and it is the clearest evidence for the accounting
rule in this document:

| | |
|---|---|
| uv cache apparent size | 5761 MB → **1 MB** (prune + escalation under the 2048 MB bound) |
| `df` actually gained | **+74 MB** (`9860 MB` → `9936 MB` free) |
| verdict | `fail-closed` — the owner **refuses to claim** a 5761 MB reclaim when the filesystem gained under 50% of it |

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
