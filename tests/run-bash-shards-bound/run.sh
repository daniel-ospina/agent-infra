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
# ⛔ AND THE FIXTURE MUST NOT INHERIT THE CALLER'S **RUNNER** ENV EITHER (agent-infra#3220, measured).
# `scripts/run-bash-shards.sh` hands every shard its own environment unmodified (`shard_run_bounded`
# runs `bash "$1" </dev/null`), and BOTH of this repo's bash lanes export a runner setting that this
# suite's fixtures then re-use as if it were their own:
#
#   * `ci-main.yml`'s `script-validate` exports `BASH_SHARDS_BUDGET_SECS: '7800'` job-wide. The runner
#     deliberately REFUSES (rc 2) a POSITIVE budget combined with `BASH_SHARD_SLICE` — a sliced
#     process only accumulates its own share, so a whole-list deadline would be ~N times too lenient.
#     Arms 2d/2e pass `BASH_SHARD_SLICE=1/1`, so the inherited budget turned arm 2d into
#     `❌ a 3-shard SLICED run failed (rc 2)` on EVERY main run — measured 4/4 across 9cdad0511,
#     3803336, f8f366b, 7094d4183 — while passing on a laptop where the variable is unset. This is the
#     `bash-shard::tests/run-bash-shards-bound/run.sh` identity #3220 reported.
#   * `ci.yml`'s `bash-suites` matrix exports `BASH_SHARD_SLICE: <i>/<n>` for the whole step. Every
#     fixture call here that does NOT set its own slice then inherits one and runs 1/n of its staged
#     3 shards, so the bound arms collapse. Measured: **25 of 52** assertions under
#     `BASH_SHARD_SLICE=1/3`, and **33 of 52** in CI's own `bash-suites (8)` (run 41345204825,
#     `❌ run-bash-shards-bound suite: 33 of 52 assertion(s) failed`) — so the same suite is red in
#     BOTH lanes, from these two different variables, which is why one fix has to clear both.
#
# Both are the same defect — a suite that declares itself hermetic ("no host state") reading the host's
# runner config — and this suite tests the BOUND, never the budget or the slicing. `tests/ci-lane-parity`
# already strips exactly these two variables at every one of its fixture invocations for this reason, so
# unsetting them in ONE place here is the established idiom, not a weakening. Both are written as
# `unset` rather than `=0`/`=1/1`: the runner's other documented "none" spellings, but unsetting is the
# form the sibling suite uses and what `ci-main.yml` documents as "no deadline".
unset BASH_SHARDS_BUDGET_SECS BASH_SHARD_SLICE
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
    # ⛔ REFUSE TO RUN WHEN THE PID DIRECTORY IS UNSET (review cycle 7, P3). `$HANG_PID_DIR/self.pid`
    # with the variable unset expands to `/self.pid`: a suppressed permission-denied on a normal host,
    # and a file OUTSIDE $TMP under a root CI container — which this suite's HERMETIC promise forbids,
    # and which no assertion could see because the shard still "passed". Measured: arm 6c was launched
    # without the variable. This makes ANY future omission a RED instead of a silent write attempt.
    printf 'if [ -z "${HANG_PID_DIR:-}" ] || [ "${HANG_PID_DIR}" = "/" ]; then printf "%%s\\n" "FIXTURE-BUG: HANG_PID_DIR is unset or / — the fixture would write outside its tree"; exit 97; fi\n'
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
# control proves nothing (measured three times: when the parent-side escalation was added, when it
# moved into `shard_kill_group`, and when the watchdog's kill was restructured into an `if` — that last
# one silently stopped matching its `^  kill -…` pattern, leaving the watchdog's group kill intact, so
# the control went red and said so). What remains is a wrapper-only kill — the implementation #3187
# exists to replace.
# ⛔ AND THE MUTANT MUST NOT ITSELF BE DANGEROUS: it is a bare TERM *only*, with the KILL line deleted.
# Rendering the group KILL as a BARE `kill -KILL` would reproduce, in the control, the exact construct
# this change removes — an uncatchable signal sent 1 s after the wrapper answered TERM and the driver
# reaped it, i.e. at a FREED pid that the kernel may already have handed to another process on this
# host. A control may be wrong; it must not be able to kill a stranger.
# ⛔ THE PATTERNS FOLLOW THE ESCALATION INTO ITS FUNCTION (#3187 review 8). The group kill used to be
# spelled inline in `shard_watchdog` as `kill -TERM -"$shard_bg_pid"`; it now lives in
# `shard_shard_escalate`, whose operand is `"$1"`. A stale pattern does NOT fail loudly here — the
# `cmp -s` below still sees a change (the `shard_kill_group` gutting), so the control runs with the
# watchdog's group kill INTACT and reds for the wrong reason. Keep both forms matched.
awk '
  /^[[:space:]]*if kill -TERM -"\$shard_bg_pid"/ { print "  if kill -TERM \"$shard_bg_pid\" 2>/dev/null; then"; next }
  /^[[:space:]]*if kill -TERM -"\$1" 2>\/dev\/null; then$/ { print "  if kill -TERM \"$1\" 2>/dev/null; then"; next }
  /^[[:space:]]*kill -KILL -"\$shard_bg_pid"/ { print "    :   # wrapper-only mutation: the group KILL is removed"; next }
  /^[[:space:]]*kill -KILL -"\$1" 2>\/dev\/null$/ { print "    :   # wrapper-only mutation: the group KILL is removed"; next }
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
else
  # ⛔ BOTH CONTRACTS IN ONE ASSERTION (#3187 teardown + #3174 recap). The driver's exit code here is
  # 1, NOT 143: `shard_driver_signal` composes main's #3174 partial recap, which exits 1 so a
  # TRUNCATED run can never read GREEN or be used as a baseline. Pinning 143 alone would have
  # celebrated a head where the recap had silently replaced the teardown.
  if [ "$DRV_RC" -eq 143 ]; then
    fail "the driver exited 143 — its #3187 teardown ran but the #3174 INCOMPLETE recap did not (a truncated run must exit 1 and name itself)"
  elif [ "$DRV_RC" -ne 1 ]; then
    fail "the driver exited rc $DRV_RC (want 1 = TERM'd run is UNPROVEN, #3174) and left no shard behind"
  elif ! grep -q '⚠️ RECAP INCOMPLETE' "$TMP/killdriver.out"; then
    fail "the driver died from TERM without printing '⚠️ RECAP INCOMPLETE' — a truncated run would read as a complete one"
  else
    pass "killing the driver TERMs the shard's group AND prints the INCOMPLETE recap (rc 1, #3187 + #3174)"
  fi
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
  fail "the driver exited 143 — its teardown ran but the #3174 INCOMPLETE recap was replaced/absent"
