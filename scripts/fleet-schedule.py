#!/usr/bin/env python3
"""fleet-schedule.py — ONE portable runtime for the repo's declared recurring jobs (#1864).

WHY THIS EXISTS (measured 2026-10-16, across all three cmux cloud cells)
-----------------------------------------------------------------------
The harness declares every recurring job exactly once — as a launchd plist in
`templates/launchd/` — and delivers it with `scripts/install-launchd.sh`, which requires
launchd: plists under `~/Library/LaunchAgents`, `launchctl bootstrap`, `gui/<uid>`. The cells
are Linux. They have no launchd and never can, so the measured result was:

    scheduled jobs   Mac: 24        cell-1/2/3: 0 (12 stock systemd units, no fleet jobs)
    reap scripts     Mac: 4         cell-1/2/3: 0 present
    heartbeat        Mac: running   cell-1/2/3: DEAD
    bootstrap        Mac: installed cell-1/2/3: yes/yes/ABSENT

A fix that cannot be installed where three of four machines are is not a fix, and a
hand-ported second copy of ten plists guarantees the divergence #1759 exists to remove.

THE MECHANISM, DECIDED ONCE (and it is the issue's own second option)
---------------------------------------------------------------------
**A supervised in-session loop, not cron and not systemd timers.** Measured on a cmux cloud
cell (Ubuntu 24.04, uid 1000 `cmux`, HOME=/tmp/cell-home) on 2026-10-17:

    command -v crontab     -> ABSENT (the `cron` package is not installed)
    systemctl --user status -> "Failed to connect to bus: No medium found" (no user bus,
                              no lingering), while systemd IS pid 1 in SYSTEM mode

So a crontab entry or an enabled user timer would be installed-and-inert — precisely the false
PASS this issue is about ("a unit that loads and never runs"). A system-scope timer would work
but needs root on every cell and writes machine state outside the repo. The one thing a cell is
guaranteed to have is what it already uses to run lanes: tmux. So the schedule runs in a loop
under the cell's own lifetime, and it READS THE SAME PLISTS — there is no second job
declaration, so a new job added the Mac way reaches the cells with no further edit.

WHAT IT DOES
------------
  * parses `templates/launchd/*.plist` (Label, ProgramArguments, EnvironmentVariables,
    StartInterval / StartCalendarInterval, StandardOutPath/StandardErrorPath),
  * renders the same `{{PLACEHOLDER}}` set as `scripts/install-launchd.sh` (one list here, and
    an UNKNOWN placeholder is a loud error — never an empty argv),
  * runs each due job with a per-job lock, a bounded timeout, and the plist's own log targets,
  * records a STAMP per job (`state/fleet-schedule/jobs/<label>.json`: start, rc, duration) and a
    tick stamp for the loop itself, so "scheduled" is checkable rather than believed,
  * `--status` prints the per-machine truth: every declared job, its cadence, its last run and
    its last rc — or the reason it does not run on this machine, NAMED (never silently absent),
  * `--verify` FAILS when the loop is dead, its tick is stale, a job could not be scheduled, a
    job is overdue with no run, the declarations are EMPTY (zero jobs is a false PASS, not a clean
    run), a job's calendar can never come due again, or the STAGED copy this runtime was launched
    from differs from the checkout (`--check` reports that last one as a DRIFT note instead, since
    a Mac's farmed copy legitimately lags a working tree). A skipped job is reported as SKIP (with its
    reason) rather than failing: a Mac-free dependency (a tortoise venv, a swarm root) is a
    legitimate per-machine absence, and refusing to certify the whole layer over it would block a
    cell that can run every other job. A job that is RUNNING explains a stale tick (state/busy/,
    bounded by the job's own ceiling) instead of being mistaken for a wedged loop.

⛔ NOT A SECOND SCHEDULER ON macOS. On Darwin every subcommand delegates to
`scripts/install-launchd.sh`, which is unchanged. The loop exists only where launchd does not.

CONTRACT
  python3 fleet-schedule.py --check       DECLARATIONS only: parse every template with this
                                         runtime's loader, print ERROR/SKIP/ok per job, write
                                         nothing, need no loop. Exit 1 if any declaration cannot
                                         be run (or if every job is skipped), 3 if there are no
                                         declarations at all. Runs on EVERY platform including
                                         macOS; `scripts/fleet-schedule.test.sh` is the pre-merge
                                         gate, and this verb is what it drives against the shipped
                                         set.
  python3 fleet-schedule.py --install     parse, run the DUE jobs now, start the loop, verify.
                                         Non-zero if the job set cannot be parsed, a job target
                                         is broken, or the loop does not come up.
  python3 fleet-schedule.py --status      per-job truth table (never changes anything).
  python3 fleet-schedule.py --verify      gate: exit 1 on a dead loop, a stale tick, a broken or
                                         unknown placeholder, or an overdue job.
  python3 fleet-schedule.py --start       start the loop (idempotent).
  python3 fleet-schedule.py --stop        create the OFF switch and stop the loop.
  python3 fleet-schedule.py --loop        the loop itself (what --start spawns; not for typing).
  python3 fleet-schedule.py --help

EXIT CODES
  0 ok · 1 the job set is broken or the schedule did not verify · 3 NO JOB DECLARATIONS FOUND
  (there is no templates/launchd to read and no remembered pointer). 3 is distinct on purpose: the
  cell's start path must not be bricked by a cell whose layer predates this one — it warns loudly
  and lets bring-up be the gate that installs the layer.

ENV
  TEMPLATES_DIR       plist dir (default: <checkout>/templates/launchd)
  INFRA_ROOT          the agent-infra checkout the plists are read from (default: this script's
                      checkout, then $AGENT_INFRA_PATH, then $HOME/agent-infra)
  FLEET_SCHEDULE_STATE  state dir (default: $HOME/.pi/agent/state/fleet-schedule)
  FLEET_SCHEDULE_TICK   seconds between passes (default 60)
  FLEET_SCHEDULE_JOB_TIMEOUT  per-job ceiling in seconds (default 1800) — a job that exceeds it
                      is killed and stamped rc=124, LOUDLY; a hung job must never wedge the loop.
  CELL_HOME / HOME    the home the jobs run as (the plist {{HOME}})
"""

from __future__ import annotations

import errno
import json
import os
import re
import signal
import subprocess
import sys
import time
from datetime import datetime, timedelta

INFRA_ROOT = ""
TEMPLATES_DIR = ""
STATE = ""
TICK = 0
JOB_TIMEOUT = 0

# The placeholder set — the SAME names `scripts/install-launchd.sh` renders, whose own
# PLIST_PLACEHOLDERS array is the contract. A name added there and not here turns every cell's
# --install/--start into a refusal, so the two lists must move together — and they DID drift:
# #2639 added AI_DRAINER_* / AI_MULTI_REPO_* to the installer only, which made the shipped
# ai-drainer template an ERROR on every cell and left cell4 with no scheduler at all (measured
# 2026-10-27: MainPID=0, no controller, no reaping, no liveness, no canary). agent-infra#2804 is
# that placeholder half on its own; #2908 is the cell-level symptom.
#
# ⛔ THE LISTS ARE COMPARED, NOT TRUSTED. `scripts/fleet-schedule.test.sh` reads this tuple and
# install-launchd.sh's array and fails on ANY difference, and it self-proves the check by running
# it against a mutated copy (a guard that cannot fail is the defect this repo keeps re-finding).
# That is why a third copy of the set — the `{{NAME}}` tokens actually present in
# templates/launchd/*.plist — is checked too.
#
# A template that carries any OTHER {{NAME}} is an error here, not an empty string: the launchd
# renderer would substitute empty for a name it does not know too, so the two backends agree
# only because the list is a contract, and this one refuses rather than guesses.
PLACEHOLDERS = (
    "HOME",
    "PATH",
    "AGENT_INFRA_PATH",
    "TORTOISE_REPO",
    "SWARM_ROOT",
    "SWARM_ENV_FILE",
    "PYTHON_BIN",
    "PI_BIN_DIR",
    "WORKTREE_HYGIENE_MODE",
    "REAP_ORPHAN_MODE",
    # ⛔ ENV-ONLY WITH NO DEFAULT, exactly like install-launchd.sh treats them — and here the
    # reason is the same one that put them there: a plain placeholder would put a LANE DISPATCHER
    # (ai-drainer) and a SECOND CONTROLLER (ai-multi-repo, which double-dispatches every queue)
    # on every machine in the fleet. Unset ⇒ the template is SKIPPED, named and loud; that is the
    # designed arm, not a degraded one.
    "AI_DRAINER_O",
    "AI_DRAINER_STATE",
    "AI_MULTI_REPO_SLUG",
    "AI_MULTI_REPO_REPO",
    "AI_MULTI_REPO_STATE",
)
PLACEHOLDER_RE = re.compile(r"\{\{([A-Z_][A-Z0-9_]*)\}\}")


# ──────────────────────────────────────────────────────────────── paths & placeholders


def resolve_infra_root() -> str:
    """The checkout the plists are read from — same order as install-launchd.sh's contract."""
    here = os.path.dirname(os.path.abspath(__file__))
    cands = [
        os.environ.get("INFRA_ROOT", ""),
        # `here` is <checkout>/scripts in the repo and ~/.pi/agent/scripts once farmed; only the
        # FORMER has declarations, and the latter must fall through (it is not a checkout).
        os.path.dirname(here),
        os.environ.get("AGENT_INFRA_PATH", ""),
        os.path.join(os.environ.get("HOME", ""), "agent-infra"),
    ]
    for cand in cands:
        if cand and os.path.isfile(os.path.join(cand, "templates", "launchd", "RETIRED")):
            return os.path.abspath(cand)
    # The far end of a cell's farmed layer is ~/.pi/agent/scripts/fleet-schedule.py: `here` is
    # NOT a checkout there, which is why the caller must pass INFRA_ROOT (cloud-cell-bringup.sh
    # does — it already resolved the checkout the layer was installed from).
    return ""


