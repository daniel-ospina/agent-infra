#!/bin/bash
# tests/ci-trigger-scope/run.sh — agent-infra#3196: the trigger SET of the two advisory guards,
# pinned so the reduction cannot silently decay.
#
# THE DEFECT THIS SUITE PINS. `pipeline-compliance` is this repo's ONLY required status context and
# takes ~9 s of work. On 2026-11-01 its median wall clock was 15.5 min (max 33.5) because it queues
# behind ~30 advisory runner allocations per single push. Two of those allocations were pure
# volume, not coverage:
#
#   * `workflow-lock.yml` declared `edited` in its `types:`. `scripts/record-review.sh` writes the
#     reviewer attestation INTO THE PR BODY, so EVERY recorded review was an `edited` activity and
#     bought a full run for a diff that had not changed (median 16.1 min wall clock).
#   * `harness-single-source.yml` had no `paths:` filter, so it ran on every PR (median 6.7 min)
#     for a read that depends on a handful of trees.
#
# WHAT IS PINNED, AND WHY EACH ARM CAN FAIL. Every assertion below is driven by a MUTATION of the
# live file, never by a presence check: a pin that cannot fail is not a pin.
#
#   1. LIVE — the real tree is as decided (both files, plus the required context untouched).
#   2. MUTANT: `edited` restored to workflow-lock's `types:`          → must FAIL.
#   3. MUTANT: `synchronize` dropped from it                          → must FAIL.
#   4. MUTANT: the `types:` key deleted (GitHub's default is the same three, so the VALUES still
#      match — the arm exists because an implicit default is not an artifact) → must FAIL.
#   5. MUTANT: `harness-single-source.yml`'s `paths:` block deleted   → must FAIL.
#   6. MUTANT: `paths:` reduced to `'**'` (a no-op that reads like a filter) → must FAIL.
#   7. MUTANT: `edited` dropped from `pipeline-compliance.yml`        → must FAIL. The asymmetry is
#      the whole design: the required context KEEPS `edited`, because its #513 verdict binding
#      re-reads the body marker written after the last push. "Finishing the job" there would let a
#      forged `verdict=clean-micro` marker ride a stale green check to merge.
#   8. ADMISSION — through `scripts/ci-workflow-pr-evaluable.sh`, the SAME predicate the merge rail
#      uses (one implementation of `paths:` matching, never a second): every path the doctor step
#      can read is admitted, and a docs-only diff is not.
#   9. DISCRIMINATION — the admission arms are proved live by narrowing the filter to `bin/harness`
#      alone: the `scripts/orchestrator-harness/lane.sh` arm must then flip to `no`.
#  10. NON-VACUITY — a missing file, and a file whose `pull_request_target:` trigger is gone, are
#      rc 2 / rc 1, never a green: a reader that cannot answer must not spell the answer "passed".
#
# ⛔ WHY ADMISSION GOES THROUGH THE RAIL'S PREDICATE AND NOT A GLOB HERE. A second matcher would be
# a second definition of "does this filter admit this path", and it would drift from the one the
# merge rail consults. `ci-workflow-pr-evaluable.sh --lane-applicable` answers exactly that
# question, fails closed (`unknown` on any shape it cannot attribute), and refuses to answer `no`
# from an absent changed-path list.
#
# HERMETIC: no network, no git, no docker, stdlib node + python3 (the predicate). Mutations are
# applied to copies in a temp dir by exact, verified string replacement — a mutation that does not
# apply is an ERROR, never a quietly-passing "mutant caught".
#
# Run: bash tests/ci-trigger-scope/run.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CHECK="$HERE/check.mjs"
PRED="$ROOT/scripts/ci-workflow-pr-evaluable.sh"
WL="$ROOT/.github/workflows/workflow-lock.yml"
HSS="$ROOT/.github/workflows/harness-single-source.yml"
PC="$ROOT/.github/workflows/pipeline-compliance.yml"

