#!/usr/bin/env python3
"""runner_autoscale.py — make self-hosted CI runner capacity CORRECT and AUTOMATIC on one box.

WHY THIS EXISTS (measured 2026-10-22, 19:55Z–20:30Z)
  Every runner in the `daniel-ospina/tortoise` pool was added by an ad-hoc lane
  (`runnercap2/3/4/5`, `runnerrecon`). Nothing watched capacity and nothing healed a dead
  runner, so the pool was whatever the last brief happened to ask for: cell-4 at 1 runner
  against a target of 3, listeners that die and reconnect forever, and no guard at all between
  "an 8-core box" and "how many shards it can actually hold". This file is the missing half: a
  per-box predicate that (a) DERIVES the ceiling from cores and MEASURED free memory,
  (b) converges the box to it, and (c) REFUSES to exceed it, printing the reading it used.

THE AUTHORITY IT ENCODES — owner ruling, agent-infra#2344 comment 6347825624
  "take the direction of option 3 — fill every machine to the capacity it can actually
   sustain, so merging is not the scarce resource" … "the sustainable counts are 3 on cell-1,
   3 on cell-4, 2 on cell-3" … "The runner build must refuse to add a runner when free memory
   is below a stated floor, and must report the reading it used — 'manage capacity well' has
   to be a predicate the machine evaluates, not a wish in a brief."

  ⛔ CONTRADICTION TEST. `scripts/ci_runner_gate.sh:12` records a deliberate ruling that this
  box's hardware serves CI as a FALLBACK only, because jobs here compete with the agent fleet.
  That ruling is **REOPENED by the owner** in the comment quoted above — the ruling itself says
  capacity is now a goal in its own right. So this file adds capacity openly instead of dressing
  it up as a fallback. It does NOT reverse the parts the owner did not reopen: the fallback
  LABEL stays gate-following (see `resolve_labels`), and nothing here relabels, removes, or
  re-ranks an existing runner.

  ⛔ AND "GATE-FOLLOWING" IS ENFORCED, NOT ASSERTED (review finding P1). The label floor used to be
  "does ANY runner carry `ubuntu-latest`", which is TRUE in the gate's NORMAL state — the gate
  STRIPS the label whenever GitHub-hosted is healthy (`ci_runner_gate.sh:290` `fallback_off`, called
  at `:381`), so "missing" is what a healthy box looks like. A registration that armed it there
  re-opened the incident that gate exists for (jobs landing here compete with the agent fleet; its
  own header records a local pytest run that crashed FalkorDB, 178 restarts), and the two timers then
  fought forever: the gate stripping what every repair re-added, one transition notification per
  cycle. So the floor now asks the question the paragraph above promises — does the GATE want the
  fallback, and is it missing — by reading the gate's own recorded mode (`gate_desired_mode`). With
  no such record this tool does not invent the gate's intent.

THE CEILING IS A PREDICATE, NOT A NUMBER
    ceiling = min(core_ceiling, runners_live + headroom_by_memory)

  core_ceiling — the owner's table, from CORES (never a flat 3–5):
      >= 8 cores -> 3      4..7 cores -> 2      1..3 cores -> 1
  headroom_by_memory = max(0, (mem_available_mb - MEM_RESERVE_MB) // MEM_PER_RUNNER_MB)
  and `runners_live` is how many LISTENERS are actually alive on this box (a measured process
  count, not an install count): `MemAvailable` has already paid for their memory, so the memory
  arm must be additive over them — otherwise the ceiling would shrink as runners come up, and a
  healthy box at its target would read "over ceiling".

  Measured per-shard cost (3 live shards, whole `Runner.Worker` tree, 2026-10-22):
  1431 / 1378 / 870 MB + a 2-container FalkorDB sidecar pair at 55–140 MB ⇒ 1–1.5 GB, so
  MEM_PER_RUNNER_MB=1500 and MEM_RESERVE_MB=2048. Sanity check against the owner's own readings:
  cell-3 4 cores / 5.9 GB → min(2, 2+2)=2 ✓ (the ruling's 2); cell-4 8 cores / 7.5 GB with 1
  live → min(3, 1+3)=3 ✓ (the ruling's 3); a box at 3 live with 5.5 GB free → min(3, 3+2)=3, so
  a fourth is refused by CORES with the reading printed (this is the live case measured below).

WHAT IT DOES, IN ORDER (every step idempotent; safe to run every few minutes)
  1. MEASURE   cores, MemAvailable. Unreadable ⇒ exit 2 and NO action — "cannot verify" is
               never a pass and never a guess.
  2. DISCOVER  local runner installs (`<root>/gh-runner*` holding a `.runner` config) and their
               agent names: the box's own inventory, attributable to a name and a repo.
  3. READ      the repo's pool (`gh api …/actions/runners`): name, status, busy, labels.
  4. CLASSIFY  each local install — the ORDER of these checks is the safety property
               OTHER-REPO  its `.runner` names a DIFFERENT repo. Checked FIRST: this repo's pool
                         cannot see that registration at all, so the absence below would
                         otherwise read as ORPHANED and re-register it HERE with `--replace`,
                         deleting another repo's registration and cancelling its job. Reported,
                         never touched.
               BUSY      in the pool and busy, OR a live `Runner.Worker` in its tree (checked
                         before the pool read, so a runner the pool does not list is still
                         recognised as working)
               SERVING   in the pool, online, not busy
               DEAD      in the pool, offline
               ORPHANED  in this repo's pool nowhere at all, and provably this repo's — a
                         listener whose registration is gone; it reconnects forever, takes no
                         work, and holds memory
  5. REPAIR    DEAD → restart its service unit, then WAIT for the pool to report it online; only
               if it is demonstrably still offline is it re-registered (`--replace`), and an
               UNREADABLE pool is never treated as offline. ORPHANED → re-register under its own
               name with `--replace` (adopts the stale registration; never a duplicate), keeping
               the labels it already carries. A BUSY, SERVING or OTHER-REPO runner is never
               restarted, relabelled or removed.
  6. FILL      while live < target: add ONE runner, printing `mem_available_mb` before and after,
               and stop if the next addition would leave < MEM_RESERVE_MB. A NEW install is
               created by the provisioner (`tools/install-ci-runner-x64.sh`, the one registration
               path — it downloads and sha256-checks the runner); this file never downloads a
               binary, and it REFUSES to add when no provisioner is present rather than
               improvising one.
  7. REFUSE    beyond the ceiling nothing is added and the reading is printed. `--want N` is the
               explicit-request form of the same guard; `--status` is the read-only form.

⛔ THE THREE THINGS IT WILL NOT DO
  * exceed the measured ceiling to chase throughput — a memory-starved shard fails for reasons
    unrelated to the code, which costs more than the queue does;
  * restart, relabel or remove a runner that is serving (or may be serving) a job;
  * register with a label set it has not derived: `self-hosted`/`Linux`/`<ARCH>` are derived by
    GitHub from the host and cannot be set, `ubuntu-<version>` must stay claimed by NO
    self-hosted runner, and the OTHER architecture's marker is never claimed (that would let an
    x86 box serve an arm64 job — a false PASS, not a delay).

USAGE
USAGE  (the interpreter is NAMED, so a box whose `python3` is older than 3.12 is told so by the
  guard below instead of silently running the wrong one; on a cell `python3` IS >=3.12 and the
  executable form works too — the file is mode 0755 with a `#!/usr/bin/env python3` shebang)
  python3.12 scripts/orchestrator-harness/runner_autoscale.py            # converge to the ceiling
  python3.12 scripts/orchestrator-harness/runner_autoscale.py --status   # measure+classify, 0 changes
  python3.12 scripts/orchestrator-harness/runner_autoscale.py --dry-run  # print the plan, change 0
  python3.12 scripts/orchestrator-harness/runner_autoscale.py --want 3   # REFUSED above the ceiling
  python3.12 scripts/orchestrator-harness/runner_autoscale.py --json     # one record (fleet view)
  python3.12 scripts/orchestrator-harness/runner_autoscale.py --repo owner/name
  (on a cell the converger currently runs from a LIVE-ONLY copy at
   `~/.pi/agent/scripts/runner_autoscale.py`. Until 2026-10-27 this file existed ONLY as that live
   copy on cell-4, so it could not be reviewed, tested or redeployed — the live-only class
   agent-infra#1552 tracks, where 26 of 35 lane-orchestration scripts live in only
   `~/.pi/agent/scripts`.)

  ⛔ LANDING THIS FILE DOES NOT DEPLOY IT, AND THE FARM IS NOT THE DELIVERY PATH FOR IT YET. It is
  NOT in `pi-bootstrap/setup.sh`'s `fleet_srcs`, so no `farm` install copies it to a cell: those
  entries are bare basenames copied from `$INFRA_ROOT/scripts/<base>`, a shape that cannot even name
  a file under `scripts/orchestrator-harness/`. The copy in `~/.pi/agent/scripts` on each cell keeps
  running whatever it was last hand-placed with, unmodified by this change. What this change buys is
  reviewability, a test suite and a source of truth — REDEPLOYING THE CELLS IS STILL OUTSTANDING, and
  until it is done the six defect fixes below are reachable only by running this path directly. Do
  not read this file's presence here as evidence that a cell is running it.

  Seams (all optional; the suite drives every one, and each defaults fail-closed):
    RUNNER_AUTOSCALE_RUNNER_ROOT   default /opt   (installs are `<root>/gh-runner*`)
    RUNNER_AUTOSCALE_MEMINFO       meminfo-shaped file (default /proc/meminfo)
    RUNNER_AUTOSCALE_NPROC         cores override (test seam; 0/garbage is REFUSED, never 0)
    RUNNER_AUTOSCALE_MACHINE       `uname -m` override for the label gate (test seam)
    RUNNER_AUTOSCALE_ALIVE_DIRS    newline-separated install dirs with a live listener (test seam
                                   for the `running` operand of the memory arm)
    RUNNER_AUTOSCALE_BUSY_DIRS     newline-separated install dirs with a live Runner.Worker (test
                                   seam for the local busy check)
    RUNNER_AUTOSCALE_STATE_DIR     default $HOME/.pi/agent/state (holds the run log)
    RUNNER_AUTOSCALE_GH            `gh` binary (default: gh on PATH)
    RUNNER_AUTOSCALE_SYSTEMCTL     `systemctl` binary (default: systemctl on PATH)
    RUNNER_AUTOSCALE_CONFIG_SH      config.sh for a pre-staged install (tests)
    RUNNER_AUTOSCALE_PROVISIONER    install-ci-runner-x64.sh for a NEW install
    RUNNER_AUTOSCALE_NO_SUDO        "1" → do not prefix with sudo (tests, rootless)
    RUNNER_AUTOSCALE_ONLINE_WAIT_S  seconds to wait for a restarted runner to report online (60)
    RUNNER_AUTOSCALE_POLL_S         poll interval while waiting (5)
    RUNNER_AUTOSCALE_DF           `df` for the DISK arm (default: the system one; a TEST seam)
    RUNNER_AUTOSCALE_DU           `du` for the measured per-runner footprint (same)
    RUNNER_AUTOSCALE_POOL_READ_ATTEMPTS  attempts for ONE pool read while it races our own restart (3),
                                   retrying NETWORK/5xx/RATE-LIMIT errors only — a 404 is answered at once
    RUNNER_AUTOSCALE_RETRY_BACKOFF_S     pause between those attempts (2)
    RUNNER_AUTOSCALE_UNIT_DIR      the ONE directory `--install-unit` writes to (default
                                   ~/.config/systemd/user). For the AUDIT it REPLACES the whole
                                   population; unset, the audit reads the five standard directories
                                   (~/.config/systemd/user, /etc/systemd/user, /usr/lib/systemd/user,
                                   /etc/systemd/system, /usr/lib/systemd/system). Also a TEST seam
    RUNNER_AUTOSCALE_STARVATION_CONFIRM_S  seconds between the two samples the starvation alarm takes
                                   before it pages (30). A value that is not a finite number in
                                   (0, 300] is REFUSED with a note rather than disabling the guard
    RUNNER_AUTOSCALE_HOME          the account home the unit/plist paths resolve against
                                   (default $HOME; a TEST seam — a case that read the host's HOME
                                   would report the developer's laptop, not the fixture)
    RUNNER_AUTOSCALE_BASE          the install-numbering base `_next_free_slot` walks
                                   (default <root>/gh-runner-x64; a TEST seam)
    RUNNER_AUTOSCALE_PS            `ps` for the local alive/busy checks (default: on PATH)
    RUNNER_AUTOSCALE_REPO          default repo for a pass (default daniel-ospina/tortoise)
    RUNNER_AUTOSCALE_GATE_STATE    the gate's own record — ONE bare word, written on TRANSITION only
                                   (default $HOME/.pi/agent/state/ci-runner-gate.state)
    RUNNER_AUTOSCALE_GATE_SCHEDULER  "1"/"0" override for the question this tool must ask before it
                                   treats that record as intent: does THIS box SCHEDULE the gate?
                                   A TEST seam — and it is a LOAD-BEARING input, not a knob: where
                                   nothing schedules the gate the floor stays disarmed (P1)
    RUNNER_AUTOSCALE_CRONTAB       `crontab` used to answer that question (default: on PATH; a TEST
                                   seam). A COMMENTED-OUT line is not a schedule

  ⛔ `--json` CONSUMERS: `starvation` is THREE-VALUED and the healthy value is `"ok"`. `"starved"` is
  the alarm; `"unmeasured"` means the queue could not be read and the invariant was NOT evaluated —
  never read that as healthy (a monitor whose test is `starvation != "starved"` treats blindness as
  health, which is the failure this field exists to prevent). The key is absent when the pass was not
  healthy enough to evaluate it, so absence is also not health. `starvation_eligible`/`starvation_why`
  publish the alarm's second half: the counts are always reported, and `why` states — on an `ok` pass
  — exactly why an invariant that HOLDS is not this pool's work.

  ⛔ THE SEAMS ARE MEASUREMENT INPUTS, NOT CEILING OVERRIDES. There is deliberately no
  `--ceiling` / `--max-runners` flag: a box that can be told to exceed its own measurement is a
  box with no guard, which is the defect this file exists to close.

EXIT  0 converged / nothing to do, or a CAPACITY ANSWER that is not a failure (`at-ceiling`,
      `under-target`, `over-ceiling`: the pass measured the box, decided, and changed nothing that
      it could have changed — `under-target` additionally names WHY it stopped, and a provisioner
      that reports success while installing NOTHING is `action-failed` (exit 3), not this).
      A REFUSAL is an answer too (a refusal is not a failure).
      1 usage, or `--want N` refused (N above the measured ceiling — nothing was changed)
      2 a measurement or pool read was UNREADABLE — fail-closed, nothing was changed
      3 an ACTION failed (restart / registration / missing provisioner) — the record says which
      4 STARVATION — `queued>0 ∧ busy==0 ∧ online>0` confirmed AND the queue can reach this pool
        (`starvation_eligible`: the pool advertises the fallback label, OR the gate wants `local`,
        OR the queue is at/above the gate's own backlog threshold, OR the oldest waiting run is older
        than `STARVATION_QUEUE_AGE_S` — the last one is the only term a cell can measure, where the
        gate's record does not exist). The second half is not
        decoration: those same counts are the NORMAL state of the fallback-only ruling, and paging
        on health is how the alarm that exists for #2875 gets ignored. Nothing was changed by the
        alarm: it names the invariant, the three counts and `starvation_why`. This is the one exit a
        health check should page on, because a starved box otherwise reads perfectly healthy.
      5 `--check-units` found an installed unit whose WorkingDirectory is unusable, or whose
        ExecStart names a program/path systemd cannot run (a transient or missing one, a relative
        path, or more than one ExecStart= on a non-oneshot type) — or an audit that read nothing at
        all. A READ-ONLY finding, deliberately distinct from 3: a consumer keying on "an action
        failed" must not confuse it with "my units are misconfigured".
      A pass whose provisioner refuses while THIS tool's disk arm says one more runner fits reports
      the verdict `guard-conflict` (exit 3, both sides' numbers in the notes): the two guards answer
      different questions, and the disagreement is a decision for a human, not an action failure.

      `--install-unit` exits 0 on success, 1 when REFUSED before writing anything (an unusable
      WorkingDirectory or repo), and 3 when the pair could not be installed. 3 is NOT a rollback
      guarantee: nothing installed is ever REMOVED, but the two renames are sequential, so a failure
      between them can leave one NEW file beside one from the previous install — the message names
      what was already replaced. When the files are written but `systemctl --user` could not
      reload/enable the timer, the schedule is UNKNOWN (this tool does not query it).
"""

from __future__ import annotations

import sys

# Refuse a <3.12 interpreter BEFORE the imports below. A module-level 3.12-only name would
# otherwise fail first, with an unattributed traceback instead of this message — and a lane reading
# "the tool is broken" eschews the guard and hand-rolls a runner count. The habit travels with the
# file (it is the same `sys.version_info` probe `scripts/admin-merge.sh` makes before it runs any
# python), so a caller's probe and this one cannot disagree about which interpreter ran.
if sys.version_info < (3, 12):  # noqa: UP036 — intentional RUNTIME guard
    print(
        f"runner_autoscale.py requires Python >= 3.12 (got "
        f"{sys.version_info[0]}.{sys.version_info[1]}) — run it with python3.12",
        file=sys.stderr,
    )
    raise SystemExit(2)

import argparse
import datetime
import errno
import json
import math
import os
import re
import shutil
import signal
import stat
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path

# ── the starvation alarm's numbers, in ONE place ─────────────────────────────────────────────────
# ⛔ WHY CONSTANTS: these two values are QUOTED IN OPERATOR-FACING TEXT (the refusal note says which
# range it refused and which default it used), and a hand-written second copy of a number is how a
# note comes to lie about what the code did. Measured in review: the note could say "<= 900" while
# the bound was 300, or "using 60s" while the fallback was 30, and NOTHING reddened — the note is
# prose, and prose is the copy no compiler checks. The text below is DERIVED from these constants, so
# changing a value changes the message, and the suite pins each one to the constant it came from.
STARVATION_CONFIRM_DEFAULT_S = 30.0
STARVATION_CONFIRM_MAX_S = 300.0

# ⛔ THE GATE'S OWN ENGAGEMENT THRESHOLD, COPIED DELIBERATELY AND PINNED BY THE SUITE
# (`ci_runner_gate.sh:43` `QUEUE_THRESHOLD="${CI_GATE_QUEUE_THRESHOLD:-60}"`; T43 reads THAT file and
# fails if this constant drifts from its default). It is the ONE number
# the project already uses to say "this queue is a GitHub-hosted backlog that is not draining". The
# starvation alarm needs it as an ELIGIBILITY term (see `starvation_eligible`): `queued>0` alone is
# true of a perfectly healthy fallback-only pool, and a deep queue with an idle pool is a mismatch
# worth paging on whatever the pool advertises (review finding P1).
GATE_QUEUE_THRESHOLD = 60

# ⛔ AND THE ONE DATUM A CELL *CAN* MEASURE WHEN THE GATE'S INTENT IS UNKNOWABLE: THE AGE OF THE
# OLDEST WAITING RUN (review finding P1, round 11). The eligibility terms above need something only a
# gate-managed box has (the record) or a number the incident happened to sit under (53 < 60). On a
# cell — the platform `--install-unit` targets — `gate_desired_mode()` is `None` BY CONSTRUCTION
# (`gate_scheduler_present`: the gate is a launchd job, and "nothing schedules the gate on a cell"),
# so term 2 is dead there and the #2875 shape (label STRIPPED pool-wide by the gate on another box,
# 53 queued, pool idle) read `ok`, exit 0: the tool was written for an outage it could not see from
# the boxes it is installed on.
#
# ⛔ WHY AGE AND NOT "THE QUEUE IS NOT DRAINING". That was the first candidate and it is WRONG here:
# `queued=14` sustained across the confirmation window is the measured, HEALTHY steady state of the
# fallback-only ruling (round 9's own P1) — it would re-arm the exact false alarm that fix removed.
# Age separates them: a healthy GitHub-hosted scheduler serves in seconds-to-minutes, so a queue whose
# OLDEST waiting run is half an hour old is not being served by anybody, and with the pool online and
# idle that is starvation whatever the gate's mode says. Not a second copy of a gate number: the gate
# has no age threshold, so this is this tool's own measurement, and it only ever ADDS an alarm where
# nothing previously watched (it cannot disarm `pool_serves_fallback` or the threshold term).
STARVATION_QUEUE_AGE_S = 1800

# ── the sizing predicate (owner ruling, agent-infra#2344 comment 6347825624) ────────────────────
MEM_PER_RUNNER_MB = 1500
MEM_RESERVE_MB = 2048

# ⛔ THE DISK ARM EXISTS BECAUSE THE TOOL HAD NONE. Measured incident: the provisioner refused a
# third runner with `REFUSED: disk headroom: 9G free against 44G needed for 3 runners (+20G reserve)`
# on an 8-core box whose ceiling said 3 — so this tool ASKED for a runner the disk could not hold,
# and the disagreement resolved to "add nothing" with the reason buried in a refusal note. Its cost
# model reads 3 x 8G + 20G = 44G, which is where these two constants come from.
# The per-runner number is an ALLOWANCE, not a footprint: a runner install is ~2 GB, and the 8 GB
# budgets growth of `_work` and docker images. So the allowance is used when nothing is installed
# yet (a first runner has no measurement), and the MEASURED footprint is reported beside it, so an
# operator can see which number set the ceiling instead of inferring it.
DISK_RESERVE_MB = 20480
FOOTPRINT_MB_DEFAULT = 8192
# ⛔ `_work` GROWTH IS COUNTED, AND IT ONLY EVER LOWERS THE CEILING: the measurement is the largest
# install's current size, so a runner whose workspace grew to 20 GB raises the per-runner budget to
# 20 GB and the ceiling drops with it — permanently, until that directory is trimmed. That is the
# fail-closed direction (it never over-adds) and the reading names `measured_largest=… budget=…`, so
# an operator can see it; trimming `<root>/gh-runner*/_work` restores the capacity.
CORE_TABLE = ((8, 3), (4, 2), (1, 1))

# The pool's own labels. `FALLBACK_LABEL` is attached only while the fallback is engaged —
# baking it in would make `ci_runner_gate.sh`'s `current_mode` read `local` forever.
FALLBACK_LABEL = "ubuntu-latest"
ARM_POOL_LABEL = "self-hosted-arm64"
ARCH_LABEL = {
    "x86_64": "self-hosted-x64",
    "amd64": "self-hosted-x64",
    "aarch64": "self-hosted-arm64",
    "arm64": "self-hosted-arm64",
}

DEFAULT_REPO = "daniel-ospina/tortoise"


class Unmeasurable(Exception):
    """A measurement or pool read could not be taken. Never read as a value."""


class ActionFailed(Exception):
    """An action (restart / registration / provision) failed. Retried on the next pass."""


class UnitRefused(Exception):
    """A unit was REFUSED before anything was written. Not a failure: an answer (exit 1).

    Refused rather than written-and-hoped, because a unit systemd will not start is a false PASS on
    "the converger is scheduled" — the same shape as the registered-runner-with-no-enabled-unit this
    file already refuses elsewhere.
    """


class ProvisionerRefused(ActionFailed):
    """The provisioner's OWN guard refused (exit 2). A refusal is an answer, not a failure."""


# ── measurement ────────────────────────────────────────────────────────────────────────────────
def cores(nproc: str | None = None) -> int:
    """Cores on this box. Unreadable/garbage is an ERROR, never 0 — 0 would silence every gate."""
    raw = nproc if nproc is not None else os.environ.get("RUNNER_AUTOSCALE_NPROC") or os.cpu_count()
    try:
        n = int(str(raw).strip())
    except (TypeError, ValueError) as exc:
        raise Unmeasurable(f"cores unreadable ({raw!r})") from exc
    if n < 1:
        raise Unmeasurable(f"cores not positive ({n})")
    return n


def mem_available_mb(meminfo: str | None = None) -> int:
    """MemAvailable in MiB, from /proc/meminfo (or a file with the same shape).

    ⛔ MemAvailable, not MemFree: MemFree excludes reclaimable page cache, so a healthy 15 GB box
    with a warm cache reads ~0.5 GB "free" and would refuse every addition forever.
    ⛔ A missing/garbled value raises — an absent reading is never 0 MB and never "plenty".
    """
    path = Path(meminfo or os.environ.get("RUNNER_AUTOSCALE_MEMINFO") or "/proc/meminfo")
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        raise Unmeasurable(f"cannot read {path} ({exc.strerror or exc})") from exc
    m = re.search(r"^MemAvailable:\s+(\d+)\s+kB", text, re.MULTILINE)
    if not m:
        raise Unmeasurable(f"no MemAvailable line in {path}")
    return int(m.group(1)) // 1024


def core_ceiling(ncpu: int) -> int:
    for floor, ceil in CORE_TABLE:
        if ncpu >= floor:
            return ceil
    return 1


def df_free_mb(root: str) -> int:
    """Free MB at `root`, from `df -Pm`. Raises `Unmeasurable` — a disk read is a measurement.

    ⛔ POSITIONAL FROM THE END, not from the start: `df -P` guarantees the tail fields, but the
    SOURCE field can contain a space ("my big disk"), which shifts every later field right. Reading
    `fields[3]` then returns the filesystem TOTAL — measured: a 25000 MB free disk read as 999999,
    i.e. the arm that exists to stop over-adding would have over-added by 40x.

    RESIDUALS, measured and accepted (both fail CLOSED, i.e. they never over-add): a MOUNT POINT
    containing a space (`/Volumes/My Disk`) shifts the tail so `fields[-3]` is `1%` and the read is
    `Unmeasurable` — the pass then reports `disk_UNVERIFIED` and withholds the fill for ever on that
    path, which is visible but permanent; and a mount point whose own words are numeric (`/mnt/a 12
    34 56`) can parse a WRONG number. Neither is reachable for a normal `/opt` runner root, and no
    positional parse can fix them — `-P` guarantees the tail's SHAPE, not that a path is one field.
    """
    df_bin = os.environ.get("RUNNER_AUTOSCALE_DF") or shutil.which("df") or "df"
    rc, out = _run([df_bin, "-Pm", root], timeout=60)
    if rc != 0:
        raise Unmeasurable(f"disk free space at {root}: `df -Pm` rc={rc} {out[:200]}")
    for line in reversed(out.splitlines()):
        fields = line.split()
        if len(fields) >= 4 and fields[-3].isdigit():
            return int(fields[-3])
    raise Unmeasurable(f"disk free space at {root}: cannot parse `df -Pm` output {out[-200:]!r}")


