---
title: "#1987 — machine-global package caches: bound, on a clock, on both surfaces — Scope"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-10-18
aboutSubjects: disk-reclamation, uv-cache, organisation-design-team
aboutObjects: agent-infra, issue-1987, pi-cache-reaper.sh, pi-cache-reaper.test.sh
---

<!-- issue-scoping: v5.1 double diamond + verify — lane scope for #1987 -->
## Confirmed Problem

Verified against the code before any change (not taken from the body):

* `grep -rn 'uv cache\|_cacache\|cache/pip' scripts/` found **no** reaper for the machine-global
  package caches — only `scripts/orchestrator-harness/refresh-candidates.sh` *setting* `UV_CACHE_DIR`
  for the dispatch scout.
* `cloud-cell-supervisor.sh prune` (#1745) sweeps `.venv`/`node_modules`/`.pytest_cache`/`__pycache__`
  at **worktree roots** (`sweep_root_caches`), plus superseded harness pins and `/tmp` scratch — the
  shared `~/.cache/uv` is outside its reach, and `prune --caches` returns before the scratch pass.
* `spawn-gate.sh` enforces the disk floor (`DISK_MIN_FREE_MB`, default 500) and its refusal text tells
  the operator to *"reclaim with 'cloud-cell-supervisor.sh prune'"* — a remedy that does not touch the
  measured consumer.
* Nothing schedules any cache work on a Linux cell: `install-launchd.sh` is macOS-only and
  `orchestrator-harness/install.sh` dies with *"this harness uses launchd + tmux; only macOS is
  supported"*. A cell's only scheduler is `orch-loop.sh` (tmux), which is where its hourly
  `claim_prune` already lives.

So the root cause is **not** "a big cache": it is that the shared, unbounded, machine-global sink has
no owner, no bound, and no clock on the surface (Linux cells) where it grows fastest. The controller
keeps beating and the queue reads fine because the only instrument that sees it —
`spawn-gate.sh`'s disk floor — refuses *after* the disk is gone.

**Measured on this lane's own box** (cmux VM, `HOME=/tmp/cell-home`, Ubuntu 24.04): `du -sm` reported
`~/.cache/uv` at **6091 MB**, `~/.npm/_cacache` 505 MB, `~/.cache/pip` 14 MB. The reported incident is
reproducible in kind on any box: 6091 MB of cache for one lane's own `uv` use, with no bound.

## Verification Gates

### full-diamond-verify: lane mode — the problem verification is the code+measurement evidence above; the solution verification is the PR's fresh-context code review (recorded in the PR body at the reviewed head SHA). No separate verifier cycles were dispatched for this scope comment, and none is claimed.

## Plan

1. **`scripts/pi-cache-reaper.sh`** — bounds each sink by SIZE (`CACHE_REAPER_MAX_MB`, default 2048),
   never by age:
   * **measure** → within bound: report, do nothing;
   * **prune** with the tool's own in-use-safe command (`uv cache prune`, `npm cache verify`);
   * **escalate** only while still over the bound AND no live holder: uv by removing the largest
     **exclusively cache-owned** `archive-v0` entries, gated on uv's own `.lock`
     (`flock(LOCK_EX|LOCK_NB)`, verified: with the lock held, `uv cache prune` prints *"Cache is
     currently in-use, waiting for other uv processes to finish"*), npm via `npm cache clean --force`
     and pip via `pip cache purge`, gated on a live-process probe that is treated as BUSY when it
     cannot answer;
   * one line per sink with before → after and the rung that produced it;
   * **refuse to act**: a sink still over the bound afterwards, or a ladder that freed nothing, exits
     3 and says so.
2. **Exclusivity, because the alternative is a lie.** A venv does not copy a wheel, it **hardlinks**
   into `archive-v0` (recorded in `pi-reap-worktrees.sh`). Deleting an entry a venv still holds frees
   **zero** disk and forces a re-download. Measured on the live box while building this: a
   size-ordered deletion removed **4.1 GB** of "largest entries" and `df` moved **5 MB**, because 174
   of 266 entries were alive inside 29 worktree venvs; the 92 exclusive entries (358 MB) were the only
   real reclaim. The shipped ladder deletes only entries whose every file has link count 1, and names
   the hardlinked residue when that is why a sink is still over the bound.
3. **A clock on both surfaces**: `templates/launchd/com.eldato.pi-cache-reaper.plist` (hourly, farmed
   by `pi-bootstrap/setup.sh`) for Macs; an hourly cadence in `scripts/orchestrator-harness/orch-loop.sh`
   for cells (the only scheduler a cell has); `cloud-cell-supervisor.sh prune` delegates to the same
   script so the disk gate's own remedy text is finally true.
4. **Visibility before death**: `cloud-cell-bringup.sh --check` reports each cache's size and the free
   space on the cell's disk, naming the reaper when a sink is over the bound.
5. **Tests**: `scripts/pi-cache-reaper.test.sh` (registered in `scripts/run-bash-shards.sh`) — fixture
   caches, stub tools, real held-lock, fail-closed ps probe, refuse-to-act, and the wiring on both
   surfaces. Red on the pre-fix tree (24 failing assertions), green after.

### Wiring

| Change | Wired to | Why it must be here |
|---|---|---|
| `scripts/pi-cache-reaper.sh` (new) | launchd plist, orch-loop cadence, `cloud-cell-supervisor.sh prune`, bringup report | one policy owner; the four callers would otherwise drift |
| `templates/launchd/com.eldato.pi-cache-reaper.plist` (new) | `scripts/install-launchd.sh` (all `templates/launchd/*.plist` are rendered) | the Mac timed job |
| `pi-bootstrap/setup.sh` `fleet_srcs` | farmed copy at `$HOME/.pi/agent/scripts/` | plist target + cell path; unfarmed = broken-target refusal |
| `scripts/orchestrator-harness/orch-loop.sh` | hourly marker `$O/state/.cache-reaped`, backgrounded | Linux cells have no launchd/cron |
| `scripts/cloud-cell-bringup.sh` | `--check` step + `CELL READY` banner text | the issue's "visible BEFORE it stops dispatch" |
| `scripts/cloud-cell-supervisor.sh prune` | delegates to the reaper | makes the disk gate's remedy text true |
| `scripts/run-bash-shards.sh` | the one shard list both CI lanes run | the suite must actually run |
| `scripts/install-launchd.test.sh` | new job's assertions + bootstrap inventory | a template nothing asserts is a template that rots |

## Clarifications

None required: the issue specifies the bound (~2 GB), the sinks, the prune-first-escalate rule, the
lock safety, the reporting surfaces and the refuse-to-act polarity. The one judgement the issue left
open — where a cell's "timed job" lives — is answered by the code (cells have no launchd and no cron),
so it did not qualify as a user question.

## External Research (Phase 1.5 artifact)

### Axis Research

* Canonical prune semantics — `uv cache prune` is documented as *"Prune dangling cache entries and
  cached environments"*, with `--force` to *"Force removal of the cache, ignoring in-use checks"*, i.e.
  the DEFAULT respects in-use state. Read from `uv cache prune --help` (uv 0.12.5, this box); behaviour
  confirmed empirically by holding `$UV_CACHE_DIR/.lock` and observing *"Cache is currently in-use,
  waiting for other uv processes to finish"*.
* Cache layout (uv 0.12.5): `archive-v0/<hash>/…` holds the unpacked wheels — 6075 of 6096 MB on this
  box — with `environments-v2`, `simple-v24`, `wheels-v6`, `sdists-v9`, `interpreter-v4` making up the
  rest. The reclaim unit is therefore an `archive-v0` entry.
* npm exposes only `npm cache verify` (garbage-collect) and `npm cache clean --force` (wipe); npm's
  `index-v5`/`content-v2` layout is internal and not ours to edit, so escalation uses the documented
  wipe. pip exposes no prune at all: `pip cache purge` is the only reclaim.
* Hardlink semantics: unlinking a cache entry whose inodes are also named by a venv frees no blocks
  (the inode survives), which is why the exclusivity test — link count 1 on every file — is the
  criterion for "unused", rather than age or position in a size list.

### Integration Docs

Depends on `du`, `find -links`, `awk`, `sort`, `ps`, `df` (POSIX/POSIX-adjacent, present on macOS and
the Ubuntu cells), optional `python3` for the `flock` probe (absent → *undeterminable* → treated as
held, never as clearance), and the `uv`/`npm`/`pip3` binaries already required by bring-up
(`check_tools`). No new dependency is introduced: `flock(1)` is deliberately NOT used because macOS
ships no `flock` binary.

## Rejected Alternatives

* **Age-based pruning (`-mtime +N`)** — rejected: the boxes that fill this cache are the ones that
  re-create entries right after touching them, so age keeps exactly the wrong entries; and an entry is
  worthless because nothing references it, not because it is old. The issue says size, and the
  evidence says reference-count.
* **`rm -rf` the cache and let it rebuild** — rejected: it is what the operator incident did by hand,
  it is unbounded (drops 7 GB when 100 MB was over the line), it guarantees a re-download storm on a
  box that is mid-dispatch, and it cannot be run while a lane resolves against the cache.
* **Deleting the largest entries regardless of who references them** — rejected on measurement, not
  taste (see §2 above: 4.1 GB removed, 5 MB freed).
* **A per-worktree venv reaper instead** — rejected as scope: #1949/#1745 already own that, and the
  measured failure was the *shared* sink surviving all of it. The residue line in this reaper points
  those flows at the worktrees that hold the bytes.
* **Shipping it disarmed (dry-run default)** — rejected: the content is regenerable by definition, the
  first rung is the tool's own prune, the second cannot touch a byte a venv holds, and a reaper that
  only reports leaves the incident's cause in place. `CACHE_REAPER_DRY_RUN=1` remains the disarm.
* **A cron entry installed by bring-up** — rejected: these VMs do not run cron and `cmux vm exec`
  sessions do not persist one; the controller loop is the surface's actual clock.
