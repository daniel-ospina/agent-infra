#!/usr/bin/env python3
"""beta-progress.py — the DELIVERY line for the orchestrator heartbeat.

The heartbeat's own classifier answers "is a lane wedged?" — and that answer is almost
always no, so 44% of its nudges carried no alert and it never once mentioned anything
that determines whether the beta ships (measured 2026-09-27: zero mentions of P0,
blocker, merge-ready, runner or rail in the entire log).

This adds the other half: is the BETA moving. It is deliberately CHEAP and SELF-CACHED
because the heartbeat runs every 2 minutes and the reads are expensive (the PR lists are
LIMIT 500/400, so one recompute is tens of API requests).

⛔ THE LINE CARRIES ITS OWN MEASUREMENT AGE. Measured 2026-09-28: the line reported "P0 21
open, 6 NONE" for ~50 minutes while the live truth was 19 open / 2 NONE, and the orchestrator
nearly dispatched on the stale figure. A metric with no timestamp is read as live — so the age
is printed, and it is printed even when the cache is fresh.

Coverage counts a P0/P1 as covered when a MERGED or OPEN PR names the issue in its
branch or title (boundary-exact). §48 lesson: a narrow probe reports "no work" while a
PR exists, so both channels are checked.

Output: ONE line on stdout. Exit 0 always — a metrics failure must never take the
heartbeat down with it.
"""
import json
import os
import re
import subprocess
import sys
import time
import traceback
import urllib.parse
import urllib.request

REPO = "daniel-ospina/tortoise"
CACHE = os.path.expanduser("~/.pi/agent/state/beta-progress.json")
TTL = 1800  # was 3600; halved so the worst-case lag is 30m, at ~2x the API cost (still cheap)
# ⛔ A CACHE `ts` MAY NOT BE IN THE FUTURE. Clock skew between the writer and the reader is real,
# so a little is allowed and no more; see the validator in `main()` for why the bound is not
# optional. `compute()` writes `int(time.time())`.
CACHE_TS_SKEW_S = 300


def _count(x):
    """An int that is NOT a bool (#2142 review). `isinstance(True, int)` is True, so a foreign or
    hand-corrupted cache `{"open_prs": true, "merged_today": true, "p0": {"open": true, ...}}`
    passed the validator and rendered `1 open PRs, 1 merged today` as if it had been MEASURED --
    the false-reading class this file refuses to print. `_rest_prs` already rejects bool for
    `number`; this is the same test on the cache side, so both guards agree on what a count is."""
    return isinstance(x, int) and not isinstance(x, bool)


# ── gh RESOLUTION AND FAILURE CONTRACT (fixed 2026-10-01) ────────────────────
# TWO DEFECTS, both measured, both turning a read failure into a FALSE ZERO:
#  (1) `json.loads(r.stdout or "[]")` -- when gh fails, stdout is EMPTY, so the
#      `or "[]"` made it a VALID EMPTY LIST and the function returned [] instead of
#      None. Every caller's `if x is None` check was therefore dead code, and the
#      fleet read "0 open PRs" while 100 were open. A filter's empty result must
#      never stand as evidence of absence.
#  (2) Bare "gh" depends on ambient PATH. The agent shim (~/.pi/agent/shims/gh)
#      resolves the REAL gh from PATH; in a minimal environment it refuses
#      ("cannot find the real gh"), so the loop's telemetry silently zeroed while
#      the same command worked in an interactive shell. These calls are READ-ONLY
#      telemetry, not merges, so pin the real binary and drop the PATH dependency.
# ⛔ NO ABSOLUTE HOME PATH: `~/bin/gh` is the binary #1872 pinned, and expanduser builds the same
# path without hard-coding another user's home in shipped code.
_GH_CANDIDATES = (os.path.expanduser("~/bin/gh"), "/opt/homebrew/bin/gh", "/usr/local/bin/gh")


