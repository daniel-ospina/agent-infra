#!/usr/bin/env bash
# reviewer-preflight.test.sh — #2148: the reviewer requirement must be disclosed BEFORE the work.
#
# THE DEFECT (measured 2026-10-19, cell-2). Three lanes rebased, implemented, tested, pushed and
# opened their PRs, and were then stopped by the review-enforcer:
#
#   [review-enforcer] 🚫 Blocked — no reviewers dispatched
#   [review-enforcer] 🚫 Admin-merge evidence gate blocked
#
# Each had produced real work; none could land it. They were re-dispatched only after the reviewer
# step was appended to their briefs BY HAND. The requirement lived in the enforcer's code and in
# nothing a lane could read before it started — so every new brief author rediscovered it by being
# blocked, at the cost of a full lane-run on an 8-CPU box.
#
# WHAT THIS SUITE PINS, and why each check reads an ARTIFACT rather than this repo's source:
#   §A  the disclosure line exists, is ONE line, and names all three commands (dispatch, record,
#       rail). A line that names no command still costs the lane a round trip.
#   §B  the two ROLES differ where they must: a self-landing lane dispatches; a harness lane must
#       NOT (it has no `task` tool, and merge-one.sh reviews the PR) — and must not merge.
#   §C  LANE.SH'S REAL OUTPUT carries the step. The lane is run with LANE_DRY_RUN=1, so the
#       pre-flight line and the generated brief are asserted from the files a lane would actually
#       receive. A source grep would pass on a script whose runtime output lost the text — the
#       "test that cannot fail" class the harness's selftest rig exists to prevent.
#   §D  the brief TEMPLATE a controller copies carries it too (that is where it was omitted by
#       hand three times).
#   §E  non-vacuity: the assertions above CAN fail (a stripped command, a two-line disclosure).
#       The cross-language drift pin itself is in extensions/shared/reviewer-preflight.test.ts,
#       which RENDERS both roles through this helper and compares them byte for byte to the
#       TypeScript lines; §A here pins the same constants in the bash copy.
#
# SCOPE: this is the harness's half. The pi-side disclosure, the unchanged rail refusal and the
# first-push notice are pinned by extensions/review-enforcer/index.test.ts (#2148 section) and the
# shared wording by extensions/shared/reviewer-preflight.test.ts.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$HERE/reviewer-preflight.sh"
LANE="$HERE/lane.sh"
TEMPLATE="$(cd "$HERE/../.." && pwd)/templates/LANE-BRIEF.md"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }
ck()  { if [ "$1" -eq 0 ]; then ok "$2"; else bad "$2"; fi; }

[ -f "$HELPER" ] || { echo "❌ no reviewer-preflight.sh at $HELPER"; exit 2; }

# The helper is SOURCEABLE with no side effects (lane.sh sources it): sourcing must not print.
out="$(
  # shellcheck disable=SC1090
  . "$HELPER" 2>&1
)"
[ -z "$out" ]; ck $? "sourcing reviewer-preflight.sh prints nothing (a sourced helper must not speak)"
# ...and it exposes the two functions lane.sh calls.
# shellcheck disable=SC1090
. "$HELPER"
if declare -f reviewer_preflight_line >/dev/null && declare -f reviewer_brief_section >/dev/null; then rc=0; else rc=1; fi
ck $rc "the helper exposes reviewer_preflight_line + reviewer_brief_section"

echo
echo "§A the disclosure line"
LINE="$(reviewer_preflight_line self)"
[ "$(printf '%s\n' "$LINE" | wc -l | tr -d ' ')" = "1" ]; ck $? "the pre-flight disclosure is ONE line (printed once, up front)"
case "$LINE" in *"[gate]"*) rc=0;; *) rc=1;; esac; ck $rc "…greppable by its [gate] tag"
case "$LINE" in
  *"must dispatch a reviewer and record an attestation at the final head before the rail"*) rc=0;;
  *) rc=1;;
esac; ck $rc "…and states the requirement in the one wording the pi side uses (drift-pinned)"
case "$LINE" in *"task(prompt='[REVIEW]"*) rc=0;; *) rc=1;; esac; ck $rc "…naming the dispatch command"
case "$LINE" in *"scripts/record-review.sh <PR> <HEAD> clean [owner/repo] --evidence comment:"*) rc=0;; *) rc=1;; esac
ck $rc "…naming the record command WITH --evidence (a fresh 'clean' without it is refused, tortoise#7391)"
case "$LINE" in *"scripts/admin-merge.sh <PR>"*) rc=0;; *) rc=1;; esac; ck $rc "…naming the rail command"
case "$LINE" in *"AFTER the last push"*) rc=0;; *) rc=1;; esac
ck $rc "…and WHEN to record (a stale record is refused, so 'record' alone is a trap)"
case "$LINE" in *"post the reviewer's verdict as a PR comment"*) rc=0;; *) rc=1;; esac
ck $rc "…and that the verdict must be POSTED as a PR comment (the --evidence artifact's referent)"

