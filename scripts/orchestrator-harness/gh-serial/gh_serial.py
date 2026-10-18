#!/usr/bin/env python3
"""gh_serial.py — the one place the harness serialises `gh` and backs off a GitHub rate limit.

WHY THIS EXISTS (agent-infra#1988). Measured on this fleet 2026-10-18:

    gh api rate_limit -> core remaining=2948/5000, graphql remaining=4605/5000
    EVERY GraphQL call -> "API rate limit already exceeded for user ID 81560491"
    heartbeat          -> gh=RATE-LIMITED(queue) queue=UNREADABLE

Quota remaining high + calls refused is GitHub's SECONDARY (concurrency) limit, not the primary
quota. GitHub's documented remedy has two halves and BOTH were missing from the harness:

  * SERIALISE. Secondary limits are triggered by CONCURRENCY, so a queue — not a longer sleep — is
    the fix. One `gh` invocation in flight per box (an flock), which turns four boxes × N lanes into
    four concurrent callers on the shared account instead of 4 × lanes.
  * BACK OFF ONCE LIMITED, exactly as documented: honour `retry-after`; honour
    `x-ratelimit-reset` when `x-ratelimit-remaining` is 0; otherwise wait **at least 60 s**, then
    double with jitter, bounded, and then FAIL LOUDLY. Continuing to hammer while limited "may
    result in the banning of your integration".

WHY IT IS AN EXPLICIT CALL PATH, NOT A PATH SHIM. Measured 2026-10-17 (#1981): a `gh` adapter that
cannot answer a question must DELEGATE, never answer anyway — returning null for a GraphQL-only field
disabled dispatch entirely. A layer that silently substitutes `gh` is therefore the wrong shape: it
moves the decision of whether a call is served into something the call site cannot see. So this is a
named command the scripts invoke — `ghs_run -- gh …` — and every call site that uses it is greppable.
(#1959's adapter survives on its own rule: it delegates anything it does not model, and it is a
deployment concern, not a per-call decision.)

THE FAILURE THAT MADE THE FLEET LOOK IDLE (the reason `fail_loudly` exists). A refused call that is
reported as empty data is indistinguishable from "the queue is empty": the fleet reads as idle
rather than blind. So an exhausted retry budget prints a NAMED error on stderr, writes
`$GHS_STATE_DIR/last-limit`, and exits 75 (EX_TEMPFAIL) — never 0, never an empty body.

MODES
  run [--mutative] -- <gh args…>       serialise + retry + pace mutative calls; stdout/stderr are the
                                       gh call's own, byte for byte, on success or on a non-limit error.
  rest [--jq EXPR] [--method M] <path> conditional REST GET. Sends `if-none-match`, and a 304
                                       replays the cached body BYTE-EXACTLY (a 304 costs no primary
                                       quota; GraphQL has no ETag, which is why polling must be REST).
  state                                the recorded limit (bucket/reset) WITH ITS AGE — the durable
                                       artifact, self-ageing so a past limit cannot read as current.
  version                              print the helper version (deployment drift checks).

KNobs (all env): GHS_MAX_ATTEMPTS=4, GHS_BASE_WAIT=60, GHS_MAX_WAIT=300, GHS_MUTATIVE_SPACING=1,
GHS_LOCK_TIMEOUT=300, GHS_CALL_TIMEOUT=120, GHS_JITTER=0.2, GHS_STATE_DIR, GHS_GH (the real gh
binary; tests pin it), GHS_ETAG_MAX_AGE=3600, GHS_SLEEP_CMD (TEST ONLY — replaces the sleep with a
recorder so the backoff SCHEDULE can be asserted without waiting 420 s; production never sets it).
"""

import errno
import fcntl
import hashlib
import json
import os
import random
import re
import shutil
import subprocess
import sys
import time

VERSION = "1.0.0"
EXIT_RATE_LIMITED = 75          # EX_TEMPFAIL: a distinguishable, retryable-by-the-caller failure
EXIT_USAGE = 64
EXIT_NO_GH = 127
EXIT_CALL_TIMEOUT = 124        # the CHILD gh hung; a transport failure, never a rate limit

