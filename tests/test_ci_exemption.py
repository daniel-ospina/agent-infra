"""Acceptance tests for the pre-merge exemption decision (tortoise #3756).

Every case here is a MUTATION that must RED if the fix regresses. The declared
threat surface is the **exemption face**: a failure excused because main recently
failed it. Each declared class gets its own test:

* **E1** presence-in-window immunity
* **E2** id-granularity immunity (same id, DIFFERENT failure inside it)
* **E3** rate-blindness (``main 1/8`` vs ``PR 8/8``)
* **E4** silent exemption (a green with no recorded exemption line)
* plus the **window-boundary** case (in the acceptance, NOT in the threat surface:
  it is fixed as a CONSEQUENCE of the effect change — once the decision is a
  re-measurement there is no window to be outside of)
* plus **verdict-stability** (the same failure set evaluated twice must return the
  same verdict)
* plus the **fail-closed parser** (a stray non-nodeid must REFUSE the exemption,
  never enter the union)

Out of scope and deliberately not claimed: over-block (face 1) is a COST, not a
bypass — it is fixed here, but it is not part of the exemption surface.
"""

from __future__ import annotations

import pytest

import importlib.util
import itertools
import sys
from pathlib import Path

# ── THE MODULE UNDER TEST — loaded BY PATH, exactly the way the rail runs it ──
# `scripts/` is NOT a package, so the canonical module is loaded through
# importlib by FILE LOCATION. That is deliberately the same file the rail execs
# — never a copy:
#
#   scripts/admin-merge.sh:159  EXEMPTION_PY="$SELF_DIR/ci_exemption.py"
#   scripts/admin-merge.sh:256  "$PYTHON_BIN" "$EXEMPTION_PY" decide …
#
# A retarget at a vendored copy (tortoise's tools/ci_exemption.py, PR #3761)
# would leave this suite green while the REAL module drifts. A green suite over
# a copy is a false-PASS generator — the class #3756 exists to eliminate. The
# coupling is pinned by test_tests_load_the_file_the_rail_execs below.
_CANONICAL_PATH = Path(__file__).resolve().parents[1] / "scripts" / "ci_exemption.py"
_spec = importlib.util.spec_from_file_location("ci_exemption_canonical", _CANONICAL_PATH)
if _spec is None or _spec.loader is None:  # pragma: no cover - environment failure
    raise ImportError(f"canonical exemption module is ABSENT at {_CANONICAL_PATH}")
ci_exemption = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = ci_exemption
_spec.loader.exec_module(ci_exemption)

Failure = ci_exemption.Failure
Rate = ci_exemption.Rate
decide = ci_exemption.decide
detect_rotating_identity = ci_exemption.detect_rotating_identity
guard_step_key = ci_exemption.guard_step_key
is_failure_key = ci_exemption.is_failure_key
is_failure_key_loose = ci_exemption.is_failure_key_loose
normalize_guard_error = ci_exemption.normalize_guard_error
parse_failed_ids = ci_exemption.parse_failed_ids
parse_failure_rows = ci_exemption.parse_failure_rows
parse_pr_failure_text = ci_exemption.parse_pr_failure_text
parse_rates = ci_exemption.parse_rates
parse_signature_rows = ci_exemption.parse_signature_rows

ID = "tests/test_dr_endpoints.py::TestDrDrill::test_restores_to_scratch"


def _f(failures: int, runs: int, *sigs: str) -> Failure:
    return Failure(rate=Rate(failures, runs), signatures=frozenset(sigs))


# ── the fail-closed parser ────────────────────────────────────────────────


def test_parser_rejects_a_stray_non_nodeid_line():
    """A bare `may` token must NOT enter the union (the measured artifact)."""
    parsed = parse_failed_ids(f"may\nFAILED {ID}\n")

    assert parsed.ids == [ID]
    assert "may" in parsed.rejected, "a stray token must be rejected AND counted"


def test_parser_rejects_a_failed_line_whose_payload_is_not_a_nodeid():
    """`FAILED may` is not a failure record — the payload is not a nodeid."""
    parsed = parse_failed_ids("FAILED may\n")

    assert parsed.ids == []
    assert parsed.rejected == ["FAILED may"]


def test_parser_is_fail_closed_when_nothing_parses():
    """An unreadable set must not present as an empty one."""
    parsed = parse_failed_ids("some prose\nanother line\n")

    assert parsed.ids == []
    assert parsed.ok is False, "zero parsed ids must not read as a valid empty set"
    assert len(parsed.rejected) == 2


def test_parser_accepts_both_FAILED_and_ERROR_and_dedupes():
    parsed = parse_failed_ids(f"FAILED {ID}\nERROR {ID}\n")

    assert parsed.ids == [ID], "one id, deduped"
    assert parsed.rejected == []


def test_stray_line_cannot_buy_an_exemption():
    """THE POINT OF THE PARSER RULE: junk must not weaken the gate.

    `may` must never end up in the set a PR is excused against.
    """
    parsed = parse_failed_ids("may\n")
    main_rates = {i: Rate(4, 4) for i in parsed.ids}

    decision = decide({ID: _f(4, 4, "AssertionError: x")}, main_rates,
                      main_signatures={ID: frozenset({"AssertionError: x"})},
                      k_pr=4)

    assert decision.any_blocked, "a junk union must not exempt anything"
    assert main_rates == {}, "the stray token bought no entry"


# ── the anchored record rule (#1396 mechanism A / tortoise #5194) ──────────
# A `FAILED` that does not START the line is prose, not a record. Both producers
# below were measured: the workflow echoes its own shell source, and a tool
# prints its own verdict. Reading the token after a bare `FAILED` DROPPED an
# English word, and a single drop marks the set CLIPPED / NOT COMPARABLE — which
# blocks every merge repo-wide in the vacuous branch, green PRs included.


def test_echoed_workflow_prose_with_a_bare_FAILED_is_not_a_record():
    """The measured `python-ci.yml` heartbeat comment must not drop tokens.

    These are the exact lines (run 36083467843, main 0824b850c): they yielded
    `may` and `lines`, which were DROPPED. The real nodeid must survive and the
    dropped set must be EMPTY.
    """
    capture = (
        "test (b)\tRun selected files\t2026-09-25T01:55:17.9136425Z "
        "# re-lists failures, so FAILED may double-count on the last tick;\n"
        "test (b)\tRun selected files\t2026-09-25T01:55:17.9148357Z "
        "# line log puts the FAILED lines ~2.4k lines back), so the tail\n"
        f"test (b)\tRun selected files\t2026-09-25T01:55:18.0000000Z FAILED {ID}\n"
    )
    parsed = parse_failed_ids(capture, raw_log=True)

    assert parsed.ids == [ID], "the real nodeid must still be extracted"
    assert parsed.rejected == [], (
        "prose is not a failure record; counting it as DROPPED marked the set "
        "CLIPPED and blocked the fleet (agent-infra #1396)"
    )
    assert parsed.ok


def test_a_tool_message_with_a_bare_FAILED_is_not_a_record():
    """agent-infra #1466: the VGATE extension's own verdict line, which blocked a
    green PR repo-wide. It previously yielded the id `(unparseable`.
    """
    capture = (
        "extension-tests / unit-test\tRun unit tests\t"
        "2026-09-25T00:00:00.0000000Z [verification-gate] "
        "\u274c Verifier FAILED (unparseable verdict): keep blocking, no merge\n"
    )
    parsed = parse_failed_ids(capture, raw_log=True)

    assert parsed.ids == []
    assert parsed.rejected == [], (
        "a tool's prose is not a dropped failure token — six of these made "
        "main's baseline CLIPPED and blocked every merge (#1396)"
    )


def test_pytest_progress_line_is_not_a_record_and_not_a_drop():
    """`<nodeid> FAILED [ 42%]` is the -v progress line, not the -r fE summary.

    It was never an id source (the token after FAILED was `[`), so skipping it
    loses nothing — but it must not be COUNTED as a drop either.
    """
    capture = f"test (b)\tRun selected files\t2026-09-25T00:00:00.0000000Z {ID} FAILED                                       [ 42%]\n"
    parsed = parse_failed_ids(capture, raw_log=True)

    assert parsed.ids == []
    assert parsed.rejected == []


def test_a_leading_FAILED_with_a_non_nodeid_payload_is_still_counted():
    """The anchor narrows WHERE a record starts — it does not loosen what one
    needs. A malformed record at line start is still DROPPED and COUNTED, so the
    fix cannot fail open.
    """
    parsed = parse_failed_ids("FAILED may\n", raw_log=True)

    assert parsed.ids == []
    assert parsed.rejected == ["may"], "an anchored malformed record is still a drop"
    assert parsed.ok is False


def test_xdist_progress_line_recovers_the_nodeid():
    """pytest-xdist writes status BEFORE the nodeid (pytest 9.x terminal.py).

    `[gw0] [ 50%] FAILED <nodeid>` is a REAL identity and the pre-anchor parser
    recovered it. The anchor alone would have discarded it — a fail-open whenever
    the run's `-r` summary omits the failing category — so a nodeid that follows
    a NON-leading `FAILED`/`ERROR` is recovered, while prose is not.
    """
    capture = (
        "test (b)\tRun selected files\t2026-09-25T00:00:00.0000000Z "
        f"[gw0] [ 50%] FAILED {ID}\n"
    )
    parsed = parse_failed_ids(capture, raw_log=True)

    assert parsed.ids == [ID], "the xdist progress nodeid must be recovered"
    assert parsed.rejected == [], "recovery is not a drop"


def test_a_nonleading_FAILED_with_a_non_nodeid_payload_is_skipped():
    """The recovery half must not fire on prose: a mid-line `FAILED` followed by
    a word is skipped, never dropped. This is the pair to the xdist case.
    """
    capture = (
        "test (b)\tRun selected files\t2026-09-25T00:00:00.0000000Z "
        "# so FAILED may double-count on the last tick\n"
    )
    parsed = parse_failed_ids(capture, raw_log=True)

    assert parsed.ids == []
    assert parsed.rejected == [], "prose must not be recovered NOR counted"


def test_a_bare_leading_FAILED_is_a_blank_token_drop():
    """A leading `FAILED` as the LAST token is a truncated record: it must be a
    counted drop with blank token text — the path the shell renders as the
    `CLIPPED` evidence body (admin-merge.sh #1353).
    """
    parsed = parse_failed_ids("FAILED\n", raw_log=True)

    assert parsed.ids == []
    assert parsed.rejected == [""], "a truncated record is a drop with blank text"
    assert parsed.ok is False


def test_the_id_door_and_the_signature_door_name_the_same_spaced_param_id():
    """A pytest parameter id may contain SPACES (::test_x[chromium-Claude Desktop]).

    The id door must take the payload the same way the signature door does
    (`_SUMMARY_RE`, up to an optional ` - <detail>`), not the next whitespace
    field — otherwise the two doors name different ids, `main_signatures` misses
    and the rail blocks (module header: the shell and the decision can never
    disagree about the id universe).
    """
    spaced = "tests/test_x.py::test_y[chromium-Claude Desktop]"
    capture = f"FAILED {spaced} - AssertionError: boom\n"

    assert parse_failed_ids(capture, raw_log=True).ids == [spaced]
    assert spaced in parse_pr_failure_text(capture).ids, (
        "the signature door already names the full id — the id door must agree"
    )


def test_id_file_mode_does_not_recover_a_nonleading_nodeid():
    """`recover_nodeid` is a RAW-LOG concern: an id FILE carries records, so a
    non-leading field is a defect and is rejected, never scanned for a nodeid.
    """
    parsed = parse_failed_ids(f"note FAILED may, and later FAILED {ID}\n")

    assert parsed.ids == []
    assert parsed.rejected == [f"note FAILED may, and later FAILED {ID}"], (
        "id-file mode must not widen what an id file may contain"
    )


# ── E1 · presence-in-window immunity ──────────────────────────────────────


def test_E1_a_single_main_flake_does_not_grant_immunity():
    """One unrelated main failure must not excuse a PR that now breaks it.

    main failed it 1/8; the PR breaks it 8/8. Under a presence test ("it fails on
    main too") this was EXCUSED. Rate comparison must BLOCK it.
    """
    decision = decide(
        {ID: _f(8, 8, "AssertionError: boom")},
        {ID: Rate(1, 8)},
        main_signatures={ID: frozenset({"AssertionError: boom"})},
        k_pr=8,
    )

    assert decision.any_blocked
    assert not decision.exempt
    assert "materially higher" in decision.blocked[0].reason


# ── E2 · id-granularity immunity ──────────────────────────────────────────


def test_E2_same_id_different_failure_is_not_exempt():
    """A PR holding the RATE while breaking a DIFFERENT assertion must BLOCK.

    This is the case a rate comparison ALONE cannot catch: same id, same rate,
    different signature.
    """
    decision = decide(
        {ID: _f(4, 8, "AssertionError: the PR's new failure")},
        {ID: Rate(4, 8)},
        main_signatures={ID: frozenset({"ConnectionError: socket gone"})},
        k_pr=8,
    )

    assert decision.any_blocked
    assert "signature differs" in decision.blocked[0].reason


def test_E2_matching_signature_at_the_same_rate_is_exempt():
    """The complement: SAME signature and SAME rate IS the exemption."""
    decision = decide(
        {ID: _f(4, 8, "ConnectionError: socket gone")},
        {ID: Rate(4, 8)},
        main_signatures={ID: frozenset({"ConnectionError: socket gone"})},
        k_pr=8,
    )

    assert not decision.any_blocked
    assert len(decision.exempt) == 1


# ── E3 · rate-blindness ───────────────────────────────────────────────────


def test_E3_main_1_of_8_vs_pr_8_of_8_blocks():
    """The canonical counterexample, asserted directly."""
    decision = decide(
        {ID: _f(8, 8, "sg")}, {ID: Rate(1, 8)},
        main_signatures={ID: frozenset({"sg"})}, k_pr=8,
    )

    assert decision.any_blocked, "an 8x deterministic regression must not ship"


def test_E3_equivalent_rates_are_exempt():
    decision = decide(
        {ID: _f(3, 8, "sg")}, {ID: Rate(4, 8)},
        main_signatures={ID: frozenset({"sg"})}, k_pr=8,
    )

    assert not decision.any_blocked


def test_E3_small_k_cannot_excuse():
    """One main observation cannot establish a rate — fail closed."""
    decision = decide(
        {ID: _f(8, 8, "sg")}, {ID: Rate(1, 1)},
        main_signatures={ID: frozenset({"sg"})}, k_pr=8, min_runs=3,
    )

    assert decision.any_blocked
    assert any("insufficient evidence" in n for n in decision.notes)


