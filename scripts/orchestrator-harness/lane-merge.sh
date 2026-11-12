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
# ── THE MANDATORY LANE REPORT'S CONSUMER (#2977, owner ruling 2026-10-28) ────────────────────
# ⛔ THIS IS THE EVIDENCE HALF OF THE GATE SUBSTITUTION, AND IT IS GATED HERE BECAUSE THIS IS THE LANE'S
# OWN CONVERSATION. The ruling keeps push/PR authority with the session gates bypassed BY DESIGN and
# makes the harness supply the equivalent guarantee: a durable per-lane report (tortoise#10220) plus a
# verifier that refuses to merge on silence. Measured 2026-11-07: nothing consumed the report, and the
# one staleness signal it emits (`head_moved_since_write`) is a WARNING by a recorded decision whose
# owner is "the consumer" — two of four review rounds that day were re-run because a report described a
# tree one commit behind the head being merged, and `check` exited 0 both times.
# ⛔ REFUSING HERE RATHER THAN ONLY INSIDE merge-one.sh IS NOT DUPLICATION: the remedy costs NO PUSH
# (re-run the suites at this head and re-write the report), so parking at a head inside the chain would
# deadlock the lane on its own `parked-<PR>` marker. Here it is one FIX_REQUIRED round and the lane can
# clear it in place; the chain keeps its own refusal as the backstop for every other ingress.
# Sourced WITHOUT the `|| true` that pr-state.sh gets: a missing consumer for a gate is a harness defect
# that must be loud, and `lane_report_gate` would then be an unbound command (set -u) at the one place
# the lane is told it may merge.
# ⛔ `$O` IS NOT YET DEFAULTED HERE (fresh review, P1 — it landed as a STARTUP BREAK). `set -u` is at :57
# and `O="${O:-$HOME/orchestrator}"` is at :115, BELOW argv parsing, so referencing a bare `$O` in this
# loop made the script die with `line 85: O: unbound variable` (exit 1) whenever `O` was not exported —
# before a single argument was read, on the very box shape the header documents as supported (a lane
# runs the deployed `$O/lane-merge.sh`; `lane.sh` sets `O` WITHOUT `export`). Exit 1 is not even in this
# file's own exit-code contract, so the lane got an unmapped failure. The default is spelled INLINE here
# rather than moving the block below :115: `LANE_REPORT_GATE` must be resolved before the argv loop
# terminates the process on a bad flag.
LANE_REPORT_GATE=""
# ⛔ THE CHECKOUT SIBLING WINS OVER `$O`, AND THAT IS DISCLOSED RATHER THAN FIXED (round-20 review, P2).
# A lane runs the carrier out of its own checkout (the `launch_chain` comment calls that the natural
# way to run this script), so an UNCOMMITTED edit of `scripts/orchestrator-harness/lane-report-gate.sh`
# is the module that sources here — it decides the verdict and prints the "verified" line. Measured:
# with a lane-edited sibling gate returning 0 and the real gate present in `$O`, this carrier logged
# `VERDICT=PASS` and launched the chain, while the deployed shape refused with `VERDICT=ABSENT`.
# ⛔ WHY THIS IS NOT A P0: the MERGE is still refused, because the chain this script launches is always
# `$O/merge-one.sh` (`chain-merge.sh`), which sources the gate from ITS OWN `$O` sibling and re-runs the
# check. ⛔ THE COST IS NOT "A PAID REVIEW" — an earlier wording said that and it was measured false
# (round-21 review, P2): merge-one.sh's gate block refuses with `exit 9` BEFORE `REV_STARTED=1`, so no
# reviewer is bought and its own log line says so ("No review was bought and nothing was merged"). The
# real chain-side cost is a FIX_REQUIRED verdict round. What this carrier loses is the false
# "verified" line and whatever a lane does between seeing it and the chain's own refusal.
# The class is the same one the gate's provenance comment names — the lane supplying the instrument —
# tracked with its siblings in agent-infra#3789. `merge-one.sh` shares the lookup order.
for _lrg in "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)/lane-report-gate.sh" "${O:-$HOME/orchestrator}/lane-report-gate.sh"; do
  [ -f "$_lrg" ] && { LANE_REPORT_GATE="$_lrg"; break; }
done
# shellcheck source=/dev/null
[ -n "$LANE_REPORT_GATE" ] && . "$LANE_REPORT_GATE"
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
# ⛔ SIZED TO THE CI IT WAITS FOR, NOT TO A ROUND NUMBER — AND RE-SIZED FROM A MEASUREMENT OF THE
# LIST THAT EXISTS TODAY (agent-infra#3584). The principle in that heading was already right; the
# NUMBER was a stale measurement of a smaller list, and it had gone BELOW THE FASTEST real pass.
#
# MEASURED 2026-11-09 on daniel-ospina/agent-infra, PR-lane `ci.yml`, over the runs endpoint's 1000-run
# cap (pages 1-10 of completed runs), non-cancelled and non-`main`. ⛔ THERE ARE TWO CLOCKS HERE AND THIS
# LOOP LIVES ON THE LONGER ONE — an earlier draft quoted only the shorter one and then claimed it "includes
# the runner queue", which is exactly backwards (review cycle 6, P2 — verified against the same endpoint):
#   LANE-VISIBLE (`created_at` -> `updated_at`): creation to final check-run. A run is CREATED when the push
#     lands and only STARTED when a runner picks it up, so this is the clock a lane actually sits through.
#     n=209 · min 1931 s · p50 4062 s · p90 9825 s · p95 17185 s · max 32157 s  ->  167 of 209 (79.9 %) in 5400 s
#   RUN DURATION (`run_started_at` -> `updated_at`): EXCLUDES the pre-start queue. n=209 · min 1623 s ·
#     p50 3836 s · p90 4928 s · p95 5612 s · max 7968 s  ->  197 of 209 (94.3 %) in 5400 s
# ⛔ THE 14.4-POINT GAP IS THE POINT, NOT A ROUNDING (94.3 - 79.9): 30 of 209 runs waited 60 s .. 7 h 55 m
# BEFORE they started, which is why the lane-visible p90 is 2.7 h and its p95 is 4.8 h while the
# run-duration ones are 1.4 h and 1.6 h. Sizing to the run duration would under-state what a lane waits by
# SIX HOURS AT THE MAX (32157 - 7968 = 24189 s = 6 h 43 m) and by 3.2 h at p95, in the OPTIMISTIC
# direction — the one direction a bound must never be wrong in.
# ⛔ AND THE COUNTS ARE STAMPED, NOT PORTABLE: this is a query over a SLIDING 1000-run window, so `n`, the
# per-day counts and the percentiles' low digits move as runs age out. What barely moves is `min`, `max` and
# the two RATIOS — those are what an argument here may rest on. ⛔ AND NOT EVEN `p90`/`p95` ARE STABLE TO THE
# SECOND (review cycle 7 — an honest downgrade of an earlier "the percentiles are stable" claim): between
# two reads of the same window the lane-visible p95 moved 17185 s -> 16390 s (-4.6 %). Quote a percentile to
# size a decision and you will be arguing about a sliding window; quote the order of magnitude, the ratio or
# the min/max, and the claim survives the next run.
# ⛔ THE DAYS ARE NOT INTERCHANGEABLE, which is why the population is quoted WHOLE rather than as the
# newest day: on the run-duration clock the slowest day's p95 runs ~6836 s (re-measured 6838/6840 s by
# `created_at`/`run_started_at` bucketing — so quote it as a RANGE, ~6.8 ks ≈ 1.9 h; ⛔ NOT "6.8 h", which
# this paragraph said first: the population's run-duration MAX is 7968 s = 2.2 h, so a per-day p95 inside it
# cannot be 6.8 h, and a 6.8 H figure belongs to the LANE-VISIBLE clock's tail (p50 4062 s, p90 9825 s,
# max 32157 s = 8.9 h) — exactly the two-clock confusion this paragraph exists to prevent) and its max
# 7968 s is EXACT (the same run every read). The fastest day's p95 measured ~4565 s on the first read and 4708 s later, so
# it is quoted as `~4565 s` with its max marked a LOWER BOUND, not a ceiling (the newest day is still
# FILLING: 4725 s at the first read, 4872 s a few hours later; re-read now 5067 s). ⛔ AND THIS PARAGRAPH
# EARLIER SAID THE SLOWEST DAY'S FIGURES WERE "EXACT AND STABLE", WHICH THE SAME QUERY REFUTES (review
# cycle 13, P3 — 6836 -> 6838/6840 s) and which contradicted the paragraph directly above it: only the MAX
# is stable, and only because it is one identified run. The argument rests on that max and on the ORDERING
# of the two clocks (lane-visible slower than run duration), both of which reproduce on every read.
# ⛔ AND PER-DAY COUNTS ARE DELIBERATELY NOT QUOTED (review cycle 3, P2 — verified), and the illustration
# that used to sit here is itself the evidence: it read "92/67/53 one way and 91/67/54 the other", which
# SUMS TO 212 while this block states the population is 209 — so those numbers were never from the stated
# population (review cycle 13, P3). The direction they were illustrating DOES reproduce (a run crosses
# midnight and changes bucket with the key); a concrete count does not, which is exactly why a count that
# depends on which clock you group by is not a measurement. The per-day max above reproduces under either
# key, so that is what this block states.
# ⛔ THE WINDOW IS PART OF THE MEASUREMENT, and the first draft of this block got that wrong (round-2
# review, P1 — verified). It quoted the newest ~1 day only (n=83: p95 4521, max 4960) and claimed the new
# bound covered 100 % of the population. It does not: the 11-07 day is materially slower, so a one-day
# window measured the FASTEST day and turned a real tail into a false "100 %". State the window, always.
#
# ⛔ THE OLD 1500 s (25 min) WAS NOT MERELY TIGHT — IT WAS BELOW THE FLOOR OF THE POPULATION ON EITHER
# CLOCK, and that is window-independent: 1500 s is under the lane-visible minimum (1931 s), under the
# run-duration minimum (1623 s), and 2.7x under the lane-visible median (4062 s). ⛔ BUT STATE THE CLAIM NO
# STRONGER THAN THE MEASUREMENT SUPPORTS (review cycle 4, P2 — verified): the minimum is a property of the
# RUN, while this loop's `deadline` starts at PROCESS START, i.e. at merge-phase entry — which is AFTER the
# push. So the bound a lane must survive is `run clock - entry latency`, and with 431 s of margin on the
# lane-visible clock a lane entering its merge phase >=431 s after the push COULD have seen `INFLIGHT == 0`
# inside 1500 s. It is the empirical record, not arithmetic, that settles it, and ⛔ THE RECORD SUPPORTS LESS
# THAN A CAUSAL CLAIM (review cycle 5, P2 — verified against `$O/state/lanemerge-*.verdict`, which holds
# exactly FOUR files and deletes none): 2 x `WAITING_CHECKS checks still in flight after 1500s` and 2 x
# `FIX_REQUIRED … this head's own checks are RED`, so 0 x MERGED over n=4. What that establishes is the COST
# — a lane that exhausts the bound writes a verdict that is neither a fix order nor a merge, `INFLIGHT` is
# never recorded on that path,
# and the two red-head lanes never reached the wait at all (a RED short-circuits BEFORE the `INFLIGHT` test,
# so their 0 merges are fully explained by the reds). So: the bound's cost is measured; whether it also
# blocked a GREEN head is NOT in this record, and is argued from the duration population above instead.
# (PR numbers are not cited: a verdict file is OVERWRITTEN per invocation, so a PR-number citation for a
# transient state rots by construction — the box's second `WAITING_CHECKS` is now `lanemerge-issue-2844`.)
# A bound that only fires when a lane happens to enter late is still a bound that costs every other lane its
# merge, and the duration population above is why the common case is that it fires.
# The 1500 s figure came from a 22-check commit on a loaded box, taken when `bash-suites` was a single
# ~73 min job; `scripts/run-bash-shards.sh --list` now derives a 195-shard matrix (count STAMPED
# 2026-11-09 — the list moves, so read `--list` rather than trusting this number: an earlier draft said
# 193, which is the same stale-number defect this block exists to fix, one line lower), and the matrix
# changed what a lane waits through.
#
# 5400 s (90 min): a round number a reader can hold, and the most this clock can afford (below).
#
# ⛔ AND ITS COVERAGE IS STATED, NOT ROUNDED UP TO 100 %: **79.9 % of the LANE-VISIBLE population (167 of
# 209) completes inside 5400 s, and 94.3 % of the run-duration population (197 of 209).** FORTY-TWO runs
# exceed 5400 s on the lane-visible clock and TWENTY-NINE of those exceed the lane's whole 7200 s clock —
# i.e. one run in five, and one in seven that no setting of this constant could ever have waited out. That
# is the number to hold onto when reading what follows: this change turns a bound that could never be
# reached into one that is reached 4 times in 5, and it does NOT fix the queue that makes the fifth slow.
# ⛔ AND THE POPULATION'S COMPOSITION IS PART OF THE CLAIM (review cycle 5, P2 — verified): ⛔ THE WINDOW
# HOLDS NO SUCCESSFUL RUN AT ALL. Every completed `ci.yml` run in it is `cancelled` or `failure`, and the
# newest SUCCESSFUL `ci.yml` run is 2026-10-24T22:02Z — two weeks before the oldest run sampled. So this
# coverage describes FAILING runs, and that is the RIGHT population to size to rather than a limitation:
# the newest 100 SUCCESSFUL `ci.yml` runs are markedly FASTER (run-duration median 2114 s, 99 of 100 <=
# 5400 s, max 5758 s), so failing runs are the BINDING case — sizing to the slowest population is the
# conservative direction. ⛔ AN EARLIER DRAFT OF THIS SENTENCE CITED "62.5 % <= 5400 s" FOR THE PASSING RUNS
# AND IT WAS GARBAGE (review cycle 5, P2 — the verifier measured 99.0 %): a 5-of-8 figure from a
# hand-sampled handful, exactly the small-n inference this block forbids two paragraphs earlier. The
# passing population COULD NOT be measured from the same window (it holds none), and substituting a
# different hand-picked window for it is how the false "100 %" of the first draft happened. Measure it or
# do not quote it.
# That residual is real and it is NOT closable by this constant — see the arithmetic ceiling below. It is a
# CEILING and not a delay: the loop breaks the moment `INFLIGHT` reaches 0, so a fast lane pays nothing.
#
# It is a MERGE-PHASE cost from the lane's own wall clock, so the supervision bound below is derived
# from what is left AFTER it AND after the lane's implementation time — the two must not add up to the
# whole clock. A re-run is still permitted and still cheap (one PR read) — the bound is a runaway guard,
# never a reason to call a head green.
#
# HONEST RESIDUAL, stated because it is not fixed here, and ARITHMETIC rather than taste: keeping the
# shipped 7 supervision chunks costs `IMPL_RESERVE_S + 7*POLL_S = 900 + 840 = 1740 s`, so the largest wait
# this clock can carry is `7200 - 1740 = 5460 s`. The measured LANE-VISIBLE p90 (9825 s) and p95 (17185 s)
# are FAR above that ceiling (as is the run-duration p95 5612 s), so NO value of `WAIT_S` that fits this
# lane's clock can cover the tail — the 29 runs that exceeded 7200 s on the lane-visible clock could not
# have been waited out by ANY setting of this constant, and raising `WAIT_S` past 5460 s would only eat the
# supervision it hands off to. Raising the ceiling is the remedy, and it is not this constant's to make:
# raise `LANE_BACKSTOP_S`, which raises the derived supervision budget with it (see below). The tail case
# hands off as `WAITING_CHECKS` (exit 11) and the
# next invocation resumes the SAME counter — the designed path, which depends on something RE-INVOKING the
# lane (the controller's merge step). `ci.yml`'s `bash-suites` job bound is `timeout-minutes: 100`
# (6000 s) with no internal budget variable, so a pass can legitimately outlive this wait (5400 s) and
# still be inside the job's own bound.
WAIT_S="${LANE_MERGE_WAIT:-5400}";     is_limit "$WAIT_S" || WAIT_S=5400     # per-round check wait
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
# eat the implementation time again. Shipped defaults, RE-DERIVED when the check wait moved to its
# measured 5400s (#3584) — the old row read `3300 - 1500 - 900 = 900s / 120s = 7 chunks`, and an
# arithmetic row that is not recomputed with its operand is the same stale-measurement defect one layer
# down:
#     7200 - 5400 (check wait) - 900 (implementation reserve) = 900s / 120s = 7 chunks (840s)
# i.e. the merge phase is bounded at 6240s of the 7200s clock, and a lane that implements within its
# reserve reaches BOTH bounds. A cycle that needs longer is not a lane failure: it hands off as
# WAITING_* (exit 11) and the next invocation resumes the SAME counter.
# ⛔ AND THE CLOCK ITSELF IS THE LANE'S, READ FROM THE SAME SEAM (#2888 review, P2/P3 — verified). It
# said `${LANE_TIMEOUT:-3300}` while `lane.sh` hands the lane `${LANE_TIMEOUT:-$LANE_BACKSTOP_S}` = 7200 s
# — and `lane.sh` does not export `LANE_TIMEOUT`, so the merge phase permanently spent ~45% of the clock
# the lane now owns. That is the opposite of what the paragraph above claims ("DERIVED from the lane's own
# wall clock"). `LANE_BACKSTOP_S` IS exported by spawn-gate.sh, so this child reads the lane's real bound:
#     7200 - 5400 (check wait) - 900 (implementation reserve) = 900s / 120s = 7 chunks
# ⛔ AND THAT IS THE COST OF SIZING THE WAIT HONESTLY, SAID OUT LOUD: at the measured 5400s check wait the
# supervision allowance is 7 chunks, not 40 — the same 7 the 3300s clock used to afford at a 1500s wait.
# The trade is deliberate. 40 chunks of supervision over a check wait that can never be satisfied is
# supervision of a phase that never starts; 7 chunks over a wait that reaches the merge phase is
# supervision that actually runs. Raising LANE_BACKSTOP_S buys more chunks without touching this bound.
# ⛔ AND THE COST IS A MEASURED FALSE-BLOCK TAIL, NOT A HYPOTHETICAL (review, P3 — verified against this
# box's `state/walltime.tsv`). The 840 s is CUMULATIVE per PR (`state/lanemerge-<pr>.watch`), and the chain
# it now supervises dispatches a fresh reviewer under `REVIEW_TIMEOUT=1800`. Measured over n=54 reviewer
# runs: min 162 s · p50 316 s · p90 431 s · max 1352 s — so about 1 in 54 (2 %) exceeds 840 s and will end
# in exit 13 "budget spent; the chain was still running" where `origin/main` would have supervised for
# 4800 s. That is a labelled hand-off, never a false pass — but it is a NEW false-block tail that this
# change creates by making the chain reachable at all, so it is stated rather than absorbed. The remedy,
# if it binds in practice, is to size MAX_WATCH from the chain's own reviewers (`REVIEW_TIMEOUT`) on a
# gate repo instead of from the leftover clock.
IMPL_RESERVE_S="${LANE_MERGE_IMPL_RESERVE:-900}"; is_limit "$IMPL_RESERVE_S" || IMPL_RESERVE_S=900
# ⛔ THESE THREE OPERANDS ARE PARSED THE WAY `lane_wall_bound` PARSES THEM, NOT THE WAY `is_limit` DOES, AND A
# LEADING-ZERO VALUE IS NORMALISED BEFORE IT REACHES `$(( ))` (P3, MEASURED). `lane_wall_bound`
# (`spawn-gate.sh:3841`) tests `''|*[!0-9]*` and then compares with POSIX `test`, which reads its operands as
# DECIMAL: with `LANE_BOUND_WALL_S=03600` it prints "03600 applied" and the lane is ARMED at 3600 s. This
# file's `is_limit` deliberately rejects the `0*` form (`:142`), so the clamp below SKIPPED that input, kept
# `LANE_WALL_S=7200`, and clamped the wait against a clock 3600 s longer than the one the lane has — the exact
# 560 s past-the-wall TERM with no verdict this whole block exists to prevent, reappearing SILENTLY on an
# input the sibling honours. Measured on this box: `is_limit 03600` REJECTS · `lane_wall_bound 7200` ->
# "03600 applied" · `[ 03600 -le 7200 ]` TRUE.
# ⛔ AND THE NORMALISATION IS NOT COSMETIC — IT IS THE OTHER HALF OF THE FIX. `test` reads `03600` as decimal,
# but bash's ARITHMETIC expansion reads a leading-zero integer as OCTAL: `$(( 03600 ))` is 1920 (measured). So a
# repair that merely relaxed the gate would hand `03600` to `_wall_left=$(( LANE_WALL_S - … ))` below and clamp
# the wait against 1920 s instead of 3600 s. Stripping the zeros makes the value correct for BOTH readers.
# It is applied to all three operands `LANE_WALL_S` can come from, because the defect is in the READ, not in one
# knob: `LANE_TIMEOUT=03600` was likewise rejected and silently defaulted to 7200, and `LANE_BACKSTOP_S` is
# consumed by `$(( ))` at two further sites below. Non-digit values are left UNTOUCHED, exactly as
# `lane_wall_bound` leaves them, so `is_limit`'s rejection (and its default) still governs those.
case "${LANE_TIMEOUT:-}" in
  ''|*[!0-9]*) : ;;                                                   # not a number — the sibling passes it through too
  *) LANE_TIMEOUT="${LANE_TIMEOUT#"${LANE_TIMEOUT%%[!0]*}"}"; LANE_TIMEOUT="${LANE_TIMEOUT:-0}" ;;
