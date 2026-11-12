#!/usr/bin/env bash
# verify-landing-chain.test.sh — offline suite for verify-landing-chain.sh.
#
# HERMETIC: every case is a SNAPSHOT DIRECTORY (`--from-snapshot`), so there is no network, no gh, no
# clock. The point of each case is a DECISION that has already been wrong once, in the direction that
# costs the most:
#
#   * a FALSE FAIL on a correct landing (case 3). The first cut compared `tree(reviewed)` to
#     `tree(merge)` and failed PR #3996 — main had moved between the branch point and the squash, so
#     the trees legitimately differ. A verifier that fails correct landings gets ignored, which is
#     the same outcome as not having one.
#   * a FALSE PASS on a re-run that laundered a red (cases 6, 7). A re-run ADDS a check-run; it does
#     not clear the old one. Counting "the newest attempt overall" instead of "the newest attempt
#     that had completed by mergedAt" reports a red landing green.
#   * a FALSE PASS on a same-named job in a different workflow (case 8). Two workflows can publish
#     `packaging-smoke`; grouping by the name alone lets the newer of one mask the older of the other.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/verify-landing-chain.sh"
pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail + 1)); }
ck()  { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi; }

T="$(mktemp -d)"; MUT="$T/mut"; trap 'rm -rf "$T"' EXIT
[ -s "$SCRIPT" ] || { bad "verify-landing-chain.sh is missing or empty"; exit 1; }

# ── fixture helpers ───────────────────────────────────────────────────────────────────────────────
# One snapshot = one PR. Defaults describe a CLEAN landing; a case overrides only what it is about, so
# a case's name is the whole difference it asserts.
REPO_FIXTURE="o/r"
MERGED_AT="2026-11-12T05:05:55Z"
HEAD="1111111111111111111111111111111111111111"
MERGE="2222222222222222222222222222222222222222"
HEAD_TREE="d950506a5b5500000000000000000000000000aa"
LAND_TREE="a2d8a39b183a00000000000000000000000000bb"

mk() { # mk <case-name> <pr>  → prints the snapshot root
  local root="$T/$1" pr="$2"
  mkdir -p "$root/pr-$pr"
  printf '%s\n' "$REPO_FIXTURE" > "$root/repo.txt"
  printf '%s\t%s\t%s\t%s\n' "$pr" MERGED "$MERGED_AT" "$MERGE" > "$root/pr-$pr/pr.meta"
  printf '%s\n' "$HEAD" > "$root/pr-$pr/pr-commits.tsv"
  printf '%s\t%s\t\n' "$MERGE" "$LAND_TREE" > "$root/pr-$pr/commit-$MERGE.tsv"
  printf '%s\t%s\t\n' "$HEAD" "$HEAD_TREE" > "$root/pr-$pr/commit-$HEAD.tsv"
  printf 'review recorded: reviews/%s.json verdict=clean @ %s (o/r)\n' "$pr" "$HEAD" > "$root/pr-$pr/body.txt"
  : > "$root/pr-$pr/comments.txt"
  printf '%s\n' "$root"
}

# group <root> <pr> <check-run id> <workflow-run-id> <job name> <status> <conclusion> <completed_at>
# run   <root> <pr> <workflow-run-id> <workflow name> <run attempt>
group() {
  local d="$1/pr-$2"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$3" "github-actions" "$5" "$6" "$7" "$8" \
    "https://github.com/o/r/actions/runs/$4/job/1" >> "$d/checkruns-$HEAD.tsv"
}
run() { printf '%s\t%s\t%s\n' "$3" "$4" "$5" >> "$1/pr-$2/runs-$HEAD.tsv"; }
# Both surfaces are captured for every case: the TEXT report is what a human reads (so its DETAIL is
# asserted where the detail is the finding), and the JSON is what a report file consumes (so its SHAPE
# is asserted where the verdict is the finding). Asserting one and reading the other is how a suite
# passes over a report nobody can parse.
verify() { # verify <root> [extra args]  → sets OUT (text), OUTJ (json), returns the script's exit code
  local root="$1"; shift
  OUT="$(bash "$SCRIPT" --from-snapshot "$root" --repo "$REPO_FIXTURE" "$@" 2>&1)"
  rc=$?
  OUTJ="$(bash "$SCRIPT" --from-snapshot "$root" --repo "$REPO_FIXTURE" --json "$@" 2>&1)"
  return $rc
}
has()  { printf '%s' "$OUT"  | grep -qF -- "$1"; }
hasj() { printf '%s' "$OUTJ" | grep -qF -- "$1"; }

