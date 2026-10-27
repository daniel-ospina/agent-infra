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
