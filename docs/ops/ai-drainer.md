---
title: "The AI drainer and the second controller — scheduled dispatch for a repo no controller drains"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-10-24
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-2281, ai-drainer, multi-repo-controller, fleet-inventory, orchestrator-bringup, systemd
---

# The AI drainer and the second controller

Two scheduled things that exist because **a repo with open PRs and no controller bound to it gets no
automatic dispatch at all** (agent-infra #2281). Both ship in this repo; both are **inert until an
operator activates them on a box**, and both are in the fleet inventory so their absence is visible.

| artefact | what it is | schedule |
|---|---|---|
| `scripts/orchestrator-harness/ai-drainer.sh` | ONE bounded lane per tick: make PRs mergeable, merge what goes green | 20 min (both platforms) |
| `scripts/orchestrator-harness/multi-repo-controller.sh` | a SECOND controller bound to another repo, with its own state dir and pin | long-running (no timer) |
| `templates/launchd/com.eldato.ai-drainer.plist`, `com.eldato.ai-multi-repo.plist` | macOS jobs | rendered by `scripts/install-launchd.sh` |
| `templates/systemd/eldato-ai-drainer.{service,timer}` | the cell's clock | rendered by `scripts/orchestrator-harness/install-drainer-timer.sh` |

## What they are not

- **Not a second funnel.** The drainer does not pick candidates from the controller's queue; it walks
  a PR list and does the work. The real fix for #2281 (one dispatch that serves several repos) is
  still unbuilt, and this is the smallest thing that keeps a backlog moving while it is.
- **Not a second controller on the same state dir.** Two controllers on one `$O` fight over
  `.orch.lock`, `candidates.txt` and the lane registry; `multi-repo-controller.sh` refuses that by
  name (and refuses the primary's `HARNESS_PIN` for the same reason).
- **Not installed by the PR, and not installed by a plain `install-launchd.sh`.** Both plists render
  from **env-only** placeholders, so an unset variable makes the installer SKIP the template with a
  loud warning (the same convention `{{SWARM_ROOT}}` uses). That is deliberate: `install-launchd.sh`
  with no arguments installs *every* template, and `pi-bootstrap/setup.sh` runs exactly that on every
  Darwin box — a default here would put a lane **dispatcher** on the whole fleet and a **second
  controller** on every box.

## The three guards, and why the lock is the interesting one

`ai-drainer.sh` never starts a lane unless all three hold, and each writes one line to
`$AI/logs/ai-drainer.log` when it refuses:

1. **single instance** — a lock directory. It is **held for the LANE's lifetime, not for the dispatch
   call**: the dispatcher backgrounds the worker and returns immediately, so releasing the lock after
   the call would hold it for milliseconds while the lane runs for up to `LANE_TIMEOUT`. The next tick
   would then start a SECOND lane against the same slice, and every tick would exit 0 — a lane storm
   no instrument reports.
2. **capacity** — free swap below `MIN_SWAP_MB` (default 700), or `MAX_LANES` (default 4) already
   running. A lane is counted from its pidfile by **argv shape**: both shipped dispatchers record the
   pid of a *backgrounded subshell* whose command line is `bash …/nonblocking-dispatch.sh …` (`pi` is
   its child), so a test for "the command line starts with `pi`" counts **zero** on every real
   dispatch and the cap could never fire. An unreadable swap read is a **failure**, never a skip: a
   guard that could not be evaluated must not look like a correctly-idle box.
3. **rotation** — a cursor over the open list (`SLICE_WIDTH` per tick, wrapping at `SLICE_TOTAL`), so
   repeated ticks do not all work the same six PRs.

Two more properties are part of the same contract, because each one is a way for a tick to look
successful while nothing happened:

- **the lane's own exit status is the verdict.** Both dispatchers write `$O/bg/<name>.rc`; a spawn
  refused by a gate dies in milliseconds, so "the pid is gone" is not "the work happened". No `.rc` →
  the tick FAILS (refused or lost); `.rc != 0` → the tick FAILS and names the log. The lock is also
  **not** released on a zero-length wait: an unreadable lane pidfile is a failure, not a free lock.
- **the beat is written by every tick that ran**, including a skip — on a swap-bound box, SKIP is the
  normal steady state, and a beat written only after a dispatch would make a correctly-idle job read
  `LATE` for ever.
- **the worktree is removed on every exit path** except a timeout (a lane may still be writing in it):
  a fresh checkout per tick with nothing removing it is ~72/day of disk on a box that has already been
  disk-bound.

`ai-drainer.test.sh` covers all three guards, both tick verdicts, and the launcher's refusals, and
asserts the concurrency arm against a **mutation**: the same arm is re-run against a copy with the
lock block deleted and must then FAIL (two lanes start). A guard test that cannot detect the guard's
absence proves nothing. A second arm drives the *reclaim* path directly — three ticks racing over one
STALE lock must still start exactly one lane, which is the arm that catches a non-atomic reclaim.

## Activate on macOS

```bash
# 1. the drainer (per repo, one box): where it dispatches, and where its own state lives
AI_DRAINER_O=$HOME/orchestrator AI_DRAINER_STATE=$HOME/orchestrator-ai \
  bash scripts/install-launchd.sh           # renders + bootstraps com.eldato.ai-drainer

# 2. the second controller: render the job, then create its identity ONCE
AI_MULTI_REPO_SLUG=daniel-ospina/agent-infra \
AI_MULTI_REPO_REPO=$HOME/agent-infra-main \
AI_MULTI_REPO_STATE=$HOME/orchestrator-ai \
  bash scripts/install-launchd.sh           # renders com.eldato.ai-multi-repo

OR=daniel-ospina/agent-infra REPO=$HOME/agent-infra-main O=$HOME/orchestrator-ai \
  HARNESS_PIN=$HOME/orchestrator-ai/state/HARNESS-PIN \
  bash scripts/orchestrator-harness/multi-repo-controller.sh --init     # state dir + own pin
launchctl kickstart gui/$(id -u)/com.eldato.ai-multi-repo                 # start it once
```

`install-launchd.sh --status` lists both jobs with their drift; `install-launchd.sh --uninstall`
boots them out. The installer never creates the state dir — `--init` is the one deliberate step that
does, and the launcher REFUSES to run without it.

## Activate on a cell

A cell has no launchd. **The choice: systemd, by the same installer pattern the disk reaper already
uses** (`scripts/install-disk-reaper-timer.sh` renders `templates/systemd/*` and
`systemctl enable --now`s them). It is NOT a fifth role of the cell doctor loop, for one measured
reason: the drainer's lock must outlive its own pass (it waits up to `LANE_TIMEOUT` for the lane it
dispatched), and a role that blocks the shared doctor/merge/hygiene loop for ~50 minutes delays the
cell's health work and trips the loop's own stall bound on a *healthy* drainer.

```bash
# on the cell — user unit if a user manager answers, system unit with passwordless sudo otherwise
DRAINER_O=$HOME/orchestrator DRAINER_STATE=$HOME/orchestrator-ai \
  DRAINER_REPO_SLUG=daniel-ospina/agent-infra DRAINER_SEED_REPO=$HOME/agent-infra-main \
  bash scripts/orchestrator-harness/install-drainer-timer.sh          # --dry-run to preview
bash scripts/orchestrator-harness/install-drainer-timer.sh --status   # installed? active? next run?
```

The timer is `OnUnitActiveSec=20min` (not `OnCalendar`) so the next tick is a fixed distance from the
last real attempt instead of bunching skipped ticks after a long lane. The installer **aborts** on
every failed pre-flight (a rendered unit is rejected if it is empty, has no `ExecStart`, or keeps a
`{{placeholder}}`), reads the timer's `is-active` back after enabling it, and refuses a **user** unit
whose manager will not linger — a user timer that stops with the last ssh session is an installed job
that schedules nothing. `cloud-cell-bringup.sh` does **not** install it: a lane dispatcher is per-repo
and costs model spend, so it is an explicit, per-cell operator step — the same shape as the disk
reaper's arming.

The second controller on a cell is the cell supervisor's business (`cloud-cell-supervisor.sh start`
with `OR`/`O` for that repo); it needs no timer at all, and its inventory row says so
(`no launchctl` → SKIPPED on a cell) rather than pretending to check a launchd job.

