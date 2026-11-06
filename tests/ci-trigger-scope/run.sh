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
#     reviewer attestation INTO THE PR BODY, so every record that APPENDS the marker was an `edited` activity and
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
#  3b. MUTANT: a `paths:` filter added to the base-branch checker     → must FAIL (a filter there is
#      a NARROWING on a gate that validates every workflow file in the merge result).
#   4. MUTANT: the `types:` key deleted (GitHub's default is the same three, so the VALUES still
#      match — the arm exists because an implicit default is not an artifact) → must FAIL.
#   5. MUTANT: `harness-single-source.yml`'s `paths:` block deleted   → must FAIL.
#   6. MUTANT: `paths:` reduced to `'**'` (a no-op that reads like a filter) → must FAIL.
#   7. MUTANT: `edited` dropped from `pipeline-compliance.yml`        → must FAIL. The asymmetry is
#      the whole design: the required context KEEPS `edited`, because its #513 verdict binding
#      re-reads the body marker written after the last push. "Finishing the job" there would let a
#      forged `verdict=clean-micro` marker ride a stale green check to merge.
#  7b. MUTANT: a `paths:` filter added to the REQUIRED context         → must FAIL (a path-filtered
#      workflow's checks stay "Pending", so the required context becomes unsatisfiable).
#  7c. MUTANT: `types:`/`branches-ignore:` added to the single-source guard → must FAIL (a second
#      filter key narrows coverage the path arm cannot see).
#  7d. MUTANT: a sibling key's block sequence read as `types:`        → must FAIL. The reader used to
#      attribute a FOLLOWING key's list to the preceding one.
#  7e. MUTANT: a SECOND `on:` trigger beside `pull_request_target:` / `pull_request:` → must FAIL.
#      Pinning one trigger's filters is not enough: a second trigger re-opens all of it.
#  7f. MUTANT: a `push:` trigger added to `pipeline-compliance.yml`  → must FAIL (the same `on:`
#      key-set pin on the required context).
#  7g. MUTANT: the required job's `issue_comment` guard dropped      → must FAIL. `issue_comment:` is
#      ADMITTED here (a decided, documented trigger), but only as a GUARDED PAIR: bound to the
#      `if: github.event_name != 'issue_comment'` line on the `pipeline-compliance` JOB — not on the
#      `workflow-drift` twin, which carries the same text — so the required context can never be
#      satisfied by a comment. A genuinely new trigger beside the admitted one is still refused BY NAME.
#      The GUARD'S SHAPE is pinned in both directions too: `if: true || <guard>` (contains the guard
#      text, evaluates TRUE) and `if: <guard> && x || true` (the tail is a DISJUNCTION around the guard)
#      must FAIL, while a NARROWING `… && …` suffix, a trailing YAML comment, a `!cancelled() &&`
#      conjunct, and the equivalent `${{ … }}` / double-quoted spellings must PASS — a tolerance that
#      accepts the weakening half and refuses the safe half is backwards. A DUPLICATE `if:` (guard,
#      then `if: true`) must FAIL: one matching line does not guard a job. And the block terminator is
#      an INDENT test, so a flow-mapped job header (`  job: {name: x}`) ends the block just as a bare or
#      commented one does. Not modelled: an `if: >-` block scalar — refused, and the FINDING says so
#      rather than claiming the guard is absent.
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
# ⛔ "THE REFUSAL NAMES X" MUST READ THE FINDINGS, NOT THE WHOLE BUFFER (review cycle 2, P2).
# `LAST_OUT` is the combined output of all THREE file reads, and the live reads always print the
# `harness-single-source … paths:` line and the `pipeline-compliance … edited` line. So a
# `case "$LAST_OUT" in *paths*)` / `*edited*` / `*synchronize*` matched a static report line and could
# never fail — four arms that pinned nothing while claiming to. `FINDINGS` holds only `FINDING:` lines.
FINDINGS=""
findings_only() { FINDINGS="$(grep '^FINDING:' <<<"$LAST_OUT" || true)"; }

run_check() { # <want-rc> <label> [VAR=value ...]
  local want="$1" label="$2"
  shift 2
  local rc
  LAST_OUT="$(env "$@" node "$CHECK" 2>&1)"
  rc=$?
  findings_only
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
  case "$FINDINGS" in
    *edited*) pass "the refusal NAMES \`edited\` and why it is the one being removed" ;;
    *) fail "the refusal did not name \`edited\` in its FINDING line" ;;
  esac
fi

echo "== 3. MUTANT: \`synchronize\` dropped =="
WL_NOSYNC="$TMP/wl-nosync.yml"
if apply_mutation "$WL" "$WL_NOSYNC" \
  "    types: [opened, synchronize, reopened]" \
  "    types: [opened, reopened]" \
  "a head-moving event must be droppable"; then
  run_check 1 "a \`types:\` set that lost \`synchronize\` is REFUSED" WL_FILE="$WL_NOSYNC"
  case "$FINDINGS" in
    *synchronize*) pass "the refusal NAMES the lost event" ;;
    *) fail "the refusal did not name the lost event in its FINDING line" ;;
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
  case "$FINDINGS" in
    *paths*) pass "the refusal NAMES the narrowing filter" ;;
    *) fail "the refusal did not name the narrowing filter in its FINDING line" ;;
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
  case "$FINDINGS" in
    *paths*) pass "the refusal NAMES the filter and the consequence" ;;
    *) fail "the refusal did not name the filter in its FINDING line" ;;
  esac
fi

echo "== 7c. MUTANT: harness-single-source narrowed by a SECOND filter key =="
# Review cycle 2, P1 — the mirror of 3b. `types: [opened]` drops every synchronize (no later head is
# ever measured) and `branches-ignore: [main]` stops the job firing on any PR at all; the whole suite
# was green over both, because the arms only ever asked about `paths`. APPENDED after the paths block
# on purpose: inserting between `pull_request:` and `paths:` would red only because arms 5/6/9's
# mutation anchor stops matching, which reports the wrong diagnosis.
HSS_TYPES="$TMP/hss-types.yml"
if apply_mutation "$HSS" "$HSS_TYPES" \
  "      - '.github/workflows/harness-single-source.yml'" \
  "      - '.github/workflows/harness-single-source.yml'
    types: [opened]" \
  "a second filter key must be constructible"; then
  run_check 1 "a \`types:\` narrowing the guard's coverage is REFUSED" HSS_FILE="$HSS_TYPES"
  case "$FINDINGS" in
    *types*) pass "the refusal NAMES the narrowing key" ;;
    *) fail "the refusal did not name the narrowing key in its FINDING line" ;;
  esac
fi

