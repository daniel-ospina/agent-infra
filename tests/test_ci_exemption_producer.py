"""Acceptance tests for the PR-side SIGNATURE producer and the ``decide`` CLI
(tortoise #3756, Step A + Step B).

The wire shape under test is not invented: it is the real ``gh run view
--log-failed`` capture measured on tortoise run 35223536174 (python-ci.yml,
2026-09-17). Each test names the MUTATION that must RED it — a test whose
mutation cannot fail it is not a test.

Threat surface (same as ``test_ci_exemption.py`` — the exemption face): the
producer's failures are all in the fail-OPEN direction, because a signature the
parser DROPS makes the PR's signature set smaller and therefore *easier* to
contain in main's:

* a per-run interpolated id left in the signature → the PR never matches main →
  every run BLOCKS forever (fail-closed, a cost — but the thing #3749 needs
  fixed);
* a signature stored BLANK or low-entropy → the subset rule becomes vacuous →
  a genuinely-new failure is exempted (fail-OPEN);
* an id that enters the producer's output without a signature, or leaves the
  wire parser by a rejection path, silently vanishes from the decision.
"""

from __future__ import annotations

import pytest

import importlib.util
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
# coupling is pinned by test_tests_load_the_file_the_rail_execs in
# tests/test_ci_exemption.py.
_CANONICAL_PATH = Path(__file__).resolve().parents[1] / "scripts" / "ci_exemption.py"
_spec = importlib.util.spec_from_file_location("ci_exemption_canonical", _CANONICAL_PATH)
if _spec is None or _spec.loader is None:  # pragma: no cover - environment failure
    raise ImportError(f"canonical exemption module is ABSENT at {_CANONICAL_PATH}")
ci_exemption = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = ci_exemption
_spec.loader.exec_module(ci_exemption)

Decision = ci_exemption.Decision
Failure = ci_exemption.Failure
Rate = ci_exemption.Rate
decide = ci_exemption.decide
main = ci_exemption.main
normalize_signature = ci_exemption.normalize_signature
parse_failure_rows = ci_exemption.parse_failure_rows
parse_pr_failure_text = ci_exemption.parse_pr_failure_text
parse_rotation_runs = ci_exemption.parse_rotation_runs
parse_signature_rows = ci_exemption.parse_signature_rows
render_signature_table = ci_exemption.render_signature_table

ID = "tests/test_oauth_token_fault.py::test_capture_exception_raising_does_not_break_the_typed_error"
DR = "tests/dr_endpoints.py::TestDrDrill::test_dr_restores_to_scratch"

_GH_JOB = "test (a)"
_GH_STEP = "Run fast test suite (slow files run in the test-slow job)"


def _log(body: str, *, ansi: bool = False) -> str:
    """Wrap plain pytest output in the real gh ``--log-failed`` envelope.

    Byte-for-byte the measured shape: ``<job>\\t<step>\\t\\ufeff<ISO>Z <line>``
    (BOM on the first line only), with optional SGR escapes inside the content.
    """
    out: list[str] = []
    for i, line in enumerate(body.splitlines()):
        ts = f"2026-09-17T13:10:44.17{i:05d}Z"
        bom = "\ufeff" if i == 0 else ""
        payload = f"\x1b[36;1m{line}\x1b[0m" if (ansi and line.strip()) else line
        out.append(f"{_GH_JOB}\t{_GH_STEP}\t{bom}{ts} {payload}")
    return "\n".join(out) + "\n"


_OAUTH_BODY = f"""\
=================================== FAILURES ===================================
________ test_capture_exception_raising_does_not_break_the_typed_error _________

    def test_capture_exception_raising_does_not_break_the_typed_error(monkeypatch, fault_client):
>       assert r.status_code == 503 and r.json()["error"] == "te
E       assert (200 == 503)
E        +  where 200 = <Response [200 OK]>.status_code

{ID.partition("::")[0]}:779: AssertionError
=========================== short test summary info ============================
FAILED {ID} - assert (200 == 503)
"""


def _drill_body(hex_suffix: str, *, exc: str = "RuntimeError") -> str:
    return f"""\
=================================== FAILURES ===================================
________ test_dr_restores_to_scratch ________

E       {exc}: Drill failed: Restore swap failed - verified temp graph _drill_..._{hex_suffix} intact: I/O operation on closed file.

tests/dr_endpoints.py:412: {exc}
=========================== short test summary info ============================
FAILED {DR}
"""


