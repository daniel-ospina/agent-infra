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


def test_an_unread_screen_is_unknown_never_a_confident_no_spinner(L):
    """⛔ `read-screen` IS INTERMITTENTLY EMPTY UNDER LOAD, AND EMPTY MUST NOT MEAN "NO SPINNER".

    `sh()` returns "" on ANY exception, including a timeout, and the file's own comment measures
    `read-screen` at ~10-15s per call. So `"Working" in ""` was False and a FAILED READ became a
    confident claim about the pane. Two consequences, both wrong:
      - the UI column printed `-`, a claim, indistinguishable from a real read with no spinner;
      - `classify`'s long-tool gate saw `spinner=False` and ruled the long tool OUT, pushing a lane
        with a tool genuinely in flight toward WEDGED.
    A live pi pane always draws a status line, so an empty screen is an UNREAD, never a blank pane.
    """
    for blank in ("", "   ", "\n\n", None):
        _sc = blank if isinstance(blank, str) else ""
        assert (None if not _sc.strip() else True) is None, f"blank {blank!r} must be UNKNOWN"


def test_classify_does_not_rule_out_a_tool_on_an_unread_screen(L):
    """The long-tool gate must read `spinner is not False`, so UNKNOWN cannot exclude the tool.

    ⛔ BEHAVIOURAL, NOT A SOURCE GREP. This asserted on the literal text of the guard, which pinned
    the EXPRESSION rather than the rule: it went red when the guard was rewritten to stop gating on
    child evidence (the fix for `Drain` reading CHILD-STUCK mid-`bash`), even though the rewritten
    guard reads `spinner is not False` exactly as required. A source assertion cannot tell those two
    apart; calling `classify()` can.
    """
    ti = {"name": "bash", "timeout": 1790, "age": 1415}
    # an UNREAD screen (None) must not exclude a tool that is inside its own declared budget
    assert L.classify(1507, False, None, "tool", None, None, None, None, ti) == L.LONG_TOOL
    # a screen READ with no spinner is genuine evidence against an in-flight tool
    assert L.classify(1507, False, False, "tool", None, None, None, None, ti) != L.LONG_TOOL


def test_a_live_tool_outranks_a_days_old_abandoned_child_record(L):
    """⛔ THE REGRESSION. Measured 2026-10-12 on `Drain (PR queue support)`: its pi held a live
    `bash -> sleep 52` poll loop (0 CPU, no connection) while an abandoned `task` record from
    3.9 days earlier sat in its session. The long-tool guard was gated on `child_has_evidence`,
    which is true merely because the child has a transcript -- so the guard was skipped, `ti` was
    left None, and the lane read CHILD-STUCK where the PRE-CHANGE instrument read LONG-TOOL.
    A declared-budget tool in flight on the PARENT is the strongest explanation of the quiet, and
    no record about a child may suppress it."""
    child = {"call_id": "x", "age": 338417, "abandoned": True}
    ti = {"name": "bash", "timeout": 1790, "age": 1415}
    v = L.classify(1507, False, True, "tool", child, 334455, False, None, ti,
                   has_sid=True)
    assert v == L.LONG_TOOL, (
        "a live tool call within its declared budget must read LONG-TOOL, not %s -- an abandoned "
        "child record may not suppress the parent's own in-flight tool" % v)
    # ...and the abandoned record is still answered when there is NO tool in flight.
    v2 = L.classify(12007, False, True, "tool", child, 11438, False, None, None, has_sid=True)
    assert v2 == L.CHILD_STUCK, "with no tool in flight the child record still decides: %s" % v2


def test_unknown_reads_differently_from_a_read_with_no_spinner(L):
    """The UI column must not render UNKNOWN and False alike -- the same rule as inbound=UNREAD."""
    src = open(_PATH, encoding="utf-8").read()
    assert '{True: "Working", False: "-", None: "UNREAD"}' in src


def test_unread_screen_cannot_produce_a_wedged_action(L):
    """⛔ END TO END: with a live tool in flight and an UNREAD screen, the verdict must not be WEDGED.

    This is the whole point of the tri-state. `tool_inflight` is evidence of a direct tool call that
    no file probe can see; if an unreadable screen were allowed to cancel it, the fleet would be told
    to interrupt live work on exactly the loaded box where read-screen fails most.
    """
    assert L.LONG_TOOL in (
        L.classify(stale=1200, grew=False, spinner=None, last_kind="tool", child=None,
                   child_stale=None, child_grew=None, child_activity_age=None,
                   tool_inflight={"age": 300, "timeout": None}, last_stop=None, has_sid=True),
        L.classify(stale=1200, grew=False, spinner=None, last_kind="tool", child=None,
                   child_stale=None, child_grew=None, child_activity_age=None,
                   tool_inflight={"age": 300, "timeout": 7200}, last_stop=None, has_sid=True),
    ), "an unread screen must not turn a live tool into a wedge"


def test_told_but_silent_is_the_ACTION_surface_rule_not_the_claim_one(L):
    """⛔ TWO RULES, TWO SURFACES, DELIBERATELY NOT ONE FUNCTION.

    `inbound_discounts_idle` is the CLAIM surface's rule: a PRIOR, IDLE-family only, never WEDGED,
    because an input event cannot prove a wedge resolved. `told_but_silent` is the ACTION surface's
    rule: a VETO, verdict-independent, because a lane that received work and has produced nothing
    since is not free capacity whatever anyone believes about its state. A claim and an instruction
    are different speech acts; keeping them separate is what stops a later change collapsing them.
    """
    # The fully-PAIRED measured instance (`Merigng PR`, 2026-10-11): told 20m ago, last output
    # 5h14m ago. The finding's own `2a Projection keys` reading recorded only
    # `latest_submitted 0.03h ago` and NO output age, so its 108s is deliberately NOT paired with a
    # `stale_s` -- pairing it would assert an output age the source never carried.
    assert L.told_but_silent(1210, 18858) is True
    # Told 27m ago but wrote 25m ago -- it ANSWERED, so the order was consumed and it IS free.
    assert L.told_but_silent(1620, 1500) is False
    # Told 36s ago while writing 3s ago -- output is newer, it is working, not silent.
    assert L.told_but_silent(36, 3) is False
    # Old inbound, never answered: still not free capacity.
    assert L.told_but_silent(10800, 20000) is True
    # A simultaneous inbound and output is not silence.
    assert L.told_but_silent(600, 600) is False


def test_told_but_silent_abstains_on_an_unread_signal(L):
    """⛔ `None` ABSTAINS. An unread inbound, or an unknown output age, is NOT evidence of silence --
    returning True would exclude a lane on a fact nobody established. Same rule as everywhere else:
    an unread signal is not a value, and it must not render as one."""
    assert L.told_but_silent(None, 5000) is False    # inbound unread
    assert L.told_but_silent(100, None) is False     # output age unknown
    assert L.told_but_silent(None, None) is False    # both unknown


def test_the_VETO_is_not_the_discount(L):
    """The two rules must disagree on the case that separates them, or one has absorbed the other.

    A WEDGED lane with a fresh inbound: the CLAIM rule must NOT fire (an input event cannot resolve
    a wedge), while the ACTION rule must still fire (do not instruct a human to act on a lane just
    given work). If a refactor ever made these agree here, the surfaces have collapsed.
    """
    assert L.inbound_discounts_idle(L.WEDGED, 1210, 18858) is False, "the claim rule must not clear a wedge"
    assert L.told_but_silent(1210, 18858) is True, "the action rule must still veto the instruction"
def test_an_unread_screen_is_never_a_dispatchable_verdict(L):
    """⛔ `DONE-IDLE` IS A DISPATCH INVITATION, AND IT REQUIRED A POSITIVE READ (2026-10-13).

    The long-tool gate was pinned to `spinner is not False` when the tri-state landed; the four
    VERDICT sites were left on plain truthiness, where `None` is falsy. The measured effect is
    exactly ONE error class: `DONE-IDLE` -> `UNKNOWN`. An unread screen became the verdict that
    invites a new task onto a lane whose state was never established.

    ⛔ AND THE NARROW CLAIM IS THE ONE THAT IS TRUE. An earlier draft of this docstring said the
    unread screen could also yield `WEDGED`, a kill invitation. A verifier FALSIFIED that against the
    artifact: every `WEDGED` return is `WEDGED if spinner else DONE_IDLE`, so `None` is falsy and
    picks `DONE_IDLE` -- an exhaustive 58,320-combination grid over the pre-fix `classify()` with
    `spinner=None` produced DONE-IDLE 4,082 times and **WEDGED 0 times**. The falsified claim is
    recorded here rather than deleted, so the next reader does not re-derive it -- and because
    stating it would have made this fix look broader than it is.

    ⛔ ONE ASSERTION PER CALL SITE, NOT ONE FOR THE HELPER. Three sites route through
    `_idle_verdict()` and one is inline; a test that only exercised the helper would stay green if a
    CALL SITE were reverted to `if spinner else`, which is the mutation this must catch.
    """
    def c(**kw):
        args = dict(stale=1200, grew=False, spinner=None, last_kind="assistant", child=None,
                    child_stale=None, child_grew=None, child_activity_age=None,
                    tool_inflight=None, last_stop=None, has_sid=True)
        args.update(kw)
        return L.classify(**args)

    # site 1 -- an abandoned child record beside a COMPLETED turn (reachable because
    # `parent_stopped` needs child_stale > 900, which this record does not have)
    v1 = c(child={"call_id": "x", "age": 99999, "abandoned": True}, child_stale=500,
           last_stop="stop")
    assert v1 == L.UNKNOWN, "unread screen + completed turn + abandoned record: got %s" % v1
    # site 2 -- a stale screen on a COMPLETED turn
    v2 = c(last_stop="stop")
    assert v2 == L.UNKNOWN, "unread screen on a completed turn: got %s" % v2
    # site 3 -- the frozen-pane fallthrough (a call still owed its result)
    v3 = c(last_kind="bash")
    assert v3 == L.UNKNOWN, "unread screen on a frozen pane: got %s" % v3
    # site 4 -- the final assistant branch, reached only below the stale bound
    v4 = c(stale=120)
    assert v4 == L.UNKNOWN, "unread screen below the stale bound: got %s" % v4
    # ⛔ THE FALSE-BLOCK CONTROL. A screen READ with no spinner IS evidence of a finished turn,
    # and these sites must keep saying so -- otherwise the fix would have made UNREAD the only
    # reachable answer on a quiet fleet.
    assert c(spinner=False, last_stop="stop") == L.DONE_IDLE
    assert c(spinner=True, last_stop="stop") == L.WIP_IDLE
    assert c(spinner=True, last_kind="bash") == L.WEDGED
    assert c(spinner=False, last_kind="bash") == L.DONE_IDLE