esac
# ⛔ NOT RE-ASSIGNED IN PLACE: `LANE_BACKSTOP_S` is a REGISTERED term owned by `spawn-gate.sh`
# (`extensions/shared/heartbeat-progress-edges.ts`), and a second DECLARATION of it here is exactly the
# second-authority drift that registry's reverse scan refuses (it red `verify` when this normalisation landed
# in place). The normalised copy is a LOCAL, so the file reads the bound without becoming a second owner of it.
LANE_BACKSTOP_S_N="${LANE_BACKSTOP_S:-}"
case "$LANE_BACKSTOP_S_N" in
  ''|*[!0-9]*) : ;;
  *) LANE_BACKSTOP_S_N="${LANE_BACKSTOP_S_N#"${LANE_BACKSTOP_S_N%%[!0]*}"}"; LANE_BACKSTOP_S_N="${LANE_BACKSTOP_S_N:-0}" ;;
esac
case "${LANE_BOUND_WALL_S:-}" in
  ''|*[!0-9]*) : ;;
  *) LANE_BOUND_WALL_S="${LANE_BOUND_WALL_S#"${LANE_BOUND_WALL_S%%[!0]*}"}"; LANE_BOUND_WALL_S="${LANE_BOUND_WALL_S:-0}" ;;
esac
LANE_WALL_S="${LANE_TIMEOUT:-${LANE_BACKSTOP_S_N:-7200}}"; is_limit "$LANE_WALL_S" || LANE_WALL_S=7200
# ⛔ THE NUMBER NOW HAS THREE POSSIBLE SOURCES, SO IT CARRIES THE ONE IT GOT (P3, verified by running the
# message): `LANE_WALL_S` is no longer necessarily `LANE_TIMEOUT`. An operator who set only
# `LANE_BOUND_WALL_S` was told "LANE_MERGE_MAX_WATCH exceeds what LANE_TIMEOUT=3600s affords" — naming a
# variable that was NEVER SET, on a line whose whole job is to say which knob to change. That is this
# file's own "quote the operand you measured" rule (see the review-cycle P3s above), so the source is
# resolved once, here, and every message that renders `LANE_WALL_S` names it.
if is_limit "${LANE_TIMEOUT:-}" && [ "${LANE_TIMEOUT}" = "${LANE_WALL_S}" ]; then
  LANE_WALL_SRC="LANE_TIMEOUT"
# ⛔ THE BACKSTOP IS THE SOURCE ONLY WHEN THE ARMING EXPRESSION WOULD ACTUALLY PICK IT (MEASURED, and it is
# the same defect one configuration over from the one below). The test here used to be VALUE EQUALITY alone,
# which attributes by coincidence and not by the rule: `LANE_WALL_S` is `${LANE_TIMEOUT:-…}`, so a NON-EMPTY
# `LANE_TIMEOUT` wins the mask and the backstop is never read — yet with `LANE_TIMEOUT=abc
# LANE_BACKSTOP_S=7200` (7200 is spawn-gate.sh:3419's own default, i.e. the value in EVERY lane's env) the
# backstop happens to equal the shipped default, so the elif matched and every message rendered "from
# LANE_BACKSTOP_S" while naming no malformed knob at all. `-z ${LANE_TIMEOUT}` is the resolution rule
# itself, not a second opinion about the number: it is empty exactly when `${LANE_TIMEOUT:-…}` falls through.
elif [ -z "${LANE_TIMEOUT:-}" ] && is_limit "${LANE_BACKSTOP_S_N:-}" && [ "${LANE_BACKSTOP_S_N}" = "${LANE_WALL_S}" ]; then
  LANE_WALL_SRC="LANE_BACKSTOP_S"
else
  # ⛔ NAME THE KNOB THAT IS ACTUALLY AT FAULT (review, P3 — MEASURED). This branch used to say "no usable
  # LANE_TIMEOUT or LANE_BACKSTOP_S", which sends an operator to inspect TWO knobs when exactly ONE is at
  # fault, and asserts the other is unusable when it can be perfectly usable: `LANE_TIMEOUT=abc
  # LANE_BACKSTOP_S=3600` printed that sentence while 3600 was a valid bound. It was not consulted because
  # `LANE_WALL_S` above is `${LANE_TIMEOUT:-...}`, and `lane.sh:882` arms the lane with the IDENTICAL
  # expression — so the line states the masking instead of inviting a fall-through, which would make this
  # file's clock disagree with the armed one (the mirror-image of the bug this branch fixes).
  if [ -n "${LANE_TIMEOUT:-}" ]; then
    LANE_WALL_SRC="the shipped default, because LANE_TIMEOUT='${LANE_TIMEOUT}' is not a bounded integer, and LANE_BACKSTOP_S=${LANE_BACKSTOP_S:-<unset>} was NOT consulted — the arming path masks it with the same \${LANE_TIMEOUT:-…} expression"
  elif [ -n "${LANE_BACKSTOP_S:-}" ]; then
    LANE_WALL_SRC="the shipped default, because LANE_BACKSTOP_S='${LANE_BACKSTOP_S}' is not a bounded integer"
  else
    LANE_WALL_SRC="the shipped default, because neither LANE_TIMEOUT nor LANE_BACKSTOP_S is set"
  fi
fi
# ⛔ THE DESIGN OPERAND IS THE CALLER'S, NOT THE ARMED ONE (review, P2 — MEASURED, and it is a false block
# this diff would otherwise introduce). `MAX_WATCH_FIT` is derived from `LANE_WALL_S` at its own definition
# below, so lowering `LANE_WALL_S` for the RUNTIME clamps also resized the DESIGN allowance: with
# `LANE_BOUND_WALL_S=3600` it fell from 7 chunks to 1 (`(3600-5400-900)/120` → floored to 1), and the one
# path that actually consumes the design operand — a `--watch` re-run whose lane clock is UNRESOLVABLE, i.e.
# the documented controller resume — then gets a single 120 s chunk and declares `BLOCKED_ATTEMPTS` over a
# chain still legitimately reviewing (median reviewer run 316 s), with `WATCH_F` never rewound. That
# contradicts the promise stated at `MAX_WATCH`'s re-derivation ("a lane with no resolvable clock — the
# controller re-run — keeps the shipped 7 chunks") and is a WORSE false block than the 840 s tail this diff
# discloses as a residual. So the ceiling reducer is applied to `LANE_WALL_S` (the runtime clock) only, and
# the pre-clamp value is kept here for the design arithmetic.
LANE_WALL_CALLER_S="$LANE_WALL_S"
# ⛔ THE ARMED CEILING IS NOT NECESSARILY THIS FILE'S OPERAND (review, P3 — verified against
# `spawn-gate.sh`'s `lane_wall_bound`): `run_agent` arms `min(caller_bound, LANE_BOUND_WALL_S)` for every
# POSITIVE `LANE_BOUND_WALL_S`, and that knob is documented as a CEILING REDUCER. Mirroring only
# `LANE_TIMEOUT`/`LANE_BACKSTOP_S` therefore computed a clamp against a clock the lane does not have:
# with `LANE_BOUND_WALL_S=3600` a lane entering its merge phase at elapsed 3000 s was clamped to 4160 s of
# wait, TERMed at 3600 s, and wrote NO verdict — the unlabelled kill the clamp exists to prevent. A `0` here
# is "wall axis OFF", which `lane_wall_bound` REFUSES to reduce to, so it is not applied either.
if is_limit "${LANE_BOUND_WALL_S:-}" && [ "${LANE_BOUND_WALL_S:-0}" -gt 0 ] && [ "$LANE_BOUND_WALL_S" -lt "$LANE_WALL_S" ]; then
  LANE_WALL_S="$LANE_BOUND_WALL_S"
  LANE_WALL_SRC="LANE_BOUND_WALL_S, the ceiling reducer spawn-gate.sh applies"
fi
INTERVAL="${LANE_MERGE_INTERVAL:-20}"; is_limit "$INTERVAL" || INTERVAL=20
[ "$INTERVAL" -ge 5 ] || INTERVAL=20