def wt_hygiene_mode(home: str) -> str:
    """`--apply` only when the arming record exists AND names who armed it and when — the SAME
    two-key test scripts/install-launchd.sh's wt_hygiene_mode() applies. It ships DISARMED, so
    the default is `--dry-run`.

    ⛔ NEVER empty. install-launchd.sh MATERIALISES this value rather than leaving the job to
    read an env default at run time, and an empty argument here would mean the sweeper runs with
    no mode at all — neither a dry run nor an apply — which is the one shape that reads as
    armed without being armed. The value is therefore always one of the two flags.
    """
    record = os.environ.get("WORKTREE_HYGIENE_ARM_FILE") or os.path.join(
        home, ".pi", "agent", "state", "worktree-hygiene.armed"
    )
    try:
        with open(record, encoding="utf-8", errors="replace") as fh:
            body = fh.read()
    except OSError:
        return "--dry-run"
    if re.search(r"^armed-by=.", body, re.M) and re.search(r"^armed-date=.", body, re.M):
        return "--apply"
    return "--dry-run"


def reap_orphan_mode(home: str) -> str:
    """`0` (apply) only when the arming record names who armed it and when — the SAME two-key
    test scripts/install-launchd.sh's reap_orphan_mode() applies. It ships DISARMED, so the
    default is `1` (REAP_ORPHAN_DRY_RUN=1 ⇒ --dry-run): the safe value.

    ⛔ NEVER empty. The plist renders this into REAP_ORPHAN_DRY_RUN, and an empty value is
    neither "on" nor "off" — the one shape that reads as armed without being armed. The
    arming record is the SAME file the installer uses, so a cell armed by hand is armed here.
    """
    record = os.environ.get("REAP_ORPHAN_ARM_FILE") or os.path.join(
        home, ".pi", "agent", "state", "pi-reap-orphans.armed"
    )
    try:
        with open(record, encoding="utf-8", errors="replace") as fh:
            body = fh.read()
    except OSError:
        return "1"
    if re.search(r"^armed-by=.", body, re.M) and re.search(r"^armed-date=.", body, re.M):
        return "0"
    return "1"


def placeholder_values() -> dict:
    """Resolve every placeholder in PLACEHOLDERS. Empty string means 'unresolved' (SKIPPED)."""
    home = os.environ.get("CELL_HOME") or os.environ.get("HOME") or ""
    infra = INFRA_ROOT
    tortoise = os.environ.get("TORTOISE_REPO", "")
    if not tortoise or not os.path.isdir(tortoise):
        tortoise = ""
        for cand in (
            os.path.join(home, "Documents", "GitHub", "tortoise"),
            os.path.join(infra, "..", "tortoise") if infra else "",
            os.path.join(home, "tortoise"),
        ):
            if cand and os.path.isdir(os.path.join(cand, ".git")):
                tortoise = os.path.abspath(cand)
                break
    swarm_root = os.environ.get("SWARM_ROOT", "")
    swarm_py = os.path.join(swarm_root, ".venv", "bin", "python") if swarm_root else ""
    python_bin = os.environ.get("PYTHON_BIN", "")
    if not python_bin:
        python_bin = swarm_py if swarm_py and os.access(swarm_py, os.X_OK) else (
            subprocess.run(["sh", "-c", "command -v python3"], capture_output=True, text=True).stdout.strip()
        )
    pi_bin = os.environ.get("PI_NODE_BIN", "")
    if pi_bin:
        pi_bin_dir = os.path.dirname(pi_bin)
    else:
        found = subprocess.run(["sh", "-c", "command -v pi"], capture_output=True, text=True).stdout.strip()
        pi_bin_dir = os.path.dirname(found) if found else "/usr/local/bin"
    return {
        "HOME": home,
        # NO shim-dir stripping here, and that is deliberate rather than drift: the macOS
        # transform in install-launchd.sh drops `*/shims` because launchd cannot EXEC through
        # ~/Documents (TCC). There is no such wall on Linux, and dropping a PATH entry a job
        # legitimately uses would be the divergence.
        "PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin"),
        "AGENT_INFRA_PATH": infra,
        "TORTOISE_REPO": tortoise,
        "SWARM_ROOT": swarm_root,
        "SWARM_ENV_FILE": os.environ.get("SWARM_ENV_FILE") or os.path.join(home, ".swarm.env"),
        "PYTHON_BIN": python_bin,
        "PI_BIN_DIR": pi_bin_dir,
        "WORKTREE_HYGIENE_MODE": wt_hygiene_mode(home),
        "REAP_ORPHAN_MODE": reap_orphan_mode(home),
        # ⛔ ENV-ONLY, EMPTY MEANS SKIP — never defaulted. These three pairs identify a SECOND
        # dispatcher and a SECOND controller; a default here would put both on every box that
        # installed the layer (see the comment at PLACEHOLDERS). Empty ⇒ named SKIP.
        "AI_DRAINER_O": os.environ.get("AI_DRAINER_O", ""),
        "AI_DRAINER_STATE": os.environ.get("AI_DRAINER_STATE", ""),
        "AI_MULTI_REPO_SLUG": os.environ.get("AI_MULTI_REPO_SLUG", ""),
        "AI_MULTI_REPO_REPO": os.environ.get("AI_MULTI_REPO_REPO", ""),
        "AI_MULTI_REPO_STATE": os.environ.get("AI_MULTI_REPO_STATE", ""),
    }


def render(text: str, values: dict) -> tuple:
    """(rendered, used_empty, unknown) — never renders an unresolved value silently."""
    unknown = {m for m in PLACEHOLDER_RE.findall(text) if m not in PLACEHOLDERS}
    used_empty = set()

    def sub(match):
        name = match.group(1)
        if name not in PLACEHOLDERS:
            return match.group(0)
        value = values.get(name, "")
        if not value:
            used_empty.add(name)
        return value

    return PLACEHOLDER_RE.sub(sub, text), used_empty, unknown


# ──────────────────────────────────────────────────────────────── job declarations


def plist_true(value) -> bool:
    """Is this plist entry launchd's TRUE? Read by VALUE, never by identity or truthiness.

    `<true/>` reads as `True`, and `1 is not True` — a plist round-tripped through JSON, YAML or
    `plutil -convert` carries the INTEGER 1 where the schema says boolean, so an `is True` test
    reads a valid declaration as ABSENT. Truthiness is not the fix either: the string "NO" is
    truthy, and so is `{"SuccessfulExit": false}` — the very dict whose conditions say the
    opposite of what a bare truthiness test would conclude.
    """
    return value is True or (isinstance(value, int) and not isinstance(value, bool) and value == 1)


def resident_declaration(data) -> str:
    """Which plist key declares this job's body a RESIDENT SERVICE, or "" if none does.

    ⛔ RESIDENCY IS DECLARED, BECAUSE THIS RUNTIME CANNOT WITNESS IT. The tick loop starts a job and
    kills it at FLEET_SCHEDULE_JOB_TIMEOUT; launchd supervises it and restarts it. Those are not
    the same contract, and only the body's own declaration says which one applies — nothing here
    can tell whether a program returns.

    launchd accepts KeepAlive in TWO documented forms and BOTH are a resident service: `<true/>`
    ("keep it running") and a DICT of restart conditions (`{"SuccessfulExit": false}`,
    `{"Crashed": true}`, `PathState`, `NetworkState`, `OtherJobEnabled`). This read only
    `data.get("KeepAlive") is True`, so the dict form was treated as ABSENT and the job was refused
    with "declare KeepAlive/RunAtLoad" — telling an operator to declare what they had already
    declared, and refusing the WHOLE layer over it. That is exactly the shape that left cell4 with
    no scheduler at all (agent-infra#2908, measured 2026-10-27: MainPID=0, no reaper canary). An
    unmodelled-but-VALID declaration must be ACCEPTED, so every variant of the documented form is
    read, and one it cannot enumerate (`{"PathState": {...}}`) still counts.

    An EMPTY dict is not a declaration: launchd's dict form is a SET of conditions, and an empty
    one states none — this runtime declines to launder it into a skip, so it stays the error it
    already was.

    `FleetResident` is this runtime's own key (launchd ignores keys it does not know — measured
    2026-10-27: a plist carrying it bootstrapped rc=0 and booted out clean), for the one thing no
    launchd key can say: "this body may never return, even though the plist schedules it".
    `RunAtLoad` is deliberately NOT read here — shipped templates use it as "also run once at
    load" on a bounded job (`com.tortoise.ci-runner-gate`, which this loader reads, and the
    `reaper/` `harness-apply/` templates another installer reads), and treating it as residency
    would silently stop those jobs on every cell. It is read where it does mean residency: a
    template with NO schedule at all, whose only start is its load (worker-supply).
    """
    keep_alive = data.get("KeepAlive")
    if plist_true(keep_alive):
        return "KeepAlive"
    if isinstance(keep_alive, dict) and keep_alive:
        return "KeepAlive dict"
    if plist_true(data.get("FleetResident")):
        return "FleetResident"
    return ""


