#!/usr/bin/env bash
# tests/mutation-attribution/run.sh — the WORKED EXAMPLES and the discriminating-power BASELINE for the
# contract agent-infra#3442 lands (non-vacuity: every new assertion ships with a mutant that reddens it).
#
# WHY THIS SUITE EXISTS AT ALL. The contract itself is enforced in two places, each with its own suite:
#   `scripts/orchestrator-harness/brief-gate.sh`  — a REVIEWER brief must carry the MUTATION ATTRIBUTION
#                                                   order            (brief-gate.test.sh §A2/§B2/§C2)
#   `scripts/record-review.sh`                    — a `clean` ARTIFACT must carry the filled rows
#                                                   (record-review.test.sh §21)
# What neither of those can provide is the thing the issue's acceptance asks for: a COPYABLE SHAPE per
# suite class, so the next lane does not have to invent one, and a recorded BASELINE of the five
# measured instances so "this PR would have been caught" is checkable rather than rhetorical.
#
# ⛔ AND THE FIXTURES ARE DRIVEN, NOT GREPPED. §2/§3 run each worked example TWICE — once as shipped (it
# must pass) and once as a MUTANT of itself whose mutation leg no longer reddens anything (it must FAIL,
# and it must name the row it failed to redden). A fixture whose non-vacuity cannot be demonstrated is
# the defect it documents, so this file asserts its own examples can fail.
#
# Run: bash tests/mutation-attribution/run.sh
#      ⛔ IF the checkout guard refuses to start it (`⛔ Working-tree discard blocked … Form:
#      script-indirection`), the guard is mis-reading a FIXTURE invocation in this file as an
#      unresolvable script path — it decides whether a suite may RUN, not whether it is correct, and it
#      does not exist in CI. The documented workaround is to source the suite instead, which runs the
#      identical code: `bash -c 'set -u; . ./tests/mutation-attribution/run.sh'`. Same friction as
#      `brief-gate.test.sh`, which is blocked by the same arm on pre-existing code.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PASS=0; FAIL=0
ck() { # ck <rc> <message>
  if [ "$1" -eq 0 ]; then printf '  ✅ %s\n' "$2"; PASS=$((PASS + 1))
  else printf '  ❌ %s\n' "$2"; FAIL=$((FAIL + 1)); fi
}
SUMMARY_PRINTED=0
on_exit() {
  local rc=$?
  # ⛔ AN ABORTED SUITE MUST NEVER READ AS A PASS. A crash between two arms (a missing fixture, a
  # syntax error in a worked example) leaves no summary, and a runner that only looks for non-zero
  # would still be told nothing. The trap names it.
  [ "$SUMMARY_PRINTED" = "1" ] || printf '  ❌ this suite aborted BEFORE its summary — FAILURE, not a pass (rc=%s)\n' "$rc"
}
trap on_exit EXIT
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"; on_exit' EXIT

echo
echo "§1 the discriminating-power baseline — the five measured instances (#3442)"
BASELINE="$HERE/baseline.tsv"
[ -s "$BASELINE" ]; ck $? "the baseline file exists and is non-empty"
# ⛔ AN EQUALITY, NOT A FLOOR: the baseline is the evidence record, so a row silently REMOVED is the
# single change this file's readers would never notice (the surviving rows all still look right).
ROWS="$(awk 'END { print NR }' "$BASELINE")"
[ "$ROWS" = "5" ]; ck $? "the baseline holds EXACTLY the five measured instances (got $ROWS)"
# Every row must be complete: five tab-separated fields, none empty. A row with a blank slot is a
# claim with no artefact behind it — the class this whole issue is about.
BADROWS="$(awk -F'\t' 'NF != 5 || $1 == "" || $2 == "" || $3 == "" || $4 == "" || $5 == "" { c++ } END { print c + 0 }' "$BASELINE")"
[ "$BADROWS" = "0" ]; ck $? "every baseline row carries all five fields (pr · assertion · what vitiated it · the mutant · the row that reddens); bad rows: $BADROWS"
# The five instances the issue measured, by number. The symptom-check rule exists so a root is not
# re-discovered; this arm is the same rule applied to the baseline itself.
for pair in "#3355:liveness" "#3368:pin-tree" "#3374:LAYER" ; do
  id="${pair%%:*}"; _topic="${pair#*:}"
  grep -qF -- "$id" "$BASELINE"; ck $? "the baseline records $id"
