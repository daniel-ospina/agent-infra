#!/usr/bin/env python3
"""Tests for `lane_registry.py` — the lane STATE primitive (agent-infra#3382, owner steer 2026-11-04).

RED-FIRST, AND WHAT "RED" MEANS HERE
------------------------------------
The pre-change behaviour is not "a different function output" — it is that **no state record existed at
all**, so the orchestrator answered "did it finish?" from a proxy and got it wrong five measured ways on
2026-11-03/04 (`lane_registry.py`'s docstring lists them; the FALSE-DEATH x3 in #3382 §"Why this exists"
is the same failure in the other direction).

A test that merely exercises the new code proves nothing about whether it discriminates. T1–T5 are each
paired with an in-body **mutation** (the `mod._derived = …` / `mod.terminal_refusal = …` arms the test
installs and then restores): the one line the assertion exists to protect is replaced by the
plausible-looking wrong version, and the test must then FAIL.

⛔ T6–T27 ARE **NOT** MUTATION-PAIRED, AND THIS HEADER USED TO SAY THEY WERE. It claimed every
load-bearing assertion was paired by a `_MUTANTS` table that re-derives the module from a modified copy.
No such table or runner exists in this tree — the name appears only in that sentence, so a reader was
told a suite-wide assurance existed when only five assertions had one. A claim of assurance is worse
than an honest gap: the seam an external mutation run needs is `LANE_REGISTRY_UNDER_TEST` (see
`_MODULE` below), and running one is a follow-up, not something this file can pretend it did.

    T1   a stale heartbeat with NO terminal record reports EXPIRED          (+ mutant: "RUNNING forever")
    T2   an open lease reports RUNNING                                      (+ mutant: "always EXPIRED")
    T3   `done` with no artifact is REFUSED and writes NOTHING              (+ mutant: "accept empty")
    T4   `done` with an artifact is DONE, and the artifact is in the RECORD (+ mutant: "drop artifacts")
    T5   `fail` with no reason is REFUSED                                   (+ mutant: "accept empty reason")
    T6   `beat` on a terminal record is REFUSED (terminal is FINAL)
    T7   a second terminal transition is REFUSED
    T8   `EMPTY ≠ UNMEASURED`: an unreadable registry exits 3 and prints UNMEASURED, never zero counts
    T9   a corrupt record fails the WHOLE read (it is never skipped, never rendered as EXPIRED)
    T10  `NOT-FOUND` is a lookup outcome (exit 4), never one of the four states
    T11  invariant I1: `lease_until == heartbeat_at + budget_s`, on every write, including `beat`
    T12  the record lives at `refs/lanes/<lane-id>` and creates NO branch
    T13  the five questions: running / finished-with-shas / failed-and-why / expired / oldest-unfinished
    T14  `EXPIRED` cannot be WRITTEN (it is derived) — the writer refuses it
    T15  a lane id is unique per (host, start instant, pid) — #1761's one-owner-per-controller, so a
         force-update can never clobber a peer
    T16  a peer record missing OPTIONAL fields still reads (schema tolerance, #796)
    T17  the WRITE side abstains too: an unreadable registry is exit 3, never "no record, start it first"
    T17b an unsafe lane id is refused by `_push` and `_write_local` (ref component + file name)
    T17c a ref whose PAYLOAD names another lane is corrupt, and cannot redirect a write
    T17d a GENERATED id still opens a LOCAL-ONLY record during a partition (else an outage is invisible)
    T18  the filters are applied by the SHARED read path, so CLI and MCP cannot diverge
    T19  a beat holds the lease LOCALLY and republishes only when it must (asserted on the local copy,
         which is the write that keeps a partitioned box from reading a live lane as EXPIRED)
    T20  a terminal record still carries a consistent lease (I1 is verified on read)
    T21  a HALF-SPENT lease renews the ref without `--push` (this was dead code; a live lane read EXPIRED)
    T22  an unrecognised filter is REFUSED, never answered with a confident zero
    T23  an unsafe `--lane-id` is refused BEFORE any I/O, and no handle is printed
    T24  repeating an id is REFUSED — including when a corrupt SIBLING record is present, and when only
         the local copy exists (this guard was vacuous and the suite could not see it)
    T25  a lane opened during an outage can still be CLOSED once the registry returns (else its terminal
         record is lost to the fleet for every lane launched in a partition)
    T26  `show --json` is JSON on every branch — found, NOT-FOUND (its most common answer), and partial
    T27  the CLI normalises `--state` exactly as the shared reader does
"""
import contextlib
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile

import pytest

_HERE = os.path.dirname(os.path.abspath(__file__))
# ⛔ OVERRIDABLE, SO THE GUARDS CAN BE MUTATION-TESTED FROM THE OUTSIDE. A mutation run that cannot point
# the suite at a modified copy is a mutation run against the ORIGINAL module, which reports "green" and
# proves the opposite of what it claims — measured while writing T24..T27 (38 "passed" against an
# unmodified file, with five mutants reported as surviving). NOTHING IN THIS FILE SETS IT: it is the
# seam an external run uses (`LANE_REGISTRY_UNDER_TEST=<modified copy> pytest scripts/test_lane_registry.py`).
_MODULE = os.environ.get("LANE_REGISTRY_UNDER_TEST") or os.path.join(_HERE, "orchestrator-harness",
                                                                     "lane_registry.py")


def _load(name="lane_registry_under_test", path=None):
    spec = importlib.util.spec_from_file_location(name, path or _MODULE)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture()
def box(tmp_path, monkeypatch):
    """A hermetic box: its own state root, its own bare `origin`, nothing ambient."""
    origin = tmp_path / "origin.git"
    subprocess.run(["git", "init", "-q", "--bare", str(origin)], check=True)
    monkeypatch.setenv("LANE_REGISTRY_STATE", str(tmp_path / "state"))
    monkeypatch.setenv("LANE_REGISTRY_LOCAL", str(tmp_path / "state" / "lanes"))
    monkeypatch.setenv("LANE_REGISTRY_GIT", str(tmp_path / "state" / "work.git"))
    mod = _load()
    return mod, str(origin), tmp_path


def run(mod, argv, capsys=None):
    """Drive the real CLI entry point, exactly as a launcher does. Returns (rc, stdout, stderr)."""
    import contextlib
    import io
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            rc = mod.main(argv)
        except SystemExit as exc:            # argparse / _die both leave through SystemExit
            rc = int(exc.code or 0)
    return rc, out.getvalue(), err.getvalue()


def _remote(origin):
    return ["--remote", origin]


def _backdate(mod, origin, lane_id, seconds=3600):
    """Rewrite ONE record's heartbeat into the past — the exact record a dead box leaves behind.

    This is not a simulation of the failure: it is the failure. The record is byte-identical to what
    `start` wrote; only the two lease numbers moved, which is all a killed process can leave undone.
    """
    ok, _detail, records, _src = mod.read_registry(origin, allow_local_fallback=False)
    assert ok and lane_id in records, records
    rec = dict(records[lane_id])
    rec.pop("_ref", None)
    rec.pop("_sha", None)
    rec["heartbeat_at"] = int(rec["heartbeat_at"]) - seconds
    rec["lease_until"] = rec["heartbeat_at"] + int(rec["budget_s"])
    assert rec["lease_until"] < __import__("time").time()
    pushed, detail = mod._push(rec, origin, 20.0)
    assert pushed, detail
    return rec


