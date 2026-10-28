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
#       which RENDERS all three roles through this helper and compares them byte for byte to the
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

# ONE predicate for "the record command is present, in the spelling that actually mints a record".
# §A and §E both use it, so the non-vacuity control exercises the SAME pattern it claims to validate
# (a §E that stripped a DIFFERENT, weaker token proved nothing — review of #2148, P2).
record_cmd_present() {
  case "$1" in
    *"~/.pi/agent/scripts/record-review.sh <PR> <HEAD> clean [owner/repo] --evidence comment:"*) return 0;;
    *) return 1;;
  esac
}

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
record_cmd_present "$LINE"; ck $? "…naming the record command WITH --evidence (a fresh 'clean' without it is refused, tortoise#7391)"
# ⛔ THE PATH MUST BE THE HOME COPY (fresh review, P1). This line is printed inside a lane whose cwd
# is a CONTENT repo, which has no `scripts/record-review.sh`; the production copy is farmed into
# ~/.pi/agent/scripts (that is where merge-one.sh runs it from). A repo-relative path is correct ONLY
# in agent-infra's own checkout, so every other lane would copy a command that cannot run.
case "$LINE" in *" scripts/record-review.sh"*) rc=1;; *) rc=0;; esac
ck $rc "⛔ …and NOT a repo-relative path (a content repo has no scripts/record-review.sh)"
case "$LINE" in *"scripts/admin-merge.sh <PR>"*) rc=0;; *) rc=1;; esac; ck $rc "…naming the rail command"
case "$LINE" in *"no \`task\` tool"*) rc=0;; *) rc=1;; esac
ck $rc "the self line names the condition that OVERRIDES it (a harness lane with no task tool, review P1)"
case "$LINE" in *"AFTER the last push"*) rc=0;; *) rc=1;; esac
ck $rc "…and WHEN to record (a stale record is refused, so 'record' alone is a trap)"
case "$LINE" in *"post the reviewer's verdict as a PR comment"*) rc=0;; *) rc=1;; esac
ck $rc "…and that the verdict must be POSTED as a PR comment (the --evidence artifact's referent)"
# ⛔ THE CARRY IS NOT OMITTED (#2343). A lane holding a valid record at an unchanged DIFF owes no
# second review: record-review.sh re-binds it itself (mint:"carried", no --evidence) and the merge
# gate allows an equal 64-hex diff. A line silent about it cost two lanes 20-40 minutes each on
# 2026-11-19, and one of them stopped. These checks read the RENDERED line, so a reflow that loses
# the clause cannot pass on the constants alone.
case "$LINE" in *"$REVIEWER_PREFLIGHT_CARRY_CLAUSE"*) rc=0;; *) rc=1;; esac
ck $rc "…and states the CARRY (a valid record at an unchanged artifact is not re-reviewed, #2343)"
case "$LINE" in *'mint:"carried"'*) rc=0;; *) rc=1;; esac
ck $rc "…naming what a carried record writes, so the lane recognises the record it already holds"
case "$LINE" in *"A FRESH mint still requires the dispatched reviewer"*) rc=0;; *) rc=1;; esac
ck $rc "⛔ …while a FRESH mint still requires the dispatched reviewer (the carry is never a skip)"
RECORD_AT="${LINE%%"$REVIEWER_PREFLIGHT_RECORD_CMD"*}"
CARRY_AT="${LINE%%"$REVIEWER_PREFLIGHT_CARRY_CLAUSE"*}"
[ "${#RECORD_AT}" -lt "${#CARRY_AT}" ]; ck $? "the carry sits AFTER the dispatch/record/rail trail (it refines it, not replaces it)"
# ⛔ ORDER IS A TRUTH CONDITION (#2343 review, P1): the carry is the EXCEPTION to the stale-head
# sentence, so it must follow the sentence it qualifies. Placed before it, the line contradicts
# itself and a lane reading both resolves it by paying for the review anyway.
BIND_AT="${LINE%%"$REVIEWER_HEAD_BINDING"*}"
[ "${#BIND_AT}" -lt "${#CARRY_AT}" ]; ck $? "…and AFTER the stale-head rule it is the exception to (no self-contradiction)"
# The three facts the recorder enforces and a first draft got wrong (fresh review, P1/P2):
# which head to pass (a live head is a FRESH mint, refused at record-review.sh:2008), that the lane
# arm is a FORWARD MERGE — an ANCESTRY check (:1377-1379), so a rebase rules out the LANE arm while
# the DIFF arm still carries an unchanged recomputed digest — and the red-target veto (:1951).
case "$LINE" in *"the REVIEWED head, not the live one"*) rc=0;; *) rc=1;; esac
ck $rc "…naming WHICH head to pass (the recorded one) — the live head is a fresh mint, refused"
# ⛔ THE VERDICT IS PART OF THE IDENTITY (cycle 2, P1): the DIFF arm pins `verdict=` in its marker
# regex, but the LANE arm takes only two SHAs and never reads the verdict, and the evidence guard is
# skipped for ANY carry — so a literal `clean` over a `clean-micro` record mints a claim nothing
# supports (the #513 hazard).
case "$LINE" in *"the head AND the verdict that record already names"*) rc=0;; *) rc=1;; esac
ck $rc "…saying to pass the VERDICT too (a clean-micro record must not become a clean mint)"
case "$LINE" in *"a clean-micro record stays clean-micro"*) rc=0;; *) rc=1;; esac
ck $rc "…naming the exact downgrade the lane arm cannot detect itself"
# ⛔ "A REBASE DOES NOT CARRY" WOULD BE FALSE (cycle 2, P1): the LANE arm needs ancestry, but the DIFF
# arm matches the recomputed LIVE digest with no ancestry requirement, so a rebase whose rendered
# patch is unchanged DOES carry.
case "$LINE" in *"the LANE arm cannot carry it"*) rc=0;; *) rc=1;; esac
ck $rc "…scoping the rebase exception to the LANE arm"
case "$LINE" in *"unchanged DIFF digest still carries"*) rc=0;; *) rc=1;; esac
ck $rc "…and keeping the DIFF arm's digest carry (04-merge-deploy: 'Same digest → the verdict STANDS')"
BIND_PRESENT="${LINE%%"$REVIEWER_HEAD_BINDING"*}"
[ "${#BIND_PRESENT}" -lt "${#LINE}" ]; ck $? "the stale-head anchor is still ON the line (the order pin cannot go vacuous)"
case "$LINE" in *"not measurably red"*) rc=0;; *) rc=1;; esac
ck $rc "…keeping the #1575 clause-E veto (a red target head refuses the carry)"

