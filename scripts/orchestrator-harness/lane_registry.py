#!/usr/bin/env python3
"""lane_registry.py — the lane STATE primitive: did this lane finish?

    lane_registry.py start | beat | done | fail | list | show

WHY THIS EXISTS (agent-infra#3382, owner steer 2026-11-04)
---------------------------------------------------------
The fleet ran 26 lanes and the orchestrator **could not tell whether any single one had finished**.
Every verdict was an inference over a proxy, and each proxy produced a WRONG answer:

    artifact byte count                     -> "parked, superseded"   (the lane was mid-turn)
    `cmux vm exec` timing out               -> "control plane failed" (the box was saturated)
    an empty `git diff` from a fetch that
      silently never ran                    -> "48 PRs already absorbed"  (0 were)
    a truncated list page                   -> "P0 collapsed 13 -> 3"     (it was 13)
    a merge count keyed on OPEN labels      -> "0 P0 landed"              (invisible by construction)

So the FIRST tool is not a convenience wrapper; it is the state primitive. An orchestration MCP whose
tools cannot answer "did it finish" is a typed façade over blindness.

THE CONTRACT — FOUR STATES, NO FIFTH
------------------------------------
    RUNNING   a record exists, and its lease is open
    DONE      a TERMINAL record exists whose artifacts are named
    FAILED    a TERMINAL record exists whose reason is stated
    EXPIRED   no heartbeat past the stated budget, and no terminal record

`EXPIRED` is **DERIVED, NEVER WRITTEN**. That is the whole point: a state the writer could forget to
record is the proxy problem again, one layer down. Any reader can derive it from two numbers in the
record (`lease_until` and `budget_s`), so a box that dies mid-lane needs no actor to notice — the lease
simply runs out. `start`/`beat`/`done`/`fail` REFUSE `expired` as an argument (exit 2), which is what
makes "derived" structural rather than a convention.

⚠️ `NOT-FOUND` IS A LOOKUP OUTCOME, NOT A STATE. A lane id with no record is `NOT-FOUND` (exit 4);
an unreadable registry is `UNMEASURED(<cmd> + <error>)` (exit 3). Neither may ever be reported as one
of the four states — "unknown ≠ zero" is #3382's invariant 1, and collapsing "I could not read" into
"nothing is running" is exactly the FALSE-CLEAN class the fleet keeps paying for.

WHY GIT REFS, AND WHY NOT A FILE (or a database, or the server's memory)
-----------------------------------------------------------------------
`refs/lanes/<lane-id>`, one small JSON per lane, force-updated by its own writer. Four reasons, each of
which rules out the obvious alternative:

* **It survives a dead box.** The lane runs on a cloud cell; the reader runs on the hub. A file on the
  cell is unreadable exactly when the cell is the thing that died — and `cmux vm exec` timing out is one
  of the five proxies above. A ref is readable from the repo by anything with a clone.
* **No exec channel.** Reading a cell's file needs `cmux vm exec`; reading a ref needs `git ls-remote`.
  The transport is the one this fleet already trusts for `refs/claims/*` (`claims.sh`: "the boxes already
  share exactly one durable store: the repository").
* **It cannot fire CI.** `refs/lanes/*` is outside the branch namespace and matches no `on: push:`
  trigger — verified empirically for `refs/claims/*` on 2026-10-14 in both repos (claims.sh §"WHY
  `refs/claims/*` AND NOT `refs/heads/claim/*`"), and this namespace has the same shape.
* **Persistence is not the server's job.** The MCP server is a reader; a state store that lived in its
  process would die with the process — the failure the long-running-MCP literature names as the reason
  to "persist job state outside the server process" (§8 references in `docs/ops/lane-registry.md`).

⛔ AND WHY NOT THE THING THAT ALREADY EXISTS: `refs/claims/<pr>-<sha12>` answers **"who holds this
head?"**, and #1777 states precisely why it cannot answer **"is this lane finished?"** — it is
HEAD-keyed (a lane that lands a second commit mints a second key), it is DELETED ON RELEASE and PRUNED
ON EXPIRY (`claims.sh`), it is RELEASED MID-LANE between `fix-one.sh` and `merge-one.sh` by design, and
it is ABSENT when `HEAD` is unresolvable. A durable, lane-keyed, never-deleted record is a different
object, and #1777's plan says so in as many words ("it does **not** supply the durable 'lane registry'").
This module is that registry. It does not read or write `refs/claims/*`, and it emits no liveness
verdict — `tools/fleet/liveness.py` remains the ONE verdict function over reader-side evidence
(#1178/#3382 §1.2). A registry record is HOLDER-AUTHORED EVIDENCE, which is the axis liveness.py has no
access to at all.

THE EXIT-CODE + LEASE MODEL IS NOT INVENTED HERE
------------------------------------------------
It is how CI systems already represent completion, and the comparables are unanimous on both halves:

* **A terminal condition is an explicit record, not an inference.** Kubernetes `Job` carries
  `.status.conditions` with `Complete=True` / `Failed=True`, and a Job is finished when *either*
  terminal condition is present; `completionTime` is set on success only. `kubernetes/kubernetes#117303`
  records why the intermediate counters (`.status.succeeded`) must NOT be read as definitive completion.
  → `done`/`fail` write a terminal condition; `RUNNING` is never terminal.
* **Liveness is a lease that is RENEWED, and expiry is the absence of renewal.** kubelet renews a Lease
  every ~10 s and the node goes unreachable at ~40 s; the docs are explicit that this "makes lease
  renewal/expiry an explicit liveness signal rather than a filesystem timestamp". A file's mtime is not
  an act — anything that touches the file resets it, and nothing that dies can stop touching it.
  → `budget_s` + `heartbeat_at` is the lease; `EXPIRED` is what its expiry means.
* **Return a handle, poll a status tool, enumerate the terminal states explicitly.** The long-running-MCP
  guidance converges on `running | completed | failed | not_found` with `not_found` as a lookup outcome
  rather than a state — which is exactly the four-state-plus-abstention split above.

REUSING, NOT RE-DERIVING
------------------------
#1759 (one source, one version stamp) → one writer (`run_agent`), one store (the ref), one schema.
#1761 (one owner per controller) → `lane_id` embeds host + start instant, so two boxes can never mint
the same id and a force-update can never clobber a peer's record.
#943 (a stalled turn is indistinguishable from progress) → this module never claims a lane is *working*;
it reports only whether a RECORD exists and whether its lease is open. Quiet is not a verdict here either.
#3016 (deployed drift) → every read names its `source`, and `--json` carries `readable` + `detail`, so a
stale or absent registry is DETECTABLE instead of silent.
#3382 Phase 1 (`docs/ops/orchestrator-mcp-inventory.md`) → this is the state primitive tools 1–3 rest on;
it is a WRAPPER-shaped addition in the sense that it wraps `git` and nothing else, and it is recorded in
that inventory's follow-up rather than duplicating any of its 14 rows.

EXIT CODES
----------
    0  OK — the verb did what it says
    2  USAGE — bad or contradictory arguments (including `--state expired`, which cannot be written)
    3  UNMEASURED — the registry could not be read. NOT an empty registry.
    4  NOT-FOUND — this lane id has no record. NOT a state.
    5  REFUSED — a contract violation: `done` with no artifact, `fail` with no reason, a second
                  terminal transition, or a write against an unparsable existing record
    6  LOCAL-ONLY — the record was written locally and the ref push failed. The lane is recorded on
                  THIS box and is invisible to peers; the caller must not read this as success.

PORTABILITY (mac / Linux cell / CELL_HOME cell)
-----------------------------------------------
stdlib only, `python3` only, no `timeout(1)`, no `bc`, no `/proc`. `git` is the sole external binary and
every call is bounded by `--timeout` (default 20 s). Paths resolve through `CELL_HOME` then `HOME`.
"""

from __future__ import annotations

import argparse
import errno
import json
import os
import re
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple

SCHEMA = 1
NS = "refs/lanes"
REF_GLOB = NS + "/*"
PAYLOAD_PATH = "lane.json"

STATES = ("RUNNING", "DONE", "FAILED", "EXPIRED")
TERMINAL = ("DONE", "FAILED")
WRITABLE = ("RUNNING", "DONE", "FAILED")   # `EXPIRED` is DERIVED — see the module docstring