# ⛔ SKIP is a COUNTER, not a measurement this suite currently makes: every arm is mandatory, so no
# arm below can be skipped and the final line's SKIP is structurally 0. It exists so that a future arm
# has an honest place to record a host that genuinely cannot run it, rather than being silently
# dropped — a silent skip is the no-op-gate class this repo names. If you add a skip, say why.
PASS=0; FAIL=0; SKIP=0
pass() { PASS=$((PASS + 1)); printf '   ✅ %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '   ❌ %s\n' "$*"; }
skip() { SKIP=$((SKIP + 1)); printf '   ⏭️  %s\n' "$*"; }

if ! command -v node >/dev/null 2>&1; then
  fail "node is not on PATH — the trigger reader CANNOT run, so nothing here is verified (not a pass)"
  printf 'PASS %d · FAIL %d · SKIP %d\n' "$PASS" "$FAIL" "$SKIP"
  exit 1
fi
if [ ! -f "$PRED" ]; then
  fail "scripts/ci-workflow-pr-evaluable.sh is missing — the path-admission arms cannot run (not a pass)"
  printf 'PASS %d · FAIL %d · SKIP %d\n' "$PASS" "$FAIL" "$SKIP"
  exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ci-trigger-scope.XXXXXX")"
ERR="$(mktemp "${TMPDIR:-/tmp}/ci-trigger-scope-err.XXXXXX")"
cleanup() { rm -rf "$TMP"; rm -f "$ERR"; }
trap cleanup EXIT

# ── the ONE reader, driven twice: live, and against a mutant copy ─────────────────────────────
LAST_OUT=""
run_check() { # <want-rc> <label> [VAR=value ...]
  local want="$1" label="$2"
  shift 2
  local rc
  LAST_OUT="$(env "$@" node "$CHECK" 2>&1)"
  rc=$?
  if [ "$rc" -eq "$want" ]; then
    pass "$label (rc=$rc)"
  else
    fail "$label — expected rc=$want, got rc=$rc"
    printf '%s\n' "$LAST_OUT" | sed 's/^/       /'
  fi
}

# ── the mutations: exact, verified replacement. rc 3 = the anchor was absent, which means the
# mutation never happened and the arm would otherwise prove nothing ──────────────────────────────
mutate() { # <src> <dst> <find> <repl>
  node -e '
    const fs = require("fs");
    const [src, dst, find, repl] = process.argv.slice(1);
    const t = fs.readFileSync(src, "utf8");
    if (!t.includes(find)) { console.error("MUTATION-NOT-APPLIED: " + JSON.stringify(find)); process.exit(3); }
    fs.writeFileSync(dst, t.split(find).join(repl));
  ' "$1" "$2" "$3" "$4"
}
apply_mutation() { # <src> <dst> <find> <repl> <label>
  if mutate "$1" "$2" "$3" "$4"; then
    return 0
  fi
  fail "$5 — PRECONDITION FAILED: the mutation did not apply, so this arm proves nothing"
  return 1
}

# ── path admission through the rail's own predicate ────────────────────────────────────────────
ADMIT=""
admit() { # <workflow-file> <path> ; sets ADMIT to the token
  ADMIT="$(PR_CHANGED_PATHS="$2" CI_WF_PR_EVALUABLE_QUESTION=lane-applicable \
             bash "$PRED" "$1" 2>"$ERR")"
}
expect_admit() { # <want> <label> <workflow-file> <path>
  admit "$3" "$4"
  if [ "$ADMIT" = "$1" ]; then
    pass "$2"
  else
    fail "$2 — expected '$1' for '$4', got '${ADMIT:-<empty>}'"
    [ -s "$ERR" ] && sed 's/^/       /' "$ERR"
  fi
}

# ══════════════════════════════════════════════════════════════════════════════════════════════
echo "== 1. LIVE: the tree is as decided =="
run_check 0 "the live workflows still declare the decided triggers"
case "$LAST_OUT" in
  *"workflow-lock pull_request_target types: opened, synchronize, reopened"*)
    pass "workflow-lock declares exactly opened, synchronize, reopened" ;;
  *) fail "workflow-lock's types were not reported as decided" ;;
esac
case "$LAST_OUT" in
  *"scripts/orchestrator-harness/**"*)
    pass "harness-single-source's filter names the canonical harness tree" ;;
  *) fail "harness-single-source's paths list did not name scripts/orchestrator-harness/**" ;;
