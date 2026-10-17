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
5.6 GB `uv` cache. That is why the box held ~4 lanes rather than 6. The absence of
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

* **No scheduled GC.** The runner's own teardown is the primary half and needs no
  clock; a periodic sweep is a separate change (it needs a plist, an interval, and an
  owner) and is not shipped here.
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