HSS_BRANCHES="$TMP/hss-branches.yml"
if apply_mutation "$HSS" "$HSS_BRANCHES" \
  "      - '.github/workflows/harness-single-source.yml'" \
  "      - '.github/workflows/harness-single-source.yml'
    branches-ignore: [main]" \
  "a branch filter must be constructible"; then
  run_check 1 "a \`branches-ignore: [main]\` that disables the guard on every PR is REFUSED" \
    HSS_FILE="$HSS_BRANCHES"
fi

echo "== 7d. MUTANT: a sibling key's list must not be read as \`types:\` =="
# Review cycle 2, P2 — the reader used to collect a key's items with a FILTER over every deeper line,
# so a following sibling's block sequence was attributed to the preceding key. Measured fail-open: an
# emptied `types:` followed by `branches: [- edited]` printed `types: … edited` and exited 0.
PC_SIBLING="$TMP/pc-sibling.yml"
if apply_mutation "$PC" "$PC_SIBLING" \
  "    types:
      - opened
      - synchronize
      - reopened
      - edited" \
  "    types:
    branches:
      - edited" \
  "the cross-key misread must be constructible"; then
  run_check 1 "a 'types:' emptied and a sibling list carrying 'edited' does not read GREEN" \
    PC_FILE="$PC_SIBLING"
  case "$FINDINGS" in
    *types*) pass "the refusal names \`types:\`, not the sibling's value" ;;
    *) fail "the refusal did not name \`types:\`" ;;
  esac
fi

echo "== 7e. MUTANT: a SECOND \`on:\` trigger re-opening the same coverage =="
# Review of the last delta, P2 — pinning a trigger's own filter keys is not enough. Measured before
# this arm: \`on.pull_request: types: [edited]\` added beside the pinned \`pull_request_target:\` left
# the pin suite (124/124), this shard (33/33) and the content lock all GREEN, so \`edited\` was
# silently re-addable one line away from the assertion that says it is gone.
WL_SECOND="$TMP/wl-second-trigger.yml"
if apply_mutation "$WL" "$WL_SECOND" \
  "  pull_request_target:
    types: [opened, synchronize, reopened]" \
  "  pull_request_target:
    types: [opened, synchronize, reopened]
  pull_request:
    types: [edited]" \
  "a second trigger must be constructible"; then
  run_check 1 "a second \`on:\` trigger beside \`pull_request_target:\` is REFUSED" WL_FILE="$WL_SECOND"
  case "$FINDINGS" in
    *"declares [pull_request]"*) pass "the refusal NAMES the added trigger" ;;
    *) fail "the refusal did not name the added trigger in its FINDING line" ;;
  esac
fi

HSS_SECOND="$TMP/hss-second-trigger.yml"
if apply_mutation "$HSS" "$HSS_SECOND" \
  "      - '.github/workflows/harness-single-source.yml'" \
  "      - '.github/workflows/harness-single-source.yml'
  push:
    branches: [main]" \
  "a second trigger must be constructible"; then
  run_check 1 "a \`push:\` trigger added to the single-source guard is REFUSED" HSS_FILE="$HSS_SECOND"
  case "$FINDINGS" in
    *"declares [push]"*) pass "the refusal NAMES the added trigger" ;;
    *) fail "the refusal did not name the added trigger in its FINDING line" ;;
  esac
fi

echo "== 7f. MUTANT: a \`push:\` trigger added to the REQUIRED context =="
# The third new `on:` pin. It fired when measured, but a pin with no arm is a pin nothing keeps
# firing (this suite's own header: "a pin that cannot fail is not a pin").
PC_PUSH="$TMP/pc-push.yml"
if apply_mutation "$PC" "$PC_PUSH" \
  "  pull_request:
    branches:
      - main" \
  "  push:
    branches: [main]
  pull_request:
    branches:
      - main" \
  "a push trigger on the required context must be constructible"; then
  run_check 1 "a \`push:\` trigger on pipeline-compliance is REFUSED (its verdict would attach to main)" \
    PC_FILE="$PC_PUSH"
  case "$FINDINGS" in
    *"declares [push]"*) pass "the refusal NAMES the added trigger" ;;
    *) fail "the refusal did not name the added trigger in its FINDING line" ;;
  esac
fi

echo '== 7g. MUTANT: `issue_comment` admitted ONLY as a guarded pair =='
# `issue_comment:` is on `pipeline-compliance.yml` ON PURPOSE — the comment-triggered revalidation job
# re-reads a gate verdict after a body edit and the required job guards itself out of the event. That
# makes the trigger DECIDED, so the allow-list admits it. But an allow-list entry by NAME alone would be
# the fail-open this suite exists to prevent: the required status context must never be satisfiable by
# a comment. So the admission is bound to the guard, and dropping the guard must be REFUSED.
PC_NOGUARD="$TMP/pc-noguard.yml"
if apply_mutation "$PC" "$PC_NOGUARD" \
  "  pipeline-compliance:
    name: pipeline-compliance
    # \`issue_comment\` must never satisfy the required context: this job runs the
    # gate for a PR only. The revalidation job below owns the comment event.
    if: github.event_name != 'issue_comment'" \
  "  pipeline-compliance:
    name: pipeline-compliance" \
  "the required job's comment guard must be removable"; then
  run_check 1 "dropping the required job's \`issue_comment\` guard is REFUSED" PC_FILE="$PC_NOGUARD"
  case "$FINDINGS" in
    *"does not carry"*"event_name != 'issue_comment'"*) pass "the refusal NAMES the guard the required job lost" ;;
    *) fail "the refusal did not name the dropped guard in its FINDING line" ;;
  esac
fi

# ⛔ AND THE GUARD MUST BE THE REQUIRED JOB'S OWN. `workflow-drift` carries the SAME line for its own
# reasons, so a whole-file match would report the required job guarded while its guard was gone. This
# mutant deletes ONLY the `pipeline-compliance` one and leaves `workflow-drift`'s in place — if the
# reader is text-wide it reads green here, which is exactly the false pass being pinned out.
PC_NOGUARD2="$TMP/pc-noguard2.yml"
if apply_mutation "$PC" "$PC_NOGUARD2" \
  "    # gate for a PR only. The revalidation job below owns the comment event.
    if: github.event_name != 'issue_comment'" \
  "    # gate for a PR only. The revalidation job below owns the comment event." \
  "the required job's guard must be removable while its twin survives"; then
  if grep -c "event_name != 'issue_comment'" "$PC_NOGUARD2" | grep -qx 1; then
    run_check 1 "the guard is matched on the REQUIRED job, not on \`workflow-drift\`'s twin" PC_FILE="$PC_NOGUARD2"
  else
    fail "could not construct the twin-guard mutant (the survivor count is not 1) — the arm would be vacuous"
  fi
fi

