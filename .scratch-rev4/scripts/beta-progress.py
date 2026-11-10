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

DEFAULT_REPO = "daniel-ospina/tortoise"
REPO = DEFAULT_REPO
# ⛔ `--repo` EXISTS BECAUSE `fleet_census(repos)` CANNOT BE A WRAPPER OF A MODULE THAT TAKES NO
# ARGUMENTS (#3382 row 4, docs/ops/orchestrator-mcp-inventory.md §5.0 V4 / §7.7). It is a PARAMETER on
# the existing derivation, never a second one: `compute()` still owns every P0/P1/coverage rule and
# reads this global. Defaulted to the same repo, so the beat's call (which passes no argv) is unchanged.
#
# ⛔ AND `--repo` MUST NOT BE ABLE TO RELABEL ANOTHER REPO'S NUMBERS. The cache is one file on one box
# and the payload it stores used to carry no repo identity at all, while the render stamped
# `payload["repo"] = REPO` on whatever it read. So for the whole TTL (~15 beats of 16) a
# `--repo owner/other` call returned the CACHED tortoise figures labelled `owner/other` — a figure
# attributed to a repo it was never measured on — and, in the other direction, a missing call wrote
# other-repo numbers into the shared file that the no-arg beat then rendered as tortoise's `DELIVERY:`
# line. `mcp-servers/orchestrator/server.py::_census` is exactly that caller: it fans out over
# `repos` with `["--repo", repo, "--json"]`. Three things make it impossible: the payload NAMES the
# repo it measured, a cache whose `repo` does not match is a MISS, and the file is keyed per repo.
# ⛔ (a duplicate `REPO = "daniel-ospina/tortoise"` stood here after the merge — identical
# value, so no behaviour changed, but two definitions of one name is how a future edit changes one and
# not the other, and `_cache_path()` keys off `REPO == DEFAULT_REPO`.)
# ⛔ THE TRACKER IS NOT THE ONLY REPO A FIX LANDS IN (tortoise#10951). `REPO` is where the ISSUES
# live; it is not where every fix is written. This backlog is worked by the harness, whose PRs are
# under `agent-infra`, so a single-repo PR read cannot see the PR a fix actually lives in. This
# metric decides what the fleet builds next and is the number the owner reads for "beta ships when
# p0/p1 are merged", so an absent PR may only ever come from a repo that ANSWERED.
# ⛔ WHAT WAS MEASURED, AND WHAT WAS NOT — the first draft of this comment over-claimed it, and
# tortoise#11020's own correction comment is the record. #10114 is NOT reported `without_pr` today:
# it is covered BY ACCIDENT, by a MERGED tracker PR (#10250, merged 2026-10-29) whose title carries
# `10114`. That accident is bounded -- the merged window is the newest 400 rows (#9658..#11039 on
# 2026-11-05) -- so when #10250 scrolls out, #10114 becomes `without_pr` WHILE agent-infra#3368
# (`fix(reaper): the harness PIN TREE is a holder, not residue (#10114)`) is still OPEN, and a lane
# reads "no PR, you are the path" about live work. Measured flips from this change on the day of
# authoring: ZERO, and RE-MEASURED as zero later the same day by running the shipped module twice
# with `FIX_REPOS` widened and narrowed -- the tier numbers are byte-identical, because every
# tracker unit that currently has a fix-repo PR also has a tracker PR. This is therefore a DECAY
# fix: it removes the accident that is hiding the defect, and prevents the future mis-charter; it
# is not correcting a wrong number today.
# ⛔ A CLAIM THAT WAS CHECKED AND RETRACTED, kept because it reads true: an earlier version of this
# comment said #10951 had flipped today (it appears covered by agent-infra#3467). It has not --
# tortoise#11027, OPEN since 04:44, already covered it before #3467 was created at 08:05, so the
# flip belonged to a TRACKER PR and this change made no difference to that number.
# ⛔ AND #10114 IS NOT COVERED ONLY BY THE ACCIDENT -- WITH THIS CHANGE APPLIED. The #10250 accident
# is what covers it on `main`; here the fix-repo rows (#3368's bare `(#10114)`, #3333, #3313) cover
# it directly, which is the whole point. Delete #10250 from the merged window and it still reads
# `with_pr` under this change, and stops reading so on `main`.
# ⛔ `open_prs` keeps its old meaning (the TRACKER's open PRs) — the extra repos feed `covered()`
# ONLY, so widening the gap count cannot silently move the headline number.
FIX_REPOS = (REPO, "daniel-ospina/agent-infra")
# ⛔ DERIVED, NOT FROZEN (merge of #3382's `--repo` with #10951's FIX_REPOS). `FIX_REPOS` is built from
# `REPO` at import, and `--repo` reassigns `REPO` at runtime — so without this, `--repo owner/other`
# would keep reading FIX-REPO PRs for tortoise while labelling them `owner/other`: exactly the
# attribution failure the `--repo` comment above exists to make impossible. `main()` re-derives it.
_FIX_REPOS_TAIL = "daniel-ospina/agent-infra"


def _derive_fix_repos(repo):
    """Repos a fix for <repo>'s issues may land in.

    ⛔ THE EXTRA SEPARATE REPO IS TORTOISE-BACKLOG-SPECIFIC (review cycle 7, P2). Re-deriving only the
    HEAD kept a hardcoded tail, so `--repo owner/other` returned `('owner/other',
    'daniel-ospina/agent-infra')` — counting agent-infra PRs as coverage for ANOTHER repo's issues,
    which is the attribution failure this module's `--repo` comment exists to forbid, relocated. The
    tail applies only when the tracker IS the one the tail was measured for.
    """
    if repo == DEFAULT_REPO:
        return (repo, _FIX_REPOS_TAIL)
    return (repo,)