echo
echo "§B the three roles"
HARNESS_LINE="$(reviewer_preflight_line harness)"
case "$HARNESS_LINE" in *"HARNESS reviewer"*) rc=0;; *) rc=1;; esac; ck $rc "the harness role names WHO mints the attestation"
case "$HARNESS_LINE" in *"do NOT merge"*) rc=0;; *) rc=1;; esac; ck $rc "the harness role keeps the lane out of the rail"
case "$HARNESS_LINE" in *"merge-one.sh runs:"*) rc=0;; *) rc=1;; esac
ck $rc "…and FRAMES the record/rail as merge-one.sh's work, not the lane's (review P2)"
case "$HARNESS_LINE" in *"no \`task\` tool"*) rc=1;; *) rc=0;; esac
ck $rc "…without the self line's hedge (this IS the marked harness audience)"
case "$HARNESS_LINE" in *"~/.pi/agent/scripts/record-review.sh"*) rc=0;; *) rc=1;; esac; ck $rc "…and still names the record command"
case "$HARNESS_LINE" in *"dispatch: task("*) rc=1;; *) rc=0;; esac
ck $rc "⛔ the harness role does NOT instruct the lane to dispatch (its brief forbids it — the roles cannot collapse)"
case "$HARNESS_LINE" in *"$REVIEWER_PREFLIGHT_CARRY_CLAUSE"*) rc=1;; *) rc=0;; esac
ck $rc "…and NOT carrying the self line's CARRY clause (this role never records)"
# The REVIEWER session (merge-one.sh's own) is a third audience: it posts the verdict comment and
# must not push/record/merge. Giving it the harness line contradicts the prompt it was launched with
# ("Report only — do not fix code … Do NOT modify code, commit, or merge").
REVIEWER_LINE="$(reviewer_preflight_line reviewer)"
case "$REVIEWER_LINE" in *"you ARE the harness reviewer"*) rc=0;; *) rc=1;; esac
ck $rc "the reviewer role tells the session WHAT IT IS"
case "$REVIEWER_LINE" in *"post the verdict as a PR comment"*) rc=0;; *) rc=1;; esac
ck $rc "…naming the artifact it owns (the verdict comment)"
case "$REVIEWER_LINE" in *"do NOT push"*) rc=0;; *) rc=1;; esac
ck $rc "⛔ …forbidding the push its launcher forbids"
case "$REVIEWER_LINE" in *"push your FINAL head"*) rc=1;; *) rc=0;; esac
ck $rc "⛔ …and NOT carrying the harness role's 'push your FINAL head' (the contradiction this removes)"
case "$REVIEWER_LINE" in *"$REVIEWER_PREFLIGHT_CARRY_CLAUSE"*) rc=1;; *) rc=0;; esac
ck $rc "…and NOT carrying the self line's CARRY clause (the reviewer must not record at all)"
SELF_BRIEF="$(reviewer_brief_section self)"
case "$SELF_BRIEF" in *"## Reviewer step"*) rc=0;; *) rc=1;; esac; ck $rc "the self brief has a findable heading"
case "$SELF_BRIEF" in *"Only then run the rail"*) rc=0;; *) rc=1;; esac; ck $rc "the self brief orders record BEFORE the rail"
case "$SELF_BRIEF" in *"NEVER edit the PR body after recording"*) rc=0;; *) rc=1;; esac
ck $rc "the self brief forbids the post-record body edit (it invalidates the evidence artifact)"
# ⛔ THE BRIEF IS A CHANNEL, NOT A FOOTNOTE (#2343 review, P2): a lane.sh lane's PROMPT is the brief,
# so a brief that omits the carry and says "push again after recording and the record is void" sends
# that lane into the same 20-40 minute review the line's omission caused.
case "$SELF_BRIEF" in *"$REVIEWER_PREFLIGHT_CARRY_CLAUSE"*) rc=0;; *) rc=1;; esac
ck $rc "…and the self brief carries the CARRY clause verbatim (the lane's prompt IS the brief)"
case "$SELF_BRIEF" in *"the record is void UNLESS the CARRY"*) rc=0;; *) rc=1;; esac
ck $rc "…no longer claiming the record is void unconditionally after a push"
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
# ⛔ THE DRY-RUN CWD MUST BE THE TARGET REPO (agent-infra#2724/#2694). lane.sh now refuses (72) when
# the worktree's origin is not the repo it was dispatched for. This section asserts the RENDERED
# brief, not the repo gate, so the fixture is a checkout of the `acme/widget` it names.
git init -q "$TMP" 2>/dev/null && git -C "$TMP" remote add origin https://github.com/acme/widget.git 2>/dev/null
# …and it is checked out on the branch the lane was told it is on: lane.sh refuses a worktree on a
# DIFFERENT named branch (the `prfixup` shape), so a fixture on `main` would be refused for the
# branch before this section could read the rendered brief.
git -C "$TMP" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null \
  && git -C "$TMP" checkout -q -b fix/2148-reviewer-preflight 2>/dev/null
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
grep -qF '~/.pi/agent/scripts/record-review.sh <PR> <HEAD> clean [owner/repo] --evidence comment:' "$TEMPLATE" 2>/dev/null
ck $? "…names the record command WITH --evidence (the invocation that actually mints a record)"
grep -q 'scripts/admin-merge.sh <PR>' "$TEMPLATE" 2>/dev/null; ck $? "…names the rail command"
grep -q '## Reviewer step' "$TEMPLATE" 2>/dev/null; ck $? "…and carries it as its own section, not a footnote"
# the carry rule a controller copies (#2343 review, P2 — the template is the controller's artifact)
grep -q 'A CARRY IS NOT A RE-REVIEW' "$TEMPLATE" 2>/dev/null; ck $? "…and carries the CARRY rule"
grep -q 'the REVIEWED head, not the live one' "$TEMPLATE" 2>/dev/null; ck $? "…saying WHICH head to pass for a carry"

