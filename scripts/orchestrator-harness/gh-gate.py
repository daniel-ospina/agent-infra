#!/usr/bin/env python3
# gh-gate.py — the fleet courtesy gate's LOOP, READ and INSTRUMENT half (agent-infra#1910).
#
# WHY THIS EXISTS. #1988 put ONE paced layer under every gh call (`gh-limit.py`): one call in
# flight per box, retry-after honoured, the failing bucket named. That fixed the CALL. It did not
# fix the two things the fleet still got wrong, and it could not: both are properties of the
# LOOPS, not of a single request.
#
#   1. THE LOOPS ALL ARRIVE AT ONCE. Measured 2026-10-18: 13 concurrent gh clients, 54 pi lanes,
#      4 rail-when-green landers and 2 merge loops, all reading the same endpoint in the same
#      seconds. A per-call lock serialises the requests but not the LANDERS: six loops each grab
#      and release the lock hundreds of times, so none of them makes progress and every one of
#      them is inside GitHub's burst window. The fix is a LEASE held for a whole landing, with a
#      liveness-checked holder (a SIGKILLed lander must not park the box) and staggered starts.
#
#   2. EVERY LANE PAID FOR THE SAME READ. Each lane asked GitHub what the pool/queue looked like,
#      so N lanes cost N API calls for one answer. The refresh pass already performs that read;
#      this file PUBLISHES it and lets the other lanes read the snapshot, with its age attached.
#      ⛔ A STALE SNAPSHOT IS LABELLED STALE. A cached read used as a fresh one is the same
#      false-green this issue is about, one layer down.
#
# AND THE INSTRUMENT. `gh api rate_limit` reporting `4690/5000` while every read is refused is the
# measured trap: `GET /rate_limit` is EXEMPT from the primary limit and does not expose proximity
# to the SECONDARY (concurrency) one. So a counter is never evidence here. `probe` performs a REAL
# read and names the outcome in one of four terms, and the three failures are deliberately
# distinct so a burstiness refusal can never be reported as an empty backlog or a healthy queue:
#
#   OK                 a real read succeeded. The only verdict that says the fleet can read.
#   SECONDARY-LIMITED  refused while the counter still showed headroom (GitHub's "API rate limit
#                      already exceeded for user ID …"). This is BURSTINESS, not spend: the answer
#                      is to pause and serialise, never to close PRs or park work.
#   BUDGET-EXHAUSTED   refused with the bucket genuinely at 0 / GitHub's primary message. This one
#                      waits for the reset.
#   UNREADABLE         it failed for a reason that is NOT a rate limit (auth, network, 5xx). It is
#                      named apart so nobody defers a misconfigured box for an hour.
#
# WHAT THIS IS NOT. It is not a second retry engine: `gh-limit.py` owns per-call pacing and
# backoff, and this file never sleeps on a refusal (the probe runs with `GH_LIMIT_NO_WAIT=1`, so a
# refusal is REPORTED at once instead of consuming the caller's bound). It is also not a
# cross-box coordinator — boxes cannot see each other, so the lease is per box, exactly like
# `gh-limit.py`'s lock, and the snapshot is a local publication for local readers.
#
# USAGE (all state lives in ONE directory, so every loop on a box shares it)
#   gh-gate.py lease acquire --name <who> [--pid <anchor-pid>] [--stagger S] [--wait S]
#        -> "ACQUIRED token=<t> holder=<who> pid=<pid> [BROKE=<old-holder>]"   exit 0
#        -> "BUSY holder=<h> pid=<p> age=<n>s since <iso>"                      exit 75
#        -> "UNREADABLE <why>"                                                   exit 1
#   gh-gate.py lease release --token <t>      -> "RELEASED …" | "NOT-HOLDER …" (exit 1)
#   gh-gate.py lease status                   -> "FREE" | "HELD holder=… pid=… age=…s"
#   gh-gate.py probe [--publish]              -> "GH-PROBE: <VERDICT> …"  (0/10/11/12)
#   gh-gate.py cycle                          -> "FRESH(<state>, <age>)" | "STALE(…)" | "UNKNOWN(…)"
#                                                (one real read, published, then reported with its age)
#   gh-gate.py lander-check --transport <rest|graphql>  -> "DEFER(<state>, <age>)" | "PROCEED(<why>)"
#   gh-gate.py snapshot read [--require-fresh] -> "FRESH(<state>, <age>)" | "STALE(<state>, <age>)
#                                                | "UNKNOWN(<why>)"
#        exit 0 for FRESH; a STALE reading exits 0 (it IS a reading) unless --require-fresh is
#        given, which exits 3; UNKNOWN always exits 3 (absence is never a reading).
#
# OPERATOR KNOBS (range-clamped; a value that cannot be honoured falls back to the documented
# default rather than disabling a bound): GH_GATE_DIR, GH_GATE_LEASE_MAX_S (1800),
# GH_GATE_SNAPSHOT_MAX_S (300), GH_GATE_WAIT_S (120), GH_GATE_STAGGER_S (0 = no pre-wait),
# GH_GATE_PROBE_TIMEOUT_S (45 — bounds the ONE real read, so a black-holed connection still yields
# a verdict inside the controller's pass), GH_GATE_LOCK_TIMEOUT_S (5 — bounds the wait for the
# record lock, so a stopped holder cannot hang `acquire` or the EXIT trap that releases the lease),
# GH_GATE_REAL_GH (the gh entry point the probe reads through — normally the paced layer).

import fcntl
import hashlib
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time

# ── the four verdicts. ONE vocabulary; nothing else may be reported as an answer. ─────────────
OK = "OK"
SECONDARY = "SECONDARY-LIMITED"
BUDGET = "BUDGET-EXHAUSTED"
UNREADABLE = "UNREADABLE"

EXIT_BY_VERDICT = {OK: 0, SECONDARY: 10, BUDGET: 11, UNREADABLE: 12}