# ⛔ AND A GENUINELY NEW TRIGGER IS STILL NAMED. The widening must not swallow the next one: adding
# `issue_comment:` must not turn this arm into a permanent green for any extra trigger.
PC_COMMENT_AND_PUSH="$TMP/pc-comment-push.yml"
if apply_mutation "$PC" "$PC_COMMENT_AND_PUSH" \
  "  pull_request:
    branches:
      - main" \
  "  push:
    branches: [main]
  pull_request:
    branches:
      - main" \
  "a push trigger beside the admitted comment trigger must be constructible"; then
  run_check 1 "with \`issue_comment\` ADMITTED, an added \`push:\` is STILL refused" PC_FILE="$PC_COMMENT_AND_PUSH"
  case "$FINDINGS" in
    *"declares [push]"*) pass "…and the refusal names the NEW trigger, not the admitted one" ;;
    *) fail "the refusal did not name the newly added trigger alone" ;;
  esac
fi

# ⛔ AND THE GUARD MUST BE AT THE JOB'S OWN KEY INDENT — not merely somewhere in the job's text.
# `^\s*if:` also matches a STEP's `if:`, and a step-level guard does NOT stop the job from running on
# the comment event, so a text-wide matcher reports the required job guarded while the job itself
# carries no `if:` at all and mints the required verdict from a comment.
#
# ⛔ AND THE STEP'S `if:` MUST BE THE JOB BLOCK'S *LAST* LINE. A guard placed MID-job is a vacuous
# mutant: the value fold appends everything below it (the rest of the steps) into one value, that value
# fails the whole-expression match whatever the key anchor is, and the arm reads rc=1 under a text-wide
# matcher too. MEASURED by sabotage — with `ownRe` widened to `^\s*`, the mid-job version left the
# suite at PASS 64 · FAIL 0, i.e. the arm could not fail. As the last line of the block the fold
# appends nothing, and the same sabotage is caught (PASS 64 · FAIL 1).
PC_STEPGUARD_MID="$TMP/pc-stepguard-mid.yml"
PC_STEPGUARD="$TMP/pc-stepguard.yml"
if apply_mutation "$PC" "$PC_STEPGUARD_MID" \
  "    # gate for a PR only. The revalidation job below owns the comment event.
    if: github.event_name != 'issue_comment'" \
  "    # gate for a PR only. The revalidation job below owns the comment event." \
  "the required job's guard must be removable for the step-guard arm"; then
  if apply_mutation "$PC_STEPGUARD_MID" "$PC_STEPGUARD" \
    '            echo "::notice::consumer checkout — materialize-agents suite skipped"
          fi' \
    '            echo "::notice::consumer checkout — materialize-agents suite skipped"
          fi
      - name: probe-last-line
        if: github.event_name != '"'"'issue_comment'"'"'' \
    "a step-level guard must be insertable as the job block's last line"; then
    run_check 1 "a guard on a STEP (the block's last line) does not satisfy the required job's guard" PC_FILE="$PC_STEPGUARD"
  fi
fi

# ⛔ THE INTERVENING JOB'S `if: >-` MUST GO TOO, or this arm is VACUOUS. `revalidate-on-issue-comment`
# sits between the required job and the twin that carries the same guard, and it owns a `if: >-` BLOCK
# SCALAR — a spelling this reader deliberately does not model, so it fails the whole-expression match.
# Left in place it poisons `every()`: the arm then reads rc=1 whether the block terminated correctly or
# ran on to EOF, and the suite stays green with the terminator replaced by any broken shape. MEASURED by
# sabotage: with the terminator reverted to a bare-only enumeration the suite read PASS 64 · FAIL 0.
# With that `if:` removed, the arm is load-bearing again (correct terminator rc=1, broken rc=0).
PC_NO_POISON_FIND="    if: >-
      github.event_name == 'issue_comment' &&
      github.event.issue.pull_request == null"
PC_NO_POISON_REPL="    # the intervening job's block-scalar guard is removed for this mutant"

# ⛔ AND THE BLOCK MUST END ON A JOB HEADER THAT CARRIES A COMMENT. A legal header with a trailing YAML
# comment does not match a bare-only terminator, so the required job's block over-extends into the NEXT
# jobs and a guard in a LATER job satisfies an assertion about THIS one. Both intervening headers are
# commented because `revalidate-on-issue-comment` sits between the required job and the twin that
# carries the same guard line — with only the twin commented, a bare header still stops the block and
# the arm cannot be driven (measured: that version of this arm was vacuous, it read rc=1 either way).
PC_OVEREXT_MID1="$TMP/pc-overext-mid1.yml"
PC_OVEREXT_DEPOISON="$TMP/pc-overext-depoison.yml"
PC_OVEREXT_MID2="$TMP/pc-overext-mid2.yml"
PC_OVEREXT="$TMP/pc-overext.yml"
if apply_mutation "$PC" "$PC_OVEREXT_MID1" \
  "    # gate for a PR only. The revalidation job below owns the comment event.
    if: github.event_name != 'issue_comment'" \
  "    # gate for a PR only. The revalidation job below owns the comment event." \
  "the required job's guard must be removable for the over-extension arm"; then
  if apply_mutation "$PC_OVEREXT_MID1" "$PC_OVEREXT_DEPOISON" "$PC_NO_POISON_FIND" "$PC_NO_POISON_REPL" \
    "the intervening job's block-scalar guard must be removable"; then
  if apply_mutation "$PC_OVEREXT_DEPOISON" "$PC_OVEREXT_MID2" \
    "  revalidate-on-issue-comment:
" \
    "  revalidate-on-issue-comment:  # comment-driven revalidation
" \
    "the next job header must be commentable"; then
    if apply_mutation "$PC_OVEREXT_MID2" "$PC_OVEREXT" \
      "  workflow-drift:
" \
      "  workflow-drift:  # twin job, same guard
" \
      "the twin's job header must be commentable"; then
      run_check 1 "a job header carrying a trailing comment still ENDS the required job's block" PC_FILE="$PC_OVEREXT"
    fi
  fi
  fi
fi

