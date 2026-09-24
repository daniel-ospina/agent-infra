#!/bin/bash
# tests/ci-lane-parity/run.sh — #1369 regression suite for scripts/check-ci-lane-parity.sh
# and the one-runner design it asserts.
#
# THE DEFECT (why this exists)
# ----------------------------
#   `.github/workflows/ci.yml` (PR lane) and `.github/workflows/ci-main.yml` (main lane) both
#   presented a check called "script-validate" over two different bodies of work: the PR lane
#   ran `node --check` only, main ran the bash `-n` sweeps + fourteen hermetic suites.
#   scripts/record-review.test.sh exited 127 on the ubuntu runner (its PATH-shim vector) and
#   shipped a RED MAIN behind a GREEN PR (#1348 → #1369).
#
# THE DESIGN THIS SUITE PINS
#   The first repair duplicated the shard list into both workflows and compared them. Two
#   independent reviews then walked through every text form that reads as coverage WITHOUT
#   executing — a shard named in a heredoc body, in a job-level `env:` value, after `true ||`,
#   on a `for f in a.sh …` continuation line, or invoked as `env bash x.sh`. Comparing two
#   hand-kept lists cannot be made sound, so the list now exists ONCE
#   (`scripts/run-bash-shards.sh`) and BOTH lanes call it: drift between lanes is impossible
#   by construction. The guard asserts the narrow residue.
#
# WHAT THIS SUITE PINS
# --------------------
#   0. LIVE — the guard passes; BOTH lanes' call sites are present; and the runner's list
#      demonstrably CONTAINS the motivating suite (scripts/record-review.test.sh) — the
#      incident class is covered by the shared list, not by a comment.
#   1. PR lane drops its call  → rc 1 (the split direction that caused #1348).
#   2. main lane drops its call → rc 1 (the opposite direction).
#   3. HEREDOC FAKING — the call present ONLY inside a heredoc body → rc 1. (This is the
#      fail-open an earlier draft had; the runner is text until it executes.)
#   4. COMMENT FAKING — the call present only as a comment → rc 1.
#   5. A GUTTED RUNNER (no shard lines) → rc 2, never a vacuous "both lanes agree".
#   6. A RUNNER WITH NO SWEEPS → rc 2 (the shell-syntax half would be uncovered in both lanes).
#   7. A CONDITIONAL PR JOB carrying the call → rc 2 (a job that may never run is not coverage).
#   8. AN UNREADABLE RUNNER → rc 2 (fail-closed, not "parity").
#   9. CLI contract — `--help` → 0, an unknown argument → 2.
#  10. WIRING — the guard AND the runner are invoked in both lanes; a guard nothing runs is a
#      no-op gate.
#  11. THE RUNNER'S OWN CONTRACT — `--list` prints the shard list (the same source the guard's
#      floor reads), and it is long enough to be a real list.
#
# NOTE ON STYLE: runs inside a command substitution are written as `cmd >file` + `cat file`,
# never `OUT="$(… bash …)"` — the main-worktree-guard content walker (#1484) refuses to execute
# a script that wraps a shell invocation in a command substitution, reporting it as an
# unsanctioned git operation even with zero git in the file. Evidence: issue #1122.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARD="$ROOT/scripts/check-ci-lane-parity.sh"
RUNNER="$ROOT/scripts/run-bash-shards.sh"
MAIN="$ROOT/.github/workflows/ci-main.yml"
PR="$ROOT/.github/workflows/ci.yml"
# The runner fixtures execute shard paths RELATIVE to the caller, so the suite must run from the
# checkout root (CI does; an interactive run from elsewhere would see spurious failures).
cd "$ROOT" || exit 1

