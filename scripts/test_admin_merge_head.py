#!/usr/bin/env python3
"""Tests for the rail's HEAD READ — `resolve_head` / `require_head` in scripts/admin-merge.sh.

WHY THIS FILE EXISTS (#1690). The rail blocked a fully-attested PR with:

    ✗ BLOCK — head moved before the evidence was posted (078f812a019394a3… → )

The head had NOT moved. `resolve_head` was a bare `$GH pr view … 2>/dev/null`, so a transient
failure returned the EMPTY STRING and the comparison read `"" != <head>` as "the head moved to
``". A confident claim about reality, derived from a read that failed — the instrument held the
exit status and discarded it.

The branch had no test that could call the read path DIRECTLY. (The rail CAN be driven
end-to-end hermetically through a fake `gh` — `tests/admin-merge/run.sh` has done so since #931
— but nothing could invoke `resolve_head`/`require_head` in isolation, so the empty-read branch
had no focused test.) These tests reach it directly: the script now carries the standard
`BASH_SOURCE` entry-point guard, so it can be sourced, and `ADMIN_MERGE_GH` (already the script's
own seam, line ~547) supplies a fake `gh`.

THE DISTINCTION UNDER TEST IS BETWEEN TWO SPEECH ACTS, not two strings:
  * an UNREADABLE head is NOT a claim about reality ("the instrument could not answer");
  * a MOVED head IS a claim about reality ("the evidence is SHA-bound and void").
Rendering the first as the second is the defect.
"""
from __future__ import annotations

import os
import re
import subprocess
import textwrap

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAIL = os.path.join(REPO_ROOT, "scripts", "admin-merge.sh")

VALID = "078f812a019394a366352d746a1641553ad51d4b"       # 40 hex — the real head from #1690
TRUNCATED = "078f812a019394a3"                            # what a partial read looks like


def _fake_gh(tmp_path, body: str, name: str = "gh") -> str:
    """Write an executable stand-in for `gh`. `body` is a bash fragment."""
    p = tmp_path / name
    p.write_text("#!/usr/bin/env bash\n" + body + "\n")
    p.chmod(0o755)
    return str(p)


def _drive(tmp_path, gh_body: str, bash_body: str,
           extra_env: dict | None = None) -> subprocess.CompletedProcess:
    """Source the rail with a fake `gh`, then run `bash_body` against it.

    `bash_body` runs INSIDE the sourced shell, so it can call the real functions.
    `extra_env` overrides the per-invocation env (e.g. a deliberately bad knob).
    """
    script = textwrap.dedent(f"""
        set -uo pipefail
        source {RAIL!r}
        {bash_body}
    """)
    env = dict(os.environ, ADMIN_MERGE_GH=_fake_gh(tmp_path, gh_body),
               # ⛔ SCOPED PER INVOCATION, NOT PROCESS-GLOBAL. `resolve_head` sleeps
               # `HEAD_READ_SLEEP * attempt` BETWEEN attempts, so a multi-attempt test would
               # spend its assertion budget waiting rather than asserting. Pinning the sleep to
               # 0 here is what keeps this suite fast however the seam's defaults are set — the
               # reason does not depend on what those defaults ARE, so this comment states no
               # numbers and cannot go stale when they change. It is set here rather than with a
               # module-level `os.environ.setdefault` so it stays out of every OTHER test in
               # the same pytest process (review round 2 measured that leak).
               ADMIN_MERGE_HEAD_READ_SLEEP="0")
    # ⛔ `update`, NOT `**extra_env` in the literal above: a caller overriding an already-named
    # key would otherwise raise `TypeError: dict() got multiple values for keyword argument`.
    # The first version of the sourced-path test hit exactly that and failed for that reason
    # rather than for any property of the rail.
    env.update(extra_env or {})
    return subprocess.run(["bash", "-c", script], capture_output=True, text=True,
                          env=env, cwd=REPO_ROOT, timeout=120, check=False)