# ⛔ ALSO PREFER THE HARNESS'S OWN gh LAYER (#1988) — derived from `$O`, never from PATH. These are
# the highest-volume READS on the shared GitHub bucket; going through the layer is what stops them
# bypassing its serialisation/backoff. ⛔ THE LAYER then resolves the real gh by WALKING PATH, so
# "#1872 cannot come back" is false: the pin is passed THROUGH the layer below
# (`GH_REST_REAL_GH`/`GH_LIMIT_REAL_GH`), so these readers keep calling the binary #1872 chose for
# them and still get the layer.
def _gh_bin():
    o = os.environ.get("O", "")
    if o:
        # ⛔ ORDER: `gh-rest` FIRST, matching every shell call site (`orch-loop.sh`: "adapter last so
        # `$O/gh-rest` wins where it exists"). The adapter is what serves a GraphQL refusal over REST
        # (#1959); preferring the non-translating wrapper here made these readers fail exactly as they
        # did before that fix while the same box's shell calls took the other transport.
        for c in (os.path.join(o, "gh-rest", "gh"), os.path.join(o, "gh-limit", "gh")):
            if os.path.isfile(c) and os.access(c, os.X_OK):
                return c
    # `isfile` + X_OK, never `exists`: a DIRECTORY at a candidate path would be selected and then
    # raise from `subprocess.run` (or, worse, answer as "gh not found" — the same trap the fail-open
    # walks had; found in review round 7).
    return next((p for p in _GH_CANDIDATES
                 if os.path.isfile(p) and os.access(p, os.X_OK)), "gh")


GH = _gh_bin()
# Hand the layer the binary #1872 pinned (empty when we are not going through a layer).
_PIN = next((p for p in _GH_CANDIDATES
             if os.path.isfile(p) and os.access(p, os.X_OK)), None)   # a DIRECTORY is not a pin
GH_LAYER_ENV = ({"GH_REST_REAL_GH": _PIN, "GH_LIMIT_REAL_GH": _PIN}
                if _PIN and GH.endswith(("/gh-rest/gh", "/gh-limit/gh")) else {})


# ⛔ THE LAYER MUST NOT SLEEP INSIDE THIS PROCESS (#1988). This refresh runs inside a heartbeat
# tick that is killed at a fixed bound, while the layer's first documented backoff is 60 s: an
# in-call wait outlives the caller, and the caller is killed before the layer can say why — a
# rate-limited box then reports UNKNOWN/STALL instead of the RATE-LIMITED verdict it can prove.
# NO_WAIT makes the layer record the limit and return at once, so this process's own deferral
# takes over. Children only.
os.environ.setdefault("GH_LIMIT_NO_WAIT", "1")


def gh(*args):
    """Return parsed JSON, or None on ANY failure. None means UNKNOWN, never empty."""
    try:
        r = subprocess.run([GH, *args], capture_output=True, text=True, timeout=120,
                           env={**os.environ, **GH_LAYER_ENV} if GH_LAYER_ENV else None)
    except Exception:
        return None
    if r.returncode != 0:
        return None
    out = (r.stdout or "").strip()
    if not out:
        return None
    try:
        return json.loads(out)
    except Exception:
        return None


# ── REST SECOND SOURCE FOR THE PR LISTS (fixed 2026-10-19) ─────────────────
# WHY. Both lists come from `gh pr list --json`. Where the workspace has the gh layer's REST
# adapter (`$O/gh-rest`, #1959) the OPEN read is already served over REST — `number,title,headRefName`
# are all in its PR_FIELDS — but `mergedAt` is NOT, so the MERGED read delegates to the real gh,
# which is GRAPHQL. On the cells there is no `$O/gh-rest` (#1978), so BOTH reads are GraphQL.
# Under fleet concurrency GraphQL is refused on the SECONDARY limit while the primary budget is
# nearly untouched (measured 2026-10-19: core 1599/5000, graphql 4612/5000, one REST call
# answering in 0.43 s with 17 concurrent gh clients on the same box), and the beat printed
# `DELIVERY: unavailable (metrics read failed)` — the fleet losing its OWN progress measurement,
# the number the owner reads — while REST answered. The two limits are SEPARATE BUCKETS, so REST
# is a second SOURCE, not a retry of the same refusal.
# ⛔ DELIBERATE TRADE-OFF, stated so the next reader can weigh it rather than discover it: these
# reads go DIRECT (urllib + the token) instead of through the layer. The layer cannot serve
# `mergedAt` at all — that needs a PR_FIELDS change (filed as its own issue) — and it does not
# help the cells, which have no adapter, so a fallback that queues behind the refusing path would
# not be a fallback. The cost is real: direct reads are NOT single-flight with the box's other gh
# calls, get no ETag/304 replay, and are invisible to `$GH_LIMIT_DIR/last-limit`. That is why the
# budget below is small and shared.
REST_PER_PAGE = 100   # GitHub's ceiling for /pulls -- the honest bound on ONE request
# ⛔ THIS READ IS BOUNDED BY ITS CALLER. `beta-progress.py` runs inside a tick that the loop kills
# by the `run_bounded "$((TARGET - IN_PASS_RESERVE))"` call that launches `orchestrator-heartbeat.sh`
# (= 540 - 150 = 390 s; `TARGET` and `IN_PASS_RESERVE` in `scripts/heartbeat-loop.sh`) after 300-350 s
# of measured work, so a paging loop with no budget can outlive the slack and be KILLED -- reporting
# nothing, instead of the `unavailable` line it can prove.
#
# ⛔ CITED BY NAME, NOT BY LINE NUMBER (#2142 review). The earlier form named three line numbers; all
# three had drifted onto unrelated lines (a cadence comment, a reserve comment, and the PIDFILE guard),
# so a reader who followed the pointer could conclude the bound did not exist. A name survives an edit;
# a line number does not -- the rule `.github/workflows/harness-single-source.yml` records.
# Exceeding the budget REFUSES the read (None), exactly like an unreadable page: a truncated window
# would under-count
# `merged_today`, which is the error this fallback must not add.
REST_TIMEOUT_S = 15   # per request
# ⛔ ONE BUDGET FOR THE PAIR, not per read: `compute()` creates the deadline and hands it to both.
# 30 s is ~7x the measured latency (0.43 s/call, 9 calls ~4 s) and sits well inside the tick's
# 40-90 s of residual slack. Per-read budgets would double it to 90 s and spend the slack.
REST_BUDGET_S = 30


