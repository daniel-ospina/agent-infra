#!/bin/bash
# tests/required-check-reservation/run.sh — #2752 negative test for the required-check reservation.
#
# THE DEFECT (why this exists)
#   `pipeline-compliance` is this repo's ONLY required status context (branch protection =
#   ["pipeline-compliance"]) and ~9 s of work. Measured 2026-10-24 21:43:45Z, one run waited
#   13 min for 9 s behind 66 queued runs (~1,650 advisory jobs). The repair reserves runner slots
#   behind the custom label `required-check` and routes ONLY that job at them.
#
# WHAT THIS SUITE PINS (the assertions live in check.mjs; this file drives them and, critically,
# proves the load-bearing ones are LIVE by mutating the artifact — not literally every internal
# branch, which is why the arms are enumerated rather than summarised):
#   0. LIVE — the real tree passes.
#   1. MUTANT: the reservation value stops naming `required-check`        → must FAIL (T1).
#   2. MUTANT: ONE MORE JOB is moved onto the reservation                 → must FAIL (T2).
#   3. MUTANT: the `ubuntu-latest` FALLBACK arm is deleted                → must FAIL (T3).
#   4. MUTANT: `timeout-minutes` is deleted                               → must FAIL (T4).
#   5. MUTANT: the documented runner-labels call is broken                → must FAIL (T5).
#   5b. MUTANT: only the `DELETE …/labels/ubuntu-latest` removal is broken → must FAIL (T5).
#   5c. MUTANT: the `runs-on` expression stops consuming the variable      → must FAIL (T1).
#   6. MUTANT: the doc's reservation value disagrees with the workflow    → must FAIL (T5).
#   7. MUTANT: a second job hidden in a BLOCK-SEQUENCE `runs-on:`         → must FAIL (T2).
#      A multi-line `runs-on:` parses to null in a naive reader, and a null routing looks exactly
#      like a reusable-workflow (`uses:`) job unless it is handled — so this arm exists because its
#      absence was how a second reservation could hide from T2 (found in review, reproduced).
#   8. MUTANT: a COMMENT-INTERRUPTED block sequence of `runs-on:`       → must FAIL (T2).
#      Blank/comment lines are valid INSIDE a YAML block sequence; a reader that ends the
#      sequence there sees only `ubuntu-latest` while YAML puts the job on the reservation.
#      This is the regression found in review round 2 (a false PASS).
#   9. UNREADABLE workflow                                                → rc 2, never a pass.
#   9. MUTANT: a multi-line FLOW sequence on the reservation        → must FAIL (T2).
#   9b. CONTROL: a multi-line FLOW sequence of an unchanged routing  → must stay GREEN (0).
#   9c. CONTROL: a job id with a trailing comment                    → must stay GREEN (0).
#  10. CONTROL: a quoted/annotated spelling of an UNCHANGED routing       → must stay GREEN (0).
#  10b. CONTROL: a one-line flow sequence WITH a trailing comment          → must stay GREEN (0).
#  11. MUTANT: a one-line FLOW sequence on the reservation                → must FAIL (T2).
#
# ON T2's STRICTNESS (deliberate): T2 pins EVERY other job in the tree to exactly `ubuntu-latest`,
# not merely "must not join the reservation". That is intentional — the reservation's value is that
# the advisory pool shrinks by exactly the reserved slots, so a PR that re-routes an advisory job
# changes that arithmetic while looking unrelated. A future PR that legitimately needs a different
# runner updates this suite in the same PR: the change is then visible in review, not silent.
#
# NOTES ON STYLE (same lessons as tests/ci-lane-parity/run.sh):
#   * "does this output contain X" is `grep -q 'X' <<<"$OUT"`, never `printf … | grep -q` — under
#     `set -o pipefail` a `grep -q` that exits at its first match SIGPIPEs the writer and turns a
#     PRESENT payload into a FALSE FAILURE (#841).
#   * mutations are applied by `node -e` with an exact, verified string replacement — not `sed`.
#     A mutation that does not apply must be an ERROR, never a quietly-passing "mutant caught".
#
# Hermetic: no network, no git, stdlib node only.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CHECK="$HERE/check.mjs"
WF="$ROOT/.github/workflows/pipeline-compliance.yml"
DOC="$ROOT/docs/ops/fleet-capacity.md"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
passes=0

pass() { passes=$((passes + 1)); echo "  ✅ $1"; }
fail() { fails=$((fails + 1)); echo "  ❌ $1"; }

# run_expect <expected-rc> <label> <workflow> <doc>
run_expect() {
  local want="$1" label="$2" wf="$3" doc="$4" rc out
  out="$(RC_WORKFLOW_FILE="$wf" RC_DOC_FILE="$doc" node "$CHECK" 2>&1)"
  rc=$?
  if [ "$rc" -eq "$want" ]; then
    pass "$label (rc=$rc)"
  else
    fail "$label — expected rc=$want, got rc=$rc"
    sed 's/^/       /' <<<"$out"
  fi
  LAST_OUT="$out"
}

# run_expect_nonzero <label> <workflow> <doc> — the invariant is "never green"; the exact non-zero
# code depends on which modelled check fires first, and pinning one would make the arm brittle
# without adding safety.
run_expect_nonzero() {
  local label="$1" wf="$2" doc="$3" rc
  RC_WORKFLOW_FILE="$wf" RC_DOC_FILE="$doc" node "$CHECK" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    pass "$label (rc=$rc, non-zero)"
  else
    fail "$label — expected a NON-ZERO rc (an unmodelled shape must never be green), got rc=0"
  fi
}

