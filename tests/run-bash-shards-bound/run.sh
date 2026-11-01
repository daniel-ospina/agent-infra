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

# stage_fixture <root> <hang-seconds> — a miniature checkout the REAL runner runs.
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
# ⛔ THE POINT-OF-FAILURE LINE **AND** THE RECAP'S BOUND LINE, each pinned by its own exact shape (review
# cycle 3, P2 — a mutation that stripped the bound from BOTH recaps left the suite green, so "the bound
# is reported in every recap" was an unproven claim; and the early-exit paths have no recap at all, so
# the per-failure line is the only place that case is ever explained).
if grep -qE '^⏱ SHARD TIMEOUT after 2s: tests/mmm-hang/run\.sh$' <<<"$OUT"; then
  pass "the point-of-failure line names the casualty even if the run never reaches a recap"
else
  fail "no '⏱ SHARD TIMEOUT after 2s: <path>' line at the point of failure"
fi
if grep -qE '^   ⏱  per-shard bound applied: 2s per shard' <<<"$OUT"; then
  pass "the FAILING recap reports the bound that applied"
else
  fail "the failing recap does not report the bound ($(grep -c 'per-shard bound applied' <<<"$OUT") occurrence(s))"
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
MISSING_PID_FILES=""
for _f in self.pid child.pid; do
  # ⛔ A MISSING LEDGER IS A FAILED ASSERTION, NOT A SKIP (review finding, P2). This arm is the only
  # proof of "no orphan survives"; skipping a pid file that was never written would assert nothing
  # and report ✅ — a false PASS on the one property that stands between this code and an invisible
  # orphan.
  if [ ! -f "$TMP/pids/$_f" ]; then MISSING_PID_FILES="$MISSING_PID_FILES $_f"; continue; fi
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
# The fixture brackets itself in `sleep 30 &`, so a missing CHILD pid would also mean the child the
# orphan check is about never existed — say so rather than passing.
if [ -n "$MISSING_PID_FILES" ]; then
  fail "the hung shard recorded NO pid for:$MISSING_PID_FILES — the orphan assertion below cannot pass (it would be vacuous)"
fi
if [ -z "$ORPHANS" ] && [ -z "$MISSING_PID_FILES" ]; then
  pass "no orphan: the hung shard AND the child it spawned are both gone after the bound"
else
  [ -n "$ORPHANS" ] && fail "ORPHANED process(es) survived the per-shard bound:$ORPHANS (a wrapper-only kill is not a bound)"
fi

# ⛔ NON-VACUITY CONTROL: the assertion above must be able to SEE an orphan. The obvious wrong
# implementation — kill the wrapper's pid and nothing else — is built here by deleting the group
# (`-"$pid"`) from the kill, and the CHILD MUST SURVIVE it. Without this arm, "no orphan" could be
# passing because nothing ever spawned one.
MUTFIX="$TMP/mutf"
stage_fixture "$MUTFIX" 30
# ⛔ EVERY group-kill form is neutralised, or the fixture is "fixed" by whichever one is left and the
# control proves nothing (measured twice: first when the parent-side escalation was added, then when it
# moved into `shard_kill_group`): the WATCHDOG's (`-"$shard_bg_pid"`), and the shared helper itself
# (gutted wholesale, body and all). What remains is a wrapper-only kill — the implementation #3187
# exists to replace.
awk '
  /^  kill -TERM -"\$shard_bg_pid"/ { print "  kill -TERM \"$shard_bg_pid\" 2>/dev/null"; next }
  /^  kill -KILL -"\$shard_bg_pid"/ { print "  kill -KILL \"$shard_bg_pid\" 2>/dev/null"; next }
  /^shard_kill_group\(\) \{$/ { print "shard_kill_group() { :; }"; skip = 1; next }
  skip && /^}$/ { skip = 0; next }
  skip { next }
  { print }
' "$MUTFIX/scripts/runner.sh" >"$TMP/runner-wrapper-only.sh"
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