# ⛔ THE LANE ID IS BOTH A FILENAME AND A REF COMPONENT, so it is screened by ONE pattern in three
# places: minting (`new_lane_id`), reading (`_record_problem`) and writing (`_write_local`). It must
# start with an alnum (a leading `.` hides the file and is not a legal ref component), contain no `/`,
# `..`, `~`, `^`, `:`, `?`, `*`, `[`, `\\`, space or NUL, and stay short enough for a path component.
# ⛔ AND IT MUST BE A LEGAL REF COMPONENT, NOT JUST A LEGAL FILENAME. The old pattern accepted `a..b`,
# `a.` and `a.lock` — all of which GIT REFUSES in a ref name (`invalid refspec`, rc 6, measured). The id
# was validated, the local witness written, the handle PRINTED, and only then did the push fail, so the
# lane reads `LOCAL-ONLY`/`EXPIRED` to every peer forever while `start`'s own warning says peers
# "cannot see this lane until it is" pushed. `?`-free by construction: git's rules for a ref component
# are `..`, a trailing `.`, `.lock` and the control characters, and this pattern is the one place they
# belong. See T17b for the shapes.
# ⛔ `\Z`, NOT `$`. Python's `$` also matches IMMEDIATELY BEFORE A TRAILING NEWLINE, so `"good-1\n"`
# passed `.match()` while `git check-ref-format` refused the ref — the same LOCAL-ONLY-forever handle
# this pattern exists to prevent, reachable with one byte. `\Z` is the absolute end of the string.
LANE_ID_RE = re.compile(r"^(?!.*\.\.)(?!.*\.lock\Z)[A-Za-z0-9](?:[A-Za-z0-9._-]{0,158}[A-Za-z0-9_-])?\Z")

DEFAULT_BUDGET_S = 7200      # == spawn-gate.sh's LANE_BACKSTOP_S (the lane's absolute backstop)
DEFAULT_BEAT_S = 60
DEFAULT_TIMEOUT_S = 20.0
MAX_BUDGET_S = 86_400        # a budget above a day is a typo, not a plan; clamp LOUDLY

# Exit codes — named, because a caller reads the number and the number is the contract.
OK = 0
USAGE = 2
UNMEASURED = 3
NOT_FOUND = 4
REFUSED = 5
LOCAL_ONLY = 6


# ── paths ────────────────────────────────────────────────────────────────────────────────────────

def _home() -> str:
    """The box's durable state root: `CELL_HOME` wins over `HOME` (cells set only the former)."""
    return os.environ.get("CELL_HOME") or os.environ.get("HOME") or os.path.expanduser("~")


def state_root() -> str:
    return os.environ.get("LANE_REGISTRY_STATE") or os.path.join(_home(), ".pi", "agent", "state")


def local_dir() -> str:
    """Per-box write-through copy. The REF is the shared authority; this is the box's own witness."""
    return os.environ.get("LANE_REGISTRY_LOCAL") or os.path.join(state_root(), "lanes")


def work_git() -> str:
    """A shared BARE repo used only to assemble objects. Never the caller's checkout.

    ⛔ NOT the caller's repo: writing lane objects into a checkout's object database pollutes a tree the
    lane is about to commit, and a lane's own `git status`-adjacent tooling would see it. A dedicated
    bare repo also means concurrent lanes writing objects at once are safe (loose object writes are
    atomic) with no lock of ours to get wrong.
    """
    return os.environ.get("LANE_REGISTRY_GIT") or os.path.join(state_root(), "lane-registry.git")


def short_host() -> str:
    try:
        return socket.gethostname().split(".")[0] or "unknown-host"
    except Exception:                                    # noqa: BLE001 - hostname is best-effort
        return "unknown-host"


# ── git plumbing ────────────────────────────────────────────────────────────────────────────────

class GitError(RuntimeError):
    def __init__(self, argv: Sequence[str], rc: int, err: str):
        self.argv = list(argv)
        self.rc = rc
        self.err = (err or "").strip()
        super().__init__("git %s -> rc=%d%s" % (" ".join(self.argv), rc,
                                                "" if not self.err else ": " + self.err))


def _git_env() -> dict:
    """The ONE env every git call gets.

    ⛔ `GIT_AUTHOR_*` / `GIT_COMMITTER_*` ARE PART OF IT, and not as a formality: `commit-tree` REFUSES
    with `rc=128 Author identity unknown` on a box with no global git identity — which is every cell
    (measured on cell-4, 2026-11-04: `fatal: unable to auto-detect email address (got
    'cmux@cmux.(none)')`). They must be set for the piped plumbing calls too, not only for `_git`'s,
    or the write path works on the hub and fails on the box that actually runs the lanes.
    """
    env = dict(os.environ)
    env["GIT_TERMINAL_PROMPT"] = "0"        # a prompt is an unbounded wait
    env.setdefault("GIT_AUTHOR_NAME", "lane-registry")
    env.setdefault("GIT_AUTHOR_EMAIL", "lane-registry@localhost")
    env.setdefault("GIT_COMMITTER_NAME", env["GIT_AUTHOR_NAME"])
    env.setdefault("GIT_COMMITTER_EMAIL", env["GIT_AUTHOR_EMAIL"])
    return env


def _run_piped(argv: Sequence[str], stdin_text: str, timeout: float) -> subprocess.CompletedProcess:
    """A git call that carries its payload on STDIN, with `_git`'s bounds and env."""
    return subprocess.run(["git"] + list(argv), input=stdin_text, capture_output=True, text=True,
                          timeout=timeout, env=_git_env())


def _git(argv: Sequence[str], timeout: float = DEFAULT_TIMEOUT_S, *,
         check: bool = True) -> Tuple[int, str, str]:
    """Run git, bounded. Never uses the shell, never inherits a pager."""
    env = _git_env()
    argv = ["git"] + list(argv)
    try:
        proc = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, env=env,
                              stdin=subprocess.DEVNULL)
    except FileNotFoundError as exc:
        raise GitError(argv, 127, "git not found: %s" % exc)
    except subprocess.TimeoutExpired:
        raise GitError(argv, 124, "timed out after %.0fs" % timeout)
    if check and proc.returncode != 0:
        raise GitError(argv, proc.returncode, proc.stderr)
    return proc.returncode, proc.stdout, proc.stderr


def _ensure_work_git() -> str:
    """The shared bare object store. Refuses to "initialise" a path that is somebody's WORKING TREE.

    ⛔ THE GUARD IS NOT PARANOIA. The obvious test — "does `<path>/objects` exist?" — is FALSE for a
    normal checkout (its objects live in `<path>/.git/objects`), so a `LANE_REGISTRY_GIT` pointed at a
    checkout made this run `git init --bare` INSIDE it: `core.bare=true`, and the working tree stops
    being a working tree. The marker file below is written only by this module, so a directory this
    module did not create is never silently re-initialised.
    """
    path = work_git()
    marker = os.path.join(path, "lane-registry-store")
    if os.path.exists(marker) and os.path.isdir(os.path.join(path, "objects")):
        return path
    if os.path.exists(os.path.join(path, ".git")):
        raise GitError(["check", path], 1,
                       "%s is a WORKING TREE (it has .git/) — refusing to `git init --bare` inside it; "
                       "point LANE_REGISTRY_GIT at a dedicated bare path" % path)
    os.makedirs(path, exist_ok=True)
    rc, _out, err = _git(["init", "-q", "--bare", path], check=False)
    if rc != 0:
        raise GitError(["init", "--bare", path], rc, err)
    try:
        with open(marker, "w", encoding="utf-8") as fh:
            fh.write("%s\n" % path)
    except OSError:
        pass
    return path


def registry_repo() -> str:
    """The ONE repo the registry lives in — the HARNESS repo, not the repo a lane is working on.

    ⛔ THIS IS THE DECISION THAT MAKES `lane.list` A SINGLE QUERY. A lane dispatched against `tortoise`
    would otherwise push its record to `tortoise`'s refs, and a reader on the hub would have to know
    which of N repos to poll — a discovery problem on top of a state problem, and the fleet has 26 lanes
    across several repos. So the registry is ONE store in the repo every box already has
    (`$AGENT_INFRA_PATH`), and **cross-repo visibility comes from the RECORD'S CONTENT** (`repo:
    owner/name`), never from which repo holds the ref. `lane.list --repo owner/name` filters in memory.

    Resolution: `LANE_REGISTRY_REPO` (explicit path) → `$AGENT_INFRA_PATH` → the current checkout.
    ⛔ THE LAST RUNG IS THE DANGEROUS ONE and it is never silent: a launcher whose `AGENT_INFRA_PATH`
    is unset (a cell that runs the workers from `$O`, which is NOT a checkout) would otherwise push
    `refs/lanes/*` into whatever repo it happens to sit in — a registry SPLIT ACROSS REPOS, which every
    reader then sees as "no such lane". `registry_repo_source()` names the rung in use, the payload
    carries it, and the cwd rung WARNs.
    """
    if os.environ.get("LANE_REGISTRY_REPO"):
        return os.environ["LANE_REGISTRY_REPO"]
    if os.environ.get("AGENT_INFRA_PATH"):
        return os.environ["AGENT_INFRA_PATH"]
    sys.stderr.write("[lane-registry] WARN no LANE_REGISTRY_REPO and no AGENT_INFRA_PATH — using the "
                     "CURRENT CHECKOUT (%s) as the registry. If another box resolves a different "
                     "checkout, its lanes and yours are in two registries and neither reader can see "
                     "the other. Set LANE_REGISTRY_REPO to the shared harness repo.\n" % os.getcwd())
    return os.getcwd()


