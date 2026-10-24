---
title: "PR-repair service — the cell's repair actuator, owned by a service manager (#2716, #2709)"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-10-24
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-2716, issue-2709, issue-2700, issue-2721, issue-1974, systemd, cloud-cell, pr-doctor
---

# PR-repair service (#2716, #2709)

`scripts/install-repair-service.sh` renders and installs **`eldato-pr-repair.service`** — a systemd
unit whose main process *is* the cell's repair loop (`scripts/pr-repair-loop.sh --loop`). It exists
because the fleet has **two capabilities that were being confused for one**.

| unit | what it does | what it does NOT do |
|---|---|---|
| `eldato-orchestrator.service` (`#2402`) | DISPATCHES lanes from the issue queue — `orch-loop.sh` | repair, reap or land a PR |
| **`eldato-pr-repair.service`** (this page) | DRIVES THE OPEN PR QUEUE toward `merged` — reap, then `pr-doctor.py` | dispatch issue work |

⛔ **They are separate units on purpose, and neither installer touches the other's unit.** Merging them
would let one failure take both capabilities down, and would re-create #1761 (two dispatchers on one
queue) the moment either is re-installed.

## The measured state this removes

`pi-cell-3`, 2026-10-24T17:15Z — every surface green, no repair actuator at all:

```
$ systemctl is-active eldato-orchestrator          -> active
$ pgrep -f '[p]r-doctor.py' | wc -l                -> 0
$ tmux ls                                          -> no server running on /tmp/tmux-1000/default
$ tail -1 ~/.pi/agent/state/pr-doctor.log          -> 2026-10-22T21:54:33Z   (2 days stale)
```

