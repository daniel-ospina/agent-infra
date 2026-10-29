#!/usr/bin/env bash
# lane-merge.sh — THE BOUNDED MERGE LOOP, as code. A lane runs this after it opens its PR.
#
#   lane-merge.sh <pr> --issue <n> [--repo OWNER/REPO] [--branch BR] [--rounds N]
#   lane-merge.sh <pr> --watch          # continue waiting for the chain launched by the last round
#   lane-merge.sh <pr> --status         # print the recorded verdict. No network, no writes.
#
# ⛔ WHY THIS FILE EXISTS. A lane is not done when it opens a PR. Measured 2026-10-18: the fleet had
# 22 open PRs and 3 merged, because every lane treated "PR opened" as success and exited — so the
# merge work piled up behind the running lanes and the backlog grew while the fleet looked busy.
# The instruction alone is not enough (a brief that says "keep merging" leaves the lane to invent a
# polling loop, and an invented loop is unbounded): this script gives the lane the loop, with the
# cap enforced HERE, in code, so a lane stuck in round 5 is refused by the tool instead of being
# mistaken for thoroughness.
#
# THE LOOP, exactly:
#   round k:  wait for THIS head's checks to be terminal (bounded)  →  read the failing names
#             →  FIX_REQUIRED (the lane fixes, pushes, runs again)     or green
#             →  green: launch the harness's per-PR chain (merge-one.sh) DETACHED
#             →  WAITING: --watch until it merges / a fix is required / it blocks
#   cap:      LANE_MERGE_MAX_ROUNDS (default 3) FIX rounds, then BLOCKED_ATTEMPTS + a PR comment
#
# ⛔ WHO MERGES, AND WHY IT IS NOT A SELF-REVIEW. The merge itself is `$O/merge-one.sh` — the
# harness's one per-PR chain, which resolves the repo's OWN merge authority (agent-infra#1764):
#   * rail repo (agent-infra): it runs the repo's rail (`scripts/admin-merge.sh`), which posts its
#     own head-bound evidence. The reviewer is deliberately skipped there — that repo's merge
#     contract does not consume a review marker, and minting one would edit a PR body for no gate.
#   * gate repo (tortoise): it dispatches a FRESH-CONTEXT reviewer, records the verdict with
#     record-review.sh (which VERIFIES the evidence comment), and only then merges.
# A lane must never call `record-review.sh` itself: a lane attesting to its own review is a review
# that did not happen, and `record-review.sh` refuses an unverifiable artifact anyway. This script
# never mints a record — it only drives the chain, and reads the result.
#
# ⛔ SPARSE GITHUB CALLS. 22 landers poll the same rate-limited account. This script:
#   * uses REST (`gh api repos/…`), never GraphQL;
#   * reads the PR ONCE per invocation and the checks at most once per poll interval;
#   * waits on LOCAL state files (no API) while the chain runs;
#   * posts exactly ONE handoff comment, only on a terminal block, and only if that head has not
#     already been commented.
#
# EXIT CODES — the lane's brief maps each of these to one action, so the code is the contract:
#   0   MERGED               the PR is merged (the merge sha is printed)
#   10  FIX_REQUIRED         its own checks are RED — fix the printed names, push, run again
#   15  FIX_CONFLICT         the PR is DIRTY — re-apply this lane's own change onto current main
#                            and force-push its OWN branch (never pick a side on a generated file)
#   11  WAITING              the chain is running detached — call `--watch` (burns no round)
#   12  BLOCKED_ATTESTATION  green and mergeable, but the chain produced no signed review at this
#                            head and did not merge: the ONE thing a lane cannot supply itself
#   13  BLOCKED_ATTEMPTS     the round cap is spent — hand off (a PR comment states the reason)
#   14  BLOCKED              the rail froze this head / it is closed / unreadable — hand off
#   2   usage or environment error (nothing was attempted)
#
# A NAIVE TEST CANNOT PASS: `--checks-tsv` and `--pr-tsv` inject the two API reads, so the state
# machine is driven offline from fixtures in lane-merge.test.sh. Every verdict below is asserted
# there, including that the cap is REACHED and that a lane can never merge without the chain.

set -u
log_line() { printf '%s\n' "$*"; }
say_err() { printf '%s\n' "$*" >&2; }

PR=""; ISSUE=""; OR=""; BR=""; WATCH=0; STATUS=0
CHECKS_TSV=""; PR_TSV=""; MAX_ROUNDS_OVERRIDE=""
# ── THE ROUTER SEAM (#2866) ───────────────────────────────────────────────────────────────────
# `pr-state.sh` is the ONE consumer seam for the PR state table; a lane that re-derives "what does
# this head need next" is the defect #2866 names. Sourced when present, and its absence is PRINTED
# at the point of use (never silently skipped).
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)/pr-state.sh" 2>/dev/null || true
lrow=""
while [ $# -gt 0 ]; do
  # ⛔ A VALUE-LESS TRAILING FLAG USED TO SPIN FOREVER (landing-review P2, REPRODUCED). Seven arms ended
  # in `shift 2` while reading "${2:-}": with the flag as the LAST argument `$#` is 1, `shift 2` fails
  # (there is no `set -e`), `$1` is unchanged, and `while [ $# -gt 0 ]` re-enters the same arm forever —
  # silently, because this bash prints nothing for the failed shift. A lane then looked wedged for its
  # whole LANE_TIMEOUT and the bounds this script adds never ran, because it was still parsing argv.
  # `need_val` refuses instead: every arm that takes a value goes through it.
  need_val() { [ $# -ge 2 ] && [ -n "${2:-}" ] || { say_err "lane-merge: $1 needs a value"; exit 2; }; }
  case "$1" in
    --issue)   need_val "$1" "${2:-}"; ISSUE="$2"; shift 2 ;;
    --repo)    need_val "$1" "${2:-}"; OR="$2"; shift 2 ;;
    --branch)  need_val "$1" "${2:-}"; BR="$2"; shift 2 ;;
    --rounds)  need_val "$1" "${2:-}"; MAX_ROUNDS_OVERRIDE="$2"; shift 2 ;;
    --watch)   WATCH=1; shift ;;
    --status)  STATUS=1; shift ;;
    # TEST SEAMS (documented, not hidden): inject the two API reads from a fixture.
    --checks-tsv) need_val "$1" "${2:-}"; CHECKS_TSV="$2"; shift 2 ;;
    --pr-tsv)     need_val "$1" "${2:-}"; PR_TSV="$2"; shift 2 ;;
    -h|--help) sed -n '2,60p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*) say_err "lane-merge: unknown flag '$1' (see --help)"; exit 2 ;;
    *) if [ -z "$PR" ]; then PR="$1"; else say_err "lane-merge: unexpected argument '$1'"; exit 2; fi; shift ;;
  esac
done
case "${PR:-}" in ''|*[!0-9]*) say_err "lane-merge: refusing non-numeric PR '${PR:-<empty>}'"; exit 2 ;; esac
O="${O:-$HOME/orchestrator}"; mkdir -p "$O/state" "$O/logs" 2>/dev/null || true
# The integer tunables feed `[ -ge ]` and `$(( ))`. Reject a leading zero (octal) and an absurd
# magnitude, exactly as fix-one.sh/merge-one.sh do — a huge value errors FALSE on bash 3.2 and the
# cap would then be silently missed, which is the one failure this file exists to prevent.
is_limit() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; 0) return 0 ;; 0*) return 1 ;; *) [ "${#1}" -le 9 ] ;; esac; }
MAX_ROUNDS="${LANE_MERGE_MAX_ROUNDS:-3}"
[ -n "$MAX_ROUNDS_OVERRIDE" ] && MAX_ROUNDS="$MAX_ROUNDS_OVERRIDE"
is_limit "$MAX_ROUNDS" || { say_err "lane-merge: LANE_MERGE_MAX_ROUNDS='$MAX_ROUNDS' is not a bounded integer — using 3"; MAX_ROUNDS=3; }
# ⛔ SIZED TO THE CI IT WAITS FOR, NOT TO A ROUND NUMBER (measured on this change's own PR: a
# 22-check commit on a loaded box reached 7/22 completed at 15 min and was still 15-in-flight at the
# old 900s bound, so EVERY lane would have spent a chunk on "still in flight — re-run"). 1500s covers
# a ~25 min CI. It is a MERGE-PHASE cost from the lane's own wall clock (`LANE_TIMEOUT`, which resolves
# to the `LANE_BACKSTOP_S` seam when unset — agent-infra#2888), so the
# supervision bound below is derived from what is left AFTER it AND after the lane's implementation
# time — the two must not add up to the whole clock. A re-run is still permitted and still cheap (one
# PR read) — the bound is a runaway guard, never a reason to call a head green.
WAIT_S="${LANE_MERGE_WAIT:-1500}";     is_limit "$WAIT_S" || WAIT_S=1500     # per-round check wait
POLL_S="${LANE_MERGE_POLL:-120}";      is_limit "$POLL_S" || POLL_S=120      # one --watch chunk
# ⛔ --watch IS BOUNDED TOO. A pid probe cannot distinguish "the chain is still working" from "the pid
# was reused", so an unbounded --watch loop would be a lane that never ends — the same defect the
# round cap removes, one layer down.
# ⛔ AND THE BOUND MUST BE SIZED TO WHAT THE LANE CAN ACTUALLY SPEND, WHICH IS NOT THE WHOLE WALL CLOCK
# (reviewer finding, P1, verified). The previous sizing satisfied `WAIT_S + MAX_WATCH x POLL <=
# LANE_TIMEOUT` by making the two sides EQUAL: 1500 + 15 x 120 = 3300 = lane.sh's LANE_TIMEOUT. That sum
# is spent from the SAME wall clock that pays for the lane's implementation, its commits, its pushes and
# opening the PR — for which it left exactly ZERO. So with any real implementation time the lane was
# killed at 3300s still inside its merge phase: neither bound was ever REACHED by the lane that owns
# them, no verdict was written, no hand-off comment was posted, and the only signal left was lane.sh's
# "NO merge-phase verdict" line. The BLOCKED_ATTEMPTS / "supervision budget spent" path was unreachable
# in production — an instrument that only fires for a lane that could not exist.
# So the invariant has THREE terms, and the lane's own implementation time is one of them:
#     WAIT_S + MAX_WATCH x POLL + IMPL_RESERVE_S <= LANE_TIMEOUT
# IMPL_RESERVE_S is the floor a lane needs for implement → commit → push → open PR before its merge
# phase can start; the merge phase must never be sized out of it. MAX_WATCH is DERIVED from what that
# leaves (never a literal), so raising LANE_TIMEOUT buys supervision and lowering it cannot silently
# eat the implementation time again. Shipped defaults:
#     7200 - 1500 (check wait) - 900 (implementation reserve) = 4800s / 120s = 40 chunks (4800s)
# i.e. the merge phase is bounded at 6300s of the 7200s clock, and a lane that implements within its
# reserve reaches BOTH bounds. A cycle that needs longer is not a lane failure: it hands off as
# WAITING_* (exit 11) and the next invocation resumes the SAME counter.
IMPL_RESERVE_S="${LANE_MERGE_IMPL_RESERVE:-900}"; is_limit "$IMPL_RESERVE_S" || IMPL_RESERVE_S=900
# ⛔ THE DEFAULT IS THE SEAM, NOT A LITERAL (agent-infra#2888 review, P2). This said `${LANE_TIMEOUT:-3300}`
# with no fallback, and `lane.sh` does not export `LANE_TIMEOUT` — so the merge phase permanently spent
# 45% of the clock the lane now owns (3240s of 7200s), while the header above claims the budget is
# "DERIVED from the lane's own wall clock". `LANE_BACKSTOP_S` IS exported by spawn-gate.sh, so a child
# process inherits it; the literal stays as the last resort for a standalone run whose box predates the
# seam. lane-merge.test.sh asserts THIS expression against lane.sh's own resolution, so the two files
# cannot drift apart in silence again.
LANE_WALL_S="${LANE_TIMEOUT:-3300}";              is_limit "$LANE_WALL_S" || LANE_WALL_S=3300
# The divisor is floored at the shipped chunk length: LANE_MERGE_POLL=0 is a legitimate value (a chunk
# that exits at once at its deadline), and dividing by it would break the arithmetic below instead of
# yielding a bound.
_fit_poll="$POLL_S"; [ "$_fit_poll" -ge 1 ] || _fit_poll=120
MAX_WATCH_FIT=$(( (LANE_WALL_S - WAIT_S - IMPL_RESERVE_S) / _fit_poll ))
[ "$MAX_WATCH_FIT" -ge 1 ] || MAX_WATCH_FIT=1          # a tiny LANE_TIMEOUT still supervises once
MAX_WATCH="$MAX_WATCH_FIT"
if [ -n "${LANE_MERGE_MAX_WATCH:-}" ] && is_limit "${LANE_MERGE_MAX_WATCH:-}"; then
  # An explicit override is an operator's escape hatch and is HONOURED rather than silently rewritten —
  # but it is never silent about breaking the invariant above, because the next reader would take the
  # bound at face value.
  MAX_WATCH="$LANE_MERGE_MAX_WATCH"
  [ "$MAX_WATCH" -le "$MAX_WATCH_FIT" ] || say_err "lane-merge: LANE_MERGE_MAX_WATCH=$MAX_WATCH exceeds what LANE_TIMEOUT=${LANE_WALL_S}s affords after the check wait (${WAIT_S}s) and the implementation reserve (${IMPL_RESERVE_S}s) — $MAX_WATCH_FIT chunk(s) fit; honouring the override, but the lane's wall clock ends the phase first."