def registry_repo_source() -> str:
    """WHICH rung of `registry_repo()` answered — carried in every payload so a split registry is visible."""
    if os.environ.get("LANE_REGISTRY_REPO"):
        return "env:LANE_REGISTRY_REPO"
    if os.environ.get("AGENT_INFRA_PATH"):
        return "env:AGENT_INFRA_PATH"
    return "cwd(UNSHARED)"


def _remote_url(remote: Optional[str], timeout: float) -> str:
    """The remote to push to / read from: an explicit URL, else the REGISTRY repo's `origin`."""
    if remote and ("://" in remote or remote.startswith("git@") or remote.startswith("/")
                   or os.path.isdir(remote)):
        return remote
    name = remote or "origin"
    repo = registry_repo() if remote is None else os.getcwd()
    rc, out, err = _git(["-C", repo, "remote", "get-url", name], timeout, check=False)
    if rc != 0 or not out.strip():
        raise GitError(["-C", repo, "remote", "get-url", name], rc or 1,
                       err or "no remote named %r in %s" % (name, repo))
    return out.strip()


def _redact(url: str) -> str:
    """Never print a credential that a remote URL may carry."""
    if "@" in url and "://" in url:
        scheme, _, rest = url.partition("://")
        _cred, _, host = rest.rpartition("@")
        return "%s://%s" % (scheme, host)
    return url


# ── the record ──────────────────────────────────────────────────────────────────────────────────

def new_lane_id(kind: str, tag: str, now: int, pid: Optional[int]) -> str:
    """`<host>.k<kind>-<tag>-<epoch>-p<pid>` — unique without a lock, safe as a ref component.

    #1761 (one owner per controller) is what makes this sufficient: host + start instant + pid is
    unique across boxes AND across lanes on one box, so the force-update below can never clobber a
    peer's record, and no registry-wide CAS is needed. A ref name may not contain `..`, `~`, `^`, `:`,
    `?`, `*`, `[`, `\\`, a space, or end in `.` — none of which the id can produce once kind/tag are
    screened (`_slug`).
    """
    # ⛔ THE RANDOM SUFFIX IS NOT DECORATION (measured, T15): two lanes started in the same second from
    # the same launcher produced the SAME id — host + instant + ppid are all identical for a controller
    # that dispatches twice in one tick, and the second `start` would then force-update the first lane's
    # record out of existence. 8 hex chars (32 bits) over a fleet of ~30 concurrent lanes makes a
    # collision a ~1-in-2-million event per dispatch pair, and the `start` CAS check below makes even that
    # impossible to lose silently.
    tag_part = "%s.k%s-%s-%d-p%d" % (short_host(), _slug(kind), _slug(tag), now, pid or 0)
    return "%s-%s" % (tag_part, secrets.token_hex(4))


def _slug(value: str) -> str:
    out = []
    for ch in str(value or ""):
        out.append(ch if (ch.isalnum() or ch in "-_") else "-")
    s = "".join(out).strip("-.")
    return s or "x"


def _derived(record: Dict[str, Any], now: int) -> Tuple[str, str]:
    """The FOUR-state reading of a record. One function, so no reader can invent a fifth.

    Returns `(state, state_reason)`. `EXPIRED` is derived here and nowhere else — a RUNNING record whose
    lease has lapsed is `EXPIRED`, and the reason names the two numbers it was derived from, because a
    verdict that cannot cite its inputs is a guess.
    """
    state = record.get("state")
    if state in TERMINAL:
        return state, "terminal-record" if state == "DONE" else "terminal-record:%s" % (
            record.get("reason") or "no-reason-recorded")
    if state != "RUNNING":
        # ⛔ UNREACHABLE BY CONSTRUCTION: `_record_problem` VALIDATES `state in WRITABLE` and every read
        # path refuses the WHOLE registry when a record fails it, so an unreadable state can never be
        # rendered as one of the four. Raising here — rather than folding it into EXPIRED — is what stops
        # "I could not read this" from being published as "no heartbeat past the budget", which would be
        # a false verdict of exactly the class this module exists to remove.
        raise ValueError("unvalidated state %r reached _derived — read paths must call _record_problem"
                         % (state,))
    lease = int(record["lease_until"])
    if now > lease:
        return "EXPIRED", "lease-lapsed:now=%d>lease_until=%d (heartbeat_at=%s budget_s=%s)" % (
            now, lease, record.get("heartbeat_at"), record.get("budget_s"))
    return "RUNNING", "lease-open:lease_until=%d" % lease


def _record_problem(rec: Any) -> Optional[str]:
    """Why this payload cannot be read as a lane record, or None when it can.

    ⛔ A CORRUPT RECORD FAILS THE WHOLE READ. It must not be skipped: skipping it would report a lane as
    NEVER HAVING EXISTED (a false-clean), and it must not be rendered as `EXPIRED`: that would assert
    "no heartbeat past the budget" about a record whose heartbeat field may be perfectly present.
    """
    if not isinstance(rec, dict):
        return "not a JSON object"
    lane_id = rec.get("lane_id")
    if not lane_id:
        return "no lane_id"
    # ⛔ THE ID IS SCREENED HERE, AT THE ONE PLACE EVERY READER PASSES, because it is used as a FILENAME
    # (`_write_local`) and as a REF COMPONENT (`_push`). A record published by a peer, or hand-edited, is
    # attacker-controlled data: `lane_id: "../../ESCAPED"` wrote outside the state root (measured), and a
    # temp name derived from it is a symlink target.
    if not LANE_ID_RE.match(str(lane_id)):
        return "lane_id %r is not a safe id (%s)" % (lane_id, LANE_ID_RE.pattern)
    if rec.get("state") not in WRITABLE:
        return "state %r is not one of %s (EXPIRED is DERIVED, never written)" % (
            rec.get("state"), list(WRITABLE))
    # ⛔ EVERY FIELD THE READER *ARITHMETICALLY* USES IS VALIDATED, not just the two easy ones. Missing
    # `lease_until` used to read as `int(0)` — i.e. EXPIRED — from a record whose heartbeat was perfectly
    # fresh, and `"lease_until": "soon"` raised an uncaught ValueError and killed `list` with exit 1
    # (measured). Both are the "corrupt record rendered as a verdict" failure the contract forbids.
    for field in ("heartbeat_at", "budget_s", "lease_until", "started_at"):
        try:
            int(rec.get(field))
        except (TypeError, ValueError):
            return "%s is not an integer (%r)" % (field, rec.get(field))
    budget = int(rec["budget_s"])
    if budget < 1 or budget > MAX_BUDGET_S:
        return "budget_s %r is outside 1..%d" % (budget, MAX_BUDGET_S)
    # Invariant I1, VERIFIED ON READ rather than trusted from the writer: a record whose lease does not
    # follow from its own heartbeat can otherwise claim RUNNING forever (a far-future `lease_until`).
    if int(rec["lease_until"]) != int(rec["heartbeat_at"]) + budget:
        return ("lease_until %s does not equal heartbeat_at+budget_s (%s+%s) — the record is "
                "self-inconsistent" % (rec["lease_until"], rec["heartbeat_at"], budget))
    # ⛔ THE TERMINAL INVARIANTS ARE RE-CHECKED ON READ, NOT TRUSTED FROM THE WRITER. They were enforced
    # only in `terminal_refusal`, which is the WRITE path — so a peer-published or hand-edited
    # `state:"DONE", artifacts:[]` read back as a perfectly good DONE, and the module's own threat model
    # treats records as attacker-controlled. The invariant is "a DONE record names what it produced", and
    # an invariant that only one writer is trusted to keep is not an invariant.
    if rec.get("state") == "DONE":
        arts = rec.get("artifacts")
        if not isinstance(arts, list) or not arts:
            return "state is DONE but artifacts is empty — a done that names nothing is unverifiable"
    if rec.get("state") == "FAILED" and not str(rec.get("reason") or "").strip():
        return "state is FAILED but reason is empty — a failure without a stated cause cannot be acted on"
    return None


def _write_local(record: Dict[str, Any]) -> str:
    """Write this box's own copy. `mkstemp`, not a predictable name:
    `<lane>.json.tmp.<pid>` is guessable, and a pre-planted symlink there is followed — measured
    overwriting an unrelated file when `LANE_REGISTRY_LOCAL` is shared."""
    lane_id = str(record.get("lane_id") or "")
    if not LANE_ID_RE.match(lane_id):
        raise ValueError("refusing to write a record whose lane_id %r is not a safe filename" % (lane_id,))
    d = local_dir()
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, "%s.json" % lane_id)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".%s." % lane_id, suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(record, fh, indent=2, sort_keys=True)
            fh.write("\n")
        os.replace(tmp, path)      # atomic: a reader never sees a half-written record
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    return path