# ⛔ THE CHECK WAIT HAS A SECOND BOUND, AND IT IS NOT THIS FILE'S CLOCK (#3584 review, P1 — MEASURED).
# `WAIT_S` seconds are spent inside ONE TOOL CALL, and `run_agent` (spawn-gate.sh) arms
# `lane-bound.sh watch` around the lane's `pi` process. That watchdog ends on IDLE, not on the wall
# clock: `lane-bound.sh` resolves `IDLE_S` flag → `LANE_BOUND_IDLE_S` → **2700 s**, and spawn-gate passes
# NO `--idle`, so 2700 s is what a shipped fleet runs. Its progress evidence is EITHER growth of the LANE
# LOG or a CPU delta above `LANE_BOUND_CPU_TOL_CS` (10 cs) across the lane's process SUBTREE.
# MEASURED 2026-11-09 (this change's own review, the reviewer's suggested probe):
#     sh lane-bound.sh run --idle 60 -- env LANE_MERGE_WAIT=180 … bash lane-merge.sh 99 --checks-tsv <in-flight>
#     → [lane-bound] VERDICT verdict=stalled … elapsed=75s silent=75s bytes=0 bytes_delta=0
#       cpu_cs=0 cpu_delta_cs=0   (TERM, exit 143, and NO `lanemerge-99.verdict` was ever written)
# ⛔ THE CPU ARM IS INERT FOR A POLLING LOOP, and not because the loop is idle: `ps time` reports the
# ACCUMULATED time of processes still ALIVE, so each poll's short-lived `gh`/`python3` child carries its
# CPU away when it exits and the subtree total stays 0. The byte arm is the only one that works — and in a
# `-p` lane this script's stdout (log_line) reaches no log. So a wait that outlives 2700 s yields NO
# `WAITING_CHECKS` hand-off: the watchdog TERMs the lane first, `lane.sh` writes "NO merge-phase verdict",
# and there is no verdict file, no PR comment and no resumable counter. That is STRICTLY WORSE than the
# 1500 s bound it replaces, which at least exited 11 well below the watchdog.
# Two arms, in this order:
#   (1) make progress REAL — append a heartbeat to the LANE LOG the watchdog watches: `$O/logs/lane-<issue>.log`
#       (lane.sh) or `$O/logs/fix-<pr>.log` (fix-one.sh); `LANE_MERGE_HB` overrides the target.
#   (2) if no heartbeat target resolves, CAP the wait BELOW the watchdog's allowance rather than out-reach
#       a bound that will kill the lane unlabelled — a bound the lane cannot reach is an inert guard, which
#       is this file's own rule (#3584) applied one layer down.
HB_F="${LANE_MERGE_HB:-}"
# ⛔ THE INVARIANT BELOW KEEPS ITS DESIGN OPERAND: the cap is a RUNTIME limit on how long this pass waits,
# and must never feed back into `MAX_WATCH` — otherwise the supervision budget a lane gets would depend on
# whether a log file happened to exist (7 chunks with a heartbeat, 30 without), and the documented
# arithmetic row would describe only one of the two worlds.
WAIT_S_DESIGN="$WAIT_S"
# ── how much of the LANE's wall clock is already spent ────────────────────────────────────────────
# ⛔ THE WAIT NEEDS THIS AND MUST NOT GUESS IT (#3584 review, P1 — see the clamp at the deadline).
# `run_agent` arms `lane-bound.sh`'s WALL ceiling around the lane's `pi` with `LANE_BACKSTOP_S`, so the
# datum is "when did THIS lane's run start" — and it is READ rather than inferred: `lane.sh` stamps
# `LANE_RUN_TOKEN="<issue>.<pid>.<epoch>"` into `$O/logs/lane-<issue>.owner` BEFORE it spawns the agent,
# so that epoch over-states the agent's own start by the spawn latency (the conservative direction for
# a bound that must never fire late).
# ⛔ EMPTY MEANS "UNKNOWN", NEVER ZERO. Reading an unresolvable elapsed as 0 would leave the wait
# uncapped exactly when the lane is oldest — the same inert guard from the other side.
# ⛔ AND A STALE TOKEN MUST NOT COUNT AS THIS LANE'S. The file is per-ISSUE and outlives the run that
# wrote it, so a LATER invocation (the controller's merge step re-running this script for a PR whose
# lane has exited) would otherwise read a token from a dead run, compute an elapsed larger than the
# whole clock, and clamp the wait to 0 — handing off instantly instead of resuming. A token from the
# future (clock skew, another box) is unknown for the same reason.
# ⛔ AND LIVENESS IS NOT IDENTITY (review, P3 — verified on this tree, BOTH directions). The
# first cut required the token's pid to be merely ALIVE (`kill -0`), and that is wrong twice: a
# RECYCLED pid (any same-user process) makes a DEAD run's age read as this lane's — measured, an
# epoch 100000 s old clamped a live wait to 0 — and a NEWER dispatch of the same issue RE-STAMPS
# this per-ISSUE file, so an OLDER still-live lane reads the newer epoch, UNDER-states its elapsed and
# the clamp goes inert (the "the epoch over-states the start" argument only holds for a run's OWN
# token). The identity that actually holds is "the shell that stamped this token leads to me":
# `lane.sh` → `run_agent` → `lane-bound.sh watch` → `pi` → this tool call. So the token's pid is
# required to be an ANCESTOR. A controller re-running this script for a PR is not under a lane and
# correctly gets "unknown", which is the disclosed unclamped path.
pid_is_ancestor() { # pid_is_ancestor <pid>
  local want="${1:-}" cur="$$" n=0
  case "$want" in ''|*[!0-9]*) return 1 ;; esac
  [ "$want" -gt 0 ] || return 1
  while [ "$n" -lt 24 ]; do
    cur="$(ps -o ppid= -p "$cur" 2>/dev/null | tr -d ' ')"
    # An unreadable or non-numeric PARENT ends the walk as "not an ancestor", never as a match.
    case "$cur" in ''|*[!0-9]*) return 1 ;; esac
    [ "$cur" -gt 0 ] || return 1
    if [ "$cur" = "$want" ]; then return 0; fi
    n=$(( n + 1 ))
  done
  return 1
}
lane_elapsed_s() {
  local now tok lpid ep
  now="$(date +%s)"
  # 1. the explicit seam — fixtures, and an operator whose caller stamps no token
  if is_limit "${LANE_MERGE_ELAPSED_S:-}"; then printf '%s' "$LANE_MERGE_ELAPSED_S"; return 0; fi
  # 2. lane.sh's own run token
  [ -n "${ISSUE:-}" ] || return 0
  [ -r "$O/logs/lane-$ISSUE.owner" ] || return 0
  # `IFS= read -r` (a builtin) strips the newline; no `tr`/`sed` dialect to get wrong. Trailing
  # whitespace is trimmed by parameter expansion, the way `round_of` above reads its counter.
  tok=""; IFS= read -r tok 2>/dev/null < "$O/logs/lane-$ISSUE.owner" || true
  tok="${tok%"${tok##*[![:space:]]}"}"
  ep="${tok##*.}"
  lpid="${tok#*.}"; lpid="${lpid%%.*}"
  # ⛔ THE EPOCH IS NOT AN `is_limit` VALUE (verified: `is_limit` refuses anything over 9 digits, and a
  # unix epoch has 10 — the guard would have rejected EVERY real token and left the clamp permanently
  # inert on the only path that can feed it). Digits-only, plus a length sanity bound, is the test here.
  case "$ep" in ''|*[!0-9]*) return 0 ;; esac
  [ "${#ep}" -le 12 ] || return 0
  [ "$ep" -gt 0 ] || return 0                 # `printf 0` when lane.sh's `date` failed
  [ "$ep" -le "$now" ] || return 0            # a future stamp is a clock we cannot reason about
  pid_is_ancestor "$lpid" || return 0          # a token that is not THIS run's is not this lane's age
  printf '%s' "$(( now - ep ))"
}
# The divisor is floored at the shipped chunk length: LANE_MERGE_POLL=0 is a legitimate value (a chunk
# that exits at once at its deadline), and dividing by it would break the arithmetic below instead of
# yielding a bound.
_fit_poll="$POLL_S"; [ "$_fit_poll" -ge 1 ] || _fit_poll=120
MAX_WATCH_FIT=$(( (LANE_WALL_CALLER_S - WAIT_S_DESIGN - IMPL_RESERVE_S) / _fit_poll ))
[ "$MAX_WATCH_FIT" -ge 1 ] || MAX_WATCH_FIT=1          # a tiny LANE_TIMEOUT still supervises once
# ⛔ THE CLAMP ABOVE IS A FLOOR, AND A FLOOR CAN MASK AN OVERSPENT CLOCK (review cycle 3, P3 — verified, not
# fixed here so the diff stays to its own defect). If an ENV override makes `LANE_WALL_S - WAIT_S -
# IMPL_RESERVE_S` zero or negative — `LANE_MERGE_WAIT=6300` gives `(7200-6300-900)/120 = 0` — the clamp
# hands back 1 chunk and the merge phase becomes `6300 + 120 + 900 = 7320 > 7200`: the lane's own wall clock
# kills it mid-supervision, which is the #2888 shape the three-term invariant exists to prevent. The SHIPPED
# default is safe (7140 of 7200, 60 s of slack) and the suite's arithmetic arm pins it, which is why this is
# a regression-guard question and not a live defect. ⛔ AND THE SAFETY NET IS NARROWER THAN IT LOOKS (review
# cycle 5, P2 — verified by running this block under each override): the suite's arm catches a DEFAULT change,
# and the ONLY override that warns is `LANE_MERGE_MAX_WATCH` (below). An env override of `LANE_MERGE_WAIT`,
# `LANE_TIMEOUT` or `LANE_BACKSTOP_S` is SILENT — `LANE_TIMEOUT=3300` with the shipped wait yields
# `MAX_WATCH=1` and a `6420 s` merge phase against a `3300 s` clock, with no line printed anywhere. ⛔ SO:
# anyone who raises the wait, or lowers the wall, must re-check this arithmetic by hand — nothing here will
# tell them. The honest fix, when someone owns it, is a `say_err` in this branch.
MAX_WATCH="$MAX_WATCH_FIT"
# ⛔ THE `--watch` LAYER NEEDS NO HEARTBEAT, and that is a measured statement rather than an omission: with
# the DESIGN operand it is bounded by `MAX_WATCH x POLL` (7 x 120 = 840 s at the shipped defaults, and
# 840 < the 2700 s progress allowance), so it reaches its own verdict before the watchdog can fire. Only the
# check wait above can outlive the watchdog, which is why only the check wait is capped/hearted.
# ⛔ AND THE ALLOWANCE IS RE-DERIVED FROM THE CLOCK THAT IS ACTUALLY LEFT, WHEN `--watch` RUNS (#3850
# review, P2 — verified by arithmetic against this repo's own declared chain budgets). The design operand
# above sizes the allowance against the WORST-CASE check wait, which is the right FLOOR — but supervision
# is paid AFTER the wait, from whatever clock remains, so a lane whose checks settled early was granted the
# worst case's 7 chunks (840 s) while thousands of seconds still stood on its clock. And 840 s is BELOW the
# chain this loop supervises: `merge-one.sh` budgets a fresh-context review at `REVIEW_TIMEOUT` = 1800 s and
# leases the PR claim for `REVIEW_TIMEOUT + _gw + 300` = 3000 s at the defaults (`claims.sh:166`), and
# `chain-merge.sh`'s merge-phase wait is 1890 s (`claims.sh:110`). A lane that finally cleared the wait
# could therefore hand off a FALSE blocker — `BLOCKED_ATTEMPTS … the chain was STILL RUNNING` — over a
# chain that was legitimately still reviewing, and `WATCH_F` is only rewound by a fix round or a head move,
# so every later `--watch` re-entered the same arm.
# The raise can never exceed the OTHER two bounds, and never lowers the design floor:
#   · the lane's REMAINING wall clock (`lane_elapsed_s`, one chunk held back to write the verdict);
#   · the watchdog's progress allowance — `--watch` writes NO heartbeat, so a chunk sequence longer than
#     `IDLE_BOUND_S` is killed as `stalled`; that bound WINS when it is the smaller one (a labelled hand-off
#     beats an unlabelled kill).
# An UNRESOLVABLE elapsed — a controller re-run, which is not under a lane and has no lane clock at all —
# keeps exactly the shipped design operand, so this cannot become unbounded supervision for a non-lane.
if [ -n "${LANE_MERGE_MAX_WATCH:-}" ] && is_limit "${LANE_MERGE_MAX_WATCH:-}"; then
  # An explicit override is an operator's escape hatch and is HONOURED rather than silently rewritten —
  # but it is never silent about breaking the invariant above, because the next reader would take the
  # bound at face value.
  MAX_WATCH="$LANE_MERGE_MAX_WATCH"
  # ⛔ NOT ON A LANE WITH NO WALL CLOCK: the sentence below says "the lane's wall clock ends the phase
  # first", which is FALSE when `LANE_TIMEOUT=0` (review cycle 15, P3 — measured: a pinned lane printed that
  # warning and, two lines later, "no wall ceiling is enforced for this lane").
  [ "$LANE_WALL_S" -eq 0 ] || [ "$MAX_WATCH" -le "$MAX_WATCH_FIT" ] || say_err "lane-merge: LANE_MERGE_MAX_WATCH=$MAX_WATCH exceeds what the ${LANE_WALL_CALLER_S}s DESIGN allowance (the caller bound, before any ceiling reducer) affords after the check wait (${WAIT_S_DESIGN}s) and the implementation reserve (${IMPL_RESERVE_S}s) — $MAX_WATCH_FIT chunk(s) fit; honouring the override, but the lane's ${LANE_WALL_S}s wall clock (from ${LANE_WALL_SRC}) ends the phase first."
fi
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
# ⛔ THE ROUND COUNTER IS READ WITH A BUILTIN, LIKE THE VERDICT LINE (round-24 review, P1). This was
# `r="$(cat "$ROUND_F")"`, and a lane runs this carrier itself with its own PATH — a `cat` that answers 0
# for `*.round` makes `round_of` return 0 forever, so `emit_fix` grants round 1 every time and THE CAP AT
# MAX_ROUNDS NEVER FIRES: an unbounded budget on the one number this script exists to bound. Measured with
# only PATH differing, round file seeded to the cap: control 13/BLOCKED_ATTEMPTS, shimmed 10/FIX_REQUIRED
# round after round. `IFS= read -r` is a builtin; nothing to shim. (The `git` seam in this file is the
# disclosed residual, agent-infra#3789 — but a counter is not a seam, it is a file read.)
round_of() { local r=0; if [ -f "$ROUND_F" ]; then IFS= read -r r < "$ROUND_F" || true; fi; [ -n "$r" ] || r=0; is_limit "$r" || r=0; printf '%s' "$r"; }

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
# ⛔ AND THIS BLOCK RUNS **AFTER** THE ISSUE IS RECOVERED, NOT AT MODULE SCOPE (review round 3, P2 —
# verified). `ISSUE` is not always given on the command line: the documented RE-INVOCATION path — the
# one the PR names as the remaining step between a green PR and `merged` — omits `--issue` and recovers
# it from `$O/state/lanemerge-<pr>.issue` a few lines above. Resolving the heartbeat target before that
# recovery found no `lane-<issue>.log`, silently capped the wait to `IDLE_BOUND_S - margin` (2660 s,
# BELOW the measured lane-visible median of 4062 s) and made the wall clamp inert (no issue -> no run
# token). The cap is still a RUNTIME limit, so `WAIT_S_DESIGN` above keeps the supervision invariant's
# operand and neither value can feed back into it.
if [ -z "$HB_F" ]; then
  if [ -n "${ISSUE:-}" ] && [ -f "$O/logs/lane-$ISSUE.log" ]; then HB_F="$O/logs/lane-$ISSUE.log"
  elif [ -f "$O/logs/fix-$PR.log" ]; then HB_F="$O/logs/fix-$PR.log"
  fi