# ── E3b · the TOTAL-failure residual (tortoise #3756 residual / #3762) ─────
#
# `rate_tolerance` is MULTIPLICATIVE, so its absolute width grows as main's rate
# rises. A PR that fails EVERY observed run therefore rode main's breakage into a
# green: `main 6/8` vs `PR 8/8` was EXEMPT (0.75 x 1.5 = 1.125 >= 1.0). This is
# the deferred residual Option B authorized as a follow-up (agent-infra #1209).
# The BLOCKING cases below RED if the guard is removed; the EXEMPTION cases alongside them are
# their negative controls (they RED if the guard is over-widened instead).


def test_E3b_a_total_pr_failure_is_not_bridged_by_the_tolerance():
    """The measured false PASS: `main 6/8` vs `PR 8/8` must BLOCK.

    MUTATION: delete the `pr_total and not main_total` guard -> the tolerance test
    admits 1.00 <= 0.75 x 1.5 and this assertion REDs — a DETERMINISTIC total
    regression must not ship on the tolerance.
    """
    decision = decide(
        {ID: _f(8, 8, "sg")}, {ID: Rate(6, 8)},
        main_signatures={ID: frozenset({"sg"})}, k_pr=8,
    )

    assert decision.any_blocked, "a deterministic total failure must not ship"
    assert not decision.exempt
    assert "TOTAL" in decision.blocked[0].reason


def test_E3b_a_total_pr_failure_is_not_bridged_at_main_two_of_three():
    """The exact number measured on #3762: `main 2/3` vs `PR 3/3` must BLOCK.

    MUTATION: same as above — without the guard `1.00 > 0.667 x 1.5` is False, so
    this reads as "rates equivalent" and is EXEMPT.
    """
    decision = decide(
        {ID: _f(3, 3, "sg")}, {ID: Rate(2, 3)},
        main_signatures={ID: frozenset({"sg"})}, k_pr=3,
    )

    assert decision.any_blocked
    assert not decision.exempt


def test_E3b_a_total_pr_failure_is_not_bridged_at_main_seven_of_eight():
    """The band edge: `main 7/8` (the highest non-total rate at k=8) vs `PR 8/8`.

    This pins the guard to the real predicate rather than a threshold someone
    might substitute later: a mis-fix such as `mr.rate < 0.8` leaves the 6/8 and
    2/3 cases BLOCKing while this one EXEMPTs. MUTATION: replace the guard with a
    rate-threshold form whose cutoff is BELOW the band edge (e.g. `mr.rate < 0.8`)
    -> this assertion REDs. (An over-blocking threshold at or above the edge is
    caught by the total-on-total exemption control below, not by this test.)
    """
    decision = decide(
        {ID: _f(8, 8, "sg")}, {ID: Rate(7, 8)},
        main_signatures={ID: frozenset({"sg"})}, k_pr=8,
    )

    assert decision.any_blocked
    assert not decision.exempt
    assert "TOTAL" in decision.blocked[0].reason


def test_E3b_a_total_pr_failure_IS_exempt_when_main_is_also_total():
    """The boundary that keeps the guard honest: total-on-total stays EXEMPT.

    The issue's own acceptance (§11) requires `main 4/4` vs `PR 4/4` to be
    permitted and RECORDED with both rates — refusing every saturated PR rate
    would be the wrong fix. MUTATION: widen the guard to `if pr_total:` -> this
    assertion REDs (the exemption disappears and main is blamed for nothing).
    """
    decision = decide(
        {ID: _f(4, 4, "sg")}, {ID: Rate(4, 4)},
        main_signatures={ID: frozenset({"sg"})}, k_pr=4,
    )

    assert not decision.any_blocked
    lines = decision.visible_exemptions()
    assert len(lines) == 1, "a permitted exemption must still be recorded"
    assert "4/4" in lines[0] and "k_pr=4" in lines[0]


def test_E3b_the_non_total_residual_is_unchanged():
    """Pin the SURVIVING authorized residual, so the guard is not over-read.

    `main 6/8` vs `PR 7/8` is a non-total rate inside the 1.5x band and stays
    EXEMPT. MUTATION: make the guard `pr.rate.rate >= mr.rate` (or any stricter
    comparison) -> this assertion REDs.
    """
    decision = decide(
        {ID: _f(7, 8, "sg")}, {ID: Rate(6, 8)},
        main_signatures={ID: frozenset({"sg"})}, k_pr=8,
    )

    assert not decision.any_blocked
    assert len(decision.exempt) == 1


def test_E3b_the_thin_pr_sample_path_is_untouched():
    """The #5250 floor still exempts a thin PR sample on attribution.

    MUTATION: move the TOTAL guard ABOVE the `k_pr < min_runs` branch -> the
    deliberate #5250 re-scope (a PR that merely inherited a red at 1/1) REDs, and
    the false-block #5237 was filed about returns.
    """
    decision = decide(
        {ID: _f(1, 1, "sg")}, {ID: Rate(3, 5)},
        main_signatures={ID: frozenset({"sg"})}, k_pr=1,
    )

    assert not decision.any_blocked
    assert len(decision.exempt) == 1
    assert "NOT measurable" in decision.exempt[0].reason


# ── #5250 · the PR-side sample floor ──────────────────────────────────────
#
# A PR gets ONE run per push, so its rate is a single observation and `1/1` is
# `100%` BY CONSTRUCTION. The rate comparison then blocks unconditionally
# (`1.00 > 0.60 × 1.5`) whenever main is red for a check the PR merely inherited
# — the rail unusable exactly when it is most needed (#5250; tortoise PR #5237).
# `min_runs` must floor BOTH sides: below it the RATE dimension is NOT-MEASURABLE
# and the decision falls back to the attribution question it has already answered.


def test_5250_a_single_sample_pr_rate_is_not_measurable_and_the_exemption_says_so():
    """THE defect: `k_pr=1` makes `pr_rate == 1.0` against a flaky main 3/5.

    With the PR sample below `min_runs` the rate is used NEITHER to exempt NOR to
    block; the exemption rests on signature + main presence. MUTATION: keep the
    rate comparison for a thin PR sample → this REDs (`1.00 > 0.90`). MUTATION:
    exempt silently → the `in lines[0]` assertions RED.
    """
    decision = decide(
        {ID: _f(1, 1, "sg")}, {ID: Rate(3, 5)},
        main_signatures={ID: frozenset({"sg"})}, k_pr=1,
    )

    assert not decision.any_blocked, "a 1/1 rate must not block by construction"
    lines = decision.visible_exemptions()
    assert len(lines) == 1, "the exemption must be recorded, never silent"
    assert "NOT measurable" in lines[0], lines[0]
    assert "signature + main presence" in lines[0], lines[0]
    assert "main 3/5" in lines[0], lines[0]
    assert "k_pr=1" in lines[0], lines[0]
    assert "5 run(s)" in lines[0], lines[0]


def test_5250_a_thin_pr_sample_does_not_exempt_a_disjoint_signature():
    """The fallback IS the attribution question — a different failure still BLOCKs.

    MUTATION: disable the signature gate (`if False:`) → this REDs (the thin sample
    would fall through to the rate floor and EXEMPT a failure main never had).
    """
    decision = decide(
        {ID: _f(1, 1, "sg-pr")}, {ID: Rate(3, 5)},
        main_signatures={ID: frozenset({"sg-main"})}, k_pr=1,
    )

    assert decision.any_blocked
    assert "signature differs" in decision.blocked[0].reason
    assert decision.visible_exemptions() == []


def test_5250_a_thin_pr_sample_does_not_exempt_an_id_main_never_failed():
    """Membership is required: an id absent from main's table is PR-unique.

    MASKING, stated so the mutation claim is accurate: with `main_signatures` keyed
    only by `other`, removing the `mr is None` gate makes the SIGNATURE gate
    intercept first (the missing main signature fails the overlap check), so the
    mutation does not surface as an exemption here — the reason assertion is what
    pins the membership gate. MUTATION: remove the `mr is None` membership block →
    the blocked reason changes → this REDs on the `"no main-side measurement"`
    assertion.
    """
    other = "tests/test_other.py::TestT::test_other"
    decision = decide(
        {ID: _f(1, 1, "sg")}, {other: Rate(3, 5)},
        main_signatures={other: frozenset({"sg"})}, k_pr=1,
    )

    assert decision.any_blocked
    assert "no main-side measurement" in decision.blocked[0].reason
    assert decision.visible_exemptions() == []


def test_5250_a_measured_pr_sample_still_compares_rates():
    """`k_pr >= min_runs` behaviour is UNCHANGED: a materially worse PR blocks.

    MUTATION: make the PR floor unconditional (`if True:`) → this REDs (the `3/3`
    sample is exempted instead of compared).
    """
    decision = decide(
        {ID: _f(3, 3, "sg")}, {ID: Rate(3, 5)},
        main_signatures={ID: frozenset({"sg"})}, k_pr=3,
    )

    assert decision.any_blocked
    assert "materially higher" in decision.blocked[0].reason


def test_5250_a_thin_pr_sample_does_not_bypass_the_zero_main_rate_guard():
    """`main 0/8` is NOT "measured red" — bypass 1a survives the fallback.

    MUTATION: exempt on main presence alone (drop `mr.rate > 0`) → this REDs and a
    PR failure main never had is excused by a single-sample PR rate.
    """
    decision = decide(
        {ID: _f(1, 1, "sg")}, {ID: Rate(0, 8)},
        main_signatures={ID: frozenset({"sg"})}, k_pr=1,
    )

    assert decision.any_blocked
    assert "materially higher" in decision.blocked[0].reason


def test_5250_an_undeclared_pr_sample_preserves_the_rate_comparison():
    """`k_pr=None` = the caller declared no PR sample; not a free exemption.

    The HISTORICAL comparison still runs, so a materially-worse PR blocks BY THE
    RATE COMPARISON — asserted on the reason, so a hard-block-on-`None` regression
    is distinguishable from the comparison this test is named for. The complement
    (equivalent rates are still exempt) is pinned by the test below.
    """
    decision = decide(
        {ID: _f(1, 1, "sg")}, {ID: Rate(3, 5)},
        main_signatures={ID: frozenset({"sg"})},
    )

    assert decision.any_blocked
    assert "materially higher" in decision.blocked[0].reason
    assert decision.visible_exemptions() == []


def test_5250_an_undeclared_pr_sample_can_still_exempt_on_the_rates():
    """The complement: with `k_pr=None` the rate comparison can still EXEMPT.

    Asserted on the RECORDED REASON, so the #5250 fallback's "NOT measurable" line
    cannot satisfy it: routing `k_pr is None` through the PR-floor branch would RED
    here. MUTATION: hard-block when `k_pr is None` (add it to the rate comparison's
    condition) → this REDs; the sibling above names the opposite mutation.
    """
    decision = decide(
        {ID: _f(3, 8, "sg")}, {ID: Rate(4, 8)},
        main_signatures={ID: frozenset({"sg"})},
    )

    lines = decision.visible_exemptions()
    assert not decision.any_blocked
    assert len(lines) == 1
    assert "rates equivalent" in lines[0], lines[0]


def test_5250_a_thin_pr_sample_does_not_rescue_a_thin_main_row():
    """The MAIN floor is checked BEFORE the PR floor: a thin PR sample must not
    exempt a single-observation main row.

    Both sides thin is the NORMAL production shape (`k_pr = max(row.runs)` is 1 for
    a head tested once). If the two floors were collapsed or reordered so the
    PR-side NOT-MEASURABLE fallback could decide first, `main 1/1` would be exempted
    off an unmeasurable main rate — bypass 1b as a false PASS. MUTATION: make the
    main floor skip when `k_pr < min_runs` → this REDs. MUTATION: reorder the floors
    → same.
    """
    decision = decide(
        {ID: _f(1, 1, "sg")}, {ID: Rate(1, 1)},
        main_signatures={ID: frozenset({"sg"})}, k_pr=1,
    )

    assert decision.any_blocked
    assert any("insufficient evidence" in n for n in decision.notes)
    assert decision.visible_exemptions() == []


def test_5250_a_thin_pr_sample_does_not_preempt_the_rotating_identity_gate():
    """The UNATTRIBUTABLE (rotating) gate runs BEFORE the PR floor — even when thin.

    Main has a WELL-MEASURED, signature-matching row for the id, so every other gate
    would let a thin PR sample exempt; the rotating identity must still win. The
    existing E5 test calls ``decide`` without ``k_pr`` (=None), so it never exercises
    the interaction. MUTATION: hoist the PR-floor block above the rotating check →
    this REDs (an UNATTRIBUTABLE id is EXEMPTed off a thin sample).
    """
    other = "tests/test_dr_endpoints.py::TestDrDrill::test_some_other"
    rotating = detect_rotating_identity([frozenset({ID}), frozenset({other})])
    decision = decide(
        {ID: _f(1, 1, "sg")}, {ID: Rate(3, 5)},
        main_signatures={ID: frozenset({"sg"})},
        rotating=rotating, k_pr=1,
    )

    assert [v.nodeid for v in decision.unattributable] == [ID]
    assert decision.blocked == []
    assert decision.visible_exemptions() == []


def test_5250_a_zero_declared_sample_is_not_an_exemption():
    """`k_pr=0` is not "thin": it is EMPTY, and it must not take the fallback.

    A `k_pr` of 0 would satisfy `< min_runs` while the caller has already been told
    "pr sample empty — treating every failure as PR-side". The two must not
    disagree. MUTATION: `k_pr < min_runs` without the lower bound → this REDs (the
    row is exempted off no PR sample at all).
    """
    decision = decide(
        {ID: _f(1, 1, "sg")}, {ID: Rate(3, 5)},
        main_signatures={ID: frozenset({"sg"})}, k_pr=0,
    )

    assert decision.any_blocked
    assert any("pr sample empty" in n for n in decision.notes)
    assert decision.visible_exemptions() == []


def test_5250_a_thin_pr_sample_exempts_on_attribution_at_a_low_main_rate():
    """The #5250 boundary, stated: below the PR floor the RATE is not consulted.

    The PR is red once (`1/1`) and main is measured red only `1/8`. The rate
    comparison would block (`1.00 > 0.15`) — and did, BY CONSTRUCTION, which is the
    defect this change removes. The exemption rests on the attribution question the
    issue authorizes (id present, signature matching, main's OWN row >= `min_runs`)
    and the verdict says the rate was not measurable. This is the deliberate,
    owner-authorized re-scoping of the E1/E3 classes to `k_pr >= min_runs`; it is
    pinned so the boundary is asserted, not only documented.
    """
    decision = decide(
        {ID: _f(1, 1, "sg")}, {ID: Rate(1, 8)},
        main_signatures={ID: frozenset({"sg"})}, k_pr=1,
    )

    lines = decision.visible_exemptions()
    assert not decision.any_blocked
    assert len(lines) == 1
    assert "NOT measurable" in lines[0], lines[0]


