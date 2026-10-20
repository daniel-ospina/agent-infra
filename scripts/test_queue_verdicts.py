#!/usr/bin/env python3
"""Proof that a TERMINAL queue verdict stays terminal, and that the reset path stays open (#1563).

WHY THIS FILE EXISTS. `claim.py` resolves `CLAIMS.tsv` last-write-wins per PR and treats `SKIPPED`
as non-terminal on every queue. So a `SKIPPED`/`FREE`/unrecognised word written by ANY lane
resurrects an item another lane already terminated as `FIXED`/`BLOCKED`/`LANDED`/`REFUSED`, and
`claim.py next` re-serves it as fresh work. #1563 records SEVEN measured instances in one session,
including #5630 — where the queue's only durable record of a STANDING OWNER DIRECTIVE ("do not
start #5630") was a `BLOCKED` row that a later `SKIPPED` silently un-terminated.

Every fixture below is a verbatim shape from those measurements (file order is the order the rows
appear in `CLAIMS.tsv`). Two things are pinned:

  * the resurrection is GONE  — a non-terminal row after a terminal one is an ANNOTATION
    (what was seen, by whom, and when) and the verdict is unchanged; and
  * the queue is NOT FROZEN  — a new item, a provisional-only item, and an item re-opened by an
    explicit `REOPENED`/`REVIVED` row with a reason all still move. A verdict that can never be
    reset is a worse defect than the one being fixed, and it stays invisible until the reset is
    needed, so the reset path is covered in both directions (a reset WORKS, and an act WITHOUT a
    reason does NOT).

`test_..._the_prefix_rule_serves_these_rows` states the pre-fix rule explicitly as an oracle:
under `if v in terminal: continue` + last-write-wins, all seven measured rows are SERVED. That is
the behaviour this change removes; the new resolver returns the opposite for the same bytes.

THE WIRING IS PINNED SEPARATELY (`the dispatcher SEAM` section at the end). Every other test in
this file calls `verdict_guard` / `refuse_resurrected` / `outcome_menu` DIRECTLY, so all of them
stay green if the call sites in `main()` are deleted — the gate would be a function nobody calls
and the resurrection would return with the suite reporting clean. The last section asserts the
call sites exist and are ordered before delivery, the same way `test_queue_dispatch.py` pins the
sibling pr-first gate.

Run:  python3 -m pytest scripts/test_queue_verdicts.py -q
"""
from __future__ import annotations

import importlib.util
import os
import pathlib
import sys

import pytest

_SCRIPTS = pathlib.Path(__file__).resolve().parent


def _load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, _SCRIPTS / filename)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


qv = _load("queue_verdicts_under_test", "queue_verdicts.py")
qd = _load("queue_dispatch_under_test", "queue-dispatch.py")

# claim.py's OWN terminal sets (claim.py:191-194), copied here as the ORACLE: the re-affirmation
# this fix writes must be a word the DEPLOYED tool already reads as terminal, or the item keeps
# looping. claim.py is not versioned in this repo (#1552/#1567), so it cannot be imported; pinning
# its vocabulary here is what makes that dependency visible instead of assumed.
CLAIM_PY_TERMINAL = {
    "LANDABLE.tsv": {"LANDED", "REFUSED", "BLOCKED"},
    "CI-PRS.tsv": {"LANDED", "REFUSED", "BLOCKED"},
    "CONFLICTS.tsv": {"LANDED", "FIXED", "BLOCKED"},
    "REMEDY.tsv": {"LANDED", "FIXED", "BLOCKED"},
}


def _claims(*rows) -> str:
    """(pr, lane, verdict, rest?) -> CLAIMS.tsv text. `rest` is a reason OR a HH:MM:SS stamp,
    exactly as claim.py writes it."""
    out = []
    for row in rows:
        out.append("\t".join(str(f) for f in row))
    return "\n".join(out) + "\n"