def test_a_failed_read_returns_nonzero_and_prints_nothing(tmp_path):
    """The core of #1690: a read that FAILS must not look like a value."""
    r = _drive(tmp_path, "exit 1", "resolve_head 1; echo \"rc=$?\"")
    assert "rc=0" not in r.stdout, (
        "a failed read returned success — this is the exact shape that produced "
        "`head moved (… → )` and blocked a healthy PR")
    assert "rc=1" in r.stdout


def test_an_EMPTY_but_SUCCESSFUL_read_is_also_unreadable(tmp_path):
    """⛔ NOT JUST THE EMPTY STRING — the shape must be validated.

    A `gh` that exits 0 with no output is indistinguishable from `[ -n "$x" ]`
    perspective, and a half-read sha is worse: it passes a non-empty check and is
    compared as though it were a real commit.
    """
    r = _drive(tmp_path, "exit 0", "resolve_head 1; echo \"rc=$?\"")
    assert "rc=0" not in r.stdout, "an empty-but-successful read was accepted as a head"


def test_a_TRUNCATED_sha_is_rejected(tmp_path):
    """A partial read passes `[ -n ]` and would be compared as a real head.

    This is the case a retry alone does not fix, and the reason the fix validates
    the SHAPE (40 hex) rather than mere non-emptiness.
    """
    r = _drive(tmp_path, f'echo "{TRUNCATED}"; exit 0', "resolve_head 1; echo \"rc=$?\"")
    assert "rc=0" not in r.stdout, "a truncated sha was accepted as a head"


def test_a_valid_sha_is_returned_once(tmp_path):
    r = _drive(tmp_path, f'echo "{VALID}"; exit 0', "resolve_head 1")
    assert r.stdout.strip() == VALID


def test_the_read_RETRIES_a_transient_failure_then_succeeds(tmp_path):
    """A transient failure must have at least one retry before it is believed.

    The fake `gh` fails on its first call and succeeds afterwards — state is kept
    in a counter file, because a transient failure is precisely a read that would
    have worked a moment later.
    """
    counter = tmp_path / "n"
    body = textwrap.dedent(f"""
        n=$(cat {counter} 2>/dev/null || echo 0)
        n=$((n+1)); echo "$n" > {counter}
        if [ "$n" -lt 2 ]; then exit 1; fi
        echo "{VALID}"
    """)
    r = _drive(tmp_path, body, "resolve_head 1")
    assert r.stdout.strip() == VALID, f"the retry did not recover a transient failure: {r.stdout!r}"


def test_require_head_says_UNREADABLE_and_never_claims_the_head_moved(tmp_path):
    """⛔ THE SPEECH-ACT TEST, and the one that pins #1690 itself.

    On a failed read the message must say the read FAILED. It must NOT say the head
    moved: that is a different claim about reality, it voided SHA-bound evidence,
    and it is what the operator saw on a PR that had not moved.
    """
    r = _drive(tmp_path, "exit 1", "require_head 1 || true")
    assert "could not READ" in r.stderr, f"no unreadable-head message: {r.stderr!r}"
    # ⛔ THE LITERAL PHRASE IS KEPT OUT DELIBERATELY, not for the test's benefit. An
    # operator (and any log scraper) that greps "head moved" must match ONLY the
    # refusal that actually claims it. A refusal that negates the claim USING the
    # phrase is indistinguishable from the claim to a machine reading the log, which
    # is the same defect one layer up.
    assert "head moved" not in r.stderr, (
        "a FAILED READ was reported using the MOVED-HEAD phrase — this is #1690, and it "
        "also makes the two refusals indistinguishable to anything scraping the log")
    assert "Nothing was merged" in r.stderr, "the refusal must state that no merge happened"


def test_require_head_propagates_the_value_on_success(tmp_path):
    r = _drive(tmp_path, f'echo "{VALID}"; exit 0', "require_head 1")
    assert r.stdout.strip() == VALID
    assert "could not READ" not in r.stderr


