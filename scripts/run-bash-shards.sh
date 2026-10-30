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
# DERIVATION — the list is DISCOVERED, never enumerated (agent-infra#2609)
# ---------------------------------------------------
#   Until this change the list was 79 hand-appended `run_shard <path>` lines. Measured 2026-10-23:
#   21 of the 71 open PRs in this repo touched this one file, so any two harness PRs conflicted
#   here and every merge re-conflicted the rest. #1369's decision — ONE list, BOTH lanes run it —
#   is unchanged and honoured: the list still exists in exactly ONE place, but that place is now a
#   DERIVATION over the tree, so adding a suite is adding a FILE, and no two PRs conflict on this
#   file to wire one.
#
#   DISCOVERY is by the conventions the suites already follow (SUITE_GLOBS below):
#   `scripts/*.test.sh`, `scripts/*/*.test.sh`, `scripts/orchestrator-harness/test-*.sh`,
#   `scripts/orchestrator-harness/selftest.sh`, `tests/*/run.sh`, `pi-bootstrap/tests/*.sh`.
#   STATED LIMIT: a suite named outside those conventions is not discovered — the same stated-limit
#   form `scripts/orchestrator-harness/spawn-gate.test.sh` uses about its own population.
#
#   ORDER is `LC_ALL=C sort -u` over the discovered paths: deterministic on every machine and
#   independent of filesystem order (a shard assignment that shifted between runners would make
#   every timing number incomparable). The order carries NO meaning: every suite is hermetic (see
#   CONTRACT) and the slice a shard lands in was already re-derived on every list insertion.
#
#   EXCLUSION is DECLARED in the suite, never an omission from a list: a discovered suite that must
#   not run here carries `# shard: off <reason>` in its own header. ⛔ The fail-closed direction is
#   RUN — no marker means the suite runs, so the dangerous direction (a suite silently missing from
#   CI) needs an explicit written reason. A marker with NO reason, or an unrecognised `# shard:`
#   spelling, REFUSES the run (exit 2); it never degrades to "skip" or "run".
#
# CONTRACT
#   - Runs every shard; the accumulator keeps going so one failure cannot hide the others.
#   - Exits 1 if any shard failed, 0 otherwise — and NAMES each failing shard (a bare
#     "N bash shard(s) failed" was unattributable: a syntax error in one suite read as a
#     whole-list failure with no name).
#   - Hermetic: every suite builds its own temp repos/HOME/shims and touches no real state.
#   - `--list` prints the DERIVED shard list (DERIVATION above), `--list-sweeps` the syntax-sweep
#     globs. Both print the lists this script EXECUTES, from one source each (SUITE_GLOBS + each
#     suite's opt-out marker, and SWEEP_GLOBS below), so `check-ci-lane-parity` can read them
#     without keeping a second, divergent copy.
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
#   ⛔ The LIST is still derived HERE and only here. `n` is a LANE WIDTH — one integer — never a
#   list of suites, so no second copy exists that could drift from this one. A slice's expected
#   size is DERIVED below from the list length and `n`; nothing is enumerated in the workflow.
#
#   ⛔ Coverage is closed ARITHMETICALLY, not by trust: each slice asserts it executed EXACTLY its
#   derived count, and every slice also asserts `executed + skipped == listed`. The slices' counts
#   therefore sum to the whole list — a slice that silently runs nothing (or runs a neighbour's
#   shards twice) fails its own assertion instead of reporting a green check over a hole.

set -uo pipefail

# ── the checkout this script BELONGS to ───────────────────────────────────────────────────────
# Discovery reads the TREE, so the globs must resolve from the checkout the script lives in, not
# from the caller's cwd. Two reasons, both measured in review (agent-infra#2609): the pre-change
# `--list` read the script's own TEXT and therefore worked from anywhere, while the run path was
# already cwd-dependent — one driver with two contracts; and a lane invoking it by ABSOLUTE path
# from another directory got an empty `--list` and a run-path refusal. Anchoring both to
# `${BASH_SOURCE[0]}/..` makes the two entry points agree and keeps the containment check
# (`pwd -P` below) anchored to the same root.
SHARD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || {
  echo "❌ cannot resolve the directory this script lives in — refusing to derive a list from an unknown tree" >&2
  exit 2
}
# In the repo the driver lives at <root>/scripts/…, so the root is one level up. A fixture that
# copies it to <root>/… is the root itself — both layouts are stated here rather than guessed, so a
# copy in a scratch repo does not silently read the PARENT of the tree it was pointed at.
if [ "$(basename "$SHARD_ROOT")" = "scripts" ]; then
  SHARD_ROOT="$(dirname "$SHARD_ROOT")"