class Job:
    def __init__(self, label, argv, env, interval, calendar, stdout, stderr):
        self.label = label
        self.argv = argv
        self.env = env
        self.interval = interval
        self.calendar = calendar
        self.stdout = stdout
        self.stderr = stderr
        self.skip = ""   # non-empty → this machine does not run it (named, never silent)
        self.error = ""  # non-empty → the declaration itself is broken (verify FAILS)
        self.daemon = False  # a resident service: a body this loop cannot supervise
        self.resident_decl = ""  # WHICH plist key declared that (named in every skip/error)

    @property
    def cadence(self):
        if self.daemon:
            return "daemon (%s)" % (self.resident_decl or "resident")
        if self.calendar is not None:
            c = self.calendar
            if "_all" in c:
                c = c["_all"][0]
            parts = []
            if "Weekday" in c:
                parts.append("W%s" % c["Weekday"])
            if "Day" in c:
                parts.append("D%s" % c["Day"])
            if "Month" in c:
                parts.append("M%s" % c["Month"])
            if "Hour" in c or "Minute" in c:
                parts.append("%02d:%02d" % (int(c.get("Hour", 0)), int(c.get("Minute", 0))))
            return "calendar " + " ".join(parts)
        return "every %s" % human_secs(self.interval or 0)

    def log_path(self):
        # The plist's own target, so the evidence lands where the macOS scheduler puts it too.
        # APPEND, never truncate: truncating a shared /tmp path on every run is the
        # symlink-truncation surface the plists' own comments call out.
        # ⚠️ launchd writes StandardOutPath and StandardErrorPath separately; the loop merges a
        # job's stderr into the ONE target its plist declares. That is not a simplification of the
        # contract — every shipped plist that declares either declares BOTH with the same value —
        # and the alternative (a second file nobody reads) would let a job's errors sit in a file
        # the operator has no reason to open.
        if self.stdout:
            return self.stdout
        if self.stderr:
            return self.stderr
        return os.path.join(STATE, "logs", self.label + ".log")


def human_secs(seconds: float) -> str:
    seconds = int(seconds)
    if seconds < 90:
        return "%ds" % seconds
    if seconds < 3600:
        return "%dm" % round(seconds / 60)
    if seconds < 86400:
        return "%dh" % round(seconds / 3600)
    return "%dd" % round(seconds / 86400)


def load_jobs(check_targets: bool = True) -> list:
    """Parse every plist in TEMPLATES_DIR into a Job. Raises ScheduleError for a broken set.

    `check_targets=False` grades the DECLARATIONS only, and is what `--check` uses: whether
    `{{HOME}}/.pi/agent/scripts/x.sh` exists is a fact about the MACHINE (a farm that is or is
    not installed here), never about the declaration — grading it in CI, where no farm is
    installed, would refuse a perfectly good template set for the runner's own missing layering.
    The layer's real existence is already the cell's gate: `--install`/`--verify`.

    RETIRED labels are read from the same manifest install-launchd.sh uses; a retired label that
    still has a template is a loud error in both backends (that file says so). A label in
    RETIRED with no template is nothing to do here: the loop only runs what is declared.
    """
    if not os.path.isdir(TEMPLATES_DIR):
        raise ScheduleError("template dir not found: %s" % TEMPLATES_DIR)
    try:
        import plistlib
    except ImportError:  # pragma: no cover - python3 always ships plistlib
        raise ScheduleError("python3 has no plistlib — cannot read the job declarations")

    retired_path = os.path.join(TEMPLATES_DIR, "RETIRED")
    retired = set()
    if os.path.isfile(retired_path):
        with open(retired_path) as fh:
            for line in fh:
                line = line.strip()
                if line and not line.startswith("#"):
                    retired.add(line)

    values = placeholder_values()
    jobs = []
    for name in sorted(os.listdir(TEMPLATES_DIR)):
        if not name.endswith(".plist"):
            continue
        path = os.path.join(TEMPLATES_DIR, name)
        label_from_file = name[: -len(".plist")]
        try:
            with open(path, "rb") as fh:
                data = plistlib.load(fh)
        except Exception as exc:
            raise ScheduleError("cannot parse %s: %s" % (path, exc))

        label = data.get("Label") or label_from_file
        job = Job(label, [], {}, None, None, "", "")
        # ⛔ A Label is a PATH COMPONENT here (stamp, lock, default log), so it is validated BEFORE
        # it is used as one. launchd accepts any string; this runtime cannot: `../x` writes the
        # stamp/log outside the state dir, and a label containing `/` makes `os.open` of the lock
        # path raise — which, with no per-job containment, used to terminate the WHOLE loop on the
        # next tick. Refuse the declaration instead, by name.
        if not re.fullmatch(r"[A-Za-z0-9._-]+", label):
            job.error = (
                "Label %r is not a safe file name — only letters, digits, '.', '_' and '-' are "
                "accepted (the label names this job's stamp, lock and default log)" % label
            )
        if label in retired:
            raise ScheduleError(
                "%s is in RETIRED but a template still exists — remove one or the other"
                % label
            )

        # ⛔ RESIDENCY IS DECIDED BEFORE THE SCHEDULE, because a SCHEDULE MUST NOT MASK IT. The
        # decision used to live INSIDE the no-schedule branch, so `KeepAlive: {"SuccessfulExit":
        # false}` (a valid declaration, read as absent — see resident_declaration) AND any resident
        # body that also carried a StartInterval fell through as "scheduled": the loop would start
        # it and kill it at JOB_TIMEOUT. That is a controller restarted every ceiling, not a
        # service, and it armed the moment an operator set AI_MULTI_REPO_* on a cell — the plist's
        # prose said so and nothing enforced it. Residency is now a property of the BODY, and a
        # resident body is REFUSED BY NAME below whatever its schedule says.
        job.resident_decl = resident_declaration(data)
        job.daemon = bool(job.resident_decl)

        # Schedule. A template with NEITHER key would run never, and a job that loads and never
        # runs is the whole defect this file exists to close: say so loudly.
        raw_interval = data.get("StartInterval")
        raw_calendar = data.get("StartCalendarInterval")
        if isinstance(raw_interval, int) and raw_interval > 0:
            job.interval = raw_interval
        elif isinstance(raw_calendar, dict):
            job.calendar = raw_calendar
        elif isinstance(raw_calendar, list) and raw_calendar and all(
            isinstance(x, dict) for x in raw_calendar
        ):
            # launchd allows an array of calendar dicts. A single-entry array is the same dict; a
            # multi-entry one is matched as "any of these", which is what launchd does with it.
            job.calendar = {"_all": raw_calendar} if len(raw_calendar) > 1 else raw_calendar[0]
        elif not job.daemon and plist_true(data.get("RunAtLoad")):
            # ⛔ RunAtLoad IS READ HERE AND NOWHERE ELSE: with no interval and no calendar, a load
            # start is the ONLY thing that ever starts the job, so a `RunAtLoad: true` template is
            # a service launchd keeps (worker-supply). With a schedule it means "also run once at
            # load" on a bounded pass — `com.tortoise.ci-runner-gate` here, plus the `reaper/` and
            # `harness-apply/` templates another installer reads — so reading it as residency
            # everywhere would silently take those jobs off every cell.
            job.daemon = True
            job.resident_decl = "RunAtLoad"
        elif not job.daemon:
            job.error = (
                "no StartInterval and no StartCalendarInterval — a job with no schedule would "
                "never run (launchd accepts it silently; this runtime does not). If it is a "
                "long-lived service, declare KeepAlive (true, or a condition dict — both forms "
                "count) or RunAtLoad, or FleetResident for a resident body with a schedule, and "
                "it is a named SKIP instead"
            )

        argv = data.get("ProgramArguments") or []
        if not isinstance(argv, list) or not argv:
            job.error = job.error or "no ProgramArguments"
        rendered_argv, used_empty, unknown = [], set(), set()
        for arg in argv:
            if not isinstance(arg, str):
                job.error = job.error or "ProgramArguments holds a non-string entry"
                continue
            text, empty, bad = render(arg, values)
            rendered_argv.append(text)
            used_empty |= empty
            unknown |= bad
        job.argv = rendered_argv

        raw_env = data.get("EnvironmentVariables") or {}
        env, env_empty = {}, set()
        if isinstance(raw_env, dict):
            for key, value in raw_env.items():
                text, empty, bad = render(str(value), values)
                env[str(key)] = text
                env_empty |= empty
                unknown |= bad
        job.env = env
        used_empty |= env_empty

        stdout_raw = data.get("StandardOutPath") or ""
        stderr_raw = data.get("StandardErrorPath") or ""
        job.stdout, out_empty, out_bad = render(stdout_raw, values)
        job.stderr = job.stdout
        if stderr_raw and stderr_raw != stdout_raw:
            job.stderr, err_empty, err_bad = render(stderr_raw, values)
            used_empty |= err_empty
            unknown |= err_bad
        used_empty |= out_empty
        unknown |= out_bad

        if unknown and not job.error:
            job.error = (
                "placeholder(s) this runtime does not know: %s — teach fleet-schedule.py the "
                "value, or the job would run with an EMPTY argument"
                % ", ".join("{{%s}}" % u for u in sorted(unknown))
            )
        if used_empty and not job.error:
            job.skip = (
                "unresolved placeholder(s) %s — absent on this machine"
                % ", ".join("{{%s}}" % u for u in sorted(used_empty))
            )

        if check_targets and not job.error and not job.skip:
            # "A dead job must never be installed" — the same rule install-launchd.sh enforces
            # before it bootstraps a plist: every absolute path in argv must resolve. WHERE it is
            # missing decides whether that is fatal, and the split is the layer's OWN files versus
            # somebody else's checkout:
            #   * under {{HOME}}/.pi/agent/ — this machine did not receive the layer, so the farm
            #     is incomplete. FATAL, because a cell certified over a half-installed farm runs
            #     fewer jobs than its schedule claims and nothing says which.
            #   * anywhere else (a tortoise checkout without a .venv, say) — a per-machine absence,
            #     exactly like an unresolved placeholder. SKIP, named, never silent.
            layer_root = values.get("HOME", "")
            layer_prefix = os.path.join(layer_root, ".pi", "agent") if layer_root else ""
            for idx, arg in enumerate(job.argv):
                if not arg.startswith("/"):
                    continue
                if os.path.exists(arg):
                    # ⛔ argv[0] IS THE PROGRAM THAT GETS EXECUTED, and "the file exists" is not
                    # "it can run". A target that lost its +x bit (or whose shebang interpreter
                    # is gone) fails EVERY run with rc=127 from subprocess, and before this check
                    # that failure produced a stamp — which cmd_verify counts as live. Measured:
                    # a plist aimed at a chmod 644 script certified "1 job(s) live" with a stamp
                    # of {"rc": 127}, so a cell reached CELL READY with a job that had never once
                    # run. Refused at declaration time instead, where the fix is obvious.
                    if idx == 0 and not os.access(arg, os.X_OK):
                        # ⛔ THE SAME LAYER/THIRD-PARTY SPLIT AS A MISSING TARGET, deliberately.
                        # A per-machine absence must not block a cell (a tortoise checkout with no
                        # .venv is a named SKIP, not a refusal), and "the .venv exists but its
                        # python lost its mode bits" is the same class of fact: this machine
                        # cannot run that job. Escalating it to job.error would refuse CELL READY
                        # on every cell over one third-party directory — the opposite of the rule
                        # that one optional job must not block a cell running every other one.
                        # INSIDE the layer it stays fatal: that farm is ours to install, and a
                        # half-installed farm must never be certified.
                        if layer_prefix and (arg == layer_prefix or arg.startswith(layer_prefix + os.sep)):
                            job.error = (
                                "not executable: %s exists but cannot be executed — every run "
                                "would fail with rc=127, so the job is refused rather than "
                                "certified" % arg
                            )
                        else:
                            job.skip = (
                                "target not executable on this machine: %s exists but cannot be "
                                "executed (every run would fail with rc=127)" % arg
                            )
                        break
                    continue
                if layer_prefix and (arg == layer_prefix or arg.startswith(layer_prefix + os.sep)):
                    job.error = (
                        "broken target: %s does not resolve — the farm is INCOMPLETE (install it: "
                        "pi-bootstrap/cell-install.sh)" % arg
                    )
                else:
                    job.skip = "target absent on this machine: %s" % arg
                break
        # ⛔ PLACED AFTER THE TARGET CHECKS ON PURPOSE: a daemon's paths must still be validated, so
        # a KeepAlive template pointed at a missing script is an ERROR (a broken farm), never a skip.
        if job.daemon and not job.error and not job.skip:
            job.skip = (
                "declared %s — a resident SERVICE body, which this runtime cannot supervise: the "
                "tick loop would start it and kill it at JOB_TIMEOUT, so it would be a restart "
                "every ceiling rather than a service. A resident job on a cell belongs to the "
                "cell's own supervisor (cloud-cell-supervisor.sh), never to this loop"
                % job.resident_decl
            )
        jobs.append(job)
    # ⛔ ZERO JOBS IS A FAILURE, not a clean run. A templates dir that EXISTS but holds no
    # *.plist (a sparse checkout, a stale TEMPLATES_DIR pointer, a dir that only has RETIRED)
    # used to verify green — "SCHEDULE VERIFIED — 0 job(s) live" — which is exactly the false
    # PASS this file exists to close: the cell is certified while running none of its jobs.
    if not jobs:
        raise ScheduleError(
            "no *.plist job declarations in %s — a schedule with ZERO jobs is the gap this "
            "runtime closes (#1864), so it is refused rather than certified" % TEMPLATES_DIR
        )
    return jobs


