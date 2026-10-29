#!/usr/bin/env python3
# merge-reminder.py — the fleet's 10-minute merge REMINDER, with a narrow, EVIDENCE-GATED actuator arm.
#
#   merge-reminder.py [--repo owner/name] [--o DIR] [--reviews DIR]
#                     [--act | --no-act] [--dry-run] [--json] [--quiet]
#                     [--max-prs N] [--candidates N] [--retry-s S] [--rail-wait-s S]
#                     [--rail PATH] [--verify-deploy-s S]
#                     [--install-timer [--interval S]] [--uninstall-timer]
#
# Exit: 0 = the cycle RAN (a reminder was written; whether it dispatched or not)
#       3 = the cycle was SKIPPED — named, and never passed off as "nothing to do"
#           (rate-limited, an unreadable read, a timer it could not install)
#       2 = usage
#       1 = internal error
#
# ── WHAT THIS IS (and what it deliberately is not) ───────────────────────────────────────────────
# It answers the OWNER'S GOALS first, then THREE questions, and spends a bounded REST budget doing it:
#   0. WHERE THE GOALS STAND — the two goals the queue exists to move (owner, 2026-10-24T04:10Z:
#      "improve the reminder message so it reminds you of the goals properly"):
#        (1) tortoise P0+P1 are DONE and MERGED — a fix without a merged PR is not done;
#        (2) the harness runs AUTONOMOUSLY — the same version deployed AND activated on the local
#            box and all three cells, on both repos, with the PR queue not behind.
#      Measured (`goal_progress`), never restated, and MEASURED FIRST — see `main`'s ORDER rule.
#   1. what is closest to landing (open PRs of the target repo, best-evidenced first);
#   2. what merged but is NOT LIVE on the boxes (a merged fix that never reached a box has fixed
#      nothing — the reminder's second half is the DEPLOY arm, #2416's sibling);
#   3. what is red for the SAME reason across many PRs (one root that unblocks a batch).
#
# Since 2026-10-23 it also ACTS — narrowly, and only on complete evidence. The owner's words:
# *"those commands could lead to automated dispatches for the needed action… we can merge and if it
# breaks then it's fast to repair, as long as it's not a catastrophic break."*
#
# ⛔ THE RAIL IS THE AUTHORITY, NOT THIS FILE. `scripts/admin-merge.sh` decides whether a merge is
# safe: it re-reads the check surface with its own allow-list polarity (an unrecognised conclusion is
# RED), binds the evidence marker to one SHA, refuses a moved head, and classifies main's reds by the
# EVENT that produced them. This file NEVER merges and NEVER emits an override. What it does is
# decide WHEN spending one rail attempt is worth it — the same division of labour as the cell
# doctor's `merge` role (`cloud-cell-doctor.sh`: "The pre-filter is a COST gate, never an
# authorization"). A second opinion here would be the two-readers defect (#1872/#1714).
#
# ⛔ IT IS ALSO A REMINDER FIRST. Before this arm existed the emitted line read
#     `#2579 (?) reds=0 [GREEN(wait:21)] :: fix(rail): …`
# — `(?)` for priority, and `GREEN` for a surface with TWENTY-ONE checks still in flight. Both read
# better than reality. Every value on the line is now MEASURED, and a value it could not read says so:
#     `reds=0 in-flight=0 attested@head=yes claim=none rail=idle`   → GO
#     `reds=0 in-flight=21 attested@head=no  claim=none rail=idle`  → WAIT  (#2522/#2592: in flight
#                                                                     is a WAIT, never a stall, and
#                                                                     never a GO)
#     `reds=0 in-flight=0  attested@head=stale …`                   → REFUSE(attested=stale)
# An UNREAD value is `UNREADABLE <reason>` and NOTHING is dispatched. That is the one rule the whole
# arm rests on: a GO is a claim about evidence, so it can only be derived from evidence it read.
#
# ── THE GATES (ALL of them, at the moment of action; a failure NAMES itself) ────────────────────
#   pr=OPEN draft=no mergeable=MERGEABLE   the PR is open, not a draft, and GitHub says it merges;
#                                          `mergeable: null` is UNKNOWN (a WAIT), never a GO.
#   attested@head=yes                      a review record exists whose `head_sha` EQUALS the live
#                                          head. A record bound to an older head is `stale` — six
#                                          PRs were caught in exactly that state on 2026-10-22, and a
#                                          stale record read as "reviewed" is a false GO.
#   reds=0 in-flight=0                     newest attempt per check group by `id`, grouped by
#                                          (app.slug, workflow, job name) — #4877's rule, because
#                                          two workflows can publish the same job name and a newer
#                                          green of one must never mask a red of the other.
#   claim=none                             no live claim: `refs/claims/pr-<N>` and
#                                          `refs/claims/<N>-<head12>` (cross-box) and
#                                          `$O/state/mergeclaim-<PR>.lock` (this box). Two landers on
#                                          one PR is the defect #2574/#2576 exist to prevent.
#   rail=idle                              no rail already running for THIS PR: the local landing lock
#                                          with a LIVE pid, or a live `admin-merge.sh` whose argv names
#                                          the PR (a hand-started rail is still a rail). One attempt
#                                          per PR per cycle.
#
# ── THE COST DISCIPLINE (kept, and made explicit) ───────────────────────────────────────────────
#   * `GET /rate_limit` FIRST — it is UNMETERED on GitHub's primary limit — and if the core budget is
#     under `REST_RESERVE` the run is SKIPPED and SAYS SO (`skipped=rate-limited core=…/… reset=…`),
#     never rendered as an empty queue. (gh-limit.py's own doctrine, #1988.)
#   * at most `REST_BUDGET = 9` metered calls: ONE open-PR listing, then per candidate THREE surface
#     reads (workflow runs, check-runs `filter=all`, legacy statuses) plus ONE single-PR read for
#     mergeability (the LIST endpoint never computes it — every PR answers `null`, which made this
#     arm inert until it was re-read per candidate), for at most `--candidates` (2).
#   * the GOAL readings spend the SEARCH quota, not the core one (a different limit on GitHub), so
#     measuring the goals can never starve the landing arm: at most `GOAL_SEARCH_BUDGET = 8` search
#     calls, counted separately (`budget.search_calls`). A count that does not come back is
#     `NOT-MEASURED`, never `0` — zero is the claim that the goal is met (`_count`).
#   * the deploy arm makes NO REST call at all: it reads artifacts on the boxes.
#
# ── THE DEPLOY ARM ─────────────────────────────────────────────────────────────────────────────
# Question 2 ("merged but not live") is only useful if it can be ACTED on. When a box's deployed
# harness sha differs from `origin/main`, the action is the box's own activation verb — on a cell,
# `cloud-cell-supervisor.sh stop → apply → start` — and it is dispatched here ONLY:
#   * AFTER the landing decision, never instead of it (a landing and a restart in the same cycle
#     would restart the controller underneath the rail that was just dispatched);
#   * when NO ROLE PASS IS MID-FLIGHT on that box (the doctor's `reap`/`merge`/`hygiene` roles hold
#     `$O/state/roles/.<role>.lock`; restarting a cell mid-reap kills work in a way a merge does not
#     repair), and
#   * it is VERIFIED BY ARTIFACT (`harness: <sha> [current]`, `controller: RUNNING`), never by the
#     activate command's exit code. An unverified deploy is REPORTED as `deploy=<box>:UNVERIFIED`,
#     never assumed.
#
# ⛔ AND IT REFUSES, BY NAME, EACH WAY AN ACTUATOR BECOMES AN INCIDENT (2026-10-23 review):
#   * `origin/main` UNREADABLE — with an empty main every box reads as drifted and the verify loop
#     could never pass: a restart storm every cycle. Nothing is activated.
#   * `--no-act` (`MERGE_REMINDER_ACT=0`) — covers BOTH arms. It is how a human INSPECTS this file
#     before trusting it, and a restart is more disruptive than the landing that mode suppresses.
#   * a landing attempt live ANYWHERE on this box (any `mergeclaim-*.lock` with a live pid, any live
#     `admin-merge.sh`/`merge-one.sh`) — not only one this cycle dispatched. `--interval` (600s) is
#     shorter than `--rail-wait-s` (900s), so overlapping cycles are reachable by construction.
#     `state/merge-reminder-deploy.lock` serialises the arm itself.
#   * `controller: STOPPED` — an absent `.desired` is the operator's intent, not drift.
#   * a `source=stamp` identity — the stamp records what was SEEDED, not what is RUNNING
#     (`harness-refresh.sh`), so a matching stamp reads `UNPROVEN` and activates nothing.
# The boxes are an INVENTORY, not a hardcoded host list: `$O/state/boxes.tsv`, one
# `name<TAB>status-cmd<TAB>activate-cmd` per line (`#` comments). Without the file the arm runs
# locally only (`box-status.sh` beside this script), which is the correct default: a timer on a box
# can act on that box without inventing a remote-control surface.
#
# ── TIMERS (both platforms; #2416 owns the fleet-wide schedule) ───────────────────────────────
#   --install-timer     macOS: renders + bootstraps a launchd agent; Linux: a systemd USER timer
#                       (falling back to crontab) — and VERIFIES the job is loaded. A box with no
#                       scheduler REFUSES loudly (exit 3) instead of installing nothing quietly.
#   --uninstall-timer   removes EVERY arm install can create (unit AND crontab entry) and verifies
#                       the removal — a successful-looking stop is not a stopped timer.
#
# ── THE SCHEDULER CONTRACT ────────────────────────────────────────────────────────────────────
# A timer's PATH is not a login shell's. `gh` is resolved from PATH, then `$O/gh-rest/gh` (the REST
# adapter), then `~/.pi/agent/shims/gh`; if none resolves the run is SKIPPED (UNREADABLE), never an
# empty answer. `git` must be on PATH for the claim gate — an unreadable claim store is
# `claim=UNREADABLE` and refuses (a GO on an unread claim store is how two landers happen).
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path

REST_BUDGET = 9          # metered REST calls per run (rate_limit is exempt); see the header
REST_RESERVE = 200       # below this core budget the run is SKIPPED, not rendered as "nothing to do"
GOAL_SEARCH_BUDGET = 8   # SEARCH-quota calls per run for the goal readings. ⛔ A DIFFERENT BUCKET to
#                          `core`: the search API has its own limit (30/min), so measuring the goals
#                          never spends a call the landing arm needed. See `_count`.
# ⛔ A RETRY IS A GAP IN TIME, NOT A SECOND CALL. Two `git rev-parse` calls issued back to back run
# microseconds apart and fail together on the same transient, so a "retry" of that shape recovers
# nothing — and the retry that DID recover (a third read after the goals) is how one report came to
# print the recovered sha in its header while the goals block called the same sha unreadable and
# accused a box sitting on it. ONE value, read once with a real backoff, used by every consumer.
# The inventory states that are NOT a probed box: an unreadable `boxes.tsv`, a file that exists and
# lists no rows, and an absent file with no local probe script. Each says which in its `note`, and none
# may be counted, fractioned, or reported as a marker.
PLACEHOLDER = ("unread", "empty", "noprobe")

MAIN_READ_ATTEMPTS = 3
MAIN_READ_BACKOFF_S = 0.5

DEFAULT_MAX_PRS = 100    # one page of the open-PR listing — the API's own page size, not a slice of
#                          it: the listing has no `total_count`, so a FULL page is UNREADABLE (below).
DEFAULT_CANDIDATES = 2   # 1 + 4*2 = 9 <= REST_BUDGET
MAX_CANDIDATES = 2       # the budget ceiling, enforced (1 + 4*3 = 13 > 9)
RETRY_S = 900            # a refusal at THIS head is not retried blind inside this window
RAIL_WAIT_S = 900        # how long the dispatch waits for the rail's own exit, to report its rc
DEPLOY_VERIFY_S = 180    # how long the deploy arm waits for the artifact to prove the cycle
STATE_MD = "MERGE-REMINDER.md"
ATTEMPTS = "merge-reminder.attempts"

# ── THE GOALS (owner, 2026-10-24T04:10Z: "improve the reminder message so it reminds you of the
#    goals properly") ────────────────────────────────────────────────────────────────────────────
# A reminder that reports on PRs and forgets what the PRs are FOR is a reminder that optimises the
# QUEUE instead of the OBJECTIVE. So the goals are stated first in the report, and they are MEASURED
# (`goal_progress`) rather than restated — a recap of what the owner said is not a reading.
GOALS = (
    ("Goal 1 — tortoise P0+P1 are DONE and MERGED",
     "a fix without a MERGED PR is not done, it is in progress. Read: OPEN P0/P1 issues, the P0/P1 "
     "issues CLOSED today, and tortoise PRs merged today."),
    ("Goal 2 — the agent-infra harness runs AUTONOMOUSLY",
     "the full lifecycle — pick up, PR, review, land, and FIX when red — on the local box AND all "
     "three cmux cells, at the SAME harness version (main / local / every cell, deployed AND "
     "activated), on BOTH repos, with the PR queue not behind."),
)
GOAL_REPO = "daniel-ospina/tortoise"     # goal 1 is measured on tortoise, whichever repo this runs for

# A completed check run is NON-RED only for a conclusion named HERE (allow-list polarity, #1714): an
# unrecognised token — a vendor's new conclusion, an empty one — is RED, never "neither".
NONRED_COMPLETED = {"success", "neutral", "skipped", "cancelled", "stale"}
IN_FLIGHT_STATUS = {"queued", "in_progress", "waiting", "requested", "pending"}
CLEAN_VERDICTS = {"clean", "clean-micro", "clean-low"}

# One code path for "no", "cannot say" and "yes" on every read this file acts on (the doctor's
# three-valued discipline, #1989). `None` is a decision, `UNREADABLE` is an abstention.
GO, WAIT, REFUSE, UNREADABLE = "GO", "WAIT", "REFUSE", "UNREADABLE"


def read_artifact(p: Path) -> str:
    """Read a state file as text, surviving bytes that are not UTF-8.

    ⛔ `UnicodeDecodeError` IS A `ValueError`, NOT AN `OSError`. Every `read_text()` in this file was
    guarded with `except OSError`, so a non-UTF-8 ledger or lock file escaped `landing_cycle`'s
    per-candidate handler, `main`'s `except (Skipped, OSError)` and `__main__`'s `except Skipped`:
    traceback, exit 1, NO report written, and the PREVIOUS cycle's MERGE-REMINDER.md left on disk —
    a silent stop for as long as the bytes stayed malformed. `errors="replace"` turns that into an
    unreadable READING, which every caller already handles by name.
    """
    return p.read_text(errors="replace")


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class Skipped(Exception):
    """A cycle that could not be measured. Reported by name; NEVER an empty answer."""


def run(cmd, timeout=60, cwd=None, env=None):
    """Run a command with a hard bound. Returns (rc, stdout, stderr); rc 124 on timeout.

    ⛔ EVERY `git` INVOCATION IS SANITISED HERE, IN ONE PLACE (round-8 review, measured). Eight of twelve
    git reads still inherited the ambient environment (8 of the 11 call sites), and
    `GIT_DIR=<a foreign repo>/.git` made
    `claim_state()` report a holder that existed only in THAT repo, `repo_slug()` answer a foreign slug,
    `github_origin()` — the checkout-vs-flag MISMATCH GUARD — return "" (fail open), and `git_dir()` name
    another repository. A defaulted `env` here closes the whole class, including calls added later; a
    caller that really needs a specific environment still passes one.
    """
    if env is None and cmd and os.path.basename(str(cmd[0])) == "git":
        env = git_env()
    try:
        # ⛔ `errors="replace"`: a command's non-UTF-8 output is a READING problem, and a UnicodeDecode
        # error here would escape every handler (same class as the boxes.tsv decode above).
        p = subprocess.run(cmd, capture_output=True, text=True, errors="replace",
                           timeout=timeout, cwd=cwd, env=env)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return 124, "", f"timeout after {timeout}s: {' '.join(cmd[:3])}"
    except FileNotFoundError as e:
        return 127, "", f"{e}"
    except OSError as e:
        # ⛔ A NON-EXECUTABLE/FULL/UNAVAILABLE BINARY IS AN ANSWER, NOT AN EXCEPTION. `EACCES` on a
        # non-executable `git`, `EAGAIN`/`ENOMEM` on fork under load: these used to escape every
        # handler — including the cycle's own guards — and kill the run with a traceback, no
        # MERGE-REMINDER.md and no stated reason. rc 126 is the shell's own "found but not
        # executable", so a caller can tell this apart from 127 (not found) and 124 (timeout).
        return 126, "", f"{type(e).__name__}: {e}"


# ── gh resolution + metered REST ────────────────────────────────────────────────────────────────
def resolve_gh(o: Path) -> str:
    """The daemon's gh is the FIRST candidate: on a live box PATH carries the gh-rest adapter and
    the limit layer. The fallbacks exist for a launchd/systemd timer whose PATH is not a login
    shell's — the measured failure that makes a scheduled job report "nothing to do" from an
    unreadable chain rather than from an empty queue."""
    for c in (shutil.which("gh"), str(o / "gh-rest" / "gh"), str(Path.home() / ".pi/agent/shims/gh")):
        if c and os.access(c, os.X_OK):
            return c
    raise Skipped("UNREADABLE gh — no gh on PATH, $O/gh-rest/gh, or ~/.pi/agent/shims/gh")


class Budget:
    """The metered REST budget. `rate_limit` is read FIRST and is exempt; every other call is
    counted, and a call that would exceed the budget raises rather than silently degrading the
    answer (a truncated read is not a smaller answer, it is a wrong one).

    ⛔ TWO BUCKETS, COUNTED SEPARATELY. `calls` is the CORE quota the landing arm spends (listing +
    3 reads per candidate), and `search_calls` is the SEARCH quota the goal readings spend. They are
    different limits on GitHub (5000/h vs 30/min), so folding the goals into `calls` would either
    starve the goals or silently cut the landing arm's bound — and `REST_BUDGET` is a documented
    invariant the suite pins."""

    def __init__(self, gh: str):
        self.gh = gh
        self.calls = 0
        self.search_calls = 0
        self.core_remaining = None
        self.core_limit = None
        self.search_remaining = None
        self.reset = None

    def rate_limit(self):
        rc, out, err = run([self.gh, "api", "rate_limit"], timeout=30)
        if rc != 0:
            raise Skipped(f"UNREADABLE rate_limit rc={rc} {one_line(err)}")
        try:
            res = json.loads(out)["resources"]
            core = res["core"]
            self.core_limit = int(core["limit"])
            self.core_remaining = int(core["remaining"])
            self.reset = int(core.get("reset") or 0)
            # The SEARCH quota is a separate bucket; absent is UNKNOWN, never "plenty".
            try:
                self.search_remaining = int(res["search"]["remaining"])
            except (KeyError, TypeError, ValueError):
                self.search_remaining = None
        except (ValueError, KeyError, TypeError):
            raise Skipped("UNREADABLE rate_limit — the answer was not a JSON rate object")
        # The EXEMPT read above is the only call allowed below the reserve: a run with 12 calls left
        # is a run that must not spend one on a reminder.
        if self.core_remaining < REST_RESERVE:
            raise Skipped(
                "skipped=rate-limited core=%d/%d reset=%s"
                % (self.core_remaining, self.core_limit, _iso(self.reset))
            )

    def api(self, path: str, timeout=45):
        if self.calls >= REST_BUDGET:
            raise Skipped(f"UNREADABLE budget — the {REST_BUDGET}-call bound is spent before {path}")
        self.calls += 1
        rc, out, err = run([self.gh, "api", path], timeout=timeout)
        return rc, out, err