fi
cd "$SHARD_ROOT" || {
  echo "❌ cannot enter $SHARD_ROOT — refusing to derive a list from a tree it cannot read" >&2
  exit 2
}

# The syntax-sweep targets. A DATA list, not two literal `for f in …` lines: `--list-sweeps` prints
# exactly what the loops below iterate, so the sweep half cannot be advertised and not performed
# (or performed and not advertised) without editing this one line.
SWEEP_GLOBS=("scripts/*.sh" "scripts/lib/*.sh" "scripts/checkout-hygiene/*.sh" "scripts/harness-up" "scripts/harness-down" "scripts/harness-status")

# ── the shard list: DISCOVERED from the tree, never enumerated (see DERIVATION in the header) ──
# A DATA list in the same shape as SWEEP_GLOBS, and the ONLY list of suites: `--list` prints what
# these globs resolve to, so the runner and the guard still read one source and no second copy can
# drift from it. ⛔ A suite is added by adding a FILE that matches one of these; nothing here is
# edited to wire one.
SUITE_GLOBS=(
  "scripts/*.test.sh"
  "scripts/*/*.test.sh"
  "scripts/orchestrator-harness/test-*.sh"
  "scripts/orchestrator-harness/selftest.sh"
  "tests/*/run.sh"
  "pi-bootstrap/tests/*.sh"
)

# shard_marker <path> — a suite's own declaration, read from its HEADER only (the first 20 lines),
# so a `# shard:` line buried in a body cannot speak for a file whose header said nothing.
shard_marker() { awk 'NR > 20 { exit } /^# shard:/ { print; exit }' "$1" 2>/dev/null; }

# shard_discover — the candidates, one per line, in GLOB order (shard_list fixes the order).
# ⛔ The fail-closed direction is RUN: no marker ⇒ the suite runs, so the dangerous direction —
# a suite silently missing from CI — requires a WRITTEN reason in the suite itself. "Written" is
# load-bearing: `# shard: off` with nothing after it, or with only whitespace, REFUSES the run
# (review finding, #2609 — a trailing space used to turn "refuse" into "drop from CI").
shard_discover() {
  local g f m reason
  for g in ${SUITE_GLOBS[@]+"${SUITE_GLOBS[@]}"}; do
    for f in $g; do
      [ -f "$f" ] || continue
      m="$(shard_marker "$f")"
      case "$m" in
        "") printf '%s\n' "$f" ;;
        "# shard: off")
          echo "❌ $f declares '# shard: off' with NO reason — refusing to run: an unexplained exclusion is an omission, not a decision" >&2
          return 2 ;;
        "# shard: off "*)
          reason="${m#\# shard: off }"
          case "$reason" in
            *[![:space:]]*) : ;;   # a DECLARED opt-out: the reason is the rest of the line
            *)
              echo "❌ $f declares '# shard: off' with NO reason (only whitespace) — refusing to run: an unexplained exclusion is an omission, not a decision" >&2
              return 2 ;;
          esac ;;
        *)
          echo "❌ $f carries an unrecognised shard marker '$m' — refusing to run (the only marker is '# shard: off <reason>')" >&2
          return 2 ;;
      esac
    done
  done
}

# shard_list — the list. Sorted with LC_ALL=C so the order is the same on every machine and does
# not inherit the filesystem's (a shard assignment that shifted between runners would make every
# timing number incomparable); de-duplicated, because a path matched by two globs is ONE shard and
# a repeated target is not extra coverage. A discovery error propagates — AND NOTHING IS PRINTED:
# a caller that ignored the status must not be handed a partial list that looks whole.
shard_list() {
  local out
  out="$(shard_discover)" || return 2
  [ -n "$out" ] || return 0
  printf '%s\n' "$out" | LC_ALL=C sort -u
}

