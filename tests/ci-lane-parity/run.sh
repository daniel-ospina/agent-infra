#!/bin/bash
# shard: off pinned by its own step in BOTH lanes (ci.yml `bash-suites-gate`, ci-main `script-validate`) and it drives THIS runner's fast copy - as a shard it would re-enter itself
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
#
# NOTE ON STYLE (2): every "does this output contain X" test here is `grep -q 'X' <<<"$OUT"`,
# NEVER a `printf`-piped-into-`grep -q` pipeline. This script runs under `set -o pipefail`, so when
# `grep -q` exits at its first match while the writer is still pushing bytes, the writer takes
# SIGPIPE and the PIPELINE status becomes non-zero — the `if` then takes its else branch and
# reports a FALSE FAILURE on a payload that was there all along. `scripts/check-no-sigpipe-grep.sh`
# records the class (#841) and its sanctioned fix (a here-string, which bash backs with a temp file
# so no writer is left to kill). That guard's default scan set is `scripts .husky pi-bootstrap`, so
# it cannot see this file — measured 2026-10-23: arm 2's piped form false-failed 13 times in 200
# iterations on an untouched `origin/main` tree, and 0 times in 200 with the here-string. A spurious
# red in the suite that gates the guard is a merge stall, not a nit.

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

# ── THE FIXTURE the runtime-mutation pins (8d, 8e, 8h, 8n, 8q) execute ────────────────────────
#
# Those pins assert properties of the RUNNER's own code — the `listed == executed` arithmetic, the
# failure-recording sentinel, the sweep counter, the refusal of a symlinked/out-of-repo target.
# Every one of them is a function of the runner's LOGIC, not of which suites its list happens to
# name. So the fixture narrows the runner's DISCOVERY to ONE committed, hermetic stand-in
# (`tests/ci-lane-parity/stand-in-shard.sh` — a single `exit 0`) and keeps the rest byte-identical.
#
# ⛔ WHY THE REAL LIST IS NOT RUN HERE (this is the whole cost of this suite, measured 2026-10-23).
# Until this line changed, the fixture was the runner's own list with a few slow shards grepped
# out (`runner-fast.sh`), and the pins executed it THREE times (8h, 8d, 8e) — after #2414 had
# already stopped 8n/8q pointing at a repo-wide guard whose verdict cost ~9.6 s per invocation.
# On `origin/main` (`6ae9d509`) that made this suite take 23m37s while its ~180 pass/fail branch
# sites (90 assertions) ran in under 40 s; the three fixture executions were the other 23 minutes,
# all of it RE-RUNNING suites
# that the lane's own `Bash shards` step already runs on the same commit (#2439 recorded the same
# duplicate-work class for other folded jobs).
#
# ⛔ AND IT WAS NOT ONLY SLOW, IT WAS NOISY. A fixture built from the real list inherits every real
# shard's verdict on the RUNNER'S machine, so an unrelated red (measured here: `reap-lane-venvs`
# `❌ O3 the summary reports reaped=1`) reds a fixture whose pins expect rc 0 — `#2414` is the same
# failure one layer out (`sigpipe-grep-guard`'s verdict reddened 8n's CONTROL arm and the message
# blamed the fixture). An inert stand-in cannot move for a reason this file does not name.
#
# Keep `CHEAP` pointed at something hermetic: its rc must depend on nothing but itself.
#
# ⛔ WHAT THE SUITE COSTS NOW (measured 2026-10-24, after #2529 landed). CI: the whole suite is
# 6-12 s on `bash-suites-gate` step 5 (17 PR runs sampled from the Actions API; one 17 s outlier),
# 6-9 s on ci-main's `script-validate` step 6 (8 successful main runs) — the ~90 static arms and ONE
# fixture execution per runtime pin, not the shard list, are the wall. Locally (macOS, loaded box)
# 27-67 s for 94 assertions. The 38m41s / "38.7 min" figure that still circulates is PR #2412's job
# 120365087427 (2026-10-23T10:25Z), taken BEFORE #2529 replaced the real list in the fixture with
# `stand-in-shard.sh`; it is not this suite's current cost and a bound sized from it protects
# nothing. Re-measure before quoting a number here.
CHEAP="tests/ci-lane-parity/stand-in-shard.sh"
# ⛔ THE FIXTURE COPIES ARE HERMETIC: THEY MUST NOT ASK THE HOST'S PROCESS TABLE ANYTHING.
# `stage_guard` gives each fixture root the real helper so `run-bash-shards.sh`'s fail-closed load
# succeeds — but the copies then call `fixture_guard_placement` with the DEFAULT root set, so a
# fixture's exit code would depend on whether the machine running this suite happens to have a
# controller executing from a cell root. Measured on a box with 4 live controllers: 22 of 121
# assertions failed here versus 15 with this line, and the 7 extra were all `rc 78` guard refusals —
# i.e. the suite's verdict became host-dependent, which is what "hermetic" in this file's header
# forbids. `${FIXTURE_LIVE_ROOTS-…}` takes an explicit empty value as "no roots" (no colon on
# purpose), so this is exactly the seam the helper advertises for a caller like this one. The real
# gate still runs in `run-bash-shards.sh` itself, which is not a fixture.
FIXTURE_LIVE_ROOTS=; export FIXTURE_LIVE_ROOTS
# cheap_runner <out-file> <one-shard-target> — a copy of the REAL runner whose DISCOVERY points at
# exactly one cheap target. ⛔ Since agent-infra#2609 the list is DERIVED (`SUITE_GLOBS` + each
# suite's own `# shard:` marker), so this fixture replaces that ONE data list instead of rewriting
# 79 `run_shard` lines: the shipped discovery, marker parse, sort and arithmetic are all still the
# ones under test, and a fixture execution now runs the stand-in ONCE instead of 79 times.
cheap_runner() {
  awk -v cheap="$2" '
    /^SUITE_GLOBS=\($/ { print "SUITE_GLOBS=( \"" cheap "\" )"; skip = 1; next }
    skip && /^\)$/ { skip = 0; next }
    skip { next }
    { print }
  ' "$RUNNER" >"$1"
}
# stage_guard <fixture-root> — copy the #3011 placement-guard helper into a fixture tree.
# ⛔ EVERY FIXTURE ROOT THAT RUNS A COPY OF THE DRIVER MUST CARRY THE GUARD HELPER. The driver sources
# `$SHARD_ROOT/scripts/orchestrator-harness/fixture-hermetic.sh` and REFUSES (exit 2) when that load
# fails — deliberately fail-closed, because an unloadable guard is the "enforcer that cannot fire"
# class #3011 exists to close. A minimal fixture copies only the driver, so without this the copy is
# refused BEFORE it exercises anything, and ~17 arms here red in BOTH lanes (measured: `rc=2`,
# "cannot load …/fixture-hermetic.sh"). Staging the helper keeps the driver's contract intact in the
# fixture — the alternative, weakening the refusal to a warning, reopens exactly the bypass.
stage_guard() {
  mkdir -p "$1/scripts/orchestrator-harness" &&
    cp "$ROOT/scripts/orchestrator-harness/fixture-hermetic.sh" "$1/scripts/orchestrator-harness/"
}
# The fixture ROOT. The runner anchors discovery to the tree it LIVES in (agent-infra#2609 review:
# `--list` used to read the script's own text and worked from any cwd, while the run path was
# cwd-relative — one driver, two contracts). A copy therefore sits at <root>/scripts/<name> and
# finds its target relative to <root>, so this fixture mirrors the layout instead of leaning on the
# caller's cwd. `scripts/sweepable.sh` keeps the syntax sweep non-empty (the `swept` sentinel).
FIX="$TMP/fixture"
mkdir -p "$FIX/scripts" "$FIX/tests/ci-lane-parity"
stage_guard "$FIX"
cp "$ROOT/$CHEAP" "$FIX/$CHEAP"
printf '#!/bin/bash\n:\n' >"$FIX/scripts/sweepable.sh"
cheap_runner "$FIX/scripts/runner-cheap.sh" "$CHEAP"

# Every fixture execution that walks the WHOLE list goes through this bound: 8d, 8e, 8h, and 8n's
# pair. Arms 8q and 8r rebuild the runner with discovery already narrowed to CHEAP, and
# the two symlink arms run a three-line stub — those four are inert by construction and carry no
# bound. The split is stated rather than implied so that a fixture added here knows which it is
# (review finding, cycle 1: the comment used to claim that EVERY fixture was bounded). A bound can
# only ever fire on a genuine hang, and then it is a NAMED red (rc 124), never silence.
# That is #2299's ask: `bash-suites` was measured stuck inside this suite for 90+ minutes with no
# step progress, and a 600 s local run terminated at the same arm, reported as an unrelated red.
# `timeout` is GNU; macOS has `gtimeout` (coreutils) or neither — with neither, the bound is absent
# and this suite still fails closed on every assertion below (the fixture itself can no longer hang).
if command -v timeout >/dev/null 2>&1; then
  FIXTURE_BOUND="timeout 120"
elif command -v gtimeout >/dev/null 2>&1; then
  FIXTURE_BOUND="gtimeout 120"
else
  FIXTURE_BOUND=""
fi
# ⛔ The bound is applied INLINE at each call site (`$FIXTURE_BOUND bash "$TMP/…"`), never through
# a helper taking the script as `$1`: `extensions/main-worktree-guard` treats a script invocation
# whose path is an UNRESOLVABLE expansion (`bash "$1"`) as "this file may discard anywhere" and
# fails closed, so wrapping the fixtures in such a helper makes every gated lane command that runs
# this suite refuse — a false block on the very gate this suite protects (measured while writing
# this change, #709/#1885).

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
if grep -qx 'scripts/record-review.test.sh' <<<"$(bash "$RUNNER" --list 2>/dev/null)"; then
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
  if [ "$RC" -eq 1 ] && grep -q 'PR lane' <<<"$OUT"; then
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
  if [ "$RC" -eq 1 ] && grep -q 'main lane' <<<"$OUT"; then
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
echo "5. A GUTTED RUNNER (no discovery) → rc 2, never a vacuous 'both lanes agree'"
# #2609: the list is DERIVED, so "gutted" now means the DISCOVERY LIST is gone (the `SUITE_GLOBS`
# array). Deleting the execution loop instead leaves a list that advertises 79 suites and runs
# none — that is the runner's own runtime counter's job (`executed 0 of 79`), pinned by 8d.
awk '
  /^SUITE_GLOBS=\($/ { skip = 1; next }
  skip && /^\)$/ { skip = 0; next }
  skip { next }
  { print }
' "$RUNNER" >"$FIX/scripts/runner-gutted.sh"
if cmp -s "$RUNNER" "$FIX/scripts/runner-gutted.sh"; then
  fail "the gutted-runner mutation did not change the file"
else
  # The runner refuses FIRST, by itself: an empty derivation is never printed as "the list".
  GUT_LIST="$( cd "$FIX" && bash scripts/runner-gutted.sh --list 2>&1 )"
  GUT_RC=$?
  guard_rc "$MAIN" "$PR" "$FIX/scripts/runner-gutted.sh"
  if [ "$GUT_RC" -eq 2 ] && grep -q 'EMPTY' <<<"$GUT_LIST" \
     && [ "$RC" -eq 2 ] && grep -q 'shard list is unreadable\|EMPTY' <<<"$OUT"; then
    pass "a gutted runner refuses its own --list (rc 2, naming the emptiness) and the guard refuses it too"
  else
    fail "a gutted runner: --list rc $GUT_RC [$GUT_LIST] guard rc $RC (want 2/2): $OUT"
  fi
fi

echo ""
echo "5b. A RUNNER THAT PRINTS TOO FEW SHARDS → rc 2, naming the floor"
# The floor is the guard's coverage FLOOR (14 suites) — independent of how the list is produced, so
# it needs its own stub now that the real runner can no longer be mutated into "prints 3 and exits
# 0": its discovery either works (79) or refuses (arm 5). Without this arm the floor would be
# unexercised, i.e. the assertion in arm 5 above would be measuring a branch nothing reached.
{
  echo '#!/usr/bin/env bash'
  echo 'case "${1:-}" in'
  echo '  --list) printf "%s\n" scripts/a.test.sh scripts/b.test.sh scripts/c.test.sh; exit 0 ;;'
  echo '  --list-sweeps) printf "%s\n" "scripts/*.sh"; exit 0 ;;'
  echo 'esac'
  echo 'exit 0'
} >"$TMP/runner-thin.sh"
guard_rc "$MAIN" "$PR" "$TMP/runner-thin.sh"
if [ "$RC" -eq 2 ] && grep -q 'shard(s) (floor' <<<"$OUT"; then
  pass "a runner listing 3 shards exits 2 and names the floor (rc 2)"