class ScheduleError(Exception):
    pass


# ──────────────────────────────────────────────────────────────── state & stamps


def stamp_path(label):
    return os.path.join(STATE, "jobs", label + ".json")


def read_stamp(label):
    try:
        with open(stamp_path(label)) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def write_stamp(label, started, rc, duration):
    os.makedirs(os.path.join(STATE, "jobs"), exist_ok=True)
    tmp = stamp_path(label) + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(
            {"label": label, "started": started, "finished": time.time(), "rc": rc, "duration": duration},
            fh,
            indent=2,
        )
    # Through a rename, so a reader (--status/--verify, or the next pass) can never observe a
    # half-written stamp and read it as "never run".
    os.replace(tmp, stamp_path(label))


def tick_age():
    try:
        return time.time() - os.path.getmtime(os.path.join(STATE, "tick"))
    except OSError:
        return None


# ────────────────────────────────────────────────────── the busy heartbeat (long-job honesty)
# The loop is single-threaded and a pass may legitimately last for JOB_TIMEOUT (a job the plists
# budget 1800s for). Without a marker, `--verify` cannot tell "one long job is running" from "the
# loop is wedged", and it refused the first — the same condition its OVERDUE arm explicitly
# excuses ("a 6-hour job 1 hour late is the loop simply being busy"). So a job announces itself
# while it runs, with a DEADLINE, and the exemption is bounded by that deadline: a job that
# crashed hard (SIGKILL, so no finally) stops excusing the tick moments after its ceiling.
def busy_path(label):
    return os.path.join(STATE, "busy", label + ".json")


def mark_busy(label, started):
    """Announce that this job is running, with an expiring deadline. Best-effort: a job must run
    even if the marker cannot be written, and an unwritable marker simply means no exemption."""
    try:
        os.makedirs(os.path.join(STATE, "busy"), exist_ok=True)
        with open(busy_path(label), "w") as fh:
            json.dump(
                {
                    "label": label,
                    "started": started,
                    "pid": os.getpid(),
                    # subprocess.run kills the child at JOB_TIMEOUT, so no pass can outlive this.
                    "deadline": started + float(JOB_TIMEOUT) + 3 * float(TICK or 0),
                },
                fh,
            )
    except OSError:
        pass


def clear_busy(label):
    try:
        os.unlink(busy_path(label))
    except OSError:
        pass


def busy_jobs(now):
    """[(label, started)] for jobs whose announced run has NOT passed its deadline."""
    live = []
    directory = os.path.join(STATE, "busy")
    try:
        names = sorted(os.listdir(directory))
    except OSError:
        return live
    for name in names:
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(directory, name)) as fh:
                entry = json.load(fh)
            deadline = float(entry["deadline"])
            started = float(entry.get("started") or 0)
        except (OSError, ValueError, KeyError, TypeError):
            continue
        # ⛔ THE DEADLINE IS SELF-DECLARED, so it is CLAMPED by the budget THIS verifier enforces.
        # Otherwise a marker written once under a large FLEET_SCHEDULE_JOB_TIMEOUT (or left behind
        # by a loop that later ran with one) would excuse a stale tick AND every overdue job for
        # that whole window, and the doc's "the exemption ends with that deadline" would only hold
        # for markers written under the current config. The clamp keeps the grace a job is owed at
        # the ceiling this process would itself allow, plus the tick slack.
        # ⛔ AN UNUSABLE START IS NOT AN EXEMPTION. The clamp below needs `started`; without it a
        # marker naming only a far-future deadline would excuse the stale tick — and every job's
        # OVERDUE arm — FOR EVER, which is the exemption this file's contract says is bounded.
        # Our own writer always stamps `started` and a deadline derived from the budget, so a
        # marker lacking it is foreign/corrupted/restored, and dropping it fails CLOSED: the tick
        # then reads as stale (correctly) instead of as "a long job is running".
        if started <= 0:
            continue
        # ⛔ AND A START DATED IN THE FUTURE IS NOT AN EXEMPTION EITHER. The clamp below is
        # computed FROM the marker's own `started`, so a future-dated one yields a future deadline
        # and `now <= deadline` holds for the whole span — a wedged loop certified as busy for
        # years. Reachable without corruption: our writer stamps `time.time()`, so a backward clock
        # step during a run (VM resume, NTP correcting a fast RTC — the same cases the stamp arm
        # refuses) leaves a SIGKILL-surviving marker future-dated, and a restored state dir does it
        # too. Same slack the stamp arm uses, so skew inside one poll is still tolerated.
        if started > now + max(3 * TICK, 300):
            continue
        deadline = min(deadline, started + JOB_TIMEOUT + 3 * TICK)
        if now <= deadline:
            live.append((entry.get("label") or name[: -len(".json")], started))
    return live


def mark_tick():
    os.makedirs(STATE, exist_ok=True)
    path = os.path.join(STATE, "tick")
    with open(path, "w") as fh:
        fh.write("%d\n" % int(time.time()))


def loop_pid():
    try:
        with open(os.path.join(STATE, "loop.pid")) as fh:
            pid = int(fh.read().strip().split()[0])
    except (OSError, ValueError):
        return None
    if not pid_alive(pid):
        return None
    return pid


def pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError as exc:
        return exc.errno == errno.EPERM