if [ "${1:-}" = "--list" ]; then
  # The same derivation, the same sort and the same source as the run below — never a second scan.
  # ⛔ AN EMPTY DERIVATION IS A REFUSAL HERE TOO: printing nothing and exiting 0 hands a consumer a
  # vacuous "the list is empty" that looks like a clean answer (review finding, #2609).
  shard_list_out="$(shard_list)" || exit 2
  if [ -z "$shard_list_out" ]; then
    echo "❌ the derived shard list is EMPTY — refusing to print an empty list as if it were the list (cwd $(pwd -P)): do the discovery globs match this tree?" >&2
    exit 2
  fi
  printf '%s\n' "$shard_list_out"
  exit 0
fi

if [ "${1:-}" = "--list-sweeps" ]; then
  # `${SWEEP_GLOBS[@]+…}` and not a bare expansion: bash 3.2 (macOS) treats `"${A[@]}"` on an
  # EMPTY array under `set -u` as an unbound variable, so this line exited 1 for an emptied list and
  # `check-ci-lane-parity`’s §6 fixture reported "the lane’s own sweep list is unreadable" instead of
  # the no-sweeps floor it was measuring. The same idiom guards SUITE_GLOBS above.
  printf '%s\n' ${SWEEP_GLOBS[@]+"${SWEEP_GLOBS[@]}"}
  exit 0
fi

# ⛔ THE PLACEMENT GUARD (agent-infra#3011) RUNS BEFORE ANY WORK, not merely before the shard loop.
# This is the ONE seam every suite passes through (both lanes call this script), so the guard lives
# here instead of in 70-odd copies of the same check — and it must fire BEFORE the syntax sweeps or a
# live cell pays for a full `bash -n` sweep before being told it should not be running suites at all.
# A CELL IS A CAPACITY RESOURCE: its load is the fleet's own busy signal, and suites run there leaked
# 145 fixture controllers onto `pi-cell-4` (load 39 on 8 cores) because nothing refused. It is a no-op
# on a laptop/CI (no controller executes from a cell root) and refuses with EX_CONFIG (78) — a
# REFUSAL, not a test failure — unless HARNESS_SUITE_ALLOW_LIVE_CELL=1 is set. `--list`/`--list-sweeps`
# above exit before this point on purpose: they execute nothing, so they stay readable everywhere.
# shellcheck source=orchestrator-harness/fixture-hermetic.sh
. "$SHARD_ROOT/scripts/orchestrator-harness/fixture-hermetic.sh"
# ⛔ FAIL CLOSED ON THE SOURCE ITSELF. A `command not found` here would exit 127 once and then let
# every suite run anyway — a guard that cannot fire is the failure class #3011 belongs to ("an
# enforcer that cannot fire"), and `bash -n` cannot see it. If the helper is not loadable this driver
# refuses rather than running the whole population unguarded.
command -v fixture_guard_placement >/dev/null 2>&1 || {
  echo "❌ cannot load scripts/orchestrator-harness/fixture-hermetic.sh — refusing to run shards with the #3011 placement guard inert" >&2
  exit 2
}
fixture_guard_placement "run-bash-shards.sh"