checks=0
failures=0
pass() { checks=$((checks + 1)); echo "   ✅ $1"; }
fail() { checks=$((checks + 1)); echo "   ❌ $1"; failures=$((failures + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A FAST copy of the runner (long shards dropped) for the runtime-mutation pins: they must
# exercise the runner's own self-checks, not spend ten minutes running the real suites.
grep -v -e 'pi-reap-idle' -e 'pi-task-session-prune' -e 'pi-reap-worktrees' -e 'install-launchd' \
  -e 'test-setup-no-nesting' -e 'scratch-worktree' -e 'tests/admin-merge' -e 'tests/atomic-land' \
  -e 'tests/gh-shim' -e 'tests/search-cost' "$RUNNER" >"$TMP/runner-fast.sh"

OUT=""
RC=0
# guard_rc <main-workflow> <pr-workflow> [runner-file] — sets RC and OUT. The runner FILE is
# separate from the call-site TEXT so a mutated copy can be read without changing what the
# lanes are compared against.
guard_rc() {
  CI_LANE_MAIN_WORKFLOW="$1" CI_LANE_PR_WORKFLOW="$2" CI_LANE_RUNNER_FILE="${3:-$RUNNER}" \
    bash "$GUARD" >"$TMP/guard.out" 2>&1
  RC=$?
  OUT="$(cat "$TMP/guard.out")"
}

if [ ! -r "$GUARD" ] || [ ! -r "$RUNNER" ] || [ ! -r "$MAIN" ] || [ ! -r "$PR" ]; then
  echo "❌ ci-lane-parity: cannot find the guard, the runner, or a workflow — refusing to report on a suite that did not run"
  exit 2
fi

echo ""
echo "0. LIVE — the real repo is at parity, and the runner covers the incident suite"
guard_rc "$MAIN" "$PR"
if [ "$RC" -eq 0 ]; then
  pass "guard PASSES on the real repo (rc 0): $(printf '%s' "$OUT" | tail -1)"
else
  fail "guard FAILED on the real repo (rc $RC): $OUT"
fi
for pair in "PR:$PR" "main:$MAIN"; do
  lane="${pair%%:*}"; wf="${pair#*:}"
  if grep -qE '^[[:space:]]*(run:[[:space:]]+)?bash[[:space:]]+scripts/run-bash-shards\.sh' "$wf"; then
    pass "the $lane lane calls the shared runner"
  else
    fail "the $lane lane does NOT call the shared runner"
  fi
done
if grep -qE '^run_shard scripts/record-review\.test\.sh' "$RUNNER"; then
  pass "the shared runner runs scripts/record-review.test.sh (the #1348 incident suite)"
else
  fail "the shared runner does NOT run scripts/record-review.test.sh — the incident class is open"
fi

echo ""
echo "1. PR lane drops its call → rc 1"
grep -v 'run: bash scripts/run-bash-shards.sh' "$PR" >"$TMP/ci-pr-drop.yml"
if cmp -s "$PR" "$TMP/ci-pr-drop.yml"; then
  fail "the PR-drop mutation did not change the file"
else
  guard_rc "$MAIN" "$TMP/ci-pr-drop.yml"
  if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'PR lane'; then
    pass "the guard FAILS (rc 1) and names the PR lane when its call is gone"
  else
    fail "guard returned rc $RC (want 1, naming the PR lane): $OUT"
  fi
fi

echo ""
echo "2. main lane drops its call → rc 1"
grep -v 'bash scripts/run-bash-shards.sh' "$MAIN" >"$TMP/ci-main-drop.yml"
if cmp -s "$MAIN" "$TMP/ci-main-drop.yml"; then
  fail "the main-drop mutation did not change the file"
else
  guard_rc "$TMP/ci-main-drop.yml" "$PR"
  if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'main lane'; then
    pass "the guard FAILS (rc 1) and names the main lane when its call is gone"
  else
    fail "guard returned rc $RC (want 1, naming the main lane): $OUT"
  fi
fi

echo ""
echo "3. HEREDOC FAKING — the call inside a heredoc body is TEXT, not coverage"
awk '{
  if ($0 ~ /^        run: bash scripts\/run-bash-shards\.sh$/) {
    print "        run: |"
    print "          cat <<'"'"'EOF'"'"'"
    print "          bash scripts/run-bash-shards.sh"
    print "          EOF"
    next
  }
  print
}' "$PR" >"$TMP/ci-pr-heredoc.yml"
if cmp -s "$PR" "$TMP/ci-pr-heredoc.yml"; then
  fail "the heredoc mutation did not change the file"
else
  guard_rc "$MAIN" "$TMP/ci-pr-heredoc.yml"
  if [ "$RC" -eq 2 ]; then
    pass "a heredoc body naming the runner is REFUSED (the call must be its own step value)"
  else
    fail "a heredoc body naming the runner was not refused (rc $RC — want 2): $OUT"
  fi
fi

echo ""
echo "4. COMMENT FAKING — a commented-out call is prose"
sed 's|^        run: bash scripts/run-bash-shards\.sh$|        # run: bash scripts/run-bash-shards.sh|' \
  "$PR" >"$TMP/ci-pr-comment.yml"
if cmp -s "$PR" "$TMP/ci-pr-comment.yml"; then
  fail "the comment mutation did not change the file"
else
  guard_rc "$MAIN" "$TMP/ci-pr-comment.yml"
  if [ "$RC" -eq 1 ]; then
    pass "a COMMENTED-OUT call does not satisfy the guard (rc 1)"
  else
    fail "a commented-out call satisfied the guard (rc $RC — want 1): $OUT"
  fi
fi

echo ""
echo "5. A GUTTED RUNNER (0 shard lines) → rc 2, never a vacuous 'both lanes agree'"
grep -v '^run_shard ' "$RUNNER" >"$TMP/runner-gutted.sh"
if cmp -s "$RUNNER" "$TMP/runner-gutted.sh"; then
  fail "the gutted-runner mutation did not change the file"
else
  guard_rc "$MAIN" "$PR" "$TMP/runner-gutted.sh"
  if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'shard(s) (floor'; then
    pass "a gutted runner exits 2 and names the floor (rc 2)"
  else
    fail "a gutted runner returned rc $RC (want 2, naming the floor): $OUT"
  fi
fi

echo ""
echo "6. A RUNNER WITH NO SWEEPS (0 syntax targets) → rc 2"
# The sweep half is DATA now (SWEEP_GLOBS) plus the loops that iterate it, and the guard reads the
# list from the runner's own `--list-sweeps`. So the mutation must remove the LIST; deleting only
# the loops leaves the list advertising globs nothing iterates, which the guard cannot see and the
# RUNNER's `swept` sentinel catches at runtime (pinned by 8q below).
grep -v -e 'for f in' -e 'SWEEP_GLOBS' "$RUNNER" >"$TMP/runner-nosweep.sh"
if cmp -s "$RUNNER" "$TMP/runner-nosweep.sh"; then
  fail "the no-sweep mutation did not change the file"
else
  guard_rc "$MAIN" "$PR" "$TMP/runner-nosweep.sh"
  if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'syntax target'; then
    pass "a runner with no sweeps exits 2 — the syntax half cannot go uncovered in silence"
  else
    fail "a runner with no sweeps returned rc $RC (want 2, naming the sweeps): $OUT"
  fi
fi

# A runner that keeps its sweeps but loses every suite must ALSO exit 2 — the two floors are
# independent, so a mutation that satisfies one must not carry the other.
echo ""
echo "6b. FLOOR INDEPENDENCE — sweeps intact but no shards still exits 2"
grep -v '^run_shard ' "$RUNNER" >"$TMP/runner-noshards-but-sweeps.sh"
guard_rc "$MAIN" "$PR" "$TMP/runner-noshards-but-sweeps.sh"
if [ "$RC" -eq 2 ]; then
  pass "the shard floor fires even while the sweep floor is satisfied (rc 2)"
else
  fail "a shardless runner with sweeps returned rc $RC (want 2): $OUT"
fi

echo ""
echo "7. A CONDITIONAL PR JOB carrying the call → rc 2"
awk '{
  if ($0 ~ /^      - name: Bash shards/) { print "        if: false" }
  print
}' "$PR" >"$TMP/ci-pr-conditional.yml"
if cmp -s "$PR" "$TMP/ci-pr-conditional.yml"; then
  fail "the conditional mutation did not change the file"
else
  guard_rc "$MAIN" "$TMP/ci-pr-conditional.yml"
  if [ "$RC" -eq 2 ]; then
    pass "a conditional job carrying the call exits 2 (unprovable, not parity)"
  else
    fail "a conditional call returned rc $RC (want 2): $OUT"
  fi
fi

echo ""
echo "8. AN UNREADABLE RUNNER → rc 2"
guard_rc "$MAIN" "$PR" "$TMP/does-not-exist-runner.sh"
if [ "$RC" -eq 2 ]; then
  pass "an unreadable runner exits 2 (fail-closed)"
else
  fail "an unreadable runner returned rc $RC (want 2): $OUT"
fi

echo ""
echo "8f. SPELLING VARIANTS of the refusal keys (quoted / spaced / flow) → rc 2"
for spec in '    "if": false' '    if : false' '    "continue-on-error": true' '    needs : [ci]' "    'needs': [ci]"; do
  awk -v line="$spec" '{ if ($0 ~ /^  bash-suites:$/) { print; print line; next } print }' \
    "$PR" >"$TMP/ci-pr-spell.yml"
  guard_rc "$MAIN" "$TMP/ci-pr-spell.yml"
  if [ "$RC" -eq 2 ]; then
    pass "refused a spelled variant: $spec"
  else
    fail "a spelled variant escaped the guard (rc $RC — want 2): $spec"
  fi
done

echo ""
echo "8g. shell: OVERRIDE on the call-carrying job → rc 2 (the step would not run the file)"
awk '{ if ($0 ~ /^  bash-suites:$/) { print; print "    shell: true {0}"; next } print }' \
  "$PR" >"$TMP/ci-pr-shell.yml"
if cmp -s "$PR" "$TMP/ci-pr-shell.yml"; then
  fail "the shell-override mutation did not change the file"
else
  guard_rc "$MAIN" "$TMP/ci-pr-shell.yml"
  if [ "$RC" -eq 2 ]; then
    pass "a shell: override on the call-carrying job exits 2"
  else
    fail "a shell: override returned rc $RC (want 2): $OUT"
  fi
fi

# The shipped job must not trip that arm itself: `shell: bash` would be a false block.
awk '{ if ($0 ~ /^  bash-suites:$/) { print; print "    shell: bash"; next } print }' \
  "$PR" >"$TMP/ci-pr-shell-bash.yml"
guard_rc "$MAIN" "$TMP/ci-pr-shell-bash.yml"
if [ "$RC" -eq 0 ]; then
  pass "an explicit 'shell: bash' is NOT a false block (rc 0)"
else
  fail "'shell: bash' was refused (rc $RC): $OUT"
fi

echo ""
echo "8h. FAILURE-RECORDING ARM — dropping it must make the RUNNER fail at runtime"
sed 's/ || shard_errors=$((shard_errors + 1))//' "$TMP/runner-fast.sh" >"$TMP/runner-norecord.sh"
if cmp -s "$TMP/runner-fast.sh" "$TMP/runner-norecord.sh"; then
  fail "the no-record mutation did not change the file"
else
  bash "$TMP/runner-norecord.sh" >"$TMP/runner-norecord.out" 2>&1
  RC=$?
  OUT="$(cat "$TMP/runner-norecord.out")"
  if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qE '(failure-recording|sweep) arm is broken'; then
    pass "a runner that cannot record failures FAILS its own sentinel (rc 1)"
  else
    fail "a runner with no failure-recording arm returned rc $RC (want 1): $OUT"
  fi
fi

echo ""
echo "8i. QUOTED run: VALUE is read, not a false block"
awk '{ if ($0 ~ /^        run: bash scripts\/run-bash-shards\.sh$/) { print "        run: \"bash scripts/run-bash-shards.sh\""; next } print }' \
  "$PR" >"$TMP/ci-pr-quoted-run.yml"
if cmp -s "$PR" "$TMP/ci-pr-quoted-run.yml"; then
  fail "the quoted-run mutation did not change the file"
else
  guard_rc "$MAIN" "$TMP/ci-pr-quoted-run.yml"
  if [ "$RC" -eq 0 ]; then
    pass "a quoted run: value is accepted (no false block on valid YAML)"
  else
    fail "a quoted run: value was refused (rc $RC): $OUT"
  fi
fi

echo ""
echo "8b. YAML env: BLOCK SCALAR naming the runner is TEXT (only run: steps are read)"
awk '{
  if ($0 ~ /^        run: bash scripts\/run-bash-shards\.sh$/) { print "        run: echo runner-disabled"; next }
  if ($0 ~ /^  bash-suites:$/) {
    print
    print "    env:"
    print "      DISABLED_RUNNER: |"
    print "        bash scripts/run-bash-shards.sh"
    next
  }
  print
}' "$PR" >"$TMP/ci-pr-envblk.yml"
if cmp -s "$PR" "$TMP/ci-pr-envblk.yml"; then
  fail "the env-block-scalar mutation did not change the file"