else
  fail "a thin runner returned rc $RC (want 2, naming the floor): $OUT"
fi

echo ""
echo "6. A RUNNER WITH NO SWEEPS (0 syntax targets) → rc 2"
# The sweep half is DATA now (SWEEP_GLOBS) plus the loops that iterate it, and the guard reads the
# list from the runner's own `--list-sweeps`. So the mutation EMPTIES that data list: deleting the
# loops alone would leave the list advertising globs nothing iterates, which the guard cannot see
# and the RUNNER's `swept` sentinel catches at runtime (pinned by 8q below). (#2609: the mutation
# used to also delete `for f in …` lines, which now includes the DISCOVERY loop — that made the
# mutated runner a syntax error, and the arm measured the unreadable-list refusal instead.)
# Discovery stays INTACT and cheap (one hermetic target): since #2609 an emptied discovery refuses
# its own `--list`, so mutating both halves at once would measure that refusal instead of the floor.
for _n in 01 02 03 04 05 06 07 08 09 10 11 12 13 14; do
  mkdir -p "$FIX/tests/t$_n"
  printf '#!/bin/bash\nexit 0\n' >"$FIX/tests/t$_n/run.sh"
done
cheap_runner "$FIX/scripts/runner-presweep.sh" "tests/t*/run.sh"
# ⛔ `SWEEP_GLOBS=""` and NOT `SWEEP_GLOBS=()`: the runner sets `set -uo pipefail`, and under
# bash 3.2 (macOS `/bin/bash`) expanding an EMPTY ARRAY is an "unbound variable" error, which would
# take this arm red locally for a reason of its own — `--list-sweeps` names the shell, not the sweep
# floor. A defined-but-empty scalar expands to one blank line, which the guard filters out, so both
# bash 3.2 and 5.x report 0 targets (#2754, kept from main across the derivation rewrite).
# ⛔ The mutant is built from `runner-presweep.sh` (14 hermetic targets, sweep declaration INTACT),
# and never from `runner-cheap.sh` — that one discovers a SINGLE stand-in, which is below the guard's
# MIN_SUITES floor of 14. The arms below that need to rebuild a sweep declaration therefore rebuild
# it from presweep too: after this mutation the `SWEEP_GLOBS=(…)` form is gone by design.
cp "$FIX/scripts/runner-presweep.sh" "$FIX/scripts/runner-nosweep.sh"
awk '{ if ($0 ~ /^SWEEP_GLOBS=\(/) { print "SWEEP_GLOBS=\"\""; next } print }' \
  "$FIX/scripts/runner-nosweep.sh" >"$TMP/runner-nosweep.tmp" && mv "$TMP/runner-nosweep.tmp" "$FIX/scripts/runner-nosweep.sh"
if cmp -s "$FIX/scripts/runner-presweep.sh" "$FIX/scripts/runner-nosweep.sh"; then
  fail "the no-sweep mutation did not change the file"
