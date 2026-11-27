#!/usr/bin/env bash
# tests/lane-signal-forensics/run.sh — mutation harness for #2932.
#
# The suite (extensions/task-signal-forensics.test.ts) proves the two arms: a
# TERMed lane records its PARENT and its uncommitted work is checkpointed (and that
# the record never claims a sender it cannot observe — the third-process test).
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

# ⛔ A RUN THAT PRINTED NO SUMMARY IS NOT A VERDICT (agent-infra#4250, measured on CI).
# On job 140169171893 mutant A answered `rc=0` with NO `tests:` line while its output carried the
# arm-1 failure. The old code graded that as "mutant A did NOT redden the suite — arm 1's assertions
# are vacuous" and then, on the very next check, reported the arm-1 failure as PRESENT: two verdicts
# that contradict each other, both derived from ONE missing line. Its real cause is that the run was
# cut off before the suite's own summary (the suite imports the mutant extension into its OWN process,
# so a fixture signal can take the runner down mid-run) — an INSTRUMENT failure, not a statement
# about the mutant. So: a summary-less run is re-run ONCE, and if it is still summary-less the arm is
# reported as UNKNOWN/(truncated) and NEVER as "the mutation did not take". A genuinely vacuous
# mutant is unaffected — it prints a full summary with rc=0, twice.
#
# Sets RC and COUNT in THIS shell (not via a subshell) so `bad`/`ok` keep counting the failures.
run_suite_verified() { # <label> -> 0 when a summary exists (RC, COUNT set); 1 when the run was truncated
  local label="$1" attempt
  for attempt in 1 2; do
    RC="$(run_suite "${label}-${attempt}")"
    COUNT="$(assertion_count "${label}-${attempt}")"
    if [ -n "$COUNT" ]; then
      cp "$FIX/${label}-${attempt}.out" "$FIX/$label.out"
      return 0
    fi
    if [ "$attempt" = 1 ]; then
      echo "   ⟳ $label printed NO summary line (rc=$RC) — the run was TRUNCATED, not a verdict; re-running it once"
      sed -n '1,12p' "$FIX/${label}-${attempt}.out" | sed 's/^/      │ /'
    fi
  done
  # The caller's diagnostics read `$FIX/<label>.out` even on this path, so publish the LAST attempt's
  # output there rather than leaving a stale file from an earlier label (or none at all).
  cp "$FIX/${label}-2.out" "$FIX/$label.out" 2>/dev/null || :
  return 1
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
# ⛔ THE `git diff` GUARD COMPARES THE DIFF TO ITSELF, NOT TO `HEAD` (#2934). It used
# to be `git diff --quiet -- <path>`, which asks "does this file differ from HEAD?" —
# a DIFFERENT question from "did this run change it?". On the pre-commit run this
# driver exists for, the extension is legitimately dirty, so the old form reported
# `the tracked extension source was MODIFIED — the mutants escaped the copy` about a
# tree no mutant had touched: a false FAIL that reads as a mutation escape. Snapshot
# the diff and compare it after the run, which answers the actual question.
SRC_DIFF_BEFORE="$(git -C "$ROOT" diff -- "$SRC_EXT")"

# ── baseline ────────────────────────────────────────────────────────────────
if run_suite_verified baseline; then
  echo "   baseline: rc=$RC  tests: ${COUNT/|/ passed, } failed"
  if [ "$RC" = "0" ]; then
    ok "baseline is GREEN (the arms pass on the unmutated source)"
  else
    bad "baseline is RED — a mutant result below would be meaningless"
    sed -n '1,40p' "$FIX/baseline.out"
  fi
  BASE_PASS="${COUNT%%|*}"
  case "$BASE_PASS" in ''|*[!0-9]*) bad "baseline printed no parsable assertion count (got '$COUNT')"; BASE_PASS=0 ;; esac
else
  echo "   baseline: rc=$RC  tests:  (no summary — TRUNCATED)"
  bad "baseline printed NO summary line in 2 attempts (rc=$RC) — the run is TRUNCATED, so the baseline is UNKNOWN, not green"
  sed -n '1,40p' "$FIX/baseline.out"
  BASE_PASS=0
fi

# ── mutant A: the trap is removed ───────────────────────────────────────────
# `process.on(signal, handler)` IS arm 1: without it the victim dies by Node's
# default action, writes no record, and takes no checkpoint. The suite must fail
# on the ARM-1 assertion, not merely somewhere.
echo
echo "── mutant A: signal trap removed"
if mutate 'process.on(signal, handler);' 'void handler; /* MUTANT-A: trap removed */'; then
  if ! run_suite_verified mutantA; then
    # ⛔ TRUNCATED IS ITS OWN VERDICT (#4250). Reporting this as "did NOT redden the suite — arm 1's
    # assertions are vacuous" claimed something about the MUTANT from a run that never finished — and
    # then reported the arm-1 failure as present one line later. Say what was measured.
    echo "   mutantA:  rc=$RC  tests:  (no summary — TRUNCATED)"
    bad "mutant A printed NO summary line in 2 attempts (rc=$RC) — the run was TRUNCATED, so the result is UNKNOWN: NOT a green mutant, and NOT evidence that arm 1's assertions are vacuous"
    sed -n '1,20p' "$FIX/mutantA.out"
  else
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
  if ! run_suite_verified mutantB; then
    echo "   mutantB:  rc=$RC  tests:  (no summary — TRUNCATED)"
    bad "mutant B printed NO summary line in 2 attempts (rc=$RC) — the run was TRUNCATED, so the result is UNKNOWN: NOT a green mutant"
    sed -n '1,20p' "$FIX/mutantB.out"
  else
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
if [ "$(git -C "$ROOT" diff -- "$SRC_EXT")" = "$SRC_DIFF_BEFORE" ]; then
  ok "the tracked extension's diff is unchanged by the run (a dirty pre-commit tree included)"
