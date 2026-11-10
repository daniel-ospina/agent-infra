#!/usr/bin/env python3
"""Tests for the cmux-dispatcher resolver (#1957).

The defect these pin is a farmed consumer shipping without the executable it calls:

    DISPATCH="${SAFE_SEND_DISPATCH:-/Users/danielospina/Documents/GitHub/tortoise/tools/cmux_dispatch.py}"

`scripts/safe-send.sh` is in `pi-bootstrap/setup.sh`'s `fleet_srcs`, so it lands on every box, while
`cmux_dispatch.py` belongs to ANOTHER checkout (`daniel-ospina/tortoise`, `tools/`) and is in no farm
array. On every box that is not the owner's the send path ran an interpreter against a nonexistent
file: the producer never ran, and the rc came from the INTERPRETER — indistinguishable from a
dispatcher verdict. Measured 2026-11-09 on the Linux box this was fixed on: `/Users` does not exist,
and the checkout is at `$HOME/tortoise`, so the literal missed even the naming convention the rest of
the fleet assumes.

What is pinned here is the CONTRACT, not the code shape:

  * the candidate list is ORDERED and DE-DUPLICATED, with the FARM DESTINATION first — so the day a
    farm (tortoise's own, or a future vendoring) delivers the producer there, this consumer uses it
    with no change (#1957's delivery arm);
  * an OVERRIDE is the whole answer — a caller that names the producer is never quietly bypassed by a
    discovered one, which is what makes `SAFE_SEND_DISPATCH=<stub>` a proof of the rc→state mapping;
  * a MISSING producer is refused with every path it looked in, BEFORE anything is sent — the
    injection arm at the bottom drives the real `safe-send.sh` and asserts that nothing ran;
  * a python < 3.12 is never accepted as the dispatcher's interpreter on name alone;
  * `-f`, not `-x`: the producer is read by the interpreter, and a non-executable `.py` is fine.

The end-to-end arms run `safe-send.sh --force` with `HOME`, `TORTOISE_REPO` and `SAFE_SEND_DISPATCH`
stripped, and with a `python3.12` THE ARM PLANTS on its own `PATH` (`_plant_python312`), so BOTH halves
of the resolution are the host's OUTSIDE this repo — a **device-independent statement** about a box
with no tortoise checkout, not about this laptop. (The producer is the arm's; the interpreter must be
the arm's too, or the arm asserts a property of the runner image instead — #3836 F1.)
"""
from __future__ import annotations

import os
import shlex
import shutil
import subprocess
import sys
import textwrap

import pytest

_HERE = os.path.dirname(os.path.abspath(__file__))
_LIB = os.path.join(_HERE, "lib", "cmux-dispatch-path.sh")
_SAFE_SEND = os.path.join(_HERE, "safe-send.sh")
# Resolved ONCE, by absolute path: several arms hand the child a PATH that contains only a fake bin (to
# control what the interpreter ladder can see), and a `bash` looked up through THAT PATH would not exist.
_BASH = shutil.which("bash") or "/bin/bash"


def _bash(script: str, env: dict | None = None, cwd: str | None = None) -> subprocess.CompletedProcess:
    """Run `script` under bash with a scrubbed environment.

    The scrub is the point: this box exports `TORTOISE_REPO`, and `HOME=/home/cmux` carries a real
    tortoise checkout — either of which would satisfy the resolver and turn a "nothing resolves"
    assertion green by accident. Every arm states the environment it means.
    """
    base = {
        "PATH": "/usr/local/bin:/usr/bin:/bin",
        "HOME": "/nonexistent-home-for-the-test",
        "LC_ALL": "C",
    }
    base.update(env or {})
    return subprocess.run([_BASH, "-c", script], capture_output=True, text=True,
                          env=base, cwd=cwd)


def _candidates(override: str = "", scripts: str = "", env: dict | None = None) -> list[str]:
    pre = f'SCRIPTS="{scripts}"; ' if scripts else "unset SCRIPTS; "
    r = _bash(pre + f'. "{_LIB}"; cmux_dispatch_candidates "{override}"', env=env)
    assert r.returncode == 0, r.stderr
    return [ln for ln in r.stdout.splitlines() if ln]


# ── the candidate list: ordered, deduplicated, farm destination first ───────────────────────────────

