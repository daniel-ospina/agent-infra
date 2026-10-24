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
#
#   BASH_SHARD_SLICE=<i>/<n> bash scripts/run-bash-shards.sh   # run ONE slice of the list
#
# SLICING — why it is an ENV VAR and not an argument (#2055 follow-up; the `bash-suites`
# duration defect). Slicing exists because the JOB's DURATION, not runner capacity, was the
# bottleneck: `bash-suites` ran every shard serially in one step, reached ~2h46m on PR #2412,
# and reddened the PR — with no `timeout-minutes`, so nothing failed fast and nothing named
# the shard. The fix runs the list as a MATRIX, one job per slice.
#
#   ⛔ The slice arrives in the ENVIRONMENT, never as `--shard i/n` on the command line, because
#   the CALL SITE is load-bearing: `check-ci-lane-parity` asserts each lane's step `run` IS the
#   bare line `bash scripts/run-bash-shards.sh` (CALL_RE). An argument there reads as a MENTION,
#   not the call, and the lane un-wires — the #1369 class this file exists to close.
#
#   ⛔ The LIST is still HERE and only here. `n` is a LANE WIDTH — one integer — never a list of
#   suites, so no second copy exists that could drift from this one. A slice's expected size is
#   DERIVED below from the list length and `n`; nothing is enumerated in the workflow.
#
#   ⛔ Coverage is closed ARITHMETICALLY, not by trust: each slice asserts it executed EXACTLY its
#   derived count, and every slice also asserts `executed + skipped == listed`. The slices' counts
#   therefore sum to the whole list — a slice that silently runs nothing (or runs a neighbour's
#   shards twice) fails its own assertion instead of reporting a green check over a hole.

set -uo pipefail

# The syntax-sweep targets. A DATA list, not two literal `for f in …` lines: `--list-sweeps` prints
# exactly what the loops below iterate, so the sweep half cannot be advertised and not performed
# (or performed and not advertised) without editing this one line.
SWEEP_GLOBS=("scripts/*.sh" "scripts/lib/*.sh" "scripts/checkout-hygiene/*.sh" "scripts/harness-up" "scripts/harness-down" "scripts/harness-status")

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
# still reads its full count) fails loudly instead of reporting "all bash shards passed". A static check
# over this file's text could never catch that; running it can.
shard_errors=0
shard_ran=0
shard_skipped=0
shard_listed=0
shard_time=0
shard_slowest_secs=0
shard_slowest=""

# The list length, read from the same `run_shard` lines `--list` prints (one source). Needed
# BEFORE the run now: it bounds the slice arithmetic and marks where the sentinels begin.
listed="$(sed -n 's/^ *run_shard  *\([^ ]*\.sh\).*$/\1/p' "${BASH_SOURCE[0]}" | grep -c .)"

