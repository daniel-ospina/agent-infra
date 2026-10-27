#!/usr/bin/env python3
"""runner_autoscale.test.py — the converger's acceptance suite, with paired mutations.

WHAT THIS PINS
--------------
`runner_autoscale.py` existed only as a live copy on a cell until 2026-10-27, so every rule in it was
learned from a live failure and NONE of them had a test. This suite is the part that makes those
rules stay true. One case per measured failure, and each case lands with the fix it pins — the list
below grows with the suite, so this header never claims a case that does not exist yet:

  1. THE LABEL FLOOR (agent-infra#2589). `resolve_labels` granted `ubuntu-latest` only when some
     runner ALREADY had it — a condition it would itself create. A pool-wide restart strips it
     everywhere, every workflow asks `runs-on: ubuntu-latest`, and CI stops assigning work while
     every runner reads `online` (measured 2026-10-27: 9 runners / 8 online / `busy=0` / 53 runs
     queued; the API add took the pool to `busy 8/8` in 20 s and it evaporated again 8/8 → 0/9 in
     ~20 min). So a label set is never written that would leave the repo at ZERO — and the floor is
     a UNION over what the runner already carries, because a DEAD runner still in the pool has
     labels to keep (T3: the pre-fix `preserved or resolve_labels(...)` never reached the floor on
     the one path that runs after every restart).
     Cases: T1 (floor binds ⇒ granted, said once, `--json` intact), T2 (gate engaged ⇒ unchanged,
     never written twice, and NOT baked in when the floor is satisfiable), T3 (DEAD re-registration
     ⇒ floor unions over the preserved custom label).

  2. THE REPAIR PATH THAT COULD NOT REPAIR (measured on cell 4). A runner whose registration was
     deleted server-side ("Failed to create a session. The runner registration has been deleted from
     the server") gets `--replace`, and `config.sh` answers "Cannot configure the runner because it
     is already configured. To reconfigure the runner, run './config.sh remove' first." — because the
     tool never cleared the LOCAL `.runner`/`.credentials`. The one case the repair exists for was
     the one it could not recover, on every pass, for ever.
     Cases: T4 (a `config.sh` that refuses "already configured" once then succeeds ⇒ the local config
     was CLEARED before the first attempt and the runner ends REGISTERED), T5 (a repair that FAILS
     restores the install — `.runner` back so `discover()` still finds it, and the credential pair
     still 0600, because `.credentials_rsaparams` is the RSA private key — plus a clear that fails
     PARTWAY restoring what it already took), T6 (a RAISE between the clear and the rc check, i.e. a
     failed token mint, must restore too: two review rounds found that hole and its two
     privilege-widening companions, and every one of them is a mutation here).
  3. AN UNREADABLE POOL AFTER A RESTART THE PASS ISSUED (measured on cell 4). Verdict
     `action-failed` / `unverified_cause=pool-read-after-restart`, log line "restart succeeded but the
     pool could not be READ" — and no reason. Failing closed is right; concluding `Unmeasurable` from
     ONE transient read, and not saying WHY, is not — the read races a restart this pass just issued.
     Cases: T7 (a transient failure is retried a BOUNDED number of times, then `unmeasurable`, and the
     message CONTAINS gh's own words), T8 (a DETERMINISTIC 404 — the unit had no `--repo`, so the call
     was `repos//actions/runners` — is NOT retried and its text survives).
  4. THE STARVATION INVARIANT (agent-infra#2875). `queued_runs > 0 ∧ busy_runners == 0 ∧
     online_runners > 0` is starvation, not demand, and nothing watched it; measured 2026-10-27 it was
     misread twice in one night, first as "capacity" and then as "review cost", costing the merge
     window. Implemented HERE, as the issue asks, instead of as a separate healer.
     Cases: T9 (it fires: verdict `starvation`, exit 4, the counts and the invariant named, and
     nothing changed), T9b (CONFIRMED across two samples, so a handover blip is not an alarm),
     T10 (the three near-misses stay silent — busy pool, empty queue, ALL-OFFLINE).
  7. THE FOUR REVIEW-ROUND-7 FINDINGS (measured on the rebased branch, one case each).
     T26 — the alarm's gate excluded `problem_kind`, so a pass whose PROVISIONER REFUSED never read
     the queue, and the refusal leg returns **exit 0**: reproduced with 1 runner online and idle and
     53 queued, `verdict=provisioner-refused`, rc=0, no `starvation` key. The alarm now runs and owns
     that verdict, and the refusal keeps its place in `notes`.
     T27 — `--check-units` read only `WorkingDirectory`, so a unit whose `ExecStart` names a file a
     reclaim takes (the checkout `render_unit` pins into `__file__`) audited as "all usable" while it
     died on every tick. The audit reads `ExecStart` too — with systemd's OWN semantics, which two
     review rounds had to correct: `ExecStart` ACCUMULATES for `Type=oneshot` and only an EMPTY
     `ExecStart=` resets it (so a drop-in that ADDS a command is not the remedy and the finding must
     survive it), a BARE program name is legitimate (systemd's compile-time search path) and an
     executable prefix (`@ - : + ! !!`) is not part of the path, and a unit systemd SKIPS by
     `Condition…=` never runs its program, so its absence is not a pending failure. Getting those
     wrong is not pedantry: the first version reported 39 of a stock box's own systemd units on
     every pass — an audit nobody could clear — and the second read only the LAST `ExecStart=`, which
     reproduced the very false PASS the check exists to close.
     T4b — the retire commit removed the only pin on `register(replace=False)` while the branch had
     changed that arm to clear-and-retry. Clearing and re-running `config.sh` WITHOUT `--replace`
     creates a SECOND registration and leaves a ghost, so the heal is confined to `replace=True` and
     this case pins the refusal, the single attempt, and a byte-identical install.
     The counts are also published machine-readably (`queued_runs`, `starvation_queued/busy/online`) —
     `queued_runs` is `origin/main`'s own field name, so a fleet reader of that record keeps working.

  9. THE LANE'S OWN REVIEW CYCLE (2026-10-27, second round). Nine defects, each measured before it
     was fixed, each with a case AND a paired mutation here.
     T33/T34 — the starvation alarm's SECOND HALF. The invariant alone is the NORMAL state of the
     fallback-only ruling (measured: `queued=14` sustained while the pool was idle), so the alarm
     also requires ELIGIBILITY: the pool advertises the fallback, or the gate wants `local` (the
     #2875 stripped-label shape), or the queue is at/above the gate's own threshold. The counts and
     `starvation_why` are published on BOTH verdicts, so the evidence outlives the alarm.
     T35 — a DISABLED schedule is not a schedule: a commented-out cron line, a `.disabled`/`.bak`
     unit file and a MASKED unit all read as "the gate runs here", which turns a stale hand-run
     `local` record into a standing decision that arms the fallback for ever.
     T36 — `discover()` used `Path.exists()`, so one uninspectable install raised through the pass
     AFTER a repair may have acted (exit 2, no `actions`), and `glob` read an unreadable root as
     EMPTY (which registers duplicates). Both now go through `_inspect_path`.
     T37 — repair identity is the INSTALL, not the agent NAME: two installs sharing a name (a
     `cp -a`) had the first repaired twice, the second never, and a self-deleting registration.
     T38 — a `df` failure MID-PASS now records `unverified`/`unverified_cause`, like the same
     failure at pass start, instead of falling through to `under-target` (exit 0).
     T39 — a provisioner that reports success and installs NOTHING is `action-failed` (exit 3), not
     `under-target` (exit 0): an enforcer that failed to grow must not exit green.
     T40 — the moved-pin diagnostic NAMES the pinned value (and the seam) instead of a literal
     filename plus advice to set a variable that is already set.
     T41 — a PARTIAL `du` (rc≠0, totals printed) is still a measurement, so it can only TIGHTEN the
     budget; discarding it fell back to an allowance LOOSER than a >8 GB install.
     T42 — an ABSENT gate record is absence ("nothing writes one here — a cell"), not a read fault.

⛔ EVERY MUTATION HAS A CONTROL. `--mutations` first runs each paired case against the SHIPPED module
and requires it GREEN; a case that is red on its own (order dependence, a host fact) makes its
mutants report `CONTROL RED` and fails the run, because a red case scores CAUGHT for every mutant
while proving nothing.

⛔ HERMETIC, BY CONSTRUCTION. Every measurement is a fixture: `meminfo` is a file, the installs are
directories, and `gh` / `systemctl` / `config.sh` / the provisioner are STUBS on the seams the tool
already declares. No network, no root, no live cell, no real runner, no `ps`, no `du`, no `df`. A
case that needs a value the tool would measure from the kernel supplies it through the tool's own
seam — never by editing the tool.

⛔ NON-VACUITY IS EXECUTED, NOT ASSERTED. `--mutations` re-runs this suite against a MUTATED copy of
the tool (written to a temp dir; the shipped file is never edited) and requires the PAIRED case to go
RED. A mutation whose case still passes is printed as `NOT RED` and fails the run: a test that cannot
catch its own defect is decoration. `--mutations` also runs the plain suite first, so it cannot
report a green set it never observed.

USAGE
  python3.12 scripts/orchestrator-harness/runner_autoscale.test.py
  python3.12 scripts/orchestrator-harness/runner_autoscale.test.py --mutations

Injected, never guessed:
  RUNNER_AUTOSCALE_MODULE     the module under test (default: ./runner_autoscale.py)
  RUNNER_AUTOSCALE_TEST_ONLY  run ONE case by id (used by the mutation runner)
"""

from __future__ import annotations

import datetime
import importlib.util
import inspect
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
MODULE_PATH = os.path.normpath(os.path.join(HERE, "runner_autoscale.py"))
# The module the CLI assertions drive. It is the MUTATED copy under `--mutations`, so a CLI-level
# assertion has the same teeth as an in-process one.
MODULE_UNDER_TEST = os.environ.get("RUNNER_AUTOSCALE_MODULE") or MODULE_PATH

# Python 3.12 is the tool's own floor (it refuses to run below it), so the suite cannot be a
# 3.9-compatible script and pretend otherwise.
if sys.version_info < (3, 12):
    sys.exit(f"runner_autoscale.test.py requires Python >= 3.12 (got {sys.version.split()[0]})")

# ⛔ NO __pycache__ IN THE CHECKOUT. Loading the module under test by path would write one next to
# the shipped file, and a suite that dirties the tree it is checking is a suite that reddens a
# clean-tree gate — measured in review round 2.
sys.dont_write_bytecode = True


def _load_module():
    path = os.environ.get("RUNNER_AUTOSCALE_MODULE") or MODULE_PATH
    spec = importlib.util.spec_from_file_location("runner_autoscale_under_test", path)
    mod = importlib.util.module_from_spec(spec)
    # Register BEFORE exec: `@dataclass` resolves string annotations through
    # sys.modules[cls.__module__], and a file-loaded module is otherwise absent there.
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


ra = _load_module()

# ⛔ THE ACCOUNT HOME IS A FIXTURE, PINNED BEFORE ANY CASE RUNS (review finding P2, measured).
# `unit_workdir_problem(None)` and `render_unit` resolve the home, and the suite's own tempdirs live
# under `/tmp` — a TRANSIENT root the tool correctly refuses. So a case that used the ambient HOME
# measured the box, not the template: measured on a cell (`HOME=/tmp/cell-home`) six cases went red
# about a CORRECT template, and a red plain suite stops `--mutations` before it runs, i.e. the
# non-vacuity evidence was unavailable exactly where the tool runs. The seam is pinned at import so
# the cases that drive the audit WITHOUT a Box (T22/T23) get the same answer as the rest.
def durable_home() -> str:
    """A path that is NOT under a transient root. The suite cannot create one portably (`tempfile`
    lives under /tmp), so it uses a stable system directory that exists on both the Mac and the
    ubuntu runner. Nothing is written to it — the tool only STATs it."""
    for cand in ("/usr/local", "/usr", "/opt", "/var"):
        if os.path.isdir(cand) and not ra.transient_path_problem(cand):
            return cand
    raise Failure("no durable directory to use as a fixture home on this box")


os.environ["RUNNER_AUTOSCALE_HOME"] = os.environ.get(
    "RUNNER_AUTOSCALE_TEST_HOME"
) or durable_home()

# ── tiny test runner (a script, not a pytest module: the repo's zero-dep suites look like this) ──
TESTS = []


def test(case_id):
    def deco(fn):
        TESTS.append((case_id, fn))
        return fn

    return deco


class Failure(AssertionError):
    pass


def check(cond, msg):
    if not cond:
        raise Failure(msg)


def _force_rmtree(path: str) -> None:
    """Remove a tree, REPAIRING permissions as it goes — never a silent false success.

    `shutil.rmtree(..., ignore_errors=True)` reported success while leaving the tree (see
    `Box.destroy`), and a retry hook cannot be written against `rmtree`'s own callbacks: `os.open`,
    `os.scandir`, `os.unlink` and `os.rmdir` all arrive at the SAME `onexc`, so `func(path)` is not
    even callable for two of them (measured: `TypeError: open() missing required argument 'flags'`).
    So the tree is made reachable FIRST — directories TOP-DOWN, which is what lets the walk descend
    into a mode-000 parent — and then removed with `rmtree`'s errors LEFT ON, so a second failure is
    loud rather than absorbed.
    """
    for base, dirs, _files in os.walk(path, topdown=True, onerror=lambda _exc: None):
        for name in dirs:
            try:
                os.chmod(os.path.join(base, name), 0o700)
            except OSError:
                pass
    try:
        shutil.rmtree(path)
    except OSError as exc:
        print(f"   ! could not remove fixture path {path}: {exc}", file=sys.stderr)


def contains(haystack, needle, what):
    if needle not in haystack:
        raise Failure(f"{what} does not contain {needle!r}\n--- got ---\n{haystack}")


# ── the fixture ────────────────────────────────────────────────────────────────────────────────
# One fixture is one BOX: its installs, its pool, its memory, its listeners, and stub binaries for
# everything the tool would otherwise run. Built as files so every measurement is attributable.
GH_STUB = r"""#!/usr/bin/env bash
# The tool's ONLY door to GitHub. Records every call (so a test can count RETRIES) and answers from
# fixture files. Modes are per-endpoint so a test can make ONE read fail and leave the rest healthy.
set -u
FIX="__FIX__"
printf '%s\n' "$*" >> "$FIX/gh-calls.log"
args="$*"
is() { case "$args" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

if is /registration-token; then
  # A mint that FAILS is the routine transient the repair path must survive: `registration_token()`
  # raises, and it does so AFTER the local config has been cleared.
  #
  # ⛔ `token.advisory` makes a SUCCESSFUL mint write an advisory to STDERR while the token still
  # goes to STDOUT — the `gh` shape that turned the token into `gh: warning: …` when the two streams
  # were merged (review finding P2, round 12). `token.stdout` replaces stdout entirely, so a case can
  # print a token AND a second line and require the guard to refuse it.
  [ -f "$FIX/token.advisory" ] && echo "gh: warning: this token expires in 1 hour" >&2
  [ -f "$FIX/token.fail" ] && { echo "gh: HTTP 401: Bad credentials (fixture)" >&2; exit 1; }
  if [ -f "$FIX/token.stdout" ]; then cat "$FIX/token.stdout"; else printf 'tok-fixture\n'; fi
  exit 0
fi
if is 'per_page=100'; then
  # THE QUEUE'S OLDEST WAITING RUN (the AGE term, round 11). MUST be tested before the depth branch
  # below, whose pattern is a SUBSTRING of this URL.
  #
  # ⛔ THE STUB IS AN ORACLE ON THE API, NOT ON THE CODE'S QUERY STRING (round-13 review finding P1).
  # It used to branch on `direction=asc` and answer with the oldest row — a spelling the endpoint
  # IGNORES (unknown query parameters are dropped, not refused), so the real API stayed NEWEST-FIRST
  # and the stub certified the shape the CODE assumed instead of the answer the API gives. T44 passed
  # over a reader that reported the NEWEST run's age, which is ~0 on a queue that is still receiving
  # work — the one direction this bound cannot afford, on the very shape #2875 measured.
  # It now answers the PAGE honestly: a `min(...)` query gets `queue-age` (the oldest row), a
  # `.workflow_runs[0]` query gets `queue-age-newest` (the newest, which is what row 0 really is), and
  # the two are separate fixtures — so reading row 0 as "the oldest" is falsifiable, and T44 is the
  # case that falsifies it.
  # `queue-age-empty` makes the page carry NO readable `created_at` while `total_count` says work is
  # queued (a run whose `created_at` is null); `queue-age-raw` makes it UNPARSABLE. Both are refusals
  # the reader must produce, not answers it may rescue.
  if [ -f "$FIX/queue-age-empty" ]; then
    oldest=""
  elif [ -f "$FIX/queue-age-raw" ]; then
    oldest="$(cat "$FIX/queue-age-raw")"
  else
    oldest="$(cat "$FIX/queue-age" 2>/dev/null)"
    [ -n "$oldest" ] || oldest="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi
  newest="$(cat "$FIX/queue-age-newest" 2>/dev/null)"
  [ -n "$newest" ] || newest="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # `queue-age-total` overrides `.total_count`: a queue DEEPER than the read page, whose min is only
  # a LOWER BOUND on the head and must be REFUSED rather than certified (see `Box.queue_age_overflow`).
  age_total="$(cat "$FIX/queue-age-total" 2>/dev/null)"
  [ -n "$age_total" ] || age_total=1
  case "$args" in
    *min*) printf '%s\t%s\n' "$age_total" "$oldest" ;;
    *)     printf '%s\t%s\n' "$age_total" "$newest" ;;
  esac
  exit 0
fi
if is 'actions/runs?status=queued'; then
  # `--jq .total_count` — the queue depth. An absent fixture file is an ERROR, never a zero.
  # `queued.seq` is a newline list consumed one per call (last repeats), so a case can make the
  # SECOND sample of the same pass disagree with the first — which is what CONFIRMATION means.
  [ -f "$FIX/queued" ] || [ -f "$FIX/queued.seq" ] || { echo "gh: no queued fixture" >&2; exit 1; }
  if [ -f "$FIX/queued.seq" ]; then
    qn=0; [ -f "$FIX/queued.count" ] && qn="$(cat "$FIX/queued.count")"
    total=$(wc -l < "$FIX/queued.seq" | tr -d ' ')
    pick=$(( qn + 1 )); [ "$pick" -gt "$total" ] && pick="$total"
    printf '%s\n' "$(( qn + 1 ))" > "$FIX/queued.count"
    sed -n "${pick}p" "$FIX/queued.seq"
  else
    cat "$FIX/queued"
  fi
  exit 0
fi
if is 'actions/runners'; then
  # POOL READ. `pool.seq` is a newline list of steps consumed one per call (last step repeats):
  #   ok            → print the pool fixture
  #   err:<stderr>  → exit 1 with that stderr (the transport's own words)
  #   empty         → exit 0 with no rows
  n=0
  [ -f "$FIX/pool.count" ] && n="$(cat "$FIX/pool.count")"
  step="ok"
  if [ -f "$FIX/pool.seq" ]; then
    total=$(wc -l < "$FIX/pool.seq" | tr -d ' ')
    pick=$(( n + 1 )); [ "$pick" -gt "$total" ] && pick="$total"
    step="$(sed -n "${pick}p" "$FIX/pool.seq")"
  fi
  printf '%s\n' "$(( n + 1 ))" > "$FIX/pool.count"
  case "$step" in
    ok)    cat "$FIX/pool.tsv"; exit 0 ;;
    swap)  cat "$FIX/pool2.tsv"; exit 0 ;;
    empty) exit 0 ;;
    err:*) echo "${step#err:}" >&2; exit 1 ;;
    *)     echo "gh: unknown pool step '$step'" >&2; exit 9 ;;
  esac
fi
# Anything else (label POSTs and friends) is recorded and succeeds.
printf 'fixture-ok\n'
exit 0
"""

SYSTEMCTL_STUB = r"""#!/usr/bin/env bash
printf '%s\n' "$*" >> "__FIX__/systemctl-calls.log"
# A `systemctl restart` that FAILS is a routine transient on a loaded box (bus/dbus unavailable,
# manager busy), and the repair path must not read it as "the runner is offline" (round 11).
if [ -f "__FIX__/systemctl.rc" ]; then exit "$(cat "__FIX__/systemctl.rc")"; fi
exit 0
"""

CONFIG_STUB = r"""#!/usr/bin/env bash
# The runner's own `config.sh`. `refusals` (a number) makes the first N calls answer with the
# MEASURED server-side refusal; `local_state` records whether the local config was present at call
# time, which is exactly what fix 2 has to change.
FIX="__FIX__"
n=0
[ -f "$FIX/config.count" ] && n="$(cat "$FIX/config.count")"
n=$(( n + 1 )); printf '%s\n' "$n" > "$FIX/config.count"
{
  printf 'call %s argv=%s\n' "$n" "$*"
  if [ -f "__DIR__/.runner" ]; then printf 'call %s local_runner=present\n' "$n"
  else printf 'call %s local_runner=absent\n' "$n"; fi
} >> "$FIX/config-calls.log"
refuse="$(cat "$FIX/config.refusals" 2>/dev/null || echo 0)"
if [ "$n" -le "$refuse" ]; then
  cat >&2 <<'ERR'
Cannot configure the runner because it is already configured. To reconfigure the runner, run
'./config.sh remove' first.
ERR
  exit 1
fi
printf '{"agentName":"__AGENT__","gitHubUrl":"https://github.com/%s","workFolder":"_work"}\n' \
  "${CONFIG_REPO:-daniel-ospina/tortoise}" > "__DIR__/.runner"
printf 'ok\n'
exit 0
"""

PROVISIONER_STUB = r"""#!/usr/bin/env bash
# `install-ci-runner-x64.sh`'s contract: 0 = did it, 2 = ITS OWN GUARD REFUSED, anything else = fail.
FIX="__FIX__"
printf '%s\n' "$*" >> "$FIX/provisioner-calls.log"
[ -f "$FIX/provisioner.rc" ] && rc="$(cat "$FIX/provisioner.rc")" || rc=0
[ -f "$FIX/provisioner.out" ] && cat "$FIX/provisioner.out" >&2
exit "$rc"
"""


class Box:
    """One fixture box. Seams are set on the PROCESS env because that is how the tool reads them."""

    def __init__(self, name: str):
        self.dir = tempfile.mkdtemp(prefix=f"runnerauto-{name}-")
        self.root = os.path.join(self.dir, "root")
        os.makedirs(os.path.join(self.root), exist_ok=True)
        self.installs: dict[str, str] = {}
        os.makedirs(os.path.join(self.dir, "state"), exist_ok=True)
        os.makedirs(os.path.join(self.dir, "bin"), exist_ok=True)
        os.makedirs(os.path.join(self.dir, "units"), exist_ok=True)
        os.makedirs(os.path.join(self.dir, "home"), exist_ok=True)
        self.disk(500_000)
        self.footprint({})
        self._write(os.path.join(self.dir, "gh"), GH_STUB.replace("__FIX__", self.dir), 0o755)
        self._write(
            os.path.join(self.dir, "systemctl"), SYSTEMCTL_STUB.replace("__FIX__", self.dir), 0o755
        )
        self._write(
            os.path.join(self.dir, "provisioner.sh"),
            PROVISIONER_STUB.replace("__FIX__", self.dir),
            0o755,
        )
        self.meminfo(7_500_000)
        self.alive([])
        self.busy([])
        self.pool([])
        self.env = {
            "RUNNER_AUTOSCALE_RUNNER_ROOT": self.root,
            "RUNNER_AUTOSCALE_MEMINFO": os.path.join(self.dir, "meminfo"),
            "RUNNER_AUTOSCALE_NPROC": "8",
            "RUNNER_AUTOSCALE_MACHINE": "x86_64",
            "RUNNER_AUTOSCALE_ALIVE_DIRS": os.path.join(self.dir, "alive.txt"),
            "RUNNER_AUTOSCALE_BUSY_DIRS": os.path.join(self.dir, "busy.txt"),
            "RUNNER_AUTOSCALE_STATE_DIR": os.path.join(self.dir, "state"),
            "RUNNER_AUTOSCALE_GH": os.path.join(self.dir, "gh"),
            "RUNNER_AUTOSCALE_SYSTEMCTL": os.path.join(self.dir, "systemctl"),
            "RUNNER_AUTOSCALE_PROVISIONER": os.path.join(self.dir, "provisioner.sh"),
            "RUNNER_AUTOSCALE_NO_SUDO": "1",
            # ⛔ the unit audit reads a FIXTURE directory, never the host's ~/.config or /etc: a suite
            # that reads the machine it runs on reports this box's units as if they were the case's.
            "RUNNER_AUTOSCALE_UNIT_DIR": os.path.join(self.dir, "units"),
            # ⛔ HOME IS A FIXTURE TOO (review finding P2, measured). `unit_workdir_problem(None)`
            # and `render_unit` resolve `ra.account_home()`, so six cases measured THE HOST'S HOME rather
            # than the template: on a cell (`HOME=/tmp/cell-home`) every one of them reported
            # "WorkingDirectory=… is inside /tmp" and the shard went RED — measured `PASS=23 FAIL=6`
            # — and because a red plain suite stops `--mutations` before it runs, the suite's
            # non-vacuity evidence was unavailable on exactly the boxes the tool exists for. CI's
            # `/home/runner` hid that, which made it worse: a real regression in those assertions
            # could be dismissed as "the known six". A stable, existing, non-transient fixture home
            # is what makes the HERMETIC claim in the header true.
            "HOME": os.path.join(self.dir, "home"),
            "RUNNER_AUTOSCALE_HOME": os.environ["RUNNER_AUTOSCALE_HOME"],
            # The gate's own recorded desired mode (`ci_runner_gate.sh:40`/`:395`). NOT created by
            # default: a box that does not run the gate has no such file, and the floor must not
            # invent one — `gate_state()` writes it in the cases that are ABOUT the handover.
            "RUNNER_AUTOSCALE_GATE_STATE": os.path.join(self.dir, "gate.state"),
            # ⛔ df/du are SEAMS, not the host: a case that read this machine's disk would size its
            # ceiling from whatever the developer's laptop has free. The default is a big, quiet disk
            # so the disk arm binds only in the cases that are ABOUT it.
            "RUNNER_AUTOSCALE_DF": os.path.join(self.dir, "df"),
            "RUNNER_AUTOSCALE_DU": os.path.join(self.dir, "du"),
            "RUNNER_AUTOSCALE_ONLINE_WAIT_S": "0",
            "RUNNER_AUTOSCALE_POLL_S": "0",
            "RUNNER_AUTOSCALE_POOL_READ_ATTEMPTS": "3",
            "RUNNER_AUTOSCALE_RETRY_BACKOFF_S": "0",
            # 1 ms: a positive value inside the seam's accepted range (0 is REFUSED — it would mean
            # "no confirmation"), so every case pays a millisecond instead of the production 30 s and
            # no case silently runs without a confirmation sample.
            "RUNNER_AUTOSCALE_STARVATION_CONFIRM_S": "0.001",
        }
        self.queued(0)  # a healthy box: the queue is readable and empty unless a case says otherwise

    # ── writing the fixture ──
    @staticmethod
    def _write(path, body, mode=0o644):
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(body)
        os.chmod(path, mode)

    def meminfo(self, available_kb: int):
        self._write(
            os.path.join(self.dir, "meminfo"),
            f"MemTotal:      16384000 kB\nMemFree:         400000 kB\n"
            f"MemAvailable:  {available_kb} kB\nBuffers:          1000 kB\n",
        )

    def alive(self, dirs):
        self._write(os.path.join(self.dir, "alive.txt"), "\n".join(dirs) + ("\n" if dirs else ""))

    def busy(self, dirs):
        self._write(os.path.join(self.dir, "busy.txt"), "\n".join(dirs) + ("\n" if dirs else ""))

    def install(self, dirname: str, name: str, repo="daniel-ospina/tortoise") -> str:
        """One runner install: the `.runner` config the runner itself writes, plus a `config.sh`."""
        path = os.path.join(self.root, dirname)
        os.makedirs(path, exist_ok=True)
        cfg = json.dumps(
            {"agentName": name, "gitHubUrl": f"https://github.com/{repo}", "workFolder": "_work"}
        )
        self._write(os.path.join(path, ".runner"), cfg)
        self._write(os.path.join(path, ".credentials"), "creds")
        self._write(os.path.join(path, ".credentials_rsaparams"), "params")
        self._write(
            os.path.join(path, "config.sh"),
            CONFIG_STUB.replace("__FIX__", self.dir)
            .replace("__DIR__", path)
            .replace("__AGENT__", name),
            0o755,
        )
        self.installs[dirname] = path
        return path

    def pool(self, entries):
        """entries: [(name, status, busy, [labels])] → the `gh api … --jq` TSV the tool parses."""
        rows = []
        for name, status, busy, labels in entries:
            rows.append(f"{name}\t{status}\t{'true' if busy else 'false'}\t{','.join(labels)}")
        self._write(os.path.join(self.dir, "pool.tsv"), "\n".join(rows) + ("\n" if rows else ""))

    def pool_seq(self, steps):
        """Per-CALL pool-read behaviour; the last step repeats. Every call is counted in gh-calls."""
        self._write(os.path.join(self.dir, "pool.seq"), "\n".join(steps) + "\n")

    def pool_then(self, entries):
        """A pool that CHANGES after the first read: `pool` for classification, `entries` afterwards.

        ⛔ The measurement that matters is a runner the pass judged OFFLINE at classification and the
        pool reports ONLINE seconds later — reconnection during the restart wait. A static fixture
        cannot express it, and `pool_seq`'s steps only name a BEHAVIOUR, not new CONTENT.
        """
        rows = [
            f"{name}\t{status}\t{'true' if busy else 'false'}\t{','.join(labels)}"
            for name, status, busy, labels in entries
        ]
        self._write(os.path.join(self.dir, "pool2.tsv"), "\n".join(rows) + ("\n" if rows else ""))
        self.pool_seq(["ok", "swap"])

    def systemctl_rc(self, rc: int):
        """Make the `systemctl` stub EXIT non-zero (a restart that failed to run)."""
        self._write(os.path.join(self.dir, "systemctl.rc"), f"{rc}\n")

    def gate_state(self, mode, *, scheduled=True):
        """The gate's last recorded decision + whether a job SCHEDULES the gate on this box.

        ⛔ BOTH, because a record alone is not a standing decision (review finding P1): the gate writes
        its mode only on TRANSITION, from a launchd job, and nothing schedules it on a cell — so a
        hand-run record must not arm the fallback for ever. `scheduled=False` is the fixture for that.
        """
        self._write(os.path.join(self.dir, "gate.state"), f"{mode}\n")
        self.env["RUNNER_AUTOSCALE_GATE_SCHEDULER"] = "1" if scheduled else "0"

    def queued(self, n):
        self._write(os.path.join(self.dir, "queued"), f"{n}\n")

    def queue_age(self, seconds: float):
        """The OLDEST queued run's `created_at`, `seconds` in the past — the queue-AGE term's input.

        ⛔ NOT A COUNT: the depth says work is waiting, the AGE says whether anyone is serving it, and
        the whole point of the round-11 finding is that a cell can measure the second and not the
        gate's intent. `None` removes the fixture, which the stub answers with "created now".
        """
        path = os.path.join(self.dir, "queue-age")
        if seconds is None:
            if os.path.exists(path):
                os.unlink(path)
            return
        stamp = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=seconds)
        self._write(path, stamp.strftime("%Y-%m-%dT%H:%M:%SZ") + "\n")

    def queue_age_newest(self, seconds: float):
        """The NEWEST queued run's `created_at` — what row 0 of the page ACTUALLY holds.

        ⛔ THIS FIXTURE EXISTS TO MAKE THE ORIGINAL DEFECT REPRODUCIBLE (round-13 review finding P1).
        The runs endpoint is newest-first and ignores `sort`/`direction`, so a reader of
        `workflow_runs[0]` gets the NEWEST run — ~0 s old on a queue that is still receiving work,
        which is precisely the starved shape #2875 measured. Left at its default, row 0 and `min()`
        agree, and a row-0 reader would look correct; a case sets this together with `queue_age()` to
        make the two readings DISAGREE, which is what falsifies the row-0 reading.
        """
        path = os.path.join(self.dir, "queue-age-newest")
        if seconds is None:
            if os.path.exists(path):
                os.unlink(path)
            return
        stamp = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=seconds)
        self._write(path, stamp.strftime("%Y-%m-%dT%H:%M:%SZ") + "\n")

    def queue_age_overflow(self, total: int):
        """Make the AGE read's page SATURATE: `total` queued runs against a `QUEUE_AGE_PAGE` page.

        `min()` over a saturated page is only a LOWER BOUND on the queue head, so it must be REFUSED
        rather than certified — the same rule `ci_runner_gate.sh:319-324` applies to the same read.
        """
        path = os.path.join(self.dir, "queue-age-total")
        if total is None:
            if os.path.exists(path):
                os.unlink(path)
            return
        self._write(path, f"{total}\n")

    def queue_age_empty(self, on: bool = True):
        """Make the age read answer with an EMPTY `created_at` while `total_count` still says work is
        queued — a run whose `created_at` is null, which is what makes `None` ("nothing is waiting")
        the WRONG answer. `on=False` removes the marker."""
        path = os.path.join(self.dir, "queue-age-empty")
        if on:
            self._write(path, "1\n")
        elif os.path.exists(path):
            os.unlink(path)

    def queue_age_raw(self, text):
        """The age read's `created_at` verbatim, so a case can make it UNPARSABLE. `None` removes it."""
        path = os.path.join(self.dir, "queue-age-raw")
        if text is None:
            if os.path.exists(path):
                os.unlink(path)
            return
        self._write(path, f"{text}\n")

    def unqueue(self):
        """Remove the queue fixture entirely: the depth read FAILS (the stub exits 1), as a scoped
        token or a broken unit would. An unreadable queue is the one input that can silence the
        alarm, so it gets its own case."""
        path = os.path.join(self.dir, "queued")
        if os.path.exists(path):
            os.unlink(path)

    def queued_seq(self, steps):
        """Per-CALL queue depth (the last step repeats) — the confirmation sample, driven."""
        self._write(os.path.join(self.dir, "queued.seq"), "\n".join(str(s) for s in steps) + "\n")

    def disk(self, free_mb: int):
        """The `df -Pm` the disk arm reads. Field 4 is Available, as `df -Pm` prints it."""
        self._write(
            os.path.join(self.dir, "df"),
            "#!/usr/bin/env bash\n"
            "printf 'Filesystem 1048576-blocks Used Available Capacity Mounted on\\n'\n"
            f"printf '/dev/fixture 999999 1 {free_mb} 1%% /\\n'\n",
            0o755,
        )

    def disk_seq(self, values: list[int]):
        """A `df` whose free space CHANGES between calls — the fill re-measures every step, so a box
        that fills up between the ceiling and the provision is a reachable state, not a fiction."""
        log = os.path.join(self.dir, "df.seq")
        with open(log, "w", encoding="utf-8") as fh:
            fh.write("\n".join(str(v) for v in values) + "\n")
        counter = os.path.join(self.dir, "df.count")
        self._write(
            os.path.join(self.dir, "df"),
            "#!/usr/bin/env bash\n"
            f"C={counter}\n"
            "n=0; [ -f \"$C\" ] && n=\"$(cat \"$C\")\"\n"
            "n=$(( n + 1 )); printf '%s\\n' \"$n\" > \"$C\"\n"
            f"v=$(sed -n \"${{n}}p\" {log})\n"
            f"[ -z \"$v\" ] && v=$(tail -1 {log})\n"
            "printf 'Filesystem 1048576-blocks Used Available Capacity Mounted on\\n'\n"
            "printf '/dev/fixture 999999 1 %s 1%% /\\n' \"$v\"\n",
            0o755,
        )

    def disk_spaced_source(self, free_mb: int, total_mb: int = 999_999):
        """A real `df -Pm` line whose SOURCE contains a space ("my big disk"), which shifts every
        later field right. `-P` guarantees the TAIL, not the head — this is the shape that made a
        25000 MB disk read as its 999999 MB total, i.e. the arm over-adding by 40x."""
        self._write(
            os.path.join(self.dir, "df"),
            "#!/usr/bin/env bash\n"
            "printf 'Filesystem 1048576-blocks Used Available Capacity Mounted on\\n'\n"
            f"printf 'my big disk {total_mb} 1 {free_mb} 1%% /\\n'\n",
            0o755,
        )

    def footprint(self, sizes: dict):
        """`du -sm` over the installs. `sizes` maps a directory NAME to its MB; anything unlisted
        reports the empty output a du that could not read the path would produce."""
        lines = "\n".join(f"{mb}\t__ROOT__/{name}" for name, mb in sizes.items())
        self._write(
            os.path.join(self.dir, "du"),
            "#!/usr/bin/env bash\n"
            f"printf '%s\\n' '{lines}' | sed \"s|__ROOT__|{self.root}|g\"\n",
            0o755,
        )

    def provisioner(self, rc=0, out=""):
        self._write(os.path.join(self.dir, "provisioner.rc"), f"{rc}\n")
        self._write(os.path.join(self.dir, "provisioner.out"), out)

    def refusals(self, n):
        """config.sh answers the MEASURED 'already configured' refusal for its first N calls."""
        self._write(os.path.join(self.dir, "config.refusals"), f"{n}\n")

    def token_fails(self, yes=True):
        """Make the registration-token mint fail (a 401): the raise lands AFTER the local clear."""
        path = os.path.join(self.dir, "token.fail")
        if yes:
            self._write(path, "1\n")
        elif os.path.exists(path):
            os.unlink(path)

    # ── reading the fixture ──
    def calls(self, log) -> list[str]:
        path = os.path.join(self.dir, log)
        if not os.path.exists(path):
            return []
        with open(path, encoding="utf-8") as fh:
            return [ln.rstrip("\n") for ln in fh if ln.strip()]

    def pool_reads(self) -> int:
        return sum(1 for line in self.calls("gh-calls.log") if "actions/runners" in line)

    def apply(self):
        os.environ.update(self.env)

    def destroy(self):
        """Remove the fixture — INCLUDING trees a case left unreadable.

        ⛔ `shutil.rmtree(..., ignore_errors=True)` REPORTED SUCCESS WHILE LEAVING THE TREE (review
        finding P2, round 12). A case that makes a directory mode-000 and does not restore it (T46)
        cannot be removed by an unprivileged `rmtree`, and `ignore_errors` turned that into a silent
        "cleaned up": one leaked `$TMPDIR/runnerauto-*` per run, each holding a `d---------`
        directory that an unprivileged `rm -rf` cannot remove either. That is a permanent disk leak
        on exactly the boxes whose disk budget this whole change exists to respect, and it also
        meant "`Box.destroy()` cleans up" was not verified by any case. The mode is repaired and the
        removal RETRIED, and a second failure is PRINTED rather than swallowed.
        """
        _force_rmtree(self.dir)


