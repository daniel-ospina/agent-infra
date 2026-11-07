#!/usr/bin/env python3
# gh-cred — WHICH credential serves a GitHub call, and why. One decision function, four fallback
# arms, one counter that proves the defect this file exists to prevent is not happening (agent-infra#3429).
#
# WHY THIS FILE EXISTS. The fleet's reads and the landing rail's writes shared ONE 5,000/hour
# budget (REST `core`, per USER). Measured on #3429: `core` hit `0/5000` at 06:10Z, 07:10Z and
# 07:20Z on one day — 2609 → 0 in 40 minutes, ~65 calls/min — while GraphQL still held 4,321. The
# consequence is #3584: reads ate the budget the controller needed, `provision` failed, the board
# came back unparsable, the claim gate went INCOMPLETE, dispatch stopped, `DRAIN DEADLOCK — no PR
# merged in 360m`.
#
# A GitHub App INSTALLATION token has its OWN budget, so read-heavy automation stops competing with
# the rail's writes. Primary sources (docs.github.com, fetched 2026-11-06):
#   * the installation token expires after 1 hour — "The installation access token will expire
#     after 1 hour." (apps/…/generating-an-installation-access-token-for-a-github-app). NOT
#     configurable. This file's answer is therefore NOT a longer token but ZERO scheduled
#     maintenance: a STATIC private key, an on-demand mint, a cache refreshed inside the last 5
#     minutes, and a transparent re-mint when a cached token has expired. No timer, no cron, no
#     human. If a change to this file needs one of those, it is wrong.
#   * an installation token's own limit — "GitHub Apps authenticating with an installation access
#     token use the installation's minimum rate limit of 5,000 requests per hour", scaling with
#     repos/org users, capped at 12,500 (15,000 GHEC)
#     (rest/using-the-rest-api/rate-limits-for-the-rest-api).
# The OTHER direction of the same doc is why the split is safe rather than a trade: an app acting
# ON YOUR BEHALF drains YOUR bucket ("if an app with a 15,000 request limit makes 10,000 requests
# on your behalf, you will have exhausted the 5,000 request budget for your personal access
# tokens"). An INSTALLATION token does not act on anybody's behalf, which is exactly the property
# the fleet needs — measured on #3429: a `check-runs` read and a `pulls` read through the
# installation moved only the app budget.
#
# ⛔ THE CONTRADICTION TEST, RUN FIRST (#3429, this repo's own record). #3429 keeps the two-bucket
# PACING decision function as future work and does NOT claim the App replaces it. So this file
# never deletes, bypasses or relaxes `gh-limit.py`'s floors, budget gates, backoff or single-flight:
# it chooses a CREDENTIAL, and hands the chosen credential to that layer unchanged. Two consequences
# are deliberately built in:
#   * THE METER KEEPS THE USER CREDENTIAL. `gh api rate_limit` is what the pacing layer reads to
#     decide whether the account is out of budget. Serving that probe from the app token would show
#     the pacing layer the APP's remaining and tell it the USER bucket is healthy — i.e. it would
#     silently disarm the very guard that #3429 put in place. So `purpose=meter` is pinned to the
#     user credential, and that is a correctness rule, not a preference.
#   * `gh auth …` also keeps the user credential: those verbs INTROSPECT the stored credential, and
#     answering them with a substituted token would make `gh auth token` lie about what is on disk.
#
# ⛔ ONE DECISION FUNCTION, NOT `if`s AT CALL SITES. `decide()` is PURE over its inputs, so every
# arm is a table row a test can pin, and the ORDER of the arms is the security boundary (a write is
# refused the app credential before any budget question is asked). `resolve()` is the only thing
# that supplies real inputs to it, and `gh-limit.py` calls `resolve()` from ONE place.
#
# ⛔ EVERY FALLBACK IS ATTRIBUTABLE. An arm that quietly produced "not the app" would be
# indistinguishable from the layer being broken — which is precisely the state a lane cannot debug
# (the #3584 signature). So each decision names its arm, appends one line to `decisions.log`, and
# bumps a counter. `--stats` reports them, and `read_on_user_unjustified` is the regression
# assertion: a READ served by the user credential while the app was available is a DEFECT, so it is
# counted separately from the reads that legitimately fall back.
#
# ⛔ THE PRIVATE KEY IS NOT COPIED PER LANE OR PER CELL (owner constraint). Nothing here ships a key
# anywhere: `deploy-harness.sh` walks this source tree and copies FILES UNDER IT, and the key lives
# at `~/.pi/agent/gh-app.pem` — outside every checkout. So the App credential exists on exactly the
# boxes an operator placed it on, and every other box reports the named arm `no-key` (a visible
# "this box still spends the user bucket"), never a silent one. The blast-radius statement, the arms
# table and the operator note live in `docs/ops/gh-rate-limits.md` ("Which credential", "Blast
# radius") — that file, not a separate page: an operator command that points at a path nobody can
# open is worse than no pointer at all (caught in review).
#
# DEPENDENCIES: stdlib + `openssl` for the RS256 signature. Deliberately NOT `gh`: this file is
# called from INSIDE the `gh` shim, so invoking `gh` would re-enter the layer (and, on a box whose
# shim resolves to this deployment, the depth guard would refuse it).
"""End of design notes. CLI:

  gh-cred.py                 print an installation token (mint/cached); exit 1 if unavailable
  gh-cred.py --token         same
  gh-cred.py --refresh       drop the cache and mint a new token
  gh-cred.py --status        print the APP budget and the USER budget side by side
  gh-cred.py --stats         counters: which arm served, and the read-on-user regression count
  gh-cred.py --explain --kind read|write [--remaining N]
                             print the decision for a hypothetical call (no network, no mint)
  gh-cred.py --jwt           print a fresh JWT (diagnostic; proves the static key signs)
  gh-cred.py --which -- <argv…>
                             print the credential and arm that WOULD serve this gh invocation
"""

