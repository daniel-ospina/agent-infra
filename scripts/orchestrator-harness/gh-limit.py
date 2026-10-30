#!/usr/bin/env python3
# gh-limit — the one layer every harness `gh` invocation passes through (#1988).
#
# WHY THIS EXISTS. Four boxes act as ONE GitHub account, so they share ONE pair of rate-limit
# buckets (REST `core` and `graphql` are separate 5,000/hr pools). Nothing serialised the calls:
# every cell, every lane, the controller and every worker issued their own requests concurrently
# and, when GitHub pushed back, NOTHING backed off — the call failed, the caller read the failure
# as "no data", and the cycle looked idle instead of limited. GitHub documents exactly two remedies
# (Best practices for using the REST API / Rate limits for the REST API) and this file implements
# both:
#
#   * SERIALISE. "Make requests serially, e.g. a queue, to avoid secondary rate limits." A delay
#     is not the fix — serialisation is. Concurrency across boxes is unavoidable (they cannot see
#     each other), but the ACCOUNT's burst becomes 4 rather than 4 x lanes.
#   * BACK OFF, in the documented order: honour `retry-after`; honour `x-ratelimit-reset` when the
#     bucket's remaining is 0; otherwise wait AT LEAST one minute and grow exponentially; throw
#     after a bounded number of attempts. Continuing to hammer while limited "may result in
#     banning the integration", and an unbounded retry turns one outage into a hang.
#
# And two of the issue's supporting requirements:
#
#   * NAME THE BUCKET. `gh api rate_limit` reporting `4999/5000` while every GraphQL call is
#     refused is the measured trap: the two pools are separate and the GraphQL path lies about its
#     own headroom. So the bucket reported is the one the FAILING CALL used, never inferred from
#     whichever counter happens to look healthy, and its reset is reported with it.
#   * CONDITIONAL REST FOR POLLING. A GET `gh api` call stores its ETag per URL and sends
#     `if-none-match` next time; a `304 Not Modified` does not count against the primary limit, so
#     a poll that changes nothing costs nothing. (GraphQL has no ETag — that is why this layer
#     targets `gh api`, and why the sweeps moved to REST.)
#   * FAIL OVER, IN BOTH DIRECTIONS. The REST adapter beside this file serves a GRAPHQL refusal over
#     REST (#1959). This file adds the other direction — the one that took the fleet down on
#     2026-10-22: `core: 5000 used / 0 remaining` beside `graphql: 4769 remaining`. The pools are
#     separate, so an exhausted `core` still has real headroom, and a read with an exact GraphQL
#     equivalent is served from it instead of waiting out a 12-minute reset. A read with NO exact
#     equivalent (branch protection has none) is REFUSED with a NAME, never answered empty.
#   * NAME THE STATE A LANE SHOULD SAY. `gh-core-exhausted resets_in=12m` replaces the sentence that
#     reads like a broken repository (“the token is invalid”, “branch protection UNREADABLE”). A
#     budget that OUR OWN polling spent is indistinguishable, from inside a lane, from GitHub being
#     down — so the layer says which one it is, in one token a caller can print verbatim.
#
# ⛔ ACCOUNT SCOPE, NOT BOX SCOPE (agent-infra#2137). The two remedies above bound what THIS BOX
# sends; they do not bound what the ACCOUNT sends. Four boxes acting as ONE account share ONE pair of
# buckets, so a per-box budget is ~4x the account's, and GitHub's SECONDARY (burst/concurrency)
# limit is enforced on the ACCOUNT. Measured 2026-10-20: `gh api rate_limit` honestly reported
# graphql ~4573/5000 while the fleet was refused — the primary counter does not predict a secondary
# limit, so a box cannot tell "the account is out" from "my box is fine". Two things follow, and
# neither needs cross-box messaging:
#
#   * PARTITION THE ACCOUNT BUDGET. GitHub's primary limit is per ACCOUNT (5,000/hr per bucket for
#     authenticated users, shared by every token and app acting for that user). A declared fleet size
#     (`GH_LIMIT_ACCOUNT_FLEET_SIZE`, default 4) divides that budget, a safety fraction
#     (`GH_LIMIT_ACCOUNT_SAFETY`, default 0.8) keeps headroom, and this box then sends at most its
#     share per window (`GH_LIMIT_ACCOUNT_WINDOW_S`, default 60 s) — 5000 x 0.8 / 4 / 60 ≈ 16/min at
#     the defaults. A partition is testable and needs no peer to be reachable.
#   * AN UNCLASSIFIED REFUSAL IS ITS OWN CLASS. `status=?` — a limit whose bucket/status could not be
#     parsed — used to be the one case that produced a FULL-WINDOW block, because the only number
#     available was a bucket reset ~43 minutes away while the refusal was secondary. It is now
#     classified `unclassified` and treated like a secondary limit: >= 1 minute with upward jitter,
#     doubling per attempt, and the classification is RECORDED. It never adopts a bucket reset as its
#     wait, because the primary counter does not predict a secondary limit.
#
# ⛔ THE RECORD IS EVIDENCE WITH A WINDOW, NOT A STATE. `last-limit` now carries `kind=` (the
# classification used), `until=` (the block window that classification justifies — never a reset for
# an unclassified/secondary refusal) and `remaining=` (what the exempt `/rate_limit` read said). The
# layer blocks a call on that marker ONLY within `until`, NEVER on a marker older than the window it
# recorded, and it REVALIDATES with one exempt REST `rate_limit` read before any long wait: if that
# bucket reports headroom, the marker is stale, it is annotated `stale=` (the age stays — the age is
# evidence) and the call proceeds. Every refusal/backoff line names its own evidence: the
# classification, the AGE of the evidence it used (`0s` when the refusal is in hand, the marker's age
# when the marker is what it waited on), the remaining count read, and the attempt number — a line
# that cannot say how old its evidence is reads the same as a live one.
#
# WHAT THIS IS NOT. It is not a retry that hides the problem. A limited call RECORDS itself — in
# `$GH_LIMIT_DIR/last-limit` (read by the controller's heartbeat) and in `events.log` — and a final
# failure says so on stderr in the API's own terms. A cycle that was limited never looks like a
# cycle that was idle.
#
# AND IT IS NOT ONLY A QUEUE (#2243). Serialising decides WHO GOES NEXT; it does not decide whether
# the work is worth doing twice. Thirteen lanes on one box asking for the SAME read queued thirteen
# times for one answer that was already known after the first (measured: 0.676 s at 3 lane processes,
# 63 s at 13, while `curl /rate_limit` took 0.091 s on 4658/5000 quota — the queue was ours). So
# identical concurrent READS are now COALESCED (single flight, `single_flight` below): one in-flight
# load per normalised request, waiters share its result — or its failure — under a bounded wait, and
# a waiter that exceeds the bound gets a distinct `busy` outcome naming the holder's age. #2005's
# "one request in flight per box" is COMPLETED by this, not reversed: there is still exactly one
# request in flight, and the `flock` is still what guarantees it.
#
# ⛔ THE STREAMS ARE SACRED. On a call that eventually SUCCEEDS this helper must be invisible: the
# child's stdout and stderr are replayed byte for byte and nothing else is written. That is not
# politeness — the harness's callers merge stderr into stdout and then PARSE it (`gh-rest/gh` does
# `raw="$(… 2>&1)"` and projects `$raw` through jq), so an extra stderr line on a successful call
# would turn a good answer into `projection failed`. Retry announcements therefore go to
# `events.log`; only a FINAL FAILURE (where the call is already non-zero and the caller already
# prints stderr) is written to stderr.
#
# USAGE (both entry points call this; neither reimplements it)
#   gh-limit.py --real-gh <path>   -- <gh argv…>     # the Mac REST adapter resolves gh itself
#   gh-limit.py --self <this shim> -- <gh argv…>     # the cell-side wrapper (`--self` is skipped
#                                                    # while walking PATH, so it cannot exec itself)

import base64
import binascii
import fcntl
import hashlib
import errno
import io
import json
import os
import random
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

REENTRANCY_ENV = "GH_LIMIT_LOCK_HELD"

# ── configuration (env is the operator's seam; tests replace the CLOCK and the SLEEP, not the logic) ──
def cfg(name, default):
    v = os.environ.get(name)
    return default if v is None or v == "" else v


def cfg_float(name, default):
    try:
        return float(cfg(name, default))
    except (TypeError, ValueError):
        return float(default)


def _finite(name, default):
    """A float that CANNOT be nan/inf. `float()` accepts both, and every consumer of these knobs
    dies differently on them: `nan` makes `int(x)` raise (a traceback instead of gh's message), and
    `inf` disables the bound it is compared against — `LOCK_TIMEOUT=inf` makes the lock wait
    unbounded, `MAX_WAIT=nan` disables the fail-fast, `MUTATION_GAP=inf` raises OverflowError in
    `time.sleep`. One typo in the cell's keys.env would stop every gh call on the box."""
    v = cfg_float(name, default)
    if v != v or v in (float("inf"), float("-inf")):
        return float(default)
    return v


def cfg_secs(name, default, lo, hi):
    """A bounded SECONDS knob (fractional is meaningful: a 1.0 s mutation gap)."""
    return max(float(lo), min(_finite(name, default), float(hi)))


def cfg_int(name, default, lo, hi):
    """A bounded integer knob that CANNOT raise at import.

    ⛔ `int(cfg_float(…))` dies on values `float()` accepts: `nan` raises ValueError and `inf`
    (or `1e400`) raises OverflowError. This module is the interposer under EVERY gh call on the
    box, so one typo'd knob would not mis-tune the layer — it would stop every gh call on that
    box with a traceback, which is the opposite of "a degraded state dir must not fail a gh
    call". Out-of-range values are clamped to the documented bound rather than honoured, so the
    "never an infinite retry" promise cannot be disabled from the environment either."""
    v = _finite(name, default)
    return max(lo, min(int(v), hi))


MAX_ATTEMPTS = cfg_int("GH_LIMIT_MAX_ATTEMPTS", 4, 1, 10)      # 4 ATTEMPTS in total, then fail (a count, not a retry count)
BASE_WAIT = cfg_secs("GH_LIMIT_BASE_WAIT", 60, 60, 3600)          # "wait at least one minute"
MAX_WAIT = cfg_secs("GH_LIMIT_MAX_WAIT", 300, 1, 3600)           # a single in-call wait bound
LOCK_TIMEOUT = cfg_secs("GH_LIMIT_LOCK_TIMEOUT", 600, 1, 3600)
MUTATION_GAP = cfg_secs("GH_LIMIT_MUTATION_GAP", 1.0, 1.0, 60)     # ">= 1 second between mutations"
# 1 = never sleep in-process: report the limit and return at once. For a caller with its OWN
# subprocess timeout and its own deferral (the telemetry readers, bounded by the heartbeat at 90/120 s)
# an in-call 60-420 s wait is not patience, it is a timeout: the caller is killed before the layer can
# say what happened, so the box reports STALL/UNKNOWN instead of the RATE-LIMITED verdict it has.
NO_WAIT = cfg_int("GH_LIMIT_NO_WAIT", 0, 0, 1)
# The lock budget under NO_WAIT — small enough to fit inside a 90 s caller alongside one request.
NO_WAIT_LOCK_S = cfg_secs("GH_LIMIT_NO_WAIT_LOCK_S", 5.0, 1.0, 600)

# ── ACCOUNT SCOPE (agent-infra#2137): the budget is the ACCOUNT's, so a box must assume its peers exist ──
# The declared fleet size is an ENV VALUE, not a measurement: boxes cannot see each other, and a
# partition derived from an unreachable peer would be unavailable exactly when it is needed. A
# declaration is conservative in the safe direction (too few boxes => too generous a share => the
# account limit is hit, which the backoff below handles; too many => a box is slower than it needs to
# be, which costs latency, not correctness).
ACCOUNT_FLEET_SIZE = cfg_int("GH_LIMIT_ACCOUNT_FLEET_SIZE", 4, 1, 64)
ACCOUNT_BUDGET_PER_HOUR = cfg_int("GH_LIMIT_ACCOUNT_BUDGET_PER_HOUR", 5000, 60, 100000)
ACCOUNT_SAFETY = max(0.1, min(_finite("GH_LIMIT_ACCOUNT_SAFETY", 0.8), 1.0))
ACCOUNT_WINDOW_S = cfg_secs("GH_LIMIT_ACCOUNT_WINDOW_S", 60, 10, 3600)
# WHICH buckets are partitioned. `graphql` by default: that is the measured exhaustion (#1762/#1939)
# and the bucket the heartbeat's ~513-call refresh bursts use. `core` is deliberately NOT paced by
# default — #1962/#2137 move the hot reads ONTO REST, so pacing REST here would push the fleet back
# onto the bucket that is already refusing. An operator who measures core pressure opts in with
# `GH_LIMIT_ACCOUNT_PARTITION_BUCKETS=graphql,core`.
ACCOUNT_PARTITION_BUCKETS = tuple(
    b.strip().lower() for b in cfg("GH_LIMIT_ACCOUNT_PARTITION_BUCKETS", "graphql").split(",") if b.strip())
# A marker older than this is not evidence about now (matches `orch-loop.sh`'s GH_LIMIT_STALE_S).
MARKER_MAX_AGE = cfg_secs("GH_LIMIT_MARKER_MAX_AGE", 900, 60, 86400)
# A wait longer than this is worth ONE exempt REST read before committing to it (requirement 3).
GATE_REVALIDATE_S = cfg_secs("GH_LIMIT_GATE_REVALIDATE_S", 30, 1, 600)
CACHE_MAX_BODY = 1024 * 1024
CACHE_MAX_BYTES = cfg_int("GH_LIMIT_CACHE_MAX_BYTES", 64 * 1024 * 1024, 1024, 1 << 30)  # whole cache
CACHE_MAX_ENTRIES = cfg_int("GH_LIMIT_CACHE_MAX_ENTRIES", 500, 1, 100000)
EVENTS_MAX_BYTES = 256 * 1024


_STATE = {"dir": None}


def _dead_writer(fp):
    """True when a `.tmp-<name>-<pid>` staging file's writer is gone (or the name says nothing and
    the file is old). Used by BOTH reapers — the state root and the ETag directory — because reaping
    a LIVE writer's file between its `open` and its `replace` silently loses the write."""
    n = os.path.basename(fp)
    try:
        pid = int(n.rsplit("-", 1)[1])
    except (IndexError, ValueError):
        pid = None
    # ⛔ `int()` IS ARBITRARY-PRECISION AND `os.kill` IS NOT: a junk name like
    # `.tmp-last-limit-<24 digits>` raised OverflowError, which `except OSError` cannot catch — one
    # bad filename would have failed EVERY gh call on the box with a traceback (review round 5).
    if pid is not None and not (0 < pid < 1 << 22):
        pid = None                      # junk name: fall through to the age test
    if pid and pid != os.getpid():
        try:
            os.kill(pid, 0)
            return False                # alive: leave it alone
        except OverflowError:
            pass
        except OSError as exc:
            if exc.errno == errno.EPERM:
                return False            # exists, other uid
        return True                     # definitely gone
    if pid:
        return False                    # OUR OWN pid while it is still writing
    try:
        return (time.time() - os.path.getmtime(fp)) > 600
    except OSError:
        return True


def state_dir():
    """The per-box state root: ONE lock, ONE etag cache, ONE limit record.

    Per BOX, not per process — that is the whole point of the single-flight lock. `$HOME` is the
    one path every harness process on a box agrees on (the daemon, its lanes and its workers all
    inherit it), and `GH_LIMIT_DIR` pins it for tests and for a box with an odd HOME."""
    if _STATE["dir"]:
        return _STATE["dir"]
    d = cfg("GH_LIMIT_DIR", "")
    degraded = False
    if not d:
        base = cfg("XDG_CACHE_HOME", "") or os.path.join(os.path.expanduser("~"), ".cache")
        d = os.path.join(base, "gh-limit")
    try:
        os.makedirs(d, mode=0o700, exist_ok=True)
        # ⛔ `exists_ok=True` SAYS NOTHING ABOUT WRITABILITY. A dir that exists but is not writable
        # by this uid (one root-run of the harness, a `chmod`, a disk-full remount) passed here and
        # then lost EVERY channel at once: no lock (so the box was silently UNSERIALISED), and
        # `log_event`/`write_state` fail into the same unwritable dir, so nothing said so — the exact
        # state the degraded branch exists to prevent (review round 8). Probe once, then take the
        # same stable-per-user fallback.
        probe = os.path.join(d, ".tmp-wprobe-%d" % os.getpid())   # a name the reaper understands
        with open(probe, "wb"):
            pass
        os.unlink(probe)
    except OSError:
        # A degraded state dir must not fail a gh call. ⛔ It must not silently UNSERIALISE the box
        # either: a per-process temp dir shares no lock with the next process, so "one call in
        # flight" would be gone with nothing anywhere saying so (review round 1). The fallback is
        # therefore STABLE PER USER — the lock, the ETag cache and `last-limit` are still shared by
        # every process of this uid — and the degradation is written to the evidence log, which now
        # lands in the fallback dir.
        d = os.path.join(tempfile.gettempdir(), "gh-limit-%d" % os.getuid())
        try:
            os.makedirs(d, mode=0o700, exist_ok=True)
            # ⛔ A PREDICTABLE NAME IN A WORLD-WRITABLE DIR IS ONLY OURS IF WE OWN IT. Adopting a
            # directory another uid created would hand them the lock, `last-limit` and every cached
            # API body. (Narrow — launchd gives each user a private TMPDIR — but one stat closes it.)
            if os.stat(d).st_uid != os.getuid():
                raise OSError("not owned by this uid")
            os.chmod(d, 0o700)
            degraded = True
        except OSError:
            d = tempfile.mkdtemp(prefix="gh-limit-")
            degraded = True
    _STATE["dir"] = d
    # ⛔ REAP ABANDONED STAGING FILES. `write_state` writes `.tmp-<name>-<pid>` and renames it; a
    # helper killed between the two (a bounded caller's timeout now kills it, since it is `exec`'d)
    # leaves one behind and nothing else sweeps the state root. Once per process, because this runs
    # under EVERY gh call.
    try:
        now = time.time()
        for n in os.listdir(d):
            if not n.startswith(".tmp-"):
                continue
            fp = os.path.join(d, n)
            # ⛔ ONLY A DEAD WRITER'S STAGING FILE. `write_state` stages `.tmp-<name>-<pid>` and
            # renames it; reaping on sight deleted a CONCURRENT live process's file between its
            # `open` and its `replace`, i.e. it could lose the very `last-limit` record this file
            # exists to write (found in review round 5). A live pid is left alone; a name with no
            # parseable pid is only reaped once it is old enough that no writer can be coming back.
            if not _dead_writer(fp):
                continue
            try:
                os.unlink(fp)
            except OSError:
                pass
    except OSError:
        pass
    if degraded:
        log_event("WARNING primary state dir unusable — using %s. Serialisation holds between the "
                  "processes of this user; the controller's heartbeat CANNOT see this last-limit." % d)
    return d


# ── the clock and the sleep are injectable SOLELY so the documented waits can be asserted ────────
def clock():
    cmd = os.environ.get("GH_LIMIT_NOW_CMD")
    if not cmd:
        return time.time()
    r = subprocess.run(shlex.split(cmd), capture_output=True, text=True)
    try:
        return float(r.stdout.strip())
    except ValueError:
        # A configured-but-broken clock seam must be LOUD: silently falling back to the wall clock
        # would make a fake-clock test measure real time and pass for the wrong reason.
        sys.stderr.write("gh-limit: GH_LIMIT_NOW_CMD did not print a number (%r) — refusing to guess the time\n"
                         % (r.stdout.strip()[:60],))
        raise SystemExit(3)


