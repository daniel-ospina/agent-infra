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
This feature was explicitly instructed to run unattended on the cell, so the unit's
`ExecStart` carries `--apply`; the arming is visible in the installed file, not
hidden in an environment default. Re-run the installer with `--dry-run` to install a
report-only unit.

The timer's environment is rendered from this box (`HOME`, `PATH`, repos that git
confirms exist), so the pass never depends on a login shell. The venv and worktree
classes need a repo; a pass with none **fails closed** rather than scanning nothing.

## Status — the supervisor answers "did it succeed, and how much did it free"

Every pass writes `$DISK_REAPER_STATE_DIR/disk-reaper.status` (default
`$HOME/.pi/agent/state`), atomically, as `key=value`:

```
mode=apply ok=0 rc=3 classes=uv,venv,worktree
freed_mb=515 freed_mb_uv=1 freed_mb_venv=0 freed_mb_worktree=514
verdict_uv=fail-closed verdict_venv=ok verdict_worktree=ok
would_free_mb_* candidates_* detail=pi-cache-reap.sh exited 3
```

`cloud-cell-supervisor.sh status` prints the last pass, its age and the per-class
bytes, and prints a `⛔` line when the pass failed, is stale (older than
`DISK_REAPER_STALE_SECONDS`, default 7200) or has never run. A failure in one class
does not hide the others' reclaim — it names the class and its verdict.

`disk-reaper.sh --print-status` prints the same record; exit 0 ok, 3
failed/stale/never, 2 usage.

## Exit codes

| code | meaning |
|---|---|
| 0 | pass completed, every selected class ok |
| 2 | usage |
| 3 | fail-closed: a delegate is missing, failed closed, or a class had no repo — nothing is claimed for it |
| 4 | a class completed but at least one removal failed (or another pass holds the lock) |
| 5 | dry-run only: a class reported work it would do |

## Tests

`scripts/disk-reaper.test.sh` — 65 assertions, run by the `disk-reaper` shard of
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
| T12 | the installer's `--dry-run` changes nothing; a set-but-missing `$DISK_REAPER` is refused |

T9, T10 and T12 were each red on the build that preceded the fresh-context review
that found them.

## Deliberately out of scope

* **`node_modules`** — still reclaimed by the supervisor's existing sweep; it is not
  on the measured offenders and would need its own liveness proof.
* **The uv cache is never deleted wholesale** — the owner prunes and evicts entries
  under a size bound, because a venv hardlinks into it.
* **Removing branches** — `git worktree remove` deletes checkouts; branch refs are
  never deleted by any class.
* **A macOS schedule** — Macs keep their existing launchd jobs
  (`com.tortoise.worktree-reaper`, `com.eldato.pi-cache-reap`); this entry point and
  its timer are the **cell** answer, which is where the measured exhaustion happened.

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
