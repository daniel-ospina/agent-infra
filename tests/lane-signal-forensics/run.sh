#!/usr/bin/env bash
# tests/lane-signal-forensics/run.sh — mutation harness for #2932.
#
# The suite (extensions/task-signal-forensics.test.ts) proves the two arms: a
# TERMed lane records its signaller, and its uncommitted work is checkpointed.
# A green suite proves nothing about whether an ASSERTION could ever fail, so this
# driver removes each arm's mechanism and requires the suite to redden on the
# assertion that names it.
#
# ⛔ NOTHING TRACKED IS MODIFIED. The extension and its suite are copied into a
#     temp dir first, and the mutant is applied to the COPY. The copy is what the
#     suite imports (`./task-signal-forensics.js` from its own directory) and what
#     it spawns as the lane, so the mutant is the only difference between the
#     baseline run and the mutant run. A driver that patched the working tree
#     would leave a half-applied mutation behind on any interrupted run.
#
# Each arm reports: the assertion count before (baseline), the mutant's exit
# status, and the exact failing assertion.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

SRC_EXT="$ROOT/extensions/task-signal-forensics.ts"
SRC_TEST="$ROOT/extensions/task-signal-forensics.test.ts"
TSX="${TSX_RUNNER:-npx --yes tsx}"

fails=0
ok()  { echo "   ✅ $1"; }
bad() { echo "   ❌ $1"; fails=$((fails + 1)); }

[ -f "$SRC_EXT" ]  || { echo "   ❌ missing $SRC_EXT"; exit 1; }
[ -f "$SRC_TEST" ] || { echo "   ❌ missing $SRC_TEST"; exit 1; }

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/ext"
cp "$SRC_EXT" "$FIX/ext/task-signal-forensics.ts"
cp "$SRC_TEST" "$FIX/ext/task-signal-forensics.test.ts"

# The extension imports the repo's SHARED redaction seam (`./shared/redact-command.js`)
# so that its parent-argv record cannot drift from the two other command-recording
# sinks (#966). The fixture must reproduce that import graph: a copy containing only
# the extension would make the BASELINE fail to resolve a module, and a mutation
# driver whose baseline is red proves nothing. Only the ONE shared module the
# extension actually imports is copied — a blanket copy of `extensions/shared/`
# would drag in ~20 unrelated modules and their own suites.
SHARED_REDACT="$ROOT/extensions/shared/redact-command.ts"
[ -f "$SHARED_REDACT" ] || { echo "   ❌ missing $SHARED_REDACT (the extension imports it)"; exit 1; }
mkdir -p "$FIX/ext/shared"
cp "$SHARED_REDACT" "$FIX/ext/shared/redact-command.ts"

run_suite() { # run_suite <label> -> writes $FIX/<label>.out, echoes the exit status
  local label="$1" rc
  ( cd "$ROOT" && $TSX "$FIX/ext/task-signal-forensics.test.ts" ) >"$FIX/$label.out" 2>&1
  rc=$?
  printf '%s' "$rc"
}

assertion_count() { # assertion_count <label> -> "N passed, M failed" from the suite's own summary
  sed -n 's/^tests: \([0-9]*\) passed, \([0-9]*\) failed$/\1|\2/p' "$FIX/$1.out" | tail -1
}

# mutate <old> <new> — applies ONE exact replacement to the copied extension and
# refuses if the anchor is not present exactly once (a mutant that cannot locate
# its target would silently test nothing).
mutate() {
  node -e '
    const fs = require("node:fs");
    const [file, oldText, newText] = process.argv.slice(1);
    const src = fs.readFileSync(file, "utf8");
    const parts = src.split(oldText);
    if (parts.length !== 2) {
      console.error(`anchor matched ${parts.length - 1} time(s), expected exactly 1: ${JSON.stringify(oldText)}`);
      process.exit(3);
    }
    fs.writeFileSync(file, parts.join(newText));
  ' "$FIX/ext/task-signal-forensics.ts" "$1" "$2"
}

echo "== lane-signal-forensics mutation harness (#2932) =="

# Content guard, taken BEFORE anything runs. `git diff` alone cannot defend this:
# the extension may be UNTRACKED on a pre-commit run, and `git diff --quiet --
# <path>` ignores an untracked path — so a mutant that escaped the copy would be
# invisible to it exactly when the driver is most likely to be run by hand. The
# hash works tracked or not; the `git diff` check below still covers the tracked
# case from the other direction.
SRC_HASH_BEFORE="$(shasum -a 256 "$SRC_EXT" | awk '{print $1}')"

# ── baseline ────────────────────────────────────────────────────────────────
RC="$(run_suite baseline)"
COUNT="$(assertion_count baseline)"
echo "   baseline: rc=$RC  tests: ${COUNT/|/ passed, } failed"
if [ "$RC" = "0" ]; then
  ok "baseline is GREEN (the arms pass on the unmutated source)"
else
  bad "baseline is RED — a mutant result below would be meaningless"
  sed -n '1,40p' "$FIX/baseline.out"