# Subcommand groups whose porcelain goes over GraphQL. Used ONLY to NAME the bucket when the response
# carries no `x-ratelimit-resource`; never to decide whether a call is limited.
GRAPHQL_GROUPS = {
    "pr", "issue", "run", "search", "repo", "workflow", "label", "release", "secret", "variable",
    "gist", "cache", "ruleset", "project",
}
# Phrases GitHub uses when it refuses on a rate limit. A bare 403 is deliberately NOT here: a
# permission/scope failure also arrives as 403 and carries no rate-limit header (#1762 review).
LIMIT_PHRASES = (
    "api rate limit already exceeded",     # the SECONDARY limit — the shape measured on this fleet
    "secondary rate limit",
    "rate limit exceeded",
    "abuse detection",
    "rate_limit_exceeded",
    "too many requests",
    "http 429",
    "http 403: rate limit",
)


def _env(name, default, cast):
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    try:
        return cast(raw)
    except (TypeError, ValueError):
        sys.stderr.write("gh-serial: ignoring invalid %s=%r (using %r)\n" % (name, raw, default))
        return default


def max_attempts():
    n = _env("GHS_MAX_ATTEMPTS", 4, int)
    return n if n >= 1 else 1


def base_wait():
    v = _env("GHS_BASE_WAIT", 60.0, float)
    return v if v > 0 else 60.0


def max_wait():
    v = _env("GHS_MAX_WAIT", 300.0, float)
    return v if v > 0 else 300.0


def spacing():
    return max(0.0, _env("GHS_MUTATIVE_SPACING", 1.0, float))


def lock_timeout():
    v = _env("GHS_LOCK_TIMEOUT", 300.0, float)
    return v if v > 0 else 300.0


def call_timeout():
    """Bound the CHILD, not just the lock.

    Without this, a gh that never returns (the TLS black hole this harness has measured) holds the
    box-wide single-flight lock FOREVER, and every other wrapped call on the machine burns its full
    GHS_LOCK_TIMEOUT and fails — one stuck socket making the whole box gh-blind. A timeout here is
    a TRANSPORT failure (exit 124, unambiguous), never a rate limit, so it is not retried.
    """
    v = _env("GHS_CALL_TIMEOUT", 120.0, float)
    return v if v > 0 else 120.0


def jitter_frac():
    v = _env("GHS_JITTER", 0.2, float)
    return min(max(v, 0.0), 0.9)


def state_dir():
    d = os.environ.get("GHS_STATE_DIR")
    if not d:
        cache = os.environ.get("XDG_CACHE_HOME") or os.path.join(
            os.environ.get("HOME") or os.path.expanduser("~"), ".cache")
        d = os.path.join(cache, "pi-gh-serial")
    os.makedirs(d, mode=0o700, exist_ok=True)
    return d


def real_gh():
    pinned = os.environ.get("GHS_GH")
    if pinned:
        if os.path.isfile(pinned) and os.access(pinned, os.X_OK):
            return pinned
        sys.stderr.write("gh-serial: GHS_GH=%r is not an executable file\n" % pinned)
        raise SystemExit(EXIT_NO_GH)
    found = shutil.which("gh")
    if not found:
        sys.stderr.write("gh-serial: no `gh` on PATH (set GHS_GH to the real binary)\n")
        raise SystemExit(EXIT_NO_GH)
    return found


# ── single flight ────────────────────────────────────────────────────────────────────────────────
class LockTimeout(Exception):
    pass


class SingleFlight:
    """One gh invocation at a time PER MACHINE (an flock on a per-box lock file).

    Held across the request and released during the backoff wait: a waiter that kept the lock while
    sleeping 60 s would serialise the SLEEP too, and every lane behind it would wait the sum of the
    waits instead of the remaining one.
    """

    def __init__(self, path, timeout):
        self.path = path
        self.timeout = timeout
        self.fd = None

    def __enter__(self):
        self.fd = os.open(self.path, os.O_RDWR | os.O_CREAT, 0o600)
        deadline = time.time() + self.timeout
        while True:
            try:
                fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return self
            except OSError as exc:
                if exc.errno not in (errno.EACCES, errno.EAGAIN):
                    os.close(self.fd)
                    self.fd = None
                    raise
                if time.time() >= deadline:
                    os.close(self.fd)
                    self.fd = None
                    raise LockTimeout(
                        "waited %ss for the single-flight gh lock (%s)" % (self.timeout, self.path))
                time.sleep(0.02)

    def __exit__(self, *exc):
        if self.fd is not None:
            try:
                fcntl.flock(self.fd, fcntl.LOCK_UN)
            finally:
                os.close(self.fd)
                self.fd = None
        return False


