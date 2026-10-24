#!/usr/bin/env python3
"""tools/fleet/claim_lanes.py — read the fleet's REF-CLAIM registry (#1777).

WHY THIS EXISTS
---------------
Every lane population ``tools/fleet/`` could build required a **transcript**: the
cmux hook store and the session JSONL. An orchestrator lane runs
``pi -p --no-session`` (``lane.sh`` / ``fix-one.sh`` / ``merge-one.sh``), so it
writes no transcript and has no store record — it is in **no** population the
fleet reports on. Measured 2026-10-15: the live ``fix-<pr>`` lane was absent from
``lane_liveness.py``'s 22 lanes, and a controller reading
``grep -l <branch> ~/.pi/agent/sessions/*/*.jsonl`` concluded CLEAN while a live
fixer was committing to the branch. The defect class is an
**undeclared-coverage inference**: the surface never declared the read set it
could not see.

The durable, holder-authored record that DOES name such a lane already exists and
was already being written: the **ref-claim**. ``scripts/orchestrator-harness/claims.sh``
pushes ``refs/claims/<pr>-<sha12>`` — a root commit whose message carries
``owner=<host>:<pid>`` and ``lease_until=<digits>`` — so the claim is atomic,
cross-box, and survives the process that made it. This module is the READER of
that registry, and it is the in-tree production caller of the claim evidence:
``liveness.ClaimRead`` in, ``liveness.Evidence`` out via ``to_evidence()``, with
the CLI rendering ``liveness.evaluate(ev)``.

THIS MODULE NEVER DECIDES A STATE.
---------------------------------
It is acquisition only. The one verdict function is ``liveness.evaluate`` (#1178);
a second opinion here would re-create the "two contracts for one safety rule"
defect that rule exists to remove. Consequently this file exports no ``STATES``,
no state names and no ``evaluate`` (pinned by L11) — every claim verdict is an
ABSTENTION whose reason comes from ``liveness.CLAIM_REASONS``.

Also: **``ref-claim`` is not "claim"**. The fleet's other shipped sense is the
*comment-claim* — a GitHub issue comment a lane takes ownership with, read by the
product repo's pre-flight (``collision_preflight.py``'s ``claim-ownership-v1``).
This module reads the ``refs/claims/`` sense only. See
``docs/ops/fleet-liveness.md`` §7.

TWO DRIVERS, ONE CONTRACT
-------------------------
The normalized record is the same three fields ``claims.sh``'s ``claim_snapshot``
already writes — ``<ref>\\t<owner>\\t<lease_until>``:

* **PULL** — ``git ls-remote <remote> "<ns>/*"`` is the **authority on presence**.
  rc≠0 ⇒ ``readable=False`` and the cause is named; **never** "no claim visible".
  rc=0 with zero refs ⇒ ``readable=True, present=False``. Otherwise each claim's
  root commit is fetched into an **isolated temporary bare repo** and read with
  ``cat-file``. A metadata failure keeps ``present=True`` with ``owner="?"`` —
  presence alone refutes freedom.
* **FILE** (``--snapshot``) — a caller-stated ``--max-age-s`` is REQUIRED (no
  invented bound). Missing, stale, or shape-drifted ⇒ ``readable=False``.

Grammar and the lease polarity are declared once, here, and cited to the shipped
call sites rather than to one of them: ``owner=<host>:<pid>``,
``lease_until=<digits>``, and ``lease_state ∈ {live, expired, unknown}`` where
**absent / ``0`` / non-digit / more than 18 digits ⇒ unknown, and unknown is NOT
expired** — ``claims.sh``'s ``claim_acquire`` and ``claim_prune`` and
``orch-loop.sh``'s ``claim_live`` all treat that input class as LIVE, and a
tighter reading here would be the very two-readers-disagree defect those sites
document.

**The namespace carries THREE key shapes** (`claims.sh` mints all three into
``CLAIM_NS``), and they are matched explicitly (``parse_key``): the HEAD key
``<pr>-<sha12>`` (``claim_key``), the ISSUE key ``issue-<N>``
(``claim_issue_key``), and the LANDING key ``pr-<N>`` (``claim_pr_key``, #1952,
minted by ``claim_pr_ref`` for "this PR is being landed"). Only the HEAD key is
HEAD-scoped: an issue key and a landing key are reported (presence is presence)
but never matched by ``--sha``, never returned for ``--pr``, and never disclosed
as a PR's sibling — and the read's ``detail`` names the exclusion. They are NOT
both ``foreign``: ``kind`` is ``issue`` for ``issue-<N>`` and ``foreign`` for
``pr-<N>``; what they share is being NOT-HEAD-scoped. So a live LANDING claim
reads ``no-claim-visible`` for its head: fail-closed, and the read-level
``detail`` names the excluded key (the verdict-level reason does not), which is
why the shape is enumerated here. Any other
shape is ``foreign`` rather than an invented ``pr``/``sha12`` pair.

FAIL-CLOSED, STRUCTURALLY
-------------------------
An unreadable read is a DIFFERENT reason from an empty one; an absent key is
never "free"; a foreign owner's pid is never probed; the process table is never
used to build a population (#1178). Nothing here kills, signals, or escalates.

Exit codes: ``0`` a claim IS VISIBLE for the queried head (do not treat it as free —
this is the fail-closed direction) · ``3`` nothing was established (unreadable, or no
claim visible for this head — never read it as freedom) · ``2`` usage/env.

ONE TARGET, NEVER THE CWD
-------------------------
The remote is always caller-stated (``--repo``'s ``origin`` or ``--remote-url``), and
it is made ABSOLUTE before use: a relative ref would otherwise be resolved against the
caller's cwd by ``ls-remote`` and against the temp bare repo by ``fetch`` — one
argument, two reads (measured with ``origin=../origin.git``). Durations
(``--max-age-s``, ``--timeout``) are validated finite and positive at the door, because
a non-finite bound compares False forever and would silently accept a stale snapshot.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from typing import List, Optional, Sequence, Tuple

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

try:  # the farm promise: claim_lanes.py and liveness.py land side by side.
    import liveness  # noqa: E402
except ImportError as _exc:  # pragma: no cover - env dependent
    sys.stderr.write(
        "claim-lanes: FATAL: cannot import the liveness classifier next to this "
        "reader (%s). The pi-bootstrap farm must copy liveness.py and "
        "claim_lanes.py together, to ~/.pi/agent/scripts/fleet/.\n" % _exc
    )
    raise SystemExit(2)

__all__ = [
    "ADVISORY",
    "READER_LIMITS",
    "LEASE_MAX_DIGITS",
    "DEFAULT_NS",
    "UsageError",
    "parse_owner",
    "parse_lease",
    "parse_key",
    "read_pull",
    "read_snapshot",
    "read_registry",
    "to_evidence",
    "sanitize",
    "short_host",
    "render_text",
    "render_json",
    "main",
]

# The namespace ``claims.sh`` defaults to (``CLAIM_NS``). Read from the same env
# name so a test that isolates the namespace isolates the Python reader too.
DEFAULT_NS = "refs/claims"

# ⛔ 18 DIGITS, NOT 9 (``claims.sh``'s own bound). ``lease_until`` is an epoch
# SECOND — 10 digits today — so a 9-digit bound would call every legitimate lease
# unparseable and treat it as live forever. 2**63-1 is 19 digits, so 18 is the
# precise magnitude guard, and rejecting 19+ is the CONSERVATIVE direction.
LEASE_MAX_DIGITS = 18

DEFAULT_TIMEOUT_S = 20.0

# Appended to BOTH renderings. This sentence is the fix: the incident read an
# absence as freedom, and the read now says so out loud.
ADVISORY = (
    "the claim registry does not decide freedom; every claim verdict is an "
    "abstention (#1777)"
)

# What this reader CANNOT see, declared. The plan's §2.4 deferrals, in the
# reader's own words — a lane that is invisible here is invisible because of one
# of these, never because the registry said it was free.
READER_LIMITS = (
    "HEAD-scoped key: `refs/claims/<pr>-<sha12>` is keyed on the head sha, and a "
    "ref is DELETED on release and PRUNED on expiry — an absent key is not a free PR",
    "three key shapes share this namespace: `claims.sh` also mints `refs/claims/issue-<N>` "
    "(claim_issue_key) and `refs/claims/pr-<N>` (claim_pr_key, the landing key). Those are "
    "ISSUE/LANDING claims, not HEAD claims: `kind` is `issue` / `foreign` respectively, and "
    "neither matches --sha nor is disclosed as a PR's sibling (both stay visible)",
    "remote-only: only claims pushed to the target remote are visible; a lane that "
    "has not yet claimed, or whose claim was deleted, is invisible",
    "local harness state NOT read: `~/orchestrator/state/*` and the tmux `lane-*` / "
    "`fix-<pr>` sessions are a genuine on-box population with an unversioned layout "
    "(#1552) — a local-only lane is invisible here",
    "no branch resolution: a claim names its owner box, not a branch (sha12 -> branch "
    "is deliberately not derived)",
)

_OWNER_RE = re.compile(r"^(?P<host>[A-Za-z0-9._-]{1,128}):(?P<pid>[0-9]{1,18})$")
_LEASE_RE = re.compile(r"^[0-9]{1,%d}$" % LEASE_MAX_DIGITS)
# ── THE KEY GRAMMAR: THREE SHAPES, ONE NAMESPACE (matched, never guessed) ──────
# `claims.sh` mints THREE keys into the SAME namespace: `claim_key`'s HEAD key
# `<pr>-<sha12>`, `claim_issue_key`'s ISSUE key `issue-<N>`, and `claim_pr_key`'s
# LANDING key `pr-<N>` (#1952). Only the HEAD key is HEAD-scoped. Splitting
# every ref on the first `-` therefore parses `issue-1850` as pr="issue",
# sha12="1850" — and then (a) a short `--sha 1850` head-matches it, so the CLI exits
# 0 ("a claim IS VISIBLE for the queried head") for a head nobody holds, and
# (b) `--json` publishes `pr="issue", sha12="1850"`, two values that are neither.
# The shape is matched EXPLICITLY here; a key of neither shape is `foreign`, which
# is declared rather than guessed into a pr/sha12 pair.
_KEY_HEAD_RE = re.compile(r"^(?P<pr>[0-9]+)-(?P<sha12>[0-9A-Za-z]+)$")
_KEY_ISSUE_RE = re.compile(r"^issue-(?P<issue>[0-9]+)$", re.IGNORECASE)
# A remote reference that is already ONE target, mirrored on git's own rule: a scheme URL
# (`https://`, `file://`, `ssh://`), an absolute path, or an scp-like `host:path` — with or
# WITHOUT a `user@` — where the colon comes before any slash. Anything else (no colon, so
# `../origin.git` / `relative.git`) is a filesystem path and must be resolved against a repo.
_ABSOLUTE_REMOTE_RE = re.compile(
    r"^(?:[A-Za-z][A-Za-z0-9+.\-]*:/"       # `file:/path` — a scheme with one slash
    r"|[A-Za-z][A-Za-z0-9+.\-]*://"         # `https://…`, `ssh://…`
    r"|[^/@\s]+@[^/@\s:]+:"                 # `user@host:path`
    r"|[^/@\s]+:"                           # `host:path` — git's own scp test (colon before any `/`)
    r"|/)")                                  # an absolute filesystem path
# A URL embedded in FREE TEXT — git echoes the URL it failed on (`unable to access
# 'https://…'`), and its own anonymizer leaves a password whose tail holds `@`
# intact. The quoted/space-bounded `rest` captures the whole URL, not the prose.
_TEXT_URL_RE = re.compile(r"(?P<scheme>[A-Za-z][A-Za-z0-9+.\-]*://)(?P<rest>[^\s'\"]+)")


class UsageError(Exception):
    """A caller mistake: exit 2, never a verdict."""


# ── hygiene ─────────────────────────────────────────────────────────────
def sanitize(text: str, limit: int = 300) -> str:
    """Neutralise render-hostile input.

    ``owner`` is attacker-influencable — any box able to push to the repo mints a
    claim with an arbitrary owner string — and the output is printed and may be
    pasted into an issue. Same rationale as ``lane_liveness._md_cell`` (#1272):
    a newline forges a line, a ``|`` adds a markdown column, a backtick closes a
    code span. Control characters are dropped.
    """
    out = str(text or "")
    out = out.replace("|", "\\|").replace("`", "'")
    out = out.replace("\r", " ").replace("\n", " ")
    out = "".join(ch if ch.isprintable() else " " for ch in out)
    if len(out) > limit:
        out = out[: limit - 1] + "…"
    return out


def short_host(name: Optional[str] = None) -> str:
    """The short hostname, matching ``claims.sh``'s ``hostname -s``.

    ⛔ THE SEAM IS THE WRITER'S SEAM. The registry is stamped by
    ``claims.sh``'s ``claim_host()``, which reads **``CLAIM_OWNER_HOST``** (the
    env var a cell exports to announce itself, #2094). The reader therefore
    reads that same name: a reader honouring a different variable would compare
    this box's claims against a host the writer never stamped, and scope — the
    one field these two programs share — would silently disagree. ``CLAIM_HOST``
    is kept as an alias so a probe written against the earlier name still works.

    Scope is a HOST comparison, and proving "foreign is never probed" needs two
    names on one box, which is what makes a test seam necessary at all.

    ⚠️ Known residual: ``claims.sh`` also remembers FORMER host names
    (``$CLAIM_STATE_DIR/claim-hosts``) so a renamed box's own claims stay local;
    this reader compares only the current name, so that earlier-name claim is
    scoped ``foreign``. The label that follows depends on the LEASE, because
    scope is only one rung of the cascade (measured, not assumed): a **live** or
    **unknown** lease still reads ``claim-held`` (the held rung fires first), and
    only an **expired** one falls through to ``holder-on-foreign-box``.
    Consequence is label-only — every claim verdict is an abstention — and it is
    declared here rather than fixed silently.
    """
    env = os.environ.get("CLAIM_OWNER_HOST") or os.environ.get("CLAIM_HOST")
    if env:
        return env.strip()
    return (name if name is not None else socket.gethostname()).split(".")[0]


def _redact_text(text: str) -> str:
    """Strip userinfo and query strings from every URL EMBEDDED in free text.

    git echoes the URL it failed on (``unable to access 'https://…'``), and its own
    anonymizer leaves a password whose tail holds ``@`` intact — measured: the
    rendered ``detail`` carried ``https://ssw0rdLEAK@…`` and a raw
    ``?access_token=…``. Since ``detail`` can be pasted into an issue, the same
    redaction the ``source`` gets is applied to text before it is rendered.
    """
    def repl(m):
        rest = re.split(r"[?#]", m.group("rest"), maxsplit=1)[0]
        authority, slash, path = rest.partition("/")
        if "@" in authority:
            authority = authority[authority.rfind("@") + 1:]
        return m.group("scheme") + authority + slash + path
    return _TEXT_URL_RE.sub(repl, str(text or ""))


def _redact_url(url: str) -> str:
    """Never echo credentials: userinfo goes WHOLE, and so does any query string.

    ⛔ Two shapes a first-``@`` userinfo pattern misses, both measured (#1777 review):
    a password whose tail contains ``@`` (``https://user:pa@ss@host`` — a regex
    stopping at the first ``@`` redacts only ``pa@`` and leaves ``ss@host``), and a
    token in the QUERY string (``https://host/r.git?access_token=…``), which no
    userinfo pattern touches. The rendered ``source``/``detail`` may be pasted into
    an issue, so both are removed.

    Display only: git still receives the untouched url.
    """
    raw = str(url or "")
    if not raw:
        return ""
    if "://" in raw:
        return sanitize(_redact_text(raw))
    # scp-like `[user@]host:path` — userinfo precedes the LAST `@`, and only when a
    # colon follows it (git's own scp test).
    head, slash, tail = raw.partition("/")
    if "@" in head and ":" in head.rsplit("@", 1)[-1]:
        raw = head[head.rfind("@") + 1:] + slash + tail
    return sanitize(raw)


def _bounded_seconds(value, flag: str) -> float:
    """A duration at the DOOR: finite, and positive.

    ⛔ Fail-closed, because the value IS the guard. ``argparse``'s ``type=float``
    accepts ``nan``/``inf``, and every comparison against a non-finite bound is
    False — so an unvalidated ``--max-age-s nan`` silently accepted a 10-day-old
    snapshot as FRESH (measured: rc=0 where the honest answer is the staleness
    abstention), and ``--timeout nan`` escaped ``_git`` as a ``ValueError``
    traceback instead of the declared exit 2. Validating the number once, here,
    covers every caller that can reach the guard.
    """
    try:
        num = float(value)
    except (TypeError, ValueError):
        raise UsageError("%s must be a number (got %r)" % (flag, value))
    if not math.isfinite(num):
        raise UsageError("%s must be a finite number (got %r)" % (flag, value))
    if num <= 0:
        raise UsageError("%s must be positive (got %r)" % (flag, value))
    return num


def _one_target(url: str, repo: Optional[str]) -> str:
    """Make a remote reference ABSOLUTE, so every later git call names ONE target.

    ⛔ A relative ref is not a label, it is a lookup two processes can resolve
    differently. Measured with ``origin=../origin.git`` (an ordinary sibling
    clone): the SAME ``--repo`` read ``claims-unreadable`` from one cwd and
    ``fetch rc=128`` — the URL resolved inside the temp bare repo — from another,
    i.e. the reader answered a different question per directory, which is exactly
    what the cwd ban exists to prevent. Resolving once against the repo the ref
    came from removes the difference; with no repo to resolve against there is no
    honest answer to give, so a relative ref is refused rather than guessed.

    A scheme URL (``https://``, ``file://``), an absolute path, and an scp-like
    ``host:path`` (with or without a ``user@``) are already one target and pass
    through untouched — the scp form matters because a bare ``host:path`` has no
    scheme AND no leading slash, and git resolves that form verbatim.
    """
    s = (url or "").strip()
    if not s:
        raise UsageError("empty remote reference")
    if s.startswith("~"):
        # git expands `~/x.git` against HOME, so it is already one target — but it is
        # NOT self-evident to a reader of the regex, and treating it as a path would
        # rewrite it under the repo. (Measured by the verify gate: pre-fix this form
        # errored where git resolved it.)
        return os.path.expanduser(s)
    if _ABSOLUTE_REMOTE_RE.match(s):
        return s
    if not repo:
        raise UsageError(
            "a relative remote (%r) needs a --repo to resolve against — the current "
            "directory is never used implicitly" % sanitize(s, 120))
    return os.path.abspath(os.path.join(repo, s))


# ── grammar (one place, cited to the shipped call sites) ────────────────
def parse_owner(owner: str, host: str) -> Tuple[str, Optional[int], str]:
    """``owner=<host>:<pid>`` -> ``(owner_host, owner_pid, scope)``.

    ``scope`` is ``local`` (the owner host IS this host), ``foreign`` (a named
    host that is not), or ``unknown`` (the owner string is unusable). A local pid
    is still never probed by this reader — see ``liveness.claim_verdict``.
    """
    m = _OWNER_RE.match((owner or "").strip())
    if not m:
        return "", None, "unknown"
    try:
        pid = int(m.group("pid"))
    except ValueError:  # pragma: no cover - the regex bounds the digits
        return m.group("host"), None, "unknown"
    oh = m.group("host")
    return oh, pid, ("local" if oh == (host or "") else "foreign")


def parse_lease(raw: str, now: int) -> Tuple[Optional[int], str]:
    """``lease_until`` -> ``(epoch_seconds, state)``, state ∈ live/expired/unknown.

    Absent / ``0`` / non-digit / >18 digits ⇒ ``(None, "unknown")``, and
    ``unknown`` is deliberately NOT expired: ``claims.sh``'s ``claim_acquire`` and
    ``claim_prune`` and ``orch-loop.sh``'s ``claim_live``
    all read that class as LIVE, so a stricter reading here would re-create the
    two-readers-disagree defect those comments document.
    """
    s = (raw or "").strip()
    if s == "" or s == "0":
        return None, "unknown"
    if not _LEASE_RE.match(s):
        return None, "unknown"
    try:
        until = int(s)
    except ValueError:  # pragma: no cover - the regex bounds the digits
        return None, "unknown"
    return until, ("live" if now <= until else "expired")


# ── the git boundary (argv, never a shell; always a timeout) ────────────
def _git(args: Sequence[str], timeout: float) -> Tuple[int, str, str, str]:
    """Run git. -> ``(rc, stdout, stderr, failure)``; ``failure`` names a non-rc cause."""
    env = dict(os.environ)
    env["GIT_TERMINAL_PROMPT"] = "0"  # never block on a credential prompt
    env.pop("GIT_ASKPASS", None)
    try:
        proc = subprocess.run(
            ["git", *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, timeout=timeout, env=env,
        )
    except FileNotFoundError:
        return 127, "", "", "git-not-found"
    except subprocess.TimeoutExpired:
        return 124, "", "", "timeout-after-%gs" % timeout
    except OSError as exc:  # pragma: no cover - env dependent
        return 126, "", "", "exec-error: %s" % exc
    return proc.returncode, proc.stdout or "", proc.stderr or "", ""


def _remote_arg(repo: Optional[str], remote_url: Optional[str]) -> str:
    """The remote to read. An explicit ``--remote-url`` wins; else ``--repo``'s origin.

    The cwd is NEVER an implicit target: the controller runs from launchd with
    cwd=``$HOME``, where git fails and `claims.sh`'s snapshot "silently comes back
    empty" — which is exactly how "snapshot lines=0 while origin had 3 live claims"
    happened.
    """
    if remote_url:
        return remote_url
    if repo:
        return "origin"
    raise UsageError(
        "no target: pass --repo PATH (its `origin` is read) or --remote-url URL, "
        "or set CLAIM_REPO. The current directory is never used implicitly."
    )


def _resolve_remote(remote: str, repo: Optional[str], timeout: float) -> str:
    """Resolve ``origin`` to an ABSOLUTE url, so every later git call names ONE target.

    ⛔ Load-bearing twice over. (1) The temp bare repo has no remotes, so a literal
    ``origin`` would be resolved inside it and fail (measured: `fetch rc=128 ... and
    the repository exists`). (2) Resolving here also removes any chance that a later
    call silently reads the CWD's repo — and ``_one_target`` extends that to a
    RELATIVE url, which two git processes resolve against two different directories.
    """
    resolved = remote
    if remote == "origin":
        if not repo:
            # `--remote-url origin` with no --repo is a caller mistake, not a crash:
            # there is no checkout whose `origin` could be resolved. Report the
            # declared usage exit (2), never a TypeError traceback (exit 1).
            raise UsageError(
                "`origin` needs a --repo PATH to resolve against — pass --repo PATH "
                "(its `origin` is read) or a --remote-url URL")
        rc, out, _err, failure = _git(["-C", repo, "remote", "get-url", "origin"], timeout)
        url = out.strip().splitlines()[0].strip() if out.strip() else ""
        if failure or rc != 0 or not url:
            raise UsageError("cannot resolve `origin` in %s (%s) — pass --remote-url URL"
                             % (repo, failure or ("rc=%d" % rc)))
        resolved = url
    return _one_target(resolved, repo)


def _git_error(err: str) -> str:
    """The CAUSE from git's stderr, not its last line (git ends with advice).

    Measured: a fetch failure's last line was `and the repository exists.` — the
    tail of "Please make sure you have the correct access rights and the
    repository exists" — which names no cause at all. The text is redacted too:
    git echoes the URL it failed on (including a credential it did not anonymize).
    """
    clean = [_redact_text(ln.strip()) for ln in (err or "").splitlines() if ln.strip()]
    for ln in clean:
        if ln.startswith("fatal:") or ln.startswith("error:"):
            return sanitize(ln, 200)
    return sanitize(clean[-1] if clean else "", 200)


def read_pull(remote: str, *, repo: Optional[str] = None, ns: str = DEFAULT_NS,
              timeout: float = DEFAULT_TIMEOUT_S, pr: Optional[str] = None,
              sha: Optional[str] = None, host: Optional[str] = None,
              now: Optional[int] = None) -> liveness.ClaimRead:
    """Read the registry from a remote. The authority on PRESENCE is ``ls-remote``."""
    host = short_host() if host is None else host
    now = int(time.time()) if now is None else int(now)
    url = _resolve_remote(remote, repo, timeout)
    source = "pull %s %s" % (_redact_url(url), ns)

    rc, out, err, failure = _git(["ls-remote", url, "%s/*" % ns], timeout)
    if failure or rc != 0:
        # ⛔ NOT an absence. A failed read must never be collapsed into "no claims".
        why = failure or "rc=%d" % rc
        tail = _git_error(err)
        return liveness.ClaimRead(
            readable=False, present=False, claims=(), source=source,
            detail="ls-remote %s%s" % (why, "" if not tail else ": %s" % tail),
        )

    refs: List[Tuple[str, str]] = []
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) != 2:
            parts = line.split()
        if len(parts) != 2:
            continue
        sha_hex, ref = parts[0].strip(), parts[1].strip()
        if ref.startswith(ns + "/") and ref != ns:
            refs.append((sha_hex, ref))

    if not refs:
        return liveness.ClaimRead(readable=True, present=False, claims=(), source=source)

    # One fetch into an ISOLATED temp bare repo — never the caller's ref space, so
    # a hostile or racing registry can neither write nor delete a local ref. The
    # commit message is the payload; ``--depth=1`` keeps it to the root commits.
    claims: List[liveness.Claim] = []
    tmp = tempfile.mkdtemp(prefix="claim-lanes-")
    try:
        irc, _o, ierr, ifail = _git(["-C", tmp, "init", "-q", "--bare"], timeout)
        metadata_ok = not (ifail or irc != 0)
        fetch_detail = ""
        if metadata_ok:
            frc, _fo, ferr, ffail = _git(
                ["-C", tmp, "fetch", "-q", "--no-tags", "--depth=1", url,
                 "+%s/*:refs/claim-lanes/*" % ns], timeout)
            if ffail or frc != 0:
                metadata_ok = False
                fetch_detail = ffail or ("fetch rc=%d" % frc)
                ferr = _git_error(ferr)
                if ferr:
                    fetch_detail += ": %s" % ferr
        else:
            fetch_detail = ifail or ("init rc=%d" % irc)
        for sha_hex, ref in refs:
            owner, raw_until, commit = "?", "0", ""
            committed_at: Optional[int] = None
            if metadata_ok:
                crc, cout, _cerr, cfail = _git(["-C", tmp, "cat-file", "commit", sha_hex], timeout)
                if cfail or crc != 0:
                    # The ref raced between ls-remote and the fetch: read what the
                    # fetch actually landed, else report presence-with-no-metadata.
                    lref = "refs/claim-lanes/" + ref.rsplit("/", 1)[-1]
                    crc, cout, _cerr, cfail = _git(
                        ["-C", tmp, "cat-file", "commit", lref], timeout)
                if cfail or crc != 0:
                    owner, raw_until = "?", "0"
                    if not fetch_detail:
                        fetch_detail = cfail or ("cat-file rc=%d" % crc)
                else:
                    commit = sha_hex
                    owner, raw_until = _owner_and_lease(_commit_body(cout))
                    committed_at = _commit_time(cout)
            claims.append(_row(ref, owner, raw_until, ns, host, now, commit, committed_at))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    detail = "" if not fetch_detail else "claim metadata read failed (%s)" % fetch_detail
    targets, siblings, note = _select(claims, pr, sha)
    if note:
        detail = (detail + " — " if detail else "") + note
    return liveness.ClaimRead(
        readable=True, present=True, claims=tuple(targets), siblings=siblings,
        source=source, detail=detail,
    )


def _commit_body(obj: str) -> str:
    """The commit MESSAGE only — headers stripped, exactly as ``claims.sh`` does.

    ⛔ ``git cat-file commit`` prints the WHOLE object: tree/author/committer/gpgsig
    headers, a blank line, then the message. ``claims.sh``'s ``_lease_of`` strips
    them (``sed -n '/^$/,$p' | tail -n +2``); feeding the raw object to the field
    parser lets a HEADER supply ``owner=``/``lease_until=`` — and headers are minted
    by whoever pushes — so the two readers disagree about one lease (the Python
    reader sees an expired lease where ``claims.sh`` sees an unparseable one).
    """
    _headers, sep, body = (obj or "").partition("\n\n")
    return body.replace("\r", "") if sep else ""


_COMMITTER_TIME_RE = re.compile(r"^committer .*? ([0-9]{1,}) [+-][0-9]{4}[ \t]*$", re.M)


def _commit_time(obj: str) -> Optional[int]:
    """The committer epoch from the HEADER block, or ``None``.

    The header block only (before the first blank line): a message body line that
    happens to read ``committer …`` must never be read as the timestamp. The value
    is pusher-minted, so it is displayed as an age and never decides anything.
    """
    headers, sep, _body = (obj or "").partition("\n\n")
    if not sep:
        return None
    m = _COMMITTER_TIME_RE.search(headers)
    return int(m.group(1)) if m else None


def _owner_and_lease(msg: str) -> Tuple[str, str]:
    """The last ``owner=`` / ``lease_until=`` in a commit MESSAGE (``_lease_of`` parity).

    Mirrors ``claims.sh``'s ``_lease_of``: it reads the message BODY only (feed it
    ``_commit_body``'s output — a header must never supply the payload), the greedy
    leading ``.*`` in its sed means the LAST occurrence of each field wins, and an
    ABSENT field yields ``?`` / ``0`` — an absence is reported as an unparseable
    VALUE, never as "no claim", which is what keeps presence alone refuting freedom.
    """
    o = re.findall(r"owner=([^ \n]*)", msg or "")
    u = re.findall(r"lease_until=([0-9]*)", msg or "")
    return (o[-1] if o else "") or "?", (u[-1] if u else "") or "0"


def parse_key(key: str) -> Tuple[str, str, str, str]:
    """``(kind, pr, sha12, issue)`` for one key — ``head`` | ``issue`` | ``foreign``.

    ⛔ ONLY a ``head`` key is HEAD-scoped. An ``issue`` key names an issue, not a
    head, so it can never answer "is this head held" and must never be matched by a
    ``--sha`` query or published as a PR's sibling; ``foreign`` is a key shape this
    reader does not know, and reporting it as ``pr=<prefix>`` would be an invented
    grammar. ``key`` itself is always preserved on the row, so nothing is lost.
    """
    raw = key or ""
    m = _KEY_ISSUE_RE.match(raw)
    if m:
        return "issue", "", "", m.group("issue")
    m = _KEY_HEAD_RE.match(raw)
    if m:
        return "head", m.group("pr"), m.group("sha12"), ""
    return "foreign", "", "", ""


def _row(ref: str, owner: str, raw_until: str, ns: str, host: str, now: int,
         commit: str = "", committed_at: Optional[int] = None) -> liveness.Claim:
    owner_host, owner_pid, scope = parse_owner(owner, host)
    key = ref.rsplit("/", 1)[-1]
    kind, pr, sha12, issue = parse_key(key)
    until, state = parse_lease(raw_until, now)
    # The claim's AGE rides as non-liveness detail (a snapshot carries no commit, so
    # the age is honestly ABSENT there rather than invented).
    age_s = None if committed_at is None else max(0, now - committed_at)
    return liveness.Claim(
        ref=ref, key=key, pr=pr, sha12=sha12, kind=kind, issue=issue, owner=owner or "?",
        owner_host=owner_host, owner_pid=owner_pid, lease_until=until, lease_state=state,
        scope=scope, commit=commit, age_s=age_s,
    )


def _select(claims: Sequence[liveness.Claim], pr: Optional[str], sha: Optional[str]
            ) -> Tuple[List[liveness.Claim], Tuple[str, ...], str]:
    """Filter to the queried HEAD key and disclose that PR's other HEAD keys.

    Returns ``(claims_for_the_target, sibling_keys, note)``. The key is HEAD-scoped,
    so "absent for this head" is NOT "free": the siblings are returned so the read
    declares that gap rather than dropping it.

    ⛔ THE PR IS BOUND FROM THE MATCH, NEVER FROM THE REF ORDER (verify-gate P1).
    ``git ls-remote`` emits refs sorted lexicographically, so inferring the PR from
    ``claims[0].pr`` lets ANY box that pushed a lower-sorting key
    (``refs/claims/0-…`` — any lower-numbered PR) force every ``--sha``-only read to
    look in the wrong PR: the live holder is then reported as ``no-claim-visible``
    AND the sibling disclosure names the wrong PR. Matching the sha across the whole
    registry first, and binding the PR from what matched, removes the ordering
    dependency entirely. Case is normalised because the key is a sha (hex).

    ⛔ AND A MULTI-PR MATCH IS RETURNED ENTIRELY, NOT INDEXED (verify-gate cycle-2
    P1/P2). When several PRs carry the same head sha — a duplicated head, or a decoy
    minted by anyone who can push — indexing ``targets[0]`` re-introduces the ordering
    dependency (which PR wins follows ``ls-remote`` order), would DROP a live holder
    from ``claims`` (a false absence), and would publish one PR's heads as the
    disclosure while suppressing the other's. So every match is returned and the
    ambiguity is declared in ``note``: no claim is ever hidden, and no sibling list is
    invented where the notion of "this PR's other heads" is undefined.

    The short-sha prefix fallback runs BEFORE the ``--pr`` filter, so a short query
    cannot be consumed by another PR's coincidental prefix match (cycle-2 P1).

    ⛔ ONLY ``kind == "head"`` ROWS ARE MATCHED OR DISCLOSED. ``refs/claims/`` also
    carries ``issue-<N>`` keys (``kind == "issue"``) and ``pr-<N>`` landing keys
    (``kind == "foreign"``) — both minted by ``claims.sh``, neither HEAD-scoped, so
    neither can ever answer "is this head held". They stay VISIBLE
    in a bare read and their exclusion is named in ``note``.
    """
    if not pr and not sha:
        return list(claims), (), ""
    # ⛔ ONLY A HEAD KEY IS HEAD-SCOPED, so only head keys take part in the match and
    # in the sibling disclosure below. An `issue-<N>` ref shares this namespace and
    # used to be parsed as pr="issue"/sha12="<N>", which let a short `--sha <N>`
    # answer "a claim IS VISIBLE for the queried head" for a head nobody holds. The
    # non-head keys are EXCLUDED, not dropped: the exclusion is NAMED in `note`, so a
    # head-scoped absence is never silently narrowed to a head-only registry.
    heads = [c for c in claims if c.kind == "head"]
    other = [c for c in claims if c.kind != "head"]
    excl = ""
    if other:
        excl = ("%d claim key(s) in the namespace are not HEAD-scoped (%s) and cannot "
                "answer for a head" % (len(other), ", ".join(sorted(c.key for c in other))))
    want = (sha or "")[:12].lower()
    note = excl
    if sha:
        targets = [c for c in heads if c.sha12.lower() == want]
        # A sha shorter than 12 chars is a PREFIX, and the prefix set is UNIONED with the
        # exact set rather than used as a fallback: a decoy whose whole sha12 happens to
        # equal the short query would otherwise CONSUME it (the exact set is non-empty,
        # so a fallback never runs) and hide the real head one character longer
        # (verify-gate cycle-2 P1).
        if len(want) < 12:
            pre = [c for c in heads if c.sha12.lower().startswith(want)]
            if len(pre) > len(targets):
                targets = pre
        if pr:
            targets = [c for c in targets if c.pr == pr]
        prs = sorted({c.pr for c in targets})
        if pr:
            pass                        # the caller resolved the ambiguity
        elif len(prs) == 1:
            pr = prs[0]                 # unambiguous: bind from the match
        elif prs:
            amb = ("the queried head sha matched claims under %d PRs (%s) — the registry "
                   "is AMBIGUOUS for this head, so every match is returned rather than "
                   "picking one by ref order" % (len(prs), ", ".join(prs)))
            return targets, (), (excl + " — " + amb if excl else amb)
        else:
            # No PR named and no matching head anywhere: there is no PR to disclose
            # against, and inventing one would be the P1 defect again.
            return [], (), note
    else:
        targets = [c for c in heads if c.pr == pr]
    sibs = tuple(sorted(c.key for c in heads if c.pr == pr and c.key not in
                        {t.key for t in targets}))
    return targets, sibs, note


def read_snapshot(path: str, *, max_age_s: float, ns: str = DEFAULT_NS,
                  pr: Optional[str] = None, sha: Optional[str] = None,
                  host: Optional[str] = None, now: Optional[int] = None) -> liveness.ClaimRead:
    """Read a ``claim_snapshot`` file. A caller-stated ``max_age_s`` is REQUIRED."""
    host = short_host() if host is None else host
    now = int(time.time()) if now is None else int(now)
    source = "snapshot %s" % sanitize(path)
    if max_age_s is None:
        raise UsageError("--snapshot requires a positive --max-age-s (no invented bound)")
    max_age_s = _bounded_seconds(max_age_s, "--max-age-s")
    try:
        st = os.stat(path)
    except OSError as exc:
        return liveness.ClaimRead(readable=False, present=False, claims=(), source=source,
                                  detail="snapshot unreadable: %s" % sanitize(exc))
    age = now - int(st.st_mtime)
    if age > float(max_age_s):
        return liveness.ClaimRead(
            readable=False, present=False, claims=(), source=source,
            detail="snapshot STALE: age=%ds > max-age-s=%.0fs (an old snapshot is not a "
                   "fresh read)" % (age, float(max_age_s)))
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError as exc:  # pragma: no cover - raced with the stat
        return liveness.ClaimRead(readable=False, present=False, claims=(), source=source,
                                  detail="snapshot unreadable: %s" % sanitize(exc))

    claims: List[liveness.Claim] = []
    for lineno, raw in enumerate(text.splitlines(), 1):
        if not raw.strip():
            continue
        parts = raw.split("\t")
        if len(parts) != 3:
            # Shape drift is an UNREADABLE read, never a partial one: a partially
            # parsed registry would silently drop the claims it mis-read.
            return liveness.ClaimRead(
                readable=False, present=False, claims=(), source=source,
                detail="snapshot SHAPE DRIFT at line %d: expected 3 tab-separated "
                       "fields, got %d" % (lineno, len(parts)))
        ref, owner, raw_until = parts
        claims.append(_row(ref.strip(), owner.strip(), raw_until.strip(), ns, host, now))
    if not claims:
        return liveness.ClaimRead(readable=True, present=False, claims=(), source=source)
    targets, siblings, note = _select(claims, pr, sha)
    return liveness.ClaimRead(readable=True, present=True, claims=tuple(targets),
                              siblings=siblings, source=source, detail=note)


def read_registry(*, repo: Optional[str] = None, remote_url: Optional[str] = None,
                  snapshot: Optional[str] = None, max_age_s: Optional[float] = None,
                  ns: Optional[str] = None, timeout: float = DEFAULT_TIMEOUT_S,
                  pr: Optional[str] = None, sha: Optional[str] = None,
                  host: Optional[str] = None, now: Optional[int] = None) -> liveness.ClaimRead:
    """Dispatch to the driver the caller asked for (FILE if snapshot, else PULL)."""
    ns = ns or os.environ.get("CLAIM_NS") or DEFAULT_NS
    # Validate the duration ONCE, before any git call or guard consumes it: a
    # non-finite or non-positive value must be a named usage error (exit 2), not a
    # traceback out of subprocess and not a guard that compares False forever.
    timeout = _bounded_seconds(timeout, "--timeout")
    if snapshot:
        return read_snapshot(snapshot, max_age_s=max_age_s, ns=ns, pr=pr, sha=sha,
                             host=host, now=now)
    repo = repo if repo is not None else (os.environ.get("CLAIM_REPO") or None)
    remote = _remote_arg(repo, remote_url)
    return read_pull(remote, repo=repo, ns=ns, timeout=timeout, pr=pr, sha=sha,
                     host=host, now=now)


def to_evidence(cr: liveness.ClaimRead, **kw) -> liveness.Evidence:
    """The bridge: ``ClaimRead`` -> ``Evidence``, with NO candidates.

    ``candidates=[]`` is the point, not an omission: an orchestrator lane writes no
    cmux record by construction, which is exactly why it was invisible. The claim
    axis is consulted only inside ``evaluate``'s empty-candidate branch, so the
    session ladder is untouched. This function decides nothing.
    """
    kw.setdefault("candidates", [])
    return liveness.Evidence(claim_read=cr, **kw)


# ── rendering (the CLI is the in-tree caller of liveness.evaluate) ──────
def render_json(cr: liveness.ClaimRead, verdict: "liveness.Verdict") -> str:
    # The verdict is liveness.evaluate's, never this reader's — but its `detail`
    # carries the attacker-influencable `owner=<commit-message string>`
    # (`liveness._claim_detail`), and `render_text` already sanitizes the same
    # string. Every other untrusted field of this payload is sanitized, so
    # leaving the verdict raw was the one inconsistent path (#1272); sanitize its
    # string fields here, at the render boundary, rather than inside the pure
    # verdict library.
    vd = verdict.to_dict()
    vd["detail"] = sanitize(vd["detail"], 400)          # matches render_text's limit
    vd["witnesses"] = [sanitize(w, 300) for w in vd["witnesses"]]
    return json.dumps({
        "advisory": ADVISORY,
        "source": sanitize(cr.source, 500),
        "readable": cr.readable,
        "present": cr.present,
        # `present` above is about the NAMESPACE (any ref at all). This is the answer to
        # the question a consumer actually asks — "is a claim visible for the target
        # head?" — and it exists so `present=yes claims=0` cannot be read as one fact
        # (verify-gate P3).
        "present_for_target": bool(cr.claims),
        "read_detail": sanitize(cr.detail, 500),
        "siblings": [sanitize(s, 80) for s in cr.siblings],
        "reader_limits": [sanitize(x, 300) for x in READER_LIMITS],
        "claims": [
            {"ref": sanitize(c.ref, 120), "key": sanitize(c.key, 120), "pr": sanitize(c.pr, 20),
             "sha12": sanitize(c.sha12, 20), "kind": c.kind,
             "issue": sanitize(c.issue, 20), "owner": sanitize(c.owner, 120),
             "owner_host": sanitize(c.owner_host, 120), "owner_pid": c.owner_pid,
             "lease_until": c.lease_until, "lease_state": c.lease_state,
             "scope": c.scope, "commit": sanitize(c.commit, 64)}
            for c in cr.claims
        ],
        # The verdict is liveness.evaluate's, never this reader's.
        "verdict": vd,
    }, sort_keys=True, indent=2)


def render_text(cr: liveness.ClaimRead, verdict: "liveness.Verdict") -> str:
    lines: List[str] = []
    lines.append("claim-lanes: %s" % sanitize(cr.source, 500))
    lines.append("ADVISORY: %s" % ADVISORY)
    lines.append("readable=%s present(namespace)=%s claims=%d"
                 % ("yes" if cr.readable else "NO", "yes" if cr.present else "no",
                    len(cr.claims)))
    if cr.present and not cr.claims:
        # `present` is about the NAMESPACE. Said out loud so the header cannot be read as
        # "this PR has a claim" (verify-gate P3).
        lines.append("  ⚠️ the namespace HAS refs but NONE for the queried head — `present` "
                     "describes the namespace, NOT this PR")
    if not cr.readable:
        lines.append("  ⚠️ nothing was established about any holder (%s)"
                     % sanitize(cr.detail, 300))
    elif cr.detail:
        lines.append("  ⚠️ %s" % sanitize(cr.detail, 300))
    lines.append("verdict: %s%s — reason=%s"
                 % (verdict.state, " (ABSTENTION)" if verdict.state == "unknown" else "",
                    verdict.reason))
    if verdict.detail:
        lines.append("  detail: %s" % sanitize(verdict.detail, 400))
    lines.append("  holder_pid: never set for a claim — a ref-claim records no process "
                 "start to fence against")
    if cr.claims:
        lines.append("claims:")
        for c in cr.claims:
            lines.append("  %s  owner=%s  lease=%s  scope=%s%s"
                         % (sanitize(c.ref, 120), sanitize(c.owner, 120),
                            c.lease_state, c.scope,
                            "" if c.kind == "head" else "  kind=%s (NOT head-scoped)" % c.kind))
    if cr.siblings:
        lines.append("other heads of this PR (NOT free — the key is HEAD-scoped): %s"
                     % ", ".join(sanitize(s, 80) for s in cr.siblings))
    lines.append("reader limits (what this read cannot see):")
    for lim in READER_LIMITS:
        lines.append("  - %s" % lim)
    return "\n".join(lines)


# ── CLI ─────────────────────────────────────────────────────────────────
def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    ap = argparse.ArgumentParser(
        prog="claim_lanes.py",
        description="Read the fleet's ref-claim registry (#1777): who holds a PR head, "
                    "with an owner and a lease. NEVER decides freedom — every claim "
                    "verdict is an abstention.",
    )
    ap.add_argument("--repo", default=None,
                    help="a git checkout/remote whose `origin` is read (CLAIM_REPO also "
                         "defaults this). The cwd is never used implicitly.")
    ap.add_argument("--remote-url", default=None,
                    help="read this remote directly instead of --repo's origin")
    ap.add_argument("--snapshot", default=None,
                    help="read a `claim_snapshot` file instead of the remote")
    ap.add_argument("--max-age-s", type=float, default=None,
                    help="REQUIRED with --snapshot: the caller's staleness bound")
    ap.add_argument("--pr", default=None, help="the PR to answer for (discloses sibling heads)")
    ap.add_argument("--sha", default=None, help="the head sha (12 chars used as the key)")
    ap.add_argument("--ns", default=None, help="claim namespace (default: $CLAIM_NS or refs/claims)")
    ap.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_S,
                    help="per-git-call timeout seconds (default %.0f)" % DEFAULT_TIMEOUT_S)
    ap.add_argument("--host", default=None, help="this box's short hostname (test seam)")
    ap.add_argument("--now", type=int, default=None, help="pin the clock (epoch s; tests only)")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    return ap.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    ns = parse_args(argv)
    try:
        cr = read_registry(repo=ns.repo, remote_url=ns.remote_url, snapshot=ns.snapshot,
                           max_age_s=ns.max_age_s, ns=ns.ns, timeout=ns.timeout,
                           pr=ns.pr, sha=ns.sha, host=ns.host, now=ns.now)
    except UsageError as exc:
        sys.stderr.write("claim-lanes: usage: %s\n" % exc)
        return 2
    verdict = liveness.evaluate(to_evidence(cr))
    print(render_json(cr, verdict) if ns.json else render_text(cr, verdict))
    # ⛔ EXIT POLICY (verify-gate P2 — tightened after the divergence from `liveness.py`).
    # NOT "0 = the read worked": a flat readable-absence read is EXACTLY the input the
    # incident misread, so a consumer writing `if claim_lanes.py …; then` would read
    # success as "nobody is on it". And `liveness.py`'s own CLI already returns 3 for
    # every `unknown` verdict, which every claim verdict is. So:
    #   0 = a claim IS VISIBLE for the target head — the positive answer to "is anyone on
    #       this?", and the OPPOSITE of freedom (the fail-CLOSED direction);
    #   3 = NOTHING was established (unreadable, or no claim visible for this head);
    #   2 = usage/env. A consumer must never read 3 as freedom.
    return 0 if (cr.readable and cr.claims) else 3


if __name__ == "__main__":
    sys.exit(main())