def start(mod, origin, **kw):
    argv = ["start"] + _remote(origin) + ["--kind", kw.pop("kind", "lane"),
                                          "--tag", str(kw.pop("tag", "3382"))]
    for flag, value in kw.items():
        argv += ["--%s" % flag.replace("_", "-"), str(value)]
    rc, out, err = run(mod, argv)
    assert rc == 0, err
    return out.strip().splitlines()[-1]


def _purge(origin, tmp_path, lane_id):
    """Delete one record from BOTH stores — needed after a mutant writes a deliberately corrupt record.

    ⛔ WITHOUT THIS, ONE POISONED RECORD HIDES EVERYTHING: a corrupt record fails the WHOLE read
    (`_record_problem` -> UNMEASURED, by design), so a follow-up arm that expects to read anything at all
    would be asserting against the corruption it just planted, not against the behaviour under test.
    """
    subprocess.run(["git", "-C", origin, "update-ref", "-d", "refs/lanes/%s" % lane_id],
                   check=False, capture_output=True)
    # ⛔ ONLY THIS LANE. A blanket glob would silently destroy sibling evidence in a multi-lane arm — and
    # this helper is test-only BECAUSE a production box has no `prune`/`repair` verb (docs §9), which is
    # why it must not model one it does not have.
    own = tmp_path / "state" / "lanes" / ("%s.json" % lane_id)
    if own.exists():
        own.unlink()


def records_on_refs(origin):
    out = subprocess.run(["git", "ls-remote", origin], capture_output=True, text=True, check=True).stdout
    return [line.split()[1] for line in out.splitlines() if line.strip()]


# ── T1 / T2 — the derivation, both directions, each with a mutant ───────────────────────────────

def test_T1_stale_heartbeat_with_no_terminal_record_is_EXPIRED(box):
    """THE acceptance criterion. A lane that stopped beating and never recorded an end is EXPIRED."""
    mod, origin, _ = box
    lane = start(mod, origin, budget=60)
    rc, out, _err = run(mod, ["show", "--lane-id", lane] + _remote(origin) + ["--json"])
    assert rc == 0
    rec = json.loads(out)
    assert rec["state"] == "RUNNING"

    # Re-derive the SAME record at a clock past its lease. This is not simulated state: the record is
    # byte-identical, only "now" moved — which is exactly what a dead box leaves behind.
    lease = int(rec["lease_until"])
    state, why = mod._derived(rec, lease + 1)
    assert state == "EXPIRED", why
    assert "lease-lapsed" in why and str(lease) in why, why


def test_T1_MUTANT_a_registry_that_ignores_the_lease_is_caught(box):
    """The mutant: `_derived` returns RUNNING whenever no terminal record exists.

    That is not a strawman — it is precisely what every proxy the fleet used tonight did: a lane with no
    terminal marker was read as still-there. If this suite cannot see it, T1 is decoration.
    """
    mod, origin, _ = box
    lane = start(mod, origin, budget=60)
    rec = json.loads(run(mod, ["show", "--lane-id", lane] + _remote(origin) + ["--json"])[1])
    lease = int(rec["lease_until"])
    real = mod._derived
    try:
        mod._derived = lambda r, now: ("RUNNING", "always-running") if r.get("state") == "RUNNING" \
            else real(r, now)
        assert mod._derived(rec, lease + 1)[0] == "RUNNING"
        with pytest.raises(AssertionError):
            # the mutant must break T1's own assertion, verbatim
            assert mod._derived(rec, lease + 1)[0] == "EXPIRED"
        # …and through the verb path a caller actually uses: age the record, keep the mutant installed.
        _backdate(mod, origin, lane, seconds=3600)
        aged = json.loads(run(mod, ["show", "--lane-id", lane] + _remote(origin) + ["--json"])[1])
        assert aged["state"] == "RUNNING", "the mutant must be visible through `show`, not only in-process"
        with pytest.raises(AssertionError):
            assert aged["state"] == "EXPIRED"
    finally:
        mod._derived = real


def test_T2_MUTANT_an_always_expired_registry_is_caught(box):
    """The opposite mutant: 'no heartbeat recently' collapsed into 'expired' regardless of the budget.

    This is #943's failure (quiet is not a verdict) with a different name, and it would report a lane
    that is working fine as gone.
    """
    mod, origin, _ = box
    lane = start(mod, origin, budget=600)
    rec = json.loads(run(mod, ["show", "--lane-id", lane] + _remote(origin) + ["--json"])[1])
    now = int(rec["heartbeat_at"])
    real = mod._derived
    try:
        mod._derived = lambda r, t: (("EXPIRED", "quiet-means-dead") if r.get("state") == "RUNNING"
                                     else real(r, t))
        with pytest.raises(AssertionError):
            assert mod._derived(rec, now)[0] == "RUNNING"
    finally:
        mod._derived = real
    assert mod._derived(rec, now)[0] == "RUNNING"


# ── T3 / T4 — DONE names its artifacts ──────────────────────────────────────────────────────────

def test_T3_done_without_an_artifact_is_REFUSED_and_writes_nothing(box):
    mod, origin, _ = box
    lane = start(mod, origin)
    rc, _out, err = run(mod, ["done", "--lane-id", lane] + _remote(origin))
    assert rc == mod.REFUSED, err
    assert "artifact" in err.lower()
    rec = json.loads(run(mod, ["show", "--lane-id", lane] + _remote(origin) + ["--json"])[1])
    assert rec["state"] == "RUNNING", "a refused done must not have written a terminal record"


def test_T3_MUTANT_the_artefact_guard_is_what_refuses(box):
    """The mutant removes ONLY the guard. If DONE then succeeds, the guard is load-bearing and T3
    discriminates; if it still refuses, T3 is passing for some other reason and proves nothing."""
    mod, origin, _ = box
    lane = start(mod, origin)
    real = mod.terminal_refusal
    try:
        mod.terminal_refusal = lambda state, arts, reason: None
        rc, _out, _err = run(mod, ["done", "--lane-id", lane] + _remote(origin))
        assert rc == 0, "with the guard removed, DONE must be accepted — else T3 proves nothing"
        # ⛔ AND THE READER IS A SECOND, INDEPENDENT GUARD: `_record_problem` re-checks the terminal
        # invariants, so the artifact-less DONE the mutant just wrote is not readable as a lane at all.
        # (Measured before that guard existed: it read back as a perfectly good DONE.)
        got = json.loads(run(mod, ["show", "--lane-id", lane] + _remote(origin) + ["--json"])[1])
        assert got.get("readable") is False, got
        assert "artifacts" in got["unmeasured"], got
    finally:
        mod.terminal_refusal = real
    _purge(origin, box[2], lane)
    # …and with the guard restored, the SAME invocation is refused again.
    assert run(mod, ["done", "--lane-id", start(mod, origin)] + _remote(origin))[0] == mod.REFUSED