elif [ "$DEAF_RC" -ne 1 ]; then
  fail "the driver exited rc $DEAF_RC (want 1, #3174) and left no term-deaf shard behind"
else
  pass "a TERM-deaf shard is KILLed after a cancelled driver (rc 1 + INCOMPLETE recap)"
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
# ⛔ HANG_PID_DIR IS SET HERE TOO (review cycle 7, P3): the fixture's hang shard writes
# `$HANG_PID_DIR/self.pid`, and with the variable UNSET that path is `/self.pid` — a suppressed
# permission-denied on a normal host, and a file created OUTSIDE $TMP under a root CI container, which
# this suite's HERMETIC promise forbids. Every other fixture run in this file sets it.
set -m
HANG_PID_DIR="$TMP/pids-leader" SHARD_BOUND=60 bash "$LEADER/scripts/runner.sh" >"$TMP/leader.out" 2>&1 &
LEADER_JOB=$!
set +m
wait "$LEADER_JOB" 2>/dev/null
LEADER_RC=$?
LOUT="$(cat "$TMP/leader.out")"
# one predicate, so the arm and its control are judged by EXACTLY the same rule
leader_whole_list() {  # <rc> <out file>
  [ "$1" -eq 0 ] && grep -q 'BEFORE-RAN' "$2" && grep -q 'AFTER-RAN' "$2" \
    && grep -q 'all 3 bash shards passed' "$2"
}
if leader_whole_list "$LEADER_RC" "$TMP/leader.out"; then
  pass "a GROUP-LEADER driver runs the WHOLE list (rc 0, all 3 shards, recap) — no self-signal on bash 3.2"
else
  fail "a group-leader driver exited rc $LEADER_RC with $(grep -c '  ▸' <<<"$LOUT") shard row(s) — the run was cut short ($(printf '%s' "$LOUT" | tail -1))"
fi
# ⛔ THE CONTROL, AND WHY IT IS SPELLED `$$` AND NOT `${BASHPID:-$$}` (review cycle 7, P3). The bug this
# arm pins was `kill -TERM -- -"${BASHPID:-$$}"` in the watchdog's TERM trap: on bash 3.2 `BASHPID`
# does not exist, so it evaluates to `$$` — the DRIVER's pid — and the per-shard teardown signals the
# driver's own group. Restoring THAT spelling cannot discriminate on bash 5 (there `BASHPID` is the
# watchdog's own pid, i.e. harmless), and CI runs bash 5, so this arm would be green EITHER WAY on the
# platform it is judged on. The control therefore restores the same BEHAVIOUR in the one spelling that
# means it on EVERY bash — a bare `$$` — and requires this arm's own predicate to go red.
LEADER_CTRL="$TMP/leader-ctrl"
stage_fixture "$LEADER_CTRL" 0
awk '
  /^  trap .*TERM INT HUP$/ {
    print "  trap \047kill \"${shard_timer_pid:-}\" 2>/dev/null; kill -TERM -- -$$ 2>/dev/null; exit 0\047 TERM INT HUP"
    next
  }
  { print }
' "$LEADER_CTRL/scripts/runner.sh" >"$LEADER_CTRL/scripts/runner.mut.sh"
if [ ! -s "$LEADER_CTRL/scripts/runner.mut.sh" ] \
   || cmp -s "$LEADER_CTRL/scripts/runner.sh" "$LEADER_CTRL/scripts/runner.mut.sh"; then
  fail "the self-signal mutation did not change the fixture runner — arm 6c has no control on this bash"
else
  cp "$LEADER_CTRL/scripts/runner.mut.sh" "$LEADER_CTRL/scripts/runner.sh"
  set -m
  HANG_PID_DIR="$TMP/pids-leader-ctrl" SHARD_BOUND=60 bash "$LEADER_CTRL/scripts/runner.sh" >"$TMP/leader-ctrl.out" 2>&1 &
  CTRL_JOB=$!
  set +m
  wait "$CTRL_JOB" 2>/dev/null
  CTRL_RC=$?
  if leader_whole_list "$CTRL_RC" "$TMP/leader-ctrl.out"; then
    fail "control: the pre-fix self-signal (\`kill -TERM -- -\$\$\` from the watchdog) still ran the WHOLE list (rc $CTRL_RC) — arm 6c cannot see the bug it claims to pin on this bash"
  else
    pass "control: the pre-fix self-signal cuts the run short (rc $CTRL_RC, $(grep -c '  ▸' "$TMP/leader-ctrl.out") shard row(s)) — arm 6c discriminates on bash 5 as well as 3.2"
  fi
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

# 6e. INT AND HUP ARE FORWARDED TOO (review cycle 4, P2). With `set -m` the shard lives in its
# own group, so a terminal INT reaches ONLY the driver — the INT trap is the single thing that kills a
# shard on a Ctrl-C.
# ⛔ JOB CONTROL IS LOAD-BEARING FOR THE *TEST*, NOT JUST THE RUNNER (review cycle 6, P2, measured).
# A non-interactive shell starts its background jobs with SIGINT (and SIGQUIT) IGNORED at the OS
# level, and POSIX forbids trapping a signal inherited as ignored — so `… &` from a plain script
# produces a driver whose INT trap CAN NEVER RUN. Written that way this arm passed while testing
# nothing: it measured rc 0 after the FULL 60 s hang with no recap at all, the shard being gone only
# because the run had COMPLETED. `set -m` around the launch restores job control, which un-ignores
# INT, and the trap then really fires (verified: rc 130 and the trap's own output on a 0 s fixture).
# A helper would put `bash "$1"` in the source (a shape `extensions/main-worktree-guard` refuses), so
# the two signals are spelled out — and so are their two FIXTURE PATHS: a `bash "$TMP/sig-$_sig/…"`
# inside a loop makes the script path unresolvable to that guard's static analysis, which then refuses
# EVERY gated command that names this file (measured; the loop form was replaced for exactly that).
SIGFIX_INT="$TMP/sig-int"
stage_fixture "$SIGFIX_INT" 60
set -m
HANG_PID_DIR="$TMP/pids-sig-int" SHARD_BOUND=1800 bash "$SIGFIX_INT/scripts/runner.sh" >"$TMP/sig-int.out" 2>&1 &
SIGINT_DRV=$!
set +m
_n=0
while [ "$_n" -lt 100 ]; do
  [ -s "$TMP/pids-sig-int/self.pid" ] && break
  sleep 0.2
  _n=$((_n + 1))
