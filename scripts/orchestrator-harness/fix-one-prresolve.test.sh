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
# WHAT IS PINNED — every arm drives the SHIPPED blocks, extracted from fix-one.sh between their own
# `[fixgate-prresolve:…]` / `[fixgate-reviewread:…]` markers, never a re-typed copy of the rule:
#   0  both blocks are extractable (pre-fix code has neither marker, so this FAILS rather than
#      passing vacuously), and the refund block this suite drives is extractable too.
#   1  gh says the number is not a PR → REFUSED, exit 78, the reason names the dispatch defect, and
#      the booked `fixcount` attempt is REFUNDED (a dispatch defect must not burn a repair round).
#   2  gh CANNOT answer (rate limit / auth / timeout) → NO refusal. This is the over-block arm: the
#      ordinary "gh budget was spent" dispatch (#4182 arm 2) must still run, and it is recorded as
#      UNKNOWN instead.
#   3  the PR exists but its head read came back EMPTY → no refusal, nothing refunded, and the
#      recorded reason names the blanked staleness guard (#4182 arm 2) rather than claiming a head.
#   4  a head was read → the probe is not even made (no extra gh call per dispatch).
#   5  the review read SUCCEEDS → the comments land verbatim, there is no NOT-A-REVIEW header, and
#      the brief's lead still says a reviewer found issues.
#   5b a read that SUCCEEDED and delivered NOTHING is marked NOT-A-REVIEW on its first line and the
#      brief stops asserting findings (#4190 review F2, P1). Redirected, `gh pr view --comments`
#      prints ONLY comments and reviews, so a PR with none yields exit 0 AND ZERO BYTES — which the
#      pre-fix lead presented as "a fresh-context reviewer found real issues" over an empty file.
#   5c content WITHOUT a findings heading gets a lead that says none was DETECTED — never a claim of
#      findings, and never the stronger, false claim that the PR carries no review (#4190 review F2).
#   6  the review read FAILS → the artifact's FIRST line says it is not a review, the failure text is
#      still visible below it, and the brief's lead does NOT assert a review exists.
#   7  the raw file never survives the block (success and failure alike).
#   8  the rendered brief carries the OBSERVED lead, not the unconditional sentence — the literal
#      appears exactly once in fix-one.sh (where the lead is computed) and the brief line reads
#      `$FIX_REVIEW_LEAD`.
#   9  the brief's two STALENESS GUARDS render the head it was given — RENDERED for real, not
#      grepped: a known head appears in both, and an empty one renders `UNKNOWN — <reason>` in both
#      instead of the blank `THIS head (``)` the pre-fix template produced (#4190 review F1, P2).
#  10 the suite POLICES ITSELF: no `ck` row may pass a bare last-command status while its own
#      message runs a command substitution. That shape is DEAD — the substitution's status is what
#      `$?` then holds — and it is what made 7 of these 36 checks unable to fail (#4190 review F1).
#
# ⛔ ARM 10 EXISTS BECAUSE THE FAILURE WAS MEASURED, NOT IMAGINED. At 6ec6eb79e3b5 five executed
# mutants each left this suite 36/36 GREEN and printed a ✅ whose own annotation contradicted it:
#   refund call DELETED            → "✅ 1) the booked attempt is REFUNDED (fixcount 1 -> 1)"
#   refund added to the PROCEEDING path → "✅ 2) nothing is refunded … (fixcount still 0)"
#   refund_gate_attempt renamed    → "✅ 0) … still carries 'refund_gate_attempt'"
#   FIX_BRIEF_HEAD blanked (×2)    → "✅ 3) … never a blank ()…" / "✅ 4) … the head that was read ()"
# The security of a mutation table is only as good as the status it actually reads.
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
# The fixer BRIEF itself, for arm 9: rendered from the shipped template exactly as fix-one-brief.test.sh
# does it, so the head rendering is exercised through fix-one.sh's own code rather than a re-typed copy.
awk '/cat > "\$L-fixer.txt" <<EOF/{f=1} f{print} f&&/^EOF$/{exit}' "$FIXER" > "$T/briefregion.sh"
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
  grep -qF -e "$needle" "$T/$f"; _rc=$?
  ck "0) $f is extractable and still carries '$needle' ($(wc -l < "$T/$f" | tr -d ' ') lines)" "$_rc"