# mutate <src> <dst> <find> <repl> — exact, verified replacement. rc 3 = the finding text was
# absent, which means the mutation never happened and the arm would otherwise prove nothing.
mutate() {
  node -e '
    const fs = require("fs");
    const [src, dst, find, repl] = process.argv.slice(1);
    const t = fs.readFileSync(src, "utf8");
    if (!t.includes(find)) { console.error("MUTATION-NOT-APPLIED: " + JSON.stringify(find)); process.exit(3); }
    fs.writeFileSync(dst, t.split(find).join(repl));
  ' "$1" "$2" "$3" "$4"
}

reservation='["self-hosted","Linux","X64","required-check"]'

# append <src> <dst> <text> — copy then append. Used by the arms that add a whole unrecognised
# shape (a second `jobs:` mapping, a stray top-level blob) rather than re-spelling an existing one.
append() {
  node -e '
    const fs = require("fs");
    const [src, dst, text] = process.argv.slice(1);
    fs.writeFileSync(dst, fs.readFileSync(src, "utf8") + text);
  ' "$1" "$2" "$3"
}
fallback="'[\"ubuntu-latest\"]'"

echo "== required-check reservation (#2752) =="

# ── 0. LIVE ────────────────────────────────────────────────────────────────────────────────────
run_expect 0 "0 LIVE — the real tree pins the reservation" "$WF" "$DOC"

# ── 1. the reservation value stops naming required-check ──────────────────────────────────────
if mutate "$WF" "$TMP/wf-no-label.yml" "$reservation" '["self-hosted","Linux","X64"]'; then
  run_expect 1 "1 MUTANT reservation without 'required-check' is REFUSED" "$TMP/wf-no-label.yml" "$DOC"
else
  fail "1 MUTATION-NOT-APPLIED (the reservation literal was not found in the workflow)"
fi

# ── 2. ONE MORE JOB moved onto the reservation ────────────────────────────────────────────────
# `workflow-drift` is the only other job in this file, and it must stay on ubuntu-latest.
if mutate "$WF" "$TMP/wf-extra-job.yml" "    runs-on: ubuntu-latest" "    runs-on: \${{ fromJSON(vars.PIPELINE_COMPLIANCE_RUNS_ON || '[\"ubuntu-latest\"]') }}"; then
  run_expect 1 "2 MUTANT a second job on the reservation is REFUSED" "$TMP/wf-extra-job.yml" "$DOC"
else
  fail "2 MUTATION-NOT-APPLIED (no plain 'runs-on: ubuntu-latest' left to move — did the file change shape?)"
fi

# ── 3. the fallback arm deleted ───────────────────────────────────────────────────────────────
if mutate "$WF" "$TMP/wf-no-fallback.yml" " || $fallback" ""; then
  run_expect 1 "3 MUTANT a reservation with no fallback is REFUSED" "$TMP/wf-no-fallback.yml" "$DOC"
else
  fail "3 MUTATION-NOT-APPLIED (the fallback arm was not found in the workflow)"
fi

# ── 4. timeout-minutes deleted ────────────────────────────────────────────────────────────────
if mutate "$WF" "$TMP/wf-no-timeout.yml" "    timeout-minutes: 20" ""; then
  run_expect 1 "4 MUTANT a reserved job with no timeout is REFUSED" "$TMP/wf-no-timeout.yml" "$DOC"
else
  fail "4 MUTATION-NOT-APPLIED (no '    timeout-minutes: 20' to delete)"
fi

# ── 5. the documented runner-labels call broken ─────────────────────────────────────────────
if mutate "$DOC" "$TMP/doc-bad-labels.md" "/actions/runners/ID/labels" "/actions/runners/ID/nope"; then
  run_expect 1 "5 MUTANT a broken documented label call is REFUSED" "$WF" "$TMP/doc-bad-labels.md"
else
  fail "5 MUTATION-NOT-APPLIED (no /actions/runners/<id>/labels path was found in the doc)"
fi

# 5b — ONLY the DELETE-based removal of `ubuntu-latest` is broken. Arm 5 breaks the POST and the
# DELETE together, so on its own it cannot show the DELETE requirement is live.
if mutate "$DOC" "$TMP/doc-bad-delete.md" "/labels/ubuntu-latest" "/labels/other"; then
  run_expect 1 "5b MUTANT a doc that stops documenting the ubuntu-latest removal is REFUSED" "$WF" "$TMP/doc-bad-delete.md"
else
  fail "5b MUTATION-NOT-APPLIED (no '/labels/ubuntu-latest' removal was found in the doc)"
fi

# 5c — the routing stops consuming the variable (i.e. someone hardcodes a label list).
if mutate "$WF" "$TMP/wf-novar.yml" 'vars.PIPELINE_COMPLIANCE_RUNS_ON || ' ""; then
  run_expect 1 "5c MUTANT a runs-on that ignores the release variable is REFUSED" "$TMP/wf-novar.yml" "$DOC"
else
  fail "5c MUTATION-NOT-APPLIED (the variable reference was not found in the runs-on expression)"
fi

# ── 6. doc and workflow disagree on the reservation value ─────────────────────────────────────
if mutate "$DOC" "$TMP/doc-no-label.md" "$reservation" '["self-hosted","Linux","X64"]'; then
  run_expect 1 "6 MUTANT a doc whose reservation disagrees is REFUSED" "$WF" "$TMP/doc-no-label.md"
else
  fail "6 MUTATION-NOT-APPLIED (the reservation literal was not found in the doc)"
fi