def _read_local() -> Tuple[bool, str, Dict[str, Dict[str, Any]]]:
    """Read this box's write-through copies. `(readable, detail, records)`."""
    d = local_dir()
    if not os.path.isdir(d):
        return True, "no local records (%s absent)" % d, {}
    out: Dict[str, Dict[str, Any]] = {}
    try:
        names = [n for n in os.listdir(d) if n.endswith(".json")]
    except OSError as exc:
        return False, "listdir %s: %s" % (d, exc), {}
    for name in names:
        path = os.path.join(d, name)
        try:
            with open(path, encoding="utf-8") as fh:
                rec = json.load(fh)
        except (OSError, ValueError) as exc:
            # ⛔ A corrupt local record is UNREADABLE, not absent. Dropping it would report a lane as
            # never having existed, which is the false-clean direction.
            return False, "unreadable local record %s: %s" % (path, exc), out
        problem = _record_problem(rec)
        if problem:
            return False, "local record %s: %s" % (path, problem), out
        out[rec["lane_id"]] = rec
    return True, "local %s (%d record(s))" % (d, len(out)), out


def _push(record: Dict[str, Any], remote: Optional[str], timeout: float) -> Tuple[bool, str]:
    """Publish the record as `refs/lanes/<lane-id>`. `(pushed, detail)` — never raises."""
    try:
        lane_id = str(record.get("lane_id") or "")
        # ⛔ THE DESTINATION IS THE *RECORD'S OWN* ID, AND THE RECORD'S ID MUST BE A SAFE ONE. Both halves
        # are load-bearing: `_push` used to take the ref name from the payload alone, so a peer-published
        # ref whose payload named ANOTHER lane made `beat`/`done` overwrite THAT lane's record (measured:
        # a terminal DONE flipped back to RUNNING). The read path now rejects an id/ref mismatch, and this
        # guard means no future caller can reintroduce it.
        if not LANE_ID_RE.match(lane_id):
            return False, "refusing to push lane_id %r — not a safe ref component" % (lane_id,)
        repo = _ensure_work_git()
        url = _remote_url(remote, timeout)
        body = json.dumps(record, indent=2, sort_keys=True) + "\n"
        # `hash-object` and `mktree` both read their payload on STDIN, which `_git` deliberately
        # closes (`stdin=DEVNULL`) so that no git call can block on a prompt. So these two are piped
        # directly with the same bounds, instead of going through the helper.
        proc = _run_piped(["-C", repo, "hash-object", "-w", "--stdin"], body, timeout)
        if proc.returncode != 0:
            return False, "hash-object rc=%d: %s" % (proc.returncode, proc.stderr.strip())
        blob = proc.stdout.strip()
        if not blob:
            return False, "hash-object produced no blob"
        tree_in = "100644 blob %s\t%s\n" % (blob, PAYLOAD_PATH)
        proc = _run_piped(["-C", repo, "mktree"], tree_in, timeout)
        if proc.returncode != 0:
            return False, "mktree rc=%d: %s" % (proc.returncode, proc.stderr.strip())
        tree = proc.stdout.strip()
        msg = "lane %s state=%s host=%s ts=%d" % (record["lane_id"], record["state"],
                                                   record.get("host", "?"), int(time.time()))
        proc = _run_piped(["-C", repo, "commit-tree", tree], msg + "\n", timeout)
        if proc.returncode != 0:
            return False, "commit-tree rc=%d: %s" % (proc.returncode, proc.stderr.strip())
        commit = proc.stdout.strip()
        ref = "%s/%s" % (NS, lane_id)
        # ⛔ FORCE, and it is safe by CONSTRUCTION rather than by convention: the ref name embeds the
        # host, the start instant and the pid, so the only writer that can ever target this ref is the
        # process that minted it. A lease-guarded force would be pure ceremony here — and ceremony that
        # can refuse would let a registry hiccup block a lane's terminal record, which is worse than the
        # clobber it prevents (there is nobody to clobber).
        rc, _out, err = _git(["-C", repo, "push", "--quiet", "--force", url,
                              "%s:%s" % (commit, ref)], timeout, check=False)
        if rc != 0:
            return False, "push %s: %s" % (ref, err.strip() or ("rc=%d" % rc))
        return True, "pushed %s" % ref
    except GitError as exc:
        return False, str(exc)
    except Exception as exc:                             # noqa: BLE001 - push must never raise
        return False, "%s: %s" % (type(exc).__name__, exc)


def _read_remote(remote: Optional[str], timeout: float) -> Tuple[bool, str, Dict[str, Dict[str, Any]], bool]:
    """Read the shared registry. `(readable, detail, records, corrupt)` — `readable=False` is NOT empty.

    The pattern is `claims.sh`'s, reused rather than re-invented: `ls-remote` is the AUTHORITY ON
    PRESENCE (it can distinguish "the read failed" from "there are no refs"), and the payloads are
    fetched into an ISOLATED temp bare repo so a racing registry can neither write nor delete a local ref.

    ⛔ `corrupt` IS ITS OWN AXIS, NOT A KIND OF "UNREACHABLE". A registry that ANSWERED and was
    unreadable is a different fact from one that could not be reached, and only the second may be
    replaced by this box's own copy — otherwise a corrupt shared record is silently masked by a stale
    local cache, which is the one read that most needs to be loud.
    """
    try:
        url = _remote_url(remote, timeout)
    except GitError as exc:
        return False, "cannot resolve remote: %s" % exc, {}, False
    try:
        return _read_remote_from(url, timeout)
    except GitError as exc:
        # ⛔ A TIMEOUT IS A `GitError`, AND IT USED TO ESCAPE THIS FUNCTION ENTIRELY. `check=False`
        # suppresses a RETURN CODE, not the exception `subprocess.run` raises on its own bound — so a
        # blackholed remote made `list`/`show`/`beat`/`done` die with a traceback and exit 1, outside the
        # documented 0/2/3/4/5/6 table, and never reached the local fallback (measured: a reachable local
        # witness, `rc=1`, empty stdout). An unbounded error is not an abstention; it is an outage.
        return False, "%s" % exc, {}, False


def _read_remote_from(url: str, timeout: float) -> Tuple[bool, str, Dict[str, Dict[str, Any]], bool]:
    source = "pull %s %s" % (_redact(url), REF_GLOB)
    rc, out, err = _git(["ls-remote", url, REF_GLOB], timeout, check=False)
    if rc != 0:
        return False, "%s rc=%d%s" % (source, rc, "" if not err.strip() else ": " + err.strip()), {}, False

    refs: List[Tuple[str, str]] = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) != 2:
            continue
        sha, ref = parts[0].strip(), parts[1].strip()
        if ref.startswith(NS + "/") and ref != NS:
            refs.append((sha, ref))
    if not refs:
        return True, "%s: 0 ref(s) — a READ registry with no lanes" % source, {}, False

    tmp = tempfile.mkdtemp(prefix="lane-registry-")
    try:
        rc, _o, ierr = _git(["-C", tmp, "init", "-q", "--bare"], timeout, check=False)
        if rc != 0:
            return False, "%s: temp init rc=%d %s" % (source, rc, ierr.strip()), {}, False
        rc, _o, ferr = _git(["-C", tmp, "fetch", "-q", "--no-tags", "--depth=1", url,
                             "+%s:%s" % (REF_GLOB, "refs/lane-read/*")], timeout, check=False)
        if rc != 0:
            # ⛔ A held registry whose BODIES cannot be read is UNMEASURED, not a list of empty lanes.
            return False, "%s: fetch rc=%d %s" % (source, rc, ferr.strip()), {}, False
        records: Dict[str, Dict[str, Any]] = {}
        for sha, ref in refs:
            lane_id = ref[len(NS) + 1:]
            rc, body, cerr = _git(["-C", tmp, "cat-file", "-p", "%s:%s" % (sha, PAYLOAD_PATH)],
                                  timeout, check=False)
            if rc != 0:
                return False, "%s: %s unreadable: %s" % (source, ref, cerr.strip()), {}, True
            try:
                rec = json.loads(body)
            except ValueError as exc:
                return False, "%s: %s is not JSON: %s" % (source, ref, exc), {}, True
            problem = _record_problem(rec)
            if problem:
                return False, "%s: %s: %s" % (source, ref, problem), {}, True
            # ⛔ THE REF NAME AND THE PAYLOAD'S ID MUST AGREE. Everything downstream keys on
            # `rec["lane_id"]` (the writer pushes to it, `show` matches on it), so a ref called A whose
            # payload says B is a record that can silently stand in for another lane — a false RUNNING or
            # a resurrected DONE manufactured from ref/record construction. A mismatch is corrupt.
            if rec["lane_id"] != lane_id:
                return False, ("%s: %s payload names lane_id %r — a ref/record mismatch is a corrupt "
                               "record, not a lane" % (source, ref, rec["lane_id"])), {}, True
            rec["_ref"] = ref
            rec["_sha"] = sha
            records[lane_id] = rec
        return True, "%s: %d ref(s)" % (source, len(records)), records, False
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def read_registry(remote: Optional[str] = None, timeout: float = DEFAULT_TIMEOUT_S,
                  *, allow_local_fallback: bool = True) -> Tuple[bool, str, Dict[str, Dict[str, Any]], str]:
    """The ONE read path. `(readable, detail, records, source)` — `source` is `ref` / `local` / `none`.

    ⛔ `source` IS RETURNED, NOT INFERRED FROM THE PROSE. It used to be recovered by substring-matching
    `"[source=local"` inside `detail` (see `coverage`), so every `isError` on the MCP surface and every
    NOT-FOUND suppression hung off the wording of a human-readable log line — reword one message and the
    whole fleet silently reports `coverage: shared` for a box's own witness.
    """
    ok, detail, records, corrupt = _read_remote(remote, timeout)
    if ok:
        return True, detail + " [source=ref]", records, "ref"
    if corrupt:
        # ⛔ A CORRUPT SHARED REGISTRY IS NOT A REASON TO ANSWER FROM THE LOCAL CACHE. That would hide the
        # corruption from the one reader placed to notice it, and report a stale local view as the fleet.
        return (False, detail + " | NOT replaced by the local copy: the shared registry answered and was "
                                "corrupt, which is a different fact from unreachable", {}, "none")
    if not allow_local_fallback:
        return False, detail, {}, "none"
    lok, ldetail, lrecs = _read_local()
    if not lok:
        return False, "%s | local ALSO unreadable: %s" % (detail, ldetail), {}, "none"
    if not lrecs:
        # ⛔ AN EMPTY LOCAL WITNESS IS NOT EVIDENCE OF AN EMPTY FLEET. This box's own records are the only
        # thing the fallback can speak to; with none, the honest answer is still UNMEASURED — reporting
        # `RUNNING=0` here would publish "nothing is running" from a read that never reached the shared
        # store, which is the FALSE-CLEAN this module exists to make impossible (the fleet's 26 lanes run
        # on OTHER boxes, so zero local rows says nothing about them).
        return (False, "%s | local %s has 0 record(s) — an empty local witness is NOT an empty fleet"
                % (detail, local_dir()), {}, "none")
    return True, ("%s | FELL BACK to %s [source=local: THIS BOX ONLY — peer lanes invisible]"
                  % (detail, ldetail)), lrecs, "local"


