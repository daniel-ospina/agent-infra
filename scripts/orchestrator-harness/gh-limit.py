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
#
# WHAT THIS IS NOT. It is not a retry that hides the problem. A limited call RECORDS itself — in
# `$GH_LIMIT_DIR/last-limit` (read by the controller's heartbeat) and in `events.log` — and a final
# failure says so on stderr in the API's own terms. A cycle that was limited never looks like a
# cycle that was idle.
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


def record_limit(bucket, reset, attempts, waited, status):
    """The durable record the controller's heartbeat reads (`gh=<bucket> reset=<epoch>`)."""
    write_state("last-limit",
                "at=%d bucket=%s reset=%s attempts=%d waited=%d status=%s"
                % (int(clock()), bucket, ("%d" % reset) if reset else "0", attempts, int(waited),
                   status if status is not None else "?"))


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
def acquire_lock():
    """One gh call in flight per box. Returns the fd to hold (or None when re-entrant/unavailable).

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
    budget = min(LOCK_TIMEOUT, NO_WAIT_LOCK_S) if NO_WAIT else LOCK_TIMEOUT
    deadline = time.monotonic() + budget      # real monotonic: the fake clock is for BACKOFF
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except OSError as exc:
            if exc.errno not in (errno.EWOULDBLOCK, errno.EAGAIN, errno.EACCES):
                # "the lock is held" is the ONLY reason to wait. Anything else (EOPNOTSUPP/ENOLCK on a
                # filesystem without flock — SMB/CIFS, some FUSE mounts) would spin here for the full
                # LOCK_TIMEOUT on EVERY gh call and then proceed unserialised anyway: a 10-minute
                # stall on the box that looks like a slow network.
                log_event("WARNING gh.lock unusable (%s) — proceeding UNSERIALISED" % exc)
                break
            if time.monotonic() >= deadline:
                # Bounded, and announced in the evidence log rather than blocking for ever: an
                # unbounded wait behind one slow gh call would park the whole box's merge sweep.
                log_event("WARNING gh.lock not acquired within %ds — proceeding UNSERIALISED" % int(budget))
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
}
METHOD_FLAGS = ("-X", "--method")
DATA_FLAGS = ("-f", "--raw-field", "-F", "--field", "--input")


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
        elif a in DATA_FLAGS or any(a.startswith(f + "=") for f in DATA_FLAGS if f.startswith("--")):
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


def run(real_gh, argv, extra=None):
    cmd = [real_gh] + list(argv) + list(extra or [])
    env = dict(os.environ)
    env[REENTRANCY_ENV] = "1"       # a gh child that re-enters this helper must not deadlock on our lock
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    return Result(p.returncode, p.stdout, p.stderr)


# ── conditional REST (the polling half) ────────────────────────────────────────────────────────
# ONLY a plain GET `gh api <path>` is modelled. Every shape whose output this file would have to
# re-create by hand — `--paginate`, `--template`, `-H`, `-f`, a non-GET method — is left COMPLETELY
# alone: adding a conditional header to a call whose response we cannot reproduce is not a slow
# answer, it is a wrong one (the rule the REST adapter beside this file states for flags).
def conditional_plan(argv):
    if not argv or argv[0] != "api":
        return None
    if os.environ.get("GH_LIMIT_CONDITIONAL", "1") == "0":
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
    invocation on a path that also handles `gh auth token`."""
    return bool(cfg(PASS_CACHE_ENV, ""))


def pass_cache_dir():
    """The pass's memo directory, or None when the feature is off. `mkdir -p` on demand so a caller
    that only exports the name still gets a working cache; ANY inability to use it is returned as
    None (a broken cache must never break the call)."""
    d = cfg(PASS_CACHE_ENV, "")
    if not d:
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
        rest = [a for a in gh_argv[1:] if not a.startswith("-")]
        if rest and rest[0].split("?")[0] in ("rate_limit", "rate_limit/"):
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
    parts = [host, _cred_digest(), cwd] + list(gh_argv)
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


