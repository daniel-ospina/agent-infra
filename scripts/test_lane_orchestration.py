#!/usr/bin/env python3
"""test_lane_orchestration.py — the lane-orchestration layer's own regression pins (#1552).

The layer was versioned from live, untracked files, so its review findings are exactly the
class that ships as SILENT fleet behaviour. These tests pin three of them:

  * the stall screener inside ``scripts/lane/orchestrator-heartbeat.sh`` must resolve its
    path where expansion can happen AND must FAIL OPEN — a missing or crashing screener
    alerts instead of suppressing every WEAK verdict (the whole stall/idle family);
  * ``lane-triage.py`` is invoked from the FARMED copy (``$SCRIPTS``), not the ``state/``
    path ``pi-bootstrap/setup.sh`` never provisions;
  * every ``scripts/lane/*.sh`` is inside CI's bash syntax sweep (``SWEEP_GLOBS``);
  * the lane classifier has ONE home after the #1553 rebase (main's promoted ``scripts/``
    copies), not a second Oct-1 snapshot under ``scripts/lane/``.

Each behavioural assertion is written to FAIL on the pre-fix source — the non-vacuity
proof for the P1 findings. The screener block is extracted VERBATIM from the shell file
and executed as a subprocess against synthetic lane rows under a throwaway HOME, which is
how the finding was reproduced.
"""
from __future__ import annotations

import glob
import json
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent
HEARTBEAT = HERE / "lane" / "orchestrator-heartbeat.sh"
SHARDS = HERE / "run-bash-shards.sh"
SETUP = REPO_ROOT / "pi-bootstrap" / "setup.sh"

# The stall-verdict Python is the single-quoted argument of the second `python3 -c '…'`.
_BLOCK_RE = re.compile(r"\| /usr/bin/python3 -c '\n(.*?)\n' 2>/dev/null\)", re.S)

# One WEAK verdict (the family that must never be silently suppressed) and one non-WEAK
# verdict (alerts unconditionally), so the assertion cannot pass by alerting everything.
ROWS = [
    {"lane": "LANE-WEDGED", "verdict": "WEDGED", "child": None, "stale_s": 900},
    {"lane": "LANE-EMPTY", "verdict": "EMPTY", "child": None, "stale_s": 900},
]


def _screener_python() -> str:
    src = HEARTBEAT.read_text(encoding="utf-8")
    m = _BLOCK_RE.search(src)
    assert m, f"could not locate the stall-verdict python block in {HEARTBEAT}"
    return m.group(1)


def _run_block(home: Path) -> str:
    """Execute the extracted block against ROWS under a throwaway HOME."""
    env = dict(os.environ, HOME=str(home))
    proc = subprocess.run(
        [sys.executable, "-c", _screener_python()],
        input=json.dumps(ROWS),
        capture_output=True,
        text=True,
        env=env,
        timeout=120,
    )
    assert proc.returncode == 0, f"screener block failed rc={proc.returncode}: {proc.stderr}"
    return proc.stdout.strip()


def _field(out: str, name: str) -> str:
    """`NAME="…"` from the `KEY="value";KEY="value";…` line the block prints."""
    m = re.search(rf'(?:^|;){name}="([^"]*)"', out)
    assert m, f"{name} not in screener output: {out!r}"
    return m.group(1)


def _write_screener(home: Path, rc: int) -> Path:
    """Install a fake screener that RECORDS that it ran, then exits with `rc`.

    The marker is what makes the negative-verdict test non-vacuous: pre-fix the block
    never runs any screener (the literal `$HOME` argv), so the marker is never written.
    """
    p = home / ".pi" / "agent" / "state" / "lane-confirm.py"
    p.parent.mkdir(parents=True, exist_ok=True)
    marker = home / ".screener-ran"
    p.write_text(
        "import sys, pathlib\n"
        f"pathlib.Path({str(marker)!r}).write_text('ran')\n"
        f"sys.exit({rc})\n",
        encoding="utf-8",
    )
    return marker


# ── P1: the screener's path resolution and its FAIL-OPEN contract ─────────────


def test_missing_screener_fails_open_and_the_weak_alert_fires(tmp_path):
    """No lane-confirm.py on the box ⇒ alert, never silent suppression.

    PRE-FIX this fails: the path was the literal token `$HOME/…` (bash expands nothing
    inside the single-quoted `-c` argument), python3 exited 2 on the missing file, and
    `rc == 0` read that as "not stalled" — so LANE-WEDGED landed in KNOWN[screened-ok].
    """
    out = _run_block(tmp_path)
    alerts = _field(out, "ALERTS")
    assert "LANE-WEDGED:WEDGED" in alerts, f"WEAK alert suppressed with no screener: {out!r}"
    assert "[screened-ok]" not in out, out