import base64
import calendar
import json
import os
import subprocess
import sys
import time

# ── configuration ───────────────────────────────────────────────────────────────────────────────
HOME = os.environ.get("HOME") or os.path.expanduser("~")

APP_KEY = os.environ.get("GH_CRED_APP_KEY") or os.path.join(HOME, ".pi", "agent", "gh-app.pem")
APP_ID = os.environ.get("GH_CRED_APP_ID") or "5649054"
INSTALLATION_ID = os.environ.get("GH_CRED_INSTALLATION_ID") or "179404600"
API = (os.environ.get("GH_CRED_API") or "https://api.github.com").rstrip("/")

CACHE_DIR = os.environ.get("GH_CRED_CACHE_DIR") or os.path.join(HOME, ".pi", "agent", "gh-cred")

# The floor. An installation token's own budget is 5,000/hr; a floor of 500 keeps ~10% for the
# rail's own read-backs and for a burst the caller did not predict. Configurable because a GHEC
# installation (12,500–15,000) wants a proportionally larger reserve.
FLOOR = int(os.environ.get("GH_CRED_FLOOR") or 500)

# Minting early is cheaper than minting late: a token with <5 minutes left is replaced BEFORE it is
# handed to a call, so expiry is never surfaced to a caller. This is the property the owner asked to
# protect — short-lived token, zero scheduled maintenance.
RETIRE_MARGIN = int(os.environ.get("GH_CRED_RETIRE_MARGIN") or 300)

MINT_TIMEOUT = float(os.environ.get("GH_CRED_MINT_TIMEOUT") or 10)

# Test/ops seams. `GH_CRED_NOW_CMD` is the same fake-clock contract gh-limit.py uses
# (`GH_LIMIT_NOW_CMD`): the DECISION must stay assertable without sleeping out a real hour.
NOW_CMD = os.environ.get("GH_CRED_NOW_CMD") or ""
MINT_CMD = os.environ.get("GH_CRED_MINT_CMD") or ""      # prints {"token":…,"expires_at":…}
PROBE_CMD = os.environ.get("GH_CRED_PROBE_CMD") or ""    # prints {"remaining":N,"reset":T}

# The escape hatches, and why each exists:
#   GH_CRED_APP=0        roll the fleet back to the user credential in one variable (no code change)
#   GH_CRED_ARM_OVERRIDE force an arm — a DIAGNOSIS tool. Forcing `user` on a read is the exact
#                        defect this file prevents, so it is COUNTED as unjustified, not hidden.
ENABLED_DEFAULT = not (os.environ.get("GH_CRED_APP") or "").strip().lower() in ("0", "off", "false", "no")
ARM_OVERRIDE = (os.environ.get("GH_CRED_ARM_OVERRIDE") or "").strip()

TOKEN_FILE = "token.json"
MINT_FAIL_FILE = "mint-failure.json"
# ⛔ A FAILED MINT IS NEGATIVELY CACHED, and this is not politeness — it is the difference between a
# revoked key costing ONE attempt and costing EVERY gh call. `resolve()` runs once per gh invocation,
# so without a cooldown a controller with a rotated/revoked key pays a JWT sign plus a network attempt
# — up to `GH_CRED_MINT_TIMEOUT` (10 s) — on every single read, on the box whose reads gate dispatch.
# Measured on review: three sequential reads against a failing mint = three mint attempts, and one read
# paid 2.09 s of pure mint latency. The cooldown is SHORT on purpose: a re-placed key must take effect
# within a minute, with no restart and no human step — the same "zero scheduled maintenance" property
# the token lifetime rests on.
MINT_COOLDOWN = int(os.environ.get("GH_CRED_MINT_COOLDOWN") or 60)
BUDGET_FILE = "app-budget.json"
DECISIONS_FILE = "decisions.log"

DECISIONS_MAX_BYTES = 256 * 1024