def test_T4_done_with_an_artifact_records_the_artifact_in_the_REF(box):
    """Not merely in the return value: the SHARED record must carry it, or a peer cannot verify the end."""
    mod, origin, _ = box
    lane = start(mod, origin)
    rc, out, err = run(mod, ["done", "--lane-id", lane, "--pr", "3419", "--sha", "deadbeef"]
                       + _remote(origin))
    assert rc == 0, err
    refs = records_on_refs(origin)
    assert "refs/lanes/%s" % lane in refs
    rec = json.loads(run(mod, ["show", "--lane-id", lane] + _remote(origin) + ["--json"])[1])
    assert rec["state"] == "DONE"
    kinds = {a["kind"]: a["value"] for a in rec["artifacts"]}
    assert kinds == {"pr": "3419", "sha": "deadbeef"}, kinds


def test_T4_MUTANT_a_done_that_drops_its_artifacts_is_caught(box):
    mod, origin, _ = box
    lane = start(mod, origin)
    real_commit = mod._commit

    def drop_artifacts(record, *a, **kw):
        record["artifacts"] = []
        return real_commit(record, *a, **kw)

    try:
        mod._commit = drop_artifacts
        assert run(mod, ["done", "--lane-id", lane, "--pr", "1"] + _remote(origin))[0] == 0
        got = json.loads(run(mod, ["show", "--lane-id", lane] + _remote(origin) + ["--json"])[1])
        assert got.get("readable") is False, got
        assert "artifacts" in got["unmeasured"], got
    finally:
        mod._commit = real_commit
    _purge(origin, box[2], lane)
    # …and with the writer restored a second lane's DONE really does carry its artifact, so T4's
    # assertion is not passing merely because every DONE is empty.
    other = start(mod, origin)
    assert run(mod, ["done", "--lane-id", other, "--pr", "2"] + _remote(origin))[0] == 0
    again = json.loads(run(mod, ["show", "--lane-id", other] + _remote(origin) + ["--json"])[1])
    assert {a["kind"]: a["value"] for a in again["artifacts"]} == {"pr": "2"}


# ── T5 / T6 / T7 — terminality is FINAL ────────────────────────────────────────────────────────

def test_T5_fail_without_a_reason_is_REFUSED(box):
    mod, origin, _ = box
    lane = start(mod, origin)
    rc, _out, err = run(mod, ["fail", "--lane-id", lane, "--reason", "  "] + _remote(origin))
    assert rc == mod.REFUSED, err
    assert "reason" in err.lower()


def test_T5_MUTANT_the_reason_guard_is_what_refuses(box):
    mod, origin, _ = box
    lane = start(mod, origin)
    real = mod.terminal_refusal
    try:
        mod.terminal_refusal = lambda state, arts, reason: None
        rc, _o, _e = run(mod, ["fail", "--lane-id", lane, "--reason", ""] + _remote(origin))
        assert rc == 0, "with the guard removed, FAIL must be accepted — else T5 proves nothing"
        # The reader re-checks the terminal invariants, so the reason-less FAILED is not readable as a
        # lane at all — a second, independent guard behind the writer's.
        got = json.loads(run(mod, ["show", "--lane-id", lane] + _remote(origin) + ["--json"])[1])
        assert got.get("readable") is False, got
        assert "reason" in got["unmeasured"], got
    finally:
        mod.terminal_refusal = real
    _purge(origin, box[2], lane)
    assert run(mod, ["fail", "--lane-id", start(mod, origin), "--reason", " "]
               + _remote(origin))[0] == mod.REFUSED


def test_T6_beat_on_a_terminal_record_is_REFUSED(box):
    """A stray process must not resurrect a finished lane — the fleet would re-dispatch it."""
    mod, origin, _ = box
    lane = start(mod, origin)
    assert run(mod, ["done", "--lane-id", lane, "--pr", "7"] + _remote(origin))[0] == 0
    rc, _out, err = run(mod, ["beat", "--lane-id", lane] + _remote(origin))
    assert rc == mod.REFUSED, err
    assert "terminal" in err.lower()


def test_T7_a_second_terminal_transition_is_REFUSED(box):
    mod, origin, _ = box
    lane = start(mod, origin)
    assert run(mod, ["done", "--lane-id", lane, "--pr", "7"] + _remote(origin))[0] == 0
    rc, _out, err = run(mod, ["fail", "--lane-id", lane, "--reason", "changed my mind"]
                        + _remote(origin))
    assert rc == mod.REFUSED, err


def test_T7b_a_lane_whose_lease_lapsed_may_still_write_its_terminal_record(box):
    """EXPIRED is derived, so it is not a tombstone: a late writer still gets to say what happened.

    ⛔ THE RAW RECORD, NOT THE `show --json` ROW. `collect()` REPLACES a row's `state` with the DERIVED
    one (`_derived(rec, now)`), so feeding that payload back into `_derived` hands it `"EXPIRED"` — a value
    `_derived` refuses by design (`unvalidated state 'EXPIRED' reached _derived`), because only a raw
    record is a legal input. That made this test depend on elapsed wall clock: with `budget=1`, a `show`
    subprocess that finished inside the same second returned `"RUNNING"` and the assertion passed, while
    the same test under load (or in the full CI list) read `"EXPIRED"` and ERRORED with `ValueError` —
    reproduced deterministically with a 1.5 s gap. Reading the raw registry removes the clock from the
    assertion and keeps its discriminating power: this still fails if `_derived` stops deriving EXPIRED.
    """
    mod, origin, _ = box
    lane = start(mod, origin, budget=1)
    ok, _detail, records, _src = mod.read_registry(str(origin), 20.0, allow_local_fallback=False)
    assert ok
    rec = dict(records[lane])
    rec.pop("_ref", None)
    rec.pop("_sha", None)
    assert mod._derived(rec, int(rec["lease_until"]) + 1)[0] == "EXPIRED"
    assert run(mod, ["done", "--lane-id", lane, "--pr", "9"] + _remote(origin))[0] == 0
    assert json.loads(run(mod, ["show", "--lane-id", lane] + _remote(origin) + ["--json"])[1])[
        "state"] == "DONE"


# ── T8 / T9 / T10 — the abstentions ────────────────────────────────────────────────────────────

def test_T8_an_unreadable_registry_is_UNMEASURED_never_zero(box, tmp_path):
    """Invariant 1: unknown is not zero. This is the FALSE-CLEAN direction and it must be impossible."""
    mod, origin, _ = box
    shutil.rmtree(origin)                       # the remote is GONE — the read cannot succeed
    rc, out, _err = run(mod, ["list", "--json"] + _remote(origin))
    assert rc == mod.UNMEASURED, out
    # ⛔ AND IT IS STILL JSON. The plain-text form made `list --json | jq` a PARSE ERROR instead of the
    # abstention, on the surface the docs call "one object, the whole answer".
    blob = json.loads(out)
    assert blob["readable"] is False, blob
    assert blob["unmeasured"].startswith("UNMEASURED("), blob
    assert "counts" not in blob, "an unreadable registry must not render zero counts"
    # the human form keeps the plain word, and still exits non-zero
    rc2, out2, _e2 = run(mod, ["list"] + _remote(origin))
    assert rc2 == mod.UNMEASURED and out2.startswith("UNMEASURED("), out2