# GitHub's own words. The primary and the secondary messages are NOT the same string, and the
# difference is the whole discriminator: measured, `API rate limit already exceeded for user ID
# 81560491` arrived while `graphql` still reported 4690 points of headroom.
SECONDARY_PHRASES = (
    "already exceeded",         # "API rate limit already exceeded for user ID …" (measured)
    "secondary rate limit",
    "secondary-rate-limit",
    "abuse detection",
)
PRIMARY_PHRASE = "rate limit exceeded"      # the primary wording, without "already"
LIMIT_PHRASES = ("rate limit", "rate-limit", "abuse detection", "secondary rate")


# ── configuration ────────────────────────────────────────────────────────────────────────────
def cfg(name, default):
    v = os.environ.get(name)
    return default if v is None or v == "" else v


def cfg_float(name, default):
    try:
        return float(cfg(name, default))
    except (TypeError, ValueError):
        return float(default)


def _num(name, default, lo, hi):
    """A knob with a FLOOR and a CEILING. The floor is the requirement, not a preference: a knob
    that could be set to 0 would switch off the behaviour while still looking clamped. nan/inf
    fall back to the default (an `inf` bound is a hang, a `nan` one a traceback)."""
    try:
        v = float(cfg(name, default))
    except (TypeError, ValueError):
        return float(default)
    if v != v or v in (float("inf"), float("-inf")):
        return float(default)
    return max(float(lo), min(float(hi), v))


def state_dir():
    # ⛔ ONE DIRECTORY PER BOX, deliberately under gh-limit's own dir: the lease and the per-call
    # lock describe the same resource (this box's gh token), so an operator who points
    # GH_LIMIT_DIR somewhere points both, and the two can never end up on different filesystems.
    explicit = cfg("GH_GATE_DIR", "")
    if explicit:
        return explicit
    base = cfg("GH_LIMIT_DIR", os.path.join(
        cfg("XDG_CACHE_HOME", os.path.expanduser("~/.cache")), "gh-limit"))
    return os.path.join(base, "gate")


def _usable(d):
    """A state dir is usable only if it exists, is OURS, and is not group/world writable.

    ⛔ THE OWNERSHIP CHECK IS NOT DECORATION. The degraded fallback lives in a world-writable parent
    (`$TMPDIR`), and this directory holds the LEASE and the published SNAPSHOT — so another uid who
    pre-creates it could hold the box's lander lease or write `state=OK at=<now>` and turn the
    fleet's read verdict into the exact false green #1910 exists to remove. `gh-limit.py` refuses a
    foreign-owned dir for the same reason; this is that rule, one directory over."""
    try:
        st = os.stat(d)
    except OSError:
        return False
    if not os.path.isdir(d) or st.st_uid != os.getuid():
        return False
    return (st.st_mode & 0o022) == 0


def ensure_dir():
    d = state_dir()
    try:
        os.makedirs(d, mode=0o700, exist_ok=True)
        # ⛔ THE PRIMARY DIR IS AN OPERATOR KNOB, SO IT IS NOT TRUSTED BY BEING PRIMARY. It holds
        # the lease and the published snapshot, so a world-writable `GH_GATE_DIR` lets another uid
        # hold the box's lander lease or write `state=OK at=<now>` — the false green this file
        # exists to remove. The same `_usable()` check therefore applies here, and an unusable
        # primary falls through to the guarded fallback below rather than being used anyway.
        if not _usable(d):
            raise OSError("state dir %s is not owned by uid %d or is writable by others"
                          % (d, os.getuid()))
        return d
    except OSError as e:
        # A degraded state dir must not disable the gate: fall back to a per-user temp dir, which
        # still shares ONE lease between this user's processes (the same shape gh-limit documents).
        alt = os.path.join(os.environ.get("TMPDIR") or "/tmp", "gh-gate-%d" % os.getuid())
        try:
            # ⛔ NO SYMLINK, AND NO chmod BEFORE THE OWNERSHIP CHECK. A plain local uid can
            # pre-create `$TMPDIR/gh-gate-<uid>` as a link: makedirs swallows FileExistsError
            # (isdir follows links), chmod would then change the TARGET's mode, and _usable's
            # os.stat would read the TARGET as ours — so the gate would chmod a victim directory
            # and write its lease into it. `lstat` refuses the link outright, and the chmod is
            # applied only to a directory we have already proven is ours.
            if os.path.islink(alt):
                raise OSError("the fallback state dir %s is a SYMLINK — refusing to use it" % alt)
            os.makedirs(alt, mode=0o700, exist_ok=True)
        except OSError as e2:
            # ⛔ NO TRACEBACK FROM A DEGRADED DIR. The caller turns this into `UNKNOWN(...)`/a loud
            # fail-open warning; dying here would make "a degraded dir still serialises" false and
            # would take the EXIT path's release with it.
            sys.stderr.write("gh-gate: no usable state dir (%s; fallback %s: %s)\n" % (d, alt, e2))
            return None
        if not _usable(alt):
            sys.stderr.write("gh-gate: refusing the fallback state dir %s — it is not owned by uid %d "
                             "or is writable by others\n" % (alt, os.getuid()))
            return None
        # Now that it is PROVEN ours and not a link, tightening the mode is safe.
        try:
            os.chmod(alt, 0o700)
        except OSError:
            pass
        log_event(alt, "state dir %s is unusable (%s) — falling back to %s" % (d, e, alt))
        return alt