class Env:
    """Snapshot/restore os.environ so one case cannot leak a seam into the next."""

    def __init__(self):
        self.saved = dict(os.environ)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        os.environ.clear()
        os.environ.update(self.saved)
        return False


def _cli_env(box: Box) -> dict:
    """The seams a SHIPPED subprocess needs, as an OVERRIDABLE mapping.

    `dict(os.environ, **box.env)` cannot be narrowed afterwards — a seam the box already sets is a
    DUPLICATE keyword — so a case that must pin one seam differently (T1 pins nproc) builds on this.

    ⛔ `PYTHONDONTWRITEBYTECODE` IS PART OF THE CONTRACT, not a convenience (review finding P1, round
    12). `sys.dont_write_bytecode = True` at the top of this file is a PER-PROCESS flag, and T48's
    child runs a FRESH interpreter that imports the module under test by path: it wrote
    `scripts/orchestrator-harness/__pycache__/runner_autoscale.cpython-312.pyc` INTO THE CHECKOUT.
    `pin_dirty` does not tolerate that (only `.DS_Store`/`._*` are excused), so a GREEN suite run made
    `harness-exec.sh` refuse ("the pinned tree has UNCOMMITTED CHANGES") and `cloud-cell-supervisor
    check` die DRIFT on the cell that had just validated the tool — and the remedy both messages
    offer (commit or discard) cannot be applied to a gitignored file. The child inherits the flag.
    """
    return {**os.environ, **box.env, "PYTHONDONTWRITEBYTECODE": "1"}


def cli(box: Box, *args) -> tuple[int, str]:
    """Run the SHIPPED entry point with the fixture's seams — exit codes are a contract, and a
    verdict is not a substitute for one (`--want` refused, starvation alarm, unmeasurable)."""
    box.apply()
    proc = subprocess.run(
        [sys.executable, MODULE_UNDER_TEST, *args],
        env=_cli_env(box),
        capture_output=True,
        text=True,
    )
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


def converge(box: Box, **kw) -> dict:
    """Drive one pass against the fixture. `root` is passed EXPLICITLY, not inferred from the seam:
    the env seam is read by the CLI (`--root`), while `converge()` takes it as an argument — a
    suite that relied on the env here would silently measure `/opt` and prove nothing."""
    box.apply()
    ra._WORKER_CACHE.clear()
    kw.setdefault("root", box.root)
    return ra.converge(kw.pop("repo", "daniel-ospina/tortoise"), **kw)


# ── 1. THE LABEL FLOOR ─────────────────────────────────────────────────────────────────────────
@test("T1 label floor: no runner advertises ubuntu-latest ⇒ it is granted, once, and said out loud")
def t1_label_floor():
    with Env():
        box = Box("floor")
        try:
            # One install with a registration the pool cannot see (ORPHANED ⇒ labels are DERIVED),
            # and a pool in which NOTHING advertises the label every workflow asks for.
            box.install("gh-runner-x64", "r-orphan")
            box.pool([("r-other", "online", False, ["self-hosted", "self-hosted-x64", "Linux"])])
            box.alive([box.installs["gh-runner-x64"]])
            # The GATE wants the fallback: that is what makes this a floor rather than a second
            # opinion (`ci_runner_gate.sh` records it at `~/.pi/agent/state/ci-runner-gate.state`).
            box.gate_state("local")
            # 2 cores ⇒ the owner's table says ONE runner, and one is already alive: the fill loop
            # cannot run, so this case measures the label rule and nothing else.
            record = converge(box, nproc="2")
            check(
                record.get("label_floor_binds") is True,
                f"the pool has no {ra.FALLBACK_LABEL} and the record must say so: {record}",
            )
            argv = [c for c in box.calls("config-calls.log") if "argv=" in c]
            check(len(argv) == 1, f"expected exactly one registration, got {argv}")
            contains(argv[0], f"--labels {ra.ARCH_LABEL['x86_64']},{ra.FALLBACK_LABEL}", "the argv")
            # The reason is a RECORD note, not a bare print: `--json` prints the record on stdout and
            # a print from resolve_labels corrupted it (this is the machine-readable contract).
            floor_notes = [n for n in record["notes"] if "label floor" in n]
            check(len(floor_notes) == 1, f"exactly one floor line, got {record['notes']}")
            contains(floor_notes[0], ra.FALLBACK_LABEL, "the floor line")
            contains(floor_notes[0], "advertises", "the floor line")
            check(record["verdict"] != "action-failed", f"record: {record}")

            # ⛔ AND THE MACHINE-READABLE CONTRACT STILL HOLDS. A `print` from `resolve_labels`
            # landed on stdout in the middle of the single-line `--json` record, so every fleet
            # consumer of that record broke exactly when the floor bound (i.e. when it mattered).
            # Driven as a REAL subprocess, because the corruption was a stdout-ordering effect that
            # an in-process call cannot see.
            cli = subprocess.run(
                [sys.executable, MODULE_UNDER_TEST, "--json", "--root", box.root],
                # ⛔ THIS SUBPROCESS MUST USE THE CASE'S OWN 2-CORE PREMISE. `Box` already pins
                # `RUNNER_AUTOSCALE_NPROC=8` as the fixture default, so the CLI was sizing a ceiling
                # of 3 (not the host's core count) and the fill arm ran — in a case about the label
                # rule. Since the fill arm now reports a provisioner that installs NOTHING as a
                # failure, that leaked into the exit code. Pinning 2 restores the stated premise:
                # one runner, already alive, so the fill loop cannot run.
                env={**_cli_env(box), "RUNNER_AUTOSCALE_NPROC": "2"},
                capture_output=True,
                text=True,
            )
            check(cli.returncode == 0, f"--json exited {cli.returncode}: {cli.stderr[:400]}")
            try:
                payload = json.loads(cli.stdout)
            except ValueError as exc:
                raise Failure(f"--json is not ONE json record ({exc})\n--- stdout ---\n{cli.stdout}")
            check(payload.get("label_floor_binds") is True, f"--json record: {payload}")
            check(
                any("label floor" in n for n in payload.get("notes") or []),
                f"--json must carry the reason in its notes: {payload.get('notes')}",
            )
        finally:
            box.destroy()


@test("T2 label handover: gate engaged ⇒ unchanged, and the label is never written twice")
def t2_label_handover():
    with Env():
        pool = {
            "arm-1": ra.PoolEntry(
                name="arm-1", status="online", busy=False,
                labels=["self-hosted", ra.ARM_POOL_LABEL, ra.FALLBACK_LABEL],
            ),
            "x86-1": ra.PoolEntry(
                name="x86-1", status="online", busy=False,
                labels=["self-hosted", "self-hosted-x64", "Linux"],
            ),
        }
        notes: list[str] = []
        got = ra.resolve_labels(pool, "x86_64", notes=notes, gate_mode="local")
        check(got == "self-hosted-x64,ubuntu-latest", f"gate-engaged set was {got!r}")
        check(got.count(ra.FALLBACK_LABEL) == 1, f"{ra.FALLBACK_LABEL} written twice: {got!r}")
        check(notes == [], f"the gate path must not claim the floor, notes={notes}")
        check(
            ra.label_floor_binds(pool, "local") is False,
            "a pool WITH the label does not bind the floor",
        )

        # The other half: the floor is SATISFIED by a non-arm runner, the gate is NOT engaged, and
        # the arch runner must therefore stay arch-only — the pre-floor behaviour, unchanged.
        satisfied = {
            "x86-1": ra.PoolEntry(
                name="x86-1", status="online", busy=False,
                labels=["self-hosted", "self-hosted-x64", ra.FALLBACK_LABEL],
            )
        }
        notes = []
        got = ra.resolve_labels(satisfied, "x86_64", notes=notes, gate_mode="github")
        check(got == "self-hosted-x64", f"a satisfied floor must add nothing, got {got!r}")
        check(notes == [], f"no floor note when the floor is satisfied, notes={notes}")
        # ⛔ THE PUBLISHED BOOLEAN IS PINNED, not just the label string (review finding P2). The
        # description of `fallback_engaged` was already widened once and nothing reddened; a fleet
        # reader keyed on it must be able to trust the definition the record documents.
        check(
            ra.fallback_engaged(pool) is True,
            "an ARM pool entry carrying the fallback IS engaged (the record publishes this)",
        )
        check(
            ra.fallback_engaged(satisfied) is False,
            "an x64 pool carrying the label is NOT 'engaged' — the key means an ARM marker too",
        )


@test("T3 label floor unions: a DEAD runner's re-registration keeps its custom label AND gains")
def t3_floor_unions_over_preserved():
    """THE PRE-FIX DEFECT THIS PINS. The floor was only reached when there was nothing to preserve
    (`preserved or resolve_labels(...)`). A DEAD runner is still IN the pool, so it has labels to
    keep — and its re-registration therefore wrote a set with no `ubuntu-latest` at all, on the one
    path that runs after every restart. The floor is a UNION over the preserved set, not an
    alternative to it."""
    with Env():
        box = Box("floor-union")
        try:
            box.install("gh-runner-x64", "r-dead")
            # Offline (DEAD) and carrying a custom tier label that must survive, but NO ubuntu-latest
            # anywhere in the pool: this is the pool-wide-strip state.
            box.pool(
                [
                    (
                        "r-dead",
                        "offline",
                        False,
                        ["self-hosted", "Linux", "X64", "self-hosted-x64", "tier-a"],
                    )
                ]
            )
            box.alive([])
            box.gate_state("local")
            record = converge(box, want=0)
            argv = [c for c in box.calls("config-calls.log") if "argv=" in c]
            check(len(argv) == 1, f"expected exactly one re-registration, got {argv}")
            contains(argv[0], "--labels self-hosted-x64,tier-a,ubuntu-latest", "the argv")
            check(
                argv[0].count(ra.FALLBACK_LABEL) == 1,
                f"{ra.FALLBACK_LABEL} must appear exactly once: {argv[0]}",
            )
            check(
                any("label floor" in n for n in record["notes"]),
                f"the DEAD path must say the floor bound: {record['notes']}",
            )
            check(record.get("label_floor_binds") is True, f"record: {record}")
            # ⛔ THE OTHER PUBLISHED POOL FACT IS PINNED TOO (review finding P2). Its description
            # already widened once, and the field could be replaced with `None` while 43 cases
            # stayed green: an x64 pool carrying the label is NOT "engaged".
            check(
                record.get("fallback_engaged") is False,
                f"the record publishes the pool fact: {record.get('fallback_engaged')!r}",
            )
        finally:
            box.destroy()


@test("T4 repair: 'already configured' is cleared before the attempt, and the runner ends REGISTERED")
def t4_repair_recovers_from_already_configured():
    """THE MEASURED CELL-4 DEFECT. A registration deleted server-side gets `--replace`, and the
    runner's own `config.sh` refuses: "Cannot configure the runner because it is already configured.
    To reconfigure the runner, run './config.sh remove' first." With the local config never cleared,
    the repair could not repair — so BOTH halves are pinned here: the local config is gone BEFORE the
    first attempt (`local_runner=absent`), and a `config.sh` that still refuses is retried once and
    the runner ends registered."""
    with Env():
        box = Box("repair")
        try:
            box.install("gh-runner-x64", "r-dead")
            # In the pool, offline, carrying the fallback label so THIS case measures the repair
            # path alone (the floor is satisfied and cannot be what did the work).
            box.pool([("r-dead", "offline", False, ["self-hosted-x64", ra.FALLBACK_LABEL])])
            box.alive([])
            box.refusals(1)  # the FIRST configure answers the measured refusal, the second works
            record = converge(box, want=0)

            calls = box.calls("config-calls.log")
            argv_calls = [c for c in calls if "argv=" in c]
            check(len(argv_calls) == 2, f"expected a refusal then a retry, got {argv_calls}")
            check(
                "call 1 local_runner=absent" in calls,
                "the local config must be CLEARED before the first attempt — with it present the "
                f"real config.sh refuses exactly as measured. calls={calls}",
            )
            runner_cfg = os.path.join(box.installs["gh-runner-x64"], ".runner")
            check(os.path.exists(runner_cfg), "the retry must leave the install REGISTERED (.runner)")
            with open(runner_cfg, encoding="utf-8") as fh:
                check(json.load(fh).get("agentName") == "r-dead", "the retry must rewrite .runner")
            check(not record["problems"], f"the repair must not report a failure: {record['problems']}")
            check(
                any(a.startswith("registered r-dead") for a in record["actions"]),
                f"the record must say the runner was re-registered: {record['actions']}",
            )
        finally:
            box.destroy()


@test("T5 repair fails closed: a failed re-registration RESTORES the install, at its original mode")
def t5_failed_repair_restores_the_install():
    """The failure leg of fix 2, which the first version of the fix got WRONG in two ways, both
    measured on the fixture before they were fixed:
      * it restored `.credentials`/`.credentials_rsaparams` with a plain write, i.e. 0644 — and
        `.credentials_rsaparams` is the runner's RSA PRIVATE KEY, which `config.sh` writes 0600. A
        shared cell would have been left with a world-readable runner identity;
      * a clear that failed PARTWAY (EACCES on `.credentials`) left the install without `.runner`,
        so `discover()` no longer saw it and its slot read FREE to the provisioner — the very
        "install vanishes" state the stash exists to prevent.
    Both are pinned here, because both are silent."""
    with Env():
        box = Box("repair-fail")
        try:
            path = box.install("gh-runner-x64", "r-dead")
            for name in (".credentials", ".credentials_rsaparams"):
                os.chmod(os.path.join(path, name), 0o600)
            box.pool([("r-dead", "offline", False, ["self-hosted-x64", ra.FALLBACK_LABEL])])
            box.alive([])
            box.refusals(5)  # EVERY attempt refuses: the failure leg
            record = converge(box, want=0)

            check(record["problems"], f"a failed repair must be recorded: {record}")
            check(
                any("already configured" in p.lower() for p in record["problems"]),
                f"the record must quote config.sh's own words: {record['problems']}",
            )
            check(
                os.path.exists(os.path.join(path, ".runner")),
                "the failed repair must put `.runner` BACK — without it the install is invisible to "
                "discover() and its slot reads FREE to the provisioner",
            )
            modes = {n: oct(os.stat(os.path.join(path, n)).st_mode & 0o777)
                     for n in (".credentials", ".credentials_rsaparams")}
            check(
                modes == {".credentials": "0o600", ".credentials_rsaparams": "0o600"},
                f"the restore must preserve 0600 on the credential pair (RSA key), got {modes}",
            )
            check(
                [r.name for r in ra.discover(box.root)] == ["r-dead"],
                "the install must still be DISCOVERED after a failed repair",
            )

            # …and a clear that fails PARTWAY restores what it already took.
            box2 = Box("repair-eacces")
            try:
                path2 = box2.install("gh-runner-x64", "r-dead")
                box2.pool([("r-dead", "offline", False, ["self-hosted-x64", ra.FALLBACK_LABEL])])
                box2.alive([])
                # `.runner` is cleared FIRST, then this file is unreadable: exactly the partial state.
                os.chmod(os.path.join(path2, ".credentials"), 0o000)
                record2 = converge(box2, want=0)
                check(record2["problems"], f"an unreadable local config must be recorded: {record2}")
                check(
                    any("cannot clear" in p for p in record2["problems"]),
                    f"the record must name the clear that failed: {record2['problems']}",
                )
                check(
                    os.path.exists(os.path.join(path2, ".runner")),
                    "a PARTIAL clear must restore what it already removed, not leave a half-install",
                )
            finally:
                os.chmod(os.path.join(path2, ".credentials"), 0o600)
                box2.destroy()
        finally:
            box.destroy()


@test("T6 repair raises safe: a FAILED token mint cannot destroy the install it just cleared")
def t6_repair_is_exception_safe():
    """THE HOLE ROUND 2 FOUND IN FIX 2. `registration_token()` is evaluated AFTER the local config was
    cleared, and it raises on any gh failure — a routine transient for a pass that runs every few
    minutes. Restoring only on `rc != 0` meant a failed mint left the install with NO `.runner` and NO
    RSA key: `discover()` stopped seeing it, its slot read FREE to the provisioner (`[ ! -f .runner ]`
    is the installer's own occupancy test) and the SAME pass installed a second runner over the top.
    Measured on the fixture before the fix: the directory kept `config.sh` alone. This case pins the
    restore for a RAISE, not just for a non-zero exit."""
    with Env():
        box = Box("repair-raise")
        try:
            path = box.install("gh-runner-x64", "r-dead")
            for name in (".credentials", ".credentials_rsaparams"):
                os.chmod(os.path.join(path, name), 0o600)
            box.pool([("r-dead", "offline", False, ["self-hosted-x64", ra.FALLBACK_LABEL])])
            box.alive([])
            box.token_fails()
            record = converge(box, want=0)

            check(record["problems"], f"the failed mint must be recorded: {record}")
            check(
                any("registration token" in p for p in record["problems"]),
                f"the record must name the token failure: {record['problems']}",
            )
            present = sorted(os.listdir(path))
            for name in (".runner", ".credentials", ".credentials_rsaparams"):
                check(name in present, f"{name} must be RESTORED after a raise; dir={present}")
            modes = {
                n: oct(os.stat(os.path.join(path, n)).st_mode & 0o777)
                for n in (".credentials", ".credentials_rsaparams")
            }
            check(
                set(modes.values()) == {"0o600"},
                f"the restored credential pair must stay 0600 (RSA key), got {modes}",
            )
            check(
                [r.name for r in ra.discover(box.root)] == ["r-dead"],
                "the install must still be DISCOVERED — otherwise nothing retries the same repair",
            )
            check(
                ra._next_free_slot(box.root) > 1,
                "the install's slot must NOT read free to the provisioner: `[ ! -f .runner ]` is the "
                "installer's own occupancy test, so a missing `.runner` invites a SECOND install",
            )
        finally:
            box.destroy()


@test("T7 unread pool after OUR OWN restart: bounded retry, then the verdict CARRIES gh's words")
def t7_unread_pool_after_restart():
    """THE MEASURED FAILURE (cell 4): verdict `action-failed` / `unverified_cause=pool-read-after-restart`
    and the log line "restart succeeded but the pool could not be READ" — with no reason. The read
    races a restart THIS PASS issued, so ONE transient blip ended the pass with the box's state
    unknown and nothing an operator could act on. Pinned here: a transient failure is retried a
    BOUNDED number of times, then `unmeasurable`, and the message must CONTAIN the gh error text (a
    message that hides the reason is a test failure)."""
    with Env():
        box = Box("pool-unread")
        try:
            box.install("gh-runner-x64", "r-dead")
            box.pool([("r-dead", "offline", False, ["self-hosted-x64", ra.FALLBACK_LABEL])])
            box.alive([])
            box.pool_seq(
                [
                    "ok",  # the pass's FIRST read: offline, so a restart is due
                    "err:dial tcp 10.0.0.1:443: i/o timeout",  # …and every later read fails this way
                ]
            )
            record = converge(box, want=0)

            check(record["verdict"] == "unmeasurable", f"verdict must be unmeasurable: {record}")
            check(
                record.get("unverified_cause") == "pool-read-after-restart",
                f"the cause must name the racing read: {record}",
            )
            check(
                box.pool_reads() == 4,
                f"expected 1 initial read + 3 bounded attempts, got {box.pool_reads()} pool reads",
            )
            blob = " ".join(record["notes"]) + " " + str(record.get("error"))
            contains(blob, "i/o timeout", "the record")
            contains(blob, "dial tcp 10.0.0.1:443", "the record")
            check(
                not [c for c in box.calls("config-calls.log") if "argv=" in c],
                "an UNREAD pool must never re-register — that is the destructive action",
            )
            rc, out = cli(box, "--json", "--root", box.root, "--want", "0")
            check(rc == 2, f"unmeasurable must exit 2 (fail-closed), got {rc}: {out[:300]}")
        finally:
            box.destroy()


@test("T8 a DETERMINISTIC pool error is NOT retried, and its own words survive")
def t8_deterministic_pool_error_is_not_retried():
    """The other real cause measured that night: the unit had no repo, so the call was
    `gh api repos//actions/runners` → 404. Retrying a 404 is more latency for the same answer, and
    "transient" would then mean "anything" — so the retry is gated on NETWORK/5xx/RATE-LIMIT markers
    and a deterministic error is surfaced at once, verbatim."""
    with Env():
        box = Box("pool-404")
        try:
            box.install("gh-runner-x64", "r-dead")
            box.pool([("r-dead", "offline", False, ["self-hosted-x64", ra.FALLBACK_LABEL])])
            box.alive([])
            box.pool_seq(["ok", "err:gh: Not Found (HTTP 404) — repos//actions/runners"])
            record = converge(box, want=0)
            check(record["verdict"] == "unmeasurable", f"verdict must be unmeasurable: {record}")
            check(
                box.pool_reads() == 2,
                f"a 404 must NOT be retried (1 initial + 1 attempt), got {box.pool_reads()} reads",
            )
            blob = " ".join(record["notes"]) + " " + str(record.get("error"))
            contains(blob, "repos//actions/runners", "the record")
            contains(blob, "404", "the record")
        finally:
            box.destroy()


@test("T9 starvation FIRES: queued>0 ∧ busy==0 ∧ online>0 ⇒ verdict + non-zero exit, counts named")
def t9_starvation_fires():
    """agent-infra#2875. WORK IS WAITING, CAPACITY IS UP, NONE OF IT IS BUSY — and nothing watched
    it. Measured 2026-10-27 it was misread twice in one night, first as "capacity" and then as
    "review cost", costing the merge window. The converger already reads both numbers, so it alarms:
    a verdict naming the invariant and the three counts, and a NON-ZERO exit.

    The pre-fix shape read exactly this box as healthy: 1 runner online, not busy, 0 problems ⇒
    `at-ceiling` and exit 0."""
    with Env():
        box = Box("starved")
        try:
            box.pool([("r-1", "online", False, ["self-hosted-x64", ra.FALLBACK_LABEL])])
            box.queued(53)
            record = converge(box, want=0)
            check(record["verdict"] == "starvation", f"verdict must be starvation: {record}")
            check(record.get("starvation") == "starved", f"starvation state: {record.get('starvation')}")
            blob = " ".join(record["notes"]) + " " + str(record.get("error"))
            contains(blob, "STARVATION", "the record")
            contains(blob, "queued>0 AND busy==0 AND online>0", "the record")
            contains(blob, "queued=53", "the record")
            contains(blob, "busy=0", "the record")
            contains(blob, "online=1", "the record")
            # ⛔ THE MACHINE-READABLE COUNTS ARE PINNED, not only the prose (review finding P2). The
            # header claims `queued_runs`/`starvation_queued` are published for fleet readers; a
            # deleted assignment kept the whole suite green, so the contract had no artifact.
            check(record.get("queued_runs") == 53, f"queued_runs must be published: {record}")
            check(record.get("starvation_queued") == 53, f"starvation_queued: {record}")
            check(record.get("starvation_busy") == 0, f"starvation_busy: {record}")
            check(record.get("starvation_online") == 1, f"starvation_online: {record}")
            check(record.get("starvation_eligible") is True, f"starvation_eligible: {record}")
            check(
                record["actions"] == [],
                f"the alarm must CHANGE NOTHING (it is not a healer): {record['actions']}",
            )
            rc, out = cli(box, "--root", box.root, "--want", "0")
            check(rc == 4, f"a starvation alarm must exit non-zero (4), got {rc}: {out[:400]}")
            contains(out, "starvation", "the human output")
        finally:
            box.destroy()


@test("T9b confirmation: the second sample must ALSO be starved, so a handover blip is not an alarm")
def t9b_starvation_is_confirmed():
    """The invariant also holds for a few seconds of ordinary handover (a queue drains, the next job
    has not been assigned yet). So the probe samples again before alarming — and ONLY when the first
    sample already looks starved, so a healthy box pays nothing."""
    with Env():
        box = Box("starved-blink")
        try:
            box.pool([("r-1", "online", False, ["self-hosted-x64", ra.FALLBACK_LABEL])])
            box.queued_seq([53, 0])  # starved on the first sample, drained by the second
            box.env["RUNNER_AUTOSCALE_STARVATION_CONFIRM_S"] = "0.01"
            record = converge(box, want=0)
            check(
                record["verdict"] != "starvation",
                f"a blip must NOT alarm (the second sample was queued=0): {record['verdict']}",
            )
            check(
                record.get("starvation") == "ok",
                f"the probe must report ok after the second sample: {record.get('starvation')}",
            )
        finally:
            box.destroy()


@test("T10 the three NEAR-MISSES must not fire: busy pool, empty queue, all-offline")
def t10_starvation_near_misses():
    """Each of these was a way to misread the same night, and each must stay silent:
      (a) queued>0 ∧ busy>0 — a BUSY pool is demand being served, not starvation;
      (b) queued==0 — nothing is waiting;
      (c) all runners OFFLINE — nothing can take work, which is the DEAD/ORPHANED repair path's job.
    Firing on (c) would page a human for a state this tool already owns, which is why `online > 0`
    is an operand of the invariant rather than a comment."""
    cases = [
        ("busy-pool", [("r-1", "online", True, ["self-hosted-x64", ra.FALLBACK_LABEL])], 53),
        ("empty-queue", [("r-1", "online", False, ["self-hosted-x64", ra.FALLBACK_LABEL])], 0),
        ("all-offline", [("r-1", "offline", False, ["self-hosted-x64", ra.FALLBACK_LABEL])], 53),
    ]
    with Env():
        for label, pool, queued in cases:
            box = Box(f"near-{label}")
            try:
                box.pool(pool)
                box.queued(queued)
                record = converge(box, want=0)
                check(
                    record.get("starvation") != "starved",
                    f"[{label}] must NOT read as starved: {record.get('starvation')} ({record['verdict']})",
                )
                check(
                    record["verdict"] != "starvation",
                    f"[{label}] verdict must not be starvation: {record['verdict']}",
                )
                check(
                    not any("STARVATION " in n for n in record["notes"]),
                    f"[{label}] no starvation line may be emitted: {record['notes']}",
                )
            finally:
                box.destroy()