# ── 7. unreadable workflow → could-not-measure, never a pass ──────────────────────────────────
node -e '
  const fs = require("fs");
  const src = fs.readFileSync(process.argv[1], "utf8");
  const add = [
    "",
    "  sneaky-second-job:",
    "    runs-on:",
    "      - self-hosted",
    "      - Linux",
    "      - X64",
    "      - required-check",
    "    steps:",
    "      - run: echo hi",
    "",
  ].join("\n");
  fs.writeFileSync(process.argv[2], src + add);
' "$WF" "$TMP/wf-blockseq.yml"

# 7 — a second job whose `runs-on:` is a BLOCK SEQUENCE (not a single line).
run_expect 1 "7 MUTANT a block-sequence second reservation job is REFUSED" "$TMP/wf-blockseq.yml" "$DOC"

# 8 — a COMMENT-INTERRUPTED block sequence. Blank and comment-only lines are valid INSIDE a YAML
# block sequence; a reader that ends the sequence there sees only the prefix (`ubuntu-latest`) while
# YAML puts the job on the reservation. This arm is the regression from review round 2.
node -e '
  const fs = require("fs");
  const src = fs.readFileSync(process.argv[1], "utf8");
  const from = "    runs-on: ubuntu-latest\n";
  if (!src.includes(from)) { console.error("MUTATION-NOT-APPLIED"); process.exit(3); }
  const to = [
    "    runs-on:",
    "      - ubuntu-latest",
    "      # reserved",
    "      - required-check",
    "",
  ].join("\n");
  fs.writeFileSync(process.argv[2], src.replace(from, to));
' "$WF" "$TMP/wf-commentseq.yml"
run_expect 1 "8 MUTANT a comment-interrupted block sequence is REFUSED" "$TMP/wf-commentseq.yml" "$DOC"

# ── 10. CONTROLS: equivalent spellings must not red a clean job, and must not hide a reserved one ─
# The reader asserts the resolved VALUE, not the source spelling. Round 3 found it reddened a CLEAN
# job for a trailing comment, quotes, or a one-element flow sequence; round 4 pins both directions.
# 9 — a FLOW sequence that WRAPS onto the next line. `runs-on: [a,` / `  b]` is valid YAML; reading
# only the first line reported just the labels before the break, so a second job on the reservation
# passed GREEN (review round 4, P1).
if mutate "$WF" "$TMP/wf-mlflow.yml" '    runs-on: ubuntu-latest' '    runs-on: [ubuntu-latest,
              required-check]'; then
  run_expect 1 "9 MUTANT a multi-line FLOW sequence on the reservation is REFUSED" "$TMP/wf-mlflow.yml" "$DOC"
else
  fail "9 MUTATION-NOT-APPLIED (no plain runs-on to convert)"
fi

if mutate "$WF" "$TMP/wf-mlflow-clean.yml" '    runs-on: ubuntu-latest' '    runs-on: [ubuntu-latest,
              ]'; then
  run_expect 0 "9b CONTROL a multi-line FLOW sequence of an unchanged routing stays GREEN" "$TMP/wf-mlflow-clean.yml" "$DOC"
else
  fail "9b MUTATION-NOT-APPLIED (no plain runs-on to convert)"
fi

# 9c — a JOB ID with a trailing comment. Not recognising it appended that job's lines to the
# previous job and overwrote its routing, reddening a clean tree and blaming the wrong job.
if mutate "$WF" "$TMP/wf-jobcomment.yml" '  workflow-drift:' '  workflow-drift: # drift guard'; then
  run_expect 0 "9c CONTROL a job id with a trailing comment stays GREEN" "$TMP/wf-jobcomment.yml" "$DOC"
else
  fail "9c MUTATION-NOT-APPLIED (no plain job id to annotate)"
fi

if mutate "$WF" "$TMP/wf-quoted.yml" '    runs-on: ubuntu-latest' '    runs-on: "ubuntu-latest"  # default hosted'; then
  run_expect 0 "10 CONTROL a quoted/annotated unchanged routing stays GREEN" "$TMP/wf-quoted.yml" "$DOC"
else
  fail "10 MUTATION-NOT-APPLIED (no plain runs-on to re-spell)"
fi

# 10b — the COMBINATION VGATE round 4 found: a one-line flow sequence WITH a trailing comment.
# The bracket is located before comment-stripping, so the comment cannot swallow the label list.
if mutate "$WF" "$TMP/wf-flowcomment.yml" '    runs-on: ubuntu-latest' '    runs-on: [ubuntu-latest]  # default hosted'; then
  run_expect 0 "10b CONTROL a flow sequence with a trailing comment stays GREEN" "$TMP/wf-flowcomment.yml" "$DOC"
else
  fail "10b MUTATION-NOT-APPLIED (no plain runs-on to convert)"
fi

if mutate "$WF" "$TMP/wf-flow.yml" '    runs-on: ubuntu-latest' '    runs-on: [ubuntu-latest, required-check]'; then
  run_expect 1 "11 MUTANT a one-line FLOW sequence on the reservation is REFUSED" "$TMP/wf-flow.yml" "$DOC"
else
  fail "11 MUTATION-NOT-APPLIED (no plain runs-on to convert to a flow sequence)"
fi

run_expect 2 "12 UNREADABLE workflow exits 2 (never a vacuous pass)" "$TMP/absent.yml" "$DOC"