def pause(seconds):
    if seconds <= 0:
        return
    cmd = os.environ.get("GH_LIMIT_SLEEP_CMD")
    if not cmd:
        time.sleep(seconds)
        return
    arg = ("%d" % round(seconds)) if abs(seconds - round(seconds)) < 1e-6 else ("%.3f" % seconds)
    r = subprocess.run(shlex.split(cmd) + [arg], capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write("gh-limit: GH_LIMIT_SLEEP_CMD failed (%s) — refusing to continue as if we had waited\n"
                         % (r.stderr.strip()[:120] or "rc=%d" % r.returncode))
        raise SystemExit(3)


# ── state files: written atomically, read defensively ───────────────────────────────────────────
def write_state(name, text):
    d = state_dir()
    tmp = os.path.join(d, ".tmp-%s-%d" % (name, os.getpid()))
    try:
        with open(tmp, "w") as fh:
            fh.write(text if text.endswith("\n") else text + "\n")
        os.replace(tmp, os.path.join(d, name))
        return True
    except OSError as exc:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        # ⛔ EVERY OTHER DEGRADATION IN THIS FILE IS ANNOUNCED (the lock, the state dir); the RECORD
        # was the exception. Losing it is exactly "a limited box looks merely slow" — the issue's
        # non-goal — so a failed write says so, and the caller still proceeds (a record is evidence,
        # not the answer).
        log_event("WARNING cannot write %s (%s) — the %s record was NOT updated"
                  % (os.path.join(state_dir(), name), exc, name))
        # ⛔ `events.log` LIVES IN THE SAME DIRECTORY. When the failure IS the directory (a chmod, a
        # disk-full remount — the very classes the probe in `state_dir()` cannot prevent), the
        # announcement was written into the failure and lost, so the promise "a failed write says so"
        # said nothing. stderr cannot be silenced that way (review round 9).
        sys.stderr.write("gh-limit: WARNING cannot write the %s record in %s (%s) — a rate-limited "
                         "box may not report it until the next refused call\n"
                         % (name, d, exc))
        return False


def record_limit(bucket, reset, attempts, waited, status, kind="unclassified", until=None, remaining=None):
    """The durable record the controller's heartbeat reads (`gh=<bucket> reset=<epoch>`).

    ⛔ IT CARRIES ITS OWN EVIDENCE AND ITS OWN WINDOW (#2137). `kind=` is the classification this
    observation used, `until=` is the block window that classification justifies, and `remaining=` is
    what the exempt `/rate_limit` read said. Before this, the record carried the BUCKET RESET and
    nothing else — so a refusal classified `status=?` (secondary, ~1 minute) wrote a reset ~43
    minutes away, and every consumer that trusted it blocked the box for the full window. A reader
    must block until `until`, never until `reset`. The older fields stay where they were and keep
    their meaning, so `orch-loop.sh`'s token (and any older reader) still parses the line."""
    write_state("last-limit",
                "at=%d bucket=%s reset=%s attempts=%d waited=%d status=%s kind=%s until=%s remaining=%s"
                % (int(clock()), bucket, ("%d" % reset) if reset else "0", attempts, int(waited),
                   status if status is not None else "?", kind or "unclassified",
                   ("%d" % until) if until else "0",
                   ("%d" % remaining) if remaining is not None else "?"))


def marker_until(kind, reset, wait, now):
    """The BLOCK WINDOW an observation justifies — and the whole point of requirement 2/5.

    A PRIMARY exhaustion is honest about the full window: `remaining == 0` and a reset in the future
    is exactly "this bucket is out until then", and the docs say not to call again before it. A
    SECONDARY or UNCLASSIFIED refusal is not: the primary counter does not predict it (documented,
    and measured — graphql ~4573/5000 while refused), so its reset is NOT a recovery time. Its window
    is the wait this layer itself will honour, capped at the documented one-minute floor, so a
    `status=?` observation can never become an hour-long box-wide block again."""
    if kind == "primary" and reset and reset > now:
        return int(reset)
    # ⛔ A `retry-after` WINDOW IS THE SERVER'S OWN DELAY, NOT THE FLOOR. `plan_wait` honours that
    # header exactly (bounded by MAX_WAIT), so capping the RECORD at the one-minute floor published a
    # window shorter than the one this process was obeying: with `Retry-After: 300` the box slept 300 s
    # while its own marker told every peer client it was free again in 60 — 240 s of peer traffic inside
    # a cool-down the layer itself respected.
    if kind == "retry-after" and wait and wait > 0:
        return int(now + min(float(wait), float(MAX_WAIT)))
    if wait and wait > 0:
        return int(now + min(float(wait), float(BASE_WAIT)))
    return int(now + BASE_WAIT)


def record_window(limit, kind, reset, wait, now):
    """The window a refusal justifies, for the paths that have no `plan_wait` result to hand.

    ⛔ ONE EXPRESSION, THREE CALL SITES. The give-up and NO_WAIT paths pass `wait=None`, so a
    `retry-after` refusal recorded the 60 s floor while `plan_wait` was obeying the server's delay —
    publishing a window shorter than the one the layer honoured. `limit.retry_after` is the only wait
    those paths can imply, and it is exactly what `plan_wait` would have used."""
    if wait is None and kind == "retry-after" and limit.retry_after:
        wait = float(limit.retry_after)
    return marker_until(kind, reset, wait, now)


def _parse_marker(raw):
    """`key=value …` text into a dict (the on-disk `last-limit` shape), or None when unparsable."""
    try:
        parts = dict(kv.split("=", 1) for kv in raw.split() if "=" in kv)
    except ValueError:
        return None
    return parts or None


def read_marker():
    """`last-limit` as a dict, or None. Read defensively: a torn/dir/corrupt record is not an error."""
    try:
        with open(os.path.join(state_dir(), "last-limit")) as fh:
            raw = fh.read()
    except OSError:
        return None
    return _parse_marker(raw)


def marker_window(marker):
    """(kind, until_epoch) — the classification the marker recorded and the window it justifies.

    ⛔ A MARKER WITH NO `kind=` IS `unclassified`, NEVER `primary`. Records written before this change
    carry `reset=` and nothing else, and the measured stale marker was exactly that shape with a
    reset ~43 min ahead. Deriving a primary window from it would restore the full-window block for
    every marker already on disk, so the migration default is the bounded one."""
    kind = (marker.get("kind") or "unclassified").strip()
    at = as_int(marker.get("at"))
    until = as_int(marker.get("until"))
    if until and until > 0:
        return kind, until
    # No window recorded (a legacy marker): bound it by what this layer will actually wait.
    if at is None:
        return kind, 0
    return kind, marker_until(kind, as_int(marker.get("reset")), BASE_WAIT, at)


def marker_age(marker):
    """Seconds since the marker was written, or None. The AGE is part of every line that uses it."""
    at = as_int(marker.get("at")) if marker else None
    return None if at is None else int(clock()) - at


def mark_marker_stale(remaining, why, expect=None):
    """Annotate a marker whose own evidence contradicts it. ⛔ ANNOTATE, NEVER DELETE.

    The age is the evidence an operator needs ("refused 4 minutes ago, probe says 4573 left"), so the
    record keeps its `at=` and gains `stale=`/`reval_remaining=`/`why=`. Deleting it would make the
    next reader unable to tell "no limit happened" from "a limit happened and was cleared".

    ⛔ AND IT DOES **NOT** WRITE `recovered=`. That field is the cycle token's "this limit was read
    past" mark, and the only honest source of it is a REAL REQUEST THAT SUCCEEDED (`record_recovery`).
    A `/rate_limit` read is exempt from the primary limit — measured at 4999/5000 while every GraphQL
    call was refused — so deriving `recovered=` from it would make a box that is still being refused
    report itself recovered, which is the false pass this whole layer exists to prevent. The gate
    suppresses on `stale=`, so nothing needs that field."""
    path = os.path.join(state_dir(), "last-limit")
    try:
        with open(path) as fh:
            cur = fh.read().strip()
    except OSError:
        return False
    if not cur or "stale=" in cur:
        return False
    # ⛔ ANNOTATE ONLY THE RECORD WE READ. `record_limit` writes `last-limit` OUTSIDE the box lock (a
    # refusal must not queue behind a sleeping gate), so between this gate's read and this write a
    # concurrent client can have replaced the file — with another bucket's marker, or with a FRESH
    # genuine refusal whose `until` is a real window. Stamping `stale=` on that record would clear a
    # block that must hold, and the gate suppresses on `stale=` for good, so the drop would be silent
    # and permanent (fail-open). Identity is `at` + `bucket` + `kind`: same observation, same record.
    if expect is not None:
        now_rec = _parse_marker(cur) or {}
        if (as_int(now_rec.get("at")), now_rec.get("bucket"), now_rec.get("kind")) != \
           (as_int(expect.get("at")), expect.get("bucket"), expect.get("kind")):
            log_event("marker-gate: NOT annotating last-limit — it was replaced under me (read at=%s, found at=%s)"
                      % (expect.get("at"), now_rec.get("at")))
            return False
    now = int(clock())
    extra = " stale=%d reval_remaining=%s why=%s" % (now, ("%d" % remaining) if remaining is not None else "?", why)
    return write_state("last-limit", cur + extra)


def record_recovery(bucket):
    """A call on `bucket` SUCCEEDED after a limit: keep the observation, mark it recovered.

    ⛔ A RECORD IS NOT A STATE. `last-limit` outlives the process that wrote it, so without this a
    one-off limit kept the heartbeat printing `gh=rate_limited(bucket=graphql reset=<past>)` for 15
    minutes while every call in the same line's window was succeeding — a healthy box asserting it is
    limited, which trains an operator to ignore the token. Append-only: the same file, one line, the
    record it annotates untouched for a reader that only wants `at`/`bucket`/`reset`.

    ⛔ AND IT IS BUCKET-SCOPED. The two pools are separate: a REST success proves nothing about a
    GraphQL limit, and marking it recovered would report the opposite of the truth on the one line an
    operator reads (while every GraphQL call is still refused)."""
    path = os.path.join(state_dir(), "last-limit")
    try:
        with open(path) as fh:
            cur = fh.read().strip()
    except OSError:
        return
    if not cur or "recovered=" in cur:
        return
    rec_bucket = next((kv.split("=", 1)[1] for kv in cur.split() if kv.startswith("bucket=")), "")
    if rec_bucket and rec_bucket != bucket:
        return
    write_state("last-limit", "%s recovered=%d" % (cur, int(clock())))


def recorded_reset(bucket):
    """The reset the LAST observation of THIS bucket carried, or None.

    ⛔ SO THE GIVE-UP LINE CAN NAME A RESET WITHOUT SPENDING A REQUEST. The final attempt is checked
    before `plan_wait` (which may probe `/rate_limit`), so the refused response's own headers are all
    it has — but an earlier attempt in the same call already probed and recorded one."""
    try:
        with open(os.path.join(state_dir(), "last-limit")) as fh:
            parts = dict(kv.split("=", 1) for kv in fh.read().split() if "=" in kv)
    except (OSError, ValueError):
        return None
    if parts.get("bucket") != bucket:
        return None
    return as_int(parts.get("reset"))


def log_event(line):
    """Append-only evidence, bounded. This is where a RETRY announces itself."""
    try:
        p = os.path.join(state_dir(), "events.log")
        if os.path.exists(p) and os.path.getsize(p) > EVENTS_MAX_BYTES:
            with open(p, "r", errors="replace") as fh:
                keep = fh.readlines()[-500:]
            with open(p, "w") as fh:
                fh.writelines(keep)
        with open(p, "a") as fh:
            fh.write("%d %s\n" % (int(clock()), line))
    except OSError:
        pass


# ── single flight ───────────────────────────────────────────────────────────────────────────────
# ⛔ THIS PROCESS'S CUMULATIVE LOCK WAIT. `NO_WAIT` bounds the time a bounded caller may spend in the
# lock queue for the WHOLE call, not per acquire: `_dispatch` takes the lock twice on the floor path
# (the exempt meter probe, then the call), and a per-acquire budget made that two budgets. Read and
# written only by `acquire_lock`, reset never — a process is one call.
_LOCK_WAIT_SPENT = [0.0]


def acquire_lock(strict=False):
    """One gh call in flight per box. Returns the fd to hold (or None when re-entrant/unavailable).

    ⛔ `strict=True` IS FOR THE METER PROBES ONLY (#2342 review P1). The permissive path deliberately
    PROCEEDS UNSERIALISED once its bound expires — that is right for an ordinary call, whose caller
    would otherwise be killed inside the layer — but it returns a real fd anyway, so `if lock is None`
    never fires for contention. A probe that rides the permissive path therefore issues a request the
    file says it never issues unserialised, past the very bound NO_WAIT exists to keep. In strict mode
    a wait that expires (or a lock this process cannot use) returns None, and the caller skips the
    request entirely: no snapshot is a legitimate answer, an unserialised meter call is not.

    `flock` is a KERNEL lock, so a holder that dies (killed worker, crashed lane) releases it —
    there is no stale-lock state to reap. `flock(1)` is NOT portable to macOS, which is why this
    is `fcntl` and not a shell `flock`."""
    if os.environ.get(REENTRANCY_ENV):      # a gh child that itself runs a harness script: no deadlock
        return None
    path = os.path.join(state_dir(), "gh.lock")
    try:
        fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
    except OSError as exc:
        # ⛔ NOT SILENTLY. This is the same failure class as the timeout below — the box is fully
        # UNSERIALISED — and returning None quietly left events.log and the heartbeat reporting a
        # healthy serialised box (ENOSPC/EDQUOT on O_CREAT, EMFILE/ENFILE under fd pressure, or a
        # lock the /tmp fallback left owned by another uid).
        log_event("WARNING cannot open %s (%s) — proceeding UNSERIALISED" % (path, exc))
        return None
    # ⛔ A BOUNDED CALLER MUST NOT DIE IN THE QUEUE. `GH_LIMIT_NO_WAIT` bounds the BACKOFF, and the
    # lock wait is the other wait this layer imposes: the default 600 s outlives every caller that has
    # its own subprocess bound (the heartbeat's 90 s refresh), so a busy box turned a rate-limit
    # verdict into a silent timeout — the same non-goal, reached from the lock. Proceed UNSERIALISED
    # after NO_WAIT_LOCK_S and say so, rather than being killed mid-wait with no record at all.
    #
    # ⛔ AND THE NO_WAIT BUDGET IS PER PROCESS, NOT PER ACQUIRE (#2342 review, the merge regression).
    # `_dispatch` takes this lock TWICE on the floor path — once for the exempt meter probe and once
    # for the call itself — so a per-acquire budget DOUBLED the wait a bounded caller imposed on
    # itself (measured: 2 x NO_WAIT_LOCK_S = 10 s, against a suite bound of `<= 10` s and against every
    # caller that budgeted one 5 s wait). The second acquire sees what the first one spent: a caller
    # whose lock budget is gone proceeds UNSERIALISED AT ONCE (the same documented fallback) instead of
    # paying the budget again.
    budget = min(LOCK_TIMEOUT, NO_WAIT_LOCK_S) if NO_WAIT else LOCK_TIMEOUT
    budget = max(0.0, budget - _LOCK_WAIT_SPENT[0])
    _wait_start = time.monotonic()
    deadline = _wait_start + budget           # real monotonic: the fake clock is for BACKOFF
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            _LOCK_WAIT_SPENT[0] += time.monotonic() - _wait_start
            break
        except OSError as exc:
            if exc.errno not in (errno.EWOULDBLOCK, errno.EAGAIN, errno.EACCES):
                # "the lock is held" is the ONLY reason to wait. Anything else (EOPNOTSUPP/ENOLCK on a
                # filesystem without flock — SMB/CIFS, some FUSE mounts) would spin here for the full
                # LOCK_TIMEOUT on EVERY gh call and then proceed unserialised anyway: a 10-minute
                # stall on the box that looks like a slow network.
                _LOCK_WAIT_SPENT[0] += time.monotonic() - _wait_start
                log_event("WARNING gh.lock unusable (%s) — proceeding UNSERIALISED" % exc)
                if strict:
                    try:
                        os.close(fd)
                    except OSError:
                        pass
                    return None
                break
            if time.monotonic() >= deadline:
                # Bounded, and announced in the evidence log rather than blocking for ever: an
                # unbounded wait behind one slow gh call would park the whole box's merge sweep.
                _LOCK_WAIT_SPENT[0] += time.monotonic() - _wait_start
                log_event("WARNING gh.lock not acquired within %ds — proceeding UNSERIALISED" % int(budget))
                if strict:
                    try:
                        os.close(fd)
                    except OSError:
                        pass
                    return None            # strict callers must NOT issue an unserialised request
                break
            time.sleep(0.02)
    os.set_inheritable(fd, False)
    return fd


def release_lock(fd):
    if fd is None:
        return
    try:
        fcntl.flock(fd, fcntl.LOCK_UN)
    except OSError:
        pass
    try:
        os.close(fd)
    except OSError:
        pass


# ── the ACCOUNT partition (agent-infra#2137, requirement 1) ────────────────────────────────────
def account_share():
    """This box's share of the ACCOUNT's hourly budget, as calls per window.

    GitHub's primary limit is per ACCOUNT, not per machine: a personal access token, an OAuth app and
    a GitHub App acting for the same user all draw on the same 5,000/hr bucket ("All of these requests
    count towards your personal rate limit of 5,000 requests per hour"). Four boxes therefore act as
    ONE client of a 5,000/hr budget, and bounding each box at 5,000/hr bounds the account at 20,000/hr
    — four times what it has. This is the partition: budget x safety / fleet, per window.

    ⛔ THE FLOOR IS 1, NOT 0. A share that rounds to zero would refuse EVERY call on a box and turn a
    conservative configuration into a dead harness; one call per window is slow, and slow is
    recoverable. The knob's value is a DECLARATION (`GH_LIMIT_ACCOUNT_FLEET_SIZE`), not a measurement:
    a peer that cannot be reached is still a peer spending the same budget."""
    per_min = (float(ACCOUNT_BUDGET_PER_HOUR) * float(ACCOUNT_SAFETY)
               / float(ACCOUNT_FLEET_SIZE) / 60.0)
    per_window = max(1, int(per_min * float(ACCOUNT_WINDOW_S) / 60.0))
    return {"fleet": ACCOUNT_FLEET_SIZE, "budget": ACCOUNT_BUDGET_PER_HOUR,
            "safety": ACCOUNT_SAFETY, "window": int(ACCOUNT_WINDOW_S),
            "per_min": per_min, "per_window": per_window}


def _budget_file(bucket):
    return "budget-%s" % re.sub(r"[^a-z0-9]", "", str(bucket).lower() or "core")


def _budget_take(bucket, now, cap, window):
    """Record one slot in this box's sliding window, or report when the next one frees up.

    Called under the box lock: the window file is shared by every process of this uid on this box, so
    a read-modify-write outside the lock would let N callers each see "one slot left" and take it
    (measured shape: the same defect the mutation stamp had). Returns (allowed, wait_seconds, used)."""
    path = os.path.join(state_dir(), _budget_file(bucket))
    try:
        with open(path) as fh:
            stamps = [int(x) for x in fh.read().split() if x.strip().lstrip("-").isdigit()]
    except (OSError, ValueError):
        stamps = []
    cut = now - window
    # ⛔ LOWER *AND* UPPER BOUND. A stamp from the FUTURE is invalid by construction (a clock that
    # stepped back: NTP, a VM resume — the same class `last-mutation` guards), and honouring one made
    # `oldest + window - now` a huge number, i.e. every call refused with `rc 75` until wall-clock
    # caught up. Future stamps are DROPPED, not believed.
    stamps = sorted(s for s in stamps if cut < s <= now)
    if len(stamps) < cap:
        stamps.append(int(now))
        write_state(_budget_file(bucket), "\n".join("%d" % s for s in stamps) + "\n")
        return True, 0.0, len(stamps)
    # The window is full: the next slot frees when the OLDEST entry leaves it.
    return False, max(1.0, float(stamps[0] + window - now)), len(stamps)


def record_budget(bucket, next_slot, share):
    """A durable record of a LOCAL budget refusal, kept OUT of `last-limit`.

    ⛔ SEPARATE FILE ON PURPOSE. `last-limit` is what the heartbeat prints as
    `gh=rate_limited(...)`, so writing a partition refusal there would publish OUR refusal as GitHub's
    -- the false attribution that the local-refusal rule exists to prevent. This file is the evidence
    an operator needs to see why a box is quiet (`next_slot`, the share it enforced, the declared
    fleet), and `events.log` carries the same line in sequence."""
    write_state("last-budget",
                "at=%d bucket=%s next_slot=%ds per_window=%d window=%ds fleet=%d budget=%d/hr safety=%.2f"
                % (int(clock()), bucket, int(next_slot), share["per_window"], share["window"],
                   share["fleet"], share["budget"], share["safety"]))


def _overdraw_once(bucket, now, window):
    """True for the FIRST over-share call in the current window, so the overdraw line is evidence
    rather than a flood.

    ⛔ WHY THIS EXISTS. The heartbeat's refresh is ~513 graphql calls in one bounded run with
    `GH_LIMIT_NO_WAIT=1` (the file's own P9 reasoning). Against a 16-call window share that is ~497
    over-share calls; one line each would cross `EVENTS_MAX_BYTES` mid-run, and from then on
    `log_event` rewrites the file to its last 500 lines on EVERY call — so the log would converge to
    100% overdraw lines and evict every refusal, probe and marker decision this layer exists to keep.
    The overdraw is still VISIBLE (once per window per bucket); it just cannot eat the record."""
    name = _budget_file(bucket) + ".over"
    try:
        with open(os.path.join(state_dir(), name)) as fh:
            last = int((fh.read() or "0").split()[0])
    except (OSError, ValueError, IndexError):
        last = 0
    if last and 0 <= now - last < window:
        return False
    write_state(name, "%d" % int(now))
    return True


def budget_gate(bucket, now):
    """Seconds to wait before sending, or 0.0 when a slot was taken for THIS send.

    ⛔ A BOUNDED CALLER IS NOT PARKED. `GH_LIMIT_NO_WAIT` exists because its caller has its own
    subprocess bound (the heartbeat's 90 s refresh); spending that bound in a queue here would turn a
    rate-limit verdict into a timeout — the failure #2137's NO_WAIT half exists to prevent. Such a
    caller proceeds and the OVERDRAW is recorded, so the partition is enforced for every caller that
    can wait and the one class that cannot is visible instead of silent."""
    if bucket not in ACCOUNT_PARTITION_BUCKETS:
        return 0.0
    share = account_share()
    lock = acquire_lock()
    try:
        allowed, wait, used = _budget_take(bucket, now, share["per_window"], share["window"])
    finally:
        release_lock(lock)
    if allowed:
        if used == share["per_window"]:
            log_event("account budget: %s at its share (%d/%d per %ds, fleet=%d budget=%d/hr safety=%.2f)"
                      % (bucket, used, share["per_window"], share["window"], share["fleet"],
                         share["budget"], share["safety"]))
        return 0.0
    if NO_WAIT:
        if _overdraw_once(bucket, now, share["window"]):
            log_event("account budget: %s OVER the box's share (%d/%d per %ds) — NO_WAIT caller proceeds over the "
                      "partition (it cannot be paced without outliving its own bound); further overdraw in "
                      "this window is not repeated here"
                      % (bucket, used, share["per_window"], share["window"]))
        return 0.0
    return wait


def marker_gate(gh_argv, real_gh, now):
    """The ACCOUNT view shared by every client on this box: may this call be sent at all?

    Returns the seconds waited (0.0 = proceed). This is the half that makes an observation on ONE box
    useful to every other client on it: a refusal writes `until=` and the box's next calls wait out
    that window instead of each spending four attempts to discover the same thing.

    ⛔ FOUR BOUNDS, EACH ONE CLOSING A MEASURED FAILURE:
      1. only within `until` — the window the CLASSIFICATION justifies, never the bucket reset for an
         unclassified/secondary refusal (that is the 43-minute block that blinded the beat);
      2. never on a marker OLDER than the window it recorded, nor older than `MARKER_MAX_AGE` — an
         old observation is a fact about the past, not a state (the `last-mutation` future-stamp class);
      3. revalidated with ONE exempt REST `rate_limit` read before any long wait: if that bucket now
         reports headroom, the marker is stale, it is annotated (age kept) and the call proceeds;
      4. never for a NO_WAIT caller, and never for a call that makes no request (`gh --version`, `help`,
         `auth token`) — those cannot be refused, and parking them would only hide the tooling."""
    if NO_WAIT or not makes_request(gh_argv):
        return 0.0
    marker = read_marker()
    # ⛔ `marker` IS A DICT, so membership tests its KEYS (`recovered`, `stale`) — the `=` spelling
    # made both checks always false, which quietly disabled the suppressor this gate depends on: a
    # marker already marked recovered (by `record_recovery`) or stale (by `mark_marker_stale`) still
    # blocked, and if the probe could not answer it paid the WHOLE window again.
    if not marker or "recovered" in marker or "stale" in marker:
        return 0.0
    bucket = bucket_for(gh_argv)
    if marker.get("bucket") != bucket:
        return 0.0
    age = marker_age(marker)
    if age is None or age < 0 or age > MARKER_MAX_AGE:
        if age is not None and age >= 0:
            log_event("marker-gate: IGNORED a %s marker aged %ds (> %ds) — an old record is not a state"
                      % (bucket, age, int(MARKER_MAX_AGE)))
        return 0.0
    kind, until = marker_window(marker)
    if until <= now:
        # ⛔ REQUIREMENT 5: the marker is older than the window it recorded. This is the measured
        # stale shape — `attempts=1 waited=0` with a reset ~43 min ahead — and it must not block.
        log_event("marker-gate: IGNORED a %s marker whose window ended %ds ago (kind=%s age=%ds)"
                  % (bucket, int(now - until), kind, age))
        return 0.0
    wait = float(until - now)
    remaining = as_int(marker.get("remaining"))
    if wait > GATE_REVALIDATE_S:
        # ⛔ REQUIREMENT 3: one REST `rate_limit` read is UNMETERED, so a long wait is worth checking
        # before it is paid. A bucket that reports headroom contradicts the marker: the refusal was
        # secondary, or the window has moved on — either way the marker must stop blocking.
        p_remaining, p_reset = probe_rate_limit(real_gh, bucket)
        if p_remaining is not None:
            remaining = p_remaining
        if p_remaining is not None and p_remaining > 0 and kind != "retry-after":
            # ⛔ EXCEPT FOR `retry-after`. That window is the SERVER'S own instruction, and headroom on
            # the primary counter does not contradict it — GitHub's own docs say secondary limits strike
            # while the primary counter looks healthy, which is exactly why `plan_wait` honours the
            # header verbatim and `probe_rate_limit` documents its `remaining` as untrusted for health.
            # Clearing a 300 s cool-down on `remaining > 0` put every later client on the box back
            # inside a cool-down this layer was still obeying — the same failure the recorded window
            # itself was fixed for.
            # ⛔ THE LINE MUST DESCRIBE WHAT ACTUALLY HAPPENED. `mark_marker_stale` refuses to annotate a
            # record that was REPLACED between this gate's read and its write (another client's refusal,
            # possibly a real primary window that must hold). Logging "cleared it" then would put two
            # contradictory decisions in `events.log` and claim to have cleared a record that is still
            # blocking the next client.
            if mark_marker_stale(p_remaining, "remaining-gt-0", expect=marker):
                log_event("marker-gate: STALE %s marker (kind=%s age=%ds) — revalidation read remaining=%d > 0, "
                          "cleared it and proceeding instead of waiting %ds"
                          % (bucket, kind, age, p_remaining, int(wait)))
            else:
                log_event("marker-gate: %s marker (kind=%s age=%ds) contradicted by revalidation (remaining=%d > 0) "
                          "but NOT annotated — it was replaced under me; proceeding, the new record stands for the "
                          "next client"
                          % (bucket, kind, age, p_remaining))
            return 0.0
        log_event("marker-gate: revalidated %s (kind=%s age=%ds remaining=%s) — the wait stands"
                  % (bucket, kind, age, "%d" % p_remaining if p_remaining is not None else "?"))
    if wait > MAX_WAIT:
        # ⛔ THE IN-CALL BOUND APPLIES TO THE GATE TOO. Sleeping the cap and then SENDING anyway is
        # the worst of both: the caller pays the full bound and the request is one the marker says is
        # doomed. The gate declines, the attempt is made (it is now the cheaper evidence), and the
        # normal refusal path fails fast in `plan_wait`-time so the caller's own deferral takes over.
        log_event("marker-gate: a %s marker's window is %ds away (kind=%s age=%ds remaining=%s) — beyond "
                  "the %ds in-call bound, so NOT holding the call for it"
                  % (bucket, int(wait), kind, age,
                     "%d" % remaining if remaining is not None else "?", int(MAX_WAIT)))
        return 0.0
    # ⛔ THE LINE STATES ITS OWN EVIDENCE (requirement 4): classification, marker AGE, the remaining
    # count read, and the attempt number. A refusal that cannot say how old its evidence is reads the
    # same as a live one.
    log_event("marker-gate: waiting %ds on a %s marker — evidence: kind=%s marker_age=%ds remaining=%s "
              "attempt=preflight"
              % (int(wait), bucket, kind, age, "%d" % remaining if remaining is not None else "?"))
    pause(wait)
    return wait


# ── argv shape ─────────────────────────────────────────────────────────────────────────────────
# Mutative = a request that CHANGES something. Getting this wrong in the permissive direction only
# costs latency (an extra 1s wait), so the list errs wide rather than narrow.
MUTATING_PAIRS = {
    ("pr", "merge"), ("pr", "comment"), ("pr", "edit"), ("pr", "create"), ("pr", "ready"),
    ("pr", "close"), ("pr", "reopen"), ("pr", "review"), ("pr", "update-branch"),
    ("issue", "comment"), ("issue", "create"), ("issue", "edit"), ("issue", "close"),
    ("issue", "reopen"), ("run", "rerun"), ("run", "cancel"), ("release", "create"),
    ("release", "edit"), ("release", "delete"), ("label", "create"), ("label", "edit"),
    ("label", "delete"), ("repo", "edit"), ("workflow", "run"),
    # ⛔ A WRITE THE TABLE DID NOT KNOW WAS A WRITE. These reached the READ branch, so the refusal told the
    # operator “this READ has no exact GraphQL equivalent” about a mutation — the diagnostic falsehood this
    # file exists to remove — and they were not PACED, because pacing keys on the same predicate. The
    # safety outcome was right (refused, nothing spent); the one line a human reads was wrong (round 7).
    ("secret", "set"), ("secret", "delete"), ("variable", "set"), ("variable", "delete"),
    ("cache", "delete"), ("gist", "create"), ("gist", "delete"), ("gist", "edit"),
    ("codespace", "create"), ("codespace", "delete"), ("codespace", "stop"),
    ("ruleset", "create"), ("ruleset", "edit"), ("ruleset", "delete"),
    ("ssh-key", "add"), ("ssh-key", "delete"), ("gpg-key", "add"), ("gpg-key", "delete"),
    ("repo", "create"), ("repo", "delete"), ("repo", "fork"), ("repo", "rename"),
    ("repo", "archive"), ("repo", "sync"), ("repo", "unarchive"),
}
METHOD_FLAGS = ("-X", "--method")
DATA_FLAGS = ("-f", "--raw-field", "-F", "--field", "--input")


def _data_flag_value(a):
    """Is this argv token a DATA flag, and if its value is attached, what is that value?

    ⛔ `gh` IS COBRA/PFLAG, SO A SHORT FLAG'S VALUE MAY BE ATTACHED. `-fbody=x`, `-Fbody=x` and
    `-f=body=x` are all `-f body=x` (verified against gh 2.102.0 — none is an "unknown flag"); only
    the SEPARATE form and the LONG attached form (`--field=x`) used to be recognised, so a write
    spelled `gh api <endpoint> -fbody=x` classified as a READ. Since a field makes `gh api` infer
    POST, two concurrent identical creates were then coalesced and one of them never happened — a
    silent lost mutation, and a key that could not tell it from a GET (review round 4). Every consumer
    now asks THIS function, so the flag vocabulary has one definition."""
    if a in DATA_FLAGS:
        return True, None
    for f in ("--field", "--raw-field", "--input"):
        if a.startswith(f + "="):
            return True, a[len(f) + 1:]
    for f in ("-f", "-F"):
        if a.startswith(f) and len(a) > 2:
            v = a[2:]
            return True, v[1:] if v.startswith("=") else v
    return False, None


def api_is_mutating(argv):
    method = None
    has_data = False
    graphql = False
    i = 1
    while i < len(argv):
        a = argv[i]
        if a == "graphql":
            graphql = True
        if a in METHOD_FLAGS and i + 1 < len(argv):
            method = argv[i + 1].upper()
            i += 2
            continue
        if a.startswith("--method="):
            method = a.split("=", 1)[1].upper()
        elif a.startswith("-X") and len(a) > 2:
            method = a[2:].upper()
        elif _data_flag_value(a)[0]:
            has_data = True
        i += 1
    if method:
        return method != "GET"
    # ⛔ `gh api graphql -f query=…` IS A READ, `-f` notwithstanding. The heartbeat's objective
    # refresh is ~513 of these in a measured 12 s window inside a bounded 90 s run; classifying
    # each as a mutation put a cumulative ~1 s gap per call in the way (and, before the reservation
    # change, held the box's lock for it). A genuine GraphQL mutation loses at most one 1 s gap —
    # the cheap direction — while the read path keeps its throughput.
    if graphql:
        return False
    # `gh api` infers POST from the presence of fields — treat that as mutative too.
    return has_data


def is_mutating(argv):
    if not argv:
        return False
    if argv[0] == "api":
        return api_is_mutating(argv)
    return len(argv) >= 2 and (argv[0], argv[1]) in MUTATING_PAIRS


def pace_mutation():
    """>= 1 second between MUTATIVE calls on a box (GitHub's documented guidance for many
    POST/PATCH/PUT/DELETE). Returns the seconds to wait before this call may LEAVE.

    ⛔ THE STAMP IS THE TIME THE CALL FIRED, AND THE GAP IS MEASURED BETWEEN SENDS. Round 2 got this
    wrong in both directions: a *reserved future slot* re-read as "last fired" made each attempt
    sleep again, and a reservation taken under the lock does not bound TRANSMISSION — a competing
    caller that held the lock for 0.9 s let two mutations leave 0.1 s apart, which is the burst the
    secondary limit reacts to. So: read the last FIRE time, wait outside the lock, re-check inside it
    immediately before the request, and stamp the fire time then (see dispatch)."""
    path = os.path.join(state_dir(), "last-mutation")
    now = clock()
    last = 0.0
    try:
        with open(path) as fh:
            last = float((fh.read() or "0").split()[0])
    except (OSError, ValueError, IndexError):
        last = 0.0
    if last > now:
        # A stamp from the FUTURE is invalid by construction (a clock that stepped back: NTP, a VM
        # resume) — the same class `last-limit`'s age bound exists for. Honouring it parks every
        # mutation until wall-clock catches up (measured shape: an hour of "pacing mutation: waiting
        # 3600.00s"), so it is ignored rather than believed.
        log_event("last-mutation stamp %.1fs ahead of now — ignoring it" % (last - now))
        last = 0.0
    return max(0.0, min(last + MUTATION_GAP - now, MUTATION_GAP))


def mark_mutation():
    """Record that a mutative call is leaving NOW (called immediately before the request)."""
    write_state("last-mutation", "%.3f\n" % clock())


# ── execution ──────────────────────────────────────────────────────────────────────────────────
class Result(object):
    __slots__ = ("rc", "out", "err", "status")

    def __init__(self, rc, out, err, status=None):
        self.rc, self.out, self.err, self.status = rc, out, err, status


def run(real_gh, argv, extra=None, timeout=None):
    cmd = [real_gh] + list(argv) + list(extra or [])
    env = dict(os.environ)
    env[REENTRANCY_ENV] = "1"       # a gh child that re-enters this helper must not deadlock on our lock
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env,
                           timeout=timeout)
    except subprocess.TimeoutExpired:
        # ⛔ A BOUNDED CALLER MUST NOT BE HELD BY AN UNBOUNDED ONE (#2342 review P2). The meter probe
        # runs while the box-wide LOCK is held, so a stalled `/rate_limit` (a proxy black hole, a TLS
        # stall) would otherwise park every gh call on the box — including the landing rail's own —
        # for the whole `GH_LIMIT_LOCK_TIMEOUT` and then de-serialise the box. A timeout is a FAILED
        # call (rc 124, `timeout`'s own code), which every caller already treats as "no measurement".
        return Result(124, b"", ("gh-limit: the call did not finish within %ss\n" % timeout).encode())
    return Result(p.returncode, p.stdout, p.stderr)


# ── conditional REST (the polling half) ────────────────────────────────────────────────────────
# ONLY a plain GET `gh api <path>` is modelled. Every shape whose output this file would have to
# re-create by hand — `--paginate`, `--template`, `-H`, `-f`, a non-GET method — is left COMPLETELY
# alone: adding a conditional header to a call whose response we cannot reproduce is not a slow
# answer, it is a wrong one (the rule the REST adapter beside this file states for flags).
def conditional_plan(argv, honour_kill_switch=True):
    """The parsed shape of a plain GET `gh api <path>`, or None when this layer must not touch it.

    ⛔ THE PARSE AND THE TRANSPORT SWITCH ARE SEPARATE ON PURPOSE. `GH_LIMIT_CONDITIONAL=0` disables
    the ETag/`--include` round trip; it must NOT also disable the GraphQL failover, which needs the
    same parse and nothing else. Coupling them meant an operator turning off one optimisation lost
    the other — and the failover is the one that keeps merges readable at 2am. Every safety refusal
    below still applies to both transports."""
    if not argv or argv[0] != "api":
        return None
    if honour_kill_switch and os.environ.get("GH_LIMIT_CONDITIONAL", "1") == "0":
        return None
    path = None
    jq = None
    silent = False
    host = None
    i = 1
    while i < len(argv):
        a = argv[i]
        if a in ("--paginate", "--include", "-i", "--slurp", "--cache", "--template", "-t",
                 "-H", "--header", "--input", "--silent-errors"):
            return None
        if a in ("--jq", "-q") and i + 1 < len(argv):
            jq = argv[i + 1]
            i += 2
            continue
        if a.startswith("--jq="):
            jq = a.split("=", 1)[1]
        elif a.startswith("-q") and len(a) > 2:
            jq = a[2:]
        elif a in ("--silent",):
            silent = True
        elif a == "--hostname" and i + 1 < len(argv):
            host = argv[i + 1]
            i += 2
            continue
        elif a.startswith("--hostname="):
            host = a.split("=", 1)[1]
        elif a in METHOD_FLAGS or a in DATA_FLAGS:
            return None
        elif a.startswith("--method=") or (a.startswith("-X") and len(a) > 2):
            v = a.split("=", 1)[1] if "=" in a else a[2:]
            if v.upper() != "GET":
                return None
        elif a.startswith("-"):
            return None
        elif path is None:
            path = a
        else:
            return None            # two positionals: not the shape this models
        i += 1
    if not path:
        return None
    # ⛔ NEVER ADD A DEPENDENCY `gh` DOES NOT HAVE. This file projects `--jq` locally with the
    # external `jq` binary; `gh` vendors its own engine. With jq absent, intercepting a `--jq`
    # call would replace gh's working answer with a FileNotFoundError traceback from us — so a
    # `--jq` call is left COMPLETELY alone when jq is not on PATH (gh serves it itself, just
    # without the free 304).
    if jq is not None and shutil.which("jq") is None:
        return None
    return {"path": path, "jq": jq, "silent": silent, "host": host}


STATUS_RE = re.compile(rb"^HTTP/\S+\s+(\d{3})")
HEADER_SPLIT_RE = re.compile(rb"\r?\n\r?\n", re.M)


def split_http(raw):
    """`gh api --include` output -> (status, headers{lower-name: value}, body). None when the bytes
    are not an HTTP response (then the caller must not pretend it can replay them)."""
    m = STATUS_RE.match(raw)
    if not m:
        return None
    parts = HEADER_SPLIT_RE.split(raw, 1)
    head = parts[0]
    body = parts[1] if len(parts) > 1 else b""
    headers = {}
    for line in head.split(b"\n"):
        line = line.rstrip(b"\r")
        c = line.find(b":")
        if c <= 0:
            continue
        headers[line[:c].strip().lower().decode("latin-1")] = line[c + 1:].strip().decode("latin-1")
    return int(m.group(1)), headers, body


def _cred_digest():
    """A digest of the credential this call will use — never the secret itself.

    ⛔ ALL FOUR credential names: `gh` reads the ENTERPRISE pair for a non-github.com host, and a key
    on GH_TOKEN alone shared an entry between two enterprise credentials (reproduced)."""
    tok = (os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
           or os.environ.get("GH_ENTERPRISE_TOKEN") or os.environ.get("GITHUB_ENTERPRISE_TOKEN") or "")
    return hashlib.sha256(tok.encode("utf-8")).hexdigest()[:16] if tok else "-"


def cache_key(plan):
    """The cache identity of ONE request. The HOST is part of it, not decoration: a box configured
    for a GH Enterprise host and for github.com can issue the same path against both, and a shared
    entry would replay one host's body for the other — the `--repo` wrong-repo class in a new
    spelling.

    ⛔ AND THE CREDENTIAL IS PART OF IT. A second token on the same `$HOME` (an operator's keyring
    `gh` beside the harness's `GH_TOKEN`) yields a DIFFERENT representation for the same path, so a
    shared entry could replay one credential's body to the other on a 304. The digest keeps the
    secret out of the key (the file name is already a hash of the whole thing). A token the child
    reads from a keyring rather than the environment is not visible here — recorded as a residual."""
    # ⛔ ALL FOUR credential names: `gh` reads the ENTERPRISE pair for a non-github.com host, and a
    # key on GH_TOKEN alone shared an entry between two enterprise credentials (reproduced).
    tdig = _cred_digest()
    # ⛔ `GH_HOST` IS THE SAME DECORATION AS `--hostname`, AND IT WAS MISSING. gh reads the host from
    # the environment when the flag is absent, so two processes on one box with different `GH_HOST`
    # shared an entry and a 304 replayed one host's body for the other — a wrong-but-plausible answer
    # with rc 0 (the #1959/#1981 class), reproduced.
    host = plan["host"] or os.environ.get("GH_HOST") or ""
    return "%s|%s|%s" % (host, plan["path"], tdig)


def cache_path(key):
    digest = hashlib.sha256(key.encode("utf-8")).hexdigest()[:40]
    return os.path.join(state_dir(), "etag", digest + ".json")


def cache_get(key):
    """The cached entry, with its body as BYTES. Base64, not a decoded string: a 304 replay must
    reproduce the 200 body EXACTLY, and any text decoding (`utf-8`, `replace`) silently corrupts a
    body that is not UTF-8 — a `gh api` of a contents/binary endpoint would come back mangled while
    the caller believed it had the unchanged resource."""
    try:
        with open(cache_path(key)) as fh:
            d = json.load(fh)
        if isinstance(d, dict) and d.get("etag") and isinstance(d.get("body_b64"), str):
            d["body"] = base64.b64decode(d["body_b64"].encode("ascii"))
            return d
    except (OSError, ValueError, binascii.Error):
        pass
    return None