def _token():
    """The token for api.github.com: the fleet's env first, then gh's own config. Never logged.

    ⛔ HOST-ASSOCIATED, not "the first oauth_token in the file": hosts.yml may list another host
    (GHES) first, and THAT token answers 401 against api.github.com -- a failure that looks like
    "REST is down". Only the `github.com:` block is read. A keyring-backed config (no
    `oauth_token:` line at all) is asked for through `gh auth token`, which `gh-limit.py`'s
    `makes_request()` treats as request-free (its own `auth token` branch -- NOT `NO_REQUEST`,
    which holds only `--version`/`help`/`config`-class forms), so it cannot re-enter the refusal
    this fallback exists to escape.

    ⛔ AND DEPTH-ASSOCIATED: the key must be one of the BLOCK's OWN keys, not merely indented
    somewhere under it. gh's multi-account config nests per-user credentials under a `users:`
    map, and those nested entries come FIRST -- so "first `oauth_token:` inside the github.com
    block" can hand back ANOTHER account's token, which answers 401/404 against api.github.com
    (the same "REST is down" disguise) or spends a different account's quota. The block's
    direct child depth is fixed by its first indented line; anything deeper is a nested map and
    is skipped.

    ⛔ WHAT THAT LEAVES, measured rather than assumed: the block's OWN `oauth_token:` is what gh
    itself uses. When it switches accounts gh MOVES the active user's token up to block level
    (`activateUser`), so a config carrying both a `users:` map and a block-level token answers
    with the ACTIVE account's token and never reaches `gh auth token` (measured: the mixed
    shape returns the block-level token with no subprocess call, and real gh's own
    `gh auth token` answers the same value). The fall-through is then split in two, and they
    are NOT the same outcome: a KEYRING-BACKED config (no `oauth_token:` in the file) is
    answered the ACTIVE account by `gh auth token --hostname github.com` (per its own docs),
    while a file whose tokens are ALL nested under `users:` is answered NOTHING -- measured
    with gh 2.102.0: `no oauth token found for github.com` on stderr, empty stdout, rc 1 -- so
    `_token()` returns `""` and the REST read refuses with the honest `unavailable` line. That
    refusal is the correct outcome, not a regression, and naming it keeps an operator from
    chasing it as one. The user's own `user:`/`users:` pick is not separately modelled because
    it does not need to be: the block-level token already IS gh's answer. No branch can return
    another account's token, which is the property this function has to hold.
    """
    for var in ("GH_TOKEN", "GITHUB_TOKEN"):
        if os.environ.get(var):
            return os.environ[var]
    # `GH_CONFIG_DIR` is gh's own override and the harness already honours it
    # (`refresh-scout.test.sh`: `${GH_CONFIG_DIR:-$HOME/.config/gh}/hosts.yml`); ignoring it
    # made this fallback silently inert on a box that relocates its config.
    cfg = os.environ.get("GH_CONFIG_DIR") or os.path.expanduser("~/.config/gh")
    host = None
    depth = None      # the current block's DIRECT-child indent (None until its first child)
    try:
        with open(os.path.join(cfg, "hosts.yml"), "r") as fh:
            for line in fh:
                if not line.strip() or line.lstrip().startswith("#"):
                    continue
                indent = len(line) - len(line.lstrip())
                if indent == 0:
                    host = line.split(":", 1)[0].strip()
                    depth = None          # a new block: child depth is not known yet
                    continue
                if host != "github.com":
                    continue
                if depth is None:
                    depth = indent         # FIRST indented line fixes the block's own key depth
                elif indent != depth:
                    continue              # nested map (e.g. `users:`) -- not the block's own key
                s = line.strip()
                if s.startswith("oauth_token:"):
                    return s.split(":", 1)[1].strip().strip("'\"")
    except Exception:
        pass
    try:
        r = subprocess.run([GH, "auth", "token", "--hostname", "github.com"],
                           capture_output=True, text=True, timeout=5,
                           env={**os.environ, **GH_LAYER_ENV} if GH_LAYER_ENV else None)
        if r.returncode == 0:
            return (r.stdout or "").strip()
    except Exception:
        return ""
    return ""