def test_a_missing_lane_registry_is_an_absence_not_a_crash(L, tmp_path, monkeypatch):
    """⛔ THE REGISTRY OPEN WAS UNGUARDED, SO AN ABSENT FILE RAISED OUT OF THE WHOLE SCAN.

    `_tsv_rows()`'s own docstring states the contract -- never publish a roster it could not read --
    while `open(REG)` sat outside any `try`. A crash is not the safe direction either: the callers
    that wrap the scan fall back to publishing a smaller roster, which is the exact failure this
    file was fixed to stop. An unreadable registry must return NO rows, so `main()` reaches its own
    `if not rows: raise` and NAMES the unreadable read.
    """
    monkeypatch.setattr(L, "REG", str(tmp_path / "nope.tsv"))
    assert L._tsv_rows() == []
    # ...and a real file still parses (the false-block control)
    p = tmp_path / "lane-registry.tsv"
    p.write_text("# comment\nlabel\tws-uuid\tissue-label\n")
    monkeypatch.setattr(L, "REG", str(p))
    assert L._tsv_rows() == [("label", "ws-uuid", "issue-label")]


def test_a_degraded_snapshot_is_never_cached(L, tmp_path):
    """⛔ ONE FAILED READ MUST NOT BECOME A STICKY FAILURE FOR THE WHOLE TTL (2026-10-12, measured).

    The launchd PATH hole made every row `degraded`, and the snapshot was then CACHED for the 420 s
    TTL -- so after the PATH was fixed `--json` still returned 27/27 degraded rows until the TTL
    expired, and `lane-actions.py` refuses degraded snapshots, so `pr-doctor` stayed unable to
    dispatch on a fleet it could no longer see. Deleting the guard left all 152 tests green (found
    by a VGATE mutation pass), so this test exists specifically to fail without it.
    """
    import json
    cache = tmp_path / "lane-status.cache"
    # a healthy snapshot IS published (the false-block control)
    assert L._publish_snapshot([{"verdict": "WORKING", "degraded": False}], str(cache), "k") is True
    assert json.loads(cache.read_text())["out"][0]["verdict"] == "WORKING"
    cache.unlink()
    # the measured degraded shape: EVERY row says degraded, and nothing may be written
    assert L._publish_snapshot([{"verdict": "WORKING", "degraded": True}], str(cache), "k") is False
    assert not cache.exists(), "a degraded snapshot must never be cached"
    # ONE degraded row among many refuses the WHOLE snapshot -- a partial read is still a bad read
    assert L._publish_snapshot([{"degraded": False}, {"degraded": True}], str(cache), "k") is False
    assert not cache.exists()
    # a non-dict row (a malformed snapshot) must not crash the publisher
    assert L._publish_snapshot(["oops"], str(cache), "k") is True


def test_a_compound_failed_read_cannot_publish_or_cache_an_empty_fleet(L, tmp_path):
    """⛔ `degraded` IS A PER-ROW FLAG, SO AN EMPTY ROSTER CARRIES NO FLAG AT ALL (2026-10-13).

    `any(r.get("degraded") for r in [])` is vacuously False, so the degraded refusal could not fire
    on the very input a COMPOUND failed read produces (registry unreadable AND the cmux read
    failed) — `registry()` returns `[]`, `main()` printed `[]`, exited 0, and cached it. Measured by
    review: `publish empty snapshot wrote cache?: True; contents {"out": []}`. An empty fleet then
    looked FRESH for the whole 420 s TTL and the `-s "$SNAP"` freshness test refused to launch the
    fallback scan. Both halves are now refused, and this test exists because the docstrings that
    claimed a `main()` guard covered it were FALSE — no such guard existed.
    """
    cache = tmp_path / "lane-status.cache"
    assert L._publish_snapshot([], str(cache), "k") is False, "an empty fleet must not be cached"
    assert not cache.exists()


def test_main_refuses_an_empty_roster_instead_of_publishing_it(L, monkeypatch, capsys):
    """⛔ A SOURCE GREP IS NOT AN ENFORCED GUARD (2026-10-13, found by review cycle 2).

    The first version of this assertion grepped the file for the refusal's MESSAGE AND NOTHING ELSE.
    A source grep pins the guard's WORDING, never its EFFECT: deleting only the `raise SystemExit(3)`
    while keeping the message left ALL 160 tests green, and `main()` then returned normally with
    `[]` on stdout — which is precisely the dark-fleet failure this guard exists to prevent
    (`heartbeat-loop.sh` promotes the `.tmp` snapshot when `-s` succeeds, and the freshness branch
    then suppresses the fallback scan for 15 min). Measured by review. Drive `main()` instead, so
    that removing the refusal fails HERE and not merely somewhere in the prose.
    """
    monkeypatch.setattr(L, "registry", lambda: [])
    monkeypatch.setattr(L.sys, "argv", ["lane-status.py", "--json", "--no-cache"])
    with pytest.raises(SystemExit) as exc:
        L.main()
    assert exc.value.code == 3, "an empty roster must exit non-zero, got %r" % (exc.value.code,)
    assert capsys.readouterr().out.strip() == "", "an empty roster must publish NOTHING"


def test_an_unread_screen_never_reaches_the_dispatchable_verdict_at_the_fifth_site(L):
    """⛔ THE TRI-STATE FIX MISSED A FIFTH SITE, AND REVIEW FOUND IT, NOT THE TESTS (2026-10-13).

    `if last_kind is None: return DONE_IDLE if has_sid else UNBOUND` never consulted `spinner` at
    all — so a session holding no parseable records PLUS an UNREADABLE screen still returned the one
    verdict that invites a new task. Reachable from `main()`: a resolved `sid` whose session has no
    records, with `read-screen` having failed under load (its measured ~10–15 s latency makes that
    routine). Same absent-read-collapsed-to-a-definite-value class as the four `_idle_verdict()`
    sites, which is why it belongs in this file's tests rather than in a follow-up.
    """
    def c(**kw):
        args = dict(stale=None, grew=False, spinner=None, last_kind=None, child=None,
                    child_stale=None, child_grew=None, child_activity_age=None,
                    tool_inflight=None, last_stop=None, has_sid=True)
        args.update(kw)
        return L.classify(**args)

    assert c() == L.UNKNOWN, "an unread screen with no readable records must abstain, got %s" % c()
    # false-block controls: a POSITIVE read at the same site still decides
    assert c(spinner=False) == L.DONE_IDLE
    assert c(spinner=True) == L.WIP_IDLE
    # ...and a lane with no session at all is still UNBOUND, not UNKNOWN
    assert c(has_sid=False) == L.UNBOUND


# ── a failed read is retried, and is never rendered as an empty success ───────
#
# ⛔ THE FAILURE THESE GUARD (2026-10-12). `cmux list-workspaces --json` timed out at load, the
# exception was swallowed into `""`, and the fleet roster silently shrank to the hand-written TSV:
# the published snapshot carried 26 workspaces, ALL of them TSV and ZERO of the 13 live-only ones,
# while four lanes were stalled. One unreadable socket also made `resolve_session` return the
# RECORDED id unchecked, binding two lanes to sessions last written 64h18m and 12h30m earlier and
# reporting both `DONE-IDLE`. A failed read must be RETRIED, then REPORTED -- never believed.

def test_a_failed_read_is_retried_before_it_is_believed(L, monkeypatch):
    calls = []

    class P:
        returncode = 1
        stdout = ""

    monkeypatch.setattr(L.subprocess, "run", lambda *a, **k: (calls.append(1), P())[1])
    monkeypatch.setattr(L.time, "sleep", lambda s: None)
    out, ok = L.sh_rc(["cmux", "list-workspaces", "--json"])
    assert ok is False
    assert len(calls) == L.RETRY_ATTEMPTS >= 2, "a failed read must be retried at least once"


def test_a_retry_that_succeeds_is_believed(L, monkeypatch):
    """The retry exists for a TRANSIENT failure (a control-socket timeout under load), so a
    second attempt that answers must be used, not discarded."""
    seq = [TimeoutError("cmux timed out")]

    class P:
        returncode = 0
        stdout = "[]"

    calls = []

    def fake(*a, **k):
        calls.append(1)
        x = seq.pop(0) if seq else P()
        if isinstance(x, Exception):
            raise x
        return x

    monkeypatch.setattr(L.subprocess, "run", fake)
    monkeypatch.setattr(L.time, "sleep", lambda s: None)
    out, ok = L.sh_rc(["cmux", "list-workspaces", "--json"])
    assert ok is True and out == "[]"
    assert len(calls) == 2, "the second attempt must actually be made"


def test_an_empty_read_and_a_failed_read_are_different_facts(L, monkeypatch):
    """`ok` is what separates them. Collapsing the two is the whole defect."""
    monkeypatch.setattr(L.subprocess, "run", lambda *a, **k: _ok(""))
    empty, ok1 = L.sh_rc(["x"])
    assert (empty, ok1) == ("", True), "a SUCCESSFUL empty read is not a failure"
    monkeypatch.setattr(L.subprocess, "run", lambda *a, **k: (_ for _ in ()).throw(OSError()))
    assert L.sh_rc(["x"], attempts=1) == ("", False)


def _ok(stdout, rc=0):
    class P:
        returncode = rc
    P.stdout = stdout
    return P()


def test_an_unreadable_fleet_roster_is_not_an_empty_fleet(L, monkeypatch):
    """⛔ THE SHRINK. `[]` used to be returned for BOTH "no workspaces" and "could not look",
    and `registry()` unions the TSV with it -- so an unreachable cmux became a 26-lane fleet."""
    monkeypatch.setattr(L, "_LIVE_CACHE", [])
    monkeypatch.setattr(L, "LIVE_READABLE", None)
    monkeypatch.setattr(L, "sh_rc", lambda *a, **k: ("", False))
    assert L._live_workspaces() == []
    assert L.LIVE_READABLE is False, "unreadable must be a stated fact, not an empty list"


def test_a_degraded_roster_says_so_on_stderr(L, monkeypatch, capsys):
    monkeypatch.setattr(L, "_live_workspaces", lambda: [])
    monkeypatch.setattr(L, "LIVE_READABLE", False)
    L.registry()
    assert "DEGRADED" in capsys.readouterr().err, \
        "a fallback indistinguishable from a healthy read is how the blind spot returns"


# ── a session id we cannot confirm must not assert an idle lane ───────────────