def test_present_screener_is_resolved_and_a_stalled_verdict_alerts(tmp_path):
    """A screener that exists at ~/.pi/agent/state must actually be invoked.

    rc=0 == STALLED, which must reach ALERTS. PRE-FIX the literal `$HOME` path means the
    real file is never found (rc=2), so the WEDGED lane is suppressed and this fails.
    """
    _write_screener(tmp_path, rc=0)
    out = _run_block(tmp_path)
    assert "LANE-WEDGED:WEDGED" in _field(out, "ALERTS"), out


def test_screener_negative_verdict_suppresses_but_stays_visible(tmp_path):
    """rc=1 == definitively NOT stalled: keep the verdict visible, out of ALERTS."""
    marker = _write_screener(tmp_path, rc=1)
    out = _run_block(tmp_path)
    assert marker.exists(), "the screener was never invoked — the path did not resolve"
    assert "LANE-WEDGED:WEDGED" not in _field(out, "ALERTS"), out
    assert "LANE-WEDGED:WEDGED[screened-ok]" in _field(out, "KNOWN"), out


def test_crashing_screener_fails_open(tmp_path):
    """A screener that ERRORS (rc=2) is 'could not run' — the docstring says alert.

    PRE-FIX rc=2 read as "not stalled" ⇒ suppressed ⇒ this fails.
    """
    _write_screener(tmp_path, rc=2)
    out = _run_block(tmp_path)
    assert "LANE-WEDGED:WEDGED" in _field(out, "ALERTS"), out


def test_screener_block_carries_no_unexpanded_home_token():
    """The block is a single-quoted `-c` argument, so a bare `$HOME` is a literal path."""
    assert '"$HOME/' not in _screener_python(), "an unexpanded $HOME path survives in the block"


# ── P1: lane-triage.py is read from the farmed copy ───────────────────────────


def test_lane_triage_is_invoked_from_the_farmed_copy():
    src = HEARTBEAT.read_text(encoding="utf-8")
    assert '"$SCRIPTS/lane-triage.py"' in src, "$SCRIPTS/lane-triage.py is not the call site"
    assert '"$HOME/.pi/agent/state/lane-triage.py"' not in src, (
        "the un-provisioned state/ path is still the call site — the farmed copy is inert"
    )


# ── P2: the lane shell files are inside CI's syntax sweep ─────────────────────


def test_every_lane_shell_file_is_swept_for_syntax():
    src = SHARDS.read_text(encoding="utf-8")
    m = re.search(r"SWEEP_GLOBS=\((.*?)\)", src, re.S)
    assert m, "SWEEP_GLOBS not found in run-bash-shards.sh"
    globs = re.findall(r'"([^"]+)"', m.group(1))
    # Use real shell-style globbing, NOT fnmatch: fnmatch's `*` crosses `/`, so it would
    # report `scripts/*.sh` as covering `scripts/lane/x.sh` and the gap would stay invisible.
    matched = set()
    for g in globs:
        matched.update(p.relative_to(REPO_ROOT).as_posix() for p in REPO_ROOT.glob(g) if p.is_file())
    lane_sh = sorted(p.name for p in (HERE / "lane").glob("*.sh"))
    assert lane_sh, "expected scripts/lane/*.sh to exist"
    for name in lane_sh:
        rel = f"scripts/lane/{name}"
        assert rel in matched, f"{rel} matches none of the SWEEP_GLOBS patterns {globs}"


# ── reconciliation: one home for the lane classifier ──────────────────────────


def test_the_lane_classifier_has_one_home():
    """No second, stale classifier after the rebase onto main's promoted copies."""
    assert not (HERE / "lane" / "lane-status.py").exists(), "stale lane-status.py snapshot"
    assert not (HERE / "lane" / "heartbeat-loop.sh").exists(), "stale heartbeat-loop.sh snapshot"
    assert (HERE / "lane-status.py").exists(), "missing the canonical scripts/lane-status.py"
    assert (HERE / "heartbeat-loop.sh").exists(), "missing the canonical scripts/heartbeat-loop.sh"
    setup = SETUP.read_text(encoding="utf-8")
    assert "lane_root_srcs=(lane-status.py heartbeat-loop.sh)" in setup, (
        "the farm must source the two promoted files from scripts/, not scripts/lane/"
    )