# ── 13–15. Round 5: the closing bracket is located AFTER the trailing comment is stripped ──────
# FINDING 13 (P1, false PASS): a `]` inside a trailing comment terminated the label list, so the
# continuation line carrying the real second label was dropped and a job that YAML put ON the
# reservation graded GREEN. It truncated to exactly `ubuntu-latest`, so T2's changed-routing arm
# never fired either. The comment is now stripped BEFORE the bracket is sought.
if mutate "$WF" "$TMP/wf-bracketcomment.yml" '    runs-on: ubuntu-latest' '    runs-on: [ubuntu-latest   # ]
      , required-check]'; then
  run_expect 1 "13 MUTANT a ']' inside a comment cannot truncate a reservation (false-PASS arm)" "$TMP/wf-bracketcomment.yml" "$DOC"
else
  fail "13 MUTATION-NOT-APPLIED (no plain runs-on to re-spell)"
fi

# FINDING 14 (P2, false BLOCK): the mirror image on a CLEAN job — a comment that merely CONTAINS a
# bracket produced a bogus label (`[ubuntu-latest]`) and reddened an unchanged routing.
if mutate "$WF" "$TMP/wf-bracketclean.yml" '    runs-on: ubuntu-latest' '    runs-on: [ubuntu-latest]  # NOTE [hosted] default'; then
  run_expect 0 "14 CONTROL a comment containing ']' does not redden a clean routing" "$TMP/wf-bracketclean.yml" "$DOC"
else
  fail "14 MUTATION-NOT-APPLIED (no plain runs-on to re-spell)"
fi

# FINDING 15 (P2, green on unparseable YAML): once a job's runs-on resolved, any indented line the
# reader did not model was silently dropped — certifying a routing over a file `yaml.safe_load`
# REJECTS. Such a leftover now makes the job OPAQUE (exit 2), never green.
if mutate "$WF" "$TMP/wf-stray.yml" '    runs-on: ubuntu-latest' '    runs-on: [ubuntu-latest]
      , required-check]'; then
  run_expect 2 "15 UNREADABLE a stray continuation after a resolved runs-on is NOT green" "$TMP/wf-stray.yml" "$DOC"
else
  fail "15 MUTATION-NOT-APPLIED (no plain runs-on to re-spell)"
fi

# FINDING 16 — the same false-green class via the BLOCK form: a block-sequence `runs-on:` followed by
# a stray continuation line exited 0 while PyYAML REJECTS the file, because the line that ended the
# sequence was dropped when it was not a 4-space key.
if mutate "$WF" "$TMP/wf-blockstray.yml" '    runs-on: ubuntu-latest' '    runs-on:
      - ubuntu-latest
    , required-check]'; then
  run_expect 2 "16 UNREADABLE a stray line after a BLOCK sequence is NOT green" "$TMP/wf-blockstray.yml" "$DOC"
else
  fail "16 MUTATION-NOT-APPLIED (no plain runs-on to re-spell)"
fi

# FINDING 17 — the quoted/annotated variant of the same shape. This one is caught by a DIFFERENT
# arm (the bogus joined label is a routing violation, rc 1) rather than as unreadable (rc 2). Both
# are fail-closed, so the invariant asserted is "never green" rather than one exact code.
if mutate "$WF" "$TMP/wf-flowstray2.yml" '    runs-on: ubuntu-latest' '    runs-on: [ubuntu-latest # ]
      required-check]'; then
  run_expect_nonzero "17 a ']' in a comment followed by a stray line is NEVER green" "$TMP/wf-flowstray2.yml" "$DOC"
else
  fail "17 MUTATION-NOT-APPLIED (no plain runs-on to re-spell)"
fi

# ── 18–22. Round 6 ──────────────────────────────────────────────────────────────────────────────
# FINDING 18 (P1, false PASS): a job whose whole body is a one-line FLOW MAPPING is invisible to
# the job-start regex, so the job VANISHED from the sweep and T2 certified "no other job asks for
# the reservation" over a tree that had one. The remainder after the job key is now captured and
# makes the job OPAQUE — never green, never silently dropped.
if mutate "$WF" "$TMP/wf-flowmapping.yml" '  workflow-drift:' '  sneaky: {runs-on: [ubuntu-latest, required-check], steps: [{run: echo hi}]}
  workflow-drift:'; then
  run_expect 2 "18 UNREADABLE a flow-mapping job body is not silently skipped" "$TMP/wf-flowmapping.yml" "$DOC"
else
  fail "18 MUTATION-NOT-APPLIED (no sibling job key to prepend to)"
fi

# FINDING 19 (P1, false PASS, same root): a QUOTED job key at job indent matched nothing at all, so
# the job and its routing were dropped while grading "every other job".
if mutate "$WF" "$TMP/wf-quotedkey.yml" '  workflow-drift:' '  "sneaky":
    runs-on: [ubuntu-latest, required-check]
  workflow-drift:'; then
  run_expect 2 "19 UNREADABLE a quoted job key is not silently skipped" "$TMP/wf-quotedkey.yml" "$DOC"
else
  fail "19 MUTATION-NOT-APPLIED (no sibling job key to prepend to)"
fi

# FINDING 20 (P2, false BLOCK): an anchor on an UNCHANGED routing was graded as a routing CHANGE
# ("expected exactly 'ubuntu-latest', got [&hosted ubuntu-latest]") — a false block, and a message
# asserting a change that did not happen. Attachment syntax is stripped before grading.
if mutate "$WF" "$TMP/wf-anchor.yml" '    runs-on: ubuntu-latest' '    runs-on: &hosted ubuntu-latest'; then
  run_expect 0 "20 CONTROL a YAML anchor on an unchanged routing stays GREEN" "$TMP/wf-anchor.yml" "$DOC"