# ⛔ THE SHARP CASE (review finding, P1): the WRAPPER dies on TERM and a CHILD ignores it. The group
# TERM then returns `wait` immediately, and an implementation that tears its watchdog down at that
# point cuts the KILL escalation off — the child survives the bound FOREVER. Measured by a reviewer on
# exactly this fixture before the fix; this arm is the regression pin (arm 2b traps TERM in the
# WRAPPER, which is the ordering where `wait` has NOT returned yet, so it could never catch this).
echo ""
echo "2c. THE WRAPPER DIES ON TERM BUT ITS CHILD IGNORES IT — BOTH MUST BE GONE"
DEEAFIX="$TMP/deafchild"
stage_fixture "$DEEAFIX" 30
{
  printf '#!/bin/bash\n'
  printf 'trap "" TERM\n'
  printf 'printf "%%s\\n" "$$" >"$HANG_PID_DIR/child-term.pid"\n'
  printf 'while :; do sleep 1; done\n'
} >"$DEEAFIX/tests/mmm-hang/deaf-child.sh"
{
  printf '#!/bin/bash\n'
  printf 'mkdir -p "$HANG_PID_DIR" 2>/dev/null\n'
  printf 'printf "%%s\\n" "$$" >>"$HANG_PID_DIR/self.pid"\n'
  printf 'bash "$(dirname "$0")/deaf-child.sh" &\n'
  printf 'wait\n'
} >"$DEEAFIX/tests/mmm-hang/run.sh"
T0="$(date +%s)"
HANG_PID_DIR="$TMP/pids-deaf" SHARD_BOUND=2 bash "$DEEAFIX/scripts/runner.sh" >"$TMP/deaf.out" 2>&1
RC=$?
T1="$(date +%s)"
ELAPSED=$((T1 - T0))
DOUT="$(cat "$TMP/deaf.out")"
DEAF_ORPHANS=""
DEAF_MISSING=""
for _f in self.pid child-term.pid; do
  if [ ! -f "$TMP/pids-deaf/$_f" ]; then DEAF_MISSING="$DEAF_MISSING $_f"; continue; fi
  while IFS= read -r _pid; do
    [ -n "$_pid" ] || continue
    _n=0
    while kill -0 "$_pid" 2>/dev/null && [ "$_n" -lt 5 ]; do sleep 1; _n=$((_n + 1)); done
    if kill -0 "$_pid" 2>/dev/null; then DEAF_ORPHANS="$DEAF_ORPHANS $_f=$_pid"; kill -KILL "$_pid" 2>/dev/null; fi
  done <"$TMP/pids-deaf/$_f"
done
if [ -n "$DEAF_MISSING" ]; then
  fail "the deaf-child fixture recorded NO pid for:$DEAF_MISSING — this arm proves nothing"
elif [ -n "$DEAF_ORPHANS" ]; then
  fail "a child that IGNORES TERM survived the bound:$DEAF_ORPHANS (the KILL escalation was cut off after the wrapper died)"
elif [ "$RC" -eq 1 ] && [ "$ELAPSED" -lt 25 ] && grep -q 'TIMEOUT after 2s' <<<"$DOUT"; then
  pass "a TERM-deaf CHILD is KILLed with the group (rc 1, ${ELAPSED}s, named) — the escalation is not lost when the wrapper dies first"
else
  fail "the deaf-child run is wrong (rc $RC, ${ELAPSED}s): $(printf '%s' "$DOUT" | tail -3 | tr '\n' '|')"
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
# …and the SUCCESS recap carries it too, in the RECAP's own shape (not the header's): a truncated run
# must be self-describing whichever recap it reaches (review cycle 3, P2).
if grep -qE 'shard work; slowest [0-9]+s.*; per-shard bound 1800s per shard' <<<"$DOUT"; then
  pass "the SUCCESS recap reports the bound that applied as well"