# run_shard <path> — one shard. `shard_ran` is what makes the list SELF-CHECKING at runtime: the
# counters are compared against the derived count at the end, so a neutered helper (executing
# nothing while the list still reads its full count) fails loudly instead of reporting "all bash
# shards passed". A static check over this file's text could never catch that; running it can.
shard_errors=0
# ⛔ NO SECOND FAILURE LIST. This branch carried `shard_failed=()` feeding its own recap; main's
# #2643 recap names from `shard_failed_list` AND accounts for sweep-only runs, so a second array
# would be written and never read. The rc this branch adds reaches the log at the failure line.
shard_ran=0
shard_skipped=0
shard_listed=0
shard_time=0
shard_slowest_secs=0
shard_slowest=""
# ── ATTRIBUTION (#2643) ───────────────────────────────────────────────────────────────────────────
# `shard_failed_list` is the NAMES of the listed shards that raised `shard_errors`, joined by `, `.
# it this runner's whole verdict was a COUNT: four shards were red on main on 2026-10-24 and four PR
# slices each printed `❌ 1 bash shard(s) failed`, so the only way to learn WHICH suite was red was to
# download an 18,695-line job log and bisect it against the runner's own `▸ <secs> <path>` rows. The
# merge rail needs a failure IDENTITY, and a count is not one.
#
# ⛔ DERIVED FROM THE COUNTER, NEVER A SECOND `||` CLAUSE. `shard_err0` is sampled before the shard
# runs and the name fires on the DELTA (`shard_errors -ne shard_err0`), so any future way of counting
# a failure still names the shard. `tests/ci-lane-parity/run.sh` arm 8am proves it by deleting this
# branch's naming call (`… && shard_fail "$1"; `) and requiring the name to vanish from the verdict,
# and arm 8h proves the failure-recording arm is load-bearing by deleting the literal
# ` || shard_errors=$((shard_errors + 1))`.
#
# It records only LISTED shards (`shard_is_listed`) — the same rule `shard_note` uses — so the
# self-check sentinels below, which deliberately fail, cannot print a bogus name.

# THE LIST, derived ONCE. The count, the target-containment check, the execution loop and the
# slice-coverage comparison below all read this variable, so the four cannot disagree about what
# the list is. Needed BEFORE the run: it bounds the slice arithmetic and marks where the sentinels
# begin.
shard_paths="$(shard_list)" || {
  echo "❌ the shard list could not be derived — refusing to run a partial list (see the error above)"
  exit 2
}
listed=0
[ -z "$shard_paths" ] || listed="$(awk 'NF { n++ } END { print n + 0 }' <<<"$shard_paths")"
if [ "$listed" -lt 1 ]; then
  echo "❌ the derived shard list is EMPTY — refusing to report success over a run that executes no suite"
  exit 2
fi

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
# ⛔ THREE READERS, AND THE RAIL NOW KNOWS ALL THREE (#2700). `run_shard` emits
# `::error::bash shard failed: <path>`, a GitHub annotation, and `scripts/ci_exemption.py ids`
# recognises it as a guard-step identity that CARRIES the shard path — measured on a log with two of
# them: `guard-step::bash-suites-2::bash-shard-failed-tests-atomic-land-run.sh`, `ids=2`. Since
# #2648/#2700 the parser ALSO reads the two prose lines below as `bash-shard::<path>` family
# identities: the per-shard `❌ FAILED SHARD: <path>` and the recap `❌ failing shard(s): <paths>`. The
# earlier revision of this paragraph said "measured against the prose lines printed here, the same
# parser returns `ids=0` — they neither help nor hurt it"; that was true before #2648 and is false
# now, and a stale claim about the parser is exactly what a future lane reads before deciding whether
# to touch the rail. **Do not "fix" the rail here, and never delete the annotation while keeping
# these lines** — the annotation is the only one of the three that survives being taken out of the
# step's own prose, and it is what keeps every lane attributable.
#
# Two prints, on purpose — and the REASON is the early exits: the recap below is reached only at the
# END of a run, while this file has several `exit 1` paths ABOVE it (`shard target resolves outside
# this checkout`, `slice executed a DIFFERENT SET of shards`, and the two sentinels). On any of those
# the per-failure line is the only name the log will ever carry.
# LISTED shards only: the runtime sentinel at the end of this file deliberately runs a failing stub,
# and a green run must never print a FAILED SHARD line for it (`shard_is_listed` is 0 there).
# ⛔ ONE NAME, ONE CHAIN (#2643 + #2648). `shard_fail` is the name the execution line calls, and it
# delegates to `shard_record_failure`, which gates on the path being a LISTED shard and prints through
# `shard_named_failure`. The chain exists so that EITHER mutation arm kills the name: arm 8am deletes
# the call and gutting `shard_record_failure()` also removes it — while the ACCUMULATOR
# (`shard_failed_list`) is the one main's recap reads. Two independent recorders would each have to be
# gutted for the name to disappear, which is exactly the vacuous arm the tests refuse.
shard_failed_list=""
shard_fail() { shard_record_failure "$1"; }

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