# Arms that legitimately answer a READ with the USER credential. Anything not in this set is the
# defect the regression assertion counts — an arm name that is not one of these and is not `app`
# means the wiring chose the user credential without a reason, which is what #3429 measured.
USER_READ_ARMS = frozenset((
    "mint-failed", "floor", "disabled", "no-key", "no-helper", "app-refused", "app-dry",
))


class Decision(object):
    """arm: why THIS credential. credential: "app" | "user". token: the app token, when arm is app."""

    __slots__ = ("arm", "credential", "why", "token")

    def __init__(self, arm, credential, why, token=None):
        self.arm, self.credential, self.why, self.token = arm, credential, why, token

    def __repr__(self):
        return "Decision(arm=%r, credential=%r, why=%r)" % (self.arm, self.credential, self.why)


# ── clock / cache ───────────────────────────────────────────────────────────────────────────────
def now():
    """Seconds since the epoch, or the fake clock's reading. ONE clock for the whole file."""
    if NOW_CMD:
        try:
            out = subprocess.run(NOW_CMD, shell=True, stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL, timeout=10).stdout
            return float(out.decode().strip().split()[0])
        except Exception:
            # A broken fake clock must not become a silent "no clock": fall through to the real one
            # so the file still works, and the caller's assertions see real time rather than 0.
            return time.time()
    return time.time()


def _cache_dir():
    try:
        os.makedirs(CACHE_DIR, mode=0o700)
    except OSError:
        pass
    return CACHE_DIR


def _read(name):
    try:
        with open(os.path.join(_cache_dir(), name), "r") as fh:
            return json.load(fh)
    except Exception:
        return None


def _write(name, doc):
    """Write 0600 through a temp file: a half-written token cache is a credential corruption, and a
    reader that ran mid-write would see truncated JSON and (correctly) treat it as 'no token'."""
    d = _cache_dir()
    path = os.path.join(d, name)
    tmp = path + ".tmp.%d" % os.getpid()
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as fh:
            json.dump(doc, fh)
        os.replace(tmp, path)
        return True
    except Exception:
        try:
            os.unlink(tmp)
        except Exception:
            pass
        return False


# ── attribution: one log line and one counter per decision ──────────────────────────────────────
# ⛔ APPEND-ONLY, ONE SMALL LINE PER EVENT (`O_APPEND`), written by up to four boxes and dozens of
# lanes at once. gh-limit.py already learned this the hard way and states the reason for its own
# stats log: "concurrent lanes cannot lose each other's counts the way a read-modify-write of one JSON
# document would". A counter that SILENTLY UNDER-COUNTS is worse than none here, because the number it
# under-reports is the regression assertion — the one signal that says the fleet is back on the user
# bucket.
COUNTERS_FILE = "counters.jsonl"
COUNTERS_MAX_BYTES = 1 << 20


def log(line):
    path = os.path.join(_cache_dir(), DECISIONS_FILE)
    try:
        if os.path.exists(path) and os.path.getsize(path) > DECISIONS_MAX_BYTES:
            # Bounded, append-only, one generation: the log is evidence, not an archive, and an
            # unbounded log on a box with 40 lanes is a disk leak.
            try:
                os.replace(path, path + ".1")
            except Exception:
                pass
        with open(path, "a") as fh:
            fh.write("%s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now())), line))
    except Exception:
        pass


def count(arm, kind):
    """Record ONE decision. Append-only; aggregation happens in `_stats()`."""
    d = _cache_dir()
    path = os.path.join(d, COUNTERS_FILE)
    try:
        if os.path.exists(path) and os.path.getsize(path) > COUNTERS_MAX_BYTES:
            try:
                os.replace(path, path + ".1")
            except Exception:
                pass
        line = json.dumps({"at": int(now()), "arm": arm, "kind": kind}, separators=(",", ":"))
        with open(path, "a") as fh:
            fh.write(line + "\n")
    except Exception:
        pass


# ── RS256 JWT from the STATIC key ───────────────────────────────────────────────────────────────
def _b64url(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


class MintError(Exception):
    pass


def jwt(key_path=None, app_id=None, at=None):
    """A GitHub App JWT (RS256), signed with the static private key.

    ⛔ `openssl` RATHER THAN A PYTHON CRYPTO DEPENDENCY, deliberately: the fleet boxes do not all
    carry `cryptography`, and a *missing python module* would turn every read back onto the user
    credential (arm `mint-failed`) — i.e. the fix would silently not apply on a box that has no
    pip. `openssl` is present wherever `gh` and `git` are, which is the only environment this runs
    in. The signature is verified by gh-cred.test.sh against a throwaway key, so this is not a
    claim, it is a checked property.
    """
    key_path = key_path or APP_KEY
    app_id = app_id or APP_ID
    at = int(now() if at is None else at)
    # `iat` backdated 60s: a box 30s ahead of GitHub is otherwise told the JWT is not yet valid, and
    # that failure would read as `mint-failed` — the arm that quietly returns the fleet to the user
    # budget. `exp` is 9 minutes (GitHub's ceiling for a JWT is 10).
    header = {"alg": "RS256", "typ": "JWT"}
    payload = {"iat": at - 60, "exp": at + 540, "iss": str(app_id)}
    signing_input = "%s.%s" % (
        _b64url(json.dumps(header, separators=(",", ":")).encode()),
        _b64url(json.dumps(payload, separators=(",", ":")).encode()))
    try:
        p = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path],
                           input=signing_input.encode(), stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, timeout=15)
    except FileNotFoundError:
        raise MintError("openssl is not on PATH — cannot sign the app JWT")
    except subprocess.TimeoutExpired:
        raise MintError("openssl timed out signing the app JWT")
    if p.returncode != 0:
        raise MintError("openssl could not sign with %s: %s"
                        % (key_path, p.stderr.decode("utf-8", "replace").strip()[:200]))
    return signing_input + "." + _b64url(p.stdout)