def _iso(epoch) -> str:
    try:
        return datetime.fromtimestamp(int(epoch), timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except (ValueError, OSError, TypeError):
        return "unknown"


def one_line(text: str) -> str:
    return " ".join((text or "").split())[:200]


def _count(budget: Budget, query: str) -> tuple[int | None, str]:
    """How many issues/PRs the SEARCH answers for `query` — counted SERVER-SIDE. -> (count, why-not)

    ⛔ THE LABEL FILTER MUST RUN SERVER-SIDE. `gh issue list --label P0 --json number` returns ONE
    PAGE (30 by default), so counting the returned slice counts THE PAGE and not the population —
    and the repos this measures are large. Measured on tortoise (2026-10-24): a local `--json`
    slice reported `P0=4 · P1=5` while the label query answered **7 and 20**, because the repo has
    more than 300 open issues. A goal line that undercounts is worse than no goal line at all: it
    reports the goal as nearly met, and it does it in the one place a human looks for the answer.

    The query goes into the PATH (`search/issues?q=…`) with no `-f` flag, so `gh api` issues a GET
    with the filter already applied by the server. SEARCH is its own quota, so these calls are
    counted in `budget.search_calls` and NEVER against `REST_BUDGET`.

    -> `(None, why)` when the count could not be READ. A caller must render that as NOT MEASURED:
    `0` is a claim that there are none, and this function never makes that claim.
    """
    if budget.search_calls >= GOAL_SEARCH_BUDGET:
        return None, f"NOT-MEASURED (the {GOAL_SEARCH_BUDGET}-call goal bound is spent this cycle)"
    if budget.search_remaining is not None and budget.search_remaining <= 0:
        return None, "NOT-MEASURED (the search quota is exhausted)"
    budget.search_calls += 1
    # `+` for the term separator (not %20): GitHub treats both as a space, and a query whose
    # separators survive legibly is one a human can read out of a log when it goes wrong.
    path = "search/issues?q=" + urllib.parse.quote(query, safe=":/").replace("%20", "+")
    rc, out, err = run([budget.gh, "api", path], timeout=30)
    if rc != 0:
        return None, f"UNREADABLE rc={rc} {one_line(err)}"
    try:
        obj = json.loads(out)
    except ValueError:
        return None, "UNREADABLE — the search answer was not JSON"
    if not isinstance(obj, dict) or obj.get("incomplete_results"):
        # ⛔ GITHUB ITSELF CAN SAY THE ANSWER IS INCOMPLETE, and an incomplete answer is not a count:
        # `total_count: 0, incomplete_results: true` would render `open P0=0` - i.e. `STANDING=DONE` -
        # on the one rule this file is built on (a `0` is a CLAIM that the goal is met).
        return None, ("UNREADABLE — the search answer was INCOMPLETE (incomplete_results)"
                      if isinstance(obj, dict) else "UNREADABLE — the answer was not a JSON object")
    try:
        return int(obj["total_count"]), ""
    except (KeyError, TypeError, ValueError):
        return None, "UNREADABLE — the search answer carried no total_count"


# ── the review record (a stale record is NOT a record) ─────────────────────────────────────────
def attest(o: Path, reviews: Path, slug: str, pr: int, head: str) -> tuple[str, str]:
    """-> (state, detail) with state in {yes, stale, none, UNREADABLE}.

    The record is the shipped `record-review.sh` artifact:
      {"pr":N,"head_sha":"<40hex>","verdict":"clean","repo":"owner/repo","reviewed_at":"…"}
    `registry-sync.sh` unions these across boxes, and `admin-merge.sh`/`review-enforcer` read the
    same shape — so this reads the SAME file the rail's own evidence does, never a side channel.
    ⛔ A record whose `head_sha` is not the LIVE head is `stale`: the verdict was minted for code
    that is no longer there. That is not a smaller yes, it is a no.
    """
    owner, _, repo = slug.partition("/")
    names = [reviews / f"{owner}-{repo}-{pr}.json", reviews / f"{pr}.json"]
    if not reviews.is_dir():
        return "none", f"no review store at {reviews}"
    tried = []
    for f in names:
        if not f.exists():
            continue
        tried.append(str(f))
        if not f.is_file() or not os.access(f, os.R_OK):
            return "UNREADABLE", f"attestation=<{f}> not readable"
        try:
            d = json.loads(f.read_text())
        except (ValueError, OSError) as e:
            return "UNREADABLE", f"attestation=<{f}> unparseable ({type(e).__name__})"
        if not isinstance(d, dict):
            return "UNREADABLE", f"attestation=<{f}> is not a JSON object"
        rec_repo = str(d.get("repo") or "").strip()
        if rec_repo and rec_repo.lower() != slug.lower():
            # A record for ANOTHER repo is not a record for this one, even when the head matches.
            # `record-review.sh` deliberately leaves a foreign legacy `<pr>.json` in place (it will
            # not delete what might be another repo's data), so `<pr>.json` is a compatibility path
            # — not a licence to reuse a foreign verdict for a same-numbered PR.
            continue
        rec_head = str(d.get("head_sha") or "").strip().lower()
        verdict = str(d.get("verdict") or "").strip().lower()
        if not re.fullmatch(r"[0-9a-f]{40}", rec_head):
            return "UNREADABLE", f"attestation=<{f}> carries no usable head_sha"
        if verdict not in CLEAN_VERDICTS:
            return "stale", f"attestation=<{f}> verdict={verdict or 'none'} (not clean)"
        if rec_head != head.lower():
            return "stale", f"attestation=<{f}> head={rec_head[:12]} live={head[:12]}"
        return "yes", f"attestation=<{f}> head={rec_head[:12]}"
    return "none", "no attestation for this PR (tried %s)" % (", ".join(
        str(p.name) for p in names))


# ── the check surface: groups, newest attempt, allow-list polarity ─────────────────────────────
def _workflow_map(budget: Budget, slug: str, head: str) -> dict[str, str]:
    """run id -> workflow name, for ONE head. This is why the group key can carry the WORKFLOW:
    `check_run.name` is the JOB name, and two workflows may publish the same job name, so grouping
    on the name alone lets the newest of one mask the other (#4877's measured conflation)."""
    rc, out, err = budget.api(f"repos/{slug}/actions/runs?head_sha={head}&per_page=100")
    if rc != 0:
        raise Skipped(f"UNREADABLE workflow map rc={rc} {one_line(err)}")
    try:
        runs = json.loads(out).get("workflow_runs") or []
    except (ValueError, AttributeError):
        raise Skipped("UNREADABLE workflow map — the answer was not a JSON run list")
    m = {}
    for r in runs:
        if not isinstance(r, dict):
            continue
        rid = str(r.get("id") or "")
        if rid:
            # `name` is the workflow's display name; `path` is its file — name first, path as the
            # stable fallback (a renamed workflow still has one path).
            m[rid] = str(r.get("name") or r.get("path") or f"run:{rid}")
    return m


def _run_id_from_url(url: str) -> str:
    m = re.search(r"/actions/runs/(\d+)", url or "")
    return m.group(1) if m else ""


def _ts(value) -> float | None:
    """A GitHub timestamp -> epoch seconds, or None when it is absent/unparseable. Used to order
    legacy commit statuses the way the rail orders them; a value that cannot be ordered is NOT
    given a positional guess (see `check_surface`)."""
    s = str(value or "").strip()
    if not s:
        return None
    try:
        return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc).timestamp()
    except ValueError:
        pass
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def check_surface(budget: Budget, slug: str, head: str) -> dict:
    """-> {reds:[…], in_flight:[…], groups:N, unreadable:None|str}

    Group key: (app.slug, workflow, job name) for check runs; ("status", context) for legacy commit
    statuses. Newest attempt per group by check-run `id` — the SAME rule the merge rail uses
    ("the LATEST check run (highest id) per (app, name) decides"), extended with the workflow so a
    shared job name cannot mask. An entry whose run id cannot be resolved is NEVER dropped: it takes
    its own per-entry group (its own check-run id), so an unresolvable entry can never be superseded
    by a neighbour and its red can never vanish.
    """
    wf = _workflow_map(budget, slug, head)

    rc, out, err = budget.api(f"repos/{slug}/commits/{head}/check-runs?filter=all&per_page=100")
    if rc != 0:
        raise Skipped(f"UNREADABLE check-runs rc={rc} {one_line(err)}")
    try:
        payload = json.loads(out)
        checks = payload.get("check_runs")
    except (ValueError, AttributeError):
        raise Skipped("UNREADABLE check-runs — the answer was not a JSON check-run list")
    if not isinstance(checks, list):
        raise Skipped("UNREADABLE check-runs — no check_run array in the answer")
    # ⛔ ONE PAGE IS NOT THE SURFACE. `filter=all` returns ATTEMPT history, so a busy head exceeds
    # 100 entries (re-runs multiply it), and the rail reads this endpoint with `--paginate` while
    # this read cannot afford to. A page cut drops the OLDEST entries — which can drop a whole
    # group (a job that exists only in an older workflow run) and with it a red. `total_count` makes
    # the truncation DETECTABLE, so the honest reading is UNREADABLE rather than `reds=0`.
    total = payload.get("total_count")
    if isinstance(total, int) and total > len(checks):
        raise Skipped(f"UNREADABLE check-runs — this read saw {len(checks)} of {total} entries "
                      f"(one page); a truncated surface can hide a whole red group")

    rc, out, err = budget.api(f"repos/{slug}/commits/{head}/status?per_page=100")
    if rc != 0:
        raise Skipped(f"UNREADABLE statuses rc={rc} {one_line(err)}")
    try:
        status_payload = json.loads(out) or {}
        statuses = status_payload.get("statuses") or []
    except (ValueError, AttributeError):
        raise Skipped("UNREADABLE statuses — the answer was not a JSON status list")
    if len(statuses) >= 100:
        # This endpoint has no `total_count`, so a FULL page is the only truncation signal it offers
        # — which is why the read must ask for the maximum page in the first place (#2603 review:
        # without `per_page=100` GitHub answers 30 and the guard below could never fire).
        raise Skipped("UNREADABLE statuses — a full page (100) was returned; completeness cannot "
                      "be proven from one page")
    # The COMBINED state is the one field that survives truncation, so it is the cross-check on the
    # page: `failure` with no failing status read means entries were dropped (or one was not
    # classified), and that is NOT a quiet surface.
    combined = str(status_payload.get("state") or "").strip().lower()

    groups: dict[tuple, dict] = {}

    def offer(key, order, verdict, label):
        cur = groups.get(key)
        if cur is None or order > cur["order"]:
            groups[key] = {"order": order, "verdict": verdict, "label": label}

    for idx, c in enumerate(checks):
        if not isinstance(c, dict):
            # A non-object entry is unreadable, and unreadable is never green: it becomes a RED
            # placeholder rather than being skipped (nothing is dropped before classification).
            offer(("?", "unresolved", f"entry:{idx}"), idx, "red",
                  f"unparseable check entry #{idx}")
            continue
        cid = c.get("id")
        name = str(c.get("name") or "").strip()
        app = ((c.get("app") or {}) if isinstance(c.get("app"), dict) else {}).get("slug") or "?"
        rid = _run_id_from_url(c.get("details_url") or c.get("html_url") or "")
        workflow = wf.get(rid, f"run:{rid}" if rid else f"unresolved:{cid if cid is not None else idx}")
        # An UNNAMED entry shares the placeholder name with every other unnamed one; keying it by
        # (app, workflow, name) would let a newer unnamed non-red supersede an older unnamed red.
        key = (app, workflow, name if name else f"unnamed:{cid if cid is not None else idx}")
        verdict = _classify_check(c)
        offer(key, int(cid) if isinstance(cid, int) else idx, verdict, f"{workflow} / {name or '<unnamed>'}")

    # Legacy commit statuses. The rail reads BOTH endpoints; a status surface this file ignored
    # would be a read that is quieter than the rail's — the wrong direction for a cost gate.
    # ⛔ ORDER BY TIME, NOT BY ARRAY POSITION. `admin-merge.sh` orders the same payload by
    # `updated_at`/`created_at` (its `sbest` comparison). A positional assumption is only correct for
    # one payload direction, and when it is wrong an older `success` supersedes a newer `failure` —
    # `reds=0` printed over a live red, which is a GO minted from a misread. A status carrying
    # NEITHER timestamp cannot be ordered at all, so that surface is UNREADABLE rather than guessed.
    problem = ""
    for idx, s in enumerate(statuses):
        if not isinstance(s, dict):
            offer(("status", "unresolved", f"entry:{idx}"), idx, "red", "unparseable status entry")
            continue
        ctx = str(s.get("context") or "").strip()
        key = ("status", "commit-status", ctx if ctx else f"unnamed:{idx}")
        state = str(s.get("state") or "").strip().lower()
        verdict = "nonred" if state == "success" else ("in_flight" if state == "pending" else "red")
        stamp = _ts(s.get("updated_at") or s.get("created_at"))
        if stamp is None:
            problem = (f"a legacy commit status for context {ctx or '<unnamed>'} carries neither "
                       f"updated_at nor created_at, so which entry is newest cannot be established")
            continue
        offer(key, stamp, verdict, f"status / {ctx or '<unnamed>'}")

    status_groups = [v for k, v in groups.items() if k and k[0] == "status"]
    # ⛔ EVERY OTHER COMBINED TOKEN IS RED (the same allow-list polarity as a check conclusion):
    # `error` is a red-class value in GitHub's enum (admin-merge.sh's MEASURING_STATE includes it), and
    # an unnamed future token must never fall through the gap between `failure` and `pending`.
    if not problem and combined and combined not in ("success", "pending", "failure"):
        problem = (f"the combined commit-status state is `{combined}`, which this reader does not "
                   f"classify — an unrecognised conclusion is never green")
    if not problem and combined == "failure" and not any(
            v["verdict"] == "red" for v in status_groups):
        problem = ("the combined commit-status state is `failure` but no failing status was read "
                   "— the page is incomplete, so its absences prove nothing")
    # ⛔ `pending` IS THE EMPTY STATE, NOT EVIDENCE OF A DROPPED ENTRY. GitHub reports
    # `state: "pending"` for a body carrying ZERO legacy statuses — the normal shape of any head whose
    # CI is check-runs only (`admin-merge.sh` documents the same fact twice) — so treating it as
    # truncation made EVERY real head UNREADABLE and the actuator dead (2026-10-23, measured on five
    # consecutive origin/main commits: `state=pending statuses=0 total_count=0`). Only a pending
    # state that the READ ENTRIES contradict is suspicious.
    if not problem and combined == "pending" and statuses and not any(
            v["verdict"] == "in_flight" for v in status_groups):
        problem = ("the combined commit-status state is `pending` but no in-flight status was read "
                   "— the page is incomplete, so its absences prove nothing")

    reds = sorted({v["label"] for v in groups.values() if v["verdict"] == "red"})
    inflight = sorted({v["label"] for v in groups.values() if v["verdict"] == "in_flight"})
    return {"reds": reds, "in_flight": inflight, "groups": len(groups),
            "unreadable": problem or None}


def _classify_check(c: dict) -> str:
    """Allow-list polarity for ONE check run. `completed` is non-red only for a named conclusion;
    a named in-flight status is a WAIT; ANY OTHER non-completed status is classified by its
    conclusion — so `completely_finished`/`Completed`/`` can never be filed as pending and read
    green (#1353)."""
    status = str(c.get("status") or "").strip().lower()
    concl = str(c.get("conclusion") or "").strip().lower()
    if status == "completed":
        return "nonred" if concl in NONRED_COMPLETED else "red"
    if status in IN_FLIGHT_STATUS:
        return "in_flight"
    # Unnamed status with a conclusion: classify by the conclusion, under the same allow-list.
    if concl:
        return "nonred" if concl in NONRED_COMPLETED else "red"
    return "red"


# ── claims and rails (local + cross-box) ──────────────────────────────────────────────────────
def _pid_alive(pid) -> bool:
    try:
        os.kill(int(pid), 0)
        return True
    except (ProcessLookupError, ValueError, TypeError):
        return False
    except PermissionError:
        return True       # exists but is not ours: ALIVE is the fail-closed reading


def claim_state(o: Path, repo_path: Path, pr: int, head: str) -> tuple[str, str]:
    """-> (state, detail). state: none | <holder> | UNREADABLE.

    Three surfaces, because they answer three different questions and all three mean "a lander":
      * `$O/state/mergeclaim-<PR>.lock` — this box (merge-one.sh's noclobber lock; a DEAD pid is a
        stale lock, which is not a live claim and is reported as such);
      * `refs/claims/pr-<N>` — the CROSS-BOX landing claim (#1952: keyed on the PR, because two
        heads of one PR are not two landing events);
      * `refs/claims/<N>-<head12>` — the per-head review/landing claim.
    ⛔ An UNREADABLE claim store is an ABSTENTION, never "no claim": a GO minted against a claim we
    could not read is how two landers end up on one PR (#2574/#2576).
    """
    # ⛔ THE LOCAL LOCK IS THE RAIL'S, NOT THE CLAIM GATE'S. `mergeclaim-<PR>.lock` is created by
    # the thing that is ABOUT TO LAND this PR on this box (merge-one.sh, or this file's own
    # dispatch) — so a LIVE one is reported by `rail_state` as `rail=running`, which is the action
    # it forbids. Reading it as a "claim" here would name the same fact twice and refuse with the
    # wrong word. A DEAD pid is not a live claim and is reported as a stale lock rather than
    # deleted: this file is read-only about every artifact another component owns.
    lock = o / "state" / f"mergeclaim-{pr}.lock"
    stale_note = ""
    if lock.exists():
        try:
            pid = read_artifact(lock).strip()
        except (OSError, ValueError):
            pid = "?"
        if not _pid_alive(pid):
            stale_note = f"stale-local-lock=<{lock}> pid={pid} dead"

    heads = head[:12].lower()
    refs = [f"refs/claims/pr-{pr}", f"refs/claims/{pr}-{heads}"]
    rc, out, err = run(["git", "-C", str(repo_path), "ls-remote", "--refs", "origin", *refs],
                       timeout=45)
    if rc != 0:
        # `git` missing is 127; a network failure is any other non-zero. Both are abstentions.
        return "UNREADABLE", f"claim store unreadable (git ls-remote rc={rc} {one_line(err)})"
    held = []
    for line in (out or "").splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[1] in refs:
            held.append((parts[1], parts[0]))
    if not held:
        return "none", stale_note
    ref, sha = held[0]
    holder = f"{ref}@{sha[:12]}"
    lease_until = ""
    # The claim's own commit message carries `owner` and `lease_until` (claims.sh). Read it when it
    # is cheap to do so; a failure to read the LEASE is not a failure to see the CLAIM, so the
    # refusal stands and the holder just carries less detail.
    # ⛔ A PRIVATE REF, NEVER `FETCH_HEAD`. There is ONE FETCH_HEAD per .git, shared by every worktree
    # and rewritten by ANY concurrent fetch — reading it made a LIVE claim readable as an EXPIRED one
    # (harness-refresh.sh records the same decision for its own reads, with a staged race test). The
    # ref is ours alone, and a FULL fetch of one claim commit (not `--depth=1`, which a local-path
    # transport refuses outright) is a few objects.
    tmp_ref = f"refs/reminder/claim-{pr}-{os.getpid()}-{int(time.time())}"
    msg = ""
    rc, _, _ = run(["git", "-C", str(repo_path), "fetch", "--no-tags", "origin",
                    f"{ref}:{tmp_ref}"], timeout=60)
    if rc == 0:
        rc2, out_msg, _ = run(["git", "-C", str(repo_path), "log", "-1", "--format=%B", tmp_ref],
                              timeout=15)
        if rc2 == 0:
            msg = out_msg or ""
    run(["git", "-C", str(repo_path), "update-ref", "-d", tmp_ref], timeout=15)
    if msg:
        # ⛔ THE SHAPE IS `claims.sh`'s, NOT AN INVENTED ONE: one line,
        # `claim owner=<x> lease_until=<epoch-seconds> nonce=<...>`, parsed with the same
        # non-anchored patterns `_lease_of` uses — a claim minted by the real writer must be
        # readable here, or every claim reads as lease-less and none can ever expire.
        m_owner = re.search(r"\bowner=([^\s]+)", msg)
        m_lease = re.search(r"\blease_until=([^\s]+)", msg)
        extra = []
        if m_owner:
            extra.append(f"owner={m_owner.group(1).strip()}")
        if m_lease:
            lease_until = m_lease.group(1).strip()
            extra.append(f"lease_until={lease_until}")
        if extra:
            holder = f"{ref}@({', '.join(extra)})"
    if lease_until:
        # `lease_until` is EPOCH SECONDS (claims.sh: "an EPOCH SECOND, which is 10 digits TODAY");
        # an ISO stamp is tolerated for an older writer. ⛔ AN UNPARSEABLE LEASE IS LIVE, NEVER FREE,
        # which includes the `0` SENTINEL: claims.sh's `_lease_unparseable` treats `'' | 0 | non-digit`
        # (and 19+ digits) as unparseable, `_lease_is_live` then answers LIVE, and test-claims.sh pins
        # "`lease_until=0` reads as UNPARSEABLE => LIVE (rc=1)". Reading 0 as an expired epoch here
        # would be a FIFTH polarity about the same fact — and it would steal a live claim.
        lease_ts = None
        if re.fullmatch(r"\d{1,18}", lease_until) and int(lease_until) != 0:
            lease_ts = float(lease_until)
        elif _ts(lease_until) is not None:
            lease_ts = _ts(lease_until)
        if lease_ts is not None and lease_ts < time.time():
            # ⛔ AN EXPIRED CLAIM IS FREE. `claims.sh` (`_lease_is_live`) and the lander this gate
            # feeds (`merge-one.sh`'s CAS reclaim) both say so. Refusing on a dead lease is the
            # stale-flag defect the fleet ruled is ours to fix (#8175): a box that died mid-review
            # would block this PR forever, with no code path that ever re-validates.
            return "none", f"expired claim {holder} — past its lease, reclaimable"
    return holder, f"claim={holder}"


def _ps_table() -> list[tuple[str, str]] | None:
    """(pid, cmdline) for every process, or None when the table cannot be read (an abstention)."""
    rc, out, _ = run(["ps", "-axo", "pid=,command="], timeout=30)
    if rc != 0:
        return None
    rows = []
    for line in (out or "").splitlines():
        line = line.strip()
        if not line:
            continue
        pid, _, cmd = line.partition(" ")
        rows.append((pid.strip(), cmd.strip()))
    return rows


