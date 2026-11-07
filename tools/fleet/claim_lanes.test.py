#!/usr/bin/env python3
"""tools/fleet/claim_lanes.test.py — the #1777 ref-claim reader acceptance suite.

Thirty-six tests with forty-eight paired mutations: every mutation re-introduces
the defect its test exists to catch, so "the test fails without the fix" is an
EXECUTED claim rather than an asserted one (the standard this repo's
``liveness.test.py`` set).

    python3.12 tools/fleet/claim_lanes.test.py              # the 36 tests, green
    python3.12 tools/fleet/claim_lanes.test.py --mutations  # each mutation, RED

`--mutations` writes BOTH modules — a mutated copy of one and a verbatim copy of
the other — into a temp dir, and runs the paired test against that pair in a
subprocess. Writing the pair (not just the mutated file) is load-bearing: the
reader imports its sibling classifier (``import liveness``) from its own
directory, so the mutant pair must be importable together. The real files are
never modified. A mutation whose paired test PASSES is reported as a failure of
the suite.

Evidence for the incident (#1777), which is what the fixtures reproduce:

  * ``ls-remote`` FAILS  ⇒ ``readable=False`` ⇒ an abstention, never "no claim".
  * ``ls-remote`` OK, zero refs ⇒ a readable read with ``present=False`` — a
    DIFFERENT reason from the failure above.
  * presence with unreadable metadata ⇒ ``present=True, owner="?"`` ⇒ presence
    alone refutes freedom.
  * a live local lease ⇒ ``claim-held``; a foreign owner is NEVER probed.
  * the lease polarity is ``claims.sh``'s own (absent / ``0`` / non-digit /
    >18 digits ⇒ unknown, and unknown is NOT expired), checked against the
    SHIPPED shell primitives rather than against a transcription of them.
  * a relative ``origin`` names ONE absolute target from any cwd, while an
    absolute/scp-like remote passes through VERBATIM; a credential in the remote URL is
    never echoed; a NON-FINITE staleness bound is refused; and the CLI's default (text)
    output is asserted — the cycle-1 review findings.

Injected, never guessed:
  * CLAIM_LANES_MODULE — the reader under test (default: ./claim_lanes.py)
  * CLAIM_LANES_ONLY   — run one test by id (set by --mutations)
  * CLAIMS_SH          — the shipped shell registry (default: ../../scripts/orchestrator-harness/claims.sh)
"""

from __future__ import annotations

import contextlib
import importlib.util
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
MODULE_PATH = os.path.normpath(os.environ.get("CLAIM_LANES_MODULE") or
                               os.path.join(HERE, "claim_lanes.py"))
CLASSIFIER_PATH = os.path.normpath(os.path.join(os.path.dirname(MODULE_PATH), "liveness.py"))
CLAIMS_SH = os.path.normpath(os.path.join(
    HERE, "..", "..", "scripts", "orchestrator-harness", "claims.sh"))

EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
NOW_S = 1_789_000_000
HOST = "test-box"
OTHER_HOST = "cmux"


def _load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    # Register BEFORE exec: dataclasses resolves string annotations through
    # sys.modules[cls.__module__].
    sys.modules[name] = mod
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


# The reader inserts its OWN directory on sys.path and imports `liveness` from
# there, so loading the mutant reader must not reuse a stale classifier.
sys.modules.pop("liveness", None)
cl = _load_module("fleet_claim_lanes_under_test", MODULE_PATH)
liv = sys.modules["liveness"]

# ── tiny test runner (the suite is a script, not a pytest module) ────────
TESTS = []


def test(name):
    def deco(fn):
        TESTS.append((name, fn))
        return fn
    return deco


class Failure(AssertionError):
    pass


def check(cond, msg):
    if not cond:
        raise Failure(msg)


# ── git fixtures (real git, real refs, a file:// transport; no network) ──
GIT_ENV = {
    "GIT_AUTHOR_NAME": "claim-test", "GIT_AUTHOR_EMAIL": "claim@test",
    "GIT_COMMITTER_NAME": "claim-test", "GIT_COMMITTER_EMAIL": "claim@test",
    "GIT_TERMINAL_PROMPT": "0",
}


