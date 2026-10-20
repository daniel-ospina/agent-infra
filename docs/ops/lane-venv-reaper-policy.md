---
title: "Lane venv reaper policy — a .venv belongs to a running lane (#1932)"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-10-17
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-1932, lane-venvs, uv, disk-reclaim, reaper
---

# Lane venv reaper policy (#1932)

One place that pins **how a lane's `.venv` is reclaimed, and why it can never be
reclaimed while the lane is alive**. Implementation: `scripts/reap-lane-venvs.sh`
(tested by `scripts/reap-lane-venvs.test.sh`, farmed to `~/.pi/agent/scripts/` by
`pi-bootstrap/setup.sh`). Delivered by issue #1932.

## Problem class

A `.venv` is a private copy of Python plus every library the project needs. It is a
**build artifact**: it can always be recreated from `uv.lock`. Lanes run the test
suite (`uv sync --extra embeddings --extra parity`, per `AGENTS.md`), `uv` writes
`.venv` **inside the worktree**, and the fleet runs one worktree per lane — so every
lane materialises its own env, and before #1932 **nothing removed it**.

MEASURED on lane-1 (2026-10-17): 5 lane venvs = **7.3 GB deduplicated** on a 32 GB
disk (one of them 5.8 GB, because its lane installed a broader extra set), plus a
5.6 GB `uv` cache. ⛔ That dead residue is why the box ran out of **DISK**; it is not why
the box held ~4 lanes — **RAM** (~0.9 GB/lane) sets the lane count, and N LIVE lanes
need N x ~1.1 GB whatever the reaper does. Removing dead residue returns disk headroom
that those live lanes need; it **cannot raise the per-lane ceiling**. See
`docs/ops/disk-reaper.md`, "What this does NOT do" (#2159). The absence of
reaping is the "fix that is not live" shape: a resource created per lane with no
owner responsible for its end-of-life.

## The contract — a venv is removed ONLY when all of these hold

1. **Not the repo's MAIN checkout.** That env is the controller's, not a lane's.
   Decided by git (`--git-dir` == `--git-common-dir` only for the main checkout),
   never by path shape; a git that cannot answer is a KEEP.
2. **Not the worktree the reaper itself runs in** (GC mode only — see below).
3. **`<worktree>/.venv` is a REAL DIRECTORY.** A symlinked `.venv` is never
   followed, so no delete can leave the worktree.
4. **No live holder**, proven by three mechanical witnesses (next section).
5. **GC mode only:** the venv is older than `REAP_VENV_MIN_AGE_SECONDS` (default
   1800 s) — the floor that covers the window between `git worktree add` and the
   first process binding to it.

## Liveness is mechanical — never "the directory looks old"

| witness | what it reads | why it is needed |
|---|---|---|
| `live-tmux-pane` | `tmux list-panes -a -F '#{pane_pid} #{pane_current_path}'`, path canonicalized into the worktree | the fleet spawns every lane into its own tmux session, so this fires for a lane that is merely **between turns** (measured on cell-2: every live lane is a pane whose cwd is its worktree) |
| `live-cwd` | `lsof -a -d cwd` (or `/proc/*/cwd` where lsof is absent) | catches a `bash -c 'cd <wt> && pytest'` whose argv never names the path |
| `live-argv` | `ps -axo pid=,ppid=,command=` | catches `$wt/.venv/bin/python` running from a different cwd |

**The reaper's own process tree is excluded from all three** — ancestors *and*
descendants. Ancestors, because `--worktree` mode is called from inside the lane it
is reaping. Descendants, because every probe forks a subshell that carries the
parent's argv and cwd: measured during this change, a dry run classified its own
probe subshell as `live-argv` and kept every env while reporting itself correct. The
probes themselves additionally run from `/` (`run_probe`) and the bounded watchdog
`cd /`s, because `lsof` reports *itself*.

## Fail closed on ambiguity

A wrongly deleted env costs a lane a multi-minute re-sync; deleting the env of a lane
that is **mid-test** is the failure the design exists to prevent. So an unreadable
`ps`, an empty `ps` table, a tmux that is installed but cannot list panes, an
unavailable cwd probe, or an unstatable age is a **KEEP** — and for a probe that
makes the whole pass unsound, **exit 3 with nothing removed**. "No tmux server" is a
*known zero* (no session can exist), not a failure.

`REAP_VENV_ALLOW_DEGRADED_CWD=1` accepts tmux+argv-only evidence explicitly, and says
so on every report. It exists for hosts with neither `lsof` nor `/proc`; it is not a
default.

## The age floor is a declared surface, not a private default

`REAP_VENV_MIN_AGE_SECONDS` (1800 s) is a **retention** bound, so the #1068
declared-surface gate (`extensions/shared/heartbeat-progress-edges.ts`, reverse scan)
requires it in the registry — a new script that declares a liveness/retention bound
without registering it leaves the bound invisible to the audit that exists to notice
exactly that. It is registered there (axis `retention`, with the same shape as
`REAP_WT_LOCK_STALE_SECONDS`) and the suite pins both halves: the declaration in this
script and the registration that makes it auditable.

**And the bound is VALIDATED before it is compared** (#2158). Only the `--min-age`
argv form used to be checked; the environment form was compared raw, so any typo
(`30m`) made `[ "$age" -lt "$REAP_VENV_MIN_AGE_SECONDS" ]` error, take the else
branch under `set -uo pipefail` (no `-e`), and fall straight through to reaping — the
floor silently DISABLED, in the direction that deletes a live lane's env. It failed
open.

The final value (env or argv) is now checked with the same `is_pos_int` the `--min-age`
argv path already used, **and bounded in magnitude to at most 9 significant digits**
(~31 years). Leading zeros are stripped first, so they are harmless. A non-numeric or
over-long value is refused with **exit 2 and nothing removed**.

The bound is a SANITY CEILING, not the comparison limit. `[ -lt ]` parses with
strtoimax, so only a value above 2^63-1 makes the COMPARISON itself error — that was the
fail-open one size class up (99999999999999999999 passes `is_pos_int`, then `[` prints
"integer expression expected" and control falls through to REAP). Nine digits is far
below it, so the guard cannot be defeated by a value the comparison would choke on, and
no real floor can exceed it.

Why `2` and not `3`: **this is a departure from #2158's own suggestion** — the issue
proposed exit `3`. That predates #2036's split, in which a delegate's `3` became the
pass's **fail-closed** code (a RED unit). A typo must not be reachable from any code
whose meaning is anything else, so it keeps `2`, the misconfiguration code this script
already uses for a bad `--min-age`, which `disk-reaper.sh` maps to a red pass. (It is
emphatically not the benign deferral: only `pi-cache-reap.sh` `4`/`7` become that, and
only for the uv class.)

## Two entry points, and why both

| path | who calls it | what it proves |
|---|---|---|
| `--worktree PATH --apply` (**reap on exit**) | `lane.sh` (EXIT trap) and `fix-one.sh` (after the merge chain), via `spawn-gate.sh`'s `reap_lane_venv` | the lane is **known** to be done, so nothing is inferred. Covers every exit path, including a TERM'd session (bash runs EXIT traps on SIGTERM). The liveness re-probe still applies, so a worktree another lane is using, or a `pi`/pytest child still running after the agent returned, keeps its env. |
| `--gc --repo PATH [--apply]` (**orphan GC**) | `cloud-cell-supervisor.sh prune`, an operator, or cron | sweeps the lanes that never reached their exit path (killed session, reboot). Death is **inferred**, so every removal rests on the three witnesses plus the age floor. |

Dry-run is the default (`REAP_VENV_DRY_RUN=1`); `--apply` arms a pass. Every decision
row names its verdict, its reason, its evidence and its size, and the footer reports
`venvs_found / reapable / reaped / kept / recheck_kept / failed`.

## Byte accounting — two numbers, because only one pair is honest

* `du` per venv: the blocks the tree occupies. It **over-reports** what removal frees,
  because a venv hardlinks into the `uv` cache and the same cache blocks are counted
  again for every venv that shares them.
* `df` delta across the pass: what the filesystem actually got back.

MEASURED on cell-2 (2026-10-17, `/tmp/cell-t`, 23 lane venvs): `du` said
**77,438 MB** reclaimable; the filesystem returned **1,330 MB**. Both are printed and
the `du` figure is labelled an over-count. Do not quote a `du` total as reclaimed
space.

## Capacity — N measured, a stated floor, both printed

Byte accounting says what a pass reclaimed. It says nothing about what the box can still take, and
the acceptance clause on this issue is the second question: **a box can run N lanes without free disk
falling below a stated floor.** So every pass ends with one `capacity:` line carrying every input and
the verdict:

```
capacity: lanes_live=K lane_venv_max=M MB free_after=F MB floor=L MB floor_ok=yes|no|unknown lanes_headroom=N
```

| field | kind | meaning |
|---|---|---|
| `lanes_live` | MEASURED | lane **envs** this pass KEPT because a live holder was found — a count of retained envs, **not** of worktrees: a live worktree with no `.venv` yet produces no row and is not counted |
| `lane_venv_max` | MEASURED | the LARGEST lane env this pass saw — the worst case, never the mean. Its representativeness is only as good as the sample: a PARTIALLY-synced env is small and inflates `lanes_headroom`. The divisor is printed so a reader can reject the quotient |
| `free_after` | MEASURED | filesystem free space after the pass |
| `floor` | STATED | `REAP_VENV_FREE_FLOOR_MB` (default 2048 = one measured lane env, ~1.85 GB) |
| `floor_ok` | ASSERTED | `yes` / `no` / `unknown`. **`unknown` is never read as satisfied** — a `df` that cannot answer is never read as "enough", and the line names it and names why. It does **not** change the exit code: an unmeasurable `df` is not evidence of a *breach* (that is `no`, which exits 5). **Read `floor_ok`, never the pass's rc, as the floor verdict** |
| `lanes_headroom` | DERIVED | `(free_after - floor) / lane_venv_max`, floored at 0; `?` when an input is unreadable — never a fabricated number |

A pass that ends **below the floor exits 5** — **unless a removal also FAILED, in which case it exits 4**
(the severity order is 3 abort > 4 removal failed > 5 over-bound). The capacity line still reads
`floor_ok=no` and the `over-bound` log row is still written **before** that branch, so a degraded pass
never hides the breach; only the process exit code is 4. It **asserts, it does not reclaim**: the reaper
never deletes a live lane's env to get back above the floor. The floor is registered in the `#1068`
declared surface (`hygiene` axis, and in `OUT_OF_FAMILY_TERMS` because `_MB` is not a bound suffix — the
reverse scan cannot see the name on its own).

⛔ **Exit 5 is NOT yet surfaced by the fleet entry point — measured, not assumed.** An earlier draft of
this doc claimed `disk-reaper.sh` "already maps 5 to `over-bound`, so the fleet entry point reports it".
It does not: `worst_rc()` in `scripts/disk-reaper.sh` drops 5 (`0|5) printf '%s' "$cur"`), so a venv pass
that ends below the floor is recorded as `rc=0 verdict=ok`. Measured end-to-end with a stub delegate
exiting 5 under `--only venv --apply`: `disk-reaper: class=venv rc=0 verdict=ok`, status `ok=1`, and the
only trace is `detail=reap-lane-venvs.sh exited 5`. `class_verdict()`'s `5)` arm (also `fail-closed` in
apply mode) is therefore unreachable for this class. The breach IS named by the reaper's own capacity
line and its log (`over-bound`), and `spawn-gate.sh` reports it per lane exit; the pass-level plumbing is
tracked separately. Do not restate the old claim without re-measuring it.

## ⛔ The `uv` download cache is never touched

A venv hardlinks into the cache: removing the cache does not free the space it
appears to (the links keep the blocks alive) and it forces every later `uv sync` to
write a full copy. That is the measured regression this issue started from: 6.1 GB
"freed" by deleting the cache, then re-spent as duplicated venvs. Bounding the cache
is `uv cache prune` (which preserves live links) — a different tool, deliberately not
this one. The reaper references no cache path and performs exactly one `rm -rf`, on
the `.venv` basename, from inside the verified worktree.

## Considered and rejected: a machine-wide shared dependency env

`uv` installs the project itself in **editable** mode pointing at one worktree, so a
shared env would silently import the wrong code for every other lane. The safe
version (`--no-install-project` plus an explicit `PYTHONPATH` per lane) is a design
decision, not a reaper, and is recorded here so it is not re-proposed as a hotfix.

## Ops

```bash
# report only (default), for one repo's worktrees
scripts/reap-lane-venvs.sh --gc --repo /tmp/cell-t
# armed
scripts/reap-lane-venvs.sh --gc --repo /tmp/cell-t --apply
# the runner's own path (what lane.sh/fix-one.sh do)
scripts/reap-lane-venvs.sh --worktree /tmp/cell-t/.worktrees/fix-1234 --apply
```

A cell gets the reaper at `~/.pi/agent/scripts/reap-lane-venvs.sh` (farm), and
`cloud-cell-supervisor.sh prune` runs the GC for `$REPO` and `$HARNESS_REPO`. On a
cell, `REAP_VENV_LOG` defaults to `$HOME/.pi/agent/state/reap-lane-venvs.log`.

## Declared residuals

* **A scheduled GC DOES run — on installed cells.** `eldato-disk-reaper.timer`
  (`OnCalendar=hourly`) runs `disk-reaper.sh --apply`, which calls this reaper as
  `--gc --repo <r> --min-age 1800 --apply` (armed by #2032; see
  `docs/ops/disk-reaper.md`). The runner's own teardown remains the PRIMARY half — it
  needs no clock and knows the lane is done — but an operator must not read "no
  scheduled GC" here: an unattended sweep exists and deletes lane venvs unattended.
* **The cwd witness is permission-bounded.** `lsof`/`/proc/*/cwd` can only name a
  process the invoking user may inspect, and a NON-EMPTY partial table still sets
  `CWD_STATE=ok`. A holder running as a DIFFERENT user, whose argv does not name the
  path, is invisible to all three witnesses and its env would be reaped. The fleet is
  single-user today; on a multi-user box this is the gap to close first (the argv
  witness still covers a cross-UID process that names the path).
* **A missing `tmux` binary is reported as "no tmux server on this host".** Both set
  `TMUX_STATE=absent`, so a cell whose `PATH` does not contain `tmux` loses the pane
  witness while the log claims the host has no server. The cwd witness still covers a
  pane sitting in the worktree.
* **A lane parked OUTSIDE its worktree between turns** (agent `cd /tmp`, then idles) has
  no cwd, no argv and no pane inside the tree, so it reads as dead. Cost is a re-sync of
  a build artifact, not data.
* **The main checkout's `.venv` is out of scope** — it is not a lane's env and the
  issue measured lane venvs.
* **`node_modules` is unchanged.** It is arguably the same class once a lane's dev
  server holds it, but it is not on the measured 7.3 GB and widening this change
  would need its own liveness proof.
* **A venv held open by a process that outlives its lane reads as live and is KEPT.**
  Measured on cell-2: five dead lanes' envs were held by stranded `redislite`
  `redis-server` processes (`orphan-reap.py` deliberately excludes that class; it
  belongs to tortoise's embedded-process reaper). Correct behaviour, visible in the
  KEPT list, and it clears when the orphan is reaped.
* **The capacity line ASSERTS the floor, it does not enforce it.** A pass below
  `REAP_VENV_FREE_FLOOR_MB` exits 5 and says so; nothing is deleted to get back above
  it, and nothing stops a dispatcher from starting another lane. Enforcement (refusing
  a dispatch under the floor) belongs to the dispatcher — #1852 holds the measured
  gap between the dispatch floor and what one lane actually costs.
* **`lanes_headroom` divides by the largest env seen in THAT pass.** A pass over a repo
  with no lane venv at all prints `?` rather than assuming a size: a headroom number
  invented from a default is the same lie as a `du` figure quoted as reclaimed space.
