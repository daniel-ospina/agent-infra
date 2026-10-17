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
  * `--verify` FAILS when the loop is dead, its tick is stale, a job could not be scheduled, or a
    job is overdue with no run. A skipped job is reported as SKIP (with its reason) rather than
    failing: a Mac-free dependency (a tortoise venv, a swarm root) is a legitimate per-machine
    absence, and refusing to certify the whole layer over it would block a cell that can run
    every other job.

⛔ NOT A SECOND SCHEDULER ON macOS. On Darwin every subcommand delegates to
`scripts/install-launchd.sh`, which is unchanged. The loop exists only where launchd does not.

CONTRACT
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

# The placeholder set — the SAME eight `scripts/install-launchd.sh` renders. A template that
# carries any OTHER {{NAME}} is an error here, not an empty string: the launchd renderer would
# substitute empty for a name it does not know too, so the two backends agree only because the
# list is a contract, and this one refuses rather than guesses.
PLACEHOLDERS = (
    "HOME",
    "PATH",
    "AGENT_INFRA_PATH",
    "TORTOISE_REPO",
    "SWARM_ROOT",
    "SWARM_ENV_FILE",
    "PYTHON_BIN",
    "PI_BIN_DIR",
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


def placeholder_values() -> dict:
    """Resolve the eight placeholders. Empty string means 'unresolved' (the job is SKIPPED)."""
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

    @property
    def cadence(self):
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


def load_jobs() -> list:
    """Parse every plist in TEMPLATES_DIR into a Job. Raises ScheduleError for a broken set.

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
        if label in retired:
            raise ScheduleError(
                "%s is in RETIRED but a template still exists — remove one or the other"
                % label
            )

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
        else:
            job.error = (
                "no StartInterval and no StartCalendarInterval — a job with no schedule would "
                "never run (launchd accepts it silently; this runtime does not)"
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

        if not job.error and not job.skip:
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
            for arg in job.argv:
                if not arg.startswith("/") or os.path.exists(arg):
                    continue
                if layer_prefix and (arg == layer_prefix or arg.startswith(layer_prefix + os.sep)):
                    job.error = (
                        "broken target: %s does not resolve — the farm is INCOMPLETE (install it: "
                        "pi-bootstrap/cell-install.sh)" % arg
                    )
                else:
                    job.skip = "target absent on this machine: %s" % arg
                break
        jobs.append(job)
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
    window = 400 if ("Month" in calendar or "Day" in calendar) else 8
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
        rc = 127
        log("ERROR %s could not be executed (%s)" % (job.label, exc))
    finally:
        write_stamp(job.label, started, rc, time.time() - started)
        try:
            os.unlink(lock)
        except OSError:
            pass
    log("RAN %s rc=%s in %.1fs (log %s)" % (job.label, rc, time.time() - started, log_path))
    return rc


def log(message):
    line = "%s %s" % (datetime.now().strftime("%Y-%m-%d %H:%M:%S"), message)
    try:
        os.makedirs(STATE, exist_ok=True)
        with open(os.path.join(STATE, "loop.log"), "a") as fh:
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
    if theirs and theirs != os.getpid():
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
        if jobs:
            now = time.time()
            for job in jobs:
                if job.error or job.skip:
                    continue
                if is_due(job, read_stamp(job.label), now):
                    run_job(job)
        mark_tick()
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
    for _ in range(30):
        time.sleep(0.2)
        pid = loop_pid()
        if pid and pid_is_our_loop(pid):
            return pid
    return loop_pid()


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
    if age is None:
        failures.append("the loop has never ticked (no %s/tick)" % STATE)
    elif age > stale_after:
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
        if not stamp:
            failures.append(
                "%s: declared and runnable here, but has NEVER RUN — 'scheduled' must be read from "
                "a run, not from a file" % job.label
            )
            continue
        ran += 1
        due = due_at(job, stamp, now)
        overdue = (now - due) if due is not None else 0
        # LATE BY MORE THAN A COUPLE OF ITS OWN INTERVALS *and* by more than a few ticks. Both
        # halves matter: a 5-minute job 10 minutes late is a miss, while a 6-hour job 1 hour late
        # is the loop simply being busy with something else.
        if overdue > max(2 * (job.interval or 0), 3 * TICK):
            failures.append(
                "%s: OVERDUE by %s — the loop is not running it (last run %s ago)"
                % (job.label, human_secs(overdue), human_secs(now - stamp["started"]))
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
    open(os.path.join(STATE, "OFF"), "a").close()
    pid = loop_pid()
    if not pid:
        print("loop not running (OFF switch set — remove it or run --start to resume)")
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
        if bad:
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
    print("usage: %s [--install|--status|--verify|--start|--stop|--help]" % os.path.basename(sys.argv[0]), file=sys.stderr)
    return 2


def main(argv):
    global INFRA_ROOT, TEMPLATES_DIR, STATE, TICK, JOB_TIMEOUT
    mode = argv[1] if len(argv) > 1 else "--install"
    if mode in ("--help", "-h"):
        print(__doc__)
        return 0
    if mode not in ("--install", "--status", "--verify", "--start", "--stop", "--loop"):
        print("usage: %s [--install|--status|--verify|--start|--stop|--help]" % os.path.basename(argv[0]), file=sys.stderr)
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