@test("T11 an UNREADABLE queue is 'unmeasured', never 'ok' — blindness must not read as health")
def t11_unreadable_queue_is_unmeasured():
    """The one input that can silence the alarm. `read_queued_runs` raises instead of returning 0, and
    the probe reports `unmeasured` with gh's own words — because turning a failed read into `ok` is
    how a starved box keeps reading healthy, and turning it into exit 2 would let a permission-scoped
    token redden the capacity tool for ever. The residual is a CONSUMER duty, stated here: the green
    test is `starvation == "ok"`, never `starvation != "starved"`."""
    with Env():
        box = Box("queue-unread")
        try:
            box.pool([("r-1", "online", False, ["self-hosted-x64", ra.FALLBACK_LABEL])])
            box.unqueue()
            record = converge(box, want=0)
            check(
                record.get("starvation") == "unmeasured",
                f"an unread queue must be 'unmeasured', got {record.get('starvation')!r}",
            )
            check(record["verdict"] != "starvation", f"it must not alarm either: {record['verdict']}")
            blob = " ".join(record["notes"])
            contains(blob, "NOT evaluated", "the record")
            contains(blob, "actions/runs?status=queued", "the record")
            rc, out = cli(box, "--root", box.root, "--want", "0")
            check(rc == 0, f"the pass itself is healthy, so exit 0 — but the state is NAMED: {out[:200]}")
            contains(out, "starvation=unmeasured", "the human output")
        finally:
            box.destroy()


@test("T12 a pass that ACTED still ALARMS — the alarm is never suppressed by actions")
def t12_acting_pass_still_alarms():
    """MEASURED IN REVIEW ROUND 2, and it inverted the first version of this gate. Gating the alarm
    on "this pass did nothing" silences it FOR EVER on exactly the box that needs it: a runner whose
    repair never sticks is restarted and re-registered on every pass, so the acting gate reported
    `converged` / exit 0 with 53 runs still queued — #2875's own signature, hidden inside the state
    the tool keeps repairing. A bounded false page right after a repair is the cheaper failure, so
    the alarm fires on an acting pass too."""
    with Env():
        box = Box("acted-starved")
        try:
            box.install("gh-runner-x64", "r-dead")
            box.pool(
                [
                    ("r-dead", "offline", False, ["self-hosted-x64", ra.FALLBACK_LABEL]),
                    ("r-other", "online", False, ["self-hosted-x64", ra.FALLBACK_LABEL]),
                ]
            )
            box.alive([])
            box.queued(53)
            record = converge(box, want=0)
            check(record["actions"], f"this case needs a pass that ACTED: {record}")
            check(
                record.get("starvation") == "starved",
                f"an acting pass must STILL evaluate the invariant: {record.get('starvation')!r}",
            )
            check(
                record["verdict"] == "starvation",
                f"…and must still alarm: {record['verdict']}",
            )
        finally:
            box.destroy()


class _WaitRecorder:
    """A stand-in for the module's `time` BINDING (never the stdlib module) that records what it is
    asked to sleep.

    ⛔ WHY A PROXY AND NOT `ra.time.sleep = ...`: `ra.time` IS the stdlib module, so patching its
    attribute rewrites `time.sleep` PROCESS-WIDE — including CPython's own
    `subprocess.Popen._wait` poll loop (`sleep(min(delay*2, remaining, .05))`), which fires whenever a
    stub child outlives the first `waitpid`. That leaked `0.001…0.05` entries into the recorder and
    made the T13 assertion FLAKE (measured: 1 red in 3 runs, the failing input varying — timing, not
    input). Rebinding the MODULE's reference keeps the recorder to this module's own sleeps, and
    `__getattr__` still delegates every other clock read (`monotonic`, `time`) to the real module —
    which `wait_online` needs and which one assertion below pins.
    """

    def __init__(self):
        self.sleeps: list[float] = []
        self.delegated: list[str] = []

    def sleep(self, seconds):
        self.sleeps.append(seconds)

    def __getattr__(self, name):
        self.delegated.append(name)
        return getattr(time, name)


@test("T13 the alarm never masks a real failure — and a bad confirm interval cannot disable it")
def t13_gate_and_confirm_interval():
    """Two guards the review found were unpinned, both about a guard that quietly stops guarding:
      (a) THE GATE. A starved queue on a pass that ALSO failed must not publish a starvation state:
          the verdict is `action-failed` and the invariant was never evaluated (the key is ABSENT —
          "not evaluated" must not read as "healthy"), so no consumer can page on the alarm while the
          real failure is the repair.
      (b) THE CONFIRM INTERVAL seam accepts `nan`, `-5` and `inf` under a plain `float()`. The first
          two SILENTLY SKIPPED the confirmation sample and `inf` raised `OverflowError` OUT of the
          pass (only `Unmeasurable` is caught), killing it with no record. Each must fall back to the
          default AND say so."""
    with Env():
        box = Box("gate-failed")
        try:
            box.install("gh-runner-x64", "r-dead")
            box.pool([("r-dead", "offline", False, ["self-hosted-x64", ra.FALLBACK_LABEL])])
            box.alive([])
            box.queued(53)
            box.token_fails()  # the repair fails ⇒ a real failure on a starved queue
            record = converge(box, want=0)
            check(record["verdict"] == "action-failed", f"verdict must be the REAL failure: {record}")
            check(
                record.get("starvation") is None,
                "the invariant must NOT be evaluated on a failed pass (absent key, never 'ok'): "
                f"{record.get('starvation')!r}",
            )
            check(
                not any(n.startswith("STARVATION ") for n in record["notes"]),
                f"…and no alarm line: {record['notes']}",
            )
            check(
                not [c for c in box.calls("gh-calls.log") if "status=queued" in c],
                "an unhealthy pass must not even pay for the queue read",
            )
        finally:
            box.destroy()

        # (b) every value a plain float() would accept but that disables or crashes the guard, PLUS
        # the two edges of the cadence-derived bound. `400` is the value that distinguishes the shipped
        # `<= 300` from a widened `<= 900`: without it, WIDENING the bound survives every other input.
        # ⛔ The recorder is scoped to the MODULE's `time` binding, never to the stdlib module (see
        # _WaitRecorder), and the assertions are on the CONFIRM sleep rather than the whole list,
        # because a pool retry inside the same pass legitimately sleeps here too.
        real_time = ra.time
        for value, expect_sleep in (
            ("nan", 30.0), ("-5", 30.0), ("inf", 30.0), ("30s", 30.0),  # unusable → default
            # ⛔ THE BOUND IS PINNED TO A POINT, NOT TO A WINDOW: `301` is what reddens ANY widening
            # into 301..399 (measured round 6: `<= 350` survived when only 400/900 probed it, so a
            # plausible "6 minutes for a slow box" edit was a FALSE PASS of the finding it came from).
            ("0", 30.0),                                   # ⛔ 0 would SILENTLY disable the second
            #                                                          sample; refused on purpose
            ("301", 30.0), ("400", 30.0), ("900", 30.0),   # above the bound → refused, default 30 s
            ("300", 300.0), ("299", 299.0),                # the bound itself and below → ACCEPTED
        ):
            box = Box("confirm-seam")
            recorder = _WaitRecorder()
            try:
                box.pool([("r-1", "online", False, ["self-hosted-x64", ra.FALLBACK_LABEL])])
                box.queued(53)
                box.env["RUNNER_AUTOSCALE_STARVATION_CONFIRM_S"] = value
                ra.time = recorder
                record = converge(box, want=0)
                check(
                    record["verdict"] == "starvation",
                    f"confirm={value!r}: the alarm must still FIRE, got {record['verdict']}",
                )
                check(
                    recorder.sleeps and recorder.sleeps[-1] == expect_sleep,
                    f"confirm={value!r}: the confirm must sleep {expect_sleep}s, got {recorder.sleeps}",
                )
                # …and the refusal must quote the SHIPPED bound AND the SHIPPED default, derived from
                # the module's own constants rather than retyped here. Both are operator-facing prose
                # that nothing else checks: measured, the note could say "<= 900" while the bound was
                # 300, or "using 60s" while the fallback was 30, and the suite stayed green. The digit
                # boundary matters — a bare `"<= 300" in note` is satisfied by `"<= 3000"`, i.e. by the
                # commonest typo, which is the confusion the note exists to prevent.
                note = next(
                    (n for n in record["notes"] if "not a usable number of seconds" in n), ""
                )
                # ⛔ LITERALS, on purpose: this assertion IS the pin. Deriving the expectation from
                # the same constant the code prints makes it self-referential — measured, a mutant that
                # moved the default 30→45 stayed GREEN. The module derives its prose from the
                # constant (so a change moves the text); the test holds the number the operator was
                # promised (so a change reddens here). That asymmetry is the whole mechanism.
                refused = bool(
                    re.search(r"0 < s <= 300(?![0-9])", note) and "using 30s" in note
                )
                check(
                    refused is (expect_sleep == 30.0),
                    f"confirm={value!r}: the refusal must be NAMED iff the value was refused "
                    f"(refused={refused}, notes={record['notes']})",
                )
                try:
                    delegated = recorder.monotonic()
                except AttributeError:
                    delegated = None
                check(
                    isinstance(delegated, float),
                    "the recorder must DELEGATE every other clock read the module makes — "
                    "`wait_online` calls monotonic() through this same binding",
                )
            finally:
                ra.time = real_time
                box.destroy()

@test("T14 the documented DEFAULT is what an UNSET seam gets — no value is injected")
def t14_unset_seam_takes_the_documented_default():
    """The suite injects the seam everywhere else (1 ms, so cases are fast), which left the UNSET
    branch dead as far as the suite was concerned: measured, changing that `30.0` to `45.0` kept the
    suite green while the module header still advertised `(30)` and the note still said "using 30s" —
    three hand-written copies of one number drifting apart in silence. Here the variable is ABSENT."""
    with Env():
        box = Box("confirm-unset")
        recorder = _WaitRecorder()
        real_time = ra.time
        try:
            box.pool([("r-1", "online", False, ["self-hosted-x64", ra.FALLBACK_LABEL])])
            box.queued(53)
            box.env.pop("RUNNER_AUTOSCALE_STARVATION_CONFIRM_S")
            ra.time = recorder
            record = converge(box, want=0)
            check(record["verdict"] == "starvation", f"the alarm must fire: {record['verdict']}")
            check(
                recorder.sleeps == [30.0],
                f"an unset seam must sleep the DOCUMENTED default (30s), got {recorder.sleeps}",
            )
            check(
                not any("not a usable number" in n for n in record["notes"]),
                f"an unset seam is not a REFUSAL and must not be reported as one: {record['notes']}",
            )
            # ⛔ EVERY HAND-WRITTEN NUMBER IN THE OPERATOR-FACING HEADER AND SIGNATURE IS PINNED HERE,
            # as LITERALS, in one place. These are prose copies that no compiler checks, and each one
            # was measured lying in a previous round: the range said `(0, 900]` while the bound was
            # 300, the default said `(45)` while the code used 30, the exit block said `5 STARVATION`
            # while the code returned 4, and the signature advertised a default nothing else pinned.
            # The module DERIVES its messages from the constants; this test holds the numbers an
            # operator was promised. Change a value and you must change this list — deliberately.
            for needle, what in (
                ("(0, 300]", "the accepted range in the seam table"),
                ("before it pages (30)", "the default in the seam table"),
                ("4 STARVATION", "the exit code in the header's EXIT block"),
            ):
                check(needle in (ra.__doc__ or ""), f"the module header must document {what}")
            check(
                inspect.signature(ra.starvation_probe).parameters["confirm_s"].default == 30.0,
                "the probe's SIGNATURE default is the documented 30s, not a stale copy: "
                f"{inspect.signature(ra.starvation_probe).parameters['confirm_s'].default}",
            )
        finally:
            ra.time = real_time
            box.destroy()


@test("T15 a DIRECT call with confirm_s=0 takes ONE sample — the > that refusing 0 relies on")
def t15_zero_takes_one_sample():
    """`starvation_probe` takes its second sample only when `confirm_s > 0`, and the seam's refusal of
    0 exists BECAUSE that is what keeps 0 from silently disabling the confirmation. Nothing pinned the
    operator itself: `>` → `>=` was green, so a direct caller (or a future seam change) could reach a
    zero-length confirmation that still LOOKS like one. Zero sleeps is the signal."""
    with Env():
        box = Box("probe-zero")
        recorder = _WaitRecorder()
        real_time = ra.time
        try:
            box.pool([("r-1", "online", False, ["self-hosted-x64", ra.FALLBACK_LABEL])])
            box.queued(53)
            box.apply()  # ⛔ the SEAMS, not just the fixture files: without this the direct call
            #               reads the real `gh` and the real repo — measured, it returned a live
            #               queued=94/busy=9/online=9 from the network. A hermetic suite must never
            #               take that path, even accidentally.
            ra.time = recorder
            result = ra.starvation_probe(ra.DEFAULT_REPO, 0.0)
            check(result["state"] == "starved", f"one sample of a starved pool is still starved: {result}")
            check(
                recorder.sleeps == [],
                f"confirm_s=0 must take NO second sample, so no sleep at all: {recorder.sleeps}",
            )
        finally:
            ra.time = real_time
            box.destroy()


# ── 5. THE CONVERGER'S OWN UNIT ────────────────────────────────────────────────────────────────
@test("T16 unit template: a STABLE WorkingDirectory, absolute interpreter and script, a timer that")
def t16_unit_template():
    """`WorkingDirectory=/tmp/cell-wt-runnerauto2` was deleted by a cell reclaim and systemd then
    failed the oneshot with `status=200/CHDIR` BEFORE running a line — every 10 minutes, for as long
    as the reclaim stood. The template must therefore pin the ONE path a reclaim cannot take (`%h`),
    and must name an ABSOLUTE interpreter and script: `ExecStart=python3 ...` is not a PATH lookup."""
    units = ra.render_unit("daniel-ospina/tortoise")
    service = units[f"{ra.UNIT_BASENAME}.service"]
    timer = units[f"{ra.UNIT_BASENAME}.timer"]
    check(
        "WorkingDirectory=%h" in service,
        f"the default WorkingDirectory must be %h, got:\n{service}",
    )
    # ⛔ A BLANKET "/tmp not in service" MEASURED WHERE THE SUITE RUNS, NOT THE TEMPLATE. `render_unit`
    # pins `Path(__file__).resolve()`, so on a cell — where the checkout IS under /tmp — the template
    # names a transient path CORRECTLY, and the audit reports it (T27). Asserting its absence made
    # this case red on every box the tool exists for, which is a false RED about a correct template.
    # The rule is: the ONLY transient path the template may carry is the one this module actually
    # lives at, and when that is transient the audit must SAY so.
    module_path = str(Path(ra.__file__).resolve())
    check(
        "/tmp" not in service.replace(module_path, "")
        and "/var/tmp" not in service.replace(module_path, ""),
        f"no transient path may appear except this module's own (if it lives in one):\n{service}",
    )
    exec_line = next(ln for ln in service.splitlines() if ln.startswith("ExecStart="))
    check(
        exec_line.startswith('ExecStart="') and module_path in exec_line,
        f"ExecStart must be ABSOLUTE, QUOTED and name THIS script: {exec_line}",
    )
    if ra.transient_path_problem(str(Path(module_path).parent)):
        check(
            ra.unit_exec_problems("x.service", [exec_line[len("ExecStart="):]], "oneshot"),
            "a transient script path in the template must be REPORTED by the audit, not silently "
            "rendered — otherwise the schedule dies 203/EXEC with 'all usable' in the audit",
        )
    check(
        any(ln.startswith("Unit=") and ln.endswith(".service") for ln in timer.splitlines()),
        f"the timer must name the service it drives:\n{timer}",
    )
    check(
        any(ln.startswith("OnUnitActiveSec=") for ln in timer.splitlines()),
        "the timer must be PERIODIC, not only OnBoot",
    )
    check(
        ra.unit_workdir_problem(None) is None,
        f"the default workdir must be usable: {ra.unit_workdir_problem(None)}",
    )
    # ⛔ THE PROVISIONER IS PINNED INTO THE UNIT (review finding P1), because `%h` as the cwd kills
    # the `$PWD/tools/…` candidate and no deployment puts the installer in `~/.pi/agent/scripts` —
    # a scheduled pass then resolved nothing and the FILL half could never fire.
    pinned = ra.render_unit("daniel-ospina/tortoise", provisioner="/opt/harness/install-x64.sh")
    pinned_service = pinned[f"{ra.UNIT_BASENAME}.service"]
    check(
        'Environment="RUNNER_AUTOSCALE_PROVISIONER=/opt/harness/install-x64.sh"' in pinned_service,
        f"a resolved provisioner must be PINNED into the unit, and QUOTED: systemd.exec(5) says "
        f"`Environment=` performs specifier expansion and splits an unquoted assignment on "
        f"whitespace, so an unquoted path with a space is truncated. got:\n{pinned_service}",
    )
    # …and the path is VALIDATED before it reaches the file: the same rejections `--repo` gets.
    for bad, needle in (
        ("/opt/harness/install-%h.sh", "systemd specifier"),
        ('/opt/it"s.sh', "double quote"),
        ("/opt/two words.sh\nExecStartPre=/bin/false", "control character"),
        ("relative/install.sh", "not absolute"),
    ):
        problem = ra.provisioner_problem(bad)
        check(problem is not None, f"a provisioner path must be refused: {bad!r}")
        contains(problem, needle, f"the refusal for {bad!r}")
    unpinned = ra.render_unit("daniel-ospina/tortoise", provisioner=None)
    check(
        "RUNNER_AUTOSCALE_PROVISIONER"
        not in unpinned[f"{ra.UNIT_BASENAME}.service"].split("ExecStart=")[0],
        "no unresolvable provisioner may be written into the unit (an empty value would be read "
        "as a path by the fill arm)",
    )


@test("T17 install REFUSES a missing WorkingDirectory — and writes NOTHING")
def t17_missing_workdir_refused():
    with Env():
        box = Box("unit-missing")
        try:
            box.apply()
            # ⛔ NOT under the fixture's tmpdir: that path is TRANSIENT, so it would be refused for
            # its SHAPE and this case would never exercise the exists() check it is about. A path
            # under the (durable) home is refused for exactly one reason: it is not there.
            gone = os.path.join(str(ra.account_home()), "runnerauto-definitely-absent-cwd")
            code, out = cli(box, "--install-unit", "--workdir", gone)
            check(code == 1, f"a missing cwd must be REFUSED (exit 1, nothing written), got {code}")
            check("does not exist" in out, f"the refusal must name the reason, got: {out!r}")
            check(
                not os.listdir(os.path.join(box.dir, "units")),
                f"NOTHING may be written on a refusal: {os.listdir(os.path.join(box.dir, 'units'))}",
            )
        finally:
            box.destroy()


@test("T18 install REFUSES a transient WorkingDirectory — even when it EXISTS today")
def t18_transient_workdir_refused():
    """The measured failure mode is subtle: the path existed when the unit was written and was gone
    later. Refusing only on `is_dir` would let the incident through on day one, so the path's SHAPE
    is refused — an existing directory under /tmp (or the TMPDIR a harness hands us) is a countdown."""
    with Env():
        box = Box("unit-transient")
        try:
            box.apply()
            code, out = cli(box, "--install-unit", "--workdir", box.dir)  # exists, and transient
            check(code == 1, f"an existing transient cwd must still be REFUSED, got {code}")
            check(
                "inside /" in out,
                f"the refusal must say WHY the path is unusable, got: {out!r}",
            )
            check(
                not os.listdir(os.path.join(box.dir, "units")),
                "NOTHING may be written on a refusal",
            )
            # ⛔ A `%` is expanded at LOAD time, so a directory whose NAME contains one passes an
            # is_dir check and then resolves to a DIFFERENT path inside systemd — the very
            # status=200/CHDIR class this fix closes. A newline is a directive injection.
            specifier = str(ra.account_home()) + "/ra-%h-literal-dir"
            newline = str(ra.account_home()) + "/x\nExecStartPre=/bin/false"
            for value, needle in ((specifier, "systemd specifier"), (newline, "control character")):
                code2, out2 = cli(box, "--install-unit", "--workdir", value)
                check(code2 == 1, f"workdir={value!r} must be REFUSED, got {code2}: {out2}")
                check(needle in out2, f"the refusal must name the reason: {out2!r}")
            # ⛔ --repo is interpolated into ExecStart: a newline writes a DIRECTIVE, a quote closes
            # the quote and re-points --repo, and a `%` becomes a specifier at load time.
            for bad_repo, needle in (
                ("o/r\nExecStartPre=/bin/false", "not a plain"),
                ('o/r" --repo "x', "not a plain"),
                ("o/r%n", "not a plain"),
                ("o", "not a plain"),
            ):
                code3, out3 = cli(box, "--install-unit", "--repo", bad_repo)
                check(code3 == 1, f"repo={bad_repo!r} must be REFUSED, got {code3}: {out3}")
                check(needle in out3, f"the refusal must say why: {out3!r}")
            check(
                not os.listdir(os.path.join(box.dir, "units")),
                "NOTHING may be written on any of those refusals",
            )
        finally:
            box.destroy()


@test("T19 install writes the pair and ENABLES the timer — written is not scheduled")
def t19_install_writes_and_enables():
    with Env():
        box = Box("unit-install")
        try:
            box.apply()
            code, out = cli(box, "--install-unit")
            check(code == 0, f"an installable unit must install, got {code}: {out}")
            units = os.path.join(box.dir, "units")
            check(
                sorted(os.listdir(units))
                == [f"{ra.UNIT_BASENAME}.service", f"{ra.UNIT_BASENAME}.timer"],
                f"both files must be written, got {sorted(os.listdir(units))}",
            )
            calls = box.calls("systemctl-calls.log")
            check(
                any("--user daemon-reload" in c for c in calls),
                f"the new files must be loaded: {calls}",
            )
            check(
                any(f"--user enable --now {ra.UNIT_BASENAME}.timer" == c.strip() for c in calls),
                f"the TIMER must be enabled: a written unit with no timer schedules nothing: {calls}",
            )
            before = Path(units, f"{ra.UNIT_BASENAME}.service").read_text()
            code2, out2 = cli(box, "--install-unit", "--workdir", str(ra.account_home()))
            check(code2 == 0, f"a re-install must succeed, got {code2}: {out2}")
            check(
                f"WorkingDirectory={ra.account_home()}"
                in Path(units, f"{ra.UNIT_BASENAME}.service").read_text(),
                "an EXPLICIT, usable --workdir must be written literally",
            )
            check(before.strip() != "", "the first write must not have been empty")
        finally:
            box.destroy()

    with Env():
        box = Box("unit-enable-fail")
        try:
            Path(box.dir, "systemctl").write_text(
                "#!/usr/bin/env bash\nprintf '%s\\n' \"$*\" >> \"" + box.dir
                + "/systemctl-calls.log\"\nexit 1\n",
                encoding="utf-8",
            )
            os.chmod(Path(box.dir, "systemctl"), 0o755)
            box.apply()
            code, out = cli(box, "--install-unit")
            check(code == 3, f"a written unit with no running timer is an ACTION failure, got {code}")
            # ⛔ the message must NOT assert a state the code never read (there is no `is-active`
            # query here): it says the schedule is UNKNOWN, and says which step failed.
            check(
                "did not verify whether a timer is scheduled" in out,
                f"the failure must say the schedule is UNKNOWN, not that it is off: {out!r}",
            )
            check(
                "systemctl --user daemon-reload rc=1" in out,
                f"and must name the step that failed: {out!r}",
            )
            check(
                sorted(os.listdir(os.path.join(box.dir, "units")))
                == [f"{ra.UNIT_BASENAME}.service", f"{ra.UNIT_BASENAME}.timer"],
                "the files ARE written — the failure is reported, not hidden",
            )
        finally:
            box.destroy()

    with Env():
        box = Box("unit-half-swap")
        try:
            box.apply()
            code, _ = cli(box, "--install-unit")
            check(code == 0, "the first install must succeed")
            units = Path(box.dir, "units")
            installed = (units / f"{ra.UNIT_BASENAME}.service").read_text()
            # make the SECOND replace fail: a non-empty directory where the timer file must go
            timer = units / f"{ra.UNIT_BASENAME}.timer"
            timer.unlink()
            timer.mkdir()
            Path(timer, "blocker").write_text("x")
            code2, out2 = cli(box, "--install-unit", "--workdir", str(ra.account_home()))
            check(code2 == 3, f"a failed second replace is an ACTION failure, got {code2}: {out2}")
            # ⛔ the message must be TRUE: the service half WAS replaced, the timer half was not
            check(
                "already replaced" in out2 and f"{ra.UNIT_BASENAME}.service" in out2,
                f"the failure must name what it already replaced: {out2!r}",
            )
            check(
                "may be MIXED" in out2,
                f"…and must warn the pair can be MIXED instead of claiming a clean rollback: {out2!r}",
            )
            check(
                (units / f"{ra.UNIT_BASENAME}.service").read_text() != ""
                and timer.is_dir(),
                "no installed file is destroyed and the blocked path is untouched",
            )
            # and the temp files are cleaned up, so a failed install leaves no droppings
            leftovers = [p.name for p in units.iterdir() if p.name.endswith(".tmp") and p.is_file()]
            check(not leftovers, f"no .tmp file may survive a failed install: {leftovers}")
            check(installed.strip() != "", "the first install wrote real content")
            # ⛔ THE DOCUMENTED CONTRACT MUST MATCH THE MESSAGE. Exit 3 is three branches, and two of
            # them leave part of the pair NEW — a header claiming "no file is replaced" told an
            # operator that exit 3 means the previous install is intact, which is observable false.
            doc = ra.__doc__ or ""
            check(
                "3 is NOT a rollback" in doc and "one NEW file beside one from the previous" in doc,
                "the EXIT block must state what exit 3 really guarantees (not a clean rollback)",
            )
        finally:
            box.destroy()


@test("T20 --check-units finds the shape ALREADY installed — and cannot call an unreadable one clean")
def t20_check_units_audit():
    with Env():
        box = Box("unit-audit")
        units = os.path.join(box.dir, "units")
        try:
            for name, body in (
                ("a.service", "[Service]\nWorkingDirectory=/tmp/cell-wt-runnerauto2\nExecStart=/bin/true\n"),
                ("b.service", "[Service]\nWorkingDirectory=/nowhere/at-all\n"),
                ("c.service", "[Service]\nWorkingDirectory=%h\n"),
                ("d.service", "[Service]\nWorkingDirectory=-/tmp/also-gone\n"),
                ("e.service", "[Service]\nWorkingDirectory=%t/thing\n"),
                ("f.service", "[Service]\nExecStart=/bin/true\n"),
            ):
                Path(units, name).write_text(body, encoding="utf-8")
            # ⛔ the population that DECIDES the value: a DROP-IN overrides a clean main unit, and
            # `.socket`/`.path`/... give their processes a working directory too.
            dropin = Path(units, "g.service.d")
            dropin.mkdir()
            Path(units, "g.service").write_text("[Service]\nWorkingDirectory=%h\n", encoding="utf-8")
            Path(dropin, "override.conf").write_text(
                "[Service]\nWorkingDirectory=/tmp/cell-wt-runnerauto2\n", encoding="utf-8"
            )
            Path(units, "h.socket").write_text(
                "[Socket]\nListenStream=1234\n\n[Service]\nWorkingDirectory=/tmp/also-gone\n",
                encoding="utf-8",
            )
            Path(units, "i.service").write_text(
                "[Unit]\nWorkingDirectory=/tmp/not-in-service\n", encoding="utf-8"
            )
            # systemd applies the LAST [Service] assignment: a fixed unit is FIXED, and a line that
            # is overridden has no runtime effect — reporting it would refuse something harmless and
            # would make the documented remedy (a drop-in) unable to ever clear the finding.
            # a VALUELESS `WorkingDirectory` line is not an assignment: systemd skips it and keeps the
            # earlier value, so the bad one must still be reported (parsing it as '' resolved to the
            # home and MASKED the bad line — a fail-open the last-wins rework introduced).
            Path(units, "k.service").write_text(
                "[Service]\nWorkingDirectory=/tmp/cell-wt-runnerauto2\nWorkingDirectory\n",
                encoding="utf-8",
            )
            Path(units, "j.service").write_text(
                "[Service]\nWorkingDirectory=/tmp/then-overridden\n"
                "WorkingDirectory=%h\n",
                encoding="utf-8",
            )
            box.apply()
            code, out = cli(box, "--check-units")
            check(code == 5, f"a read-only audit finding exits 5 (not 3), got {code}: {out}")
            # named by the FILE the value came from — a drop-in is reported as the override, which is
            # the file to edit; the clean main unit it overrides must NOT be blamed
            for name in ("override.conf", "h.socket"):
                check(f"{name}:" in out, f"{name} must be named in the audit: {out}")
            check("g.service:" not in out, f"the CLEAN main unit must not be blamed: {out}")
            check(
                "k.service:" in out,
                f"a VALUELESS line must not mask the bad assignment before it: {out}",
            )
            check(
                "j.service:" not in out,
                f"a value systemd OVERRIDES has no runtime effect and must not be reported: {out}",
            )
            check(
                "i.service" not in out,
                f"a WorkingDirectory under [Unit] has NO runtime effect and must not be refused: {out}",
            )
            # "is inside /" — not "inside /tmp": `resolve()` reports the REAL path, and on macOS
            # /tmp is /private/tmp. The assertion is about the REASON, not about a spelling.
            for bad, needle in (
                ("a.service", "is inside /"),
                ("b.service", "does not exist"),
                # `-` only SUPPRESSES the failure: the unit runs, in the wrong directory. The wording
                # must say that and not "systemd fails this unit", which is false for a tolerated one.
                ("d.service", "silently start in the WRONG directory"),
                ("e.service", "cannot resolve"),
            ):
                check(f"{bad}:" in out and needle in out, f"{bad} must be named ({needle}): {out}")
            for good in ("c.service", "f.service"):
                check(f"{good}:" not in out, f"a healthy unit must NOT be reported: {out}")
            for name in os.listdir(units):
                if name not in ("c.service", "f.service", "i.service", "j.service"):
                    full = os.path.join(units, name)
                    shutil.rmtree(full) if os.path.isdir(full) else os.unlink(full)
            code2, out2 = cli(box, "--check-units")
            check(code2 == 0, f"a clean audit must exit 0, got {code2}: {out2}")
            # ⛔ AN AUDIT THAT READ NOTHING IS NOT A CLEAN AUDIT — the polarity this tool already
            # enforces for pool health (`unmeasured` is never `ok`).
            # ⛔ on box.env, not os.environ: `cli()` re-applies the box's seams, so a bare
            # os.environ assignment is overwritten and the case silently re-audits the fixture dir.
            box.env["RUNNER_AUTOSCALE_UNIT_DIR"] = os.path.join(box.dir, "no-such-unit-dir")
            code3, out3 = cli(box, "--check-units")
            check(code3 == 5, f"an unreadable/absent unit dir must NOT read as clean, got {code3}")
            check("nothing was audited" in out3.lower(), f"…and must say so: {out3!r}")
            check(
                "no-such-unit-dir" in out3,
                f"…and must NAME the directory it could not read: {out3!r}",
            )
            # an EMPTY but existing directory: only the aggregate guard can catch this one, so it
            # pins the second half of the polarity rather than re-testing the first
            empty = os.path.join(box.dir, "empty-unit-dir")
            os.makedirs(empty, exist_ok=True)
            box.env["RUNNER_AUTOSCALE_UNIT_DIR"] = empty
            code4, out4 = cli(box, "--check-units")
            check(code4 == 5, f"an EMPTY unit dir audited NOTHING and must not read as clean: {code4}")
            check("nothing was audited" in out4.lower(), f"…and must say so: {out4!r}")
            box.env["RUNNER_AUTOSCALE_UNIT_DIR"] = units
        finally:
            box.destroy()