fi
# ⛔ THE SECOND TARGET IS ANOTHER PROCESS'S STALL DETECTOR, STATED RATHER THAN HIDDEN (review, P3 —
# verified). `$O/logs/fix-$PR.log` is the log a FIXER's own `lane-bound.sh --log` watches, so appending
# this wait's heartbeats to it is progress evidence for whoever that watchdog is supervising: a genuinely
# stalled fixer for the SAME PR would keep reading as alive while this merge phase runs. The branch is
# taken on a re-invocation without `--issue` OR with one whose `lane-<issue>.log` does not exist (a lane run
# from another `$O`), AND with a concurrently live fixer on that PR — which the per-PR
# claim is what normally prevents — so this is a narrow disclosed edge rather than a live defect.
# Closing it properly means preferring a target only THIS invocation's watchdog reads (or probing the
# claim before falling back); neither is done here, and `LANE_MERGE_HB` is the way to be explicit.
# The watchdog's allowance, resolved the way `lane-bound.sh` resolves it. This script is never handed the
# flag, so env → default is the whole chain here — and the default is THEIRS, not a second copy of it.
# ⛔ THE RESIDUAL, MEASURED RATHER THAN ASSUMED: the heartbeat only counts if it lands in the file the
# watchdog is watching (`--log`), and the mirror above only sees env → default. MEASURED 2026-11-09 —
# `--idle 60` passed as a FLAG (invisible to this mirror) left the cap inert; and a heartbeat written to
# a file OTHER than `--log` left `bytes_delta=0` and the lane was still killed as `stalled` (8 heartbeat
# lines written, none of them read). Both are safe, not silent: the first because spawn-gate passes no
# `--idle` (the leg this mirrors), the second because the cap fires when discovery finds nothing. The
# one path that can still be wrong is a caller passing `--log` somewhere OTHER than the two discovered
# paths AND `--idle` explicitly — it gets neither arm, and this line is why that is a known edge rather
# than an oversight.
IDLE_BOUND_S="${LANE_BOUND_IDLE_S:-2700}"; is_limit "$IDLE_BOUND_S" || IDLE_BOUND_S=2700
# Two polls of headroom, so the first heartbeat lands before the bound can fire; floored so a tiny
# LANE_MERGE_INTERVAL cannot make the cap degenerate.
_hb_margin=$(( INTERVAL * 2 )); [ "$_hb_margin" -ge 10 ] || _hb_margin=10
# ⛔ THE MARGIN IS SIZED TO A POLL *SLEEP*, NOT TO A CHECK *READ*, AND THAT IS A DISCLOSED RESIDUAL
# (review, P2 — verified by reading the adapter, NOT fixed here). The loop reads this head's checks at the
# TOP of each iteration and tests the deadline AFTER it, so the hand-off lands `read_latency + <=intervals`
# after the deadline. `checks_read` shells out to `gh`, which is the REST adapter → `gh-limit.py`, whose
# retry path can SLEEP 60/120/240 s on top of its shim budget — far more than this margin. A throttled
# final read can therefore push the labelled hand-off PAST the wall (or past the idle allowance) and the
# watchdog TERMs the lane mid-hand-off: no verdict, no WAITING_CHECKS, the same unlabelled outcome this
# branch's P1 closed on the common path. ⛔ NOT A REGRESSION (`origin/main` had no clamp at all, so every
# late lane died that way); the class is SHRUNK, not closed. Bounded fix, not taken here because it is a
# loop-restructure on a gate path and deserves its own review: test the deadline BEFORE the read on
# iterations after the first, keeping "one last look" while taking the read off the critical path — or run
# `checks_read` under a bounded runner. ⛔ AND THE MARGIN CANNOT SIMPLY GROW TO 60 s+: it is spent out of
# the SAME 60 s of slack (`7140 + 60 = 7200`), so the fix is the read's placement, not the number.
# ⛔ THIS IS A RUNTIME LIMIT ON A REAL WAIT, SO `--status` MUST NOT PAY FOR IT (review finding, P3 —
# verified). `--status` is documented "no network, no writes" and exits ABOVE this block, so a read-only
# status query never emits the cap's multi-line `say_err` about a wait it was never going to sit
# through. ⛔ THE ORDER IS THE GUARD, AND IT MUST STAY THIS WAY (`8de98255f` moved this block below the
# `--status` exit; that MOVE is what fixed the P3 — not the `[ "$STATUS" -eq 0 ]` conjunct, which was
# dead here because `STATUS=1` always returned above and has been removed). `lane-merge.test.sh` pins
# the ORDER, so moving the block back above the exit reddens its arm.
# ⛔ AND `--watch` MUST NOT PAY FOR IT EITHER (#3850 review, P3 — verified). This block has no `WATCH`
# conjunct below, so every `--watch` invocation — which returns inside its own chunk loop and NEVER reaches the
# check wait — also emitted a multi-line `CAPPED at …s` about a wait it was never going to sit through, and
# mutated `WAIT_S` for no consumer. The `--status` guard above cannot cover it (both paths share module scope),
# so the runtime limit is scoped to the path that runs the wait. `lane-merge.test.sh` pins it.
if [ "$WATCH" -eq 0 ] && [ -z "$HB_F" ] && [ "$IDLE_BOUND_S" -gt 0 ] && [ "$WAIT_S" -ge "$IDLE_BOUND_S" ]; then
  # ⛔ THE ALLOWANCE IS AN UPPER BOUND, AND THE OLD FLOOR MADE IT A LOWER ONE (review finding, P3 —
  # verified by arithmetic). `[ "$WAIT_S" -ge "$POLL_S" ] || WAIT_S="$POLL_S"` RAISED the capped wait
  # back to one poll chunk whenever the allowance was SMALLER than a chunk — with
  # `LANE_BOUND_IDLE_S=120` and the shipped 120 s poll that is `WAIT_S=120 >= 120`, i.e. the "cap"
  # lands ON the bound it exists to stay strictly under and the guard stops guarding. The floor is 0
  # now: a wait of 0 is a labelled hand-off on the first poll, which is the right answer when the
  # allowance cannot fit one (the loop's own `[ "$now" -ge "$deadline" ]` test terminates it).
  WAIT_S=$(( IDLE_BOUND_S - _hb_margin )); [ "$WAIT_S" -ge 0 ] || WAIT_S=0
  say_err "lane-merge: no watchdog-visible heartbeat target (nothing at \$O/logs/lane-${ISSUE:-<issue>}.log or \$O/logs/fix-$PR.log, and LANE_MERGE_HB is unset) — the check wait is CAPPED at ${WAIT_S}s, below lane-bound.sh's ${IDLE_BOUND_S}s progress allowance. An uncapped wait would be killed as 'stalled' before it could write its hand-off verdict (#3584 review, P1). Set LANE_MERGE_HB, or run the lane with --issue, to get the full wait."
fi
printf '%s %s\n' "${ISSUE:-}" "$(date +%s)" > "$PHASE_F" 2>/dev/null || true

# ── THE REPO'S REQUIRED SURFACE IS THE GATE THIS LOOP WAITS ON (#4014) ──────────────────────────
# THE DEFECT. This loop classified EVERY check on the head's surface: any red spent a FIX round, and
# any non-terminal attempt was waited out to the 5400 s bound — regardless of whether the repo's own
# branch protection gates on that check at all. MEASURED on a live tortoise PR (#12171, head
# 49840e6e): 57 check names, 24 of them still queued after 70 minutes, and exactly ONE red —
# `agent-infra-ci / lint` — which is NOT one of tortoise's 7 required contexts, and which main cannot
# even be compared against, because main publishes the same ruff program under a DIFFERENT name
# (`main-lint / lint`). So a lane was told to FIX a red it had not caused and could not fix, spent
# its rounds on it, and the owner then did the only thing the loop left open: admin-merged past CI.
# That is the measured mechanism behind "CI is too slow to gate a merge, so merges bypass it".
#
# THE RULE, and it is NOT a weakening of the gate — it is the repo's OWN gate, read from the ONE home
# that already resolves it (`repo-authority.sh::resolve_required_checks`, the same resolver
# `merge-one.sh` and `orch-loop.sh` use, so a third opinion cannot appear here):
#   * a REQUIRED red is a FIX_REQUIRED round, exactly as before;
#   * a REQUIRED name that is not on the surface YET is IN FLIGHT, never green. Tortoise's
#     `python-ci-gate` is published only when its whole needs-graph finishes, so its absence is the
#     normal state for most of a PR's life — and a missing required check must never read as
#     "nothing left to wait for";
#   * a NON-required red is REPORTED (never hidden) and does not spend a round;
#   * a NON-required in-flight job is REPORTED and is not waited for.
# WHO MERGES IS UNCHANGED, and that is why this cannot land anything the repo's contract refuses:
# this script never merges. `merge-one.sh` runs the repo's own authority — a gate repo merges through
# a plain `gh pr merge`, where GitHub enforces exactly this required set (so an advisory red still
# cannot be bypassed INTO main by anything this loop does); a rail repo goes through
# `admin-merge.sh`, which re-reads the WHOLE surface and refuses on its own rules. What changes here
# is only that the loop stops *fixing* and *waiting on* checks the merge contract does not gate on.
# ⛔ FAIL-CLOSED, AND THE UNREADABLE CASE IS THE ONE THAT MATTERS. A contract that could not be read
# is NOT treated as "nothing is required": the resolver's own fail-closed fallback is tortoise's name
# list and is FOREIGN to every other repo, so on `REQ_SOURCE=fallback` — or with no `repo-authority.sh`
# on this box at all — `LM_REQ_TRUSTED=0` and EVERY check on the surface counts as required, which is
# exactly this script's behaviour before this change. A box whose protection read fails today behaves
# as it did yesterday, loudly.
# ⛔ THE COST IS ONE REST READ PER INVOCATION, NOT PER POLL. `required_checks` hits
# `branches/main/protection/required_status_checks` once, before the wait loop starts — the poll inside
# the loop is unchanged (and its un-paginated shape answers 304 free). 22 landers share one rate-limited
# account, so one extra read at startup is the price of not waiting on 24 checks nobody requires; it is
# the same read `merge-one.sh` already pays once per chain.
LM_REQ=""; LM_REQ_SRC=""; LM_REQ_TRUSTED=0
# ⛔ `--watch` MUST NOT PAY FOR IT (review P2, #4039 — verified). `--watch` never classifies a
# check-run surface (it reads the chain's LOCAL state; the only `WATCH` tests in this file are the
# `WAIT_S` cap guard and the `--watch` branch, both BELOW this block), so every `--watch` chunk would
# spend one `branches/main/protection` read — the one read the harness flags ESSENTIAL and lets breach
# the REST reserve — for a value nothing on that path consumes. `--watch` is also the highest-frequency
# invocation (`MAX_WATCH` chunks per lane, ~22 lanes). The order is the guard, exactly as the `WAIT_S`
# cap is deliberately ordered below the `--status` exit (`:699`). Leaving the surface unresolved here is
# fail-closed by construction: `LM_REQ_TRUSTED` stays 0, so anything that DID classify on this path would
# treat every check as required.
lm_resolve_required_surface() {
  local _ra="" _d="" _c=""
  [ "${WATCH:-0}" -eq 0 ] || return 0
  [ -n "${OR:-}" ] || return 0
  _d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" || _d=""
  for _c in "${O_WORK:-}" "${O:-}" "$_d"; do
    [ -n "$_c" ] || continue
    if [ -f "$_c/repo-authority.sh" ]; then _ra="$_c/repo-authority.sh"; break; fi
  done
  if [ -z "$_ra" ]; then
    say_err "lane-merge: no repo-authority.sh beside this script or in \$O — the required-check contract cannot be read, so EVERY check on this head counts as required (fail-closed)"
    return 0
  fi
  # shellcheck source=/dev/null
  . "$_ra" 2>/dev/null || {
    say_err "lane-merge: $_ra did not source — EVERY check on this head counts as required (fail-closed)"
    return 0
  }
  if ! command -v resolve_required_checks >/dev/null 2>&1; then
    say_err "lane-merge: $_ra is stale (no resolve_required_checks) — EVERY check on this head counts as required (fail-closed)"
    return 0
  fi
  # `REQ` in the environment is the operator/controller override the other consumers honour; capture
  # it ONCE here because `resolve_required_checks` overwrites `REQ` with the resolved value in THIS
  # shell (that in-place contract is what makes REQ_SOURCE readable — a command substitution would
  # subshell it away).
  REQ_OVERRIDE="${REQ:-}"; REQ=""
  resolve_required_checks "$OR" >/dev/null 2>&1 || true
  LM_REQ="${REQ:-}"; LM_REQ_SRC="${REQ_SOURCE:-}"
  case "$LM_REQ_SRC" in
    protection|env)
      if [ -n "$LM_REQ" ]; then LM_REQ_TRUSTED=1; fi ;;
  esac
  if [ "$LM_REQ_TRUSTED" = 1 ]; then
    say_err "lane-merge: required surface for $OR (source=$LM_REQ_SRC): $LM_REQ"
  else
    say_err "lane-merge: the required-check contract for $OR is UNREADABLE (source=${LM_REQ_SRC:-none}) — every check on this head is treated as required (fail-closed)"
  fi
  return 0
}
lm_resolve_required_surface

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
    # ⛔ NO 2>/dev/null ON THIS ONE (#3858). The single-page poll above can stay quiet — its TOTAL row
    # already answers "is this all of it" — but on the PAGINATED path the read's own stderr is the only
    # place the reason a page stream stopped exists, and suppressing it left an operator looking at a
    # held head with nothing to act on. The caller routes it to a file and prints the first line.
    gh api "$q" --paginate --jq "$rows"
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
classify() { # classify <tsv-file> [required-set] [1=trusted]
  python3 - "$1" "${2:-}" "${3:-0}" <<'PY'
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
# ── NUMBER 4014: THE REQUIRED SURFACE DECIDES WHAT IS WAITED FOR AND WHAT IS FIXED ────────────
# `required` is the repo's own branch-protection set (space-separated) and `trusted` says whether it
# was actually READ. Untrusted => EVERY name is required, i.e. the pre-#4014 behaviour, which is the
# fail-closed default (see `lm_resolve_required_surface`).
required = sys.argv[2].split() if len(sys.argv) > 2 and sys.argv[2] else []
trusted = (len(sys.argv) > 3 and sys.argv[3] == "1")


def is_required(name):
    """Is THIS surface check one of the repo's required contexts?"""
    if not trusted or not required:
        return True
    return any(_bare_is(name, r) for r in required)


def _bare_is(name, wanted):
    """Does THIS surface name name the required context `wanted`?

    GitHub renders a reusable workflow's job as `<caller> / <job>` (measured: `agent-infra-ci / lint`
    on tortoise). The REQUIRED CONTEXT is the bare name branch protection declares, so a suffixed
    name must still match its required parent — the same normalisation `merge-one.sh` and
    `admin-merge.sh` apply to a gate row. The direction matters: this makes MORE names count as
    required, never fewer.
    """
    if name == wanted:
        return True
    i = name.rfind(" / ")
    return i > 0 and name[i + 3:] == wanted


def is_required(name):
    """Is THIS surface check one of the repo's required contexts?"""
    if not trusted or not required:
        return True
    return any(_bare_is(name, r) for r in required)


inflight_req, red, red_req, red_adv, names = 0, [], [], [], set()
for (app, name), (status, conclusion, _cid) in sorted(newest.items()):
    names.add(name)
    disp = "%s:%s" % (app, name) if app else name
    req = is_required(name)
    if status != "completed":
        # Only a REQUIRED in-flight job is waited for. An advisory job still queued behind the
        # queue is a fact about the queue, not about whether this head may proceed.
        if req:
            inflight_req += 1
    elif conclusion not in NONRED:
        red.append(disp)
        (red_req if req else red_adv).append(disp)
# A REQUIRED NAME WITH NO ROW AT ALL is neither green nor red — it has not been published yet
# (tortoise's `python-ci-gate` appears only once its whole needs-graph finishes). It is reported
# separately so the caller can treat it as in flight; a missing required check must never be read
# as "nothing left to wait for".
# ⛔ THE PRESENCE TEST IS THE *SAME* TEST AS `is_required` (review P1, #4039). The first revision
# asked `n not in names`, so for the very shape 4014-f declares supported — required `lint`, surface
# row `agent-infra-ci / lint` — the bare name was never in `names` and the check was reported BOTH as
# required-and-green AND as "not published yet": `_eff` never reached 0, the loop waited out the whole
# bound on a complete green required surface and exited `WAITING_CHECKS`, printing `(0) in flight`. Two
# harness readers disagreed about one head. One rule now decides both questions.
missing = [n for n in required if not any(_bare_is(x, n) for x in names)] if (trusted and required) else []
print("INFLIGHT %d" % inflight_req)
print("RED %s" % ",".join(red))
if trusted and required:
    print("REQRED %s" % ",".join(red_req))
    print("ADVRED %s" % ",".join(red_adv))
    print("REQMISSING %s" % ",".join(missing))
PY
}