def _last_write_wins(text: str, queue: str):
    """THE PRE-FIX RULE, stated so the defect is reproducible rather than described.

    `claim.py next` decides with `if v in terminal: continue`, so the EFFECTIVE row is simply the
    last row for the PR; the item is served whenever that last row's verdict is not terminal.
    """
    terminal = CLAIM_PY_TERMINAL.get(os.path.basename(queue), {"LANDED", "FIXED", "BLOCKED"})
    last = {}
    for row in qv.parse_rows(text)[0]:
        last[row.pr] = row.verdict
    return {pr: (v not in terminal) for pr, v in last.items()}


# ── the seven measured resurrection shapes (+ #6119's FREE and #7413's work-order REFUSED) ────
MEASURED = [
    # (issue row, queue being served, rows in file order, terminal word that must survive)
    ("3419", "CONFLICTS.tsv", [
        ("3419", "land-lane-2", "FIXED", "conflict cleared and pushed"),
        ("3419", "rebase-lane", "SKIPPED", "NO REBASE NEEDED — the queue's CONFLICTING label is stale"),
    ], "FIXED"),
    ("5453", "CONFLICTS.tsv", [
        ("5453", "land-lane-2", "BLOCKED", "redundant — same fix landed twice"),
        ("5453", "rebase-lane", "SKIPPED", "no conflict to resolve"),
    ], "BLOCKED"),
    ("5461", "CONFLICTS.tsv", [
        ("5461", "land-lane-2", "BLOCKED", "semantic conflict: DEFAULT_MIN_KEYWORDS removed by main"),
        ("5461", "rebase-lane", "SKIPPED", "not this PR's defect"),
        ("5461", "4a Retrieval and traversal", "FIXED", "rebased"),
        ("5461", "lane-b-ci-substrate", "NEEDS-REBASE", "coined word, resurrected a FIXED row"),
    ], "BLOCKED"),
    ("5667", "CONFLICTS.tsv", [
        ("5667", "land-lane-2", "FIXED", "cleared"),
        ("5667", "rebase-lane", "SKIPPED", "nothing to do"),
        ("5667", "rebase-lane", "SKIPPED", "nothing to do (again)"),
    ], "FIXED"),
    ("5696", "CONFLICTS.tsv", [
        ("5696", "land-lane-2", "FIXED", "cleared, pushed"),
        ("5696", "rebase-lane", "SKIPPED", "no rebase needed"),
    ], "FIXED"),
    ("6234", "CONFLICTS.tsv", [
        ("6234", "land-lane-2", "BLOCKED", "superseded by main's #6135 rework"),
        ("6234", "rebase-lane", "SKIPPED", "cannot reproduce"),
        ("6234", "rebase-lane", "SKIPPED", "cannot reproduce"),
    ], "BLOCKED"),
    ("5630", "LANDABLE.tsv", [
        ("5630", "2b Extractor", "BLOCKED",
         "STANDING OWNER DIRECTIVE: do not start #5630 or #5651 — starting it is the forbidden action"),
        ("5630", "land-lane-4", "SKIPPED", "held by another lane"),
    ], "BLOCKED"),
    # the resurrecting row was a claim RELEASE, not a skip (#1563, 2026-10-04)
    ("6119", "LANDABLE.tsv", [
        ("6119", "land-lane-2 (73A9A92C)", "CLAIMED", "17:31:30"),
        ("6119", "land-lane-2 (73A9A92C)", "BLOCKED",
         "SEMANTIC — the PR's fix and main's #5360 safety fix are MUTUALLY EXCLUSIVE; needs the AUTHOR"),
        ("6119", "__orchestrator__", "FREE", "01:47:02"),
        ("6119", "π - land-lane-4", "CLAIMED", "02:08:23"),
    ], "BLOCKED"),
    # #7413 on REMEDY, where REFUSED is the WORK ORDER and therefore not a terminal verdict
    ("7413", "REMEDY.tsv", [
        ("7413", "4-REVIEW", "BLOCKED", "review-record bound to a live head"),
        ("7413", "4-REVIEW", "REFUSED", "re-run the review at the new head"),
    ], "BLOCKED"),
]