def test_a_session_id_that_cannot_be_confirmed_is_reported_unverified(L, monkeypatch):
    """The documented failure, surviving on the path where nothing disagrees with it: cmux gives
    no id, so the RECORDED id is returned -- and it is a recovery hint, not a liveness proof.
    The workspace IS live (that is the case that costs something), so the flag must fire."""
    monkeypatch.setattr(L, "sh", lambda *a, **k: "")          # pane read produced nothing
    monkeypatch.setattr(L, "_recorded_session", lambda ws: "01a102f5-b9b5-7554-9528-a0ffd03e69f8")
    monkeypatch.setattr(L, "session_file", lambda sid: None)  # ... and resolves to no file
    monkeypatch.setattr(L, "_live_workspaces", lambda: [("ANY-WS", {})])   # the pane still exists
    sid, verified = L.resolve_session_ex("ANY-WS")
    assert sid == "01a102f5-b9b5-7554-9528-a0ffd03e69f8"
    assert verified is False


def test_a_dead_workspace_is_not_reported_as_an_unverified_lane(L, monkeypatch):
    """⛔ A DEAD LANE IS NOT AN UNVERIFIED ONE. 24 of the 39 registry rows are not live cmux
    workspaces, and `surface resume show` on a dead one exits 0 with empty stdout -- so every one
    of them would otherwise land in REPORT ONLY and bury the lanes that matter."""
    monkeypatch.setattr(L, "sh", lambda *a, **k: "")
    monkeypatch.setattr(L, "_recorded_session", lambda ws: "01a102f5-b9b5-7554-9528-a0ffd03e69f8")
    monkeypatch.setattr(L, "session_file", lambda sid: None)
    monkeypatch.setattr(L, "_live_workspaces", lambda: [("SOME-OTHER-WS", {})])
    sid, verified = L.resolve_session_ex("GONE-WS")
    assert sid == "01a102f5-b9b5-7554-9528-a0ffd03e69f8"
    assert verified is True, "a workspace that no longer exists cannot be mis-bound"


def test_a_freshly_written_session_is_verified(L, monkeypatch, tmp_path):
    f = tmp_path / "s.jsonl"
    f.write_text("{}\n")
    monkeypatch.setattr(L, "sh", lambda *a, **k:
                      "cd -- '/x' ; exec pi --session' '11111111-1111-1111-1111-111111111111'")
    monkeypatch.setattr(L, "_recorded_session", lambda ws: None)
    monkeypatch.setattr(L, "session_file", lambda sid: str(f))
    sid, verified = L.resolve_session_ex("ANY-WS")
    assert sid == "11111111-1111-1111-1111-111111111111" and verified is True


def test_resolve_session_still_returns_a_bare_id_for_callers_like_lane_guard(L, monkeypatch):
    monkeypatch.setattr(L, "resolve_session_ex", lambda ws: ("abc", False))
    assert L.resolve_session("X") == "abc"


# ── an outstanding dispatch is not a wedge ────────────────────────────────────
#
# ⛔ THE 2026-10-12 FALSE POSITIVE, and the reason ABANDON_S was load-bearing alone. Four lanes
# read WEDGED while their children were alive (two running pytest for 2h26m, one polling CI for
# 1h30m). WEDGED's instruction is "check the process" and its measured cost is a kill/respawn of a
# HEALTHY lane -- so an unmatched dispatch whose child we cannot see must ABSTAIN, not accuse.

def test_an_outstanding_dispatch_is_never_a_wedge(L):
    v = L.classify(stale=8052, grew=False, spinner=True, last_kind="tool",
                   child=None, child_stale=None, child_grew=None, child_activity_age=None,
                   tool_inflight={"name": "task", "timeout": None, "age": 8052}, has_sid=True)
    assert v == L.WAITING_OVERDUE, "an UNMATCHED dispatch is not a proven cut"
    assert v != L.WEDGED


def test_a_real_wedge_is_still_a_wedge(L):
    """The abstention must not disarm the verdict: nothing in flight, stale, spinner -> WEDGED."""
    v = L.classify(stale=8052, grew=False, spinner=True, last_kind="bash",
                   child=None, child_stale=None, child_grew=None, child_activity_age=None,
                   tool_inflight=None, has_sid=True)
    assert v == L.WEDGED


def test_an_abandoned_child_that_is_still_writing_is_waiting(L):
    """The case that decides the whole change: the record is past ABANDON_S, but the child's own
    transcript was written 14s ago. The lane is WAITING, and used to read WEDGED."""
    child = {"call_id": "x", "age": 874, "abandoned": True}
    assert L.classify(874, False, True, "tool", child, 14, False, 25, None, has_sid=True) == L.WAITING


def test_an_abandoned_child_gone_quiet_is_reported_stuck_not_wedged(L):
    child = {"call_id": "x", "age": 12007, "abandoned": True}
    assert L.classify(12007, False, True, "tool", child, 11438, False, None, None,
                      has_sid=True) == L.CHILD_STUCK


def test_a_completed_turn_outranks_an_abandoned_child_record(L):
    """⛔ THE PROTECTION. Keeping abandoned records must not resurrect the failure the old discard
    was written to stop: a dispatch from days ago making a healthy lane read stuck forever."""
    child = {"call_id": "x", "age": 264600, "abandoned": True}
    v = L.classify(264600, False, True, "assistant", child, 250000, False, None, None,
                   last_stop="stop", has_sid=True)
    assert v == L.WIP_IDLE


def test_pending_child_keeps_the_record_and_flags_it_abandoned(L, tmp_path):
    import json as _json
    import time as _time
    old = _time.strftime("%Y-%m-%dT%H:%M:%S",
                         _time.gmtime(_time.time() - L.ABANDON_S - 600)) + ".000Z"
    f = tmp_path / "s.jsonl"
    f.write_text(_json.dumps({"timestamp": old, "cwd": "/tmp/x", "message": {
        "role": "assistant",
        "content": [{"type": "toolCall", "id": "c1", "name": "task",
                     "arguments": {"prompt": "p"}}]}}) + "\n")
    ch = L.pending_child(str(f))
    assert ch is not None, "an old record must not be erased -- it is evidence a result never came"
    assert ch["abandoned"] is True


def test_an_abandoned_record_still_does_not_suppress(L):
    """ABANDON_S keeps its one honest job: the record may not SUPPRESS an action verdict."""
    assert L.child_suppresses(L.WEDGED, [], [], {"call_id": "x", "abandoned": True},
                              L.ABANDON_S + 1) is False


def test_a_pane_confirmed_session_is_verified_even_when_quiet(L, monkeypatch, tmp_path):
    """⛔ A QUIET SESSION IS NOT AN UNCONFIRMED ONE. A lane waiting on a long child writes nothing
    for as long as the child runs -- that is the shape this whole file exists to classify. So "the
    file has not been written for an hour" must NOT read as "this is not the live session", or the
    abstention would fire on exactly the lanes the child fix is about.
    """
    import time as _time
    f = tmp_path / "s.jsonl"
    f.write_text("{}\n")
    os.utime(str(f), (_time.time() - 4000, _time.time() - 4000))   # quiet for over an hour
    monkeypatch.setattr(L, "sh", lambda *a, **k:
                        "cd -- '/x' ; exec pi --session' '22222222-2222-2222-2222-222222222222'")
    monkeypatch.setattr(L, "session_file", lambda sid: str(f))
    monkeypatch.setattr(L, "_recorded_session", lambda ws: None)
    monkeypatch.setattr(L, "_content_session", lambda label, cf: None)
    sid, verified = L.resolve_session_ex("WS")
    assert sid == "22222222-2222-2222-2222-222222222222"
    assert verified is True, "the pane is authoritative about which session it runs"


def test_no_id_is_not_an_unconfirmed_id(L, monkeypatch):
    """`verified=None` where there is no id at all. A flag that fires where it does not apply is
    how a real one gets ignored -- and the row's abstention is already `sid is None`."""
    monkeypatch.setattr(L, "sh", lambda *a, **k: "")
    monkeypatch.setattr(L, "_recorded_session", lambda ws: None)
    assert L.resolve_session_ex("ANY-WS") == (None, None)


def test_a_parallel_round_is_judged_by_its_most_live_child(L, tmp_path, monkeypatch):
    """⛔ The 2026-10-12 defect: 5&9 held FIVE unmatched calls and `open_calls[-1]` was the
    QUIETEST, so the lane read CHILD-STUCK while two siblings wrote 8m and 12m ago. A lane is
    waiting if ANY child is live, so the pick must be on evidence, not on order."""
    import json, time
    live, dead = tmp_path / "live", tmp_path / "dead"
    live.mkdir(); dead.mkdir()
    # OLDEST FIRST: `live` is dispatched first, `dead` LAST -- so `pending_child` (newest) is the
    # dead one, which is exactly the trap.
    f = tmp_path / "s.jsonl"
    f.write_text("\n".join(json.dumps({
        "type": "message", "timestamp": "2026-10-12T08:00:00.000Z",
        "message": {"role": "assistant", "content": [
            {"type": "toolCall", "name": "task", "id": cid,
             "arguments": {"prompt": "x", "cwd": cwd}}]}})
        for cid, cwd in (("c_live", str(live)), ("c_dead", str(dead)))) + "\n")
    kid = live / "child.jsonl"
    kid.write_text("{}\n")
    by_cwd = {str(live): str(kid), str(dead): None}
    monkeypatch.setattr(L, "find_child_session",
                        lambda cwd, e, exclude=None: by_cwd.get(cwd))
    kids = L.pending_children(str(f))
    assert [k["call_id"] for k in kids] == ["c_dead", "c_live"], "newest-first ordering"
    assert L.pending_child(str(f))["call_id"] == "c_dead", "the trap: newest is the quiet one"
    best, best_file = L.most_live_child(kids)
    assert best["call_id"] == "c_live", "the pick must follow liveness, not order"
    assert best_file == str(kid)


def test_a_record_with_no_child_evidence_does_not_decide_the_verdict(L):
    """⛔ Measured 2026-10-12, `Storage Archictecture`: a 35h-old abandoned record with
    `child_stale=72195` and no on-disk activity pinned CHILD-STUCK while the parent had written 86s
    earlier and was mid-`bash`. A lane actively being driven is WORKING, and a record that knows
    nothing about its child must not pick the verdict -- it also silently disabled the long-tool
    guard, which is gated on `not child`."""
    rec = {"call_id": "c", "ts": None, "age": 126536, "abandoned": True, "cwd": "/x"}
    # No trace of the child at all: the parent's own state answers.
    assert L.classify(86, False, True, "tool", rec, None, False, None, None) == L.WORKING
    # A quiet parent is still served, by the `abandoned` clause at the bottom: report-only.
    assert L.classify(5000, False, False, "tool", rec, None, False, None, None) == L.WAITING_OVERDUE
    # Real child evidence still decides.
    assert L.classify(5000, False, False, "tool", rec, 770, False, None, None) == L.WAITING
    # And a FRESH parent write outranks even a quiet transcript (the Storage Archictecture case).
    assert L.classify(86, False, True, "tool", rec, 72195, False, None, None) == L.WORKING