# ── chain supervision ────────────────────────────────────────────────────────────────────────────
# ⛔ COUNTER FILES ARE READ WITH A BUILTIN, INCLUDING HERE (round-25 review, P1). `round_of` and the
# watch increment were converted, but the counters DESIDE whether a loop is bounded, and three of those
# reads were still `cat`: a `cat` answering 0 for `*.headmoved` makes "pass 2" unreachable, and one
# answering 0 for `*.apiretry` makes the refund unconditional, so WATCH_F is pinned at 0 and
# BLOCKED_ATTEMPTS can never fire — measured on the shipped carrier with only PATH differing (control:
# 13 after 81 runs; shimmed: 11 for ever, watch=0). A counter is a file read, not a seam: read it with
# `IFS= read -r`, never a PATH-resolved program.
_lm_readint() { # _lm_readint <file> — integer file contents, 0 when absent/blank/unusable
  local _v=0
  [ -f "$1" ] && { IFS= read -r _v < "$1" || true; }
  [ -n "$_v" ] || _v=0
  is_limit "$_v" || _v=0
  printf '%s' "$_v"
}
chain_pid() { local _p=""; [ -f "$CHAIN_F" ] && { IFS= read -r _p < "$CHAIN_F" || true; }; printf '%s' "${_p%% *}"; }
chain_head() { local _p=""; [ -f "$CHAIN_F" ] && { IFS= read -r _p < "$CHAIN_F" || true; }; _p="${_p#* }"; printf '%s' "${_p%% *}"; }
chain_alive() { local p; p="$(chain_pid)"; [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
chain_log() { local _p=""; [ -f "$CHAIN_F" ] && { IFS= read -r _p < "$CHAIN_F" || true; }; _p="${_p#* }"; _p="${_p#* }"; printf '%s' "${_p:-$CHAIN_LOG}"; }

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
  # ⛔ `awk` HERE DECIDED WHICH CHECKOUT IS "TRUSTED", AND `awk` IS PATH-RESOLVED (round-24 review, P2). A
  # shimmed `awk` returning the lane's own worktree defeated the resolver this function exists to make
  # fail-closed — measured: control handed the chain the hub, the awk shim handed it the lane. Parsed with
  # a bash builtin loop instead (the same shape the gate uses for its own resolution). `git` remains the
  # disclosed seam (agent-infra#3789); a field split is not a seam.
  main=""
  while IFS= read -r _stanza; do
    case "$_stanza" in "worktree "*) main="${_stanza#worktree }"; break ;; esac
  done <<< "$(git -C "$lane_real" worktree list --porcelain 2>/dev/null)"
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
# _lm_tree_kind <dir> — ONE of `main` / `flat` / `linked` / `unknown`. The caller decides.
# ⛔ THE QUESTION IS "IS THIS A LANE'S OWN CHECKOUT?", NOT "IS THIS A MAIN WORKTREE?" (fresh-context
# review of #3846, P1-2; MEASURED). The anti-bypass rule from #3789 is "a lane must not merge its PR
# through ITS OWN edited merge gate", and the realistic shape of that attack is a lane editing
# `merge-one.sh` inside its own `.worktrees/tm-<N>` checkout and having the beside-file fallback pick
# it up. A lane checkout is a LINKED worktree. Asking "is it a MAIN worktree" refuses that — and ALSO
# refuses the operator-seeded runtime, which is a FLAT `cp -p` tree with no `.git` at all (the shape
# `deploy-harness.sh` produces), so `git rev-parse --git-dir` failed and EVERY lane on a split box
# exited 2 before any merge work. Measured at the round-10 head: `/home/cmux/orchestrator` (this box's
# real seeded runtime) -> REFUSED; a fresh `cp -p` seed -> REFUSED; the same tree after `git init` ->
# MAIN-YES. The property to refuse is a LINKED worktree, and the caller has already established the
# identity that makes a flat tree trustworthy (`_d` IS the controller-declared harness root).
# Fail-closed the other way round: a tree that carries a `.git` entry but cannot be resolved is
# `unknown`, and cannot-tell is never trust.
_lm_tree_kind() {
  local d="${1:-}" gd="" common="" c=""
  if [ -z "$d" ] || [ ! -d "$d" ]; then printf 'unknown'; return 0; fi
  if ! git -C "$d" rev-parse --git-dir >/dev/null 2>&1; then
    # No readable git dir. A `.git` entry that git REFUSES to read is a tree we cannot classify; a
    # tree with no `.git` at all is the flat seeded runtime, which is the shape this arm exists for.
    if [ -e "$d/.git" ]; then printf 'unknown'; else printf 'flat'; fi
    return 0
  fi
  gd="$(git -C "$d" rev-parse --absolute-git-dir 2>/dev/null)" || { printf 'unknown'; return 0; }
  common="$(git -C "$d" rev-parse --git-common-dir 2>/dev/null)" || { printf 'unknown'; return 0; }
  if [ -z "$gd" ] || [ -z "$common" ]; then printf 'unknown'; return 0; fi
  c="$(cd "$d" 2>/dev/null && cd "$common" 2>/dev/null && pwd -P)" || { printf 'unknown'; return 0; }
  if [ -z "$c" ]; then printf 'unknown'; return 0; fi
  if [ "$gd" = "$c" ]; then printf 'main'; else printf 'linked'; fi
  return 0
}
# _lm_root_trusted <dir> — 0 when <dir> may supply the merge authority.
# ⛔ TRUSTED: `main` (a main checkout — the pre-#2095 shape) and `flat` (the seeded runtime, which is
# what `deploy-harness.sh` produces and what the README's split-state table promotes).
# ⛔ REFUSED: `linked` (a lane's own checkout — #3789) and `unknown` (a `.git` git cannot resolve).
# ⛔ RESIDUAL, STATED RATHER THAN HIDDEN: `flat` is trusted because the caller has already required
# `_d` == the controller-declared `O_WORK`, and that is a DECLARATION a lane can set — so a lane that
# copies a harness into a flat directory and points `O_WORK` at it is not refused by this predicate.
# It was not refused before either (`O_WORK` is exactly as settable as `$O`, whose copy has always
# been the trusted authority, and a lane can write there too); what this predicate closes is the
# REALISTIC shape — the lane's own `.worktrees/<lane>` checkout, which is a linked worktree.
_lm_root_trusted() {
  case "$(_lm_tree_kind "${1:-}")" in
    main|flat) return 0 ;;
    *) return 1 ;;
  esac
}

