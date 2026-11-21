#!/usr/bin/env bash
# fix-one-prresolve.test.sh — a fixer must REFUSE a number that is not a PR, and must never present a
# FAILED review read as "the review" (agent-infra#4182 arm 3, #3608 / #3937).
#
# THE MEASURED FAILURE (this box, 2026-11-21). A fixer lane was dispatched for "PR #3301 in
# daniel-ospina/agent-infra". #3301 is an ISSUE. Nothing in the dispatch path noticed:
#   $ gh pr view 3301 --repo daniel-ospina/agent-infra --comments
#   GraphQL: Could not resolve to a PullRequest with the number of 3301. (repository.pullRequest)
# so the handed branch (`fix/3301-worktree-reap-on-exit`) existed at origin/main's tip with ZERO
# commits, `logs/fix-3301-comments.txt` held exactly that GraphQL line, the required-check read had
# also failed, and the brief the lane read still asserted "A fresh-context reviewer found real
# issues". Its own staleness guard rendered as `THIS head (``)` because `$HEAD` was empty, so the one
# sentence that could have exposed the mismatch was blanked by the same failed read. A lane that
# obeys that brief fixes nothing, reports success, and pushes to a branch no PR tracks (#4182).
#
# ⛔ WHY THE REFUSAL IS A POSITIVE IDENTIFICATION, NOT A MESSAGE MATCH (fresh-context plan review, P1 —
# VERIFIED). The first version keyed on gh's WORDING. That is defeated on the boxes where this actually
# happens: `fix-one.sh:56` prepends `$O/gh-rest` to PATH, `number` is in that shim's `PR_FIELDS`, and its
# `pr view --json` arm serves the read over REST — where a 404 arrives as `gh-rest: API error: Not
# Found`, not the GraphQL sentence. Upstream gh gives no help either: `gh help exit-codes` documents ONE
# generic code for "fails for any reason". A second attempt used `refs/pull/<N>/head`, which is a network
# round trip in a dispatch path and a GitHub-only convention. So the guard refuses only when gh can still
# read the ISSUE of that number while it cannot produce a PR — the measured class itself ("the number is
# an ISSUE") — and the arms below prove both that refusal and every case where it must NOT refuse.
#
# WHAT IS PINNED — every arm drives the SHIPPED blocks, extracted from fix-one.sh between their own
# `[fixgate-prresolve:…]` / `[fixgate-reviewread:…]` markers, never a re-typed copy of the rule:
#   0  both blocks are extractable (pre-fix code has neither marker, so this FAILS rather than
#      passing vacuously), and the refund block this suite drives is extractable too.
#   1  both reads negative → REFUSED with the dedicated DISPATCH code (86, not the cannot-verify 78),
#      the reason names both facts, and the booked `fixcount` attempt is REFUNDED.
#   2  the REST wording a `gh-rest` box produces is NOT required to match — the same two negatives
#      refuse on it (the arm that would have caught the wording-only version).
#   3  gh unreadable but the `refs/pull` ref EXISTS → NO refusal (the ordinary "gh budget spent"
#      dispatch, #4182 arm 2, must still run).
#   4  a gh failure whose TEXT mentions the refusal phrase, with the ref present → NO refusal. Message
#      text cannot decide this; this is the declared-class-(iv) arm.
#   5  neither probe can answer → NO refusal (an unreadable read is not an absence), and the reason
#      says so.
#   6  the PR exists but its head read came back EMPTY → no refusal, and the brief's head is rendered
#      as UNKNOWN rather than the blank `THIS head ()` that hid the mismatch.
#   7  a head was read → neither probe is made (no extra gh call, no extra ls-remote per dispatch).
#   8  the review read SUCCEEDS → the comments land verbatim, there is no NOT-A-REVIEW header, and
#      the brief's lead still says a reviewer found issues.
#   9  the review read FAILS → the artifact's FIRST line says it is not a review, the failure text is
#      still visible below it, and the brief's lead does NOT assert a review exists.
#  10  the raw file never survives the block (success and failure alike).
#  11  the rendered brief carries the OBSERVED lead and the OBSERVED head — the unconditional
#      sentence and the bare `($HEAD)` both appear exactly once, where they are computed.
#
# Run:  bash scripts/orchestrator-harness/fix-one-prresolve.test.sh

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
FIXER="$HERE/fix-one.sh"
[ -r "$FIXER" ] || { echo "FATAL: fix-one.sh not found beside this test ($FIXER)" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/fix-one-prresolve.XXXXXX")" || { echo "FATAL: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$T"' EXIT
pass=0 fail=0
ok()  { printf '  ✅ %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  ❌ %s\n' "$1"; fail=$((fail+1)); }
ck()  { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi; }

# ── 0. extract the SHIPPED blocks ──────────────────────────────────────────────────────────────
sed -n '/\[fixgate-prresolve:begin\]/,/\[fixgate-prresolve:end\]/p' "$FIXER" > "$T/prresolve.sh"
sed -n '/\[fixgate-reviewread:begin\]/,/\[fixgate-reviewread:end\]/p' "$FIXER" > "$T/reviewread.sh"
sed -n '/\[fixgate-refund:begin\]/,/\[fixgate-refund:end\]/p' "$FIXER" > "$T/refund.sh"
# ⛔ REFUSE, DO NOT CONTINUE: with an absent/emptied block every driver arm below would pass
# vacuously — the pre-fix file has no markers at all, so this is the arm that makes the suite
# FAIL on it instead of reporting a green it never earned.
for pair in "prresolve.sh:PR_RESOLVE_UNKNOWN" "reviewread.sh:FIX_REVIEW_LEAD" "refund.sh:refund_gate_attempt"; do
  f="${pair%%:*}"; needle="${pair#*:}"
  if [ ! -s "$T/$f" ]; then
    bad "0) $f is EMPTY — fix-one.sh lost its $needle block (no markers), so every arm below would pass vacuously"
    echo "───────────────────────────────────────────────────────────────────"
    echo "❌ fix-one PR-resolution/review-read suite: the block is not extractable — refusing to run arm 1+"
    exit 1
  fi
  grep -qF -e "$needle" "$T/$f"
  ck "0) $f is extractable and still carries '$needle' ($(wc -l < "$T/$f" | tr -d ' ') lines)" $?
done
bash -n "$FIXER"; ck "0) fix-one.sh still parses" $?
# the wording-only version this suite was written against after review: a message matcher is what the
# shim defeats, so its ABSENCE is pinned too (a revert to it re-introduces the P1).
# CODE lines only: the comment block above the guard may legitimately QUOTE the wording it explains
# (that is how a reader learns why it is not matched), so prose is excluded rather than silenced.
if grep -v '^[[:space:]]*#' "$T/prresolve.sh" | grep -qF 'Could not resolve to a PullRequest'; then
  bad "0) the guard still matches gh's WORDING — the gh-rest shim serves this read over REST, so that matcher never fires on the boxes that hit it"
else
  ok "0) the guard decides on reads, not on gh's wording (no GraphQL-phrase matcher in executable code)"
fi
if grep -v '^[[:space:]]*#' "$T/prresolve.sh" | grep -qF 'ls-remote'; then
  bad "0) the guard still makes a refs/pull round trip — a network call in the dispatch path (and 41 fixture runs of spawn-gate.test.sh went red on it)"
else
  ok "0) no network probe: the guard decides from gh reads only"
fi

# ── the driver for the PR-existence block ──────────────────────────────────────────────────────
# run_pr <head> <pr_rc> <pr_out> <issue_rc> <issue_out>
#   → $T/run/{rc,unknown,head12,refunded,ghcalls} + $T/run/o/logs/fix-3301.log
run_pr() {
  local head="${1-}" pr_rc="${2:-0}" pr_out="${3-}" issue_rc="${4:-0}" issue_out="${5-}" d="$T/run"
  rm -rf "$d"; mkdir -p "$d/o/state" "$d/o/logs"
  printf '1\n' > "$d/o/state/fixcount-3301"
  (
    set -u
    O="$d/o"; L="$d/o/logs/fix-3301"; PR=3301; OR=daniel-ospina/agent-infra; HEAD="$head"; CTRL=1
    : > "$L"
    GH_CALLS="$d/ghcalls"; : > "$GH_CALLS"
    # `pr view` and `issue view` answer independently — that asymmetry IS the guard's evidence, so the
    # stub models the two subcommands rather than one "gh fails" switch.
    gh() {
      printf '%s\n' "$*" >> "$GH_CALLS"
      case "$*" in
        'pr view '*|'pr view'*) [ -n "$pr_out" ] && printf '%s\n' "$pr_out"; return "$pr_rc" ;;
        'issue view '*|'issue view'*) [ -n "$issue_out" ] && printf '%s\n' "$issue_out"; return "$issue_rc" ;;
        *) return 1 ;;
      esac
    }
    # spawn-gate.sh's predicate, which the refund block uses; the stub keeps this suite hermetic.
    is_num() { case "${1-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
    . "$T/refund.sh" >/dev/null 2>&1
    . "$T/prresolve.sh" >/dev/null 2>&1
    printf '%s\n' "${PR_RESOLVE_UNKNOWN-}" > "$d/unknown"
    printf '%s\n' "${HEAD12_DISPLAY-}" > "$d/head12"
  )
  printf '%s\n' "$?" > "$d/rc"
  printf '%s\n' "$(cat "$d/o/state/fixcount-3301" 2>/dev/null)" > "$d/refunded"
}
LOG="$T/run/o/logs/fix-3301.log"