def prune_cache():
    """Keep the ETag cache BOUNDED — in ENTRIES and in BYTES. Every distinct poll URL earns an
    entry, and the body it carries is up to CACHE_MAX_BODY, so an entries-only bound allowed ~0.5 GB
    on a box whose disk gate then refuses dispatch (`AGENT_DISK_REFUSED`). Oldest-mtime first, and
    only when a bound is exceeded; the steady state costs one `listdir` plus one `stat` per entry
    (the byte total needs each size), which is what keeps the cache bounded in BYTES as well.

    It also reaps `*.tmp-<pid>` staging files: a `cache_put` killed between `open` and `os.replace`
    (reachable — a bounded caller's timeout now kills the helper, which is `exec`'d) leaves one
    behind and nothing else would ever remove it."""
    d = os.path.join(state_dir(), "etag")
    try:
        entries = []
        for n in os.listdir(d):
            fp = os.path.join(d, n)
            try:
                st = os.stat(fp)
            except OSError:
                continue
            if n.endswith(".json"):
                entries.append((st.st_mtime, st.st_size, n))
            elif ".tmp-" in n:
                if not _dead_writer(fp):
                    continue            # a LIVE writer's staging file is not ours to collect
                try:
                    os.unlink(fp)
                except OSError:
                    pass
    except OSError:
        return
    entries.sort()
    total = sum(size for _, size, _ in entries)
    drop = len(entries) - CACHE_MAX_ENTRIES
    for _, size, n in entries:
        if drop <= 0 and total <= CACHE_MAX_BYTES:
            break
        try:
            os.unlink(os.path.join(d, n))
        except OSError:
            continue
        drop -= 1
        total -= size


def cache_put(key, etag, body):
    if len(body) > CACHE_MAX_BODY:
        return
    p = cache_path(key)
    tmp = p + ".tmp-%d" % os.getpid()
    try:
        os.makedirs(os.path.dirname(p), mode=0o700, exist_ok=True)
        with open(tmp, "w") as fh:
            json.dump({"etag": etag, "body_b64": base64.b64encode(body).decode("ascii")}, fh)
        os.replace(tmp, p)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return
    prune_cache()


# ── PASS-SCOPED READ MEMOISATION (agent-infra#1984, cause 1) ──────────────────────────────────
# WHY THIS LAYER, AND WHY NOT THE ETAG PATH ABOVE. A refresh pass runs the collision pre-flight
# ONCE PER CANDIDATE, and three of the five calls each candidate makes are FLEET-WIDE CONSTANTS:
# `gh api user` (identity), the open-PR list, and the recently-closed-PR sample. Measured on the
# shipped script, agent-infra, 24 candidates: 72 of the pass's 134 core requests, i.e. 54%, are the
# SAME THREE ANSWERS asked 24 times.
#
# The conditional (ETag) path above cannot take them: it deliberately refuses every shape whose
# output it would have to re-create by hand (`--paginate`, `--slurp`, `-H`, `-i`, `--jq` with no
# `jq`), and those are exactly the shapes these reads use — the timeline surface is
# `--paginate --slurp`, the listings are `api -i`, and the PR list is a `--json` subcommand that is
# not `gh api` at all. Adding a conditional header to a call whose body we cannot reproduce is a
# WRONG answer, not a slow one (the rule stated where `conditional_plan` lives).
#
# So this is the other half of the same idea, and it needs no knowledge of gh's semantics: memoise
# the WHOLE INVOCATION — argv in, (stdout, stderr, rc) out — for the life of ONE pass. There is no
# re-implementation to get wrong, the bytes are the bytes the real gh produced, and the scope is
# narrow enough that staleness is bounded by the pass itself.
#
# ⛔ THE SCOPE IS THE POINT, AND IT IS THE CALLER'S. `GH_LIMIT_PASS_CACHE` names a directory that
# the refresh wipes and re-creates at the START of every pass, so an entry written by a previous
# pass cannot be read by this one — the failure mode that makes a cache dangerous is not reachable
# here by construction, not by a TTL that could be forgotten. Unset/empty => this function is
# inert and every call behaves exactly as before.
#
# ⛔ WHAT IS NEVER MEMOISED, AND WHY EACH ONE MATTERS:
#   * A MUTATION. It has an effect; replaying its stdout would report work it did not do.
#   * `/rate_limit`. It is the pass's own budget METER (the refresh's pacing gate re-reads it before
#     every candidate precisely to see what the last candidate cost). A memoised meter reports a
#     budget that cannot move, which would hide exactly the exhaustion the gate exists to see.
#   * `gh auth token`, WHOSE STDOUT IS THE CREDENTIAL. This directory is on disk; a token must never
#     land in it. The whole `auth` command is excluded, not just that subcommand.
#   * A FAILURE. `rc != 0` is replayed to the caller as-is and not stored: an error is evidence about
#     a moment, and pinning it for the rest of the pass would turn one transient fault into a stable
#     "unreadable" for every later candidate — an INCOMPLETE this layer manufactured.
PASS_CACHE_ENV = "GH_LIMIT_PASS_CACHE"
PASS_CACHE_MAX_ENTRY = cfg_int("GH_LIMIT_PASS_CACHE_MAX_ENTRY", 4 * 1024 * 1024, 1024, 1 << 30)
PASS_CACHE_MAX_BYTES = cfg_int("GH_LIMIT_PASS_CACHE_MAX_BYTES", 64 * 1024 * 1024, 1024, 1 << 30)


def pass_cache_enabled():
    """Is the feature on at all? Read-only — no directory work, because this is asked once per
    invocation on a path that also handles `gh auth token`.

    ⛔ `0` IS OFF. The value is a DIRECTORY, so this used to be `bool(value)` — which made the
    documented disable (`GH_LIMIT_PASS_CACHE=0`) ENABLE the cache and create a directory literally
    named `0` in the caller's CWD. A switch that does the opposite of what it says is worse than no
    switch: an operator who turned the cache off kept writing to disk."""
    raw = cfg(PASS_CACHE_ENV, "").strip()
    return bool(raw) and raw != "0"


def pass_cache_dir():
    """The pass's memo directory, or None when the feature is off. `mkdir -p` on demand so a caller
    that only exports the name still gets a working cache; ANY inability to use it is returned as
    None (a broken cache must never break the call)."""
    d = cfg(PASS_CACHE_ENV, "")
    if not d or d.strip() == "0":
        return None
    try:
        os.makedirs(d, mode=0o700, exist_ok=True)
    except OSError:
        return None
    return d if os.path.isdir(d) else None


def pass_cache_eligible(gh_argv):
    """May THIS invocation be memoised? See the exclusion list above."""
    if not pass_cache_enabled() or not gh_argv:
        return False
    if gh_argv[0] == "auth":
        return False
    if is_mutating(gh_argv):
        return False
    if gh_argv[0] == "api":
        ep = api_endpoint(gh_argv)
        if ep is None:
            return False            # unattributable: not memoised either (a meter must be able to move)
        if ep.split("?")[0].strip("/").lower() == "rate_limit":
            return False
    return True


def pass_cache_key(gh_argv):
    """One invocation's identity. THE CWD IS PART OF IT and that is not decoration: `gh pr list`
    with no `--repo` resolves the repository from the working directory, so two checkouts of two
    different repos issue an IDENTICAL argv that must not share an answer — the `--repo` wrong-repo
    class in its quietest form. The host and the credential are in it for the same reason the ETag
    key carries them (`cache_key`): a second token, or a GHES host, yields a different
    representation for the same argv."""
    host = os.environ.get("GH_HOST") or ""
    try:
        cwd = os.getcwd()
    except OSError:
        cwd = ""
    # ⛔ `GH_REPO` IS PART OF THE IDENTITY HERE TOO (`#2243` review round 7): gh resolves a
    # `--repo`-less call from `--repo` > `GH_REPO` > the cwd remote, and substitutes `{owner}`/`{repo}`
    # in an `api` endpoint from the same place — so the cwd pin alone lets two GH_REPO values share a
    # memoised answer.
    parts = [host, os.environ.get("GH_REPO") or "", _cred_digest(), cwd] + list(gh_argv)
    return hashlib.sha256("\x00".join(parts).encode("utf-8", "surrogateescape")).hexdigest()[:40]


def pass_cache_get(gh_argv):
    """(out, err, rc) for a memoised invocation, or None. A corrupt/partial entry is a MISS, never
    an error: the staging write is atomic, but a half-installed cache directory must still answer
    by asking GitHub rather than by crashing the box's gh layer."""
    d = pass_cache_dir()
    if d is None:
        return None
    try:
        with open(os.path.join(d, pass_cache_key(gh_argv) + ".json")) as fh:
            e = json.load(fh)
        out = base64.b64decode(e["out_b64"].encode("ascii"))
        err = base64.b64decode(e["err_b64"].encode("ascii"))
        rc = int(e["rc"])
    except (OSError, ValueError, KeyError, TypeError, binascii.Error):
        return None
    if rc != 0:
        return None                     # never trust a stored failure (see the exclusion list)
    return out, err, rc


def pass_cache_put(gh_argv, out, err, rc):
    d = pass_cache_dir()
    if d is None or rc != 0:
        return
    size = len(out) + len(err)
    if size > PASS_CACHE_MAX_ENTRY:
        return
    try:
        used = sum(os.path.getsize(os.path.join(d, n)) for n in os.listdir(d))
    except OSError:
        used = 0
    if used + size > PASS_CACHE_MAX_BYTES:
        return
    p = os.path.join(d, pass_cache_key(gh_argv) + ".json")
    tmp = p + ".tmp-%d" % os.getpid()
    try:
        with open(tmp, "w") as fh:
            json.dump({"rc": rc,
                       "out_b64": base64.b64encode(out).decode("ascii"),
                       "err_b64": base64.b64encode(err).decode("ascii")}, fh)
        os.replace(tmp, p)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


class _StreamCapture(object):
    """Stands in for ONE of sys.stdout / sys.stderr while an invocation runs, so the memo stores
    exactly the bytes the caller would have received. `.buffer` is the attribute the rest of this
    file writes to; `write()` covers the text paths (`fail_loudly`). Two of these are used — never
    one shared object — because merging the streams here would break every caller that redirects
    stderr to a file and parses stdout as JSON (`rest_list`, `gh-rest`'s `2>&1` projectors)."""

    def __init__(self):
        self.buffer = io.BytesIO()

    def write(self, s):
        self.buffer.write(s.encode("utf-8", "surrogateescape"))
        return len(s)

    def flush(self):
        return None

    def isatty(self):
        return False

    def getvalue(self):
        return self.buffer.getvalue()


# ── SINGLE FLIGHT: identical concurrent READS share ONE load (agent-infra#2243) ─────────────────
# WHY THIS LAYER EXISTS AT ALL. `acquire_lock` makes the box's `gh` traffic SERIAL, which #1988/#2005
# decided and this section does not revisit. Serialisation says who goes next; it says nothing about
# whether the next request is the SAME request. Thirteen lanes reading `repos/o/r/pulls/9426` ran it
# thirteen times — the last lane waiting for the twelve before it — to produce one answer the first
# call already had. Measured on one box, one account, 2026-10-21: 0.676 s at 3 lane processes, 63 s
# at 13, while a raw `curl https://api.github.com/rate_limit` took 0.091 s on 4658/5000 quota. The
# cost was OURS.
#
# So: request coalescing (single flight), in the form the research converged on, with each piece
# named where it lives:
#
#   * ONE IN-FLIGHT LOAD PER KEY (`flight_key`). The key is the NORMALISED REQUEST — the endpoint,
#     the argv, the host, the credential digest and the cwd repo pin — never the whole command line.
#     Only decorations that CANNOT change the answer are dropped (`normalised_request`); anything
#     that can (`--json`, `--jq`, `--paginate`, `--limit`, `-H`, `?query`) stays in the key verbatim,
#     because a key that dropped one would replay another request's body with rc 0 — the wrong-answer
#     class every other key in this file already refuses.
#   * A BOUNDED WAIT (`GH_LIMIT_FLIGHT_WAIT`, default 5 s — Nginx's own `proxy_cache_lock_timeout`
#     default). Past the bound a waiter returns a DISTINCT `busy` outcome naming the holder's AGE and
#     exits 75 (`EX_TEMPFAIL`). It never inherits an unbounded queue: "bounded" cannot mean "bounded
#     in the other queue".
#   * FAILURES ARE SHARED, NEVER LAUNDERED. The leader publishes its exit code beside its bytes, so
#     a follower leaves with the LEADER'S code and error. A fake success is the one thing a follower
#     may never report (Go's singleflight shares the error for the same reason).
#   * MUTATIONS ARE NEVER COALESCED (`flight_eligible`). Two callers asking for a merge are two
#     merges; coalescing one would DROP it — a lost merge is not a latency bug. `auth` is excluded
#     too (its stdout is the credential, and this runs through files on disk), and so is `/rate_limit`
#     (the pass's own meter: a shared meter cannot move).
#   * STALE IS LABELLED, NEVER PRESENTED AS CURRENT. A previous answer still on record while a
#     refresh is in flight may be served instead of waiting — but only when the CALLER asks
#     (`GH_LIMIT_FLIGHT_STALE_SERVE=1`; off by default because the label is a stderr write and the
#     harness's callers merge stderr into the bytes they parse), and then the age goes on stderr.
#   * A STALLED HOLDER CANNOT HOLD THE KEY. Nginx `proxy_cache_lock_age`: a leader whose pid is gone,
#     or whose claim is older than `GH_LIMIT_FLIGHT_LEADER_MAX_AGE`, is taken over by the next waiter,
#     so a dead leader is a retry rather than a deadlock. The leader unlinks its claim in a `finally`
#     and `prune_flights` sweeps one a killed leader left behind — no orphan lock file survives.
#
# ⛔ WHAT THIS IS NOT: a cache. A follower shares only a result that COMPLETED AFTER IT ARRIVED, so
# this path can never hand out an old answer as a fresh one. The ETag cache is the cache and it is
# untouched; the result file is kept only for `GH_LIMIT_FLIGHT_KEEP_S` so the stale-while-refresh
# path above has something to offer and an operator has evidence.
FLIGHT_ENV = "GH_LIMIT_FLIGHT"
FLIGHT_WAIT = cfg_secs("GH_LIMIT_FLIGHT_WAIT", 5.0, 0.1, 300)              # nginx proxy_cache_lock_timeout
FLIGHT_LEADER_MAX_AGE = cfg_secs("GH_LIMIT_FLIGHT_LEADER_MAX_AGE", 120, 2, 3600)  # proxy_cache_lock_age
FLIGHT_KEEP_S = cfg_secs("GH_LIMIT_FLIGHT_KEEP_S", 30, 0, 3600)
FLIGHT_STALE_SERVE = cfg_int("GH_LIMIT_FLIGHT_STALE_SERVE", 0, 0, 1)
FLIGHT_STALE_MAX_AGE = cfg_secs("GH_LIMIT_FLIGHT_STALE_MAX_AGE", 30, 1, 3600)
FLIGHT_MAX_ENTRY = cfg_int("GH_LIMIT_FLIGHT_MAX_ENTRY", 4 * 1024 * 1024, 1024, 1 << 30)
FLIGHT_POLL_S = 0.02
# EX_TEMPFAIL, the same "retry later" code the give-up path's callers already know. DISTINCT from
# every answer and from every refusal this layer produces, because "busy" is neither.
BUSY_EXIT = 75


# Flags of `gh api` whose NEXT argv token is a VALUE (never the endpoint), and the ones that stand
# alone. Both sets exist for `api_endpoint` below — see the ⛔ there.
API_VALUE_FLAGS = frozenset(METHOD_FLAGS) | frozenset(DATA_FLAGS) | frozenset({
    "-H", "--header", "--hostname", "-t", "--template", "-q", "--jq", "--cache", "--cache-ttl",
    "-p", "--preview",
})
API_BARE_FLAGS = frozenset({
    "-i", "--include", "--paginate", "--slurp", "--silent", "--silent-errors", "--verbose",
    # a real `gh api` flag in 2.102.0 (`gh api --allow-escape-sequences` answers “accepts 1 arg(s),
    # received 0”, i.e. it parses). Absent from this vocabulary it made `api_endpoint` answer None,
    # which made `makes_request` answer “no API request” and SKIPPED the write guard entirely — one
    # request into a measured-empty pool, and the headerless refusal then rewrote the dated record as
    # undated, after which every known-spelling write was sent too (measured, round 9).
    "--allow-escape-sequences",
})


def api_endpoint(gh_argv):
    """The ENDPOINT of a `gh api …` invocation, or None when it cannot be attributed with certainty.

    ⛔ "THE FIRST TOKEN THAT DOES NOT START WITH `-`" IS A FLAG'S VALUE. `gh api -H 'Accept: x' graphql
    -f 'query=mutation { … }'` makes that scan answer `Accept: x`: the GRAPHQL routing is skipped, the
    call looks like a plain REST read, and the gate that must inspect a GraphQL payload is bypassed —
    a LOST MUTATION, reached by a route the tests that fed the gate a bare `api graphql …` never
    exercised (review round 3). The same scan was wrong in `bucket_for` (a `gh api -H … graphql`
    refusal was pinned on the `core` pool), in `makes_request` (a `-H`-prefixed `/rate_limit` counted
    as recovery evidence) and in `pass_cache_eligible` (it could be MEMOISED, freezing the meter), so
    all four now share THIS function.

    A flag we do not know how to consume returns None, and every caller treats None as the
    conservative answer (not coalesced, not memoised, `core`), because a mis-attributed endpoint is
    how this class came back."""
    i = 1
    while i < len(gh_argv):
        a = gh_argv[i]
        if a == "--":
            i += 1
            continue
        if a in API_VALUE_FLAGS:
            i += 2                          # the flag AND its value are not the endpoint
            continue
        if a in API_BARE_FLAGS:
            i += 1
            continue
        if "=" in a and a.split("=", 1)[0] in API_VALUE_FLAGS:
            i += 1                          # `--jq=…` / `--method=GET`: one token, no separate value
            continue
        if a.startswith("-X") or a.startswith("--method=") or a.startswith("--"):
            if a.startswith("-X") and len(a) > 2:
                i += 1                      # `-XGET`: attached method, no separate value
                continue
            if a.startswith("--method="):
                i += 1
                continue
            return None                     # an unknown flag: we cannot say what the next token is
        if a.startswith("-"):
            # ⛔ AN ATTACHED DATA FLAG (`-fbody=x`, `-Fbody=x`) IS A VALUE-BEARING FLAG, NOT THE ENDPOINT —
            # `_data_flag_value` already knows the spelling, and returning None here made
            # `makes_request()` answer “this call makes no API request”, which SKIPPED the core-budget
            # guard entirely: `gh api -fbody=x repos/o/r/issues` (a POST, because a field implies it) was
            # sent into a pool measured at zero and retried to the attempt cap — 7 requests and 439 s —
            # while the same call with the flag AFTER the endpoint spent nothing (measured, round 8).
            _is_data, _ = _data_flag_value(a)
            if _is_data and "=" in a:
                i += 1
                continue
            return None
        return a
    return None


def flight_enabled():
    return cfg(FLIGHT_ENV, "1") != "0"


def _now():
    """REAL wall clock for the flight ledger — deliberately NOT `clock()`.

    ⛔ THE FAKE-CLOCK SEAM IS FOR THE DOCUMENTED WAITS. `GH_LIMIT_NOW_CMD` exists so a test can assert
    a 60/120/240 s backoff without sleeping it. The flight ledger instead measures how long a LIVE
    process has been on a key and how old an answer is — and BOTH are safety labels: a stale answer
    must never read as current, and a stalled holder must be visible with its age. Making those
    fudgeable from the environment would let a knob make a fresh answer look stale (or a stale one
    look fresh), which is the exact failure the labels exist to prevent. So the ledger is real time,
    and the price is that a test asserting an AGE waits for it."""
    return time.time()


# ⛔ COALESCING NEEDS A FAIL-CLOSED GATE, AND THAT IS THE OPPOSITE DIRECTION FROM `is_mutating`'s.
# `MUTATING_PAIRS` says of itself that it "errs wide rather than narrow" because mistaking a READ for a
# mutation costs one wasted 1 s pace — cheap. Reused as the coalescing gate, the same widening is not
# cheap at all: an unlisted MUTATING subcommand (`gh run delete`, `gh secret set`, `gh repo create`,
# `gh workflow disable`, `gh issue lock`, …) would read as a read, two concurrent identical calls would
# collapse into ONE, and the second would be handed the first one's rc 0 — a LOST mutation. (Found in
# review: the pacing predicate is deliberately permissive, so it can never be the coalescing one.)
# So this is a READ allowlist: a subcommand not named here is simply not coalesced (it runs serialised
# exactly as before — no regression, no lost effect), and `api graphql` additionally requires a payload
# that is PROVABLY a query.
FLIGHT_READ_PAIRS = {
    # ⛔ THE CRITERION IS "STDOUT IS THE WHOLE OBSERVABLE RESULT", not "it does not take a method". A
    # command with a LOCAL SIDE EFFECT cannot be coalesced even when it looks like a read: `gh run
    # download` writes artifact files into the CWD, so a follower would be handed the leader's rc 0
    # while its own files were never fetched (review round 6 removed it). Anything whose effect is not
    # in the bytes must run serialised, exactly as before.
    ("pr", "view"), ("pr", "list"), ("pr", "diff"), ("pr", "checks"), ("pr", "status"),
    ("issue", "view"), ("issue", "list"), ("issue", "status"),
    ("repo", "view"), ("repo", "list"),
    ("run", "view"), ("run", "list"),
    ("workflow", "view"), ("workflow", "list"),
    ("release", "view"), ("release", "list"),
    ("label", "list"), ("cache", "list"), ("secret", "list"), ("variable", "list"),
    ("search", "code"), ("search", "commits"), ("search", "issues"), ("search", "prs"),
    ("search", "repos"),
}
# GraphQL's own grammar: a payload that starts with `query` or with `{` (the unnamed-query shorthand) is
# a read. `mutation`, `subscription`, a fragment-only document and anything we cannot see are not.
GRAPHQL_READ_RE = re.compile(r"^\s*(query\b|\{)")


def _graphql_query_is_read(gh_argv):
    """Is this `gh api graphql` invocation PROVABLY a query? Fail-closed, deliberately.

    ⛔ `api_is_mutating` RETURNS FALSE FOR EVERY `gh api graphql` CALL and states why: for PACING the
    cheap direction is to treat a GraphQL payload as a read (a false mutation costs a 1 s gap). That
    reasoning inverts under coalescing — a GraphQL MUTATION treated as a read is two concurrent
    identical mutations collapsed into one, i.e. one of them never happens. So the payload is read
    here: only a `query` document or the `{ … }` shorthand qualifies; `mutation`/`subscription`, a
    `--input` file and a `-F query=@file` we cannot inspect are all NOT-a-read.
    """
    seen = []
    i = 0
    while i < len(gh_argv):
        a = gh_argv[i]
        if a == "--input" or a.startswith("--input="):
            return False                    # the payload is a FILE: not visible, so not provable
        if a in DATA_FLAGS and i + 1 < len(gh_argv):
            val, i = gh_argv[i + 1], i + 2
        else:
            is_data, attached = _data_flag_value(a)
            if not is_data or attached is None:
                i += 1
                continue
            val, i = attached, i + 1
        if val.startswith(("mutation=", "subscription=")):
            return False
        if val.startswith("operationName="):
            # ⛔ A MULTI-OPERATION DOCUMENT CAN SELECT A MUTATION BY NAME. `query Foo { … } mutation M { … }`
            # with `-f operationName=M` is a MUTATION whose payload STARTS with `query`, so a
            # leading-keyword test alone called it a read and coalesced it — the round-6/7 class again
            # (review round 7). A named operation is therefore not provable either way.
            return False
        if val.startswith("query="):
            seen.append(val.split("=", 1)[1])
    if not seen:
        return False                        # no payload we can judge (e.g. `-F query=@file`)
    # ⛔ "STARTS WITH `query`" IS NOT ENOUGH: a document may carry SEVERAL operations. Any
    # `mutation`/`subscription` anywhere in it means the executed operation is not provably a read
    # (and with no `operationName` gh executes the FIRST, which such a document may still make a
    # mutation if it is written `query … mutation …` — the keyword test below is the cheap, sound half).
    if any(re.search(r"\b(mutation|subscription)\b", q) for q in seen):
        return False
    return all(GRAPHQL_READ_RE.match(q) for q in seen)


def flight_eligible(gh_argv):
    """May THIS invocation be shared with an identical caller already in flight?"""
    if not flight_enabled() or not gh_argv:
        return False
    if os.environ.get(REENTRANCY_ENV):
        # ⛔ A NESTED CALL IS NEVER A DUPLICATE OF ITS PARENT. A gh child that re-enters this helper
        # would wait for the flight ITS OWN PARENT is leading, which cannot finish until the child
        # returns — the bound would turn that into a spurious `busy` on every nested call. Same rule
        # as `acquire_lock`, for the same reason.
        return False
    if gh_argv[0] == "auth":
        return False            # its stdout IS the credential — never into a file that outlives the call
    if not makes_request(gh_argv):
        return False            # nothing to share (`gh --version`, `gh help`) — and no file written for it
    if gh_argv[0] == "api":
        ep = api_endpoint(gh_argv)
        if ep is None:
            return False        # an argv we cannot attribute: FAIL CLOSED (never coalesced)
        if ep.strip("/").lower() == "rate_limit":
            return False        # the pass's own budget METER: a shared meter cannot see the last call
        if api_is_mutating(gh_argv):
            return False        # a non-GET method, or a data-carrying call gh infers POST for
        if ep.strip("/").lower() == "graphql":
            return _graphql_query_is_read(gh_argv)
        return True
    # ⛔ FAIL CLOSED FOR SUBCOMMANDS TOO: only an allowlisted READ pair is coalesced. `is_mutating` is
    # the PACING predicate and errs wide by design; this direction cannot afford that (see the comment
    # on FLIGHT_READ_PAIRS — an unlisted mutation would be silently dropped).
    return len(gh_argv) >= 2 and (gh_argv[0], gh_argv[1]) in FLIGHT_READ_PAIRS


def normalised_request(gh_argv):
    """argv with ONLY the decorations that provably cannot change the answer removed.

    ⛔ NOTHING ELSE IS DROPPED, AND THAT IS THE SAFETY RULE. `--json`, `--jq`, `-q`, `--limit`,
    `--paginate`, `--slurp`, `-i`, `-H` and a `?query` in the path each change the bytes the caller
    receives, so a key that ignored one would hand a caller ANOTHER request's answer with rc 0 (the
    #1959/#1981 class). ⛔ AND `--` IS KEPT: after it a positional may legitimately START WITH `-`
    (`gh search code -- '--owner=x'` is a literal-text search, while `gh search code --owner=x` is an
    owner filter), so dropping it made two different requests share a key (review round 7). The one
    decoration that provably cannot change the answer is an explicit `-X GET` / `--method GET` on a
    call carrying NO data fields (gh infers GET there anyway). With data fields present the flag is
    KEPT — and such a call is not eligible at all, because a data-carrying `gh api` is a mutation to
    this file (`api_is_mutating`)."""
    has_data = any(_data_flag_value(a)[0] for a in gh_argv)
    out = []
    i = 0
    while i < len(gh_argv):
        a = gh_argv[i]
        if not has_data:
            if a in METHOD_FLAGS and i + 1 < len(gh_argv) and gh_argv[i + 1].strip().upper() == "GET":
                i += 2
                continue
            if a.startswith("--method=") and a.split("=", 1)[1].strip().upper() == "GET":
                i += 1
                continue
            if a.startswith("-X") and len(a) > 2 and a[2:].strip().upper() == "GET":
                i += 1
                continue
        out.append(a)
        i += 1
    return out


def flight_key(gh_argv):
    """The NORMALISED REQUEST: host + credential + the cwd repo pin + endpoint + argv.

    All four decorations are here for the reasons the ETag key already states them: a GHES host or a
    second credential yields a DIFFERENT representation for the same argv, and a `--repo`-less
    subcommand resolves its repository from the CWD, so two checkouts of two repos issue an identical
    argv that must not share an answer."""
    toks = normalised_request(gh_argv)
    lead = _leading_tokens(toks)
    endpoint = lead[1] if len(lead) > 1 and lead[0] == "api" else ""
    try:
        cwd = os.getcwd()
    except OSError:
        cwd = ""
    # ⛔ `GH_REPO` IS PART OF THE IDENTITY. gh resolves a `--repo`-less call from `--repo` > `GH_REPO` >
    # the cwd's remote, and it substitutes `{owner}`/`{repo}`/`{branch}` in an `api` endpoint from the
    # same source — so two processes in the SAME cwd with DIFFERENT `GH_REPO` issue different requests
    # that the cwd pin alone cannot tell apart (the wrong-repo class this key exists to prevent, found
    # in review round 7). `GH_HOST` is here for the identical reason.
    parts = [os.environ.get("GH_HOST") or "", os.environ.get("GH_REPO") or "", _cred_digest(), cwd,
             endpoint] + toks
    return hashlib.sha256("\x00".join(parts).encode("utf-8", "surrogateescape")).hexdigest()[:40]


def flight_dir():
    d = os.path.join(state_dir(), "flights")
    try:
        os.makedirs(d, mode=0o700, exist_ok=True)
    except OSError:
        return None
    return d


def _read_json(path):
    try:
        with open(path) as fh:
            d = json.load(fh)
        return d if isinstance(d, dict) else None
    except (OSError, ValueError):
        return None


def _holder_dead(meta):
    """Is the leader's PROCESS gone? An unknown pid proves nothing (the age bound then decides) —
    and `os.kill` is not arbitrary-precision, so a junk pid in a hand-edited claim is refused rather
    than raised out of every gh call on the box (the same trap `_dead_writer` documents)."""
    pid = meta.get("pid") if isinstance(meta, dict) else None
    if not isinstance(pid, int) or not (0 < pid < 1 << 22) or pid == os.getpid():
        return False
    try:
        os.kill(pid, 0)
        return False
    except OverflowError:
        return False
    except OSError as exc:
        return exc.errno != errno.EPERM


def flight_claim(key, gh_argv):
    """Become the leader for `key`. Returns `("leader", path, meta)`, `("held", None, None)` when
    another caller holds the key, or `("error", None, None)` when the claim could not even be
    attempted.

    ⛔ ONE ATOMIC CREATE IS THE CLAIM. Write-then-rename would let two callers both believe they won,
    which is two leaders for one key and exactly the duplicate work this section removes.

    ⛔ AND THE THREE OUTCOMES ARE DISTINCT ON PURPOSE. `held` means WAIT for that peer; `error` means
    the flight directory itself is unusable (unwritable, full, gone), where waiting would turn a
    broken cache dir into a slow failure on every eligible call and flying unshared is the honest
    degradation. Collapsing them into a `None` plus a later `os.path.exists` test loses the
    distinction exactly when it bites: a peer that finishes between the failed create and the
    existence check then reads as "no directory", and the duplicate request comes straight back."""
    d = flight_dir()
    if d is None:
        return "error", None, None
    path = os.path.join(d, key + ".leader")
    started = _now()
    meta = {"pid": os.getpid(), "started_at": started,
            # ⛔ EVERY CLAIM CARRIES ITS OWN IDENTITY, so a later step can ask "is the file on disk
            # still MINE?" before removing it. Without it a leader whose key was taken over unlinks
            # its SUCCESSOR's claim in its own `finally` (the cascade in review round 2), and a
            # takeover cannot tell the claim it judged from the one that replaced it.
            "flight": "%d@%.3f@%s" % (os.getpid(), started, os.urandom(4).hex()),
            "request": _flight_label(gh_argv)}
    try:
        fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError:
        return "held", None, None
    except OSError:
        return "error", None, None
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump(meta, fh)
    except OSError:
        try:
            os.unlink(path)
        except OSError:
            pass
        return "error", None, None
    return "leader", path, meta