# ── E4 · the exemption must be VISIBLE ────────────────────────────────────


def test_E4_an_exemption_is_recorded_with_both_rates():
    """A green with no exemption line FAILS this test, not passes it."""
    decision = decide(
        {ID: _f(4, 8, "sg")}, {ID: Rate(4, 8)},
        main_signatures={ID: frozenset({"sg"})}, k_pr=8,
    )

    lines = decision.visible_exemptions()
    assert len(lines) == 1, "an exemption must be recorded, never silent"
    assert lines[0].startswith("EXEMPT:")
    assert "4/8" in lines[0], "the exemption must carry the measured rates"
    assert "8 run(s)" in lines[0], "the exemption must carry the main SAMPLE SIZE"
    assert "k_pr=8" in lines[0], "the exemption must carry the PR sample size"
    assert lines[0] in decision.report()


# ── window-boundary · in the ACCEPTANCE, not the threat surface ───────────


def test_window_boundary_is_no_longer_a_distinction():
    """A main-side red at ANY position is exempt — there is no window to miss.

    Previously a red outside the sampled window was invisible BY CONSTRUCTION and
    the failure read as PR-unique. With a re-measurement the position is not an
    input at all: only the measured rate is. This case is in the acceptance
    precisely because it is fixed as a CONSEQUENCE of the effect change.
    """
    decision = decide(
        {ID: _f(4, 10, "sg")}, {ID: Rate(4, 10)},
        main_signatures={ID: frozenset({"sg"})}, k_pr=10,
    )

    assert not decision.any_blocked, "no window exists to be outside of"
    assert "Window" not in decision.report() and "position" not in decision.report()


def test_an_id_main_never_failed_is_always_pr_unique():
    decision = decide(
        {ID: _f(1, 10, "sg")}, {}, k_pr=10,
    )

    assert decision.any_blocked
    assert "no main-side measurement" in decision.blocked[0].reason


# ── verdict-stability · the ACCEPTANCE test ───────────────────────────────


def test_verdict_stability_same_input_twice_same_verdict():
    """THE acceptance: a verdict that changes on re-evaluation is not a verdict.

    This single test catches every instance of the family found so far — B3's case
    cleared on the rail's retry, and mine blocked three times, with the SAME
    relationship to main in both. Sampling alignment decided the outcome.
    """
    pr = {
        ID: _f(8, 8, "sg"),
        "tests/test_other.py::test_b": _f(4, 8, "sg2"),
    }
    main = {ID: Rate(1, 8), "tests/test_other.py::test_b": Rate(4, 8)}
    sigs = {ID: frozenset({"sg"}), "tests/test_other.py::test_b": frozenset({"sg2"})}

    first = decide(pr, main, main_signatures=sigs, k_pr=8)
    second = decide(pr, main, main_signatures=sigs, k_pr=8)

    assert first.report() == second.report(), "the verdict must not depend on the draw"
    assert [v.nodeid for v in first.blocked] == [v.nodeid for v in second.blocked]


def test_verdict_stability_across_a_wider_sample():
    """More evidence changes the MEASUREMENT, never the RULE for the same data."""
    pr = {ID: _f(8, 8, "sg")}
    sigs = {ID: frozenset({"sg"})}

    # GENUINELY wider: the same RATE (0.125) measured over 8 runs vs 32. The two
    # calls must differ in their SAMPLE and agree in their VERDICT — otherwise this
    # test cannot fail and proves nothing.
    narrow = decide(pr, {ID: Rate(1, 8)}, main_signatures=sigs, k_pr=8)
    wide = decide(pr, {ID: Rate(4, 32)}, main_signatures=sigs, k_pr=8)

    assert narrow.any_blocked == wide.any_blocked, (
        "more evidence must change the measurement, never the rule")
    assert narrow.report() != wide.report(), (
        "the reports MUST differ — otherwise the two calls are the same input and "
        "this test is tautological")


# ── substrate-misfire · the fix must be correct when the substrate lies ───


def test_substrate_misfire_does_not_launder_a_pr_caused_failure():
    """Flaky main AND a genuinely worse PR must still BLOCK.

    The fix must be correct WHEN THE SUBSTRATE LIES, not depend on it being
    healthy. Here main is flaky at 2/10 and the PR is 10/10.
    """
    decision = decide(
        {ID: _f(10, 10, "sg")}, {ID: Rate(2, 10)},
        main_signatures={ID: frozenset({"sg"})}, k_pr=10,
    )

    assert decision.any_blocked


# --------------------------------------------------------------------------
# The consumer: reading `ci-failure-set.sh --main-union-rates` (#3756)
# --------------------------------------------------------------------------


def test_parse_rates_reads_the_emitted_wire_format():
    """`<nodeid>\t<failures>\t<runs>` — exactly what the shell mode writes."""
    wire = "tests/a.py::T::t1\t8\t8\ntests/b.py::T::t2\t1\t8\n"
    r = parse_rates(wire)
    assert r.rejected == []
    assert r.runs == 8
    assert r.rates["tests/a.py::T::t1"] == Rate(8, 8)
    assert r.rates["tests/b.py::T::t2"] == Rate(1, 8)


def test_parse_rates_rejects_a_vacuous_run_count():
    """`0/0` must not read as "main never fails this".

    `Rate(0, 0).rate` is `0.0` — a zero-evidence pass. The line is rejected rather
    than trusted, and the id then has NO rate, which fails closed (no exemption).
    """
    r = parse_rates("tests/a.py::T::t1\t0\t0\n")
    assert r.rates == {}
    assert r.rejected == ["tests/a.py::T::t1\t0\t0"]
    assert r.runs == 0


def test_parse_rates_rejects_malformed_and_impossible_lines():
    r = parse_rates(
        "tests/a.py::T::t1\t3\n"              # too few fields
        "tests/a.py::T::t2\t3\t8\textra\n"  # too many
        "FAILED tests/a.py::T::t3\n"           # a union line, not a rate line
        "tests/a.py::T::t4\tx\t8\n"          # non-numeric
        "tests/a.py::T::t5\t9\t8\n"          # failures > runs
    )
    assert r.rates == {}
    assert len(r.rejected) == 5


def test_E3_via_the_real_wire_format_blocks_a_deterministic_regression():
    """The live case, driven through the format the shell actually emits.

    Main's own table says it failed the id in 1 of 8 runs; the PR fails it 8 of 8
    with the SAME signature. A presence test ("it fails on main too") exempts this.
    The rate comparison must not: an eight-fold jump is a regression the PR
    introduced, and the fix that matters is the one that gets this right.
    """
    main = parse_rates("tests/a.py::T::t1\t1\t8\n")
    pr = {"tests/a.py::T::t1": Failure(rate=Rate(8, 8), signatures=frozenset({"sg"}))}
    decision = decide(
        pr, main.rates,
        main_signatures={"tests/a.py::T::t1": frozenset({"sg"})},
        k_pr=8, rate_tolerance=1.5,
    )
    assert [v.nodeid for v in decision.blocked] == ["tests/a.py::T::t1"]
    assert decision.visible_exemptions() == []
    assert "rates" in decision.report().lower() or "BLOCK" in decision.report()


def test_the_total_failure_blocks_through_the_real_wire_format():
    """The closed residual, driven through the table the shell actually emits.

    `main 6/8` vs `PR 8/8` is the case the MULTIPLICATIVE tolerance bridged:
    `1.00 <= 0.75 x 1.5`. It must BLOCK, and the verdict must name the total
    failure rather than a ratio, because the ratio has no information here.

    MUTATION: remove the totality guard -> this EXEMPTs (the measured false PASS)
    and the `visible_exemptions() == []` assertion REDs.
    """
    main = parse_rates("tests/a.py::T::t1\t6\t8\n")
    pr = {"tests/a.py::T::t1": Failure(rate=Rate(8, 8), signatures=frozenset({"sg"}))}
    decision = decide(
        pr, main.rates,
        main_signatures={"tests/a.py::T::t1": frozenset({"sg"})},
        k_pr=8, rate_tolerance=1.5,
    )
    assert [v.nodeid for v in decision.blocked] == ["tests/a.py::T::t1"]
    assert decision.visible_exemptions() == []
    assert "TOTAL" in decision.report()


def test_the_gate_does_not_loosen_as_the_substrate_degrades():
    """#3756's compounding finding, as a single assertion.

    Substrate flakiness puts more ids into main's union. Under presence-based
    subtraction each one becomes an exemption, so the gate's discriminating power
    FALLS as real health falls — confidence inversely coupled to health. Here main
    is BADLY broken (it fails 3 of 8 runs) and the SAME table must still block a PR
    at 8/8 — a 2.7x jump, far outside tolerance. The table cannot be read as
    "everything is excused".
    """
    main = parse_rates("tests/a.py::T::t1\t3\t8\n")
    innocent = {"tests/a.py::T::t1": Failure(rate=Rate(3, 8), signatures=frozenset({"sg"}))}
    d_ok = decide(innocent, main.rates, main_signatures={"tests/a.py::T::t1": frozenset({"sg"})},
                  k_pr=8)
    assert d_ok.visible_exemptions(), "the innocent PR must be exempt, visibly"

    worse = {"tests/a.py::T::t1": Failure(rate=Rate(8, 8), signatures=frozenset({"sg"}))}
    d_no = decide(worse, main.rates, main_signatures={"tests/a.py::T::t1": frozenset({"sg"})},
                  k_pr=8)
    assert not d_no.visible_exemptions(), "a PR worse than a broken main is still a regression"


# --------------------------------------------------------------------------
# Review cycle 1 — the two reproduced in-surface bypasses, as regression tests
# --------------------------------------------------------------------------


def test_E3_zero_main_rate_does_not_buy_the_strongest_exemption():
    """Bypass 1a: `main 0/8` vs `PR 8/8` printed as "rates equivalent".

    The guard was `mr.rate > 0 and ...`, so a ZERO main rate SKIPPED the comparison
    entirely: the weakest possible main evidence bought the strongest exemption. A
    PR failure main never had is a NEW failure, not an equivalent one.
    """
    main = parse_rates("tests/a.py::T::t1\t0\t8\n")
    pr = {"tests/a.py::T::t1": Failure(rate=Rate(8, 8), signatures=frozenset({"sg"}))}
    d = decide(pr, main.rates, main_signatures={"tests/a.py::T::t1": frozenset({"sg"})},
               k_pr=8)
    assert not d.visible_exemptions(), "0% vs 100% is not 'equivalent'"
    assert [v.nodeid for v in d.blocked] == ["tests/a.py::T::t1"]


def test_E3_the_default_call_still_applies_the_min_runs_floor():
    """Bypass 1b: the DEFAULT call had no floor and emitted no note.

    the floor used to be gated on a caller-declared `k_main`, and the block on
    truthiness, so a single-sample main row exempted silently. The declared K must
    come from the table itself when the caller does not state it.
    """
    main = parse_rates("tests/a.py::T::t1\t1\t1\n")  # a SINGLE sample
    pr = {"tests/a.py::T::t1": Failure(rate=Rate(1, 1), signatures=frozenset({"sg"}))}
    d = decide(pr, main.rates, main_signatures={"tests/a.py::T::t1": frozenset({"sg"})})
    assert not d.visible_exemptions(), "a single-sample main row must not exempt"
    assert any("insufficient evidence" in n for n in d.notes), d.notes


def test_E2_a_new_signature_alongside_mains_is_not_exempt():
    """Bypass 2: intersection exempted a PR that ADDED a new failing assertion.

    Intersection only asked "do the two sets share ANY failure", so a PR keeping
    main's assertion while introducing a new one was exempt — masking exactly the
    failure the PR introduced. The PR's signature set must be a SUBSET of main's.
    """
    main = parse_rates("tests/a.py::T::t1\t4\t8\n")
    pr = {"tests/a.py::T::t1": Failure(
        rate=Rate(5, 8), signatures=frozenset({"sg", "a-brand-new-assertion"}))}
    d = decide(pr, main.rates, main_signatures={"tests/a.py::T::t1": frozenset({"sg"})},
               k_pr=8)
    assert not d.visible_exemptions(), "a NEW assertion failure is not exempt"


def test_the_subset_rule_still_exempts_a_genuine_subset():
    """The legitimate form that must STAY green — the complement of bypass 2."""
    main = parse_rates("tests/a.py::T::t1\t4\t8\n")
    pr = {"tests/a.py::T::t1": Failure(rate=Rate(4, 8), signatures=frozenset({"sg"}))}
    d = decide(pr, main.rates, main_signatures={"tests/a.py::T::t1": frozenset({"sg"})},
               k_pr=8)
    assert d.visible_exemptions(), "a genuine subset at an equivalent rate IS exempt"


def test_the_k_main_knob_is_gone_not_silently_ignored():
    """A knob that is accepted but never read must not exist at all.

    `k_main` was a parameter of `decide()` that the body never consulted, while the
    docstring advertised "k_main below min_runs -> BLOCK". An accepted-but-ignored
    knob is the exact shape that produced this family of defects: the caller believes
    they set a floor and the verdict ignores it. The floor is per-id, so there is no
    caller-declared form; passing one must fail LOUDLY rather than be dropped.
    """
    main = parse_rates("tests/test_a.py::test_a11\t4\t8\n")
    pr = {"tests/test_a.py::test_a11": Failure(rate=Rate(4, 8), signatures=frozenset({"sg"}))}
    with pytest.raises(TypeError):
        decide(pr, main.rates, k_main=8)  # type: ignore[call-arg]