else
  fail "20 MUTATION-NOT-APPLIED (no plain runs-on to re-spell)"
fi

# ...and an ALIAS points at a definition this reader does not follow, so it refuses rather than
# guessing which side it names.
if mutate "$WF" "$TMP/wf-alias.yml" '    runs-on: ubuntu-latest' '    runs-on: *hosted'; then
  run_expect 2 "21 UNREADABLE an unresolvable alias routing is not graded" "$TMP/wf-alias.yml" "$DOC"
else
  fail "21 MUTATION-NOT-APPLIED (no plain runs-on to re-spell)"
fi

# FINDING 22 (P1, false PASS): T1 graded the joined text by SUBSTRING, so a literal `required-check`
# could be ANDed onto the required job with the variable expression and the suite stayed green —
# while GitHub ANDs the labels, making the documented `ubuntu-latest` default unsatisfiable.
if mutate "$WF" "$TMP/wf-anded.yml" "    runs-on: \${{ fromJSON(vars.PIPELINE_COMPLIANCE_RUNS_ON || '[\"ubuntu-latest\"]') }}" '    runs-on:
      - ${{ fromJSON(vars.PIPELINE_COMPLIANCE_RUNS_ON || '["ubuntu-latest"]') }}
      - required-check'; then
  run_expect 1 "22 MUTANT a literal label ANDed onto the required routing is REFUSED" "$TMP/wf-anded.yml" "$DOC"
else
  fail "22 MUTATION-NOT-APPLIED (the variable expression was not found in the workflow)"
fi

# ── 23–26. VGATE round 6 ───────────────────────────────────────────────────────────────────────
# FINDING 23 (P1, GREEN over a reservation): the reusable-workflow exemption tested `uses:` ALONE,
# so a job carrying BOTH `uses:` and a `runs-on` spelled in a form this reader does not parse
# (`"runs-on":`) was skipped as exempt — while YAML put it on the reservation. The exemption now
# requires the job block to contain no `runs-on` key in ANY spelling.
if mutate "$WF" "$TMP/wf-usesquoted.yml" '  workflow-drift:' '  sneaky:
    uses: actions/checkout@v4
    "runs-on": [ubuntu-latest, required-check]
  workflow-drift:'; then
  run_expect 2 "23 UNREADABLE a 'uses:' job with an unparsed 'runs-on' is NOT exempt" "$TMP/wf-usesquoted.yml" "$DOC"
else
  fail "23 MUTATION-NOT-APPLIED (no sibling job key to prepend to)"
fi

# …and the genuine reusable-workflow job must still be exempt, or the fix would red every real tree.
if mutate "$WF" "$TMP/wf-usesonly.yml" '  workflow-drift:' '  sneaky:
    uses: actions/checkout@v4
  workflow-drift:'; then
  run_expect 0 "24 CONTROL a genuine reusable-workflow job stays EXEMPT" "$TMP/wf-usesonly.yml" "$DOC"
else
  fail "24 MUTATION-NOT-APPLIED (no sibling job key to prepend to)"
fi

# FINDING 25 (unreadable input graded GREEN): a TAB-indented job line is not matched by the
# space-only job-indent guard, so it was absorbed into the previous block and vanished.
if mutate "$WF" "$TMP/wf-tab.yml" '  workflow-drift:' '	sneaky:
		runs-on: [ubuntu-latest, required-check]
  workflow-drift:'; then
  run_expect 2 "25 UNREADABLE a tab-indented job is not silently absorbed" "$TMP/wf-tab.yml" "$DOC"
else
  fail "25 MUTATION-NOT-APPLIED (no sibling job key to prepend to)"
fi

# FINDING 26 (unreadable input graded GREEN): a `---` document separator inside `jobs:` starts a
# SECOND document; the reader graded the first and never saw the reservation in the second.
if mutate "$WF" "$TMP/wf-docsep.yml" 'jobs:' 'jobs:
---
  sneaky:
    runs-on: [ubuntu-latest, required-check]'; then
  run_expect 2 "26 UNREADABLE a second document inside 'jobs:' is not graded" "$TMP/wf-docsep.yml" "$DOC"
else
  fail "26 MUTATION-NOT-APPLIED (the 'jobs:' anchor was not found)"
fi

# ── 27–31. VGATE round 6, second pass ──────────────────────────────────────────────────────────
# The exemption was a DENY-list ("does this block contain a runs-on key?") and four spellings
# walked past it while YAML put the job on the reservation: an explicit `? runs-on` key, a `<<:`
# merge, an anchored key, and a tagged key. It is now an ALLOW-list over job-level keys, which
# cannot be spelled around — an unknown line REFUSES the input rather than exempting the job.
if mutate "$WF" "$TMP/wf-explicitkey.yml" '  workflow-drift:' '  sneaky:
    uses: actions/checkout@v4
    ? runs-on
    : [ubuntu-latest, required-check]
  workflow-drift:'; then
  run_expect 2 "27 UNREADABLE a '? runs-on' explicit key is not exempted" "$TMP/wf-explicitkey.yml" "$DOC"
else
  fail "27 MUTATION-NOT-APPLIED (no sibling job key to prepend to)"
fi

if mutate "$WF" "$TMP/wf-mergekey.yml" '  workflow-drift:' '  sneaky:
    uses: actions/checkout@v4
    <<: &r {runs-on: [ubuntu-latest, required-check]}
  workflow-drift:'; then
  run_expect 2 "28 UNREADABLE a '<<:' merge key is not exempted" "$TMP/wf-mergekey.yml" "$DOC"