def flight_publish(key, meta, rc, out, err):
    """Publish THIS flight's outcome — its bytes AND its exit code, a failure included."""
    d = flight_dir()
    if d is None:
        return False
    size = len(out) + len(err)
    if size > FLIGHT_MAX_ENTRY:
        # Too big to share. Publishing nothing makes the waiters take the key over and run the call
        # themselves (serialised by the lock, as before) — the honest degradation, and stated here so
        # a 4 MiB read never turns into a silent `busy`.
        log_event("single-flight: `%s` produced %dB — too large to share; waiters take the key over"
                  % (meta.get("request", ""), size))
        return False
    path = os.path.join(d, key + ".json")
    tmp = path + ".tmp-%d" % os.getpid()
    rec = {"flight": meta.get("flight") or "%d@%.3f" % (meta["pid"], meta["started_at"]),
           "request": meta.get("request", ""),
           "started_at": meta["started_at"], "finished_at": _now(), "rc": rc,
           "out_b64": base64.b64encode(out).decode("ascii"),
           "err_b64": base64.b64encode(err).decode("ascii")}
    try:
        with open(tmp, "w") as fh:
            json.dump(rec, fh)
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return False
    return True


def flight_result(d, key):
    """The last PUBLISHED outcome for `key`, with its completion time, or None. A corrupt or
    half-written entry is a miss, never an error."""
    rec = _read_json(os.path.join(d, key + ".json"))
    if rec is None:
        return None
    try:
        return {"rc": int(rec["rc"]),
                "out": base64.b64decode(rec["out_b64"].encode("ascii")),
                "err": base64.b64decode(rec["err_b64"].encode("ascii")),
                "started_at": float(rec.get("started_at") or 0),
                "finished_at": float(rec["finished_at"]),
                "request": rec.get("request", "")}
    except (KeyError, TypeError, ValueError, binascii.Error):
        return None


def _leading_tokens(gh_argv, cap=3):
    """The leading NON-FLAG tokens of an argv, stopping at the FIRST flag.

    ⛔ THIS IS THE ONLY SAFE WAY TO NAME A REQUEST. A "first positional" scan takes a flag's VALUE
    (`gh api -H 'Authorization: Bearer …' repos/o/r` has `Authorization: Bearer …` as its first
    non-dash token), so a human-readable label built that way would write a credential wherever the
    label goes — the claim file, the result file and `events.log`. Stopping at the first flag makes
    that impossible by construction, while `gh api repos/o/r/pulls/9426` (no flags) still reads
    exactly as an operator expects."""
    out = []
    for a in gh_argv:
        if a.startswith("-"):
            break
        out.append(a)
        if len(out) >= cap:
            break
    return out


def _flight_label(gh_argv):
    """A request name that is SAFE TO PERSIST: the subcommand and the leading positionals, never a
    flag or a flag's value. This label is written to the claim file, to the result file (which
    outlives the call by `GH_LIMIT_FLIGHT_KEEP_S`) and to `events.log` — the ETag cache stores only a
    digest for precisely this reason, and a label must not undo what the key protects."""
    return ("gh " + " ".join(_leading_tokens(gh_argv)))[:120].strip()


def _leader_stale(meta, path, now):
    """Has the holder given up on the key? Gone (a kill, a crash, a power loss) or older than the age
    bound.

    ⛔ AN UNREADABLE OR UNATTRIBUTABLE CLAIM IS JUDGED BY ITS MTIME — it must not be declared stale on
    sight (a leader that has just created the file is alive and about to write it, and stealing its
    key would run the request twice), and it must not be immortal either. A leader killed between
    `os.open(O_EXCL)` and its `json.dump` leaves a ZERO-LENGTH claim, and one that is never removed
    holds that key for every later caller: the orphan lock file #2243 forbids. A parsed claim whose
    pid is not a live int AND whose `started_at` is unusable is in the same class, so it falls back
    to the file's age too."""
    started = 0.0
    if isinstance(meta, dict):
        try:
            started = float(meta.get("started_at") or 0)
        except (TypeError, ValueError):
            started = 0.0
        if _holder_dead(meta):
            return True
    if started > 0:
        return (now - started) > FLIGHT_LEADER_MAX_AGE
    try:
        return (now - os.path.getmtime(path)) > FLIGHT_LEADER_MAX_AGE
    except OSError:
        return True


def _take_over(leader_path, judged):
    """Atomically REMOVE a stale claim, so exactly ONE waiter can then claim the key.

    ⛔ `os.rename` IS THE COMPARE-AND-SWAP. Unlink-then-create is two steps, and in the microseconds
    between them a peer that has just claimed is deleted by the loser — two leaders for one key, i.e.
    the duplicate load this whole section exists to remove (review round 2, found in exactly the
    burst this feature targets). A rename of the SAME path is atomic: the first waiter moves the
    stale claim aside and the second gets ENOENT and simply loses the race; `flight_claim`'s O_EXCL
    then decides which of them leads.

    ⛔ AND A CLAIM WE DID NOT JUDGE IS PUT BACK, NOT DESTROYED. `os.link` restores it WITHOUT clobbering
    a third claim (a plain rename back could), and if a third claim is already there (EEXIST) the moved
    file is LEFT for the reaper rather than unlinked — destroying a live peer's claim is the one
    outcome this function must not produce.

    ⛔ "DID WE MOVE THE CLAIM WE JUDGED?" IS AN IDENTITY TEST, NOT "is one of them readable". The
    first version only restored when BOTH sides parsed (`judged_id and moved is a dict and ids
    differ`), so two cases still deleted a live peer's claim (review round 5): we judged an UNREADABLE
    claim and a peer had since written a good one, or we judged a good one and a peer had since
    written an unreadable one. Identity now means "both unreadable" or "both readable with the SAME
    flight id"; anything else is a claim we did not judge."""
    aside = leader_path + ".stale-%d" % os.getpid()
    try:
        os.rename(leader_path, aside)
    except OSError:
        return False                    # someone else moved it first: we lost, just wait for them
    moved = _read_json(aside)
    # "Is the file still EXACTLY the claim I judged?" — content identity, not "do the ids match". The
    # flight id is the claim's own name, but a claim can legitimately arrive without one (a hand-written
    # or older claim is still judged stale by pid/age), and comparing the id alone then answered
    # "not mine" for a claim we HAD judged — leaving a dead holder's key unreleased for ever (caught by
    # the dead-pid fixture). Equality of the parsed claim answers both questions at once: unchanged ⇒ it
    # is ours to remove; anything else ⇒ a peer replaced it, so restore.
    same = judged == moved
    if same:
        try:
            os.unlink(aside)
        except OSError:
            pass
        return True                     # the claim we judged: it IS stale, so the key is free
    try:
        os.link(aside, leader_path)     # atomic: refuses to clobber a third claim
        os.unlink(aside)
    except OSError:
        pass                            # EEXIST: a third claim is live — leave the aside to the reaper
    return False                        # a claim we did not judge: a live peer owns the key, back off


def _unlink_claim(leader_path, flight_id):
    """Remove the claim at `leader_path` ONLY IF it is provably OURS (`flight_id`).

    ⛔ A LEADER MUST NOT UNLINK ITS SUCCESSOR'S CLAIM. When a stale claim is taken over, the old
    leader may still be running; its `finally` would otherwise delete the new leader's claim and a
    third caller could claim concurrently — the same double-lead, reached from the other side.

    ⛔ AND AN UNREADABLE FILE IS NOT "OURS BY DEFAULT". The first version unlinked whenever the read
    came back None, which includes a SUCCESSOR's claim inside its own `os.open(O_EXCL)` → `json.dump`
    window: the successor then writes to an orphaned inode and a third caller claims concurrently
    (review round 6). Removal now requires a POSITIVE identity match; anything else is left to
    `_leader_stale` / `prune_flights`, which reclaim by age."""
    cur = _read_json(leader_path)
    if not (isinstance(cur, dict) and flight_id and cur.get("flight") == flight_id):
        return False
    try:
        os.unlink(leader_path)
        return True
    except OSError:
        return False


def prune_flights(d):
    """Keep the flight directory bounded, and collect what a KILLED leader left behind: its claim
    (the orphan lock file #2243 forbids) and a staging file whose writer is gone."""
    if not d:
        return
    try:
        names = os.listdir(d)
    except OSError:
        return
    now = _now()
    for n in names:
        fp = os.path.join(d, n)
        try:
            if ".tmp-" in n or ".stale-" in n:
                # A staging file or a moved-aside claim: ours only to collect once its writer is gone
                # (`_take_over` removes its own aside on the normal path, so this is the crash half).
                if _dead_writer(fp):
                    os.unlink(fp)
                continue
            if ".leader" in n:
                # ⛔ ONE READ FEEDS BOTH THE VERDICT AND `_take_over`'s IDENTITY. Reading twice let a
                # peer's fresh claim land between them: the staleness verdict used the OLD claim while
                # `_take_over` judged (and so removed) the NEW one — a live peer's claim destroyed by
                # the reaper (review round 6).
                judged = _read_json(fp)
                if _leader_stale(judged, fp, now):
                    _take_over(fp, judged)
                continue
            if n.endswith(".json"):
                rec = _read_json(fp)
                try:
                    fin = float((rec or {}).get("finished_at") or 0)
                except (TypeError, ValueError):
                    fin = 0.0
                if not fin or (now - fin) > FLIGHT_KEEP_S:
                    os.unlink(fp)
        except OSError:
            continue


def _run_captured(real_gh, gh_argv):
    """`_dispatch` with BOTH streams captured, returning (rc, out, err) — the caller's own bytes.
    Two separate captures, never one shared object: merging them here would break every caller that
    redirects stderr to a file and parses stdout as JSON (the rule `_StreamCapture` states)."""
    cap_out, cap_err = _StreamCapture(), _StreamCapture()
    saved = (sys.stdout, sys.stderr)
    sys.stdout, sys.stderr = cap_out, cap_err
    try:
        rc = _dispatch(real_gh, gh_argv)
    finally:
        sys.stdout, sys.stderr = saved
        out, err = cap_out.getvalue(), cap_err.getvalue()
    return rc, out, err


def _emit_streams(rc, out, err):
    """Write captured bytes to the caller exactly as the child produced them — never one stream
    without the other, and never an added line."""
    if out:
        sys.stdout.buffer.write(out)
    if err:
        sys.stderr.buffer.write(err)
    return rc


def _lead(real_gh, gh_argv, key, claimed):
    """Perform the shared load (this process is the leader for `key`), publish it, release the key."""
    path, meta = claimed
    try:
        rc, out, err = _run_captured(real_gh, gh_argv)
        flight_publish(key, meta, rc, out, err)
        return rc, out, err
    finally:
        # ⛔ THE LEADER ALWAYS RELEASES ITS OWN KEY: a failed publish, an exception, any exit path. A
        # claim left behind is an orphan lock file, and waiters would spend their whole bound on a
        # holder that has already gone. `_unlink_claim` keeps that from becoming the OPPOSITE bug —
        # deleting a successor's claim after a takeover.
        _unlink_claim(path, meta.get("flight"))
        prune_flights(os.path.dirname(path))


def _busy(gh_argv, leader, age, budget):
    """The DISTINCT outcome of a waiter whose bound expired: not an answer, and never a QUOTA refusal.

    ⛔ THE WORDS "rate limit" MAY NOT APPEAR, NOT EVEN NEGATED. `scripts/objective.py` classifies a gh
    failure with `TRANSPORT_MARKERS`, a plain substring scan whose first entry is `"rate limit"`
    (`_note_gh_failure` then records `RATE-LIMITED`). "This is NOT a rate limit" CONTAINS the marker,
    so a `busy` — the one outcome this layer says is deliberately not a refusal — was classified as a
    limit and the fleet waited out a quota that was never exhausted (review round 6). The message
    therefore says `quota`, and the test asserts the ABSENCE of the classifier's marker rather than the
    presence of a parenthesis."""
    req = (leader or {}).get("request") or _flight_label(gh_argv)
    who = ("pid %s" % leader.get("pid")) if leader else "an unreadable holder"
    aged = ("%ds in flight" % age) if age >= 0 else "of unknown age"
    msg = ("gh-limit: BUSY single-flight — `%s` is being loaded by %s, %s, and this caller's "
           "bound is %.1fs. This is NOT an answer and NOT quota exhaustion: retry.\n"
           % (req, who, aged, budget))
    log_event("single-flight: BUSY after %.1fs for `%s` (holder=%s age=%ds)" % (budget, req, who, age))
    return BUSY_EXIT, b"", msg.encode()


def single_flight(real_gh, gh_argv):
    """One load per key, shared by every identical caller in flight. Returns (rc, out, err).

    THREE outcomes, all distinct: the answer (own or the leader's), the LEADER'S FAILURE (his exit
    code and his error — never a success he did not have), or BUSY (exit 75 and the holder's age)
    when the bound expires."""
    key = flight_key(gh_argv)
    d = flight_dir()
    if d is None:
        # A state dir that cannot hold flights must not fail a gh call — but it must not silently
        # claim the call was shared either: `state_dir()` has already announced the degraded dir, and
        # this line names the consequence for THIS call.
        log_event("single-flight: no usable %s — this call runs UNSHARED"
                  % os.path.join(state_dir(), "flights"))
        return _run_captured(real_gh, gh_argv)
    leader_path = os.path.join(d, key + ".leader")
    # ⛔ A BOUNDED CALLER MUST NOT DIE IN THIS QUEUE EITHER. `GH_LIMIT_NO_WAIT` bounds the backoff and
    # the lock; the flight wait is the third wait this layer imposes, so it takes the same budget rule
    # (`acquire_lock`), or a bounded caller's flight wait outlives the caller it is trying to help.
    budget = min(FLIGHT_WAIT, NO_WAIT_LOCK_S) if NO_WAIT else FLIGHT_WAIT
    t_arrive = _now()                          # arrival, from the same real clock as the records
    deadline = time.monotonic() + budget        # real monotonic: the BOUND is not the ledger's clock
    while True:
        res = flight_result(d, key)
        if res is not None and res["finished_at"] >= t_arrive:
            # ⛔ ONLY A FLIGHT THAT COMPLETED AFTER THIS CALLER ARRIVED IS SHARED. An older result is
            # a cache entry, and this is not a cache: handing one out as current is the exact failure
            # #2243 clause 5 forbids.
            log_event("single-flight: shared the in-flight answer for `%s` (rc=%d)" % (res["request"], res["rc"]))
            if res["rc"] == 0:
                # ⛔ A SHARED **FAILURE** IS NOT AN AVERTED REQUEST (review P2). Counting every share
                # made the instrument read BEST during the incident it exists to measure: a refusal
                # shared by 25 lanes reported `averted=24` while nothing was served and nothing was
                # saved. Only a SERVED share is one request the box did not send.
                stats_record("single-flight", "share")
            return res["rc"], res["out"], res["err"]
        leader = _read_json(leader_path)
        # ⛔ A MISSING CLAIM IS NOT A STALE ONE. `_leader_stale(None, …)` answers True for an absent
        # path (getmtime raises), and an UNCONDITIONAL unlink on that verdict is itself a race: a peer
        # can create the claim between the check and the unlink, and the loser then deletes the
        # WINNER's fresh claim — two leaders for one key, which is the duplicate load this exists to
        # remove (review round 2). Absent ⇒ claim directly, remove nothing.
        if leader is None and not os.path.exists(leader_path):
            how, claim_path, claim_meta = flight_claim(key, gh_argv)
            if how == "leader":
                return _lead(real_gh, gh_argv, key, (claim_path, claim_meta))
            if how == "error":
                # The directory cannot hold a claim at all — waiting the bound for a leader that can
                # never exist is the one thing a degraded state dir may not do. Announced, because a
                # box whose flight dir is broken is running uncoalesced and must be findable.
                log_event("single-flight: cannot claim a key in %s — this call runs UNSHARED" % d)
                return _run_captured(real_gh, gh_argv)
            leader = _read_json(leader_path)    # "held": a peer won the create — wait for ITS answer
        elif _leader_stale(leader, leader_path, _now()):
            # Nginx's `proxy_cache_lock_age` half: the holder is gone, has been at it far too long, or
            # left a claim nobody can read — so the key is released and exactly ONE waiter may take it
            # (`_take_over` is atomic: the rename is the compare-and-swap).
            # ⛔ THE REMOVAL IS NOT CONDITIONAL ON THE CLAIM PARSING. An unparseable claim is exactly
            # the one that would otherwise be immortal: `flight_claim` would answer EEXIST for ever and
            # every caller for the key would get `busy`. Announced in both shapes — a box taking keys
            # over is a box with a stalled request, which an operator must see.
            if leader is not None:
                try:
                    age = int(max(0.0, _now() - float(leader.get("started_at") or 0)))
                except (TypeError, ValueError):
                    age = 0
                log_event("single-flight: taking the key over from `%s` (age=%ds, holder_alive=%s)"
                          % (leader.get("request", "?"), age,
                             "no" if _holder_dead(leader) else "yes"))
            else:
                try:
                    age = int(max(0.0, _now() - os.path.getmtime(leader_path)))
                except OSError:
                    age = 0
                log_event("single-flight: removing an UNREADABLE claim that is %ds old (%s)" % (age, key))
            if _take_over(leader_path, leader):
                how, claim_path, claim_meta = flight_claim(key, gh_argv)
                if how == "leader":
                    return _lead(real_gh, gh_argv, key, (claim_path, claim_meta))
                if how == "error":
                    log_event("single-flight: cannot claim a key in %s — this call runs UNSHARED" % d)
                    return _run_captured(real_gh, gh_argv)
            leader = _read_json(leader_path)        # a peer won it, or took it over: wait for theirs
        if FLIGHT_STALE_SERVE and leader is not None:
            stale = flight_result(d, key)
            if stale is not None and stale["rc"] == 0 and stale["finished_at"] < t_arrive:
                age = int(max(0.0, t_arrive - stale["finished_at"]))
                if age <= FLIGHT_STALE_MAX_AGE:
                    # STALE-WHILE-REFRESH, and LABELLED: the caller asked for this trade, and it is
                    # never presented as a current read (this fleet has been burned by exactly that).
                    label = ("gh-limit: STALE — served a %ds-old answer for `%s` because a refresh is in "
                             "flight (pid %s). Not a fresh read (GH_LIMIT_FLIGHT_STALE_SERVE=1).\n"
                             % (age, stale["request"], leader.get("pid")))
                    log_event("single-flight: STALE age=%ds served for `%s` (refresh in flight)"
                              % (age, stale["request"]))
                    return stale["rc"], stale["out"], stale["err"] + label.encode()
        if time.monotonic() >= deadline:
            try:
                started = float((leader or {}).get("started_at") or 0)
            except (TypeError, ValueError):
                started = 0.0
            if started <= 0:
                # ⛔ A CLAIM NOBODY CAN READ HAS NO `started_at`, AND `now - 0` IS THE EPOCH. A leader
                # killed mid-claim leaves a zero-length file, and the waiter then reported
                # "1792603104s in flight" — an age label that names nothing (review round 7). The
                # claim file's own mtime is the evidence of how long the holder has had the key.
                try:
                    age = int(max(0.0, _now() - os.path.getmtime(leader_path)))
                except OSError:
                    age = -1                       # unknown: `_busy` says so instead of inventing one
            else:
                age = int(max(0.0, _now() - started))
            return _busy(gh_argv, leader, age, budget)
        time.sleep(FLIGHT_POLL_S)


# ── READ CACHE: a TTL per query class, for facts a merge can survive being seconds old ─────────
# WHY, ON TOP OF SINGLE FLIGHT (#2243). Single flight removes the DUPLICATE call; it deliberately
# shares only a result that COMPLETED AFTER the caller arrived, so N lanes that ask the same question
# a minute apart still make N requests. Measured 2026-10-22: the fleet spent the account's whole REST
# pool (5000/h) on polls whose answers had not changed — a PR's head sha, its required checks, its
# comments — while `/rate_limit` answered `core: 0 remaining` and GraphQL still held 4769.
#
# ⛔ THIS IS NOT THE FLIGHT PATH'S STALE-SERVE, AND THE DIFFERENCE IS THE POINT. `FLIGHT_STALE_SERVE`
# hands out an answer of UNKNOWN age while a refresh runs, which is why it is off by default and
# LABELLED when on. This hands out an answer PROVABLY younger than its class's TTL — a bound, not a
# bet — and it is silent on the caller's streams (the “streams are sacred” rule: a cache notice on a
# successful call would corrupt the JSON that `gh-rest/gh` and `rest_list` parse).
#
# ⛔ AN UNLISTED SHAPE IS NEVER CACHED. There is deliberately NO default TTL: a default is how a
# cache silently starts lying about a fact nobody reasoned about.
#
# ⛔ AND THE `gh api` SURFACE IS NOT IN THE LIST AT ALL — THAT BOUNDARY IS THE WHOLE SAFETY ARGUMENT.
# An unvalidated TTL is only defensible where nothing else validates staleness AND the value is not
# read-modify-written. `gh api` fails BOTH tests:
#   * it already HAS a validator — the ETag/`conditional_fetch` path returns the real body on change and
#     costs no quota on a 304, so a TTL entry there is strictly worse (staler, unvalidated);
#   * `record-review.sh` and `atomic-land.sh` READ `pulls/{n}`'s `.body` and PATCH it back whole, so a
#     10 s stale body is a LOST UPDATE — lane A's marker, or a human's edit, silently gone, both lanes
#     exiting 0 (found in review round 5, reproduced: two reads 1 s apart, one request, the second the
#     first body); and `admin-merge.sh` reads `commits/…/status` for a merge DECISION, where a 10 s
#     window can miss a just-landed red.
#
# So the TTL cache covers exactly the ETag-free surface: the SUBCOMMANDS below, which are GraphQL (no
# ETag exists at all) and are the traffic whose only saving today is single flight. Their TTLs are
# sized to the poll cadence that produces the waste, so the cost of staleness is one poll:
#   * `pr-list` 5 s — a board read polled per lane;
#   * `run-list` 10 s — the MEASURED hotspot; see its entry below.
# ⛔ AND NO DECISION-CARRYING SHAPE IS CACHED — not `pr-state` (the head a merge and the review evidence
# are bound to) and not `checks` (whether to merge). See READ_SUBCOMMAND_CLASSES.
# ⛔ AND ONLY A SUCCESS IS STORED. A failure is evidence about a MOMENT; caching one turns a transient
# fault into a stable “unreadable” for every lane on the box (the pass cache's rule, restated because
# it is the same defect class and it has bitten this file before).
READ_CACHE_ENV = "GH_LIMIT_READ_CACHE"        # "0" disables the TTL cache entirely
READ_CACHE_MAX_BYTES = cfg_int("GH_LIMIT_READ_CACHE_MAX_BYTES", 32 << 20, 1024, 1 << 30)

# (class, path pattern, TTL seconds) — matched against the ENDPOINT `api_endpoint` attributes.
# Subcommand shapes only (GraphQL) — see the boundary argument above. There is intentionally no `gh
# api` class: that surface is the ETag path's, and caching it unvalidated is a lost-update hazard.
# The SUBCOMMANDS whose answer is one of those classes. A board LISTING and a run-state POLL are not
# decisions; the head sha and the check surface are, and they are deliberately absent.
READ_SUBCOMMAND_CLASSES = (
    # ⛔ `pr-state` IS NOT HERE EITHER, AND FOR THE SAME REASON AS `checks` BELOW: `gh pr view --json
    # headRefOid` IS THE HEAD A DECISION IS MADE ON. The licence for a 10 s window was “a stale head
    # sha makes GitHub REFUSE a merge whose sha no longer matches” — true on the rail
    # (`admin-merge.sh --match-head-commit`), FALSE on the other merge path, whose merge is UNPINNED,
    # and false again for the review recorder, which binds evidence and checks the signed marker against
    # the head it read (`record-review.sh`: `@ <head>`). Both re-read through THIS cache, so a stale
    # entry could park a reviewed PR or accept the previous head's marker while an unpinned merge lands
    # the live head — measured: two reads 1 s apart across a head flip both returned the old sha on ONE
    # request. What remains cached is the two shapes whose answer is not a decision: a board LISTING
    # (bounded staleness, no verdict) and a RUN-LIST poll.
    ("pr-list",  ("pr", "list"), 5),
    # ⛔ `gh pr checks` IS DELIBERATELY **NOT** HERE, AND IT WAS REMOVED FOR A REASON THAT IS MEASURED.
    # Its answer is a MERGE DECISION: `merge-one.sh` computes its gate from `gh pr checks --json
    # name,state`, breaks on SUCCESS, and the merge it then issues is unpinned (no
    # `--match-head-commit`), while the cache key carries no head sha. So a 10 s window can serve the
    # PREVIOUS head's SUCCESS for a PR whose new head is PENDING. Measured with the class in place: two
    # reads 1 s apart across a SUCCESS->PENDING flip both returned SUCCESS on ONE request. It is not
    # covered by the “a stale head is caught server-side” argument that licenses `pr-state`, because
    # nothing in the decision re-reads the head. Cheap and safe still holds: single flight coalesces
    # CONCURRENT identical reads (the 25-lanes-one-call property the incident asks for) without ever
    # serving an older answer to a later caller.
    #
    # ⛔ MEASURED HOTSPOT, and the reason the next one IS here. One merge cycle was counted end to end
    # (2026-10-22, PR 9134): 41 gh invocations, of which **30 — 73 % — were ONE poll loop**, the
    # FIRST-CHECKS wait. Each 10-second iteration issues `run list …` plus
    # `jobs?per_page=100 --paginate`, and `run list` ran with BYTE-IDENTICAL argv 16 times against data
    # that had not changed once in 150 s. That loop reads RUN STATE, which is not a merge key: a stale
    # `completed` only delays the next poll, and no decision is taken on it.
    ("run-list", ("run", "list"), 10),
)
# Flags that make an answer depend on something beyond the endpoint (a page, a header framing, a
# template, a changed representation). A shape carrying one is NEVER cached: `--paginate` returns ONE
# PAGE per invocation, so replaying it would answer a different question than the caller asked.
READ_UNCACHEABLE_FLAGS = frozenset({
    "--paginate", "--include", "-i", "--slurp", "--template", "-t", "-H", "--header",
    "--input", "-p", "--preview",
})


def read_cache_enabled():
    return cfg(READ_CACHE_ENV, "1") != "0"


def read_class(gh_argv):
    """(name, ttl) for an invocation the TTL cache admits, or None.

    ⛔ THE SAME REFUSALS AS THE FLIGHT PATH, FOR THE SAME REASONS: never a mutation (replaying its
    stdout reports work it did not do — and it would DROP it), never `auth` (its stdout IS the
    credential, and this cache is on disk), never `/rate_limit` (it is the budget METER: a frozen
    meter cannot see the exhaustion this section exists to make survivable)."""
    if not gh_argv:
        return None
    if gh_argv[0] == "auth" or not makes_request(gh_argv):
        return None
    # ⛔ THE STATED CONTRACT, IMPLEMENTED. `READ_UNCACHEABLE_FLAGS` was defined and never consulted, so
    # a shape carrying `--template` / `--include` / `--paginate` was cached anyway — measured: three
    # `gh pr list --template '{{.number}}'` calls made ONE request and `events.log` recorded two
    # `pr-list` hits. `--paginate` returns ONE PAGE per invocation, so a cached replay answers a
    # different question than the caller asked; the rest frame or reshape the output. A future flag
    # added to that set must take effect, which it only does if something reads it.
    for a in gh_argv:
        if a in READ_UNCACHEABLE_FLAGS or any(a.startswith(f + "=") for f in READ_UNCACHEABLE_FLAGS):
            return None
    if gh_argv[0] == "api":
        # ⛔ `gh api` IS NEVER TTL-CACHED — not an omission, the safety boundary (see the header).
        # It has an ETag validator, and its body is read-modify-written by the review recorder.
        return None
    if len(gh_argv) >= 2:
        for name, pair, ttl in READ_SUBCOMMAND_CLASSES:
            if (gh_argv[0], gh_argv[1]) == pair:
                return name, ttl
    return None


def read_cache_dir():
    d = os.path.join(state_dir(), "reads")
    try:
        os.makedirs(d, mode=0o700, exist_ok=True)
    except OSError:
        return None
    return d if os.path.isdir(d) else None


def read_cache_get(key, ttl):
    """(rc, out, err) from the fleet-wide TTL cache when it is FRESH, else None."""
    d = read_cache_dir()
    if d is None:
        return None
    try:
        with open(os.path.join(d, key + ".json")) as fh:
            e = json.load(fh)
        if int(e["rc"]) != 0:
            return None            # never trust a stored failure (see the exclusion list)
        if clock() - float(e["at"]) > ttl:
            return None            # too old for THIS class: ask GitHub
        if float(e["at"]) > clock() + 60:
            # ⛔ A STAMP FROM THE FUTURE IS NOT A FRESH ENTRY. A clock step backwards (NTP, a VM
            # resume) would otherwise serve an entry as fresh until wall time catches up — the same
            # class `pace_mutation` already refuses to honour.
            return None
        return (0, base64.b64decode(e["out_b64"].encode("ascii")),
                base64.b64decode(e["err_b64"].encode("ascii")))
    except (OSError, ValueError, KeyError, TypeError, binascii.Error):
        return None                # a corrupt/partial entry is a MISS, never an error


def read_cache_put(key, rc, out, err):
    """Store ONE successful answer, bounded in BYTES (the entries here are small, and a byte bound
    is the one that actually protects the disk). A full cache must never fail a call."""
    d = read_cache_dir()
    if d is None or rc != 0:
        return
    size = len(out) + len(err) + 512
    try:
        used = sum(os.path.getsize(os.path.join(d, n)) for n in os.listdir(d))
        if used + size > READ_CACHE_MAX_BYTES:
            entries = sorted(((os.path.getmtime(os.path.join(d, n)), n)
                              for n in os.listdir(d) if n.endswith(".json")), key=lambda t: t[0])
            for _, n in entries:
                fp = os.path.join(d, n)
                used -= os.path.getsize(fp)
                os.unlink(fp)
                if used + size <= READ_CACHE_MAX_BYTES:
                    break
            if used + size > READ_CACHE_MAX_BYTES:
                return
    except OSError:
        return
    p = os.path.join(d, key + ".json")
    tmp = p + ".tmp-%d" % os.getpid()
    try:
        with open(tmp, "w") as fh:
            json.dump({"at": clock(), "rc": rc,
                       "out_b64": base64.b64encode(out).decode("ascii"),
                       "err_b64": base64.b64encode(err).decode("ascii")}, fh)
        os.replace(tmp, p)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


# ── THE SAVING MUST BE MEASURABLE (#2342) ────────────────────────────────────────────────────────
# “A cache that cannot show its hit rate is not an instrument.” Every TTL hit and every single-flight
# share is ONE `gh` request this box did NOT send, and the whole point of the layer is to turn the
# fleet's spend into a number an operator can read instead of a suspicion. So each event is APPENDED
# as one JSON line (`O_APPEND` on a small line is atomic, so concurrent lanes cannot lose each
# other's counts the way a read-modify-write of one JSON document would), the log is rotated at 1 MiB
# (one old file kept: counters must never be a disk leak), and `--stats` aggregates both files.
# ⛔ IT IS A LOCAL FILE READ — no request, no credentials, so it is usable at the exact moment the
# budget is gone, which is when the question “what did the cache save us?” is asked.
STATS_FILE = "read-cache-stats.jsonl"
STATS_CARRY_FILE = "read-cache-totals.json"
STATS_ROTATE_BYTES = 1 << 20


def _stats_add(doc, cls, kind, at=None):
    one = doc["classes"].setdefault(cls, {})
    one[kind] = one.get(kind, 0) + 1
    if isinstance(at, int) and (doc.get("since") is None or at < doc["since"]):
        doc["since"] = at


def stats_carry():
    try:
        with open(os.path.join(state_dir(), STATS_CARRY_FILE)) as fh:
            doc = json.load(fh)
        if isinstance(doc.get("classes"), dict):
            return {"since": doc.get("since"), "classes": doc["classes"]}
    except (OSError, ValueError, TypeError):
        pass
    return {"since": None, "classes": {}}


def _stats_write_carry(doc):
    p = os.path.join(state_dir(), STATS_CARRY_FILE)
    tmp = p + ".tmp-%d" % os.getpid()
    try:
        with open(tmp, "w") as fh:
            json.dump(doc, fh)
        os.replace(tmp, p)
        return True
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return False