def _read_float(path):
    try:
        with open(path, "r") as fh:
            return float(fh.read().strip())
    except (OSError, ValueError):
        return 0.0


def _write_atomic(path, data):
    tmp = "%s.%d.tmp" % (path, os.getpid())
    mode = "wb" if isinstance(data, bytes) else "w"
    with open(tmp, mode) as fh:
        fh.write(data)
    os.replace(tmp, path)


def pace_mutative(sd):
    """≥ 1 s between MUTATIVE calls (GitHub's stated guidance). Called with the lock held."""
    gap = spacing()
    if gap <= 0:
        return
    last = _read_float(os.path.join(sd, "last-mutative"))
    if last <= 0:
        return
    remaining = gap - (time.time() - last)
    if remaining > 0:
        time.sleep(min(remaining, gap))


def record_mutative(sd):
    try:
        _write_atomic(os.path.join(sd, "last-mutative"), "%.6f" % time.time())
    except OSError:
        pass


# ── response inspection ─────────────────────────────────────────────────────────────────────────
HEADER_STATUS = re.compile(rb"^HTTP/[0-9.]+\s+([0-9]{3})")


def split_headers(body):
    """Split a raw `gh api -i` response into (headers dict, status, body bytes).

    gh prints the status line first, then headers, then a blank line, then the payload — and with
    `--paginate` it repeats that block per page, so only the FIRST block is used (it is the one our
    conditional header was sent on).
    """
    for sep in (b"\r\n\r\n", b"\n\n"):
        idx = body.find(sep)
        if idx != -1:
            head, rest = body[:idx], body[idx + len(sep):]
            break
    else:
        return {}, None, body
    if not HEADER_STATUS.match(head):
        return {}, None, body
    status = int(HEADER_STATUS.match(head).group(1))
    hdrs = {}
    for line in head.replace(b"\r\n", b"\n").split(b"\n")[1:]:
        if b":" not in line:
            continue
        name, _, value = line.partition(b":")
        key = name.strip().decode("latin-1").lower()
        if key and key not in hdrs:
            hdrs[key] = value.strip().decode("latin-1")
    return hdrs, status, rest


def limit_info(hdrs, stdout, stderr, argv):
    """Named facts about a refusal: the bucket, `retry-after`, and the bucket's own reset epoch."""
    info = {}
    if hdrs.get("retry-after"):
        try:
            info["retry_after"] = max(0.0, float(hdrs["retry-after"]))
        except ValueError:
            pass
    if hdrs.get("x-ratelimit-remaining", "").strip() == "0":
        info["remaining"] = 0
    if hdrs.get("x-ratelimit-reset"):
        try:
            info["reset"] = int(float(hdrs["x-ratelimit-reset"]))
        except ValueError:
            pass
    if hdrs.get("x-ratelimit-resource"):
        info["resource"] = hdrs["x-ratelimit-resource"].strip().lower()
    text = (stderr or b"").decode("utf-8", "replace") + "\n" + (stdout or b"").decode("utf-8", "replace")
    if "graphql" in text.lower():
        info.setdefault("resource", "graphql")
    elif re.search(r"api\.github\.com/repos|api\.github\.com/orgs|api\.github\.com/user", text):
        info.setdefault("resource", "core")
    return info


def is_limit_failure(hdrs, stdout, stderr):
    # A header is corroboration enough: 429, retry-after, or an EMPTY bucket. This is the same
    # polarity the sweep uses (#1762) — a bare 403 with none of these is a permission failure and
    # must be replayed unchanged, not slept on.
    if hdrs.get("retry-after") or hdrs.get("x-ratelimit-remaining", "").strip() == "0":
        return True
    text = (stderr or b"").decode("utf-8", "replace") + "\n" + (stdout or b"").decode("utf-8", "replace")
    low = text.lower()
    if re.search(r"http/[0-9.]+\s+429\b", low):
        return True
    return any(phrase in low for phrase in LIMIT_PHRASES)