@pytest.mark.parametrize("pr,queue,rows,terminal", MEASURED, ids=[m[0] for m in MEASURED])
def test_a_terminal_verdict_survives_a_late_non_terminal_row(pr, queue, rows, terminal):
    res = qv.resolve(_claims(*rows), queue)
    assert res.servable(pr) is False, f"#{pr} was resurrected on {queue}"
    assert res.verdict_of(pr) == terminal, f"#{pr}: the effective verdict must stay {terminal}"
    # every row after the terminal one is RECORDED (as an annotation), none is lost
    parsed = qv.parse_rows(_claims(*rows))[0]
    term_at = next(i for i, r in enumerate(parsed) if r.verdict == terminal)
    assert [a.verdict for a in res.annotations_for(pr)] == [r.verdict for r in parsed[term_at + 1:]]


@pytest.mark.parametrize("pr,queue,rows,terminal", MEASURED, ids=[m[0] for m in MEASURED])
def test_the_prefix_rule_serves_these_rows(pr, queue, rows, terminal):
    """The defect, reproduced: under claim.py's own rule every one of these rows is SERVED."""
    assert _last_write_wins(_claims(*rows), queue)[pr] is True, (
        f"#{pr} is not a resurrection fixture under last-write-wins — the fixture is wrong")


def test_the_later_observation_is_recorded_with_what_and_when():
    text = _claims(
        ("6119", "land-lane-2 (73A9A92C)", "BLOCKED", "SEMANTIC — needs the AUTHOR"),
        ("6119", "__orchestrator__", "FREE", "01:47:02"),
        ("6119", "π - land-lane-4", "SKIPPED", "held by a live rail"),
    )
    res = qv.resolve(text, "LANDABLE.tsv")
    anns = res.annotations_for("6119")
    assert [a.verdict for a in anns] == ["FREE", "SKIPPED"]
    free, skipped = anns
    assert free.lane == "__orchestrator__" and free.at == "01:47:02"   # WHEN, from the stamp
    assert skipped.lane == "π - land-lane-4" and skipped.at is None     # a reason row: no stamp
    assert "held by a live rail" in skipped.describe()                  # WHAT was seen
    assert "FREE at 01:47:02" in free.describe()
    assert "later observations recorded as annotations" in res.why("6119")


def test_an_unrecognised_verdict_is_LOUD_and_still_cannot_resurrect():
    res = qv.resolve(_claims(
        ("5461", "land-lane-2", "BLOCKED", "semantic conflict"),
        ("5461", "lane-b-ci-substrate", "NEEDS-REBASE", "coined word"),
    ), "CONFLICTS.tsv")
    assert [r.verdict for r in res.unknown] == ["NEEDS-REBASE"]
    assert res.servable("5461") is False
    assert "UNRECOGNISED" in qv.guard(res, "5461").reaffirm_reason


# ── the reverse direction: the queue must still MOVE ────────────────────────────────────────
def test_a_genuinely_new_item_is_servable():
    res = qv.resolve(_claims(("7000", "some-lane", "SKIPPED", "not mine")), "LANDABLE.tsv")
    assert res.servable("7000") is True


def test_a_provisional_only_item_still_moves_last_write_wins():
    text = _claims(
        ("7001", "lane-a", "CLAIMED", "10:00:00"),
        ("7001", "lane-a", "SKIPPED", "held by a rail"),
        ("7001", "lane-b", "FREE", "10:05:00"),
    )
    res = qv.resolve(text, "LANDABLE.tsv")
    assert res.servable("7001") is True
    assert res.verdict_of("7001") is None
    assert res.governing["7001"].verdict == "FREE"


def test_an_explicit_reopen_with_a_reason_moves_a_terminal_item_again():
    base = [
        ("5667", "land-lane-2", "FIXED", "cleared"),
        ("5667", "rebase-lane", "SKIPPED", "nothing to do"),
    ]
    assert qv.resolve(_claims(*base), "CONFLICTS.tsv").servable("5667") is False

    reopened = base + [("5667", "operator", "REOPENED",
                        "the stored clean record was bound to a stale head; fresh review required")]
    res = qv.resolve(_claims(*reopened), "CONFLICTS.tsv")
    assert res.servable("5667") is True, "the reset path must re-open the item"
    assert [a.verdict for a in res.acts["5667"]] == ["REOPENED"]

    # …and the item can terminate again, and is sticky again (no permanent un-termination)
    again = reopened + [("5667", "4-REVIEW", "BLOCKED", "fresh review found a real defect"),
                        ("5667", "4-REVIEW", "SKIPPED", "parked")]
    assert qv.resolve(_claims(*again), "CONFLICTS.tsv").servable("5667") is False


