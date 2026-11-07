#!/usr/bin/env bash
# mutation-attribution.test.sh — the NON-VACUITY contract's corpus, and the five measured instances
# (agent-infra#3442).
#
# WHY THIS SUITE IS SEPARATE FROM brief-gate.test.sh. That file pins the CONTRACT (the schema, the
# refusal, the teaching message, the wiring). This one pins the DISCRIMINATING POWER: the five
# assertions that were reviewed clean and could never have failed (docs/ops/review-non-vacuity-baseline.md),
# the two copyable suite-class fixtures, and the reviewers' own artifacts that must now carry the
# block. Splitting them keeps each suite's failure attributable: a red here means "an artifact that
# should be refused was admitted", a red there means "the dispatch contract broke".
#
# §A  the WORKED EXAMPLES — one per suite class the issue measured (#3368 bash prefix match, #3355
#     python missing leg). Each carries the attribution table a real suite must produce, and each is
#     ADMITTED by the parser, so the shape is copyable rather than described.
# §B  the BASELINE — the five pre-fix artifacts. Each is REFUSED. This is the "would this PR have been
#     caught?" check: the artifact those PRs produced had no attribution, so the clean verdict could
#     not have been minted.
# §C  the CARRIERS a reviewer actually writes — a `## MUTATION ATTRIBUTION` section inside a longer
#     review comment, in the @tsv-ESCAPED single-line form `record-review.sh` reads.
# §D  MUTATION — the mutant is derived FROM THE SHIPPED VALIDATOR, and each §B refusal must flip.
#
# Run: bash scripts/orchestrator-harness/mutation-attribution.test.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
GATE="$HERE/brief-gate.sh"
FIX="$HERE/fixtures/mutation-attribution"
PASS=0; FAIL=0
ck() { # ck <rc> <message>
  if [ "$1" -eq 0 ]; then printf '  ✅ %s\n' "$2"; PASS=$((PASS+1));
  else printf '  ❌ %s\n' "$2"; FAIL=$((FAIL+1)); fi
}
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
[ -s "$GATE" ] && bash -n "$GATE"; ck $? "the validator exists and parses"
[ -d "$FIX" ]; ck $? "the fixture directory exists (a suite that reads nothing must not report clean)"

echo
echo "§A the WORKED EXAMPLES — the shape a suite must produce, one per class"
# A FIXTURE THAT IS NOT READ IS NOT A FIXTURE (the #2258 review's finding, applied): each file is
# asserted present AND admitted, so deleting one reddens this suite instead of silently shrinking it.
for f in bash-suite.sh python-mutation-harness.py verdict-attribution.md README.md; do
  [ -s "$FIX/$f" ]; ck $? "fixture present: $f"
