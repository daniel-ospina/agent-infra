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


def _drive(tmp_path, gh_body: str, bash_body: str) -> subprocess.CompletedProcess:
    """Source the rail with a fake `gh`, then run `bash_body` against it.

    `bash_body` runs INSIDE the sourced shell, so it can call the real functions.
    """
    script = textwrap.dedent(f"""
        set -uo pipefail
        source {RAIL!r}
        {bash_body}
    """)
    env = dict(os.environ, ADMIN_MERGE_GH=_fake_gh(tmp_path, gh_body),
               # ⛔ SCOPED PER INVOCATION, NOT PROCESS-GLOBAL. `resolve_head` retries with an
               # exponential backoff (`sleep 1`, then `sleep 2`), so at the seam's default
               # this suite spends ~13 s of its ~16 s ASLEEP and the `--timeout=60` budget in
               # both CI lanes is mostly spent waiting rather than asserting. Setting it here
               # rather than with a module-level `os.environ.setdefault` keeps it out of every
               # OTHER test in the same pytest process (review round 2 measured that leak).
               ADMIN_MERGE_HEAD_READ_SLEEP="0")
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
