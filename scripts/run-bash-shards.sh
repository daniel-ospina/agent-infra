#!/usr/bin/env bash
# run-bash-shards.sh — #1369: THE single list of bash shards. Both lanes call this script.
#
# WHY THIS FILE EXISTS (the design, not just the code)
# ---------------------------------------------------
#   The defect (#1369) was a LANE SPLIT: the same check name covered two different bodies of
#   work, so a runner-only bash failure shipped green on the PR and reddened main
#   (#1348: scripts/record-review.test.sh exited 127 on the ubuntu runner).
#
#   The first repair added the missing suites to the PR lane and a guard that PARSED BOTH
#   WORKFLOW FILES to compare their suite lists. Two independent reviews then showed that no
#   text parser can prove execution: a suite named in a heredoc body, an `env:` value, a
#   `true ||` short-circuit, a `for f in a.sh …` continuation, `env bash x.sh`, `command bash
#   x.sh`, or a shard living in any job other than the named one all read as "covered".
#   Each hardened regex just moved the gap.
#
#   So the lists are not compared any more — they do not exist twice. This script IS the list,
#   and BOTH lanes invoke it:
#       PR lane  → .github/workflows/ci.yml      job `bash-suites`
#       main lane→ .github/workflows/ci-main.yml job `script-validate`
#   A suite added here is therefore in both lanes by construction. The class "a lane split that
#   a green check hides" cannot recur by DRIFT — only by deliberately un-wiring one lane, which
#   is a visible diff, and is what `scripts/check-ci-lane-parity.sh` now asserts (it checks the
#   two call sites and this file's own floor, instead of diffing shell text).
#
# CONTRACT
#   - Runs every shard; the accumulator keeps going so one failure cannot hide the others.
#   - Exits 1 if any shard failed, 0 otherwise.
#   - Hermetic: every suite builds its own temp repos/HOME/shims and touches no real state.
#   - `--list` prints the shard list, `--list-sweeps` the syntax-sweep globs. Both print the lists
#     this script EXECUTES, from one source each (the `run_shard` lines and SWEEP_GLOBS below), so
#     `check-ci-lane-parity` can read them without keeping a second, divergent copy.
#
# USAGE
#   bash scripts/run-bash-shards.sh                 # run them all
#   bash scripts/run-bash-shards.sh --list          # print the shard list, run nothing
#   bash scripts/run-bash-shards.sh --list-sweeps   # print the syntax-sweep globs, run nothing

set -uo pipefail

# The syntax-sweep targets. A DATA list, not two literal `for f in …` lines: `--list-sweeps` prints
# exactly what the loops below iterate, so the sweep half cannot be advertised and not performed
# (or performed and not advertised) without editing this one line.
SWEEP_GLOBS=("scripts/*.sh" "scripts/checkout-hygiene/*.sh")

if [ "${1:-}" = "--list" ]; then
  # Only `.sh` targets: the sentinel self-check below also calls run_shard, and it must not
  # appear in the list it is checked against.
  sed -n 's/^ *run_shard  *\([^ ]*\.sh\).*$/\1/p' "${BASH_SOURCE[0]}"
  exit 0
fi

if [ "${1:-}" = "--list-sweeps" ]; then
  printf '%s\n' "${SWEEP_GLOBS[@]}"
  exit 0
fi

# run_shard <path> — one shard. Kept as a helper so `--list` can read the same source lines
# (a list kept anywhere else would be the very duplication this file exists to remove).
# `shard_ran` is what makes the list SELF-CHECKING at runtime: the counters are compared
# against the listed count at the end, so a neutered helper (executing nothing while the list
# still reads 14) fails loudly instead of reporting "all bash shards passed". A static check
# over this file's text could never catch that; running it can.
shard_errors=0
shard_ran=0
# One line on purpose: the execution and the counter that proves it happened are inseparable,
# so "stop executing but keep counting" is an explicit rewrite, not a one-line deletion.
run_shard() { shard_ran=$((shard_ran + 1)); bash "$1" || shard_errors=$((shard_errors + 1)); }