def probe_buckets(gh, sd):
    """Ask `/rate_limit` which bucket is spent, and when it resets.

    Used ONLY to NAME a reset the refused call did not carry — never to decide whether a call is
    limited, and never to declare the fleet healthy: `/rate_limit` was measured reporting 4933/5000
    while every GraphQL call failed (#1762). The endpoint itself is not charged to the limit.
    """
    try:
        with SingleFlight(os.path.join(sd, "gh.lock"), lock_timeout()):
            proc = subprocess.run([gh, "api", "rate_limit"], stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, timeout=60)
        if proc.returncode != 0:
            return {}
        data = json.loads(proc.stdout.decode("utf-8", "replace"))
    except Exception:
        return {}
    out = {}
    for name, res in (data.get("resources") or {}).items():
        if not isinstance(res, dict):
            continue
        try:
            remaining = int(res.get("remaining"))
            reset = int(res.get("reset"))
        except (TypeError, ValueError):
            continue
        if remaining <= 0:
            out[name] = reset
    return out


def bucket_and_reset(argv, info, gh, sd):
    buckets = probe_buckets(gh, sd) if (info.get("reset") is None) else {}
    resource = info.get("resource")
    if not resource:
        if argv and argv[0] in GRAPHQL_GROUPS:
            resource = "graphql"
        elif argv and argv[0] == "api":
            resource = "graphql" if any("graphql" in a for a in argv) else "core"
        elif buckets:
            resource = sorted(buckets)[0]
    if info.get("reset") is None and resource and resource in buckets:
        info = dict(info, reset=buckets[resource])
    return (resource or "unknown"), info.get("reset")


def record_limit(sd, bucket, reset, argv, attempts, gave_up):
    stamp = "bucket=%s reset=%s at=%d attempts=%d%s cmd=gh %s" % (
        bucket, reset if reset else "unknown", int(time.time()), attempts,
        " GAVE-UP" if gave_up else "", " ".join(argv)[:200])
    try:
        _write_atomic(os.path.join(sd, "last-limit"), stamp + "\n")
    except OSError:
        pass


def record_wedge(sd, name, stamp):
    try:
        _write_atomic(os.path.join(sd, name), stamp + "\n")
    except OSError:
        pass


def record_lock_timeout(sd, argv, waited):
    """A wedged lock is NOT a rate limit and must never be recorded as one.

    Writing `last-limit` here would make the durable "why was this cycle blind" artifact point at
    GitHub quota while the truth is a stuck process — a misdiagnosis that looks authoritative.
    """
    record_wedge(sd, "last-lock-timeout",
                 "waited=%ss at=%d cmd=gh %s" % (waited, int(time.time()), " ".join(argv)[:200]))


def mode_state():
    """Print every recorded non-limit/wedge event WITH ITS AGE — a write-only record is a stale flag.

    ALL records, not the first: `last-limit` is never cleared, so returning on the first hit made a
    months-old rate limit mask the wedged lock or hung `gh` that is the CURRENT reason a cycle is
    blind (round-2 review). Each line ages itself, so a past event cannot read as current.
    """
    sd = state_dir()
    printed = False
    for name in ("last-limit", "last-lock-timeout", "last-call-timeout"):
        path = os.path.join(sd, name)
        try:
            with open(path, "r") as fh:
                line = fh.read().strip()
        except OSError:
            continue
        at = None
        for field in line.split():
            if field.startswith("at=") and field[3:].isdigit():
                at = int(field[3:])
        printed = True
        if at is None:
            sys.stdout.write("%s: %s age=unknown\n" % (name, line))
        else:
            age = max(0, int(time.time()) - at)
            sys.stdout.write("%s: %s age=%ss\n" % (name, line, age))
    if not printed:
        sys.stdout.write("no limit recorded\n")
    return 0