echo
echo "§B the two roles"
HARNESS_LINE="$(reviewer_preflight_line harness)"
case "$HARNESS_LINE" in *"HARNESS reviewer"*) rc=0;; *) rc=1;; esac; ck $rc "the harness role names WHO mints the attestation"
case "$HARNESS_LINE" in *"do NOT merge"*) rc=0;; *) rc=1;; esac; ck $rc "the harness role keeps the lane out of the rail"
case "$HARNESS_LINE" in *"scripts/record-review.sh"*) rc=0;; *) rc=1;; esac; ck $rc "…and still names the record command"
case "$HARNESS_LINE" in *"dispatch: task("*) rc=1;; *) rc=0;; esac
ck $rc "⛔ the harness role does NOT instruct the lane to dispatch (its brief forbids it — the roles cannot collapse)"
SELF_BRIEF="$(reviewer_brief_section self)"
case "$SELF_BRIEF" in *"## Reviewer step"*) rc=0;; *) rc=1;; esac; ck $rc "the self brief has a findable heading"
case "$SELF_BRIEF" in *"Only then run the rail"*) rc=0;; *) rc=1;; esac; ck $rc "the self brief orders record BEFORE the rail"
case "$SELF_BRIEF" in *"NEVER edit the PR body after recording"*) rc=0;; *) rc=1;; esac
ck $rc "the self brief forbids the post-record body edit (it invalidates the evidence artifact)"
HARNESS_BRIEF="$(reviewer_brief_section harness)"
case "$HARNESS_BRIEF" in *"do NOT dispatch it"*) rc=0;; *) rc=1;; esac
ck $rc "the harness brief says the LANE does not dispatch (it has no task tool — telling it to would waste the run)"
case "$HARNESS_BRIEF" in *"Never merge, never run the rail"*) rc=0;; *) rc=1;; esac
ck $rc "…and forbids the lane merging its own PR"
# An unknown role must REFUSE rather than silently print the wrong audience's instructions.
reviewer_preflight_line SCOPE=banana >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]; ck $? "an unknown role is refused (never a silent default that addresses the wrong audience)"