fi
INTERVAL="${LANE_MERGE_INTERVAL:-20}"; is_limit "$INTERVAL" || INTERVAL=20
[ "$INTERVAL" -ge 5 ] || INTERVAL=20

PHASE_F="$O/state/lanemerge-$PR.phase"   # "this lane IS in its merge phase" (chain-merge waits on it)
ROUND_F="$O/state/lanemerge-$PR.round"
VERDICT_F="$O/state/lanemerge-$PR.verdict"
LAST_F="$O/state/lanemerge-$PR.last"
# ⛔ `LAST_F` IS PER-PR, BUT ITS NAMES ARE PER-HEAD (reviewer finding, R10): it is written when a red
# set is read and cleared nowhere, so a hand-off at a NEWER head still claimed "a CI run was read to
# terminal and its failing names are recorded below" — with the PREVIOUS head's names, under "do not
# redo it". The head it was written for is recorded beside it; the bullet renders only on a match.
LASTHEAD_F="$O/state/lanemerge-$PR.lasthead"

# ⛔ ONE BRANCH RESOLUTION FOR THE WHOLE SCRIPT (reviewer finding, P2, R13). `launch_chain` resolved it
# from the process CWD with no `-C "$REPO_PATH"`, while handing the chain `REPO_PATH` — so in any
# `.worktrees/*` checkout they can differ, and the detached chain would fetch a SIBLING LANE's branch and
# have the reviewer read that lane's content at this PR's paths, silently, on the path with no human in
# it. `git rev-parse --abbrev-ref HEAD` also answers "HEAD" when detached, and `origin/HEAD` is main.
# merge-one.sh never validates BR, so this is the only place it can be caught.
resolve_branch() {
  local rp="${1:-${REPO_PATH:-$(pwd)}}" b
  # ⛔ THE OVERRIDE GETS THE SAME FILTER (reviewer finding, P2, R14, measured): filtering only the
  # git-derived value let `--branch HEAD` through — it launched the chain with BR=HEAD and rendered it in
  # a hand-off — and `origin/HEAD` is main, so the reviewer read MAIN's content under this PR's name. The
  # hand-off's own remedy ("Pass --branch <name>") was the thing that fed it. `HEAD`, empty and spaced
  # values are refused here, which makes the LAUNCH refuse (WAITING_NO_BRANCH) and the body render
  # `<branch>` with the hint.
  if [ -n "${BR:-}" ]; then
    case "$BR" in ''|HEAD|*[[:space:]]*) printf '%s' "" ;; *) printf '%s' "$BR" ;; esac
    return 0
  fi
  b="$(git -C "$rp" branch --show-current 2>/dev/null)"
  case "${b:-}" in ''|HEAD|*[[:space:]]*) b="" ;; esac
  printf '%s' "$b"
}
RESOLVED_BR="$(resolve_branch)"
CHAIN_F="$O/state/lanemerge-$PR.chain"     # "<pid> <head> <chain-log>"
WATCH_F="$O/state/lanemerge-$PR.watch"     # --watch chunks spent (its own bound, see below)
CHAIN_LOG="$O/logs/lane-merge-$PR.log"

# disposition — WHAT THIS CHUNK ESTABLISHED, overwritten by every wait exit so the exhausted-budget
# hand-off can only ever describe the chunk that just ran.
# ⛔ IT MUST BE WRITTEN ON EVERY WAIT EXIT, NOT ONLY ON WAITING_API (reviewer finding, P2, measured):
# a disposition from an earlier chunk survived a run of `WAITING_LOAD` chunks, and the hand-off then
# said "the LAST chunk could not READ the merge confirmation: the PR may well be merged" about fifteen
# chunks that had read the PR fine and been refused by the load gate. A false claim, posted as a PR
# comment, with the real cause never named.
disposition() { printf '%s\n' "$*" > "$O/state/lanemerge-$PR.lastdisp" 2>/dev/null || true; }
verdict() { # verdict <TOKEN> <reason…> — the ONE writer, so no exit path can skip the record
  local tok="$1"; shift
  printf '%s %s\n' "$tok" "$*" > "$VERDICT_F"
  # The ISSUE-keyed copy is lane.sh's post-run diagnostic ("no merge-phase verdict"); chain-merge.sh
  # waits on the PR-keyed file above ($PR_VERDICT, chain-merge.sh:121). Both are written here, and
  # neither reader falls back to the other — so a comment naming the wrong file misleads a maintainer
  # into "fixing" the wrong write (reviewer finding, P2).
  [ -n "$ISSUE" ] && printf '%s %s\n' "$tok" "$*" > "$O/state/lanemerge-issue-$ISSUE.verdict"
  return 0
}
round_of() { local r=0; [ -f "$ROUND_F" ] && r="$(cat "$ROUND_F" 2>/dev/null || echo 0)"; is_limit "$r" || r=0; printf '%s' "$r"; }

# ── --status: no network, no writes. chain-merge.sh and an operator both read this. ──────────────
if [ "$STATUS" -eq 1 ]; then
  if [ -f "$VERDICT_F" ]; then cat "$VERDICT_F"; else log_line "NONE round=$(round_of)/$MAX_ROUNDS"; fi
  exit 0
fi

OR="${OR:-${GH_REPO:-}}"
if [ -z "$OR" ]; then
  # Resolve from the checkout this script is being run in, over GIT — not `gh repo view --json`,
  # which is served by GraphQL: the transport this harness has already had refuse outright (so the
  # header's "never GraphQL" would be a lie), and a call that costs quota for a datum git already
  # holds locally. Only reached when the caller did not name the repo (the brief always does).
  # ⛔ POSIX, NOT GNU (reviewer finding, P2, R11, measured): `+?` inside a `sed -E` RE is not supported by
  # BSD sed, so on this box the fallback yielded NOTHING and a hand-off's printed command exited 2 with
  # "the repo is unknown". `[^/]*` pairs are portable and do the same job.
  OR="$(git remote get-url origin 2>/dev/null | sed -E 's#^.*[:/]([^/]+)/([^/]+)$#\1/\2#' | sed 's/[.]git$//')"
fi
[ -n "$OR" ] || { say_err "lane-merge: the repo is unknown (pass --repo OWNER/REPO)"; exit 2; }

# ⛔ ANNOUNCE THE PHASE BEFORE DOING ANY WORK. chain-merge.sh finds the PR the moment it is open and
# would otherwise start its own review immediately — and a review recorded at a head this lane then
# fixes is a STRANDED attestation (the record binds the old head, so the gate goes red and the review
# is paid for twice). The marker is what it waits on, so it must exist before the first API read.
# The ISSUE is what makes the issue-keyed verdict (lane.sh's post-run diagnostic) exist at all, and a
# `--watch` call used to omit it — so a lane that BLOCKED during supervision left no issue-keyed
# record and lane.sh then reported "no verdict" over a lane that HAD named its blocker (A6).
# Persist the key on the first round; re-read it when a later invocation was not given one.
[ -n "${ISSUE:-}" ] && printf '%s\n' "$ISSUE" > "$O/state/lanemerge-$PR.issue" 2>/dev/null
[ -z "${ISSUE:-}" ] && ISSUE="$(cat "$O/state/lanemerge-$PR.issue" 2>/dev/null || true)"
printf '%s %s\n' "${ISSUE:-}" "$(date +%s)" > "$PHASE_F" 2>/dev/null || true

# ── the two reads (injectable) ───────────────────────────────────────────────────────────────────
# pr_read → "<state>|<merged_at>|<head_sha>|<mergeable_state>"
# ⛔ PIPE, NOT TAB. Tab is WHITESPACE to the shell, so `IFS=<tab> read` COLLAPSES empty fields — an
# unmerged PR (merged_at empty) then shifts its head sha into the merged slot and reads as MERGED.
# Reproduced while writing this file's own suite: `closed\t\tabc123\tclean` → "MERGED clean". A
# non-whitespace separator preserves the empty field, which is the whole point of a fixed arity.
pr_read() {
  if [ -n "$PR_TSV" ]; then [ -f "$PR_TSV" ] || return 1; cat "$PR_TSV"; return 0; fi
  gh api "repos/$OR/pulls/$PR" \
     --jq '[(.state // ""), (.merged_at // ""), (.head.sha // ""), (.mergeable_state // "")] | join("|")' 2>/dev/null
}
# merged_confirmed — the ONLY proof this loop accepts for MERGED. Returns 0 and prints the merge
# commit (or the merged_at stamp) only when THIS repo's PR reports merged.
# ⛔ A LOG LINE IS A HINT, NOT AN ARTIFACT (reviewer finding, P0, verified by measurement).
# `$O/logs/merge-<PR>.log` and `$O/state/merged-<PR>.done` are keyed by PR NUMBER ONLY, and `$O/state`
# is shared by every repo on the box — so a merge of `tortoise#<same n>` made this loop print
# "✅ MERGED — PR #<n> at head <tip>", exit 0, and record a MERGED verdict that `chain-merge.sh` then
# treated as "nothing left to review": the review was skipped, the merge never happened, and the lane
# read as done. One read, on this terminal path only, settles which PR was actually merged.
# ⛔ THREE OUTCOMES, NOT TWO (reviewer finding, P2, verified). An UNREADABLE API (rate limit, DNS, a
# failed gh) and an API that ANSWERED "not merged" are different facts, and collapsing them made a
# rate-limited read turn a genuinely MERGED PR into a terminal BLOCKED — "stop fixing and hand off" —
# with a comment asserting "reports no merged_at" about a read that never happened, while merge-rate.sh
# counted the lane as `other_end` and chain-merge re-ran merge-one.sh on an already-merged PR.
#   0 → merged (prints the merge commit)   1 → the API answered: NOT merged   2 → the read FAILED
merged_confirmed() {
  local mt rc=0 sha
  mt="$(gh api "repos/$OR/pulls/$PR" --jq '.merged_at // ""' 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] || return 2
  [ -n "${mt:-}" ] || return 1
  sha="$(gh api "repos/$OR/pulls/$PR" --jq '.merge_commit_sha // ""' 2>/dev/null)"
  printf '%s' "${sha:-$mt}"
  return 0
}

# checks_read → TSV rows "name\tstatus\tconclusion\tid\tapp_slug", ALL attempts (filter=all is not
# the default; the app slug is what keeps two workflows sharing a job name from masking each other).
# ⛔ NO `--paginate` ON THE POLL. `gh-limit.py` deliberately leaves every argv containing
# `--paginate` (or `--slurp`/`-H`/`--template`) COMPLETELY alone — its output cannot be re-created —
# so a paginated poll is NEVER made conditional and costs primary quota on every tick: 45 polls per
# invocation x 22 landers, on the one account that has already refused GraphQL outright. The
# un-paginated shape answers 304 (free) when nothing changed, which is the whole point of the layer.
# A head with MORE than one page of check-runs is rare and stable-ish; for that case only, do the one
# full paginated read (the count comes back in the same response, so the branch costs nothing extra).
checks_read() { # checks_read <head> [--full]
  local head="$1" full="${2:-}"
  # Defence in depth for the same defect: an empty head is a DEFAULT-BRANCH read, never this PR's.
  [ -n "$head" ] || { say_err "lane-merge: checks_read called with an EMPTY head — refusing (GitHub would answer for the default branch)"; return 1; }
  if [ -n "$CHECKS_TSV" ]; then [ -f "$CHECKS_TSV" ] || return 1; cat "$CHECKS_TSV"; return 0; fi
  local q="repos/$OR/commits/$head/check-runs?per_page=100&filter=all"
  local rows='(.check_runs[] | [(.name // ""), (.status // ""), (.conclusion // ""), (.id // 0), (.app.slug // "")] | @tsv)'
  if [ "$full" = "--full" ]; then
    gh api "$q" --paginate --jq "$rows" 2>/dev/null
    return $?
  fi
  # One page, plus the total as a 2-field TSV row so the caller can tell "this page is all of it"
  # from "there is more" (the caller strips it before classifying: `NF>=4`).
  gh api "$q" --jq "([\"TOTAL\", (.total_count | tostring)] | @tsv), $rows" 2>/dev/null
}