# ── verbs ──────────────────────────────────────────────────────────────────────────────────────

def coverage(source: str) -> str:
    """`shared` when the SHARED store answered; `local-only` when only this box's copies did.

    A pure mapping over the `source` that `read_registry` RETURNS — never over the wording of a log line.

    ⛔ THIS IS A SEPARATE FIELD FROM `readable`, AND THE DISTINCTION IS THE WHOLE POINT. A local fallback
    answers "which of THIS BOX's lanes are running" and says nothing about the fleet — on 2026-11-04
    that was 26 lanes across several boxes. Reporting it as a complete answer is the false-clean class
    again, so every payload carries it and the MCP surface raises `isError` on `local-only`: a caller
    must not conclude "no peer lanes" from a read that never reached the shared store.
    """
    return "shared" if source == "ref" else "local-only"


def _now() -> int:
    return int(time.time())


def _budget(value: Optional[int]) -> int:
    b = DEFAULT_BUDGET_S if value is None else int(value)
    if b < 1:
        raise SystemExit(_die(USAGE, "budget must be >= 1 second (got %r)" % value))
    if b > MAX_BUDGET_S:
        sys.stderr.write("[lane-registry] WARN budget %ds clamped to %ds — a budget above a day is a "
                         "typo, not a plan\n" % (b, MAX_BUDGET_S))
        b = MAX_BUDGET_S
    return b


def _die(code: int, msg: str) -> int:
    sys.stderr.write("[lane-registry] %s\n" % msg)
    return code


def measure_existing(lane_id: str, remote: Optional[str],
                     timeout: float) -> Tuple[bool, Optional[Dict[str, Any]]]:
    """Read one record, remote-first. `(readable, record_or_None)` — a TRI-STATE, on purpose.

    ⛔ `None` IS NOT "ABSENT" UNTIL `readable` IS TRUE. This used to discard the read's `ok` flag, which
    collapsed UNMEASURED into NOT-FOUND: `done`/`fail` answered “no record, start it first” and never
    published the terminal record, and `start` skipped its own CAS guard and force-pushed a fresh RUNNING
    over an existing terminal DONE (both measured). "I could not read" must never become "it is not
    there" on the WRITE side — that is how a finished lane is silently resurrected.
    """
    ok, _detail, records, _source = read_registry(remote, timeout)
    if not ok:
        return False, None
    rec = records.get(lane_id)
    if rec is None:
        # ⛔ THE SHARED STORE ANSWERING WITHOUT THIS LANE IS NOT PROOF THE LANE DOES NOT EXIST — a record
        # opened during an outage (exit 6, LOCAL_ONLY) lives only here, and the shared read now succeeds
        # without it. Ignoring the local copy made every such lane UNCLOSABLE: `done`/`fail` answered
        # NOT-FOUND (measured, rc=4), the terminal record was lost to the fleet, and the WARN in
        # `run_agent` told the operator to run a command that could never work. The local copy is
        # consulted for THIS id only, and only on the write path — `start` does not use this function, so
        # the "do not resurrect a finished lane" guard is untouched.
        try:
            with open(os.path.join(local_dir(), "%s.json" % lane_id), "r") as fh:
                local = json.load(fh)
        except (OSError, ValueError):
            return True, None
        if isinstance(local, dict) and local.get("lane_id") == lane_id and not _record_problem(local):
            return True, local
    return True, rec


def ref_exists(lane_id: str, remote: Optional[str],
               timeout: float) -> Tuple[bool, bool, str]:
    """`(readable, exists, detail)` for ONE lane, in ONE round trip — the WRITE side's existence probe.

    ⛔ `start` DOES NOT NEED THE WHOLE REGISTRY, AND READING IT COST THE SPAWN ITSELF. It used a full
    `read_registry` (an `ls-remote` plus a `fetch` plus a `cat-file` per existing lane, each bounded at
    20 s) BEFORE the agent was spawned — so on a blackholed remote the launch path grew by ≥40 s and by
    the number of lanes, which is exactly the "must not delay a spawn" property the wiring claims. This
    asks the authority the one question it actually has: does this exact ref exist? One bounded
    `ls-remote`, no fetch, no per-lane cost.

    `ls-remote` distinguishes absence (`rc=0`, empty output) from failure (`rc!=0`) — the whole reason a
    failed read must never be read as "not there": at rc!=0 `readable` is False and the caller abstains.
    """
    try:
        url = _remote_url(remote, timeout)
    except GitError as exc:
        return False, False, "cannot resolve remote: %s" % exc
    ref = "%s/%s" % (NS, lane_id)
    try:
        rc, out, err = _git(["ls-remote", url, ref], timeout, check=False)
    except GitError as exc:
        return False, False, "ls-remote %s: %s" % (ref, exc)
    if rc != 0:
        return False, False, "ls-remote %s rc=%d%s" % (ref, rc,
                                                        "" if not err.strip() else ": " + err.strip())
    present = bool(out.strip())
    return True, present, "ls-remote %s: %s" % (ref, "present" if present else "absent")


def _commit(record: Dict[str, Any], remote: Optional[str], timeout: float, *, quiet: bool) -> int:
    """Persist (local copy + ref push) and return the VERB's exit code.

    ⛔ THE LOCAL WRITE IS BEST-EFFORT AND THE PUSH IS THE AUTHORITY. `_write_local` used to run unguarded,
    so an unwritable state dir (a read-only HOME, a full disk, `HOME` unset) aborted the verb BEFORE the
    shared record was ever pushed — the terminal record was lost to a cache failure, and docs §7 says the
    local copy is never the authority. The exit code is derived from the push alone.
    """
    try:
        _write_local(record)                   # the box's own witness — always attempted
    except (OSError, ValueError) as exc:
        sys.stderr.write("[lane-registry] WARN could not write the local copy of %s: %s "
                         "(the ref is the authority; continuing)\n" % (record.get("lane_id"), exc))
    pushed, detail = _push(record, remote, timeout)
    if not quiet:
        sys.stderr.write("[lane-registry] %s %s: %s\n"
                         % (record.get("lane_id"), record.get("state"), detail))
    return OK if pushed else LOCAL_ONLY