else
  fail "28 MUTATION-NOT-APPLIED (no sibling job key to prepend to)"
fi

if mutate "$WF" "$TMP/wf-anchorkey.yml" '  workflow-drift:' '  sneaky:
    uses: actions/checkout@v4
    &k runs-on: [ubuntu-latest, required-check]
  workflow-drift:'; then
  run_expect 2 "29 UNREADABLE an anchored key is not exempted" "$TMP/wf-anchorkey.yml" "$DOC"
else
  fail "29 MUTATION-NOT-APPLIED (no sibling job key to prepend to)"
fi

if mutate "$WF" "$TMP/wf-taggedkey.yml" '  workflow-drift:' '  sneaky:
    uses: actions/checkout@v4
    !!str runs-on: [ubuntu-latest, required-check]
  workflow-drift:'; then
  run_expect 2 "30 UNREADABLE a tagged key is not exempted" "$TMP/wf-taggedkey.yml" "$DOC"
else
  fail "30 MUTATION-NOT-APPLIED (no sibling job key to prepend to)"
fi

# …and a real reusable job stays exempt, including the keys real workflows use. Without this the
# allow-list could tighten into a blanket refusal that reds every tree carrying a `uses:` job.
if mutate "$WF" "$TMP/wf-reusable.yml" '  workflow-drift:' '  sneaky:
    uses: actions/checkout@v4
    permissions:
      contents: read
    with:
      node-version: "22"
    secrets: inherit
  workflow-drift:'; then
  run_expect 0 "31 CONTROL a reusable job with standard keys stays EXEMPT" "$TMP/wf-reusable.yml" "$DOC"
else
  fail "31 MUTATION-NOT-APPLIED (no sibling job key to prepend to)"
fi

# ── 32–37. VGATE round 6, third pass: TOTAL COVERAGE ────────────────────────────────────────────
# Every hole so far was the same shape of failure: a line the reader did not recognise was SKIPPED
# while it certified "no other job asks for the reservation". The reader now refuses a file it
# cannot follow instead of grading the part it happens to understand. These arms pin the family.
for spec in \
  'jobs: {sneaky: {runs-on: [ubuntu-latest, required-check]}}|32 UNREADABLE an inline flow jobs: mapping is REFUSED' \
  'jobs:  # second|33 UNREADABLE a commented second jobs: is REFUSED' \
  'jobs: &j|34 UNREADABLE an anchored jobs: value is REFUSED' \
  'jobs: !!map|35 UNREADABLE a tagged jobs: value is REFUSED' \
  '{jobs: {sneaky: {runs-on: [ubuntu-latest, required-check]}}}|36 UNREADABLE a whole-file flow document is REFUSED'; do
  text="${spec%%|*}"
  label="${spec#*|}"
  if append "$WF" "$TMP/wf-append.yml" "$text"$'\n'; then
    run_expect 2 "$label" "$TMP/wf-append.yml" "$DOC"
  else
    fail "$label — MUTATION-NOT-APPLIED"
  fi
done

# A stray INDENTED line inside a `uses:` job made the file invalid YAML but was swallowed as
# "nested content" — while the suite treats the analogous stripes elsewhere as unreadable. Nested
# content is now allowed only under a key whose value really is nested.
# ⛔ The fixture must NOT prepend a second `jobs:`: that refuses first (arm 32's mechanism) and this
# arm would then pass whatever `reusableJobExempt` does — the vacuous-arm defect review round 8
# found. Arm 55 below is the STANDING guard for that: it re-injects the regression into a copy of the
# checker and requires the mutant to grade THIS arm's fixture CLEAN (rc 0) — a re-vacuumized fixture
# makes the mutant exit 2 for the wrong reason instead, which arm 55 fails on.
if append "$WF" "$TMP/wf-usesstray.yml" $'  sneaky:\n    uses: actions/checkout@v4\n      runs-on: [ubuntu-latest, required-check]\n'; then
  run_expect 2 "37 UNREADABLE a stray nested line in a 'uses:' job is not swallowed" "$TMP/wf-usesstray.yml" "$DOC"
else
  fail "37 MUTATION-NOT-APPLIED"
fi

# …and a legitimate top-level key AFTER the jobs mapping must still be fine (the column-0 rule
# must not turn into a blanket refusal of everything that follows `jobs:`).
if append "$WF" "$TMP/wf-toplevel.yml" $'permissions: read-all\n'; then
  run_expect 0 "38 CONTROL a top-level key after 'jobs:' stays GREEN" "$TMP/wf-toplevel.yml" "$DOC"
else
  fail "38 MUTATION-NOT-APPLIED"
fi

# ── 39–42. Round 7: EQUALITY, not count, on the required routing ────────────────────────────────
# A count was not enough. One SCALAR carrying the expression plus a literal token is ONE label to
# GitHub, so `includes(VAR_NAME)` and `length === 1` both held and the suite stayed GREEN — while
# with the variable unset the default arm matches no runner, the required check queues to the 24 h
# self-hosted cancel, and a `cancelled` check is non-red in the merge rail. The repo's ONLY required
# context would read non-red with no verdict. Asserted now by exact match on the resolved label.
EXPR_FIND="    runs-on: \${{ fromJSON(vars.PIPELINE_COMPLIANCE_RUNS_ON || '[\"ubuntu-latest\"]') }}"
# The VALUE only — the block-sequence arm needs the item text, not the `runs-on:` prefix.
EXPR_VAL="${EXPR_FIND#    runs-on: }"