def pid_is_our_loop(pid):
    """A pid alone is not the loop: a recycled pid makes a dead scheduler read as running.

    The same class AGENTS.md names for a first-match reading — so the command line is checked,
    not just the number.
    """
    try:
        with open("/proc/%d/cmdline" % pid, "rb") as fh:
            cmdline = fh.read().replace(b"\0", b" ").decode("utf-8", "replace")
    except OSError:
        cmdline = ""
        try:
            out = subprocess.run(
                ["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True
            )
            cmdline = out.stdout
        except OSError:
            return False
    return "fleet-schedule" in cmdline and "--loop" in cmdline


# ──────────────────────────────────────────────────────────────── due / calendar


def next_occurrence(calendar, after):
    """The first moment strictly after `after` matching the launchd calendar dict.

    Minute-stepping, bounded to 8 days, is deliberately dumb: it implements launchd's own
    semantics for PARTIAL dicts (only Hour → every hour, only Weekday → that day every hour) with
    no special cases to get wrong, and 8 days is one full week plus the current one.
    """
    start = datetime.fromtimestamp(after).replace(second=0, microsecond=0) + timedelta(minutes=1)
    # A Weekday/Hour/Minute calendar recurs within a week; a Day (or Month) one can be up to a year
    # away, and a window that is too small would read as "never due" — a job silently unscheduled,
    # which is this file's whole subject.
    # ⛔ The KEYS must be read from the UNION of an `_all` array's entries, not from the wrapper
    # dict: a multi-entry StartCalendarInterval is stored as `{"_all": [...]}`, so testing the
    # wrapper for "Month"/"Day" saw neither and searched only 8 days — an annual entry was then
    # never found, `next_occurrence` returned None, and the job was reported live while being
    # permanently unschedulable.
    keys = set().union(*calendar["_all"]) if "_all" in calendar else set(calendar)
    window = 400 if ("Month" in keys or "Day" in keys) else 8
    for _ in range(window * 24 * 60):
        if calendar_matches(calendar, start):
            return start.timestamp()
        start += timedelta(minutes=1)
    return None


def calendar_matches(calendar, when):
    if "_all" in calendar:  # an array of dicts: the soonest match of any of them wins
        return any(calendar_matches(sub, when) for sub in calendar["_all"])
    if "Weekday" in calendar:
        # launchd: 0 and 7 are Sunday, 1..6 Monday..Saturday. datetime: Monday=0..Sunday=6.
        want = {(int(calendar["Weekday"]) - 1) % 7}
        if int(calendar["Weekday"]) == 7:
            want = {6}
        if when.weekday() not in want:
            return False
    if "Day" in calendar and when.day != int(calendar["Day"]):
        return False
    if "Month" in calendar and when.month != int(calendar["Month"]):
        return False
    if "Hour" in calendar and when.hour != int(calendar["Hour"]):
        return False
    if "Minute" in calendar and when.minute != int(calendar["Minute"]):
        return False
    return True


def due_at(job, stamp, now):
    """The epoch at which this job next becomes due (None = never)."""
    last = stamp.get("started") if stamp else None
    if last is None:
        return 0  # never run: due immediately, which is how a fresh cell proves itself
    if job.calendar is not None:
        return next_occurrence(job.calendar, float(last))
    return float(last) + float(job.interval or 0)


def is_due(job, stamp, now):
    at = due_at(job, stamp, now)
    return at is not None and now >= at


# ──────────────────────────────────────────────────────────────── running a job


def acquire_lock(label):
    """A per-job lock so the loop and an inline `--install` pass cannot run one job twice.

    Returns the lock path, or None when another run holds it. A lock whose pid is GONE is
    stolen: a crashed run must not disable its job forever (the abandoned-claim class).
    """
    locks = os.path.join(STATE, "locks")
    os.makedirs(locks, exist_ok=True)
    path = os.path.join(locks, label + ".lock")
    for _ in range(2):
        try:
            fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
            os.write(fd, ("%d\n" % os.getpid()).encode())
            os.close(fd)
            return path
        except FileExistsError:
            try:
                with open(path) as fh:
                    pid = int(fh.read().strip().split()[0])
            except (OSError, ValueError):
                pid = None
            if pid is not None and pid_alive(pid):
                return None
            try:
                os.unlink(path)
            except OSError:
                return None
    return None


def run_job(job):
    """Run one job to completion. Returns rc, or None when another run held the lock."""
    lock = acquire_lock(job.label)
    if lock is None:
        log("SKIP %s: already running (lock held)" % job.label)
        return None
    started = time.time()
    mark_busy(job.label, started)
    log_path = job.log_path()
    try:
        os.makedirs(os.path.dirname(log_path), exist_ok=True)
    except OSError:
        log_path = os.path.join(STATE, "logs", job.label + ".log")
        os.makedirs(os.path.dirname(log_path), exist_ok=True)

    env = {"HOME": os.environ.get("CELL_HOME") or os.environ.get("HOME", "")}
    for name in ("PATH", "LANG", "LC_ALL", "TMPDIR"):
        if os.environ.get(name):
            env[name] = os.environ[name]
    # The plist's EnvironmentVariables win, exactly as launchd applies them.
    env.update(job.env)
    if not env.get("HOME"):
        del env["HOME"]

    rc = None
    exec_failed = False
    try:
        with open(log_path, "a") as out:
            out.write(
                "\n=== fleet-schedule run %s start %s ===\n"
                % (job.label, datetime.now().isoformat(timespec="seconds"))
            )
            out.flush()
            proc = subprocess.run(
                job.argv,
                env=env,
                cwd="/",  # launchd's cwd for these plists is /; every path in them is absolute
                stdout=out,
                stderr=subprocess.STDOUT,
                timeout=JOB_TIMEOUT,
                close_fds=True,
            )
            rc = proc.returncode
            out.write(
                "=== fleet-schedule run %s end %s rc=%s (%.1fs) ===\n"
                % (job.label, datetime.now().isoformat(timespec="seconds"), rc, time.time() - started)
            )
    except subprocess.TimeoutExpired:
        rc = 124
        try:
            with open(log_path, "a") as out:
                out.write(
                    "=== fleet-schedule run %s KILLED after %ds (ceiling FLEET_SCHEDULE_JOB_TIMEOUT) ===\n"
                    % (job.label, JOB_TIMEOUT)
                )
        except OSError:
            pass
        log("TIMEOUT %s exceeded %ds — killed (rc=124); raise FLEET_SCHEDULE_JOB_TIMEOUT if that is wrong" % (job.label, JOB_TIMEOUT))
    except OSError as exc:
        # ⛔ THIS IS NOT A RUN. The runtime could not even spawn the job, so rc=127 here is OUR
        # sentinel, not an exit status the job produced — and a stamp for it certified a job that
        # has never run as live (see the finally block).
        rc = 127
        exec_failed = True
        log("ERROR %s could not be executed (%s)" % (job.label, exc))
    finally:
        # ⛔ ONLY A REAL rc IS A RUN. The loop's SIGTERM handler raises SystemExit (so `--stop` and
        # the supervisor's teardown actually work), which lands here with rc still None — and the
        # old code wrote a stamp carrying `"rc": null`. cmd_verify counts ANY stamp as "has run",
        # so a job interrupted mid-flight certified itself as live on the strength of an
        # interrupted run: the "a stamp with an rc" evidence claim, satisfied by a stamp with no
        # rc. Writing nothing is the truthful record — the previous stamp stands (a real run at an
        # earlier time), or the job is honestly still NEVER RUN.
        if rc is not None and not exec_failed:
            write_stamp(job.label, started, rc, time.time() - started)
        clear_busy(job.label)
        try:
            os.unlink(lock)
        except OSError:
            pass
    if exec_failed:
        # Say plainly that the job did NOT run, so a log reader is not told "RAN rc=127". No stamp
        # was written, so --verify keeps reporting this job as NEVER RUN until it can actually
        # execute — which is the truth, and is what the fatal bring-up gate needs to see.
        log(
            "NOT-RUN %s rc=%s — could not be EXECUTED, so no stamp was written and --verify will "
            "keep reporting it as never run" % (job.label, rc)
        )
        return rc
    log("RAN %s rc=%s in %.1fs (log %s)" % (job.label, rc, time.time() - started, log_path))
    return rc


def _stdout_is(path):
    """True when our stdout is already this file (see log())."""
    try:
        return os.path.samestat(os.fstat(sys.stdout.fileno()), os.stat(path))
    except (OSError, ValueError, AttributeError):
        return False


def log(message):
    line = "%s %s" % (datetime.now().strftime("%Y-%m-%d %H:%M:%S"), message)
    path = os.path.join(STATE, "loop.log")
    # ⛔ WRITE ONCE. spawn_loop points the loop's stdout at this very file, so appending here as
    # well put every loop line in loop.log TWICE — doubling the growth of the one file an operator
    # reads to find out what the loop is doing, and making a repeated line look like a repeated
    # pass. When our stdout already IS that file the print() below is the write; otherwise (a
    # foreground run, or a pipe) the file is not receiving it, so append explicitly.
    if not _stdout_is(path):
        try:
            os.makedirs(STATE, exist_ok=True)
            with open(path, "a") as fh:
                fh.write(line + "\n")
        except OSError:
            pass
    print(line, flush=True)


# ──────────────────────────────────────────────────────────────── the loop


def cmd_loop():
    off = os.path.join(STATE, "OFF")
    if os.path.exists(off):
        log("loop: OFF switch present (%s) — not starting" % off)
        return 0
    os.makedirs(STATE, exist_ok=True)
    pidfile = os.path.join(STATE, "loop.pid")
    theirs = loop_pid()
    # ⛔ `pid_is_our_loop`, NOT a bare pid. A pidfile holding a RECYCLED pid (any live process —
    # what a killed loop leaves behind) used to make every new instance log "already running" and
    # exit BEFORE writing its own pidfile, so the state never self-healed while that pid lived.
    if theirs and theirs != os.getpid() and pid_is_our_loop(theirs):
        log("loop: already running (pid %d) — this instance exits" % theirs)
        return 0
    with open(pidfile, "w") as fh:
        fh.write("%d\n" % os.getpid())

    def bye(signum, _frame):
        log("loop: signal %d — exiting" % signum)
        try:
            os.unlink(pidfile)
        except OSError:
            pass
        raise SystemExit(0)

    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        try:
            signal.signal(sig, bye)
        except (ValueError, OSError):
            pass

    log("loop: start pid=%d tick=%ds templates=%s" % (os.getpid(), TICK, TEMPLATES_DIR))
    jobs = None
    while True:
        if os.path.exists(off):
            log("loop: OFF switch appeared — exiting")
            break
        # RE-READ the declarations every pass: a merged template change (or a new job added the
        # Mac way) lands on the next tick with no reinstall, which is what makes "diverged from
        # the repo" structurally impossible rather than checked-for.
        try:
            jobs = load_jobs()
        except ScheduleError as exc:
            log("ERROR: cannot read the job declarations (%s) — keeping the previous set" % exc)
        # ⛔ The tick is stamped at the START of the pass, not after it: the pass is
        # single-threaded, so an end-of-pass stamp makes the tick's age equal the duration of the
        # job currently executing — and a job allowed to run for JOB_TIMEOUT (1800s by default,
        # 300s from the shipped templates onward) would then read as "the process exists but is
        # not passing" WHILE it is doing exactly what it was told.
        mark_tick()
        if jobs:
            now = time.time()
            for job in jobs:
                if job.error or job.skip:
                    continue
                if is_due(job, read_stamp(job.label), now):
                    # ⛔ ONE BROKEN DECLARATION MUST NOT STOP THE SET. Anything run_job raises
                    # (a bad log path, an unusable lock dir) used to escape here and terminate
                    # the loop, leaving every other job unscheduled until a human restarts it.
                    try:
                        run_job(job)
                    except Exception as exc:  # noqa: BLE001 — a loop must outlive one job
                        log("ERROR %s could not be run (%s: %s) — continuing with the set" % (job.label, type(exc).__name__, exc))
        time.sleep(max(5, TICK))
    try:
        os.unlink(pidfile)
    except OSError:
        pass
    return 0


def spawn_loop():
    log_path = os.path.join(STATE, "loop.log")
    os.makedirs(STATE, exist_ok=True)
    with open(log_path, "a") as out:
        subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), "--loop"],
            stdout=out,
            stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL,
            cwd="/",
            env=os.environ.copy(),
            start_new_session=True,  # survive the bring-up/exec session that started it
            close_fds=True,
        )
    # Wait (boundedly) for the loop to stamp its first tick, so "started" is not a claim about a
    # pid that died on line one.
    # ⛔ The poll matches the COMMENT above: a pid whose command line is the loop AND a stamped
    # first tick. Polling only the command line returned as soon as the child existed — before
    # mark_tick() — so `--install` verified immediately afterwards and failed a HEALTHY install on
    # "the loop has never ticked" whenever any job was due in that first pass.
    # ⛔ AND THE TICK MUST BE THIS INCARNATION'S: a tick merely PRESENT can be the one the PREVIOUS
    # loop left, so the poll returned before the new loop had passed at all and a healthy install
    # was refused with "the loop tick is Ns old" — the same false FAIL by a different route, and
    # the one a loaded cell (where bring-up actually runs) hits when the child starts slowly.
    # ⛔ And a failed poll returns None, never `loop_pid()`: that fallback handed back whatever pid
    # the pidfile held (a recycled pid) and reported it as the loop that had just started.
    spawned_at = time.time()
    for _ in range(50):
        time.sleep(0.2)
        pid = loop_pid()
        if pid and pid_is_our_loop(pid):
            age = tick_age()
            # 1 s of slack: the tick is stamped with this process's clock, and a tick older than
            # the spawn instant belongs to the incarnation that came before.
            if age is not None and age <= (time.time() - spawned_at) + 1.0:
                return pid
    return None