echo
echo "§E non-vacuity — the checks above can fail"
# A disclosure with the commands STRIPPED must fail the §A assertions. Without this control, a
# `case` that never matches (a typo'd pattern) would read as green forever.
STRIPPED="$(printf '%s\n' "$LINE" | sed 's#~/.pi/agent/scripts/record-review.sh##')"
record_cmd_present "$STRIPPED"; rc=$?
[ "$rc" -ne 0 ]; ck $? "the command assertion FIRES when the script path is removed"
# The flag is part of the invocation, so the control must strip the FLAG too — the defect that
# actually shipped once was a command that named the script and omitted `--evidence`.
NOFLAG="$(printf '%s\n' "$LINE" | sed 's# --evidence comment:<review-comment-id>##')"
record_cmd_present "$NOFLAG"; rc=$?
[ "$rc" -ne 0 ]; ck $? "…and when --evidence is removed (the defect that shipped)"
# ...and the "one line" assertion fires on a two-line disclosure.
TWO_LINE="$(printf '%s\n%s' "$LINE" extra)"
[ "$(printf '%s\n' "$TWO_LINE" | wc -l | tr -d ' ')" = "1" ]; rc=$?
[ "$rc" -ne 0 ]; ck $? "the one-line assertion FIRES on a two-line disclosure"
# ...and the CARRY assertion fires when the clause is dropped — the regression this issue exists to
# prevent (a lane re-disclosing only the requirement pays for a review it does not owe, #2343).
NOCARRY="$(printf '%s\n' "$LINE" | sed "s# $REVIEWER_PREFLIGHT_CARRY_CLAUSE##")"
case "$NOCARRY" in *"$REVIEWER_PREFLIGHT_CARRY_CLAUSE"*) rc=0;; *) rc=1;; esac
[ "$rc" -ne 0 ]; ck $? "the CARRY assertion FIRES when the clause is stripped from the line (#2343)"

echo
echo "§F landing artifacts — the brief must make a PR PASSABLE, not just reviewed (#2325)"
# THE DEFECT (agent-infra#2325, measured 2026-10-25 on agent-infra). `pipeline-compliance` blocked 36
# of 40 open agent-infra PRs and the count GREW faster than lanes could be rescued from it (33 -> 36
# in one hour). The brief told a lane to READ `issue-workflow` / `issue-scoping` and never to PRODUCE
# the artifacts those skills exist to create, so every lane finished real work, opened a PR, and was
# refused — its evidence retro-fitted by a human or a drain lane afterwards. These checks read the
# ARTIFACTS a lane receives (the composed brief + the template block), and §F.4 drives the GATE'S OWN
# PARSERS over the shapes this text prescribes — a shape that stops being accepted there goes red here.
LANDING_SELF="$(landing_artifacts_brief_section self)"
LANDING_HARNESS="$(landing_artifacts_brief_section harness)"
landing_artifacts_brief_section SCOPE=banana >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]; ck $? "an unknown role is refused (never the wrong audience's record duty)"
[ -n "$LANDING_SELF" ] && [ -n "$LANDING_HARNESS" ]; ck $? "the helper renders the section for both roles"
case "$LANDING_SELF" in *"$LANDING_ARTIFACTS_HEADING"*) rc=0;; *) rc=1;; esac
ck $rc "the section carries its findable heading (the check this exists for is named in it)"

# ONE predicate per requirement, used by BOTH the composed-brief check and the non-vacuity control —
# so the control exercises the SAME pattern it claims to validate (a control that strips a DIFFERENT,
# weaker token proves nothing; the #2148 suite's own §E lesson).
has_req_a()  { case "$1" in *"[a] the issue reference must BEGIN A LINE"*) return 0;; *) return 1;; esac; }
has_req_b()  { case "$1" in *"FIRST CONTENT LINE"*"<!-- issue-scoping:"*) return 0;; *) return 1;; esac; }
has_req_c()  { case "$1" in *"CURRENT head"*"$LANDING_HEAD_BINDING"*"~/.pi/agent/scripts/record-review.sh"*) return 0;; *) return 1;; esac; }
has_req_d()  { case "$1" in *"[d] plan evidence"*) ;; *) return 1;; esac
                case "$1" in *'`## Wiring`'*) ;; *) return 1;; esac
                case "$1" in *"docs/plans/*.md"*) return 0;; *) return 1;; esac; }
has_req_e()  { case "$1" in *"[e] test evidence"*"*.test.ts"*) return 0;; *) return 1;; esac; }
has_mech_1() { case "$1" in *'`git commit -F <message-file>`'*) return 0;; *) return 1;; esac; }
has_mech_2() { case "$1" in *'never `git add -A`'*) return 0;; *) return 1;; esac; }
has_honesty() { case "$1" in *"never write a scoping comment for a plan you did not follow"*"fabricated one MERGES"*) return 0;; *) return 1;; esac; }

echo
echo "§F.1 the composed brief a lane.sh lane RECEIVES (the same dry-run artifact §C asserts on)"
[ -f "$BRIEF_FILE" ]; ck $? "the composed brief exists"
COMPOSED="$(cat "$BRIEF_FILE" 2>/dev/null || true)"
has_req_a "$COMPOSED"; ck $? "[a] the issue ref must BEGIN A LINE (a mid-sentence ref does not count)"
has_req_b "$COMPOSED"; ck $? "[b] the scoping marker is the comment's FIRST CONTENT LINE at column 0"
has_req_c "$COMPOSED"; ck $? "[c] the record is bound to the CURRENT head, with the recorder command"
has_req_d "$COMPOSED"; ck $? "[d] plan evidence: docs/plans/*.md or a ## Wiring section"
has_req_e "$COMPOSED"; ck $? "[e] test evidence for runtime code"
has_mech_1 "$COMPOSED"; ck $? "mechanic: git commit -F <message-file> (never -m)"
has_mech_2 "$COMPOSED"; ck $? "mechanic: never git add -A"
has_honesty "$COMPOSED"; ck $? "⛔ the brief forbids FABRICATION (evidence describes work actually done; else BLOCKED)"
case "$COMPOSED" in *"a moved head must be RE-RECORDED at the new head"*) rc=0;; *) rc=1;; esac
ck $rc "the HEAD-BINDING rule is stated: a moved head invalidates the record, so it is re-recorded"
# The five artifacts must not have displaced what the brief already said (an insertion that drops a
# line is invisible to every check above).
grep -q '## Reviewer step' "$BRIEF_FILE" 2>/dev/null; ck $? "…and the reviewer step SURVIVES the insertion"
grep -q '## Deliverable' "$BRIEF_FILE" 2>/dev/null; ck $? "…as does the Deliverable section"
grep -q 'never search the filesystem for an interpreter' "$BRIEF_FILE" 2>/dev/null; ck $? "…and the no-search bound"