def test_annotations_belong_to_the_epoch_of_the_verdict_in_force():
    """A revived item must not be reported alongside observations that PREDATE its new verdict —
    that is the same false account (a row mis-describing the artifact) this module removes."""
    res = qv.resolve(_claims(
        ("5718", "land-lane-2", "REFUSED", "the rail said no"),
        ("5718", "rebase-lane", "SKIPPED", "an old-epoch observation"),
        ("5718", "operator", "REVIVED", "fresh record at head + zero failing checks"),
        ("5718", "4-REVIEW", "BLOCKED", "fresh review found a real defect"),
        ("5718", "rebase-lane", "SKIPPED", "a new-epoch observation"),
    ), "LANDABLE.tsv")
    assert res.servable("5718") is False
    assert res.verdict_of("5718") == "BLOCKED"
    assert [a.verdict for a in res.annotations_for("5718")] == ["SKIPPED"]
    assert "old-epoch" not in res.why("5718") and "new-epoch" in res.why("5718")


def test_revived_is_honoured_too_claim_pys_own_word():
    res = qv.resolve(_claims(
        ("5718", "land-lane-2", "REFUSED", "the rail said no (stale premise)"),
        ("5718", "operator", "REVIVED", "fresh record at head + zero failing checks"),
    ), "LANDABLE.tsv")
    assert res.servable("5718") is True


def test_an_act_without_a_reason_is_refused_and_does_not_reset():
    res = qv.resolve(_claims(
        ("5667", "land-lane-2", "FIXED", "cleared"),
        ("5667", "someone", "REOPENED", ""),
    ), "CONFLICTS.tsv")
    assert res.servable("5667") is False, "an unexplained act must not un-terminate a verdict"
    assert [r.verdict for r in res.refused_acts] == ["REOPENED"]


# ── the owner-prohibition arm (#5630) ───────────────────────────────────────────────────────
def test_a_prohibition_outranks_every_lifecycle_verdict_and_is_not_liftable_by_reopen():
    text = _claims(
        ("5630", "owner-feeder", "PROHIBITED", "STANDING OWNER DIRECTIVE: do not start #5630 or #5651"),
        ("5630", "land-lane-4", "SKIPPED", "held by another lane"),
        ("5630", "land-lane-4", "FIXED", "I fixed it anyway"),
        ("5630", "operator", "REOPENED", "we think it is fine now"),
    )
    res = qv.resolve(text, "LANDABLE.tsv")
    assert res.servable("5630") is False
    assert res.verdict_of("5630") == "PROHIBITED", "a completion word is not a permission decision"
    assert "PROHIBITED" in res.why("5630")

    g = qv.guard(res, "5630")
    assert g.reaffirm == "BLOCKED"      # claim.py has no PROHIBITED; BLOCKED is its "do not act" word
    assert "owner directive" in g.reaffirm_reason and "LIFTED" in g.reaffirm_reason


def test_a_prohibition_recorded_after_a_verdict_starts_its_own_epoch():
    """Measured order on #5630's history: the item was worked and blocked, and the owner
directive came LATER. The prohibition binds, and the observations from before it are history —
not `later observations` of the prohibition."""
    res = qv.resolve(_claims(
        ("5630", "land-lane-2", "BLOCKED", "a decision no other lane can make"),
        ("5630", "rebase-lane", "SKIPPED", "an observation from before the directive"),
        ("5630", "owner-feeder", "PROHIBITED", "STANDING OWNER DIRECTIVE: do not start #5630"),
        ("5630", "land-lane-4", "SKIPPED", "an observation after the directive"),
    ), "LANDABLE.tsv")
    assert res.servable("5630") is False
    assert res.verdict_of("5630") == "PROHIBITED"
    assert [a.verdict for a in res.annotations_for("5630")] == ["SKIPPED"]
    assert "before the directive" not in res.why("5630")
    assert "after the directive" in res.why("5630")


