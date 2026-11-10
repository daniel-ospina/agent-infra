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
                                         set. ⛔ THIS IS THE ONLY VERB THAT REFUSES A `RETIRED`
                                         LABEL WHOSE TEMPLATE STILL EXISTS (#2908): the
                                         contradiction is authored in the repo, so the repo's
                                         gate is where it is caught — the machine verbs honour
                                         the manifest and keep running every other job.
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
import math
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
# The BOX's loop mutex, resolved in main(). ⛔ Not under $STATE, and not keyed on $HOME/$CELL_HOME
# or the uid — see resolve_loop_lock(). Empty means "not resolved" (a unit test importing this
# module, or a mode that never reaches a loop).
LOOP_LOCK = ""
LOOP_LOCK_ROOT = ""

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
# ⛔ AND THE FOURTH COPY IS `placeholder_values()`, WHICH MUST RESOLVE EVERY NAME HERE. A name
# declared in this tuple with no resolver is the SAME backend divergence by a fourth route: macOS
# renders it from its env, while this runtime resolved it to "" and reported the job as a legitimate
# per-machine SKIP — a silent non-run dressed as a designed absence, with `--check` still printing
# "0 errors". That is graded in `load_jobs`, where a used-but-unresolvable name is a DECLARATION
# error rather than a skip, and pinned by `fleet-schedule.test.sh` case 1g.
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


def absolutize_path_knobs():
    """Resolve every CWD-SENSITIVE path knob ONCE, in the parent, before anything renders.

    ⛔ The loop child runs with `cwd="/"` (see `spawn_loop`), and `placeholder_values()` re-reads these
    knobs there. Any knob whose VALUE is acted on relative to the cwd — `os.path.isdir()`, `os.access()`,
    `open()` — therefore resolves DIFFERENTLY in the child, and the child then renders a different job
    argv than the inline pass and `--verify` certified: a placeholder renders empty (a named SKIP, so the
    job silently never runs) or names a different checkout (so the job runs against something nobody
    certified). Both are the `SCHEDULE VERIFIED`-over-a-loop-that-runs-nothing false PASS this change
    exists to remove, and it is NOT just `INFRA_ROOT`:

      TORTOISE_REPO  `os.path.isdir(tortoise)` decides whether the value is kept or replaced by the
                     fallback scan, so a RELATIVE value can keep its relative form in the parent and
                     be replaced by an ABSOLUTE checkout in the child (measured).
      SWARM_ROOT     `os.access(join(SWARM_ROOT, '.venv/bin/python'))` feeds `PYTHON_BIN`, so the same
                     relative root yields two different interpreters.
      CELL_HOME      `home` — and `WORKTREE_HYGIENE_MODE` / `REAP_ORPHAN_MODE` / `SWARM_ENV_FILE` are
                     all derived from it by `open()`.
      SWARM_ENV_FILE a path read with `open()`.
      WORKTREE_HYGIENE_ARM_FILE / REAP_ORPHAN_ARM_FILE
                     the two arming records: each OVERRIDES the `home/.pi/agent/state/...` default and is
                     then read with `open()`, so a relative override decides `--apply` vs `--dry-run` (and
                     `0` vs `1` for the reaper) by the CALLER'S cwd — measured end-to-end as a marker
                     carrying `wt=--apply` from the inline pass and `wt=--dry-run` from the loop child under
                     one `SCHEDULE VERIFIED`, on the two shipped templates that carry those placeholders.
                     They are NOT "derived from CELL_HOME" whenever the override is set, which is why the
                     completeness claim below has to name them explicitly.
      PYTHON_BIN / PI_NODE_BIN  executables: a value WITH a separator is cwd-resolved; a BARE NAME is a
                     PATH lookup and is identical in both processes, so it is left alone (abspath on
                     `python3` would invent a file that does not exist).

    Normalising `os.environ` itself is deliberate: `spawn_loop` passes `os.environ.copy()`, so the child
    inherits the RESOLVED values without a second handover list to drift out of date — which is exactly
    how the `INFRA_ROOT` gap happened. `FLEET_SCHEDULE_STATE` / `TEMPLATES_DIR` / `FLEET_SCHEDULE_LOCK_ROOT`
    still need their explicit handover because they are resolved from DEFAULTS rather than from an env
    value the child would simply re-read.

    ⛔ EVERY KNOB IN THESE TUPLES IS GRADED, AND A NEW ONE NEEDS ITS OWN ARM (#3442). The completeness this
    function claims is only worth what the suite can refuse, so §19 names one arm per knob — deleting a
    knob from the tuples below REDDENS a named row instead of passing quietly (it used to pass quietly on
    SIX of them: `SWARM_ROOT`, `CELL_HOME`, `SWARM_ENV_FILE`, `REAP_ORPHAN_ARM_FILE`, `PYTHON_BIN`,
    `PI_NODE_BIN`, whose absence was invisible to every other check). The map, so the next knob cannot
    repeat it: `TORTOISE_REPO` 19ak · `SWARM_ROOT` 19as (via the DERIVED `{{PYTHON_BIN}}`) · `CELL_HOME`
    19at (via both arming records) · `SWARM_ENV_FILE` 19av · `WORKTREE_HYGIENE_ARM_FILE` 19am ·
    `REAP_ORPHAN_ARM_FILE` 19au · `PYTHON_BIN`/`PI_NODE_BIN` 19av plus its CONTROL row, which is what pins
    the bare-name exemption below.
    """
    for knob in ("TORTOISE_REPO", "SWARM_ROOT", "CELL_HOME", "SWARM_ENV_FILE",
                 "WORKTREE_HYGIENE_ARM_FILE", "REAP_ORPHAN_ARM_FILE"):
        val = os.environ.get(knob, "")
        if val:
            os.environ[knob] = os.path.abspath(val)
    for knob in ("PYTHON_BIN", "PI_NODE_BIN"):
        val = os.environ.get(knob, "")
        if val and os.sep in val:
            os.environ[knob] = os.path.abspath(val)


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
        if self.interval is None and self.calendar is None:
            # ⛔ A JOB RETIRED BEFORE ITS SCHEDULE IS PARSED HAS NEITHER (#2908), and
            # `human_secs(None or 0)` rendered that as "every 0s" — a cadence that says a job runs
            # constantly, next to the SKIP that says it never runs. This is the only state that
            # reaches here: every other skip is decided AFTER the schedule is read.
            return "-"
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


def _finite(value) -> bool:
    # ⛔ `math.isfinite` IS ITSELF A RE-RAISER FOR A BIG ENOUGH INT. `json.load` returns an
    # arbitrary-precision int for an integer literal, so a hand-edited or foreign stamp can hold
    # `10**400`; `isinstance(value, int)` passes it and `math.isfinite` then raises OverflowError
    # ("int too large to convert to float"). That lands in the very guards whose job is to NAME a
    # value they cannot use — `--verify` raised out of them instead, aborting the check for every
    # job after the broken one, the exact defect those guards replaced one value class earlier.
    # A number too large to be a float is not a usable time: answer False, never raise.
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return False
    try:
        return math.isfinite(value)
    except (OverflowError, ValueError):
        return False


def human_secs(seconds: float) -> str:
    # ⛔ A NON-FINITE AGE IS NOT AN AGE. `int(inf)` raises OverflowError and `int(nan)` raises
    # ValueError, and a stamp carrying either reaches this from `--verify`'s IN-THE-FUTURE arm.
    # A big int raises inside `math.isfinite` itself, which is why this asks `_finite` (#3340).
    if not _finite(seconds):
        return "an unusable age (%r)" % (seconds,)
    seconds = int(seconds)
    if seconds < 90:
        return "%ds" % seconds
    if seconds < 3600:
        return "%dm" % round(seconds / 60)
    if seconds < 86400:
        return "%dh" % round(seconds / 3600)
    return "%dd" % round(seconds / 86400)


def load_jobs(check_targets: bool = True, strict_declarations: bool = False) -> list:
    """Parse every plist in TEMPLATES_DIR into a Job. Raises ScheduleError for a broken set.

    `check_targets=False` grades the DECLARATIONS only, and is what `--check` uses: whether
    `{{HOME}}/.pi/agent/scripts/<entry>` exists is a fact about the MACHINE (a farm that is or is
    not installed here), never about the declaration — grading it in CI, where no farm is
    installed, would refuse a perfectly good template set for the runner's own missing layering.
    The layer's real existence is already the cell's gate: `--install`/`--verify`.

    `strict_declarations=True` is the DECLARATION GATE's arm and is what `--check` passes: a
    contradiction between two REPO files is refused outright there, because the repo is where it
    was authored and a gate is where it must be caught. Every MACHINE verb (`--install`, `--start`,
    `--verify`, `--status`, `--loop`) leaves it False — see `RETIRED` below for why one line in a
    manifest must never be able to disarm a whole cell.

    RETIRED labels are read from the same manifest install-launchd.sh uses. A label in RETIRED with
    no template is nothing to do here: the loop only runs what is declared.

    ⛔ A LABEL IN RETIRED *WHILE* ITS TEMPLATE STILL EXISTS IS A DISPOSITION AT RUNTIME, NOT A
    REFUSAL (#2908). It used to raise, which took the WHOLE layer down — so an operator who
    appended one line to `RETIRED` to stop two jobs they could not run lost every other job with
    them: no reaping, no liveness detection, no canary, and a disk that then fills (measured on
    cell 3/4, 2026-10-27: `fatal: the scheduled layer would not start (rc=1)`). The refusal is the
    right verdict from the DECLARATION gate — both statements are in the repo, so `--check`
    refuses it (strict_declarations) and CI cannot let an author add a template whose label is
    still retired, which would be a job that silently never runs. The MACHINE verbs honour the
    manifest instead: the label is a named SKIP, its installed copy is unloaded by the installer,
    and the layer still starts over every other job.
    """
    if not os.path.isdir(TEMPLATES_DIR):
        raise ScheduleError("template dir not found: %s" % TEMPLATES_DIR)
    try:
        import plistlib
    except ImportError:  # pragma: no cover - python3 always ships plistlib
        raise ScheduleError("python3 has no plistlib — cannot read the job declarations")

    retired_path = os.path.join(TEMPLATES_DIR, "RETIRED")
    retired = set()
    try:
        with open(retired_path) as fh:
            for line in fh:
                line = line.strip()
                if line and not line.startswith("#"):
                    retired.add(line)
    except FileNotFoundError:
        pass
    except OSError as exc:
        # ⛔ A NAMED REFUSAL, NOT A TRACEBACK. This read is a syscall on an untrusted directory: on
        # a full disk (ENOSPC) or a root-owned RETIRED (EACCES) it used to escape `load_jobs` as a
        # raw OSError, and `main()` catches only ScheduleError — so `--check`/`--verify`/`--install`
        # died with a traceback, and the install path left the cell with no scheduler.
        raise ScheduleError("cannot read %s: %s: %s" % (retired_path, type(exc).__name__, exc))

    values = placeholder_values()
    # ⛔ THE FOURTH COPY IS placeholder_values(), AND NOTHING COMPARED IT. PLACEHOLDERS is checked
    # against the installer's array and against the {{NAME}} tokens in the shipped templates — so
    # a name added to all THREE with no resolver below passed every gate while being unrunnable on
    # every cell: render() resolved it to "" and this loop filed it as "absent on this machine",
    # i.e. a designed per-machine SKIP, with `--check` still printing "0 errors". macOS renders the
    # same template from its own env by name, so that is the #2804 asymmetry by a fourth route —
    # silent this time instead of a whole-cell refusal. Measured: PROBE_NEW added to PLACEHOLDERS,
    # to PLIST_PLACEHOLDERS and to a template left `--check` at rc 0 with
    # "DECLARATIONS OK — … 0 errors", and exporting PROBE_NEW changed nothing (the resolver never
    # reads it). Graded only where a template USES the name: a declared-but-unused name costs
    # nothing, and refusing over one would block a cell on a tuple entry no template mentions.
    unresolvable = {n for n in PLACEHOLDERS if n not in values}
    jobs = []
    try:
        entries = sorted(os.listdir(TEMPLATES_DIR))
    except OSError as exc:
        raise ScheduleError(
            "cannot list %s: %s: %s" % (TEMPLATES_DIR, type(exc).__name__, exc))
    for name in entries:
        if not name.endswith(".plist"):
            continue
        path = os.path.join(TEMPLATES_DIR, name)
        label_from_file = name[: -len(".plist")]
        try:
            with open(path, "rb") as fh:
                data = plistlib.load(fh)
        except Exception as exc:
            raise ScheduleError("cannot parse %s: %s" % (path, exc))

        # ⛔ THE ROOT IS VALIDATED BEFORE IT IS USED. `plistlib.load` happily returns a LIST (or a
        # non-dict leaf) for a hand-edited or truncated file, and `data.get("Label")` then raised
        # AttributeError — an escape path `plistlib`'s own except does not cover, because the parse
        # SUCCEEDED. Measured at this head with an array-root plist: `--check`, `--verify` and
        # `--install` each died with a raw `AttributeError: 'list' object has no attribute 'get'`
        # traceback out of main(), and `--install` left the cell with no scheduler. `cmd_loop` had
        # to widen its own call site to `except Exception` for this exact input; naming the file
        # here is the fix the loop's guard was compensating for.
        if not isinstance(data, dict):
            raise ScheduleError(
                "cannot use %s: the plist root is %s, not a dict — a declaration must be a "
                "<dict> (a truncated or hand-edited file looks like this)"
                % (path, type(data).__name__))
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
            if strict_declarations:
                raise ScheduleError(
                    "%s is in RETIRED but a template still exists — remove one or the other"
                    % label
                )
            # ⛔ THE MANIFEST WINS ON A MACHINE (#2908). Retirement is the only statement here
            # that a MACHINE can honour: the alternative is refusing the layer, which is the state
            # that left cell 3/4 with no reaper, no liveness detection and no canary. Nothing else
            # about the body is graded — a retired job is not going to run, so its schedule, its
            # placeholders and its targets are all beside the point.
            job.skip = (
                "RETIRED — the label is listed in RETIRED while its template (%s) still exists, so "
                "nothing is scheduled here and install-launchd.sh unloads any installed copy. This "
                "contradiction is a REPO authoring error: `fleet-schedule.py --check` refuses it, "
                "so remove the template or the RETIRED line (in the repo) to clear it" % name
            )
            jobs.append(job)
            continue

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

        # ⛔ `FleetResident` MARKS A BODY WHOSE *SCHEDULE* STARTS IT, so it must NOT rescue the
        # SCHEDULELESS shape. Residency is decided before the schedule (rightly — a schedule must
        # not mask a resident body), and BOTH branches above are guarded by `not job.daemon`: so a
        # template declaring FleetResident alone skipped the no-schedule ERROR and fell through to
        # the resident SKIP below. The layer was then certified green — `DECLARATIONS OK — …
        # 0 errors` — over a plist that NO backend would ever start: launchd loads it silently and
        # never runs it (the original #1864 defect, which is exactly what a Linux cell refuses the
        # whole layer over), and this runtime will not supervise a resident service either. That is
        # the sentence docs/ops/fleet-schedule.md already states — "`FleetResident` alone does not
        # rescue it: nothing would ever start the job, on either backend" — ENFORCED here rather
        # than asserted in prose (measured: `FleetResident: true` with no schedule graded a named
        # SKIP, 0 errors, rc=0, next to one runnable job).
        # KeepAlive keeps its arm (launchd starts and restarts the job), and so does a scheduleless
        # RunAtLoad (the load start is what starts worker-supply), so only FleetResident is graded.
        if job.resident_decl == "FleetResident" and job.interval is None and job.calendar is None:
            job.error = job.error or (
                "declares FleetResident with NO StartInterval and no StartCalendarInterval — "
                "FleetResident marks a resident BODY whose schedule is what starts it, so with no "
                "schedule nothing would ever start this job on either backend (launchd accepts the "
                "plist silently and never runs it; this runtime will not supervise a resident "
                "service). Give it a schedule, or declare the residency that starts it: KeepAlive, "
                "or RunAtLoad on a template with no schedule"
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
        # ⛔ BEFORE THE SKIP ARM, because the two states look identical from used_empty alone and
        # one of them is a lie: "absent on this machine" is FALSE for a name this runtime declares
        # with no resolver — it is absent on EVERY machine, for ever, and macOS would render it.
        no_resolver = used_empty & unresolvable
        if no_resolver and not job.error:
            job.error = (
                "placeholder(s) declared in PLACEHOLDERS with NO resolver in "
                "placeholder_values(): %s — this template would be SKIPPED on every cell while "
                "the macOS backend renders it, so it is a DECLARATION error, not this machine's "
                "absence" % ", ".join("{{%s}}" % n for n in sorted(no_resolver))
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
        # ⛔ `OverflowError` IS NOT A `ValueError` (cycle-5 review, P1). It is an `ArithmeticError`,
        # so the tuple above did not cover it and `float()` on an integer literal like `10**400`
        # RAISED OUT of `--verify`, aborting the check for every job after the broken marker —
        # verbatim the defect `_finite` was added for on the stamp arm, left open on this one.
        except (OSError, ValueError, KeyError, TypeError, OverflowError):
            continue
        # ⛔ A NON-FINITE MARKER IS NOT A BUSY MARKER (cycle-5 review, P1 — FALSE PASS).
        # EVERY comparison against NaN is False, so `started=NaN` walked through BOTH guards below:
        # `nan <= 0` did not drop it, `nan > now + slack` did not drop it, and
        # `min(deadline, nan + …)` returns `deadline` because `nan < deadline` is False — so the
        # clamp was a NO-OP and the marker's own self-declared deadline survived. The marker then
        # counted as LIVE, `cmd_verify`'s tick and OVERDUE arms both excused themselves, and a
        # WEDGED LOOP was certified `SCHEDULE VERIFIED` rc=0. `json.load` parses `NaN`/`Infinity`,
        # and this file's own comment names the reachable inputs (hand-edit, foreign writer,
        # restored state dir), so this is reachable without any exotic cause.
        # Dropping it fails CLOSED: the tick then reads stale, which is the truth. This is the same
        # `_finite` gate `cmd_verify` already applies to its own `started` (and `human_secs` to its
        # age) — the printer was hardened while the gate it feeds was not.
        if not (_finite(started) and _finite(deadline)):
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


def report_bookkeeping_failure(exc):
    """Announce a failed bookkeeping write WITHOUT assuming any write works.

    Both of the loop's own surfaces can be the one that failed: `tick` (a file) and `loop.log`
    (which is also the loop's stdout AND stderr, merged by spawn_loop). So each report attempt is
    made independently and a failure to report is never allowed to escape — silence is the worst
    outcome, because the loop would then keep ticking with no tick file and no explanation.
    """
    msg = "loop: bookkeeping write failed (%s: %s) — continuing to the next tick" % (
        type(exc).__name__, exc)
    # ⛔ ONE LINE, NOT TWO. `spawn_loop` points stderr at stdout, and both at loop.log, so a
    # stderr write AND the log() write land in the SAME target: one untimestamped copy plus one
    # timestamped one — the exact doubling log()'s own WRITE ONCE rule exists to prevent, and on a
    # persistently broken tick that is two lines every TICK into the one file an operator reads.
    # Emit on stderr only when stderr is a DIFFERENT target than stdout.
    # ⛔ Exception, not OSError, on both emits: this function's contract is that a failure to
    # REPORT must never escape, and the report is the one path where a second failure is most
    # likely (an ASCII locale raises UnicodeEncodeError here, and `sys.stderr` can be None under
    # a windowed interpreter).
    if sys.stderr is not None and not _stderr_is_stdout():
        try:
            sys.stderr.write(msg + "\n")
            sys.stderr.flush()
        except Exception:  # noqa: BLE001 — see above
            pass
    try:
        log(msg)
    except Exception:  # noqa: BLE001 — see above
        pass


def loop_pid():
    # ⛔ IndexError, NOT just (OSError, ValueError). `"".split()` is `[]`, so a ZERO-BYTE pidfile
    # raised IndexError out of here — and this function is called by `cmd_loop` BEFORE the loop
    # starts and by `--start`/`--install`/`--verify`/`--status`/`--stop`, i.e. by EVERY recovery
    # command. Measured: a 0-byte loop.pid made all of them die with a traceback and the cell's
    # only scheduler could never come up again, self-perpetuatingly (each attempt died at this line
    # before it could rewrite the file). A human `rm loop.pid` was the only way back.
    # The producer is in THIS file (see `cmd_loop`) and its trigger is this PR's own trigger: it
    # truncated the pidfile with `open(pidfile, "w")` and then wrote it UNGUARDED, so ENOSPC left
    # the empty file behind. Both ends are fixed together.
    try:
        with open(os.path.join(STATE, "loop.pid")) as fh:
            pid = int(fh.read().strip().split()[0])
    except (OSError, ValueError, IndexError, TypeError):
        return None
    if not pid_alive(pid):
        return None
    return pid


def pid_alive(pid):
    # ⛔ `OverflowError` IS NOT AN `OSError` (cycle-6 review, P2), and this is the SECOND place the
    # same class bit this file: `os.kill(10 ** 400, 0)` raises `OverflowError`, so a pidfile written
    # by a foreign writer / restored state dir / hand-edit escaped `pid_alive` entirely. The two
    # callers below are both recovery paths, so the effect is the one `loop_pid`'s own comment calls
    # out: `--status`, `--verify`, `--stop` AND `--start` all die on a traceback, and the cell's only
    # scheduler can never come back (measured: `FAIL: --start: OverflowError: Python int too large
    # to convert to C long`). The lock probe at `acquire_lock` raises instead of stealing the dead
    # lock, so that job never runs again on any pass.
    #
    # The BOUND is the primary guard and `OverflowError` is only defence in depth: no real pid
    # reaches 2**31, so an out-of-range value is corrupt by definition and "not alive" is the
    # answer both callers need (a wedged loop restarts, a dead lock is stolen).
    if not isinstance(pid, int) or pid <= 0 or pid > 2 ** 31 - 1:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OverflowError:
        return False
    except OSError as exc:
        return exc.errno == errno.EPERM


# ─────────────────────────────────── one scheduler loop per BOX, not per state dir (#2890)


def resolve_loop_lock():
    """Set LOOP_LOCK: ONE path every scheduler on this box derives IDENTICALLY.

    ⛔ NOT keyed on `$STATE`, `$HOME`/`$CELL_HOME` or the uid — those are precisely the inputs that
    DIFFER between two delivery paths on one box, and a lock whose NAME depends on them is a lock
    those two do not share. Measured on cell-4 (2026-11-06, recorded on #2890): **7 concurrent
    `--loop` instances on one box**, resolving five different `$STATE` dirs (a cell home, the
    operator's home, three lane-worktree homes, a stale cloud-cell fixture home). Each was
    internally correct — the loop's own guard is scoped to `$STATE` and held — and every one of
    them ran the SAME box-level job set (`ci-runner-gate`, `controller-watchdog`, `pr-doctor`)
    against the same machine. The resource being guarded is the BOX, so the guard's scope must be
    the box.

    This is `scripts/disk-reaper.sh`'s CANONICAL_LOCK_DIR rule (#2443) applied here: *"ONE
    CANONICAL LOCK PATH, DERIVED FROM THE TMPFS ROOT ALONE … one name cannot drift."* The realm is
    the same too — `--loop` never executes on Darwin (main() delegates to install-launchd.sh
    first), so the Linux tmpfs root is always the right place for it.

    Engagements, both STATED rather than silent:
      * `FLEET_SCHEDULE_LOCK_ROOT` — the hermetic suites' seam, and the operator's pin. Every suite
        that starts a loop MUST set it (fleet-schedule.test.sh and cloud-cell-bringup.test.sh do),
        or it would contend with the box's own production scheduler — which is the very defect this
        guard exists to prevent.
      * `FLEET_SCHEDULE_TMPFS_ROOT` — the root's parent, mirroring disk-reaper.sh's knob.

    A root that cannot be used does NOT wedge the box: it degrades to `$STATE/loop.lock` (still an
    atomic `O_EXCL` claim, so strictly better than the plain pidfile it also keeps) and says so on
    stderr. Same arm, same reason, as #2898's recorded decision for an unwritable `$STATE` —
    refusing would take the box's only alarm offline exactly when the box is broken.
    """
    global LOOP_LOCK, LOOP_LOCK_ROOT
    root = os.environ.get("FLEET_SCHEDULE_LOCK_ROOT") or os.path.join(
        os.environ.get("FLEET_SCHEDULE_TMPFS_ROOT") or "/dev/shm", "fleet-schedule"
    )
    # ⛔ ABSOLUTE BEFORE ANYTHING ELSE, for the same reason `STATE` is (see main()): this path IS the
    # mutex's NAME, and a name that resolves differently in two processes is two mutexes. A RELATIVE
    # root is resolved against the caller's cwd here but against `cwd="/"` in the loop child
    # (`spawn_loop`), so the parent creates e.g. `$PWD/relock` while the child — unable to create
    # `/relock` — degrades to `$STATE/loop.lock`. Both loops then hold DIFFERENT locks, both verbs
    # print `SCHEDULE VERIFIED`, and #2890 is reproduced with the guard reporting success (measured
    # by the reviewer with a `FLEET_SCHEDULE_LOCK_ROOT=relock` pin: two live loops on one box and no
    # lock file on the parent's path).
    root = os.path.abspath(root)
    why = ""
    try:
        # ⛔ A PRIVILEGED VERB MUST NOT SQUAT THIS ROOT — and `chmod` IS NOT THE ANSWER. `chmod`
        # changes MODE, not OWNERSHIP, so it does nothing about the `st_uid != getuid()` arm below
        # (the [VGATE] pass measured a 1777 root still degrading every operator loop), while it
        # would widen an operator-pinned private `FLEET_SCHEDULE_LOCK_ROOT` to world-writable for no
        # benefit — and a `chmod` UP is exactly what the arm below rejects. The mode is therefore left
        # alone on a pre-existing root, and requested as 0o755 (umask-cleared only, never upwards) on a
        # root we create. Residual, named rather than hidden: a `sudo`-run `--start` on a box that
        # has no lock root yet leaves it root-owned, and every operator loop then degrades with the
        # NOTE below — tracked as its own follow-up, since the sound fixes are a chown-uid decision.
        # Second residual, named for the same reason: `makedirs` IGNORES `mode` on a directory that
        # already exists, so a root created by a pre-#3615 run under `umask 022` keeps its 0o1755 and
        # is never widened — a second uid on a shared box therefore keeps degrading until that
        # directory is recreated by hand. That is the right trade (widening a directory we did not
        # create is exactly the bypass rejected above), and it is stated here rather than left as the
        # one consequence of the no-chmod rule that a reader has to infer.
        # ⛔ AND NO `chmod`, ON *ANY* ROOT — not even one we create. Widening is the bypass, whichever
        # directory it happens to: with `loop.lock` writable by others, ANY local uid can create one
        # naming a live `fleet-schedule --loop` it runs, and every operator loop then refuses while
        # `--start` exits 0 — the box silently unscheduled, through a guard defeated by the mode of
        # its own directory. A previous cut corrected a pre-existing root to 0o1777; that was measured
        # to WEAKEN a fresh root (see below) and is reverted.
        # ⛔ AND THE REQUESTED MODE IS 0o755, NOT 0o1777 — THE DIFFERENCE IS NOT COSMETIC. `makedirs`'s
        # mode is UMASK-FILTERED, and a umask can only CLEAR bits, so requesting 0o1777 let a permissive
        # umask produce a world-writable root: measured 0o1777 under `umask 0` (services, containers and
        # some CI images do exactly that), which is the plant-a-`loop.lock` bypass above with the guard
        # reporting nothing. Requesting 0o755 makes "not world-writable" TRUE UNDER EVERY UMASK, and it
        # costs nothing: the `st_uid != getuid()` arm below refuses a root another uid owns whatever its
        # mode, so a world-writable root could never be SHARED across uids anyway — only attacked. The
        # mode of a PRE-EXISTING root is still untouched (`makedirs` ignores `mode` when the dir exists),
        # so an operator's deliberate 0700 pin survives, which is the distinction that matters here.
        os.makedirs(root, mode=0o755, exist_ok=True)
        # /dev/shm is 1777 and this name is guessable, so a PRE-EXISTING foreign dir must never
        # become our lock dir (the same ownership rule, and the same reason, as disk-reaper.sh's
        # fallback candidates). Only a pre-existing dir can be foreign — an absent one we create.
        if not os.access(root, os.W_OK):
            why = "not writable"
        elif os.stat(root).st_uid != os.getuid():
            why = "owned by uid %d" % os.stat(root).st_uid
    except OSError as exc:
        why = exc.strerror or type(exc).__name__
    # ⛔ THE ATTEMPTED ROOT IS RECORDED EVEN WHEN WE DEGRADE, and it is what the child is handed.
    # Emptying it made parent and child resolve DIFFERENT mutexes: this process then tested the
    # degraded `$STATE/loop.lock` while the child (no override, `TMPFS_ROOT` dropped) resolved the
    # DEFAULT `/dev/shm/fleet-schedule`, so the parent's own holder checks were blind to its own
    # child — a second home's `--start` spawned a child that correctly refused the box lock, the poll
    # timed out, and `--start` reported "the loop did not come up" over a box that IS scheduled. The
    # child re-runs this same usability check against the same absolute path, so it degrades in
    # exactly the same way and both sides agree.
    LOOP_LOCK_ROOT = root
    if why:
        LOOP_LOCK = os.path.join(STATE, "loop.lock")
        print(
            "  NOTE   the box lock root %s is unusable (%s) — this scheduler can only exclude "
            "against another pass that resolved the SAME state dir, so a second delivery path on "
            "this box would run the same jobs beside it (#2890). Set FLEET_SCHEDULE_LOCK_ROOT to "
            "a writable directory to restore the box-wide guard." % (root, why),
            file=sys.stderr,
        )
    else:
        LOOP_LOCK = os.path.join(root, "loop.lock")
    return LOOP_LOCK


def proc_start_time(pid):
    """The process's OWN start time — the second half of an identity, not a liveness reading.

    `/proc/<pid>/stat` field 22 (starttime, in clock ticks since boot). Everything after the LAST
    ')' is parsed: `comm` is parenthesised and may itself contain spaces and ')', so a naive
    whitespace split misreads every field after it (field 3 is the first post-comm field, and
    starttime is field 22, hence index 19).

    Returns None when it cannot be read (a non-Linux box, or a pid that vanished between the two
    reads) — an ABSENT datum, which the callers must treat as "not proof", never as a match.
    """
    try:
        with open("/proc/%d/stat" % pid, "rb") as fh:
            raw = fh.read().decode("utf-8", "replace")
    except (OSError, ValueError, OverflowError):
        return None
    tail = raw[raw.rfind(")") + 2:].split()
    if len(tail) < 20:
        return None
    return tail[19]


def read_loop_lock(path=None):
    """(pid, start, state) recorded in the box lock at `path` (default: the lock), or None.

    ⛔ JSON, NOT WHITESPACE-SEPARATED FIELDS — and the difference is a measured fail-open, caught by
    this file's own suite (§19f). The lock's `start` field is legitimately EMPTY when /proc could not
    be read, and `"%d %s %s" % (pid, "", state)` collapses to `"<pid> <state>"`: the reader then took
    the state PATH as the start time, the identity comparison failed, `loop_holder()` answered "no
    holder", and a second scheduler JOINED the live one — the guard disabled by its own record
    format. Named keys cannot shift.

    ⛔ Everything is caught for the same reason `loop_pid()` catches it (#3340): this is a RECOVERY
    path, and a 0-byte, truncated or hand-edited lock file must answer "nobody READABLE holds this",
    never raise out of `--start`/`--install`/`--verify`/`--loop` and leave the cell with no
    scheduler and no way back.
    """
    path = path or LOOP_LOCK
    if not path:
        return None
    try:
        with open(path) as fh:
            rec = json.load(fh)
        if not isinstance(rec, dict):
            return None
        pid = int(rec.get("pid"))
    except (OSError, ValueError, TypeError, OverflowError, json.JSONDecodeError):
        # A corrupt record is "no readable holder", which RECLAIMS (see `loop_holder`). It never
        # raises, and it never silently keeps a lock nobody can explain.
        # ⛔ `OverflowError` IS NOT A `ValueError` — the same trap `pid_alive` documents. JSON parses
        # `1e400` as `inf`, and `int(inf)` raises it, so a lock record of `{"pid": 1e400}` made
        # `--loop`, `--start`, `--install` AND `--verify` die with `OverflowError: cannot convert
        # float infinity to integer` instead of reclaiming — the cell left with no scheduler and its
        # own repair verb refusing. (`{"pid": NaN}` raises ValueError and was already caught, which
        # is what made the gap invisible.) Found by the [VGATE] pass.
        return None
    if not pid_alive(pid):
        return None
    start = str(rec.get("start") or "")
    state = str(rec.get("state") or "")
    return pid, start, state


def loop_holder():
    """The LIVE loop holding this box's lock, as (pid, start, state) — or None.

    ⛔ LIVENESS IS NOT IDENTITY (#1985), and this is the arm that keeps this guard from becoming
    that defect: a recycled pid read as "the holder is alive" BOTH stops the box and blocks its own
    recovery, because a start that defers to a wrong pid can never repair the lock it defers to.
    So the pid must be alive, its command line must be a `fleet-schedule --loop`, AND its own start
    time must equal the one the lock recorded. A missing start time (a lock written on a box with
    no /proc) is an absent datum, so the command-line check alone decides — which is still strictly
    more than a bare pid.
    """
    return live_holder(record=read_loop_lock())


def live_holder(record):
    """The IDENTITY CHECK ITSELF, for a record not necessarily read from `LOOP_LOCK`.

    Split out because the reclaim paths must judge a record they have MOVED ASIDE, not the one at the
    lock's path — reading `LOOP_LOCK` there answers about the wrong claim.
    """
    if record is None:
        return None
    pid, start, _state = record
    if not pid_is_our_loop(pid):
        return None
    if start:
        observed = proc_start_time(pid)
        if observed is not None and observed != start:
            return None
    return record


def same_state_dir(a, b):
    """Two spellings of one state dir are the SAME state dir.

    `STATE` comes straight from the environment, so a trailing slash, a `..` segment or a symlinked
    home makes ONE directory read as TWO. Both directions of that mistake are defects: a loop
    deferring to "another" state dir that is really its own is a false NOTE on a normal box, and a
    genuinely different dir read as ours would make `--verify` certify a state dir with no loop.
    """
    if not a or not b:
        return False
    try:
        return os.path.realpath(a) == os.path.realpath(b)
    except (OSError, ValueError):
        return os.path.normpath(a) == os.path.normpath(b)


def describe_holder(holder):
    pid, _start, owner = holder
    return "pid %d%s" % (pid, ", $STATE=%s" % owner if owner else "")


def claim_loop_lock():
    """Take the box's loop lock atomically. Returns None when WE hold it, else the live holder.

    `O_CREAT|O_EXCL` is the claim: the kernel decides the winner, so there is no read-then-write
    window. That is exactly what the pidfile check further down is NOT — it reads `loop.pid` and
    then writes it, so two starts in the same instant can both pass the check.

    A lock whose holder is provably gone is RECLAIMED BY RENAME, never by unlink-then-create:
    between an unlink and the next `O_EXCL` two starters can both create the file and both win
    (#3353's class, measured there on this file's job lock). A rename is atomic, so the NAME is
    never absent for a third party to fill.

    ⛔ WHAT THIS RECLAIM DOES **NOT** PROVE, stated because the first two cuts of it claimed more.
    A path-based mutex with stale takeover cannot be made race-free by patching: the staleness
    decision precedes the rename, so a claim published inside that window is moved aside, and if a
    THIRD starter takes the freed name before the restore, the moved claim cannot be put back. The
    file therefore never deletes a record it did not judge stale (`moved == judged` is required
    before any unlink), and when the restore fails it KEEPS the displaced record and says so loudly
    — a silent two-loop outcome is not acceptable, an evidenced one is survivable. The real fix is a
    kernel lock on a persistent file, which is #3353's scope and a reopen of #469's `flock` ruling,
    not something this change may adopt quietly.
    """
    if not LOOP_LOCK:
        return None
    payload = json.dumps(
        {"pid": os.getpid(), "start": proc_start_time(os.getpid()) or "", "state": STATE}
    ) + "\n"
    # ⛔ THE RECORD IS PUBLISHED COMPLETE OR NOT AT ALL — `os.open(O_EXCL)` alone is atomic only in
    # the file's EXISTENCE, not in its CONTENT: the file is 0 bytes until `os.write` runs, so a
    # second claimant landing in that window read a JSONDecodeError, concluded "no readable holder",
    # and reclaimed a claim that was live — BOTH loops ran. (Measured by the [VGATE] pass, which
    # widened only that window; the window is microseconds but is exactly what a descheduled or
    # GC-paused creator on a loaded cell produces.) Writing the payload to a private temp name and
    # `os.link`-ing it into place makes existence and content arrive together, and `os.link` fails
    # with EEXIST when somebody got there first — the same publish `write_stamp` uses.
    staged = "%s.%d.tmp" % (LOOP_LOCK, os.getpid())
    try:
        with open(staged, "w") as fh:
            fh.write(payload)
    except OSError as exc:
        return _permit_without_lock(
            "cannot stage the box lock beside %s (%s: %s)" % (LOOP_LOCK, type(exc).__name__, exc)
        )
    try:
        for _ in range(3):
            try:
                os.link(staged, LOOP_LOCK)
            except FileExistsError:
                # ⛔ `judged` IS THE RECORD WE WILL VERIFY AFTER THE RENAME. The STALENESS decision
                # is `loop_holder()`'s own (second) read, and the two can disagree — which is exactly
                # what the `moved != judged` arm below exists to survive.
                judged = read_loop_lock()
                holder = loop_holder()
                if holder is not None:
                    return holder
                # Stale: no live holder. Take it aside under OUR OWN name first, so two reclaimers
                # cannot both unlink the same file and then both create it.
                # ⛔ UNIQUE PER ATTEMPT, not per pid: a later reclaim by the SAME pid used to
                # `rename` straight over a record the previous attempt had preserved for evidence.
                aside = "%s.reclaim.%d.%d" % (LOOP_LOCK, os.getpid(), time.time_ns())
                try:
                    os.rename(LOOP_LOCK, aside)
                except OSError:
                    # Somebody else moved or removed it between our read and our rename. Re-loop
                    # and let `os.link` decide against whatever is there now.
                    continue
                # ⛔ VERIFY WHAT WE ACTUALLY MOVED, AND PUT IT BACK IF IT IS NOT WHAT WE JUDGED.
                # The staleness decision happens BEFORE the rename, so a competitor that completed
                # ITS reclaim in the window has its LIVE claim renamed away — and if we then deleted
                # it, both starters would conclude they hold the box: the #2890 defect re-created by
                # the lock's own reclaim. Measured by the [VGATE] pass with real kernel ops.
                moved = read_loop_lock(aside)
                if moved == judged:
                    # The record we judged stale is the record we moved: a normal reclaim.
                    try:
                        os.unlink(aside)
                    except OSError:
                        pass
                    continue
                # NOT ours to destroy. Restore it WITHOUT clobbering a third party — `link` succeeds
                # only while the name is still free, unlike `rename`, which overwrites.
                try:
                    os.link(aside, LOOP_LOCK)
                except OSError:
                    # ⛔ AND IF EVEN THAT FAILS, THE DISPLACED CLAIM IS THE ONLY COPY. Deleting it
                    # would erase the evidence and leave two unguarded loops with nothing in any log
                    # — the silent dual-run `_permit_without_lock` exists to make impossible. So the
                    # file is KEPT (one per contended pid, never read back) and the outcome is
                    # DISCLOSED, in the same terms as the permit path.
                    _permit_without_lock(
                        "a reclaim moved a claim aside at %s that was not the stale record it judged "
                        "(%r vs %r) and could not restore it — that claim's record is preserved "
                        "there; a second scheduler may be running beside this one"
                        % (aside, moved, judged)
                    )
                    continue
                try:
                    os.unlink(aside)
                except OSError:
                    pass
                continue
            except OSError as exc:
                # ⛔ A LOCK ROOT THAT CANNOT HARD-LINK IS NOT A BROKEN BOX. A FUSE/tmpfs mount may
                # refuse `link(2)` while allowing `open(O_EXCL)`; permitting there would silently
                # disable a guard that worked before this change. Fall back to the create, which is
                # atomic in the file's EXISTENCE (only the content window returns, and a contender
                # that reads an empty file now simply reclaims and re-publishes — it cannot outrun
                # the `read_loop_lock(aside) != judged` check above for longer than that window).
                if exc.errno in (errno.EPERM, errno.EOPNOTSUPP, errno.ENOSYS):
                    try:
                        fd = os.open(LOOP_LOCK, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
                    except FileExistsError:
                        # ⛔ THE FALLBACK MUST ASK THE SAME QUESTION THE LINK PATH ASKS, AND THEN DO
                        # THE SAME THING ABOUT IT. A bare `continue` retried the create against a name
                        # that was still taken, burned all three attempts and landed on a disclosed
                        # PERMIT — so on any link-refusing root a STALE OR CORRUPT record made every
                        # claimant permit, i.e. two loops on one box, permanently (measured with two
                        # real processes: both printed GUARD OFF and the stale record sat byte-
                        # identical afterwards). A live holder is returned (the caller refuses);
                        # a provably-gone one is RECLAIMED — by `rename`, which these filesystems do
                        # allow even when they refuse `link`.
                        fallen_holder = loop_holder()
                        if fallen_holder is not None:
                            return fallen_holder
                        fallen_aside = "%s.reclaim.%d.%d" % (LOOP_LOCK, os.getpid(), time.time_ns())
                        try:
                            os.rename(LOOP_LOCK, fallen_aside)
                        except OSError:
                            continue
                        # ⛔ JUDGE WHAT WE MOVED, NEVER WHAT IS AT THE PATH (the reclaim above makes
                        # the same point): a claim published between the two reads must survive.
                        # ⛔ AND IT MUST NOT BE PUT BACK BY `rename` — `rename` REPLACES the
                        # destination, so a fourth party that filled the freed name in the meantime
                        # would have its live record DESTROYED, and an `os.path.exists` guard only
                        # narrows that window (it is the same read-then-act the claim itself refuses).
                        # The link path cannot restore either on a link-refusing root, and its ruling
                        # is the one that holds here: KEEP the displaced record, never delete it, and
                        # SAY SO — a silent two-loop outcome is unacceptable, an evidenced one is
                        # survivable (this file's `claim_loop_lock` docstring states the same).
                        # ⛔ AND WHEN THE DISPLACED CLAIM IS LIVE, THIS PASS MUST REFUSE — NOT PERMIT
                        # AND RETRY. `_permit_without_lock(...)` followed by `continue` was WORSE than
                        # the permit it looks like: the `rename` above left `LOOP_LOCK` FREE, so the
                        # next attempt's `O_EXCL` create SUCCEEDS (the link still refuses — that is why
                        # this arm exists), the inode check passes and `claim_loop_lock` returns None,
                        # i.e. "I hold the box". The displaced live loop does not re-read the lock, so
                        # TWO loops run AND the name now records the NEWCOMER — after which `--verify`
                        # sees one healthy holder with a fresh tick and prints `SCHEDULE VERIFIED`. The
                        # disclosure that was supposed to make that survivable is one stderr line in
                        # the starting pass that no instrument reads. The sibling arm 40 lines up
                        # (`return fallen_holder`) already answers this condition correctly; the
                        # asymmetry here was the defect.
                        fallen_live = live_holder(read_loop_lock(fallen_aside))
                        if fallen_live is not None:
                            # Best-effort ATOMIC restore. `link` FAILS rather than replacing, so a
                            # fourth party that took the freed name keeps its own record — the reason
                            # `rename` is forbidden here does not apply to it. On this root `link`
                            # cannot succeed (it is the arm's precondition), so the usual outcome is
                            # the disclosure below with the record preserved at `fallen_aside`.
                            try:
                                os.link(fallen_aside, LOOP_LOCK)
                            except OSError:
                                print(
                                    "  WARN   a reclaim on a link-refusing root moved a claim aside "
                                    "at %s that turned out to be LIVE (%r) and could not be put back "
                                    "— that claim's record is preserved there and THIS pass refuses "
                                    "to run beside it (#2890)" % (fallen_aside, fallen_live),
                                    file=sys.stderr,
                                )
                            else:
                                try:
                                    os.unlink(fallen_aside)
                                except OSError:
                                    pass
                            return fallen_live
                        try:
                            os.unlink(fallen_aside)
                        except OSError:
                            pass
                        continue
                    except OSError as create_exc:
                        # ⛔ THE DISCLOSURE MUST NAME THE ERROR THAT ACTUALLY STOPPED US. This arm is
                        # reached when the CREATE fails, but `exc` here is still the LINK error (the
                        # one that selected the fallback), so using it reported a misdiagnosis: a
                        # full disk or an unwritable root was disclosed as `Operation not permitted`
                        # — the link errno — and an operator was sent to the wrong cause on the exact
                        # failure this fallback exists to survive. Bind the create's own exception,
                        # and leave the `exc`-based message below to the LINK failure it describes.
                        return _permit_without_lock(
                            "cannot create the box lock at %s (%s: %s)"
                            % (LOOP_LOCK, type(create_exc).__name__, create_exc)
                        )
                    else:
                        # ⛔ PUBLISH IS NOT COMPLETE UNTIL THE FILE AT `LOOP_LOCK` IS STILL OURS.
                        # `O_EXCL` makes only the CREATE atomic; the write that follows is a window,
                        # and a contender that reclaims inside it RENAMES our (empty) claim away and
                        # publishes its own. Writing then lands in the inode nobody can see, so
                        # returning "I hold the box" here would give TWO loops on one box. This is
                        # the same rule `acquire_lock` states for the per-job lock, and the fallback
                        # was the one publish path that skipped it. Comparing the inode is enough:
                        # the reclaimer MOVES our file, so `LOOP_LOCK` afterwards is either absent
                        # or a different inode, and a write to a moved-but-live inode would
                        # otherwise look like success.
                        try:
                            os.write(fd, payload.encode())
                            ours = os.fstat(fd)
                        finally:
                            os.close(fd)
                        try:
                            now_at_path = os.stat(LOOP_LOCK)
                        except OSError:
                            now_at_path = None
                        if now_at_path is not None and (now_at_path.st_dev, now_at_path.st_ino) == \
                                (ours.st_dev, ours.st_ino):
                            return None
                        # ⛔ OUR CLAIM IS NOT THE ONE AT THE PATH, SO WE DO NOT HOLD IT. Re-examine
                        # instead of believing the create: the next attempt asks `loop_holder()` and
                        # returns a LIVE holder to the caller (which then refuses), or falls into the
                        # disclosed permit if the root stays unusable. Returning a permit straight
                        # from here would run this pass beside a scheduler that just beat us.
                        continue
                # ⛔ THIS IS THE *LINK* FAILURE, and the message says so. `errno` not in the
                # fallback set means `os.link` itself was refused (EROFS/EACCES/ENOSPC on the link),
                # so calling it a create failure named a syscall that never ran. The create's own
                # failure is disclosed above, from `create_exc`.
                return _permit_without_lock(
                    "cannot link the box lock into place at %s (%s: %s)"
                    % (LOOP_LOCK, type(exc).__name__, exc)
                )
            return None
        # Three contended attempts and no verdict: either the box's lock is churning, or somebody
        # keeps reclaiming ours. Fall back to the probe — a HOLDER refuses, and a genuinely empty
        # lock permits with the disclosure below rather than looping for ever.
        holder = loop_holder()
        if holder is not None:
            return holder
        return _permit_without_lock(
            "the box lock at %s stayed contended across 3 attempts" % LOOP_LOCK
        )
    finally:
        try:
            os.unlink(staged)
        except OSError:
            pass


def _permit_without_lock(why):
    """Run WITHOUT the box lock, and say so where an operator can see it.

    ⛔ LOUDLY, NOT SILENTLY — this is the disclosure the permit path owes. Two decisions meet here
    and only one of them is about the schedule: refusing takes the box's only alarm (reapers,
    liveness, pr-doctor) offline exactly when the box is in trouble (#2898's recorded arm), so we
    PERMIT; but a permit that says nothing is the same silent fail-open `acquire_lock` already rules
    out in this file — measured there, the disk-full cause "never appeared in the log at all".
    """
    print(
        "  WARN   ONE-LOOP-PER-BOX GUARD OFF: %s — running the pass WITHOUT the box lock, so a "
        "second delivery path on this box could run the same jobs beside it (#2890)"
        % why,
        file=sys.stderr,
    )
    return None


def release_loop_lock():
    """Release ONLY if the lock still records US — an exiting loop must never delete a
    successor's lock (the same ownership-checked release as ai-drainer.sh's GUARD 1)."""
    if not LOOP_LOCK:
        return
    try:
        with open(LOOP_LOCK) as fh:
            pid = int(json.load(fh).get("pid"))
    except (OSError, ValueError, TypeError, OverflowError, json.JSONDecodeError):
        return
    if pid != os.getpid():
        return
    try:
        os.unlink(LOOP_LOCK)
    except OSError:
        pass


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
    # 3, not 2: the re-examine paths (`continue` when a racer replaced the file we inspected) burn
    # an iteration without attempting a create, so 2 could discard a legitimate steal on the LAST
    # iteration and answer "already running (lock held)" for a lock that no longer exists.
    for _ in range(3):
        try:
            fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
        except FileExistsError:
            # Somebody may hold it (live or abandoned) — fall through to the probe below.
            pass
        except OSError:
            # ⛔ NOT swallowed. EACCES/EROFS/ENOSPC on the CREATE itself is not "somebody else has
            # it" — the caller's per-job guard names the real cause in the log. An earlier version
            # answered `None` here, so on the very ENOSPC recovery this whole change is about the
            # operator read `SKIP <job>: already running (lock held)` for a job nothing held, and
            # the disk-full cause never appeared in the log at all.
            raise
        else:
            # ⛔ THE INITIALISER IS LOAD-BEARING, NOT TIDINESS. `os.fstat(fd)` can itself fail
            # (EIO/ESTALE on a full or dying filesystem — the fault class this change is about), and
            # the handler below reads `own`. Without this line a stat fault became
            # `UnboundLocalError: cannot access local variable 'own'` — a coding error replacing the
            # real cause — and because it is raised BEFORE the identity-checked cleanup, the 0-byte
            # lock the create just made was left behind instead of being removed. Measured: removing
            # it turns `OSError: [Errno 5]` into `UnboundLocalError`; `if own is not None` then never
            # reaches the cleanup the comment three lines above promises.
            own = None
            try:
                own = os.fstat(fd)
                # ⛔ A SMALL WRITE STILL NEEDS A DATA BLOCK, so ENOSPC/EIO/EDQUOT fail here having
                # already CREATED the file. Unguarded that left a 0-byte lock behind, and every
                # later `acquire_lock` then raised IndexError on `"".split()[0]` — measured — so the
                # job never ran again on any pass until a human deleted the lock.
                # ⚠️ `close`, NOT `write`, is the leg that defeats the probe's self-healing: a
                # deferred ENOSPC/EIO is reported by close AFTER the write landed, so the lock then
                # holds OUR OWN LIVE PID — the probe would read a live holder and answer "already
                # running" for ever, and nothing would ever unlink it. So on ANY failure here we
                # remove the file ourselves (we created it in this iteration, so it is provably
                # ours) before propagating.
                # ⛔ `os.write` RETURNS A COUNT. A short write (ENOSPC/EINTR/SIGPIPE on a dying
                # filesystem) leaves a TRUNCATED pid in a lock WE created — measured: the file held
                # `"3"`, which parses as pid 3 and is alive, so the probe refused the lock forever.
                # Ignoring the return value made that wedge invisible at the one place we can see it.
                payload = ("%d\n" % os.getpid()).encode()
                written = os.write(fd, payload)
                if written != len(payload):
                    raise OSError(5, "short write to %s (%d of %d bytes)"
                                  % (path, written, len(payload)))
                os.close(fd)
            except OSError:
                try:
                    os.close(fd)
                except OSError:
                    pass
                # ⛔ IDENTITY-CHECKED, NOT NAME-CHECKED. "We created it in this iteration, so it is
                # provably ours" stopped being true the moment a probe could steal an EMPTY lock
                # (see the probe's parse arm): a racer can replace the path between our create and
                # this cleanup, and a bare `unlink(path)` would then delete THEIR live lock — two
                # callers both told they hold it. Remove it only while it is still our own inode.
                if own is not None:
                    try:
                        cur = os.stat(path)
                    except OSError:
                        cur = None
                    if cur is not None and (cur.st_dev, cur.st_ino) == (own.st_dev, own.st_ino):
                        try:
                            os.unlink(path)
                        except OSError:
                            pass
                raise
            # ⛔ PUBLISH IS NOT COMPLETE UNTIL THE FILE AT `path` IS STILL OURS. Between `O_EXCL`
            # and the write above, the lock is ZERO BYTES, and a racer's probe reads that as an
            # unusable lock, matches our inode (nothing was replaced), and STEALS it — after which
            # it publishes its own and both callers would return a lock path. Verified by fault
            # injection: with the create→write window widened, both callers were told they held it.
            # Re-verifying ownership here makes the loser LOSE: it re-examines (bounded by the
            # retry count) and answers "held" to the racer that actually owns the lock now.
            # ⛔ A FAILED STAT IS NOT "SOMEONE ELSE'S LOCK" — but it is not proof of ownership
            # either, so neither "abandon" nor "assume ours" is sound. Both wrong answers are
            # measured:
            #   • `except OSError: continue` (blind abandon) — one transient EIO/ESTALE, or an
            #     EACCES flip landing after the create (the fault test 18n constructs), abandoned a
            #     lock we still held, with OUR live pid inside it. Every later `acquire_lock` then
            #     read a live holder and answered "held": `SKIP <job>: already running (lock held)`
            #     for a lock this process had created, and the job never ran again — a wedge.
            #   • `except OSError: return path` (blind assume) — `O_EXCL` speaks about CREATE time,
            #     not about what now sits at `path`. A stat failure that coincides with the very
            #     steal documented above made us return a lock whose content was the RACER's live
            #     pid; `run_job` then ran the body concurrently with it and its `finally` unlinked
            #     the racer's lock by name, after which a third caller also acquired it.
            # So on a stat failure we ask the QUESTION THE PROBE ASKS — read the file and take the
            # pid from the fd we actually opened. Ours ⇒ we still hold it (keep it). Someone else's
            # ⇒ we lost (re-examine). Unreadable ⇒ undeterminable, and the answer to that is KEEP —
            # NOT "fail closed", which WEDGES the job: see the `cur is None` arm below, where a
            # `continue` here is measured abandoning a lock that holds our own live pid forever.
            cur = None
            try:
                cur = os.stat(path)
            except FileNotFoundError:
                # Same reasoning: one unreliable filesystem can answer ENOENT for a file it holds.
                # A second ENOENT is treated as a real deletion (the loop re-creates the lock).
                # ⛔ NOT "anything else resolves to OURS, which cannot wedge" — that was this
                # comment's earlier claim and it is FALSE, measured in both branches it covered: a
                # live foreign inode resolved to None, and a live racer alongside a failed re-ask
                # resolved to a path naming the RACER. Any non-ENOENT outcome ASKS the ownership
                # question below (read the pid, keep only if it is ours); nothing here may assume.
                try:
                    cur = os.stat(path)
                except FileNotFoundError:
                    continue
                except OSError:
                    # ⛔ NOT `return path`. "Anything else resolves to OURS" is FALSE, and measured
                    # false: with a racer's live-pid lock in place (the steal this block exists to
                    # survive) plus a one-shot `ENOENT` then `EIO`, returning the path made us run
                    # the job while the lock on disk named the RACER — and `run_job`'s `finally`
                    # then unlinked the racer's lock by name, after which a third caller acquired it
                    # too. Falling through to `cur = None` asks the question properly: read the
                    # pid, keep only if it is ours.
                    cur = None
            except OSError:
                cur = None
            if cur is None:
                # ⛔ WHEN NOTHING CAN BE DETERMINED, KEEP — do not "fail closed" with `continue`.
                # `continue` is the WRONG answer here and it was measured as one: it abandons a lock
                # this process created, leaving it on disk holding OUR OWN LIVE PID, so every later
                # `acquire_lock` reads a live holder and refuses forever — `SKIP <job>: already
                # running (lock held)` for a lock we made. Worse, the failure need not raise: a read
                # that returns b"" wedges the job with NO exception anywhere. The comment this
                # replaces claimed a `continue` was a "skipped pass" — it is not, because the lock
                # persists and nothing steals a live-pid lock.
                # So the three reachable states are: keep (proved ours), lose (proved someone
                # else's), and UNDETERMINABLE — and for the last one KEEP is the only answer that
                # cannot wedge. The residual is the mirror image and is declared rather than
                # papered over: keep is wrong only if a racer stole the lock AND both the stat and
                # the read failed, i.e. three coincident faults; `continue` is wrong on ONE. That
                # asymmetry is the whole argument, and the real fix for the remaining class is the
                # `flock` redesign in #3353, which removes stealing altogether.
                mine = None
                try:
                    with open(path, "rb") as fh:
                        mine = fh.read(64).decode("ascii", "replace").strip()
                except FileNotFoundError:
                    # ⛔ ENOENT FROM THE READ IS NOT PROOF EITHER, because the STAT that just
                    # failed already told us this filesystem is answering unreliably — and
                    # ESTALE→ENOENT is the textbook pair on a dying mount. Measured: stat EIO/ESTALE
                    # then open→ENOENT `continue`d, leaving the lock on disk holding OUR live pid,
                    # and the next pass (faults lifted) still returned None — the identical wedge.
                    # Re-ask ONCE: a genuine deletion still answers ENOENT and we re-create it; an
                    # unreliable answer resolves to ours (KEEP), which cannot wedge.
                    try:
                        again = os.stat(path)
                    except FileNotFoundError:
                        continue      # really gone, twice over — the loop re-creates it
                    except OSError:
                        mine = str(os.getpid())   # still undeterminable → KEEP (cannot wedge)
                    else:
                        mine = (str(os.getpid())
                                if (again.st_dev, again.st_ino) == (own.st_dev, own.st_ino)
                                else None)
                        if mine is None:
                            continue  # the replacement is provably not ours
                except OSError:
                    mine = None       # undeterminable — fall through to KEEP (see above)
                # ⛔ AN EMPTY READ IS NOT "PROVABLY FOREIGN" — it is another undeterminable. `read`
                # returning b"" raises nothing at all, and the previous `mine is not None and …`
                # test saw `""` as a pid that is not ours, so it `continue`d and ABANDONED a lock
                # this process had created and written its own live pid into. Measured: first
                # acquire False, lock left on disk holding OUR pid, and every later pass refused —
                # the wedge, with no exception anywhere. Only a NON-EMPTY, different pid is proof.
                if mine and mine != str(os.getpid()):
                    continue          # provably someone else's live lock
            elif cur.st_dev != own.st_dev or cur.st_ino != own.st_ino:
                continue
            return path
        # Probe: refuse a LIVE holder, steal a dead or unusable one, retry a vanished one.
        seen = None
        try:
            with open(path) as fh:
                seen = os.fstat(fh.fileno())
                pid = int(fh.read().strip().split()[0])
        except FileNotFoundError:
            # ⛔ The holder released it between our O_EXCL and this probe. That is a LOST RACE, and
            # the retry loop is what answers it — `continue` here, not the `unlink` arm below (whose
            # OSError returns None after a single attempt, i.e. the job is skipped and the log says
            # "already running (lock held)" for a lock that does not exist).
            continue
        except (OSError, ValueError, IndexError, TypeError):
            pid = None
        if pid is not None and pid_alive(pid):
            return None
        # ⛔ UNLINK BY IDENTITY, NOT BY NAME. Probe-then-unlink is check-then-act: a racer can
        # replace the abandoned lock with one naming ITS OWN live pid between our read and our
        # unlink, and we would then delete a live holder's lock and win our own O_EXCL — two
        # callers both told they hold it, so the same job runs twice concurrently. Measured on
        # 40 unsynchronised fork trials: 7 produced two winners (18%); 60/60 with a synchronised
        # start. Comparing (st_dev, st_ino) against the file we actually read makes the deletion
        # conditional on it still being that file; if it changed, re-examine instead.
        try:
            now = os.stat(path)
        except FileNotFoundError:
            continue
        except OSError:
            return None
        # `seen is None` means we could not read the lock to identify it (EACCES/EMFILE/EIO on a
        # 0-mode or foreign-uid file). That must stay STEALABLE, exactly as before this change:
        # refusing it would make an unreadable stale lock a permanent skip — the very "a crashed run
        # must not disable its job forever" contract this function's docstring makes.
        if seen is not None and (now.st_dev, now.st_ino) != (seen.st_dev, seen.st_ino):
            continue
        try:
            os.unlink(path)
        except FileNotFoundError:
            continue
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
    # ⛔ THE FALLBACK `os.makedirs` BELOW USED TO SIT OUTSIDE ANY GUARD, between the lock and the
    # `try:`/`finally:` that is the ONLY place the lock and busy marker are released. It raises on
    # ENOSPC/EACCES — so on the very trigger this change exists for, the exception escaped with the
    # lock still held by the LOOP'S OWN live pid, and the job was wedged for ever: "already running
    # (lock held)" on every pass while `--verify` certified it. Measured, and it survived recovering
    # the disk. `mark_busy` is already best-effort internally; the log path was not.
    # Moved inside the guarded region, whose failure path now releases explicitly.
    try:
        log_path = job.log_path()
        try:
            os.makedirs(os.path.dirname(log_path), exist_ok=True)
        except OSError:
            log_path = os.path.join(STATE, "logs", job.label + ".log")
            os.makedirs(os.path.dirname(log_path), exist_ok=True)
    except OSError as exc:
        # Could not even decide where to log: release and report, rather than wedge.
        log("ERROR %s could not be started (%s: %s) — nothing was run, the job is NOT locked"
            % (job.label, type(exc).__name__, exc))
        clear_busy(job.label)
        try:
            os.unlink(lock)
        except OSError:
            pass
        return None

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
            # ⛔ THE STAMP WRITE IS GUARDED, AND IT IS THE ONLY UNGUARDED DISK WRITE IN THIS
            # `finally` — which is the only place that unlocks the job. Measured 2026-11-03: on
            # ENOSPC (the very trigger this change exists for) `write_stamp` raised, the `finally`
            # aborted before `clear_busy()`/`os.unlink(lock)`, and the lock survived holding the
            # LOOP'S OWN live pid — so `acquire_lock()` then answered "already running (lock
            # held)" for ever, for every job that fired, including `eldato-disk-reaper`. The log
            # said the opposite of the truth, the job never ran again, and `--verify` returned
            # SCHEDULE VERIFIED over it for up to JOB_TIMEOUT + 3*TICK. The loop no longer DIES on
            # a full disk; without this it merely fails to schedule anything — the same closed
            # feedback loop with a healthier-looking log line.
            try:
                write_stamp(job.label, started, rc, time.time() - started)
            except OSError as exc:
                log("ERROR %s ran (rc=%s) but its stamp could not be written (%s: %s) — it will "
                    "read as never run until a later run succeeds; the job is NOT wedged"
                    % (job.label, rc, type(exc).__name__, exc))
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


def _stderr_is_stdout():
    """True when stderr and stdout are the SAME target (so one report is enough).

    ⚠️ The comparison is stderr-vs-STDOUT, not stderr-vs-loop.log — an earlier version compared
    against loop.log and was only correct in the SPAWNED shape. `--loop > out 2>&1` (and this
    suite's own `run()` helper, which uses `2>&1`) merges the two streams while neither is
    loop.log: stderr and log()'s print both went to one file, so every failure was reported
    twice — measured 6 lines for 3 failures. samestat() covers both shapes.
    """
    try:
        return os.path.samestat(os.fstat(sys.stderr.fileno()), os.fstat(sys.stdout.fileno()))
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
    # ⛔ A LOGGING FAILURE MUST NEVER BECOME A PROCESS FAILURE. When the loop's stdout IS this
    # file (spawn_loop sets stdout to loop.log and stderr=STDOUT at the same target), THIS
    # print() is the write — and on a full disk it raises ENOSPC. Measured 2026-11-03 on a cmux
    # cell: that OSError escaped every handler in the loop and the cell's ONLY scheduler died,
    # its last words a truncated `OSError: [Errno 28] No space left o` — the traceback itself
    # could not be written. The file-append above is already guarded; leaving the report
    # unguarded made a failure to REPORT the failure fatal.
    # ⛔ Exception, NOT OSError: `print()` raises UnicodeEncodeError — a ValueError — when the
    # stdout encoding cannot represent the message, and EVERY message here contains an em dash.
    # Measured with PYTHONIOENCODING=ascii: the unguarded print killed the loop, i.e. the guard
    # added to keep the loop alive was itself what killed it.
    try:
        print(line, flush=True)
    except Exception:  # noqa: BLE001 — a logging failure is never a process failure
        pass


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
    # ⛔ ONE LOOP PER BOX (#2890), checked BEFORE the pass and above the pidfile write. The check
    # above is scoped to $STATE, so it is structurally blind to a second delivery path on the same
    # box resolving a DIFFERENT home (measured: 7 instances on cell-4 across five state dirs, all
    # running this one job set). This arm is the box's mutex, and it is idempotent by construction:
    # a start that loses the race writes NOTHING into the holding loop's state dir, and says which
    # pid holds it plus where that loop keeps its state. The refusal line goes to THIS state dir's
    # own log on purpose — unlike a heartbeat tick, the two instances do not share a state dir, so
    # this log is the only channel an operator can read afterwards.
    holder = claim_loop_lock()
    if holder is not None:
        msg = ("loop: this box already has a scheduler (%s) — one loop per box, so this instance "
               "exits without running or writing anything (#2890)" % describe_holder(holder))
        log(msg)
        print(msg, flush=True)
        return 0
    # ⛔ ATOMIC, AND GUARDED — this file is the cell's ONLY evidence that a loop is running, and the
    # old `open(pidfile, "w")` TRUNCATED it before writing. On ENOSPC (this PR's own trigger) the
    # write raised, the process died, and the truncated 0-byte pidfile made every recovery command
    # (--loop/--start/--install/--verify/--status/--stop) raise IndexError. Write beside it and
    # rename, exactly as `write_stamp` does, so a failed write leaves the PREVIOUS pidfile intact.
    try:
        tmp_pid = pidfile + ".tmp"
        with open(tmp_pid, "w") as fh:
            fh.write("%d\n" % os.getpid())
        os.replace(tmp_pid, pidfile)
    except OSError as exc:
        log("ERROR loop: cannot record our pid in %s (%s: %s) — the loop still runs, but "
            "--verify will read no loop; the previous pidfile (if any) was left intact"
            % (pidfile, type(exc).__name__, exc))

    def bye(signum, _frame):
        log("loop: signal %d — exiting" % signum)
        try:
            os.unlink(pidfile)
        except OSError:
            pass
        # ⛔ Ownership-checked: a TERM'd loop must not delete the lock of the loop that replaced it
        # (`kickstart -k` SIGTERMs and starts the successor immediately).
        release_loop_lock()
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
        except Exception as exc:  # noqa: BLE001 — a loop must outlive one unreadable set
            # ⛔ Exception, NOT (ScheduleError, OSError). `load_jobs()` reads untrusted plist
            # files, and the ways that fails are not all OSErrors: a plist whose ROOT is an array
            # makes `data.get("Label")` raise AttributeError, a non-string StandardOutPath makes
            # `render()` raise TypeError. Measured: one such file killed the loop permanently —
            # the identical 3.6-day outcome this change exists to prevent, one line above the
            # guard that fixes the other half of it. Keeping the previous set is the right
            # answer to ANY unreadable declaration set.
            log("ERROR: cannot read the job declarations (%s: %s) — keeping the previous set"
                % (type(exc).__name__, exc))
        # ⛔ The tick is stamped at the START of the pass, not after it: the pass is
        # single-threaded, so an end-of-pass stamp makes the tick's age equal the duration of the
        # job currently executing — and a job allowed to run for JOB_TIMEOUT (1800s by default,
        # 300s from the shipped templates onward) would then read as "the process exists but is
        # not passing" WHILE it is doing exactly what it was told.
        # ⛔ THE LOOP'S OWN BOOKKEEPING IS NOT A JOB, AND IT MUST NOT BE ABLE TO KILL THE LOOP.
        # Measured 2026-11-03 on a cmux cell: `mark_tick()` hit ENOSPC on a full disk, the
        # OSError escaped `while True`, and the cell's ONLY scheduler was dead for 3.6 days —
        # taking `eldato-disk-reaper` with it, i.e. the very job that would have freed the space
        # that killed it. A closed feedback loop.
        # The handler below cannot cover this: it protects ONE JOB being run, and these writes are
        # the loop's own. A full disk is external and transient and this process is the only thing
        # that will retry, so the correct cost of it is ONE TICK — never the process.
        # ⚠️ The tick write is guarded SEPARATELY from the pass, on purpose: a failed stamp must
        # not cancel the jobs. Folding them into one guard made a broken tick discard the whole
        # pass (caught by case 18a — the marker stopped growing while the loop stayed alive, which
        # is a quieter failure than the death this fixes and must not be traded for it).
        try:
            mark_tick()
        except OSError as exc:
            report_bookkeeping_failure(exc)
        try:
            if jobs:
                now = time.time()
                for job in jobs:
                    if job.error or job.skip:
                        continue
                    # ⛔ ONE UNPARSEABLE JOB MUST NOT UNSCHEDULE THE ONES AFTER IT. `is_due`
                    # reads THIS job's own stamp (hand-edited, or written by an older copy) and
                    # its calendar values, so it can raise on one job's data — and the pass guard
                    # below abandons the REST OF THE SET when it does. Measured with
                    # `{"started": "yesterday"}` on the middle of three jobs: the ones sorting
                    # after it ran 0x for the whole window while the loop ticked happily, so every
                    # liveness check read "fine". Skip and NAME that one job; the others still run.
                    try:
                        due_now = is_due(job, read_stamp(job.label), now)
                    except Exception as exc:  # noqa: BLE001 — one bad stamp is one bad job
                        log("ERROR %s has an unusable stamp or calendar (%s: %s) — skipping it; "
                            "the rest of the set still runs"
                            % (job.label, type(exc).__name__, exc))
                        continue
                    if due_now:
                        # ⛔ ONE BROKEN DECLARATION MUST NOT STOP THE SET. Anything run_job
                        # raises (a bad log path, an unusable lock dir) used to escape here and
                        # terminate the loop, leaving every other job unscheduled until a human
                        # restarts it.
                        try:
                            run_job(job)
                        except Exception as exc:  # noqa: BLE001 — a loop must outlive one job
                            log("ERROR %s could not be run (%s: %s) — continuing with the set" % (job.label, type(exc).__name__, exc))
        except Exception as exc:  # noqa: BLE001 — a loop must outlive one bad pass
            # ⛔ Exception, NOT OSError, and NOT a second guard on run_job (the inner one already
            # covers that). What escapes here is everything OUTSIDE a job: `read_stamp`/`is_due`
            # over a stamp a foreign writer or a hand-edit left malformed (`{"started":
            # "yesterday"}` ⇒ `float(last)` ⇒ ValueError) and `next_occurrence`'s `int(calendar
            # ["Hour"])` over a template whose value is not a number (load_jobs validates the
            # SHAPE of a dict, not its values). Both are one bad file on disk, and both used to
            # stop every job on the box permanently — the same outcome this whole change exists to
            # prevent, so the guard must be as wide as the ways a pass can fail. SystemExit is a
            # BaseException, so `--stop` and the signal handlers are unaffected.
            report_bookkeeping_failure(exc)
        # ⛔ THE LAST UNGUARDED STATEMENT IN THE LOOP. `TICK` comes from an env var with no upper
        # bound, so `FLEET_SCHEDULE_TICK=10**20` made `time.sleep` raise OverflowError ("timestamp
        # too large") and killed the loop at the end of its FIRST pass — after writing a fresh
        # tick, so `--verify` read healthy for max(3*TICK,300) before failing. Clamped, and the
        # sleep itself guarded as the belt: a scheduler must never die between two passes.
        try:
            time.sleep(max(5, min(TICK, 86400)))
        except Exception as exc:  # noqa: BLE001 — the loop must outlive its own pause
            report_bookkeeping_failure(exc)
    try:
        os.unlink(pidfile)
    except OSError:
        pass
    release_loop_lock()
    return 0


def spawn_loop():
    """Start the box's loop. Returns (pid, started) — `started` False when a verified holder on this
    box already had it, so callers do not print "loop started" over a loop they did not start.
    """
    log_path = os.path.join(STATE, "loop.log")
    os.makedirs(STATE, exist_ok=True)
    # ⛔ IF THIS BOX ALREADY HAS A SCHEDULER, THE TRUTH IS "STARTED" — not a spawn we then wait on.
    # Without this, the child we are about to spawn correctly refuses the box lock (#2890), the poll
    # below times out, and `--install`/`--start` report "the scheduler loop did not come up" over a
    # box whose schedule is running fine under another state dir — a false FAIL, and the shape that
    # bricks a cell's bring-up (#3029). The holder is IDENTITY-verified (pid + start time + command
    # line) by `loop_holder()`, so this is not the blind pidfile adoption the comment below forbids.
    holder = loop_holder()
    if holder is not None:
        # ⛔ NEUTRAL WORDING ON PURPOSE: the holder may be THIS state dir's own loop (its pidfile
        # went missing, a documented state). Saying "this state dir starts none" there was a false
        # report to the operator, and `cmd_start` had already been told the truth by its own check.
        print("loop already running (%s)" % describe_holder(holder))
        return holder[0], False
    with open(log_path, "a") as out:
        # ⛔ THE CHILD RESOLVES ITS OWN PATHS — SO A RELATIVE KNOB MUST BE HANDED OVER RESOLVED.
        # `subprocess` runs the loop with `cwd="/"`, so every relative path in the inherited
        # environment means a DIFFERENT path in the child than it did here. `FLEET_SCHEDULE_LOCK_ROOT`
        # is the mutex's NAME: created against the caller's cwd by this process and against `/` by the
        # child, the two resolve `relock` to two different directories, the child cannot create
        # `/relock` and degrades to `$STATE/loop.lock`, and BOTH homes then hold "the box" — #2890
        # reproduced while both verbs print `SCHEDULE VERIFIED` (measured by the reviewer, and by
        # case 19v: with the pin `FLEET_SCHEDULE_LOCK_ROOT=relock`, a second home started a second
        # loop on the same box). Making the root absolute in `resolve_loop_lock` is NOT sufficient —
        # that fixes this process's reading of the variable, not the one the child reads back out of
        # the environment. So the resolved directory is passed explicitly, and `FLEET_SCHEDULE_TMPFS_ROOT`
        # is dropped so it cannot re-derive a relative root on top of it.
        # ⛔ EVERY NORMALIZED PATH KNOB, NOT JUST THE LOCK ROOT. The same reasoning applies to any
        # path this process made absolute: the child inherits the RAW environment and re-resolves it
        # against `cwd="/"`. A relative `FLEET_SCHEDULE_STATE` left the child writing `/relstate` (a
        # `PermissionError` that surfaced as "the loop did not come up"; as root it created the dir
        # instead, so the child ran over a state dir the parent never reads and `--stop` set an OFF
        # switch the child never observed), and a relative `TEMPLATES_DIR` loaded a different job set
        # than the inline pass and `--verify` had just certified.
        # ⛔ AND `INFRA_ROOT` IS THE FOURTH KNOB, not an exception to that rule. It is `abspath`-ed
        # in `resolve_infra_root`, the child re-derives it from the RAW environment against
        # `cwd="/"`, and `placeholder_values()` renders it as `{{AGENT_INFRA_PATH}}` into five
        # shipped templates (ai-drainer, ai-multi-repo, controller-watchdog, objective-reminder,
        # worker-supply). A relative `INFRA_ROOT` therefore rendered a DIFFERENT checkout in the
        # child than in the parent's inline pass: with none of the child's own fallbacks a checkout,
        # the placeholder rendered EMPTY, `render()` classified those five jobs as a named SKIP, and
        # the loop ran ZERO of them while `--install` printed `SCHEDULE VERIFIED` — the same false
        # PASS as a relative `TEMPLATES_DIR`, one knob over (measured by the #3636 reviewer, who
        # watched the parent's marker carry the caller's path and the child's carry another).
        # ⛔ AND `INFRA_ROOT` IS NOT THE LAST ONE EITHER. The rest of the cwd-sensitive set —
        # `TORTOISE_REPO`, `SWARM_ROOT`, `CELL_HOME`, `SWARM_ENV_FILE`, and the path-valued
        # `PYTHON_BIN`/`PI_NODE_BIN` — is NOT listed here because `absolutize_path_knobs()` has
        # already rewritten `os.environ` in the parent, so `os.environ.copy()` below carries them
        # RESOLVED. A previous cut claimed in this comment that `SWARM_ROOT`/`TORTOISE_REPO` "cannot
        # diverge because neither is abspath-ed anywhere" — that was FALSE (`placeholder_values()`
        # does `os.path.isdir()`/`os.access()`/`open()` on them, which is cwd-relative) and the claim
        # itself was the trap: a reviewer measured `--install` printing `SCHEDULE VERIFIED` over a
        # loop that skipped its tortoise jobs. Keep the handover list and the absolutise list in sync
        # — or better, add knobs to `absolutize_path_knobs()` and leave this block alone.
        child_env = os.environ.copy()
        child_env["FLEET_SCHEDULE_STATE"] = STATE
        if TEMPLATES_DIR:
            child_env["TEMPLATES_DIR"] = TEMPLATES_DIR
        if LOOP_LOCK_ROOT:
            child_env["FLEET_SCHEDULE_LOCK_ROOT"] = LOOP_LOCK_ROOT
        if INFRA_ROOT:
            child_env["INFRA_ROOT"] = INFRA_ROOT
        child_env.pop("FLEET_SCHEDULE_TMPFS_ROOT", None)
        child = subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), "--loop"],
            stdout=out,
            stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL,
            cwd="/",
            env=child_env,
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
    # ⛔ THE CHILD'S OWN PID, so the timeout branch can tell "the box was already scheduled by someone
    # else" from "the loop I just started is the holder, it just had not ticked yet". Returning
    # `started=False` for our own child made `--start` print "this state dir starts none" one line
    # after it started one, and (because `--start` records the declaration set only when it started
    # something) left the box with NO recorded set — after which the supervisor's bare-env revival
    # exits 3 and only warns, and a second home grades its own declarations against the holder's
    # stamps (#3029). Measured by the [VGATE] pass with the declaration read slowed past the poll.
    child_pid = child.pid
    for _ in range(50):
        time.sleep(0.2)
        pid = loop_pid()
        if pid and pid_is_our_loop(pid):
            age = tick_age()
            # 1 s of slack: the tick is stamped with this process's clock, and a tick older than
            # the spawn instant belongs to the incarnation that came before.
            if age is not None and age <= (time.time() - spawned_at) + 1.0:
                return pid, True
    # The child may have lost a race for the box lock to a THIRD scheduler that appeared since the
    # pre-check above. Report that holder rather than "did not come up": the box IS scheduled.
    holder = loop_holder()
    if holder is not None:
        if holder[0] == child_pid:
            # OUR OWN CHILD: it claimed the box and simply had not stamped its first tick when the
            # poll expired. It is started; nothing else started it.
            return holder[0], True
        print(
            "loop already running (%s) — one loop per box, so this state dir starts none (#2890)"
            % describe_holder(holder)
        )
        return holder[0], False
    return None, False


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


def declarations_unresolvable() -> bool:
    """True for the "no declarations at all" state of the CONTRACT — a STATE, not a broken set.

    ⛔ WHY THIS IS A FUNCTION AND NOT TWO EXPRESSIONS. `--check` is documented as exit 3 for "no
    declarations at all" and 1 for a set this runtime cannot run. Both platform arms classified
    that state differently: the darwin arm tested `isdir` and answered 3, while the linux arm fell
    into a blanket `except ScheduleError -> 1`. So `TEMPLATES_DIR=/nonexistent --check` exited 1 on
    the platform that runs the cells and 3 on the platform that authors the templates — one tree,
    two verdicts, and 1 is the code `cloud-cell-supervisor.sh` treats as FATAL rather than as "this
    cell was never installed". `--start` already answers 3 for exactly this state
    (`cmd_start`'s `except ScheduleError`), and `docs/ops/fleet-schedule.md` documents 3 for it, so
    the linux `--check` arm was the one contradicting the file's own contract.
    """
    return not TEMPLATES_DIR or not os.path.isdir(TEMPLATES_DIR)


def print_table(jobs, now):
    for job in jobs:
        if job.error:
            print("  ERROR  %-38s %-18s %s" % (job.label, "-", job.error))
            continue
        if job.skip:
            # `job.skip` can be a NAME, not a reason (an unresolved placeholder), and a skipped job
            # with a non-numeric calendar value made `job.cadence` raise here — outside the guard
            # below — and blank the whole table.
            try:
                cadence = job.cadence
            except Exception:  # noqa: BLE001 — one bad row must not blank the table
                cadence = "?"
            print("  SKIP   %-38s %-18s %s" % (job.label, cadence, job.skip))
            continue
        # ⛔ ONE BAD FILE MUST NOT BLANK THE TABLE. A stamp that is not an object, a missing or
        # non-numeric `started`, or a calendar value that is not a number used to raise straight
        # out of this loop, so `--status` — the truth table the docs point operators at, and the
        # surface they reach right after `--verify` says a hand-edit broke something — printed NO
        # rows at all. That is the same "aborts for every job after it" defect fixed in --verify.
        try:
            cadence = job.cadence          # itself raises on a non-numeric calendar value
            stamp = read_stamp(job.label)
            last = fmt_age(now - stamp["started"]) if stamp else "never"
            rc = "" if not stamp else " rc=%s" % stamp.get("rc")
            at = due_at(job, stamp, now)
            nxt = fmt_until(None if at is None else at - now)
        except Exception as exc:  # noqa: BLE001 — one bad stamp is one table row
            # ⛔ NOT job.cadence here: for a non-numeric calendar value THAT is what just raised,
            # so re-evaluating it inside the handler raised again and blanked the table anyway.
            print("  BROKEN %-38s %-18s unusable stamp/calendar (%s: %s) — clear: rm -f %s"
                  % (job.label, "-", type(exc).__name__, exc, stamp_path(job.label)))
            continue
        print(
            "  ok     %-38s %-18s last=%-11s%s next=%s  log=%s"
            % (job.label, cadence, last, rc, nxt, job.log_path())
        )


def staged_copy_report() -> tuple:
    """(kind, detail) — is the file THIS process runs the checkout's own copy?

    `kind` is one of:
      "checkout"    — this IS a checkout's copy (or another worktree of one): nothing is staged
      "same"        — a staged copy, byte-identical to the checkout's
      "differs"     — a staged copy that is NOT the checkout's: a landing has not reached here
      "no-checkout" — a staged copy, but no checkout could be resolved to compare it with

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

    ⛔ "I COULD NOT COMPARE" IS ITS OWN ANSWER, never a silent clean one. This used to return ""
    for both "no drift" and "no checkout to compare against", so `--verify` printed
    `SCHEDULE VERIFIED` with its staged-copy arm never having run — the no-op-gate shape, over the
    one check that exists to stop a cell certifying a build it is not running. The read-error arm
    already failed; the no-checkout arm was silence. `kind` makes the two answerable apart, and
    the polarity is the caller's: `--check` reports only `differs`, `--verify` fails on `differs`
    and NAMES `no-checkout` beside its verdict.
    """
    me = os.path.abspath(__file__)
    if not INFRA_ROOT:
        return "no-checkout", "no checkout could be resolved (INFRA_ROOT / AGENT_INFRA_PATH unset)"
    root = os.path.abspath(INFRA_ROOT)
    checkout_copy = os.path.join(root, "scripts", "fleet-schedule.py")
    if me == checkout_copy or me.startswith(root + os.sep):
        return "checkout", me  # this IS a checkout's copy (or another worktree of one)
    if not os.path.isfile(checkout_copy):
        # A checkout that predates this file ships no scheduler to compare against.
        return "no-checkout", "no checkout copy at %s" % checkout_copy
    try:
        with open(me, "rb") as a, open(checkout_copy, "rb") as b:
            same = a.read() == b.read()
    except OSError as exc:
        return "no-checkout", "the staged scheduler could not be read (%s)" % exc
    if same:
        return "same", me
    return "differs", (
        "the STAGED scheduler differs from the checkout: %s is not %s — this cell runs the staged "
        "copy, so a fix landed in the checkout has NOT reached it. Refresh the farm: "
        "bash %s/pi-bootstrap/cell-install.sh --install" % (me, checkout_copy, root)
    )


def staged_copy_drift() -> str:
    """The `differs` message only — what `--check` reports as a non-fatal DRIFT line."""
    kind, detail = staged_copy_report()
    return detail if kind == "differs" else ""


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
    # ⛔ THE DECLARATION GATE IS THE ONLY VERB THAT REFUSES A RETIRED/TEMPLATE CONTRADICTION
    # (#2908). Both statements are in the repo, so this is where it is caught and where CI can
    # hold an author to it; every machine verb honours the manifest instead, so a stale line can
    # never cost a cell its whole scheduled layer.
    jobs = load_jobs(check_targets=False, strict_declarations=True)
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
    global STATE, TEMPLATES_DIR
    # ⛔ ONE LOOP PER BOX MEANS ONE STATE DIR CARRIES THE BOX'S EVIDENCE (#2890). When this box's
    # lock is held by a loop over ANOTHER state dir, the honest question is not "does THIS dir have a
    # loop" (it must not) but "is the loop that does have it working". So this verification is
    # conducted against the HOLDER's state dir — its pidfile, its tick, its per-job stamps, its
    # zero-live rule.
    # ⛔ SKIPPING THOSE ARMS INSTEAD IS A FALSE PASS, and an earlier cut did exactly that: it printed
    # a friendly `SCHEDULE VERIFIED` for a holder whose tick was 3 hours old, which
    # `cloud-cell-bringup.sh` turns into `CELL READY` on a cell with no reaping and no liveness
    # detection — the #1864 false PASS, disabled on every two-home box (cell-4 measured five state
    # dirs). Reproduced by the [VGATE] pass with the holder stopped: the holder's own `--verify`
    # failed `the loop tick is 10800s old` while the second home's `--verify` said VERIFIED.
    # Rebinding rather than forking the checks keeps ONE code path, so a new arm added later is
    # graded for a two-home box for free.
    # `STATE` is NOT restored: every caller returns straight out of the process from here.
    # ⛔ AND THE DECLARATION SET IS REBOUND WITH IT, BEFORE IT IS READ. Stamps are read from the
    # HOLDER's state dir, so grading the CALLER's declarations against them reported `NEVER RUN` for
    # a job no loop on this box was ever asked to run — a false FAIL that `cloud-cell-bringup.sh`
    # turns into `die on any FAIL line`, i.e. the #3029 shape this change exists to remove, re-opened
    # one branch over (measured by the reviewer: two homes, one extra plist in the verifying home's
    # set, `rc=1` from both `--install` and `--verify`). The holder remembers its own templates dir,
    # so the verdict is taken over the set the box actually runs — and the caller's extra
    # declarations are NAMED rather than dropped, because a job declared in this home and run by no
    # loop anywhere IS a real gap, just not one this verb can fix.
    holder = loop_holder()
    caller_templates = TEMPLATES_DIR
    if holder is not None and holder[2] and not same_state_dir(holder[2], STATE):
        print(
            "  NOTE   this box's scheduler runs under a DIFFERENT state dir (%s) — one loop per box "
            "(#2890), so the checks below grade THAT loop's evidence, not this state dir's"
            % describe_holder(holder),
            flush=True,
        )
        STATE = holder[2]
        holder_templates = ""
        try:
            with open(os.path.join(STATE, TEMPLATES_POINTER)) as fh:
                holder_templates = fh.read().strip()
        except OSError:
            holder_templates = ""
        # ⛔ ABSOLUTE IS PART OF "KNOWN". A holder's pointer is a path in the HOLDER's context; a
        # RELATIVE one (what the pre-fix writer produced) would be resolved against THIS process's
        # cwd, so `isdir` and the grade below would silently use whatever same-named directory the
        # verifier happens to stand in — measured: a decoy `tpl19ag` in the verifier's cwd made
        # `--verify` claim "its DECLARATION set … (%s)" about a set the holder never reads and then
        # `FAIL … NEVER RUN` over a healthy box (and a decoy SUBSET is the mirror: a job the holder
        # never ran goes ungraded). `os.path.abspath` is NOT the fix for the same reason; the honest
        # answer is the UNKNOWN branch below.
        if not (holder_templates and os.path.isabs(holder_templates)
                and os.path.isdir(holder_templates)):
            # ⛔ AN UNKNOWN SET IS NOT SILENCE, AND "absent" IS NOT THE ONLY WAY TO NOT KNOW IT.
            # A pointer naming a DELETED checkout is just as unknown as a missing pointer, and the
            # first cut only disclosed the missing one — so a dangling pointer silently graded the
            # caller's set and produced `FAIL … NEVER RUN` for a job that had nothing to do with the
            # problem. Either way the caller's set is what gets graded below, and that fact is SAID.
            print(
                "  NOTE   the holder's declaration set is UNKNOWN (%s/templates-dir %s), so THIS "
                "state dir's declarations are graded against the holder's stamps — a job declared "
                "here and never run there will read NEVER RUN"
                % (STATE, "is missing or unreadable" if not holder_templates
                   else ("names a RELATIVE path (%s), which this process cannot resolve for the "
                         "holder" % holder_templates if not os.path.isabs(holder_templates)
                         else "names %s, which is not a directory" % holder_templates)),
                file=sys.stderr,
            )
        if holder_templates and os.path.isabs(holder_templates) and os.path.isdir(holder_templates):
            TEMPLATES_DIR = holder_templates
            if not same_state_dir(holder_templates, caller_templates):
                print(
                    "  NOTE   and its DECLARATION set, which is the set that actually runs here "
                    "(%s) — this state dir's set is not graded" % holder_templates,
                    flush=True,
                )
    jobs = load_jobs()
    failures = []
    now = time.time()
    if not same_state_dir(TEMPLATES_DIR, caller_templates):
        # Best-effort and bounded: name the caller's own declarations that no loop on this box runs.
        # Wrapped because a broken caller-side set must never turn a box-level verdict into a crash,
        # and the graded set is restored afterwards so nothing below reads the transient one (this
        # block is a diagnostic, never a gate — the arms below grade the HOLDER's set).
        extra = []
        graded_templates = TEMPLATES_DIR
        try:
            graded = {job.label for job in jobs}
            TEMPLATES_DIR = caller_templates
            # ⛔ A NAMED SKIP IS NOT A DIVERGENCE. Every other reader of this runtime treats a
            # declaration whose placeholders cannot resolve on THIS host as a `SKIP … for a named
            # reason` — `--check` prints `DECLARATIONS OK` over it and the graded loop below
            # `continue`s past it. Counting one as "a declaration no loop on this box runs" turned
            # the documented non-fatal state into a `^  FAIL`, which `cloud-cell-bringup.sh` `die`s
            # on: two homes whose checkouts are version-skewed (the operator's vs a cell's farmed
            # copy, which lags by design) plus any shipped template that is a SKIP on a box without
            # swarm/tortoise env bricked bring-up — the #3029 shape this change exists to close.
            extra = [job.label for job in load_jobs() if job.label not in graded and not job.skip]
        except Exception as exc:  # noqa: BLE001 — a diagnostic must never fail the verdict
            # ⛔ "VANISHED WITHOUT A WORD" IS THE FAILURE MODE case 19x NAMES. A caller-side set
            # that cannot be read means the divergence could not be computed at all; swallowing that
            # silently would report a clean verdict over an ungraded comparison.
            print(
                "  NOTE   this state dir's declaration set (%s) could not be read (%s: %s), so the "
                "jobs it declares were NOT compared with the holder's"
                % (caller_templates, type(exc).__name__, exc),
                file=sys.stderr,
            )
            extra = []
        finally:
            TEMPLATES_DIR = graded_templates
        if extra:
            # ⛔ A FAILURE, NOT A NOTE — and the previous cut got this wrong in the other direction.
            # The NOTE read as "informational", but `cloud-cell-bringup.sh` certifies a cell on
            # rc=0 + `SCHEDULE VERIFIED` and dies only on a `^ *FAIL` line, so a declaration this
            # home installs and NO loop on the box runs was certified CELL READY while the job ran
            # nowhere: trading the old false FAIL for a false PASS is the one trade the A/B rule
            # forbids (fail-open). The wording names the cause and the two ways out, because the
            # condition is a genuine misconfiguration — the box's scheduler runs a different set.
            failures.append(
                "%d declaration(s) in %s are run by NO loop on this box: %s%s — the box's scheduler "
                "runs %s, so nothing here will ever run them; install from the holder's state dir "
                "or point both at the same declarations"
                % (len(extra), caller_templates, ", ".join(extra[:5]),
                   " …" if len(extra) > 5 else "", TEMPLATES_DIR)
            )
    # ⛔ A STAGED COPY THAT IS NOT THE CHECKOUT IS A FAILURE HERE, not a note: a cell runs
    # $CELL_HOME/.pi/agent/scripts/fleet-schedule.py, so when it differs from the checkout this cell
    # was installed from, the layer being certified is not the layer in the repo — the state in
    # which a landing is invisible on every running cell (measured 2026-10-27). See
    # staged_copy_report(). Never raised by --check, where a Mac's farmed copy legitimately lags.
    drift_kind, drift_detail = staged_copy_report()
    if drift_kind == "differs":
        failures.append(drift_detail)
    elif drift_kind == "no-checkout":
        # ⛔ NOT A FAILURE, BUT NOT SILENCE EITHER. A cell started without INFRA_ROOT cannot be
        # compared with the checkout it was installed from (and a Mac legitimately has no checkout
        # at that path at all). Reporting a plain VERIFIED over an arm that never ran is the no-op
        # gate this repo refuses, so the arm is NAMED beside the verdict: the reader can tell
        # "compared and clean" from "could not compare".
        print(
            "  NOTE   the staged scheduler could not be compared with a checkout (%s) — set "
            "INFRA_ROOT/AGENT_INFRA_PATH to have this arm actually graded" % drift_detail,
            file=sys.stderr,
        )

    pid = loop_pid()
    if pid and not pid_is_our_loop(pid):
        # ⛔ A STALE-BUT-ALIVE PID IN *loop.pid* IS NOT THE LOOP, AND THE BOX LOCK OUTRANKS IT.
        # `loop_pid()` answers "is that pid alive", so once the pid was recycled onto an unrelated
        # process the refusal below fired over a box whose scheduler was passing — including when the
        # recycled pid sits in the HOLDER's own dir, which `cmd_loop` itself documents as reachable
        # ("the previous pidfile, if any, was left intact" when a pidfile write fails). The box lock
        # is identity-verified (pid + command line + start time), so it settles the question the
        # pidfile cannot.
        # ⛔ NOT A BLANKET RESCUE: with no verified holder this arm changes nothing, so the existing
        # refusal for a dead scheduler behind a stale pid still fires (case 4b pins it).
        holder_pid = loop_holder()
        if holder_pid is not None and same_state_dir(holder_pid[2], STATE):
            pid = holder_pid[0]
    if not pid:
        # ⛔ A HOLDER OVER *THIS* STATE DIR WHOSE PIDFILE WENT MISSING IS NOT A DEAD SCHEDULER —
        # liveness and identity are proven by the box lock, and failing here would refuse a box that
        # is passing. (A holder over ANOTHER state dir was already handled by the rebinding above, so
        # it never reaches this arm — including when THIS dir's stale `loop.pid` holds a recycled
        # pid, which used to make a correctly-scheduled box fail to bring up.)
        holder_pid = loop_holder()
        if holder_pid is not None and same_state_dir(holder_pid[2], STATE):
            pid = holder_pid[0]
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
        # ⛔ A STAMP THAT IS NOT AN OBJECT IS NOT EVIDENCE EITHER. `stamp.get("rc")` below used to
        # inherit whatever `json.load` returned, so a stamp a foreign writer left as `[1, 2, 3]`
        # raised AttributeError out of `--verify` — the surface whose whole job is to DIAGNOSE bad
        # state — and aborted the check for every job after it.
        if stamp and not isinstance(stamp, dict):
            failures.append(
                "%s: its last-run stamp is not a job record (%s) — a foreign or partial writer "
                "broke it; clear: rm -f %s"
                % (job.label, type(stamp).__name__, stamp_path(job.label))
            )
            continue
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
        # ⛔ A `started` WE CANNOT COMPARE IS NOT A LIVE JOB EITHER. This arm used to do
        # `stamp["started"] > now` unguarded, so a stamp a hand-edit or a foreign writer left as a
        # string raised TypeError out of --verify — the surface whose whole job is to DIAGNOSE the
        # unusable stamp that the loop now skips. Report it as the failure it is.
        started = stamp.get("started")
        # ⛔ isfinite, not just isinstance: `json.load` parses NaN/Infinity happily, NaN satisfies
        # isinstance(int,float), and EVERY comparison against NaN is False — so a NaN `started`
        # passed the type check, made `due_at` permanently not-due with no exception for the loop's
        # per-job guard to catch, and `--verify` then certified the job `SCHEDULE VERIFIED` (rc=0)
        # with zero runs and an empty log. Measured. ±Infinity dies further down in human_secs().
        # ⛔ `_finite`, not `math.isfinite`: a `started` of 10**400 (an int, so the type check
        # passes) raised OverflowError out of `math.isfinite` ITSELF — from this arm, whose comment
        # says it exists so that `--verify` reports a stamp it cannot compare instead of raising.
        # Caught by fresh-context review at #3340 and pinned by 18g's big-int arm.
        if not _finite(started):
            failures.append(
                "%s: its last-run stamp has no usable 'started' value (%r) — a hand-edit or a "
                "foreign writer broke it, so its due-ness cannot be trusted; clear: rm -f %s"
                % (job.label, started, stamp_path(job.label))
            )
            continue
        if started > now + max(3 * TICK, 300):
            failures.append(
                "%s: its last-run stamp is IN THE FUTURE (%s from now) — the clock stepped back "
                "or the state dir was restored from a skewed box, so the job reads as not-due for "
                "ever while a stamp makes it look live; clear: rm -f %s"
                % (job.label, human_secs(started - now), stamp_path(job.label))
            )
            continue
        try:
            due = due_at(job, stamp, now)
        except (TypeError, ValueError, OverflowError, OSError) as exc:
            # ⛔ The same untrusted values `load_jobs` accepts (it validates a calendar's SHAPE, not
            # its values) reach `next_occurrence`'s `int(calendar["Hour"])` here. Unguarded that
            # raised ValueError out of `--verify`, aborting the check for every job after it — the
            # diagnostic surface could not name the defect it exists to name. OSError belongs in the
            # tuple too: a hugely negative `started` reaches `datetime.fromtimestamp(-1e18)`, which
            # raises OSError (errno 75) on this platform rather than ValueError.
            failures.append(
                "%s: its calendar has an unusable value (%s: %s) — `is_due` cannot evaluate it, "
                "so the job never becomes due"
                % (job.label, type(exc).__name__, exc)
            )
            continue
        ran += 1
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
    # ⛔ `pid` IS PROVABLY NOT None HERE. The foreign-holder case does NOT return early any more: it
    # REBINDS `STATE` to the holder's dir at the top of this function and is graded inline by every
    # arm below (that is what closed the false PASS). So this line is reachable only after the
    # liveness arms above passed, which requires a real pid. That is deliberate: an earlier cut formatted `pid` with `%d` while the
    # foreign-holder arm could leave it None, so `--install`/`--verify` died with
    # `TypeError: %d format: a real number is required` on exactly the two-home box the arm exists to
    # un-brick (#3029) — reproduced by the [VGATE] pass. Keeping the failure and this line
    # structurally disjoint is the fix; a formatting guard would only hide the next such arm.
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

    # ⛔ THE DECLARATION POINTER IS LOAD-BEARING NOW (`cmd_verify` reads it and grades THAT set), so it
    # may only be written by an invocation that is the effective OWNER of this state dir's pointer — and
    # the rule is "no loop OF THIS STATE DIR is already running", NOT "spawn_loop started one". Gating on
    # `started` was a REGRESSION: on the cell-bringup shape (a second state dir installing while another
    # holds the BOX lock) `spawn_loop` returns the foreign holder with started=False, so nothing wrote the
    # pointer — and the pointer is the only thing `cloud-cell-supervisor.sh`'s bare-env revival
    # (`HOME=$CELL_HOME CELL_HOME=$CELL_HOME … --start`, no INFRA_ROOT/TEMPLATES_DIR) has to find the
    # declarations. Measured: `FAIL: no job declarations found` rc=3 there, which the supervisor logs as a
    # WARN, so a cell that bring-up had just certified ran with no reap, no liveness detection and no
    # canary. The base wrote it here unconditionally (single call site) and returned rc=0 in that shape.
    # ⛔ AND IT MUST NOT BE OVERWRITTEN WHEN THIS STATE DIR'S OWN LOOP IS ALREADY RUNNING: that loop keeps
    # reading its own set, so recording the caller's would make a later `--verify` grade a set nothing runs
    # and print "the set that actually runs here" over a misdescription (measured: pointer tplA -> tplB
    # while `loop.log` still start-named tplA — the 19al arm).
    # ⛔ THE OWNER TEST IS THE BOX LOCK'S, NOT THE PIDFILE'S — and getting this wrong re-opened the
    # 19al defect one precondition over. `loop.pid` is ABSENT in states this file documents as
    # reachable (`cmd_loop` leaves the previous pidfile alone when its own write fails; 19ad removes
    # it), and it names a RECYCLED pid in another (#3029's shape, #6 in this change). On either, a
    # `loop_pid()`-only test reads "no loop here" over a loop that IS running, so `remember_templates_
    # dir()` overwrote the pointer with the CALLER's set: the live loop kept reading tplA while the
    # pointer said tplB, so `--verify` then graded a set nothing runs and printed `SCHEDULE VERIFIED`
    # over it — the identical failure 19al pins, moved one precondition over (measured with a real
    # loop + `rm loop.pid`: `--install TEMPLATES_DIR=tplB` rewrote the pointer, `loop.log` still named
    # tplA, `--verify` certified it). Every OTHER "is this state dir's loop running" decision in this
    # file — `cmd_verify`, `cmd_start` — already reads the identity-verified BOX lock; this one did
    # not, and `loop_holder()` was called ten lines LATER (for the inline-pass check) and never for
    # this. So it is read once, HERE, and both decisions use it.
    # ⛔ BOTH SIGNALS, UNIONED — neither alone is sufficient. The box lock is empty when the lock root
    # is unusable (the degraded `$STATE/loop.lock` arm), and the pidfile is missing or recycled in the
    # states above; a loop is running if EITHER says so, and only "neither" may write the pointer.
    holder = loop_holder()
    own_via_lock = bool(holder is not None and same_state_dir(holder[2], STATE))
    own_pid = loop_pid()
    own_via_pid = bool(own_pid and pid_is_our_loop(own_pid))
    own_alive = own_via_lock or own_via_pid
    foreign_holder = None
    if holder is not None and not same_state_dir(holder[2], STATE):
        foreign_holder = holder
    if own_alive:
        if not os.path.exists(os.path.join(STATE, TEMPLATES_POINTER)):
            # ⛔ NAME IT INSTEAD OF GUESSING A SET. Writing the caller's here could certify a set the
            # loop does not read; writing nothing leaves the next bare-env `--start` with no pointer. The
            # state is answerable by the operator, so it is SAID rather than resolved by a coin flip.
            print(
                "  NOTE   a loop for this state dir is running but no declaration set is recorded in "
                "%s — a later `--start` from an environment without INFRA_ROOT/TEMPLATES_DIR will not "
                "find the declarations; record it with: %s --install from the loop's own environment"
                % (STATE, os.path.basename(sys.argv[0])),
                file=sys.stderr,
            )
    else:
        try:
            remember_templates_dir()
        except OSError as exc:
            # A state dir we cannot write the pointer into must not fail an install; it degrades a later
            # bare-env `--start` on this home, so it is SAID.
            print(
                "  NOTE   could not record the declaration set in %s (%s) — a later `--start` from an "
                "environment without INFRA_ROOT/TEMPLATES_DIR will not find the declarations"
                % (STATE, exc),
                file=sys.stderr,
            )

    # The first pass is run INLINE, before the loop exists, so that `--install` ends with EVIDENCE
    # (a stamp and a log line per runnable job) rather than with a pid. "A unit that loads and
    # never runs is precisely this issue" — this is the half that proves it ran. On a re-run the
    # jobs are not due, so this costs nothing.
    now = time.time()
    # ⛔ THE DUE-NESS READ IS UNTRUSTED INPUT AND IT MUST NOT ABORT THE INSTALL EITHER. The guard
    # below wraps ONE job's RUN; this line decides WHICH jobs run, and it reads the same two
    # unguarded surfaces the loop's per-job guard was added for (`read_stamp` → a hand-edited
    # stamp, `is_due`/`due_at` → `float(last)`, `int(calendar["Hour"])`). Measured at this head
    # with a stamp of `{"started": "yesterday"}`: `ValueError: could not convert string to float`
    # escaped `main()`, `--install` returned 1 with NO `loop.pid`, and the cell was left with no
    # scheduler — the identical closed feedback loop as the ENOSPC death, reintroduced one line
    # above the guard that exists to prevent it. Per-job and NAMED, exactly as the loop does it:
    # one unusable stamp skips that job and the rest of the set still installs and runs.
    # ⛔ THE INLINE FIRST PASS IS THE BOX-LEVEL JOB SET, so it needs the SAME box-holder check the
    # loop takes — and it must come BEFORE the pass, not after it. `--install` is the verb bring-up
    # runs, and on a two-home box it used to execute the due jobs inline while another home's loop
    # ran the same jobs beside it (measured by the [VGATE] pass: one job, two runs, one box), which
    # is exactly the invariant this change claims to establish. Skipping the pass here is not a
    # weaker proof: the holder IS the proof that this box's job set runs, and `cmd_verify` below
    # still grades this state dir's stamps.
    # ⛔ `holder` / `foreign_holder` are read ONCE, ABOVE the pointer decision — that read IS the
    # identity-verified box lock, and the pointer write must be decided on the same signal that the
    # inline-pass skip is (a second read here would let the two disagree on a claim published between
    # them).
    first = []
    for j in ([] if foreign_holder is not None else jobs):
        if j.skip or j.error:
            continue
        try:
            due = is_due(j, read_stamp(j.label), now)
        except Exception as exc:  # noqa: BLE001 — one unusable stamp must not abort the install
            log("ERROR %s due-ness unusable (%s: %s) — skipping it in the inline first pass"
                % (j.label, type(exc).__name__, exc))
            print("  %-38s ERROR due-ness unusable (%s: %s) — skipped"
                  % (j.label, type(exc).__name__, exc))
            continue
        if due:
            first.append(j)
    if foreign_holder is not None:
        print(
            "loop already running (%s) — one loop per box, so the inline first pass is SKIPPED: "
            "that loop is the proof this box's job set runs (#2890)"
            % describe_holder(foreign_holder)
        )
    elif first:
        print("running the %d due job(s) now (the first pass IS the proof):" % len(first))
    for job in first:
        # ⛔ THIS PASS IS UNGUARDED ELSEWHERE AND IT MUST NOT BE ABLE TO ABORT `--install`.
        # `--install` is what `cloud-cell-bringup.sh` runs (and `die`s on non-zero), and its LAST
        # act is `spawn_loop()` — so an exception here means the cell ends up with NO scheduler and
        # nothing to retry: the 2026-10-30 closed feedback loop, reintroduced on the install path.
        # Measured on a real unwritable locks dir: a raw PermissionError traceback out of main(),
        # the remaining due jobs never run, `--verify` never runs, `loop.pid` absent, `loop.log`
        # empty. The loop's own pass has wrapped `run_job` this way since #1864; the inline one had
        # not. Same treatment: name the cause, keep going, still reach spawn_loop.
        try:
            rc = run_job(job)
        except Exception as exc:  # noqa: BLE001 — one job must not abort the install
            log("ERROR %s could not be run by the inline first pass (%s: %s) — continuing"
                % (job.label, type(exc).__name__, exc))
            print("  %-38s ERROR (%s: %s)  log=%s"
                  % (job.label, type(exc).__name__, exc, job.log_path()))
            continue
        print("  %-38s rc=%s  log=%s" % (job.label, "held" if rc is None else rc, job.log_path()))

    pid = loop_pid()
    if pid and pid_is_our_loop(pid):
        print("loop already running (pid %d)" % pid)
    else:
        pid, started = spawn_loop()
        if not pid:
            print("FAIL: the scheduler loop did not come up (see %s/loop.log)" % STATE, file=sys.stderr)
            return 1
        # ⛔ "loop started" IS A CLAIM ABOUT AN ACT. When the box's lock is held by another state
        # dir, `spawn_loop` returns that holder's pid and started NOTHING — printing "loop started
        # (pid N)" there reported a pid this verb never created, one line after the honest "a second
        # delivery path could be beside it" message. Found by the [VGATE] pass.
        if started:
            print("loop started (pid %d, tick %ds)" % (pid, TICK))
    return cmd_verify()


def cmd_start():
    pid = loop_pid()
    if pid and pid_is_our_loop(pid):
        # ⛔ THE OFF SWITCH IS CLEARED EVEN HERE. `--start` is the revival verb (#1864) and an OFF
        # set while the loop was still alive outlived it: the loop exited at its next check and the
        # box went dark while `--start` — the one verb an operator reaches for — answered 0 and
        # changed nothing (measured by the reviewer: `OFF still present? YES`, loop gone one tick
        # later, `--verify` then `NOT RUNNING` with nothing left to revive it). The own-state holder
        # with a MISSING pidfile already falls through to the clear below; this is the same ruling
        # for the same state, not a new one. A FOREIGN holder still changes nothing (next arm).
        off = os.path.join(STATE, "OFF")
        if os.path.exists(off):
            os.unlink(off)
            print("loop already running (pid %d) — OFF switch cleared" % pid)
        else:
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
    # ⛔ THE BOX'S HOLDER IS CHECKED BEFORE THE OFF SWITCH IS CLEARED. Clearing it first was the
    # worse half of the same defect: on a box scheduled under another state dir this verb starts
    # nothing, but it would still delete an operator's deliberate OFF. A start that started nothing
    # must not change anything.
    # ⛔ ONLY a holder in ANOTHER state dir may short-circuit. A holder over THIS state dir is our
    # own loop, whose pidfile went missing (a documented state), and returning early there left the
    # operator's OFF switch in place: the loop then exited at its next check and the box had no
    # scheduler — while `--start`, the revival verb, answered 0. So an own-state holder falls
    # THROUGH: the OFF is cleared (the operator said "on"), and `spawn_loop` refuses to add a second
    # loop because it sees the same verified holder.
    holder = loop_holder()
    if holder is not None and not same_state_dir(holder[2], STATE):
        print(
            "loop already running (%s) — one loop per box, so this state dir starts none (#2890)"
            % describe_holder(holder)
        )
        # ⛔ A LIVE HOLDER IS NOT NECESSARILY A PASSING ONE, AND THIS VERB CANNOT REVIVE IT. A frozen
        # loop (`SIGSTOP`ped by a lane, a debugger, a stopped container) still owns the box lock, so
        # this starts nothing and the tick goes stale — `--verify` will refuse (19s), but the operator
        # standing here needs to know WHICH home can act, because `--stop` does not consult the box
        # lock and must be run from the holder's own state dir.
        print(
            "        if that loop is not making progress, stop it from ITS OWN state dir: "
            "FLEET_SCHEDULE_STATE=%s %s --stop" % (holder[2], os.path.basename(sys.argv[0]))
        )
        return 0
    off = os.path.join(STATE, "OFF")
    if os.path.exists(off):
        os.unlink(off)  # --start is the operator saying "on"; the OFF switch is cleared on purpose
    pid, started = spawn_loop()
    # ⛔ RECORDED ONLY WHEN THIS VERB ACTUALLY STARTED THE LOOP. The pointer says "this is the set
    # the box's loop runs", so writing it from a `--start` that started NOTHING is a lie that the
    # next grade acts on: on the documented "own-state loop alive, pidfile missing" state this verb
    # falls through and `spawn_loop` returns the existing holder, so a caller with a different
    # `TEMPLATES_DIR` used to overwrite the pointer with ITS set — after which the very home that
    # verified clean returned `FAIL … NEVER RUN` for a job its loop has never heard of. That is the
    # #3029 false FAIL this write exists to remove, injected by the write itself.
    # (`--install` writes it because its inline pass IS the proof the set ran.)
    if started:
        try:
            remember_templates_dir()
        except OSError as exc:
            # A state dir we cannot write the pointer into must not block the revival (`--start` is
            # what brings a dark cell back); it degrades a later second-home grade, so it is SAID.
            print(
                "  NOTE   could not record the declaration set in %s (%s) — a scheduler for another "
                "state dir on this box will grade ITS OWN declarations against this loop's stamps"
                % (STATE, exc),
                file=sys.stderr,
            )
    if not pid:
        print("FAIL: the scheduler loop did not come up (see %s/loop.log)" % STATE, file=sys.stderr)
        return 1
    if started:
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
    # ⛔ ABSOLUTE, because the state dir's SPELLING is compared against the box lock's record
    # (`same_state_dir`): a relative `FLEET_SCHEDULE_STATE` would resolve against the CALLER's cwd,
    # so the same dir spelled relatively and absolutely would read as two — a false "another state
    # dir holds the box". A no-op for the shipped absolute defaults and for a pinned absolute value.
    STATE = os.path.abspath(os.environ.get("FLEET_SCHEDULE_STATE") or os.path.join(
        os.environ.get("CELL_HOME") or os.environ.get("HOME", ""),
        ".pi",
        "agent",
        "state",
        "fleet-schedule",
    ))
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
    # ⛔ ABSOLUTE, AND NORMALISED *AFTER* THE POINTER READ, NOT BEFORE IT. This value is handed to the
    # loop child, which runs with `cwd="/"`. A RELATIVE `TEMPLATES_DIR=tpl` left the child reading
    # `/tpl`, so `--start` printed "loop started" while the child logged `template dir not found` on
    # every tick and ran ZERO jobs — and `cloud-cell-supervisor.sh` keys on the exit code, so it
    # reported a scheduled layer on a cell that runs nothing. Normalising before the pointer fallback
    # missed the POINTER-sourced value (a pointer written by any earlier run from a relative env, which
    # `remember_templates_dir()` then keeps re-writing), so the same false PASS survived one path over
    # — and `cmd_verify`'s holder-set check would resolve it against whichever cwd the caller had.
    if TEMPLATES_DIR:
        TEMPLATES_DIR = os.path.abspath(TEMPLATES_DIR)
    # ⛔ AND THE SAME RULE FOR EVERY OTHER CWD-SENSITIVE KNOB, in one place rather than one per fix (see
    # `absolutize_path_knobs`): the child re-reads these against `cwd="/"`, so a relative value rendered
    # a different argv there — `TORTOISE_REPO=tortoise` measured as a `SCHEDULE VERIFIED` over a loop
    # that skipped its tortoise jobs entirely. Called BEFORE anything renders or spawns.
    absolutize_path_knobs()
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
                # The SAME predicate as the linux arm below, so the two platforms cannot disagree
                # about one state — see declarations_unresolvable().
                return 3 if declarations_unresolvable() else 1
        if not INFRA_ROOT:
            print("FAIL: no agent-infra checkout found (set INFRA_ROOT or AGENT_INFRA_PATH)", file=sys.stderr)
            return 1
        return cmd_darwin(mode)

    # The BOX's loop mutex (#2890), resolved ONLY on the platform that has a loop and ONLY for the
    # verbs that can reach one. `--loop` needs it before its first write; `--start`/`--install`/
    # `--verify` must answer "is this box already scheduled" with the SAME path the loop claims
    # with. Resolution creates nothing and never raises — a degraded root is disclosed there, and
    # `--status`/`--check` stay silent because they never touch the lock.
    if mode in ("--loop", "--start", "--install", "--verify"):
        resolve_loop_lock()

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
        # ⛔ `--check` IS THE PRE-MERGE GATE, so its codes are a cross-platform contract: 3 for the
        # "no declarations at all" state (nothing to grade here — the benign never-installed box a
        # caller must not read as fatal) and 1 for a set that IS here and cannot be run. A
        # nonexistent TEMPLATES_DIR is the former on BOTH platforms now; it used to be 3 on darwin
        # and 1 here. Other verbs keep the blanket 1: `--start` classifies this state itself (3),
        # and `--install`/`--verify` have no caller keying on 3.
        if mode == "--check" and declarations_unresolvable():
            return 3
        return 1
    except Exception as exc:  # noqa: BLE001 — a declaration set that cannot be read is NAMED
        # ⛔ THE LAST NET, AND IT IS DELIBERATE. `load_jobs` parses UNTRUSTED files (plistlib gives
        # back whatever shape the file holds) and the parse sites are many; a shape nobody
        # anticipated must still be a NAMED refusal on stderr rather than a traceback out of every
        # verb — `--install`/`--start` are how a cell gets its ONLY scheduler back, and a traceback
        # there is the same "no scheduler, nothing to retry" state this change exists to close.
        # The specific shapes are named by file where they are known (see `load_jobs`); this arm
        # only guarantees no verb dies without saying what broke.
        # ⛔ IT MUST NOT CLAIM THE DECLARATIONS FAILED WHEN THEY DID NOT. Measured with an
        # unwritable STATE dir (the EACCES/ENOSPC case this change exists for): the blanket arm
        # reported "cannot read the job declarations (PermissionError: .../state/templates-dir)"
        # when the failing surface was `remember_templates_dir()` — pointing the operator at the
        # wrong subsystem on the recovery path that matters most. A ScheduleError already NAMES its
        # own file, so only a non-declaration failure needs different wording; both still exit 1,
        # so nothing reads this as a success.
        # (No `isinstance(exc, ScheduleError)` arm here: the `except ScheduleError` above already
        # consumes those, so it could only ever be dead code that LOOKS like a live distinction.)
        print("FAIL: %s: %s: %s" % (mode, type(exc).__name__, exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