# 1. the number IS an issue — the measured case (gh issue view answers, gh pr view cannot)
run_pr "" 1 "GraphQL: Could not resolve to a PullRequest with the number of 3301. (repository.pullRequest)" 0 '{"number":3301}'
ck "1) a number that is an ISSUE is REFUSED with the DISPATCH code 86 (got rc=$(cat "$T/run/rc"))" \
   "$([ "$(cat "$T/run/rc")" = 86 ] && echo 0 || echo 1)"
grep -qF 'it DOES have an ISSUE with that number' "$LOG"
ck "1) the refusal names the POSITIVE evidence (an issue exists, a PR does not)" $?
grep -qF 'DISPATCH defect' "$LOG"
ck "1) the log says why it is not a repair (so the next reader does not re-derive it)" $?
grep -qx '0' "$T/run/refunded"
ck "1) the booked attempt is REFUNDED (fixcount 1 -> $(cat "$T/run/refunded"))" $?
ck "1) it is NOT the cannot-verify code 78 (whose remedy is a redeploy, not a re-dispatch)" \
   "$([ "$(cat "$T/run/rc")" != 78 ] && echo 0 || echo 1)"

# 2. the REST wording a gh-rest box produces needs no special case (the arm the P1 was about)
run_pr "" 1 "gh-rest: API error: Not Found" 0 '{"number":3301}'
ck "2) the REST/shim wording ('gh-rest: API error: Not Found') also REFUSES (rc=$(cat "$T/run/rc"))" \
   "$([ "$(cat "$T/run/rc")" = 86 ] && echo 0 || echo 1)"