done
kill -INT "$SIGINT_DRV" 2>/dev/null
wait "$SIGINT_DRV" 2>/dev/null
SIGINT_RC=$?
SIGINT_SURVIVORS=""
for _f in self.pid child.pid; do
  [ -f "$TMP/pids-sig-int/$_f" ] || continue
  while IFS= read -r _pid; do
    [ -n "$_pid" ] || continue
    _n=0
    while kill -0 "$_pid" 2>/dev/null && [ "$_n" -lt 6 ]; do sleep 0.5; _n=$((_n + 1)); done
    if kill -0 "$_pid" 2>/dev/null; then SIGINT_SURVIVORS="$SIGINT_SURVIVORS $_f=$_pid"; kill -KILL "$_pid" 2>/dev/null; fi
  done <"$TMP/pids-sig-int/$_f"
done
if [ ! -f "$TMP/pids-sig-int/self.pid" ]; then
  fail "the INT fixture never started — this arm proves nothing"
elif [ -n "$SIGINT_SURVIVORS" ]; then
  fail "an INT to the driver left the shard alive:$SIGINT_SURVIVORS (the shard is in its own group now, so the INT trap is the only thing that reaches it)"
elif [ "$SIGINT_RC" -ne 1 ] || ! grep -q '⚠️ RECAP INCOMPLETE' "$TMP/sig-int.out"; then
  fail "the INT trap did not run: rc $SIGINT_RC (want 1, #3174) and $(grep -c '⚠️ RECAP INCOMPLETE' "$TMP/sig-int.out") INCOMPLETE line(s) — an INT that reaches nothing is the Ctrl-C leak this arm exists for"
else
  pass "an INT to the driver takes the shard and its child with it (rc 1 + INCOMPLETE recap)"
fi
SIGFIX_HUP="$TMP/sig-hup"
stage_fixture "$SIGFIX_HUP" 60
# ⛔ THE HUP RUN GETS A `mktemp` SHIM, SO ITS TEMP FILES ARE FINDABLE (review cycle 7, P3). The HUP
# branch of the handler used to `exit "$1"` directly instead of going through `shard_exit`, so the
# driver's ran/skip/timeout files survived in the temp dir on EVERY terminal hangup — while the file's
# stated residual bounds that leak to `kill -9`/OOM only. The paths are decided by `mktemp` at runtime
# (and BSD `mktemp` ignores TMPDIR), so the only hermetic way to see them is to shim it and read back
# what it created.
mkdir -p "$TMP/mktemp-shim" "$TMP/hup-tmp"
cat >"$TMP/mktemp-shim/mktemp" <<MKTEMP
#!/bin/bash
p="\$(/usr/bin/mktemp "$TMP/hup-tmp/tmp.XXXXXXXX")" || exit 1
printf '%s\\n' "\$p" >>"$TMP/hup-tmp/made"
printf '%s\\n' "\$p"
MKTEMP
chmod +x "$TMP/mktemp-shim/mktemp"
PATH="$TMP/mktemp-shim:$PATH" HANG_PID_DIR="$TMP/pids-sig-hup" SHARD_BOUND=1800 bash "$SIGFIX_HUP/scripts/runner.sh" >"$TMP/sig-hup.out" 2>&1 &
SIGHUP_DRV=$!
_n=0
while [ "$_n" -lt 100 ]; do
  [ -s "$TMP/pids-sig-hup/self.pid" ] && break
  sleep 0.2
  _n=$((_n + 1))
done
kill -HUP "$SIGHUP_DRV" 2>/dev/null
wait "$SIGHUP_DRV" 2>/dev/null
SIGHUP_SURVIVORS=""
for _f in self.pid child.pid; do
  [ -f "$TMP/pids-sig-hup/$_f" ] || continue
  while IFS= read -r _pid; do
    [ -n "$_pid" ] || continue
    _n=0
    while kill -0 "$_pid" 2>/dev/null && [ "$_n" -lt 6 ]; do sleep 0.5; _n=$((_n + 1)); done
    if kill -0 "$_pid" 2>/dev/null; then SIGHUP_SURVIVORS="$SIGHUP_SURVIVORS $_f=$_pid"; kill -KILL "$_pid" 2>/dev/null; fi
  done <"$TMP/pids-sig-hup/$_f"
done
if [ ! -f "$TMP/pids-sig-hup/self.pid" ]; then
  fail "the HUP fixture never started — this arm proves nothing"
elif [ -n "$SIGHUP_SURVIVORS" ]; then
  fail "a HUP to the driver left the shard alive:$SIGHUP_SURVIVORS"
else
  pass "a HUP to the driver takes the shard and its child with it"
fi
# ⛔ AND THE HUP MUST CARRY THE DRIVER'S BOOKKEEPING AWAY WITH IT (review cycle 7, P3). Read back what
# the `mktemp` shim above created: every path it handed out must be GONE, because the handler now ends
# in `shard_exit` (cleanup) rather than a bare `exit`.
if [ ! -s "$TMP/hup-tmp/made" ]; then
  fail "the mktemp shim was never used — the HUP cleanup assertion below would be vacuous"
else
  # ONE `mktemp`, THREE artifacts: the runner derives `.skipped` and `.timeout` from the single path it
  # got back, so all three are checked and all three must be gone.
  HUP_MADE=0
  HUP_LEFT=0
  while IFS= read -r _p; do
    [ -n "$_p" ] || continue
    HUP_MADE=$((HUP_MADE + 1))
    for _s in "" .skipped .timeout; do [ -e "$_p$_s" ] && HUP_LEFT=$((HUP_LEFT + 1)); done
  done <"$TMP/hup-tmp/made"
  if [ "$HUP_MADE" -lt 1 ]; then
    fail "the HUP run recorded no temp path at all — this arm proves nothing"
  elif [ "$HUP_LEFT" -ne 0 ]; then
    fail "a HUP left $HUP_LEFT of $((HUP_MADE * 3)) temp artifact(s) behind — the handler exited WITHOUT shard_cleanup"
  else
    pass "a HUP carries the driver's bookkeeping away with it (all $((HUP_MADE * 3)) temp artifacts removed)"
  fi
fi
# 6f. AND THE DOCUMENTED RESIDUAL: SIGKILL cannot be trapped. What saves the run is the WATCHDOG, which
# is orphaned but still holding the bound — so this arm pins BOTH halves of the truth the PR body states:
# with a bound on, the shard dies at the bound; with `SHARD_BOUND=0` there is no watchdog and it does not.
KILLRES="$TMP/killres"
stage_fixture "$KILLRES" 30
HANG_PID_DIR="$TMP/pids-killres" SHARD_BOUND=3 bash "$KILLRES/scripts/runner.sh" >"$TMP/killres.out" 2>&1 &
KILLRES_DRV=$!
_n=0
while [ "$_n" -lt 100 ]; do
  [ -s "$TMP/pids-killres/self.pid" ] && break
  sleep 0.2
  _n=$((_n + 1))