def cmd_start(args: argparse.Namespace) -> int:
    now = _now()
    budget = _budget(args.budget)
    pid = args.pid if args.pid is not None else os.getppid()
    lane_id = args.lane_id or new_lane_id(args.kind, args.tag, now, pid)
    rec: Dict[str, Any] = {
        "schema": SCHEMA,
        "lane_id": lane_id,
        "state": "RUNNING",
        "host": short_host(),
        "pid": pid,
        "kind": args.kind,
        "tag": str(args.tag),
        "repo": args.repo,
        "branch": args.branch,
        "worktree": args.worktree or os.getcwd(),
        "issue": args.issue,
        "attempt": args.attempt,
        "started_at": now,
        "heartbeat_at": now,
        "budget_s": budget,
        "lease_until": now + budget,          # I1: the ONE derivation — see _derived()
        "artifacts": [],
        "reason": None,
        "exit_code": None,
    }
    # ⛔ AN UNSAFE ID IS REFUSED *BEFORE* ANY I/O. Previously `start --lane-id ../escape` reached the
    # writer, which warned, wrote nothing, and still exited 6 ("written on this box, the push failed") and
    # PRINTED the handle — handing the caller an id for a lane that does not exist. The id is a ref
    # component and a file name, so it is validated where it is minted.
    if not LANE_ID_RE.match(lane_id):
        return _die(USAGE, "start: lane id %r is not a safe ref component (want %s) — refused before "
                           "anything was written" % (lane_id, LANE_ID_RE.pattern))
    # ⛔ THE LOCAL WITNESS IS CHECKED FIRST, AND IT COSTS NO NETWORK. `ref_exists` alone asks only the
    # shared ref, so a record that exists ONLY here — left by a `start` that hit LOCAL_ONLY (exit 6) —
    # read as "absent" and a second `start` for the same id silently REPLACED it, exit 0, while the code
    # below and docs §3.3 both claim an existing id is refused. The local copy is the one axis this box
    # can always answer.
    # ⛔ THE PROBE IS THIS LANE'S OWN FILE, NOT THE DIRECTORY MAP. `_read_local` fails the WHOLE directory
    # as soon as ONE record is corrupt, so a guard written as `if lok and lane_id in lrecords` is vacuous
    # in exactly the state the reader treats as first-class: with a single poisoned sibling present,
    # `start --lane-id X` over an existing local X returned 0 and replaced it (measured), while the same
    # call without the poison returned 5. Presence of the file is the fact that matters, and an
    # existing-but-corrupt record must block a start too — one `exists()`, O(1), immune to siblings.
    own_local = os.path.join(local_dir(), "%s.json" % lane_id)
    if os.path.exists(own_local):
        return _die(REFUSED, "start REFUSED: %s already exists in this box's own witness (%s) — pick "
                             "another id, or use `beat` if this IS that lane" % (lane_id, own_local))
    # ⛔ ONE ROUND TRIP, NOT A FULL REGISTRY READ: see `ref_exists`. The id is a freshly generated handle,
    # so the only question worth asking the authority is whether this exact ref is already taken.
    readable, exists, rdetail = ref_exists(lane_id, args.remote, args.timeout)
    if not readable and args.lane_id:
        # ⛔ A CALLER-SUPPLIED id, WITH AN UNREADABLE REGISTRY, IS THE RESURRECTION CASE: this exact id may
        # already be a finished lane we simply cannot see, and overwriting it would resurrect it. Refuse.
        # (A GENERATED id cannot collide — it carries a random suffix — so that case falls through below
        # and still opens a record, which is what keeps a lane dispatched during an outage VISIBLE on this
        # box instead of invisible for its whole life: the pre-fix behaviour refused, wrote nothing, and
        # every lane launched in the outage then answered NOT-FOUND forever. Measured.)
        return _die(UNMEASURED, "start REFUSED: the registry could not be read, so the id %r you supplied "
                                "cannot be checked for an existing record — NOT a missing record, and "
                                "not a reason to overwrite one (%s)" % (lane_id, rdetail))
    if not readable and not args.lane_id:
        sys.stderr.write("[lane-registry] WARN start: the registry is unreadable (%s); opening a "
                         "LOCAL-ONLY record for the generated id %s — this lane is visible on this box "
                         "only until its record can be pushed\n" % (rdetail, lane_id))
    if exists:
        # ⛔ A `start` MUST NOT OVERWRITE A LANE. The random suffix makes this unreachable in practice; it
        # is enforced anyway because the failure mode (one lane's record silently replacing another's) is
        # invisible after the fact — the fleet would read a finished lane's SLOT as a fresh RUNNING one.
        return _die(REFUSED, "start REFUSED: %s already exists — pick another id, or use `beat` if this "
                             "IS that lane (%s)" % (lane_id, rdetail))
    rc = _commit(rec, args.remote, args.timeout, quiet=args.quiet)
    if not args.quiet:
        sys.stdout.write("%s\n" % lane_id)     # the handle, and the only thing a caller needs
    return rc


def cmd_beat(args: argparse.Namespace) -> int:
    ok, rec = measure_existing(args.lane_id, args.remote, args.timeout)
    if not ok:
        return _die(UNMEASURED, "beat: the registry could not be read, so %r cannot be shown to exist "
                                "(this is NOT 'not found')" % args.lane_id)
    if rec is None:
        return _die(NOT_FOUND, "beat: no record for %r — NOT a state; start it first" % args.lane_id)
    state, why = _derived(rec, _now())
    if state in TERMINAL:
        # ⛔ A TERMINAL RECORD IS FINAL (Kubernetes Job conditions are). A beat that resurrected one would
        # let a stray process overwrite the answer the fleet is waiting for.
        return _die(REFUSED, "beat REFUSED: %s is %s (%s) — a terminal record is final"
                    % (args.lane_id, state, why))
    now = _now()
    budget = int(rec["budget_s"])
    # ⛔ THE OLD LEASE MUST BE READ BEFORE IT IS OVERWRITTEN. It used to be assigned on the next line and
    # then COMPARED TO ITSELF (`now >= rec["lease_until"] - budget//2` == `now >= now + budget//2`), which
    # is False for every budget ≥ 1 — so the half-way renewal was dead code and a live lane's ref was
    # never extended past `started_at + budget_s`. `read_registry` is remote-first, so the fresh local
    # heartbeat was never consulted while the shared store was reachable: any lane outliving its budget
    # read EXPIRED to every peer while it was working (measured with budget=100: bound crossed, `beat`
    # returned 0, ref NOT republished). This is the false-death direction the whole module exists to end.
    old_lease = int(rec["lease_until"])
    rec["heartbeat_at"] = now
    rec["lease_until"] = now + budget       # I1, the same derivation `_record_problem` verifies
    rec["state"] = "RUNNING"
    # ⛔ A BEAT IS LOCAL UNLESS THE LEASE ACTUALLY NEEDS RENEWING. Publishing every beat would mint one
    # commit + one ref write per lane per minute (~1.4k unreachable objects/day at 25 lanes, and the same
    # number of pushes at the remote) to say the same thing. The lease is what a reader consults, so the
    # ref only has to be renewed before it lapses: renew once HALF of it is spent. `--push` forces it.
    if args.push or now >= old_lease - budget // 2:
        return _commit(rec, args.remote, args.timeout, quiet=args.quiet)
    try:
        _write_local(rec)
    except (OSError, ValueError) as exc:
        sys.stderr.write("[lane-registry] WARN could not write the local copy of %s: %s\n"
                         % (rec["lane_id"], exc))
    if not args.quiet:
        sys.stderr.write("[lane-registry] %s RUNNING: lease held locally (renews the ref at the "
                         "half-way point)\n" % rec["lane_id"])
    return OK


def _artifacts(args: argparse.Namespace) -> List[Dict[str, str]]:
    out: List[Dict[str, str]] = []
    for raw in (args.artifact or []):
        kind, sep, value = raw.partition(":")
        if not sep or not kind.strip() or not value.strip():
            raise SystemExit(_die(USAGE, "--artifact wants <kind>:<value> (got %r)" % raw))
        out.append({"kind": kind.strip(), "value": value.strip()})
    # `getattr`, because `fail` accepts artifacts but has no `--pr`: a shared helper that reaches for
    # an attribute only one subparser declares crashes the OTHER verb (measured: `fail` died with
    # `Namespace has no attribute 'pr'` before any record was written).
    pr = getattr(args, "pr", None)
    if pr:
        out.append({"kind": "pr", "value": str(pr)})
    for sha in (getattr(args, "sha", None) or []):
        out.append({"kind": "sha", "value": sha})
    return out


def terminal_refusal(state: str, arts: Sequence[Dict[str, str]], reason: Optional[str]) -> Optional[str]:
    """The TERMINAL-RECORD guard, as a PURE function — so the guard itself can be mutation-tested.

    ⛔ `DONE` MUST NAME ITS ARTIFACTS (the brief's own acceptance criterion). A done that names nothing is
    the mirror image of the FALSE-DEATH the fleet paid for: it asserts finished, and cannot say finished
    WITH WHAT, which is the question the orchestrator actually needs answered. `ARTIFACTS` are what let a
    reader verify the end instead of trusting the word.
    ⛔ `FAILED` MUST STATE A CAUSE. "It failed" is precisely what the fleet already had; a failure whose
    reason is blank costs a full re-investigation.
    """
    if state == "DONE" and not arts:
        return ("done REFUSED: --artifact/--pr/--sha is REQUIRED — a DONE record must name what it "
                "produced (a done that names nothing is unverifiable)")
    if state == "FAILED" and not (reason or "").strip():
        return ("fail REFUSED: --reason is REQUIRED — a failure without a stated cause cannot be acted "
                "on, and 'it failed' is what the fleet already had")
    return None