def test_every_head_comparison_goes_through_require_head():
    """⛔ THE DUPLICATION PIN. Three call sites compare the head; if ONE of them still
    calls `resolve_head` directly it has no way to tell an unread head from a moved
    one, and the fix is partial in exactly the way that is hardest to notice.

    `resolve_head` may be called only from `require_head` (and never otherwise).
    """
    with open(RAIL) as fh:
        src = fh.read()
    # Look only OUTSIDE `require_head`'s own body: its single internal call is the
    # legitimate one, and a detector that cannot tell the two apart would either
    # pass vacuously or fail on the function it is meant to protect.
    after = src.split("require_head() {", 1)[1]
    body_end = after.index("\n}\n")
    inside, rest = after[:body_end], after[body_end + 3:]
    calls = [ln.strip() for ln in rest.splitlines()
             if "resolve_head " in ln and "()" not in ln and "require_head" not in ln]
    assert calls == [], (
        "these call sites still call resolve_head directly and cannot distinguish an "
        f"UNREADABLE head from a MOVED one: {calls}")
    # ...and the detector is not vacuous: require_head must actually do the read.
    assert "resolve_head \"$pr\"" in inside, (
        "require_head no longer performs the read — the guard above would pass for the "
        "wrong reason")


# ── THE COMPOSITION (#1690, review round 2) ───────────────────────────────────
# ⛔ WHY THESE EXIST. The first version of this suite pinned `require_head` itself and the
# call-site ROUTING, and its author reported that as sufficient. A reviewer then MEASURED the
# refusal composition instead of reading it: with `require_head` keeping its full, correct
# message but returning 0, or with either comparison site dropping `|| exit 1`, **0 of the 8
# tests failed** — and with one site's guard changed to `|| true`, the rail printed the correct
# refusal AND THEN the original `head moved ... ( ... -> )`. So the bug this file was written
# for was still reachable with every test green. A correct function whose failure nothing
# checks is the original defect under a new name.


def test_a_failed_read_that_is_not_propagated_CAN_reprint_the_moved_head(tmp_path):
    """The composition, run as the call sites actually run it.

    This drives the same two-line pattern the real comparison sites use, with a fake `gh`
    whose read ALWAYS fails. The assertion is on the OUTCOME the operator sees: the process
    must abort, and the moved-head sentence must never be printed. That is what was measured
    to survive all 8 original tests.
    """
    r = _drive(
        tmp_path,
        "exit 1",
        'h="$(require_head 1)" || exit 1; '
        '[ "$h" = "deadbeef" ] || echo "admin-merge: BLOCK - head moved before the evidence was posted (deadbeef -> $h)"',
    )
    assert "head moved" not in r.stdout, (
        "a FAILED HEAD READ reached the moved-head message — this is #1690 itself, and it "
        f"means the `|| exit 1` that is supposed to abort was not honoured: {r.stdout!r}")
    assert r.returncode != 0, (
        "the process exited 0 after a failed head read — the failure was swallowed, so every "
        "downstream comparison runs against an EMPTY head")
    assert "could not READ" in r.stderr, (
        f"no unreadable-head refusal reached stderr: {r.stderr!r}")


def test_the_unreadable_refusal_carries_a_machine_readable_tag(tmp_path):
    """⛔ SEPARATING THE TWO SPEECH ACTS MUST NOT DEPEND ON PROSE.

    The rail's two refusals mean different things — "the instrument could not answer" vs
    "the evidence is void because the head really moved" — and the first version separated
    them by WORDING only. A consumer that must tell them apart would have to parse prose, and
    a future rewording would silently destroy the distinction. `[head_unreadable]` is the tag
    the moved-head refusals do NOT carry, so its PRESENCE is now pinned, not just the absence
    of the other phrase.
    """
    r = _drive(tmp_path, "exit 1", "require_head 1 || true")
    assert "[head_unreadable]" in r.stderr, (
        "the unreadable-head refusal carries no machine-readable tag, so distinguishing it "
        f"from a moved head requires parsing prose: {r.stderr!r}")