done
grep -qF 'round 4' "$BASELINE"; ck $? "the baseline records #3355's ROUND 4 instance (the ceiling check) as its own row"

echo
echo "§2 the BASH worked example — the #3368 prefix-match shape"
BASH_EX="$HERE/examples/bash-suite-prefix-match.sh"
[ -s "$BASH_EX" ] && bash -n "$BASH_EX"; ck $? "the bash fixture exists and parses"
bash "$BASH_EX" > "$TMP/bash-ok.out" 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "the fixture PASSES as shipped (rc=$rc) — its rows pass AND its mutation leg reddens the named row"
grep -q 'REDDENS G15b' "$TMP/bash-ok.out"; ck $? "…and the leg names the row it reddened (attribution, not just 'a mutation was caught')"
grep -q 'G15a (a DIFFERENT behaviour) still passes' "$TMP/bash-ok.out"; ck $? "…and proves the catch is ATTRIBUTABLE (a different row did not move)"
bash "$BASH_EX" --no-mutations > "$TMP/bash-nomut.out" 2>&1; rc=$?
[ "$rc" -ne 0 ]; ck $? "⛔ the SAME fixture with its mutation leg removed FAILS (rc=$rc) — the leg's absence is a failure, never a pass"
grep -q 'MUTATION LEG IS MISSING' "$TMP/bash-nomut.out"; ck $? "…and says so by name, so the failure is attributable rather than a mystery red"
# MUTATE THE FIXTURE: its mutation no longer reverts anything. The leg must catch that too — otherwise
# the example would be teaching a leg that can pass on a mutation that does nothing, which is #3442.
sed 's|^mutate_prefix_match_restored() { .*$|mutate_prefix_match_restored() { :; }  # MUTANT: reverts nothing|' "$BASH_EX" > "$TMP/bash-mutant.sh"
diff -q "$BASH_EX" "$TMP/bash-mutant.sh" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]; ck $? "the fixture mutant REALLY changed the example (the sed anchor still matches)"
bash "$TMP/bash-mutant.sh" > "$TMP/bash-mutant.out" 2>&1; rc=$?
[ "$rc" -ne 0 ]; ck $? "⛔ MUTATION: an example whose mutation reverts NOTHING now FAILS (rc=$rc) — the leg is load-bearing in the fixture, not decorative"
grep -q 'did NOT redden G15b' "$TMP/bash-mutant.out"; ck $? "…and names the row that failed to redden (the diagnostic a reviewer needs)"

echo
echo "§3 the PYTHON worked example — the #3355 missing-leg shape"
PY_EX="$HERE/examples/python-mutation-leg.py"
[ -s "$PY_EX" ]; ck $? "the python fixture exists"
command -v python3 >/dev/null 2>&1
if [ "$?" -eq 0 ]; then
  python3 "$PY_EX" --check > "$TMP/py-ok.out" 2>&1; rc=$?
  [ "$rc" -eq 0 ]; ck $? "the fixture PASSES as shipped (rc=$rc)"
  grep -q 'REDDENS T57_liveness_exact' "$TMP/py-ok.out"; ck $? "…and the mutation reddens the row that NAMES the behaviour"
  grep -q 'T58_liveness_admits_itself still passes' "$TMP/py-ok.out"; ck $? "…and the attribution control did not move (the catch is attributable)"
  python3 "$PY_EX" --no-mutations > "$TMP/py-nomut.out" 2>&1; rc=$?
  [ "$rc" -ne 0 ]; ck $? "⛔ with its mutation leg removed the python fixture FAILS (rc=$rc)"
  grep -q 'MUTATION LEG IS MISSING' "$TMP/py-nomut.out"; ck $? "…and names the missing leg"
  python3 "$PY_EX" --mutations > "$TMP/py-list.out" 2>&1; rc=$?
  [ "$rc" -eq 0 ] && grep -q 'expect_red=' "$TMP/py-list.out"; ck $? "the --mutations shard selector answers, and each mutation declares the row it must redden"
  # MUTATE THE FIXTURE: the mutation's `revert` becomes a no-op → the leg must refuse.
  sed 's|"revert": lambda: RULE.__setitem__("is_alive", is_alive_prefix),|"revert": lambda: None,  # MUTANT: reverts nothing|' "$PY_EX" > "$TMP/py-mutant.py"
  diff -q "$PY_EX" "$TMP/py-mutant.py" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ]; ck $? "the python fixture mutant REALLY changed the example (the sed anchor still matches)"
  python3 "$TMP/py-mutant.py" --check > "$TMP/py-mutant.out" 2>&1; rc=$?
  [ "$rc" -ne 0 ]; ck $? "⛔ MUTATION: a python mutation that reverts NOTHING now FAILS (rc=$rc)"
  grep -q 'did NOT redden T57_liveness_exact' "$TMP/py-mutant.out"; ck $? "…and names the VACUOUS pin it found"