def _terminal(args: argparse.Namespace, state: str, reason: Optional[str],
              exit_code: Optional[int]) -> int:
    ok, rec = measure_existing(args.lane_id, args.remote, args.timeout)
    if not ok:
        # ⛔ THE TERMINAL RECORD IS THE MOST IMPORTANT WRITE IN THE MODULE. Reporting NOT-FOUND here
        # because the registry was UNREADABLE loses it, and the lane then reads EXPIRED to every peer —
        # the exact answer the fleet cannot afford to get wrong.
        return _die(UNMEASURED, "%s: the registry could not be read, so %r cannot be shown to exist "
                                "(this is NOT 'not found')" % (state.lower(), args.lane_id))
    if rec is None:
        return _die(NOT_FOUND, "%s: no record for %r" % (state.lower(), args.lane_id))
    cur, why = _derived(rec, _now())
    if cur in TERMINAL:
        return _die(REFUSED, "%s REFUSED: %s is already %s (%s) — a terminal record is final"
                    % (state.lower(), args.lane_id, cur, why))
    arts = _artifacts(args)
    refusal = terminal_refusal(state, arts, reason)
    if refusal:
        return _die(REFUSED, refusal)
    now = _now()
    rec["state"] = state
    rec["heartbeat_at"] = now
    # A terminal record is not "running", so its lease is widened by exactly the remaining budget in a
    # way that keeps I1 true — `_record_problem` VERIFIES `lease_until == heartbeat_at + budget_s` on
    # every read, so a terminal record that skipped this would be rejected as self-inconsistent.
    rec["lease_until"] = now + int(rec["budget_s"])
    rec["artifacts"] = arts or rec.get("artifacts") or []
    rec["reason"] = (reason or "").strip() or None
    rec["exit_code"] = exit_code
    rec["ended_at"] = now
    rec["duration_s"] = now - int(rec["started_at"])
    return _commit(rec, args.remote, args.timeout, quiet=args.quiet)


def cmd_done(args: argparse.Namespace) -> int:
    return _terminal(args, "DONE", None, args.exit_code)


def cmd_fail(args: argparse.Namespace) -> int:
    return _terminal(args, "FAILED", args.reason, args.exit_code)


def collect(args: argparse.Namespace) -> Tuple[bool, str, List[Dict[str, Any]], int, Dict[str, Any], Dict[str, Any]]:
    """Shared by `list` and `show`: `(readable, detail, rows, exit_code_hint, filters_applied, extra)`.

    ⛔ THE FILTERS ARE APPLIED HERE, NOT IN `cmd_list`. They used to live only in `cmd_list`, so the MCP
    surface — which calls this — silently ignored `state`/`host`/`repo` and answered a WIDER population
    than the caller asked for, with no marker (measured: `lane.list {state:"FAILED"}` returned the DONE
    and the RUNNING lane while the CLI with the same filter returned none). One implementation, two
    surfaces, and the same answer from both.

    ⛔ AND AN UNRECOGNISED FILTER IS A USAGE ERROR, NOT A ZERO. The CLI got that from argparse `choices`;
    the MCP did not, so `lane.list {state:"BOGUS"}` (or `"RUNNING "` with a stray space) answered a
    DEFINITE `RUNNING=0` with `isError: false` — a filter-shaped false clean on the surface the owner is
    meant to use, and the exact invariant-1 violation this module exists to forbid. The check lives here
    because this is the one place both surfaces pass through.
    """
    want_state = getattr(args, "state", None)
    if want_state and str(want_state).strip().upper() not in STATES:
        return (False, "filter state %r is not one of %s" % (want_state, list(STATES)),
                [], USAGE, {}, {})
    ok, detail, records, source = read_registry(args.remote, args.timeout)
    now = _now()
    if not ok:
        return False, detail, [], UNMEASURED, {}, {"source": source}
    rows: List[Dict[str, Any]] = []
    try:
        for rec in records.values():
            state, why = _derived(rec, now)
            row = dict(rec)
            row["state"] = state
            row["state_reason"] = why
            row["age_s"] = now - int(rec["started_at"])
            row["heartbeat_age_s"] = now - int(rec["heartbeat_at"])
            rows.append(row)
    except (KeyError, TypeError, ValueError) as exc:
        # ⛔ VALIDATION SHOULD HAVE CAUGHT THIS; IF IT DID NOT, THE ANSWER IS UNMEASURED, NOT A TRACEBACK.
        # An uncaught arithmetic error used to exit 1 with empty stdout — outside the documented table.
        return False, "%s | record rendering failed: %s: %s" % (detail, type(exc).__name__, exc), \
               [], UNMEASURED, {}, {"source": source}
    rows.sort(key=lambda r: int(r.get("started_at") or 0))
    applied = {k: v for k, v in (("state", want_state),
                                 ("host", getattr(args, "host", None)),
                                 ("repo", getattr(args, "repo", None))) if v}
    extra: Dict[str, Any] = {"source": source}
    # ⛔ A FILTER THAT CANNOT MATCH IS NOT A ZERO, IT IS A BLIND SPOT — and say which. A record whose
    # `repo` was never written (an origin that does not parse to `owner/name`, a peer's older record) can
    # never satisfy `--repo`, so `--repo o/n → RUNNING=0` may mean "no such lane" or "no lane could say".
    # The count of rows that could not answer is published rather than left to the reader to assume.
    unfiltered = len(rows)
    if applied.get("state"):
        want = str(applied["state"]).strip().upper()
        rows = [r for r in rows if r["state"] == want]
        applied["state"] = want
    if applied.get("host"):
        missing = sum(1 for r in rows if not r.get("host"))
        rows = [r for r in rows if r.get("host") == applied["host"]]
        if missing:
            extra["excluded_no_host"] = missing
    if applied.get("repo"):
        missing = sum(1 for r in rows if not r.get("repo"))
        rows = [r for r in rows if r.get("repo") == applied["repo"]]
        if missing:
            extra["excluded_no_repo"] = missing
    if applied and not rows and unfiltered:
        extra["filter_matched_nothing"] = True
    return True, detail, rows, OK, applied, extra