else
  guard_rc "$MAIN" "$TMP/ci-pr-envblk.yml"
  if [ "$RC" -eq 1 ]; then
    pass "an env: block scalar naming the runner does NOT satisfy the guard (rc 1)"
  else
    fail "an env: block scalar satisfied the guard (rc $RC — want 1): $OUT"
  fi
fi

echo ""
echo "8c. continue-on-error: — a failing bash body must fail the RUN, not just the job"
awk '{ if ($0 ~ /^  bash-suites:$/) { print; print "    continue-on-error: true"; next } print }' \
  "$PR" >"$TMP/ci-pr-coe.yml"
if cmp -s "$PR" "$TMP/ci-pr-coe.yml"; then
  fail "the continue-on-error mutation did not change the file"
else
  guard_rc "$MAIN" "$TMP/ci-pr-coe.yml"
  if [ "$RC" -eq 2 ]; then
    pass "continue-on-error on the call-carrying job exits 2 (a green check over a red body)"
  else
    fail "continue-on-error returned rc $RC (want 2): $OUT"
  fi
fi

echo ""
echo "8d. RUNTIME SELF-CHECK — a neutered runner helper must fail, not report success"
# Neutering means replacing the WHOLE helper (the verifier's repro): the counter goes with the
# execution, so the runner can no longer claim it ran anything.
awk '{ if ($0 ~ /^run_shard\(\) \{/) { print "run_shard() { :; }"; next } print }' \
  "$TMP/runner-fast.sh" >"$TMP/runner-neutered.sh"
if cmp -s "$TMP/runner-fast.sh" "$TMP/runner-neutered.sh"; then
  fail "the neutered-helper mutation did not change the file"
else
  bash "$TMP/runner-neutered.sh" >"$TMP/runner-neutered.out" 2>&1
  RC=$?
  OUT="$(cat "$TMP/runner-neutered.out")"
  if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'executed 0 of'; then
    pass "a runner whose helper executes nothing FAILS at runtime (rc 1, count mismatch)"
  else
    fail "a neutered helper returned rc $RC (want 1): $OUT"
  fi
  # and the un-mutated runner must agree with its own list
  bash "$RUNNER" --list >"$TMP/selfcheck-list.txt" 2>&1
  if [ "$(grep -c . "$TMP/selfcheck-list.txt")" -ge 14 ]; then
    pass "the shipped runner lists its shards (so the runtime count cannot be satisfied trivially)"
  else
    fail "the shipped runner listed too few shards"
  fi
fi

echo ""
echo "8e. COUNTER-PRESERVING SABOTAGE is now CAUGHT by the failure-recording sentinel"
# Earlier revisions could not catch this (the count stayed correct while failures stopped being
# recorded); the sentinel self-check in the runner closes it, so it is no longer a residual.
awk '{ if ($0 ~ /^run_shard\(\) \{/) { print "run_shard() { shard_ran=$((shard_ran + 1)); }"; next } print }' \
  "$TMP/runner-fast.sh" >"$TMP/runner-counter-only.sh"
bash "$TMP/runner-counter-only.sh" >"$TMP/runner-counter-only.out" 2>&1
RC=$?
OUT="$(cat "$TMP/runner-counter-only.out")"
if [ "$RC" -eq 1 ]; then
  pass "dropping the failure-recording arm without touching the counter FAILS (rc 1)"
else
  fail "the counter-preserving sabotage returned rc $RC (want 1): $OUT"
fi

echo ""
echo "8j. A FLAG AT THE CALL SITE → rc 2 (--list runs no shard)"
awk '{ if ($0 ~ /^        run: bash scripts\/run-bash-shards\.sh$/) { print "        run: bash scripts/run-bash-shards.sh --list"; next } print }' \
  "$PR" >"$TMP/ci-pr-flag.yml"
if cmp -s "$PR" "$TMP/ci-pr-flag.yml"; then
  fail "the flag mutation did not change the file"
else
  guard_rc "$MAIN" "$TMP/ci-pr-flag.yml"
  if [ "$RC" -eq 2 ]; then
    pass "a call carrying --list exits 2 (it executes no shard)"
  else
    fail "--list at the call site returned rc $RC (want 2): $OUT"
  fi
fi

echo ""
echo "8k. A SWALLOWING TAIL → rc 2 (|| true is the shell spelling of continue-on-error)"
awk '{ if ($0 ~ /^        run: bash scripts\/run-bash-shards\.sh$/) { print "        run: bash scripts/run-bash-shards.sh || true"; next } print }' \
  "$PR" >"$TMP/ci-pr-swallow.yml"
if cmp -s "$PR" "$TMP/ci-pr-swallow.yml"; then
  fail "the swallowing mutation did not change the file"
else
  guard_rc "$MAIN" "$TMP/ci-pr-swallow.yml"
  if [ "$RC" -eq 2 ]; then
    pass "'|| true' at the call site exits 2 (a failing shard could not fail the run)"
  else
    fail "'|| true' returned rc $RC (want 2): $OUT"
  fi
fi

echo ""
echo "8l. A QUOTED PATH at the call site is accepted (no false block)"
awk '{ if ($0 ~ /^        run: bash scripts\/run-bash-shards\.sh$/) { print "        run: bash \"scripts/run-bash-shards.sh\""; next } print }' \
  "$PR" >"$TMP/ci-pr-quotedpath.yml"
if cmp -s "$PR" "$TMP/ci-pr-quotedpath.yml"; then
  fail "the quoted-path mutation did not change the file"
else
  guard_rc "$MAIN" "$TMP/ci-pr-quotedpath.yml"
  if [ "$RC" -eq 0 ]; then
    pass "a quoted call path is accepted (no false block)"
  else
    fail "a quoted call path was refused (rc $RC) — quoting is an equivalent spelling: $OUT"
  fi
fi

echo ""
echo "8m. TRIGGER REMOVED from the PR lane → rc 2 (a lane that never runs covers nothing)"
sed 's|^  pull_request:$|  workflow_dispatch:|' "$PR" >"$TMP/ci-pr-notrigger.yml"
if cmp -s "$PR" "$TMP/ci-pr-notrigger.yml"; then
  fail "the trigger mutation did not change the file"
else
  guard_rc "$MAIN" "$TMP/ci-pr-notrigger.yml"
  if [ "$RC" -eq 2 ]; then
    pass "a PR lane with no pull_request trigger exits 2"
  else
    fail "a trigger-less PR lane returned rc $RC (want 2): $OUT"
  fi
fi

echo ""
echo "8n. SWEEP BODY NEUTERED → the RUNNER must fail at runtime (and pass unneutered)"
# A synthetic cheap shard replaces every listed target so this pair costs ~1s instead of the
# whole suite, while keeping the runner's own self-check arithmetic (listed == executed) intact.
CHEAP="scripts/check-no-sigpipe-grep.sh"
awk -v cheap="$CHEAP" '
  /^run_shard / && $2 !~ /^\"/ { print "run_shard " cheap; next }
  { print }