launch_chain() {
  local head="$1" chain="$O/merge-one.sh" _d="" _o_canon="" _root=""
  # ⛔ `$O` IS THE CONTROLLER'S STATE DIR, AND THE HARNESS ROOT IS A SEPARATE NAME (#2095; fresh-context
  # review of #3846, P1). Since this PR, `orch-loop.sh` exports `O` = the state dir and `O_WORK` = the
  # harness root; on the documented `ORC_STATE_DIR` arrangement, and on every `derived:isolated(<copy>)`
  # instance, `<state>/merge-one.sh` cannot exist and the identity test below compared against a
  # directory the harness never lives in — so EVERY lane on such a box exited 2 before any merge work,
  # with an exit code `lane.sh`'s table does not even map (`:580-591` lists 0/10/15/11/12/13/14) and a
  # remedy (`deploy-harness --o $O`) that would install a whole harness INTO the state dir, undoing the
  # split. `$O/merge-one.sh` is still tried FIRST: the operator-seeded runtime keeps exact priority, so
  # no existing box changes behaviour by one byte.
  _o_canon="$(cd "$O" 2>/dev/null && pwd -P)" || _o_canon="$O"
  _root="$(cd "${O_WORK:-$O}" 2>/dev/null && pwd -P)" || _root=""
  # ⛔ THE FALLBACK MUST RESOLVE TO THE SAME TREE AS $O, NOT WHEREVER THIS FILE WAS INVOKED. $O's copy
# is the operator-seeded authority precisely so a lane cannot choose its own gate — and the natural
# way for a lane to run this script is the checkout copy (`scripts/orchestrator-harness/lane-merge.sh`
# is in its cwd), so an unconditional fallback would let a lane that edited `merge-one.sh` on its own
# branch merge its PR through ITS version of the merge gate. Refuse instead: the lane's remedy is to
# sync the harness, which is safe.
if [ ! -f "$chain" ]; then
  _d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  if [ "$_d" = "$_o_canon" ]; then
    # TODAY'S PATH, UNCHANGED: the state dir IS the seeded runtime.
    chain="$_d/merge-one.sh"
  elif [ -n "$_root" ] && [ "$_d" = "$_root" ] && [ -f "$_root/merge-one.sh" ] && _lm_root_trusted "$_d"; then
    # THE CONTROLLER-DECLARED HARNESS ROOT (#2095). Three conditions: a lane CAN set `O_WORK` itself,
    # so the value alone is not identity — the copy beside the running script must be THAT tree — and
    # #3789 keeps the last one: the tree must not be a LINKED worktree, which is exactly what a lane's
    # own `.worktrees/<lane>` checkout is. A FLAT tree (no `.git`) is the seeded runtime and is
    # accepted; refusing it was the P1-2 defect that made every lane on such a box exit 2.
    chain="$_d/merge-one.sh"
  else
    say_err "lane-merge: no merge authority found — looked in $O/merge-one.sh and in the harness root"
    say_err "  ${_root:-<unresolved>}/merge-one.sh; the copy beside this script ($_d) is neither the"
    say_err "  state dir ($_o_canon) nor the controller-declared harness root ($_root), or it is a"
    say_err "  LINKED worktree / an unreadable git tree, so it may be a lane's own branch. Refusing to"
    say_err "  select the merge authority from it."
    say_err "  If this box keeps its state elsewhere, the harness root must be the tree the controller"
    say_err "  runs from (a main checkout, exported as O_WORK); the remedy is to re-seed THAT tree:"
    say_err "  bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o ${_root:-$O}"
    exit 2
  fi
fi
  if [ ! -f "$chain" ]; then
    say_err "lane-merge: merge-one.sh not found (looked in $O, the harness root ${_root:-<unresolved>}, and"
    say_err "            beside this script) — refusing to hand-roll a merge; redeploy the harness"
    say_err "            (bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o ${_root:-$O})"
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
    local opid; opid="$(_lm_readint "$O/state/mergeclaim-$PR.lock")"
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
    # ⛔ THE MANDATORY LANE REPORT'S REFUSAL IS A FIX DUTY, NOT A BLOCK (#2977). merge-one.sh exits 9
    # with no `needsfix` marker (it must not authorise a code-fixing agent for a report the LANE can fix
    # in place, with no push), so without this arm a refused report classified UNKNOWN and reached the
    # lane as BLOCKED_ATTESTATION (12) — "hand off, only a fresh reviewer can supply this" — about a
    # report the lane itself can re-run. Same writer's-vocabulary rule as the patterns below.
    if tail -n 300 "$mlog" 2>/dev/null | grep -qE '^\[merge [0-9]+\] LANE REPORT REFUSED'; then echo "FIX_REQUIRED"; return; fi
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
    # ⛔ THE BOX ARM MUST NOT RENDER A BUDGET IT DID NOT SPEND (round-21 review, P2). This line was
    # unconditional, so a box-fault hand-off said `Rounds spent: 0/3` beside "the loop is capped by
    # design" — implying this run spent the budget, which is exactly what the box arm exists to avoid.
    if [ "${HANDOFF_NEXT:-}" = "box" ]; then
      printf -- '- Rounds spent: %s/%s — this run spent NONE (a box/repo fault cannot be fixed by a push); rounds already spent by EARLIER runs: %s.\n\n' "$_rs" "$MAX_ROUNDS" "$_rs"
    else
      printf -- '- Rounds spent: %s/%s (the loop is capped by design — a lane in round 5 is a failure, not thoroughness).\n\n' "$_rs" "$MAX_ROUNDS"
    fi
    # ⛔ THE BRANCH MUST BE RESOLVED, NOT A PLACEHOLDER (reviewer finding, P1, R11, measured): the brief's
    # own `--watch` call never passes `--branch`, so `${BR:-<branch>}` rendered the literal `<branch>` on
    # the documented supervision path — and merge-one feeds that argument into
    # `git fetch origin "+refs/heads/$BR:refs/remotes/origin/$BR"` (the shipped form since #3009 named
    # the DESTINATION), so the next holder paid up to 1800s for a reviewer aimed at a ref that does not exist.
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
          box)     printf 'Next: NOTHING you can push. The blocker is the BOX (or its lane-report state),\n'
                   printf 'not this PR, and THIS run spent no fix round — so re-run `%s/lane-merge.sh %s --repo %s`\n' "$O" "$PR" "$OR"
                   printf 'once the box reason named above is repaired. Rounds already spent by earlier\n'
                   printf 'runs are NOT refunded: the cap counts every round on this PR.\n' ;;
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
      # ⛔ THE BOX FOOTER CANNOT SAY "after a fix" (round-21 review, P2): it sat under the box arm and
      # told the next holder to re-run "after a fix" on a fault whose whole point is that no fix exists,
      # contradicting the arm's own "NOTHING you can push" two lines above.
      *)
        if [ "${HANDOFF_NEXT:-}" = "box" ]; then
          printf '\n_Re-run with `%s/lane-merge.sh %s --repo %s` once the BOX reason above is repaired — no push is involved._\n' "$O" "$PR" "$OR"
        else
          printf '\n_Re-run with `%s/lane-merge.sh %s --repo %s` after a fix; a new head re-arms the PR._\n' "$O" "$PR" "$OR"
        fi ;;
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
  local n slug f sha line
  n="$PR"; slug="$(printf '%s' "$OR" | tr '/' '-')"
  for f in "$HOME/.pi/agent/reviews/$slug-$n.json" "$HOME/.pi/agent/reviews/$n.json"; do
    [ -f "$f" ] || continue
    # ⛔ BUILTIN PARSE OF THE ATTESTED HEAD (round-26 review, P3). This used `grep -o … | head -1 |
    # grep -o`, three PATH-resolved programs deciding whether a signed review exists at $HEAD: a shim
    # made a record bound to ANOTHER head read as present (measured: rc=1 → rc=0, "a signed review exists
    # at this head" about a head it never named). The consequence is a mis-grade (exit 12
    # BLOCKED_ATTESTATION → 13 BLOCKED, so the lane loses the exact remedy), not a merge — but it is a
    # decision read, and the rest of this file now reads its state with builtins.
    sha=""
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in *'"head_sha"'*) sha="${line#*\"head_sha\"}"; break ;; esac
    done < "$f"
    sha="${sha#*:}"; sha="${sha#*\"}"; sha="${sha%%\"*}"
    case "$sha" in ''|*[!0-9a-fA-F]*) sha="" ;; esac
    [ "${#sha}" -ge 7 ] || sha=""
    if [ -n "$sha" ] && [ -n "${HEAD:-}" ]; then
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
  # ⛔ SAME RULE AS round_of (round-24 review, P1): the supervision budget is a COUNTER read from a local
  # file, so it is read with a builtin rather than a PATH-resolved `cat` a lane could shim into answering 0.
  w=0; if [ -f "$WATCH_F" ]; then IFS= read -r w < "$WATCH_F" || true; fi; [ -n "$w" ] || w=0; is_limit "$w" || w=0
  w=$(( w + 1 )); printf '%s\n' "$w" > "$WATCH_F"
  # ⛔ THE ALLOWANCE IS RE-DERIVED HERE, FROM THE CLOCK THAT IS ACTUALLY LEFT (#3850 review, P2 — see the
  # block at `MAX_WATCH`'s definition for the derivation and the two bounds it is clamped by). It only ever
  # RAISES the design operand, and it is skipped entirely when an operator pins `LANE_MERGE_MAX_WATCH` (an
  # explicit ceiling is an escape hatch, not a suggestion). A lane with no resolvable clock — the controller
  # re-run — keeps the shipped 7 chunks.
  if [ -z "${LANE_MERGE_MAX_WATCH:-}" ]; then
    _mw_rt="$MAX_WATCH"
    _watch_elapsed="$(lane_elapsed_s)"
    # ⛔ THE WALL AXIS CAN BE OFF, AND THEN THERE IS NO CLOCK TO DERIVE FROM ' SO DO NOT DERIVE FROM THE
    # ZERO (review cycle 13, P2 ' MEASURED: with `LANE_TIMEOUT=0` this block's `-gt 0` guard did not run,
    # leaving the design operand's `MAX_WATCH_FIT`, which the arithmetic floors at ONE chunk ' 120 s of
    # supervision on a lane DOCUMENTED AS UNBOUNDED ' and `--watch` then posted a blocker two minutes into
    # a legitimate chain wait. That is the same 0-semantics inversion this branch fixed for the check wait,
    # one layer down). The backstop lane-bound.sh was armed with is the honest source when the fleet exports
    # it; with neither, supervision is unbounded too (a zero allowance means NO COUNTER, not "spent") and
    # the operator line says which of the two it got.
    if [ "$LANE_WALL_S" -eq 0 ]; then
      if is_limit "${LANE_BACKSTOP_S_N:-}" && [ "${LANE_BACKSTOP_S_N:-0}" -gt 0 ]; then
        # ⛔ AND IT IS THE BACKSTOP THAT IS *LEFT*, NOT THE WHOLE OF IT (review cycle 15, P2 — MEASURED:
        # deriving from the untouched backstop gave a lane with 100 s of its backstop remaining the SAME 22
        # chunks as a fresh lane — 2640 s of supervision against a clock that ends in 100 s, so lane-bound.sh
        # TERMed it mid-supervision with no verdict and no hand-off. That is the very outcome this PR calls
        # "strictly worse than the bound it replaces" for the check wait, and it was reachable only because
        # the finite-wall sibling below subtracts the elapsed time and this branch did not.
        _bt_left=$(( LANE_BACKSTOP_S_N - _hb_margin ))
        if [ -n "$_watch_elapsed" ]; then _bt_left=$(( _bt_left - _watch_elapsed )); fi
        _backstop_fit=$(( _bt_left / _fit_poll ))
        [ "$_backstop_fit" -ge 1 ] || _backstop_fit=1
        _mw_rt="$_backstop_fit"
      else
        _mw_rt=0
      fi
    elif [ -n "$_watch_elapsed" ]; then
      _wall_fit=$(( (LANE_WALL_S - _watch_elapsed - POLL_S) / _fit_poll ))
      [ "$_wall_fit" -gt "$_mw_rt" ] && _mw_rt="$_wall_fit"
    fi
    [ "$_mw_rt" -eq 0 ] || { [ "$_mw_rt" -ge "$MAX_WATCH_FIT" ] || _mw_rt="$MAX_WATCH_FIT"; }   # never below the design floor, unless unbounded
    if [ "$_mw_rt" -gt 0 ] && [ "$IDLE_BOUND_S" -gt 0 ]; then
      _idle_fit=$(( (IDLE_BOUND_S - _hb_margin) / _fit_poll ))
      if [ "$_idle_fit" -ge 1 ] && [ "$_idle_fit" -lt "$_mw_rt" ]; then _mw_rt="$_idle_fit"; fi
    fi
    MAX_WATCH="$_mw_rt"
  fi
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
  # ⛔ A ZERO ALLOWANCE MEANS "NO COUNTER", NOT "SPENT" (the wall axis is OFF and no `LANE_BACKSTOP_S` was
  # exported): without this conjunct the comparison fires on the FIRST chunk for ever, which is the same
  # inversion one more time.
  if [ "$MAX_WATCH" -gt 0 ] && [ "$w" -gt "$MAX_WATCH" ]; then
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
        HANDOFF_NEXT=running post_handoff BLOCKED_ATTEMPTS "supervision allowance spent (${MAX_WATCH} --watch chunks = $(( MAX_WATCH * POLL_S ))s, which is this lane's bound and NOT the chain's own budget of REVIEW_TIMEOUT + the gate wait) while the chain was STILL RUNNING (pid $(chain_pid)) — it may still merge; wait for that pid before re-running"
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
      _hm=$(( $(_lm_readint "$O/state/lanemerge-$PR.headmoved") + 1 ))
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
          _n_ar="$(_lm_readint "$_ar")"
          if [ "$_n_ar" -lt "$MAX_WATCH" ]; then
            _n_ar=$(( _n_ar + 1 )); printf '%s\n' "$_n_ar" > "$_ar" 2>/dev/null || true
            w="$(_lm_readint "$WATCH_F")"
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
# Where the FULL (paginated) check-run read's stderr lands, so a read that stopped early can say why
# (#3858). Separate from CHECK_TMP because that one is the classifier's input.
CHECK_ERR_TMP="$(mktemp "${TMPDIR:-/tmp}/lane-merge-checks-err.XXXXXX")" || { rm -f "$CHECK_TMP"; exit 2; }
trap 'rm -f "$CHECK_TMP" "$CHECK_ERR_TMP"' EXIT
# ⛔ THE WAIT MUST FIT WHAT IS LEFT OF THE LANE'S **REMAINING** WALL CLOCK, NOT JUST THE WHOLE OF IT
# (#3584 review, P1 — verified). `deadline` was `now + WAIT_S` and nothing compared it with how much of
# `LANE_WALL_S` THIS lane had already spent. At the shipped numbers a lane entering its merge phase more
# than ~1800 s into its run (7200 - 5400) was TERMed by `lane-bound.sh`'s WALL ceiling MID-wait: the
# `now >= deadline` arm never ran, so `WAITING_CHECKS` was never emitted, no `lanemerge-<pr>.verdict`
# was written, and `lane.sh` printed "NO merge-phase verdict" over a lane that HAD a labelled hand-off
# available. ⛔ THAT IS STRICTLY WORSE THAN THE 1500 s BOUND THIS CHANGE REPLACES (which reached its own
# deadline for any implementation under 5700 s), and it is this file's own rule — "a bound the lane
# cannot reach is an inert guard" — applied to the number that replaced it. So the wait is clamped to
# the seconds actually LEFT, minus a margin to write the hand-off, which lands the label BEFORE the
# kill. ⛔ THE DESIGN OPERAND IS ALREADY CAPTURED (`WAIT_S_DESIGN` above), so this clamp cannot move the
# supervision budget — same rule as the watchdog cap, for the same reason.
_lane_elapsed="$(lane_elapsed_s)"
_wait_elapsed_note=""
# ⛔ `LANE_TIMEOUT=0` IS "THE WALL AXIS IS OFF", NOT A ZERO-SECOND WAITING BUDGET (#3850 review, P2 —
# verified). `is_limit` accepts `0` as a valid value (by design: it is the harness's OFF switch), and
# `spawn-gate.sh` documents it as exactly that — *"`0` — the documented "wall axis OFF" value — is a
# raise in this sense (unbounded) … the OFF switch remains available … through the caller's own seam,
# `LANE_TIMEOUT=0`"* — while `lane.sh` passes it straight through. Clamped against it, the arithmetic
# below (`0 - elapsed - margin`) goes negative, floors at 0, and the wait becomes ZERO for ever: the
# loop hands off `WAITING_CHECKS` on its FIRST poll, so an unbounded lane can never wait a head out.
# That is the inversion the harness already has a rule about (`spawn-gate.sh`: "a numeric `-le` would
# read it as the largest possible SHORTENING"), so the clamp applies ONLY to a FINITE wall, and the
# unbounded case is disclosed rather than left to be inferred. (External convention agrees: systemd's
# `TimeoutSec=0` disables the timeout, and `systemd#9556` is the bug filed when `0s` was read as a
# zero-second budget instead — the same misreading fixed here.)
if [ "$LANE_WALL_S" -eq 0 ]; then
  # ⛔ NO BACKTICKS INSIDE THIS MESSAGE (review, P2 — verified by running it): in a DOUBLE-QUOTED
  # string a backtick is COMMAND SUBSTITUTION, so a "`--watch`" here executed `--watch`, printed
  # "command not found" to stderr and DELETED the word from the line — corrupting the one message a
  # LANE_TIMEOUT=0 operator reads, on the exact path this branch exists to fix. `bash -n` passes and a
  # prefix-grep arm cannot see it, so `lane-merge.test.sh` now pins "no backtick in any say_err".
  # ⛔ AND IT QUOTES THE DESIGN OPERAND, NOT THE WATCHDOG-CAPPED VALUE (review cycle 13, P3 — measured: it
  # read 10s while the line printed IMMEDIATELY ABOVE it said the wait was capped at 10s, and this line
  # claimed nothing had clamped it). ⛔ AND IT STATES WHAT HAPPENS TO THE SUPERVISION AXIS, which is no
  # longer "floored at one chunk" — see the re-derivation in the `--watch` branch.
  # ⛔ THE PIN IS READ THROUGH A VARIABLE RATHER THAN WITH AN ARITHMETIC DEFAULT: the suite forbids a
  # digit default on this name, because that is exactly how a literal allowance default creeps back in.
  _mw_pin="${LANE_MERGE_MAX_WATCH:-}"
  if is_limit "$_mw_pin" && [ "$_mw_pin" -eq 0 ]; then
    # ⛔ A PIN OF ZERO IS "NO COUNTER", NOT "ZERO CHUNKS" (review cycle 15, P3 — measured: this branch
    # called it "a FINITE 0 chunk(s)" while the code admitted the 1000th chunk, because 0 switches the
    # budget block off). Labelling an unbounded allowance FINITE is the defect class this file keeps fixing.
    _watch_basis_note="an explicit LANE_MERGE_MAX_WATCH=0, which DISABLES the supervision counter"
    _watch_supervision_note="UNBOUNDED (there is no counter to spend)"
  elif is_limit "${LANE_BACKSTOP_S_N:-}" && [ "${LANE_BACKSTOP_S_N:-0}" -gt 0 ]; then
    _watch_basis_note="lane-bound.sh's own backstop (LANE_BACKSTOP_S=${LANE_BACKSTOP_S_N}s), because the wall axis (${LANE_WALL_SRC}) is OFF"
    # ⛔ THE FIGURE MUST BE WHAT THE CODE WILL USE, WHICH INCLUDES THE ELAPSED SUBTRACTION (review cycle
    # 16, P3 — measured: the line printed "a FINITE 29 chunk(s)" on a lane that had spent 3400 s of its 3600 s
    # backstop, where `--watch` derives 1). `_lane_elapsed` is already resolved above for the wait clamp; this
    # is the same datum the `--watch` branch reads as `_watch_elapsed`.
    _backstop_chunks=$(( (LANE_BACKSTOP_S_N - _hb_margin - ${_lane_elapsed:-0}) / _fit_poll ))
    [ "$_backstop_chunks" -ge 1 ] || _backstop_chunks=1
    # ⛔ A PINNED `LANE_MERGE_MAX_WATCH` OVERRIDES THIS NUMBER (review cycle 14, observation 2 — measured:
    # `LANE_BACKSTOP_S=3600 LANE_MERGE_MAX_WATCH=2` printed "a FINITE 29 chunk(s)" while the real allowance
    # was 2). An operator line that states a number the code will not use is the class this branch fixes.
    if is_limit "${LANE_MERGE_MAX_WATCH:-}"; then
      _watch_supervision_note="a FINITE ${LANE_MERGE_MAX_WATCH} chunk(s), because LANE_MERGE_MAX_WATCH pins it"
    else
      if [ -n "${_lane_elapsed:-}" ]; then
        _watch_supervision_note="a FINITE ${_backstop_chunks} chunk(s) derived from what is LEFT of it (${_lane_elapsed}s of this lane's clock already spent), further capped by the watchdog allowance when that is smaller"
      else
        # ⛔ THE RATIONALE MUST MATCH THE NUMBER (review cycle 16, observation): with an unresolvable elapsed
        # it subtracted 0 while still saying "after this lane's elapsed time", which reads as if a subtraction
        # had happened. Same rule as every other line in this file: state what the code did.
        _watch_supervision_note="a FINITE ${_backstop_chunks} chunk(s) derived from it, further capped by the watchdog allowance when that is smaller (this lane's elapsed time could not be resolved, so nothing was subtracted from it)"
      fi
    fi
  else
    # ⛔ THE KNOB NAMED HERE IS THE ONE THAT RESOLVED TO 0, AND THE SENTENCE ABOUT THE BACKSTOP IS A
    # MEASUREMENT, NOT AN ASSUMPTION (review, P3 — MEASURED both ways). `LANE_BACKSTOP_S=0` with
    # `LANE_TIMEOUT` unset resolves `LANE_WALL_S` to 0 FROM THE BACKSTOP, yet this branch announced
    # "LANE_TIMEOUT=0" (a variable never set) and "no LANE_BACKSTOP_S is exported" — while it was
    # exported, as 0. `lane_wall_bound` arms `--wall 0` for that value, so it really is the OFF switch;
    # the line must say so instead of telling an operator to set the knob they already set.
    case "${LANE_WALL_SRC}" in
      LANE_BACKSTOP_S)
        _watch_basis_note="no clock at all, because the wall axis is OFF (LANE_BACKSTOP_S=${LANE_BACKSTOP_S_N} is the same OFF switch lane_wall_bound honours, and LANE_TIMEOUT is unset or empty)" ;;
      *)
        if [ -n "${LANE_BACKSTOP_S_N:-}" ]; then
          _watch_basis_note="no clock at all, because the wall axis is OFF (${LANE_WALL_SRC}=0) and LANE_BACKSTOP_S=${LANE_BACKSTOP_S_N} is the same OFF switch rather than a clock"
        else
          _watch_basis_note="no clock at all, because the wall axis is OFF (${LANE_WALL_SRC}=0) and no LANE_BACKSTOP_S is exported"
        fi ;;
    esac
    _watch_supervision_note="UNBOUNDED (there is no counter to spend)"
  fi
  # ⛔ THE HEADLINE NAMES THE KNOB THAT IS ACTUALLY OFF, NEVER A LITERAL (review, P3 — measured: a
  # `LANE_BACKSTOP_S=0` lane was told "LANE_TIMEOUT=0 is the documented 'wall axis OFF' value" about a
  # variable it never set, on the one line an OFF-axis operator reads). Guarded to a knob NAME so a
  # longer source phrase can never be pasted into an `<operand>=0` sentence.
  _wall_off_knob="LANE_TIMEOUT"
  case "${LANE_WALL_SRC}" in LANE_TIMEOUT|LANE_BACKSTOP_S) _wall_off_knob="${LANE_WALL_SRC}" ;; esac
  say_err "lane-merge: ${_wall_off_knob}=0 is the documented 'wall axis OFF' value (unbounded), not a zero-second budget — the design check wait is ${WAIT_S_DESIGN}s and it is NOT clamped by the wall clock (a WATCHDOG cap may still have reduced it to ${WAIT_S}s, and the line above says so when it did), and no wall ceiling is enforced for this lane. Reading 0 as a zero-second budget would hand off WAITING_CHECKS on the first poll for ever (#3850 review, P2). ⛔ AND NOTE THE OTHER AXIS: the --watch supervision allowance is NOT derived from that zero clock (review cycle 13, P2) — it comes from ${_watch_basis_note}, so it is ${_watch_supervision_note} here. Do not read this line as 'this lane has no bounds at all'."
