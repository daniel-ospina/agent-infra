#!/usr/bin/env python3
"""tools/fleet/claim_lanes.test.py — the #1777 ref-claim reader acceptance suite.

Eighteen tests with nineteen paired mutations: every mutation re-introduces the
defect its test exists to catch, so "the test fails without the fix" is an
EXECUTED claim rather than an asserted one (the standard this repo's
``liveness.test.py`` set).

    python3.12 tools/fleet/claim_lanes.test.py              # the 15 tests, green
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
import shutil
import stat
import subprocess
import sys
import tempfile

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
            check(proc.returncode == 0, "claims.sh primitives failed for %s: %s"
                  % (label, proc.stderr.strip()))
            shell_owner, _tab, shell_until = proc.stdout.rstrip("\n").partition("\t")
            # The shell is the ORACLE for what the file contains; the Python reader
            # must classify that content the way claims.sh's own readers do.
            until, state = cl.parse_lease(shell_until, NOW_S)
            check(state == want, "case %s (shell emitted %r) => the reader said %s, expected %s"
                  % (label, shell_until, state, want))
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


# ── CLI helper (used by L2) ──────────────────────────────────────────────
def _cli_rc(args):
    proc = subprocess.run([sys.executable, MODULE_PATH, *args],
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                          env=dict(os.environ, CLAIM_HOST=HOST))
    return proc.returncode


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
        '            claims.append(_row(ref, owner, raw_until, ns, host, now, commit))',
        '            _unreachable = _row(ref, owner, raw_until, ns, host, now, commit)',
        "a metadata failure DROPS the claim, so presence stops refuting freedom",
    ),
    Mutation(
        "L5", "reader",
        '    sibs = tuple(sorted(c.key for c in claims if c.pr == pr and c.key not in\n'
        '                        {t.key for t in targets}))',
        '    sibs = ()',
        "the PR's other heads stop being disclosed, so an absent key reads as a free PR",
    ),
    Mutation(
        "L6", "reader",
        '    except OSError as exc:\n'
        '        return liveness.ClaimRead(readable=False, present=False, claims=(), source=source,\n'
        '                                  detail="snapshot unreadable: %s" % sanitize(exc))\n'
        '    age = now - int(st.st_mtime)',
        '    except OSError as exc:\n'
        '        return liveness.ClaimRead(readable=True, present=False, claims=(), source=source,\n'
        '                                  detail="snapshot unreadable: %s" % sanitize(exc))\n'
        '    age = now - int(st.st_mtime)',
        "a MISSING snapshot reads as a successful empty read — absence inferred as freedom",
    ),
    Mutation(
        "L7", "reader",
        '    if age > float(max_age_s):',
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
        "L11", "reader",
        '    kw.setdefault("candidates", [])',
        '    kw.setdefault("candidates", [])\n'
        '    kw["_verdict"] = liveness.Verdict("dead", "reader-decided")',
        "the reader starts constructing a verdict of its own (a second opinion, #1178)",
    ),
    Mutation(
        "L12", "reader",
        '    rc, out, err, failure = _git(["ls-remote", url, "%s/*" % ns], timeout)',
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
        "L14", "reader",
        '    if remote != "origin":\n        return remote',
        '    return "origin"',
        "`origin` is never resolved, so the read lands in the CWD's repo (a wrong-target read)",
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
        '        targets = [c for c in claims if c.sha12.lower() == want]',
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
        '            pre = [c for c in claims if c.sha12.lower().startswith(want)]\n'
        '            if len(pre) > len(targets):\n'
        '                targets = pre',
        '        if not targets and len(want) < 12:\n'
        '            targets = [c for c in claims if c.sha12.lower().startswith(want)]',
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
        red = proc.returncode != 0
        print("── %s mutation → %s ───────────────────────────────────────" % (mut.test_name, mut.why))
        for line in body.splitlines():
            print("   | %s" % line)
        if red:
            print("   ✅ RED (the paired test caught the defect, rc=%d)\n" % proc.returncode)
        else:
            bad += 1
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