echo
echo "§F.2 role-correct on [c] only — who mints the record differs, what is owed does not"
case "$LANDING_SELF" in *"Record AFTER your last push, then RE-RECORD if the head moves"*) rc=0;; *) rc=1;; esac
ck $rc "self: the LANE records (after the last push) and re-records when the head moves"
case "$LANDING_SELF" in *"insert ABOVE the footer BLOCK"*"KEEPING the blank line"*) rc=0;; *) rc=1;; esac
ck $rc "…and says how to extend a FOOTER-shaped scoping comment without destroying its position"
case "$LANDING_SELF" in *"posting a SECOND"*"satisfies the check"*) rc=0;; *) rc=1;; esac
ck $rc "…and that a second comment is accepted (the check scans every comment)"
case "$LANDING_SELF" in *'`merge-one.sh` mints'*) rc=1;; *) rc=0;; esac
ck $rc "…and is not told merge-one.sh mints it (the two roles cannot collapse)"
case "$LANDING_HARNESS" in *'`merge-one.sh` mints'*) rc=0;; *) rc=1;; esac
ck $rc "harness: merge-one.sh mints the record for this lane"
case "$LANDING_HARNESS" in *"Record AFTER your last push"*) rc=1;; *) rc=0;; esac
ck $rc "⛔ …and is NOT told to record it (this lane has no reviewer to point --evidence at)"
case "$LANDING_HARNESS" in *"do NOT amend, rebase or push again"*) rc=0;; *) rc=1;; esac
ck $rc "…its duty is the head: no amend/rebase/push once the record exists"
# ⛔ NOT JUST THE SENTENCE, THE ADVICE (cycle-3 review, P2): "in doubt use `clean`" and the stale-line
# deletion are the RECORDER's business, so a harness lane must not be handed them four lines before
# being told merge-one.sh mints the record.
case "$LANDING_HARNESS" in *"in doubt use"*|*"DELETE it"*) rc=1;; *) rc=0;; esac
ck $rc "⛔ …and is NOT given the recorder's verdict/stale-line advice (it does not run the recorder)"
case "$LANDING_SELF" in *"in doubt use"*) rc=0;; *) rc=1;; esac
ck $rc "the SELF role does carry the verdict advice (it is the one that runs the recorder)"
case "$LANDING_SELF" in *"DELETE it"*) rc=0;; *) rc=1;; esac
ck $rc "…and the stale-line deletion (the remedy for a body carrying an older verdict)"
# …and the post-record body-edit ban must carry its ONE exception, or the [c] remedy contradicts it.
# It lives in the REVIEWER brief section (where the ban is stated), not in the landing section.
case "$SELF_BRIEF" in *"ONE exception is the [c] remedy"*) rc=0;; *) rc=1;; esac
ck $rc "the body-edit ban names its one exception (deleting a stale record line — the [c] remedy)"
for L in "$LANDING_SELF" "$LANDING_HARNESS"; do has_honesty "$L"; ck $? "each role carries the no-fabrication paragraph (neither can be the honest one by accident)"; done
has_mech_1 "$LANDING_HARNESS" && has_mech_2 "$LANDING_HARNESS"; ck $? "both commit mechanics are in the harness section lane.sh splices"
# ⛔ ALL FIVE, IN BOTH ROLES (cycle-2 review, P2). §F.1 reads the composed HARNESS brief; §F.3 pins the
# template to the SELF render — so without this loop a self-branch regression (e.g. losing the recorder
# invocation) plus a regenerated template block was invisible to the whole suite.
for L in "$LANDING_SELF" "$LANDING_HARNESS"; do
  has_req_a "$L" && has_req_b "$L" && has_req_c "$L" && has_req_d "$L" && has_req_e "$L"
  ck $? "every role carries [a]-[e] (the self render is what templates/LANE-BRIEF.md pins)"
done

echo
echo "§F.3 the controller brief template mirrors the section BYTE FOR BYTE (drift-pinned block)"
BLOCK="$(awk '/^<!-- BEGIN landing-artifacts/{f=1;next} /^<!-- END landing-artifacts -->$/{exit} f' "$TEMPLATE")"
[ -n "$BLOCK" ]; ck $? "templates/LANE-BRIEF.md carries a landing-artifacts block"
if [ "$BLOCK" = "$LANDING_SELF" ]; then rc=0; else rc=1; fi
ck $rc "the block EQUALS the helper's rendered self section (one home: edit the helper, not the template)"
if grep -qF 'BEGIN landing-artifacts' "$TEMPLATE"; then rc=0; else rc=1; fi
ck $rc "…under named markers, so the pin cannot silently drift to a stale block"
grep -q 'edit THERE, not here' "$TEMPLATE" 2>/dev/null; ck $? "…and the marker says where the text actually lives"

echo
echo "§F.4 GATE PARITY — the shapes this text prescribes are the shapes the CHECK accepts"
# The section is only worth anything if its samples pass the real gate, and its warnings are true.
# Neither script sources cleanly (check-pipeline-compliance.sh is a top-level program), so its
# functions and constants are EXTRACTED and driven here — the same technique selftest.sh uses to
# drive the required-check derivation. A parser rename/removal makes this go red rather than quietly
# turning the assertions below into prose checks.
GATE="$(cd "$HERE/../.." && pwd)/scripts/check-pipeline-compliance.sh"
[ -f "$GATE" ]; ck $? "the gate scripts/check-pipeline-compliance.sh is present beside the harness"
extract_fn() { awk -v n="$1" '$0 == n"() {"{f=1} f{print} f&&/^}$/{exit}' "$GATE"; }
gate_const() { grep -E "^$1=" "$GATE" | head -1; }
eval "$(extract_fn has_scoping_marker)" 2>/dev/null
eval "$(extract_fn has_review_record)" 2>/dev/null
eval "$(extract_fn parse_issue_ref)" 2>/dev/null
# parse_trace_ref and has_test_evidence are ONE-LINERS in the gate (`name() { …; }`), so the
# brace-terminated extractor above cannot lift them; lift the LINES themselves, verbatim. A reword
# goes red in the `declare -f` guard below — it must never degrade into a local re-implementation,
# which is a copy of the gate that can agree with itself while the gate disagrees (caught in review:
# the first version declared its own `has_test_evidence` fallback and stayed green against a gate
# whose [e] matcher had been inverted).
eval "$(grep -E '^parse_trace_ref\(\) \{' "$GATE" | head -1)" 2>/dev/null
eval "$(grep -E '^has_test_evidence\(\) \{' "$GATE" | head -1)" 2>/dev/null
# …and the pattern it reads, so the extracted matcher is the gate's mechanism, not an empty variable.
eval "$(gate_const TEST_EVIDENCE_RE)" 2>/dev/null
eval "$(gate_const REVIEW_RECORD_MARKER_RE)" 2>/dev/null
eval "$(gate_const REFCTX)" 2>/dev/null
eval "$(gate_const CLOSING_KW)" 2>/dev/null
eval "$(gate_const TRACE_KW)" 2>/dev/null
GH_REPO='daniel-ospina/agent-infra'
if declare -f has_scoping_marker >/dev/null && declare -f has_review_record >/dev/null && declare -f parse_issue_ref >/dev/null && declare -f parse_trace_ref >/dev/null && declare -f has_test_evidence >/dev/null && [ -n "${REVIEW_RECORD_MARKER_RE:-}" ] && [ -n "${TEST_EVIDENCE_RE:-}" ]; then rc=0; else rc=1; fi
ck $rc "the gate's own parsers + patterns were EXTRACTED (a rename would make this section vacuous)"