def _http(url, method="GET", token=None, body=None):
    """Minimal stdlib HTTP. Returns (status, parsed-json-or-None, text).

    ⛔ NO `gh` HERE. This file is invoked from inside the `gh` shim, so a `gh` call would re-enter
    the layer being served — and on a box whose shim resolves to this deployment the depth guard
    refuses it (exit 127), which would surface as `mint-failed` forever.
    """
    import urllib.error
    import urllib.request
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    req.add_header("User-Agent", "agent-infra-gh-cred")
    if token:
        req.add_header("Authorization", "Bearer %s" % token)
    try:
        with urllib.request.urlopen(req, timeout=MINT_TIMEOUT) as resp:
            raw = resp.read().decode("utf-8", "replace")
            return resp.status, _json_or_none(raw), raw
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", "replace") if hasattr(exc, "read") else ""
        return exc.code, _json_or_none(raw), raw
    except Exception as exc:                       # network, DNS, TLS, timeout
        return 0, None, "%s: %s" % (type(exc).__name__, exc)


def _json_or_none(raw):
    try:
        return json.loads(raw)
    except Exception:
        return None


def _epoch(iso):
    """GitHub's `expires_at` (e.g. 2026-11-06T23:00:00Z) to epoch. 0 when unparseable.

    ⛔ `calendar.timegm`, NOT `mktime() - time.timezone` (review note). `time.timezone` is a FIXED
    offset with no DST term, so on a DST-observing host the cached expiry was an hour out for part of
    the year — bounded and self-correcting (`RETIRE_MARGIN` re-mints, then the refusal takes the retry
    arm), but wrong by construction. `timegm` reads the parsed struct fields as UTC, which is exactly
    what GitHub sends (`Z`, i.e. `+0000`). (`strptime` KEEPS the offset in `tm_gmtoff` but does not
    apply it to the fields, and `timegm` ignores `tm_gmtoff` — so this is correct for `Z` and would be
    off by the offset for a `+0200` stamp, which no input path produces.)
    """
    if not iso:
        return 0
    txt = str(iso).strip().replace("Z", "+0000")
    for fmt in ("%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%dT%H:%M:%S.%f%z"):
        try:
            return int(calendar.timegm(time.strptime(txt, fmt)))
        except Exception:
            continue
    return 0


def mint():
    """Mint an installation token. Returns (token, expires_at_epoch). Raises MintError.

    The cache is written BEFORE the budget probe so a probe failure cannot lose a good token.
    """
    if MINT_CMD:
        # Test seam: the same shape the API returns, so the cache/refresh logic under test is the
        # production one (only the network is replaced).
        p = subprocess.run(MINT_CMD, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           timeout=MINT_TIMEOUT + 10)
        if p.returncode != 0:
            raise MintError("mint command failed rc=%d: %s"
                            % (p.returncode, p.stderr.decode("utf-8", "replace").strip()[:200]))
        doc = _json_or_none(p.stdout.decode("utf-8", "replace")) or {}
        tok = doc.get("token")
        if not tok:
            raise MintError("mint command produced no token")
        exp = int(doc.get("expires_at") or 0) or (int(now()) + 3600)
        _write(TOKEN_FILE, {"token": tok, "expires_at": exp, "minted_at": int(now())})
        return tok, exp

    if not os.path.isfile(APP_KEY):
        raise MintError("no app private key at %s" % APP_KEY)
    try:
        os.stat(APP_KEY)
    except OSError as exc:
        raise MintError("cannot stat %s: %s" % (APP_KEY, exc))

    tok_jwt = jwt()
    status, doc, raw = _http("%s/app/installations/%s/access_tokens" % (API, INSTALLATION_ID),
                             method="POST", token=tok_jwt)
    if status not in (200, 201) or not isinstance(doc, dict) or not doc.get("token"):
        raise MintError("installation token request failed (status %s): %s"
                        % (status or "network", (raw or "")[:200].strip()))
    tok = doc["token"]
    exp = _epoch(doc.get("expires_at")) or (int(now()) + 3540)
    _write(TOKEN_FILE, {"token": tok, "expires_at": exp, "minted_at": int(now())})
    return tok, exp