CACHE = os.path.expanduser("~/.pi/agent/state/beta-progress.json")


def _cache_path():
    """The cache file for the CURRENT `REPO`.

    The DEFAULT repo keeps the historical path byte-for-byte, because that file has other READERS
    (`scripts/merge-queue.py` opens it directly) and the beat that writes it passes no `--repo`. Any
    other repo gets its own file, so a fan-out cannot overwrite the beat's state.
    """
    if REPO == DEFAULT_REPO:
        return CACHE
    root, ext = os.path.splitext(CACHE)
    return "%s.%s%s" % (root, REPO.replace("/", "__"), ext or ".json")
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


# ⛔ ONE CLOCK FOR THE WHOLE READ PHASE (see `PHASE_BUDGET_S`). `compute()` opens it and restores
# the previous value when it returns; `gh()` derives its child's timeout from what is LEFT of it.
# None means "no phase in flight", so a direct call (a test, a REPL) keeps the old fixed timeout.
# ⛔ AND IT IS MEASURED ON `time.monotonic()`, NOT ON THE WALL CLOCK (#3457 review round 6). A
# budget answered by `time.time()` is answered by a clock that STEPS: an NTP correction or a resume
# from sleep moves it, and the two directions are both wrong — a forward step truncates every
# remaining read (a spurious `unavailable`), and a backward step GROWS what is left, so the phase
# outlives its own constant, which is the one property it exists to hold. Every other bounded read
# in this tree already budgets on the monotonic clock (`turn-end.py`'s `BOUNCE_BUDGET_S`,
# `pr-doctor.py`'s `CONFIRM_WINDOW_S`, `merge-queue.py`), and this is the same kind of number.
# The WALL clock stays where the value is a TIMESTAMP (`out["ts"]`, the cache's age) — those must
# match the reader's calendar, not the process's uptime.
_PHASE_DEADLINE = None


class _phase_clock:
    """Bound every `gh()` inside the block by ONE deadline, and restore what was there before."""

    __slots__ = ("_prev",)

    def __enter__(self):
        global _PHASE_DEADLINE
        self._prev = _PHASE_DEADLINE
        _PHASE_DEADLINE = time.monotonic() + PHASE_BUDGET_S
        return _PHASE_DEADLINE

    def __exit__(self, *_exc):
        global _PHASE_DEADLINE
        _PHASE_DEADLINE = self._prev
        return False


