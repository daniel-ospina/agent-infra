"""#2737 — a `conftest.py` ABOVE this checkout must never be imported.

THE DEFECT THIS PINS. pytest's rootdir determination
(`_pytest/config/findpaths.py::determine_setup`) walks UP from the invocation
directory for a config file, then for a `setup.py`, and whichever it finds
CAPTURES the rootdir — so that directory's `conftest.py` is loaded. Every fleet
runner is SELF-HOSTED with its checkout under a work directory inside `/tmp`
(`/tmp/ai-runner-work-<cell>-<n>/agent-infra/agent-infra`), and `/tmp` carries
other lanes' debris: measured on cell c3-1, `/tmp/pyproject.toml` (a Tortoise
one, `[tool.pytest.ini_options]` at line 284) plus `/tmp/setup.py`. A run started
in that checkout therefore captured rootdir at `/tmp` and imported
`/tmp/conftest.py` — another project's 133 KB E2E conftest — and main went red
with `ModuleNotFoundError: No module named 'httpx'`, a failure that says nothing
about agent-infra.

WHY IT WAS INTERMITTENT, WHICH IS WHY IT NEEDS A TEST AND NOT JUST A FILE. With
no inifile and no `setup.py` above it, the same geometry is GREEN (rootdir stays
at the invocation's common ancestor, so the parent conftest is never reached),
which is why runs 40118809756 (cell c3-3) and 40122940309 (c3-1) both died while
a run between them, on a cell without that debris, was green. A green run proves
nothing about the next cell, so the fix has to be immunity in the checkout.

WHAT IS ASSERTED — two arms over the SAME runner geometry, with the parent debris
PLANTED BY THE TEST so that neither arm depends on what the box happens to have:
  (A) WITH the shipped `pytest.ini` — it is the nearest inifile to the nested run,
      so rootdir lands on the checkout and the parent's poison is never imported:
      the nested run is green and collects its test.
  (B) MUTATION — the same tree WITHOUT it: the parent's config captures rootdir,
      the parent's conftest is imported, and the run is not green. This is what
      makes (A) load-bearing rather than a poison that never fired.

⛔ Both arms plant their own parent debris on purpose. An earlier cut of this
suite relied on the box's own `/tmp` debris for arm (B) and therefore REDD on a
clean runner (a GitHub-hosted `ubuntu-latest`, or a freshly provisioned cell) —
the exact box-dependence the change exists to remove, wired into a required job.
Measured: with the pytest temp root moved to a clean directory, arm (B) failed on
a healthy box. Do not reintroduce that by dropping the planted files.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# The loader must be spelled as a raise so an import is unmissable in the output.
POISON = 'raise RuntimeError("POISON-CONFTEST-LOADED: a conftest above the checkout was imported")\n'
# The smallest ancestor inifile pytest recognises — this is the debris that
# captured rootdir on the incident box (`/tmp/pyproject.toml`).
ANCESTOR_CONFIG = "[tool.pytest.ini_options]\n"


def _nested_run(tmp_path: Path, *, with_shipped_ini: bool) -> tuple[int, str]:
    """The runner geometry — `<cell>/runner-workspace/agent-infra`, poisoned above — run for real."""
    workspace = tmp_path / "ai-runner-work-c3-1" / "agent-infra"
    (workspace / "tests").mkdir(parents=True)
    # The debris, planted rather than inherited from the host.
    (tmp_path / "ai-runner-work-c3-1" / "conftest.py").write_text(POISON)
    (tmp_path / "ai-runner-work-c3-1" / "pyproject.toml").write_text(ANCESTOR_CONFIG)
    (workspace / "tests" / "test_ok.py").write_text("def test_ok():\n    assert True\n")
    if with_shipped_ini:
        shutil.copyfile(REPO / "pytest.ini", workspace / "pytest.ini")
    r = subprocess.run(
        [sys.executable, "-m", "pytest", "tests/test_ok.py", "-q", "-p", "no:cacheprovider"],
        cwd=workspace,
        capture_output=True,
        text=True,
        timeout=120,
    )
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def test_the_shipped_config_cuts_the_conftest_search_at_the_checkout(tmp_path: Path) -> None:
    """(A) The shipped pytest.ini keeps a poisoned parent out of this checkout's run."""
    shipped = REPO / "pytest.ini"
    assert shipped.is_file(), (
        "pytest.ini is missing from the checkout root (#2737): nothing pins this checkout as "
        "pytest's root, so a config file above it (every runner checks out under /tmp) captures "
        "rootdir and its conftest.py is imported into the test job"
    )
    code, out = _nested_run(tmp_path, with_shipped_ini=True)
    assert "POISON-CONFTEST-LOADED" not in out, (
        "a conftest.py ABOVE the checkout was imported (#2737) — the shipped pytest.ini no longer "
        "pins this checkout as pytest's root\n" + out[-3000:]
    )
    assert code == 0, "the nested run is not green:\n" + out[-3000:]
    assert "1 passed" in out, (
        "the nested run collected nothing, so a green would certify nothing:\n" + out[-3000:]
    )


def test_the_same_geometry_without_the_config_does_import_the_parent(tmp_path: Path) -> None:
    """(B) MUTATION — without the config the parent's conftest IS imported, so (A) is not vacuous.

    The assertion names the poison this test planted and nothing weaker: a substring
    like "conftest.py" would be satisfied by output that merely MENTIONS the file.
    """
    code, out = _nested_run(tmp_path, with_shipped_ini=False)
    assert "POISON-CONFTEST-LOADED" in out, (
        "without pytest.ini the parent's conftest was NOT imported, so this suite cannot tell a "
        "cut conftest search from a poison that never fired — arm (A) would certify nothing "
        "(code=%r). pytest's rootdir determination changed; re-derive the failure mode before "
        "removing pytest.ini\n%s" % (code, out[-3000:])
    )
    assert code != 0, "the poisoned nested run did not fail:\n" + out[-3000:]
    assert "1 passed" not in out, "the poisoned nested run still reported a pass:\n" + out[-3000:]