def _assert_body(left: str, right: str) -> str:
    return f"""\
=================================== FAILURES ===================================
________ test_dr_restores_to_scratch ________

>       assert restored == expected
E       assert {left} == {right}

tests/dr_endpoints.py:88: AssertionError
=========================== short test summary info ============================
FAILED {DR} - assert {left} == {right}
"""


# ── Step A · the signature producer ───────────────────────────────────────


def test_signature_extraction_matches_the_real_gh_log_shape():
    """THE grounding test: the measured artifact parses to the measured signature.

    MUTATION: make ``_strip_log_prefix`` return the line unchanged → the ``E``
    and trailer lines keep the ``<job>\\t<step>\\t<ts> `` prefix, match nothing,
    and the id falls back to the bare summary detail (or goes unsigned) → the
    exact-string assertion REDs.
    MUTATION: drop the ``_ANSI_RE.sub`` in ``parse_pr_failure_text`` → the
    trailer ``path.py:779: AssertionError`` is wrapped in SGR escapes, so the
    exception TYPE is lost and the signature degrades to ``assert (200 == 503)``
    → the exact-string assertion REDs.
    """
    parsed = parse_pr_failure_text(_log(_OAUTH_BODY, ansi=True))

    assert parsed.ids == [ID]
    assert parsed.signatures[ID] == frozenset({"AssertionError: assert (200 == 503)"})
    assert parsed.rejected == []
    assert parsed.unsigned == []


def test_per_run_interpolated_identifier_does_not_change_the_signature():
    """The declared class: ``_drill_..._416bf7c5`` varies per run, the failure does not.

    MUTATION: remove the ``<HEX>`` normalizer from ``_VOLATILE_NORMALIZERS`` →
    the two captures yield two different signatures → the equality REDs (and
    with it every exemption for the #3749 substrate family).
    """
    a = parse_pr_failure_text(_log(_drill_body("416bf7c5")))
    b = parse_pr_failure_text(_log(_drill_body("aa11bb22")))

    assert a.signatures[DR] == b.signatures[DR]
    assert a.signatures[DR] == frozenset(
        {
            "RuntimeError: Drill failed: Restore swap failed - verified temp graph "
            "_drill_..._<HEX> intact: I/O operation on closed file."
        }
    )


def test_distinct_assertions_do_not_collapse_into_one_signature():
    """Over-normalising is the fail-OPEN direction — guard it explicitly.

    MUTATION: add a generic digit/identifier mask (e.g. ``re.sub(r"\\d+", "<N>")``)
    to ``_VOLATILE_NORMALIZERS`` → both assertions collapse to one signature,
    which is exactly how the subset rule would start exempting a failure the PR
    introduced → the inequality REDs.
    """
    three = parse_pr_failure_text(_log(_assert_body("3", "2")))
    four = parse_pr_failure_text(_log(_assert_body("4", "2")))

    assert three.signatures[DR] != four.signatures[DR]
    assert three.signatures[DR] == frozenset({"AssertionError: assert 3 == 2"})


def test_unsigned_id_is_reported_and_never_stored_blank():
    """An id with no signature is EVIDENCE, never an empty signature.

    MUTATION: store ``frozenset({""})`` (or ``""``) for the id → the
    ``"" not in`` assertion and the ``unsigned`` assertion RED — and in the real
    gate a blank signature is what makes the subset rule vacuous.
    """
    parsed = parse_pr_failure_text(_log(f"FAILED {DR}\n"))

    assert parsed.ids == [DR]
    assert DR not in parsed.signatures
    assert parsed.unsigned == [DR]
    for sigs in parsed.signatures.values():
        assert "" not in sigs


def test_a_failed_line_with_a_bad_payload_is_rejected_and_counted():
    """``FAILED may`` is not a failure record — and must not enter the id set.

    MUTATION: remove the ``_NODEID_LOOSE_RE`` guard → ``may`` enters ``ids`` and
    ``rejected`` is empty → RED.
    """
    parsed = parse_pr_failure_text(_log(f"FAILED may\nFAILED {DR}\n"))

    assert parsed.ids == [DR]
    assert parsed.rejected == ["FAILED may"]


