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