# ⛔ AND "ENDS THE BLOCK" MUST BE AN INDENT TEST, NOT AN ENUMERATION OF HEADER SPELLINGS. The arm
# above pins ONE omitted spelling (a trailing YAML comment); any list of spellings has more, and each
# omission lets the block run on into a later job where THAT job's guard satisfies an assertion about
# this one. Here the two intervening headers are legal FLOW MAPPINGS (`  job: {name: x}`), which no
# bare/quoted/comment terminator matches — measured: an enumerated terminator read ok/rc=0 on this
# mutant. A job's children are at 4 spaces, so "a non-space, non-# character at column 2" is the
# complete test, and this arm is what keeps it complete.
PC_FLOWEXT_MID1="$TMP/pc-flowext-mid1.yml"
PC_FLOWEXT_DEPOISON="$TMP/pc-flowext-depoison.yml"
PC_FLOWEXT_MID2="$TMP/pc-flowext-mid2.yml"
PC_FLOWEXT="$TMP/pc-flowext.yml"
if apply_mutation "$PC" "$PC_FLOWEXT_MID1" \
  "    # gate for a PR only. The revalidation job below owns the comment event.
    if: github.event_name != 'issue_comment'" \
  "    # gate for a PR only. The revalidation job below owns the comment event." \
  "the required job's guard must be removable for the flow-mapped-extension arm"; then
  if apply_mutation "$PC_FLOWEXT_MID1" "$PC_FLOWEXT_DEPOISON" "$PC_NO_POISON_FIND" "$PC_NO_POISON_REPL" \
    "the intervening job's block-scalar guard must be removable"; then
  if apply_mutation "$PC_FLOWEXT_DEPOISON" "$PC_FLOWEXT_MID2" \
    "  revalidate-on-issue-comment:
" \
    "  revalidate-on-issue-comment: {name: revalidate-on-issue-comment}
" \
    "the next job header must be flow-mappable"; then
    if apply_mutation "$PC_FLOWEXT_MID2" "$PC_FLOWEXT" \
      "  workflow-drift:
" \
      "  workflow-drift: {name: workflow-drift}
" \
      "the twin's job header must be flow-mappable"; then
      run_check 1 "a FLOW-MAPPED job header still ENDS the required job's block" PC_FILE="$PC_FLOWEXT"
    fi
  fi
  fi
fi

# ⛔ AND THE GUARD MUST BE THE WHOLE EXPRESSION, NOT MERELY "ANYTHING, THEN THE GUARD TEXT". A
# leading `.*` ("tolerate a compound `if:`") tolerates the compound in the WRONG DIRECTION: `if: true
# || <guard>` CONTAINS the guard text and evaluates to TRUE, so the required job runs on the comment
# event while this gate reads green — the fail-open the admission exists to prevent. The same `.*`
# refused a NARROWING suffix, which is safe by construction (ANDing with the guard can only exclude
# more events). Both directions are pinned, so a future "just make the regex tolerant" edit reds here.
PC_ORGUARD="$TMP/pc-orguard.yml"
if apply_mutation "$PC" "$PC_ORGUARD" \
  "    # gate for a PR only. The revalidation job below owns the comment event.
    if: github.event_name != 'issue_comment'" \
  "    # gate for a PR only. The revalidation job below owns the comment event.
    if: true || github.event_name != 'issue_comment'" \
  "the required job's guard must be weakenable with an always-true prefix"; then
  run_check 1 "an always-true \`||\` prefix does NOT satisfy the required job's guard" PC_FILE="$PC_ORGUARD"
  case "$FINDINGS" in
    *"does not carry"*) pass "…and the refusal still says the job does not carry the guard" ;;
    *) fail "the always-true-prefix refusal did not name the lost guard" ;;
  esac
fi

# ⛔ AND A STRICTLY-NARROWING SUFFIX IS ACCEPTED. `… && <anything>` can only exclude MORE events than
# the guard alone, so it is safe by construction and must not read as a lost guard — a false block on a
# guarded tree is its own defect (the over-block direction), and it is what a leading `.*` produced.
PC_NARROW="$TMP/pc-narrow.yml"
if apply_mutation "$PC" "$PC_NARROW" \
  "    # gate for a PR only. The revalidation job below owns the comment event.
    if: github.event_name != 'issue_comment'" \
  "    # gate for a PR only. The revalidation job below owns the comment event.
    if: github.event_name != 'issue_comment' && github.event.action != 'deleted'" \
  "the required job's guard must be narrowable with a suffix"; then
  run_check 0 "a NARROWING suffix on the guard is ACCEPTED (it can only exclude more events)" PC_FILE="$PC_NARROW"
fi

# ⛔ AND THE SUFFIX TOLERANCE MUST NOT BECOME A DISJUNCTION. `&&` binds TIGHTER than `||`, so
# `… && x || true` evaluates to TRUE and the required job runs on the comment event — "anything that
# came after the guard" is exactly as unsafe as "anything that came before it". Pinned because the
# first version of this tolerance accepted it (measured: ok/rc=0).
PC_ORTAIL="$TMP/pc-ortail.yml"
if apply_mutation "$PC" "$PC_ORTAIL" \
  "    # gate for a PR only. The revalidation job below owns the comment event.
    if: github.event_name != 'issue_comment'" \
  "    # gate for a PR only. The revalidation job below owns the comment event.
    if: github.event_name != 'issue_comment' && github.event.action != 'deleted' || true" \
  "the required job's guard must be defeatable with a trailing disjunction"; then
  run_check 1 "a trailing \`|| …\` DISJUNCTION does NOT satisfy the required job's guard" PC_FILE="$PC_ORTAIL"
fi

# …while a trailing YAML COMMENT carries no operator at all (YAML strips it), so refusing it would be a
# false block on a guarded tree — and a false block is what invites the next loosening.
PC_GUARDCOMMENT="$TMP/pc-guardcomment.yml"
if apply_mutation "$PC" "$PC_GUARDCOMMENT" \
  "    # gate for a PR only. The revalidation job below owns the comment event.
    if: github.event_name != 'issue_comment'" \
  "    # gate for a PR only. The revalidation job below owns the comment event.
    if: github.event_name != 'issue_comment'  # excludes the comment event" \
  "the required job's guard must be commentable"; then
  run_check 0 "a trailing YAML COMMENT on the guard is ACCEPTED (it carries no operator)" PC_FILE="$PC_GUARDCOMMENT"
fi

# …and `!cancelled() &&` is the idiom GitHub's own docs lead with, and it is a CONJUNCT: ANDing it in
# can only exclude more events. Enumerated as that exact token, never as a `.*` prefix — an open prefix
# is precisely the P1 shape ("anything, then the guard text").
PC_NOTCANCELLED="$TMP/pc-notcancelled.yml"
if apply_mutation "$PC" "$PC_NOTCANCELLED" \
  "    # gate for a PR only. The revalidation job below owns the comment event.
    if: github.event_name != 'issue_comment'" \
  "    # gate for a PR only. The revalidation job below owns the comment event.
    if: \${{ !cancelled() && github.event_name != 'issue_comment' }}" \
  "the required job's guard must be prefixable with \`!cancelled() &&\`"; then
  run_check 0 "a \`!cancelled() &&\` CONJUNCT prefix is ACCEPTED, not a false block" PC_FILE="$PC_NOTCANCELLED"
fi