def test_min_runs_floor_is_PER_ID_not_table_wide():
    """Cycle-2 SURVIVOR: the floor was `max(runs)` over the WHOLE table.

    A row with `runs=1` was exempted whenever ANY OTHER row in the table had
    `>= min_runs` runs — and with NO insufficient-evidence note, because the global
    looked healthy. That is the permissive direction, and it violates the module's own
    invariant ("one observation cannot establish a rate"), which is a claim about THIS
    id's evidence. The earlier test built a SINGLE-ROW table, so `max(runs)` degenerated
    to that row's runs and the hole was structurally invisible.
    """
    main = parse_rates(
        "tests/test_a.py::test_a11\t1\t1\n"      # the id under test: ONE observation
        "tests/test_b.py::test_b48\t4\t8\n")     # a healthy row ELSEWHERE in the table
    pr = {"tests/test_a.py::test_a11": Failure(rate=Rate(1, 1), signatures=frozenset({"sg"}))}
    d = decide(pr, main.rates,
               main_signatures={"tests/test_a.py::test_a11": frozenset({"sg"})})
    assert not d.visible_exemptions(), (
        "a healthy OTHER row must not license THIS id's exemption")
    assert [v.nodeid for v in d.blocked] == ["tests/test_a.py::test_a11"]
    # The reviewer's required observation is `BLOCK, with the note`: a per-id block
    # that left `notes` empty would report the refusal without its reason. Asserted
    # here because the table-wide derivation must not be able to satisfy it.
    assert any("one observation cannot establish a rate" in n for n in d.notes), d.notes


def test_the_per_id_floor_still_exempts_a_genuinely_well_measured_row():
    """The legitimate form that must STAY green — complement of the survivor."""
    main = parse_rates(
        "tests/test_a.py::test_a11\t4\t8\n"
        "tests/test_b.py::test_b48\t1\t1\n")     # a thin row must not block THIS id
    pr = {"tests/test_a.py::test_a11": Failure(rate=Rate(4, 8), signatures=frozenset({"sg"}))}
    d = decide(pr, main.rates,
               main_signatures={"tests/test_a.py::test_a11": frozenset({"sg"})})
    assert d.visible_exemptions(), "a well-measured row at an equivalent rate IS exempt"


def test_a_duplicate_row_is_rejected_not_resolved_by_order():
    """Latent 2: row order decided the verdict.

    `"A 8 8" then "A 0 8"` yielded `Rate(0,8)` (→ no block) while the REVERSED order
    yielded `Rate(8,8)` (→ block). An order-dependence inside the verdict-stability
    class. A self-contradicting table is not evidence; the id gets NO rate, and no
    rate means not exempt.
    """
    a = parse_rates("tests/test_a.py::test_a11\t8\t8\ntests/test_a.py::test_a11\t0\t8\n")
    b = parse_rates("tests/test_a.py::test_a11\t0\t8\ntests/test_a.py::test_a11\t8\t8\n")
    assert a.rates == {} and b.rates == {}
    assert len(a.rejected) == 1 and len(b.rejected) == 1, (
        "the duplicate is the rejected row — the first is accepted, then withdrawn")
    assert a.rates == b.rates, "order must not decide the verdict"

    pr = {"tests/test_a.py::test_a11": Failure(rate=Rate(1, 8), signatures=frozenset({"sg"}))}
    d = decide(pr, a.rates, main_signatures={"tests/test_a.py::test_a11": frozenset({"sg"})})
    assert not d.visible_exemptions(), "no rate -> not exempt"


def test_a_duplicate_row_set_is_order_invariant_at_any_row_count():
    """#3766: the invariant is the ROW MULTISET, not one sampled shape of it.

    ``test_a_duplicate_row_is_rejected_not_resolved_by_order`` pinned the two-row
    case, and the guard it pinned withdrew an id by POPPING it -- so the
    withdrawal expired after the contradicting row and an ODD duplicate count put
    the id back. Three shards concatenated for one id (``8 8``, ``0 8``, ``1 8``)
    gave ``Rate(1,8)`` in one order and ``Rate(8,8)`` in the reverse: the SAME row
    multiset produced a BLOCK and an EXEMPT. Enumerating EVERY order is the
    assertion the invariant actually makes -- a two-order sample passes while the
    third row silently re-establishes the id, which is exactly the defect.

    **A permutation sweep is only as strong as the shape it permutes.** Permuting
    a single key whose rows are all valid and pairwise distinct pins the invariant
    for that one shape and lets a guard that is order-dependent one boundary away
    ship green. Each fixture below therefore CROSSES a boundary the module's
    claims are about, and each is enumerated in full:

    * the **key** boundary -- a clean second id must keep its rate in EVERY order.
      That is what separates a per-key withdrawal from a table-wide one: a global
      withdrawal refuses the clean id only when it arrives after the withdrawal, so
      the same multiset yields it a rate in one order and none in another. The
      withdrawal must also be keyed on the WHOLE nodeid, so the near-miss ids below
      each differ from the withdrawn id along one NAMED dimension and must survive a
      withdrawal keyed on the grouping their fixture is named for: the same file,
      the same function name across files, the same file BASENAME in another
      directory, the same CLASS (both sides of the pair class-bearing), a case-only
      variant, and a one-character extension. Exclusivity is not claimed -- two ids
      can be fused by more than one grouping at once (a same-file pair is fused by
      the file AND by the basename). A class-nested sibling is a SEPARATE case from
      a case-folding or file-prefix one, because a classless id has no class to
      share. That list is a hand-picked sample of an unbounded family; the
      exhaustive-over-pairs test below does not depend on it.
    * the **equality** boundary -- an EXACT repeat withdraws the id too. The rule
      is a second valid row (agreeing or disagreeing), not a disagreeing one, so a
      guard that refuses only on a *differing* rate is caught here.
    * the **validity** boundary -- a row the guards ABOVE reject (``failures >
      runs``, ``runs <= 0``, malformed) contributes nothing and cannot withdraw the
      id, so a valid sibling keeps its rate in every order. A withdrawal branch
      placed ABOVE those guards reads the same table the other way round -- and a
      rejection branch that CLEARS the withdrawn set is caught only when a later
      row of the SAME id follows the rejected one, so those fixtures carry one.
    * the **multiplicity** boundary -- TWO independently duplicated ids plus a third
      row for the first. One slot holding "the last duplicate" (rather than a set of
      withdrawn ids) passes every single-duplicate fixture above and is still
      order-dependent here.
    """
    key = "tests/test_a.py::test_a11"
    other = "tests/test_b.py::test_b48"
    # Near-miss ids: each differs from `key` along one named dimension.
    same_file = "tests/test_a.py::test_a12"
    same_name = "tests/test_b.py::test_a11"
    # A class-bearing id: `key` has NO class, so a class-sharing fixture needs one
    # that does. `class_key` of each side of this pair is identical (verified), which
    # is the dimension `key` cannot reach.
    cls = "tests/test_a.py::TestX::test_a11"
    cls_sib = "tests/test_a.py::TestX::test_a12"
    # The same dimension for a GUARD-STEP identity, whose class is the step.
    step = "guard-step::build::orphan-4-rows"
    step_sib = "guard-step::build::missing-3-artifact"
    # Same file BASENAME, other directory.
    same_basename = "tests/sub/test_a.py::test_a11"
    # A case-folding key is only split by two ids that differ in NOTHING but case --
    # a producer on a case-insensitive filesystem can emit either spelling.
    case_variant = "tests/TEST_A.py::test_a11"
    extended = "tests/test_a.py::test_a111"
    pr = {key: Failure(rate=Rate(8, 8), signatures=frozenset({"sg"}))}
    sig = {key: frozenset({"sg"})}

    def verdict_of(rates):
        d = decide(pr, rates, main_signatures=sig, k_pr=8)
        return (tuple(v.nodeid for v in d.blocked), tuple(d.visible_exemptions()))

    def as_key(rates):
        return tuple(sorted((k, v.failures, v.runs) for k, v in rates.items()))

    cases = [
        ("a duplicate pair, a clean sibling",
         [f"{key}\t8\t8", f"{key}\t0\t8", f"{other}\t4\t8"],
         {other: Rate(4, 8)}),
        ("an ODD duplicate count, a clean sibling",
         [f"{key}\t8\t8", f"{key}\t0\t8", f"{key}\t1\t8", f"{other}\t4\t8"],
         {other: Rate(4, 8)}),
        ("an EXACT repeat (agreeing, not disagreeing)",
         [f"{key}\t8\t8", f"{key}\t8\t8", f"{other}\t4\t8"],
         {other: Rate(4, 8)}),
        ("a duplicate beside an upper-guard-rejected row, with a LATER row of the "
         "same id (catches a rejection branch that clears the withdrawn set)",
         [f"{key}\t8\t8", f"{key}\t0\t8", f"{key}\t9\t8", f"{key}\t1\t8",
          f"{other}\t4\t8"],
         {other: Rate(4, 8)}),
        ("a malformed row between the pair and a LATER row of the same id "
         "(catches a malformed branch that clears the withdrawn set)",
         [f"{key}\t8\t8", f"{key}\t0\t8", "not a rate row", f"{key}\t1\t8",
          f"{other}\t4\t8"],
         {other: Rate(4, 8)}),
        ("an all-valid four-row duplicate, with a LATER row of the same id "
         "(catches an 'already withdrawn' branch that un-withdraws)",
         [f"{key}\t8\t8", f"{key}\t0\t8", f"{key}\t1\t8", f"{key}\t2\t8",
          f"{other}\t4\t8"],
         {other: Rate(4, 8)}),
        ("a duplicate pair with DIFFERENT RUN COUNTS (the withdrawal is keyed on "
         "the id, not on the id together with the run count)",
         [f"{key}\t8\t8", f"{key}\t0\t4"],
         {}),
        ("an ODD duplicate count with different run counts",
         [f"{key}\t0\t4", f"{key}\t1\t4", f"{key}\t8\t8"],
         {}),
        ("two independently duplicated ids",
         [f"{key}\t8\t8", f"{key}\t0\t8", f"{key}\t1\t8",
          f"{other}\t4\t8", f"{other}\t5\t8"],
         {}),
        ("a clean sibling in the SAME FILE",
         [f"{key}\t8\t8", f"{key}\t0\t8", f"{same_file}\t4\t8"],
         {same_file: Rate(4, 8)}),
        ("a clean sibling with the SAME FUNCTION NAME",
         [f"{key}\t8\t8", f"{key}\t0\t8", f"{same_name}\t4\t8"],
         {same_name: Rate(4, 8)}),
        ("a clean sibling that SHARES A CLASS with the withdrawn id",
         [f"{cls}\t8\t8", f"{cls}\t0\t8", f"{cls_sib}\t4\t8"],
         {cls_sib: Rate(4, 8)}),
        ("the same, for a GUARD-STEP identity (its class is the step)",
         [f"{step}\t8\t8", f"{step}\t0\t8", f"{step_sib}\t4\t8"],
         {step_sib: Rate(4, 8)}),
        ("a class-NESTED sibling of the same file and leaf",
         [f"{key}\t8\t8", f"{key}\t0\t8", f"{cls}\t4\t8"],
         {cls: Rate(4, 8)}),
        ("a clean sibling with the SAME FILE BASENAME, other dir",
         [f"{key}\t8\t8", f"{key}\t0\t8", f"{same_basename}\t4\t8"],
         {same_basename: Rate(4, 8)}),
        ("a clean id differing only in CASE (splits a case-folding key)",
         [f"{key}\t8\t8", f"{key}\t0\t8", f"{case_variant}\t4\t8"],
         {case_variant: Rate(4, 8)}),
        ("a clean id that EXTENDS the withdrawn one by one character",
         [f"{key}\t8\t8", f"{key}\t0\t8", f"{extended}\t4\t8"],
         {extended: Rate(4, 8)}),
        ("a valid row shadowed by an upper-guard rejection",
         [f"{key}\t8\t8", f"{key}\t9\t8"], {key: Rate(8, 8)}),
        ("a valid row shadowed by runs <= 0",
         [f"{key}\t8\t8", f"{key}\t8\t0"], {key: Rate(8, 8)}),
        ("a valid row beside a malformed line",
         [f"{key}\t8\t8", "not a rate row"], {key: Rate(8, 8)}),
    ]
    for label, rows, expected in cases:
        tables, rejected_counts, verdicts = set(), set(), set()
        for order in itertools.permutations(rows):
            main = parse_rates("\n".join(order) + "\n")
            tables.add(as_key(main.rates))
            rejected_counts.add(len(main.rejected))
            verdicts.add(verdict_of(main.rates))

        assert tables == {as_key(expected)}, (
            f"{label}: row order decided the rate table")
        assert len(rejected_counts) == 1, (
            f"{label}: the NUMBER of rejected rows must not depend on row order -- "
            "which rows are reported is the module's reporting policy and may "
            "legitimately differ")
        assert verdicts == {verdict_of(expected)}, (
            f"{label}: every order of one row multiset must yield the SAME verdict -- "
            "row order must never decide whether the PR blocks")

    # A withdrawal must not EXPIRE, and a bounded lifetime does not live on the
    # permutation axis -- it lives on the rows that ARRIVE after it. A bound of N
    # is defeated by a table with MORE rows following the withdrawal, so the sweep
    # grows what follows. The following rows are OTHER keys on purpose: a later row
    # of the WITHDRAWN key is itself refused, so only an ACCEPTED row can expire
    # anything, and a fixture whose only accepted row sits after every row of the
    # withdrawn key cannot see a bound at all. The run counts deliberately DIFFER
    # between the rows of the withdrawn id, so a withdrawal keyed on (id, runs)
    # rather than on the id is not left unpinned by the ladder either.
    #
    # FORWARD (withdrawal first, then n accepted rows, then one more row of the
    # withdrawn key): the ladder itself catches a bound up to 257 accepted rows --
    # measured, with the largest n=256 supplying 256 filler accepts plus the first
    # row of the withdrawn key. REVERSED (a row of the withdrawn key accepted BEFORE
    # the withdrawal): pins that a withdrawal also removes an id already in the
    # table, which no forward order can show.
    #
    # RESIDUAL, stated rather than implied: the suite's reach is 300 accepted rows --
    # the 300-duplicated-id scale test below supplies those, and a bound of 301 or
    # larger still escapes. No finite sweep can exclude one: "permanent" is a
    # universally quantified claim over table sizes and is not provable by black-box
    # sampling. The structural half of the guarantee is the shape of the code, not
    # this test: the withdrawn set is a bare local that is only ever ADDED to, and
    # membership is tested before the accept path.
    for n in (1, 2, 3, 5, 8, 16, 64, 256):
        fillers = [f"tests/test_f{i}.py::test_f1" for i in range(n)]
        rows = ([f"{key}\t8\t8", f"{key}\t0\t4"]
                + [f"{f}\t4\t8" for f in fillers]
                + [f"{key}\t1\t4"])
        for order in (rows, list(reversed(rows))):
            main = parse_rates("\n".join(order) + "\n")
            assert main.rates == {f: Rate(4, 8) for f in fillers}, (
                f"n={n}: a withdrawal must not expire -- no later row, however many "
                "arrive, may re-establish a withdrawn id")

    # The ladder above grows only ACCEPTED rows. A bound on any other counter is
    # invisible to it, so the same shape is repeated with rows that are REJECTED
    # instead. Each rejection KIND gets its own interleaved fixture, because the
    # module refuses them at different places -- a malformed line and a
    # whitespace-only line are refused in their own branches, while ``runs <= 0``,
    # ``failures > runs`` and not-a-failure-key are separate sub-conditions of the
    # ONE validity guard -- so a clear keyed to any single sub-condition must be
    # crossed too.
    rejected_rows = [
        "not a rate row",                             # no tab-separated fields
        "   ",                                        # blank after strip -> skipped
        "tests/test_r.py::test_r1\t8\t0",              # runs <= 0
        "tests/test_r.py::test_r1\t9\t8",              # failures > runs
        "notakey\t1\t8",                              # not a failure key
    ]
    for kind in rejected_rows:
        # Adjacent to the pair, with a LATER row of the same id: this is the shape
        # that exposes a branch which clears the withdrawn set. Run counts differ.
        rows = [f"{key}\t8\t8", f"{key}\t0\t4", kind, f"{key}\t1\t4"]
        for order in itertools.permutations(rows):
            assert parse_rates("\n".join(order) + "\n").rates == {}, (
                f"a rejection of kind {kind!r} expired a withdrawal")
    for n in (1, 2, 8, 64, 256):
        rows = ([f"{key}\t8\t8", f"{key}\t0\t4"]
                + [rejected_rows[i % len(rejected_rows)] for i in range(n)]
                + [f"{key}\t1\t8"])
        for order in (rows, list(reversed(rows))):
            assert parse_rates("\n".join(order) + "\n").rates == {}, (
                f"n={n}: no rejection -- of any kind -- may expire a withdrawal")