def disk_footprint_mb(root: str) -> tuple[int, str]:
    """(per_runner_mb, basis) — the cost budgeted per runner, and HOW it was decided.

    ⛔ THE MEASUREMENT CAN ONLY TIGHTEN THE BUDGET, NEVER LOOSEN IT. 8 GB is the installer's
    allowance (it budgets growth of `_work` and docker images); a real install is ~2 GB. Taking
    `min(measured, allowance)` made this arm LOOSER than the guard it is supposed to agree with for
    every measurement below 8 GB — i.e. always — so a box with a 20 GB install and 30 GB free would
    have been told "one more fits". `max()` keeps the arm at least as strict as the installer.
    A failed `du` is NOT fatal (the allowance still bounds it) but the basis SAYS it was not
    measured, because a number that set a ceiling must never be presented as a measurement.
    """
    installs = sorted(Path(root).glob("gh-runner*"))
    if not installs:
        return FOOTPRINT_MB_DEFAULT, f"allowance={FOOTPRINT_MB_DEFAULT} (nothing installed yet)"
    du_bin = os.environ.get("RUNNER_AUTOSCALE_DU") or shutil.which("du") or "du"
    rc, out = _run([du_bin, "-sm", *[str(p) for p in installs]], timeout=120)
    sizes = []
    for line in out.splitlines():
        fields = line.split()
        if fields and fields[0].isdigit():
            sizes.append(int(fields[0]))
    if not sizes:
        return FOOTPRINT_MB_DEFAULT, (
            f"allowance={FOOTPRINT_MB_DEFAULT} (footprint NOT measured: `du -sm` rc={rc} "
            f"{out[-120:]!r} — the ceiling uses the installer's number, not a measurement)"
        )
    measured = max(sizes)
    # ⛔ A NON-ZERO `du` IS NOT AN ABSENT MEASUREMENT (review finding P2). `du` prints a total for
    # EVERY argument it could read and exits 1 when ANY subdirectory was unreadable — measured on
    # this box: a root-owned file left in a runner's `_work` produced `2 du/a`, `3 du/b`,
    # `du: cannot read directory …: Permission denied`, **RC=1**. The old `rc != 0` arm threw both
    # numbers away and fell back to the installer's 8 GB allowance, which is LOOSER than the truth
    # whenever an install is bigger than 8 GB — the exact over-add the docstring says this arm can
    # never allow. A partial measurement is a LOWER BOUND, so it can only tighten `max(...)`, and
    # the basis says which it was.
    partial = (
        f"; PARTIAL (du -sm rc={rc}, so this is a lower bound on {len(sizes)} install(s))"
        if rc != 0
        else ""
    )
    return max(measured, FOOTPRINT_MB_DEFAULT), (
        f"measured_largest={measured} of {len(sizes)} installs, "
        f"allowance={FOOTPRINT_MB_DEFAULT}, budget={max(measured, FOOTPRINT_MB_DEFAULT)} "
        f"(the stricter of the two){partial}"
    )


def measure_disk(root: str) -> tuple[int, int, str]:
    """(free_mb, per_runner_mb, reading). Free space RAISES; the footprint never does."""
    free_mb = df_free_mb(root)
    per_runner, basis = disk_footprint_mb(root)
    return free_mb, per_runner, f"disk_free_mb={free_mb} per_runner_disk_mb={per_runner} {basis}"


def disk_allows_one_more(free_mb: int, per_runner_mb: int) -> bool:
    """Does ONE more runner fit under the installer's own reserve?

    ⛔ THE INCREMENT, NOT THE WHOLE BOX. The installer asks "is there room for ALL N runners plus the
    reserve"; this tool asks "is there room for the ONE runner it is about to add". Those are
    different questions, and when the first says no and the second says yes the box is in the state
    that produced the measured refusal — which must be REPORTED as a conflict, not averaged away.
    """
    return (free_mb - DISK_RESERVE_MB) >= per_runner_mb


def ceiling(
    ncpu: int, mem_mb: int, running: int, free_mb: int | None, per_runner_mb: int
) -> tuple[int, str, str]:
    """(ceiling, bound, reading). `running` = listeners ALREADY alive on this box."""
    by_core = core_ceiling(ncpu)
    headroom = max(0, (mem_mb - MEM_RESERVE_MB) // MEM_PER_RUNNER_MB)
    by_mem = max(0, running) + headroom
    # ⛔ THE DISK ARM COUNTS RUNNERS ALREADY ON DISK, like the memory arm counts the ones already in
    # RAM: `running` is included because their bytes are already paid for.
    # ⛔ AND AN UNREAD DISK BOUNDS NOTHING — it does not silently become "no arm". The caller that
    # gets `None` here REFUSES TO FILL (see converge): an unknown disk is not permission to add.
    if free_mb is None:
        by_disk: int | None = None
        value = min(by_core, by_mem)
        bound = "cores" if by_core <= by_mem else "memory"
        disk_part = "by_disk=UNKNOWN"
    else:
        disk_headroom = max(0, (free_mb - DISK_RESERVE_MB) // max(per_runner_mb, 1))
        by_disk = max(0, running) + disk_headroom
        value = min(by_core, by_mem, by_disk)
        bound = min((by_core, "cores"), (by_mem, "memory"), (by_disk, "disk"))[1]
        disk_part = f"by_disk={by_disk}"
    reading = (
        f"ncpu={ncpu} mem_available_mb={mem_mb} running={max(0, running)} "
        f"per_runner_mb={MEM_PER_RUNNER_MB} reserve_mb={MEM_RESERVE_MB} "
        f"by_cores={by_core} by_memory={by_mem} {disk_part} bound={bound} ceiling={value}"
    )
    return value, bound, reading


# ── local inventory ────────────────────────────────────────────────────────────────────────────
@dataclass
class LocalRunner:
    """One runner INSTALL on this box, as the box sees it (not as the pool reports it)."""

    directory: Path
    name: str
    repo: str
    alive: bool = False

    @property
    def unit(self) -> str:
        slug = self.repo.rstrip("/").removeprefix("https://github.com/")
        return f"actions.runner.{slug.replace('/', '-')}.{self.name}.service"


def _repo_slug(value: str) -> str:
    """`https://github.com/o/n`, `github.com/o/n`, `o/n`, trailing slash → `o/n`, lowercased.

    ⛔ The comparison decides whether an install may be RE-REGISTERED, so it must not be fooled
    by spelling: `.runner` writes a URL with no trailing slash today and a trailing slash in some
    runner versions, and a case difference must not flip the answer in the UNSAFE direction
    ("another repo" read as "same" would hijack it; the reverse only declines to act).
    """
    v = (value or "").strip().rstrip("/").removesuffix(".git")
    for prefix in ("https://", "http://", "ssh://git@", "git@"):
        if v.startswith(prefix):
            v = v[len(prefix) :]
    v = v.removeprefix("github.com/").removeprefix("github.com:")
    return v.lower()


def _read_runner_config(directory: Path) -> tuple[str, str]:
    """(agentName, gitHubUrl) from `<dir>/.runner`. Raises when it is not readable.

    ⛔ A directory is not an install. The ONLY accept condition is the `.runner` config the
    runner itself wrote at registration — that is what makes an install attributable to a name
    and a repo. (`utf-8-sig`: some runner versions write a BOM, so a line regex would miss it.)
    """
    cfg = directory / ".runner"
    try:
        data = json.loads(cfg.read_text(encoding="utf-8-sig", errors="replace"))
    except (OSError, ValueError) as exc:
        raise Unmeasurable(f"{cfg} is not a readable runner config ({exc})") from exc
    name = str(data.get("agentName") or "").strip()
    repo = str(data.get("gitHubUrl") or "").strip()
    if not name or not repo:
        raise Unmeasurable(f"{cfg} has no agentName/gitHubUrl")
    return name, repo


def _listener_dirs() -> set[str]:
    """Install directories that currently have a live `Runner.Listener`.

    ⛔ This is the `running` operand of the memory arm, so it is MEASURED, never inferred from
    "an install exists": a registered-but-dead install occupies no memory, and counting it would
    inflate the ceiling by one runner on exactly the box that just lost one.
    """
    seam = os.environ.get("RUNNER_AUTOSCALE_ALIVE_DIRS")
    if seam:
        try:
            return {
                ln.strip()
                for ln in Path(seam).read_text(encoding="utf-8").splitlines()
                if ln.strip()
            }
        except OSError as exc:
            raise Unmeasurable(f"alive-dirs seam unreadable ({seam}: {exc})") from exc
    try:
        proc = subprocess.run(
            [os.environ.get("RUNNER_AUTOSCALE_PS") or "ps", "-eo", "args"],
            capture_output=True,
            text=True,
            timeout=15,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        # ⛔ FAIL CLOSED. This is the ONLY arm that used to degrade to a value: a broken `ps`
        # returned the empty set, so `running` read 0 and the guard added a runner to a box that
        # was already at its ceiling (round 7, finding 1) — while the record printed `running=0`
        # as if it were a reading. Every other measurement raises, and so must this one.
        raise Unmeasurable(f"process list unreadable ({exc})") from exc
    if proc.returncode != 0:
        raise Unmeasurable(
            f"process list unreadable (ps exited {proc.returncode}: {(proc.stderr or '').strip()[:200]})"
        )
    dirs: set[str] = set()
    for line in proc.stdout.splitlines():
        if "Runner.Listener" not in line:
            continue
        for token in line.split():
            if "/bin/Runner.Listener" in token or token.endswith("bin/Runner.Listener"):
                dirs.add(str(Path(token).parent.parent))
    return dirs


def discover(root: str | Path) -> list[LocalRunner]:
    """Every runner install under `root/gh-runner*`, sorted by directory name.

    A sibling directory with no `.runner` is SKIPPED (a download that never registered is a fact
    about the box, not a reason to abort the pass). A `.runner` that exists and cannot be parsed
    RAISES: silently dropping it would make the box think it has one fewer runner than it has,
    and it would then register a duplicate under a new name. An install this account cannot INSPECT
    raises `Unmeasurable` for the same reason — "unreadable" is not "absent" (review finding P1).
    """
    base = Path(root)
    # ⛔ EVERY PROBE HERE IS THREE-VALUED, like `_inspect_path` — because the pass runs this FIRST
    # and an escaping OSError lands in `main()`'s backstop AFTER a repair may already have acted,
    # losing the record of it. Measured 2026-10-27: a `drwx------` install owned by another account
    # (the mode `sudo` installs produce) made `Path.exists()` raise PermissionError through
    # `discover()`, and a pass that had already restarted a runner exited 2 with NO `actions` field.
    # An install directory that cannot be ENUMERATED is not empty either: `Path.glob` answers `[]`
    # for an unreadable base, which would read as "this box has no runners" and register duplicates.
    base_stat, base_reason = _inspect_path(base)
    if base_stat is None:
        if base_reason is None:
            return []
        raise Unmeasurable(f"the runner root {base} {base_reason} — cannot inventory this box")
    # ⛔ `Path.glob` CANNOT DETECT AN UNLISTABLE ROOT (review finding P1). 3.12's
    # `_WildcardSelector._select_from` wraps its `scandir` in `except OSError: pass`, so a directory
    # this account can stat but cannot LIST returns `[]` — "this box has no runners" — which is the
    # duplicate-registration hole this comment claims to close. `os.scandir` is used directly so the
    # failure is raised where it happens.
    try:
        names = [entry.name for entry in os.scandir(base)]
    except OSError as exc:
        raise Unmeasurable(
            f"the runner root {base} cannot be listed ({exc.strerror or exc}) — cannot inventory "
            "this box"
        ) from exc
    candidates = sorted(base / name for name in names if name.startswith("gh-runner"))
    alive = _listener_dirs()
    found: list[LocalRunner] = []
    for entry in candidates:
        entry_stat, entry_reason = _inspect_path(entry)
        if entry_reason is not None:
            raise Unmeasurable(
                f"the install {entry} {entry_reason} — an install this account cannot read cannot be "
                "counted, and counting it as absent would register a duplicate"
            )
        if entry_stat is None or not stat.S_ISDIR(entry_stat.st_mode):
            continue
        cfg_stat, cfg_reason = _inspect_path(entry / ".runner")
        if cfg_reason is not None:
            raise Unmeasurable(
                f"the install {entry} {cfg_reason} — an install this account cannot read cannot be "
                "counted, and counting it as absent would register a duplicate"
            )
        if cfg_stat is None:
            continue
        name, repo = _read_runner_config(entry)
        found.append(LocalRunner(directory=entry, name=name, repo=repo, alive=str(entry) in alive))
    return found


# ── the pool ──────────────────────────────────────────────────────────────────────────────────
@dataclass
class PoolEntry:
    name: str
    status: str
    busy: bool
    labels: list[str] = field(default_factory=list)

    @property
    def online(self) -> bool:
        return self.status == "online"


def gh_bin() -> str:
    return os.environ.get("RUNNER_AUTOSCALE_GH") or (shutil.which("gh") or "")


def read_pool(repo: str) -> dict[str, PoolEntry]:
    """The repo's runner pool by name. Unreadable raises; an EMPTY pool is a legitimate answer.

    ⛔ `--paginate` is mandatory: `gh api` returns 30 runners per page, so a bigger pool read
    without it makes existing runners invisible — and "not in the pool" is the ORPHANED
    classification, which RE-REGISTERS. A truncated read would double-register the tail.
    ⛔ A failed read is not an empty pool: conflating them is how a network blip becomes three
    new runners.
    """
    gh = gh_bin()
    if not gh:
        raise Unmeasurable("gh is not on PATH (set RUNNER_AUTOSCALE_GH)")
    cmd = [
        gh,
        "api",
        "--paginate",
        f"repos/{repo}/actions/runners",
        "--jq",
        '.runners[] | [.name, .status, (.busy|tostring), ([.labels[].name]|join(","))] | @tsv',
    ]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.SubprocessError) as exc:
        raise Unmeasurable(f"gh api failed to run ({exc})") from exc
    if proc.returncode != 0:
        raise Unmeasurable(
            f"gh api repos/{repo}/actions/runners exited {proc.returncode}: "
            f"{(proc.stderr or '').strip()[:300]}"
        )
    pool: dict[str, PoolEntry] = {}
    for line in proc.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 3:
            raise Unmeasurable(f"runner row has no readable name/status: {line[:160]!r}")
        name, status, busy = parts[0], parts[1], parts[2]
        if not name or status not in ("online", "offline"):
            raise Unmeasurable(f"runner row has no readable name/status: {line[:160]!r}")
        pool[name] = PoolEntry(
            name=name,
            status=status,
            busy=(busy == "true"),
            labels=[x for x in parts[3].split(",") if x] if len(parts) > 3 else [],
        )
    return pool


def fallback_engaged(pool: dict[str, PoolEntry]) -> bool:
    """Is the ARM64 pool carrying the fallback label RIGHT NOW (the gate's own condition)?"""
    return any(ARM_POOL_LABEL in e.labels and FALLBACK_LABEL in e.labels for e in pool.values())


# ── the starvation invariant (agent-infra#2875) ─────────────────────────────────────────────────
# The runs endpoint is NEWEST-FIRST and ignores `sort`/`direction` (they are not parameters of it, so
# they are silently dropped rather than refused). `min(created_at)` over a page is therefore the only
# way to reach the queue's head, and the page must hold the whole queue or that min is merely a LOWER
# BOUND. `scripts/ci_runner_gate.sh` encodes both facts for the same endpoint (#2904).
QUEUE_AGE_PAGE = 100


def read_queued_runs(repo: str) -> int:
    """How many workflow runs are QUEUED for this repo. Unreadable raises — never reads as 0.

    ⛔ An absent queue reading is not "no queue". `0` is the value that silences the alarm, so a
    failed read must never produce it (the same fail-closed rule every measurement here follows).
    """
    gh = gh_bin()
    if not gh:
        raise Unmeasurable("gh is not on PATH (set RUNNER_AUTOSCALE_GH)")
    cmd = [
        gh,
        "api",
        f"repos/{repo}/actions/runs?status=queued&per_page=1",
        "--jq",
        ".total_count",
    ]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.SubprocessError) as exc:
        raise Unmeasurable(f"queue depth read failed to run ({exc})") from exc
    if proc.returncode != 0:
        raise Unmeasurable(
            f"repos/{repo}/actions/runs?status=queued exited {proc.returncode}: "
            f"{(proc.stderr or '').strip()[:300]}"
        )
    raw = (proc.stdout or "").strip()
    try:
        return int(raw)
    except (TypeError, ValueError) as exc:
        raise Unmeasurable(f"queue depth is not a number ({raw[:80]!r})") from exc


def read_oldest_queued_age_s(repo: str) -> float | None:
    """How long the OLDEST queued run has been waiting, in seconds; `None` when nothing is queued.

    ⛔ THIS IS THE ONE STARVATION INPUT A CELL CAN MEASURE WITHOUT THE GATE'S INTENT (review finding
    P1, round 11 — see `STARVATION_QUEUE_AGE_S`). It answers a different question from the depth: a
    depth says work is waiting, an AGE says whether anybody is serving it.

    ⛔ FAIL-CLOSED IN THE SAME DIRECTION AS EVERY OTHER MEASUREMENT: an unreadable answer RAISES, and
    an EMPTY queue is the only thing that returns `None`. A failed read must never manufacture "nothing
    is waiting" — that is the value that silences the alarm — and it must not manufacture an age
    either, because a fabricated 0 would disarm the term it feeds.

    ⛔ THE RUNS ENDPOINT IS NEWEST-FIRST AND DOES NOT TAKE `sort`/`direction` (round-13 review P1,
    verified against the live API: `?sort=created&direction=asc` returns the SAME newest-first page as
    no parameters at all, because unknown query parameters are ignored rather than refused). This
    function used to send that pair and read row 0 as "the oldest" — which was the NEWEST run on a
    queue still receiving work, i.e. an age near 0 on exactly the starved shape #2875 reported, and
    therefore `starvation="ok"` and exit 0. That is the one direction this bound cannot afford, so
    the head is derived the way `scripts/ci_runner_gate.sh` derives it (#2904): read a FULL page and
    take `min(created_at)`. A page that cannot hold the whole queue yields only a LOWER BOUND on the
    head age, so it is REFUSED by name rather than certified — same verdict, `Unmeasurable`, as every
    other operand that could not be read.

    ⛔ THAT REFUSAL IS DEFENSIVE, AND ITS RATIONALE IS STATED RATHER THAN IMPLIED (round-13 review,
    2nd round). The age read is only taken when the DEPTH term has not already decided, i.e. when
    `queued < GATE_QUEUE_THRESHOLD` (60) — and `QUEUE_AGE_PAGE` is 100. So at the shipped constants a
    saturated page cannot arise here, and the `total` this read sees always equals the `queued` the
    depth term already declined to alarm on. It is kept because the two numbers are INDEPENDENT (the
    gate's threshold is operator-settable while its counterpart here is a module constant), and
    because certifying a lower bound is the one error this function must not make in either
    direction: if the two ever cross, the refusal is what stands between a full stop and a healthy
    reading. Its case pins the guard at the unit boundary rather than through an end-to-end state
    this tool cannot produce — see T56.
    """
    gh = gh_bin()
    if not gh:
        raise Unmeasurable("gh is not on PATH (set RUNNER_AUTOSCALE_GH)")
    cmd = [
        gh,
        "api",
        f"repos/{repo}/actions/runs?status=queued&per_page={QUEUE_AGE_PAGE}",
        "--jq",
        '[.total_count, (([.workflow_runs[].created_at]|min)//"")]|@tsv',
    ]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.SubprocessError) as exc:
        raise Unmeasurable(f"queue age read failed to run ({exc})") from exc
    if proc.returncode != 0:
        raise Unmeasurable(
            f"repos/{repo}/actions/runs?status=queued&per_page={QUEUE_AGE_PAGE} exited "
            f"{proc.returncode}: {(proc.stderr or '').strip()[:300]}"
        )
    total_raw, _, raw = (proc.stdout or "").strip().partition("\t")
    raw = raw.strip().strip('"')
    try:
        total = int(total_raw)
    except (TypeError, ValueError) as exc:
        raise Unmeasurable(f"queue age read has no readable total_count ({total_raw[:80]!r})") from exc
    if total > QUEUE_AGE_PAGE:
        raise Unmeasurable(
            f"queue ({total}) is DEEPER than the age read page ({QUEUE_AGE_PAGE}) — the page is "
            "newest-first, so its min is only a LOWER BOUND on the queue head's age; the head cannot "
            "be measured"
        )
    if not raw:
        # ⛔ AN EMPTY PAGE IS NOT AN EMPTY QUEUE (round-13 review, 2nd round). The docstring above
        # promises that `None` means "nothing is waiting"; returning it on `total > 0` would be
        # exactly the disarmed term that paragraph forbids — the age is only consulted when
        # `queue_age_s is not None`, so a null/absent `created_at` on a queue that HAS work would
        # report "nothing is waiting". `ci_runner_gate.sh:299` refuses this same combination BY NAME
        # ("A queued run exists, so its age MUST be a measurement").
        if total == 0:
            return None
        raise Unmeasurable(
            f"{total} queued run(s) but the page carries no readable created_at — the queue head "
            "cannot be measured, and that is not an empty queue"
        )
    try:
        created = datetime.datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError as exc:
        raise Unmeasurable(f"the queue's oldest run has an unreadable created_at ({raw[:80]!r})") from exc
    if created.tzinfo is None:
        created = created.replace(tzinfo=datetime.timezone.utc)
    age = (datetime.datetime.now(datetime.timezone.utc) - created).total_seconds()
    # ⛔ A NEGATIVE AGE IS A CLOCK SKEW, NOT A YOUNG QUEUE. Left alone it would silently satisfy the
    # bound's opposite and read as "fresh", so it is reported as unmeasurable with the value named.
    if age < 0:
        raise Unmeasurable(
            f"the queue's oldest run is dated {int(-age)}s in the FUTURE ({raw}) — a clock skew, "
            "not a measurement"
        )
    return age


def starvation_invariant(queued: int, busy: int, online: int) -> bool:
    """`queued > 0 ∧ busy == 0 ∧ online > 0` — WORK IS WAITING, CAPACITY IS UP AND IDLE.

    ⛔ THIS IS STARVATION, NOT DEMAND. Work queued with every runner BUSY is a busy pool; work queued
    with NO runner online is a repair problem (this tool's own DEAD/ORPHANED path); work queued with a
    runner ONLINE and NONE busy means the queue and the runners are not meeting — the labels, the
    arch, or the gate. Nothing watched that: measured 2026-10-27 it was misread twice in one night,
    first as "capacity" and then as "review cost", and the merge window was gone (agent-infra#2875).
    ⛔ THE `online > 0` OPERAND IS NOT DECORATION: without it an all-offline pool (nothing can take
    work) reads as starvation and pages a human for a state the repair path already owns.

    ⛔ AND THE INVARIANT ALONE IS NOT THE ALARM — `starvation_eligible` is the second half. The shape
    below is ALSO the designed steady state of the fallback-only ruling (`ci_runner_gate.sh:11-13`):
    while GitHub-hosted is healthy the pool deliberately does not advertise `ubuntu-latest`, so the
    repo's queue is ALWAYS > 0 for this pool, and every online runner is idle BY DESIGN. Measured
    2026-10-27 on agent-infra: `queued=14` sustained across a confirmation window while the pool was
    idle — the old code paged exit 4 on that, every ~9 minutes, for ever.
    """
    return queued > 0 and busy == 0 and online > 0