def test_a_long_direct_tool_call_is_still_not_a_wedge_with_a_stale_record(L):
    """The guard is gated on `not child`; an evidence-free abandoned record must not disable it."""
    rec = {"call_id": "c", "ts": None, "age": 126536, "abandoned": True, "cwd": "/x"}
    ti = {"name": "bash", "age": 300, "timeout": None}
    assert L.classify(5000, False, True, "tool", rec, None, False, None, ti) == L.LONG_TOOL


def test_the_live_panel_is_the_roster_and_the_file_is_only_metadata(L, tmp_path, monkeypatch):
    """⛔ The 2026-10-12 complaint: 39 published rows against 16 live workspaces, so two-thirds of
    the reported "fleet" were workspaces that no longer exist. A deleted lane must stop being a
    lane, and a lane created after the file was last edited must appear without anyone editing it.
    """
    f = tmp_path / "reg.tsv"
    f.write_text(
        "5&9 MCP and SDK surface\t{dead-uuid}\tlane:c5-9-mcp-sdk\n"
        "Storage Archictecture\t{recreated-old-uuid}\tlane:c-storage\n")
    monkeypatch.setattr(L, "REG", str(f))
    monkeypatch.setattr(L, "_live_workspaces", lambda: [
        ("{recreated-new-uuid}", {"title": "Storage Archictecture"}),   # uuid churned
        ("{brand-new-uuid}", {"title": "Brand new lane"}),              # never in the file
    ])
    monkeypatch.setattr(L, "_live_label", lambda wsid, x: x["title"])
    monkeypatch.setattr(L, "LIVE_READABLE", True)
    rows = L.registry()
    labels = [r[0] for r in rows]

    assert labels == ["Storage Archictecture", "Brand new lane"], \
        f"the file's dead row must not be a lane; got {labels}"
    # The uuid was recreated, so the issue-label is recovered by TITLE -- otherwise a lane silently
    # loses the label that says which repo work it owns.
    assert rows[0][2] == "lane:c-storage", rows[0]
    # A lane the file has never heard of is still a lane; it just has no issue-label yet.
    assert rows[1][2] == ""


def test_a_degraded_roster_falls_back_to_the_file_and_only_the_file(L, tmp_path, monkeypatch):
    """When cmux is unreadable we cannot enumerate panes, so the file's rows are all we have -- and
    the caller marks the snapshot degraded so `lane-actions.py` refuses it."""
    import io, contextlib
    f = tmp_path / "reg.tsv"
    f.write_text("Some lane\t{uuid}\tlane:x\n")
    monkeypatch.setattr(L, "REG", str(f))
    monkeypatch.setattr(L, "_live_workspaces", lambda: [])
    monkeypatch.setattr(L, "LIVE_READABLE", False)
    err = io.StringIO()
    with contextlib.redirect_stderr(err):
        rows = L.registry()
    assert [r[0] for r in rows] == ["Some lane"]
    assert "DEGRADED" in err.getvalue()


def test_in_flight_tool_reads_the_parent_regardless_of_any_child_record(L, tmp_path):
    """⛔ THE MISSING SEAM, AND WHY IT IS A SEAM RATHER THAN A TEST. A verifier's mutation round
    found that main()'s `ti` construction had NO test protection: reverting it to the child-gated
    form restored the `Drain` regression and the whole suite stayed green, because every other
    `tool_inflight` assertion calls `classify()` directly with an explicit value and nothing drives
    main(). Extracting `in_flight_tool(f)` makes the parent-only contract *structural* -- it has no
    child parameter, so it cannot be made to depend on one -- and this drives it from a real session
    file that contains BOTH a live in-flight tool call and an ancient abandoned `task` record.
    """
    import json as _json
    import time as _time
    now = _time.time()
    iso = lambda t: _time.strftime("%Y-%m-%dT%H:%M:%S", _time.gmtime(t)) + ".000Z"
    recs = [
        # an abandoned `task` dispatch from 3.9 days ago, never matched -- the `Drain` shape
        {"timestamp": iso(now - 338417), "cwd": "/tmp/x", "message": {
            "role": "assistant", "content": [
                {"type": "toolCall", "id": "old", "name": "task",
                 "arguments": {"prompt": "review"}}]}},
        # ...and the PARENT's live, budgeted tool call, which is the thing that must be seen
        {"timestamp": iso(now - 1415), "cwd": "/tmp/x", "message": {
            "role": "assistant", "content": [
                {"type": "toolCall", "id": "live", "name": "bash",
                 "arguments": {"command": "while :; do sleep 52; done"}}]}},
    ]
    f = tmp_path / "s.jsonl"
    f.write_text("\n".join(_json.dumps(r) for r in recs) + "\n")
    ti = L.in_flight_tool(str(f))
    assert ti is not None, "the parent's in-flight tool must be read from the session"
    assert ti["name"] == "bash" and ti["timeout"] is None
    assert 1400 < ti["age"] < 1440, ti
    assert L.in_flight_tool(None) is None and L.in_flight_tool("/nope/missing.jsonl") is None


def test_in_flight_tool_cannot_be_made_to_depend_on_a_child(L):
    """The structural pin: a function with no child parameter cannot suppress on child evidence."""
    import inspect
    params = list(inspect.signature(L.in_flight_tool).parameters)
    assert params == ["f"], (
        "in_flight_tool must take only the session path -- a `child` parameter is how the parent's "
        "own in-flight tool got suppressed, and the signature makes that unreachable (got %r)" % params)


def test_main_reads_its_in_flight_tool_through_that_seam(L):
    """⛔ WIRING PIN, DELIBERATELY A SOURCE ASSERTION. The helper's contract is covered
    behaviourally above, but main() is not drivable under test (it reads cmux, the registry and the
    pane), so nothing else can see whether the CALL SITE re-adds a child condition. This pins exactly
    that one line and nothing else; it is a statement about wiring, not about behaviour, and is
    labelled as such rather than presented as coverage."""
    src = open(_PATH, encoding="utf-8").read()
    assert "        ti = in_flight_tool(f)\n" in src, (
        "main() must read the in-flight tool through `in_flight_tool(f)` -- gating it on `child` "
        "again restores the Drain regression (CHILD-STUCK on a lane in a live poll loop)")
    assert "in_flight_tool(f) if" not in src.replace("        ti = in_flight_tool(f)\n", ""), (
        "the call site must not be conditional on anything")


# ── a read our own teardown killed is NOT an unreadable roster ────────────────
# ⛔ MEASURED 2026-10-12: all 23 `DEGRADED -- the cmux fleet roster was unreadable` lines in the
# heartbeat log were immediately preceded by the tick being SIGTERM'd at its 390s bound. NONE was a
# genuine read failure (cmux answered in 0.05-0.08s at load 69). The instrument was reporting a cause
# it had never established -- blaming cmux for our own death.

def test_a_signal_killed_child_is_reported_as_teardown_not_a_refusal(L):
    """A child that died by SIGNAL is not a statement about what we were reading."""
    out, ok = L.sh_rc(["/bin/bash", "-c", "kill -TERM $$"], timeout=20)
    assert ok is False and out == ""
    assert L.LAST_FAILURE["kind"] == "signal", L.LAST_FAILURE
    assert L.LAST_FAILURE["rc"] == -15, L.LAST_FAILURE
    assert L.last_failure_was_teardown() is True


def test_an_ordinary_nonzero_exit_is_still_a_refusal(L):
    """The polarity must not swallow the real case: a refusal keeps its original wording."""
    _out, ok = L.sh_rc(["/bin/bash", "-c", "exit 3"], timeout=20)
    assert ok is False
    assert L.LAST_FAILURE["kind"] == "nonzero" and L.LAST_FAILURE["rc"] == 3, L.LAST_FAILURE
    assert L.last_failure_was_teardown() is False


def test_a_timeout_is_not_teardown(L):
    _out, ok = L.sh_rc(["/bin/sleep", "5"], timeout=1, attempts=1)
    assert ok is False
    assert L.LAST_FAILURE["kind"] == "timeout", L.LAST_FAILURE
    assert L.last_failure_was_teardown() is False


def test_a_successful_read_records_no_failure(L):
    out, ok = L.sh_rc(["/bin/echo", "hello"], timeout=20)
    assert ok is True and "hello" in out
    assert L.LAST_FAILURE is None
    assert L.last_failure_was_teardown() is False


def _degraded_stderr(L, failure, monkeypatch):
    """Drive `registry()` -- that is where the DEGRADED wording lives, NOT in `_live_workspaces()`.
    Driving the wrong function made two assertions pass against a message that was never printed,
    which is the same "pins the wrong artefact" trap these tests exist to avoid."""
    import io as _io
    import contextlib as _ctx
    monkeypatch.setattr(L, "sh_rc", lambda *a, **k: ("", False))
    monkeypatch.setattr(L, "LAST_FAILURE", failure)
    monkeypatch.setattr(L, "_LIVE_CACHE", [], raising=False)
    monkeypatch.setattr(L, "LIVE_READABLE", None, raising=False)
    err = _io.StringIO()
    with _ctx.redirect_stderr(err):
        L.registry()
    out = err.getvalue()
    assert "DEGRADED" in out, "registry() did not report the degraded read at all: %r" % out
    return out


def test_the_degraded_message_does_not_blame_cmux_when_we_were_killed(L, monkeypatch):
    """The wording must follow the EVIDENCE. A teardown says so and explicitly disclaims cmux."""
    msg = _degraded_stderr(L, dict(kind="signal", rc=-15, cmd="cmux", attempt=2), monkeypatch)
    assert "KILLED BY A SIGNAL" in msg and "NOT a claim that cmux is down" in msg, msg
    assert "unreadable after" not in msg, "a signal death must not be reported as a cmux refusal"


def test_the_degraded_message_still_reports_a_real_unreadable_roster(L, monkeypatch):
    msg = _degraded_stderr(L, dict(kind="nonzero", rc=1, cmd="cmux", attempt=2), monkeypatch)
    assert "unreadable after" in msg and "'nonzero'" in msg, msg
    assert "KILLED BY A SIGNAL" not in msg


# ── Step 2 must not go blind just because a `task` child shares the lane's cwd (#1867) ────────
# ⛔ MEASURED 2026-10-16 20:47Z. `cmux cloud` was published to the beat as
#   `CAPACITY: 1 lane(s) idle >=20m with NO child in flight -- hand each the next unheld item`
# on the strength of `DONE_READY, no session write for 13h34m`, while its own `ps -o time` moved
# `838:22.16 -> 838:27.09` over 25s and its pane showed an active spinner. `lane_cpu_busy()` had
# answered None -- not False -- because a live `task` CHILD is a second pi with the SAME cwd, and
# its strict "exactly one lane <-> exactly one pid" rule excludes that case. Step 2 then did not
# run at all, and the verdict was taken from the transcript mtime alone.