@test("T21 a bad installed unit is a NOTE on the pass — it never changes a converged verdict")
def t21_pass_note_does_not_change_the_verdict():
    """`--check-units` is the loud surface (exit 5). The PASS must also NAME what it finds, but it must
    NOT fold it into `problems`: a stale unit file is not a reason to report an otherwise-converged
    pool as failed, and a pass that goes red for it would train its reader to ignore red. Both halves
    are pinned here because a regression in either direction is silent — folding it into `problems`
    reddens every pass on a cell that has one old unit; dropping the note makes it invisible."""
    with Env():
        box = Box("unit-note")
        try:
            Path(box.dir, "units", "old.service").write_text(
                "[Service]\nWorkingDirectory=/tmp/cell-wt-runnerauto2\n", encoding="utf-8"
            )
            box.install("gh-runner-x64", "r-1")
            box.alive([box.installs["gh-runner-x64"]])
            box.pool([("r-1", "online", False, ["self-hosted-x64", ra.FALLBACK_LABEL])])
            record = converge(box, nproc="2", want=1)
            check(
                record["verdict"] in ("at-ceiling", "converged"),
                f"the pool IS converged, so the verdict must say so: {record['verdict']}",
            )
            check(
                record.get("unit_cwd_problems"),
                f"the bad unit must be recorded: {record.get('unit_cwd_problems')}",
            )
            check(
                any(n.startswith("unit audit: ") for n in record["notes"]),
                f"…and NAMED in the human notes as ONE summary line: {record['notes']}",
            )
            check(
                len([n for n in record["notes"] if n.startswith("unit audit: ")]) == 1,
                "one summary note per pass, not one per finding (a standing wall of identical "
                f"lines made a NEW finding indistinguishable): {record['notes']}",
            )
            check(
                record["problems"] == [],
                f"it must NOT become a `problems` entry (that would redden every pass): "
                f"{record['problems']}",
            )
            code, out = cli(box, "--status")
            check(code == 0, f"and the exit code stays a healthy 0, got {code}: {out}")
        finally:
            box.destroy()


@test("T22 a unit directory that cannot be READ is not an empty one")
def t22_unreadable_dir_is_not_empty():
    """Round 2's P1: `Path.glob` swallows `PermissionError`, so a drop-in directory this account could
    not read audited as EMPTY — a transient WorkingDirectory inside it reported CLEAN. The fix walks
    with `iterdir()` and reports the failure; this case pins that branch WITHOUT chmod, because a
    suite running as root would not be denied and would pass vacuously."""
    with Env():
        box = Box("unit-unreadable")
        units = os.path.join(box.dir, "units")
        try:
            Path(units, "ok.service").write_text("[Service]\nWorkingDirectory=%h\n", encoding="utf-8")
            denied = Path(units, "secret.service.d")
            denied.mkdir()
            Path(denied, "override.conf").write_text(
                "[Service]\nWorkingDirectory=/tmp/cell-wt-runnerauto2\n", encoding="utf-8"
            )
            real_iterdir = Path.iterdir

            def guard(self):
                if str(self).endswith("secret.service.d"):
                    raise PermissionError(13, "Permission denied", str(self))
                return real_iterdir(self)

            # the ROOT directory itself unreadable — a different branch from an unreadable `.d`
            root_denied = os.path.join(box.dir, "root-denied")
            os.makedirs(root_denied, exist_ok=True)
            Path(root_denied, "z.service").write_text("[Service]\nWorkingDirectory=%h\n")

            def guard_root(self):
                if str(self) == root_denied or str(self).endswith("secret.service.d"):
                    raise PermissionError(13, "Permission denied", str(self))
                return real_iterdir(self)

            Path.iterdir = guard_root
            try:
                found_root = ra.installed_unit_cwd_problems([root_denied], require_any=True)
            finally:
                Path.iterdir = real_iterdir
            check(
                any("unreadable" in f for f in found_root),
                f"an unreadable ROOT unit dir must be reported: {found_root}",
            )
            Path.iterdir = guard
            try:
                # ⛔ IN PROCESS, not through `cli()`: `cli` spawns a fresh interpreter, where a patched
                # `Path.iterdir` does not exist — measured: the patch was silently ineffective and the
                # case passed on the finding it was supposed to prevent coming from.
                found = ra.installed_unit_cwd_problems([units], require_any=True)
            finally:
                Path.iterdir = real_iterdir
            check(
                any("unreadable" in f for f in found),
                f"an UNREADABLE unit dir must be reported, never audited as EMPTY: {found}",
            )
            check(
                any("NOTHING was audited there" in f for f in found),
                f"…and must say nothing was audited in it: {found}",
            )
            check(
                not any("ok.service" in f for f in found),
                f"the readable unit is still audited normally and must not be blamed: {found}",
            )
        finally:
            box.destroy()


@test("T23 drop-in PRIORITY and the two MANAGERS: a healthy copy must not mask a broken unit")
def t23_priority_and_hierarchies():
    """Two measured fail-opens in the audit's merge, both of the 'reported CLEAN over a broken unit'
    kind:
      (a) two drop-ins with the SAME basename in two directories: systemd SKIPS the overridden file
          (`conf-files.c::files_add`) instead of merging it, so the FIRST (higher-priority) copy is
          the one that runs. Sorting by name alone left the LAST as `last`, so a clean lower-priority
          copy masked a broken higher-priority one.
      (b) the user and system managers search DISJOINT load paths and can never override each other,
          so `/etc/systemd/system/x.service` must not be able to hide a broken
          `~/.config/systemd/user/x.service` (nor invent a finding on a healthy one)."""
    with Env():
        box = Box("unit-priority")
        hi = os.path.join(box.dir, "units-hi")
        lo = os.path.join(box.dir, "units-lo")
        try:
            os.makedirs(os.path.join(hi, "z.service.d"))
            os.makedirs(os.path.join(lo, "z.service.d"))
            Path(hi, "z.service").write_text("[Service]\nWorkingDirectory=%h\n", encoding="utf-8")
            # same basename, DIFFERENT values: the higher-priority copy is the one systemd runs
            Path(hi, "z.service.d", "15-cwd.conf").write_text(
                "[Service]\nWorkingDirectory=/tmp/cell-wt-runnerauto2\n", encoding="utf-8"
            )
            Path(lo, "z.service.d", "15-cwd.conf").write_text(
                "[Service]\nWorkingDirectory=%h\n", encoding="utf-8"
            )
            found = ra.installed_unit_cwd_problems([hi, lo], require_any=True)
            check(
                any("15-cwd.conf" in f for f in found),
                f"the HIGHER-priority drop-in is the effective one and must be reported: {found}",
            )
            # …and the mirror image: bad in the LOWER copy must NOT be reported, because it is skipped
            Path(hi, "z.service.d", "15-cwd.conf").write_text(
                "[Service]\nWorkingDirectory=%h\n", encoding="utf-8"
            )
            Path(lo, "z.service.d", "15-cwd.conf").write_text(
                "[Service]\nWorkingDirectory=/tmp/cell-wt-runnerauto2\n", encoding="utf-8"
            )
            found = ra.installed_unit_cwd_problems([hi, lo], require_any=True)
            check(
                not any("15-cwd.conf" in f for f in found),
                f"an OVERRIDDEN (skipped) drop-in has no runtime effect and must not be reported: "
                f"{found}",
            )
            # the two managers: same unit NAME, disjoint load paths — the user copy is a separate
            # unit, so a HEALTHY user copy must not hide a BROKEN system copy (and vice versa).
            user_root = os.path.join(box.dir, "user-units")
            system_root = os.path.join(box.dir, "etc", "systemd", "system")
            os.makedirs(user_root)
            os.makedirs(system_root)
            Path(user_root, "w.service").write_text("[Service]\nWorkingDirectory=%h\n")
            Path(system_root, "w.service").write_text(
                "[Service]\nWorkingDirectory=/tmp/cell-wt-runnerauto2\n"
            )
            check(
                ra.unit_dir_hierarchy(user_root) == "user"
                and ra.unit_dir_hierarchy(system_root) == "system"
                and ra.unit_dir_hierarchy("/etc/systemd/system") == "system",
                "the audit must KNOW which manager's load path each directory belongs to",
            )
            found2 = ra.installed_unit_cwd_problems([user_root, system_root], require_any=True)
            check(
                any("w.service" in f for f in found2),
                f"a healthy USER copy must not mask a broken SYSTEM copy of the same name: {found2}",
            )
            check(
                [ra.unit_dir_hierarchy(d) for d in ra.default_unit_dirs()]
                == ["user"] * len(ra.USER_UNIT_DIRS) + ["system"] * len(ra.SYSTEM_UNIT_DIRS),
                f"the default population must be the user paths then the system paths: "
                f"{ra.default_unit_dirs()}",
            )

        finally:
            box.destroy()


# ── 6. THE DISK ARM, AND THE CONFLICT WITH THE PROVISIONER'S GUARD ─────────────────────────────
@test("T24 the disk arm binds the ceiling from MEASURED footprint, and names which number did")
def t24_disk_arm():
    """Measured incident: the provisioner refused `9G free against 44G needed for 3 runners (+20G
    reserve)` on an 8-core box whose ceiling said 3. This tool had NO disk term at all, so it asked
    for a runner the disk could not hold. The arm now measures: free space from `df`, and the
    per-runner cost from `du` over the installs — because 8 GB is an ALLOWANCE, not a footprint, and
    the reading has to say which one set the ceiling."""
    with Env():
        box = Box("disk-arm")
        try:
            box.install("gh-runner-x64", "r-1")
            box.alive([box.installs["gh-runner-x64"]])
            box.pool([("r-1", "online", False, ["self-hosted-x64", ra.FALLBACK_LABEL])])
            # 30 GB free, 2 GB measured footprint, 20 GB reserve ⇒ one more fits
            box.disk(30_000)
            box.footprint({"gh-runner-x64": 2000})
            record = converge(box, nproc="8", want=1)
            check(
                record["per_runner_disk_mb"] == ra.FOOTPRINT_MB_DEFAULT,
                f"a 2G measurement BELOW the 8G allowance must not loosen the budget: "
                f"{record['per_runner_disk_mb']}",
            )
            check(
                "measured_largest=2000" in record["reading"]
                and "allowance=8192" in record["reading"]
                and "the stricter of the two" in record["reading"],
                f"the reading must name the measurement, the allowance AND which won: "
                f"{record['reading']}",
            )
            # ⛔ …and a measurement ABOVE the allowance must TIGHTEN it: 20G installs against a 30G
            # disk leave 9520MB, which is less than the 20G a runner now costs ⇒ does NOT fit.
            box.footprint({"gh-runner-x64": 20_000})
            record = converge(box, nproc="8", want=1)
            check(
                record["per_runner_disk_mb"] == 20_000,
                f"a measurement ABOVE the allowance must win (stricter): "
                f"{record['per_runner_disk_mb']}",
            )
            check(
                ra.disk_allows_one_more(30_000, 20_000) is False,
                "30G free with a 20G runner under a 20G reserve does NOT fit",
            )
            box.footprint({"gh-runner-x64": 2000})
            # the arm must BIND: 5 GB free cannot hold a 2 GB runner under a 20 GB reserve
            box.disk(5000)
            record = converge(box, nproc="8", want=0)
            check(
                record["bound"] == "disk",
                f"with 5GB free the DISK must be the binding constraint: {record['reading']}",
            )
            check(
                record["ceiling"] == 1,
                f"1 running + 0 disk headroom ⇒ ceiling 1, got {record['ceiling']}",
            )
            # ⛔ THE PARSE ITSELF: a `df -Pm` line whose SOURCE has a space shifts every later field.
            # `fields[3]` (the pre-fix code) then reads the filesystem TOTAL — here 999999 MB instead
            # of 5000 — turning a 5 GB disk into a 1 TB one and adding a runner it cannot hold.
            box.disk_spaced_source(5000)
            record_sp = converge(box, nproc="8", want=1)
            check(
                record_sp["disk_free_mb"] == 5000,
                f"the free field must be the AVAILABLE column, not the total: "
                f"{record_sp['disk_free_mb']}",
            )
            check(
                record_sp["bound"] == "disk" and record_sp["ceiling"] == 1,
                f"and a 5 GB disk with a 1 MB running set cannot hold another runner: "
                f"{record_sp['reading']}",
            )
            check(
                ra.df_free_mb(box.root) == 5000,
                f"df_free_mb must read the same column: {ra.df_free_mb(box.root)}",
            )
            box.disk(30_000)
            # ⛔ AN UNREADABLE DISK MUST NOT DISABLE THE PASS. Disk space decides ONE thing — whether
            # to ADD — so an unreadable `df` records `disk_unverified`, prints `by_disk=UNKNOWN`, adds
            # nothing, and still repairs and still evaluates the starvation invariant. Making it fatal
            # (this fix's first version) exited 2 BEFORE the repair loop: a box with a DEAD runner
            # stayed unrepaired and the queue alarm (#2875) never ran, for as long as `df` failed.
            Path(box.dir, "df").write_text("#!/usr/bin/env bash\nexit 1\n", encoding="utf-8")
            os.chmod(Path(box.dir, "df"), 0o755)
            code, out = cli(box, "--status", "--json")
            check(
                code == 2,
                f"an unreadable `df` leaves the box's capacity UNKNOWN (unmeasurable, exit 2) — not "
                f"healthy and not fatal: got {code}",
            )
            check("by_disk=UNKNOWN" in out, f"…the reading must say the arm is unknown: {out!r}")
            check("disk free space" in out, f"…naming the failed read: {out!r}")
            # …and the SAME polarity when `df` succeeds but its output cannot be parsed
            Path(box.dir, "df").write_text(
                "#!/usr/bin/env bash\necho 'no numbers here'\n", encoding="utf-8"
            )
            os.chmod(Path(box.dir, "df"), 0o755)
            code, out = cli(box, "--status", "--json")
            check(code == 2, f"unparseable `df` output is UNMEASURABLE too, got {code}")
            check("cannot parse" in out, f"…and must say which read failed: {out!r}")
            box.disk(30_000)

            # ⛔ AND THE HALF THAT MUST STILL RUN: a DEAD runner is repaired, the queue alarm is
            # evaluated, and NO runner is added on an unmeasured disk.
            box_repair = Box("disk-unverified-repair")
            try:
                box_repair.install("gh-runner-x64", "r-dead")
                box_repair.pool(
                    [
                        ("r-dead", "offline", False, ["self-hosted-x64", ra.FALLBACK_LABEL]),
                        ("r-other", "online", False, ["self-hosted-x64", ra.FALLBACK_LABEL]),
                    ]
                )
                box_repair.alive([])
                box_repair.queued(53)
                Path(box_repair.dir, "df").write_text(
                    "#!/usr/bin/env bash\nexit 1\n", encoding="utf-8"
                )
                os.chmod(Path(box_repair.dir, "df"), 0o755)
                # `want=3` on purpose: the CEILING (cores/memory) allows three, so only the
                # unknown disk stands between this pass and an addition — which is exactly the guard
                # under test. `want=0` would never reach the fill loop at all.
                record3 = converge(box_repair, nproc="8", want=3)
                check(
                    any(n.startswith("not filling") for n in record3["notes"]),
                    f"the pass must SAY it withheld the fill: {record3['notes']}",
                )
                check(
                    any(a.startswith("restart r-dead") for a in record3["actions"]),
                    f"a DEAD runner must still be repaired with an unread disk: {record3['actions']}",
                )
                check(
                    record3.get("disk_unverified"),
                    f"…and the unknown disk must be recorded: {record3.get('disk_unverified')}",
                )
                check(
                    record3.get("starvation") == "starved",
                    f"…and the queue alarm must still be evaluated: {record3.get('starvation')}",
                )
                check(
                    not box_repair.calls("provisioner-calls.log"),
                    "an unmeasured disk is NOT permission to add a runner",
                )
                check(
                    record3["verdict"] == "unmeasurable",
                    f"a pass that never asked its only capacity question is NOT converged: "
                    f"{record3['verdict']}",
                )
                check(
                    record3.get("unverified_cause") == "disk-unreadable",
                    f"…and the cause must be named: {record3.get('unverified_cause')}",
                )
            finally:
                box_repair.destroy()
            # and with nothing installed there is nothing to measure, so the allowance is used
            box2 = Box("disk-allowance")
            try:
                box2.disk(30_000)
                record2 = converge(box2, nproc="8", want=0)
                check(
                    record2["per_runner_disk_mb"] == ra.FOOTPRINT_MB_DEFAULT,
                    f"no installs ⇒ the installer's allowance: {record2['per_runner_disk_mb']}",
                )
                check(
                    "nothing installed yet" in record2["reading"],
                    f"and the reading must SAY so: {record2['reading']}",
                )
            finally:
                box2.destroy()
        finally:
            box.destroy()


@test("T25 the provisioner's refusal is a CONFLICT when this tool's arm says one more fits")
def t25_guard_conflict():
    """The two guards answer DIFFERENT questions — the installer provisions space for the WHOLE
    target plus its reserve, this pass adds ONE runner. When they disagree, the box needed capacity
    and got none, and the reason must be a verdict with both numbers, not an `action-failed` note
    (a scheduled pass would cry failure every 10 minutes) and not a silent refusal either."""
    with Env():
        box = Box("guard-conflict")
        try:
            box.install("gh-runner-x64", "r-1")
            box.alive([box.installs["gh-runner-x64"]])
            box.pool([("r-1", "online", False, ["self-hosted-x64", ra.FALLBACK_LABEL])])
            box.disk(9000)  # the measured 9G of the incident
            box.footprint({"gh-runner-x64": 2000})  # a real install is ~2G, not 8G
            check(ra.disk_allows_one_more(30_000, 2000) is True, "30G free holds a 2G runner")
            check(
                ra.disk_allows_one_more(21_000, 2000) is False,
                "21G free does NOT: the 20G reserve is the installer's, and it is respected",
            )
            # ⛔ THE REACHABLE CONFLICT: the box has room for the ONE runner this pass adds
            # (free 25G - 20G reserve >= 2G measured), and the installer still refuses because it
            # asks about the WHOLE target at its own 8G-per-runner allowance.
            # 36864MB free = 20480 reserve + TWO 8192 runners ⇒ ceiling 3 with 1 running
            box.disk(36_864)
            box.footprint({"gh-runner-x64": 2000})
            box.provisioner(
                rc=2,
                out="REFUSED: disk headroom: 25G free against 44G needed for 3 runners (+20G reserve)",
            )
            record = converge(box, nproc="8", want=3)
            check(
                record["verdict"] == "guard-conflict",
                f"a disagreement between the guards is its own verdict: {record['verdict']}",
            )
            conflict = next(n for n in record["notes"] if "GUARD CONFLICT" in n)
            check(
                "44G needed for 3 runners" in conflict and "free=36864MB" in conflict,
                f"both sides' numbers must be in the note: {conflict}",
            )
            check(
                "DISAGREE" in conflict and "does not interpret its prose" in conflict,
                f"…and it must not claim to know WHY the installer refused: {conflict}",
            )
            # a REAL pass (no --status): a dry run never calls the provisioner, so it cannot
            # discover a conflict at all — and the exit code is what a monitor reads
            code, out = cli(box, "--want", "3")
            check(code == 3, f"a conflict exits 3 (capacity was needed and not added), got {code}: {out}")
            check("verdict=guard-conflict" in out, f"and the verdict is printed: {out}")

            # ⛔ THE AGREEMENT BRANCH IS REACHABLE, and this is what makes it so: the ceiling is
            # computed ONCE but the fill RE-MEASURES the disk, so a box that filled up between the
            # two gets a refusal this tool's own arm AGREES with. The verdict must then be a plain
            # refusal (an answer), not a conflict page.
            box.disk_seq([36_864, 21_000])
            box.provisioner(rc=2, out="REFUSED: disk headroom: 21G free against 44G needed")
            record2 = converge(box, nproc="8", want=3)
            check(
                record2["verdict"] == "provisioner-refused",
                f"when the arm AGREES, a refusal is an answer, not a conflict: {record2['verdict']}",
            )
            check(
                "DISK arm also says the increment does not fit"
                in next(n for n in record2["notes"] if "REFUSED" in n),
                f"…and the note must say so: {record2['notes']}",
            )
            check(
                "blocked" not in record2["verdict"],
                "a refusal must never read as a failure",
            )
        finally:
            box.destroy()


# ── 7. THE REVIEW-ROUND-7 FINDINGS ────────────────────────────────────────────────────────────
@test("T26 a PROVISIONER REFUSAL must not silence the starvation alarm — it is the pass that exits 0")
def t26_refusal_does_not_silence_the_alarm():
    """MEASURED FAIL-OPEN (review round 7). The alarm's gate excluded `problem_kind`, so a pass whose
    provisioner refused never even read the queue — and the refusal leg returns **exit 0**, the
    documented "converged / nothing to do". Reproduced through the shipped CLI against this fixture:
    1 runner online and idle, 53 queued, and `verdict=provisioner-refused` with **rc=0** — the exact
    silent-green state the alarm exists to break (#2875).

    A refusal is ROUTINE and UNRELATED to the queue (the module says so itself: a scheduled pass must
    not cry failure every 10 minutes over a deliberate no), and the queue is still perfectly
    readable, so the alarm runs and OWNS the verdict. Both sets of numbers survive in the record."""
    with Env():
        box = Box("refusal-starved")
        try:
            box.install("gh-runner-x64", "r-1")
            box.alive([box.installs["gh-runner-x64"]])
            # ONLINE and IDLE while 53 runs wait — the invariant — and NO runner is busy.
            box.pool([("r-1", "online", False, ["self-hosted-x64", ra.FALLBACK_LABEL])])
            box.queued(53)
            # The AGREEMENT shape (T25's second branch): our disk arm also says one more does not
            # fit, so the verdict is the routine `refusal`, NOT a guard conflict.
            box.disk_seq([36_864, 21_000])
            box.provisioner(rc=2, out="REFUSED: disk headroom: 21G free against 44G needed")
            record = converge(box, nproc="8", want=3)
            check(
                record.get("problem_kind") == "refusal",
                "this fixture must exercise the REFUSAL leg (not a conflict): "
                f"{record.get('problem_kind')}",
            )
            check(
                record.get("starvation") == "starved",
                "the alarm must still be EVALUATED on a refused pass — a routine, unrelated event "
                f"cannot supply the compensating signal: {record.get('starvation')!r}",
            )
            check(
                record["verdict"] == "starvation",
                f"the alarm must OWN the verdict over the refusal: {record['verdict']}",
            )
            check(
                record.get("queued_runs") == 53
                and record.get("starvation_busy") == 0
                and record.get("starvation_online") == 1,
                "the counts must be MACHINE-readable, not only spelled into prose: "
                f"queued_runs={record.get('queued_runs')!r} busy={record.get('starvation_busy')!r} "
                f"online={record.get('starvation_online')!r}",
            )
            # ⛔ THE COMPENSATING SIGNAL MUST NOT BE LOST EITHER: the refusal keeps its own place in
            # the record (it is why no runner was added), even though it no longer sets the verdict.
            check(
                any("provisioner REFUSED" in n for n in record["notes"]),
                "the refusal must still be recorded (losing its verdict must not lose its "
                f"evidence): {record['notes']}",
            )
            # ⛔ THE `df` SEQUENCE COUNTER IS SHARED WITH THE FIRST PASS, and the CLI below is a
            # SECOND process: left alone it would read the LAST value (21G) and refuse `--want 3` on
            # the ceiling before any fill runs, which measures a different path than this case is
            # about. Resetting replays the shape the case declares: ceiling 3, then the box fills up.
            counter = os.path.join(box.dir, "df.count")
            if os.path.exists(counter):
                os.unlink(counter)
            code, out = cli(box, "--want", "3")
            check(
                code == 4,
                "a starved box must exit 4 (the one exit a health check pages on) even when the "
                f"provisioner refused: got {code}: {out[-400:]}",
            )
            contains(out, "verdict=starvation", "the human output")
        finally:
            box.destroy()


@test("T27 --check-units reads ExecStart with systemd's own semantics — accumulate, prefixes, skip")
def t27_audit_reads_execstart():
    """MEASURED FALSE PASS (review round 7) and the TWO defects its first fix had (round 2).

    `render_unit` pins `__file__`, which on a cell is a lane worktree under /tmp — the exact directory
    the fix refuses as a cwd. The unit then dies `203/EXEC` on every tick while the audit answered
    "all usable", because it only ever read `WorkingDirectory`. A unit whose PROGRAM a reclaim can
    take is not a scheduled converger.

    The first fix judged only the LAST `ExecStart=` and treated a bare name as a defect. Both are
    wrong against systemd.service(5), which the round-2 reviewer quoted and this case pins:
      * `ExecStart=` ACCUMULATES — only an EMPTY `ExecStart=` resets the list — so a later durable
        line does NOT remove an earlier transient one, and a drop-in that ADDS a command is not the
        remedy (the empty reset is). Reading only the last value reproduced the very false PASS the
        check was added to close.
      * a BARE program name is legitimate (systemd resolves it through its own compile-time search
        path), and an EXECUTABLE PREFIX (`@ - : + ! !!`) is not part of the path. The first version
        reported 39 of this box's own stock units (`systemd-tmpfiles`, `journalctl`, `udevadm`,
        `!!/usr/lib/systemd/systemd-networkd`) — an audit nobody could ever clear, on every pass.
    """
    with Env():
        box = Box("exec-audit")
        try:
            units = os.path.join(box.dir, "units")
            # ⛔ `Type=oneshot`, because that is the type where EVERY ExecStart line runs — and the
            # type this tool installs. Durable cwd, transient SCRIPT ARGUMENT (the `render_unit`
            # shape): the only finding must be the ExecStart one.
            Path(units, "bad.service").write_text(
                "[Service]\n"
                "Type=oneshot\n"
                "WorkingDirectory=/\n"
                'ExecStart="/usr/bin/python3" "/tmp/cell-ai/.worktrees/x/runner_autoscale.py" '
                '--repo "daniel-ospina/tortoise"\n',
                encoding="utf-8",
            )
            # ⛔ NOT `__file__` for the durable controls — the suite itself runs from a lane worktree
            # under /tmp, so it IS transient here and would (correctly) turn the control positive.
            Path(units, "good.service").write_text(
                "[Service]\n"
                "WorkingDirectory=/\n"
                'ExecStart="/usr/bin/python3" "/usr/bin/python3" --repo "o/r"\n',
                encoding="utf-8",
            )
            found = ra.installed_unit_cwd_problems([units], require_any=True)
            bad = [f for f in found if "bad.service" in f]
            check(
                any("ExecStart" in f and "/tmp" in f for f in bad),
                f"a transient ExecStart ARGUMENT must be NAMED as the reclaim risk it is: {found}",
            )
            check(
                any("fails on what it was told to run" in f for f in bad),
                f"…and it must say how the unit dies (the script it was told to run is gone): {found}",
            )
            check(
                not [f for f in found if "good.service" in f],
                f"a fully durable unit must stay CLEAN, or the finding is noise: {found}",
            )
            # The PROGRAM itself transient — that one dies 203/EXEC before any interpreter runs.
            Path(units, "prog.service").write_text(
                "[Service]\n"
                "WorkingDirectory=/\n"
                'ExecStart="/tmp/cell-wt-x/python3" "--version"\n',
                encoding="utf-8",
            )
            prog = [
                f
                for f in ra.installed_unit_cwd_problems([units], require_any=True)
                if "prog.service" in f
            ]
            check(any("203/EXEC" in f for f in prog), f"a transient PROGRAM dies 203/EXEC: {prog}")
            os.unlink(Path(units, "prog.service"))

            # (a) ⛔ AN APPEND IS NOT A REMEDY: systemd accumulates ExecStart, so the transient
            # command still runs and the finding must SURVIVE the drop-in.
            Path(units, "bad.service.d").mkdir()
            Path(units, "bad.service.d", "20-exec.conf").write_text(
                '[Service]\nExecStart="/usr/bin/python3" "/usr/bin/python3"\n',
                encoding="utf-8",
            )
            found = ra.installed_unit_cwd_problems([units], require_any=True)
            check(
                any("bad.service" in f for f in found),
                "a drop-in that APPENDS a durable ExecStart does NOT remove the transient one "
                f"(systemd runs both for Type=oneshot) — the finding must survive: {found}",
            )
            # (b) the EMPTY `ExecStart=` IS the reset, and it must clear the finding.
            Path(units, "bad.service.d", "20-exec.conf").write_text(
                '[Service]\nExecStart=\nExecStart="/usr/bin/python3" "/usr/bin/python3"\n',
                encoding="utf-8",
            )
            found = ra.installed_unit_cwd_problems([units], require_any=True)
            check(
                not [f for f in found if "bad.service" in f],
                "an EMPTY ExecStart= is the documented reset and must CLEAR the finding: "
                f"{found}",
            )
            os.unlink(Path(units, "bad.service"))
            shutil.rmtree(Path(units, "bad.service.d"))

            # (c) ⛔ THE STOCK SHAPES THAT MADE THE FIRST VERSION UNUSABLE: bare names, executable
            # prefixes, and a unit systemd SKIPS by condition. None of them is a finding.
            Path(units, "stock.service").write_text(
                "[Service]\nExecStart=systemd-tmpfiles --clean\n", encoding="utf-8"
            )
            Path(units, "prefix.service").write_text(
                "[Service]\n"
                "Type=oneshot\n"
                "ExecStart=!/usr/bin/true\n"
                "ExecStart=-/usr/bin/true\n"
                "ExecStart=@/usr/bin/true --version\n"
                "ExecStart=!!/usr/bin/true\n",
                encoding="utf-8",
            )
            Path(units, "cond.service").write_text(
                "[Unit]\nConditionPathExists=/nonexistent-for-this-case\n"
                "[Service]\nExecStart=/tmp/cell-wt-x/gone.sh\n",
                encoding="utf-8",
            )
            # …and the one that IS a defect in the non-oneshot case: systemd refuses the unit.
            Path(units, "multi.service").write_text(
                "[Service]\n"
                "ExecStart=/usr/bin/true\n"
                "ExecStart=/usr/bin/true\n",
                encoding="utf-8",
            )
            found = ra.installed_unit_cwd_problems([units], require_any=True)
            for clean in ("stock.service", "prefix.service", "cond.service"):
                check(
                    not [f for f in found if clean in f],
                    f"{clean} is a LEGITIMATE systemd shape and must not be reported: {found}",
                )
            check(
                any("multi.service" in f and "oneshot" in f for f in found),
                "two ExecStart= lines with Type=simple make systemd REFUSE the unit — that is a "
                f"finding: {found}",
            )
            # the CLI: a directory of only legitimate shapes must audit clean, exit 0
            clean_dir = os.path.join(box.dir, "clean-units")
            os.makedirs(clean_dir, exist_ok=True)
            for name in ("good.service", "stock.service", "prefix.service", "cond.service"):
                shutil.copy(Path(units, name), Path(clean_dir, name))
            os.environ["RUNNER_AUTOSCALE_UNIT_DIR"] = clean_dir
            box.env["RUNNER_AUTOSCALE_UNIT_DIR"] = clean_dir  # `cli()` passes box.env, not os.environ
            code, out = cli(box, "--check-units")
            check(
                code == 0,
                f"a stock-shaped population must audit clean (exit 0), got {code}: {out[-500:]}",
            )
        finally:
            box.destroy()


@test("T4b register(replace=False) still REFUSES — the clear-and-retry is confined to --replace")
def t4b_retry_is_confined_to_replace():
    """Review round 7. The retire commit removed the only pin on this arm while the branch changed it:
    the `already configured` retry cleared the local config EVEN WITHOUT `--replace`, and re-running
    `config.sh` without `--replace` does not adopt a registration — it CREATES a second one and
    leaves the old one a ghost in the pool (the state #2892 exists to clean up). So the heal is
    confined to the arm that has `--replace` to land it, and this case pins the refusal AND that the
    install was not touched."""
    with Env():
        box = Box("replace-false")
        try:
            path = box.install("gh-runner-x64", "r-dead")
            before = {
                name: Path(path, name).read_bytes()
                for name in (".runner", ".credentials", ".credentials_rsaparams")
            }
            box.apply()
            box.refusals(1)
            raised = None
            try:
                ra.register(Path(path), "r-dead", "daniel-ospina/tortoise", "self-hosted-x64", False)
            except ra.ActionFailed as exc:
                raised = str(exc)
            check(
                raised is not None,
                "replace=False must NOT clear-and-retry: without --replace the retry registers a "
                "SECOND runner and leaves a ghost. Expected ActionFailed.",
            )
            contains(raised, "already configured", "the refusal carries the runner's own words")
            calls = box.calls("config-calls.log")
            check(
                len([c for c in calls if "argv=" in c]) == 1,
                f"exactly ONE configure attempt (no retry without --replace): {calls}",
            )
            check(
                "call 1 local_runner=present" in calls,
                f"the local config must not have been cleared on this arm: {calls}",
            )
            after = {name: Path(path, name).read_bytes() for name in before}
            check(after == before, "the install must be byte-identical after the refused call")
        finally:
            box.destroy()