# ──────────────────────────────────────────────────────────────── reporting


def fmt_age(seconds):
    if seconds is None:
        return "never"
    if seconds < 120:
        return "%ds ago" % int(seconds)
    if seconds < 7200:
        return "%dm ago" % int(seconds / 60)
    if seconds < 172800:
        return "%dh ago" % int(seconds / 3600)
    return "%dd ago" % int(seconds / 86400)


def fmt_until(seconds):
    if seconds is None:
        return "-"
    if seconds <= 0:
        return "DUE"
    if seconds < 120:
        return "in %ds" % int(seconds)
    if seconds < 7200:
        return "in %dm" % int(seconds / 60)
    if seconds < 172800:
        return "in %dh" % int(seconds / 3600)
    return "in %dd" % int(seconds / 86400)


def print_table(jobs, now):
    for job in jobs:
        if job.error:
            print("  ERROR  %-38s %-18s %s" % (job.label, "-", job.error))
            continue
        if job.skip:
            print("  SKIP   %-38s %-18s %s" % (job.label, job.cadence, job.skip))
            continue
        stamp = read_stamp(job.label)
        last = fmt_age(now - stamp["started"]) if stamp else "never"
        rc = "" if not stamp else " rc=%s" % stamp.get("rc")
        at = due_at(job, stamp, now)
        nxt = fmt_until(None if at is None else at - now)
        print(
            "  ok     %-38s %-18s last=%-11s%s next=%s  log=%s"
            % (job.label, job.cadence, last, rc, nxt, job.log_path())
        )


def staged_copy_drift() -> str:
    """Empty unless THIS file is a copy OUTSIDE the checkout that differs from the checkout's.

    ⛔ THE DEFECT THIS CLOSES. A cell does not run this file from the checkout: the supervisor
    stages a copy at `$CELL_HOME/.pi/agent/scripts/fleet-schedule.py` (cloud-cell-supervisor.sh:2383,
    farmed by pi-bootstrap/setup.sh's `fleet_srcs`) and the loop executes THAT, every tick. So a fix
    landed in the checkout changes nothing on a running cell until the farm is refreshed — measured
    2026-10-27: a checkout fix for the placeholder drift “did not take” because the staged copy still
    carried the old PLACEHOLDERS tuple. The refresh path already exists and is the ONLY one
    (`cell-install.sh --install`, whose own `verify_layer` byte-compares the farm); what was missing
    is the scheduler SAYING so, in the terms its own contract uses.

    Reported as a DRIFT line by `--check` (never fatal: a Mac's farmed copy legitimately lags a
    working tree) and as a named FAILURE by `--verify` on a cell, where a staged copy that differs
    from the checkout is precisely the state that makes a landing invisible.
    """
    me = os.path.abspath(__file__)
    if not INFRA_ROOT:
        return ""
    root = os.path.abspath(INFRA_ROOT)
    checkout_copy = os.path.join(root, "scripts", "fleet-schedule.py")
    if me == checkout_copy or me.startswith(root + os.sep):
        return ""  # this IS a checkout's copy (or another worktree of one): nothing is staged
    if not os.path.isfile(checkout_copy):
        return ""  # a checkout that predates this file ships no scheduler to compare against
    try:
        with open(me, "rb") as a, open(checkout_copy, "rb") as b:
            same = a.read() == b.read()
    except OSError as exc:
        return "the staged scheduler could not be compared with the checkout (%s)" % exc
    if same:
        return ""
    return (
        "the STAGED scheduler differs from the checkout: %s is not %s — this cell runs the staged "
        "copy, so a fix landed in the checkout has NOT reached it. Refresh the farm: "
        "bash %s/pi-bootstrap/cell-install.sh --install" % (me, checkout_copy, root)
    )


def cmd_check():
    """The DECLARATION gate: parse every template with this runtime's loader, write nothing.

    ⛔ WHY THIS VERB EXISTS. `--verify` is the cell's gate and needs a LIVE LOOP, so before this
    existed nothing graded the shipped declaration set on the machine that AUTHORS it: on macOS
    `--verify` delegates to launchd, which knows nothing about this runtime's placeholder contract.
    That is how #2639 added `{{AI_DRAINER_O}}` to a template without teaching the runtime, reached
    main, and made every cell refuse to start a scheduler at all (measured 2026-10-27: cell4
    MainPID=0 — no reaping, no liveness, no canary). `--check` runs on every platform, needs no
    state, no loop and no lock, and answers exactly one question: can this runtime run the job set
    it ships? Target EXISTENCE is deliberately not graded here (see load_jobs); it is a fact about
    the machine, graded by `--install`/`--verify`.
    """
    jobs = load_jobs(check_targets=False)
    print_table(jobs, time.time())
    errors = [j for j in jobs if j.error]
    skipped = [j for j in jobs if j.skip and not j.error]
    live = [j for j in jobs if not j.error and not j.skip]
    drift = staged_copy_drift()
    if drift:
        print("  DRIFT  %s" % drift, file=sys.stderr)
    for job in errors:
        print("  FAIL   %s: %s" % (job.label, job.error), file=sys.stderr)
    if errors:
        print(
            "DECLARATIONS BROKEN — %d of %d job(s) cannot be run by this runtime, of %s. A cell "
            "refuses to start a scheduler over this set, so it would run no reap, no liveness and "
            "no canary job (#1864)." % (len(errors), len(jobs), TEMPLATES_DIR),
            file=sys.stderr,
        )
        return 1
    if not live:
        print(
            "DECLARATIONS INERT — %d job(s) declared and every one SKIPPED for a named reason, so "
            "nothing would run here: a set that is entirely skips is not a working schedule"
            % len(jobs),
            file=sys.stderr,
        )
        return 1
    print(
        "DECLARATIONS OK — %d job(s) runnable by this runtime, %d skipped for a named reason, "
        "0 errors (%s)" % (len(live), len(skipped), TEMPLATES_DIR)
    )
    return 0


def cmd_status():
    jobs = load_jobs()
    pid = loop_pid()
    age = tick_age()
    live = "running(pid=%d)" % pid if pid and pid_is_our_loop(pid) else (
        "STALE PIDFILE (pid %d is not the loop)" % pid if pid else "NOT RUNNING"
    )
    print("fleet-schedule — surface=linux templates=%s" % TEMPLATES_DIR)
    print("  loop=%s last_tick=%s jobs=%d" % (live, fmt_age(age), len(jobs)))
    print_table(jobs, time.time())
    off = os.path.join(STATE, "OFF")
    if os.path.exists(off):
        print("  ⛔ OFF switch present: %s — the loop exits until it is removed" % off)
    return 0