def test_T8b_an_unreachable_remote_with_a_local_record_LABELS_the_fallback(box):
    """A box that cannot reach the network still answers for itself — and SAYS that is what it did."""
    mod, origin, _ = box
    lane = start(mod, origin, budget=600)
    shutil.rmtree(origin)
    rc, out, _err = run(mod, ["list", "--json"] + _remote(origin))
    assert rc == 0, out
    payload = json.loads(out)
    assert "source=local" in payload["source"], payload["source"]
    assert any(r["lane_id"] == lane for r in payload["lanes"])


def test_T9_a_corrupt_record_fails_the_whole_read(box):
    mod, origin, tmp_path = box
    start(mod, origin)
    (tmp_path / "state" / "lanes" / "broken.json").write_text("{ not json", encoding="utf-8")
    shutil.rmtree(origin)                       # force the local axis to be what answers
    rc, out, _err = run(mod, ["list", "--json"] + _remote(origin))
    assert rc == mod.UNMEASURED, out


def test_T9b_a_record_with_a_written_EXPIRED_state_is_CORRUPT(box):
    """`EXPIRED` is DERIVED. A record that writes it is not a record this reader trusts."""
    mod, origin, tmp_path = box
    start(mod, origin)
    path = next((tmp_path / "state" / "lanes").glob("*.json"))
    rec = json.loads(path.read_text())
    rec["state"] = "EXPIRED"
    path.write_text(json.dumps(rec))
    shutil.rmtree(origin)
    rc, out, _err = run(mod, ["list", "--json"] + _remote(origin))
    assert rc == mod.UNMEASURED, out
    assert "DERIVED" in out or "not one of" in out, out


def test_T10_an_unknown_lane_is_NOT_FOUND_not_a_state(box):
    mod, origin, _ = box
    rc, out, _err = run(mod, ["show", "--lane-id", "nope"] + _remote(origin))
    assert rc == mod.NOT_FOUND, out
    assert out.startswith("NOT-FOUND"), out
    for state in mod.STATES:
        assert not out.startswith(state)


# ── T11 / T12 / T14 / T15 — the record's own invariants ───────────────────────────────────────

def test_T11_lease_until_is_always_heartbeat_plus_budget(box):
    mod, origin, _ = box
    lane = start(mod, origin, budget=300)
    rec = json.loads(run(mod, ["show", "--lane-id", lane] + _remote(origin) + ["--json"])[1])
    assert rec["lease_until"] == rec["heartbeat_at"] + rec["budget_s"]
    run(mod, ["beat", "--lane-id", lane] + _remote(origin))
    after = json.loads(run(mod, ["show", "--lane-id", lane] + _remote(origin) + ["--json"])[1])
    assert after["lease_until"] == after["heartbeat_at"] + after["budget_s"], \
        "beat must re-derive the lease, not append to it"
    assert after["state"] == "RUNNING"


def test_T12_the_record_is_a_ref_under_refs_lanes_and_creates_no_branch(box):
    mod, origin, _ = box
    lane = start(mod, origin)
    refs = records_on_refs(origin)
    assert "refs/lanes/%s" % lane in refs
    assert not any(r.startswith("refs/heads/") for r in refs), refs


def test_T14_expired_cannot_be_written(box):
    """No writer verb has a `--state` at all, and the invariant a writer must maintain is VERIFIED here.

    The reader-side half of the same guarantee is T9b (a record that WRITES `expired` is corrupt).
    """
    mod, origin, _ = box
    parser = mod.build_parser()
    with pytest.raises(SystemExit) as exc:
        parser.parse_args(["start", "--kind", "lane", "--tag", "1", "--state", "expired"])
    assert exc.value.code == 2
    for verb in ("beat", "done", "fail"):
        with pytest.raises(SystemExit):
            parser.parse_args([verb, "--lane-id", "x", "--state", "EXPIRED"])
    # A hand-edited record that widens its own lease is refused as self-inconsistent on READ, rather
    # than trusted as RUNNING forever.
    start(mod, origin)
    ok, _detail, records, _src = mod.read_registry(origin, 20.0)
    assert ok
    rec = dict(next(iter(records.values())))
    rec["lease_until"] = int(rec["lease_until"]) + 10 ** 7
    problem = mod._record_problem(rec)
    assert problem is not None and "self-inconsistent" in problem, problem


def test_T15_lane_ids_are_unique_per_host_instant_and_pid(box):
    mod, origin, _ = box
    a = start(mod, origin)
    b = start(mod, origin)
    assert a != b
    for lane in (a, b):
        assert len(lane) < 200, lane
        assert ".." not in lane and not lane.endswith(".")


# ── T13 — the five questions the fleet could not ask ──────────────────────────────────────────

def test_T13_the_five_questions(box):
    mod, origin, _ = box
    running = start(mod, origin, tag="100")
    done = start(mod, origin, tag="101")
    failed = start(mod, origin, tag="102")
    lapsed = start(mod, origin, tag="103", budget=600)
    _backdate(mod, origin, lapsed, seconds=3600)
    assert run(mod, ["done", "--lane-id", done, "--pr", "5000", "--sha", "abc123"]
               + _remote(origin))[0] == 0
    assert run(mod, ["fail", "--lane-id", failed, "--reason", "brief-gate refused (80)"]
               + _remote(origin))[0] == 0

    payload = json.loads(run(mod, ["list", "--json"] + _remote(origin))[1])
    by_id = {r["lane_id"]: r for r in payload["lanes"]}
    now = payload["measured_at"]

    # 1) which lanes are RUNNING
    assert [r["lane_id"] for r in payload["running"]] == [running]
    # 2) which finished, and with what shas
    fin = by_id[done]
    assert fin["state"] == "DONE"
    assert {a["kind"]: a["value"] for a in fin["artifacts"]}["sha"] == "abc123"
    # 3) which FAILED, and why
    assert by_id[failed]["state"] == "FAILED"
    assert "brief-gate" in by_id[failed]["reason"]
    # 4) which EXPIRED — derived from a stale heartbeat with no terminal record, and named as such
    assert payload["counts"]["EXPIRED"] == 1, payload["counts"]
    assert by_id[lapsed]["state"] == "EXPIRED"
    assert "lease-lapsed" in by_id[lapsed]["state_reason"]
    # 5) the oldest unfinished lane
    assert payload["oldest_unfinished"]["lane_id"] == running
    assert payload["oldest_unfinished"]["age_s"] >= 0
    assert payload["measured_at"] > 0
    assert payload["registry_repo_source"] in ("env:LANE_REGISTRY_REPO", "env:AGENT_INFRA_PATH",
                                               "cwd(UNSHARED)")
    del now  # the payload's own clock is the measurement; comparing it to a probe clock proved nothing


