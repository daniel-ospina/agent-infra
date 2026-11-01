#!/bin/bash
# tests/run-bash-shards-bound/run.sh — #3187: a HUNG shard is BOUNDED, NAMED, and the shards after
# it still run.
#
# THE DEFECT THIS PINS (measured, not hypothetical)
# -------------------------------------------------
#   Shard #103 of 148 on main's `script-validate` (`scripts/orchestrator-harness/selftest.sh`) hung
#   for 82 minutes inside a child with 0.00 s CPU. `run_shard` ran `bash "$1" </dev/null` with NO
#   per-shard bound, so the only bound was the STEP's — and when it fired, shards #104–#148 (45 of
#   them) had never run at all. The reported failing set then SHRANK across runs (13 → 11 → 10)
#   because fewer shards executed before the kill, not because anything was fixed.
#
# WHAT THIS SUITE ASSERTS (and why each assertion is here)
# --------------------------------------------------------
#   1. A shard that outlives `SHARD_BOUND` reds the run (rc 1) instead of hanging the step.
#   2. It is NAMED in the recap with a distinguishable `TIMEOUT after <n>s` marker, and it is also
#      in `❌ failing shard(s): …` — the line `scripts/ci_exemption.py` splits into
#      `bash-shard::<path>` identities, so the rail can attribute a hang like any other red.
#   3. A shard sorted AFTER the hang STILL RUNS and is reported (its `▸ <secs> <path>` row and its
#      own output are both present) — this is the whole point: a hang costs ONE shard.
#   4. NO ORPHAN SURVIVES: the hang's own pid AND the pid of the child it spawned are dead after the
#      kill. A wrapper-only kill (the obvious implementation) leaves the child — which is exactly
#      where #103's 0.00 s CPU was — running for the rest of the step.
#   5. The bound that applied is REPORTED (header and recap), so a truncated run is self-describing,
#      and the default is 1800 s — 1.65× the slowest shard measured (1092 s).
#   6. `SHARD_BOUND=0` DISABLES the bound (a lane may legitimately want none) and a non-integer
#      REFUSES rather than silently running unbounded.
#   7. The timeout marker does NOT leak into the identity list (`bash-shard::<path>` stays a clean
#      path) — a marker inside a name is a phantom identity that would false-BLOCK every lane.
#
# HERMETIC: a throwaway fixture tree, its own shards, no network, no host state. The hang is
# `sleep 30`, and the bound is 2 s, so the whole suite is a few seconds — never 30 minutes.
#
# STYLE NOTE: the runner is never wrapped in a command substitution (`$(… bash …)`); each
# invocation writes to a file and the file is read after. `extensions/main-worktree-guard` treats a
# shell invocation wrapped that way as an unsanctioned-discard risk and fails closed (see
# tests/ci-lane-parity/run.sh), and every "does this output contain X" test is `grep -q … <<<"$OUT"`
# or `grep -q … <file>` — never a `printf` piped into `grep -q`, which takes SIGPIPE under
# `set -o pipefail` and reports a false failure on a payload that was there.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER="$ROOT/scripts/run-bash-shards.sh"
HELPER="$ROOT/scripts/orchestrator-harness/fixture-hermetic.sh"
EXEMPTION="$ROOT/scripts/ci_exemption.py"
# The runner discoveries are relative to the tree it LIVES in, so run from the checkout root (CI
# does; an interactive run from elsewhere would otherwise see a different list).
cd "$ROOT" || exit 1

checks=0
failures=0
pass() { checks=$((checks + 1)); echo "   ✅ $1"; }
fail() { checks=$((checks + 1)); echo "   ❌ $1"; failures=$((failures + 1)); }

if [ ! -r "$RUNNER" ] || [ ! -r "$HELPER" ]; then
  echo "❌ run-bash-shards-bound: cannot read the runner or the placement-guard helper — refusing to report on a suite that did not run"
  exit 2
fi

TMP="$(mktemp -d)"
# ⛔ THE FIXTURE MUST NOT ASK THE HOST'S PROCESS TABLE ANYTHING. `run-bash-shards.sh` sources the
# #3011 placement guard and REFUSES to run when a live cell root is detected; a fixture that keeps
# the default root set would make this suite's verdict depend on whether the machine happens to be
# running a cell controller. An explicit EMPTY value (no colon) is the helper's advertised seam for
# "no roots" — the same line tests/ci-lane-parity/run.sh uses.
FIXTURE_LIVE_ROOTS=; export FIXTURE_LIVE_ROOTS
trap 'rm -rf "$TMP"' EXIT

