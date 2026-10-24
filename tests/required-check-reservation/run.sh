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
# proves each assertion is LIVE by mutating the artifact):
#   0. LIVE — the real tree passes.
#   1. MUTANT: the reservation value stops naming `required-check`        → must FAIL (T1).
#   2. MUTANT: ONE MORE JOB is moved onto the reservation                 → must FAIL (T2).
#   3. MUTANT: the `ubuntu-latest` FALLBACK arm is deleted                → must FAIL (T3).
#   4. MUTANT: `timeout-minutes` is deleted                               → must FAIL (T4).
#   5. MUTANT: the documented PUT /labels call is broken                  → must FAIL (T5).
#   6. MUTANT: the doc's reservation value disagrees with the workflow    → must FAIL (T5).
#   7. UNREADABLE workflow                                                → rc 2, never a pass.
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

# ── 5. the documented PUT /labels call broken ─────────────────────────────────────────────────
if mutate "$DOC" "$TMP/doc-bad-put.md" "/actions/runners/ID/labels" "/actions/runners/ID/nope"; then
  run_expect 1 "5 MUTANT a broken PUT /labels call is REFUSED" "$WF" "$TMP/doc-bad-put.md"
else
  fail "5 MUTATION-NOT-APPLIED (the documented PUT /labels path was not found)"
fi

# ── 6. doc and workflow disagree on the reservation value ─────────────────────────────────────
if mutate "$DOC" "$TMP/doc-no-label.md" "$reservation" '["self-hosted","Linux","X64"]'; then
  run_expect 1 "6 MUTANT a doc whose reservation disagrees is REFUSED" "$WF" "$TMP/doc-no-label.md"
else
  fail "6 MUTATION-NOT-APPLIED (the reservation literal was not found in the doc)"
fi

# ── 7. unreadable workflow → could-not-measure, never a pass ──────────────────────────────────
run_expect 2 "7 UNREADABLE workflow exits 2 (never a vacuous pass)" "$TMP/absent.yml" "$DOC"

echo
if [ "$fails" -ne 0 ]; then
  echo "❌ required-check reservation: $fails failed, $passes passed"
  exit 1
fi
echo "✅ required-check reservation: $passes passed, 0 failed"
