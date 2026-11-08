#!/usr/bin/env python3
"""Proof, in both directions, that the graph scripts address the CANONICAL loopback — (#907).

WHY THIS FILE EXISTS. `scripts/goal-state.py` and `scripts/seed-goal-map.py` are FARMED to every box
(`pi-bootstrap/setup.sh` `fleet_srcs`), and both defaulted `TORTOISE_DB_URI` to
`docker://:@localhost:16379/tortoise`. On macOS `localhost` resolves `::1` BEFORE `127.0.0.1`, and
port 16379 can carry a SECOND, near-empty FalkorDB on `::1` — an ephemeral dev container, a
re-created sandbox. A bare connect SUCCEEDS against either server, so the mis-address is silent:
`goal-state.py` reads a near-empty decoy and reports the goal map as empty/missing, and
`seed-goal-map.py` — the ONLY writer of goal state — writes the whole goal cascade into a graph
nothing reads, printing success for every point. That is tortoise#6666, where a 1,263-node graph read
as 25 and looked like total data loss; this repo's own rule (`skills/how-to-use-tortoise/SKILL.md`,
`scripts/turn-classify.py`) is that the address is `127.0.0.1`, never the name.

`seed-goal-map.py` had a second, sharper defect on the same line: it ASSIGNED `TORTOISE_DB_URI`
instead of `setdefault`-ing it, so an explicit URI was silently discarded and the seeder could not be
pointed at any other graph at all.

WHAT IS ASSERTED — four behavioural arms over the SHIPPED scripts, with a stub `tortoise` package:

  (A) URI unset            -> the loader receives `docker://:@127.0.0.1:16379/tortoise`, exactly.
  (B) URI set explicitly   -> the loader receives that value, verbatim (the `setdefault` half).
  (C) MUTATION             -> the same arms against a COPY of each script whose literal is put back
                              to `localhost`: they must FAIL. Without this the assertion could pass
                              while the defect returns, because a build that never reaches the loader
                              records nothing.

Every arm also asserts the recording came from the STUB (`sdk_loaded_from`) and that the stub package
exists on a temporary path, so a box that happens to have a real tortoise checkout cannot turn this
suite into a live-graph test — the failure mode that would make it dangerous rather than merely wrong.
"""
from __future__ import annotations

import json
import os
import pathlib
import subprocess
import sys

import pytest

SCRIPTS = pathlib.Path(__file__).resolve().parent
CANONICAL = "docker://:@127.0.0.1:16379/tortoise"
DECOY = "docker://:@localhost:16379/tortoise"
LITERAL = '"docker://:@127.0.0.1:16379/tortoise"'

# A `tortoise` package with just enough SDK to run the shipped scripts. It RECORDS the URI it was
# constructed with and where it was imported from; it talks to nothing.
STUB_SDK = '''\
import json
import os


class TortoiseSDK:
    """Records its target; reads and writes NOTHING."""

    def __init__(self, *args, **kwargs):
        out = os.environ.get("STUB_URI_OUT")
        if out:
            with open(out, "w", encoding="utf-8") as fh:
                json.dump(
                    {
                        "uri": os.environ.get("TORTOISE_DB_URI"),
                        "sdk_loaded_from": os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                        "cwd": os.getcwd(),
                    },
                    fh,
                )
        self._points = {}

    # goal-state.py
    def query(self, **kwargs):
        return []

    # seed-goal-map.py
    def update_point(self, gid, **props):
        self._points.setdefault(gid, {}).update(props)
        return {}

    def get_point(self, gid):
        point = {"status": "live"}
        point.update(self._points.get(gid, {}))
        return point

    def promote_point(self, gid):
        return {"promoted": True}
'''


def _stub_repo(tmp_path: pathlib.Path) -> pathlib.Path:
    """A throwaway `tortoise` import root, so no real SDK is ever reached."""
    root = tmp_path / "graph-stub"
    pkg = root / "tortoise"
    pkg.mkdir(parents=True)
    (pkg / "__init__.py").write_text("")
    (pkg / "sdk.py").write_text(STUB_SDK)
    return root