# ── case 1: the clean landing — every check PASS, exit 0 ─────────────────────────────────────────
R="$(mk clean 401)"
run "$R" 401 9001 "CI" 1; group "$R" 401 10 9001 "unit-test" completed success "$MERGED_AT"
printf 'admin-merge: ok\n' > "$R/pr-401/rail.out"
verify "$R" --json; rc=$?
ck "clean landing exits 0" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"
ck "clean landing: review_bound PASS (reviewed head IS the final commit)" "$(hasj '"check":"review_bound","verdict":"PASS"'; echo $?)"
ck "clean landing: green_gated PASS" "$(hasj '"check":"green_gated","verdict":"PASS"'; echo $?)"
ck "clean landing: rail_landed PASS" "$(hasj '"check":"rail_landed","verdict":"PASS"'; echo $?)"
ck "clean landing: --json is parseable JSON" "$(printf '%s' "$OUTJ" | python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; echo $?)"

# ── case 2: code pushed AFTER the review — the attestation stands over content nobody reviewed ────
R="$(mk pushed-after-review 402)"
printf '%s\n%s\n' "$HEAD" "3333333333333333333333333333333333333333" > "$R/pr-402/pr-commits.tsv"
run "$R" 402 9001 "CI" 1; group "$R" 402 10 9001 "unit-test" completed success "$MERGED_AT"
verify "$R"; rc=$?
ck "pushed-after-review exits 1" "$([ "$rc" -eq 1 ] && echo 0 || echo 1)"
ck "pushed-after-review: review_bound FAIL" "$(has "commits pushed AFTER the review and never re-reviewed: 333333333333"; echo $?)"

# ── case 3: ⛔ THE MEASURED FALSE FAIL — main moved, so trees differ, but the head IS the tip ─────
# Reproduces PR #3996: head tree != merge tree, reviewed head == the PR's last commit. MUST PASS.
R="$(mk squash-main-moved 403)"
run "$R" 403 9001 "CI" 1; group "$R" 403 10 9001 "unit-test" completed success "$MERGED_AT"
printf 'admin-merge: ok\n' > "$R/pr-403/rail.out"
verify "$R"; rc=$?
ck "squash-main-moved: review_bound PASS despite differing trees (#3996 regression)" "$(hasj '"check":"review_bound","verdict":"PASS"'; echo $?)"
ck "squash-main-moved exits 0" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"

# ── case 4: a not-clean verdict superseded at a new head — the fix round DID happen ───────────────
R="$(mk fix-round 404)"
{
  printf 'review recorded: reviews/404.json verdict=not-clean @ %s (o/r) findings=1\n' "$HEAD"
  printf 'review recorded: reviews/404.json verdict=clean @ %s (o/r)\n' "4444444444444444444444444444444444444444"
} > "$R/pr-404/body.txt"
printf '%s\n%s\n' "$HEAD" "4444444444444444444444444444444444444444" > "$R/pr-404/pr-commits.tsv"
run "$R" 404 9001 "CI" 1; group "$R" 404 10 9001 "unit-test" completed success "$MERGED_AT"
verify "$R"
ck "fix-round: fix_round PASS (not-clean superseded at a new head)" "$(has "was superseded by clean@444444444444"; echo $?)"

# ── case 5: a not-clean that was never superseded — condition 4 unmet ────────────────────────────
R="$(mk no-fix-round 405)"
printf 'review recorded: reviews/405.json verdict=not-clean @ %s (o/r) findings=2\n' "$HEAD" > "$R/pr-405/body.txt"
run "$R" 405 9001 "CI" 1; group "$R" 405 10 9001 "unit-test" completed success "$MERGED_AT"
verify "$R"; rc=$?
ck "no-fix-round: fix_round FAIL" "$(has "was never superseded by a record at a different head"; echo $?)"
ck "no-fix-round exits 1" "$([ "$rc" -eq 1 ] && echo 0 || echo 1)"