def _record_mint_failure(why):
    """Open a cooldown window. Best-effort: a failure to record must not itself fail a call."""
    _write(MINT_FAIL_FILE, {"until": int(now()) + max(1, MINT_COOLDOWN),
                            "at": int(now()), "why": str(why)[:200]})


def current_token(force=False):
    """A usable installation token, minting/refreshing transparently. None when unavailable.

    ⛔ THE EXPIRY IS NEVER SURFACED. A cached token with less than RETIRE_MARGIN left is replaced
    BEFORE it is returned, so no caller ever receives a token that dies under it; and a token the
    API rejects mid-call is handled by the retry arm in gh-limit.py (`app-refused` / `app-dry`), not
    by an error the caller has to interpret. That is the whole "short-lived token, zero scheduled
    maintenance" property, in one place.
    """
    if not force:
        cached = _read(TOKEN_FILE) or {}
        tok = cached.get("token")
        exp = int(cached.get("expires_at") or 0)
        if tok and exp and (exp - int(now())) > RETIRE_MARGIN:
            return tok
        # A recent failure means "do not try again this minute", so a broken credential costs one
        # attempt per cooldown per box instead of one per call.
        failed = _read(MINT_FAIL_FILE) or {}
        if int(failed.get("until") or 0) > int(now()):
            log("arm=mint-failed why=%r (cooldown until %s)"
                % (str(failed.get("why"))[:160], int(failed["until"])))
            return None
    try:
        tok, _exp = mint()
    except MintError as exc:
        _record_mint_failure(str(exc))
        log("arm=mint-failed why=%r" % str(exc)[:200])
        return None
    except Exception as exc:                        # never let a credential bug crash a gh call
        _record_mint_failure("%s: %s" % (type(exc).__name__, exc))
        log("arm=mint-failed why=%r" % ("%s: %s" % (type(exc).__name__, exc))[:200])
        return None
    try:
        os.unlink(os.path.join(_cache_dir(), MINT_FAIL_FILE))
    except OSError:
        pass
    # One budget probe per mint (~once an hour) keeps the floor current without putting a network
    # call on the hot path. A probe failure just leaves the budget UNKNOWN, which `decide()` treats
    # as "not below the floor" — see its note on why that direction is the safe one.
    try:
        probe_budget(tok)
    except Exception:
        pass
    return tok


def probe_budget(token):
    """Refresh the cached APP budget. Returns the doc, or None when it cannot be read."""
    if PROBE_CMD:
        p = subprocess.run(PROBE_CMD, shell=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           timeout=MINT_TIMEOUT + 10)
        doc = _json_or_none(p.stdout.decode("utf-8", "replace")) if p.returncode == 0 else None
    else:
        status, doc, _raw = _http("%s/rate_limit" % API, token=token)
        if status != 200 or not isinstance(doc, dict):
            return None
        core = ((doc.get("resources") or {}).get("core") or {})
        doc = {"remaining": core.get("remaining"), "reset": core.get("reset"),
               "limit": core.get("limit")}
    if not isinstance(doc, dict) or doc.get("remaining") is None:
        return None
    out = {"remaining": int(doc["remaining"]),
           "reset": int(doc.get("reset") or 0),
           "limit": int(doc.get("limit") or 5000),
           "fetched_at": int(now())}
    _write(BUDGET_FILE, out)
    return out


def cached_budget():
    doc = _read(BUDGET_FILE)
    if not isinstance(doc, dict) or doc.get("remaining") is None:
        return None
    # A record past its own reset window is stale by definition — the bucket refilled at `reset`.
    reset = int(doc.get("reset") or 0)
    if reset and int(now()) >= reset:
        return None
    return doc


def note_app_refusal(remaining=0, reset=None):
    """The app itself told us it is dry. Record it so the NEXT call takes the `floor` arm.

    This is how the floor stays honest without a poller: the 403 that a dry installation returns IS
    the measurement, and it arrives exactly when it matters. (A poller would add a request per
    interval on every box to learn something the failing call already tells us.)
    """
    doc = {"remaining": int(remaining), "reset": int(reset or 0),
           "limit": int((cached_budget() or {}).get("limit", 5000)), "fetched_at": int(now())}
    _write(BUDGET_FILE, doc)