# ⛔ AND A DUPLICATE `if:` MUST NOT SATISFY THE ASSERTION. A job carrying the guard and then a second
# `if: true` has one matching line and one that re-opens the event; a first-match reader reports it
# guarded by the line the effective value is not. Every arm above would pass while the job ran on the
# comment event, so this is the one shape that defeats the whole binding from inside it.
PC_DUPIF="$TMP/pc-dupif.yml"
if apply_mutation "$PC" "$PC_DUPIF" \
  "    # gate for a PR only. The revalidation job below owns the comment event.
    if: github.event_name != 'issue_comment'" \
  "    # gate for a PR only. The revalidation job below owns the comment event.
    if: github.event_name != 'issue_comment'
    if: true" \
  "the required job's guard must be duplicable"; then
  run_check 1 "a DUPLICATE \`if:\` that re-opens the event does not satisfy the guard" PC_FILE="$PC_DUPIF"
fi

# ⛔ AND AN EQUIVALENT SPELLING IS NOT A LOST GUARD. `${{ … }}` is the form GitHub documents as
# equivalent, and YAML permits single OR double quotes on `issue_comment` — a formatter may switch
# them. Refusing either is a false block on a correctly-guarded tree (category-B over-block), so both
# spellings are pinned as ACCEPTED rather than left to drift into a red nobody can explain.
PC_DOLLAR="$TMP/pc-dollar.yml"
PC_DQUOTE="$TMP/pc-dquote.yml"
if apply_mutation "$PC" "$PC_DOLLAR" \
  "    # gate for a PR only. The revalidation job below owns the comment event.
    if: github.event_name != 'issue_comment'" \
  "    # gate for a PR only. The revalidation job below owns the comment event.
    if: \${{ github.event_name != 'issue_comment' }}" \
  "the required job's guard must be wrappable in \${{ }}"; then
  run_check 0 "GitHub's equivalent \`\${{ … }}\` wrapper is ACCEPTED, not a false block" PC_FILE="$PC_DOLLAR"
fi
if apply_mutation "$PC" "$PC_DQUOTE" \
  "    # gate for a PR only. The revalidation job below owns the comment event.
    if: github.event_name != 'issue_comment'" \
  "    # gate for a PR only. The revalidation job below owns the comment event.
    if: github.event_name != \"issue_comment\"" \
  "the required job's guard must be re-quotable"; then
  run_check 0 "a DOUBLE-QUOTED \`issue_comment\` (YAML-identical) is ACCEPTED" PC_FILE="$PC_DQUOTE"
fi

echo "== 7h. MUTANT: the guard EXPRESSION's shape and YAML folding =="
# ⛔ These arms exist because every one of them was a MEASURED false PASS or false block, not a
# hypothetical. A guard is only useful if the gate reads the expression YAML actually evaluates.
PC_GUARD_ANCHOR="    # gate for a PR only. The revalidation job below owns the comment event.
    if: github.event_name != 'issue_comment'"
PC_GUARD_KEPT="    # gate for a PR only. The revalidation job below owns the comment event.
    if: github.event_name != 'issue_comment'"