# stage_fixture <root> <hang-seconds> [<hang-exit-rc>] — a miniature checkout the REAL runner runs.
#
#   tests/aaa-before/run.sh  prints BEFORE-RAN and exits 0
#   tests/mmm-hang/run.sh    records its own pid and its CHILD's pid, then sleeps <hang-seconds>
#   tests/zzz-after/run.sh   prints AFTER-RAN and exits 0
#
# `LC_ALL=C sort -u` puts them in that order, so the hang is in the MIDDLE and a shard sorted after
# it exists to be swallowed by a runner that stutters at the first hang (the #3187 shape).
stage_fixture() {
  local root="$1" hang="$2"
  mkdir -p "$root/scripts/orchestrator-harness" \
    "$root/tests/aaa-before" "$root/tests/mmm-hang" "$root/tests/zzz-after"
  # The driver sources this and REFUSES (exit 2) when the load fails — deliberately fail-closed.
  cp "$HELPER" "$root/scripts/orchestrator-harness/fixture-hermetic.sh"
  cp "$RUNNER" "$root/scripts/runner.sh"
  # A sweepable file, so the runner's own `swept` sentinel has work to do (it refuses to report
  # success over a syntax sweep that parsed nothing).
  printf '#!/bin/bash\n:\n' >"$root/scripts/sweepable.sh"
  printf '#!/bin/bash\nprintf "%%s\\n" "BEFORE-RAN"\nexit 0\n' >"$root/tests/aaa-before/run.sh"
  printf '#!/bin/bash\nprintf "%%s\\n" "AFTER-RAN"\nexit 0\n' >"$root/tests/zzz-after/run.sh"
  {
    printf '#!/bin/bash\n'
    printf '# the hung shard: it blocks INSIDE A CHILD, like shard #103 of 148 did\n'
    printf 'mkdir -p "$HANG_PID_DIR" 2>/dev/null\n'
    printf 'printf "%%s\\n" "$$" >>"$HANG_PID_DIR/self.pid"\n'
    printf 'sleep %s &\n' "$hang"
    printf 'printf "%%s\\n" "$!" >>"$HANG_PID_DIR/child.pid"\n'
    printf 'wait\n'
    printf 'exit 0\n'
  } >"$root/tests/mmm-hang/run.sh"
  chmod +x "$root/tests/mmm-hang/run.sh" "$root/tests/aaa-before/run.sh" "$root/tests/zzz-after/run.sh"
}

# ⛔ NO HELPER WRAPS THE `bash` INVOCATION. `extensions/main-worktree-guard` treats a shell invocation
# wrapped in a command substitution as an unsanctioned-discard risk and fails closed (see
# tests/ci-lane-parity/run.sh), so each fixture run below is written out at its call site with its
# output in a file.

echo "1. A SHARD THAT OUTLIVES THE BOUND IS KILLED, NAMED, AND DOES NOT SWALLOW THE LIST (#3187)"
FIX="$TMP/fixture"
stage_fixture "$FIX" 30
T0="$(date +%s)"
HANG_PID_DIR="$TMP/pids" SHARD_BOUND=2 bash "$FIX/scripts/runner.sh" >"$TMP/bound.out" 2>&1
RC=$?
T1="$(date +%s)"
ELAPSED=$((T1 - T0))
OUT="$(cat "$TMP/bound.out")"

if [ "$RC" -eq 1 ]; then
  pass "a hung shard reds the run (rc 1) instead of hanging it"
else
  fail "a hung shard returned rc $RC (want 1): $(printf '%s' "$OUT" | tail -3 | tr '\n' '|')"
fi
# Non-vacuity for the BOUND itself: without it the run would still be sitting in `sleep 30`.
if [ "$ELAPSED" -lt 25 ]; then
  pass "the bound fired early: the run took ${ELAPSED}s against a 30s hang (the shard was killed, not awaited)"
else
  fail "the run took ${ELAPSED}s against a 30s hang — the per-shard bound did not cut it short"