def test_farm_destination_is_the_FIRST_candidate():
    """`$SCRIPTS/cmux_dispatch.py` comes first, and it is the whole delivery arm of #1957.

    It is where a farmed consumer's siblings land on every farmed box (`$HOME/.pi/agent/scripts`) and
    in a checkout (`<repo>/scripts`), so a delivery of the producer there needs no change here — and
    it is the location `pi-bootstrap/tests/test-setup-no-nesting.sh` DERIVES, which is why the
    undispositioned producer is a DECLARED gap rather than an invisible one.
    """
    got = _candidates(scripts="/some/scripts")
    assert got[0] == "/some/scripts/cmux_dispatch.py", got


def test_the_Mac_literal_is_no_longer_a_default_and_no_candidate_is_absolute():
    """Every candidate is BOX-RELATIVE. The defect was one literal path into one checkout.

    The Mac-shaped clone is still a CANDIDATE (`$HOME/Documents/GitHub/tortoise`, below) — that is
    discovery, not a default: it is tried after the farm destination, `TORTOISE_REPO` and a derived
    sibling, and it is rendered from `$HOME` rather than spelled absolutely.
    """
    got = _candidates(scripts="/some/scripts", env={"HOME": "/h"})
    assert "/Users/" not in " ".join(got), got
    assert "/h/Documents/GitHub/tortoise/tools/cmux_dispatch.py" in got, got
    for c in got:
        assert c.startswith("/some/scripts") or c.startswith("/h/"), c


def test_an_OVERRIDE_is_the_WHOLE_answer():
    """A named producer is never displaced by a discovered one.

    This is what makes `SAFE_SEND_DISPATCH=<stub>` a proof of the rc→state mapping instead of a
    hopeful suggestion — the arm that shipped before this relied on it (`brief-gate.test.sh` sets
    `SAFE_SEND_DISPATCH=/bin/true` in every deeper arm, because on CI there is no checkout to find).
    """
    got = _candidates(override="/stub/cmux_dispatch.py", scripts="/some/scripts")
    assert got == ["/stub/cmux_dispatch.py"], got


def test_TORTOISE_REPO_outranks_the_derived_and_conventional_clones():
    got = _candidates(scripts="/some/scripts",
                      env={"TORTOISE_REPO": "/opt/tortoise", "HOME": "/h"})
    assert got[1] == "/opt/tortoise/tools/cmux_dispatch.py", got
    assert got.index("/opt/tortoise/tools/cmux_dispatch.py") < \
        got.index("/h/Documents/GitHub/tortoise/tools/cmux_dispatch.py"), got


def test_the_derived_SIBLING_checkout_is_used_without_any_configured_path():
    """A sibling checkout is derived from this repo's own git common dir — never a literal.

    `--git-common-dir` is the point: a lane runs in a LINKED WORKTREE, where the naive reading of
    `$SCRIPTS/..` is the worktree, not the checkout the fleet clones beside tortoise. So the candidate
    must be `<parent-of-the-MAIN-checkout>/tortoise/tools/cmux_dispatch.py` even when this file is
    loaded from a worktree — which is exactly where this suite runs.
    """
    # ⛔ THE CONVENTIONAL PATH IS COMPUTED FROM THE ENV THIS ARM SETS, NOT FROM THIS BOX'S HOME.
    # This arm used to guard the ordering assertion with `"/h/…" in got`, i.e. a path no env here
    # ever produces: the expression was `assert True` (MEASURED: 0 occurrences of `/h/`), so moving
    # the derived sibling BELOW the conventional clones — the exact regression the comment above it
    # promises to catch — reddened no row at all (#3836 F3).
    conv = "/h/Documents/GitHub/tortoise/tools/cmux_dispatch.py"
    got = _candidates(scripts=_HERE, env={"HOME": "/h"})
    assert "/Users/" not in " ".join(got), got
    common_dir = subprocess.run(
        ["git", "-C", _HERE, "rev-parse", "--path-format=absolute", "--git-common-dir"],
        capture_output=True, text=True).stdout.strip()
    assert common_dir, "this suite must run inside the checkout: the derivation is what is under test"
    expected = os.path.join(os.path.dirname(os.path.dirname(common_dir)),
                            "tortoise", "tools", "cmux_dispatch.py")
    assert expected in got, (expected, got)
    # ...and it outranks the box's conventional clones, so a sibling checkout wins over a stale clone
    # in the owner's `~/Documents` — the ordering is the contract, not just membership.
    assert conv in got, (conv, got)
    assert got.index(expected) < got.index(conv), got