def test_a_param_nodeid_with_a_space_is_accepted_not_dropped():
    """Real pytest params contain spaces; dropping the id would be fail-OPEN.

    MUTATION: use the narrow ``_NODEID_RE`` here instead of ``_NODEID_LOOSE_RE``
    → the nodeid is rejected, the id disappears from the decision entirely, and
    an undecided id is an unblocked id → RED.
    """
    nid = "tests/e2e/test_x.py::test_a[chromium-Claude Desktop]"
    parsed = parse_pr_failure_text(_log(f"FAILED {nid}\n"))

    assert parsed.ids == [nid]
    assert parsed.rejected == []


def test_an_unmatched_failures_block_is_counted_not_guessed():
    """A block that joins to no id is a rejection, not an attribution.

    MUTATION: attribute every unjoined block to the first/only known id → the
    block's signature is invented onto an id that never had it, and
    ``unattributed`` is empty → RED.
    """
    body = (
        "=================================== FAILURES ===================================\n"
        "________ test_ghost ________\n"
        "\n"
        "E       AssertionError: nowhere\n"
        "\n"
        "tests/test_other.py:9: AssertionError\n"
        "=========================== short test summary info ============================\n"
        f"FAILED {DR}\n"
    )
    parsed = parse_pr_failure_text(_log(body))

    assert parsed.unattributed == ["test_ghost"]
    assert DR not in parsed.signatures, "no signature may be invented by position"
    assert parsed.unsigned == [DR]


def test_summary_detail_is_the_fallback_when_no_block_exists():
    """The summary line's own payload is used only when no block joined.

    MUTATION: drop the ``details`` fallback in ``parse_pr_failure_text`` → the id
    goes ``unsigned`` and the non-empty-``signatures`` assertion REDs.
    """
    parsed = parse_pr_failure_text(_log(f"FAILED {DR} - assert 3 == 2\n"))

    assert parsed.signatures[DR] == frozenset({"assert 3 == 2"})
    assert parsed.unsigned == []


def test_block_signature_wins_and_only_one_form_is_stored_per_id():
    """One id contributes ONE form — the block's, which carries the exception TYPE.

    MUTATION: union the block signature with the summary detail →
    ``len(signatures[ID]) == 2`` and the set-equality REDs; the competing forms
    would also make ``pr <= main`` fail against a main side that saw only one.
    """
    parsed = parse_pr_failure_text(_log(_OAUTH_BODY))

    assert parsed.signatures[ID] == frozenset({"AssertionError: assert (200 == 503)"})
    assert len(parsed.signatures[ID]) == 1


def test_normalize_signature_collapses_whitespace():
    """The same assertion is rendered at different prefix widths between runs.

    MUTATION: delete the ``" ".join(str(text).split())`` collapse → the two
    strings differ → RED.
    """
    assert normalize_signature("assert   3   ==   2") == "assert 3 == 2"


# ── Step B · the wire parser ──────────────────────────────────────────────


def test_failure_rows_parse_and_union_signatures_for_duplicate_ids():
    """Two rows for one id are how a multi-signature id is expressed.

    MUTATION: let the last row win instead of unioning signatures → only one
    signature remains → RED.
    """
    r = parse_failure_rows(
        f"{DR}\t4\t8\tAssertionError: assert 3 == 2\n"
        f"{DR}\t4\t8\tConnectionError: socket gone\n"
    )

    assert r.failures[DR].rate == Rate(4, 8)
    assert r.failures[DR].signatures == frozenset(
        {"AssertionError: assert 3 == 2", "ConnectionError: socket gone"}
    )
    assert r.rejected == []


def test_a_blank_signature_column_is_dropped_and_counted():
    """The rate survives; the blank signature does NOT become an entry.

    MUTATION: store the blank signature (``frozenset({""})``) → the ``unsigned``
    assertion and the ``"" not in`` assertion RED.
    """
    r = parse_failure_rows(f"{DR}\t1\t1\t\n")

    assert r.failures[DR].rate == Rate(1, 1)
    assert r.failures[DR].signatures == frozenset()
    assert r.unsigned == [DR]


