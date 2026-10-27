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

A lane **scratch** checkout — a directory whose basename matches
`REAP_WT_SCRATCH_GLOB` (default `wt-*|cell-wt-*`) — has its floor **capped at**
`REAP_WT_SCRATCH_AGE_DAYS` (default `1`): a dead lane's throwaway dir is not a
week's worth of review surface. The cap only ever lowers, so a value above the
floor in force has no effect (14 does not mean "keep longer"), and a
merged/patch-equivalent scratch row keeps `REAP_WT_MERGED_AGE_DAYS`. Every other
gate still applies, and the pattern is anchored (`wtfoo/` is not `wt-*`), so a
named checkout is unaffected.

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
verdict_uv=deferred verdict_venv=ok verdict_worktree=ok
would_free_mb_* candidates_* repos=/tmp/cell-ai detail=pi-cache-reap.sh exited 7
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
supervisor prints the raw value; the total is the sum of the classes that WERE measured).

⛔ **The worktree class is REPORTED, not just counted.** `pi-reap-worktrees.sh` ends every pass with
ONE machine-readable line —

```
SUMMARY examined=<n> classified=<n> remove=<m> preserved=<k> deferred=<n> deferred_remove=<n>
        removed=<n> failed=<n> late_preserved=<n> prune_blocked=<0|1> reasons=<reason>:<n>,…
        main_proof=<auto|local|unavailable|auto-unfetched|ambiguous>
        main_ref=<refs/heads/…|refs/remotes/…|?> pr_merged=<ok|na|unavailable>
```

— and the record lifts it into `candidates_worktree=` (the delegate's own `remove=`),
`classified_worktree=`, `preserved_worktree=`, `preserved_reasons_worktree=`, `main_proof=` and
`pr_merged=`. `examined = classified + deferred` and `classified = remove + preserved` are the two
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
false PASS this record exists to remove. Two of the five classes cannot answer the CANDIDATE count on
every pass and say so rather than guessing `0`: `uv` (its owner publishes no tally, so an ARMED pass —
which has no `DRY-RUN` rows to count — records `candidates_uv=?`), and `duplicate-install` only when its
own `SUMMARY … candidates=<n>` did not answer (that delegate prints it in BOTH modes, so an armed pass
normally CAN answer).

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

The pre-existing suite (`disk-reaper.test.sh`) additionally scopes both owners' scratch roots to its
own fixture: without that, a `--apply` assertion anywhere in it would sweep the machine's real `/tmp`
(it did once, on this box, before the scoping was added).
`scripts/disk-reaper.test.sh` — 659 assertions, run by the `disk-reaper` shard of
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
ADMIT  iff  free_mb >= tree_mb + reserve_mb      (fresh `df` reading, at every spawn)
REFUSE with  `[disk-gate] REFUSED <label>: DISK-NOHEADROOM — …`  (AGENT_DISK_REFUSED, 77)
```

`tree` is what ONE more lane costs. `reserve` is the headroom a spawn must leave behind. Both are
**measured per target**, never one global constant: #1852 recorded that a single constant cannot serve
an agent-infra lane (48 MB, no install) and a tortoise lane (5.7 GB of python), and a tortoise-sized
floor would refuse every harness spawn on every cell — a false *block*, which is its own defect.

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

| target | `DISK_LANE_TREE_MB` (default) | `DISK_LANE_RESERVE_MB` (default) |
|---|---|---|
| `uv.lock` present (python lane) | **350** | **6144** (6 GiB = the 5,772 MB self-contained tree, rounded up) |
| no install step (harness lane) | **64** | **1024** |

### The number the fleet must budget **per lane**

* **316 MB/lane** on a cell whose shared uv cache is populated (measured above) — plus **~5.7 GB once**
  per cell for the cache itself.
* **5,772 MB/lane** the moment the sharing is lost, which is why the reserve is 6 GiB and not 316 MB:
  a budget built only on the marginal figure admits exactly the spawns that filled cell-4.
* Consequence for the concurrency target (`MAX_LANES = vCPU * 5/2` = **20** on 8 vCPU): with sharing,
  20 lanes ≈ 6.3 GB + 5.7 GB cache + 6 GB reserve ≈ **18 GB**, which fits a 128 GB cell with room for
  the CI runners. **Without sharing, 20 lanes need 115 GB + the base image — it does not fit**, and the
  honest answer is that such a cell can carry ~9 lanes. If a cell starts refusing `DISK-NOHEADROOM`
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

then set `DISK_LANE_TREE_MB` / `DISK_LANE_RESERVE_MB` for that cell, and say so where an operator
will read it. `scripts/worktree-disk-probe.sh` classifies which byte regime the machine is in.

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
demotion is named in the pass log (`stale-shell:` / `STALE-SHELL`) and in the row
(`unref=stale-shell:<pids>`). `REAP_VENV_IDLE_SHELL=0` / `REAP_WT_IDLE_SHELL=0` restore the strict
reading without editing a shipped script.

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