def test_the_list_is_DEDUPLICATED():
    """Candidates 1 and 2 must be the SAME STRING for this contract to be observable at all.

    The dedup is `awk 'NF && !seen[$0]++'`, i.e. BYTE-EXACT. So `SCRIPTS=/x/tortoise/tools` with
    `TORTOISE_REPO=/x/tortoise/tools/..` — this arm as it first shipped — produced two candidates
    that are the same FILE but different STRINGS (`…/tools/…` vs `…/tools/../tools/…`), which the
    dedup is right to keep: `!seen[]` never fires, so `got.count(got[0]) == 1` was true by
    construction and the arm stayed green under a `| cat` mutant (MEASURED, #3836 F2). Under #3442
    rule 3 an assertion no mutation of the diff can vary is dead weight that tells the next reader
    dedup is covered.

    `TORTOISE_REPO=/x/tortoise` collides candidate 2 with candidate 1 on the exact same string.
    """
    dup = "/x/tortoise/tools/cmux_dispatch.py"
    got = _candidates(scripts="/x/tortoise/tools", env={"TORTOISE_REPO": "/x/tortoise"})
    assert got[0] == dup, got
    assert got.count(dup) == 1, got          # the collision is real; it is listed once
    assert len(got) == len(set(got)), got


def test_SOURCING_under_set_eu_does_not_abort_on_a_non_checkout(tmp_path):
    """CONSUMER CONTRACT: a `set -e` caller must not die on "there is no sibling checkout here".

    The sibling candidate is derived with a `git -C` call that legitimately FAILS on a non-checkout —
    and on `$HOME/.pi/agent/scripts`, which is exactly where this lib is farmed to. A plain
    assignment holding a failed command substitution makes the SHELL exit, so "no sibling checkout"
    would kill the send path with a bare rc that looks like a dispatcher verdict — the silent failure
    #1957 exists to remove, one level down. Nothing breaks today (`safe-send.sh` does not use `-e`);
    this arm is what keeps the next `set -e` consumer from inheriting it.

    ⛔ `-o pipefail` IS PART OF THE FIXTURE, not decoration: the candidate list is emitted through an
    internal `| awk` pipeline, so under plain `set -e` the pipeline's status is `awk`'s (0) and the
    failure is swallowed. `pipefail` is what makes the subshell's abort reach the caller — MEASURED:
    with `|| true` stripped from the git probe, this arm exits 128; as shipped it exits 0.
    """
    scripts = tmp_path / "not-a-checkout" / "scripts"
    scripts.mkdir(parents=True)
    r = _bash(f'set -euo pipefail; SCRIPTS="{scripts}"; . "{_LIB}"; cmux_dispatch_candidates')
    assert r.returncode == 0, (r.returncode, r.stdout, r.stderr)
    assert r.stdout.splitlines()[0] == f"{scripts}/cmux_dispatch.py", r.stdout


def test_an_UNSET_HOME_renders_as_a_HOME_shaped_candidate_not_as_a_root_path():
    """A launchd/systemd job can run with HOME unset; `/tortoise/tools/…` is not a path any box has."""
    r = _bash(f'unset SCRIPTS HOME; . "{_LIB}"; cmux_dispatch_candidates')
    assert r.returncode == 0, r.stderr
    assert "/tortoise/tools/cmux_dispatch.py" in r.stdout, r.stdout
    for line in r.stdout.splitlines():
        assert not line.startswith("/tortoise"), line


# ── resolution: `-f`, not `-x` ──────────────────────────────────────────────────────────────────────

def test_a_non_executable_producer_resolves(tmp_path):
    """The producer is invoked as `"$PY312" "$DISPATCH" send …` — it never needs the execute bit.

    A `-x` test would refuse a perfectly good `.py` and report the send path as dead on a box that
    could have sent.
    """
    scripts = tmp_path / "scripts"
    scripts.mkdir()
    target = scripts / "cmux_dispatch.py"
    target.write_text("print('hi')\n")
    got = _bash(f'SCRIPTS="{scripts}"; . "{_LIB}"; cmux_dispatch_resolve').stdout.strip()
    assert got == str(target), got