done
# The bash-suite example is a SHELL file, so it must be syntactically a shell program (a copyable shape
# that does not parse teaches a shape nobody can paste). Its non-vacuity block is what #3368 lacked.
bash -n "$FIX/bash-suite.sh"; ck $? "the bash-suite fixture parses (it is copyable, not prose)"
grep -q 'THE ROW THAT NAMES THE BEHAVIOUR' "$FIX/bash-suite.sh"; ck $? "…and it names the ATTRIBUTABLE row (the #3368 prefix-match defect, §rule 2)"
grep -q 'cmp -s "\$GATE_SRC" "\$mutant"' "$FIX/bash-suite.sh"; ck $? "…and it ASSERTS the mutation applied (a sed that stops matching must not pass silently)"
# The python example is read, not executed, so the assertions are on the shape it teaches: every
# Mutation names the TEST ids it must fail, which is the leg #3355 never had.
# ⛔ THE FIXTURE IS NAMED BY A BARE RELATIVE PATH, AFTER A `cd` (review cycle 4). `python3 - "$FIX/…"`
# is an interpreter operand the repo's `main-worktree-guard` (#709/#1228) classifies as a
# shell-expansion form, and it fails CLOSED on those — measured: it refused to invoke this whole
# suite from an agent session, so the suite could only be run by hand-stripping these lines first,
# which is how a suite stops being evidence. The fixture is READ by `ast`, never executed, so the
# refusal is a false block; but the path the guard asks for ("literal, so its contents can be read")
# is cheap to give, and a path with no `$` in it is honest by any reading. Nothing here discards a
# working tree.
( cd "$FIX" && python3 - python-mutation-harness.py <<'PY'
import ast, sys
src = open(sys.argv[1]).read()
tree = ast.parse(src)                      # a shape that does not parse teaches nothing
calls = [n for n in ast.walk(tree) if isinstance(n, ast.Call) and getattr(n.func, "id", "") == "Mutation"]
assert len(calls) >= 2, "the example must show more than one mutation"
for c in calls:
    kw = {k.arg for k in c.keywords}
    assert "expect_failing" in kw, "a Mutation without expect_failing cannot attribute a kill"
    assert "find" in kw and "replace" in kw, "a Mutation without find/replace is not an edit"
print("ok")
PY
)
[ "$?" -eq 0 ]; ck $? "the python-mutation-harness fixture parses and EVERY Mutation names its expect_failing legs (the #3355 missing-leg shape)"
# …and the reviewer-artifact example is a REAL artifact: it must satisfy the parser it documents.
bash "$GATE" --mutation-missing "$FIX/verdict-attribution.md" > "$TMP/fix-miss.txt" 2>&1; rc=$?
[ -z "$(cat "$TMP/fix-miss.txt")" ]; ck $? "the verdict-attribution fixture is ADMITTED by the shipped parser (the documented shape is the accepted shape) ($(cat "$TMP/fix-miss.txt"))"
# ⛔ AND ITS ADMISSION MUST COME FROM THE TABLE (review cycle 4, P2 — VACUOUS ARM). The document also
# carries a worked `NO NEW ASSERTIONS:` line, and while that line was LIVE the fixture was admitted
# with its ENTIRE table deleted — so this arm could not detect a corrupted table, which is the one
# thing it is for. The line is an indented code block now; this is the arm that says so.
grep -v '^|' "$FIX/verdict-attribution.md" > "$TMP/fix-notable.md"
grep -q '^    NO NEW ASSERTIONS: docs-only' "$TMP/fix-notable.md"; ck $? "…fixture: the table strip keeps the exemption EXAMPLE (otherwise this arm would pass for the wrong reason)"
bash "$GATE" --mutation-missing "$TMP/fix-notable.md" 2>/dev/null | grep -qx 'MUTATION-EXEMPTION-INDENTED'; ck $? "…and the SAME fixture with its table DELETED is REFUSED, NAMING the indented exemption — the documented example cannot exempt the document it documents, and the token says so"

echo
echo "§B the BASELINE — the five pre-fix artifacts, each REFUSED (#3442)"
# Each fixture is the artifact text the PR would have produced, from the issue's own table. None of
# them carries an attribution block, because the contract did not exist when they were written — so
# "would this PR have been caught?" is answerable: the clean verdict could not have been minted.
# ⛔ THE BASELINE IS DATA, NOT PROSE: the five rows live here as text so a deletion is a RED, and the
# issue's record of them lives in docs/ops/review-non-vacuity-baseline.md (asserted in §D).
_base() { printf '%s' "$1" > "$TMP/base.txt"; }
_base '#3355 — Code review

No issues found. Checked for bugs, guidance compliance, historical context.

The liveness leg is covered: `alive = str(entry) in alive` is asserted at runners.py:412.'
bash "$GATE" --mutation-missing "$TMP/base.txt" | grep -qx 'MUTATION-ATTRIBUTION'; ck $? "baseline 1 (#3355 liveness leg, no Mutation ever produced the case) is REFUSED"
_base '#3368 — Code review

No issues found. The new gate asserts the pre-fix spelling is absent:

    assert_absent "$OUT" "unbound variable"      # test.sh:4413'
bash "$GATE" --mutation-missing "$TMP/base.txt" | grep -qx 'MUTATION-ATTRIBUTION'; ck $? "baseline 2 (#3368 the fixture sets CELL_HOME, so the line was never expanded) is REFUSED"
_base '#3368 — Code review

