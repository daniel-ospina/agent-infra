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

HERE = os.path.dirname(os.path.abspath(__file__))
MODULE_PATH = os.path.normpath(os.path.join(HERE, "runner_autoscale.py"))
# The module the CLI assertions drive. It is the MUTATED copy under `--mutations`, so a CLI-level
# assertion has the same teeth as an in-process one.
MODULE_UNDER_TEST = os.environ.get("RUNNER_AUTOSCALE_MODULE") or MODULE_PATH

# Python 3.12 is the tool's own floor (it refuses to run below it), so the suite cannot be a
# 3.9-compatible script and pretend otherwise.
if sys.version_info < (3, 12):
    sys.exit(f"runner_autoscale.test.py requires Python >= 3.12 (got {sys.version.split()[0]})")


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
  [ -f "$FIX/queued" ] || { echo "gh: no queued fixture" >&2; exit 1; }
  cat "$FIX/queued"; exit 0
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
            "RUNNER_AUTOSCALE_ONLINE_WAIT_S": "0",
            "RUNNER_AUTOSCALE_POLL_S": "0",
            "RUNNER_AUTOSCALE_POOL_READ_ATTEMPTS": "3",
            "RUNNER_AUTOSCALE_RETRY_BACKOFF_S": "0",
        }

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


# ── the mutation map ──────────────────────────────────────────────────────────────────────────
class Mutation:
    def __init__(self, case_id, old, new, why):
        self.case_id = case_id
        self.old = old
        self.new = new
        self.why = why


MUTATIONS = [
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
        '    if rc != 0 and _ALREADY_CONFIGURED in out.lower():',
        '    if False:',
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


def _mutated_module(mut):
    with open(MODULE_PATH, encoding="utf-8") as fh:
        src = fh.read()
    if src.count(mut.old) != 1:
        raise SystemExit(
            f"mutation anchor not unique in {MODULE_PATH} ({src.count(mut.old)} hits):\n{mut.old}"
        )
    tmp = tempfile.mkdtemp(prefix="runnerauto-mutant-")
    out = os.path.join(tmp, "runner_autoscale.py")
    with open(out, "w", encoding="utf-8") as fh:
        fh.write(src.replace(mut.old, mut.new, 1))
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
        tmp, out = _mutated_module(mut)
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
        print(f"── {mut.case_id} mutation → {mut.why}")
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
