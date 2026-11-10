---
title: "Disk reaper — one scheduled pass over every disk sink that stops a cell (#2032, #2542)"
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
the sinks that exhaust a cell's disk. The **scheduled** entry point is
`scripts/disk-reaper-run.sh`, which wraps it and supplies exactly what a
timer-started process does not inherit: `HOME` and `keys.env`, the REAL `gh`
binary by absolute path (rejecting any `gh-shim`/`gh-limit` interposer and
unsetting a poisoned `AGENT_GH_REAL`), `AGENT_GH_GATE_NO_WAIT=1`, and
`REAP_WT_GH_TIMEOUT=120`. Without that wrapper the worktree class fails CLOSED
on a box whose only `gh` on PATH is the interactive pacing shim (#2354). Each class has
one owner (one class has two, for the two shapes of one sink), and the owners are the
only code that deletes:

| class | owner (policy) | reclaims |
|---|---|---|
| `uv` | `scripts/pi-cache-reap.sh` (#1987) | machine-global uv/npm/pip caches, bounded **by size** (`CACHE_REAP_MAX_MB`, default 2048 per cache), prune-then-escalate |
| `venv` | `scripts/reap-lane-venvs.sh` (#1932 / #1949) | per-worktree `.venv`s whose lane is gone, proven by three liveness witnesses; fail-closed |
| `worktree` | `scripts/pi-reap-worktrees.sh` (#1095) **+** `scripts/reap-abandoned-worktrees.sh` (#2542) | the first arm: clean, reachable, holder-free checkouts; merged heads are exempt from the 7-day floor. The second arm: abandoned LINKED worktree directories under a scratch root — age > 180 min **and** no live process's cwd/exe inside (see *The two classes that were missing* below) |
| `duplicate-install` | `scripts/reap-duplicate-installs.sh` (#2542) | surplus copies of the same tool install (a runner family): only copies **proven idle** are removed, the newest is always kept, the last copy is never removed |
| `runner-work` | `scripts/reap-runner-work.sh` (2026-10-28, #3043 is the sibling sink) | the CI runners' `_work` checkout dirs — **19 G** measured in six dirs on a box at 98%: an entry is removed only when **nothing in it (its own top dir included) has been written for longer than the mtime floor** (default 7200 s — the only empirically validated value;
the shipped 3600 s was half of it — see the class note below), and the vendor's whole under-`_work` namespace is deliberately retained — `_temp`, `_actions`, `_tool`, `_update`, plus **any `_`-prefixed name the table has not seen** — from ONE declared table (`WORK_LAYOUT`), never a second literal list |

## Why one entry point

The fleet already ran ad-hoc reap passes from **several** scheduled places —
among them `cloud-cell-supervisor.sh prune` (the one whose cache arm is ARMED:
it reaches `pi-cache-reap.sh --apply` at `cloud-cell-supervisor.sh:4875`,
unattended under pressure), the hourly cache pass inside `orch-loop.sh`, the
`pi-reap-worktrees-launchd.py` unit (macOS only, so cells had nothing), the
hourly `com.eldato.pi-cache-reap.plist` unit, and the 6-hourly
`com.tortoise.worktree-hygiene.plist` (whose step 1 is `pi-reap-worktrees.sh`).

**Most of those shipped DISARMED, deliberately** (#1678: "the reaper may run
unattended; arming it may not"): the loop's cache pass hardcodes `--dry-run`
(`scripts/orchestrator-harness/orch-loop.sh:4246`) and so do both unit
templates — `com.eldato.pi-cache-reap.plist:89`,
`com.tortoise.worktree-reaper.plist:129` — where arming is an owner edit of that
argument plus an `install-launchd.sh` re-run; `worktree-hygiene` instead renders
`--apply` only on an armed box, `--dry-run` otherwise, from
`{{WORKTREE_HYGIENE_MODE}}`, which `install-launchd.sh` resolves from
`~/.pi/agent/state/worktree-hygiene.armed`. So **of those legacy passes**, on a
default install only the `prune` path reclaims anything and the rest merely
report, which is the distinction this page exists to stop blurring. That is not
a statement about this page's own pass: on a cell the consolidated timer is
installed with `--apply` (`install-disk-reaper-timer.sh:108`, run
unconditionally by `cloud-cell-bringup.sh:2240`), so *it* does reclaim — the
scoped clause above is the legacy enumeration, not this script. No single one
answered *"is this box being reaped, and how much did the last pass free?"* —
and **no count is claimed here**, because a count is the claim
that made this page wrong in the first place: the point is not how many triggers
existed, it is that none of them could answer that question. This is the
consolidation: one scheduled pass, one pass record, one status line, and the
existing owners untouched except where a class needed a new policy (the
merged-head floor below).

⛔ **The merge-time teardown is NOT one of them — it is a manual convention, not an
automation.** An earlier version of this page (and of `scripts/disk-reaper.sh`'s
header) listed `cleanup-worktree.sh` *at merge time* as a fourth consolidated
trigger. It never was one: **no automation invokes it.** `merge-one.sh` performs no
worktree removal at all, `admin-merge.sh` removes only its own scratch worktree,
and an index-bounded `git grep -n 'cleanup-worktree' origin/main` finds the
script's only operational **caller** in a **manual step** —
`skills/commit-workflow/workflow/05-cleanup.md:20`, which a lane has to remember to
run. (Every other hit is prose or a test — the script's own usage line, comments,
a scoping doc, the guard extension's README, and guard tests that assert the script
is *refused* — never an executor.) So what the fleet has at
merge time is a convention a lane may forget, not a scheduled pass: this script
neither schedules it nor accounts for it, and a reader who saw it in the list above
would rightly stop asking why the disk still fills.

Wiring a real merge-time reaper in is deliberately **not** done here — see #3278's
plan comment §4: the mass such a hook cannot reach is the `no-pr` / `open-pr`
worktrees, which by definition have *not* merged, so a merge-time trigger would be
yet another reaper for bytes it can never take. The merge trigger that *does* exist
and *is* automated is `pi-reap-worktrees.sh` rule 4 (a checkout whose PR `MERGED`
at that exact head, exempt from the 7-day floor) — and it is one of the scheduled
passes above, not a merge hook.

Adding another copy of a delete rule would have been the easy path and is
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

* **dry-run**: per-candidate `du` (blocks occupied) for what *would* go. Whether a
  per-worktree `.venv` shares blocks with the uv cache — and so whether `du` counts
  the same blocks again and **over-states** what removal frees — is **PER MACHINE,
  not universal**. ⛔ The old universal claim ("a venv **hardlinks** into the uv cache,
  so `du` always over-states") was FALSIFIED 2026-10-16 (#1851). Measured regimes:
  APFS **clonefile** (`du` 22.0 MB vs `df` used +0.6 MB, `nlink=1`), a **hardlink**
  into the cache (`du` 5,704 MB vs 186 MB released, `nlink>1`), and **neither**, where
  `du` is accurate (5,647 MiB vs 5.90 GB, ratio 1.004). Measure the box in front of you
  with `scripts/worktree-disk-probe.sh`; never infer it. The `du` estimate stays labelled an
  estimate wherever it is printed, and it is never reported as freed bytes; this section
  does not tell you which regime this box is in — only the probe does.
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

⛔ **ONE IMPLEMENTATION.** The census the two #2542 classes use is `scripts/lib/live-paths.sh`
(`lp_census` / `lp_path_held` / `lp_path_named`): one bulk `ls -l /proc/<pid>/{cwd,exe}` plus argv,
the same probe the merged #2594 hygiene pass makes its per-root exclusion from, and the same
`(deleted)`-stripping and path-boundary rules. A second copy of this predicate is how two deletion
policies drift, and the drift is silent in the dangerous direction — the copy that forgets one arm
deletes live work.

A probe that cannot be evaluated is a refusal (`exit 3` **from the owner**), not a pass. Through the
entry point that refusal arrives as exit **6** with `ok=0` in the pass record and
`verdict=<class>=refused` — the unit stays green because the box is busy, and the RECORD is what
alarms (see **Exit codes** below).

**The PR-state probe is the one refusal that is PER REPO** (#2443). It needs a credential store, and
that store is per-`HOME` (`$HOME/.config/gh`, or `GH_TOKEN`); the installed unit renders
`Environment=HOME={{HOME}}`, so the unit's own `HOME` decides whether the class can run at all. When
the probe cannot answer, only the repo it could not answer FOR is skipped: its checkouts are left
untouched (a checkout whose PR state is unknown is never removed) while the other repos in the same
pass are still reclaimed. The skip is named twice — `skipped=<repo> reason=<why>` on the class output
and `skipped_worktree=` in the pass record — and the class verdict stays **fail-closed (3)**: skipping
a repo is not a pass. `reason=` says which thing failed, because the remedies differ:

| `reason=` | what it means |
|---|---|
| `gh-not-authenticated(rc=4)` | `gh` is installed and working but has no credentials for this pass's `HOME`. The remedy is the unit's `HOME` (or `GH_TOKEN`), **not** an install |
| `gh-missing(rc=127)` | `gh` is not executable for the pass (`GH_BIN`) |
| `gh-timeout(rc=124)` | `gh` did not answer within `REAP_WT_GH_TIMEOUT` |
| `gh-error(rc=N)` | the query failed for another reason; the pass log carries `gh`'s own message |
| `origin-probe-failed(rc=N)` | the repo's `origin` remote could not be read — a git problem, never an auth one |
| `origin-probe-timeout(rc=124)` | the bounded `git remote get-url origin` did not answer in `REAP_WT_GIT_TIMEOUT` |
| `git-missing(rc=127)` | `git` is not executable for the pass (`GIT_BIN`) |
| `scratch-unwritable` | the probe could not create its one scratch file (the path is named in the line above it) |

A token never contains a space, so a repo path or a `TMPDIR` with a space in it cannot split the line
and turn a named skip back into an anonymous class-wide verdict.

`install-disk-reaper-timer.sh` names this prerequisite **at install time** (a warning, not a refusal:
a box without working `gh` still wants its `uv` and `venv` classes). A unit installed with a `HOME`
that cannot authenticate `gh` otherwise goes red every hour while nothing is reclaimed, and the red
names a cause nobody can act on.

The worktree owner additionally requires the checkout to be
**clean** (uncommitted work is never destroyed), **reachable** (its commits survive the checkout's
deletion), and not an open-PR head — and, since #2721, no younger than
`REAP_WT_MIN_AGE_MINUTES` (45) with a live-cwd check that matches a process standing
ANYWHERE INSIDE the tree, not only at its root (see the seven-rule table below).

`disk-reaper.test.sh` T2 is the load-bearing test: a real process cwd'd into a real
linked worktree is kept by both the worktree and venv classes, and the *same*
fixture is reclaimed once the holder is gone.

## A worktree that OBEYS the fleet must still be reclaimable (lane evidence)

⛔ **Measured defect, 2026-11-03, cell-3 at 90 % used.** The pass was armed, hourly, green and
*correct by its own rules* — and reclaimed **one** worktree per pass while the box created ~**80 per
day**. Its own summary named the reason:

```
examined=133 classified=133 remove=1 preserved=132
reasons=ignored-artifact:70,open-pr:19,no-pr:15,dirty:14,live-cwd:5,pr-closed-unmerged:4,too-young:2,…
```

`ignored-artifact` — a PRESERVE rule — was the **largest bucket**: 70 rows holding **20,557 MB**
(measured by summing `du` over the paths the journal named). What those rows carried, from the same
pass's `proof=git-status --ignored` lines:

| ignored entry | rows | what it is |
|---|---|---|
| `.worktree-report/ WORKTREE-REPORT.md` | 35 | the **mandatory** per-lane report (owner ruling 2026-10-28, #10220) |
| …plus `scripts` | 12 | the gitignored agent-infra **symlink** the AGENTS.md prereq requires (#9475) |
| `scripts` | 7 | same |
| `data/kind_index/*.npz`, `build/`, `dist/`, `.coverage`, `*.report.json` | ~16 | genuine build/experiment output — **still preserved** |

Both of the fleet-mandated names are **gitignored by design** (the ruling says so: *"Its files … are
gitignored and never committed"*). So the two rules the fleet added *after* this reaper was written
turned **every worktree that followed them into a permanent resident**: the more diligently a lane
obeyed its instructions, the less reclaimable its checkout became. This is the **second** instance of
the same shape — the regenerable allowlist records the first, where protecting `__pycache__` *"held
212 worktrees on the live estate forever"* (measured 2026-10-11). Over-preservation is not the safe
direction when the sink is the disk: it is the failure.

**The fix is not a wider allowlist.** Lane evidence is neither operator data nor regenerable, so the
only honest answer is to **preserve it out of the tree and then let the ordinary gates decide**:

* `IGNORED_LANE_EVIDENCE` (`REAP_WT_IGNORED_EVIDENCE`, default ` .worktree-report WORKTREE-REPORT.md `)
  and `IGNORED_POINTER` (`REAP_WT_IGNORED_POINTER`, default ` scripts `) stop vetoing. Both are
  **ROOT-level only**, and the pointer is tolerated **only when it really is a symlink** (`-L`) — the
  NAME list and the `-L` test are a CONJUNCTION, so a real `scripts/` DIRECTORY is a checkout's own
  content and keeps preserving, and a symlink under any other name is not admitted either. Both
  negative controls are fixtures in the suite, each with its own mutant.
* **Every other ignored entry still preserves** (`ignored-artifact`) — `G2b`/`G2e` hold that line, and
  the `data/kind_index`, `build/`, `.coverage` rows above are untouched by this change.
* `preserve_before_removal()` is **gate (b)** on **every** removal (not only evidence rows): before the
  fork that destroys — and **before the last holder re-check**, so the final liveness probe is still
  the last thing before the fork — it writes
  `<REAP_WT_PRESERVE_DIR>/<UTC date>/<slug>.<sha8>.<pathdisc>/` with `lane-evidence.tar.gz` (the
  mandated report), `worktree.diff` (`git diff HEAD`), `worktree.status` (`git status --porcelain`)
  and `manifest.txt` (path, branch, HEAD, reason, time, restore recipe) — **and verifies the
  capture**. The directory is keyed on the CHECKOUT, not the branch: every DETACHED worktree has no
  branch, so a branch-keyed name made two removals in one pass overwrite each other's evidence, and an
  occupied directory name is never reused (a re-dispatched lane at the same path gets a unique sibling
  instead of clobbering the earlier lane's only copy). A
  capture that does not verify takes the PRESERVE arm: nothing is removed. This is the same contract
  as `backup_before_removal`, and it exists because a LANDED checkout can still hold work a human
  wanted (a fixer mid-edit when its PR auto-merged is the ordinary case).
* ⛔ **A capture FAILURE is a pass failure, never a routine pause** (`PRESERVE-SKIP` ⇒ rc 1 ⇒
  `failed=` ⇒ exit 4, red). And because gate (b) inserts a WRITE into every removal, an unwritable
  archive root must not make the class inert on exactly the box that needs it: the root is the first
  writable of `REAP_WT_PRESERVE_DIR` and **`REAP_WT_PRESERVE_FALLBACKS`** (default
  `${XDG_RUNTIME_DIR:-/dev/shm}/pi-disk-reaper-<uid>/reaped-evidence` then `$TMPDIR/pi-reap-evidence`
  — tmpfs is deliberately not the volume being reclaimed), and a fallback is DISCLOSED as
  `PRESERVE-DIR-FALLBACK` in the log. An empty `REAP_WT_PRESERVE_FALLBACKS` restores "this directory
  or nothing" for a box whose state dir must be the only one — and then the pass refuses to remove.
* The archive is a NEW sink on the reclaim path, so it is **bounded**: `REAP_WT_PRESERVE_KEEP_DAYS`
  (default 14; `0` keeps everything) prunes dated subdirectories under the pass lock, oldest first —
  and it prunes **every root an archive can land in**, the configured one *and* the fallbacks, because
  a bounded configured root with an unbounded fallback is unbounded exactly on the box whose data
  volume is full. A dry run only reports. Only exact `YYYY-MM-DD` directory names are ever candidates
  (`2020-01-0`, `2026-11-03-nodash`, `notadate` all survive — anything else there is operator data) and
  an unusable `date` skips the prune rather than guessing. The root is resolved **once per pass**, so
  the prune bounds exactly what the pass can write.
* The archive root can be an NFS or a dead mount, and the prune runs at the START of every pass, so
  **every** filesystem operation this code performs on that root goes through the same bounded fork
  the rest of the reaper uses: `mkdir -p`, the writability probe and its cleanup, the occupied-capture
  probe, the manifest copy, the post-capture verification (`-s`/`-e`), the failure-path `rm -f`, the
  prune's `-d` test, its directory listing and its `rm -rf` — and the two artefacts whose OUTPUT is
  opened in the CALLER's shell (`worktree.diff`, `worktree.status`: `run_bounded` truncates `$out`
  before forking, in `: >"$out"` and again in the `tb_timeout … >"$out"` redirect) are built off-root
  and copied in with `fs_write_bounded`. The tarball needs none of that: `tar` IS the watchdog's child,
  so its own open of the archive path happens inside the bounded fork — rebuilding it off-root (a
  round-5 draft) doubled peak `$TMPDIR` usage for no benefit. A `stat`/`open`/`readdir` on a hung mount
  blocks in the kernel where the caller's own loop cannot be rescued, so leaving any one of them
  unbounded would wedge a oneshot unit that has no timeout — on exactly the box that needs the pass.
  (The helpers are `fs_bounded`, `fs_bounded_out`, `fs_exists_bounded`, `fs_isdir_bounded`,
  `fs_nonempty_bounded` and `fs_write_bounded`.)
* `REAP_WT_PRESERVE=0` restores the **pre-fix verdict exactly** — the tolerance in `clean_gate` is
  gated on the same switch as the archive, so a row can never be called `clean` because of something
  the removal path will not write down.

**Every merge/liveness gate is untouched.** Lane evidence buys a checkout exactly what a *clean*
checkout already had: the ancestry/PR proof, the open-PR veto, the live-process/cwd witnesses, the
stash and unpushed gates, and the age floors all still decide. A `no-pr` row still cannot be proved
landed, and an `open-pr` row is still refused.

**What it reclaims, measured on this box** (dry run first, then an armed pass): see the PR body — the
20.5 GB above was the ceiling, and the row that replaces it is `reclaimable`.

## Deployed-vs-source: is the copy that RUNS the copy we think it is?

`systemctl status` answers *a pass ran*; it never answers *what ran*. The set is a **farm copy**
(`$HOME/.pi/agent/scripts/`) derived from an agent-infra checkout, so a stale or hand-patched copy is
invisible to every readiness check the installer has.

⛔ **Measured shape (2026-11-03, this box).** The deployed `pi-reap-worktrees.sh` was byte-identical
to `origin/main`, while the agent-infra **checkout beside it sat 153 commits behind**. Both artifacts
were fine — and a reader diffing *deployed vs the checkout I can see* would have concluded the reaper
was stale, while the opposite layout (a checkout ahead of what was farmed) would have concluded a fix
was live that had never been deployed. Neither reading is visible to `systemctl`.

So the deployed set is **stamped** and re-checkable with no checkout at all:

```bash
scripts/disk-reaper-deployed-check.sh --stamp --source ~/agent-infra   # after any farm/install
scripts/disk-reaper-deployed-check.sh                                  # 0 = deployed == stamp
scripts/disk-reaper-deployed-check.sh --source ~/agent-infra           # …and == that checkout
```

| exit | meaning |
|---|---|
| 0 | every pinned file matches the stamp (and the checkout, when `--source` was given) |
| 1 | **DRIFT** — a deployed file changed since the stamp, is missing, is one the stamp never MEASURED (`APPEARED`), or is pinned by this checker but absent from the record (`UNRECORDED`), or differs from the checkout |
| 2 | usage, or the record exists but cannot be read (a permissions problem — **not** "unstamped") |
| 3 | **UNSTAMPED** — no record, so "the copy that runs is the copy we think" is **UNPROVEN** |

3 is deliberately distinct from 1: an absent record is a *set-up gap*, not a change. A file the stamp
recorded `missing` and someone later farmed is **`APPEARED`** and fails: it is bytes nobody measured,
and the remedy is a re-stamp, never a green summary. The file list is the set the systemd unit
**pins** (`Environment=*_REAPER=` **plus** `Environment=BOUNDED_LIB=`, the watchdog every bounded fork
goes through — absent, the reaper refuses to start — **plus `lib/live-paths.sh`**, the shared
process-census code two pinned delegates `exit 3` without, **plus `lib/cell-home.sh`**, which
`reap-abandoned-worktrees.sh` resolves from `$SELF_DIR/lib/` and `exit 3`s without
(agent-infra#3453)), written once in the checker, and the record is
**reconciled** against it every run, so a file the unit executes cannot sit outside the check. ⛔ **The
`rm -rf` owner is in that set** (`reap-runner-work.sh`): it was the one pinned delegate outside it, so a
cell still carrying an EARLIER farmed copy — one revision of which deleted a LIVE job's `_work/_temp` —
was a live delete-policy no instrument hashed while the check exited 0 with `same …` for every file it
knew. A
pinned file the stamp recorded `missing` and that is **still absent** is `DRIFT` (exit 1): stamping an
empty directory must not certify a deployment that cannot execute. `disk-reaper-deployed-check.test.sh` drives every
branch to its red path (D2 a one-byte change, D3 a missing delegate, D5 `SOURCE-DRIFT` for the
153-commit shape, D6 a checkout that cannot explain the file, D7/D8 unstamped, D9 usage, D13 the
delete-policy owner missing from the deployed set) — a checker
that cannot fail would certify a stale deployment.

## The two classes that were missing (#2542)

Measured 2026-10-24, all three cells. The guard fired on a nearly-full box and reclaimed **4 MB per
cycle**:

```
cell-1: LOW free=6618MB use=95% floor=8000MB — reclaiming   →  reclaimed: 6618MB -> 6614MB
        (six cycles in 25 minutes; its classes uv, venv, worktree matched nothing)
```

Two consumers were in **none** of the classes, and they are the ones that fill a cell:

| sink | measured | what it is |
|---|---|---|
| abandoned `/tmp` worktree directories | **12.3 GB, 133 directories** across c4/c1/c3 (`df` deltas +5,595 / +3,001 / +3,738 MB); oldest 4,801 min, newest three 5 GB each | linked worktrees of lanes that finished or died. Their HEAD is young and their tree is dirty, so `pi-reap-worktrees.sh`'s clean/aged/reachable policy never lets go |
| duplicate tool installs | **11.3 GB** — eight identical `actions-runner` installs on an 8-core cell | copies of one tool where one would serve |

### `class=worktree`, second arm — abandoned scratch worktrees

`scripts/reap-abandoned-worktrees.sh` owns the rule. **Two dials, both required:**

1. **AGE** — the directory's mtime older than `--aged-minutes` (default **180**;
   `DISK_REAPER_ABANDONED_MINUTES` / `REAP_AW_AGED_MINUTES`).
2. **LIVE-CWD** — no live process's cwd *or* exe resolves inside it, enumerated by reading
   `/proc/<pid>/cwd` (plus `exe` and argv) for **every** pid — never `pgrep -f`, which self-matches the
   shell running the check and shows the nesting stack rather than the population.

Dial 2 is what makes it safe, and it earned its place on the first run: it **kept** five directories
whose age alone would have condemned them — `cell-wt-tmainred70` (226 m), `cell-wt-zombiepi` (742 m),
`cell-wt-trebase6` (823 m), `cell-wt-venvlink` (1,080 m), `wt-pinfix` (2,200 m) — each with a live
process inside it. A reaper without that arm deletes live work, which is worse than a full disk.

**What is a candidate, exactly** — a directory immediately under a scratch root (`--root`, default
`/tmp`) whose `.git` is a **file**, i.e. a *linked* worktree. That one test is what keeps this from
being a reaper for the machine: a primary checkout's `.git` is a *directory*, so `/tmp/cell-ai` (the
hub) and `/tmp/cell-t3` (the cell's repo) cannot be reached by an age or liveness accident; depth 1
means `/tmp/cell-home/...` (state, harness pins) is not swept; and a directory that is not a checkout
at all is never touched.

**The rest of the contract is kept verbatim (#2542 / #2594):**

* the sha pinned in `.agent-infra-stamp.json` is **never** reaped — by path (`harness`, `scripts`, …)
  or by name (a directory named after the commit);
* a path a **live** process's `/proc/<pid>/args` names is never reaped (a controller can be started
  elsewhere and still hold the tree it was pointed at);
* a live lane's worktree is never reaped — that is dial 2;
* when the process list cannot be read **at all**, the sweep is *skipped* and says so
  (`SKIP reason=census-unreadable`, exit 3) — "could not enumerate" is never read as "nothing is live".
  A **partial** read (another uid's `/proc` entries are unreadable) is a real census and is reported
  with its population size; refusing on a partial read would make the sweep inert on every real box,
  which is the inert-enforcer shape this family exists to remove;
* the report is a **`df` delta** taken by the entry point, never a `du` sum.

**The third dial, `--dirty keep|reap` (default `keep`).** A candidate whose `git status --porcelain`
is non-empty is KEPT and named (`reason=dirty(<n>)`). `git worktree remove` never deletes a branch,
the commits live in the shared object store, and a detached sha is still findable with
`git fsck --unreachable` — so the one thing removal genuinely destroys is **uncommitted work**
(measured on the same box: a 33-hour-old abandoned checkout holding 212 dirty entries). `--dirty reap`
restores exactly the six-cycle measurement's two-dial predicate. Both settings are reported, so the
choice is never implicit: on this box the default kept 26 dirty directories and reaped 43;
`--dirty reap` made 69 candidates.

> **OVERRIDES:** the #1095 worktree policy's *clean* gate and 7-day HEAD floor, for **scratch-root
> linked worktrees only** — the owner ruled (2026-10-24, #2542) that an abandoned `/tmp` checkout is
> reclaimable at age > 180 min with no live cwd inside it, because the debris is a dead lane's
> checkout and the repo-layout gates kept 12.3 GB of it forever while the cells filled to 95%. The
> uncommitted-work dial above is the guard that makes that ruling safe by default.

### `class=duplicate-install` — surplus copies of the same tool install

`scripts/reap-duplicate-installs.sh` owns the rule. A **family** is a directory whose children each
carry the same install **marker** (default `bin/Runner.Listener` — a file only a GitHub Actions runner
install has; markers are a table, never inferred from a directory name). Then:

* the **newest copy is never a candidate** — it is the survivor;
* a copy with a live process's cwd/exe inside it is KEPT (`reason=live-listener`), as is one a live
  process was started from (`reason=argv-named`) and one a systemd/launchd **unit file names**
  (`reason=unit-referenced` — a configured-but-stopped runner is not idle in intent);
* a copy younger than `--aged-minutes` (default 180) is KEPT (`reason=young`);
* if the number of copies, or which is newest, cannot be established, **the family is untouched**;
* if the process list cannot be read, the pass **fails closed** and removes nothing.

⛔ **The asymmetry is the policy.** A duplicate left on disk costs disk; a duplicate reaped while live
costs **work** — a runner killed mid-job is a lost job and the run goes unserved (#2542: a runner died
mid-`packaging-smoke` on ENOSPC). Every uncertain case therefore takes the keep arm, and every keep is
named with its reason.

⛔ **The candidate count obeys the same coverage rule as every other class total.** `reap_dup` walks
`roots=` and SUMS the delegate's own `candidates=` over the roots whose `SUMMARY` carried
`census=ok`; the record publishes that sum only when EVERY visited root answered. One answering root
of two is a lower bound, not a measurement, so the record reads `candidates_duplicate_install=?` and
the class line carries `tally=<answered>/<visited>` — without which the `?` would name no cause and
the partial sum would be indistinguishable from a fully-measured one (the same defect the worktree
arm's `tally_worktree=` and the venv arm's `tally_venv=` exist to remove). A `census=ok` root still
has to publish a numeric `candidates=`; anything else is not an answer from that root.

Both owners need no `--repo`: they run on a cell whose repo list is empty, which is the #2443 failure
mode (the repo-scoped classes fail closed there while the disk keeps filling).

### `class=runner-work` — the CI runners' `_work` sink

**MEASURED (2026-10-28, cell c1 `vm-efa6cc8fdb974e61b5c054acf41d8846`, 8 cores, 12 GitHub Actions
runners).** `/` at **98% used, 3.5 G free**, and **19 G** in
`/opt/gh-runner-x64-{2,4,5,6,7,8}/_work` — 2.6–4.7 G per runner — of checkout left by jobs that had
finished or been killed. A runner cleans its own `_work/<entry>` only on a NORMAL job end, so a
cancelled/crashed/OOM-killed job's tree stays for ever. **No class matched it**: not a cache, not a lane
env, not a tracked checkout, not a duplicate install — so the hourly pass reported healthy while a
third of the box sat in none of the traffic classes. `scripts/disk-reaper-run.sh` had ZERO coverage of
`gh-runner`/`_work` (grep proves it), so a box that GAINED five runners in a week silently lost its
headroom.

`scripts/reap-runner-work.sh` owns the rule; the class only runs it and accounts per filesystem.

* **Discovery** is a bounded, documented glob list — `/opt/gh-runner*/_work`,
  `$HOME/actions-runner*/_work`, `$HOME/actions-runner/*/_work`, `/tmp/actions-runner*/_work`,
  `/tmp/actions-runner/*/_work` — as `DISK_REAPER_RUNNER_GLOBS`
  (space-separated, handed down as `REAP_RW_GLOBS`). A SET-but-EMPTY value is a **refusal at startup**
  (exit 3), the rule `BOUNDED_LIB` already gets: `${X:-default}` would silently substitute the WIDEST
  sweep for an emptied seam, which is the delete direction. A glob that matches nothing is ordinary; a
  glob list set EXPLICITLY that matches NOTHING is `misconfigured` + `?` (see below).
  ⛔ **BOTH DEPTHS SHIP, AND THE NESTED PAIR IS NOT OPTIONAL.** Globs expand ONE level as written, and
  this repo's own `scripts/ci_runner_pool.sh` defaults `RUNNER_ROOT=/tmp/actions-runner` and copies the
  template into `$RUNNER_ROOT/<name>` — so a POOLED runner's `_work` is `/tmp/actions-runner/<name>/_work`,
  one level deeper than a flat `/opt/gh-runner-x64/_work` install. A flat-only default matched nothing on
  a pooled cell, and this class reads a default-glob miss as a MEASURED EMPTY POPULATION (`roots=0
  census=ok`, exit 0) by design — so the class was **INERT ON A CELL WHILE REPORTING HEALTHY**, which is
  the exact defect `#2894` was filed to remove (measured in review; the suite's `(f)` reach arm and its
  `MUT_F5` flat-only mutant now pin it). A custom `RUNNER_ROOT` still needs its own glob: discovery is by
  glob, never a walk of the whole filesystem.
* ⛔ **A matched root whose BASENAME is not `_work` is REFUSED, by name, and the pass exits 3.** This is
  the last gate before `rm -rf` and it was missing: a seam ONE COMPONENT SHORT — `/opt/gh-runner*/`
  instead of `/opt/gh-runner*/_work` — matched the runner INSTALL tree and swept `bin/`,
  `config/`, `externals/` (**measured: `REAPED …/gh-runner-x//bin`**), and the mtime floor offers NO
  protection there because an install tree is ALWAYS older than any floor — the very test that is this
  class's proof of death is what makes the install look dead. One character in a rendered unit would have
  destroyed the CI hosts. Refused rather than silently skipped: sweeping the roots it did find and
  reporting a healthy population would hide a wrong layout assertion, which is the same
  explicit-vs-default rule the glob list gets. The count is on the class line as `refused=<n>`, so "why
  did this pass do nothing" is answerable.
* **A root named by more than one glob is swept ONCE.** `--glob` is repeatable, so a wildcard and a
  literal naming the same root is a normal operator spelling; without a seen-set the root was swept per
  glob and the population was reported at twice its size (`roots=2 candidates=2` for one entry, the same
  `WOULD-REMOVE` path logged twice) — a count that is a function of how an operator spelled the list
  is not a measurement. The skip is NAMED, so a dedupe cannot be mistaken for a root that never matched.
* **The gate is CONTENT mtime** — `DISK_REAPER_RUNNER_MIN_AGE` (default **7200 s**, the only empirically
  validated value; it was 3600 s, half of it, until a review of this class measured the consequence). A
  `_work` entry is a
  candidate only when **nothing under it has been written for longer than the floor**. The in-entry
  witness is the **checkout's own writes** (outputs, build artefacts, `.venv`/`node_modules`, any file a
  step creates under the checkout) — NOT `_work/_temp`: the vendor resolves the runner's private
  directories as `Combine(Work, <name>)` (`actions/runner` `src/Runner.Common/HostContext.cs`
  `GetDirectory`: `case WellKnownDirectory.Temp` → `Path.Combine(GetDirectory(WellKnownDirectory.Work),
  Constants.Path.TempDirectory)`, and the same for `.Actions` and `.Update`), so `_temp` — like
  `_actions` and `_update` — is a **sibling of `_work/<repo>` INSIDE `_work`**, not a directory at the
  runner root (older runner builds put them at the install root; the checkout's `_work` is what this
  class sweeps). ⛔ **`_tool` IS THE EXCEPTION AND ITS PREMISE IS CONDITIONAL:** `WellKnownDirectory.Tools`
  prefers `$RUNNER_TOOL_CACHE` / `$RUNNER_TOOLSDIRECTORY` / `$AGENT_TOOLSDIRECTORY` / the
  `agent.ToolsDirectory` runner variable, and only falls back
  to `Combine(Work, "_tool")` when ALL FOUR are empty, so on a box that sets any one of them (every github-hosted
  image, many self-hosted) `_work/_tool` is not the tool cache and may not exist. The retain row is
  still right — a directory by that name under `_work` is never a job checkout — but the reason is
  "never a checkout", not "the vendor puts the tool cache here"; stating the fallback as a rule is the
  same wrong-origin class this paragraph exists to correct. Writes there therefore do not
  refresh the checkout's floor, and mtime is a positive proof of death for the entry being reaped.
  ⛔ **But being none of the checkout's business is NOT the same as being invisible here**, and reading
  it as "at the runner root" was the whole of the shipped defect: `sweep_root` walks **every** entry of
  `_work`, so a directory that protects nothing is a **candidate**. `_temp` is a live job's
  `$RUNNER_TEMP`, and `ScriptHandler.cs` writes the step's script there **once per step** — so a job
  whose CURRENT step outruns the floor has a **fresh checkout** (correctly KEPT) and a **stale
  `_temp`**, and the class deleted a running job's temp directory while its checkout gate worked
  perfectly. It is now retained by name (see the next bullet); the residual below does **not** cover
  this shape, which is why it is stated separately. The comparison set is everything under the entry **including the
  entry's own top directory**, which is the conservative direction (a stray `touch`/`cp` over a dead
  entry's top dir restores its floor). What the gate deliberately does NOT use is the top directory's
  mtime **alone**: a killed job stamps that directory at the moment of the kill while its CONTENTS can
  be hours older, so "the dir is old" is not on its own the proof. The
  owner re-probes the same question immediately before each removal, so a job that starts mid-pass is
  preserved (`reason=toctou`), and an unanswerable walk (permission error, vanished mount, watchdog
  timeout) is **KEPT**, never read as dead (`reason=unreadable`).
  ⛔ **There is no busy-check, and one must not be invented.** The listener is a child of the runner
  service, the job worker's state lives inside that process, and `_work/<entry>` carries no owner pid,
  no lock and no name-to-process mapping — so a `pgrep Runner.Listener`-shaped guess is both over-broad
  (it keeps every dead entry while ANY runner is idle, which on a 12-runner box is always) and
  under-broad (`--ephemeral` runners started by hand). That is an inert class reporting healthy, which
  is the shape this whole reaper exists to remove.
  ⚠️ **Residual, stated so it is not discovered:** a job that writes NOTHING **inside its checkout** for
  longer than the floor is indistinguishable from a dead entry by this test. That is a whole-job
  exposure for any job whose artefacts land in `$TMPDIR`, `~/.cache` or `_work/_temp` (i.e. every step
  after checkout), not merely "one long quiet step". Raise the floor for such a box
  (`DISK_REAPER_RUNNER_MIN_AGE=7200`) — that is the intended response. The only empirically validated
  floor is **7200 s** (the 120-minute hand reap that took c1 98 % → 90 % with no job disturbed), and
  **that is now the SHIPPED default at both layers** — it was 3600 s, HALF the validated value, in a
  class that is in the default `--only` list and whose installed `ExecStart` carries `--apply`, so the
  aggressive side of a measured trade was what ran on every box when nobody read this paragraph. A
  default is not a suggestion here: it is what runs.
  ⛔ **RAISING THE FLOOR IS A LOAD-BEARING INSTRUCTION, SO THE FLOOR IS BOUNDED — and it was not.**
  The paragraph above tells an operator to raise it, and until this was fixed that instruction could
  delete the very work it was meant to protect. The owner validated its floor with `num()` alone
  (all-digits), then computed `when=now − FLOOR` in **bash's 64-bit** arithmetic. `18446744073709551616`
  (2⁶⁴) is all-digits, so it passed; `now − 2⁶⁴` **wraps to `now`**, the floor reference lands at NOW,
  and every entry is older than it — **MEASURED: a 5-minute-old entry `REAPED` under a floor an operator
  set to "keep everything", with the log asserting "no content written for >= 18446744073709551616s"**,
  a flat falsehood about a 5-minute-old checkout. A second spelling of the same hole: the floor value
  later feeds `$(( ))` and `touch -t`, so `08` passed `num()`, then `$(( ))` died with *"08: value too
  great for base"*, the floor became unusable, and the pass still exited **0** with `census=ok` reporting
  **every** entry as `reason=unreadable` — a bad knob reported as a filesystem problem, i.e. a silent
  full abstention that reads as a healthy box. The floor is now **normalised** (leading zeros stripped,
  which is what makes `08` mean 8) and **bounded by magnitude** (≤ 9 digits, ~31 years — a value larger
  than that cannot be compared at all), refusing with exit 2 and naming the cause. This is the guard the
  family already shipped for the same seam — `scripts/reap-lane-venvs.sh` (*"out of range — at most 9
  digits (~31 years)"*) and `disk-reaper.sh`'s `seam_too_large` — and the hourly pass was never exposed
  to it because the ENTRY POINT bounds `DISK_REAPER_RUNNER_MIN_AGE` at startup and exits 3. The exposure
  was the **owner's own** `--min-age` / `REAP_RW_MIN_AGE`, the spelling its `--help` recommends, which is
  why the case that covers it drives the owner directly rather than through the entry point.
* **THE RUNNER'S WHOLE `_work` NAMESPACE IS DELIBERATELY RETAINED, and it is DERIVED from one table.**
  The owner declares the vendor's layout once (`WORK_LAYOUT` in `scripts/reap-runner-work.sh`, one row per
  name: `<name>|<disposition>|<reason>|<why>`) and reads the retain set **off** it — never a second
  literal list, because a second list is exactly how the third directory was missed while the first one
  still read as complete. The rows:

  | name | why it is not a candidate |
  |---|---|
  | `_temp` | the **live job's `$RUNNER_TEMP`** — the step script (written once per step, so it goes stale while the job runs), the command log, every temp file a step writes |
  | `_actions` | every downloaded action: reaping it forces a re-download on the NEXT job, i.e. slower CI rather than disk |
  | `_tool` | every fetched toolchain: the same trade as `_actions` |
  | `_update` | the runner's own self-update staging: reaping it mid-update breaks the runner it is updating |

  ⛔ **A `_`-PREFIXED NAME WITH NO ROW IS ALSO RETAINED**, and named as such
  (`reason=vendor-namespace-unlisted`). Every directory the vendor names for itself is `_`-prefixed and a
  job checkout is a repository name, so the next directory the vendor adds arrives as a **named, counted
  decision** (a `RETAINED` line plus `retained=`) instead of as another silent `REAP` candidate. That is
  the over-retain direction on purpose: a checkout wrongly kept costs a dead tree one more pass, a vendor
  directory wrongly reaped costs a live job. ⚠️ The cost, stated rather than discovered: a repository
  actually NAMED `_something` would never be reaped — if a box runs one, give it a `reap` row, which is
  the visible decision the default exists to force. **A `reap` row is HONOURED** (`reap` and `retain` are
  read by the same table lookup, so a row cannot work in one direction and be inert in the other), the
  name is then a CANDIDATE like any other checkout — the floor and the liveness gate still decide, so a
  LIVE one is KEPT — and the pass names the decided row on its own line (`reaped-by-table=`). Case **(k)**
  pins that with the shipped bug as its mutant: when the lookup honoured only `retain`, a `reap` row fell
  through to this default and printed `reason=vendor-namespace-unlisted` — *"no WORK_LAYOUT row"* about a
  name whose row was in the table, i.e. the documentation was true and the code ignored it.
  The exclusion happens BEFORE anything is measured, is counted on the class line (`retained=`) and is
  named per directory (`RETAINED … reason=`), so "why is this still here" has an answer.
  `scripts/disk-reaper-runner-work.test.sh` proves it both ways: case **(c)** — `_tool`/`_actions` survive
  when they are the OLDEST thing in the tree, in the same pass that reaps a dead sibling; case **(j)** —
  a **live** checkout's stale `_temp` survives, a vendor directory the table has never seen survives,
  and a genuinely dead checkout in the same pass is still reaped.
* **The vendor namespace is the only carve-out; whole entries are the only candidates.** A plain
  file in `_work` is not a job's checkout, so it is left alone — the class removes directory entries.
* **A ROOT is re-asserted at SWEEP time, not only at admission** (#3057 review, P2). The pass is two-phase
  on purpose — every root is classified before the first delete — so the `-d`/`! -L` assertions made in
  discovery are stale when the sweep runs. An operator freeing a full runner disk (the action a box at
  98 % invites) moves `_work` aside and leaves a symlink behind, and `"$root"/*/` then expands THROUGH it:
  the sweep would classify, and `rm -rf`, a tree OUTSIDE the population it was told to sweep. A root that
  EXISTS but is no longer a plain directory is therefore an **abstention** (`reason=root-changed-since-discovery`,
  counted in `unmeasurable=`), never a swept population — the same sentence the per-ENTRY loop already
  carried, and the same TOCTOU this owner re-probes for every entry before the `rm`. ⛔ A **vanished** root
  is a different state (`reason=vanished`, its own `gone=` field): a fact about the box, not a doubt about
  it. Case **(w)** pins the whole thing with an instrumented owner that performs the swap at the phase
  boundary, because the race itself cannot be asserted.
* **Accounting** is a `df` delta per distinct filesystem the globs can land on (`/tmp` is a tmpfs on
  some boxes and part of `/` on others, so one reading would report 0MB for gigabytes freed from the
  other), attributed only when the owner's own ledger says it removed something. A pass that removed
  nothing reports `freed=0` and names the un-attributed `df` change in `detail=`, like every other class.
* **The record** carries `freed_mb_runner_work=`, `candidates_runner_work=` (and the same number as
  `cand_runner_work=`, the spelling this class's brief uses — both written from one expression so they
  cannot disagree), `unmeasurable_runner_work=`, `reaped_runner_work=`, `gone_runner_work=`,
  `verdict_runner_work=` and `note_runner_work=` (the class's own cause channel; it rides in `detail=`
  too). `--print-status` prints all of them (`freed_mb_`, `would_free_mb_`, `candidates_`, `cand_`,
  `unmeasurable_`, `reaped_`, `gone_`, `note_`, `verdict_`) — a field the reader does not print does not
  exist.
* **`reaped_runner_work=` and `gone_runner_work=` are the two tallies the record used to DROP** (added
  after a reviewer measured both holes at this head). The owner answers `reaped=<n>` (what it removed) and
  `gone=<n>` (entries/roots that disappeared under the pass), and the entry point lifted neither — which
  produced two distinct lies on a DELETER:
  * **Without `reaped=`, a cut-short pass claimed it removed NOTHING.** A sweep killed at
    `CLASS_TIMEOUT` prints no `SUMMARY`, so the lifted tally was the COERCED 0 and the `df`-attribution
    arm concluded the observed `df` change "belongs to another process". **Measured** with a stub owner
    that deletes a 40 MB entry and exits `124`: the record read `freed_mb_runner_work=0` beside
    `note_runner_work=nothing removed: the 40MB df change belongs to another process (not attributed)` —
    the class blaming someone else for the deletion it had just performed. The sentence is now gated on
    the owner ANSWERING (`HAVE_RW_REAPED`), and an unanswered ledger reports the delta as
    **MAY BE ITS OWN (unattributed)**, never as proof that another process caused it, while
    `reaped_runner_work=?` tells a reader the removal count is not a measurement. ⛔ **AND THE BYTES ARE
    `unmeasured` TOO, not a measured `0 MB`** (#3057 review): `freed_mb_runner_work=unmeasured`, with
    `freed_mb_unmeasured` naming `runner-work` — a stub that deleted 40 MB reported a *confident* zero there
    while the note admitted the figure was unknown, and the note being the only surface that said so is the
    same "measured zero that is not a measurement" this class's `?` polarity exists to remove.
    ⛔ **AND EVERY SURFACE THAT READS THE FIGURE FOLLOWS IT**, because fixing one field at a time left the
    same lie one step over, each time on a surface an operator reads FIRST: `freed_mb=` (the pass total that
    `--print-status`, `tools/fleet/fleet-health.py` and the supervisor all name — `freed_mb_total` is read
    by nothing) is `unmeasured`; `alert=under-reclaim` is gated on the **MEASURED SUBSET** and never on a
    sum containing an unconfirmed `0` (#3057 review cycle 2 — it used to require the WHOLE sum to be
    measured, so one unrelated unmeasured class silenced the alarm on a pass that demonstrably did not keep
    up; it now fires while `freed_mb_total` still abstains, and `alert_detail` names its figure a lower
    bound); and the REASON is
    split, so `detail=` and the pass-end line say **owner never answered its ledger: runner-work**, not
    "df could not measure" — `df` ANSWERED here, and blaming it points an operator at the mount for a
    cut-short ledger. `freed_mb_unmeasured` still lists `runner-work` (one answer to "whose reclaim was not
    measured"); only the cause is separated.
  * **Without `gone=`, an EMPTY sink and a VANISHED one were the same record.** The owner counts a
    disappeared entry/root into `gone=` and feeds it into its census decision, and cases **(s)**/**(t)**
    exist to keep that out of `unmeasurable=` — a gone root is a fact about the box, not a doubt about
    permissions. But with no field, a pass whose whole population vanished recorded
    `candidates_runner_work=0 verdict_runner_work=ok`, byte-identical to a `_work` that was simply empty.
    It is now carried in `gone_runner_work=` and NAMED in `note_runner_work=` when nonzero.
  Both use `unmeasurable_runner_work=`'s polarity (`?` when unanswered or when the class could not be set
  up, `not-run` when this pass did not select the class, the owner's own number otherwise), they are
  printed on the class line beside `candidates=`/`reaped=`, and case **(v)** asserts each with its own
  mutant — including that a normal reaping pass records `gone_runner_work=0`, so the field is a
  measurement there and not a permanent `?`.
* **`unmeasurable_runner_work=` is the ABSTENTION channel, and it is a field of its own on purpose.** The
  owner answers `unmeasurable=<n>`: entries it KEPT because its bounded walk could not ANSWER (a
  permission error, a vanished mount, a watchdog 124, a TOCTOU re-probe that could not answer). Those
  entries are correctly kept — an unanswerable walk is not proof of death — but with only `kept=` and
  `failed=` in the record, "kept because nothing was written for an hour" (a measured decision) and "kept
  because the walk could not read it" (an abstention, i.e. a probe to fix) printed the same number. It is
  `?` when the owner did not answer, `not-run` when this pass did not select the class, `?` when the class
  could not be set up, and a nonzero value is also named in `note_runner_work=`/`detail=` so an operator
  finds it without knowing the field exists. **All three polarities are ASSERTED, not merely documented:**
  the numeric reading by case **(b)**, `not-run` (a pass that selected another class) by case **(d)**, and
  `?` (a class that could not be set up) by case **(f)** — each with a mutant that must turn it red, so a
  value that stops being produced reddens instead of shipping as prose.
  ⛔ **AND THE SAME ABSTENTION APPLIES ONE LEVEL UP, TO THE ROOT — added at this head after a reviewer
  measured the hole.** `[ -d "$root" ]` needs only a stat, so it SUCCEEDS on a `_work` this process may
  not READ (mode 0750/0711 owned by another user — plausible on a cell whose runners the root bring-up
  installed while the reaper runs as `cmux`). `"$root"/*/` then expands to ITSELF, the loop body never
  runs, and the pass printed `roots=1 candidates=0 kept=0 unmeasurable=0 census=ok`, exit 0 — the entry
  point recorded `candidates_runner_work=0 verdict_runner_work=ok`, and an INERT class read HEALTHY. A root
  whose listing cannot be read is now counted into the SAME `unmeasurable=` field
  (`reason=unlistable`, named per root), so `candidates=` still reports what WAS seen while
  `unmeasurable=` names what was not. Case **(l)** pins it, with its own mutant.
  ⛔ **AND THE ABSTENTION IS NOW A CENSUS AND A VERDICT, not only a note — added after a second reviewer
  measured the same hole one state further on.** Counting the root into `unmeasurable=` was the right
  ANSWER and the wrong RECORD: with nothing readable, `candidates=` stayed 0 from a census that still
  read `ok`, so the entry point lifted `candidates_runner_work=0 verdict_runner_work=ok` and a box whose
  sink fills behind a permission mismatch read HEALTHY for ever — `fleet-health.py` alarms on the
  record's `ok`, not on `note_`. The owner now publishes **`census=abstained`** when `unmeasurable>0`
  **and NOTHING was reached** (`CAND+KEPT+RETAINED+REAPED+FAILED+GONE == 0`, so no entry was classified —
  the `candidates=0` spelling of this gate is the version that was WRONG; see the reached-ness note
  below), and the entry point records **`candidates_runner_work=?`** with
  **`verdict_runner_work=abstained`**. The pass still exits **0**: an abstention is not a failure of the
  pass, it is the pass saying it could not look, and an hourly red for a permission mismatch is the
  alarm-fatigue shape this family forbids — the RECORD is the alarm channel. Case **(l)** asserts the
  owner's token, the record's `?`, and the distinct verdict separately, with a mutant for each half
  (`l2` the owner's census, `l3` the entry point's mapping), because either half alone leaves one
  surface lying.
  ⛔ **AND THE ABSTENTION IS ONLY THE *TOTAL* CASE — a PARTLY-unreadable population is the same hole one
  state over (#3057 review, P1).** `census=abstained` WAS gated on `candidates=0` at that head, so a pass
  that READ one root and could not read another published `census=ok`, and the entry point lifted it as
  `verdict_runner_work=ok`. MEASURED on two roots — one readable holding a dead checkout, one mode-0111
  holding a dead checkout: `roots=2 candidates=1 unmeasurable=1 census=ok` ⇒ record
  `{candidates=1, unmeasurable=1, verdict=ok}`. That is the LIKELY shape on a real cell, not a corner: the
  runners are not all owned by one user (one `_work` root-owned 0750, the rest readable), so the sink that
  fills silently is exactly the one the verdict calls healthy. The owner now publishes
  **`census=partial`** when `unmeasurable>0` AND something WAS reached; the measured count is KEPT
  (`candidates_runner_work=<n>`, a LOWER BOUND — withdrawing a real count to signal doubt would hide work
  the class can prove) and the verdict is **`verdict_runner_work=partial`**. rc stays 0 for the same
  reason `abstained` does. Case **(r)** drives both roots, asserts that the readable root's dead checkout
  IS reaped while the unreadable one's SURVIVES, and mutates each half separately (`r1` the owner's token,
  `r2` the entry point's mapping).
  ⛔ **AND THE GATE IS *REACHED-NESS*, NOT `candidates` — the first version of this fix keyed on
  `candidates=0` and made the abstention lie on the most ordinary healthy box.** A cell with two roots —
  one readable holding only a FRESH checkout, one unlistable — printed `kept=1 unmeasurable=1
  census=abstained`, whose note says *"nothing under a matched `_work` root could be READ … no entry was
  classified"* about an entry that WAS read and classified `written-within-floor`, and raised a non-`ok`
  verdict on a cell that was fine. `abstained` therefore means **nothing was reached** (case (l)'s shape —
  no entry classified at all), and any pass that classified at least one entry (candidate, kept, retained,
  reaped, failed, or observed to VANISH) publishes `partial`, with `candidates=` a lower bound that may be
  `0`. Case **(r)** drives this shape too, so the falsehood and the false alarm are both pinned.
  ⛔ **AND A VANISHED ENTRY IS NOT AN UNREADABLE ONE.** `find` on a path that a runner deleted mid-pass
  exits non-zero exactly like a permission failure, so a job finishing during the sweep was counted into
  `unmeasurable=` — enough to publish a non-`ok` census on a pass that measured everything else. The walk
  re-stats before claiming an abstention and reports **`GONE … reason=vanished`** instead (`gone=` on the
  SUMMARY), which is a fact about the runner, not a doubt about the box.
  ⛔ **AND A REFUSED ROOT IS ITS OWN CENSUS, because it has its own REMEDY — and it refuses BEFORE the
  sweep.** The root-name gate refuses a
  matched root whose basename is not `_work` and exits 3, but the census used to fall through to
  `no-roots` when no root had been swept — so the record said *"no runner `_work` root matched
  DISK_REAPER_RUNNER_GLOBS"* about a glob that HAD matched and been refused, and the remedy that sentence
  implies (widen the glob) is the OPPOSITE of the correct one (the glob is already matching; it is one
  component short). The owner now publishes **`census=refused`**, the entry point records
  `misconfigured` with its own `runner-work-root-refused` token and a note naming the basename refusal,
  and rc stays 3. Case **(o)** asserts the cause, with mutant `o2`.
  ⛔ **THE PASS IS TWO-PHASE FOR THE SAME REASON: DISCOVER, THEN SWEEP.** The name gate is per-root inside
  the discovery loop, so with a seam that matched BOTH a real `_work` and a runner INSTALL tree the pass
  REAPED under the good root and only then hit the refusal — and exited 3 carrying a note that said
  *"nothing was swept"*, with `freed_mb=0`/`freed_mb_runner_work=not-run` for the checkout it had just
  destroyed. MEASURED (seam `…/gh-runner-x64-1/_work …/gh-runner*`, one `--apply` pass):
  `REAPED …/job-dead how=rm` then `REFUSED …/gh-runner-x64-1` and a record claiming zero bytes freed. A
  wrong seam now refuses for the WHOLE pass before anything is touched, which is also what makes that note
  true. Case **(o)** drives the mixed seam and asserts the dead checkout SURVIVES it.
  ⛔ **AND THE RECORD REACHES AN OPERATOR OR IT DOES NOT EXIST.** `abstained`/`partial` are rc 0 by
  decision, so the record IS the alarm channel — and both readers dropped it: `fleet-health.py` printed
  only `ok/rc/freed_mb` (throwing away the `detail` that names the abstention) and
  `cloud-cell-supervisor.sh` printed per-class lines for `uv`/`venv`/`worktree` only. Both now print a
  non-`ok` `verdict_runner_work` — `⚠️ runner-work=partial unmeasurable=1`, the tally included because
  `partial` without the number cannot distinguish one unreadable root from fifty — and **neither alarms on
  it**: that is the recorded decision above, not an oversight, and reversing it in a fleet-wide reader
  would defeat it.
* **A class that scanned NOTHING is not a pass.** With the globs set EXPLICITLY and no directory
  matching, the owner reports `census=no-roots` and the class records `misconfigured` +
  `candidates_runner_work=?`, exit 3 — the same rule (and shape) as `venv-no-repo`. With the DEFAULT
  globs, a box that has no runners in the documented layouts is an EMPTY POPULATION, which IS a
  measurement (`roots=0`, candidates `0`, exit 0): painting that red hourly is the alarm-fatigue shape
  this family forbids, an alarm nobody reads.
* **It is in the DEFAULT `--only` list**, and pinned in both scheduled artifacts
  (`RUNNER_WORK_REAPER` in `templates/systemd/eldato-disk-reaper.service` and in the launchd plist)
  and in the farm list, because a class an operator has to remember to enable is exactly the hole it
  closes. It runs LAST, after `duplicate-install`: its candidates live outside the fleet's own trees
  and its gate is the most conservative in the pass, so it must never be the reason a bigger arm did
  not run.

⛔ **The `/tmp` sink on the same box is NOT this class.** c1's `/tmp` held **148 826 entries older than
24 h ≈ 15 G** (c4's `/tmp` measured 48 G). That needs its own class and it is harder — a live lane's cwd
can BE under `/tmp` (measured: a running `pi` lane cwd'd in `/tmp/cell-t3/.worktrees/…`), so an mtime
floor alone is not proof of death. Filed as **#3043**, not implemented here.

**UPDATE — merged base 2026-11-03 (#3272, `f2d40ef8`).** The *gitless* half of that population now DOES
have an owner, so "nothing sweeps `/tmp`" is no longer true and this paragraph would otherwise be read as
that claim: `scripts/reap-abandoned-worktrees.sh --include-gitless` (reached from the pass's abandoned
arm, `DISK_REAPER_GITLESS=0` off-switch) sweeps a `/tmp/<name>` scratch tree with **no `.git` at all**,
using the liveness witness the objection above asks for (a live-pid cwd/exe census, `reason=live-cwd`)
plus a keep list (`REAP_AW_GITLESS_KEEP`, default `/tmp/actions-runner:/tmp/venv-shared*`).
**#3278 changed WHEN #3272's count ceiling is charged, not its size.** The ceiling (`REAP_AW_GITLESS_MAX`,
default 10 per root) is still the bound on destructive capacity, and it is now taken **after the age
floor and before the live-pid census** — the unit used to be spent BEFORE the floor was consulted, so
~89 % of those ten slots went to trees the age test preserved anyway, and on a population of thousands
the aged trees were never reachable at all (a dry run over 3,314 entries classified 10 and printed
`gitless-cap` for **3,137**). **An exhausted ceiling also short-circuits the eligibility scan itself**
(one integer compare, at the top of the gitless branch): with the refusal downstream of the scan a
capped pass still paid ~6 forks per entry to print rows that say the same thing — measured at 8.98 s
versus 0.60 s over 300 entries with the census isolated, for a byte-identical pass record. The cost of
that ordering is a REPORT change, and it is deliberate: past the ceiling a row names the ceiling
(`gitless-cap`), not the tree's own reason, because the arm did not look. Every outcome there is a
preserve.
The pass's **expensive per-candidate work** is additionally bounded, **per
root**, by a **TIME** bound, `REAP_AW_BUDGET_SECONDS` default 300 s — the eligibility scan over the whole
population up to the ceiling is *not* budgeted (classifying every entry is the product), and
`DISK_REAPER_CLASS_TIMEOUT` (1800) bounds each **per-root invocation**, not the whole pass.
**Raising or removing the ceiling is #3278's P3 — an owner decision, sequenced after P2 — and is not
part of this change.**

The `home-or-state` guard protects the cell home even when nothing exports `CELL_HOME`: the unit renders
`Environment=HOME=/home/cmux` (a real directory), so the wrapper's own fallback never fires and
`/tmp/cell-home` — ~20 GB of live `.pi` state with no `.git` — used to match none of the guard's
references. The guard now resolves it itself, via `REAP_AW_CELL_HOME_DEFAULT` (default
`/tmp/cell-home`). ⛔ **That seam is TEST-ONLY: never set it in a systemd unit, a launchd plist, or any
scheduled artifact.** It is a *substitution*, not an addition — an exported `CELL_HOME` still wins, and
a wrong value protects a different directory **and drops `/tmp/cell-home`**. It exists so the fallback
has a behavioural test (a fixture cannot live at `/tmp/cell-home`); it is a default, not a second
source of truth.
What **#3043** still covers is the remainder: trees a `.git`-owned arm claims (those keep their own
`open-pr`/`dirty` proofs) and everything the ceiling and the pass's time bound leave for the next run.

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

## The seven-rule decision table, PR state as a proof, and the freshness floor (#2721)

The floor above is a *staleness* floor. It does not answer the opposite question —
"is anything using this tree RIGHT NOW" — and until 2026-10-24 the tool answered it
with an **exact-match** cwd test. Measured: a worktree dispatched to a lane four
minutes earlier was deleted underneath it while the lane stood in a SUBDIRECTORY of
it; the lane then sat at 0% CPU in a deleted cwd logging `getcwd() failed`. The gate
tested the path, not the tree.

Every row now prints the rule that decided it and the proof it used
(`rule=4 … proof=pr-merged head-ref fix/x state=MERGED (#9862)`), so a KEEP that
cannot name its evidence is visibly a bug rather than a verdict:

⚠️ **A KEEP row never wears a REMOVE rule's number.** `rule=3` and `rule=4` both mean "remove" in the
table below, so a preserve printed as `rule=3` was counted as a removal by anything grepping
`rule=3` — the mirror of the rule-6 defect above. Rows that abort a removal arm therefore carry the
pre-existing `rule=P` label and name the suppressed rule in a token that **cannot collide**
(`rule=P would-remove=3 …`): the row's only `rule=` token is `rule=P`, so `grep ' rule=3'` — the
command that reads this table — cannot classify a preserve as a removal. (`would-be-rule=3`, the first
cut, still matched that grep; the token is spelled to make the property true, not merely to look like
it.) `main-proof-vanished` is the reason such a row carries: the ancestry proof that put the checkout
in the removal path **did not reproduce** on the re-take, and a proof that cannot be retaken removes
nothing.

| # | condition (all previously applicable rules still hold) | verdict |
|---|---|---|
| 1 | a process has the tree, or **any path inside it**, as cwd, or names it in argv | KEEP |
| 2 | dirty, or a clean gate that cannot be evaluated | KEEP |
| 3 | clean + HEAD is an ancestor of `origin/main` | REMOVE |
| 4 | clean + the PR **whose `headRefOid` IS this commit** is `MERGED` (merge, squash or rebase) | REMOVE |
| 5 | clean + PR `CLOSED` unmerged + head not an ancestor | KEEP, and **name the PR** |
| 6 | clean + no PR matches this head, still inside the floor in force | KEEP (`no PR — cannot prove it is landed`) |
| 7 | younger than `REAP_WT_MIN_AGE_MINUTES` (45) | KEEP |
| P | pre-existing gates: main/self checkout, `worktree lock`, unreadable path, bare repo, OPEN PR head, commit held only by a revocable ref, detached on no ref. Past the floor in force, a clean no-PR checkout whose commits survive on a branch is REMOVED by the pre-existing #1095 aged rule (`rule=P … no-pr=`) — rule 6 is the KEEP row and never labels a removal | KEEP |

**What "main" is, and why it is not the local cache.** Rules 3-4 both prove a head is
*landed*, so the answer is only as good as the `main` it is compared against. The local
`refs/remotes/origin/main` is a **cache** and can lag the remote by hours, which would
let a pass prove "merged into main" against a stale tip. `REAP_WT_MAIN_PROOF=auto`
(default) therefore asks the remote that PUSHES (`git remote get-url --push --all`,
one url or none) which branch it calls HEAD (`ls-remote --symref`) and then reads that
exact ref — so a `master`- or `dev`-default repo is not silently proved against a `main`
that does not exist there. The remote oid is tried FIRST and the local ref chain
SECOND, every failure mode (`unavailable`, `ambiguous` for two push urls,
`auto-unfetched` when the remote's oid is not in this repository) claims **no**
evidence rather than falling back silently, and `REAP_WT_MAIN_PROOF=local` forces the
local chain — which is the test seam and what keeps every fixture offline. Which source
answered is printed once per pass (`main_proof=` on the `SUMMARY` line, and
`main_ref=` for the branch the remote named), so a pass can never cite a remote it
did not read. ⛔ It answers "could the REMOTE be read", not "which chain decided this
row": with the remote unreadable the report says `main_proof=unavailable` while
`is_ancestor_of_main` still evaluated the LOCAL chain — which is why the field is
pass-level and the per-row `proof=` cites the actual command (`merge-base
--is-ancestor <sha> <main>`).

**Rule 4 is why this exists.** `git merge-base --is-ancestor` cannot see a squash
merge: the branch head is not an ancestor of `main` even though the work landed. So a
fully landed, clean, holder-free checkout was loggable only as `no upstream — cannot
prove it is pushed` and kept indefinitely. Measured on cell-4: `/tmp/cell-wt-p9555b`
was clean, its PR **#9862 was MERGED**, and removing it freed **6004 MB**. The read is
ONE batched `gh pr list --state all --json headRefName,state,number,headRefOid` per
pass — never one call per worktree (the fleet's `gh` budget is real) — and it now runs
for **detached** records too, matched by `headRefOid`, because a detached head has no
branch name to match and is exactly the class that sat unprovable.

⛔ **A branch NAME is not identity, and the limit is not a licence.** A merged PR is
matched to this checkout by its `headRefOid`, which must equal this HEAD: after a
branch lands, the next lane can check the same name out again and commit new work, and
a name-only match would "prove" that unlanded work disposable (the revocable-ref waiver
at rule P rests on the same equality — GitHub holds the **PR's** sha, not necessarily
this one). And because `--state all` spends ONE limit on every state, a repo with a long
merged history can exhaust it; gh then returns the newest N rows and silently drops the
rest. An absent row is NOT "no PR" — inside the floor it is rule 6, past the floor the
aged rule — so a row count AT `REAP_WT_PR_LIMIT` is a **refusal** (exit 3, nothing
removed), never a KEEP: a live branch must not be reaped on a list that never
contained it. The bound therefore has to exceed the largest repo's total PR
count — **`REAP_WT_PR_LIMIT` defaults to 5000** because `daniel-ospina/tortoise`
measured **3,987** PRs across all states on 2026-10-24, and a default below that
would refuse every pass on the very repo with the most worktrees (a reaper that
reaps nothing is the failure this change exists to remove). `gh` pages past 1000,
so a bigger repo is a bigger number here, not a code change.

**Rule 7 is the freshness floor, and its witness is two-sided.** A lane dispatched
minutes ago is detached at `main`, clean and holder-free for exactly the same reason an
abandoned checkout is; only time separates them. HEAD's *commit* date does not measure
that time — a checkout created minutes ago from an hours-old `main` has an hours-old
HEAD — so the age is the **younger** of HEAD's commit date and the checkout's own
ctime (`REAP_WT_TREE_TS` supplies an already-measured value for a caller that probed
the tree). Nothing younger than 45 minutes is removable by rules 3–4, and the footer
records `MIN_AGE_MINUTES=` so the floor in force is auditable.

⛔ Rules 3–4 still require the commit to be *survivable*: a checkout whose commits are
held only by `refs/remotes/*`, a tag, stash or a bisect ref is preserved with that ref
named, **except** when the PR is `MERGED` **and its head is this commit** — GitHub then
durably holds that sha, so the merged PR is the stronger proof and rule 4 applies.

Rule 4 also honours the merged cooldown: a PR-merged head takes
`REAP_WT_MERGED_AGE_DAYS` (and a scratch cap may only lower it), exactly like the
ancestry proof — and unlike patch-equivalence, it does not need `git cherry` to have
seen the squash (a multi-commit branch squashed into one commit has no per-commit twin).

**Patch equivalence (a squash the ancestry test cannot see) lifts the floor too (#2354).**
A **squash-merged** head is never an ancestor of `MAIN_REF`, so the ancestry test
alone cannot see it. `patch_equivalent()` (`git cherry MAIN_REF <head>`, no `+`
line) supplies that evidence and takes the same `REAP_WT_MERGED_AGE_DAYS` floor.
⛔ It is an AGE-FLOOR signal only, never a reachability proof: a detached head on
no ref is still `detached-unreachable` and preserved, because `git cherry` matches
patch-ids against all of main's history (a reverted change still matches, and
whitespace is ignored) and says nothing about whether any ref still holds the
commit. Multi-commit squash merges do not match either, so they stay on the floor.

**The survival allowlist has exactly ONE remove-eligible exception: `remote-holds` (#3041).**
Survival is an **allowlist** — only `refs/heads/*` counts — because a remote-tracking,
tag, stash or bisect ref is revocable by routine commands (`fetch --prune`,
`fetch --prune-tags`, `stash drop`, `bisect reset`) and the commit would then be on
nothing. That rule is right, and on its own it is **over-conservative against the remote
itself**: a tip that was pushed and whose branch still exists on the remote is
restorable with one `git fetch`, yet the allowlist preserved it for ever. The measured
cost (pi-cell-4, 2026-10-29): `examined=52 classified=52 remove=0 preserved=52`, the box
at **0 bytes free**, both repair loops at `cap: 0`, no cell able to dispatch for ~13 h;
an operator then reclaimed 62 clean checkouts (7.7 GB) by hand, losing no commits.

So a tip held only by `refs/remotes/<remote>/<branch>` is remove-eligible **only** when the
remote advertises **exactly this HEAD sha** at that branch — and, because the advertisement is read
ONCE per remote per pass, that fact is **re-proved against the remote at the moment of the
removal** (`remote_holds_recheck`: one targeted `ls-remote --heads <remote> refs/heads/<branch>`,
same exact refname+sha compare). The snapshot is CLASSIFICATION evidence; a branch auto-deleted on
merge between the snapshot and the fork would otherwise make "the remote still holds this head"
false at the instant a checkout with **no backup** is destroyed. The cost is ONE targeted probe per
`remote-holds` candidate at classification, plus a SECOND at the fork for one that reaches re-check
#3 — so a removal pays two, a preserve by `clean_gate`/gate (b)/the ladder pays one, and a preserve
**at the fork** has already paid two; the second is the decisive one. A failed, timed-out or empty
targeted probe at removal time preserves.

The remote's own `refs/heads/*` are read by ONE bounded `git ls-remote --heads <remote>` **per remote
per pass** (#3371) and cached for that pass. That is what took the per-candidate round trip out of the
**classification**: it used to cost ONE targeted `ls-remote` per `remote-only-ref` candidate, one
network round trip each, which is what made a large `remote-only-ref` population unable to finish a
pass (measured on cmux/cell-3, 2026-11-07: 12 targeted probes = 7.54 s wall (0.63 s each), versus 0.56
s for the remote's whole 2,111-head advertisement). The cached advertisement is the same evidence **for
the CLASSIFICATION only** — the remote's advertised heads at one instant, a superset of any single
targeted answer *at t0* is not evidence of anything at the removal, which is exactly why
`remote_holds_recheck` re-takes it — and the advertised refname is still matched literally and exactly
once against it (⚠️ because `ls-remote` matches a pattern against the ref's **tail, from any slash
separator**, so `refs/heads/<b>` also selects an advertised `refs/heads/x/refs/heads/<b>` — ⛔ *not*
because of glob metacharacters: `check-ref-format` rule 5 forbids `?`, `*` and `[` in a refname, so no
branch name can widen the match that way), and the remote is the **longest configured remote name**
prefixing the ref, not the first path segment (a remote name may contain a slash). Any failure,
timeout, empty answer, unadvertised refname or different sha at **classification** leaves the verdict
where it was — `remote-only-ref`, PRESERVE — and a TRANSPORT failure is remembered for the rest of the
pass so a dead remote costs one timeout, not one per candidate. ⛔ At **removal** the preserve verdict
is different and the operator will see it: a `remote-holds` row whose targeted re-probe can no longer
re-prove the head is kept as **`remote-holds-stale`** (`remote_holds_recheck`, taken twice — at
classification and again immediately before the fork). Treat that as "the remote moved under us": the
checkout is intact, and — if the preserve happened at the **fork** — the archive it had just taken is
kept too (a **classification-time** preserve never entered `remove_one`, so there is no archive to look
for). The commit is what to look at, not the checkout. The row is `remote-holds:<remote>/<branch>`, and
— like `remote-only-ref` — it does **NOT** block the end-of-pass prune: a `remote-holds` row is reached
only when the commit is held by `refs/remotes/<remote>/<branch>` (the probe runs on that very ref), so
the admin `HEAD` is not the commit's last durable handle, and the F17 window (a record that becomes
prunable mid-pass, after a snapshot that saw it present) is closed for **every** reason by the
reason-independent pre-prune re-read. Blocking on the reason instead would disable the `prunable`
reclaim path for as long as ONE preserve row lives — `no-pr`, `too-recent` and `too-young` rows carry
`refs=remote-holds:` too, for up to the whole aged-days floor — which is the F7 defect one reason class
over. A26c pins both arms (the `reason=` REMOVE row and the `refs=` PRESERVE row).

A lane **scratch** checkout — a directory whose basename matches
`REAP_WT_SCRATCH_GLOB` (default `wt-*|cell-wt-*`) — has its floor **capped at**
`REAP_WT_SCRATCH_AGE_DAYS` (default `1`): a dead lane's throwaway dir is not a
week's worth of review surface. The cap only ever lowers, so a value above the
floor in force has no effect (14 does not mean "keep longer"), and a
merged/patch-equivalent scratch row keeps `REAP_WT_MERGED_AGE_DAYS`. Every other
gate still applies, and the pattern is anchored (`wtfoo/` is not `wt-*`), so a
named checkout is unaffected.

## Scheduling — installed by the bring-up, armed by owner instruction

**Cadence, derived from the measured growth rate rather than chosen.** On cell-3 (2026-11-03) the
estate created **80 worktree directories in 24 h** (≈3.3/h, bursty: 16 in one hour, 14 in another) at
~250 MB each — **≈20 GB/day** inflow — and the pass reclaimed **one** checkout per run. An hourly
cadence is *sufficient* at that rate (one sweep must clear ≥1 h of traffic to hold the line), which is
why the fix is YIELD, not a faster timer: the same hourly pass with the lane-evidence gate reclaims
the backlog the veto was holding, and then keeps pace. A daily cadence would have to reclaim ≈20 GB
in one burst; an hourly one never faces more than a few GB. `Persistent=true` matters on these cells
for the same reason — a suspended cell must run a pass as soon as it resumes instead of waiting out an
interval at the threshold.

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
~1.1 GB of `.venv` (measured on APFS with **no** sharing between the venv and the uv
cache — `du` 5,647 MiB vs `df` 5.90 GB released, ratio 1.004; where this box *does* share
blocks the apparent figure is larger than the space removal frees, which is exactly why the
regime must be measured with `scripts/worktree-disk-probe.sh` and not inferred), so a box with
8 GB free can hold about seven live lanes no matter how aggressively its dead residue is reaped.

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

The **state dir is resolved, not assumed** (#2443). The configured dir is used whenever a byte can be
written to it; when it cannot (a full disk — the exact condition the pass exists for), the lock, log,
scratch and record move to the first writable tmpfs candidate in
`DISK_REAPER_STATE_DIR_FALLBACKS` (default `$XDG_RUNTIME_DIR/pi-disk-reaper` then
`/dev/shm/pi-disk-reaper-<uid>`), and the pass says so on its own output. `DISK_REAPER_TMPFS_ROOT`
relocates where the default fallback lives (default `/dev/shm`), and an **EMPTY**
`DISK_REAPER_STATE_DIR_FALLBACKS` disables the fallback entirely, restoring the pre-#2443 hard refusal
for a box whose configured state dir must be the only one (T46 pins that arm). **The three delegates are
given that dir too** (`CACHE_REAP_LOCK`/`CACHE_REAP_LOG`, `REAP_WT_STATE_DIR`/`REAP_WT_LOG`,
`REAP_VENV_LOG`, and `TMPDIR` for scratch) — on a full disk each of them would otherwise fail closed at
its OWN lock and log in the same unwritable directory, so the pass would "run" and free nothing. The
record then carries
`state_dir=` (where the pass ran) and `state_dir_primary=` (the configured dir it could not use), plus
a `detail=` naming the reason. A writable configured dir produces the unchanged record — no extra
field, no fallback. The record itself is written to the **configured** path whenever that path is
writable at the END of the pass (a pass that freed the space may have just unblocked it), so the
supervisor's read path is preferred and the fallback path is the last resort. With no writable
candidate anywhere the pass REFUSES (exit 3) and names every candidate it tried — a pass with no
lock and no readable record is not a pass (T46, T55).

A fallback pass also refuses to run beside a **live pass** (T55f/T55b): the fallback only proves the
configured dir is unwritable *now*, and a pass that started while it was writable can still be running
and holding that lock. Because a fallback pass hands the delegates its own state dir, their locks move
too, so nothing else would keep two `uv cache prune` / `git worktree remove` runs off the same tree.
**The lock is ONE canonical path**, `${DISK_REAPER_TMPFS_ROOT}/pi-disk-reaper/disk-reaper.lock` —
deliberately not keyed on the uid, on `$XDG_RUNTIME_DIR`, or on which fallback candidate was resolved,
because those are exactly the inputs that differ between a **system unit**, an interactive shell and a
pass run by hand as another account. A lock whose *name* depends on them is a lock those passes do not
share. Every pass checks the canonical path **and its own configured dir's**, so the ordering this
paragraph is about — a healthy pass starting while a fallback pass still runs, the fallback having just
freed the space — is closed (T55f4b), not traded, because one fixed path costs a single stat. (Two
passes under **different accounts** each check their own configured dir, so the older pass's
`$HOME` lock is still not visible to the other; that is unchanged from before the fallback and is why
every pass on a box should share one `DISK_REAPER_STATE_DIR`.) Enumerating "my candidates" / "my uid's tmpfs dir" was tried and abandoned: each variant
made the set a function of the checker's environment, and each left a reachable ordering where two
passes reaped concurrently. Two further properties are load-bearing: a lock dir with **no readable
token** counts as live while it is younger than the stale bound, because the token write can fail on a
full disk where `mkdir` still succeeded (reading that as "free" was fail-open — T55f2); and liveness does **not** use `kill -0`, which
returns EPERM for a **live** process owned by another uid and so read a live holder as dead. It uses
`ps -o lstart=` plus a decision on the **exit status**: `ps -p PID` exits 1 BOTH for "no such process"
and for "I could not look" (a hardened `/proc` with hidepid, a sandboxed cell, a `PS_BIN` shim), and
folding the second into the first is fail-OPEN. A control probe (`ps -p $$`) decides which reading
applies — rc 1 means *absent* only when `ps` can report the pass's own start time, otherwise the
holder is treated as live for the stale window (T55f4e). The full-disk probe likewise never writes
through a pre-planted name: a `.disk-reaper-probe.<pid>` that already exists (file, symlink or FIFO)
refuses the candidate rather than truncating its target or **hanging** the pass on a FIFO — the
oneshot unit has no timeout, so a hang there is a silently disarmed reaper. Matching is by file identity, not
string: a trailing slash or a symlink alias must not make a pass refuse against its own lock, which
would be this feature's own failure — a green unit over a reaper that never reaps (T55f5). If the
canonical tmpfs dir is itself unusable the pass falls back to a lock inside its state dir and **says
so**: exclusion then holds only against passes that resolved the same state dir. **The canonical lock is obeyed only when this user owns its directory**, and it is only *used* then
too: `/dev/shm` is world-writable, so a token planted by another local user could otherwise hold every
pass — root's included — at exit 6, the one non-zero code the unit accepts, with no record written. A
foreign directory instead degrades the pass to state-dir locking, which the pass prints. For the same
reason a **fallback candidate** directory is adopted only when this user owns it; the configured state
dir is exempt, since a shared or root-run state dir is legitimate. **Residuals:** a peer using a
*different* `DISK_REAPER_TMPFS_ROOT` is outside the set (pin it identically on every pass); and while
degraded, exclusion holds only against passes that resolved the same state dir.

```
mode=apply ok=0 rc=6 classes=uv,venv,worktree watchdog=internal
freed_mb=515 freed_mb_uv=1 freed_mb_venv=0 freed_mb_worktree=514
verdict_uv=deferred verdict_venv=ok verdict_worktree=ok delegate_verdict_worktree=reap-ineffective
would_free_mb_* candidates_* repos=/tmp/cell-ai detail=pi-cache-reap.sh exited 7
freed_mb_runner_work=not-run candidates_runner_work=not-run cand_runner_work=not-run verdict_runner_work=not-run note_runner_work=
skipped_worktree=/tmp/cell-ai[gh-not-authenticated(rc=4)]
freed_mb_unmeasured=
```

`skipped_worktree=` is empty on a pass where every repo could be verified; otherwise it lists
`<repo>[<reason>], …` — the subject the class verdict never had, so "the worktree class is red" is
answerable as "one repo, because `gh` has no credentials here" (#2443). It is also printed by
`disk-reaper.sh --print-status`, which is the surface `cloud-cell-supervisor.sh` reads: a field the
reader does not print does not exist.

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
supervisor prints the raw value).

⛔ **AND THE PASS TOTAL FOLLOWS THE SAME RULE, FOR EVERY CAUSE (#3057 review).** When ANY class's figure
is `unmeasured` — `df` silent, the owner silent, **a class that could not be set up** — an APPLY pass records
`freed_mb=unmeasured` and `freed_mb_total=unmeasured`, because a sum with an unconfirmed term is not a
measurement. ⛔ **THE ALARM IS *NOT* BUILT ON THAT SUM, AND AN EARLIER REVISION OF THIS PARAGRAPH SAID IT
WAS** (#3057 review cycle 2): `alert=under-reclaim` was gated on `_total_unmeasured = 0`, so one unrelated
unmeasured class silenced it on a pass whose measured classes demonstrably did not keep up — measured
(`--only venv` alone alerts; `--only venv,runner-work` with the owner missing alerted NOTHING). It is now
gated on `_measured_total`, which is `none` only when NO class measured anything (so a pass whose only
class never ran still cannot say "did not keep up"), and `alert_detail` labels its figure a lower bound
when another class went unmeasured. The measured
part is not lost: the pass-end line prints it as `freed_df=unmeasured (measured classes: NMB)`, the sum of
the classes that were **SELECTED** and measured — `none` when that set is empty, because a deselected or
never-set-up class contributes nothing and printing `0MB` for a pass in which no class actually ran is the
same invented zero one surface over (#3057 review cycle 2, P2: keyed on `DF_*_OK` alone it read
`measured classes: 0MB` for a pass whose only class never ran). That line now also names the third cause
(`could not be set up: <class>`) beside the two it already carried, so the figure and its reason travel
together. **A DRY RUN IS THE EXCEPTION**: it removed nothing, so `freed_mb=0` there
is a real measurement and is recorded as one.
⛔ **THE THIRD CAUSE WAS DOCUMENTED AND NOT IMPLEMENTED, AND THAT IS THE WORST OF THE TWO** (#3057 review,
P2). Every setup-failure arm pins `DF_<class>_OK=1` — deliberately, so `detail=` does not blame `df` for a
failure `df` did not cause — and that pin was the ONLY input to `freed_mb_unmeasured=`, so a class that
never ran was summed as its initialised `0`. MEASURED on the ARM the installed unit runs (`--apply --only
runner-work`, an explicit seam matching nothing, `DISK_REAPER_LOW_FREE_MB=999999999`), before the fix:
`freed_mb=0` beside `freed_mb_runner_work=not-run` and `candidates_runner_work=?`, plus
`alert=under-reclaim` — "the pass RAN and did not keep up" about a pass whose only class never ran — while
`detail=cannot run: runner-work-no-root` said the opposite on the line above. The predicate is the one
`candidates_` already used (`misconfigured` means SELECTED BUT UNMEASURED, which is why `WANT=0` alone
cannot be read as "never selected"), so the two totals on one record cannot disagree again. ⛔ **NOT EVERY
`misconfigured` CLASS BELONGS IN THAT LIST**: the worktree class stays `misconfigured` when its REGISTERED
arm could not be set up while its ABANDONED arm ran and measured a reclaim — that class HAS a measurement,
and tainting the total with it would report `unmeasured` on a pass whose every running class answered.
Case **(f)**'s armed half pins the rule on both sides (the fields, and the alert that must NOT fire).

⛔ **`detail=` NAMES THE CAUSE, and the two causes are not interchangeable.** `df could not measure the
reclaim for:` — the mount did not answer. `owner never answered its ledger for:` — a sweep was cut short
at `CLASS_TIMEOUT`, so `df` ANSWERED and the class's own ledger did not; blaming `df` there sends an
operator to the mount for a cut-short ledger. `freed_mb_unmeasured=` stays a single list either way
("whose reclaim was not measured" has one answer); only the reason is split.

⛔ **The worktree class is REPORTED, not just counted.** `pi-reap-worktrees.sh` ends every pass with
ONE machine-readable line —

```
SUMMARY examined=<n> classified=<n> remove=<m> preserved=<k> deferred=<n> deferred_remove=<n>
        removed=<n> failed=<n> late_preserved=<n> prune_blocked=<0|1> reasons=<reason>:<n>,…
        main_proof=<auto|local|unavailable|auto-unfetched|ambiguous>
        main_ref=<refs/heads/…|refs/remotes/…|?> pr_merged=<ok|na|unavailable>
        stalled=<n> verdict=<dry-run|reclaimed|idle|reap-ineffective|unmeasured>
```

`stalled=` is the STALLED REVIEW LIST's tally (agent-infra#2179): 0-commits-ahead lane residue this
pass did NOT release and no later pass will release on its own. It is an exact SUBSET of
`preserved=` — a selected removal that failed is counted under `remove=` and reported by
`failed=`/exit 4 instead, so `preserved - stalled` can never underflow. A non-zero tally is followed
by the list itself, each row naming the ISSUE its branch holds out of dispatch with its age, its
class floor it is past (`<n>h` — always an hour count: a record that cannot be dated is never listed)
and the reason.

⛔ **`verdict=` is the pass's own ANSWER, and the counters alone cannot supply it (#3041).** A pass
can be perfectly self-consistent (`examined=52 classified=52 remove=0 preserved=52`) while reclaiming
NOTHING on a box at 0 bytes free — pi-cell-4, 2026-10-29: that pass was the whole incident, and every
number in it was true. So the pass must also say what its numbers MEAN:

| `verdict=` | condition |
|---|---|
| `dry-run` | the pass was not armed — nothing may be removed, and that is the correct answer |
| `reclaimed` | armed, and at least one checkout was removed |
| `idle` | armed, removed nothing, and the **reason** is benign: free space is at or above the floor, or fewer than `REAP_WT_INEFFECTIVE_MIN_EXAMINED` records were **examined** (not *classified* — a budget-starved pass defers the rest, and deciding two of fifty-two while removing none on a full box is the incident, not an idle pass) |
| `reap-ineffective` | armed, examined `>= REAP_WT_INEFFECTIVE_MIN_EXAMINED` (default 10) records, removed NONE, and free space is UNDER `REAP_WT_DISK_FLOOR_MB` (default 4096 MiB) — a reaper that cannot reclaim on a full box |
| `unmeasured` | the condition depended on free space and `df` could not answer — **never** read as `idle` |

⛔ **`reap-ineffective` also writes a durable record**, `$STATE_DIR/reap-ineffective.<repo>`, atomically
(tmp + `mv`), carrying `verdict=`, `epoch=`, `repo=`, `mode=`, the counters, `free_mb=`, `floor_mb=`,
`reasons=` and a one-line `remedy=`. A **summary line is not a verdict**: the line is gone when the
next pass prints, and the incident is only visible afterwards if something durably said so. Any pass
that **evaluated** the condition and found it not held REMOVES the file — so the record's presence
means *the condition holds now*, not *it once held*; `unmeasured` deletes it too (a disk we could not
read is not a disk we proved healthy).

⛔ **ONE RECORD PER REPO, not one per state dir.** `disk-reaper.sh` runs the worktree delegate once per
repo **with the same state dir**, so a single fixed filename is last-writer-wins ACROSS repos: an
ineffective repo followed by any repo with room had its alarm erased by a pass that never looked at
it — measured in a fixture. The path therefore carries the checkout's basename (readable) plus a
`cksum` of its canonical path (unique, so two checkouts named alike cannot collide), and each record
is owned by that repo's own pass. Presence means *THIS repo's condition holds, as of its `epoch=`*;
sum the records to read the box. The residual, stated: dropping a repo from `DISK_REAPER_REPOS`
leaves its last record behind, so compare `epoch=` rather than assuming the newest pass rewrote every
file.

⛔ **A `--dry-run` never touches the record.** It removes nothing by construction, so it has evaluated
none of the live condition and cannot say whether the condition holds. This matters because
`disk-reaper.sh` **defaults** to `DISK_REAPER_DRY_RUN=1`, so a "delete unless the verdict is
reap-ineffective" rule let a routine dry run on a full cell erase the armed pass's alarm.

A fail-closed abort evaluated nothing, so it neither writes nor deletes the file. ⚠️ **Not every abort
prints a footer**: the `git worktree list` failure, the empty-list refusal, the unwritable-log refusal
and the lock-held refusal exit 3 before a footer is reachable (the unwritable-log one cannot log
anything at all), while the `gh` and `ps` aborts do print one — and where a footer is printed it
carries `VERDICT=?`, never an empty field. ⛔ **A record that could
not be WRITTEN says so** (log `record=NOT-WRITTEN`, and the pass states that the verdict exists only
on its own line): this branch fires when free space is under the floor, i.e. exactly when `ENOSPC` is
live, so a missing file is never evidence that the condition cleared. `REAP_WT_FREE_MB` (a witness)
and `DF_BIN` are the test seams; the measured paths are `df -Pm <repo>` under `REAP_WT_DF_TIMEOUT`.

— and the record lifts it into `candidates_worktree=` (the delegate's own `remove=`),
`classified_worktree=`, `preserved_worktree=`, `preserved_reasons_worktree=`, `main_proof=`,
`pr_merged=` and `delegate_verdict_worktree=` (the delegate's own `verdict=`; it carries the same
`?`/`not-run` vocabulary, but **not** `main_proof=`'s disagreement polarity — see below; it is printed
by `--print-status` **and** on the cell health verb's
per-class line (`scripts/cloud-cell-supervisor.sh`, `⛔ worktree-delegate=`) — a field the reader does not print
does not exist, so a status channel that showed only `worktree=ok` for an ineffective reap was
publishing the incident's own misleading sentence — and it is deliberately SEPARATE from
`verdict_worktree=`, which stays the exit-code reading — an ineffective reap exits 0 by design, so
without this field the fleet's record said `worktree=ok` for it).

⛔ **A DISAGREEMENT IS NOT ONE THING, because this field feeds an ALARM.** `main_proof=` and
`pr_merged=` collapse any disagreement to `mixed` and nothing reads that token. This field is printed
with a ⛔ for every value outside the benign allow-list, so the same rule would mean two opposite
things at once on the multi-repo shape (`DISK_REAPER_REPOS`, or `--repo` repeated):
`reap-ineffective` + `idle` (**the alarm**) and `reclaimed` + `idle` (**two ordinary readings**) would
both read `mixed`, painting a ⛔ onto healthy cells and making `⛔ worktree-delegate=reap-ineffective`
unreachable. The aggregation therefore gives the **alarm class precedence** and spells the two cases
differently (`scripts/disk-reaper.sh`, `_dclass`):

| answers across repos | record | cell health verb |
|---|---|---|
| all agree | that answer | `ok`/`?`/`not-run`/`dry-run`/`reclaimed`/`idle` are silent; anything else prints ⛔ |
| ordinary readings disagree (`reclaimed` + `idle`) | `mixed-benign` | silent |
| an alarm answer, alone or beside any benign answer | **that alarm**, e.g. `reap-ineffective` | `⛔ worktree-delegate=reap-ineffective` |
| two DIFFERENT alarm answers (`reap-ineffective` + `unmeasured`) | `mixed` | `⛔ worktree-delegate=mixed` — the only case where the cell cannot say |
| a spelling this reader has not been taught | itself — the benign side is an allow-list | ⛔ (fail-loud) |

The class is an ALLOW-LIST and not a deny-list for that last row: a verdict added to the reaper later
must be SURFACED by a reader that was never taught it, never silently swallowed by one. `examined = classified + deferred` and `classified = remove + preserved` are the two
identities, and a deferred REMOVAL is its own counter: an armed overrun defers a record whose verdict
was already `remove`, so folding it into `deferred` would deflate `preserved` and make the line
contradict itself. `main_proof=` names which source proved "merged into main" (`auto` = the remote
ANSWERED — its advertised default branch, or, when `--symref` itself did not answer, the first of
`refs/heads/main`/`refs/heads/master` that exists there; the branch that actually resolved is
printed in `main_ref=`, so a guessed default is visible; `local` = the local ref chain, used when
`auto` claimed no evidence, `unavailable`/`ambiguous`/`auto-unfetched` = no evidence claimed), and
`pr_merged=` says whether the pass's batched
`gh pr list` read was answerable at all (`ok` / `na` no GitHub origin / `unavailable`; the
record reports `mixed` when two repos in one pass disagree). ⛔ **`main_proof=` and `pr_merged=`
obey the SAME coverage rule as the counters**, because they are accumulated the same way (over the
repos that answered, with `mixed` as the disagreement sentinel): on a pass where only SOME of the
scanned repos produced a `SUMMARY`, all of them read `?` — including on the class line, which used
to print the raw last-answering value while the record printed `?`, so one pass published two
contradictory answers about how its merges were proved. The class line carries `tally=<answered>/<scanned>`,
which is what makes a `?` here diagnosable rather than mysterious. ⛔ **Every one of these fields
reads `?` — never `0` — when the class was SELECTED but produced no measurement**, and `not-run`
when the class was **not selected at all**. "Selected, no measurement" covers both a delegate that
ran without printing a tally and a class that could not be SET UP (a missing delegate, no repo to
scan: `want_class` was true and the record says `verdict_<class>=misconfigured` —
`candidates_worktree=?` on that path, pinned by T60). The one exception is the **venv** class: its
setup-failure arms deselect it (`WANT_VENV=0`, because there is nothing left for it to measure), so
its counters read `not-run` there. Neither token is a count — a refusal (`FAIL-CLOSED gh
unavailable`) is not a measurement, and a measured zero beside an unknown classification is the
false PASS this record exists to remove. Two of the FIVE classes cannot answer the CANDIDATE count on
every pass and say so rather than guessing `0`: `uv` (its owner publishes no tally, so an ARMED pass —
which has no `DRY-RUN` rows to count — records `candidates_uv=?`), and `duplicate-install` only when its
own `SUMMARY … candidates=<n>` did not answer (that delegate prints it in BOTH modes, so an armed pass
normally CAN answer). `runner-work` (the fifth, added 2026-10-28) is in that same position — its owner
prints `SUMMARY class=runner-work … candidates=<n> … census=ok` in BOTH modes, so an armed pass answers
a real count; `census=no-roots` (an EXPLICIT glob list that matched nothing) is `misconfigured` + `?`
rather than a `0`; `census=refused` (a matched root REFUSED because its basename is not `_work`) is
`misconfigured` + `?` with its own `runner-work-root-refused` token, so the record names the seam rather
than a glob that matched; and **`census=abstained`** (nothing under a matched root could be measured, so the
population was never measured) is `?` plus `verdict_runner_work=abstained` at rc 0, while
**`census=partial`** (SOME of the population could not be measured) keeps the measured count as a LOWER
BOUND and answers `verdict_runner_work=partial` — in both cases a zero nothing measured is not a zero,
and a non-`ok` verdict never lands as `ok`. ⛔ **AND BOTH NOTES STATE THE TALLY WITHOUT PICKING A CAUSE**
(#3057 review cycles 2–3): `unmeasurable=` has three causes — an unreadable entry, an unlistable root, and
a root **replaced** between discovery and the sweep — so a note that says "could not be read" names a
permissions fault that may not exist and aims the operator at the wrong remedy (restore the swapped
`_work` vs `chmod`), which is the same defect this file records for the class line's cause.

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
| 3 | **fail-closed**: a delegate returned its own `3` (it could not measure, verify or reach a probe), a delegate is missing or a class had no repo to scan (per-class `verdict=misconfigured`, record `freed_mb_<class>=not-run`), the pass record could not be written, or a delegate could not run as asked (its `2` = bad arguments, `124` = timeout, `126`/`127` = no such binary). **Also a refusal at startup** when `scripts/lib/bounded.sh` is missing, `TB_TIMEOUT_BIN` is unusable, **neither the state dir nor any `DISK_REAPER_STATE_DIR_FALLBACKS` candidate can be written** (#2443 — a pass with no lock and no readable record is not a pass; the refusal names every candidate), or a numeric seam (`DISK_REAPER_STALE_SECONDS`, `DISK_REAPER_LOCK_STALE_SECONDS`, the timeouts, the `du` budget) is not a number — or is a digit string too large for the shell to compare (`[ ... ]` parses with `strtoimax`, and an out-of-range value makes the COMPARISON error and take the `else` arm, so such a bound is refused rather than silently ignored: at most 9 digits, ~31 years) — no per-class line is printed there | red |
| 4 | a class completed but at least one removal FAILED; a lock directory that cannot be created at all (a filesystem problem NOTHING could work around — the state dir was writable when it was resolved, so this is the mid-pass case); or the **pass record cannot be written** while the verdict was a green one (with no record there is no alarm channel, so 5/6 escalates to 4) | red |
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

`scripts/disk-reaper-classes.test.sh` covers the two #2542 classes and is **mutation-checked**: each
case runs twice, once against the real owner (must pass) and once against a mutant of the same file
with that case's arm neutered (must fail), so a case that has stopped checking anything says so.

| case | proves | mutant that must turn it red |
|---|---|---|
| A | an old directory with a **live cwd** inside is KEPT and named, while an identical old directory in the same run is reaped | `if lp_path_held …` → `if false` |
| B | an old directory with **no** live cwd is reaped **and the entry point reports a `df` delta** (not a `du` sum) | `if remove_one …` → `if false` |
| C | with the process list **unreadable** the sweep is skipped and reports the skip (exit 3, nothing removed) | `if ! lp_census …` → `if false` |
| D | the **pinned sha** is never reaped, by name and by path, while a sibling candidate in the same run is | `if pinned …` → `if false` |
| E | duplicate-install **keeps the last copy**: newest never a candidate, live-hosted copy kept, only the provably-idle surplus removed | `[ "$c" = "$newest" ]` → `[ "$c" = "__never__" ]` |
| F | with **no resolvable repo** the abandoned arm still runs (the #2443 shape: the registered arm fails closed as `misconfigured`, the arm that needs no repo does not) | `REPO_ARM_OK=0; REPOS=""` → `return 3` |
| G | a class that removed **nothing** reports `freed=0` and names the un-attributed `df` change in the pass record, instead of claiming another process' free space as its own | `if [ "$reaped" = 0 ] && ! is_dry` → `if false` |
| H | a **symlink** in the scratch root is never followed out of it: the link is kept and named, the target outside the root is untouched | `if [ -L "$d" ]` → `if false` |
| I | a tree **git cannot read** is not a clean tree: `dirty=?` KEEPS it (`reason=clean-unknown`), so uncommitted work survives a dangling `.git` | `dirty="?"` → `dirty="0"` |
| J | a lock whose owner is **live** is honoured by both owners (`SKIP reason=lock-held`, rc 3, lock left in place) | `kill -0 "$owner"` → `false` |
| K | a class that could not be **set up** is `misconfigured` (not `fail-closed`, which means the delegate ran) | `AW_SETUP_FAIL=1` → `:` |
| L | a live process that names the tree through a **symlinked** spelling still protects it — sub-path, alias-to-tree, and `--flag=<abs>` (argv tokens are canonicalised) | `_lp_rel "$_cand" "$path"` → `_lp_rel "" "$path"` |
| M | an **EMPTY census** on the `lsof`/`ps` arm is a refusal, never "nothing is live" (the `ps` block's early `return` used to skip the empty-table gate) | `if command -v "$_lp_ps_probe" …; then` → `… || return 0; if true; then` |
| N | **re-probe before removal**: a lane that enters an old, clean worktree DURING the pass preserves it (`reason=toctou`) | `if ! toctou_preserve "$canon"; then` → `if false; then` |

The newest class has its own suite, `scripts/disk-reaper-runner-work.test.sh` — **23 case runs + 43 mutants,
66 outcomes per box**, plus **3 top-level assertions on the owner's own source** (the
pre-removal re-probe, which no existing case can drive behaviourally — see the comment at the assertion), so
**69 outcomes** in total (case (s) is driven TWICE, at its two vanish sites), each outcome passed or failed — also mutation-checked. A run ADDITIONALLY states how
many arms it **skipped** — ⛔ not "a third outcome": `skipped` is counted on its own line, orthogonal to
the outcome tally, because an arm that did not run proves nothing and must not be read as one that passed. Run
against the PRE-CHANGE tree (`origin/main`'s `disk-reaper.sh` beside this tree's owner) it reports **29 passed,
40 failed, 5 skipped**, and against this tree **69 passed, 0 failed, 8 skipped**: the discrimination is
measured both ways, not asserted. (The red on the pre-change tree is 20 of the 23 case runs — every case whose
subject runs through the ENTRY POINT, which on that tree has no `class=runner-work` at all: (a), (b), (c),
(d), (e), (f), (g), (h), (j), (k), (l), (n), (o), (p), (r), (s) BOTH arms, (t), (v) and (w); the owner-only cases (i), (m) and
(q) stay green — plus **20** mutants that cannot even be applied there, because the arms they edit do not
exist in that tree. The 23 mutants that DO still apply are reported "caught" only because their case is already
red on that tree, so the green run above is the discriminating measurement, not that one. The two rows
COMPOSE: 20 red case outcomes + 20 unappliable mutants = the 40 failures, and 23 applicable mutants (each
"caught") + the 3 owner-only cases + the 3 top-level assertions = the 29 passes.)
⛔ **THESE ARE NOT FIXED NUMBERS — re-derive them.** The failure row is stable, but the SKIP count is a
function of the host AND the tree: 8 on a box with real runner roots for this tree, 5 on the pre-change tree
(two `(f)` sites, `f4` twice — the base entry point records no measured `duplicate-install` figure — and
`v1`), plus one per case-(v) invocation whose pass observed no `df` delta. A row that quotes a skip count
without saying which box produced it is how this paragraph was wrong at three consecutive heads.

⚠️ **A gap that WAS disclosed, and is now CLOSED by measurement — BY THE SUITE THAT ACTUALLY ASSERTS IT.**
The class's **record fields** at the ENTRY-POINT level (`freed_mb_runner_work=`,
`candidates_runner_work=`/`cand_runner_work=`, `unmeasurable_runner_work=`, `verdict_runner_work=`, and
`--print-status` rendering them) are asserted by **`scripts/disk-reaper-runner-work.test.sh` case (b)** —
the case that drives a real `--apply` and then reads back **every** field of the record that pass wrote.
⛔ **"only case" is true of the FULL FIELD SET, and NOT of reaping — and an earlier revision of this
paragraph said the latter and was measurably false.** It read "the only case in that suite that drives a
real `--apply` and then reads back the record that pass wrote". Measured against the suite: case **(a)**
drives `--apply` and reads the record the pass wrote; case **(g)** — `case_g()`, which
`grep -n 'case_g()'` locates — drives `--apply`, reads the record **and reaps**: its own assertion
"and it reaped the dead entry on the pass the fallback exists for" **passes**.
⛔ **These citations were bare line numbers for three revisions and were WRONG in all three, so they are
content anchors now.** The numbers drifted on every insertion above `case_g()` — `:467`/`:469`/`:472`
landed on `PASS_OWNER=`, `dead="$(mk_entry …)"` and a `mkdir`; then the block moved to `:468` and was
reported stale; the fix for that wrote `:550` and the very act of CORRECTING it moved it to `:552`. Each
statement is now named by the text that proves it (`bash "$pass" --apply --only runner-work`,
`st="$(status_of "$fb")"`, `and it reaped the dead entry …`, `grep -n 'case_g()'`), which is the durable
evidence this paragraph claims to want. At the *prior* head `301235ef8`, case (g) already
reaped **and** already asserted `^verdict_runner_work=ok$`. So (b) is not "the only case that reaps"; it is
the case that reads the **whole** field set on a reaping pass, which is a different and narrower claim.
⛔ **That credit was WRONG for one revision, and wrong in the one direction that matters.** It named
`scripts/disk-reaper-classes.test.sh` as the suite covering these fields. That suite asserts **nothing**
about this class: `grep -nE 'runner_work|--print-status' scripts/disk-reaper-classes.test.sh` returns no
output, and its record-field assertions are `freed_mb_worktree=`, `verdict_worktree=` and
`freed_mb_duplicate_install=`. So the evidence chain pointed at an instrument that would have stayed
GREEN with every runner-work assertion deleted — the same shape as the three findings this revision
exists to fix, an assertion that looks like a check and is not. **The boundary, stated so a reader need
not infer it:** `classes.test.sh` covers the WORKTREE and DUPLICATE-INSTALL record fields; this class's
are covered by `runner-work.test.sh` case (b). ⛔ **`verdict_runner_work=`'s gap is NARROWER than
"asserted nowhere", and the previous wording overstated it on both halves.** The field WAS asserted at the
ends of (f) and (g) — and (g) reaps, as measured above — so "asserted in (f)/(g), and neither of those
reaps" was false in each clause. What was actually missing, stated so a reader can check it: the field was
**unasserted on case (b), the primary reaping path that reads every other record field**, and
`--print-status` — the field's only READER — had **no assertion at all** anywhere in the suite (the only
`print-status` reference in `runner-work.test.sh` is the one added at this revision). So it now reads `ok`
on case (b)'s reaping pass (measured at this head), `--print-status` is asserted to RENDER it, and deleting
the record line turns case (b) red: that mutation is (b)'s second, counted among the 39 above.
The classes suite was **killed at 30 minutes with no result** on the box that measured this PR (load
180–220), so at that point the record-field delta was **unmeasured** and a green run of the owner-level
suite below could not be read as covering it. It was then **run to completion at load ~15 on the same
8-core box**: `1 failed, 32 passed`, and the single failure is case **N** (a tree that CHANGES during the
pass is preserved, `reason=toctou`) — the same case and the same count as the pre-change baseline, i.e.
pre-existing and not this class's. That tally is recorded here as what it is — the classes suite's own
result, on the fields it actually asserts — and **not** as this class's evidence, which it never was. The
record fields are MEASURED at this head by case (b) (`69 passed, 0 failed, 8 skipped` at this head on this
box — it has real runner roots, so the (f) empty-population arm is skipped by name; the earlier
`0 skipped` row was taken on a laptop and is not restated as this head's); the caveat that
stood here for one revision is recorded rather than dropped silently, because "we could not measure it"
and "it is fine" are different claims and only the first one was ever true.

The measured transcript, `./scripts/disk-reaper-runner-work.test.sh`, at this head on a box that HAS
real runner roots (so the (f) empty-population arm is skipped by name):

```
  69 passed, 0 failed, 8 skipped
```

and the same suite with `DR_REAPER=` `origin/main`'s `disk-reaper.sh` (the pre-change tree, beside this
tree's owner):

```
  28 passed, 40 failed, 3 skipped
```

⛔ **THESE TALLIES WERE RE-MEASURED BECAUSE THE SUITE CHANGED, NOT BECAUSE THE ARITHMETIC LOOKED WRONG.**
This revision adds case **(r)**, case **(s)** (the vanished-entry race, with its own instrumented owner and
mutant), case **(t)** (the same race one level up — the ROOT — which was asserted only by prose until now),
case **(v)** (the two tallies the record used to drop, four arms) and mutants `o2`, `r1`, `r2`, `s`, `t` and
`v-cs`/`v-gone`/`v-rr`, so the previous head's `43`/`31` rows describe a suite that no longer exists; both
numbers above were taken by running the suite at this head,
and the pre-change row is the same command with `DR_REAPER` pointed at the base commit — **20 case outcomes and
18 unappliable mutants** are red there simply because the base entry point has no `class=runner-work` at
all, and it reports **5 skips, not 8**, for THREE reasons: only two of the eight `(f)` invocation sites get
that far on a tree whose entry point refuses them earlier; `f4`'s two-class arm cannot measure there (the
base entry point records no measured `duplicate-install` figure); and case (v)'s conditional positive
half fires DETERMINISTICALLY there — the base entry point emits no `df_raw` at all, so the arm that needs a
nonzero delta can never run and now says so instead of vanishing (measured: `29 passed, 40 failed,
5 skipped`, one of the skips being `v1 positive half`). That pre-change run is a discrimination check, not
evidence: every mutant it reports "caught" is caught only because its case is already red.

⛔ **A RUN AS ROOT IS ALSO A MEASURED, NON-GREEN-NEUTRAL OUTCOME, and it used to be a FALSE PASS.** Cases
(g), (l) and (r) exist to make a directory unreadable or unwritable, which `chmod` cannot do to root: each
now calls `skip()` and returns `CASE_SKIPPED`, which `expect_pass`/`expect_fail` map to a `⏭` line instead
of ✅ — so the arm is on the `skipped:` channel and NOT in the outcome tally, and its SIX mutants are
reported as "NOT measured" rather than as `MUTANT SURVIVED` (five of them did report `MUTANT SURVIVED`
before the sentinel; `(g)`'s read "caught" only because `(g)` itself was red there). Measured on this box under
`unshare -r --map-root-user`: **53 passed, 0 failed, 14 skipped, exit 0**, with zero `MUTANT SURVIVED`
lines. Before the sentinel the same run printed `50 passed, 6 failed, 10 skipped, exit 1` — five of those
reds being "MUTANT SURVIVED: the arm is not covered by this case" about arms that WERE covered and merely
could not be built, i.e. a suite blaming its own coverage for a host limitation, on a box that reports
healthy. `passed + the skipped CASE lines` still totals 62; the 14 skips are 5 `(f)` sites + 9 case
invocations — `(l)` four times (real + `l`/`l2`/`l3`), `(r)` three times (real + `r1`/`r2`), and `(g)`
twice (real + its single mutant). The per-case split is STRUCTURAL — it is the number of times each case is
reached from the registration block — so it is derived from that block, not taken from a lucky run.

**The tally names SKIPS separately, because a skip is not a pass.** Case (f)'s default-glob half cannot
run on a box that HAS real runner roots — its whole subject is the default list, so there is nothing to
pin the seam to — and recording it as a passing check meant a CELL (which skips it) printed the same
tally as a laptop on which every arm really ran. The skipped arms are now counted on
their own line with their reason, so the two runs cannot be mistaken for each other. Measured AT THIS HEAD,
on a box told to have real runner roots so the skip path is taken (`<entry>` is the entry point under test;
`mut-f`, `mut-f3`, `mut-f4`, `mut-f5`, `mut-f6` and `mut-u` are mutated copies of the ENTRY POINT made under
the suite's own `$T`, so their skip line names that copy. ⛔ `mut-f5b` is a copy of the **OWNER**, and its
`case_f` run passes `$REAPER` — so its skip names the REAL entry point, which is why `<entry>` appears TWICE
and there is no `mut-f5b/disk-reaper.sh` line; an earlier revision of this block printed one, and no run of
any head can produce it):

```
  69 passed, 0 failed, 8 skipped
    skipped: (f) empty-population half, entry point <entry>/disk-reaper.sh — this box HAS real runner roots (/opt or /tmp), so the empty-population arm was NOT measured; the documented defaults are asserted by REACH instead
    skipped: (f) empty-population half, entry point <suite $T>/mut-f/disk-reaper.sh — …as above…
    skipped: (f) empty-population half, entry point <suite $T>/mut-f3/disk-reaper.sh — …as above…
    skipped: (f) empty-population half, entry point <suite $T>/mut-f4/disk-reaper.sh — …as above…
    skipped: (f) empty-population half, entry point <suite $T>/mut-f5/disk-reaper.sh — …as above…
    skipped: (f) empty-population half, entry point <entry>/disk-reaper.sh — …as above… (the mut-f5b arm: an OWNER mutant, run against the real entry point)
    skipped: (f) empty-population half, entry point <suite $T>/mut-f6/disk-reaper.sh — …as above…
    skipped: (f) empty-population half, entry point <suite $T>/mut-u/disk-reaper.sh — …as above…
```

⛔ Note what the skip means now: the arm skipped is the EMPTY-POPULATION half. **The REACH half runs on
every box** (it expands the shipped default string against a fixture) and is what `MUT_F5` / `MUT_F5B`
redden — so the defaults are no longer "asserted from the source" by a grep that stays green on a list
that names the roots and cannot match them.

**How those two numbers compose — `skipped` is ORTHOGONAL, so the arithmetic must not be "balanced".**
`passed + failed` is the OUTCOME count (69 here: one line per case run and per mutant — 23 case runs, and 43
mutants — plus the 3 top-level assertions on the owner's own source). `skipped` is an
independent count of arms that did not run: `skip()` neither increments nor decrements `PASS` — it records
a reason in a file the outer runner reads at the end — and the arm's own pass line still lands, because the
assertions beside the skip (the REACH arm that expands the shipped default) still run. So
`69 passed … 8 skipped` reads as **69 outcomes, 0 of them failed, PLUS 8 arms that were not measured**, and
`passed + skipped` legitimately EXCEEDS 69. ⛔ **A transcript is therefore never "corrected" on the grounds
that `passed + skipped` exceeds the outcome count.** An earlier revision of this section did exactly that,
on the false premise that a skip must displace a pass, and replaced a correct transcript with
`20 passed, 0 failed, 2 skipped` — a line no head of this suite can print; the same false premise then
re-derived the number here to `24`. What is printed above is measured, not derived.

🚫 **`census=abstained` IS NOT A MISSING MEASUREMENT, AND ITS NOTE MUST NOT INVENT ONE.** `abstained` means NOTHING was reached; `partial` means some of the population was not. Neither can name a cause it does not know: the note once asserted *"a matched `_work` root could not be listed"*, which is FALSE when the unreadable thing is an ENTRY under a perfectly listable root (MEASURED: `roots=1 … census=abstained` from a mode-0000 subtree inside one entry) — and it aimed the operator at root permissions for an entry problem. The note now states the tally and says the count is unknown, and the per-item `reason=` rows carry the cause.
⚠️ **AND A CENSUS TOKEN NEVER OUTRANKS A REAL FAILURE.** `census=partial` co-occurs with `rc=4` (one unreadable entry, one removal that failed), and the override used to replace `removal-failed` with `partial` — the surviving word was the BENIGN one, printed under the ⚠️ symbol. `abstained`/`partial` are now applied only when the class verdict is `ok`, so `removal-failed`, `fail-closed` and `deferred` win.
⚠️ **AND `globs=` COUNTS PATTERNS, not expanded words.** The discovery split used to glob-expand before counting, so a two-pattern list whose wildcard matched two roots reported `globs=3`, and every `root … (glob …)` line printed the expansion instead of the pattern — the one thing that line exists to answer. The pattern list is now split with globbing off and expanded per pattern.

Eight skips, not two: `(f)` is driven from EIGHT places in the suite — the real entry point, and the
`mut-f`/`mut-f3`/`mut-f4`/`mut-f5`/`mut-f5b`/`mut-f6`/`mut-u` mutants, which each reach `case_f` again —
so an arm that skips `(f)` skips it eight times, and "the same two skips" was already stale when it was
written. ⛔ **DERIVE THE COUNT FROM THE RUN, NOT FROM THIS PARAGRAPH** — every `(f)` mutant added adds `(f)`
sites, and this sentence has been wrong at every head that added one (it said three, then five, and a
reviewer had to re-derive the number both times). `grep -cE 'expect_(pass|fail) .* case_f '` is the answer.

⛔ **AND THE SKIP COUNT IS NOT ALWAYS 5 — case (v) has a CONDITIONAL arm that names itself.** Its
positive half ("having observed a nonzero `df` delta, the note offers it as a POSSIBLE own reclaim") can
only be asserted when the pass actually observed a delta, and `df` is shared: a full fixture's worth of
concurrent allocation on the same filesystem cancels it. **Measured**: across one run of the five
case-(v) invocations the arm ran 4 times and vanished once, and the tally then read an unqualified line
whose skip count had quietly DROPPED by one — an arm that did not run, travelling as one that did, which is the
exact defect the skip channel exists to remove. It now calls `skip()` with its reason, and the fixture
is 16 MB (large enough that cancellation is unlikely, small enough to stay cheap), so a healthy run
reports **8** skips and a run whose delta was cancelled reports that many MORE, each with its reason on
the `skipped:` lines. **A tally whose skip count exceeds 8 is therefore not a regression** — read the
reasons before assuming one. The count is a function of the HOST and the TREE, not of the suite's health:
**8** on a normal box with runner roots (`grep -cE 'expect_(pass|fail) .* case_f '` is the authority —
this sentence said three, then five, and was wrong both times), **3** on the pre-change tree (one `(f)` site, plus case (v)'s arm
firing deterministically there), **up to 9 more** on a box that runs as root (the `(g)/(l)/(r)` case skips
above), and one more per case-(v) invocation whose pass observed no delta.

| case | proves | mutant that must turn it red |
|---|---|---|
| (a) | a YOUNG `_work` entry is neither counted nor reaped — in `--dry-run` AND `--apply` — and the entry point's floor is **RELAYED, not hardcoded**: the case drives the seam to **60 s** and requires the 5-minute entry to become a candidate while the 0 s one stays kept — i.e. an operator RAISING the floor on a box whose jobs write outside the checkout must actually get the higher floor, or the class keeps deleting. ⚠️ **An earlier wording here said "every other assertion is satisfied by … a literal 3600 (the default and the literal are the same number)" — FALSE since the shipped default became 7200 s** (measured in review: at 7200 the relay mutant ALSO reddens the shipped-default arms, because a literal 3600 would reap a 90-minute entry). The relay mutant is still a valid mutant; it is simply not the isolation the sentence claimed. ⛔ **AND THE SHIPPED DEFAULT IS ASSERTED, at BOTH layers** — added after a reviewer measured that every other arm passes the floor in, so the default was covered by nothing: a 90-minute entry (sitting BETWEEN 3600 and 7200) must be KEPT with no seam and the line must read `min_age=7200s`, driven once through the entry point and once through the owner directly, because the entry point RELAYS `--min-age` and would hide a halved owner default | the owner's floor reference becomes `now`; separately the entry point's `--min-age "$RUNNER_MIN_AGE"` becomes `--min-age 3600` (the inert-knob shape); and separately each LAYER's shipped default is halved back to 3600 |
| (b) | an OLD entry is counted in dry-run and REMOVED by `--apply`, reported as a `df` delta with a numeric record field; a second pass claims no un-caused delta; and the record carries `verdict_runner_work=ok` **and** `--print-status` RENDERS it (this case is the instrument for the class's record fields) | the `-newer` test is dropped from the walk; and, separately, the `verdict_runner_work=` line is deleted from the pass record |
| (c) | `_work/_tool` and `_work/_actions` survive when they are the OLDEST thing in the tree, in the same pass that reaps a dead sibling | the `retain` ROWS are deleted from `WORK_LAYOUT` **and** the vendor-namespace default disabled (they are one arm, because the prefix default alone would still keep them) |
| (d) | `--only runner-work` runs no other class, and a pass selecting another class does not run this one — whose record then answers `unmeasurable_runner_work=not-run`, the documented polarity for an unselected class, never a number | `want_class runner-work` → `true` |
| (e) | an unknown `--only` value is refused, the valid list names `runner-work`, and a near-miss (`runner`) is refused too | the valid list is shortened in the refusal |
| (f) | an EXPLICIT glob list matching nothing is `misconfigured` + `?` (rc 3), while the DEFAULT globs matching nothing is a measured empty population (rc 0) — and the RECORD answers `?` for both `candidates_runner_work=` and `unmeasurable_runner_work=`, a class that measured nothing claiming no number at all. On a box with REAL runner roots (a cell) the default-glob half is **SKIPPED by name and counted on the `skipped` line — not as an outcome, and never as a pass** (the case itself still passes or fails on the source assertions beside the skip) — the documented default list is then asserted from the source — and `(b)` pins that the record carries the owner's `unmeasurable=` tally. ⛔ **AND THE ARMED HALF, which the dry arm structurally cannot see** (a dry run records `freed_mb_total=not-applicable` by design, so the defect only exists on the `--apply` pass the installed unit runs): a class that could not be set up publishes `not-run`, and the pass TOTAL follows it to `unmeasured` — never a measured `0`, and with **no** `alert=under-reclaim`, because "the pass ran and did not keep up" cannot be asserted about a pass whose only class never ran | the `census=no-roots` arm is deleted; and, separately, the `unmeasurable_runner_work=` `?` polarity answers `not-run`; and, separately, the setup-failure cause removed from the unmeasured list (a class that never ran is added back as a measured 0 and the alert fires again); and, separately, the same rule dropped from the pass-end "measured classes" figure (a pass that measured nothing prints a measured `0MB` and names no cause) |
| (g) | a FULL-DISK FALLBACK pass (configured state dir **and** `$HOME` unwritable) still hands this owner a writable dir, so the class REAPS on the pass it most needs to. ⚠️ **Skipped by name (not passed) when the suite runs as root** — `chmod` cannot deny root, so the unwritable state dir cannot be created and there would be nothing to measure | the `REAP_RW_STATE_DIR` relay line is dropped from the fallback block |
| (h) | a SET-but-EMPTY glob list is a refusal at **both** layers (the entry point's seam and the owner's), never "scan nothing for ever" — `${X:-default}` would substitute the *widest* sweep for an emptied value, and this class's output is deletions | the entry point's empty-glob arm never matches; and, separately, the owner's |
| (i) | the owner's OWN `--glob` flag is an explicit assertion too: an unmatched `--glob` is a REFUSAL (rc 3, `census=no-roots`), never a measured empty population — the same verdict the `REAP_RW_GLOBS` + `REAP_RW_EXPLICIT=1` env spelling gives. This is the case a fail-open `--glob` arm slipped past: the flag named roots the census never read, so an operator's explicit layout matched nothing and the pass reported a measured zero | the `--glob` arm's own `EXPLICIT=1` line becomes `:` |
| (j) | **a LIVE job's `_temp` is never a candidate**: `_work/_temp` — the vendor's `Combine(Work, "_temp")`, written once per step, so it goes stale while the checkout beside it stays fresh — SURVIVES a stale floor and is named (`reason=live-job-temp`); a vendor directory the table has never seen also survives and is named (`reason=vendor-namespace-unlisted`); and a genuinely dead checkout in the SAME pass is still reaped. This is the shipped defect the reviewer measured — a `REAP` row for `_work/_temp`, with the checkout gate working perfectly, which the disclosed residual does not cover | the `_temp` row is deleted (the prefix default still keeps the directory, so the case pins the ROW by its reason); and, separately, the vendor-namespace default is disabled |
| (k) | **a `reap` ROW is honoured — the table's OTHER disposition is not inert**: a `_foo|reap|…` row is injected into a copy of the owner, and `_work/_foo` is REAPED (a `REAP`/`REAPED` row names it), while the four `retain` rows still hold at the same age with their own reason strings, an UNDECIDED dead checkout beside them is reaped in the same pass, and the pass record names the decided row (`reaped-by-table=_foo`). Measured before the fix: `_foo` came back `RETAINED … reason=vendor-namespace-unlisted` — "no WORK_LAYOUT row" about a name whose row was in the table — while its `job-dead` control was reaped, i.e. the disposition the script and this doc tell an operator to write was inert AND the log named the wrong cause | the table lookup is filtered to `retain` (the shipped bug: a `reap` row then matches nothing and falls through to the `_`-prefix default) |
| (l) | **a root that cannot be LISTED is an abstention, never a measured zero.** `_work` is set to mode 0111 (stat-able and traversable, NOT listable) with a dead entry under it; the glob then expands to itself and reaches no entry. The pass must count `roots=1 candidates=0 unmeasurable=1`, EXIT 0 (an abstention is not a failure), NAME the root (`reason=unlistable`), carry it into the record as `unmeasurable_runner_work=1`, and — because nothing was classified — the dead entry must SURVIVE. ⛔ **AND THE ZERO MUST NOT LAND AS A MEASUREMENT**, which is what a reviewer found at this head: the owner now publishes `census=abstained`, the record answers `candidates_runner_work=?` and `verdict_runner_work=abstained`, and the class line carries the same `?` — before this, the same fixture recorded `candidates_runner_work=0 verdict_runner_work=ok` and an INERT class read healthy. ⚠️ Skipped by name (not passed) when the suite runs **as root**, because `chmod` cannot deny root and the condition cannot be made | the `[ "$_seen" = 0 ] && ! root_is_listable "$root"` guard is deleted, restoring the measured-zero reading; separately the owner's `census=abstained` arm is removed (the false PASS returns); and separately the entry point's `VERDICT_RW=abstained` override is removed (an abstention reports `ok` again) |
| (m) | **an OUT-OF-RANGE floor is REFUSED, and a leading-zero floor is NORMALISED** — the floor is the only gate on a `rm -rf`, so its refusal path is load-bearing: `--min-age 18446744073709551616` (2^64) is all-digits, `now − 2^64` WRAPS to `now` in bash's 64-bit arithmetic, the floor ref lands at NOW and every entry is older than it — **measured: a 5-minute-old entry `REAPED` under a floor set to "keep everything"**, the log asserting a flat falsehood about its age; and `--min-age 08` passed the digit check, then `$(( ))` died on the octal spelling, the floor became unusable, and the pass still exited **0** with `census=ok` calling every entry `reason=unreadable` — a bad knob reported as a filesystem problem. The case drives the **OWNER directly**, because the entry point already bounds its own seam and exits 3; the owner's `--min-age` / `REAP_RW_MIN_AGE` was bounded by nothing. Asserts rc 2, the cause named, the entry SURVIVED, no `census=ok`, and that `08` normalises to `min_age=8s` rather than aborting | the magnitude bound `[ "${#_rw_floor_norm}" -gt 9 ]` is disabled, restoring the wrap that deletes |
| (n) | **a CUT-SHORT sweep publishes no PARTIAL candidate count.** The owner prints its `SUMMARY` unconditionally on every path that reaches the end of a pass, and it deliberately refuses to truncate a `--dry-run` ("a partial count presented as a total, which is the false-measurement shape this class's own `census=` refusal exists to prevent"); the ENTRY POINT then bounds the delegate with `CLASS_TIMEOUT`, so the rows a cut-short dry pass printed first ARE a partial count. Driven with a STUB owner that emits two `REAP` rows and no ledger — the observable shape of that cut, not a race against a real `timeout`, which flakes under load on exactly the box this class exists for. Asserts the record answers `candidates_runner_work=?` and NEVER a number, that the class line carries the same `?`, and that the rows it did scan are still NAMED as `WOULD-REMOVE`, so nothing an operator needs is lost | the `&& [ -n "$_rw_line" ]` guard on the dry-run row-count fallback is dropped, restoring the shipped fallback that turns partial rows into a total |
| (o) | **THE LAST GATE BEFORE `rm -rf` IS THE ROOT'S NAME, and it was missing.** The root loop tested only `-d` and `! -L`, so a seam ONE COMPONENT SHORT (`/opt/gh-runner*/` instead of `/opt/gh-runner*/_work`) matched the runner INSTALL tree itself and swept `bin/`, `config/`, `externals/` — **measured: `REAPED …/gh-runner-x//bin`** — and the floor offers NO protection there, because an install tree is ALWAYS older than any floor, so the very mtime test that is this class's proof of death is what makes the install look dead. One character in a rendered unit would have destroyed the CI hosts. A matched root whose BASENAME is not `_work` is now REFUSED BY NAME and the pass exits 3 (a wrong layout assertion is loud, not a healthy population over the roots it did find); the fixture carries a real `bin/Runner.Listener` + `config/` tree aged 600 min, asserts both SURVIVE, and the control re-runs the SAME box with the correct seam to prove the refusal is about the name and not about sweeping nothing | the basename `case` label is pinned to `_work`, so the refusal arm can never fire — and the mutant then REAPS the install tree (`reaped=2` of `bin`/`config`), which is the deletion this guard exists to stop. ⛔ **AND THE RECORD MUST NAME THE REFUSAL, NOT A GLOB THAT MATCHED NOTHING** (added after the same review): the census used to fall through to `no-roots` when nothing was swept, so the record read *"no runner `_work` root matched DISK_REAPER_RUNNER_GLOBS"* about a glob that had matched 2 install trees — a false cause whose implied remedy (widen the glob) is the opposite of the correct one. The owner now publishes `census=refused` and the entry point its own `runner-work-root-refused` misconfiguration token; the case asserts the cause and the ABSENCE of the nothing-matched sentence. ⛔ **AND IT DRIVES THE MIXED SEAM** (one good `_work` root + the install tree in the same list), because that is the shape in which sweeping-as-it-discovered DELETED a checkout and then reported *"nothing was swept"* with `freed_mb_runner_work=not-run`: the pass is two-phase now, so the mixed seam refuses for the whole pass and the dead checkout under the good root SURVIVES, which is the assertion that catches a regression to per-root sweeping | … and, separately, the refused-census token is dropped (the summary says `no-roots`), so the record blames a glob that matched |
| (p) | **a root matched by TWO globs is swept ONCE.** `--glob` is repeatable, so a wildcard and a literal naming the same root is a normal operator spelling, and there was no root dedupe (`rw_df_targets` dedupes filesystems; this loop deduped nothing): measured `roots=2 candidates=2` for ONE entry with the same WOULD-REMOVE path logged twice — a population reported at twice its size and a to-free figure doubled by a spelling. A seen-set (a string, because bash 3.2 has no associative arrays) now dedupes roots and NAMES the skip, so a dedupe cannot be mistaken for a root that never matched | the `case " $SEEN_ROOTS "` guard is replaced by one that never matches, so the same root is swept once per glob and both counts double |
| (r) | **a PARTLY-unreadable population is `census=partial`, with a LOWER-BOUND count — never `verdict=ok`.** Two roots, both holding a dead checkout; one set to mode 0111 (stat-able, not listable). Measured before the fix: `roots=2 candidates=1 unmeasurable=1 census=ok` ⇒ record `{candidates=1, unmeasurable=1, verdict=ok}`, i.e. one runner's whole `_work` sink unmeasured while the only field an operator reads said healthy — the abstention implemented only for the `candidates=0` case. Now the owner publishes `census=partial`, the record keeps the MEASURED count (`candidates_runner_work=1`, a lower bound) plus `unmeasurable_runner_work=1`, the verdict is `partial`, and the note says LOWER BOUND in as many words. The case also pins the DELETER's two halves: the readable root's dead checkout IS reaped (a partial census must not make the class inert) and the unreadable root's SURVIVES (nothing was classified there). ⛔ **AND IT PINS THE ORDINARY HEALTHY SHAPE, which the first version of this fix got wrong:** the same two roots with a FRESH checkout under the readable one (`kept=1 unmeasurable=1`) published `census=abstained`, whose note asserts *"no entry was classified"* about an entry that WAS classified — and a non-`ok` verdict on a cell that was fine. The gate is REACHED-ness (any entry classified ⇒ `partial`, `candidates` a lower bound that may be `0`; nothing classified ⇒ `abstained`), and the case drives both. ⚠️ Skipped by name (not passed) when the suite runs **as root**, because `chmod` cannot deny root | `else CENSUS=partial` is replaced by `else CENSUS=ok`, so a partly-read population is published as measured again; and, separately, the entry point's `VERDICT_RW=partial` override is removed, so the token lands as `ok` |
| (s) | **an entry that VANISHES mid-pass is `GONE`, not `unmeasurable=`.** `find` on a path a runner deleted exits non-zero exactly like a permission failure, so a job finishing during the sweep (the runner removes its own `_work/<entry>`) was counted into `unmeasurable=` — and, with the census keyed on reached-ness, that alone is enough to publish a non-`ok` verdict on a pass that measured everything else. The two facts have different consequences (one says "I could not prove this checkout dead", the other says "there is nothing to prove"), so the walk re-stats before claiming an abstention and names `GONE … reason=vanished`, counted in its own `gone=` field and in NO other bucket. Driven by a copy of the REAL owner with the delete injected at the classification site — a race fixture, not a stub of the logic under test — which asserts the entry was already gone at classification (nothing reaped), `gone=1 unmeasurable=0 census=ok`, and `verdict_runner_work=ok`; the ROOT-level walk got the same distinction (`GONE … reason=vanished` instead of `reason=unlistable`), because the two-phase pass widens the discovery→sweep window. ⛔ **AND THE THIRD SITE — the REMOVAL window — was the unguarded one**: `rm -rf` exits 0 for a path that no longer exists (measured), so a checkout the runner cleaned up between the re-probe and the `rm` was counted and logged as THIS class's removal — `reaped=` up (which is also the gate the entry point uses to unlock `df` attribution, so the pass claimed BYTES for a deletion never performed) and a REAPED row asserting "no content written for >= N s" about an entry that simply vanished. Existence is now decided BEFORE the delete (with `-L`, since a dangling symlink is not `-e`), and (s) drives that site too, with its own instrumented owner | reverting the re-stat to `return 2` turns the case RED — a gone entry becomes an abstention again. The removal-window arm has its own mutant: disabling the pre-`rm` existence check (`if …` → `if false`) lets the fall-through `rm -rf && [ ! -e ]` credit the vanished entry as REAPED, which turns the same case RED |
| (t) | **a ROOT that VANISHES between discovery and sweep is `GONE`, not `unmeasurable=` — and this arm was covered by NOTHING.** (s) fixed the ENTRY site and the root walk got the same re-stat in the same commit, but the case drove only the entry, so a revert of the root branch to `reason=unlistable` kept every outcome green: an arm asserted only by prose, in the doc that requires a case to say when it has stopped checking something. It matters MORE at root level because the pass is TWO-PHASE, which widens the window — a runner teardown or a re-image between the phases left the pass claiming it could not LOOK at a root that is simply not there. Driven by an instrumented copy of the real owner that removes the queued root just before the sweep, so the REAL `root_is_listable` + re-stat run against a missing path; asserts `gone=1 unmeasurable=0 census=ok`, `verdict_runner_work=ok`, nothing reaped, and rc 0 | reverting the re-stat (`if [ ! -e "$root" ]` → `if false`) turns the case RED — a gone root becomes an abstention again |
| (w) | **a ROOT REPLACED between discovery and the sweep is NOT followed** (#3057 review, P2). The pass is two-phase on purpose, so discovery's `-d`/`! -L` assertions are already stale when the sweep runs: an operator freeing a full runner disk moves `_work` aside and leaves a symlink behind, and `"$root"/*/` then expands THROUGH it — the sweep would classify, and `rm -rf`, a tree OUTSIDE the population it was told to sweep. Driven by an INSTRUMENTED owner that performs the swap exactly at the phase boundary (the race itself cannot be asserted, so the swap is the input), and asserts the whole answer: the root really is a symlink at sweep time, it is NAMED `reason=root-changed-since-discovery`, it counts as `unmeasurable=1` and NOT as `gone=`, nothing under it is REAPED, the tree the link points at is UNTOUCHED, and the pass exits 0 (an abstention is not a failure of the pass). ⛔ A **vanished** root stays a DIFFERENT state — `reason=vanished`, its own `gone=` field — a fact about the box rather than a doubt about it (case (t)) | reverting the sweep-time re-assertion turns the case RED: the sweep follows the link out of the population and reaps the target |
| (v) | **the two tallies the record used to DROP — `reaped=` and `gone=` — on a DELETER** (#3057 review, P1 + P2). Four arms. **(v1)** a stub owner really deletes an entry and exits `124` (the watchdog-kill shape: no `SUMMARY`), so the record must answer `reaped_runner_work=?` — a DELETE the owner never answered is not a measured `0` — the note must NAME the cut, it must NOT assert that the class removed nothing while blaming "another process" for the `df` change it caused, and when a nonzero `df_raw` WAS observed the note must offer the delta as a POSSIBLE OWN reclaim. The fixture's own size is asserted (≥ 3 MB) first, because that is what caught `dd bs=1m` — a BSD-only spelling GNU dd rejects, which the old `|| true` swallowed, so on every Linux box a "24 MB" fixture was 12 KB and every `df`-delta assertion in this suite was vacuous while printing ✅. **(v2)** a `SUMMARY` with `gone=2 census=ok` must reach the record as `gone_runner_work=2` and be NAMED, while `candidates_runner_work=0 verdict_runner_work=ok` read exactly as an EMPTY sink does — that is the hole: the population vanished under the pass and the record was byte-identical to a `_work` with nothing in it. **(v3)** a fully-answered pass records `gone_runner_work=0` and `reaped_runner_work=0`, so both are MEASUREMENTS there and not a permanent `?`. **(v4)** the BUSY case — `reaped=3` with `gone=1`, i.e. one job finishes while other dead checkouts are reaped — must record BOTH, and its note must never say "nothing was removed", which would contradict the class's own count. `--print-status` is asserted to render both fields (a field with no reader does not exist) | ungating the `HAVE_RW_REAPED` test (the sentence is emitted again for an unanswered ledger) turns it RED; dropping the `gone=` lift turns it RED (a vanished population reads as an empty sink); deleting the `reaped_runner_work=` record line turns it RED (the removal count has no channel); restoring "nothing was removed" in the gone note turns it RED (it contradicts `reaped_runner_work=3`) |
| (q) | **a SET-but-EMPTY `REAP_RW_EXPLICIT=` is a REFUSAL.** `${REAP_RW_EXPLICIT-0}` is right to keep UNSET distinct from SET — but a set-and-EMPTY value yields `""`, which is neither `1` nor `0`, so every `[ "$EXPLICIT" = 1 ]` read FALSE and an explicitly-asserted layout that matched nothing reported a MEASURED EMPTY POPULATION (`census=ok`, rc 0) instead of `census=no-roots` (rc 3) — the third spelling of the fail-open case (i) fixed, reopened through an emptied seam. A template that renders `REAP_RW_EXPLICIT=` must not disarm the assertion it carries. Asserts rc 3, the seam named, no census published, and the `EXPLICIT=1` control reaching the documented `no-roots` route | the `case "$EXPLICIT"` scrutinee is pinned to `0`, so the `0|1` arm is taken for every value and the emptied assertion is silently read as "not explicit" |

The pre-existing suite (`disk-reaper.test.sh`) additionally scopes both owners' scratch roots to its
own fixture: without that, a `--apply` assertion anywhere in it would sweep the machine's real `/tmp`
(it did once, on this box, before the scoping was added).
`scripts/disk-reaper.test.sh` — 720 assertions, run by the `disk-reaper` shard of
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
| T46 | an unwritable state dir with **no fallback** is a REFUSAL (3, RED), never "another pass holds the lock" (6) and never a benign skip (#2443) |
| T47 | a class that could not be **set up** records `verdict=misconfigured` + `freed_mb=not-run`, never a measured 0 |
| T48 | a non-numeric `DISK_REAPER_WT_AGED_DAYS` is refused on the **Darwin** install path too |
| T49 | the pass leaves **no probe scratch** behind — neither on a completed pass nor on a startup refusal |
| T50 | the installer REFUSES a system unit rendered from transient scratch space (the cells' hourly `127`), still installs through the explicit test override, the installed `SuccessExitStatus` is exactly `{0, 6}` (3, 4 and 5 are each asserted absent, with a positive control), and the three `Environment=…_REAPER=` delegate pins are present and absolute |
| T51 | the USER install target — reachable only when the sudo probe fails, and it used to route its file copy through sudo (so it could never install): the files land in `~/.config/systemd/user` with no sudo, every `systemctl` call keeps `--user`, an unconfirmed `Linger` refuses with the exact remedy, and `--uninstall` really removes them |
| T52 | the **venv class alone** clears a GONE lane's `.venv` and never a LIVE one's: one fixture, two worktrees, both envs aged, `--min-age 0`, so the only difference is a real cwd holder (#2159) |
| T53 | a delegate's exit code is neither swallowed nor mis-coloured, **per class**: a delegate's `3` is RED (never 6); uv `7` and uv `4` are deferrals (pass 6, `ok=0`, `verdict_uv=deferred`, detail naming the delegate's own code); venv `4` is a RED removal failure, never a deferral; `5` is RED in apply and informative in dry-run; `2` is red; a fail-closed class outranks a removal failure across two repos in **both** `--repo` orders, with both codes named in `detail=`; a uv deferral cannot mask a venv removal failure across classes; and the `7` row is asserted on BOTH sides — uv `7` defers, a venv delegate's out-of-vocabulary `7` is RED (#2156, #2036) |
| T54 | the stale threshold and the help text: a non-numeric `DISK_REAPER_STALE_SECONDS` is refused on read (never a green `status=ok`), and `--help` still reaches the end of the header — it carries the DEFERRED exit-code bullet and the watchdog pin, so the derived range is what is printing |
| T58 | the INSTALLED ARTIFACT is read back before `enable --now`: a clean install says it read `ExecStart` + `HOME` out of the artifact; a `50-mask.conf` drop-in that REPLACES `ExecStart` makes the install refuse (naming the drop-in files that exist) and nothing is armed; removing it restores a clean install; an ADDED `ExecStart` (a pre-flight) is accepted and still verified; a drop-in that moves `Environment=HOME` is refused and names both HOMEs; and a `gh` that does not resolve is reported. It also pins the **wrapper preference** (`disk-reaper-run.sh` beside the reaper) on a deliberately UNPINNED install — nothing else measures it, and a timer-started raw reaper inherits no HOME/keys/`gh`, fails the open-PR gate closed and reclaims nothing (#2354) |
| T58b | the plist **textual** fallback (no usable parser) still refuses a stale arming decision: a good artifact passes and the message names `EnvironmentVariables.HOME` as NOT verified; a stale one (no `--apply`) is refused, naming the missing flag |
| T55 | **a full disk does not stop the pass** (#2443): an uncreatable state dir falls back to a tmpfs candidate — the classes RUN, the record is written with `state_dir=`/`state_dir_primary=` and says why, and the pass discloses it; the fallback lock is a REAL lock (a live holder still defers, 6); nothing writable anywhere is still a refusal naming every candidate; a writable configured dir produces the unchanged record; and the record returns to the configured path on the next pass once it can be written |
| T62 | the **installer** refuses to render a unit that scans nothing: an all-empty resolved list is refused (rc=1, no unit written) and an entry dropped from a PARTIALLY resolvable list is NAMED on **stderr** — quoting git's own first line, measured on its own stream — while the entries it CAN use still install. It also pins the absolute-path arm hoisted above the git probe (a relative / `git@host:owner/repo.git` candidate is dropped for the reason that applies, not blamed on a missing checkout) and the `<git gave no message>` fallback (#2159/#2878) |
| T63 | the **hourly pass** applies the same rule in its own `resolve_repos`: git's own error line reaches the operator (`git cannot use it here (fatal: cannot change to …)`) instead of the blanket `not a git checkout`, a silent non-zero git renders `<git gave no message>`, and a probe killed by the BOUND (rc=124, a dead or hung mount) is named as a timeout rather than as a git that said nothing (#2159) |
| T64 | **lane evidence** (`scripts/pi-reap-worktrees.test.sh` G2g–G2y, **G2j/G2k**): a LANDED checkout whose only ignored entries are the fleet-mandated ones is `reclaimable`, and an armed pass removes it while the unlanded (open-PR) and dirty-but-landed siblings in the SAME fixture are refused; the archive is verified **by content** (the lane's own report text round-trips out of the tarball), the `manifest` names path/HEAD/reason, **a second pass removes nothing and writes no second archive**, a dry run archives nothing, and TWO mutants must go RED while controls on the same fixtures stay green — the evidence predicate neutered (G2x) and the pointer predicate back to its shipped early-return form, which would admit a real `scripts/` DIRECTORY and an unrelated ignored symlink (G2y) (#1932 over-preservation, the 70-row/20.5 GB class). **G2j drives the capture KEY**, which no fixture could see before: two DETACHED checkouts at ONE commit (`br="-"` for both) must produce TWO captures in DIFFERENT directories, and the first lane's report must still round-trip out of its own tarball — under a branch-derived key both land in `<day>/-.<sha8>` and the second capture destroys the first. **G2k** proves an existing capture is never reused: a re-dispatch onto the same path/branch/head takes a unique sibling and the earlier tarball's bytes are unchanged (the old `rm -f "$tarf"` overwrote them) |
| T65 | **deployed-vs-source** (`scripts/disk-reaper-deployed-check.test.sh` D1–D13): a fresh stamp verifies (control), one changed byte is `DRIFT` (1) and is NAMED, a pinned file that is MISSING is drift, a file farmed after the stamp is `APPEARED` (unmeasured, exit 1) and re-stamping clears it, a file stamped MISSING and still absent is drift (a stamp over an incomplete set can never verify), a pinned file absent from the record is `UNRECORDED` (the set is reconciled, not trusted), deployed-vs-checkout disagreement is `SOURCE-DRIFT` (the measured 153-commit shape), a digest that could not be taken is recorded `unmeasured` and is DRIFT (the stamp itself exits 1), a record line whose digest FIELD is blank (truncated or hand-edited record) is DRIFT even when the deployed file is absent, and header lines are not misread as malformed file lines, the two-delegate library `lib/live-paths.sh` is in the pinned set (a stale copy is `SOURCE-DRIFT`), the abandoned-worktree arm's library `lib/cell-home.sh` is in the pinned set too (agent-infra#3453 — outside it, the class died on every pass while the check said `deployed ok`), an unreadable record is 2 (permissions) and **no record / an empty record is `UNSTAMPED` (3), never 0** |
| T66 | **the archive cannot make the class inert** (`scripts/pi-reap-worktrees.test.sh` G2z): with NO writable archive root the checkout is KEPT, the log names the cause, the row is NOT recorded as a benign late preserve, and the pass exits **4 (red)**; with a writable `REAP_WT_PRESERVE_FALLBACKS` candidate the same unwritable configured root still reclaims, the archive lands in the fallback, and the pass DISCLOSES `PRESERVE-DIR-FALLBACK`; and a mutant that inverts the capture result leaves the checkout in place, which is what makes the removal assertions load-bearing |
| T67 | **the archive is bounded, in every root it can land in** (`scripts/pi-reap-worktrees.test.sh` G2aa): a dated dir older than `KEEP_DAYS` is pruned, a recent one survives, `notadate` / `2020-01-0` / `2026-11-03-nodash` all survive (only an exact `YYYY-MM-DD` is a candidate), the dry run reports without removing, `0` keeps everything, an unusable value is REFUSED by seam validation (exit 2) with nothing pruned, and the FALLBACK root is pruned too |
| T70 | **lane evidence created or changed DURING the archive** (`scripts/pi-reap-worktrees.test.sh` A21f–A21o): `clean_gate` tolerates `IGNORED_LANE_EVIDENCE` because the archive is about to capture it — a precondition spent once the archive has run — so after the archive the tolerated NAME set is compared with the manifest's captured set, and a CONTENT signature is compared with the one taken before the archive: a `cksum` of a sorted `<crc> <size> <path>` stream, produced by the same function on both sides (GNU `tar -t` quotes member names, `find` prints raw bytes, so a cross-tool name comparison differs forever on such a file). A new file at the root, a file created INSIDE a tolerated dir, and an append/rewrite of a file already captured are all PRESERVEs (`REMOVED=0`, the data survives). The digest is STREAMED (no size cap ⇒ nothing is permanently unreclaimable, and no `head`/SIGPIPE red), a walk that fails is a FAILED removal (exit 4, RED), a probe that cannot answer is RED rather than "no evidence", and a symlinked root is compared AS A LINK — never followed, so a dangling link is not a permanent red and an out-of-checkout target is not counted against the checkout. Mutants remove each comparison and lose the file. Round 12 closed the ways a comparison can *not run* while sounding like it did: the link probe and `readlink` are BOUNDED like every other stat on this path (a hung mount must not wedge the pass — the oneshot unit has no timeout), a `readlink` that fails is a walk failure (RED) rather than a `link r -> ` line that compares equal to itself; a `find` listing whose `cat` could not deliver is a walk failure, not an empty tree; `lane_evidence_present`'s "could not answer" reaches ALL THREE call sites (the archive one used to hand the `!unreadable` sentinel to `tar` as a member name — fail-closed, but red for the wrong reason); inner symlinks inside a tolerated root are compared by their TARGET (`tar` stores them as links, `cksum` would follow them); and the waived-precondition note is normalised against the manifest's own `<none>` encoding so it fires only when a root really vanished. A21k's symlink arm is a flipping fixture — the out-of-checkout target is appended to during the archive, so a following implementation PRESERVEs and the test goes red (verified against that exact mutant)  Round 13 pinned the last three ways a comparison can under-report: an inner link's `readlink` failing now REDs the pass instead of emitting `link <path> -> ` (which compares equal to itself forever) — that arm is pinned at SOURCE, by a DEDICATED A21o arm that matches the inner guard itself (not by A21o's count of the three `*) exit 3 ;;` catch-alls: the guard is a `||` on a command substitution inside the `find -exec sh -c` string, so deleting it leaves that count at three — measured), and is NOT exercised by a fixture (a `sh` shim on PATH would also intercept the reaper's own predicates and destabilise the harness — measured on the sibling arm, run_reaper rc 127 with an empty log); separately, **A21n proves the link TARGET is carried** into the signature by RETARGETING a ROOT-level link between the two signatures, which a target-less `link <path>` line cannot see; the per-root probe dispatch captures 124/125 (timed out / no scratch file) instead of reading them as "absent" and dropping the root from the digest with rc 0; and the waived-precondition note is pinned by A21m, a checkout with NO tolerated evidence, so the normalisation cannot be reverted silently. Both new fixtures fail under their mutants (verified: the normalisation removed ⇒ A21m red, the target dropped from the link line ⇒ A21n red).  Round 14 closed the last hole in that invariant: whitelisting 124|125 was not enough, because `lib/bounded.sh` can also surface 137 (watchdog SIGKILL with no sentinel), 126/127, or a killed child — all of which read as "absent" and dropped the root from the digest at rc 0, i.e. an INERT comparison that compares equal to itself forever (measured: two trees, one appended to, both digesting to `4294967295 0`), and on the presence side a skipped archive. Every probe arm now ends in a catch-all (`*) exit 3`), and the presence probe means exactly 1 by "absent". A21o pins both at the source — the three catch-alls, the absence of a `124|125` whitelist, the presence probe's `!= 1` rule, AND the inner-link `readlink` guard by its own needle — a functional fixture would need a `sh` shim that also intercepts the reaper's own predicates and destabilises the harness (measured: run_reaper rc 127 with an empty log) |
| T71 | **a truncated record still measures its last line** (`scripts/disk-reaper-deployed-check.test.sh` D14): `read` does not run its body for a final line without a trailing newline, while the reconciliation read it — so the last pinned file could be deleted and the summary still read ok; the loop tail (`|| [ -n ... ]`) closes it. D13 also PROVES each record rewrite applied before asserting, so no arm can pass for the wrong reason, and uses no `sed -i` (GNU-only; the repo's portability gate reds it) |
| T68 | **the post-archive re-check** (`scripts/pi-reap-worktrees.test.sh` A21e): gate (b) spends four bounded forks between re-check #2 and the fork, so a `clean` verdict captured before it does not prove the checkout is clean now — a file that appears DURING the archive is a PRESERVE (`LATE_PRESERVE=1`, `REMOVED=0`, the ignored file survives, the log names the POST-ARCHIVE re-check), a MUTANT with the block deleted REMOVES the checkout and takes the file with it, and the SOURCE ORDER is asserted (post-archive gate line < `holder_recheck` line < the `git worktree remove` line), so `holder_recheck` staying last is a pinned fact rather than a comment. The post-archive gate is also the **LAST cleanliness read by placement**: it runs AFTER the lane-evidence ladder, because that ladder is up to nine bounded probes (manifest read, one presence probe per tolerated root, then a link + a directory + a walk probe per root) at `REAP_WT_REMOVE_TIMEOUT` = 120 s each — up to ~18 min during which a lane's build can write a `.env`, and a verdict taken BEFORE it would be a per-pass `clean` the window could falsify. `holder_recheck` is a LIVENESS probe and cannot see such a file, so it cannot close the window on its own |
| T69 | **the harness catches its own undefined helpers** (both suites): an explicit vocabulary check plus a `command_not_found_handle` detector that records to a FILE (bash runs the hook in a subshell, so a counter is lost) and turns each unresolved command into a real FAILURE — never a silent skip (the round-3/round-4 false-PASS shape). In BOTH suites an unusable record FAILS the run rather than degrading to "0 undefined", and a single chained EXIT trap removes the record — and, in the checker suite, every per-fixture temp dir it created (measured 1052 leaked dirs and one leaked record per run before it; `trap` REPLACES rather than chains, which is how the leak survived one round) |

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

## The dispatch headroom budget — one lane's tree, measured (#2721)

The reaper answers *"what can be reclaimed?"*. It cannot answer *"does the checkout this spawn is
about to provision fit?"* — and on 2026-10-24 cell-4 (8 vCPU) reached **~2,286 MB free** carrying
**59** `/tmp/cell-wt-*` checkouts at 5-6 GB `du` each, went unreachable for ~40 minutes (`cmux cloud
exec` timed out on `date` and `df`), and was recovered by a human `pause`/`resume`. Every one of those
spawns passed `DISK_MIN_FREE_MB=500`, because a floor answers "is the filesystem full?" and 2,286 MB
is 4.5x that floor. `spawn-gate.sh`'s `run_agent` now also applies a **headroom** gate:

```
ADMIT  iff  free_mb >= max(tree_mb, self_mb) + reserve_mb      (fresh `df` reading, at every spawn)
REFUSE with  `[disk-gate] REFUSED <label>: DISK-NOHEADROOM REFUSED-DISK(free=…, need=…, box=…) — …`
        (AGENT_DISK_REFUSED, 77)
```

⛔ **GREP THE TOKEN, NOT THE DASH.** Since agent-infra#3395 the verdict also carries the
machine-readable `REFUSED-DISK(free=…, need=…, box=…)` term (the same token the PRE-START seam emits
from `wt_provision` before a worktree is created, e.g.
`[disk-admit] REFUSED-DISK(free=3.5GB, need=8.0GB, box=cell-3; free_mb=3584, need_mb=8144)`), so the
line no longer reads `DISK-NOHEADROOM — `. Anchor a grep on the shared **`REFUSED-`** prefix (or on
**`DISK-NOHEADROOM`** for the live arm and **`REFUSED-DISK(`** for a refusal that MEASURED the volume),
not on the em dash that used to follow the verdict.

⛔ **`REFUSED-DISK` IS NOT THE ONLY PRE-START VERDICT, SO GREPPING FOR IT ALONE HIDES THREE REFUSALS.**
The `wt_provision` seam fails **CLOSED** on the three conditions that produced no measurement at all —
an unreadable `df`, a `$O` missing `spawn-gate.sh` (version skew, #2033), and a `disk_admit` that
refused without naming its numbers — and each of them refuses with **`REFUSED-UNKNOWN`**, never
`REFUSED-DISK`:

```
[disk-admit] REFUSED-UNKNOWN <label>: free=? need=… box=… target=…   (spawn-gate.sh)
REFUSED-UNKNOWN disk-admit(free=?, need=?, box=…)                   (wt-lifecycle.sh, no spawn-gate.sh)
REFUSED-UNKNOWN(free=?, need=?, box=…)                              (wt-lifecycle.sh, un-named refusal)
```

A monitor or a runbook anchored on `REFUSED-DISK(` alone therefore sees **no line at all** for exactly
the refusals that mean "this box cannot verify its headroom" — the refusal exists, nothing names its
cause, and the cell reads dark. Anchor on `REFUSED-` (the prefix all of them share) and read the token
after it to tell "the volume is full" (`REFUSED-DISK`) from "the probe could not answer"
(`REFUSED-UNKNOWN`): the two have OPPOSITE remedies, and pruning a filesystem that was never measured
cannot help.

`tree` is what ONE more lane costs *while the shared uv cache holds*; `self` is what the same lane
costs when it does not (a pruned cache, `--link-mode=copy`, a cache on another mount); `reserve` is the
headroom that must still be free **after** that worst case — **4x the dispatch floor**, which is the
number the cell's warning band defaults to, derived independently: the reserve is an *enforcement* bound
and the band is a *reporting* threshold, so an operator lowering the band to quiet the logs cannot be
lowering admission with it. `max(tree, self)` is not a redundancy: a
gate that admitted on `tree + reserve` alone (2,350 MB with the shipped numbers) admits a lane that then
writes 5,772 MB and drives the cell ~3,400 MB SHORT of zero — the cell-4 wedge, reached from a rule that
looked one term cheaper. `tree` and `self` are **measured per target**,
never one global constant (`reserve` is 4x the dispatch
floor, which is enforcement, not a per-target measurement): #1852 recorded that a single constant cannot serve an agent-infra lane
(48 MB, no install) and a tortoise lane (5.7 GB of python), and a tortoise-sized floor would refuse
every harness spawn on every cell — a false *block*, which is its own defect. The band is
evaluated **before** the headroom refusal (a warning that can never fire is not an instrument), and an
admitted spawn cannot drop the cell below 4x the dispatch floor.

### Measured (2026-10-24, 8-vCPU cell, `/dev/root` 128,828 MB, `uv` 0.12.5, warm uv cache)

`df -Pm /` **used**-column deltas, two readings before and after, nothing else provisioning:

| repo | `git worktree add` | install step | **marginal / lane** | **self-contained tree** |
|---|---|---|---|---|
| `tortoise` | **147 MB** | `uv sync --extra embeddings --extra parity` = **169 MB** (2 s, warm cache) | **316 MB** | **5,772 MB** (`du` 5,625 MB venv + 147 MB checkout) |
| `agent-infra` | **48 MB** | none (no `pyproject`/`uv.lock`, zero npm deps) | **48 MB** | 48 MB |

The venv's `du` is ~18x its real cost because **28,730 of its files are hardlinked into the shared
cache** (`nlink=3` measured on every `site-packages/*.so`): those blocks belong to
`~/.cache/uv`, and deleting one venv releases ~124 MB, not 5,625 MB. That sharing is a property of the
*cache state*, not of the lane — `pi-cache-reap.sh` prunes the cache under pressure, `--link-mode=copy`
and a cache on another mount never share at all — so the gate ships both numbers:

| target | `DISK_LANE_TREE_MB` | `DISK_LANE_SELF_MB` | `DISK_LANE_RESERVE_MB` |
|---|---|---|---|
| python project (any of nine package-manager markers — `uv.lock`, `pyproject.toml`, `requirements.txt`, `poetry.lock`, `pdm.lock`, `Pipfile`, `setup.py`, … — at the top level **or one level down**) | **350** | **6144** (6 GiB = the 5,772 MB self-contained tree, rounded up) | **2000** (4x the floor; admit iff free >= 8144) |
| no install step (harness lane) | **64** | **64** | **2000** (admit iff free >= 2064) |

The gate's ledger records `tree` (field 6), `reserve` (7) and `self` (8) per spawn. ⛔ `self` is
appended **last** on purpose: field 7 already means *reserve* in the series already shipped, and moving
the worst case into it would silently re-label every historical row — a `64 1024` harness row would read
as "this lane costs 1024 MB without sharing", 16x its real cost, i.e. exactly the figure a per-cell
budget is calibrated from.

**Which path is measured.** The triple is derived from the lane's **checkout** — `DISK_GATE_PATH` when
that path is one, otherwise the caller's cwd — and never from the mount root `df` was read on: an
operator legitimately points `DISK_GATE_PATH` at a volume, where `df` is right and no marker exists, and
classifying that would admit a python lane on the 64 MB harness pair. If neither path is a checkout the
target is genuinely unknown; the gate charges the harness pair and **names it in the pass log**, because
the alternative (charging the python bound) refuses every harness lane on any cell below ~8 GB free. That
case is a caller bug, and the log is where it surfaces.

`uv.lock` alone was the first discriminator and it was a **false pass**: a pip/poetry/pdm service, or a
monorepo whose lock sits in `backend/`, installs the same ~5.7 GB venv and would have been admitted on
the 64 MB harness pair. The detection fails toward the *expensive* pair on purpose — over-estimating a
harness lane withholds a few spawns on an almost-full cell; under-estimating a python lane fills it.
**Where that rationale does not hold, stated rather than implied:** the markers are matched as *exact
names*, so a project whose only requirement file is `requirements/base.txt` (Django's default layout),
`requirements-dev.txt`, or `environment.yml` matches nothing and derives the 64 MB harness pair — the
failure is then toward the CHEAP pair, and a ~5.7 GB venv can materialise on 2,064 MB of headroom. The
fleet's own lanes are covered (`uv.lock` in tortoise, no install step in agent-infra); a repo adopting
one of those layouts should add its marker, or set `DISK_LANE_TREE_MB`/`DISK_LANE_SELF_MB` for the cell.

⚠️ **What the reserve does not buy.** Two things, both stated rather than implied.

**Concurrent spawns inside the materialisation window.** Admission compares one fresh reading against one
lane's worst case, so it is correct for the lane it is deciding and for any lane spawned AFTER that lane's
tree exists. It is **not** a reservation: a python lane's 5,772 MB materialises over minutes, and two or
three dispatches inside that window all read the same free value and are all admitted. On a cell sitting
at the bound with the sharing regime lost, k concurrent python spawns can consume k x 5,772 MB against
~8.1 GB free — the #2721 wedge, with every log line saying *admitted*. Closing it needs a reservation
(a lane marker held from admission to install, or a dispatcher-side counter), and no such marker exists
today; the gate narrows the window, it does not remove it.

**How the reserve itself can be lost.** The admission rule guarantees that the lane admitted *now* cannot
consume the reserve even in its worst case. It does not guarantee `free >= reserve` for ever: a cell
can lose the sharing regime wholesale (a `pi-cache-reap.sh --caches` sweep frees the cache but the NEXT
sync re-materialises every venv it prunes), and the gate then refuses one lane at a time as the free
space falls. That is the correct behaviour — the refusal is the signal — but it means the budget below
is a *budget*, not a hard floor enforced by construction.

### The number the fleet must budget **per lane**

* **316 MB/lane** on a cell whose shared uv cache is populated (measured above) — plus **~5.7 GB once**
  per cell for the cache itself.
* **5,772 MB/lane** the moment the sharing is lost, which is why admission is bounded by
  `max(tree, self) + reserve` and not by the marginal figure: a budget built only on 316 MB admits
  exactly the spawns that filled cell-4.
* Consequence for the concurrency target (`MAX_LANES = vCPU * 5/2` = **20** on 8 vCPU): with sharing,
  20 lanes ≈ 6.3 GB + 5.7 GB cache + **2 GB reserve** (`4 x the 500 MB dispatch floor`, the value the
  code computes) ≈ **14 GB**, which fits a 128 GB cell with room for the CI runners.
  **Without sharing, 20 lanes need 117 GB (115 GB of trees + the 2 GB reserve) + the base image — it does
  not fit**, and the honest answer is that such a cell can carry ~9 lanes. ⛔ The reserve is **2 GB, not
  the 6 GB python worst case**: those are different numbers doing different jobs (the reserve is what
  must survive the *next* lane; `self` is what one lane costs when sharing is lost), and setting
  `DISK_LANE_RESERVE_MB=6144` to "match the worst case" raises every python spawn's bar from 8,144 MB to
  12,288 MB — mass `DISK-NOHEADROOM` refusals from a line of documentation. If a cell starts refusing `DISK-NOHEADROOM`
  while it has tens of GB free, the sharing regime was lost; measure it before raising the reserve.

**Measure your own cell** (never infer it from `du`): in a fresh worktree,

```bash
df -Pm / | awk 'NR==2{print $3}'   # used, before
git -C <repo> worktree add --detach /tmp/measure-wt HEAD
df -Pm / | awk 'NR==2{print $3}'   # after the checkout  -> the add cost
cd /tmp/measure-wt && uv sync --extra embeddings --extra parity
df -Pm / | awk 'NR==2{print $3}'   # after the install   -> the marginal venv cost
du -sm .venv                       # the APPARENT figure (upper bound, never the budget)
```

then set `DISK_LANE_TREE_MB` / `DISK_LANE_SELF_MB` / `DISK_LANE_RESERVE_MB` for that cell, and say so
where an operator will read it. `scripts/worktree-disk-probe.sh` classifies which byte regime the
machine is in. The gate's own ledger (`$O/state/disk.tsv`) records all three per spawn, so a series
always separates *what a lane cost* (field 6) from *what it would have cost with sharing lost* (field 8)
— field 7 is the reserve, not the worst case; reading it as the per-lane unshared cost budgets ~2000 MB
where the real figure is ~5,772 MB.

### The KEEP rule: a shell at a prompt is not a live lane

Both liveness reapers (`reap-lane-venvs.sh` for the env, `pi-reap-worktrees.sh` for the checkout) now
apply one rule:

> A cwd / argv / tmux-pane holder is **live evidence unless it is a shell whose start time is before
> the worktree's HEAD commit and which has no child process.**

A shell at its prompt answers "yes, someone is here" for ever, and that single false positive is why 59
checkouts accumulated on cell-4 while the logs said `KEEP … (a live process has it as cwd)`. A lane
between turns still holds its `pi`/test **child**, so it is not demoted; a lane that finished and left
its pane or its `cd` behind is. Every other gate is untouched (`dirty`, `ignored-artifact`, `open-pr`,
`too-recent`, `detached-unreachable`, `remote-only-ref`, `main-proof-vanished`), so the blast radius
of a wrong reading is a re-created env or checkout — never uncommitted or unpushed work. Every unprovable input (pid not in the
`ps` table, unreadable start time, undatable HEAD, failed probe) leaves the holder **live**, and each
demotion is named in the pass log (`stale-shell:` / `STALE-SHELL`), and `pi-reap-worktrees.sh` also
carries it into the row (`unref=stale-shell:<pids>`) — the venv reaper's row has no `unref` column, so
for an env the pass log is the record (stated here because the difference otherwise reads as a missing
field). `REAP_VENV_IDLE_SHELL=0` / `REAP_WT_IDLE_SHELL=0` restore the strict
reading without editing a shipped script. The start time comes from the process table's own creation
time (`/proc/<pid>`), and both reapers read it through a root seam — `REAP_VENV_PROC_ROOT` /
`REAP_WT_PROC_ROOT`, default `/proc` — so a test can drive the `ps` fallback deterministically on a
host where the fixture pid happens to be live; in production the seam is never set.

Two more seams exist ONLY to make backstops testable, and production never sets them either:
`REAP_VENV_SCAN_CAP` / `REAP_WT_SCAN_CAP` lower the scan's runaway cap so its **exhaustion** branch can be
reached. That branch is otherwise unreachable by construction (the derived cap exceeds any holder count
and each iteration consumes a distinct pid), which is exactly why it needs an arm: its polarity is
`truncated => LIVE`, and the opposite reading — "no holder found" — deletes a live lane's env or
checkout. Both suites drive it (`K10`, `G2721m`) and both fail if the branch is reverted.

The scan that applies the rule examines **every** holder (an idle shell and a working lane routinely
share a checkout) and carries a per-record exclude list instead of mutating the probe output, so one
verdict cannot consume the evidence the next one needs and a probe that keeps returning the same pid
terminates instead of spinning. `pi-reap-worktrees.sh` also asks the rule again **at removal time**,
re-reading the process and cwd tables first: a shell demoted as idle can pick up a child — i.e. start
working again — while the pass is still running, and that is exactly when the delete must stop.

⛔ **A shared *environment* is not the fix, and was not adopted.** The recorded decision in
`docs/ops/lane-venv-reaper-policy.md` rejects a machine-wide venv because `uv` installs the project in
EDITABLE mode pointing at ONE worktree, so a shared env silently imports the wrong code for every other
lane. The shared thing the fleet already uses is the **uv cache** (block sharing via hardlinks), which
is sanctioned and keeps each lane's editable install its own. Reviving a shared venv would be a reopen
of that decision, not an optimisation.

## Deliberately out of scope

* **`node_modules`** — still reclaimed by the supervisor's existing sweep; it is not
  on the measured offenders and would need its own liveness proof.
* **The uv cache is never deleted wholesale** — the owner prunes and evicts entries
  under a size bound, because a venv may share blocks with it (a hardlink or an APFS
  clonefile — per machine, see "Byte accounting" above).
* **Removing branches** — `git worktree remove` deletes checkouts; branch refs are
  never deleted by any class.
* **Retiring the per-sink Mac jobs** — `com.tortoise.worktree-reaper` and
  `com.eldato.pi-cache-reap` keep their own launchd jobs. The consolidated pass is now
  scheduled alongside them (`com.eldato.disk-reaper`), and retiring them is a follow-up
  that needs a measured window on a Mac — which the Linux cells this was built for
  cannot provide.
* **The general stale `/tmp` population** (c1: **148 826 entries > 24 h ≈ 15 G**; c4's `/tmp`
  measured 48 G) — **the gitless half is implemented on the merged base, not here**: #3272
  (`f2d40ef8`) added `--include-gitless` to `scripts/reap-abandoned-worktrees.sh`, reached from this
  pass's abandoned arm (`DISK_REAPER_GITLESS=0` off-switch), so a `/tmp/<name>` tree with no `.git` is
  swept once its liveness witness (a live-pid cwd/exe census) says no live process is in it. The
  remainder is filed as **#3043** and is still not implemented: it is a different trade from
  `class=runner-work` — a live lane's cwd can BE under `/tmp` (measured, a running `pi` lane cwd'd in
  `/tmp/cell-t3/.worktrees/…`), so an mtime floor is not proof of death, and a scratch copy is the only
  artifact of an unfinished review. Beyond the pass's own bounds (the count ceiling,
  `REAP_AW_GITLESS_MAX` default 10 per root, now charged to AGED candidates — #3278 — and a per-root
  wall-clock budget on its **expensive per-candidate work**, `REAP_AW_BUDGET_SECONDS` default 300 s, inside
  a `DISK_REAPER_CLASS_TIMEOUT` of 1800 *per root invocation*) and the trees a `.git`-owned arm claims, it needs an
  owner ruling on what scratch counts as evidence — the same reversal-of-a-decision problem
  `docs/ops/disk-consumers.md` G2 records. Do not "just add an age sweep": it would delete working
  lanes' trees.

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

That gap is the shared-block regime ON THIS BOX (the per-machine caveat above — `du` is
not always the over-counting instrument): the cache's blocks were already owned by the
live lane venvs, so emptying the cache freed almost nothing real (and the next
`uv sync` will copy rather than hardlink). A reaper that reported the `du` number would have claimed
5.7 GB for 74 MB. The class-1 bound itself is proven with real bytes by
`disk-reaper.test.sh` T4/T7 on a fixture cache that has no hardlinks.

Safety on live estate, both passes: `live-process` and `live-cwd` rows were preserved
(including the running controller's own harness pin and every active lane worktree);
the only venv reaped under a live lane belonged to one already in the merge chain,
which runs in the main checkout and needs no env. A fixer that is merely *between
commands* has no witness by construction (#1949's declared limit): its env is
regenerable with `uv sync`, and its WORKTREE is never touched (open PR + dirty gates).