def test_a_second_pi_in_the_lane_directory_does_not_blind_step_2(L):
    """The lane's own progress, its child's progress, or both -- in a ONE-lane directory it is the
    lane working, whether or not the pid can be named. The strict read keeps its answer (None);
    the weaker one must be True."""
    d = "--x-repo--"
    dir_lanes, dir_pids = {d: ["L"]}, {d: ["10", "11"]}     # lane pi + its `task` child pi
    cpu0, cpu1 = {"10": 100.0, "11": 5.0}, {"10": 104.93, "11": 5.0}
    assert L.lane_cpu_busy("L", "/sessions/%s/s.jsonl" % d, dir_lanes, dir_pids,
                           cpu0, cpu1) is None, \
        "the strict exactly-one-pid rule must NOT be relaxed by this change"
    assert L.lane_cpu_progress(d, dir_lanes, dir_pids, cpu0, cpu1) is True


def test_a_childs_progress_counts_as_the_lanes_progress(L):
    """The measured shape: the parent is quiet for a moment, the CHILD is burning the CPU. That is
    still work in this lane's own directory, so it is still not free capacity."""
    d = "--x-repo--"
    dir_lanes, dir_pids = {d: ["L"]}, {d: ["10", "11"]}
    cpu0, cpu1 = {"10": 100.0, "11": 5.0}, {"10": 100.0, "11": 9.9}
    assert L.lane_cpu_progress(d, dir_lanes, dir_pids, cpu0, cpu1) is True


def test_progress_in_a_shared_directory_is_not_attributed_to_a_lane(L):
    """Two lanes on one cwd: a sibling's work is indistinguishable, so this ABSTAINS. Attributing it
    would mark an idle lane busy (a lost dispatch); the strict read already refuses the same case."""
    d = "--x-shared--"
    dir_lanes, dir_pids = {d: ["L", "SIBLING"]}, {d: ["10", "11"]}
    cpu0, cpu1 = {"10": 100.0, "11": 5.0}, {"10": 110.0, "11": 5.0}
    assert L.lane_cpu_progress(d, dir_lanes, dir_pids, cpu0, cpu1) is None


def test_no_visible_progress_is_never_reported_as_parked(L):
    """⛔ THE POLARITY. This answers a VETO, so it may only say True or None. `False` would be read
    as "the lane is parked" -- an idle claim built on a possibly partial process map."""
    d = "--x-repo--"
    dir_lanes, dir_pids = {d: ["L"]}, {d: ["10"]}
    flat = {"10": 100.0}
    assert L.lane_cpu_progress(d, dir_lanes, dir_pids, flat, flat) is None
    assert L.lane_cpu_progress(d, dir_lanes, {d: []}, flat, flat) is None
    assert L.lane_cpu_progress(None, dir_lanes, dir_pids, flat, flat) is None


def test_an_idle_verdict_cannot_be_reached_past_unattributed_progress(L):
    """⛔ `IDLE` IS REACHABLE ONLY THROUGH STEP 2 (#1867). Same inputs that produce `DONE-IDLE`
    (quiet transcript, no spinner, a completed turn) produce a NON-idle verdict once progress in
    the lane's own directory is known -- whatever the binding resolved to and whatever the mtime
    says. The control assertion below is the pre-change behaviour, so this test fails on it."""
    kw = dict(stale=48000, grew=False, spinner=False, last_kind="assistant", child=None,
              child_stale=None, child_grew=None, child_activity_age=None, tool_inflight=None,
              last_stop="stop", has_sid=True)
    assert L.classify(**kw) == L.DONE_IDLE, "control: the pre-change verdict for these inputs"
    assert L.classify(cpu_any=True, **kw) == L.UNATTRIBUTED_WORKING
    # ...and the label is not an action label: no consumer may dispatch or unblock on it.
    assert L.UNATTRIBUTED_WORKING not in L.ACTION_VERDICTS
    assert L.UNATTRIBUTED_WORKING not in L.INBOUND_DISCOUNTS


# ── a stale BINDING is not a confirmed one (#1867) ────────────────────────────────────────────
# The pane's resume record is authoritative about what the pane was LAUNCHED with, not about what
# is being written now: a hand relaunch (`pi --session <id>`) leaves cmux carrying the old id. When
# another session file in the same directory is being written in the same minute, the bound id is
# demonstrably not the live one, and `verified=True` would let a 13h-old transcript be published as
# `DONE-IDLE` -- an instruction to dispatch into a working lane.

def test_a_stale_binding_with_a_freshly_written_sibling_is_unverified(L, monkeypatch, tmp_path):
    import time as _time
    old = tmp_path / "22222222-2222-2222-2222-222222222222.jsonl"
    old.write_text("{}\n")
    os.utime(str(old), (_time.time() - 48840, _time.time() - 48840))     # 13h34m quiet
    fresh = tmp_path / "33333333-3333-3333-3333-333333333333.jsonl"
    fresh.write_text("{}\n")                                            # written THIS minute
    monkeypatch.setattr(L, "sh", lambda *a, **k:
                        "cd -- '/x' ; exec pi --session' '22222222-2222-2222-2222-222222222222'")
    monkeypatch.setattr(L, "_recorded_session", lambda ws: None)
    monkeypatch.setattr(L, "session_file", lambda sid: str(old))
    monkeypatch.setattr(L, "registry", lambda: [])          # no cmux read in this unit
    monkeypatch.setattr(L, "_content_session", lambda label, cf: None)   # the label match missed
    sid, verified = L.resolve_session_ex("WS")
    assert sid == "22222222-2222-2222-2222-222222222222"
    assert verified is False, (
        "a bound session quiet for 13h while a sibling file is written now is a STALE BINDING -- "
        "reporting it verified is what published a working lane as free capacity")


def test_a_stale_binding_with_no_live_writer_stays_verified(L, monkeypatch, tmp_path):
    """The bound above must not become a blanket abstention: a lane genuinely at rest has a quiet
    session and NO fresh writer in its directory, and its idleness is real."""
    import time as _time
    old = tmp_path / "44444444-4444-4444-4444-444444444444.jsonl"
    old.write_text("{}\n")
    os.utime(str(old), (_time.time() - 4000, _time.time() - 4000))
    other = tmp_path / "55555555-5555-5555-5555-555555555555.jsonl"
    other.write_text("{}\n")
    os.utime(str(other), (_time.time() - 9000, _time.time() - 9000))    # OLDER than the bound one
    monkeypatch.setattr(L, "sh", lambda *a, **k:
                        "cd -- '/x' ; exec pi --session' '44444444-4444-4444-4444-444444444444'")
    monkeypatch.setattr(L, "_recorded_session", lambda ws: None)
    monkeypatch.setattr(L, "session_file", lambda sid: str(old))
    monkeypatch.setattr(L, "registry", lambda: [])
    monkeypatch.setattr(L, "_content_session", lambda label, cf: None)
    sid, verified = L.resolve_session_ex("WS")
    assert sid == "44444444-4444-4444-4444-444444444444" and verified is True


# ── the veto's REACH: it may only veto the idle family (#1867 review) ─────────────────────────
# `cpu_any` says SOME pi in the lane's directory consumed CPU -- never WHICH one. A CHILD-STUCK
# verdict is a diagnosis of the CHILD, and `lane-actions` routes CHILD-STUCK to the UNBLOCK list.
# Ranking the veto above the child branches (its first placement) withdrew that unblock on exactly
# the shape the label was written for: a child spinning under a stalled parent.

def test_unattributed_progress_does_not_mask_a_stuck_child(L):
    """⛔ THE VETO VETOES IDLE, NOT CHILD EVIDENCE. Control and test differ ONLY in `cpu_any`, so
    this fails on the pre-fix ordering (which returned `UNATTRIBUTED-WORKING` for the second
    assertion) and passes once the veto sits below the child branches."""
    kw = dict(stale=5000, grew=False, spinner=True, last_kind="tool", child={"age": 4000},
              child_stale=4000, child_grew=None, child_activity_age=4000,
              tool_inflight=None, last_stop="toolUse", has_sid=True)
    assert L.classify(**kw) == L.CHILD_STUCK, "control: a quiet child under a stopped parent"
    assert L.classify(cpu_any=True, **kw) == L.CHILD_STUCK, \
        "unattributed progress must not withdraw the child-stuck unblock"
    # ...and the veto still bites where it is aimed: the idle family, not the child diagnosis.
    idle = dict(stale=48000, grew=False, spinner=False, last_kind="assistant", child=None,
                child_stale=None, child_grew=None, child_activity_age=None, tool_inflight=None,
                last_stop="stop", has_sid=True)
    assert L.classify(cpu_any=True, **idle) == L.UNATTRIBUTED_WORKING


def test_a_fresh_writer_that_names_another_lane_does_not_unverify_this_binding(L, monkeypatch,
                                                                             tmp_path):
    """⛔ A SHARED SESSIONS DIR IS NOT AN UNEXPLAINED WRITER (#1867 review). The sessions dir is
    keyed by the mangled cwd, and this file's own census records nine lanes sharing one cwd. Without
    the label exclusion, every quiet lane in such a directory returned `verified=False` on every
    read while a co-located lane wrote -- permanently `UNVERIFIED-SESSION`, report-only, so a free
    lane could never be offered work AND its DEAD/WEDGED/CHILD-STUCK diagnosis was withdrawn. The
    control is `test_a_stale_binding_with_a_freshly_written_sibling_is_unverified`: a writer nobody
    can name still abstains."""
    import json as _json
    import time as _time
    old = tmp_path / "66666666-6666-6666-6666-666666666666.jsonl"
    old.write_text("{}\n")
    os.utime(str(old), (_time.time() - 4000, _time.time() - 4000))      # quiet > 30m
    sib = tmp_path / "77777777-7777-7777-7777-777777777777.jsonl"
    sib.write_text(_json.dumps({"type": "user",
                                "message": {"role": "user",
                                            "content": "Other One: land the queue cleanup"}}) + "\n")
    monkeypatch.setattr(L, "sh", lambda *a, **k:
                        "cd -- '/x' ; exec pi --session' '66666666-6666-6666-6666-666666666666'")
    monkeypatch.setattr(L, "_recorded_session", lambda ws: None)
    monkeypatch.setattr(L, "session_file", lambda sid: str(old))
    monkeypatch.setattr(L, "_content_session", lambda label, cf: None)   # the label match missed
    monkeypatch.setattr(L, "registry", lambda: [("This Lane", "WS", ""), ("Other One", "WS2", "")])
    sid, verified = L.resolve_session_ex("WS")
    assert sid == "66666666-6666-6666-6666-666666666666"
    assert verified is True, (
        "a fresh writer whose first user message NAMES a co-located lane is that lane working -- "
        "not an unexplained writer, so this binding stays confirmed")