else
  bad "the tracked extension source was MODIFIED BY THIS RUN — the mutants escaped the copy"
fi

# ── the TRUNCATED guard is TESTED, not merely measured (#4250, review F4) ──
# `run_suite_verified` above is this driver's own confidence limit: a run that prints no
# `tests:` summary is re-run ONCE and then graded UNKNOWN/(truncated) — never "the mutation did
# not take". NOTHING here could fail if that guard were reverted to the old single-`run_suite`
# form, and the suite would go green again on the exact CI shape that produced two contradictory
# verdicts (job 140169171893). So this arm re-runs THIS driver with a `TSX_RUNNER` stub that
# reproduces that shape — an arm failure PRINTED, the process cut off before any summary, exit 0 —
# and asserts the composed verdict from the OUTSIDE: TRUNCATED is stated, the retry is taken
# exactly once per label, and the two false verdicts are absent (a summary-less baseline read as
# GREEN, a summary-less mutant read as "the assertions are vacuous"). The stub needs no tsx, so
# this arm costs a few file copies.
if [ "${LSF_TRUNCATION_GUARD:-}" = "child" ]; then
  # The child's three labels ARE the stub's runs; re-entering this arm would fork forever.
  echo
  echo "── truncation-guard arm skipped: this run IS the truncated child"
else
  echo
  echo "── guard: a summary-less run is TRUNCATED, not a green mutant (#4250)"
  TRUNC_STUB="$FIX/truncating-runner.sh"
  cat >"$TRUNC_STUB" <<'STUB'
#!/usr/bin/env bash
# CI's measured shape (job 140169171893): arms print, arm 1's failure is PRINTED, and the process
# is cut off before the suite's own `tests: N passed, M failed` summary. Exit 0 is what made the
# old code read this as "the mutant did not redden the suite".
printf '  ✅ arm 1: the lane records its parent\n'
printf '  ❌ arm 1: the signal log has exactly one record\n'
exit 0
STUB
  chmod +x "$TRUNC_STUB"
  GUARD_OUT="$FIX/truncation-guard.out"
  LSF_TRUNCATION_GUARD=child TSX_RUNNER="$TRUNC_STUB" \
      bash "$ROOT/tests/lane-signal-forensics/run.sh" >"$GUARD_OUT" 2>&1
  GUARD_RC=$?
  if [ "$GUARD_RC" -ne 0 ]; then
    ok "the driver does not PASS a summary-less run (exit $GUARD_RC)"
  else
    bad "the driver reported PASS on a summary-less run (exit 0) — a truncated run is UNPROVEN, never green"
    sed -n '1,40p' "$GUARD_OUT"
  fi
  if grep -q 'TRUNCATED' "$GUARD_OUT"; then
    ok "the summary-less run is graded TRUNCATED/UNKNOWN, in its own words"
  else
    bad "the summary-less run was never called TRUNCATED — the guard is gone"
    grep -E '^\s+(✅|❌)' "$GUARD_OUT" | head -20
  fi
  # The pre-fix verdict IS this string: "baseline is GREEN" was printed from a run that never
  # emitted a summary — the false PASS the guard exists to refuse.
  if grep -q 'baseline is GREEN' "$GUARD_OUT"; then
    bad "a summary-less BASELINE was reported GREEN — a pass verdict from a run that never finished"
  else
    ok "a summary-less baseline is NOT reported green"
  fi
  # …and this one is the CONTRADICTION: "did NOT redden the suite" is a claim about the MUTANT,
  # derived from a run that never finished, printed beside the arm-1 failure it denies.
  if grep -q 'did NOT redden the suite' "$GUARD_OUT"; then
    bad "a summary-less MUTANT was called 'did NOT redden the suite' — a claim about a mutant from an unfinished run"
  else
    ok "a summary-less mutant is never called 'did NOT redden' (no claim about an unfinished run)"
  fi
  # The retry notice is the `⟳` line run_suite_verified prints ONLY when it re-runs (its wording,
  # "re-running it once", is not shared with the `bad` verdict lines, which name the attempt count).
  TRUNC_RETRIES="$(grep -c 're-running it once' "$GUARD_OUT" 2>/dev/null || true)"
  if [ "$TRUNC_RETRIES" = "3" ]; then
    ok "each of the three labels was re-run exactly ONCE before its verdict (3 retry notices)"
  else
    bad "expected exactly one retry per label (3 notices), observed '$TRUNC_RETRIES'"
  fi
fi

echo
echo "assertions: baseline ${BASE_PASS} groups green; 2 mutants required red"
if [ "$fails" -gt 0 ]; then
  echo "RESULT: FAIL ($fails)"
  exit 1
fi
echo "RESULT: PASS"