elif [ -n "$_lane_elapsed" ]; then
  _wall_left=$(( LANE_WALL_S - _lane_elapsed - _hb_margin ))
  [ "$_wall_left" -ge 0 ] || _wall_left=0
  if [ "$WAIT_S" -gt "$_wall_left" ]; then
    WAIT_S="$_wall_left"
    _wait_elapsed_note=" (this lane had already spent ${_lane_elapsed}s of its ${LANE_WALL_S}s clock, so the wait is what was left after a ${_hb_margin}s margin to write the hand-off)"
    say_err "lane-merge: the check wait is CAPPED at ${WAIT_S}s${_wait_elapsed_note}. Uncapped it would out-live the ${LANE_WALL_S}s wall this lane is armed with (from ${LANE_WALL_SRC}), which TERMs the lane with NO verdict file and no WAITING_CHECKS hand-off (#3584 review, P1)."
  fi
else
  # ⛔ THIS MESSAGE IS THE ONE AN OPERATOR ACTUALLY READS, SO IT GETS THE SAME CORRECTION THE CODE GOT
  # (review, P2 — verified): it said "no live run token" and offered "--issue" as an equivalent remedy.
  # Both were wrong once the test became ANCESTRY: a token can exist, be readable and name a LIVE pid and
  # still be rejected for being a non-ancestor (an operator would check `kill -0`, see it alive, and have no
  # way to reconcile that with the message), and `--issue` is what makes the token FINDABLE — it is not
  # what makes it apply, because a controller re-running this script is not under a lane.
  say_err "lane-merge: this lane's elapsed wall-clock time could not be resolved — no run token OF THIS LANE at \$O/logs/lane-${ISSUE:-<issue>}.owner (absent, unreadable, future-dated, or naming a pid that is not an ANCESTOR of this script) and LANE_MERGE_ELAPSED_S is unset or unusable — so the ${WAIT_S}s check wait is NOT clamped to what is left of LANE_WALL_S=${LANE_WALL_S}s, and a lane that entered its merge phase late can be TERMed mid-wait with no verdict (#3584 review, P1). ⛔ THE REMEDY IS LANE_MERGE_ELAPSED_S=<seconds>; --issue only makes the token findable, and a token whose pid is not this script's ancestor is never read as this lane's age."
fi
_wait_t0="$(date +%s)"
deadline=$(( _wait_t0 + WAIT_S ))
while :; do
  # ⛔ A CHECK-RUN READ THAT DID NOT FINISH IS NOT A MEASUREMENT — AND ON THIS LOOP IT FLIPS THE
  # VERDICT (#3858). Both reads below hand their rows to `classify`, which derives GREEN from the rows
  # it is GIVEN (`IF=0` + empty RED over whatever arrived) — so a read that dropped rows drops the
  # PENDING ones with them, a head with queued runs looks terminal-and-clean, and the loop `break`s,
  # which is the ONLY path to `launch_chain`. Measured on a fixture (issue #3858, 2026-11-09): page 2
  # held `redjob failure`, page 1 held one green row, and origin/main launched the merge chain on that
  # unmeasured head; the same fixture with page 2 delivered exited 10 FIX_REQUIRED. The missing page IS
  # the difference between the two verdicts, so this is a false PASS in the merge gate, not a partial
  # log line. The verdict was reproducible because the read's exit status was DISCARDED here and no
  # row count was ever compared with the TOTAL the single-page read had just returned: completeness was
  # assumed from having ASKED for more.
  # ⛔ BOTH HALVES ARE NEEDED AND NEITHER SUBSTITUTES FOR THE OTHER: the exit status catches a read
  # that FAILED (a secondary rate limit, a 502 on page 2, a broken pipe), and the COUNT catches one
  # that exited 0 having silently dropped rows — which is why the exit-status fix alone is not the fix.
  # The count assertion is also the external convention: GitHub's REST check-runs response carries
  # `total_count`, and comparing the flattened row count against it (fail closed on a mismatch) is how
  # a pagination is known to have ended. Same shape this repo's own graph reads adopted — a `truncated:`
  # marker rather than silence.
  # ⛔ FAIL-CLOSED DIRECTION: a truncated/undetermined read is HELD (IF=1, RED empty, retried next
  # poll, reported WAITING_CHECKS at the bound) — the bucket an unreadable classification already uses.
  # It is never green, and the loop's own bound keeps a held head from waiting for ever.
  _read_rc=0
  rows="$(checks_read "$HEAD")"; _read_rc=$?
  # The single-page read carries a TOTAL line so "this page is all of it" is distinguishable from
  # "there is more". Only then pay for the full paginated read (the rare case), and never let the
  # TOTAL line itself reach the classifier — a head with 0 check-runs would otherwise classify as
  # GREEN with an empty red set, which is the "nothing measured is not green" rule this loop holds.
  # NF==2 on the marker as well as the name: a CHECK-RUN may legitimately be named "TOTAL", and it
  # would arrive with 5 fields — matching it here would read a status string as a count.
  total="$(printf '%s\n' "${rows:-}" | awk -F'\t' '$1=="TOTAL" && NF==2 {print $2; exit}')"
  rows="$(printf '%s\n' "${rows:-}" | awk -F'\t' 'NF>=4')"
  _undet=""; _n=0
  if [ "$_read_rc" -ne 0 ]; then
    # A non-zero exit can still have printed rows (the shim writes as it goes), and none of them can
    # be trusted as the whole set. On a SUCCESSFUL single page the TOTAL row is always present, so
    # "no TOTAL and rc 0" is not a reachable state in production and "no TOTAL" needs no arm here.
    _undet="the single-page check-run read FAILED (exit ${_read_rc})"
  elif [ -n "${total:-}" ] && [ "$total" -gt 100 ] 2>/dev/null; then
    : > "$CHECK_ERR_TMP"
    _full_rc=0
    rows="$(checks_read "$HEAD" --full 2>"$CHECK_ERR_TMP")"; _full_rc=$?
    # Count the rows the classifier will actually see (NF>=4, exactly its own predicate). A job name
    # carrying an embedded newline can only ever DEFLATE this count, and a deflated count holds — the
    # safe direction. Growth (check-runs created between the two reads) is expected and allowed.
    _n="$(printf '%s\n' "${rows:-}" | awk -F'\t' 'NF>=4 {n++} END{print n+0}')"
    if [ "$_full_rc" -ne 0 ]; then
      _undet="the FULL (paginated) check-run read FAILED (exit ${_full_rc}) after ${_n} of ${total} rows"
    elif [ "${_n:-0}" -lt "$total" ]; then
      _undet="the FULL (paginated) check-run read returned ${_n} of ${total} rows, so it was TRUNCATED"
    fi
  fi
  if [ -n "$_undet" ]; then
    log_line "… ${_undet} at head ${HEAD:0:12} — a partial read is not a measurement, so this head is HELD (a truncation never reads as green)"
    # Say WHY the read stopped, once: the read's own stderr is the only place that reason exists.
    if [ -s "$CHECK_ERR_TMP" ]; then
      _why="$(head -1 "$CHECK_ERR_TMP" 2>/dev/null)"
      [ -n "$_why" ] && say_err "lane-merge:   the read said: ${_why:0:400}"
    fi
    IF=1; RED=""
  elif [ -z "${rows:-}" ]; then
    # An EMPTY check-run set is not a green set: nothing has been measured. Keep polling (this is
    # the "a queued run is not a green run" rule at its surface), and the bound below reports it.
    log_line "… no check-runs reported for head ${HEAD:0:12} yet — a queued run is not a green run"
    IF=1; RED=""
  else
    printf '%s\n' "$rows" > "$CHECK_TMP"
    classified="$(classify "$CHECK_TMP" "${LM_REQ:-}" "$LM_REQ_TRUSTED")"
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
    # ── THE REQUIRED / ADVISORY SPLIT (#4014). Only present when the contract was READ; when it
    # was not, the classifier prints neither line and `RED_REQ` falls back to the WHOLE red set —
    # the fail-closed default (every check required). A `REQMISSING` name is a required check that
    # has not been published yet, and it is counted as in flight below.
    RED_REQ="$(printf '%s' "$classified" | awk '/^REQRED /{sub(/^REQRED /,""); print}')"
    RED_ADV="$(printf '%s' "$classified" | awk '/^ADVRED /{sub(/^ADVRED /,""); print}')"
    REQ_MISSING="$(printf '%s' "$classified" | awk '/^REQMISSING /{sub(/^REQMISSING /,""); print}')"
    # ⛔ A TRUNCATED SPLIT MUST NOT READ AS "EVERYTHING IS ADVISORY". The two lines above were the
    # classifier's whole contract before #4014, so the guard below still only demands them; the SPLIT
    # is elected here instead — absent, `RED_REQ` reverts to the WHOLE red set, which is the fail-closed
    # direction (every red is a fix round). A crash between the prints lands here, not in a false green.
    if [ "$LM_REQ_TRUSTED" = 1 ] && ! grep -q '^REQRED ' <<<"$classified"; then
      say_err "lane-merge: the classifier printed no required/advisory split — treating EVERY red as required (fail-closed)"
      LM_REQ_TRUSTED=0
    fi
    if [ "$LM_REQ_TRUSTED" != 1 ]; then RED_REQ="${RED:-}"; RED_ADV=""; REQ_MISSING=""; fi
  fi
  [ -n "$RED" ] && { printf '%s\n' "$(printf '%s' "$RED" | tr ',' '\n')" > "$LAST_F"
                     printf '%s\n' "${HD:-${HEAD:-}}" > "$LASTHEAD_F" 2>/dev/null || true; }
  # ⛔ AN ADVISORY RED IS REPORTED, NEVER HIDDEN (#4014). It spends no fix round and is not waited
  # for, but a lane that was told nothing would be the silence this file exists to abolish — and the
  # MERGE decision is still not made here: the chain re-reads the surface through the repo's own
  # authority (see the block that resolves `LM_REQ` above).
  if [ -n "${RED_ADV:-}" ]; then
    log_line "… ADVISORY (not in $OR's required set: ${LM_REQ:-none}) — reported, NOT a fix round and NOT waited for: $(printf '%s' "$RED_ADV" | tr ',' ' ')"
  fi
  if [ -n "${REQ_MISSING:-}" ]; then
    log_line "… required check(s) NOT PUBLISHED YET at head ${HEAD:0:12} — a missing required check is in flight, never green: $(printf '%s' "$REQ_MISSING" | tr ',' ' ')"
  fi
  if [ -n "${RED_REQ:-}" ]; then
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
    emit_fix FIX_REQUIRED "this head's own required checks are RED: $(printf '%s' "$RED_REQ" | tr ',' ' ')"
  fi
  # ⛔ THE WAIT IS ON THE REQUIRED SURFACE (#4014). `IF` is already required-only when the contract
  # was read (untouched otherwise), and an UNPUBLISHED required name is in flight too. Continuing to
  # sit through advisory jobs is the 24-queued-checks tax measured on #12171, and it buys nothing:
  # no merge decision is made here.
  _eff="${IF:-0}"
  if [ -n "${REQ_MISSING:-}" ]; then _eff=$(( _eff + 1 )); fi
  [ "$_eff" = "0" ] && break
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
    # ⛔ THE QUOTED NUMBER IS THE WAIT THAT ACTUALLY RAN, NOT THE CONSTANT (review finding, P3 — the
    # same "quote the operand you measured" rule this file holds elsewhere). `WAIT_S` can now be capped
    # four ways AFTER the constant is read (watchdog allowance, remaining wall clock, a lost heartbeat,
    # the seam), so a line rendered from `WAIT_S` would name a bound that never fired.
    _waited=$(( now - _wait_t0 ))
    # ⛔ A HELD HEAD IS NOT AN IN-FLIGHT ONE (#3858). When the last read could not be completed, the
    # in-flight count is this loop's own placeholder, so quoting it as "still in flight" would report a
    # state nobody measured. Name the read failure instead.
    if [ -n "${_undet:-}" ]; then
      log_line "… this head's checks could NOT be measured after ${_waited}s (${_undet}) — re-run this script; nothing was merged"
      disposition WAITING_CHECKS
      verdict WAITING_CHECKS "check-run read incomplete after ${_waited}s: ${_undet}"
      exit 11
    fi
    log_line "… checks still IN FLIGHT (${IF}) after ${_waited}s — re-run this script; nothing was merged"
    # ⛔ QUOTING `0` IN FLIGHT OVER A REAL CAUSE IS THE SILENCE THIS FILE ABOLISHES (review P1, #4039).
    # An unpublished required check is an IN FLIGHT reason, not an in-flight COUNT, so a bound reached
    # solely because it is missing would otherwise print `(0)` and send the reader after a slow CI run.
    if [ -n "${REQ_MISSING:-}" ]; then
      log_line "… the ONLY thing outstanding is required check(s) not published at this head: $(printf '%s' "$REQ_MISSING" | tr ',' ' ') — a required check that GitHub never reports leaves the merge blocked, so waiting is the correct direction"
    fi
    disposition WAITING_CHECKS
    verdict WAITING_CHECKS "checks still in flight after ${_waited}s${REQ_MISSING:+ (required and unpublished: $(printf '%s' "$REQ_MISSING" | tr ',' ' '))}"
    exit 11
  fi
  # ⛔ WATCHDOG-VISIBLE PROGRESS, EVERY POLL (#3584 review, P1 — measured). `lane_bound`'s only working
  # progress arm for this loop is GROWTH OF THE LANE LOG: the CPU arm cannot see a poll's short-lived
  # `gh`/`python3` child (its time is gone once it exits — see the measurement above). Written BEFORE the
  # sleep so the first poll is already covered, and unconditionally (not only when the count changes),
  # because an unchanged count is exactly the case the watchdog would read as silence.
  if [ -n "$HB_F" ]; then
    printf '[lane-merge] heartbeat %s: %s check(s) in flight at head %s (%ss left in this bound)\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)" "${IF:-?}" "${HEAD:0:12}" \
      "$(( deadline - $(date +%s) ))" >> "$HB_F" 2>/dev/null || {
        say_err "lane-merge: the heartbeat target '$HB_F' became unwritable — progress is no longer visible to lane-bound.sh's ${IDLE_BOUND_S}s allowance; re-run with LANE_MERGE_HB pointing at the lane log."
        HB_F=""
        # ⛔ DETECTING THE LOSS IS NOT ACTING ON IT (review finding, P2 — verified). Clearing `HB_F`
        # stops the heartbeats, but the deadline still held the FULL wait — so the loop went on waiting
        # while visibly silent and was TERMed as `stalled` with no verdict: exactly the outcome the
        # heartbeat exists to prevent, on a path this branch has just PROVEN it is on. The remaining
        # wait is clamped to the watchdog's own allowance measured from NOW (silence starts the moment
        # the last heartbeat landed) minus the same margin, which lands the labelled hand-off before the
        # stall bound instead of after it.
        if [ "$IDLE_BOUND_S" -gt 0 ]; then
          _hb_left=$(( IDLE_BOUND_S - _hb_margin )); [ "$_hb_left" -ge 0 ] || _hb_left=0
          [ "$deadline" -gt $(( now + _hb_left )) ] && deadline=$(( now + _hb_left ))
        fi
      }
  fi
  sleep "$INTERVAL"