# ── case 6: ⛔ THE RE-RUN LAUNDER — red completed BEFORE the merge, green AFTER. Must stay RED. ──
R="$(mk rerun-launder 406)"
run "$R" 406 9001 "CI" 1
group "$R" 406 10 9001 "pipeline-compliance" completed failure   "2026-11-12T04:41:17Z"
group "$R" 406 20 9001 "pipeline-compliance" completed success   "2026-11-12T05:24:50Z"   # after 05:05:55
verify "$R"; rc=$?
ck "rerun-launder: green_gated FAIL (a green that finished after the merge gated nothing)" "$(has "green exists but completed AFTER mergedAt"; echo $?)"
ck "rerun-launder exits 1" "$([ "$rc" -eq 1 ] && echo 0 || echo 1)"

# ── case 7: the same shape, but the green DID complete before the merge → PASS ───────────────────
R="$(mk rerun-before-merge 407)"
run "$R" 407 9001 "CI" 1
group "$R" 407 10 9001 "pipeline-compliance" completed failure "2026-11-12T04:41:17Z"
group "$R" 407 20 9001 "pipeline-compliance" completed success "2026-11-12T05:01:00Z"
verify "$R"
ck "rerun-before-merge: green_gated PASS (the re-run is what the landing saw)" "$(hasj '"check":"green_gated","verdict":"PASS"'; echo $?)"

# ── case 8: ⛔ SAME JOB NAME, TWO WORKFLOWS — the name-only grouping masks a red ─────────────────
# Workflow A publishes `packaging-smoke` success (newer id 30); workflow B publishes the same name
# failure (older id 20). Grouped by (app, workflow, name) these are TWO groups and B is RED. Grouped
# by the NAME alone the newer id 30 wins and the red disappears — the exact masking measured on real
# check-runs. The verdict must be FAIL.
R="$(mk same-name-two-workflows 408)"
run "$R" 408 9001 "Workflow A" 1; run "$R" 408 9002 "Workflow B" 1
group "$R" 408 20 9002 "packaging-smoke" completed failure "2026-11-12T04:00:00Z"
group "$R" 408 30 9001 "packaging-smoke" completed success "2026-11-12T04:10:00Z"
verify "$R"; rc=$?
ck "same-name-two-workflows: green_gated FAIL (name-only grouping would have masked the red)" "$(has "Workflow B/packaging-smoke:failure"; echo $?)"

# ── case 9: an UNRESOLVABLE workflow is grouped under its app, never dropped ─────────────────────
R="$(mk no-workflow 409)"
printf '30\tgithub-actions\topaque-check\tcompleted\tfailure\t2026-11-12T04:00:00Z\t-\n' > "$R/pr-409/checkruns-$HEAD.tsv"
verify "$R"
ck "no-workflow: an app-only check still forms a group and can go red" "$(has "app:github-actions/opaque-check:failure"; echo $?)"

# ── case 10: a novel conclusion is RED (allow-list polarity), and `cancelled` is not ─────────────
R="$(mk novel-conclusion 410)"
run "$R" 410 9001 "CI" 1
group "$R" 410 10 9001 "unit-test" completed success "2026-11-12T04:00:00Z"
group "$R" 410 20 9001 "startup" completed startup_failure "2026-11-12T04:01:00Z"
verify "$R"
ck "novel-conclusion: an undocumented conclusion is RED, never a pass" "$(has "CI/startup:startup_failure"; echo $?)"
R="$(mk cancelled-not-red 411)"
run "$R" 411 9001 "CI" 1
group "$R" 411 10 9001 "unit-test" completed success "2026-11-12T04:00:00Z"
group "$R" 411 20 9001 "flaky" completed cancelled "2026-11-12T04:01:00Z"
verify "$R"
ck "cancelled-not-red: a cancelled attempt is non-red" "$(hasj '"check":"green_gated","verdict":"PASS"'; echo $?)"

# ── case 11: an UNREAD surface is INCONCLUSIVE, never green ──────────────────────────────────────
R="$(mk surface-unreadable 412)"
printf '%s\n' "$HEAD" > "$R/pr-412/pr-commits.tsv"
verify "$R"; rc=$?
ck "surface-unreadable: green_gated INCONCLUSIVE" "$(hasj '"check":"green_gated","verdict":"INCONCLUSIVE"'; echo $?)"
ck "surface-unreadable exits 2 (an unread check is never a pass)" "$([ "$rc" -eq 2 ] && echo 0 || echo 1)"

# ── case 12: an empty surface attached NOTHING — a FAIL, not a pass ──────────────────────────────
R="$(mk surface-empty 413)"
run "$R" 413 9001 "CI" 1
: > "$R/pr-413/checkruns-$HEAD.tsv"
verify "$R"
ck "surface-empty: green_gated FAIL (nothing attached is a measured zero, not an unknown)" "$(has "NOTHING had attached a verdict"; echo $?)"