fi
if grep -qE '^⏱  TIMEOUT after 2s \(SHARD_BOUND\): .*tests/mmm-hang/run\.sh' <<<"$OUT"; then
  pass "the recap NAMES the hung shard with a distinguishable 'TIMEOUT after 2s' marker"
else
  fail "the recap carries no 'TIMEOUT after 2s … tests/mmm-hang/run.sh' line: $(grep -E 'TIMEOUT|failing shard' <<<"$OUT" | tr '\n' '|')"
fi
if grep -qE '^❌ failing shard\(s\): .*tests/mmm-hang/run\.sh$' <<<"$OUT"; then
  pass "the hung shard reaches the verdict's identity line, so the rail can attribute it"
else
  fail "the hung shard is absent from '❌ failing shard(s): …': $(grep -E 'failing shard' <<<"$OUT" | tr '\n' '|')"
fi
if grep -q 'BEFORE-RAN' <<<"$OUT"; then
  pass "the shard BEFORE the hang ran"
else
  fail "the shard before the hang did not run"
fi
# ⛔ THE HEADLINE ASSERTION: a shard sorted AFTER the hang still runs and is still reported. This is
# what failed on main — 45 shards after #103 never executed at all.
if grep -q 'AFTER-RAN' <<<"$OUT" && grep -qE '^  ▸ +[0-9]+s  tests/zzz-after/run\.sh$' <<<"$OUT"; then
  pass "the shard AFTER the hang STILL RAN and is reported (its own output plus its timing row)"
else
  fail "the shard after the hang did not run or was not reported: after-marker=$(grep -c 'AFTER-RAN' <<<"$OUT") row=$(grep -cE '^  ▸ .*tests/zzz-after/run\.sh$' <<<"$OUT")"
fi
if grep -qE '^  ▸ +[0-9]+s  tests/mmm-hang/run\.sh$' <<<"$OUT"; then
  pass "the killed shard still carries a timing row (it is accounted for, not silently dropped)"
else
  fail "the killed shard has no ▸ timing row"
fi

echo ""
echo "2. NO ORPHAN SURVIVES THE KILL — the whole PROCESS GROUP dies, not just the wrapper"
# ⛔ `run_shard` used to run the suite in the driver's own process group, and shard #103 hung inside
# a CHILD whose CPU was 0.00 s. A wrapper-only kill leaves that child alive for the rest of the step,
# so this asserts BOTH pids: the shard's own and the child it backgrounded.
ORPHANS=""
for _f in self.pid child.pid; do
  [ -f "$TMP/pids/$_f" ] || continue
  while IFS= read -r _pid; do
    [ -n "$_pid" ] || continue
    # Give the TERM→KILL escalation its second before deciding; NEVER wait on it indefinitely.
    _n=0
    while kill -0 "$_pid" 2>/dev/null && [ "$_n" -lt 5 ]; do sleep 1; _n=$((_n + 1)); done
    if kill -0 "$_pid" 2>/dev/null; then
      ORPHANS="$ORPHANS $_f=$_pid"
      kill -KILL "$_pid" 2>/dev/null
    fi
  done <"$TMP/pids/$_f"
done
if [ -z "$ORPHANS" ]; then
  pass "no orphan: the hung shard AND the child it spawned are both gone after the bound"
else
  fail "ORPHANED process(es) survived the per-shard bound:$ORPHANS (a wrapper-only kill is not a bound)"
fi

# ⛔ NON-VACUITY CONTROL: the assertion above must be able to SEE an orphan. The obvious wrong
# implementation — kill the wrapper's pid and nothing else — is built here by deleting the group
# (`-"$pid"`) from the kill, and the CHILD MUST SURVIVE it. Without this arm, "no orphan" could be
# passing because nothing ever spawned one.
MUTFIX="$TMP/mutf"
stage_fixture "$MUTFIX" 30
sed 's/-"\$shard_bg_pid"/"$shard_bg_pid"/g' \
  "$MUTFIX/scripts/runner.sh" >"$TMP/runner-wrapper-only.sh"
if cmp -s "$MUTFIX/scripts/runner.sh" "$TMP/runner-wrapper-only.sh"; then
  fail "the wrapper-only mutation did not change the runner — the orphan assertion has no control"