def test_the_owner_lift_is_the_only_way_out_of_a_prohibition():
    res = qv.resolve(_claims(
        ("5630", "owner-feeder", "PROHIBITED", "STANDING OWNER DIRECTIVE"),
        ("5630", "owner-feeder", "LIFTED", "directive withdrawn — duplicate assignments resolved"),
    ), "LANDABLE.tsv")
    assert res.servable("5630") is True


# ── claim.py's class-dependent terminality must be PRESERVED (the two-stage pipeline) ──────
def test_fixed_is_terminal_on_a_work_queue_and_provisional_on_the_landing_queue():
    rows = (("3419", "land-lane-2", "FIXED", "conflict cleared, pushed"),
            ("3419", "rebase-lane", "SKIPPED", "stale CONFLICTING label"))
    assert qv.resolve(_claims(*rows), "CONFLICTS.tsv").servable("3419") is False
    assert qv.resolve(_claims(*rows), "REMEDY.tsv").servable("3419") is False
    # FIXED on a CONFLICTS row means "cleared, ready to land" — a sticky rule applied to the
    # LANDING queue would strand exactly the item the pipeline just produced.
    assert qv.resolve(_claims(*rows), "LANDABLE.tsv").servable("3419") is True


def test_refused_is_terminal_on_the_landing_queue_only():
    rows = (("7413", "land-lane-2", "REFUSED", "the rail said no"),)
    assert qv.resolve(_claims(*rows), "LANDABLE.tsv").servable("7413") is False
    assert qv.resolve(_claims(*rows), "REMEDY.tsv").servable("7413") is True


def test_an_unknown_queue_is_conservative_but_never_calls_refused_terminal():
    cls, terminal = qv.queue_class("SOMETHING-NEW.tsv")
    assert cls == "unknown"
    assert "REFUSED" not in terminal
    assert {"LANDED", "FIXED", "BLOCKED"} <= set(terminal)


# ── the guard: what the dispatcher WRITES must terminate the row in claim.py too ────────────
@pytest.mark.parametrize("queue", sorted(CLAIM_PY_TERMINAL))
def test_the_terminal_set_is_claim_pys_own(queue):
    """The module's class tables and the deployed tool's must not drift: a per-queue terminal
    set that is WIDER than claim.py's would refuse items claim.py would serve (a false freeze);
    a NARROWER one would miss the very rows this fix exists for."""
    assert set(qv.queue_class(queue)[1]) == CLAIM_PY_TERMINAL[queue]


@pytest.mark.parametrize("queue", sorted(CLAIM_PY_TERMINAL))
def test_the_reaffirmed_word_is_terminal_in_the_DEPLOYED_queue(queue):
    rows = (("9001", "lane-a", "BLOCKED", "a decision no other lane can make"),)
    g = qv.guard(qv.resolve(_claims(*rows), queue), "9001")
    assert g.servable is False
    assert g.reaffirm in CLAIM_PY_TERMINAL[queue], (
        f"{g.reaffirm} is not terminal for {queue} in claim.py — the item would loop forever")


def test_reaffirming_is_idempotent_and_keeps_the_annotation():
    text = _claims(
        ("5630", "2b Extractor", "BLOCKED", "STANDING OWNER DIRECTIVE: do not start #5630"),
        ("5630", "land-lane-4", "SKIPPED", "held by another lane"),
    )
    g = qv.guard(qv.resolve(text, "LANDABLE.tsv"), "5630")
    assert g.servable is False and g.reaffirm == "BLOCKED"
    assert "held by another lane" in g.reaffirm_reason       # the annotation travels with the write
    assert "REOPENED" in g.reaffirm_reason                   # and the reset path is named

    replayed = text + _claims(("5630", "land-lane-4", g.reaffirm, g.reaffirm_reason))
    res2 = qv.resolve(replayed, "LANDABLE.tsv")
    assert res2.servable("5630") is False, "the re-affirmed row must not flip the item back"
    assert res2.verdict_of("5630") == "BLOCKED"
    assert [a.verdict for a in res2.annotations_for("5630")][-1] == "BLOCKED"