# ── 9. REVIEW CYCLE OF THIS LANE (2026-10-27) — ELIGIBILITY, SCHEDULING, IDENTITY, RECORDS ──────
@test("T33 a fallback-only queue is NOT starvation: the counts hold, the work is GitHub-hosted's")
def t33_starvation_eligibility_healthy():
    """MEASURED ON agent-infra 2026-10-27: `queued=14` sustained across the confirmation window while
    the pool was idle. That is the DESIGNED steady state of the fallback-only ruling — while the gate
    says `github`, `ubuntu-latest` belongs to GitHub-hosted, our pool deliberately does not advertise
    it, and every online runner is idle BY DESIGN. The old invariant (`queued>0 ∧ busy==0 ∧
    online>0`) paged exit 4 on that every ~9 minutes for ever, and noise is how the incident the
    alarm exists for (#2875) becomes invisible.

    The alarm's second half is ELIGIBILITY (`starvation_eligible`): the pool advertises the fallback,
    OR the gate wants `local`, OR the queue is at/above the gate's own backlog threshold."""
    with Env():
        box = Box("starve-ineligible")
        try:
            # The pool is up and idle; NOTHING advertises ubuntu-latest, and the gate says github.
            box.pool([("r-1", "online", False, ["self-hosted", "self-hosted-x64", "Linux"])])
            box.queued(14)
            box.gate_state("github")
            record = converge(box, want=0)
            check(
                record.get("starvation") == "ok",
                f"a GitHub-hosted backlog is not this pool's starvation: {record.get('starvation')}",
            )
            check(
                record.get("starvation_eligible") is False,
                f"the record must publish WHY it did not arm: {record}",
            )
            check(record["verdict"] != "starvation", f"verdict: {record['verdict']}")
            # ⛔ THE EVIDENCE SURVIVES THE VERDICT: the counts and the reason are still published.
            check(record.get("queued_runs") == 14, f"the counts must stay published: {record}")
            blob = " ".join(record["notes"])
            contains(blob, "starvation NOT armed", "the record")
            contains(blob, "GitHub-hosted", "the record")
            rc, out = cli(box, "--root", box.root, "--want", "0")
            check(rc == 0, f"a healthy fallback-only box must exit 0, got {rc}: {out[:300]}")
        finally:
            box.destroy()


@test("T34 the alarm STILL fires when the gate wants `local` and the label was stripped (#2875)")
def t34_starvation_gate_wants_local():
    """THE INCIDENT SHAPE, and the reason eligibility is not simply "does the pool carry the label":
    the pool had been STRIPPED while the gate was asking for the fallback (9 runners / 8 online /
    `busy=0` / 53 queued). A test keyed on the pool's own labels would have been silent on exactly the
    box the alarm exists for, so the gate's recorded intent is a term of its own."""
    with Env():
        box = Box("starve-stripped")
        try:
            box.pool([("r-1", "online", False, ["self-hosted", "self-hosted-x64", "Linux"])])
            box.queued(53)
            box.gate_state("local")
            record = converge(box, want=0)
            check(record.get("starvation") == "starved", f"the alarm must fire: {record}")
            check(record["verdict"] == "starvation", f"verdict: {record['verdict']}")
            check(
                record.get("starvation_eligible") is True,
                f"the gate's `local` makes the queue this pool's work: {record}",
            )
            contains(str(record.get("starvation_why")), "local", "the eligibility reason")
            rc, out = cli(box, "--root", box.root, "--want", "0")
            check(rc == 4, f"the alarm exits 4, got {rc}: {out[:300]}")
        finally:
            box.destroy()


@test("T35 a DISABLED schedule is not a schedule: commented cron, .disabled unit, masked unit")
def t35_disabled_schedule_is_not_scheduled():
    """`gate_scheduler_present()` turns a stale hand-run `local` record into a STANDING DECISION, so
    its evidence has to be a schedule systemd/cron will actually RUN. The first version matched a
    substring: a commented-out cron line (the standard disable), a `ci-runner-gate.service.bak`, and a
    MASKED unit (`ln -s /dev/null …`) all read as "scheduled", and every later repair then armed
    `ubuntu-latest` on a box with no gate left to strip it — the fallback-only incident made permanent
    and made to look deliberate. A LIVE cron line is the control that proves detection works."""
    with Env():
        box = Box("gate-schedule")
        try:
            home = os.path.join(box.dir, "gatehome")
            units = os.path.join(home, ".config", "systemd", "user")
            os.makedirs(units, exist_ok=True)
            box.env["RUNNER_AUTOSCALE_HOME"] = home
            cron = os.path.join(box.dir, "crontab")
            cron_body = os.path.join(box.dir, "crontab.txt")
            box._write(cron, f'#!/usr/bin/env bash\ncat "{cron_body}"\n', 0o755)
            box.env["RUNNER_AUTOSCALE_CRONTAB"] = cron
            box.gate_state("local")
            # Detection, not the override: the seam would mask the code under test.
            box.env.pop("RUNNER_AUTOSCALE_GATE_SCHEDULER", None)
            box.apply()

            # (a) the only cron line is COMMENTED OUT — the ordinary way a job is disabled.
            box._write(
                cron_body,
                "# disabled 2026-10-20: 0 * * * * /usr/local/bin/ci_runner_gate.sh\n",
            )
            check(
                ra.gate_scheduler_present() is False,
                "a commented-out cron line is not a schedule",
            )
            # (b) a unit file systemd would never load, and a MASK.
            box._write(os.path.join(units, "ci-runner-gate.service.disabled"), "[Service]\n")
            os.symlink(os.devnull, os.path.join(units, "ci-runner-gate.timer"))
            check(
                ra.gate_scheduler_present() is False,
                "a .disabled unit file and a masked unit are not schedules",
            )
            mode, why = ra.gate_desired_mode()
            check(mode is None, f"a record with no live scheduler is NOT intent: {(mode, why)}")
            contains(why, "NOTHING SCHEDULES", "the reason")
            check(
                ra.label_floor_binds({"r": ra.PoolEntry("r", "online", False, ["x"])}, mode)
                is False,
                "and the floor stays disarmed",
            )
            # (c) CONTROL: a live line IS a schedule, so (a) is not passing because detection is dead.
            box._write(cron_body, "0 * * * * /usr/local/bin/ci_runner_gate.sh\n")
            check(
                ra.gate_scheduler_present() is True,
                "a live cron line must be seen — otherwise the disables above prove nothing",
            )
            # (d) and a masked unit ALONE (no cron, no plist) is still not a schedule.
            box._write(cron_body, "")
            check(
                ra.gate_scheduler_present() is False,
                "a masked unit alone is not a schedule",
            )
            # (e) POSITIVE CONTROL FOR THE SYSTEMD ARM (review finding P2): with the mask gone and a
            # real `.service` installed, the answer must be True — otherwise (a)–(d) could all be
            # passing because the unit arm never returns True at all.
            os.unlink(os.path.join(units, "ci-runner-gate.timer"))
            box._write(os.path.join(units, "ci-runner-gate.service"), "[Service]\n")
            check(
                ra.gate_scheduler_present() is True,
                "an installed .service IS a schedule — the systemd arm must be able to say so",
            )
            # (f) the LAUNCHD arm, which is where this gate really runs: a MASKED plist
            # (`ln -s /dev/null …`, launchd's own way of not loading a job) is not a schedule, and a
            # real one IS (the positive control).
            os.unlink(os.path.join(units, "ci-runner-gate.service"))
            agents = os.path.join(home, "Library", "LaunchAgents")
            os.makedirs(agents, exist_ok=True)
            plist = os.path.join(agents, f"{ra.GATE_JOB_LABEL}.plist")
            os.symlink(os.devnull, plist)
            check(
                ra.gate_scheduler_present() is False,
                "a MASKED launchd plist is not a schedule",
            )
            os.unlink(plist)
            box._write(plist, "<plist/>\n")
            check(
                ra.gate_scheduler_present() is True,
                "an installed plist IS the evidence on a Mac — the launchd arm must say so",
            )
        finally:
            box.destroy()


@test("T36 an install this account cannot INSPECT is UNMEASURABLE — never a traceback")
def t36_discover_uninspectable_is_unmeasurable():
    """`discover()` runs FIRST and its OSError used to escape to `main()`'s backstop AFTER the repair
    loop may have acted — so a pass that had already restarted a runner exited 2 with NO `actions`
    field, losing the record of what it did. It also read an unreadable install as ABSENT (`glob`
    answers `[]` for a directory it cannot list), which registers a duplicate. `_inspect_path` gives
    the third answer, and the base probe is where a too-long root lands (ENAMETOOLONG needs no
    privileges, which is why it is the acceptance probe rather than a chmod)."""
    with Env():
        box = Box("discover-uninspectable")
        try:
            box.apply()
            try:
                ra.discover(_TOO_LONG)
            except ra.Unmeasurable as exc:
                contains(str(exc), "cannot", "the Unmeasurable reason")
            else:
                raise Failure("an uninspectable runner root must raise Unmeasurable, not read as empty")
            # CONTROL: a readable, empty root is still `[]` — absence and blindness differ.
            check(ra.discover(box.root) == [], "an empty readable root is empty, not unmeasurable")
            # ⛔ THE SHAPE THAT MATTERS — a root this account can STAT but cannot LIST. `Path.glob`
            # swallows that EACCES and answers `[]`, i.e. "this box has no runners" (review finding
            # P1), so the probe is `os.scandir`. Root can read anything, so this arm is stated rather
            # than silently skipped on such a box.
            if os.geteuid() != 0:
                denied = os.path.join(box.dir, "root-denied")
                os.makedirs(os.path.join(denied, "gh-runner-x64"), exist_ok=True)
                box._write(os.path.join(denied, "gh-runner-x64", ".runner"), "{}")
                os.chmod(denied, 0o000)
                try:
                    try:
                        ra.discover(denied)
                    except ra.Unmeasurable as exc:
                        contains(str(exc), "cannot be listed", "the Unmeasurable reason")
                    else:
                        raise Failure(
                            "an UNLISTABLE runner root read as an empty one — that is how a pass "
                            "registers duplicates over installs it could not enumerate"
                        )
                finally:
                    os.chmod(denied, 0o755)
        finally:
            box.destroy()


@test("T37 two installs that share an agent NAME: ONE registration, owned by a STABLE install")
def t37_repair_identity_is_the_directory():
    """A `cp -a` of an install keeps the same `agentName` in `.runner`, and `next(... name == ...)`
    then repaired the FIRST install on both iterations — the second `--replace` deleting the
    registration the first had just created — while the install that needed the repair was never
    touched, with the record attributing the action to it.

    ⛔ AND THE SERVER HOLDS ONE REGISTRATION PER NAME, SO "REPAIR BOTH" IS NOT THE FIX (review
    finding P2, round 12). Driving both installs with `--replace` in one pass still ends with the
    second call deleting the first's registration, and the record still claims two successes. Making
    the choice per-pass is no better: the pass that repairs the other install destroys the working
    registration, so the two flip every 9 minutes. The OWNER is the first install in the sorted order
    `discover()` returns — stable across passes — and every other install carrying that name is a
    REPORTED duplicate that a human must remove, never a repair target."""
    with Env():
        box = Box("dup-names")
        try:
            a = box.install("gh-runner-x64", "r-dup")
            b = box.install("gh-runner-x64-2", "r-dup")  # a cp -a: same agentName, own directory
            box.pool([])  # neither is in the pool: both ORPHANED
            box.alive([])

            record = converge(box, want=0)
            registrations = [c for c in box.calls("config-calls.log") if "argv=" in c]
            check(
                len(registrations) == 1,
                f"ONE registration per NAME — a second --replace deletes the first: {registrations}",
            )
            check(
                os.stat(os.path.join(a, ".runner")).st_mtime_ns != 0
                and any("registered r-dup" in act for act in record["actions"]),
                f"the OWNER (first in sorted order) is the install repaired: {record['actions']}",
            )
            # ⛔ THE DUPLICATE IS REPORTED — as a `problems` entry, because the box cannot be
            # converged until a human removes it, and silence is how a phantom install survives.
            dup = [p for p in record["problems"] if "agentName" in p]
            check(len(dup) == 1, f"the duplicate is NAMED, once: {record['problems']}")
            contains(dup[0], b, "the finding names the install that was NOT registered")
            contains(dup[0], "Remove the duplicate install", "…and what to do about it")
            check(
                b not in "".join(record["actions"]),
                f"…and no action claims it was registered: {record['actions']}",
            )
            check(record["verdict"] == "action-failed", f"the verdict: {record.get('verdict')}")
            # ⛔ AND THE CHOICE IS STABLE: a second pass repairs the SAME install, so the duplicate
            # cannot oscillate the registration between the two directories.
            record = converge(box, want=0)
            check(
                any("registered r-dup" in act for act in record["actions"]),
                f"the same owner is repaired again, never the duplicate: {record['actions']}",
            )
            check(
                sum(1 for c in box.calls("config-calls.log") if "argv=" in c) <= 3,
                "at most one registration per pass: "
                + str(box.calls("config-calls.log")),
            )
        finally:
            box.destroy()


@test("T38 a disk read that fails MID-PASS is recorded as UNVERIFIED, like the same at pass start")
def t38_midpass_disk_unverified():
    """One measurement failure had two record shapes depending on WHEN it happened: at pass start
    `unverified` + `unverified_cause` + exit 2; mid-pass only a prose note, falling through to
    `under-target` (exit 0). A fleet reader keyed on `unverified` saw nothing on the pass that
    STOPPED FILLING — the one that runs on a box whose disk is filling up."""
    with Env():
        box = Box("midpass-disk")
        try:
            first = box.install("gh-runner-x64", "r-1")
            box.alive([first])
            box.pool([("r-1", "online", False, ["self-hosted-x64", ra.FALLBACK_LABEL])])
            # `df` answers once (pass start) and FAILS from the second call (the fill re-read).
            counter = os.path.join(box.dir, "df.count")
            box._write(
                os.path.join(box.dir, "df"),
                "#!/usr/bin/env bash\n"
                f'C="{counter}"\n'
                'n=0; [ -f "$C" ] && n="$(cat "$C")"\n'
                'n=$(( n + 1 )); printf \'%s\\n\' "$n" > "$C"\n'
                '[ "$n" -ge 2 ] && { echo "df: cannot read table" >&2; exit 1; }\n'
                "printf 'Filesystem 1048576-blocks Used Available Capacity Mounted on\\n'\n"
                "printf '/dev/fixture 999999 1 500000 1%% /\\n'\n",
                0o755,
            )
            record = converge(box, nproc="4", want=2)
            check(record.get("unverified") is True, f"the record must say unverified: {record}")
            check(
                record.get("unverified_cause") == "disk-unreadable-midpass",
                f"and WHICH measurement: {record}",
            )
            check("disk_unverified" in record, f"the disk cause is named: {record}")
            # ⛔ THE RENDERED `error` MUST NAME THE DISK (review finding P2): the shared mid-pass
            # cause rendered "the box could not be re-measured AFTER AN INSTALL" for a `df` that
            # failed BEFORE the first slot.
            contains(str(record.get("error")), "disk free space", "the error")
            # ⛔ AND THE EXIT-CODE CONTRACT IS EXERCISED ON THE MID-PASS SHAPE, not on the pass-start
            # arm one call earlier (review finding P2): reset the `df` counter so the subprocess
            # repeats this pass rather than starting at its second call.
            if os.path.exists(os.path.join(box.dir, "df.count")):
                os.unlink(os.path.join(box.dir, "df.count"))
            rc, out = cli(box, "--root", box.root, "--want", "2")
            contains(out, "disk free space", "the CLI output")
            check(rc == 2, f"a pass that could not measure the disk is exit 2, got {rc}: {out[:300]}")
        finally:
            box.destroy()


@test("T39 a provisioner that reports success and installs NOTHING is an ACTION FAILURE")
def t39_provisioner_success_without_install():
    """`rc=0` with no new install is not a capacity answer and not a timing state: the one action the
    tool took did not do what it reported. The old code left the verdict at `under-target` → exit 0 —
    the documented "converged / nothing to do" — so an enforcer that failed to grow exited GREEN and
    only a `--json` reader could tell."""
    with Env():
        box = Box("fill-nothing")
        try:
            first = box.install("gh-runner-x64", "r-1")
            box.alive([first])
            box.pool([("r-1", "online", False, ["self-hosted-x64", ra.FALLBACK_LABEL])])
            box.provisioner(rc=0, out="nothing installed")
            record = converge(box, nproc="4", want=2)
            check(record["problems"], f"a provisioner that installed nothing is a problem: {record}")
            contains(" ".join(record["problems"]), "NO install appeared", "the problem")
            check(record["verdict"] == "action-failed", f"verdict: {record['verdict']}")
            rc, out = cli(box, "--root", box.root, "--want", "2")
            check(rc == 3, f"an action that did nothing is exit 3, got {rc}: {out[:300]}")
        finally:
            box.destroy()


@test("T40 a provisioner that MOVED is NAMED — the operator is not told to set a set seam")
def t40_moved_provisioner_names_the_value():
    """The pinned path is the most likely failure of the pin (a cell install from `/tmp`), and the old
    message printed a literal filename and advised setting `RUNNER_AUTOSCALE_PROVISIONER` — advice to
    set a variable that IS set, pointing at a value nobody named. `resolve_provisioner` now returns
    `(path, why)` and the caller prints it."""
    with Env():
        box = Box("provisioner-moved")
        try:
            gone = os.path.join(box.dir, "moved", "install-ci-runner-x64.sh")
            box.env["RUNNER_AUTOSCALE_PROVISIONER"] = gone
            box.apply()
            path, why = ra.resolve_provisioner()
            check(path is None, f"an absent pinned path resolves to nothing: {path!r}")
            contains(why, gone, "the reason")
            contains(why, "RUNNER_AUTOSCALE_PROVISIONER", "the reason")
            try:
                ra.provision(2)
            except ra.ActionFailed as exc:
                contains(str(exc), gone, "the ActionFailed message")
            else:
                raise Failure("an absent provisioner must raise ActionFailed")
        finally:
            box.destroy()


@test("T41 a PARTIAL `du` is still a measurement — it can only TIGHTEN the budget")
def t41_partial_du_tightens():
    """`du` prints a total for every argument it could read and exits 1 when any subdirectory was
    unreadable — measured: a root-owned file in a runner's `_work` produced both sizes AND rc=1. The
    old `rc != 0` arm threw the numbers away and fell back to the installer's 8 GB allowance, which is
    LOOSER than the truth whenever an install is bigger than 8 GB: the over-add the docstring says
    this arm can never allow."""
    with Env():
        box = Box("du-partial")
        try:
            path = box.install("gh-runner-x64", "r-1")
            box._write(
                os.path.join(box.dir, "du"),
                "#!/usr/bin/env bash\n"
                f"printf '20480\\t{path}\\n'\n"
                "echo 'du: cannot read directory: Permission denied' >&2\n"
                "exit 1\n",
                0o755,
            )
            box.apply()
            budget, basis = ra.disk_footprint_mb(box.root)
            check(budget == 20480, f"a partial measurement must TIGHTEN the budget, got {budget}")
            contains(basis, "PARTIAL", "the basis")
            contains(basis, "20480", "the basis")
            # CONTROL: NO number at all is still the allowance, and says so.
            box._write(
                os.path.join(box.dir, "du"),
                "#!/usr/bin/env bash\necho 'du: cannot read' >&2\nexit 1\n",
                0o755,
            )
            budget, basis = ra.disk_footprint_mb(box.root)
            check(budget == ra.FOOTPRINT_MB_DEFAULT, f"nothing measured ⇒ the allowance: {budget}")
            contains(basis, "NOT measured", "the basis")
        finally:
            box.destroy()


@test("T42 an ABSENT gate record is absence — not a read fault the operator must chase")
def t42_absent_gate_record_is_absence():
    """A cell's normal state is that NOTHING ever writes the record. Calling that "unreadable (No such
    file or directory)" sent an operator hunting permissions on a box where no file was ever meant to
    exist, while the docstring promised the two situations were told apart in the words."""
    with Env():
        box = Box("gate-absent")
        try:
            box.env["RUNNER_AUTOSCALE_GATE_STATE"] = os.path.join(box.dir, "never-written.state")
            box.apply()
            mode, why = ra.gate_desired_mode()
            check(mode is None, f"no record is no mode: {mode!r}")
            contains(why, "there is no gate record", "the reason")
            check("unreadable" not in why, f"absence must not be reported as a read fault: {why}")
        finally:
            box.destroy()


@test("T43 the gate's own backlog threshold is the alarm's third term — and the constant is PINNED")
def t43_deep_queue_threshold():
    """The third eligibility term exists for a queue nobody's labels explain: a DEEP backlog with an
    idle pool is worth a page whatever the pool advertises, and the number is the gate's own
    (`ci_runner_gate.sh:43`, `CI_GATE_QUEUE_THRESHOLD:-60`) rather than a second opinion invented
    here. Review finding P1: without this case the constant was documented as "PINNED BY THE SUITE"
    with zero references in it, so a drift from 60 — or the term being dropped — was invisible."""
    with Env():
        box = Box("starve-threshold")
        try:
            # The gate says `github` and the pool does NOT advertise the label: terms 1 and 2 are
            # both false, so only the THRESHOLD can make this queue the pool's work.
            box.pool([("r-1", "online", False, ["self-hosted", "self-hosted-x64", "Linux"])])
            box.gate_state("github")
            box.queued(ra.GATE_QUEUE_THRESHOLD)
            record = converge(box, want=0)
            check(record.get("starvation") == "starved", f"a deep backlog must alarm: {record}")
            check(record["verdict"] == "starvation", f"verdict: {record['verdict']}")
            check(record.get("starvation_eligible") is True, f"eligible: {record}")
            contains(
                str(record.get("starvation_why")),
                str(ra.GATE_QUEUE_THRESHOLD),
                "the eligibility reason (it must NAME the number it used)",
            )
            # …and it is a THRESHOLD, not a constant fire: one below it is GitHub-hosted's work.
            box.queued(ra.GATE_QUEUE_THRESHOLD - 1)
            below = converge(box, want=0)
            check(
                below.get("starvation") == "ok",
                f"one below the gate's threshold must not alarm: {below.get('starvation')}",
            )
            # ⛔ THE CONSTANT IS PINNED TO THE GATE'S OWN DEFAULT, read from the gate file itself —
            # a copy of a number in a second file is how the two drift apart in silence.
            gate_src = (Path(__file__).resolve().parents[2] / "scripts" / "ci_runner_gate.sh").read_text(
                encoding="utf-8"
            )
            m = re.search(r'CI_GATE_QUEUE_THRESHOLD:-([0-9]+)', gate_src)
            check(m is not None, "the gate must still declare CI_GATE_QUEUE_THRESHOLD's default")
            check(
                int(m.group(1)) == ra.GATE_QUEUE_THRESHOLD,
                f"GATE_QUEUE_THRESHOLD ({ra.GATE_QUEUE_THRESHOLD}) must equal the gate's own "
                f"default ({m.group(1)}) — the alarm and the gate must agree on what 'a backlog' is",
            )
        finally:
            box.destroy()


# ── the mutation map ──────────────────────────────────────────────────────────────────────────
class Mutation:
    def __init__(self, case_id, old, new, why):
        self.case_id = case_id
        self.old = old
        self.new = new
        self.why = why


# ── 8. THE REVIEW-FINDING CASES (2026-10-27) ────────────────────────────────────────────────────
# A path longer than PATH_MAX, rooted OUTSIDE every transient prefix, so the SHAPE check cannot be
# what fires: the only thing left for the tool to hit is `os.stat`'s ENAMETOOLONG.
_TOO_LONG = "/" + "a" * 300 + "/" + "/".join(["b" * 250] * 30)


@test("T28 a path this check CANNOT INSPECT is a finding — never a traceback, never an exemption")
def t28_uninspectable_path():
    """THE MEASURED DEFECT. `Path.is_dir()`/`Path.exists()` return False only for the errnos `pathlib`
    lists as absence (ENOENT, ENOTDIR, EBADF, ELOOP) and RE-RAISE everything else, so an unreadable
    path escaped as a traceback: `--check-units` over one unit whose `WorkingDirectory` sat under
    `/root` (audited by a non-root account) exited 1 with a PermissionError stack and NO verdict —
    and the audit runs on EVERY pass. A path over PATH_MAX does the same without needing privileges,
    which is why it is the fixture here."""
    check(len(_TOO_LONG) > 4096, "the fixture must exceed PATH_MAX")
    problem = ra.unit_workdir_problem(_TOO_LONG)
    check(problem is not None, "an uninspectable WorkingDirectory must be REFUSED")
    contains(problem, "cannot be inspected", "the workdir refusal")
    check(
        "does not exist" not in problem,
        f"it must not claim an absence it could not observe: {problem}",
    )
    exec_problems = ra.unit_exec_problems("x.service", [_TOO_LONG], "oneshot")
    check(
        any("cannot be inspected" in p for p in exec_problems),
        f"the ExecStart program arm must report it too: {exec_problems}",
    )
    # ⛔ THE EXEMPTION DIRECTION IS THE DANGEROUS ONE. `_condition_absent` exempts a unit from the
    # ExecStart check when a `Condition*=` path is missing — so reading "I could not look" as "the
    # condition is unmet" would declare a unit systemd may well start to be SKIPPED: a false PASS
    # inside the audit. The finding must survive.
    guarded = ra.unit_exec_problems(
        "x.service",
        ["/nonexistent-program-xyz/run"],
        "simple",
        [("ConditionPathExists", _TOO_LONG)],
    )
    check(
        any("does not exist" in p for p in guarded),
        f"an uninspectable condition must NOT exempt the unit: {guarded}",
    )
    with Env():
        box = Box("uninspectable")
        try:
            Path(box.dir, "units", "a.service").write_text(
                f"[Service]\nWorkingDirectory={_TOO_LONG}\nExecStart=/bin/true\n", encoding="utf-8"
            )
            code, out = cli(box, "--check-units")
            check(
                code == 5,
                f"--check-units must answer with a VERDICT (5 = findings), never a traceback (1): "
                f"rc={code}\n{out}",
            )
            contains(out, "cannot be inspected", "the audit's report")
            check("Traceback" not in out, f"…and never a traceback:\n{out}")
            # ⛔ AND THE BASE DIRECTORY ITSELF (review finding P2): an uninspectable
            # `RUNNER_AUTOSCALE_UNIT_DIR` used to raise out of `root.is_dir()` and exit 1, which is
            # the SAME code as "the audit found something" — a monitor could not tell them apart.
            box.env["RUNNER_AUTOSCALE_UNIT_DIR"] = _TOO_LONG
            code, out = cli(box, "--check-units")
            check(code == 5, f"an uninspectable unit dir is a FINDING, not a crash: rc={code}\n{out}")
            contains(out, "NOTHING was audited", "the aggregate finding")
            check("Traceback" not in out, f"…and never a traceback:\n{out}")
            # ⛔ AND `--install-unit`, which sits outside `main()`'s converge try. A provisioner seam
            # this account cannot inspect used to escape `Path(c).exists()` as a traceback and exit 1
            # — the SAME code as a deliberate refusal. It is now SKIPPED as a candidate (a path that
            # cannot be looked at is not a usable installer) and the run says so and installs a
            # repair-only unit, which is the honest outcome.
            box.env["RUNNER_AUTOSCALE_UNIT_DIR"] = os.path.join(box.dir, "units")
            box.env["RUNNER_AUTOSCALE_PROVISIONER"] = _TOO_LONG
            code, out = cli(box, "--install-unit")
            check("Traceback" not in out, f"an uninspectable seam must never traceback:\n{out}")
            check(code == 0, f"an uninspectable candidate is skipped, not fatal: rc={code}\n{out}")
            contains(out, "no install-ci-runner-x64.sh resolved", "the operator is told")
        finally:
            box.destroy()


@test("T29 the floor follows the GATE: `github` or no state file ⇒ NOT armed, and the record says why")
def t29_floor_follows_the_gate():
    """THE REVIEW'S P1, AND A RECORDED DECISION. `ci_runner_gate.sh:12` rules that this box serves CI
    as a FALLBACK only, and its header records the cost of ignoring that (jobs here compete with the
    agent fleet; a local pytest run crashed FalkorDB, 178 restarts). "No runner carries
    `ubuntu-latest`" is what a HEALTHY box looks like, because the gate strips the label whenever
    GitHub-hosted is fine — so a floor keyed on absence alone armed the label on every repair, and
    the gate stripped it again, forever."""
    arch_only = {
        "x86-1": ra.PoolEntry(
            name="x86-1", status="online", busy=False, labels=["self-hosted", ra.ARM_POOL_LABEL]
        )
    }
    check(ra.label_floor_binds(arch_only, "local") is True, "a gate that says local IS missing it")
    check(
        ra.label_floor_binds(arch_only, "github") is False,
        "a gate that says github must NOT arm it — that is the healthy state, not an outage",
    )
    check(ra.label_floor_binds(arch_only, None) is False, "no recorded mode is not a reason to arm")
    notes: list[str] = []
    got = ra.resolve_labels(arch_only, "x86_64", notes=notes, gate_mode="local")
    check(got == "self-hosted-x64,ubuntu-latest", f"local ⇒ armed: {got!r}")
    notes = []
    got = ra.resolve_labels(arch_only, "x86_64", notes=notes, gate_mode="github")
    check(got == "self-hosted-x64", f"github ⇒ NOT armed: {got!r}")
    check(
        len(notes) == 1 and "NOT armed" in notes[0],
        f"…and the refusal to arm must be SAID, not silent: {notes}",
    )
    # ⛔ THE GATE WINS OVER WHAT THE RUNNER ALREADY CARRIES (review finding P1, round 13). The cases
    # above all start from a pool that does NOT carry the fallback, so the one path that re-opened
    # the incident — a repair on a runner that still carries `ubuntu-latest` while the gate records
    # `github` — was never driven, even though the assertion above names the property it broke.
    carried = {
        "x86-1": ra.PoolEntry(
            name="x86-1",
            status="online",
            busy=False,
            labels=["self-hosted", ra.ARM_POOL_LABEL, ra.FALLBACK_LABEL],
        )
    }
    notes = []
    got = ra.resolve_labels(
        carried, "x86_64", notes=notes, current=["self-hosted-x64", ra.FALLBACK_LABEL], gate_mode="github"
    )
    check(got == "self-hosted-x64", f"github ⇒ a carried fallback is DROPPED, not re-asserted: {got!r}")
    check(
        len(notes) == 1 and "REMOVED" in notes[0],
        f"…and the removal must be SAID, not silent: {notes}",
    )
    # …and the same for a HOSTED image name — and this family is stripped in EVERY mode, because
    # `ci_runner_gate.sh` owns only `ubuntu-latest` (`:205`) and its `labels_for()` preserves every
    # other label, so NOTHING else would ever remove a mis-set `ubuntu-22.04`. A self-hosted runner
    # claiming it makes a hosted job run here on another OS: a false PASS, not a queue delay.
    for gate in ("github", "local", None):
        notes = []
        got = ra.resolve_labels(
            carried, "x86_64", notes=notes, current=["self-hosted-x64", "ubuntu-22.04"], gate_mode=gate
        )
        check(
            "ubuntu-22.04" not in got,
            f"{gate} ⇒ a carried ubuntu-<version> is DROPPED in every mode: {got!r}",
        )
        check(
            any("REMOVED" in x for x in notes),
            f"{gate} ⇒ …and the removal must be SAID, not silent: {notes}",
        )
    # `local` and a MISSING record must NOT strip it: the floor owns arming, and `None` is not intent
    # ("with no state file the pool stays exactly as the gate left it").
    got = ra.resolve_labels(
        carried, "x86_64", notes=[], current=["self-hosted-x64", ra.FALLBACK_LABEL], gate_mode="local"
    )
    check(
        ra.FALLBACK_LABEL in got,
        f"local ⇒ the carried fallback STAYS (the floor must not be stripped by the new term): {got!r}",
    )
    got = ra.resolve_labels(
        carried, "x86_64", notes=[], current=["self-hosted-x64", ra.FALLBACK_LABEL], gate_mode=None
    )
    check(
        ra.FALLBACK_LABEL in got,
        f"no gate record ⇒ the pool stays as the gate left it, never stripped: {got!r}",
    )
    # …and a custom/tier label is never touched by the new term: dropping one would make the
    # workflows targeting it queue for ever.
    got = ra.resolve_labels(
        carried, "x86_64", notes=[], current=["self-hosted-x64", "tier-gold"], gate_mode="github"
    )
    check(got == "self-hosted-x64,tier-gold", f"github ⇒ a custom label is still preserved: {got!r}")
    # end to end, with the gate's OWN file in the fixture: the registration must not carry the label
    # ⛔ A RECORD IS NOT A STANDING DECISION (review finding P1): the gate writes its mode only on a
    # TRANSITION, from a launchd job, and nothing schedules it on a cell — so one hand-run during
    # incident triage must not arm `ubuntu-latest` on every later repair for ever.
    with Env():
        box = Box("gate-unscheduled")
        try:
            box.install("gh-runner-x64", "r-dead")
            box.pool([("r-dead", "offline", False, ["self-hosted", "self-hosted-x64"])])
            box.alive([])
            box.gate_state("local", scheduled=False)
            record = converge(box, want=0)
            check(record.get("gate_mode") is None, f"an unscheduled record is not a mode: {record}")
            contains(
                str(record.get("gate_why")),
                "NOTHING SCHEDULES THE GATE",
                "the record must say WHY it refused to arm",
            )
            argv = [c for c in box.calls("config-calls.log") if "argv=" in c]
            check(argv, f"the repair still happens (preserving labels): {argv}")
            check(
                ra.FALLBACK_LABEL not in argv[0],
                f"a hand-run record must not arm the fallback: {argv[0]}",
            )
        finally:
            box.destroy()
    with Env():
        box = Box("gate-github")
        try:
            box.install("gh-runner-x64", "r-dead")
            box.pool([("r-dead", "offline", False, ["self-hosted", "self-hosted-x64"])])
            box.alive([])
            box.gate_state("github")
            record = converge(box, want=0)
            check(record.get("gate_mode") == "github", f"the record must publish the mode: {record}")
            argv = [c for c in box.calls("config-calls.log") if "argv=" in c]
            check(len(argv) == 1, f"expected one re-registration, got {argv}")
            check(
                ra.FALLBACK_LABEL not in argv[0],
                f"a healthy gate must not be overwritten by a repair: {argv[0]}",
            )
            check(record.get("label_floor_binds") is False, f"record: {record}")
        finally:
            box.destroy()