# classify <tsv-file> → prints exactly two lines:
#   "INFLIGHT <n>"
#   "RED <comma-separated names>"      (empty list = green)
# ⛔ IT TAKES A FILE, NOT A PIPE. `python3 - <<'PY'` reads the PROGRAM from stdin, so piping rows
# into it delivers the heredoc instead of the data and the classifier sees NOTHING — every red set
# comes back empty and a red head reads GREEN. That is a FALSE PASS in a merge gate; it was caught by
# this file's own suite (a `failure` conclusion classified as green) before it ever shipped.
# ⛔ ALLOW-LIST POLARITY, the rail's own (AGENTS.md "reading verification state"): of the COMPLETED
# attempts only success/neutral/skipped are green and cancelled/stale are non-red; EVERY OTHER
# CONCLUSION IS RED — including one GitHub has not documented yet, and a null one. An unnamed
# conclusion must never fall through a gap. Newest attempt per **(app, name)** by id — a job name
# shared across two workflows must not let one mask the other; `started_at` is nullable and is only a
# tiebreak, and grouping by check_suite would shatter one check per re-run.
classify() {
  python3 - "$1" <<'PY'
import sys
GREEN = {"success", "neutral", "skipped"}
NONRED = GREEN | {"cancelled", "stale"}
newest = {}
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    parts = line.rstrip("\n").split("\t")
    if len(parts) < 4:
        continue
    name, status, conclusion, cid = parts[0], parts[1].lower(), parts[2].lower(), parts[3]
    # GROUP BY (app, name), NOT NAME ALONE. A check-run's `name` is the JOB name, and two workflows
    # can publish the same one — so keying on the name lets the newest attempt of one mask the other
    # (this repo's own instructions record it: two `packaging-smoke` runs, one cancelled, one
    # success). The red is printed as `app:name` so a report says which one failed.
    app = parts[4].strip() if len(parts) > 4 else ""
    try:
        cid = int(cid)
    except ValueError:
        cid = 0
    key = (app, name)
    cur = newest.get(key)
    if cur is None or cid > cur[2]:
        newest[key] = (status, conclusion, cid)
inflight, red = 0, []
for (app, name), (status, conclusion, _cid) in sorted(newest.items()):
    if status != "completed":
        inflight += 1
    elif conclusion not in NONRED:
        red.append("%s:%s" % (app, name) if app else name)
print("INFLIGHT %d" % inflight)
print("RED %s" % ",".join(red))
PY
}

# ── chain supervision ────────────────────────────────────────────────────────────────────────────
chain_pid() { awk '{print $1}' "$CHAIN_F" 2>/dev/null; }
chain_head() { awk '{print $2}' "$CHAIN_F" 2>/dev/null; }
chain_alive() { local p; p="$(chain_pid)"; [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
chain_log() { local l; l="$(awk '{print $3}' "$CHAIN_F" 2>/dev/null)"; printf '%s' "${l:-$CHAIN_LOG}"; }

# resolve_trusted_checkout [lane-checkout] — the repo's MAIN worktree, the tree the chain must run from.
#
# ⛔ THE `$O` PIN ON merge-one.sh IS NOT ENOUGH (landing-review F1, P1). merge-one.sh resolves the repo's
# merge authority as `$REPO/scripts/admin-merge.sh`, and THAT rail resolves its own graders
# (`ci_exemption.py`, `ci-failure-set.sh`) from its own directory — admin-merge.sh's header calls a
# grader drawn from the graded system a bypass. The lane's cwd is `.worktrees/tm-<N>` on `feat/<N>-tm`,
# so handing `$(pwd)` to the chain made a PR that edits the rail or its graders merge THROUGH ITS OWN
# EDITED COPY, while lane-merge.sh's own comment claimed the authority could not come from a lane branch.
# So the checkout handed to the chain is resolved from the git common dir (the MAIN worktree) and the
# lane's own checkout is refused: fail-closed, because there is no other safe default here.
# Three outcomes, not two:
#   0 + a path  → the trusted checkout (the main worktree, or the lane's own tree when the lane IS the
#                 main worktree — the controller path, which is not a lane branch).
#   1           → the tree IS a git checkout but no main worktree could be resolved: REFUSE (fail-closed).
#   0 + the same path, no git  → the tree is not a git checkout at all. It cannot be a lane branch, and
#                 merge-one.sh fails loudly on it (it cd's there and finds no rail), so this is not a
#                 bypass — and refusing here would make the suite's throwaway-$T fixtures unrunnable
#                 while proving nothing about the property that matters.
resolve_trusted_checkout() {
  local lane="${1:-${REPO_PATH:-$(pwd)}}" main="" lane_real main_real
  lane_real="$(cd "$lane" 2>/dev/null && pwd -P)" || return 1
  [ -n "$lane_real" ] || return 1
  if ! git -C "$lane_real" rev-parse --git-dir >/dev/null 2>&1; then
    printf '%s' "$lane_real"; return 0
  fi
  main="$(git -C "$lane_real" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10); exit}')"
  [ -n "$main" ] && [ -d "$main" ] || return 1
  main_real="$(cd "$main" 2>/dev/null && pwd -P)" || return 1
  [ -n "$main_real" ] || return 1
  printf '%s' "$main_real"
}

# launch_chain <head> — start the harness's per-PR chain DETACHED and return immediately.
# ⛔ DETACHED, NOT A BLOCKING CALL. The chain pays for a fresh-context reviewer (up to REVIEW_TIMEOUT)
# and then runs the repo's rail; a lane that blocked on that inside one shell invocation would be
# silent for ~15-25 minutes, which reads as a wedged lane to every liveness instrument we have.
# ⛔ AND IT WILL NOT DOUBLE-REVIEW: merge-one.sh takes state/mergeclaim-<PR>.lock first, so a chain
# the controller already spawned owns the PR and ours exits without paying a second reviewer.
launch_chain() {
  local head="$1" chain="$O/merge-one.sh"
  # ⛔ THE FALLBACK MUST RESOLVE TO THE SAME TREE AS $O, NOT WHEREVER THIS FILE WAS INVOKED. $O's copy
# is the operator-seeded authority precisely so a lane cannot choose its own gate — and the natural
# way for a lane to run this script is the checkout copy (`scripts/orchestrator-harness/lane-merge.sh`
# is in its cwd), so an unconditional fallback would let a lane that edited `merge-one.sh` on its own
# branch merge its PR through ITS version of the merge gate. Refuse instead: the lane's remedy is to
# sync the harness, which is safe.
if [ ! -f "$chain" ]; then
  _d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ "$_d" = "$(cd "$O" 2>/dev/null && pwd)" ]; then
    chain="$_d/merge-one.sh"
  else
    say_err "lane-merge: $O/merge-one.sh is missing and the copy beside this script ($_d) is not the"
    say_err "  harness $O — refusing to select the merge authority from a checkout that may be a lane's"
    say_err "  own branch. Sync it: cp scripts/orchestrator-harness/*.sh $O/"
    exit 2
  fi
fi
  if [ ! -f "$chain" ]; then
    say_err "lane-merge: merge-one.sh not found (looked in $O and beside this script) — refusing to"
    say_err "            hand-roll a merge; sync the harness (cp scripts/orchestrator-harness/*.sh \$O/)"
    return 1
  fi
  # ⛔ THE CHECKOUT THE CHAIN RUNS FROM IS RESOLVED, NEVER INHERITED (landing-review F1). Resolved here,
  # once, so no caller can hand a lane's own worktree to the rail; the remedy on failure is a harness
  # problem, not something the lane can fix by pointing at another tree.
  TRUSTED_CHECKOUT="$(resolve_trusted_checkout "${REPO_PATH:-$(pwd)}")" || TRUSTED_CHECKOUT=""
  if [ -z "$TRUSTED_CHECKOUT" ]; then
    say_err "lane-merge: cannot resolve the repo's MAIN worktree from ${REPO_PATH:-$(pwd)} — refusing to"
    say_err "            hand the merge authority a checkout that may be this lane's own branch (the rail"
    say_err "            and its graders are read FROM THE TREE THE CHAIN RUNS IN). Run lane-merge.sh inside"
    say_err "            a git checkout of the repo whose main worktree is reachable via 'git worktree list'."
    verdict BLOCKED "no trusted (main) checkout could be resolved from the lane's checkout; the merge authority must not come from the lane's own branch"
    exit 2
  fi
  # ⛔ NO BRANCH, NO CHAIN (reviewer finding, P2, R13): merge-one.sh never validates BR, and its fetch is
  # `|| true`, so an empty branch would silently review whatever `origin/HEAD` points at. Fail loudly and
  # name the fix instead of launching a chain that cannot be right.
  if [ -z "${RESOLVED_BR// /}" ]; then
    say_err "lane-merge: cannot resolve a BRANCH for PR #$PR (detached checkout, or REPO_PATH is not a"
    say_err "            git repo) — refusing to launch a chain that would review the wrong tree."
    say_err "            Pass --branch <name> (the branch the PR is on) and re-run."
    disposition WAITING_NO_BRANCH
    verdict WAITING_NO_BRANCH "no branch could be resolved for this checkout; pass --branch"
    exit 2
  fi
  # THE LOCK IS A PID FILE, AND ITS EXISTENCE IS NOT A HOLDER (reviewer finding, reproduced). A bare
  # `[ -f lock ]` read a STALE lock (its worker had died) as a live owner: no chain was spawned, no
  # supervision target was recorded, and `--watch` then declared BLOCKED over a PR nobody was
  # merging — permanently foreclosing the lane. merge-one.sh's own claim reaper clears exactly this
  # condition, so do the same test it does: read the pid and probe it.
  if [ -f "$O/state/mergeclaim-$PR.lock" ]; then
    local opid; opid="$(cat "$O/state/mergeclaim-$PR.lock" 2>/dev/null || echo 0)"
    case "${opid:-0}" in ''|*[!0-9]*) opid=0 ;; esac
    if [ "$opid" -gt 0 ] && kill -0 "$opid" 2>/dev/null; then
      # A LIVE owner (the controller's chain, or an earlier round of ours): never spawn a competitor.
      # Record it as the supervision target so --watch can follow it by pid AND by its own log.
      # ⛔ DO NOT OVERWRITE AN EXISTING RECORD (reviewer finding, P1, verified): stamping the CURRENT
      # head onto a chain launched for an OLDER head defeats the head-moved guard below, which exists
      # to notice exactly that. The recorded head is the one the chain is actually working.
      if [ -s "$CHAIN_F" ]; then
        # ⛔ KEEPING THE RECORDED HEAD IS ONLY HALF THE FIX (reviewer finding, P2, verified): the file is
        # `<pid> <head> <log>`, and preserving ALL of it kept a DEAD pid too — so a live chain went
        # unsupervised behind a dead pid, whose stale log could then name FIX_REQUIRED/PARKED and burn a
        # round. The LIVE pid and the RECORDED head are both facts; write both.
        printf '%s %s %s\n' "$opid" "$(chain_head)" "$(chain_log)" > "$CHAIN_F"
        # Adopting a LIVE chain starts a new supervision lifetime: the per-chain counters describe the
        # chain that came before, and carrying them forward is how a stale head-moved count blocked a PR
        # on the first pass for ever (round-4 reviewer).
        rm -f "$O/state/lanemerge-$PR.headmoved" "$O/state/lanemerge-$PR.apiretry" \
              "$O/state/lanemerge-$PR.lastdisp" 2>/dev/null || true
        log_line "lane-merge: pid $opid already owns PR #$PR — supervising it at the recorded head $(chain_head) (log $(chain_log))"
      else
        printf '%s %s %s\n' "$opid" "${head:-}" "$O/logs/merge-$PR.log" > "$CHAIN_F"
        log_line "lane-merge: pid $opid already owns PR #$PR — supervising it (log $O/logs/merge-$PR.log)"
      fi
      return 0
    fi
    log_line "lane-merge: a STALE merge lock (pid ${opid:-?} is not alive) — clearing it and taking the PR"
    rm -f "$O/state/mergeclaim-$PR.lock"
  fi
  # ⛔ THE OUTCOME MUST OUTLIVE THE LANE (E6). This chain is launched DETACHED precisely so it keeps
  # running when the lane's wall clock ends — and the only writer of a MERGED verdict used to be the
  # live supervisor. So the SUCCESS case (lane killed, chain merges minutes later) left no MERGED
  # anywhere: chain-merge read no verdict, merge-rate counted the lane as PR_OPENED/UNKNOWN, and the
  # measured rate FELL as the change started working on the slowest PRs — an instrument punishing the
  # behaviour it was written to reward. The wrapper below writes the verdict from the chain's own
  # artifact (`state/merged-<PR>.done`, written by merge-one.sh) with no agent present.
  LM_O="$O" LM_VERDICT="$VERDICT_F" nohup bash -c '
    bash "$1" "$2" "$3" "$4" "$5"
    rc=$?
    # ⛔ A PR-NUMBER-KEYED MARKER IS NOT PROOF FOR *THIS* REPO (F3). `state/merged-<PR>.done` has no
    # repo component and $O/state is shared by every repo on the box, so a marker left by
    # tortoise#<same number> would make this wrapper declare premise-labs#<n> merged — and
    # chain-merge.sh then exits 0 on that marker WITHOUT REVIEWING, so the PR is never merged at all
    # while the verdict says MERGED. One REST read, on this rare path only, settles it.
    mt=""
    if [ -f "$LM_O/state/merged-$4.done" ]; then
      # (single quotes cannot appear here: this whole block is one single-quoted program)
      mt="$(gh api "repos/$3/pulls/$4" --jq ".merged_at // \"\"" 2>/dev/null)"
    fi
    if [ -n "$mt" ]; then
      m="$(cat "$LM_O/state/merged-$4.done" 2>/dev/null)"
      printf "%s\n" "MERGED ${m:-merged}" > "$LM_VERDICT" 2>/dev/null || true
      [ -n "${6:-}" ] && printf "%s\n" "MERGED ${m:-merged}" > "$LM_O/state/lanemerge-issue-$6.verdict" 2>/dev/null
      echo "[lane-merge] ✅ the chain merged PR #$4 at ${m:-?} (chain exit $rc)"
    else
      if [ -f "$LM_O/state/merged-$4.done" ]; then
        echo "[lane-merge] ⚠️ a state/merged-$4.done marker exists but repos/$3/pulls/$4 reports no merged_at — NOT recording MERGED (the marker may belong to another repo + same PR number $4)"
      fi
      echo "[lane-merge] the chain did not merge PR #$4 (chain exit $rc)"
    fi
  ' lane-merge-wrap "$chain" "$TRUSTED_CHECKOUT" "$OR" "$PR" \
      "$RESOLVED_BR" "${ISSUE:-}" \
      >> "$CHAIN_LOG" 2>&1 < /dev/null &
  printf '%s %s %s\n' "$!" "${head:-}" "$CHAIN_LOG" > "$CHAIN_F"
  rm -f "$O/state/lanemerge-$PR.headmoved" "$O/state/lanemerge-$PR.lastdisp" \
        "$O/state/lanemerge-$PR.apiretry" 2>/dev/null || true
  log_line "lane-merge: launched the merge chain (pid $!, log $CHAIN_LOG)"
  return 0
}