No issues found. Deleting the record-based probe was checked by hand; G15a and G15b still pass.'
bash "$GATE" --mutation-missing "$TMP/base.txt" | grep -qx 'MUTATION-ATTRIBUTION'; ck $? "baseline 3 (#3368 prefix match: the whole probe deleted, both gates green) is REFUSED"
_base '#3374 — Code review

No issues found. The credential state is verified: LAYER VERIFIED appears in the install log.'
bash "$GATE" --mutation-missing "$TMP/base.txt" | grep -qx 'MUTATION-ATTRIBUTION'; ck $? "baseline 4 (#3374 the phrase is printed unconditionally) is REFUSED"
_base '#3355 (round 4) — Code review

No issues found. The ceiling is asserted: check(record["ceiling"] == 3).'
bash "$GATE" --mutation-missing "$TMP/base.txt" | grep -qx 'MUTATION-ATTRIBUTION'; ck $? "baseline 5 (#3355 round 4: ceiling is capped, so no mutation could redden it) is REFUSED"
# …and the CORRECTED form of the same five is ADMITTED, so the baseline cannot be "caught" by a parser
# that refuses everything — the failure mode #1884's review named.
printf '%s\n' '#3355 — Code review' '' 'No issues found.' '' '## MUTATION ATTRIBUTION' '' \
  '| assertion | mutant (reverts the fix) | reddened row | observed |' '|---|---|---|---|' \
  '| `runners.py:412` liveness leg | remove the `Mutation(name="stale")` entry | T57 | 1 failed, 41 passed |' > "$TMP/fixed.txt"
miss="$(bash "$GATE" --mutation-missing "$TMP/fixed.txt")"
[ -z "$miss" ]; ck $? "…and the CORRECTED form of that artifact is ADMITTED (the control: the parser is not refusing everything) (got '$miss')"

echo
echo "§C the CARRIERS a reviewer actually writes — @tsv-escaped, inside a longer comment"
# `record-review.sh` reads a GitHub comment body through `jq @tsv`, so newlines arrive as the two
# characters `\n` and the whole artifact is ONE awk record. This is the carrier, not a theoretical
# edge: without the un-escape the parser finds no heading and EVERY honest review is refused.
printf '%s' '#3344 — Code review\n\nNo issues found.\n\n## MUTATION ATTRIBUTION\n\n| assertion | mutant | reddened row | observed |\n|---|---|---|---|\n| `x.sh:9` gate | `sed s/rc=80/rc=0/` | §A (i) | rc=0 |\n' > "$TMP/carrier.txt"
[ "$(grep -c '' "$TMP/carrier.txt")" = "1" ]; ck $? "fixture: the escaped carrier is ONE line (so this arm really models the @tsv read)"
miss="$(bash "$GATE" --mutation-missing "$TMP/carrier.txt")"
[ -z "$miss" ]; ck $? "an attribution block inside an @tsv-escaped comment body is FOUND (got '$miss')"
printf '%s' '#3344 — Code review\n\nNo issues found. Checked the diff.\n' > "$TMP/carrier-bad.txt"
bash "$GATE" --mutation-missing "$TMP/carrier-bad.txt" | grep -qx 'MUTATION-ATTRIBUTION'; ck $? "…and the same carrier WITHOUT the block is refused (the un-escape is not a rubber stamp)"