# (a) A YAML plain scalar CONTINUES on the next line when that line is indented deeper than the key.
#     `if:` + a folded `|| true` therefore evaluates to TRUE and the required job RUNS on the comment
#     event, while a line-wise reader sees the guard verbatim. Measured: ok/rc=0 before folding.
PC_FOLDED_OR="$TMP/pc-folded-or.yml"
if apply_mutation "$PC" "$PC_FOLDED_OR" "$PC_GUARD_ANCHOR" \
  "$PC_GUARD_KEPT
      || true" \
  "a folded \`||\` continuation must be constructible"; then
  run_check 1 "a \`||\` folded onto the guard's next line is REFUSED" PC_FILE="$PC_FOLDED_OR"
fi

# (b) …while the SAFE direction stays accepted: ANDing can only exclude more events. A gate that
#     refused this would be a false block on a correctly guarded tree.
PC_FOLDED_AND="$TMP/pc-folded-and.yml"
if apply_mutation "$PC" "$PC_FOLDED_AND" "$PC_GUARD_ANCHOR" \
  "$PC_GUARD_KEPT
      && github.event.action != 'deleted'" \
  "a folded \`&&\` narrowing must be constructible"; then
  run_check 0 "a folded \`&&\` NARROWING is accepted (ANDing only excludes more events)" PC_FILE="$PC_FOLDED_AND"
fi

# (c) YAML permits the key quoted. A duplicate written `"if": true` is the value the workflow
#     evaluates (PyYAML: `if = True`), so a reader that only matched the BARE spelling reads green
#     over it. Measured: ok/rc=0 when only `if:` was matched.
PC_DUP_IF="$TMP/pc-dup-if.yml"
if apply_mutation "$PC" "$PC_DUP_IF" "$PC_GUARD_ANCHOR" \
  "$PC_GUARD_KEPT
    \"if\": true" \
  "a duplicate quoted \`\"if\":\` must be constructible"; then
  run_check 1 "a duplicate \`\"if\": true\` cannot hide behind the guarded \`if:\`" PC_FILE="$PC_DUP_IF"
fi

# (c2) …and WHITESPACE BEFORE THE COLON is the same key in YAML (`if :`). Requiring the colon hard
#      against the name left the duplicate invisible to `every()`, one space away from the quoted form
#      above, so the gate read ok/rc=0 over a job whose EFFECTIVE `if` is `True` (measured, PyYAML
#      `True`). A key-matching rule that knows only the spellings someone wrote down repeats exactly
#      the defect this section exists to close.
PC_DUP_IF_SPACE="$TMP/pc-dup-if-space.yml"
if apply_mutation "$PC" "$PC_DUP_IF_SPACE" "$PC_GUARD_ANCHOR" \
  "$PC_GUARD_KEPT
    if : true" \
  "a duplicate \`if :\` must be constructible"; then
  run_check 1 "a duplicate \`if : true\` (space before the colon) cannot hide either" PC_FILE="$PC_DUP_IF_SPACE"
fi

# (c1b) ⛔ A DUPLICATE JOB ID IS LAST-WINS IN YAML, so a first-match reader answers about the WRONG
#       job. A second `  pipeline-compliance:` block APPENDED AT EOF with no `if:` at all leaves the
#       effective `if` ABSENT — the job RUNS on the comment event — while the FIRST block still carries
#       the guard, so a first-match reader reports ok/rc=0. Measured: old reader rc=0, this reader rc=2.
#       The duplicate is appended, never prepended: prepending puts the guard in the SECOND block, the
#       first-match reader then finds no guard and reds at rc=1, and the arm would pin a false alarm
#       instead of the fail-open it exists for (measured — that version of this arm was vacuous).
#       The reader cannot answer which block is in force, so the only honest verdict is
#       CANNOT-VERIFY (rc=2), never green: an unanswerable question is not a pass.
PC_DUP_JOB="$TMP/pc-dup-job.yml"
if apply_mutation "$PC" "$PC_DUP_JOB" \
  '          echo "✅ no symlinks under .github/workflows"' \
  '          echo "✅ no symlinks under .github/workflows"

  pipeline-compliance:
    name: pipeline-compliance' \
  "a duplicate \`pipeline-compliance:\` job id must be appended"; then
  run_check 2 "a DUPLICATE \`pipeline-compliance:\` job id is CANNOT-VERIFY, never green" PC_FILE="$PC_DUP_JOB"
fi

# (c1e) ⛔ THE CONTAINER `jobs:` IS LAST-WINS TOO, one level above the job id. YAML keeps only the LAST
#       `jobs:` and discards the rest, so a second block redefines `pipeline-compliance` with no `if:`
#       at all while every job-id check inside the FIRST block still passes — measured rc=0 over an
#       effective `if` of ABSENT, including the plausible witness where the second block renames the
#       job (`pc-renamed:`) so no duplicate job id exists to count at all.
PC_DUP_JOBS="$TMP/pc-dup-jobs.yml"
if apply_mutation "$PC" "$PC_DUP_JOBS" \
  '          echo "✅ no symlinks under .github/workflows"' \
  '          echo "✅ no symlinks under .github/workflows"

jobs:
  pc-renamed:
    name: pipeline-compliance' \
  "a duplicate top-level \`jobs:\` must be constructible"; then
  run_check 2 "a DUPLICATE top-level \`jobs:\` is CANNOT-VERIFY, never green" PC_FILE="$PC_DUP_JOBS"
fi

# (c1e2) ⛔ AND THE REQUIRED JOB IS THE ONE THAT MINTS THE CONTEXT — BY **NAME**, NOT BY ID. The
#        workflow's own header says branch protection requires EXACTLY the check context
#        `pipeline-compliance`, and GitHub derives that context from `jobs.<id>.name` when present. So a
#        second job carrying `name: pipeline-compliance` and `if: true` mints the required context ON A
#        COMMENT EVENT while the guarded `pipeline-compliance` job still satisfies every assertion about
#        its own `if:` — measured rc=0 with the shadow job's effective `if` = `True`. The unguarded one
#        is the context that counts, so a duplicated context NAME must be CANNOT-VERIFY (which job the
#        merge is gated on becomes unanswerable), never a green read of the wrong block.
PC_SHADOW_JOB="$TMP/pc-shadow-job.yml"
if apply_mutation "$PC" "$PC_SHADOW_JOB" \
  '          echo "✅ no symlinks under .github/workflows"' \
  '          echo "✅ no symlinks under .github/workflows"

  shadow:
    name: pipeline-compliance
    if: true
    runs-on: ubuntu-latest' \
  "a shadow job minting the required context must be constructible"; then
  run_check 2 "a SECOND job minting the required context NAME is CANNOT-VERIFY" PC_FILE="$PC_SHADOW_JOB"
fi

# (c1e3) ⛔ AND THE MINTER'S `name:` MUST BE READ AS A YAML SCALAR, NOT AS RAW TEXT. The uniqueness
#        check compared the raw line text, so `name: pipeline-compliance  # mints the required context`
#        resolved to a DIFFERENT context — the shadow became an invisible minter, exactly one job
#        appeared to mint, and the gate read ok/rc=0 while the only job minting the context on a comment
#        event was the unguarded one (measured). The mirror fired too: the required job's own `name:`
#        carrying a comment read as "0 job(s) mint", a false block on a correct tree. A flow-mapped job
#        header (`shadow: {name: …}`) hides a `name:` from a line reader entirely, so it is refused.
PC_SHADOW_COMMENT="$TMP/pc-shadow-comment.yml"
if apply_mutation "$PC" "$PC_SHADOW_COMMENT" \
  '          echo "✅ no symlinks under .github/workflows"' \
  '          echo "✅ no symlinks under .github/workflows"

  shadow:
    name: pipeline-compliance  # mints the required context
    if: true
    runs-on: ubuntu-latest' \
  "a shadow minter whose name carries a comment must be constructible"; then
  run_check 2 "a shadow minter whose \`name:\` carries a COMMENT is still counted" PC_FILE="$PC_SHADOW_COMMENT"
fi

PC_SHADOW_FLOW="$TMP/pc-shadow-flow.yml"
if apply_mutation "$PC" "$PC_SHADOW_FLOW" \
  '          echo "✅ no symlinks under .github/workflows"' \
  '          echo "✅ no symlinks under .github/workflows"

  shadow: {name: pipeline-compliance, if: true, runs-on: ubuntu-latest}' \
  "a flow-mapped shadow job must be constructible"; then
  run_check 2 "a FLOW-MAPPED job header (which hides its \`name:\`) is CANNOT-VERIFY" PC_FILE="$PC_SHADOW_FLOW"
fi

# (c1e4) ⛔ AND A FLOW MAPPING IS NOT CONFINED TO ITS HEADER LINE. Inferring "no `name:` inside" from the
#        header line's own text is unsound exactly when the mapping continues: `shadow: {` /
#        `name: pipeline-compliance,` / `}` puts the context name on a FOLLOWING line, so the header text
#        does not contain it, the job was skipped as a non-minter, and a real second minter went
#        invisible — rc=0 while a comment event could satisfy the required context (measured, pyyaml
#        shows both jobs named `pipeline-compliance`). The mapping is now read to its closing brace
#        first, and both continuations are pinned: an opening brace on the header, and an opening brace
#        on the NEXT line (which the header-only check read as a block mapping).
PC_SHADOW_FLOW_MULTI="$TMP/pc-shadow-flow-multi.yml"
if apply_mutation "$PC" "$PC_SHADOW_FLOW_MULTI" \
  '          echo "✅ no symlinks under .github/workflows"' \
  '          echo "✅ no symlinks under .github/workflows"

  shadow: {
    name: pipeline-compliance,
    if: true,
    runs-on: ubuntu-latest }' \
  "a multi-line flow mapping shadow must be constructible"; then
  run_check 2 "a FLOW MAPPING continued over lines still COUNTS its minter" PC_FILE="$PC_SHADOW_FLOW_MULTI"
fi

