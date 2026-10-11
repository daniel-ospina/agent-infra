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
    assert L.inbound_discounts_idle(L.DONE_IDLE, L.INBOUND_LIVE_S + 1) is False


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