# shard_record_failure <path> — the ATTRIBUTION half of the failure arm: remember the shard's name and
# say it at the point of failure, in the context of the suite's own output, so a reader (and the log
# parses the rail does on a 40-minute job) never has to bisect a slice by its timing rows.
#
# A helper, not an inline printf, for the same reason `shard_note` is: it keeps the execution line one
# statement-chain. It is deliberately `: `-able — gutting the body leaves the failure COUNTED and the
# run red, only nameless — which is exactly the mutation `tests/ci-lane-parity/run.sh` arm 8am needs in
# order to prove the name is not being printed by something else. That mutation replaces THIS ONE
# LINE, so the body must stay on it (a multi-line body would be left dangling at top level and the
# fixture would fail for a reason it did not choose).
#
# ⛔ TWO RECORDERS, TWO GATES (#2643 review cycle 3). `shard_record_failure` gates on the path being a
# LISTED shard, so the self-check sentinels (a mktemp `exit 1` file) cannot print a bogus name. The
# syntax sweep has no such gate and must not need one: its path is real, and it is a failure the rail
# has to be able to attribute. Naming only the shard LOOP left a MIXED run — one listed shard plus a
# `bash -n` failure — yielding exactly ONE identity, so the rail's step-1c `examined > extracted`
# check passed and the un-named file vanished from a certificate that then named no residual. A red
# file the rail cannot name is the class this whole file exists to refuse.
shard_named_failure() { shard_failed_list="${shard_failed_list}${shard_failed_list:+, }$1"; printf '❌ FAILED SHARD: %s\n' "$1"; }
shard_record_failure() { [ "$shard_is_listed" = 1 ] || return 0; shard_named_failure "$1"; }

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
run_shard() { slice_skips "$1" && return 0; shard_ran=$((shard_ran + 1)); printf '%s\n' "$1" >> "$shard_ran_log"; shard_t0=$SECONDS; shard_err0=$shard_errors; bash "$1" || { shard_rc=$?; shard_errors=$((shard_errors + 1)); [ "$shard_is_listed" = 1 ] && printf '❌ SHARD FAILED (rc %s): %s\n' "$shard_rc" "$1"; [ "${1#/}" != "$1" ] || echo "::error::bash shard failed: $1"; }; [ "$shard_errors" -ne "$shard_err0" ] && shard_fail "$1"; [ "$shard_is_listed" = 1 ] && shard_note "$1" $((SECONDS - shard_t0)); return 0; }

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
# ⛔ …AND THE SWEEP NAMES TOO (#2648): the same DELTA that charges `sweep_errors` also names the file,
# so a mixed run has no un-named red. It stays gated on `sweep_name` (the sentinel is a mktemp path,
# not a shard) and the bare `|| shard_errors=$((shard_errors + 1))` literal stays intact for §8h.
sweep_errors=0
sweep_file() { swept=$((swept + 1)); shard_err0=$shard_errors; bash -n "$1" || shard_errors=$((shard_errors + 1)); [ "$shard_errors" -ne "$shard_err0" ] && { sweep_errors=$((sweep_errors + 1)); [ "${sweep_name:-1}" = 1 ] && shard_named_failure "$1"; }; }

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
done <<<"$shard_paths"

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
# ── the run — ONE loop over the DERIVED list ──────────────────────────────────────────────────
# There is no per-suite line here any more, on purpose: a suite is wired by the FILE it lives in
# matching SUITE_GLOBS, so two harness PRs adding two suites no longer conflict in this file.
# The order is the list's (LC_ALL=C sort -u) — see DERIVATION: every suite is hermetic, so no
# suite depends on running before or after another.
while IFS= read -r shard; do
  [ -n "$shard" ] || continue
  run_shard "$shard"
done <<<"$shard_paths"
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
  printf '%s\n' "$shard_paths" \
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
before_failed_shards="$shard_failed_list"
before_sweep_errors=$sweep_errors
sweep_name=0          # the sentinel is a mktemp path, not a shard — it must not print a name
sweep_file "$sentinel_sweep"
sweep_name=1
rm -f "$sentinel_sweep"
if [ "$shard_errors" -ne $((before_sweep_err + 1)) ]; then
  echo "❌ the sweep arm is broken — a file with a syntax error would not fail this run"
  exit 1