# 3. gh unreadable and the issue probe cannot answer either — must NOT refuse (the over-block arm)
run_pr "" 1 "gh: HTTP 403: API rate limit exceeded for user ID 1 (https://api.github.com/graphql)" 1 "gh: HTTP 403: API rate limit exceeded"
ck "3) an UNREADABLE pair does NOT refuse (rc=$(cat "$T/run/rc"))" \
   "$([ "$(cat "$T/run/rc")" != 86 ] && echo 0 || echo 1)"
grep -qF 'did not identify it either' "$T/run/unknown"
ck "3) and it is recorded as an unreadable read, never as a missing PR" $?
grep -qx '1' "$T/run/refunded"
ck "3) nothing is refunded for a run that proceeds (fixcount still $(cat "$T/run/refunded"))" $?

# 4. declared threat class (iv): gh PR text mentions the phrase, no issue identified → no refusal
run_pr "" 1 "GraphQL: Could not resolve to a PullRequest with the number of 3301. (repository.pullRequest)" 1 "gh-rest: API error: Not Found"
ck "4) message TEXT cannot decide it — the phrase alone does NOT refuse (rc=$(cat "$T/run/rc"))" \
   "$([ "$(cat "$T/run/rc")" != 86 ] && echo 0 || echo 1)"

# 5. the PR exists but the head read is empty — no refusal, and the brief renders UNKNOWN
run_pr "" 0 '{"number":3301}' 1 "unused"
ck "5) an empty head on a REAL PR does not refuse (rc=$(cat "$T/run/rc"))" \
   "$([ "$(cat "$T/run/rc")" != 86 ] && echo 0 || echo 1)"
grep -qF 'staleness guard cannot name this head' "$T/run/unknown"
ck "5) the recorded reason names the BLANKED staleness guard instead of claiming a head" $?
grep -qF 'UNKNOWN' "$T/run/head12"
ck "5) and the brief's head renders as UNKNOWN, not as the blank 'THIS head ()'" $?

# 6. a head was read — neither probe may cost a call per dispatch
run_pr "0123456789abcdef0123456789abcdef01234567" 0 "" 0 ""
ck "6) no probe when the head is already known (gh calls: $(wc -l < "$T/run/ghcalls"))" \
   "$([ ! -s "$T/run/ghcalls" ] && echo 0 || echo 1)"
ck "6) and nothing is recorded as UNKNOWN on the ordinary path" \
   "$([ -z "$(cat "$T/run/unknown")" ] && echo 0 || echo 1)"
grep -qF '0123456789abcdef0123456789abcdef01234567' "$T/run/head12"
ck "6) the brief's head is the head that was read" $?