#: Structural neighbours of one nodeid: ids that differ from a given id along ONE
#: dimension a key derivation could use (file, directory, file basename, leaf,
#: leaf prefix/suffix, case, class, bracket/parametrize id, step). A withdrawal
#: keyed on ANY of those coarser dimensions fuses two of these ids and is refused
#: by the pairwise sweep below.
_WITHDRAWAL_KEY_POOL = [
    "tests/test_a.py::test_a11",
    "tests/test_a.py::test_a1",
    "tests/test_a.py::test_a111",
    "tests/test_a.py::test_a11.extra",
    "tests/test_a.py::test_a11[x]",
    "tests/test_a.py::test_a11[y]",
    "tests/test_a.py::test_a11[1-2]",
    "tests/test_a.py::TEST_A11",
    "tests/test_a.py::test_a12",
    "tests/test_b.py::test_a11",
    "tests/test_b.py::test_b48",
    "tests/test_a.py::TestX::test_a11",
    "tests/test_a.py::TestX::test_a12",
    "tests/test_a.py::TestX::test_a11[x]",
    "tests/test_a.py::TestY::test_a11",
    "tests/TEST_A.py::test_a11",
    "tests/tests_a.py::test_a11",
    "tests/unit/test_a.py::test_a11",
    "tests/sub/test_a.py::test_a11",
    "tests/test-a.py::test_a11",
    "guard-step::build::orphan-4-rows",
    "guard-step::build::orphan-5-rows",
    "guard-step::build::missing-3-artifact",
    "guard-step::test::orphan-4-rows",
]


def test_the_withdrawal_is_keyed_on_the_whole_nodeid_for_every_pair_of_ids():
    """#3766: EXHAUSTIVE over every PAIR of ids, not over a hand-picked list.

    The sweep in the test above enumerates the dimensions a key derivation might
    use, one fixture per dimension -- which means it can only catch a derivation
    whose dimension somebody thought to write down. The property is really about
    DISTINCTNESS: duplicating one id must not change any OTHER id's rate, and two
    ids the module treats as the same id are by definition not distinct. That is
    decidable by enumeration over the ids themselves.

    So this test takes a pool of structurally adjacent ids -- same file, same
    directory, same file basename, leaf prefix and suffix, case variant, class
    suffix, bracket/parametrize id, step -- and asserts the property for EVERY
    ordered pair of DISTINCT ids in it, over every order of the three rows. A
    withdrawal keyed on any derivation that fuses two pool ids into one is caught
    wherever it lands, without that derivation having been enumerated in advance:
    the pool supplies the colliding pair for the enumeration instead of a fixture
    having to guess it. Checked as a pair invariant, it also refuses a withdrawal
    key that fuses the pair in one direction only.

    What it does NOT reach: a derivation that fuses two ids which are NOT both in
    the pool. That residual is unbounded in principle (any function of the nodeid),
    and it is why the pool is structurally diverse rather than a sample -- but it is
    still a finite pool, and the residual is stated, not closed.
    """
    pool = _WITHDRAWAL_KEY_POOL
    for dup in pool:
        for sibling in pool:
            if sibling == dup:
                continue
            rows = [f"{dup}\t8\t8", f"{dup}\t0\t4", f"{sibling}\t4\t8"]
            for order in itertools.permutations(rows):
                rates = parse_rates("\n".join(order) + "\n").rates
                assert rates == {sibling: Rate(4, 8)}, (
                    f"withdrawing {dup!r} changed the rate of {sibling!r} -- the "
                    "withdrawal is not keyed on the whole nodeid")


def test_a_duplicated_id_leaves_no_rate_for_every_id_in_the_pool():
    """#3766: the shape the pair sweep above CANNOT see.

    The pair sweep always follows a duplicated id with a DIFFERENT id, so it never
    re-checks the withdrawn id itself. That is a structural blind spot, not a
    property of the ids it happens to use: it stays blind even though its pool
    already carries class-bearing and guard-step ids. The slip it cannot see is a
    withdrawal RECORDED under a derived key while membership is TESTED under the
    raw nodeid (or the mirror) -- harmless whenever the derivation is the IDENTITY
    on the duplicated id, because then the third, DIFFERENT id is what gets tested
    and the derived key never has to match the withdrawn id.

    The mismatch bites only when the derivation is non-identity on the duplicated
    id AND a later row IS that same id: the derived key does not match, the id is
    not recognised as withdrawn, and it is accepted with a rate it must not have.

    So every id in the pool also gets a shape whose three rows are the SAME id,
    with BOTH columns pairwise distinct (runs 8/4/2, failures 8/0/1), so a slip
    keyed on the id plus either number is crossed in every order. The pool contains
    class-bearing, guard-step, bracketed and case-variant ids, so at least one of
    them makes the add/check mismatch non-identity and the assertion fails; the
    shipped code leaves no rate in every order.
    """
    for dup in _WITHDRAWAL_KEY_POOL:
        rows = [f"{dup}\t8\t8", f"{dup}\t0\t4", f"{dup}\t1\t2"]
        for order in itertools.permutations(rows):
            rates = parse_rates("\n".join(order) + "\n").rates
            assert rates == {}, (
                f"{dup!r} left a rate behind -- its withdrawal was recorded under a "
                "key its own later rows do not match")


def test_the_withdrawn_set_is_neither_capacity_nor_budget_bounded():
    """#3766: a withdrawn set is a SET, not a fixed-size cache or a budget.

    The fixtures above duplicate at most two ids, so a withdrawal structure that
    keeps only the last N ids (a FIFO / LRU / two-slot cache) is invisible to them,
    and the lifetime ladder grows only ACCEPTED rows, so a bound measured on any
    other counter is invisible too. Both are order-dependent once the table is big
    enough: the id that fell out of the cache is re-established by a later row.

    Scale is the only axis that reaches them, so this test scales: many
    INDEPENDENTLY duplicated ids, followed by a further row of the FIRST and of the
    LAST one. Neither may reappear. The trailing rows are placed last on purpose --
    an evicted id is re-established precisely by a row that arrives after the
    eviction.

    REACH, stated rather than implied: a capacity of 300 or more is NOT reached by
    300 duplicated ids (measured: 299 REDs, 300 does not), for the same reason the
    lifetime ladder cannot exclude an arbitrarily large bound -- "bounded by a
    constant" is not falsifiable by a finite test. What this arm does establish is
    that the reach is set by the TEST's scale and not by any constant in the module,
    which is the direction a regression would move. It also supplies the 300 accepted
    rows that the lifetime residual above refers to.
    """
    n_ids = 300
    ids = [f"tests/test_scale.py::test_s{i}" for i in range(n_ids)]
    rows = []
    for nodeid in ids:
        rows += [f"{nodeid}\t8\t8", f"{nodeid}\t0\t4"]
    rows += [f"{ids[0]}\t1\t4", f"{ids[-1]}\t2\t4", "not a rate row"]
    for order in (rows, list(reversed(rows))):
        assert parse_rates("\n".join(order) + "\n").rates == {}, (
            "an id that fell out of a bounded withdrawal structure was "
            f"re-established -- all {n_ids} duplicated ids must stay withdrawn")

    # The same scale, one id only, to reach a budget measured on the whole table's
    # row count rather than on the withdrawn set: 1024 rows for one id, then one
    # more.
    many = [f"tests/test_scale.py::test_one\t8\t8",
            f"tests/test_scale.py::test_one\t0\t4"]
    many += [f"tests/test_scale.py::test_one\t{k % 8}\t8" for k in range(1024)]
    many += ["tests/test_scale.py::test_one\t1\t4"]
    assert parse_rates("\n".join(many) + "\n").rates == {}, (
        "a budget measured on the table's own size expired a withdrawal")
    assert parse_rates("\n".join(reversed(many)) + "\n").rates == {}


def test_a_pr_failure_with_an_empty_sample_is_not_exempt():
    """Latent 1: `Rate(3, 0)` has `.rate == 0.0` and slipped into EXEMPT while the
    note claimed 'pr sample empty — treating every failure as PR-side', the opposite.
    """
    main = parse_rates("tests/test_a.py::test_a11\t4\t8\n")
    pr = {"tests/test_a.py::test_a11": Failure(rate=Rate(3, 0), signatures=frozenset({"sg"}))}
    d = decide(pr, main.rates, main_signatures={"tests/test_a.py::test_a11": frozenset({"sg"})})
    assert not d.visible_exemptions(), "an unmeasurable PR rate is not an exemption"
    assert [v.nodeid for v in d.blocked] == ["tests/test_a.py::test_a11"]


# --------------------------------------------------------------------------
# REQUIRED CLASS E5 — ROTATING IDENTITY (a changing identity is not novel)
# --------------------------------------------------------------------------

_CLS = "tests/test_dr_endpoints.py::TestDrDrillScheduled"
_A = f"{_CLS}::test_rto_breach_opens_incident"
_B = f"{_CLS}::test_manual_drill_records_measured_time"
_C = f"{_CLS}::test_status_surfaces_last_drill"


def test_E5_a_rotating_id_is_unattributable_neither_blocked_nor_exempt():
    """The measured refusal (B6 on #3577): one class, red in 3 runs, 3 different ids.

    Run 1 failed {A, B}; runs 2-3 failed {C}. The CLASS stayed red; the IDENTITY moved.
    Neither attribution is supported: it is not "unique to this PR" (false-block) and it
    is not exempt (false-PASS) — the verdict must be UNATTRIBUTABLE.
    """
    rotating = detect_rotating_identity([
        frozenset({_A, _B}), frozenset({_C}), frozenset({_C}),
    ])
    assert set(rotating) == {_CLS}
    assert rotating[_CLS] == frozenset({_A, _B, _C})

    main = parse_rates(f"{_C}\t1\t8\n")   # main happens to have seen C — must still not exempt
    pr = {_A: Failure(rate=Rate(1, 1), signatures=frozenset({"sg"}))}
    d = decide(pr, main.rates, main_signatures={_A: frozenset({"sg"})}, rotating=rotating)

    assert [v.nodeid for v in d.unattributable] == [_A]
    assert not d.visible_exemptions(), "a rotating id must NEVER be exempt"
    # it must not be reported as a PR-unique failure
    assert all(v.nodeid != _A for v in d.blocked), (
        "a rotating id must not be attributed to the PR")


def test_E5_a_STABLE_id_is_still_ordinary():
    """The legitimate form: a class red with the SAME id across runs is not rotating,
    so the normal rules apply and a genuine main-side match can still be exempt."""
    rotating = detect_rotating_identity([
        frozenset({_A}), frozenset({_A}), frozenset({_A}),
    ])
    assert rotating == {}, "a stable id is not a rotating identity"

    main = parse_rates(f"{_A}\t4\t8\n")
    pr = {_A: Failure(rate=Rate(4, 8), signatures=frozenset({"sg"}))}
    d = decide(pr, main.rates, main_signatures={_A: frozenset({"sg"})}, rotating=rotating)
    assert d.visible_exemptions(), "a stable, well-measured match is still exempt"
    assert not d.unattributable


def test_E5_a_single_run_cannot_establish_rotation():
    """One sample cannot distinguish 'moved' from 'not yet moved' — fail closed to the
    ordinary rules rather than inventing rotation."""
    assert detect_rotating_identity([frozenset({_A, _B})]) == {}


# ── the suite must load THE RAIL'S OWN FILE, never a copy ─────────────────


def test_tests_load_the_file_the_rail_execs():
    """FROM A SOURCE REPO, ONLY THE CONSUMER'S OWN COPY COUNTS.

    This suite is worth exactly what it is worth against the file the rail runs.
    `scripts/admin-merge.sh` points `EXEMPTION_PY` at `$SELF_DIR/ci_exemption.py`
    and execs it by path (line 256). If this module were ever loaded from
    somewhere else — a vendored `tools/ci_exemption.py`, a fixture, a stale
    checkout — the suite would stay green while the REAL decision module drifted:
    a false-PASS generator, the class #3756 exists to eliminate.

    Pinned as a test so the retarget cannot happen silently: repointing either
    side REDs here.
    """
    repo_root = Path(__file__).resolve().parents[1]
    rail = repo_root / "scripts" / "admin-merge.sh"
    assert rail.is_file(), f"the consumer rail is missing at {rail}"

    # `SELF_DIR` is the rail's own directory, so the module it execs is
    # scripts/ci_exemption.py — the very file loaded above.
    assert 'EXEMPTION_PY="$SELF_DIR/ci_exemption.py"' in rail.read_text(
        encoding="utf-8"
    ), "the rail no longer points EXEMPTION_PY at its own ci_exemption.py"

    assert Path(ci_exemption.__file__).resolve() == (
        repo_root / "scripts" / "ci_exemption.py"
    ).resolve(), f"the suite loaded a DIFFERENT file: {ci_exemption.__file__}"