echo
echo "§D MUTATION — the shipped validator, mutated, must flip each §B refusal"
# ⛔ MUTATE THE VALIDATOR, NOT THE TEST (the §C idiom of brief-gate.test.sh). The mutation deletes the
# section requirement, which IS the pre-#3442 behaviour: nothing asked a review artifact for
# attribution. If §B stayed green under it, §B would be asserting that a string exists.
MUT="$TMP/mutant-no-section.sh"
# ⛔ THE MUTANT MUST ADMIT, NOT MERELY REFUSE DIFFERENTLY: `{ print "x"; exit }` leaves the parser
# refusing (on the column arm) and the arm below would read that as `not flipped`. This one EXITS with
# no token, which is exactly what a parser that never asks about the section does.
sed 's/^  if (!sec) { print "MUTATION-ATTRIBUTION"; exit }$/  if (!sec) { exit }  # MUTANT: no section required/' "$GATE" > "$MUT"
cmp -s "$GATE" "$MUT"; rc=$?
[ "$rc" -ne 0 ]; ck $? "§D the mutation REALLY changed the file (the awk anchor still matches)"
bash -n "$MUT"; ck $? "§D the mutant still parses — it fails for the contract, not for a syntax error"
bash "$TMP/mutant-no-section.sh" --section reviewer >/dev/null 2>&1; ck $? "§D the mutant is ALIVE (it still renders the reviewer brief)"
_base '#3355 — Code review
No issues found. The liveness leg is asserted at runners.py:412.'
miss="$(bash "$TMP/mutant-no-section.sh" --mutation-missing "$TMP/base.txt")"
[ -z "$miss" ]; ck $? "§D ⛔ MUTATION: baseline 1 ('no attribution is REFUSED') now FAILS — the mutant admits it (got '$miss')"
printf '%s' '#3368 — Code review
No issues found. G15a and G15b still pass.'
miss="$(bash "$TMP/mutant-no-section.sh" --mutation-missing "$TMP/base.txt")"
[ -z "$miss" ]; ck $? "§D ⛔ MUTATION: baseline 3 (the #3368 prefix-match shape) now FAILS too (got '$miss')"
# …and the OTHER direction: a mutant that refuses EVERYTHING makes the §A/§C admissions fail, so the
# suite cannot be satisfied by a parser that is merely strict.
MUT2="$TMP/mutant-always.sh"
sed 's/^  if (!sec) { print "MUTATION-ATTRIBUTION"; exit }$/  print "MUTATION-ATTRIBUTION"; exit  # MUTANT: always refuse/' "$GATE" > "$MUT2"
cmp -s "$GATE" "$MUT2"; rc=$?
[ "$rc" -ne 0 ]; ck $? "§D the always-refuse mutation REALLY changed the file"
miss="$(bash "$TMP/mutant-always.sh" --mutation-missing "$TMP/fixed.txt")"
[ "$miss" = "MUTATION-ATTRIBUTION" ]; ck $? "§D ⛔ MUTATION (other direction): 'a corrected artifact is ADMITTED' FAILS when the parser refuses everything (got '$miss')"

echo
echo "§E the RECORD of the five — the baseline doc and the two carriers that must TELL a reviewer"
BASELINE="$ROOT/docs/ops/review-non-vacuity-baseline.md"
[ -s "$BASELINE" ]; ck $? "docs/ops/review-non-vacuity-baseline.md exists (the issue's acceptance item 4)"
for tok in 3355 3368 3374 'no mutation leg' 'prefix'; do
  grep -qi -- "$tok" "$BASELINE"; ck $? "…and it records '$tok'"
done
# THE TWO GENERATED CARRIERS, asserted by EFFECT not by a source grep: the reviewer brief this repo
# hands a reviewer, and the clean-verdict template the code-review skill tells a reviewer to post. A
# rule that is enforced but never DISCLOSED is the #2148 defect (a lane learns it by being blocked).
bash "$GATE" --section reviewer | grep -q '^## MUTATION ATTRIBUTION'; ck $? "the reviewer BRIEF the harness splices carries the block (brief-gate --section reviewer)"
grep -q 'MUTATION ATTRIBUTION' "$ROOT/skills/code-review/SKILL.md"; ck $? "the code-review skill's clean-verdict template carries the block (so a skill-driven reviewer emits it)"
grep -q 'MUTATION ATTRIBUTION' "$ROOT/scripts/orchestrator-harness/merge-one.sh"; ck $? "merge-one.sh's generated reviewer prompt names it"
grep -q -- '--mutation-missing' "$ROOT/scripts/record-review.sh"; ck $? "record-review.sh calls the ONE parser (no second definition of the predicate)"

echo
echo "================ RESULT: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