# [a] — the shape the brief prescribes passes; the shape it warns about does not.
GH_REPO='daniel-ospina/agent-infra'
[ "$(parse_issue_ref $'Stuff.\n\nCloses #2325\n')" = "daniel-ospina/agent-infra#2325" ]; ck $? "[a] 'Closes #2325' at line start IS a reference"
[ "$(parse_issue_ref '- Closes #2325')" = "daniel-ospina/agent-infra#2325" ]; ck $? "…including after a bullet (the brief says so)"
[ "$(parse_issue_ref 'This (fixes #2325) inline.')" = "" ]; ck $? "⛔ …while a MID-SENTENCE '(fixes #N)' is NOT (the brief says so)"
[ "$(parse_trace_ref 'Refs #2325')" != "" ]; ck $? "…and 'Refs #N' on its own line satisfies [a] (traceability form, which the gate resolves second)"

# [b] — first content line at column 0 passes; the three mention shapes the brief warns about fail.
SC_BRIEF='<!-- issue-scoping: 2026-10-25 (standard) -->

## Scope
boundaries, alternatives, wiring table.'
has_scoping_marker "$SC_BRIEF"; ck $? "[b] the brief's shape (marker = FIRST content line, column 0) PASSES the gate"
has_scoping_marker 'Discussed first.

<!-- issue-scoping: 2026-10-25 (standard) -->'; rc=$?
[ "$rc" -eq 0 ]; ck $? "…and a BLANK-LINE-SEPARATED FOOTER is ACCEPTED (one of the two documented alternatives — an earlier draft claimed the marker must be first, and THIS gate falsified it)"
# ⛔ THE HEADING SHAPE IS THE THIRD (cycle-3 review, P2): the brief names it, so it must be driven, or a
# gate that stopped skipping headings would leave a lane following the brief rejected with §F all green.
has_scoping_marker $'## Scope — #2325\n<!-- issue-scoping: v5.1 double diamond + verify -->\n\nboundaries.'; rc=$?
[ "$rc" -eq 0 ]; ck $? "…and a leading ATX heading with the marker on the next content line is ACCEPTED (the #729/#843 shape the brief names)"
has_scoping_marker 'Discussed first.
<!-- issue-scoping: 2026-10-25 (standard) -->'; rc=$?
[ "$rc" -ne 0 ]; ck $? "⛔ …while a marker CROWDED under a preamble (no blank line) FAILS (that is the mention shape)"
# …and the FOOTER remedy has the same trap: text inserted directly above the marker (no blank line) is
# the shape the [b] remedy must not produce — measured, not assumed.
has_scoping_marker '## Scope
preamble.

NEW CONTENT
<!-- issue-scoping: 2026-10-25 (standard) -->'; rc=$?
[ "$rc" -ne 0 ]; ck $? "⛔ …and inserting text directly ABOVE a footer marker (no blank line) FAILS — the blank line is part of the shape"
has_scoping_marker '    <!-- issue-scoping: 2026-10-25 (standard) -->'; rc=$?
[ "$rc" -ne 0 ]; ck $? "⛔ …an INDENTED marker FAILS (a code block is a mention — column 0 is the contract)"
has_scoping_marker 'The artifact looks like `<!-- issue-scoping: 2026-10-25 (standard) -->` in a table.'; rc=$?
[ "$rc" -ne 0 ]; ck $? "⛔ …a quoted marker FAILS (a mention is not an artifact)"

# [c] — a record in the brief's shape binds at the current head and is STALE at an older one.
H40='0123456789abcdef0123456789abcdef01234567'
O40='89abcdef0123456789abcdef0123456789abcdef'
MARK="review recorded: reviews/2325.json verdict=clean @ $H40 (daniel-ospina/agent-infra)"
has_review_record "$MARK" 2325 daniel-ospina/agent-infra "$H40"; ck $? "[c] the brief's marker shape binds at the CURRENT head"
has_review_record "$MARK" 2325 daniel-ospina/agent-infra "$O40"; rc=$?
[ "$rc" -ne 0 ]; ck $? "⛔ …and is REFUSED once the head moves (why the brief says re-record)"
has_review_record 'code-review done, reviewer approved' 2325 daniel-ospina/agent-infra "$H40"; rc=$?
[ "$rc" -ne 0 ]; ck $? "⛔ …and no phrase satisfies [c] (only the recorder's line does)"

# [d] — the gate's OWN wiring predicate, lifted from the line that computes it (:1368). Driven as
# source, so "the brief says ## Wiring and the gate accepts it" is proved, not asserted. The brief is
# STRICTER than the gate here (the gate accepts any occurrence of the word), which is the safe
# direction and is stated in the brief itself.
WIRING_LINE="$(grep -E "^ *if grep -qi 'wiring' <<<\"\\\$SCOPING_COMMENT\"; then wiring_found=\"yes\"; fi$" "$GATE" | head -1)"
if [ -n "$WIRING_LINE" ]; then
  eval "gate_wiring_found() { local SCOPING_COMMENT=\"\$1\" wiring_found=no; ${WIRING_LINE#"${WIRING_LINE%%[![:space:]]*}"}; printf '%s' \"\$wiring_found\"; }"
  rc=0
else rc=1; fi
ck $rc "the gate's [d] wiring predicate was EXTRACTED (a reword goes red, never silently vacuous)"
WIRING_SAMPLE='<!-- issue-scoping: v5.1 double diamond + verify -->
## Scope
body.