def test_a_MULTI_LINE_read_is_rejected(tmp_path):
    """⛔ THE WHOLE VALUE MUST BE VALIDATED, NOT A LINE OF IT.

    The first version of the shape check was `printf '%s' "$out" | grep -qE '^[0-9a-fA-F]{40}$'`,
    which is an ANY-LINE test: a read returning a good sha AND a trailing junk line PASSED it,
    and `printf '%s\n' "$out"` then emitted BOTH lines — so a multi-line value flowed into the
    comparisons, the evidence body and `--match-head-commit`. An embedded newline is not a hex
    character, so the whole-value check rejects this by construction. This test pins that.
    """
    r = _drive(
        tmp_path,
        f"printf '%s\\n' '{VALID}' 'JUNK-SECOND-LINE'; exit 0",
        'resolve_head 1; echo "rc=$?"',
    )
    assert "rc=0" not in r.stdout, (
        "a MULTI-LINE read (valid sha + a junk line) was accepted as a head — the shape check "
        f"is matching a LINE rather than the whole value: {r.stdout!r}")


def test_every_head_read_that_is_assigned_is_guarded():
    """The structural half of the composition pin.

    Every `require_head` whose result is ASSIGNED must propagate its failure on the same line.
    A non-zero return that nothing checks is invisible: the assignment succeeds, `$head` is
    empty, and the next comparison reports a moved head.

    ⛔ THE GUARD MUST FOLLOW THE SUBSTITUTION'S CLOSING PAREN — a `|| exit 1` written INSIDE
    `$( … )` exits only the SUBSHELL, so the parent continues with an empty head. Measured
    (review round 2): that shape reproduced #1690 with all 12 tests green, as did a guard that
    exists only in a trailing COMMENT (`|| true  # was || exit 1`).

    ⛔ WHAT THIS TEST CANNOT DO, stated rather than implied: it is a source scan, so it sees
    only the shapes it knows to look for. Reformatting the call across lines, or writing it as
    a process substitution or in backticks, produced four measured false negatives in round 2.
    Those are covered by OUTCOME in `tests/admin-merge/run.sh` §13b/§13c/§13d, which drive the
    real call sites and so cannot be reformatted away. This is the fast half; that is the
    durable half. Both are required.
    """
    with open(RAIL) as fh:
        src = fh.read()

    def without_trailing_comment(line: str) -> str:
        i = line.find(" #")
        return line[:i] if i != -1 else line

    # ⛔ COLLECT BY NAME, NOT BY `$(` (#1690 review round 3). Requiring `$(` on the SAME line was
    # itself a measured false negative: a call split across lines carries `$(` on the first line
    # and `require_head ` on a later one, so the site was never collected and the test passed
    # GREEN while the rail proceeded with an empty head. Selecting every line that NAMES the
    # function, then requiring the guard to follow the substitution's closing paren, catches
    # that shape. If this ever over-blocks a legitimate reformat that is the SAFE direction for
    # a safety rail — and the durable half (§13b/§13c/§13d, which drive the real call sites)
    # is what actually proves the behaviour.
    calls = [without_trailing_comment(ln).strip() for ln in src.splitlines()
             if "require_head " in ln and not ln.lstrip().startswith("#")]
    assert calls, "detector is vacuous: no assigning require_head call site was found"
    guard = re.compile(r'\)"?\s*\|\|\s*exit 1\s*$')
    unguarded = [c for c in calls if not guard.search(c)]
    assert unguarded == [], (
        "these call sites do not carry `|| exit 1` on the CLOSING-PAREN LINE of the command "
        "substitution, so a failed read could flow on as an empty head and be rendered as a "
        "MOVED head (#1690). ⛔ IF ONE OF THE LINES BELOW IS A LEGITIMATE REFORMAT that puts "
        "the guard on that line, this is an over-block (the safe direction) — the fix is to "
        "move the guard onto the closing-paren line, NOT to relax this check, because the "
        "outcome scenarios (§13b/§13c/§13d/§13e) are the ones that prove the behaviour and "
        f"this scan only has to not lie. Offending: {unguarded}")