def starvation_eligible(
    pool: dict[str, PoolEntry],
    queued: int,
    gate_mode: str | None,
    queue_age_s: float | None = None,
) -> tuple[bool, str]:
    """`(eligible, why)` — can the work in this queue REACH this pool at all? (the alarm's second half)

    ⛔ WHY AN ELIGIBILITY TERM, AND WHY NOT SIMPLY `queued > threshold` (review finding P1). The
    alarm exists because a mismatch between what the jobs ask for and what the runners advertise is
    invisible everywhere else (#2875: 9 runners / 8 online / `busy=0` / **53 queued**). But the exact
    same counts are the NORMAL state of the recorded fallback-only ruling: while the gate says
    `github`, `ubuntu-latest` is claimed by GitHub-hosted ONLY, so queued work is meant to be served
    there and an idle pool is health. A guard that cannot tell those apart pages on health until the
    page is ignored, which is how the incident it exists for becomes invisible (noise loses).

    So the alarm fires when this pool is REPONSIBLE for the queue:
      * the pool ADVERTISES the fallback label right now — work can be handed to us and is not; or
      * the gate WANTS `local` — the pool should be carrying it and is not (this is #2875's own shape:
        the label had been stripped while the gate was asking for the fallback); or
      * the queue is at/above the GATE'S OWN threshold (`GATE_QUEUE_THRESHOLD`, the same 60 the gate
        uses to call a GitHub-hosted backlog unhealthy) — a deep queue with an idle pool is worth a
        page whatever the labels say, and the pool read is the only other evidence available; or
      * the queue's OLDEST waiting run is older than `STARVATION_QUEUE_AGE_S` — the one term a CELL
        can measure when the gate's intent is unknowable there (see the constant). It does not
        replace "the queue is not draining" (which is the healthy steady state): it is AGE.

    Everything else is `ok` WITH the counts published, so an operator who expects an alarm can read
    why it did not fire from the record instead of guessing (the same rule as the label floor).
    """
    if pool_serves_fallback(pool):
        return True, f"the pool advertises {FALLBACK_LABEL} right now"
    if gate_mode == "local":
        return True, f"the gate wants `local`, but no runner in the pool advertises {FALLBACK_LABEL}"
    if queued >= GATE_QUEUE_THRESHOLD:
        return (
            True,
            f"queued={queued} is at/above the gate's own backlog threshold ({GATE_QUEUE_THRESHOLD})",
        )
    if queue_age_s is not None and queue_age_s >= STARVATION_QUEUE_AGE_S:
        return (
            True,
            f"the OLDEST queued run has waited {int(queue_age_s)}s, at/above the "
            f"{STARVATION_QUEUE_AGE_S}s bound — a healthy GitHub-hosted scheduler does not hold work "
            "that long, and this pool is online and idle, so nobody is serving this queue",
        )
    if gate_mode is None:
        # ⛔ "UNKNOWN" IS NOT "GITHUB" (review finding P1). `gate_desired_mode()` returns `None` in
        # four states (no record, nothing scheduling the gate, an unreadable record, a record holding
        # something that is not a mode), and saying "the gate does not want `local`" of all four
        # asserts a decision nobody made. The verdict is still `ok` — and the residual is stated: on
        # such a box NOTHING here strips the label (this tool preserves it) — but ⛔ THAT IS NOT THE
        # CLAIM THE OLD TEXT MADE (review finding P1, round 11). The label is a POOL property and the
        # gate that strips it runs on ANOTHER box (the hub), so "nothing HERE strips it" does not rule
        # the stripped shape out on a cell; only the AGE term can, and that is why the sentence now
        # states what was MEASURED instead of a conclusion this box cannot reach.
        return False, (
            f"the gate's mode could not be determined on this box (see `gate_why`), no runner "
            f"advertises {FALLBACK_LABEL}, queued={queued} is below the gate's backlog threshold "
            f"({GATE_QUEUE_THRESHOLD}), and the oldest waiting run is younger than "
            f"{STARVATION_QUEUE_AGE_S}s (or the queue is empty) — so the waiting work has not been "
            "waiting long enough to show it cannot reach a runner, and it is treated as "
            "GitHub-hosted's until it does"
        )
    return False, (
        f"queued={queued} is below the gate's backlog threshold ({GATE_QUEUE_THRESHOLD}), the gate "
        f"says `{gate_mode}` (so it does not want `local`), no runner advertises "
        f"{FALLBACK_LABEL}, and the oldest waiting run is younger than {STARVATION_QUEUE_AGE_S}s — "
        "this queue is GitHub-hosted's work, not this pool's "
        "(fallback-only, ci_runner_gate.sh:11-13)"
    )


def starvation_probe(
    repo: str, confirm_s: float = STARVATION_CONFIRM_DEFAULT_S, gate_mode: str | None = None
) -> dict:
    """Sample the invariant, CONFIRM it across a short interval, and report the counts.

    A dict, not a bool, so a `--json` consumer reads one record instead of parsing prose.

    ⛔ CONFIRMED, because the invariant also holds for a few seconds of ordinary handover (a queue
    drains, the next job has not been assigned yet). The second sample is only taken when the FIRST
    one already looks starved, so a healthy box pays nothing for the confirmation.
    ⛔ AN UNREAD QUEUE IS `unmeasured`, NOT OK. Turning it into exit 2 would let a permission-scoped
    token silence the capacity work this tool exists for; turning it into `ok` would hide the one
    state the alarm exists to surface. So it is named, in the record and in the human line.
    ⛔ THE INVARIANT IS NECESSARY AND NOT SUFFICIENT: `eligible` (see `starvation_eligible`) turns
    the SAME counts into `ok` when the queue is GitHub-hosted's work, and `why` says so — the counts
    are still published, because an explanation is not a measurement and the evidence must survive.
    ⛔ A FAILED CONFIRM READ DOES NOT DISCARD THE FIRST SAMPLE (review finding P3, round 11). Both
    samples used to sit inside ONE `try`, so a one-off API blip on the second read returned
    `{"state": "unmeasured"}` with EVERY count absent — indistinguishable from "the queue was never
    readable", and it threw away an observation that had already answered "yes". The state stays
    `unmeasured` (a blip is not a page), but the record now carries what the first sample SAW and
    names the confirm failure separately.
    """

    def sample() -> tuple[dict[str, PoolEntry], int]:
        return read_pool_retrying(repo), read_queued_runs(repo)

    def decide(
        pool: dict[str, PoolEntry], queued: int, busy: int, online: int
    ) -> tuple[bool, str, float | None]:
        """`(eligible, why, queue_age_s)` — the AGE read is taken only where it can change the answer.

        ⛔ ONE EXTRA API CALL, ON THE AMBIGUOUS SHAPE ONLY. A healthy box (a busy pool, or an empty
        queue) never reaches it: the invariant is false, so nothing could make it eligible. It is
        asked exactly when the counts say "work is waiting and capacity is idle" and the cheaper
        terms could not decide — which is the state the round-11 finding was about.
        """
        eligible, why = starvation_eligible(pool, queued, gate_mode)
        age: float | None = None
        if starvation_invariant(queued, busy, online) and not eligible:
            age = read_oldest_queued_age_s(repo)
            eligible, why = starvation_eligible(pool, queued, gate_mode, queue_age_s=age)
        return eligible, why, age

    seen: dict[str, object] = {}
    # ⛔ THE COUNTS ARE AN OBSERVATION OF A COMPLETE SAMPLE, SO THEY OUTLIVE A LATER READ'S FAILURE
    # (round-13 review, 2nd round). `seen` cannot carry them on that path because it is built from
    # `decide()`'s RETURN VALUE, and the AGE read happens INSIDE `decide()` — so a refused age erased
    # counts that had already been measured, and `converge`'s `if "queued" in starvation:` then
    # published no `queued_runs` at all, i.e. the round-7 contract (`--json` must not report the
    # depth as absent) broke on exactly the passes an operator needs to explain.
    measured: dict[str, object] = {}
    try:
        pool, queued = sample()
        busy = sum(1 for e in pool.values() if e.busy)
        online = sum(1 for e in pool.values() if e.online)
        measured = {"queued": queued, "busy": busy, "online": online}
        eligible, why, age = decide(pool, queued, busy, online)
        seen = {
            "queued": queued,
            "busy": busy,
            "online": online,
            "eligible": eligible,
            "why": why,
            # ⛔ THE SAME KEY THE HEALTHY PATH PUBLISHES (`queue_age_s`), so the confirm-failure
            # record carries the age under the name a reader already knows. A second spelling here
            # would publish the evidence on one path and drop it on the other.
            "queue_age_s": age,
        }
        starved = starvation_invariant(queued, busy, online) and eligible
        if starved and confirm_s > 0:
            time.sleep(confirm_s)
            pool, queued = sample()
            busy = sum(1 for e in pool.values() if e.busy)
            online = sum(1 for e in pool.values() if e.online)
            measured = {"queued": queued, "busy": busy, "online": online}
            eligible, why, age = decide(pool, queued, busy, online)
            seen = {
                "queued": queued,
                "busy": busy,
                "online": online,
                "eligible": eligible,
                "why": why,
                "queue_age_s": age,
            }
            starved = starvation_invariant(queued, busy, online) and eligible
    except Unmeasurable as exc:
        out: dict[str, object] = {"state": "unmeasured", "detail": str(exc)}
        # ⛔ `seen` IS THE COMPLETE PICTURE (counts AND the eligibility answer); `measured` is the
        # subset that survives when the AGE read inside `decide()` refused. Publishing the latter is
        # what keeps `--json` honest on that path — `seen` alone was the reason the depth went absent.
        if measured:
            out.update(measured)
        if seen:
            out.update(seen)
            out["confirm_error"] = str(exc)
        return out
    return {
        "state": "starved" if starved else "ok",
        "queued": seen["queued"],
        "busy": seen["busy"],
        "online": seen["online"],
        "eligible": seen["eligible"],
        "why": seen["why"],
        "queue_age_s": seen["queue_age_s"],
        "invariant": "queued>0 AND busy==0 AND online>0",
    }


# The gate records its decision as ONE BARE WORD in this file (`ci_runner_gate.sh:40` STATE_DIR,
# `:395` the write — ON TRANSITION ONLY, which is why a record has no "freshness").
GATE_STATE_NAME = "ci-runner-gate.state"
# The launchd job that actually runs the gate (`templates/launchd/com.tortoise.ci-runner-gate.plist`,
# farmed by `pi-bootstrap/setup.sh`). It is macOS-only and nothing schedules the gate on a cell.
GATE_JOB_LABEL = "com.tortoise.ci-runner-gate"


def gate_scheduler_present() -> bool:
    """Does THIS box run the fallback gate on a schedule?

    ⛔ THIS IS WHAT MAKES A STALE RECORD HARMLESS (review finding P1). The gate writes its mode only
    when the mode CHANGES (`ci_runner_gate.sh:392-395`), so the file has no freshness of its own: one
    hand-run of the gate on a cell during incident triage writes `local`, the gate never runs there
    again, and that word would arm `ubuntu-latest` on every later repair FOR EVER — the fallback-only
    incident (`ci_runner_gate.sh:7-10`: jobs competing with the fleet, a local pytest run that
    crashed FalkorDB, 178 restarts) made permanent, and made to look deliberate.

    So the record is only evidence where the job that maintains it exists. Where it does not, this
    tool has no mandate to arm the fallback: it preserves whatever the gate set pool-wide and says
    that it could not enforce the floor.

    ⛔ THE RESIDUAL THIS FUNCTION CANNOT CLOSE, STATED RATHER THAN IMPLIED. On macOS the evidence is
    the INSTALLED PLIST (`templates/launchd/com.tortoise.ci-runner-gate.plist`); `launchctl disable`
    (or `unload -w`) switches that job off and leaves the plist in place, and the override database
    it writes is not readable without privileges — so a disabled job still answers "installed".
    What IS closed here is the mask (`ln -s /dev/null …`), which launchd also honours as "do not
    load". Resolving loadedness would need a probe that is unavailable on exactly the boxes this
    tool guards, and `docs/ops/controller-service.md`'s rule is that an unavailable probe must not
    turn a healthy box into a refusal — so the residual is named, and `gate_desired_mode`'s reason
    says the evidence was the file's presence.
    """
    override = os.environ.get("RUNNER_AUTOSCALE_GATE_SCHEDULER")
    if override is not None:
        return override.strip().lower() not in ("", "0", "false", "no")
    plist = account_home() / "Library" / "LaunchAgents" / f"{GATE_JOB_LABEL}.plist"
    plist_stat, plist_reason = _inspect_path(plist)
    if plist_reason is None and plist_stat is not None:
        if not (plist.is_symlink() and os.readlink(plist) == os.devnull):
            return True
        # MASKED: launchd refuses to load it (review finding P2 — the same mask rule as systemd).
    # An uninspectable plist is neither evidence nor its absence: fall through to the other arms.
    # ⛔ A UNIT FILE IS NOT A SCHEDULE EITHER (review finding P1). The first version tested a
    # SUBSTRING of every entry name, so `ci-runner-gate.service.bak` — the ordinary way a unit is
    # disabled by hand — and a MASKED unit (`ln -s /dev/null …`, systemd's own way) both read as
    # "scheduled". Either one turns a stale hand-run `local` record into a standing decision and
    # arms the fallback for ever, which is the exact failure this function exists to prevent. So:
    # the suffix must be a unit systemd LOADS (.service/.timer), and a mask is not a load.
    user_units = account_home() / ".config" / "systemd" / "user"
    try:
        for entry in user_units.iterdir():
            name = entry.name.lower()
            if "ci-runner-gate" not in name and "ci_runner_gate" not in name:
                continue
            if not name.endswith((".service", ".timer")):
                continue
            mask_stat, mask_reason = _inspect_path(entry)
            if mask_reason is not None:
                continue  # cannot look is not evidence either way for THIS candidate
            if mask_stat is None:
                continue  # a dangling symlink, or nothing there: not a loaded unit
            if entry.is_symlink() and os.readlink(entry) == os.devnull:
                continue  # MASKED: systemd refuses to load it, so it cannot maintain the record
            return True
    except OSError:
        pass  # no user unit directory is not an error: the gate may still be in a crontab
    try:
        proc = subprocess.run(
            [os.environ.get("RUNNER_AUTOSCALE_CRONTAB") or "crontab", "-l"],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    if proc.returncode != 0:
        return False
    # ⛔ A COMMENTED-OUT LINE IS NOT A SCHEDULE (review finding P1). Commenting a cron line out is
    # the standard disable, and the substring test read that comment as a live job — which armed
    # the fallback for ever on a box whose gate had been deliberately switched off.
    for line in (proc.stdout or "").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if "ci_runner_gate" in stripped:
            return True
    return False


def gate_desired_mode() -> tuple[str | None, str]:
    """`(mode, why)` — the mode `scripts/ci_runner_gate.sh` last wrote for this repo, and its source.

    ⛔ WHY THIS IS READ AND NOT DERIVED. Deriving the same answer here from the Actions status and
    the queue length would be a SECOND implementation of the gate's decision — the very thing
    `resolve_labels` refuses everywhere else ("one decision point") — and it would drift the first
    time the gate's threshold changed. The gate already states its will; this reads it.

    `None` is the honest answer in THREE different situations, and `why` says which — a reader who
    cannot tell "the gate says off" from "there is no gate here" cannot act on either:
      * no record at this path (a cell: nothing schedules the gate there),
      * a record, but no SCHEDULED GATE on this box (`gate_scheduler_present`),
      * a record holding something that is not a mode.
    """
    override = os.environ.get("RUNNER_AUTOSCALE_GATE_STATE")
    path = override or str(account_home() / ".pi" / "agent" / "state" / GATE_STATE_NAME)
    try:
        mode = Path(path).read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        # ⛔ ABSENCE IS THE NORMAL CELL STATE, AND IT IS NOT A READ FAULT (review finding P3).
        # "unreadable (No such file or directory)" sent an operator hunting permissions on a box
        # where nothing was ever meant to write the file — the very state this docstring's first
        # case describes. The two are now told apart in the words, not only in the sentences.
        return None, f"there is no gate record at {path} (nothing writes one here — a cell)"
    except OSError as exc:
        return None, f"the gate's record {path} is unreadable ({exc.strerror or exc})"
    if mode not in ("local", "github"):
        return None, f"the gate's record {path} holds {mode!r}, which is not a mode"
    if not gate_scheduler_present():
        return None, (
            f"the gate's record {path} says {mode!r}, but NOTHING SCHEDULES THE GATE ON THIS BOX "
            "(no launchd job, no systemd user unit, no crontab entry) — a hand-run record is not a "
            "standing decision, so the floor stays disarmed and labels are only PRESERVED"
        )
    return mode, f"the gate's record {path} (and a job that installs the gate IS present on this box)"


def pool_serves_fallback(pool: dict[str, PoolEntry]) -> bool:
    """Does ANY runner in the pool advertise the fallback label right now? (a POOL-WIDE reading)"""
    return any(FALLBACK_LABEL in e.labels for e in pool.values())


def _hosted_image_label(label: str) -> bool:
    """TRUE for a HOSTED image name (`ubuntu-latest`, `ubuntu-22.04`, …).

    ⛔ THIS FAMILY IS NOT THE GATE'S, SO ITS STRIP IS NOT GATED. `ci_runner_gate.sh:205` — "The one
    label this gate owns is `ubuntu-latest`" — and its `labels_for()` preserves every OTHER label as
    `extra` (`:220-224`), so nothing ever removes a mis-set `ubuntu-22.04` from the pool. It is THIS
    file's own invariant (see the header) that such a label must stay claimed by NO self-hosted
    runner: a runner claiming `ubuntu-22.04` makes a job asking for that HOSTED image run here instead,
    on a different OS — the "false PASS, not a delay" class.

    A label outside both families (`tier-gold`, a pool tag) is a custom label and is preserved
    untouched: dropping it would make the workflows that target it queue for ever.
    """
    return label.strip().lower().startswith("ubuntu-")


def _is_fallback_label(label: str) -> bool:
    """TRUE for the one label the GATE owns and arms — see `resolve_labels` for its shape."""
    return label.strip().lower() == FALLBACK_LABEL


def label_floor_binds(pool: dict[str, PoolEntry], gate_mode: str | None) -> bool:
    """TRUE when the GATE wants the fallback, a SCHEDULED gate maintains that record, and NO runner
    in the pool advertises the label.

    ⛔ This is a POOL-WIDE reading, not a per-runner one: the question is what the repo can serve,
    and `runs-on: ubuntu-latest` is matched against the pool, so one runner carrying the label is
    enough for the repo and zero is a total stop.

    ⛔ AND IT IS A REPAIR OF THE GATE'S INTENT, NEVER A SECOND OPINION (review finding P1). "No
    runner carries the label" alone is the gate's NORMAL, HEALTHY state — `fallback_off` removes it
    whenever GitHub-hosted is healthy — so a floor keyed on absence alone arms the label on a
    healthy box, on every repair, forever. The measured incident this floor exists for is the OTHER
    case: the gate WANTED `local` and no runner carried it (9 runners / 8 online / `busy=0` / 53
    queued), which is why the gate's mode is the first term.

    A `None` gate mode is not intent: with no state file (a cell that does not run the gate) the
    pool stays exactly as the gate left it, and `resolve_labels` says so in its note.
    """
    return gate_mode == "local" and not pool_serves_fallback(pool)


def resolve_labels(
    pool: dict[str, PoolEntry],
    machine: str,
    *,
    notes: list[str] | None = None,
    current: list[str] | None = None,
    gate_mode: str | None = None,
    gate_why: str | None = None,
) -> str:
    """The ONE place a label set is decided: what the runner already carries, then the floor.

    This mirrors `tools/install-ci-runner-x64.sh::resolve_labels` (the one registration path)
    instead of inventing a second rule, and it is `auto`: the gate's state is the source of
    truth, so a runner never acquires a permanent claim on the pool. An unknown architecture
    RAISES — `self-hosted`/`Linux`/`<ARCH>` are host-derived and may not be set, so there is no
    safe default to fall back to.

    `current` is the label set the runner carries in the pool RIGHT NOW (empty for a runner the
    pool does not list, i.e. ORPHANED). Preserving it is not a convenience: deriving a fresh set
    drops any custom/tier label, so the workflows that target it queue forever — a "repair" that
    removes capacity. The arch marker is re-derived from THIS box, never preserved (a mis-registered
    runner can carry the other arch's marker, and passing it back is a false PASS).

    ⛔ THE FLOOR (measured 2026-10-27, twice in one night; agent-infra#2589). The fallback label used
    to be granted only when some runner ALREADY advertised it — a condition it would itself create.
    A pool-wide restart therefore strips it everywhere (each registration reads a pool that no longer
    has it), CI stops assigning any job that says `runs-on: ubuntu-latest`, and the queue grows while
    every runner reads `online`. Measured: 9 runners / 8 online / `busy=0` / **53 runs queued**;
    adding the label through the API took the pool to `busy 8/8` in 20 s, and it EVAPORATED AGAIN
    (8/8 → 0/9) in ~20 min with no restart we issued. The API add is a bandage; REGISTRATION is the
    only durable path, so the label set written at registration must never leave the repo at zero.

    ⛔ AND THE FLOOR IS A UNION OVER `current`, NOT AN ALTERNATIVE TO IT. The first version of this
    function was only reached when there was nothing to preserve; a DEAD runner that is still IN the
    pool has labels to keep, so a re-registration could preserve `self-hosted-x64` alone and write a
    set with NO `ubuntu-latest` — the pool-wide-strip case the floor exists for, on the one path that
    runs after every restart. Keeping and flooring are two independent steps, and both always run.

    ⛔ WHICH RULE WINS WHEN THEY DISAGREE — THE GATE, ALWAYS, AND THE FLOOR ONLY REPAIRS IT. An
    earlier version of this docstring argued the opposite ("the floor always") on the grounds that
    a zero-label pool runs no workflow at all. That reasoning named a real incident but drew the
    wrong conclusion from it: it is TRUE in the gate's healthy state, which is exactly when arming
    the label re-opens the incident `ci_runner_gate.sh:12` records. The floor's real job is the
    measured case where the gate ALREADY wanted `local` and the label was gone, so `gate_mode` is
    its first term and "no runner carries it" its second.

    `notes` is where the one-line reason goes. It is a parameter, not a `print`, because
    `--json` prints the record as a single object on stdout: a bare `print` from here corrupted the
    machine-readable record for every fleet consumer (measured by driving `--json` through a
    floor-binding registration).
    """
    arch = ARCH_LABEL.get(machine.lower())
    if not arch:
        raise Unmeasurable(
            f"unknown architecture {machine!r}: cannot derive a label set "
            "(self-hosted/Linux/<ARCH> are host-derived and may not be set)"
        )
    kept = _preserve_labels(list(current or ()), machine)
    labels = [x for x in kept.split(",") if x] or [arch]
    floor = label_floor_binds(pool, gate_mode)
    engaged = fallback_engaged(pool)
    lacks = not pool_serves_fallback(pool)
    reason: str | None = None
    if floor and not engaged and FALLBACK_LABEL not in labels:
        reason = (
            f"label floor: the gate wants `{gate_mode}` and no runner in the pool "
            f"({len(pool)} registered) advertises {FALLBACK_LABEL} — this registration repairs "
            f"that, otherwise nothing can serve `runs-on: {FALLBACK_LABEL}` while GitHub-hosted is "
            f"unhealthy"
        )
    elif lacks and not engaged and gate_mode != "local":
        # ⛔ SAID OUT LOUD, not silently skipped: an operator who expected the floor to arm it must
        # be able to read WHY it did not, from the record, on the pass where it mattered. `gate_why`
        # carries the distinction that matters — "the gate says github" is a decision, "there is no
        # gate on this box" and "a hand-run record with nothing scheduling it" are not.
        reason = (
            f"label floor NOT armed: no runner in the pool ({len(pool)} registered) advertises "
            f"{FALLBACK_LABEL} — {gate_why or 'no gate record was consulted'}"
            + (
                f" and its mode is `{gate_mode}`"
                if gate_mode
                else " and it records NO USABLE MODE"
            )
            + " — the pool serves CI "
            "only while GitHub-hosted is unhealthy (ci_runner_gate.sh:12)"
        )
    if reason:
        if notes is not None:
            notes.append(reason)
        else:
            print(f"  · {reason}", flush=True)
    # `dict.fromkeys` keeps order and makes a DOUBLE-ADD unrepresentable, whichever arm asked for it:
    # the pre-floor code could write `ubuntu-latest` twice (once preserved, once from the gate), and
    # a repeated label is a `config.sh` argument GitHub rejects.
    if floor or engaged:
        labels.append(FALLBACK_LABEL)
    # ⛔ TWO FAMILIES, TWO SCOPES — THEY MUST NOT SHARE ONE `if` (review finding P1, round 14).
    #
    # (1) `ubuntu-<version>` other than the fallback is NOT a label the gate owns: `ci_runner_gate.sh`
    #     says so itself (`:205` "The one label this gate owns is `ubuntu-latest`") and its
    #     `labels_for()` preserves every other label as `extra`, so NOTHING ever removes a mis-set
    #     `ubuntu-22.04` — not the gate, and (before this term) not this tool either. So it is stripped
    #     in EVERY mode, because this file's own invariant (see the header) is that a hosted image name
    #     stays claimed by NO self-hosted runner: under `local` the box is ACTIVELY serving, so a job
    #     for that hosted image would run here on another OS, and under `None` (a cell — no gate runs
    #     there at all) nothing else will ever clean it up.
    #     ⛔ It cannot fight the floor: the floor only ever ADDS the fallback label.
    # (2) The FALLBACK label is the gate's, so its strip is scoped to a READABLE, SCHEDULED `github`
    #     record — the long note below has the measurement and the reasoning. `local` keeps what it has
    #     (the floor owns arming there) and `None` is not intent (the pool stays as the gate left it).
    hosted = list(
        dict.fromkeys(
            x for x in labels if _hosted_image_label(x) and not _is_fallback_label(x)
        )
    )
    if hosted:
        labels = [x for x in labels if x not in hosted] or [arch]
        hosted_reason = (
            f"{', '.join(hosted)} is REMOVED from this registration rather than preserved: a "
            "self-hosted runner claiming a HOSTED image name makes a job that asked for that image "
            "run here instead, on a different OS — and no gate owns this label, so nothing else "
            "would ever remove it"
        )
        if notes is not None:
            notes.append(hosted_reason)
        else:
            print(f"  · {hosted_reason}", flush=True)
    # ⛔ THE GATE WINS OVER EVERYTHING ABOVE, INCLUDING OVER WHAT THE RUNNER ALREADY CARRIES AND
    # OVER THE ENGAGEMENT ARM (review finding P1, round 13). Preservation is unconditional, so a
    # repair in the window between the gate recording `github` and its own `fallback_off` wrote
    # `ubuntu-latest` STRAIGHT BACK into `config.sh --labels` (measured: gate_mode="github",
    # current=["self-hosted-x64", "ubuntu-latest"] -> the same set back, and NO note). That is the
    # defect this floor exists to prevent, reached through the other door: the gate strips the
    # label, every repair re-adds it, and the two timers fight once per transition — while
    # `runs-on: ubuntu-latest` work lands on this box and competes with the agent fleet
    # (`ci_runner_gate.sh:12` records the cost: a local pytest run crashed FalkorDB, 178 restarts).
    # ⛔ THE `engaged` ARM IS UNDONE HERE TOO, DELIBERATELY: "the pool still advertises it" is the
    # pre-`fallback_off` window, and `github` is the gate's answer about that window — not a second
    # opinion about the pool's current contents.
    if gate_mode == "github":
        # Deduped: `labels` can hold the same label twice at this point (preserved AND appended by
        # the engagement arm), and a note that says `ubuntu-latest, ubuntu-latest` reads as a bug.
        gate_owned = list(dict.fromkeys(x for x in labels if _is_fallback_label(x)))
        if gate_owned:
            labels = [x for x in labels if not _is_fallback_label(x)] or [arch]
            dropped_reason = (
                f"the gate records `github`, so {', '.join(gate_owned)} is REMOVED from this "
                "registration rather than preserved: the pool serves CI only while GitHub-hosted "
                "is unhealthy (ci_runner_gate.sh:12), and re-writing it here would fight the "
                "gate's own fallback_off once per repair"
            )
            if notes is not None:
                notes.append(dropped_reason)
            else:
                print(f"  · {dropped_reason}", flush=True)
    return ",".join(dict.fromkeys(labels))


# ── actions ───────────────────────────────────────────────────────────────────────────────────
def _run_split(cmd: list[str], timeout: int = 300) -> tuple[int, str, str]:
    """ONE spawn, TWO streams KEPT APART.

    ⛔ A MERGED STREAM CANNOT ANSWER "WHICH LINE IS THE VALUE" (review finding P2, round 12). `_run`
    concatenates stdout THEN stderr, so the LAST line of the merged text is stderr's whenever stderr
    is non-empty — and `registration_token()` read exactly that line as the token. One advisory line
    on stderr (`gh: warning: this token expires in 1 hour`) turned a SUCCESSFUL mint into a token
    `config.sh` rejects, so the repair path raised `ActionFailed` on every pass and blamed the
    runner's own tooling. The caller that has a VALUE to read must get the stream it is on.
    """
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError) as exc:
        return 127, "", str(exc)
    return proc.returncode, (proc.stdout or ""), (proc.stderr or "")


