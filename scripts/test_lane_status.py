#!/usr/bin/env python3
"""Tests for lane-status's suppression rules.

Two independent liveness priors live here, and they have deliberately DIFFERENT strength:

  * a live `task` CHILD  -> may suppress any action verdict (the child is OUTPUT evidence)
  * a recent INBOUND     -> may discount only the IDLE family (it is an INPUT event; it proves
                            the lane was TOLD something, not that it is producing)

The second was got wrong once: it was first built as a liveness signal that vetoed ANY verdict.
That is the defect these tests exist to prevent from returning.
"""
import importlib.util
import os

import pytest

_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lane-status.py")


@pytest.fixture(scope="module")
def L():
    spec = importlib.util.spec_from_file_location("lane_status_under_test", _PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# ── inbound-recency: a PRIOR, not a liveness proof ────────────────────────────

def test_fresh_inbound_discounts_the_idle_family(L):
    """A fresh work order means "do not call this idle" -- the case this signal exists for.

    Measured 2026-10-11: `2a Projection keys` read IDLE->WITHHELD on a work order submitted
    0.03h earlier. Acting on it would have interrupted live work.
    """
    for v in L.INBOUND_DISCOUNTS:
        assert L.inbound_discounts_idle(v, 60) is True, v


def test_wedged_is_never_discounted_by_an_inbound_event(L):
    """⛔ THE CORRECTION. `latest_submitted_at` is INBOUND -- the last turn submitted TO the
    workspace, not output produced BY it. Every value in the column is inbound: the
    orchestrator's is the heartbeat, a marketing lane's is the OWNER asking a question, a rail
    lane's is a dispatch someone sent it.

    So a fresh inbound is NOT proof of life and must never clear WEDGED / CHILD-STUCK /
    CHILD-OVERDUE -- verdicts that say "check the process", whose suppression would hide a real
    wedge. One of tonight's lanes, `tortoise-sweep`, was genuinely wedged.
    """
    for v in (L.WEDGED, L.CHILD_STUCK, L.WAITING_OVERDUE):
        assert L.inbound_discounts_idle(v, 1) is False, v
        assert L.inbound_discounts_idle(v, 60) is False, v


def test_stale_inbound_does_not_discount_idle(L):
    """A lane that was told something 5h ago and has produced nothing since is the genuinely
    suspicious one -- the age is the discriminator, so an old inbound discounts nothing."""
    assert L.inbound_discounts_idle(L.DONE_IDLE, L.INBOUND_FRESH_S + 1) is False


def test_unread_inbound_abstains(L):
    """An unread timestamp is not "recent" and not "stale". It must not discount (a failed read
    must not be able to change a verdict) and must not be read as staleness either."""
    for v in L.ACTION_VERDICTS:
        assert L.inbound_discounts_idle(v, None) is False, v


# ── the child prior: still the stronger signal ───────────────────────────────

def test_a_live_child_suppresses_every_action_verdict(L):
    """The child IS output evidence, so it keeps the wider power: a lane waiting on a child is
    never IDLE/WEDGED/STUCK. Regression guard for the child-count fix."""
    for v in L.ACTION_VERDICTS:
        assert L.child_suppresses(v, [], [], {"call_id": "x"}, None) is True, v


def test_no_child_no_suppression(L):
    assert L.child_suppresses(L.WEDGED, [], [], None, None) is False


def test_an_abandoned_child_does_not_mask_a_wedge(L):
    """`child_stale` past ABANDON_S is a stale RECORD, not a live child -- it must NOT suppress."""
    assert L.child_suppresses(L.WEDGED, [], [], {"call_id": "x"}, L.ABANDON_S + 1) is False


def test_a_missing_child_stat_does_not_count_against_the_child(L):
    """`child_stale is None` is an unreadable stat, not evidence the child is dead."""
    assert L.child_suppresses(L.WEDGED, [], [], {"call_id": "x"}, None) is True


# ── "no record" is not "failed read" ─────────────────────────────────────────
#
# The two render differently on purpose. `cmux list-workspaces --json` covers the live fleet;
# lane-status ALSO unions in rows from the session files, which have no cmux record at all. So a
# lane can legitimately have no `latest_submitted_at` while cmux read perfectly well -- and that
# is a different fact from cmux being unreadable, which means NOTHING follows from inbound.

def test_absent_record_is_not_a_failed_read(L, monkeypatch):
    """cmux read fine; this lane just has no inbound record -> (None, True)."""
    monkeypatch.setattr(L, "_live_workspaces", lambda: [("OTHER-WS", {"latest_submitted_at": None})])
    epoch, readable = L._submitted_epoch("2C-PACK-COMPILE")
    assert (epoch, readable) == (None, True)


def test_unreadable_cmux_reports_itself_as_unreadable(L, monkeypatch):
    """cmux could not be read at all -> (None, False). Must NOT look like 'no record'."""
    monkeypatch.setattr(L, "_live_workspaces", lambda: [])
    epoch, readable = L._submitted_epoch("ANY")
    assert (epoch, readable) == (None, False)


def test_a_parsable_timestamp_comes_back_readable(L, monkeypatch):
    """A live workspace's inbound parses through the existing ts_epoch (UTC, `Z` suffix)."""
    monkeypatch.setattr(L, "_live_workspaces",
                        lambda: [("WS-1", {"latest_submitted_at": "2026-10-11T22:11:13.924Z"})])
    epoch, readable = L._submitted_epoch("ws-1")   # case-insensitive match
    assert readable is True and epoch and epoch > 1_700_000_000


def test_the_two_unknowns_are_never_rendered_alike(L):
    """The row-level contract the renderer depends on: readable=0 -> UNREAD, else '-' when None."""
    def render(r):
        return "UNREAD" if not r.get("inbound_readable", False) else ("-" if r.get("inbound_age") is None else "AGE")
    assert render({"inbound_readable": False, "inbound_age": None}) == "UNREAD"
    assert render({"inbound_readable": True, "inbound_age": None}) == "-"


# ── the discount must not fire on an inbound the lane has already ANSWERED ────
#
# `stale_s` is the lane's OWN session-file age — its output. When output is newer than the
# inbound, the lane took the work order, finished the turn and is idle again. Measured on
# `2a Projection keys`: inbound 27m old, last write 25m old (a completed turn), so it was
# genuinely free and the discount was suppressing a lane that needed dispatching.

def test_a_consumed_inbound_does_not_discount_idle(L):
    """Output NEWER than the inbound -> the lane already answered it -> IDLE stands."""
    assert L.inbound_discounts_idle(L.DONE_IDLE, inbound_age=1660, stale_s=1498) is False


def test_an_unanswered_inbound_does_discount_idle(L):
    """Silent for longer than since it was told -> it has not responded -> do not call it idle."""
    assert L.inbound_discounts_idle(L.DONE_IDLE, inbound_age=108, stale_s=4000) is True


def test_an_unread_output_age_does_not_fire_the_consumed_check(L):
    """`stale_s=None` is unread, not 'consumed' — it must not flip the discount either way."""
    assert L.inbound_discounts_idle(L.DONE_IDLE, inbound_age=60, stale_s=None) is True


def test_the_name_does_not_claim_liveness(L):
    """⛔ The withdrawn over-claim must not survive in a NAME.

    The file spends thirty lines retracting "`latest_submitted_at` is a liveness signal". A constant
    called `INBOUND_LIVE_S` would let the next reader re-derive it anyway, because a name is read
    far more often than the prose beside it. This is a cheap structural guarantee that the
    correction cannot quietly revert.
    """
    src = open(_PATH, encoding="utf-8").read()
    assert "INBOUND_LIVE_S" not in src
    assert "INBOUND_FRESH_S" in src
    assert hasattr(L, "INBOUND_FRESH_S") and not hasattr(L, "INBOUND_LIVE_S")


def test_the_discount_has_its_own_label_not_the_child_one(L):
    """⛔ The discount must not claim a child. `2a` read WAITING-CHILD with no child of any kind
    (no `child`, no `pane_children`, no `declared`) purely because this discount reused the
    child-wait label — so a reader chasing an imaginary child could not see the lane was free."""
    assert L.WAITING_INBOUND != L.WAITING
    assert "CHILD" not in L.WAITING_INBOUND.upper()


def test_the_inbound_prior_reads_the_base_verdict(L):
    """⛔ THE TWO PRIORS MUST READ THE SAME ORIGINAL VERDICT.

    `child_suppresses` REWRITES `verdict` to WAITING-CHILD, and WAITING-CHILD is not in
    `INBOUND_DISCOUNTS` — so if the inbound prior reads the rewritten value it can NEVER fire, for
    any lane that has a child. It is a latent dead-code bug that no behavioural test would catch
    while every fresh-inbound lane also has a child (measured 2026-10-11: 14 lanes with a fresh
    inbound, 0 RECENT-INBOUND). Hence a structural pin: both priors are fed `_base_verdict`, and the
    second is an `elif`, so the child prior wins and exactly one label is produced.
    """
    src = open(_PATH, encoding="utf-8").read()
    assert "_base_verdict = verdict" in src, "the base verdict is not captured before suppression"
    assert "child_suppresses(_base_verdict" in src, "the child prior does not read the base verdict"
    assert "inbound_discounts_idle(_base_verdict" in src, "the inbound prior does not read the base verdict"
    assert "elif inbound_discounts_idle(_base_verdict" in src, "the priors must not both apply"


def test_inbound_message_is_one_sanitised_line_or_none(L):
    """⛔ The inbound TEXT must be a single short line, and ABSENT must not render as EMPTY.

    `latest_submitted_message` is a whole turn, so it can contain newlines and be thousands of
    characters. Two failure modes: a raw turn wrecks the one-line-per-lane table, and a missing
    record returned as `""` becomes indistinguishable from "the turn was empty".
    """
    fake = {"ws-1": {"latest_submitted_message": "hello\n\n  world\t!!  "},
            "ws-2": {"latest_submitted_message": "x" * 500},
            "ws-3": {"latest_submitted_message": "   \n  "},
            "ws-4": {}}
    orig = L._live_workspaces
    try:
        L._live_workspaces = lambda: list(fake.items())
        got1 = L._inbound_message("ws-1")
        assert got1 == "hello world !!", got1
        assert "\n" not in got1 and "\t" not in got1
        got2 = L._inbound_message("ws-2")
        assert len(got2) == L.INBOUND_MSG_MAX + 3 and got2.endswith("..."), (len(got2), got2[:20])
        assert L._inbound_message("ws-3") is None, "whitespace-only must be None, not ''"
        assert L._inbound_message("ws-4") is None, "no record must be None, not ''"
        assert L._inbound_message(None) is None
        assert L._inbound_message("never-seen") is None
    finally:
        L._live_workspaces = orig


def test_inbound_message_abstains_when_cmux_is_unreadable(L):
    """An unread cmux must yield None -- never a message, and never a crash."""
    orig = L._live_workspaces
    try:
        L._live_workspaces = lambda: []
        assert L._inbound_message("ws-1") is None
    finally:
        L._live_workspaces = orig


def test_the_message_is_shown_only_for_recent_inbound(L):
    """⛔ Ordering: only a RECENT-INBOUND row may spend its line on the message.

    Showing it on every row would bury the discriminator column, and the message is not liveness --
    it belongs on screen exactly where it explains a suppression.
    """
    src = open(_PATH, encoding="utf-8").read()
    assert 'r["verdict"] == WAITING_INBOUND and r.get("inbound_msg") and _sa is not None' in src, \
        "the message must be gated on the RECENT-INBOUND verdict AND a real age"