# ── THE DECISION FUNCTION ───────────────────────────────────────────────────────────────────────
def decide(kind, purpose="request", enabled=None, key_present=None, token_ok=None,
           app_remaining=None, floor=None):
    """THE one place that answers *which credential* and *why*. PURE — no I/O, no network.

    `kind`     "read" | "write"
    `purpose`  "request" (spends API quota) | "meter" (the rate_limit probe) | "introspect" (`gh auth`)

    ARM ORDER IS THE SECURITY BOUNDARY, and it is ordered by "what must never happen" first:
      0. purpose ≠ request → user. The meter and the credential introspection MUST see the user
         credential. Serving the pacing layer's own probe from the app would make it read the APP's
         headroom and believe the USER bucket is healthy — disarming #3429's guard. A read-only
         installation token also cannot answer `gh auth token` truthfully.
      1. write → user. The installation is read-only BY PERMISSION, so a write sent to it can only
         ever fail; sending one anyway would be a silent 403 on the rail's merge path. This arm is
         FIRST so no budget or token state can ever route a write to the app.
      2. disabled / no key / mint failed → user, each with its own named arm so an operator can tell
         "turned off" from "broken" from "this box was never given the key".
      3. below floor → user: the app bucket is the fleet's reserve for reads, and a read that
         empties it converts every later read into a failure. The floor is the reserve.
      4. otherwise → app.

    ⛔ `app_remaining is None` (budget unknown) falls through to APP, deliberately. The two
    directions are not symmetric: sending the call to the APP when its headroom is unknown risks an
    app 403, which the caller retries on the user credential (`app-dry`) — a failed call, retried.
    Sending it to the USER when its headroom is unknown is the exact failure #3429/#3584 measured
    (the rail starved of budget by reads), and it is NOT recoverable by a retry. So the unknown
    direction always resolves toward the app.
    """
    floor = FLOOR if floor is None else int(floor)
    enabled = ENABLED_DEFAULT if enabled is None else bool(enabled)
    key_present = (os.path.isfile(APP_KEY) and os.access(APP_KEY, os.R_OK)) if key_present is None \
        else bool(key_present)

    if purpose != "request":
        return Decision("purpose:%s" % purpose, "user",
                        "the %s call must see the user credential (pacing/credential truth)" % purpose)
    if kind == "write":
        return Decision("write", "user",
                        "a write is never sent to a read-only installation token")
    if kind == "unproven":
        # ⛔ THE FAIL-CLOSED ARM, AND THE ONE THE REVIEW FOUND MISSING. A call whose verb is not on the
        # READ allow-list keeps the user credential even though it is probably a read. The label says
        # exactly that, so `--stats` shows how much is being left on the user bucket and a missing
        # verb is an actionable number rather than a silent wish. The opposite default is what sent
        # `gh issue lock`, `gh run delete`, `gh workflow disable` and `gh issue pin` to the
        # installation token: `MUTATING_PAIRS` is a partial table on purpose, so "not in the write
        # table" must never mean "safe for the app".
        return Decision("not-provably-read", "user",
                        "the verb is not on the read allow-list, so the call keeps the user credential "
                        "(fail-closed: an unlisted WRITE must never reach the installation token)")
    if not enabled:
        return Decision("disabled", "user", "GH_CRED_APP=0 — the app credential is turned off")
    if not key_present:
        return Decision("no-key", "user", "no readable private key at %s" % APP_KEY)
    if not token_ok:
        return Decision("mint-failed", "user",
                        "an installation token could not be minted (see decisions.log)")
    if app_remaining is not None and int(app_remaining) <= floor:
        return Decision("floor", "user",
                        "the app bucket is at or below the floor (%d <= %d)" % (int(app_remaining), floor))
    return Decision("app", "app",
                    "read served by the installation token (app remaining %s)"
                    % ("unknown" if app_remaining is None else app_remaining))


def resolve(kind, purpose="request", argv=None, record=True):
    """Supply real inputs to `decide()` and record the outcome. THE only production entry point.

    `record=False` is for the DIAGNOSTIC verbs (currently `--which`): they answer "what WOULD serve
    this call", so they must not append a decision to `decisions.log` or bump a counter. A diagnostic
    that counts mints a synthetic answer — it inflated the `app` arm in `--stats`, and under
    `GH_CRED_ARM_OVERRIDE=user` a single `--which` made `--stats` exit 3 with
    `READS-ON-USER-UNJUSTIFIED`, i.e. asking the question MOVED THE REGRESSION COUNTER it was asked to
    explain (review P3). The mint itself is still performed: an operator debugging "why is this box on
    the user bucket" needs the real token state, and a mint is not a counter.
    """
    enabled = ENABLED_DEFAULT
    key_present = os.path.isfile(APP_KEY) and os.access(APP_KEY, os.R_OK)
    token_ok = None
    token = None
    remaining = None

    # The token is only worth minting when the decision could possibly use it — a call that is not
    # PROVABLY a read (write or unproven) or one of the pinned purposes must not spend a mint (one
    # HTTP request) to learn it will not use the answer.
    if enabled and key_present and purpose == "request" and kind == "read":
        token = current_token()
        token_ok = token is not None
        if token_ok:
            budget = cached_budget()
            remaining = None if budget is None else budget.get("remaining")

    if ARM_OVERRIDE and enabled:
        # A diagnosis/rollback seam. It does NOT silently look like health: forcing the user
        # credential onto a read is the defect, so it is counted as unjustified below.
        d = Decision("override:%s" % ARM_OVERRIDE,
                     ARM_OVERRIDE if ARM_OVERRIDE in ("app", "user") else "user",
                     "GH_CRED_ARM_OVERRIDE=%s" % ARM_OVERRIDE,
                     token if ARM_OVERRIDE == "app" else None)
        if d.credential == "app" and not d.token:
            d = Decision("mint-failed", "user", "GH_CRED_ARM_OVERRIDE=app but no token is available")
    else:
        d = decide(kind, purpose, enabled=enabled, key_present=key_present,
                   token_ok=token_ok, app_remaining=remaining)
        d.token = token if d.credential == "app" else None

    if purpose == "request" and record:
        log("arm=%s kind=%s why=%r argv=%r" % (d.arm, kind, d.why[:120],
                                               (list(argv or [])[:6])))
        count(d.arm, kind)
    return d