# ── parsing: the shapes the measured histories are quoted in ────────────────────────────────
def test_a_leading_line_number_is_not_read_as_the_pr():
    text = "1578\t6244\t4a Retrieval and traversal\tSKIPPED\tNOT a conflict and NOT this PR's defect\n"
    rows, malformed = qv.parse_rows(text)
    assert not malformed
    assert rows[0].pr == "6244"
    assert rows[0].lane == "4a Retrieval and traversal"
    assert rows[0].verdict == "SKIPPED"


def test_malformed_rows_are_reported_not_silently_dropped():
    rows, malformed = qv.parse_rows("nonsense line\n1\t2\t\n")
    assert rows == []
    assert len(malformed) == 2


def test_the_menu_is_the_QUEUES_vocabulary_and_the_lane_label_is_quoted():
    conflicts = qd.outcome_menu("4a Retrieval and traversal", "5461", "/q/CONFLICTS.tsv")
    assert 'done "4a Retrieval and traversal" 5461' in conflicts
    assert "FIXED" in conflicts and "BLOCKED" in conflicts
    assert "REOPENED" in conflicts

    land = qd.outcome_menu("land-lane-4", "5630", "/q/LANDABLE.tsv")
    assert "REFUSED" in land and "FIXED" not in land


# ── the dispatcher seam, end to end over a real CLAIMS.tsv in a temp STATE ─────────────────
def test_the_dispatcher_refuses_to_serve_a_resurrected_item(tmp_path, monkeypatch):
    (tmp_path / "CLAIMS.tsv").write_text(_claims(
        ("5630", "2b Extractor", "BLOCKED", "STANDING OWNER DIRECTIVE: do not start #5630"),
        ("5630", "land-lane-4", "SKIPPED", "held by another lane"),
    ), encoding="utf-8")
    monkeypatch.setattr(qd, "STATE", str(tmp_path))

    g = qd.verdict_guard(str(tmp_path / "LANDABLE.tsv"), "5630")
    assert g.servable is False
    assert g.verdict == "BLOCKED"
    assert g.reaffirm == "BLOCKED"
    assert "held by another lane" in g.reaffirm_reason


def test_the_dispatcher_serves_an_item_with_no_terminal_verdict(tmp_path, monkeypatch):
    (tmp_path / "CLAIMS.tsv").write_text(_claims(
        ("7002", "land-lane-4", "SKIPPED", "held by a rail"),
    ), encoding="utf-8")
    monkeypatch.setattr(qd, "STATE", str(tmp_path))
    assert qd.verdict_guard(str(tmp_path / "LANDABLE.tsv"), "7002").servable is True


def test_the_dispatcher_can_RESET_an_item_through_the_same_replay(tmp_path, monkeypatch):
    """The reset path through the real seam: a REOPENED row with a reason un-freezes the item."""
    (tmp_path / "CLAIMS.tsv").write_text(_claims(
        ("5630", "2b Extractor", "BLOCKED", "STANDING OWNER DIRECTIVE: do not start #5630"),
        ("5630", "owner-feeder", "LIFTED", "directive withdrawn"),
    ), encoding="utf-8")
    monkeypatch.setattr(qd, "STATE", str(tmp_path))
    assert qd.verdict_guard(str(tmp_path / "LANDABLE.tsv"), "5630").servable is True


def test_a_missing_CLAIMS_file_is_no_verdicts_not_an_error(tmp_path, monkeypatch):
    monkeypatch.setattr(qd, "STATE", str(tmp_path))
    assert qd.verdict_guard(str(tmp_path / "LANDABLE.tsv"), "7003").servable is True