# chain_verdict_from_log — classify a FINISHED merge chain, from the artifacts that ACTUALLY exist.
#
# ⛔ IT MUST NOT READ THE CHAIN LOG FOR THE VERDICT (reviewer finding A1, verified against the
# shipped writers). The chain log (`lane-merge-<PR>.log`, or `chain-<N>.log`) carries only the
# chain's own progress lines and `merge-one rc=…`. The reviewer's outcome and the rail's verdict are
# written by merge-one.sh to ITS log — `$O/logs/merge-<PR>.log` — as `ISSUES <n>` /
# `NOT CLEAN or reviewer failed` / `MERGED via the rail` / `PARKED`, and the durable head-keyed
# markers are `state/needsfix-<PR>-<head>`, `state/parked-<PR>` and `state/parkreason-<PR>`.
# A classifier that greps only the chain log can never return FIX_REQUIRED, so every "the reviewer
# found issues" outcome would reach the lane as a terminal BLOCK — the one path that turns a paid
# review into work. The MARKERS are checked first: machine-written, and not mistakable for prose.
chain_verdict_from_log() { # chain_verdict_from_log <chain-log> [head]
  local clog="$1" mlog="$O/logs/merge-$PR.log" f seen_needsfix=0 at="${2:-${HEAD:-}}"
  # ⛔ `parked-<PR>` IS THE HEAD ITSELF (merge-one.sh:342), so EXISTENCE IS NOT A PARK AT THIS HEAD
  # (reviewer finding, P2, verified). Reading it by existence reported BLOCKED for a PR whose park was
  # superseded by a later push — and with an EMPTY reason, because `parkreason-<PR>` was rewritten by a
  # different cycle. Compare the content.
  if [ -f "$O/state/parked-$PR" ]; then
    case "$(cat "$O/state/parked-$PR" 2>/dev/null)" in
      "$at") [ -n "$at" ] && { echo "BLOCKED"; return; } ;;
      '')    echo "BLOCKED"; return ;;   # a bare marker (controller-written): no head to compare
    esac
  fi
  # ⛔ THE FIX MARKER IS HEAD-KEYED (`needsfix-<PR>-<head>`, merge-one.sh). A PR-WIDE glob read a marker
  # from a head the lane has already pushed past as "the reviewer found issues", burning a fix round on
  # a superseded head — `orch-loop.sh:1335-1339`'s recorded "owned forever" bug, reintroduced here
  # (reviewer finding, P1, verified). With no head to compare, fall back to the glob and say so.
  # ⛔ THE MARKER IS NOT THE VERDICT (reviewer finding, P1, measured). merge-one.sh writes
  # `needsfix-<PR>-<head>` for a real `ISSUES n` AND for "reviewer failed", so testing the marker FIRST
  # made the no-verdict split below unreachable on the production path: a cap-hit reviewer still came
  # back as a fix list, spent a fix round, and told the lane to read a comment that was never posted.
  # A marker therefore only counts as a fix list when the merge log carries an ACTUAL issue count; with
  # no count it is the no-verdict case and says so.
  # Three states, because a rotated log is not evidence either way:
  #   the log names an ISSUES count      → the marker IS a fix list
  #   the log names the reviewer FAILING → the marker is NOT a fix list (the no-verdict case)
  #   the log names neither (rotated)    → the DURABLE marker decides, as it always did
  _has_issues=0; _saw_failure=0
  if [ -s "$mlog" ]; then
    # ⛔ ANCHORED (reviewer finding, P2): the log is merge-one's stdout AND the reviewer's own prose,
    # so `grep 'ISSUES [0-9]+'` matched a reviewer that merely WROTE "ISSUES 2" somewhere. Only a line
    # that STARTS with the verdict counts — the same anchor merge-one uses when it reads it back.
    tail -n 300 "$mlog" 2>/dev/null | grep -qE '^ISSUES [0-9]+' && _has_issues=1
    tail -n 300 "$mlog" 2>/dev/null | grep -qE 'NOT CLEAN or reviewer failed' && _saw_failure=1
  fi
  _marker_is_fixlist() { [ "$_has_issues" = 1 ] || { [ "$_saw_failure" = 0 ]; }; }
  if [ -n "$at" ]; then
    if [ -e "$O/state/needsfix-$PR-$at" ]; then
      _marker_is_fixlist && { echo "FIX_REQUIRED"; return; }
      echo "REVIEW_NO_VERDICT"; return
    fi
  else
    for f in "$O/state/needsfix-$PR"-*; do [ -e "$f" ] && seen_needsfix=1; done
    if [ "$seen_needsfix" = 1 ]; then
      _marker_is_fixlist && { echo "FIX_REQUIRED"; return; }
      echo "REVIEW_NO_VERDICT"; return
    fi
  fi
  if [ -s "$mlog" ]; then
    # ⛔ "THE REVIEWER RECORDED ISSUES" AND "THE REVIEWER FAILED TO PRODUCE A VERDICT" ARE DIFFERENT
    # FACTS (reviewer finding, P2, measured). merge-one.sh's `*)` arm collapses them into one log line,
    # and this read then told the lane "read the review comment on PR #N and fix every finding" about a
    # run that posted NO comment at all — a fix round spent, rc=10, and nothing on the PR to read. The
    # header of this file measures that class at 43 of 124 runs, so it is not a corner case. Only an
    # ACTUAL issue count is a fix list; a failed/unrunnable reviewer gets its own token.
    if tail -n 300 "$mlog" 2>/dev/null | grep -qE '^ISSUES [0-9]+'; then echo "FIX_REQUIRED"; return; fi
    # ⛔ THE VOCABULARY IS THE WRITER'S, NOT AN APPROXIMATION OF IT (landing-review, two findings). Both
    # patterns below are taken from `merge-one.sh`'s own echo lines, because the strings they used to
    # carry were DEAD TEXT:
    #   * `NOT CLEAN or reviewer failed` — merge-one.sh writes, for a stall/crash/timeout,
    #         `[merge N] NO VERDICT (stall/crash/timeout, NOT 'issues') — no needsfix marker, …`
    #     (merge-one.sh:966); `NOT CLEAN` occurs there only inside the REVIEWER PROMPT as a forbidden
    #     phrase. So a verdict-less run fell to UNKNOWN → BLOCKED_ATTESTATION (12, "a signed review
    #     record does not exist") instead of WAITING_NO_VERDICT (11, re-run the chain).
    #   * `Successfully merged` appears NOWHERE in the repo, and `is MERGED` only in unrelated prose —
    #     while the GATE-mode success line is `[merge N] MERGED <date>` (merge-one.sh:941). On a gate
    #     repo (tortoise) a real merge therefore classified UNKNOWN → BLOCKED (14) with a hand-off
    #     comment on an already-merged PR, and chain-merge re-ran merge-one.sh on it.
    # Both spellings are accepted on purpose: a `$O` deployed before the rename still writes the older
    # `NOT CLEAN or reviewer failed` line, and a lane reading its own box's log must not misclassify it.
    if tail -n 300 "$mlog" 2>/dev/null | grep -qE 'NO VERDICT \(stall/crash/timeout|no needsfix marker|NOT CLEAN or reviewer failed'; then
      echo "REVIEW_NO_VERDICT"; return
    fi
    if tail -n 300 "$mlog" 2>/dev/null | grep -qE 'MERGED via the rail|^\[merge [0-9]+\] MERGED |Successfully merged|is MERGED'; then
      # The log SAYS merged; only the API may confirm it (see merged_confirmed). Unconfirmed reads as
      # UNKNOWN, not MERGED — the caller then refuses to claim a merge rather than claiming a false one.
      merged_confirmed >/dev/null; local _mc=$?
      [ "$_mc" -eq 0 ] && { echo "MERGED"; return; }
      # 2 = the read FAILED: re-runnable, not a verdict about the PR (see merged_confirmed).
      [ "$_mc" -eq 2 ] && { echo "API_UNREADABLE"; return; }
      echo "UNCONFIRMED_MERGE"; return
    fi
    tail -n 300 "$mlog" 2>/dev/null | grep -q 'PARKED' && { echo "BLOCKED"; return; }
  fi
  # ⛔ THE LOAD REFUSAL IS WRITTEN TO THE MERGE LOG, NOT THE CHAIN LOG (landing-review P2, verified).
  # `merge-one.sh` prints `[merge N] reviewer NOT started (pi spawn-point load gate) …` and exits 75 into
  # `$O/logs/merge-<PR>.log` — the file read as `$mlog` above; nothing writes that string to
  # `$O/logs/lane-merge-<PR>.log` (the chain log). Testing only `$clog` therefore made this arm
  # unreachable on the shipped path: a load refusal fell through to UNKNOWN and was handed off as
  # terminal BLOCKED_ATTESTATION with a cause that never happened ("no signed review record exists…"),
  # posting a comment on the PR, while the WAITING_LOAD sentence ("refused by the LOAD GATE — not a lane
  # failure") was unreachable. `$clog` stays as a second candidate because on the adopt/chain path
  # `chain_log` IS `$O/logs/merge-<PR>.log`, so either file can legitimately carry it.
  if { [ -s "$mlog" ] && tail -n 120 "$mlog" 2>/dev/null | grep -q 'reviewer NOT started\|load gate'; } \
     || { [ -s "$clog" ] && tail -n 80 "$clog" 2>/dev/null | grep -q 'reviewer NOT started\|load gate'; }; then
    echo "LOAD"; return
  fi
  [ -s "$O/state/parkreason-$PR" ] && { echo "BLOCKED"; return; }
  echo "UNKNOWN"
}