fi
BASE_PASS="${COUNT%%|*}"
case "$BASE_PASS" in ''|*[!0-9]*) bad "baseline printed no parsable assertion count (got '$COUNT')"; BASE_PASS=0 ;; esac

# ── mutant A: the trap is removed ───────────────────────────────────────────
# `process.on(signal, handler)` IS arm 1: without it the victim dies by Node's
# default action, writes no record, and takes no checkpoint. The suite must fail
# on the ARM-1 assertion, not merely somewhere.
echo
echo "── mutant A: signal trap removed"
if mutate 'process.on(signal, handler);' 'void handler; /* MUTANT-A: trap removed */'; then
  RC="$(run_suite mutantA)"
  COUNT="$(assertion_count mutantA)"
  echo "   mutantA:  rc=$RC  tests: ${COUNT/|/ passed, } failed"
  if [ "$RC" != "0" ]; then
    ok "mutant A reddens the suite (exit $RC)"
  else
    bad "mutant A did NOT redden the suite — arm 1's assertions are vacuous"
  fi
  if grep -q 'arm 1: the signal log has exactly one record' "$FIX/mutantA.out"; then
    ok "mutant A's failing assertion is the arm-1 one: 'arm 1: the signal log has exactly one record'"
  else
    bad "mutant A did not fail on the arm-1 assertion (it must fail THERE, not elsewhere)"
    grep -E '^\s+(❌|✅)' "$FIX/mutantA.out" | head -20
  fi
  # Non-vacuity: the mutant must have removed exactly one arm — the mutant run's
  # passing count is strictly lower than the baseline's, and at least one test
  # still passed (so the suite ran rather than crashing on load).
  MUT_PASS="${COUNT%%|*}"
  case "$MUT_PASS" in ''|*[!0-9]*) MUT_PASS=0 ;; esac
  if [ "$MUT_PASS" -gt 0 ] && [ "$MUT_PASS" -lt "$BASE_PASS" ]; then
    ok "mutant A removed $((BASE_PASS - MUT_PASS)) passing assertion group(s) and the suite still ran"
  else
    bad "mutant A's pass count ($MUT_PASS) is not strictly between 0 and the baseline ($BASE_PASS) — the suite crashed or nothing changed"
  fi
else
  bad "mutant A could not be applied (anchor not unique) — the mutation was not exercised"
fi

# ── mutant B: the checkpoint arm cannot run ─────────────────────────────────
# Restore a clean copy, then disable exactly the checkpoint call, leaving arm 1
# intact. The suite must now fail on the ARM-2 assertion while arm 1 still passes
# — that is the proof the two arms are independent and each is load-bearing.
echo
echo "── mutant B: checkpoint arm disabled"
cp "$SRC_EXT" "$FIX/ext/task-signal-forensics.ts"
if mutate 'checkpoint = doCheckpoint ? snapshot() :' 'checkpoint = false ? snapshot() :'; then
  RC="$(run_suite mutantB)"
  COUNT="$(assertion_count mutantB)"
  echo "   mutantB:  rc=$RC  tests: ${COUNT/|/ passed, } failed"
  if [ "$RC" != "0" ]; then
    ok "mutant B reddens the suite (exit $RC)"
  else
    bad "mutant B did NOT redden the suite — arm 2's assertions are vacuous"
  fi
  if grep -q 'arm 2: the checkpoint was SAVED' "$FIX/mutantB.out"; then
    ok "mutant B's failing assertion is the arm-2 one: 'arm 2: the checkpoint was SAVED'"
  else
    bad "mutant B did not fail on the arm-2 assertion"
    grep -E '^\s+(❌|✅)' "$FIX/mutantB.out" | head -20
  fi
  if grep -q 'arm 1: the signal log has exactly one record' "$FIX/mutantB.out"; then
    bad "mutant B also broke arm 1 — the arms are not independent, so neither mutant isolates a mechanism"
  else
    ok "mutant B left arm 1 green (the two arms are independently load-bearing)"
  fi
else
  bad "mutant B could not be applied (anchor not unique) — the mutation was not exercised"
fi

# ── the working tree must be exactly as we found it ─────────────────────────
echo
SRC_HASH_AFTER="$(shasum -a 256 "$SRC_EXT" | awk '{print $1}')"
if [ "$SRC_HASH_BEFORE" = "$SRC_HASH_AFTER" ]; then
  ok "the extension source is byte-identical to what we started with ($SRC_HASH_AFTER)"
else
  bad "the extension source CHANGED during the run ($SRC_HASH_BEFORE -> $SRC_HASH_AFTER) — a mutant escaped the copy"
fi
if git -C "$ROOT" diff --quiet -- "$SRC_EXT"; then
  ok "the tracked extension source is unmodified (mutants live only in the temp copy)"
else
  bad "the tracked extension source was MODIFIED — the mutants escaped the copy"
fi

echo
echo "assertions: baseline ${BASE_PASS} groups green; 2 mutants required red"
if [ "$fails" -gt 0 ]; then
  echo "RESULT: FAIL ($fails)"
  exit 1
fi
echo "RESULT: PASS"