done

# Green here MEANS: at least one attempt is completed and no group is red. A head with no
# check-runs at all never reaches this point — it is held in the wait above and reported as
# WAITING_CHECKS at the bound — so "the head was never tested" cannot masquerade as green.

# Green + mergeable → launch the harness chain (fresh reviewer where the repo needs one, the repo's
# own rail where it does not) and hand control to --watch.
#
# ── THE MANDATORY LANE REPORT (#2977) — BEFORE the chain, because the chain is PAID ────────────
# A report that is absent, invalid, red or written at another head is not evidence for the tree about
# to be merged, and a lane whose own evidence says that may not land. 5 and 6 are ABSTENTIONS (this box
# or this repo cannot carry the check) and are logged, never treated as green: collapsing them into a
# pass is how a gate reports coverage it does not have.
#
# ⛔ AN EMPTY BRANCH IS NOT GATED HERE, DELIBERATELY (fresh review, P1 — the guard must not outrank a
# better refusal). `launch_chain` already refuses a missing branch with the ACTIONABLE remedy
# (`WAITING_NO_BRANCH`, exit 2, "pass --branch <name>"), and the gate cannot bind a report to a branch
# it was not given. Running it first would turn that exit 2 into a `FIX_REQUIRED` telling the lane to
# fix CODE over a caller error. The empty-branch arm still refuses in the gate itself, which is where
# merge-one.sh / chain-merge.sh / fix-one.sh reach it.
_lrg_rc=0; _lrg_out=""; _lrg_skip=0
if [ -z "${RESOLVED_BR// /}" ]; then
  : # launch_chain owns the refusal below; nothing to gate, and no chain will launch.
elif [ -n "$LANE_REPORT_GATE" ]; then
  # ⛔ THE VERIFIER MUST NOT COME FROM THE TREE BEING MERGED (fresh review, P2). The gate resolves
  # `tools/worktree_report.py` from the repo it is handed, and `$(pwd)` here is the LANE's own
  # worktree on the branch under review — so a lane could edit the grader that grades it. A trusted
  # (main) checkout is resolved here, once, exactly as `launch_chain` resolves it, so the gate's
  # instrument comes from the tree nobody is merging.
  # ⛔ THAT IS TRUE FOR A LINKED WORKTREE AND FALSE FOR AN INDEPENDENT CLONE (round-19 review, P1).
  # `resolve_trusted_checkout` returns the FIRST `git worktree list` stanza, which for a clone is the
  # clone itself — i.e. the tree under review. So a lane running this script from its own clone still
  # supplies the grader, and the residual is NOT closed here; it is disclosed here, in the gate's own
  # provenance comment, and alongside its siblings in agent-infra#3789. Do not read this block as
  # closing the self-supplied-instrument class.
  # ⛔ AND WHEN THERE IS NO TRUSTED CHECKOUT, THE GATE DOES NOT RUN AT ALL (fresh review, P2). Falling
  # back to the lane checkout made the gate source its verifier from the tree under review and return
  # a self-graded PASS — the bypass this block exists to close, re-reachable on the fallback path. It
  # is skipped instead, and `launch_chain` refuses immediately below (it resolves the same checkout and
  # BLOCKs with the actionable remedy), so no merge can follow a skipped check.
  _lrg_repo="${REPO_PATH:-$(pwd)}"
  _lrg_trusted="$(resolve_trusted_checkout "$_lrg_repo" 2>/dev/null)" || _lrg_trusted=""
  if [ -z "$_lrg_trusted" ]; then
    _lrg_skip=1
    log_line "lane-report: NOT CHECKED — no trusted (main) checkout to source the verifier from (the only reachable copy is the tree under review); launch_chain will refuse this merge."
  else
    _lrg_repo="$_lrg_trusted"
    # ONE run, captured: the verdict line is the diagnosis, and running the gate twice to quote it would
    # pay two git/python invocations per merge for a message.
    _lrg_out="$(lane_report_gate "$_lrg_repo" "$RESOLVED_BR" "$HEAD" 2>&1)" || _lrg_rc=$?
    [ -n "$_lrg_out" ] && log_line "$_lrg_out"
  fi
else
  log_line "lane-report: NOT CHECKED — lane-report-gate.sh is not deployed (looked beside this script and in \$O=$O). The mandatory lane report (#2977) is NOT verified on this box; redeploy the harness."
  _lrg_rc=5
fi
# ⛔ THE CASE RUNS ONLY WHEN THE GATE RAN: with no branch, `_lrg_rc` is 0 and this block would CLAIM a
# verification that never happened. The branchless path falls straight through to `launch_chain`, which
# refuses before anything merges.
if [ -n "${RESOLVED_BR// /}" ] && [ "$_lrg_skip" = 0 ]; then
  case "$_lrg_rc" in
    0)  log_line "lane-report: verified at head ${HEAD:0:12} — the report describes the tree being merged" ;;
    5|6) log_line "lane-report: NOT ENFORCED here (rc=$_lrg_rc) — an abstention, not a green: this box/repo cannot carry the check" ;;
    # ⛔ 7 IS A BAG, NOT A FAULT CLASS (round-20 review, P1), AND THE SPLIT IS BY REASON TOKEN, NOT BY
    # SUBSTRING OF THE LINE (round-21 review, P1). The gate renders LANE-CHOSEN values on the same line
    # (`branch=$branch worktree=$wt … reason=…`), and a lane creates its own branch, so
    # `git check-ref-format --branch 'fix/2977-reason=no-interpreter-at-or-above-python-3.12'` is legal.
    # Matching the raw line therefore let a lane whose fault was `writer-state-absent` (lane-fixable)
    # select the BOX arm — no round spent, `BLOCKED_ATTEMPTS`, "nothing you can push" — and the 3-round
    # cap never fired for a fault the lane owned. Measured: same reason, only the branch differs →
    # RC=14/round-none vs RC=10/round-1. So the reason VALUE is extracted and compared EXACTLY.
    # ⛔ TWO DEFENCES, BECAUSE ORDERING ALONE IS NOT ONE (round-22 review, P1). `##*reason=` takes the
    # LAST occurrence, so ANY lane-chosen value carrying the literal `reason=` can win — a worktree PATH
    # is as lane-controlled as a branch name, and one emit rendered `state=$wt/…` after the token
    # (measured: worktree `…/lane-wt-reason=no-interpreter-…` → the extracted token was the path tail →
    # box arm, 14, round 0). (a) `reason=` is now the LAST lane-influenced field on every emit, pinned by
    # a gate-suite row; (b) the count of `reason=` tokens is checked, and anything but exactly ONE is
    # LANE-fixable — so a future emit that reintroduces the ordering defect, and any spoof, costs the
    # lane a round instead of buying it the no-round arm. The budget is the thing an attacker would want
    # to preserve, so refusing to preserve it is the fail-safe polarity.
    # ⛔ THE LANE-CLEARABLE SET IS THE EXPLICIT LIST; every other 7 is the box/caller arm. That default
    # is deliberate: a NEW reason that a lane could clear would at worst hand off with the token printed
    # (recoverable, and the message says so), whereas defaulting the other way burns a lane's rounds on
    # what no push can change — the round-19 defect. The evaluable set is `writer-state-*`,
    # `worktree-registered-but-unreadable`, and the three report/worktree-placement arms, whose remedies
    # are all one `git switch` or one `run` away (`lane_report_remedy 7`).
    7)  # ⛔ THE WITNESS LINE IS CUT WITH A BUILTIN, NOT `tail` (round-23 review, P1). `lane-merge.sh` sets
        # no PATH, and a lane runs this carrier itself — the gate's own threat premise — so a 7-line `tail`
        # shim could author the line this decision reads: keep only lines containing `VERDICT=UNMEASURABLE`
        # and replace them with a box reason, and the whole reason-token split (round 22), INCLUDING its
        # `reason=` count, is computed over text the lane wrote. Measured on the fixture with only PATH
        # differing: control 10/FIX_REQUIRED/round 1, shimmed 14/BLOCKED_ATTEMPTS/round 0. `${var##*$'\n'}`
        # is a pure parameter expansion: no program, nothing to shim.
        _lrg_line="${_lrg_out##*$'\n'}"
        # ⛔ A LINE WITH MORE THAN ONE `reason=` IS AMBIGUOUS AND IS TREATED AS LANE-FIXABLE (round-22
        # review, P1). Nothing in the gate promises the token is unique — every lane-chosen value is a
        # candidate (`branch`, `worktree`, a path in `state=`), and a path or branch containing
        # `reason=no-interpreter-…` makes `##*reason=` resolve to the PATH TAIL rather than the verdict.
        # Fixing the ordering on all 32 emit sites is necessary but not sufficient, because a future emit
        # can reintroduce it. So ambiguity is DETECTED: a spoof attempt then costs the lane a fix round
        # instead of buying it the no-round arm, which is the fail-safe polarity (the round budget is the
        # thing an attacker would want to preserve, and this refuses to preserve it).
        _lrg_norsn="${_lrg_line//reason=/}"
        _lrg_nrsn=$(( (${#_lrg_line} - ${#_lrg_norsn}) / 7 ))
        _lrg_rsn="${_lrg_line##*reason=}"; _lrg_rsn="${_lrg_rsn%%[[:space:]]*}"
        if [ "$_lrg_nrsn" != 1 ]; then
          log_line "⛔ lane-report: UNMEASURABLE (rc=7) — the verdict line carries $_lrg_nrsn 'reason=' tokens, so its cause cannot be read unambiguously. A LANE-chosen field (branch, worktree or a path) is spoofing the token. Treated as LANE-fixable so the round budget is never handed to a spoof."
          lane_report_remedy 7 2>/dev/null || true
          emit_fix FIX_REQUIRED "the lane report verdict line is ambiguous ($_lrg_nrsn reason= tokens): $_lrg_line"
        fi
        case "$_lrg_rsn" in
          writer-state-*|worktree-registered-but-unreadable|evidence-present-on-this-box-but-no-worktree-is-registered-on-this-branch|worktree-at-this-head-is-not-registered-on-this-branch-and-holds-no-report|this-box-holds-the-report-for-this-branch-in-a-worktree-that-is-not-at-the-merging-head)
            log_line "⛔ lane-report: UNMEASURABLE (rc=7, reason=$_lrg_rsn) — a LANE-fixable condition, so a fix round is spent."
            lane_report_remedy 7 2>/dev/null || true
            emit_fix FIX_REQUIRED "the lane report could not be verified (rc=7, reason=$_lrg_rsn): $_lrg_line" ;;
          *)
            log_line "⛔ lane-report: UNMEASURABLE (rc=7, reason=$_lrg_rsn) — a BOX/REPO/CALLER fault. No fix round is spent: nothing a push does can clear it."
            lane_report_remedy 7 2>/dev/null || true
            HANDOFF_NEXT=box emit_blocked BLOCKED_ATTEMPTS "the lane report cannot be verified on this box (rc=7, reason=$_lrg_rsn): $_lrg_line" ;;
        esac ;;
    *)  log_line "⛔ lane-report: REFUSED (rc=$_lrg_rc) — the mandatory lane report does not support merging head ${HEAD:0:12}"
        lane_report_remedy "$_lrg_rc" 2>/dev/null || true
        emit_fix FIX_REQUIRED "the lane report does not support this merge (rc=$_lrg_rc): ${_lrg_out##*$'\n'}" ;;
  esac
fi

launch_chain "$HEAD" || exit 2
log_line "… the merge chain owns PR #$PR now. Next: lane-merge.sh $PR --watch (bounded chunk; repeat)"
exit 11