done
kill -KILL "$KILLRES_DRV" 2>/dev/null
KR_PID="$(cat "$TMP/pids-killres/self.pid" 2>/dev/null)"
_n=0
while kill -0 "$KR_PID" 2>/dev/null && [ "$_n" -lt 20 ]; do sleep 1; _n=$((_n + 1)); done
if [ -z "$KR_PID" ]; then
  fail "the SIGKILL-residual fixture never started — this arm proves nothing"
elif kill -0 "$KR_PID" 2>/dev/null; then
  fail "a SIGKILLed driver left its shard alive past the 3s bound (pid $KR_PID) — the orphaned watchdog did not fire"
  kill -KILL "$KR_PID" 2>/dev/null
else
  pass "a SIGKILLed driver's SHARD still dies at the bound (the orphaned watchdog fires) — the residual is bounded, not silent"
fi

# 2d. A SHARD'S TEARDOWN MUST NOT WIPE THE DRIVER'S OWN BOOKKEEPING (review cycle 6, P1, measured).
# `shard_watchdog` runs in a forked subshell, and bash runs an inherited EXIT trap inside forked
# children of the driver — measured, the trapping shell IS the watchdog — so an EXIT-trap `rm` of the
# ran/skip/timeout logs DELETED them after every shard. The failure is not a crash but a LIE: the
# slice-coverage self-check then reads a log holding only the LAST shard and reports
# `slice N/M executed a DIFFERENT SET of shards than its index derives`. Measured **11 of 20** sliced
# runs — a flaky FALSE RED on exactly the sliced callers CI uses (`ci.yml`'s bash-suites matrix) — and
# a deleted timeout marker would make a real bound-hit unattributable. This arm is the regression pin:
# 3 shards, a slice that must see all 3, and a control that re-installs the destructive trap.
SLICEFIX="$TMP/sliceclean"
stage_fixture "$SLICEFIX" 0
for _s in before hang after; do :; done
SLICE_RC=0
HANG_PID_DIR="$TMP/pids-sliceclean" SHARD_BOUND=1800 BASH_SHARD_SLICE=1/1 bash "$SLICEFIX/scripts/runner.sh" >"$TMP/sliceclean.out" 2>&1 || SLICE_RC=$?
# 3 shards ran, so the log the coverage check compares must hold all 3
SLICE_ROWS="$(grep -c '  ▸' "$TMP/sliceclean.out")"
SLICEMUT="$TMP/sliceclean-mutant.sh"
# ⛔ THE CONTROL INJECTS THE WIPE ITSELF, NOT THE `EXIT` TRAP THAT USED TO CARRY IT (review cycle 7,
# U1, measured on this host). The control used to re-install `trap 'rm -f …' EXIT` and require the same
# sliced run to go red in ≥1 of 6 attempts — which depends on bash running an INHERITED `EXIT` trap
# inside the forked child of a background FUNCTION. Probed on this host: /bin/bash 3.2.57 and bash 5.3
# both run that trap ONCE, in the DRIVER, at script exit (`BASH_SUBSHELL=0`) — so the control red-not in
# 0 of 6 on BOTH, and this arm was a false red wherever the child does not inherit the trap. The
# regression being pinned is not "an EXIT trap" — it is "the driver's bookkeeping gets wiped after a
# shard", so the control now does exactly that, deterministically, on every bash.
awk '
  /^shard_watchdog\(\) \{$/ {
    print
    print "  rm -f \"$shard_ran_log\" \"$shard_skip_log\" \"$shard_timeout_marker\""
    next
  }
  { print }
' "$SLICEFIX/scripts/runner.sh" >"$SLICEMUT"
if [ "$SLICE_RC" -ne 0 ]; then
  fail "a 3-shard SLICED run failed (rc $SLICE_RC) — the driver's own bookkeeping did not survive its shard teardowns: $(grep -E 'DIFFERENT SET|sort: cannot read' "$TMP/sliceclean.out" | head -2 | tr '\n' ' ')"
elif [ "$SLICE_ROWS" -ne 3 ]; then
  fail "a 3-shard sliced run printed $SLICE_ROWS timing row(s), not 3 — this arm proves nothing"
elif cmp -s "$SLICEFIX/scripts/runner.sh" "$SLICEMUT"; then
  fail "the teardown-wipe mutation did not change the runner — the 'no wipe' assertion has no control"
else
  # the control: make the watchdog wipe the driver's logs. It must make the same sliced run red, and
  # the FIRST attempt is enough — the wipe is a certainty, not a schedule.
  cp "$SLICEMUT" "$SLICEFIX/scripts/runner.sh"
  MUT_RC=0
  HANG_PID_DIR="$TMP/pids-slicemut" SHARD_BOUND=1800 BASH_SHARD_SLICE=1/1 bash "$SLICEFIX/scripts/runner.sh" >"$TMP/sliceclean-mut.out" 2>&1 || MUT_RC=$?
  if [ "$MUT_RC" -ge 1 ]; then
    pass "a shard teardown does NOT wipe the driver's ran/skip/timeout logs, and re-arming the wipe reds the same sliced run (rc $MUT_RC)"
  else
    fail "the teardown-wipe control did not red the sliced run (rc 0) — the assertion above cannot see the wipe it guards"
  fi
fi

# ── 10. THE ESCALATION'S BARE-PID KILL IS OWNERSHIP-CHECKED (review cycle 6, P2) ─────────────────
# The no-group fallback names a BARE pid (see `shard_shard_escalate`), and it fires a full second
# after the driver may have reaped the shard — an uncatchable `SIGKILL` aimed at a freed pid, i.e.
# possibly at another lane or the runner agent itself. It is only safe because `shard_pid_is_mine`
# re-verifies ownership first, and NOTHING pinned that: the arm that neutralises the kill neutralises
# both forms together, so unguarding it would have gone unnoticed.
# ⛔ BEHAVIOURAL, NOT A GREP: the function is lifted out of the real runner and EXERCISED on a real
# parent/child pair, so the assertion is about what it decides, not how it is spelled. The no-group
# scenario itself cannot be staged hermetically on a host whose `set -m` works, which is why the
# function is the unit under test.
# ⛔ IT ALSO PINS `$$`, NOT `$PPID`: inside the watchdog's forked subshell bash leaves `$$` as the
# DRIVER's pid but `$PPID` as the driver's PARENT, so a `$PPID` comparison would be false on every host
# and the guard would silently never fire.
OWNARM="$TMP/ownercheck"
mkdir -p "$OWNARM"
# lift `shard_pid_is_mine` (body and all) out of the shipped runner and load it here
sed -n '/^shard_pid_is_mine() {$/,/^}$/p' "$RUNNER" >"$OWNARM/fn.sh"
if [ ! -s "$OWNARM/fn.sh" ]; then
  fail "cannot lift 'shard_pid_is_mine' out of the runner — the ownership guard does not exist"
else
  . "$OWNARM/fn.sh"
  # (a) REAL OWNER: a direct child of THIS shell — the ppid test must succeed
  sleep 20 &
  OWN_CHILD=$!
  if shard_pid_is_mine "$OWN_CHILD"; then
    pass "the ownership check ACCEPTS a pid whose parent is the caller (real owner ⇒ signal is allowed)"
  else
    fail "the ownership check REJECTED a direct child of this shell — the guard is inverted or compares against \$PPID, and a real bound-hit would never escalate"
  fi
  # (b) FOREIGN OWNER: a process whose parent is a shell that has already exited (reparented), i.e.
  #     exactly "the number now names someone else" — must be refused
  # ⛔ the inner sleep's stdout MUST be redirected: in a command substitution a background child
  # that still holds the pipe keeps the substitution open until it exits (measured: the fixture
  # "never started" because the capture was blocked on it).
  OWN_FOREIGN="$(bash -c 'sleep 20 >/dev/null 2>&1 & printf "%s\n" "$!"')"
  sleep 0.5
  if [ -n "$OWN_FOREIGN" ] && kill -0 "$OWN_FOREIGN" 2>/dev/null; then
    if shard_pid_is_mine "$OWN_FOREIGN"; then
      fail "the ownership check ACCEPTED pid $OWN_FOREIGN whose parent is not this shell — the bare-pid KILL could hit a recycled pid"
    else
      pass "the ownership check REFUSES a live pid owned by someone else (recycled pid ⇒ no signal)"
    fi
    # ⛔ the fixture is killed AFTER the control below, not here: the control re-checks the SAME pid, and a
    # dead pid is refused by the `ps` lookup rather than by the ownership gate — which is how the
    # control first "passed" for the wrong reason (measured rc 8).
  else
    fail "the foreign-owner fixture never started — this arm proves nothing"
  fi
  # (c) CONTROL: with the parent comparison gutted, case (b) must flip — otherwise (b) may pass for the
  #     wrong reason (e.g. because the fixture was already dead).
  sed 's|\[ "\$_w" = "\$\$" \]|[ -n "$_w" ]|' "$OWNARM/fn.sh" >"$OWNARM/fn-gutted.sh"
  if cmp -s "$OWNARM/fn.sh" "$OWNARM/fn-gutted.sh"; then
    fail "the ownership-gate mutation did not change the lifted function — case (b) has no control"
  else
    ( . "$OWNARM/fn-gutted.sh"
      if shard_pid_is_mine "$OWN_FOREIGN"; then exit 7; else exit 8; fi ) 2>/dev/null
    GUT_RC=$?
    if [ "$GUT_RC" -eq 7 ]; then
      pass "control: with the parent comparison removed the check accepts a foreign pid — case (b) is not vacuous"
    else
      fail "control: the gutted ownership gate still refused (rc $GUT_RC) — case (b) passes for the wrong reason"
    fi
  fi
  kill -KILL "$OWN_CHILD" 2>/dev/null
  kill -KILL "$OWN_FOREIGN" 2>/dev/null
fi

# ── 11. THE WATCHDOG'S OWN TEARDOWN NAMES A BARE PID ONLY WHILE IT IS STILL OURS (cycle 7, P2) ────
# `kill -TERM -"$shard_wd_pid" || kill -TERM "$shard_wd_pid"` takes the `||` branch EXACTLY when the
# group is empty — i.e. when the watchdog (which EXITS BY ITSELF after firing the bound) and its timer
# are both gone. Its number is then free, or already handed to another process, so the unguarded
# fallback was a signal aimed at whatever now owns it; the post-reap `kill -KILL -"$shard_wd_pid"` had
# the same problem one `wait` later. Both now go through `shard_wd_term`/`shard_wd_kill`, which is what
# `shard_driver_signal` and the per-shard teardown call.
# ⛔ LIFTED AND EXERCISED, NOT GREPPED: staging a real pid-reuse race is not hermetic, so the units are
# read out of the shipped runner and run against a LOGGING `kill`, which records the signal it was
# asked to send. Each case states the decision that matters, and the control proves case (b) is not
# vacuous (gut the ownership comparison and the foreign pid gets signalled).
WDEARM="$TMP/wdteardown"
mkdir -p "$WDEARM"
sed -n '/^shard_pid_is_mine() {$/,/^}$/p' "$RUNNER" >"$WDEARM/pid_is_mine.sh"
sed -n '/^shard_wd_term() {$/,/^}$/p' "$RUNNER" >"$WDEARM/wd_term.sh"
sed -n '/^shard_wd_kill() {$/,/^}$/p' "$RUNNER" >"$WDEARM/wd_kill.sh"
if [ ! -s "$WDEARM/pid_is_mine.sh" ] || [ ! -s "$WDEARM/wd_term.sh" ] || [ ! -s "$WDEARM/wd_kill.sh" ]; then
  fail "cannot lift shard_pid_is_mine/shard_wd_term/shard_wd_kill out of the runner — the gated teardown does not exist"
else
  cat >"$WDEARM/harness.sh" <<'WDHARNESS'
#!/bin/bash
# usage: harness.sh <fn-dir> <siglog> <case> — one teardown decision, with `kill` logged instead of hidden
set -uo pipefail
FNDIR="$1"; SIGLOG="$2"; CASE="$3"
: >"$SIGLOG"
. "$FNDIR/pid_is_mine.sh" || exit 3
. "$FNDIR/wd_term.sh" || exit 3
. "$FNDIR/wd_kill.sh" || exit 3
kill() { printf '%s\n' "$*" >>"$SIGLOG"; builtin kill "$@" 2>/dev/null; }
case "$CASE" in
  ours)
    # a direct child of THIS shell, in THIS shell's group (no job control): the group TERM fails ESRCH,
    # so the bare-pid fallback is the only thing that can reach it — and it must be allowed
    sleep 20 & p=$!
    shard_wd_term "$p"
    builtin kill -KILL "$p" 2>/dev/null
    ;;
  foreign)
    # a live pid whose parent has exited: "the number now names someone else"
    p="$(bash -c 'sleep 20 >/dev/null 2>&1 & printf "%s\n" "$!"')"
    sleep 0.5
    shard_wd_term "$p"
    builtin kill -KILL "$p" 2>/dev/null
    ;;
  gone)
    # a pid that is already REAPED (free), the ordering the bound creates when the watchdog exits first
    sleep 20 & p=$!
    builtin kill -KILL "$p" 2>/dev/null
    wait "$p" 2>/dev/null
    shard_wd_term "$p"
    shard_wd_kill "$p"
    ;;
  held)
    # a group that IS still there: the group TERM succeeds, so the post-reap group KILL must follow
    set -m
    sleep 20 & p=$!
    set +m
    shard_wd_term "$p"
    shard_wd_kill "$p"
    builtin kill -KILL "$p" 2>/dev/null
    ;;
  *) exit 4 ;;