# ── THE RETRY BUDGET IS A KNOB, AND A BAD KNOB MUST NOT LOOK LIKE THE BUG ─────
# ⛔ WHY THESE TWO EXIST. The validation was initially written INLINE in `resolve_head` as
# `case "$attempts" in '' | *[!0-9]*) attempts=3 ;; esac`, and review round 3 MEASURED what that
# misses: `08` contains no non-digit, so it passes, and bash ARITHMETIC then reads it as an
# invalid OCTAL and errors — after which the rail STILL emitted `[head_unreadable]`. So it
# asserted "the instrument could not read the head" on a run where the instrument never ran:
# #1690's own symptom, machine-readably, one layer out.
#
# A positive control is required: without it, a test asserting "a bad knob is refused" would
# pass just as happily if the rail refused EVERYTHING, including good values.

def _run_rail(env_overrides: dict) -> subprocess.CompletedProcess:
    env = dict(os.environ, ADMIN_MERGE_GH="/bin/false", ADMIN_MERGE_POLL_INTERVAL="0",
               **env_overrides)
    return subprocess.run(["bash", RAIL, "42", "--main-runs", "1"], capture_output=True,
                          text=True, env=env, cwd=REPO_ROOT, timeout=60, check=False)


def test_a_bad_retry_budget_is_refused_BY_NAME_not_as_an_unreadable_head():
    """A leading zero is OCTAL to bash arithmetic, so `08` is not 8 — it is an error.

    The refusal must name the KNOB. It must never carry the unreadable-head tag, because the
    tag is a claim about the instrument's own read and no read was attempted.
    """
    r = _run_rail({"ADMIN_MERGE_HEAD_ATTEMPTS": "08"})
    assert r.returncode == 2, (
        f"expected the knob refusal (exit 2), got {r.returncode}: {r.stderr!r}")
    assert "ADMIN_MERGE_HEAD_ATTEMPTS" in r.stderr, (
        f"the refusal must NAME the knob it refused: {r.stderr!r}")
    assert "[head_unreadable]" not in r.stderr, (
        "a BAD KNOB was reported as an UNREADABLE HEAD — the rail asserted a claim about its "
        "own read on a run where no read was attempted, which is #1690's symptom exactly")


def test_a_valid_retry_budget_is_accepted_and_reaches_the_head_read():
    """⛔ THE POSITIVE CONTROL. Without it, the test above also passes if the rail refuses
    every value — including the good ones — which would be a far worse regression than the
    one it guards against, and would look identical from the bad-knob side."""
    r = _run_rail({"ADMIN_MERGE_HEAD_ATTEMPTS": "3", "ADMIN_MERGE_HEAD_READ_SLEEP": "0"})
    assert r.returncode != 2, (
        f"a VALID retry budget was refused as a bad knob value: {r.stderr!r}")
    assert "[head_unreadable]" in r.stderr, (
        "the positive control never reached the head read, so it does not prove the knob was "
        f"accepted — it only proves some later step failed: {r.stderr!r}")