echo
echo "§C lane.sh's REAL output (LANE_DRY_RUN=1)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/o/logs"
# A throwaway worktree dir: lane.sh reads $PWD for the log header and the venv reaper, and
# REAP_LANE_VENV_DISABLE keeps the reaper out of the fixture's way.
(
  cd "$TMP" || exit 1
  O="$TMP/o" REAP_LANE_VENV_DISABLE=1 LANE_DRY_RUN=1 \
    bash "$LANE" 2148 fix/2148-reviewer-preflight acme/widget
) > "$TMP/stdout" 2>"$TMP/stderr"
rc=$?
ck $rc "lane.sh --dry-run exits 0 (nothing is spawned: no agent, no gate consumed)"
PREFLIGHT_COUNT="$(grep -c '#2148 preflight' "$TMP/stdout" 2>/dev/null || true)"
[ "${PREFLIGHT_COUNT:-0}" = "1" ]; ck $? "the pre-flight line is printed EXACTLY ONCE on the lane's stdout"
grep -q '#2148 preflight' "$TMP/o/logs/lane-2148.log" 2>/dev/null; ck $? "…and lands in the lane LOG (what an operator greps)"
grep -q 'DRY RUN' "$TMP/o/logs/lane-2148.log" 2>/dev/null; ck $? "the dry run says so in the log"
[ -f "$TMP/o/logs/prompt-2148.txt" ]; ck $? "the brief a lane would be given was generated"
BRIEF_FILE="$TMP/o/logs/prompt-2148.txt"
grep -q '## Reviewer step' "$BRIEF_FILE" 2>/dev/null; ck $? "the GENERATED brief carries the reviewer step (a brief that omits it is the defect)"
grep -q 'must dispatch a reviewer and record an attestation at the final head before the rail' "$BRIEF_FILE" 2>/dev/null
ck $? "…stating the requirement in the shared wording"
# -F: the placeholder contains a bracket expression, which a plain grep would read as a
# character class and silently never match (the vacuous-green shape this suite exists to avoid).
grep -qF 'scripts/record-review.sh <PR> <HEAD> clean [owner/repo] --evidence comment:' "$BRIEF_FILE" 2>/dev/null
ck $? "…naming the record command WITH --evidence (the invocation that actually mints a record)"
grep -q 'scripts/admin-merge.sh <PR>' "$BRIEF_FILE" 2>/dev/null; ck $? "…naming the rail command"
grep -q 'do NOT dispatch it' "$BRIEF_FILE" 2>/dev/null; ck $? "…in the HARNESS role (this lane's reviewer is merge-one.sh)"
# The brief must keep the pre-existing content it had before #2148 — an insertion that displaced a
# line would be invisible to every check above.
grep -q 'Closes #' "$BRIEF_FILE" 2>/dev/null; ck $? "the brief still carries its PR-body requirement"
grep -q '## Deliverable' "$BRIEF_FILE" 2>/dev/null; ck $? "…and its Deliverable section"
grep -q 'never search the filesystem for an interpreter' "$BRIEF_FILE" 2>/dev/null; ck $? "…and the no-search bound"
# The prompt heredoc is UNQUOTED, so an unescaped backtick in the inserted section would run at
# prompt-build time. #1835's rig counts ticks in the heredoc; this asserts the OBSERVABLE half:
# the rendered brief still contains the literal backticked commands it is supposed to.
grep -q '`uv sync --extra embeddings --extra parity`' "$BRIEF_FILE" 2>/dev/null
ck $? "no backtick span in the grown heredoc was executed at prompt-build time (#1835 class)"
[ ! -s "$TMP/stderr" ] || [ -z "$(grep -v '^$' "$TMP/stderr")" ]; ck $? "the dry run writes nothing to stderr"
# Fail-closed: a missing helper must STOP the lane, not silently ship a brief with no reviewer step.
# ⛔ The restore is a TRAP, not the next line: an interrupted run that left the shipped helper renamed
# is a broken checkout (selftest.sh renders the brief through it). And the exit code is pinned to 78
# — "any non-zero" would still pass if lane.sh started failing for an unrelated reason.
HELPER_MOVED=0
restore_helper() { [ "$HELPER_MOVED" = "1" ] && mv -f "$HELPER.moved" "$HELPER" 2>/dev/null; }
trap 'restore_helper; rm -rf "$TMP"' EXIT
mv "$HELPER" "$HELPER.moved" && HELPER_MOVED=1
(
  cd "$TMP" || exit 1
  O="$TMP/o2" REAP_LANE_VENV_DISABLE=1 LANE_DRY_RUN=1 \
    bash "$LANE" 2148 fix/x acme/widget
) >/dev/null 2>&1
rc=$?
restore_helper; HELPER_MOVED=0
[ "$rc" = "78" ]; ck $? "a MISSING helper refuses the lane with exit 78 (fail-closed: never a brief that omits the step silently)"

echo
echo "§D the brief template a controller copies"
[ -f "$TEMPLATE" ]; ck $? "templates/LANE-BRIEF.md exists"
grep -q 'must dispatch a reviewer and record an attestation at the final head before the rail' "$TEMPLATE" 2>/dev/null
ck $? "the template states the requirement verbatim"
grep -qF 'scripts/record-review.sh <PR> <HEAD> clean [owner/repo] --evidence comment:' "$TEMPLATE" 2>/dev/null
ck $? "…names the record command WITH --evidence (the invocation that actually mints a record)"
grep -q 'scripts/admin-merge.sh <PR>' "$TEMPLATE" 2>/dev/null; ck $? "…names the rail command"
grep -q '## Reviewer step' "$TEMPLATE" 2>/dev/null; ck $? "…and carries it as its own section, not a footnote"

echo
echo "§E non-vacuity — the checks above can fail"
# A disclosure with the commands STRIPPED must fail the §A assertions. Without this control, a
# `case` that never matches (a typo'd pattern) would read as green forever.
STRIPPED="$(printf '%s\n' "$LINE" | sed 's/scripts\/record-review.sh//')"
case "$STRIPPED" in *"scripts/record-review.sh"*) rc=1;; *) rc=0;; esac
ck $rc "the command assertion FIRES when the command is removed"
# ...and the "one line" assertion fires on a two-line disclosure.
TWO_LINE="$(printf '%s\n%s' "$LINE" extra)"
[ "$(printf '%s\n' "$TWO_LINE" | wc -l | tr -d ' ')" = "1" ]; rc=$?
[ "$rc" -ne 0 ]; ck $? "the one-line assertion FIRES on a two-line disclosure"

echo
echo "================ RESULT: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