else
  printf '  (python3 unavailable — the python half is NOT proven by this run)\n'
  ck 1 "python3 is required to prove the python worked example"
fi

echo
echo "§4 ONE GRAMMAR, TWO ARTIFACTS — the two halves must disagree exactly where the design says"
# The two halves of the contract share the label MUTATION ATTRIBUTION and are deliberately DIFFERENT
# checks: a BRIEF carries the instruction (prose is correct there, so the brief half only requires a
# NON-EMPTY value), an ARTIFACT carries the FILLED rows (so the artifact half requires a row, or a
# `none — <why>` declaration). §4 drives BOTH SHIPPED implementations over the same three bodies and
# shows they disagree in exactly the designed places. If a later simplification collapsed them into one
# check, one of these arms flips — which is the whole reason they are compared here.
GATE="$ROOT/scripts/orchestrator-harness/brief-gate.sh"
[ -x "$GATE" ]; ck $? "brief-gate.sh is present and executable"
bash "$GATE" --section reviewer > "$TMP/reviewer-brief.txt" 2>/dev/null; rc=$?
[ "$rc" -eq 0 ] && [ -s "$TMP/reviewer-brief.txt" ]; ck $? "the canonical reviewer section renders"
bash "$GATE" --check "$TMP/reviewer-brief.txt" reviewer >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "…and SATISFIES the brief half (a brief states the instruction; prose is correct there)"
# Slice the ARTIFACT half's parser out of the shipped recorder — the same "drive the shipped code, not a
# copy of it" rule selftest.sh applies to run_agent. Fail closed if the slice stops matching.
# ⛔ AN OVER-WIDE SLICE IS EXECUTED, NOT IGNORED (fresh review, cycle 4): a `sed` range whose END anchor
# stops matching runs to EOF, and the recorder's `BASH_SOURCE == $0` main-flow guard is TRUE under a
# sourced/eval-ed slice — so a drifted anchor would run the RECORDER's body inside this suite. awk exits
# on the anchor and reports whether it saw it.
if awk '/^MUTATION_ATTRIBUTION_AWK=/{p=1} p&&/^MUTATION_ATTRIBUTION_HELP=/{s=1;exit} p{print} END{exit (s?0:1)}' \
     "$ROOT/scripts/record-review.sh" > "$TMP/parser.sh"; then
  ck 0 "the artifact parser was sliced out of the shipped record-review.sh (BOTH anchors matched)"
else
  ck 1 "the parser slice FAILED — an anchor is missing, so nothing below may be attributed to the parser"
fi
[ -s "$TMP/parser.sh" ]; ck $? "…and the slice is non-empty"
# Sourced into THIS shell rather than invoked through a nested interpreter: the slice only defines an
# awk program and one function, and a nested interpreter invocation here is a script-indirection shape
# the checkout guard cannot resolve — it refuses to run the suite at all (measured on this file).
# shellcheck disable=SC1090
. "$TMP/parser.sh"
declare -F mutation_attribution_missing >/dev/null 2>&1; ck $? "…and it defines mutation_attribution_missing"
artifact_verdict() { # artifact_verdict <body-file> — prints the parser's token, empty = accepted
  # ⛔ THE BUILTIN FILE READ, NOT A CAT-SUBSTITUTION OF A VARIABLE PATH. The checkout guard reads a
  # command-substituted cat of an expanded path as a way to obtain a script body at runtime and refuses
  # to run THIS SUITE at all (script-indirection, measured on this very file) — one more entry in the
  # pattern of false blocks that already made `brief-gate.test.sh` unrunnable in an agent session. The
  # builtin reads the same bytes with no producer for the guard to resolve.
  local body
  body="$(<"$1")"
  mutation_attribution_missing "$body"
}