def test_the_SOURCED_path_refuses_a_bad_knob_instead_of_claiming_an_unread_head(tmp_path):
    """⛔ THE GUARD'S OWN TEST — WHICH IT DID NOT HAVE (review round 5, MEASURED).

    Deleting the `require_head`/`resolve_head` knob guard left **14/14 unit tests AND the whole
    rail suite green**, while the SOURCED path reproduced #1690 exactly: with
    `ADMIN_MERGE_HEAD_ATTEMPTS=0` the loop body never ran, so ZERO reads were attempted, and the
    rail still printed `[head_unreadable] — could not READ the head … (0 attempts)`.

    `validate_timing_knobs` cannot catch this: it runs only inside `main()`, and this is a sourced
    call. That is why EVERY bad-knob test that drives `main` passes with or without the guard —
    and why the guard, the round-4/5 delta's only production change, was unenforced. A fix that no
    test exercises is not a fix, which is the same sentence this PR keeps rediscovering.
    """
    # ⛔ BOTH ENTRY POINTS AND BOTH KNOBS. The delta's claim is ONE helper called by BOTH
    # resolvers, and the SLEEP knob has its own predicates (a NUMBER, so 0 is legal, unlike the
    # ATTEMPTS budget which must be POSITIVE). Review round 5 MEASURED that varying only
    # `require_head` + `ATTEMPTS` pinned HALF the change: deleting the `resolve_head` guard left
    # 16/16 green, and deleting all three SLEEP predicates left 16/16 green — after which a sourced
    # `ADMIN_MERGE_HEAD_READ_SLEEP=abc` died on `abc: unbound variable` inside the arithmetic and
    # STILL emitted `[head_unreadable]`. That is what this matrix exists to catch.
    for fn, knob, bad, why in (
        ("require_head", "ADMIN_MERGE_HEAD_ATTEMPTS", "0", "permits no read at all"),
        ("require_head", "ADMIN_MERGE_HEAD_ATTEMPTS", "08", "is invalid octal to the arithmetic"),
        ("require_head", "ADMIN_MERGE_HEAD_ATTEMPTS", "abc", "is not a number"),
        ("require_head", "ADMIN_MERGE_HEAD_READ_SLEEP", "abc", "is not a number"),
        ("require_head", "ADMIN_MERGE_HEAD_READ_SLEEP", "010", "is a leading zero (octal)"),
        ("resolve_head", "ADMIN_MERGE_HEAD_ATTEMPTS", "0", "permits no read at all"),
        ("resolve_head", "ADMIN_MERGE_HEAD_ATTEMPTS", "08", "is invalid octal to the arithmetic"),
        ("resolve_head", "ADMIN_MERGE_HEAD_READ_SLEEP", "abc", "is not a number"),
        # Symmetry: `require_head` is pinned for `010` above, so `resolve_head` is too. The owner
        # of the arithmetic is `resolve_head`, and a leading-zero knob is the case where the two
        # disagree — testing the delegator but not the owner is how round 5's guard went uncovered.
        ("resolve_head", "ADMIN_MERGE_HEAD_READ_SLEEP", "010", "is a leading zero (octal)"),
    ):
        r = _drive(tmp_path, "exit 1", f'{fn} 1; echo "rc=$?"', extra_env={knob: bad})
        assert "refusing a bad head-read knob" in r.stderr, (
            f"{fn} with {knob}={bad} ({why}) was NOT refused on the SOURCED path: {r.stderr!r}")
        assert "[head_unreadable]" not in r.stderr, (
            f"{fn} with {knob}={bad} produced an UNREADABLE-HEAD claim on the sourced path — "
            "#1690's symptom, emitted by the instrument on a run whose budget may permit zero "
            "reads")
        # ⛔ ASSERT ON THE FUNCTION'S OWN STATUS, NOT THE SCRIPT'S. A bash body that ends in
        # `echo` exits 0 whatever happened, and the FIRST version of this test wrote
        # `require_head 1 || true`, which FORCES 0 — so `assert r.returncode != 0` was
        # unsatisfiable and the test was red on a CORRECT rail (review round 5 measured it).
        assert "rc=0" not in r.stdout, (
            f"{fn} must return non-zero for {knob}={bad} ({why}): {r.stdout!r}")


def test_the_SOURCED_path_accepts_a_valid_knob(tmp_path):
    """The positive control for the test above: without it, a guard that refused EVERYTHING on
    the sourced path would pass, and the rail would be unusable for every real caller."""
    r = _drive(tmp_path, "exit 1", 'require_head 1; echo "rc=$?"',
               extra_env={"ADMIN_MERGE_HEAD_ATTEMPTS": "3"})
    assert "refusing a bad head-read knob" not in r.stderr, (
        f"a VALID knob was refused on the SOURCED path: {r.stderr!r}")
    assert "[head_unreadable]" in r.stderr, (
        "the positive control never reached the read, so it does not prove the knob was accepted")