# ⛔ AND A HEADER VALUE THAT DOES NOT *LEAD* WITH `{` IS STILL A FLOW MAPPING — or not a shape this
#    reader can read at all, which is the same answer. `^\s*\{` caught only a leading brace, so
#    `shadow: &a {name: pipeline-compliance, if: true}`, `shadow: !!map {…}` and an ALIAS value fell to
#    the BLOCK path, where no `name:` key line exists — the job was counted as minting its own id, a real
#    second minter with `if: true` went invisible, and the gate read ok/rc=0 on a workflow that admits
#    `issue_comment` (measured; pyyaml shows two jobs named `pipeline-compliance`). Only two header values
#    are classified: empty (a block mapping) and a value leading with `{` (a flow mapping, read to its
#    close). Anything else is refused.
PC_SHADOW_ANCHOR="$TMP/pc-shadow-anchor.yml"
if apply_mutation "$PC" "$PC_SHADOW_ANCHOR" \
  '          echo "✅ no symlinks under .github/workflows"' \
  '          echo "✅ no symlinks under .github/workflows"

  shadow: &a {name: pipeline-compliance, if: true}' \
  "an anchor-prefixed flow mapping shadow must be constructible"; then
  run_check 2 "a flow mapping behind an ANCHOR (\`&a {…}\`) still COUNTS its minter" PC_FILE="$PC_SHADOW_ANCHOR"
fi

PC_SHADOW_FLOW_NEXT="$TMP/pc-shadow-flow-next.yml"
if apply_mutation "$PC" "$PC_SHADOW_FLOW_NEXT" \
  '          echo "✅ no symlinks under .github/workflows"' \
  '          echo "✅ no symlinks under .github/workflows"

  shadow:
    {name: pipeline-compliance, if: true, runs-on: ubuntu-latest}' \
  "a flow mapping starting on the NEXT line must be constructible"; then
  run_check 2 "a FLOW MAPPING starting on the NEXT line still COUNTS its minter" PC_FILE="$PC_SHADOW_FLOW_NEXT"
fi

# (c1e5) ⛔ AND THE JOB'S KEY INDENT IS DERIVED, NOT ASSUMED. YAML requires only that a job's children
#        be DEEPER than its header, so a shadow whose children sit at 6 spaces declared a `name:` that a
#        hardcoded 4-space read never saw — a second minter invisible again (measured rc=0, pyyaml shows
#        two). Both resolvers now take the indent from the job's first key line, which also un-reds the
#        required job re-indented the same way (the mirror false block).
PC_SHADOW_INDENT6="$TMP/pc-shadow-indent6.yml"
if apply_mutation "$PC" "$PC_SHADOW_INDENT6" \
  '          echo "✅ no symlinks under .github/workflows"' \
  '          echo "✅ no symlinks under .github/workflows"

  shadow:
      name: pipeline-compliance
      if: true
      runs-on: ubuntu-latest' \
  "a shadow with 6-space children must be constructible"; then
  run_check 2 "a shadow whose children are DEEPER-indented still COUNTS its minter" PC_FILE="$PC_SHADOW_INDENT6"
fi

# …while a trailing comment on the REQUIRED job's own `name:` is a comment, not a different context.
PC_REQ_NAME_COMMENT="$TMP/pc-req-name-comment.yml"
if apply_mutation "$PC" "$PC_REQ_NAME_COMMENT" \
  "    name: pipeline-compliance
" \
  "    name: pipeline-compliance  # the required status context
" \
  "the required job's name must be commentable"; then
  run_check 0 "a trailing COMMENT on the required job's \`name:\` is ACCEPTED" PC_FILE="$PC_REQ_NAME_COMMENT"
fi