# ==========================================================================
# #4469 — GUARD-STEP ATTRIBUTION
# ==========================================================================
#
# THE DEFECT. The id universe was pytest nodeids ONLY, so a failing run whose
# failure lived in a non-pytest GUARD STEP yielded NO id. `examined=1 /
# extracted=0` then tripped the rail's fail-closed refusal — "yielded NO
# parseable 'FAILED <nodeid>' line … This is a refusal" — and a green,
# review-clean PR could not be merged through the sanctioned path, although the
# failure was a real, attributable, and FLAKY guard owned by another lane.
#
# THE FIX under test attributes the guard-step failure as an identity in the set,
# so the PR-vs-main comparison runs exactly as it does for a test nodeid. The
# refusal is PRESERVED for a run that carries neither a nodeid nor a substantive
# annotation (the runner's own `Process completed with exit code <N>.` is not
# one — it is emitted for the pytest step too).
#
# GROUNDED IN THE REAL CAPTURE: tortoise PR #4672, run 35785085760
# (`gh run view --log-failed`, 2026-09-23). `pytest` exited rc 0; the failing
# step was the post-suite orphan guard. The echoed script SOURCE is included
# DELIBERATELY: a mid-line search for `::error::` would manufacture a second,
# `$COUNT`-bearing identity for the same run, and this fixture makes that
# regression a RED.
_GUARD_JOB = "test (b)"
_GUARD_STEP = "Assert no redislite orphans (issue"
_GUARD_KEY = (
    "guard-step::Assert-no-redislite-orphans-issue::"
    "redislite-server-leak-N-orphans-after-suite-threshold-N-issue-N-epic-N-E2E--N"
)
_GUARD_SIG = (
    "redislite server leak: <N> orphans after suite, threshold <N> "
    "(issue #<N> / epic #<N> E2E-<N>)"
)
_GUARD_RUNNER_EXIT = "##[error]Process completed with exit code 1."


def _real_capture(orphans: int = 16) -> str:
    """The production `--log-failed` shape, byte-shaped like the measured run."""
    prefix = f"{_GUARD_JOB}\t{_GUARD_STEP}\t"
    echo_source = (
        '2026-09-23T01:19:53.8474165Z \x1b[36;1m    echo "::error::redislite server'
        ' leak: $COUNT orphans after suite, threshold $THRESHOLD (issue #1005 /'
        ' epic #1647 E2E-7)"\x1b[0m'
    )
    lines = [
        # The echoed script source — the annotation marker is MID-LINE here.
        prefix + echo_source,
        prefix
        + "2026-09-23T01:19:53.8634323Z orphaned redislite servers after suite:"
        + f" {orphans} (pytest rc: 0, threshold: 12)",
        prefix
        + f"2026-09-23T01:19:53.8645102Z ##[error]redislite server leak: {orphans}"
        + " orphans after suite, threshold 12 (issue #1005 / epic #1647 E2E-7)",
        prefix + f"2026-09-23T01:19:53.8649910Z {_GUARD_RUNNER_EXIT}",
        # The aggregate gate step: the runner's generic annotation ONLY.
        "python-ci-gate\tAggregate matrix result\t2026-09-23T01:20:00.3040113Z "
        + _GUARD_RUNNER_EXIT,
    ]
    return "\n".join(lines) + "\n"


def test_guard_step_failure_is_attributed_from_the_real_capture():
    """The measured guard step becomes ONE id, with the measured signature.

    MUTATION: drop the guard pass from ``parse_failed_ids`` → ``ids == []`` and
    ``ok is False`` → RED (and the rail refuses the run forever).
    MUTATION: search for the annotation marker anywhere instead of anchoring it
    → the echoed `echo "::error::… $COUNT …"` line adds a SECOND, `$COUNT`-bearing
    id → the exact-key and one-id assertions RED.
    MUTATION: treat the runner's generic exit annotation as attribution → the
    aggregate gate step adds a third id → RED.
    """
    parsed = parse_failed_ids(_real_capture(), raw_log=True)

    assert parsed.ids == [_GUARD_KEY]
    assert parsed.guard_steps == [_GUARD_KEY]
    assert parsed.rejected == []
    assert parsed.ok is True, "an attributed run is no longer an unreadable set"


def test_guard_step_identity_masks_the_run_varying_count():
    """16 orphans and 14 orphans are the SAME guard failure.

    MUTATION: remove the integer mask from ``normalize_guard_error`` → the two
    captures yield two different keys → this REDs, and the same guard on main can
    never match the PR (the failure would read as PR-unique forever).
    """
    a = parse_failed_ids(_real_capture(16), raw_log=True)
    b = parse_failed_ids(_real_capture(14), raw_log=True)

    assert a.ids == b.ids == [_GUARD_KEY]


def test_guard_step_discrimination_is_preserved():
    """Two DIFFERENT guard errors in one step do NOT collapse into one identity.

    The integer mask is the declared trade; this pins its boundary — the error
    TEXT still discriminates, so masking numbers is not a blanket equality.
    """
    other = _real_capture().replace(
        "redislite server leak:", "redislite server leak detected:"
    )
    parsed = parse_failed_ids(other, raw_log=True)

    assert parsed.ids and parsed.ids != [_GUARD_KEY]
    assert _GUARD_KEY not in parsed.ids


def test_guard_step_failure_is_compared_against_the_main_union():
    """THE POINT: the attributed guard id participates in the decision.

    Main's own rate table carries the SAME guard identity (measured over the
    ``min_runs`` floor) with the same error shape; the PR failed it at an
    equivalent rate. Before this change there was no id to compare and the rail
    simply refused; now the decision runs and EXEMPTS it, visibly.
    """
    key = parse_failed_ids(_real_capture(17), raw_log=True).ids[0]
    main_rates = parse_rates(f"{key}\t3\t8\n")

    assert main_rates.rejected == []
    assert main_rates.rates[key] == Rate(3, 8)

    decision = decide(
        {key: Failure(rate=Rate(3, 8), signatures=frozenset({_GUARD_SIG}))},
        main_rates.rates,
        main_signatures={key: frozenset({_GUARD_SIG})},
        k_pr=8,
    )

    assert not decision.any_blocked
    assert decision.visible_exemptions(), "the guard exemption must be RECORDED"
    assert key in decision.visible_exemptions()[0]


def test_guard_step_absent_from_main_still_blocks():
    """The other direction: an id absent from main is NOT exempt — it BLOCKS.

    The change widens what is PARSEABLE, never what is EXCUSED. A guard failure
    main never carried is still a PR-unique failure.
    """
    decision = decide(
        {_GUARD_KEY: Failure(rate=Rate(3, 8), signatures=frozenset({_GUARD_SIG}))},
        {},
        main_signatures={},
        k_pr=8,
    )

    assert decision.any_blocked
    assert "no main-side measurement" in decision.blocked[0].reason


def test_a_pytest_nodeid_is_never_re_keyed_as_a_guard_step():
    """NO REGRESSION on the existing id class: a FAILED nodeid stays a nodeid.

    MUTATION: route every line through the guard path → the nodeid would leave
    the set (or gain a phantom guard twin) → RED.
    """
    parsed = parse_failed_ids(f"FAILED {ID}\n", raw_log=True)

    assert parsed.ids == [ID]
    assert parsed.guard_steps == [], "a nodeid is not a guard-step identity"


def test_the_two_id_classes_coexist_and_stay_distinct():
    """A run may carry BOTH (failing tests AND a failing guard) — both count."""
    parsed = parse_failed_ids(f"FAILED {ID}\n" + _real_capture(), raw_log=True)

    assert parsed.ids == sorted([ID, _GUARD_KEY])
    assert parsed.guard_steps == [_GUARD_KEY]


def test_the_fail_closed_refusal_survives_the_widening():
    """A run carrying NEITHER a nodeid NOR a substantive annotation is REFUSED.

    This is the exact shape the refusal exists for — "the log format moved" /
    "the run failed outside the test step": pytest rc≠0 with no `FAILED` line.
    The only annotation such a run carries is the runner's own generic exit line,
    which names no failure and must NOT be an identity. Without this test, the
    widening would have silently converted every unparseable run into a
    certificate.
    """
    moved = (
        "test (a)\tRun fast test suite\t2026-09-23T01:00:00.0000000Z "
        + _GUARD_RUNNER_EXIT
        + "\n"
    )
    parsed = parse_failed_ids(moved, raw_log=True)

    assert parsed.ids == [], "the runner's own exit annotation is NOT an identity"
    assert parsed.guard_steps == []
    assert parsed.ok is False, "an unreadable failure set must still read as such"


def test_a_stripped_capture_with_no_step_head_is_not_attributable():
    """No ``<job>\t<step>\t<ts> `` head → no step → NO attribution.

    gh always emits the head, so a head-less capture is hand-made input; the
    module must not found an attribution on a step it cannot name (see
    ``_split_log_line``). Before the root-step rule, this fixture asserted an
    ``unknown``-keyed identity — exactly the step INVENTION that rule removes.

    MUTATION: re-invent the step for a head-less line
    (``guard_step_key('', …)``) → ``ids == []`` REDs.
    """
    parsed = parse_failed_ids(
        "##[error]packaging guard: wheel is missing\n", raw_log=True
    )

    assert parsed.ids == []
    assert parsed.guard_steps == []
    assert parsed.ok is False


def test_an_unparseable_test_failure_is_not_laundered_by_a_sibling_guard():
    """A run's ROOT failure cannot be replaced by a sibling annotation.

    The cycle-3 false certificate step 1c exists for: pytest fails with
    ``ImportError: no module named y`` — no ``FAILED`` line, so the run yields NO
    id — and the SAME run also carries a legitimate guard-step annotation. Under
    an unqualified widening the sibling supplies an id, ``examined > extracted``
    stops firing, and the decision certifies a run whose real failure was never
    classified. (Found by three reviewers on this PR, reproduced against the
    shipped module.)

    The ROOT failing step — the first the runner marked — is the pytest step, and
    it yields nothing, so the run contributes NO identity of any kind.

    MUTATION: drop the ``failing[0] not in evidence`` condition → ``ids == []``
    REDs (and ``guard_steps == []`` with it).
    """
    mixed = (
        "test (a)\tRun fast test suite\t2026-09-23T01:00:00.0000000Z "
        "E   ImportError: no module named y\n"
        "test (a)\tRun fast test suite\t2026-09-23T01:00:01.0000000Z "
        + _GUARD_RUNNER_EXIT
        + "\n"
        + _real_capture()
    )
    parsed = parse_failed_ids(mixed, raw_log=True)

    assert parsed.ids == [], "the root failing step yielded nothing to attribute"
    assert parsed.guard_steps == []
    assert parsed.ok is False, "the rail must still REFUSE this run (step 1c)"


def test_a_same_named_step_in_another_matrix_leg_is_not_evidence():
    """Two matrix legs run same-NAMED steps — the step is (job, step), not a name.

    Cycle-2 review, reproduced: with the bookkeeping keyed on the step NAME alone,
    leg ``a``'s unparseable failure was attested by leg ``b``'s guard annotation
    (same step name, different job), so the run was attributed and leg ``a``'s real
    failure stayed invisible. (The ``E   `` clause also refuses this capture; the
    keying must too — see the non-pytest fixture below, which has no ``E   ``.)

    MUTATION: key ``failing``/``evidence`` on the step name only → ``ids == []``
    REDs.
    """
    collision = (
        "test (a)\tRun fast test suite\t2026-09-23T01:00:00.0000000Z "
        "E   ImportError: no module named y\n"
        "test (a)\tRun fast test suite\t2026-09-23T01:00:01.0000000Z "
        + _GUARD_RUNNER_EXIT
        + "\n"
        "test (b)\tRun fast test suite\t2026-09-23T01:00:02.0000000Z "
        "##[error]packaging guard: wheel is missing\n"
        "test (b)\tRun fast test suite\t2026-09-23T01:00:03.0000000Z "
        + _GUARD_RUNNER_EXIT
        + "\n"
    )
    parsed = parse_failed_ids(collision, raw_log=True)

    assert parsed.ids == [], "a sibling LEG's step name is not the root failure"
    assert parsed.ok is False


def test_a_same_named_step_in_another_matrix_leg_is_not_evidence_without_e_line():
    """The same collision with NO pytest-shaped line: the (job, step) key refuses.

    Isolates the keying clause from the ``E   `` clause — a non-pytest unparseable
    failure in leg ``a`` must not be attested by leg ``b``'s same-named step.
    """
    collision = (
        "test (a)\tRun fast test suite\t2026-09-23T01:00:00.0000000Z "
        "ImportError: no module named y\n"
        "test (a)\tRun fast test suite\t2026-09-23T01:00:01.0000000Z "
        + _GUARD_RUNNER_EXIT
        + "\n"
        "test (b)\tRun fast test suite\t2026-09-23T01:00:02.0000000Z "
        "##[error]packaging guard: wheel is missing\n"
        "test (b)\tRun fast test suite\t2026-09-23T01:00:03.0000000Z "
        + _GUARD_RUNNER_EXIT
        + "\n"
    )
    parsed = parse_failed_ids(collision, raw_log=True)

    assert parsed.ids == [], "the ROOT leg failed and yielded nothing"
    assert parsed.ok is False


def test_a_pytest_failure_line_must_yield_a_nodeid_not_an_annotation():
    """A step showing pytest's own failure output must produce a NODEID.

    Cycle-2 review, reproduced: when the ROOT step both fails unparseably
    (``E   ImportError``) and prints a wrapper annotation, the annotation satisfied
    the root condition and ``decide`` certified the run off a key that never named
    the failure. An annotation is not pytest's classification.

    MUTATION: drop the ``e_line_steps - nodeid_steps`` clause → ``ids == []``
    REDs.
    """
    wrapped = (
        "test (a)\tRun fast test suite\t2026-09-23T01:00:00.0000000Z "
        "E   ImportError: no module named y\n"
        "test (a)\tRun fast test suite\t2026-09-23T01:00:01.0000000Z "
        "##[error]tests failed\n"
        "test (a)\tRun fast test suite\t2026-09-23T01:00:02.0000000Z "
        + _GUARD_RUNNER_EXIT
        + "\n"
    )
    parsed = parse_failed_ids(wrapped, raw_log=True)

    assert parsed.ids == [], "pytest reported a failure the parser did not classify"
    assert parsed.ok is False


def test_an_explained_pytest_failure_line_does_not_refuse_the_run():
    """The ``E   `` clause is bound to the NODEID, not to the shape of any text.

    A parsed nodeid explains pytest's output for its step, so a run carrying both
    a nodeid and ``E   `` lines is fully attributed — the clause must not become a
    blanket refusal of every pytest log.
    """
    parsed = parse_failed_ids(
        f"test (a)\tRun fast test suite\t2026-09-23T01:00:00.0000000Z "
        f"E   AssertionError: 1 != 2\n"
        f"test (a)\tRun fast test suite\t2026-09-23T01:00:01.0000000Z FAILED {ID}\n",
        raw_log=True,
    )

    assert parsed.ids == [ID]