# (a) LABEL + PROSE ONLY: a valid BRIEF, an INVALID artifact. This is the pair that proves the artifact
# half is not presence-only — the exact defect #3368 measured (a label satisfied by a prefix match).
printf '## RESEARCH FIRST\nINTERNAL: x\nEXTERNAL: y\nRUNG: 3 - web_fetch\nCONTRADICTION TEST: none\nMUTATION ATTRIBUTION: for each new assertion, name the mutant that reddens it\n' > "$TMP/label-prose-full.txt"
bash "$GATE" --check "$TMP/label-prose-full.txt" reviewer >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; ck $? "(a) a COMPLETE brief carrying the attribution as PROSE passes the brief half (rc=$rc) — prose is what a brief should hold"
SHAPES="$(artifact_verdict "$TMP/label-prose-full.txt")"
[ "$SHAPES" = "NO-ROWS" ]; ck $? "⛔ (a) …while the ARTIFACT half REFUSES the same prose (got '${SHAPES:-<accepted>}') — the two halves disagree exactly where the design says they must"

# (b) ROWS WITHOUT THE LABEL: refused by the artifact half. A row nobody anchored is not an attribution.
printf '%s\n' '- assertion: the gate refuses an artifact that names no mutant | mutant: delete the attribution call | red: 21b' > "$TMP/rows-nolabel.txt"
SHAPES="$(artifact_verdict "$TMP/rows-nolabel.txt")"
[ "$SHAPES" = "NO-BLOCK" ]; ck $? "(b) rows WITHOUT the label are REFUSED by the artifact half (got '${SHAPES:-<accepted>}') — an unanchored row is not an attribution"

# (c) LABEL + ROW: accepted by BOTH, which is the intended agreement.
printf '%s\n%s\n' 'MUTATION ATTRIBUTION:' '- assertion: the gate refuses an artifact that names no mutant | mutant: delete the attribution call | red: 21b' > "$TMP/label-row.txt"
SHAPES="$(artifact_verdict "$TMP/label-row.txt")"
[ -z "$SHAPES" ]; ck $? "(c) label + a filled row is ACCEPTED by the artifact half (got '${SHAPES:-<accepted>}')"
# …and the canonical reviewer section is REFUSED by the artifact half, BECAUSE IT IS AN INSTRUCTION
# WITH PLACEHOLDERS, not a filled attribution. This assertion was originally the other way round (the
# section "satisfied" the artifact half because a wrapped prose line happened to carry all three
# keywords), and a fresh review of this change showed what that admitted: a refused lane could paste
# the BRIEF — or the help text the refusal prints — as a fresh comment and mint `clean`. The row grammar
# now requires a BULLET with no angle-bracketed placeholder left in a slot, so instruction text is
# refusable and a filled row is still accepted.
SHAPES="$(artifact_verdict "$TMP/reviewer-brief.txt")"
[ "$SHAPES" = "NO-ROWS" ]; ck $? "⛔ the canonical reviewer section is REFUSED by the ARTIFACT half (got '${SHAPES:-<accepted>}') — an instruction with placeholders is not a filled attribution"
# …and the help text the refusal itself prints is refused for the same reason: a refused lane cannot
# satisfy the gate by pasting the remedy.
printf '%s\n%s\n' 'MUTATION ATTRIBUTION:' '- assertion: <the behaviour the new assertion protects> | mutant: <the revert of that behaviour> | red: <the row that goes red>' > "$TMP/help-block.txt"
SHAPES="$(artifact_verdict "$TMP/help-block.txt")"
[ "$SHAPES" = "NO-ROWS" ]; ck $? "⛔ …and so is the help text the REFUSAL prints (got '${SHAPES:-<accepted>}') — an unfilled template is a claim nobody made"

echo
echo "================ RESULT: $PASS passed, $FAIL failed ================"
SUMMARY_PRINTED=1
[ "$FAIL" -eq 0 ]