esac

echo "== 2. MUTANT: \`edited\` restored to workflow-lock's types: =="
WL_EDITED="$TMP/wl-edited.yml"
if apply_mutation "$WL" "$WL_EDITED" \
  "    types: [opened, synchronize, reopened]" \
  "    types: [opened, synchronize, reopened, edited]" \
  "the per-edit trigger must be restored"; then
  run_check 1 "a restored \`edited\` is REFUSED" WL_FILE="$WL_EDITED"
  case "$LAST_OUT" in
    *edited*) pass "the refusal NAMES \`edited\` and why it is the one being removed" ;;
    *) fail "the refusal did not name \`edited\`" ;;
  esac
fi

echo "== 3. MUTANT: \`synchronize\` dropped =="
WL_NOSYNC="$TMP/wl-nosync.yml"
if apply_mutation "$WL" "$WL_NOSYNC" \
  "    types: [opened, synchronize, reopened]" \
  "    types: [opened, reopened]" \
  "a head-moving event must be droppable"; then
  run_check 1 "a \`types:\` set that lost \`synchronize\` is REFUSED" WL_FILE="$WL_NOSYNC"
  case "$LAST_OUT" in
    *synchronize*) pass "the refusal NAMES the lost event" ;;
    *) fail "the refusal did not name the lost event" ;;
  esac
fi

echo "== 3b. MUTANT: a \`paths:\` filter added to the base-branch checker =="
# Review cycle 1, P2 — the positive assertion that this trigger carries `types` and NOTHING else. A
# filter here narrows a gate that validates every workflow file in the merge result, and every
# assertion about the trigger would still read true.
WL_PATHS="$TMP/wl-paths.yml"
if apply_mutation "$WL" "$WL_PATHS" \
  "    types: [opened, synchronize, reopened]" \
  "    types: [opened, synchronize, reopened]
    paths:
      - '.github/workflows/**'" \
  "a narrowing filter must be constructible"; then
  run_check 1 "a \`paths:\` on \`pull_request_target:\` is REFUSED" WL_FILE="$WL_PATHS"
  case "$LAST_OUT" in
    *paths*) pass "the refusal NAMES the narrowing filter" ;;
    *) fail "the refusal did not name the narrowing filter" ;;
  esac
fi

echo "== 4. MUTANT: the \`types:\` key deleted (GitHub's default matches the values) =="
WL_NOTYPES="$TMP/wl-notypes.yml"
if apply_mutation "$WL" "$WL_NOTYPES" \
  "  pull_request_target:
    types: [opened, synchronize, reopened]" \
  "  pull_request_target:" \
  "an implicit default must be distinguishable from a decided one"; then
  run_check 1 "an absent \`types:\` is REFUSED — the decision needs an artifact" WL_FILE="$WL_NOTYPES"
fi

echo "== 5. MUTANT: harness-single-source loses its \`paths:\` key =="
HSS_BLOCK="  pull_request:
    paths:
      - 'bin/harness'
      - 'scripts/orchestrator-harness/**'
      - 'scripts/cloud-cell-supervisor.sh'
      - '.github/workflows/harness-single-source.yml'"
HSS_NOPATHS="$TMP/hss-nopaths.yml"
if apply_mutation "$HSS" "$HSS_NOPATHS" "$HSS_BLOCK" "  pull_request:" \
  "the paths key must be removable"; then
  run_check 1 "a workflow that runs on every PR again is REFUSED" HSS_FILE="$HSS_NOPATHS"
fi

echo "== 6. MUTANT: \`paths:\` reduced to a no-op =="
HSS_NOOP="$TMP/hss-noop.yml"
if apply_mutation "$HSS" "$HSS_NOOP" "$HSS_BLOCK" "  pull_request:
    paths:
      - '**'" \
  "a no-op filter must be constructible"; then
  run_check 1 "a \`paths: ['**']\` that reads like a reduction is REFUSED" HSS_FILE="$HSS_NOOP"
fi