# ── FIX / BLOCK emitters (they own the round counter and the handoff comment) ────────────────────
# ── the hand-off's "how to merge this" instruction ────────────────────────────────────────────────
# ⛔ THE PRINTED REMEDY MUST NAME THE SAME CHECKOUT `launch_chain` WOULD ACCEPT (landing-review F1, P1,
# verified). It used `${REPO_PATH:-$(pwd)}` — the LANE'S OWN checkout — which is precisely the tree
# `resolve_trusted_checkout` refuses (see its header). `merge-one.sh` resolves the merge authority as
# `$REPO/scripts/admin-merge.sh`, and that rail resolves its own graders (`ci_exemption.py`,
# `ci-failure-set.sh`) from its own directory, so a PR that edits either was merged THROUGH THE LANE'S
# EDITED COPY by whoever followed the printed instruction: the exact bypass the launch path hardened
# the code against, reintroduced as documentation. So the instruction is derived from the SAME resolver
# as the launch, and when the resolver refuses the hand-off REFUSES TOO — an instruction must never
# point at a tree the guard refuses.
chain_cmd() { # chain_cmd <trusted-checkout> <branch> <lead-in> <suffix>
  printf 'Next: %s`bash "%s/merge-one.sh" "%s" "%s" %s "%s"`%s\n' \
    "$3" "$O" "$1" "$OR" "$PR" "$2" "$4"
}
merge_authority_unresolved_note() { # no trusted checkout could be resolved — refuse, do not point
  printf 'Next: NO merge command is printed here — no trusted (main) checkout could be resolved from\n'
  printf 'this lane'"'"'s checkout, and `merge-one.sh` reads the merge authority (`scripts/admin-merge.sh`)\n'
  printf 'and that rail'"'"'s own graders FROM THE TREE IT IS RUN IN. Aiming it at a lane worktree is the\n'
  printf 'bypass this script refuses to LAUNCH through, so it is not offered as a remedy either. Run the\n'
  printf 'chain from the repo'"'"'s MAIN worktree instead:\n'
  printf '  git worktree list --porcelain    # the FIRST "worktree " line names the main checkout\n'
  printf '  bash "%s/merge-one.sh" "<that path>" "%s" %s "%s"\n' "$O" "$OR" "$PR" "${_br:-<branch>}"
}

post_handoff() { # post_handoff <verdict-token> <reason>
  local tok="$1" reason="$2" marker body
  marker="<!-- lane-merge-handoff: ${HEAD:-unknown} -->"
  # Dedup per HEAD, and only on the terminal path: 1 read + at most 1 write.
  # THE NEWEST PAGE, NOT THE OLDEST. The default order is oldest-first, so on a PR with more than 100
  # comments an existing marker was never in the page and every invocation re-posted the handoff — a
  # write on a rate-limited account shared by 22 landers (reviewer finding).
  if gh api "repos/$OR/issues/$PR/comments?per_page=100&sort=created&direction=desc" --jq '.[].body' 2>/dev/null | grep -qF "lane-merge-handoff: ${HEAD:-unknown}"; then
    log_line "lane-merge: a handoff comment for this head already exists — not repeating it"
    return 0
  fi
  body="$(mktemp "${TMPDIR:-/tmp}/lane-merge-handoff.XXXXXX")"
  {
    printf '%s\n' "$marker"
    printf '## ⛔ Lane handoff — %s at head `%s`\n\n' "$tok" "${HEAD:-unknown}"
    printf 'This lane could not take PR #%s to `merged` and is handing off. The exact blocker:\n\n' "$PR"
    printf '    %s\n\n' "$reason"
    # ⛔ ONLY WHAT THIS RUN ESTABLISHED (reviewer finding, P2, measured). These were unconditional, so
    # a hand-off whose blocker was "checks never settled" said, nine lines later, "CI was driven to
    # terminal and its failing names were read, not guessed" — and a chain-absent hand-off claimed the
    # same about a chain that never existed. Each line now renders only where the disposition behind it
    # actually established it, and this script never pushes or merges, so it never claims to have.
    printf 'What was already done for the next holder (do not redo it):\n'
    _last_current=0
    if [ -s "$LAST_F" ] && [ "$(cat "$LASTHEAD_F" 2>/dev/null)" = "${HEAD:-}" ]; then _last_current=1; fi
    if [ "$_last_current" = 1 ]; then
      # ⛔ TERMINALITY IS NOT ESTABLISHED HERE (reviewer finding, P2, R11, measured): these names are written
      # whenever RED is non-empty, which includes a read with checks still IN FLIGHT. Say what is true.
      printf -- '- A CI run was read at THIS head; the failing names observed are recorded below.\n'
    fi
    if [ "$_last_current" = 1 ]; then
      printf -- '- Last failing check names observed: `%s`\n' "$(tr '\n' ',' < "$LAST_F" | sed 's/,$//')"
    fi
    _rs="$(round_of)"; [ "$_rs" -gt "$MAX_ROUNDS" ] && _rs="$MAX_ROUNDS"   # never render "4/3"
    printf -- '- Rounds spent: %s/%s (the loop is capped by design — a lane in round 5 is a failure, not thoroughness).\n\n' "$_rs" "$MAX_ROUNDS"
    # ⛔ THE BRANCH MUST BE RESOLVED, NOT A PLACEHOLDER (reviewer finding, P1, R11, measured): the brief's
    # own `--watch` call never passes `--branch`, so `${BR:-<branch>}` rendered the literal `<branch>` on
    # the documented supervision path — and merge-one feeds that argument into `git fetch origin "$BR"`,
    # so the next holder paid up to 1800s for a reviewer aimed at a ref that does not exist.
    # ⛔ A DETACHED HEAD IS NOT A BRANCH (reviewer finding, P2, R12, measured): `git rev-parse
    # --abbrev-ref HEAD` answers "HEAD" outside a branch, and `origin/HEAD` resolves to main — so the
    # printed command would hand the reviewer MAIN's content under the PR's name, and a `CLEAN` verdict
    # from it would be recorded with no error at all. Accept only something that is a branch: never
    # empty, never HEAD, never spaced.
    # ⛔ AND THE CHECKOUT IS RESOLVED, NEVER INHERITED (landing-review F1, P1): `_rp` is the tree the
    # chain would actually run from, or empty when the resolver refuses (see chain_cmd above).
    _rp="$(resolve_trusted_checkout "${REPO_PATH:-$(pwd)}" 2>/dev/null)" || _rp=""
    _br="$RESOLVED_BR"
    [ -n "$_br" ] || _br="<branch>"
    # ⛔ THE NEXT STEP MUST BE TRUE FOR THIS TOKEN *AND* EXECUTABLE AS WRITTEN (reviewer finding, R10):
    # it rendered literal `<repo>`/`<branch>` placeholders and an unexpanded `"$O"`, showed three
    # positionals to a FOUR-argument tool (filled in, that reads as REPO=owner/repo, OR=<pr>, PR=branch
    # and is refused), and told a CLOSED PR's next holder to launch a chain — which has no closed-PR
    # guard, so it would pay for a reviewer it could never merge. For the ROUND CAP it said "re-run the
    # supervision chunk" about a blocker that is a fix duty the chunk cannot clear.
    case "$tok" in
      BLOCKED_ATTESTATION)
        printf 'The ONE thing this lane cannot supply: a signed review attestation is minted by\n'
        printf '`merge-one.sh` from a FRESH-CONTEXT reviewer, never by the lane itself.\n'
        if [ -n "$_rp" ]; then chain_cmd "$_rp" "$_br" "" "."
        else merge_authority_unresolved_note; fi
        [ "$_br" = "<branch>" ] && printf '(pass --branch: this checkout is not on a branch.)\n' ;;
      BLOCKED_CLOSED)
        printf 'This PR is CLOSED and was not merged. A chain cannot fix that, so do NOT launch one\n'
        printf '— reopen the PR if the change is still wanted, or open a new one from the branch.\n' ;;
      BLOCKED_ATTEMPTS)
        case "${HANDOFF_NEXT:-}" in
          cap)     printf 'Next: fix the failure named above and push. The round cap is not a supervision\n'
                   printf 'budget — re-running the chunk reaches the same cap on its first fix.\n' ;;
          running) printf 'Next: the chain was STILL RUNNING — wait for the pid above, or once it exits\n'
                   printf 'run `%s/lane-merge.sh %s --repo %s` (no --watch: the budget is spent).\n' "$O" "$PR" "$OR" ;;
          absent)  if [ -n "$_rp" ]; then chain_cmd "$_rp" "$_br" "launch the chain — " "."
                   else merge_authority_unresolved_note; fi
                   [ "$_br" = "<branch>" ] && printf '(pass --branch: this checkout is not on a branch.)\n' ;;
          # ⛔ NOT `--watch` (reviewer finding, P1, R11, measured: RC=13, same token, 0.455s, zero
          # supervision — the budget is what refused it, so chunk N+1 is charged before any work and
          # re-hands-off). A PLAIN run re-reads the PR and the checks, and its fix path re-arms the budget.
          *)       printf 'Next: `%s/lane-merge.sh %s --repo %s` — NOT --watch: the budget is what\n' "$O" "$PR" "$OR"
                   printf 'refused you, so another watch chunk is charged before it does any work.\n' ;;
        esac ;;
      *)
        if [ -n "$_rp" ]; then chain_cmd "$_rp" "$_br" "" " (reviews, records, merges)."
        else merge_authority_unresolved_note; fi
        [ "$_br" = "<branch>" ] && printf '(pass --branch: this checkout is not on a branch.)\n' ;;
    esac
    case "$tok" in
      BLOCKED_CLOSED)
        printf '\n_This PR is closed; re-running lane-merge.sh %s reports the same thing._\n' "$PR" ;;
      *)
        printf '\n_Re-run with `%s/lane-merge.sh %s --repo %s` after a fix; a new head re-arms the PR._\n' "$O" "$PR" "$OR" ;;
    esac
  } > "$body"
  if gh api -X POST "repos/$OR/issues/$PR/comments" -F "body=@$body" >/dev/null 2>&1; then
    log_line "lane-merge: handoff comment posted on PR #$PR (the next holder inherits a diagnosis)"
  else
    say_err "lane-merge: ⚠️ could not post the handoff comment (rate limit or auth) — the reason is in"
    say_err "            $VERDICT_F and must be relayed in the lane's final message"
  fi
  rm -f "$body"
}