def cmd_verify():
    """The gate. Every failure is named; a SKIP is named and counted, never hidden."""
    failures = []
    jobs = load_jobs()
    now = time.time()

    # ⛔ A STAGED COPY THAT IS NOT THE CHECKOUT IS A FAILURE HERE, not a note: a cell runs
    # $CELL_HOME/.pi/agent/scripts/fleet-schedule.py, so when it differs from the checkout this cell
    # was installed from, the layer being certified is not the layer in the repo — the state in
    # which a landing is invisible on every running cell (measured 2026-10-27). See
    # staged_copy_drift(). Never raised by --check, where a Mac's farmed copy legitimately lags.
    drift = staged_copy_drift()
    if drift:
        failures.append(drift)

    pid = loop_pid()
    if not pid:
        failures.append("the scheduler loop is NOT RUNNING (no live pid at %s/loop.pid)" % STATE)
    elif not pid_is_our_loop(pid):
        failures.append(
            "the pid in %s/loop.pid (%d) is not fleet-schedule --loop — a stale pid reads as a "
            "running scheduler" % (STATE, pid)
        )
    age = tick_age()
    stale_after = max(3 * TICK, 300)
    # Read ONCE and shared by both arms below: a job that is running is the explanation for a stale
    # tick AND for a job that is late, and computing it in only one arm is how the two disagreed.
    busy = busy_jobs(now)
    if age is None:
        failures.append("the loop has never ticked (no %s/tick)" % STATE)
    elif age > stale_after:
        # A LONG JOB IS NOT A WEDGE. The loop is single-threaded and a pass may last JOB_TIMEOUT,
        # so a job that is RUNNING announces itself (state/busy/<label>.json) with an expiring
        # deadline; while one is live the old tick is explained, not failed. Past that deadline
        # the exemption is gone, so a job killed hard cannot mask a wedged loop forever.
        if busy:
            print(
                "  BUSY   the loop is running %s (%s so far) — the %s tick age is a long job, "
                "not a wedge"
                % (
                    ", ".join(label for label, _ in busy),
                    human_secs(now - min(started for _, started in busy)),
                    human_secs(age),
                )
            )
        else:
            failures.append("the loop tick is %.0fs old (stale after %ds) — the process exists but is not passing" % (age, stale_after))

    ran = 0
    skipped = []
    for job in jobs:
        if job.error:
            failures.append("%s: %s" % (job.label, job.error))
            continue
        if job.skip:
            skipped.append((job.label, job.skip))
            continue
        stamp = read_stamp(job.label)
        # ⛔ A STAMP WITH NO rc IS NOT A RUN, and neither is one we could not execute. The stamp
        # writer only records completed runs now, but stamps written by an older copy of this
        # runtime (and by the exec-failure path, which wrote rc=127) are still on disk, and this
        # arm is what decides whether they count as evidence.
        if not stamp or stamp.get("rc") is None:
            failures.append(
                "%s: declared and runnable here, but has NEVER RUN — 'scheduled' must be read from "
                "a run, not from a file" % job.label
            )
            continue
        # ⛔ A STAMP FROM THE FUTURE IS NOT A LIVE JOB. due_at() is `last + interval`, so a
        # `started` ahead of now makes the job permanently NOT due — is_due() stays False, nothing
        # dispatches it — while this loop counted it as live because a stamp exists at all. A cell
        # clock that stepped back (a resumed VM, an NTP correction of a fast RTC) or a state dir
        # restored from a skewed box is enough, and if it is the only live job the zero-live guard
        # is satisfied too: SCHEDULE VERIFIED over a job that will never run again.
        if stamp["started"] > now + max(3 * TICK, 300):
            failures.append(
                "%s: its last-run stamp is IN THE FUTURE (%s from now) — the clock stepped back "
                "or the state dir was restored from a skewed box, so the job reads as not-due for "
                "ever while a stamp makes it look live; clear: rm -f %s"
                % (job.label, human_secs(stamp["started"] - now), stamp_path(job.label))
            )
            continue
        ran += 1
        due = due_at(job, stamp, now)
        if due is None:
            # A calendar that never matches again is a job that is scheduled and can never run.
            # Silence here certified such a job as live, which is the same false PASS as a job
            # that never ran at all.
            failures.append(
                "%s: its calendar never becomes due again (no occurrence within the search "
                "window) — the job is declared and can never run" % job.label
            )
            continue
        overdue = (now - due) if due is not None else 0
        # LATE BY MORE THAN A COUPLE OF ITS OWN INTERVALS *and* by more than a few ticks. Both
        # halves matter: a 5-minute job 10 minutes late is a miss, while a 6-hour job 1 hour late
        # is the loop simply being busy with something else.
        # ⛔ ...AND A BUSY LOOP IS A LATE LOOP, NOT AN IDLE ONE. The tick arm above already grants
        # a running job its deadline; this arm did not, so a calendar job that came due while a
        # 1800s job was executing (the loop is single-threaded) was reported OVERDUE by a --verify
        # that ran in that window — and check_schedule turns that into a FATAL refusal of a cell
        # whose loop is doing exactly what it was told. The exemption is the same one, and it is
        # deadline-bounded in busy_jobs(), so a hard-killed job cannot mask a wedged loop forever.
        if overdue > max(2 * (job.interval or 0), 3 * TICK):
            if busy:
                print(
                    "  BUSY   %s is %s past due, but the loop is running %s — a busy loop is a "
                    "late loop, not an idle one"
                    % (job.label, human_secs(overdue), ", ".join(label for label, _ in busy))
                )
            else:
                failures.append(
                    "%s: OVERDUE by %s — the loop is not running it (last run %s ago)"
                    % (job.label, human_secs(overdue), human_secs(now - stamp["started"]))
                )

    # ⛔ ZERO LIVE JOBS IS A FAILURE, not a clean run — by a longer route than an empty dir.
    # load_jobs() already refuses a declarations dir holding no *.plist, but a set where EVERY
    # declared job is a named SKIP (a cell with no swarm root and no tortoise checkout) reached
    # the verdict line as "SCHEDULE VERIFIED — 0 job(s) live on this machine …, N skipped for a
    # named reason" and exited 0 — so cloud-cell-bringup.sh printed "scheduled layer live: …"
    # and the cell reached CELL READY with nothing scheduled at all. That is the exact false PASS
    # this runtime exists to close. Skips stay non-fatal only while at least ONE job is live.
    if ran == 0 and not failures:
        failures.append(
            "%d job(s) declared and %d skipped for named reasons, but NOT ONE is live on this "
            "machine — a schedule with zero live jobs leaves this host with no reaping, no "
            "liveness detection and no canary, so it is refused rather than certified (#1864)"
            % (len(jobs), len(skipped))
        )

    for label, reason in skipped:
        print("  SKIP   %-38s %s" % (label, reason))
    for failure in failures:
        print("  FAIL   %s" % failure, file=sys.stderr)
    if failures:
        print("SCHEDULE NOT VERIFIED — %d problem(s) above" % len(failures), file=sys.stderr)
        return 1
    print(
        "SCHEDULE VERIFIED — %d job(s) live on this machine (loop pid %d, last tick %s), "
        "%d skipped for a named reason" % (ran, pid, fmt_age(age), len(skipped))
    )
    return 0


# ──────────────────────────────────────────────────────────────── commands


TEMPLATES_POINTER = "templates-dir"


def remember_templates_dir():
    """Persist WHERE the declarations live, so a later `--start` from any environment finds the
    same set. Without it, a `start` from a shell without INFRA_ROOT/AGENT_INFRA_PATH would either
    refuse (no schedule — correct but hostile to the cell's own restart path) or, worse, pick a
    DIFFERENT checkout and silently schedule a different job set."""
    os.makedirs(STATE, exist_ok=True)
    with open(os.path.join(STATE, TEMPLATES_POINTER), "w") as fh:
        fh.write(TEMPLATES_DIR + "\n")


def cmd_install():
    # ⛔ Checked FIRST, before anything runs: a deliberate OFF switch is NOT overridden by an
    # install — it records a decision, and silently reversing it is how a "why are the reapers not
    # running" mystery starts. Say it plainly and let the operator clear it (--start does).
    os.makedirs(STATE, exist_ok=True)
    off = os.path.join(STATE, "OFF")
    if os.path.exists(off):
        print(
            "FAIL: the schedule is switched OFF (%s) — a machine in this state runs no reap, "
            "liveness or canary job. Clear it deliberately with: %s --start"
            % (off, os.path.basename(sys.argv[0])),
            file=sys.stderr,
        )
        return 1
    jobs = load_jobs()
    errors = [j for j in jobs if j.error]
    if errors:
        for job in errors:
            print("  FAIL   %s: %s" % (job.label, job.error), file=sys.stderr)
        print(
            "the declared job set is BROKEN — refusing to start a scheduler on a set it cannot "
            "read in full (%d error(s))" % len(errors),
            file=sys.stderr,
        )
        return 1
    remember_templates_dir()

    # The first pass is run INLINE, before the loop exists, so that `--install` ends with EVIDENCE
    # (a stamp and a log line per runnable job) rather than with a pid. "A unit that loads and
    # never runs is precisely this issue" — this is the half that proves it ran. On a re-run the
    # jobs are not due, so this costs nothing.
    now = time.time()
    first = [j for j in jobs if not j.skip and not j.error and is_due(j, read_stamp(j.label), now)]
    if first:
        print("running the %d due job(s) now (the first pass IS the proof):" % len(first))
    for job in first:
        rc = run_job(job)
        print("  %-38s rc=%s  log=%s" % (job.label, "held" if rc is None else rc, job.log_path()))

    pid = loop_pid()
    if pid and pid_is_our_loop(pid):
        print("loop already running (pid %d)" % pid)
    else:
        pid = spawn_loop()
        if not pid:
            print("FAIL: the scheduler loop did not come up (see %s/loop.log)" % STATE, file=sys.stderr)
            return 1
        print("loop started (pid %d, tick %ds)" % (pid, TICK))
    return cmd_verify()