That is the ALIVE / REFUSING / IDLE confusion of #2700 §1.2: the box was *dispatched at* and could not
*land*, and nothing said so. The repair loop was also coupled to a tmux server (#2558), which is the
class of lifetime #2402 removed for the controller and this unit removes for repair.

## What one pass does

1. **Measure the machine** — free MB on the *checkout's* filesystem (`df -Pm`), `nproc`, `load1`.
   The cap is derived, never a literal:

   | term | rule | why |
   |---|---|---|
   | cpu | `nproc / 2`, floored at 1, ceilinged by `REPAIR_MAX_WORKERS` (6) | a repair worker is a `pi` agent **plus** the suite it runs |
   | disk | `(free_mb - floor) / per_worker`, floor 4096 MB, 1024 MB per worker | a worker materialises a worktree **with its dependency tree** (#2721) |
   | load | the whole pass defers at `load1 >= nproc × 8` | the owner's 8–10× ceiling (`docs/ops/fleet-capacity.md`) |

   Measured: `pi-cell-3` (4 cores, 24 GB free) → **2** workers. `pi-cell-4` (8 cores, **3.4 GB** free,
   #2721) → **0** → `DEFERRED` (exit 6) with the number in the journal. That is the guard, not a
   comment: a repair loop on cell-4 is how the box wedged at 16:30Z on 2026-10-24.
2. **Reap** through the SHIPPED reaper (`pi-reap-worktrees.sh --apply`) — never a second worktree
   policy. Its `preserve … reason=…` / `REMOVED` rows are the evidence a decision was taken.
3. **Dispatch** through the SHIPPED classifier/dispatcher pair (`pr-doctor.py` →
   `objective.classify_one()`), with the target repo supplied as **inputs**:
   `PR_DOCTOR_REPO`, `PR_DOCTOR_REPO_DIR`, `OBJECTIVE_REPO`. ⛔ `pr-doctor.py` shipped the slug and
   `$HOME/Documents/GitHub/tortoise` as literals; on a cell that path does not exist, so every git read
   and worktree add failed and reported `UNREADABLE` — indistinguishable from an empty queue (#1974).
4. **Record** one status row (`$O/state/pr-repair.status.json`): the measurement, the cap, the
   **decision**, the reason and every step's rc. The vocabulary is exhaustive, and each value means one
   thing a reader can act on:

   | decision | meaning |
   |---|---|
   | `dispatched` | the dispatcher ran and returned 0 — work was placed, or the queue was genuinely empty |
   | `deferred` | the machine said not now; the reason carries the measurement (`disk-floor:3481<4096`, `load-ceiling:…`, `cap-zero`) |
   | `refusing` | a read a pass needs could not be taken, or the dispatcher itself refused (rc=2) — **never** "nothing to do" |
   | `placed-undelivered` | the work was placed and no worker took it (pr-doctor rc=3) |
   | `idle` | a `--dry-run` pass: measured and derived, dispatched nothing |
   | `skipped` | another pass held the lock, so this one attempted nothing. Written to its **own** file (`pr-repair.skip.json`) so a skipping process can never replace the lock holder's verdict; `--status` prints both |

## Credentials are sourced, not inherited (#1852)

⛔ The unit is started by **systemd**, and the fleet's credentials (`DEEPSEEK_API_KEY`, `GH_TOKEN`, the
`PATH` that carries `pi`) live in `keys.env` — sourced with `set -a` into the **tmux server**, which is
why every lane and every supervisor-spawned worker has them. A service has no tmux server, so the loop
sources `ENV_FILE` itself before its first pass. Without that, every worker spawns credential-less and
dies with `No API key found` while the pass records `dispatched` and the unit reads `active` — the
#2716 false PASS one level up, and the measured #1852 shape ("all three cells: every review and fixer
died").

The loop's own locals keep the **unit's** values (the target repo, the checkout, the state dir), and the
file's exports reach the children — a credential file may move a credential, never the thing the unit
said it repairs (#2700 §5: "the unit says N" is not "the running process uses N"). A *supplied* but
unreadable `ENV_FILE` REFUSES (exit 2); a manual run with no file simply inherits the operator's shell.

## The one directive that must never be dropped

```ini
KillMode=process
```

A pass **dispatches by backgrounding workers** (`nonblocking-dispatch.sh`) and returning at once. Under
systemd's default `KillMode=control-group`, the end of the pass tears down the cgroup and SIGTERMs the
workers it started seconds earlier. Measured on `pi-cell-4` 2026-10-24T15:19Z: two workers "launched,
running", both `.log` files **0 bytes**, no `.rc`, 290 MB of orphan worktrees — while `is-active` read
`active` and `dispatched=2`.

The installer asserts the property on the **rendered** artifact and refuses without it, and
`scripts/pr-repair-loop.test.sh` asserts it for **every** shipped unit whose `ExecStart` reaches the
dispatcher, so the next author inherits it instead of rediscovering it.

## Verbs

```bash
bash scripts/install-repair-service.sh --dry-run   # render + print, touch nothing
bash scripts/install-repair-service.sh --install   # install, enable --now, READ BACK
bash scripts/install-repair-service.sh --status    # is-active, is-enabled, ExecStart, KillMode, last pass
bash scripts/install-repair-service.sh --uninstall # stop, disable, remove, verify gone
```

`--install` verifies the farmed artifacts exist **before** the unit does, refuses when a
`pr-repair-loop.sh` from some other actor is already live on the box (two loops double-claim work), and
then reads the manager back: `is-active=active` **and** `is-enabled=enabled` **and**
`KillMode=process` **and** an `ExecStart` naming the farmed path. A mismatch is exit 1 with the observed
value — the installer's own success message is never the verdict.

⛔ The unit execs the **farmed** copy (`$CELL_HOME/.pi/agent/scripts/pr-repair-loop.sh`), never a lane
worktree (#2697: an `ExecStart` baked onto `/tmp/wt-2433-fu`, a lane's unmerged branch, which a reboot
erases) and never a checkout the reaper may reclaim. Both new scripts are declared in
`pi-bootstrap/setup.sh`'s `fleet_srcs`, which is what puts them there.

## What is NOT claimed here

- **No Mac activation.** A Mac's repair loop is a launchd job / `nohup` loop, and its blocker is TCC
  (#2709 §4), not a missing unit. The installer refuses Darwin rather than installing a unit that
  cannot supervise anything.
- **No parity readout.** Per-machine capability parity (one surface saying `ACTIVE | REFUSING(reason) |
  IDLE | NOT INSTALLED` for every capability) is #2709's own deliverable. This page documents one
  capability's activation, and the per-cell state is recorded on #2700.
- **`systemctl is-active` is a hint, not the proof.** The proof is the journal decision **and** a PR
  whose state changed because of that box (#2709 §1).
