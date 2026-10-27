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
  (on a cell this is the FARMED copy at `~/.pi/agent/scripts/runner_autoscale.py` — one file,
   one source: this one. Until 2026-10-27 it existed ONLY as a live copy on cell-4, so it could not
   be reviewed, tested or redeployed — the live-only class agent-infra#1552 tracks, where 26 of 35
   lane-orchestration scripts live in only `~/.pi/agent/scripts`.)

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

  ⛔ `--json` CONSUMERS: `starvation` is THREE-VALUED and the healthy value is `"ok"`. `"starved"` is
  the alarm; `"unmeasured"` means the queue could not be read and the invariant was NOT evaluated —
  never read that as healthy (a monitor whose test is `starvation != "starved"` treats blindness as
  health, which is the failure this field exists to prevent). The key is absent when the pass was not
  healthy enough to evaluate it, so absence is also not health.

  ⛔ THE SEAMS ARE MEASUREMENT INPUTS, NOT CEILING OVERRIDES. There is deliberately no
  `--ceiling` / `--max-runners` flag: a box that can be told to exceed its own measurement is a
  box with no guard, which is the defect this file exists to close.

EXIT  0 converged / nothing to do (a REFUSAL is an answer, not a failure)
      1 usage, or `--want N` refused (N above the measured ceiling — nothing was changed)
      2 a measurement or pool read was UNREADABLE — fail-closed, nothing was changed
      3 an ACTION failed (restart / registration / missing provisioner) — the record says which
      4 STARVATION — `queued>0 ∧ busy==0 ∧ online>0` confirmed (agent-infra#2875). Nothing was
        changed by the alarm: it names the invariant and the three counts. This is the one exit a
        health check should page on, because a starved box otherwise reads perfectly healthy.
      5 `--check-units` found an installed unit whose WorkingDirectory is unusable (or an audit that
        read nothing at all). A READ-ONLY finding, deliberately distinct from 3: a consumer keying on
        "an action failed" must not confuse it with "my units are misconfigured".
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
import json
import math
import os
import re
import shutil
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

# ── the sizing predicate (owner ruling, agent-infra#2344 comment 6347825624) ────────────────────
MEM_PER_RUNNER_MB = 1500
MEM_RESERVE_MB = 2048
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


def ceiling(ncpu: int, mem_mb: int, running: int) -> tuple[int, str, str]:
    """(ceiling, bound, reading). `running` = listeners ALREADY alive on this box."""
    by_core = core_ceiling(ncpu)
    headroom = max(0, (mem_mb - MEM_RESERVE_MB) // MEM_PER_RUNNER_MB)
    by_mem = max(0, running) + headroom
    value = min(by_core, by_mem)
    bound = "cores" if by_core <= by_mem else "memory"
    reading = (
        f"ncpu={ncpu} mem_available_mb={mem_mb} running={max(0, running)} "
        f"per_runner_mb={MEM_PER_RUNNER_MB} reserve_mb={MEM_RESERVE_MB} "
        f"by_cores={by_core} by_memory={by_mem} bound={bound} ceiling={value}"
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
    and it would then register a duplicate under a new name.
    """
    base = Path(root)
    if not base.is_dir():
        return []
    alive = _listener_dirs()
    found: list[LocalRunner] = []
    for entry in sorted(base.glob("gh-runner*")):
        if not entry.is_dir() or not (entry / ".runner").exists():
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


def starvation_invariant(queued: int, busy: int, online: int) -> bool:
    """`queued > 0 ∧ busy == 0 ∧ online > 0` — WORK IS WAITING, CAPACITY IS UP AND IDLE.

    ⛔ THIS IS STARVATION, NOT DEMAND. Work queued with every runner BUSY is a busy pool; work queued
    with NO runner online is a repair problem (this tool's own DEAD/ORPHANED path); work queued with a
    runner ONLINE and NONE busy means the queue and the runners are not meeting — the labels, the
    arch, or the gate. Nothing watched that: measured 2026-10-27 it was misread twice in one night,
    first as "capacity" and then as "review cost", and the merge window was gone (agent-infra#2875).
    ⛔ THE `online > 0` OPERAND IS NOT DECORATION: without it an all-offline pool (nothing can take
    work) reads as starvation and pages a human for a state the repair path already owns.
    """
    return queued > 0 and busy == 0 and online > 0


def starvation_probe(repo: str, confirm_s: float = STARVATION_CONFIRM_DEFAULT_S) -> dict:
    """Sample the invariant, CONFIRM it across a short interval, and report the counts.

    A dict, not a bool, so a `--json` consumer reads one record instead of parsing prose.

    ⛔ CONFIRMED, because the invariant also holds for a few seconds of ordinary handover (a queue
    drains, the next job has not been assigned yet). The second sample is only taken when the FIRST
    one already looks starved, so a healthy box pays nothing for the confirmation.
    ⛔ AN UNREAD QUEUE IS `unmeasured`, NOT OK. Turning it into exit 2 would let a permission-scoped
    token silence the capacity work this tool exists for; turning it into `ok` would hide the one
    state the alarm exists to surface. So it is named, in the record and in the human line.
    """

    def sample() -> tuple[int, int, int]:
        pool = read_pool_retrying(repo)
        queued = read_queued_runs(repo)
        return (
            queued,
            sum(1 for e in pool.values() if e.busy),
            sum(1 for e in pool.values() if e.online),
        )

    try:
        queued, busy, online = sample()
        starved = starvation_invariant(queued, busy, online)
        if starved and confirm_s > 0:
            time.sleep(confirm_s)
            queued, busy, online = sample()
            starved = starvation_invariant(queued, busy, online)
    except Unmeasurable as exc:
        return {"state": "unmeasured", "detail": str(exc)}
    return {
        "state": "starved" if starved else "ok",
        "queued": queued,
        "busy": busy,
        "online": online,
        "invariant": "queued>0 AND busy==0 AND online>0",
    }


def label_floor_binds(pool: dict[str, PoolEntry]) -> bool:
    """TRUE when no runner in the pool advertises the fallback label at all.

    ⛔ This is a POOL-WIDE reading, not a per-runner one: the question is what the repo can serve,
    and `runs-on: ubuntu-latest` is matched against the pool, so one runner carrying the label is
    enough for the repo and zero is a total stop.
    """
    return not any(FALLBACK_LABEL in e.labels for e in pool.values())


def resolve_labels(
    pool: dict[str, PoolEntry],
    machine: str,
    *,
    notes: list[str] | None = None,
    current: list[str] | None = None,
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

    ⛔ WHICH RULE WINS WHEN THEY DISAGREE — THE FLOOR, ALWAYS. The gate (`fallback_engaged`) can
    only ADD the label; the floor is a MINIMUM on every set this function returns. They disagree
    exactly when the gate says "no" and no runner holds the label, and resolving THAT toward the
    gate is what took the pool to zero. The prices are not symmetric: a floor-granted label makes
    `ci_runner_gate.sh`'s `current_mode` read `local` (a mode that misdescribes the box, is
    visible in the gate's own reading, and is recoverable by any later pass or operator), while a
    zero-label pool runs NO workflow at all — including the one that would restore the label. **The
    cheaper failure wins the tie, and that is the floor.**

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
    floor = label_floor_binds(pool)
    engaged = fallback_engaged(pool)
    if floor and not engaged and FALLBACK_LABEL not in labels:
        reason = (
            f"label floor: no runner in the pool ({len(pool)} registered) advertises "
            f"{FALLBACK_LABEL} — this registration takes it, otherwise nothing can serve "
            f"`runs-on: {FALLBACK_LABEL}`"
        )
        if notes is not None:
            notes.append(reason)
        else:
            print(f"  · {reason}", flush=True)
    # `dict.fromkeys` keeps order and makes a DOUBLE-ADD unrepresentable, whichever arm asked for it:
    # the pre-floor code could write `ubuntu-latest` twice (once preserved, once from the gate), and
    # a repeated label is a config.sh argument GitHub rejects.
    if floor or engaged:
        labels.append(FALLBACK_LABEL)
    return ",".join(dict.fromkeys(labels))


# ── actions ───────────────────────────────────────────────────────────────────────────────────
def _run(cmd: list[str], timeout: int = 300) -> tuple[int, str]:
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError) as exc:
        return 127, str(exc)
    return proc.returncode, ((proc.stdout or "") + (proc.stderr or "")).strip()


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


def read_pool_retrying(repo: str, *, attempts: int | None = None) -> dict[str, PoolEntry]:
    """`read_pool` with a BOUNDED retry for TRANSIENT failures, keeping the LAST error's own words.

    ⛔ The final message CONTAINS the gh error text. A verdict of `unmeasurable` that hides the cause
    is indistinguishable from "the tool is broken", which is how a lane ends up hand-rolling a runner
    count instead of fixing the unit's missing `--repo`.
    ⛔ BOUNDED, and the bound is short: this runs INSIDE a restart-recovery window, so an unbounded
    wait would outlive the very poll it is serving.
    """
    tries = attempts if attempts is not None else int(
        os.environ.get("RUNNER_AUTOSCALE_POOL_READ_ATTEMPTS") or 3
    )
    backoff = float(os.environ.get("RUNNER_AUTOSCALE_RETRY_BACKOFF_S") or 2)
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
    rc, out = _run(
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
    token = out.splitlines()[-1].strip() if out else ""
    if rc != 0 or not token:
        raise ActionFailed(f"registration token mint failed rc={rc}: {out[:300]}")
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
        _restore_local_config(directory, stash)
        raise ActionFailed(f"cannot clear {directory}/{name} for re-registration ({exc})") from exc
    return stash


def _restore_local_config(directory: Path, stash: dict[str, tuple[int, bytes]]) -> None:
    """Put the stashed local config back, AT ITS ORIGINAL MODE, in one atomic creation.

    ⛔ `os.open(..., mode)` RATHER THAN `write_bytes` + `chmod`. Written the naive way the file is
    created 0644 under the usual umask and only then narrowed, so (a) `.credentials_rsaparams` — the
    runner's RSA PRIVATE KEY — is world-readable for a window, and (b) if the `chmod` fails (EROFS, a
    foreign-owned mount) the swallowed error leaves it 0644 FOR EVER, silently. Creating it with the
    mode means there is no window and no second failure mode; `os.fchmod` keeps ANY stashed mode
    exact rather than trusting the umask.
    """
    for name, (mode, data) in stash.items():
        path = Path(directory) / name
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
            try:
                os.fchmod(fd, mode)
                os.write(fd, data)
            finally:
                os.close(fd)
        except OSError:
            pass  # best effort: the raise that follows already names the real failure


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
    stash = _clear_local_config(directory) if replace else {}
    # ⛔ THE CLEARED REGION IS EXCEPTION-SAFE (fix 2, round 2). `registration_token()` is evaluated
    # INSIDE this block, and it raises `ActionFailed` on any gh failure — a routine transient for a
    # tool that runs every few minutes. Restoring only on `rc != 0` left that raise to drop the stash,
    # so a failed token mint DESTROYED the install's `.runner` and its RSA key, `discover()` stopped
    # seeing it, its slot read FREE to the provisioner, and the same pass added a SECOND install over
    # the top (measured on the fixture: the directory kept `config.sh` alone and `--count 1` ran).
    # `registered` is set BEFORE `enable_unit`, so a unit failure still never writes the stale stash
    # back over the fresh config a successful re-registration just wrote.
    registered = False
    try:
        rc, out = _run(
            _config_argv(cfg, repo, registration_token(repo), name, labels, replace), timeout=600
        )
        if rc != 0 and _ALREADY_CONFIGURED in out.lower():
            # ⛔ The retry's stash is MERGED, not discarded: a refused configure can leave `.runner`
            # behind, and if the retry's clear takes it the restore below must still be able to put
            # the install back. (Today `register()` is only called with `replace=True`, so the first
            # stash is always present — this keeps that true if a caller ever passes False.)
            for fname, entry in _clear_local_config(directory).items():
                stash.setdefault(fname, entry)
            rc, out = _run(
                _config_argv(cfg, repo, registration_token(repo), name, labels, replace),
                timeout=600,
            )
        if rc != 0:
            raise ActionFailed(f"config.sh for {name} rc={rc}: {out[-400:]}")
        registered = True
    finally:
        if not registered:
            _restore_local_config(directory, stash)
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


def unit_workdir_problem(workdir: str | None) -> str | None:
    """None when `workdir` may be a unit's WorkingDirectory, else the reason it may not.

    `None` means the template's `%h` — the account's home, which systemd resolves per-user. It is
    checked by RESOLVING it (a container may hand out `HOME=/tmp/something`, and then the stable
    spelling points at a transient directory).
    """
    if workdir in (None, "", "%h"):
        workdir = str(Path.home())
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
    path = Path(workdir).expanduser()
    if not path.is_absolute():
        return f"WorkingDirectory={workdir!r} is not an absolute path"
    # ⛔ THE SHAPE IS CHECKED FIRST, and the order is load-bearing: a path under /tmp that does not
    # exist YET is still a transient path, and reporting only "does not exist" would invite the
    # operator to mkdir it — which is exactly how the measured unit came to point at a directory a
    # reclaim later took. Shape first, then existence.
    real = path.resolve()
    for prefix in TRANSIENT_UNIT_PREFIXES:
        if str(real) == prefix or str(real).startswith(prefix + "/"):
            return (
                f"WorkingDirectory={workdir} is inside {prefix} — a reclaim or a tmp cleaner removes "
                "it underneath the unit (measured: /tmp/cell-wt-runnerauto2 killed a converger for "
                "as long as the reclaim stood)"
            )
    if not path.is_dir():
        return (
            f"WorkingDirectory={workdir} does not exist — systemd fails the unit with "
            "status=200/CHDIR BEFORE it runs a line, so the converger would silently stop"
        )
    return None


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
            # ⛔ QUOTED. systemd splits ExecStart on whitespace, so an unquoted script path or repo
            # containing a space yields a unit that fails on EVERY tick — a cron-style silent break of
            # the very schedule being installed (measured: `--repo o/r` + a positional, exit 2).
            'ExecStart="%s" "%s" --repo "%s"' % (python, script, repo),
            "Nice=10",
            "# A pass can legitimately run for many minutes (waits, reads, a provision), and systemd",
            "# will not start a SECOND instance of an active oneshot service — that is the mutual",
            "# exclusion this CLI keeps no lock for, so two passes can never repair one runner at once.",
            "TimeoutStartSec=1800",
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
    planned = render_unit(repo, workdir)
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
        if entry.is_dir() and name.endswith(".d"):
            try:
                files.extend(sorted(entry.iterdir()))
            except OSError as exc:
                problems.append(f"{entry}: unreadable ({exc}) — NOTHING was audited there")
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
        if not root.is_dir():
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


def provision(target_count: int) -> str:
    """Create/extend the install so that runners 1..target_count exist — via the ONE installer.

    ⛔ This file never downloads a runner binary and never builds a `config.sh` argv for a NEW
    install: download + sha256 verification + the headroom/arch guards are
    `tools/install-ci-runner-x64.sh`'s job (it is the only registration path). Absent, this
    REFUSES — improvising a provisioner here is how a second, divergent registration path is
    born (#9639 exists precisely because there was one).
    """
    raw = os.environ.get("RUNNER_AUTOSCALE_PROVISIONER")
    # The installer is resolved, never assumed: the RUNNING copy of this tool lives in
    # ~/.pi/agent/scripts (a stable path), so a sibling lookup alone would find nothing there and
    # every add would refuse — an enforcer that can never fire. The candidate list spans the
    # installed copy's neighbours, the working directory (the cell's checkout), and $REPO/tools.
    candidates = (
        [raw]
        if raw
        else [
            str(Path(__file__).resolve().parent / "install-ci-runner-x64.sh"),
            str(Path.cwd() / "tools" / "install-ci-runner-x64.sh"),
            str(Path.home() / ".pi" / "agent" / "scripts" / "install-ci-runner-x64.sh"),
        ]
    )
    provisioner = next((c for c in candidates if c and Path(c).exists()), None)
    if not provisioner:
        raise ActionFailed(
            "no provisioner: tools/install-ci-runner-x64.sh is absent, so a NEW runner cannot be "
            "created on this box (this script never downloads a runner binary). Repair/orphan "
            "paths still work; set RUNNER_AUTOSCALE_PROVISIONER to the installer."
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
        "notes": [],
        "verdict": "",
        "problems": [],
    }
    ncpu = cores(nproc)
    mem_mb = mem_available_mb(meminfo)
    local = discover(root)
    pool = read_pool(repo)
    machine = machine or os.environ.get("RUNNER_AUTOSCALE_MACHINE") or os.uname().machine
    wait_s = int(
        os.environ.get(
            "RUNNER_AUTOSCALE_ONLINE_WAIT_S", online_wait_s if online_wait_s is not None else 60
        )
    )
    poll = int(os.environ.get("RUNNER_AUTOSCALE_POLL_S", poll_s if poll_s is not None else 5))

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
    ceil, bound, reading = ceiling(ncpu, mem_mb, running)
    record.update(
        ncpu=ncpu,
        mem_available_mb=mem_mb,
        bound=bound,
        ceiling=ceil,
        reading=reading,
        runners=classified,
        local=[{"dir": str(r.directory), "name": r.name} for r in local],
        pool_total=len(pool),
        pool_online=sum(1 for e in pool.values() if e.online),
        pool_busy=sum(1 for e in pool.values() if e.busy),
        # ⛔ BOTH LABEL FACTS ARE PUBLISHED, because they answer different questions and only one of
        # them is a policy preference: `fallback_engaged` is the gate's state, `label_floor_binds`
        # is "this repo can serve NO `runs-on: ubuntu-latest` job at all". A fleet consumer that
        # sees the second one true is looking at (or one pass away from) a total CI stop.
        fallback_engaged=fallback_engaged(pool),
        label_floor_binds=label_floor_binds(pool),
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
    for c in classified:
        if c["state"] in ("SERVING", "BUSY", "OTHER-REPO"):
            # OTHER-REPO is reported and never repaired: it is not this repo's runner, so
            # `register(..., repo)` would move it here (`--replace` deletes the other repo's
            # registration). It still counts in `live` above — it occupies the box.
            continue
        runner = next(r for r in local if r.name == c["name"])
        if dry_run:
            record["actions"].append(f"would repair {c['name']} ({c['state']})")
            continue
        if c["state"] == "DEAD":
            ok, detail = restart_runner(runner)
            record["actions"].append(f"restart {c['name']}: {detail}")
            # ⛔ "we could not look" is NOT "it is still offline". An unreadable pool after a
            # restart proves nothing about the runner, and acting on it re-registers (with
            # --replace) a registration that may be reconnecting and picking up a job — the one
            # destructive action this file promises never to take blindly. Stop the PASS: the box
            # state is unknown from here, so no fill decision may be taken on a stale count.
            state, why = (
                wait_online(repo, c["name"], wait_s, poll) if ok else ("offline", "")
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
            record["actions"].append(
                f"{c['name']} still offline after restart — re-registering with --replace"
            )
        try:
            # ⛔ ONE DECISION POINT, TWO INDEPENDENT STEPS. `resolve_labels` keeps the labels the
            # runner already carries AND applies the floor (see its docstring for why an "either/or"
            # was a defect: a DEAD runner in the pool has labels to keep, so the floor was never
            # reached on the path that runs after every restart). ⛔ PER RUNNER, never a value cached
            # from the previous iteration: that leaked one runner's set (including an other-arch
            # marker) onto every later repair in the same pass (round 2, finding 3).
            labels = resolve_labels(
                pool, machine, notes=record["notes"], current=c["labels"]
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

    for _step in range(max(1, target)):
        if stop_pass or live >= target:
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
        index = _next_free_slot(root)
        if dry_run:
            # A DRY RUN CANNOT MODEL A CONVERGENCE IT CANNOT MEASURE. The old plan assumed +1 per
            # call and printed N steps ending `converged`, while the real pass on the same box
            # issued ONE call and ended under-target (round 4, finding 4). Say what a plan knows:
            # the call it WOULD make, and that the result is measured by the real pass.
            record["actions"].append(
                f"would ask the provisioner for install slot #{index} (mem_available_mb={before}); "
                "how many listeners that yields is MEASURED by a real pass, not predicted here"
            )
            break
        try:
            note = provision(index)
        except ProvisionerRefused as exc:
            record["problem_kind"] = "refusal"
            record["notes"].append(
                f"provisioner REFUSED slot #{index}: {exc} — its own headroom guard is stricter "
                "than this tool's measured ceiling, so nothing was added (a refusal is an answer, "
                "not a failure; the two predicates must be reconciled — see #9672)"
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
            record["notes"].append(
                f"stop: slot #{index} was installed but no listener came up (live={live}), so "
                "another call would repeat the same result — stopping instead of reporting a "
                "convergence that did not happen"
            )
            break
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
    if not record["problems"] and not record.get("unverified") and not record.get("problem_kind"):
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
        starvation = starvation_probe(repo, confirm_s)
        record["starvation"] = starvation.get("state")
        if starvation.get("state") == "starved":
            record["notes"].append(
                f"STARVATION {starvation['invariant']}: queued={starvation['queued']} "
                f"busy={starvation['busy']} online={starvation['online']} — work is waiting and the "
                "capacity that is up is idle; this is not demand, it is a queue that cannot reach "
                "the runners (labels/arch/gate). Nothing else watches this (agent-infra#2875)"
            )
        elif starvation.get("state") == "unmeasured":
            record["notes"].append(
                "starvation invariant NOT evaluated: "
                f"{starvation.get('detail')} — an unread queue is not an empty one"
            )

    if record["problems"]:
        record["verdict"] = "action-failed"
    elif record.get("problem_kind") == "refusal":
        record["verdict"] = "provisioner-refused"
    elif record.get("unverified"):
        # A measurement could not be taken (after a restart). Reported as unmeasurable rather than
        # "converged so nothing to see", because the box's state is genuinely unknown here.
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
        else:
            record["error"] = (
                "a measurement could not be taken mid-pass (the box could not be re-measured after "
                "an install) — the pass stopped there. The actions listed above were already "
                "performed BEFORE that point; nothing further was done."
            )
    elif starvation.get("state") == "starved":
        record["verdict"] = "starvation"
        record["error"] = (
            f"STARVATION ({starvation['invariant']}): queued={starvation['queued']} "
            f"busy={starvation['busy']} online={starvation['online']} — the queue has work and every "
            "online runner is idle. Nothing was changed by this alarm; the cause is a mismatch "
            "between what the jobs ask for and what the runners advertise (labels/arch/gate), not a "
            "lack of capacity (agent-infra#2875)"
        )
    elif live > ceil:
        record["verdict"] = "over-ceiling"
        record["notes"].append(
            f"over-ceiling: {live} live against a measured ceiling of {ceil} — {reading}; nothing "
            "removed (a runner that may be serving is never removed)"
        )
    elif live >= target and record["actions"]:
        record["verdict"] = "converged"
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
    unit_problems = installed_unit_cwd_problems()
    if unit_problems:
        record["unit_cwd_problems"] = unit_problems
        record["notes"].extend(f"unit cwd: {p}" for p in unit_problems)
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


def _worker_alive(runner: LocalRunner) -> bool:
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
    if key not in _WORKER_CACHE:
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
        help="audit the INSTALLED units' WorkingDirectory values; exit 5 when one is unusable",
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
        problems = installed_unit_cwd_problems(require_any=True)
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

    _log(record)
    if opts.json:
        print(json.dumps(record))
    else:
        print(f"repo={record['repo']} cell={os.uname().nodename} {record['reading']}")
        for c in record.get("runners", []):
            print(f"  {c['state']:<9} {c['name']} dir={c['dir']}")
        for a in record["actions"]:
            print(f"  - {a}")
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
    if record["verdict"] == "action-failed":
        return 3
    if record["verdict"] == "unmeasurable":
        return 2
    if record["verdict"] == "starvation":
        return 4
    return 0


if __name__ == "__main__":
    sys.exit(main())