## Wiring
| surface | change |
|---|---|
| lane.sh | splice |'
[ "$(gate_wiring_found "$WIRING_SAMPLE")" = "yes" ]; ck $? "[d] the brief's shape (a \`## Wiring\` section) satisfies the gate's wiring branch"
[ "$(gate_wiring_found '## Scope
no plan evidence here')" = "no" ]; ck $? "…and a scoping comment without one does not"

# [e] — the evidence markers the brief tells a lane to report, through the GATE's matcher.
has_test_evidence 'pytest: 412 passed, 0 failed'; ck $? "[e] 'pytest … N passed' is accepted as test evidence"
has_test_evidence 'VGATE PASS'; ck $? "…and 'VGATE PASS'"
# ⛔ AND THE DIRECTION THAT MATTERS AS MUCH (cycle-2 review, P2): a matcher that accepts EVERYTHING
# (`TEST_EVIDENCE_RE='.*'`) passed every positive above. A negative vector is what makes the parity
# two-directional.
has_test_evidence 'no evidence was produced'; rc=$?
[ "$rc" -ne 0 ]; ck $? "⛔ …while prose with NO evidence is REFUSED (an accept-everything matcher cannot pass this)"

echo
echo "§F.5 NON-VACUITY — composer-level: drop ONE requirement and the assertions fire"
# ⛔ THIS IS THE ONE THAT MATTERS. §F.1 greps text; if the composer could lose a requirement while
# the greps still passed, the whole section would be a test that cannot fail. So a COPY of the
# harness is built with ONE bullet deleted from the helper and lane.sh run against it, forbidding any
# stub of the real files: the failure must be OBSERVED in the composed brief.
STRIP="$TMP/strip"; mkdir -p "$STRIP"
cp "$HERE/spawn-gate.sh" "$STRIP/spawn-gate.sh"
cp "$LANE" "$STRIP/lane.sh"
# ⛔ THE RIG MUST CARRY THE MODULE THE LANE HARD-REQUIRES, AND ITS CWD MUST PASS THE REPO GATE
# (#2724 follow-up; the cause was MEASURED, not guessed). `lane.sh` sources `repo-target.sh` from ITS
# OWN directory and exits 78 without it; it then exits 78 AGAIN when `brief-gate.sh` cannot be resolved
# (#2258), and `brief_gate_lib` looks only in `$O`, `$SELF`, `$AGENT_INFRA_PATH/...` and
# `~/.pi/agent/scripts` — none of which exist on a CI runner or under a hidden HOME. That was the real
# reason this section composed NOTHING in CI (`rc=78 brief-gate.sh not found`, measured) while it passed
# on a dev box whose `~/.pi/agent/scripts` supplied the fallback; with no brief, the arms below reported
# ✅ on nothing — the vacuity this section exists to disprove. Same rule as `spawn-gate.test.sh`'s rig:
# copy the validator in, so resolution cannot depend on the box. The identity module is copied too.
cp "$HERE/repo-target.sh" "$STRIP/repo-target.sh"; cp "$HERE/repo-slug.sh" "$STRIP/repo-slug.sh"
cp "$HERE/brief-gate.sh" "$STRIP/brief-gate.sh"
# ⛔ AND THE GATE-POLICY MODULE, WHICH IS THE SAME CLASS OF HARD REQUIREMENT (review, P1). `lane.sh`
# sources it at L134 and `exit 78`s without it, and that source sits BEFORE the brief is composed —
# so a rig without it composed NOTHING and the two control arms below were green/failing on an empty
# artifact, the exact vacuity this section exists to forbid (measured in CI: 133 passed, 2 failed).
cp "$HERE/gate-policy.sh" "$STRIP/gate-policy.sh"
sed '/^- \*\*\[d\] plan evidence\*\*/,+2d' "$HELPER" > "$STRIP/reviewer-preflight.sh"
[ -s "$STRIP/reviewer-preflight.sh" ]; ck $? "the stripped helper copy was produced"
# The cwd is the §C fixture — a checkout of `acme/widget` that this suite already proves works in CI —
# told it is on a DIFFERENT branch. Both branch refs are created from its own HEAD and the worktree is
# DETACHED: a detached HEAD is an allowed lane shape, so the repo gate is satisfied by IDENTITY while
# the assertion under test stays the brief's. `update-ref` + detach, never a branch SWITCH, so building
# the rig cannot leave the fixture on some third branch.
for _rigbr in fix/strip fix/strip2; do
  git -C "$TMP" update-ref "refs/heads/$_rigbr" HEAD 2>/dev/null || true
done
git -C "$TMP" checkout -q --detach 2>/dev/null || true
git -C "$TMP" rev-parse --verify -q refs/heads/fix/strip >/dev/null 2>&1 \
  && git -C "$TMP" rev-parse --verify -q refs/heads/fix/strip2 >/dev/null 2>&1 \
  && [ -z "$(git -C "$TMP" symbolic-ref -q --short HEAD 2>/dev/null || true)" ]
ck $? "the non-vacuity fixture is DETACHED with both branch refs present (the lane's repo gate cannot be what refuses)"
mkdir -p "$TMP/o3/logs"
(
  cd "$TMP" || exit 1
  O="$TMP/o3" REAP_LANE_VENV_DISABLE=1 LANE_DRY_RUN=1 \
    bash "$STRIP/lane.sh" 2325 fix/strip acme/widget
) >"$TMP/o3/lane.out" 2>&1
_rc3=$?
STRIPPED="$(cat "$TMP/o3/logs/prompt-2325.txt" 2>/dev/null || true)"
# ⛔ NAME THE REASON ON THE SPOT (a rig that silently composes nothing is what hid the defect): the
# lane's own stdout/stderr is printed the moment the artifact is absent, so the CI log says WHY.
if [ -z "$STRIPPED" ]; then echo "  · [d]-strip lane refused/failed (rc=$_rc3) — its output follows:"; sed -n '1,6p' "$TMP/o3/lane.out"; fi
# ⛔ COMPOSITION IS A PRECONDITION OF THE ARM, NOT A NOTE BESIDE IT (review, P2). `has_req_d ""` fails by
# construction, so this arm was GREEN on an empty file — it could not tell "stripped correctly" from
# "composed nothing", which is the exact sentence in the comment above. A rig that produced no brief now
# fails the arm that claims it.
_composed3=1; [ -n "$STRIPPED" ] || _composed3=0
has_req_d "$STRIPPED"; rc=$?
[ "$_composed3" = "1" ] && [ "$rc" -ne 0 ]; ck $? "⛔ removing the [d] bullet from the composer MAKES the §F.1 [d] assertion FAIL (non-vacuous, and the rig composed a brief)"
has_req_a "$STRIPPED" && has_req_e "$STRIPPED"; ck $? "…and the untouched requirements still pass (the control is targeted, not a broken fixture)"
# …and the same control for the HEAD-BINDING sentence, which is the rule a lane most needs.
STRIP2="$TMP/strip2"; mkdir -p "$STRIP2"
cp "$HERE/spawn-gate.sh" "$STRIP2/spawn-gate.sh"; cp "$LANE" "$STRIP2/lane.sh"
cp "$HERE/repo-target.sh" "$STRIP2/repo-target.sh"; cp "$HERE/repo-slug.sh" "$STRIP2/repo-slug.sh"
cp "$HERE/brief-gate.sh" "$STRIP2/brief-gate.sh"
cp "$HERE/gate-policy.sh" "$STRIP2/gate-policy.sh"   # same hard requirement as the first rig (review, P1)
sed "s#$LANDING_HEAD_BINDING##" "$HELPER" > "$STRIP2/reviewer-preflight.sh"
[ -s "$STRIP2/reviewer-preflight.sh" ]; ck $? "the head-binding-stripped helper copy was produced"
mkdir -p "$TMP/o4/logs"
(
  cd "$TMP" || exit 1
  O="$TMP/o4" REAP_LANE_VENV_DISABLE=1 LANE_DRY_RUN=1 \
    bash "$STRIP2/lane.sh" 2325 fix/strip2 acme/widget
) >"$TMP/o4/lane.out" 2>&1
_rc4=$?
STRIPPED2="$(cat "$TMP/o4/logs/prompt-2325.txt" 2>/dev/null || true)"
if [ -z "$STRIPPED2" ]; then echo "  · head-binding strip lane refused/failed (rc=$_rc4) — its output follows:"; sed -n '1,6p' "$TMP/o4/lane.out"; fi
# ⛔ THE FIXTURE MUST HAVE COMPOSED (review, P2): an absent/empty artifact is indistinguishable from a
# successful strip, so this control asserts the ONE-THING-CHANGED shape: the other requirements are
# still on the brief, and only the stripped sentence is gone.
has_req_a "$STRIPPED2" && has_req_e "$STRIPPED2"; ck $? "the head-binding fixture still composed a brief with [a] and [e] (not an empty file)"
case "$STRIPPED2" in *"a moved head must be RE-RECORDED at the new head"*) rc=0;; *) rc=1;; esac
_composed4=1; [ -n "$STRIPPED2" ] || _composed4=0
[ "$_composed4" = "1" ] && [ "$rc" -ne 0 ]; ck $? "⛔ removing the HEAD-BINDING sentence MAKES the §F.1 head-binding assertion FAIL (and the rig composed a brief)"