if mutate "$WF" "$TMP/wf-eqscalar.yml" "$EXPR_FIND" "$EXPR_FIND required-check"; then
  run_expect 1 "39 MUTANT the expression plus a literal token in ONE scalar is REFUSED" "$TMP/wf-eqscalar.yml" "$DOC"
else
  fail "39 MUTATION-NOT-APPLIED (the variable expression was not found)"
fi

if mutate "$WF" "$TMP/wf-eqcomma.yml" "$EXPR_FIND" "$EXPR_FIND, required-check"; then
  run_expect 1 "39b MUTANT the expression plus a comma-separated token is REFUSED" "$TMP/wf-eqcomma.yml" "$DOC"
else
  fail "39b MUTATION-NOT-APPLIED (the variable expression was not found)"
fi

if mutate "$WF" "$TMP/wf-eqblock.yml" "$EXPR_FIND" $'    runs-on:\n      - '"$EXPR_VAL"$' required-check'; then
  run_expect 1 "40 MUTANT a one-item block sequence carrying a token is REFUSED" "$TMP/wf-eqblock.yml" "$DOC"
else
  fail "40 MUTATION-NOT-APPLIED (the variable expression was not found)"
fi

# ── 41. Round 8: an INDENTED line under a top-level key whose value is already complete ───────
# Such a line cannot legally exist: the document does not parse. Skipping it certified a tree that
# yaml.safe_load REJECTS, with the reservation hidden inside the skipped job.
if append "$WF" "$TMP/wf-completekey.yml" $'permissions: read-all\n  sneaky:\n    runs-on: [ubuntu-latest, required-check]\n'; then
  run_expect 2 "41 UNREADABLE an indented line under a COMPLETE top-level key is REFUSED" "$TMP/wf-completekey.yml" "$DOC"
else
  fail "41 MUTATION-NOT-APPLIED"
fi

# …and a top-level key whose value is DEFERRED to its children must still accept them.
if append "$WF" "$TMP/wf-blockkey.yml" $'permissions:\n  contents: read\n'; then
  run_expect 0 "42 CONTROL a top-level key with a nested value stays GREEN" "$TMP/wf-blockkey.yml" "$DOC"
else
  fail "42 MUTATION-NOT-APPLIED"
fi

# ── 43–46. VGATE round 8: an UNTERMINATED construct must not defer "children are legal" ────────
# Exempting `&`, `!`, `[`, `{` without closure tracking meant an unterminated one accepted every
# following indented line forever — rc 0 over a file yaml.safe_load REJECTS.
# ⛔ There is NO exemption left. A block scalar (`|` / `>`) was briefly exempt on the theory that its
# children are literal TEXT and cannot hide a job — but the exemption was undecidable by first
# character (a malformed header `run-name: |#x` and an illegally dedented body both graded GREEN over
# YAML PyYAML rejects; arms 48/49). So a top-level INLINE value now refuses indented children of ANY
# kind, and a legitimate block scalar or multi-line flow is a deliberate over-block (arm 47).
# Do not "align the code with an older comment" here: re-adding that exemption re-opens arms 48/49.
for spec in \
  'permissions: [|43 UNREADABLE an unterminated flow sequence is REFUSED' \
  'permissions: {|44 UNREADABLE an unterminated flow mapping is REFUSED' \
  'permissions: \&|45 UNREADABLE a dangling anchor is REFUSED' \
  'run-name: !foo|46 UNREADABLE a dangling tag is REFUSED'; do
  head_text="${spec%%|*}"
  label="${spec#*|}"
  if append "$WF" "$TMP/wf-unterm.yml" "$head_text"$'\n  sneaky:\n    runs-on: [ubuntu-latest, required-check]\n'; then
    run_expect 2 "$label" "$TMP/wf-unterm.yml" "$DOC"
  else
    fail "$label — MUTATION-NOT-APPLIED"
  fi
done

# ── 47–49. The no-exemption rule: a top-level INLINE value refuses indented children ──────────
# Round 8 tried to exempt block scalars (their children are literal TEXT, so they cannot hide a job).
# The VGATE showed the exemption is undecidable by first character: a MALFORMED header
# (`run-name: |#x`) and an ILLEGALLY DEDENTED body are both accepted by a first-character check and
# both make yaml.safe_load REJECT the document — GREEN over an unparseable file. There is no small
# correct subset, so the rule is now total: an inline top-level value refuses indented children.
# ⚠️ This deliberately over-blocks a legitimate top-level block scalar / multi-line flow. No workflow
# in this repo uses one (arm 0 proves the 11 real files stay green), and the refusal NAMES the
# construct, so the cost of a future one is a fixable message, never a wrong verdict.
if append "$WF" "$TMP/wf-scalar.yml" $'run-name: |\n  a literal string, not structure\n'; then
  run_expect 2 "47 REFUSED a top-level block scalar is not graded (deliberate over-block)" "$TMP/wf-scalar.yml" "$DOC"
else
  fail "47 MUTATION-NOT-APPLIED"
fi

if append "$WF" "$TMP/wf-badheader.yml" $'run-name: |#x\n  sneaky:\n    runs-on: [ubuntu-latest, required-check]\n'; then
  run_expect 2 "48 UNREADABLE a malformed block-scalar header is not graded" "$TMP/wf-badheader.yml" "$DOC"
else
  fail "48 MUTATION-NOT-APPLIED"
fi

if append "$WF" "$TMP/wf-dedent.yml" $'run-name: |\n    a\n  sneaky:\n    runs-on: [ubuntu-latest, required-check]\n'; then
  run_expect 2 "49 UNREADABLE an illegally dedented block-scalar body is not graded" "$TMP/wf-dedent.yml" "$DOC"