emit_fix() { # emit_fix <TOKEN> <reason…>
  local tok="$1"; shift
  local r; r="$(round_of)"; r=$((r + 1)); printf '%s\n' "$r" > "$ROUND_F"
  # A new fix round is a NEW cycle: the supervision budget spent on the old head must not be inherited,
  # or a re-armed run is refused from its first chunk (E1 — the stale-counter class AGENTS.md names).
  : > "$WATCH_F" 2>/dev/null || true
  # …and the head-moved counter with it: it bounds "THIS chain outlived two passes", not the PR number.
  # A cumulative counter meant a head-move in one cycle plus one in a later cycle blocked on the FIRST
  # pass for ever, permanently removing the re-runnable path from the PR (reviewer finding, P2).
  rm -f "$O/state/lanemerge-$PR.headmoved" "$O/state/lanemerge-$PR.apiretry" \
        "$O/state/lanemerge-$PR.lastdisp" 2>/dev/null || true
  if [ "$r" -gt "$MAX_ROUNDS" ]; then
    # The cap REFUSES the next round rather than granting it: this is the bound the owner asked for.
    # ⛔ THE VERDICT MUST SAY *WHY* IT STOPPED. Recording the fix token here would leave
    # FIX_REQUIRED as the authoritative verdict on a lane that is handing off — chain-merge would
    # then treat it as "still working" and merge-rate.sh would count a capped lane as a live fixer.
    # ⛔ THE BODY AND THE COUNTER MUST AGREE (reviewer finding, P2, measured): the increment above
    # happened BEFORE the cap test, so the body said "round cap reached (3/3)" while the same comment's
    # "Rounds spent: 4/3" line rendered the unclamped count. The REFUSED round stays recorded — that is
    # what the lane spent — but the comment renders the GRANTED count (clamped at the cap).
    HANDOFF_NEXT=cap post_handoff BLOCKED_ATTEMPTS "round cap reached (${MAX_ROUNDS}/${MAX_ROUNDS}): $*"
    verdict BLOCKED_ATTEMPTS "round cap ${MAX_ROUNDS} reached: $*"
    log_line "⛔ BLOCKED_ATTEMPTS — round cap ${MAX_ROUNDS} reached. $*"
    log_line "   Hand off. The exact reason is on PR #$PR as a comment."
    exit 13
  fi
  verdict "$tok" "$*"
  log_line "→ $tok (round ${r}/${MAX_ROUNDS}): $*"
  case "$tok" in
    FIX_CONFLICT) exit 15 ;;
    *)            exit 10 ;;
  esac
}

# review_record_at_head — is there a SIGNED review record for the CURRENT head? Reads the same store
# record-review.sh writes; no API call. A record bound to a DIFFERENT head does NOT count: that is
# the stranded-attestation condition, not coverage.
review_record_at_head() {
  local n slug f sha
  n="$PR"; slug="$(printf '%s' "$OR" | tr '/' '-')"
  for f in "$HOME/.pi/agent/reviews/$slug-$n.json" "$HOME/.pi/agent/reviews/$n.json"; do
    [ -f "$f" ] || continue
    sha="$(grep -o '"head_sha"[[:space:]]*:[[:space:]]*"[0-9a-fA-F]*"' "$f" 2>/dev/null \
            | head -1 | grep -o '[0-9a-fA-F]\{7,\}')"
    if [ -n "${sha:-}" ] && [ -n "${HEAD:-}" ]; then
      case "$HEAD" in "$sha"*) return 0 ;; esac
    fi
  done
  return 1
}

emit_attestation() { # emit_attestation <reason…>
  verdict BLOCKED_ATTESTATION "$*"
  post_handoff BLOCKED_ATTESTATION "$*"
  log_line "⛔ BLOCKED_ATTESTATION — $*"
  exit 12
}

emit_blocked() { # emit_blocked <TOKEN> <reason…>
  local tok="$1"; shift
  verdict "$tok" "$*"
  post_handoff "$tok" "$*"
  log_line "⛔ $tok — $*"
  exit 14
}

# ── --watch: bounded chunks on LOCAL state; only the PR read costs an API call ───────────────────
if [ "$WATCH" -eq 1 ]; then
  # ⛔ HEAD IS SEEDED FROM THE LAST HEAD THIS LANE SAW, BEFORE ANY EXIT PATH (F4). The budget check
  # below posts a handoff WITHOUT reading the PR, so with HEAD unset the marker degenerated to the
  # constant `unknown` — collapsing per-head dedup back to per-PR and suppressing a later handoff at
  # a new head (the exact bug an earlier round fixed for the in-loop path only). A failed read in a
  # later chunk is the same story, so the seed covers both.
  HEAD="$(cat "$O/state/lanemerge-$PR.head" 2>/dev/null || true)"
  w="$(cat "$WATCH_F" 2>/dev/null || echo 0)"; is_limit "$w" || w=0
  w=$(( w + 1 )); printf '%s\n' "$w" > "$WATCH_F"
  deadline=$(( $(date +%s) + POLL_S ))
  # ⛔ ONE PR READ PER CHUNK, NOT PER TICK (A7). The header promises "reads the PR ONCE per
  # invocation … waits on LOCAL state files while the chain runs"; at INTERVAL=20 a per-tick read was
  # ~6/min per lane, across 22 landers, on one rate-limited account. Tick 0 reads, the rest poll
  # local state (pid, log, markers); a later chunk re-reads.
  _tick=0
  while :; do
    if [ "$_tick" -eq 0 ]; then
      # ⛔ ONLY ON A GOOD READ. An empty read_up (rate-limited / failed pr_read) would blank ALL
      # four fields, so HEAD falls back to "" and the handoff marker degenerates to the constant
      # `unknown` — collapsing per-head dedup back to per-PR, the bug this file fixed once — and the
      # closed/head-moved checks would be skipped for the whole chunk.
      read_up="$(pr_read 2>/dev/null)"
      if [ -n "${read_up:-}" ]; then
        IFS='|' read -r ST MT HD MS <<< "$read_up"
        # PERSIST the head: a LATER chunk that cannot reach the API would otherwise post a marker
        # keyed `unknown`, collapsing per-head dedup back to per-PR (F4 — the state file is what makes
        # the guard observable instead of a claim).
        [ -n "${HD:-}" ] && printf '%s\n' "$HD" > "$O/state/lanemerge-$PR.head" 2>/dev/null
      fi
    fi
    _tick=$(( _tick + 1 ))
    # HEAD IS SET HERE TOO. post_handoff builds a HEAD-BOUND marker; with HEAD unset the marker
    # degenerated to the constant "unknown", so the per-head dedup became per-PR and every later
    # handoff at a NEW head was silently suppressed (reviewer finding, reproduced). A failed read
    # falls back to the last head this lane actually saw (persisted above) — never to "unknown".
    HEAD="${HD:-$(cat "$O/state/lanemerge-$PR.head" 2>/dev/null || true)}"
    # ⛔ IS WHAT THE READ PARSED TO USABLE AT ALL? (reviewer finding, P2, REPRODUCED) `read_up` being
    # NON-EMPTY is not the same as a usable read: a rate-limited or truncated response is `open|||behind`
    # — the shape this file records at its plain-path guard below — non-empty, with an EMPTY state and
    # head. Gating on the read being non-empty let that reach a JUDGEMENT. Measured on the shipped
    # script with a dead chain and an inconclusive merge log: it ATTESTS (exit 12, posting "green and
    # mergeable … head ?" as a PUBLIC PR comment on a PR that may simply need a fix), and
    # `closed|||behind` reports "closed and was NOT merged" (exit 14) — both claims about fields nothing
    # populated. So the test is on what was PARSED: a state AND a head, the same pair the plain path
    # refuses at exit 2.
    # ⛔ IT IS A FLAG, NOT AN EARLY EXIT (reviewer finding, P1, measured). Exiting here pre-empted three
    # things that are NOT judgements and that must keep working when a read fails: a LIVE chain still
    # WAITS (WAITING_CHAIN_RUNNING, which spreads the chunk budget over the lane's wall clock instead of
    # letting MAX_WATCH failed reads burn it inside one rate-limit window), a missing chain record still
    # says the actionable thing (WAITING_CHAIN_ABSENT), and the head-moved check is untouched (it needs
    # HD, so it skips itself). Only the two judgement sites consume the flag: the `closed` arm below and
    # the attestation path in the `! chain_alive` block.
    if [ -z "${read_up:-}" ] || [ -z "${ST:-}" ] || [ -z "${HD:-}" ]; then _readable=0; else _readable=1; fi
    # ⛔ THE BUDGET CHECK RUNS HERE, NOT AT THE TOP OF THE CHUNK (reviewer finding, P2, measured): the
    # hand-off it posts is HEAD-BOUND, and at the top of the chunk HEAD is not yet read — so the marker
    # carried the literal "unknown", collapsing per-head dedup back to per-PR: the exact defect F4 fixed
    # for the review path, still open on the budget path. By now HEAD is known (or the persisted one).
  # ⛔ A MERGED PR OUTRANKS A SPENT BUDGET (landing-review P1, MEASURED). The budget block below runs
  # before this tick's PR state is acted on, so on the first tick past the cap a PR that this same tick
  # had just read as closed+merged was reported BLOCKED_ATTEMPTS (exit 13): the MERGED verdict was never
  # written, a hand-off comment was posted on an already-merged PR ("the merge chain has not resolved
  # this PR" — false), and chain-merge.sh, which breaks its wait on BLOCKED_ATTEMPTS, then ran a PAID
  # merge-one.sh review on a merged PR instead of taking its MERGED early exit. The read this needs
  # already happened at the top of the tick (ST/MT/HD), so it is answered before the budget decides
  # anything. The plain (non---watch) path already had this order; only the supervised path inverted it.
  if [ "${ST:-}" = closed ] && [ -n "${MT:-}" ]; then
    verdict MERGED "$(merged_confirmed 2>/dev/null || printf '%s' "${MT:-${HD:-}}")"
    log_line "✅ MERGED — PR #$PR at head ${HD:-}"; exit 0
  fi
  if [ "$w" -gt "$MAX_WATCH" ]; then
    # ⛔ A CHUNK THAT ESTABLISHED NOTHING MUST NOT BE REPORTED AS "UNRESOLVED" (reviewer finding, P2,
    # verified). `WAITING_API` returns in seconds and explicitly refuses to judge the PR, so a run of
    # them could burn the whole budget and then post "the merge chain has not resolved this PR" — a
    # false statement about a state we declined to decide, handed off as "stop". The last disposition
    # is persisted beside the counter, and it changes what the hand-off SAYS.
    _lastd="$(cat "$O/state/lanemerge-$PR.lastdisp" 2>/dev/null || true)"
    rm -f "$O/state/lanemerge-$PR.lastdisp" 2>/dev/null || true   # it described the LAST chunk only
    case "${_lastd:-}" in
      WAITING_API*)
        post_handoff BLOCKED_ATTEMPTS "supervision budget spent (${MAX_WATCH} --watch chunks) and the LAST chunk could not READ the merge confirmation, so this verdict says nothing about the PR: it may well be merged. Re-run when gh answers, or check the PR directly — do not fix code on this"
        verdict BLOCKED_ATTEMPTS "budget spent; the last chunk's merge confirmation was UNREADABLE — the PR may be merged; re-run when the API answers" ;;
      WAITING_LOAD*)
        post_handoff BLOCKED_ATTEMPTS "supervision budget spent (${MAX_WATCH} --watch chunks), but the LAST chunk was refused by the LOAD GATE — this is not a lane failure: re-dispatch when the box quietens"
        verdict BLOCKED_ATTEMPTS "budget spent; the last chunk was refused by the load gate (not a lane failure)" ;;
      WAITING_NO_BRANCH*)
        post_handoff BLOCKED_ATTEMPTS "supervision budget spent (${MAX_WATCH} --watch chunks) and no BRANCH could be resolved — pass --branch; a chain launched without one reviews the wrong tree"
        verdict BLOCKED_ATTEMPTS "budget spent; no branch could be resolved (pass --branch)" ;;
      WAITING_CHAIN_RUNNING*)
        HANDOFF_NEXT=running post_handoff BLOCKED_ATTEMPTS "supervision budget spent (${MAX_WATCH} --watch chunks) while the chain was STILL RUNNING (pid $(chain_pid)) — it may still merge; wait for that pid before re-running"
        verdict BLOCKED_ATTEMPTS "budget spent; the chain was still running (may still merge — check pid $(chain_pid))" ;;
      WAITING_CHAIN_ABSENT*)
        HANDOFF_NEXT=absent post_handoff BLOCKED_ATTEMPTS "supervision budget spent (${MAX_WATCH} --watch chunks) with NO chain recorded for this PR — every chunk had nothing to supervise; launch the chain"
        verdict BLOCKED_ATTEMPTS "budget spent; no merge chain was ever recorded for this PR" ;;
      WAITING_NO_VERDICT*)
        post_handoff BLOCKED_ATTEMPTS "supervision budget spent (${MAX_WATCH} --watch chunks) and the LAST chunk found NO reviewer verdict — there is no review comment to read and nothing to fix: re-run the chain"
        verdict BLOCKED_ATTEMPTS "budget spent; the last chunk found no reviewer verdict (nothing to fix)" ;;
      WAITING_CHECKS*)
        post_handoff BLOCKED_ATTEMPTS "supervision budget spent (${MAX_WATCH} --watch chunks) with the checks still IN FLIGHT at the last look — the head never settled; re-run when CI finishes"
        verdict BLOCKED_ATTEMPTS "budget spent; the last chunk still had checks in flight" ;;
      WAITING_CLASSIFIER*)
        post_handoff BLOCKED_ATTEMPTS "supervision budget spent (${MAX_WATCH} --watch chunks) and the last chunk could not CLASSIFY the head's check-runs (python3 missing?) — nothing about the PR was decided"
        verdict BLOCKED_ATTEMPTS "budget spent; the last chunk could not classify the check-runs" ;;
      WAITING_HEAD_MOVED*)
        # ⛔ NO ESCAPED SUBSTITUTION IN A HAND-OFF BODY (reviewer finding, P2, measured): a `\$(chain_pid)`