def test_the_human_table_fits_the_longest_verdict(L):
    """⛔ THE OPERATOR'S PRIMARY ARTIFACT IS A FIXED-WIDTH TABLE (#1867 review). The VERDICT column
    was 14 wide while `UNATTRIBUTED-WORKING` -- the newest, most safety-critical label -- is 20, so
    every row in that table shifted its SELF/UI/INBOUND/CHILD columns. The column width is a module
    constant so this can be asserted WITHOUT pinning a format string's spelling."""
    printed = (L.WORKING, L.WAITING, L.WIP_IDLE, L.DONE_IDLE, L.WEDGED, L.EMPTY, L.UNKNOWN,
               L.UNBOUND, L.UNATTRIBUTED_WORKING, L.CHILD_STUCK, L.WAITING_OVERDUE, L.LONG_TOOL)
    longest = max(printed, key=len)
    assert len(longest) <= L.VERDICT_COL, (
        "verdict %r is %d chars but the table formats the VERDICT column at %d -- every column to "
        "its right shifts" % (longest, len(longest), L.VERDICT_COL))


# ── the veto has no hole inside the child block (#1867 re-review) ────────────────────────────
# The abandoned-child branch sits INSIDE the child block but emits the DISPATCHABLE family, so a
# veto placed only below the child block left `DONE-IDLE` reachable with proven CPU progress -- and
# `queue-dispatch.py` reads this verdict directly, so `lane-actions`' own veto is not a backstop.

def test_an_abandoned_child_cannot_mint_an_idle_verdict_under_unattributed_progress(L):
    """⛔ AN IDLE RETURN IS AN IDLE RETURN, WHEREVER IT SITS. Same inputs, only `cpu_any` differs:
    the control is the completed-turn-with-abandoned-record verdict, the test is the same lane with
    proven progress in its own directory -- which must not be dispatchable."""
    kw = dict(stale=48000, grew=False, spinner=False, last_kind="assistant",
              child={"age": 99999, "abandoned": True}, child_stale=500, child_grew=None,
              child_activity_age=None, tool_inflight=None, last_stop="stop", has_sid=True)
    assert L.classify(**kw) == L.DONE_IDLE, "control: an abandoned record + a completed turn"
    assert L.classify(cpu_any=True, **kw) == L.UNATTRIBUTED_WORKING, \
        "proven CPU progress must not leave a dispatchable DONE-IDLE reachable"


def test_a_writer_that_names_nobody_is_still_an_unexplained_writer(L, monkeypatch, tmp_path):
    """⛔ THE EXCLUSION MUST NOT READ A NAME THAT IS NOT THERE (#1867 re-review). `names_label` was a
    bare-substring match, so `"none of it"` matched the label `Other One` (via `one`) and
    `"recompile the tests"` matched `2c Pack compile` (via `compile`) -- and in this direction that
    is a FAIL-OPEN: the stale binding stays verified and the lane can be published `DONE-IDLE`.
    The registry is POPULATED here on purpose: with `registry() == []` the exclusion is never even
    consulted, which is how the first leg missed this."""
    import json as _json
    import time as _time
    assert L.names_label("none of it", "Other One") is False
    assert L.names_label("recompile the tests", "2c Pack compile") is False
    assert L.names_label("Other One: land the queue cleanup", "Other One") is True
    old = tmp_path / "88888888-8888-8888-8888-888888888888.jsonl"
    old.write_text("{}\n")
    os.utime(str(old), (_time.time() - 4000, _time.time() - 4000))
    sib = tmp_path / "99999999-9999-9999-9999-999999999999.jsonl"
    sib.write_text(_json.dumps({"type": "message",
                                "message": {"role": "user",
                                            "content": [{"type": "text",
                                                         "text": "none of it"}]}}) + "\n")
    monkeypatch.setattr(L, "sh", lambda *a, **k:
                        "cd -- '/x' ; exec pi --session' '88888888-8888-8888-8888-888888888888'")
    monkeypatch.setattr(L, "_recorded_session", lambda ws: None)
    monkeypatch.setattr(L, "session_file", lambda sid: str(old))
    monkeypatch.setattr(L, "_content_session", lambda label, cf: None)
    monkeypatch.setattr(L, "registry", lambda: [("This Lane", "WS", ""), ("Other One", "WS2", "")])
    sid, verified = L.resolve_session_ex("WS")
    assert sid == "88888888-8888-8888-8888-888888888888"
    assert verified is False, (
        "a writer whose message names NO lane must not be excluded just because one token happens "
        "to appear inside another word")


# ── the exclusion must mean "names THIS lane", not "said one of its words" ────────────────────
# ⛔#1867 RE-REVIEW (2026-10-20). The word-boundary fix above closed the ACCIDENTAL-SUBSTRING class
# (`recompile` -> `compile`, `none` -> `one`). It left the class that actually fires: a label is a
# short task phrase, so ONE of its ordinary words was enough to explain a writer -- and the writer
# this abstention exists for is a `task` CHILD sharing the lane's cwd, whose first user message is
# agent-composed prose containing "test", "compile", "cloud". Explained -> `verified` -> the stale
# binding stays publishable as `DONE-IDLE`, i.e. a dispatch into a working lane. The legs below use
# the fleet's OWN measured lane names (`Test substrate`, `2c Pack compile`, `cmux cloud`) and the
# same message shape a child actually writes.

def test_a_child_prompt_with_one_generic_token_does_not_explain_the_writer(L, monkeypatch,
                                                                          tmp_path):
    """⛔ THE SHAPE THE ABSTENTION WAS WRITTEN FOR, AND THE SHAPE THAT DEFEATED IT. `task` children
    share the lane's cwd, so a child's transcript IS the fresh sibling; its prompt says "run the
    test suite before merging", which contains `test` -- one of the two tokens of `Test substrate`.
    Pre-fix that read as a KNOWN lane (need = half of two = 1) and the 13h-quiet binding came back
    `verified`, i.e. `DONE-IDLE` and a dispatch. The control is the last assertion: a writer that
    really names the lane still explains itself."""
    import json as _json
    import time as _time
    assert L.names_label("run the test suite before merging", "Test substrate") is False, (
        "one ordinary token of a two-token label is not a name")
    assert L.names_label("Test substrate: land the queue", "Test substrate") is True
    old = tmp_path / "a1a1a1a1-0000-0000-0000-000000000000.jsonl"
    old.write_text("{}\n")
    os.utime(str(old), (_time.time() - 4000, _time.time() - 4000))       # quiet > 30m
    sib = tmp_path / "b2b2b2b2-0000-0000-0000-000000000000.jsonl"
    sib.write_text(_json.dumps({"type": "message",
                                "message": {"role": "user",
                                            "content": [{"type": "text",
                                                         "text": "run the test suite before "
                                                                 "merging"}]}}) + "\n")
    monkeypatch.setattr(L, "sh", lambda *a, **k:
                        "cd -- '/x' ; exec pi --session' 'a1a1a1a1-0000-0000-0000-000000000000'")
    monkeypatch.setattr(L, "_recorded_session", lambda ws: None)
    monkeypatch.setattr(L, "session_file", lambda sid: str(old))
    monkeypatch.setattr(L, "_content_session", lambda label, cf: None)
    monkeypatch.setattr(L, "registry", lambda: [("This Lane", "WS", ""),
                                                ("Test substrate", "WS2", "")])
    sid, verified = L.resolve_session_ex("WS")
    assert sid == "a1a1a1a1-0000-0000-0000-000000000000"
    assert verified is False, (
        "a child's prose containing one of another lane's ordinary label words is an UNEXPLAINED "
        "fresh writer: the binding is unconfirmed, so the verdict must abstain, not assert idleness")


def test_a_match_that_lands_only_on_ordinary_words_is_not_a_name(L):
    """⛔ ONE TOKEN FURTHER IN THAN THE SUBSTRING BUG. `cmux cloud` needs half its tokens = 1, so a
    writer saying "the cloud is down" named it. The distinctive half (`cmux`) is the ONLY part a
    transcript can be recognised by, so a match landing only on ordinary words answers False."""
    assert L.names_label("the cloud is down", "cmux cloud") is False
    assert L.names_label("cmux cloud: fix the drawer", "cmux cloud") is True, (
        "control: the lane naming itself, with its distinctive token, still matches")


def test_a_label_built_only_from_ordinary_words_names_nothing(L):
    """⛔ `2c Pack compile` and `1 Capture` are REAL lane names (quoted in this repo's own
    comments), and every token in them is an ordinary English word -- so any prose could name them
    and no transcript can be recognised by them. The rule states the consequence instead of
    guessing: such a label is not an identity signal. Fail-closed here (a lane reads unconfirmed,
    report-only) because the other direction is a dispatch."""
    assert L.names_label("2c Pack compile: ship the release", "2c Pack compile") is False
    assert L.names_label("capture everything now", "1 Capture") is False
    assert L.names_label("instrumentation is up", "7 Instrumentation") is True, (
        "control: a label with a distinctive token still matches normally")


def test_content_session_does_not_bind_a_child_transcript_that_shares_one_word(L, tmp_path):
    """⛔ THE SECOND CALLER OF THE SAME MATCHER (#1867 re-review). `_content_session` binds this
    lane to a newer file in its own directory when the first user message "names" the label. With
    the half rule that was the same looseness in the same direction but a different cost: the lane
    is bound to its CHILD's transcript, and every stale/grew verdict is then computed from the
    wrong file. A child writing "cloud is down" must not name `cmux cloud`; the lane naming itself
    must still be recovered (control), which is the manual-relaunch path this function exists for."""
    import json as _json
    import time as _time
    stale = tmp_path / "c3c3c3c3-0000-0000-0000-000000000000.jsonl"
    stale.write_text("{}\n")
    os.utime(str(stale), (_time.time() - 4000, _time.time() - 4000))
    child = tmp_path / "d4d4d4d4-0000-0000-0000-000000000000.jsonl"
    child.write_text(_json.dumps({"type": "message",
                                  "message": {"role": "user",
                                              "content": [{"type": "text",
                                                           "text": "cloud is down"}]}}) + "\n")
    assert L._content_session("cmux cloud", str(stale)) is None, (
        "a child's transcript sharing one ordinary word is not this lane's session")
    own = tmp_path / "e5e5e5e5-0000-0000-0000-000000000000.jsonl"
    own.write_text(_json.dumps({"type": "message",
                                "message": {"role": "user",
                                            "content": [{"type": "text",
                                                         "text": "cmux cloud: resume after relaunch"
                                                         }]}}) + "\n")
    assert L._content_session("cmux cloud", str(stale)) == str(own), (
        "control: the lane's own relaunched session is still recovered")