# ── slice selection — see SLICING in the header ────────────────────────────────────────────────
# Default: no slice (run the whole list) — the behaviour every existing caller keeps.
slice_index=-1
slice_count=0
if [ -n "${BASH_SHARD_SLICE:-}" ]; then
  case "$BASH_SHARD_SLICE" in
    *[!0-9/]*) echo "❌ BASH_SHARD_SLICE='$BASH_SHARD_SLICE' is not <index>/<count>"; exit 2 ;;
    */*/*)     echo "❌ BASH_SHARD_SLICE='$BASH_SHARD_SLICE' carries more than one '/' — want <index>/<count>"; exit 2 ;;
    */|/*)     echo "❌ BASH_SHARD_SLICE='$BASH_SHARD_SLICE' is missing its index or count — want <index>/<count>"; exit 2 ;;
  esac
  slice_index="${BASH_SHARD_SLICE%%/*}"
  slice_count="${BASH_SHARD_SLICE##*/}"
  # 10# so a leading zero stays decimal; `08` in arithmetic is otherwise an INVALID OCTAL error.
  slice_index=$((10#$slice_index - 1))
  slice_count=$((10#$slice_count))
  if [ "$slice_count" -lt 1 ]; then
    echo "❌ BASH_SHARD_SLICE count must be >= 1 (got '$BASH_SHARD_SLICE')"; exit 2
  fi
  if [ "$slice_index" -lt 0 ] || [ "$slice_index" -ge "$slice_count" ]; then
    echo "❌ BASH_SHARD_SLICE index must be 1..$slice_count (got '$BASH_SHARD_SLICE')"; exit 2
  fi
  # A slice wider than the list would leave some slices EMPTY: a job that proves nothing while its
  # check reads green. Refuse rather than report a vacuous pass (the #1369 shape, one level up).
  if [ "$slice_count" -gt "$listed" ]; then
    echo "❌ BASH_SHARD_SLICE asks for $slice_count slice(s) of $listed listed shard(s) — a slice would run nothing"; exit 2
  fi
fi

# slice_skips <0-based position> — 0 (true) = this slice does NOT run it, 1 (false) = it does.
# Slicing applies ONLY to list lines (`pos < listed`): the sentinels below sit past the list on
# purpose, so the vacuity arms ALWAYS execute — a slice must never be able to leave "can a failing
# shard fail this run?" untested. Positions are dealt round-robin (pos % n), so slow shards spread
# across slices instead of clustering in one (contiguous chunks would stack the expensive suites).
#
# ⛔ THE EXECUTED PATHS ARE RECORDED, not only counted (#2482 review, 2026-10-23). A COUNT cannot
# distinguish "ran my 10" from "ran MY NEIGHBOUR's 10": with the modulus broken so every slice runs
# the first slice's set, N=78 is caught only because 78 % 8 ≠ 0 — at N=80 all eight slices execute a
# correct COUNT (10 each) and print ✅ while 10 of the 80 shards never run at all. The list grows, so
# that decay is scheduled rather than hypothetical. The set is compared at the end.
shard_ran_log="$(mktemp 2>/dev/null || echo "/tmp/bash-shards-ran.$$")"
: > "$shard_ran_log" 2>/dev/null || true
trap 'rm -f "$shard_ran_log"' EXIT

# ── NAMING THE FAILING SHARD (#2643) ──────────────────────────────────────────────────────────
# The count alone is UNATTRIBUTABLE. `❌ 4 bash shard(s) failed` names no suite, so nobody reading
# the job — human or agent — can tell WHICH body of work is red without walking tens of thousands of
# lines up the log. Measured cost (2026-10-24): main and every PR carried the same four red shards
# for hours, `bash-suites` red on every PR head, and every lane re-derived those four from CI logs by
# hand, over a 5-minute fix. The names were in the log all along; they were just not in the answer.
#
# ⛔ TWO READERS, TWO MECHANISMS — and the rail is served by the OTHER one. `run_shard` emits
# `::error::bash shard failed: <path>`, a GitHub annotation, and `scripts/ci_exemption.py ids`
# recognises it as a guard-step identity that CARRIES the shard path — measured on a log with two of
# them: `guard-step::bash-suites-2::bash-shard-failed-tests-atomic-land-run.sh`, `ids=2`. That is what
# makes a red `bash-suites` step comparable to main's baseline PER SHARD, and it is NOT this block:
# measured against the prose lines printed here, the same parser returns `ids=0` — they neither help
# nor hurt it. Do not "fix" the rail here, and never delete the annotation while keeping these lines:
# that would leave every lane unattributable again.
#
# Two prints, on purpose — and the REASON is the early exits: the recap below is reached only at the
# END of a run, while this file has several `exit 1` paths ABOVE it (`shard target resolves outside
# this checkout`, `slice executed a DIFFERENT SET of shards`, and the two sentinels). On any of those
# the per-failure line is the only name the log will ever carry.
# LISTED shards only: the runtime sentinel at the end of this file deliberately runs a failing stub,
# and a green run must never print a FAILED SHARD line for it (`shard_is_listed` is 0 there).
shard_failed_list=""
shard_fail() {
  [ "$shard_is_listed" = 1 ] || return 0
  shard_failed_list="${shard_failed_list}${shard_failed_list:+, }$1"
  echo "❌ FAILED SHARD: $1"
}

slice_skips() {
  slice_pos=$shard_listed
  shard_listed=$((shard_listed + 1))
  # Whether this call is a LIST line or one of the sentinels below (used by the timing report).
  if [ "$slice_pos" -lt "$listed" ]; then shard_is_listed=1; else shard_is_listed=0; fi
  [ "$slice_count" -gt 0 ] || return 1
  [ "$slice_pos" -lt "$listed" ] || return 1
  [ $((slice_pos % slice_count)) -eq "$slice_index" ] && return 1
  shard_skipped=$((shard_skipped + 1))
  return 0
}

# shard_note <path> <seconds> — the per-shard timing row, and the running total/slowest. Separate
# from run_shard so the execution line stays one readable statement-chain (the mutation pins replace
# that whole line; everything they must disable has to live on it).
shard_note() {
  shard_time=$((shard_time + $2))
  if [ "$2" -gt "$shard_slowest_secs" ]; then shard_slowest_secs=$2; shard_slowest="$1"; fi
  printf '  ▸ %4ss  %s\n' "$2" "$1"
}

# One line on purpose: the execution and the counter that proves it happened are inseparable,
# so "stop executing but keep counting" is an explicit rewrite, not a one-line deletion. The skip
# branch is that explicit rewrite, and it is COUNTED (`shard_skipped`) so a skipped shard can never
# be mistaken for an executed one — see the coverage assertions at the end.
#
# The timing report is why the DURATION half of this file's own defect (a hung shard burning hours
# anonymously) can be measured at all: until now no lane printed how long a shard took, so "which
# shard is slow, which one hangs" was answerable only by watching a job's clock. It prints ONLY for
# list lines (`shard_is_listed`), so the sentinels cannot print a bogus row.
# ⛔ A FAILING SHARD MUST LEAVE AN IDENTITY THE MERGE RAIL CAN COMPARE (measured 2026-10-24: THREE
# failing PR runs, `ids=0`, and `scripts/admin-merge.sh` refused with "yielded NO parseable failure
# identity" — the block every lane hits while ANY suite on main is red). The rail's parser keys on a
# pytest `FAILED <nodeid>` or an attributable guard-step `::error::` annotation (ci_exemption.py,
# `guard_step_failures`), and this runner printed NEITHER: only `PASS=n FAIL=m` and
# "❌ FAILURES — fix and re-run". A red suite on main therefore made every PR unattributable (#1185).
# This annotation comes from THIS step, which the runner marks failed, so it is attributable by the
# parser's own rules and names the suite — the rail can rate-compare it against main's baseline instead
# of refusing. It does NOT weaken the comparison: a suite that fails here and is green on main is still
# a PR-unique failure and still blocks.
run_shard() { slice_skips "$1" && return 0; shard_ran=$((shard_ran + 1)); printf '%s\n' "$1" >> "$shard_ran_log"; shard_t0=$SECONDS; shard_err0=$shard_errors; bash "$1" || { shard_errors=$((shard_errors + 1)); [ "${1#/}" != "$1" ] || echo "::error::bash shard failed: $1"; }; [ "$shard_errors" -ne "$shard_err0" ] && shard_fail "$1"; [ "$shard_is_listed" = 1 ] && shard_note "$1" $((SECONDS - shard_t0)); return 0; }

# Sweeping is counted too: a `for` loop whose BODY was neutered (`: ` instead of `bash -n`) would
# otherwise leave the loops — and therefore any glob floor in the guard — perfectly intact while
# checking no syntax at all. `swept` is asserted below, so the sweep loops must have done work.
swept=0
# ⛔ SWEEP FAILURES ARE COUNTED SEPARATELY (#2643 review, 2026-10-24). `shard_errors` is the verdict
# and covers BOTH classes, so a recap that DERIVES "the sweep half" by subtracting the named shards
# is guessing: when the naming arm itself is broken, a failing SHARD opens the "all sweeps" branch and
# points the reader at the wrong subsystem. One counter, incremented where the failure happens.
# ⛔ THE ` || shard_errors=$((shard_errors + 1))` LITERAL SURVIVES IN `sweep_file` because
# `tests/ci-lane-parity/run.sh` §8h pins it by `sed` — and MEASURED, that `sed` changes ONLY
# `sweep_file` (plus a comment). `run_shard`'s recorder is the grouped form main added on 2026-10-24
# (`bash "$1" || { shard_errors=…; … echo "::error::…"; }`), so the sed never matched it, before or
# after this branch; `run_shard`'s recorder is pinned by the runtime failure-recording sentinel
# instead. The second counter below is therefore charged from the same DELTA idiom rather than by
# rewriting the recorder into another group, so a reader who trusts §8h keeps seeing exactly what
# §8h covers.
sweep_errors=0
sweep_file() { swept=$((swept + 1)); shard_err0=$shard_errors; bash -n "$1" || shard_errors=$((shard_errors + 1)); [ "$shard_errors" -ne "$shard_err0" ] && sweep_errors=$((sweep_errors + 1)); }

# Every listed target must be a real file INSIDE this checkout. Without this, a substitution that
# keeps the line count but points the list at a /tmp stub would report every shard as passed having
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
# PROVENANCE: these lines were moved out of ci-main.yml's `script-validate`, so each keeps the
# note that workflow carried. A line that is ALSO run by a dedicated per-PR job or step in ci.yml
# still carries its "(also a per-PR … in ci.yml)" note.
#
# ⛔ #2439 FOLDED THE DUPLICATE RUN SITES — this paragraph used to say the opposite, deliberately.
# It read: "That duplication is deliberate here … the PR lane runs those twice … Dropping them
# from this list to save the minutes would recreate the second, hand-kept list that #1369 exists
# to remove — the alternative is to retire the dedicated jobs and let this list be the PR lane's
# only coverage, which changes PR feedback granularity and is the owner's call, not a silent edit."
# OVERRIDES: that reservation — the owner directed the fold (agent-infra#2439), so the alternative
# named there is now the layout: the dedicated `admin-merge` job and `setup-suite` job are GONE
# from ci.yml and this list is the only run site for their suites. What was traded, exactly:
# PR feedback granularity (a red now names a shard of `bash-suites` rather than a dedicated job),
# measured at 3,110 runner-seconds per push on PR #2385's head. What was NOT traded: coverage.
# This list is the ONE list BOTH lanes run (#1369), so every folded suite still runs on every PR
# push and every push to main — and `tests/admin-merge-evidence-contract/run.sh`, which was the
# only step of the deleted job that was not already a shard, now runs POST-MERGE as well.
# ⛔ Do not "restore" the deleted jobs from this list's absence: the run site moved, it did not go.
# The fold assumes this step actually EXECUTES — a sibling step failing ahead of it skips the whole
# list, which is why agent-infra#2417 (the lane-parity self-test's live-gate control fixture) is a
# coverage hole for every shard, not just the folded five.
run_shard scripts/checkout-hygiene/deepseek-balance-watch.test.sh          # #476 balance poller (network-free seam)
run_shard scripts/checkout-hygiene/hub-state-check.test.sh                 # #1313 the DETECTOR (clean-but-stale PASS matrix)
run_shard scripts/checkout-hygiene/hub-worktree.test.sh                    # #1309/#1313 the RECOVERY half
run_shard scripts/install-launchd.test.sh                                  # #304 installer suite
run_shard scripts/install-controller-service.test.sh                      # #2402 the cell's controller is a SERVICE, not a tmux session: the rendered unit (Restart=always — NOT on-failure, the measured case is an orderly exit 0 — a stated RestartSec, and a StartLimit window that can actually fill at that RestartSec), the FOREGROUND exec that puts the controller in the unit's cgroup with the gh-limit layer still first on PATH (#1988), start/stop/status cooperating with an enabled unit instead of producing two dispatchers on one queue (#1761), the installer's refusals (Darwin/launchd, no service manager, a bad RestartSec, an unresolved token) and its idempotency, and the restart policy BOTH ways — a SIGKILL comes back, an ORDERLY exit 0 comes back, and the same exit-0 controller is NOT restarted under on-failure (the negative control that makes the other two mean something)
run_shard scripts/pi-reap-idle.test.sh                                     # #469 session reaper (fake PS/KILL/DATE shims)
run_shard scripts/pi-task-session-prune.test.sh                            # #783 retention sweep (dry-run default)
run_shard scripts/pi-cache-reap.test.sh                                    # #1987 the machine-global uv/npm/pip caches: an over-bound fixture MUST come back under it (prune first, escalate only with no live holder, and prove the shrink)
run_shard scripts/pi-reap-orphans.test.sh                                  # #1142 orphan reaper gates (deleted cwd + CPU advance + human ancestry; dry-run default)
run_shard scripts/pi-reap-worktrees.test.sh                                # #1095 worktree reaper gates
run_shard scripts/worktree-hygiene-sweep.test.sh                          # #2053 the 6-hourly sweep that runs BOTH reapers: its rc mapping, its remove-row count on a constructed fixture (the engine's rows are TAB-separated and the counter once read 0 forever), that a DRY RUN writes and removes nothing, that a missing engine prerequisite is rc=6 NAMED (not the generic 2 that let the job sit inert), and that the launchd template ships --dry-run — arming is a dated record behind an explicit verb that refuses a box whose sweep cannot run (#1678)
run_shard scripts/reap-lane-venvs.test.sh                                  # #1932 lane-.venv reaper: the liveness witnesses both ways (a live lane is KEPT, a dead one reaped), fail-closed on every unreadable probe, TOCTOU re-probe, and REAL ps/lsof/tmux fixtures
run_shard scripts/disk-reaper.test.sh                                     # #2032 ONE entry point over the three disk sinks: dry-run removes nothing, a LIVE-cwd worktree is never selected (and is reaped once the holder is gone), a MERGED checkout is, the size budget is honoured, a missing delegate fails closed, and the hourly timer renders armed + enabled
run_shard scripts/worktree-disk-probe.test.sh                              # #1851 apparent-vs-real disk measurement (df used delta, per machine)
run_shard scripts/cleanup-stale-branches.test.sh                          # #1787 local-branch reaper gates (the squash-merge-aware three gates, dry-run default)
run_shard scripts/scratch-worktree.test.sh                                 # #1141 scratch-checkout helper
run_shard scripts/bg-rescue-wip.test.sh                                    # #2045 THE CAP-KILL RESCUE: the archive carries CONTENT (read back from a bare remote, not just a ref), the branch and working tree and real index are NOT disturbed (a throwaway GIT_INDEX_FILE, safe under a live lane), a SECOND rescue after the grace period ACCUMULATES onto the first instead of being rejected non-fast-forward, an unreadable status / an unborn HEAD / a nested repo with no commit are each still archived (the fail-open that reported 'nothing at risk' on unrescuable work), a misrouted non-root path is refused, and an impossible push exits 2 saying the work is STILL ONLY ON THIS DISK. #2292: a WORKFLOW-SCOPE refusal is retried ONCE with the credential that can push (the clear-then-name keychain pair, asserted in order; no force, no config write at any origin; no prompt), a NON-workflow rejection is never retried (the stub would succeed on a second attempt, so a blanket retry shows up as a false success), a retry that is also refused reports BOTH causes without claiming a rescue, and the sha the success line claims is the sha origin's ref holds
run_shard scripts/daily-backup.test.sh                                     # #907 the backup target is RESOLVED from the port it publishes and PROVEN to answer before any state exists; the LOAD_GATE_FORCE path runs; an incomplete backup dir is removed
run_shard scripts/record-review.test.sh                                    # #1348 THE INCIDENT: runner-only rc=127 shipped green
run_shard scripts/conflict-rebase.test.sh                                  # #2698 the CONFLICTING queue is a treadmill, not a labour shortage: a clean rebase is PUSHED (real origin, main's change present exactly once), a content conflict is REFUSED with the branch UNTOUCHED + labelled, a record whose diff changed is moved off the canonical path while an identical diff keeps it, a head that is not the PR's own head / a moving head / a PR-named worktree / a `refs/claims/*` hold are each skipped, the cap bounds ATTEMPTS, --dry-run pushes and labels nothing, and an unreadable PR list is exit 2 rather than 'nothing to do'
run_shard scripts/registry-sync.test.sh                                   # #2374 the review-record registry's cross-box replication: a record minted on ANOTHER box becomes visible, a NEWER record wins and an OLDER one is refused in both directions, an equal-reviewed_at disagreement is REPORTED and nothing is overwritten, an unattributable legacy <pr>.json is never collapsed into a repo's key, a second run changes nothing (digest-asserted), and an unreadable store is UNKNOWN rather than 'converged' (hermetic: a local bare origin IS the shared store)
run_shard scripts/check-false-pass-shapes.test.sh                           # #2121 the three LEXICALLY-detectable false-PASS shapes (discarded status via a declaration builtin, empty-as-pass over a substitution, pre-existing count as evidence) — detection, the near-misses that must NOT be flagged, the '# verified:' marker, the (file,rule,count) baseline, and the real tree clean under it
run_shard scripts/ci_runner_gate.test.sh                                   # #1704 an unreadable queue count / a failed runner enumeration must not read as healthy; #1719 the launcher, the farm and the script must agree
run_shard scripts/ci_runner_pool.test.sh                                   # #2373 runner PROVISIONING in-repo + the reconciliation pass: the add floor refuses below 3.5 GB while printing the reading it used (owner decision #2344 comment 6347825624), a restart of a DEAD listener is NOT floor-gated and a LIVE one is not touched, the core-aware ceiling names both readings, an unreadable reading is cannot-measure (rc 2) and changes nothing, and a mutant with the floor comparison defused must stop refusing — so the floor assertion is live
run_shard scripts/orchestrator-harness/cloud-cell-record-dep.test.sh       # #1717 cmd_check must refuse a cell without record-review.sh, and a record failure must PARK (not re-pay)
run_shard scripts/diff-normalize.test.sh                                  # #1362 D1 review-evidence diff normalizer (one impl, shared with the gate) — ⛔ FOLDED HERE by agent-infra#2439 (it also ran as a step of ci.yml's `admin-merge` job on the same commit). The producer's integration pins live in scripts/record-review.test.sh §12, likewise a shard, so both halves run in BOTH lanes
run_shard scripts/session-postmortem.test.sh                              # #1921 the retrospective's Transcript Patterns producer is a FARMED SIBLING (resolved from the script's own dir), and an absent/failing producer FAILS the section and the run instead of leaving a placeholder that reads as produced
run_shard scripts/cloud-cell-supervisor.test.sh                            # #1713 a keys.env top-level exit must not turn a failed cell start into a silent success; #1761 the controller read/start/stop come from the lock (not the tmux session) and exclude descendant processes; #1989 the cell doctor is required, launched, stopped and reported
# ⛔ #1997 OWNS, AND NOTHING HERE PINS: the supervisor's classified-read invariant — `sup_session_list` answers 0 present / 1 absent / 3 cannot-verify, every tmux target is EXACT (`=name`), a session name carrying `:`/`.` is refused rather than resolved, and `TMUX_READ_TIMEOUT` is validated > 0. Its suite (`scripts/cloud-cell-supervisor.hardening.test.sh`) was DROPPED at ba5ba770 because the implementation it pinned was never landed on this branch, so these invariants are currently UNPINNED in this tree — they must return BESIDE the implementation (#1997's land), not as a shard line restored ahead of it.
run_shard scripts/orchestrator-bringup.test.sh                               # #1761 ONE entry point: a second controller for the SAME repo on this machine is refused (naming its pid) while a DIFFERENT repo is allowed, a stale record is reclaimed not blocked, and a configured repo path that is not on this machine is refused (#reseed repairs it without destroying lock/claim state)
run_shard scripts/fleet-inventory.test.sh                                   # #2026 THE FLEET INVENTORY: status prints COMPONENT|EXPECTED|ACTUAL|STATE for every declared component and exits with the worst row — DUPLICATE on two live instances (a lock is not proof), MISSING when one is absent, a matcher that cannot match itself, SKIPPED distinct from OK, and an unreadable ps as UNKNOWN/2 rather than green
run_shard scripts/orchestrator-harness/lander.test.sh                     # the versioned drain loop: a MERGEABLE+all-green PR is merged head-pinned, a PENDING one is NOT merged and NOT called failed (the measured case: 127 runs queued vs 5 in progress), a failing check is skipped and NAMED, a draft and a BLOCKED PR are reported with their reason, the CI queue depth is printed once per run even when nothing merges, and an unreadable board merges nothing — plus --nonvacuity, which deletes the pending arm and requires the PENDING assertion to break by name
run_shard scripts/orchestrator-harness/cloud-cell-doctor.test.sh            # #1989 the cell's reap/doctor/merge/hygiene roles: a lane whose child is still writing is NOT reaped, a human-attached/terminal lane is NOT touched, the rail is gated on a clean attestation at the head with no blind retry, an unreadable read is cannot-verify, and `status` FAILS a started cell whose roles never ran
run_shard scripts/orchestrator-harness/cloud-cell-doctor.hardening.test.sh  # #1989 the CLASSIFICATION invariant: every read a pass acts on answers 0/1/3, so a failed read never arrives as evidence (a kill is verified before it is counted, an unparseable process table or a DECREASING cpu reading is cannot-verify, an unreadable attestation never reads as "nothing to land", a bound-killed rail is not a refusal, a failed hygiene action is not a clean row, `--dry-run` keeps the WORSE verdict, and a role row's recorded rc reaches `status`'s exit status)
run_shard scripts/orchestrator-harness/cloud-cell-doctor.hygiene.test.sh    # #2573 the DISK-RECLAIM contract, in BOTH directions in one fixture: a stale `cloud-cell-<pid>.<rand>` dir (dead pid + past the idle floor) is reaped and a LIVE one, a no-pid one and a fresh one are LEFT with their reasons; `docker image prune -af`/`volume prune -f` run and `system prune` never does; an abandoned checkout is reclaimed while an unpushed commit and a dirty tree are preserved (driven through the SHIPPED reaper on real git); the cache sweep excludes the root a live cwd census HOLDS and still sweeps the idle ones (a live worker no longer suppresses every root), an unreadable census is cannot-verify/3, and every pass reports a signed `df` BEFORE → AFTER delta instead of a `du` sum
run_shard scripts/cloud-cell-bringup.test.sh                               # #1718 the pushed gh token must not outlive the bring-up, on ANY exit
run_shard scripts/orchestrator-harness/refresh-scout.test.sh               # #1736 a cell on a non-Python repo must provision dispatch (or refuse loudly), never merge-only-and-silent; #2094 a peer-held candidate is counted WITHHELD *and* (the #1729 half, same verdict arm) written to the collision ledger in the SAME pass — the one assertion a merge resolution that keeps either side alone cannot pass
run_shard scripts/orchestrator-harness/refresh-quota.test.sh               # #2022/#1736 follow-up + #1984/#2050 (the SAME shard, listed once — two lanes added it and the duplication was a lane-parity red): the refresh pass's per-pass API spend is BOUNDED — the board cache is enabled under the TOOL's seam (ONE rebuild per pass, not one per candidate), a starved pass judges FEWER candidates rather than none and still queues work, and a pass that can buy nothing NAMES the budget and refuses TRANSIENTLY (rc=1) instead of reporting an empty backlog — a budget that cannot buy one candidate refuses by name, and the refusal sits AFTER the `dispatched.txt` reaper, so a broke box still prunes its blacklist first (#2049/#1729 reconciled); an UNREADABLE budget is reported, not assumed (hermetic: stub gh, stub pre-flight, and a SCRIPTED core budget — no clock is faked, and this shard does NOT drive the board-cache TTL: `COLLISION_PREFLIGHT_BOARD_CACHE_TTL` expiry is reported, never exercised)
run_shard scripts/orchestrator-harness/pr-dispatch.test.sh                  # #2126 the PR path must be HONEST and COMPLETE: every counted un-owned PR is acted on or carries a PRINTED reason (the sweep's silent `continue`s, the NOCHECKS class with no arm, a failed spawn swallowed by `&&`, and five capacity `elif`s with no else), the funnel cannot claim "dispatching" on a cycle that spawned nothing, and the disposition ledger is never an input to the gate — behaviourally DRIVEN (extracted shipped fragments + stub gh/tmux), never a log-string grep
run_shard scripts/orchestrator-harness/pr-path-reads.test.sh               # #2601 the PR path must have a READ before it can act: `SWEEP_LIST` (the only ACTABLE row set — `pr \t branch \t draft`, which `state/pr-meta.tsv` does not carry) must SURVIVE the process, so a 304 cycle performs the read from the persisted rows instead of having no memory to inherit (measured: 152 of 221 cycles were 304s and spawned nothing), and the bounded rotating window must FINISH so the arms at the end of the loop are actually reached (measured: 0 act rows in 555 cycles). Drives the shipped blocks VERBATIM by marker in a SEPARATE SUBSHELL PER CYCLE (that is the real runtime, and the whole reason memory-only state was fatal), against a stub gh. ⛔ WIRED HERE because spawn-gate.test.sh asserts the UNWIRED population is exactly the two documented non-loop suites — an unwired new suite reds bash-suites by design (#1890, same class as gh-rest/merged-not-closed/worker-terminal)
run_shard scripts/orchestrator-harness/red-fixer.test.sh                    # #2223 the controller's RED-FIXER role: a rail refusal that names a RED TREE spawns ONE fixer for that PR (idempotent per PR, head-keyed, capped at MAX_RED_FIX_TRIES per head and MAX_RED_FIX per box), a NEW HEAD invalidates the refusal and RE-RAILS, the audited override is never taken, and the fixer's provider/model cannot be shadowed by the image's OPENAI_API_KEY — driven against a FAKE RAIL, hermetic (no network, no gh, no tmux)
run_shard scripts/orchestrator-harness/sweep-quota.test.sh                 # #1762 the merge sweep's listing must be conditional (ETag/304) and defer on the RESPONSE rate-limit headers, not /rate_limit
run_shard scripts/orchestrator-harness/harness-refresh.test.sh             # #2215 the box re-pins ITSELF once per cycle: behind+clean ADVANCES the pin old->new through the materialiser, an empty pin is MENDED and said out loud (the measured three-cells state), dirty / ahead / diverged / unresolvable each REFUSE and name themselves while touching nothing, a re-pin is not repeated on the next cycle (restart-pending), and the harness rides on every dispatch row and issue spawn line — driven against the SHIPPED script and the SHIPPED loop block (hermetic bare origin, stub materialiser)
run_shard scripts/orchestrator-harness/claim-exclusion.test.sh             # #1908 does a claim EXCLUDE a concurrent holder, per operation class — N processes raced at a barrier against a real receive-pack (hermetic bare origin)
run_shard scripts/orchestrator-harness/watchdog-loop.test.sh                  # #2303 the CONTROLLER WATCHDOG: a live pid with a stale heartbeat is WEDGED (the measured hour a pid-existence predicate calls healthy) and gets EXACTLY one restart, a dead pid is DOWN, a missing heartbeat is DOWN and never healthy, N consecutive wedges STOP restarting and record ONE crash line quoting the controller's own stdout that SURVIVES a restart, and a mutant with the heartbeat check removed must read the wedged box HEALTHY (non-vacuity)
run_shard scripts/orchestrator-harness/claim-reaper.test.sh                # a claim is RELEASED only when its holder is demonstrably GONE: absent holder + age over the threshold released ONLY with --release, a present holder or live WORK never released, an unidentifiable holder or an unparseable lease only REPORTED, the dry run changes nothing, and --max bounds the pass — plus `--mutations`, which disables one gate at a time and requires its case to go RED (hermetic: bare origin + fixture probes; no network, no real process)
run_shard scripts/orchestrator-harness/origination-funnel.test.sh          # #2229 a FAILED refresh must name its own stage/command/cause and must NEVER read as `[dispatch] skipped (…)`: the pass records `state/refresh-last`, the caller renders BLOCKED from it, a healthy pass NAMES the candidate it hands over, a deliberate deferral still says `skipped` WITH its reason, and every failure stage — plus an unreadable record and an absent one — is proven not to produce the mask
run_shard scripts/orchestrator-harness/product-floor.test.sh               # #2054 THE PRODUCT WORK FLOOR: a BATCH=2 dispatch with a dispatchable product candidate contains one, floor=0 is exactly today's order, the floor is clamped to the batch and never duplicates or resurrects a candidate, an unmet floor LOGS WITH THE QUEUE-STATE TOKEN and still dispatches, the floor yields to an EMERGENCY (a P0 in the batch window, or a red tree) and says so, an UNCLASSIFIABLE candidate never satisfies the floor, and the floor sits AFTER the merge-priority gate so it can never delay a batch (hermetic: the shipped functions are extracted and driven)
run_shard scripts/orchestrator-harness/test-gates.sh                       # the dispatch gate: mp_reason(prs, lanes, workers) must count workers, not lanes alone (hermetic)
run_shard scripts/orchestrator-harness/live-ownership.test.sh             # #2029 the owner's dispatch rule: ownership is a LIVE process cwd (REAL worktrees + processes; the 4 selection cases, incl. registry-claims-owned-but-dead)
run_shard scripts/orchestrator-harness/selftest.sh                         # #1764 harness self-test incl. the CI-red derivation (offline; previously local-only — review round 1 note)
run_shard scripts/orchestrator-harness/gh-rest.test.sh                     # #1959 the gh REST adapter's TRANSLATION (argv in, argv out) for exactly the shapes the harness calls: `pr list --head` must not silently widen to the newest open PR, and `pr comment` must print a URL — both shipped green before, as P0s. Offline, a stub gh; unwired since #1962 landed it, so spawn-gate.test.sh's population check was red on main (review round 1)
run_shard scripts/orchestrator-harness/merged-not-closed.test.sh       # #8468 the instrument that answers "which OPEN issue already has a MERGED PR?" — and the shape that matters is the one it must NOT answer: every unqueryable surface exits 2 (never 1, never an empty successful sweep), a path-shaped --repo is refused rather than sent to gh as repos/../x, and an empty sweep says it swept nothing. Hermetic: a stub gh. ⛔ WIRED HERE because `spawn-gate.test.sh` asserts the UNWIRED population is exactly the two documented non-loop suites — an unwired new suite reds bash-suites by design (#1890 fixed the same class for gh-rest.test.sh)
run_shard scripts/orchestrator-harness/gh-limit.test.sh                     # #1988 ONE gh call in flight per box; the documented backoff order (retry-after, then the bucket's reset, then >=60s doubling to a bounded failure); the bucket NAMED on failure; conditional REST (ETag/304) for polling. #2137 ACCOUNT scope: the budget partitioned by a declared fleet size, an unclassified refusal bounded to its own window (never the bucket reset), and a marker revalidated + aged before it may block. Fake clock, stub gh, hermetic
run_shard scripts/orchestrator-harness/gh-limit-pass-cache.test.sh  # #1984 the PASS-SCOPED read memo: inert unless asked, exact (stdout, stderr, rc) replay, and the four exclusions that make it safe — a failure, /rate_limit (the budget meter), `auth token` (the credential must never reach a cache file), and any mutation
run_shard scripts/orchestrator-harness/refresh-spend.test.sh             # #1984 a pass's own core-request SPEND: fleet-wide reads paid once per pass instead of once per candidate, an unchanged listing skipping the expensive sweep, an unreadable listing never read as 'unchanged', and LIMIT still an upper bound (hermetic: the real layer + a stub gh)
run_shard scripts/orchestrator-harness/spawn-gate.test.sh                  # #1765 the ONE agent-invocation helper: the disk gate, the load gate, and the three callers' exit codes (hermetic; review round 2 — it was served by NO lane, so its own residual check could never fire)
run_shard scripts/orchestrator-harness/ci-queue.test.sh                    # #2296 CI BACK-PRESSURE — the reading every other gate was missing: the ceiling is DERIVED from runners x horizon / job_p90 (not a constant), an unreadable queue DEFERS as UNKNOWN instead of opening the gate, the deferral line NAMES the depth/runners/ceiling and WHAT was deferred, EVERY CI-spending surface (fix-one.sh and adopt-fix.sh, the THREE fixer spawn arms in orch-loop.sh — CONFLICTED, CI-red and review-gate — the batch dispatcher, and the CI rerun) reads the SAME module so they cannot disagree, each of those fixer deferrals is DRIVEN by pr-dispatch.test.sh (a defer branch that also spawns goes red), a deferral consumes no attempt, and a mutant with the queue read disabled OPENS the gate (the red proof, with the driving namespace cleared so an inherited function cannot stand in for it). NOTE the fourth pusher, the RED-TREE fixer, is NOT gated yet — disclosed in the module header, home #2408
run_shard scripts/orchestrator-harness/worker-terminal.test.sh              # #1702 the worker LAUNCHER: no `tmux new-session`/`setsid` spawn may remain in either controller, a spawn creates a daemon-owned durable terminal where the cmux daemon answers and tmux WITH an explicit HOME+keys.env contract where it does not (the ~21-line death was the missing environment, not tmux — agent-infra#2210 reopened), a box with NO surface at all refuses, the census is fail-closed (unreadable ⇒ ALIVE), a close that cannot prove the surface is gone keeps its record, and the shipped `stat`/load/swap probes answer in BOTH the GNU and the BSD shape. ⛔ WIRED HERE because spawn-gate.test.sh asserts the UNWIRED population is exactly the two documented suites — an unwired new suite reds bash-suites by design (#1890); and (#2248) that the module INITIALISES under bash 3.2 — a heredoc nested in a command substitution is executed word-by-word there, killing the controller at source time, and this runner is Linux/bash-5 so it can never observe the mis-parse: that half is pinned TEXTUALLY
run_shard scripts/orchestrator-harness/capacity-transfer.test.sh            # #1909 R8: a capacity refusal must not consume the item's turn — the record the lane writes, the chain that stops waiting and RELEASES the cross-box claim, and the controller that stands down so a peer wins the CAS (hermetic; local bare repo, no network)
run_shard scripts/orchestrator-harness/install-launchd-durability.test.sh  # #1975 the installer must not be able to disable the production controller: no persistent-disable verb, bootstrap→load fallback, pid+heartbeat asserted, and "not running with rc=0" is a FAILURE (hermetic: stub launchctl + throwaway HOME; §F runs on Linux too — plutil stubbed, ELDATO_ALLOW_NON_DARWIN=1 — and skips loudly only when the checkout is not a usable git work tree)
run_shard scripts/orchestrator-harness/claim-cwd.test.sh                   # 2026-10-18 the claim builder must work from a cwd it was never given (a launchd cell's WorkingDirectory is not a repo): `git -C` returned an EMPTY hash and refused EVERY candidate with "could not build claim commit" while the controller looked alive. Hermetic: the denial is a git shim doing a real getcwd, the shipped claims.sh does the rest
run_shard scripts/orchestrator-harness/reviewer-preflight.test.sh          # #2148 the reviewer requirement is disclosed BEFORE the work: the one-line pre-flight disclosure and all three commands, both roles (self/harness), lane.sh's REAL dry-run output (the generated brief carries the step, fail-closed on a missing helper), the controller brief template, and non-vacuity controls proving the checks can fire. Hermetic: no network, no agent
run_shard scripts/orchestrator-harness/claim-orphan.test.sh                # #2094 a host RENAME must not orphan a lease forever: the owner host is re-derived per call, a stale CLAIM_OWNER_ID is rejected, an ORPHANED-HOST claim is reclaimable regardless of its term (pre-flight CLEAN, acquire reclaims, claim_prune reaps), a KNOWN live peer is never stolen, and no ttl can mint a term past its keying's ceiling (hermetic bare origin)
run_shard scripts/harness-cohesion.test.sh                                 # #2231 ONE launcher + a per-box divergence check: a failing self-test BLOCKS the start and names the test, an unread/unmaterialised pin dir is REFUSED (the #2216 "worktree nobody reads"), the three helpers answer IDENTICALLY with and without the commands one platform lacks (`timeout`/`gtimeout`/`pgrep -c`, shims that record any use), and `check-deployed-drift.sh --surface` names a home-only script, a differing script, a MISSING script, a component dir the RUNNING controller executes, and exits 2 (BROKEN, never OK) on an unreadable one. Hermetic: fixture repo + `DRIFT_PS` seam, no network. ⛔ The three entry points carry no `.sh` suffix by design (the operator types `scripts/harness-up`), so they are added to SWEEP_GLOBS above — the syntax gate would otherwise cover none of them
run_shard scripts/orchestrator-harness/deploy-harness.test.sh               # #2041 the deploy must report what the COPY did: an absent source fails against a target pre-seeded with 30 scripts (the measured false PASS), a copy that fails for one file is a FAILURE and never "partial success", a copy that "succeeds" but does not match the source is caught by the verification half, every failing path notifies FAILURE and none notifies success, and a preflight refusal leaves the target byte-identical (hermetic: scratch sources/runtimes + a notifier stub)
run_shard scripts/orchestrator-harness/capacity-placement.test.sh         # MEASURED placement + the SELF-DISPATCH PROOF (2026-10-21): one box saturated, a box twice its size idle, and nothing moved the work. The probe's fields (load-per-cpu, lanes, free disk, free memory), the 8.00 load-per-cpu ceiling and what it protects, the least-loaded-eligible choice, an unreadable/stale/absent record never being chosen, a no-eligible-box REFUSAL that names the bound, and the per-cycle record + `bin/harness status` reading a two-cycle-stale controller DEGRADED and an absent one ABSENT — never HEALTHY. Hermetic: seams for clock/host, and a LOCAL bare repo as the shared origin (real pushes, real ls-remote)
run_shard scripts/orchestrator-harness/landing-read.test.sh                   # #2320 a box whose gh chain cannot reach a REAL binary, and an EMPTY protection read, are NAMED on `bin/harness status` (gh=CANNOT-REACH-REAL-GH naming the layer that was identified statically as a wrapper/shim, or quoting a PROBED wrapper's own refusal words / contract=UNREADABLE why=<token>) as their OWN dimension beside the cycle verdict — so a landing blocker is never mistaken for load, and never mistaken for a pass. Drives the shipped verb over stub PATHs; mutation controls delete the resolution read and make the empty contract a pass, and BOTH assertions go RED. Hermetic: stub gh, `OR` pinned, no network, no repo
run_shard scripts/harness-surface.test.sh                                  # #2286 the surface the ONE launcher was missing: an `exec` row that reads the RUNNING controller's OWN argv, resolves the tree it executes and compares that COMMIT with the pin (GREEN=HEALTHY on the pin's tree, RED=DEGRADED naming both shas when it is one restart behind); `up` twice is a NO-OP that starts nothing and kills nothing (the authority is invoked once — the pre-change second run called it again and reported FAILED); the capacity ceiling is MEASURED from load+disk at the decision and a fixed cap is REPORTED AND IGNORED, with an unmeasurable box REFUSING rather than substituting the cap; and the macOS arm is EXERCISED on Linux (`HARNESS_UP_OS=Darwin` + BSD-shaped `mktemp`/`stat`/`sysctl`/`launchctl` stubs, including the `mktemp` that requires a TEMPLATE and killed every prior Apple run at the launcher's last line). Hermetic: fixture git worktrees, stubbed `ps`/`tmux`/autorities, no network
run_shard scripts/mac-pin-parity.test.sh                                   # #2231 the MAC runs the same PINNED tree as the cells: the rendered job's program is the pinned worktree (never `$O`, `~/orchestrator` or `~/.cache/orc`), the FIRST pin is materialised by the cells' own `apply --force --pin-only`, and the installer REFUSES (rc=78, both paths named) on a COPY, a pin/tree disagreement, an unreadable or unexaminable record, no pin with no materialiser, and a LIVE-ONLY entrypoint the pin does not carry; on macOS it also reads the INSTALLED plists and reds when any job runs a repo script from outside the pin. Carries the home-dir-only fix register (carrier + witness + shard wiring) and a `timeout`/`gtimeout`/`pgrep -c` portability gate. Hermetic: fixture git repo + sandbox HOME, no network, no launchd
run_shard tests/admin-merge/run.sh                                         # #930 safe-admin-merge rail — ⛔ FOLDED HERE by agent-infra#2439: it used to ALSO be a step of ci.yml's `admin-merge` job, which re-ran this suite on the SAME commit (993 s of that job's 3,009 s, measured on PR #2385's head at 39879010341). One run site, and it is the one BOTH lanes execute (#1369)
run_shard tests/atomic-land/run.sh                                         # #1367 atomic land unit — ⛔ FOLDED HERE by agent-infra#2439 (same duplicate job; this suite was 1,920 s of it, 32 min). The land step DELEGATES to admin-merge.sh and the record step to record-review.sh; the suite pins only the sequencing and the fail-closed preconditions
run_shard tests/record-review/run.sh                                       # the lane-dimension carry (#6072/#6213/#4823): a base-only head move must CARRY, lane work must REFUSE, and a lying local base ref must REFUSE
run_shard tests/review-pr/run.sh                                           # the REVIEW SEAM a lander runs (scripts/review-pr.sh): a fresh-context reviewer's CLEAN verdict is RECORDED bound to the reviewed head, findings are NOT recorded (exit 7, printed), an unresolvable repo / no auth / missing `pi` / no verdict / a head that moved mid-review all refuse with no record, an unchanged head is never re-recorded, an ambient GH_REPO cannot choose the repo, and a MUTANT that removes the clean-only guard records a false `clean` (hermetic: stub gh, fake pi, fake recorder)
run_shard tests/gh-shim/run.sh                                             # #984 argv-level gh shim — ⛔ FOLDED HERE by agent-infra#2439 (same duplicate job, 86 s): the shim inspects its OWN argv, where bash has already resolved `-${V:--}admin=true` into `--admin`, and the suite drives it through a real shell with the splices that defeated the string scanner
run_shard tests/admin-merge-evidence-contract/run.sh                       # #1388 the ONE certificate contract, pinned against a REAL captured evidence comment rather than a hand-written fixture (bcbb7df renamed the producer's residual clause and BOTH gates kept requiring the old name — six days of fleet-wide refusals with every suite green). ⛔ MOVED HERE from ci.yml's `admin-merge` job by agent-infra#2439: the suite was the ONLY step there that was not already a shard, so folding it is what let that job go — and, unlike the job, this list runs in BOTH lanes, so the post-merge lane now runs it too (it previously ran at PR time only)
run_shard tests/pipeline-compliance-fetch-stderr/run.sh                    # #1876 in the FETCH path: a warning on a SUCCESSFUL gh call is SURFACED, never parsed (stderr merged into the --jq stream turned it into "invalid character ... looking for beginning of value") and a FAILED call reports BLOCKED-BY-TOOLING, never a policy failure. Mutation included: the stderr-merged variant must fail
run_shard tests/pi-shim/run.sh                                             # #1884 the SPAWN-POINT load gate: a caller that sources nothing is refused anyway (also driven end-to-end by the two pi-bootstrap installer suites above)
run_shard scripts/orchestrator-harness/merge-reminder.test.sh              # #2603 the merge reminder's ACTUATOR ARM is gated on EVIDENCE: an attested-at-head + quiet + unclaimed + idle surface DISPATCHES `admin-merge.sh`, and every single gate failure refuses BY NAME (stale record, reds=0/in-flight=3, claim held, rail running) — plus the grouping rule (a re-run to success is not red; a same-named job in ANOTHER workflow cannot mask a red), the deploy arm's artifact-verified restart, `rate_limit` read FIRST with a thin budget spending nothing else, and two MUTANTS proving the gates are live (hermetic: stub gh/ps/rail, a real git claim ref)
run_shard tests/search-cost/run.sh                                         # #1069 fleet search cost (also a per-PR job in ci.yml)
run_shard tests/git-fixture-host-neutral/run.sh                           # agent-infra#2581: a fixture's verdict must not be a function of the BOX. main's own post-merge leg was red (check-run 120643122366) with two `FAILED extensions/…` annotations while both suites were green wherever the box's EFFECTIVE git config supplied `init.defaultBranch=main` — both built an EMPTY bare origin and cloned it, so the clone's branch came from that config (`master` when unset ⇒ `git push origin main` dies on `error: src refspec main does not match any`), and WHICH channel supplies it differs per suite (one reads the global `~/.gitconfig`, the other replaces HOME so only the system/ambient channel reaches it). The fixtures now name their own branch (`init --bare -b main`); this shard runs those suites with every ambient git-config source neutralised, plus two anti-vacuity arms (the child must provably read NO global config, failing with the actual `fatal:` message when the seam breaks; and an empty bare created with `-b main` must clone onto `main` in that environment). ⛔ In this list — not in a workflow step — because ci.yml/node-ci.yml/ci-main.yml are BYTE-LOCKED (scripts/check-workflow-lock.mjs) and a ci-main line would only run POST-MERGE, after the damage
run_shard tests/beat-pair/run.sh                                           # #7957 H3 the recap/beat pair is BOUND, not merely written twice: a fresh recap beside a stale beat must SUPPRESS the act clause, never publish the previous tick's number (hermetic)
run_shard scripts/heartbeat-loop.test.sh                                   # #1933 the detached children's exit status is CAPTURED and REPORTED. ON `origin/main` (`7a051b7b`) THE REPORT WAS ABSENT, NOT UNREACHABLE: #2056 (`838228de`) had already deleted queue-dispatch's `if [ "$rc" -ne 0 ]` branch, left a bare `rc=0` (line 581) with no reader at all, and `QUEUE-DISPATCH FAILED` survived there only in comments (91, 229, 431). A branch cut BEFORE `838228de` (this branch's fork point `57edbd7a`) still carried the pair — literal `rc=0` directly above that branch — where it could never fire. Either way no pass could print the line, and the fix ADDS the report rather than repairing it. The word now follows the rc (`REFUSED` for exactly 2, `PR-DOCTOR RED rc=N` for any other non-zero, so a crash is never called a refusal). Drives REAL one-pass runs of the real loop against stubbed children (hermetic)
run_shard tests/heartbeat-fleet-advance/run.sh                             # #1991 the beat carries the FLEET ADVANCE standing order on BOTH bodies, in SIXTEEN fleet states (0 / 1 / 2 / 6 / 12 / 26 lanes, idle capacity, alert+capacity, dead panes, no-live-pi, questioning, alerting, queue-bottleneck, objective-at-risk, a warm tick, and the recovery-refusal path), each delivered body pinned to a byte-for-byte GOLDEN with the four sentences exactly once, the order EMBEDDED in the literals, the single send pinned, and a mutant proving the assertions are live (hermetic; drives the real tick against stubbed helpers, a stubbed screen and a recorded cmux send)
run_shard pi-bootstrap/tests/test-setup-no-nesting.sh                      # #449 setup regression (~2min) — ⛔ FOLDED HERE by agent-infra#2439: it used to ALSO be ci.yml's whole `setup-suite` job, which re-ran this one suite on the SAME commit (17 s of that job's 23 s). This shard is now the ONLY run site; the #447 ship-list drift class it guards is unchanged
run_shard pi-bootstrap/tests/test-models-merge.sh                          # #682 setup.sh's models.json merge must preserve live-only model ids/override keys (RED control included); both lanes by construction
run_shard pi-bootstrap/tests/test-cell-install.sh                          # #1723 a Linux cell receives the operational layer (the farmed scripts, the guards, the skills, record-review.sh) BY CONSTRUCTION, and refuses a partial one
run_shard pi-bootstrap/tests/test-farm-unfarm.sh                            # #1924 the farm has an UNFARM leg: two farmed scripts, one retired, re-applied — the retired one is gone from $DEST/scripts AND the other SURVIVED (an over-deleting removal leg is worse than the gap), a retirement a farm array still declares removes nothing and fails the run, an escaping entry is refused, and a cell is not certified while it still carries a retired artifact

echo "───────────────────────────────────────────────────────────────────"
# Runtime self-check 1: every listed shard must have been EXECUTED. This is the arm that catches
# a helper whose execution was disabled — a text-only floor would still see the same listed count.
# Runtime self-check 1: every listed shard must have been EXECUTED or DELIBERATELY SKIPPED for
# this slice. This is the arm that catches a helper whose execution was disabled — a text-only
# floor would still see the same listed count. `executed + skipped == listed` also means the list
# was traversed end to end: a slice cannot quietly stop early.
if [ $((shard_ran + shard_skipped)) -ne "$listed" ]; then
  echo "❌ executed $shard_ran of $listed listed shard(s) ($shard_skipped skipped) — the list and the execution disagree"
  exit 1
fi

# Runtime self-check 1b: slice COVERAGE. Each slice must execute exactly its derived share, so the
# slices' counts sum to the list: `expected = |{ p < listed : p % n == i }|`. A slice that runs the
# wrong subset (off-by-one in the modulus, an unreadable env var, a stray `continue`) fails here,
# and so does an unsharded run that skipped anything.
if [ "$slice_count" -gt 0 ]; then
  # ⛔ IDENTITY, not a count. The expected set is DERIVED from the same list and the same round-robin
  # the skips use (`pos % n == i`), and compared as a SORTED SET, so a slice that runs the right
  # number of the WRONG shards fails here — the hole a count assertion reports as green.
  exp_log="$shard_ran_log.expected"
  sed -n 's/^ *run_shard  *\([^ ]*\.sh\).*$/\1/p' "${BASH_SOURCE[0]}" \
    | awk -v i="$slice_index" -v n="$slice_count" '(NR - 1) % n == i' | sort > "$exp_log"
  sort "$shard_ran_log" > "$exp_log.ran"
  if ! cmp -s "$exp_log" "$exp_log.ran"; then
    echo "❌ slice $((slice_index + 1))/$slice_count executed a DIFFERENT SET of shards than its index derives (expected $(wc -l <"$exp_log" | tr -d ' '), ran $(wc -l <"$exp_log.ran" | tr -d ' ')); first difference: $(diff "$exp_log" "$exp_log.ran" | head -4 | tr '\n' ' ')"
    rm -f "$exp_log" "$exp_log.ran"
    exit 1
  fi
  rm -f "$exp_log" "$exp_log.ran"
  expected=$(( (listed - 1 - slice_index) / slice_count + 1 ))
  if [ "$shard_ran" -ne "$expected" ]; then
    echo "❌ slice $((slice_index + 1))/$slice_count executed $shard_ran shard(s), expected $expected — the slice does not cover its share of the list"
    exit 1
  fi
elif [ "$shard_skipped" -ne 0 ]; then
  echo "❌ $shard_skipped shard(s) skipped without a slice (BASH_SHARD_SLICE unset) — an unsharded run must execute every listed shard"
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
# loop body RAN, but a body rewritten as `swept=$((swept+1))` alone leaves that counter reading a
# full, non-zero count while checking no syntax at all — so the arm is proven the same way as the
# shard arm: run a file that MUST fail, and require the failure to be recorded.
sentinel_sweep="$(mktemp)"
printf 'if then\n' >"$sentinel_sweep"
before_sweep_err=$shard_errors
before_sweep_errors=$sweep_errors
sweep_file "$sentinel_sweep"
rm -f "$sentinel_sweep"
if [ "$shard_errors" -ne $((before_sweep_err + 1)) ]; then
  echo "❌ the sweep arm is broken — a file with a syntax error would not fail this run"
  exit 1
fi
# Both counters are restored to their PRE-sentinel values (not decremented): a decrement silently
# assumes the sentinel incremented, and this file's whole discipline is that an assumption about a
# counter is what a refactor invalidates.
shard_errors=$before_sweep_err
sweep_errors=$before_sweep_errors
swept=$((swept - 1))

# Runtime self-check 3: the FAILURE-RECORDING arm must still be wired. Without this, a rewrite
# that keeps counting executions but drops the `|| shard_errors=…` clause would report success
# over a failing shard — a green check hiding a red bash body, the class this file exists to
# close. Proven by running a sentinel shard that must fail.
sentinel="$(mktemp)"
printf 'exit 1\n' >"$sentinel"
before_err=$shard_errors
before_ran=$shard_ran
before_skip=$shard_skipped
before_listed=$shard_listed
run_shard "$sentinel"
rm -f "$sentinel"
if [ "$shard_errors" -ne $((before_err + 1)) ]; then
  echo "❌ the failure-recording arm is broken — a failing shard would not fail this run"
  exit 1
fi
shard_errors=$before_err
shard_ran=$before_ran
shard_skipped=$before_skip
shard_listed=$before_listed

if [ "$shard_errors" -gt 0 ]; then
  echo "❌ $shard_errors bash shard(s) failed"
  # The recap (#2643). Three shapes, each REPORTED from what was counted — never inferred from what is
  # absent: a failing shard is named; a failing syntax sweep named its own file at the `bash -n` line;
  # and a failure with NEITHER means the naming arm is broken, which is a defect in this runner and must
  # say so rather than blame a subsystem it never looked at.
  if [ -n "$shard_failed_list" ]; then
    echo "❌ failing shard(s): $shard_failed_list"
    # ⚠️ A MIXED RUN MUST ACCOUNT FOR ITS COUNT. `shard_errors` counts BOTH failing shards and failing
    # syntax sweeps; the list above names only the former. Printing "2 failed" beside one name reads as
    # a missing name — and the missing half is exactly what the recap exists to stop hunting for.
    if [ "$sweep_errors" -gt 0 ]; then
      echo "❌ …and $sweep_errors of them are SYNTAX-SWEEP failures, not shards — each named at its own 'bash -n' line"
    fi
  elif [ "$sweep_errors" -eq "$shard_errors" ] && [ "$sweep_errors" -gt 0 ]; then
    echo "❌ every failure above is a syntax-sweep failure, named at its own 'bash -n' line"
  else
    # Mixed AND unnamed: a broken naming arm alongside a failing sweep. Do NOT claim the sweep caused
    # everything — measure it. (Final review: this branch used to say "every failure above is a
    # syntax-sweep failure", which sent triage to fix the sweep and lose the unnamed shard with it.)
    echo "❌ no shard is named, and $((shard_errors - sweep_errors)) of the $shard_errors failure(s) is/are NOT a syntax sweep — the naming arm is not wired for them. This is a defect in scripts/run-bash-shards.sh, not in the shard: read the per-shard output above for the path."
  fi
  exit 1
fi
if [ "$slice_count" -gt 0 ]; then
  echo "✅ all $shard_ran bash shards passed (slice $((slice_index + 1))/$slice_count of $listed; $swept file(s) syntax-checked)"
  echo "   ⏱  this slice: ${shard_time}s of shard work over $shard_ran shard(s); slowest ${shard_slowest_secs}s${shard_slowest:+ ($shard_slowest)}"
else
  echo "✅ all $shard_ran bash shards passed ($swept file(s) syntax-checked)"
  echo "   ⏱  ${shard_time}s of shard work; slowest ${shard_slowest_secs}s${shard_slowest:+ ($shard_slowest)}"
fi