else
  cp "$TMP/runner-wrapper-only.sh" "$MUTFIX/scripts/runner.sh"
  HANG_PID_DIR="$TMP/pids-control" SHARD_BOUND=2 bash "$MUTFIX/scripts/runner.sh" >"$TMP/wrapper-only.out" 2>&1
  CTRL_ORPHAN=""
  if [ -f "$TMP/pids-control/child.pid" ]; then
    while IFS= read -r _pid; do
      [ -n "$_pid" ] || continue
      _n=0
      while kill -0 "$_pid" 2>/dev/null && [ "$_n" -lt 3 ]; do sleep 1; _n=$((_n + 1)); done
      if kill -0 "$_pid" 2>/dev/null; then CTRL_ORPHAN="$_pid"; kill -KILL "$_pid" 2>/dev/null; fi
    done <"$TMP/pids-control/child.pid"
  fi
  if [ -n "$CTRL_ORPHAN" ]; then
    pass "control: a wrapper-only kill DOES leave the shard's child running (pid $CTRL_ORPHAN) — the orphan assertion is not vacuous"
  else
    fail "control: a wrapper-only kill left no orphan, so the 'no orphan' assertion above cannot distinguish a group kill from a bare-pid kill"
  fi
fi

# ⛔ AND A SUITE THAT TRAPS TERM MUST STILL DIE. A TERM-only implementation is defeated by one line
# (`trap '' TERM`), and a bound that a suite can opt out of is not a bound.
echo ""
echo "2b. A SHARD THAT IGNORES SIGTERM IS STILL KILLED BY THE BOUND"
TERMFIX="$TMP/termf"
stage_fixture "$TERMFIX" 30
{
  printf '#!/bin/bash\n'
  printf 'trap "" TERM\n'
  printf 'mkdir -p "$HANG_PID_DIR" 2>/dev/null\n'
  printf 'printf "%%s\\n" "$$" >>"$HANG_PID_DIR/self.pid"\n'
  printf 'while :; do sleep 1; done\n'
} >"$TERMFIX/tests/mmm-hang/run.sh"
T0="$(date +%s)"
HANG_PID_DIR="$TMP/pids-term" SHARD_BOUND=2 bash "$TERMFIX/scripts/runner.sh" >"$TMP/term.out" 2>&1
RC=$?
T1="$(date +%s)"
ELAPSED=$((T1 - T0))
TOUT="$(cat "$TMP/term.out")"
if [ -f "$TMP/pids-term/self.pid" ]; then
  while IFS= read -r _pid; do
    [ -n "$_pid" ] || continue
    kill -KILL "$_pid" 2>/dev/null
  done <"$TMP/pids-term/self.pid"
fi
if [ "$RC" -eq 1 ] && [ "$ELAPSED" -lt 25 ] && grep -q 'TIMEOUT after 2s' <<<"$TOUT" \
   && grep -q 'AFTER-RAN' <<<"$TOUT"; then
  pass "a TERM-trapping shard is KILLed after the bound (rc 1, ${ELAPSED}s, named) and the list still finishes"
else
  fail "a TERM-trapping shard outlived the bound (rc $RC, ${ELAPSED}s): $(printf '%s' "$TOUT" | tail -3 | tr '\n' '|')"
fi

echo ""
echo "3. THE BOUND IS REPORTED, AND THE DOCUMENTED DEFAULT IS 1800s"
if grep -q 'per-shard bound: 2s per shard' <<<"$OUT"; then
  pass "the run states the bound it applied in its header"
else
  fail "the header does not report the applied bound: $(grep -i 'bound' <<<"$OUT" | tr '\n' '|')"
fi
# The default is pinned by RUNNING it: a fixture whose shards are all instant must still report
# 1800 s — 1.65× the slowest shard measured (1092 s), so a legitimately slow suite cannot false-trip.
FAST="$TMP/fast"
stage_fixture "$FAST" 0
HANG_PID_DIR="$TMP/pids" bash "$FAST/scripts/runner.sh" >"$TMP/default.out" 2>&1
RC=$?
DOUT="$(cat "$TMP/default.out")"
if [ "$RC" -eq 0 ] && grep -q 'per-shard bound: 1800s per shard' <<<"$DOUT"; then
  pass "with SHARD_BOUND unset the run uses and reports the 1800s default (rc 0 on instant shards)"