# ── case 13: the landing route — override is a FAIL, chain is a FAIL, rail is a PASS ─────────────
R="$(mk route-override 414)"
run "$R" 414 9001 "CI" 1; group "$R" 414 10 9001 "unit-test" completed success "$MERGED_AT"
printf 'admin-merge: merged via AGENT_ADMIN_MERGE_OVERRIDE=1 (logged as admin_merge_override)\n' > "$R/pr-414/rail.out"
verify "$R"
ck "route-override: rail_landed FAIL (condition 6 forbids a certificate bypass)" "$(has "an admin-merge override is recorded"; echo $?)"
R="$(mk route-chain 415)"
run "$R" 415 9001 "CI" 1; group "$R" 415 10 9001 "unit-test" completed success "$MERGED_AT"
: > "$R/pr-415/chain.merged"
verify "$R"
ck "route-chain: rail_landed FAIL (the chain landed it, not auto-rail)" "$(has "landed by the per-PR chain, not by auto-rail"; echo $?)"
R="$(mk route-absent 416)"
run "$R" 416 9001 "CI" 1; group "$R" 416 10 9001 "unit-test" completed success "$MERGED_AT"
verify "$R"
ck "route-absent: rail_landed INCONCLUSIVE (no artifact ⇒ unknown, never a pass)" "$(hasj '"check":"rail_landed","verdict":"INCONCLUSIVE"'; echo $?)"

# ── case 14: an unmerged PR has no landing to verify ──────────────────────────────────────────────
R="$(mk unmerged 417)"
printf '%s\t%s\t%s\t%s\n' 417 OPEN - - > "$R/pr-417/pr.meta"
verify "$R"
ck "unmerged: merged FAIL" "$(hasj '"check":"merged","verdict":"FAIL"'; echo $?)"

# ── case 15: the record-file FALLBACK (a body with no marker) is a weaker but valid source ───────
R="$(mk record-file-fallback 418)"
: > "$R/pr-418/body.txt"
printf '{"pr":418,"head_sha":"%s","verdict":"clean","repo":"o/r"}\n' "$HEAD" > "$R/pr-418/record.json"
run "$R" 418 9001 "CI" 1; group "$R" 418 10 9001 "unit-test" completed success "$MERGED_AT"
verify "$R"
ck "record-file-fallback: review_record PASS with source=record-file" "$(has "source=record-file"; echo $?)"

# ── case 16: NO record at all is INCONCLUSIVE — an absent attestation is not a clean one ─────────
R="$(mk no-record 419)"
: > "$R/pr-419/body.txt"
run "$R" 419 9001 "CI" 1; group "$R" 419 10 9001 "unit-test" completed success "$MERGED_AT"
verify "$R"; rc=$?
ck "no-record: review_record INCONCLUSIVE" "$(hasj '"check":"review_record","verdict":"INCONCLUSIVE"'; echo $?)"
ck "no-record exits 2 (never a pass by silence)" "$([ "$rc" -eq 2 ] && echo 0 || echo 1)"