def log_event(d, msg):
    try:
        with open(os.path.join(d, "events.log"), "a") as f:
            f.write("%s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), msg))
    except OSError:
        pass


# ── lease ────────────────────────────────────────────────────────────────────────────────────
def _proc_start(pid):
    """The holder's process START token, or "". Pid numbers are RECYCLED, so `kill -0` alone
    says "something is running under this number" — not "the lander that took the lease is still
    running". `ps -o lstart=` is the portable read (BSD ps and procps both have it); where it is
    unavailable the pid check is all there is, and that degradation is stated in the docs rather
    than assumed away."""
    try:
        out = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except (OSError, ValueError):
        return ""
    # ⛔ NORMALISED TO ONE FIELD. The lease is one line of space-separated `key=value` pairs, and
    # `ps` pads `lstart` with REPEATED spaces — stored raw, `start=Sun 18 Oct …` split into a
    # `start=Sun` plus five junk keys, and the next reader compared "Sun" against the full token
    # and declared a LIVE holder dead (reproduced: serialisation silently switched itself off).
    return re.sub(r"[\s,]+", "_", out.stdout.decode("utf-8", "replace").strip())


def _alive(pid, start):
    # ⛔ BOUND THE PID. `os.kill` raises OverflowError for a pid outside C long, and this function
    # is what BREAKS a stale lease — so one malformed record (`--pid 99999999999999999999`, or an
    # edited/truncated lease) raised before the record could be broken and wedged the box's gate
    # permanently, with a hand-`rm` as the only remedy. A pid that cannot name a process is simply
    # not a live holder.
    if not isinstance(pid, int) or pid <= 0 or pid > 2 ** 31 - 1:
        return False, "pid %r is not a usable process id" % (pid,)
    try:
        os.kill(pid, 0)
    except OSError as e:
        if getattr(e, "errno", None) == 1:      # EPERM: it exists and is not ours
            pass
        else:
            return False, "pid %d is not running" % pid
    if start:
        now = _proc_start(pid)
        if now and now != start:
            return False, "pid %d was reused (start token %r != %r)" % (pid, now, start)
    return True, ""


def _read_lease(path):
    try:
        with open(path) as f:
            raw = f.read().strip()
    except OSError:
        return None
    if not raw:
        return None
    rec = {}
    for kv in raw.split():
        if "=" in kv:
            k, v = kv.split("=", 1)
            rec[k] = v
    return rec or None


def _write_lease(path, rec):
    line = " ".join("%s=%s" % (k, rec[k]) for k in
                    ("token", "holder", "pid", "start", "host", "at") if rec.get(k) is not None)
    tmp = path + ".tmp.%d" % os.getpid()
    with open(tmp, "w") as f:
        f.write(line + "\n")
    os.replace(tmp, path)


def lease_path(d):
    return os.path.join(d, "lease")


def _flock(fd, timeout):
    """Take an exclusive lock within `timeout`, or report failure. ⛔ UNBOUNDED HERE WAS A STALL:
    the release path runs first in merge-one.sh's EXIT trap, so a stopped/wedged holder would hang
    the trap, and the per-PR claim file — removed by the SAME trap — would survive the worker. That
    is the "unbounded exit path with the local lock already gone" defect #1715 fixed one line below.
    On timeout the caller proceeds UNSERIALISED and says so, the same declared residual as
    gh-limit.py's lock timeout."""
    deadline = time.time() + timeout
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except OSError:
            if time.time() >= deadline:
                return False
            time.sleep(0.05)


def _lease_age(cur):
    """`(age_seconds, readable)` for a lease record — the ONE definition both verbs use.

    ⛔ ONE DEFINITION, BOTH VERBS (#1910 round 6): `_attempt` treated `at=nan` as stale while
    `lease status` printed the SAME record as `HELD … age=0s` — a fresh lease — and crashed outright
    on `at=inf`. `status` is the verb an operator reaches for during a suspected wedge, so it must
    never answer a corrupt record with a comforting number or a traceback.
    ⛔ AND `readable` IS A SEPARATE FACT (#1910 round 9). Folding it into `age > max_hold` told an
    operator investigating a genuine 40-minute holder that the record was CORRUPT, while `acquire`
    was correctly saying "held for 2400s, past the 1800s bound" — the same two-answers-for-one-
    record defect, re-entered from the other side. `readable` is False only when `at` is not a
    number at all (unparseable, NaN, ±inf); an old-but-valid age is readable AND past the bound.
    """
    try:
        age = time.time() - float(cur.get("at", "0"))
    except (TypeError, ValueError):
        return 0.0, False
    if not (age == age) or age in (float("inf"), float("-inf")):
        return 0.0, False
    # ⛔ A FUTURE `at` IS NOT EVIDENCE OF FRESHNESS (#2128 review P3). `cmd_snapshot` already names a
    # stepped-back clock explicitly ("clock stepped back"), because a negative age answers a question
    # about LATER, not about now. The lease verbs were the one place it was read as freshness: the
    # over-age break is False for a negative age, so `acquire` answered BUSY for ever with the
    # self-contradicting `age=-3600s since <now>`, and `status` printed `HELD … age=-3600s`. A
    # record that cannot be read as an age is UNREADABLE — which `_attempt` already turns into a
    # LOUD break — never a live holder.
    if age < 0:
        return 0.0, False
    return age, True


def _attempt(d, name, max_hold, anchor, lock_timeout):
    """ONE acquire attempt under the read-modify-write lock. Returns (rec, broke) on success,
    or (None, busy_message) when a LIVE holder is in the way."""
    lock = os.path.join(d, "lease.lock")
    lf = open(lock, "a+")
    try:
        if not _flock(lf.fileno(), lock_timeout):
            log_event(d, "lease.lock held past %ss — proceeding UNSERIALISED" % lock_timeout)
        path = lease_path(d)
        cur = _read_lease(path)
        broke = ""
        if cur:
            try:
                pid = int(cur.get("pid", ""))
            except (TypeError, ValueError):
                pid = 0
            why = "the record is unparseable"
            alive = False
            if pid > 0:
                alive, why = _alive(pid, cur.get("start", ""))
            # ⛔ `at` WAS THE ONLY FIELD WITH NO VALIDITY GUARD. A non-finite age (`nan`/`inf`) is
            # not a reading: it is treated as past the bound, so the record is BROKEN instead of
            # crashing before the break and parking the box for ever.
            age, age_ok = _lease_age(cur)
            if not age_ok:
                age = max_hold + 1
            if alive and age > max_hold:
                # One slow lander must not hold the box for ever. Same declared residual as
                # gh-limit.py's lock timeout: the bound is stated, and breaking is LOUD.
                alive = False
                why = "held for %ds, past the %ds bound" % (age, max_hold)
            if alive:
                return None, "BUSY holder=%s pid=%d age=%ds since %s" % (
                    cur.get("holder", "?"), pid, int(age),
                    time.strftime("%Y-%m-%dT%H:%M:%SZ",
                                  time.gmtime(time.time() - max(0, age))))
            broke = cur.get("holder", "?")
            log_event(d, "broke stale holder %s (pid=%s): %s" % (
                broke, cur.get("pid", "?"), why))
        rec = {
            "token": hashlib.sha256(os.urandom(16)).hexdigest()[:24],
            "holder": re.sub(r"[^A-Za-z0-9_.:/-]", "_", name)[:64],
            "pid": str(anchor),
            "start": _proc_start(anchor) or "",
            "host": socket.gethostname(),
            "at": str(int(time.time())),
        }
        _write_lease(path, rec)
        return rec, broke
    finally:
        try:
            fcntl.flock(lf.fileno(), fcntl.LOCK_UN)
        finally:
            lf.close()


def cmd_lease_acquire(argv):
    name = ""
    anchor = None
    stagger = _num("GH_GATE_STAGGER_S", 0.0, 0.0, 30.0)
    wait = _num("GH_GATE_WAIT_S", 120.0, 0.0, 3600.0)
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--name" and i + 1 < len(argv):
            name = argv[i + 1]; i += 2
        elif a == "--pid" and i + 1 < len(argv):
            try:
                anchor = int(argv[i + 1])
            except ValueError:
                sys.stderr.write("gh-gate: --pid needs an integer (pid)\n")
                return 2
            i += 2
        elif a == "--stagger" and i + 1 < len(argv):
            try:
                stagger = max(0.0, min(30.0, float(argv[i + 1])))
            except ValueError:
                pass
            i += 2
        elif a == "--wait" and i + 1 < len(argv):
            try:
                wait = max(0.0, min(3600.0, float(argv[i + 1])))
            except ValueError:
                pass
            i += 2
        else:
            sys.stderr.write("gh-gate: unknown lease-acquire argument %r\n" % a)
            return 2
    if not name:
        sys.stderr.write("gh-gate: lease acquire needs --name <who>\n")
        return 2

    d = ensure_dir()
    if d is None:
        sys.stderr.write("gh-gate: no usable state dir — cannot take the lease (fail-open: the caller "
                         "lands UNSERIALISED and logs it)\n")
        return 1
    max_hold = _num("GH_GATE_LEASE_MAX_S", 1800.0, 60.0, 86400.0)
    # ⛔ THE ANCHOR IS THE CALLER'S PROCESS, NOT THIS ONE. The CLI is a one-shot: it exits the
    # instant it has written the lease, so anchoring on itself would make every lease look dead to
    # the very next lander — the exact opposite of serialising. The holder therefore NAMES the
    # process whose lifetime the lease tracks (`--pid $$` in a shell loop); the default is the
    # invoking parent, which is right for a long-lived caller and is documented as WRONG under
    # `$( … )` (bash's command-substitution subshell exits immediately).
    if anchor is None:
        anchor = os.getppid()
    # ⛔ A STAGGERED START, DETERMINISTIC PER NAME. Six loops woken by the same cycle would
    # otherwise collide on the first attempt and on every retry afterwards; a per-name offset
    # spreads them so the second lander is not retrying in lockstep with the first. Derived from
    # the name (not `random`) so a repeated run of the same lane lands in the same slot — a
    # flapping gate is indistinguishable from a busy one.
    if stagger > 0:
        h = int(hashlib.sha256(name.encode("utf-8")).hexdigest()[:8], 16)
        time.sleep((h % 1000) / 1000.0 * stagger)

    lock_timeout = _num("GH_GATE_LOCK_TIMEOUT_S", 5.0, 1.0, 600.0)
    deadline = time.time() + wait
    while True:
        rec, why = _attempt(d, name, max_hold, anchor, lock_timeout)
        if rec is not None:
            sys.stdout.write("ACQUIRED token=%s holder=%s pid=%s%s\n" % (
                rec["token"], rec["holder"], rec["pid"], (" BROKE=" + why) if why else ""))
            return 0
        if time.time() >= deadline:
            sys.stdout.write(why + "\n")
            return 75
        # Jittered retry, so N waiters released by one holder do not all fire on the same tick
        # (the thundering herd this gate exists to stop, one level down).
        time.sleep(0.15 + 0.25 * ((int(time.time() * 1000) + os.getpid()) % 7) / 7.0)


def cmd_lease_release(argv):
    token = ""
    i = 0
    while i < len(argv):
        if argv[i] == "--token" and i + 1 < len(argv):
            token = argv[i + 1]; i += 2
        else:
            sys.stderr.write("gh-gate: unknown lease-release argument %r\n" % argv[i])
            return 2
    d = ensure_dir()
    if d is None:
        sys.stdout.write("NOT-HOLDER no usable state dir (nothing to release)\n")
        return 1
    path = lease_path(d)
    lock = os.path.join(d, "lease.lock")
    lf = open(lock, "a+")
    try:
        # Best-effort by design: this runs on the exit path, so it must NEVER block the trap.
        if not _flock(lf.fileno(), _num("GH_GATE_LOCK_TIMEOUT_S", 5.0, 1.0, 600.0)):
            log_event(d, "release: lease.lock held past the bound — releasing UNSERIALISED")
        cur = _read_lease(path)
        if not cur:
            sys.stdout.write("NOT-HOLDER no lease is held\n")
            return 1
        if cur.get("token") != token:
            sys.stdout.write("NOT-HOLDER holder=%s token does not match\n" % cur.get("holder", "?"))
            return 1
        try:
            os.unlink(path)
        except OSError:
            pass
        sys.stdout.write("RELEASED holder=%s\n" % cur.get("holder", "?"))
        return 0
    finally:
        try:
            fcntl.flock(lf.fileno(), fcntl.LOCK_UN)
        finally:
            lf.close()


def cmd_lease_status(argv):
    d = ensure_dir()
    if d is None:
        sys.stdout.write("UNKNOWN(no usable state dir)\n")
        return 1
    cur = _read_lease(lease_path(d))
    if not cur:
        sys.stdout.write("FREE\n")
        return 0
    # The SAME reading `acquire` uses, so the two verbs can never disagree about one record.
    _max_hold = _num("GH_GATE_LEASE_MAX_S", 1800.0, 60.0, 86400.0)
    age, age_ok = _lease_age(cur)
    try:
        pid = int(cur.get("pid", "0"))
    except (TypeError, ValueError):
        pid = 0
    alive, why = _alive(pid, cur.get("start", "")) if pid else (False, "no pid recorded")
    if not age_ok:
        age_txt = "age unreadable (at=%s)" % cur.get("at", "?")
    elif age > _max_hold:
        # Readable AND over the bound — say both. Calling this "unreadable" sent an operator
        # hunting a corrupt record when the truth was a lander that has held the box too long.
        age_txt = "age=%ds (past the %ds bound)" % (int(age), int(_max_hold))
    else:
        age_txt = "age=%ds" % int(age)
    sys.stdout.write("%s holder=%s pid=%d %s%s\n" % (
        "HELD" if alive else "HELD-STALE", cur.get("holder", "?"), pid, age_txt,
        "" if alive else (" (" + why + ")")))
    return 0


# ── the read: resolve the gh entry point, run ONE real read, classify it ─────────────────────
def resolve_gh():
    """The gh ENTRY POINT the probe reads through. `GH_GATE_REAL_GH` is the operator pin and the
    test seam; otherwise the paced layer ($O/gh-rest, then $O/gh-limit) is preferred, exactly as
    every harness call site prefers it, because a probe that bypasses the layer is an unpaced
    request — and the probe's whole subject is burstiness. PATH is the last resort."""
    pin = cfg("GH_GATE_REAL_GH", "")
    if pin:
        return pin
    o = cfg("O", os.path.expanduser("~/orchestrator"))
    for cand in (os.path.join(o, "gh-rest", "gh"), os.path.join(o, "gh-limit", "gh")):
        if os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    return shutil.which("gh") or "gh"


HEADER_RE = re.compile(r"^([A-Za-z0-9][A-Za-z0-9-]*):[ \t]*(.*?)\r?$")


def _headers(text):
    out = {}
    for line in text.splitlines():
        m = HEADER_RE.match(line)
        if m:
            k = m.group(1).lower()
            if k not in out:            # page 1 wins, like the sweep's rl_header
                out[k] = m.group(2)
    return out


def _body(text):
    """The response BODY from a `--include` capture: everything after the header block's blank
    line. A `--include` refusal puts the body (and GraphQL puts the error) here — and GitHub
    answers a GraphQL rate limit with **HTTP 200 + `errors[type:RATE_LIMIT]`** (measured on this
    account; a cached introspection body can be served for 24 h), so the STATUS cannot be trusted
    either. Returns "" when there is no separable body."""
    for sep in ("\r\n\r\n", "\n\n"):
        i = text.find(sep)
        if i >= 0:
            return text[i + len(sep):]
    return ""


def _graphql_errors(body):
    """The `type`+`message` of each GraphQL `errors` entry, or [] when the body is not that shape.

    ⛔ THE STRUCTURED `type` MUST SURVIVE A PRESENT MESSAGE (#2128 review P2). This read
    `message or type`, so a body whose message was plain English dropped the ONE field that says the
    refusal IS a rate limit regardless of wording: `{"type":"RATE_LIMIT","message":"Too many
    requests."}` matched no phrase arm and fell through to UNREADABLE — the verdict this file's own
    docs say must NOT defer a landing and should send the operator to "the token/network". So on
    exactly the refusal this instrument exists to name, the published snapshot said "not a rate
    limit" and the fleet kept landing while every read was refused.
    """
    try:
        doc = json.loads(body)
    except (TypeError, ValueError):
        return []
    if not isinstance(doc, dict):
        return []
    errs = doc.get("errors")
    if not errs:
        return []
    out = []
    for e in errs if isinstance(errs, list) else [errs]:
        if isinstance(e, dict):
            # BOTH fields, kept apart from each other so neither can shadow the other.
            out.append(" ".join(
                p for p in (str(e.get("type") or "").strip(), str(e.get("message") or "").strip())
                if p))
        else:
            out.append(str(e))
    return [m for m in out if m]


def _as_int(v):
    try:
        return int(str(v).strip())
    except (TypeError, ValueError):
        return None


def _classify(rc, out, err):
    """(verdict, detail, remaining, reset) for ONE response. ⛔ THE PHRASE ARMS ARE GATED ON THE
    STATUS, exactly as `gh-limit.py:931` does and for its measured reason: gh echoes request content
    in some failures (a PR titled "fix rate limit" rejected with 422), so a phrase in the WRONG
    response is not a limit. Without the gate a 502 error page mentioning "rate limit" was published
    as a burst refusal — and `lander_read_blocked` then deferred every landing on the box for a
    reason whose real remedy is "GitHub is down", not "stop arriving together"."""
    hdrs = _headers(out)
    remaining = _as_int(hdrs.get("x-ratelimit-remaining"))
    reset = _as_int(hdrs.get("x-ratelimit-reset"))
    retry_after = _as_int(hdrs.get("retry-after"))
    m = re.search(r"^HTTP/\S+\s+(\d{3})", out, re.M)
    status = int(m.group(1)) if m else None
    text = (err + "\n" + out).lower()
    phrase_ok = status in (None, 403, 429)

    if rc == 0:
        # ⛔ rc == 0 IS NOT EVIDENCE OF A READ. GitHub answers a GraphQL rate limit with HTTP 200
        # and an `errors[]` array (measured on this account; a cached introspection body can be
        # replayed for 24 h), so an exit code alone would publish `state=OK` over a fleet that
        # cannot read. The BODY decides — and when `--include` gives us no separable body we parse
        # the whole response instead, because "I could not find a body" is not "the body was clean"
        # (an entry point that re-renders the response would otherwise silently restore the false
        # green).
        body = _body(out)
        errs = _graphql_errors(body) or _graphql_errors(out)
        if errs:
            joined = " ".join(errs).lower()
            if any(p in joined for p in SECONDARY_PHRASES) or "rate_limit" in joined:
                return SECONDARY, "HTTP 200 but the body is a rate-limit error: %s" % errs[0][:160], remaining, reset
            if PRIMARY_PHRASE in joined:
                return BUDGET, "HTTP 200 but the body is the primary-limit error: %s" % errs[0][:160], remaining, reset
            return UNREADABLE, "HTTP 200 but the GraphQL body carries errors: %s" % errs[0][:160], remaining, reset
        if body.strip() and _jsonish(body) is None and _jsonish(out) is None:
            return UNREADABLE, "rc=0 but the response carries no parseable body", remaining, reset
        return OK, "a real read succeeded", remaining, reset

    # 1) A HARD FACT BEATS A PHRASE. A bucket at 0 is the primary limit whatever the prose says.
    if remaining == 0:
        return BUDGET, "bucket at 0 (x-ratelimit-remaining: 0)", remaining, reset
    # 2) BURSTINESS. GitHub's secondary wording — and, decisively, a refusal that arrived while the
    #    counter still showed headroom, which is the shape measured on 2026-10-18.
    if phrase_ok and any(p in text for p in SECONDARY_PHRASES):
        return SECONDARY, "refused with headroom remaining=%s" % (
            "?" if remaining is None else remaining), remaining, reset
    # 3) A 429, or a `retry-after`, is GitHub's own burst signal even when the body carries no
    #    prose (the secondary limit arrives as 403 OR 429; `retry-after` is the canonical
    #    "do not retry before N" header). Reporting these as UNREADABLE sent an operator to the
    #    token/network during pure burstiness.
    if status == 429:
        return SECONDARY, "HTTP 429 with headroom remaining=%s" % (
            "?" if remaining is None else remaining), remaining, reset
    if retry_after is not None:
        return SECONDARY, "refused with retry-after=%ds and headroom remaining=%s" % (
            retry_after, "?" if remaining is None else remaining), remaining, reset
    # 4) The primary wording, without "already": the hourly budget, not the burst.
    if phrase_ok and PRIMARY_PHRASE in text and "already exceeded" not in text:
        return BUDGET, "the primary limit's wording", remaining, reset
    if phrase_ok and remaining is not None and remaining > 0 and any(p in text for p in LIMIT_PHRASES):
        return SECONDARY, "refused with headroom remaining=%d" % remaining, remaining, reset
    # 5) NOT A LIMIT AT ALL. Named apart on purpose: it must not defer the box, and it must not
    #    read as an empty answer either.
    first = (err.strip().splitlines() or ["(no error output)"])[0]
    return UNREADABLE, "not a rate limit: %s" % first[:200], remaining, reset


def _jsonish(text):
    try:
        return json.loads(text)
    except (TypeError, ValueError):
        return None


def _adapter_present():
    """The SAME test `merge-one.sh` uses to decide which pool its own reads go to: when the gh-rest
    adapter is installed, every `pr`/`issue` read is served over REST; without it, those reads are
    GraphQL. Producer and consumer must agree, or the probe measures a pool nobody reads."""
    return os.path.isdir(os.path.join(cfg("O", os.path.expanduser("~/orchestrator")), "gh-rest"))


def probe():
    """ONE real read attempt on the LANDERS' path, then a verdict.
    Returns (verdict, detail, remaining, reset, path, other_verdict) — `other_verdict` is the other
    pool's verdict when it had to be confirmed, else "". ⛔ SIX values: the error arms below return
    six too, because `cmd_probe` unpacks six (a four-value arm there was a traceback on the two
    paths — a missing gh, a black-holed connection — whose whole purpose is to publish UNREADABLE).

    ⛔ IT NEVER ASKS `rate_limit`. That endpoint is EXEMPT from the primary limit, so it answers on
    a box where every real call is refused — using it as the probe IS the false green (#1762/#1910).
    ⛔ AND IT READS THE POOL THE LANDERS USE FIRST (round 3). The pools are independent: #1959 is
    the measured incident where GraphQL was refused for minutes while REST answered normally. A
    GraphQL-first probe published that refusal as the fleet's state and deferred every REST landing
    on the box, so the primary read is chosen by `_adapter_present()` and a non-OK read is confirmed
    with ONE read on the other pool. A healthy pass still costs exactly one call."""
    gh = resolve_gh()
    # The SAME two shapes, chosen so the FIRST read is on the pool this box's landers use.
    path = "rest" if _adapter_present() else "graphql"
    argv = ([gh, "api", "--include", "user"] if path == "rest"
            else [gh, "api", "--include", "graphql", "-f", "query=query { viewer { login } }"])
    env = dict(os.environ)
    # The probe is an INSTRUMENT with a caller's bound, so it must never sleep through the layer's
    # 60 s+ backoff: a refusal is DATA here, and the answer to a burst is to stop, not to wait
    # inside the probe. The layer still records the limit and still takes the box's call lock.
    env["GH_LIMIT_NO_WAIT"] = "1"
    # ⛔ A BOUNDED PROBE, because it runs at the TOP of every controller cycle. gh-limit.py's
    # NO_WAIT opt-in is documented as being for "a caller with its OWN subprocess timeout" — this
    # is that timeout. Without it a black-holed connection blocks the whole pass instead of
    # returning a verdict.
    probe_timeout = _num("GH_GATE_PROBE_TIMEOUT_S", 45.0, 1.0, 600.0)
    try:
        r = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env,
                           timeout=probe_timeout)
    except subprocess.TimeoutExpired:
        # `path` is already known, so the pool that FAILED is named rather than left `?`: an
        # unattributed UNREADABLE reads as a corrupt snapshot instead of "this pool is broken".
        return (UNREADABLE, "the read did not answer within %ds" % probe_timeout,
                None, None, path, "")
    except OSError as e:
        return UNREADABLE, "could not run %s: %s" % (gh, e), None, None, path, ""
    verdict, detail, remaining, reset = _classify(
        r.returncode, r.stdout.decode("utf-8", "replace"), r.stderr.decode("utf-8", "replace"))

    # ⛔ A REFUSAL ON ONE PATH IS NOT A REFUSAL ON THE PATH THE LANDERS USE (review round 2, P1).
    # This repo's runbook is explicit that REST and GraphQL are SEPARATE pools, and #1959 is the
    # measured incident where GraphQL was refused for minutes while REST answered normally — which
    # is the whole reason the gh-rest adapter exists. Publishing a GraphQL-only refusal as the
    # fleet's state made `lander_read_blocked` defer EVERY landing on a box whose adapter would have
    # served every one of those reads. So a non-OK GraphQL read is confirmed with ONE REST read, and
    # both verdicts are published; the consumer picks the one matching its own transport.
    other_verdict = ""
    if verdict != OK:
        other_argv = ([gh, "api", "--include", "graphql", "-f", "query=query { viewer { login } }"]
                      if path == "rest" else [gh, "api", "--include", "user"])
        try:
            r2 = subprocess.run(other_argv, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, env=env, timeout=probe_timeout)
            rv, _, _, _ = _classify(r2.returncode, r2.stdout.decode("utf-8", "replace"),
                                    r2.stderr.decode("utf-8", "replace"))
            other_verdict = rv
        except (subprocess.TimeoutExpired, OSError):
            other_verdict = UNREADABLE
        detail = "%s (other pool: %s)" % (detail, other_verdict)
    return verdict, detail, remaining, reset, path, other_verdict