else
  fail "the success recap omits the bound: $(grep -i 'shard work' <<<"$DOUT" | tr '\n' '|')"
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
# ⛔ AND A VALUE WIDE ENOUGH TO WRAP IS A REFUSAL TOO. `$((10#$x))` wraps a 19-digit bound NEGATIVE,
# which a `-lt 1` test reads as "disabled" — i.e. a typo'd bound would silently mean UNBOUNDED.
HANG_PID_DIR="$TMP/pids" SHARD_BOUND=9223372036854775808 bash "$FAST/scripts/runner.sh" >"$TMP/huge.out" 2>&1
RC=$?
HOUT="$(cat "$TMP/huge.out")"
if [ "$RC" -eq 2 ] && grep -q 'is TOO LARGE' <<<"$HOUT"; then
  pass "a bound wide enough to wrap NEGATIVE in shell arithmetic REFUSES (rc 2) rather than reading as 'disabled'"
else
  fail "an oversized SHARD_BOUND returned rc $RC (want 2): $(printf '%s' "$HOUT" | tail -2 | tr '\n' '|')"
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
echo "6. A SHARD MUST DIE WITH ITS DRIVER (a cancelled CI step/cell must not leak a shard)"
# ⛔ `set -m` gives the running shard its OWN process group, so a kill of the driver no longer reaches
# it — a regression the bound itself introduces (review finding, P2). Before the change the shard
# inherited the driver's group, so a cancelled step took it down. Without the driver's TERM trap the
# shard would keep running for up to SHARD_BOUND (unbounded when disabled) after the step was declared
# over. Measured before the fix by the reviewer: `ORPHAN SURVIVED: pid=… ppid=1`.
KILLFIX="$TMP/killdriver"
stage_fixture "$KILLFIX" 60
HANG_PID_DIR="$TMP/pids-kill" SHARD_BOUND=1800 bash "$KILLFIX/scripts/runner.sh" >"$TMP/killdriver.out" 2>&1 &
DRV=$!
_n=0
while [ "$_n" -lt 100 ]; do
  [ -s "$TMP/pids-kill/child.pid" ] && break
  sleep 0.2
  _n=$((_n + 1))
done
kill -TERM "$DRV" 2>/dev/null
wait "$DRV" 2>/dev/null
DRV_RC=$?
KILL_ORPHANS=""
KILL_MISSING=""
for _f in self.pid child.pid; do
  if [ ! -f "$TMP/pids-kill/$_f" ]; then KILL_MISSING="$KILL_MISSING $_f"; continue; fi
  while IFS= read -r _pid; do
    [ -n "$_pid" ] || continue
    _n=0
    while kill -0 "$_pid" 2>/dev/null && [ "$_n" -lt 5 ]; do sleep 1; _n=$((_n + 1)); done
    if kill -0 "$_pid" 2>/dev/null; then KILL_ORPHANS="$KILL_ORPHANS $_f=$_pid"; kill -KILL "$_pid" 2>/dev/null; fi
  done <"$TMP/pids-kill/$_f"
done
if [ -n "$KILL_MISSING" ]; then
  fail "the shard never started (no pid for:$KILL_MISSING) — this arm proves nothing"
elif [ -n "$KILL_ORPHANS" ]; then
  fail "the shard SURVIVED its driver being killed:$KILL_ORPHANS (it is in its own process group now, so the driver must forward the signal)"
elif [ "$DRV_RC" -eq 143 ]; then
  pass "killing the driver TERMs the shard's group and the shard dies with it (driver rc 143)"
else
  fail "the driver exited rc $DRV_RC (want 143 — its TERM trap) and left no shard behind"
fi

# 6b. AND A SHARD THAT IGNORES TERM MUST STILL DIE (review cycle 2, P2, measured). A TERM-only
# forward left a `trap '' TERM` shard running for EVER after a cancelled step — reparented to init, in
# its own group, with the watchdog TERMed too, so nothing was left to bound or kill it. Arm 6's shard
# answers TERM, so it could not see this.
TERMDEAF="$TMP/killdeaf"
stage_fixture "$TERMDEAF" 60
{
  printf '#!/bin/bash\n'
  printf 'trap "" TERM\n'
  printf 'mkdir -p "$HANG_PID_DIR" 2>/dev/null\n'
  printf 'printf "%%s\\n" "$$" >"$HANG_PID_DIR/deaf.pid"\n'
  printf 'while :; do sleep 1; done\n'
} >"$TERMDEAF/tests/mmm-hang/run.sh"
HANG_PID_DIR="$TMP/pids-deafkill" SHARD_BOUND=1800 bash "$TERMDEAF/scripts/runner.sh" >"$TMP/killdeaf.out" 2>&1 &
DEAF_DRV=$!
_n=0
while [ "$_n" -lt 100 ]; do
  [ -s "$TMP/pids-deafkill/deaf.pid" ] && break
  sleep 0.2
  _n=$((_n + 1))