## Verify

```bash
bash scripts/orchestrator-bringup.sh status
```

Two rows matter, and both are calibrated against the failure they exist for:

| row | OK means | the state that is NOT OK |
|---|---|---|
| `ai-drainer` | job loaded, last exit 0, its own **beat** fresh within 2×1200s | `LATE` = installed and not running (nothing dispatches, nothing goes red); `MISSING` = the code is present and no job installs it |
| `second-controller` | job loaded, ONE `orch-loop.sh` for its own state dir, heartbeat fresh | `MISSING` = loaded with nothing cycling, or a controller identity with no job (hand-run, ends at reboot); `DUPLICATE` = two controllers on one dir |

Two details of that row are deliberate. Its state dir comes from the **job's own `O`**, not from the
seam (an operator who activated it elsewhere would otherwise be judged against a directory the job
does not use); and "a second controller was set up here" is evidenced by the `--init` artefact
(`state/HARNESS-PIN`), **not** by the directory existing — `$HOME/orchestrator-ai` is also the
drainer's default state dir, so the weaker test turned activating *only the drainer* into a red row
instructing the operator to install a second controller.

The drainer's freshness file is `$AI/state/ai-drainer.beat`, written as soon as the tick owns the lock
and on every poll while it holds it — not its log, because a healthy 50-minute pass would otherwise
read `LATE` against its own 20-minute interval. That is also why the plist declares **no**
`StandardOutPath`: the inventory prefers a plist's capture path over the row's own file, and this
script writes nothing to stdout on any normal path, so declaring one would date an untouched file and
mark a healthy drainer `LATE` for ever.

## Known remaining gap (owned elsewhere)

The second controller does see the backlog — 72 rows — but **spawns nothing**, with the reason
`no per-PR read this cycle (the open-PR listing w…)`. The drainer is what keeps work moving until that
funnel is fixed; it is not a fix for it.