else
  # (a) the mutant is VALID shell — a syntax error here would make the arm's red meaningless
  if bash -n "$FIX/scripts/runner-nosweep.sh" 2>"$TMP/runner-nosweep.syntax"; then
    pass "the no-sweep mutant is VALID shell (bash -n clean)"
  else
    fail "the no-sweep mutant is not valid shell: $(cat "$TMP/runner-nosweep.syntax")"
  fi
  # (b) the mutation is SURGICAL — the mutant lists the same shards, line for line, as the runner it
  # was built from. ⛔ Measure the INPUTS: two `--list` invocations that both fail compare equal under
  # `cmp -s`, so asserting only the comparison would pass having read nothing (the exact class this
  # change is about). The list must be non-empty — 14 is the guard's own MIN_SUITES floor.
  bash "$FIX/scripts/runner-presweep.sh" --list >"$TMP/sweeps-real-list.txt" 2>&1
  real_list_rc=$?
  bash "$FIX/scripts/runner-nosweep.sh" --list >"$TMP/sweeps-mutant-list.txt" 2>&1
  mutant_list_rc=$?
  real_list_n="$(grep -c . "$TMP/sweeps-real-list.txt" || true)"
  if [ "$real_list_rc" -ne 0 ] || [ "$real_list_n" -lt 14 ]; then
    fail "the fixture runner's own --list is unreadable (rc $real_list_rc, $real_list_n line(s)) — the comparison below would measure nothing"
  elif [ "$mutant_list_rc" -ne 0 ]; then
    fail "the no-sweep mutant's --list exited $mutant_list_rc — it cannot be compared to the real list"
  elif cmp -s "$TMP/sweeps-real-list.txt" "$TMP/sweeps-mutant-list.txt"; then
    pass "the no-sweep mutant keeps the shard list intact ($real_list_n shard(s), only the sweep declaration moved)"
  else
    fail "the no-sweep mutant ALSO changed the shard list: $(diff "$TMP/sweeps-real-list.txt" "$TMP/sweeps-mutant-list.txt" | head -3 | tr '\n' ' ')"
  fi
  # (c) …and it really declares no sweeps: 0 non-blank lines from its own `--list-sweeps`
  bash "$FIX/scripts/runner-nosweep.sh" --list-sweeps >"$TMP/sweeps-mutant-sweeps.txt" 2>&1
  if [ "$(grep -c . "$TMP/sweeps-mutant-sweeps.txt" || true)" -eq 0 ]; then
    pass "the no-sweep mutant declares 0 sweep target(s) — the neuter is behavioural"
  else
    fail "the no-sweep mutant still declares sweeps: $(tr '\n' ' ' <"$TMP/sweeps-mutant-sweeps.txt")"
  fi
  guard_rc "$MAIN" "$PR" "$FIX/scripts/runner-nosweep.sh"
  if [ "$RC" -eq 2 ] && grep -q 'syntax target' <<<"$OUT"; then
    pass "a runner with no sweeps exits 2 — the syntax half cannot go uncovered in silence"
  else
    fail "a runner with no sweeps returned rc $RC (want 2, naming the sweeps): $OUT"
  fi
  # (d) NON-VACUITY — the same CHEAP fixture runner with the sweep list NON-EMPTY (one real glob,
  # everything else byte-identical) must PASS. Without this the red above could be attributable to
  # the guard being handed a file outside the checkout rather than to the emptied list.
  # ⛔ THE MUTANT LIVES INSIDE THE FIXTURE CHECKOUT, NEVER IN BARE `$TMP` (#2609 review, found by
  # this arm going red after the derivation landed). The runner anchors discovery to the tree it
  # LIVES in, so a copy at `$TMP/runner-onesweep.sh` has no `scripts/` beside it, its `--list`
  # refuses with rc 2 ("shard list is unreadable") and the control measures that refusal instead of
  # the sweep floor — the same reason arms 5 and 6b already write `$FIX/scripts/*`.
  # ⛔ …AND IT DISCOVERS THE FIXTURE'S 14 hermetic targets (`tests/t*/run.sh`), not the real order and
  # not `$CHEAP` (ONE stand-in): the guard's floor is 14, so a one-shard runner is refused for the
  # FLOOR and the control would be red for a reason that is not the emptied sweep list. Rebuilt from
  # `runner-presweep.sh` (the 14-target copy taken BEFORE the sweep declaration was emptied, so the
  # `SWEEP_GLOBS=(…)` form is still there to substitute) rather than from `runner-cheap.sh`.
  awk '
    /^SWEEP_GLOBS=\(/ { print "SWEEP_GLOBS=(\"scripts/*.sh\")"; next }
    { print }
  ' "$FIX/scripts/runner-presweep.sh" >"$FIX/scripts/runner-onesweep.sh"
  guard_rc "$MAIN" "$PR" "$FIX/scripts/runner-onesweep.sh"
  if [ "$RC" -eq 0 ]; then
    pass "control: the same fixture path with ONE sweep target PASSES (rc 0) — the red is the emptied list"
  else
    fail "control: a runner with one sweep target returned rc $RC (want 0): $OUT"
  fi
  # (e) …and the guard READS the list rather than grepping the declaration. The mutant above empties
  # the DECLARATION, which a text scan of the runner would also see, so on its own it cannot tell a
  # behavioural read (`bash <runner> --list-sweeps`, the design the .mjs header records) from a grep
  # over the file. This mutant keeps the declaration intact and silences only the print, so a
  # text-scanning guard passes it and this arm goes red.
  awk '
    /^  printf .*SWEEP_GLOBS\[@\]/ { print "  :"; next }
    { print }
  ' "$FIX/scripts/runner-onesweep.sh" >"$FIX/scripts/runner-silentsweeps.sh"
  if cmp -s "$FIX/scripts/runner-onesweep.sh" "$FIX/scripts/runner-silentsweeps.sh"; then
    fail "the silent-sweeps mutation did not change the file"
  else
    guard_rc "$MAIN" "$PR" "$FIX/scripts/runner-silentsweeps.sh"
    if [ "$RC" -eq 2 ] && grep -q 'syntax target' <<<"$OUT"; then
      pass "a runner whose declaration is intact but whose --list-sweeps prints nothing still exits 2 (the list is READ, not grepped)"
    else
      fail "an intact declaration with a silent --list-sweeps returned rc $RC (want 2): $OUT"
    fi
  fi
fi

# A runner that keeps its sweeps but loses every suite must ALSO exit 2 — the two floors are
# independent, so a mutation that satisfies one must not carry the other.
echo ""
echo "6b. FLOOR INDEPENDENCE — sweeps intact but no discovery still exits 2"
awk '
  /^SUITE_GLOBS=\($/ { skip = 1; next }
  skip && /^\)$/ { skip = 0; next }
  skip { next }
  { print }
' "$RUNNER" >"$FIX/scripts/runner-noshards-but-sweeps.sh"
# ⛔ THE MUTANT MUST BE VALID SHELL (#2754, kept from main across the derivation rewrite). An
# unparseable mutant would make the red below a SYNTAX failure wearing the floor's message: the arm
# would pass while measuring nothing about the floor. `bash -n` is the check; the mutant is written
# into $FIX (inside a checkout) because the runner derives its root from its own location.
if bash -n "$FIX/scripts/runner-noshards-but-sweeps.sh"; then
  pass "the empty-discovery mutant is VALID shell (bash -n clean)"
else
  fail "the empty-discovery mutant is not valid shell"
fi
guard_rc "$MAIN" "$PR" "$FIX/scripts/runner-noshards-but-sweeps.sh"
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
sed 's/ || shard_errors=$((shard_errors + 1))//' "$FIX/scripts/runner-cheap.sh" >"$FIX/scripts/runner-norecord.sh"
if cmp -s "$FIX/scripts/runner-cheap.sh" "$FIX/scripts/runner-norecord.sh"; then
  fail "the no-record mutation did not change the file"
else
  $FIXTURE_BOUND bash "$FIX/scripts/runner-norecord.sh" >"$TMP/runner-norecord.out" 2>&1
  RC=$?
  OUT="$(cat "$TMP/runner-norecord.out")"
  # ⛔ THE TWO CLAUSES ARE REPORTED SEPARATELY (#2838). This arm asserted a CONJUNCTION and then
  # reported only the rc — so when the rc clause was the one that HELD it printed
  # `returned rc 1 (want 1)`, a message describing a satisfied clause and never naming the grep
  # that failed. It read as a shard outage; the actual diagnosis was "the sentinel text is absent",
  # which has a different cause and a different fix (measured 2026-10-29: the runner's coverage
  # guard exited 1 at `executed 104 of 1 listed shard(s)` before the sentinel at the end of the file
  # was reachable, because the tree still carried an enumerated `run_shard` block — #2838).
  # ⛔ AND ONLY THE TAIL OF `$OUT` IS PUBLISHED. The whole capture was 213 lines of this fixture's
  # own `No such file or directory` spray, carrying `::error::`/`##[error]` strings that GitHub
  # turns into CHECK-RUN ANNOTATIONS — one failed assertion put a page of fabricated shard failures
  # on a PR's check surface. A message is a diagnosis, not a transcript.
  if [ "$RC" -ne 1 ]; then
    fail "a runner with no failure-recording arm returned rc $RC (want 1): $(printf '%s' "$OUT" | tail -3 | tr '\n' '|')"
  elif ! grep -qE '(failure-recording|sweep) arm is broken' <<<"$OUT"; then
    fail "the mutated runner exited 1, but NOT on its sentinel: no '(failure-recording|sweep) arm is broken' line in $(wc -l <<<"$OUT" | tr -d ' ') line(s) of output — the exit came from somewhere else (often the coverage guard's 'executed N of M listed shard(s)', which exits before the sentinel is reachable); tail: $(printf '%s' "$OUT" | tail -3 | tr '\n' '|')"
  else
    pass "a runner that cannot record failures FAILS its own sentinel (rc 1)"
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
  "$FIX/scripts/runner-cheap.sh" >"$FIX/scripts/runner-neutered.sh"
if cmp -s "$FIX/scripts/runner-cheap.sh" "$FIX/scripts/runner-neutered.sh"; then
  fail "the neutered-helper mutation did not change the file"
else
  $FIXTURE_BOUND bash "$FIX/scripts/runner-neutered.sh" >"$TMP/runner-neutered.out" 2>&1
  RC=$?
  OUT="$(cat "$TMP/runner-neutered.out")"
  if [ "$RC" -eq 1 ] && grep -q 'executed 0 of' <<<"$OUT"; then
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
  "$FIX/scripts/runner-cheap.sh" >"$FIX/scripts/runner-counter-only.sh"
$FIXTURE_BOUND bash "$FIX/scripts/runner-counter-only.sh" >"$TMP/runner-counter-only.out" 2>&1
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
# The same inert fixture the other runtime pins execute (built once at the top of this script):
# every listed target is the committed stand-in, so this pair costs ~1 s while keeping the
# runner's own self-check arithmetic (listed == executed) intact.
#
# The stand-in MUST be hermetic: its rc has to depend on nothing but itself. It was
# `scripts/check-no-sigpipe-grep.sh` until 2026-10-23 — a REPO-WIDE guard, so its verdict was a
# function of every file in the tree. Five `printf … | grep -q` idioms in
# `scripts/orchestrator-harness/lander.test.sh` (#2301) therefore reddened THIS control fixture on
# every PR, reported as `the control fixture returned rc 1` — a message that blames the fixture and
# never names the cause (another job's subject, `sigpipe-grep-guard`). Never point `CHEAP` at
# anything whose rc can move without this file changing. See its definition — and the measurement
# of what pointing it at the real list costs — at the top of this script.
awk '
  /^sweep_file\(\) \{/ { print "sweep_file() { :; }"; next }
  { print }
' "$FIX/scripts/runner-cheap.sh" >"$FIX/scripts/runner-nosweepbody.sh"
if cmp -s "$FIX/scripts/runner-cheap.sh" "$FIX/scripts/runner-nosweepbody.sh"; then
  fail "the sweep-body mutation did not change the fixture"
else
  $FIXTURE_BOUND bash "$FIX/scripts/runner-cheap.sh" >"$TMP/runner-cheap.out" 2>&1
  RCC=$?
  OUTC="$(cat "$TMP/runner-cheap.out")"
  if [ "$RCC" -eq 0 ] && grep -q 'file(s) syntax-checked' <<<"$OUTC"; then
    pass "control: the same fixture with the sweep intact PASSES (rc 0)"
  else
    fail "the control fixture returned rc $RCC (want 0): $(printf '%s' "$OUTC" | tail -1)"
  fi
  $FIXTURE_BOUND bash "$FIX/scripts/runner-nosweepbody.sh" >"$TMP/runner-nosweepbody.out" 2>&1
  RC=$?
  OUT="$(cat "$TMP/runner-nosweepbody.out")"
  if [ "$RC" -eq 1 ] && grep -q 'syntax sweep executed no file' <<<"$OUT"; then
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
cheap_runner "$FIX/scripts/runner-cheap-sweep.sh" "$CHEAP"
awk '{ if ($0 ~ /^sweep_file\(\) \{/) { print "sweep_file() { swept=$((swept + 1)); }"; next } print }' \
  "$FIX/scripts/runner-cheap-sweep.sh" >"$FIX/scripts/runner-sweepcounter.sh"
bash "$FIX/scripts/runner-sweepcounter.sh" >"$TMP/runner-sweepcounter.out" 2>&1
RC=$?
OUT="$(cat "$TMP/runner-sweepcounter.out")"
if [ "$RC" -eq 1 ] && grep -q 'sweep arm is broken' <<<"$OUT"; then
  pass "a runner that keeps the sweep counter but does not parse exits 1 (the arm is proven)"
else
  fail "a counter-preserving sweep neuter returned rc $RC (want 1): $(printf '%s' "$OUT" | tail -1)"
fi

echo ""
echo "8r. A SUBSTITUTED-OUT-OF-REPO TARGET → the RUNNER must refuse it"
# The discovery must FIND the target (a glob only yields real files), and it must be a REAL file
# OUTSIDE the checkout, so the refusal under test is the containment check and not an empty list.
printf 'exit 0\n' >"$TMP/not-in-the-repo.sh"
cheap_runner "$TMP/runner-subst.sh" "$TMP/not-in-the-repo.sh"
stage_guard "$TMP"          # this copy's SHARD_ROOT is $TMP itself (see run-bash-shards.sh:100-110)
if cmp -s "$RUNNER" "$TMP/runner-subst.sh"; then
  fail "the substitution mutation did not change the file"
else
  bash "$TMP/runner-subst.sh" >"$TMP/runner-subst.out" 2>&1
  RC=$?
  OUT="$(cat "$TMP/runner-subst.out")"
  if [ "$RC" -eq 1 ] && grep -q 'is not inside this checkout' <<<"$OUT"; then
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
stage_guard "$SYMDIR"
printf 'exit 0\n' >"$TMP/outside-target.sh"
ln -sf "$TMP/outside-target.sh" "$SYMDIR/scripts/linked.sh"
cheap_runner "$SYMDIR/runner.sh" "scripts/linked.sh"
( cd "$SYMDIR" && bash runner.sh ) >"$TMP/runner-symlink.out" 2>&1
RC=$?
OUT="$(cat "$TMP/runner-symlink.out")"
if [ "$RC" -eq 1 ] && grep -q 'is a symlink' <<<"$OUT"; then
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
echo "8am. THE FAILING SHARD IS NAMED — deleting the naming must turn this arm RED (#2643)"
# The runner now prints `❌ FAILED SHARD: <path>` at the point of failure and a recap
# (`❌ failing shard(s): <path,…>`). BOTH are asserted here, because a reader-facing line nobody
# asserts is a line the next refactor deletes with every gate green — and the runner's own runtime
# sentinels CANNOT pin it (the sentinel is deliberately not a listed shard, so a name would be a
# false report on a green run). Non-vacuity is built in: the same fixture with `shard_fail` deleted
# must print NO name, and still exit 1.
#
# ⛔ THE FIXTURE IS A TREE, NOT A REWRITTEN LIST (agent-infra#2609 + #2643 interaction, found by
# THIS arm). #2643 landed on main while the list was still ENUMERATED there, so its fixture rewrote
# `run_shard <path>` lines in a copy of the runner left in `$TMP`. Under DERIVATION there is no such
# line to rewrite, and `-` this is the part that fails silently `-` a copy sitting outside a tree
# anchors its own discovery to the wrong root and refuses (rc 2, list EMPTY), so the arm measured
# the refusal instead of the naming. The layout below mirrors §12's PROBE: a real fixture root the
# copy LIVES in, with discovery narrowed to the two committed stand-ins, one passing and one failing.
NAMED_FAIL="tests/ci-lane-parity/stand-in-fail.sh"
NAMED_FIX="$TMP/named-fixture"
mkdir -p "$NAMED_FIX/scripts" "$NAMED_FIX/tests/ci-lane-parity"
stage_guard "$NAMED_FIX"
# Non-empty sweep: the fixture runner refuses to report success over a sweep that parsed nothing.
printf '#!/bin/bash\n:\n' >"$NAMED_FIX/scripts/sweepable.sh"
cp "$ROOT/$CHEAP" "$NAMED_FIX/$CHEAP"
cp "$ROOT/$NAMED_FAIL" "$NAMED_FIX/$NAMED_FAIL"
# `stand-in-*.sh` matches BOTH, so the passing shard proves the run is not only its failure.
awk -v g="tests/ci-lane-parity/stand-in-*.sh" '
  /^SUITE_GLOBS=\($/ { print "SUITE_GLOBS=( \"" g "\" )"; skip = 1; next }
  skip && /^\)$/ { skip = 0; next }
  skip { next }
  { print }
' "$RUNNER" >"$NAMED_FIX/scripts/runner-named.sh"
env -u BASH_SHARD_SLICE -u BASH_SHARDS_BUDGET_SECS $FIXTURE_BOUND bash "$NAMED_FIX/scripts/runner-named.sh" >"$TMP/runner-onefail.out" 2>&1
RC=$?
OUT="$(cat "$TMP/runner-onefail.out")"
if [ "$RC" -eq 1 ] && grep -qF "❌ FAILED SHARD: $NAMED_FAIL" <<<"$OUT"; then
  pass "a failing shard is NAMED at the point of failure ($NAMED_FAIL), and the run still fails (rc 1)"
else
  fail "a failing shard was not named at the point of failure (rc $RC): $(grep -F 'FAILED SHARD' <<<"$OUT" | head -3)"
fi
if grep -qE '^❌ failing shard\(s\): .*stand-in-fail\.sh' <<<"$OUT"; then
  pass "the RECAP names it too (so grepping the summary does not require walking the log)"
else
  fail "the recap did not name the failing shard: $(grep -F 'failing shard' <<<"$OUT" | head -3)"
fi
# NON-VACUITY: same fixture, the naming call deleted. The run must STILL fail (the counter is
# untouched) and must print NO name — so an arm that passed on any failing run would be caught.
sed 's/\[ "$shard_errors" -ne "$shard_err0" \] && shard_fail "$1"; //' "$NAMED_FIX/scripts/runner-named.sh" >"$NAMED_FIX/scripts/runner-noname.sh"
if cmp -s "$NAMED_FIX/scripts/runner-named.sh" "$NAMED_FIX/scripts/runner-noname.sh"; then
  fail "the no-name mutation did not change the fixture (the naming call moved — update this arm's sed)"
else
  env -u BASH_SHARD_SLICE -u BASH_SHARDS_BUDGET_SECS $FIXTURE_BOUND bash "$NAMED_FIX/scripts/runner-noname.sh" >"$TMP/runner-onefail-noname.out" 2>&1
  RC=$?
  OUT="$(cat "$TMP/runner-onefail-noname.out")"
  if [ "$RC" -eq 1 ] && ! grep -qF 'FAILED SHARD' <<<"$OUT"; then
    pass "with the naming deleted the run still fails and prints NO name — this arm measures the naming, not the count"
  else
    fail "the no-name mutation returned rc $RC and printed: $(grep -F 'FAILED SHARD' <<<"$OUT" | head -3)"
  fi
fi

echo ""
echo "8aa. A SYMLINKED PARENT DIRECTORY → the RUNNER must refuse it"
PARENTDIR="$TMP/parentrepo"
mkdir -p "$PARENTDIR" "$TMP/outside-dir"
printf 'exit 0\n' >"$TMP/outside-dir/stub.sh"
ln -sfn "$TMP/outside-dir" "$PARENTDIR/scripts"
# staged AFTER the symlink exists, so it lands through it exactly where the driver will look.
stage_guard "$PARENTDIR"
cheap_runner "$PARENTDIR/runner.sh" "scripts/stub.sh"
( cd "$PARENTDIR" && bash runner.sh ) >"$TMP/runner-parentsym.out" 2>&1
RC=$?
OUT="$(cat "$TMP/runner-parentsym.out")"
if [ "$RC" -eq 1 ] && grep -q 'resolves outside this checkout' <<<"$OUT"; then
  pass "a symlinked PARENT directory is refused (the leaf check alone would pass it)"
else
  fail "a symlinked parent dir returned rc $RC (want 1): $(printf '%s' "$OUT" | tail -1)"
fi

echo ""
echo "8aQ. THE OVERRUN IS A DIFFERENT NAMED RED FROM A SUITE FAILURE (agent-infra#3174)"
# The step bound (`timeout-minutes`) is the PLATFORM's kill, and a FAILED shard is also `failure`:
# before #3174 those two reds had nothing distinguishing them, so "a suite failed" and "the derived
# list outran its bound" read identically in the check and only a hand diff of two logs told them
# apart. `BASH_SHARDS_BUDGET_SECS` is the runner's own deadline, and this arm proves the two reds
# are now distinguishable AND that neither absorbs the other:
#   * no budget declared      -> the suite failure is named, and NO overrun verdict appears (a
#                                verdict appearing unconditionally would be a permanent false block)
#   * budget exhausted        -> the OVERRUN is named, disclaimed as "NOT a suite failure", and any
#                                real failure is reported SEPARATELY rather than blamed on the bound
#   * a live, unspent budget  -> the suite failure still fails the step (a budget must never absorb a
#                                failure: that is the fail-open this arm exists to catch)
# The slow stand-ins are written into the fixture TREE (`$NAMED_FIX`), never committed: they only have
# to make `shard_time` cross the budget at a point this arm CHOOSES, and a committed 2 s sleep would
# be paid by every run of this suite forever.
# ⛔ THE PROPERTY IS AN INEQUALITY UNDER INTEGER TRUNCATION, NOT "2 + 2 > 3" (review, #3174).
# `shard_note` measures each shard as `$((SECONDS - shard_t0))` — bash's INTEGER `SECONDS` — so a
# `sleep 2` stand-in records **2 or 3** depending on where it straddles a 1 s boundary (measured on
# this repo's own fixture: 54×`2`, 6×`3` in 60 runs). At `BASH_SHARDS_BUDGET_SECS=3` the trip's
# `-ge` therefore fired BEFORE `stand-in-aab-failslow.sh` ran whenever the first stand-in measured 3 —
# `shard_errors` was still 0, no "failed INDEPENDENTLY" line was printed, and the assertion below
# failed on a CORRECT tree (measured: 3 of 40 runs). The budget is 4 so the invariant is
#     first < budget <= first + second
# which holds for EVERY truncation: first ∈ {2,3} < 4, and first + second ∈ {4,5,6} >= 4. The trip still
# lands MID-LOOP (before the third stand-in), which is what the arm exists to exercise.
# ⛔ TWO slow stand-ins, named so they sort FIRST (`aaa`) and SECOND (`aab`), because the arm must
# exercise the MID-LOOP trip: a `zzz`-sorted slow suite only ever reaches the end-of-list trip, where
# `ran + skipped == listed` — so the "NOT RUN" listing (the branch that was fatal in review cycle 2)
# is never entered, and a suite that crashes on every mid-loop trip would stay green here. Measured
# consequence of getting this wrong: 8aQ passed 7 assertions over a line that lost the log to
# `unbound variable` on 100 % of mid-loop trips.
printf '#!/bin/bash\nsleep 2\n' >"$NAMED_FIX/tests/ci-lane-parity/stand-in-aaa-slow.sh"
# A FAILING stand-in that is slow enough to have contributed `shard_time`, so the trip fires AFTER a
# recorded failure: that is what makes the "failed INDEPENDENTLY of the overrun" line reachable. Both
# sleeps stay at 2 and the BUDGET carries the margin (see the invariant above) — lowering this one
# or raising the other only moves which truncation can break the arm.
printf '#!/bin/bash\nsleep 2\nexit 1\n' >"$NAMED_FIX/tests/ci-lane-parity/stand-in-aab-failslow.sh"
# (1) NO budget: exactly §8am's verdict, and no overrun line.
if grep -qF 'SHARD BUDGET EXCEEDED' "$TMP/runner-onefail.out"; then
  fail "an overrun verdict appeared on a run that declared NO budget — a verdict that fires unconditionally is a permanent false block"
else
  pass "no overrun verdict when no budget is declared (0 = no deadline)"
fi
# (2) Budget exhausted (4 s: after ONE stand-in at 2-3 s, at/below it after TWO at 4-6 s): the TRIP
# HAPPENS MID-LOOP, after a recorded failure and with suites still un-run — the production shape, and
# the one cycle 2 proved fatal. 4, not 3: see the truncation invariant above.
env -u BASH_SHARD_SLICE BASH_SHARDS_BUDGET_SECS=4 $FIXTURE_BOUND bash "$NAMED_FIX/scripts/runner-named.sh" >"$TMP/runner-overrun.out" 2>&1
RC=$?
OUT="$(cat "$TMP/runner-overrun.out")"
if [ "$RC" -eq 1 ] && grep -qF '❌ SHARD BUDGET EXCEEDED' <<<"$OUT" && grep -qF 'this is NOT a suite failure' <<<"$OUT"; then
  pass "an exhausted budget fails the step (rc 1) with its OWN NAMED verdict, disclaimed as not a suite failure"
else
  fail "the overrun verdict did not fire or did not disclaim a suite failure (rc $RC): $(grep -F 'BUDGET' <<<"$OUT" | head -2)"
fi
if grep -qF 'BASH_SHARDS_BUDGET_SECS=4' <<<"$OUT" && grep -qE 'failed INDEPENDENTLY of the overrun: .*stand-in-' <<<"$OUT"; then
  pass "…it prints the budget it compared against AND names the real failure SEPARATELY (neither red is laundered into the other)"
else
  fail "the overrun verdict did not separate the budget from the failure: $(grep -F 'INDEPENDENTLY' <<<"$OUT" | head -2)"
fi
# ⛔ THE MID-LOOP TRIP MUST NAME WHAT IT DID NOT RUN (review cycle 2, #3174 — this branch was FATAL:
# `$shard_count_lines` is a function, so `set -u` killed the log with `unbound variable` on 100 % of
# mid-loop trips, i.e. on the production case). Both the count line and at least one per-path line
# must appear, and NO shell error may.
if grep -qF 'NOT RUN —' <<<"$OUT" && grep -qE '⏭  NOT RUN: tests/ci-lane-parity/stand-in-' <<<"$OUT"; then
  pass "a mid-loop trip NAMES the shards it will not attempt (count line + per-path lines) — a short count is a short LIST"
else
  fail "the overrun did not name the shards it never ran: $(grep -F 'NOT RUN' <<<"$OUT" | head -3)"
fi
if grep -qE 'unbound variable|command not found|syntax error' <<<"$OUT"; then
  fail "the overrun verdict ended on a SHELL ERROR, not a message: $(grep -E 'unbound variable|command not found|syntax error' <<<"$OUT" | head -2)"
else
  pass 'the overrun verdict prints no shell error (the fatal shard_count_lines-as-a-variable bug is pinned)'
fi

# set-but-EMPTY is a MISSING VALUE, not the documented "no deadline" — it must be refused, because an
# unset CI variable expands to empty and silently running with no deadline is the fail-open.
env -u BASH_SHARD_SLICE BASH_SHARDS_BUDGET_SECS= $FIXTURE_BOUND bash "$NAMED_FIX/scripts/runner-named.sh" >"$TMP/runner-budgetempty.out" 2>&1
RC=$?
if [ "$RC" -eq 2 ] && grep -qF 'is SET but EMPTY' "$TMP/runner-budgetempty.out"; then
  pass "a SET-but-EMPTY budget is refused (rc 2) instead of meaning 'no deadline'"
else
  fail "a set-but-empty budget returned rc $RC (want 2)"
fi
# (3) A live budget that is NOT spent must not absorb the failure.
env -u BASH_SHARD_SLICE BASH_SHARDS_BUDGET_SECS=99999 $FIXTURE_BOUND bash "$NAMED_FIX/scripts/runner-named.sh" >"$TMP/runner-budgetok.out" 2>&1
RC=$?
OUT="$(cat "$TMP/runner-budgetok.out")"
if [ "$RC" -eq 1 ] && grep -qF "❌ FAILED SHARD: $NAMED_FAIL" <<<"$OUT" && ! grep -qF 'SHARD BUDGET EXCEEDED' <<<"$OUT"; then
  pass "an unspent budget changes nothing: the suite failure still fails the step, named, with no overrun line"
else
  fail "a live budget altered the suite-failure verdict (rc $RC): $(grep -E 'BUDGET|FAILED SHARD' <<<"$OUT" | head -2)"
fi
# (3b) The documented `0` spelling means NO deadline, and it must not be a silent no-op either: a
# SET-but-zero budget that behaved like a tiny deadline would false-block every run.
env -u BASH_SHARD_SLICE BASH_SHARDS_BUDGET_SECS=0 $FIXTURE_BOUND bash "$NAMED_FIX/scripts/runner-named.sh" >"$TMP/runner-budgetzero.out" 2>&1
RC=$?
OUT="$(cat "$TMP/runner-budgetzero.out")"
if [ "$RC" -eq 1 ] && grep -qF "❌ FAILED SHARD: $NAMED_FAIL" <<<"$OUT" && ! grep -qF 'SHARD BUDGET EXCEEDED' <<<"$OUT"; then
  pass "BASH_SHARDS_BUDGET_SECS=0 is the documented 'no deadline' spelling: the failure is named, no overrun line"
else
  fail "a zero budget changed the verdict (rc $RC): $(grep -E 'BUDGET|FAILED SHARD' <<<"$OUT" | head -2)"
fi
# (3c) A budget and a slice are REFUSED together: `shard_time` only accumulates this process's own
# slice, so a whole-list budget over a 1/N share is ~N times too lenient — a silent weakening, so it
# fails closed instead of never binding.
env BASH_SHARD_SLICE=1/2 BASH_SHARDS_BUDGET_SECS=10 $FIXTURE_BOUND bash "$NAMED_FIX/scripts/runner-named.sh" >"$TMP/runner-budgetsliced.out" 2>&1
RC=$?
if [ "$RC" -eq 2 ] && grep -qF 'cannot be combined with BASH_SHARD_SLICE' "$TMP/runner-budgetsliced.out"; then
  pass "a budget combined with a slice is refused (rc 2) instead of silently never binding"
else
  fail "budget+slice returned rc $RC (want 2)"
fi
# (3d) …but `0` is the documented "no deadline" spelling, and it is NOT a budget at all. Refusing it
# alongside a slice is a false block on a documented no-op spelling (review finding, #3174): the
# caller has declared NO deadline, so there is no whole-list/1-N-share mismatch to refuse. Pre-fix
# this returned rc 2 and the run never happened.
env BASH_SHARD_SLICE=1/2 BASH_SHARDS_BUDGET_SECS=0 $FIXTURE_BOUND bash "$NAMED_FIX/scripts/runner-named.sh" >"$TMP/runner-budgetzerosliced.out" 2>&1
RC=$?
OUT="$(cat "$TMP/runner-budgetzerosliced.out")"
if [ "$RC" -eq 1 ] && ! grep -qF 'cannot be combined with BASH_SHARD_SLICE' <<<"$OUT" && ! grep -qF 'SHARD BUDGET EXCEEDED' <<<"$OUT"; then
  pass "BASH_SHARDS_BUDGET_SECS=0 is NOT refused alongside a slice — '0 = no deadline' is not a budget to compose"
else
  fail "a zero budget combined with a slice was refused or changed the verdict (rc $RC): $(grep -E 'BUDGET' <<<"$OUT" | head -2)"
fi
# (4) A budget that is not a number is REFUSED, never silently ignored.
env -u BASH_SHARD_SLICE BASH_SHARDS_BUDGET_SECS=12x $FIXTURE_BOUND bash "$NAMED_FIX/scripts/runner-named.sh" >"$TMP/runner-budgetbad.out" 2>&1
RC=$?
if [ "$RC" -eq 2 ] && grep -qF 'is not a whole number of seconds' "$TMP/runner-budgetbad.out"; then
  pass "a non-numeric BASH_SHARDS_BUDGET_SECS is refused (rc 2), not silently run with no deadline"
else
  fail "a non-numeric budget returned rc $RC (want 2)"
fi
# ⛔ THE TWO SLOW STAND-INS ARE REMOVED HERE, so the arms BELOW see the tree their own comments
# document (review finding, #3174). Leaving them in `$NAMED_FIX` silently re-shaped the attribution
# arm into "four stand-ins, two failing, ~+8 s of sleeps" for every later run of this file — the arm
# still passed, so what drifted was WHAT IT MEASURED. The two COMMITTED stand-ins stay: they are the
# fixture those arms are written against.
rm -f "$NAMED_FIX/tests/ci-lane-parity/stand-in-aaa-slow.sh" "$NAMED_FIX/tests/ci-lane-parity/stand-in-aab-failslow.sh"

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
# ⛔ THE INJECTION MUST LAND INSIDE THE JOB THE GUARD AUDITS (#2482 review, 2026-10-23). An earlier
# revision of this fixture injected a second `strategy:` into `bash-suites` — which broke when that job
# gained a REAL matrix (duplicate mapping key, guard correctly exits 2, so the fixture measured YAML
# duplication rather than the property it names) — and the first repair injected into `drift-check`,
# which is VACUOUS: the guard reads `jobs["bash-suites"]` only, so the injection could not affect any
# assertion it makes. The injection below adds an `os:` LIST to `bash-suites`' EXISTING matrix: no
# duplicate key, the job's own steps stay intact, and the list really does precede `steps:` in the
# job under audit — so if the parser latched the step indent on a list, the call would go unseen and
# the guard would exit 2.
awk '{ print }
     /^        shard: \[1, 2, 3, 4, 5, 6, 7, 8\]$/ { print "        os:"; print "          - ubuntu-latest" }' \
  "$PR" >"$TMP/ci-pr-matrix.yml"
guard_rc "$MAIN" "$TMP/ci-pr-matrix.yml"
if [ "$RC" -eq 0 ]; then
  pass "a strategy/matrix list before steps: does not hide the steps"
else
  fail "a matrix list before steps: false-blocked the call (rc $RC): $OUT"
fi

# ⛔ AND THE GUARD ITSELF CANNOT BE SWITCHED OFF (#2482 review, 2026-10-23). The steps that run this
# guard and its mutation self-test live in a SECOND job (`bash-suites-gate`), so a conditional or a
# non-blocking failure there used to leave this check green over a disabled self-test. Measured on the
# pre-change layout: exit 2; on the matrix layout before this fixture: exit 0.
awk 'BEGIN { done = 0 }
     { print }
     !done && /^  bash-suites-gate:$/ { done = 1; next }
     done && /^      - / { print "        if: false"; done = 2 }
     done == 2 { done = 3 }' \
  "$PR" >"$TMP/ci-pr-gateif.yml"
guard_rc "$MAIN" "$TMP/ci-pr-gateif.yml"
if [ "$RC" -eq 2 ]; then
  pass "an 'if:' on the guard-covering job's first step is refused (the guard cannot be switched off)"
else
  fail "an 'if:' on bash-suites-gate's step returned rc $RC (want 2): $OUT"
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
if [ "$RC" -eq 2 ] && grep -q 'CI_LANE_RUNNER' <<<"$OUT"; then
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
  if [ "$RC" -eq 2 ] && grep -q "$key" <<<"$OUT"; then
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
if [ "$RC" -eq 2 ] && grep -q 'defaults.run.shell' <<<"$OUT"; then
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
# ⛔ THE CONSTRUCTION MOVED WITH THE DESIGN (#2609). A DERIVED list cannot contain a duplicate —
# `LC_ALL=C sort -u` collapses one and the globs are disjoint — so a mutated runner can no longer
# produce this shape. The floor is still worth having: it is the guard's assertion about WHATEVER
# runner it is pointed at (a list is an artifact, not a proof), so it is driven with a stub runner
# that answers `--list` with 13 copies of one path and a valid sweep list.
{
  echo '#!/usr/bin/env bash'
  echo 'case "${1:-}" in'
  echo '  --list) n=0; while [ "$n" -lt 14 ]; do printf "%s\n" "scripts/cheap.sh"; n=$((n + 1)); done; exit 0 ;;'
  echo '  --list-sweeps) printf "%s\n" "scripts/*.sh"; exit 0 ;;'
  echo 'esac'
  echo 'exit 0'
} >"$TMP/runner-dupes.sh"
guard_rc "$MAIN" "$PR" "$TMP/runner-dupes.sh"
if [ "$RC" -eq 2 ] && grep -q 'duplicate' <<<"$OUT"; then
  pass "a runner listing the same script 14 times exits 2 and says why"
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
echo "8am. ATTRIBUTION — a failed shard is NAMED in the verdict, not only counted (#2643)"
# ⛔ WHAT THIS ARM EXISTS FOR. On 2026-10-24 four shards were red on `main` and FOUR PR slices each
# printed `❌ 1 bash shard(s) failed`; the merge rail refused the PR with "yielded NO parseable failure
# identity", and the only way to learn which suite was red was to download an 18,695-line job log and
# bisect it against this runner's own `▸ <secs> <path>` rows. A count is not an identity, so the
# verdict now names its shards. Nothing asserted that, and nothing could: every existing arm here
# asserts COUNTS and SETS (listed==executed, the slice's exact set, the sweep counter), and a red that
# prints nothing still satisfies all of them.
#
# The fixture is the runner with EVERY `run_shard` line pointed at a hermetic stand-in, exactly as
# arms 8d/8e/8h do — with ONE of them pointed at the failing stand-in, so the run is red for a reason
# this arm chose. Three assertions, and the second and third are what make the first mean something:
#   (a) the failing shard's PATH appears in the verdict block;
#   (b) the PASSING stand-in's path does NOT appear there (a block that names every shard satisfies
#       (a) while telling a reader nothing);
#   (c) RED CONTROL — gut the recorder and the run must STILL fail (rc 1, the counter is untouched)
#       while naming nothing. Without (c), (a) could be satisfied by any future line that happens to
#       print a path.
PASS_SHARD="tests/ci-lane-parity/stand-in-shard.sh"
FAIL_SHARD="tests/ci-lane-parity/stand-in-fail.sh"   # the failing file arm 8am above copies in
# ⛔ PORTED TO DERIVATION. This fixture used to rewrite `run_shard <path>` lines in a copy of the
# runner left in `$TMP` — there is no such line any more, and a copy sitting OUTSIDE a tree anchors
# its own discovery to the wrong root and refuses (rc 2, EMPTY list), which would measure the refusal
# instead of the naming. So this arm reuses the tree fixture arm 8am above already built
# (`$NAMED_FIX`: a passing and a failing stand-in, discovery narrowed to `stand-in-*.sh`).
if [ ! -f "$NAMED_FIX/scripts/runner-named.sh" ]; then
  fail "the attribution fixture is missing — arm 8am above must build \$NAMED_FIX before this arm"
elif ! grep -qF 'stand-in-*.sh' "$NAMED_FIX/scripts/runner-named.sh" 2>/dev/null; then
  fail "the attribution fixture was not narrowed to the stand-ins — this arm would run the real list"
else
  # ⛔ RUN IT WHERE IT LIVES. A copy moved to `$TMP` anchors discovery to `$TMP` and refuses (rc 2,
  # EMPTY list); the fixture is only a fixture inside its own tree.
  # ⛔ AND WITH NO INHERITED BUDGET (review finding, #3174): the main lane's shards step exports
  # `BASH_SHARDS_BUDGET_SECS` to EVERY child, so without these `-u` flags this arm's expected verdict
  # would depend on an env value supplied by the workflow — and a budget that fires would SUPPRESS the
  # very verdict shape the arm asserts on. The exemption is now stated here instead of resting on
  # "this suite is `# shard: off` so it never runs as a shard".
  env -u BASH_SHARD_SLICE -u BASH_SHARDS_BUDGET_SECS $FIXTURE_BOUND bash "$NAMED_FIX/scripts/runner-named.sh" >"$TMP/runner-named.out" 2>&1
  RC=$?
  OUT="$(cat "$TMP/runner-named.out")"
  # The verdict block is everything from the `N bash shard(s) failed` line on: the per-shard line is
  # printed mid-run and is NOT what a parser sees at the end, so assert on the block.
  VERDICT="$(sed -n '/bash shard(s) failed/,$p' "$TMP/runner-named.out")"
  if [ "$RC" -eq 1 ] && grep -qF "$FAIL_SHARD" <<<"$VERDICT"; then
    pass "a failed shard is NAMED in the verdict block (rc 1)"
  else
    fail "the verdict did not name the failed shard (rc $RC): $VERDICT"
  fi
  if grep -qF "$PASS_SHARD" <<<"$VERDICT"; then
    fail "the verdict names the PASSING stand-in too — a block naming every shard attributes nothing: $VERDICT"
  else
    pass "…and it names only the shard that actually failed"
  fi
  # RED CONTROL (c): the recorder's body replaced by `: ` — the failure is still COUNTED, so the run is
  # still rc 1; only the name is gone. That is the shape that proves (a) is pinning the recorder.
  # ⛔ ASSERTED ON THE VERDICT SLICE, NEVER ON `$OUT` (review cycle 1). `shard_note` prints a timeline
  # row — `▸ 0s <path>` — for every listed shard whether it passed or failed, so the WHOLE log always
  # contains the failing path and `! grep -qF "$FAIL_SHARD" <<<"$OUT"` would fail this arm on every
  # commit, reddening `bash-suites` for the very reason it exists to attribute.
  awk '{ if ($0 ~ /^shard_record_failure\(\) \{/) { print "shard_record_failure() { :; }"; next } print }' \
    "$NAMED_FIX/scripts/runner-named.sh" >"$NAMED_FIX/scripts/runner-noname.sh"
  if cmp -s "$TMP/runner-named.sh" "$TMP/runner-noname.sh"; then
    fail "the no-name mutation did not change the fixture"
  else
    env -u BASH_SHARD_SLICE -u BASH_SHARDS_BUDGET_SECS $FIXTURE_BOUND bash "$NAMED_FIX/scripts/runner-noname.sh" >"$TMP/runner-noname.out" 2>&1
    RC=$?
    NONAME_VERDICT="$(sed -n '/bash shard(s) failed/,$p' "$TMP/runner-noname.out")"
    if [ "$RC" -eq 1 ] && ! grep -qF "$FAIL_SHARD" <<<"$NONAME_VERDICT"; then
      pass "RED CONTROL: a gutted recorder still fails the run (rc 1) and names nothing in the verdict"
    else
      fail "with the recorder gutted the run returned rc $RC and/or named a shard in the verdict: $NONAME_VERDICT"
    fi
    # …and it must SAY SO rather than end on a bare count: an unnamed failure has to read as unnamed.
    if grep -q 'could NOT be named' <<<"$NONAME_VERDICT"; then
      pass "…and an unnamed failure says so, instead of ending as a silent count"
    else
      fail "an unnamed failure did not announce that it could not be named: $NONAME_VERDICT"
    fi
  fi
fi

echo ""
echo "8an. ATTRIBUTION — a SWEEP failure is named too, so a MIXED run has no un-named red (#2643)"
# ⛔ WHAT THIS ARM EXISTS FOR (#2648 cycle-4 review): the first version named only the shard LOOP, so
# a MIXED run — one listed shard failing PLUS a `bash -n` failure from the syntax sweep — yielded
# exactly ONE identity. The rail's step-1c (`examined > extracted`) then PASSED, and the un-named file
# disappeared from a certificate that named no residual: a truthful refusal turned into a FALSE PASS.
# Nothing reddened if the sweep-naming half were reverted, which is what this arm closes.
#
# The fixture: every `run_shard` points at the PASSING stand-in (so the run is red ONLY because of the
# sweep), and SWEEP_GLOBS is narrowed to a temp dir holding one file with a syntax error. Assert the
# broken file is NAMED in the verdict block and that the run does NOT fall back to `could NOT be named`.
# ⛔ PORTED TO DERIVATION. The old fixture rewrote `SWEEP_GLOBS` and every `run_shard <path>`
# line in a copy of the runner left in `$TMP`. There is no such list line any more, and a copy
# outside a tree refuses (rc 2, EMPTY list) — which would measure the refusal, not the sweep naming.
# So the fixture is a TREE: one passing shard, and a syntax-sweep target with a real syntax error.
SWEEP_FIX="$TMP/sweepname-fixture"
mkdir -p "$SWEEP_FIX/scripts" "$SWEEP_FIX/tests/ci-lane-parity"
stage_guard "$SWEEP_FIX"
printf 'if then\n' >"$SWEEP_FIX/scripts/broken.sh"
printf '#!/bin/bash\nexit 0\n' >"$SWEEP_FIX/tests/ci-lane-parity/pass.sh"
awk '\
  /^SUITE_GLOBS=\($/ { print "SUITE_GLOBS=( \"tests/ci-lane-parity/pass.sh\" )"; skip = 1; next }
  skip && /^\)$/ { skip = 0; next }
  skip { next }
  /^SWEEP_GLOBS=\(/ { print "SWEEP_GLOBS=(\"scripts/*.sh\")"; next }
  { print }
' "$RUNNER" >"$SWEEP_FIX/scripts/runner-sweepname.sh"
if cmp -s "$RUNNER" "$SWEEP_FIX/scripts/runner-sweepname.sh"; then
  fail "the sweep-attribution fixture rewrote neither SWEEP_GLOBS nor SUITE_GLOBS"
else
  $FIXTURE_BOUND bash "$SWEEP_FIX/scripts/runner-sweepname.sh" >"$TMP/runner-sweepname.out" 2>&1
  RC=$?
  SWEEP_VERDICT="$(sed -n '/bash shard(s) failed/,$p' "$TMP/runner-sweepname.out")"
  if [ "$RC" -eq 1 ] && grep -qF "broken.sh" <<<"$SWEEP_VERDICT"; then
    pass "a bash -n failure is NAMED in the verdict block (rc 1)"
  else
    fail "a sweep failure was counted but not named (rc $RC): $SWEEP_VERDICT"
  fi
  if grep -q 'could NOT be named' <<<"$SWEEP_VERDICT"; then
    fail "a sweep failure was left UNNAMED — the rail gets an identity for the other shard and merges: $SWEEP_VERDICT"
  else
    pass "…and the verdict has no un-named remainder (the rail sees every failure)"
  fi
  # RED CONTROL: gut the recorder that the SWEEP calls, and the same run must go back to the count-only
  # verdict — proving this arm pins the sweep's naming rather than any other line that prints a path.
  awk '{ if ($0 ~ /^shard_named_failure\(\) \{/) { print "shard_named_failure() { :; }"; next } print }' \
    "$SWEEP_FIX/scripts/runner-sweepname.sh" >"$SWEEP_FIX/scripts/runner-sweepnoname.sh"
  $FIXTURE_BOUND bash "$SWEEP_FIX/scripts/runner-sweepnoname.sh" >"$TMP/runner-sweepnoname.out" 2>&1
  RC2=$?
  SWEEP_NONAME="$(sed -n '/bash shard(s) failed/,$p' "$TMP/runner-sweepnoname.out")"
  if [ "$RC2" -eq 1 ] && ! grep -qF "broken.sh" <<<"$SWEEP_NONAME" && grep -q 'could NOT be named' <<<"$SWEEP_NONAME"; then
    pass "RED CONTROL: with the naming helper gutted the sweep failure is un-named again (rc 1)"
  else
    fail "the no-name control did not revert to an un-named verdict (rc $RC2): $SWEEP_NONAME"
  fi
fi

echo ""
echo "8ao. FAIL-CLOSED PAST THE DERIVED LIST — a second list must REFUSE, and the call-count arm (#2838)"
# ⛔ WHY THIS IS A RUNTIME ARM AND NOT A TEXT PIN (review finding on #2838). `slice_skips` now
# refuses any call beyond the DERIVED list, declares exactly ONE past-list call (the runtime
# failure-recording sentinel) BY NAME, bounds that budget at 1, and the run also compares the CALL
# count against `$listed`. Measured before this arm existed: `grep -rn 'past_list\|past the derived
# list\|entered run_shard'` matched the runner and NOTHING ELSE — so the refusal, the budget or the
# count check could be deleted (or downgraded to a skip) with every other assertion here green, which
# is the exact vacuity the code comment at the count check claims to survive. The fixture is the
# existing one-stand-in `$FIX` tree, so each arm is one cheap execution, and the mutation is the SHAPE
# the defect actually had: rows appended after the derived loop.
# (a) THE DEFECT'S OWN SHAPE — an UNDECLARED call after the loop refuses instead of running.
awk -v ins="run_shard \"$CHEAP\"\n" \
  '/^  run_shard "\$shard"$/ { inloop = 1 } { print } inloop && /^done$/ { printf "%s", ins; inloop = 0 }' \
  "$FIX/scripts/runner-cheap.sh" >"$FIX/scripts/runner-pastlist.sh"
if cmp -s "$FIX/scripts/runner-cheap.sh" "$FIX/scripts/runner-pastlist.sh"; then
  fail "the past-list mutation did not change the file (the fixture no longer matches the runner's loop)"
else
  $FIXTURE_BOUND bash "$FIX/scripts/runner-pastlist.sh" >"$TMP/runner-pastlist.out" 2>&1
  RC=$?
  OUT="$(cat "$TMP/runner-pastlist.out")"
  if [ "$RC" -eq 1 ] && grep -q 'PAST the derived list' <<<"$OUT"; then
    pass "an UNDECLARED run_shard call past the derived list REFUSES (rc 1) instead of running extra work"
  else
    fail "an undeclared past-list call returned rc $RC (want 1 + 'PAST the derived list'): $OUT"
  fi
  # (b) THE DECLARED BUDGET IS ONE, and it is the SENTINEL's. A second declared call — appended after
  # the sentinel, which is the only shape that gets past the tally arm — must trip the budget and NAME
  # it, so a second sentinel cannot be added without raising `past_list_budget` deliberately.
  cp "$FIX/scripts/runner-cheap.sh" "$FIX/scripts/runner-pastbudget.sh"
  printf '%s\n' 'shard_past_list=1' "run_shard \"$CHEAP\"" 'shard_past_list=0' >>"$FIX/scripts/runner-pastbudget.sh"
  $FIXTURE_BOUND bash "$FIX/scripts/runner-pastbudget.sh" >"$TMP/runner-pastbudget.out" 2>&1
  RC=$?
  OUT="$(cat "$TMP/runner-pastbudget.out")"
  if [ "$RC" -eq 1 ] && grep -q '2 call(s) past the derived list' <<<"$OUT" && grep -q 'declared budget is 1' <<<"$OUT"; then
    pass "a SECOND declared past-list call trips the declared budget (rc 1, 'declared budget is 1')"
  else
    fail "a second declared past-list call returned rc $RC (want 1 + 'declared budget is 1'): $OUT"
  fi
  # (c) NON-VACUITY FOR THE CALL-COUNT ARM — the arm exists for the case the refusal is later
  # downgraded to a skip, so the mutant is exactly that: the UNdeclared refusal becomes a silent,
  # UNCOUNTED skip (a counted skip would red the `executed + skipped == listed` tally instead, which is
  # why the count arm would otherwise be untestable) and the derived loop is duplicated. `ran + skipped`
  # then still equals `$listed`, so ONLY the call count can catch it.
  awk '
    /^      echo "❌ call #/ { print "      return 0"; skipexit = 1; next }
    skipexit && /^      exit 1$/ { skipexit = 0; next }
    { print }
  ' "$FIX/scripts/runner-cheap.sh" >"$TMP/runner-cheap-silentskip.sh"
  if cmp -s "$FIX/scripts/runner-cheap.sh" "$TMP/runner-cheap-silentskip.sh"; then
    fail "the silent-skip mutation did not change the file (the refusal's text moved)"
  else
    # ⛔ ONE-LINE WITH `\n` ESCAPES, NOT A LITERAL MULTI-LINE STRING: BWK awk (macOS's `/usr/bin/awk`)
    # refuses a newline inside a `-v` string ("awk: newline in string"), so the fixture file came out
    # EMPTY and this arm reported "the mutation did not change the file" on every macOS run while
    # passing on the Linux runner. `-v` assignments DO expand `\n`, so the injected text is identical
    # and the arm now measures the runner on both hosts instead of measuring awk's dialect.
    awk -v ins='while IFS= read -r shard; do\n  [ -n "$shard" ] || continue\n  run_shard "$shard"\ndone <<<"$shard_paths"\n' \
      '/^  run_shard "\$shard"$/ { inloop = 1 } { print } inloop && /^done$/ { printf "%s", ins; inloop = 0 }' \
      "$TMP/runner-cheap-silentskip.sh" >"$FIX/scripts/runner-relist.sh"
    $FIXTURE_BOUND bash "$FIX/scripts/runner-relist.sh" >"$TMP/runner-relist.out" 2>&1
    RC=$?
    OUT="$(cat "$TMP/runner-relist.out")"
    if [ "$RC" -eq 1 ] && grep -q 'entered run_shard 2 time(s)' <<<"$OUT"; then
      pass "a RE-READ of the list is caught by the call count even when the skip is silent (rc 1, 2 calls vs 1 listed)"
    else
      fail "a doubled list with a silent skip returned rc $RC (want 1 + 'entered run_shard 2 time(s)'): $OUT"
    fi
    # ⛔ THE CONTROL: delete ONLY the call-count arm from that same mutant and it must go GREEN. That
    # is what makes the assertion above a measurement of the arm rather than of some other check.
    awk '
      /^if \[ \$\(\(slice_calls - past_list_calls\)\) -ne "\$listed" \]; then$/ { skip = 1; next }
      skip { if ($0 == "fi") { skip = 0 }; next }
      { print }
    ' "$FIX/scripts/runner-relist.sh" >"$FIX/scripts/runner-relist-nocount.sh"
    if cmp -s "$FIX/scripts/runner-relist.sh" "$FIX/scripts/runner-relist-nocount.sh"; then
      fail "the count-arm deletion did not change the file (the arm's text moved)"
    else
      $FIXTURE_BOUND bash "$FIX/scripts/runner-relist-nocount.sh" >"$TMP/runner-relist-nocount.out" 2>&1
      RC=$?
      OUT="$(cat "$TMP/runner-relist-nocount.out")"
      if [ "$RC" -eq 0 ] && grep -q '✅ all 1 bash shards passed' <<<"$OUT"; then
        pass "RED CONTROL: with the call-count arm deleted the same doubled list reports GREEN (so the arm is the one that catches it)"
      else
        fail "the count-arm control did not revert to a green run (rc $RC — want 0; something else is red and the arm is unproven): $OUT"
      fi
    fi
  fi
fi

echo ""
echo "8ap. A SHARD MUST NOT BE ABLE TO DRAIN THE LIST (#3079)"
# ⛔ WHAT THIS ARM EXISTS FOR — the largest silent coverage hole this runner has had. The loop used
# to be `while IFS= read -r shard; do run_shard "$shard"; done <<<"$shard_paths"`, so the shard list
# lived on the driver's STDIN and every shard inherited it. A shard that reads stdin therefore
# consumed the lines the driver had not reached yet, the loop simply ENDED — no error, no name — and
# the runner reported `executed 107 of 139 listed shard(s) (0 skipped)`. Measured on main's
# `script-validate` job 2026-10-30: the last timing row was `▸ 60s scripts/pi-reap-idle.test.sh`
# (position 107) and 32 shards — everything sorted after it — never ran on main or on ANY PR, while
# the job was read as "a count mismatch" rather than "32 suites are not covered".
#
# The fixture is three shards where the SECOND one reads stdin to EOF: with the defect it drains
# `drain-c.sh`, so the driver executes 2 of 3 and says so (that is the mutant below). With the fix
# both arms are independently sufficient — the list is read into an ARRAY (a child cannot reach it)
# and every shard is handed `</dev/null` — so this arm also pins each arm's sufficiency, because a
# future refactor that drops one of them must not be able to reintroduce the hole quietly.
DRAIN_FIX="$TMP/drain-fixture"
mkdir -p "$DRAIN_FIX/scripts" "$DRAIN_FIX/tests/ci-lane-parity"
stage_guard "$DRAIN_FIX"
printf '#!/bin/bash\nexit 0\n' >"$DRAIN_FIX/tests/ci-lane-parity/drain-a.sh"
printf '#!/bin/bash\nwhile IFS= read -r _l; do :; done\nexit 0\n' >"$DRAIN_FIX/tests/ci-lane-parity/drain-b.sh"
printf '#!/bin/bash\nexit 0\n' >"$DRAIN_FIX/tests/ci-lane-parity/drain-c.sh"
awk '\
  /^SUITE_GLOBS=\($/ { print "SUITE_GLOBS=( \"tests/ci-lane-parity/drain-*.sh\" )"; skip = 1; next }
  skip && /^\)$/ { skip = 0; next }
  skip { next }
  { print }
' "$RUNNER" >"$DRAIN_FIX/scripts/runner-drain.sh"
if cmp -s "$RUNNER" "$DRAIN_FIX/scripts/runner-drain.sh"; then
  fail "the stdin-drain fixture did not narrow SUITE_GLOBS — it would run the real 139-shard list"
else
  $FIXTURE_BOUND bash "$DRAIN_FIX/scripts/runner-drain.sh" >"$TMP/runner-drain.out" 2>&1
  RC=$?
  OUT="$(cat "$TMP/runner-drain.out")"
  if [ "$RC" -eq 0 ] && grep -q '✅ all 3 bash shards passed' <<<"$OUT"; then
    pass "a shard that reads stdin to EOF does not shorten the run (3 of 3 executed, rc 0)"
  else
    fail "a stdin-draining shard SHORTENED the run (rc $RC — want 0 + 'all 3 bash shards passed'): $OUT"
  fi
  # MUTANT (the pre-fix shape, both arms reverted): the loop reads the list FROM STDIN and the shard
  # inherits it. The run must then reproduce the defect — a SHORT count — and, crucially, NAME the
  # shard it never reached, which the pre-fix message could not.
  awk '
    /^for shard in / { print "while IFS= read -r shard; do"
                       print "  [ -n \"$shard\" ] || continue"
                       print "  run_shard \"$shard\""
                       print "done <<<\"$shard_paths\""
                       inold = 1; next }
    inold { if ($0 == "done") { inold = 0 }; next }
    { print }
  ' "$DRAIN_FIX/scripts/runner-drain.sh" \
    | sed 's| bash "\$1" </dev/null| bash "$1"|' >"$DRAIN_FIX/scripts/runner-drain-mutant.sh"
  if cmp -s "$DRAIN_FIX/scripts/runner-drain.sh" "$DRAIN_FIX/scripts/runner-drain-mutant.sh"; then
    fail "the drain mutant did not change the file — the loop's shape or the shard call moved, and this arm now measures nothing"
  else
    $FIXTURE_BOUND bash "$DRAIN_FIX/scripts/runner-drain-mutant.sh" >"$TMP/runner-drain-mutant.out" 2>&1
    RC=$?
    MOUT="$(cat "$TMP/runner-drain-mutant.out")"
    if [ "$RC" -eq 1 ] && grep -q 'executed 2 of 3 listed shard(s)' <<<"$MOUT"; then
      pass "MUTANT (pre-fix shape): the drain reproduces the defect — executed 2 of 3 (rc 1)"
    else
      fail "the pre-fix mutant did not reproduce the short run (rc $RC — want 1 + 'executed 2 of 3'): $MOUT"
    fi
    if grep -qF 'NEVER RAN: tests/ci-lane-parity/drain-c.sh' <<<"$MOUT"; then
      pass "…and the verdict NAMES the shard that never ran (a count alone cannot say which suite is uncovered)"
    else
      fail "the verdict did not name the un-reached shard (want 'NEVER RAN: tests/ci-lane-parity/drain-c.sh'): $MOUT"
    fi
    if grep -qF 'NEVER RAN: tests/ci-lane-parity/drain-a.sh' <<<"$MOUT" || grep -qF 'NEVER RAN: tests/ci-lane-parity/drain-b.sh' <<<"$MOUT"; then
      fail "the verdict named a shard that DID run — a block naming every shard attributes nothing: $MOUT"
    else
      pass "…and it names ONLY the shard that was skipped over"
    fi
  fi
  # EACH ARM ALONE: revert one at a time. Both must stay green, so neither can be dropped as
  # "redundant" without this arm going red — the belt-and-braces is pinned, not assumed.
  #
  # ⛔ AND THE FIXTURE'S OWN STDIN IS THE LIST, NOT THE CALLER'S (#3099 review). `runner-drain-nostdin`
  # is the driver with `</dev/null` stripped, so its drainer inherits whatever fd 0 the TEST process
  # holds — a TTY, a pipe, an `ssh host 'bash tests/…'`. With neither `timeout` nor `gtimeout`
  # installed (the macOS default, so `$FIXTURE_BOUND` is EMPTY) that is an UNBOUNDED HANG, which
  # falsifies the guarantee stated at `FIXTURE_BOUND`'s definition above; with the bound present it is
  # a red naming the wrong cause (rc 124). And at EOF the arm cannot fail for the reason it names: a
  # shard handed EOF drains nothing whether the list is in an array or on stdin, so it would report
  # "the ARRAY alone is sufficient" for a runner whose array had also been removed. Handing it the
  # LIST fixes both — the shard still gets a stream it COULD drain, so a future refactor that drops the
  # ARRAY while `</dev/null` is absent shortens the run and reds this arm, and the caller's stdin stops
  # mattering.
  printf '%s\n' tests/ci-lane-parity/drain-a.sh tests/ci-lane-parity/drain-b.sh \
                tests/ci-lane-parity/drain-c.sh >"$TMP/drain-stdin.txt"
  sed 's| bash "\$1" </dev/null| bash "$1"|' "$DRAIN_FIX/scripts/runner-drain.sh" >"$DRAIN_FIX/scripts/runner-drain-nostdin.sh"
  if cmp -s "$DRAIN_FIX/scripts/runner-drain.sh" "$DRAIN_FIX/scripts/runner-drain-nostdin.sh"; then
    fail "the </dev/null removal did not change the file — the shard call moved, and this arm now measures the UNMUTATED runner"
  else
    $FIXTURE_BOUND bash "$DRAIN_FIX/scripts/runner-drain-nostdin.sh" <"$TMP/drain-stdin.txt" >"$TMP/runner-drain-nostdin.out" 2>&1
    RC=$?
    if [ "$RC" -eq 0 ] && grep -q '✅ all 3 bash shards passed' "$TMP/runner-drain-nostdin.out"; then
      pass "the ARRAY alone is sufficient (a shard without </dev/null, handed a stream it could drain, still cannot shorten the list)"
    else
      fail "without </dev/null the run still shortened (rc $RC) — the array is not doing the work this arm claims: $(cat "$TMP/runner-drain-nostdin.out")"
    fi
  fi
  awk '
    /^for shard in / { print "while IFS= read -r shard; do"
                       print "  [ -n \"$shard\" ] || continue"
                       print "  run_shard \"$shard\""
                       print "done <<<\"$shard_paths\""
                       inold = 1; next }
    inold { if ($0 == "done") { inold = 0 }; next }
    { print }
  ' "$DRAIN_FIX/scripts/runner-drain.sh" >"$DRAIN_FIX/scripts/runner-drain-stdinloop.sh"
  if cmp -s "$DRAIN_FIX/scripts/runner-drain.sh" "$DRAIN_FIX/scripts/runner-drain-stdinloop.sh"; then
    fail "the loop revert did not change the file — the loop's shape moved, and this arm now measures the UNMUTATED runner"
  else
    $FIXTURE_BOUND bash "$DRAIN_FIX/scripts/runner-drain-stdinloop.sh" >"$TMP/runner-drain-stdinloop.out" 2>&1
    RC=$?
    if [ "$RC" -eq 0 ] && grep -q '✅ all 3 bash shards passed' "$TMP/runner-drain-stdinloop.out"; then
      pass "the </dev/null arm alone is sufficient (a stdin-fed loop cannot be drained when the shard's stdin is closed)"
    else
      fail "with the stdin-fed loop and </dev/null the run still shortened (rc $RC): $(cat "$TMP/runner-drain-stdinloop.out")"
    fi
  fi
  # ⛔ THE SKIP REASON IS PINNED TOO (`#3099` review, P2). `slice_skips` writes `<path>\t<slice i/n>`
  # into `shard_skip_log` and the mismatch verdict prints those lines, but NO fixture ever entered
  # that branch: every arm above induces a mismatch with `(0 skipped)`, so the print could have
  # emitted an empty or garbled line and this suite would still be green — the same "a diagnostic is
  # claimed but nothing measures it" gap the mutant arms exist to close for the other blocks. The
  # fixture below reaches the branch BY CONSTRUCTION: 4 shards, the slice skips position 1, and the
  # shard at position 2 drains the list — so the run ends with one DELIBERATE skip recorded and one
  # shard never reached, which is the only state that prints BOTH the `(1 skipped)` count with its
  # per-shard reasons and the NEVER-RAN list. The GREEN CONTROL on the unmutated runner is part of
  # the arm: without it, a fixture that reds for some unrelated reason would count as proof.
  SKIP_FIX="$TMP/skip-reason-fixture"
  mkdir -p "$SKIP_FIX/scripts" "$SKIP_FIX/tests/ci-lane-parity"
  stage_guard "$SKIP_FIX"
  printf '#!/bin/bash\nexit 0\n' >"$SKIP_FIX/tests/ci-lane-parity/skip-a.sh"
  printf '#!/bin/bash\nexit 0\n' >"$SKIP_FIX/tests/ci-lane-parity/skip-b.sh"
  printf '#!/bin/bash\nwhile IFS= read -r _l; do :; done\nexit 0\n' >"$SKIP_FIX/tests/ci-lane-parity/skip-c.sh"
  printf '#!/bin/bash\nexit 0\n' >"$SKIP_FIX/tests/ci-lane-parity/skip-d.sh"
  awk '\
    /^SUITE_GLOBS=\($/ { print "SUITE_GLOBS=( \"tests/ci-lane-parity/skip-*.sh\" )"; skip = 1; next }
    skip && /^\)$/ { skip = 0; next }
    skip { next }
    { print }
  ' "$RUNNER" >"$SKIP_FIX/scripts/runner-skip.sh"
  if cmp -s "$RUNNER" "$SKIP_FIX/scripts/runner-skip.sh"; then
    fail "the skip-reason fixture did not narrow SUITE_GLOBS — it would run the real shard list"
  else
    BASH_SHARD_SLICE=1/2 $FIXTURE_BOUND bash "$SKIP_FIX/scripts/runner-skip.sh" >"$TMP/runner-skip-control.out" 2>&1
    RC=$?
    if [ "$RC" -eq 0 ] && grep -q 'bash shards passed (slice 1/2 of 4' "$TMP/runner-skip-control.out"; then
      pass "skip-reason CONTROL: the fixed runner executes slice 1/2 of 4 and reports green (rc 0)"
    else
      fail "the skip-reason control run is not green (rc $RC — want 0 + 'bash shards passed (slice 1/2 of 4'): $(cat "$TMP/runner-skip-control.out")"
    fi
    awk '
      /^for shard in / { print "while IFS= read -r shard; do"
                         print "  [ -n \"$shard\" ] || continue"
                         print "  run_shard \"$shard\""
                         print "done <<<\"$shard_paths\""
                         inold = 1; next }
      inold { if ($0 == "done") { inold = 0 }; next }
      { print }
    ' "$SKIP_FIX/scripts/runner-skip.sh" \
      | sed 's| bash "\$1" </dev/null| bash "$1"|' >"$SKIP_FIX/scripts/runner-skip-mutant.sh"
    if cmp -s "$SKIP_FIX/scripts/runner-skip.sh" "$SKIP_FIX/scripts/runner-skip-mutant.sh"; then
      fail "the skip-reason mutant did not change the file — the loop's shape or the shard call moved, and this arm now measures nothing"
    else
      BASH_SHARD_SLICE=1/2 $FIXTURE_BOUND bash "$SKIP_FIX/scripts/runner-skip-mutant.sh" >"$TMP/runner-skip-mutant.out" 2>&1
      RC=$?
      MOUT="$(cat "$TMP/runner-skip-mutant.out")"
      if [ "$RC" -eq 1 ] && grep -q 'executed 2 of 4 listed shard(s) (1 skipped)' <<<"$MOUT"; then
        pass "MUTANT: a mismatch that also SKIPPED a shard reports 'executed 2 of 4 … (1 skipped)' (rc 1)"
      else
        fail "the skip-reason mutant did not report the expected mismatch (rc $RC — want 1 + 'executed 2 of 4 listed shard(s) (1 skipped)'): $MOUT"
      fi
      if grep -qF '⏭  SKIPPED: tests/ci-lane-parity/skip-b.sh (slice 1/2)' <<<"$MOUT"; then
        pass "…and the verdict PRINTS the skipped shard WITH its reason ('slice 1/2') — skipped=N is never an unexplained shortfall"
      else
        fail "the verdict printed no per-shard skip reason (want '⏭  SKIPPED: tests/ci-lane-parity/skip-b.sh (slice 1/2)'): $MOUT"
      fi
      if grep -qF 'NEVER RAN: tests/ci-lane-parity/skip-d.sh' <<<"$MOUT"; then
        pass "…and the same block still NAMES the shard the drain skipped over (skip-d.sh) — the reason print did not displace the set difference"
      else
        fail "the skip-reason block displaced the NEVER-RAN naming (want 'NEVER RAN: tests/ci-lane-parity/skip-d.sh'): $MOUT"
      fi
    fi
  fi