def test_the_dispatcher_writes_the_reaffirmation_through_claim_py(tmp_path, monkeypatch):
    """The refusal must actually WRITE the terminal verdict back. Releasing the claim alone
    restores the item to the pool (`FREE` + immediate re-serve was measured at the same second),
    so a guard that only released would hand the same item to this lane forever."""
    (tmp_path / "CLAIMS.tsv").write_text(_claims(
        ("5630", "2b Extractor", "BLOCKED", "STANDING OWNER DIRECTIVE: do not start #5630"),
        ("5630", "land-lane-4", "SKIPPED", "held by another lane"),
    ), encoding="utf-8")
    monkeypatch.setattr(qd, "STATE", str(tmp_path))
    calls = []
    monkeypatch.setattr(qd, "sh", lambda argv, timeout=None: (calls.append(argv), (0, ""))[1])

    class _Done:
        def __init__(self, argv, **kw):
            calls.append(argv)
            self.returncode = 0
            self.stdout = self.stderr = ""

    monkeypatch.setattr(qd.subprocess, "run", _Done)

    g = qd.verdict_guard(str(tmp_path / "LANDABLE.tsv"), "5630")
    assert qd.refuse_resurrected("land-lane-4", "5630", g, True) == "BLOCKED"

    done = [c for c in calls if len(c) > 2 and c[2] == "done"]
    assert len(done) == 1, "the terminal verdict was not written back — the item would loop"
    argv = done[0]
    assert argv[3] == "land-lane-4" and argv[4] == "5630"
    assert argv[5] == "BLOCKED"
    assert "held by another lane" in argv[6], "the later observation must survive as an annotation"
    assert any(len(c) > 2 and c[2] == "free" for c in calls), "the claim must be released"


def test_a_dry_run_refuses_without_writing_anything(tmp_path, monkeypatch):
    (tmp_path / "CLAIMS.tsv").write_text(_claims(
        ("5630", "2b Extractor", "BLOCKED", "STANDING OWNER DIRECTIVE: do not start #5630"),
    ), encoding="utf-8")
    monkeypatch.setattr(qd, "STATE", str(tmp_path))
    calls = []
    monkeypatch.setattr(qd, "sh", lambda argv, timeout=None: (calls.append(argv), (0, ""))[1])
    monkeypatch.setattr(qd.subprocess, "run", lambda argv, **kw: calls.append(argv))

    g = qd.verdict_guard(str(tmp_path / "LANDABLE.tsv"), "5630")
    assert qd.refuse_resurrected("land-lane-4", "5630", g, False) is None
    assert [c for c in calls if len(c) > 2 and c[2] == "done"] == [], "a dry run must write nothing"
    assert any(len(c) > 2 and c[2] == "free" for c in calls)


@pytest.mark.skipif(os.geteuid() == 0, reason="root can read a 000 file; the read cannot be made to fail")
def test_an_unreadable_CLAIMS_file_is_UNKNOWN_not_empty(tmp_path, monkeypatch):
    p = tmp_path / "CLAIMS.tsv"
    p.write_text("", encoding="utf-8")
    p.chmod(0o000)
    monkeypatch.setattr(qd, "STATE", str(tmp_path))
    with pytest.raises(qd.QueueReadError):
        qd.verdict_guard(str(tmp_path / "LANDABLE.tsv"), "7004")


def test_pr_of_reads_the_item_shape_claim_py_prints():
    assert qd.pr_of("PR 5484  4-REVIEW -- review at the current head") == "5484"
    assert qd.pr_of("PR  7413") == "7413"
    assert qd.pr_of("no number here") is None


# ── the dispatcher SEAM: the gate must be a GATE, not a function nobody calls ───────────────
# ⛔ EVERY test above calls the gate's functions DIRECTLY. Delete the whole
# `── A TERMINAL VERDICT STAYS TERMINAL (#1563) ──` block from `main()` and all of them stay
# green: the resurrection returns, the suite reports clean. That is not a hypothetical — it is
# the class of defect this PR exists to remove one layer down (a filter that logs a drop but
# does not perform it), so the seam is pinned by SOURCE POSITION rather than by a `main()`
# harness: `main()` reads the live verdicts file, shells out to `claim.py` and then to
# safe-send.sh, and a harness that stubbed all three would be a second dispatcher, tested
# against itself. This mirrors
# `test_queue_dispatch.py::test_the_gate_is_actually_CALLED_by_the_dispatch_path`.
_SRC = (_SCRIPTS / "queue-dispatch.py").read_text(encoding="utf-8")