esac
printf '%s\n' "$p" >"$SIGLOG.pid"
exit 0
WDHARNESS
  wd_run() {  # <fn dir> <tag> <case>
    bash "$WDEARM/harness.sh" "$1" "$WDEARM/sig-$2.log" "$3" 2>/dev/null
    printf '%s\n' "$?" >"$WDEARM/rc-$2"
  }
  wd_pid() { cat "$WDEARM/sig-$1.log.pid" 2>/dev/null; }
  wd_sig() { grep -qxF -- "$2" "$WDEARM/sig-$1.log" 2>/dev/null; }

  wd_run "$WDEARM" ours ours
  WD_P="$(wd_pid ours)"
  if [ ! -s "$WDEARM/rc-ours" ] || [ "$(cat "$WDEARM/rc-ours")" -ne 0 ] || [ -z "$WD_P" ]; then
    fail "the teardown harness did not run case (a) — this arm proves nothing"
  elif wd_sig ours "-TERM -$WD_P" && wd_sig ours "-TERM $WD_P"; then
    pass "a real child (no group of its own) still gets the bare-pid TERM after the group TERM fails"
  else
    fail "case (a): the group TERM $(wd_sig ours "-TERM -$WD_P" && echo ran || echo missing) and the bare TERM $(wd_sig ours "-TERM $WD_P" && echo ran || echo missing) — a live shard-watchdog would never be signalled"
  fi

  wd_run "$WDEARM" foreign foreign
  WD_F="$(wd_pid foreign)"
  if [ ! -s "$WDEARM/rc-foreign" ] || [ "$(cat "$WDEARM/rc-foreign")" -ne 0 ] || [ -z "$WD_F" ]; then
    fail "the teardown harness did not run case (b) — this arm proves nothing"
  elif wd_sig foreign "-TERM $WD_F"; then
    fail "the teardown sent a bare TERM to pid $WD_F, which is not this driver's child — a freed pid that got recycled would be signalled"
  else
    pass "a pid that no longer belongs to this driver is NOT signalled (only the group form was attempted)"
  fi

  wd_run "$WDEARM" gone gone
  WD_G="$(wd_pid gone)"
  if [ ! -s "$WDEARM/rc-gone" ] || [ "$(cat "$WDEARM/rc-gone")" -ne 0 ] || [ -z "$WD_G" ]; then
    fail "the teardown harness did not run case (c) — this arm proves nothing"
  elif wd_sig gone "-KILL -$WD_G" || wd_sig gone "-TERM $WD_G"; then
    fail "an ALREADY-FREED pid ($WD_G) was signalled anyway — that is the SIGKILL-at-a-freed-number the file bans"
  else
    pass "an already-freed watchdog pid is left alone: no bare signal, and no group KILL for a group that was gone"
  fi

  wd_run "$WDEARM" held held
  WD_H="$(wd_pid held)"
  if [ ! -s "$WDEARM/rc-held" ] || [ "$(cat "$WDEARM/rc-held")" -ne 0 ] || [ -z "$WD_H" ]; then
    fail "the teardown harness did not run case (d) — this arm proves nothing"
  elif wd_sig held "-KILL -$WD_H"; then
    pass "a group that WAS still there gets the post-reap group KILL — the leak fix is not disarmed by the new gate"
  else
    fail "case (d): the post-reap group KILL did not fire for a group that was observed alive — a leaked timer would now survive"
  fi

  # ⛔ CONTROL for case (b): with the parent comparison gutted, a FOREIGN pid must be signalled. Otherwise
  # (b) may be passing because the fixture was already dead rather than because of the ownership gate.
  sed 's|\[ "\$_w" = "\$\$" \]|[ -n "$_w" ]|' "$WDEARM/pid_is_mine.sh" >"$WDEARM/pid_is_mine-gutted.sh"
  if cmp -s "$WDEARM/pid_is_mine.sh" "$WDEARM/pid_is_mine-gutted.sh"; then
    fail "the ownership-gate mutation did not change the lifted function — case (b) has no control"
  else
    mkdir -p "$WDEARM/gutted"
    cp "$WDEARM/pid_is_mine-gutted.sh" "$WDEARM/gutted/pid_is_mine.sh"
    cp "$WDEARM/wd_term.sh" "$WDEARM/gutted/wd_term.sh"
    cp "$WDEARM/wd_kill.sh" "$WDEARM/gutted/wd_kill.sh"
    wd_run "$WDEARM/gutted" foreign-gut foreign
    WD_FG="$(wd_pid foreign-gut)"
    if [ -n "$WD_FG" ] && wd_sig foreign-gut "-TERM $WD_FG"; then
      pass "control: with the parent comparison removed the foreign pid IS signalled — case (b) is not vacuous"
    else
      fail "control: the gutted ownership gate still refused the foreign pid — case (b) passes for the wrong reason"
    fi
  fi
