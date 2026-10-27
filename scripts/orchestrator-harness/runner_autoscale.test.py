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

import importlib.util
import json
import os
import re
import shutil
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
  [ -f "$FIX/token.fail" ] && { echo "gh: HTTP 401: Bad credentials (fixture)" >&2; exit 1; }
  printf 'tok-fixture\n'; exit 0
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

    def queued(self, n):
        self._write(os.path.join(self.dir, "queued"), f"{n}\n")

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
        shutil.rmtree(self.dir, ignore_errors=True)


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


def cli(box: Box, *args) -> tuple[int, str]:
    """Run the SHIPPED entry point with the fixture's seams — exit codes are a contract, and a
    verdict is not a substitute for one (`--want` refused, starvation alarm, unmeasurable)."""
    box.apply()
    proc = subprocess.run(
        [sys.executable, MODULE_UNDER_TEST, *args],
        env=dict(os.environ, **box.env),
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
                env=dict(os.environ, **box.env),
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
        got = ra.resolve_labels(pool, "x86_64", notes=notes)
        check(got == "self-hosted-x64,ubuntu-latest", f"gate-engaged set was {got!r}")
        check(got.count(ra.FALLBACK_LABEL) == 1, f"{ra.FALLBACK_LABEL} written twice: {got!r}")
        check(notes == [], f"the gate path must not claim the floor, notes={notes}")
        check(ra.label_floor_binds(pool) is False, "a pool WITH the label does not bind the floor")

        # The other half: the floor is SATISFIED by a non-arm runner, the gate is NOT engaged, and
        # the arch runner must therefore stay arch-only — the pre-floor behaviour, unchanged.
        satisfied = {
            "x86-1": ra.PoolEntry(
                name="x86-1", status="online", busy=False,
                labels=["self-hosted", "self-hosted-x64", ra.FALLBACK_LABEL],
            )
        }
        notes = []
        got = ra.resolve_labels(satisfied, "x86_64", notes=notes)
        check(got == "self-hosted-x64", f"a satisfied floor must add nothing, got {got!r}")
        check(notes == [], f"no floor note when the floor is satisfied, notes={notes}")


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
                ra.starvation_probe.__defaults__ == (30.0,),
                "the probe's SIGNATURE default is the documented 30s, not a stale copy: "
                f"{ra.starvation_probe.__defaults__}",
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


@test("T17 install REFUSES a missing WorkingDirectory — and writes NOTHING")
def t17_missing_workdir_refused():
    with Env():
        box = Box("unit-missing")
        try:
            box.apply()
            # ⛔ NOT under the fixture's tmpdir: that path is TRANSIENT, so it would be refused for
            # its SHAPE and this case would never exercise the exists() check it is about. A path
            # under the (durable) home is refused for exactly one reason: it is not there.
            gone = os.path.join(str(Path.home()), "runnerauto-definitely-absent-cwd")
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
            specifier = str(Path.home()) + "/ra-%h-literal-dir"
            newline = str(Path.home()) + "/x\nExecStartPre=/bin/false"
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
            code2, out2 = cli(box, "--install-unit", "--workdir", str(Path.home()))
            check(code2 == 0, f"a re-install must succeed, got {code2}: {out2}")
            check(
                f"WorkingDirectory={Path.home()}"
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
            code2, out2 = cli(box, "--install-unit", "--workdir", str(Path.home()))
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
                any(n.startswith("unit cwd: ") for n in record["notes"]),
                f"…and NAMED in the human notes: {record['notes']}",
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


# ── the mutation map ──────────────────────────────────────────────────────────────────────────
class Mutation:
    def __init__(self, case_id, old, new, why):
        self.case_id = case_id
        self.old = old
        self.new = new
        self.why = why


MUTATIONS = [
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
        "        if not Path(path).exists():",
        "        if False:",
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
        '            try:\n                files.extend(sorted(entry.iterdir()))\n            except OSError as exc:',
        '            try:\n                files.extend(sorted(entry.iterdir()))\n            except ZeroDivisionError as exc:',
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
        '''        record["unit_cwd_problems"] = unit_problems
        record["notes"].extend(f"unit cwd: {p}" for p in unit_problems)''',
        """        record["problems"].extend(unit_problems)""",
        "a stale unit file is folded into `problems`, so every pass on that cell reports failure",
    ),
    Mutation(
        "T21",
        '''        record["notes"].extend(f"unit cwd: {p}" for p in unit_problems)''',
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
        '        if entry.is_dir() and name.endswith(".d"):',
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
        "    if not path.is_dir():",
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
        '            labels = resolve_labels(\n                pool, machine, notes=record["notes"], current=c["labels"]\n            )',
        '            labels = resolve_labels(\n                pool, machine, notes=record["notes"]\n            ) if not c["labels"] else _preserve_labels(c["labels"], machine)',
        "the PRE-FIX either/or: a DEAD runner preserves its labels and the floor is never reached",
    ),
    Mutation(
        "T4",
        '    stash = _clear_local_config(directory) if replace else {}',
        '    stash: dict[str, bytes] = {}',
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
        '    except OSError as exc:\n        _restore_local_config(directory, stash)',
        '    except OSError as exc:\n        pass',
        "a clear that fails partway leaves the install half-cleared (no .runner: invisible, slot FREE)",
    ),
    Mutation(
        "T6",
        '    finally:\n        if not registered:\n            _restore_local_config(directory, stash)',
        '    finally:\n        if not registered and "rc" in locals() and rc != 0:\n            _restore_local_config(directory, stash)',
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
        '    except Unmeasurable as exc:\n        return {"state": "unmeasured", "detail": str(exc)}',
        '    except Unmeasurable as exc:\n        return {"state": "ok"}',
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


def run_mutations():
    print("── MUTATION EVIDENCE — each mutation must make its paired case RED ──")
    print("   (the mutated module is written to a temp dir; the shipped file is never touched)\n")
    bad = 0
    for mut in MUTATIONS:
        # ⛔ A STALE OR DUPLICATE ANCHOR MUST NOT TRUNCATE THE REPORT. `_mutated_module` raises when an
        # anchor no longer matches the module (measured: this suite shipped a `<= 600` anchor after the
        # module moved to `<= 300`, so the run died at 14/16 and the summary line — and two declared
        # mutations — silently vanished while the plain suite stayed green). A mutation that cannot be
        # built is a mutation that verified NOTHING: count it MISSED and say why.
        print(f"── {mut.case_id} mutation → {mut.why}")
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