done
bash -n "$FIXER"; ck "0) fix-one.sh still parses" $?

# ── the driver for the PR-existence block ──────────────────────────────────────────────────────
# run_pr <head> <gh_rc> <gh_out>   → $T/run/{rc,unknown,refunded,ghcalls,log}
run_pr() {
  local head="${1-}" gh_rc="${2:-0}" gh_out="${3-}" d="$T/run"
  rm -rf "$d"; mkdir -p "$d/o/state" "$d/o/logs"
  printf '1\n' > "$d/o/state/fixcount-3301"
  (
    set -u
    O="$d/o"; L="$d/o/logs/fix-3301"; PR=3301; OR=daniel-ospina/agent-infra; HEAD="$head"; CTRL=1
    : > "$L"
    GH_CALLS="$d/ghcalls"; : > "$GH_CALLS"
    gh() { printf '%s\n' "$*" >> "$GH_CALLS"; [ -n "$gh_out" ] && printf '%s\n' "$gh_out"; return "$gh_rc"; }
    # spawn-gate.sh's predicate, which the refund block uses; the stub keeps this suite hermetic.
    is_num() { case "${1-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
    . "$T/refund.sh" >/dev/null 2>&1
    . "$T/prresolve.sh" >/dev/null 2>&1
    printf '%s\n' "${PR_RESOLVE_UNKNOWN-__unset__}" > "$d/unknown"
    printf '%s\n' "${FIX_BRIEF_HEAD-__unset__}" > "$d/briefhead"
  )
  printf '%s\n' "$?" > "$d/rc"
  printf '%s\n' "$(cat "$d/o/state/fixcount-3301" 2>/dev/null)" > "$d/refunded"
}

# 1. the number is not a PR — the measured case
run_pr "" 1 "GraphQL: Could not resolve to a PullRequest with the number of 3301. (repository.pullRequest)"
ck "1) a not-a-PR number is REFUSED with exit 78 (got rc=$(cat "$T/run/rc"))" \
   "$([ "$(cat "$T/run/rc")" = 78 ] && echo 0 || echo 1)"
grep -qF 'REFUSED' "$T/run/o/logs/fix-3301.log" && grep -qF 'no pull request numbered 3301' "$T/run/o/logs/fix-3301.log"
ck "1) the refusal names the number AND the class (a DISPATCH defect, not a repair)" $?
grep -qF 'DISPATCH defect' "$T/run/o/logs/fix-3301.log"
ck "1) the log says why it is not a repair (so the next reader does not re-derive it)" $?
grep -qx '0' "$T/run/refunded"; _rc=$?
ck "1) the booked attempt is REFUNDED (fixcount 1 -> $(cat "$T/run/refunded"))" "$_rc"

# 2. gh cannot answer — must NOT refuse (the over-block arm: an unreadable read is not an absence)
run_pr "" 1 "gh: HTTP 403: API rate limit exceeded for user ID 1 (https://api.github.com/graphql)"
ck "2) an UNREADABLE probe does NOT refuse the dispatch (rc=$(cat "$T/run/rc"), want not-78)" \
   "$([ "$(cat "$T/run/rc")" != 78 ] && echo 0 || echo 1)"
grep -qF 'could not answer' "$T/run/unknown"
ck "2) and it is RECORDED as unanswerable, never as a missing PR" $?
grep -qx '1' "$T/run/refunded"; _rc=$?
ck "2) nothing is refunded for a run that proceeds (fixcount still $(cat "$T/run/refunded"))" "$_rc"

# 3. the PR exists, but its head read came back empty — #4182 arm 2, still no refusal
run_pr "" 0 '{"number":3301}'
ck "3) an empty head on a REAL PR does not refuse (rc=$(cat "$T/run/rc"))" \
   "$([ "$(cat "$T/run/rc")" != 78 ] && echo 0 || echo 1)"
grep -qF 'staleness guard cannot name this head' "$T/run/unknown"
ck "3) the recorded reason names the BLANKED staleness guard instead of claiming a head" $?
# ⛔ THE PROCEEDING PATH MUST NOT REFUND, IN EITHER SUB-CASE (#1720/#2223). An empty head is the
# ORDINARY #4182-arm-2 dispatch, not a refusal: refunding here would credit an attempt that a
# fixer really did start, and the mutant that inserts the call into this branch survived the
# pre-fix suite (#4190 review F1).
grep -qx '1' "$T/run/refunded"; _rc=$?
ck "3) an empty head on a REAL PR refunds nothing either (fixcount still $(cat "$T/run/refunded"))" "$_rc"
grep -qF 'UNKNOWN' "$T/run/briefhead" && ! grep -qx 'UNKNOWN$' "$T/run/briefhead"; _rc=$?
ck "3) and the head the BRIEF will show is UNKNOWN plus that reason, never a blank ($(head -c 60 "$T/run/briefhead")…)" "$_rc"

# 4. a head was read — the probe must not cost a second gh call per dispatch
run_pr "0123456789abcdef0123456789abcdef01234567" 0 ""
[ -s "$T/run/ghcalls" ] && ck "4) no probe when the head is already known (gh calls: $(wc -l < "$T/run/ghcalls"))" 1 \
                        || ok "4) no probe when the head is already known (gh calls: 0)"
ck "4) and nothing is recorded as UNKNOWN on the ordinary path" "$([ -z "$(cat "$T/run/unknown")" ] && echo 0 || echo 1)"
grep -qx '0123456789abcdef0123456789abcdef01234567' "$T/run/briefhead"; _rc=$?
ck "4) and the head the BRIEF will show is the head that was read ($(cat "$T/run/briefhead"))" "$_rc"

# ── the driver for the review-read block ──────────────────────────────────────────────────────
# run_review <gh_rc> <payload>   → $T/run/o/logs/fix-3301{,-comments.txt,-comments.raw} + $T/run/lead
run_review() {
  local gh_rc="$1" payload="$2" d="$T/run"
  rm -rf "$d"; mkdir -p "$d/o/logs"
  (
    set -u
    O="$d/o"; L="$d/o/logs/fix-3301"; PR=3301; OR=daniel-ospina/agent-infra
    : > "$L"
    # ⛔ an EMPTY payload writes ZERO bytes, which is what a PR with no comments really returns
    # (redirected, `gh pr view --comments` prints only comments and reviews). Printing a bare
    # newline here would make arm 5b test a whitespace file instead of the measured 0-byte artifact.
    gh() { [ -n "$payload" ] && printf '%s\n' "$payload"; return "$gh_rc"; }
    . "$T/reviewread.sh" >/dev/null 2>&1
    printf '%s\n' "$FIX_REVIEW_LEAD" > "$d/lead"
  )
}

# 5. a readable review is delivered verbatim and the brief still promises a review
run_review 0 '### 1. P1 — the thing
Fix: do the thing.'
grep -qF 'P1 — the thing' "$T/run/o/logs/fix-3301-comments.txt"
ck "5) a successful read lands the comments verbatim in the findings file" $?
grep -qF 'NOT A REVIEW' "$T/run/o/logs/fix-3301-comments.txt"
ck "5) and it carries NO 'this is not a review' header" "$([ $? -ne 0 ] && echo 0 || echo 1)"
grep -qF 'found real issues' "$T/run/lead"
ck "5) the brief's lead still says a reviewer found issues (nothing was weakened)" $?
[ -e "$T/run/o/logs/fix-3301-comments.raw" ]
ck "5) the raw read does not survive the block" "$([ $? -ne 0 ] && echo 0 || echo 1)"

# 5b. a read that SUCCEEDED and delivered NOTHING (#4190 review F2, P1) — the measured artifact was
# 0 BYTES while the brief asserted "a fresh-context reviewer found real issues".
run_review 0 ''
# PRE-FIX this file is 0 BYTES (gh printed nothing and `cat` copied nothing); post-fix it carries the
# self-description, so the row reds on the pre-fix tree and can never be satisfied by an empty file.
[ -s "$T/run/o/logs/fix-3301-comments.txt" ]; _rc=$?
ck "5b) the artifact is no longer a 0-byte file ($(wc -c < "$T/run/o/logs/fix-3301-comments.txt") bytes) — the empty read is documented IN it" "$_rc"
head -1 "$T/run/o/logs/fix-3301-comments.txt" | grep -qF 'THIS FILE IS NOT A REVIEW'
ck "5b) so its FIRST LINE says it is not a review (an empty file cannot be presented as one)" $?
grep -qF 'found real issues' "$T/run/lead"
ck "5b) and the brief's lead no longer claims a reviewer found issues over an empty file" \
   "$([ $? -ne 0 ] && echo 0 || echo 1)"
grep -qF 'CARRIES NO REVIEW COMMENT' "$T/run/lead"
ck "5b) and it says the PR carries no review comment (so the fixer is not sent hunting)" $?
grep -qF 'marked NOT-A-REVIEW' "$T/run/o/logs/fix-3301.log"
ck "5b) the WARN is in the worker log (findable afterwards, like the failure arm)" $?

# 5c. content WITHOUT a findings heading gets an honest lead — not a claim of findings, and not the
# stronger claim "the PR carries no review", which a text match cannot establish.
run_review 0 'LGTM — queued this for the merge train.'
grep -qF 'looks good' "$T/run/lead"
ck "5c) content with no findings heading does not get the unqualified findings claim" \
   "$([ $? -ne 0 ] && echo 0 || echo 1)"
grep -qF 'no findings heading' "$T/run/lead" && ! grep -qF 'CARRIES NO REVIEW COMMENT' "$T/run/lead"
ck "5c) it names what was DETECTED (a missing heading), never that the PR has no review" $?
grep -qF 'LGTM — queued this for the merge train.' "$T/run/o/logs/fix-3301-comments.txt"
ck "5c) and the comments still land verbatim — the artifact IS the PR's comments" $?

# 6. an unreadable review must SAY SO — in the artifact AND in the brief
run_review 1 'GraphQL: Could not resolve to a PullRequest with the number of 3301. (repository.pullRequest)'
head -1 "$T/run/o/logs/fix-3301-comments.txt" | grep -qF 'THIS FILE IS NOT A REVIEW'
ck "6) the artifact's FIRST LINE says it is not a review (the measured case)" $?
grep -qF 'Could not resolve to a PullRequest' "$T/run/o/logs/fix-3301-comments.txt"
ck "6) the failure text is still visible below the header (not swallowed)" $?
grep -qF 'THE REVIEW COULD NOT BE READ' "$T/run/lead"
ck "6) the brief's lead says the review could not be read" $?
grep -qF 'found real issues' "$T/run/lead"
ck "6) and the lead no longer asserts a review it never read" "$([ $? -ne 0 ] && echo 0 || echo 1)"
[ -e "$T/run/o/logs/fix-3301-comments.raw" ]
ck "6) the raw read does not survive this arm either" "$([ $? -ne 0 ] && echo 0 || echo 1)"
grep -qF 'marked NOT-A-REVIEW' "$T/run/o/logs/fix-3301.log"
ck "6) the WARN is in the worker log (so the dispatch defect is findable afterwards)" $?

# ── 8. the rendered brief is the OBSERVED lead ────────────────────────────────────────────────
n="$(grep -cF 'A fresh-context reviewer found real issues' "$FIXER")"
ck "8) the unconditional sentence survives exactly ONCE, where the lead is computed (found $n)" \
   "$([ "$n" = 1 ] && echo 0 || echo 1)"
_briefline="$(grep -F 'You are a FIX agent for branch' "$FIXER" || true)"
case "$_briefline" in
  *'$FIX_REVIEW_LEAD'*) ok "8) the fixer brief renders \$FIX_REVIEW_LEAD, not a literal claim" ;;
  *) bad "8) the fixer brief does not render \$FIX_REVIEW_LEAD — the unconditional claim is back" ;;