# ── backoff schedule ────────────────────────────────────────────────────────────────────────────
def planned_wait(info, attempt, rnd=random):
    """The documented schedule. Returns None when the wait would exceed the in-call bound.

    retry-after            -> exactly that (GitHub: "do not retry until that many seconds")
    remaining == 0 + reset -> until the bucket's own reset epoch
    otherwise (secondary)  -> >= 60 s, doubling per attempt, with jitter
    """
    now = time.time()
    fixed = False
    if info.get("retry_after") is not None:
        wait, fixed = float(info["retry_after"]), True
    elif info.get("remaining") == 0 and info.get("reset"):
        wait, fixed = max(1.0, float(info["reset"]) - now + 1.0), True
    else:
        wait = base_wait() * (2 ** (attempt - 1))
        spread = jitter_frac()
        if spread:
            wait *= 1.0 + rnd.uniform(-spread, spread)
        wait = max(base_wait(), wait)
    if not fixed:
        wait = max(wait, base_wait())
    if wait > max_wait():
        return None
    return max(wait, 1.0)


def _sleep(seconds):
    """Sleep, unless GHS_SLEEP_CMD is set — the TEST hook that records the schedule instead."""
    recorder = os.environ.get("GHS_SLEEP_CMD")
    if recorder:
        subprocess.run([recorder, "%.3f" % seconds], check=False)
        return
    time.sleep(seconds)


def fail_loudly(bucket, reset, argv, attempts, reason):
    when = ""
    if reset:
        when = " reset=%s (%s)" % (reset, time.strftime("%H:%M:%SZ", time.gmtime(int(reset))))
    sys.stderr.write(
        "gh-serial: RATE_LIMITED bucket=%s%s attempts=%d reason=%s cmd='gh %s'\n"
        % (bucket, when, attempts, reason, " ".join(argv)[:200]))
    sys.stderr.write(
        "gh-serial: giving up after the bounded retry budget — THIS IS NOT EMPTY DATA. "
        "The caller must treat the read as unreadable, not as zero rows (exit %d).\n"
        % EXIT_RATE_LIMITED)
    sys.stderr.flush()
    return EXIT_RATE_LIMITED


def call_with_backoff(argv, gh, sd, mutative=False, label=None):
    """Run `gh <argv>` under single-flight with bounded secondary-limit backoff.

    Returns (returncode, stdout, stderr, limit_meta). `limit_meta` is non-empty when the call was
    refused on a rate limit, whether or not it later succeeded — so a caller can record that the
    cycle was limited instead of looking merely slow.
    """
    argv = list(argv)
    limit_meta = {}
    attempt = 0
    while True:
        attempt += 1
        try:
            with SingleFlight(os.path.join(sd, "gh.lock"), lock_timeout()):
                if mutative:
                    pace_mutative(sd)
                try:
                    proc = subprocess.run([gh] + argv, stdout=subprocess.PIPE,
                                          stderr=subprocess.PIPE, timeout=call_timeout())
                except subprocess.TimeoutExpired:
                    record_wedge(sd, "last-call-timeout",
                                 "timeout=%ss at=%d cmd=gh %s" % (
                                     call_timeout(), int(time.time()), " ".join(argv)[:200]))
                    sys.stderr.write(
                        "gh-serial: CALL_TIMEOUT gh did not return within %ss — cmd='gh %s'\n"
                        "gh-serial: this is a TRANSPORT failure, not a rate limit; not retrying\n"
                        % (call_timeout(), " ".join(argv)[:200]))
                    return EXIT_CALL_TIMEOUT, b"", b"", {"call_timeout": True}
                if mutative:
                    record_mutative(sd)
        except LockTimeout as exc:
            record_lock_timeout(sd, argv, lock_timeout())
            sys.stderr.write("gh-serial: LOCK_TIMEOUT %s — cmd='gh %s'\n"
                             % (exc, " ".join(argv)[:200]))
            return EXIT_RATE_LIMITED, b"", b"", {"lock_timeout": True}

        if proc.returncode == 0:
            return 0, proc.stdout, proc.stderr, limit_meta

        hdrs, _status, _body = split_headers(proc.stdout)
        if not is_limit_failure(hdrs, proc.stdout, proc.stderr):
            # NOT a rate limit: replay the failure untouched (a permission 403, a 404, a network
            # error). Retrying those would hide the real cause behind a wall-clock delay.
            return proc.returncode, proc.stdout, proc.stderr, limit_meta

        info = limit_info(hdrs, proc.stdout, proc.stderr, argv)
        bucket, reset = bucket_and_reset(argv, info, gh, sd)
        wait = planned_wait(info, attempt)
        limit_meta = {
            "bucket": bucket,
            "reset": reset,
            "attempts": attempt,
            "wait": wait,
        }
        record_limit(sd, bucket, reset, argv, attempt, gave_up=wait is None or attempt >= max_attempts())
        if wait is None:
            return (fail_loudly(bucket, reset, argv, attempt, "wait-beyond-bound"),
                    b"", getattr(proc, "stderr", b""), limit_meta)
        if attempt >= max_attempts():
            return (fail_loudly(bucket, reset, argv, attempt, "attempts-exhausted"),
                    b"", proc.stderr, limit_meta)
        sys.stderr.write(
            "gh-serial: rate limited (bucket=%s reset=%s) — waiting %.0fs before attempt %d/%d\n"
            % (bucket, reset if reset else "unknown", wait, attempt + 1, max_attempts()))
        sys.stderr.flush()
        _sleep(wait)