# shipped the literal placeholder to the PR, so the arm that exists to NAME the chain handed over
# "check pid $(chain_pid)". The sibling block path below already renders it.
        post_handoff BLOCKED_ATTEMPTS "supervision budget spent (${MAX_WATCH} --watch chunks) while the chain stayed bound to an older head — check pid $(chain_pid) before re-running"
        verdict BLOCKED_ATTEMPTS "budget spent; the chain stayed bound to an older head" ;;
      *)
        post_handoff BLOCKED_ATTEMPTS "supervision budget spent (${MAX_WATCH} --watch chunks): the merge chain has not resolved this PR"
        verdict BLOCKED_ATTEMPTS "supervision budget spent (${MAX_WATCH} chunks)" ;;
    esac
    log_line "⛔ BLOCKED_ATTEMPTS — ${MAX_WATCH} --watch chunks spent and the chain is still unresolved."
    exit 13
  fi
    # ⛔ A READ THAT PARSED TO NOTHING IS NOT "CLOSED AND NOT MERGED" (reviewer finding, P2, REPRODUCED).
    # `closed|||<x>` is a TRUNCATED read, not a closed PR: with `_readable=0` this arm does nothing and the
    # wait below answers instead — WAITING_API when the chain is dead, WAITING_CHAIN_RUNNING while one is
    # still alive. A genuinely closed-unmerged PR carries its head, so `closed||<sha>|clean` still reaches
    # BLOCKED_CLOSED.
    case "${ST:-}" in
      closed) if [ "$_readable" = 0 ]; then :
              elif [ -n "${MT:-}" ]; then
                # MT is `merged_at` off THIS repo's PR read (pr_read), so it is a confirmation, not a
                # hint. ⛔ THE PAYLOAD MUST BE THE MERGE COMMIT HERE TOO (reviewer finding, P2): the
                # other MERGED writers record `merge_commit_sha`, and the brief tells the lane to read
                # this record back as "the merge sha" — a path-dependent payload makes that a trap. MT
                # is the fallback when the follow-up read cannot answer.
                verdict MERGED "$(merged_confirmed 2>/dev/null || printf '%s' "${MT:-${HD:-}}")"
                log_line "✅ MERGED — PR #$PR at head ${HD:-}"; exit 0
              else
                emit_blocked BLOCKED_CLOSED "PR #$PR is closed and was not merged by this chain"
              fi ;;
    esac
    # ⛔ A LIVE PID IS NOT PROOF THAT THE CHAIN IS SUPERVISING *THIS* HEAD. A lane that pushed a fix
    # after launching leaves a chain working the old head; its eventual "MERGED"/"BLOCKED" would then
    # ⛔ NOTHING TO SUPERVISE IS NOT A HAND-OFF (reviewer finding, P2, measured). With no chain record
    # and no claim lock, this chunk has nothing to observe: it used to fall through to the no-review
    # path and POST "no signed review record exists … and the chain did not merge" with rc=12 — a
    # hand-off about a chain that was never launched, reachable because WAITING and WAITING_CHECKS share
    # exit 11 and the brief maps 11 → "call --watch". Say what is true and say nothing on the PR.
    if ! chain_alive && [ ! -s "$CHAIN_F" ] && [ ! -f "$O/state/mergeclaim-$PR.lock" ]; then
      log_line "⚠️ there is NO chain record for PR #$PR and no claim lock — nothing is being supervised."
      log_line "   Launch one: lane-merge.sh $PR --issue ${ISSUE:-<n>} --repo $OR"
      disposition WAITING_CHAIN_ABSENT
      verdict WAITING_CHAIN_ABSENT "no merge chain is recorded or owned for this PR; launch one (nothing was decided)"
      exit 11
    fi
    # be read against the new one. The head the chain was launched for is recorded in CHAIN_F.
    if chain_alive && [ -n "$(chain_head)" ] && [ -n "${HD:-}" ] && [ "$(chain_head)" != "$HD" ]; then
      # ⛔ HEAD-MOVED IS RE-RUNNABLE, NOT UNFALSIFIABLE (reviewer finding, P2, verified). Re-arming on
      # every pass meant a chain that never died left the lane cycling WAITING_HEAD_MOVED until its 3300s
      # wall clock ran out — a wait with no terminal state. One re-run is honest (the chain usually
      # finishes the old head); a SECOND is a stuck chain, and that is a hand-off with a name.
      _hm=$(( $(cat "$O/state/lanemerge-$PR.headmoved" 2>/dev/null || echo 0) + 1 ))
      printf '%s\n' "$_hm" > "$O/state/lanemerge-$PR.headmoved" 2>/dev/null || true
      log_line "… the PR head moved past the chain's head ($(chain_head) → ${HD}) — the chain is working"
      log_line "   a head that is no longer the tip (pass $_hm of 2)."
      if [ "$_hm" -ge 2 ]; then
        emit_blocked BLOCKED "the merge chain (pid $(chain_pid)) is still bound to head $(chain_head) after 2 passes while the PR is at ${HD} — wait for it to exit, or kill pid $(chain_pid) and re-run"
      fi
      : > "$WATCH_F" 2>/dev/null || true
      disposition WAITING_HEAD_MOVED
      verdict WAITING_HEAD_MOVED "the supervision chain is bound to an older head"
      exit 11
    fi
    if ! chain_alive; then
      # ⛔ AN UNCLASSIFIABLE READ IS A WAIT, NOT A JUDGEMENT (reviewer finding, P2, verified). Reaching
      # here means the chain is dead AND the read gave us nothing usable. With an inconclusive merge log,
      # `chain_verdict_from_log` returns UNKNOWN and the `*)` arm ATTESTS: "green and mergeable, but no
      # signed review record exists for head ${HEAD:-?} …" — facts asserted about a PR nothing was read
      # for, posted as a public PR comment, exit 12 ("stop fixing and hand off") on a PR that may be
      # perfectly mergeable. WAITING_API (exit 11) is the disposition that exists for exactly this:
      # nothing is classified, nothing is posted. The chunk is CHARGED (not refunded) on purpose, so a
      # permanently unreadable API converges on the budget hand-off that already says the truth — "the
      # last chunk could not read the merge confirmation, so this verdict says nothing about the PR: it
      # may well be merged" — instead of manufacturing a review verdict.
      if [ "$_readable" = 0 ]; then
        # ⛔ THE MESSAGE BRANCH MUST NOT REUSE THE GUARD'S EXACT TEST (reviewer finding, P2): suite §19
        # asserts the good-read guard at the top of the tick STRUCTURALLY, by grepping for its literal
        # expression — so repeating that expression here made the assertion match a message branch and
        # pass even if the guard it names were deleted. `read_up` is assigned unconditionally at the top
        # of this tick, so the plain `-n "$read_up"` form is set -u safe and leaves ONE grep site.
        if [ -n "$read_up" ]; then
          log_line "… the PR read came back INCOMPLETE this chunk (state '${ST:-}' head '${HD:-}' from '${read_up}')"
          log_line "   — a truncated or partial response is not a fact about the PR, so nothing is decided:"
        else
          log_line "… the PR could not be READ this chunk (rate limit / auth / DNS) — nothing about it is decided:"
        fi
        log_line "   no attestation, no hand-off comment, no fix round. Re-run when gh answers."
        disposition WAITING_API
        verdict WAITING_API "the PR read failed this chunk; no judgement about the PR was made"
        exit 11
      fi
      cv="$(chain_verdict_from_log "$(chain_log)" "${HD:-}")"
      case "$cv" in
        MERGED)
          # The classifier already confirmed with one API read; the payload is the merge commit.
          msha="$(merged_confirmed 2>/dev/null)"
          verdict MERGED "${msha:-${HD:-}}"
          log_line "✅ MERGED — PR #$PR, merge commit ${msha:-?} (was head ${HD:-?})"; exit 0 ;;
        API_UNREADABLE)
          # The evidence we need could not be read. That is a WAIT, not a verdict: no comment, no round,
          # and the next invocation asks again (the counter is untouched).
          # ⛔ REFUND THE CHUNK: this pass established nothing about the PR, so charging the budget for
          # it is how ~15 rapid re-runs against a merged-but-unreadable PR used to reach
          # BLOCKED_ATTEMPTS (reviewer finding, P2, verified). The disposition is persisted so the
          # exhausted-budget hand-off can say the truth (see above).
          # ⛔ THE REFUND IS CAPPED (reviewer finding, P2, measured): an unbounded refund meant 20
          # consecutive passes with a dead chain, a MERGED log and a failing read all refunded — the
          # counter pinned at 0, exit 11 for ever, BLOCKED_ATTEMPTS unreachable, and the "MAY BE MERGED"
          # hand-off could only ever fire with a FALSE "the LAST chunk could not read" (a chunk that
          # refunds can never be the one that crosses the budget). So: at most MAX_WATCH refunds per
          # cycle; past that, the chunk is CHARGED and the honest hand-off becomes reachable.
          _ar="$O/state/lanemerge-$PR.apiretry"
          _n_ar="$(cat "$_ar" 2>/dev/null || echo 0)"; is_limit "$_n_ar" || _n_ar=0
          if [ "$_n_ar" -lt "$MAX_WATCH" ]; then
            _n_ar=$(( _n_ar + 1 )); printf '%s\n' "$_n_ar" > "$_ar" 2>/dev/null || true
            w="$(cat "$WATCH_F" 2>/dev/null || echo 0)"; is_limit "$w" || w=0
            [ "$w" -gt 0 ] && printf '%s\n' "$(( w - 1 ))" > "$WATCH_F" 2>/dev/null
            log_line "… the API could not be read (retry $_n_ar/$MAX_WATCH this cycle) — no round and no chunk is spent"
          else
            log_line "… the API STILL cannot be read after $MAX_WATCH retries this cycle — the chunk is charged"
          fi
          disposition WAITING_API
          log_line "… the API could not be read while confirming the merge — re-run the loop (no round and no chunk is spent)"
          verdict WAITING_API "the merge confirmation read failed; not a statement about the PR"
          exit 11 ;;
        UNCONFIRMED_MERGE)
          # ⛔ A MERGE CLAIM NOBODY CAN CONFIRM IS THE WORST OUTCOME HERE (reviewer finding, P0): the
          # log names a merge, the API says this PR is not merged. That is not "merged" and it is not
          # "the reviewer found issues" — it is the one thing a lane must NAME and hand off.
          emit_blocked BLOCKED "the merge log claims MERGED but repos/$OR/pulls/$PR reports no merged_at — the log may belong to another repo's PR #$PR (log: $(chain_log))" ;;
        FIX_REQUIRED)
          # The reviewer's findings ARE the fix list; the PR comment carries them in full.
          emit_fix FIX_REQUIRED "the fresh-context reviewer recorded ISSUES at head ${HD:-} — read the review comment on PR #$PR and fix every finding" ;;
        REVIEW_NO_VERDICT)
          # ⛔ NO COMMENT TO POINT AT (reviewer finding, P2, measured): the reviewer hit its cap or its
          # tool failed, so there IS no review comment — telling the lane to read one is a hand-off to
          # nowhere, and charging it a fix round spends the lane's budget on nothing. It is re-runnable
          # like the load gate, and it is bounded by the watch counter (it does NOT refund).
          log_line "… the reviewer produced NO verdict at head ${HD:-} (cap hit or tool failure) — there is no"
          log_line "   review comment to read; re-run the chain: lane-merge.sh $PR --issue ${ISSUE:-<n>} --repo $OR"
          disposition WAITING_NO_VERDICT
          verdict WAITING_NO_VERDICT "the reviewer produced no verdict (no comment to read); re-run the chain"
          exit 11 ;;
        LOAD) log_line "… the reviewer was refused by the load gate; this is not a lane failure — re-run:"
                 log_line "   lane-merge.sh $PR --issue ${ISSUE:-<n>} --repo $OR"
                 disposition WAITING_LOAD
                 verdict WAITING_LOAD "reviewer refused by the load gate; re-dispatch when the box quietens"
                 exit 11 ;;
        BLOCKED) _why="$(tail -n 3 "$O/state/parkreason-$PR" 2>/dev/null | tr '\n' ' ')"
                 # ⛔ AN EMPTY REASON IS A BLOCKED HANDOFF WITH NOTHING TO HAND OFF (reviewer finding,
                 # P2, verified): parkreason-<PR> may have been rewritten by another cycle, leaving the
                 # next holder "⛔ BLOCKED" with no cause. Fall back to the chain log's last line.
                 [ -n "${_why// /}" ] || _why="$(tail -n 1 "$(chain_log)" 2>/dev/null)"
                 [ -n "${_why// /}" ] || _why="the chain parked this head and left no reason"
                 emit_blocked BLOCKED "the merge chain parked this head: $_why" ;;
        *)       # ⛔ THE ONE THING A LANE CANNOT SUPPLY HAS ITS OWN CODE (12): a green, mergeable PR
                 # with no signed review at this head is not the generic "blocked" — the next holder
                 # needs to know the ONLY missing step is the fresh-context review, which the lane
                 # may not mint for itself (that would be a review that did not happen).
                 if ! review_record_at_head; then
                   emit_attestation "green and mergeable, but no signed review record exists for head ${HEAD:-?} and the chain did not merge; a lane cannot mint one for itself"
                 fi
                 log_line "… the chain exited without merging and its log names no cause — see $(chain_log)"
                 emit_blocked BLOCKED "the merge chain exited without a merge or a named cause (log: $(chain_log))" ;;
      esac
    fi
    now="$(date +%s)"
    [ "$now" -ge "$deadline" ] && { disposition WAITING_CHAIN_RUNNING; log_line "… WAITING — the chain is still running (pid $(chain_pid)); call --watch again"; exit 11; }
    sleep "$INTERVAL"
  done