def stats_fold():
    """Rotation: fold the live file into a CUMULATIVE carry, then empty it.

    ⛔ ROTATION MUST NOT MAKE THE COUNT GO DOWN (review P2). Replacing a `…jsonl.1` dropped the totals
    it held, so `averted` could read SMALLER on a later run — “lost data, or a cache regression” to the
    only reader this instrument has. Folding first makes the total monotone; nothing is summed twice
    because a successful fold REMOVES the live file."""
    p = os.path.join(state_dir(), STATS_FILE)
    # ⛔ RENAME BEFORE READING (#2342 review P2). Read-then-unlink lost every event appended between
    # the two (measured 3/3 on a 300 k-line file) and let two folds contribute the same lines to the
    # carry. The rename is atomic, so concurrent appends land in a FRESH live file, and the fold only
    # ever owns the renamed one.
    folded = p + ".folding-%d" % os.getpid()
    try:
        os.replace(p, folded)
    except OSError:
        return
    try:
        with open(folded) as fh:
            lines = fh.readlines()
    except OSError:
        lines = []
    # ⛔ A CORRUPT CARRY IS NOT A ZERO (review P2). Overwriting it with a carry built only from the
    # live file made the reported total DROP while `--stats` stopped saying UNREADABLE — the exact
    # symptom the fold exists to prevent, reachable one rotation later. Skip the fold and let the
    # instrument report UNREADABLE until a human clears it.
    carry_path = os.path.join(state_dir(), STATS_CARRY_FILE)
    if os.path.exists(carry_path):
        try:
            with open(carry_path) as fh:
                json.load(fh)
        except (OSError, ValueError):
            log_event("stats: the cumulative carry is unparseable — fold SKIPPED, counters kept in %s"
                      % folded)
            os.rename(folded, p + ".unreadable-carry")
            return
    doc = stats_carry()
    for line in lines:
        try:
            e = json.loads(line)
        except ValueError:
            continue
        cls, kind = e.get("cls"), e.get("kind")
        if isinstance(cls, str) and isinstance(kind, str):
            _stats_add(doc, cls, kind, e.get("at"))
    if _stats_write_carry(doc):
        try:
            os.unlink(folded)
        except OSError:
            pass
    else:
        # ⛔ A FAILED CARRY WRITE MUST NOT EAT THE EVENTS (review P2). Put them back where the reader
        # looks; an orphan `*.folding-<pid>` is invisible to `stats_report`, so ENOSPC/EACCES/a kill
        # would silently shrink every later total.
        try:
            fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
            try:
                os.write(fd, "".join(lines).encode())
            finally:
                os.close(fd)
            os.unlink(folded)
        except OSError:
            pass                       # the `.folding-*` copy remains the only record; do not lose it


def stats_record(cls, kind):
    """Count ONE cache event. Never fails a call and never touches the caller's streams."""
    try:
        p = os.path.join(state_dir(), STATS_FILE)
        try:
            if os.path.getsize(p) > STATS_ROTATE_BYTES:
                stats_fold()
        except OSError:
            pass                        # absent, or unfreezable: appending still works
        line = json.dumps({"at": int(clock()), "cls": cls, "kind": kind},
                          separators=(",", ":")) + "\n"
        fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            os.write(fd, line.encode())
        finally:
            os.close(fd)
    except (OSError, TypeError, ValueError):
        pass


def stats_readable():
    """(ok, reason) — an instrument that cannot be READ is not `no-reads-counted`.

    ⛔ THE CARRY IS PART OF THE COUNTER (#2342 review P2). A corrupt `read-cache-totals.json` was
    silently treated as zero, which made the cumulative `averted` DROP — the one property the fold
    exists to guarantee — and the report then read as lost data or a cache regression."""
    for name in (STATS_FILE, STATS_CARRY_FILE):
        p = os.path.join(state_dir(), name)
        if not os.path.exists(p):
            continue
        try:
            with open(p) as fh:
                fh.read(1)
        except OSError as exc:
            return (False, "%s (%s)" % (p, exc))
    p = os.path.join(state_dir(), STATS_CARRY_FILE)
    if os.path.exists(p):
        try:
            with open(p) as fh:
                json.load(fh)
        except (OSError, ValueError):
            return (False, "%s (unparseable carry — the cumulative totals cannot be trusted)" % p)
    return (True, "")


def stats_report():
    """(earliest stamp, {class: {kind: count}}) — the CUMULATIVE counters of this box.

    ⛔ A TORN LINE IS A LOST COUNT, NEVER A WRONG ONE: it is skipped, so the totals can under-report
    (an instrument that is honest about its floor) but never invent hits."""
    doc = stats_carry()
    out = doc["classes"]
    since = doc.get("since")
    try:
        with open(os.path.join(state_dir(), STATS_FILE)) as fh:
            for line in fh:
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                cls, kind = e.get("cls"), e.get("kind")
                if not isinstance(cls, str) or not isinstance(kind, str):
                    continue
                one = out.setdefault(cls, {})
                one[kind] = one.get(kind, 0) + 1
                at = e.get("at")
                if isinstance(at, int) and (since is None or at < since):
                    since = at
    except OSError:
        pass
    return since, out


def floor_source():
    """WHICH knob set the floor — the one whose VALUE is in force, not the one merely present.

    `GH_LIMIT_CORE_LOW_WATER` still works, so a box that carries the old value KEEPS it; without this
    the fleet's effective floor can be 100 while the runbook and the PR say 800.
    ⛔ PRESENCE IS NOT PARSEABILITY (#2342 review P2). `GH_LIMIT_CORE_FLOOR=abc` is ignored by
    `cfg_int` (which falls back to the legacy value), so reporting it as the source pointed an operator
    at a knob the layer was not reading. A set-but-unparseable value is NAMED as such."""
    new = cfg("GH_LIMIT_CORE_FLOOR", "")
    legacy = cfg("GH_LIMIT_CORE_LOW_WATER", "")
    if new:
        try:
            int(float(new))
            return "GH_LIMIT_CORE_FLOOR"
        except (TypeError, ValueError, OverflowError):
            return ("GH_LIMIT_CORE_FLOOR (unparseable, ignored)"
                    + (" — using GH_LIMIT_CORE_LOW_WATER" if legacy else " — using the default"))
    if legacy:
        return "GH_LIMIT_CORE_LOW_WATER (legacy)"
    return "default"


def read_cache_class(gh_argv):
    """The TTL class for this invocation, or None — the ADMISSION gate, one place.

    ⛔ ONE CACHE PER SHAPE, AND THE ETAG PATH WINS ITS OWN. A `gh api` GET that `conditional_fetch`
    will revalidate already has a stronger mechanism: a `304` costs NO quota and returns a body the
    server just confirmed is current. Wrapping a TTL cache over that would hand out an OLDER body
    where a fresh one was free — a slower AND staler answer — and would break the documented
    “the second poll SENDS if-none-match” guarantee. So the TTL cache applies exactly where the ETag
    path cannot: shapes `conditional_plan` refuses, and every SUBCOMMAND (`gh pr view` / `pr list` /
    `pr checks` are GraphQL, which has no ETag at all)."""
    if not read_cache_enabled() or conditional_plan(gh_argv) is not None:
        return None
    return read_class(gh_argv)


def _run_shared(real_gh, gh_argv):
    """(rc, out, err) for this invocation: TTL cache, then coalesced, then plain.

    The ORDER is the whole saving: a fresh cache entry spends no request and no lock; a miss goes to
    the single flight, so N lanes arriving together still make ONE call; and only a miss with no
    leader above it reaches the transport (where `_dispatch` may fail over core->GraphQL)."""
    cls = read_cache_class(gh_argv)
    if cls is None:
        if flight_eligible(gh_argv):
            return single_flight(real_gh, gh_argv)
        return _run_captured(real_gh, gh_argv)
    name, ttl = cls
    key = flight_key(gh_argv)          # ONE key definition: host + credential + repo pin + request
    hit = read_cache_get(key, ttl)
    if hit is not None:
        stats_record(name, "hit")      # ONE request this box did NOT send — counted where it happens
        log_event("read-cache: %s hit — within its %ds TTL, so no request was made" % (name, ttl))
        return hit
    stats_record(name, "miss")
    if flight_eligible(gh_argv):
        rc, out, err = single_flight(real_gh, gh_argv)
    else:
        rc, out, err = _run_captured(real_gh, gh_argv)
    read_cache_put(key, rc, out, err)
    return rc, out, err


def dispatch(real_gh, gh_argv):
    """The public entry: pass-scoped memoisation (when enabled) ABOVE the real dispatch, and single
    flight (#2243) in it. A memo HIT spends no request, so there is nothing to coalesce; a miss is
    exactly the call another lane may be making at the same moment."""
    if pass_cache_eligible(gh_argv):
        hit = pass_cache_get(gh_argv)
        if hit is not None:
            out, err, rc = hit
            if out:
                sys.stdout.buffer.write(out)
            if err:
                sys.stderr.buffer.write(err)
            log_event("pass-cache: hit for `%s` — served from this pass's memo, no request"
                      % _flight_label(gh_argv))
            return rc
        rc, out, err = _run_shared(real_gh, gh_argv)
        # ⛔ THE CALLER'S BYTES ARE WRITTEN WHATEVER HAPPENS — a layer that swallowed one stream on an
        # unusual exit path would SUBTRACT from the child, which this file forbids in every branch.
        _emit_streams(rc, out, err)
        pass_cache_put(gh_argv, out, err, rc)
        return rc
    if flight_eligible(gh_argv) or read_cache_class(gh_argv) is not None:
        return _emit_streams(*_run_shared(real_gh, gh_argv))
    return _dispatch(real_gh, gh_argv)