esac

# ── 9. the brief's staleness guards render the HEAD they were given (#4190 review F1, P2) ─────
# ⛔ RENDERED, not grepped, and through fix-one.sh's own code: the driver sources the SHIPPED
# prresolve block (which computes the head the brief shows) and then the SHIPPED heredoc, exactly as
# fix-one-brief.test.sh's A2 does. Pre-fix, the template interpolated `$HEAD` verbatim, so with no
# head it rendered `THIS head (``)` — a BLANK where the one sentence that could expose a stale brief
# should be, while the WARN claimed the opposite.
run_brief() {
  local head="${1-}" gh_rc="${2:-0}" gh_out="${3-}" d="$T/brief"
  rm -rf "$d"; mkdir -p "$d/o/logs" "$d/o/state" "$d/wt"
  (
    set -u
    O="$d/o"; L="$d/o/logs/fix-3301"; PR=3301; OR=daniel-ospina/agent-infra; HEAD="$head"; CTRL=1
    BR=fix/3301-worktree-reap-on-exit; WT="$d/wt"
    FIX_RESEARCH_BRIEF="RESEARCH-MARKER"; FIX_DELIVERY_BRIEF="DELIVERY-MARKER"
    FIX_REVIEW_LEAD="REVIEW-LEAD-MARKER"
    : > "$L"
    printf '1\n' > "$O/state/fixcount-3301"
    gh() { [ -n "$gh_out" ] && printf '%s\n' "$gh_out"; return "$gh_rc"; }
    is_num() { case "${1-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
    . "$T/refund.sh" >/dev/null 2>&1
    . "$T/prresolve.sh" >/dev/null 2>&1
    . "$T/briefregion.sh"
  ) > "$d/run.log" 2>&1
}
_brief="$T/brief/o/logs/fix-3301-fixer.txt"
_guards() { grep -F 'first 12 characters of THIS head' "$_brief" 2>/dev/null; }

_nraw="$(grep -oF '$HEAD' "$T/briefregion.sh" | wc -l | tr -d ' ')"
ck "9) the brief template interpolates no RAW \$HEAD — it renders \$FIX_BRIEF_HEAD instead (found $_nraw raw)" \
   "$([ "$_nraw" = 0 ] && echo 0 || echo 1)"

run_brief "0123456789abcdef0123456789abcdef01234567" 0 ""
ck "9) the brief was written for a KNOWN head ($([ -s "$_brief" ] && echo "$(wc -c < "$_brief") bytes" || echo MISSING))" \
   "$([ -s "$_brief" ] && echo 0 || echo 1)"
_nk="$(_guards | grep -cF '0123456789abcdef0123456789abcdef01234567')"
ck "9) BOTH staleness guards name the head that was read (found $_nk of 2)" \
   "$([ "$_nk" = 2 ] && echo 0 || echo 1)"
_nu="$(_guards | grep -cF 'UNKNOWN')"
ck "9) and neither claims UNKNOWN when the head IS known (found $_nu)" \
   "$([ "$_nu" = 0 ] && echo 0 || echo 1)"

run_brief "" 0 '{"number":3301}'
ck "9) the brief was written with NO head ($([ -s "$_brief" ] && echo "$(wc -c < "$_brief") bytes" || echo MISSING))" \
   "$([ -s "$_brief" ] && echo 0 || echo 1)"
_nu="$(_guards | grep -cF 'UNKNOWN')"
ck "9) with no head BOTH staleness guards render UNKNOWN (found $_nu of 2) — the pre-fix blank is gone" \
   "$([ "$_nu" = 2 ] && echo 0 || echo 1)"
grep -qF 'staleness guard cannot name this head' "$_brief"
ck "9) and they carry the REASON the head is unknown, not just the word" $?

# ── 10. the suite POLICES ITSELF (#4190 review F1, P1) ───────────────────────────────────────
# A row of the shape `ck "… $(cmd) …" $?` is DEAD: the message's command substitution runs FIRST, so
# the status argument is the SUBSTITUTION's, never the guard's. Seven checks were in that shape and
# five executed mutants left this suite green. This arm reads THIS file and refuses the shape, so a
# future row cannot silently reintroduce it.
SELF="${BASH_SOURCE[0]:-$0}"
_dead="$(awk '
  {
    line = $0; sub(/[ \t]+$/, "", line)
    n = split(line, f, /[ \t]+/)
    if (n > 0 && f[n] == "$?" && index(line, "ck \"") > 0 && index(line, "$(") > 0) print NR
  }' "$SELF")"
if [ -n "$_dead" ]; then
  bad "10) no ck row takes a bare last-command status while its own message runs a command substitution — DEAD row(s) at line(s): $(printf '%s' "$_dead" | tr '\n' ' ')"
else
  ok "10) every ck row's status is the GUARD's — none is masked by a command substitution in its own message"
fi

echo "───────────────────────────────────────────────────────────────────"
if [ "$fail" -eq 0 ]; then
  echo "✅ fix-one PR-resolution/review-read suite: all $pass check(s) passed"
  exit 0
fi
echo "❌ fix-one PR-resolution/review-read suite: $fail failure(s), $pass passed"
exit 1