# ── CLI ────────────────────────────────────────────────────────────────────────────────────────
def _aggregate():
    """(arms, kinds, reads_on_user, reads_on_user_unjustified) from the append-only counters."""
    arms, kinds = {}, {}
    on_user = unjustified = 0
    for name in (COUNTERS_FILE, COUNTERS_FILE + ".1"):
        try:
            with open(os.path.join(_cache_dir(), name)) as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        e = json.loads(line)
                    except ValueError:
                        continue                 # a torn final line is skipped, never fatal
                    arm, kind = e.get("arm") or "?", e.get("kind") or ""
                    arms[arm] = arms.get(arm, 0) + 1
                    if kind:
                        kinds[kind] = kinds.get(kind, 0) + 1
                    if kind == "read":
                        if arm != "app":
                            on_user += 1
                        if arm != "app" and arm not in USER_READ_ARMS and not arm.startswith("purpose:"):
                            unjustified += 1
        except OSError:
            continue
    return arms, kinds, on_user, unjustified


def _status():
    tok = current_token()
    if not tok:
        sys.stdout.write("app: UNAVAILABLE (no key, or the installation token could not be minted)\n")
    else:
        b = probe_budget(tok) or cached_budget() or {}
        if b.get("remaining") is None:
            sys.stdout.write("app: core ?/%s (the budget probe did not answer)\n"
                             % (b.get("limit", 5000)))
        else:
            sys.stdout.write("app: core %s/%s resets_in=%s\n"
                             % (b["remaining"], b.get("limit", 5000),
                                _resets_in(b.get("reset"))))
    # The USER budget is reported by `gh api rate_limit`, which is exempt from the primary limit —
    # and it is the only way to show both side by side. Skipped when this is somehow called from
    # inside the shim (HARNESS_GH_SHIM_DEPTH), because a `gh` call from here would re-enter the
    # layer we are inside.
    if os.environ.get("HARNESS_GH_SHIM_DEPTH"):
        sys.stdout.write("user: (skipped — called from inside the gh shim)\n")
        return 0
    try:
        p = subprocess.run(["gh", "api", "rate_limit"], stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, timeout=30)
        doc = _json_or_none(p.stdout.decode("utf-8", "replace")) if p.returncode == 0 else None
        core = ((doc or {}).get("resources") or {}).get("core") or {}
        if core.get("remaining") is None:
            sys.stdout.write("user: core ? (gh did not answer)\n")
        else:
            sys.stdout.write("user: core %s/%s resets_in=%s\n"
                             % (core["remaining"], core.get("limit", 5000),
                                _resets_in(core.get("reset"))))
    except Exception:
        sys.stdout.write("user: core ? (gh not runnable here)\n")
    return 0