def dispatch(real_gh, gh_argv):
    """The public entry: pass-scoped memoisation (when enabled) ABOVE the real dispatch."""
    if pass_cache_eligible(gh_argv):
        hit = pass_cache_get(gh_argv)
        if hit is not None:
            out, err, rc = hit
            if out:
                sys.stdout.buffer.write(out)
            if err:
                sys.stderr.buffer.write(err)
            log_event("pass-cache: hit for `gh %s` — served from this pass's memo, no request"
                      % " ".join(gh_argv)[:180])
            return rc
        cap_out, cap_err = _StreamCapture(), _StreamCapture()
        saved = (sys.stdout, sys.stderr)
        sys.stdout, sys.stderr = cap_out, cap_err
        try:
            rc = _dispatch(real_gh, gh_argv)
        finally:
            sys.stdout, sys.stderr = saved
            out, err = cap_out.getvalue(), cap_err.getvalue()
        # ⛔ THE CALLER'S BYTES ARE WRITTEN WHATEVER HAPPENS — a memoisation that swallowed one
        # stream on an unusual exit path would be a layer that SUBTRACTS from the child, which this
        # file forbids in every other branch. `finally` is what guarantees it even on an exception.
        if out:
            saved[0].buffer.write(out)
        if err:
            saved[1].buffer.write(err)
        pass_cache_put(gh_argv, out, err, rc)
        return rc
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
REST_SUBCOMMANDS = {"run", "workflow", "release", "label", "cache", "secret", "variable"}


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
        sub = next((a for a in argv[1:] if not a.startswith("-")), "")
        if sub.strip("/").lower() == "rate_limit":
            return False
    return not any(a in NO_REQUEST_ANY for a in argv)


def bucket_for(argv):
    if not argv:
        return "graphql"
    if argv[0] == "api":
        # `gh api graphql …` reaches the GRAPHQL pool through the REST-shaped command. ⛔ Match the
        # SUBCOMMAND, not any occurrence: `gh api repos/o/graphql-tools/pulls` is a REST call, and
        # naming the healthy graphql pool there points an operator at the wrong bucket.
        sub = next((a for a in argv[1:] if not a.startswith("-")), "")
        return "graphql" if sub.lower() == "graphql" else "core"
    return "core" if argv[0] in REST_SUBCOMMANDS else "graphql"


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
    lock = acquire_lock()
    try:
        r = run(real_gh, ["api", "rate_limit"])
    finally:
        release_lock(lock)
    try:
        if r.rc != 0:
            return None, None
        d = json.loads(r.out.decode("utf-8", "replace"))
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


def plan_wait(limit, attempt, real_gh, now):
    """The documented order, and nothing invented: retry-after, then the bucket's reset when the
    bucket is empty, then >= BASE_WAIT doubling. Returns (seconds, reset_epoch, why)."""
    if limit.retry_after is not None and limit.retry_after >= 0:
        # ⛔ A `retry-after: 0` IS NOT PERMISSION TO RETRY AT ONCE. Taken verbatim it produced four
        # back-to-back requests with zero seconds waited — the burst secondary limits react to, and
        # the opposite of the floor the docs state. One second is the smallest honest gap; the
        # attempt cap still bounds the total.
        if limit.retry_after < 1:
            log_event("retry-after=%ds is below the 1s floor — waiting 1s" % limit.retry_after)
            return 1.0, limit.reset, "retry-after-floor"
        return float(limit.retry_after), limit.reset, "retry-after"
    remaining, reset = limit.remaining, limit.reset
    if remaining is None or reset is None:
        # No usable header: ask the exempt endpoint for THIS bucket's reset (the refused call did
        # not carry one). A bucket that reports headroom anyway is exactly the lying-GraphQL case,
        # so its number never suppresses the backoff — it can only extend it.
        p_remaining, p_reset = probe_rate_limit(real_gh, limit.bucket)
        remaining = p_remaining if remaining is None else remaining
        reset = p_reset if reset is None else reset
    if remaining == 0 and reset and reset > now:
        return float(reset - now) + 1.0, reset, "reset"
    # Exponential, JITTERED UPWARDS only, so the floor the docs state (>= 1 minute) is never
    # breached by jitter: 60, 120, 240 …
    base = BASE_WAIT * (2 ** (attempt - 1))
    return base * (1.0 + random.random() * 0.2), reset, "backoff"


def fail_loudly(limit, attempts, waited, reset):
    # ⛔ THE WORDS MATTER: the harness's own classifiers look for "rate limit" (objective.py's
    # TRANSPORT_MARKERS) to turn a refused read into `VERDICT=GH-RATE-LIMITED` instead of
    # `UNKNOWN`/`STALL`. "rate_limited" does not contain it, so the token would be lost at exactly the
    # boundary this layer exists to make honest.
    sys.stderr.write(
        "gh-limit: gh rate limit (bucket=%s reset=%s) — FAILED after %d attempt(s), %ds waited. "
        "This is a REFUSED call, not an empty answer%s\n"
        % (limit.bucket, reset if reset else "?", attempts, int(waited),
           (" (%s)" % limit.message) if limit.message else ""))