# ── THE REFUSAL MUST CARRY THE READ'S OWN WORDS (#1690 review) ────────────────────────────
# `2>/dev/null` was the defect's own shape. It is why a transient blip and a permanent cause
# (bad credentials, wrong `--repo`, PR not found) produced the SAME refusal, with a remedy
# ("re-run the rail") that can never help the permanent ones. These tests pin both directions
# of the diagnostic channel: it is QUOTED when it exists, and its ABSENCE is stated rather
# than papered over.
def test_the_refusal_quotes_the_reads_diagnostic(tmp_path):
    """A permanent cause must be distinguishable from a transient one in the refusal."""
    r = _drive(tmp_path,
               'echo "HTTP 403: API rate limit exceeded for user ID 1" >&2\nexit 1',
               'require_head 1; echo "rc=$?"')
    assert "API rate limit exceeded" in r.stderr, (
        "the refusal discarded the read's diagnostic, so a permanent cause is "
        f"indistinguishable from a transient blip: {r.stderr!r}")
    # The refusal must still be the UNREADABLE one, and still carry its tag: quoting a
    # diagnostic must not turn it into a claim about reality.
    assert "[head_unreadable]" in r.stderr, f"the tag was lost: {r.stderr!r}"
    assert "head moved" not in r.stderr, (
        f"an unreadable head was rendered as a moved head: {r.stderr!r}")


def test_the_refusal_says_so_when_there_is_no_diagnostic(tmp_path):
    """The other direction: silence must be REPORTED, not rendered as a generic 're-run the
    rail' — that is the same defect one layer up (absence read as a benign fact)."""
    r = _drive(tmp_path, "exit 1", 'require_head 1; echo "rc=$?"')
    assert "produced no diagnostic" in r.stderr, (
        "a silent failure was reported as if a diagnostic had been quoted, or not "
        f"reported at all: {r.stderr!r}")
    assert "[head_unreadable]" in r.stderr, f"the tag was lost: {r.stderr!r}"


def test_a_successful_read_leaves_no_diagnostic_behind(tmp_path):
    """The channel must not leak a stale or spurious diagnostic into a SUCCESS."""
    r = _drive(tmp_path, f'printf "%s\\n" {VALID} >&2\nprintf "%s\\n" {VALID}',
               'require_head 1; echo "rc=$?"')
    assert "rc=0" in r.stdout, f"a valid head was not returned: {r.stdout!r}"
    assert "the read reported" not in r.stderr, (
        f"a stale or spurious diagnostic was printed on a SUCCESS: {r.stderr!r}")


def test_the_diagnostic_is_captured_on_the_LAST_attempt_not_the_first(tmp_path):
    """Retry semantics: the diagnostic quoted must be the one closest to the refusal. A fake
    `gh` failing with a DISTINCT message per call proves which attempt's words survive.

    ⛔ THE COUNTER MUST LIVE IN A FILE, NOT IN THE CHILD'S ENV. The first version of this test
    did `export ADMIN_MERGE_HEAD_CALLS=$((n+1))` inside the fake `gh` — but each attempt is a
    SEPARATE PROCESS, and a child's `export` cannot reach the parent shell, so every attempt
    read an unset variable and wrote `attempt 1`. The test then failed (measured) while the
    rail was quoting the last attempt correctly: a fixture defect that would have been easy to
    misread as a rail defect. `$0` is the fake `gh`'s own path, which DOES persist across
    invocations, so the counter rides on a file beside it.
    """
    body = (
        'c="$0.calls"\n'
        'n=0\n'
        '[ -s "$c" ] && n="$(cat "$c")"\n'
        'n=$((n + 1))\n'
        'printf "%s" "$n" > "$c"\n'
        'echo "attempt $n: distinct diagnostic" >&2\n'
        'exit 1\n'
    )
    r = _drive(tmp_path, body, 'require_head 1; echo "rc=$?"',
               extra_env={"ADMIN_MERGE_HEAD_ATTEMPTS": "3"})
    assert "attempt 3: distinct diagnostic" in r.stderr, (
        f"the diagnostic quoted is not the last attempt's: {r.stderr!r}")
    assert "attempt 1:" not in r.stderr and "attempt 2:" not in r.stderr, (
        f"an earlier attempt's diagnostic leaked into the refusal: {r.stderr!r}")