# ── case 17: an unmerged PR under --from-snapshot with no PR argument is VERIFIED, not skipped ────
# A snapshot root with two PRs must report both; a reader that silently verified only the first would
# make a two-PR record look like complete evidence.
ROOT="$T/multi"
mkdir -p "$ROOT"
printf '%s\n' "$REPO_FIXTURE" > "$ROOT/repo.txt"
for p in 420 421; do
  cp -R "$T/clean/pr-401" "$ROOT/pr-$p"
  sed -i.bak -e "s/^401/$p/" "$ROOT/pr-$p/pr.meta" 2>/dev/null || true
  rm -f "$ROOT/pr-$p"/*.bak
done
OUT="$(bash "$SCRIPT" --from-snapshot "$ROOT" --repo "$REPO_FIXTURE" 2>&1)"
n="$(printf '%s\n' "$OUT" | grep -c '^PR #')"
ck "snapshot-auto: every PR in the snapshot is verified (saw $n of 2)" "$([ "$n" -eq 2 ] && echo 0 || echo 1)"

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# THE FOUR FINDINGS FROM THE FRESH-CONTEXT REVIEW AT 4d23b74b2 — one case each, because each was a
# defect this file shipped and each was reachable in ONE of the two directions that matter.
# ══════════════════════════════════════════════════════════════════════════════════════════════════

# F1 — a group that had STARTED but not voted when the merge happened is not a green.
# Before the fix, one green + two such groups printed "3 group(s) green" and PASSed.
R="$(mk f1-waited 440)"
run "$R" 440 9001 "CI" 1
group "$R" 440 10 9001 "unit-test"           completed success "2026-11-12T04:00:00Z"
group "$R" 440 20 9001 "vendor-drift"        in_progress -     "-"
group "$R" 440 30 9001 "pipeline-compliance" in_progress -     "-"
# started_at is field 8; rewrite the two in-flight rows so they began BEFORE the merge
awk -F'\t' 'BEGIN{OFS="\t"} $3=="vendor-drift" || $3=="pipeline-compliance" { $8="2026-11-12T04:30:00Z" } { print }' \
  "$R/pr-440/checkruns-$HEAD.tsv" > "$R/pr-440/c2" && mv "$R/pr-440/c2" "$R/pr-440/checkruns-$HEAD.tsv"
verify "$R"; rc=$?
ck "F1: an in-flight-at-merge group is not a green (no '3 group(s) green')" "$(has "did not wait for"; echo $?)"
if has "3 group(s) GREEN"; then
  bad "F1: the report still claims 3 green when only 1 group voted"
else
  ok "F1: no 3-green claim — the count is of groups that actually voted green"
fi

# F1b — a group with NO run at all by mergedAt (a post-merge job) is excluded, not counted
R="$(mk f1-later 441)"
run "$R" 441 9001 "CI" 1
group "$R" 441 10 9001 "unit-test" completed success "2026-11-12T04:00:00Z"
group "$R" 441 20 9001 "post-merge" completed success "2026-11-12T06:00:00Z"   # started after mergedAt
awk -F'\t' 'BEGIN{OFS="\t"} $3=="post-merge" { $8="2026-11-12T05:40:00Z" } { print }' \
  "$R/pr-441/checkruns-$HEAD.tsv" > "$R/pr-441/c2" && mv "$R/pr-441/c2" "$R/pr-441/checkruns-$HEAD.tsv"
printf 'admin-merge: ok\n' > "$R/pr-441/rail.out"
verify "$R"
ck "F1b: a post-merge-only group is excluded and the GREEN count is the measured 1" "$(has "1 group(s) GREEN"; echo $?)"

# F2a — an UNREAD surface is INCONCLUSIVE, never a measured zero (the fail-closed direction)
R="$(mk f2-unread 442)"
run "$R" 442 9001 "CI" 1
# the ORIGINAL bug left the truncated 0-byte artifact behind; both are present here on purpose, so a
# regression that stops honouring the sentinel lands on "measured zero" (FAIL) and this case flips.
: > "$R/pr-442/checkruns-$HEAD.tsv"
: > "$R/pr-442/checkruns-$HEAD.tsv.unread"
verify "$R"; rc=$?
ck "F2a: a rate-limited check-runs read is INCONCLUSIVE, not FAIL" "$(has "was NOT READ" ; echo $?)"
ck "F2a: …and the run exits 2 (unknown), not 1" "$([ "$rc" -eq 2 ] && echo 0 || echo 1)"

# F2b — an UNREAD runs list is INCONCLUSIVE too: without run ids the app-only fallback merges two
# workflows that publish the same job name, so a failed read could mask a red in the GREEN direction.
R="$(mk f2-unread-runs 443)"
printf '9001\tWorkflow A\t1\n' > "$R/pr-443/runs-$HEAD.tsv"
: > "$R/pr-443/runs-$HEAD.tsv.unread"
run "$R" 443 9001 "CI" 1
group "$R" 443 10 9001 "unit-test" completed success "2026-11-12T04:00:00Z"
verify "$R"
ck "F2b: an unread workflow list is INCONCLUSIVE (grouping would be unsound)" "$(has "was NOT READ"; echo $?)"

# F3 — a marker naming ANOTHER repo is not evidence for this head
R="$(mk f3-foreign-marker 444)"
: > "$R/pr-444/body.txt"
printf '<<<COMMENT>>>\nreview recorded: reviews/444.json verdict=clean @ %s (someone-else/other-repo)\n' "$HEAD" \
  > "$R/pr-444/comments.txt"
run "$R" 444 9001 "CI" 1; group "$R" 444 10 9001 "unit-test" completed success "$MERGED_AT"
verify "$R"
ck "F3: a foreign-repo marker is REFUSED, not adopted (review_record INCONCLUSIVE)" "$(hasj '"check":"review_record","verdict":"INCONCLUSIVE"'; echo $?)"
ck "F3: …and the refusal is named" "$(has "refused as naming another repo"; echo $?)"

# F3b — a comment-only marker IS admitted, but declared as the weaker source the recorder refuses
R="$(mk f3-comment-marker 445)"
: > "$R/pr-445/body.txt"
printf '<<<COMMENT>>>\nreview recorded: reviews/445.json verdict=clean @ %s (o/r)\n' "$HEAD" > "$R/pr-445/comments.txt"
run "$R" 445 9001 "CI" 1; group "$R" 445 10 9001 "unit-test" completed success "$MERGED_AT"
printf 'admin-merge: ok\n' > "$R/pr-445/rail.out"
verify "$R"
ck "F3b: a comment-only marker is admitted as source=marker-comment (declared weaker)" "$(has "source=marker-comment"; echo $?)"

# F4 — a PR-number-keyed chain marker outside this PR's merge window is not proof (chain-merge.sh:246)
R="$(mk f4-out-of-window 446)"
run "$R" 446 9001 "CI" 1; group "$R" 446 10 9001 "unit-test" completed success "$MERGED_AT"
: > "$R/pr-446/chain.merged.out-of-window"
verify "$R"
ck "F4: an out-of-window chain marker leaves the route UNKNOWN, not chain-attributed" "$(has "OUTSIDE this PR's merge window"; echo $?)"

# ── MUTATIONS: prove every case above is DISCRIMINATING, not merely green ───────────────────────
# ⛔ A suite that passes over BOTH the real script and a deliberately wrong one asserts nothing. Each
# mutation below breaks exactly the decision one case exists for; the case must then FLIP. This is the
# same non-vacuity discipline `tools/fleet/outcome_canary.test.py --mutations` applies, and the reason
# it is here: two of the three mutations are defects this file actually shipped with for one round
# (tree equality instead of final-commit binding; the re-run read as "newest overall").
mutant() { # mutant <name> <python-old> <python-new> → prints the path of a mutated copy
  local d="$MUT/$1"
  mkdir -p "$d"
  cp "$SCRIPT" "$d/verify-landing-chain.sh"
  python3 - "$d/verify-landing-chain.sh" "$2" "$3" <<'PYEOF' || return 1
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
if s.count(old) != 1:
    sys.stderr.write("mutation site not found exactly once (%d)\n" % s.count(old)); sys.exit(1)
open(path, "w").write(s.replace(old, new))
PYEOF
  printf '%s\n' "$d/verify-landing-chain.sh"
}
verify_with() { # verify_with <script> <root> → prints the report, sets the exit code
  AOUT="$(bash "$1" --from-snapshot "$2" --repo "$REPO_FIXTURE" 2>&1)"
}

# M1 — group by JOB NAME alone (drop the workflow). Case 8 must stop seeing the red.
MS="$(mutant name-only 'g = w "/" name' 'g = name')" \
  || bad "M1 mutation could not be applied"
[ -n "$MS" ] || MS=/nonexistent-mutant
R="$(mk mut-name-only 430)"
run "$R" 430 9001 "Workflow A" 1; run "$R" 430 9002 "Workflow B" 1
group "$R" 430 20 9002 "packaging-smoke" completed failure "2026-11-12T04:00:00Z"
group "$R" 430 30 9001 "packaging-smoke" completed success "2026-11-12T04:10:00Z"
verify_with "$MS" "$R"
if printf '%s' "$AOUT" | grep -qF "Workflow B/packaging-smoke:failure"; then
  bad "M1: the name-only mutant STILL saw the red — case 8 is not discriminating"
else
  ok "M1: grouping by the job name alone loses the red — case 8 is discriminating"
fi

# M2 — read the newest attempt OVERALL instead of the newest that had finished by mergedAt.
MS="$(mutant newest-overall '&& done_at <= merged) {' ') {')" \
  || bad "M2 mutation could not be applied"
[ -n "$MS" ] || MS=/nonexistent-mutant
R="$(mk mut-newest-overall 431)"
run "$R" 431 9001 "CI" 1
group "$R" 431 10 9001 "pipeline-compliance" completed failure "2026-11-12T04:41:17Z"
group "$R" 431 20 9001 "pipeline-compliance" completed success "2026-11-12T05:24:50Z"
verify_with "$MS" "$R"
if printf '%s' "$AOUT" | grep -qF "completed AFTER mergedAt"; then
  bad "M2: the newest-overall mutant STILL caught the late green — case 6 is not discriminating"
else
  ok "M2: reading the newest attempt overall launders the red — case 6 is discriminating"
fi

# M3 — bind on TREE EQUALITY instead of the PR's final commit (the #3996 FALSE FAIL).
MS="$(mutant tree-equality 'if [ "$last_commit" = "$rsha" ]; then' 'if [ "$(tree_of "$dir/commit-${rsha}.tsv")" = "$landed_tree" ]; then')" \
  || bad "M3 mutation could not be applied"
[ -n "$MS" ] || MS=/nonexistent-mutant
R="$(mk mut-tree-equality 432)"
run "$R" 432 9001 "CI" 1; group "$R" 432 10 9001 "unit-test" completed success "$MERGED_AT"
printf 'admin-merge: ok\n' > "$R/pr-432/rail.out"
verify_with "$MS" "$R"
if printf '%s' "$AOUT" | grep -qF "IS the PR's final commit"; then
  bad "M3: the tree-equality mutant still PASSED — case 3 is not discriminating"
else
  ok "M3: tree equality fails a correct landing (the #3996 defect) — case 3 is discriminating"
fi

# M4 — collapse "started but had not voted by the merge" back into an innocent bucket (the F1 defect).
MS="$(mutant f1-collapse 'else if (g in started)     v = "waited"' 'else if (g in started)     v = "later"')" \
  || bad "M4 mutation could not be applied"
[ -n "$MS" ] || MS=/nonexistent-mutant
verify_with "$MS" "$R"
if printf '%s' "$AOUT" | grep -qF "did not wait for"; then
  bad "M4: the collapsed mutant STILL reported the non-waiting check — case F1 is not discriminating"
else
  ok "M4: treating an in-flight group as 'not part of the gate' green-lights the landing — F1 is discriminating"
fi

# M5 — keep the truncated artifact when the read fails (the F2 defect): an unread surface becomes a
# measured zero, i.e. a FAIL against a landing nobody could read.
MS="$(mutant f2-not-atomic '  : > "$dir/$name.unread"' '  : > "$dir/${name%%.*}.unread"')" \
  || bad "M5 mutation could not be applied"
[ -n "$MS" ] || MS=/nonexistent-mutant
R2="$(mk f2-unread-mut 447)"
run "$R2" 447 9001 "CI" 1
: > "$R2/pr-447/checkruns-$HEAD.tsv"
: > "$R2/pr-447/checkruns-$HEAD.tsv.unread"
verify_with "$MS" "$R2"
if printf '%s' "$AOUT" | grep -qF "was NOT READ"; then
  bad "M5: the non-atomic mutant STILL honoured the sentinel — case F2a is not discriminating"
else
  ok "M5: a read sentinel written to the wrong name degrades to 'measured zero' — F2a is discriminating"
fi

# M6 — admit a marker that names ANOTHER repo (the F3 defect): PR numbers collide across repos.
MS="$(mutant f3-no-repo-filter 'if (tolower(repo) != fold) { printf "SKIP\t%s\t%s\t%s\n",     chan, substr(s, 1, 12), repo; next }' 'if (0) { printf "SKIP\t%s\t%s\t%s\n",     chan, substr(s, 1, 12), repo; next }')" \
  || bad "M6 mutation could not be applied"
[ -n "$MS" ] || MS=/nonexistent-mutant
R3="$(mk f3-foreign-mut 448)"
: > "$R3/pr-448/body.txt"
printf '<<<COMMENT>>>\nreview recorded: reviews/448.json verdict=clean @ %s (someone-else/other-repo)\n' "$HEAD" > "$R3/pr-448/comments.txt"
run "$R3" 448 9001 "CI" 1; group "$R3" 448 10 9001 "unit-test" completed success "$MERGED_AT"
verify_with "$MS" "$R3"
if printf '%s' "$AOUT" | grep -qF "refused as naming another repo"; then
  bad "M6: the unfiltered mutant STILL refused the foreign marker — case F3 is not discriminating"
else
  ok "M6: without the repo filter a foreign marker reads as this PR's review — F3 is discriminating"
fi

# ── summary ──────────────────────────────────────────────────────────────────────────────────────
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