echo

echo "§G commit as you go — a cap kill must leave a PR behind (#2981)"
# THE DEFECT (agent-infra#2981, measured 2026-10-27/28). Five `prfix` lanes, one batch: all five
# killed at their 2400 s cap, **0 commits, 0 PRs, 144 KB of work** recovered only as rescue patches.
# The rescue worked; the work still reached no PR, and the next run had to adopt its predecessor's
# tree before it could add a line. The briefs those lanes received carried the research contract, the
# reviewer step, the landing artifacts and the push refspec — and never the cheapest rule of all.
# These arms read the ARTIFACT a worker receives, never the helper's own prose.
DELIVERY_LANE="$(delivery_brief_section lane)"
DELIVERY_PRFIX="$(delivery_brief_section prfix)"
delivery_brief_section banana >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ]; ck $? "an unknown role is a usage error (2), never the wrong audience's PR duty"

# ONE predicate per requirement, shared by the composed-brief arm AND the non-vacuity controls.
has_commit_rule() { case "$1" in *"Commit as soon as you have a coherent unit, push it, then KEEP IMPROVING it"*) return 0;; *) return 1;; esac; }
has_push_each()   { case "$1" in *"Push after every commit"*) return 0;; *) return 1;; esac; }
has_cap_reason()  { case "$1" in *"killed at its"*"cap takes the uncommitted tree with it"*) return 0;; *) return 1;; esac; }
has_resume()      { case "$1" in *'read `git status` and `git diff` FIRST'*"PREDECESSOR's work on"*) return 0;; *) return 1;; esac; }
has_adopt()       { case "$1" in *"Never discard"*'`git checkout -- .`'*'`git reset --hard`'*) return 0;; *) return 1;; esac; }
has_open_pr()     { case "$1" in *"Open the PR as soon as the first commit is pushed"*) return 0;; *) return 1;; esac; }
has_no_second()   { case "$1" in *"do NOT open a second PR"*) return 0;; *) return 1;; esac; }

for _p in has_commit_rule has_push_each has_cap_reason has_resume has_adopt; do
  "$_p" "$DELIVERY_LANE"; ck $? "the helper renders it ($_p)"
done

# §G.1 THE ARTIFACT, NOT THE HELPER: the brief a lane.sh lane would ACTUALLY be given (§C composed it).
echo
echo "§G.1 the composed brief a lane.sh lane RECEIVES"
[ -s "$BRIEF_FILE" ]; ck $? "the composed brief from §C is non-empty (an empty artifact fails every arm below)"
COMPOSED_G="$(cat "$BRIEF_FILE" 2>/dev/null || true)"
has_commit_rule "$COMPOSED_G"; ck $? "the imperative: commit as soon as you have a coherent unit, then KEEP IMPROVING"
has_push_each   "$COMPOSED_G"; ck $? "…push after every commit (not once at the end)"
has_cap_reason  "$COMPOSED_G"; ck $? "…and WHY: the cap kill takes the uncommitted tree with it"
has_resume      "$COMPOSED_G"; ck $? "resume: read git status / git diff FIRST — the tree is your predecessor's work"
has_adopt       "$COMPOSED_G"; ck $? "…and ADOPT it: never checkout -- . / stash / clean / reset --hard over it"
has_open_pr     "$COMPOSED_G"; ck $? "the lane role opens its OWN PR as soon as the first commit is pushed"
has_no_second   "$COMPOSED_G"; ck $? "…and is told not to open a SECOND PR"
case "$COMPOSED_G" in *"$DELIVERY_BRIEF_HEADING"*) rc=0;; *) rc=1;; esac
ck $rc "…under the findable heading the helper owns"
# The rule must not have DISPLACED what the brief already said.
grep -q '## RESEARCH FIRST' "$BRIEF_FILE" 2>/dev/null; ck $? "…and the research contract SURVIVES the insertion"
grep -q '## Reviewer step' "$BRIEF_FILE" 2>/dev/null; ck $? "…as does the reviewer step"
grep -q '## Deliverable' "$BRIEF_FILE" 2>/dev/null; ck $? "…and the Deliverable section"