def test_conflicting_duplicate_rows_leave_the_id_blockable():
    """A self-contradicting table must not make the id VANISH.

    MUTATION: ``failures.pop(nodeid)`` on conflict (mirroring ``parse_rates``) →
    the id is absent from ``pr_failures``, so :func:`decide` never blocks it and
    a contradicted failure ships → both the presence assertion and the
    ``decide`` block assertion RED.
    """
    r = parse_failure_rows(
        f"{DR}\t8\t8\tAssertionError: assert 3 == 2\n"
        f"{DR}\t0\t8\tAssertionError: assert 3 == 2\n"
    )

    assert DR in r.failures, "a contradicted id must not vanish from the decision"
    assert r.failures[DR].rate.runs == 0, "unmeasurable rate → the existing BLOCK path"
    assert len(r.rejected) == 1

    d = decide(
        r.failures,
        {DR: Rate(4, 8)},
        main_signatures={DR: frozenset({"AssertionError: assert 3 == 2"})},
    )
    assert d.any_blocked, "an unmeasurable PR rate is never exempt"


def test_signature_rows_and_rotation_runs_parse_their_formats():
    """Main signatures are ``<nodeid>\\t<sig>``; a rotation run is one line of ids.

    MUTATION: split rotation input on "::" or treat each id as its own run → the
    three-run shape collapses and the assertion REDs.
    """
    sigs = parse_signature_rows(f"{DR}\tAssertionError: assert 3 == 2\n\n")
    assert sigs == {DR: frozenset({"AssertionError: assert 3 == 2"})}

    runs = parse_rotation_runs(f"{DR} tests/other.py::t\ntests/other.py::t\n")
    assert runs == [frozenset({DR, "tests/other.py::t"}), frozenset({"tests/other.py::t"})]


def test_render_signature_table_is_the_documented_wire_form():
    """MUTATION: emit ``nodeid sig`` (space) instead of a tab → the split
    assertion REDs, and the shell's join would silently produce a bad row."""
    out = render_signature_table({DR: frozenset({"AssertionError: x"})})
    assert out == f"{DR}\tAssertionError: x\n"


# ── Step B · the CLI ──────────────────────────────────────────────────────


def _write(tmp_path, name: str, text: str):
    p = tmp_path / name
    p.write_text(text, encoding="utf-8")
    return str(p)


def test_cli_decide_blocks_and_writes_the_residual(tmp_path, capsys):
    """The shell's residual is the decision's BLOCKED set, not a subtraction.

    MUTATION: return 0 unconditionally → the exit assertion REDs.
    MUTATION: skip ``--blocked-out`` → the residual-file assertion REDs.
    """
    pr = _write(tmp_path, "pr.txt", f"{DR}\t8\t8\tAssertionError: assert 3 == 2\n")
    mainf = _write(tmp_path, "main.txt", f"{DR}\t1\t8\n")
    msig = _write(tmp_path, "msig.txt", f"{DR}\tAssertionError: assert 3 == 2\n")
    blocked = tmp_path / "blocked.txt"
    verdict = tmp_path / "verdict.txt"

    rc = main(
        [
            "decide", "--pr-failures", pr, "--main-rates", mainf,
            "--main-signatures", msig,
            "--blocked-out", str(blocked), "--verdict-out", str(verdict),
        ]
    )
    out = capsys.readouterr().out

    assert rc == 1
    assert blocked.read_text(encoding="utf-8") == f"{DR}\n"
    assert verdict.read_text(encoding="utf-8").startswith("VERDICT\tBLOCK")
    assert "blocked=1" in out


def test_cli_decide_exempts_with_both_rates_visible(tmp_path, capsys):
    """An exemption must be RECORDED with both rates — never an absence.

    MUTATION: write the EXEMPT line without the measured rates → the ``4/8``
    assertion REDs; a green with no recorded exemption is the fail-open defect.
    """
    pr = _write(tmp_path, "pr.txt", f"{DR}\t4\t8\tAssertionError: assert 3 == 2\n")
    mainf = _write(tmp_path, "main.txt", f"{DR}\t4\t8\n")
    msig = _write(tmp_path, "msig.txt", f"{DR}\tAssertionError: assert 3 == 2\n")
    exempt = tmp_path / "exempt.txt"

    rc = main(
        [
            "decide", "--pr-failures", pr, "--main-rates", mainf,
            "--main-signatures", msig, "--exempt-out", str(exempt),
        ]
    )
    out = capsys.readouterr().out

    assert rc == 0
    line = exempt.read_text(encoding="utf-8")
    assert line.startswith("EXEMPT:")
    assert "main 4/8" in line and "PR 4/8" in line
    assert "VERDICT\tCLEAN" in out