done
kill -TERM "$DEAF_DRV" 2>/dev/null
wait "$DEAF_DRV" 2>/dev/null
DEAF_RC=$?
DEAF_SURVIVED=0
if [ -f "$TMP/pids-deafkill/deaf.pid" ]; then
  DEAF_PID="$(cat "$TMP/pids-deafkill/deaf.pid")"
  _n=0
  while kill -0 "$DEAF_PID" 2>/dev/null && [ "$_n" -lt 8 ]; do sleep 1; _n=$((_n + 1)); done
  if kill -0 "$DEAF_PID" 2>/dev/null; then DEAF_SURVIVED=1; kill -KILL "$DEAF_PID" 2>/dev/null; fi
fi
if [ ! -f "$TMP/pids-deafkill/deaf.pid" ]; then
  fail "the TERM-deaf shard never started — this arm proves nothing"
elif [ "$DEAF_SURVIVED" -ne 0 ]; then
  fail "a TERM-DEAF shard outlived a cancelled driver — the forward must escalate to KILL, not stop at TERM"
elif [ "$DEAF_RC" -eq 143 ]; then
  pass "a TERM-deaf shard is KILLed after a cancelled driver (driver rc 143)"
else
  fail "the driver exited rc $DEAF_RC (want 143) and left no term-deaf shard behind"
fi

# 6c. THE DRIVER AS A PROCESS-GROUP LEADER (review cycle 2, P1, measured). `BASHPID` is bash 4+; a
# `"${BASHPID:-$$}"` fallback in the watchdog became `$$` — the DRIVER's pid — on bash 3.2, so the
# parent's normal per-shard teardown TERMed the driver's own group: the run exited 143 after the FIRST
# shard and the remaining shards never ran, which is #3187 recreated by its own fix. Any foreground
# job of a job-control/interactive shell is this shape, i.e. every human running this script.
LEADER="$TMP/leader"
stage_fixture "$LEADER" 0
# ⛔ THE DRIVER ITSELF MUST BE THE GROUP LEADER, so it is started as a BACKGROUND JOB OF A
# JOB-CONTROL SHELL (`set -m` above): with `set -m`, `bash … &` gets pgid == its own pid. A `( … ) &`
# subshell would be the leader and the runner its child — the shape the finding is about (a foreground
# job of an interactive shell) would not be reproduced, measured: the arm passed with the bug restored.
# The runner anchors its discovery on the tree it lives in, so no `cd` is needed here.
set -m
SHARD_BOUND=60 bash "$LEADER/scripts/runner.sh" >"$TMP/leader.out" 2>&1 &
LEADER_JOB=$!
set +m
wait "$LEADER_JOB" 2>/dev/null
LEADER_RC=$?
LOUT="$(cat "$TMP/leader.out")"
if [ "$LEADER_RC" -eq 0 ] && grep -q 'BEFORE-RAN' <<<"$LOUT" && grep -q 'AFTER-RAN' <<<"$LOUT" \
   && grep -q 'all 3 bash shards passed' <<<"$LOUT"; then
  pass "a GROUP-LEADER driver runs the WHOLE list (rc 0, all 3 shards, recap) — no self-signal on bash 3.2"
else
  fail "a group-leader driver exited rc $LEADER_RC with $(grep -c '  ▸' <<<"$LOUT") shard row(s) — the run was cut short ($(printf '%s' "$LOUT" | tail -1))"
fi