else
  fail "49 MUTATION-NOT-APPLIED"
fi

# …while a top-level BLOCK MAPPING and a childless scalar stay green (the rule is about INLINE values
# owning children, not about top-level keys existing).
if append "$WF" "$TMP/wf-topscalar.yml" $'run-name: CI\n'; then
  run_expect 0 "50 CONTROL a childless top-level scalar stays GREEN" "$TMP/wf-topscalar.yml" "$DOC"
else
  fail "50 MUTATION-NOT-APPLIED"
fi

# ── 51–54. VGATE round 8 (second pass): a TAB, and `key :value` ────────────────────────────────
# A first-column-only tab guard let `runs-on:\tubuntu-latest` and a merely TRAILING tab through as
# GREEN over files yaml.safe_load REJECTS. A tab is not decidable in the general case without
# tracking quoted scalars and block-scalar bodies, so the whole character is refused (no workflow in
# this repo contains one — arm 0 proves it).
if mutate "$WF" "$TMP/wf-tabsep.yml" '    runs-on: ubuntu-latest' $'    runs-on:\tubuntu-latest'; then
  run_expect 2 "51 UNREADABLE a tab used as a separator is REFUSED" "$TMP/wf-tabsep.yml" "$DOC"
else
  fail "51 MUTATION-NOT-APPLIED"
fi

if mutate "$WF" "$TMP/wf-tabtrail.yml" '    runs-on: ubuntu-latest' $'    runs-on: ubuntu-latest\t'; then
  run_expect 2 "52 UNREADABLE a trailing tab is REFUSED" "$TMP/wf-tabtrail.yml" "$DOC"
else
  fail "52 MUTATION-NOT-APPLIED"
fi

# `key :value` — whitespace before the colon with a value that does NOT start at the next space — is
# not valid YAML, but it was modelled as a key with an inline value and graded GREEN.
if append "$WF" "$TMP/wf-spacecolon.yml" $'a :b\n'; then
  run_expect 2 "53 UNREADABLE 'key :value' (invalid YAML) is REFUSED" "$TMP/wf-spacecolon.yml" "$DOC"
else
  fail "53 MUTATION-NOT-APPLIED"
fi

if append "$WF" "$TMP/wf-spacecolonok.yml" $'a : b\n'; then
  run_expect 0 "54 CONTROL 'key : value' (valid YAML) stays GREEN" "$TMP/wf-spacecolonok.yml" "$DOC"
else
  fail "54 MUTATION-NOT-APPLIED"
fi

echo

# ── 55. SELF-TEST: arm 37 must actually DISCRIMINATE ───────────────────────────────────────────
# A mutation arm that cannot fail is worse than no arm: it asserts coverage it does not provide.
# Round 8 found arm 37 vacuous (its fixture prepended a second `jobs:`, so arm 32 refused first and
# arm 37 passed whatever `reusableJobExempt` did). This arm is the standing guard against that
# recurring: it re-injects the round-6 regression into a COPY of the checker and requires the MUTANT
# to grade arm 37's own fixture CLEAN (rc 0) — because that is what arm 37 exists to refuse. A fixture
# re-vacuumized by a second `jobs:` makes the mutant exit 2 for that reason, and this arm fails.
if node -e '
  const fs = require("fs");
  const [src, dst] = process.argv.slice(1);
  const s = fs.readFileSync(src, "utf8");
  const from = "if (nestable && /^ {5,}\\S/.test(line)) continue;";
  if (!s.includes(from)) process.exit(3);
  fs.writeFileSync(dst, s.replace(from, "if (/^ {5,}\\S/.test(line)) continue;"));
' "$CHECK" "$TMP/check-vacuous.mjs"; then
  # ⛔ RC_WORKFLOWS_DIR MUST be overridden: the mutant copy lives in $TMP, so check.mjs derives its
  # DEFAULT_ROOT as `/` and would exit 2 on an unreadable `/.github/workflows` — a non-zero rc that
  # this arm would read as success. That is exactly the no-op-gate defect this arm exists to prevent
  # (the first version of this arm passed unconditionally for that reason; review round 9).
  RC_WORKFLOW_FILE="$TMP/wf-usesstray.yml" RC_WORKFLOWS_DIR="$ROOT/.github/workflows" \
    RC_DOC_FILE="$DOC" node "$TMP/check-vacuous.mjs" >/dev/null 2>&1
  rc=$?
  # The assertion is EQUALITY, not "non-zero": the regression must make the mutant grade arm 37's
  # fixture CLEAN (rc 0). If the fixture were re-vacuumized (a second `jobs:` prepended), the mutant
  # would exit 2 for that reason instead, and this arm fails.
  if [ "$rc" -eq 0 ]; then
    pass "55 SELF-TEST arm 37 DISCRIMINATES — the regression makes its fixture grade clean (mutant rc=$rc; arm 37 measured the real checker)"
  else
    fail "55 SELF-TEST arm 37 is VACUOUS — the regression does NOT make its fixture grade clean (mutant rc=$rc, expected 0): the fixture no longer isolates reusableJobExempt (did a second 'jobs:' get prepended again?)"
  fi
else
  fail "55 SELF-TEST-NOT-APPLIED (the reusableJobExempt regression anchor was not found in $CHECK)"
fi

if [ "$fails" -ne 0 ]; then
  echo "❌ required-check reservation: $fails failed, $passes passed"
  exit 1
fi
echo "✅ required-check reservation: $passes passed, 0 failed"