def test_resolve_returns_1_and_prints_nothing_when_no_candidate_exists(tmp_path):
    r = _bash(f'SCRIPTS="{tmp_path}"; HOME="{tmp_path}/home"; . "{_LIB}"; '
              f'cmux_dispatch_resolve || echo "RC=$?"')
    assert r.stdout.strip() == "RC=1", r.stdout
    assert r.returncode == 0, r.stderr


# ── safe-send.sh, end to end: the refusal happens BEFORE anything runs ──────────────────────────────

def _safe_send_fixture(tmp_path):
    """A copy of safe-send.sh + its lib in an isolated `scripts/` dir.

    The copy is what makes the arms device-independent: `$SCRIPTS` becomes the temp dir, so the
    resolution depends only on the environment each arm states — not on this box's `~/tortoise`, and
    not on this repo being a checkout at all.
    """
    scripts = tmp_path / "scripts"
    (scripts / "lib").mkdir(parents=True)
    shutil.copy(_SAFE_SEND, scripts / "safe-send.sh")
    shutil.copy(_LIB, scripts / "lib" / "cmux-dispatch-path.sh")
    (tmp_path / "home").mkdir()
    brief = tmp_path / "brief.txt"
    brief.write_text("a lane brief\n")
    return scripts / "safe-send.sh", brief, tmp_path / "home"


def _plant_python312(tmp_path):
    """A `python3.12` THE ARM OWNS, first on the arm's `PATH` -> (path, the stub's invocation log).

    ⛔ WHY THE POSITIVE CONTROLS NEED THIS (#3836 F1): both of them pin `PATH` so the resolution is
    the environment the arm states — and then required the INTERPRETER ladder (`safe-send.sh:245-250`
    -> `exit 5`) to find a `python >= 3.12` in the RUNNER IMAGE. Nothing in the arm provided one, so
    the assertion's truth value was a property of the machine: green here and on `ubuntu-24.04`
    (`/usr/bin/python3` = 3.12), RED on any runner whose `/usr/bin`/`/usr/local/bin` python is
    3.10-3.11 (`ubuntu-22.04`, Debian 12, a self-hosted runner) — on a REQUIRED job (`ci.yml:294`,
    `ci-main.yml:796`). That is the one device-dependence this suite's own docstring disclaims, and
    it is the shape `tests/test_pytest_root_cut.py` records this repo already paying for once.

    The stub is NAMED `python3.12` because the ladder takes a versioned name at its word (the name IS
    the version — see `cmux_dispatch_python_candidates`), so no probe decides anything: it execs the
    interpreter running this suite, whichever that is. Its log is the DECISIVE assertion — it proves
    the ladder picked the arm's interpreter rather than the image's, which is what keeps the fix
    non-vacuous on a host (like this one) that carries a 3.12 of its own: remove the plant and the
    log is absent even though the arm still passes.
    """
    bindir = tmp_path / "bin"
    bindir.mkdir()
    log = tmp_path / "python-invoked.log"
    real = sys.executable or shutil.which("python3") or "/usr/bin/python3"
    stub = bindir / "python3.12"
    stub.write_text(textwrap.dedent(f"""\
        #!/bin/sh
        printf '%s\\n' "$*" >> {str(log)!r}
        exec {shlex.quote(real)} "$@"
    """))
    stub.chmod(0o755)
    return f"{bindir}:/usr/local/bin:/usr/bin:/bin", log


def _run_safe_send(tmp_path, *args, env=None, path_prefix=None):
    ss, brief, home = _safe_send_fixture(tmp_path)
    bare = {"PATH": (f"{path_prefix}:/usr/local/bin:/usr/bin:/bin" if path_prefix
                     else "/usr/local/bin:/usr/bin:/bin"),
            "HOME": str(home)}
    bare.update(env or {})
    return subprocess.run(["bash", str(ss), "0000-1111", "lane", str(brief), *args],
                          capture_output=True, text=True, env=bare, cwd=str(tmp_path))