class _SameOriginOnly(urllib.request.HTTPRedirectHandler):
    """Follow a redirect only while it stays on the origin we asked.

    ⛔ THE REQUEST CARRIES THE PAT. urllib's default redirect handler re-sends every header
    except `content-length`/`content-type` to the redirect target, so a 30x naming another
    host would hand `Authorization: bearer <tok>` to that host. GitHub's API does not redirect
    `/pulls` cross-origin today, so this is defence in depth rather than a live leak: the
    property bought is that the token cannot leave the ORIGIN that was asked. Returning None
    makes urllib raise HTTPError, which the caller already turns into None (UNKNOWN, never
    empty). Same-origin redirects are untouched.

    ⛔ AN ORIGIN IS (scheme, host, port), NOT netloc. `netloc` alone would follow a same-host
    `https:` -> `http:` downgrade and re-send the PAT IN CLEARTEXT; the stdlib's own check in
    `HTTPRedirectHandler.http_error_302` only asserts the scheme is one it knows, never that it
    did not change. So compare the pair.
    """

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new, cur = urllib.parse.urlsplit(newurl), urllib.parse.urlsplit(req.full_url)
        if (new.scheme, new.netloc) != (cur.scheme, cur.netloc):
            return None
        return super().redirect_request(req, fp, code, msg, headers, newurl)


_REST_OPENER = urllib.request.build_opener(_SameOriginOnly)


def _rest_open(req, timeout):
    """The single seam every REST read goes through -- ONE opener, so the same-origin
    redirect policy cannot be bypassed by a second call site appearing later."""
    return _REST_OPENER.open(req, timeout=timeout)