def git(args, cwd=None):
    return subprocess.run(["git", *args], cwd=cwd, env=dict(os.environ, **GIT_ENV),
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def commit_claim(repo, ref, owner, lease_raw):
    """Write ONE root claim commit at ``ref`` — the ``claims.sh`` object shape.

    The message is built exactly as ``_claim_commit`` builds it, so the fixtures
    differ from production only in the nonce.
    """
    msg = "claim owner=%s lease_until=%s nonce=%d" % (owner, lease_raw, os.getpid())
    proc = git(["-C", repo, "commit-tree", EMPTY_TREE, "-m", msg])
    check(proc.returncode == 0, "commit-tree failed: %s" % proc.stderr.strip())
    sha = proc.stdout.strip()
    upd = git(["-C", repo, "update-ref", ref, sha])
    check(upd.returncode == 0, "update-ref failed: %s" % upd.stderr.strip())
    return sha


@contextlib.contextmanager
def bare_remote(claims=(), local_refs=()):
    """A hermetic remote. ``claims`` = [(ref, owner, lease_raw), …]."""
    d = tempfile.mkdtemp(prefix="claims-remote-")
    try:
        bare = os.path.join(d, "origin.git")
        git(["init", "-q", "--bare", bare])
        for ref, owner, lease in claims:
            commit_claim(bare, ref, owner, lease)
        for ref, owner, lease in local_refs:
            commit_claim(bare, ref, owner, lease)
        yield bare
    finally:
        shutil.rmtree(d, ignore_errors=True)


@contextlib.contextmanager
def work_repo(remote, local_refs=()):
    """A non-bare checkout whose ``origin`` is ``remote``."""
    d = tempfile.mkdtemp(prefix="claims-work-")
    try:
        git(["init", "-q", d])
        git(["-C", d, "remote", "add", "origin", remote])
        for ref, owner, lease in local_refs:
            commit_claim(d, ref, owner, lease)
        yield d
    finally:
        shutil.rmtree(d, ignore_errors=True)


@contextlib.contextmanager
def git_shim(fail=("ls-remote", "fetch", "cat-file")):
    """A PATH shim: the named git subcommands fail, everything else passes through.

    ``fail=()`` models git absent/entirely failing; ``fail=("fetch",)`` models
    "presence established, metadata not". The shim matches SUBCOMMAND argv, not
    substrings of the whole call, so ``-C <dir> init --bare`` still reaches git.
    """
    d = tempfile.mkdtemp(prefix="claims-shim-")
    try:
        real_git = shutil.which("git") or "/usr/bin/git"
        path = os.path.join(d, "git")
        with open(path, "w", encoding="utf-8") as fh:
            if fail:
                fh.write(
                    "#!/usr/bin/env bash\n"
                    "fail=' %s '\n"
                    "for a in \"$@\"; do\n"
                    "  case \"$fail\" in *\" $a \"*) exit 128 ;; esac\n"
                    "done\n"
                    "exec %s \"$@\"\n" % (" ".join(fail), real_git)
                )
            else:
                # Every call fails (git absent / entirely unable to reach the remote).
                fh.write("#!/usr/bin/env bash\nexit 128\n")
        os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
        yield d
    finally:
        shutil.rmtree(d, ignore_errors=True)


@contextlib.contextmanager
def env_with(path_dir):
    old = os.environ.get("PATH", "")
    os.environ["PATH"] = path_dir + os.pathsep + old
    try:
        yield
    finally:
        os.environ["PATH"] = old


def write_snapshot(d, text, age_s=0):
    path = os.path.join(d, "claims-snapshot")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    t = NOW_S - age_s
    os.utime(path, (t, t))
    return path


# ══════════════════════════════════════════════════════════════════════════
# L1 — the PULL driver reads presence, owner, lease and scope
# ══════════════════════════════════════════════════════════════════════════
@test("L1 pull: owner/lease/scope are parsed and an EXPIRED lease reads expired (#1777)")
def l1_pull_parses_rows():
    live_until = NOW_S + 1800
    with bare_remote([("refs/claims/5-abcdef123456", "%s:4242" % HOST, str(live_until)),
                      ("refs/claims/6-123456abcdef", "%s:99" % OTHER_HOST, str(NOW_S - 60))]) as remote:
        cr = cl.read_pull(remote, host=HOST, now=NOW_S)
    check(cr.readable is True, "a successful ls-remote is a readable read")
    check(cr.present is True, "two refs are present")
    check(len(cr.claims) == 2, "both claims are read; got %d" % len(cr.claims))
    by_key = {c.key: c for c in cr.claims}
    a = by_key["5-abcdef123456"]
    check((a.pr, a.sha12) == ("5", "abcdef123456"), "the key is split into pr/sha12: %r" % (a.key,))
    check(a.owner == "%s:4242" % HOST and a.owner_pid == 4242 and a.owner_host == HOST,
          "the owner string is parsed: %r" % (a.owner,))
    check(a.scope == "local", "an owner host equal to this host is LOCAL; got %s" % a.scope)
    check(a.lease_until == live_until and a.lease_state == "live",
          "an open window reads live; got %r/%s" % (a.lease_until, a.lease_state))
    b = by_key["6-123456abcdef"]
    check(b.scope == "foreign", "another host is FOREIGN; got %s" % b.scope)
    check(b.lease_state == "expired",
          "a past lease reads EXPIRED, not live; got %s" % b.lease_state)
    check(b.lease_until == NOW_S - 60, "the lease value is preserved; got %r" % (b.lease_until,))
    # and the reader's bridge yields an abstention, never a state of its own
    v = liv.evaluate(cl.to_evidence(cr, now_ms=NOW_S * 1000))
    check(v.state == "unknown" and v.reason in liv.CLAIM_REASONS,
          "got %s/%s" % (v.state, v.reason))


# ══════════════════════════════════════════════════════════════════════════
# L2 — a FAILED read is never an absence
# ══════════════════════════════════════════════════════════════════════════
@test("L2 pull: a failed ls-remote is UNREADABLE (never 'no claim') (#1777 adversarial B2)")
def l2_pull_unreadable_is_not_absent():
    d = tempfile.mkdtemp(prefix="claims-absent-")
    try:
        cr = cl.read_pull(os.path.join(d, "does-not-exist.git"), host=HOST, now=NOW_S)
        check(cr.readable is False, "a missing remote is an unreadable read")
        check(cr.claims == () and cr.present is False,
              "an unreadable read carries no claims and no presence")
        check(cr.detail, "the cause is named; got %r" % cr.detail)
        v = liv.evaluate(cl.to_evidence(cr))
        check(v.state == "unknown" and v.reason == "claims-unreadable",
              "got %s/%s" % (v.state, v.reason))
        check(v.holder_pid is None, "an unreadable read must not name an incarnation")
    finally:
        shutil.rmtree(d, ignore_errors=True)
    # git itself failing (absent / unauthenticated) takes the same path
    with bare_remote([("refs/claims/5-abcdef123456", "h:1", str(NOW_S + 60))]) as remote:
        with git_shim(fail=()) as shim, env_with(shim):
            cr = cl.read_pull(remote, host=HOST, now=NOW_S)
    check(cr.readable is False, "a git failure is an unreadable read; got %r" % cr.detail)
    check("rc=128" in cr.detail, "the failing rc is named; got %r" % cr.detail)
    # The CLI exit policy is fail-CLOSED (verify-gate P2): a visible claim is the positive
    # answer, while a readable-but-empty read and an unreadable one are BOTH "nothing
    # established" — so `if claim_lanes.py …; then` can never mean "nobody is on it".
    check(_cli_rc(["--remote-url", os.path.join(d, "nope.git")]) == 3,
          "an unreadable read must exit 3")
    with bare_remote([("refs/claims/5-abcdef123456", "h:1", str(NOW_S + 60))]) as remote:
        check(_cli_rc(["--remote-url", remote, "--pr", "5"]) == 0,
              "a VISIBLE claim exits 0 (the positive answer)")
        check(_cli_rc(["--remote-url", remote, "--pr", "999999"]) == 3,
              "a readable read with NO claim for the head exits 3, never 0")
        check(_cli_rc(["--remote-url", remote]) == 0,
              "an unfiltered read that sees a claim exits 0")


# ══════════════════════════════════════════════════════════════════════════
# L3 — a readable, EMPTY registry is a different fact from an unreadable one
# ══════════════════════════════════════════════════════════════════════════
@test("L3 pull: rc=0 with zero refs is READABLE and empty — a distinct reason (#1777)")
def l3_pull_empty_is_readable():
    with bare_remote(()) as remote:
        cr = cl.read_pull(remote, host=HOST, now=NOW_S)
    check(cr.readable is True, "an empty namespace is still a successful read")
    check(cr.present is False and cr.claims == (), "no claims, no presence")
    v = liv.evaluate(cl.to_evidence(cr))
    check(v.state == "unknown", "an empty registry abstains; got %s" % v.state)
    check(v.reason == "no-claim-visible", "got %s" % v.reason)
    check(v.reason != "claims-unreadable",
          "an empty read must NOT be reported as a failed read")
    check("NOT freedom" in v.detail, "the absence disclosure is mandatory; got %r" % v.detail)


# ══════════════════════════════════════════════════════════════════════════
# L4 — presence with unreadable metadata still refutes freedom
# ══════════════════════════════════════════════════════════════════════════
@test("L4 pull: presence with unreadable metadata keeps present=True, owner=? (#1777 C11)")
def l4_presence_without_metadata():
    with bare_remote([("refs/claims/5-abcdef123456", "%s:77" % HOST, str(NOW_S + 60))]) as remote:
        with git_shim(fail=("fetch",)) as shim, env_with(shim):
            cr = cl.read_pull(remote, host=HOST, now=NOW_S)
    check(cr.readable is True, "ls-remote succeeded, so the read is readable")
    check(cr.present is True, "presence is established by ls-remote alone")
    check(len(cr.claims) == 1, "the claim is kept, not dropped; got %d" % len(cr.claims))
    check(cr.claims[0].owner == "?", "an unreadable message yields owner='?'; got %r"
          % cr.claims[0].owner)
    check(cr.detail, "the metadata failure is surfaced; got %r" % cr.detail)
    v = liv.evaluate(cl.to_evidence(cr))
    check(v.reason == "claim-owner-unparseable", "got %s" % v.reason)
    check(v.state == "unknown", "presence alone must abstain, never read free; got %s" % v.state)


# ══════════════════════════════════════════════════════════════════════════
# L5 — the key is HEAD-scoped, so the PR's other heads are DISCLOSED
# ══════════════════════════════════════════════════════════════════════════
@test("L5 pull: sibling heads of the queried PR are disclosed, not dropped (#1777 T22)")
def l5_sibling_heads_disclosed():
    with bare_remote([("refs/claims/77-aaaaaaaaaaaa", "%s:1" % HOST, str(NOW_S + 60)),
                      ("refs/claims/77-bbbbbbbbbbbb", "%s:2" % HOST, str(NOW_S + 60)),
                      ("refs/claims/78-cccccccccccc", "%s:3" % HOST, str(NOW_S + 60))]) as remote:
        cr = cl.read_pull(remote, ns=cl.DEFAULT_NS, host=HOST, now=NOW_S,
                          pr="77", sha="aaaaaaaaaaaa")
        check([c.key for c in cr.claims] == ["77-aaaaaaaaaaaa"],
              "only the queried head's claim is selected; got %r" % [c.key for c in cr.claims])
        check(cr.siblings == ("77-bbbbbbbbbbbb",),
              "the PR's OTHER head is disclosed; got %r" % (cr.siblings,))
        check("78-cccccccccccc" not in cr.siblings,
              "another PR's head is not a sibling of this one; got %r" % (cr.siblings,))
        # Querying a head with NO claim still discloses the siblings that do exist.
        cr2 = cl.read_pull(remote, host=HOST, now=NOW_S, pr="77", sha="dddddddddddd")
        check(cr2.claims == () and set(cr2.siblings) == {"77-aaaaaaaaaaaa", "77-bbbbbbbbbbbb"},
              "got claims=%r siblings=%r" % ([c.key for c in cr2.claims], cr2.siblings))
        v = liv.evaluate(cl.to_evidence(cr2))
        check(v.reason == "no-claim-visible" and "bbbbbbbbbbbb" in v.detail,
              "the disclosed siblings reach the rendered detail; got %r" % v.detail)
        # `present` is a NAMESPACE fact; the per-target answer is separate (verify-gate P3).
        payload = json.loads(cl.render_json(cr2, v))
        check(payload["present"] is True and payload["present_for_target"] is False,
              "present(namespace)=yes must not be readable as 'this PR has a claim'; got %r"
              % {k: payload[k] for k in ("present", "present_for_target", "claims")})
        text = cl.render_text(cr2, v)
        check("present(namespace)" in text and "NONE for the queried head" in text,
              "the text rendering disambiguates it too; got %r" % text.splitlines()[:4])
        payload_ok = json.loads(cl.render_json(cl.read_pull(remote, host=HOST, now=NOW_S,
                                                           pr="77", sha="aaaaaaaaaaaa"), v))
        check(payload_ok["present_for_target"] is True,
              "and present_for_target is True when the head DOES have a claim")


# ══════════════════════════════════════════════════════════════════════════
# L6–L9 — the FILE driver
# ══════════════════════════════════════════════════════════════════════════
@test("L6 snapshot: a MISSING file is unreadable (never 'no claims') (#1777)")
def l6_snapshot_missing():
    d = tempfile.mkdtemp(prefix="claims-snap-")
    try:
        cr = cl.read_snapshot(os.path.join(d, "nope"), max_age_s=600, host=HOST, now=NOW_S)
    finally:
        shutil.rmtree(d, ignore_errors=True)
    check(cr.readable is False, "a missing snapshot establishes nothing")
    check(cr.claims == (), "and carries no claims")
    check("unreadable" in cr.detail, "the cause is named; got %r" % cr.detail)
    v = liv.evaluate(cl.to_evidence(cr))
    check(v.reason == "claims-unreadable", "got %s" % v.reason)


@test("L7 snapshot: a STALE file is unreadable — an old read is not a read (#1777)")
def l7_snapshot_stale():
    d = tempfile.mkdtemp(prefix="claims-snap-")
    try:
        path = write_snapshot(d, "refs/claims/5-abcdef123456\t%s:1\t%d\n"
                             % (HOST, NOW_S + 60), age_s=900)
        cr = cl.read_snapshot(path, max_age_s=600, host=HOST, now=NOW_S)
        check(cr.readable is False, "900s old against a 600s bound is STALE")
        check("STALE" in cr.detail, "staleness is named, not implied; got %r" % cr.detail)
        check(cr.claims == (), "a stale read carries no claims")
        v = liv.evaluate(cl.to_evidence(cr))
        check(v.reason == "claims-unreadable", "got %s" % v.reason)
        # and a fresh read of the same content IS readable — the bound is the only difference
        path2 = write_snapshot(d, "refs/claims/5-abcdef123456\t%s:1\t%d\n"
                               % (HOST, NOW_S + 60), age_s=10)
        ok = cl.read_snapshot(path2, max_age_s=600, host=HOST, now=NOW_S)
        check(ok.readable is True and len(ok.claims) == 1, "a fresh snapshot reads")
    finally:
        shutil.rmtree(d, ignore_errors=True)


@test("L8 snapshot: shape drift is unreadable — never a partial parse (#1777)")
def l8_snapshot_shape_drift():
    d = tempfile.mkdtemp(prefix="claims-snap-")
    try:
        good = "refs/claims/5-abcdef123456\t%s:1\t%d\n" % (HOST, NOW_S + 60)
        path = write_snapshot(d, good + "refs/claims/6-123456abcdef\t%s:2\n" % HOST)
        cr = cl.read_snapshot(path, max_age_s=600, host=HOST, now=NOW_S)
    finally:
        shutil.rmtree(d, ignore_errors=True)
    check(cr.readable is False, "a 2-field line is drift, not a readable read")
    check(cr.claims == (), "the well-formed line is NOT partially returned: a partial read "
                           "would silently drop the claim it mis-read")
    check("SHAPE DRIFT" in cr.detail, "the drift is named; got %r" % cr.detail)
    v = liv.evaluate(cl.to_evidence(cr))
    check(v.reason == "claims-unreadable", "got %s" % v.reason)


@test("L9 snapshot: a 0-byte file is a READABLE empty read (#1777)")
def l9_snapshot_empty():
    d = tempfile.mkdtemp(prefix="claims-snap-")
    try:
        path = write_snapshot(d, "")
        cr = cl.read_snapshot(path, max_age_s=600, host=HOST, now=NOW_S)
        check(cr.readable is True, "an empty snapshot is a successful read of nothing")
        check(cr.present is False and cr.claims == (), "no claims, no presence")
        v = liv.evaluate(cl.to_evidence(cr))
        check(v.reason == "no-claim-visible",
              "an empty FILE and a missing FILE must not share a reason; got %s" % v.reason)
    finally:
        shutil.rmtree(d, ignore_errors=True)


# ══════════════════════════════════════════════════════════════════════════
# L10 — lease polarity parity with the SHIPPED shell primitives
# ══════════════════════════════════════════════════════════════════════════
@test("L10 lease parity: the Python polarity matches the SHIPPED claims.sh (#1709 rec 3)")
def l10_lease_parity_with_shipped_shell():
    check(os.path.exists(CLAIMS_SH), "the shipped registry is present: %s" % CLAIMS_SH)
    d = tempfile.mkdtemp(prefix="claims-parity-")
    try:
        git(["init", "-q", d])
        # Cases exactly as they arise in production, with the polarity each MUST take.
        cases = [
            ("future", str(NOW_S + 900), "live"),
            ("past", str(NOW_S - 900), "expired"),
            ("zero", "0", "unknown"),      # the documented sentinel in claims.sh
            ("negative", "-5", "unknown"),  # `[0-9]*` cannot match the minus => 0 => live
            ("nineteen", "9" * 19, "unknown"),  # > 2**63-1 would ERROR the shell comparison
            ("eighteen", "9" * 18, "live"),     # the precise magnitude bound is still numeric
            ("nondigit", "soon", "unknown"),
            # ⛔ A LEADING ZERO IS UNPARSEABLE IN BOTH READERS (agent-infra#3203). The shell rejects it
            # because `[` compares decimally (`0000009999` would read as a 1970 window), and Python's
            # `int()` would do exactly the same — so the reader must refuse the shape BEFORE converting,
            # or the two readers disagree in the FREE direction: this one passes a claim gate on a
            # lease claims.sh ABSTAINS over.
            ("leading-zero", "0" + str(NOW_S), "unknown"),
            ("one-then-digits", "0999", "unknown"),
            ("garbled-suffix", "1junk", "unknown"),
            ("garbled-non-ascii", "17\u06692000000", "unknown"),
            # ⛔ THE WHOLE SEPARATOR CLASS, NOT ONE CHARACTER (review round 15, agent-infra#3203).
            # Every one of these terminates a line in PYTHON (`str.splitlines`, `\s`) and does NOT in
            # the shell — which reads `\n`/space/TAB only. Each must therefore be UNPARSEABLE in both
            # readers; the loop compares this reader's EXTRACTOR against the shipped `_lease_of`, so a
            # divergence in either direction reddens HERE rather than in production.
            ("vt", "1\x0b", "unknown"),
            ("ff", "1\x0c", "unknown"),
            ("fs", "1\x1c", "unknown"),
            ("gs", "1\x1d", "unknown"),
            ("rs", "1\x1e", "unknown"),
            ("nel", "1\u0085", "unknown"),
            ("ls", "1\u2028", "unknown"),
            ("ps", "1\u2029", "unknown"),
            ("nbsp", "1\xa0", "unknown"),
            ("emspace", "1\u2003", "unknown"),
            # ⛔ CR IS THE ONE SEPARATOR THE SHELL *DELETES* (review round 16, agent-infra#3203).
            # `_lease_of` runs `tr -d '\r'`, so `lease_until=A<CR>lease_until=B` is ONE token to the
            # shell (the last digits win) — while Python's `text=True` (universal newlines) had already
            # turned that CR into a LINE BREAK at decode, so this reader saw two lines and took the
            # first. That is why CR is its own class: it is not "content" and not "a break", it is
            # REMOVED. Pinned here through the shipped `_lease_of`, which is the oracle.
            # The DISCRIMINATING shape: the shell DELETES the CR and the two tokens FUSE —
            # `lease_until=1<CR>lease_until=9999999999` becomes the single word
            # `lease_until=1lease_until=9999999999`, which is not a faithful token ⇒ UNPARSEABLE. A
            # reader that let universal newlines turn the CR into a LINE BREAK would take line 1's `1`
            # and answer EXPIRED, i.e. FREE (measured). The digits-join case is pinned too.
            ("cr-fuse", "1\rlease_until=9999999999", "unknown"),
            ("cr-mid", "1792009999\r1", "live"),
            ("cr-after", "1\r", "expired"),
            ("absent", "", "unknown"),
        ]
        driver = os.path.join(d, "driver.sh")
        with open(driver, "w", encoding="utf-8") as fh:
            fh.write(
                "set -eu\n"
                "export GIT_TERMINAL_PROMPT=0\n"
                "CLAIM_REPO=\"$1\"\n"
                ". \"$2\"\n"
                "c=\"$(_claim_commit \"$3\" \"$4\")\"\n"
                "git -C \"$CLAIM_REPO\" update-ref refs/parity \"$c\"\n"
                "_lease_of refs/parity\n"
            )
        for label, raw, want in cases:
            proc = subprocess.run(["bash", driver, d, CLAIMS_SH, "%s:31337" % HOST, raw],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            # the exact commit message the shipped writer minted for this case
            # ⛔ BYTES, NOT `text=True` (review round 16): universal newlines would turn a crafted
            # CR into a line break HERE, in the fixture reader, and hide the divergence the case exists
            # to pin — `_lease_of` DELETES the CR (`tr -d '\r'`), so the bytes are the faithful read.
            proc_msg = subprocess.run(
                ["git", "-C", d, "log", "-1", "--format=%B", "refs/parity"],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout.decode("utf-8", "replace")
            check(proc.returncode == 0, "claims.sh primitives failed for %s: %s"
                  % (label, proc.stderr.strip()))
            shell_owner, _tab, shell_until = proc.stdout.rstrip("\n").partition("\t")
            # The shell is the ORACLE for what the file contains; the Python reader
            # must classify that content the way claims.sh's own readers do.
            until, state = cl.parse_lease(shell_until, NOW_S)
            check(state == want, "case %s (shell emitted %r) => the reader said %s, expected %s"
                  % (label, shell_until, state, want))
            # ⛔ THE EXTRACTOR TOO, NOT JUST THE PARSER (review round 10, agent-infra#3203): the loop
            # above compares `parse_lease` against the SHELL's `_lease_of` output, so a Python
            # EXTRACTOR that disagreed — `lease_until=1junk` was captured as `1` by an unanchored
            # `[0-9]*`, i.e. expired/FREE, while the shell's anchored reader said unparseable — was
            # invisible to every case here. One datum, one answer, or the free-direction divergence
            # this PR exists to remove is simply re-created one layer down.
            py_owner, py_until = cl._owner_and_lease(proc_msg)
            check(py_until == shell_until,
                  "case %s: the EXTRACTOR diverged from the shell: %r vs %r"
                  % (label, py_until, shell_until))
            oh, opid, scope = cl.parse_owner(shell_owner, HOST)
            check((oh, opid, scope) == (HOST, 31337, "local"),
                  "case %s: owner parity broke: %r -> %r" % (label, shell_owner, (oh, opid, scope)))
        # The sentinel class must ALSO agree with the reader's own documented rule: an
        # unparseable lease is NOT expired (the conservative direction).
        for label, raw, want in cases:
            if want != "unknown":
                continue
            until, state = cl.parse_lease(raw, NOW_S)
            check(until is None and state == "unknown",
                  "%s must be (None, unknown), got %r/%s" % (label, until, state))
        check(cl.LEASE_MAX_DIGITS == 18, "the magnitude bound is 18, not 9; got %r"
              % cl.LEASE_MAX_DIGITS)
        # ── extraction parity: a HOSTILE HEADER must not supply the payload ────
        # The pull reader uses `cat-file commit`, which prints the WHOLE object.
        # `claims.sh`'s `_lease_of` strips the headers first; the Python reader must
        # agree, or a header (minted by whoever pushes) supplies owner=/lease_until=
        # and the two readers disagree about ONE lease (#1777 review P1).
        hostile = ("tree %s\n" % EMPTY_TREE +
                   "author x <e@e> 1792092574 +0000\n"
                   "committer x owner=evil-host:4242 lease_until=999999999999999999 "
                   "<e@e> 1792092574 +0000\n\n"
                   "claim nonce=deadbeef\n")
        check(cl._owner_and_lease(cl._commit_body(hostile)) == ("?", "0"),
              "a header must NOT supply owner/lease; got %r"
              % (cl._owner_and_lease(cl._commit_body(hostile)),))
        check(cl._owner_and_lease(cl._commit_body(
                  "tree t\n\nclaim owner=good-host:7 lease_until=123\n")) ==
              ("good-host:7", "123"),
              "the message BODY is still parsed (last occurrence wins)")
        # ... and the same through the real reader, so the call site (not just the
        # helper) is pinned. The committer DATE stays readable (it is the claim age).
        hostile_env = dict(os.environ, **GIT_ENV)
        hostile_env["GIT_COMMITTER_NAME"] = \
            "x owner=evil-host:4242 lease_until=999999999999999999"
        hostile_env["GIT_COMMITTER_DATE"] = "%d +0000" % (NOW_S - 600)
        proc = subprocess.run(
            ["git", "-C", d, "commit-tree", EMPTY_TREE, "-m", "claim nonce=deadbeef"],
            env=hostile_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        check(proc.returncode == 0, "hostile commit-tree failed: %s" % proc.stderr.strip())
        git(["-C", d, "update-ref", "refs/claims/7-aaaaaaaaaaaa", proc.stdout.strip()])
        cr = cl.read_pull(d, host=HOST, now=NOW_S)
        check(cr.readable is True, "the hostile remote is readable: %r" % cr.detail)
        row = [c for c in cr.claims if c.key == "7-aaaaaaaaaaaa"]
        check(len(row) == 1, "the hostile claim is present; got %r" % [c.key for c in cr.claims])
        check(row[0].owner == "?", "the header must not name an owner; got %r" % row[0].owner)
        check(row[0].lease_state == "unknown",
              "the header lease must not be read; got %r" % row[0].lease_state)
        check(row[0].age_s == 600, "the committer date is still read as the age; got %r"
              % row[0].age_s)
    finally:
        shutil.rmtree(d, ignore_errors=True)


# ══════════════════════════════════════════════════════════════════════════
# L11 — this reader never decides a state
# ══════════════════════════════════════════════════════════════════════════
@test("L11 the reader emits NO state: no STATES, no state names, no Verdict (#1178)")
def l11_reader_decides_nothing():
    with open(MODULE_PATH, "r", encoding="utf-8") as fh:
        src = fh.read()
    check("Verdict(" not in src,
          "the reader must never construct a verdict; the ONE verdict function is "
          "liveness.evaluate (#1178)")
    check(not (set(cl.__all__) & set(liv.STATES)),
          "a state name is exported: %r" % sorted(set(cl.__all__) & set(liv.STATES)))
    check("evaluate" not in cl.__all__, "the reader must not re-export the verdict function")
    check("STATES" not in cl.__all__, "the reader must not re-export the state vocabulary")
    # The claim vocabulary it DOES expose is the classifier's, not a copy.
    check(cl.ADVISORY and "abstention" in cl.ADVISORY,
          "the fixed advisory is present; got %r" % cl.ADVISORY)
    for name in cl.__all__:
        check(hasattr(cl, name), "__all__ names a missing attribute: %s" % name)
    check(len(cl.READER_LIMITS) >= 3, "the reader declares its blind spots; got %r"
          % (cl.READER_LIMITS,))


# ══════════════════════════════════════════════════════════════════════════
# L12 — local refs are NEVER read
# ══════════════════════════════════════════════════════════════════════════
@test("L12 the reader never reads LOCAL refs: a bogus local claim is invisible (#1777)")
def l12_local_refs_never_read():
    with bare_remote(()) as remote:
        with work_repo(remote, local_refs=[("refs/claims/9999-cafebabe0000", "ghost:1",
                                            str(NOW_S + 60))]) as work:
            # The local ref really is there …
            local = git(["-C", work, "for-each-ref", "--format=%(refname)"]).stdout
            check("refs/claims/9999-cafebabe0000" in local,
                  "fixture check: the local ref exists")
            # … and the read still says "nothing", because the registry is the REMOTE.
            cr = cl.read_pull("origin", repo=work, host=HOST, now=NOW_S)
            check(cr.readable is True, "the remote read succeeded")
            check(cr.present is False and cr.claims == (),
                  "a local ref must NOT leak into the registry read; got %r"
                  % ([c.ref for c in cr.claims],))
            v = liv.evaluate(cl.to_evidence(cr))
            check(v.reason == "no-claim-visible", "got %s" % v.reason)


# ══════════════════════════════════════════════════════════════════════════
# L13 — output hygiene (the owner string is attacker-influencable)
# ══════════════════════════════════════════════════════════════════════════
@test("L13 hostile owner strings are neutralised in every rendering (#1272)")
def l13_output_hygiene():
    # A newline cannot ride inside a tab-separated record (it would become shape
    # drift), so it is checked against the sanitizer directly.
    check("\n" not in cl.sanitize("a\nb"), "a newline must not survive")
    hostile = "evil| `code` | <h1>x</h1> \x07"
    check("\\|" in cl.sanitize(hostile), "a pipe is escaped")
    check("`" not in cl.sanitize(hostile), "a backtick is replaced")
    check("\x07" not in cl.sanitize(hostile), "a control char is dropped")
    d = tempfile.mkdtemp(prefix="claims-snap-")
    try:
        path = write_snapshot(d, "refs/claims/5-abcdef123456\t%s\t%d\n" % (hostile, NOW_S + 60))
        cr = cl.read_snapshot(path, max_age_s=600, host=HOST, now=NOW_S)
    finally:
        shutil.rmtree(d, ignore_errors=True)
    check(len(cr.claims) == 1, "the line parses (3 fields)")
    check(cr.claims[0].scope == "unknown", "a hostile owner is unusable => scope unknown")
    v = liv.evaluate(cl.to_evidence(cr))
    check(v.reason == "claim-owner-unparseable", "got %s" % v.reason)
    text = cl.render_text(cr, v)
    check("\x07" not in text, "no control character reaches the output")
    rendered_line = [ln for ln in text.splitlines() if "evil" in ln][0]
    check(rendered_line.count("|") - rendered_line.count("\\|") == 0,
          "no unescaped pipe reaches the output: %r" % rendered_line)
    check("`" not in rendered_line,
          "no backtick reaches the owner rendering: %r" % rendered_line)
    payload = json.loads(cl.render_json(cr, v))
    check("\n" not in payload["claims"][0]["owner"], "JSON carries no raw newline")
    check(payload["advisory"] == cl.ADVISORY, "JSON carries the fixed advisory")
    # The SAME attacker-influencable owner string rides in the verdict's `detail`
    # (`liveness._claim_detail`), not just in `claims[].owner` — so "every
    # rendering" is only true if the machine rendering neutralises it there too.
    # The claims[] checks above do not cover this field (#1784 review, P2).
    vdetail = payload["verdict"]["detail"]
    check("owner=" in vdetail and "evil" in vdetail,
          "the owner identity is still reported, not dropped: %r" % vdetail)
    check(vdetail == cl.sanitize(v.detail, 400),
          "the JSON verdict detail is the sanitized text rendering: %r" % vdetail)
    check(vdetail.count("|") - vdetail.count("\\|") == 0,
          "no unescaped pipe reaches the JSON verdict detail: %r" % vdetail)
    check("`" not in vdetail,
          "no backtick reaches the JSON verdict detail: %r" % vdetail)
    check("\x07" not in vdetail,
          "no control character reaches the JSON verdict detail: %r" % vdetail)
    check(payload["verdict"]["witnesses"] == [], "witnesses stays a list")


# ══════════════════════════════════════════════════════════════════════════
# L14 — per-repo binding: the CWD is never the target
# ══════════════════════════════════════════════════════════════════════════
@test("L14 --repo binds the read to the TARGET repo, never the cwd (#1709)")
def l14_repo_binding():
    with bare_remote([("refs/claims/1-111111111111", "%s:11" % HOST, str(NOW_S + 60))]) as a:
        with bare_remote([("refs/claims/2-222222222222", "%s:22" % HOST, str(NOW_S + 60))]) as b:
            with work_repo(a) as wa, work_repo(b) as wb:
                env = dict(os.environ, CLAIM_HOST=HOST)
                proc = subprocess.run(
                    [sys.executable, MODULE_PATH, "--repo", wb, "--json", "--now", str(NOW_S)],
                    cwd=wa, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                check(proc.returncode == 0, "the CLI must exit 0: rc=%d %s"
                      % (proc.returncode, proc.stderr.strip()))
                payload = json.loads(proc.stdout)
                keys = [c["key"] for c in payload["claims"]]
                check(keys == ["2-222222222222"],
                      "run from repo A, --repo B must read B; got %r" % (keys,))
                check("1-111111111111" not in keys, "the cwd's claim must NOT appear")
                check(payload["readable"] is True and payload["verdict"]["state"] == "unknown",
                      "and the verdict stays an abstention")


@test("L10d a refname carrying U+2028 is not a claim at the canonical key (splitlines decoy)")
def l10d_ls2028_decoy():
    # ⛔ `git check-ref-format` ACCEPTS U+2028 in a refname, and `str.splitlines()` breaks on it — so a
    # peer pushing `refs/claims/<pr>-<sha12><LS>junk` made `read_pull` report a claim at the canonical
    # key, which does not exist (review round 17, agent-infra#3203; measured: this reader "readable, 1
    # claim", the shell `claim-absent`). Over-block, not a grant — but the shell splits `ls-remote` on
    # `\n` alone and so must this reader.
    # ⛔ AND IT MUST BE BOTH-SIDED (review round 18, agent-infra#3203). The first draft only forbade
    # the canonical phantom, so a mutant that DROPS every non-ASCII ref (`present=False` ⇒
    # `no-claim-visible`) passed it — the "presence lost" direction was unasserted. And the datum was
    # LS-INTERIOR, where a bare `.strip()` is inert; the trim is what turns a TRAILING U+2028 into the
    # canonical key, so both positions are pinned now.
    for suffix in ("\u2028junk", "\u2028", "\u00a0", "\u2003", "\u2029"):
        with bare_remote([("refs/claims/9-bbbbbbbbbbbb" + suffix, "decoy", "9999999999")]) as remote:
            cr = cl.read_pull(remote, host=HOST, now=NOW_S)
        keys = [c.ref for c in cr.claims]
        check(cr.readable is True, "the read itself succeeds; got %r" % (cr.detail,))
        check(cr.present is True and len(cr.claims) == 1,
              "the decoy IS a claim (it must not be dropped); suffix=%r got %r present=%r"
              % (suffix, keys, cr.present))
        check(keys[0] == "refs/claims/9-bbbbbbbbbbbb" + suffix,
              "the refname is kept VERBATIM, never trimmed to the canonical key; suffix=%r got %r"
              % (suffix, keys))
        check("refs/claims/9-bbbbbbbbbbbb" not in keys,
              "and it must not surface as the canonical key; suffix=%r got %r" % (suffix, keys))


@test("L32 a NUL in the claim line is DELETED (bash does), not carried or truncated at")
def l32_nul_is_deleted():
    # ⛔ review round 19, agent-infra#3203. `_lease_of` reads the object through `$( )`, and a command
    # substitution DROPS NUL bytes — so `lease_until=1<NUL>lease_until=1792009999` is ONE fused, invalid
    # token to the shell (UNPARSEABLE ⇒ abstain). A reader that KEPT the NUL saw two words and took the
    # first (`1` ⇒ expired ⇒ FREE). `git commit-tree` refuses a NUL in argv; `hash-object --literally`
    # writes it and a plain push accepts it, so this is a peer-mintable object.
    d = tempfile.mkdtemp(prefix="nul-cl-")
    try:
        git(["init", "-q", d])
        git(["-C", d, "config", "user.email", "a@b"])
        git(["-C", d, "config", "user.name", "a"])
        with open(os.path.join(d, "f"), "w") as fh:
            fh.write("x\n")
        git(["-C", d, "add", "f"])
        git(["-C", d, "commit", "-qm", "base"])
        tree = git(["-C", d, "rev-parse", "HEAD^{tree}"]).stdout.strip()
        raw = ("tree %s\nauthor a <a@b> 1 +0000\ncommitter a <a@b> 1 +0000\n\n"
               "claim owner=peerbox:7 lease_until=1\x00lease_until=1792009999 nonce=n\n" % tree)
        sha = subprocess.run(
            ["git", "-C", d, "hash-object", "-t", "commit", "--literally", "-w", "--stdin"],
            input=raw.encode(), check=True, capture_output=True).stdout.decode().strip()
        # the body the reader gets must be NUL-FREE, exactly as bash hands it to `_lease_of`
        obj = subprocess.run(["git", "-C", d, "cat-file", "commit", sha],
                             check=True, capture_output=True).stdout.decode("utf-8", "replace")
        body = cl._commit_body(obj)
        check("\x00" not in body, "the body carries no NUL (bash deletes them); got %r" % (body,))
        owner, until = cl._owner_and_lease(body)
        check(until == "0",
              "so the two tokens FUSE into one invalid word ⇒ unparseable, not the first "
              "one taken; got %r/%r" % (owner, until))
        check(cl.parse_lease(until, NOW_S)[1] == "unknown",
              "and the reader abstains rather than publishing the first token as expired")
    finally:
        shutil.rmtree(d, ignore_errors=True)


@test("L31 parse_owner does not trim a Unicode separator off the owner token")
def l31_owner_no_unicode_trim():
    # ⛔ review round 18, agent-infra#3203: `parse_owner((owner or "").strip())` turned `boxA:7<U+2028>`
    # into a PARSED `("boxA", 7, "foreign")`, where the shell's owner word is `boxA:7<U+2028>` (its
    # split is `tr ' \t'` only). Not a grant — the oracle's orphan arm refuses every variant and this
    # reader never probes a local pid — but a label invented from a value nobody wrote.
    for sep in ("\u2028", "\u00a0", "\u2003", "\u0085"):
        host, pid, scope = cl.parse_owner("boxA:7" + sep, "thisbox")
        check(scope == "unknown", "owner %r must be UNUSABLE, not parsed; got %r"
              % ("boxA:7" + sep, (host, pid, scope)))
    check(cl.parse_owner("boxA:7", "thisbox") == ("boxA", 7, "foreign"),
          "a clean owner still parses")


@test("L30 the committer stamp is accepted exactly as the shell accepts it (no trailing ws, 12-digit cap)")
def l30_committer_acceptance():
    # ⛔ ONE DATUM, ONE ANSWER — in the field the bounded reap is MEASURED FROM (review round 18,
    # agent-infra#3203). `claims.sh`'s `_claim_commit_time` takes the LAST `committer `-prefixed header
    # line (`sed -n '/^committer /p' | tail -n 1`, round 24), parses THAT line with
    # `sed -n 's/^committer .*> \([0123456789]\{1,\}\) [+-][0123456789]\{4\}$/\1/p'` — anchored on
    # `> `, the IDENT's end, so the accepted stamp is the field git reads and a second `digits +dddd`
    # tail cannot forge it (round 22) — NOTHING may follow the tz digits — and then rejects a stamp
    # longer than 12 digits as UNMEASURABLE
    # (`case … |?????????????*`), which is what keeps `now - ct` out of a wrapped negative. This
    # reader allowed `[ \t]*$` and any length, so the same object was "unmeasurable" to the oracle and
    # a fresh/aged stamp here.
    def obj(headers, body="claim owner=c lease_until=9999999999 nonce=x"):
        # a commit object is `<headers>\n\n<body>`; `_commit_time` reads the header block only
        return "tree " + "0" * 39 + "\n" + headers + "\n\n" + body + "\n"
    ok = "committer a <a@b> 1700000000 +0000"
    cases = [
        (ok, 1700000000),
        (ok + " ", None),                       # trailing space: the shell's `...$` refuses it
        (ok + "\t", None),
        ("committer a <a@b> 17000000000 +0000", 17000000000),   # 11 digits: accepted by both
        ("committer a <a@b> 170000000000 +0000", 170000000000), # 12 digits: still accepted
        ("committer a <a@b> 1700000000000 +0000", None),        # 13+ ⇒ `?????????????*`: UNMEASURABLE
        # ⛔ THE THIRD REJECTION ARM (review round 20): `_claim_commit_time` also rejects `0?*`, because a
        # leading-zero operand aborts `$(( now - ct ))` as OCTAL. Round 19 added the arm here and no case
        # pinned it — a mutant that deletes it left the whole suite green.
        ("committer a <a@b> 0999 +0000", None),
        # ⛔ A BARE `0` IS ACCEPTED BY THE SHELL (its arm is `''|*[!0123456789]*|0?*` — `0?*` needs at
        # least two characters), so a 1970 stamp is a real, reaped-as-ancient date and this reader must
        # agree. Only `0` FOLLOWED BY DIGITS is the octal hazard.
        ("committer a <a@b> 0 +0000", 0),
    ]
    for line, want in cases:
        got = cl._commit_time(obj(line))
        check(got == want, "%r -> %r (want %r), as the shell's anchored+12-digit rule does"
              % (line, got, want))
    # the header block still ends at the first blank line (a `committer` word in the BODY is content)
    check(cl._commit_time(obj(ok, "committer a <a@b> 9999999999 +0000")) == 1700000000,
          "a `committer`-shaped line in the BODY is not a header; got %r"
          % (cl._commit_time(obj(ok, "committer a <a@b> 9999999999 +0000")),))
    # ⛔ AND A LAST HEADER THAT IS PRESENT BUT UNUSABLE DOES NOT FALL BACK (review round 20,
    # agent-infra#3203). `_claim_commit_time` takes the LAST `committer `-prefixed header line and
    # judges THAT line — it never considers an earlier `committer` line. A bounded `{1,12}` quantifier
    # made `findall` skip the unusable line and return the FIRST one's stamp (measured: shell
    # unmeasurable, this reader 1700000000).
    # ⛔ AND NEITHER DOES A LAST LINE WHOSE *SHAPE* DOES NOT MATCH (review round 24). Rounds 20–21
    # disagreed about the oracle here because the oracle's parse was ONE `sed` piped to `tail -n 1`
    # ("the last line that MATCHES", so a shape-broken last line was SKIPPED and an earlier valid one
    # won). Round 24 SPLIT that parse — `sed -n '/^committer /p' | tail -n 1 | sed -n 's/…$/\1/p'`, so
    # that a newest header carrying a trailing token can no longer forge the age from an OLDER line —
    # and in doing so it made a shape-broken LAST line UNMEASURABLE rather than skippable. Measured on
    # the shipped pair: a last line with a trailing space or a 3-digit tz answers UNMEASURABLE from the
    # oracle (rc 1 — the claim is KEPT and NAMED) and `1700000000` from this reader, and on the
    # forged-age shape the oracle keeps the claim while this reader reports ~1.79e9 s of age. These
    # two assertions used to pin the OLD rule under a comment that became FALSE about the oracle; the
    # rule moved, so the pins move with it.
    shape_bad_last = "committer a <a@b> 1700000000 +0000\ncommitter a <a@b> 1700000001 +0000 "
    check(cl._commit_time(obj(shape_bad_last)) is None,
          "a shape-broken LAST line is NOT skipped: the oracle judges that line and answers "
          "unmeasurable, never the earlier valid stamp; got %r"
          % (cl._commit_time(obj(shape_bad_last)),))
    tz_short = "committer a <a@b> 1700000000 +0000\ncommitter a <a@b> 1700000001 +000"
    check(cl._commit_time(obj(tz_short)) is None,
          "a 3-digit tz on the LAST line is unmeasurable too, not the earlier stamp; got %r"
          % (cl._commit_time(obj(tz_short)),))
    # ⛔ AND THE FORGED-AGE SHAPE THIS CHANGE EXISTS TO CLOSE (review round 24). A newest `committer`
    # header with any trailing token made the OLD one-stage parse fall through to an EARLIER line —
    # here `1793991810` — which is the "a claim zero seconds old deleted" measurement. Both layers must
    # now refuse to measure it, so the assert is on BOTH: this reader `None`, and the oracle `rc 1`
    # (`scripts/orchestrator-harness/test-claims.sh` A76–A78).
    forged = "committer a <a@b> 1793991810 +0000\ncommitter a <a@b> 1700000000 +0000 junk"
    check(cl._commit_time(obj(forged)) is None,
          "a trailing token on the NEWEST committer header must not fall back to an older stamp "
          "(that is the forged-age steal); got %r" % (cl._commit_time(obj(forged)),))
    # ⛔ AND THE SAME STEAL THROUGH A TOKEN THAT *PARSES* (review round 22, agent-infra#3203). The forged
    # shape above only pins the FALLBACK. A greedy `.* ` accepted the LAST `digits [+-]dddd` pair ANYWHERE
    # on the line, so a second such pair forged the same age by a different token: measured on the shipped
    # pair, `committer a <a@b> <NOW> +0000 1 +0000` — a claim git dates at the current SECOND — answered `1`
    # in BOTH layers, and the shell's reaper DELETED it as `1793991810s old, PAST the 18000s bound`. The
    # pattern is now anchored on `> ` (the ident's end), so the accepted stamp is the field git reads and
    # any other `digits [+-]dddd` tail is simply not a match (⇒ unmeasurable ⇒ KEPT and NAMED). The oracle
    # side is A79-A81, which drive the same object through `claim_prune`.
    field_forged = "committer a <a@b> 1793991810 +0000 1 +0000"
    check(cl._commit_time(obj(field_forged)) is None,
          "a SECOND 'digits +dddd' pair on the committer line must not become the stamp "
          "(the greedy .* read it as '1', dating a 0-second-old claim as ancient); got %r"
          % (cl._commit_time(obj(field_forged)),))
    # ⛔ AND THE SAME STEAL THROUGH A SECOND `> ` — AND WHY THE ANSWER IS THE **VALUE**, NOT `None`
    # (review round 27, agent-infra#3203). A round-27 finding claimed git reads the FIRST `<`…FIRST `>` span,
    # so `... +0000 > 1 +0000` would be dated NOW by git and only this pattern would answer `1`. MEASURED on
    # git 2.43.0 (`hash-object -w -t commit --literally` + `git log -1 --format=%ct`): git dates from the
    # field after the **LAST** `>`, so BOTH shapes below are dated **1** by git — the pattern AGREES, and an
    # anchor on the mail span answered `None`, i.e. it refused to measure an object git dates 1970. That is
    # the PERMANENT-HOLD direction: `claim_prune` `continue`s on an unmeasurable age BEFORE the bound is
    # compared, so a peer appending ` > 1 +0000` would hold its claim for ever (#3203 re-opened). The pin is
    # therefore on the VALUE git answers, not on an abstention — the two readers must agree with git, not
    # merely with each other.
    greedy_forged = "committer a <a@b> 1793991810 +0000 > 1 +0000"
    check(cl._commit_time(obj(greedy_forged)) == 1,
          "a forged tail after the LAST '>' is dated 1 by git, so the reader must answer 1, not abstain "
          "(an abstention here makes a git-ancient claim unreapable); got %r"
          % (cl._commit_time(obj(greedy_forged)),))
    greedy_forged_mail = "committer a <a@b> 1793991810 +0000 <c@d> 1 +0000"
    check(cl._commit_time(obj(greedy_forged_mail)) == 1,
          "a later '<c@d>' mail-shaped span is not a split point for git either; got %r"
          % (cl._commit_time(obj(greedy_forged_mail)),))
    # ...and the reverse sign: a forged LATER stamp after a `>` must be MEASURED as git measures it, so a
    # peer cannot delay a reap by appending `> <fresh> +0000`. git answers the SAME value here.
    reverse_sign = "committer a <a@b> 1 +0000 > 1793991810 +0000"
    check(cl._commit_time(obj(reverse_sign)) == 1793991810,
          "a forged later stamp after '> ' is the value git reads; got %r"
          % (cl._commit_time(obj(reverse_sign)),))
    # ...and a name legitimately carrying a forged-LOOKING token BEFORE the date field still measures.
    name_with_tail = "committer a > 1 +0000 <a@b> 1793991810 +0000"
    check(cl._commit_time(obj(name_with_tail)) == 1793991810,
          "a name carrying '> 1 +0000' still measures the trailing stamp (git's answer); got %r"
          % (cl._commit_time(obj(name_with_tail)),))
    no_blank = "tree " + "0" * 39 + "\ncommitter a <a@b> 1700000000 +0000\n"
    check(cl._commit_time(no_blank) == 1700000000,
          "with NO blank line the shell prints the whole object, so the stamp is still found; got %r"
          % (cl._commit_time(no_blank),))
    two = "committer a <a@b> 1700000000 +0000\ncommitter a <a@b> 1700000000000 +0000"
    check(cl._commit_time(obj(two)) is None,
          "a 13-digit LAST stamp makes the object UNMEASURABLE, not the first header's date; got %r"
          % (cl._commit_time(obj(two)),))
    two2 = "committer a <a@b> 1700000000 +0000\ncommitter a <a@b> 0999 +0000"
    check(cl._commit_time(obj(two2)) is None,
          "a leading-zero LAST stamp is unmeasurable too, not the first header's date; got %r"
          % (cl._commit_time(obj(two2)),))
    # and the NUL arm: bash deletes NULs before the sed, so a NUL inside the stamp FUSES into one
    # (`\x00` consumes exactly two hex digits, so the two halves are concatenated explicitly.)
    # ⛔ AND A FIRST LINE THAT IS EMPTY MAKES THE WHOLE OBJECT EMPTY TO THE ORACLE (review round 22,
    # agent-infra#3203). `sed -n '/^$/q;p'` QUITS ON LINE 1 having printed nothing, so
    # `_claim_commit_time` exits 1 and the claim is KEPT as unmeasurable. The old `partition("\n\n")`
    # expression found no separator on this shape and scanned everything, inventing a stamp the shell
    # refuses. (The shape is not pushable — `git push` rejects it and `fast-import` emits `tree` first —
    # which is why it was P3: closed by construction, not by a live exploit.)
    lead_blank = "\ncommitter a <a@b> 1700000000 +0000\n\nclaim owner=c lease_until=9999999999\n"
    check(cl._commit_time(lead_blank) is None,
          "a LEADING blank line makes the object unmeasurable to the shell; got %r"
          % (cl._commit_time(lead_blank),))
    # ...while a blank line AFTER headers still scopes to the headers (the sed prints them, then quits).
    check(cl._commit_time(obj(ok)) == 1700000000,
          "a normal object still measures (the takewhile must not over-scope); got %r"
          % (cl._commit_time(obj(ok)),))
    nul = "committer a <a@b> " + "17" + "\x00" + "0000000000" + " +0000"
    check(cl._commit_time(obj(nul)) == 170000000000,
          "a NUL inside the committer stamp fuses as bash deletes it; got %r"
          % (cl._commit_time(obj(nul)),))


@test("L10c a CR-fused claim reads UNPARSEABLE through read_pull itself (not just the extractor)")
def l10c_cr_fused_through_read_pull():
    # ⛔ THE PRODUCTION READ PATH, NOT THE EXTRACTOR (review round 16, agent-infra#3203). `L10` feeds
    # `_owner_and_lease` a byte-faithful message read by the TEST, so a SUT whose own git read used
    # `text=True` (universal newlines) would still pass: that read is where the CR was being decoded as
    # a LINE BREAK, while `_lease_of` DELETES CRs (`tr -d '\r'`) and therefore sees one fused, invalid
    # token. `read_pull` is the path the fleet actually takes, so the polarity is pinned THERE.
    fused = "1\rlease_until=9999999999"   # shell: `lease_until=1lease_until=9999999999` -> not a token
    with bare_remote([("refs/claims/9-bbbbbbbbbbbb", "peerbox:1", fused)]) as remote:
        cr = cl.read_pull(remote, host=HOST, now=NOW_S)
    check(cr.readable is True and len(cr.claims) == 1, "one claim is read; got %r" % (cr.claims,))
    c = cr.claims[0]
    check(c.lease_state == "unknown",
          "a CR-fused term is UNPARSEABLE, exactly as the shell reads it; got %s (until %r)"
          % (c.lease_state, c.lease_until))
    v = liv.evaluate(cl.to_evidence(cr, now_ms=NOW_S * 1000))
    check(v.state == "unknown", "and the fleet verdict is an abstention; got %s/%s" % (v.state, v.reason))


@test("L10b the EXTRACTOR takes the FIRST claim line, as _lease_of does, and the LAST committer header")
def l10b_first_line_and_last_header():
    # A claim commit carries ONE `claim …` line; a second one is peer-planted junk. `_lease_of` reads
    # the FIRST (it pipes both extractions through `head -n 1`), so this reader must too: with
    # `lease_until=9999999999` on line 1 and `lease_until=1` on line 2, the shell says LIVE and a
    # last-match reader says `expired` — i.e. FREE for a claim nobody may steal (review round 11).
    # ⛔ DISTINCT OWNERS PER LINE (review round 19, agent-infra#3203): with `owner=peerbox` on BOTH
    # lines, a last-match-wins reader produced the same answer and this assertion could not see the
    # defect it names — measured GREEN under that mutant.
    msg = ("claim owner=peerbox lease_until=9999999999 nonce=1\n"
           "claim owner=otherbox lease_until=1 nonce=2")
    owner, lease = cl._owner_and_lease(msg)
    check((owner, lease) == ("peerbox", "9999999999"),
          "the FIRST claim line wins, as in the shell; got %r" % ((owner, lease),))
    msg2 = ("claim owner=peerbox lease_until=9999999999 nonce=1\n"
            "claim owner=otherbox lease_until=1 nonce=2")
    check(cl._owner_and_lease(msg2) == ("peerbox", "9999999999"),
          "a full second `claim …` line does not contribute either field; got %r"
          % (cl._owner_and_lease(msg2),))
    # and GIT's rule for a duplicated header: the LAST one dates the commit (claims.sh: tail -n 1).
    obj = ("tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904\n"
           "author a <a@b> 1 +0000\n"
           "committer a <a@b> 1 +0000\n"
           "committer a <a@b> 1793962674 +0000\n"
           "\nbody\n")
    check(cl._commit_time(obj) == 1793962674,
          "the LAST committer header is the commit's date, as git and claims.sh read it; got %r"
          % (cl._commit_time(obj),))
    # and the SAME FIELD TWICE ON ONE LINE: both layers take the FIRST token (review round 12).
    # ⛔ AND THE FIRST-LINE RULE ITSELF (review round 13): the shell reads line 1 ONLY, so a lease
    # token on line 2 is not the claim's term — it is an ABSTENTION. A whole-body scan published
    # `expired` for exactly this shape, i.e. FREE, and that is what `merge-reminder` feeds to its
    # `decide()` as a PASSING claim gate.
    # ⛔ AND THE DATUM MUST NOT BE EXPLAINED BY THE WORDBOUNDARY (review round 19): `\nlease_until=1`
    # puts the token at a LINE START, where `(?<![^ \t])` refuses it whether or not the first-line rule
    # exists — so the pre-round-13 whole-body mutant stayed GREEN on it. The discriminating datums are a
    # full SPACE-PRECEDED token on line 2, in both the bare and the `claim …` form.
    for later in ("lease_until=1", "claim owner=otherbox lease_until=1 nonce=2"):
        two_lines = "claim owner=peerbox nonce=1\n" + later
        check(cl._owner_and_lease(two_lines) == ("peerbox", "0"),
              "a lease token on a LATER line (%r) is not the claim's term; got %r"
              % (later, cl._owner_and_lease(two_lines)))
    check(cl.parse_lease(cl._owner_and_lease(two_lines)[1], NOW_S)[1] == "unknown",
          "so the reader stays in the abstention, never `expired`")
    # ⛔ AND A UNICODE SPACE IS NOT A WORD BOUNDARY (review round 14): `_lease_of` splits on
    # space/TAB only, so an NBSP between the fields makes ONE word to the shell — no `lease_until=`
    # field, i.e. the ABSTENTION — while Python's `\s`/`(?<!\S)` treated it as a boundary and
    # published `expired` = FREE.
    nbsp = "claim owner=peerbox:9\u00a0lease_until=1 nonce=x"
    check(cl._owner_and_lease(nbsp)[1] == "0",
          "an NBSP-separated field is not a field to the shell, so not to this reader; got %r"
          % (cl._owner_and_lease(nbsp),))
    check(cl.parse_lease(cl._owner_and_lease(nbsp)[1], NOW_S)[1] == "unknown",
          "and the reader stays in the abstention")
    # a token the shell's word-anchoring would not accept either
    check(cl._owner_and_lease("claim owner=peerbox xlease_until=1 nonce=y") == ("peerbox", "0"),
          "a mid-word token is not a field, as in the shell")
    twice = "claim owner=peerbox lease_until=9999999999 lease_until=1 nonce=x"
    check(cl._owner_and_lease(twice) == ("peerbox", "9999999999"),
          "a repeated on-line token resolves to the FIRST, as the shell does; got %r"
          % (cl._owner_and_lease(twice),))
    obj2 = obj.replace("committer a <a@b> 1793962674 +0000\n", "")
    check(cl._commit_time(obj2) == 1, "and a single header is simply that header")


# ══════════════════════════════════════════════════════════════════════════
# L15 — the cascade is total, ordered and mutually exclusive
# ══════════════════════════════════════════════════════════════════════════
@test("L15 the claim cascade is TOTAL, ORDERED and mutually exclusive (#1777)")
def l15_cascade_precedence():
    def claim(owner, raw, ref="refs/claims/5-abcdef123456"):
        oh, opid, scope = cl.parse_owner(owner, HOST)
        until, state = cl.parse_lease(raw, NOW_S)
        return liv.Claim(ref=ref, key=ref.rsplit("/", 1)[-1], pr="5", sha12="abcdef123456",
                         owner=owner, owner_host=oh, owner_pid=opid, lease_until=until,
                         lease_state=state, scope=scope)

    local_live = claim("%s:1" % HOST, str(NOW_S + 60))
    local_exp = claim("%s:2" % HOST, str(NOW_S - 60))
    foreign_exp = claim("%s:3" % OTHER_HOST, str(NOW_S - 60))
    unparseable = claim("garbage", str(NOW_S + 60))
    fixtures = [
        # (readable, claims, expected reason) — the ORDERED rungs
        (False, (), "claims-unreadable"),
        (True, (), "no-claim-visible"),
        (True, (unparseable, local_live), "claim-owner-unparseable"),
        (True, (local_live,), "claim-held"),
        (True, (local_live, local_exp), "claim-held"),
        (True, (foreign_exp,), "holder-on-foreign-box"),
        (True, (local_exp,), "claim-holder-unverifiable"),
        # an unparseable owner ANYWHERE outranks an open lease (fail-closed ordering)
        (True, (local_live, unparseable), "claim-owner-unparseable"),
        # an unreadable read outranks everything, including claims in hand
        (False, (local_live,), "claims-unreadable"),
    ]
    seen = set()
    for readable, claims, want in fixtures:
        cr = liv.ClaimRead(readable=readable, present=bool(claims), claims=tuple(claims),
                           source="fixture")
        v = liv.claim_verdict(cr)
        check(v.reason == want, "readable=%s claims=%d => %s, expected %s"
              % (readable, len(claims), v.reason, want))
        check(v.state == "unknown", "every rung abstains; got %s" % v.state)
        check(v.holder_pid is None, "no rung may assert an incarnation")
        seen.add(v.reason)
    check(seen == set(liv.CLAIM_REASONS),
          "the fixture set must exercise every rung (a partition, not a sample); missing %r"
          % sorted(set(liv.CLAIM_REASONS) - seen))
    # Exclusivity: exactly one rung fires, deterministically, for every order.
    import itertools
    for perm in itertools.permutations((unparseable, local_live, foreign_exp)):
        v = liv.claim_verdict(liv.ClaimRead(readable=True, present=True, claims=perm))
        check(v.reason == "claim-owner-unparseable",
              "the ordering must not depend on the registry's iteration order; got %s" % v.reason)


# ══════════════════════════════════════════════════════════════════════════
# L16 — a --sha-only read binds its PR from the MATCH, never from ref order
# ══════════════════════════════════════════════════════════════════════════
@test("L16 a --sha read binds the PR from the MATCH, not from the ls-remote order (B1/P1)")
def l16_sha_binds_from_the_match():
    # `git ls-remote` sorts refs lexicographically, so "5-…" precedes "9999-…".
    # Any box can push a lower-sorting key; the read must not depend on that order.
    decoy = ("refs/claims/5-111111111111", "%s:1" % HOST, str(NOW_S + 60))
    real = ("refs/claims/9999-abcdef123456", "%s:2" % HOST, str(NOW_S + 60))
    with bare_remote([decoy, real]) as remote:
        cr = cl.read_pull(remote, host=HOST, now=NOW_S, sha="abcdef123456")
        check([c.key for c in cr.claims] == ["9999-abcdef123456"],
              "a --sha-only read must find the claim on THAT head; got %r"
              % [c.key for c in cr.claims])
        check(cr.siblings == (),
              "the decoy is another PR, so it is not a sibling; got %r" % (cr.siblings,))
        v = liv.evaluate(cl.to_evidence(cr))
        check(v.reason == "claim-held" and v.reason != "no-claim-visible",
              "a present holder must never read as absent; got %s" % v.reason)
        # Case is normalised: the key is a sha, and a caller may pass uppercase.
        up = cl.read_pull(remote, host=HOST, now=NOW_S, sha="ABCDEF123456")
        check([c.key for c in up.claims] == ["9999-abcdef123456"],
              "an uppercase sha must match the same head; got %r" % [c.key for c in up.claims])
        # A short sha is prefix-matched against the head, per PR when the PR is named.
        short = cl.read_pull(remote, host=HOST, now=NOW_S, sha="abcdef")
        check([c.key for c in short.claims] == ["9999-abcdef123456"],
              "a short sha prefix-matches; got %r" % [c.key for c in short.claims])
        # A named PR with a non-matching head discloses ITS own heads — not another PR's.
        named = cl.read_pull(remote, host=HOST, now=NOW_S, pr="5", sha="abcdef123456")
        check(named.claims == () and named.siblings == ("5-111111111111",),
              "a named PR scopes the disclosure to that PR; got claims=%r siblings=%r"
              % ([c.key for c in named.claims], named.siblings))


# ══════════════════════════════════════════════════════════════════════════
# L17 — a SHORT --sha is a prefix UNION, so a decoy cannot consume the query
# ══════════════════════════════════════════════════════════════════════════
@test("L17 a short --sha unions prefix matches: a decoy cannot consume the query (B10/N1)")
def l17_short_sha_is_a_prefix_union():
    # The decoy's whole sha12 EQUALS the short query, so an exact-match-then-fallback
    # implementation finds a non-empty exact set, never falls back, and drops the real
    # head one character longer (verify-gate cycle-2 P1).
    decoy = ("refs/claims/0-abcdef", "%s:1" % HOST, str(NOW_S + 60))
    real = ("refs/claims/9999-abcdef123456", "%s:2" % HOST, str(NOW_S + 60))
    sib = ("refs/claims/9999-bbbbbbbbbbbb", "%s:3" % HOST, str(NOW_S + 60))
    with bare_remote([decoy, real, sib]) as remote:
        cr = cl.read_pull(remote, host=HOST, now=NOW_S, pr="9999", sha="abcdef")
        check([c.key for c in cr.claims] == ["9999-abcdef123456"],
              "the named PR's head must be found despite the coincidental decoy; got %r"
              % [c.key for c in cr.claims])
        check(cr.siblings == ("9999-bbbbbbbbbbbb",),
              "and that PR's other head is the disclosure; got %r" % (cr.siblings,))
        v = liv.evaluate(cl.to_evidence(cr))
        check(v.reason == "claim-held",
              "a live holder must never read as absent; got %s" % v.reason)
        # With no PR named the head genuinely matched two PRs: return BOTH and declare it.
        both = cl.read_pull(remote, host=HOST, now=NOW_S, sha="abcdef")
        check({c.key for c in both.claims} == {"0-abcdef", "9999-abcdef123456"},
              "an ambiguous head must not be silently reduced to one claim; got %r"
              % sorted(c.key for c in both.claims))
        check(both.siblings == (),
              "no sibling list may be invented across PRs; got %r" % (both.siblings,))
        check("AMBIGUOUS" in both.detail,
              "the ambiguity is declared, not swallowed; got %r" % both.detail)


# ══════════════════════════════════════════════════════════════════════════
# L18 — two PRs on one head sha: every match returned, order-independent
# ══════════════════════════════════════════════════════════════════════════
@test("L18 two PRs on one head sha return EVERY match, order-independently (B10/N2)")
def l18_multi_pr_head_is_declared():
    refs = [("refs/claims/0-abcdef123456", "%s:1" % HOST, str(NOW_S + 60)),
            ("refs/claims/0-zzzzzzzzzzzz", "%s:2" % HOST, str(NOW_S + 60)),
            ("refs/claims/9999-abcdef123456", "%s:3" % HOST, str(NOW_S + 60)),
            ("refs/claims/9999-bbbbbbbbbbbb", "%s:4" % HOST, str(NOW_S + 60))]
    with bare_remote(refs) as remote:
        want = {"0-abcdef123456", "9999-abcdef123456"}
        for _ in range(2):   # twice: the answer may not depend on ls-remote's order
            cr = cl.read_pull(remote, host=HOST, now=NOW_S, sha="abcdef123456")
            check({c.key for c in cr.claims} == want,
                  "every claim on the queried head is returned; got %r"
                  % sorted(c.key for c in cr.claims))
            check(cr.siblings == (),
                  "a sibling list is undefined across PRs and must not be published; got %r"
                  % (cr.siblings,))
            check("AMBIGUOUS" in cr.detail, "the ambiguity is declared; got %r" % cr.detail)
            v = liv.evaluate(cl.to_evidence(cr))
            check(v.state == "unknown" and v.holder_pid is None,
                  "still an abstention; got %s/%s" % (v.state, v.reason))
        # Naming the PR resolves it, and the other PR's heads are NEVER published as this
        # PR's siblings — the exact mis-naming the cycle-2 finding reproduced.
        scoped = cl.read_pull(remote, host=HOST, now=NOW_S, pr="0", sha="abcdef123456")
        check([c.key for c in scoped.claims] == ["0-abcdef123456"],
              "--pr scopes the read; got %r" % [c.key for c in scoped.claims])
        check(scoped.siblings == ("0-zzzzzzzzzzzz",),
              "and scopes the disclosure to THAT PR; got %r" % (scoped.siblings,))
        other = cl.read_pull(remote, host=HOST, now=NOW_S, pr="9999", sha="abcdef123456")
        check("0-zzzzzzzzzzzz" not in other.siblings,
              "the decoy PR's heads must not appear as another PR's siblings; got %r"
              % (other.siblings,))


# ── CLI helper (used by L2, L19 and L20) ──────────────────────────────────
def _cli(args, cwd=None):
    return subprocess.run([sys.executable, MODULE_PATH, *args], cwd=cwd,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                          env=dict(os.environ, CLAIM_HOST=HOST))


def _cli_rc(args):
    return _cli(args).returncode


# ══════════════════════════════════════════════════════════════════════════
# L19 — the CLI contract: usage is 2, and the FILE driver works end to end
# ══════════════════════════════════════════════════════════════════════════
@test("L19 CLI: usage exits 2, and FILE mode reads a snapshot end-to-end (#1777/D2)")
def l19_cli_usage_and_file_mode():
    d = tempfile.mkdtemp(prefix="claims-cli-")
    try:
        snap = write_snapshot(d, "refs/claims/5-abcdef123456\t%s:1\t%d\n"
                              % (HOST, NOW_S + 60))
        # `--snapshot` without its staleness bound: the BOUND is the guard, and
        # inventing one would silently decide how stale a claim may be.
        check(_cli_rc(["--snapshot", snap]) == 2,
              "--snapshot without --max-age-s is a usage error (2), never a silent read")
        check(_cli_rc(["--snapshot", snap, "--max-age-s", "0"]) == 2,
              "a zero staleness bound is refused, not read as 'anything goes'")
        check(_cli_rc(["--snapshot", snap, "--max-age-s", "-1"]) == 2,
              "a negative staleness bound is refused")
        # ⛔ Measured fail-OPEN (cycle-1 D2): argparse's `type=float` accepts
        # nan/inf, and EVERY comparison against a non-finite bound is False — so
        # `nan` accepted a 10-day-old snapshot as fresh (exit 0) instead of
        # abstaining. The value IS the guard, so the value is what is checked.
        check(_cli_rc(["--snapshot", snap, "--max-age-s", "nan"]) == 2,
              "a NON-FINITE staleness bound is refused; it cannot be compared")
        check(_cli_rc(["--snapshot", snap, "--max-age-s", "inf"]) == 2,
              "an infinite staleness bound is refused for the same reason")
        check(_cli_rc(["--timeout", "nan", "--remote-url", "file:///nope.git"]) == 2,
              "a non-finite --timeout is a named usage error, not a traceback")
        check(_cli_rc(["--timeout", "inf", "--remote-url", "file:///nope.git"]) == 2,
              "an infinite --timeout is refused too")
        check(_cli_rc([]) == 2, "no target at all is a usage error — the cwd is never implied")
        check(_cli_rc(["--snapshot", snap, "--now", str(NOW_S)]) == 2,
              "a missing bound outranks the read: usage is decided before the file")
        # ── the FILE driver, end to end ───────────────────────────────────
        check(_cli_rc(["--snapshot", snap, "--max-age-s", "600", "--now", str(NOW_S),
                       "--pr", "5"]) == 0,
              "a FRESH snapshot with a visible claim exits 0 (the positive answer)")
        with open(snap, "r", encoding="utf-8") as fh:
            body = fh.read()
        stale = write_snapshot(d, body, age_s=99999)
        check(_cli_rc(["--snapshot", stale, "--max-age-s", "600", "--now", str(NOW_S)]) == 3,
              "a STALE snapshot abstains (3) instead of deciding")
        check(_cli_rc(["--snapshot", os.path.join(d, "missing"), "--max-age-s", "600"]) == 3,
              "a missing snapshot abstains (3) instead of reading as an empty one")
    finally:
        shutil.rmtree(d, ignore_errors=True)


# ══════════════════════════════════════════════════════════════════════════
# L20 — the DEFAULT output is the text report (the operator's actual view)
# ══════════════════════════════════════════════════════════════════════════
@test("L20 CLI: the default output is the TEXT report, and it declares the gap (#1777)")
def l20_cli_default_output_is_text():
    refs = [("refs/claims/5-abcdef123456", "%s:1" % HOST, str(NOW_S + 60))]
    with bare_remote(refs) as remote:
        proc = _cli(["--remote-url", remote, "--pr", "5", "--now", str(NOW_S)])
    check(proc.returncode == 0, "a visible claim exits 0; stderr=%r" % proc.stderr.strip())
    out = proc.stdout
    check("verdict: unknown (ABSTENTION)" in out,
          "the DEFAULT rendering is the text report, and it names the abstention; got %r"
          % out[:240])
    check("ABSTENTION" in out and "reason=claim-held" in out,
          "the reason is stated, not implied; got %r" % out[:240])
    check("ADVISORY:" in out, "the advisory rides the default output; got %r" % out[:240])
    check("reader limits (what this read cannot see)" in out,
          "the reader's own limits are printed with the default verdict")
    check("holder_pid: never set" in out,
          "the no-incarnation rule is visible to the operator, not only in the source")
    check(not out.lstrip().startswith("{"),
          "--json was not asked for, so the default must not be JSON")


# ══════════════════════════════════════════════════════════════════════════
# L21 — a relative `origin` names ONE absolute target, from any cwd
# ══════════════════════════════════════════════════════════════════════════
@test("L21 a relative `origin` resolves to ONE absolute target, from any cwd (D2)")
def l21_relative_origin_is_absolute():
    # ⛔ Measured (cycle-1 B/deep): with `origin=../origin.git` — an ordinary
    # sibling clone — the SAME `--repo` read `claims-unreadable` from one cwd and
    # `fetch rc=128` from another, because `ls-remote` resolved the relative url
    # against the CALLER's cwd while `fetch -C <tmp>` resolved it against the temp
    # bare repo. One argument, two questions; the reader must name one target.
    d = tempfile.mkdtemp(prefix="claims-rel-")
    try:
        bare = os.path.join(d, "origin.git")
        git(["init", "-q", "--bare", bare])
        commit_claim(bare, "refs/claims/5-abcdef123456", "%s:1" % HOST, str(NOW_S + 60))
        work = os.path.join(d, "work")
        git(["init", "-q", work])
        git(["-C", work, "remote", "add", "origin", "../origin.git"])
        old = os.getcwd()
        try:
            for cwd in (d, work, os.path.dirname(d)):
                os.chdir(cwd)
                cr = cl.read_pull("origin", repo=work, host=HOST, now=NOW_S)
                check(cr.readable is True,
                      "readable from cwd=%s; got %r" % (cwd, cr.detail))
                check([c.key for c in cr.claims] == ["5-abcdef123456"],
                      "the same claim from cwd=%s; got %r"
                      % (cwd, [c.key for c in cr.claims]))
                check(cr.claims[0].owner == "%s:1" % HOST,
                      "metadata read from the SAME target; got %r" % cr.claims[0].owner)
                check(cr.claims[0].scope == "local", "and it is this box's claim")
        finally:
            os.chdir(old)
        # A relative url with NO repo has no non-cwd base, so it is refused rather
        # than guessed (the cwd is never used implicitly).
        try:
            cl._one_target("../origin.git", None)
            raise Failure("a relative remote with no --repo must be a usage error")
        except cl.UsageError:
            pass
    finally:
        shutil.rmtree(d, ignore_errors=True)
    # ── the pass-through half ─────────────────────────────────────────────
    # A ref git already resolves VERBATIM must not be "normalised" into a filesystem
    # path. This is the cycle-1 regression the VERIFY gate caught: a bare `host:path`
    # scp remote (no `user@`) was classified relative, so a valid URL git SSHes to was
    # refused (`--remote-url github.com:org/repo.git` → exit 2) or misresolved under
    # `--repo`. git's own rule is the test: a COLON BEFORE ANY SLASH makes it scp-like.
    for raw in ("https://github.com/o/r.git", "ssh://git@github.com/o/r.git",
                "file:///tmp/x.git", "/tmp/x.git", "user@host:path/r.git",
                "github.com:org/repo.git", "git@github.com:org/repo.git",
                "file:/tmp/x.git", "host:/abs/path.git"):
        got = cl._one_target(raw, None)          # no repo: it must NOT need one
        check(got == raw, "an already-resolved remote passes through verbatim: %r -> %r"
              % (raw, got))
    # git expands a tilde against HOME, so `~/x.git` is already one target too — it must
    # NOT be rewritten under the repo (the second regression the verify gate caught).
    check(cl._one_target("~/probe.git", None) == os.path.expanduser("~/probe.git"),
          "a tilde remote is expanded, not resolved under the repo: %r"
          % cl._one_target("~/probe.git", None))
    # ... while a genuine relative path STILL needs the repo, and resolves to ONE target.
    d2 = tempfile.mkdtemp(prefix="claims-onetarget-")
    try:
        for rel in ("../origin.git", "relative.git", "./x/y.git"):
            check(cl._one_target(rel, d2) == os.path.abspath(os.path.join(d2, rel)),
                  "a relative path resolves against the repo: %r" % rel)
    finally:
        shutil.rmtree(d2, ignore_errors=True)
    for rel in ("../origin.git", "relative.git"):
        try:
            cl._one_target(rel, None)
            raise Failure("a relative remote with no --repo must be a usage error: %r" % rel)
        except cl.UsageError:
            pass


# ══════════════════════════════════════════════════════════════════════════
# L22 — a credential in the remote URL is never echoed into any rendering
# ══════════════════════════════════════════════════════════════════════════
@test("L22 a credential in the remote URL never reaches `source`, text or JSON (#1777)")
def l22_credentials_are_redacted():
    token = "ghp_SECRETTOKENc0ffee"
    raw = "https://user:%s@127.0.0.1:1/r.git" % token
    check(cl._redact_url(raw) == "https://127.0.0.1:1/r.git",
          "userinfo is stripped: got %r" % cl._redact_url(raw))
    # 127.0.0.1:1 refuses instantly (no DNS, no network): the read FAILS, which is
    # the point — `source` is built before the read, so the echo is what is tested.
    cr = cl.read_pull(raw, host=HOST, now=NOW_S)
    check(cr.readable is False, "an unreachable remote is an unreadable read")
    check(token not in cr.source, "the token must not survive into `source`: %r" % cr.source)
    check(token not in cr.detail, "git echoes the URL in stderr, so not into `detail`: %r"
          % cr.detail)
    check("127.0.0.1:1/r.git" in cr.source, "the target is still named: %r" % cr.source)
    v = liv.evaluate(cl.to_evidence(cr))
    for rendering, text in (("text", cl.render_text(cr, v)),
                            ("json", cl.render_json(cr, v))):
        check(token not in text, "the token must not appear in the %s rendering" % rendering)
    # ⛔ Two shapes the FIRST-`@` / no-query redaction left in place (#1777 review):
    # a password whose tail contains `@` (a regex stopping at the first `@` redacts
    # only up to it) and a token in the QUERY string (no userinfo pattern touches it).
    pw = "pa@ssw0rdLEAK"
    pw_url = "https://user:%s@127.0.0.1:1/r.git" % pw
    check(cl._redact_url(pw_url) == "https://127.0.0.1:1/r.git",
          "an `@` inside the password is stripped with the rest of the userinfo: got %r"
          % cl._redact_url(pw_url))
    qs = "https://127.0.0.1:1/r.git?access_token=ghp_QUERYLEAK"
    check("QUERYLEAK" not in cl._redact_url(qs),
          "a query-string credential is stripped: got %r" % cl._redact_url(qs))
    cr_pw = cl.read_pull(pw_url, host=HOST, now=NOW_S)
    check(pw not in cr_pw.source, "the password tail must not survive: %r" % cr_pw.source)
    check(pw not in cr_pw.detail,
          "git echoes the URL in stderr, so the password tail must not reach `detail`: %r"
          % cr_pw.detail)
    cr_qs = cl.read_pull(qs, host=HOST, now=NOW_S)
    check("QUERYLEAK" not in cr_qs.source, "the query token must not survive: %r" % cr_qs.source)
    check("QUERYLEAK" not in cr_qs.detail,
          "git echoes the URL in stderr, so the query token must not reach `detail`: %r"
          % cr_qs.detail)
    for label, c in (("password-tail", cr_pw), ("query", cr_qs)):
        secret = pw if label == "password-tail" else "QUERYLEAK"
        v = liv.evaluate(cl.to_evidence(c))
        for rendering, text in (("text", cl.render_text(c, v)),
                                ("json", cl.render_json(c, v))):
            check(secret not in text,
                  "the %s credential must not appear in the %s rendering" % (label, rendering))


# ══════════════════════════════════════════════════════════════════════════
# L23 — the harness's own truth table (a non-running test is not a caught one)
# ══════════════════════════════════════════════════════════════════════════
@test("L23 the mutation harness cannot read a NON-RUNNING test as 'caught' (#1777)")
def l23_mutation_verdict_requires_a_real_failure():
    """Pinned by a direct truth-table assertion, not a paired mutation.

    A mutation is caught only when the paired test RAN and FAILED. The pre-fix
    harness used `returncode != 0`, and `run_tests` ALSO returns 1 when the filter
    matched nothing (``PASS=0 FAIL=0``) — so a renamed test id, or a typo in the
    map, reported every mutation CAUGHT while verifying nothing: a false-PASS
    generator inside the very evidence the suite's mutation claims rest on. The
    decision lives in THIS file, which the harness never mutates, so it is pinned
    where it lives.
    """
    caught = _mutation_verdict
    check(caught(0, "PASS=1 FAIL=0") is False, "a green run is not a caught mutation")
    check(caught(1, "PASS=0 FAIL=1") is True, "a failed paired test IS caught")
    check(caught(1, "PASS=0 FAIL=0") is False,
          "a filter that matched NO test is not a caught mutation")
    check(caught(1, "  ok   L1 x\nPASS=1 FAIL=0\n") is False, "same, with noise around it")
    check(caught(1, "FAIL L1 x\nPASS=0 FAIL=2\n") is True, "more than one failure counts")
    check(caught(1, "") is False, "an unparseable run is not a caught mutation")
    check(caught(1, "PASS=nope FAIL=1") is False, "a malformed summary is not a caught mutation")


# ══════════════════════════════════════════════════════════════════════════
# L24 — `--remote-url origin` with no --repo is a USAGE exit, never a traceback
# ══════════════════════════════════════════════════════════════════════════
@test("L24 `origin` with no --repo is a USAGE exit (2), never a TypeError traceback (#1777)")
def l24_origin_without_repo_is_usage():
    # `--remote-url origin` is a legal argparse value ("read this remote directly
    # instead of --repo's origin"), and it is the natural way to name the origin
    # remote. With no --repo there is no checkout to resolve it against: the
    # declared contract is exit 2 (usage), and a consumer branches on rc.
    try:
        cl._resolve_remote("origin", None, 5.0)
        raise Failure("`origin` with no --repo must be a usage error")
    except cl.UsageError:
        pass
    except TypeError as exc:
        raise Failure("`origin` with no --repo escaped as %s: %s" % (type(exc).__name__, exc))
    check(_cli_rc(["--remote-url", "origin", "--pr", "1"]) == 2,
          "the CLI must exit 2 (usage), not 1 (an uncaught TypeError)")
    # With a --repo the same value resolves — the guard must not over-block.
    with bare_remote() as remote, work_repo(remote) as work:
        check(cl._resolve_remote("origin", work, 5.0) == remote,
              "`origin` resolves against the repo's own remote when one is given")


# ══════════════════════════════════════════════════════════════════════════
# L33 — resolving `origin` from a NON-UTF-8 `remote.origin.url` is a VERDICT, not a traceback
# ══════════════════════════════════════════════════════════════════════════
@test("L33 a non-UTF-8 `remote.origin.url` yields an abstention verdict, never a UnicodeDecodeError")
def l33_non_utf8_remote_url_is_a_verdict():
    # ⛔ THE LAST `text=True` SITE (review rounds 21–22, agent-infra#3203). `_resolve_remote` read the
    # resolved URL with `_git` — `text=True`, no `errors=` — so a byte the UTF-8 decoder cannot handle
    # (`0xff`) raised `UnicodeDecodeError` straight OUT of the reader: exit 1, no verdict at all, from a
    # value git accepts verbatim in `.git/config`. The contract everywhere else in this tool is an
    # abstention, and an abstention is a VERDICT (exit 2/3), so this pins the polarity through the CLI.
    # The URL is LOCAL (the caller's own config), which is why this is the last site rather than the
    # first — but "local" is not "trusted": `git clone` writes whatever the remote advertises.
    with bare_remote() as remote, work_repo(remote) as work:
        cfg_path = os.path.join(work, ".git", "config")
        with open(cfg_path, "rb") as fh:
            cfg = fh.read()
        bad = os.fsencode(remote).rstrip(b"\n")
        check(bad in cfg, "fixture: the origin URL must be in .git/config as raw bytes")
        with open(cfg_path, "wb") as fh:
            fh.write(cfg.replace(bad, b"file:///tmp/\xff-not-utf8.git", 1))
        try:
            got = cl._resolve_remote("origin", work, 5.0)
        except cl.UsageError:
            got = None          # an abstention at the unit is fine too; both are verdicts
        except UnicodeDecodeError as exc:
            raise Failure("a non-UTF-8 remote URL escaped as UnicodeDecodeError: %s" % (exc,))
        check(got is None or isinstance(got, str),
              "the unit must answer a str or abstain \u2014 never raise out of the decoder; got %r" % (got,))
        # ⛔ THE CONTRACT IS AT THE CLI, because that is where the contract lives: `_git_bytes` decodes
        # with `errors="replace"`, so the URL comes back with U+FFFD in it and the FETCH then fails —
        # a verdict (rc 3, "not answerable"), with no traceback. The pre-fix form (`_git`, `text=True`,
        # no `errors=`) raised UnicodeDecodeError one frame earlier: rc 1 and a `Traceback` on stderr,
        # which is indistinguishable from a bug in this tool.
        proc = _cli(["--remote-url", "origin", "--repo", work, "--pr", "5"])
        check(proc.returncode in (2, 3),
              "the CLI must exit 2 (usage) or 3 (unanswerable), never 1 (a traceback); got %r"
              % (proc.returncode,))
        check("Traceback" not in proc.stderr and "UnicodeDecodeError" not in proc.stderr,
              "no traceback may reach the operator; stderr was %r" % (proc.stderr[:200],))


# ══════════════════════════════════════════════════════════════════════════
# L25 — `issue-<N>` shares the namespace and NEVER answers for a head
# ══════════════════════════════════════════════════════════════════════════
@test("L25 `issue-<N>` keys share the namespace and never answer for a head (#1784)")
def l25_issue_keys_are_not_head_scoped():
    """The namespace carries THREE key shapes; only `<pr>-<sha12>` is HEAD-scoped.

    `claims.sh` mints `claim_key`'s `<pr>-<sha12>`, `claim_issue_key`'s
    `issue-<N>` and `claim_pr_key`'s `pr-<N>` into ONE namespace. Splitting every ref on the
    first `-` parsed `issue-1850` as `pr="issue", sha12="1850"`, so a short
    `--sha 1850` (or `18`) PREFIX-MATCHED it, the CLI exited 0 — "a claim IS
    VISIBLE for the queried head" — for a head nobody holds, and `--json`
    published a `pr`/`sha12` pair that is neither. Wrong in the safe direction is
    still wrong: exit 0 is the signal a controller acts on.
    """
    HEAD_KEY = "1850-abcdef123456"          # the issue number and the PR number COLLIDE
    refs = [("refs/claims/issue-1850", "%s:1" % HOST, str(NOW_S + 60)),
            ("refs/claims/%s" % HEAD_KEY, "%s:2" % HOST, str(NOW_S + 60))]
    with bare_remote(refs) as remote:
        # (a) The grammar is MATCHED, not guessed: an issue key is `issue`, and it
        #     carries the issue number — never an invented pr/sha12 pair.
        bare = cl.read_pull(remote, host=HOST, now=NOW_S)
        check({c.key: c.kind for c in bare.claims} == {"issue-1850": "issue", HEAD_KEY: "head"},
              "both shapes must be classified; got %r"
              % {c.key: c.kind for c in bare.claims})
        issue_row = next(c for c in bare.claims if c.key == "issue-1850")
        check((issue_row.pr, issue_row.sha12, issue_row.issue) == ("", "", "1850"),
              "an issue key must not be parsed into a pr/sha12; got pr=%r sha12=%r issue=%r"
              % (issue_row.pr, issue_row.sha12, issue_row.issue))
        check(issue_row.kind == "issue" and issue_row.ref.endswith("/issue-1850"),
              "the row is still VISIBLE (presence is presence); got %r" % (issue_row,))

        # (b) A short `--sha` that equals the issue number binds NOTHING, and the CLI
        #     says so (3 = nothing established) instead of 0 = "a claim is visible".
        for q in ("1850", "18", "8"):
            cr = cl.read_pull(remote, host=HOST, now=NOW_S, sha=q)
            check(cr.claims == (),
                  "--sha %r must not head-match an issue key; got %r" % (q, [c.key for c in cr.claims]))
            v = liv.evaluate(cl.to_evidence(cr))
            check(v.reason == "no-claim-visible",
                  "an issue claim is not a head holder; got %s" % v.reason)
        check(_cli_rc(["--remote-url", remote, "--sha", "18"]) == 3,
              "the CLI must not exit 0 for a head nobody holds")
        # …and the guard does not over-block: the real head still answers 0.
        check(_cli_rc(["--remote-url", remote, "--sha", "abcdef123456"]) == 0,
              "the real head must still read as held (the exclusion must not over-block)")

        # (c) `--pr` scopes to HEAD keys, so the colliding issue key is not a sibling.
        scoped = cl.read_pull(remote, host=HOST, now=NOW_S, pr="1850")
        check([c.key for c in scoped.claims] == [HEAD_KEY],
              "--pr names HEAD keys; got %r" % [c.key for c in scoped.claims])
        check(scoped.siblings == (),
              "an issue key must never be disclosed as a PR's sibling; got %r" % (scoped.siblings,))

        # (d) The exclusion is DECLARED, so a head-scoped absence is not silently
        #     narrowed to a head-only registry.
        short = cl.read_pull(remote, host=HOST, now=NOW_S, sha="18")
        check("not HEAD-scoped" in short.detail and "issue-1850" in short.detail,
              "the read must name the excluded non-head key; got %r" % short.detail)

        # (e) `--json` publishes the shape instead of a schema lie.
        payload = json.loads(cl.render_json(bare, liv.evaluate(cl.to_evidence(bare))))
        rows = {r["key"]: r for r in payload["claims"]}
        check(rows["issue-1850"]["kind"] == "issue" and rows["issue-1850"]["issue"] == "1850",
              "the JSON must name the row kind; got %r" % (rows["issue-1850"],))
        check(rows["issue-1850"]["pr"] == "" and rows["issue-1850"]["sha12"] == "",
              "the JSON must not invent a pr/sha12 for an issue key; got %r"
              % (rows["issue-1850"],))
        check(rows[HEAD_KEY]["kind"] == "head" and rows[HEAD_KEY]["pr"] == "1850",
              "a HEAD row still publishes its pr; got %r" % (rows[HEAD_KEY],))


# ══════════════════════════════════════════════════════════════════════════
# L26 — the reader's host seam IS the writer's seam (#1784 review, P2-1)
# ══════════════════════════════════════════════════════════════════════════
@test("L26 the host seam the READER honours is the one claims.sh STAMPS (#1784)")
def l26_host_seam_matches_the_writer():
    """`scope` is the ONE field the reader and the writer share, so the two
    programs must read the same env var or they silently disagree.

    `claims.sh`'s `claim_host()` stamps `CLAIM_OWNER_HOST` (the var a cell exports to
    announce itself, #2094). The reader read `CLAIM_HOST`, a name that exists nowhere
    else in the tree, so a box that announced itself was compared against a host the
    writer never stamped. Consequence was label-only (every claim verdict is an
    abstention) — which is exactly why nothing caught it.
    """
    saved = {k: os.environ.get(k) for k in ("CLAIM_OWNER_HOST", "CLAIM_HOST")}
    try:
        # (a) THE WRITER'S SEAM IS HONOURED. This is the assertion the old reader fails.
        os.environ.pop("CLAIM_HOST", None)
        os.environ["CLAIM_OWNER_HOST"] = "writer-box"
        check(cl.short_host() == "writer-box",
              "the reader must read CLAIM_OWNER_HOST, the var claims.sh stamps; got %r"
              % cl.short_host())

        # (b) The writer wins when both are set — the alias must not shadow it.
        os.environ["CLAIM_HOST"] = "stale-probe-box"
        check(cl.short_host() == "writer-box",
              "CLAIM_OWNER_HOST must take precedence over the CLAIM_HOST alias; got %r"
              % cl.short_host())

        # (c) The alias still works, so a probe written against the earlier name runs.
        os.environ.pop("CLAIM_OWNER_HOST", None)
        check(cl.short_host() == "stale-probe-box",
              "the CLAIM_HOST alias must still be honoured; got %r" % cl.short_host())

        # (d) With neither set, the unflagged path is the writer's `hostname -s`.
        os.environ.pop("CLAIM_HOST", None)
        check(cl.short_host("build-07.example.internal") == "build-07",
              "the fallback must be the short form of the hostname")
    finally:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


# ══════════════════════════════════════════════════════════════════════════
# L27 — the snapshot HEADER is the contract, and BOTH readers honour it
# ══════════════════════════════════════════════════════════════════════════
@test("L27 the FILE reader parses the header claim_snapshot WRITES (#2534 review P1)")
def l27_snapshot_header_is_the_contract():
    """`claims.sh` publishes a 4-field header as the snapshot's first line.

    This driver knew only the three-field body, so `len(parts) != 3` fired on line 1 of
    EVERY real snapshot and the documented offline read answered `claims-unreadable` for
    ever — a phantom UNREADABLE, the mirror of the phantom FREE the change removes. It was
    invisible here because every fixture was header-less: a shape the writer no longer
    produces. So the fixtures below are the shapes the writer DOES produce.
    """
    d = tempfile.mkdtemp(prefix="claims-hdr-")
    try:
        row = "refs/claims/5-abcdef123456\t%s:1\t%d\n" % (HOST, NOW_S + 1800)

        def snap(text, age_s=0):
            return write_snapshot(d, text, age_s=age_s)

        fresh = "#claim-snapshot\t%d\tok\t1\n%s" % (NOW_S, row)
        cr = cl.read_snapshot(snap(fresh), max_age_s=600, host=HOST, now=NOW_S, pr="5")
        check(cr.readable is True, "a header-then-rows snapshot is READABLE; got %r" % (cr.detail,))
        check(len(cr.claims) == 1 and cr.claims[0].key == "5-abcdef123456",
              "the row under the header is the claim; got %r" % ([c.key for c in cr.claims],))
        check(cr.claims[0].lease_state == "live", "the lease is still classified live")

        # a readable EMPTY snapshot: the registry answered and holds nothing (the control —
        # proves the body IS consulted and `claim-absent` is not a silent fallback)
        empty = cl.read_snapshot(snap("#claim-snapshot\t%d\tok\t0\n" % NOW_S),
                                 max_age_s=600, host=HOST, now=NOW_S, pr="5")
        check(empty.readable is True and empty.claims == (),
              "a header stating ZERO refs is a readable empty read, not an abstention")

        # ⛔ A FAILED FETCH IS REFUSED AT ANY AGE: its rows are the LAST GOOD read, so a claim
        # published or released since then is invisible — an answer this file cannot give.
        failed = "#claim-snapshot\t%d\tfailed\t1\n%s" % (NOW_S, row)
        cr = cl.read_snapshot(snap(failed), max_age_s=600, host=HOST, now=NOW_S, pr="5")
        check(cr.readable is False, "a FAILED-fetch header must not be read as a snapshot")
        check("FAILED fetch" in (cr.detail or ""), "and it says why; got %r" % (cr.detail,))

        # ⛔ THE HEADER'S read_at IS THE AGE — NOT THE MTIME. An old mtime with a fresh header is
        # a snapshot whose copy was carried; a fresh mtime with an old header is a stale read
        # dressed up. Reading either off the mtime is how a stale read stays believed.
        cr = cl.read_snapshot(snap(fresh, age_s=99999), max_age_s=600, host=HOST, now=NOW_S,
                             pr="5")
        check(cr.readable is True,
              "a fresh HEADER is believed even when the file's mtime is old; got %r" % (cr.detail,))
        old_hdr = "#claim-snapshot\t%d\tok\t1\n%s" % (NOW_S - 99999, row)
        cr = cl.read_snapshot(snap(old_hdr), max_age_s=600, host=HOST, now=NOW_S, pr="5")
        check(cr.readable is False, "an over-age HEADER is refused even on a fresh mtime")

        # ⛔ A FUTURE STAMP IS DROPPED, NEVER TRUSTED (AGENTS.md's one-sided-age rule, now the
        # fleet's cross-box signal): clamping it to fresh would believe it for ever.
        future = "#claim-snapshot\t%d\tok\t1\n%s" % (NOW_S + 999, row)
        cr = cl.read_snapshot(snap(future), max_age_s=600, host=HOST, now=NOW_S, pr="5")
        check(cr.readable is False, "a read instant AHEAD of the clock is refused, not clamped")

        # Malformed headers: a writer this reader cannot parse is NOT an old writer, so the
        # mtime fallback (kept for the pre-header writer, below) must not answer for it.
        for label, hdr in (("no read instant", "#claim-snapshot\n"),
                           ("non-numeric read instant", "#claim-snapshot\tsoon\tok\t1\n"),
                           ("three-field header", "#claim-snapshot\t%d\tok\n" % NOW_S)):
            cr = cl.read_snapshot(snap(hdr + row), max_age_s=600, host=HOST, now=NOW_S, pr="5")
            check(cr.readable is False, "a header with %s must abstain; got %r"
                  % (label, cr.detail))
        cr = cl.read_snapshot(snap(row + "#claim-snapshot\t%d\tok\t1\n" % NOW_S),
                             max_age_s=600, host=HOST, now=NOW_S, pr="5")
        check(cr.readable is False, "a header that is not the FIRST line is shape drift")

        # The pre-header writer keeps working on the mtime — that fallback is for an OLD writer.
        legacy = write_snapshot(d, row)
        cr = cl.read_snapshot(legacy, max_age_s=600, host=HOST, now=NOW_S, pr="5")
        check(cr.readable is True and len(cr.claims) == 1,
              "a header-LESS snapshot from an older writer still reads; got %r" % (cr.detail,))
    finally:
        shutil.rmtree(d, ignore_errors=True)


# ══════════════════════════════════════════════════════════════════════════
# L28 — CROSS-LANGUAGE PIN: the file claims.sh WRITES is the file this reads
# ══════════════════════════════════════════════════════════════════════════
@test("L29 a VT inside the OWNER field does not make the snapshot unreadable for every key")
def l29_vt_in_owner():
    # ⛔ THE SNAPSHOT READ WAS THE SAME TRAP (review round 17, agent-infra#3203). `read_snapshot` opened
    # the file in text mode (`newline=None`) and split with `splitlines()`, which breaks on VT/FF/NEL/
    # LS/PS/U+2028 — but the WRITER's owner comes from `_lease_of`'s space/TAB word split, so it can
    # legitimately CONTAIN one. One peer-minted claim then shifted every line's field count and the
    # whole snapshot read `unreadable` for ALL keys on the box (measured: "expected 3 tab-separated
    # fields, got 2"). Fail-closed, but one bad row must not blind the registry.
    d = tempfile.mkdtemp(prefix="snap-vt-")
    try:
        f = os.path.join(d, "snapshot.tsv")
        # ⛔ THE SEPARATOR MUST BE **TRAILING** TOO (review round 18, agent-infra#3203): the round-17
        # fixture put the VT in the MIDDLE (`c\x0b1`), where a bare `.strip()` changes nothing, so it
        # discriminated `splitlines()` but not the trim — the exact defect round 17 fixed one file away.
        # Each field gets a row whose separator is at its END, which is the shape `.strip()` repairs.
        rows = [
            ("refs/claims/9-bbbbbbbbbbbb", "c\x0b1", "9999999999"),      # interior (round 17)
            ("refs/claims/9-bbbbbbbbbbbb\x0b", "c", "9999999999"),       # trailing ref
            ("refs/claims/9-bbbbbbbbbbbb", "c\x0b", "9999999999"),       # trailing owner
            ("refs/claims/9-bbbbbbbbbbbb", "c", "9999999999\x0b"),       # trailing lease
            ("refs/claims/9-bbbbbbbbbbbb", "c", "9999999999\u00a0"),
            ("refs/claims/9-bbbbbbbbbbbb", "c", "9999999999\u2003"),
        ]
        with open(f, "w", encoding="utf-8") as fh:
            fh.write("#claim-snapshot\t%d\tok\t%d\n" % (NOW_S, len(rows)))
            for r, o, u in rows:
                fh.write("%s\t%s\t%s\n" % (r, o, u))
        cr = cl.read_snapshot(f, host=HOST, max_age_s=3600, now=NOW_S)
        check(cr.readable is True, "a separator is CONTENT, not a line break; got %r"
              % (cr.detail,))
        check(len(cr.claims) == len(rows), "every row survives; got %r"
              % ([c.ref for c in cr.claims],))
        check([c.ref for c in cr.claims] == [r for r, _o, _u in rows],
              "every refname is kept VERBATIM (a trailing separator is not trimmed away); got %r"
              % ([c.ref for c in cr.claims],))
        check([c.owner for c in cr.claims] == [o for _r, o, _u in rows],
              "every owner is kept VERBATIM; got %r" % ([c.owner for c in cr.claims],))
        # and the FIELD that decides free-or-not: a lease with a TRAILING separator is not a term (the
        # first three rows carry a clean `9999999999`, which is genuinely LIVE — the ref/owner
        # separators must not disturb it, which is the other half of the property).
        want_state = ["live", "live", "live", "unknown", "unknown", "unknown"]
        check([c.lease_state for c in cr.claims] == want_state,
              "a lease with a trailing non-ASCII separator is UNPARSEABLE, and a separator in the "
              "ref/owner does not disturb a clean term; want %r got %r"
              % (want_state, [c.lease_state for c in cr.claims]))
    finally:
        shutil.rmtree(d, ignore_errors=True)


@test("L28 the SHIPPED claim_snapshot's output reads back here (#2534 review P1)")
def l28_shell_written_snapshot_reads_back():
    """The only pin that makes this class self-identifying: run the real writer.

    Every fixture in this file is hand-written, so it can drift from the shape the shell
    actually publishes — which is exactly how a 4-field header shipped past a 3-field
    reader with this suite 36/36 green. Here the bytes come from `claim_snapshot` itself.
    """
    live_until = int(time.time()) + 1800
    with bare_remote([("refs/claims/5-abcdef123456", "%s:1" % OTHER_HOST, str(live_until))]) as remote:
        # `claim_snapshot` fetches from a remote named `origin`, so the fixture must be a checkout
        # whose origin IS the registry — a bare path with no remote makes the fetch fail, which is
        # the one shape that publishes a `failed` header (pinned separately in L27).
        with work_repo(remote) as work:
            d = tempfile.mkdtemp(prefix="claims-xlang-")
            try:
                snap = os.path.join(d, "claims-snapshot")
                driver = os.path.join(d, "snapshot.sh")
                with open(driver, "w", encoding="utf-8") as fh:
                    fh.write("set -eu\n"
                             'CLAIM_REPO="$1"\n'
                             'CLAIM_OWNER_HOST="$3"\n'
                             '. "$2"\n'
                             'claim_snapshot "$4"\n')
                proc = subprocess.run(["bash", driver, work, CLAIMS_SH, HOST, snap],
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                check(proc.returncode == 0,
                      "claim_snapshot failed: %s" % proc.stderr.strip())
                with open(snap, "r", encoding="utf-8") as fh:
                    written = fh.read()
                check(written.startswith("#claim-snapshot\t"),
                      "the writer's first line must be the header; got %r" % written[:80])
                cr = cl.read_snapshot(snap, max_age_s=600, host=HOST, pr="5")
                check(cr.readable is True,
                      "the file the SHIPPED writer publishes must be READABLE by the reader "
                      "that documents it; got %r" % (cr.detail,))
                check(len(cr.claims) == 1 and cr.claims[0].key == "5-abcdef123456",
                      "and the claim the shell fetched is the claim this reads; got %r"
                      % ([c.key for c in cr.claims],))
                check(cr.claims[0].scope == "foreign",
                      "the holder is another box, read from the shell's own owner stamp")
            finally:
                shutil.rmtree(d, ignore_errors=True)


# ══════════════════════════════════════════════════════════════════════════
# The mutation map: each entry reintroduces the defect its test catches.
# ══════════════════════════════════════════════════════════════════════════
class Mutation:
    def __init__(self, test_name, target, old, new, why):
        self.test_name = test_name
        self.target = target      # "reader" | "classifier"
        self.old = old
        self.new = new
        self.why = why


MUTATIONS = [
    Mutation(
        "L27", "reader",
        '        if raw.startswith(SNAPSHOT_HEADER):',
        '        if False:',
        "the pre-fix reader returns: the writer's 4-field header is parsed as a 3-field "
        "row, so EVERY real snapshot is SHAPE DRIFT and the fleet reads claims-unreadable "
        "for ever (a phantom UNREADABLE, the mirror of a phantom FREE)",
    ),
    Mutation(
        "L27", "reader",
        '            if fetch == "failed":',
        '            if False:',
        "a FAILED fetch is believed: its rows are the last good read, so a released claim "
        "still reads held and a live peer's new claim is invisible",
    ),
    Mutation(
        "L27", "reader",
        '            if age < 0:',
        '            if False:',
        "a future read instant is CLAMPED to fresh instead of dropped, so the further ahead "
        "the stamp, the longer it is believed — with no age bound at all",
    ),
    Mutation(
        "L1", "reader",
        '    return until, ("live" if now <= until else "expired")',
        '    return until, "live"',
        "an expired lease reads live forever, so a dead holder blocks its PR indefinitely",
    ),
    Mutation(
        "L2", "reader",
        '    if failure or rc != 0:',
        '    if False:',
        "a failed ls-remote is no longer distinguished from an empty one — the #1777 defect",
    ),
    Mutation(
        "L3", "reader",
        '    if not refs:\n'
        '        return liveness.ClaimRead(readable=True, present=False, claims=(), source=source)',
        '    if not refs:\n'
        '        return liveness.ClaimRead(readable=False, present=False, claims=(), source=source)',
        "an empty registry is reported as an unreadable one (the two facts are collapsed)",
    ),
    Mutation(
        "L4", "reader",
        '            claims.append(_row(ref, owner, raw_until, ns, host, now, commit, committed_at))',
        '            _unreachable = _row(ref, owner, raw_until, ns, host, now, commit, committed_at)',
        "a metadata failure DROPS the claim, so presence stops refuting freedom",
    ),
    Mutation(
        "L5", "reader",
        '    sibs = tuple(sorted(c.key for c in heads if c.pr == pr and c.key not in\n'
        '                        {t.key for t in targets}))',
        '    sibs = ()',
        "the PR's other heads stop being disclosed, so an absent key reads as a free PR",
    ),
    Mutation(
        "L6", "reader",
        '    except OSError as exc:\n'
        '        return liveness.ClaimRead(readable=False, present=False, claims=(), source=source,\n'
        '                                  detail="snapshot unreadable: %s" % sanitize(exc))\n'
        '    mtime_age = now - int(st.st_mtime)',
        '    except OSError as exc:\n'
        '        return liveness.ClaimRead(readable=True, present=False, claims=(), source=source,\n'
        '                                  detail="snapshot unreadable: %s" % sanitize(exc))\n'
        '    mtime_age = now - int(st.st_mtime)',
        "a MISSING snapshot reads as a successful empty read — absence inferred as freedom",
    ),
    Mutation(
        "L7", "reader",
        '    if not header_seen and mtime_age > float(max_age_s):',
        '    if False:',
        "the staleness bound is ignored, so an arbitrarily old snapshot decides",
    ),
    Mutation(
        "L8", "reader",
        '        if len(parts) != 3:',
        '        if len(parts) > 3:',
        "shape drift is tolerated, so a partially-parsed registry decides",
    ),
    Mutation(
        "L9", "reader",
        '    if not claims:\n'
        '        return liveness.ClaimRead(readable=True, present=False, claims=(), source=source)',
        '    if not claims:\n'
        '        return liveness.ClaimRead(readable=False, present=False, claims=(), source=source)',
        "a 0-byte snapshot is reported as unreadable, so 'read, found none' is lost",
    ),
    Mutation(
        "L10", "reader",
        '    if not _LEASE_RE.match(s):\n        return None, "unknown"',
        '    if not _LEASE_RE.match(s) and s != "-5":\n        return None, "unknown"',
        "the reader accepts a negative lease as a real value and reads it expired",
    ),
    Mutation(
        "L10", "reader",
        # The anchor is the SHIPPED guard, and it must stay a CONTIGUOUS substring of the source: the
        # round-19 comment block sits between these lines and the final return, so the mutation replaces
        # only the guard (the code after it becomes dead, which is what "no guard" means here).
        '    _headers, sep, body = (obj or "").partition("\\n\\n")\n'
        '    if not sep:\n'
        '        return ""',
        '    return (obj or "").replace("\\r", "")',
        "the commit HEADERS are parsed as if they were the message, so a header supplies "
        "owner=/lease_until= and the reader disagrees with claims.sh about one lease",
    ),
    # ── the tests THIS CHANGE added (agent-infra#3203). The file's contract is that every mutation
    # re-introduces the defect its paired test exists to catch; without these entries seven new
    # assertions had no recorded defect, which is how an assertion becomes vacuous unnoticed.
    Mutation(
        "L10b", "reader",
        '        if _cand.strip(" \\t"):\n            line = _cand\n            break',
        '        if _cand.strip(" \\t"):\n            line = _cand\n            continue',
        "the reader SCANS PAST the first non-empty line (the pre-round-13 whole-body read), so a lease "
        "token on a later line becomes the claim's term \u2014 `expired` where the shell ABSTAINS",
    ),
    Mutation(
        "L10b", "reader",
        '    u = re.findall(r"(?<![^ \\t])lease_until=([0-9]+)(?=[ \\t]|$)", line)',
        '    u = re.findall(r"lease_until=([0-9]+)", line)',
        "the lease token loses its WORD anchoring, so `xlease_until=1` is read as a field the shell "
        "ignores \u2014 a term invented from a word nobody wrote",
    ),
    Mutation(
        "L33", "reader",
        '        rc, out, _err, failure = _git_bytes(["-C", repo, "remote", "get-url", "origin"], timeout)',
        '        rc, out, _err, failure = _git(["-C", repo, "remote", "get-url", "origin"], timeout)',
        "the resolved URL is decoded with `text=True` and no `errors=`, so a non-UTF-8 "
        "`remote.origin.url` raises UnicodeDecodeError out of the reader \u2014 exit 1, no verdict",
    ),
    Mutation(
        "L10c", "reader",
        '    crc, cout, _cerr, cfail = _git_bytes(["-C", tmp, "cat-file", "commit", sha_hex], timeout)',
        '    crc, cout, _cerr, cfail = _git(["-C", tmp, "cat-file", "commit", sha_hex], timeout)',
        "the object is decoded with universal newlines, so a lone CR becomes a LINE BREAK and the "
        "reader takes the first line's term \u2014 FREE for a claim the shell fuses into one invalid token",
    ),
    Mutation(
        "L10d", "reader",
        '    for line in out.split("\\n"):',
        '    for line in out.splitlines():',
        "`ls-remote` is split on Unicode line boundaries, so a legal refname carrying U+2028 surfaces "
        "as a claim at the CANONICAL key \u2014 a phantom held",
    ),
    Mutation(
        "L10d", "reader",
        '        sha_hex, ref = parts[0].strip(" \\t"), parts[1].strip(" \\t")',
        '        sha_hex, ref = parts[0].strip(), parts[1].strip()',
        "the refname is Unicode-trimmed, so `refs/claims/<pr>-<sha12><U+2028>` collapses onto the "
        "canonical key \u2014 a claim at a ref nobody pushed",
    ),
    Mutation(
        "L29", "reader",
        '    for lineno, raw in enumerate(text.split("\\n"), 1):',
        '    for lineno, raw in enumerate(text.splitlines(), 1):',
        "the SNAPSHOT is split on Unicode line boundaries, so a VT/LS inside the writer's OWNER field "
        "(legal: `_lease_of` splits on space/TAB only) makes every row SHAPE DRIFT \u2014 the whole "
        "registry unreadable for every key on the box",
    ),
    Mutation(
        "L29", "reader",
        '        claims.append(_row(ref.strip(" \\t"), owner.strip(" \\t"), raw_until.strip(" \\t"),',
        '        claims.append(_row(ref.strip(), owner.strip(), raw_until.strip(),',
        "the snapshot fields are Unicode-trimmed, so a lease with a TRAILING separator becomes a pure "
        "digit string and reads as a real (expired) term \u2014 FREE",
    ),
    Mutation(
        "L30", "reader",
        '_COMMITTER_TIME_RE = re.compile(r"^committer .* ([0-9]+) [+-][0-9]{4}$", re.M)',
        '_COMMITTER_TIME_RE = re.compile(r"^committer .* ([0-9]+) [+-][0-9]{4}[ \\t]*$", re.M)',
        "the committer stamp is accepted with trailing whitespace and any length, so an object the "
        "oracle calls UNMEASURABLE is dated here and the bounded reap is measured from a guess",
    ),
    Mutation(
        "L30", "reader",
        '    head = "\\n".join(itertools.takewhile(lambda _l: _l != "", text.split("\\n")))',
        '    head = text.partition("\\n\\n")[0] if "\\n\\n" in text else text',
        "the scope is `partition` rather than `sed -n '/^$/q;p'`, so an object whose FIRST line is empty "
        "is scanned whole \u2014 a stamp the oracle refuses (an unmeasurable age read as measurable)",
    ),
    Mutation(
        "L30", "reader",
        '    lines = [_l for _l in head.split("\\n") if _l.startswith("committer ")]',
        '    lines = [_l for _l in text.split("\\n") if _l.startswith("committer ")]',
        "the reader scans the WHOLE object, so a `committer`-shaped line in the peer-writable "
        "MESSAGE supplies the age \u2014 the oracle's `sed -n '/^$/q;p'` never looks there",
    ),
    # ⛔ THE RULE ITSELF, AS A MUTATION (review round 24). Rounds 20–21 pinned the OLD oracle rule (the
    # last line that MATCHES) and this suite was green; round 24 split the shell's parse into
    # SELECT-then-PARSE, so that rule is now the DEFECT: a newest `committer` header carrying any
    # trailing token falls through to an EARLIER line and forges a fresh claim's age. Restoring the
    # one-stage `findall` must turn L30 RED on `shape_bad_last` / `tz_short` / `forged`.
    Mutation(
        "L30", "reader",
        '    lines = [_l for _l in head.split("\\n") if _l.startswith("committer ")]\n'
        '    if not lines:\n'
        '        return None\n'
        '    m = _COMMITTER_TIME_RE.match(lines[-1])\n'
        '    if not m:\n'
        '        return None\n'
        '    stamp = m.group(1)',
        '    _ms = _COMMITTER_TIME_RE.findall(head)\n'
        '    if not _ms:\n'
        '        return None\n'
        '    stamp = _ms[-1]',
        "the parse is ONE anchored pass over every matching line again (the pre-round-24 oracle rule), "
        "so a shape-broken LAST `committer` header is SKIPPED and an EARLIER line supplies the age \u2014 "
        "the forged-age steal the oracle now refuses",
    ),
    Mutation(
        "L30", "reader",
        '    if stamp.startswith("0") and len(stamp) > 1:\n'
        '        return None',
        '    if False:\n'
        '        return None',
        "the leading-zero arm is deleted, so a peer-writable `0000009999` stamp becomes a 1970 date "
        "here while the oracle calls the age UNMEASURABLE",
    ),
    Mutation(
        "L31", "reader",
        '    m = _OWNER_RE.match((owner or "").strip(" \\t"))',
        '    m = _OWNER_RE.match((owner or "").strip())',
        "the owner is Unicode-trimmed, so `boxA:7<U+2028>` parses as a real owner (a label invented "
        "from a value nobody wrote)",
    ),
    Mutation(
        "L32", "reader",
        '    return body.replace("\\x00", "").replace("\\r", "")',
        '    return body.replace("\\r", "")',
        "NUL bytes are carried instead of deleted, so `lease_until=1<NUL>lease_until=<live>` reads as "
        "TWO words and the first is taken \u2014 FREE, where bash's `$( )` fuses them into one invalid token",
    ),
    Mutation(
        "L11", "reader",
        '    kw.setdefault("candidates", [])',
        '    kw.setdefault("candidates", [])\n'
        '    kw["_verdict"] = liveness.Verdict("dead", "reader-decided")',
        "the reader starts constructing a verdict of its own (a second opinion, #1178)",
    ),
    Mutation(
        "L12", "reader",
        '    rc, out, err, failure = _git_bytes(["ls-remote", url, "%s/*" % ns], timeout)',
        '    rc, out, err, failure = _git(\n'
        '        ["-C", repo or ".", "for-each-ref", "--format=%(objectname)\\t%(refname)", ns], timeout)',
        "the LOCAL ref space is read, so a stale local claim decides instead of the registry",
    ),
    Mutation(
        "L13", "reader",
        '    out = out.replace("|", "\\\\|").replace("`", "\'")',
        '    out = out',
        "render-hostile owner input is no longer neutralised (a forged column/newline)",
    ),
    Mutation(
        "L13", "reader",
        '    vd["detail"] = sanitize(vd["detail"], 400)',
        '    vd["detail"] = vd["detail"]',
        "the JSON verdict detail keeps the attacker-influencable owner string raw while "
        "render_text sanitizes it — the one inconsistent path (#1784 P2)",
    ),
    Mutation(
        "L14", "reader",
        '    resolved = remote\n    if remote == "origin":',
        '    resolved = "origin"\n    if False:',
        "`origin` is never resolved, so the read names a path under the repo (or the CWD's "
        "repo) instead of the caller's remote target",
    ),
    Mutation(
        "L15", "classifier",
        '    if any(c.scope == "unknown" for c in cr.claims):',
        '    if False:',
        "an unusable owner no longer outranks an open lease, so the cascade order inverts",
    ),
    Mutation(
        "L16", "reader",
        '    if sha:\n'
        '        targets = [c for c in heads if c.sha12.lower() == want]',
        '    pr = pr or (claims[0].pr if claims else "")\n'
        '    if sha:\n'
        '        targets = [c for c in claims if c.key == "%s-%s" % (pr, want)]',
        "the cycle-1 bypass returns: the PR comes from the ls-remote ORDER and the head is "
        "matched by that PR's key, so a lower-sorting claim key hides a live holder",
    ),
    Mutation(
        "L16", "reader",
        '    want = (sha or "")[:12].lower()',
        '    want = (sha or "")[:12]',
        "the sha is no longer case-normalised, so an uppercase sha misses its own head",
    ),
    Mutation(
        "L17", "reader",
        '        if len(want) < 12:\n'
        '            pre = [c for c in heads if c.sha12.lower().startswith(want)]\n'
        '            if len(pre) > len(targets):\n'
        '                targets = pre',
        '        if not targets and len(want) < 12:\n'
        '            targets = [c for c in heads if c.sha12.lower().startswith(want)]',
        "the short-sha prefix becomes a fallback again, so a decoy whose sha12 EQUALS the "
        "short query consumes it and hides the real head (the cycle-2 N1 bypass)",
    ),
    Mutation(
        "L18", "reader",
        '        if pr:\n'
        '            pass                        # the caller resolved the ambiguity\n'
        '        elif len(prs) == 1:\n'
        '            pr = prs[0]                 # unambiguous: bind from the match\n'
        '        elif prs:',
        '        if pr:\n'
        '            pass                        # the caller resolved the ambiguity\n'
        '        elif prs:\n'
        '            pr = targets[0].pr          # pre-fix indexing: ls-remote order decides\n'
        '        elif prs:',
        "a multi-PR head is reduced to targets[0] again, so the PR (and its published "
        "sibling list) follows the ref order (the cycle-2 N2 bypass)",
    ),
    Mutation(
        "L19", "reader",
        '    if not math.isfinite(num):',
        '    if False:',
        "a NON-FINITE duration is accepted, and every comparison against it is False — so "
        "`--max-age-s nan` silently certifies a stale snapshot as fresh (the D2 fail-open)",
    ),
    Mutation(
        "L21", "reader",
        '    return os.path.abspath(os.path.join(repo, s))',
        '    return s',
        "a RELATIVE remote is left relative, so ls-remote and fetch resolve it against two "
        "different directories and one --repo answers per cwd",
    ),
    Mutation(
        "L21", "reader",
        "    r\"|[^/@\\s]+:\"                           # `host:path` — git's own scp test (colon before any `/`)\n",
        "",
        "a bare `host:path` scp remote is classified RELATIVE, so a URL git resolves "
        "verbatim is refused (or, under --repo, rewritten into a bogus local path)",
    ),
    Mutation(
        "L22", "reader",
        '        rest = re.split(r"[?#]", m.group("rest"), maxsplit=1)[0]\n',
        '',
        "the query string is NOT stripped, so a `?access_token=…` credential survives "
        "into `source`/`detail` (and from there into the report and an issue body)",
    ),
    Mutation(
        "L22", "reader",
        '        if "@" in authority:\n'
        '            authority = authority[authority.rfind("@") + 1:]\n',
        '',
        "userinfo is not stripped, so a credential (including one whose password tail "
        "holds `@`) is echoed into `source`/`detail`",
    ),
    Mutation(
        "L24", "reader",
        '        if not repo:\n',
        '        if False:\n',
        "`origin` with no --repo reaches git as a None path and escapes as an uncaught "
        "TypeError (exit 1), not the declared usage exit 2",
    ),
    Mutation(
        "L25", "reader",
        '    m = _KEY_ISSUE_RE.match(raw)\n'
        '    if m:\n'
        '        return "issue", "", "", m.group("issue")',
        '    m = _KEY_ISSUE_RE.match(raw)\n'
        '    if m:\n'
        '        return "head", "issue", m.group("issue"), ""',
        "the pre-fix split returns: an `issue-<N>` key is parsed as pr=\"issue\"/"
        "sha12=\"<N>\", so a short --sha head-matches it and the CLI exits 0 for a "
        "head nobody holds",
    ),
    Mutation(
        "L25", "reader",
        '"sha12": sanitize(c.sha12, 20), "kind": c.kind,',
        '"sha12": sanitize(c.sha12, 20), "kind": "head",',
        "every JSON row is published as a HEAD row, so a machine consumer head-matches "
        "an issue claim",
    ),
    Mutation(
        "L25", "reader",
        '    if other:\n'
        '        excl = ("%d claim key(s) in the namespace are not HEAD-scoped (%s) and cannot "',
        '    if False:\n'
        '        excl = ("%d claim key(s) in the namespace are not HEAD-scoped (%s) and cannot "',
        "the excluded non-head keys are no longer named, so a head-scoped absence is "
        "silently narrowed to a head-only registry",
    ),
]


# ── runner ───────────────────────────────────────────────────────────────
def run_tests(only=None):
    passed = failed = 0
    for name, fn in TESTS:
        if only and name.split()[0] != only:
            continue
        try:
            fn()
        except Exception as exc:  # noqa: BLE001 - a test runner reports everything
            failed += 1
            print("  FAIL %s\n       %s: %s" % (name, type(exc).__name__, exc))
        else:
            passed += 1
            print("  ok   %s" % name)
    print("PASS=%d FAIL=%d" % (passed, failed))
    return failed == 0 and passed > 0


def _mutated_env(mut):
    """Write the mutant PAIR (one mutated, one verbatim) into a temp dir."""
    tmp = tempfile.mkdtemp(prefix="claims-mutant-")
    src_reader = MODULE_PATH
    src_classifier = CLASSIFIER_PATH
    for target, src in (("reader", src_reader), ("classifier", src_classifier)):
        with open(src, "r", encoding="utf-8") as fh:
            body = fh.read()
        name = "claim_lanes.py" if target == "reader" else "liveness.py"
        if target == mut.target:
            if body.count(mut.old) != 1:
                raise SystemExit("mutation anchor not unique in %s (%d hits):\n%s"
                                 % (src, body.count(mut.old), mut.old))
            body = body.replace(mut.old, mut.new, 1)
        with open(os.path.join(tmp, name), "w", encoding="utf-8") as fh:
            fh.write(body)
    env = {"CLAIM_LANES_MODULE": os.path.join(tmp, "claim_lanes.py"),
           "CLAIM_LANES_ONLY": mut.test_name, "CLAIM_HOST": HOST}
    return tmp, env


def _mutation_verdict(returncode: int, body: str) -> bool:
    """Is this mutation CAUGHT? Only if the paired test RAN and FAILED.

    ⛔ `returncode != 0` is NOT the test: ``run_tests`` also exits 1 when the
    filter matched nothing at all (``PASS=0 FAIL=0``), so a renamed test id — or a
    typo in the map — would report every mutation CAUGHT while verifying nothing.
    Published by the runner as its own summary line, so the summary is the source
    of the verdict.
    """
    if returncode == 0:
        return False
    for line in body.splitlines():
        m = re.match(r"\s*PASS=(\d+) FAIL=(\d+)\s*$", line)
        if m:
            return int(m.group(2)) > 0
    return False


def run_mutations():
    print("── MUTATION EVIDENCE — each mutation must make its paired test RED ──")
    print("   (the mutated pair is written to a temp dir; the real files are never touched)\n")
    bad = 0
    for mut in MUTATIONS:
        tmp, env = _mutated_env(mut)
        try:
            proc = subprocess.run(
                [sys.executable, os.path.abspath(__file__)],
                env=dict(os.environ, **env),
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            )
            body = proc.stdout.decode("utf-8", "replace")
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        red = _mutation_verdict(proc.returncode, body)
        print("── %s mutation → %s ───────────────────────────────────────" % (mut.test_name, mut.why))
        for line in body.splitlines():
            print("   | %s" % line)
        if red:
            print("   ✅ RED (the paired test caught the defect, rc=%d)\n" % proc.returncode)
        else:
            bad += 1
            if "FAIL=0" in body and "PASS=0" in body:
                print("   ❌ NOT RUN — no test matched `%s`; this mutation verified NOTHING\n"
                      % mut.test_name)
            else:
                print("   ❌ NOT RED — the paired test did NOT catch its own defect\n")
    print("MUTATIONS=%d CAUGHT=%d MISSED=%d" % (len(MUTATIONS), len(MUTATIONS) - bad, bad))
    return bad == 0


def main(argv):
    if "--mutations" in argv:
        return 0 if run_mutations() else 1
    print("── #1777 ref-claim reader acceptance suite (%d tests) ──" % len(TESTS))
    return 0 if run_tests(os.environ.get("CLAIM_LANES_ONLY")) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