fi

# ── 12. THE WATCHDOG'S SHARD ESCALATION GATES **BOTH** BARE SIGNALS, AT ITS CALL SITE (review 8, P2) ──
# Arm 10 exercises the ownership PREDICATE — and that was exactly the hole: nothing asserted that the
# ESCALATION USES it, so deleting the gate at the call site left this suite fully green (measured by a
# reviewer: 46 assertions, exit 0, with the guard removed). The escalation is therefore a FUNCTION
# (`shard_shard_escalate`), lifted out of the real runner and run against a LOGGING `kill` exactly like
# arm 11 — and what it must do is asserted on BOTH of its bare-pid signals, because the TERM was
# ungated for two review cycles while three artifacts said it was gated.
ESCARM="$TMP/shardescalate"
mkdir -p "$ESCARM"
sed -n '/^shard_pid_is_mine() {$/,/^}$/p' "$RUNNER" >"$ESCARM/pid_is_mine.sh"
sed -n '/^shard_shard_escalate() {$/,/^}$/p' "$RUNNER" >"$ESCARM/escalate.sh"
if [ ! -s "$ESCARM/pid_is_mine.sh" ] || [ ! -s "$ESCARM/escalate.sh" ]; then
  fail "cannot lift shard_shard_escalate/shard_pid_is_mine out of the runner — the watchdog's shard escalation is not a gated function any more"
else
  cat >"$ESCARM/harness.sh" <<'ESCHARNESS'