def _rest_get_json(url, tok, timeout=REST_TIMEOUT_S):
    """One REST GET. Parsed JSON, or None on ANY failure -- None means UNKNOWN, never empty."""
    req = urllib.request.Request(url, headers={
        "Authorization": "bearer %s" % tok,
        "Accept": "application/vnd.github+json",
        "User-Agent": "beta-progress",
    })
    try:
        with _rest_open(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8", "replace"))
    except Exception as exc:
        # ⛔ A REASON, NOT SILENCE (#2142 review). Still returns None (UNKNOWN, never empty), but a
        # hand run and a CI log now say WHY -- otherwise a real transport defect is
        # indistinguishable from a rate-limit refusal, on every beat, forever. The reason is the
        # exception TYPE plus the URL: the credential lives only in the request header and is
        # never formatted here, which is the one thing this line must not do.
        sys.stderr.write("beta-progress: rest read failed: %s %s\n"
                         % (type(exc).__name__, url.split("?", 1)[0]))
        return None


def _rest_prs(state, limit=100, deadline=None):
    """The PR list over REST -- the fallback when `gh pr list` (GraphQL) is refused.

    Returned in the `gh pr list --json` shape this file consumes: `number`, `title`,
    `headRefName` (<- head.ref), `mergedAt` (<- merged_at). REST `closed` ALSO carries
    PRs closed WITHOUT merging, so the merged list keeps only rows with a non-null
    `merged_at`; counting the others would inflate `merged_today` with PRs that were
    abandoned, which `gh pr list --state merged` never returned.

    PAGING, stated honestly: REST caps `per_page` at 100, while the callers ask for 500
    (open) and 400 (merged) -- so those windows are ceil(limit/100) REQUESTS, not one.
    ⛔ `per_page` is ALWAYS 100, never `min(100, limit - seen)`: GitHub derives a request's
    offset from THAT request's `per_page` ((page-1)*per_page), so shrinking it on the last
    page re-reads rows an earlier page already returned and leaves a hole at the end (a
    limit of 250 returned rows 1-200 + a duplicate of 101-150, missing 201-250 -- measured).
    The final page is trimmed AFTER it arrives instead. It does NOT return the first page as if
    it were the window: a silently short list would under-count `merged_today`, which is the one
    error this fallback must not add.

    ⛔ `limit` BOUNDS ROWS READ, NOT ROWS RETURNED (#2142 review). The loop advances on
    `len(keep)` -- the rows it FETCHED -- so it spends the same row budget `gh pr list --limit`
    spent. In the closed window the rows are then filtered to merges, so `out` holds the merges
    among the `limit` most-recently-updated CLOSED PRs and is SHORTER than `limit` whenever some
    of those rows were closed without merging (measured: 396/400). That is exactly the bound
    stated below, not a short read -- but it is why `merged` here is not interchangeable with
    `gh pr list --state merged --limit 400`, and why the earlier form of this paragraph read as
    a promise the code does not make. Driving the loop on `len(out)` instead would fill the
    window with merges only at the cost of an UNBOUNDED number of requests against the very
    bucket this fallback exists because we are rationing; the disclosed row bound is the honest
    trade, and `merged_today` stays exact while a day's merges (plus the abandoned rows updated
    beside them) fit inside it. A page
    that cannot be read -- or a read whose SHARED deadline (`deadline`, an epoch-seconds
    instant the caller owns; None = no bound) has passed -- returns None for the WHOLE read; a
    partial list is indistinguishable from a complete one at the call site. The deadline is a
    caller-supplied `deadline`, not a per-read budget: `compute()` gives both reads of a pair
    the SAME one, because a per-read budget doubles the phase's worst case inside a tick that
    is killed (see `REST_BUDGET_S`).

    ⛔ THE OFFSET WINDOW IS A LIVE ORDER, SO A ROW THAT MOVES DURING THE READ MAKES THE READ
    UNCERTIFIABLE -- and the read REFUSES rather than returning the window.

    ⛔ WHAT ACTUALLY HAPPENS WHEN THE LIST MOVES, stated the way it was measured rather than the
    way it reads before breakfast. `updated desc` is re-sorted between two requests and each page
    is an OFFSET into it:
      * a PR updated mid-read jumps to offset 0 -- INSIDE the page already read -- so it is
        returned by NO page at all. The row that jumped is the row that goes MISSING.
      * every row below it shifts down by one, so the row that sat at the END of the page just
        read is pushed across the boundary and returned a SECOND time by the next page.
    So the REPEAT names the boundary row, and the ABSENT row is the mover. Measured with the
    shipped loop (400-row window, #150 bumped after page 1): `100` repeated, `150` never
    returned. Returning a deduped list would fix the double-count and leave the missing row
    uncounted -- the class this file refuses to report -- so a repeat returns None for the WHOLE
    read, the same answer as an unreadable or truncated page.

    ⛔ AND THE DETECTOR IS ONE-WAY -- stated, not assumed. A row that LEAVES the list mid-read (a
    PR reopened, a PR deleted) shifts every later row UP by one: nothing repeats, and the row
    that should sit at each later offset is skipped. Measured: 250 closed rows with #101 merged
    today, #5 reopened after page 1 -- the read returns a window with #101 ABSENT and
    `merged_today` 0 where the truth is 1. Offset paging cannot see that from the rows alone; the
    successor detector is the collection's own total from the `Link: rel="last"` header compared
    across the read (both an insertion and a removal change it, and a pure update does not), and
    it is NOT implemented here. Until it is, the honest statement of the bound is: a repeat
    refuses the read; a mid-read REMOVAL can leave it short by one row per removal, it is rare (a
    reopen or delete inside a ~2 s read), and it is the one path where this fallback can
    under-count rather than refuse. Named so the next reader weighs it instead of discovering it.

    ⛔ THE PER-ROW SHAPE CHECK is what makes the detector safe to rely on: any row whose
    `number`, `head` or `merged_at` is not the documented TYPE is an unreadable page (None),
    never a row to hash, dereference or compare.

    `sort=updated&direction=desc` is what makes the window SOUND for `merged_today`, and the
    bound is worth stating exactly: the window is the 400 most-recently-UPDATED **closed** PRs,
    and rows closed without merging are dropped AFTER the window is read. So it is today's
    updated closed PRs (merges plus the abandoned ones updated alongside them), not today's
    merges alone, that must fit in 400 for `merged_today` to be exact. That is a bound, not a
    promise for an arbitrarily large day -- state it rather than assume it.
    """
    tok = _token()
    if not tok:
        return None
    path = "open" if state == "open" else "closed"
    if deadline is None:
        deadline = time.time() + REST_BUDGET_S
    # ⛔ ONE RETRY ON A REPEAT (#2142 review). A repeat proves the list moved DURING the read,
    # and on a box running ~17 concurrent gh clients most movers are churn that a SECOND attempt
    # reads cleanly -- so the read is attempted once more BEFORE it refuses. The cost is bounded
    # and stated: at most ONE extra page-set (ceil(limit/100) requests), spent only on a path that
    # was going to print `unavailable` anyway, and out of the SAME shared `deadline` (so a retry
    # can never outlive the tick). A SECOND repeat still refuses, so a genuinely unstable window
    # never yields a number -- a few requests are cheap, a wrong number is the false line this
    # file exists to prevent.
    for attempt in (1, 2):
        out, seen, page = [], 0, 1
        numbers = set()   # the identity both call sites count; a REPEAT means the list moved
        repeated = False  # set by the repeat detector; only THIS attempt is abandoned by it
        while seen < limit:
            remaining = deadline - time.time()
            if remaining <= 0:
                return None           # budget spent -- refuse, never return a short window
            url = ("https://api.github.com/repos/%s/pulls?state=%s&sort=updated&direction=desc"
                   "&per_page=%d&page=%d" % (REPO, path, REST_PER_PAGE, page))
            raw = _rest_get_json(url, tok, min(REST_TIMEOUT_S, remaining))
            if not isinstance(raw, list):
                return None
            keep = raw[:limit - seen]          # trim the FINAL page to the caller's window
            for p in keep:
                # ⛔ ONE SHAPE CHECK, TYPES INCLUDED. Presence alone is not enough: the repeat check
                # HASHES `number`, the mapping DEREFERENCES `head`, and `compute()` compares
                # `merged_at` -- so `{"number": {}}` raised TypeError out of `sys.exit(main())`
                # and printed NO line at all, breaking the "exit 0 always" promise, while
                # `{"head": "x"}` raised AttributeError. A page whose rows are not the documented
                # shape is an UNREADABLE page, not an empty answer -- `continue` here once consumed
                # a window of unusable rows and returned [], the false zero this file's header says
                # was fixed on 2026-10-01. Refuse the whole read.
                if not isinstance(p, dict):
                    return None
                n = p.get("number")
                if not isinstance(n, int) or isinstance(n, bool):
                    return None
                head = p.get("head")
                if head is not None and not isinstance(head, dict):
                    return None
                if p.get("merged_at") is not None and not isinstance(p.get("merged_at"), str):
                    return None
                # ⛔ AND THE TWO FIELDS THAT REACH A REGEX (#2142 review) -- not only the three that are
                # hashed, dereferenced or compared. `covered()` runs `pat.search()` over `title` and
                # `headRefName`, so `title: {"a": 1}` passed the guard above, arrived at `pat.search()`
                # as a dict in `compute()` and raised TypeError -- which the catch-all below turned into
                # the WHOLE metric reading `unavailable`, instead of this page being REFUSED as
                # unreadable (measured). A row is the documented shape or it is not a row.
                if p.get("title") is not None and not isinstance(p.get("title"), str):
                    return None
                ref = (head or {}).get("ref")
                if ref is not None and not isinstance(ref, str):
                    return None
                # ⛔ THE REPEAT CHECK COMES FIRST -- BEFORE the closed-without-merge filter, and its
                # set holds EVERY row's number, dropped ones included. The repeat is evidence about
                # the LIST, not about which rows count: the row that shifts the live order mid-read
                # is very often an unmerged closed PR (bot churn, a superseded PR closed, a
                # re-labelled one), and filtering it out BEFORE the check hid the only sound signal
                # the read has. Measured: 100 unmerged rows on page 1, then one PR merges (now at
                # offset 0) and an unmerged row repeats on page 2 -- the guard never fired and the
                # read returned 0 rows, a REAL "0 merged today" line while the truth was 1. That is
                # the false zero this file's header says was fixed on 2026-10-01, and the one error
                # this fallback must not add.
                if n in numbers:
                    # ⛔ A REPEAT PROVES THE LIST MOVED DURING THE READ, and a moved list is also a
                    # SHORT one: the row that entered at the head after page 1 was read is at
                    # offset 0 and will be returned by NO page. Deduping would hide the
                    # double-count and leave `merged_today` short by every merge that landed
                    # mid-read -- so this ATTEMPT is abandoned (the retry above), and a SECOND
                    # repeat refuses the whole read.
                    repeated = True
                    break
                numbers.add(n)
                if state != "open" and not p.get("merged_at"):
                    continue      # closed-without-merge is not a merged PR
                out.append({
                    "number": n,
                    "title": p.get("title") or "",
                    "headRefName": ref or "",
                    "mergedAt": p.get("merged_at") or "",
                })
            if repeated:
                break     # the repeat abandoned this attempt -- fetching the next page is pointless
            seen += len(keep)
            if len(raw) < REST_PER_PAGE:
                break             # last page of the collection
            page += 1

        if not repeated:
            return out
    return None


def compute():
    openpr = gh("pr", "list", "--repo", REPO, "--state", "open", "--limit", "500",
                "--json", "number,title,headRefName")
    merged = gh("pr", "list", "--repo", REPO, "--state", "merged", "--limit", "400",
                "--json", "number,title,headRefName,mergedAt")
    # GRAPHQL REFUSED -> TRY REST BEFORE DECLARING THE METRICS UNAVAILABLE. If EITHER read
    # failed, BOTH lists are re-read over REST: once one read has failed the survivor may
    # itself be a degraded read, so pairing a REST count with it would compare two
    # DIFFERENTLY-WRONG reads of one metric. The cross-list consumer that makes that unsafe is
    # `covered()`, which walks `openpr + merged` together (`merged_today` reads `merged` alone).
    # Same source or no metric -- scoped to THIS re-read: where the workspace has the gh layer's
    # REST adapter the OPEN read is already REST while MERGED is GraphQL (see the block above),
    # so this arm claims no more than that a FAILURE never leaves a half-re-read pair.
    if openpr is None or merged is None:
        deadline = time.time() + REST_BUDGET_S      # ONE budget for the pair (see above)
        ro = _rest_prs("open", limit=500, deadline=deadline)
        # Short-circuit: if the open read already failed, the merged one cannot be used by the
        # guard below, so spending the shared budget on it only starves the tick.
        rm = _rest_prs("merged", limit=400, deadline=deadline) if ro is not None else None
        if ro is not None and rm is not None:
            openpr, merged = ro, rm
    if openpr is None or merged is None:
        return None

    today = time.strftime("%Y-%m-%dT00:00:00Z", time.gmtime())
    merged_today = sum(1 for p in merged if (p.get("mergedAt") or "") >= today)

    def covered(n):
        pat = re.compile(r"(?<![\d])%d(?![\d])" % n)
        for p in openpr + merged:
            if pat.search(p.get("headRefName") or "") or pat.search(p.get("title") or ""):
                return True
        return False

    out = {"ts": int(time.time()), "open_prs": len(openpr), "merged_today": merged_today}
    for tier, label in (("p0", "P0-blocker"), ("p1", "P1-severe")):
        # ⛔ STILL GRAPHQL, and NOT covered by the fallback above: where the layer's REST adapter
        # is absent (#1978 -- the cells) a refusal here returns None and the WHOLE line still
        # reads `unavailable`, after the PR lists were paid for. Named as a residual on #2139
        # rather than silently widened here; `merge-queue.py`'s own `--state merged` read is the
        # same class (it is what prints `VERDICT=UNKNOWN (merge-rate read failed)`).
        rows = gh("issue", "list", "--repo", REPO, "--label", label, "--state", "open",
                  "--limit", "300", "--json", "number")
        if rows is None:
            return None
        have = sum(1 for r in rows if covered(r["number"]))
        out[tier] = {"open": len(rows), "with_pr": have, "without": len(rows) - have}
    return out


def main():
    data = None
    try:
        with open(CACHE) as fh:
            cached = json.load(fh)
        # ⛔ A CACHE THIS VERSION CANNOT RENDER IS NOT A CACHE. The cache-hit path is the one
        # taken on ~15 beats out of 16 (TTL 1800 s, heartbeat every ~2 min), and it is ABOVE the
        # `compute()` guard below -- so a cache written by another schema, or truncated, raised
        # KeyError 'p0' out of `sys.exit(main())` and printed NOTHING (measured), which is the
        # very failure the guard exists to prevent.
        # ⛔ AND THE CHECK MUST REACH WHAT THE RENDER READS, not just the top-level keys: a
        # `{"ts": now, "p0": {"open": 1}}` passes a key-presence test, then fails `p0["with_pr"]`
        # in the render -- which the guard below turns into `unavailable`. That is a line, but it
        # is the WRONG line (nothing was read) and it repeats for the rest of the TTL, because the
        # bad cache is never replaced (measured: 3 consecutive beats, `compute()` never called).
        # So the predicate mirrors exactly what the render dereferences: `ts` a number, the two
        # counters ints, each tier a dict carrying three ints. Anything else is a MISS -- one
        # refresh -- and the store path then overwrites the bad file.
        if not isinstance(cached, dict) or not {
                "ts", "p0", "p1", "open_prs", "merged_today"} <= set(cached):
            cached = None
        elif not (isinstance(cached.get("ts"), (int, float))
                  # ⛔ A NUMBER IS NOT A TIMESTAMP. `time.localtime()` raises OverflowError on a
                  # numeric-but-unrenderable `ts` (measured: `1e30`), and a FUTURE `ts` renders as
                  # `-Nm ago`; both passed a bare isinstance test, so the cache was accepted as
                  # FRESH, the render guard printed `unavailable`, and because `main()` returns
                  # before `compute()` the bad file was NEVER replaced -- the whole-TTL wrong line
                  # this nested check exists to close, reached through the one field it never
                  # bounded (measured: 3 consecutive beats, `compute()` never called). Bounding it
                  # makes such a cache a MISS, so one refresh overwrites it.
                  and 0 < cached["ts"] <= time.time() + CACHE_TS_SKEW_S
                  and _count(cached.get("open_prs"))
                  and _count(cached.get("merged_today"))
                  and all(isinstance(cached.get(tier), dict)
                          and all(_count(cached[tier].get(k))
                                  for k in ("open", "with_pr", "without"))
                          for tier in ("p0", "p1"))):
            cached = None
        if cached is not None and time.time() - cached.get("ts", 0) < TTL:
            data = cached
    except Exception as exc:
        # ⛔ NOT SILENT (#2142 review). The beat discards stderr, so this costs nothing where it
        # matters and is the ONLY reason an operator hand-running the script gets -- a genuine
        # defect in the fallback was otherwise indistinguishable from "GraphQL refused", which is
        # the silence this PR exists to remove. The message is the exception's own text (a
        # JSONDecodeError carries a position, never the payload), so it can leak no data.
        sys.stderr.write("beta-progress: cache unreadable: %s: %s\n"
                         % (type(exc).__name__, exc))
    if data is None:
        # ⛔ EXIT 0 ALWAYS (module header), AND A LINE ALWAYS. `compute()` is a pile of
        # compares, hashes and dereferences over data an API returned; an unexpected shape must
        # reach the operator as the honest `unavailable` line, not as a traceback to /dev/null.
        # Measured before this guard: a page whose `number` was an object raised TypeError out of
        # `sys.exit(main())` and printed NOTHING, while the `DELIV=$(...)` capture in
        # `orchestrator-heartbeat.sh` sends stderr to /dev/null -- the exact "reports nothing
        # instead of the line it can prove" failure this file exists to avoid. Cited by NAME for
        # the reason stated at `REST_TIMEOUT_S` above (#2142 review): the number this used to name
        # is a line that moves. The row guards above make that payload unreachable; this keeps a
        # FUTURE one from taking the beat's measurement down silently.
        try:
            data = compute()
        except Exception:
            # ⛔ AND THE REASON GOES TO STDERR (#2142 review). `compute()` has no other reporter:
            # a traceback here is discarded by the beat and invaluable in a hand run or CI log, and
            # it changes no stdout contract. `format_exc` prints source lines, not locals, so no
            # credential reaches it.
            sys.stderr.write("beta-progress: compute failed:\n%s" % traceback.format_exc())
            data = None
        if data is None:
            print("DELIVERY: unavailable (metrics read failed)")
            return 0
        try:
            with open(CACHE, "w") as fh:
                json.dump(data, fh)
        except Exception:
            pass
    # ⛔ Print the age ALWAYS. Omit it and a 50-minute-old figure reads as live. And render
    # inside the same guard: `%d` on a cached `"many"` raised TypeError and printed nothing, so
    # the belt covers the FORMATTING too, not just the fetch.
    try:
        p0, p1 = data["p0"], data["p1"]
        ts = data.get("ts", 0)
        # ⛔ NEVER A NEGATIVE AGE. `CACHE_TS_SKEW_S` deliberately admits a few seconds of FUTURE
        # `ts` (writer/reader clock skew is real), but `int((now - ts) / 60)` then renders
        # `-1m ago` on the owner's line -- measured: `ts = now+120` -> `-1m ago`, `now+299` ->
        # `-4m ago`. Clamped rather than refused: the tolerance exists for the TTL comparison,
        # and a future stamp inside that band is still a usable cache.
        age_m = max(0, int((time.time() - ts) / 60))
        stamp = time.strftime("%H:%M", time.localtime(ts)) if ts else "unknown"
        line = ("DELIVERY [as of %s, %dm ago]: P0 %d open (%d with PR, %d NONE)"
                " | P1 %d open (%d with PR, %d NONE)"
                " | %d open PRs, %d merged today"
                % (stamp, age_m,
                   p0["open"], p0["with_pr"], p0["without"],
                   p1["open"], p1["with_pr"], p1["without"],
                   data["open_prs"], data["merged_today"]))
    except Exception:
        print("DELIVERY: unavailable (metrics read failed)")
        return 0
    print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