def _run(cmd: list[str], timeout: int = 300) -> tuple[int, str]:
    """The merged-stream form, for the callers whose ONLY question is the exit status."""
    rc, out, err = _run_split(cmd, timeout)
    return rc, ((out or "") + (err or "")).strip()


def _sudo_prefix() -> list[str]:
    return [] if os.environ.get("RUNNER_AUTOSCALE_NO_SUDO") == "1" else ["sudo", "-n"]


def _systemctl(args: list[str]) -> list[str]:
    binary = os.environ.get("RUNNER_AUTOSCALE_SYSTEMCTL") or (
        shutil.which("systemctl") or "systemctl"
    )
    return [*_sudo_prefix(), binary, *args]


def restart_runner(runner: LocalRunner) -> tuple[bool, str]:
    """Restart a runner's service unit. NEVER called on a BUSY runner (the caller decides)."""
    rc, out = _run(_systemctl(["restart", runner.unit]), timeout=180)
    return rc == 0, f"systemctl restart {runner.unit} rc={rc} {out[:200]}"


# ── the pool read that races our own restart (fix 3, measured on cell 4) ─────────────────────────
# THE MEASURED VERDICT: `action-failed` / `unverified_cause=pool-read-after-restart`, with the log line
# "restart succeeded but the pool could not be READ" — and no reason. Failing closed is right; aborting
# the pass on ONE transient read, and not saying WHY, is not: the read races a restart THIS PASS issued
# (the runner is reconnecting, the API is briefly unhappy), so a single blip was enough to end the pass
# with the box's state unknown.
# ⛔ AND THE FIX IS NOT "RETRY EVERYTHING". A 404 is DETERMINISTIC — one real cause measured tonight
# was a unit with no repo, so the call was `gh api repos//actions/runners` → 404, and retrying that is
# three times the latency for the same answer. Only NETWORK/5xx/RATE-LIMIT markers are retried;
# everything else is raised at once, carrying gh's own words.
TRANSIENT_POOL_MARKERS = (
    "i/o timeout",
    "dial tcp",
    "connection reset",
    "connection refused",
    "tls handshake timeout",
    "server misbehaving",
    "unexpected eof",
    "eof",
    "temporary failure in name resolution",
    "no such host",
    "context deadline exceeded",
    "broken pipe",
    "rate limit",
    "secondary rate limit",
    "http 429",
    "http 500",
    "http 502",
    "http 503",
    "http 504",
)


def pool_error_is_transient(message: str) -> bool:
    """Is this pool-read failure worth ONE more attempt? A deterministic error is not."""
    low = (message or "").lower()
    return any(marker in low for marker in TRANSIENT_POOL_MARKERS)


def _env_int(name: str, default: int, minimum: int | None = None) -> int:
    """`RUNNER_AUTOSCALE_*` as an int, or `Unmeasurable` NAMING the seam (review finding P1).

    ⛔ A SEAM THAT COULD NOT BE PARSED USED TO KILL THE PASS WITH A TRACEBACK. `int(os.environ.get(…)`
    raises ValueError, `main()` caught only `Unmeasurable`, so the process exited 1 with a stack trace
    and `_log()` was never called: a scheduled pass that may ALREADY have restarted and re-registered
    runners left NO record of what it did — the exact "a scheduled pass that dies with no cause" this
    file's fix 3 was written to end. Two of these four seams were first parsed inside the starvation
    probe, i.e. AFTER the repair and fill steps.

    ⛔ AND THE RANGE IS CHECKED, NOT ONLY THE SYNTAX (review finding P2). `-1` parses, and then
    `max(1, tries)` silently reduces a bounded retry to one attempt, `max(0, timeout_s)` turns "wait
    for online" into a single read — sending a reconnecting runner straight to
    `register(..., replace=True)` — and `time.sleep(-5)` raises. The precedent one screen away is the
    starvation-confirm seam, which refuses `nan`/`-5`/`inf`/`0` for exactly this reason.
    """
    raw = os.environ.get(name)
    if raw is None or not raw.strip():
        value = default
    else:
        try:
            value = int(raw.strip())
        except ValueError as exc:
            raise Unmeasurable(
                f"{name}={raw!r} is not an integer — refusing to run with an unreadable seam"
            ) from exc
    if minimum is not None and value < minimum:
        raise Unmeasurable(
            f"{name}={raw!r} is below {minimum} — that would disable or invert the bound it feeds, "
            "so it is refused rather than quietly applied"
        )
    return value


def _env_float(name: str, default: float, minimum: float | None = None) -> float:
    """The float sibling of `_env_int`, for the same two reasons."""
    raw = os.environ.get(name)
    if raw is None or not raw.strip():
        value = default
    else:
        try:
            value = float(raw.strip())
        except ValueError as exc:
            raise Unmeasurable(
                f"{name}={raw!r} is not a number — refusing to run with an unreadable seam"
            ) from exc
    if not math.isfinite(value) or (minimum is not None and value < minimum):
        raise Unmeasurable(
            f"{name}={raw!r} is not a finite value at or above {minimum} — refused rather than "
            "quietly applied to a bound"
        )
    return value


def read_pool_retrying(repo: str, *, attempts: int | None = None) -> dict[str, PoolEntry]:
    """`read_pool` with a BOUNDED retry for TRANSIENT failures, keeping the LAST error's own words.

    ⛔ The final message CONTAINS the gh error text. A verdict of `unmeasurable` that hides the cause
    is indistinguishable from "the tool is broken", which is how a lane ends up hand-rolling a runner
    count instead of fixing the unit's missing `--repo`.
    ⛔ BOUNDED, and the bound is short: this runs INSIDE a restart-recovery window, so an unbounded
    wait would outlive the very poll it is serving.
    """
    tries = (
        attempts
        if attempts is not None
        else _env_int("RUNNER_AUTOSCALE_POOL_READ_ATTEMPTS", 3, minimum=1)
    )
    backoff = _env_float("RUNNER_AUTOSCALE_RETRY_BACKOFF_S", 2.0, minimum=0.0)
    seen: list[str] = []
    for attempt in range(1, max(1, tries) + 1):
        try:
            return read_pool(repo)
        except Unmeasurable as exc:
            seen.append(str(exc))
            if not pool_error_is_transient(str(exc)):
                # Deterministic: DONE. Surfaced as-is, so `repos//actions/runners → 404` reads as what
                # it is — a broken unit invocation — instead of as a flaky network.
                raise
            if attempt < max(1, tries):
                time.sleep(max(0.0, backoff))
    raise Unmeasurable(
        f"pool unreadable after {max(1, tries)} attempt(s) — every one was transient: " + " | ".join(seen)
    )


def wait_online(repo: str, name: str, timeout_s: int, poll_s: int) -> tuple[str, str]:
    """Poll the pool for `name`. Returns (`online` | `offline` | `unverified`, detail).

    ⛔ THREE STATES, NOT A BOOL. A failed pool read is not evidence that the runner did not come
    back: folding it into `False` made the caller say "still offline" about something it never
    looked at, and act on that (re-register with `--replace`). `unverified` is a measurement
    failure and the caller must NOT act on it.
    ⛔ AND `unverified` CARRIES WHY. The detail is the last gh error text, retried the bounded way
    above, so the record says *404 repos//actions/runners* or *dial tcp …: i/o timeout* instead of
    the reasonless sentence that cost a whole merge window.
    """
    deadline = time.monotonic() + max(0, timeout_s)
    while True:
        try:
            if read_pool_retrying(repo).get(name, PoolEntry(name, "offline", False)).online:
                return "online", ""
        except Unmeasurable as exc:
            return "unverified", str(exc)
        if time.monotonic() >= deadline:
            return "offline", ""
        time.sleep(max(1, poll_s))


def registration_token(repo: str) -> str:
    """A one-hour registration token. Unreadable is `ActionFailed` — never a guess."""
    gh = gh_bin()
    if not gh:
        raise ActionFailed("gh is not on PATH (set RUNNER_AUTOSCALE_GH)")
    rc, out, err = _run_split(
        [
            gh,
            "api",
            "-X",
            "POST",
            f"repos/{repo}/actions/runners/registration-token",
            "--jq",
            ".token",
        ]
    )
    # ⛔ THE TOKEN IS THE LAST LINE OF **STDOUT** — never of stderr, and never a line that carries
    # whitespace inside it (`--jq .token` prints the value and nothing else). Reading the merged
    # stream meant any advisory `gh` wrote to stderr on an otherwise-good mint became the token, and
    # a token with a space in it is a `gh:` line, not a value. Both are refused here, naming what
    # was actually printed, so the failure is attributable to this call rather than to `config.sh`.
    token = out.strip().splitlines()[-1].strip() if out.strip() else ""
    if rc != 0 or not token or any(ch.isspace() for ch in token):
        raise ActionFailed(
            f"registration token mint failed rc={rc}: "
            f"stdout={out.strip()[:200]!r} stderr={err.strip()[:200]!r}"
        )
    return token


# ⛔ THE LOCAL STATE THAT MAKES `--replace` IMPOSSIBLE (fix 2, measured on cell 4). `config.sh`
# decides `--replace` is meaningless when its OWN config files are still on disk, and answers
# "Cannot configure the runner because it is already configured. To reconfigure the runner, run
# './config.sh remove' first." — so a runner whose registration was deleted SERVER-SIDE (the exact
# case `--replace` exists for: "Failed to create a session. The runner registration has been deleted
# from the server") could never be repaired by this tool. These are the three files `config.sh`
# honours; clearing them is the LOCAL half of a re-registration and needs no server authority.
_LOCAL_CONFIG_FILES = (".runner", ".credentials", ".credentials_rsaparams")
_ALREADY_CONFIGURED = "already configured"


def _clear_local_config(directory: Path) -> dict[str, tuple[int, bytes]]:
    """Remove the runner's local config, returning (MODE, bytes) so a FAILED re-registration can put
    it back exactly as it was.

    ⛔ Safe only where it is called from: `register()` is reached for DEAD and ORPHANED installs
    only — the classifier never repairs a BUSY, SERVING or OTHER-REPO runner — so nothing that may
    be serving a job loses its credentials.
    ⛔ And it is STASHED, not just deleted: if the re-registration then fails (no network, a spent
    token), the install would otherwise lose its `.runner`, become invisible to `discover()` — which
    requires it — and look FREE to the provisioner, which sends the next pass down the "fresh
    install" path instead of retrying the same repair.
    ⛔ THE MODE IS STASHED TOO. `.credentials_rsaparams` is the runner's RSA PRIVATE key and
    `config.sh` writes both credential files 0600; restoring with a plain `write_bytes` would
    recreate them 0644 (world-readable) on a shared cell — a silent privilege widening on exactly
    the failure leg this function exists to make safe. Measured by the suite (T5).
    ⛔ A CLEAR THAT FAILS PARTWAY RESTORES WHAT IT ALREADY TOOK. Unlinking is sequential, so an
    `OSError` on a later file (EACCES on a 000 `.credentials`, say) must not leave the install
    half-cleared — that is the same "install vanishes" state, reached from inside the guard.
    """
    stash: dict[str, tuple[int, bytes]] = {}
    try:
        for name in _LOCAL_CONFIG_FILES:
            path = Path(directory) / name
            if path.exists():
                stash[name] = (path.stat().st_mode & 0o777, path.read_bytes())
                path.unlink()
    except OSError as exc:
        lost = _restore_local_config(directory, stash)
        raise ActionFailed(
            f"cannot clear {directory}/{name} for re-registration ({exc})"
            + (
                f" — and {len(lost)} of {len(stash)} stashed config file(s) could NOT be put back "
                f"({'; '.join(lost)}), so this install may no longer be discoverable: check it "
                f"before the next pass adds a second one over the top"
                if lost
                else ""
            )
        ) from exc
    except BaseException as exc:
        # ⛔ A SIGNAL IS THE OTHER WAY THIS LOOP ENDS HALFWAY, AND IT IS NOT AN `OSError` (round-13
        # review finding P2). `_term_as_exit` raises `SystemExit`, which the `OSError` arm above does
        # not catch, so a SIGTERM landing between two `unlink()` calls would unwind PAST this function
        # and drop the stash it is holding — the install left with `.runner`/`.credentials` deleted, no
        # record of what they were, and no restore. Restore here and re-raise: the caller's own
        # `finally` still gets its unwind, and the files this loop already took go back first.
        # ⛔ AND A RESTORE THAT FAILS ON THIS PATH IS REPORTED, LIKE THE `OSError` ARM ABOVE
        # (round-13 review, 2nd round). `_restore_local_config` RETURNS its failures rather than
        # raising, so discarding the value would leave the install without `.runner`/credentials and
        # say nothing, while the process exits 143 as if the stash came back. The signal's exit code
        # is worth less than the record: an ENOSPC during a kill is exactly when an operator must be
        # told the install may no longer be discoverable.
        lost = _restore_local_config(directory, stash)
        if lost:
            raise ActionFailed(
                f"{exc} — AND {len(lost)} of {len(stash)} stashed config file(s) could NOT be put "
                f"back ({'; '.join(lost)}), so this install may no longer be discoverable: check it "
                "before the next pass adds a second one over the top"
            ) from exc
        raise
    return stash


def _restore_local_config(directory: Path, stash: dict[str, tuple[int, bytes]]) -> list[str]:
    """Put the stashed local config back, AT ITS ORIGINAL MODE, and RETURN what could not go back.

    ⛔ `os.open(..., mode)` RATHER THAN `write_bytes` + `chmod`. Written the naive way the file is
    created 0644 under the usual umask and only then narrowed, so (a) `.credentials_rsaparams` — the
    runner's RSA PRIVATE KEY — is world-readable for a window, and (b) if the `chmod` fails (EROFS, a
    foreign-owned mount) the swallowed error leaves it 0644 FOR EVER, silently. Creating it with the
    mode means there is no window and no second failure mode; `os.fchmod` keeps ANY stashed mode
    exact rather than trusting the umask.

    ⛔ AND A SHORT WRITE IS NOT A SUCCESS — the same argument, one level down (review finding P2,
    reproduced: a patched `os.write` returning 16 of 1,263 bytes left a TRUNCATED
    `.credentials_rsaparams` and raised nothing). A disk that fills mid-file makes `os.write` return
    FEWER bytes than asked and raise NOTHING, so the naive one-shot call silently truncates the RSA
    private key on exactly the box that is out of space — which is the state the disk arm exists for.
    The loop below writes until the whole buffer is out, and treats a zero/negative return as the
    failure it is.

    ⛔ AND A RESTORE THAT FAILS IS REPORTED, NOT `pass`-ED. Returning the problems (rather than
    swallowing them) lets the caller put "N of M config files could NOT be restored" into the
    `ActionFailed` it was already raising, so the record states BOTH facts. A silent failure here is
    the worst state this file knows: the install has lost `.runner` and its key, `discover()` stops
    seeing it, its slot reads FREE to the provisioner, and the same pass adds a SECOND install over
    the top.
    """
    problems: list[str] = []
    for name, (mode, data) in stash.items():
        path = Path(directory) / name
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
            try:
                os.fchmod(fd, mode)
                view = memoryview(data)
                while view:
                    written = os.write(fd, view)
                    if written <= 0:
                        raise OSError(
                            f"short write: {len(view)} of {len(data)} byte(s) left unwritten"
                        )
                    view = view[written:]
            finally:
                os.close(fd)
        except OSError as exc:
            problems.append(f"{name} could NOT be restored ({exc})")
    return problems


def _config_argv(cfg: Path, repo: str, token: str, name: str, labels: str, replace: bool):
    return [
        str(cfg),
        "--unattended",
        "--url",
        f"https://github.com/{repo}",
        "--token",
        token,
        "--name",
        name,
        "--labels",
        labels,
        "--work",
        "_work",
        *(["--replace"] if replace else []),
    ]


def register(directory: Path, name: str, repo: str, labels: str, replace: bool) -> str:
    """Register or RE-register an EXISTING install (`<dir>/config.sh`) and enable its unit.

    `--replace` is what makes an orphaned name reusable: the stale registration is adopted
    instead of a duplicate being created. `--unattended` is what makes it safe from a timer.

    ⛔ THE REPAIR PATH MUST BE ABLE TO REPAIR (measured on cell 4). With a registration deleted
    server-side, `--replace` was refused by the runner's own `config.sh` — "already configured" —
    because THIS TOOL never cleared the local `.runner`/`.credentials`. So the one case the repair
    exists for was the one it could not recover, on every pass, for ever. Two steps close it:
    clear the local config BEFORE configuring, and if a `config.sh` still refuses that way, clear
    again and retry ONCE with a fresh token (a refusal can leave `.runner` behind, and the first
    token may be spent by the attempt).
    """
    cfg = Path(os.environ.get("RUNNER_AUTOSCALE_CONFIG_SH") or (directory / "config.sh"))
    if not cfg.exists():
        raise ActionFailed(f"{cfg} does not exist — {directory} is not a runner install")
    # ⛔ THE HANDLER IS INSTALLED BEFORE THE DESTRUCTIVE STEP, NOT AFTER IT (round-13 review finding
    # P2). It used to be installed only once `_clear_local_config` had RETURNED, which left the
    # destructive step it exists to protect running under the OS DEFAULT disposition: a SIGTERM
    # landing during the unlink loop (systemd's `TimeoutStartSec` firing on a legitimate pass — see
    # `render_unit`) terminated the process where it stood, so no `finally` ran and the stash was
    # dropped mid-unlink. The install was left with `.runner`, `.credentials` and the RSA key
    # deleted, gone from `discover()`, its slot reading FREE to the provisioner — the exact state the
    # paragraph below says is prevented. The comment was right about the WINDOW and wrong about the
    # ORDER; the clear now runs INSIDE the guarded region below, so the `finally` covers it.
    # Restoring the previous disposition from that same `finally` is why this is safe to leave open
    # on every path; a non-main thread (the suite's in-process drivers) cannot install a handler, and
    # `_clear_local_config` is itself unwind-safe there.
    previous_sigterm = None
    stash: dict[str, tuple[int, bytes]] = {}
    # ⛔ THE CLEARED REGION IS EXCEPTION-SAFE (fix 2, round 2). `registration_token()` is evaluated
    # INSIDE this block, and it raises `ActionFailed` on any gh failure — a routine transient for a
    # tool that runs every few minutes. Restoring only on `rc != 0` left that raise to drop the stash,
    # so a failed token mint DESTROYED the install's `.runner` and its RSA key, `discover()` stopped
    # seeing it, its slot read FREE to the provisioner, and the same pass added a SECOND install over
    # the top (measured on the fixture: the directory kept `config.sh` alone and `--count 1` ran).
    # `registered` is set BEFORE `enable_unit`, so a unit failure still never writes the stale stash
    # back over the fresh config a successful re-registration just wrote.
    registered = False
    # ⛔ THE IN-FLIGHT FAILURE IS CAPTURED, NOT JUST CHAINED (review finding P2, round 3). Raising
    # the restore failure from the `finally` REPLACES the propagating exception, and NOTHING in this
    # tool ever prints a traceback: `converge` records `f"{c['name']}: {exc}"`, i.e. `str(exc)` alone.
    # So a comment claiming "the original failure is still chained" was wrong in the only place it
    # matters — the RECORD. Measured: a `config.sh` exiting 1 with `gh: HTTP 401: Bad credentials`
    # plus an unrestorable stash produced a problem line that named the restore failure and NOT the
    # 401, so an operator could no longer tell auth from transport from ENOSPC on the one path this
    # commit exists to make loud. `failure` carries it into the message below, so the record states
    # BOTH facts.
    failure: BaseException | None = None
    try:
        if replace:
            try:
                previous_sigterm = signal.getsignal(signal.SIGTERM)
                signal.signal(signal.SIGTERM, _term_as_exit)
            except (ValueError, OSError):  # not the main thread / unsupported — see the note above
                previous_sigterm = None
            stash = _clear_local_config(directory)
        rc, out = _run(
            _config_argv(cfg, repo, registration_token(repo), name, labels, replace), timeout=600
        )
        if rc != 0 and _ALREADY_CONFIGURED in out.lower() and replace:
            # ⛔ `and replace` IS LOAD-BEARING (review round 7). Clearing the local config and
            # re-running `config.sh` WITHOUT `--replace` does not adopt the registration — it creates
            # a NEW one and leaves the old one a ghost in the pool, which is the state #2892 exists
            # to clean up. So the heal is confined to the arm that has `--replace` to land it, and the
            # replace=False arm keeps raising the refusal its caller must resolve (a retired case
            # pinned exactly that; T4b pins it again on this path).
            # ⛔ The retry's stash is MERGED, not discarded: a refused configure can leave `.runner`
            # behind, and if the retry's clear takes it the restore below must still be able to put
            # the install back.
            for fname, entry in _clear_local_config(directory).items():
                stash.setdefault(fname, entry)
            rc, out = _run(
                _config_argv(cfg, repo, registration_token(repo), name, labels, replace),
                timeout=600,
            )
        if rc != 0:
            raise ActionFailed(f"config.sh for {name} rc={rc}: {out[-400:]}")
        registered = True
    except BaseException as exc:  # noqa: BLE001 — recorded, then re-raised: the `finally` needs it
        failure = exc
        raise
    finally:
        if previous_sigterm is not None:
            signal.signal(signal.SIGTERM, previous_sigterm)
        if not registered:
            lost = _restore_local_config(directory, stash)
            if lost:
                # ⛔ RAISED FROM THE `finally`, ON PURPOSE (review finding P2) — and it NAMES the
                # original failure, because that is the only part of it the RECORD will ever see
                # (see `failure` above). The restore failure is the fact a reader must not miss: the
                # install has lost the files that make it discoverable, so the next pass can add a
                # SECOND one over it. `from failure` keeps the chain for a human reading a traceback.
                raise ActionFailed(
                    f"{failure if failure is not None else f'{name} could not be re-registered'}"
                    f" — AND {len(lost)} of {len(stash)} stashed config file(s) could NOT be put "
                    f"back ({'; '.join(lost)}) — the install may no longer be discoverable, and its "
                    "slot can read FREE to the provisioner"
                ) from failure
    # ⛔ A REGISTERED RUNNER WITH NO ENABLED UNIT IS NOT LIVE. Configuring the unit used to be
    # best-effort, so a `svc.sh install` / `systemctl enable` failure still returned "registered",
    # the caller counted it as live and reported `converged` while no listener would ever start —
    # a false PASS on the tool's own exit-3 contract, and exactly the "runner disappears silently"
    # mode the unit exists to prevent.
    failures = enable_unit(directory, name, repo)
    if failures:
        raise ActionFailed(
            f"{name} registered but its service could not be enabled (it will not stay up): "
            + "; ".join(failures)
        )
    return f"registered {name} labels={labels}"


def _term_as_exit(signum, frame) -> None:
    """SIGTERM → `SystemExit`, so an interrupted pass still unwinds its `finally` blocks.

    ⛔ WHY A HANDLER AND NOT A `try/except`: SIGTERM's default disposition TERMINATES the process
    without running `finally`, which is exactly the case `register()`'s stash cannot survive. Raising
    `SystemExit` turns the signal into an ordinary unwind (exit code 128+n, as a shell reports a
    signalled child), and the only reason this is installed for the cleared window alone is that a
    broader handler would change how every OTHER interruption of the pass reports itself.
    """
    raise SystemExit(128 + signum)


def enable_unit(directory: Path, name: str, repo: str) -> list[str]:
    """Install/enable the systemd unit. Returns the FAILURES (empty = the unit is up).

    A registered runner without an enabled unit dies with the shell that started it, which is the
    "runner disappears silently" mode; a caller that ignores this returns `converged` over a
    runner that will never start, so every step's status is checked and reported.
    """
    unit = f"actions.runner.{repo.replace('/', '-')}.{name}.service"
    failures: list[str] = []
    svc = directory / "svc.sh"
    if svc.exists():
        rc, out = _run(
            [*_sudo_prefix(), str(svc), "install", os.environ.get("USER") or "root"], timeout=180
        )
        if rc != 0:
            failures.append(f"svc.sh install rc={rc} {out[-200:]}")
    rc, out = _run(_systemctl(["enable", "--now", unit]), timeout=180)
    if rc != 0:
        failures.append(f"systemctl enable --now {unit} rc={rc} {out[-200:]}")
    return failures


