#!/usr/bin/env python3
"""Tests for the rail's HEAD READ — `resolve_head` / `require_head` in scripts/admin-merge.sh.

WHY THIS FILE EXISTS (#1690). The rail blocked a fully-attested PR with:

    ✗ BLOCK — head moved before the evidence was posted (078f812a019394a3… → )

The head had NOT moved. `resolve_head` was a bare `$GH pr view … 2>/dev/null`, so a transient
failure returned the EMPTY STRING and the comparison read `"" != <head>` as "the head moved to
``". A confident claim about reality, derived from a read that failed — the instrument held the
exit status and discarded it.

The branch had no test at all, because the ONLY way to reach it was to run the whole rail, which
needs a live PR. These tests reach it directly: the script now carries the standard
`BASH_SOURCE` entry-point guard, so it can be sourced, and `ADMIN_MERGE_GH` (already the script's
own seam, line ~547) supplies a fake `gh`.

THE DISTINCTION UNDER TEST IS BETWEEN TWO SPEECH ACTS, not two strings:
  * an UNREADABLE head is NOT a claim about reality ("the instrument could not answer");
  * a MOVED head IS a claim about reality ("the evidence is SHA-bound and void").
Rendering the first as the second is the defect.
"""
from __future__ import annotations

import os
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
    env = dict(os.environ, ADMIN_MERGE_GH=_fake_gh(tmp_path, gh_body))
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