def test_cli_decide_rotation_is_unattributable_and_gates(tmp_path, capsys):
    """A rotating identity gates but is reported as UNATTRIBUTABLE, not blocked.

    MUTATION: treat ``unattributable`` as non-gating (``return 0``) → the exit
    assertion REDs; MUTATION: fold it into ``blocked`` → the
    ``--unattributable-out`` assertion REDs.
    """
    cls = "tests/dr_endpoints.py::TestDrDrillScheduled"
    a = f"{cls}::test_manual_drill_records_measured_time"
    b = f"{cls}::test_status_surfaces_last_drill"
    pr = _write(tmp_path, "pr.txt", f"{a}\t1\t8\tAssertionError: assert 3 == 2\n")
    mainf = _write(tmp_path, "main.txt", f"{a}\t1\t8\n")
    msig = _write(tmp_path, "msig.txt", f"{a}\tAssertionError: assert 3 == 2\n")
    rot = _write(tmp_path, "rot.txt", f"{a} {b}\n{b}\n{b}\n")
    un = tmp_path / "un.txt"

    rc = main(
        [
            "decide", "--pr-failures", pr, "--main-rates", mainf,
            "--main-signatures", msig, "--rotation", rot,
            "--unattributable-out", str(un),
        ]
    )
    out = capsys.readouterr().out

    assert rc == 1, "a rotating identity must gate"
    assert un.read_text(encoding="utf-8") == f"{a}\n"
    assert "unattributable=1" in out
    assert "UNATTRIBUTABLE" in out


def test_cli_decide_without_main_signatures_fails_closed_and_says_so(tmp_path, capsys):
    """No main signature evidence = every signature check BLOCKS, visibly.

    MUTATION: default ``main_sigs`` to the PR's own signatures → the PR is
    exempted with no main-side evidence → the exit assertion REDs.
    MUTATION: drop the explanatory note → the note assertion REDs, and the
    safe-but-wrong state becomes indistinguishable from a real block.
    """
    pr = _write(tmp_path, "pr.txt", f"{DR}\t4\t8\tAssertionError: assert 3 == 2\n")
    mainf = _write(tmp_path, "main.txt", f"{DR}\t4\t8\n")

    rc = main(["decide", "--pr-failures", pr, "--main-rates", mainf])
    out = capsys.readouterr().out

    assert rc == 1
    assert "signature differs from main's" in out
    assert "no --main-signatures supplied" in out


def test_cli_signatures_emits_the_wire_table(tmp_path, capsys):
    """The producer's stdout is the shell-joinable table.

    MUTATION: print nothing (or an unnormalized line) → the row assertion REDs.
    """
    log = _write(tmp_path, "log.txt", _log(_OAUTH_BODY, ansi=True))

    rc = main(["signatures", "--log", log])
    captured = capsys.readouterr()

    assert rc == 0
    assert captured.out == f"{ID}\tAssertionError: assert (200 == 503)\n"
    assert "signed=1" in captured.err


def test_cli_signatures_fails_closed_when_nothing_parses(tmp_path, capsys):
    """A capture with no usable id exits non-zero — an unreadable set is not empty.

    MUTATION: return 0 when ``parsed.ok`` is False → RED (a vacuous producer would
    let the shell build a PR set with no ids, i.e. nothing to gate).
    """
    log = _write(tmp_path, "log.txt", _log("some prose\nanother line\n"))

    rc = main(["signatures", "--log", log])

    assert rc == 1


def test_cli_requires_a_subcommand():
    """MUTATION: ``add_subparsers(required=False)`` → no SystemExit → RED."""
    with pytest.raises(SystemExit) as exc:
        main([])
    assert exc.value.code == 2


def test_cli_rejects_an_unknown_subcommand():
    """MUTATION: a catch-all that accepts any argv → no SystemExit → RED."""
    with pytest.raises(SystemExit) as exc:
        main(["exempt-everything"])
    assert exc.value.code == 2


def test_decision_type_is_importable_for_the_cli():
    """A tiny guard that the CLI's own types stay exported (and that the
    ``Decision``/``Failure`` names the CLI builds are the same ones the tests
    drive). MUTATION: rename ``Decision`` → AttributeError → RED."""
    assert isinstance(decide({}, {}), Decision)
    assert Failure(rate=Rate(0, 0)).signatures == frozenset()


# ==========================================================================
# #4469 — GUARD-STEP ATTRIBUTION THROUGH THE PRODUCER AND THE WIRE
# ==========================================================================
#
# The measured capture (tortoise PR #4672, run 35785085760): pytest rc 0, the
# post-suite orphan guard red. The producer must emit a SIGNATURE ROW for it — a
# guard id with no signature would make ``_signatures_overlap`` fail closed and
# no guard exemption could ever be recorded. The echoed script SOURCE and the
# runner's generic exit annotation are in the fixture on purpose: neither may
# become an identity.
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