_RUNNER_WRAPPERS = (
    "##[error]Process completed with exit code 1.",
    "##[error]Bash exited with code '1'.",
    "##[error]The process '/usr/bin/bash' failed with exit code 1.",
    "##[error]Docker failed with exit code 1",
    "##[error]Failed to run container step: exec format error",
    "##[error]Failed to initialize containers, pull access denied",
    "##[error]The action 'actions/checkout@v4' has timed out after 10 minutes.",
)


@pytest.mark.parametrize("wrapper", _RUNNER_WRAPPERS)
def test_no_runner_or_hook_wrapper_is_ever_an_identity(wrapper):
    """EVERY harness wrapper is excluded — and the list is pinned in full.

    Cycle-3 review, reproduced on the container hooks: `Docker failed with exit
    code 1` was absent from a three-entry denylist, so a container step that failed
    for a reason the parser did not classify became a
    `guard-step::…Docker-failed-with-exit-code-N` identity, satisfied
    `examined > extracted`, and could then be EXEMPTED off main's own same wrapper —
    a false certificate from a live lane shape. The parameters are the harness's
    measured forms; a missing one costs BOTH roles at once (the exclusion, and the
    "the runner marked this step failed" signal).

    MUTATION: drop a form from `_RUNNER_GENERIC_ANNOTATIONS` → its parameter REDs.
    """
    parsed = parse_failed_ids(
        f"test (a)\tRun tests in container\t2026-09-23T01:00:00.0000000Z {wrapper}\n",
        raw_log=True,
    )

    assert parsed.ids == [], f"{wrapper!r} became a failure identity"
    assert parsed.ok is False


def test_colliding_step_slug_pairs_do_not_attest_each_other():
    """The unit is the RAW (job, step) pair — ``_slug`` is lossy, so it would fuse them.

    Cycle-3 review, reproduced: ``_slug('test (py 3.12)') == _slug('test (py-3.12)')``,
    so slugged units collapsed and one leg's annotation attested the other leg's
    unparseable failure. A PR author edits ``.github/workflows``, so a step named
    ``Run-tests`` beside ``Run tests`` is author-choosable.

    MUTATION: build the unit as ``f"{_slug(job)}::{_slug(step)}"`` → ``ids == []``
    REDs (the colliding leg's annotation gets attributed).
    """
    capture = (
        "test (py 3.12)\tGuard\t2026-09-23T01:00:00.0000000Z "
        "ImportError: no module named y\n"
        "test (py 3.12)\tGuard\t2026-09-23T01:00:01.0000000Z "
        + _GUARD_RUNNER_EXIT
        + "\n"
        "test (py-3.12)\tGuard\t2026-09-23T01:00:02.0000000Z "
        "##[error]redislite server leak: 16 orphans after suite, threshold 12\n"
        "test (py-3.12)\tGuard\t2026-09-23T01:00:03.0000000Z "
        + _GUARD_RUNNER_EXIT
        + "\n"
    )
    parsed = parse_failed_ids(capture, raw_log=True)

    assert parsed.ids == [], "a slug collision fused two different (job, step) pairs"
    assert parsed.ok is False


def test_a_tab_inside_a_step_name_does_not_hide_the_guard_failure():
    """The guard pass recovers the prefix the NODEID pass uses (greedy fallback).

    A tab inside a step name defeated the field split, so the guard pass silently
    skipped every line of that step while the nodeid pass (which uses the greedy
    ``_LOG_PREFIX_RE``) parsed it — the two passes disagreeing about one capture,
    which is the permanent false refusal #4469 exists to remove.
    """
    parsed = parse_failed_ids(
        "test\t(a)\tGuard step\t2026-09-23T01:00:00.0000000Z "
        "##[error]redislite server leak: 16 orphans after suite, threshold 12\n"
        "test\t(a)\tGuard step\t2026-09-23T01:00:01.0000000Z "
        + _GUARD_RUNNER_EXIT
        + "\n",
        raw_log=True,
    )

    assert parsed.ids == [
        "guard-step::a-Guard-step::redislite-server-leak-N-orphans-after-suite-threshold-N"
    ]


def test_every_runner_failure_marker_form_marks_the_step_failed():
    """All three runner forms are recognised, INCLUDING the quoted exit code.

    ``_runner_step_failure`` is both the generator's exclusion list and the only
    detector of "the runner marked this step failed"; a form missing from the list
    costs BOTH, silently refusing a genuine guard run. The runner emits
    ``Bash exited with code '1'.`` for a ``shell: bash`` step — quoted — so the
    quoted code must parse.
    """
    generic = normalize_guard_error("redislite server leak: 16 orphans")
    for marker in (
        "##[error]Process completed with exit code 1.",
        "##[error]Bash exited with code '1'.",
        "##[error]The process '/usr/bin/bash' failed with exit code 1.",
        "##[error]Docker failed with exit code 1",
    ):
        parsed = parse_failed_ids(
            "test (b)\tAssert no redislite orphans (issue\t2026-09-23T01:19:53.8645102Z "
            + "##[error]redislite server leak: 16 orphans\n"
            "test (b)\tAssert no redislite orphans (issue\t2026-09-23T01:19:53.8649910Z "
            + marker
            + "\n",
            raw_log=True,
        )
        assert parsed.ids == [guard_step_key("Assert no redislite orphans (issue", generic)], (
            f"the runner marker {marker!r} did not mark its step failed"
        )


def test_declared_residual_an_unparseable_failure_with_no_pytest_signal():
    """DECLARED RESIDUAL (agent-infra #1366) — pinned, so closing it is a RED.

    An unparseable failure that leaves NO ``E   `` line and sits in a step OTHER
    than the root is invisible: the guard root is attributed first, and nothing
    marks the later step's failure except prose. This is the honest, narrow form
    of the residual — the pytest-shaped and same-named-step variants are refused
    by the ``E   `` and ``(job, step)`` clauses above. Closing the class needs
    per-step conclusions from the run metadata (#1366); a capture alone cannot tell
    a consequence step from an unparseably-failed one.
    """
    residual = _real_capture() + (
        "test (a)\tDeploy preview\t2026-09-23T01:00:02.0000000Z "
        "ImportError: no module named y\n"
        "test (a)\tDeploy preview\t2026-09-23T01:00:03.0000000Z "
        + _GUARD_RUNNER_EXIT
        + "\n"
    )
    parsed = parse_failed_ids(residual, raw_log=True)

    assert parsed.ids == [_GUARD_KEY], (
        "the guard is the ROOT failing step so it is attributed — the residual is "
        "that a LATER unparseable, pytest-signal-free failure is invisible; #1366"
    )


# ── a NON-NODEID failure identity must be COMPARED, not REFUSED (#6798) ────
# MEASURED DEFECT (main @ 4eb27bc0b, run 36806577265; reproduced on a live run):
#
#   `tools/ci-failure-set.sh --commit-rows <sha>` reported
#       examined=1  extracted=0
#     for a run whose ONLY failure evidence was a pytest COLLECTION ERROR:
#       ERROR tests/test_gmm_proofs.py - AttributeError: partially initialized
#       module 'torch' has no attribute 'Tensor' (most likely due to a circular import)
#     and, on the brief's shard, a WATCHDOG KILL with no nodeid at all:
#       ==================== WATCHDOG: pytest killed after 15m
#       (0 passed, 0 failed, 0 errored so far) ====================
#       ==================== pytest exit code: 137 ====================
#
# `admin-merge.sh` step 1c refuses while `extracted < examined`:
#
#     if [ "$pr_extracted" -lt "$pr_examined" ]; then … exit 1
#
# and it has NO exit: a killed leg can never produce a nodeid, so a
# clean-reviewed PR is refused forever. Both causes are ONE defect — a failing
# run that yields no `::nodeid` — and one fix: admit a STABLE, COMPARABLE
# identity from evidence the nodeid pass cannot shape-check, exactly as the
# GUARD-STEP pass (#4469) already does for annotations.
#
# WHY IT IS FAIL-CLOSED: main's union is the EXEMPTION ALLOWLIST, so a PR-side
# identity only excuses a failure main is ALSO red on. A PR that breaks
# collection on a file main collects fine contributes an identity main does not
# carry, so it stays BLOCKED — the comparison is untouched; only its INPUT is
# corrected. (This is the guard-step argument, unchanged.)


# THE KILL BANNER, exactly as the runner's failed-step log carries it. Note the
# `<job>\t<step>\t<ts>Z ` head: that is what makes it a RECORD in a raw log.
_KILL_HEAD = (
    "test (h)\tRun fast test suite (slow files run in the test-slow job)\t"
    "2026-10-01T02:57:36.4464344Z "
)
_KILL_BANNER_137 = (
    "==================== WATCHDOG: pytest killed after 15m "
    "(0 passed, 0 failed, 0 errored so far) — last test lines above "
    "===================="
)
_KILL_BANNER_ZERO_ZERO = (
    "==================== WATCHDOG: pytest killed after 15m "
    "(75 passed, 0 failed, 0 errored so far) — last test lines above "
    "===================="
)
_COLLECT_ERROR = (
    "ERROR tests/test_gmm_proofs.py - AttributeError: partially initialized "
    "module 'torch' has no attribute 'Tensor' (most likely due to a circular import)"
)


def _log(*lines: str) -> str:
    """A raw `gh run view --log-failed` capture: every line carries the head."""
    return "".join(_KILL_HEAD + line + "\n" for line in lines)


def test_6798_a_watchdog_killed_leg_yields_a_comparable_identity():
    """(a) THE UNBLOCK: a killed leg is not an un-measured surface.

    Measured: the kill banner carries NO nodeid, so the nodeid pass yields
    nothing, `extracted` stays 0 against `examined=1`, and step 1c refuses with
    no exit. The kill IS the failure identity — and it must be STABLE, so the
    identity is keyed on the pytest watchdog, not on the shard, the minute
    count, or the tick's passed/failed counters (all of which move run to run
    and would make main's baseline un-matchable — the rotating-identity class).
    """
    parsed = parse_failed_ids(_log(_KILL_BANNER_137), raw_log=True)

    assert parsed.ids == ["watchdog-kill::pytest"], (
        "a watchdog-killed leg must yield a comparable identity, or the rail "
        "refuses it forever (§1c: extracted < examined, exit 1)"
    )
    assert parsed.ok is True, "the set is READ, not empty: the run is attributable"
    assert parsed.rejected == [], "the banner is a RECORD, never a dropped token"
    assert parsed.non_nodeid == ["watchdog-kill::pytest"], (
        "the kill must be reported AS a non-nodeid attribution so the rail can "
        "say WHICH signal it read (a kill is re-runnable; a collection error is "
        "the PR's own breakage — the remedies differ)"
    )


def test_6798_the_kill_identity_does_not_track_the_tick_counters():
    """THE STABILITY REQUIREMENT: 0 passed and 75 passed name the SAME id.

    The banner's passed/failed/errored counters are a snapshot of the tick the
    watchdog fired on. Keying the identity on them would make it rotate between
    runs, so it could never match main's baseline and EVERY killed leg would
    read as "unique to this PR" — the #3756 permanent-false-refusal, rebuilt.
    """
    zero = parse_failed_ids(_log(_KILL_BANNER_137), raw_log=True)
    mid = parse_failed_ids(_log(_KILL_BANNER_ZERO_ZERO), raw_log=True)

    assert zero.ids == mid.ids == ["watchdog-kill::pytest"], (
        "the identity must not vary with the kill tick's counters"
    )


def test_6798_a_killed_leg_with_REPORTED_FAILURES_is_not_a_bare_kill():
    """FAIL-CLOSED: a kill is a bare failure ONLY at zero failures.

    A pytest run killed AFTER failures have been reported has real nodeids, and
    those are the PR's failures. Emitting a bare `watchdog-kill::pytest` there
    would let a genuine assertion failure ride an environmental exemption — the
    one direction this must never open.
    """
    banner_with_failures = (
        "==================== WATCHDOG: pytest killed after 15m "
        "(120 passed, 3 failed, 2 errored so far) — last test lines above "
        "===================="
    )
    parsed = parse_failed_ids(_log(banner_with_failures), raw_log=True)

    assert "watchdog-kill::pytest" not in parsed.ids, (
        "a kill at 3 failed / 2 errored is NOT a bare kill — those failures "
        "must be named by their nodeids, never excused as environmental"
    )


def test_6798_the_echoed_script_source_does_not_emit_a_kill_identity():
    """THE MEASURED TRAP: the workflow ECHOES the banner's own source line.

    `--log-failed` contains the shell source — measured at run 36809707842 line
    85, the letter-for-letter text `echo "==================== WATCHDOG: pytest
    killed after 15m …"`. A substring match fires on EVERY run, green included,
    and would exempt the whole fleet unconditionally. The record must be the
    BANNER (the runner's own output line), never its source echo.
    """
    echoed_source = (
        "\x1b[36;1m  echo \"==================== WATCHDOG: pytest killed after "
        "15m ($passed passed, $failed failed, $errored errored so far) — last "
        "test lines above ====================\"\x1b[0m"
    )
    parsed = parse_failed_ids(_log(echoed_source), raw_log=True)

    assert "watchdog-kill::pytest" not in parsed.ids, (
        "the echoed shell source names unset variables, not a measurement — "
        "emitting an id here exempts every run repo-wide"
    )


def test_6798_a_kill_banner_at_any_budget_is_recognised():
    """The MINUTE COUNT is not fixed — `test-slow` kills at 10m, `test` at 15m.

    MEASURED: run 36811187065's echoed source carries a 10m banner for the
    `test-slow` job while the `test` job's is 15m, so a pattern pinned to one
    budget silently misses every kill on the other leg — a fix that fires on the
    shard that was measured tonight and not on the next one, which is the
    per-shard failure mode (#1266 -> #1371 -> #3395 -> #6145).
    """
    ten_minute = (
        "==================== WATCHDOG: pytest killed after 10m "
        "(40 passed, 0 failed, 0 errored so far) — last test lines above "
        "===================="
    )
    parsed = parse_failed_ids(_log(ten_minute), raw_log=True)

    assert parsed.ids == ["watchdog-kill::pytest"], (
        "the kill identity must not be pinned to one watchdog budget"
    )