def gh(*args):
    """Return parsed JSON, or None on ANY failure. None means UNKNOWN, never empty.

    ⛔ BOUNDED BY THE PHASE CLOCK WHEN ONE IS OPEN. Each read used to get a flat 120 s, so the
    phase's worst case grew with the NUMBER of reads -- which is exactly the shape that makes
    adding a repo a regression. A spent clock REFUSES rather than spawning: `None` is the honest
    `unavailable`, and `unavailable` is a line, where a killed tick prints nothing at all.
    """
    tmo = 120.0
    if _PHASE_DEADLINE is not None:
        left = _PHASE_DEADLINE - time.monotonic()
        if left <= 0:
            return None
        tmo = min(tmo, left)
    try:
        r = subprocess.run([GH, *args], capture_output=True, text=True, timeout=tmo,
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
# WHY. BOTH LISTS OF A PAIR come from `gh pr list --json` — the TRACKER pair here, whose fallback
# is inline in `_compute`, and (since #3457) each fix repo's pair, which goes through `_repo_prs`
# (ONE function for all of them). Where the workspace has the gh layer's REST
# adapter (`$O/gh-rest`, #1959) the OPEN read is already served over REST — `number,title,headRefName`
# are all in its PR_FIELDS — but `mergedAt` is NOT, so the MERGED read delegates to the real gh,
# which is GRAPHQL. On the cells `$O/gh-rest` is absent unless the pinned harness ships it AND a seeding
# verb put it there — `cloud-cell-supervisor.sh start` (it runs `harness_apply` then `seed_and_stamp`)
# and `deploy-crossbox.sh` DO seed it since #2039, while `check` only PROBES and refuses — so a cell
# whose pin carries the adapter serves the OPEN read over REST too, and a cell whose pin predates it
# (`check` warns) stays on GraphQL.
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
# ⛔ ONE BUDGET FOR THE REST PHASE, not per read: `compute()` creates the deadline and hands it to
# the tracker PAIR *and* to every fix-repo read (`FIX_REPOS`) — FOUR reads at 500/400 rows, up to 18
# pages (36 REQUESTS if every read takes its one repeat-triggered retry, which the SAME 30 s
# deadline still holds: 36 x the measured 0.43 s/call = 15.5 s). 30 s is ~4x the measured latency
# (0.43 s/call, ~7.7 s for 18 pages) and sits inside the
# tick's 40-90 s of residual slack. A PER-READ budget is what this rules out: four 30 s reads is
# 120 s of REST alone, which spends the slack and then some.
# ⛔ AND THE DISCLOSED COST OF THE WIDER READ IS IN THIS BUDGET, NOT IN A LARGER ONE. The fix-repo
# pair adds ~9 more pages inside the SAME 30 s, so the per-page tolerance on a GraphQL-refusing box
# halves: ~3.3 s/page before this change, ~1.67 s/page after, against a measured 0.43 s/call. It is
# accepted rather than raised because a bigger REST budget pushes the phase past the slack the
# paragraph above measures, which is the failure this budget exists to prevent — and because the
# direction it fails in is `unavailable` (a line), never a SHORT WINDOW (a wrong number).
REST_BUDGET_S = 30
# ⛔ AND REST IS NOT THE WHOLE PHASE. `gh()` reads are NOT on `rest_deadline`; they were bounded
# only by `gh()`'s own flat 120 s, so the phase's worst case was (PR lists + issue lists) x 120 s =
# 480 s BEFORE this change — already past the 390 s `run_bounded` kill (`scripts/heartbeat-loop.sh`:
# `TARGET` 540 - `IN_PASS_RESERVE` 150). The two fix-repo PR lists added here take it to 720 s: the
# tick is killed and the box prints NOTHING, the one outcome the shared budget exists to prevent.
# So ONE clock bounds the WHOLE phase: `compute()` opens it (`_phase_clock`), `gh()` derives every
# child's timeout from what is LEFT of it, `_rest_prs` clamps its deadline to it, and `_token()`'s
# own `gh auth token` spawn draws on it too (`_token` is called by `_rest_prs` BEFORE the deadline
# check, so a spent clock has to refuse there as well). The bound is a CONSTANT of the phase —
# adding a fix repo cannot EXTEND it, it only spends it.
# ⛔ SIZED FROM THE PHASE'S OWN SLACK — AND THAT IS NOT THE SAME NUMBER AS A READ'S LATENCY. An
# earlier draft sized this at 100 s by borrowing `objective.py`'s `QUEUE_READ_MAX_S`, and it was
# wrong twice over: (a) 100 s sits ABOVE the 40-90 s this step actually has left inside the tick, so
# the clock could never fire before `run_bounded` killed the tick — it was an INERT ENFORCER that
# looked like protection; and (b) it borrowed a bound for ONE read to cover SIX (two tracker PR
# lists + two fix-repo PR lists + two issue lists), giving each an effective 16.7 s.
# 60 s is chosen from the slack band this step really has, and the band is stated with its FLOOR
# rather than only its ceiling: the step holds 40-90 s at the end of a normal pass, and the harness
# floors a tick's residual at 20 s (the `remaining()` helper in `heartbeat-loop.sh`: `[ "$r" -lt 20 ]
# && r=20`). So the
# honest claim is: **the clock FIRES whenever at least 60 s remain**, which is the band's middle and
# up — and below that the tick can still be killed with no line, because a bound cannot fire before
# the kill that precedes it. What the constant must NOT do is exceed the band's TOP, where it would
# be inert in every case (that was the 100 s draft).
# ⛔ AND ITS MARGIN OVER THE MEASURED PHASE IS ~3.5x, NOT THE 5-6x THIS SAID FIRST (#3457 review
# round 16). The retracted figures ("0.7-3.3 s each, ~8-12 s end to end") came from ONE quiet run.
# RE-MEASURED at this head on the box this ships from, the same six reads took **17.4 s end to end
# with per-read 1.2-7.0 s** -- two of the six ABOVE the 3.3 s ceiling the old sentence stated -- so
# 60 s is a real bound on a quiet box and a LOAD-BOUNDED one on a busy box. It is still the right
# size (under the band's 90 s top, exactly 2x `REST_BUDGET_S` so the REST arm fits inside it, and a
# late fire degrades to `unavailable` -- a line -- rather than to a killed tick, which prints
# nothing), but a margin argued from a single quiet measurement is how an INERT constant gets
# defended, so the spread is stated as measured instead of as its best case.
# ⛔ THE RESIDUAL, STATED RATHER THAN BOUNDED AWAY: `objective.py` measures 63 s for ONE `gh` read at
# 13 lanes, and SIX such reads (378 s) cannot fit this step's slack in ANY implementation — that is a
# pre-existing property of the heartbeat, not something this constant can fix. What the clock buys is
# that the phase's worst case no longer GROWS with `FIX_REPOS`, and that the slow case yields a line
# instead of a killed tick.
# ⛔ WHY THE WHOLE LINE AND NOT "DEGRADE TO THE TRACKER PAIR": the tracker pair IS already in hand
# when the fix-repo reads run, so a partial answer is possible. It is refused on purpose. A
# tracker-only count reports `without_pr` for every unit whose fix repo went unread -- a FALSE GAP,
# the exact mis-charter this change exists to remove -- so an unread phase must say so, not guess.
PHASE_BUDGET_S = 60


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
    # ⛔ THE PHASE CLOCK BOUNDS THIS SPAWN TOO (#3457 review round 5). `gh auth token` is a `gh`
    # CHILD on a flat 5 s, and `_rest_prs` resolves the token BEFORE it looks at its deadline, so
    # without this the phase's worst case was `PHASE_BUDGET_S + 5 s` on exactly the gh-refusing box
    # the clock exists for -- and "ONE clock bounds the WHOLE phase" was false by those 5 s.
    # A SPENT clock REFUSES (`""` -> the REST read returns None -> the honest `unavailable`):
    # spending the last seconds of a pass on a credential lookup is how the tick outlives its kill.
    tmo = 5.0
    if _PHASE_DEADLINE is not None:
        left = _PHASE_DEADLINE - time.monotonic()
        if left <= 0:
            return ""
        tmo = min(tmo, left)
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
                           capture_output=True, text=True, timeout=tmo,
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


def _rest_prs(state, limit=100, deadline=None, repo=None):
    """The PR list over REST -- the fallback when `gh pr list` (GraphQL) is refused.

    `repo` defaults to the TRACKER. It is a parameter because the gap count also reads the
    repos a fix lands in (FIX_REPOS), and those reads need the SAME second source: the
    measured #2139 refusal is a SECONDARY-limit one, so every `gh pr list` on the box is
    refused at once and a fix repo with no REST fallback would take the whole DELIVERY line
    down -- the exact line this fallback exists to keep printing.
    ⛔ AND THE URL MUST BE REBUILT FROM IT. This path used `REPO` directly, so a caller that
    passed a repo without changing that line would be handed the TRACKER's `/pulls` under
    the fix repo's name -- a wrong list that still looks complete.

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
    that cannot be read -- or a read whose SHARED deadline (`deadline`, an instant on the SAME
    clock as `time.monotonic()`, which is what every caller here uses; `None` opens a budget
    clamped to `min(now + REST_BUDGET_S, _PHASE_DEADLINE)` — it is NOT "unbounded", and a SPENT
    phase clock refuses outright) has
    passed -- returns None for the WHOLE read; a
    partial list is indistinguishable from a complete one at the call site. The deadline is a
    caller-supplied `deadline`, not a per-read budget: `compute()` gives the tracker PAIR **and
    every fix-repo read** the SAME one, because a per-read budget MULTIPLIES the phase's worst
    case by the number of reads, inside a tick that is killed (see `REST_BUDGET_S`).

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
    # ⛔ A FALSY `repo` IS REFUSED, NOT SUBSTITUTED (#3457 review). `None` is the documented
    # "the tracker" default; anything else that is not a well-formed `owner/name` — an empty
    # string from a malformed config, say — used to fall through `repo or REPO` and hand back the
    # TRACKER's `/pulls` under the caller's repo name: a wrong list that still looks complete, which
    # is the one thing this path may not do. The caller validates `FIX_REPOS` too, but a callee that
    # only holds the hazard when its caller remembers is not holding it at all.
    if repo is None:
        repo = REPO
    elif not isinstance(repo, str) or repo.count("/") != 1 or not all(repo.split("/")):
        return None
    path = "open" if state == "open" else "closed"
    if deadline is None:
        # ⛔ AND `None` IS BOUNDED BY A LIVE PHASE CLOCK TOO (#3457 review round 21). The default
        # used to be a bare `REST_BUDGET_S`, so a caller that omitted the deadline got 30 s
        # REGARDLESS of a phase clock that had 2 s left -- and the module-level claim that
        # "ONE clock bounds the WHOLE phase" then held only while every caller remembered to clamp
        # (it is `_compute` that clamps: `min(rest_deadline, _PHASE_DEADLINE)`). A bound a callee
        # only holds when its caller remembers is not a bound, which is the same rule this function
        # already applies to `repo` above. Both shipped call sites pass the clamped deadline, so
        # this changes no current read; it removes the trap for the NEXT one.
        deadline = time.monotonic() + REST_BUDGET_S
        if _PHASE_DEADLINE is not None:
            if _PHASE_DEADLINE - time.monotonic() <= 0:
                return None           # a spent phase clock REFUSES rather than opening a budget
            deadline = min(deadline, _PHASE_DEADLINE)
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
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return None           # budget spent -- refuse, never return a short window
            url = ("https://api.github.com/repos/%s/pulls?state=%s&sort=updated&direction=desc"
                   "&per_page=%d&page=%d" % (repo, path, REST_PER_PAGE, page))
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


def _shape_pr_rows(rows, state):
    """THE ONE SHAPE GATE EVERY PR LIST GOES THROUGH: well-formed rows, or the read FAILED.

    ⛔ `gh` CAN EXIT 0 WITH A JSON OBJECT (`{"message": "Not Found"}`) OR A LIST OF NON-DICTS, and
    a dict is TRUTHY and sized — so an `is None` test never fires on it, `covered()` calls `.get()`
    on a str and RAISES, and `len()` turns the payload into a NUMBER. Four rounds of review each
    found one more consumer that had only half this rule (#3457 rounds 9-12): the fix-repo list,
    then the tracker's list-level check, then the fix-repo's non-list path, then the ISSUE rows.
    Every read that produces rows is gated by it OR by `_rest_prs`'s own copy, whichever is
    upstream: the two tracker PR lists and the two fix-repo lists call it here (the fix-repo path
    BEFORE its REST fallback and again on the fallback's answer), the tier reads call it, and the
    TRACKER's REST fallback reaches it only through `_rest_prs`, which validates as it pages.
    ⛔ IT IS NOT THE ONLY COPY OF THE PER-ROW RULE, and saying so would be false: `_rest_prs` keeps
    its own, because it validates AS IT PAGES — a bad row on page 3 must refuse before page 4 is
    paid for, which a post-hoc gate cannot do. That copy is upstream and stricter in timing, not a
    second policy; this one is what every caller gets whatever the transport.

    ⛔ PRESENCE IS NOT SHAPE — TYPES INCLUDED, and that is why this is not `isinstance(rows, list)`:
    `number` must be an int that is not a bool (a bool IS an int, and `covered(True)` would search
    for `1`), the two fields `covered()` REGEXES must be strings when present, and in a MERGED
    window `mergedAt` must be PRESENT and a NON-EMPTY string (`""` and `null` both collapse with
    `(p.get("mergedAt") or "")` and report `merged_today: 0` — a number, not a refusal).
    ⛔ AND `state` IS THE ONE THING THE CALLER KNOWS: an OPEN list carries no `mergedAt`, so
    demanding the key there would refuse every valid read. The tier rows pass `"open"` and rely on
    the `number` check, which is exactly the field `covered(r["number"])` indexes them by.

    Returns the rows, or None — never a partial list: a short window is indistinguishable from a
    complete one at every call site, which is the error class this file exists to refuse.
    """
    if not isinstance(rows, list):
        return None
    for r in rows:
        if not isinstance(r, dict):
            return None
        n = r.get("number")
        if not isinstance(n, int) or isinstance(n, bool):
            return None
        # ⛔ THE TWO FIELDS THAT REACH A REGEX. `covered()` runs `pat.search()` over both, so a
        # non-str here is a TypeError out of the WHOLE metric, not a row to skip.
        for key in ("title", "headRefName"):
            if r.get(key) is not None and not isinstance(r.get(key), str):
                return None
        # ⛔ AND IN A MERGED WINDOW THE KEY IS MANDATORY (#3457 review round 13). The lenient form
        # ("a string WHEN PRESENT") let a merged row with no `mergedAt` — or an explicit `null` —
        # through, and `merged_today` then UNDER-COUNTS through `(p.get("mergedAt") or "")` instead
        # of the read refusing: measured, a merged window of one such row yields
        # `merged_today: 0` and CACHES it for the TTL. Every row of a `--state merged` read is
        # merged by construction and `_rest_prs` filters unmerged rows out, so an absent key is a
        # PARTIAL payload, not a shape we can render. (The `open` state is the exception that
        # justifies the split: an OPEN list carries no `mergedAt` at all.)
        if state != "open" and not (isinstance(r.get("mergedAt"), str) and r.get("mergedAt")):
            return None
    return rows


def _repo_prs(repo, state, limit, deadline):
    """One repo's PR list: GraphQL first, REST second, then THE shape gate.

    ⛔ EVERY FIX-REPO READ NEEDS THE SECOND SOURCE TOO (#2139). The measured refusal is a
    SECONDARY-limit one, so every `gh pr list` on a box is refused at once; a fix-repo read with no
    REST fallback would take down a DELIVERY line whose tracker read had already succeeded.
    ⛔ AND A MALFORMED BUT ANSWERED READ IS NOT A LIST. `gh` can exit 0 with a JSON OBJECT
    (`{"message": "Not Found"}`) or a list of non-dicts. `covered()` then calls `.get()` on a str
    and RAISES, `main()` catches it, and the box prints a traceback and `unavailable` on EVERY
    refresh for as long as that payload persists -- a whole metric lost to one repo's odd answer.
    ⛔ SO THE SHAPE IS NORMALISED BEFORE THE FALLBACK, not after it (#3457 review round 11). It
    used to be checked only on the way OUT, so a non-list answer returned None without ever asking
    the second source -- the exact "one repo's odd answer costs the whole line" failure this
    function's own first paragraph says it exists to prevent. The tracker path already ordered it
    this way; now all four lists do.
    """
    fields = ("number,title,headRefName" if state == "open"
              else "number,title,headRefName,mergedAt")
    rows = _shape_pr_rows(
        gh("pr", "list", "--repo", repo, "--state", state, "--limit", str(limit),
           "--json", fields), state)
    if rows is None:
        rows = _shape_pr_rows(
            _rest_prs(state, limit=limit, deadline=deadline, repo=repo), state)
    return rows


def compute():
    """The metric, or None. Every read inside it shares ONE clock (see `PHASE_BUDGET_S`)."""
    with _phase_clock():
        return _compute()


def _compute():
    # ⛔ THE TRACKER LISTS GO THROUGH THE SAME GATE AS EVERY OTHER LIST (#3457 review round 11).
    # This was only a LIST-level check for one round, which left two members of the class open: a
    # list of non-dicts (`["nope", None, 42]`) became `3 open PRs` with both tier lists empty (so
    # `covered()` never ran to raise), and a falsy non-str `mergedAt` silently under-counted
    # `merged_today`. Both are refused now, by the predicate the fix-repo path already used.
    openpr = _shape_pr_rows(
        gh("pr", "list", "--repo", REPO, "--state", "open", "--limit", "500",
           "--json", "number,title,headRefName"), "open")
    merged = _shape_pr_rows(
        gh("pr", "list", "--repo", REPO, "--state", "merged", "--limit", "400",
           "--json", "number,title,headRefName,mergedAt"), "merged")
    # ⛔ AN ANSWERED READ THAT IS NOT A LIST IS A FAILED READ, FOR THE TRACKER TOO (#3457 review
    # round 10). `gh` can exit 0 with a JSON OBJECT (`{"message": "Not Found"}`), and a dict is
    # TRUTHY and sized, so the `is None` tests below never fire. Measured on the shipped module: an
    # open read answered `{"message": "Not Found"}` printed `... | 1 open PRs, 0 merged today`
    # (`len(dict)` == 1), and the REST fallback never engaged. `_shape_pr_rows` normalises it (and
    # the per-row types) BEFORE the fallback, so ONE rule covers all four PR lists.
    # (The shape is applied above, at the read itself — this comment records why.)
    # GRAPHQL REFUSED -> TRY REST BEFORE DECLARING THE METRICS UNAVAILABLE. If EITHER read
    # failed, BOTH lists are re-read over REST: once one read has failed the survivor may
    # itself be a degraded read, so pairing a REST count with it would compare two
    # DIFFERENTLY-WRONG reads of one metric. The cross-list consumer that makes that unsafe is
    # `covered()`, which walks `openpr + merged + fix_prs` together (`merged_today` reads `merged`
    # alone) -- THREE lists since #3457, which is why the fix-repo lists' per-state fallback is
    # disclosed in the docs as a TRADE and not as a second half of this guarantee.
    # Same source or no metric -- scoped to THIS re-read: where the workspace has the gh layer's
    # REST adapter the OPEN read is already REST while MERGED is GraphQL (see the block above),
    # so this arm claims no more than that a FAILURE never leaves a half-re-read pair.
    # ⛔ ONE BUDGET FOR THE WHOLE REST PHASE, not one per read (see the invariant above). The
    # tracker pair and every fix-repo read draw on the SAME deadline: a per-read budget would let a
    # refusing box MULTIPLY the phase's worst case by the read count and outlive the tick's own
    # `run_bounded` kill -- which prints NOTHING, the failure that budget exists to prevent. With
    # one extra repo this is FOUR reads, not the two the earlier form of this comment described.
    rest_deadline = time.monotonic() + REST_BUDGET_S
    if _PHASE_DEADLINE is not None:
        # ⛔ THE REST BUDGET IS A CHILD OF THE PHASE CLOCK, not a peer of it: a slow `gh` read has
        # already spent part of the phase, and REST may not spend that part a second time.
        rest_deadline = min(rest_deadline, _PHASE_DEADLINE)
    if openpr is None or merged is None:
        deadline = rest_deadline                    # the pair shares it
        ro = _rest_prs("open", limit=500, deadline=deadline)
        # Short-circuit: if the open read already failed, the merged one cannot be used by the
        # guard below, so spending the shared budget on it only starves the tick.
        rm = _rest_prs("merged", limit=400, deadline=deadline) if ro is not None else None
        if ro is not None and rm is not None:
            openpr, merged = ro, rm
    if openpr is None or merged is None:
        return None

    # ── the other repos a fix may land in (see FIX_REPOS) ─────────────────────────────
    # ⛔ THE WINDOW IS OPEN **AND** MERGED, and the merged half is not symmetry for its own sake.
    # A PR in a fix repo does not close a TRACKER issue (cross-repo `Closes` does not close it), so
    # the issue stays open AFTER the fix merges. Reading only OPEN rows would report #10114 as
    # `without_pr` the moment agent-infra#3368 merged -- "no PR, you are the path" about work that
    # had LANDED. That is strictly worse than the open case this change exists to fix: rebuilding an
    # open PR wastes a lane, rebuilding a landed fix ships nothing, and the error would grow
    # monotonically as fixes complete. The tracker's own list counts merged rows for exactly this
    # reason, so the two lists now agree on what coverage means.
    # ⛔ AND `covered()` CANNOT TELL WHICH REPO A ROW CAME FROM, so a fix repo's bare `#N` is read
    # as the TRACKER's issue N. That fails OPTIMISTICALLY -- the issue reads covered and nobody
    # builds it -- so the risk is stated as MEASURED rather than as it first read:
    #   * 2026-11-05 against the live lists (agent-infra open ~46 + merged 400, window #1986..#3483):
    #     TWO colliding tracker units, #10114 and #10951, and BOTH are TRUE covers. Zero false
    #     covers that day -- but that is a fact about WHICH ROWS THE WINDOW RETURNED, not a property
    #     of this change, so it is not a guarantee to lean on.
    #   * The risk is STRUCTURAL and already IN RANGE, not "below the current numbering". agent-infra
    #     is numbered in the SAME sequence as tortoise and its newest PR is in the #34xx range, so
    #     the LOW end of the open tortoise backlog (#2281, #2513) is ALREADY inside it -- an
    #     agent-infra PR on its own issue #2513 collides TODAY. Every tracker unit numbered ABOVE
    #     agent-infra's counter becomes a scheduled collision as that counter passes it, and ALL BUT
    #     TWO open units are above it (the count that stood here is retracted below).
    #     ⛔ THE COUNT THIS BLOCK CARRIED WAS WRONG WHEN IT WAS WRITTEN, and how it was wrong is the
    #     reason it is retracted rather than corrected in place: it read "~34 units (17 P0 + 17 P1,
    #     re-measured 2026-11-05 after this block was first written with a stale 14/17 split)".
    #     Re-measured with `gh issue list --label … --state open`: the P0 half was right and the P1
    #     half was not -- **17 P0 + 26 P1 = 43 open units**, and all 26 open P1s were created before
    #     16:06Z that day, i.e. BEFORE this line was authored at 20:31Z. So the "re-measurement"
    #     that replaced a stale split was itself stale, and 41 of the 43 sit above agent-infra's
    #     #3493; the two that do not are #2281 and #2513, which is the point of the sentence.
    #     ⛔ AND IT IS NOT CHECKABLE WITH `--state all`: that read truncates at `--limit` (a
    #     300-row read of this label reported 24 where the OPEN read reports 26), which is the
    #     "a measurement artifact is not a state" failure -- count from `--state open` only.
    #     ⛔ NO EXPLICIT LIST OF NUMBERS HERE, DELIBERATELY: an earlier draft enumerated eight of
    #     them and got the surface wrong in three ways (four were `P0-blocker` rather than
    #     `P1-severe`, ten open P1s above the range were missing, and the "newest PR" it pinned was
    #     already stale). The CHECK IS "ANY OPEN TORTOISE NUMBER", so a list can only rot.
    #   * THE MITIGATION IS NOT A QUALIFIED MATCH, AND NONE IS APPLIED HERE. `tortoise#N` / issue-URL
    #     matching was the first suggestion and it would UNDO this change: agent-infra#3368's title
    #     carries the bare `(#10114)` that this PR exists to see, so requiring a qualifier restores
    #     the `without_pr` that charters a lane to rebuild landed work.
    #   * ⛔ AND A "SELF-REFERENCE" FILTER WAS TRIED, MEASURED, AND REMOVED. The idea was to ignore a
    #     fix-repo row whose bare `#N` equals the ROW'S OWN number (agent-infra#2513's
    #     `fix/2513-pool-filter` citing agent-infra#2513, not tortoise#2513). Measured against the
    #     live windows (2026-11-05, agent-infra open 47 + merged 400 = 447 rows; **43** open tracker
    #     P0/P1 -- 17 P0 + 26 P1, see the count retraction above, NOT the 31 or the 34 this block
    #     carried earlier): only 2 of 447 rows carry their own number at all, and **0 of the 7 rows
    #     that actually collide with an open tracker unit are self-references** — each of them cites
    #     the tracker BARE (`fix/10114-pin-tree-is-a-holder`, `fix/10951-pool-filter`, `p0-10114`,
    #     `ai-10114`, `batch(#3309 #10114 …)`), which is the same fact that rules out the qualified
    #     match. So the filter closed nothing measurable while SUPPRESSING a real cover whenever a
    #     fix-repo PR numbered N genuinely fixes tortoise#N — a false gap, i.e. work rebuilt. Not
    #     worth it, and it made this block argue both that a false gap is the worst error and that it
    #     is the cheap one. Removed rather than documented; the measurement is kept so it is not
    #     re-invented.
    #   * SO THE FALSE-COVER RISK IS OPEN AND UNMITIGATED, deliberately -- AND THE REASON IS THE
    #     REFERENT, NOT THE ROW. `_repo_prs` is called FROM the loop that knows which repo it is
    #     reading (`_repo`), so the row's OWN repo is already in hand at the append site; what no
    #     read of the row can say is what a BARE `#N` in its title REFERS TO. Two corrections are
    #     recorded here because earlier forms of this comment gave the wrong reason twice:
    #     (a) it once said neither read returns a repo identity -- FALSE: `/pulls` rows carry
    #     `head.repo.full_name` (measured 2026-11-05: `{"head_ref":"mcp-3382-phase2",
    #     "head_repo":"daniel-ospina/agent-infra"}`) and `gh pr list --json` offers
    #     `headRepository,headRepositoryOwner,isCrossRepository`; and (b) it then said the datum is
    #     missing from THIS FILE's projection -- ALSO FALSE for the same reason: `_repo` already
    #     holds it. THE ACTUAL GAP is that `headRepository` is the HEAD/FORK repo, not necessarily
    #     the repo the row lands in (and `baseRepository` is not in `gh pr list`'s field list at
    #     all), and that a bare `#N` in a title or branch names no referent. ⛔ THE REFERENT FIELD
    #     EXISTS AND WAS MEASURED, so this is not a missing field either: `closingIssuesReferences`
    #     is accepted by `gh pr list`, and it does carry the referent's repo (0 of the 197
    #     populated rows among 400 merged agent-infra rows had a null `repository`, measured
    #     2026-11-05). What it does NOT do is cover the rows that matter here: the colliding rows
    #     cite the tracker BARE, so they close nothing and their `closingIssuesReferences` is
    #     EMPTY (#3368 and #3313 both measured [] while their titles carry `(#10114)`; only #3333
    #     has a ref, and it is agent-infra#3309). Matching a bare number against the rows of EVERY
    #     repo we read is therefore the same unqualified match this comment has just argued
    #     against, one level further out. So the successor is per-row REFERENT resolution (a
    #     qualified match with the referent's repo), which these rows carry no signal for -- a
    #     follow-up by ABSENCE OF SIGNAL ON THE COLLIDING ROWS, not by an absent field and not by
    #     an absent projection. Until then the optimistic error stands: a
    #     fix-repo row citing an in-range number marks the same-numbered tortoise unit covered.
    # ⛔ A REFUSED READ IS NOT "NO PR": with no second source it returns None so the whole line
    # reads `unavailable`, exactly as a failed tracker read does. Inflating `without` from an
    # unreadable repo is the fail-open direction, and it is the one that misdirects a lane into
    # duplicate work.
    # ⛔ AND THE MERGED COVER IS WINDOW-BOUNDED TOO, WHICH IS THE ONE RESIDUAL THIS BLOCK HAS NOT
    # STATED (#3457 review round 14). The merged half reads the newest 400 rows -- the SAME bound
    # the block above spends six paragraphs on for the tracker -- so a long-lived P0/P1 whose fix
    # landed in another repo goes back to `without_pr` once 400 newer closed PRs exist in that
    # repo (the 2026-11-05 measurement already put 400 agent-infra rows across ~1380 PR numbers).
    # So "prevents the future mis-charter" is true of the OPEN window and TIME-BOUNDED for the
    # merged one; the successor that removes both is the per-row referent resolution named above.
    # It is accepted rather than widened because a deeper merged window costs a page per 100 rows
    # on every tick inside the same 30 s REST budget and the same 60 s phase clock.
    fix_prs = []
    seen = []
    for _repo in FIX_REPOS:
        # ⛔ VALIDATE FIRST, DEDUPE SECOND. `dict.fromkeys(FIX_REPOS)` used to run ABOVE this check,
        # so an UNHASHABLE entry (a list, a dict) raised `TypeError` out of `compute()` instead of
        # taking the documented `return None` -- the traceback-and-no-line path the shape gate
        # exists to prevent (#3457 review).
        # ⛔ AND A FIX_REPOS ENTRY IS A CONTRACT, NOT A HINT. A falsy or malformed one must be
        # UNREADABLE, never silently substituted: `--repo None` raises, and the REST path's
        # `repo or REPO` would then hand back the TRACKER's `/pulls` under the fix repo's name --
        # a wrong list that still looks complete, which is the one thing this path may not do.
        if not isinstance(_repo, str) or _repo.count("/") != 1 or not all(_repo.split("/")):
            return None
        if _repo == REPO or _repo in seen:
            continue      # dedupe: a repo listed twice is ONE read, never two
        seen.append(_repo)
        for _state, _limit in (("open", 500), ("merged", 400)):
            rows = _repo_prs(_repo, _state, _limit, rest_deadline)
            if rows is None:
                return None
            fix_prs.extend(rows)

    today = time.strftime("%Y-%m-%dT00:00:00Z", time.gmtime())
    merged_today = sum(1 for p in merged if (p.get("mergedAt") or "") >= today)

    def covered(n):
        pat = re.compile(r"(?<![\d])%d(?![\d])" % n)
        # ⛔ ONE RULE FOR EVERY ROW. A per-repo rule was tried and removed -- see the false-cover
        # block above for the measurement (0 of 7 colliding rows are self-references) and why the
        # only sound successor is a per-row repo identity rather than a heuristic here.
        for p in openpr + merged + fix_prs:
            if pat.search(p.get("headRefName") or "") or pat.search(p.get("title") or ""):
                return True
        return False

    out = {"ts": int(time.time()), "repo": REPO,
           "open_prs": len(openpr), "merged_today": merged_today}
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
        # ⛔ AND THE SAME SHAPE GATE HERE (#3457 review round 10), where it is the worst of the
        # four: `{}` iterates to NOTHING, so `len(rows)` is 0 and the tier reads `0 open, 0 none`
        # -- a wrong number, not `unavailable`, and `main()` CACHES it for the whole 1800 s TTL.
        # Measured: an issue read answered `{}` printed `P0 0 open (0 with PR, 0 NONE) | P1 0 open
        # (0 with PR, 0 NONE)`. The `for r in rows` below cannot catch it: there is no row to
        # reject.
        # ⛔ AND IT IS THE SHARED PREDICATE, NOT A SECOND ONE (#3457 review round 12). These rows
        # are the ONLY ones whose `number` is dereferenced (`covered(r["number"])`), so the bool-is-
        # not-an-int rule belongs here more than anywhere -- the first form of this block checked
        # `isinstance(rows, list)` only, and a tier list of `True` reached `covered(True)`.
        rows = _shape_pr_rows(rows, "open")
        if rows is None:
            return None
        have = sum(1 for r in rows if covered(r["number"]))
        out[tier] = {"open": len(rows), "with_pr": have, "without": len(rows) - have}
    return out


def main(argv=None):
    """ONE line by default; `--json` emits the SAME object the render reads.

    ⛔ TWO SURFACES, ONE DERIVATION (#3382 invariant-by-construction): `--json` does not compute
    anything. It emits `payload`, which is the exact dict the prose branch renders from — so a caller
    cannot get a figure from the JSON that the operator's line does not show, or the other way round.
    `--json` also carries `age_m`/`stamp` **computed here, at render time, from `ts`** (#3382 invariant
    4), so every figure in it has a measurement time and a correctly-computed age, and a future stamp
    is clamped by the same rule the prose uses rather than by a second one.

    Exit is 0 in every case except a USAGE error (2), because this runs on the beat and a metrics
    failure must never take it down (module header). `--json` says `unavailable` in the payload.
    """
    global REPO
    # ⛔ `None` MEANS "NO ARGUMENTS", and the CLI passes them explicitly at the trailer. Reading
    # `sys.argv[1:]` here made every in-process caller — the tests, and anything that imports this
    # module — inherit ITS OWN argv, so a pytest run turned pytest's arguments into a usage error.
    argv = list(argv or [])
    as_json = False
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--json":
            as_json = True
        elif a == "--repo":
            if i + 1 >= len(argv) or "/" not in argv[i + 1]:
                sys.stderr.write("beta-progress: --repo needs owner/name\n")
                return 2
            REPO = argv[i + 1]
            globals()["FIX_REPOS"] = _derive_fix_repos(REPO)   # see the note beside FIX_REPOS
            i += 1
        elif a in ("-h", "--help"):
            print(__doc__)
            return 0
        else:
            sys.stderr.write("beta-progress: unknown argument %r\n" % a)
            return 2
        i += 1
    data = None
    _cache_path_now = _cache_path()
    try:
        with open(_cache_path_now) as fh:
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
            # ⛔ A CACHE THAT NAMES A DIFFERENT REPO IS NEVER THIS REPO'S ANSWER. And an UNLABELLED
            # cache is only this repo's when it is the BASE file (`REPO == DEFAULT_REPO`), which is
            # the one path the label-less writer ever used — so that inference is provable, not
            # hopeful. Any other repo reads its own repo-keyed file (`_cache_path()`), so it can
            # never inherit the beat's figures.
            _cr = cached.get("repo")
            if (_cr is not None and _cr != REPO) or (_cr is None and REPO != DEFAULT_REPO):
                cached = None
            else:
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
        # is a line that moves. The row guards above COVER THE LIST-LEVEL SHAPE for all four PR
        # lists and the issue reads (a non-list is `unavailable`, never a number), and this keeps a
        # FUTURE shape from taking the beat's measurement down silently. It is not redundant with
        # them: a list of well-typed-but-absent fields still reaches here.
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
            if as_json:
                print(json.dumps({"repo": REPO, "readable": False, "measured_at": int(time.time()),
                                  "unmeasured": "UNMEASURED(gh issue/pr list --repo %s + metrics "
                                                "read failed: no P0/P1 figure is known, and unknown "
                                                "is not zero)" % REPO},
                                 indent=2, sort_keys=True))
                return 0
            print("DELIVERY: unavailable (metrics read failed)")
            return 0
        try:
            with open(_cache_path_now, "w") as fh:
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
        if as_json:
            print(json.dumps({"repo": REPO, "readable": False, "measured_at": int(time.time()),
                              "unmeasured": "UNMEASURED(render of the cached payload + unrenderable "
                                            "shape: no figure is reported rather than a guess)"},
                             indent=2, sort_keys=True))
            return 0
        print("DELIVERY: unavailable (metrics read failed)")
        return 0
    if as_json:
        payload = dict(data)
        payload["repo"] = REPO
        payload["readable"] = True
        payload["measured_at"] = int(ts) if ts else None
        payload["age_m"] = age_m
        payload["stamp"] = stamp
        print(json.dumps(payload, indent=2, sort_keys=True))
        return 0
    print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