#!/bin/bash
# usage: harness.sh <fn-dir> <siglog> <case> — one bound escalation, with `kill` logged instead of hidden
set -uo pipefail
FNDIR="$1"; SIGLOG="$2"; CASE="$3"
: >"$SIGLOG"
. "$FNDIR/pid_is_mine.sh" || exit 3
. "$FNDIR/escalate.sh" || exit 3
kill() { printf '%s\n' "$*" >>"$SIGLOG"; builtin kill "$@" 2>/dev/null; }
case "$CASE" in
  deaf)
    # a TERM-DEAF direct child of THIS shell, in THIS shell's group (no job control): the group TERM
    # fails ESRCH, so the bare-pid fallback is the only path — and the gate must let BOTH signals
    # through, or a suite that traps TERM outlives the bound on a host with no per-shard group
    # ⛔ WAIT FOR THE TRAP TO BE INSTALLED FIRST (measured: without this the arm is FLAKY). Escalate is
    # otherwise called while the child is still between `fork` and `trap "" TERM`, so the bare TERM
    # lands on the DEFAULT disposition, kills it, and the second ownership read sees a zombie — case
    # (a) then reports "bare KILL missing" on a code path that is correct.
    ES_READY="$SIGLOG.ready" bash -c 'trap "" TERM; : >"$ES_READY"; while :; do sleep 1; done' &
    p=$!
    _n=0
    while [ ! -f "$SIGLOG.ready" ] && [ "$_n" -lt 100 ]; do sleep 0.1; _n=$((_n + 1)); done
    [ -f "$SIGLOG.ready" ] || exit 5
    ;;
  answered)
    # a child that ANSWERS the TERM: it is a ZOMBIE one second later (this shell has not `wait`ed),
    # which is the "freed pid" case — the bare KILL must NOT be aimed at it
    sleep 20 & p=$!
    ;;
  foreign)
    # a live pid whose parent has exited: "the number now names someone else"
    p="$(bash -c 'sleep 20 >/dev/null 2>&1 & printf "%s\n" "$!"')"
    sleep 0.5
    ;;
  held)
    # the COMMON path: job control gave the child its own group, so the group form reaches it and the
    # bare-pid fallback must never be taken
    set -m
    sleep 20 & p=$!
    set +m
    ;;
  *) exit 4 ;;
esac
shard_shard_escalate "$p"
builtin kill -KILL "$p" 2>/dev/null
printf '%s\n' "$p" >"$SIGLOG.pid"
exit 0
ESCHARNESS
  es_run() {  # <fn dir> <tag> <case>
    bash "$ESCARM/harness.sh" "$1" "$ESCARM/sig-$2.log" "$3" 2>/dev/null
    printf '%s\n' "$?" >"$ESCARM/rc-$2"
  }
  es_pid() { cat "$ESCARM/sig-$1.log.pid" 2>/dev/null; }
  es_sig() { grep -qxF -- "$2" "$ESCARM/sig-$1.log" 2>/dev/null; }

  es_run "$ESCARM" deaf deaf
  ES_D="$(es_pid deaf)"
  if [ ! -s "$ESCARM/rc-deaf" ] || [ "$(cat "$ESCARM/rc-deaf")" -ne 0 ] || [ -z "$ES_D" ]; then
    fail "the shard-escalation harness did not run case (a) — this arm proves nothing"
  elif es_sig deaf "-TERM $ES_D" && es_sig deaf "-KILL $ES_D"; then
    pass "a TERM-DEAF shard with no group of its own gets BOTH bare signals (TERM, then KILL) — the gate does not disarm the bound"
  else
    fail "case (a): bare TERM $(es_sig deaf "-TERM $ES_D" && echo ran || echo missing), bare KILL $(es_sig deaf "-KILL $ES_D" && echo ran || echo missing) — a TERM-deaf shard would outlive the bound"
  fi

  es_run "$ESCARM" answered answered
  ES_A="$(es_pid answered)"
  if [ ! -s "$ESCARM/rc-answered" ] || [ "$(cat "$ESCARM/rc-answered")" -ne 0 ] || [ -z "$ES_A" ]; then
    fail "the shard-escalation harness did not run case (b) — this arm proves nothing"
  elif es_sig answered "-KILL $ES_A"; then
    fail "the escalation sent a bare KILL to pid $ES_A after the shard had answered the TERM — that number is a reaped/zombie child, and a recycled one would be signalled"
  elif es_sig answered "-TERM $ES_A"; then
    pass "a shard that answers the bare TERM is NOT then KILLed by bare pid (the one-second window is gated at both signals)"
  else
    fail "case (b): the bare TERM never ran, so the KILL gate was not actually exercised"
  fi

  es_run "$ESCARM" foreign foreign
  ES_F="$(es_pid foreign)"
  if [ ! -s "$ESCARM/rc-foreign" ] || [ "$(cat "$ESCARM/rc-foreign")" -ne 0 ] || [ -z "$ES_F" ]; then
    fail "the shard-escalation harness did not run case (c) — this arm proves nothing"
  elif es_sig foreign "-TERM $ES_F" || es_sig foreign "-KILL $ES_F"; then
    fail "the escalation bare-signalled pid $ES_F, which is not this driver's child — a recycled pid would be hit"
  else
    pass "a pid that belongs to someone else gets NO bare signal (only the group form was attempted)"
  fi

  es_run "$ESCARM" held held
  ES_H="$(es_pid held)"
  if [ ! -s "$ESCARM/rc-held" ] || [ "$(cat "$ESCARM/rc-held")" -ne 0 ] || [ -z "$ES_H" ]; then
    fail "the shard-escalation harness did not run case (d) — this arm proves nothing"
  elif es_sig held "-KILL -$ES_H" && ! es_sig held "-TERM $ES_H" && ! es_sig held "-KILL $ES_H"; then
    pass "a shard WITH its own group still gets the group TERM→KILL and no bare signal — the common bound path is unchanged"
  else
    fail "case (d): the group path did not run as expected (group KILL $(es_sig held "-KILL -$ES_H" && echo ran || echo missing), bare TERM $(es_sig held "-TERM $ES_H" && echo ran || echo missing))"
  fi

  # ⛔ CONTROL for case (c): with the parent comparison gutted, a FOREIGN pid must be signalled. Otherwise
  # (c) may pass because the fixture died rather than because of the ownership gate.
  sed 's|\[ "\$_w" = "\$\$" \]|[ -n "$_w" ]|' "$ESCARM/pid_is_mine.sh" >"$ESCARM/pid_is_mine-gutted.sh"
  if cmp -s "$ESCARM/pid_is_mine.sh" "$ESCARM/pid_is_mine-gutted.sh"; then
    fail "the ownership-gate mutation did not change the lifted function — case (c) has no control"
  else
    mkdir -p "$ESCARM/gutted"
    cp "$ESCARM/pid_is_mine-gutted.sh" "$ESCARM/gutted/pid_is_mine.sh"
    cp "$ESCARM/escalate.sh" "$ESCARM/gutted/escalate.sh"
    es_run "$ESCARM/gutted" foreign-gut foreign
    ES_FG="$(es_pid foreign-gut)"
    if [ -n "$ES_FG" ] && es_sig foreign-gut "-TERM $ES_FG"; then
      pass "control: with the parent comparison removed the foreign pid IS signalled — case (c) is not vacuous"
    else
      fail "control: the gutted ownership gate still refused the foreign pid — case (c) passes for the wrong reason"
    fi
  fi