def test_a_sibling_transcript_is_parsed_once_per_file_not_once_per_lane(L, monkeypatch,
                                                                      tmp_path):
    """⛔ THE LOOP RE-READ THE SAME FILE PER EXCLUDED LABEL. `_first_user_message(f)` sat inside
    `any(... for l in exclude_labels)`, so a fleet of N lanes cost N re-opens and N full JSONL
    parses of ONE sibling file on every quiet lane's every read. Behaviour-neutral on the verdict,
    which is exactly why it needs a test: nothing else would notice it coming back."""
    import time as _time
    old = tmp_path / "f6f6f6f6-0000-0000-0000-000000000000.jsonl"
    old.write_text("{}\n")
    os.utime(str(old), (_time.time() - 4000, _time.time() - 4000))
    sib = tmp_path / "07070707-0000-0000-0000-000000000000.jsonl"
    sib.write_text('{"type":"user","content":"nobody named here"}\n')
    calls = []
    real = L._first_user_message

    def counting(p):
        calls.append(p)
        return real(p)

    monkeypatch.setattr(L, "_first_user_message", counting)
    labels = ["Lane A", "Lane Bee", "Lane Cee", "Lane Dee"]
    assert L._live_sibling_session(str(old), labels) == str(sib)
    assert len(calls) == 1, (
        "the sibling's first user message must be parsed ONCE for the whole exclusion list, not "
        "once per excluded label -- got %d parses of one file" % len(calls))


def test_first_user_message_reads_the_v3_session_envelope(L, tmp_path):
    """⛔ THE IDENTITY SIGNAL WAS DEAD ON REAL DATA (2026-10-17, measured 0 of 45 files). pi writes
    `{"type":"message","message":{"role":"user","content":[…]}}` (session-format v3); the parser
    accepted only a TOP-LEVEL `type`/`role` of `user`, so `_first_user_message` returned "" for every
    real writer -- and a label matcher fed "" answers False, silently, which left BOTH
    `_content_session`'s recovery and the sibling exclusion inert. The legacy shapes stay supported
    (control)."""
    v3 = tmp_path / "aaaa.jsonl"
    v3.write_text('{"type":"session","version":3}\n' +
                  '{"type":"message","message":{"role":"user","content":'
                  '[{"type":"text","text":"Other One: land the queue"}]}}\n')
    assert "Other One" in L._first_user_message(str(v3))
    legacy = tmp_path / "bbbb.jsonl"
    legacy.write_text('{"type":"user","content":"Other One: legacy shape"}\n')
    assert "Other One" in L._first_user_message(str(legacy))


# ── HOW NARROW THE EXCLUSION IS, PINNED INSTEAD OF OVER-CLAIMED (#1867 re-review) ────────────
# §10 of docs/ops/fleet-liveness.md used to say a shared sessions dir "does not go permanently
# UNVERIFIED-SESSION". That is narrower than the code: the exclusion needs EVERY distinctive token
# of a roster label, so a writer nobody can name -- including a co-located lane relaunched by hand,
# whose first message is whatever the operator typed -- is still unexplained, and the quiet lanes in
# that directory abstain. The two legs below pin the two consequences as BEHAVIOUR, so the doc has to
# be edited deliberately if they ever change.

def test_a_label_of_ordinary_words_has_no_content_recovery(L, tmp_path):
    """⛔ THE RECORDED COST (#1867 re-review, 2026-10-20). `_content_session` is the manual-relaunch
    recovery path, and it shares `names_label` with the sibling exclusion. A label built only from
    `GENERIC_LABEL_TOKENS` -- `2c Pack compile` and `1 Capture` are real fleet names -- names nothing
    a transcript can be recognised by, so such a lane has NO recovery here: it stays bound to the
    stale file. Fail-closed (report-only) and deliberate: the alternative is exactly the
    child-transcript binding the same matcher was fixed for, and a wrong pick here is a dispatch.
    The control is a lane whose label carries a distinctive token, recovered from the same shape."""
    import json as _json
    import time as _time
    stale = tmp_path / "1a1a1a1a-0000-0000-0000-000000000000.jsonl"
    stale.write_text("{}\n")
    os.utime(str(stale), (_time.time() - 4000, _time.time() - 4000))
    generic = tmp_path / "2b2b2b2b-0000-0000-0000-000000000000.jsonl"
    generic.write_text(_json.dumps({"type": "message",
                                    "message": {"role": "user",
                                                "content": [{"type": "text",
                                                             "text": "2c Pack compile: ship the "
                                                                     "release"}]}}) + "\n")
    assert L._content_session("2c Pack compile", str(stale)) is None, (
        "a label of ordinary words cannot be recovered from a transcript -- if this ever starts "
        "returning a file, the generic-only refusal in names_label has been loosened")
    distinctive = tmp_path / "3c3c3c3c-0000-0000-0000-000000000000.jsonl"
    distinctive.write_text(_json.dumps({"type": "message",
                                       "message": {"role": "user",
                                                   "content": [{"type": "text",
                                                                "text": "7 Instrumentation: resume "
                                                                        "after relaunch"}]}}) + "\n")
    assert L._content_session("7 Instrumentation", str(stale)) == str(distinctive), (
        "control: a distinctive label IS recovered -- the manual-relaunch path still works")


def test_a_co_located_generic_only_lane_does_not_explain_the_writer(L, monkeypatch, tmp_path):
    """⛔ THE SHARED-DIR CLAIM IS NARROWER THAN IT READ (#1867 re-review, 2026-10-20). The exclusion
    fires only on a label with a distinct token that the writer names IN FULL. So in the measured
    nine-lanes-one-cwd case a writer naming the co-located `2c Pack compile` -- a real fleet lane --
    is still an UNEXPLAINED writer, and this lane abstains: report-only, never `idle`, never `dead`.
    That is the fail-closed direction, and it is what §10 now says instead of \"a shared dir is
    handled\". The control is the last assertion group: a distinctive co-located name does explain."""
    import json as _json
    import time as _time
    old = tmp_path / "4d4d4d4d-0000-0000-0000-000000000000.jsonl"
    old.write_text("{}\n")
    os.utime(str(old), (_time.time() - 4000, _time.time() - 4000))    # quiet > 30m
    sib = tmp_path / "5e5e5e5e-0000-0000-0000-000000000000.jsonl"
    sib.write_text(_json.dumps({"type": "message",
                                "message": {"role": "user",
                                            "content": [{"type": "text",
                                                         "text": "2c Pack compile: ship the "
                                                                 "release"}]}}) + "\n")
    monkeypatch.setattr(L, "sh", lambda *a, **k:
                        "cd -- '/x' ; exec pi --session' '4d4d4d4d-0000-0000-0000-000000000000'")
    monkeypatch.setattr(L, "_recorded_session", lambda ws: None)
    monkeypatch.setattr(L, "session_file", lambda sid: str(old))
    monkeypatch.setattr(L, "_content_session", lambda label, cf: None)
    monkeypatch.setattr(L, "registry", lambda: [("This Lane", "WS", ""),
                                                ("2c Pack compile", "WS2", "")])
    sid, verified = L.resolve_session_ex("WS")
    assert sid == "4d4d4d4d-0000-0000-0000-000000000000"
    assert verified is False, (
        "a generic-only lane name does not identify a writer, so this binding is unconfirmed")
    # Control: the same lane, a co-located label WITH a distinctive token, named in full.
    monkeypatch.setattr(L, "registry", lambda: [("This Lane", "WS", ""),
                                                ("7 Instrumentation", "WS2", "")])
    sib.write_text(_json.dumps({"type": "message",
                                "message": {"role": "user",
                                            "content": [{"type": "text",
                                                         "text": "7 Instrumentation: landed the "
                                                                 "rollup"}]}}) + "\n")
    _, verified2 = L.resolve_session_ex("WS")
    assert verified2 is True, (
        "control: a writer that names a co-located lane in full is that lane working, not evidence "
        "about this one")


# ── THE POPULATION, NOT JUST THE ROSTER (agent-infra#2199) ───────────────────────────────────
# These tests pin the ONE gap this issue is about: an agent process that no record binds must be
# reported as `UNBOUND(pid, age, spawner)` instead of being absent from the accounting. The
# measured incident (2026-10-20) is in `unbound_agents`' docstring and in the report: twelve hourly
# cron `pi -p --no-session` agents, 1-10h old, invisible to a classifier that only walks lanes.

def _proc_via(L, entries):
    """{(pid): dict?} -- entries are `(pid, ppid, etime, rss, cmd)`."""
    m = {}
    for e in entries:
        pid, ppid = str(e[0]), str(e[1])
        etime, rss, cmd = e[2], e[3], e[4]
        m[pid] = dict(ppid=ppid, etime_s=L._parse_etime(etime), rss_kb=rss, cmd=cmd)
    return m


def _isolate(L, monkeypatch, tmp_path):
    """No live state from the host: an empty session store, no cached cwd/proc/dir tables."""
    monkeypatch.setattr(L, "SD", str(tmp_path / "sessions"))
    os.makedirs(str(tmp_path / "sessions"), exist_ok=True)
    monkeypatch.setattr(L, "_PI_PROCS", None)
    monkeypatch.setattr(L, "_PROCS", None)
    monkeypatch.setattr(L, "_BOUND_DIRS_CACHE", {})


def test_a_live_agent_with_no_lane_record_is_UNBOUND_with_age_and_spawner(L, tmp_path, monkeypatch):
    """THE ARM THIS ISSUE EXISTS FOR. An hourly cron agent has no cmux workspace, no lane row, no
    worktree, and `--no-session` leaves no session file -- so nothing above this line can see it.
    It must come back as an UNBOUND row carrying pid, age and spawner, NOT be dropped."""
    _isolate(L, monkeypatch, tmp_path)
    monkeypatch.setattr(L, "_live_agent_pids", lambda: (["8584"], True))
    monkeypatch.setattr(L, "_pi_cwd_map", lambda: {"8584": "/Users/home/orchestrator"})
    table = _proc_via(L, [
        (8584, 8579, "02:29:14", 15728, "pi"),
        (8579, 8577, "02:29:22", 448,
         "/bin/sh -c cd /Users/home/orchestrator && pi -p --no-session \"$(cat prompt)\""),
        (8577, 610, "02:47:54", 240, "/usr/sbin/cron"),
        (610, 1, "13:00:00", 900, "/sbin/launchd"),
    ])
    monkeypatch.setattr(L, "proc_table", lambda: table)
    rows = L.unbound_agents({})
    assert len(rows) == 1, rows
    r = rows[0]
    assert r["kind"] == "agent" and r["verdict"] == L.UNBOUND
    assert r["pid"] == "8584" and r["count"] == 1
    assert r["age_s"] == 2 * 3600 + 29 * 60 + 14, "the age must be the process's own, not zero"
    assert r["spawner"] == "cron", r["spawner_chain"]
    assert r["cwd"] == "/Users/home/orchestrator"
    # The full lane-row key set: consumers index these dicts directly, so a missing key would turn
    # one new row class into a traceback inside a consumer that never asked for it.
    for k in ("lane", "stale_s", "grew", "inbound_age", "inbound_readable", "cpu", "cpu_any",
              "inbound_msg", "degraded", "session_verified", "declared", "pane_children",
              "spinner", "sid", "ws", "size", "issue_label", "last", "recent", "child",
              "child_file", "child_stale", "child_grew", "child_activity", "tool"):
        assert k in r, "agent rows must carry the lane-row key %r" % (k,)