fi

# ── ONE ROUND ────────────────────────────────────────────────────────────────────────────────────
read_up="$(pr_read)"; IFS='|' read -r ST MT HD MS <<< "${read_up:-}"
if [ -z "${ST:-}" ]; then
  say_err "lane-merge: could not read PR #$PR in $OR (rate limit, auth, or wrong --repo)."
  say_err "            Nothing was attempted. Re-run when gh answers; do NOT hand-roll a merge."
  exit 2
fi
# ⛔ A HEAD IS NOT OPTIONAL (measured: a rate-limited read returned `open|||behind`, and the loop then
# polled `commits//check-runs` — which GitHub resolves against the DEFAULT BRANCH. So the loop
# classified MAIN's checks as this PR's, and a lane could have been told its own PR was green on the
# strength of a branch it never touched. An empty field must never reach an API URL; the one write
# that could follow (launching the merge chain) makes that a false PASS, not a cosmetic bug.
if [ -z "${HD:-}" ]; then
  say_err "lane-merge: read PR #$PR but its HEAD SHA is EMPTY (partial/truncated API response)."
  say_err "            Refusing to poll a blank head — GitHub would resolve it to the DEFAULT BRANCH,"
  say_err "            so any verdict would be about a branch this lane never touched. Nothing attempted."
  exit 2
fi
HEAD="${HD:-}"
case "$ST" in
  closed)
    if [ -n "${MT:-}" ]; then
      # ⛔ THE PAYLOAD IS THE MERGE COMMIT, NOT THE HEAD (landing-review P2). Every other MERGED writer
      # records `merge_commit_sha` (the two --watch arms, and the detached wrapper from merge-one's own
      # marker), and the brief tells the lane to read this record back AS THE MERGE SHA — so recording
      # $HEAD here reported a commit that is not on main. That is the plain-run path a lane hits when it
      # re-runs after the chain already merged, i.e. the common post-change case. Same fallback order as
      # the watch arm: merge_commit_sha, then merged_at, then the head only if neither could be read.
      verdict MERGED "$(merged_confirmed 2>/dev/null || printf '%s' "${MT:-$HEAD}")"
      log_line "✅ MERGED — PR #$PR at head $HEAD"; exit 0
    fi
    emit_blocked BLOCKED_CLOSED "PR #$PR is closed and was NOT merged" ;;
esac
case "${MS:-}" in
  dirty)
    emit_fix FIX_CONFLICT "the PR is DIRTY (conflicts with main): re-apply THIS lane's own change onto current origin/main and force-push THIS branch. Never resolve a GENERATED file's conflict by picking a side — regenerate it." ;;
esac

# NO PRE-CHECK AT THE CAP (reviewer finding, reproduced). A pre-check that refused BEFORE reading the
# checks could never verify the LAST allowed fix: round 3 is spent (emit_fix grants it), the lane
# pushes that fix, and the next invocation exited 13 having measured nothing — reporting "the cap is
# spent" and quoting STALE failing names from round 2's head. The cap belongs where it is SPENT, in
# emit_fix, which sees the CURRENT reds: a green head after round 3 proceeds to the chain (that is
# convergence, not a violation), and a red one blocks with names read at THIS head.

# Wait for THIS head's checks to be terminal, bounded, printing progress so the lane never looks
# wedged and so a human reading the transcript can see it is making progress and not hung.
CHECK_TMP="$(mktemp "${TMPDIR:-/tmp}/lane-merge-checks.XXXXXX")" || exit 2
trap 'rm -f "$CHECK_TMP"' EXIT
deadline=$(( $(date +%s) + WAIT_S ))
while :; do
  rows="$(checks_read "$HEAD")"
  # The single-page read carries a TOTAL line so "this page is all of it" is distinguishable from
  # "there is more". Only then pay for the full paginated read (the rare case), and never let the
  # TOTAL line itself reach the classifier — a head with 0 check-runs would otherwise classify as
  # GREEN with an empty red set, which is the "nothing measured is not green" rule this loop holds.
  # NF==2 on the marker as well as the name: a CHECK-RUN may legitimately be named "TOTAL", and it
  # would arrive with 5 fields — matching it here would read a status string as a count.
  total="$(printf '%s\n' "${rows:-}" | awk -F'\t' '$1=="TOTAL" && NF==2 {print $2; exit}')"
  rows="$(printf '%s\n' "${rows:-}" | awk -F'\t' 'NF>=4')"
  if [ -n "${total:-}" ] && [ "$total" -gt 100 ] 2>/dev/null; then
    rows="$(checks_read "$HEAD" --full)"
  fi
  if [ -z "${rows:-}" ]; then
    # An EMPTY check-run set is not a green set: nothing has been measured. Keep polling (this is
    # the "a queued run is not a green run" rule at its surface), and the bound below reports it.
    log_line "… no check-runs reported for head ${HEAD:0:12} yet — a queued run is not a green run"
    IF=1; RED=""
  else
    printf '%s\n' "$rows" > "$CHECK_TMP"
    classified="$(classify "$CHECK_TMP")"
    # ⛔ FAIL CLOSED ON AN UNREADABLE CLASSIFICATION. A missing/broken python3 yields EMPTY output,
    # which would read as "no red, no inflight" — i.e. GREEN — and launch a merge on a head nobody
    # classified. The classifier's own contract is two lines; anything else is "I cannot judge".
    # BOTH LINES, NOT JUST THE FIRST: a truncated classification (INFLIGHT present, RED missing — a
    # crash between the two prints, a broken pipe, a future edit) left RED empty and read as GREEN,
    # launching a merge on a head whose red was never reported (reviewer finding). Fail closed.
    if ! grep -q '^INFLIGHT ' <<<"$classified" || ! grep -q '^RED ' <<<"$classified"; then
      say_err "lane-merge: the check-run classifier produced no verdict (python3 missing or its"
      say_err "            output was not understood) — refusing to call this head green."
      disposition WAITING_CLASSIFIER
      verdict WAITING_CLASSIFIER "could not classify this head's check-runs"
      exit 2
    fi
    IF="$(printf '%s' "$classified" | awk '/^INFLIGHT /{print $2}')"
    RED="$(printf '%s' "$classified" | awk '/^RED /{sub(/^RED /,""); print}')"
  fi
  [ -n "$RED" ] && { printf '%s\n' "$(printf '%s' "$RED" | tr ',' '\n')" > "$LAST_F"
                     printf '%s\n' "${HD:-${HEAD:-}}" > "$LASTHEAD_F" 2>/dev/null || true; }
  if [ -n "${RED:-}" ]; then
    # ── A FLAKE IS NOT A FIX (#2866) ──────────────────────────────────────────────────────────
    # Before this round spends a FIX on the red, ask the router whether the red is a red at all.
    # `RERUN-FLAKE` = the same (app, workflow, job) PASSED on an earlier attempt at THIS SAME head:
    # editing code here produces a new head for a flake, strands the head-bound review attestation
    # and buys a full CI pass. The re-run re-executes the SAME sha (a re-run keeps GITHUB_SHA), so
    # it costs one job and no review.
    # ⛔ `unavailable` (no router on this box) changes NOTHING: the lane fixes the red as before and
    # says the router did not run. An unresolved router must never read as "no flake here".
    if [ -z "${lrow:-}" ] && declare -f prstate_row >/dev/null 2>&1; then
      lrow="$(prstate_row "$OR" "$PR")" || lrow="$(printf '%s' "${lrow:-unavailable\t-\tno row}")"
      lsick_action="$(printf '%s' "${lrow:-}" | cut -f1)"
      lsick_run="$(printf '%s' "${lrow:-}" | cut -f2)"
      lsick_why="$(printf '%s' "${lrow:-}" | cut -f3-)"
      case "$lsick_action" in
        RERUN-FLAKE)
          log_line "… this head's red is a FLAKE, not a fix: ${lsick_why:-a job passed at this same head}"
          log_line "   re-trigger the FAILED jobs (same sha, no new head, no attestation stranded):"
          log_line "     gh run rerun ${lsick_run:-<run>} --failed --repo $OR"
          disposition WAITING_FLAKE
          verdict WAITING_FLAKE "flake at ${HD:-${HEAD:-}}: rerun run ${lsick_run:-?} --failed; no fix, no new head"
          exit 11 ;;
        unavailable)
          log_line "… router unavailable (${lsick_why:-no reason recorded}) — this head's red is treated as fixable"
          lrow="unavailable" ;;
      esac
    fi
    [ "${lsick_action:-}" = "RERUN-FLAKE" ] && exit 11
    emit_fix FIX_REQUIRED "this head's own checks are RED: $(printf '%s' "$RED" | tr ',' ' ')"
  fi
  [ "${IF:-0}" = "0" ] && break
  # ⛔ SAY SOMETHING WHILE YOU WAIT (measured live on this change's own PR). With every required
  # check in flight the loop printed NOTHING for up to WAIT_S — and to every liveness instrument we
  # have, a lane that has produced no output for 15 minutes is indistinguishable from a wedged one.
  # The header promises progress; this is it. Printed when the count CHANGES (so a stable wait does
  # not spam 45 identical lines) and at least once a minute otherwise.
  now="$(date +%s)"
  if [ "${IF:-}" != "${_last_if:-}" ] || [ $(( now - ${_last_say:-0} )) -ge 60 ]; then
    log_line "… ${IF} check(s) in flight at head ${HEAD:0:12} — waiting ($(( deadline - now ))s left in this bound)"
    _last_if="$IF"; _last_say="$now"
  fi
  if [ "$now" -ge "$deadline" ]; then
    # In flight at the bound is NOT a failure of the lane and NOT a green: it is an unexplained
    # wait. Say so and let the caller re-run (a re-run costs one PR read).
    log_line "… checks still IN FLIGHT (${IF}) after ${WAIT_S}s — re-run this script; nothing was merged"
    disposition WAITING_CHECKS
    verdict WAITING_CHECKS "checks still in flight after ${WAIT_S}s"
    exit 11
  fi
  sleep "$INTERVAL"
done

# Green here MEANS: at least one attempt is completed and no group is red. A head with no
# check-runs at all never reaches this point — it is held in the wait above and reported as
# WAITING_CHECKS at the bound — so "the head was never tested" cannot masquerade as green.

# Green + mergeable → launch the harness chain (fresh reviewer where the repo needs one, the repo's
# own rail where it does not) and hand control to --watch.
launch_chain "$HEAD" || exit 2
log_line "… the merge chain owns PR #$PR now. Next: lane-merge.sh $PR --watch (bounded chunk; repeat)"
exit 11