' "$TMP/runner-fast.sh" >"$TMP/runner-cheap.sh"
awk -v cheap="$CHEAP" '
  /^run_shard / && $2 !~ /^\"/ { print "run_shard " cheap; next }
  /^sweep_file\(\) \{/ { print "sweep_file() { :; }"; next }
  { print }
' "$TMP/runner-fast.sh" >"$TMP/runner-nosweepbody.sh"
if cmp -s "$TMP/runner-cheap.sh" "$TMP/runner-nosweepbody.sh"; then
  fail "the sweep-body mutation did not change the fixture"
else
  bash "$TMP/runner-cheap.sh" >"$TMP/runner-cheap.out" 2>&1
  RCC=$?
  OUTC="$(cat "$TMP/runner-cheap.out")"
  if [ "$RCC" -eq 0 ] && printf '%s' "$OUTC" | grep -q 'file(s) syntax-checked'; then
    pass "control: the same fixture with the sweep intact PASSES (rc 0)"
  else
    fail "the control fixture returned rc $RCC (want 0): $(printf '%s' "$OUTC" | tail -1)"
  fi
  bash "$TMP/runner-nosweepbody.sh" >"$TMP/runner-nosweepbody.out" 2>&1
  RC=$?
  OUT="$(cat "$TMP/runner-nosweepbody.out")"
  if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'syntax sweep executed no file'; then
    pass "a runner whose sweep body is neutered FAILS at runtime (rc 1)"
  else
    fail "a neutered sweep body returned rc $RC (want 1): $(printf '%s' "$OUT" | tail -1)"
  fi
fi

echo ""
echo "9. CLI contract"
bash "$GUARD" --help >"$TMP/help.out" 2>&1
RC=$?
OUT="$(cat "$TMP/help.out")"
if [ "$RC" -eq 0 ]; then pass "--help exits 0"; else fail "--help exited $RC (want 0)"; fi
echo ""
echo "8o. A PIPE THEN A SWALLOW → rc 2 (the swallow is not only a prefix)"
awk '{ if ($0 ~ /^        run: bash scripts\/run-bash-shards\.sh$/) { print "        run: bash scripts/run-bash-shards.sh | tee /tmp/shards.log || true"; next } print }' \
  "$PR" >"$TMP/ci-pr-pipe-swallow.yml"
if cmp -s "$PR" "$TMP/ci-pr-pipe-swallow.yml"; then
  fail "the pipe+swallow mutation did not change the file"
else
  guard_rc "$MAIN" "$TMP/ci-pr-pipe-swallow.yml"
  if [ "$RC" -eq 2 ]; then
    pass "'runner | tee log || true' exits 2 (the failure is still swallowed)"
  else
    fail "'runner | tee log || true' returned rc $RC (want 2): $OUT"
  fi
fi

echo ""
echo "8p. PATHS-NARROWED TRIGGER → rc 2 (script changes would not run the lane)"
awk 'BEGIN{d=0} /^[[:space:]]*pull_request:/{d=1; print; next} d && /^[a-zA-Z]/{ if (!i) { print "    paths:"; print "      - \x27scripts/**\x27"; i=1 } d=0 } {print}' \
  "$PR" >"$TMP/ci-pr-paths.yml"
if cmp -s "$PR" "$TMP/ci-pr-paths.yml"; then
  fail "the paths-filter mutation did not change the file"
else
  guard_rc "$MAIN" "$TMP/ci-pr-paths.yml"
  if [ "$RC" -eq 2 ]; then
    pass "a paths-narrowed pull_request trigger exits 2"
  else
    fail "a paths-narrowed trigger returned rc $RC (want 2): $OUT"
  fi
fi

echo ""
echo "8q. COUNTER-PRESERVING SWEEP NEUTER → the RUNNER must fail at runtime"
awk -v cheap="$CHEAP" '
  /^run_shard / && $2 !~ /^\"/ { print "run_shard " cheap; next }
  /^sweep_file\(\) \{/ { print "sweep_file() { swept=$((swept + 1)); }"; next }
  { print }
' "$RUNNER" >"$TMP/runner-sweepcounter.sh"
bash "$TMP/runner-sweepcounter.sh" >"$TMP/runner-sweepcounter.out" 2>&1
RC=$?
OUT="$(cat "$TMP/runner-sweepcounter.out")"
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'sweep arm is broken'; then
  pass "a runner that keeps the sweep counter but does not parse exits 1 (the arm is proven)"
else
  fail "a counter-preserving sweep neuter returned rc $RC (want 1): $(printf '%s' "$OUT" | tail -1)"
fi

echo ""
echo "8r. A SUBSTITUTED-OUT-OF-REPO TARGET → the RUNNER must refuse it"
awk '{ if ($0 ~ /^run_shard [a-z]/) { print "run_shard /tmp/not-in-the-repo.sh"; next } print }' \
  "$RUNNER" >"$TMP/runner-subst.sh"
if cmp -s "$RUNNER" "$TMP/runner-subst.sh"; then
  fail "the substitution mutation did not change the file"
else
  bash "$TMP/runner-subst.sh" >"$TMP/runner-subst.out" 2>&1
  RC=$?
  OUT="$(cat "$TMP/runner-subst.out")"
  if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'is not inside this checkout'; then
    pass "a list pointed at a path outside the checkout is refused (rc 1)"
  else
    fail "an out-of-repo target returned rc $RC (want 1): $(printf '%s' "$OUT" | tail -1)"
  fi
fi

echo ""
echo "8s. A BARE PIPE at the call site → rc 2 (GitHub's default shell has no pipefail)"
awk '{ if ($0 ~ /^        run: bash scripts\/run-bash-shards\.sh$/) { print "        run: bash scripts/run-bash-shards.sh | cat"; next } print }' \
  "$PR" >"$TMP/ci-pr-bare-pipe.yml"
if cmp -s "$PR" "$TMP/ci-pr-bare-pipe.yml"; then
  fail "the bare-pipe mutation did not change the file"
else
  guard_rc "$MAIN" "$TMP/ci-pr-bare-pipe.yml"
  if [ "$RC" -eq 2 ]; then
    pass "a bare pipe at the call site exits 2 (the pipe's status would be reported)"
  else
    fail "a bare pipe returned rc $RC (want 2): $OUT"
  fi
fi

echo ""
echo "8t. REDIRECTIONS ONLY at the call site are accepted (no false block)"
awk '{ if ($0 ~ /^        run: bash scripts\/run-bash-shards\.sh$/) { print "        run: bash scripts/run-bash-shards.sh > /tmp/shards.log 2>&1"; next } print }' \
  "$PR" >"$TMP/ci-pr-redir.yml"
if cmp -s "$PR" "$TMP/ci-pr-redir.yml"; then
  fail "the redirect mutation did not change the file"
else
  guard_rc "$MAIN" "$TMP/ci-pr-redir.yml"
  if [ "$RC" -eq 2 ]; then
    pass "a redirection-only tail is refused (the step value must BE the bare call)"
  else
    fail "a redirection-only tail was accepted (rc $RC — want 2): $OUT"
  fi
fi

echo ""
echo "8u. A KEY NAMED run OUTSIDE THE STEP LIST → rc 1 (a lane that calls nowhere)"
awk '
  { print }
  /^  bash-suites:/ { injob = 1; next }
  injob && /^    runs-on:/ { print "    env:"; print "      run: bash scripts/run-bash-shards.sh"; injob = 0 }
' "$PR" \
  | awk '{ if ($0 ~ /^        run: bash scripts\/run-bash-shards\.sh$/) { print "        run: echo no-shards-here"; next } print }' \
  >"$TMP/ci-pr-envrun.yml"
if cmp -s "$PR" "$TMP/ci-pr-envrun.yml"; then
  fail "the env-run mutation did not change the file"
else
  guard_rc "$MAIN" "$TMP/ci-pr-envrun.yml"
  if [ "$RC" -eq 1 ]; then
    pass "a job-level 'run:' key outside the step list does not count as a call (rc 1)"
  else
    fail "an env-nested run: key returned rc $RC (want 1): $OUT"
  fi
fi

echo ""
echo "8v. FLOW-STYLE paths filter → rc 2 (the same narrowing, another spelling)"
awk '{ if ($0 ~ /^  pull_request:$/) { print "  pull_request: {paths: [\x27scripts/**\x27]}"; next } print }' \
  "$PR" >"$TMP/ci-pr-flowpaths.yml"
if cmp -s "$PR" "$TMP/ci-pr-flowpaths.yml"; then
  fail "the flow-style paths mutation did not change the file"
else
  guard_rc "$MAIN" "$TMP/ci-pr-flowpaths.yml"
  if [ "$RC" -eq 2 ]; then
    pass "a flow-style paths filter exits 2"
  else
    fail "a flow-style paths filter returned rc $RC (want 2): $OUT"
  fi
fi

echo ""
echo "8w. A SYMLINKED SHARD TARGET → the RUNNER must refuse it"
SYMDIR="$TMP/symrepo"
mkdir -p "$SYMDIR/scripts"
printf 'exit 0\n' >"$TMP/outside-target.sh"
ln -sf "$TMP/outside-target.sh" "$SYMDIR/scripts/linked.sh"
awk -v cheap="scripts/linked.sh" '
  /^run_shard / && $2 !~ /^\"/ { print "run_shard " cheap; next }
  { print }
' "$RUNNER" >"$SYMDIR/runner.sh"
( cd "$SYMDIR" && bash runner.sh ) >"$TMP/runner-symlink.out" 2>&1
RC=$?
OUT="$(cat "$TMP/runner-symlink.out")"
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'is a symlink'; then
  pass "a symlinked shard target is refused (rc 1)"
else
  fail "a symlinked target returned rc $RC (want 1): $(printf '%s' "$OUT" | tail -1)"
fi

echo ""
echo '8x. DASH-INLINE step conditional (`- if: false`) -> rc 2 (the step may not run)'
awk '{ print } /^  bash-suites:/ { injob = 1; next } injob && /^    runs-on:/ { print "      - if: false"; injob = 0 }' \
  "$PR" >"$TMP/ci-pr-dashif.yml"
if cmp -s "$PR" "$TMP/ci-pr-dashif.yml"; then
  fail "the dash-inline if mutation did not change the file"
else
  guard_rc "$MAIN" "$TMP/ci-pr-dashif.yml"
  if [ "$RC" -eq 2 ]; then
    pass "a dash-inline '- if: false' in the job exits 2 (the dash is not part of the key)"
  else
    fail "'- if: false' returned rc $RC (want 2): $OUT"
  fi
fi

echo ""
echo "8y. CI_LANE_* IN THE JOB → rc 2 (a job that configures the gate is not coverage)"
awk '{ print } /^  bash-suites:/ { injob = 1; next } injob && /^    runs-on:/ { print "    env:"; print "      CI_LANE_RUNNER: scripts/stub-shards.sh"; injob = 0 }' \
  "$PR" >"$TMP/ci-pr-laneenv.yml"
if cmp -s "$PR" "$TMP/ci-pr-laneenv.yml"; then
  fail "the CI_LANE_ env mutation did not change the file"
else
  guard_rc "$MAIN" "$TMP/ci-pr-laneenv.yml"
  if [ "$RC" -eq 2 ]; then
    pass "a CI_LANE_* key in the audited job exits 2 (the guard cannot be configured by it)"
  else
    fail "a CI_LANE_* job key returned rc $RC (want 2): $OUT"
  fi
fi

echo ""
echo "8z. A BACKSLASH-CONTINUED SWALLOW → rc 2 (the tail is not only the first physical line)"
awk '{ if ($0 ~ /^        run: bash scripts\/run-bash-shards\.sh$/) { print "        run: |"; print "          bash scripts/run-bash-shards.sh > /dev/null \\"; print "            || true"; next } print }' \
  "$PR" >"$TMP/ci-pr-cont-swallow.yml"
if cmp -s "$PR" "$TMP/ci-pr-cont-swallow.yml"; then
  fail "the continued-swallow mutation did not change the file"
else
  guard_rc "$MAIN" "$TMP/ci-pr-cont-swallow.yml"
  if [ "$RC" -eq 2 ]; then
    pass "a re-direction then a continued '|| true' exits 2 (the fold is what makes the tail visible)"
  else
    fail "a continued '|| true' returned rc $RC (want 2): $OUT"
  fi
fi

awk '{ if ($0 ~ /^        run: bash scripts\/run-bash-shards\.sh$/) { print "        run: |"; print "          bash scripts/run-bash-shards.sh 2>&1 \\"; print "            | tee /tmp/shards.log"; next } print }' \
  "$PR" >"$TMP/ci-pr-cont-pipe.yml"
guard_rc "$MAIN" "$TMP/ci-pr-cont-pipe.yml"
if [ "$RC" -eq 2 ]; then
  pass "a continued pipe exits 2 (no pipefail in the default shell)"
else
  fail "a continued pipe returned rc $RC (want 2): $OUT"
fi

echo ""
echo "8aa. A SYMLINKED PARENT DIRECTORY → the RUNNER must refuse it"
PARENTDIR="$TMP/parentrepo"
mkdir -p "$PARENTDIR" "$TMP/outside-dir"
printf 'exit 0\n' >"$TMP/outside-dir/stub.sh"
ln -sfn "$TMP/outside-dir" "$PARENTDIR/scripts"
awk -v cheap="scripts/stub.sh" '
  /^run_shard / && $2 !~ /^\"/ { print "run_shard " cheap; next }
  { print }
' "$RUNNER" >"$PARENTDIR/runner.sh"
( cd "$PARENTDIR" && bash runner.sh ) >"$TMP/runner-parentsym.out" 2>&1
RC=$?
OUT="$(cat "$TMP/runner-parentsym.out")"
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'resolves outside this checkout'; then
  pass "a symlinked PARENT directory is refused (the leaf check alone would pass it)"
else
  fail "a symlinked parent dir returned rc $RC (want 1): $(printf '%s' "$OUT" | tail -1)"
fi

echo ""
echo "8ab. FALSE-BLOCK CONTROLS — legitimate spellings must still be read as calls"
# Each of these was a real false block found by the code-review bug scan. A guard that refuses a
# lane which DOES call the runner is a category-B false block, and on a workflow nobody edited it
# would block every PR.
for spelling in "bash scripts/run-bash-shards.sh" "bash ./scripts/run-bash-shards.sh"; do
  awk -v r="        run: bash scripts/run-bash-shards.sh" -v s="        run: $spelling" \
    '{ if ($0 == r) { print s; next } print }' "$PR" >"$TMP/ci-pr-spell.yml"
  guard_rc "$MAIN" "$TMP/ci-pr-spell.yml"
  if [ "$RC" -eq 0 ]; then
    pass "the equivalent spelling '$spelling' is accepted"
  else
    fail "the spelling '$spelling' was refused (rc $RC): $OUT"
  fi
done

# A `<<` that is not a redirection (an arithmetic shift) must not swallow the rest of the step.
awk -v r="        run: bash scripts/run-bash-shards.sh" \
  '{ if ($0 == r) { print "        run: |"; print "          echo $((1 << 3))"; print r; next } print }' \
  "$PR" >"$TMP/ci-pr-shift.yml"
guard_rc "$MAIN" "$TMP/ci-pr-shift.yml"
if [ "$RC" -eq 2 ]; then
  pass "an arithmetic '<<' plus a second run: is refused as unparseable YAML (never read as a call)"
else
  fail "an arithmetic '<<' fixture returned rc $RC (want 2, unparseable YAML): $OUT"
fi

# Same, when the swallowed region would also have hidden a refused site: both must be visible.
awk -v r="        run: bash scripts/run-bash-shards.sh" \
  '{ if ($0 == r) { print "        run: |"; print "          echo $((1 << 3))"; print "          bash scripts/run-bash-shards.sh"; print "          bash scripts/run-bash-shards.sh || true"; next } print }' \
  "$PR" >"$TMP/ci-pr-shift2.yml"
guard_rc "$MAIN" "$TMP/ci-pr-shift2.yml"
if [ "$RC" -eq 2 ]; then
  pass "a refused site after an arithmetic '<<' is still refused (no hiding behind noise)"
else
  fail "a refused site after a '<<' returned rc $RC (want 2): $OUT"
fi

# A heredoc body whose line ends in a backslash must not swallow its own terminator.
awk -v r="        run: bash scripts/run-bash-shards.sh" \
  '{ if ($0 == r) { print "        run: |"; print "          cat <<EOF"; print "          body \\"; print "          EOF"; print r; next } print }' \
  "$PR" >"$TMP/ci-pr-hdcont.yml"
guard_rc "$MAIN" "$TMP/ci-pr-hdcont.yml"
if [ "$RC" -eq 2 ]; then
  pass "a heredoc body with a backslash yields unparseable YAML and is refused (rc 2)"
else
  fail "a heredoc-body fixture returned rc $RC (want 2, unparseable YAML): $OUT"
fi

# A matrix list before `steps:` must not latch the step indent.
awk '{ print } /^  bash-suites:$/ { inb = 1; next } inb && /^    runs-on: ubuntu-latest$/ { print "    strategy:"; print "      matrix:"; print "        os:"; print "          - ubuntu-latest"; inb = 0 }' \
  "$PR" >"$TMP/ci-pr-matrix.yml"
guard_rc "$MAIN" "$TMP/ci-pr-matrix.yml"
if [ "$RC" -eq 0 ]; then
  pass "a strategy/matrix list before steps: does not hide the steps"
else
  fail "a matrix list before steps: false-blocked the call (rc $RC): $OUT"
fi

# A sibling `push:` block that filters paths must not be read as narrowing pull_request.
awk '{ print; if ($0 ~ /^  pull_request:$/) { print "  push:"; print "    paths:"; print "      - \x27scripts/**\x27" } }' \
  "$PR" >"$TMP/ci-pr-pushpaths.yml"
guard_rc "$MAIN" "$TMP/ci-pr-pushpaths.yml"
if [ "$RC" -eq 0 ]; then
  pass "a paths filter on a sibling push: trigger is not attributed to pull_request"
else
  fail "a sibling push: paths filter refused the lane (rc $RC): $OUT"
fi

echo ""
echo "8ac. A QUOTED CI_LANE_* KEY → rc 2 (the refusal arm is not spelling-blind)"
awk '{ print } /^  bash-suites:$/ { inb = 1; next } inb && /^    runs-on: ubuntu-latest$/ { print "    env:"; print "      \"CI_LANE_MIN_SUITES\": \"0\""; inb = 0 }' \
  "$PR" >"$TMP/ci-pr-quotedlane.yml"
guard_rc "$MAIN" "$TMP/ci-pr-quotedlane.yml"
if [ "$RC" -eq 2 ]; then
  pass "a quoted CI_LANE_* key exits 2 (quoting is not an escape)"
else
  fail "a quoted CI_LANE_* key returned rc $RC (want 2): $OUT"
fi

echo ""
echo '8ac2. A WORKFLOW-LEVEL CI_LANE_* KEY -> rc 2, NAMING THE KEY (a doc under audit cannot configure the guard)'
# Inserted at the TOP of the document: inserted after `on:` it would land inside the trigger mapping
# and the refusal would come from the trigger arm, leaving this arm with no effective pin.
awk 'NR == 1 { print; print "env:"; print "  CI_LANE_RUNNER: /tmp/fake.sh"; next } { print }' \
  "$PR" >"$TMP/ci-pr-wflane.yml"
guard_rc "$MAIN" "$TMP/ci-pr-wflane.yml"
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'CI_LANE_RUNNER'; then
  pass "a workflow-level env: CI_LANE_* key exits 2 and names the key (the arm is load-bearing)"
else
  fail "a workflow-level CI_LANE_* key returned rc $RC (want 2, naming the key): $OUT"
fi

echo ""
echo '8ac3. A TRIGGER FILTER under pull_request: -> rc 2 (keys other than paths: narrow it too)'
# `types: [closed]` runs the lane only on PR-close events and `branches-ignore: ["**"]` matches
# every base branch: in both, the lane never runs on a PR commit while parity reads green — the
# #1369 split re-created with a different key, which the old key-by-key arm (paths/paths-ignore)
# did not see.
for spec in 'types: [closed]' 'branches-ignore: ["**"]' 'paths: ["src/**"]'; do
  awk -v extra="$spec" '
    /^  pull_request:/ { print; print "    " extra; next }
    { print }
  ' "$PR" >"$TMP/ci-pr-filter.yml"
  guard_rc "$MAIN" "$TMP/ci-pr-filter.yml"
  if [ "$RC" -eq 2 ]; then
    pass "a pull_request filter ($spec) exits 2"
  else
    fail "a pull_request filter ($spec) returned rc $RC (want 2): $OUT"
  fi
done

# The bare trigger is the shipped spelling and must stay green — the control for 8ac3: a guard that
# refused every `pull_request:` value would make the three pins above vacuous.
guard_rc "$MAIN" "$PR"
if [ "$RC" -eq 0 ]; then
  pass "the shipped bare 'pull_request:' trigger is NOT a false block (rc 0)"
else
  fail "the shipped trigger was refused (rc $RC): $OUT"
fi

echo ''
echo '8ac4. A BASH-STARTUP HIJACK in env: -> rc 2 (BASH_ENV runs a committed file first)'
# `env: {BASH_ENV: evil.sh}` makes bash source a committed file BEFORE the guard or the runner
# executes a line, so the file can `exit 0` and nothing either prints can be trusted — no self-check
# inside them can defend. Key-name assertion on the parsed document; a PATH rewrite that shadows
# `bash` is the same family and stays a filed residual (#1426).
for key in BASH_ENV PROMPT_COMMAND; do
  awk -v k="$key" 'NR == 1 { print; print "env:"; print "  " k ": evil.sh"; next } { print }' \
    "$PR" >"$TMP/ci-pr-inject.yml"
  guard_rc "$MAIN" "$TMP/ci-pr-inject.yml"
  if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q "$key"; then
    pass "a workflow-level env: $key exits 2 and names the key"
  else
    fail "a workflow-level env: $key returned rc $RC (want 2, naming it): $OUT"
  fi
done

echo ''
echo '8ac5. defaults.run.shell -> rc 2 (the SAME knob one level up: the step never executes)'
# `defaults.run.shell: 'true {0}'` runs the step as `true <file>` — exit 0, runner never executed —
# while the step's own `run:` still reads as the bare call. Job-level and workflow-level spellings
# (the workflow-level one reaches EVERY job, so auditing the named job alone is not enough).
awk '{ print; if ($0 ~ /^  bash-suites:$/) { j = 1; next } if (j && $0 ~ /^    runs-on: ubuntu-latest$/) { print "    defaults:"; print "      run:"; print "        shell: \x27true {0}\x27"; j = 0 } }' \
  "$PR" >"$TMP/ci-pr-dshell.yml"
guard_rc "$MAIN" "$TMP/ci-pr-dshell.yml"
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'defaults.run.shell'; then
  pass "a job-level defaults.run.shell exits 2 and names the key"
else
  fail "a job-level defaults.run.shell returned rc $RC (want 2, naming it): $OUT"
fi
awk 'NR == 1 { print; print "defaults:"; print "  run:"; print "    shell: \x27true {0}\x27"; next } { print }' \
  "$PR" >"$TMP/ci-pr-wfdshell.yml"
guard_rc "$MAIN" "$TMP/ci-pr-wfdshell.yml"
if [ "$RC" -eq 2 ]; then
  pass "a workflow-level defaults.run.shell exits 2 (it reaches every job)"
else
  fail "a workflow-level defaults.run.shell returned rc $RC (want 2): $OUT"
fi

# The control: `defaults.run.shell: bash` is the shipped shell and must stay accepted — without
# this, a guard that refused every `defaults:` key would make the two pins above vacuous.
awk 'NR == 1 { print; print "defaults:"; print "  run:"; print "    shell: bash"; next } { print }' \
  "$PR" >"$TMP/ci-pr-dshell-ok.yml"
guard_rc "$MAIN" "$TMP/ci-pr-dshell-ok.yml"
if [ "$RC" -eq 0 ]; then
  pass "defaults.run.shell: bash is NOT a false block (rc 0)"
else
  fail "defaults.run.shell: bash was refused (rc $RC): $OUT"
fi

echo ''
echo '8ac6. AN EMPTY pull_request VALUE -> rc 0 (no filter can narrow; not a false block)'
for spec in '{}' '[]'; do
  awk -v v="$spec" 'NR == 1 { print "on:"; print "  pull_request: " v; skip = 1 } skip && /^  pull_request:$/ { next } /^on:$/ { next } { print }' \
    "$PR" >"$TMP/ci-pr-emptytrig.yml"
  guard_rc "$MAIN" "$TMP/ci-pr-emptytrig.yml"
  if [ "$RC" -eq 0 ]; then
    pass "pull_request: $spec is accepted (an empty value carries no filter)"
  else
    fail "pull_request: $spec returned rc $RC (want 0): $OUT"
  fi
done

echo ''
echo '8ac7. A DUPLICATED SHARD LIST -> rc 2 (a repeated target is not extra coverage)'
# 13 of the 14 lines pointed at one cheap script: any length floor is satisfied while 13 suites
# never run (ledger-sourced, cycle 2 — the substitution variant of the runner-body residual).
awk -v cheap="scripts/check-no-sigpipe-grep.sh" '
  /^run_shard [a-z]/ && n < 13 { print "run_shard " cheap; n++; next }
  { print }
' "$RUNNER" >"$TMP/runner-dupes.sh"
guard_rc "$MAIN" "$PR" "$TMP/runner-dupes.sh"
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'duplicate'; then
  pass "a runner listing the same script 13 times exits 2 and says why"
else
  fail "a duplicated shard list returned rc $RC (want 2, naming duplicates): $OUT"
fi

echo ''
echo '8ac8. A FLOW-MAPPING __proto__ KEY -> rc 2 (it must not hand the guard a node nobody declares)'
# `jobs: {__proto__: {bash-suites: …}}` used to set the parsed object's PROTOTYPE, so the guard read
# a `bash-suites` job the document does not declare while a real YAML parser sees no such job — a
# false PASS, found by the security reviewer in `workflow-yaml.mjs` (flow mappings assigned with
# `out[key] = value`, which hits Object.prototype's `__proto__` setter). Fixed at the root: the
# parser creates OWN properties, as real YAML does. The control below proves flow mappings are still
# READ (so this pin cannot pass merely because flow style is refused).
printf 'name: x\non: pull_request\njobs: {__proto__: {bash-suites: {runs-on: ubuntu-latest, steps: [{run: "bash scripts/run-bash-shards.sh"}]}}}\n' \
  >"$TMP/ci-pr-proto.yml"
guard_rc "$MAIN" "$TMP/ci-pr-proto.yml"
if [ "$RC" -eq 2 ]; then
  pass "a flow-mapping __proto__ key exits 2 (the lane is not declared, so it is not covered)"
else
  fail "a flow-mapping __proto__ key returned rc $RC (want 2 — a false PASS): $OUT"
fi
printf 'name: x\non: pull_request\njobs: {bash-suites: {runs-on: ubuntu-latest, steps: [{run: "bash scripts/run-bash-shards.sh"}]}}\n' \
  >"$TMP/ci-pr-flowok.yml"
guard_rc "$MAIN" "$TMP/ci-pr-flowok.yml"
if [ "$RC" -eq 0 ]; then
  pass "control: an ordinary flow-mapping job IS read (the pin above is not 'flow style is refused')"
else
  fail "an ordinary flow-mapping job returned rc $RC (want 0): $OUT"
fi

# ROOT-CAUSE PIN. The guard refusing the polluted document does not prove the PARSER is fixed —
# the guard's own own-property lookup refuses it even with the bug present (verified: reverting
# workflow-yaml.mjs to plain assignment leaves the guard's rc 2 unchanged). The bug is a false PASS
# for EVERY consumer of this parser, so assert the parser's own behaviour: `__proto__` is an
# ordinary OWN key, and the object's prototype is untouched.
(
  cd "$ROOT" && node --input-type=module -e '
    import { readFileSync } from "node:fs";
    const { parseWorkflowYaml } = await import("./scripts/workflow-yaml.mjs");
    const wf = parseWorkflowYaml(readFileSync(process.argv[1], "utf8"));
    console.log(Object.getPrototypeOf(wf.jobs) === Object.prototype ? "CLEAN" : "POLLUTED");
    console.log("keys:" + Object.keys(wf.jobs).join(","));
  ' "$TMP/ci-pr-proto.yml"
) >"$TMP/proto-parser.txt" 2>&1
if grep -q '^CLEAN$' "$TMP/proto-parser.txt" && grep -q '^keys:__proto__$' "$TMP/proto-parser.txt"; then
  pass "the PARSER keeps __proto__ as an own key and does not pollute the prototype"
else
  fail "the parser polluted a prototype or lost the key: $(tr '\n' ' ' <"$TMP/proto-parser.txt")"
fi

echo ''
echo '8ad. A FOLDED block scalar (`run: >`) joins its lines -> the tail is visible'
awk -v r="        run: bash scripts/run-bash-shards.sh" \
  '{ if ($0 == r) { print "        run: >"; print "          bash scripts/run-bash-shards.sh"; print "          --list"; next } print }' \
  "$PR" >"$TMP/ci-pr-fold.yml"
guard_rc "$MAIN" "$TMP/ci-pr-fold.yml"
if [ "$RC" -eq 2 ]; then
  pass "a folded scalar whose single command carries --list exits 2 (YAML folds it into one line)"
else
  fail "a folded scalar with --list returned rc $RC (want 2): $OUT"
fi

awk -v r="        run: bash scripts/run-bash-shards.sh" \
  '{ if ($0 == r) { print "        run: >"; print "          bash scripts/run-bash-shards.sh"; next } print }' \
  "$PR" >"$TMP/ci-pr-foldok.yml"
guard_rc "$MAIN" "$TMP/ci-pr-foldok.yml"
if [ "$RC" -eq 0 ]; then
  pass "a folded scalar whose single command is the bare call is accepted"
else
  fail "a bare folded scalar was refused (rc $RC): $OUT"
fi

echo ""
echo "8ae. A FLOW VALUE on the trigger line itself → rc 2 (the value lives on the trigger line)"
awk '{ if ($0 ~ /^  pull_request:$/) { print "  pull_request: {paths: [\x27scripts/**\x27]}"; next } print }' \
  "$PR" >"$TMP/ci-pr-flowvalue.yml"
guard_rc "$MAIN" "$TMP/ci-pr-flowvalue.yml"
if [ "$RC" -eq 2 ]; then
  pass "a flow value on the pull_request line exits 2"
else
  fail "a flow value on the trigger line returned rc $RC (want 2): $OUT"
fi

echo ""
echo "8af. AN INDENTED COMMENT before the paths filter → rc 2 (a comment never ends a mapping)"
awk '{ print; if ($0 ~ /^  pull_request:$/) { print "  # a comment"; print "    paths:"; print "      - \x27scripts/**\x27" } }' \
  "$PR" >"$TMP/ci-pr-indcomment.yml"
guard_rc "$MAIN" "$TMP/ci-pr-indcomment.yml"
if [ "$RC" -eq 2 ]; then
  pass "an indented comment does not end the trigger block (the filter is still seen)"
else
  fail "an indented comment hid the paths filter (rc $RC, want 2): $OUT"
fi

echo ""
echo "8ag. A BACKGROUNDED CALL → rc 2 (exit 0 immediately, so no shard can fail the run)"
awk -v r="        run: bash scripts/run-bash-shards.sh" \
  '{ if ($0 == r) { print "        run: bash scripts/run-bash-shards.sh > /dev/null &"; next } print }' \
  "$PR" >"$TMP/ci-pr-bg.yml"
guard_rc "$MAIN" "$TMP/ci-pr-bg.yml"
if [ "$RC" -eq 2 ]; then
  pass "a backgrounded call exits 2"
else
  fail "a backgrounded call returned rc $RC (want 2): $OUT"
fi

awk -v r="        run: bash scripts/run-bash-shards.sh" \
  '{ if ($0 == r) { print "        run: bash scripts/run-bash-shards.sh 2>&1"; next } print }' \
  "$PR" >"$TMP/ci-pr-stderr.yml"
guard_rc "$MAIN" "$TMP/ci-pr-stderr.yml"
if [ "$RC" -eq 2 ]; then
  pass "a '2>&1' tail is refused (the step value must BE the bare call)"
else
  fail "'2>&1' was accepted (rc $RC — want 2): $OUT"
fi

echo ""
echo '8ah. `steps:` WITH A TRAILING COMMENT -> rc 0 (still the step list)'
awk '{ if ($0 ~ /^    steps:$/) { print "    steps:  # the steps"; next } print }' \
  "$PR" >"$TMP/ci-pr-stepscomment.yml"
guard_rc "$MAIN" "$TMP/ci-pr-stepscomment.yml"
if [ "$RC" -eq 0 ]; then
  pass "'steps:  # comment' still anchors the step list"
else
  fail "'steps:' with a trailing comment returned rc $RC (want 0): $OUT"
fi

echo ""
echo "8ai. TWO CONSECUTIVE FOLDED STEPS → the first is not dropped (a pending fold must flush)"
awk '
  /^      - name: Bash shards/ { print "      - run: >"; print "          bash scripts/run-bash-shards.sh"; print "          --list"; print "      - run: >"; print "          bash scripts/run-bash-shards.sh"; pend = 1; next }
  pend && /^        run: bash scripts\/run-bash-shards\.sh$/ { pend = 0; next }
  { print }
' "$PR" >"$TMP/ci-pr-twofold.yml"
guard_rc "$MAIN" "$TMP/ci-pr-twofold.yml"
# rc 0 is correct here, and this pin used to assert 2: the second (bare, folded) step IS the call,
# so the lane executes the full list, while the first folded step only mentions the runner. A
# mention is refused only when it STANDS IN for the call (`exact === 0`) — a lane that carries the
# bare call somewhere is not a bypass, and refusing it would over-block an extra `--list` step.
if [ "$RC" -eq 0 ]; then
  pass "a mention beside a bare call is not a bypass (the lane still executes the runner)"
else
  fail "a mention beside a real bare call was refused (rc $RC — want 0): $OUT"
fi

# The control makes the FIRST fold the only matching call, so losing it changes the verdict: with
# the second fold carrying only `echo done`, the pre-fix guard dropped the bare call and returned
# rc 1 while this asserted rc 0. (An earlier version put the call in the SECOND fold too, so it
# passed even when the first was dropped — a vacuous assertion, found by the bug-scan reviewer.)
awk '
  /^      - name: Bash shards/ { print "      - run: >"; print "          bash scripts/run-bash-shards.sh"; print "      - run: >"; print "          echo done"; pend = 1; next }
  pend && /^        run: bash scripts\/run-bash-shards\.sh$/ { pend = 0; next }
  { print }
' "$PR" >"$TMP/ci-pr-twofoldok.yml"
guard_rc "$MAIN" "$TMP/ci-pr-twofoldok.yml"
if [ "$RC" -eq 0 ]; then
  pass "two consecutive folded steps: the FIRST one's bare call is still read"
else
  fail "the first folded step was lost (rc $RC, want 0): $OUT"
fi

echo ""
echo "8ak. A TRAILING COMMENT mentioning paths: → rc 0 (a comment is not a filter)"
awk '{ if ($0 ~ /^  pull_request:$/) { print "  pull_request:  # no paths: filter"; next } print }' \
  "$PR" >"$TMP/ci-pr-trailcomment.yml"
guard_rc "$MAIN" "$TMP/ci-pr-trailcomment.yml"
if [ "$RC" -eq 0 ]; then
  pass "a trailing comment mentioning 'paths:' does not read as a narrowing filter"
else
  fail "a trailing comment mentioning 'paths:' was read as a filter (rc $RC): $OUT"
fi

echo ""
echo '8al. A BLANK LINE inside `run: >` separates commands (YAML keeps it as a newline)'
awk -v r="        run: bash scripts/run-bash-shards.sh" \
  '{ if ($0 == r) { print "        run: >"; print "          echo hi"; print ""; print "          bash scripts/run-bash-shards.sh"; next } print }' \
  "$PR" >"$TMP/ci-pr-foldblank.yml"
guard_rc "$MAIN" "$TMP/ci-pr-foldblank.yml"
if [ "$RC" -eq 2 ]; then
  pass "a folded block with a blank line is refused (its value is not the bare call)"
else
  fail "a folded block with a leading blank line returned rc $RC (want 2): $OUT"
fi

awk -v r="        run: bash scripts/run-bash-shards.sh" \
  '{ if ($0 == r) { print "        run: >"; print "          bash scripts/run-bash-shards.sh"; print ""; print "          echo done"; next } print }' \
  "$PR" >"$TMP/ci-pr-foldblank2.yml"
guard_rc "$MAIN" "$TMP/ci-pr-foldblank2.yml"
if [ "$RC" -eq 2 ]; then
  pass "a folded block with a trailing command is refused (its value is not the bare call)"
else
  fail "a folded block with a trailing blank line returned rc $RC (want 2): $OUT"
fi

echo ""
echo "8aj. A COMMENT MENTIONING paths: → rc 0 (a comment is not a filter)"
awk '{ print; if ($0 ~ /^  pull_request:$/) { print "    # NOTE: a paths: filter is deliberately NOT used here" } }' \
  "$PR" >"$TMP/ci-pr-commentpaths.yml"
guard_rc "$MAIN" "$TMP/ci-pr-commentpaths.yml"
if [ "$RC" -eq 0 ]; then
  pass "a comment mentioning 'paths:' does not read as a narrowing filter"
else
  fail "a comment mentioning 'paths:' was read as a filter (rc $RC): $OUT"
fi

bash "$GUARD" --no-such-flag >"$TMP/badflag.out" 2>&1
RC=$?
OUT="$(cat "$TMP/badflag.out")"
if [ "$RC" -eq 2 ]; then pass "an unknown argument exits 2"; else fail "an unknown argument exited $RC (want 2)"; fi

echo ""
echo "10. WIRING — a guard (or runner) nothing invokes protects nothing"
for pair in "PR:$PR" "main:$MAIN"; do
  lane="${pair%%:*}"; wf="${pair#*:}"
  if grep -qE '^[[:space:]]*(run:[[:space:]]+)?bash[[:space:]]+scripts/check-ci-lane-parity\.sh' "$wf"; then
    pass "the guard is invoked in the $lane lane"
  else
    fail "the guard is NOT invoked in the $lane lane — the assertion would never run there"
  fi
done

echo ""
echo "11. THE RUNNER'S OWN CONTRACT — --list is the list the floor reads"
bash "$RUNNER" --list >"$TMP/runner-list.txt" 2>&1
RC=$?
listed="$(grep -c . "$TMP/runner-list.txt" || true)"
if [ "$RC" -eq 0 ] && [ "$listed" -ge 14 ]; then
  pass "--list prints $listed shard(s) and exits 0 (the floor reads this same source)"
else
  fail "--list returned rc $RC with $listed line(s) (want 0 and >= 14)"
fi
if grep -q 'scripts/record-review.test.sh' "$TMP/runner-list.txt"; then
  pass "--list names the incident suite (the list is the one that actually runs)"
else
  fail "--list does not name scripts/record-review.test.sh: $(cat "$TMP/runner-list.txt")"
fi

echo ""
if [ "$failures" -eq 0 ]; then
  echo "✅ ci-lane-parity suite passed (${checks} assertions)"
  exit 0
fi
echo "❌ ci-lane-parity suite: $failures of $checks assertion(s) failed"
exit 1