# 6d. AN UNREADABLE `ps` MUST NOT DISARM THE BOUND (review cycle 2, P1, measured). The zombie guard
# reads `ps -o stat=`; treating EMPTY output as "finished" made the bound INERT on any host without a
# POSIX `ps` (slim images have none; busybox' rejects `-o stat= -p`) while the run still printed
# `✅ all N bash shards passed`. Measured with a `ps` shim: rc 0, no TIMEOUT, the hung shard ran on.
NOPS="$TMP/nops"
stage_fixture "$NOPS" 30
mkdir -p "$TMP/ps-shim"
printf '#!/bin/bash\nexit 1\n' >"$TMP/ps-shim/ps"
chmod +x "$TMP/ps-shim/ps"
T0="$(date +%s)"
HANG_PID_DIR="$TMP/pids-nops" PATH="$TMP/ps-shim:$PATH" SHARD_BOUND=2 bash "$NOPS/scripts/runner.sh" >"$TMP/nops.out" 2>&1
NOPS_RC=$?
T1="$(date +%s)"
NOUT="$(cat "$TMP/nops.out")"
if [ "$NOPS_RC" -eq 1 ] && [ $((T1 - T0)) -lt 25 ] && grep -q 'TIMEOUT after 2s' <<<"$NOUT"; then
  pass "with no usable 'ps' the bound still FIRES and NAMES the shard (rc 1, $((T1 - T0))s, fail-closed)"
else
  fail "with no usable 'ps' the bound was disarmed (rc $NOPS_RC, $((T1 - T0))s): $(printf '%s' "$NOUT" | tail -2 | tr '\n' '|')"
fi

echo ""
echo "7. NO TIMER MAY HOLD THE CALLER'S PIPE (the regression that hung tests/ci-lane-parity)"
# ⛔ A watchdog's `sleep <bound>` INHERITS STDOUT. A caller that runs this driver inside `$( … )` or a
# pipeline waits for EOF on that pipe, so a timer that outlives the driver blocks the CALLER until the
# bound — measured on this suite's own driver: a leaked `sleep 1800` kept `tests/ci-lane-parity`'s
# command substitution open for 10+ minutes with the driver long gone (the suite then sat at one line
# of output forever, holding the whole lane). The bound here is 3117, so a leaked timer can be found BY
# NAME instead of guessed at.
#
# 7a. A NORMAL run, whose stdout is a PIPE the caller reads, reaches EOF and leaves no timer
# behind. ⛔ A FIFO, NOT `bash … | cat`: `extensions/main-worktree-guard` classifies a piped shell
# invocation in a script's own source as an unresolvable payload and then refuses EVERY gated command
# that runs that script — a false block on this whole lane, measured while writing this change
# (tests/ci-lane-parity/run.sh records the same trap for command substitutions). A FIFO is the same
# hazard with a statically readable command: the reader gets EOF only when every writer closes.
# ⛔ THE BOUND IS 3117 SO THE TIMER CAN BE FOUND BY NAME, and a name that odd is what keeps the check
# from seeing (or the cleanup from killing) some unrelated `sleep` on the host.
PIPEFIX="$TMP/pipefix"
stage_fixture "$PIPEFIX" 0
PIPE_FIFO="$TMP/pipe.fifo"
rm -f "$PIPE_FIFO"
mkfifo "$PIPE_FIFO" 2>/dev/null
cat "$PIPE_FIFO" >"$TMP/pipe.out" &
PIPE_READER=$!
T0="$(date +%s)"
HANG_PID_DIR="$TMP/pids-pipe" SHARD_BOUND=3117 bash "$PIPEFIX/scripts/runner.sh" >"$PIPE_FIFO" 2>&1 &
PIPE_WRITER=$!
_n=0
while kill -0 "$PIPE_READER" 2>/dev/null && [ "$_n" -lt 40 ]; do sleep 0.5; _n=$((_n + 1)); done
T1="$(date +%s)"
wait "$PIPE_WRITER" 2>/dev/null
PIPE_RC=$?
READER_OPEN=0
kill -0 "$PIPE_READER" 2>/dev/null && READER_OPEN=1
LEAKED="$(ps -A -o args= -ww | grep -cx 'sleep 3117')"
if [ "$READER_OPEN" -eq 0 ] && [ "$PIPE_RC" -eq 0 ] && [ $((T1 - T0)) -lt 20 ] && [ "$LEAKED" -eq 0 ]; then
  pass "a piped run reaches EOF in $((T1 - T0))s and leaves NO 'sleep 3117' timer behind"