def _resets_in(reset):
    try:
        d = int(reset) - int(now())
    except Exception:
        return "?"
    if d <= 0:
        return "0s"
    return "%dm" % (d // 60) if d >= 60 else "%ds" % d


def _stats():
    arms, kinds, on_user, bad = _aggregate()
    if not arms:
        sys.stdout.write("gh-cred no-decisions-counted-yet\n")
        return 0
    sys.stdout.write("gh-cred floor=%d key=%s enabled=%s\n"
                     % (FLOOR, "present" if os.path.isfile(APP_KEY) else "MISSING",
                        "yes" if ENABLED_DEFAULT else "no"))
    for arm in sorted(arms):
        sys.stdout.write("  arm %-22s n=%d\n" % (arm, arms[arm]))
    for kind in sorted(kinds):
        sys.stdout.write("  kind %-21s n=%d\n" % (kind, kinds[kind]))
    sys.stdout.write("  reads served by the user credential: %d\n" % on_user)
    # ⛔ THE REGRESSION ASSERTION (#3429). A read on the user credential with no named arm is the
    # defect this file exists to prevent — the fleet quietly back on the 5,000/hour bucket. It is
    # reported on its own line and it makes the verb exit non-zero, so a caller can gate on it.
    if bad:
        sys.stdout.write("  ⛔ READS-ON-USER-UNJUSTIFIED n=%d — a read was served by the user "
                         "credential with no fallback arm; the layer is not wired\n" % bad)
    else:
        sys.stdout.write("  reads-on-user-unjustified: 0\n")
    return 3 if bad else 0


def main(argv):
    if not argv:
        argv = ["--token"]
    verb, rest = argv[0], argv[1:]

    if verb in ("--token", "-t"):
        tok = current_token(force=(os.environ.get("GH_CRED_FORCE_MINT") == "1"))
        if not tok:
            sys.stderr.write("gh-cred: no installation token (no key at %s, or minting failed — "
                             "the fallback arm is `mint-failed`, i.e. calls use the user credential)\n"
                             % APP_KEY)
            return 1
        sys.stdout.write(tok + "\n")
        return 0

    if verb == "--refresh":
        try:
            os.unlink(os.path.join(_cache_dir(), TOKEN_FILE))
        except OSError:
            pass
        tok = current_token(force=True)
        if not tok:
            sys.stderr.write("gh-cred: refresh failed — no installation token could be minted\n")
            return 1
        sys.stdout.write(tok + "\n")
        return 0

    if verb == "--status":
        return _status()

    if verb == "--stats":
        return _stats()

    if verb == "--jwt":
        try:
            sys.stdout.write(jwt() + "\n")
            return 0
        except MintError as exc:
            sys.stderr.write("gh-cred: %s\n" % exc)
            return 1

    if verb == "--explain":
        kind = "read"
        remaining = None
        purpose = "request"
        # The three inputs that are not argv properties are settable so an operator can ask "what
        # WOULD happen if…" on a box where the real state hides the answer (every arm below `app`
        # masks the ones after it — e.g. on a keyless box `--explain` could never show `floor`).
        key_present = None
        token_ok = None
        enabled = None
        i = 0
        while i < len(rest):
            a = rest[i]
            if a == "--kind" and i + 1 < len(rest):
                kind = rest[i + 1]
                i += 2
            elif a == "--remaining" and i + 1 < len(rest):
                remaining = int(rest[i + 1])
                i += 2
            elif a == "--purpose" and i + 1 < len(rest):
                purpose = rest[i + 1]
                i += 2
            elif a == "--key" and i + 1 < len(rest):
                key_present = rest[i + 1] not in ("absent", "no", "0")
                i += 2
            elif a == "--token" and i + 1 < len(rest):
                token_ok = rest[i + 1] not in ("fail", "no", "0")
                i += 2
            elif a == "--enabled" and i + 1 < len(rest):
                enabled = rest[i + 1] not in ("no", "0", "off")
                i += 2
            else:
                sys.stderr.write("gh-cred: unknown --explain flag %r\n" % a)
                return 2
        d = decide(kind, purpose, enabled=enabled, key_present=key_present,
                   token_ok=token_ok, app_remaining=remaining)
        sys.stdout.write("credential=%s arm=%s why=%s\n" % (d.credential, d.arm, d.why))
        return 0

    if verb == "--which":
        # What WOULD serve this argv. Runs the real decision path (including a mint), which is what
        # an operator debugging "why is this box still on the user bucket" needs.
        #
        # ⛔ THE KIND COMES FROM `gh-limit.py`'s OWN CLASSIFIER, NOT A SECOND COPY. An earlier version
        # kept a local verb table here, and it drifted immediately: `gh-cred.py --which -- issue lock
        # 42` answered "user/write" while production sent that same argv to the installation token.
        # A diagnostic that disagrees with the thing it diagnoses is worse than none. If the sibling
        # cannot be loaded the answer is `unproven`, which is the fail-closed default.
        args = rest[1:] if rest[:1] == ["--"] else rest
        kind = _authoritative_kind(args)
        # ⛔ AND IT RECORDS NOTHING (`record=False`): a diagnostic must not move the counters it
        # exists to explain. It used to go through the recording path, so it inflated the `app` arm in
        # `--stats` — and under `GH_CRED_ARM_OVERRIDE=user` a single `--which` made `--stats` exit 3
        # with `READS-ON-USER-UNJUSTIFIED` (review P3). The mint still happens: an operator needs the
        # real token state, and a mint is not a counter.
        d = resolve(kind, "request", args, record=False)
        sys.stdout.write("credential=%s arm=%s kind=%s why=%s\n"
                         % (d.credential, d.arm, kind, d.why))
        return 0

    sys.stderr.write("gh-cred: unknown verb %r (see the header for the verb list)\n" % verb)
    return 2


# ⛔ `--which` ASKS `gh-limit.py` RATHER THAN KEEPING ITS OWN VERB TABLE. Two classifiers for the
# same question is how the diagnostic came to answer the OPPOSITE of production (`issue lock 42`:
# "user" here, the installation token there). Loading the sibling is best-effort; failing to load it
# answers `unproven`, which is the fail-closed direction and needs no network, mint or key.
def _authoritative_kind(argv):
    import importlib.util
    limit = os.path.join(os.path.dirname(os.path.abspath(__file__)), "gh-limit.py")
    try:
        spec = importlib.util.spec_from_file_location("gh_limit", limit)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod.cred_kind(list(argv))
    except Exception:
        return "unproven"


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except BrokenPipeError:
        try:
            sys.stdout.close()
        except Exception:
            pass
        sys.exit(0)