@test("T30 a seam that cannot be parsed is UNMEASURABLE naming it — and the pass still leaves a RECORD")
def t30_bad_seam_leaves_a_record():
    """TWO HALVES OF ONE MEASURED DEFECT. `int(os.environ[…])` on a seam raised ValueError, and
    `main()` caught only `Unmeasurable` — so a pass that may already have restarted and re-registered
    runners died with a traceback, exit 1, and `_log()` never called: no record of what it did. The
    seam is now a named `Unmeasurable`, and the backstop turns any other exception into a recorded
    verdict instead of silence."""
    with Env():
        box = Box("bad-seam")
        try:
            box.apply()
            os.environ["RUNNER_AUTOSCALE_POOL_READ_ATTEMPTS"] = "abc"
            try:
                ra.read_pool_retrying("daniel-ospina/tortoise")
            except ra.Unmeasurable as exc:
                contains(str(exc), "RUNNER_AUTOSCALE_POOL_READ_ATTEMPTS", "the seam is NAMED")
            else:
                raise Failure("an unparsable seam must raise Unmeasurable, not crash")
            # ⛔ AND THE RANGE, not only the syntax (review finding P2): `-1` parses, and then
            # `max(1, tries)` silently reduces the bounded retry this pass is built on.
            for seam, bad in (
                ("RUNNER_AUTOSCALE_POOL_READ_ATTEMPTS", "-1"),
                ("RUNNER_AUTOSCALE_ONLINE_WAIT_S", "-1"),
                ("RUNNER_AUTOSCALE_POLL_S", "-1"),
                ("RUNNER_AUTOSCALE_RETRY_BACKOFF_S", "-5"),
            ):
                os.environ[seam] = bad
                try:
                    if seam.endswith("BACKOFF_S"):
                        ra._env_float(seam, 2.0, minimum=0.0)
                    else:
                        ra._env_int(seam, 3, minimum=0)
                except ra.Unmeasurable as exc:
                    contains(str(exc), seam, "the seam is NAMED")
                    check(
                        "below" in str(exc) or "at or above" in str(exc),
                        f"…and the reason is the RANGE, not the syntax: {exc}",
                    )
                else:
                    raise Failure(f"{seam}={bad} must be REFUSED, not quietly applied")
                os.environ.pop(seam, None)
            os.environ.pop("RUNNER_AUTOSCALE_POOL_READ_ATTEMPTS", None)
            box.install("gh-runner-x64", "r-1")
            box.alive([box.installs["gh-runner-x64"]])
            # ⛔ THE INSTALL IS ALIVE AND THE POOL DOES NOT HAVE IT (ORPHANED): the pass therefore
            # performs its ONE DESTRUCTIVE ACTION — clear the local config and re-register with
            # `--replace` — which is the thing whose record the audit used to cost.
            box.pool([])
            original = ra.installed_unit_cwd_problems

            def boom(*_a, **_k):
                raise RuntimeError("the unit audit exploded")

            ra.installed_unit_cwd_problems = boom
            try:
                code = ra.main(["--root", box.root, "--want", "1"])
            finally:
                ra.installed_unit_cwd_problems = original
            # ⛔ ROUND 12: THE AUDIT IS A REPORTER, AND IT CAN NO LONGER COST THE PASS ITS RECORD.
            # The exception used to reach `main()`'s backstop, whose payload carries NO `actions` —
            # so exit 2 ("nothing was changed") was published over a pass that had just destroyed
            # and recreated a registration, which is the one claim that payload must never make. The
            # pass now COMPLETES (the box did converge; the audit could not run) and says so.
            check(
                code == 0,
                f"an audit failure is a FINDING, not the pass's verdict — a completed pass exits 0, "
                f"got {code}",
            )
            log = os.path.join(box.dir, "state", "runner-autoscale.log")
            check(
                os.path.exists(log),
                "the pass MUST leave a record — a timer that dies silently is the failure this "
                f"whole file refuses. looked for {log}",
            )
            with open(log, encoding="utf-8") as fh:
                body = fh.read()
            contains(body, "the unit audit exploded", "the record carries the cause")
            contains(body, "registered r-1", "…and the DESTRUCTIVE ACTION it performed")
            contains(body, "converged", "the record carries a VERDICT")
            # ⛔ AND THE BACKSTOP ITSELF IS STILL THE LAST RESORT (round 12 keeps BOTH halves). The
            # audit can no longer reach it, so the arm that must still be pinned is an unexpected
            # exception from `converge` ITSELF: `main()` must record a verdict instead of dying with
            # a bare traceback and an untouched log — the pass may already have acted.
            os.unlink(log)
            original_converge = ra.converge

            def explode(*_a, **_k):
                raise RuntimeError("the pass exploded unexpectedly")

            ra.converge = explode
            try:
                code = ra.main(["--root", box.root, "--want", "1"])
            finally:
                ra.converge = original_converge
            check(code == 2, f"an unrecorded crash is exit 2 (unmeasurable), got {code}")
            check(os.path.exists(log), f"…and it is RECORDED, not lost. looked for {log}")
            with open(log, encoding="utf-8") as fh:
                body = fh.read()
            contains(body, "the pass exploded unexpectedly", "the record carries the cause")
            contains(body, "unmeasurable", "the record carries a VERDICT")
        finally:
            box.destroy()


@test("T31 FILL success: ONE addition, at the NEXT FREE SLOT — the tool's primary action, measured")
def t31_fill_adds_one_runner():
    """THE ONE BRANCH WITH NO ACCEPTANCE TEST (review finding P2): every other provisioner call in
    this suite is the `rc=2` REFUSAL. So the action the tool exists for — growing a box — was
    unproven, including `_next_free_slot` (two measured over-fill incidents) and the argv the
    installer is actually given."""
    with Env():
        box = Box("fill")
        try:
            first = box.install("gh-runner-x64", "r-1")
            box.install("gh-runner-cell4-x64", "r-foreign")  # ad-hoc, NOT in the numbering
            box.alive([first])
            box.pool([("r-1", "online", False, ["self-hosted-x64", ra.FALLBACK_LABEL])])
            box.disk(500_000)
            slot = os.path.join(box.root, "gh-runner-x64-2")
            box._write(
                os.path.join(box.dir, "provisioner.sh"),
                "#!/usr/bin/env bash\n"
                f'printf "%s\\n" "$*" >> "{box.dir}/provisioner-calls.log"\n'
                f'mkdir -p "{slot}"\n'
                f'printf \'{{"agentName":"r-2"}}\' > "{slot}/.runner"\n'
                f'printf "%s\\n" "{slot}" >> "{box.dir}/alive.txt"\n'
                "exit 0\n",
                0o755,
            )
            record = converge(box, nproc="4", want=2)  # 4 cores ⇒ ceiling 2, one live ⇒ add ONE
            calls = box.calls("provisioner-calls.log")
            check(len(calls) == 1, f"one addition is ONE provisioner call, got {calls}")
            contains(calls[0], "--count 2", "the argv (the NEXT FREE SLOT, not the install count)")
            check(not record["problems"], f"a successful fill must not report a problem: {record}")
            check(
                any(a.startswith("installs ") or "provision" in a.lower() for a in record["actions"]),
                f"the record must say what was added: {record['actions']}",
            )
        finally:
            box.destroy()


@test("T32 a runner that came up with a JOB during the restart wait is NOT re-registered")
def t32_busy_reread_before_replace():
    """`wait_online` re-reads the POOL only — the view that already called the runner offline — and
    `--replace` DELETES a registration. A runner that comes up at the last second and takes a job
    would therefore lose it, against this file's own invariant ("a BUSY, SERVING or OTHER-REPO runner
    is never restarted"). The re-check has to be FRESH, too: the classification value is cached, and
    a cached `False` would certify exactly what the re-check exists to refuse."""
    with Env():
        box = Box("busy-reread")
        try:
            path = box.install("gh-runner-x64", "r-dead")
            box.pool([("r-dead", "offline", False, ["self-hosted-x64", ra.FALLBACK_LABEL])])
            box.alive([])
            # ⛔ NO busy-dirs seam here: that path is UNCACHED, so it could not show the stale cache
            # this case is about. A stateful `ps` answers "no worker" while the runner is judged and
            # "a worker" from then on — exactly a job starting during the wait.
            del box.env["RUNNER_AUTOSCALE_BUSY_DIRS"]
            counter = os.path.join(box.dir, "ps-count")
            box._write(
                os.path.join(box.dir, "ps"),
                "#!/usr/bin/env bash\n"
                f'n=$(cat "{counter}" 2>/dev/null || echo 0)\n'
                f'echo $((n+1)) > "{counter}"\n'
                f'if [ "$n" -ge 1 ]; then echo "Runner.Worker {path}/bin/Runner.Listener"; fi\n',
                0o755,
            )
            box.env["RUNNER_AUTOSCALE_PS"] = os.path.join(box.dir, "ps")
            record = converge(box, want=0)
            argv = [c for c in box.calls("config-calls.log") if "argv=" in c]
            check(argv == [], f"a runner serving a job must NOT be re-registered: {argv}")
            check(
                any("came up with a JOB" in n for n in record["notes"]),
                f"…and the pass must say so: {record['notes']}",
            )
            # ⛔ AND `actions` MUST NOT CLAIM IT (review finding P3): the line was appended before the
            # checks, so the record said "re-registering with --replace" while `notes` said the
            # opposite — and `actions` is what a human reads to learn if a registration was destroyed.
            check(
                not any("re-registering with --replace" in a for a in record["actions"]),
                f"the record must not assert an action that was not taken: {record['actions']}",
            )
        finally:
            box.destroy()


# ── 10. THE ROUND-11 REVIEW FINDINGS (2026-10-27) ─────────────────────────────────────────────────
# Five defects, found by a fresh-context reviewer at head 5e0011629. Each one is a place where this
# file's own prose was stronger than its code, and each fix ships with its case AND its mutation.


@test("T44 the queue's AGE is the term a CELL can measure — #2875's shape alarms there, a served backlog does not")
def t44_queue_age_eligibility():
    """THE FINDING THAT MATTERS MOST, because it is about the boxes this tool is INSTALLED on.

    `--install-unit` writes a SYSTEMD user unit, i.e. a cell — and on a cell `gate_desired_mode()` is
    `None` BY CONSTRUCTION (`gate_scheduler_present`: the gate is a launchd job; "nothing schedules the
    gate on a cell"). So the eligibility term that reads the gate is DEAD there, and the #2875 shape —
    the label STRIPPED pool-wide by the gate on another box, 53 queued, pool online and idle — fell
    through to the 60-deep threshold and reported `ok`, exit 0. The tool was written for an outage it
    could not see from the boxes it runs on.

    ⛔ AND THE FIX IS NOT "THE QUEUE IS NOT DRAINING": `queued=14` sustained across the confirmation
    window is the measured, HEALTHY steady state of the fallback-only ruling (round 9's own fix), so
    that term would re-arm the false alarm it removed. AGE separates them — a healthy GitHub-hosted
    scheduler serves in seconds-to-minutes — so both halves are asserted here: the starved queue pages,
    and the served backlog stays silent with the reason and the counts published.
    """
    with Env():
        box = Box("queue-age")
        try:
            box.install("gh-runner-x64", "r-1")
            box.alive([box.installs["gh-runner-x64"]])
            # #2875's own counts: the label is GONE from every runner (the gate on the hub stripped
            # it), the pool is online and IDLE, and 53 runs are waiting (below the gate's 60).
            box.pool([("r-1", "online", False, ["self-hosted", "self-hosted-x64"])])
            box.queued(53)
            # ⛔ ROW 0 IS NOT THE OLDEST (round-13 review finding P1). The runs endpoint is
            # newest-first and ignores `sort`/`direction`, so the page's first row is the run that
            # arrived a moment ago — and a queue STILL RECEIVING WORK is exactly #2875's shape. Pin
            # the newest row separately, or a reader of row 0 looks correct here and this case
            # certifies the very defect it exists to catch.
            box.queue_age(2400)  # 40 minutes — the OLDEST waiting run
            box.queue_age_newest(0)  # …while the NEWEST arrived just now
            record = converge(box, nproc="2", dry_run=True)
            check(
                record.get("starvation") == "starved",
                f"a 40-minute-old queue with an idle online pool IS starvation, whatever the gate "
                f"says: {record.get('starvation')} / {record.get('starvation_why')}",
            )
            check(record.get("starvation_eligible") is True, f"record: {record.get('starvation_why')}")
            contains(record.get("starvation_why", ""), "OLDEST queued run", "the reason names the AGE")
            check(
                record.get("starvation_queue_age_s") is not None
                and record["starvation_queue_age_s"] >= ra.STARVATION_QUEUE_AGE_S,
                f"the age is part of the evidence: {record.get('starvation_queue_age_s')}",
            )
            check(record.get("verdict") == "starvation", f"the verdict: {record.get('verdict')}")
            # ⛔ THE OTHER HALF: the SAME depth, a queue that is being served. Nothing about the
            # counts changed — only the age — and the alarm must stay silent, with the reason.
            box.queue_age(None)  # the oldest waiting run was created NOW
            record = converge(box, nproc="2", dry_run=True)
            check(
                record.get("starvation") == "ok",
                f"a backlog younger than the bound is GitHub-hosted's work, not this pool's: "
                f"{record.get('starvation')} / {record.get('starvation_why')}",
            )
            check(
                record.get("starvation_eligible") is False,
                f"…and it must not be ELIGIBLE: {record.get('starvation_why')}",
            )
            contains(
                record.get("starvation_why", ""),
                "younger than",
                "the reason must name the age bound it did not reach",
            )
            check(
                record.get("starvation_queued") == 53,
                f"the counts are published on BOTH verdicts: {record}",
            )
        finally:
            box.destroy()


@test("T56 the queue-head reader REFUSES every reading it cannot take — a lower bound and an empty page are not answers")
def t56_queue_age_reader_refusals():
    """THREE REFUSALS, AND WHY EACH EXISTS (round-13 review, both rounds).

    (a) A SATURATED PAGE. `min(created_at)` over a page IS the queue head only while the page holds
        the whole queue; beyond that it is a LOWER BOUND, which can only UNDERSTATE the age — the one
        direction that silences a starved-queue alarm. `ci_runner_gate.sh:315-324` refuses exactly this
        state for exactly this read.
        ⛔ PINNED AT THE UNIT BOUNDARY ON PURPOSE. In *this* tool the state is unreachable end to end:
        the age read is taken only after the depth term declines, i.e. at `queued <
        GATE_QUEUE_THRESHOLD` (60), and `QUEUE_AGE_PAGE` is 100. A case that faked `total_count=150`
        while the depth read reported 53 would assert an API response that cannot exist (both reads
        are the same endpoint) and would claim a false-open this tool cannot produce. The guard is
        kept for when the two numbers cross — the gate's threshold is operator-settable, its
        counterpart here is a constant — so it is tested where it is reachable: the reader itself.
        The mutation beside this case is what proves the test has teeth.

    (b) AN EMPTY PAGE ON A NON-EMPTY QUEUE. `None` means "nothing is waiting", and it DISARMS the age
        term; returning it because a `created_at` did not parse would report a backlog as an idle
        queue. `ci_runner_gate.sh:299` refuses the same combination by name.

    (c) AND THE REASON SURVIVES TO THE RECORD. A refusal that reaches a reader as a bare
        `unmeasured` with no cause cannot be acted on, and this path is REACHABLE — an unparsable
        timestamp on a shallow queue is exactly it. The counts the sample already measured must
        survive it too: `--json` reporting the depth as absent is the round-7 defect.
    """
    with Env():
        box = Box("queue-age-refusals")
        try:
            # (a) the saturated page — the reader, driven directly.
            box.apply()
            box.queue_age(60)
            box.queue_age_overflow(150)
            try:
                ra.read_oldest_queued_age_s("daniel-ospina/tortoise")
            except ra.Unmeasurable as exc:
                contains(str(exc), "LOWER BOUND", "the refusal must name WHY the min is not the head")
                contains(str(exc), "150", "…and the depth it could not measure")
            else:
                raise Failure(
                    "a saturated page must be REFUSED, not read as an age — the minimum of a page "
                    "that cannot hold the queue is only a lower bound on the head"
                )

            # (b) a page with no readable `created_at` on a queue that HAS runs.
            box.queue_age(None)
            box.queue_age_empty()
            box.queue_age_overflow(53)
            try:
                age = ra.read_oldest_queued_age_s("daniel-ospina/tortoise")
            except ra.Unmeasurable as exc:
                contains(str(exc), "53", "the refusal names how many runs are waiting")
                contains(
                    str(exc),
                    "not an empty queue",
                    "…and states that this is NOT the empty-queue answer, which is what `None` means",
                )
            else:
                raise Failure(
                    f"an unreadable created_at on a queue with 53 runs must not read as an empty "
                    f"queue (returned {age!r}) — `None` DISARMS the age term"
                )
            # …and the genuine empty queue still answers None, or the guard would break the healthy
            # case: no runs at all is `total_count=0` with an empty page, which IS "nothing waiting".
            box.queue_age_empty()
            box.queue_age_overflow(0)
            check(
                ra.read_oldest_queued_age_s("daniel-ospina/tortoise") is None,
                "an EMPTY queue is still `None` — the refusal must not swallow the one true answer",
            )

            # (c) the refusal reaches the RECORD with its cause and the counts it did measure.
            box.queue_age_empty(None)
            box.queue_age_overflow(None)
            box.queue_age_raw("not-a-timestamp")
            box.install("gh-runner-x64", "r-1")
            box.alive([box.installs["gh-runner-x64"]])
            box.pool([("r-1", "online", False, ["self-hosted", "self-hosted-x64"])])
            box.queued(53)
            record = converge(box, nproc="2", dry_run=True)
            check(
                record.get("starvation") == "unmeasured",
                f"an unreadable queue head cannot certify `ok`: {record.get('starvation')}",
            )
            check(
                record.get("starvation_eligible") is None,
                f"…nor may it claim eligibility either way: {record.get('starvation_eligible')}",
            )
            contains(
                record.get("starvation_why") or "",
                "created_at",
                "the refusal must carry its cause to the record, not a bare `unmeasured`",
            )
            check(
                record.get("queued_runs") == 53,
                f"and the depth the sample DID measure must survive the failed read — `--json` "
                f"reporting it as absent is the round-7 defect: {record.get('queued_runs')}",
            )
        finally:
            box.destroy()


@test("T45 a FAILED restart command is not 'offline': a runner the pool reports ONLINE is never --replace'd")
def t45_failed_restart_is_not_offline():
    """`wait_online` was called only when the restart COMMAND succeeded; on failure the pass set
    `state = "offline"` without asking the pool at all — and the pre-`--replace` guard tested `busy`
    only, never `online`. So a runner that reconnected while `sudo -n systemctl restart` returned
    non-zero (a routine transient on a loaded box: bus/dbus unavailable, manager busy) had its LIVE
    registration deleted, the record claimed "still offline after restart" about a question it never
    asked, and the pass exited 0 (`converged`)."""
    with Env():
        box = Box("restart-failed")
        try:
            box.install("gh-runner-x64", "r-dead")
            box.alive([])
            # Classification sees it offline; from the SECOND read on the pool reports it ONLINE.
            box.pool([("r-dead", "offline", False, ["self-hosted-x64", ra.FALLBACK_LABEL])])
            box.pool_then([("r-dead", "online", False, ["self-hosted-x64", ra.FALLBACK_LABEL])])
            box.systemctl_rc(1)  # `systemctl restart` exits 1 and never reaches the manager
            record = converge(box, nproc="2")
            check(
                not box.calls("config-calls.log"),
                f"a runner the pool reports ONLINE must never be re-registered: "
                f"{box.calls('config-calls.log')}",
            )
            check(
                any("the pool reports it ONLINE" in n for n in record["notes"]),
                f"…and the pass must say WHICH evidence stopped it: {record['notes']}",
            )
            check(
                any("restart COMMAND failed" in n for n in record["notes"]),
                f"…and that the restart command failed, since that is what it measured: "
                f"{record['notes']}",
            )
            check(
                not any("re-registering with --replace" in a for a in record["actions"]),
                f"the record must not claim an action that was not taken: {record['actions']}",
            )
        finally:
            box.destroy()


@test("T46 a unit entry this account cannot INSPECT is a finding — not a traceback that loses the pass's record")
def t46_uninspectable_unit_entry():
    """`_unit_files` was converted from `glob()` to `iterdir()` for the DIRECTORY, but the PER-ENTRY
    probe stayed `entry.is_dir()` — which re-raises everything outside `pathlib`'s absence errnos. A
    symlink in a unit directory pointing into a tree this account cannot traverse therefore escaped
    BOTH `--check-units` and the every-pass audit: on the pass path that is `main()`'s backstop, exit 2
    with no `actions` field — i.e. the record of a registration the pass had already destroyed is the
    part that gets lost, which is the exact mechanism round 9 fixed for `discover()` and left live at
    the audit that runs LAST."""
    with Env():
        box = Box("unit-entry")
        try:
            box._write(
                os.path.join(box.dir, "units", "a.service"),
                "[Service]\nWorkingDirectory=%h\nExecStart=/bin/true\n",
            )
            # ⛔ AN ENTRY WHOSE `stat` FAILS WITHOUT NEEDING PRIVILEGES. A symlink pointing THROUGH a
            # mode-000 directory: the link itself is listable, but following it is EACCES for its own
            # OWNER too, so `Path.is_dir()`/`os.stat` raise instead of returning an absence. (A
            # symlink TARGET cannot be made over-long — the filesystem returns ENAMETOOLONG at
            # creation — which is what `_TOO_LONG` is for in the WORKDIR probe, not here.)
            secret = os.path.join(box.dir, "secret")
            os.makedirs(secret, exist_ok=True)
            os.symlink(
                os.path.join(secret, "b.service"), os.path.join(box.dir, "units", "b.service")
            )
            os.chmod(secret, 0o000)
            # ⛔ THE MODE STAYS 000 FOR THE WHOLE CASE (review finding P2, round 12): it is the
            # FIXTURE, and the two halves below both need it. It is restored in the case's own
            # `finally` instead — restoring it here made the symlink resolve to a MISSING file
            # (`unreadable: No such file`) rather than to an INSPECTABLE one (`cannot be inspected`),
            # which silently measured a different defect.
            code, out = cli(box, "--check-units")
            check(
                code == 5,
                f"an uninspectable ENTRY is a finding (5), never a crash: rc={code}\n{out}",
            )
            contains(out, "cannot be inspected", "the audit names the entry")
            check("Traceback" not in out, f"…and never a traceback:\n{out}")
            # ⛔ AND THE PASS PATH: the audit runs at the end of every pass, so an exception here
            # costs the record its `actions` — after the repair loop may already have acted.
            box.install("gh-runner-x64", "r-1")
            box.alive([box.installs["gh-runner-x64"]])
            box.pool([("r-1", "online", False, ["self-hosted-x64"])])
            record = converge(box, nproc="2", dry_run=True)
            check("actions" in record, f"the pass must keep its record: {sorted(record)}")
            # ⛔ A NOTE + `unit_cwd_problems`, NOT a `problems` entry: a stale unit file must not turn
            # a healthy pool red (that trade is pinned elsewhere), so the finding is asserted where
            # this file actually carries it.
            findings = record.get("unit_cwd_problems") or []
            check(
                any("NOTHING was audited" in p for p in findings),
                f"…and the uninspectable entry is reported, not skipped: {findings}",
            )
        finally:
            # ⛔ RESTORE THE MODE BEFORE THE FIXTURE IS REMOVED, LIKE T36 DOES (review finding P2,
            # round 12). Without it the tree is unremovable by an unprivileged `rmtree`, so every run
            # leaked a `d---------` directory on the boxes whose disk budget this change exists to
            # respect. `Box.destroy()` now repairs such a tree as well (T54 pins that half).
            try:
                os.chmod(secret, 0o755)
            except OSError:
                pass
            box.destroy()


@test("T47 the unit's TimeoutStartSec is ABOVE a legitimate pass — systemd must never SIGTERM one mid-register")
def t47_unit_timeout_exceeds_pass_bounds():
    """The rendered unit claimed systemd's oneshot mutual exclusion as this CLI's only overlap guard,
    then set `TimeoutStartSec=1800` — which is SHORTER than the pass's own bounds: `provision` alone
    carries `timeout=1800`, a DEAD runner adds a 180 s restart plus a `wait_online` read, `config.sh`
    is 600 s and may run TWICE on the already-configured retry. systemd therefore SIGTERMs a healthy
    pass, and Python runs no `finally` on SIGTERM — so a kill inside `register()`'s
    clear → configure → restore window left the install with its `.runner` and RSA key DELETED (gone
    from `discover()`, its slot reading FREE to the provisioner, which adds a second install on top).
    The bound now clears the worst case; the signal assumption it rested on is pinned by T48."""
    units = ra.render_unit(repo="daniel-ospina/tortoise")
    service = next(body for name, body in units.items() if name.endswith(".service"))
    match = re.search(r"^TimeoutStartSec=(\d+)$", service, re.MULTILINE)
    check(match is not None, f"the unit must bound its own run: {service}")
    timeout = int(match.group(1))
    # The components are read from the code, not restated: a future bump to `provision`'s timeout
    # that is not reflected here is exactly the drift this case exists to catch.
    provision_timeout = 1800
    config_timeout = 600  # `_run(..., timeout=600)` inside `register`, twice on the retry
    enable_timeout = 180
    worst_case = provision_timeout + 2 * config_timeout + 2 * enable_timeout + 180
    check(
        timeout > worst_case,
        f"TimeoutStartSec={timeout} must exceed the pass's own worst case ({worst_case}s), or systemd "
        "kills a legitimate pass and a killed pass never restores the install it cleared",
    )
    contains(service, "TimeoutStartSec=5400", "the bound itself")


@test("T48 a SIGTERM inside the cleared window RESTORES the install — the stash is signal-safe, not only exception-safe")
def t48_sigterm_restores_stash():
    """T47 bounds the timeout, but a bound is not a guarantee: an operator `systemctl stop`, a
    shutdown, or a kill lands in the same window, and Python's DEFAULT SIGTERM disposition terminates
    the process WITHOUT running `finally`. `register()` therefore installs a handler that raises
    `SystemExit`, so the existing `finally` (`_restore_local_config`) actually runs. Measured here as a
    real signal delivered to a real process — a stubbed `signal.signal` call would prove the line
    exists, not that the install survives."""
    with Env():
        box = Box("sigterm-restore")
        try:
            path = box.install("gh-runner-x64", "r-term")
            before_mode = stat.S_IMODE(os.stat(os.path.join(path, ".credentials_rsaparams")).st_mode)
            config = os.path.join(path, "config.sh")
            # The installer signals its own parent (the tool) and then hangs, exactly like a
            # `config.sh` caught by a manager shutdown mid-registration.
            box._write(
                config,
                "#!/usr/bin/env bash\nkill -TERM " + "$PPID" + "\nsleep 5\n",
                0o755,
            )
            script = (
                "import importlib.util, pathlib, sys\n"
                f"spec = importlib.util.spec_from_file_location('ra_under_test', {ra.__file__!r})\n"
                "ra = importlib.util.module_from_spec(spec)\n"
                "sys.modules['ra_under_test'] = ra\n"
                "spec.loader.exec_module(ra)\n"
                "try:\n"
                f"    ra.register(pathlib.Path({path!r}), 'r-term', 'daniel-ospina/tortoise', "
                "'self-hosted-x64', True)\n"
                "except SystemExit as exc:\n"
                "    sys.exit(exc.code)\n"
            )
            box.apply()
            proc = subprocess.run(
                [sys.executable, "-c", script], env=_cli_env(box), capture_output=True, text=True
            )
            check(
                proc.returncode == 128 + 15,
                f"the handler must convert SIGTERM into an exit code (143), got {proc.returncode}:\n"
                f"{proc.stdout}\n{proc.stderr}",
            )
            check(
                os.path.exists(os.path.join(path, ".runner")),
                "a killed pass must not leave the install without its `.runner` — `discover()` would "
                "stop seeing it and the provisioner would count its slot FREE",
            )
            for name in (".credentials", ".credentials_rsaparams"):
                check(
                    os.path.exists(os.path.join(path, name)),
                    f"{name} is part of the stash and must be restored too",
                )
            # ⛔ "NOT WIDENED" IS MEASURED AGAINST WHAT IT WAS, not against a literal: the stash holds
            # `(mode, bytes)`, so the invariant is that a kill restores the mode the install had.
            mode = stat.S_IMODE(os.stat(os.path.join(path, ".credentials_rsaparams")).st_mode)
            check(
                mode == before_mode,
                f"and restored at its original mode ({oct(before_mode)}), not {oct(mode)}",
            )

            # ⛔ AND THE WINDOW THIS CASE COULD NOT SEE (round-13 review finding P2). T48's signal
            # arrives from `config.sh`, i.e. AFTER the handler is installed, so it passes over the
            # window the handler was installed too late for: the CLEAR itself. The handler used to be
            # installed only once `_clear_local_config` had RETURNED, so a SIGTERM inside the unlink
            # loop still ran under the default disposition and terminated without unwinding — the
            # stash dropped mid-unlink and the install left without `.runner`. Delivered here the way
            # it actually happens (a manager SIGTERM racing a legitimate pass), from inside the loop.
            inclear = Box("sigterm-in-clear")
            try:
                path2 = inclear.install("gh-runner-x64", "r-inclear")
                script2 = (
                    "import importlib.util, pathlib, signal, sys\n"
                    f"spec = importlib.util.spec_from_file_location('ra_in_clear', {ra.__file__!r})\n"
                    "ra = importlib.util.module_from_spec(spec)\n"
                    "sys.modules['ra_in_clear'] = ra\n"
                    "spec.loader.exec_module(ra)\n"
                    "real = pathlib.Path.unlink\n"
                    "fired = []\n"
                    "def boom(self, *a, **k):\n"
                    "    real(self, *a, **k)\n"
                    "    if not fired:\n"
                    "        fired.append(1)\n"
                    "        signal.raise_signal(signal.SIGTERM)\n"
                    "pathlib.Path.unlink = boom\n"
                    "try:\n"
                    f"    ra.register(pathlib.Path({path2!r}), 'r-inclear', "
                    "'daniel-ospina/tortoise', 'self-hosted-x64', True)\n"
                    "except SystemExit as exc:\n"
                    "    sys.exit(exc.code)\n"
                    "sys.exit(0)\n"
                )
                inclear.apply()
                proc2 = subprocess.run(
                    [sys.executable, "-c", script2],
                    env=_cli_env(inclear),
                    capture_output=True,
                    text=True,
                )
                check(
                    proc2.returncode == 128 + 15,
                    f"a signal INSIDE the clear must unwind as 143, not kill the process outright "
                    f"(got {proc2.returncode}):\n{proc2.stdout}\n{proc2.stderr}",
                )
                for name in (".runner", ".credentials", ".credentials_rsaparams"):
                    check(
                        os.path.exists(os.path.join(path2, name)),
                        f"a signal inside the CLEAR must still restore {name} — the handler has to be "
                        "installed BEFORE the destructive step, not after it returns",
                    )
            finally:
                inclear.destroy()
        finally:
            box.destroy()