def snapshot_path(d):
    return os.path.join(d, "snapshot")


def cmd_probe(argv):
    publish = "--publish" in argv
    for a in argv:
        if a not in ("--publish",):
            sys.stderr.write("gh-gate: unknown probe argument %r\n" % a)
            return 2
    verdict, detail, remaining, reset, path, other_verdict = probe()
    # `state` is always the GraphQL verdict and `rest` always the REST one, whichever was measured
    # first; a pool that was NOT measured this pass is "?" — never a guess, and never the other
    # pool's answer (republishing a GraphQL refusal as the REST verdict is the over-deferral the
    # REST confirmation exists to prevent).
    graphql_v = verdict if path == "graphql" else (other_verdict or "?")
    rest_v = verdict if path == "rest" else (other_verdict or "?")
    d = ensure_dir()
    if d is None and publish:
        # ⛔ THE VERDICT MUST SURVIVE A BROKEN STATE DIR. The one-line cycle record is what an
        # operator reads, so the detail goes to STDERR (never stdout — that would put a newline
        # inside the `key=value` record) and the token folds the verdict in.
        sys.stderr.write("gh-gate: GH-PROBE: %s %s (NOT published — no usable state dir)\n"
                         % (verdict, detail))
        sys.stdout.write("GH-PROBE: %s %s (NOT published — no usable state dir)\n" % (verdict, detail))
        return EXIT_BY_VERDICT[verdict]
    if publish:
        rec = "state=%s rest=%s at=%d remaining=%s bucket=%s detail=%s reset=%s" % (
            graphql_v, rest_v, int(time.time()),
            "?" if remaining is None else remaining, path,
            re.sub(r"\s+", "_", detail)[:120],
            "?" if reset is None else reset)
        tmp = snapshot_path(d) + ".tmp.%d" % os.getpid()
        with open(tmp, "w") as f:
            f.write(rec + "\n")
        os.replace(tmp, snapshot_path(d))
        log_event(d, "probe %s (%s)" % (verdict, detail))
    sys.stdout.write("GH-PROBE: %s %s (path=%s)\n" % (verdict, detail, path))
    return EXIT_BY_VERDICT[verdict]