# Sweeping is counted too: a `for` loop whose BODY was neutered (`: ` instead of `bash -n`) would
# otherwise leave the loops — and therefore any glob floor in the guard — perfectly intact while
# checking no syntax at all. `swept` is asserted below, so the sweep loops must have done work.
swept=0
sweep_file() { swept=$((swept + 1)); bash -n "$1" || shard_errors=$((shard_errors + 1)); }

# Every listed target must be a real file INSIDE this checkout. Without this, a substitution that
# keeps the line count but points the list at a /tmp stub would report "14 shards passed" having
# run none of the suites — the counter arm alone cannot tell the difference.
checkout_real="$(pwd -P)"
while IFS= read -r t; do
  case "$t" in
    /*|*..*) echo "❌ shard target '$t' is not inside this checkout"; exit 1 ;;
  esac
  if [ -L "$t" ]; then
    echo "❌ shard target '$t' is a symlink — it may resolve outside the checkout"
    exit 1
  fi
  # The leaf check above is not enough: a symlinked PARENT directory (scripts/ -> elsewhere)
  # resolves the same target out of the checkout while the leaf itself is a regular file.
  # `cd … && pwd -P` resolves every component, so containment is judged on the real path.
  case "$(cd "$(dirname "$t")" 2>/dev/null && pwd -P)/" in
    "$checkout_real"/*) : ;;
    *) echo "❌ shard target '$t' resolves outside this checkout ($(cd "$(dirname "$t")" 2>/dev/null && pwd -P))"; exit 1 ;;
  esac
  if [ ! -f "$t" ]; then
    echo "❌ shard target '$t' does not exist — the list and the checkout disagree"
    exit 1
  fi
done <<<"$(sed -n 's/^ *run_shard  *\([^ ]*\.sh\).*$/\1/p' "${BASH_SOURCE[0]}")"

echo "── bash syntax sweeps ─────────────────────────────────────────────"
# The `bash -n` half: before #1369 the PR lane had NO shell-syntax gate at all — the purest
# instance of the split (a syntax error shipped green through the PR and reddened main).
# The inner loop expands each PATTERN deliberately (unquoted): quoting it would pass the literal
# string `scripts/*.sh` to `sweep_file`, so the sweep would report success having parsed nothing.
for pattern in "${SWEEP_GLOBS[@]}"; do
  for f in $pattern; do
    [ -f "$f" ] || continue
    sweep_file "$f"
  done
done

echo "── hermetic suites ────────────────────────────────────────────────"
# Every suite below is hermetic (temp repos / temp HOME / stubbed tools, no network).
#
# PROVENANCE, and one caveat: these lines were moved out of ci-main.yml's `script-validate`, so
# each keeps the note that workflow carried. Five of them are ALSO run by a dedicated per-PR job in
# ci.yml — the four marked "post-merge re-check of a per-PR job", plus pi-bootstrap. That
# duplication is deliberate here: this file is the ONE list both lanes run, so the PR lane runs
# those five twice (once in their own job, once inside this list). Dropping them from this list to
# save the minutes would recreate the second, hand-kept list that #1369 exists to remove — the
# alternative is to retire the dedicated jobs and let this list be the PR lane's only coverage,
# which changes PR feedback granularity and is the owner's call, not a silent edit.
run_shard scripts/checkout-hygiene/deepseek-balance-watch.test.sh          # #476 balance poller (network-free seam)
run_shard scripts/checkout-hygiene/hub-state-check.test.sh                 # #1313 the DETECTOR (clean-but-stale PASS matrix)
run_shard scripts/checkout-hygiene/hub-worktree.test.sh                    # #1309/#1313 the RECOVERY half
run_shard scripts/install-launchd.test.sh                                  # #304 installer suite
run_shard scripts/pi-reap-idle.test.sh                                     # #469 session reaper (fake PS/KILL/DATE shims)
run_shard scripts/pi-task-session-prune.test.sh                            # #783 retention sweep (dry-run default)
run_shard scripts/pi-reap-worktrees.test.sh                                # #1095 worktree reaper gates
run_shard scripts/scratch-worktree.test.sh                                 # #1141 scratch-checkout helper
run_shard scripts/record-review.test.sh                                    # #1348 THE INCIDENT: runner-only rc=127 shipped green
run_shard tests/admin-merge/run.sh                                         # #930 safe-admin-merge rail (also a per-PR job in ci.yml)
run_shard tests/atomic-land/run.sh                                         # #1367 atomic land unit (also a per-PR job in ci.yml)
run_shard tests/gh-shim/run.sh                                             # #984 argv-level gh shim (also a per-PR job in ci.yml)
run_shard tests/search-cost/run.sh                                         # #1069 fleet search cost (also a per-PR job in ci.yml)
run_shard pi-bootstrap/tests/test-setup-no-nesting.sh                      # #449 setup regression (~2min; also a per-PR step in ci.yml)

echo "───────────────────────────────────────────────────────────────────"
# Runtime self-check 1: every listed shard must have been EXECUTED. This is the arm that catches
# a helper whose execution was disabled — a text-only floor would still see 14 listed shards.
listed="$(sed -n 's/^ *run_shard  *\([^ ]*\.sh\).*$/\1/p' "${BASH_SOURCE[0]}" | grep -c .)"
if [ "$shard_ran" -ne "$listed" ]; then
  echo "❌ executed $shard_ran of $listed listed shard(s) — the list and the execution disagree"
  exit 1
fi

# Runtime self-check 2: the SWEEP must have executed. A `for` loop kept intact while its body
# was replaced (`: ` for `bash -n`) still satisfies any textual glob count, so only a runtime
# counter proves the sweep did something.
if [ "$swept" -lt 1 ]; then
  echo "❌ the syntax sweep executed no file — the sweep loops are present but the body is not"
  exit 1
fi

# Runtime self-check 2b: the SWEEP ARM must still be wired. The `swept` counter above proves the
# loop body RAN, but a body rewritten as `swept=$((swept+1))` alone keeps that counter at 73 while
# checking no syntax at all — so the arm is proven the same way as the shard arm: run a file that
# MUST fail, and require the failure to be recorded.
sentinel_sweep="$(mktemp)"
printf 'if then\n' >"$sentinel_sweep"
before_sweep_err=$shard_errors
sweep_file "$sentinel_sweep"
rm -f "$sentinel_sweep"
if [ "$shard_errors" -ne $((before_sweep_err + 1)) ]; then
  echo "❌ the sweep arm is broken — a file with a syntax error would not fail this run"
  exit 1
fi
shard_errors=$before_sweep_err
swept=$((swept - 1))

# Runtime self-check 3: the FAILURE-RECORDING arm must still be wired. Without this, a rewrite
# that keeps counting executions but drops the `|| shard_errors=…` clause would report success
# over a failing shard — a green check hiding a red bash body, the class this file exists to
# close. Proven by running a sentinel shard that must fail.
sentinel="$(mktemp)"
printf 'exit 1\n' >"$sentinel"
before_err=$shard_errors
before_ran=$shard_ran
run_shard "$sentinel"
rm -f "$sentinel"
if [ "$shard_errors" -ne $((before_err + 1)) ]; then
  echo "❌ the failure-recording arm is broken — a failing shard would not fail this run"
  exit 1
fi
shard_errors=$before_err
shard_ran=$before_ran

if [ "$shard_errors" -gt 0 ]; then
  echo "❌ $shard_errors bash shard(s) failed"
  exit 1
fi
echo "✅ all $shard_ran bash shards passed ($swept file(s) syntax-checked)"
