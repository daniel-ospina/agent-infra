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
unit whose main process *is* the cell's repair loop (`scripts/pr-repair-loop.sh --loop`, or
`--trigger` for the event-driven front end — see **The clock** below). It exists
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
   ⛔ AND THE PAIR IS EVIDENCE, NOT A FALLBACK: `pr-doctor.py` no longer carries those literals at all,
   so it refuses (exit 2) when nothing names a repo — and an unset pair is a launcher bug this loop
   surfaces rather than a default it quietly adopts (#2716 reconciled with #2235).
4. **Record** one status row (`$O/state/pr-repair.status.json`): the measurement, the cap, the
   **decision**, the reason and every step's rc. The vocabulary is exhaustive, and each value means one
   thing a reader can act on:

   | decision | meaning |
   |---|---|
   | `dispatched` | the dispatcher ran and returned 0 — work was placed, or the queue was genuinely empty |
   | `deferred` | the machine said not now; the reason carries the measurement (`disk-floor:3481<4096`, `load-ceiling:…`, `cap-zero`) |
   | `refusing` | a read a pass needs could not be taken, or the dispatcher itself refused (rc=2) — **never** "nothing to do" |
   | `placed-undelivered` | legible work, **none of it out** (pr-doctor rc=3): no worker took an order that was placed, **or** a durable refusal stopped the order before delivery (`agent-infra#2710` — a dirty worktree, a queue parked under the 45-min cooldown the refusal created; measured for #2708). The pass exits **3** too, so a monitor keyed on the exit code cannot read green over work nobody accepted. ⚠️ The `reason` token on this row is still `no-worker-took-it` for both causes; the human line on stderr names both, and renaming the token is left to a change that can verify every reader |
   | `idle` | a `--dry-run` pass: measured and derived, dispatched nothing |
   | `skipped` | another pass held the lock, so this one attempted nothing. Written to its **own** file (`pr-repair.skip.json`) so a skipping process can never replace the lock holder's verdict; `--status` prints both |
   | `pass-failed` | the dispatcher did **not return a verdict**: it CRASHED (`pr-doctor` rc=4 — an uncaught exception), timed out (`timeout` gives 124) or died on a signal (128+n). The pass exits **4**, which is **not** a verdict, so it does **not** consume the backstop window and a later tick retries instead of waiting half an hour on a crash. ⛔ **Never a `refusing` row**: before `ai#2922` this reached the catch-all, so a crash and a genuine refusal produced a byte-identical `decision`/`reason`/exit code and an operator was sent to look for a broken read while the dispatcher was dead. Reason token is `dispatcher-crashed`; a genuine refusal (rc=2) keeps its own row via its own explicit arm. ⚠️ **An unreadable cwd is NOT a cause of this row any more** — it was the one #2922 was measured on, but `pr-doctor` now SKIPS an unreadable cwd as a candidate and refuses with `EXIT_REFUSING` when nothing else names the repo (`scripts/pr-doctor.py`'s `_safe_cwd`), so that cause lands in the `refusing` row above |

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

## The clock: `--loop` (a timer) or `--trigger` (the event-driven front end, #2700 C5)

The unit's main process is `pr-repair-loop.sh` in one of two MODES. `REPAIR_MODE` chooses, and it is
rendered into `ExecStart` — there is no second unit and no second installer, because a second actuator
on the same queue is #1761 one capability over.

| | `REPAIR_MODE=loop` (default) | `REPAIR_MODE=trigger` |
|---|---|---|
| `ExecStart` | `pr-repair-loop.sh --loop` | `pr-repair-loop.sh --trigger` |
| when a pass runs | every `REPAIR_INTERVAL_S` (default 900) | when the PR surface MOVES, plus a backstop |
| the lead for a freshly-red PR | up to one full interval (mean 450 s at 900) | one poll + the debounce (default 60 + 90) |

`--trigger` **execs** `pr-doctor-trigger.py`, and the trigger's child is **this same loop's one-pass
mode**. So the cap, the disk floor, the load ceiling, the reap, the `keys.env` credential source and
the status row still decide every pass: the front end chooses *when*, never *what*.

⚠️ **Measured on the Mac before this existed:** `com.tortoise.pr-doctor` ran `StartInterval 1800` — a
mean **900 s** and a worst case **1800 s** of dead time for a repair whose own cost is one pass. With
`--poll 60 --debounce 90` the measured lead is **150 s**, and the timer survives only as
`REPAIR_TRIGGER_BACKSTOP_S` (default 1800) for the work only a clock can see: a check that never
reports, a worker that dies silently, a stale claim.

Knobs (rendered as `Environment=`, all optional): `REPAIR_TRIGGER_POLL_S` (60), `REPAIR_TRIGGER_DEBOUNCE_S`
(90), `REPAIR_TRIGGER_BACKSTOP_S` (1800), `REPAIR_TRIGGER_RETRY_MIN_S` (300 — the floor between
retries of a FAILED pass, so a box that cannot deliver does not re-read the whole PR surface every
poll).

⛔ **The pass's exit codes are the trigger's vocabulary**, and they are not interchangeable: `0` (a pass
completed) and `2` (REFUSING — a read it needed could not be taken) and `6` (DEFERRED — the machine
said not now: below the disk floor, above the load ceiling, or a cap of 0) are **verdicts** and consume
the backstop window; `3` (UNDELIVERED) is retried under `REPAIR_TRIGGER_RETRY_MIN_S`; anything else is
`PASS-FAILED`, which does **not** consume the window so a later tick retries instead of waiting half an
hour on a crash. A trigger whose pass is absent (`PASS-MISSING`) is never a clean window — CPython
exits 2 for "can't open file", and 2 is a verdict.

## Verbs

```bash
bash scripts/install-repair-service.sh --dry-run   # render + print, touch nothing
bash scripts/install-repair-service.sh --install   # install, enable --now, READ BACK
bash scripts/install-repair-service.sh --status    # is-active, is-enabled, ExecStart, KillMode, last pass
bash scripts/install-repair-service.sh --uninstall # stop, disable, remove, verify gone
```

`--install` verifies the farmed artifacts exist **before** the unit does, refuses an `ExecStart` under
a **lane scratch checkout** (`.worktrees/…`, `/tmp/wt-*` — the #2697 shape: the unit dies when that lane
is reaped, and a read-back cannot see it because the comparison is against the same variable that
rendered it), refuses a **user-scope install without linger** (a unit that dies with the last login is
not activation), refuses when a
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