# (c1f0) ⛔ AND AN EXPLICIT KEY AT THE JOB *KEY* INDENT IS THE SAME UNMODELLED SHAPE. The refusal was
#        gated on the 2-space HEADER indent, so `? if` / `: true` at 4 spaces was neither matched by
#        `ownRe` nor refused: gate ok/rc=0 while YAML's effective `if` is `True` — a duplicate `if:`
#        hidden one indent below the shape already refused. An explicit key is not modelled at ANY
#        indent, so it is refused at every indent that can hold one.
PC_EXPLICIT_IF="$TMP/pc-explicit-if.yml"
if apply_mutation "$PC" "$PC_EXPLICIT_IF" \
  "    # gate for a PR only. The revalidation job below owns the comment event.
    if: github.event_name != 'issue_comment'" \
  "    # gate for a PR only. The revalidation job below owns the comment event.
    if: github.event_name != 'issue_comment'
    ? if
    : true" \
  "an explicit-key duplicate \`if:\` must be constructible"; then
  run_check 2 "an EXPLICIT-KEY duplicate \`if:\` at the job's key indent is CANNOT-VERIFY" PC_FILE="$PC_EXPLICIT_IF"
fi

# (c1f) ⛔ AND AN UNCLASSIFIABLE LINE IS CANNOT-VERIFY, NOT A SILENT DROP. YAML's explicit-key syntax
#       (`? push` / `: value`) is legal; `onKeys` filtered every line KEY_RE did not match, so a trigger
#       written that way was invisible while being effective (measured: effective key set included
#       `push`, gate read green). A gate that drops what it cannot read reports "as decided" about a
#       file it did not fully read — the no-op-gate class, arriving through a filter instead of a
#       return. Both levels are pinned here because both had the filter.
PC_EXPLICIT_ON="$TMP/pc-explicit-on.yml"
if apply_mutation "$PC" "$PC_EXPLICIT_ON" \
  "  issue_comment:
" \
  "  ? push
  :
  issue_comment:
" \
  "an explicit-key trigger must be constructible"; then
  run_check 2 "an EXPLICIT-KEY trigger (\`? push\`) the reader cannot parse is CANNOT-VERIFY" PC_FILE="$PC_EXPLICIT_ON"
fi

PC_EXPLICIT_JOB="$TMP/pc-explicit-job.yml"
if apply_mutation "$PC" "$PC_EXPLICIT_JOB" \
  '          echo "✅ no symlinks under .github/workflows"' \
  '          echo "✅ no symlinks under .github/workflows"

jobs:
  ? pipeline-compliance
  : {if: true}' \
  "an explicit-key job header must be constructible"; then
  run_check 2 "an EXPLICIT-KEY job header (\`? pipeline-compliance\`) is CANNOT-VERIFY" PC_FILE="$PC_EXPLICIT_JOB"
fi

# (c1b2) ⛔ AND THE DUPLICATE MUST BE FOUND FOR EVERY HEADER SPELLING, not just the bare one. The
#        guard that refuses a duplicate job id located the header with a list of spellings, so
#        `  pipeline-compliance :` (space before the colon), `  pipeline-compliance: &anchor` and
#        `  pipeline-compliance: {name: x}` matched the block TERMINATOR but not the start rule —
#        `starts` saw one header, the duplicate guard was skipped, and the reader answered about the
#        FIRST (guarded) block while YAML's effective job was the LAST, with `if: true` or no `if:` at
#        all. Measured: rc=0 over an effective `if` of `True`, one character from the spelling the arm
#        above already covers. Both ends now derive from the indent SHAPE and the key NAME.
PC_DUP_JOB_SPACE="$TMP/pc-dup-job-space.yml"
if apply_mutation "$PC" "$PC_DUP_JOB_SPACE" \
  '          echo "✅ no symlinks under .github/workflows"' \
  '          echo "✅ no symlinks under .github/workflows"

  pipeline-compliance :
    if: true' \
  "a duplicate job id with a space before the colon must be constructible"; then
  run_check 2 "a duplicate job id spelled \`pipeline-compliance :\` is CANNOT-VERIFY too" PC_FILE="$PC_DUP_JOB_SPACE"
fi

# (c1c2) ⛔ AND THE DUPLICATE `on:` MUST BE FOUND FOR `on :` TOO — the same key in YAML, one space
#        away from the spelling the arm below covers. `/^(?:"on"|'on'|on):/` demanded the colon abut the
#        name, so `on :` carrying `push:` was invisible and the 7f pin read green (measured: effective
#        key set `['push']`). The name is now parsed with KEY_RE's `[ \t]*:` tolerance rather than
#        matched against a list — the same repair the job-header rule needed.
PC_DUP_ON_SPACE="$TMP/pc-dup-on-space.yml"
if apply_mutation "$PC" "$PC_DUP_ON_SPACE" \
  '          echo "✅ no symlinks under .github/workflows"' \
  '          echo "✅ no symlinks under .github/workflows"

on :
  push:
    branches: [main]' \
  "a duplicate \`on :\` must be constructible"; then
  run_check 2 "a duplicate top-level \`on :\` (space before the colon) is CANNOT-VERIFY too" PC_FILE="$PC_DUP_ON_SPACE"
fi

# (c1d) ⛔ AND A DUPLICATE TOP-LEVEL `on:` IS THE SAME ROOT, one level up: YAML keeps the LAST, so a
#       second `on:` carrying `push:` left the trigger pin inspecting the FIRST and reporting green
#       (measured rc=0 with the effective key set `['push', 'pull_request']`). A `push:` arm attaches
#       its verdict to main, not to a PR head, so this is the surface the whole 7f pin exists for.
PC_DUP_ON="$TMP/pc-dup-on.yml"
if apply_mutation "$PC" "$PC_DUP_ON" \
  '          echo "✅ no symlinks under .github/workflows"' \
  '          echo "✅ no symlinks under .github/workflows"

on:
  push:
    branches: [main]' \
  "a duplicate top-level \`on:\` must be constructible"; then
  run_check 2 "a DUPLICATE top-level \`on:\` is CANNOT-VERIFY, never green" PC_FILE="$PC_DUP_ON"
fi

# (c1c) …and a WHOLE-SCALAR QUOTED `if:` is the SAME value: quoting the whole expression is how a
#       `!`-leading one is made legal YAML, so refusing it was a false block on a guarded tree
#       (measured rc=1 against PyYAML's identical string).
PC_QUOTED_WHOLE="$TMP/pc-quoted-whole.yml"
if apply_mutation "$PC" "$PC_QUOTED_WHOLE" \
  "    # gate for a PR only. The revalidation job below owns the comment event.
    if: github.event_name != 'issue_comment'" \
  "    # gate for a PR only. The revalidation job below owns the comment event.
    if: \"!cancelled() && github.event_name != 'issue_comment'\"" \
  "a whole-scalar quoted guard must be constructible"; then
  run_check 0 "a WHOLE-SCALAR QUOTED guard (YAML-identical) is ACCEPTED" PC_FILE="$PC_QUOTED_WHOLE"
fi

# (c3) …while `if:` with the guard on the NEXT line is YAML's value being exactly the guard, and must be
#      ACCEPTED. The fold used to prepend a space to an empty first fragment, which the anchored match
#      can never satisfy — a false block on a correctly guarded tree, in the one direction the fold was
#      added to model. A false block is what invites loosening the guard regex, so it is pinned here.
PC_IF_NEXTLINE="$TMP/pc-if-nextline.yml"
if apply_mutation "$PC" "$PC_IF_NEXTLINE" "$PC_GUARD_ANCHOR" \
  "    # gate for a PR only. The revalidation job below owns the comment event.
    if:
      github.event_name != 'issue_comment'" \
  "an \`if:\` with its value on the next line must be constructible"; then
  run_check 0 "an \`if:\` whose guard sits on the NEXT line is ACCEPTED (same folded value)" PC_FILE="$PC_IF_NEXTLINE"
fi

# (d) The required job's OWN header carrying a trailing comment (or a quoted name) must NOT be read as
#     "the guard is missing": that was a false block AND a misdiagnosis of a correctly guarded tree.
PC_OWN_HEADER="$TMP/pc-own-header.yml"
if apply_mutation "$PC" "$PC_OWN_HEADER" "  pipeline-compliance:
" \
  "  pipeline-compliance:  # the required context
" \
  "the required job's own header must be commentable"; then
  run_check 0 "a trailing comment on the REQUIRED job's own header does not look like a lost guard" PC_FILE="$PC_OWN_HEADER"
fi

# (e) `if: >-` is a block scalar this reader does NOT model — and it is the shortest path from a false
#     block back to a fail-open, because a `>-` body of `guard` + `|| true` folds to TRUE. Both are
#     REFUSED, so "add `>-` support" cannot be made to pass without meeting this arm.
#     ⛔ These two are REGRESSION PINS, not a fixed bug: both read rc=1 before this section existed too
#     (the shape simply failed the regex). They are here to keep the documented residual ENFORCED,
#     because the natural next change is to teach the reader `>-` — and a `>-` reader that folds
#     before it checks the operator is exactly the fail-open arms (a)/(c) guard against.
PC_BLOCK_SCALAR="$TMP/pc-block-scalar.yml"
if apply_mutation "$PC" "$PC_BLOCK_SCALAR" "$PC_GUARD_ANCHOR" \
  "    # gate for a PR only. The revalidation job below owns the comment event.
    if: >-
      github.event_name != 'issue_comment'" \
  "a \`>-\` block-scalar guard must be constructible"; then
  run_check 1 "a guard written as an \`if: >-\` block scalar is REFUSED (not modelled)" PC_FILE="$PC_BLOCK_SCALAR"
fi

PC_BLOCK_SCALAR_OR="$TMP/pc-block-scalar-or.yml"
if apply_mutation "$PC" "$PC_BLOCK_SCALAR_OR" "$PC_GUARD_ANCHOR" \
  "    # gate for a PR only. The revalidation job below owns the comment event.
    if: >-
      github.event_name != 'issue_comment' || true" \
  "a \`>-\` block scalar with \`||\` must be constructible"; then
  run_check 1 "a \`>-\` body carrying \`|| true\` is REFUSED (that body folds to TRUE)" PC_FILE="$PC_BLOCK_SCALAR_OR"
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