def test_safe_send_REFUSES_before_running_anything_when_the_producer_is_missing(tmp_path):
    """#1957's measured failure, pinned: rc 5 is the INTERPRETER's on a missing file, and it reads as
    a dispatcher verdict. Now it is a refusal that names the producer and every path it tried.

    `--force` is deliberate: it bypasses the brief gate and the busy/idle probes, so the arm reaches
    the send path directly and can only fail for the reason under test.
    """
    r = _run_safe_send(tmp_path, "--force")
    assert r.returncode == 5, (r.returncode, r.stdout, r.stderr)
    assert "cmux_dispatch.py NOT FOUND" in r.stderr, r.stderr
    # ⛔ THE LIST IS THE CONTRACT: a refusal that does not say WHERE it looked sends the operator to
    # guess, and every one of these causes needs a different fix.
    assert "Looked in (in order):" in r.stderr, r.stderr
    assert str(tmp_path / "scripts" / "cmux_dispatch.py") in r.stderr, r.stderr
    assert str(tmp_path / "home" / "Documents" / "GitHub" / "tortoise" / "tools"
               / "cmux_dispatch.py") in r.stderr, r.stderr
    # Nothing was sent, and no interpreter was pointed at a file that is not there.
    assert "UNKNOWN [lane]" not in r.stdout, r.stdout
    assert "AMBIGUOUS [lane]" not in r.stdout, r.stdout


def test_safe_send_NAMES_a_bad_OVERRIDE_as_the_override(tmp_path):
    """An explicit answer that does not exist is the CALLER's bug, and the message says so."""
    r = _run_safe_send(tmp_path, "--force", env={"SAFE_SEND_DISPATCH": "/nope/cmux_dispatch.py"})
    assert r.returncode == 5, (r.returncode, r.stdout, r.stderr)
    assert "Looked in (in order): /nope/cmux_dispatch.py" in r.stderr, r.stderr
    assert "SAFE_SEND_DISPATCH=/nope/cmux_dispatch.py" in r.stderr, r.stderr


def test_safe_send_RESOLVES_a_sibling_producer_on_a_box_with_no_checkout(tmp_path):
    """POSITIVE CONTROL, and it is the one that would have caught the defect: a box with NO tortoise
    checkout and NO override still sends, because the producer is resolved from the farm destination.

    `brief-gate.test.sh` had to set `SAFE_SEND_DISPATCH=/bin/true` in every arm for the OPPOSITE
    reason — on CI nothing resolved — so this arm is what makes the sibling-first contract real.
    """
    ss, brief, home = _safe_send_fixture(tmp_path)
    path, py_log = _plant_python312(tmp_path)
    mark = tmp_path / "mark.txt"
    (tmp_path / "scripts" / "cmux_dispatch.py").write_text(textwrap.dedent(f"""
        import os, sys
        open({str(mark)!r}, "w").write(" ".join(sys.argv[1:]))
        sys.exit(0)
    """).lstrip())
    r = subprocess.run(["bash", str(ss), "0000-1111", "lane", str(brief), "--force"],
                       capture_output=True, text=True, cwd=str(tmp_path),
                       env={"PATH": path, "HOME": str(home)})
    assert r.returncode == 0, (r.returncode, r.stdout, r.stderr)
    assert mark.exists(), (r.stdout, r.stderr)
    assert mark.read_text().startswith("send --workspace 0000-1111 --label lane"), mark.read_text()
    # the interpreter came from the ARM, not from the runner image (#3836 F1)
    assert py_log.exists(), (r.stdout, r.stderr)
    assert "send --workspace 0000-1111" in py_log.read_text(), py_log.read_text()


def test_the_producer_is_the_ONLY_thing_read_needs_no_execute_bit_and_still_sends(tmp_path):
    """Same positive control with the producer NOT executable: `-x` would have refused it."""
    ss, brief, home = _safe_send_fixture(tmp_path)
    path, py_log = _plant_python312(tmp_path)
    mark = tmp_path / "mark2.txt"
    producer = tmp_path / "scripts" / "cmux_dispatch.py"
    producer.write_text(f'import os\nopen({str(mark)!r}, "w").write("ran")\n')
    producer.chmod(0o444)
    r = subprocess.run(["bash", str(ss), "0000-1111", "lane", str(brief), "--force"],
                       capture_output=True, text=True, cwd=str(tmp_path),
                       env={"PATH": path, "HOME": str(home)})
    assert r.returncode == 0, (r.returncode, r.stdout, r.stderr)
    assert mark.read_text() == "ran"
    assert py_log.exists(), (r.stdout, r.stderr)  # the arm's interpreter, not the image's (#3836 F1)