def test_T13b_no_running_lane_means_oldest_unfinished_is_absent_not_invented(box):
    mod, origin, _ = box
    lane = start(mod, origin)
    assert run(mod, ["done", "--lane-id", lane, "--pr", "1"] + _remote(origin))[0] == 0
    payload = json.loads(run(mod, ["list", "--json"] + _remote(origin))[1])
    assert payload["oldest_unfinished"] is None
    assert payload["running"] == []
    assert payload["counts"]["DONE"] == 1


# ── T16 — the schema is versioned and tolerant (#796) ────────────────────────────────────────

def test_T16_a_peer_record_missing_optional_fields_still_reads(box):
    """A record written by another framework version may lack fields. Readers tolerate absence."""
    mod, origin, tmp_path = box
    start(mod, origin)
    path = next((tmp_path / "state" / "lanes").glob("*.json"))
    rec = json.loads(path.read_text())
    for key in ("repo", "branch", "worktree", "issue", "attempt", "artifacts", "reason"):
        rec.pop(key, None)
    path.write_text(json.dumps(rec))
    shutil.rmtree(origin)
    rc, out, _err = run(mod, ["list", "--json"] + _remote(origin))
    assert rc == 0, out
    assert json.loads(out)["counts"]["RUNNING"] == 1


# ── T17 / T18 / T19 / T20 — the write side's own abstentions ──────────────────────────────────

def test_T17_an_unreadable_registry_makes_writers_abstain_not_guess(box, tmp_path):
    """⛔ UNMEASURED IS NOT NOT-FOUND — ON THE WRITE SIDE. This is the defect that motivated T17.

    With the registry unreadable, `done`/`fail`/`beat` used to answer NOT-FOUND (exit 4, "no record,
    start it first") and never publish the terminal record at all, while `start` skipped its own
    existing-id guard and force-pushed a fresh RUNNING over a finished lane. Every verb must abstain
    with UNMEASURED (exit 3) and write nothing.
    """
    mod, origin, _ = box
    lane = start(mod, origin)
    assert run(mod, ["done", "--lane-id", lane, "--pr", "9"] + _remote(origin))[0] == 0
    before = sorted(records_on_refs(origin))
    # Make every read fail: the remote is gone AND the local witness is empty (a fresh box).
    shutil.rmtree(origin)
    for path in (tmp_path / "state" / "lanes").glob("*.json"):
        path.unlink()
    for argv in (["beat", "--lane-id", lane], ["done", "--lane-id", lane, "--pr", "10"],
                 ["fail", "--lane-id", lane, "--reason", "x"],
                 # a CALLER-SUPPLIED id with an unreadable registry may be a finished lane we cannot see
                 ["start", "--kind", "lane", "--lane-id", "h.klane-0-1-p1-deadbeef"]):
        rc, _out, err = run(mod, argv + _remote(origin))
        assert rc == mod.UNMEASURED, "%s must abstain, got %s: %s" % (argv[0], rc, err)
        assert "NOT" in err, err          # the message must say this is not an absence
    assert before                    # the DONE record was really there before the remote went away


def test_T17d_a_generated_id_still_opens_a_record_during_a_partition(box, tmp_path):
    """⛔ ABSTAINING HERE WAS A REGRESSION THAT MADE A WHOLE OUTAGE INVISIBLE.

    Refusing every `start` when the registry cannot be read sounds safe, but `run_agent` takes the WARN
    path and drops the id — so EVERY lane launched during a network outage is invisible to `lane.list`
    for its whole life, and its terminal `lane_registry_end` is a no-op. A GENERATED id cannot collide
    (random suffix), so there is nothing to protect: the record is opened locally, the push fails, and the
    verb returns LOCAL-ONLY (6) — which is exactly what that exit code is documented to mean.
    """
    mod, origin, _ = box
    shutil.rmtree(origin)
    for path in (tmp_path / "state" / "lanes").glob("*.json"):
        path.unlink()
    rc, out, err = run(mod, ["start", "--kind", "lane", "--tag", "1"] + _remote(origin))
    assert rc == mod.LOCAL_ONLY, (rc, out, err)
    lane = out.strip().splitlines()[-1]
    assert lane and " " not in lane, lane
    assert "LOCAL-ONLY" in err or "visible on this box only" in err, err
    local = json.loads((tmp_path / "state" / "lanes" / ("%s.json" % lane)).read_text())
    assert local["state"] == "RUNNING" and local["lane_id"] == lane


def test_T17b_a_lane_id_cannot_escape_the_namespace(box, tmp_path):
    """A lane id reaches a ref name AND a temp-file name. `../`, `/` and friends must be refused.

    `start --tag` is slugged (a tag is free text), so the guard is tested where the id is actually
    trusted: `_push` (ref component) and `_write_local` (file name).

    ⛔ THE ESCAPE SHAPES WERE NOT THE ONLY CLASS. `a..b`, `a.` and `a.lock` escaped nothing and are
    legal FILE names — but git REFUSES every one of them as a ref component (measured: `fatal: invalid
    refspec`, rc 6). They passed validation, wrote the local witness, PRINTED a handle, and the push
    then failed permanently — so the lane reads `LOCAL-ONLY`/`EXPIRED` to every peer forever. A regex
    stricter than git is the point; a regex LOOSER than it is a handle that lies.
    """
    mod, origin, tmp_path = box
    for bad in ("../escape", "a/b", "", ".hidden", "-dash", "x" * 200, "a\n b",
                # ⛔ ref-ILLEGAL but regex-plausible before this arm existed:
                "a..b", "a.", "a.lock",
                # ⛔ AND `$`-vs-`\Z`: `$` matches before a trailing newline, so this passed .match()
                # while git refused the ref. One byte was enough to mint a handle that never pushes.
                "a\n", "a.b\n"):
        pushed, detail = mod._push({"lane_id": bad, "state": "RUNNING", "host": "h",
                                    "heartbeat_at": 1, "budget_s": 1, "lease_until": 2,
                                    "started_at": 1}, origin, 20.0)
        assert pushed is False, "id %r must be refused" % (bad,)
        assert "safe ref component" in detail, detail
        with pytest.raises(ValueError):
            mod._write_local({"lane_id": bad, "state": "RUNNING", "host": "h",
                              "heartbeat_at": 1, "budget_s": 1, "lease_until": 2, "started_at": 1})
    assert not (tmp_path / "escape.json").exists()
    assert not (tmp_path / "state" / "lanes" / "escape.json").exists()


def _plant_ref(mod, origin, ref_name, payload):
    """Publish an arbitrary record under an arbitrary ref — a PEER, or a hand-edited ref. Plumbing only.

    A bare repo answers `hash-object`/`mktree`/`commit-tree`/`update-ref` directly, so no checkout is
    needed to forge a ref, exactly as a compromised or buggy peer could.
    """
    env = dict(os.environ, GIT_AUTHOR_NAME="peer", GIT_AUTHOR_EMAIL="peer@example.com",
               GIT_COMMITTER_NAME="peer", GIT_COMMITTER_EMAIL="peer@example.com")

    def plumb(argv, text):
        proc = subprocess.run(["git", "-C", origin] + argv, input=text, capture_output=True,
                              text=True, env=env)
        assert proc.returncode == 0, proc.stderr
        return proc.stdout.strip()

    blob = plumb(["hash-object", "-w", "--stdin"], json.dumps(payload, sort_keys=True))
    tree = plumb(["mktree"], "100644 blob %s\t%s\n" % (blob, mod.PAYLOAD_PATH))
    commit = plumb(["commit-tree", tree], "forged\n")
    plumb(["update-ref", ref_name, commit], "")