else
  fail "piped run: reader still open=$READER_OPEN, rc $PIPE_RC, $((T1 - T0))s, $LEAKED leaked timer(s) — a leaked timer holds the caller's pipe until the bound"
  kill -KILL "$PIPE_READER" "$PIPE_WRITER" 2>/dev/null
fi
# 7b. CONTROL — the same run with the THREE defences removed (no TERM trap in the watchdog, its output
# NOT /dev/null, and the teardown signalling the bare pid instead of the group) MUST leave a
# `sleep 3117`. Without this, "no leak" could be passing because no timer ever existed.
MUTPIPE="$TMP/pipefix-mutant"
stage_fixture "$MUTPIPE" 0
awk '
  /^  set \+m$/ { print "  :   # job-control reset removed by the control"; next }
  /^  trap .kill .*shard_timer_pid/ { print "  :   # trap removed by the control"; next }
  /^  shard_watchdog >\/dev\/null 2>&1 &$/ { print "  shard_watchdog &"; next }
  /^  kill -TERM -"\$shard_wd_pid" 2>\/dev\/null \|\| kill -TERM "\$shard_wd_pid"/ { print "  kill -TERM \"$shard_wd_pid\" 2>/dev/null"; next }
  /^  kill -KILL -"\$shard_wd_pid" 2>\/dev\/null$/ { print "  :   # post-reap group KILL removed by the control"; next }
  { print }
' "$MUTPIPE/scripts/runner.sh" >"$TMP/runner-leaky.sh"
if cmp -s "$MUTPIPE/scripts/runner.sh" "$TMP/runner-leaky.sh"; then
  fail "the leaky-timer mutation did not change the runner — the 'no timer' assertion has no control"
else
  cp "$TMP/runner-leaky.sh" "$MUTPIPE/scripts/runner.sh"
  HANG_PID_DIR="$TMP/pids-pipe" SHARD_BOUND=3117 bash "$MUTPIPE/scripts/runner.sh" >"$TMP/leaky.out" 2>&1
  LEAKED_CTRL="$(ps -A -o args= -ww | grep -cx 'sleep 3117')"
  if [ "$LEAKED_CTRL" -gt 0 ]; then
    pass "control: with the defences removed a 'sleep 3117' timer DOES survive the driver ($LEAKED_CTRL) — this arm can see a leak"
  else
    fail "control: the mutant left no timer behind, so 'no leaked timer' above cannot distinguish the fixed code from the broken one"
  fi
  # Clean up the control's OWN timers, and prove they are gone (this suite must not leak either).
  for _p in $(ps -A -o pid=,args= -ww | awk '$1 ~ /^[0-9]+$/ && $NF == "3117" && $(NF-1) == "sleep" { print $1 }'); do
    kill -KILL "$_p" 2>/dev/null
  done
  sleep 0.3
  if [ "$(ps -A -o args= -ww | grep -cx 'sleep 3117')" -eq 0 ]; then
    pass "the control's leaked timer(s) were cleaned up (this suite leaves no residue)"
  else
    fail "this suite left 'sleep 3117' timer(s) running — its own control leaked"
  fi
fi