def test_a_python_older_than_3_12_is_never_accepted_on_NAME_alone(tmp_path):
    """`command -v python3` is not a version claim.

    The shipped line was `PY312="${SAFE_SEND_PYTHON:-$(command -v python3.12 || true)}"` plus a
    `/Users/<owner>/.local/bin/python3.12` fallback. Accepting a bare `python3` on name would let a 3.9
    box run a 3.12-only dispatcher and surface the SyntaxError as a DELIVERY VERDICT.

    `PATH` holds ONLY the fake bin, so the ladder sees nothing but the 3.9 stub — and the last candidate
    (`$HOME/.local/bin/python3.12`) is pointed at an empty home.
    """
    fake = tmp_path / "bin"
    fake.mkdir()
    stub = fake / "python3"
    # The resolver asks the INTERPRETER, not its `--version` string: `-c 'sys.version_info >= (3, 12)'`.
    # So the stub answers that question "no" — which is what a 3.9 box does — instead of only printing a
    # version banner a name-based check would have believed.
    stub.write_text(textwrap.dedent("""
        #!/bin/sh
        case "$*" in *"sys.version_info >= (3, 12)"*) exit 1 ;; esac
        exit 0
    """).lstrip())
    stub.chmod(0o755)
    r = _bash(f'. "{_LIB}"; cmux_dispatch_python_resolve || echo "RC=$?"',
              env={"PATH": str(fake), "HOME": str(tmp_path / "emptyhome")})
    assert r.stdout.strip() == "RC=1", (r.stdout, r.stderr)


def test_a_python3_reporting_3_12_on_the_same_ladder_IS_accepted(tmp_path):
    """POSITIVE CONTROL for the arm above: the version check admits a real 3.12, so the refusal is
    about the VERSION and not about a bare `python3` being banned outright."""
    fake = tmp_path / "bin"
    fake.mkdir()
    stub = fake / "python3"
    stub.write_text('#!/bin/sh\nexit 0\n')
    stub.chmod(0o755)
    r = _bash(f'. "{_LIB}"; cmux_dispatch_python_resolve',
              env={"PATH": str(fake), "HOME": str(tmp_path / "emptyhome")})
    assert r.stdout.strip() == str(stub), (r.stdout, r.stderr)


def test_the_interpreter_ladder_names_every_path_it_tried_including_the_override(tmp_path):
    r = _bash(f'. "{_LIB}"; cmux_dispatch_python_candidates_one_line /nope/python3.12')
    assert r.stdout.strip() == "/nope/python3.12", r.stdout


def test_safe_send_still_exits_78_for_a_missing_brief_gate(tmp_path):
    """PRECEDENCE, pinned: the brief gate is the FIRST refusal, so a caller that reads 78 keeps
    reading 78. Moving the producer check ahead of it would reclassify every broken-install refusal
    as a dispatch failure.

    ⛔ NO PRODUCER IS WRITTEN HERE, AND THAT IS THE FIXTURE (#3836 F4). This arm used to place a
    RESOLVABLE `cmux_dispatch.py` first, so the precedence was never exercised: with a producer
    present, a producer check moved ahead of the brief gate resolves, falls through, and still exits
    78 — MEASURED, the whole block deleted left this arm green. BOTH refusals present is the only
    state in which order is observable, so the brief gate has to win with nothing else resolvable.
    """
    ss, _brief, home = _safe_send_fixture(tmp_path)
    brief = tmp_path / "nobrief.txt"
    brief.write_text("no research contract here\n")
    r = subprocess.run(["bash", str(ss), "0000-1111", "lane", str(brief)],
                       capture_output=True, text=True, cwd=str(tmp_path),
                       env={"PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": str(home),
                            "AGENT_INFRA_PATH": str(tmp_path / "absent")})
    assert r.returncode == 78, (r.returncode, r.stdout, r.stderr)
    # the refusal is the BRIEF gate's, so a mutant that reorders the blocks reddens on rc AND here
    assert "brief-gate.sh not found" in r.stderr, r.stderr
    assert "cmux_dispatch.py NOT FOUND" not in r.stderr, r.stderr


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