# ── the driver for the review-read block ──────────────────────────────────────────────────────
# run_review <gh_rc> <payload>   → $T/run/o/logs/fix-3301{,-comments.txt,-comments.raw} + $T/run/lead
run_review() {
  local gh_rc="$1" payload="$2" d="$T/run"
  rm -rf "$d"; mkdir -p "$d/o/logs"
  (
    set -u
    O="$d/o"; L="$d/o/logs/fix-3301"; PR=3301; OR=daniel-ospina/agent-infra
    : > "$L"
    gh() { printf '%s\n' "$payload"; return "$gh_rc"; }
    . "$T/reviewread.sh" >/dev/null 2>&1
    printf '%s\n' "$FIX_REVIEW_LEAD" > "$d/lead"
  )
}

# 8. a readable review is delivered verbatim and the brief still promises a review
run_review 0 '### 1. P1 — the thing
Fix: do the thing.'
grep -qF 'P1 — the thing' "$T/run/o/logs/fix-3301-comments.txt"
ck "8) a successful read lands the comments verbatim in the findings file" $?
grep -qF 'NOT A REVIEW' "$T/run/o/logs/fix-3301-comments.txt"
ck "8) and it carries NO 'this is not a review' header" "$([ $? -ne 0 ] && echo 0 || echo 1)"
grep -qF 'found real issues' "$T/run/lead"
ck "8) the brief's lead still says a reviewer found issues (nothing was weakened)" $?
[ -e "$T/run/o/logs/fix-3301-comments.raw" ]
ck "8) the raw read does not survive the block" "$([ $? -ne 0 ] && echo 0 || echo 1)"

# 9. an unreadable review must SAY SO — in the artifact AND in the brief
run_review 1 'GraphQL: Could not resolve to a PullRequest with the number of 3301. (repository.pullRequest)'
head -1 "$T/run/o/logs/fix-3301-comments.txt" | grep -qF 'THIS FILE IS NOT A REVIEW'
ck "9) the artifact's FIRST LINE says it is not a review (the measured case)" $?
grep -qF 'Could not resolve to a PullRequest' "$T/run/o/logs/fix-3301-comments.txt"
ck "9) the failure text is still visible below the header (not swallowed)" $?
grep -qF 'THE REVIEW COULD NOT BE READ' "$T/run/lead"
ck "9) the brief's lead says the review could not be read" $?
grep -qF 'found real issues' "$T/run/lead"
ck "9) and the lead no longer asserts a review it never read" "$([ $? -ne 0 ] && echo 0 || echo 1)"
[ -e "$T/run/o/logs/fix-3301-comments.raw" ]
ck "9) the raw read does not survive this arm either" "$([ $? -ne 0 ] && echo 0 || echo 1)"
grep -qF 'marked NOT-A-REVIEW' "$T/run/o/logs/fix-3301.log"
ck "9) the WARN is in the worker log (so the dispatch defect is findable afterwards)" $?

# ── 11. the rendered brief is the OBSERVED lead and the OBSERVED head ─────────────────────────
n="$(grep -cF 'A fresh-context reviewer found real issues' "$FIXER")"
ck "11) the unconditional sentence survives exactly ONCE, where the lead is computed (found $n)" \
   "$([ "$n" = 1 ] && echo 0 || echo 1)"
_briefline="$(grep -F 'You are a FIX agent for branch' "$FIXER" || true)"
case "$_briefline" in
  *'$FIX_REVIEW_LEAD'*) ok "11) the fixer brief renders \$FIX_REVIEW_LEAD, not a literal claim" ;;
  *) bad "11) the fixer brief does not render \$FIX_REVIEW_LEAD — the unconditional claim is back" ;;
esac
n="$(grep -cF 'THIS head (`$HEAD`)' "$FIXER")"
ck "11) no brief sentence prints a bare \$HEAD any more (found $n — it rendered '()' when the read failed)" \
   "$([ "$n" = 0 ] && echo 0 || echo 1)"
n="$(grep -cF '$HEAD12_DISPLAY' "$FIXER")"
ck "11) both head sentences render \$HEAD12_DISPLAY (found $n, want >= 2)" \
   "$([ "$n" -ge 2 ] && echo 0 || echo 1)"

echo "───────────────────────────────────────────────────────────────────"
if [ "$fail" -eq 0 ]; then
  echo "✅ fix-one PR-resolution/review-read suite: all $pass check(s) passed"
  exit 0
fi
echo "❌ fix-one PR-resolution/review-read suite: $fail failure(s), $pass passed"
exit 1