def list_payload(detail: str, rows: List[Dict[str, Any]], applied: Dict[str, Any],
                 extra: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    """THE payload — built ONCE, for the CLI and for the MCP server.

    ⛔ IT USED TO BE BUILT TWICE. `server.py` hand-copied this dict, and the only thing pinning the two
    copies together was `test_S11`, which compared three of the keys — so a drift in `running`/`expired`/
    `filters`/`source` shape was invisible while the copy's own docstring promised "identical shape". Two
    implementations of one answer is the duplication #3382 exists to remove; this is the one
    implementation, and the server calls it.
    """
    unfinished = [r for r in rows if r["state"] == "RUNNING"]
    expired = [r for r in rows if r["state"] == "EXPIRED"]
    extra = extra or {}
    return {
        "measured_at": _now(),
        "source": detail,
        "readable": True,
        "coverage": coverage(str(extra.get("source") or "none")),
        "registry_repo": registry_repo(),
        "registry_repo_source": registry_repo_source(),
        "schema": SCHEMA,
        "states": list(STATES),
        # ⛔ A FILTERED ANSWER IS LABELLED. `list --repo X` reporting `RUNNING=0` was indistinguishable
        # from a full-fleet measurement of zero — a filter-shaped false clean.
        "filters": applied,
        # ⛔ NAMED KEYS, NOT A SPLAT. `**extra` would silently overwrite `counts`/`lanes`/`filters`/
        # `coverage` the day a key name collides, and it is the same class of quiet shadowing that let the
        # two payload implementations drift apart in the first place.
        "excluded_no_host": extra.get("excluded_no_host", 0),
        "excluded_no_repo": extra.get("excluded_no_repo", 0),
        "filter_matched_nothing": bool(extra.get("filter_matched_nothing", False)),
        "counts": {s: sum(1 for r in rows if r["state"] == s) for s in STATES},
        "lanes": rows,
        # The two QUESTIONS the fleet could not ask tonight, answered directly and by name. Deriving
        # them here (once) rather than in each caller is what stops a caller inventing its own rule.
        "running": [{"lane_id": r["lane_id"], "kind": r.get("kind"), "tag": r.get("tag"),
                     "host": r.get("host"), "age_s": r["age_s"]} for r in unfinished],
        "expired": [{"lane_id": r["lane_id"], "kind": r.get("kind"), "tag": r.get("tag"),
                     "host": r.get("host"), "state_reason": r["state_reason"]} for r in expired],
        "oldest_unfinished": (None if not unfinished else {
            "lane_id": min(unfinished, key=lambda r: int(r.get("started_at") or 0))["lane_id"],
            "age_s": max(int(r["age_s"]) for r in unfinished),
        }),
    }


def cmd_list(args: argparse.Namespace) -> int:
    ok, detail, rows, code, applied, extra = collect(args)
    if not ok:
        if code == USAGE:
            sys.stderr.write("[lane-registry] %s\n" % detail)
            return code
        # ⛔ INVARIANT 1: unknown is not zero. `UNMEASURED(...)` on stdout AND a non-zero exit, so a
        # caller cannot read the absence of rows as "nothing is running". ⛔ AND WITH `--json` IT MUST
        # STILL BE JSON: the plain-text form made `list --json | jq` a PARSE ERROR instead of the
        # abstention — a documented "one object, the whole answer" surface that emitted a bare word.
        if args.json:
            sys.stdout.write(json.dumps({"readable": False, "unmeasured": "UNMEASURED(%s)" % detail,
                                         "source": detail}, indent=2, sort_keys=True) + "\n")
        else:
            sys.stdout.write("UNMEASURED(%s)\n" % detail)
        return code
    payload = list_payload(detail, rows, applied, extra)
    if args.json:
        sys.stdout.write(json.dumps(payload, indent=2, sort_keys=True) + "\n")
        return OK
    c = payload["counts"]
    sys.stdout.write("lanes: RUNNING=%d DONE=%d FAILED=%d EXPIRED=%d  (%s)\n"
                     % (c["RUNNING"], c["DONE"], c["FAILED"], c["EXPIRED"], detail))
    for r in rows:
        arts = ",".join("%s:%s" % (a.get("kind"), a.get("value")) for a in (r.get("artifacts") or []))
        sys.stdout.write("  %-9s %-52s %-6s %-8s age=%-7ss %s%s\n"
                         % (r["state"], r["lane_id"], r.get("kind") or "-", r.get("tag") or "-",
                            r["age_s"], (r.get("reason") or ""),
                            (" artifacts=" + arts) if arts else ""))
    if payload["oldest_unfinished"]:
        sys.stdout.write("oldest unfinished: %s (%ds)\n"
                         % (payload["oldest_unfinished"]["lane_id"],
                            payload["oldest_unfinished"]["age_s"]))
    return OK


def cmd_show(args: argparse.Namespace) -> int:
    ok, detail, rows, code, _applied, extra = collect(args)
    if not ok:
        if code == USAGE:
            sys.stderr.write("[lane-registry] %s\n" % detail)
            return code
        if args.json:
            sys.stdout.write(json.dumps({"readable": False, "unmeasured": "UNMEASURED(%s)" % detail,
                                         "source": detail}, indent=2, sort_keys=True) + "\n")
        else:
            sys.stdout.write("UNMEASURED(%s)\n" % detail)
        return code
    for r in rows:
        if r["lane_id"] == args.lane_id:
            if args.json:
                out = dict(r)
                # ⛔ A FOUND ROW CARRIES ITS PROVENANCE TOO. A local-only read can report a lane as
                # present while every PEER lane is invisible; without this marker the caller cannot tell
                # a complete answer from a partial one.
                out["coverage"] = coverage(str(extra.get("source") or "none"))
                out["source"] = detail
                out["measured_at"] = _now()
                out["readable"] = True            # `list --json` always carries it; `show` must too
                sys.stdout.write(json.dumps(out, indent=2, sort_keys=True) + "\n")
            else:
                for k in ("lane_id", "state", "state_reason", "host", "pid", "kind", "tag", "repo",
                          "branch", "worktree", "started_at", "heartbeat_at", "heartbeat_age_s",
                          "budget_s", "lease_until", "age_s", "reason", "exit_code", "duration_s"):
                    if k in r:
                        sys.stdout.write("%-16s %s\n" % (k, r[k]))
                sys.stdout.write("%-16s %s\n" % ("artifacts", json.dumps(r.get("artifacts") or [])))
            return OK
    # ⛔ NOT-FOUND FROM A PARTIAL READ IS NOT A VERDICT. If only this box's witness answered, an absent id
    # may simply belong to a peer — so the honest answer is UNMEASURED, not "this lane never existed".
    # ⛔ AND BOTH OF THESE MUST HONOUR `--json`. They were plain text unconditionally, so `show --json`
    # — whose most common answer is NOT-FOUND — was a PARSE ERROR for every JSON consumer. Fixing `list`
    # and leaving its sibling is the same class of half-fix the list arm was written to close.
    if coverage(str(extra.get("source") or "none")) != "shared":
        msg = ("UNMEASURED(%s) — NOT-FOUND cannot be asserted from a read that did not reach the shared "
               "registry" % detail)
        if args.json:
            sys.stdout.write(json.dumps({"readable": False, "unmeasured": msg, "source": detail},
                                        indent=2, sort_keys=True) + "\n")
        else:
            sys.stdout.write(msg + "\n")
        return UNMEASURED
    if args.json:
        sys.stdout.write(json.dumps({"not_found": args.lane_id, "readable": True,
                                     "note": "NOT-FOUND is a lookup outcome, not one of the four states",
                                     "source": detail, "measured_at": _now(),
                                     "coverage": coverage(str(extra.get("source") or "none"))},
                                    indent=2, sort_keys=True) + "\n")
    else:
        sys.stdout.write("NOT-FOUND %s (a lookup outcome, not a state) — read: %s\n"
                         % (args.lane_id, detail))
    return NOT_FOUND


# ── CLI ────────────────────────────────────────────────────────────────────────────────────────

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="lane_registry.py", description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="verb", required=True)

    def common(sp: argparse.ArgumentParser) -> None:
        sp.add_argument("--remote", default=None,
                        help="git remote name or URL (default: origin of the current checkout)")
        sp.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_S)
        sp.add_argument("--quiet", action="store_true")

    s = sub.add_parser("start", help="open a RUNNING record for a lane")
    common(s)
    s.add_argument("--kind", default="lane", help="lane|fix|chain|review|… (screened to [A-Za-z0-9-_])")
    s.add_argument("--tag", default="0", help="the issue/PR number or lane tag")
    s.add_argument("--lane-id", default=None, help="override the generated id (rarely right)")
    s.add_argument("--pid", type=int, default=None)
    s.add_argument("--repo", default=None, help="owner/name")
    s.add_argument("--branch", default=None)
    s.add_argument("--worktree", default=None)
    s.add_argument("--issue", type=int, default=None)
    s.add_argument("--attempt", type=int, default=1)
    s.add_argument("--budget", type=int, default=DEFAULT_BUDGET_S,
                   help="lease seconds (default %d = LANE_BACKSTOP_S)" % DEFAULT_BUDGET_S)
    s.set_defaults(func=cmd_start)

    b = sub.add_parser("beat", help="renew the lease (refuses a terminal record)")
    common(b)
    b.add_argument("--lane-id", required=True)
    b.add_argument("--push", action="store_true",
                   help="publish the renewed lease now (default: only when the lease is half spent)")
    b.set_defaults(func=cmd_beat)

    d = sub.add_parser("done", help="write the TERMINAL done record — artifacts REQUIRED")
    common(d)
    d.add_argument("--lane-id", required=True)
    d.add_argument("--artifact", action="append", metavar="KIND:VALUE")
    d.add_argument("--pr", default=None)
    d.add_argument("--sha", action="append")
    d.add_argument("--exit-code", type=int, default=None)
    d.set_defaults(func=cmd_done)

    f = sub.add_parser("fail", help="write the TERMINAL failed record — reason REQUIRED")
    common(f)
    f.add_argument("--lane-id", required=True)
    f.add_argument("--reason", required=True)
    f.add_argument("--artifact", action="append", metavar="KIND:VALUE")
    f.add_argument("--exit-code", type=int, default=None)
    f.set_defaults(func=cmd_fail)

    ls = sub.add_parser("list", help="every lane, with the four-state reading")
    common(ls)
    ls.add_argument("--json", action="store_true")
    ls.add_argument("--state", default=None,
                    # ⛔ NORMALISED, THEN CHECKED — the CLI used to reject `--state " RUNNING "` (no
                    # stdout, exit 2) while the MCP accepted the same value and answered, so the two
                    # surfaces disagreed on the very argument the shared `collect` was meant to unify.
                    type=lambda v: v.strip().upper(),
                    choices=list(STATES),
                    help="filter to one of the four states")
    ls.add_argument("--host", default=None)
    ls.add_argument("--repo", default=None)
    ls.set_defaults(func=cmd_list)

    sh = sub.add_parser("show", help="one lane")
    common(sh)
    sh.add_argument("--lane-id", required=True)
    sh.add_argument("--json", action="store_true")
    sh.set_defaults(func=cmd_show)
    return p


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    for path in (local_dir(),):
        try:
            os.makedirs(path, exist_ok=True)
        except OSError as exc:
            if exc.errno != errno.EEXIST:
                sys.stderr.write("[lane-registry] WARN cannot create %s: %s\n" % (path, exc))
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