def cmd_start():
    pid = loop_pid()
    if pid and pid_is_our_loop(pid):
        print("loop already running (pid %d)" % pid)
        return 0
    # ⛔ READ THE DECLARATIONS BEFORE SPAWNING, and refuse in the terms the caller keys on.
    # main() returns 3 only when there is no template PATH AT ALL; a remembered templates-dir
    # pointer that resolves to a deleted checkout, or a dir holding no *.plist, fell straight
    # through to a spawn — so `--start` printed "loop started (pid …)" and exited 0 over a loop
    # that can never schedule anything, while cloud-cell-supervisor.sh's rc=3 warn-vs-fatal split
    # (which exists precisely for "this cell was never installed") never fired. `start` is the ONLY
    # thing that revives the schedule on a running cell (#1864), so that silent 0 is a cell running
    # lanes with no reaping and no liveness detection — the defect, reported as a success.
    try:
        jobs = load_jobs()
    except ScheduleError as exc:
        print(
            "FAIL: no job declarations to read (%s) — there is NO scheduled layer here, so no reap "
            "job, no liveness report and no canary would ever run. Install it: "
            "pi-bootstrap/cell-install.sh (or point INFRA_ROOT/TEMPLATES_DIR at an agent-infra "
            "checkout its templates/launchd)." % exc,
            file=sys.stderr,
        )
        return 3
    # A set the runtime cannot run in full is not startable either: right after a `--stop` the loop
    # is gone, so THIS is the last place that can still refuse it. `--install` already refuses, and
    # a job that can never run must not be certified by a scheduler that keeps ticking over it.
    # NAMED SKIPS stay non-fatal: they are this machine's ordinary state (no swarm root, no
    # tortoise checkout), and refusing the whole layer over one optional job is what would block a
    # cell that runs every other one.
    broken = [j for j in jobs if j.error]
    if broken:
        for job in broken:
            print("  FAIL   %s: %s" % (job.label, job.error), file=sys.stderr)
        print(
            "the declared job set is BROKEN — refusing to start a scheduler over a set it cannot "
            "run in full (%d error(s))" % len(broken),
            file=sys.stderr,
        )
        return 1
    off = os.path.join(STATE, "OFF")
    if os.path.exists(off):
        os.unlink(off)  # --start is the operator saying "on"; the OFF switch is cleared on purpose
    pid = spawn_loop()
    if not pid:
        print("FAIL: the scheduler loop did not come up (see %s/loop.log)" % STATE, file=sys.stderr)
        return 1
    print("loop started (pid %d, tick %ds)" % (pid, TICK))
    return 0


def cmd_stop():
    # ⛔ The state dir may not exist yet (a machine that never ran the schedule). `--stop` is the
    # ONE mode that skips the "no declarations" exits, so it must be able to create its own OFF
    # switch — it used to die with FileNotFoundError instead of switching anything off.
    os.makedirs(STATE, exist_ok=True)
    open(os.path.join(STATE, "OFF"), "a").close()
    pid = loop_pid()
    if not pid:
        print("loop not running (OFF switch set — remove it or run --start to resume)")
        return 0
    # ⛔ A STALE PID IS NOT THE LOOP. `loop_pid()` answers "is that pid alive", and after the loop
    # died its number can be recycled onto an unrelated process — a lane, the controller, the
    # supervisor. Signalling it would kill someone else's work and report "loop stopped", which is
    # the reading AGENTS.md forbids (a first-match reading is not evidence). Every other arm
    # (verify, status, spawn, loop start) already applies the command-line check; this one did not.
    if not pid_is_our_loop(pid):
        print(
            "loop not running (the pid in %s/loop.pid, %d, is not fleet-schedule --loop — stale "
            "pidfile repaired; OFF switch set)" % (STATE, pid)
        )
        try:
            os.unlink(os.path.join(STATE, "loop.pid"))
        except OSError:
            pass
        return 0
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        pass
    for _ in range(25):
        if not pid_alive(pid):
            print("loop stopped (pid %d, OFF switch set)" % pid)
            return 0
        time.sleep(0.2)
    print("FAIL: loop pid %d is still alive after SIGTERM" % pid, file=sys.stderr)
    return 1


def darwin_delegate(argv):
    installer = os.path.join(INFRA_ROOT, "scripts", "install-launchd.sh")
    if not os.path.isfile(installer):
        print("FAIL: launchd owns the schedule on macOS and %s is missing" % installer, file=sys.stderr)
        return 1
    return subprocess.run(["bash", installer] + argv).returncode


def cmd_darwin(mode):
    if mode == "--verify":
        out = subprocess.run(
            ["bash", os.path.join(INFRA_ROOT, "scripts", "install-launchd.sh"), "--status"],
            capture_output=True,
            text=True,
        )
        text = out.stdout + out.stderr
        bad = [
            line
            for line in text.splitlines()
            if "NOT INSTALLED" in line or "DRIFTED" in line or "not loaded" in line
        ]
        for line in bad:
            print("  FAIL   %s" % line.strip(), file=sys.stderr)
        # ⛔ THE DELEGATE'S EXIT STATUS IS THE SECOND HALF OF THE GATE, not an implementation
        # detail: the substring scan catches only three wordings, so any OTHER failure of
        # install-launchd.sh --status (a missing template dir, an unset HOME, a syntax death)
        # was certified as "SCHEDULE VERIFIED" on macOS — a false PASS over a broken installer.
        if out.returncode != 0:
            print(
                "  FAIL   install-launchd.sh --status exited %d — the delegate that owns the "
                "launchd job set did not report a clean status" % out.returncode,
                file=sys.stderr,
            )
        if bad or out.returncode != 0:
            print(
                "SCHEDULE NOT VERIFIED — %d launchd job(s) not installed/loaded/in sync above"
                % len(bad),
                file=sys.stderr,
            )
            return 1
        print("SCHEDULE VERIFIED — launchd job set matches templates/launchd (install-launchd.sh --status)")
        return 0
    if mode == "--status":
        return darwin_delegate(["--status"])
    if mode in ("--install", "--start"):
        return darwin_delegate([])
    if mode == "--loop":
        print("FAIL: --loop is the Linux runtime; macOS schedules through launchd", file=sys.stderr)
        return 2
    if mode == "--stop":
        print(
            "launchd owns the schedule on macOS: use scripts/install-launchd.sh --uninstall to "
            "remove the jobs (there is no loop process to stop)"
        )
        return 0
    print("usage: %s [--install|--status|--check|--verify|--start|--stop|--help]" % os.path.basename(sys.argv[0]), file=sys.stderr)
    return 2


def main(argv):
    global INFRA_ROOT, TEMPLATES_DIR, STATE, TICK, JOB_TIMEOUT
    mode = argv[1] if len(argv) > 1 else "--install"
    if mode in ("--help", "-h"):
        print(__doc__)
        return 0
    if mode not in ("--install", "--status", "--check", "--verify", "--start", "--stop", "--loop"):
        print("usage: %s [--install|--status|--check|--verify|--start|--stop|--help]" % os.path.basename(argv[0]), file=sys.stderr)
        return 2

    INFRA_ROOT = resolve_infra_root()
    STATE = os.environ.get("FLEET_SCHEDULE_STATE") or os.path.join(
        os.environ.get("CELL_HOME") or os.environ.get("HOME", ""),
        ".pi",
        "agent",
        "state",
        "fleet-schedule",
    )
    TEMPLATES_DIR = os.environ.get("TEMPLATES_DIR") or (
        os.path.join(INFRA_ROOT, "templates", "launchd") if INFRA_ROOT else ""
    )
    if not TEMPLATES_DIR and mode != "--stop":
        # The pointer the last --install wrote: the loop and a later `--start` must resolve the
        # SAME declarations the cell was installed with, not whatever the caller's environment
        # happens to name — or nothing at all, which would leave the cell scheduled-but-idle.
        try:
            with open(os.path.join(STATE, TEMPLATES_POINTER)) as fh:
                TEMPLATES_DIR = fh.read().strip()
        except OSError:
            pass
    TICK = int(os.environ.get("FLEET_SCHEDULE_TICK") or 60)
    JOB_TIMEOUT = int(os.environ.get("FLEET_SCHEDULE_JOB_TIMEOUT") or 1800)

    if sys.platform == "darwin":
        if mode == "--check":
            # ⛔ BEFORE THE DELEGATION, DELIBERATELY. The declaration set is the SAME files on both
            # platforms, and macOS is where they are authored — but every other verb delegates to
            # launchd, which knows nothing about this runtime's placeholder contract. So before
            # this verb, NOTHING graded the shipped templates on the machine that writes them: that
            # is how a template carrying {{AI_DRAINER_O}} reached main and refused every cell.
            try:
                return cmd_check()
            except ScheduleError as exc:
                print("FAIL: %s" % exc, file=sys.stderr)
                return 3 if not os.path.isdir(TEMPLATES_DIR or "-") else 1
        if not INFRA_ROOT:
            print("FAIL: no agent-infra checkout found (set INFRA_ROOT or AGENT_INFRA_PATH)", file=sys.stderr)
            return 1
        return cmd_darwin(mode)

    if not TEMPLATES_DIR and mode != "--stop":
        print(
            "FAIL: no job declarations found — set INFRA_ROOT to an agent-infra checkout (or "
            "TEMPLATES_DIR to its templates/launchd). Without them there is NO scheduled layer, "
            "which is the silent gap this script exists to close (#1864).",
            file=sys.stderr,
        )
        return 3

    try:
        if mode == "--install":
            return cmd_install()
        if mode == "--status":
            return cmd_status()
        if mode == "--check":
            return cmd_check()
        if mode == "--verify":
            return cmd_verify()
        if mode == "--start":
            return cmd_start()
        if mode == "--stop":
            return cmd_stop()
        return cmd_loop()
    except ScheduleError as exc:
        print("FAIL: %s" % exc, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