def test_T17c_a_ref_whose_payload_names_another_lane_is_corrupt(box, tmp_path):
    """⛔ THE P0. `_push` built its destination from the PAYLOAD's lane_id, not the addressed id, so a
    peer-published ref whose payload named ANOTHER lane let `beat`/`done` overwrite that lane's record
    (reproduced: a terminal DONE flipped back to RUNNING). The ref name and the payload must agree, and
    a mismatch must fail the whole read rather than be trusted as the lane it names.
    """
    mod, origin, tmp_path = box
    victim = start(mod, origin)
    assert run(mod, ["done", "--lane-id", victim, "--pr", "77"] + _remote(origin))[0] == 0
    ok, _detail, records, _src = mod.read_registry(origin, 20.0)
    assert ok and records[victim]["state"] == "DONE"
    forged = dict(records[victim])
    for key in ("_ref", "_sha"):
        forged.pop(key, None)
    forged["lane_id"] = "someone-else"
    forged["state"] = "RUNNING"
    _plant_ref(mod, origin, "%s/%s" % (mod.NS, victim), forged)
    rc, out, err = run(mod, ["list", "--json"] + _remote(origin))
    assert rc == mod.UNMEASURED, (rc, out, err)
    assert "someone-else" in out + err and "mismatch" in out + err, (out, err)
    # ⛔ AND THE LOCAL COPY MUST NOT MASK IT: this box still holds a perfectly good DONE for the victim,
    # so a fallback that answers from it would hide the corruption from the one reader placed to see it.
    assert "NOT replaced by the local copy" in out, out
    # …and a writer holding such a record cannot reach the victim's ref with it: the push addresses the
    # record's OWN safe id, so the worst it can do is publish its own lane — never overwrite another one.
    before = {ref: sha for sha, ref in
              (ln.split() for ln in subprocess.run(["git", "ls-remote", origin], capture_output=True,
                                                   text=True, check=True).stdout.splitlines())}
    assert mod._push(forged, origin, 20.0)[0] is True
    after = {ref: sha for sha, ref in
             (ln.split() for ln in subprocess.run(["git", "ls-remote", origin], capture_output=True,
                                                  text=True, check=True).stdout.splitlines())}
    assert after["%s/%s" % (mod.NS, victim)] == before["%s/%s" % (mod.NS, victim)], \
        "a forged payload must not overwrite another lane's ref"
    assert "%s/someone-else" % mod.NS in after


def test_T18_filters_are_applied_by_the_shared_read_path(box):
    """CLI and MCP both go through `collect`, so a filter must narrow there — not only in `cmd_list`.

    The MCP previously ignored every filter (it called `collect`, which did not apply them) and answered
    a WIDER population than asked for, unlabelled. This asserts one implementation, one answer.
    """
    mod, origin, _ = box
    done = start(mod, origin, tag="a")
    running = start(mod, origin, tag="b")
    assert run(mod, ["done", "--lane-id", done, "--pr", "1"] + _remote(origin))[0] == 0
    ns = type("NS", (), dict(remote=origin, state="DONE", host=None, repo=None, timeout=20.0))()
    ok, _detail, rows, _code, applied, _extra = mod.collect(ns)
    assert ok and [r["lane_id"] for r in rows] == [done]
    assert applied == {"state": "DONE"}
    _rc, out, _e = run(mod, ["list", "--state", "DONE", "--json"] + _remote(origin))
    payload = json.loads(out)
    assert [r["lane_id"] for r in payload["lanes"]] == [done]
    assert payload["counts"]["RUNNING"] == 0 and payload["filters"] == {"state": "DONE"}
    assert running                       # the filtered-out lane really exists


def test_T19_a_beat_holds_the_lease_locally_and_only_renews_the_ref_when_needed(box):
    """Publishing every beat is one commit + one ref write per lane per minute for no new information.

    The lease is what a reader consults, so the ref only has to be renewed before it lapses (half-way);
    `--push` forces it. Without this the registry would mint ~1.4k unreachable objects/day at 25 lanes.
    """
    mod, origin, _ = box
    lane = start(mod, origin, budget=600)
    # Age THIS BOX's copy by two minutes first, so "the beat rewrote it" is observable in a single-second
    # test run (a beat within the same second as `start` leaves the numbers equal).
    aged = json.loads((box[2] / "state" / "lanes" / ("%s.json" % lane)).read_text())
    aged["heartbeat_at"] = int(aged["heartbeat_at"]) - 120
    aged["lease_until"] = aged["heartbeat_at"] + 600
    mod._write_local(aged)
    before_local = dict(aged)
    sha = _ref_shas(origin)
    assert run(mod, ["beat", "--lane-id", lane] + _remote(origin))[0] == 0
    assert _ref_shas(origin) == sha, "a fresh lease must not be republished"
    # ⛔ THE LOCAL WRITE IS THE POINT OF THIS ARM, AND IT USED TO BE UNTESTED. Reading the beat back
    # through `show` is remote-first, so the ref (which the beat deliberately did not touch) answered —
    # and replacing the whole non-renewing branch with `return OK` (writing NOTHING) left the suite green.
    # That write is what stops a partitioned box's local fallback from reading a live lane as EXPIRED.
    local = json.loads((box[2] / "state" / "lanes" / ("%s.json" % lane)).read_text())
    assert int(local["heartbeat_at"]) > int(before_local["heartbeat_at"]), (local, before_local)
    assert int(local["lease_until"]) == int(local["heartbeat_at"]) + 600, local
    assert run(mod, ["beat", "--lane-id", lane, "--push"] + _remote(origin))[0] == 0
    forced = {ref: sha for sha, ref in
              (line.split() for line in subprocess.run(["git", "ls-remote", origin], capture_output=True,
                                                       text=True, check=True).stdout.splitlines())}
    assert forced != sha, "--push must publish"


def test_T20_a_terminal_record_carries_a_consistent_lease(box):
    """`_record_problem` verifies `lease_until == heartbeat_at + budget_s` on every read, so a terminal
    record that skipped that derivation would be rejected as corrupt by every peer."""
    mod, origin, _ = box
    lane = start(mod, origin, budget=120)
    assert run(mod, ["done", "--lane-id", lane, "--pr", "5"] + _remote(origin))[0] == 0
    ok, _detail, records, _src = mod.read_registry(origin, 20.0)
    assert ok
    rec = records[lane]
    assert rec["state"] == "DONE"
    assert int(rec["lease_until"]) == int(rec["heartbeat_at"]) + 120
    assert mod._record_problem(dict(rec)) is None
    assert rec["duration_s"] >= 0 and rec["ended_at"] >= rec["started_at"]