echo "8. A SHARD THAT EXITS LEAVING A CHILD BEHIND: the child must NOT survive, and must NOT hold the pipe"
# ⛔ `set -m` puts the shard in its OWN group, so a child it backgrounded and never waited for is no
# longer in the driver's group (review cycle 3, P1, measured): nothing reached it — not the driver, not
# a cancelled step's group kill — it outlived the driver with the shard's stdout still open (a caller
# reading through a pipe/FIFO never got EOF: measured, the reader got no EOF until the LEFTOVER exited),
# and the run reported the shard PASSED. The driver now tears down the group of a FINISHED shard too.
LEAKFIX="$TMP/leakfix"
stage_fixture "$LEAKFIX" 0
mkdir -p "$TMP/pids-leak"
{
  printf '#!/bin/bash\n'
  printf 'sleep 45 &\n'
  printf 'printf "%%s\\n" "$!" > "%s"\n' "$TMP/pids-leak/child.pid"
  printf 'printf "LEAVING-A-CHILD\\n"\n'
  printf 'exit 0\n'
} >"$LEAKFIX/tests/mmm-hang/run.sh"
SHARD_BOUND=60 bash "$LEAKFIX/scripts/runner.sh" >"$TMP/leakfix.out" 2>&1
LEAK_RC=$?
LEAK_PID="$(cat "$TMP/pids-leak/child.pid" 2>/dev/null)"
LEAK_ALIVE=0
if [ -n "$LEAK_PID" ]; then
  _n=0
  while kill -0 "$LEAK_PID" 2>/dev/null && [ "$_n" -lt 6 ]; do sleep 0.5; _n=$((_n + 1)); done
  kill -0 "$LEAK_PID" 2>/dev/null && LEAK_ALIVE=1
fi
if [ -z "$LEAK_PID" ]; then
  fail "the leftover-child fixture recorded no pid — this arm proves nothing"
elif [ "$LEAK_ALIVE" -ne 0 ]; then
  fail "a child left behind by a FINISHED shard survived the driver (pid $LEAK_PID) — it is in the shard's own group now, so nothing else will reach it"
  kill -KILL "$LEAK_PID" 2>/dev/null
elif [ "$LEAK_RC" -ne 0 ]; then
  fail "the leftover-child run itself failed (rc $LEAK_RC, want 0 — the shard exits successfully)"
else
  pass "a child left behind by a finished shard is torn down with its group (run still rc 0)"
fi
# CONTROL: with the shared group-kill helper gutted, that same child MUST survive — otherwise this arm
# is proving only that the fixture never started a child.
MUTLEAK="$TMP/leakfix-mutant"
stage_fixture "$MUTLEAK" 0
{
  printf '#!/bin/bash\n'
  printf 'sleep 45 &\n'
  printf 'printf "%%s\\n" "$!" > "%s"\n' "$TMP/pids-leak/child2.pid"
  printf 'exit 0\n'
} >"$MUTLEAK/tests/mmm-hang/run.sh"
awk '
  /^shard_kill_group\(\) \{$/ { print "shard_kill_group() { :; }"; skip = 1; next }
  skip && /^}$/ { skip = 0; next }
  skip { next }
  { print }
' "$MUTLEAK/scripts/runner.sh" >"$TMP/runner-nokill.sh"
if cmp -s "$MUTLEAK/scripts/runner.sh" "$TMP/runner-nokill.sh"; then
  fail "the no-kill mutation did not change the runner — the leftover-child arm has no control"
else
  cp "$TMP/runner-nokill.sh" "$MUTLEAK/scripts/runner.sh"
  SHARD_BOUND=60 bash "$MUTLEAK/scripts/runner.sh" >"$TMP/leakfix-mutant.out" 2>&1
  MUT_PID="$(cat "$TMP/pids-leak/child2.pid" 2>/dev/null)"
  if [ -n "$MUT_PID" ] && kill -0 "$MUT_PID" 2>/dev/null; then
    pass "control: with the group teardown gutted the leftover child DOES survive (pid $MUT_PID) — the arm can see a leak"
  else
    fail "control: a gutted group teardown left no surviving child, so the assertion above cannot distinguish the fixed code"
  fi
  [ -n "$MUT_PID" ] && kill -KILL "$MUT_PID" 2>/dev/null
fi

echo ""
if [ "$failures" -eq 0 ]; then
  echo "✅ run-bash-shards-bound suite passed (${checks} assertions)"
  exit 0
fi
echo "❌ run-bash-shards-bound suite: $failures of $checks assertion(s) failed"
exit 1