fi
# Both counters are restored to their PRE-sentinel values (not decremented): a decrement silently
# assumes the sentinel incremented, and this file's whole discipline is that an assumption about a
# counter is what a refactor invalidates.
shard_errors=$before_sweep_err
shard_failed_list=$before_failed_shards
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
  # ⛔ THE VERDICT NAMES WHAT IT COUNTED (#2643). A red slice's log ends here, and the merge rail reads
  # its failure identity from the `❌ FAILED SHARD: <path>` line printed at the point of failure
  # (`scripts/ci_exemption.py`'s bash-shard pass); `❌ 1 bash shard(s) failed` alone is a red with no
  # owner. Three shapes, each REPORTED from what was counted — never inferred from what is absent: a
  # failing shard is named; a failing syntax sweep named its own file at the `bash -n` line; and a
  # failure with NEITHER means the naming arm is broken, which is a defect in THIS runner and must say
  # `could NOT be named` rather than blame a subsystem it never looked at.
  if [ -n "$shard_failed_list" ]; then
    echo "❌ failing shard(s): $shard_failed_list"
    # ⛔ A PARTIAL RECAP IS A FALSE PASS (review cycle 2, P2). The list can name SOME of the counted
    # failures, and "2 failed" beside one name reads as a COMPLETE recap to the rail, which then
    # compares a 1-identity certificate and admits the un-named half — the incomplete-set direction
    # this runner exists to close. Completeness is compared from what was COUNTED (`shard_errors`)
    # against what was NAMED, never inferred from the list being non-empty.
    recap_named=$(printf '%s' "$shard_failed_list" | awk -F', ' '{print NF}')
    if [ "$recap_named" -lt "$shard_errors" ]; then
      echo "❌ …and $((shard_errors - recap_named)) of the counted failure(s) could NOT be named — the naming arm did not run for them. This is a defect in scripts/run-bash-shards.sh, not in the failing file."
    fi
    # ⚠️ A MIXED RUN MUST ACCOUNT FOR ITS COUNT. `shard_errors` counts BOTH failing shards and failing
    # syntax sweeps; the list above names them together. Printing "2 failed" beside one name reads as a
    # missing name — and the missing half is exactly what the recap exists to stop hunting for.
    if [ "$sweep_errors" -gt 0 ]; then
      if [ "$sweep_errors" -eq "$shard_errors" ]; then
        echo "❌ every failure above is a SYNTAX-SWEEP failure, named at its own 'bash -n' line"
      else
        echo "❌ …and $sweep_errors of them are SYNTAX-SWEEP failures, not shards — each named at its own 'bash -n' line"
      fi
    fi
  elif [ "$sweep_errors" -eq "$shard_errors" ] && [ "$sweep_errors" -gt 0 ]; then
    # The sweep counted the failure but its name never reached the list: the naming arm is broken.
    echo "❌ every failure above is a syntax-sweep failure, and its file could NOT be named at its own 'bash -n' line — the naming arm is not wired for it. This is a defect in scripts/run-bash-shards.sh, not in the swept file."
  else
    # Mixed AND unnamed: a broken naming arm alongside a failing sweep. Do NOT claim the sweep caused
    # everything — measure it. (Final review: this branch used to say "every failure above is a
    # syntax-sweep failure", which sent triage to fix the sweep and lose the unnamed shard with it.)
    echo "❌ $((shard_errors - sweep_errors)) of these failure(s) could NOT be named — a counting path with no path of its own raised them (this is the backstop: the shard loop AND the syntax sweep both name themselves, so a defect in scripts/run-bash-shards.sh is the likely cause)"
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


# ── the per-suite notes that used to ride on each `run_shard` line are NOT reproduced here ────────
# Each of those 79 lines carried a one-sentence note (what the suite pins, which incident added it).
# A long comment block of them is NOT inert text: the fleet's `main-worktree-guard` reads
# command-position paths in a script's own source, so a block of ~79 path-shaped comment lines made
# it exhaust its seed budget and REFUSE to run this script at all (measured 2026-10-23; recorded on
# agent-infra#2189). The notes are in git history on the commit that derived this list
# (`git log -p --follow` on this file) and each suite's own header states what it pins — a suite's
# MEMBERSHIP needs neither.