# ── T21 / T22 / T23 — the three defects a green suite could not see ──────────────────────────

def _age(mod, origin, lane_id, seconds):
    """Move one record's heartbeat `seconds` into the past, WITHOUT requiring the lease to have lapsed."""
    ok, _detail, records, _src = mod.read_registry(origin, 20.0)
    assert ok and lane_id in records, records
    rec = dict(records[lane_id])
    for key in ("_ref", "_sha"):
        rec.pop(key, None)
    rec["heartbeat_at"] = int(rec["heartbeat_at"]) - seconds
    rec["lease_until"] = rec["heartbeat_at"] + int(rec["budget_s"])
    pushed, detail = mod._push(rec, origin, 20.0)
    assert pushed, detail
    return rec


def _ref_shas(origin):
    return {ref: sha for sha, ref in
            (line.split() for line in subprocess.run(["git", "ls-remote", origin], capture_output=True,
                                                     text=True, check=True).stdout.splitlines())}


def test_T21_a_beat_renews_the_REF_once_half_the_lease_is_spent(box):
    """⛔ THE HALF-WAY RENEWAL WAS DEAD CODE, AND THIS IS THE ARM THAT WOULD HAVE CAUGHT IT.

    `cmd_beat` assigned `rec["lease_until"] = now + budget` and then compared `now` against THAT — i.e.
    `now >= now + budget//2`, False for every budget — so the ref was never extended past
    `started_at + budget_s`. Since `read_registry` is remote-first, the fresh local heartbeat was never
    consulted while the store was reachable: a lane outliving its budget read EXPIRED to every peer while
    it was working. The old T19 could not see it, because both of its arms hold precisely BECAUSE the
    branch is dead.
    """
    mod, origin, _ = box
    lane = start(mod, origin, budget=600)
    aged = _age(mod, origin, lane, 400)          # 400 of 600 spent: remaining 200 < 300, lease still live
    before = _ref_shas(origin)
    rc, _out, err = run(mod, ["beat", "--lane-id", lane] + _remote(origin))
    assert rc == 0, err
    after = _ref_shas(origin)
    assert after != before, "a half-spent lease MUST renew the ref without --push"
    rec = json.loads(run(mod, ["show", "--lane-id", lane] + _remote(origin) + ["--json"])[1])
    assert rec["state"] == "RUNNING", rec
    assert int(rec["lease_until"]) == int(rec["heartbeat_at"]) + 600, rec
    assert int(rec["lease_until"]) > int(aged["lease_until"]), (rec, aged)
    # …and a FRESH lease still does not republish (the economy half of the same rule).
    settled = _ref_shas(origin)
    assert run(mod, ["beat", "--lane-id", lane] + _remote(origin))[0] == 0
    assert _ref_shas(origin) == settled, "a fresh lease must not be republished"


def test_T22_an_unrecognised_filter_is_REFUSED_not_answered_with_zero(box):
    """The CLI got this from argparse `choices`; the MCP did not, and answered a definite `RUNNING=0`."""
    mod, origin, _ = box
    lane = start(mod, origin)
    ns = type("NS", (), dict(remote=origin, state="BOGUS", host=None, repo=None, timeout=20.0))()
    ok, detail, rows, code, applied, extra = mod.collect(ns)
    assert (ok, code, rows) == (False, mod.USAGE, []), (ok, code, rows)
    assert "not one of" in detail, detail
    # a stray space is NORMALISED, not answered as zero: the filter still finds the lane.
    ns = type("NS", (), dict(remote=origin, state=" RUNNING ", host=None, repo=None, timeout=20.0))()
    ok, _d, rows, code, applied, _x = mod.collect(ns)
    assert ok and applied["state"] == "RUNNING" and [r["lane_id"] for r in rows] == [lane], (rows, applied)
    # an EMPTY result set because the filter could not match must be labelled, not silently zero
    ns = type("NS", (), dict(remote=origin, state=None, host=None, repo="nobody/nothing", timeout=20.0))()
    ok, _d, rows, code, applied, extra = mod.collect(ns)
    assert ok and rows == [] and applied["repo"] == "nobody/nothing", (rows, applied)
    assert extra.get("filter_matched_nothing") is True, extra
    assert extra.get("excluded_no_repo") == 1, extra
    assert lane                                  # the lane that could not answer for its repo
    _rc, out, _e = run(mod, ["list", "--state", "BOGUS", "--json"] + _remote(origin))
    assert _rc == mod.USAGE, out


def test_T23_an_unsafe_lane_id_is_REFUSED_before_anything_is_written(box, tmp_path):
    """`start --lane-id ../escape` exited 6 (\"written, the push failed\") and PRINTED the handle.

    Nothing had been written; the caller was handed an id for a lane that does not exist, and exit 6 is
    documented as \"written on this box, invisible to peers\" — a false claim in the exit table.
    """
    mod, origin, _ = box
    started = _ref_shas(origin)
    for bad in ("../escape", "a/b", ".hidden", "-dash"):
        rc, out, err = run(mod, ["start", "--kind", "lane", "--tag", "1", "--lane-id", bad]
                           + _remote(origin))
        assert rc == mod.USAGE, (bad, rc, out, err)
        # `.hidden`/`a/b`/`../escape` reach OUR guard; `-dash` is caught one step earlier by argparse
        # (`expected one argument`) — both are a refusal, and the point of the arm is that neither
        # writes anything nor hands back a handle.
        if not bad.startswith("-"):
            assert "safe ref component" in err, err
        assert "RUNNING" not in out, "a refused id must not be reported as a started lane"
    assert _ref_shas(origin) == started, "nothing may be written for a refused id"
    assert not (tmp_path / "escape.json").exists()


# ── T24 / T25 / T26 / T27 — the arms a mutation run proved were MISSING ───────────────────────

