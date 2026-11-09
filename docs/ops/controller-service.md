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
The cloud-cell bring-up **runs that installer and reads it back** (`scripts/cloud-cell-bringup.sh` →
`check_controller_service`), so a Linux cell is not certified `CELL READY` with nothing above its
controller.

⛔ **macOS is not verified there, and this page must not claim it is** (review P1, #2402). The bring-up
**warns** and returns success: *"controller supervision on macOS is NOT VERIFIED by this check — the launchd
agent (com.eldato.orchestrator-loop) is out of scope here and nothing in this run read launchctl"*. That is
deliberate — a `launchctl` probe would refuse a healthy Mac whenever the read is unavailable — but it means
the Mac's supervision is an **unmeasured** surface, not a checked one: verify it by hand with
`launchctl print gui/$UID/com.eldato.orchestrator-loop`. The gap is named here rather than hidden behind the
banner.

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
| `After=network-online.target`, `Wants=` | the first cycle reads GitHub and the candidate board, and `start` runs those reads as a **pre-flight** — offline, `cmd_check` fails and `start` exits non-zero before the loop runs. ⛔ **This ordering binds in the SYSTEM scope only**: `network-online.target` exists in the system manager (`/usr/lib/systemd/system/`) and NOT in a per-user manager, so a user-scope unit's dependency is dropped by systemd. Both scopes render the lines (one owner for the property) and the installer **says so** on a user-scope install: there, a boot without network can spend the three attempts and converge to `failed` |
| `StartLimitIntervalSec=300` / `StartLimitBurst=3` | systemd's **default 10 s window can never fill** at one start per 15 s, so a configuration fault (no key, foreign controller, bad pin) would restart the box forever, re-running `cmd_check`'s network reads each time. Three failures inside five minutes converge to `failed`, which `--status` prints — and that only holds while the failures **fit** the window: `StartLimitBurst × (CONTROLLER_ORPHAN_TIMEOUT + RestartSec) < StartLimitIntervalSec`. ⛔ **The installer also reserves slack**, so the orphan ceiling it accepts is `(interval−1)/burst − RestartSec − 5 − 5` = **74 s** at these defaults, not the 84 s the plain relation suggests (the 5 s poll quantum is a reserve even though `foreground_handover` tests the NEXT step and so does not overrun its bound; the second 5 s covers the supervisor's own startup). ⛔ **AND THE RELATION IS NOT THE WHOLE STORY** (review P1 round 17, #2402): a *configuration* fault does not wait on the orphan ceiling — it dies in `cmd_check`/`harness_apply`, whose cost is **not bounded by this window at all** (no `timeout` wraps the pre-flight, and a hung `gh`/`git` can outrun it), so a slow-enough pre-flight makes the burst never fill while `--status` reads supervised. The window is necessary, not sufficient; bounding that phase is filed separately rather than half-fixed here |
| `KillMode=process`, `TimeoutStopSec=30` | `orch-loop.sh` traps TERM and exits in ~0.1 s (#1715), so the controller stops on its own. **Not `mixed`**: with no tmux server running (the measured #2402 shape) the doctor's session forks the *server* inside this unit's cgroup, and `mixed` would SIGKILL every session on that per-user server — peer repos' controllers and operators' shells included — before `stop`'s ownership proof could run |
| `TimeoutStartSec=60`, `Environment=CONTROLLER_ORPHAN_TIMEOUT=60` | `ExecStart` runs the **whole** of `start`, and service mode **waits** for a controller that is already running. The bound is the process's, **not** `TimeoutStartSec`'s: this unit is `Type=simple`, whose start job completes the moment the main process is forked (`systemd.service(5)`), so that directive cannot bound the wait — an earlier revision claimed it did and the real bound was the supervisor's 3600 s default, with the unit reading `active (running)` throughout. `CONTROLLER_ORPHAN_TIMEOUT` is the wait for a session that outlived its loop; an orphan never exits, so this start can never succeed. It must therefore be short enough that `StartLimitBurst` of those attempts **fit inside** `StartLimitIntervalSec` — `3 × (60 + 15) = 225 s < 300 s` — because systemd refuses the start **after** the burst is exceeded: at the old 120 s default the three failures spanned 405 s, the oldest start aged out of the window before the fourth was refused, and the unit restarted forever while every surface read supervised (`ORCH_START_TIMEOUT_SEC` overrides both; the installer refuses any value that does not fit the arithmetic) |
| `Environment=CONTROLLER_HANDOVER_TIMEOUT=3600` | the wait for a controller this state dir **owns** and that is still running — the **migration** case, where the box being upgraded is landing PRs right now. Long on purpose: a short bound would fail the upgrade instead of adopting the running controller (`ORCH_HANDOVER_TIMEOUT_SEC` overrides; a whole number ≥ 1) |
| `StandardOutput/Error=journal` | `journalctl -u eldato-orchestrator.service` is the controller's log in service mode |
| `Environment=ORCH_SUPERVISOR_PIN=<repo>@<sha>` | which revision the unit **boots**, rendered at install time (#2697). `merged ≠ running` was silent: a farmed copy can be days behind `main` and nothing on the box recorded it, so "which code is this cell executing" was answered by `git -C` guesses at a path the unit merely names. Read it from `systemctl show eldato-orchestrator -p Environment`, or from `--status`'s `supervisor_pin=` row. A supervisor outside any git work tree (a farmed copy) records `unknown@unknown` — this is an observation, never a gate. ⛔ **A hand-edited work tree records `<repo>@<sha>+dirty`**, and a `git status` that cannot be read records `unknown@unknown`: `HEAD` names the commit, never the bytes, so an unqualified `<sha>` for a locally-modified supervisor is a confident wrong answer to "which code is this unit executing" (the same rule the supervisor's own provenance stamp follows — *its commit does not describe its bytes*). ⛔ **It is what the NEXT start executes, not a claim about a live process**: `--install` re-renders the unit but deliberately does not restart a healthy controller, so after a checkout advances the two differ until the unit restarts |

⛔ **The `ExecStart` PATH MUST OUTLIVE THE SHELL THAT RENDERED IT** (#2697). "The file exists at
render time" is not a property systemd can rely on at boot. Measured on cell-1:
`ExecStart=/bin/bash /tmp/wt-2433-fu/scripts/cloud-cell-supervisor.sh start` — a **lane worktree** at an
unmerged branch — so once that path goes the unit's `ExecStart` cannot resolve; `Restart=always` burns the
unit's start limit (**3 attempts inside 300 s**), systemd converges it to `failed` in well under a minute,
and **nothing pages** — every surface that asks reads a dead unit, not a retrying one. `/tmp` is not its own
mount on these cells, so the mechanism is `systemd-tmpfiles --clean` once the entry ages out of the window
the box's own `tmpfiles.d` sets (`D /tmp … 30d` on this fleet's Ubuntu/systemd-255 image, `10d` on some
others), not a reboot: the box looks healthy for a while and then goes silently dead.

So the installer **refuses to render** a supervisor that resolves into a lane worktree, or under a
temporary root that no deployment root on this box declares. The roots it accepts under a temporary root
are the cell's own home (`CELL_HOME`), the operator's `HOME`, and `$AGENT_INFRA_PATH` — because **the
cells keep their home under `/tmp`** (`/tmp/cell-home`) and their harness pin under it too
(`/tmp/cell-home/harness/<sha>/scripts/…`, the shape cell-3 measured as correct), so "under `/tmp`"
alone cannot be the rule without blocking every cell bring-up. The refusal names the durable
alternatives (`$AGENT_INFRA_PATH/scripts/…`, the harness pin, and `$HOME/.pi/agent/scripts/…`) and writes
**nothing** — the preview verb refuses too. ⛔ **The farmed path IS delivered by this landing (#1938)**:
`cloud-cell-supervisor.sh` is farmed FLAT by `setup.sh`'s `fleet_srcs`, so `bash pi-bootstrap/setup.sh`
DOES create `$HOME/.pi/agent/scripts/cloud-cell-supervisor.sh` and the refusal names it as a durable
alternative. ⚠️ A box installed by an OLDER `setup.sh` may still lack it — re-run the installer rather
than copying from a clone. (This paragraph said the opposite until the entry landed; kept as a record
because the refusal text is what an operator acts on.)

⛔ **"Lane worktree" is decided by GIT — and by the BRANCH, not by being a worktree.** A name list cannot
be the guard (the measured shape was `/tmp/wt-2433-fu`; the next lane picks the next name, and a copy
nested one directory deeper matches no pattern). In a **linked** worktree `git rev-parse
--absolute-git-dir` answers `<main>/.git/worktrees/<name>` while `--git-common-dir` still answers
`<main>/.git`; in the **main** clone the two are the same directory. ⛔ Those questions (and the pin's) are
asked with `GIT_DIR`, `GIT_WORK_TREE`, `GIT_COMMON_DIR` and `GIT_INDEX_FILE` **scrubbed**, because an exported
`GIT_DIR` at the hub makes both answers the hub's and reads a linked worktree as primary — measured, and
§P7 arms it.

⛔ **NOT EVERY LINKED WORKTREE IS A LANE'S — the cell's harness pin is one too.** The bring-up creates the
pin with `git worktree add --detach <pin>/<sha> <sha>`, so a rule that refused every linked worktree
refused the very shape this document calls correct, and the alternative its own refusal message
recommends: a loop for an operator with no farm. What makes the #2697 shape wrong is a worktree checked
out **on a branch** — unmerged code a lane removes when it lands — and git answers that directly
(`symbolic-ref -q HEAD` succeeds on a branch, fails on a detached HEAD). So a linked worktree **on a
branch** is refused wherever it lives (`/tmp/wt-x`, `$HOME/wt-x`, `<repo>/.worktrees/x`); a **detached**
one is admitted ONLY when it is the pin TREE this box records — the path in `$CELL_HOME/.harness-path`
(override: `HARNESS_PIN_FILE`), or, when no record exists yet, under the bring-up's pin root
`$CELL_HOME/harness` (override: `HARNESS_PIN_DIR`) — because detached is also the shape the fleet's
**drainer** gives a lane's
scratch checkout (`ai-drainer.sh`: `git worktree add -f "$AI/wt-drainer-<name>" "$SEED_REF"`, removed with
`worktree remove --force` when the lane ends), and that one lives under `$HOME`; **every** other detached
worktree is refused. The pin tree corroborates itself: its directory basename must be a prefix of the
commit it actually holds, so a scratch named with an unrelated commit id is refused. A **primary clone**
under a transient root is admitted only when it is checked out on its **default** branch: a clone on any
other branch is unmerged work a lane removes, so a lane that isolates by cloning instead of
`git worktree add` is refused exactly like a linked worktree on a branch, while `/tmp/cell-ai` on `main`
keeps installing. ⛔ **That branch question is asked for a clone under a TRANSIENT root only** — the walk
returns "durable" for a path outside every temporary root before any clone rule is consulted (linked
worktrees are the shape refused *wherever* they live). So a **primary** clone under a durable root (say
`~/agent-infra`) on a lane branch is **admitted**, and the pin records which revision the unit then runs. That
is a stated limit, not coverage: the fleet's clones live under `/tmp` (`/tmp/cell-ai`) or under their owning
lane's checkout, which is the transient shape this rule does cover.

**And a DETACHED primary clone is graded, not waved through.** A detached HEAD has no branch name to grade,
so the helper used to read it as "nothing to be unmerged at" and admit it — which armed a unit at a clone a
lane detaches at a PR head (`git clone … && git checkout <pr-head>`) and then removes, i.e. the #2697 class
in a checkout that had no name. The question available without a name is containment: a detached clone is
admitted when its HEAD is contained in the clone's default ref (`git merge-base --is-ancestor HEAD
refs/remotes/origin/<default>` — the clone is pinned at the revision its own deployment carries) and
refused when it is not. The fleet's only legitimately detached checkout is the harness **pin**, which the
bring-up creates with `git worktree add --detach` and which the linked-worktree rule grades before this one
is consulted, so no deployment shape is lost. `merge-base --is-ancestor` is **tri-state** — 0 yes, 1 no,
128 git could not answer — and a read that cannot be made is reported as CANNOT PROVE and refused, never
folded into a confident "not contained". The graded ref is the **local** `refs/remotes/origin/HEAD` symref,
which `git clone` derives from the remote and a caller can rewrite: this guard is an **accident guard**
(`#2697` was an install from a lane worktree with nothing exported), not a boundary against a caller who
rewrites its own refs.

**Named residual (detached clone, no default ref):** when the clone carries no default ref to compare
against (a fixture clone with no `origin`), containment cannot be asked, so a detached clone is admitted.
There is no evidence to refuse on, and fabricating a refusal would false-block a clone that is in fact
pinned at its own deployment's revision; the residual is stated rather than papered over.

**Named residual:** the pin has three locators — `HARNESS_PIN_DIR`, `HARNESS_PIN_FILE`, and the record
itself (`$CELL_HOME/.harness-path`) — and all three are how a real box relocates its pin, so a caller that
deliberately declares a scratch as its own pin root (or writes a record naming one) can still arm it. This
is an **accident guard** (`#2697` was an install from a lane worktree with nothing exported), not a
boundary against an operator who declares the scratch deliberately, who can write the unit anyway. The
record is box state, not a credential. A **primary** clone under `/tmp` (`/tmp/cell-ai`, the cells' own checkout) is
untouched; and **no declaration launders a lane checkout**: a caller that names its own worktree as
`AGENT_INFRA_PATH` does not get to admit it. When git cannot identify the checkout at all (a `.git` entry
it refuses to read — dubious ownership, an unreadable directory), the answer is **cannot prove**, and it
is refused rather than admitted. Every git read scrubs an ambient `GIT_DIR`/`GIT_WORK_TREE`/`GIT_COMMON_DIR`
first, because one exported variable otherwise makes a branch worktree answer as a main clone.

The fleet's scratch shapes (`*/.worktrees/*`, `/tmp/wt-*`, `/tmp/cell-wt-*`, `/tmp/base-*`) are refused
by name as well — a deliberate **coarse pre-filter** that runs before the git test, so it also refuses a
detached pin under `.worktrees/` (and says which shape matched). That list is the **same** list
`scripts/install-repair-service.sh` uses — the suite extracts both `case` statements and compares them, so
a second hand-kept copy cannot drift.

Two callers, two strengths, one owner of the rule:

| seam | when the named path is not durable |
|---|---|
| `ORCH_SUPERVISOR` (an operator's requirement) | **refused** — never silently swapped for something else |
| `ORCH_SUPERVISOR_PREFER` (a caller's preference: `cloud-cell-bringup.sh` names the layer checkout it just installed, so the unit runs the layer's code rather than a possibly-stale farm) | **skipped, loudly**, and the next durable candidate is used; refused only when no durable candidate exists |

Without the preference strength the bring-up would refuse on a lane layer — `self_root` is the lane's own
checkout whenever a lane runs it — which is a real shape, and the reason the strength exists. The
preference is a bodyguard, not a hole: a lane's **linked** worktree is refused by the git rule above
before the preference is consulted, so what the bring-up loses is only the unmerged-code ExecStart it
must not arm, and it falls through to the **harness pin** (`$CELL_HOME/harness/<pin-sha>`, the box's own
pinned revision — `check_harness_pin` runs before `check_controller_service`, so it exists by then) and
then to the farm. ⛔ The pin is graded at preference strength and is tried **before** the two farm paths
because a pin is this cell's revision where the farm is a possibly-stale copy. `cloud-cell-supervisor.sh`
itself IS farmed flat as of this landing (#1938), so on a fresh provisioned cell BOTH the pin and the farm can
deliver it; the pin still wins, because a copy the cell chose beats a copy the installer last happened to
write. ⚠️ On a box whose installer predates that entry the farm copy is absent and the pin remains the
only durable candidate — which is why the pin is content-checked rather than assumed.

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

**A root run is refused, not degraded — `sudo bash …` and every other spelling.** Run the installer as
the operator, not as root: the rendered unit takes `User=`, `HOME=`, `CELL_HOME=` and `O=` from the
invoking shell, so an elevated run would install a root-owned controller with root's `keys.env` and `gh`
auth — and, because it is enabled, `start` would delegate to it and the cell's own controller could never
come up. The refusal is on the **uid**, not on `SUDO_USER`: `su -`, a direct root login and a root-run
provision are refused too (an earlier guard tested `uid 0 AND SUDO_USER`, so it admitted exactly those).
`SUDO_USER` only selects the remedy sentence. A root-owned controller must be asked for explicitly with
`CONTROLLER_ALLOW_ROOT=1` — that is the ONLY way through, on any scope, including the `SYSTEMD_UNIT_DIR`
override (the test/operator seam names a directory, not an identity, and it does **not** exempt a root run;
the hermetic suite installs as any uid by exporting the same `CONTROLLER_ALLOW_ROOT=1` an operator would).

## The cooperation contract (`cloud-cell-supervisor.sh`)

A service-managed controller must not fight its own verbs:

| verb | behaviour when a unit is **installed and enabled** |
|---|---|
| `start` | starts the **unit** and verifies a controller of *this state dir* appears; never creates a session. A tmux controller beside an enabled unit is **two dispatchers on one queue** (#1761) — a defect the fix for #2402 would otherwise introduce |
| `stop` | stops the **unit**. `Restart=always` re-creates the controller within `RestartSec` of any kill, so a pid-only stop would report "stopped" over a dispatcher that is back seconds later |
| `status` | prints a `supervision:` row — `ACTIVE`, `installed but NOT ACTIVE`, or `NONE` (naming the installer). A dead controller and an idle box print the same lines otherwise |

An installed but **disabled** unit falls through to the tmux path: "disabled" is an operator saying this
box is not service-managed.

**Who may re-arm a stopped or failed unit is part of the contract.** A deliberate
`systemctl stop eldato-orchestrator.service` (or `--uninstall`'s `disable --now`) does not remove
`.desired`, so the cell's doctor loop still reaches its "controller absent → restart" arm on its next pass.
That restart is an **automated** one (`ORCH_AUTOMATED_RESTART=1`), and it does **not** re-arm a unit the
service manager reports not active: doing so would (a) undo the operator's stop, leaving the manager
reporting `inactive` over a live dispatcher — the "reported stopped, still running" shape this whole file
removes — and (b) clear the start-limit counter that is supposed to converge a configuration fault to
`failed`, so a keyless cell would retry forever with every surface reading supervised. A human
`cloud-cell-supervisor.sh start` **is** asking for exactly one more attempt: it clears the counter and
starts the unit. Only another unit name can be installed beside another state dir's copy — `--install`
**refuses** to overwrite a unit that provably supervises a different state dir, naming that dir. Installing
beside it needs BOTH the override and a template **of that name** (`CONTROLLER_UNIT` is the template's file
name too, so the override alone refuses with `template missing`): `CONTROLLER_UNIT=eldato-orchestrator-<cell>.service`
with a matching template in `TEMPLATES_DIR`. Discovery is keyed on the unit NAME (see #2602), so a copy
installed under such an override is not yet seen by the default name's `--status`/`--uninstall`/install guard
— retire the other copy deliberately instead of relying on a second name.

**A unit belongs to ONE state dir, and the verbs read that rather than assume it.** The unit name is
machine-scoped, so "the first unit file on the box" can be another cell's. Every unit this installer
renders carries `Environment=O=<state dir>`, and `start` / `stop` / `status` resolve the copy that declares
**this** `O` — preferring the one that is enabled or active when two of them exist. A copy that declares
another state dir is reported and **never stopped on this cell's behalf**; `status` names it and the state
dir it belongs to. A unit with no `Environment=O=` line (hand-written) is *unprovable*: it is still
addressed — treating it as foreign would launch a session beside the very unit that may be enabled
(#1761) — and `status` says the ownership is UNKNOWN rather than guessing.

The installer's install verdict rests on **two** witnesses and both must be able to fire: a heartbeat
written after this start, and the harness's own single-instance lock (`$O/.orch.lock`) held by a live
`<shell> …/orch-loop.sh`. The lock witness matches the argv **shape**, not a path prefix, because the
controller a cell runs execs `$HARNESS/orch-loop.sh` — measured on `pi-cell-2` (#2402).

## Verifying an install (what the issue asks an operator to run)

`--status` resolves the **installed** copy first, so it is correct in both scopes — use it as the verdict.
The systemd commands below are shown for the default **system** scope; on a box that installed the
**user** unit, add `--user` to each (`systemctl --user …`, `journalctl --user -u …`):

```
bash scripts/install-controller-service.sh --status    # the verdict: scope, enabled, active, pid, restarts, heartbeat

systemctl is-active eldato-orchestrator.service        # active
systemctl show -p MainPID eldato-orchestrator.service  # the unit's MAIN PROCESS: the launcher until it execs the controller — pair it with --status
systemctl show -p NRestarts eldato-orchestrator.service # it came back on its own
journalctl -u eldato-orchestrator.service -n 40        # a fresh [dispatch] line with lanes=0 moving on
```

`--status` is stricter than `is-active` in the direction that matters: it requires **both** that the unit
is active/enabled **and** that a controller `MainPID` exists, and it reports an **unreadable** state as
UNKNOWN rather than as `not active` / `nothing will restart it`. When `$O/heartbeat` is present it also
reports its age and refuses a stale one (a unit can be `active` while its controller died before taking
the lock); a missing heartbeat is tolerated only while a `MainPID` exists, because the first cycle writes
the file after one `CYC` and a `keys.env` `O=` line can move the controller's state dir.

**`MainPID` is not the same claim as "a controller is running".** Under `Type=simple` the unit's main
process is the launcher (`… start`), which runs `harness_apply`/`cmd_check` — and waits out a handover —
before it `exec`s the loop. So `--status` prints a separate `controller=` row built from the same witness
`--install` requires (the lock's owner, age-bound, or a heartbeat newer than two cycles). It is reported,
not gated: a start still inside its first `CYC` legitimately has neither, and refusing that would be a
false red on every healthy start. The stale-heartbeat bound above is what refuses a dead controller, so
the residual ambiguity is one heartbeat window (900 s), stated rather than hidden.

The unit name is **machine-scoped** (`eldato-orchestrator.service`), so on a box with more than one state
dir the installer reads each copy's **owner**, which that copy carries TWICE: the `Environment=O=` line it
**renders** (which `--install` pins to the installing state dir) and what it **resolves** to, because the
controller re-sources `Environment=ENV_FILE=` and a `keys.env` `O=` line can move its state dir. A copy is
this state dir's when **either** read matches — the two disagree in both directions, and reading only one
turned a healthy cell's own unit into `other_unit=` — and a copy that provably matches **neither** is
reported as `other_unit=` and is **never** disabled, removed, or answered for. A copy with no `O=` line and
no readable env file (hand-written, or pre-#2402) counts as ours — the fail-safe side of #1761, where the
danger is a tmux controller launched beside a unit that may be enabled.

**Those verbs never execute `keys.env` with root's authority.** Resolving the owner means *sourcing* that
file, and the file belongs to the operator, while `sudo bash … --status` is a documented invocation — so
when the installer runs as root it evaluates the file as the account that can actually **write** it, which is
the file's **owner** (`runuser -u <owner>`); `SUDO_USER` is only the non-root stand-in for the one case
ownership cannot answer — the owner **is root**, and root can write anything, so "owned by root" says nothing
about who could have written it. It refuses to evaluate the file at all — falling back to the rendered `O=`,
which is cleartext in the unit — in three cases: no `runuser`; a file it cannot read, or whose owner it
cannot name; and a file **any account but its owner can write** (the shape `sudo tee` leaves behind with a
shared group; the mode check rejects group/other *write*, so a `0644` file owned by another account is fine
only because it then runs as *that* owner, never as the caller). The fallback costs nothing for ownership,
because ownership is the union above.

## Tests

`scripts/install-controller-service.test.sh` (in `scripts/run-bash-shards.sh`, so both CI lanes run it)
pins the artifact, the foreground `exec`, the three-verb cooperation, the installer refusals and
idempotency, and the restart policy **both directions** — a SIGKILL comes back, an orderly exit 0 comes
back — plus the negative control that the *same* exit-0 controller is **not** restarted under
`on-failure`. The pre-fix supervisor turns §B–§E red (`SUP=<a pre-#2402 supervisor> bash …`), so the
suite is not vacuous.