fi

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

# ⛔ A SECOND PARSER OF THE OLD SHAPE IS HOW THIS CHANGE WENT RED TWICE IN REVIEW (#2609): two
# suites asserted their own membership by grepping the driver's TEXT for their own filename. That
# only ever worked because the list was enumerated — and it went red the moment it was derived,
# while telling the next lane to hand-edit the driver. Pinning "the driver names no suite" means
# that shape can never come back: a text-grep membership check can no longer pass, so it fails
# loudly at the suite instead of silently asserting a list that is not there.
if grep -qE '^[[:space:]]*run_shard[[:space:]]+[^"$]' "$RUNNER"; then
  fail "the runner still carries an ENUMERATED 'run_shard <path>' line — the list is supposed to be derived"
else
  pass "the runner carries no enumerated 'run_shard <path>' line (a text-grep membership check cannot pass)"
fi

echo ""
echo "12. DERIVATION — the list is DISCOVERED from the tree, not enumerated (#2609)"
# ⛔ THE GATE THIS SECTION EXISTS FOR: no suite may silently disappear from CI. Two halves:
#   (a) at REPO level, every discovered suite is either in `--list` or declares `# shard: off
#       <reason>` in its own header — so a glob that stopped matching, or a suite that arrived
#       without a marker, is caught HERE rather than by the suite quietly never running;
#   (b) in a FIXTURE repo, a new suite is picked up with NO edit to the runner at all.
# The enumeration below is deliberately an INDEPENDENT re-statement of the discovery conventions:
# a check that asked the runner what it discovered could not see a convention that narrowed.
LIST_ALL="$(bash "$RUNNER" --list 2>/dev/null)"
unlisted() {
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -qxF "$f" <<<"$LIST_ALL" && continue
    # A reason is REQUIRED and it must be more than whitespace: `# shard: off` followed by spaces
    # used to read as a declared opt-out while the runner refused it (#2609 review) — the two
    # parsers disagreed, which is how a suite gets dropped by a trailing space.
    grep -qE '^# shard: off[[:space:]]+[^[:space:]]' <<<"$(sed -n '1,20p' "$f" 2>/dev/null)" && continue
    printf '%s\n' "$f"
  done
}
DISCOVERED="$( { for g in "scripts/*.test.sh" "scripts/*/*.test.sh" \
      "scripts/orchestrator-harness/test-*.sh" "scripts/orchestrator-harness/selftest.sh" \
      "tests/*/run.sh" "pi-bootstrap/tests/*.sh"; do
    for f in $g; do [ -f "$f" ] || continue; printf '%s\n' "$f"; done
  done; } | LC_ALL=C sort -u )"
OFFENDERS="$(unlisted <<<"$DISCOVERED")"
if [ -z "$OFFENDERS" ]; then
  pass "every discovered suite is in --list or declares '# shard: off <reason>' ($(grep -c . <<<"$DISCOVERED") discovered)"
else
  fail "suite(s) discovered but NEITHER listed NOR opted out with a reason: $(tr '\n' ' ' <<<"$OFFENDERS")"
fi
# NON-VACUITY: the check must be able to report an offender, or the pass above means nothing.
GHOST_OFFENDERS="$(unlisted <<<"$DISCOVERED
scripts/zzz-ghost-suite.test.sh")"
if grep -qxF 'scripts/zzz-ghost-suite.test.sh' <<<"$GHOST_OFFENDERS"; then
  pass "control: an unlisted, unmarked suite IS reported (the check is not vacuous)"
else
  fail "control: an unlisted, unmarked suite was NOT reported — the assertion above is vacuous"
fi

# ── (b) the fixture repo: discovery, opt-out, order, and a NAMED failure ─────────────────────
PROBE="$TMP/probe-repo"
mkdir -p "$PROBE/tests/zzz-probe" "$PROBE/tests/zzz-off" "$PROBE/tests/aaa" "$PROBE/scripts"
stage_guard "$PROBE"
cp "$RUNNER" "$PROBE/scripts/runner.sh"
# A sweepable file, so the fixture runner's own sweep self-check has work to do (it refuses to
# report success over a sweep that parsed nothing).
printf '#!/bin/bash\n:\n' >"$PROBE/scripts/sweepable.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "ZZZ-PROBE-RAN"\n' >"$PROBE/tests/zzz-probe/run.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "ZZZ-AAA-RAN"\n' >"$PROBE/tests/aaa/run.sh"
printf '#!/bin/bash\n# shard: off fixture: exists only to prove a DECLARED opt-out is not run\nprintf "%%s\\n" "ZZZ-OFF-RAN"\n' \
  >"$PROBE/tests/zzz-off/run.sh"
PROBE_LIST="$( cd "$PROBE" && bash scripts/runner.sh --list 2>&1 )"
RCL=$?
if [ "$RCL" -eq 0 ] && grep -qx 'tests/zzz-probe/run.sh' <<<"$PROBE_LIST"; then
  pass "a suite that matches a discovery glob is LISTED with no edit to the runner (the #2609 defect)"
else
  fail "a newly added suite was not discovered (rc $RCL): $(tr '\n' ' ' <<<"$PROBE_LIST")"
fi
if grep -qx 'tests/zzz-off/run.sh' <<<"$PROBE_LIST"; then
  fail "a suite carrying '# shard: off <reason>' was still LISTED"
else
  pass "a suite carrying '# shard: off <reason>' is NOT listed (and the reason is required, below)"
fi
# ⛔ Determinism: `tests/zzz-*` was created BEFORE `tests/aaa`, so a filesystem-order list would
# put zzz first. The list must be `LC_ALL=C sort -u` — the same on every machine, and stable.
PROBE_LIST2="$( cd "$PROBE" && bash scripts/runner.sh --list 2>&1 )"
if [ "$PROBE_LIST" = "$PROBE_LIST2" ] && [ "$PROBE_LIST" = "$(LC_ALL=C sort <<<"$PROBE_LIST")" ]; then
  pass "the list is LC_ALL=C sorted and identical across runs (creation order cannot leak in)"
else
  fail "the list is not deterministically sorted: [$(tr '\n' '|' <<<"$PROBE_LIST")]"
fi
# The opt-out is a SKIP, not merely an omission: the suite's body must not execute.
PROBE_RUN="$( cd "$PROBE" && bash scripts/runner.sh 2>&1 )"
PROBE_RC=$?
if [ "$PROBE_RC" -eq 0 ] && grep -q 'ZZZ-PROBE-RAN' <<<"$PROBE_RUN" && ! grep -q 'ZZZ-OFF-RAN' <<<"$PROBE_RUN"; then
  pass "the discovered suite RUNS and the opted-out suite does NOT execute"
else
  fail "discovery and opt-out disagree (rc $PROBE_RC): $(tr '\n' '|' <<<"$PROBE_RUN")"
fi
# ⛔ The fail-closed direction: a marker with NO reason must REFUSE, never degrade to skip or run.
mkdir -p "$PROBE/tests/zzz-noreason"
printf '#!/bin/bash\n# shard: off\nexit 0\n' >"$PROBE/tests/zzz-noreason/run.sh"
NOREASON="$( cd "$PROBE" && bash scripts/runner.sh --list 2>&1 )"
RC="$?"
if [ "$RC" -eq 2 ] && grep -q 'zzz-noreason' <<<"$NOREASON" && grep -q 'NO reason' <<<"$NOREASON"; then
  pass "'# shard: off' with NO reason REFUSES the run (rc 2) and names the suite"
else
  fail "a reasonless opt-out returned rc $RC (want 2, naming the suite): $(tr '\n' '|' <<<"$NOREASON")"
fi
printf '#!/bin/bash\n# shard: maybe later\nexit 0\n' >"$PROBE/tests/zzz-noreason/run.sh"
BOGUS="$( cd "$PROBE" && bash scripts/runner.sh --list 2>&1 )"
RC="$?"
if [ "$RC" -eq 2 ] && grep -q 'unrecognised shard marker' <<<"$BOGUS"; then
  pass "an unrecognised '# shard:' marker REFUSES the run (rc 2) rather than guessing"
else
  fail "an unrecognised marker returned rc $RC (want 2): $(tr '\n' '|' <<<"$BOGUS")"
fi
rm -rf "$PROBE/tests/zzz-noreason"
mkdir -p "$PROBE/tests/zzz-blankreason"
printf '#!/bin/bash\n# shard: off   \nexit 0\n' >"$PROBE/tests/zzz-blankreason/run.sh"
BLANK="$( cd "$PROBE" && bash scripts/runner.sh --list 2>&1 )"
RC="$?"
if [ "$RC" -eq 2 ] && grep -q 'zzz-blankreason' <<<"$BLANK" && grep -q 'NO reason' <<<"$BLANK"; then
  pass "a marker with only WHITESPACE after it REFUSES the run (rc 2) — a trailing space is not a reason"
else
  fail "a whitespace-only reason returned rc $RC (want 2, naming the suite): $(tr '\n' '|' <<<"$BLANK")"
fi
rm -rf "$PROBE/tests/zzz-blankreason"
# ⛔ The attribution half of #2609: a failing shard must be NAMED, not counted anonymously.
mkdir -p "$PROBE/tests/zzz-fail"
printf '#!/bin/bash\nexit 3\n' >"$PROBE/tests/zzz-fail/run.sh"
FAILRUN="$( cd "$PROBE" && bash scripts/runner.sh 2>&1 )"
RC="$?"
if [ "$RC" -eq 1 ] && grep -q 'SHARD FAILED (rc 3): tests/zzz-fail/run.sh' <<<"$FAILRUN" \
   && grep -qE '^❌ failing shard\(s\): .*zzz-fail/run\.sh' <<<"$FAILRUN"; then
  pass "a failing shard is NAMED inline and in the summary (rc 1, not an anonymous count)"
else
  fail "a failing shard was not named (rc $RC): $(tr '\n' '|' <<<"$FAILRUN")"
fi
rm -rf "$PROBE/tests/zzz-fail"

# ── the SLICE arithmetic over a DERIVED list (#2609 rewired its input) ─────────────────────────
# The slice code reads the same derived variable as the execution loop, so this pins that the
# round-robin still deals every suite EXACTLY once across the slices — and, because a count-only
# assertion is blind to "the right number of the WRONG shards", that the identity check fires on a
# broken modulus at a width that divides the list evenly (9 shards / 3 slices).
PROBE2="$TMP/slice-repo"
mkdir -p "$PROBE2/scripts"
stage_guard "$PROBE2"
cp "$RUNNER" "$PROBE2/scripts/runner.sh"
printf '#!/bin/bash\n:\n' >"$PROBE2/scripts/sweepable.sh"
for i in 1 2 3 4 5 6 7 8 9; do
  mkdir -p "$PROBE2/tests/s$i"
  printf '#!/bin/bash\nexit 0\n' >"$PROBE2/tests/s$i/run.sh"
done
SLICE_OK=1
SLICE_SEEN=""
for i in 1 2 3; do
  SLICE_OUT="$( cd "$PROBE2" && BASH_SHARD_SLICE=$i/3 bash scripts/runner.sh 2>&1 )"
  SLICE_RC=$?
  SLICE_N="$(grep -c '  ▸' <<<"$SLICE_OUT")"
  [ "$SLICE_RC" -eq 0 ] || SLICE_OK=0
  [ "$SLICE_N" = 3 ] || SLICE_OK=0
  SLICE_SEEN="$SLICE_SEEN$(grep '  ▸' <<<"$SLICE_OUT" | sed 's/.*tests/tests/' | tr '\n' ' ')"
done
if [ "$SLICE_OK" -eq 1 ] && [ "$(grep -o 'tests/s[0-9]' <<<"$SLICE_SEEN" | LC_ALL=C sort -u | grep -c .)" = 9 ]; then
  pass "three slices of a 9-shard derived list run 3 each and cover all 9 (rc 0, no double-run)"
else
  fail "slice coverage is wrong (ok=$SLICE_OK, seen: $SLICE_SEEN)"
fi
# NON-VACUITY: every slice running slice-1's set keeps the COUNT right (9 % 3 == 0 ⇒ 3 each) and
# must still fail — on the SET, not on the number.
awk '{ if ($0 ~ /-eq "\$slice_index" \] && return 1/) { sub(/-eq "\$slice_index"/, "-eq 0"); print; next } print }' \
  "$RUNNER" >"$PROBE2/scripts/runner-badmod.sh"
if cmp -s "$RUNNER" "$PROBE2/scripts/runner-badmod.sh"; then
  fail "the broken-modulus mutation did not change the runner"
fi
BADMOD_OUT="$( cd "$PROBE2" && BASH_SHARD_SLICE=2/3 bash scripts/runner-badmod.sh 2>&1 )"
BADMOD_RC=$?
if [ "$BADMOD_RC" -eq 1 ] && grep -q 'executed a DIFFERENT SET' <<<"$BADMOD_OUT"; then
  pass "control: a broken modulus that keeps the COUNT right is caught by the SET assertion"
else
  fail "a broken modulus was not caught on the set (rc $BADMOD_RC): $(printf '%s' "$BADMOD_OUT" | tail -2 | tr '\n' '|')"
fi

echo ""
if [ "$failures" -eq 0 ]; then
  echo "✅ ci-lane-parity suite passed (${checks} assertions)"
  exit 0
fi
echo "❌ ci-lane-parity suite: $failures of $checks assertion(s) failed"
exit 1