def _guard_capture(orphans: int = 16) -> str:
    """The real `--log-failed` shape, wrapped like the measured capture."""
    prefix = f"{_GUARD_JOB}\t{_GUARD_STEP}\t"
    echo_source = (
        '2026-09-23T01:19:53.8474165Z \x1b[36;1m    echo "::error::redislite server'
        ' leak: $COUNT orphans after suite, threshold $THRESHOLD (issue #1005 /'
        ' epic #1647 E2E-7)"\x1b[0m'
    )
    return "\n".join(
        [
            prefix + echo_source,
            prefix
            + f"2026-09-23T01:19:53.8645102Z ##[error]redislite server leak: {orphans}"
            + " orphans after suite, threshold 12 (issue #1005 / epic #1647 E2E-7)",
            prefix + f"2026-09-23T01:19:53.8649910Z {_GUARD_RUNNER_EXIT}",
            "python-ci-gate\tAggregate matrix result\t2026-09-23T01:20:00Z "
            + _GUARD_RUNNER_EXIT,
        ]
    ) + "\n"


def test_guard_step_annotation_becomes_a_signature_row():
    """The producer emits the guard id AND its (masked) error shape.

    MUTATION: skip the guard pass in ``parse_pr_failure_text`` → ``ids == []``,
    the producer exits 1, and the rail can never build a guard row → RED.
    MUTATION: store the raw message instead of the shape → the orphan COUNT
    differs between main and the PR and no exemption can match → the exact-string
    assertion REDs.
    """
    parsed = parse_pr_failure_text(_guard_capture())

    assert parsed.ids == [_GUARD_KEY]
    assert parsed.guard_steps == [_GUARD_KEY]
    assert parsed.signatures[_GUARD_KEY] == frozenset({_GUARD_SIG})
    assert parsed.unsigned == [], "a signed guard failure is not unsigned"
    assert parsed.ok is True


def test_the_echoed_source_and_the_runner_exit_are_not_identities():
    """Both negative fixtures must stay out of the id set (the exact id count).

    The echoed `echo "::error::…"` line is a MID-LINE mention and the aggregate
    step carries only the runner's own exit annotation; if either became an
    identity the capture would yield 2–3 ids instead of 1.
    """
    parsed = parse_pr_failure_text(_guard_capture())

    assert len(parsed.ids) == 1
    assert all("$COUNT" not in i for i in parsed.ids)
    assert all("Python-ci-gate" not in i for i in parsed.ids)


def test_cli_ids_reports_the_guard_step_attribution(tmp_path, capsys):
    """The shell's door: `ids` emits the guard key and REPORTS the attribution.

    MUTATION: drop the guard-steps summary line → the `guard-steps=1` assertion
    REDs, and the attribution becomes invisible in the rail's evidence.
    """
    log = _write(tmp_path, "guard.log", _guard_capture())

    rc = main(["ids", "--log", log])
    captured = capsys.readouterr()

    assert rc == 0
    assert captured.out == f"{_GUARD_KEY}\n"
    assert "guard-steps=1" in captured.err
    assert "guard-step failure ATTRIBUTED" in captured.err


def test_cli_signatures_emits_the_guard_row(tmp_path, capsys):
    """The producer's stdout is the shell-joinable guard row.

    MUTATION: emit no signature for the guard id → the empty-stdout / rc-1
    assertions RED, and the decision would fail closed on every guard failure.
    """
    log = _write(tmp_path, "guard.log", _guard_capture())

    rc = main(["signatures", "--log", log])
    captured = capsys.readouterr()

    assert rc == 0
    assert captured.out == f"{_GUARD_KEY}\t{_GUARD_SIG}\n"
    assert "guard-steps=1" in captured.err


def test_cli_signatures_still_fails_closed_on_a_generic_only_capture(tmp_path, capsys):
    """The refusal is PRESERVED at the producer door (#4469).

    A failing step whose only annotation is the runner's `Process completed with
    exit code 1.` names no failure, so the capture proves nothing and the
    producer must still exit non-zero with ZERO guard steps.

    MUTATION: treat the generic exit annotation as attribution → rc flips to 0,
    `ids=1`, and the rail would certify an unparseable run → RED.
    """
    log = _write(
        tmp_path,
        "generic.log",
        f"test (a)\tRun fast test suite\t2026-09-23T01:00:00Z {_GUARD_RUNNER_EXIT}\n",
    )

    rc = main(["signatures", "--log", log])
    captured = capsys.readouterr()

    assert rc == 1
    assert captured.out == ""
    assert "guard-steps=0" in captured.err