# ── modes ──────────────────────────────────────────────────────────────────────────────────────
def mode_run(argv):
    mutative = False
    rest = []
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--":
            rest.extend(argv[i + 1:])
            break
        if arg == "--mutative":
            mutative = True
        elif arg in ("-h", "--help") and not rest:
            # ONLY the layer's own help, and only when no gh command has been named yet. Matching it
            # anywhere in the argv swallowed `ghs_run -- gh pr create --help` and printed THIS
            # docstring with rc 0 — an adapter answering a question gh was asked (#1959/#1981 class).
            sys.stdout.write(__doc__ or "")
            return 0
        else:
            rest.append(arg)
        i += 1
    # `ghs_run -- gh pr list …` is the documented call-site shape (it reads AS the gh call it is),
    # so the leading separators and the literal `gh` token are accepted and dropped: the engine
    # supplies the binary itself. Stripping happens AFTER the loop because `ghs_run` already passes
    # its own `--` (and `ghs_mut` a `--mutative --`), so a second one arrives in `rest`.
    while rest and rest[0] == "--":
        rest = rest[1:]
    if rest and rest[0] == "gh":
        rest = rest[1:]
    if not rest:
        sys.stderr.write("gh-serial: run needs a gh command, e.g. `gh-serial run -- gh pr list`\n")
        return EXIT_USAGE
    gh = real_gh()
    sd = state_dir()
    rc, out, err, _meta = call_with_backoff(rest, gh, sd, mutative=mutative)
    sys.stdout.buffer.write(out)
    sys.stdout.buffer.flush()
    if err:
        sys.stderr.buffer.write(err)
        sys.stderr.buffer.flush()
    return rc


JQ_FALLBACK = "r"