def emit(body, jq, silent):
    """Reproduce exactly what `gh api` (without `--include`) would print."""
    if silent:
        return 0
    if jq is not None:
        try:
            # `-c` AND `-r`: gh's own engine emits each result COMPACTLY (one line for an object or
            # array) and raw for strings. `jq -r` alone pretty-prints containers over several lines,
            # so a successful intercepted call returned different bytes from the plain one — the
            # "a successful call is unchanged" rule, broken by the replay itself (review round 1).
            # `-S`: gh's embedded gojq marshals through encoding/json, which SORTS object keys; plain
            # `jq` keeps document order, so a `--jq` projection returned the same data with different
            # bytes — falsifying "byte for byte" for every container-producing filter (review
            # round 8). No in-tree caller is affected (they all project scalars/tables), but the
            # promise is the promise.
            r = subprocess.run(["jq", "-c", "-S", "-r", jq], input=body, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        except OSError as exc:
            # Unreachable while conditional_plan checks for jq, and kept as a defence so a future
            # caller of emit() cannot turn a missing binary into a traceback attributed to the harness.
            sys.stderr.write("gh-limit: cannot run jq (%s) — the projection was not applied\n" % exc)
            return 1
        sys.stdout.buffer.write(r.stdout)
        if r.returncode != 0:
            sys.stderr.buffer.write(b"gh-limit: --jq projection failed: " + r.stderr)
            return 1
        return 0
    sys.stdout.buffer.write(body)       # byte for byte: gh prints no trailing newline for a bare body
    return 0


def conditional_fetch(real_gh, plan):
    """One revalidating GET. Returns (Result, headers) — Result already carries the body the caller
    should print (the cached one on 304), so callers never see `--include` framing."""
    key = cache_key(plan)
    cached = cache_get(key)
    include = ["--include"]
    if plan["host"]:
        include += ["--hostname", plan["host"]]
    extra = list(include)
    if cached:
        extra += ["-H", "If-None-Match: %s" % cached["etag"]]
    res = run(real_gh, ["api"] + extra + [plan["path"]])
    parsed = split_http(res.out)
    if parsed is None:
        # gh always frames `--include`, so a body without a status line means the request never
        # reached GitHub (DNS, TLS, a reset) — NOT that the shape was unexpected. ⛔ DO NOT RE-RUN:
        # a second request per attempt doubled the network traffic during an outage (8 for a
        # 4-attempt budget), discarded the first failure's own text, and logged a diagnosis that was
        # simply wrong. The attempt's result is returned as-is, exactly like a plain call's.
        log_event("conditional: no HTTP response to frame for %s (the request did not reach the API) — returning it as-is"
                  % plan["path"])
        return res, {}
    status, headers, body = parsed
    if status == 304 and cached:
        log_event("conditional: 304 for %s — served from cache, no quota spent" % plan["path"])
        return Result(0, cached["body"], b"", status=304), headers
    if status == 304:
        # The validator found the server unchanged but its cache entry is gone (the bounded cache
        # evicted it between the read and the request, or a concurrent prune did). Replaying
        # nothing would turn an unchanged resource into a FAILED call, so re-run without a
        # validator and serve the real body.
        log_event("conditional: 304 for %s with no cache entry — re-running plain" % plan["path"])
        plain = ["--hostname", plan["host"]] if plan["host"] else []
        return run(real_gh, ["api"] + plain + [plan["path"]]), {}
    if res.rc == 0 and status == 200:
        etag = headers.get("etag")
        if etag:
            cache_put(key, etag, body)
    return Result(res.rc, body, res.err, status=status), headers


# ── rate-limit classification and the documented backoff ──────────────────────────────────────
LIMIT_PHRASES = ("rate limit", "rate-limit", "abuse detection", "secondary rate")
# GitHub's own vocabulary for the SECONDARY (burst/concurrency) limit. `already exceeded for user ID`
# is the measured wording the fleet receives when the primary budget is healthy (#1762/#1910), so it
# is the strongest available signal that the refusal is not about the point budget.
SECONDARY_PHRASES = ("abuse detection", "secondary rate", "already exceeded for user id",
                     "exceeded a secondary")


class Limit(object):
    __slots__ = ("bucket", "status", "retry_after", "remaining", "reset", "message")

    def __init__(self, bucket, status, retry_after, remaining, reset, message):
        self.bucket = bucket
        self.status = status
        self.retry_after = retry_after
        self.remaining = remaining
        self.reset = reset
        self.message = message


# gh subcommands that go straight to REST. Everything else gh does for the shapes this harness
# calls (`pr`, `issue`) is GraphQL. This is a HEURISTIC and it is stated as one: the authoritative
# signal is the response header when the refused call carried one, and the label exists so a failure
# says WHICH pool to look at instead of pointing at whichever counter happens to look healthy.
# Subcommands gh serves over REST **for the shapes this file can see**: `run`/`workflow`/`release`/
# `label`/`cache`/`secret`/`variable` have REST-only reads.
# ⛔ `repo` AND `gist` ARE DELIBERATELY ABSENT (#2342 review, P1). They were added "because their
# WRITES are REST calls", and that reason is unreachable: `is_mutating` answers `core` for every
# mutation BEFORE this set is consulted, and `repo create/delete/edit/fork/…` are all in
# `MUTATING_PAIRS`. So the entries could never affect a write — their only reachable effect was on
# READS, and `gh repo view` / `gh repo list` are `RepositoryInfo` GraphQL queries. Labelling then
# `core` refused them, with ZERO requests, inside a dated-empty core window while GraphQL had
# thousands left: `admin-merge.sh`'s `gh repo view --json nameWithOwner` printed an empty slug and
# the rail reported "the repo identity could not be resolved" — the misdiagnosis this layer exists to
# delete (measured on the 2026-10-22 path). Writes stay covered by `is_mutating`.
REST_SUBCOMMANDS = {"run", "workflow", "release", "label", "cache", "secret", "variable"}
# ⛔ THE DEFAULT FOR AN UNKNOWN VERB IS `core`, NOT `graphql`. Labelling every unlisted verb `graphql`
# meant `codespace delete`, `ruleset delete`, `ssh-key delete` and their kin were described as a healthy
# GraphQL READ: unguarded against an empty core pool, and their refusal filed under a pool that was fine
# (the 2026-10-22 false-healthy line, reachable from any verb nobody had listed). Enumerating the verbs
# that are genuinely GraphQL is a finite list this file CAN know — gh's own GraphQL-first surface.
# ⛔ `repo` AND `gist` ARE LISTED HERE BECAUSE THEIR *READS* ARE GRAPHQL (#2342 review, P1), and the
# fall-through default below is `core` for an unlisted verb — so removing them from REST_SUBCOMMANDS
# alone would still label `gh repo view` as a core read. Their WRITES are unaffected: `is_mutating`
# answers `core` before either set is consulted (`repo create/delete/edit/fork/rename/archive/sync`,
# `gist create/delete/edit` are all in MUTATING_PAIRS), so this only reclassifies the reads that
# `RepositoryInfo` actually serves from GraphQL.
GRAPHQL_SUBCOMMANDS = {"pr", "issue", "search", "project", "browse", "auth", "extension", "alias",
                       "repo", "gist"}


# Subcommands/flag forms that never reach the API. `makes_request()` gates the RECOVERY record: a
# local command succeeding is not evidence that a refused bucket recovered.
NO_REQUEST = {"--version", "version", "help", "--help", "-h", "completion", "alias", "config"}
NO_REQUEST_ANY = {"--help", "-h", "help", "--version"}     # request-free ANYWHERE in argv


def makes_request(argv):
    """False for the `gh` forms that answer without an API call. Deliberately a small allow-list of
    NO-REQUEST forms rather than a list of API calls: an unknown subcommand is assumed to reach the
    API, so the failure mode of a MISS is a limit record that no non-API call can clear for its
    15-minute age bound — the conservative direction (a stale `rate_limited` is visible and harmless;
    an erased one is not). ⛔ `argv[0]` ALONE WAS NOT ENOUGH: `gh -h`, `gh api --help`, `gh pr list
    -h` and `<cmd> help` all answer without a request AND cleared a live record, because a help flag
    can appear after the subcommand (review round 9)."""
    if not argv:
        return False
    if argv[0] in NO_REQUEST:
        return False
    # `gh auth token` is an OFFLINE lookup of the stored credential (hosts.yml / the keyring) and the
    # harness runs it every refresh (`refresh-candidates.sh:250`) on a layer-first PATH — so it marked
    # a live GraphQL limit `recovered` on the steady-state path, and the box reported healthy while
    # every real call was refused (measured: `gh=recovered(bucket=graphql 8s)` right after a 403).
    # `auth status` is NOT here: it validates the token against the API.
    if len(argv) >= 2 and argv[0] == "auth" and argv[1] == "token":
        return False
    # ⛔ AND NOT `gh api rate_limit` EITHER. That endpoint is EXEMPT from the primary limit (the file
    # says so itself, and `refresh-candidates.sh`/`orch-loop.sh`'s `res_line` call it every cycle
    # BEFORE the cycle token is read) — so it succeeds on a box where every `core` call is refused,
    # and counting it as evidence printed `gh=recovered(bucket=core …)` for a box that was still
    # being refused. It reaches the API but it is the one call the limit cannot refuse (review
    # round 10). This is the "exempt by design, therefore not evidence" class.
    if argv[0] == "api":
        # ⛔ NOT "the first token that does not start with `-`": with a value-taking flag first that is
        # the flag's VALUE, so `gh api -H 'Accept: x' rate_limit` counted as recovery evidence and
        # ERASED a live limit (review round 3 — the same mis-attribution as `bucket_for`).
        # ⛔ AND AN UNATTRIBUTABLE ARGV IS "NO EVIDENCE", not "some non-meter endpoint" (review round
        # 5): `api_endpoint` answers None for a flag it cannot consume (`gh api -p preview rate_limit`
        # before `--preview` was added to the vocabulary), and answering True there would re-open the
        # erase from a new spelling. The docstring's promise — callers treat None conservatively — now
        # holds here too.
        ep = api_endpoint(argv)
        if ep is None or ep.strip("/").lower() == "rate_limit":
            return False
    return not any(a in NO_REQUEST_ANY for a in argv)


def reaches_api(argv):
    """Does this invocation SPEND a non-exempt API request?

    ⛔ SEPARATE FROM `makes_request` ON PURPOSE, because the two questions have OPPOSITE safe defaults.
    `makes_request` answers “may this call be EVIDENCE that a bucket recovered”, where an unattributable
    argv must be NO evidence (it could be the exempt meter, and counting it erased a live limit). The
    BUDGET GUARD needs the opposite default: an argv the layer cannot attribute must be TREATED as
    spending the pool, or a flag nobody listed becomes a way to send a write into an empty pool.
    Measured, round 9: `gh api --allow-escape-sequences -X POST …` — an argv `api_endpoint` could not
    attribute — skipped the guard (1 request into a dated-empty pool instead of 0), its headerless
    refusal rewrote the dated record as UNDATED, and after that every known-spelling write was sent too
    (0,0,1,1,1 across five identical writes) while the real reset disappeared from the token."""
    if not argv:
        return False
    if any(a in NO_REQUEST_ANY for a in argv):
        return False
    if argv[0] == "auth" and len(argv) >= 2 and argv[1] == "token":
        return False                     # an OFFLINE keyring lookup, not a request
    if argv[0] == "api":
        ep = api_endpoint(argv)
        if ep is not None and ep.strip("/").lower() == "rate_limit":
            return False                 # exempt by design: the meter itself
        return True                      # attributable or NOT: assume it spends the pool
    return argv[0] not in NO_REQUEST


def makes_no_request_strictly(argv):
    """The BOX-LOCK exemption. ⛔ DELIBERATELY NARROWER THAN `makes_request()` — they answer different
    questions and only one of them is safe here.

    `makes_request()` answers "can this call spend the ACCOUNT's budget?", and it is CORRECTLY
    fail-OPEN about a few shapes that still reach the network: `gh api rate_limit` is exempt from the
    limit yet is a real request, an `gh api` argv it cannot attribute is called "no evidence" rather
    than "no request", and `NO_REQUEST_ANY` matches a help-looking token ANYWHERE in argv (`gh issue
    create -t help` is a mutation with a title). Using that predicate for the LOCK — whose invariant is
    the much stricter "one gh REQUEST in flight per box" — serialised nothing for those shapes:
    measured in review, `api rate_limit` and `api --unknown-flag repos/o/r` went from peak 1 in flight
    to peak 6, i.e. the fix would have traded a starved credential read for an UNSERIALISED fleet
    (the exact failure #1988/#2005 exists to prevent), and a `gh issue create -t help` would have run
    `pace_mutation`/`mark_mutation` outside the lock.

    So this predicate is an exact allow-list of forms whose argv is PROVABLY local, and everything
    else — including every form `makes_request()` merely cannot attribute — keeps the lock. The cost
    of a MISS here is one serialised local read (a queue, i.e. today's behaviour); the cost of a
    false POSITIVE is an unserialised API call."""
    if not argv:
        return True                      # bare `gh` prints help
    if argv[0] in NO_REQUEST:
        return True                      # --version/version/help/--help/-h/completion/alias/config
    # `gh auth token [--hostname H] [-s]` reads hosts.yml or the keyring; nothing else under `auth` is
    # exempt (`auth status` VALIDATES the token against the API — it takes the lock).
    return len(argv) >= 2 and argv[0] == "auth" and argv[1] == "token"


def bucket_for(argv):
    if not argv:
        return "graphql"
    if argv[0] == "api":
        # `gh api graphql …` reaches the GRAPHQL pool through the REST-shaped command. ⛔ Match the
        # SUBCOMMAND, not any occurrence: `gh api repos/o/graphql-tools/pulls` is a REST call, and
        # naming the healthy graphql pool there points an operator at the wrong bucket. ⛔ AND NOT
        # "the first token that does not start with `-`" — with a value-taking flag before the
        # endpoint that is a FLAG'S VALUE, which pinned a `-H`-prefixed GraphQL refusal on `core`
        # (review round 3); an unattributable argv answers `core`, the conservative label.
        sub = api_endpoint(argv) or ""
        return "graphql" if sub.strip("/").lower() == "graphql" else "core"
    # ⛔ ANY MUTATION IS A `core` CALL UNLESS IT GOES THROUGH `api graphql` (handled above). A write has
    # no second pool, and `gh-rest/gh` translates the GraphQL-shaped ones (`pr merge`, `pr comment`,
    # `issue comment`, `issue close`) into REST writes.
    if is_mutating(argv):
        return "core"
    if argv[0] in REST_SUBCOMMANDS:
        return "core"
    # an UNKNOWN verb is not evidence that it spends GraphQL — see GRAPHQL_SUBCOMMANDS
    return "graphql" if argv[0] in GRAPHQL_SUBCOMMANDS else "core"


def probe_rate_limit(real_gh, bucket):
    """(remaining, reset) for ONE bucket, or (None, None). Only consulted when a call has already
    been refused, and never to DECIDE that it is fine: `GET /rate_limit` is exempt from the primary
    limit and it is the only way to name a reset a refused call did not carry a header for. Its
    `remaining` is deliberately not trusted as a health signal — measured: it read 4999/5000 while
    every GraphQL call was refused (#1988, #1762).

    ⛔ TAKES THE SINGLE-FLIGHT LOCK. It is called from `plan_wait`, which runs OUTSIDE the
    attempt lock (a caller must not hold the box while it sleeps 60s), so without this it would be
    the ONE gh request the layer issues unserialised — during backoff, exactly when the other boxes
    and the other lanes are most likely to be issuing their own. One invariant, no exemptions."""
    lock = acquire_lock(strict=True)
    if lock is None:
        return None, None          # no serialised slot, no probe (never unserialised)
    try:
        r = run(real_gh, ["api", "rate_limit"], timeout=PROBE_TIMEOUT_S)
    finally:
        release_lock(lock)
    try:
        if r.rc != 0:
            return None, None
        d = json.loads(r.out.decode("utf-8", "replace"))
        # ⛔ WHILE WE ARE HERE, RECORD BOTH POOLS. This request has already been made (the refused
        # call carried no usable header), and one `/rate_limit` read is exactly what the other 24
        # lanes need to choose a transport without a request of their own. Before the 2026-10-22
        # fix the answer was thrown away after extracting one bucket.
        write_budget(d)
        res = (d.get("resources") or {}).get(bucket) or {}
        remaining = res.get("remaining")
        reset = res.get("reset")
        return (int(remaining) if isinstance(remaining, int) else None,
                int(reset) if isinstance(reset, int) else None)
    except (ValueError, OSError):
        return None, None


def as_int(v):
    try:
        return int(str(v).strip())
    except (TypeError, ValueError):
        return None


def classify(res, argv, headers):
    """A rate-limit refusal, or None when this is some other failure.

    ⛔ A BARE 403 IS NOT A RATE LIMIT. A 403 is how a permission/scope failure arrives (an expired
    or under-scoped token, SSO, "Resource not accessible by integration") and it carries no
    rate-limit header because there is no rate limit. Classifying it as one DEFERS a box that is
    actually misconfigured, and reports the opposite of what stderr says — the #1762 lesson, kept.
    """
    if res.rc == 0:
        return None
    text = (res.err or b"").decode("utf-8", "replace")
    # The status the RESPONSE carried beats a regex over stderr: gh's error prose is not an API.
    status = res.status
    if status is None:
        m = re.search(r"HTTP[/ ]?\d*\.?\d*\s*(\d{3})|\bHTTP\s+(\d{3})\b", text)
        if m:
            status = int(m.group(1) or m.group(2))
    remaining = as_int(headers.get("x-ratelimit-remaining")) if headers else None
    retry_after = as_int(headers.get("retry-after")) if headers else None
    reset = as_int(headers.get("x-ratelimit-reset")) if headers else None
    low = text.lower()
    phrase = any(p in low for p in LIMIT_PHRASES)
    corroborated = (remaining == 0) or (retry_after is not None) or phrase
    # ⛔ A PHRASE IN THE WRONG RESPONSE IS NOT A LIMIT. `gh` echoes request content in some
    # failures (a PR titled "fix rate limit" rejected with `HTTP 422 Validation Failed`), and
    # treating that as a limit would spend the full 4-attempt backoff (60+120+240 s) before
    # failing anyway — a 7-minute hang on a call that will never succeed. A phrase therefore
    # counts only where a limit can actually arrive: 429, an unparsed status (GraphQL reports the
    # refusal in prose alone), or a 403 that already corroborates.
    if status == 429 or (status == 403 and corroborated) or (phrase and status in (None, 403, 429)):
        return Limit(bucket_for(argv), status, retry_after, remaining, reset, text.strip().splitlines()[0]
                     if text.strip() else "")
    return None


def limit_kind(limit):
    """What KIND of refusal this is. Drives both the wait and the evidence recorded for it.

    ⛔ `unclassified` IS A REAL CLASS, NOT A FALLBACK. A refusal whose HTTP status could not be parsed
    (GraphQL reports it in prose alone) and whose text names no secondary vocabulary used to fall
    through to "no usable header" — where the only number available was a bucket reset, which for a
    secondary refusal is not a recovery time. `unclassified` is therefore treated like a secondary
    limit (>= 1 minute, jittered, doubling) and NEVER adopts a reset as its wait."""
    if limit.retry_after is not None:
        return "retry-after"
    low = (limit.message or "").lower()
    if any(p in low for p in SECONDARY_PHRASES):
        return "secondary"
    if limit.status is None:
        return "unclassified"
    if limit.remaining == 0:
        return "primary"
    return "unclassified"


def plan_wait(limit, attempt, real_gh, now, kind=None):
    """The documented order, and nothing invented: retry-after, then the bucket's reset when the
    bucket is empty, then >= BASE_WAIT doubling. Returns (seconds, reset_epoch, why, remaining).

    ⛔ THE RESET IS HONOURED FOR A PRIMARY REFUSAL ONLY (agent-infra#2137, requirement 2). GitHub
    documents that the primary counter does NOT predict a secondary limit — measured, graphql
    ~4573/5000 while every call was refused — so a reset read beside a secondary/unclassified refusal
    is not a recovery time. Adopting it produced the full-window block this change removes."""
    if kind is None:
        kind = limit_kind(limit)
    if limit.retry_after is not None and limit.retry_after >= 0:
        # ⛔ A `retry-after: 0` IS NOT PERMISSION TO RETRY AT ONCE. Taken verbatim it produced four
        # back-to-back requests with zero seconds waited — the burst secondary limits react to, and
        # the opposite of the floor the docs state. One second is the smallest honest gap; the
        # attempt cap still bounds the total.
        if limit.retry_after < 1:
            log_event("retry-after=%ds is below the 1s floor — waiting 1s" % limit.retry_after)
            return 1.0, limit.reset, "retry-after-floor", limit.remaining
        return float(limit.retry_after), limit.reset, "retry-after", limit.remaining
    remaining, reset = limit.remaining, limit.reset
    if remaining is None or reset is None:
        # No usable header: ask the exempt endpoint for THIS bucket's reset (the refused call did
        # not carry one). A bucket that reports headroom anyway is exactly the lying-GraphQL case,
        # so its number never suppresses the backoff — it can only extend it.
        p_remaining, p_reset = probe_rate_limit(real_gh, limit.bucket)
        remaining = p_remaining if remaining is None else remaining
        reset = p_reset if reset is None else reset
    # ⛔ A MEASURED ZERO IS THE EVIDENCE, NOT THE CLASSIFICATION WORD (the merge of #2137 with the
    # failover layer). #2137's rule — never adopt a bucket reset for a SECONDARY refusal — was written
    # for the measured shape it found: a burst refusal whose `remaining` was 3200 beside a reset ~43
    # minutes away, where adopting the reset blocked the whole box on a pool with thousands left. That
    # rule is `remaining == 0` BELOW, and it is the load-bearing half: a refusal that (or whose exempt
    # probe) reports a zero count and a dated reset has MEASURED that the pool is empty until that
    # time, whatever word the prose fell back to. Keying on `kind == "primary"` instead made an
    # `unclassified` refusal (gh's prose-only shape, no HTTP status — exactly the 2026-10-22 incident)
    # pay the full 60/120/240 s backoff curve in-call: measured on the merged tree, the failed read
    # that this layer exists to fail FAST sat ~7 minutes before giving up, past every caller's bound,
    # and its 12-minute reset was never named. So:
    #   * `secondary` keeps the curve — GitHub enforces it on burst/concurrency, and its reset is not a
    #     recovery time (a probed `remaining` of 0 there is the lying-counter case #2137 measured);
    #   * any other kind adopts a dated reset ONLY on a measured `remaining == 0`.
    # `retry-after` never reaches here (the server's own delay is honoured above, verbatim).
    if remaining == 0 and reset and reset > now and kind != "secondary":
        return float(reset - now) + 1.0, reset, "reset", remaining
    # Exponential, JITTERED UPWARDS only, so the floor the docs state (>= 1 minute) is never
    # breached by jitter: 60, 120, 240 … A secondary refusal lands here, with the reset recorded as
    # EVIDENCE (the bucket's own number) but never as this call's wait.
    base = BASE_WAIT * (2 ** (attempt - 1))
    return base * (1.0 + random.random() * 0.2), reset, "backoff", remaining


def fail_loudly(limit, attempts, waited, reset, kind=None, remaining=None, marker_age_s=None):
    # ⛔ THE WORDS MATTER: the harness's own classifiers look for "rate limit" (objective.py's
    # TRANSPORT_MARKERS) to turn a refused read into `VERDICT=GH-RATE-LIMITED` instead of
    # `UNKNOWN`/`STALL`. "rate_limited" does not contain it, so the token would be lost at exactly the
    # boundary this layer exists to make honest.
    #
    # ⛔ AND ONLY EMPTINESS MAY BE CALLED EMPTINESS. A SECONDARY (concurrency/burst) refusal arrives in
    # the same shape as a primary one and `classify` admits both — but it carries
    # `x-ratelimit-remaining: 3200`, and naming it `gh-core-exhausted` froze every write on the box for up
    # to an hour while the pool had thousands of requests left, with a message saying the pool was EMPTY.
    # A number we can SEE above zero refutes exhaustion, so it gets its own name and writes no health
    # record at all.
    named = ""
    if limit.bucket == "core":
        rem = getattr(limit, "remaining", None)
        if rem == 0:
            named = "%s — " % record_core_exhausted(reset, rem)
        elif rem is None:
            # ⛔ ABSENT IS UNKNOWN, NOT ZERO. A secondary refusal is governed by `retry-after` and is
            # NOT counted by the primary counters, so it may arrive carrying a reset and no remaining
            # at all. Persisting that reset made a DATED “the pool is empty” claim out of a burst —
            # writes then refused with no request, for up to an hour, on a pool with thousands left.
            # An undated record still DIVERTS reads to GraphQL and still names the state; it just
            # cannot refuse anything (the round-3 rule).
            named = "%s — " % record_core_exhausted(None, None)
        else:
            named = "gh-secondary-rate-limited remaining=%d — " % rem
    # ⛔ AND THE LINE CARRIES ITS OWN EVIDENCE (agent-infra#2137, requirement 4): the classification
    # used, the marker's AGE, the remaining count read, and the attempt number. Without the age a
    # refusal built on a 40-minute-old record is indistinguishable from one that just happened, so an
    # operator cannot tell whether to wait or to fix something else.
    sys.stderr.write(
        "gh-limit: %sgh rate limit (bucket=%s reset=%s kind=%s) — FAILED after %d attempt(s), %ds waited. "
        "evidence: remaining=%s marker_age=%s. This is a REFUSED call, not an empty answer%s\n"
        % (named, limit.bucket, reset if reset else "?", kind or limit_kind(limit), attempts, int(waited),
           ("%d" % remaining) if remaining is not None else "?",
           ("%ds" % marker_age_s) if marker_age_s is not None else "none",
           (" (%s)" % limit.message) if limit.message else ""))


def main(argv):
    real_gh = None
    self_path = None
    health = False
    budget = False
    stats = False
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--":
            i += 1
            break
        if a == "--real-gh" and i + 1 < len(argv):
            real_gh = argv[i + 1]
            i += 2
        elif a == "--self" and i + 1 < len(argv):
            self_path = argv[i + 1]
            i += 2
        elif a in ("--health", "--gh-health"):
            # ⛔ A NAMED HEALTH VERB, SO A LANE NEVER HAS TO INTERPRET A FAILURE. It reads local
            # state only: no request, no credentials, no quota — which is what makes it usable at
            # exactly the moment every `gh` call is being refused.
            health = True
            i += 1
        elif a in ("--budget", "--gh-budget"):
            # ⛔ THE ONE PLACE A CALLER SPENDS ONE EXEMPT REQUEST TO LEARN BOTH POOLS, and the reason
            # the hot path can stay free. A dispatcher about to run a burst calls this ONCE; every
            # call it then makes reads the shared snapshot instead.
            budget = True
            i += 1
        elif a in ("--stats", "--gh-stats"):
            # ⛔ THE CACHE'S OWN HIT RATE, WHICH IS THE ONLY WAY TO PROVE THE SAVING (#2342). Local
            # counters only: no request, no quota, no credentials. See `stats_report`.
            stats = True
            i += 1
        else:
            sys.stderr.write("gh-limit: unknown argument %r (expected --real-gh|--self <path>|--health|--budget|--stats -- <argv>)\n" % a)
            return 2
    if health:
        token, rc = health_token()
        sys.stdout.write(token + "\n")
        return rc
    if stats:
        ok, why = stats_readable()
        if not ok:
            # ⛔ AN UNREADABLE INSTRUMENT IS NOT “NOTHING COUNTED” (review P2). `--health` already
            # refuses to call an unparseable record `gh-ok`; the same rule applies to the counters.
            sys.stdout.write("gh-read-cache UNREADABLE %s\n" % why)
            # ⛔ AND IT EXITS 3, NOT 0 (review round 2, P2). Returning 0 made an UNREADABLE
            # instrument report success to any caller gating on the exit status — the exact
            # false-PASS polarity this block's own comment names: `--health` refuses to call an
            # unparseable record `gh-ok` and returns 3 there. The genuinely-empty arm below keeps
            # 0, because "nothing has been counted yet" IS an answer; "I could not read the
            # counters" is not.
            return 3
        since, doc = stats_report()
        if not doc:
            # ⛔ AN EMPTY COUNTER IS NOT “ZERO SAVING”. It is “nothing has been counted yet”, and
            # printing `averted=0` would be a measurement nobody made — the same class of lie this
            # layer exists to stop a caller from telling itself.
            sys.stdout.write("gh-read-cache no-reads-counted\n")
            return 0
        ttl = {name: t for name, _pair, t in READ_SUBCOMMAND_CLASSES}
        averted = 0
        stamp = time.strftime("%Y-%m-%dT%H:%MZ", time.gmtime(since)) if since else "?"
        sys.stdout.write("gh-read-cache since=%s floor=%d (%s)\n"
                         % (stamp, CORE_FLOOR, floor_source()))
        for cls in sorted(doc):
            kinds = doc[cls]
            hit, miss, share = (kinds.get("hit", 0), kinds.get("miss", 0), kinds.get("share", 0))
            if cls == "single-flight":
                sys.stdout.write("  %-14s share=%-6d \u2192 coalesced (N lanes, one request)\n"
                                 % (cls, share))
                averted += share
                continue
            sys.stdout.write("  %-14s hit=%-6d miss=%-6d ttl=%ds\n" % (cls, hit, miss, ttl.get(cls, 0)))
            averted += hit
        sys.stdout.write("  %-14s averted=%-6d \u2192 gh requests this box did not send (hits + shares)\n"
                         % ("TOTAL", averted))
        return 0
    gh_argv = list(argv[i:])
    if real_gh is None:
        real_gh = os.environ.get("GH_LIMIT_REAL_GH") or resolve_real_gh(self_path)
    if budget:
        snap = probe_budget(real_gh) if real_gh and os.path.isfile(real_gh) else None
        if snap is None:
            sys.stdout.write("gh-budget-unknown\n")
            return 3                   # never a guessed number: “I could not read the meter”
        sys.stdout.write("core=%s/%s resets_in=%s graphql=%s/%s resets_in=%s\n"
                         % (snap["core"]["remaining"], snap["core"].get("limit", 5000),
                            resets_in(snap["core"]["reset"]),
                            (snap.get("graphql") or {}).get("remaining", "?"),
                            (snap.get("graphql") or {}).get("limit", 5000),
                            resets_in((snap.get("graphql") or {}).get("reset"))))
        return 0
    if not real_gh or not os.path.isfile(real_gh) or not os.access(real_gh, os.X_OK):
        sys.stderr.write("gh-limit: cannot locate the real gh (set GH_LIMIT_REAL_GH)\n")
        return 127

    return dispatch(real_gh, gh_argv)


def is_harness_shim(path):
    """True when `path` is one of OUR `gh` entry points.

    ⛔ THE LOOKUP IS BY THE FILE'S OWN SENTINEL LINE, not by the sibling helper's presence. The
    sibling is the file whose ABSENCE defines the fail-open state ("a box whose helper did not get
    installed must still be able to merge"), so keying identity on it made the two shims stop
    recognising each other exactly in that state and resume resolving into one another — every gh
    call then hit the depth guard and exited 127 (reproduced). ⛔ AND THE SENTINEL IS THE ONLY RULE:
    a sibling `../gh-limit.py` was accepted too, which SILENTLY SKIPPED any other `gh` sitting in such
    a directory — measured with the tree's own admin-merge guard (`scripts/gh-shim/gh`) placed beside
    the helper: `gh pr merge --admin` then reached the real gh UNGUARDED, i.e. the layer defeated
    #984's gate. A bypass of a gate is worse than the 127 it was guarding against, and the sentinel
    has been in both entry points since round 1 (review round 10)."""
    try:
        with open(path, "rb") as fh:
            return b"harness-gh-shim-marker" in fh.read(8192)
    except OSError:
        return False


def resolve_real_gh(self_path):
    """Walk PATH, skipping THIS shim and every OTHER harness shim (by device+inode and by the
    `../gh-limit.py` marker), so a shim named `gh` can neither exec itself nor a sibling."""
    self_real = None
    if self_path:
        try:
            self_real = os.path.realpath(self_path)
        except OSError:
            self_real = None
    for d in (os.environ.get("PATH") or "/usr/bin:/bin").split(":"):
        if not d:
            continue
        cand = os.path.join(d, "gh")
        if not (os.path.isfile(cand) and os.access(cand, os.X_OK)):
            continue
        if self_real:
            try:
                if os.path.samefile(cand, self_real):
                    continue
            except OSError:
                pass
        if is_harness_shim(cand):
            continue
        return cand
    return None


# ── BOTH BUDGETS, THE CORE->GRAPHQL FAILOVER, AND THE NAMED HEALTH STATE ────────────────────────
# MEASURED 2026-10-22 14:03Z, the incident this section exists for:
#
#     core:   5000 used / 0 remaining, resets in 12 min
#     graphql: 255 used / 4745 remaining
#
# Both counters are the SAME account, so both are ours. The REST pool was empty and the GraphQL pool
# had 95% of a budget, and NOTHING in the fleet could use it: every read that hits `core` failed, the
# rail's protection read failed, `repo-authority.sh` fell back to `REQ_SOURCE=fallback`, every PR was
# refused with “the merge contract is UNKNOWN”, and `gh auth status` reported “the token is invalid”.
# A budget our own polling spent was indistinguishable, from inside a lane, from GitHub being down.
#
# Three mechanisms, each stated where it applies:
#
#   1. READ BOTH BUDGETS, CHEAPLY AND SHARED. `GET /rate_limit` is exempt from the primary limit (it
#      answered normally with `core` at 0), so it is the ONE meter that works when the pool is empty.
#      Its snapshot is kept for `GH_LIMIT_BUDGET_TTL` in the box's state dir, so 25 lanes cost ONE
#      probe per TTL window, not 25.
#   2. FAIL OVER — BUT ONLY WHERE THE ANSWER IS EXACT. A REST read with a GraphQL equivalent of the
#      SAME SHAPE is served from the GraphQL pool. `conditional_plan` is the admission gate (a plain
#      GET, one positional, no `--paginate`/`-i`/`-H`), and the equivalent must reproduce the REST BODY
#      field for field before the caller's own `--jq` is applied — the same “never drop a flag and
#      answer anyway” rule the REST adapter states. A path with NO exact equivalent (branch
#      protection is the one that actually bit) is NOT approximated: it fails closed with the name.
#   3. NAME THE STATE, AND NEVER RETRY INTO THE LIMIT. When `core` is empty, a read with no equivalent
#      is refused ONCE with `gh-core-exhausted resets_in=<Nm>` — no request, no retry (a retry loop is
#      what turned a rate limit into a 4,482-fork storm once already). A mutation is never failed
#      over (there is no GraphQL equivalent of an evidence comment that is the same comment) and it is
#      refused the same way, so the rail says the truth instead of “UNKNOWN”.
BUDGET_TTL = cfg_secs("GH_LIMIT_BUDGET_TTL", 30, 5, 600)
# Fail over while there is still a RESERVE left, because the tail of the pool is the only budget a
# MUTATION can use: writes have no second pool, so spending the last reads on polls would take merges
# down before it took polling down.
#
# ⛔ THE FLOOR IS A GUARD THAT ACTS BEFORE THE WALL (#2342, measured 2026-10-23 04:11Z). The reserve
# was 100, which is a number small enough to never be noticed — and it was never reached before the
# pool was GONE: one identity, one bucket, the Mac plus three cells and ~20 lanes, `core remaining=0`
# at the same moment for all of them, so every lane lost the ability to read or write GitHub and the
# instruments then reported the absence as a state. The pool is spent by POLLING inside the last
# minutes of the window, and the last ~800 requests are the only budget a MUTATION has. So below the
# floor a READ stops spending `core` at all:
#   * it fails over to GraphQL where an EXACT equivalent exists (`graphql_plan`), and
#   * where none exists it is REFUSED BY NAME — `gh-core-floor remaining=N floor=F resets_in=<Nm>` —
#     unless the caller declares that this work cannot proceed without it (`GH_LIMIT_ESSENTIAL=1`).
# The refusal asserts NOTHING about exhaustion: the pool still has `remaining`, and claiming otherwise
# is the false diagnosis this file exists to delete (see `core_pressure`). The escape hatch is not a
# convenience: a landing's protection read has no GraphQL equivalent, so the rail's own reader sets it
# (`repo-authority.sh::required_checks`) — “essential” is exactly “this landing cannot proceed”.
#
# ⛔ ONE CONCEPT, ONE NUMBER. `GH_LIMIT_CORE_LOW_WATER` still works (it is what the runbook and the
# deployed cells carry); `GH_LIMIT_CORE_FLOOR` is the name that says what it does, and it wins.
CORE_FLOOR = cfg_int("GH_LIMIT_CORE_FLOOR",
                     cfg_int("GH_LIMIT_CORE_LOW_WATER", 800, 0, 4950), 0, 4950)
CORE_LOW_WATER = CORE_FLOOR
ESSENTIAL_ENV = "GH_LIMIT_ESSENTIAL"       # "1" = this read cannot be deferred (a landing)
FAILOVER_ENV = "GH_LIMIT_FAILOVER"          # "0" disables the failover (the named state still applies)
HEALTH_FILE = "health"


def essential():
    """Has the CALLER declared this read cannot be deferred?

    ⛔ IT IS OPT-IN AND IT IS NAMED, because the floor is a policy about SPEND and a policy that every
    caller can silently set is not one. `essential` is true only for the work a landing cannot
    complete without: the rail's own protection read. A poll is never essential — if polling were,
    the reserve would be spent exactly the way the 2026-10-23 incident spent it."""
    return cfg(ESSENTIAL_ENV, "0") == "1"


def failover_enabled():
    return cfg(FAILOVER_ENV, "1") != "0"


def resets_in(reset):
    """`<Nm>` — the phrase the named state carries. Ceiling, never a fraction: “resets in 0m” for a
    window 40 s away would read as “about to clear” and invite the retry this exists to prevent."""
    try:
        d = int(reset) - int(clock())
    except (TypeError, ValueError):
        return "?"
    if d <= 0:
        return "0m"
    return "%dm" % max(1, (d + 59) // 60)


def read_budget():
    """The last recorded snapshot of BOTH pools, or None — NO REQUEST IS MADE.

    ⛔ THIS IS THE HOT PATH AND IT MUST BE FREE. The first draft of this layer probed `/rate_limit` from
    every `core` call, which is “only” one exempt request per box per TTL window — but it is a request
    PER CALL SITE on a box running a fleet, and it made this layer's cost depend on how often callers
    call rather than on what they need. Measured against the existing suite it also shifted every
    request-count assertion by one. The meter is therefore read in exactly two places, both of which
    already had a reason to ask: the `--budget` verb, and the refusal path's own `probe_rate_limit`
    (which runs at most once per refused call and now records BOTH pools while it is there)."""
    try:
        with open(os.path.join(state_dir(), "budget.json")) as fh:
            d = json.load(fh)
        at = float(d.get("at") or 0)
        if clock() - at > BUDGET_TTL:
            return None                # too old to decide a TRANSPORT on
        if at > clock() + 60:
            return None                # a stamp from the FUTURE is not fresh (a clock stepped back)
        return d if isinstance(d.get("core"), dict) else None
    except (OSError, ValueError, TypeError):
        return None


def write_budget(doc):
    """Record both pools from a `/rate_limit` document. Shared: ONE probe answers every process."""
    try:
        res = doc.get("resources") or {}
        snap = {"at": clock()}
        for b in ("core", "graphql"):
            one = res.get(b) or {}
            rem, reset, limit = one.get("remaining"), one.get("reset"), one.get("limit")
            if isinstance(rem, int) and isinstance(reset, int):
                snap[b] = {"remaining": rem, "reset": reset,
                           "limit": limit if isinstance(limit, int) else 5000}
        if "core" not in snap:
            return None
        write_state("budget.json", json.dumps(snap))
        return snap
    except (TypeError, ValueError, OSError):
        return None


def probe_budget(real_gh):
    """ONE exempt `/rate_limit` read, under the single-flight lock (the `--budget` verb's work)."""
    lock = acquire_lock(strict=True)
    if lock is None:
        return None                    # no serialised slot, no probe (never unserialised)
    try:
        r = run(real_gh, ["api", "rate_limit"], timeout=PROBE_TIMEOUT_S)
    finally:
        release_lock(lock)
    if r.rc != 0:
        return None
    try:
        return write_budget(json.loads(r.out.decode("utf-8", "replace")))
    except ValueError:
        return None


PROBE_STAMP = "budget-probe-at"
# The probe holds the box-wide lock, so it carries its OWN bound. It reads one small exempt
# document: 20 s is generous, and a timeout costs only "no snapshot this window".
PROBE_TIMEOUT_S = cfg_secs("GH_LIMIT_PROBE_TIMEOUT", 20.0, 1.0, 120.0)


def _probe_due():
    """Is a `/rate_limit` probe allowed in this window?

    ⛔ A FAILED PROBE MUST NOT BECOME A PROBE PER CALL. `write_budget` only lands on SUCCESS, so
    without this stamp a box whose probe fails (a torn state dir, a proxy error) would probe on every
    single gh call — the “cost depends on how often callers call” defect `read_budget` documents."""
    try:
        with open(os.path.join(state_dir(), PROBE_STAMP)) as fh:
            at = float((fh.read() or "0").strip() or 0)
    except (OSError, ValueError):
        return True
    if at > clock() + 60:
        return True                    # a stamp from the FUTURE is not a stamp (a clock stepped back)
    return (clock() - at) >= BUDGET_TTL


def _stamp_probe():
    try:
        with open(os.path.join(state_dir(), PROBE_STAMP), "w") as fh:
            fh.write("%d" % int(clock()))
    except OSError:
        pass


def budget_snapshot_or_probe(real_gh):
    """A FRESH meter snapshot: the free file read, or at most ONE exempt probe per box per TTL.

    ⛔ THE LOCK IS WHAT MAKES “ONE PROBE PER BOX” TRUE. The snapshot is re-read INSIDE the lock, so a
    burst of lanes arriving together costs one request and the rest read the answer — the same shape
    as every other coalescing in this file. The probe is exempt from the primary limit (it answered
    with `core` at 0 on 2026-10-22), so it spends no quota; the stamp bounds it when the probe FAILS.
    """
    snap = read_budget()
    if snap is not None:
        return snap
    if not (real_gh and os.path.isfile(real_gh)):
        return None
    lock = acquire_lock(strict=True)
    if lock is None:
        # ⛔ NO LOCK, NO PROBE (#2342 review P1). A bounded caller (`GH_LIMIT_NO_WAIT`) that could not
        # take the box lock has already spent its budget waiting; issuing the meter call anyway would
        # put ONE gh request in flight UNSERIALISED — the single invariant this layer exists to keep —
        # and would outlive the bound the caller asked for. No snapshot is a legitimate answer. (Strict
        # mode is what makes this true under CONTENTION: the permissive path returns a real fd after
        # logging "proceeding UNSERIALISED", so `is None` alone never fires for a held lock.)
        return None
    try:
        snap = read_budget()           # a peer may have probed while we waited for the lock
        if snap is not None:
            return snap
        if not _probe_due():
            return None                # a probe was already ATTEMPTED this window and did not land
        _stamp_probe()
        # ⛔ BOUNDED, LIKE THE OTHER LOCK-HOLDING PROBE (#2342 review P2). This one runs on the PRIMARY
        # read path (`_dispatch`), so an unbounded `/rate_limit` here is the worse of the two: it would
        # hold the box-wide lock for `GH_LIMIT_LOCK_TIMEOUT` and then de-serialise the box.
        r = run(real_gh, ["api", "rate_limit"], timeout=PROBE_TIMEOUT_S)
    finally:
        release_lock(lock)
    if r.rc != 0:
        return None
    try:
        return write_budget(json.loads(r.out.decode("utf-8", "replace")))
    except ValueError:
        return None


def core_record_reset():
    """The reset on a LIVE `core` refusal record (bucket=core, no `recovered=`), or None.

    ⛔ A RECOVERED RECORD IS NOT EVIDENCE, and the two facts cannot be confused: `record_recovery`
    annotates the same line, so reading `reset=` alone would keep failing over on a pool that had
    already answered a call. This is the durable half of the meter — it is written by the FIRST
    refused `core` call on any lane and read here by every lane, at no cost."""
    try:
        with open(os.path.join(state_dir(), "last-limit")) as fh:
            parts = dict(kv.split("=", 1) for kv in fh.read().split() if "=" in kv)
    except (OSError, ValueError):
        return None
    if parts.get("bucket") != "core" or "recovered" in parts:
        return None
    # ⛔ A RECORD THAT SHOWS HEADROOM REFUTES ITS OWN EXHAUSTION, AND ONE THAT SHOWS NOTHING PROVES
    # NOTHING. `remaining` is written only when the refused response carried it. `> 0` is a burst
    # refusal (never exhaustion); ABSENT means the response did not say — and an older writer recorded
    # primary and secondary refusals identically with no count at all, so trusting an uncounted record
    # would gate every write on the box for the length of the primary window. Only an OBSERVED zero is
    # evidence of emptiness; the undated health record carries the rest.
    rem = as_int(parts.get("remaining"))
    if rem != 0:
        return None
    reset = as_int(parts.get("reset"))
    return reset if reset and reset > clock() else None


HEALTH_UNKNOWN_WINDOW = cfg_secs("GH_LIMIT_HEALTH_UNKNOWN_WINDOW", 900, 60, 86400)


def _health_record():
    try:
        with open(os.path.join(state_dir(), HEALTH_FILE)) as fh:
            return dict(kv.split("=", 1) for kv in fh.read().split() if "=" in kv)
    except (OSError, ValueError):
        return None


def health_state():
    """(reset, dated) for the current `core` health record, or (None, False).

    ⛔ `dated` IS THE POINT, AND IT DECIDES WHAT THE EVIDENCE MAY BE USED FOR. A record whose reset we
    know is a measurement: it may REFUSE a read outright. A record written from a refusal that carried
    no reset (the `--include`-less shape, and every `GH_LIMIT_NO_WAIT` caller, which skips the probe)
    is undated: it is honoured for a BOUNDED window, and it may only DIVERT a read to GraphQL. It may
    not pre-emptively refuse one, because it cannot say when the window ends — and a pre-emptive
    refusal that no core call can ever clear (no call is attempted, so `record_core_ok` never fires)
    would park the box for the full window. Attempting the read is self-correcting: it re-records the
    truth in one request.

    ⛔ AND `reset=0` IS NOT “HEALTHY”. Deriving health from it made `--health` say `gh-ok` while the
    pool was spent and nothing failed over (review round 2, finding 4)."""
    parts = _health_record()
    if not parts or parts.get("bucket") != "core":
        return None, False
    reset = as_int(parts.get("reset"))
    if reset and reset > clock():
        return reset, True
    if reset:
        # ⛔ A DATED RECORD WHOSE WINDOW HAS PASSED IS SPENT — it is NOT re-served as an undated one.
        # Falling through to the `at` branch below kept `--health` printing `gh-core-exhausted` for up
        # to HEALTH_UNKNOWN_WINDOW AFTER the pool had actually reset, which is the token lying in the
        # other direction.
        return None, False
    at = as_int(parts.get("at"))
    if at and clock() - at <= HEALTH_UNKNOWN_WINDOW:
        return int(at + HEALTH_UNKNOWN_WINDOW), False
    return None, False


def health_reset():
    """Just the window (for `--health`): the reset of a current `core` health record, or None."""
    return health_state()[0]


def _record_is_unreadable():
    """True when the health file EXISTS with content but yields no state at all.

    ⛔ THE DIFFERENCE BETWEEN “NO RECORD” AND “A RECORD I COULD NOT READ” IS THE DIFFERENCE BETWEEN A
    HEALTHY POOL AND A BROKEN INSTRUMENT, and `--health` used to print `gh-ok` for both. An absent record
    is genuinely `gh-ok`; a SPENT dated window is `gh-ok` too (it is an answer). An unparseable one is
    neither — it is the one verb an operator trusts at the moment nothing else works, answering from a
    file it could not parse."""
    try:
        with open(os.path.join(state_dir(), HEALTH_FILE)) as fh:
            text = fh.read().strip()
    except OSError:
        return False               # no record is not an unreadable record
    if not text:
        return False               # an empty file is an absent record
    parts = dict(kv.split("=", 1) for kv in text.split() if "=" in kv)
    if parts.get("bucket") != "core":
        return True                # a record about something else, or a truncated one
    reset = as_int(parts.get("reset"))
    at = as_int(parts.get("at"))
    if reset is not None and reset > 0:
        return False               # dated (current or spent) — health_state() has the verdict
    return not (at and at > 0)     # undated and not even datable


def core_pressure():
    """(reset, remaining, dated) when the CORE pool is known to be low/empty, else None.

    ⛔ NO REQUEST IS MADE HERE — the whole call path depends on that. Three FREE sources of truth: a
    snapshot someone else already paid for (the `--budget` verb, or the refusal path's own probe); the
    durable `last-limit` record that the FIRST refused `core` call on ANY lane writes; and the named
    health record, which survives a GraphQL refusal overwriting that single record.

    `dated` says whether the WINDOW is known, and that governs what the evidence may be used for (see
    `health_state`)."""
    # ⛔ THE FLOOR IS NOT THE FAILOVER (#2342 review P2). This used to return None whenever
    # `GH_LIMIT_FAILOVER=0`, which silently removed the floor AND the dated-empty write guard — the two
    # things the kill switch's own contract says still apply (“0 disables the failover (the named state
    # still applies)”). An operator turning failover off during GraphQL trouble would have sent a
    # measured-empty read (and, on the mutating arm, a WRITE) into the pool. Only the TRANSPORT choice
    # is gated now, at the `graphql_plan` call site.
    now = clock()
    snap = read_budget()
    if snap is not None:
        core = snap.get("core") or {}
        rem, reset = core.get("remaining"), core.get("reset")
        if isinstance(rem, int) and isinstance(reset, int) and rem <= CORE_LOW_WATER and reset > now:
            return reset, rem, True         # a MEASUREMENT: may refuse a read outright
        return None                    # a FRESH snapshot that says the pool is fine outranks a record
    reset = core_record_reset()
    if reset:
        return reset, 0, True           # the refused call OBSERVED zero — that IS a measurement
    reset, dated = health_state()
    if reset:
        # ⛔ `remaining` IS NOT OBSERVED ON THE UNDATED PATH — and it IS on the dated one. Getting the
        # two arms backwards broke BOTH directions at once (review round 2, regression of the round-1
        # fix): hard-coding 0 declared the pool empty on undated evidence (refusing writes), while
        # hard-coding None removed the ONE durable record that survives a GraphQL refusal overwriting
        # `last-limit`, so a known-empty DATED pool started SENDING writes into it (measured: 1 request
        # spent against a record saying `remaining=0 reset=<12m away>`).
        #   dated   -> the record carries the zero that WAS observed: a measurement, may refuse.
        #   undated -> `remaining=?`: unknown; reads divert, nothing is asserted, writes are sent.
        rec = _health_record() or {}
        rem = as_int(rec.get("remaining"))
        return reset, (rem if (dated and rem == 0) else None), dated
    return None


def record_core_exhausted(reset, remaining):
    """Write the NAMED state and return its phrase. One file, one line, per box.

    ⛔ IT IS REWRITTEN ONLY WHEN IT CHANGES. This is called from the per-call budget check, so on a box
    in the low-water band it would otherwise be a temp-file + rename per gh call — thousands an hour,
    for a line whose whole content is the same until the reset moves or the count crosses zero.

    ⛔ BUT AN **UNDATED** RECORD MUST STILL BE RE-STAMPED, OR IT EXPIRES MID-INCIDENT. Its `at=` is the
    ONLY thing that says how old the evidence is, and `health_state()` age-bounds it — so freezing `at=`
    (which “the fields that carry meaning are equal” did, since it excludes `at=`) meant that fifteen
    minutes into an ONGOING undated exhaustion the record stopped counting: `--health` said `gh-ok`,
    `core_pressure` said None, the read was SENT into the empty pool, and the rail went back to “the merge
    contract is UNKNOWN” while the pool was still empty (measured, round 8: five refusals at T…T+1300 left
    `at=T`). A refresh is cheap and bounded — once per half-window, not once per call."""
    phrase = "gh-core-exhausted resets_in=%s" % resets_in(reset)
    line = "%s at=%d bucket=core remaining=%s reset=%s" % (
        phrase, int(clock()), remaining if remaining is not None else "?", reset or 0)
    p = os.path.join(state_dir(), HEALTH_FILE)
    try:
        with open(p) as fh:
            cur = fh.read().strip()
        # `at=` moves every second by definition, so compare the FIELDS THAT CARRY MEANING rather than
        # the whole line: the phrase, the bucket and the reset window.
        keep = [kv for kv in cur.split() if not kv.startswith("at=")]
        if keep == [kv for kv in line.split() if not kv.startswith("at=")]:
            # …and an UNDATED record (reset=0) is re-stamped once per half-window so it cannot age out
            # while the exhaustion continues. A DATED one needs no re-stamp: its `reset` is the bound.
            cur_at = as_int(next((kv.split("=", 1)[1] for kv in cur.split() if kv.startswith("at=")), None))
            dated = reset is not None and int(reset or 0) > 0
            if dated or (cur_at and clock() - cur_at <= HEALTH_UNKNOWN_WINDOW // 2):
                return phrase
    except OSError:
        pass
    write_state(HEALTH_FILE, line)
    return phrase


def record_core_ok():
    """A `core` call SUCCEEDED, so the named state no longer holds. ⛔ BUCKET-SCOPED exactly like
    `record_recovery`: a GraphQL success proves nothing about a core pool, and clearing on it would
    report the opposite of the truth on the one line an operator reads."""
    try:
        os.unlink(os.path.join(state_dir(), HEALTH_FILE))
    except OSError:
        pass


def health_token():
    """(token, exit) for `--health`: the NAMED state a lane can print verbatim, or `gh-ok`.

    ⛔ AGE-BOUNDED, like `last-limit`: a record whose window has passed is not a current state (the
    record outlives the process that wrote it, so without this a one-off exhaustion would be asserted
    for ever). Exit 3 = exhausted, 0 = healthy — never 1, which callers read as “the check failed”.

    ⛔ AND IT AGREES WITH `core_pressure`, WHICH IS THE POINT. An undated record (a refusal that carried
    no reset) is a current state for `HEALTH_UNKNOWN_WINDOW`; deriving “healthy” from `reset == 0` made
    `--health` say `gh-ok` at the exact moment the pool was spent and the failover had stopped.

    ⛔ A FRESH METER OUTRANKS THE RECORD, IN BOTH DIRECTIONS — and reading only the record got both of
    them wrong (measured, review round 6): a `--budget` probe that had JUST measured `core=0` still
    read `gh-ok` here, because nothing had been refused yet and so no health record existed. That is
    the incident's own false-healthy line, printed by the verb an operator is told to trust. The
    reverse direction lies too: a record from a window that has since cleared read `gh-core-exhausted`
    beside a meter saying 3000 remaining. `read_budget()` is a FILE READ (no request), so consulting it
    here costs nothing and cannot be the reason a box polls the meter.

    ⛔ AND IT NEVER REPORTS A NUMBER NOBODY MEASURED. An UNDATED record is a refusal that carried no
    reset (every `GH_LIMIT_NO_WAIT` caller skips the probe, and eight heartbeat tools set it). Printing
    the synthetic `HEALTH_UNKNOWN_WINDOW` as `resets_in=<Nm>` stated a 15m window for a refusal that
    came with a 12m one (measured) — a lane would wait out the wrong number. The window is UNKNOWN, so
    the token says `?`, in the same slot and the same shape, and callers that only read the TOKEN are
    unaffected."""
    snap = read_budget()
    if snap is not None:
        core = snap.get("core") or {}
        rem, mreset = core.get("remaining"), core.get("reset")
        if isinstance(rem, int) and isinstance(mreset, int):
            # ⛔ A FRESH SNAPSHOT ALWAYS WINS — INCLUDING WHEN ITS WINDOW HAS ALREADY PASSED. The first
            # version required `mreset > now`, so a fresh meter whose reset was in the past fell THROUGH
            # to the durable record and reported an exhaustion the rail and the write guard both treat as
            # closed (measured, round 7: `--health` said `resets_in=12m` rc 3 while `core_pressure()` said
            # None and the rail printed nothing — the verb telling a lane to wait for a window nobody
            # else believes in). Either the meter has headroom (gh-ok), or it is empty inside a live
            # window (named), or its window is over (gh-ok, whatever the older record says).
            if mreset <= clock():
                return "gh-ok", 0
            if rem == 0:
                return "gh-core-exhausted resets_in=%s" % resets_in(mreset), 3
            # ⛔ THE LOW-WATER BAND IS NOT EXHAUSTION — the same distinction `core_pressure` makes for
            # writes. An operator reading `gh-core-exhausted` at remaining=50 would chase a window that
            # has not started; the failover is a transport choice, not a pool state.
            return "gh-ok", 0
    reset, dated = health_state()
    if reset is None:
        # ⛔ THE DURABLE `core` REFUSAL RECORD IS THE LAYER'S OWN MEASUREMENT and `core_pressure()`
        # already trusts it — reading only the health file here made the two disagree in the window that
        # matters most: a refused core call is recorded in `last-limit` on EVERY attempt, while the
        # `health` record is only written when the layer gives up. So mid-backoff (or with the failing
        # lane killed before it gave up) `core_pressure` refused every WRITE with zero requests and
        # diverted every READ, while this verb printed `gh-ok` rc 0 — the incident's own false-healthy
        # line, from the one verb an operator is told to trust (measured, review round 6).
        rec_reset = core_record_reset()
        if rec_reset is not None:
            return "gh-core-exhausted resets_in=%s" % resets_in(rec_reset), 3
        # ⛔ “I COULD NOT READ THE RECORD” IS NOT “THE POOL IS FINE”. A record that exists but cannot be
        # parsed (a truncated write, a hand edit, a version skew) used to be served as `gh-ok` rc 0 — an
        # answer that was never obtained, reported as healthy, from the one verb an operator trusts at
        # the exact moment nothing else works. A SPENT dated window is different (it is an answer), and
        # is still `gh-ok`.
        if _record_is_unreadable():
            return "gh-health-unknown", 3
        return "gh-ok", 0
    if not dated:
        return "gh-core-exhausted resets_in=?", 3
    return "gh-core-exhausted resets_in=%s" % resets_in(reset), 3


# ── the GraphQL equivalents (EXACT bodies only) ──────────────────────────────────────────────
# ⛔ EVERY ENCODER BELOW MAY RETURN None, AND None MEANS “I CANNOT REPRODUCE THE REST BODY”. It is
# never filled in with a plausible default: a synthesized empty `check_runs` or a null `head` would
# be the failure this whole file exists to prevent — an EMPTY answer read as a green tree.
_GQL_PR = ("query($owner:String!,$name:String!,$number:Int!)"
           "{repository(owner:$owner,name:$name){pullRequest(number:$number)"
           "{number state isDraft merged mergeable headRefOid headRefName baseRefOid baseRefName "
           "title body url updatedAt createdAt closedAt mergedAt "
           "changedFiles additions deletions comments{totalCount} author{login}}}}")
_GQL_ISSUE_COMMENTS = ("query($owner:String!,$name:String!,$number:Int!)"
                       "{repository(owner:$owner,name:$name){issue(number:$number)"
                       "{comments(first:30){pageInfo{hasNextPage} nodes{databaseId body createdAt url author{login}}}}}}")
_GQL_PR_REVIEWS = ("query($owner:String!,$name:String!,$number:Int!)"
                   "{repository(owner:$owner,name:$name){pullRequest(number:$number)"
                       "{reviews(first:30){pageInfo{hasNextPage} nodes{databaseId state submittedAt body commit{oid} author{login}}}}}}")

# ⛔ THE NAMES EACH ENCODER CAN ACTUALLY PRODUCE, AND WHY THAT LIST IS A GATE RATHER THAN A COMMENT.
# `jq` on a field that is ABSENT prints `null` and exits 0, so a partial equivalence is not a small
# imprecision — it is an EMPTY ANSWER WITH A SUCCESS STATUS, which is the one failure this file
# exists to prevent. Measured during review of this very change: `--jq .body` against a failover
# returned `null`/rc 0, and `record-review.sh` reads `.body` precisely to tell “the GET failed” from
# “the body is empty” before it PATCHes a PR description. A caller's `--jq` is therefore admitted only
# when every name it references is one this encoder produces; otherwise the read is NOT failed over
# (and, with the pool empty, refused by name instead of answered wrongly). Over-blocking here costs a
# refusal that would have happened anyway; under-blocking costs a confident wrong answer.
PULL_NAMES = frozenset({
    "number", "state", "draft", "merged", "mergeable", "title", "body", "html_url",
    "updated_at", "created_at", "closed_at", "merged_at", "changed_files", "additions",
    "deletions", "comments", "head", "base", "user", "sha", "ref", "login",
})
# A CONTAINER is a name whose VALUE the encoder reproduces only partly (`head` is {sha,ref}, while REST
# also has head.label/head.repo/head.user). Naming one as the END of a projection therefore asks for a
# partial object, which is the same defect as asking for an unproduced field.
FAILOVER_CONTAINERS = frozenset({"head", "base", "user"})
# ⛔ THE ALLOW-LIST IS FLAT (the encoder produces those names at the ROOT), SO WALKING THROUGH A CONTAINER
# MUST BE CHECKED AGAINST WHAT THAT CONTAINER ACTUALLY CARRIES. The rule used to look only at the LAST
# key, so `.user.html_url` was admitted — `user` is a container, `html_url` is a root name, and the
# encoder's `user` object has only `login`: the read answered `null` with rc 0 where REST returns a real
# URL (measured; an exhaustive sweep of 490 admitted two-segment programs found 21 divergences, all of
# this one shape). One map, so a new container cannot be added without saying what it reproduces.
CONTAINER_CHILDREN = {
    "head": frozenset({"sha", "ref"}),
    "base": frozenset({"sha", "ref"}),
    "user": frozenset({"login"}),
}
# ⛔ `merge_commit_sha` IS DELIBERATELY ABSENT, AND THIS IS THE MOST DANGEROUS FIELD TO GET WRONG.
# For an UNMERGED PR, REST `merge_commit_sha` is the TENTATIVE test-merge commit and GraphQL
# `mergeCommit` is **null** — the rail's own header says so (“GraphQL `mergeCommit` is NULL for any
# unmerged PR (verified on an open PR whose REST `merge_commit_sha` was populated)”), which is exactly
# why `admin-merge.sh:2049` reads the REST object instead of `gh pr view --json mergeCommit`.
# Reproducing the NAME from the OTHER field turns every open PR's merge ref into “absent”, and
# `resolve_merge_ref` then BLOCKS with `no CI run has evaluated the merge of this PR into its base` —
# a fabricated CI diagnosis for the whole empty-core window, on the very merges this failover exists to
# keep alive. There is no GraphQL equivalent, so the projection is refused (fail closed).
COMMENT_NAMES = frozenset({"id", "body", "created_at", "html_url", "user", "login"})
REVIEW_NAMES = frozenset({"id", "state", "body", "submitted_at", "commit_id", "user", "login"})
# jq operators/shapes that can reach a field WITHOUT naming it in a `.name` form. A projection using
# one cannot be shown to stay inside the reproduced body, so it is refused rather than guessed at.
PROJECTION_SHAPE_OPS = ("getpath", "to_entries", "with_entries", "keys", "keys_unsorted", "tojson",
                        "paths", "leaf_paths", "map_values", "values", "path", "env", "has",
                        # the STREAM family and the recursive walkers emit whole subtrees without
                        # naming a field: `[tostream]` / `[recurse]` both returned the encoder's entire
                        # subset with rc 0 (review round 2).
                        "tostream", "truncate_stream", "fromstream", "recurse", "walk")
PROJECTION_VALUE_FILTERS = ("select", "if", "first", "last", "nth", "until", "while", "recurse", "walk",
                            "input", "inputs")
# ⛔ WHY THIS IS A PARSER AND NOT A BLOCKLIST. Five review rounds each closed one jq syntax that
# reached a field without appearing as a dotted path — `.name`, then `."name"`, then `{name}`, then
# `[.]`/`@json`/`tostring`/`length`, then `del(.body)` / `.title |= "x"` / `. + {state:.state}`. That
# list cannot be finished: jq's grammar is open, and every round's fix taught the same lesson — a
# NEGATIVE rule ("this construct is not allowed") is defeated by the next construct that a helpful
# reader can spell, while a POSITIVE rule ("only these shapes are projections") is not.
#
# So the gate is now a CLOSED GRAMMAR over the shapes the fleet actually writes. Anything this parser
# cannot derive is REFUSED, which for this layer means a read that fails closed with the named state
# (and which would have been refused by an empty pool anyway). A false refusal costs one read; a false
# admission hands a lane a confident wrong answer with a success status.
#
#   program   := pipe ( '|' pipe )*            (the top level)
#   pipe      := atom ( ',' atom )*
#   atom      := path [ '//' literal ]
#              | '[' [ atom ( ',' atom )* ] ']'
#              | '{' [ IDENT ':' atom ( ',' IDENT ':' atom )* ] '}'   (shorthand `{x}` is NOT admitted)
#              | '(' program ')'
#              | string                    ("text \(program) text")
#              | FILTER                    (@tsv @csv @base64 tostring)
#   path      := '.' ( IDENT | '"' IDENT '"' | '[' '"' IDENT '"' ']' ) ( '.' IDENT | '[' '"' IDENT '"' ']' | '[]' )*
#   literal   := '"' … '"' | NUMBER | true | false | null | '{}' | '[]'
#
# SEMANTIC RULES on top of the grammar: every key must be in the encoder's allow-list; the LAST key of
# a path may not be a CONTAINER (a partly-reproduced object is not an answer); `[]` may not be terminal
# (an iteration whose RESULT is emitted is an identity read); and at least one allowed key must be read
# at all (otherwise the program emits whatever the encoder produced, which is the defect this exists to
# refuse). `merge_commit_sha` is absent from every allow-list on purpose — see the comment there.
_PROJ_FILTERS = ("@tsv", "@csv", "@base64", "tostring")
_PROJ_IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
_PROJ_NUMBER = re.compile(r"-?[0-9]+(?:\.[0-9]+)?")


class _ProjectionRefused(Exception):
    """The program is not a projection this layer can prove. Always a refusal, never a default."""


class _ProjectionParser(object):
    def __init__(self, text, allowed):
        self.s = text
        self.i = 0
        self.allowed = allowed
        self.leaf = False

    # ── lexical helpers ─────────────────────────────────────────────────────────────────────────
    def ws(self):
        while self.i < len(self.s) and self.s[self.i] in " \t\r\n":
            self.i += 1

    def peek(self):
        self.ws()
        return self.s[self.i] if self.i < len(self.s) else ""

    def take(self, ch):
        self.ws()
        if self.i >= len(self.s) or self.s[self.i] != ch:
            raise _ProjectionRefused("expected %r at %d" % (ch, self.i))
        self.i += 1

    def ident(self):
        self.ws()
        m = _PROJ_IDENT.match(self.s, self.i)
        if not m:
            raise _ProjectionRefused("expected an identifier at %d" % self.i)
        self.i = m.end()
        return m.group(0)

    def key(self, name):
        if name not in self.allowed:
            raise _ProjectionRefused("field %r is not reproduced by the encoder" % name)
        # ⛔ THE LEAF FLAG IS SET BY A KEY THAT PASSES THE MEMBERSHIP RULE, and only there: a program
        # that names no admissible key emits whatever the encoder produced, which is the defect this
        # refuses. The CONTAINER rule is applied to the LAST key of a path, not to every segment —
        # `.head.sha` walks THROUGH the container `head` to reach the scalar `sha`, and rejecting the
        # intermediate segment refused every in-tree projection (`[.base.sha,.head.sha]`).
        self.leaf = True

    # ── grammar ────────────────────────────────────────────────────────────────────────────────
    def program(self, top=True):
        self.pipe()
        while self.peek() == "|":
            self.take("|")
            # ⛔ A FILTER IS ONLY EVER APPLIED TO A STAGE, NEVER USED AS A BARE VALUE. `[.state,
            # tostring]` is `tostring` applied to the WHOLE object — an identity read — while
            # `.body | tostring` is a scalar derived from a named field. So a filter is admissible in
            # the stage after a `|`, and nowhere else.
            self.pipe(filters=True)
        self.ws()
        # ⛔ END-OF-INPUT IS A TOP-LEVEL RULE ONLY: a nested `(.a)` or `\(.b)` must stop at its own
        # closing delimiter, and checking here refused every parenthesised in-tree projection.
        if top and self.i != len(self.s):
            raise _ProjectionRefused("unconsumed input at %d: %r" % (self.i, self.s[self.i:self.i + 12]))

    def pipe(self, filters=False):
        self.atom(filters)
        while self.peek() == ",":
            self.take(",")
            self.atom(filters)

    def atom(self, filters=False):
        c = self.peek()
        if c == "[":
            self.array()
        elif c == "{":
            self.obj()
        elif c == "(":
            self.take("(")
            self.program(top=False)
            self.take(")")
        elif c == '"':
            self.string()
        elif c == ".":
            self.path()
        elif c == "@" or (filters and _PROJ_IDENT.match(self.s, self.i)):
            self.filter()
        elif c == "i" and self.s.startswith("if ", self.i):
            # ⛔ `if <path> then <literal> else <literal> end` IS A PROJECTION: every branch is a named
            # field or a constant, and `scripts/atomic-land.sh` reads exactly this to turn `.merged` into
            # "MERGED"/"OPEN". Refusing it made that caller's poll fall through its own `|| echo OPEN`
            # and report a LANDED PR as unmerged for the whole wait (review round 6).
            self.i += 3
            self.atom()
            self.ws()
            if not self.s.startswith("then", self.i):
                raise _ProjectionRefused("if without then")
            self.i += 4
            self.literal()
            self.ws()
            if not self.s.startswith("else", self.i):
                raise _ProjectionRefused("if without else")
            self.i += 4
            self.literal()
            self.ws()
            if not self.s.startswith("end", self.i):
                raise _ProjectionRefused("if without end")
            self.i += 3
        else:
            raise _ProjectionRefused("not a projection atom at %d: %r" % (self.i, self.s[self.i:self.i + 12]))

    def filter(self):
        self.ws()
        start = self.i
        for f in _PROJ_FILTERS:
            if self.s.startswith(f, self.i):
                self.i += len(f)
                # a filter APPLIED to an argument (`tostring(`, `@csv {`) is not this shape
                if self.peek() and self.peek() in "({":
                    raise _ProjectionRefused("filter %r takes an argument" % f)
                return
        self.i = start
        raise _ProjectionRefused("not an allowed filter at %d: %r" % (self.i, self.s[self.i:self.i + 12]))

    def array(self):
        self.take("[")
        if self.peek() == "]":
            self.take("]")
            return                                 # `[]` as a literal is admitted only after `//`
        self.pipe()
        self.take("]")

    def obj(self):
        self.take("{")
        if self.peek() == "}":
            self.take("}")
            return
        while True:
            k = self.ident()
            if self.peek() != ":":
                # `{name}` is `{name: .name}` — a key read with no dot. Refused: the shape is not in
                # the grammar, and admitting it is how the shorthand escaped five rounds ago.
                raise _ProjectionRefused("object shorthand %r is not a projection" % k)
            self.take(":")
            self.atom()
            if self.peek() == ",":
                self.take(",")
                continue
            self.take("}")
            return

    def string(self):
        self.take('"')
        while True:
            if self.i >= len(self.s):
                raise _ProjectionRefused("unterminated string")
            ch = self.s[self.i]
            if ch == "\\" and self.s[self.i:self.i + 2] == "\\(":
                self.i += 2
                self.program(top=False)
                self.take(")")
                continue
            if ch == "\\":
                self.i += 2
                continue
            self.i += 1
            if ch == '"':
                return

    def literal(self):
        self.ws()
        c = self.s[self.i:self.i + 1]
        if c == '"':
            self.string()
            return
        for kw in ("true", "false", "null"):
            if self.s.startswith(kw, self.i):
                self.i += len(kw)
                return
        m = _PROJ_NUMBER.match(self.s, self.i)
        if m:
            self.i = m.end()
            return
        if self.s.startswith("{}", self.i):
            self.i += 2
            return
        if self.s.startswith("[]", self.i):
            self.i += 2
            return
        raise _ProjectionRefused("not a literal at %d" % self.i)

    def path(self):
        names = []
        self.take(".")
        self.ws()
        if self.peek() == '"':
            names.append(self._quoted())
            self.key(names[-1])
        elif self.peek() == "[":
            self.take("[")
            if self.peek() == "]":
                # `.[]` as the FIRST segment: iteration over the root list. Legal only when something
                # after it names a field, exactly like the mid-path form below.
                self.take("]")
                if self.peek() in ("", ",", "]", "}", ")"):
                    raise _ProjectionRefused("terminal iteration would emit whole objects")
            else:
                self.take('"')
                names.append(self._quoted(consumed_open=True))
                self.take("]")
                self.key(names[-1])
        else:
            names.append(self.ident())
            self.key(names[-1])
        while True:
            c = self.peek()
            if c == ".":
                self.take(".")
                names.append(self.ident())
                self.key(names[-1])
            elif c == "[":
                self.take("[")
                if self.peek() == "]":
                    self.take("]")
                    # ⛔ AN ITERATION WHOSE RESULT IS EMITTED IS AN IDENTITY READ. It is legal only
                    # with something AFTER it that names a field (`.[] | .state`, `.[].x`); a `[]`
                    # that ENDS the expression hands back whole sub-objects — the encoder's SUBSET
                    # served as the answer. A following `|` is not terminal: the next stage decides.
                    if self.peek() in ("", ",", "]", "}", ")"):
                        raise _ProjectionRefused("terminal iteration would emit whole objects")
                    continue
                self.take('"')
                names.append(self._quoted(consumed_open=True))
                self.take("]")
                self.key(names[-1])
            else:
                break
        if names and names[-1] in FAILOVER_CONTAINERS:
            raise _ProjectionRefused("field %r is a container the encoder reproduces only partly" % names[-1])
        # ⛔ EVERY container on the way must be walked INTO a name it actually carries (see
        # CONTAINER_CHILDREN). `.user.html_url` passes the flat allow-list and would answer `null`.
        for i, name in enumerate(names[:-1]):
            kids = CONTAINER_CHILDREN.get(name)
            if kids is not None and names[i + 1] not in kids:
                raise _ProjectionRefused("field %r is not reproduced inside %r" % (names[i + 1], name))
        if self.peek() == "/" and self.s[self.i:self.i + 2] == "//":
            self.i += 2
            self.literal()

    def _quoted(self, consumed_open=False):
        if not consumed_open:
            self.take('"')
        name = self.ident()                     # a literal identifier only: no computed keys
        self.take('"')
        return name


def _projection_ok(jq, allowed):
    """Does this `--jq` program stay inside the body the encoder can produce?

    ⛔ A CLOSED GRAMMAR, NOT A LIST OF FORBIDDEN CONSTRUCTS — see the block above `_PROJ_FILTERS`.
    Five rounds of blocklist fixes each closed one spelling and left the next one open
    (`.name` → `."name"` → `{name}` → `[.]`/`@json`/`tostring`/`length` → `del(.body)` /
    `.title |= "x"` / `. + {state:.state}`), and the measured cost of the last one was a program that
    emitted the encoder's 22-key SUBSET where REST returns 46 keys, with rc 0. A rule that says only
    what IS a projection cannot be escaped by a spelling nobody thought of."""
    if not jq or not jq.strip():
        return False
    if ".." in jq:
        return False                # recursive descent: no depth bound, no field attribution
    p = _ProjectionParser(jq, allowed)
    try:
        p.program()
    except _ProjectionRefused:
        return False
    return p.leaf


def _enc_pull(doc):
    pr = (((doc.get("data") or {}).get("repository") or {}).get("pullRequest"))
    if not isinstance(pr, dict):
        return None
    # REST's `state` is lowercase and reports a merged PR as `closed` with `merged: true`; GraphQL has
    # its own third value. Mapping it ANY other way would make a merged PR look open.
    state = {"OPEN": "open", "CLOSED": "closed", "MERGED": "closed"}.get((pr.get("state") or "").upper(), "")
    mergeable = {"MERGEABLE": True, "CONFLICTING": False}.get((pr.get("mergeable") or "").upper())
    return json.dumps({
        "number": pr.get("number"), "state": state, "draft": bool(pr.get("isDraft")),
        "merged": bool(pr.get("merged")), "mergeable": mergeable, "title": pr.get("title"),
        "body": pr.get("body"), "html_url": pr.get("url"),
        "updated_at": pr.get("updatedAt"), "created_at": pr.get("createdAt"),
        "closed_at": pr.get("closedAt"), "merged_at": pr.get("mergedAt"),
        "changed_files": pr.get("changedFiles"), "additions": pr.get("additions"),
        "deletions": pr.get("deletions"),
        # REST's `comments` on a PR is a COUNT, not a list — same shape, from totalCount.
        "comments": (pr.get("comments") or {}).get("totalCount"),
        "head": {"sha": pr.get("headRefOid"), "ref": pr.get("headRefName")},
        "base": {"sha": pr.get("baseRefOid"), "ref": pr.get("baseRefName")},
        "user": {"login": (pr.get("author") or {}).get("login")},
    }).encode()


def _enc_issue_comments(doc):
    issue = (((doc.get("data") or {}).get("repository") or {}).get("issue"))
    if not isinstance(issue, dict):
        return None
    # ⛔ A MISSING CONNECTION IS NOT AN EMPTY ONE. Substituting `[]` answered rc 0 with an EMPTY body for
    # a document that simply did not carry `comments` — an empty answer with a success status, the one
    # shape this file exists to prevent (measured, review round 4). `nodes` present-and-empty is a real
    # “no comments”; `comments` absent is “I cannot reproduce the REST body”, which is `None`.
    conn = issue.get("comments")
    if not isinstance(conn, dict):
        return None
    # ⛔ AN ABSENT `pageInfo` IS NOT “COMPLETE”. Testing only `hasNextPage is True` read a missing (or
    # null) `pageInfo` as the end of the list and emitted a window truncated at `first:30` as the whole
    # answer — the exact “a truncated list reported as complete is a different answer” this guard
    # forbids, from the guard's own blind spot (measured, round 7). The connection must SAY it is
    # complete: `hasNextPage` false.
    if (conn.get("pageInfo") or {}).get("hasNextPage") is not False:
        return None
    nodes = conn.get("nodes")
    if not isinstance(nodes, list) or any(not isinstance(n, dict) for n in nodes):
        # ⛔ GraphQL returns `null` for a node the viewer cannot see, and `.get` on it raised an
        # AttributeError — the caller got a Python traceback instead of the named refusal, so
        # `objective.py`'s TRANSPORT_MARKERS could not turn it into VERDICT=GH-RATE-LIMITED
        # (measured, round 8). A list we cannot reproduce faithfully is `None`, like every other
        # unrepresentable shape here.
        return None
    return json.dumps([{"id": n.get("databaseId"), "body": n.get("body"),
                        "created_at": n.get("createdAt"), "html_url": n.get("url"),
                        "user": {"login": (n.get("author") or {}).get("login")}} for n in nodes]).encode()


def _enc_pr_reviews(doc):
    pr = (((doc.get("data") or {}).get("repository") or {}).get("pullRequest"))
    if not isinstance(pr, dict):
        return None
    conn = pr.get("reviews")
    if not isinstance(conn, dict):
        return None                    # a missing connection is not an empty review list (see above)
    if (conn.get("pageInfo") or {}).get("hasNextPage") is not False:
        return None                    # absent pageInfo = “I cannot prove this is the whole list”
    nodes = conn.get("nodes")
    if not isinstance(nodes, list) or any(not isinstance(n, dict) for n in nodes):
        return None                    # a null node is not a review we can reproduce (see comments)
    return json.dumps([{"id": n.get("databaseId"), "state": n.get("state"), "body": n.get("body"),
                        "submitted_at": n.get("submittedAt"),
                        "commit_id": (n.get("commit") or {}).get("oid"),
                        "user": {"login": (n.get("author") or {}).get("login")}} for n in nodes]).encode()


# path regex -> (GraphQL query, encoder). ⛔ `repos/{o}/{r}/commits/{sha}/check-runs` IS DELIBERATELY
# ABSENT. `statusCheckRollup` mixes `CheckRun` nodes with `StatusContext` nodes, and a StatusContext
# has NO representation as a REST `check_run` — a synthesized list would silently drop every legacy
# status and could turn a red surface into a green one. The honest answer for that path is the named
# state (fail closed), not a plausible-looking body. Recorded in docs/ops/gh-rate-limits.md.
GRAPHQL_EQUIVALENTS = (
    (re.compile(r"^repos/([^/]+)/([^/]+)/pulls/(\d+)$"), _GQL_PR, _enc_pull, PULL_NAMES),
    (re.compile(r"^repos/([^/]+)/([^/]+)/issues/(\d+)/comments$"), _GQL_ISSUE_COMMENTS,
     _enc_issue_comments, COMMENT_NAMES),
    (re.compile(r"^repos/([^/]+)/([^/]+)/pulls/(\d+)/reviews$"), _GQL_PR_REVIEWS,
     _enc_pr_reviews, REVIEW_NAMES),
)


def graphql_plan(plan):
    """(gh argv, encoder) that answers `plan`'s REST read from the GraphQL pool, or None.

    ⛔ THE ADMISSION IS `conditional_plan`'S, NOT A SECOND ONE. That function already refuses every
    shape whose output this layer would have to re-create by hand (`--paginate`, `-i`, `-H`, `-f`, a
    non-GET method, `--template`). Taking the plan as input means a shape it refuses can never be
    failed over either — one gate, two transports.

    ⛔ AND THE PROJECTION IS ADMITTED SEPARATELY. A REST body we can only PARTLY reproduce is not a
    near miss: `--jq` prints `null` for a missing field and exits 0, so the caller is told the read
    succeeded while a field it needed does not exist. `_projection_ok` therefore refuses any `--jq`
    that names something the encoder does not produce.

    ⛔ A GHES HOST IS REFUSED — BOTH SPELLINGS. `gh` reads the host from `GH_HOST` when `--hostname`
    is absent, so checking only the flag let a box with `GH_HOST=<ghes>` be failed over to an endpoint
    this layer has no reason to trust (the same class the ETag cache key already guards)."""
    if plan is None or plan.get("host"):
        return None
    host_env = (os.environ.get("GH_HOST") or "").strip().lower()
    if host_env and host_env != "github.com":
        return None
    path = (plan.get("path") or "").strip("/")
    for pat, query, enc, allowed in GRAPHQL_EQUIVALENTS:
        m = pat.match(path)
        if not m:
            continue
        if not _projection_ok(plan.get("jq"), allowed):
            log_event("failover: NOT attempted for `%s` — the --jq names a field the encoder cannot "
                      "reproduce, so answering it would return null with a success status" % path)
            return None
        owner, name, number = m.group(1), m.group(2), m.group(3)
        # ⛔ VARIABLES, NOT INTERPOLATION. The path comes from argv, so a string-substituted query
        # would be an injection surface; gh types `-F number=` as an Int, which is what the query
        # declares.
        gargv = ["api", "graphql", "-f", "query=" + query,
                 "-f", "owner=" + owner, "-f", "name=" + name, "-F", "number=" + number]
        return gargv, enc
    return None


def run_failover(real_gh, fo):
    """One GraphQL request, encoded back into the REST body the caller expects.

    ⛔ A GRAPHQL `errors` ARRAY IS A FAILURE, not an empty result — the same rule as a refused REST
    call. The caller applies its own `--jq` afterwards (`emit`), exactly as on the REST path, so a
    projection can never be silently dropped by the transport change."""
    gargv, enc = fo
    res = run(real_gh, gargv)
    if res.rc != 0:
        return Result(res.rc, res.out, res.err)
    try:
        doc = json.loads(res.out.decode("utf-8", "replace"))
    except ValueError:
        return Result(1, b"", b"gh-limit: failover answered with bytes that are not JSON\n")
    if doc.get("errors"):
        return Result(1, b"", ("gh-limit: graphql failover refused: %s\n"
                               % json.dumps(doc["errors"])[:400]).encode())
    body = enc(doc)
    if body is None:
        return Result(1, b"", b"gh-limit: graphql failover cannot reproduce the REST body (object absent)\n")
    return Result(0, body, b"")


def _named_core_refusal(phrase, why):
    """The single line a lane prints instead of “branch protection UNREADABLE” — STDOUT-CLEAN.

    It keeps the words `rate limit` because `objective.py`'s TRANSPORT_MARKERS turn a refused read
    into `VERDICT=GH-RATE-LIMITED` from that phrase, and a named state that lost the classifier's
    marker would be MORE honest to a human and LESS honest to the beat. ⛔ AND IT NO LONGER ASSERTS
    “the REST pool is EMPTY”: the same helper is called for `gh-graphql-unavailable` and for a
    low-water refusal, where that sentence would be false about the pool."""
    sys.stderr.write(
        "gh-limit: %s — gh rate limit: this is the GitHub BUDGET, not a broken repo, an invalid "
        "token, or GitHub being down. %s\n" % (phrase, why))


def _named_floor_refusal(remaining, floor, reset, dated):
    """The floor's own refusal: NAMED, STDOUT-CLEAN, and TRUE about the pool.

    ⛔ IT SAYS `remaining=<n>`, NOT `remaining=0`. The pool is not empty; it is inside the reserve
    this layer keeps for writes, and a message that over-claimed emptiness would be the same false
    diagnosis as `repo-authority.sh` printing “the merge contract is UNKNOWN” for a spent budget —
    the defect the whole change exists to remove. `resets_in=?` when the window was never measured,
    for the same reason (`_record_is_unreadable`).

    ⛔ IT KEEPS THE WORDS `gh rate limit` because `objective.py`'s TRANSPORT_MARKERS classify a
    refused read from that phrase, and here the budget genuinely IS the reason. It writes NO health
    record: nothing was measured as exhausted, and a floor refusal is not evidence about the pool.
    ⛔ BUT IT DOES RECORD ITSELF IN `events.log` (review P2). Every rail caller passes `2>/dev/null`,
    so a fleet-wide floor refusal was invisible everywhere — `--health` said `gh-ok`, no `last-limit`
    was written, and the only copy of the reason was the stderr the caller discarded. A local append
    costs no request, and it makes the policy findable after the fact."""
    log_event("pressure: gh-core-floor remaining=%s floor=%d resets_in=%s — read refused; the reserve "
              "is kept for writes (GH_LIMIT_ESSENTIAL=1 defers this policy)"
              % ("?" if remaining is None else remaining, floor,
                 resets_in(reset) if dated else "?"))
    sys.stderr.write(
        "gh-limit: gh-core-floor remaining=%s floor=%d resets_in=%s — gh rate limit: this is the "
        "GitHub BUDGET, not a broken repo, an invalid token, or GitHub being down. The REST pool is "
        "inside the reserve this layer keeps for WRITES (a merge has no second pool), and this read "
        "has NO exact GraphQL equivalent, so it is refused rather than spending that reserve. "
        "Nothing was sent. If this work cannot proceed without this read, re-run with %s=1"
        "%s.\n"
        % ("?" if remaining is None else remaining, floor,
           resets_in(reset) if dated else "?", ESSENTIAL_ENV,
           "" if dated else " (the window was never measured, so no reset is claimed)"))


def _dispatch(real_gh, gh_argv):
    """Run, back off, retry — holding the single-flight lock for each ATTEMPT and NOT for the wait.

    ⛔ THE LOCK IS RELEASED DURING A WAIT, deliberately. The invariant is "one gh request in flight
    per box", not "one caller in the queue": holding it through a 60/120/240 s backoff would park
    every other gh call on the box behind a box that is simply waiting — including the merge that is
    the reason the harness runs. Releasing it during the wait keeps the invariant exactly (no two
    requests overlap) while letting an independent call proceed (it will be refused and back off on
    its own if the bucket is still empty, which is the honest behaviour)."""
    plan = conditional_plan(gh_argv)
    # The failover uses the SAME parse with the ETag kill-switch ignored (see `conditional_plan`):
    # turning off conditional requests must not take the second transport with it.
    read_plan = plan if plan is not None else conditional_plan(gh_argv, honour_kill_switch=False)
    attempt = 0
    waited = 0.0
    mutating = is_mutating(gh_argv)
    # ⛔ THE ACCOUNT VIEW COMES FIRST (#2137). If this BOX's record says the bucket is inside a
    # window, every client on the box waits it out: that is what makes one box's observation useful
    # to its peers instead of each client spending four attempts to rediscover the same refusal. The
    # gate is bounded (see marker_gate), so a bad record cannot park the box — that failure is the
    # reason this whole change exists.
    # ⛔ AND ITS WAIT COUNTS. `waited` is what the refusal line reports as the time this call spent;
    # dropping a 60-300 s gate pause from it made that evidence wrong by exactly the window it claims
    # to have honoured (measured: 499 s of waits reported as 439 s).
    waited += marker_gate(gh_argv, real_gh, clock())
    if mutating:
        # The bulk of the mutation gap is waited OUTSIDE the lock (a 1 s pause under the box lock
        # would park every unrelated gh call); the remainder is re-checked inside it, immediately
        # before the request leaves — see pace_mutation.
        w = pace_mutation()
        if w > 0:
            log_event("pacing mutation: waiting %.2fs (>= %.1fs between mutative calls)" % (w, MUTATION_GAP))
            pause(w)
    bucket = bucket_for(gh_argv)
    # A call that makes no request cannot spend the ACCOUNT's budget (`gh auth token` is an offline
    # keyring read the harness runs every refresh; `--version`/`help` are local). Counting them would
    # pace local commands against a network budget.
    counts_budget = makes_request(gh_argv)
    res = None
    # ⛔ BUDGET FIRST, TRANSPORT SECOND — AND THE BUDGET READ IS FREE. `core_pressure` touches two
    # local files (a snapshot someone already paid for, and the durable refusal record) and makes NO
    # request, so this decision costs nothing on the hot path. It is also why a box does not need to
    # poll the meter to benefit: the FIRST refused `core` call anywhere writes the record every other
    # lane then reads.
    fo = None
    core_reset = None                     # kept so a LATER record cannot erase the reset we acted on
    core_empty = False                    # did the DECISION say the pool was empty (not merely low)?
    core_dated = False                    # …and did it know WHEN the window ends?
    # ⛔ A SPECULATIVE CONDITIONAL READ IS ALLOWED **ONCE**, NEVER ONCE PER RETRY. See the branch that
    # sets it: a cached validator offers a POSSIBLE 304, not a free request, so a changed resource must
    # be refused rather than retried into the pool the layer has measured as empty.
    _speculative_read = False
    # ⛔ THE GUARD IS NOT `bucket == core`, BECAUSE THE RAIL'S OWN MERGE IS LABELLED `graphql`.
    # `bucket_for` answers `core` only for `REST_SUBCOMMANDS`, so `gh pr merge` → `graphql` — while
    # `gh-rest/gh` TRANSLATES that same command into `api -X PUT repos/…/pulls/N/merge`, which IS a
    # core write (and it delegates the verbatim form for `--admin`, an unmodelled flag, which is
    # exactly what `admin-merge.sh` passes). Measured before this fix: with a dated-empty core record,
    # `gh pr merge --admin --match-head-commit …` was SENT (1 request), the refusal was recorded
    # against `graphql`, a 64 s wait and a retry followed, NO health record was written — and once the
    # 30 s snapshot expired, `--health` said `gh-ok`: the 2026-10-22 misdiagnosis, from the path that
    # matters most. A WRITE therefore consults the CORE record whatever pool gh labels it with: there
    # is no second pool for a write, and a refusal is retryable while a retry storm is not. (The
    # over-block this accepts: on a box with no REST adapter a GraphQL-native merge could have
    # succeeded during a core-empty window — refused, visible, and re-runnable; the alternative is the
    # burst this layer exists to prevent.)
    bucket = bucket_for(gh_argv)
    if reaches_api(gh_argv) and (bucket == "core" or (mutating and bucket == "graphql")):
        # ⛔ MEASURE THE POOL BEFORE DECIDING ON IT (#2342 review P1). The floor can only act on a
        # MEASURED `remaining`, and the only non-zero source of one is `budget.json` — whose only
        # writer WAS the `--budget` verb, which NO harness script calls, plus the refusal path's own
        # probe (which by definition runs once the pool is already EMPTY). So the floor was a gate
        # that could never fire in production: the no-op-enforcer class it exists to prevent, and the
        # suite only reached it because a test called `--budget` explicitly. `read_budget()` stays the
        # free hot path; this spends ONE exempt `/rate_limit` per box per TTL, and only when there is
        # no fresh snapshot to read.
        # ⛔ ONLY WHERE THE FLOOR COULD ACT, AND ONLY WHEN NOTHING LOCAL IS KNOWN. A probe on every
        # read would spend a request to learn something the existing mechanisms already record (the
        # refusal path probes once for the whole box), and a read that CAN fail over needs no floor: it
        # is served from GraphQL either way. So a probe happens for a read that has NO exact
        # equivalent, when no snapshot and no durable record exists — the exact case in which the
        # guard would otherwise be blind.
        if read_budget() is None and core_pressure() is None and graphql_plan(read_plan) is None:
            budget_snapshot_or_probe(real_gh)
        pressure = core_pressure()
        if pressure is not None:
            reset, remaining, core_dated = pressure
            core_reset = reset
            core_empty = (remaining == 0)
            # ⛔ “EXHAUSTED” IS A CLAIM ABOUT THE POOL, AND IT MUST BE TRUE. In the low-water band
            # (0 < remaining <= CORE_LOW_WATER) the pool is NOT empty: reads move to GraphQL to keep
            # the reserve, but nothing is asserted exhausted and no write is refused. The earlier
            # draft refused writes and wrote `gh-core-exhausted` at remaining=50 — a false diagnosis
            # produced by the very layer that exists to stop false diagnoses.
            empty = core_empty
            # ⛔ THE NAMED STATE IS WRITTEN WHENEVER IT IS TRUE — including on the failover path, where
            # the read SUCCEEDS. The pool being empty is a fact about the budget that lanes,
            # `repo-authority.sh` and an operator all need to see; a GraphQL-served read does not make
            # it stop being true (only a real `core` success does — see `record_core_ok`).
            phrase = record_core_exhausted(reset if core_dated else None, remaining) if empty else None
            if mutating:
                if empty and core_dated:
                    # ⛔ A WRITE HAS NO SECOND POOL. `merge`, `comment` and `PATCH` have no GraphQL
                    # equivalent that IS the same write, so there is nothing to fail over TO — and
                    # retrying into an empty pool is what turned one limit into a 4,482-fork storm.
                    # ⛔ BUT ONLY A DATED WINDOW MAY REFUSE WITHOUT SENDING ONE. An undated refusal
                    # (no reset) may have been a burst that cleared seconds ago, and nothing would
                    # ever clear the record if no call were attempted — `record_core_ok` fires on a
                    # SUCCESS, so a box that refuses pre-emptively could never recover itself.
                    _named_core_refusal(
                        record_core_exhausted(reset if core_dated else None, remaining),
                        "This call WRITES (no GraphQL equivalent of the same write) and is NOT retried.")
                    return 1
                # In the band (or with undated evidence) a WRITE is what the reserve exists for.
            else:
                fo = graphql_plan(read_plan) if failover_enabled() else None
                if fo is not None:
                    log_event("failover: %s — serving `%s` from the GraphQL pool"
                              % (phrase or "core remaining=%s reset=%s"
                                 % ("?" if remaining is None else remaining, reset),
                                 _flight_label(gh_argv)))
                elif empty and core_dated:
                    # ⛔ UNLESS A FREE REVALIDATION IS AVAILABLE. A `gh api` GET with a stored ETag costs
                    # NOTHING on a 304 (“a 304 does not count against the primary limit” — this file's
                    # own promise), so refusing it before trying would be an over-block against the
                    # guarantee that makes polling affordable. Only a call that WOULD spend quota is
                    # refused pre-emptively.
                    if plan is not None and cache_get(cache_key(plan)) is not None:
                        # ⛔ A CACHED VALIDATOR OFFERS A *POSSIBLE* 304 — IT IS NOT ONE. Sending the
                        # call is therefore a bet that it spends nothing, and when the resource HAS
                        # changed the request goes into a pool the layer has MEASURED as empty and
                        # then enters the ordinary retry ladder. Measured, round 9: the incident's own
                        # read (`branches/main/protection`) with one cached validator made FOUR
                        # conditional GETs into the empty pool and reported `waited=599s`, where the
                        # same box with no validator made ZERO requests and refused by name. So the
                        # bet is allowed exactly ONCE — a 304 succeeds and costs nothing, anything
                        # else is refused WITHOUT a retry, which is what “never retry into the limit”
                        # means here.
                        _speculative_read = True
                        log_event("pressure: core empty but a validator is cached for `%s` — "
                                  "attempting the conditional GET ONCE (a 304 spends no quota; a "
                                  "changed resource is refused, not retried)"
                                  % _flight_label(gh_argv))
                    else:
                        # ⛔ NO EXACT EQUIVALENT, EMPTY POOL: refuse with the NAME. Approximating it
                        # (an empty `check_runs`, a null protection set, a `--jq` of a field we
                        # cannot produce) is the one thing that would make a lane read “nothing is
                        # required” — a red tree mistaken for a green one.
                        _named_core_refusal(
                            phrase,
                            "This read has NO exact GraphQL equivalent, so it is refused rather "
                            "than approximated.")
                        return 1
                elif isinstance(remaining, int) and 0 < remaining <= CORE_FLOOR and not essential():
                    # ⛔ THE FLOOR, ENFORCED — and this is the branch #2342 is about. It used to say
                    # “remaining > 0 but low and no equivalent: the read can still succeed, so let
                    # it”, i.e. a read with no failover was allowed to spend the RESERVE. That is the
                    # spend that empties the pool in the last minutes of every window and takes every
                    # WRITE down with it (measured 2026-10-23 04:11Z: `core remaining=0` for the Mac
                    # and all three cells at once). The reserve is for work that cannot be deferred;
                    # a caller that says it cannot be deferred asks for it by name.
                    # ⛔ BUT A CACHED VALIDATOR IS CONSULTED FIRST (review P1). Refusing a read whose
                    # 304 would have cost NOTHING is stricter than total exhaustion, and the arm above
                    # already states the rule: “refusing it before trying would be an over-block
                    # against the guarantee that makes polling affordable”. Same bet, same bound: a
                    # 304 succeeds free, a CHANGED resource is refused without a retry.
                    if plan is not None and cache_get(cache_key(plan)) is not None:
                        _speculative_read = True
                        log_event("floor: core remaining=%d <= floor=%d but a validator is cached for "
                                  "`%s` — attempting the conditional GET ONCE (a 304 spends no "
                                  "quota; a changed resource is refused, not retried)"
                                  % (remaining, CORE_FLOOR, _flight_label(gh_argv)))
                    else:
                        _named_floor_refusal(remaining, CORE_FLOOR, reset, core_dated)
                        return 1
                # remaining UNKNOWN (an undated record — no measurement, so no floor claim), or the
                # caller declared this read essential: it can still succeed, so it is sent.
    while True:
        # ⛔ THE PARTITION IS TAKEN IMMEDIATELY BEFORE THE SEND (requirement 1): the slot is a
        # REQUEST, so a retry spends another one, and NO_WAIT callers proceed over the partition with
        # the overdraw recorded rather than dying in a queue they cannot afford. ONE pause at most: a
        # second full window means a peer (or a clock jump) took the slot, and waiting again would
        # multiply the layer's in-call bound by the attempt count.
        if counts_budget:
            bwait = budget_gate(bucket, clock())
            if bwait > 0:
                if bwait > MAX_WAIT:
                    share = account_share()
                    record_budget(bucket, bwait, share)
                    sys.stderr.write(
                        "gh-limit: this box's share of the ACCOUNT's %s budget is exhausted (fleet=%d,"
                        " %d per %ds) and the next slot is %ds away — beyond the %ds in-call bound, so"
                        " refusing now rather than holding the call\n"
                        % (bucket, share["fleet"], share["per_window"], share["window"], int(bwait),
                           int(MAX_WAIT)))
                    log_event("account budget: %s next slot %ds away (> %ds bound) — failing fast"
                              % (bucket, int(bwait), int(MAX_WAIT)))
                    # ⛔ NEVER SUBTRACT WHAT THE CHILD PRINTED. This branch is reachable on a RETRY, so
                    # a previous attempt's stdout/stderr may be the only evidence the caller has; the
                    # local refusal must ADD its reason, not replace the child's answer.
                    if res is not None:
                        if res.out:
                            sys.stdout.buffer.write(res.out)
                        if res.err:
                            sys.stderr.buffer.write(res.err if res.err.endswith(b"\n") else res.err + b"\n")
                    # ⛔ AND THE CALLER READS THE VERDICT FROM THE EXIT CODE. 75 (EX_TEMPFAIL) is the
                    # layer's "refused LOCALLY, retry later" signal — the same one the give-up path uses
                    # — so a caller that only inspects stderr cannot mistake a partition refusal for a
                    # success. Nothing was sent, and the rejection is what makes the partition real.
                    return 75
                log_event("account budget: %s at this box's share — waiting %ds before attempt %d"
                          % (bucket, int(bwait), attempt + 1))
                w0 = bwait
                pause(bwait)
                waited += w0
                bwait = budget_gate(bucket, clock())
                if bwait > 0:
                    # ⛔ NEVER FALL THROUGH SILENTLY. Sending with no slot and no line is exactly the
                    # invisible over-partition burst this change exists to remove; the send happens
                    # (the caller has already waited its bounded share) and the overdraw is recorded.
                    # The line names the time actually WAITED (`w0`), not the time still remaining,
                    # and it is bounded to once per window so it cannot flood `events.log`.
                    if _overdraw_once(bucket, clock(), account_share()["window"]):
                        log_event("account budget: %s still at its share after waiting %ds — proceeding "
                                  "OVER the partition (recorded, not silent)" % (bucket, int(w0)))
        attempt += 1
        # ⛔ THE SINGLE-FLIGHT LOCK IS FOR REQUESTS, NOT FOR CALLS (#3099). Its invariant is "one gh
        # REQUEST in flight per box" — and a call that makes NO request cannot overlap anyone. Taking
        # the lock anyway made a purely LOCAL read queue behind every API call on the box, and the
        # measured consequence was not slow: it was a REFUSED WORKER. `wt_gh_token` / the launch-line
        # guard run `gh auth token` (an OFFLINE hosts.yml/keyring read — `makes_request()` is False)
        # under a 10 s alarm, through the `gh-rest` PATH shim, i.e. through THIS function — so on a
        # busy box the credential read waited its turn and the alarm fired first. Measured on the mac
        # 2026-10-30 (uncontended): `gh-rest/gh auth token` 4.1 s vs the real binary's 0.009 s; 8
        # concurrent shim calls on a cell: 436/571/691/858/1052/1259/1395/1529 ms — strictly linear,
        # which is a queue, not work. `worker-terminal.sh` then reported rc=98 ("the credential
        # contract FAILS") and agent-infra merged 0 PRs for 9 hours while the controller classified
        # correctly. ⛔ THE PREDICATE IS `makes_no_request_strictly`, NOT `counts_budget`: the budget
        # predicate is fail-OPEN for shapes that DO reach the network (`api rate_limit`, an
        # unattributable `api` argv, a help-looking flag VALUE) and using it here unserialised them
        # (review finding, measured: peak 1 -> peak 6). See that function's own note.
        lock = None if makes_no_request_strictly(gh_argv) else acquire_lock()
        try:
            if mutating:
                w = pace_mutation()
                if w > 0:
                    pause(w)
                mark_mutation()
            if fo is not None:
                # Inside the lock, like every other request: the failover is not an exemption from
                # “one gh request in flight per box”.
                res, headers = run_failover(real_gh, fo), {}
            else:
                res, headers = run_attempt(real_gh, gh_argv, plan)
        finally:
            release_lock(lock)
        if res.rc == 0:
            # ⛔ ON EVERY SUCCESS, not only this process's own retry: the record outlives the process
            # that wrote it, so the FIRST call that succeeds after a limit is the evidence — waiting
            # for the same process to recover leaves a healthy box asserting `rate_limited` for the
            # full 15-minute age bound. Costs one small read, writes only an unrecovered record.
            # ⛔ BUT ONLY A CALL THAT ACTUALLY TOUCHED THE API IS EVIDENCE. `gh --version`,
            # `gh help`, `gh completion` succeed without a request; marking a live limit recovered
            # turned `gh=rate_limited(...)` into `gh=recovered(...)` for 15 minutes on a box that was
            # still refusing — and `cloud-cell-supervisor.sh`'s `cmd_check` runs `gh --version`
            # through this very layer, so the operator's diagnostic ERASED the evidence it was run
            # to read (review round 8).
            if makes_request(gh_argv) and getattr(res, "status", None) != 304:
                # ⛔ A REVALIDATED `304` IS NOT A SUCCESSFUL CORE CALL. It is exempt from the primary
                # limit BY DESIGN — the same “exempt, therefore not evidence” class `makes_request`
                # already excludes for `api rate_limit`. Counting it here made one cached-validation
                # poll ERASE the exhaustion evidence: `record_core_ok()` unlinked the health record and
                # `record_recovery("core")` marked `last-limit` recovered, so once the 30 s budget
                # snapshot expired every lane on the box stopped failing over and `--health` said
                # `gh-ok` while the pool was spent — the exact 2026-10-22 misdiagnosis this layer
                # exists to remove, reachable from the one optimisation that is supposed to be free.
                # The bucket that recovers is the one that ANSWERED, not the one the argv names.
                record_recovery("graphql" if fo is not None else bucket_for(gh_argv))
                if fo is None and bucket_for(gh_argv) == "core":
                    record_core_ok()
            if fo is not None:
                log_event("failover: served `%s` from GraphQL (core still exhausted)"
                          % _flight_label(gh_argv))
                if res.err:
                    sys.stderr.buffer.write(res.err)
                # The caller's OWN `--jq` is applied to the synthesized REST body, exactly as it would
                # be to a real one — so the transport change is invisible to the projection.
                return emit(res.out, read_plan["jq"], read_plan["silent"])
            if plan is not None:
                if res.err:
                    sys.stderr.buffer.write(res.err)
                return emit(res.out, plan["jq"], plan["silent"])
            sys.stdout.buffer.write(res.out)
            sys.stderr.buffer.write(res.err)
            return 0
        if fo is not None:
            # ⛔ NO RETRY ACROSS POOLS. The GraphQL pool WAS the alternative and it refused too, so
            # trying again here is precisely the “retry into the limit” this layer forbids: the next
            # honest event is the reset, not another request. Name the state and leave.
            #
            # ⛔ THE RESET IS TAKEN FROM THE DECISION, NOT RE-READ AFTER THE RECORD IS OVERWRITTEN.
            # `record_limit("graphql", …)` replaces `last-limit` (one record per box, by design), so
            # asking `recorded_reset("core")` afterwards returns None — and a health record written
            # with `reset=0` makes `--health` report `gh-ok` at the exact moment BOTH pools are empty
            # and `repo-authority.sh` goes silent. `core_reset` was captured before any of that.
            limit = classify(res, gh_argv, headers)
            if limit is not None:
                # ⛔ THE CLASSIFICATION DECIDES THE WINDOW HERE TOO (#2137). Passing the remaining
                # count in the old positional slot would have written a GraphQL `kind=` of "remaining=3200",
                # and recording the bucket reset as the window is the full-window block that #2137
                # exists to remove.
                _fo_kind = limit_kind(limit)
                record_limit("graphql", limit.reset, attempt, 0.0, limit.status, _fo_kind,
                             marker_until(_fo_kind, limit.reset, None, clock()), limit.remaining)
            # ⛔ THE BAND IS NOT EXHAUSTION, ON THIS PATH TOO. `core_empty` is false when the pool still
            # had headroom (the read was moved to GraphQL to PRESERVE that headroom): writing
            # `gh-core-exhausted … remaining=0` here made `health_reset()` report pressure, so every
            # WRITE on the box was refused without spending a request until the reset — the round-1
            # finding, reintroduced through the failover-failure branch. What actually failed is the
            # GraphQL transport, so that is what gets named.
            if core_empty:
                phrase = record_core_exhausted(core_reset if core_dated else None, 0)
            else:
                phrase = "gh-graphql-unavailable resets_in=%s" % resets_in(core_reset)
            _named_core_refusal(
                phrase,
                "The GraphQL failover was refused as well, so BOTH pools are empty for this read."
                if limit is not None and core_empty else
                "The GraphQL failover was refused, so this read cannot be served on either transport."
                if limit is not None else
                "The GraphQL failover could not reproduce the REST body, so this read is refused.")
            # ⛔ THE FAILOVER CHILD'S STDOUT IS **NOT** WRITTEN HERE (#2342 review, P2). `run_failover`
            # returns the GraphQL child's `Result` verbatim, and `gh api graphql` prints its ERROR
            # DOCUMENT on stdout (`{"data":null,"errors":[…]}` — the same measured shape this file
            # records for `gh api`). Copying it out broke the contract this change states twice —
            # "every refusal path exits non-zero with EMPTY stdout" — so a caller that reacts to
            # emptiness/`-n` rather than to the exit status (exactly the pattern
            # `record-review.sh::target_head_red` was fixed for) was handed a foreign document instead
            # of "nothing". The "never SUBTRACT what the child printed" rule does not reach these
            # bytes: the caller asked for a REST read the failover substituted, so this is the LAYER's
            # transport, not the child the caller invoked. stderr IS kept — it is the diagnosis.
            if res.err:
                sys.stderr.buffer.write(res.err if res.err.endswith(b"\n") else res.err + b"\n")
            return res.rc or 1
        limit = classify(res, gh_argv, headers)
        if limit is None:
            # Not a limit: replay the child and let the caller decide. No retry, no rewrite, BOTH
            # streams. ⛔ Replaying only stderr was a P1: `gh api` does print its error body on
            # stdout (measured on gh 2.102.0), and — worse — `gh pr checks` prints its WHOLE surface
            # on stdout and signals the verdict with the exit code (0/1/8). Swallowing stdout turned
            # a red or pending PR into an EMPTY surface, which orch-loop reads as NOCHECKS: never
            # green, never fixed, the sweep stalled with no error. A layer may ADD an explanation; it
            # may never SUBTRACT what the child printed (review round 7).
            if res.out:
                sys.stdout.buffer.write(res.out)
            if res.err:
                sys.stderr.buffer.write(res.err)
            return res.rc
        now = clock()
        kind = limit_kind(limit)
        if _speculative_read and attempt >= 1:
            # The ONE speculative conditional GET was made and did not pay off (no 304):
            # refuse by name, do not retry into the pool.
            reset = limit.reset or recorded_reset(limit.bucket)
            # The age names the evidence that was used (see the give-up arm below).
            prior = read_marker() if limit.reset is None else None
            page = marker_age(prior) if prior and prior.get("bucket") == limit.bucket else 0
            record_limit(limit.bucket, reset, attempt, waited, limit.status, kind,
                         record_window(limit, kind, reset, None, now), limit.remaining)
            log_event("GAVE UP (speculative conditional read) bucket=%s status=%s kind=%s attempts=%d remaining=%s marker_age=%ds"
                      % (limit.bucket, limit.status, kind, attempt,
                         "%d" % limit.remaining if limit.remaining is not None else "?", page))
            fail_loudly(limit, attempt, waited, reset, kind, limit.remaining, page)
            if res.out:
                sys.stdout.buffer.write(res.out)
            if res.err:
                sys.stderr.buffer.write(res.err)
            return res.rc
        if attempt >= MAX_ATTEMPTS:
            # ⛔ CHECKED BEFORE `plan_wait`, because that may spend one more `/rate_limit` request
            # (the probe) — and this is the attempt that is about to fail, on a box that is already
            # refusing calls. `limit.reset` is what the refused response itself carried.
            reset = limit.reset or recorded_reset(limit.bucket)
            # ⛔ THE AGE NAMES THE EVIDENCE THAT WAS USED. If this response carried its own reset, the
            # evidence is the refusal in hand (age 0). Only when the reset was BORROWED from an earlier
            # record does that record's age describe this line — and reporting a 40-minute-old marker
            # as the basis of a live refusal is precisely the reading `fail_loudly` must not create.
            prior = read_marker() if limit.reset is None else None
            page = marker_age(prior) if prior and prior.get("bucket") == limit.bucket else 0
            record_limit(limit.bucket, reset, attempt, waited, limit.status, kind,
                         record_window(limit, kind, reset, None, now), limit.remaining)
            log_event("GAVE UP bucket=%s status=%s kind=%s attempts=%d waited=%ds reset=%s remaining=%s marker_age=%ds"
                      % (limit.bucket, limit.status, kind, attempt, int(waited), reset,
                         "%d" % limit.remaining if limit.remaining is not None else "?", page))
            fail_loudly(limit, attempt, waited, reset, kind, limit.remaining, page)
            # The failed attempt's own words still reach the caller, AFTER the announcement that
            # names the bucket and the reset — never instead of it. BOTH streams: the "never
            # subtract what the child printed" rule is unconditional (review round 8).
            if res.out:
                sys.stdout.buffer.write(res.out)
            if res.err:
                sys.stderr.buffer.write(res.err if res.err.endswith(b"\n") else res.err + b"\n")
            return res.rc or 1
        if NO_WAIT:
            # The caller has its own bound and its own deferral (GH_LIMIT_NO_WAIT). Report the limit
            # NOW so its verifier can say RATE-LIMITED: sleeping 60 s here would outlive its timeout
            # and the box would report a stall instead of the limit it actually hit. `plan_wait` is
            # skipped too — it may spend a `/rate_limit` probe, and this caller is not going to wait
            # for the answer anyway.
            reset = limit.reset or recorded_reset(limit.bucket)
            prior = read_marker() if limit.reset is None else None
            page = marker_age(prior) if prior and prior.get("bucket") == limit.bucket else 0
            record_limit(limit.bucket, reset, attempt, waited, limit.status, kind,
                         record_window(limit, kind, reset, None, now), limit.remaining)
            log_event("rate_limited bucket=%s status=%s kind=%s attempt=%d reset=%s remaining=%s — NO_WAIT, returning at once (evidence_age=%ds)"
                      % (limit.bucket, limit.status, kind, attempt, reset,
                         "%d" % limit.remaining if limit.remaining is not None else "?", page))
            fail_loudly(limit, attempt, waited, reset, kind, limit.remaining, page)
            if res.out:
                sys.stdout.buffer.write(res.out)
            if res.err:
                sys.stderr.buffer.write(res.err if res.err.endswith(b"\n") else res.err + b"\n")
            return res.rc or 1
        wait, reset, why, remaining = plan_wait(limit, attempt, real_gh, now, kind)
        # ⛔THE WINDOW IS WRITTEN FROM THE CLASSIFICATION, NOT FROM THE RESET (requirement 2/5). An
        # unclassified/secondary observation blocks its peers for at most the documented floor; only a
        # PRIMARY exhaustion may claim the bucket's reset as its window.
        record_limit(limit.bucket, reset, attempt, waited, limit.status, kind,
                     marker_until(kind, reset, wait, now), remaining)
        if wait > MAX_WAIT:
            log_event("reset beyond the in-call bound bucket=%s wait=%ds reset=%s kind=%s attempt=%d "
                      "remaining=%s evidence_age=0s — failing fast"
                      % (limit.bucket, int(wait), reset, kind, attempt,
                         "%d" % remaining if remaining is not None else "?"))
            # The wait is `reset`-derived here, so the evidence age is this response's own (0).
            fail_loudly(limit, attempt, waited, reset, kind, remaining, 0)
            if res.out:
                sys.stdout.buffer.write(res.out)
            sys.stderr.write("gh-limit: the next wait is %ds away (%s), beyond the %ds in-call bound — "
                             "failing now so the caller's own deferral can take over\n"
                             % (int(wait), why, int(MAX_WAIT)))
            if res.err:
                sys.stderr.buffer.write(res.err if res.err.endswith(b"\n") else res.err + b"\n")
            return res.rc or 1
        log_event("rate_limited bucket=%s status=%s kind=%s attempt=%d/%d reset=%s why=%s remaining=%s evidence_age=0s waiting=%ds"
                  % (limit.bucket, limit.status, kind, attempt, MAX_ATTEMPTS, reset, why,
                     "%d" % remaining if remaining is not None else "?", int(wait)))
        # NOT under the lock: see the docstring. The wait is what the docs demand; the lock is only
        # about overlap.
        pause(wait)
        waited += wait


def run_attempt(real_gh, gh_argv, plan):
    if plan is not None:
        return conditional_fetch(real_gh, plan)
    return run(real_gh, gh_argv), {}


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except BrokenPipeError:
        try:
            sys.stdout.close()
        except Exception:
            pass
        sys.exit(0)