def test_cli_signatures_refuses_a_mixed_capture(tmp_path, capsys):
    """The producer door refuses an unparseable ROOT failure beside a guard hit.

    A sibling annotation must not stand in for the run's root failure: the
    `signatures` CLI still exits 1 with ZERO ids, so the rail's step-1c refusal
    fires. This is the shell-facing half of
    `test_an_unparseable_test_failure_is_not_laundered_by_a_sibling_guard`.

    MUTATION: drop the root-step condition in `guard_step_failures` → rc flips to
    0 with `ids=1`, and the cycle-3 false certificate is back → RED.
    """
    mixed = (
        "test (a)\tRun fast test suite\t2026-09-23T01:00:00Z "
        "E   ImportError: no module named y\n"
        "test (a)\tRun fast test suite\t2026-09-23T01:00:01Z "
        + _GUARD_RUNNER_EXIT
        + "\n"
        + _guard_capture()
    )
    log = _write(tmp_path, "mixed.log", mixed)

    rc = main(["signatures", "--log", log])
    captured = capsys.readouterr()

    assert rc == 1
    assert captured.out == ""
    assert "guard-steps=0" in captured.err


def test_cli_signatures_refuses_a_wrapper_annotation_in_the_failing_step(
    tmp_path, capsys
):
    """A same-step wrapper annotation is not pytest's classification.

    The cycle-2 finding at the producer door: a step that prints `E   ImportError`
    (pytest's own failure report) AND a substantive annotation must still refuse,
    because the annotation does not classify the failure. Without this the run is
    certified off a key that never names the failure.

    MUTATION: drop the `e_line_steps - nodeid_steps` clause → rc flips to 0 with
    `ids=1` → RED.
    """
    wrapped = (
        "test (a)\tRun fast test suite\t2026-09-23T01:00:00Z "
        "E   ImportError: no module named y\n"
        "test (a)\tRun fast test suite\t2026-09-23T01:00:01Z ##[error]tests failed\n"
        "test (a)\tRun fast test suite\t2026-09-23T01:00:02Z " + _GUARD_RUNNER_EXIT + "\n"
    )
    log = _write(tmp_path, "wrapped.log", wrapped)

    rc = main(["signatures", "--log", log])
    captured = capsys.readouterr()

    assert rc == 1
    assert captured.out == ""
    assert "guard-steps=0" in captured.err


def test_guard_key_flows_through_the_wire_rows_into_an_exemption():
    """END TO END through the producer's own wire formats: a guard exemption.

    The id derived from the REAL annotation is fed back through
    ``parse_failure_rows`` / ``parse_signature_rows`` (the two files the rail
    writes) and the decision EXEMPTS it — i.e. the guard failure participates in
    the PR-vs-main comparison exactly like a test nodeid.
    """
    key = parse_pr_failure_text(_guard_capture()).ids[0]

    rows = parse_failure_rows(f"{key}\t3\t8\t{_GUARD_SIG}\n")
    assert rows.rejected == [] and rows.unsigned == []
    main_rates = {key: Rate(3, 8)}
    main_sigs = parse_signature_rows(f"{key}\t{_GUARD_SIG}\n")
    assert main_sigs == {key: frozenset({_GUARD_SIG})}

    d = decide(rows.failures, main_rates, main_signatures=main_sigs, k_pr=8)
    assert not d.any_blocked, d.report()
    assert d.visible_exemptions()


def test_a_test_nodeid_still_flows_through_unchanged():
    """NO REGRESSION: the widened key predicate does not re-key a nodeid row.

    MUTATION: make the guard branch swallow every row → the nodeid row is
    rejected, ``failures`` is empty, and the exemption disappears → RED.
    """
    rows = parse_failure_rows(f"{DR}\t4\t8\tAssertionError: assert 3 == 2\n")
    assert list(rows.failures) == [DR]
    assert rows.rejected == []
    assert list(parse_signature_rows(f"{DR}\tAssertionError: assert 3 == 2\n")) == [DR]