else
  fail "the default bound is not 1800s (rc $RC): $(grep -i 'bound' <<<"$DOUT" | tr '\n' '|')"
fi

echo ""
echo "4. SHARD_BOUND=0 DISABLES THE BOUND; A NON-INTEGER REFUSES"
# Non-vacuity for arms 1-3: the same fixture, the same hang, no bound → the shard RUNS TO COMPLETION
# and the run is green. Without this, "the shard was killed" could be an artefact of the fixture.
SLOWISH="$TMP/slowish"
stage_fixture "$SLOWISH" 2
HANG_PID_DIR="$TMP/pids" SHARD_BOUND=0 bash "$SLOWISH/scripts/runner.sh" >"$TMP/disabled.out" 2>&1
RC=$?
NOUT="$(cat "$TMP/disabled.out")"
if [ "$RC" -eq 0 ] && ! grep -q 'TIMEOUT' <<<"$NOUT" && grep -q 'per-shard bound: DISABLED' <<<"$NOUT"; then
  pass "SHARD_BOUND=0 runs the slow shard TO COMPLETION (rc 0, no TIMEOUT) and says the bound is disabled"
else
  fail "SHARD_BOUND=0 did not disable the bound (rc $RC): $(grep -iE 'bound|TIMEOUT' <<<"$NOUT" | tr '\n' '|')"
fi
# ⛔ A TYPO MUST NOT SILENTLY REMOVE THE BOUND (#3187's whole point): anything that is not a whole
# number of seconds, 0, or `off` REFUSES the run (exit 2) rather than degrading to unbounded.
HANG_PID_DIR="$TMP/pids" SHARD_BOUND=bogus bash "$FAST/scripts/runner.sh" >"$TMP/bogus.out" 2>&1
RC=$?
BOUT="$(cat "$TMP/bogus.out")"
if [ "$RC" -eq 2 ] && grep -q "SHARD_BOUND='bogus' is not a bound" <<<"$BOUT"; then
  pass "a non-integer SHARD_BOUND REFUSES (rc 2) instead of running unbounded"
else
  fail "SHARD_BOUND=bogus returned rc $RC (want 2, naming the value): $(printf '%s' "$BOUT" | tail -2 | tr '\n' '|')"
fi

echo ""
echo "5. THE TIMEOUT MARKER DOES NOT POLLUTE THE FAILURE IDENTITY (ci_exemption contract)"
# `scripts/ci_exemption.py` splits `❌ failing shard(s): <a>, <b>` on ", " into `bash-shard::<path>`
# keys. A `(TIMEOUT after 2s)` marker appended to a NAME would manufacture a phantom identity that
# matches nothing on main — a FALSE BLOCK on every lane. The marker therefore lives on its own line.
if [ -r "$EXEMPTION" ] && command -v python3 >/dev/null 2>&1; then
  python3 "$EXEMPTION" ids --log "$TMP/bound.out" >"$TMP/ids.out" 2>"$TMP/ids.err"
  RC=$?
  IDS="$(cat "$TMP/ids.out")"
  if [ "$RC" -eq 0 ] && grep -qx 'bash-shard::tests/mmm-hang/run.sh' <<<"$IDS"; then
    pass "the rail parses the hung shard's identity exactly ('bash-shard::tests/mmm-hang/run.sh')"
  else
    fail "the hung shard's identity is not parseable (rc $RC): ids=[$(tr '\n' ' ' <<<"$IDS")] err=[$(tail -2 "$TMP/ids.err" | tr '\n' ' ')]"
  fi
  if ! grep -qiE 'TIMEOUT|\(' <<<"$IDS"; then
    pass "no phantom identity carries the TIMEOUT marker (the marker is on its own recap line)"
  else
    fail "the TIMEOUT marker leaked into the identity set: [$(tr '\n' ' ' <<<"$IDS")]"
  fi
else
  fail "cannot read scripts/ci_exemption.py or python3 — the identity contract is UNPROVEN here (fail closed)"
fi

echo ""
if [ "$failures" -eq 0 ]; then
  echo "✅ run-bash-shards-bound suite passed (${checks} assertions)"
  exit 0
fi
echo "❌ run-bash-shards-bound suite: $failures of $checks assertion(s) failed"
exit 1
