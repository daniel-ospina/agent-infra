---
title: "Controller service — the cell's dispatcher, owned by a service manager (#2402)"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-10-23
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-2402, orchestrator-controller, systemd, cloud-cell
---

# Controller service (#2402)

The cell's orchestrator controller is started by `scripts/install-controller-service.sh`, which renders
and installs **`eldato-orchestrator.service`** — a systemd unit whose main process *is* the controller.

## Failure mode this exists for

The controller lived and died as a **tmux session**, and a tmux session has nothing above it: when the
box empties and the last session closes, the tmux server exits and no surface restarts the controller.
The cell then sits idle with no dispatcher and **reads as a healthy idle box**.

Measured 2026-10-23 on `cell-1`:

```
02:20Z  tmux ls                      → no server running on /tmp/tmux-1000/default
02:20Z  pgrep -fc "[o]rch-loop.sh"   → 0
02:02Z  [reap-lane-venvs.sh] capacity: lanes_live=0 … free_after=22069MB
```

Landings on that box had completed normally minutes earlier (`#9582` 01:56, `#9714` 02:10, `#9719`
02:16). Nothing crashed — which is exactly why nothing reported it. "Self-dispatches" is the whole
point of the controller, and a supervisor whose lifetime is coupled to the objects it supervises goes
quiet exactly when the box becomes free.

## What is installed

`scripts/install-controller-service.sh --install` renders
`templates/systemd/eldato-orchestrator.service` from machine state and converges it. The rendered unit
is not a launcher for a session:

| property | why |
|---|---|
| `ExecStart=/bin/bash <supervisor> start` + `Environment=ORCH_FOREGROUND=1` | `start` `exec`s `orch-loop.sh` **in the unit's own process**, so the unit's cgroup owns the controller's lifetime |
| `Restart=always` | the measured case is an **orderly exit 0**. `on-failure` reproduces the defect byte for byte |
| `RestartSec=15` | stated in the artifact, not inherited (`ORCH_RESTART_SEC` overrides; a whole number of seconds ≥ 1) |
| `After=network-online.target`, `Wants=` | the first cycle reads GitHub and the candidate board; started early it records "no work" and sleeps a whole `CYC` |
| `StartLimitIntervalSec=300` / `StartLimitBurst=3` | systemd's **default 10 s window can never fill** at one start per 15 s, so a configuration fault (no key, foreign controller, bad pin) would restart the box forever, re-running `cmd_check`'s network reads each time. 3-in-5-minutes converges to `failed`, which `--status` prints |
| `KillMode=mixed`, `TimeoutStopSec=30` | `orch-loop.sh` traps TERM and exits in ~0.1 s (#1715); the group is signalled after, so a stop leaves no half-spawned worker behind |
| `StandardOutput/Error=journal` | `journalctl -u eldato-orchestrator.service` is the controller's log in service mode |

## Install targets

Tried in order, and the reason is named in the output:

1. a **system** unit via passwordless sudo (`/etc/systemd/system`) — the cell's normal shape; the
   service runs as the invoking user, so the state dir, `keys.env` and `gh` auth are the operator's,
   not root's;
2. a **user** unit (`~/.config/systemd/user`) when systemd's user manager answers — plus a **linger**
   check, because a user manager that dies at the last logout is a supervisor that dies with the last
   lane: the same defect, one layer down;
3. nothing — a **loud failure** naming the missing service manager and the remedy, never a silent
   no-op. A controller that was "installed" but never supervised is a false pass.

**macOS is refused, not degraded.** A Mac's controller is already a launchd agent with `KeepAlive`
(`scripts/orchestrator-harness/install.sh` + `launchd.plist.template`); a second supervisor there would
be a second dispatcher on one queue.

## The cooperation contract (`cloud-cell-supervisor.sh`)

A service-managed controller must not fight its own verbs:

| verb | behaviour when a unit is **installed and enabled** |
|---|---|
| `start` | starts the **unit** and verifies a controller of *this state dir* appears; never creates a session. A tmux controller beside an enabled unit is **two dispatchers on one queue** (#1761) — a defect the fix for #2402 would otherwise introduce |
| `stop` | stops the **unit**. `Restart=always` re-creates the controller within `RestartSec` of any kill, so a pid-only stop would report "stopped" over a dispatcher that is back seconds later |
| `status` | prints a `supervision:` row — `ACTIVE`, `installed but NOT ACTIVE`, or `NONE` (naming the installer). A dead controller and an idle box print the same lines otherwise |

An installed but **disabled** unit falls through to the tmux path: "disabled" is an operator saying this
box is not service-managed.

## Verifying an install (what the issue asks an operator to run)

```
systemctl is-active eldato-orchestrator.service        # active
systemctl show -p MainPID eldato-orchestrator.service  # the controller, not a launcher
systemctl show -p NRestarts eldato-orchestrator.service# it came back on its own
journalctl -u eldato-orchestrator.service -n 40        # a fresh [dispatch] line with lanes=0 moving on
bash scripts/install-controller-service.sh --status    # unit + heartbeat freshness, with the verdict
```

`--status` is stricter than `is-active`: it also requires a **fresh heartbeat** (`$O/heartbeat`), because
a unit can be `active` while its controller died before taking the lock.

## Tests

`scripts/install-controller-service.test.sh` (in `scripts/run-bash-shards.sh`, so both CI lanes run it)
pins the artifact, the foreground `exec`, the three-verb cooperation, the installer refusals and
idempotency, and the restart policy **both directions** — a SIGKILL comes back, an orderly exit 0 comes
back — plus the negative control that the *same* exit-0 controller is **not** restarted under
`on-failure`. The pre-fix supervisor turns §B–§E red (`SUP=<a pre-#2402 supervisor> bash …`), so the
suite is not vacuous.