# §G.2 ROLE-CORRECT ON ONE SENTENCE. `pr-doctor.py` dispatches its worker TO AN EXISTING PR, so
# ordering that worker to "open the PR" would be a FALSE instruction (the #2148/#2325 untruth class).
echo
echo "§G.2 role-correct on the PR sentence only — what is owed is identical"
has_no_second "$DELIVERY_PRFIX"; ck $? "prfix: the PR is ALREADY OPEN, so it must not open a second one"
has_open_pr "$DELIVERY_PRFIX"; rc=$?
[ "$rc" -ne 0 ]; ck $? "⛔ …and is NOT told to open a PR it already has"
for _p in has_commit_rule has_push_each has_cap_reason has_resume has_adopt; do
  "$_p" "$DELIVERY_PRFIX"; ck $? "prfix carries the same rule: $_p"
done

# §G.3 THE CONTROLLER TEMPLATE — the authored-brief source. Byte for byte, or it is a second copy.
echo
echo "§G.3 templates/LANE-BRIEF.md mirrors the section BYTE FOR BYTE (drift-pinned block)"
DBLOCK="$(awk '/^<!-- BEGIN delivery-contract/{f=1;next} /^<!-- END delivery-contract -->$/{exit} f' "$TEMPLATE")"
[ -n "$DBLOCK" ]; ck $? "the template carries a delivery-contract block"
if [ "$DBLOCK" = "$DELIVERY_LANE" ]; then rc=0; else rc=1; fi
ck $rc "the block EQUALS the helper's rendered lane section (one home: edit the helper, not the template)"
grep -qF 'BEGIN delivery-contract' "$TEMPLATE"; ck $? "…under named markers, so the pin cannot drift silently"
grep -q 'edit THERE, not here' "$TEMPLATE"; ck $? "…and the marker says where the text actually lives"

# §G.4 NON-VACUITY, both levels.
echo
echo "§G.4 NON-VACUITY — the arms above can fail"
# (a) predicate level: strip the clause from the COMPOSED text; the SAME predicate must fire.
NO_COMMIT="$(printf '%s\n' "$COMPOSED_G" | sed 's/Commit as soon as you have a coherent unit, push it, then KEEP IMPROVING it/./')"
has_commit_rule "$NO_COMMIT"; rc=$?
[ "$rc" -ne 0 ]; ck $? "stripping the imperative MAKES has_commit_rule FAIL"
NO_RESUME="$(printf '%s\n' "$COMPOSED_G" | sed 's/PREDECESSOR.s work on/./')"
has_resume "$NO_RESUME"; rc=$?
[ "$rc" -ne 0 ]; ck $? "…stripping the resume half MAKES has_resume FAIL (both halves are pinned)"
# (b) composer level: a helper that renders the section WITHOUT its heading must make lane.sh REFUSE.
# That is lane.sh's BUILD-TIME guard, and without this arm it could be inert (exit 0, or a grep that
# never matches) while every arm above stayed green — the no-op-gate shape.
STRIPG="$TMP/stripg"; mkdir -p "$STRIPG"
cp "$HERE/spawn-gate.sh" "$STRIPG/spawn-gate.sh"; cp "$LANE" "$STRIPG/lane.sh"
cp "$HERE/repo-target.sh" "$STRIPG/repo-target.sh"; cp "$HERE/repo-slug.sh" "$STRIPG/repo-slug.sh"
cp "$HERE/brief-gate.sh" "$STRIPG/brief-gate.sh"; cp "$HERE/gate-policy.sh" "$STRIPG/gate-policy.sh"
sed "s#^DELIVERY_BRIEF_HEADING=.*#DELIVERY_BRIEF_HEADING=''#" "$HELPER" > "$STRIPG/reviewer-preflight.sh"
grep -q "^DELIVERY_BRIEF_HEADING=''$" "$STRIPG/reviewer-preflight.sh"; ck $? "the heading-stripped helper copy was produced"
for _rigbr in fix/stripg; do git -C "$TMP" update-ref "refs/heads/$_rigbr" HEAD 2>/dev/null || true; done
mkdir -p "$TMP/o5/logs"
(
  cd "$TMP" || exit 1
  O="$TMP/o5" REAP_LANE_VENV_DISABLE=1 LANE_DRY_RUN=1 \
    bash "$STRIPG/lane.sh" 2981 fix/stripg acme/widget
) >"$TMP/o5/lane.out" 2>&1
_rc5=$?
[ "$_rc5" = "78" ]; ck $? "⛔ a composer that loses the section REFUSES the lane with 78 — the build-time guard is LIVE (rc=$_rc5)"
grep -q 'COMMIT-AS-YOU-GO' "$TMP/o5/lane.out" 2>/dev/null; ck $? "…and says WHICH section was lost, in the refusal"

# §G.5 ONE SOURCE, ASSERTED. The heading literal must live in the helper (its definition) and in the
# drift-pinned template copy — nowhere else. A second copy is the drift this section exists to refuse.
echo
echo "§G.5 the heading has ONE home (plus the pinned template copy)"
STRAY=""
for _f in "$TEMPLATE" "$LANE" "$HERE/fix-one.sh" "$HERE/brief-gate.sh" "$HERE/spawn-gate.sh" \
          "$HERE/nonblocking-dispatch.sh" "$(cd "$HERE/../.." && pwd)/scripts/pr-doctor.py"; do
  [ -f "$_f" ] || continue
  case "$_f" in "$TEMPLATE"|"$HELPER") continue;; esac
  grep -qF "$DELIVERY_BRIEF_HEADING" "$_f" 2>/dev/null && STRAY="$STRAY $_f"
done
[ -z "$STRAY" ]; ck $? "no composer carries its own copy of the section (stray:${STRAY:- none})"
# …and every composer that hands a worker a brief OBTAINS it from the helper.
for _f in "$LANE" "$HERE/fix-one.sh" "$HERE/nonblocking-dispatch.sh"; do
  grep -q 'delivery_brief_section\|--delivery-brief' "$_f" 2>/dev/null; ck $? "$(basename "$_f") splices the canonical section"
done
grep -q 'delivery_brief_section\|--delivery-brief' "$(cd "$HERE/../.." && pwd)/scripts/pr-doctor.py" 2>/dev/null
ck $? "pr-doctor.py splices the canonical section"

echo

echo "================ RESULT: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