# ── THE CONVERGER'S OWN UNIT (fix 5) ─────────────────────────────────────────────────────────────
# ⛔ A UNIT WHOSE CWD IS TRANSIENT IS A COUNTDOWN, NOT A SCHEDULE. Measured incident: a hand-written
# unit on a cell carried `WorkingDirectory=/tmp/cell-wt-runnerauto2`; the cell reclaimed that worktree,
# and systemd failed the oneshot with `status=200/CHDIR` BEFORE it ran a line — every 10 minutes, for
# as long as the reclaim stood. The converger was dead while its job was to repair exactly that kind
# of degradation, and the only signal was a red unit nobody read. So the template pins a path that
# cannot be reclaimed, and an unusable path is REFUSED instead of written.
UNIT_BASENAME = "eldato-runner-autoscale"
REPO_PATTERN = re.compile(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+")
# ⛔ `/private/...` IS LISTED SEPARATELY, not as a nicety: on macOS `Path.resolve()` turns
# `/tmp` into `/private/tmp` and `/var/folders/...` into `/private/var/folders/...` (both are symlinks),
# so a list naming only the friendly spelling reports a temp directory as DURABLE — measured, that is
# exactly how the first version of this guard passed a `tempfile.mkdtemp()` workdir.
# Every unit TYPE whose processes systemd gives a working directory. `.service` alone is not the
# population that can fail at CHDIR.
UNIT_FILE_SUFFIXES = ("service", "socket", "path", "mount", "swap")
TRANSIENT_UNIT_PREFIXES = (
    "/tmp",
    "/var/tmp",
    "/run",
    "/dev/shm",
    "/var/folders",
    "/private/tmp",
    "/private/var/tmp",
    "/private/var/folders",
)


def account_home() -> Path:
    """The home `%h` resolves to for THIS pass.

    ⛔ A SEAM, NOT `Path.home()` ALONE (review finding P2, measured). `render_unit` writes `%h` and
    the audit must decide whether that path is USABLE — which depends on the account's home, i.e. on
    the box. Without a seam the acceptance suite could only measure the HOME it happened to run
    under: on a cell (`HOME=/tmp/cell-home`) six cases went red about a CORRECT template — measured
    `PASS=23 FAIL=6` — and a red plain suite stops `--mutations` before it runs, so the suite's
    non-vacuity evidence was unavailable on exactly the boxes this tool exists for. This is the same
    treatment every other host fact here gets (`RUNNER_AUTOSCALE_MEMINFO`, `_PS`, `_DF`, `_SYSTEMCTL`).

    ⛔ IT DOES NOT CHANGE WHAT THE UNIT SAYS: `render_unit` still writes the literal `%h`, and
    systemd still expands it per-user. Only the CHECK follows the seam.
    """
    raw = os.environ.get("RUNNER_AUTOSCALE_HOME")
    return Path(raw).expanduser() if raw else Path.home()


def transient_path_problem(path_value: str) -> str | None:
    """The SHAPE half of `unit_workdir_problem`: is this path inside a tree a reclaim can take?

    ⛔ ONE IMPLEMENTATION, TWO CALLERS (a unit's `WorkingDirectory` and its `ExecStart` program). The
    prefix list is the whole decision, and two copies of it drift: the second would be the one that
    stays un-updated when a new transient root is measured.
    """
    real = Path(path_value).expanduser().resolve()
    for prefix in TRANSIENT_UNIT_PREFIXES:
        if str(real) == prefix or str(real).startswith(prefix + "/"):
            return (
                f"is inside {prefix} — a reclaim or a tmp cleaner removes it underneath the unit "
                "(measured: /tmp/cell-wt-runnerauto2 killed a converger for as long as the reclaim "
                "stood)"
            )
    return None


# ⛔ "COULD NOT LOOK" IS NOT "ABSENT", AND `pathlib` WILL NOT TELL YOU THE DIFFERENCE
# (review finding P1, measured). `Path.exists()` and `Path.is_dir()` return False only for the errnos
# `pathlib` names as absence (`_IGNORED_ERRNOS` = ENOENT, ENOTDIR, EBADF, ELOOP — read from the 3.12
# stdlib source); EVERY other OSError is RE-RAISED. Measured 2026-10-27: `--check-units` over ONE
# installed unit whose `WorkingDirectory` sat under a directory the auditing account cannot traverse
# (`/root/…` audited by a non-root account) exited 1 printing a PermissionError traceback and NO
# verdict — and this audit runs on EVERY pass (see `installed_unit_cwd_problems`), so a single such
# unit cost the pass its verdict, in silence. A path longer than PATH_MAX does the same
# (`OSError(ENAMETOOLONG)`), which is what the acceptance case uses because it needs no privileges.
#
# So the probe is `os.stat`, and the ABSENT arm is DELIBERATELY the same errno set `pathlib` ignores:
# nothing that used to read as absence changes meaning here, and only the previously-unhandled case
# becomes a NAMED problem. `(None, None)` = absent; `(None, reason)` = could not be inspected.
_ABSENT_ERRNOS = (errno.ENOENT, errno.ENOTDIR, errno.EBADF, errno.ELOOP)


def _inspect_path(path: Path) -> tuple[os.stat_result | None, str | None]:
    """`(stat, None)` when the path WAS inspected, `(None, reason)` when it could NOT be.

    Three answers, never two: present, absent, and "this check could not look" — the third is what
    `pathlib`'s boolean helpers silently lose by raising, and what every caller below must state in
    its own words instead of mistaking it for either neighbour.
    """
    try:
        return os.stat(path), None
    except OSError as exc:
        if exc.errno in _ABSENT_ERRNOS:
            return None, None
        return None, f"cannot be inspected ({exc.strerror or exc})"


def unit_workdir_problem(workdir: str | None) -> str | None:
    """None when `workdir` may be a unit's WorkingDirectory, else the reason it may not.

    `None` means the template's `%h` — the account's home, which systemd resolves per-user. It is
    checked by RESOLVING it (a container may hand out `HOME=/tmp/something`, and then the stable
    spelling points at a transient directory).
    """
    if workdir in (None, "", "%h"):
        workdir = str(account_home())
    else:
        # ⛔ AN EXPLICIT VALUE IS ONE ABSOLUTE PATH, ONE LINE — and nothing else:
        #   * a `%` is a systemd SPECIFIER, expanded at LOAD time. Validated here as a filesystem
        #     path it can pass (measured: `~/ra-%h-x` exists as a literal directory) and then resolve
        #     to a DIFFERENT, non-existent path inside systemd — the status=200/CHDIR class this fix
        #     exists to close, written by the fix itself. Only the `%h` default may carry one.
        #   * a newline injects an arbitrary systemd DIRECTIVE into a unit that runs as this account
        #     (measured: `--workdir "$HOME/x\nExecStartPre=/bin/false"` wrote that line into [Service]).
        #     A control character has no legitimate place in a path, so the whole class is refused.
        if "%" in workdir:
            return (
                f"WorkingDirectory={workdir!r} contains a systemd specifier (%) — it would be "
                "expanded at load time to a path this check never saw. Use a literal path, or the "
                "default (%h)"
            )
        if any(ch in workdir for ch in ("\n", "\r", "\0")) or any(
            ord(ch) < 32 for ch in workdir
        ):
            return (
                f"WorkingDirectory={workdir!r} contains a control character — that is a directive "
                "injection into the unit, not a path"
            )
    # ⛔ `Path.expanduser()` RAISES on a `~user` this account cannot resolve — `RuntimeError: Could
    # not determine home directory.` — while `os.path.expanduser` returns the argument unchanged
    # (review finding P1, round 12). `WorkingDirectory=~someone/x` is legal systemd syntax, and the
    # audit exists precisely to READ FOREIGN/HAND-WRITTEN units, so this is a reachable input: it
    # escaped the audit, landed in `main()`'s backstop AFTER the repair loop had acted, and exited 2
    # — "nothing was changed" — over a pass that had just destroyed and recreated a registration,
    # with the record losing `actions`. A path that cannot be resolved is a FINDING, not a crash.
    try:
        path = Path(workdir).expanduser()
    except RuntimeError as exc:
        return (
            f"WorkingDirectory={workdir!r} names a home directory this account cannot resolve "
            f"({exc}) — the unit's cwd is unmeasurable from here, which systemd answers with "
            "status=200/CHDIR before the unit runs a line"
        )
    if not path.is_absolute():
        return f"WorkingDirectory={workdir!r} is not an absolute path"
    # ⛔ THE SHAPE IS CHECKED FIRST, and the order is load-bearing: a path under /tmp that does not
    # exist YET is still a transient path, and reporting only "does not exist" would invite the
    # operator to mkdir it — which is exactly how the measured unit came to point at a directory a
    # reclaim later took. Shape first, then existence.
    shape = transient_path_problem(workdir)
    if shape:
        return f"WorkingDirectory={workdir} {shape}"
    probe, uninspectable = _inspect_path(path)
    if uninspectable:
        # ⛔ NEITHER "does not exist" (a claim about the world this check could not make) NOR
        # "usable" (the false PASS the audit exists to refuse): the named answer is that the path
        # could not be LOOKED AT. `install_unit` REFUSES on it — a unit whose cwd cannot be
        # confirmed is the 200/CHDIR stop with no verdict behind it.
        return (
            f"WorkingDirectory={workdir} {uninspectable} — this check cannot tell a usable "
            "directory from a missing one, so it will not certify it: systemd fails the unit with "
            "status=200/CHDIR before it runs a line, and 'I could not look' is not evidence that "
            "it will not"
        )
    if probe is None or not stat.S_ISDIR(probe.st_mode):
        return (
            f"WorkingDirectory={workdir} does not exist — systemd fails the unit with "
            "status=200/CHDIR BEFORE it runs a line, so the converger would silently stop"
        )
    return None


# ⛔ THE EXECUTABLE PREFIXES systemd accepts in front of the program (`@`, `-`, `:`, `+`, `!`, `!!`) —
# Table 2 of systemd.service(5). They are NOT part of the path, and reading them as one made the
# audit flag three of this box's own stock units (`@/usr/bin/dbus-daemon`, `-/sbin/agetty`,
# `!!/usr/lib/systemd/systemd-networkd`) the first time it learned to look at ExecStart.
EXEC_PREFIX_CHARS = "@-:+!"


def _exec_commands(values: list[str]) -> list[str]:
    """The commands systemd will actually run from every `ExecStart=` in load order.

    ⛔ `ExecStart=` ACCUMULATES; IT DOES NOT OVERRIDE (review round 2, verified against
    systemd.service(5): *"Commands may be specified by providing multiple command lines in the same
    directive, or alternatively, this directive may be specified more than once with the same effect.
    If the empty string is assigned to this option, the list of commands to start is reset"*). Reading
    only the LAST value — as `WorkingDirectory` is correctly read — reproduced the exact false PASS
    this check exists to close: a unit whose EARLIER `ExecStart` is transient audited CLEAN because a
    LATER one was durable, while the transient command still ran and still failed on every tick.
    """
    commands: list[str] = []
    for raw in values:
        value = raw.strip()
        if value == "":
            commands.clear()  # the documented RESET — the one way a later line removes an earlier one
            continue
        commands.append(value)
    return commands


def _split_exec_commands(command: str) -> list[str]:
    """`;`-separated commands inside ONE `ExecStart=` (quotes protect a `;` inside a path)."""
    parts: list[str] = []
    buf: list[str] = []
    in_quotes = False
    for char in command:
        if char == '"':
            in_quotes = not in_quotes
            buf.append(char)
        elif char == ";" and not in_quotes:
            parts.append("".join(buf))
            buf = []
        else:
            buf.append(char)
    parts.append("".join(buf))
    return [part.strip() for part in parts if part.strip()]


def _strip_exec_prefixes(token: str) -> str:
    index = 0
    while index < len(token) and token[index] in EXEC_PREFIX_CHARS:
        index += 1
    return token[index:]


def _exec_tokens(command: str) -> list[str]:
    return [quoted or bare for quoted, bare in re.findall(r'"([^"]*)"|(\S+)', command) if (quoted or bare)]


def _condition_skip(conditions: list[tuple[str, str]]) -> str | None:
    """The `Condition…=` line that makes systemd SKIP this unit, or None.

    ⛔ A CONDITIONALLY SKIPPED UNIT NEVER RUNS ITS PROGRAM, so a missing program is not a pending
    failure there: stock `rc-local.service` carries `ConditionPathExists=/etc/rc.local` and no such
    file, and reporting it as "fails 203/EXEC every tick" would page a human about a unit systemd
    deliberately does not start. Negated and specifier-bearing conditions are left alone (this cannot
    resolve them, and guessing is what this file refuses to do everywhere else).
    """
    for key, value in conditions:
        if value.startswith("!"):
            continue  # negated: the path's ABSENCE is what ENABLES the unit
        path = value.lstrip("-").strip()
        if "%" in path or not path.startswith("/"):
            continue
        probe, uninspectable = _inspect_path(Path(path))
        if uninspectable:
            # ⛔ THE DIRECTION MATTERS: this function's answer EXEMPTS a unit from the ExecStart
            # check, so reading "I could not look" as "the condition is unmet" would declare a unit
            # systemd may well start to be SKIPPED — a false PASS inside the audit itself. The
            # finding stays; a noisy finding beats a silent exemption.
            continue
        if probe is None:
            return f"{key}={value}"
    return None


def _exec_command_problems(unit_name: str, command: str) -> list[str]:
    """Findings for ONE command line: the program, then every absolute path it was given."""
    tokens = _exec_tokens(command)
    if not tokens:
        return []
    problems: list[str] = []
    program = _strip_exec_prefixes(tokens[0])
    if "%" in program:
        problems.append(
            f"{unit_name}: ExecStart program {program} uses a systemd specifier this check cannot "
            "resolve — verify it by hand"
        )
        return problems
    if program.startswith("/"):
        # ⛔ SHAPE FIRST, THEN EXISTENCE — the same order, and for the same reason, as the workdir
        # check: a `/tmp` program that happens to exist today is still a countdown, and reporting
        # only "does not exist" would invite `mkdir`-ing its way to a green audit.
        shape = transient_path_problem(program)
        if shape:
            problems.append(
                f"{unit_name}: ExecStart program {program} {shape} — after that the unit fails "
                "203/EXEC on EVERY tick, not 200/CHDIR"
            )
        else:
            probe, uninspectable = _inspect_path(Path(program))
            if uninspectable:
                problems.append(
                    f"{unit_name}: ExecStart program {program} {uninspectable} — this check "
                    "cannot tell a runnable program from a missing one, so it will not call the "
                    "unit usable"
                )
            elif probe is None:
                problems.append(
                    f"{unit_name}: ExecStart program {program} does not exist — systemd fails the "
                    "unit with 203/EXEC before it runs a line"
                )
    elif "/" in program:
        problems.append(
            f"{unit_name}: ExecStart program {program!r} is a RELATIVE path — systemd requires an "
            "absolute path (or a bare name, which it resolves through its own compile-time search "
            "path), so this unit cannot load"
        )
    # ⛔ A BARE NAME IS LEGITIMATE, never a finding: systemd resolves it through a fixed compile-time
    # search path, and its own documentation calls that safe for the standard directories. An earlier
    # version reported every one of them — 39 of the 51 findings on this box were `systemd-tmpfiles`,
    # `journalctl`, `udevadm` and friends, i.e. an audit nobody could ever clear.
    # The ARGUMENTS carry the same reclaim risk as the program (the pinned `__file__` is one), so
    # every absolute path it was given is judged too.
    reported = {program}
    for token in tokens[1:]:
        if not token.startswith("/") or token in reported:
            continue
        shape = transient_path_problem(token)
        if shape:
            reported.add(token)
            problems.append(
                f"{unit_name}: ExecStart names {token}, which {shape} — the unit starts and then "
                "fails on what it was told to run, which is the same silent stop with a different "
                "status (this is the shape `render_unit` writes: the program is durable, the SCRIPT "
                "is the checkout the installer ran from)"
            )
    return problems


def unit_exec_problems(
    unit_name: str,
    values: list[str],
    unit_type: str = "simple",
    conditions: list[tuple[str, str]] | None = None,
) -> list[str]:
    """Findings for a unit's `ExecStart` — the OTHER way a reclaim takes a scheduled tool down.

    ⛔ THE SAME RECLAIM CLASS AS `WorkingDirectory`, ONE UNIT STATUS LATER (measured, review round 7).
    `render_unit()` pins `sys.executable` and `Path(__file__).resolve()`, and `__file__` is the file
    in the CHECKOUT the installer ran from — on a cell that is a lane worktree under `/tmp`
    (`/tmp/cell-ai/.worktrees/…`), i.e. the exact directory `unit_workdir_problem` refuses to use as
    a cwd. After a reclaim the unit does not fail at CHDIR (`200/CHDIR`); it fails at EXEC
    (`203/EXEC`) on EVERY tick — the same silent death, and `--check-units` answered "all usable"
    for it, because it only ever read `WorkingDirectory`. Absence is never health: a unit whose
    PROGRAM is gone is not a scheduled converger.

    The population judged is the one systemd will actually run (see `_exec_commands`): every
    accumulated command for `Type=oneshot`, the first for any other type — where a SECOND command is
    itself a finding, because systemd refuses such a unit (`more than one ExecStart= setting is only
    allowed for Type=oneshot`).
    """
    commands = _exec_commands(values)
    if not commands:
        return []
    if _condition_skip(conditions or []):
        return []  # systemd skips this unit; nothing it would run is pending
    kind = (unit_type or "simple").strip()
    problems: list[str] = []
    if kind != "oneshot" and len(commands) > 1:
        problems.append(
            f"{unit_name}: {len(commands)} ExecStart= commands with Type={kind} — systemd refuses the "
            "unit ('more than one ExecStart= setting is only allowed for Type=oneshot'), so it never "
            "starts at all"
        )
    for command in commands if kind == "oneshot" else commands[:1]:
        for part in _split_exec_commands(command):
            problems.extend(_exec_command_problems(unit_name, part))
    return list(dict.fromkeys(problems))


# ⛔ TWO HIERARCHIES, TWO LOAD PATHS. The user manager and the system manager search DISJOINT
# directories, so `~/.config/systemd/user/x.service` and `/etc/systemd/system/x.service` are two
# different units that can never override one another. Merging them by bare name let a healthy copy
# in one hierarchy mask a broken copy in the other (measured), so the audit partitions by hierarchy.
USER_UNIT_DIRS = (
    "~/.config/systemd/user",
    "/etc/systemd/user",
    "/usr/lib/systemd/user",
)
SYSTEM_UNIT_DIRS = (
    "/etc/systemd/system",
    "/usr/lib/systemd/system",
)


def default_unit_dirs() -> list[str]:
    """Every audited unit directory, in SEARCH-PATH ORDER (highest priority first, per hierarchy).

    The seam replaces the whole population, which is what makes the audit hermetic.
    """
    raw = os.environ.get("RUNNER_AUTOSCALE_UNIT_DIR")
    if raw:
        return [raw]
    # EXPANDED, so the default population reads as absolute paths (a `~` in an audit report is a
    # path the reader has to resolve again, and one this tool already resolved for its own checks)
    return [str(Path(d).expanduser()) for d in (*USER_UNIT_DIRS, *SYSTEM_UNIT_DIRS)]


def unit_dir_hierarchy(directory: str) -> str:
    """`user` or `system` — which manager's load path `directory` belongs to.

    A seam directory (or anything unrecognised) is treated as `user`: it is a test/fixture root, and
    the ONLY thing the partition must guarantee is that one hierarchy cannot mask the other.
    """
    expanded = str(Path(directory).expanduser())
    for system_dir in SYSTEM_UNIT_DIRS:
        # EXACT or under a fixture root: a test cannot write to /etc, so a path that ENDS with one of
        # the system load paths is treated as the system hierarchy. Over-inclusive in the safe
        # direction (a misclassified directory can only add findings, never hide one).
        if expanded == system_dir or expanded.endswith("/" + system_dir.lstrip("/")):
            return "system"
    return "user"


def render_unit(
    repo: str,
    workdir: str | None = None,
    *,
    script: str | None = None,
    python: str | None = None,
    provisioner: str | None = None,
) -> dict[str, str]:
    """The unit PAIR as text: `<name>.service` + `<name>.timer`.

    ⛔ `%h`, NOT the script's own directory, is the default: this tool is often run from a working
    copy (a cell worktree, a lane checkout) and THAT is what a reclaim removes. `%h` is the account
    home — the one path the unit's own account always owns. An operator who wants something else
    passes `--workdir`, and then it is VALIDATED rather than trusted.
    ⛔ The interpreter and the script are ABSOLUTE and MEASURED (`sys.executable`, `__file__`), not
    guessed: `ExecStart=python3 ...` is not a PATH lookup, and a unit naming a different interpreter
    than the one that rendered it fails on its own version guard.
    """
    script = script or str(Path(__file__).resolve())
    python = python or sys.executable
    wd = workdir or "%h"
    service = "\n".join(
        [
            "[Unit]",
            "Description=Converge the self-hosted CI runner pool to this box's measured ceiling",
            f"Documentation=file:{script}",
            "After=network-online.target",
            "",
            "[Service]",
            "Type=oneshot",
            "# %h is the account's home: a reclaimed worktree can never take it away.",
            f"WorkingDirectory={wd}",
            # ⛔ THE PROVISIONER IS PINNED, not re-resolved by the schedule (review finding P1).
            # `%h` as the cwd kills the `$PWD/tools/…` candidate, so a scheduled pass resolved
            # nothing and the FILL half could never fire — see `resolve_provisioner`. The path is
            # the one the INSTALL measured, QUOTED because `systemd.exec(5)` expands specifiers in
            # `Environment=` and splits an unquoted assignment on whitespace, and VALIDATED by
            # `provisioner_problem` before it gets here. A pinned path that later moves surfaces as
            # the fill arm's own `ActionFailed`, which names the value it tried — see the note at
            # `--install-unit` about a transient one.
            *(
                [f'Environment="RUNNER_AUTOSCALE_PROVISIONER={provisioner}"']
                if provisioner
                else []
            ),
            # ⛔ QUOTED. systemd splits ExecStart on whitespace, so an unquoted script path or repo
            # containing a space yields a unit that fails on EVERY tick — a cron-style silent break of
            # the very schedule being installed (measured: `--repo o/r` + a positional, exit 2).
            'ExecStart="%s" "%s" --repo "%s"' % (python, script, repo),
            "Nice=10",
            "# A pass can legitimately run for many minutes (waits, reads, a provision), and systemd",
            "# will not start a SECOND instance of an active oneshot service — that is the mutual",
            "# exclusion this CLI keeps no lock for, so two passes can never repair one runner at once.",
            # ⛔ THE TIMEOUT MUST NOT BE SHORTER THAN A LEGITIMATE PASS (review finding P2, round 11).
            # 1800 s was picked to bound a wedged pass, but the pass's OWN bounds sum past it: the
            # provisioner alone carries `timeout=1800`, a DEAD runner adds up to 180 s of restart plus
            # a `wait_online` read (3 x 120 s), `config.sh` is 600 s and may run TWICE on the
            # already-configured retry, and each `svc.sh`/`enable` is 180 s. So systemd could SIGTERM a
            # healthy pass — and SIGTERM runs no `finally`, so a kill inside `register()`'s
            # clear → configure → restore window left the install with its `.runner` and RSA key
            # DELETED: invisible to `discover()`, and its slot reading FREE to the provisioner, which
            # then adds a second install over the top. 5400 s (90 min) is above that sum and still
            # bounds a wedge; the timer's 9 min cadence is unchanged, and a second instance still
            # cannot start while this one is active.
            "TimeoutStartSec=5400",
        ]
    )
    timer = "\n".join(
        [
            "[Unit]",
            "Description=Run the CI runner converger every ~9 minutes",
            "",
            "[Timer]",
            "OnBootSec=2min",
            "OnUnitActiveSec=9min",
            f"Unit={UNIT_BASENAME}.service",
            "",
            "[Install]",
            "WantedBy=timers.target",
        ]
    )
    return {f"{UNIT_BASENAME}.service": service + "\n", f"{UNIT_BASENAME}.timer": timer + "\n"}


def _systemctl_user(args: list[str]) -> list[str]:
    """`systemctl --user …` — NO sudo: `sudo` would target root's manager, not the unit's owner."""
    binary = os.environ.get("RUNNER_AUTOSCALE_SYSTEMCTL") or (
        shutil.which("systemctl") or "systemctl"
    )
    return [binary, "--user", *args]


def repo_problem(repo: str) -> str | None:
    """None when `repo` is a plain `owner/name`, else the reason it must not reach `ExecStart`.

    ⛔ `--repo` IS INTERPOLATED INTO A UNIT FILE, so it gets the SAME treatment as `--workdir`:
    unvalidated, a newline writes an arbitrary directive into `[Service]` (a unit that runs as this
    account, measured), a quote escapes the ExecStart quoting and silently re-points `--repo`, and a
    `%` becomes a systemd specifier expanded at load time. Quoting is not a substitute for validation
    — it is the second line, and a value that can close the quote defeats it.
    """
    if not REPO_PATTERN.fullmatch(repo or ""):
        return (
            f"--repo {repo!r} is not a plain `owner/name` (letters, digits, dot, dash, underscore) — "
            "it is interpolated into ExecStart, where a newline, a quote or a % becomes a directive "
            "or a specifier instead of a repository"
        )
    return None


def install_unit(
    repo: str, workdir: str | None = None, unit_dir: str | None = None
) -> list[str]:
    """Write the unit pair and enable its timer. Returns what was done; raises on refusal/failure.

    ⛔ WRITTEN IS NOT ENABLED. A unit file on disk with no timer running is exactly the false PASS
    this file refuses for runners ("registered but its service could not be enabled"), so the reload
    and the enable are steps whose status is checked and reported, never best-effort.
    """
    for problem in (repo_problem(repo), unit_workdir_problem(workdir)):
        if problem:
            raise UnitRefused(problem)
    # ⛔ RESOLVED AT INSTALL TIME AND PINNED INTO THE UNIT (review finding P1). Nothing is
    # downloaded here; this only decides whether the unit being written can GROW a box. Told loud
    # and NOT refused, for the same measured reason the transient-script warning below is not a
    # refusal: repair-only is still a useful schedule, and refusing would make `--install-unit`
    # unusable on a box that simply has no installer checkout.
    provisioner, provisioner_why = resolve_provisioner()
    bad = provisioner_problem(provisioner)
    if bad:
        raise UnitRefused(f"{bad} — refusing to write a unit whose provisioner cannot be read back")
    if provisioner and transient_path_problem(provisioner):
        # ⛔ WARNED, NOT REFUSED — the same call the transient-`script_dir` warning above makes, for
        # the same reason, and it is NOT optional here: `resolve_provisioner`'s second candidate is
        # `$PWD/tools/…`, and on a cell the checkout IS under /tmp (this file says so at
        # `render_unit`). So the NORMAL cell install pins a path a reclaim takes, and the operator
        # must be told at install time rather than discover it as `action-failed` every nine minutes.
        print(
            f"  · WARNING: the pinned provisioner {provisioner} is at a path a reclaim can take "
            f"({transient_path_problem(provisioner)}). The unit will audit 'all usable' and then "
            "record `no provisioner` on every pass after that reclaim; install from a durable "
            "checkout to schedule a box that keeps growing.",
            flush=True,
        )
    if not provisioner:
        # ⛔ THE REASON GOES INTO THE WARNING, and the advice is only given when it can help (review
        # finding P2). Told loud and NOT refused, for the same measured reason the transient-script
        # warning below is not a refusal: repair-only is still a useful schedule, and refusing would
        # make `--install-unit` unusable on a box that simply has no installer checkout. But an
        # uninspectable or absent seam is a DIFFERENT fact from "no installer on this box", and the
        # old text told the operator to set the variable that was already set.
        print(
            f"  · WARNING: no install-ci-runner-x64.sh resolved ({provisioner_why}), so this unit "
            "can REPAIR and RE-REGISTER but can never ADD a runner (every pass with live < target "
            "will record `no provisioner` → action-failed). Install from a checkout that carries "
            "tools/install-ci-runner-x64.sh, or point RUNNER_AUTOSCALE_PROVISIONER at a readable "
            "installer, to schedule a box that grows.",
            flush=True,
        )
    directory = Path(unit_dir or default_unit_dirs()[0]).expanduser()
    try:
        directory.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise ActionFailed(f"could not create {directory}: {exc} — NOTHING was written") from exc
    # ⛔ STAGED, NOT SPLICED, AND NOTHING INSTALLED IS EVER DESTROYED. Both temp files are written
    # first and only then renamed into place, so a failure before the first replace leaves the
    # installed pair untouched, and no branch ever unlinks a REAL path (a first version unlinked "what
    # it wrote", which on a re-install was the previously installed file — measured, and worse than
    # the problem it fixed). The two replaces are sequential, so a failure between them can still
    # leave a MIXED pair; the failure says exactly that rather than claiming a clean rollback.
    planned = render_unit(repo, workdir, provisioner=provisioner)
    # ⛔ WARNED, NOT REFUSED — and the difference is deliberate (review round 7). `ExecStart` pins
    # `Path(__file__).resolve()`, so a unit installed from a lane worktree names a path a reclaim
    # takes (on every cell the checkout IS under /tmp), and the tool acknowledges that in
    # `render_unit` itself: "this tool is often run from a working copy". Refusing would make
    # `--install-unit` unusable ON THE BOXES IT EXISTS FOR — a false block, which is a worse failure
    # than a documented one. So the operator is told loud at install time, `--check-units` REPORTS
    # the resulting unit (`unit_exec_problems`), and the scheduled pass never loses the finding.
    script_dir = os.path.dirname(str(Path(__file__).resolve()))
    script_shape = transient_path_problem(script_dir)
    if script_shape:
        print(
            f"  · WARNING: installing a unit whose ExecStart names this tool at {script_dir}, which "
            f"{script_shape}. The schedule will fail 203/EXEC once that path goes; install from a "
            "durable checkout (a clone outside /tmp) to schedule it permanently.",
            flush=True,
        )
    staged: list[tuple[Path, Path]] = []
    replaced: list[Path] = []
    try:
        for name, text in planned.items():
            path = directory / name
            tmp = directory / f".{name}.tmp"
            staged.append((tmp, path))  # BEFORE the write: a failed write must still be cleaned up
            tmp.write_text(text, encoding="utf-8")
            os.chmod(tmp, 0o644)
        for tmp, path in staged:
            os.replace(tmp, path)
            replaced.append(path)
    except OSError as exc:
        for tmp, _ in staged:  # ONLY the temp files: the real paths were never touched
            try:
                tmp.unlink()
            except OSError:
                pass
        when = (
            "nothing had been replaced yet"
            if not replaced
            else "already replaced: " + ", ".join(p.name for p in replaced)
        )
        raise ActionFailed(
            f"could not install the unit pair into {directory}: {exc} — {when}. No installed file "
            "was DESTROYED, but the pair may be MIXED (one new file, one from the previous install); "
            "the next successful run repairs it"
        ) from exc
    done = [f"wrote {path}" for _, path in staged]
    for args in (["daemon-reload"], ["enable", "--now", f"{UNIT_BASENAME}.timer"]):
        rc, out = _run(_systemctl_user(args), timeout=120)
        if rc != 0:
            raise ActionFailed(
                f"systemctl --user {' '.join(args)} rc={rc} {out[:200]} — the unit files are written "
                "but the install is INCOMPLETE: this tool did not verify whether a timer is "
                "scheduled now, so treat the schedule as UNKNOWN (a previously enabled timer for "
                "this unit may still be firing; one that was never enabled will not start)"
            )
        done.append(f"systemctl --user {' '.join(args)}")
    return done


def _unit_files(directory: Path, problems: list[str]) -> list[Path]:
    """Every file in `directory` (and its `*.d/` drop-in dirs) that can carry a WorkingDirectory.

    ⛔ `iterdir()` WITH AN ERROR PATH, not `glob()`. `Path.glob` swallows `PermissionError` and
    returns `[]`, so a drop-in directory this account cannot read reported as an EMPTY one — measured:
    a mode-000 `clean.service.d` holding a transient WorkingDirectory audited as CLEAN while the same
    content under a readable directory was caught. An unreadable directory is not an empty one.
    """
    try:
        entries = sorted(directory.iterdir())
    except OSError as exc:
        problems.append(f"{directory}: unreadable ({exc}) — NOTHING was audited there")
        return []
    files: list[Path] = []
    for entry in entries:
        name = entry.name
        # ⛔ EVERY ENTRY IS INSPECTED THROUGH `_inspect_path`, NOT ONLY THE DIRECTORY ITSELF (review
        # finding P2, round 11). `iterdir()` above got the error path; the PER-ENTRY probe did not, and
        # `Path.is_dir()` re-raises everything outside `pathlib`'s absence errnos — so a symlink into a
        # tree this account cannot traverse escaped `--check-units` AND the every-pass audit as a
        # PermissionError. On the pass path that is main()'s backstop: exit 2 with no `actions` field,
        # i.e. the record of a registration this pass already destroyed is the part that gets lost.
        stat_result, uninspectable = _inspect_path(entry)
        if uninspectable:
            # ⛔ FAIL CLOSED, AND KEEP IT IN THE POPULATION: a unit file we cannot stat is still a unit
            # someone installed, so it is REPORTED as unaudited and still handed to the audit (which
            # will say it could not be read) rather than dropped as if it were not there.
            problems.append(f"{entry}: {uninspectable} — NOTHING was audited there")
            if name.rsplit(".", 1)[-1] in UNIT_FILE_SUFFIXES:
                files.append(entry)
            continue
        if stat_result is not None and stat.S_ISDIR(stat_result.st_mode) and name.endswith(".d"):
            try:
                nested = sorted(entry.iterdir())
            except OSError as exc:
                problems.append(f"{entry}: unreadable ({exc}) — NOTHING was audited there")
                continue
            for child in nested:
                child_stat, child_uninspectable = _inspect_path(child)
                if child_uninspectable:
                    problems.append(f"{child}: {child_uninspectable} — NOTHING was audited there")
                files.append(child)
        elif name.rsplit(".", 1)[-1] in UNIT_FILE_SUFFIXES:
            files.append(entry)
    return files


def installed_unit_cwd_problems(
    unit_dirs: list[str] | None = None, *, require_any: bool = False
) -> list[str]:
    """Audit the INSTALLED units for the shape the template now refuses to create.

    ⛔ THIS IS THE OTHER HALF OF THE FIX. Refusing to WRITE a transient WorkingDirectory does nothing
    for the units already on the box — including the hand-written one that started this — so the
    existing population is read and any bad one is NAMED.

    ⛔ AND IT READS THE POPULATION THAT ACTUALLY DECIDES THE VALUE, not the convenient one:
      * DROP-INS (`<unit>.d/*.conf`) are read, and LAST ASSIGNMENT WINS is honoured — systemd applies
        the last `WorkingDirectory=` it sees. Reading only the main unit reported the measured
        incident shape as CLEAN; reporting EVERY assignment made the documented remedy (fix it with a
        drop-in) unable to ever clear the finding. So the audit keeps the LAST value per unit, in
        systemd's order: the unit file (the FIRST copy in search-path order wins), then its drop-ins
        by filename — and of two drop-ins with the SAME name, again the FIRST copy wins, because
        systemd skips an overridden file instead of merging it.
      * THE TWO MANAGERS ARE AUDITED SEPARATELY. `~/.config/systemd/user/x.service` and
        `/etc/systemd/system/x.service` are different units on disjoint load paths; merging them by
        name let a healthy copy in one hierarchy mask a broken copy in the other.
      * every unit TYPE whose processes systemd gives a working directory (`service`, `socket`,
        `path`, `mount`, `swap`) — a `*.service`-only glob reported a transient WorkingDirectory on a
        `.socket` as clean.
      * only the `[Service]` SECTION: a `WorkingDirectory=` under `[Unit]` is ignored by systemd, and
        reporting it would refuse something with no runtime effect.
      * a directory this cannot read, and (with `require_any`) an audit that finds NO unit files at
        all, are reported — an audit that read nothing must never print "all usable".
    ⛔ IT EVALUATES AS THE AUDITING ACCOUNT. `User=` is not resolved: a path this account can see and
    the unit's own account cannot is EACCES at CHDIR and is NOT reported here. Stated, not hidden.
    """
    problems: list[str] = []
    seen = 0
    # ⛔ ONE GROUP PER UNIT NAME, ACROSS EVERY AUDITED DIRECTORY — not one per directory. systemd
    # searches the whole unit load path, so a drop-in in a HIGHER-priority directory overrides a unit
    # defined in a lower one; grouping per directory meant the documented remedy (fix it with a
    # drop-in) could never clear a finding for exactly the user-level population this tool installs
    # into. The order below is systemd's: for a same-named unit file the FIRST directory in the
    # search path wins, and a unit's drop-ins come after it, by filename.
    groups: dict[tuple[str, str], list[Path]] = {}
    for base in unit_dirs or default_unit_dirs():
        root = Path(base).expanduser()
        # ⛔ AN UNREADABLE BASE IS NOT AN EMPTY ONE, AND NOT A TRACEBACK EITHER (review finding P2):
        # `root.is_dir()` re-raises EACCES/ENAMETOOLONG, so `--check-units` over a unit directory this
        # account cannot traverse exited 1 with a stack instead of the "NOTHING was audited" verdict
        # this audit promises. Measured with a 5000-character `RUNNER_AUTOSCALE_UNIT_DIR`.
        stat_result, uninspectable = _inspect_path(root)
        if uninspectable:
            problems.append(f"{root}: {uninspectable} — NOTHING was audited there")
            continue
        if stat_result is None or not stat.S_ISDIR(stat_result.st_mode):
            # Not a finding by itself — the aggregate guard below reports an audit that read nothing
            # (`require_any`), and it NAMES every directory it looked in.
            continue
        hierarchy = unit_dir_hierarchy(str(root))
        for path in _unit_files(root, problems):
            seen += 1
            if path.name.endswith(".conf"):
                # `<name>.service.d/x.conf` → the unit it overrides
                owner = path.parent.name[: -len(".d")]
            else:
                owner = path.name
            groups.setdefault((hierarchy, owner), []).append(path)
    for (hierarchy, owner), paths in sorted(groups.items()):
        last: tuple[Path, str] | None = None
        # ⛔ EVERY `ExecStart=` IN LOAD ORDER, plus what decides which of them RUN: the accumulation
        # rule and `Type=` are both in `unit_exec_problems`, because reading only the last value
        # reproduced the false PASS this check exists to close.
        exec_values: list[str] = []
        unit_type = "simple"
        conditions: list[tuple[str, str]] = []
        mains = [q for q in paths if not q.name.endswith(".conf")]
        # ⛔ A DROP-IN IS DE-DUPLICATED BY BASENAME, KEEPING THE FIRST — the higher-priority
        # directory's copy. systemd does not merge two files with the same name: it SKIPS the
        # lower-priority one (`conf-files.c::files_add`). Sorting by name alone left the LAST
        # occurrence (the lower-priority copy) as `last`, so a clean copy in a later directory masked
        # a bad one in an earlier directory — measured, and a failing user unit reported CLEAN.
        by_name: dict[str, Path] = {}
        for path in paths:
            if path.name.endswith(".conf"):
                by_name.setdefault(path.name, path)
        drops = sorted(by_name.values(), key=lambda q: q.name)
        # the FIRST main file in search-path order is the one systemd uses
        for path in ([mains[0]] if mains else []) + drops:
            try:
                text = path.read_text(encoding="utf-8", errors="replace")
            except OSError as exc:  # unreadable is NOT clean
                problems.append(f"{path.name}: unreadable ({exc})")
                continue
            section = ""
            for line in text.splitlines():
                bare = line.strip()
                if bare.startswith("[") and bare.endswith("]"):
                    section = bare[1:-1].strip()
                    continue
                if "=" not in line:  # systemd skips a valueless line; so must this
                    continue
                key, _, value = line.partition("=")
                if key.strip() == "WorkingDirectory" and section == "Service":
                    last = (path, value.strip())
                elif key.strip() == "ExecStart" and section == "Service":
                    # ⛔ APPENDED, NOT OVERWRITTEN — systemd ACCUMULATES ExecStart (only an empty
                    # `ExecStart=` resets the list), so a drop-in that ADDS a command does not remove
                    # the one below it. `WorkingDirectory` is the opposite, and it is kept that way.
                    exec_values.append(value.strip())
                elif key.strip() == "Type" and section == "Service":
                    unit_type = value.strip()
                elif section == "Unit" and key.strip().startswith("Condition"):
                    conditions.append((key.strip(), value.strip()))
        # ⛔ THIS RUNS BEFORE THE `last is None` EXIT: a unit with an ExecStart and no
        # WorkingDirectory is still a unit whose program a reclaim can take.
        if exec_values:
            problems.extend(unit_exec_problems(owner, exec_values, unit_type, conditions))
        if last is None:
            continue
        path, value = last
        tolerant = value.startswith("-")
        if tolerant:
            value = value[1:].strip()
        if "%" in value and value != "%h":
            problems.append(
                f"{path.name}: WorkingDirectory={value} uses a systemd specifier this "
                "check cannot resolve — verify it by hand"
            )
            continue
        problem = unit_workdir_problem(value)
        if problem is None:
            continue
        if tolerant:
            # `-` only SUPPRESSES the failure: the unit still starts, from whatever directory the
            # manager hands it. Saying "systemd fails this unit" would be false.
            problems.append(
                f"{path.name}: WorkingDirectory=-{value} — the leading `-` suppresses the "
                f"failure, so the unit will silently start in the WRONG directory ({problem})"
            )
        else:
            problems.append(f"{path.name}: {problem}")
    if require_any and seen == 0:
        problems.append(
            f"no unit files under {', '.join(unit_dirs or default_unit_dirs())} — that is "
            "'nothing was audited', NOT 'all usable'"
        )
    return problems


def _next_free_slot(root: str) -> int:
    """The first free slot in the provisioner's own numbering: base, base-2, base-3, ...

    Not `len(installs) + 1`. The numbering is repo-agnostic and this box carries installs that are
    NOT in it (`/opt/gh-runner-cell4-x64`, added by an ad-hoc lane), so a count over-counts and the
    next `--count` fills SEVERAL slots at once — the over-fill the ceiling forbids (round 5,
    finding 1). Walking the numbering for the first free slot makes one call one addition.

    ⛔ "OCCUPIED" MEANS ".runner PRESENT", NOT "the path exists" — that is the provisioner's own
    test (`[ ! -f "$d/.runner" ]`), and only that predicate keeps ONE call = ONE addition. A
    directory left behind by an interrupted download, or by a deregistered install, is invisible to
    `discover()` (which requires `.runner`) and FREE to the installer: calling it occupied skipped
    past it, so the single call filled the gap AND the requested slot — two runners where the
    ceiling allowed one, with the pass then reporting `over-ceiling` for a breach it had just
    created (round 6, finding 1).
    """
    base = Path(os.environ.get("RUNNER_AUTOSCALE_BASE") or (Path(root) / "gh-runner-x64"))
    index = 1
    while True:
        slot = base if index == 1 else Path(f"{base}-{index}")
        if not (slot / ".runner").exists():
            return index
        index += 1


def provisioner_problem(value: str | None) -> str | None:
    """None when `value` may be PINNED into the unit's `Environment=`, else why it may not.

    ⛔ THE SAME CLASS AS `--repo` AND `--workdir` (review finding P2). The value is interpolated into
    a unit file that runs as this account, and `systemd.exec(5)` says of `Environment=`: specifier
    expansion IS performed, and an unquoted assignment containing whitespace is split. So a `%` is
    expanded at load time to a path this check never saw, a space truncates the variable, and a
    newline becomes a new directive — a schedule that silently runs without its provisioner, which
    is the 200/CHDIR mistake one status class over. The rule is the workdir's, on the one value that
    reaches the unit file from the FILESYSTEM rather than from the operator.
    """
    if not value:
        return None
    if any(ch in value for ch in ("\n", "\r", "\0")) or any(ord(ch) < 32 for ch in value):
        return (
            f"the provisioner path {value!r} contains a control character — that is a directive "
            "injection into the unit, not a path"
        )
    if "%" in value:
        return (
            f"the provisioner path {value!r} contains a systemd specifier (%) — it is expanded at "
            "load time, so the schedule would run a path this check never saw"
        )
    if '"' in value:
        return (
            f"the provisioner path {value!r} contains a double quote — `Environment=` is quoted "
            "with them, so the value would escape its assignment"
        )
    if not value.startswith("/"):
        return (
            f"the provisioner path {value!r} is not absolute — the unit runs with "
            "`WorkingDirectory=%h`, so a relative path resolves somewhere nobody chose"
        )
    return None


def resolve_provisioner() -> tuple[str | None, str]:
    """`(absolute path, why)` — the installer this box may use, and HOW that answer was reached.

    ⛔ THE SECOND ELEMENT IS NOT DECORATION (review findings P1/P2). When the seam IS set and the
    path it names is absent or uninspectable, `None` alone made the caller say "set
    RUNNER_AUTOSCALE_PROVISIONER" — advice to set a variable that is already set, pointing at a
    value nobody named — and `--install-unit` wrote, pinned nothing, and reported `installed`. So
    every `None` carries the reason: which seam was consulted, what value it held, and what the
    probe found. The caller must print it.

    The installer is resolved, never assumed, and the candidate list spans the installed copy's
    neighbours, the working directory (the cell's checkout), and `~/.pi/agent/scripts`.

    ⛔ BUT THE SECOND CANDIDATE IS DEAD IN THE MODE THIS FILE SCHEDULES (review finding P1).
    `render_unit` writes `WorkingDirectory=%h`, so a scheduled pass runs with cwd = `$HOME` —
    `$HOME/tools/…` is not a checkout. Candidate 1 is a sibling of the module, and NO deployment
    puts the installer there (`pi-bootstrap/setup.sh`'s `fleet_srcs` is a flat list of script names
    in `~/.pi/agent/scripts`, and this installer is not one of them). So a scheduled box resolved
    nothing, recorded `no provisioner` → `action-failed` on every pass with `live < target`, and
    the FILL half — the half that makes a box grow — could never fire: an enforcer that can never
    fire, which is the exact failure this candidate list was written to avoid.

    The seed is what fixes it: `install_unit` resolves this ONCE, while the operator is standing in
    a checkout that does have `tools/install-ci-runner-x64.sh`, and PINS the absolute path into the
    unit's `Environment=` — so the schedule runs with the answer the install measured.
    """
    raw = os.environ.get("RUNNER_AUTOSCALE_PROVISIONER")
    candidates = (
        [raw]
        if raw
        else [
            str(Path(__file__).resolve().parent / "install-ci-runner-x64.sh"),
            str(Path.cwd() / "tools" / "install-ci-runner-x64.sh"),
            str(Path.home() / ".pi" / "agent" / "scripts" / "install-ci-runner-x64.sh"),
        ]
    )
    # ⛔ THE PROBE IS `_inspect_path`, NOT `Path(c).exists()` (review finding P2). This function is
    # called from `--install-unit`, which sits OUTSIDE `main()`'s backstop, so a candidate this
    # account cannot inspect (EACCES, ENAMETOOLONG) escaped as a traceback and exit 1 — the SAME exit
    # code as a deliberate REFUSAL. Measured: `--install-unit` with a 5000-character provisioner seam
    # printed an OSError stack and no REFUSED line.
    misses: list[str] = []
    for candidate in candidates:
        stat_result, uninspectable = _inspect_path(Path(candidate))
        if uninspectable:
            # ⛔ THE REASON IS KEPT, NOT DROPPED (review finding P2): "cannot be inspected" and
            # "is absent" are different facts about a seam the operator SET, and collapsing them
            # into "no installer resolved" is what made the printed advice wrong.
            misses.append(f"{candidate} {uninspectable}")
            continue
        if stat_result is not None:
            return candidate, "resolved"
        misses.append(f"{candidate} does not exist")
    if raw:
        return None, f"RUNNER_AUTOSCALE_PROVISIONER={raw!r} — " + "; ".join(misses)
    return None, (
        "no install-ci-runner-x64.sh found at any candidate — " + "; ".join(misses)
        if misses
        else "no install-ci-runner-x64.sh candidate could be evaluated"
    )


def provision(target_count: int) -> str:
    """Create/extend the install so that runners 1..target_count exist — via the ONE installer.

    ⛔ This file never downloads a runner binary and never builds a `config.sh` argv for a NEW
    install: download + sha256 verification + the headroom/arch guards are
    `tools/install-ci-runner-x64.sh`'s job (it is the only registration path). Absent, this
    REFUSES — improvising a provisioner here is how a second, divergent registration path is
    born (#9639 exists precisely because there was one).
    """
    provisioner, why = resolve_provisioner()
    if not provisioner:
        # ⛔ IT NAMES THE VALUE IT TRIED (review findings P1/P2). The old text printed a literal
        # `tools/install-ci-runner-x64.sh` and advised setting the seam — on the pinned-path-moved
        # deployment, where the seam IS set (in the unit's `Environment=`) and the value is the one
        # thing the operator needs. This is the diagnostic for the most likely failure of the pin.
        raise ActionFailed(
            f"no provisioner: {why} — a NEW runner cannot be created on this box (this script "
            "never downloads a runner binary). Repair/orphan paths still work; point "
            "RUNNER_AUTOSCALE_PROVISIONER (or the unit's `Environment=`) at a readable installer."
        )
    rc, out = _run(
        ["bash", provisioner, "--count", str(target_count), "--fallback", "auto"], timeout=1800
    )
    if rc == 2:
        # `install-ci-runner-x64.sh` publishes 2 as "GUARD REFUSED — nothing was attempted". That
        # is its own headroom guard declining, not this tool failing: reported as a REFUSAL in its
        # own words, so a scheduled pass does not cry failure every 10 minutes over a deliberate
        # no — and so the two predicates that disagree (its 2 GB+4 GB reserve vs this file's
        # measured 1.5 GB+2 GB, #9672) stay visible instead of being averaged away.
        raise ProvisionerRefused(f"rc=2 {out[-300:]}")
    if rc != 0:
        raise ActionFailed(f"provisioner --count {target_count} rc={rc}: {out[-400:]}")
    return f"provisioned to {target_count}: {out.splitlines()[-1][:200] if out else 'ok'}"


# ── the pass ─────────────────────────────────────────────────────────────────────────────────
def converge(
    repo: str,
    *,
    root: str = "/opt",
    want: int | None = None,
    dry_run: bool = False,
    nproc: str | None = None,
    meminfo: str | None = None,
    machine: str | None = None,
    online_wait_s: int | None = None,
    poll_s: int | None = None,
) -> dict:
    """One convergence pass: decide, then (unless dry_run) act. Raises Unmeasurable."""
    record: dict = {
        "repo": repo,
        "dry_run": dry_run,
        "actions": [],
        # ⛔ A HYPOTHETICAL IS NOT AN ACTION (review finding P1, round 12). `actions` is the record of
        # what this pass DID — the line a human reads to learn whether a registration was destroyed —
        # and a dry run used to append `would repair …` into it. That made `actions` non-empty on a
        # read-only pass, and the verdict chain below reads `actions` to distinguish `converged`
        # ("we acted and are at the target") from `at-ceiling` ("nothing to do"), so `--status` on a
        # box whose own classification said DEAD reported `verdict=converged`, exit 0 — while
        # printing `DEAD r-3` two lines above it. Two fields, two claims: what was done, and what a
        # real pass would do.
        "would_repair": [],
        "plan": [],
        "notes": [],
        "verdict": "",
        "problems": [],
    }
    ncpu = cores(nproc)
    mem_mb = mem_available_mb(meminfo)
    local = discover(root)
    pool = read_pool(repo)
    machine = machine or os.environ.get("RUNNER_AUTOSCALE_MACHINE") or os.uname().machine
    # ⛔ READ ONCE PER PASS, not once per runner: it is one file, and a pass that read it twice
    # could see the gate turn over between two repairs and arm the label on one runner but not the
    # next — a pool in two states, decided by iteration order.
    gate_mode, gate_why = gate_desired_mode()
    wait_s = _env_int(
        "RUNNER_AUTOSCALE_ONLINE_WAIT_S",
        online_wait_s if online_wait_s is not None else 60,
        minimum=0,
    )
    poll = _env_int(
        "RUNNER_AUTOSCALE_POLL_S", poll_s if poll_s is not None else 5, minimum=0
    )

    # 4. CLASSIFY ------------------------------------------------------------------------------
    classified: list[dict] = []
    for r in local:
        entry = pool.get(r.name)
        # ⛔ THE ORDER OF THESE BRANCHES IS THE SAFETY PROPERTY (review rounds 1–2).
        #  1. ANOTHER REPO first: `pool` is ONE repo's pool, so an install whose `.runner` names
        #     a different repo is simply ABSENT from it — indistinguishable from ORPHANED by the
        #     pool read alone. Treating that absence as ORPHANED re-registers it against `--repo`
        #     with `--replace`, which DELETES the other repo's registration and cancels whatever
        #     it is running. It is reported and never touched.
        #  2. A LIVE WORKER next: `_worker_alive` is a LOCAL process check, so it is valid for a
        #     runner the pool does not list at all — a listener that lost its broker connection
        #     can be executing while the API says nothing about it, and `--replace` would kill it.
        #  3. Only then the pool's own view.
        if _repo_slug(r.repo) != _repo_slug(repo):
            state = "OTHER-REPO"
        elif _worker_alive(r) or (entry is not None and entry.busy):
            state = "BUSY"
        elif entry is None:
            state = "ORPHANED"
        elif entry.online:
            state = "SERVING"
        else:
            state = "DEAD"
        classified.append(
            {
                "name": r.name,
                "dir": str(r.directory),
                "state": state,
                "pool_status": entry.status if entry else None,
                "busy": bool(entry and entry.busy),
                "labels": list(entry.labels) if entry else [],
                "repo": r.repo,
                "alive": r.alive,
            }
        )

    running = sum(1 for c in classified if c["alive"])
    # ⛔ AN UNREADABLE DISK IS NOT AN UNRUNNABLE PASS. Disk space is needed for ONE decision — whether
    # to ADD a runner — and the measured version of this file made it a precondition for the whole
    # pass: a failing `df` (or a `df` missing from a unit's PATH) exited 2 before the repair loop, so
    # a box with a DEAD runner was left unrepaired AND the starvation alarm (#2875) never ran, for as
    # long as the disk could not be read. Repair needs no disk figure. So: record it, refuse to FILL,
    # and carry on.
    try:
        disk_free_mb, per_runner_disk_mb, disk_reading = measure_disk(root)
    except Unmeasurable as exc:
        disk_free_mb = None
        per_runner_disk_mb, _basis = disk_footprint_mb(root)
        disk_reading = f"disk_UNVERIFIED ({exc})"
        record["disk_unverified"] = str(exc)
        record["notes"].append(
            f"disk NOT measured: {exc} — nothing will be ADDED this pass (an unmeasured disk is not "
            "permission to add), and repair/orphan handling and the starvation alarm still run"
        )
    ceil, bound, reading = ceiling(ncpu, mem_mb, running, disk_free_mb, per_runner_disk_mb)
    reading = f"{reading} {disk_reading}"
    record.update(
        ncpu=ncpu,
        mem_available_mb=mem_mb,
        disk_free_mb=disk_free_mb,
        per_runner_disk_mb=per_runner_disk_mb,
        bound=bound,
        ceiling=ceil,
        reading=reading,
        runners=classified,
        local=[{"dir": str(r.directory), "name": r.name} for r in local],
        pool_total=len(pool),
        pool_online=sum(1 for e in pool.values() if e.online),
        pool_busy=sum(1 for e in pool.values() if e.busy),
        # ⛔ BOTH LABEL FACTS ARE PUBLISHED, and they answer DIFFERENT questions: `fallback_engaged`
        # is "an ARM runner in the pool carries the fallback RIGHT NOW" (it requires the ARM marker,
        # so on an x64 pool it is False even when every runner carries the label — this description
        # used to claim otherwise), and `label_floor_binds` is "the gate wants `local`, NOTHING
        # schedules that gate question against a missing scheduler, and NO runner carries it" (a
        # repair owed on the next registration — the description used to say only "the GATE wants it
        # and NO runner carries it", which this delta's own `gate_scheduler_present` made too wide:
        # on a box where nothing schedules the gate the key is False EVEN THOUGH both clauses hold).
        # `gate_mode`/`gate_why` publish the decision the floor acted on, because "the gate says
        # github" and "there is no gate on this box" are different facts and neither is deducible
        # from the two booleans.
        fallback_engaged=fallback_engaged(pool),
        label_floor_binds=label_floor_binds(pool, gate_mode),
        gate_mode=gate_mode,
        gate_why=gate_why,
    )

    if want is not None and want > ceil:
        # ⛔ THE GUARD THE OWNER ASKED FOR, in its explicit-request form: nothing changes and the
        # reading that produced the refusal is printed.
        record["verdict"] = "refused"
        record["refusal"] = f"REFUSED: want={want} exceeds the measured ceiling {ceil} — {reading}"
        return record

    target = ceil if want is None else want

    # 5. REPAIR (DEAD / ORPHANED) — NEVER a BUSY, SERVING or OTHER-REPO runner ------------------
    # ⛔ `live` IS THE BOX TOTAL, MEASURED — not a count of our own repairs. `ceiling` is also a box
    # total (`running` includes every listener alive on this box, another repo's included, because
    # their memory is really gone from MemAvailable), so the fill decision must compare like with
    # like. Counting only OUR runners here made a box with one foreign listener add ceil−0 new ones
    # — 4 CI listeners where the owner's 8-core ruling allows 3 (round 2, finding 1). A repair does
    # not change the total (restart keeps one listener; re-registration keeps one) unless the
    # listener was actually gone, which is why only that case increments.
    live = sum(1 for c in classified if c["alive"])
    stop_pass = False
    # ⛔ ONE REGISTRATION PER NAME, PER PASS — AND THE SAME ONE ON EVERY PASS (review finding P2,
    # round 12). Two installs can share an `agentName` after a `cp -a` (the shape `discover()` is
    # written for), and the server holds ONE registration per name: two `--replace` calls in one pass
    # mean the second deletes the registration the first created seconds earlier, while the record
    # appends `registered r-dup` twice and `live` counts two listeners — two restored runners claimed
    # for one registration. Picking a different install each pass is no better: the pass that repairs
    # the other one destroys the working registration every 9 minutes. So the OWNER of a duplicated
    # name is the FIRST install in the order `discover()` returns (sorted, stable), it is repaired
    # normally, and every other install carrying that name is a REPORTED duplicate, never a repair
    # target. `name_owner` is derived from `local`, which is that same sorted list.
    by_name: dict[str, list[str]] = {}
    for r in local:
        by_name.setdefault(r.name, []).append(str(r.directory))
    duplicates = {name: dirs for name, dirs in by_name.items() if len(dirs) > 1}
    for c in classified:
        if c["state"] in ("SERVING", "BUSY", "OTHER-REPO"):
            # OTHER-REPO is reported and never repaired: it is not this repo's runner, so
            # `register(..., repo)` would move it here (`--replace` deletes the other repo's
            # registration). It still counts in `live` above — it occupies the box.
            continue
        # ⛔ THE RESTART COMMAND'S OUTCOME IS ITS OWN FACT, AND IT OUTLIVES THE DEAD-ONLY BRANCH
        # (review finding P1, round 11). Only a DEAD runner is restarted, but the ACTION LINE far
        # below has to say what the pool measured — and `None` here means "no restart was attempted",
        # which is a different claim from "the restart command failed".
        restart_ok: bool | None = None
        # ⛔ IDENTITY IS THE INSTALL, NOT THE NAME (review finding P2). Two installs can carry the
        # same `agentName` after a `cp -a` (the `.runner` file records ad-hoc installs of exactly
        # that shape), and `next(... name == ...)` then repaired the FIRST one on both iterations —
        # the second `--replace` deleting the registration the first had just created — while the
        # install that needed the repair was never touched and the record attributed the action to
        # it. `c["dir"]` is right there in the classified entry.
        runner = next((r for r in local if str(r.directory) == c["dir"]), None)
        if runner is None:  # a classified entry always came FROM `local`; this cannot drift silently
            runner = next(r for r in local if r.name == c["name"])
        if dry_run:
            record["would_repair"].append(f"would repair {c['name']} ({c['state']})")
            continue
        if c["state"] == "DEAD":
            ok, detail = restart_runner(runner)
            restart_ok = ok
            record["actions"].append(f"restart {c['name']}: {detail}")
            # ⛔ "we could not look" is NOT "it is still offline". An unreadable pool after a
            # restart proves nothing about the runner, and acting on it re-registers (with
            # --replace) a registration that may be reconnecting and picking up a job — the one
            # destructive action this file promises never to take blindly. Stop the PASS: the box
            # state is unknown from here, so no fill decision may be taken on a stale count.
            state, why = (
                wait_online(repo, c["name"], wait_s, poll) if ok else ("unasked", "")
            )
            if not ok:
                # ⛔ A FAILED RESTART COMMAND IS NOT EVIDENCE THE RUNNER IS OFFLINE (review finding
                # P1, round 11). `sudo -n systemctl restart` fails transiently on exactly the loaded
                # boxes this runs on (bus/dbus unavailable, manager busy), and the old code turned
                # that into `("offline", "")` — never asking the pool at all — then re-registered a
                # runner the pool could still be serving, and printed "still offline after restart"
                # about a question it never asked. The pool is asked below; this branch only records
                # that the command failed, so the pass's words match what it measured.
                record["notes"].append(
                    f"{c['name']}: the restart COMMAND failed ({detail}) — that is not a measurement "
                    "of the runner, so the pool is asked before anything destructive"
                )
            if state == "online":
                record["actions"].append(f"{c['name']} came back online after restart")
                continue
            if state == "unverified":
                record["unverified"] = True
                record["unverified_cause"] = "pool-read-after-restart"
                # ⛔ THE CAUSE IS THE VERDICT'S CONTENT. The retry already absorbed the transient
                # failures; what is left is either a DETERMINISTIC error (a unit with no `--repo`
                # calling `repos//actions/runners` → 404) or a persistent one (i/o timeout), and
                # only gh's own words distinguish them.
                record["unverified_detail"] = why
                record["notes"].append(
                    f"{c['name']}: restart succeeded but the pool could not be READ — {why} — "
                    "refusing to re-register on an unread pool, and stopping this pass (no fill "
                    "decision can be taken on an unknown count)"
                )
                stop_pass = True
                break
        # ⛔ A FRESH READ IMMEDIATELY BEFORE THE DESTRUCTIVE STEP (review finding P2). Everything
        # above judged this runner as of CLASSIFICATION; the act below deletes its registration, and
        # a whole `wait_online` timeout has passed since. `wait_online` re-reads the POOL only, and
        # the pool is the view that already called this runner offline — while the local listener
        # signal exists precisely because the API can say idle/offline about a box that is serving a
        # job. So the two facts are asked again, now, and `fresh=True` bypasses the classification
        # cache (a cached `False` would certify exactly what this refuses).
        # ⛔ THE POOL IS RE-READ, NOT RE-CHECKED IN THE SNAPSHOT (review finding P3). `pool` is the
        # pass-start view and every runner reaching here was classified with `busy=False`, so
        # `pool.get(...)` could only ever confirm what classification already decided — a test that
        # cannot fail. The pool's own `busy` is the AUTHORITATIVE flag in this file, so it is asked
        # again, now, seconds before the destructive step.
        try:
            refreshed = read_pool_retrying(repo).get(c["name"])
            alive = _worker_alive(runner, fresh=True)
            pool_busy = refreshed is not None and refreshed.busy
            # ⛔ ONLINE IS A SERVING STATE TOO (review finding P1, round 11). The guard used to ask
            # only `busy`, so a runner the POOL reports ONLINE — which is what the hub-side view says
            # about a runner that reconnected, and the ONLY pool-side fact available when the restart
            # command itself failed — was treated as "not serving" and `--replace`d. The destructive
            # step deletes a live registration; `online` is exactly what must stop it.
            pool_online = refreshed is not None and refreshed.online
            serving = alive or pool_busy or pool_online
        except Unmeasurable as exc:
            record["problems"].append(
                f"{c['name']}: NOT re-registering — {exc} — a busy state this pass could not read "
                "is not a busy state it may overwrite"
            )
            stop_pass = True
            break
        if serving:
            # ⛔ THE REASON IS THE FINDING (a `busy` and an `online` runner are different evidence, and
            # an operator reading why nothing was re-registered must not be told a job arrived when
            # what arrived was the runner itself).
            if alive:
                evidence = "came up with a JOB during the restart wait"
            elif pool_busy:
                evidence = "the pool reports it BUSY after the restart wait"
            else:
                evidence = "the pool reports it ONLINE after the restart wait"
            record["notes"].append(
                f"{c['name']}: {evidence} — NOT re-registering "
                "(a busy or online runner is never re-registered); it is re-judged next pass"
            )
            continue
        # ⛔ A DUPLICATE IS NOT A REPAIR TARGET (review finding P2, round 12) — see `duplicates`
        # above. Checked HERE, immediately before the destructive step and AFTER the serving checks,
        # so a duplicate the pool reports online still keeps its registration and still says why.
        if c["name"] in duplicates and c["dir"] != duplicates[c["name"]][0]:
            record["problems"].append(
                f"{c['name']}: NOT re-registering {c['dir']} — {len(duplicates[c['name']])} installs "
                f"carry this agentName ({', '.join(duplicates[c['name']])}) and the server holds ONE "
                "registration per name, so the second --replace would delete the registration the "
                f"first just created; {duplicates[c['name']][0]} is the install this tool repairs. "
                "Remove the duplicate install — until then this box cannot be converged"
            )
            continue
        # ⛔ THE ACTION LINE GOES AFTER THE CHECKS (review finding P3). It used to be appended before
        # them, so both new exits left `actions` claiming "re-registering with --replace" while
        # `notes` said the opposite — and `actions` is the line a human reads to learn whether a
        # registration was destroyed.
        # ⛔ AND IT NO LONGER CLAIMS A MEASUREMENT IT DOES NOT HAVE (review finding P1, round 11): when
        # the restart command FAILED, "still offline after restart" asserts an outcome of a restart
        # that may never have happened. The pool read is what says offline here, so that is what the
        # line names.
        record["actions"].append(
            (
                f"{c['name']} still offline after restart — re-registering with --replace"
                if restart_ok
                else f"{c['name']} the pool reports OFFLINE although the restart command failed — "
                "re-registering with --replace"
            )
        )
        try:
            # ⛔ ONE DECISION POINT, TWO INDEPENDENT STEPS. `resolve_labels` keeps the labels the
            # runner already carries AND applies the floor (see its docstring for why an "either/or"
            # was a defect: a DEAD runner in the pool has labels to keep, so the floor was never
            # reached on the path that runs after every restart). ⛔ PER RUNNER, never a value cached
            # from the previous iteration: that leaked one runner's set (including an other-arch
            # marker) onto every later repair in the same pass (round 2, finding 3).
            labels = resolve_labels(
                pool,
                machine,
                notes=record["notes"],
                current=c["labels"],
                gate_mode=gate_mode,
                gate_why=gate_why,
            )
            record["actions"].append(
                register(runner.directory, c["name"], repo, labels, replace=True)
            )
        except (ActionFailed, Unmeasurable) as exc:
            record["problems"].append(f"{c['name']}: {exc}")
            record["actions"].append(f"repair {c['name']} FAILED: {exc}")

    # 6. FILL — one install at a time, at the NEXT FREE SLOT, and measured ---------------------
    # THE PROVISIONER DOES NOT PROMISE "ADD ONE". `install-ci-runner-x64.sh --count N` means
    # "ensure slots 1..N exist", where a slot is `$BASE`, `$BASE-2`, `$BASE-3`, … — REPO-AGNOSTIC.
    # Three consequences, each learned from a real miss:
    #   * the index must be the next FREE SLOT in that numbering, not the install COUNT: this box
    #     carries an ad-hoc `gh-runner-cell4-x64` beside the numbered pair, so a count said 3 while
    #     slots 1-2 were occupied, the call asked for 4, and the installer created 3 AND 4 — two
    #     additions where the ceiling allowed one, i.e. the over-fill this file exists to prevent
    #     (round 5, finding 1). `_next_free_slot` walks the numbering instead;
    #   * what a call ADDED is measured, never assumed, and compared like with like (installs with
    #     installs, listeners with listeners) — mixing populations produced a negative delta whose
    #     note contradicted the action line above it (round 4, finding 1);
    #   * the loop is bounded twice: by `target` iterations and by LISTENER progress. Installs can
    #     appear while no listener stays up (a rejected registration, a unit that exits), and
    #     measuring only the install count made that state loop forever — hundreds of installer
    #     calls in one pass (round 5, finding 2).
    def _found() -> list[LocalRunner]:
        return discover(root)

    def _live(found: list[LocalRunner]) -> int:
        return sum(1 for r in found if r.alive)

    # ⛔ RE-MEASURE AFTER THE REPAIR LOOP, from the PROCESS LIST — never from `classified` (whose
    # `alive` flags predate the repairs) and never by assuming a repair started a listener. Both
    # mistakes were live: the stale recompute reset the count and the fill loop then added one
    # runner too many, and the increment assumed a listener a restart had not actually produced.
    try:
        live = _live(_found())
    except Unmeasurable as exc:
        record["unverified"] = True
        record["unverified_cause"] = "mid-pass-measurement"
        record["notes"].append(
            f"stopped: the box could not be re-measured after the repairs ({exc}) — the actions "
            "above were already performed; nothing further was done"
        )
        stop_pass = True

    if disk_free_mb is None and live < target:
        # ⛔ AN UNMEASURED DISK IS NOT PERMISSION TO ADD — AND IT IS NOT HEALTH EITHER. Repair,
        # orphan handling and the starvation alarm already ran; only the decision that NEEDS the disk
        # figure is withheld. Because that decision was withheld, the pass cannot claim `at-ceiling`
        # or `converged` for a target it never tested: it records the same `unverified` bit a
        # mid-pass measurement failure does, so the verdict is `unmeasurable` and the exit code 2.
        # Otherwise a consumer keying on the verdict would read "all good" from a box whose only
        # capacity question was never asked.
        record["unverified"] = True
        record["unverified_cause"] = "disk-unreadable"
        record["notes"].append(
            f"not filling: the disk free space is UNKNOWN ({record.get('disk_unverified', '?')}) — "
            f"{live} live against a target of {target}; nothing was added, and this pass therefore "
            "cannot report the box as converged"
        )
    installs_seen = len(local)
    for _step in range(max(1, target)):
        if stop_pass or live >= target or disk_free_mb is None:
            break
        try:
            before = mem_available_mb(meminfo)
        except Unmeasurable as exc:
            # Already provisioned something this pass: the record must say so, never "nothing changed".
            record["unverified"] = True
            record["unverified_cause"] = "mid-pass-measurement"
            record["notes"].append(
                f"stopped: memory could not be read mid-pass ({exc}) — the actions above were "
                "already performed; nothing further was done"
            )
            break
        if before - MEM_PER_RUNNER_MB < MEM_RESERVE_MB:
            record["notes"].append(
                f"stop: mem_available_mb={before} - per_runner_mb={MEM_PER_RUNNER_MB} "
                f"< reserve_mb={MEM_RESERVE_MB} — one more would starve a shard"
            )
            break
        # ⛔ THE DISK IS RE-MEASURED EVERY STEP, like the memory above. The pass bounds its ceiling
        # ONCE, so a fill that installs two runners would otherwise budget both against the space it
        # saw before the first byte landed — and the conflict note would quote a stale figure, turning
        # a correct installer refusal into a false conflict page.
        try:
            disk_free_mb = df_free_mb(root)
        except Unmeasurable as exc:
            # ⛔ THE SAME FAILURE AS ONE SCREEN EARLIER IS THE SAME RECORD (review finding P3). The
            # pass-start arm records `unverified` + `unverified_cause` so a fleet reader sees it;
            # this arm only wrote a note, so a `df` that died MID-PASS left no machine-readable
            # trace and the verdict fell through to `under-target` (exit 0). One measurement
            # failure must not have two record shapes depending on WHEN it happened.
            record["unverified"] = True
            # ⛔ ITS OWN CAUSE (review finding P2). The shared `mid-pass-measurement` name rendered
            # "the box could not be re-measured AFTER AN INSTALL" for a `df` that failed BEFORE the
            # first slot — the wrong cause for the failure this arm was added for. The cause is what
            # a fleet reader keys on; it must be the measurement that actually failed.
            record["unverified_cause"] = "disk-unreadable-midpass"
            record["disk_unverified"] = str(exc)
            record["notes"].append(
                f"stop: the disk free space could not be re-read mid-pass ({exc}) — nothing further "
                "was added, and this pass cannot report the box as converged"
            )
            break
        index = _next_free_slot(root)
        if dry_run:
            # A DRY RUN CANNOT MODEL A CONVERGENCE IT CANNOT MEASURE. The old plan assumed +1 per
            # call and printed N steps ending `converged`, while the real pass on the same box
            # issued ONE call and ended under-target (round 4, finding 4). Say what a plan knows:
            # the call it WOULD make, and that the result is measured by the real pass.
            record["plan"].append(
                f"would ask the provisioner for install slot #{index} (mem_available_mb={before}); "
                "how many listeners that yields is MEASURED by a real pass, not predicted here"
            )
            break
        try:
            note = provision(index)
        except ProvisionerRefused as exc:
            # ⛔ TWO ANSWERS TO TWO DIFFERENT QUESTIONS. The installer budgets space for the WHOLE
            # target plus its reserve; this pass adds ONE runner. So when its guard refuses while
            # THIS tool's arm says the increment fits, the box needed capacity and got none — the
            # state that produced the measured `9G free against 44G needed for 3 runners` refusal on
            # a box whose ceiling said 3 — and it is reported as its OWN verdict, with both sides'
            # numbers, instead of an `action-failed` note or a silent refusal.
            # ⛔ THE DECISION USES OUR OWN MEASUREMENT AND THEIR QUOTED WORDS, never a substring of
            # their prose. An earlier version tested `"disk" in refusal.lower()` over `out[-300:]`,
            # which dressed a MEMORY refusal up as a disk conflict and MISSED a disk refusal whose
            # wording this file did not anticipate (both measured).
            fits = disk_allows_one_more(disk_free_mb, per_runner_disk_mb)
            if fits:
                record["problem_kind"] = "guard-conflict"
                record["notes"].append(
                    f"GUARD CONFLICT at slot #{index}: the provisioner refused in its own words "
                    f"({exc}), while THIS tool's arm says ONE MORE fits: free={disk_free_mb}MB - "
                    f"reserve={DISK_RESERVE_MB}MB >= per_runner={per_runner_disk_mb}MB — both read at "
                    "the moment of this step. Nothing was added. The refusal may be about disk, memory or "
                    "arch — this tool does not interpret its prose — but the two guards DISAGREE "
                    "about whether capacity can be added here, and a human must decide which number "
                    "is wrong (#9672)"
                )
                break
            record["problem_kind"] = "refusal"
            record["notes"].append(
                f"provisioner REFUSED slot #{index}: {exc} — nothing was added. This tool's DISK "
                f"arm also says the increment does not fit (free={disk_free_mb}MB - "
                f"reserve={DISK_RESERVE_MB}MB < per_runner={per_runner_disk_mb}MB), so no disk space "
                "was left on the table HERE; the refusal's own reason is whatever it quoted, which "
                "this tool does not interpret. Reported as an answer, not a failure (#9672)"
            )
            break
        except ActionFailed as exc:
            record["problems"].append(str(exc))
            record["actions"].append(f"add runner (slot #{index}) FAILED: {exc}")
            break
        try:
            after = mem_available_mb(meminfo)
            measured = _found()
        except Unmeasurable as exc:
            record["actions"].append(f"{note} (post-step measurement FAILED: {exc})")
            record["unverified"] = True
            record["unverified_cause"] = "mid-pass-measurement"
            record["notes"].append(
                "stopped: the box could not be re-measured after an install — the action above "
                "already happened; nothing further was done"
            )
            break
        previous_live, live = live, _live(measured)
        record["actions"].append(
            f"{note} (mem_available_mb {before} -> {after}; installs {len(measured)}, "
            f"live listeners {live})"
        )
        if live <= previous_live:
            if len(measured) <= installs_seen:
                # ⛔ A PROVISIONER THAT REPORTS SUCCESS AND INSTALLS NOTHING IS AN ACTION FAILURE
                # (review finding P2). `rc=0` with no new install is not a capacity answer and not a
                # timing state: the one action this tool took did not do what it reported. The old
                # code recorded a note and left the verdict at `under-target` → exit 0, the
                # documented "converged / nothing to do", so an enforcer that failed to grow exited
                # green and only a `--json` reader could tell.
                record["problems"].append(
                    f"the provisioner reported success for slot #{index} but NO install appeared "
                    f"(installs {installs_seen} -> {len(measured)}): {note}"
                )
                record["actions"].append(
                    f"add runner (slot #{index}) FAILED: the provisioner returned success but no "
                    f"install appeared (installs {installs_seen} -> {len(measured)})"
                )
            else:
                record["notes"].append(
                    f"stop: slot #{index} was installed but no listener came up (live={live}), so "
                    "another call would repeat the same result — stopping instead of reporting a "
                    "convergence that did not happen"
                )
            break
        installs_seen = len(measured)
        if after < MEM_RESERVE_MB:
            record["notes"].append(
                f"stop: mem_available_mb={after} is below reserve_mb={MEM_RESERVE_MB} after this "
                "install — the box is at its memory limit"
            )
            break

    # 7. VERDICT --------------------------------------------------------------------------------
    # ⛔ THE STARVATION ALARM (agent-infra#2875) IS EVALUATED HERE, ONCE, AND ON EVERY PASS THAT IS
    # OTHERWISE HEALTHY — including a pass that ACTED. The gate is about the pass's own
    # trustworthiness, NOT about whether it did something: a pass with a problem, an unverified
    # measurement or a provisioner refusal alarms about THAT, and this must never mask it.
    # ⛔ AND IT IS NOT SUPPRESSED BY ACTIONS, DELIBERATELY — measured in review round 2. Gating on
    # `not record["actions"]` silences the alarm for ever on exactly the box that needs it: a runner
    # whose repair never sticks is restarted and re-registered on EVERY pass, so an acting gate would
    # report `converged`/exit 0 with the queue still stuck — #2875's own signature, hidden inside the
    # state the tool keeps repairing. The cost of not gating is a bounded false page in the few
    # seconds between a repair and the repaired runner picking work up (the confirmation sample
    # absorbs most of it); the cost of gating is a permanently silent alarm. NOISE LOSES.
    starvation: dict = {}
    # ⛔ `unverified` IS NOT IN THIS GATE, deliberately (measured): a pass that could not read the
    # DISK is still perfectly able to read the queue, and gating the alarm on it meant a starved box
    # with a failing `df` reported `unmeasurable` and NEVER paged — the alarm silenced by an
    # unrelated measurement failure, which is the same trap as suppressing it on actions. The probe's
    # own inputs fail closed (an unread pool or queue is `unmeasured`), so it needs no help here.
    # ⛔ THE ONE EXCEPTION IS THE POOL ITSELF: when the pool read is what failed, the probe's own
    # first step would only repeat that failure (and pay for it again — measured: 7 pool reads where
    # the contract says 1 + 3). Every OTHER unverified cause leaves the pool readable, so the alarm
    # still runs (`disk-unreadable` included).
    # ⛔ AND A PROVISIONER REFUSAL IS NOT IN THIS GATE EITHER (measured, review round 7). It was, on
    # the reasoning that "a pass with a refusal alarms about THAT" — but the refusal leg is
    # `provisioner-refused` → **exit 0**, the documented "converged / nothing to do", so the
    # compensating signal the gate assumed does not exist and a starved box read GREEN: reproduced
    # through the CLI with 1 runner online and idle, 53 queued, our arm's ceiling 3 and the installer
    # returning rc=2 — `verdict=provisioner-refused`, no `starvation` key, **rc=0**. That is the same
    # fail-open as gating on `unverified`: a refusal is a routine, unrelated event (`:1571-1575`) and
    # the queue is still readable, so the alarm runs and OWNS the verdict (see the verdict block).
    if not record["problems"] and record.get("unverified_cause") != "pool-read-after-restart":
        confirm_raw = os.environ.get("RUNNER_AUTOSCALE_STARVATION_CONFIRM_S")
        # ⛔ PARSED DEFENSIVELY, AND BOUNDED, because every value of this seam must fail LOUD. Measured
        # in review: `float()` ACCEPTS `nan`, `-5` and `inf` — the first two silently SKIPPED the
        # confirmation sample (sleep(0) and sleep(negative) both return at once), and `inf` raised
        # `OverflowError` OUT of the pass (only `Unmeasurable` is caught in `main()`), killing it with
        # a traceback and no record. A seam that can disable or crash a guard is a seam that will.
        try:
            confirm_s = (
                float(confirm_raw)
                if confirm_raw not in (None, "")
                else STARVATION_CONFIRM_DEFAULT_S
            )
            # ⛔ THE BOUND CAPS THE CONFIRM TERM ALONE — it does NOT make a pass fit the cadence, and
            # must not be read as doing so. Measured against this file's own bounds, the worst pass is
            # longer than the cadence regardless: `read_pool` and `read_queued_runs` each carry
            # `timeout=120` (a retried pool read is up to 3x120+2x2), the confirming path takes TWO
            # samples, `wait_online` tests its 60 s deadline only AFTER a read returns, and `provision`
            # is `timeout=1800`. 300 s is chosen so the confirm cannot DOMINATE a pass (it is still 10x
            # the 30 s default, so it stays usable for a slow box); 600 s would. Overlap between two
            # concurrent passes is closed by NEITHER this bound nor any lock — this tool takes none —
            # and that residual is reported, not papered over here.
            if not (
                math.isfinite(confirm_s) and 0 < confirm_s <= STARVATION_CONFIRM_MAX_S
            ):
                raise ValueError(confirm_raw)
        except (TypeError, ValueError):
            # 0 IS REFUSED, deliberately: `starvation_probe` only takes its second sample when
            # `confirm_s > 0`, so accepting 0 would silently disable the confirmation — a guard that
            # a "why forbid zero?" tidy could switch off. A caller who wants a single sample is asking
            # for a DIFFERENT guard, not for this one with its teeth removed.
            confirm_s = STARVATION_CONFIRM_DEFAULT_S
            record["notes"].append(
                f"starvation confirm interval {confirm_raw!r} is not a usable number of seconds "
                f"(finite, 0 < s <= {STARVATION_CONFIRM_MAX_S:.0f}) — "
                f"using {STARVATION_CONFIRM_DEFAULT_S:.0f}s"
            )
        starvation = starvation_probe(repo, confirm_s, gate_mode)
        record["starvation"] = starvation.get("state")
        if "eligible" in starvation:
            record["starvation_eligible"] = starvation["eligible"]
            record["starvation_why"] = starvation["why"]
        elif starvation.get("detail"):
            # ⛔ AN UNMEASURED TERM STILL HAS TO SAY WHY (round-13 review finding P1). The probe
            # returns `detail` for that state, and nothing copied it, so a REFUSED age read — the
            # saturated page, the unparsable timestamp, the failed `gh` — arrived at a reader as a
            # bare `starvation=unmeasured` with no reason at all, which is the same "silent operand"
            # this file refuses everywhere else. The bound is published under the SAME key the measured
            # paths use, so a reader parses one name rather than discovering a second spelling.
            record["starvation_why"] = starvation["detail"]
        # ⛔ THE COUNTS ARE PUBLISHED, NOT ONLY SPELLED INTO PROSE (review round 7). `--json` calls
        # this "one machine-readable record (fleet view)", and the three operands were readable only
        # by parsing a note string — while `origin/main`'s version published `queued_runs`, so a
        # consumer of that field got `None` from this one. `queued_runs` keeps main's NAME (it is the
        # contract a fleet reader already has) and the pair it was always printed beside.
        if "queued" in starvation:
            record["queued_runs"] = starvation["queued"]
            record["starvation_queued"] = starvation["queued"]
            record["starvation_busy"] = starvation["busy"]
            record["starvation_online"] = starvation["online"]
            # ⛔ THE AGE IS PART OF THE EVIDENCE, NOT A DEBUG DETAIL (review finding P1, round 11):
            # it is the datum that decides an alarm the gate's absent record cannot, so an operator
            # reading why a queue did or did not page needs the number the bound was applied to.
            if "queue_age_s" in starvation:
                record["starvation_queue_age_s"] = (
                    None
                    if starvation["queue_age_s"] is None
                    else int(starvation["queue_age_s"])
                )
            if "confirm_error" in starvation:
                record["starvation_confirm_error"] = starvation["confirm_error"]
        if starvation.get("state") == "starved":
            record["notes"].append(
                f"STARVATION {starvation['invariant']}: queued={starvation['queued']} "
                f"busy={starvation['busy']} online={starvation['online']} — work is waiting and the "
                "capacity that is up is idle; this is not demand, it is a queue that cannot reach "
                "the runners (labels/arch/gate). Nothing else watches this (agent-infra#2875)"
            )
        elif starvation.get("state") == "ok" and "queued" in starvation:
            # ⛔ THE COUNTS WERE NOT NECESSARY OR, ON THIS BOX, SUFFICIENT (review finding P1). The
            # invariant held but the queue is not this pool's work (fallback-only), so this is
            # HEALTH — said out loud, with the reason, on the pass where someone might expect an
            # alarm. Silence here was the first version's whole failure mode.
            queued = starvation["queued"]
            if (
                starvation.get("eligible") is False
                and queued > 0
                and starvation["busy"] == 0
                and starvation["online"] > 0
            ):
                record["notes"].append(
                    f"starvation NOT armed: {starvation['invariant']} holds "
                    f"(queued={queued} busy={starvation['busy']} online={starvation['online']}) but "
                    f"{starvation['why']}"
                )
        elif starvation.get("state") == "unmeasured":
            record["notes"].append(
                "starvation invariant NOT evaluated: "
                f"{starvation.get('detail')} — an unread queue is not an empty one"
            )
            # ⛔ AND THE FIRST SAMPLE'S OBSERVATION SURVIVES THE FAILED CONFIRMATION (review finding
            # P3, round 11). `queued_runs`/`starvation_*` were published above from that sample; this
            # line says the queue WAS seen and the confirmation is what failed, so "unmeasured" here
            # cannot be read as "there was nothing to see".
            if "confirm_error" in starvation:
                record["notes"].append(
                    f"the starvation CONFIRMATION read failed ({starvation['confirm_error']}) after a "
                    f"first sample of queued={starvation['queued']} busy={starvation['busy']} "
                    f"online={starvation['online']} — the observation is kept, the alarm is not "
                    "raised on one sample"
                )

    if record["problems"]:
        record["verdict"] = "action-failed"
    elif record.get("problem_kind") == "guard-conflict":
        # A CONFLICT, not a failure: nothing was added, both numbers are in the notes, and the exit
        # code says "a human must look at this" (3 — the same code an action failure gets, because
        # from a monitor's seat the box needed capacity and did not get it).
        record["verdict"] = "guard-conflict"
    elif record.get("unverified"):
        # A measurement could not be taken (after a restart). Reported as unmeasurable rather than
        # "converged so nothing to see", because the box's state is genuinely unknown here.
        # ⛔ THIS STAYS ABOVE THE ALARM, and it is a pinned decision rather than an accident (T24):
        # a pass whose OWN capacity measurement failed is `unmeasurable` (exit 2) even while a starved
        # queue is recorded, because exit 2 is already non-green and the unknown reading is the more
        # specific verdict. What could NOT stay above it is the refusal leg — see below.
        record["verdict"] = "unmeasurable"
        # ⛔ NAME THE MEASUREMENT THAT FAILED. One fixed sentence said "the pool could not be read
        # after a restart" for every unverified pass, including the one where nothing was restarted
        # and the MEMORY read failed after an install — a `--json` consumer read the wrong cause
        # (round 6, finding 3). The actions above stay in the record either way.
        if record.get("unverified_cause") == "pool-read-after-restart":
            record["error"] = (
                "the pool could not be read after a restart — "
                f"{record.get('unverified_detail') or 'no error text was captured'} — the box's "
                "runner count is UNKNOWN, so the pass stopped there. The actions listed above were "
                "already performed BEFORE that point; nothing was added or registered after it."
            )
        elif record.get("unverified_cause") == "disk-unreadable-midpass":
            record["error"] = (
                "the disk free space could not be re-read mid-pass — "
                f"{record.get('disk_unverified') or 'no error text was captured'} — so the pass "
                "stopped before adding anything it could not price. The actions listed above were "
                "already performed BEFORE that point; nothing further was done."
            )
        else:
            record["error"] = (
                "a measurement could not be taken mid-pass (the box could not be re-measured after "
                "an install) — the pass stopped there. The actions listed above were already "
                "performed BEFORE that point; nothing further was done."
            )
    elif starvation.get("state") == "starved":
        # ⛔ THE ALARM OWNS THE VERDICT OVER THE REFUSAL, and that is the one leg it must beat
        # (review round 7, measured). A routine provisioner refusal is not an error — it returns
        # **exit 0**, the documented "converged / nothing to do" — so letting it win published a
        # starved, 53-queued box as GREEN (`verdict=provisioner-refused`, rc=0, no `starvation` key).
        # The header is explicit that exit 4 "is the one exit a health check should page on, because
        # a starved box otherwise reads perfectly healthy". `problems`, `guard-conflict` and
        # `unverified` stay ABOVE this: the first two are already page-worthy and the third is the
        # more specific verdict for a box whose own capacity measurement failed (T24). The refusal's
        # own words keep their place in `notes` — losing its VERDICT must not lose its evidence.
        record["verdict"] = "starvation"
        record["error"] = (
            f"STARVATION ({starvation['invariant']}): queued={starvation['queued']} "
            f"busy={starvation['busy']} online={starvation['online']} — the queue has work and every "
            "online runner is idle. Nothing was changed by this alarm; the cause is a mismatch "
            "between what the jobs ask for and what the runners advertise (labels/arch/gate), not a "
            "lack of capacity (agent-infra#2875)"
        )
    elif record.get("problem_kind") == "refusal":
        record["verdict"] = "provisioner-refused"
    elif live > ceil:
        record["verdict"] = "over-ceiling"
        record["notes"].append(
            f"over-ceiling: {live} live against a measured ceiling of {ceil} — {reading}; nothing "
            "removed (a runner that may be serving is never removed)"
        )
    elif live >= target and record["actions"]:
        record["verdict"] = "converged"
    elif live >= target and record["would_repair"]:
        # ⛔ CAPACITY AT THE CEILING IS NOT A HEALTHY BOX (review finding P1, round 12). A runner the
        # pass's OWN classification called DEAD/ORPHANED is an outstanding repair: on a full box a
        # real pass would restart/re-register it, so a read-only pass must not answer `converged` —
        # that is the word a monitor keys on, and `--status` printed it two lines under `DEAD r-3`.
        # The verdict is what the measurement supports (`at-ceiling`: no fill is needed) and the
        # outstanding work is named, in `would_repair` for a machine and in this note for a human.
        record["verdict"] = "at-ceiling"
        record["notes"].append(
            f"at-ceiling: {live}/{ceil} — {reading} — {len(record['would_repair'])} degraded "
            f"install(s) a real pass would repair ({'; '.join(record['would_repair'])}); this pass "
            "was read-only, so nothing was done and the box is NOT converged"
        )
    elif live >= target:
        record["verdict"] = "at-ceiling"
        record["notes"].append(f"at-ceiling: {live}/{ceil} — {reading}")
    elif live < target:
        # The loop ended under target (a provisioner that added nothing, or an action failure that
        # was already recorded). NEVER `converged`: that word is a claim the box reached its
        # ceiling, and this is the state where it did not (round 3, finding 1's under-fill half).
        record["verdict"] = "under-target"
        record["notes"].append(
            f"under-target: {live} live against a target of {target} — {reading}"
        )
    else:
        record["verdict"] = "converged" if record["actions"] else "at-ceiling"
    record["live"] = live
    # ⛔ THE INSTALLED UNITS ARE AUDITED ON EVERY PASS, not only under `--check-units`. Refusing to
    # write a transient WorkingDirectory does nothing about the units ALREADY on the box — including
    # the hand-written one that started this — and a broken unit is invisible until someone reads a
    # red unit. A NOTE, not a `problems` entry: the pool may be perfectly converged, and turning a
    # healthy pool red for a stale unit file would trade one silent failure for a noisy false one.
    # ⛔ AN AUDIT MAY NOT LOSE THE RECORD — this commit's own title, and the reason the wrap exists
    # (review finding P1, round 12). This audit runs AFTER the repair and fill steps, so ANY exception
    # escaping it (measured reachable: `Path.expanduser()` on `WorkingDirectory=~nosuchuser/x`, and a
    # per-entry `stat` outside pathlib's absence errnos) reaches `main()`'s backstop with the pass's
    # destructive actions already performed — and the backstop's payload carries no `actions`, so the
    # record of a registration that was destroyed and recreated is exactly what gets lost. A finding
    # here is a FINDING; the audit never propagates.
    try:
        unit_problems = installed_unit_cwd_problems()
    except Exception as exc:  # noqa: BLE001 — the audit is a reporter, never a reason to lose a record
        unit_problems = [
            f"the installed-unit audit ITSELF failed ({type(exc).__name__}: {exc}) — the units on "
            "this box were NOT audited; the actions in this record were performed before this point"
        ]
    if unit_problems:
        record["unit_cwd_problems"] = unit_problems
        # ⛔ ONE SUMMARY NOTE, NOT ONE PER FINDING (review finding P2). Every pass re-audits every
        # installed unit, so `extend()`-ing each finding made the notes a standing wall — measured: a
        # cell at 10 standing findings appended 10 identical lines every ~9 minutes, into a log with
        # no size bound, and a NEW finding was indistinguishable from the nine old ones (the same "an
        # audit nobody could clear" failure the audit was fixed to avoid). The findings themselves
        # are kept, verbatim, in `unit_cwd_problems`; the count is what a reader needs here.
        record["notes"].append(
            f"unit audit: {len(unit_problems)} installed-unit finding(s) — see unit_cwd_problems"
        )
    return record


def _preserve_labels(current: list[str], machine: str) -> str:
    """The labels a RE-registered runner keeps: its custom labels, plus THIS box's arch marker.

    `self-hosted`, the OS token and the arch token are derived by GitHub from the host at
    registration and cannot be set by hand, so they are dropped from the `--labels` argv; every
    other label (a custom tier, a pool tag, `ubuntu-latest` while the fallback is engaged) is
    PRESERVED, because a workflow targeting it would otherwise queue forever.

    ⛔ The arch marker is RE-DERIVED from this box, never preserved: a mis-registered runner can
    carry the OTHER arch's marker, and passing it straight back lets an x86 box register with
    `self-hosted-arm64` — a false PASS (an arm64 job built on x86), not a queue delay.
    """
    host_derived = {"self-hosted", "linux", "macos", "windows", "x64", "arm64", "arm"}
    arch = ARCH_LABEL.get(machine.lower())
    keep = [
        x
        for x in current
        if x and x.lower() not in host_derived and not x.lower().startswith("self-hosted-")
    ]
    if not arch:
        return ""  # unknown arch: the caller falls back to resolve_labels, which REFUSES
    return ",".join([arch, *keep])


_WORKER_CACHE: dict[str, bool] = {}


def _worker_alive(runner: LocalRunner, *, fresh: bool = False) -> bool:
    """A live `Runner.Worker` under this install ⇒ a job is being served (belt and braces).

    The AUTHORITATIVE busy flag is the pool's own `busy`; this exists because `busy` is a
    broker-side view, and a listener that lost its broker connection can be executing a job
    while the API says idle — and for a runner the pool does not list at all, this is the ONLY
    signal that it is working. Restarting or re-registering that one would kill a real job.
    """
    seam = os.environ.get("RUNNER_AUTOSCALE_BUSY_DIRS")
    if seam:
        try:
            busy = {
                ln.strip()
                for ln in Path(seam).read_text(encoding="utf-8").splitlines()
                if ln.strip()
            }
        except OSError as exc:
            raise Unmeasurable(f"busy-dirs seam unreadable ({seam}: {exc})") from exc
        return str(runner.directory) in busy
    key = str(runner.directory)
    # ⛔ `fresh` RE-READS, because the cache is what makes a stale answer possible: the value is
    # written during CLASSIFICATION, and the destructive step it guards happens a whole
    # wait-online timeout later (`--replace`). A re-check that read the cache would return the
    # pre-wait `False` and certify exactly what it was added to refuse.
    if fresh or key not in _WORKER_CACHE:
        try:
            proc = subprocess.run(
                [os.environ.get("RUNNER_AUTOSCALE_PS") or "ps", "-eo", "args"],
                capture_output=True,
                text=True,
                timeout=15,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            # Same fail-closed rule as `_listener_dirs`: swallowing this to `False` silently
            # deletes the one signal that protects a runner the POOL does not list, so an install
            # executing a job could be `--replace`d on the strength of a broken `ps`.
            raise Unmeasurable(f"process list unreadable ({exc})") from exc
        if proc.returncode != 0:
            raise Unmeasurable(f"process list unreadable (ps exited {proc.returncode})")
        _WORKER_CACHE[key] = any(
            "Runner.Worker" in line and f"{runner.directory}/bin" in line
            for line in proc.stdout.splitlines()
        )
    return _WORKER_CACHE[key]


# ── CLI ──────────────────────────────────────────────────────────────────────────────────────
def _log(record: dict) -> None:
    state_dir = Path(
        os.environ.get("RUNNER_AUTOSCALE_STATE_DIR") or (Path.home() / ".pi" / "agent" / "state")
    )
    try:
        state_dir.mkdir(parents=True, exist_ok=True)
        with (state_dir / "runner-autoscale.log").open("a", encoding="utf-8") as fh:
            fh.write(
                json.dumps(
                    {
                        "at": datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
                        **record,
                    }
                )
                + "\n"
            )
    except OSError:
        pass  # a log that cannot be written must not fail a convergence pass


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(add_help=True, description=__doc__.split("\n")[0])
    ap.add_argument("--repo", default=os.environ.get("RUNNER_AUTOSCALE_REPO") or DEFAULT_REPO)
    ap.add_argument("--root", default=os.environ.get("RUNNER_AUTOSCALE_RUNNER_ROOT") or "/opt")
    ap.add_argument(
        "--want",
        type=int,
        default=None,
        metavar="N",
        help="runner count to ensure; REFUSED above the measured ceiling",
    )
    ap.add_argument("--status", action="store_true", help="measure + classify; change nothing")
    ap.add_argument("--dry-run", action="store_true", help="print the plan; change nothing")
    ap.add_argument("--json", action="store_true", help="one machine-readable record")
    ap.add_argument(
        "--install-unit",
        action="store_true",
        help="write+enable this tool's OWN systemd unit pair (refused if its WorkingDirectory is "
        "missing or transient); change nothing else and exit",
    )
    ap.add_argument(
        "--check-units",
        action="store_true",
        help="audit the INSTALLED units: WorkingDirectory, and ExecStart's program and paths "
        "(an accumulated command for Type=oneshot, the empty-ExecStart= reset, executable prefixes, "
        "bare names and Condition-skipped units honoured); exit 5 when one is unusable",
    )
    ap.add_argument(
        "--workdir",
        default=None,
        metavar="PATH",
        help="WorkingDirectory for --install-unit (default %%h, the account home)",
    )
    opts = ap.parse_args(argv)

    if opts.want is not None and opts.want < 0:
        print("usage: --want must be >= 0", file=sys.stderr)
        return 1

    if opts.check_units:
        # ⛔ THE BACKSTOP COVERS THE AUDIT TOO (review finding P2). This arm sits OUTSIDE the
        # `converge` try below, so an unexpected error — an uninspectable path in a shape nobody
        # converted, a broken seam — exited 1 with a traceback: the SAME exit code as an
        # `--install-unit` refusal, and "this audit could not run" became indistinguishable from "this
        # audit found something". Exit 2 is the file's "could not measure" verdict.
        try:
            problems = installed_unit_cwd_problems(require_any=True)
        except Exception as exc:  # noqa: BLE001 — an audit that cannot run must SAY so
            print(
                f"UNMEASURABLE (the audit did not complete): {type(exc).__name__}: {exc}",
                file=sys.stderr,
            )
            return 2
        payload = {"checked": default_unit_dirs(), "problems": problems}
        if opts.json:
            print(json.dumps(payload))
        else:
            for problem in problems:
                print(problem)
            print(
                f"checked {', '.join(default_unit_dirs())} — "
                + (f"{len(problems)} finding(s)" if problems else "all usable")
            )
        return 5 if problems else 0

    if opts.install_unit:
        try:
            done = install_unit(opts.repo, opts.workdir)
        except UnitRefused as exc:
            print(f"REFUSED (nothing was written): {exc}", file=sys.stderr)
            return 1
        except ActionFailed as exc:
            print(f"ACTION FAILED: {exc}", file=sys.stderr)
            return 3
        except Exception as exc:  # noqa: BLE001 — an install that cannot run must SAY so
            # Same reason as the audit arm above: a traceback here returns 1, which is this
            # command's "REFUSED, nothing written" answer, so a monitor reading exit codes would
            # read a crash as a clean refusal. 3 says the action failed, and the words say why.
            print(
                f"ACTION FAILED (unexpected): {type(exc).__name__}: {exc} — nothing is claimed "
                "about what reached disk; re-run `--check-units` to read the installed pair",
                file=sys.stderr,
            )
            return 3
        for line in done:
            print(line)
        print(f"verdict={UNIT_BASENAME} installed")
        return 0

    try:
        record = converge(
            opts.repo, root=opts.root, want=opts.want, dry_run=opts.status or opts.dry_run
        )
    except Unmeasurable as exc:
        payload = {"repo": opts.repo, "verdict": "unmeasurable", "error": str(exc)}
        print(
            json.dumps(payload) if opts.json else f"UNMEASURABLE (nothing changed): {exc}",
            file=sys.stderr,
        )
        _log(payload)
        return 2
    except Exception as exc:  # noqa: BLE001 — a pass that dies must still leave a RECORD
        # ⛔ THE BACKSTOP, and its whole purpose is the LOG (review finding P1). `converge` runs
        # after the repair and fill steps, so an exception from here can mean real changes were
        # already made — restarts, re-registrations, a provision — and exiting with a bare traceback
        # left NO record of them (measured: `RUNNER_AUTOSCALE_POOL_READ_ATTEMPTS=abc` exited 1 with a
        # stack trace and the log file untouched). One line here converts "the tool crashed" into
        # "this pass could not complete, and here is the error", which is what a 9-minute timer needs
        # in order to be diagnosable at all. The specific seams are parsed through `_env_int`/
        # `_env_float` so this arm should stay unreachable; it is the guard that makes that claim
        # checkable instead of a hope.
        detail = f"{type(exc).__name__}: {exc}"
        payload = {"repo": opts.repo, "verdict": "unmeasurable", "error": detail}
        print(
            json.dumps(payload)
            if opts.json
            else f"UNMEASURABLE (pass did not complete): {detail} — recorded, not lost",
            file=sys.stderr,
        )
        _log(payload)
        return 2

    _log(record)
    if opts.json:
        print(json.dumps(record))
    else:
        print(f"repo={record['repo']} cell={os.uname().nodename} {record['reading']}")
        for c in record.get("runners", []):
            print(f"  {c['state']:<9} {c['name']} dir={c['dir']}")
        for a in record["actions"]:
            print(f"  - {a}")
        for a in record.get("would_repair", []):
            print(f"  - {a}")
        for p in record.get("plan", []):
            print(f"  · {p}")
        for n in record.get("notes", []):
            print(f"  · {n}")
        if record.get("starvation"):
            print(f"starvation={record['starvation']}")
        if record.get("refusal"):
            print(record["refusal"], file=sys.stderr)
        if record["verdict"] == "starvation":
            print(record.get("error", ""), file=sys.stderr)
        print(f"verdict={record['verdict']}")
    if record["verdict"] == "refused":
        return 1
    if record["verdict"] in ("action-failed", "guard-conflict"):
        return 3
    if record["verdict"] == "unmeasurable":
        return 2
    if record["verdict"] == "starvation":
        return 4
    return 0


if __name__ == "__main__":
    sys.exit(main())