def test_T24_repeating_an_id_is_REFUSED_even_when_a_sibling_record_is_corrupt(box, tmp_path):
    """⛔ THE LOCAL-WITNESS GUARD WAS VACUOUS AND NOTHING SAW IT.

    Deleting the guard left the suite 50/50 green. Worse, the guard as first written asked
    `_read_local()` — which fails the WHOLE directory as soon as ONE record is corrupt — so with a single
    poisoned sibling present a repeat `start --lane-id X` returned 0 and REPLACED X's record, while the same
    call without the poison returned 5. The probe is now this lane's own file, so neither the sibling nor
    the ref path can make it vacuous.
    """
    mod, origin, _ = box
    lane = start(mod, origin, tag="victim")
    # (a) plain repeat, registry readable
    rc, out, err = run(mod, ["start", "--kind", "lane", "--tag", "0", "--lane-id", lane]
                       + _remote(origin))
    assert rc == mod.REFUSED, (rc, out, err)
    assert "already exists" in err, err
    # (b2) a PEER's record: the ref exists, this box has no local copy. Only the ref probe can refuse it,
    # so this is the arm that makes deleting `if exists:` visible (it survived every other case).
    ok, _d, records, _src = mod.read_registry(origin, 20.0)
    assert ok and lane in records
    peer = dict(records[lane])
    for key in ("_ref", "_sha"):
        peer.pop(key, None)
    peer["lane_id"] = "peer-host.klane-1-1-p1-abcdef12"
    peer["host"] = "peer-host"
    _plant_ref(mod, origin, "%s/%s" % (mod.NS, peer["lane_id"]), peer)
    rc, out, err = run(mod, ["start", "--kind", "lane", "--tag", "0",
                             "--lane-id", peer["lane_id"]] + _remote(origin))
    assert rc == mod.REFUSED, ("a ref with no local copy must still refuse", rc, out, err)
    assert "already exists" in err, err
    # (b) a corrupt SIBLING must not disable the guard — WITH THE REF GONE.
    # ⛔ THE REF MUST BE DELETED FIRST, OR THIS ARM PASSES FOR THE WRONG REASON. With the ref still present
    # `ref_exists` refuses first, so the assertions hold even when the local guard is the pre-fix
    # directory-map version — a mutation run confirmed exactly that (M2 reverted the guard, 38/38 green).
    # The state that actually exercises the guard is: no ref, a local copy, a corrupt sibling.
    subprocess.run(["git", "-C", origin, "update-ref", "-d", "refs/lanes/%s" % lane],
                   check=True, capture_output=True)
    (tmp_path / "state" / "lanes" / "poison.json").write_text("{not json")
    rc, out, err = run(mod, ["start", "--kind", "lane", "--tag", "0", "--lane-id", lane]
                       + _remote(origin))
    assert rc == mod.REFUSED, ("a corrupt sibling defeated the guard", rc, out, err)
    local = json.loads((tmp_path / "state" / "lanes" / ("%s.json" % lane)).read_text())
    assert local["tag"] == "victim", "the existing record must not have been replaced"
    (tmp_path / "state" / "lanes" / "poison.json").unlink()
    # (c) the plain LOCAL_ONLY repeat: ref absent, local copy present, NO corrupt sibling.
    # (The ref was already deleted in (b); this is the same setup minus the poison, so a guard that only
    # survives one of the two states is visible.)
    rc, out, err = run(mod, ["start", "--kind", "lane", "--tag", "0", "--lane-id", lane]
                       + _remote(origin))
    assert rc == mod.REFUSED, (rc, out, err)


def test_T25_a_lane_opened_during_an_outage_can_still_be_CLOSED_afterwards(box, tmp_path):
    """⛔ A LOCAL-ONLY RECORD WAS UNCLOSABLE, AND THE WARN TOLD THE OPERATOR TO RUN A NO-OP.

    `measure_existing` consulted the local copy only when the SHARED READ FAILED. Once the registry came
    back without this lane's ref (it was never pushed), `done` answered NOT-FOUND (measured, rc=4): the
    terminal record was lost to the fleet for every lane launched during a partition, and the advice
    `run_agent` printed (\"publish by hand: done --lane-id …\") could never work.
    """
    mod, origin, _ = box
    shutil.rmtree(origin)                                # outage: start opens a LOCAL-ONLY record
    rc, out, err = run(mod, ["start", "--kind", "lane", "--tag", "1"] + _remote(origin))
    assert rc == mod.LOCAL_ONLY, (rc, out, err)
    lane = out.strip().splitlines()[-1]
    # the registry comes back (a fresh, empty bare repo) — this lane is NOT in it
    subprocess.run(["git", "init", "-q", "--bare", origin], check=True)
    rc, out, err = run(mod, ["done", "--lane-id", lane, "--pr", "42"] + _remote(origin))
    assert rc == 0, ("a local-only lane must still be closable", rc, out, err)
    refs = records_on_refs(origin)
    assert "refs/lanes/%s" % lane in refs, "closing it must PUBLISH the ref, or the fleet never learns"
    rec = json.loads(run(mod, ["show", "--lane-id", lane] + _remote(origin) + ["--json"])[1])
    assert rec["state"] == "DONE" and rec["artifacts"] == [{"kind": "pr", "value": "42"}], rec
    # ⛔ AND A CORRUPT LOCAL COPY MUST NOT BE TRUSTED (or crash). `measure_existing` validates the local
    # record with `_record_problem`; dropping that validation left this suite green, and the effect was an
    # uncaught `KeyError: 'lease_until'` -> exit 1, outside the documented table, plus a corrupt witness
    # being re-pushed as a verdict.
    bad = tmp_path / "state" / "lanes" / "bad-lane.json"
    bad.write_text(json.dumps({"lane_id": "bad-lane", "state": "RUNNING"}))
    rc, out, err = run(mod, ["done", "--lane-id", "bad-lane", "--pr", "9"] + _remote(origin))
    assert rc == mod.NOT_FOUND, (rc, out, err)
    assert "Traceback" not in err, err
    assert "refs/lanes/bad-lane" not in records_on_refs(origin)


def test_T26_show_json_is_JSON_on_every_branch(box, tmp_path):
    """`show --json` emitted bare text on NOT-FOUND — its MOST COMMON answer — so `| jq` was a parse error.

    Deleting either JSON abstention branch, or the found branch's coverage marker, left the suite green.
    """
    mod, origin, _ = box
    lane = start(mod, origin, tag="7")
    rc, out, _e = run(mod, ["show", "--lane-id", lane] + _remote(origin) + ["--json"])
    assert rc == 0
    found = json.loads(out)
    assert found["readable"] is True and found["coverage"] == "shared", found
    assert found["lane_id"] == lane
    rc, out, _e = run(mod, ["show", "--lane-id", "nope.never"] + _remote(origin) + ["--json"])
    assert rc == mod.NOT_FOUND
    missing = json.loads(out)                       # must PARSE
    assert missing["not_found"] == "nope.never" and missing["readable"] is True, missing
    # …and a partial (local-only) read is UNMEASURED, in JSON, with the not-found claim withheld
    shutil.rmtree(origin)
    rc, out, _e = run(mod, ["show", "--lane-id", "nope.never"] + _remote(origin) + ["--json"])
    assert rc == mod.UNMEASURED
    partial = json.loads(out)
    assert partial["readable"] is False and "unmeasured" in partial, partial
    assert "not_found" not in partial, partial
    # the found record read from the local witness says so
    rc, out, _e = run(mod, ["show", "--lane-id", lane] + _remote(origin) + ["--json"])
    assert rc == 0 and json.loads(out)["coverage"] == "local-only", out


def test_T27_the_CLI_normalises_state_exactly_as_the_shared_reader_does(box):
    """`--state " RUNNING "` was rejected by argparse (exit 2, no stdout) while the MCP accepted and
    answered it — two surfaces disagreeing on the argument `collect` exists to unify."""
    mod, origin, _ = box
    lane = start(mod, origin)
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        assert mod.main(["list", "--state", " running ", "--json", "--remote", origin]) == 0
    payload = json.loads(out.getvalue())
    assert payload["filters"] == {"state": "RUNNING"}, payload["filters"]
    assert [r["lane_id"] for r in payload["lanes"]] == [lane]
    args = mod.build_parser().parse_args(["list", "--state", " RUNNING "])
    assert args.state == "RUNNING"