def rail_state(o: Path, pr: int, ps_rows) -> tuple[str, str]:
    """-> (state, detail). state: idle | running:pid=<n> | UNREADABLE.

    TWO readings, because the lock alone cannot see a rail somebody started by hand:
      * the local landing lock (`$O/state/mergeclaim-<PR>.lock`) with a LIVE pid;
      * every live `admin-merge.sh` whose argv names THIS PR (a hand-started rail is still a rail,
        and a second one would post duplicate head-bound evidence).
    """
    lock = o / "state" / f"mergeclaim-{pr}.lock"
    if lock.exists():
        try:
            pid = read_artifact(lock).strip()
        except (OSError, ValueError):
            pid = ""
        if pid and _pid_alive(pid):
            return f"running pid={pid}", f"rail=running pid={pid} (the landing lock {lock} is held by a LIVING pid)"
    if ps_rows is None:
        # The lock alone cannot see a rail somebody started by hand, and an unread table cannot
        # rule one out — so an unread table is an ABSTENTION, never "idle".
        return UNREADABLE, "rail=UNREADABLE (the process table could not be read)"
    pat = re.compile(r"admin-merge\.sh\b")
    for pid, cmd in ps_rows:
        if pat.search(cmd) and re.search(rf"(^|\s){pr}(\s|$)", cmd):
            return f"running pid={pid}", f"rail=running pid={pid} (a LIVE admin-merge.sh whose argv names {pr})"
    return "idle", ""


# ── the attempts ledger (one attempt per PR per cycle; no blind retry at one head) ────────────
def last_attempt(o: Path, pr: int, head: str) -> int:
    p = o / "state" / ATTEMPTS
    try:
        text = read_artifact(p)
    except (OSError, ValueError):
        return 0
    found = 0
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[0] == str(pr) and parts[1] == head[:40]:
            try:
                found = max(found, int(parts[2]))
            except ValueError:
                continue
    return found


def record_attempt(o: Path, pr: int, head: str, verdict: str) -> None:
    p = o / "state" / ATTEMPTS
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        with p.open("a") as fh:
            fh.write(f"{pr} {head[:40]} {int(time.time())} {verdict}\n")
        # Bounded history: the file exists to suppress a blind retry, not to become a disk leak.
        lines = read_artifact(p).splitlines()[-400:]
        tmp = p.with_suffix(f".tmp.{os.getpid()}")
        tmp.write_text("\n".join(lines) + ("\n" if lines else ""))
        os.replace(tmp, p)
    except OSError:
        pass    # a ledger that cannot be written must not turn a refusal into a dispatch


# ── deploy arm ────────────────────────────────────────────────────────────────────────────────
def read_inventory(o: Path) -> list[tuple[str, str, str]]:
    """`$O/state/boxes.tsv`: `name<TAB>status-cmd<TAB>activate-cmd` per line. Absent = LOCAL ONLY."""
    f = o / "state" / "boxes.tsv"
    rows: list[tuple[str, str, str]] = []
    if f.is_file():
        try:
            try:
                text = f.read_text()
            except UnicodeDecodeError as e:
                # ⛔ A DECODE FAILURE IS AN UNREADABLE INVENTORY. It is a `ValueError`, not an
                # `OSError`, so it escaped every handler above: traceback, exit 1, NO report written and
                # the PREVIOUS cycle's MERGE-REMINDER.md left on disk — a silent stop for as long as the
                # file stayed malformed, which is the exact false-pass shape this file is built against.
                raise Skipped(f"UNREADABLE boxes.tsv — not valid UTF-8 ({e})")
            for line in text.splitlines():
                if not line.strip() or line.lstrip().startswith("#"):
                    continue
                parts = line.split("\t")
                if len(parts) < 3:
                    raise Skipped(f"UNREADABLE boxes.tsv — {f} line is not name<TAB>status<TAB>activate: {line[:80]}")
                rows.append((parts[0].strip(), parts[1].strip(), parts[2].strip()))
        except OSError as e:
            raise Skipped(f"UNREADABLE boxes.tsv — {e}")
        return rows
    probe = Path(__file__).resolve().parent / "box-status.sh"
    if not probe.is_file():
        return []
    return [("local", f"bash {shell_quote(str(probe))} --o {shell_quote(str(o))}",
             local_activate(o))]


def shell_quote(s: str) -> str:
    return "'" + s.replace("'", "'\\''") + "'"


CRON_TAG = "# tortoise-merge-reminder"


NO_CRONTAB_RE = re.compile(r"no crontab for", re.I)


def _systemd_escape(v: str) -> str:
    """A literal `%` in a unit file — systemd would expand it as a specifier."""
    return v.replace("%", "%%")


def _crontab_read() -> tuple[bool, list[str], str]:
    """-> (readable, lines, refusal).

    ⛔ AN UNREADABLE CRONTAB IS NOT AN EMPTY ONE. `crontab -l` exits non-zero both when the user has
    no crontab AND when the spool cannot be read; reading the second as the first made `install`
    REWRITE the crontab from "" — deleting every operator entry — and made `--uninstall-timer` report
    "nothing to remove" and exit 0 while the arm was still installed and firing. The only non-zero
    answer that means "empty" is cron's own no-crontab message (stderr on Linux, stdout on some
    BSDs); anything else is an ABSTENTION, and the caller must not rewrite the spool.
    """
    rc, out, err = run(["crontab", "-l"], timeout=30)
    if rc == 0:
        return True, (out or "").splitlines(), ""
    if NO_CRONTAB_RE.search(out or "") or NO_CRONTAB_RE.search(err or ""):
        return True, [], ""
    return False, [], (f"could not READ the crontab (rc={rc}: {one_line(err) or one_line(out)}) — "
                       f"refusing to rewrite it BLIND, which would delete every other entry")


def _cron_line(o: Path, mins: int) -> str:
    """The crontab entry, quoted for /bin/sh AND for cron.

    ⛔ `%` IS EATEN BY CRON BEFORE THE SHELL EVER SEES IT (it means "newline + stdin"), so a `$O`
    containing one produced an entry cron mangles while the post-write verification still found the
    tag and reported success. Escaped here.
    """
    q_o = shell_quote(str(o)).replace("%", "\\%")
    q_s = shell_quote(str(Path(__file__).resolve())).replace("%", "\\%")
    return f"*/{mins} * * * * O={q_o} /usr/bin/env python3 {q_s} --o {q_o} {CRON_TAG}"


_O_TOKEN = re.compile(r"O='([^']*)'|O=(\S+)")


def _same_o_key(p: str) -> str:
    """One spelling per `$O`: `--o` takes what the operator typed (symlink, relative, `~`).

    ⛔ NEVER RAISES. This runs on text READ FROM A CRONTAB, and `expanduser()` raises RuntimeError for
    an unknown account (`~nosuchuser`) while `resolve()` raises it for a symlink loop — either one
    escaped `--install-timer`/`--uninstall-timer` as a traceback, i.e. an installer that refused
    nothing and removed nothing. An empty token is not a path at all: it stays empty rather than
    silently becoming the reader's own cwd.
    """
    if not p:
        return ""
    try:
        return str(Path(p).expanduser().resolve())
    except (OSError, RuntimeError):
        return p


def _is_our_cron_line(line: str, tag: str, o: Path | None = None) -> bool:
    """True only for a line THIS file wrote: the tag, AND our command, AND our `$O` — or, for an entry
    written before the `$O` token existed, the tag and this script's path.

    ⛔ A bare tag match deleted an operator's own line that merely mentioned it (e.g. a `# paused
    tortoise-merge-reminder during freeze` entry) and reported that as removing our arm (#2603
    review). Install and uninstall share this one predicate.
    """
    if tag not in line:
        return False
    name = Path(__file__).name
    quoted = shell_quote(str(Path(__file__).resolve())).replace("%", "\\%")
    # ⛔ NO SINGLE TEXT KEY IDENTIFIES OUR ENTRY. `$O/<script>` and the checkout copy are the same
    # script to `install.sh`, so keying on the script PATH made a cross-copy uninstall match nothing
    # ("nothing to remove", exit 0, arm firing). Keying on the script NAME made one `$O`'s uninstall
    # delete a peer's arm. Keying on the `O=` token ALONE deleted an operator line that merely
    # MENTIONED our `$O` — the token can sit in a comment — so a token only ever counts together with
    # our command. And the token is compared LITERALLY first: `shell_quote` can emit quotes a regex
    # cannot parse back (`--o /tmp/o'brien` renders `O='/tmp/o'\''brien'`), and a parsed-only match
    # made our OWN line unrecognisable — install then wrote the entry, reported it missing, and each
    # retry appended another live dispatcher.
    if o is not None:
        if ("O=" + shell_quote(str(o)).replace("%", "\\%")) in line and name in line:
            return True
        want = _same_o_key(str(o))
        if want:
            for m in _O_TOKEN.finditer(line):
                val = m.group(1) if m.group(1) is not None else m.group(2)
                if _same_o_key(val.replace("\\%", "%")) == want and name in line:
                    return True
        if _O_TOKEN.search(line):
            return False              # a different `$O`, or a line that only mentions ours
    # An entry written before the `O=` token existed carries only the script's path.
    return quoted in line


def local_activate(o: Path, platform: str | None = None) -> str:
    """The activation verb for THIS box, resolved the way the doctor resolves the rail: the shipped
    location first, then `$O`, then the pi agent scripts.

    ⛔ macOS GETS NO VERB HERE, DELIBERATELY. `cloud-cell-supervisor.sh` is the CELL launcher and says
    so at the top of its own file ("Runs ON the cell (Linux)"); on macOS the controller is launchd's
    and a `stop -> apply -> start` would either refuse or, worse, be emulated by something invented
    here. macOS activation is the harness installer's (`install.sh --restart`), scheduled by
    agent-infra#2416 — so this returns empty, and the deploy arm REPORTS the drift as
    `activate=none` instead of pretending it acted on it.
    """
    platform = platform or sys.platform
    if platform.startswith("darwin"):
        return ""
    for c in (Path(__file__).resolve().parent.parent / "cloud-cell-supervisor.sh",
              o / "cloud-cell-supervisor.sh",
              Path.home() / ".pi/agent/scripts/cloud-cell-supervisor.sh"):
        if c.is_file():
            q = shell_quote(str(c))
            return f"bash {q} stop && bash {q} apply && bash {q} start"
    return ""


def probe_box(name: str, status_cmd: str, timeout: int = 90,
              harness_repo: Path | None = None) -> dict:
    """Run ONE box's status command. -> its parsed reading.

    ⛔ `harness_repo` IS EXPORTED INTO THE CHILD, AND THAT IS NOT DECORATION (#2679). A box's status
    command answers a HARNESS identity, so the `origin/main` it compares against must be the HARNESS
    repo's — and a status command inherits this process's `REPO`, which the fleet sets to the repo the
    cycle SWEEPS. Measured 2026-10-24 on the hub: `REPO=/tmp/cell-t3` (tortoise) reached a
    `box-status.sh` whose `ref:` line then compared the agent-infra pin against a TORTOISE main and
    answered `[unknown]` for a box sitting exactly on the pin. Setting it here fixes every status
    command — the synthesized local one AND the human-provisioned `boxes.tsv` rows, which nothing else
    could reach. An explicit `--repo` inside a row's own command still wins: it is the box's own
    choice about its own probe.
    """
    if harness_repo is not None:
        status_cmd = f"REPO={shell_quote(str(harness_repo))} {status_cmd}"
    rc, out, err = run(["bash", "-c", status_cmd], timeout=timeout)
    text = (out or "") + ("\n" + err if err else "")
    d = {"name": name, "rc": rc, "raw": text, "harness": "", "relation": "", "source": "",
         "controller": "", "ctrl_pids": [], "roles": "", "running": "", "readable": True}
    for line in text.splitlines():
        line = line.strip()
        m = re.match(r"harness:\s*([0-9a-f]{7,40})\s*\[([^\]]+)\]\s*(?:source=(\S+))?", line)
        if m:
            d["harness"], d["relation"] = m.group(1).lower(), m.group(2).strip().lower()
            d["source"] = (m.group(3) or "").strip().lower()
        m = re.match(r"controller:\s*([A-Za-z_]+)(?:\(pid ([0-9, ]*)\))?", line)
        if m:
            d["controller"] = m.group(1).upper()
            # The pid(s) are the only part of `RUNNING` that cannot be pre-existing: a restart the
            # box's own verb failed to perform leaves the OLD process running, and its pid is what
            # tells the two apart (#2603 review: "verified by artifact" accepted one).
            d["ctrl_pids"] = [x for x in re.split(r"[,\s]+", m.group(2) or "") if x.isdigit()]
        # ⛔ THE TREE THE CONTROLLER **EXECUTES**, WHICH THE PIN DOES NOT SAY. `box-status.sh`
        # answers both: `harness:`/`pin:` name what the NEXT launch runs (`harness-refresh.sh`
        # advances the pin for the next launch — the running process keeps executing the tree it
        # booted from), and `running:` names that tree. Reading only the pin certified a box as
        # deployed-and-activated while it executed pre-fix code (#2680).
        m = re.match(r"running:\s*(\S+)\s*$", line)
        if m:
            d["running"] = m.group(1).strip().lower()
        m = re.match(r"roles:\s*(.*)$", line)
        if m:
            d["roles"] = m.group(1).strip()
    if rc != 0 or not d["harness"]:
        d["readable"] = False
    return d


def activation_gap(d: dict) -> str:
    """WHY a box that already names this cycle's harness main is not ACTIVATED — "" when it is.

    ⛔ "ACTIVATED" IS THE TREE THE CONTROLLER EXECUTES, NOT THE PIN A FILE NAMES (#2680). Measured on
    the hub 2026-10-24: the pin and the deployed tree had just been advanced to `f9381dae2ee5`, the
    live controller (pid 1561548) still exec'd
    `/tmp/cell-home/harness/f6a1a01772bd/.../orch-loop.sh`, and `harness-refresh.sh` named that state
    `restart-pending` in its own verdict — while the goal block, reading `controller=RUNNING` off the
    pin, reported "1/1 box(es) ... deployed AND activated". The one state goal 2 exists to catch (a
    merge that is not in effect anywhere) was the state it certified as met.

    Six answers, each a fact about the read and never a default:
      ""                      the controller's argv resolves to this cycle's harness main;
      `restart-pending(...)`  it resolves to a DIFFERENT commit — the pin advanced, the process did not;
      `running=NONE`          no controller process was found to ask (the STOPPED reason owns that);
      `running=UNREADABLE`    a controller is running but its tree could not be resolved;
      `running=MIXED`         two controllers exec two different trees (a restart mid-flight);
      `running=NOT-REPORTED`  the box's status command does not answer the question at all.

    ⛔ A STATUS COMMAND THAT DOES NOT ANSWER IS NOT AN ANSWER. `NOT-REPORTED` exists so an older
    payload (one whose `box-status.sh` predates this line) reads as UNPROVEN here instead of silently
    counting as activated — the same fail-closed rule the roles read already follows.
    """
    if d.get("controller") != "RUNNING":
        return ""                       # STOPPED already names it; saying it twice is a dup reason
    run = (d.get("running") or "").strip().lower()
    if not run:
        return "running=NOT-REPORTED"
    if run in ("none", "unreadable", "mixed"):
        return f"running={run.upper()}"
    if d.get("harness") and run[:12] != d["harness"][:12]:
        return f"restart-pending(running={run[:12]})"
    return ""


DEPLOYS = "merge-reminder.deploys"
# How long a `<lock>.reap` sidecar is believed to be a live reaper. The reap itself is a few
# syscalls, so anything older is an orphan whose pid may have been reused.
REAP_STALE_S = 300
DEPLOY_MAX_ATTEMPTS = 3


def deploy_attempts(o: Path, box: str, frm: str, to: str) -> tuple[int, int, str]:
    """-> (UNVERIFIED attempts since it last reached `to`, epoch of the newest row, that row's VERDICT).

    ⛔ THE VERDICT IS PART OF THE ANSWER. Every dispatched attempt is recorded, including ones that
    ended `VERIFIED … controller=RUNNING`, so "an attempt exists at this pin" is NOT "our last
    activation failed": a successful activation followed by an OPERATOR's stop is a different history,
    and reporting it as the arm's own damage is the same inversion (in the other direction) that this
    reading exists to prevent. Rows whose verdict is `VERIFIED` are not counted as failures.

    ⛔ A DEPLOY NEEDS A BOUND AS MUCH AS A MERGE DOES. Without one, a box that cannot reach
    `origin/main` — pinned `ahead` of it, `diverged` from it, or with an `apply` that never advances
    the pin — is stopped and started EVERY cycle, forever, because every gate that could stop it
    re-opens 600 s later (the deploy lock is released, roles go idle again, the controller comes back
    RUNNING). The ledger is what makes "this has been tried" a fact the next cycle can read.

    ⛔ KEYED ON THE TARGET, NOT ON THE PAIR. The `from` side is a value the ACTION ITSELF CHANGES: an
    activation that moves a box's pin at all (`diverged` -> `behind`, a partial `apply`) changes the
    next cycle's `from`, so a `(box, from, to)` key finds no row, the WAIT and the count reset, and a
    box that creeps forward without ever arriving is restarted every 600 s — the exact restart storm
    this bound exists to prevent. `from` is still RECORDED (it is what makes the ledger readable),
    it is just not part of the identity.
    """
    p = o / "state" / DEPLOYS
    try:
        text = read_artifact(p)
    except (OSError, ValueError):
        return 0, 0, ""
    rows: list[tuple[int, str]] = []
    to12 = to[:12]
    for line in text.splitlines():
        # ⛔ TAB, NOT SPACE: a box name is human-authored (`name<TAB>status<TAB>activate`) and may
        # contain a space, which a whitespace split turns into a DIFFERENT key — so the bound would
        # never bind for that box and it would be restarted every cycle.
        parts = line.split("\t")
        if len(parts) >= 4 and parts[0] == box and parts[2] == to12:
            verdict = (parts[4] if len(parts) > 4 else "").strip()
            try:
                rows.append((int(parts[3]), verdict))
            except ValueError:
                continue
    if not rows:
        return 0, 0, ""
    # ⛔ ORDERED BY EPOCH, NOT BY LINE: an out-of-order (or hand-edited) ledger must not let an old
    # row be read as "the last thing that happened".
    rows.sort()
    last, last_verdict = rows[-1]
    # ⛔ THE BOUND IS THE CURRENT STREAK, NOT A LIFETIME TOTAL. `n` means "unverified attempts SINCE
    # the box last provably reached this pin": a box that failed three times and then VERIFIED has
    # arrived, and carrying those three forever refused every later, legitimate attempt while the
    # refusal quoted a count the ledger's own last row denied.
    reached = max((e for e, v in rows if v.startswith("VERIFIED")), default=-1)
    n = sum(1 for e, v in rows if e > reached and not v.startswith("VERIFIED"))
    return n, last, last_verdict


def record_deploy(o: Path, box: str, frm: str, to: str, verdict: str) -> bool:
    """-> True when the attempt is on disk. ⛔ THE CALLER MUST REPORT A FALSE.

    An unwritable ledger (read-only `$O`, full disk) makes `deploy_attempts` return `(0, 0)` — so the
    bound would report itself satisfied while bounding nothing, an inert enforcer. Recording the
    failure in the verdict is what keeps "no attempts recorded" from meaning two different things.
    """
    p = o / "state" / DEPLOYS
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        with p.open("a") as fh:
            fh.write(f"{box}\t{frm[:12]}\t{to[:12]}\t{int(time.time())}\t"
                     f"{' '.join(verdict.split())}\n")
        lines = read_artifact(p).splitlines()[-400:]
        tmp = p.with_suffix(f".tmp.{os.getpid()}")
        tmp.write_text("\n".join(lines) + ("\n" if lines else ""))
        os.replace(tmp, p)
        return True
    except OSError:
        return False          # a ledger write must not turn a refusal into an action — but it is said


def _controller_pids(d: dict) -> list[str]:
    return [str(x) for x in (d.get("ctrl_pids") or [])]