fi

# 12b. THE WATCHDOG'S TERM TRAP MUST NOT NAME A PID IT HAS ALREADY REAPED (review 8, P1, measured on
# 46 of 46 bound hits). `wait "$shard_timer_pid"` REAPS the timer, so the variable holds a FREED number
# for the rest of the escalation (>1 s: kill -0, ps, the marker write, the group TERM, the sleep, the
# group KILL) — and the trap `kill "${shard_timer_pid:-}"` then ran against it, which the reviewer's
# instrumented `kill` shim measured as `target_state=[NO-SUCH-PID]` on every hit.
# ⚠️ THIS ONE IS A SOURCE PIN, DELIBERATELY: a `kill` FUNCTION is the only shim bash honours (a PATH
# `kill` is never consulted — the builtin wins), and the trap string lives INSIDE `shard_watchdog`, so
# the shim cannot be installed in the shell that runs it. Staging a real freed-pid TERM race
# hermetically is not possible; the invariant that makes it impossible is stated in one line, so the
# line is what is pinned. It is NOT vacuous: the pre-fix runner has no such assignment and this fails.
if awk '
  /^  wait "\$shard_timer_pid" 2>\/dev\/null \|\| exit 0$/ { seen = 1; next }
  seen && /^[[:space:]]*(#|$)/ { next }
  seen { ok = ($0 ~ /^  shard_timer_pid=""[[:space:]]*$/); exit }
  END { exit ok ? 0 : 1 }
' "$RUNNER"; then
  pass "the watchdog CLEARS the timer pid the moment \`wait\` reaps it, so its TERM trap cannot signal a freed number"
else
  fail "the watchdog keeps \`\$shard_timer_pid\` after \`wait\` reaped it — its trap would kill a freed pid (measured on every bound hit)"
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
  # ⛔ THE TEARDOWN IS NOW TWO CALLS (`shard_wd_term`/`shard_wd_kill`), so the control rewrites the CALLS:
  # a bare TERM to the watchdog (nothing reaches its timer group) and no post-reap pass at all. The old
  # literal here matched the inlined `kill … || kill …` line, which no longer exists — MEASURED: with the
  # stale pattern the mutation still applied (other arms fired) but left no timer, so this control red-ed
  # for the wrong reason and arm 7a had no discriminating partner.
  /^  shard_wd_term "\$shard_wd_pid"$/ { print "  kill -TERM \"$shard_wd_pid\" 2>/dev/null"; next }
  /^  shard_wd_kill "\$shard_wd_pid"$/ { print "  :   # post-reap group KILL removed by the control"; next }
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

echo "9. A HEALTHY SLOW SHARD UNDER AN ENABLED BOUND MUST PASS — the one production risk of this design"
# ⛔ THE OTHER DIRECTION, UNTESTED UNTIL NOW (review cycle 5, P2): every other arm is instant-or-hang, so
# a watchdog that fired EARLIER than configured (or ignored `SHARD_BOUND` and used a constant) tripped
# nothing — the `TIMEOUT after <n>s` text is printed from `$shard_bound`, so it cannot tell when the
# timer actually fired. Measured: a mutant whose timer slept `bound/2` passed 32 of 33 assertions.
# A shard that legitimately takes most of the bound must be GREEN, and halving the timer must make it RED.
SLOWOK="$TMP/slowok"
stage_fixture "$SLOWOK" 4
T0="$(date +%s)"
HANG_PID_DIR="$TMP/pids-slowok" SHARD_BOUND=6 bash "$SLOWOK/scripts/runner.sh" >"$TMP/slowok.out" 2>&1
SLOW_RC=$?
T1="$(date +%s)"
SOUT="$(cat "$TMP/slowok.out")"
if [ "$SLOW_RC" -eq 0 ] && ! grep -q 'TIMEOUT' <<<"$SOUT" && grep -q 'all 3 bash shards passed' <<<"$SOUT" \
   && [ $((T1 - T0)) -ge 4 ]; then
  pass "a 4s shard under a 6s bound PASSES ($((T1 - T0))s, rc 0, no TIMEOUT) — the bound does not false-trip a slow-but-healthy suite"
else
  fail "a 4s shard under a 6s bound did not pass cleanly (rc $SLOW_RC, $((T1 - T0))s): $(printf '%s' "$SOUT" | tail -2 | tr '\n' '|')"
fi
# CONTROL: the SAME fixture with a timer that fires at HALF the configured bound must go RED. Without
# this, the arm above cannot distinguish "the bound is respected" from "the bound is ignored".
HALFFIX="$TMP/slowok-half"
stage_fixture "$HALFFIX" 4
awk '
  /^  sleep "\$shard_bound" &$/ { print "  sleep \"$((shard_bound / 2))\" &"; next }
  { print }
' "$HALFFIX/scripts/runner.sh" >"$TMP/runner-halfbound.sh"
if cmp -s "$HALFFIX/scripts/runner.sh" "$TMP/runner-halfbound.sh"; then
  fail "the half-bound mutation did not change the runner — the 'slow shard passes' arm has no control"
else
  cp "$TMP/runner-halfbound.sh" "$HALFFIX/scripts/runner.sh"
  HANG_PID_DIR="$TMP/pids-slowok" SHARD_BOUND=6 bash "$HALFFIX/scripts/runner.sh" >"$TMP/slowok-half.out" 2>&1
  HALF_RC=$?
  HOUT="$(cat "$TMP/slowok-half.out")"
  if [ "$HALF_RC" -eq 1 ] && grep -q 'TIMEOUT after 6s' <<<"$HOUT"; then
    pass "control: a timer firing at HALF the configured bound reds that same shard — the arm can see a mistimed bound"
  else
    fail "control: a half-length timer did not red the 4s shard (rc $HALF_RC): $(printf '%s' "$HOUT" | tail -2 | tr '\n' '|')"
  fi
fi

echo ""
if [ "$failures" -eq 0 ]; then
  echo "✅ run-bash-shards-bound suite passed (${checks} assertions)"
  exit 0
fi
echo "❌ run-bash-shards-bound suite: $failures of $checks assertion(s) failed"
exit 1