# ── the shared read: a published snapshot, and its AGE, and never freshness by assumption ────
def cmd_lander_check(argv):
    """THE LANDER'S PREDICATE, in ONE place so it can be tested without driving merge-one.sh.

    `--transport rest|graphql` names the path THIS box's landers actually read on (the gh-rest
    adapter serves REST when it is installed; otherwise gh's `pr`/`issue` reads are GraphQL). The
    pool that is refused decides — a GraphQL-only refusal must never defer a REST landing, which is
    exactly the #1959 state the adapter exists for.

    Prints `DEFER(<state>, <age>, ...)` (exit 0) or `PROCEED(<why>)` (exit 1). STALE and UNKNOWN are
    NEVER a deferral: an old reading is not evidence about now, and a box without the gate must not
    stall.
    """
    transport = "graphql"
    i = 0
    while i < len(argv):
        if argv[i] == "--transport" and i + 1 < len(argv):
            transport = argv[i + 1]
            i += 2
        else:
            sys.stderr.write("gh-gate: unknown lander-check argument %r\n" % argv[i])
            return 2
    if transport not in ("rest", "graphql"):
        sys.stderr.write("gh-gate: --transport must be rest|graphql (got %r)\n" % transport)
        return 2
    d = ensure_dir()
    if d is None:
        sys.stdout.write("PROCEED(no usable state dir — fail-open)\n")
        return 1
    try:
        with open(snapshot_path(d)) as f:
            raw = f.read().strip()
    except OSError:
        sys.stdout.write("PROCEED(no snapshot has been published — fail-open)\n")
        return 1
    kv = {}
    for tok in raw.split():
        if "=" in tok:
            k, v = tok.split("=", 1)
            kv[k] = v
    at = _as_int(kv.get("at"))
    max_age = _num("GH_GATE_SNAPSHOT_MAX_S", 300.0, 1.0, 86400.0)
    # ⛔ `?` IS A LEGAL VALUE, NOT CORRUPTION. The probe measures ONE pool per pass and marks the
    # other `?`; rejecting that declared the whole (perfectly good) snapshot unparseable on the
    # HEALTHY path of every adapter box, so the cycle line read
    # `ghs=UNKNOWN(snapshot is unparseable: 'state=? rest=OK …')` on a box that could read fine.
    # Only a value that is neither a verdict nor `?` is a real parse failure.
    _legal = (OK, SECONDARY, BUDGET, UNREADABLE, "?")
    if at is None or kv.get("state") not in _legal or kv.get("rest") not in _legal:
        sys.stdout.write("PROCEED(the snapshot is unparseable — fail-open)\n")
        return 1
    age = int(time.time()) - at
    if age < 0 or age > max_age:
        sys.stdout.write("PROCEED(the snapshot is STALE at %s — an old reading is not evidence about now)\n"
                         % _age_phrase(abs(age)))
        return 1
    # The transport decides WHICH reading is about the lander's path.
    verdict = kv.get("rest") if transport == "rest" else kv.get("state")
    if verdict in (None, "?", ""):
        # ⛔ UNMEASURED IS NOT HEALTHY, BUT IT CANNOT DEFER EITHER. The probe measures ONE pool per
        # pass (the landers' own path) and only confirms the other when the first is refused, so
        # `?` here means "this pass did not ask" — printed, so an operator can see the gap.
        sys.stdout.write("PROCEED(the %s pool was UNMEASURED this pass — fail-open, path=%s)\n"
                         % (transport, transport))
        return 1
    if verdict in (SECONDARY, BUDGET):
        sys.stdout.write("DEFER(%s, %s, path=%s)\n" % (verdict, _age_phrase(age), transport))
        return 0
    sys.stdout.write("PROCEED(%s on %s, %s)\n" % (verdict, transport, _age_phrase(age)))
    return 1