@test("T49 a failed CONFIRM read keeps the first sample — 'unmeasured' must not erase what was seen")
def t49_confirm_failure_keeps_first_sample():
    """Both samples sat inside ONE `try`, so a one-off API blip on the confirmation read returned
    `{'state': 'unmeasured'}` with EVERY count absent — indistinguishable from "the queue was never
    readable", and it threw away an observation that had already answered "yes". It also silently
    dropped `queued_runs`, the field `origin/main` publishes for fleet readers. The state stays
    `unmeasured` (one blip is not a page), but the record now carries what was seen and names the
    confirm failure apart from the read that succeeded."""
    with Env():
        box = Box("confirm-blip")
        try:
            box.install("gh-runner-x64", "r-1")
            box.alive([box.installs["gh-runner-x64"]])
            box.pool([("r-1", "online", False, ["self-hosted-x64"])])
            box.queued(53)
            box.queue_age(2400)
            # The FIRST pass-start read is healthy; every read after it fails (the steps repeat).
            # ⛔ THE THIRD READ: the pass classifies from the pool first, the probe's FIRST sample is
            # the second read, and the CONFIRMATION is the third — that is the one that must blip.
            box.pool_seq(["ok", "ok", "err:dial tcp 10.0.0.9:443: i/o timeout (fixture)"])
            record = converge(box, nproc="2", dry_run=True)
            check(
                record.get("starvation") == "unmeasured",
                f"one sample is not a page: {record.get('starvation')}",
            )
            check(
                record.get("starvation_queued") == 53,
                f"the first sample's counts must SURVIVE the failed confirmation: {record}",
            )
            check(
                record.get("queued_runs") == 53,
                f"…including the field a fleet reader consumes: {record.get('queued_runs')}",
            )
            contains(
                record.get("starvation_confirm_error", ""),
                "i/o timeout",
                "the confirm failure is named SEPARATELY from the read that succeeded",
            )
            check(
                any("CONFIRMATION read failed" in n for n in record["notes"]),
                f"…and the pass says it out loud: {record['notes']}",
            )
        finally:
            box.destroy()


@test("T50 a `~user` WorkingDirectory this account cannot resolve is a FINDING — never a traceback")
def t50_unresolvable_home_workdir():
    """`pathlib.Path.expanduser()` RAISES (`RuntimeError: Could not determine home directory.`)
    for a `~user` the account cannot resolve, while `os.path.expanduser` returns the argument
    unchanged. `WorkingDirectory=~someone/x` is legal systemd syntax and the audit exists precisely
    to read FOREIGN/hand-written units, so this input is reachable by design — and the audit runs
    AFTER the repair loop, so the raise landed in `main()`'s backstop, whose payload carries no
    `actions`: exit 2, "nothing was changed", over a pass that had just destroyed and recreated a
    registration. A path that cannot be resolved is a finding, not a crash."""
    with Env():
        box = Box("workdir-home")
        try:
            box.apply()
            problem = ra.unit_workdir_problem("~nosuchuser9/x")
            check(isinstance(problem, str) and problem, f"a finding, not a crash: {problem!r}")
            contains(problem, "cannot resolve", "the finding names the cause")
            # ⛔ THE CONTROL: the tool's OWN template (`%h`) and a resolvable `~/x` must not be
            # reported as unresolvable — a guard that refused every `~` would refuse the default.
            check(
                "cannot resolve" not in (ra.unit_workdir_problem("%h") or ""),
                "`%h` is the template's own shape, not a resolution failure",
            )
            check(
                "cannot resolve" not in (ra.unit_workdir_problem("~/x") or ""),
                "a resolvable home is resolved, not reported as unresolvable",
            )
            # THE AUDIT — which runs at the end of EVERY pass — reports it instead of raising.
            box._write(
                os.path.join(box.dir, "units", "ghost.service"),
                "[Service]\nWorkingDirectory=~nosuchuser9/x\nExecStart=/bin/true\n",
            )
            findings = ra.installed_unit_cwd_problems()
            check(
                any("cannot resolve" in f for f in findings),
                f"the audit reports the unresolved home instead of raising: {findings}",
            )
            # ⛔ THE PASS: a DEAD runner is repaired, and the record KEEPS the action in the same
            # record that carries the unit finding — "an audit may not lose the record".
            box.install("gh-runner-x64", "r-1")
            box.alive([])  # no listener ⇒ DEAD once the pool reports it offline
            box.pool([("r-1", "offline", False, ["self-hosted-x64", ra.FALLBACK_LABEL])])
            record = converge(box, nproc="2")
            check(record.get("actions"), f"the repair is in the record: {record}")
            check(
                any("cannot resolve" in p for p in (record.get("unit_cwd_problems") or [])),
                f"…and the unit finding is in the SAME record: {record.get('unit_cwd_problems')}",
            )
            check(
                record.get("verdict") != "unmeasurable",
                f"a unit finding is not the pass's verdict: {record.get('verdict')}",
            )
        finally:
            box.destroy()


@test("T51 --status on a box whose OWN classification says DEAD is not `converged`")
def t51_status_does_not_launder_a_dead_runner():
    """`actions` is the record of what the pass DID, and the verdict chain reads it to tell
    `converged` ("we acted and are at the target") from `at-ceiling` ("nothing to do"). A dry run
    appended `would repair …` INTO `actions`, so a read-only `--status` on a box whose own printout
    says `DEAD r-3` reported `verdict=converged`, exit 0 — the exact word a monitor keys on, for a
    degraded pool a real pass would repair. Hypotheticals now live in `would_repair`, and a box with
    an outstanding repair cannot be `converged`."""
    with Env():
        box = Box("status-dead")
        try:
            up = [box.install("gh-runner-x64", "r-1"), box.install("gh-runner-x64-2", "r-2")]
            degraded = box.install("gh-runner-x64-3", "r-3")
            box.alive(up)  # r-3's listener is GONE and the pool says offline ⇒ DEAD
            box.pool(
                [
                    ("r-1", "online", False, ["self-hosted-x64"]),
                    ("r-2", "online", False, ["self-hosted-x64"]),
                    ("r-3", "offline", False, ["self-hosted-x64"]),
                ]
            )
            record = converge(box, nproc="8", want=2, dry_run=True)
            check(record["actions"] == [], f"a read-only pass performs NOTHING: {record['actions']}")
            check(
                any("would repair r-3" in w for w in record["would_repair"]),
                f"the outstanding repair is named: {record.get('would_repair')}",
            )
            check(
                record["verdict"] != "converged",
                f"a box with a DEAD runner is NOT converged: {record['verdict']}",
            )
            check(record["verdict"] == "at-ceiling", f"the verdict: {record['verdict']}")
            contains(
                " ".join(record["notes"]),
                "NOT converged",
                "the note says the box is not converged, out loud",
            )
            # ⛔ AND THROUGH THE CLI, where a health check actually reads it.
            rc, out = cli(box, "--status", "--want", "2", "--root", box.root)
            contains(out, "would repair r-3", "the read-only plan names the degraded install")
            check("verdict=converged" not in out, f"…and never claims convergence:\n{out}")
            check(rc == 0, f"--status is read-only and exits 0, got {rc}")
            # ⛔ THE CONTROL: the same box with that runner HEALTHY has NOTHING outstanding, so this
            # is not a case that reds every read-only pass.
            box.alive([*up, degraded])
            box.pool(
                [
                    ("r-1", "online", False, ["self-hosted-x64"]),
                    ("r-2", "online", False, ["self-hosted-x64"]),
                    ("r-3", "online", False, ["self-hosted-x64"]),
                ]
            )
            record = converge(box, nproc="8", want=2, dry_run=True)
            check(record["would_repair"] == [], f"a healthy box plans no repair: {record}")
            check(
                all(r["state"] != "DEAD" for r in record["runners"]),
                f"…because nothing is degraded: {[r['state'] for r in record['runners']]}",
            )
        finally:
            box.destroy()


@test("T52 the registration token is the LAST LINE OF STDOUT — a stderr advisory is not a token")
def t52_token_comes_from_stdout():
    """`_run` concatenates stdout THEN stderr, and `registration_token()` read the last line of that
    merged text. Any advisory `gh` writes to stderr on an otherwise-successful mint therefore BECAME
    the token (`gh: warning: this token expires in 1 hour`), so `config.sh` rejected it, `register()`
    raised `ActionFailed` on every pass, and the record blamed the runner's own tooling — the repair
    path silently dead on exactly the boxes it exists for."""
    with Env():
        box = Box("token-stream")
        try:
            box.apply()
            # A SUCCESSFUL mint whose stderr carries an advisory: stdout still holds the token.
            box._write(os.path.join(box.dir, "token.advisory"), "1\n")
            check(
                ra.registration_token("daniel-ospina/tortoise") == "tok-fixture",
                "the token is the STDOUT value, not the stderr advisory",
            )
            # ⛔ AND A STDOUT LINE THAT IS NOT A TOKEN IS REFUSED, never passed on: the same guard,
            # on the stream that does carry the value (a token has no whitespace in it).
            box._write(os.path.join(box.dir, "token.stdout"), "tok-fixture\ngh: warning: rotated\n")
            try:
                ra.registration_token("daniel-ospina/tortoise")
            except ra.ActionFailed as exc:
                contains(str(exc), "stdout=", "the refusal shows what was actually printed")
            else:
                raise Failure("a second stdout line was accepted as part of the token")
            # ⛔ AND THE REPAIR IT BLOCKED: with the advisory present a DEAD runner IS repaired.
            os.unlink(os.path.join(box.dir, "token.stdout"))
            box.install("gh-runner-x64", "r-1")
            box.alive([])
            box.pool([("r-1", "offline", False, ["self-hosted-x64", ra.FALLBACK_LABEL])])
            record = converge(box, nproc="2")
            check(
                any("registered r-1" in a for a in record["actions"]),
                f"a repr with an advisory mint still registers: {record['actions']} / "
                f"{record['problems']}",
            )
        finally:
            box.destroy()


@test("T53 a suite run writes NO bytecode into the checkout — a green run must not dirt the pin")
def t53_no_bytecode_in_the_checkout():
    """`sys.dont_write_bytecode = True` at the top of this file is a PER-PROCESS flag, so it does
    nothing for a CHILD interpreter — and T48's child imports the module under test by path. The
    child wrote `__pycache__/runner_autoscale.cpython-312.pyc` INTO THE CHECKOUT, which `pin_dirty`
    does not tolerate (only `.DS_Store`/`._*` are excused): a GREEN suite run made `harness-exec.sh`
    refuse ("the pinned tree has UNCOMMITTED CHANGES") and `cloud-cell-supervisor check` die DRIFT,
    and the remedy both messages offer — commit or discard — cannot be applied to a gitignored file.

    ⛔ NO PRODUCTION MUTANT CAN EXIST FOR THIS CASE: the guarantee lives in this harness (`_cli_env`
    puts `PYTHONDONTWRITEBYTECODE=1` into every child), not in the module under test. It is stated
    here so a reader does not count it as verified-by-mutation."""
    with Env():
        box = Box("bytecode")
        try:
            check(
                _cli_env(box).get("PYTHONDONTWRITEBYTECODE") == "1",
                "every child this suite spawns must inherit PYTHONDONTWRITEBYTECODE=1",
            )
            script = (
                "import importlib.util, sys\n"
                f"spec = importlib.util.spec_from_file_location('ra_under_test', {ra.__file__!r})\n"
                "m = importlib.util.module_from_spec(spec)\n"
                # Registered BEFORE exec: `@dataclass` resolves annotations through
                # `sys.modules[cls.__module__]` (the same reason `_load_module` does it).
                "sys.modules['ra_under_test'] = m\n"
                "spec.loader.exec_module(m)\n"
            )
            # ⛔ THE MODULE'S OWN DIRECTORY, which under `--mutations` is the mutant's temp dir and in
            # a plain run IS the checkout — the same code path, measured where the child would write.
            pycache = os.path.join(os.path.dirname(os.path.abspath(ra.__file__)), "__pycache__")
            before = set(os.listdir(pycache)) if os.path.isdir(pycache) else set()
            proc = subprocess.run(
                [sys.executable, "-c", script],
                env=_cli_env(box),
                capture_output=True,
                text=True,
            )
            check(proc.returncode == 0, f"the child ran ({proc.returncode}): {proc.stderr[:300]}")
            after = set(os.listdir(pycache)) if os.path.isdir(pycache) else set()
            check(
                after == before,
                f"a child wrote {sorted(after - before)} into {pycache} — a green run would leave "
                "the pinned harness dir DIRTY and block the cell's own harness-exec",
            )
        finally:
            box.destroy()


@test("T54 Box.destroy() removes a fixture that still carries a mode-000 directory")
def t54_destroy_removes_unreadable_tree():
    """`shutil.rmtree(..., ignore_errors=True)` REPORTED SUCCESS while leaving the tree: a case that
    makes a directory mode-000 and does not restore it (T46 did exactly that) leaked one
    `$TMPDIR/runnerauto-*` per run, each holding a `d---------` directory an unprivileged `rm -rf`
    cannot remove either — a permanent disk leak on exactly the boxes whose disk budget this change
    exists to respect, and "`Box.destroy()` cleans up" was verified by no case at all.

    ⛔ NO PRODUCTION MUTANT CAN EXIST FOR THIS CASE either: `destroy()` is harness code."""
    box = Box("destroy-unreadable")
    secret = os.path.join(box.dir, "secret")
    os.makedirs(secret, exist_ok=True)
    box._write(os.path.join(secret, "b.service"), "[Service]\nWorkingDirectory=%h\n")
    os.chmod(secret, 0o000)
    path = box.dir
    try:
        box.destroy()
    finally:
        if os.path.exists(path):  # do not leak the leak
            os.chmod(secret, 0o755)
            shutil.rmtree(path, ignore_errors=True)
    check(not os.path.exists(path), f"{path} survived destroy() — a green run would leak it")


@test("T55 a credential RESTORE that writes SHORT, or fails, is reported — never silent")
def t55_restore_cannot_lose_the_key_quietly():
    """THE OTHER HALF OF FIX 2's FAILURE LEG (review finding P2, reproduced at the reviewed head).
    `_restore_local_config` stashes `(mode, bytes)` and puts them back — but it called `os.write`
    ONCE and IGNORED the return, and its `except OSError` was `pass`.

    Both are silent, and both land on the box that is out of space, which is exactly the state the
    disk arm exists for: `os.write` returns a SHORT COUNT under ENOSPC and raises NOTHING, so
    `.credentials_rsaparams` — the runner's RSA PRIVATE KEY — was left TRUNCATED with no exception
    (measured: 16 of 1,263 bytes). And a restore that failed outright returned `None`, so the caller
    could not tell it from success and the record named only the ORIGINAL failure while the install
    had lost `.runner` too — `discover()` stops seeing it, its slot reads FREE, and the next pass
    adds a SECOND install over the top.
    """
    key = b"K" * 1263
    stash = {".runner": (0o644, b"R" * 1000), ".credentials_rsaparams": (0o600, key)}
    real_write = os.write
    real_open = os.open
    # ⛔ BOUND BEFORE THE `try` AND CLEANED UP INDIVIDUALLY (review finding P2, round 3). With the
    # three names bound inside the `try`, a `check()` that failed before the LAST assignment made the
    # `finally` build a tuple containing an unbound name: the cleanup raised `UnboundLocalError`,
    # which SUPERSEDES the real failure — so a red T55 reported a variable-binding bug instead of
    # "a short write must still land every byte", discarded the `Failure:` text the harness prints
    # (`exc.__class__.__name__`), and left the fixtures it had already made on disk. That is exactly
    # the evidence this round's mutations exist to provide.
    short = stuck = gone = None
    try:
        # (1) A SHORT WRITE IS LOOPED, and every byte lands. `bytes(b)[:16]` makes each call return
        # 16, which is the ENOSPC shape without a real full disk.
        short = tempfile.mkdtemp(prefix="restore-short-")

        def short_write(fd, buf):
            return real_write(fd, bytes(buf)[:16])

        os.write = short_write
        problems = ra._restore_local_config(short, stash)
        check(problems == [], f"a short write must be LOOPED, not reported: {problems}")
        sizes = {n: os.stat(os.path.join(short, n)).st_size for n in stash}
        check(
            sizes == {n: len(d) for n, (_, d) in stash.items()},
            f"a short write must still land every byte — a truncated RSA key is silent corruption: "
            f"{sizes}",
        )
        modes = {n: oct(os.stat(os.path.join(short, n)).st_mode & 0o777) for n in stash}
        check(
            modes == {".runner": "0o644", ".credentials_rsaparams": "0o600"},
            f"the loop must not lose the stashed mode either: {modes}",
        )

        # (2) NO PROGRESS is a failure, not an infinite loop and not success.
        stuck = tempfile.mkdtemp(prefix="restore-stuck-")
        os.write = lambda fd, buf: 0
        problems = ra._restore_local_config(stuck, stash)
        check(
            len(problems) == len(stash) and all("short write" in p for p in problems),
            f"a write that makes NO progress must be reported, not looped on: {problems}",
        )

        # (3) AN OUTRIGHT FAILURE is returned, so the caller's `ActionFailed` can state BOTH facts.
        gone = tempfile.mkdtemp(prefix="restore-gone-")

        def no_space(*a, **k):
            raise OSError(28, "No space left on device")

        os.open = no_space
        problems = ra._restore_local_config(gone, stash)
        check(
            len(problems) == len(stash) and all("could NOT be restored" in p for p in problems),
            f"a restore that fails must be REPORTED, never `pass`-ed: {problems}",
        )

        # (4) AND WHEN BOTH FAIL, THE RECORD STATES BOTH FACTS. Raising the restore failure from the
        # `finally` REPLACES the propagating exception, and `converge` records only `str(exc)` — so
        # before this, a `config.sh` that refused for a REAL reason (auth, transport) produced a
        # problem line naming the restore and NOT the cause. Reproduced by driving `register()` with
        # refusing `config.sh` + an unreservable `os.open`.
        os.open = real_open  # (the fixture needs a working open before we break it again)
        with Env():
            box = Box("restore-and-refuse")
            try:
                install = box.install("gh-runner-x64", "r-dead")
                box.refusals(5)
                os.open = no_space
                try:
                    ra.register(Path(install), "r-dead", "daniel-ospina/tortoise", "self-hosted-x64", True)
                except ra.ActionFailed as exc:
                    msg = str(exc)
                    check("could NOT be put back" in msg, f"the restore failure must be named: {msg}")
                    check(
                        "rc=" in msg,
                        f"…AND the ORIGINAL cause must survive in the same message (the record keeps "
                        f"`str(exc)` and nothing else, so a chained traceback is invisible to it): {msg}",
                    )
                else:
                    check(False, "a refused registration with an unrestorable stash must RAISE")
            finally:
                os.open = real_open
                box.destroy()
    finally:
        os.write = real_write
        os.open = real_open
        for d in (short, stuck, gone):
            if d:
                shutil.rmtree(d, ignore_errors=True)