def deploy_arm(o: Path, main_sha: str, dispatched_landing: bool, verify_s: int,
               dry: bool, act: bool = True, retry_s: int = RETRY_S,
               harness_repo: Path | None = None) -> list[dict]:
    """Question 2 made actionable. Runs AFTER the landing decision by construction (the caller
    passes `dispatched_landing`, and a dispatch in the same cycle suppresses this arm: restarting a
    controller under the rail we just started destroys the run we just paid for).

    ⛔ FIVE THINGS IT REFUSES TO DO. Each is a way an "actuator" becomes an incident:
      1. an UNREADABLE `origin/main` licenses NOTHING. With `main == ""` every box reads as drifted,
         so an abstention would become a restart storm — and the verify loop compares against the
         same empty value, so it could never pass and the box would be stopped and started every
         cycle, forever;
      2. `--no-act` covers BOTH arms. It is the mode a human uses to INSPECT this file before
         trusting it, and a controller restart is more disruptive than the landing that mode
         already suppresses;
      3. a landing attempt LIVE ANYWHERE on this box defers it — not only one this cycle
         dispatched. `--interval` (600s) is shorter than `--rail-wait-s` (900s), so overlapping
         cycles are reachable by construction, and the second one would restart the controller
         under the first one's live rail;
      4. a box whose controller is STOPPED stays stopped: an absent `.desired` is the operator's
         intent, and "make it live again" is not this arm's mandate;
      5. a `source=stamp` identity is never reported as proof of what is RUNNING
         (`harness-refresh.sh`: the stamp can name the NEW commit while the process still executes
         the OLD one). It reads `UNPROVEN`, and it licenses no activation on its own.
    """
    results: list[dict] = []
    if not main_sha:
        return [{"box": "<harness origin/main>", "harness": "", "relation": "", "source": "",
                 "controller": "", "roles": "", "running": "", "drift": False, "log": "",
                 "verdict": "UNREADABLE harness origin/main — no activation (nothing to compare a "
                            "box with)"}]
    try:
        boxes = read_inventory(o)
    except Skipped as e:
        # An unreadable inventory is REPORTED as this cycle's deploy reading; it cannot license a
        # dispatch (there is nothing to dispatch to), and it must not read as "no boxes".
        return [{"box": "<inventory>", "harness": "", "relation": "", "source": "",
                 "controller": "", "roles": "", "drift": True, "verdict": str(e), "log": ""}]
    if not boxes:
        return results
    # ONE deploy at a time across overlapping timers: a second cycle must not act on the same drift
    # while the first is mid-`stop -> apply -> start`.
    deploy_lock = o / "state" / "merge-reminder-deploy.lock"
    held_deploy_lock = False
    try:
        for name, status_cmd, activate_cmd in boxes:
            d = probe_box(name, status_cmd, harness_repo=harness_repo)
            drift = ((not d["readable"]) or (d["harness"][:12] != main_sha[:12])
                     or (d["relation"] != "current"))
            entry = {"box": name, "harness": d["harness"], "relation": d["relation"],
                     "source": d.get("source", ""), "controller": d["controller"],
                     "roles": d["roles"], "running": (d.get("running") or ""),
                     "drift": drift, "verdict": "", "log": ""}
            if not d["readable"]:
                entry["verdict"] = f"UNREADABLE harness={d['harness'] or '<none>'} rc={d['rc']}"
                results.append(entry)
                continue
            if not drift:
                if d.get("source") == "stamp":
                    # The comparison agrees, but the EVIDENCE is a seed record, not a running
                    # process — say so rather than print a `current` that cannot be proven.
                    entry["verdict"] = (f"UNPROVEN harness={d['harness'][:12]} [current] "
                                        f"source=stamp — records what was SEEDED, not what is RUNNING")
                elif d["controller"] != "RUNNING":
                    # ⛔ DEPLOYED IS NOT ACTIVATED, AND THIS ARM'S OWN TABLE SAID "current" FOR A BOX
                    # IT WOULD NOT START: the pin agreed, the controller was STOPPED, and the row read
                    # as healthy one section below a goals block calling the same box
                    # `MARKERS-BROKEN — controller=STOPPED`. Two readers of one box inside one report
                    # is the #1872/#1714 defect, and it is also why the "our last activation did not
                    # verify" attribution below was unreachable for the exact failure it describes (a
                    # `stop -> apply -> start` whose apply succeeded and whose start did not).
                    # ⛔ AND IT CAN SAY WHICH: the ledger holds exactly this fact for an at-pin box, so
                    # "cannot tell an operator's stop from its own failed activation" was a FALSE
                    # limitation — it kept the arm's OWN damage (a `stop -> apply -> start` whose apply
                    # advanced the pin and whose start failed) reading as an operator's intent, which is
                    # the one case a human most needs named.
                    if not d["controller"]:
                        # ⛔ AN EMPTY CONTROLLER IS AN UNREAD ANSWER, NOT A STOPPED ONE. `readable` is
                        # set by the `harness:` line alone, so a status command that never answers the
                        # controller question used to produce `deployed-but-NOT-activated —
                        # controller=<unread> is not RUNNING`, a verdict the read did not support — while
                        # the sibling rule for roles is REFUSE(roles=UNREADABLE).
                        entry["verdict"] = ("UNPROVEN controller=UNREADABLE — the status command did "
                                            "not answer whether the box is running, so this arm cannot "
                                            "say it is deployed-and-activated")
                        results.append(entry)
                        continue
                    n_dep, _last_dep, last_verdict = deploy_attempts(o, name, d["harness"], main_sha)
                    entry["verdict"] = (
                        f"deployed-but-NOT-activated — harness {d['harness'][:12]} [current] is the "
                        f"pin; controller={d['controller']} is not RUNNING. "
                        + ("our activation at this pin VERIFIED and the controller has been stopped "
                           "since (an operator's stop — this arm does not restart it)"
                           if last_verdict.startswith("VERIFIED") else
                           f"OUR last activation of this box did not verify "
                           f"({n_dep} unverified attempt(s); last verdict: "
                           f"{last_verdict or '<none>'}) — a human must confirm the box state before "
                           f"this arm touches it again"
                           if n_dep else
                           "no activation of this box is recorded at this pin, so this arm cannot tell "
                           "an operator's stop from its own failed activation and does not start it"))
                else:
                    gap = activation_gap(d)
                    if gap:
                        # ⛔ THE PIN SAYS THE VERSION, THE PROCESS SAYS WHETHER IT RUNS. A box whose
                        # pin already names this cycle's main but whose controller still executes the
                        # previous tree is the `restart-pending` state `harness-refresh.sh` refuses to
                        # call current — so this table must not call it `current` either (#2680).
                        # It is NOT a drift, so no activation is dispatched: the arm restarts a box
                        # that is on the WRONG commit, and a restart here would kill whatever the live
                        # controller is mid-flight on to gain a deploy the next launch gets anyway.
                        # ⛔ "STILL EXECUTES <sha>" IS A READING, so it is only said when a tree was
                        # READ. For `running=NONE|UNREADABLE|MIXED|NOT-REPORTED` no single executed tree
                        # exists, and asserting one would be the same defect in the other direction —
                        # the verdict word and the action are identical either way.
                        run = (d.get("running") or "").strip().lower()
                        what = (f"the RUNNING controller still EXECUTES {run[:12]}" if run and
                                run not in ("none", "unreadable", "mixed") else
                                "no single executed tree could be read")
                        entry["verdict"] = (
                            f"deployed-but-NOT-activated — harness {d['harness'][:12]} [current] is "
                            f"the pin, but {what} ({gap}). The pin names what the NEXT launch runs; "
                            f"the restart is what activates this box, and this arm does not restart a "
                            f"controller that is mid-flight")
                    else:
                        entry["verdict"] = "current"
                results.append(entry)
                continue
            if dispatched_landing:
                entry["verdict"] = "deferred (a landing was dispatched this cycle)"
                results.append(entry)
                continue
            live = any_rail_live(o, _ps_table())
            if live == UNREADABLE:
                # An unread table cannot rule a landing attempt out, so it cannot license a restart.
                entry["verdict"] = "REFUSE(rail=UNREADABLE) — the process table could not be read"
                results.append(entry)
                continue
            if live:
                entry["verdict"] = f"deferred (a landing attempt is live: {live})"
                results.append(entry)
                continue
            roles = d["roles"].strip().lower()
            if not roles:
                # An ABSENT roles reading is not "idle": a status command that does not answer this
                # question cannot license a restart.
                entry["verdict"] = "REFUSE(roles=UNREADABLE)"
                results.append(entry)
                continue
            if not roles.startswith("idle"):
                # ⛔ A role pass mid-flight is the one state a restart must not enter: the doctor's
                # reap and merge roles hold their own locks, and killing them mid-pass destroys work
                # that no merge re-runs.
                entry["verdict"] = f"REFUSE(roles={roles})"
                results.append(entry)
                continue
            if d["controller"] == "STOPPED":
                # ⛔ THIS ARM CANNOT TELL AN OPERATOR'S STOP FROM ITS OWN FAILED ACTIVATION, so it
                # does not start the box — and it says WHICH one the ledger suggests. (A `stop ->
                # apply -> start` chain whose `apply` failed leaves the cell DOWN; reporting that as
                # "the operator stopped it" would bury the arm's own damage.)
                n, _last, last_verdict = deploy_attempts(o, name, d["harness"], main_sha)
                why = (" — our activation at this pin VERIFIED and the controller has been stopped "
                       "since (an operator's stop; this arm does not restart it)"
                       if last_verdict.startswith("VERIFIED") else
                       f" — our last activation of this box did not verify ({n} unverified "
                       f"attempt(s); last verdict: {last_verdict or '<none>'}); a human must confirm the "
                       f"box state before this arm touches it again"
                       if n else
                       " — this arm cannot tell an operator's stop from its own failed activation, "
                       "so it does not start it")
                entry["verdict"] = f"activate=skipped(controller=STOPPED{why})"
                results.append(entry)
                continue
            if not activate_cmd:
                entry["verdict"] = "activate=none (drifted, no activation verb on this box)"
                results.append(entry)
                continue
            if dry:
                entry["verdict"] = "DRY-RUN would dispatch: " + activate_cmd
                results.append(entry)
                continue
            if not act:
                entry["verdict"] = ("DRIFTED — activate=skipped(--no-act: the reminder-only mode "
                                    "covers BOTH arms)")
                results.append(entry)
                continue
            attempts, last_try, _lv = deploy_attempts(o, name, d["harness"], main_sha)
            if attempts >= DEPLOY_MAX_ATTEMPTS:
                entry["verdict"] = (f"REFUSE(deploy-attempts={attempts} at harness="
                                    f"{d['harness'][:12] or '<none>'}) — this box has not reached "
                                    f"{main_sha[:12]} in {attempts} attempts; a human must look")
                results.append(entry)
                continue
            if last_try and (time.time() - last_try) < retry_s:
                entry["verdict"] = (f"WAIT(deploy-retry-after={int(retry_s - (time.time() - last_try))}s)"
                                    f" — an activation of this box was recorded "
                                    f"{int(time.time() - last_try)}s ago")
                results.append(entry)
                continue
            if not held_deploy_lock:
                taken, info = _take_pid_lock(deploy_lock)
                if not taken:
                    entry["verdict"] = f"deferred (another cycle is deploying: {info})"
                    results.append(entry)
                    continue
                held_deploy_lock = True
            logdir = o / "logs"
            log = logdir / f"merge-reminder-deploy-{name}-{int(time.time())}.log"
            try:
                logdir.mkdir(parents=True, exist_ok=True)
                with log.open("w") as fh:
                    fh.write(f"[{now_iso()}] deploy {name}: {activate_cmd}\n")
                    fh.flush()
                    subprocess.Popen(["bash", "-c", activate_cmd], stdout=fh, stderr=fh,
                                     stdin=subprocess.DEVNULL, start_new_session=True)
            except OSError as e:
                entry["verdict"] = f"DISPATCH-FAILED {type(e).__name__}"
                results.append(entry)
                continue
            entry["log"] = str(log)
            # VERIFY BY ARTIFACT, never by the command's exit code: re-probe until the box reports
            # the main sha as current AND a controller whose pid is NEW, or the bound expires.
            # ⛔ THE PID IS PART OF THE ARTIFACT. `stop -> apply -> start` is one shell chain whose
            # exit code is never read, so a controller that survived a FAILED stop satisfies
            # "RUNNING" while still executing the old tree — and a `source=stamp` identity is
            # rewritten by `apply` BEFORE `start`, so without a new pid a stamp-only box could go
            # `behind` -> `current` with no new process at all. A NEW pid proves a new process.
            pre_pids = set(_controller_pids(d))
            deadline = time.time() + verify_s
            verified = False
            last = None
            while True:
                time.sleep(min(15, max(1, verify_s // 6)))
                last = probe_box(name, status_cmd, harness_repo=harness_repo)
                post_pids = set(_controller_pids(last))
                # ⛔ NO "BEFORE" PID MEANS A NEW PROCESS CANNOT BE PROVEN. Falling back to "any pid
                # at all" is exactly wrong here: the pre-read that carries no pid is a box one deploy
                # BEHIND (an older status command, which is the state this arm exists to fix), and the
                # pid it then finds is the pre-existing controller the check was added to exclude.
                fresh = bool(pre_pids) and bool(post_pids - pre_pids)
                # ⛔ AND THE BOX MUST BE **ACTIVATED**, BY THE SAME PREDICATE THE GOALS USE. Without
                # this term the verify loop wrote `VERIFIED … controller=RUNNING` for a box whose
                # controller still executed the OLD tree — a false PASS recorded in the deploy LEDGER
                # and later quoted back as "our activation at this pin VERIFIED", which stops the arm
                # repairing a box it itself broke. Reachable in the exact state the comment above names:
                # a controller that survived a FAILED stop keeps the old tree, the started replacement
                # supplies the FRESH pid, and the pid satisfies every other term while `box-status.sh`
                # reports `running: MIXED` (or the old sha). One predicate, both readers (#2680).
                gap = activation_gap(last)
                if last["readable"] and last["harness"][:12] == main_sha[:12] \
                        and last["relation"] == "current" and last["controller"] == "RUNNING" \
                        and fresh and not gap:
                    verified = True
                    break
                if time.time() >= deadline:
                    break
            entry["verdict"] = (f"VERIFIED harness={last['harness'][:12]} [current] controller=RUNNING "
                                f"running={(last.get('running') or '?')[:12]}"
                                if verified else
                                f"UNVERIFIED harness={(last or {}).get('harness', '')[:12] or '<none>'} "
                                f"relation={(last or {}).get('relation') or '<none>'} "
                                f"controller={(last or {}).get('controller') or '<none>'} "
                                f"running={(last or {}).get('running') or '<not reported>'} "
                                f"pids={(','.join(_controller_pids(last or {})) or '<none>')} "
                                f"(a NEW pid is required: {','.join(sorted(pre_pids)) or '<none>'} "
                                f"before"
                                + (f"; activation: {gap}" if (last and gap) else "") + ")")
            if not record_deploy(o, name, d["harness"], main_sha, entry["verdict"]):
                entry["verdict"] += (" [⚠️ the deploy ledger could NOT be written — the attempt "
                                     "bound is inert until $O/state is writable]")
            results.append(entry)
    finally:
        if held_deploy_lock:
            try:
                deploy_lock.unlink()
            except OSError:
                pass
    return results


# ── landing decision ──────────────────────────────────────────────────────────────────────────
def decide(pr: dict, attest_state: str, attest_detail: str, surface: dict,
           claim: str, claim_detail: str, rail: str, rail_detail: str,
           retry_s: int, o: Path) -> dict:
    """One candidate -> one verdict + the measured reading it came from.

    ORDER IS THE BRIEF'S, AND IT IS THE ORDER A HUMAN WOULD CHECK: is there anything to land (open,
    not draft, mergeable) → was the CODE ON SCREEN reviewed (head-bound record) → is it quiet →
    is anybody else on it (claim) → is the rail already running. The FIRST failing gate is the named
    refusal, so the line says what to look at rather than listing every gate at once.
    """
    head = pr["head"]
    unread = surface.get("unreadable")
    if unread:
        # Not measured is NOT quiet: the counts below would read `reds=0 in-flight=0` and be a GO
        # derived from a read that never happened.
        readings = (f"pr={pr['state'].upper()} draft={'yes' if pr['draft'] else 'no'} "
                    f"mergeable={pr['mergeable']} reds=UNREADABLE in-flight=UNREADABLE "
                    f"attested@head={attest_state} claim={claim} rail={rail}")
    else:
        readings = (f"pr={pr['state'].upper()} draft={'yes' if pr['draft'] else 'no'} "
                    f"mergeable={pr['mergeable']} reds={len(surface['reds'])} "
                    f"in-flight={len(surface['in_flight'])} attested@head={attest_state} "
                    f"claim={claim} rail={rail}")
    out = {"readings": readings, "verdict": "", "detail": "", "dispatch": False,
           "reds": len(surface["reds"]), "red_labels": surface["reds"][:4],
           "attest_detail": attest_detail, "claim_detail": claim_detail,
           "rail_detail": rail_detail}

    if pr["state"].lower() != "open":
        out.update(verdict=f"{REFUSE}(pr={pr['state'].lower()})", detail="the PR is not open")
        return out
    if pr["draft"]:
        out.update(verdict=f"{REFUSE}(draft)", detail="a draft PR is not a landing candidate")
        return out
    if pr["mergeable"] != "MERGEABLE":
        # `mergeable: null` is GitHub saying "not computed yet" — UNKNOWN, and unknown is a WAIT.
        detail = ("the single-PR mergeability read was outside this cycle's REST budget — an unread "
                  "value is a WAIT, never a GO" if pr["mergeable"] == "NOT-READ" else
                  "GitHub does not report MERGEABLE (null = not computed yet)")
        out.update(verdict=f"{REFUSE}(mergeable={pr['mergeable'].lower()})", detail=detail)
        return out
    if attest_state == UNREADABLE:
        out.update(verdict=f"{REFUSE}(attested=UNREADABLE)", detail=attest_detail)
        return out
    if attest_state != "yes":
        out.update(verdict=f"{REFUSE}(attested={attest_state})",
                   detail=attest_detail + " — a stale record is not a record")
        return out
    if unread:
        out.update(verdict=f"{REFUSE}(UNREADABLE)", detail=unread)
        return out
    if not surface.get("groups"):
        # ⛔ ABSENCE OF EVIDENCE IS NOT EVIDENCE OF GREEN. A head pushed moments ago carries no check
        # runs and no commit statuses, and a review record can exist before CI registers anything: a
        # surface of ZERO groups would otherwise read `reds=0 in-flight=0` and be a GO on a head that
        # was never tested. (`groups` is computed for exactly this question.)
        out.update(verdict=f"{REFUSE}(surface=empty)",
                   detail="the head carries NO check runs and NO commit statuses — an empty surface "
                          "is not a green one (a just-pushed head, or a read that returned nothing)")
        return out
    if surface["reds"]:
        out.update(verdict=f"{REFUSE}(reds={len(surface['reds'])})",
                   detail="newest attempt per group is RED: " + "; ".join(surface["reds"][:4]))
        return out
    if surface["in_flight"]:
        # reds=0 with checks in flight is a WAIT, never a GO (#2522/#2592).
        out.update(verdict=f"{REFUSE}(in-flight={len(surface['in_flight'])})",
                   detail="checks still in flight: " + "; ".join(surface["in_flight"][:4]))
        return out
    if claim == UNREADABLE:
        out.update(verdict=f"{REFUSE}(claim=UNREADABLE)", detail=claim_detail)
        return out
    if claim != "none":
        out.update(verdict=f"{REFUSE}(claim={claim})",
                   detail="another lander holds this PR: " + claim_detail)
        return out
    if rail == UNREADABLE:
        out.update(verdict=f"{REFUSE}(rail=UNREADABLE)", detail=rail_detail)
        return out
    if rail != "idle":
        out.update(verdict=f"{REFUSE}(rail={rail})", detail=rail_detail)
        return out
    prev = last_attempt(o, pr["number"], head)
    if prev and (time.time() - prev) < retry_s:
        out.update(verdict=f"{WAIT}(retry-after={int(retry_s - (time.time() - prev))}s)",
                   detail=f"a rail attempt at this head was recorded {int(time.time() - prev)}s ago "
                          f"— not retried blind; a push moves the head and re-arms it")
        return out
    out.update(verdict=GO, detail="every gate passed")
    return out


# ── dispatch ─────────────────────────────────────────────────────────────────────────────────
def resolve_rail(explicit: str, o: Path) -> str | None:
    here = Path(__file__).resolve().parent
    cands = [explicit] if explicit else []
    cands += [str(o / "admin-merge.sh"), str(here.parent / "admin-merge.sh"),
              str(here / "admin-merge.sh"),
              str(Path.home() / ".pi/agent/scripts/admin-merge.sh")]
    for c in cands:
        if c and os.path.isfile(c) and os.access(c, os.X_OK):
            return str(Path(c).resolve())
    return None


def _take_pid_lock(path: Path) -> tuple[bool, str]:
    """Create `path` with O_EXCL and our pid inside -> (taken, detail).

    ⛔ A DEAD PID IS REAPED, NOT RESPECTED. These locks are written by a 10-minute timer, so a
    SIGKILL or a crash leaves a pid file whose owner is gone; treating that as "somebody is landing"
    is the stale-flag class that starves the gate forever (#8175).

    ⛔ AND THE REAP ITSELF IS SERIALISED. `unlink` + `O_EXCL`-create is NOT atomic against a second
    reaper: two processes that both read the same dead pid can both unlink, and the second can
    unlink the FIRST one's freshly written lock — after which both return `taken=True` and two rails
    run for one PR, the exact defect this lock exists to prevent (#2603 review, reproduced). So the
    reap runs under `<lock>.reap`, the pid is re-read UNDER that mutex (a live creator may have
    replaced the file since our first read), and a creator that wins the unlink window makes the
    reaper's create fail — one winner either way. The reap mutex is itself reapable when its owner
    is dead, for the same reason as the lock.
    """
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
    except OSError as e:
        return False, f"DISPATCH-FAILED lock={type(e).__name__}"

    def _create():
        try:
            return os.open(str(path), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
        except FileExistsError:
            return None
        except OSError as e:
            # A read-only/full `$O` must be a REPORTED refusal, not an exception out of the cycle:
            # `main` catches Skipped, and an uncaught OSError here wrote no MERGE-REMINDER.md at all.
            raise Skipped(f"DISPATCH-FAILED lock={type(e).__name__}: {e}")

    def _take(fd) -> tuple[bool, str]:
        os.write(fd, str(os.getpid()).encode())
        os.close(fd)
        return True, "taken"

    try:
        fd = _create()
    except Skipped as e:
        return False, str(e)
    if fd is not None:
        return _take(fd)
    def _reapable(pid: str) -> tuple[bool, str]:
        """-> (may we reap it, the refusal when we may not). ONE rule for BOTH reads."""
        if pid.isdigit():
            return (False, f"running pid={pid}") if _pid_alive(pid) else (True, "")
        # ⛔ A LOCK WITH NO (OR GARBLED) PID IS A CREATOR MID-WRITE, NOT A DEAD OWNER. `_create()`
        # opens with O_EXCL and `_take()` writes the pid a moment later; a racer reading in that
        # window sees an EMPTY file, which `_pid_alive("")` calls dead — and it would then reap a
        # LIVE creator's lock, giving two winners and two rails for one PR (measured 2 in 40
        # trials). Garbage is only assumed stale once the file is older than the window in which a
        # writer could still be about to write it.
        try:
            age = time.time() - path.stat().st_mtime
        except OSError:
            age = REAP_STALE_S
        if age < REAP_STALE_S:
            return False, f"running (the lock carries no usable pid yet: {age:.0f}s old)"
        return True, f"reaping (no usable pid, {age:.0f}s old)"

    try:
        pid = read_artifact(path).strip()
    except (OSError, ValueError):
        pid = "?"
    ok, why = _reapable(pid)
    if not ok:
        return False, why

    reap = path.with_name(path.name + ".reap")
    rfd = None
    for _attempt in (0, 1):
        try:
            rfd = os.open(str(reap), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
            break
        except FileExistsError:
            # The mutex carries `<pid> <epoch>`: `kill -0` alone cannot tell a live reaper from a
            # REUSED pid, and a reused pid would fence the reap for as long as that unrelated process
            # lives. The reap window is milliseconds, so an old entry is stale by age.
            try:
                fields = reap.read_text().split()
                rpid = fields[0] if fields else "?"
                rage = int(fields[1]) if len(fields) > 1 else 0
            except (OSError, ValueError):
                rpid, rage = "?", 0
            # ⛔ THE MUTEX HAS THE SAME CREATOR-MID-WRITE WINDOW AS THE LOCK. It is `O_EXCL`-created
            # and only THEN written, so a racer that reads in between sees an EMPTY sidecar; "no
            # usable pid" must not be read as "no owner", or it unlinks the LIVE mutex its peer is
            # about to occupy and BOTH reapers enter the critical section — measured, and the same
            # rule the lock itself already applies (§25d).
            if not rpid.isdigit():
                try:
                    mage = time.time() - reap.stat().st_mtime
                except OSError:
                    mage = REAP_STALE_S
                if mage < REAP_STALE_S:
                    return False, ("running (a reap is starting: its mutex carries no usable pid "
                                   f"yet, {mage:.0f}s old)")
            # An ABSENT epoch (the pre-upgrade sidecar, or an unreadable one) cannot be aged, so a
            # LIVE pid is believed: unlink it and two reapers enter the critical section together.
            aged = bool(rage) and (time.time() - rage) >= REAP_STALE_S
            if _pid_alive(rpid) and not aged:
                return False, f"running (a reap is in progress pid={rpid})"
            try:
                reap.unlink()          # a dead OR aged reaper is the same stale flag, one level down
            except OSError:
                return False, f"stale-lock pid={pid} (the reap mutex could not be cleared)"
        except OSError as e:
            return False, f"stale-lock pid={pid} ({type(e).__name__}: could not serialise the reap)"
    if rfd is None:
        return False, "running (a reap is in progress)"
    try:
        os.write(rfd, f"{os.getpid()} {int(time.time())}".encode())
        os.close(rfd)
        try:
            pid2 = read_artifact(path).strip()
        except (OSError, ValueError):
            pid2 = pid
        # The SAME window can open again between our first read and this one: the pid is re-read UNDER
        # the mutex precisely because a creator may have replaced the file — so the SAME rule decides.
        ok2, why2 = _reapable(pid2)
        if not ok2:
            return False, why2
        try:
            path.unlink()
        except OSError:
            pass
        fd = _create()
        if fd is None:
            return False, "running (a creator won the reap window)"
        return _take(fd)
    finally:
        try:
            reap.unlink()
        except OSError:
            pass


def any_rail_live(o: Path, ps_rows) -> str:
    """The detail of ANY live landing attempt on this box, "" when none is visible, or UNREADABLE.

    TWO readings, because a pid file only sees what wrote it: every `mergeclaim-*.lock` with a LIVE
    pid, and any live `admin-merge.sh` / `merge-one.sh` in the process table. `merge-one.sh` counts
    because it IS a lander — restarting a controller under it is the same destruction as under the
    rail.
    """
    for lock in sorted((o / "state").glob("mergeclaim-*.lock")):
        try:
            pid = read_artifact(lock).strip()
        except (OSError, ValueError):
            continue
        if pid and _pid_alive(pid):
            return f"{lock.name} pid={pid}"
    if ps_rows is None:
        return UNREADABLE
    me = {str(os.getpid()), str(os.getppid())}
    for pid, cmd in ps_rows:
        # ⛔ NOT OUR OWN INVOCATION: `--rail <path>/admin-merge.sh` puts the rail's NAME in this
        # process's own argv, and without this the arm refused itself on every cycle ("a landing
        # attempt is live: admin-merge.sh pid=<self>") — a self-refusal that blames a rail that does
        # not exist. A process running THIS script is never the rail it is about to dispatch.
        if pid in me or "merge-reminder.py" in cmd:
            continue
        m = re.search(r"(\S*(?:admin-merge|merge-one)\.sh)\b", cmd)
        if m:
            return f"{m.group(1).rsplit('/', 1)[-1]} pid={pid}"
    return ""


def dispatch_rail(rail: str, pr: int, slug: str, o: Path, wait_s: int) -> tuple[bool, str, str]:
    """Take the LOCAL landing lock (`mergeclaim-<PR>.lock`, the artifact merge-one.sh honours) and
    dispatch the rail in the background, its own log, no shell, no override.

    ⛔ The lock is taken with O_EXCL AFTER the gates and IMMEDIATELY before the spawn: the gates are
    reads, so between "claim=none" and "spawn" another lander on this box could take it. Whoever
    wins the create is the one attempt for this PR.
    ⛔ A DEAD-PID LOCK IS REAPED ONLY WHEN NO LANDING ATTEMPT IS LIVE. The dead pid proves nobody
    holds the LOCK; it does not prove no rail is in flight — a rail started by hand, or one whose
    pid file was written by a process that has since exited, is invisible to the file. So the
    process scan is consulted first, and when it names a live attempt the refusal is
    `rail=running`, not a reap.
    """
    # ⛔ READ THE TABLE AT THE MOMENT OF ACTION, ON EVERY PATH. The gates read a snapshot taken
    # BEFORE this cycle's REST calls (up to 2 candidates x 3 reads), and `admin-merge.sh` takes no
    # lock of its own — so a rail a human (or another agent) started in that window was invisible
    # when there was no lock file to inspect, which is the COMMON first-dispatch path.
    live = any_rail_live(o, _ps_table())
    if live == UNREADABLE:
        return False, "rail=UNREADABLE", ""
    if live:
        return False, f"rail=running ({live})", ""
    lock = o / "state" / f"mergeclaim-{pr}.lock"
    taken, info = _take_pid_lock(lock)
    if not taken:
        if info.startswith("running") or info.startswith("stale-lock"):
            return False, f"rail={info}", ""
        return False, info, ""

    logdir = o / "logs"
    logdir.mkdir(parents=True, exist_ok=True)
    log = logdir / f"merge-reminder-rail-{pr}-{int(time.time())}.log"
    try:
        with log.open("w") as fh:
            fh.write(f"[{now_iso()}] dispatch: {rail} {pr} --repo {slug}\n")
            fh.flush()
            child = subprocess.Popen([rail, str(pr), "--repo", slug], stdout=fh, stderr=fh,
                                     stdin=subprocess.DEVNULL, start_new_session=True)
    except OSError as e:
        try:
            lock.unlink()
        except OSError:
            pass
        return False, f"DISPATCH-FAILED spawn={type(e).__name__}", ""
    # Wait, bounded, so the lock's pid is a LIVE lander while the rail runs (and so the cycle can
    # report the rail's OWN exit code instead of assuming the spawn was a success).
    # ⛔ PAST THE BOUND THE LOCK IS LEFT IN PLACE. It holds our pid, which is alive for as long as
    # this cycle is — and once we exit it is a DEAD pid, which the next cycle reaps ONLY IF no
    # landing attempt is live. Deleting it here would remove the fence while the rail is still
    # running, which is the two-landings-one-PR defect this lock exists to prevent.
    try:
        rc = child.wait(timeout=wait_s)
        detail = f"rc={rc}"
    except subprocess.TimeoutExpired:
        detail = (f"still-running pid={child.pid} after {wait_s}s (the landing lock {lock.name} is "
                  f"LEFT in place as the fence)")
    else:
        try:
            lock.unlink()
        except OSError:
            pass
    return True, detail, str(log)


# ── landing cycle ────────────────────────────────────────────────────────────────────────────
def read_prs(budget: Budget, slug: str, max_prs: int) -> list[dict]:
    rc, out, err = budget.api(f"repos/{slug}/pulls?state=open&per_page={max_prs}")
    if rc != 0:
        raise Skipped(f"UNREADABLE pulls rc={rc} {one_line(err)}")
    try:
        rows = json.loads(out)
    except ValueError:
        raise Skipped("UNREADABLE pulls — the answer was not JSON")
    if not isinstance(rows, list):
        raise Skipped("UNREADABLE pulls — the answer was not a JSON list")
    if len(rows) >= max_prs:
        # ⛔ A FULL PAGE IS A TRUNCATED READ, and this listing carries no `total_count` to prove
        # otherwise. Measured 2026-10-24: agent-infra had 70 open PRs against a 30-row page, so 40
        # were INVISIBLE — the rank denominators undercounted and an attested+quiet PR below the cut
        # could never be dispatched. This file already refuses a full statuses page and a
        # page-truncated check surface for the same reason; the listing was the one read that did not.
        raise Skipped(f"UNREADABLE pulls — the listing filled its {max_prs}-row page "
                      f"({len(rows)} row(s) read), so the queue may be truncated. ⛔ THIS TOOL CANNOT "
                      f"PAGE IT (no Link-header pagination) and `--max-prs` cannot exceed the API's "
                      f"100-row cap: the actionable bound is to bring the open-PR queue under 100, and "
                      f"pagination is a named follow-up - not a flag an operator can raise")
    prs = []
    for r in rows:
        if not isinstance(r, dict):
            continue
        head = str(((r.get("head") or {}) if isinstance(r.get("head"), dict) else {}).get("sha") or "")
        if not re.fullmatch(r"[0-9a-fA-F]{40}", head):
            # A PR whose head cannot be read is NOT a candidate (a head-bound record cannot be
            # matched to nothing) — but it is still LISTED, so the reminder never silently shrinks.
            head = ""
        mergeable = r.get("mergeable")
        prs.append({
            "number": int(r.get("number") or 0),
            "title": one_line(str(r.get("title") or ""))[:120],
            "head": head,
            "state": str(r.get("state") or "open"),
            "draft": bool(r.get("draft")),
            "mergeable": ("MERGEABLE" if mergeable is True else
                          "CONFLICTING" if mergeable is False else "UNKNOWN"),
            "updated": str(r.get("updated_at") or ""),
        })
    return [p for p in prs if p["number"]]


def rank(prs: list[dict], o: Path, reviews: Path, slug: str) -> list[dict]:
    """Closest-to-landing FIRST, using evidence that costs NOTHING to read: a record at the live
    head is the strongest free signal, then not-draft, then mergeable, then the least recently
    attempted (round-robin fairness across cycles — a queue that always reads the same two heads
    never reaches the third)."""
    for p in prs:
        if p["head"]:
            st, _ = attest(o, reviews, slug, p["number"], p["head"])
            p["_attest"] = st
            p["_attempt"] = last_attempt(o, p["number"], p["head"])
        else:
            p["_attest"], p["_attempt"] = "UNREADABLE", 0
    return sorted(prs, key=lambda p: (
        0 if p["_attest"] == "yes" else 1,
        0 if not p["draft"] else 1,
        0 if p["mergeable"] == "MERGEABLE" else 1,
        p["_attempt"],
        p["number"],
    ))


def landing_cycle(args, o: Path, slug: str, repo_path: Path, budget: Budget):
    prs = read_prs(budget, slug, args.max_prs)
    if not prs:
        # A read that SUCCEEDED and listed nothing is a fact; an unreadable one raised above and is
        # SKIPPED by the caller. The two must never render the same.
        return [], False
    ranked = rank(prs, o, Path(args.reviews).expanduser(), slug)
    ps_rows = _ps_table()
    # ⛔ MERGEABILITY IS NOT COMPUTED ON THE LIST ENDPOINT. `GET /pulls?state=open` answers
    # `mergeable: null` for EVERY PR — measured 2026-10-24 on agent-infra, 10/10 open PRs, with
    # `GET /pulls/<n>` returning `true` for the same heads. A null read as `REFUSE(mergeable=unknown)`
    # therefore made this arm INERT: a gate that could never pass, forever, while the report looked
    # like it was working. The single-PR read DOES populate the field, so every candidate this cycle
    # actually reads re-reads it there, and a budget that cannot afford the read says `NOT-READ`
    # rather than inheriting a value the server never calculated.
    for p in ranked[: args.candidates]:
        if p["mergeable"] != "UNKNOWN" or not p["head"]:
            continue
        try:
            rc, out, _err = budget.api(f"repos/{slug}/pulls/{p['number']}")
        except Skipped:
            p["mergeable"] = "NOT-READ"
            continue
        if rc != 0:
            p["mergeable"] = "NOT-READ"
            continue
        try:
            detail = json.loads(out)
        except ValueError:
            detail = None
        m = detail.get("mergeable") if isinstance(detail, dict) else None
        if m is True:
            p["mergeable"] = "MERGEABLE"
        elif m is False:
            p["mergeable"] = "CONFLICTING"
        # A still-null answer stays UNKNOWN: GitHub computes mergeability lazily, and "not computed
        # yet" is a WAIT — never a GO, and never an excuse to guess.
    surface_for: dict[int, dict | None] = {p["number"]: None for p in ranked}
    for p in ranked[: args.candidates]:
        if not p["head"]:
            surface_for[p["number"]] = {"reds": [], "in_flight": [], "groups": 0,
                                        "unreadable": "the head sha could not be read from the PR listing"}
            continue
        try:
            surface_for[p["number"]] = check_surface(budget, slug, p["head"])
        except Skipped as e:
            # ONE candidate's surface unreadable does not poison the whole cycle — and it must not
            # shrink to "quiet" either. It is an UNREADABLE reading for THIS PR (no GO from it).
            surface_for[p["number"]] = {"reds": [], "in_flight": [], "groups": 0,
                                        "unreadable": str(e)}

    results = []
    dispatched = False
    for i, p in enumerate(ranked, start=1):
        surface = surface_for.get(p["number"])
        if surface is None:
            # Not read this cycle (REST budget): reported as NOT MEASURED rather than as quiet.
            results.append({"pr": p, "rank": i,
                            "readings": (f"pr={p['state'].upper()} draft={'yes' if p['draft'] else 'no'} "
                                         f"mergeable={p['mergeable']} reds=NOT-READ "
                                         f"attested@head={p['_attest']} claim=NOT-READ rail=NOT-READ"),
                            "verdict": "NOT-MEASURED (outside this cycle's read budget)",
                            "detail": f"the top {args.candidates} candidates were read",
                            "dispatch": False, "reds": 0, "red_labels": []})
            continue
        try:
            st, detail = (attest(o, Path(args.reviews).expanduser(), slug,
                                 p["number"], p["head"])
                          if p["head"] else (UNREADABLE, "the head sha could not be read"))
            claim, claim_detail = (claim_state(o, repo_path, p["number"], p["head"])
                                   if p["head"] else (UNREADABLE, "no head to key a claim on"))
            rail, rail_detail = rail_state(o, p["number"], ps_rows)
        except OSError as e:
            # ⛔ ONE CANDIDATE'S read failing must not UNMAKE A DISPATCH THIS CYCLE ALREADY MADE.
            # An OSError here (a fork/exec failure under load, a non-executable git) used to escape
            # `main`, which reported "SKIPPED … (no dispatch)" while a rail was running — an
            # invitation to hand-dispatch the same PR and end up with two rails on one lock.
            results.append({"pr": p, "rank": i,
                            "readings": (f"pr={p['state'].upper()} "
                                         f"draft={'yes' if p['draft'] else 'no'} "
                                         f"mergeable={p['mergeable']} reds=NOT-READ "
                                         f"attested@head=NOT-READ claim=NOT-READ rail=NOT-READ"),
                            "verdict": f"SKIPPED(UNREADABLE {type(e).__name__})",
                            "detail": f"this candidate's gates could not be read: {e}",
                            "dispatch": False, "reds": 0, "red_labels": []})
            continue
        d = decide(p, st, detail, surface, claim, claim_detail, rail, rail_detail,
                   args.retry_s, o)
        d.update({"pr": p, "rank": i})
        if d["verdict"] == GO and not dispatched:
            if args.dry_run or not args.act:
                d["verdict"] = "GO (not dispatched: " + ("--dry-run" if args.dry_run else "--no-act") + ")"
                d["detail"] = "every gate passed"
            else:
                rail_bin = resolve_rail(args.rail, o)
                if not rail_bin:
                    d["verdict"] = "REFUSE(rail=missing)"
                    d["detail"] = ("admin-merge.sh was not found (looked at --rail, $O, the shipped "
                                   "location, ~/.pi/agent/scripts) — the rail is the authority and "
                                   "there is no substitute for it")
                else:
                    ok, info, log = dispatch_rail(rail_bin, p["number"], slug, o, args.rail_wait_s)
                    if ok:
                        dispatched = True
                        d["dispatch"] = True
                        d["verdict"] = f"GO dispatched ({info})"
                        d["detail"] = f"{rail_bin} {p['number']} --repo {slug} → {log}"
                        # Recorded whether the rail then refused or merged: the ledger exists to stop
                        # a BLIND retry at one head, and a refusal is the strongest reason not to.
                        record_attempt(o, p["number"], p["head"], f"rail ({info})")
                    else:
                        d["verdict"] = f"REFUSE({info})"
                        own = ("DISPATCH-FAILED" in info) or ("stale-lock" in info)
                        d["detail"] = ("this cycle could not take the lock (the reading names "
                                       "why) — not necessarily another lander" if own else
                                       "another lander won the lock at the moment of action")
        elif d["verdict"] == GO:
            # A GO that was not the FIRST one this cycle still must not read like a dispatch.
            d["verdict"] = "GO (held: one dispatch per cycle)"
        results.append(d)
    return results, dispatched


# ── the goals (measured BEFORE the PR reads) ───────────────────────────────────────────────

def drift_rows(o: Path, main_sha: str, harness_repo: Path | None = None) -> list[dict]:
    """Where each box's harness stands WITHOUT ACTING — the cheap half of the deploy arm.

    ⛔ MEASURED FIRST, BEFORE THE PR READS. The goals are what the PR queue is FOR, and a cycle that
    spends its reads on the queue first reports on the queue and leaves the goals unmeasured — the
    measured failure (2026-10-24): the PR reads took the whole core budget (`8/8` at 04:22Z) and
    every goal line said "not measured". A reminder that reports on PRs and forgets what the PRs
    are for is a reminder that optimises the queue instead of the objective.

    This makes NO REST call — it reads artifacts on the boxes (`$O/state/boxes.tsv`, and
    `box-status.sh` beside this script for the local box) — which is exactly why it can go first.

    ⛔ `[current]` IS NOT "ON MAIN", AND THIS FUNCTION MUST NOT LET IT READ AS ONE. `box-status.sh`
    computes `relation` against ITS OWN checkout's `origin/main` (its `REF=origin/main`), which is not
    necessarily the checkout `repo_path_of` picked — so a box can answer `[current]` while running a
    different commit from the `main_sha` this cycle read, and a `source=stamp` identity records what
    was SEEDED, not what is RUNNING (`harness-refresh.sh`; the deploy arm refuses to license anything
    on it for exactly that reason). A goal line that counted `relation == "current"` as "the same
    version everywhere" was a fail-open: measured, it printed `MARKERS-HOLD` for two boxes whose
    harness was `deadbeef` against `main=848ba4b1`, while `deploy_arm` on the same inventory and the
    same main reported drift for both. Hence `on_pin`, which carries every term the deploy arm uses.

    It NEVER raises: an unreadable inventory or a failed probe becomes a row that SAYS SO, because a
    goal line silently missing the drifted cell reads like the cell is fine.
    """
    try:
        boxes = read_inventory(o)
    except Skipped as e:
        return [{"box": "<inventory>", "harness": "", "relation": "", "readable": False,
                 "on_pin": False, "reasons": [], "inventory": "unread", "note": str(e)}]
    if not boxes:
        # ⛔ TWO DIFFERENT EMPTIES. A file that EXISTS and lists no rows is one state; a missing file
        # whose local fallback is also unavailable (`box-status.sh` not beside this script — a staged
        # install) is another. `read_inventory` returns [] for both, so the state is decided from the
        # file itself: reporting "the inventory exists and lists NO boxes" about a file that does not
        # exist is the same class of invented reading this block exists to refuse.
        present = (o / "state" / "boxes.tsv").is_file()
        return [{"box": "<inventory>", "harness": "", "relation": "", "readable": False,
                 "on_pin": False, "reasons": [],
                 "inventory": "empty" if present else "noprobe",
                 "note": ("the inventory exists and lists NO boxes" if present else
                          "no `state/boxes.tsv` and no `box-status.sh` — nothing could be probed")}]
    rows: list[dict] = []
    for name, status_cmd, _activate in boxes:
        # ⛔ A SUMMARY READ, BOUNDED SHORT: this probe runs BEFORE the landing decision, so an
        # unreachable box must not put `timeout`-seconds of dead time in front of a dispatch (the
        # timer is 600 s and `--rail-wait-s` already overlaps it by design). The deploy arm keeps its
        # OWN moment-of-action probe — that reading gates an activation, and a cached one would be
        # evidence from minutes ago — which is why the two can disagree within one report: the deploy
        # table is the later, authoritative read.
        d = probe_box(name, status_cmd, timeout=15, harness_repo=harness_repo)
        # ⛔ `read_inventory` SYNTHESISES a one-row "local" fleet when `boxes.tsv` is absent, so
        # MARKERS-HOLD could be printed over a ONE-BOX read while goal 2 says "the local box AND all
        # three cmux cells" — and nothing distinguished "a one-box fleet" from "the inventory is
        # gone". The row carries which one it was.
        # ⛔ `on_pin` CARRIES EVERY TERM, INCLUDING THE ACTIVATION. Goal 2 is "the SAME harness
        # version DEPLOYED **AND ACTIVATED**": a box whose pin is main but whose controller is
        # STOPPED has deployed the version and is not running it — and that is exactly the row this
        # arm's own damage leaves behind (a `stop -> apply -> start` whose `apply` advances the pin
        # and whose `start` fails). Counting it as `MARKERS-HOLD` reported the fleet as autonomous in
        # the one state the deploy arm exists to repair, so `controller != RUNNING` is a reason too.
        reasons: list[str] = []
        if not d["readable"] or not d["harness"]:
            # ⛔ NOTHING WAS COMPARED FOR A BOX THAT DID NOT ANSWER. Falling through appended "a different
            # commit from this cycle's main" to a probe that printed no `harness:` line at all — an
            # invented comparison, in the reason list the action quotes.
            reasons.append("the probe did not answer")
        else:
            if d["relation"] != "current":
                reasons.append(f"relation={d['relation'] or '?'}")
            if not main_sha:
                reasons.append("main=UNREADABLE (not compared)")
            elif d["harness"][:12] != main_sha[:12]:
                reasons.append("a different commit from this cycle's main")
            if d.get("source") == "stamp":
                reasons.append("source=stamp(seeded, not running)")
            if d["controller"] != "RUNNING":
                reasons.append(f"controller={d['controller'] or '<unread>'}")
            # ⛔ AND THE ACTIVATION TERM, WHICH IS THE TREE THE CONTROLLER EXECUTES (#2680). Only
            # asked when nothing else already explains the row: a box that is behind says WHY it is
            # behind, and a second reason about a tree that is older by definition is noise in the
            # sentence the owner acts on.
            if not reasons:
                gap = activation_gap(d)
                if gap:
                    reasons.append(gap)
        rows.append({"box": name, "harness": d["harness"][:12], "relation": d["relation"],
                     "source": d.get("source", ""), "controller": d["controller"],
                     "roles": d["roles"], "running": (d.get("running") or ""), "readable": bool(d["readable"]),
                     "on_pin": bool(d["readable"] and not reasons), "reasons": reasons,
                     "inventory": "file" if (o / "state" / "boxes.tsv").is_file() else "absent",
                     "note": ""})
    return rows


def _drift_text(rows: list[dict]) -> str:
    if not rows:
        return "NOT-MEASURED (the box inventory was not read)"
    parts = []
    for r in rows:
        if r.get("inventory") in PLACEHOLDER:
            # ⛔ A PLACEHOLDER ROW IS NOT A BOX. Printing it as `UNREADABLE` beside a fraction of it
            # ("0/1") read as one probed box that failed, so the report told the owner to deploy a box
            # that does not exist. It says what happened instead.
            # ⛔ A SHORT STATE TOKEN, NOT THE SENTENCE: `boxes.tsv=no `state/boxes.tsv`` asserts and
            # denies the same file, and the sentence follows verbatim in the parenthetical one line
            # below. The sentence lives in the ⚠️ line and in `why_not_compared`; this is the row.
            parts.append("boxes.tsv=" + {"unread": "UNREADABLE", "empty": "NO-ROWS",
                                         "noprobe": "NO-PROBE"}.get(r["inventory"], "UNREADABLE"))
        elif not r["readable"]:
            parts.append(f"{r['box']}=UNREADABLE")
        else:
            tag = f"{r['harness'] or '<none>'} [{r['relation'] or '?'}]"
            if r.get("reasons"):
                tag += " — " + "; ".join(r["reasons"])
            parts.append(f"{r['box']}={tag}")
    return " · ".join(parts)


def goal_progress(drift: list[dict], budget: Budget, slug: str,
                  skipped: str = "", main_sha: str = "",
                  main_why: str = "") -> tuple[list[str], list[str]]:
    """Measure BOTH goals. -> (the readings as markdown lines, what to do IN GOAL ORDER).

    ⛔ A COUNT THAT COULD NOT BE READ IS `NOT-MEASURED`, NEVER `0`. Zero is a claim ("there are
    none"), and the whole point of this block is that the claims are derived from a reading. Each
    count is a SERVER-SIDE filter — see `_count` for why a local slice undercounts.

    The standing words are deliberately not cheerwords:
      `DONE`          every count read, and no open P0/P1 remains (goal 1 only);
      `OPEN`          counts read, work remains;
      `MARKERS-HOLD`  every box's harness EQUALS this cycle's `origin/main`, its own `relation` is
                      `current`, its `source` is not `stamp`, and its `controller` is RUNNING — the
                      MARKERS hold. That is not proof of autonomy: a drifting box or a queue that
                      grows faster than it lands breaks these markers first. The QUEUE is a separate
                      reading and never moves this word (a count that did not come back says so);
      `MARKERS-BROKEN` a box is off-pin, unreadable, seeded (`source=stamp`) or not RUNNING — and
                      `main` unreadable, because then nothing was compared;
      `NOT-MEASURED`  the cycle never reached the goal read (a SKIPPED cycle), or the counts did
                      not come back.
    """
    if skipped:
        return ([f"- **{g}** — `STANDING=NOT-MEASURED` ({skipped})." for g, _why in GOALS],
                ["Both goals are UNMEASURED this cycle (see the SKIPPED line) — fix the read first: "
                 "an unmeasured goal is not a met one."])
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")

    def c(query: str) -> tuple[str, str]:
        n, why = _count(budget, query)
        return ("NOT-MEASURED", why) if n is None else (str(n), "")

    # Goal 1 — tortoise P0+P1 DONE and MERGED.
    p0, p0_why = c(f"repo:{GOAL_REPO} type:issue state:open label:P0")
    p1, p1_why = c(f"repo:{GOAL_REPO} type:issue state:open label:P1")
    c0, c0_why = c(f"repo:{GOAL_REPO} type:issue state:closed label:P0 closed:>={today}")
    c1, c1_why = c(f"repo:{GOAL_REPO} type:issue state:closed label:P1 closed:>={today}")
    dm, dm_why = c(f"repo:{GOAL_REPO} type:pr is:merged merged:>={today}")
    # Goal 2 — the harness runs autonomously: the SAME version everywhere, and a queue that moves.
    qo, qo_why = c(f"repo:{slug} type:pr state:open")
    qm, qm_why = c(f"repo:{slug} type:pr is:merged merged:>={today}")

    unreadable = [(name, why) for name, why in (
        ("P0 open", p0_why), ("P1 open", p1_why), ("P0 closed today", c0_why),
        ("P1 closed today", c1_why), ("PRs merged today", dm_why)) if why]
    if unreadable:
        goal1 = "NOT-MEASURED"
    elif p0 == "0" and p1 == "0":
        goal1 = "DONE"
    else:
        goal1 = "OPEN"

    # Only THIS box was probed, because the inventory is missing — the cells were never read.
    local_only = bool(drift) and all(r.get("inventory") == "absent" for r in drift)
    # ⛔ A FRACTION NEEDS A COMPARISON, REAL BOXES, AND AN ANSWER FROM EACH. No `origin/main` means
    # nothing was compared; a placeholder row means no box was probed; an unreadable box means THAT
    # box's version was never read, so a denominator counting it asserts an unmeasured fact about it
    # (and the action then orders a deploy of a box nobody looked at).
    # ⛔ `absent` IS A REAL PROBED BOX: the synthesized local row is probed like any other, and
    # excluding it made the DEFAULT fleet path (no `state/boxes.tsv`) print "not compared" beside the
    # box it had just compared, with the remediation aimed at a read that never failed.
    placeholder = [r for r in drift if r.get("inventory") in PLACEHOLDER]
    # The boxes that ANSWERED — used by the readings (a partial count) and by the action (a mixed
    # fleet is not an unmeasured one), so both say the same thing about the same rows.
    measured = [r for r in drift if r.get("readable") and r.get("inventory") not in PLACEHOLDER]
    compared = (bool(drift) and not placeholder and bool(main_sha)
                and all(r.get("readable") for r in drift))
    why_not_compared = (
        (main_why or "the harness repo's `origin/main` was unreadable") if not main_sha else
        "the box inventory could not be read" if any(r.get("inventory") == "unread" for r in drift) else
        "the inventory exists and lists NO boxes" if any(
            r.get("inventory") == "empty" for r in drift) else
        "no `state/boxes.tsv` and no `box-status.sh`" if any(
            r.get("inventory") == "noprobe" for r in drift) else
        "the probe returned nothing")
    currents = [r for r in drift if r.get("on_pin")]
    boxes_bad = [r for r in drift if not r.get("on_pin")]
    # ⛔ THE STANDING IS DECIDED BY THE DRIFT ALONE. A queue count that did not come back is its OWN
    # sub-note: folding it in here downgraded a MEASURED drift (a box provably off-pin) to
    # `NOT-MEASURED` on exactly the degraded cycles where the owner needs the drift reported.
    if not drift or placeholder:
        # ⛔ A PLACEHOLDER ROW MEANS NO BOX WAS PROBED, so the honest standing is UNMEASURED — not
        # MARKERS-BROKEN, which would name a box (`<inventory> (not verified)`) that does not exist.
        goal2 = "NOT-MEASURED"
    elif boxes_bad:
        goal2 = "MARKERS-BROKEN"
    else:
        goal2 = "MARKERS-HOLD"

    lines = [
        # ⛔ WHAT `DONE` MEASURES: the OPEN counts. The goal's second half ("and MERGED") is a
        # per-ISSUE property this block never reads — a P0 closed `not planned` counts as closed — so
        # the qualifier travels BESIDE the word (prose) instead of inside it: the word is what a
        # consumer parses, and a word with a parenthetical in it is not a word.
        f"- **{GOALS[0][0]}** — `STANDING={goal1}`"
        + (" — no open P0/P1; 'and MERGED' is the merged-today count, not a per-issue read"
           if goal1 == "DONE" else ""),
        f"  {GOAL_REPO}: open P0={p0} · open P1={p1} · closed today P0={c0} · P1={c1} · "
        f"PRs merged today={dm}",
        f"- **{GOALS[1][0]}** — `STANDING={goal2}`",
        # ⛔ THE READINGS MUST AGREE WITH THE ACTION. In a mixed fleet `compared` is False, so this
        # said "not compared — the probe returned nothing" two lines above an action stating the
        # measured fraction — the two-readers defect (#1872/#1714) inside one block, with the same
        # reason then printed twice. The mixed case states the PARTIAL count instead.
        "  harness: " + _drift_text(drift) +
        ("" if not drift else
         # ⛔ THE LABEL NAMES THE PREDICATE IT COUNTS. `on_pin` requires main AND activation, so
         # "on this cycle's main" let a row say `[current]` beside a fraction that excluded it — the
         # two-readers defect inside one line.
         f" ({len(currents)}/{len(drift)} box(es) on this cycle's main, deployed AND activated)"
         if compared else
         f" ({len(drift) - len(measured)} of {len(drift)} box(es) gave no answer)"
         if (main_sha and measured) else
         f" (not compared — {why_not_compared})"),
        f"  queue ({slug}): open PRs={qo} · merged today={qm}",
    ]
    if not main_sha:
        lines.append("  ⚠️ harness: " + (main_why or "the harness repo's `origin/main` could not be "
                     "read") + ", so 'the same version everywhere' cannot be asserted at all")
    if local_only:
        lines.append("  ⚠️ harness: no `state/boxes.tsv` — only THIS box was probed; the cells were "
                     "never read, so this is not 'the fleet is on the pin'")
        # ⛔ ONE PLACE, EVERY BRANCH. Appended per-action it was present in two branches of three and
        # the third (not-compared — the state a freshly installed box is in) never said the cells were
        # never consulted; and the HOLD copy was unpinned, so deleting it left the suite green while a
        # one-box read was stated as the fleet marker.
        lines.append("  ⛔ harness: LOCAL ONLY — the inventory is absent, so nothing is known about "
                     "the cells")
    for r in drift:
        if r.get("inventory") in PLACEHOLDER:
            # ⛔ SAY IT ONCE. The readings line above already carries the reason (`not compared — …`);
            # repeating the same sentence two lines apart was the round-7 complaint in the other
            # direction, and making the noprobe note a bare FACT put the identical string in both.
            lines.append(f"  ⚠️ harness: {r.get('note') or 'the box inventory could not be read'}"
                         if r.get("inventory") == "unread" else
                         "  ⚠️ harness: no box was probed this cycle")
    for name, why in unreadable:
        lines.append(f"  ⚠️ {name}: {why}")
    if qo_why or qm_why:
        # ONE line, not one per failed count: two identical `⚠️ queue:` lines said the same thing
        # twice and read like two separate failures.
        # ⛔ DEDUPED: both counts read the same answer, so both reasons are the SAME string (“the 8-call
        # goal bound is spent this cycle”) — the line said it twice, which is what the ONE-line rule
        # above was introduced to stop.
        lines.append("  ⚠️ queue: " + "; ".join(dict.fromkeys(w for w in (qo_why, qm_why) if w)))
    if not (qo_why or qm_why) and qo.isdigit() and qm.isdigit() and int(qm) < int(qo):
        # NOT a standing flip: how many of those open PRs are stale or drafts is not read here, so
        # calling this "the queue is behind" as a verdict would be inventing a threshold. It is
        # reported as the SHAPE, which is what "the queue not behind" is asking about.
        lines.append(f"  ⚠️ queue shape: more open than landed today ({qo} open vs {qm} merged) — "
                     f"the queue is not shrinking at this rate.")

    actions: list[str] = []
    if goal1 == "OPEN":
        actions.append(
            f"**Goal 1 ({GOAL_REPO} P0+P1):** {p0} P0 + {p1} P1 issues are still OPEN, "
            f"{c0}+{c1} were closed today and {dm} PR(s) merged today. A fix without a MERGED PR is "
            f"not done — land those PRs before starting new work on the goal.")
    elif goal1 == "DONE":
        actions.append(f"**Goal 1 ({GOAL_REPO} P0+P1):** DONE — no open P0/P1, and {dm} PR(s) merged "
                       f"today. That is the OPEN side measured; 'every fix is MERGED' is not read "
                       f"per-issue here (a P0 closed `not planned` counts as closed). Hold it: a new "
                       f"P0/P1 issue re-opens the goal.")
    else:
        actions.append(f"**Goal 1 ({GOAL_REPO} P0+P1):** UNMEASURED this cycle — the counts did not "
                       f"come back (see the ⚠️ lines). Repair the read; do not assume the goal holds.")

    if goal2 == "MARKERS-BROKEN":
        drift_names = ", ".join(f"{r['box']} ({'; '.join(r.get('reasons') or ['not verified'])})"
                                for r in boxes_bad) or "<unread>"
        # ⛔ NO COMPARISON WAS MADE WITHOUT `origin/main`, SO NO COUNT MAY BE STATED. "0/N boxes run
        # this cycle's main" is a measured claim; with the ref unreadable it is an invented one, and it
        # is printed in the paragraph the owner acts on.
        # ⛔ A MIXED FLEET IS NOT AN UNMEASURED ONE. `compared` requires EVERY box to answer, so one
        # unanswered box used to void the measured verdicts in the paragraph the owner acts on
        # ("Nothing here is a verdict on a box" over a box that had just been measured off-pin) and to
        # defer a real repair behind "repair that read first".
        measured_bad = [r for r in measured if not r.get("on_pin")]
        mixed = (not compared) and bool(main_sha) and bool(measured)
        bad_names = ", ".join(f"{r['box']} ({'; '.join(r.get('reasons') or ['not verified'])})"
                              for r in measured_bad) or "<none>"
        # ⛔ "NOT all: <none>" IS A VERDICT WITH NO DATUM, contradicted by its own complete fraction —
        # and one unreachable cell with the rest on the pin is the COMMON degradation, so that clause is
        # the one the owner reads most often.
        # ⛔ "every PROBED box is on the pin" RESTATED the fraction one clause earlier (N/N), and put a
        # period before an em-dash clause. When every probed box is on the pin there is nothing to add.
        bad_clause = f" — NOT all: {bad_names}" if measured_bad else ""
        head = (f"**Goal 2 (harness autonomy):** {len(currents)}/{len(measured)} PROBED box(es) run "
                f"this cycle's main, deployed and activated{bad_clause}. "
                # \u26d4 THE COUNT IS IN THE SENTENCE, SO THE REASON IS THE FACT AND NOT A SECOND COUNT.
                # "1 box(es) did not answer (1 box(es) did not answer)" was the duplication this
                # sentence shipped with for one round.
                f"{len(drift) - len(measured)} box(es) gave no answer ({why_not_compared}), so nothing "
                f"is stated about them. "
                if mixed else
                f"**Goal 2 (harness autonomy):** the boxes could not be compared — {why_not_compared} "
                f"— so repair that read first. Nothing here is a verdict on a box, and these rows may "
                f"ALSO be stopped or unreadable for their own reasons: {drift_names}. "
                if not compared else
                f"**Goal 2 (harness autonomy):** {len(currents)}/{len(drift)} boxes run this cycle's "
                f"main, deployed AND activated — NOT all: {drift_names}. The SAME harness version on "
                f"every box is the marker; deploy/activate it (the deploy arm below) before anything "
                f"else, one box at a time. ")
        actions.append(head)
    elif goal2 == "MARKERS-HOLD":
        # ⛔ "queue read (…)" IS A MEASUREMENT CLAIM. The standing is decided by the DRIFT alone now
        # (round-2 #9), so MARKERS-HOLD is reachable with the queue unread — and the sentence went on
        # saying "queue read (NOT-MEASURED open, …)" two lines under the ⚠️ that says it was not.
        queue_note = (f"queue read ({qo} open, {qm} merged today)"
                      if not (qo_why or qm_why) else
                      "queue NOT read this cycle (see the ⚠️ line)")
        actions.append(
            f"**Goal 2 (harness autonomy):** markers HOLD — all {len(drift)} box(es) run this cycle's "
            f"main, deployed AND activated; {queue_note}. That is the marker, not proof: keep the "
            f"queue moving and keep every cell on the pin.")
    else:
        # ⛔ NO REASON HERE: the readings line and its ⚠️ already state it, and repeating the sentence
        # in the action is the duplication that has now been removed from three places.
        actions.append("**Goal 2 (harness autonomy):** UNMEASURED this cycle — no box was probed "
                       "(see the ⚠️ line), so nothing about the fleet's version is asserted. Repair "
                       "that read instead of assuming the fleet is fine.")
    actions.append("**Then, and only then, the PR table below:** it is the VEHICLE for the goals, not "
                   "the objective. A PR that moves neither goal is work, not progress.")
    return lines, actions


# ── the written reminder ─────────────────────────────────────────────────────────────────────
def compose(md: Path, slug: str, main_sha: str, budget: Budget,
            landing: list[dict], deploy: list[dict], skipped: str, line: str,
            goal_lines: list[str] | None = None,
            goal_actions: list[str] | None = None,
            harness_main: str = "") -> str:
    """Write the reminder file. -> "" on success, the failure reason otherwise (the caller turns it
    into a SKIPPED cycle: the file IS the deliverable)."""
    rows = []
    for r in landing:
        rows.append(f"| {r['rank']} | #{r['pr']['number']} | {r['verdict']} | "
                    f"{r['readings']} | {r['pr']['title'][:70]} |")
    dep = []
    for d in deploy:
        dep.append(f"| {d['box']} | {d['harness'][:12] or '<none>'} [{d['relation'] or '?'}] | "
                   f"{d['controller'] or '?'} | {d['roles'] or '?'} | {d['verdict']} |")
    goals_block = chr(10).join(goal_lines or []) or (
        "- **GOALS UNMEASURED** — this cycle did not reach the goal read (see the SKIPPED line).")
    do_block = chr(10).join(f"{i}. {a}" for i, a in enumerate(goal_actions or [], start=1)) or (
        "1. Both goals are UNMEASURED this cycle — repair the read before acting on the table below.")
    body = f"""# Merge reminder — {now_iso()}

**Target:** `{slug}` · **origin/main:** `{main_sha[:12] or 'UNREADABLE'}` ·
**harness main:** `{(harness_main or 'UNRESOLVED')[:12]}`{'' if (not harness_main or harness_main == main_sha) else f' (the harness repo\'s `origin/main` — what goal 2 compares a box against, NOT `{slug}`\'s)'} ·
**REST:** {budget.calls}/{REST_BUDGET} metered (+1 exempt `rate_limit`) ·
**search:** {budget.search_calls}/{GOAL_SEARCH_BUDGET} (the goal readings; a SEPARATE quota) ·
**core:** {(str(budget.core_remaining) + '/' + str(budget.core_limit)) if budget.core_limit else 'UNREADABLE (rate_limit was not reached)'}

{f'⛔ **SKIPPED:** {skipped}' if skipped else '**cycle:** ran'}

## GOALS

{chr(10).join(f'- **{g}** — {why}' for g, why in GOALS)}

## Where the goals stand this run

{goals_block}

## What to do (in GOAL order)

{do_block}

## One line

```
{line}
```

## 1. Closest to landing

| # | PR | verdict | measured reading | title |
|---|---|---|---|---|
{chr(10).join(rows) if rows else ('| — | — | NOT-READ (the cycle was skipped before the listing) | — | — |' if skipped else '| — | — | no open PRs | — | — |')}

Readings are the values this cycle MEASURED. `in-flight` > 0 with `reds=0` is a **WAIT**, never a
GO (#2522/#2592); `attested@head=stale` means a record exists but was minted for an older head
(a stale record is not a record). `NOT-READ` is outside the read budget, not quiet.

## 2. Merged but NOT live (the deploy arm)

| box | harness | controller | roles | verdict |
|---|---|---|---|---|
{chr(10).join(dep) if dep else ('| — | — | — | — | NOT-RUN (the cycle was skipped before the deploy arm) |' if skipped else '| — | — | — | — | no box was probed (see the goal-2 readings above for why) |')}

A merged fix that is not live on a box has fixed nothing. The arm dispatches each box's OWN
activation verb, never a hand restart, and only after the landing decision — and VERIFIES it by
artifact (`harness: <sha> [current]`, `controller: RUNNING`), never by the command's exit code.

## 3. One red for many PRs

{_shared_reds(landing, skipped)}

---
*This file is written by `scripts/orchestrator-harness/merge-reminder.py`. It never merges: a landed
PR is landed by `scripts/admin-merge.sh`, whose refusals are the record.*
"""
    try:
        tmp = md.with_suffix(f".tmp.{os.getpid()}")
        tmp.write_text(body)
        os.replace(tmp, md)
        return ""
    except OSError as e:
        return f"{type(e).__name__}: {e}"


def _shared_reds(landing: list[dict], skipped: str = "") -> str:
    """Question 3: is one RED GROUP shared across several PRs (one root that unblocks a batch)?
    Built from the group LABELS this cycle measured — a count alone cannot say "same reason"."""
    by_label: dict[str, list[int]] = {}
    for r in landing:
        for label in r.get("red_labels") or []:
            by_label.setdefault(label, []).append(r["pr"]["number"])
    shared = {k: v for k, v in by_label.items() if len(v) > 1}
    if shared:
        return "\n".join(f"- `{k}` → {', '.join(f'#{n}' for n in sorted(v))}" for k, v in shared.items())
    if any(r.get("reds") for r in landing):
        return ("A red group appears on ONE PR only (not a batch root): " +
                "; ".join(f"#{r['pr']['number']}: {', '.join(r.get('red_labels') or [])}"
                          for r in landing if r.get("reds")))
    if not landing:
        if skipped:
            return "NOT-READ — no PR surface was examined this cycle (see the SKIPPED line above)."
        return "No open PRs this cycle, so no red group can be shared."
    unread = [r for r in landing
              if "reds=UNREADABLE" in (r.get("readings") or "")
              or "reds=NOT-READ" in (r.get("readings") or "")]
    if unread and not any(r.get("red_labels") for r in landing):
        return (f"NOT-READ for {len(unread)} of {len(landing)} candidate(s) — their surfaces could "
                f"not be read, so no red group is reported as absent.")
    return ("No PR in this cycle carries a red group. (A PR whose surface was NOT READ is not "
            "evidence of a green one.)")


# ── timer install (both platforms) ───────────────────────────────────────────────────────────
def install_timer(o: Path, interval: int, uninstall: bool) -> int:
    argv = [sys.executable, str(Path(__file__).resolve()), "--o", str(o)]
    try:
        (o / "logs").mkdir(parents=True, exist_ok=True)   # the plist/unit point their output here
    except OSError as e:
        print(f"⛔ cannot create {o}/logs: {e}", file=sys.stderr)
        return 3
    plat = sys.platform
    if plat == "darwin":
        label = "com.tortoise.merge-reminder"
        plist = Path.home() / "Library" / "LaunchAgents" / f"{label}.plist"
        if uninstall:
            removed = ""
            if plist.exists():
                rc, _, err = run(["launchctl", "bootout", f"gui/{os.getuid()}/{label}"], timeout=60)
                plist.unlink()
                # VERIFY THE STOP THE WAY THE START IS VERIFIED: a `bootout` the service refused
                # leaves a loaded job pointing at a deleted plist, firing an arm nobody can see.
                rc2, _, _ = run(["launchctl", "print", f"gui/{os.getuid()}/{label}"], timeout=30)
                if rc2 == 0:
                    print(f"⛔ {label} is STILL LOADED after bootout (rc={rc}). "
                          f"Next: launchctl bootout gui/{os.getuid()}/{label}", file=sys.stderr)
                    return 3
                removed = str(plist)
            if removed:
                print(f"removed {removed}")
            else:
                print(f"nothing to remove at {plist}")
            return 0
        if not shutil.which("launchctl"):
            print("⛔ no launchctl on this macOS box — cannot install a timer, and will not pretend to", file=sys.stderr)
            return 3
        plist.parent.mkdir(parents=True, exist_ok=True)
        args_xml = "".join(f"<string>{a}</string>" for a in argv)
        xml = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>{label}</string>
  <key>ProgramArguments</key><array>{args_xml}</array>
  <key>StartInterval</key><integer>{interval}</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>{o}/logs/merge-reminder.out</string>
  <key>StandardErrorPath</key><string>{o}/logs/merge-reminder.err</string>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>{os.environ.get('PATH', '/usr/local/bin:/usr/bin:/bin')}</string>
    <key>HOME</key><string>{Path.home()}</string>
    <key>O</key><string>{o}</string>
  </dict>
</dict></plist>
"""
        tmp = plist.with_suffix(f".new.{os.getpid()}")
        tmp.write_text(xml)
        # Validate BEFORE replacing a live plist: a rejected render must not destroy a working job.
        rc, _, err = run(["plutil", "-lint", str(tmp)], timeout=30)
        if rc != 0:
            tmp.unlink(missing_ok=True)
            print(f"⛔ rendered plist does not parse ({one_line(err)}) — the installed job was left alone", file=sys.stderr)
            return 3
        os.replace(tmp, plist)
        run(["launchctl", "bootout", f"gui/{os.getuid()}/{label}"], timeout=60)
        rc, _, err = run(["launchctl", "bootstrap", f"gui/{os.getuid()}", str(plist)], timeout=60)
        rc2, out2, _ = run(["launchctl", "print", f"gui/{os.getuid()}/{label}"], timeout=30)
        if rc != 0 or rc2 != 0:
            print(f"⛔ wrote {plist} but the job is NOT loaded (bootstrap rc={rc}: {one_line(err)}). "
                  f"Next: launchctl bootstrap gui/{os.getuid()} {plist}", file=sys.stderr)
            return 3
        print(f"installed + loaded {label} every {interval}s ({plist})")
        return 0

    # Linux: a systemd USER timer, else crontab. A box with neither REFUSES by name.
    unit = "merge-reminder"
    udir = Path.home() / ".config" / "systemd" / "user"
    service = udir / f"{unit}.service"
    timer = udir / f"{unit}.timer"
    if uninstall:
        # ⛔ REMOVE EVERY ARM THIS FILE CAN INSTALL. Uninstall has to be able to reach the state
        # install can create, or a box with no systemd keeps firing a crontab entry after a
        # successful-looking `--uninstall-timer` — an arm that dispatches rails and restarts boxes.
        removed: list[str] = []
        if timer.exists() or service.exists():
            rc, _, err = run(["systemctl", "--user", "disable", "--now", f"{unit}.timer"], timeout=60)
            for f in (timer, service):
                f.unlink(missing_ok=True)
            rc2, out2, _ = run(["systemctl", "--user", "is-active", f"{unit}.timer"], timeout=30)
            if rc2 == 0 and "active" in (out2 or ""):
                print(f"⛔ {unit}.timer is STILL ACTIVE after disable (rc={rc}: {one_line(err)}). "
                      f"Next: systemctl --user disable --now {unit}.timer", file=sys.stderr)
                return 3
            removed.append(f"{unit}.timer/.service")
        if shutil.which("crontab"):
            tag = CRON_TAG
            read_ok, current_lines, why = _crontab_read()
            if not read_ok:
                print(f"⛔ {why}", file=sys.stderr)
                return 3
            out = "\n".join(current_lines)
            if any(_is_our_cron_line(ln, tag, o) for ln in (out or "").splitlines()):
                kept = [ln for ln in (out or "").splitlines() if not _is_our_cron_line(ln, tag, o)]
                try:
                    subprocess.run(["crontab", "-"], input="\n".join(kept) + "\n", text=True,
                                   capture_output=True, timeout=30, check=True)
                except (OSError, subprocess.SubprocessError) as e:
                    print(f"⛔ could not rewrite the crontab: {e}", file=sys.stderr)
                    return 3
                rc2, out2, _ = run(["crontab", "-l"], timeout=30)
                if any(_is_our_cron_line(ln, tag, o) for ln in (out2 or "").splitlines()):
                    print(f"⛔ the crontab entry is STILL there ({tag}). Next: crontab -e",
                          file=sys.stderr)
                    return 3
                removed.append(f"crontab entry {tag}")
        if removed:
            print("removed " + " and ".join(removed))
        else:
            print(f"nothing to remove at {timer} (and no crontab entry)")
        return 0
    if shutil.which("systemctl"):
        udir.mkdir(parents=True, exist_ok=True)
        service.write_text(
            "[Unit]\nDescription=merge reminder (harness)\n\n[Service]\nType=oneshot\n"
            # ⛔ `%` IS A SPECIFIER IN A UNIT FILE (`%p`, `%h`, …), so an operator path carrying
            # one ran the timer against a DIFFERENT $O while `is-active` still said active — the
            # silent no-op arm this loop keeps removing. Doubling is systemd's escape for a literal.
            f"WorkingDirectory={_systemd_escape(str(o))}\n"
            f"Environment=O={_systemd_escape(str(o))}\n"
            f"Environment=HOME={_systemd_escape(str(Path.home()))}\n"
            f"Environment=PATH={_systemd_escape(os.environ.get('PATH', '/usr/local/bin:/usr/bin:/bin'))}\n"
            # ⛔ `argv[0]` IS the interpreter, so prefixing `/usr/bin/env python3` made the unit run
            # the interpreter AS the script (an immediate SyntaxError) while the timer reported
            # itself active — the reminder then never ran at all, silently (#2603 review).
            f"ExecStart={' '.join(_systemd_escape(shell_quote(a)) for a in argv)}\n")
        timer.write_text(
            "[Unit]\nDescription=merge reminder timer\n\n[Timer]\n"
            f"OnBootSec=60s\nOnUnitActiveSec={interval}s\nAccuracySec=10s\n\n"
            "[Install]\nWantedBy=timers.target\n")
        run(["systemctl", "--user", "daemon-reload"], timeout=60)
        rc, _, err = run(["systemctl", "--user", "enable", "--now", f"{unit}.timer"], timeout=90)
        rc2, out2, _ = run(["systemctl", "--user", "is-active", f"{unit}.timer"], timeout=30)
        if rc != 0 or rc2 != 0 or "active" not in (out2 or ""):
            print(f"⛔ wrote {timer} but the timer is NOT active (enable rc={rc}: {one_line(err)}). "
                  f"Next: systemctl --user enable --now {unit}.timer", file=sys.stderr)
            return 3
        print(f"installed + started {unit}.timer every {interval}s ({timer})")
        return 0
    if shutil.which("crontab"):
        tag = CRON_TAG
        mins = max(1, interval // 60)
        # Quote EVERY interpolated path: `$O` and the checkout path are operator-supplied, and cron
        # runs the line through /bin/sh — an unquoted space turns the schedule into a command that
        # cannot run, which then reads exactly like a reminder with nothing to say.
        entry = _cron_line(o, mins)
        read_ok, current_lines, why = _crontab_read()
        if not read_ok:
            print(f"⛔ {why}", file=sys.stderr)
            return 3
        kept = [ln for ln in current_lines if not _is_our_cron_line(ln, tag, o)]
        kept.append(entry)
        # Feed the crontab through stdin (the `run()` helper cannot); the rc is still checked.
        try:
            p = subprocess.run(["crontab", "-"], input="\n".join(kept) + "\n", text=True,
                               capture_output=True, timeout=30)
            if p.returncode != 0:
                raise OSError(p.stderr.strip() or f"crontab rc={p.returncode}")
        except (OSError, subprocess.TimeoutExpired) as e:
            print(f"⛔ could not write the crontab: {e}", file=sys.stderr)
            return 3
        # VERIFY THE ARTIFACT, not the write: `crontab -` exiting 0 is the same class of evidence as
        # `cmux send` exiting 0 — it says bytes were handed over, not that a timer exists.
        rc2, out2, _ = run(["crontab", "-l"], timeout=30)
        if rc2 != 0 or not any(_is_our_cron_line(ln, tag, o) for ln in (out2 or "").splitlines()):
            print(f"⛔ wrote the crontab but the entry is NOT there (rc={rc2}). "
                  f"Next: crontab -l | grep '{tag}'", file=sys.stderr)
            return 3
        print(f"installed a crontab entry every {mins}m ({tag})")
        return 0
    print("⛔ no scheduler on this box (no systemctl, no crontab) — the reminder is installed as a "
          "script but NOTHING will run it. Next: install systemd or cron, or run it from the "
          "harness's own controller cycle.", file=sys.stderr)
    return 3


# ── main ─────────────────────────────────────────────────────────────────────────────────────
def repo_slug(repo_path: Path, explicit: str) -> str:
    if explicit:
        return explicit
    rc, out, _ = run(["git", "-C", str(repo_path), "remote", "get-url", "origin"], timeout=15)
    m = re.search(r"[:/]([^/:]+/[^/]+?)(?:\.git)?$", (out or "").strip())
    if rc == 0 and m:
        return m.group(1)
    raise Skipped("UNREADABLE repo — pass --repo owner/name (origin could not be read)")


def github_origin(repo_path: Path) -> str:
    """The CHECKOUT's own `owner/name` when `origin` is a github URL, else "".

    ⛔ `--repo` NAMES THE TARGET; THE CHECKOUT NAMES WHERE THE EVIDENCE LIVES. They are different
    questions, and nothing else couples them: `claim_state` runs `git ls-remote <repo_path>'s origin`
    while `slug` comes from the flag, so `--repo daniel-ospina/tortoise` run from an agent-infra
    checkout would read AGENT-INFRA's `refs/claims/*` and answer `claim=none` for a PR a peer box is
    landing right now — a GO derived from a namespace it never read (and `main_sha` would compare
    the boxes against the wrong `origin/main`).

    "" means "cannot prove a mismatch" — a local path, a bare fixture origin, a mirror on another
    host — and is not evidence of a match. Only a RESOLVED github slug that DIFFERS refuses.
    """
    rc, out, _ = run(["git", "-C", str(repo_path), "remote", "get-url", "origin"], timeout=15)
    if rc != 0:
        return ""
    m = re.search(r"github\.com[:/]([^/\s]+)/([^/\s]+?)(?:\.git)?/?$", (out or "").strip())
    return f"{m.group(1)}/{m.group(2)}" if m else ""


def repo_path_of(o: Path) -> Path:
    explicit = os.environ.get("REPO")
    cands = [explicit] if explicit else []
    # ⛔ THE SAME SHALLOW-COPY CRASH AS `script_checkout` (PR #2683 round-1 review). `parents[2]` raises
    # IndexError on a copy with fewer than three parents, and this line runs INSIDE the cycle's try — so
    # the traceback escaped as "no report written at all", the one failure mode the OSError handlers
    # exist to prevent. It was found by the verifier AFTER the guard was added to `harness_repo_of`,
    # because a mutation run had restored a pre-guard copy: the fix is only real once both call sites
    # use it, and only a read of the file (not a memory of the patch) shows that.
    cands += [str(script_checkout() or ""), str(Path.home() / "orchestrator")]
    for c in cands:
        if c and run(["git", "-C", c, "rev-parse", "--git-dir"], timeout=15)[0] == 0:
            return Path(c).resolve()
    return Path.cwd()


def git_dir(path: Path) -> str:
    """The ABSOLUTE git dir of `path` — the identity two checkouts are compared by.

    ⛔ NOT the toplevel and NOT the path: a linked worktree has its own gitdir but shares the repo, so
    `/tmp/cell-ai` and `/tmp/cell-home/harness` are the SAME repo while their toplevels differ. That is
    the comparison this file needs (two paths, one `origin/main`), and comparing paths instead made the
    reminder read a second, independent main for a checkout that was the same repo — a divergence
    source of exactly the kind the one-read rule exists to remove.
    """
    rc, out, _ = run(["git", "-C", str(path), "rev-parse", "--absolute-git-dir"], timeout=15)
    return (out or "").strip() if rc == 0 else ""


def script_checkout() -> Path | None:
    """`Path(__file__).parents[2]`, BOUNDED — the harness checkout this script lives in.

    ⛔ `parents[2]` RAISES IndexError ON A SHALLOW COPY. A deployed flat copy at `/tmp/mr.py` has two
    parents, and indexing the third escaped as a traceback with no report written at all — the same
    "no deliverable" failure the OSError handlers exist to prevent, from an expression that reads as a
    constant. A script outside any checkout has no checkout, which is a state to answer (None), not to
    crash on.
    """
    ps = Path(__file__).resolve().parents
    return ps[2] if len(ps) > 2 else None


MANIFEST_MARKER = "scripts/orchestrator-harness/box-status.sh"


def harness_repo_of(o: Path) -> Path | None:
    """The checkout the DEPLOYED harness belongs to — the repo goal 2's "same version" means.

    ⛔ TWO MAINS, AND THEY ARE NOT INTERCHANGEABLE (#2679). `repo_path_of` answers "which repo does this
    cycle SWEEP" — its `origin/main` is the right comparison for the PR and claim gates, because those
    refs live in the swept repo. The harness, however, is an agent-infra artifact: a box's harness sha
    can ONLY be compared with agent-infra's main. Measured on the hub 2026-10-24 with the sweep repo set
    to a tortoise checkout (`REPO=/tmp/cell-t3`, the fleet's default shape for two of its cells): the
    goal read `local=f9381dae2ee5 [unknown] — a different commit from this cycle's main (0/1 ...)` and
    ordered a deploy against `main=5f40d832c254`, which is a TORTOISE commit — an instruction to deploy
    the harness at a sha that does not exist in agent-infra. Pointed at the harness repo the same box
    reads `[current]`.

    Resolution: `HARNESS_REPO` first (the variable the fleet's supervisor already exports), then the
    checkout containing `$O`, then the checkout containing THIS script, then the conventional
    `$HOME/orchestrator` — and each candidate must CARRY THE HARNESS, meaning
    `scripts/orchestrator-harness/box-status.sh` is TRACKED by that candidate's own repo (see the
    round-3 note on the tracked check below), so a candidate that is merely some checkout is skipped.
    """
    # ⛔ FOUR CANDIDATES, BECAUSE THE TIMER EXPORTS NONE OF THE FIRST TWO. Measured (round-1 review of
    # PR #2683): the timer this file installs exports only `O`/`HOME`/`PATH` (see the timer installer),
    # and `--o` defaults to `$HOME/orchestrator` — which on the hub is NOT a checkout. So a resolution
    # that consulted `HARNESS_REPO` and `$O` alone returned None in the DEFAULT and TIMER
    # configurations, the caller fell back to the swept repo's main, and the report printed
    # `**harness main:** 5f40d832c254` — a tortoise sha labelled as the harness main — over the very
    # #2679 reading this change exists to remove. The third candidate fixes that: this script lives
    # inside the harness payload (`$O/scripts/orchestrator-harness/merge-reminder.py`, and the same
    # relative position in a repo checkout), so `parents[2]` IS the harness checkout. The fourth is the
    # conventional location, kept only because it is the documented `--o` default.
    #
    # ⛔ AND A CANDIDATE MUST PROVE IT **IS** THE HARNESS REPO, NOT MERELY THAT IT IS A CHECKOUT (#2683
    # round 2). `git rev-parse --show-toplevel` succeeding says "a repo", and two of the four candidates
    # are paths an operator or a deploy script chose: `$O` (a flat payload can land anywhere) and
    # `$HOME/orchestrator` (measured on this fleet as a TORTOISE checkout, `origin/main=5f40d832c254`).
    # Accepting either on a checkout test alone brought #2679 back in full — and SILENTLY, because when
    # that wrong repo happens to be the SWEPT repo the caller sees "same repo" and reuses the swept
    # main, which is precisely the foreign-sha comparison the goal must never make. So a candidate
    # qualifies only if it CARRIES THE HARNESS. That is an offline, local fact about the tree — never a
    # remote URL, which forks legitimately change.
    #
    # ⛔ THE MARKER MUST BE **TRACKED**, NOT MERELY PRESENT (round-3 review of PR #2683, BLOCKING). A
    # PATH-existence test re-admitted the tortoise repo for the shape this fleet actually runs: the
    # canonical tortoise/eldato checkout carries a GITIGNORED `scripts -> $AGENT_INFRA_PATH/scripts`
    # pointer (this repo's AGENTS.md, #9475), so `scripts/orchestrator-harness/box-status.sh` EXISTS in
    # every such checkout through it. Measured on `/tmp/cell-wt-greenmain` (origin = tortoise.git):
    # `is_file()` true, and the resolution returned that repo with a TORTOISE `origin/main`
    # (`49dca29bb124…`) — #2679 in full, for the shape two of the fleet's cells run. The candidate's OWN
    # repo is asked, and the question is about the INDEX ENTRY: `git ls-files -s` gives `<mode> <object>
    # <stage>\t<path>`, and only a regular blob recorded at the exact path is the harness file. A
    # path-existence test follows the pointer; `--error-unmatch` alone is a PATHSPEC match, satisfied by a
    # mode-120000 symlink and by a tracked file BESIDE a directory of that name (both measured accepted).
    # ⛔ AND THE PROBE MUST NOT INHERIT A GIT ENVIRONMENT (round-6 review, measured: with
    # `GIT_DIR=<harness>/.git` in the environment, `git -C <a non-harness checkout> ls-files` answered from
    # the HARNESS's index, so the non-harness repo was accepted and its main measured as the harness main).
    # A probe describes the directory it is pointed at; the variables are dropped for these reads only.
    genv = git_env()
    here = script_checkout()
    cands = [os.environ.get("HARNESS_REPO") or "", str(o), str(here or ""),
             str(Path.home() / "orchestrator")]
    for c in cands:
        if not c:
            continue
        rc, out, _ = run(["git", "-C", c, "rev-parse", "--show-toplevel"], timeout=15, env=genv)
        top = (out or "").strip()
        if rc != 0 or not top:
            continue
        # A TRACKED SYMLINK IS NOT THE HARNESS: `ls-files --error-unmatch` is satisfied by a mode-120000
        # entry too, so a repo that ships no harness bytes would be taken for the harness repo and its own
        # main measured against (round-4 review follow-up, measured). And the PATH must match exactly
        # (round-5 follow-up): a pathspec also matches a tracked file BESIDE a directory of that name.
        rc2, entry, _ = run(["git", "-C", top, "ls-files", "-s", "--error-unmatch", "--",
                             MANIFEST_MARKER], timeout=15, env=genv)
        line = (entry or "").strip().splitlines()[0] if (entry or "").strip() else ""
        head, _, ipath = line.partition("\t")          # `<mode> <object> <stage>\t<path>`
        mode = head.split(" ", 1)[0] if head else ""
        if rc2 == 0 and mode in ("100644", "100755") and ipath.strip() == MANIFEST_MARKER:
            return Path(top)
    return None


# ⛔ NO INHERITED GIT ENVIRONMENT, FOR ANY READ (round-7 review note, then measured). `GIT_DIR`,
# `GIT_WORK_TREE`, `GIT_INDEX_FILE`, `GIT_OBJECT_DIRECTORY`, `GIT_ALTERNATE_OBJECT_DIRECTORIES` and
# `GIT_COMMON_DIR` (measured in round 8: with THAT one set, `repo_slug()`/`github_origin()` answered a
# FOREIGN slug for an agent-infra-origin repo, so the mismatch guard failed open again) all
# redirect `git -C <path>` at ANOTHER repository, so a cycle launched from a shell that exports one would
# read a foreign main/index/repo and print it as this repo's — the #2679/#2680 false-reading class,
# reached through the environment rather than through a path. Every git invocation this file makes goes
# through this env; a probe describes the directory it was POINTED AT, never the caller's.
GIT_ENV_DROP = ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY",
                "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_COMMON_DIR")


def git_env() -> dict:
    """The environment for a git read: ours, minus every variable that relocates the repository."""
    return {k: v for k, v in os.environ.items() if k not in GIT_ENV_DROP}


def main_sha(repo_path: Path) -> str:
    """`origin/main` read WITHOUT a fetch: the question is "what has merged", and the timer must not
    spend a network round trip on it. An unreadable ref is returned as "" and REPORTED — never
    treated as "up to date" (that is the false-green this whole file exists against)."""
    rc, out, _ = run(["git", "-C", str(repo_path), "rev-parse", "--verify", "origin/main"], timeout=15,
                     env=git_env())
    if rc != 0:
        return ""
    return (out or "").strip()


def origin_main(repo_path: Path) -> str:
    """This cycle's `origin/main`, retried with a REAL backoff (see `MAIN_READ_ATTEMPTS`).

    Returns "" only after every attempt failed — and then EVERY consumer (drift, goals, deploy table,
    header, `--json`) sees the same "", which is what makes one report internally consistent.
    """
    for attempt in range(MAIN_READ_ATTEMPTS):
        sha = main_sha(repo_path)
        if sha:
            return sha
        if attempt + 1 < MAIN_READ_ATTEMPTS:
            time.sleep(MAIN_READ_BACKOFF_S)
    return ""


def parse_args(argv):
    p = argparse.ArgumentParser(add_help=True, description="merge reminder + evidence-gated actuator")
    p.add_argument("--repo", default=os.environ.get("OR", ""), help="owner/name (default: git origin)")
    p.add_argument("--o", default=os.environ.get("O", str(Path.home() / "orchestrator")))
    p.add_argument("--reviews", default=os.environ.get("MERGE_REMINDER_REVIEWS",
                                                       str(Path.home() / ".pi/agent/reviews")))
    # ⛔ THE ARM IS ON BY DEFAULT — that is the whole point of this change (the owner asked for
    # automated dispatch of the needed action). `--no-act` (or MERGE_REMINDER_ACT=0) is the
    # reminder-only mode, and it is the mode a human uses to INSPECT before trusting it. What keeps
    # the default safe is not the flag: it is the gate list, which emits no GO from an unread value.
    p.add_argument("--act", dest="act", action="store_true",
                   default=os.environ.get("MERGE_REMINDER_ACT", "1").strip().lower()
                   not in ("0", "no", "false", "off"),
                   help="dispatch the rail when every gate passes (default: ON; --no-act disables BOTH arms)")
    p.add_argument("--no-act", dest="act", action="store_false")
    p.add_argument("--dry-run", action="store_true", help="measure and report; dispatch nothing")
    p.add_argument("--json", action="store_true", help="machine-readable output on stdout")
    p.add_argument("--quiet", action="store_true", help="write the file, print nothing")
    p.add_argument("--max-prs", type=int, default=DEFAULT_MAX_PRS)
    p.add_argument("--candidates", type=int, default=DEFAULT_CANDIDATES)
    p.add_argument("--retry-s", type=int, default=RETRY_S)
    p.add_argument("--rail-wait-s", type=int, default=RAIL_WAIT_S)
    p.add_argument("--verify-deploy-s", type=int, default=DEPLOY_VERIFY_S)
    p.add_argument("--rail", default=os.environ.get("MERGE_REMINDER_RAIL", ""))
    p.add_argument("--interval", type=int, default=600)
    p.add_argument("--install-timer", action="store_true")
    p.add_argument("--uninstall-timer", action="store_true")
    return p.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv or sys.argv[1:])
    o = Path(args.o).expanduser()
    try:
        o.mkdir(parents=True, exist_ok=True)
    except OSError as e:
        print(f"⛔ cannot create $O={o}: {e}", file=sys.stderr)
        return 1

    if args.install_timer or args.uninstall_timer:
        return install_timer(o, args.interval, args.uninstall_timer)

    if args.candidates < 1 or args.candidates > MAX_CANDIDATES:
        print(f"--candidates must be 1..{MAX_CANDIDATES} (the REST budget: 1 + 4*candidates <= {REST_BUDGET})",
              file=sys.stderr)
        return 2
    if args.max_prs < 1 or args.max_prs > 100:
        # ⛔ THE API CAPS `per_page` AT 100. Accepting --max-prs 200 would return at most 100 rows
        # while the full-page guard compares `len(rows) >= 200`, which can never be true: the guard
        # would go silently inert and the listing would truncate — the exact defect it was added for,
        # reachable by following the tool's own remedy.
        print("--max-prs must be 1..100 (the API's per_page cap; a larger value disables the truncation "
              "guard instead of raising the bound)", file=sys.stderr)
        return 2

    md = o / STATE_MD
    skipped = ""
    # ⛔ BOUND BEFORE THE GUARD because `repo_path_of` can raise, and an UnboundLocalError after the
    # guard replaced the caught OSError with a crash that wrote NO report. (Nothing reads it outside the
    # guard today — this is the guard against a future consumer dereferencing it unbound, not a claim
    # about the current code.)
    repo_path: Path | None = None
    landing: list[dict] = []
    deploy: list[dict] = []
    budget = Budget("gh")          # replaced once gh resolves; carries the header's numbers
    dispatched = False
    main = ""
    # ⛔ BOTH MAINS EXIST FROM THE FIRST LINE OF THE CYCLE. `hmain` is assigned inside the try (it needs
    # the repo resolution that the MISMATCHED-repo REFUSE raises out of), and the goal block runs on the
    # REFUSAL path too — so an unset name there turned a clean `STANDING=NOT-MEASURED (MISMATCHED repo…)`
    # into an UnboundLocalError with no report written (caught by §28's mismatch test, which is the
    # only path that reaches the goal block with the resolution never run).
    hmain = ""
    main_why = ""
    slug = args.repo or "<unresolved>"
    drift: list[dict] = []
    goal_lines: list[str] = []
    goal_actions: list[str] = []
    # ONE try around the READS THAT CAN SKIP THE WHOLE CYCLE (repo identity, gh, the rate-limited
    # budget, the open-PR listing). A single candidate's surface failing inside landing_cycle is
    # handled there — it becomes an UNREADABLE reading for that PR, not a skipped cycle.
    try:
        repo_path = repo_path_of(o)
        slug = repo_slug(repo_path, args.repo)
        own = github_origin(repo_path)
        if own and slug and own.lower() != slug.lower():
            # ⛔ REFUSE RATHER THAN GUESS. Every head-bound gate below reads evidence out of the
            # CHECKOUT (`refs/claims/*`, `origin/main`), so a target that differs from the checkout
            # means those gates were never asked about the PRs they are gating.
            raise Skipped(
                f"MISMATCHED repo — the target is {slug} but this checkout's origin is {own}, so the "
                f"claim refs and origin/main would be read from the WRONG repo (a live cross-box "
                f"claim would read as claim=none). Run this from {slug}'s checkout")
        # ⛔ ONE READ, BEFORE ANYTHING THAT COMPARES AGAINST IT. The goal block, the deploy table,
        # the header and `--json` all consume THIS value; there is no later read to diverge from it.
        main = origin_main(repo_path)
        # ⛔ THE HARNESS MAIN IS ITS OWN READ, AND ONLY WHEN IT IS A DIFFERENT REPO (#2679). Goal 2
        # compares harness shas, which are agent-infra commits, against "the same version everywhere"
        # — so the comparison must use the HARNESS repo's `origin/main`, never the swept repo's. When
        # the two are the same repo (the normal agent-infra sweep) this REUSES the single read, so the
        # one-read discipline is untouched and there is no second value to diverge from.
        hrepo = harness_repo_of(o)
        if hrepo is None:
            # ⛔ UNRESOLVED IS NOT "THE SWEPT REPO". The first cut defaulted `hmain` to the swept repo's
            # main whenever the harness repo could not be resolved, so the goals compared a harness sha
            # against a foreign main AND the header printed that foreign sha under a `**harness main:**`
            # label — an assertion about a read that never happened, in the block the owner acts on.
            hmain = ""
            main_why = ("the harness repo could not be resolved (no `HARNESS_REPO`, no checkout beside "
                        "`$O`, and none containing this script)")
        elif git_dir(hrepo) and git_dir(hrepo) == git_dir(repo_path):
            hmain = main          # ONE repo, ONE read: the one-read discipline is untouched here
            main_why = ""
        else:
            hmain = origin_main(hrepo)
            main_why = ""
            if not hmain:
                main_why = "the harness repo's `origin/main` was unreadable"
        budget = Budget(resolve_gh(o))
        budget.rate_limit()
        # ⛔ ORDER: DRIFT → THE TWO GOALS → THE PR READS (owner's ask, 2026-10-24).
        # The goals are what the PR queue is FOR. Measured failure without this order: the PR reads
        # ran first, spent the whole core budget (`8/8` at 04:22Z), and every goal line said "not
        # measured" — a reminder that reported on PRs and forgot what the PRs are for. Drift is a
        # LOCAL artifact read (no REST), the goals spend the SEARCH quota (a different bucket), so
        # neither can starve the landing arm's documented `REST_BUDGET`.
        drift = drift_rows(o, hmain, harness_repo=hrepo)
        goal_lines, goal_actions = goal_progress(drift, budget, slug, main_sha=hmain,
                                                 main_why=main_why)
        landing, dispatched = landing_cycle(args, o, slug, repo_path, budget)
    except Skipped as e:
        skipped = str(e)
        landing = []
    except OSError as e:
        # ⛔ A READ-ONLY OR FULL $O MUST STILL PRODUCE THE REPORT (or say why it could not): an
        # uncaught OSError meant a traceback, no MERGE-REMINDER.md and no stated reason.
        # ⛔ AND `dispatched` IS NOT RESET: a dispatch is a FACT about a child process that is
        # already running, not a value a failed read gets to withdraw.
        skipped = f"UNREADABLE environment — {type(e).__name__}: {e}"
        landing = []
    if not goal_lines:
        # The cycle never REACHED the goal read (a Skipped rate limit, an unreadable repo, or a
        # probe that failed inside `drift_rows`). It is REPORTED as unmeasured, with the reason —
        # a goal block that is simply absent reads as "no work left", which is the false PASs this
        # whole file exists to prevent.
        goal_lines, goal_actions = goal_progress(
            drift, budget, slug,
            skipped=skipped or "the cycle did not reach the goal read", main_sha=hmain,
            main_why=main_why)
    if not skipped:
        # The deploy arm runs AFTER the landing decision, and a landing dispatched this cycle
        # DEFERS it: restarting a controller under the rail we just started destroys that run.
        # `args.act` is passed because `--no-act` is the INSPECT mode and it covers both arms.
        try:
            deploy = deploy_arm(o, hmain, dispatched, args.verify_deploy_s, args.dry_run,
                                args.act, args.retry_s, harness_repo=hrepo)
        except (Skipped, OSError) as e:
            # The deploy arm can refuse a whole cycle (a malformed inventory) or hit an environment
            # error. Neither may leave the deliverable unwritten — say it in the table instead.
            deploy = [{"box": "(the whole arm)", "harness": "", "relation": "",
                       "controller": "", "roles": "", "source": "",
                       "readings": "", "verdict": f"SKIPPED({e})"}]

    # ⛔ NO THIRD READ. The late retry that used to live here was justified as "for the OSError path",
    # but `run()` turns every OSError into rc 126, so `main_sha` cannot raise and the block had no
    # legitimate caller left: its only effect was to give `compose()` a sha that the goals block had
    # never compared against (round-4 review, proved with a stub that fails the first reads only).
    line = one_line_of(landing, deploy, skipped, dispatched)
    err = compose(md, slug, main, budget, landing, deploy, skipped, line,
                  goal_lines, goal_actions, harness_main=hmain)
    if err:
        # ⛔ THE REMINDER IS THE DELIVERABLE: a cycle whose file could not be written did not run,
        # whatever else it managed to do. Saying "ran" (exit 0) over a missing file is the same
        # false-pass shape as a green reading over an unread surface.
        print(f"⛔ could not write {md}: {err}", file=sys.stderr)
        skipped = (skipped + "; " if skipped else "") + f"UNREADABLE report — {err}"
        line = one_line_of(landing, deploy, skipped, dispatched)

    if args.json:
        print(json.dumps({
            "ts": now_iso(), "repo": slug, "main": main, "harness_main": hmain,
            "skipped": skipped,
            "rest_calls": budget.calls, "rest_budget": REST_BUDGET,
            "core": {"remaining": budget.core_remaining, "limit": budget.core_limit},
            "search_calls": budget.search_calls, "search_budget": GOAL_SEARCH_BUDGET,
            "goals": goal_lines, "goal_actions": goal_actions,
            # ⛔ THE MACHINE SURFACE MUST CARRY THE SAME READING AS THE REPORT. Publishing only
            # `relation` let a consumer re-derive the marker as `relation == "current"` - exactly the
            # fail-open the human report was just fixed for. `on_pin` + its `reasons` are the answer.
            "drift": [{"box": r["box"], "harness": r["harness"],
                       "relation": r["relation"], "readable": r["readable"],
                       "source": r.get("source", ""), "controller": r.get("controller", ""),
                       "running": r.get("running", ""),
                       "on_pin": bool(r.get("on_pin")), "reasons": list(r.get("reasons") or []),
                       "inventory": r.get("inventory", ""), "note": r.get("note", "")}
                      for r in drift],
            "landing": [{"pr": r["pr"]["number"], "head": r["pr"]["head"], "rank": r["rank"],
                         "verdict": r["verdict"], "readings": r["readings"],
                         "detail": r["detail"], "dispatch": r.get("dispatch", False),
                         "attest_detail": r.get("attest_detail", ""),
                         "claim_detail": r.get("claim_detail", ""),
                         "rail_detail": r.get("rail_detail", "")}
                        for r in landing],
            "deploy": deploy, "line": line,
        }, indent=2))
    elif not args.quiet:
        print(line)
    # A skipped cycle is exit 3: a caller (or the owner reading a log) must be able to tell "nothing
    # to do" from "I could not look". Everything else ran.
    return 3 if skipped else 0


def one_line_of(landing: list[dict], deploy: list[dict], skipped: str,
                dispatched: bool = False) -> str:
    if skipped:
        # A dispatch can happen BEFORE the skip is discovered (the report write is what failed), so
        # "SKIPPED (no dispatch)" would contradict a rail that is already running.
        tail = (" (a rail WAS dispatched this cycle — see $O/logs/merge-reminder-rail-*.log for "
                "its rc)" if dispatched else " (no dispatch)")
        return f"MERGE-REMINDER SKIPPED — {skipped}{tail}"
    if not landing:
        head = "no landing candidates"
    else:
        best = landing[0]
        head = (f"#{best['pr']['number']} rank={best['rank']}/{len(landing)} "
                f"[{best['readings']}] {best['verdict']} :: {best['pr']['title']}")
        dispatch = [r for r in landing if r.get("dispatch")]
        if dispatch:
            d = dispatch[0]
            head = (f"#{d['pr']['number']} [{d['readings']}] {d['verdict']} "
                    f":: {d['pr']['title']} :: {d['detail']}")
    dep = [f"{d['box']}={d['verdict']}" for d in deploy if d["verdict"] not in ("current",)]
    if dep:
        head += " || deploy: " + "; ".join(dep)
    return head


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Skipped as e:            # a Skipped that escaped main() (should not happen) is still named
        print(f"MERGE-REMINDER SKIPPED — {e} (no dispatch)", file=sys.stderr)
        sys.exit(3)