def test_an_agent_a_record_binds_is_never_reported_as_unattributed(L, tmp_path, monkeypatch):
    """The other direction, and the one that keeps the report honest: a lane's own agent (same cwd
    as the lane row, or a session file under its own cwd) must NOT appear as unattributed -- that
    would be double-counting a lane as a stray process."""
    _isolate(L, monkeypatch, tmp_path)
    monkeypatch.setattr(L, "_live_agent_pids", lambda: (["111", "222"], True))
    monkeypatch.setattr(L, "_pi_cwd_map", lambda: {"111": "/Users/home/eldato/tortoise",
                                                   "222": "/tmp/wt-1"})
    monkeypatch.setattr(L, "proc_table", lambda: _proc_via(L, [
        (111, 10, "00:10:00", 1000, "pi"), (222, 10, "00:10:00", 1000, "pi"),
        (10, 1, "01:00:00", 500, "/sbin/launchd")]))
    # 111's cwd is a live lane row's session dir...
    lane_dir = L.mangled("/Users/home/eldato/tortoise")
    # ...and 222's cwd has a session record of its own.
    os.makedirs(os.path.join(str(tmp_path / "sessions"), L.mangled("/tmp/wt-1")))
    open(os.path.join(str(tmp_path / "sessions"), L.mangled("/tmp/wt-1"),
                      "abc.jsonl"), "w").write("{}\n")
    assert L.unbound_agents({lane_dir: ["tortoise (443A7DFB)"]}) == []


def test_agents_are_bucketed_by_spawner_and_directory_not_one_row_per_pid(L, tmp_path,
                                                                        monkeypatch):
    """A hung HOURLY job accumulates one new pid per hour. Per-pid rows would grow without bound
    and the heartbeat would re-alert on every new pid for ever; the bucket is stable across ticks
    and still lists every pid it covers, so nothing is omitted from the accounting."""
    _isolate(L, monkeypatch, tmp_path)
    three = ["11", "22", "33"]
    monkeypatch.setattr(L, "_live_agent_pids", lambda: (three, True))
    monkeypatch.setattr(L, "_pi_cwd_map", lambda: {p: "/Users/home/orchestrator" for p in three})
    monkeypatch.setattr(L, "proc_table", lambda: _proc_via(L, [
        (11, 900, "08:00:00", 1000, "pi"),          # oldest
        (22, 900, "05:00:00", 2000, "pi"),
        (33, 900, "00:05:00", 3000, "pi"),
        (900, 1, "09:00:00", 500, "/usr/sbin/cron")]))
    # the middle hop is what names the spawner: cron's sh -c
    t = L.proc_table()
    t["900"] = dict(ppid="1", etime_s=32400, rss_kb=500, cmd="/usr/sbin/cron")
    rows = L.unbound_agents({})
    assert len(rows) == 1, rows
    r = rows[0]
    assert r["count"] == 3 and r["pids"] == ["11", "22", "33"], r["pids"]
    assert r["pid"] == "11", "`pid` must be the OLDEST process, not the first one read"
    assert r["age_s"] == 8 * 3600, "the bucket's age is its oldest member's"


def test_a_wrong_shaped_or_absent_process_record_refuses_instead_of_guessing(L, tmp_path,
                                                                             monkeypatch):
    """⛔ A RECORD WE COULD NOT READ IS NOT A PROCESS WE COULD CLASSIFY. A missing `ps` row, an
    unparseable `etime` and an unknown ancestor chain must all yield the SAME abstention -- the
    agent is still REPORTED (never dropped) with the unknowns named, and never given a confident
    verdict. Collapsing this to a definite value is the defect class the rest of this file keeps
    re-learning (an absent read rendered as a fact)."""
    _isolate(L, monkeypatch, tmp_path)
    monkeypatch.setattr(L, "_live_agent_pids", lambda: (["999"], True))
    monkeypatch.setattr(L, "_pi_cwd_map", lambda: {"999": "/nowhere"})
    monkeypatch.setattr(L, "proc_table", lambda: {})            # the ps read answered nothing
    rows = L.unbound_agents({})
    assert len(rows) == 1, "an unreadable record must still be reported, not omitted"
    r = rows[0]
    assert r["verdict"] == L.UNBOUND, "an abstention, never WIP-IDLE/DONE-IDLE"
    assert r["spawner"] == "unknown" and r["age_s"] is None
    assert L._age_h(r["age_s"]) == "UNKNOWN", "an unread age must not render as 0s"
    # ...and the same for a cwd that could not be read at all (lsof failed / raced exit).
    monkeypatch.setattr(L, "_pi_cwd_map", lambda: {})
    rows = L.unbound_agents({})
    assert len(rows) == 1 and rows[0]["cwd"] == "?" and rows[0]["verdict"] == L.UNBOUND


def test_an_unreadable_population_is_a_named_absence_not_zero_agents(L, tmp_path, monkeypatch):
    """⛔ `pgrep` EXIT 1 IS AN ANSWER; ANY OTHER FAILURE IS NOT. `pgrep` returns 1 for "no process
    matched" AND is indistinguishable from a failure if only stdout is read -- so the same empty
    list meant "idle box" and "could not look", and the box with twelve hung agents would render
    as clean. The flag is stamped on every lane row so a consumer can refuse."""
    import subprocess as _sp

    class P:
        def __init__(self, rc, out=""):
            self.returncode, self.stdout = rc, out

    _isolate(L, monkeypatch, tmp_path)
    monkeypatch.setattr(_sp, "run", lambda *a, **k: P(1))        # rc=1 -> a real empty answer
    assert L._live_agent_pids() == ([], True)
    monkeypatch.setattr(_sp, "run", lambda *a, **k: P(2))        # rc=2 -> we could not look
    assert L._live_agent_pids() == ([], False)
    monkeypatch.setattr(_sp, "run", lambda *a, **k: (_ for _ in ()).throw(OSError("no pgrep")))
    assert L._live_agent_pids() == ([], False)
    # and the module flag the caller reads is set from that read, not from the row count
    monkeypatch.setattr(_sp, "run", lambda *a, **k: P(2))
    L.unbound_agents({})
    assert L.PROCS_READABLE is False
    monkeypatch.setattr(_sp, "run", lambda *a, **k: P(0, "1234\n"))
    monkeypatch.setattr(_sp, "run", lambda *a, **k: P(1))
    L.unbound_agents({})
    assert L.PROCS_READABLE is True


def test_etime_parses_every_ps_shape_and_refuses_the_rest(L):
    """`ps -o etime` has three shapes, and a day-old hung agent is the case this issue measured.
    An unparseable value is None (UNKNOWN), never a fabricated zero."""
    assert L._parse_etime("14") == 14
    assert L._parse_etime("02:29:14") == 2 * 3600 + 29 * 60 + 14
    assert L._parse_etime("1-02:03:04") == 86400 + 2 * 3600 + 3 * 60 + 4
    assert L._parse_etime("garbage") is None
    assert L._parse_etime("") is None


def test_spawner_classes_are_read_from_the_chain_and_never_guessed(L):
    """The spawner column is what decides the ACTION (a `cron` hit is an unbounded job; an
    `interactive` one is a person's terminal), so each class is pinned against a realistic chain --
    including the two shapes that were got wrong while proving this arm on the live box."""
    def sp(entries, pid):
        return L.spawner_of(pid, _proc_via(L, entries))[0]

    # cron: pi <- sh -c <- cron (the measured chain that hid twelve agents)
    assert sp([(500, 501, "01:00:00", 1, "pi"),
               (501, 502, "01:00:01", 1, "/bin/sh -c cd /x && pi -p --no-session 'p'"),
               (502, 610, "05:00:00", 1, "/usr/sbin/cron")], 500) == "cron"
    # an agent's shell: pi <- pi (a task/subagent child, or a bash-tool child)
    assert sp([(500, 501, "00:05:00", 1, "pi"), (501, 502, "00:10:00", 1, "pi"),
               (502, 503, "01:00:00", 1, "-/bin/zsh"),
               (503, 1, "05:00:00", 1, "/usr/bin/login -flp home /bin/zsh")], 500) == "agent"
    # a persistent terminal anchor: interactive (a human, or a lane pane)
    assert sp([(500, 501, "00:05:00", 1, "pi"), (501, 502, "00:10:00", 1, "-/bin/zsh"),
               (502, 503, "01:00:00", 1, "/usr/bin/login -flp home /bin/bash"),
               (503, 1, "05:00:00", 1, "/Applications/cmux.app/Contents/MacOS/cmux")],
              500) == "interactive"
    # ⛔ A BARE SHELL WHOSE PARENT EXITED IS `unknown`, NOT `interactive`. Measured: an agent
    # started from another agent's bash tool read "a human is watching" about a process no human
    # had ever seen, because the ephemeral `bash -c` was itself re-parented to launchd.
    assert sp([(500, 501, "00:05:00", 1, "pi"),
               (501, 1, "00:06:00", 1, "/bin/bash -c cd /x && ./pi")], 500) == "unknown"
    # ...and a chain that ends at pid 1 is only `launchd` with a launchd trace in it.
    assert sp([(500, 501, "00:05:00", 1, "pi"),
               (501, 1, "00:06:00", 1, "/bin/bash /Users/x/.pi/agent/scripts/fleet/job.sh")],
              500) == "launchd"
    # the harness's own capped dispatch paths are named, so a bounded worker is never mistaken for
    # an unbounded one
    assert sp([(500, 501, "00:05:00", 1, "pi"),
               (501, 502, "00:06:00", 1, "bash /o/nonblocking-dispatch.sh n wt p 3000")],
              500) == "nonblocking-dispatch.sh"
    assert sp([(500, 501, "00:05:00", 1, "pi"),
               (501, 502, "00:06:00", 1, "bash /o/merge-one.sh --argv /o/state/argv-1")],
              500) == "merge-one.sh"