def test_6798_a_FAILED_file_level_record_is_NOT_a_collection_error():
    """THE KEYWORD IS LOAD-BEARING: pytest emits collection errors under `ERROR`.

    `FAILED tests/x.py` with no `::` is a malformed/truncated record, and the
    drop accounting exists precisely for it (`FAILED may` is the measured form).
    Admitting any `.py`-suffixed payload would let a truncated nodeid — whose
    module happens to end in `.py` — buy an identity, and the shape check is the
    only thing standing between the set and the #3756 leak.
    """
    parsed = parse_failed_ids(_log("FAILED tests/test_gmm_proofs.py"), raw_log=True)

    assert parsed.ids == [], (
        "only pytest's ERROR-led collection record is an attribution; a "
        "file-level FAILED record stays a DROP"
    )
    assert len(parsed.rejected) == 1, "and it must be COUNTED, as a drop"


def test_6798_b_an_unattributable_run_that_was_NOT_killed_still_blocks():
    """(b) THE REFUSAL THAT MUST SURVIVE — the hole-closer.

    A genuinely unattributable run (prose, no nodeid, no kill banner) must
    yield NOTHING, so `extracted < examined` still refuses it. If this test
    passes with an id in the set, the change has opened the exact hole #6798
    was mis-diagnosed against and is WRONG.
    """
    unattributable = _log(
        "ImportError: no module named y",
        "##[error]Process completed with exit code 1.",
    )
    parsed = parse_failed_ids(unattributable, raw_log=True)

    assert parsed.ids == [], (
        "an unattributable, un-killed run must keep its zero-residual refusal"
    )
    assert parsed.ok is False, "zero ids from no evidence must not read as a valid set"


def test_6798_c_a_parseable_nodeid_is_unchanged_by_the_new_pass():
    """(c) NO REGRESSION: the nodeid path is untouched.

    A leg that fails WITH a nodeid must produce exactly that nodeid — the new
    pass may not add, rename, or swallow it.
    """
    parsed = parse_failed_ids(_log(f"FAILED {ID}"), raw_log=True)

    assert parsed.ids == [ID], "the nodeid path must be byte-for-byte unchanged"


def test_6798_a_collection_error_yields_a_comparable_identity():
    """THE SECOND MEASURED CAUSE — same defect, same fix.

    Reproduced live: a run whose only failure was a collection error produced
    `examined=1 extracted=0`. pytest's record is `ERROR <path> - <reason>` — a
    FILE-level identity the nodeid pass cannot address. The reason string
    VARIES run to run (it is an exception message), so the identity is keyed on
    the FILE, which is stable.
    """
    parsed = parse_failed_ids(_log(_COLLECT_ERROR), raw_log=True)

    assert parsed.ids == ["collect-error::tests/test_gmm_proofs.py"], (
        "a collection error is an attribution, not an unattributable token"
    )
    assert parsed.rejected == [], (
        "it must be EXTRACTED, not dropped — a drop still marks the set CLIPPED"
    )
    assert parsed.non_nodeid == ["collect-error::tests/test_gmm_proofs.py"], (
        "the id must ALSO be recorded per-KIND, or the report prints "
        "`non-nodeid=0` beside an id that came from exactly that pass and the "
        "operator reads which signal it was backwards"
    )


def test_6798_a_collection_error_identity_is_file_scoped_not_reason_scoped():
    """STABILITY: the same file with a different exception is the SAME id."""
    other_reason = "ERROR tests/test_gmm_proofs.py - ModuleNotFoundError: No module named 'x'"
    a = parse_failed_ids(_log(_COLLECT_ERROR), raw_log=True)
    b = parse_failed_ids(_log(other_reason), raw_log=True)

    assert a.ids == b.ids, "an identity that tracks the exception message can never match main"


def test_6798_an_id_file_admits_neither_identity():
    """SCOPE: both passes are RAW-LOG only (as the guard-step pass is).

    An id FILE is the failure set already — an `ERROR <path>` or a banner line
    there is malformed input, not evidence, and must stay REJECTED so a
    hand-written file cannot buy an identity.
    """
    for line in (_COLLECT_ERROR, _KILL_BANNER_137):
        parsed = parse_failed_ids(line + "\n", raw_log=False)
        assert parsed.ids == [], f"id-file mode must not admit {line[:40]!r}"
        assert parsed.rejected == [line], "an id file's bad record is a DROP, not prose"


# ── THE DECISION, not just the parser (verifier-found gap) ────────────────
# The FIRST fix corrected only the `ids` half. The rail reads TWO doors, and
# `decide` compares SIGNATURES with a subset rule (`_signatures_overlap`), which
# returns False when EITHER side is empty. So an id with no signature does not
# "compare" at all — it BLOCKS. Worse, `ci_failure-set.sh:839` runs the
# signature extractor inside `if [ -n "$ids" ]` and treats a non-zero exit as
# FATAL, and `_cmd_signatures` returns non-zero when the capture yields no id —
# so an ids-only fix RELOCATED the per-run refusal into the signature door.
# These tests exercise the decision, which the unit suite had not.


def test_6798_the_signature_door_emits_the_same_non_nodeid_universe():
    """BOTH doors must agree — an id signed by one door only BLOCKS.

    `ci-failure-set.sh` calls `ids` and then, only when ids is non-empty,
    `signatures`. A non-zero exit from that second call is FATAL for the run, so
    "ids only" is not a partial fix: it is the SAME refusal with a new message.
    """
    capture = _log(_COLLECT_ERROR)
    ids_door = parse_failed_ids(capture, raw_log=True)
    sig_door = parse_pr_failure_text(capture)

    assert sig_door.ok is True, (
        "the signatures CLI returns 0 only when ok — False here makes "
        "ci-failure-set.sh abort the run as a fatal extraction failure"
    )
    assert sig_door.ids == ids_door.ids == ["collect-error::tests/test_gmm_proofs.py"]
    assert sig_door.non_nodeid == ["collect-error::tests/test_gmm_proofs.py"]
    assert sig_door.rejected == [], (
        "a non-empty `rejected` marks the set CLIPPED — and the OTHER door "
        "already calls this line extracted, so the two must not disagree"
    )
    assert sig_door.signatures["collect-error::tests/test_gmm_proofs.py"] == frozenset(
        {"collect-error"}
    )


def test_6798_the_signature_door_signs_the_watchdog_kill():
    """The kill must be signed by the same door, and signed STABLY."""
    sig_door = parse_pr_failure_text(_log(_KILL_BANNER_137))

    assert sig_door.ok is True
    assert sig_door.ids == ["watchdog-kill::pytest"]
    assert sig_door.signatures["watchdog-kill::pytest"] == frozenset({"watchdog-kill"})


def test_6798_the_carve_out_banner_is_recognised():
    """A third REACHABLE banner shape (tortoise python-ci.yml:1810).

    `WATCHDOG: carve-out pytest killed after 35m (…)` — a pattern pinned to the
    bare `WATCHDOG: pytest killed after` silently misses it, so a carve-out kill
    stays zero-id: the same permanent refusal, one shape over.
    """
    carve_out = (
        "==================== WATCHDOG: carve-out pytest killed after 35m "
        "(12 passed, 0 failed, 0 errored so far) ===================="
    )
    parsed = parse_failed_ids(_log(carve_out), raw_log=True)

    assert parsed.ids == ["watchdog-kill::pytest"], (
        "the carve-out leg is a reachable kill shape and must be attributed"
    )


def test_6798_a_non_nodeid_identity_is_COMPARED_not_BLOCKED():
    """THE POINT OF THE WHOLE CHANGE, proven at the DECISION.

    With main carrying the same identity, the PR's occurrence is EXEMPT — which
    is what the brief means by "the rail does not permanently refuse". A parser
    result that never reaches this state has fixed nothing.
    """
    capture = _log(_KILL_BANNER_137)
    ids = parse_failed_ids(capture, raw_log=True).ids
    sigs = parse_pr_failure_text(capture).signatures
    assert ids == ["watchdog-kill::pytest"] and "watchdog-kill::pytest" in sigs

    # EQUAL rates: the question here is REFUSAL vs COMPARISON, not severity. The
    # first version of this test used a PR rate 1.5x main's and the decision
    # (correctly) blocked on the RATE — which is the comparison working, not a
    # refusal. Making the rates equal isolates the thing under test.
    pr = {i: Failure(rate=Rate(2, 8), signatures=sigs[i]) for i in ids}
    main_rates = {i: Rate(2, 8) for i in ids}

    d = decide(pr, main_rates, main_signatures={i: sigs[i] for i in ids}, k_pr=8)

    assert not d.any_blocked, (
        f"a non-nodeid identity main is ALSO red on at the same rate must be "
        f"exempt, not blocked; blocked={[(v.nodeid, v.reason) for v in d.blocked]}"
    )


def test_6798_a_non_nodeid_identity_main_never_had_STILL_BLOCKS():
    """FAIL-CLOSED, at the decision: the allowlist direction is unchanged.

    A PR whose collection error main is NOT red on is the PR's own breakage and
    must BLOCK. If this passes as exempt, the change has opened the hole.
    """
    capture = _log(_COLLECT_ERROR)
    ids = parse_failed_ids(capture, raw_log=True).ids
    sigs = parse_pr_failure_text(capture).signatures

    pr = {i: Failure(rate=Rate(3, 8), signatures=sigs[i]) for i in ids}
    # main is GREEN for this file: zero rate, no signature entry.
    d = decide(pr, {}, main_signatures={}, k_pr=8)

    assert d.any_blocked, (
        "an identity main never carried must block — the exemption set is "
        "main's union, and this id is not in it"
    )


def test_6798_a_KILL_does_not_excuse_a_NAMED_test_failure():
    """CRITICAL fail-open check: the kill identity must not launder a nodeid.

    A PR that fails a real test AND was also killed carries BOTH ids. The kill
    being exempt must not exempt the named failure — the subset rule requires
    EVERY PR signature to be on main, and main has no signature for that test.
    """
    # A REAL failure line carries a detail (` - <reason>`); without one the nodeid
    # is UNSIGNED and blocks for a DIFFERENT reason, which would make this test
    # pass or fail for the wrong cause.
    capture = _log(_KILL_BANNER_137, f"FAILED {ID} - AssertionError: boom")
    ids = parse_failed_ids(capture, raw_log=True).ids
    sigs = parse_pr_failure_text(capture).signatures

    assert "watchdog-kill::pytest" in ids and ID in ids, "both must be present"
    assert ID in sigs, "the named failure must be SIGNED, or it blocks unsigned"

    pr = {i: Failure(rate=Rate(2, 8), signatures=sigs[i]) for i in ids}
    # main was killed too, but never failed ID.
    main_rates = {"watchdog-kill::pytest": Rate(1, 8)}
    main_sigs = {"watchdog-kill::pytest": frozenset({"watchdog-kill"})}

    d = decide(pr, main_rates, main_signatures=main_sigs, k_pr=8)

    assert d.any_blocked, (
        "the kill must not clean the sheet for a named test failure — a PR that "
        "asserted false must stay blocked"
    )


# ── THE THIRD LAYER: the ROW / RATE doors (verifier round-2 finding) ───────
# Round 2 found that fixing both PARSERS was still not enough, and that the
# failure mode was WORSE than the refusal it replaced. `is_failure_key_loose`
# gated the row doors and admitted only nodeids and guard-step keys, so the new
# ids were REJECTED: `parse_failure_rows` dropped the PR's OWN row, `decide` saw
# an EMPTY PR set, and the verdict became `CLEAN blocked=0 rejected=1`. A red PR
# certified clean and MERGED — a silent false PASS, strictly worse than the
# permanent refusal. Measured on the real CLI, before and after.
#
# Every unit test above still passed through this, because they build `Failure`
# dicts by hand and never exercise the row parsers. Hence these.


def test_6798_the_row_door_admits_the_non_nodeid_families():
    """F5: the predicates that gate the row/rate doors must admit them."""
    for key in ("watchdog-kill::pytest", "collect-error::tests/test_a.py"):
        assert is_failure_key(key), f"parse_rates would DROP main's row for {key}"
        assert is_failure_key_loose(key), f"parse_failure_rows would DROP the PR row for {key}"


def test_6798_the_row_door_still_rejects_junk():
    """FAIL-CLOSED: the widened predicate must not become a wildcard.

    `is_failure_key` gates MAIN's rate table — the exemption allowlist. Admitting
    a loose string there is a false-exemption vector, not a formatting nicety.
    """
    for junk in (
        "random-string",
        "watchdog-kill::OTHER",          # not the one identity we emit
        "collect-error::notapyfile",     # must be a .py path
        "collect-error::",               # empty path
        "collect-error::tests/a.py::x",  # a nodeid is NOT a collect-error key
    ):
        assert not is_failure_key_loose(junk), f"{junk!r} must NOT buy a failure key"


def test_6798_a_kill_only_PR_row_is_NOT_silently_dropped():
    """THE SILENT FALSE PASS ITSELF, at the door that produced it.

    Before the fix this returned `failures == {}` with the row in `rejected`, and
    the rail reads an empty PR set as "clean" — it does NOT read `rejected`.
    """
    rows = "watchdog-kill::pytest\t1\t3\twatchdog-kill\n"
    parsed = parse_failure_rows(rows)

    assert set(parsed.failures) == {"watchdog-kill::pytest"}, (
        f"the PR's own row must not be dropped (rejected={parsed.rejected}) — an "
        f"empty PR set reads as CLEAN to the rail"
    )
    assert parsed.rejected == []
    assert parsed.failures["watchdog-kill::pytest"].signatures == frozenset(
        {"watchdog-kill"}
    )


def test_6798_main_rates_admit_the_non_nodeid_families():
    """F6: main's rate row must survive, or main reads empty and always BLOCKS."""
    parsed = parse_rates("watchdog-kill::pytest\t1\t3\n")

    assert "watchdog-kill::pytest" in parsed.rates, (
        f"main's rate row was dropped (rejected={parsed.rejected}) — with main "
        f"empty, the COMPARISON half cannot work in either direction"
    )
    assert parsed.rejected == []


def test_6798_a_collection_error_rate_row_survives_main_side():
    """The other family, on main's side, through the strict predicate."""
    parsed = parse_rates("collect-error::tests/test_a.py\t2\t4\n")

    assert "collect-error::tests/test_a.py" in parsed.rates
    assert parsed.rejected == []


def test_6798_main_signature_rows_admit_the_non_nodeid_families():
    """The main-side signature table is a separate door and needs it too."""
    sigs = parse_signature_rows("watchdog-kill::pytest\twatchdog-kill\n")

    assert sigs.get("watchdog-kill::pytest") == frozenset({"watchdog-kill"}), (
        "a dropped main signature fails `_signatures_overlap` closed"
    )