def cmd_cycle(argv):
    """The CONTROLLER's per-pass instrument: one real read, published, then reported as a token.

    ONE call per pass, and its age, so a cycle line can say `ghs=FRESH(SECONDARY-LIMITED, 40s)`
    where it used to print a healthy `gh_gql=4690/5000` over a fleet that could not read. The
    probe is EXEMPT-free (it is a real read) and non-sleeping (GH_LIMIT_NO_WAIT), so a burst
    costs this pass one call and one honest word instead of a queue reported as empty.
    """
    for a in argv:
        sys.stderr.write("gh-gate: unknown cycle argument %r\n" % a)
        return 2
    # ⛔ ONE LINE, because the caller interpolates this into a `key=value` cycle record. Emitting
    # `GH-PROBE: …` as well put a newline INSIDE the line, detached the `===` frame and left
    # `ghs=` holding prose instead of the documented `FRESH(<state>, <age>)` token. The verdict's
    # detail is already recorded in events.log by the probe.
    import io
    import contextlib
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        cmd_probe(["--publish"])
    return cmd_snapshot([])


def _age_phrase(secs):
    if secs < 0:
        return "0s"
    if secs < 90:
        return "%ds" % secs
    if secs < 5400:
        return "%dm" % (secs // 60)
    return "%dh" % (secs // 3600)


def cmd_snapshot(argv):
    require_fresh = "--require-fresh" in argv
    for a in argv:
        if a not in ("--require-fresh",):
            sys.stderr.write("gh-gate: unknown snapshot argument %r\n" % a)
            return 2
    d = ensure_dir()
    if d is None:
        sys.stdout.write("UNKNOWN(no usable state dir)\n")
        return 3
    max_age = _num("GH_GATE_SNAPSHOT_MAX_S", 300.0, 1.0, 86400.0)
    try:
        with open(snapshot_path(d)) as f:
            raw = f.read().strip()
    except OSError:
        raw = ""
    if not raw:
        # ⛔ ABSENCE IS NOT FRESHNESS. No publication means nobody has measured: that is UNKNOWN,
        # never an empty backlog and never a green line.
        sys.stdout.write("UNKNOWN(no snapshot has ever been published)\n")
        return 3
    kv = {}
    for tok in raw.split():
        if "=" in tok:
            k, v = tok.split("=", 1)
            kv[k] = v
    state = kv.get("state", "")
    at = _as_int(kv.get("at"))
    # `?` = "this pass did not measure that pool" (see PROBE_POOLS in `probe`), so it is a legal
    # VALUE — declaring the snapshot corrupt for it lost the instrument on the healthy path.
    _legal = (OK, SECONDARY, BUDGET, UNREADABLE, "?")
    if state not in _legal or kv.get("rest", "?") not in _legal or at is None:
        sys.stdout.write("UNKNOWN(snapshot is unparseable: %r)\n" % raw[:120])
        return 3
    age = int(time.time()) - at
    if age < 0:
        # A clock that stepped backwards is not evidence about now — report the state with no
        # invented freshness and let it age out again.
        sys.stdout.write("STALE(%s, clock stepped back %dm)\n" % (state, (-age) // 60))
        return 3
    detail = ""
    if kv.get("remaining", "?") not in ("?", ""):
        detail = ", remaining=%s" % kv["remaining"]
    if kv.get("rest") not in (None, "?", ""):
        detail += ", rest=%s" % kv["rest"]
    if age > max_age:
        # A stale reading is still a READING — printed, and refused only where the caller says it
        # cannot use one. `--require-fresh` is what performs that refusal; without it a caller that
        # wants "what did we last see?" gets the state and its age.
        sys.stdout.write("STALE(%s, %s%s)\n" % (state, _age_phrase(age), detail))
        return 3 if require_fresh else 0
    sys.stdout.write("FRESH(%s, %s%s)\n" % (state, _age_phrase(age), detail))
    return 0


USAGE = """gh-gate.py — the fleet courtesy gate (#1910)
  gh-gate.py lease acquire --name <who> [--pid <anchor-pid>] [--stagger S] [--wait S]
  gh-gate.py lease release --token <t>
  gh-gate.py lease status
  gh-gate.py probe [--publish]
  gh-gate.py cycle            # one real read, published, reported as FRESH(...)/STALE(...)
  gh-gate.py lander-check [--transport rest|graphql]   # DEFER(<state>, <age>) | PROCEED(<why>)
  gh-gate.py snapshot read [--require-fresh]
"""


def main(argv):
    if not argv:
        sys.stderr.write(USAGE)
        return 2
    cmd, rest = argv[0], argv[1:]
    if cmd == "lease":
        if not rest:
            sys.stderr.write(USAGE)
            return 2
        sub, sub_rest = rest[0], rest[1:]
        if sub == "acquire":
            return cmd_lease_acquire(sub_rest)
        if sub == "release":
            return cmd_lease_release(sub_rest)
        if sub == "status":
            return cmd_lease_status(sub_rest)
        sys.stderr.write("gh-gate: unknown lease subcommand %r\n" % sub)
        return 2
    if cmd == "probe":
        return cmd_probe(rest)
    if cmd == "cycle":
        return cmd_cycle(rest)
    if cmd in ("lander-check", "lander_check"):
        return cmd_lander_check(rest)
    if cmd == "snapshot":
        return cmd_snapshot(rest[1:] if rest and rest[0] == "read" else rest)
    if cmd in ("-h", "--help", "help"):
        sys.stdout.write(USAGE)
        return 0
    sys.stderr.write(USAGE)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