def _run(tmp_path: pathlib.Path, script: pathlib.Path, *, uri: str | None) -> dict:
    """Execute `script` against the stub; return what the loader recorded.

    `TORTOISE_REPO` points the script's own `sys.path.insert` at the stub, so the import is
    deterministic on every box — including one that has a real tortoise checkout at the literal
    fallback path, where a non-deterministic harness would write to a LIVE graph.
    """
    stub = _stub_repo(tmp_path)
    recorded = tmp_path / "recorded.json"
    env = {k: v for k, v in os.environ.items() if not k.startswith(("TORTOISE_", "STUB_"))}
    env["TORTOISE_REPO"] = str(stub)
    env["STUB_URI_OUT"] = str(recorded)
    if uri is not None:
        env["TORTOISE_DB_URI"] = uri
    proc = subprocess.run(
        [sys.executable, str(script)],
        cwd=str(tmp_path),
        env=env,
        capture_output=True,
        text=True,
        timeout=45,
    )
    if not recorded.exists():
        pytest.fail(
            f"{script.name} never reached the graph loader (rc={proc.returncode})\n"
            f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
        )
    payload = json.loads(recorded.read_text(encoding="utf-8"))
    # The stub — not a real checkout — must be what was imported. Without this the suite could pass
    # by touching production, which is worse than failing.
    assert payload["sdk_loaded_from"] == str(stub), payload
    payload["rc"] = proc.returncode
    payload["stdout"] = proc.stdout
    payload["stderr"] = proc.stderr
    return payload


def _mutated(tmp_path: pathlib.Path, name: str, *, literal_from: str, literal_to: str) -> pathlib.Path:
    """A copy of the shipped script with ONE literal rewritten, and the rewrite proven to have happened."""
    source = (SCRIPTS / name).read_text(encoding="utf-8")
    mutated = source.replace(literal_from, literal_to)
    assert mutated != source, f"mutation arm is vacuous: {name} does not contain {literal_from}"
    copy = tmp_path / f"mutated-{name}"
    copy.write_text(mutated, encoding="utf-8")
    return copy


# ── the shipped scripts default to the canonical loopback ────────────────────────────────────────
@pytest.mark.parametrize("name", ["goal-state.py", "seed-goal-map.py"])
def test_default_uri_is_the_canonical_loopback(tmp_path, name):
    payload = _run(tmp_path, SCRIPTS / name, uri=None)
    assert payload["uri"] == CANONICAL
    assert "localhost" not in (payload["uri"] or ""), "the name can resolve ::1 — spell the address"


# ── an explicit URI always wins (the `setdefault` half; seed-goal-map.py assigned, and clobbered) ──
@pytest.mark.parametrize("name", ["goal-state.py", "seed-goal-map.py"])
def test_explicit_uri_is_honoured(tmp_path, name):
    explicit = "docker://:@127.0.0.1:16999/tortoise"
    payload = _run(tmp_path, SCRIPTS / name, uri=explicit)
    assert payload["uri"] == explicit


# ── non-vacuity: put the decoy back and the same assertion must fail ─────────────────────────────
@pytest.mark.parametrize("name", ["goal-state.py", "seed-goal-map.py"])
def test_mutation_the_decoy_is_detected(tmp_path, name):
    script = _mutated(tmp_path, name, literal_from=LITERAL, literal_to=f'"{DECOY}"')
    payload = _run(tmp_path, script, uri=None)
    assert payload["uri"] == DECOY, "the mutation arm did not reach the loader"
    assert payload["uri"] != CANONICAL  # i.e. `test_default_uri_is_the_canonical_loopback` would red


def test_seed_goal_map_is_the_only_writer_and_writes_nothing_here(tmp_path):
    """The seeder completes against the stub — proving the arms above ran the real body, not a prefix."""
    payload = _run(tmp_path, SCRIPTS / "seed-goal-map.py", uri=None)
    assert payload["rc"] == 0, payload["stderr"]
    assert "writing goal state into the graph" in payload["stdout"]