echo "== 7. MUTANT: \`edited\` dropped from the REQUIRED context =="
PC_NOEDIT="$TMP/pc-noedit.yml"
if apply_mutation "$PC" "$PC_NOEDIT" \
  "    types:
      - opened
      - synchronize
      - reopened
      - edited" \
  "    types:
      - opened
      - synchronize
      - reopened" \
  "the asymmetry arm must be constructible"; then
  run_check 1 "pipeline-compliance losing \`edited\` is REFUSED (its #513 binding needs it)" PC_FILE="$PC_NOEDIT"
fi

echo "== 7b. MUTANT: a \`paths:\` filter added to the REQUIRED context =="
# Review cycle 1, P1 — the second half of the asymmetry. Dropping `edited` there lets a forged body
# marker ride a stale green; ADDING a path filter there makes the required context unsatisfiable
# (GitHub keeps a filtered workflow's checks "Pending"), which blocks every merge.
PC_PATHS="$TMP/pc-paths.yml"
if apply_mutation "$PC" "$PC_PATHS" \
  "    types:
      - opened
      - synchronize
      - reopened
      - edited" \
  "    types:
      - opened
      - synchronize
      - reopened
      - edited
    paths:
      - 'scripts/**'" \
  "a filter on the required context must be constructible"; then
  run_check 1 "a \`paths:\` filter on pipeline-compliance is REFUSED (it would leave the required context Pending)" \
    PC_FILE="$PC_PATHS"
  case "$LAST_OUT" in
    *paths*) pass "the refusal NAMES the filter and the consequence" ;;
    *) fail "the refusal did not name the filter" ;;
  esac
fi

echo "== 8. ADMISSION: every path the doctor step can read is admitted =="
# Each entry names the reader it belongs to. This list is the assertion: a filter that stops
# admitting one of them is a coverage loss, and the mandate for this change is to err WIDE (#3001 —
# an arm that was right about `bin/harness` was wrong about the machine it landed on, so the rule is
# "everything the read depends on", never "the file under test").
READ_PATHS="bin/harness
scripts/orchestrator-harness/check-single-source.sh
scripts/orchestrator-harness/lane.sh
scripts/orchestrator-harness/spawn-gate.sh
scripts/orchestrator-harness/worker-terminal.sh
scripts/orchestrator-harness/uv-env.sh
scripts/cloud-cell-supervisor.sh
.github/workflows/harness-single-source.yml"
while IFS= read -r p; do
  [ -n "$p" ] || continue
  expect_admit yes "admitted: $p" "$HSS" "$p"
done <<<"$READ_PATHS"

expect_admit no "a docs-only diff does NOT trigger the job (the filter is not a no-op)" "$HSS" "docs/ops/fleet-capacity.md"

echo "== 9. DISCRIMINATION: the admission arms can fail =="
HSS_NARROW="$TMP/hss-narrow.yml"
if apply_mutation "$HSS" "$HSS_NARROW" "$HSS_BLOCK" "  pull_request:
    paths:
      - 'bin/harness'" \
  "a narrowed filter must be constructible"; then
  expect_admit no "a filter narrowed to 'bin/harness' EXCLUDES scripts/orchestrator-harness/lane.sh (so arm 8 is live)" \
    "$HSS_NARROW" "scripts/orchestrator-harness/lane.sh"
  expect_admit yes "…while still admitting bin/harness (the narrowed filter is not broken, just narrower)" \
    "$HSS_NARROW" "bin/harness"
fi

echo "== 10. NON-VACUITY: a reader that cannot answer never reports a pass =="
run_check 2 "a missing workflow-lock.yml is rc 2, not a green" WL_FILE="$TMP/absent.yml"
WL_NOTRIGGER="$TMP/wl-notrigger.yml"
if apply_mutation "$WL" "$WL_NOTRIGGER" \
  "  pull_request_target:" \
  "  push:" \
  "the base-branch trigger must be removable"; then
  run_check 2 "a workflow-lock with no \`pull_request_target:\` trigger is rc 2, not a green" WL_FILE="$WL_NOTRIGGER"
fi

echo
printf 'PASS %d · FAIL %d · SKIP %d\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -gt 0 ]; then
  printf '❌ %d trigger-scope assertion(s) failed\n' "$FAIL"
  exit 1
fi
printf '✅ the trigger scope is as decided\n'
exit 0