def mode_rest(argv):
    jq_expr = None
    method = "GET"
    path = None
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--jq":
            i += 1
            if i >= len(argv):
                sys.stderr.write("gh-serial: --jq needs an expression\n")
                return EXIT_USAGE
            jq_expr = argv[i]
        elif arg.startswith("--jq="):
            jq_expr = arg.split("=", 1)[1]
        elif arg == "--method":
            i += 1
            if i >= len(argv):
                sys.stderr.write("gh-serial: --method needs a verb\n")
                return EXIT_USAGE
            method = argv[i].upper()
        elif arg.startswith("--method="):
            method = arg.split("=", 1)[1].upper()
        elif arg in ("-h", "--help"):
            sys.stdout.write(__doc__ or "")
            return 0
        elif arg.startswith("-"):
            sys.stderr.write("gh-serial: rest does not model flag %r (call gh-serial run instead)\n" % arg)
            return EXIT_USAGE
        else:
            if path is not None:
                sys.stderr.write("gh-serial: rest takes exactly one path\n")
                return EXIT_USAGE
            path = arg
        i += 1
    if not path:
        sys.stderr.write("gh-serial: rest needs an API path, e.g. repos/o/r/pulls?state=open\n")
        return EXIT_USAGE
    if method != "GET":
        # Only a conditional GET is free; a mutating call must go through `run --mutative` so the
        # >= 1 s pacing applies.
        sys.stderr.write("gh-serial: rest models conditional GET only (use `run --mutative -- api -X %s`)\n"
                         % method)
        return EXIT_USAGE

    gh = real_gh()
    sd = state_dir()
    key = hashlib.sha256(("%s %s" % (method, path)).encode()).hexdigest()[:32]
    etag_dir = os.path.join(sd, "etag")
    os.makedirs(etag_dir, mode=0o700, exist_ok=True)
    # ⛔ ONE FILE PER URL, NOT TWO. The etag and the body it validates are one invariant: if they are
    # separately replaced, a concurrent poll (or a kill between the two writes) can pair NEW etag with
    # OLD body — and every later 304 then replays bytes the server never validated, with rc 0 and no
    # diagnostic. A single cache file replaced with one `os.replace` makes the pair atomic.
    cache_path = os.path.join(etag_dir, key + ".cache")
    max_age = _env("GHS_ETAG_MAX_AGE", 3600.0, float)

    cached_etag = None
    cached_body = None
    try:
        if time.time() - os.path.getmtime(cache_path) <= max_age:
            with open(cache_path, "rb") as fh:
                raw = fh.read()
            first, sep, rest = raw.partition(b"\n")
            if sep and first:
                cached_etag = first.decode("latin-1").strip()
                cached_body = rest
    except OSError:
        cached_etag = None
        cached_body = None

    gh_argv = ["api", "-i", path]
    if cached_etag:
        gh_argv = ["api", "-i", "-H", "if-none-match: %s" % cached_etag, path]

    rc, out, err, meta = call_with_backoff(gh_argv, gh, sd)
    hdrs, status, body = split_headers(out)
    # ⛔ THE STATUS DECIDES, NOT THE EXIT CODE. gh exits 1 for a 304 today (it reports any status >
    # 299), but that is gh's implementation detail: keying on rc means the day it exits 0 the 304
    # falls through to an EMPTY body with rc 0 — a free poll that silently reads as "nothing there".
    if status == 304:
        if cached_body is None:
            sys.stderr.write(
                "gh-serial: the API answered 304 for %s but no cached body is stored — refusing to "
                "invent an empty result (this is a bug, not an empty list)\n" % path)
            return 1
        body = cached_body
    elif rc != 0:
        sys.stdout.buffer.write(out)
        sys.stdout.buffer.flush()
        if err:
            sys.stderr.buffer.write(err)
            sys.stderr.buffer.flush()
        return rc
    elif status is None or status >= 400:
        sys.stdout.buffer.write(body)
        sys.stdout.buffer.flush()
        return 1
    elif status == 200 and hdrs.get("etag"):
        try:
            _write_atomic(cache_path, hdrs["etag"].encode("latin-1") + b"\n" + body)
        except OSError as exc:
            # An unwritable cache must NOT leave a pair that can be replayed wrongly: drop it.
            sys.stderr.write("gh-serial: could not cache the ETag for %s (%s) — the next poll will "
                             "be a full fetch\n" % (path, exc))
            try:
                os.unlink(cache_path)
            except OSError:
                pass

    if jq_expr:
        proc = subprocess.run(["jq", "-" + JQ_FALLBACK, jq_expr], input=body,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        sys.stdout.buffer.write(proc.stdout)
        sys.stdout.buffer.flush()
        if proc.returncode != 0:
            # A projection failure must never look like "no rows" (the #1981 defect class).
            sys.stderr.buffer.write(proc.stderr)
            sys.stderr.write("gh-serial: --jq failed for %s — refusing to return an empty result\n" % path)
            return 1
        return 0
    sys.stdout.buffer.write(body)
    sys.stdout.buffer.flush()
    return 0


def main(argv):
    if not argv or argv[0] in ("-h", "--help", "help"):
        sys.stdout.write(__doc__ or "")
        return 0 if argv else EXIT_USAGE
    mode = argv[0]
    if mode == "version":
        sys.stdout.write("gh-serial %s\n" % VERSION)
        return 0
    if mode == "state":
        return mode_state()
    if mode == "run":
        return mode_run(argv[1:])
    if mode == "rest":
        return mode_rest(argv[1:])
    sys.stderr.write("gh-serial: unknown mode %r (run|rest|version)\n" % mode)
    return EXIT_USAGE


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(130)