def main(argv):
    real_gh = None
    self_path = None
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
        else:
            sys.stderr.write("gh-limit: unknown argument %r (expected --real-gh|--self <path> -- <argv>)\n" % a)
            return 2
    gh_argv = list(argv[i:])
    if real_gh is None:
        # The explicit argument outranks the env pin (`gh-rest/gh` resolves the real gh itself, with
        # a documented self-skip); the pin exists for a caller that already knows, and `--self` is
        # last because it has to walk PATH.
        real_gh = os.environ.get("GH_LIMIT_REAL_GH") or resolve_real_gh(self_path)
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


def _dispatch(real_gh, gh_argv):
    """Run, back off, retry — holding the single-flight lock for each ATTEMPT and NOT for the wait.

    ⛔ THE LOCK IS RELEASED DURING A WAIT, deliberately. The invariant is "one gh request in flight
    per box", not "one caller in the queue": holding it through a 60/120/240 s backoff would park
    every other gh call on the box behind a box that is simply waiting — including the merge that is
    the reason the harness runs. Releasing it during the wait keeps the invariant exactly (no two
    requests overlap) while letting an independent call proceed (it will be refused and back off on
    its own if the bucket is still empty, which is the honest behaviour)."""
    plan = conditional_plan(gh_argv)
    attempt = 0
    waited = 0.0
    mutating = is_mutating(gh_argv)
    if mutating:
        # The bulk of the mutation gap is waited OUTSIDE the lock (a 1 s pause under the box lock
        # would park every unrelated gh call); the remainder is re-checked inside it, immediately
        # before the request leaves — see pace_mutation.
        w = pace_mutation()
        if w > 0:
            log_event("pacing mutation: waiting %.2fs (>= %.1fs between mutative calls)" % (w, MUTATION_GAP))
            pause(w)
    while True:
        attempt += 1
        lock = acquire_lock()
        try:
            if mutating:
                w = pace_mutation()
                if w > 0:
                    pause(w)
                mark_mutation()
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
            if makes_request(gh_argv):
                record_recovery(bucket_for(gh_argv))
            if plan is not None:
                if res.err:
                    sys.stderr.buffer.write(res.err)
                return emit(res.out, plan["jq"], plan["silent"])
            sys.stdout.buffer.write(res.out)
            sys.stderr.buffer.write(res.err)
            return 0
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
        if attempt >= MAX_ATTEMPTS:
            # ⛔ CHECKED BEFORE `plan_wait`, because that may spend one more `/rate_limit` request
            # (the probe) — and this is the attempt that is about to fail, on a box that is already
            # refusing calls. `limit.reset` is what the refused response itself carried.
            reset = limit.reset or recorded_reset(limit.bucket)
            record_limit(limit.bucket, reset, attempt, waited, limit.status)
            log_event("GAVE UP bucket=%s status=%s attempts=%d waited=%ds reset=%s"
                      % (limit.bucket, limit.status, attempt, int(waited), reset))
            fail_loudly(limit, attempt, waited, reset)
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
            record_limit(limit.bucket, reset, attempt, waited, limit.status)
            log_event("rate_limited bucket=%s status=%s attempt=%d reset=%s — NO_WAIT, returning at once"
                      % (limit.bucket, limit.status, attempt, reset))
            fail_loudly(limit, attempt, waited, reset)
            if res.out:
                sys.stdout.buffer.write(res.out)
            if res.err:
                sys.stderr.buffer.write(res.err if res.err.endswith(b"\n") else res.err + b"\n")
            return res.rc or 1
        wait, reset, why = plan_wait(limit, attempt, real_gh, now)
        record_limit(limit.bucket, reset, attempt, waited, limit.status)
        if wait > MAX_WAIT:
            log_event("reset beyond the in-call bound bucket=%s wait=%ds reset=%s — failing fast"
                      % (limit.bucket, int(wait), reset))
            fail_loudly(limit, attempt, waited, reset)
            if res.out:
                sys.stdout.buffer.write(res.out)
            sys.stderr.write("gh-limit: the next wait is %ds away (%s), beyond the %ds in-call bound — "
                             "failing now so the caller's own deferral can take over\n"
                             % (int(wait), why, int(MAX_WAIT)))
            if res.err:
                sys.stderr.buffer.write(res.err if res.err.endswith(b"\n") else res.err + b"\n")
            return res.rc or 1
        log_event("rate_limited bucket=%s status=%s attempt=%d/%d reset=%s why=%s waiting=%ds"
                  % (limit.bucket, limit.status, attempt, MAX_ATTEMPTS, reset, why, int(wait)))
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