MUTATIONS = [
    # ── review round 3 (this push): the both-facts leg, and the two families of the label strip ──
    Mutation(
        "T55",
        """                    f"{failure if failure is not None else f'{name} could not be re-registered'}""",
        '                    f"{name} could not be re-registered"  # MUTATION: the original cause is dropped',
        "the restore failure replaces the propagating exception and `converge` records only "
        "`str(exc)`, so the ORIGINAL cause (`config.sh rc=1: gh: HTTP 401 …`) disappears from the "
        "machine-readable record — an operator can no longer tell auth from transport from ENOSPC "
        "on the one leg where the install may have lost the files that make it discoverable",
    ),
    # ── review round 12: the 2026-10-27 second-review findings (one mutation per claim) ──
    Mutation(
        "T55",
        '                view = memoryview(data)\n                while view:\n                    written = os.write(fd, view)\n                    if written <= 0:\n                        raise OSError(\n                            f"short write: {len(view)} of {len(data)} byte(s) left unwritten"\n                        )\n                    view = view[written:]',
        '                os.write(fd, data)  # MUTATION: the return is ignored, so a short write truncates the key',
        "a disk that fills mid-file makes `os.write` return a SHORT COUNT and raise nothing, so the "
        "runner's RSA private key (`.credentials_rsaparams`) is restored TRUNCATED — silently, on "
        "exactly the box the disk arm exists for",
    ),
    Mutation(
        "T55",
        '            problems.append(f"{name} could NOT be restored ({exc})")',
        "            pass  # MUTATION: a failed restore is silent again",
        "a restore that fails OUTRIGHT returns no problems, so the caller cannot tell it from "
        "success: the record names only the original failure while the install has lost `.runner` "
        "and its key — `discover()` stops seeing it, its slot reads FREE, and the next pass adds a "
        "SECOND install over the top",
    ),
    Mutation(
        "T50",
        "    except RuntimeError as exc:",
        "    except ZeroDivisionError as exc:  # MUTATION: the unresolvable home escapes the audit",
        "`Path.expanduser()` raises on a `~user` this account cannot resolve, so the audit throws "
        "after the repair loop has already destroyed and recreated a registration — exit 2, "
        "'nothing was changed', with the record losing `actions`",
    ),
    Mutation(
        "T30",
        "    except Exception as exc:  # noqa: BLE001 — the audit is a reporter, never a reason to lose a record",
        "    except ZeroDivisionError as exc:  # MUTATION: the audit's failure escapes the pass",
        "an exception inside the every-pass unit audit reaches `main()`'s backstop again, whose "
        "payload carries no `actions` — so the record of an action already performed is lost",
    ),
    # ── review round 13: the 2026-10-27 third-review findings (one mutation per claim) ──
    Mutation(
        "T44",
        "        '[.total_count, (([.workflow_runs[].created_at]|min)//\"\")]|@tsv',",
        "        '[.total_count, (.workflow_runs[0].created_at // \"\")]|@tsv',",
        "row 0 is read as `the oldest` on an endpoint that is NEWEST-FIRST and IGNORES `sort`/"
        "`direction` — so the age is ~0 on a queue that is merely still receiving work, and #2875's "
        "starved shape (53 queued, pool online and idle) reports `ok` and exits 0",
    ),
    Mutation(
        "T56",
        "    if total > QUEUE_AGE_PAGE:",
        "    if False:  # MUTATION: a saturated page is certified",
        "`min()` over a page that cannot hold the whole queue is only a LOWER BOUND on the head's "
        "age, which can only UNDERSTATE it — the direction that silences a starved-queue alarm. "
        "`ci_runner_gate.sh:319-324` refuses this state by name for this same read; the two cross "
        "when the gate's operator-settable threshold rises above this tool's page size",
    ),
    Mutation(
        "T56",
        "        elif starvation.get(\"detail\"):",
        "        elif False:  # MUTATION: an unmeasured starvation term carries no reason",
        "a refused age read reaches a reader as a bare `starvation=unmeasured` with no reason, so an "
        "operator cannot tell a saturated page from an unparsable timestamp from a failed `gh`",
    ),
    Mutation(
        "T56",
        "        if total == 0:\n            return None\n        raise Unmeasurable(",
        "        return None  # MUTATION: an empty page is read as an empty queue\n        raise Unmeasurable(",
        "a queue whose head has no readable `created_at` answers `None`, i.e. \"nothing is "
        "waiting\" — which DISARMS the age term entirely, so a backlog reports an idle queue. "
        "The shared gate refuses the same combination by name (`ci_runner_gate.sh:299`)",
    ),
    Mutation(
        "T56",
        "        if measured:\n            out.update(measured)\n        if seen:",
        "        if seen:",
        "a refused AGE read erases the counts the sample already measured, so `--json` reports the "
        "depth as absent on exactly the passes an operator needs to explain — the round-7 "
        "defect, where the field `origin/main` publishes went missing",
    ),
    Mutation(
        "T48",
        "        lost = _restore_local_config(directory, stash)\n        if lost:\n            raise ActionFailed(\n                f\"{exc} — AND ",
        "        lost: list[str] = []  # MUTATION: a failed restore during a signal goes unreported\n        if lost:\n            raise ActionFailed(\n                f\"{exc} — AND ",
        "the stash is never put back on the signal path at all, and a restore that fails is silent: "
        "the install loses `.runner`/credentials while the process exits 143 as if they came back",
    ),
    Mutation(
        "T48",
        "        if replace:\n"
        "            try:\n"
        "                previous_sigterm = signal.getsignal(signal.SIGTERM)\n"
        "                signal.signal(signal.SIGTERM, _term_as_exit)\n"
        "            except (ValueError, OSError):  # not the main thread / unsupported — see the note above\n"
        "                previous_sigterm = None\n"
        "            stash = _clear_local_config(directory)",
        "        if replace:\n"
        "            stash = _clear_local_config(directory)  # MUTATION: handler installed too late\n"
        "            try:\n"
        "                previous_sigterm = signal.getsignal(signal.SIGTERM)\n"
        "                signal.signal(signal.SIGTERM, _term_as_exit)\n"
        "            except (ValueError, OSError):\n"
        "                previous_sigterm = None",
        "the handler is installed AFTER the clear returns, so a SIGTERM inside the unlink loop runs "
        "under the DEFAULT disposition: the process dies where it stood, no `finally` runs, the stash "
        "is dropped mid-unlink and the install loses `.runner`, its credentials and the RSA key",
    ),
    # ⛔ A MUTATION REMOVED, ON PURPOSE (round 12). "repair identity falls back to the NAME, so two
    # installs sharing an agentName act on the same one twice" is no longer a defect this file can
    # exhibit: two `--replace` calls for one name are now REFUSED outright (the mutation below), so
    # the second install never reaches the register call at all and the name lookup and the
    # directory lookup resolve to the same install in every reachable pass. The `c["dir"]` lookup
    # stays as the precise expression of "identity is the install"; the GUARANTEE that used to ride
    # on it is now pinned by the duplicate rule, and re-adding this mutation would only score a
    # CAUGHT against a code path the case cannot reach.
    Mutation(
        "T37",
        '        if c["name"] in duplicates and c["dir"] != duplicates[c["name"]][0]:',
        "        if False:  # MUTATION: every duplicate install is registered",
        "two `--replace` calls for one agentName in one pass: the second deletes the registration "
        "the first created seconds earlier, the record claims two registrations, and the pair "
        "oscillates every pass",
    ),
    Mutation(
        "T51",
        '    elif live >= target and record["would_repair"]:',
        "    elif False:  # MUTATION: an outstanding repair is laundered into `converged`",
        "a read-only `--status` on a box whose own classification says DEAD reports "
        "`verdict=converged`, exit 0 — the false PASS a health check reads as healthy",
    ),
    Mutation(
        "T52",
        '    token = out.strip().splitlines()[-1].strip() if out.strip() else ""',
        '    token = (out + err).strip().splitlines()[-1].strip() if (out + err).strip() else ""  # MUTATION: merged streams',
        "a `gh` advisory on stderr on a SUCCESSFUL mint becomes the token, so `config.sh` rejects "
        "it and the repair path raises on every pass while blaming the runner's own tooling",
    ),
    # ── review round 11: the 2026-10-27 fresh-context findings (one mutation per claim) ──
    Mutation(
        "T44",
        "    if queue_age_s is not None and queue_age_s >= STARVATION_QUEUE_AGE_S:",
        "    if False:  # MUTATION: the age term is gone — a cell is blind again",
        "the only eligibility term a CELL can measure is removed, so #2875's own shape (label stripped "
        "pool-wide by a gate that runs on ANOTHER box, 53 queued, pool idle) reports ok, exit 0 — on "
        "exactly the boxes --install-unit targets",
    ),
    Mutation(
        "T44",
        "    if queue_age_s is not None and queue_age_s >= STARVATION_QUEUE_AGE_S:",
        "    if queue_age_s is not None:  # MUTATION: the bound is not applied",
        "the age BOUND is dropped, so a queue being served right now (oldest run seconds old) pages "
        "the alarm on health — the false positive round 9 removed, reintroduced through the term "
        "that was supposed to be safe",
    ),
    Mutation(
        "T45",
        "            pool_online = refreshed is not None and refreshed.online\n            serving = alive or pool_busy or pool_online",
        "            pool_online = refreshed is not None and refreshed.online\n            serving = alive or pool_busy  # MUTATION: online is not a serving state",
        "a runner the POOL reports online is treated as not serving and --replace'd — its live "
        "registration deleted — when the restart command failed, the one case where the pool read is "
        "the only evidence there is",
    ),
    Mutation(
        "T46",
        "        stat_result, uninspectable = _inspect_path(entry)\n        if uninspectable:",
        "        stat_result, uninspectable = _inspect_path(entry)\n        if False:  # MUTATION: an uninspectable ENTRY is not reported",
        "an entry this account cannot inspect is no longer caught, so `entry.is_dir()` re-raises the "
        "PermissionError/ENAMETOOLONG through the every-pass audit into main()'s backstop — exit 2 "
        "with no actions field, after a registration may already have been destroyed",
    ),
    Mutation(
        "T47",
        '            "TimeoutStartSec=5400",',
        '            "TimeoutStartSec=1800",  # MUTATION: shorter than a legitimate pass',
        "systemd SIGTERMs a healthy pass inside the pass's own bounded worst case, and a killed pass "
        "runs no finally — the install is left with its .runner and RSA key deleted",
    ),
    Mutation(
        "T48",
        "            signal.signal(signal.SIGTERM, _term_as_exit)",
        "            pass  # MUTATION: the default SIGTERM disposition terminates without unwinding",
        "SIGTERM terminates the process without running the stash's finally, so an interrupted "
        "registration destroys the install's .runner and credentials and leaves the slot looking FREE",
    ),
    Mutation(
        "T49",
        "        if seen:",
        "        if False:  # MUTATION: the first sample is discarded",
        "a failed confirmation read erases the sample that already answered yes — the counts and "
        "queued_runs vanish, so 'unmeasured after seeing 53 queued' is indistinguishable from 'never read'",
    ),
    Mutation(
        "T29",
        "    if not gate_scheduler_present():",
        "    if False:  # MUTATION: a hand-run record is trusted as a standing decision",
        "a record written by a hand-run of the gate on a cell — where nothing schedules it — is "
        "trusted for ever, so every later repair arms ubuntu-latest on a healthy box: the "
        "fallback-only incident, made permanent and made to look deliberate",
    ),
    Mutation(
        "T29",
        "    return mode, f\"the gate's record {path} (and a job that installs the gate IS present on this box)\"",
        "    return None, f\"the gate's record {path}\"  # MUTATION: the mode is read and discarded",
        "the gate's own mode is read and thrown away, so the floor can never repair the incident it "
        "exists for while the record still looks consulted",
    ),
    Mutation(
        "T16",
        "    if \"%\" in value:",
        "    if False:  # MUTATION: an unvalidated provisioner path",
        "a provisioner path containing a systemd specifier reaches `Environment=`, where it is "
        "expanded at load time — the schedule then runs an installer path nobody chose",
    ),
    Mutation(
        "T16",
        "    if '\"' in value:",
        "    if False:  # MUTATION: a quote is allowed into the quoted assignment",
        "a double quote in the pinned path escapes its `Environment=` assignment, so the variable "
        "is not what the fill arm reads",
    ),
    Mutation(
        "T30",
        "    if minimum is not None and value < minimum:",
        "    if False:  # MUTATION: the range is not checked",
        "a negative seam is accepted: `max(1, tries)` silently drops the bounded retry, and "
        "`max(0, timeout_s)` sends a reconnecting runner straight to `--replace`",
    ),
    Mutation(
        "T28",
        '        if uninspectable:\n            problems.append(f"{root}: {uninspectable} — NOTHING was audited there")\n            continue',
        "        if uninspectable:\n            continue  # MUTATION: an unreadable base is skipped silently",
        "a unit directory this account cannot read is skipped as if it were not there, so the audit "
        "reports 'all usable' over a population it never read",
    ),
    # ── review round 8: the 2026-10-27 findings (P1–P3) ──
    Mutation(
        "T28",
        "        if exc.errno in _ABSENT_ERRNOS:\n            return None, None",
        "        if True:  # MUTATION: every unreadable path is filed as ABSENT\n            return None, None",
        "an uninspectable path is filed as ABSENT again: the audit claims 'does not exist' about a "
        "directory it never looked at, and the install refuses for the wrong reason",
    ),
    Mutation(
        "T28",
        '        if uninspectable:\n            # ⛔ THE DIRECTION MATTERS: this function\'s answer EXEMPTS a unit from the ExecStart',
        '        if uninspectable:\n            return f"{key}={value}"  # MUTATION: could-not-look read as condition-unmet\n            # ⛔ THE DIRECTION MATTERS: this function\'s answer EXEMPTS a unit from the ExecStart',
        "an uninspectable Condition path is read as an ABSENT one, so a unit systemd may well start "
        "is silently exempted from the ExecStart check — a false PASS inside the audit",
    ),
    Mutation(
        "T29",
        '    if gate_mode == "github":',
        '    if False:  # MUTATION: the gate no longer strips what the runner already carries',
        "preservation re-asserts `ubuntu-latest` against a `github` gate record again, with no note: "
        "the repair fights the gate's own fallback_off once per cycle, and `runs-on: ubuntu-latest` "
        "work lands on the box and competes with the agent fleet (ci_runner_gate.sh:12)",
    ),
    Mutation(
        "T29",
        '    return label.strip().lower().startswith("ubuntu-")',
        '    return False  # MUTATION: a hosted image label is not recognised as one',
        "a self-hosted runner re-claims `ubuntu-22.04`, so a job asking for that HOSTED image runs "
        "here on another OS — a false PASS, not a queue delay — and no gate owns that label, so "
        "nothing else ever removes it",
    ),
    Mutation(
        "T29",
        "    hosted = list(",
        "    hosted = [] if gate_mode != \"github\" else list(  # MUTATION: the hosted-image strip is gated",
        "a mis-set `ubuntu-22.04` survives under `local` (a box ACTIVELY serving CI) and under `None` "
        "(a cell, where no gate runs at all): the same hosted-image false PASS is left open in the "
        "two modes nothing else cleans up",
    ),
    Mutation(
        "T29",
        '    return gate_mode == "local" and not pool_serves_fallback(pool)',
        "    return not pool_serves_fallback(pool)  # MUTATION: the pre-fix rule",
        "the floor stops consulting the gate: 'no runner carries the label' is the gate's NORMAL "
        "state, so every repair re-arms ubuntu-latest on a healthy box and the gate strips it again "
        "— the recorded fallback-only decision is reversed and the two timers fight forever",
    ),
    Mutation(
        "T30",
        '        try:\n            value = int(raw.strip())\n        except ValueError as exc:\n            raise Unmeasurable(\n                f"{name}={raw!r} is not an integer — refusing to run with an unreadable seam"\n            ) from exc',
        '        value = int(raw.strip())  # MUTATION: a bad seam escapes as ValueError',
        "an unparsable seam crashes the pass again with a traceback and no record — on a pass that "
        "may already have restarted and re-registered runners",
    ),
    Mutation(
        "T30",
        "    except Exception as exc:  # noqa: BLE001 — a pass that dies must still leave a RECORD",
        "    except ZeroDivisionError as exc:  # MUTATION: the backstop no longer catches",
        "the backstop is removed: an unexpected error exits with a bare traceback and `_log()` is "
        "never called, so the record of a pass that DID change the box is lost",
    ),
    Mutation(
        "T31",
        '        if not (slot / ".runner").exists():\n            return index\n        index += 1',
        "        return index  # MUTATION: the base slot, never the next FREE one",
        "the slot is not walked for the first FREE one, so an occupied base makes the installer fill "
        "several slots in one call — the measured over-fill the ceiling forbids",
    ),
    Mutation(
        "T32",
        "            alive = _worker_alive(runner, fresh=True)",
        "            alive = _worker_alive(runner)  # MUTATION: the cached value",
        "the busy re-check reads the value cached at CLASSIFICATION, so a runner that came up and "
        "took a job during the restart wait has its registration deleted under the running job",
    ),
    Mutation(
        "T9b",
        "            pool, queued = sample()\n"
        "            busy = sum(1 for e in pool.values() if e.busy)\n"
        "            online = sum(1 for e in pool.values() if e.online)\n"
        "            measured = {\"queued\": queued, \"busy\": busy, \"online\": online}\n"
        "            eligible, why, age = decide(pool, queued, busy, online)\n"
        "            seen = {",
        "            pass  # MUTATION: the second sample is thrown away\n"
        "            seen = {",
        "the confirmation sample is taken and discarded, so an ordinary handover blip alarms — the "
        "one case in this suite that had no paired mutation at all (review finding P3)",
    ),
    # ── review round 7 ──
    Mutation(
        "T26",
        '    if not record["problems"] and record.get("unverified_cause") != "pool-read-after-restart":',
        '    if (\n        not record["problems"]\n        and not record.get("problem_kind")\n        and record.get("unverified_cause") != "pool-read-after-restart"\n    ):',
        "the REFUSAL leg is excluded from the alarm's gate again: the probe never reads the queue "
        "on the one pass that exits 0, so a starved box reports green (the measured fail-open)",
    ),
    Mutation(
        "T26",
        '    elif starvation.get("state") == "starved":\n        # ⛔ THE ALARM OWNS THE VERDICT',
        '    elif False:  # MUTATION: the alarm loses to the refusal\n        # ⛔ THE ALARM OWNS THE VERDICT',
        "the verdict ORDER is restored to refusal-first: the alarm evaluates, sets the counts, and "
        "then the refusal's exit 0 wins — a page computed and thrown away",
    ),
    Mutation(
        "T27",
        "        if value == \"\":\n            commands.clear()  # the documented RESET — the one way a later line removes an earlier one\n            continue\n        commands.append(value)",
        "        commands = [value] if value else []",
        "ExecStart is read as LAST-ASSIGNMENT-WINS again: a later durable command HIDES an earlier "
        "transient one, which still runs and still dies on every tick — the false PASS the check "
        "was added to close",
    ),
    Mutation(
        "T27",
        "    while index < len(token) and token[index] in EXEC_PREFIX_CHARS:",
        "    while False:",
        "the executable prefixes (@ - : + ! !!) are read as part of the path again: every stock unit "
        "that carries one is reported, and --check-units can never be cleared on a real box",
    ),
    Mutation(
        "T27",
        '        if probe is None:\n            return f"{key}={value}"',
        '        if False:\n            return f"{key}={value}"',
        "a conditionally SKIPPED unit is judged as if it would run: a stock rc-local-style unit with no "
        "rc.local pages a human about a program systemd never starts",
    ),
    Mutation(
        "T27",
        "        shape = transient_path_problem(token)\n        if shape:",
        "        shape = transient_path_problem(token)\n        if False:",
        "the audit stops judging the paths ExecStart NAMES — which is the shape `render_unit` "
        "writes (durable interpreter, transient script): a unit whose program a reclaim takes is "
        "reported 'all usable', the false PASS on 'the converger is scheduled'",
    ),
    Mutation(
        "T4b",
        'if rc != 0 and _ALREADY_CONFIGURED in out.lower() and replace:',
        'if rc != 0 and _ALREADY_CONFIGURED in out.lower():',
        "the clear-and-retry runs on the replace=False arm too: config.sh re-registers WITHOUT "
        "--replace, creating a SECOND runner and leaving the old one a ghost in the pool",
    ),
    Mutation(
        "T24",
        'if len(fields) >= 4 and fields[-3].isdigit():\n            return int(fields[-3])',
        'if len(fields) >= 4 and fields[3].isdigit():\n            return int(fields[3])',
        "a `df` source with a space shifts the fields: the TOTAL is read as free space (over-add)",
    ),
    Mutation(
        "T24",
        "    value = min(by_core, by_mem, by_disk)",
        "    value = min(by_core, by_mem)",
        "the disk arm is computed and then ignored — the ceiling asks for a runner the disk cannot hold",
    ),
    Mutation(
        "T24",
        '    return max(measured, FOOTPRINT_MB_DEFAULT), (',
        "    return FOOTPRINT_MB_DEFAULT, (",
        "the MEASURED footprint is replaced by the installer's allowance, so the reading lies",
    ),
    Mutation(
        "T25",
        "            if fits:",
        "            if False:",
        "a guard disagreement is reported as an ordinary refusal: the capacity gap loses its name",
    ),
    # ⛔ NO MUTATION FOR THE FILL'S `disk_free_mb is None` CLAUSE, DELIBERATELY: removing it changes
    # nothing observable, because the SAME unmeasured disk is re-read at the top of every step and
    # that guard stops the fill anyway (measured: the mutant reports every T24 assertion green). Two
    # independent guards for one condition is defence in depth, not dead code — but a mutation that
    # cannot be distinguished is not evidence, so it is not listed.
    Mutation(
        "T24",
        '        disk_part = "by_disk=UNKNOWN"',
        '        disk_part = "by_disk=0"',
        "an unknown disk is reported as ZERO, which is an answer this tool does not have",
    ),
    Mutation(
        "T19",
        "3 is NOT a rollback",
        "3 IS a rollback",
        "the documented contract says exit 3 restores the previous install, which the code cannot promise",
    ),
    Mutation(
        "T23",
        '            if path.name.endswith(".conf"):\n                by_name.setdefault(path.name, path)',
        '            if path.name.endswith(".conf"):\n                by_name[path.name] = path',
        "of two same-named drop-ins the LOWER-priority copy wins, so a clean one masks a broken unit",
    ),
    Mutation(
        "T23",
        '        hierarchy = unit_dir_hierarchy(str(root))',
        '        hierarchy = "user"',
        "the two systemd managers are merged, so a healthy copy in one masks a broken copy in the other",
    ),
    Mutation(
        "T22",
        '    try:\n        entries = sorted(directory.iterdir())\n    except OSError as exc:',
        '    try:\n        entries = sorted(directory.iterdir())\n    except ZeroDivisionError as exc:',
        "an unreadable unit dir raises out of the audit, or (with glob) reports CLEAN as an empty one",
    ),
    Mutation(
        "T22",
        '            try:\n                nested = sorted(entry.iterdir())\n            except OSError as exc:',
        '            try:\n                nested = sorted(entry.iterdir())\n            except ZeroDivisionError as exc:',
        "an unreadable drop-in dir raises out of the audit instead of being reported",
    ),
    Mutation(
        "T20",
        '                if "=" not in line:  # systemd skips a valueless line; so must this\n                    continue',
        "                if False:\n                    continue",
        "a valueless WorkingDirectory line MASKES a bad earlier one (systemd keeps the earlier value)",
    ),
    Mutation(
        "T19",
        '        for tmp, path in staged:\n            os.replace(tmp, path)',
        '        for tmp, path in staged:\n            os.replace(tmp, path) if tmp.name.endswith("service") else None',
        "only half the pair is swapped in: a `.timer` with no `.service` schedules nothing",
    ),
    Mutation(
        "T21",
        '''        record["unit_cwd_problems"] = unit_problems''',
        """        record["problems"].extend(unit_problems)""",
        "a stale unit file is folded into `problems`, so every pass on that cell reports failure",
    ),
    Mutation(
        "T21",
        '''        record["notes"].append(
            f"unit audit: {len(unit_problems)} installed-unit finding(s) — see unit_cwd_problems"
        )''',
        "        pass",
        "the pass finds a bad unit and says NOTHING about it",
    ),
    Mutation(
        "T18",
        '    if not REPO_PATTERN.fullmatch(repo or ""):',
        "    if False:",
        "--repo is interpolated unvalidated: a newline writes a directive, a quote escapes the quoting",
    ),
    Mutation(
        "T20",
        '        if tolerant:\n            # `-` only SUPPRESSES the failure',
        '        if False:\n            # `-` only SUPPRESSES the failure',
        "a `-`-prefixed value is reported with the failure wording, which is FALSE for a tolerated one",
    ),
    Mutation(
        "T20",
        '        if stat_result is not None and stat.S_ISDIR(stat_result.st_mode) and name.endswith(".d"):',
        "        if False:",
        "a DROP-IN overriding a clean main unit is invisible: the incident shape reports CLEAN",
    ),
    Mutation(
        "T20",
        'UNIT_FILE_SUFFIXES = ("service", "socket", "path", "mount", "swap")',
        'UNIT_FILE_SUFFIXES = ("service",)',
        "only .service is read, so a .socket with a transient WorkingDirectory reports clean",
    ),
    Mutation(
        "T20",
        '                if key.strip() == "WorkingDirectory" and section == "Service":',
        '                if key.strip() == "WorkingDirectory":',
        "a WorkingDirectory under [Unit] is refused although systemd IGNORES it there",
    ),
    Mutation(
        "T18",
        '        if "%" in workdir:',
        "        if False:",
        "an explicit --workdir with a systemd specifier is written, then expands to a path nobody checked",
    ),
    Mutation(
        "T18",
        '        if any(ch in workdir for ch in ("\\n", "\\r", "\\0")) or any(',
        "        if False and any(",
        "a newline in --workdir injects an arbitrary directive into the unit's [Service] section",
    ),
    Mutation(
        "T20",
        "    if require_any and seen == 0:",
        "    if False:",
        "an EXISTING but empty unit dir audits nothing and reports 'all usable'",
    ),
    Mutation(
        "T19",
        '        rc, out = _run(_systemctl_user(args), timeout=120)\n        if rc != 0:',
        '        rc, out = _run(_systemctl_user(args), timeout=120)\n        if False:',
        "the timer enable fails silently: the unit is written and the schedule runs nothing",
    ),
    Mutation(
        "T16",
        'f"WorkingDirectory={wd}"',
        '"WorkingDirectory=/tmp/eldato-runner"',
        "the template pins a TRANSIENT cwd — the exact shape that killed the converger for a day",
    ),
    Mutation(
        "T17",
        "    if probe is None or not stat.S_ISDIR(probe.st_mode):",
        "    if False:",
        "a missing WorkingDirectory is written anyway, and systemd then fails the unit at CHDIR",
    ),
    Mutation(
        "T18",
        "    for prefix in TRANSIENT_UNIT_PREFIXES:",
        "    for prefix in ():",
        "a path that exists TODAY is accepted although it is under /tmp and will be reclaimed",
    ),
    Mutation(
        "T19",
        '    for args in (["daemon-reload"], ["enable", "--now", f"{UNIT_BASENAME}.timer"]):',
        '    for args in (["daemon-reload"],):',
        "the files are written but the timer is never enabled: written is not scheduled",
    ),
    Mutation(
        "T20",
        '        if "%" in value and value != "%h":',
        "        if False:",
        "a specifier this check cannot resolve is silently counted as CLEAN",
    ),
    Mutation(
        "T1",
        '    if floor or engaged:\n        labels.append(FALLBACK_LABEL)',
        '    if engaged:\n        labels.append(FALLBACK_LABEL)',
        "the PRE-FLOOR rule: the label is granted only by the condition it would itself create",
    ),
    Mutation(
        "T2",
        '    if floor or engaged:\n        labels.append(FALLBACK_LABEL)',
        '    if True:\n        labels.append(FALLBACK_LABEL)',
        "the label is BAKED IN, so `ci_runner_gate.sh` reads `local` forever (the rule this pins)",
    ),
    Mutation(
        "T3",
        '            labels = resolve_labels(\n                pool,\n                machine,\n                notes=record["notes"],\n                current=c["labels"],\n                gate_mode=gate_mode,\n                gate_why=gate_why,\n            )',
        '            labels = resolve_labels(\n                pool, machine, notes=record["notes"]\n            ) if not c["labels"] else _preserve_labels(c["labels"], machine)',
        "the PRE-FIX either/or: a DEAD runner preserves its labels and the floor is never reached",
    ),
    Mutation(
        "T4",
        '            stash = _clear_local_config(directory)',
        '            stash: dict[str, tuple[int, bytes]] = {}',
        "the local config is never cleared before configuring (the refusal the repair cannot pass)",
    ),
    Mutation(
        "T4",
        '        if rc != 0 and _ALREADY_CONFIGURED in out.lower() and replace:',
        '        if False:',
        "there is no retry, so 'already configured' still ends the repair (the measured cell-4 state)",
    ),
    Mutation(
        "T5",
        '    except OSError as exc:\n        lost = _restore_local_config(directory, stash)',
        '    except OSError as exc:\n        pass',
        "a clear that fails partway leaves the install half-cleared (no .runner: invisible, slot FREE)",
    ),
    Mutation(
        "T6",
        "    finally:\n        if previous_sigterm is not None:\n            signal.signal(signal.SIGTERM, previous_sigterm)\n        if not registered:\n            lost = _restore_local_config(directory, stash)",
        "    finally:\n        if previous_sigterm is not None:\n            signal.signal(signal.SIGTERM, previous_sigterm)\n        if not registered and \"rc\" in locals() and rc != 0:\n            lost = _restore_local_config(directory, stash)",
        "the restore is gated on the rc check, so a RAISE between the clear and the rc drops the stash",
    ),
    Mutation(
        "T5",
        '            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)\n            try:\n                os.fchmod(fd, mode)',
        '            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)\n            try:\n                pass',
        "the restore is written the NAIVE way (create 0644, no fchmod): the RSA key widens to 0644",
    ),
    Mutation(
        "T7",
        '            if read_pool_retrying(repo).get(name, PoolEntry(name, "offline", False)).online:',
        '            if read_pool(repo).get(name, PoolEntry(name, "offline", False)).online:',
        "the measured pre-fix read: ONE transient failure ends the pass (there is no retry at all)",
    ),
    Mutation(
        "T8",
        '            if not pool_error_is_transient(str(exc)):',
        '            if False:',
        "every error is treated as transient, so a deterministic 404 is retried ('transient' = anything)",
    ),
    Mutation(
        "T9",
        '        "state": "starved" if starved else "ok",',
        '        "state": "ok",',
        "there is NO starvation alarm: a starved box reads healthy and exits 0 (the measured night)",
    ),
    Mutation(
        "T10",
        "    return queued > 0 and busy == 0 and online > 0",
        "    return queued > 0 and busy == 0",
        "the online operand is gone, so an ALL-OFFLINE pool (nothing can take work) alarms as starvation",
    ),
    Mutation(
        "T11",
        '    except Unmeasurable as exc:\n        out: dict[str, object] = {"state": "unmeasured", "detail": str(exc)}',
        '    except Unmeasurable as exc:\n        out: dict[str, object] = {"state": "ok"}  # MUTATION',
        "an unread queue reads as OK — blindness presented as health (the one silencing input)",
    ),
    Mutation(
        "T13",
        "0 < confirm_s <= STARVATION_CONFIRM_MAX_S",
        "0 <= confirm_s <= STARVATION_CONFIRM_MAX_S",
        "0 is accepted again — and 0 is the value that SILENTLY disables the confirmation sample",
    ),
    Mutation(
        "T13",
        'f"(finite, 0 < s <= {STARVATION_CONFIRM_MAX_S:.0f}) — "',
        'f"(finite, 0 < s <= 900) — "',
        "the note lies about the bound it refused (a hand-written copy, which no compiler checks)",
    ),
    Mutation(
        "T13",
        'f"using {STARVATION_CONFIRM_DEFAULT_S:.0f}s"',
        'f"using 60s"',
        "the note lies about the default it fell back to — the operator then tunes the wrong number",
    ),
    Mutation(
        "T14",
        "before it pages (30)",
        "before it pages (45)",
        "the header's seam table lies about the default an operator should tune",
    ),
    Mutation(
        "T14",
        "4 STARVATION",
        "5 STARVATION",
        "the header's EXIT block points a monitor at the wrong exit code",
    ),
    Mutation(
        "T15",
        "if starved and confirm_s > 0:",
        "if starved and confirm_s >= 0:",
        "a zero-length confirmation sample counts as a confirmation — the guard with its teeth out",
    ),
    Mutation(
        "T14",
        "STARVATION_CONFIRM_DEFAULT_S = 30.0",
        "STARVATION_CONFIRM_DEFAULT_S = 45.0",
        "the DOCUMENTED default drifts away from the value an unset seam actually gets",
    ),
    Mutation(
        "T13",
        '    if not record["problems"] and record.get("unverified_cause") != "pool-read-after-restart":',
        '    if record.get("unverified_cause") != "pool-read-after-restart":',
        "the alarm runs on a pass that already FAILED, so a consumer can page on it beside action-failed",
    ),
    Mutation(
        "T13",
        'if not (\n                math.isfinite(confirm_s) and 0 < confirm_s <= STARVATION_CONFIRM_MAX_S\n            ):',
        'if False:',
        "the seam accepts nan/-5/inf again: the confirmation is silently skipped, or the pass crashes",
    ),
    # F2: WIDENING the bound, not deleting the branch — the exact regression review round 5 raised.
    # A `<= 900` mutant survives every input in the fallback list, so it needs its own probe value.
    Mutation(
        "T13",
        "0 < confirm_s <= STARVATION_CONFIRM_MAX_S",
        "0 < confirm_s <= 900",
        "the cadence-derived bound is widened back out, so a pass can outlive the next timer",
    ),
    Mutation(
        "T12",
        '    if not record["problems"] and record.get("unverified_cause") != "pool-read-after-restart":',
        '    if (\n        not record["problems"]\n        and record.get("unverified_cause") != "pool-read-after-restart"\n        and not record["actions"]\n    ):',
        "the alarm is suppressed by ACTIONS, so a repair that never sticks silences it for ever (#2875)",
    ),
    # ── review cycle of this lane (2026-10-27): one mutation per new case ───────────────────────
    Mutation(
        "T33",
        '    if pool_serves_fallback(pool):',
        '    if True:  # MUTATION: eligibility is not consulted',
        "the eligibility term is neutered, so a fallback-only repo's own backlog pages exit 4 for ever",
    ),
    Mutation(
        "T34",
        '    if gate_mode == "local":',
        '    if False:  # the gate\'s recorded intent is ignored',
        "the gate's `local` no longer makes the queue this pool's work: #2875's stripped-label shape goes silent",
    ),
    Mutation(
        "T35",
        '        if not stripped or stripped.startswith("#"):',
        '        if not stripped:',
        "a COMMENTED-OUT cron line counts as a schedule, so a stale `local` record arms the fallback for ever",
    ),
    Mutation(
        "T35",
        '            if not name.endswith((".service", ".timer")):',
        '            if False:',
        "a `.disabled`/`.bak` unit file counts as a schedule — the ordinary hand-disable reads as intended",
    ),
    Mutation(
        "T35",
        "            if entry.is_symlink() and os.readlink(entry) == os.devnull:",
        "            if False:",
        "a MASKED unit counts as a schedule, so a deliberately disabled gate keeps arming the fallback",
    ),
    Mutation(
        "T36",
        '        raise Unmeasurable(f"the runner root {base} {base_reason} — cannot inventory this box")',
        "        return []",
        "an unreadable runner root reads as EMPTY: the pass registers duplicates over installs it could not see",
    ),
    Mutation(
        "T38",
        '            record["unverified"] = True\n'
        '            # ⛔ ITS OWN CAUSE (review finding P2). The shared `mid-pass-measurement` name rendered',
        '            # MUTATION: the mid-pass disk failure sets no `unverified` bit at all\n'
        '            # (review finding P2). The shared `mid-pass-measurement` name rendered',
        "the mid-pass disk failure is not recorded as unverified, so a fleet reader sees a HEALTHY pass",
    ),
    Mutation(
        "T39",
        "            if len(measured) <= installs_seen:",
        "            if False:",
        "a provisioner that installs NOTHING exits 0 as `under-target`: an enforcer that failed to grow reads green",
    ),
    Mutation(
        "T40",
        '            f"no provisioner: {why} — a NEW runner cannot be created on this box (this script "',
        '            "no provisioner: tools/install-ci-runner-x64.sh is absent, so a NEW runner cannot be "',
        "the moved-pin diagnostic names a literal filename, not the value the operator must fix",
    ),
    Mutation(
        "T41",
        "    if not sizes:",
        "    if rc != 0 or not sizes:",
        "a PARTIAL du is thrown away, so a >8 GB install budgets the 8 GB allowance: the over-add the arm forbids",
    ),
    Mutation(
        "T42",
        "    except FileNotFoundError:",
        "    except ZeroDivisionError:",
        "an ABSENT gate record is reported as unreadable, sending an operator after permissions on a cell",
    ),
    Mutation(
        "T9",
        '            record["starvation_queued"] = starvation["queued"]',
        '            record["starvation_queued"] = None',
        "the published starvation count is deleted while every gate stays green (a contract with no artifact)",
    ),
    Mutation(
        "T3",
        "        fallback_engaged=fallback_engaged(pool),",
        "        fallback_engaged=None,",
        "the published `fallback_engaged` fact becomes None and nothing reddens",
    ),    Mutation(
        "T43",
        "    if queued >= GATE_QUEUE_THRESHOLD:",
        "    if False:  # MUTATION: a deep backlog explains itself",
        "the threshold term is dropped, so a deep backlog no label explains never pages",
    ),
    Mutation(
        "T43",
        "GATE_QUEUE_THRESHOLD = 60",
        "GATE_QUEUE_THRESHOLD = 55",
        "the alarm's copy of the gate's threshold drifts away from the gate's own default",
    ),
    Mutation(
        "T35",
        '            if entry.is_symlink() and os.readlink(entry) == os.devnull:\n                continue  # MASKED: systemd refuses to load it, so it cannot maintain the record\n            return True',
        '            if entry.is_symlink() and os.readlink(entry) == os.devnull:\n                continue  # MASKED: systemd refuses to load it, so it cannot maintain the record\n            return False',
        "an installed .service stops counting as a schedule, so a box that runs the gate loses its floor",
    ),
    Mutation(
        "T35",
        "        if not (plist.is_symlink() and os.readlink(plist) == os.devnull):",
        "        if True:",
        "a MASKED launchd plist counts as a schedule on the one platform this gate really runs on",
    ),
    Mutation(
        "T36",
        '        names = [entry.name for entry in os.scandir(base)]',
        '        names = [entry.name for entry in os.scandir(base)] if False else []',
        "an UNLISTABLE runner root reads as EMPTY again — duplicates registered over invisible installs",
    ),
    Mutation(
        "T38",
        '            record["unverified_cause"] = "disk-unreadable-midpass"',
        '            record["unverified_cause"] = "mid-pass-measurement"',
        "the mid-pass disk failure loses its own cause, so the rendered error blames an install",
    ),
]


def run_tests(only=None):
    passed = 0
    failed = 0
    for case_id, fn in TESTS:
        if only and case_id.split()[0] != only:
            continue
        try:
            fn()
        except Exception as exc:  # noqa: BLE001 — a test runner reports everything
            failed += 1
            print(f"  FAIL {case_id}")
            print(f"       {exc.__class__.__name__}: {exc}")
        else:
            passed += 1
            print(f"  ok   {case_id}")
    print(f"PASS={passed} FAIL={failed}")
    return failed == 0 and passed > 0


def _apply_anchor(src: str, mut) -> str:
    """Replace the mutation's anchor. EXACT only, and LOUD when it does not match.

    ⛔ NO INDENTATION-INSENSITIVE FALLBACK — tried and REVERTED. A fallback that matched stripped
    lines silently spliced a replacement into the middle of a longer line (an anchor line that was a
    PREFIX of the module's) and produced a mutant with a SyntaxError, which reads as "the case did not
    catch it" — a false MISSED pointing at the wrong defect. An anchor that no longer matches must say
    so: `run_mutations` prints it as MISSED, the summary still prints, and the fix is to update the
    anchor to the code it means.
    """
    if src.count(mut.old) != 1:
        raise SystemExit(
            f"mutation anchor not unique in {MODULE_PATH} ({src.count(mut.old)} hits):\n{mut.old}"
        )
    return src.replace(mut.old, mut.new, 1)


def _mutated_module(mut):
    with open(MODULE_PATH, encoding="utf-8") as fh:
        src = fh.read()
    mutated = _apply_anchor(src, mut)
    tmp = tempfile.mkdtemp(prefix="runnerauto-mutant-")
    out = os.path.join(tmp, "runner_autoscale.py")
    with open(out, "w", encoding="utf-8") as fh:
        fh.write(mutated)
    return tmp, out


def _mutation_verdict(returncode: int, body: str) -> bool:
    """CAUGHT only if the paired case RAN and FAILED.

    ⛔ `returncode != 0` is not the test: the runner also exits 1 when the filter matched nothing
    (`PASS=0 FAIL=0`), so a renamed case id would report every mutation CAUGHT while verifying
    nothing. The runner publishes its own summary; the summary is the verdict.
    """
    if returncode == 0:
        return False
    for line in body.splitlines():
        m = re.match(r"\s*PASS=(\d+) FAIL=(\d+)\s*$", line)
        if m:
            return int(m.group(2)) > 0
    return False


def _case_passes_alone(case_id: str) -> tuple[bool, str]:
    """Run ONE case against the SHIPPED module — the CONTROL its mutations are scored against.

    ⛔ A MUTATION IS CAUGHT ONLY IF ITS CASE IS GREEN BEFORE THE MUTATION IS APPLIED (review finding
    P3). `_mutation_verdict` scores CAUGHT on `FAIL>0`, so a case that is red for ANY reason — an
    order-dependent fixture, a host fact leaking in — makes all of its mutants report `✅ CAUGHT`
    while proving nothing. The guard is one run per case, cached, and it runs with NO
    `RUNNER_AUTOSCALE_MODULE` so it measures the file that ships.
    """
    env = dict(os.environ, RUNNER_AUTOSCALE_TEST_ONLY=case_id)
    env.pop("RUNNER_AUTOSCALE_MODULE", None)
    proc = subprocess.run(
        [sys.executable, os.path.abspath(__file__)],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    body = proc.stdout.decode("utf-8", "replace")
    return proc.returncode == 0 and "PASS=1 FAIL=0" in body, body


def run_mutations():
    print("── MUTATION EVIDENCE — each mutation must make its paired case RED ──")
    print("   (the mutated module is written to a temp dir; the shipped file is never touched)\n")
    print("── CONTROLS — every paired case must be GREEN on the SHIPPED module first ──")
    controls: dict[str, bool] = {}
    bad = 0
    for case_id in dict.fromkeys(m.case_id for m in MUTATIONS):
        ok, body = _case_passes_alone(case_id)
        controls[case_id] = ok
        print(f"   {'✅' if ok else '❌'} control {case_id}: {'GREEN' if ok else 'RED'}")
        if not ok:
            for line in body.splitlines():
                print(f"   | {line}")
    print()
    for mut in MUTATIONS:
        # ⛔ A STALE OR DUPLICATE ANCHOR MUST NOT TRUNCATE THE REPORT. `_mutated_module` raises when an
        # anchor no longer matches the module (measured: this suite shipped a `<= 600` anchor after the
        # module moved to `<= 300`, so the run died at 14/16 and the summary line — and two declared
        # mutations — silently vanished while the plain suite stayed green). A mutation that cannot be
        # built is a mutation that verified NOTHING: count it MISSED and say why.
        print(f"── {mut.case_id} mutation → {mut.why}")
        if not controls.get(mut.case_id, False):
            # ⛔ NOT COUNTED AS CAUGHT — and counted as MISSED PER MUTATION, not once per control
            # (review finding P2): charging a whole case's mutants to a single increment printed
            # `CAUGHT=86` for a run in which 84 mutants were verified, which is the number a reviewer
            # quotes as evidence. A red control means this mutation cannot verify anything, and
            # scoring it CAUGHT would be the very false PASS this harness exists to prevent.
            bad += 1
            print("   ❌ CONTROL RED — the paired case fails on the SHIPPED module; NOTHING verified\n")
            continue
        try:
            tmp, out = _mutated_module(mut)
        except SystemExit as exc:
            bad += 1
            print(f"   | {exc}\n")
            print("   ❌ NOT RED — the anchor did not match the module, so NOTHING was verified\n")
            continue
        try:
            proc = subprocess.run(
                [sys.executable, os.path.abspath(__file__)],
                env=dict(
                    os.environ,
                    RUNNER_AUTOSCALE_MODULE=out,
                    RUNNER_AUTOSCALE_TEST_ONLY=mut.case_id,
                ),
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
            body = proc.stdout.decode("utf-8", "replace")
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        for line in body.splitlines():
            print(f"   | {line}")
        if _mutation_verdict(proc.returncode, body):
            print(f"   ✅ RED (the paired case caught the defect, rc={proc.returncode})\n")
        else:
            bad += 1
            if "PASS=0" in body and "FAIL=0" in body:
                print(f"   ❌ NOT RUN — no case matched `{mut.case_id}`; this verified NOTHING\n")
            else:
                print("   ❌ NOT RED — the paired case did NOT catch its own defect\n")
    print(f"MUTATIONS={len(MUTATIONS)} CAUGHT={len(MUTATIONS) - bad} MISSED={bad}")
    return bad == 0


def main(argv=None) -> int:
    argv = argv if argv is not None else sys.argv[1:]
    only = os.environ.get("RUNNER_AUTOSCALE_TEST_ONLY") or None
    if "--mutations" in argv:
        if not run_tests(only):
            print("❌ the plain suite is RED — the mutation evidence below cannot mean anything")
            return 1
        print()
        return 0 if run_mutations() else 1
    return 0 if run_tests(only) else 1


if __name__ == "__main__":
    sys.exit(main())