# The delivery call: safe-send.sh is reached exactly twice (the CONTINUE nudge, and the item
# dispatch we care about), so the search starts AFTER the guard and finds the dispatch one.
_SEND = 'rc, out, err = sh(["bash", SAFE_SEND'


def test_the_sticky_verdict_gate_is_CALLED_and_REFUSES_before_delivery():
    """The gate must RUN, its refusal must happen, and control must leave before safe-send."""
    assert "g = verdict_guard(qpath, pr_guard)" in _SRC, (
        "the sticky-verdict guard is not wired into main() — it is a function nobody calls, "
        "and every other test in this file still passes (#1563)")
    i_guard = _SRC.index("g = verdict_guard(qpath, pr_guard)")
    i_send = _SRC.index(_SEND, i_guard)
    assert i_guard < i_send, "the gate must be evaluated BEFORE the item is delivered"

    i_branch = _SRC.index("if g is not None and not g.servable:", i_guard)
    i_refuse = _SRC.index("refuse_resurrected(", i_branch)
    i_continue = _SRC.index("continue", i_refuse)
    assert i_guard < i_branch < i_refuse < i_continue < i_send, (
        "a non-servable item must be REFUSED (and the lane skipped) before safe-send is "
        "reached — otherwise the resurrection is refused in the log and delivered anyway")


def test_the_gate_is_LOUD_on_the_one_input_it_cannot_check():
    """No PR number in the served item ⇒ the check did not run, and the log must SAY so.

    Skip it silently and "the gate did not run" is indistinguishable in the log from "the gate
    ran and passed" — a no-op gate reading green, the defect one layer up.
    """
    note = qd.no_pr_note("land-lane-4", "no digits in this row at all")
    assert note.lstrip().startswith("⚠"), "an unrun check must not be reported as fine"
    assert "land-lane-4" in note and "#1563" in note
    assert "did NOT run" in note, note
    assert "no digits in this row at all" in note, "the note must quote what it could not read"
    # an EMPTY item must not crash the loudness path (it is the worst case: nothing to show)
    assert "did NOT run" in qd.no_pr_note("land-lane-4", "")


def test_the_UNCHECKABLE_branch_is_WIRED_and_fails_OPEN():
    """The loud line must be the `else` of the PR check — not a helper nobody prints."""
    i_guard = _SRC.index("g = verdict_guard(qpath, pr_guard)")
    i_note = _SRC.index("print(no_pr_note(lane, item))", i_guard)
    i_branch = _SRC.index("if g is not None and not g.servable:", i_guard)
    assert i_guard < i_note < i_branch, (
        "the loud line must sit in the else of the PR check, BEFORE the servable test")
    i_else = _SRC.rindex("        else:", i_guard, i_note)
    body = _SRC[i_else:i_note]
    assert "continue" not in body, (
        "the no-PR-number path must fail OPEN — withholding the whole lane on a queue-row "
        "format drift stalls delivery for every item behind it (that is why it is a loud "
        "fall-through, not a refusal)")


def test_the_menu_the_lane_is_TOLD_to_record_comes_from_the_ROWs_queue():
    """#1563's SECOND route: an unconditional menu whose words may terminate no row at all.

    `test_the_menu_is_the_QUEUES_vocabulary...` above calls `outcome_menu()` DIRECTLY, so it
    stays green if the call site reverts to the old one-size constant — and a `conflict` row's
    lane is then told a vocabulary containing no verdict that terminates its own row (#5461).
    """
    assert "menu = outcome_menu(lane, pn, qpath)" in _SRC, (
        "the menu is not derived from the row's queue at the CALL SITE")
    i_menu = _SRC.index("menu = outcome_menu(lane, pn, qpath)")
    i_use = _SRC.index(" + menu +", i_menu)
    i_send = _SRC.index(_SEND, i_menu)
    assert i_menu < i_use < i_send, "the derived menu must reach the brief that is delivered"
    assert "<LANDED|REFUSED|SKIPPED>" not in _SRC, (
        "the pre-fix one-size menu is back at a call site — it contains no verdict that "
        "terminates a CONFLICTS row")
