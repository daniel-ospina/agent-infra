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
#   - An INTERRUPTED run (TERM/INT) still prints that recap from what it accumulated, prefixed
#     `⚠️ RECAP INCOMPLETE (k/n shards ran)`, and exits 1: a truncated run is UNPROVEN, never
#     green, and never a baseline (agent-infra#3174 — see shard_partial_recap).
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
#   SHARD_BOUND=<seconds> bash scripts/run-bash-shards.sh       # that per-shard bound (see below)
#   BASH_SHARDS_BUDGET_SECS=<secs> bash scripts/run-bash-shards.sh  # name an overrun of the bound
#
# ENVIRONMENT CONTRACT (complete — a caller that sets anything else changes nothing here):
#   BASH_SHARD_SLICE      <i>/<n> — run only slice i of n. Slicing is a MATRIX concern (below).
#   SHARD_BOUND           whole seconds; the PER-SHARD bound (#3187). Unset or EMPTY takes the
#                         default 1800 s; `0`/'off' DISABLES it; any other non-integer — or one wide
#                         enough to wrap negative — is REFUSED (rc 2) rather than silently running
#                         unbounded. A shard that crosses it is killed by PROCESS GROUP, named
#                         `TIMEOUT after <n>s` in the recap, and the list CONTINUES (see below).
#   BASH_SHARDS_BUDGET_SECS  whole seconds; the runner's OWN deadline for the shard WORK it measures
#                         (`shard_time`, the sum of the per-suite `▸` rows — NOT step wall clock).
#                         Unset = no deadline; `0` = no deadline; set-but-EMPTY is REFUSED (rc 2),
#                         since an unset CI variable expands to empty and silently running with no
#                         deadline is the fail-open; non-numeric refused (rc 2). A POSITIVE value may
#                         NOT be combined with BASH_SHARD_SLICE (rc 2) — the two do not compose.
#                         On crossing it the runner prints a NAMED overrun verdict and EXITS 1, so an
#                         overrun can never be read as a suite failure (see shard_budget_trip).
#
# ⛔ THE TWO BOUNDS ARE DIFFERENT DEFECTS, and they do not overlap. SHARD_BOUND bounds ONE shard, so
# a HANG costs one shard instead of the rest of the list; BASH_SHARDS_BUDGET_SECS bounds the LIST,
# so an overrun of the whole list is NAMED as capacity rather than arriving as an opaque platform
# kill. They compose: a hung shard trips the first (bounded, named, list continues), a list whose
# shards are each within bound but whose SUM is not trips the second.
#
# THE PER-SHARD BOUND — why a hung shard must cost ONE shard (#3187)
# ------------------------------------------------------------------
#   Measured on main's `script-validate` (PR #3153 run, job 124687782089): shard #103 of 148,
#   `scripts/orchestrator-harness/selftest.sh`, STOPPED inside a child with 0.00 s CPU and sat
#   there for 82 minutes. The only bounds were the STEP's (110 min) and the JOB's, so the hang
#   consumed the whole list's budget and shards #104–#148 never ran at all. That is why the
#   reported failing set kept SHRINKING (13 → 11 → 10) while nothing was fixed: fewer shards
#   executed before the kill, not more bugs repaired. #3174 makes such a truncation VISIBLE
#   (a partial recap refuses to be used as a baseline); this bound makes it NOT HAPPEN.
#
#   `SHARD_BOUND`, default 1800 s — 1.65× the slowest shard measured (1092 s), so a legitimately
#   slow suite cannot false-trip. A shard that exceeds it is KILLED BY PROCESS GROUP (its own
#   children included — a wrapper-only kill leaves the hang's children running), NAMED with a
#   `TIMEOUT after <n>s` marker through the SAME `shard_failed_list` every other failure uses,
#   and the loop CONTINUES to the next shard. A hang therefore costs one shard, not forty-five.
#   `SHARD_BOUND=0` (or `off`) disables it for a lane that legitimately wants no bound; any other
#   non-integer refuses the run rather than silently degrading to unbounded.
#
#   PORTABILITY: `timeout` does not exist on macOS and the repo runs bash 3.2 as well as 5. The
#   bound is therefore built from `set -m` (job control ⇒ each background job LEADS its own process
#   group) plus ONE `sleep`-based watchdog — no external dependency, no poll loop (a 1 s poll costs
#   ~1.16 s of dead time per shard, measured; the watchdog costs two forks). `kill -<signal> -<pgid>`
#   reaches the whole group; TERM is followed by KILL so a shard that traps/ignores TERM cannot
#   outlive it.
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
# ── CALLS ALLOWED PAST THE END OF THE LIST (#2838) ──────────────────────────────────────────────
# `slice_skips` counts EVERY call, so `executed + skipped == listed` only holds when the calls made
# are the calls the list describes. `run_shard` has TWO call sites: the derived loop ($listed calls,
# 0 … listed-1) and the runtime sentinel (position `listed`, which must always execute so a slice
# cannot leave the failure-recording arm untested). `shard_past_list=1` marks that ONE call BY NAME;
# `slice_skips` refuses any other call past the end.
shard_past_list=0
slice_calls=0
past_list_calls=0
past_list_budget=1
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
# ── THE WALL BUDGET, AND WHY IT IS A NAMED VERDICT (agent-infra#3174) ──────────────────────────
# The step's `timeout-minutes` is the PLATFORM's kill: it is `failure`, and its log says only
# "exceeded the maximum execution time of N minutes". A shard that FAILED also produces `failure`.
# So before this, the two reds this step can produce — a suite failed, or the DERIVED LIST outran
# the bound — were one red with no distinguishing line. Measured 2026-10-31 (main, run
# 41240886978 — an `integration/batch-20261031-10` pre-merge gate, whose list is 147 = main's
# today): 147 listed suites summing 6468 s of shard work against a 6600 s (110 min) step
# bound — a 132 s margin, 98 % of the bound — so the overrun arm was one suite away.
#
# `BASH_SHARDS_BUDGET_SECS` (set by the CALLING STEP, never guessed here) is the runner's OWN
# deadline, deliberately BELOW that step bound, so the runner reaches this verdict and prints
# WHICH defect it is before the platform kills the step opaquely:
#   ❌ SHARD BUDGET EXCEEDED …  → capacity: the list outran the bound (NOT a suite failure)
#   ❌ failing shard(s): …      → a real suite failure, named, with its `::error::` annotation
# Both still exit 1. ⛔ The budget verdict deliberately emits NO `::error::` annotation: an
# annotation becomes a guard-step identity the merge rail can COMPARE against main and EXEMPT
# (scripts/ci_exemption.py, `guard_step_failures`), and a systemic overrun exists on main too — so
# annotating it would turn "the bound is under-derived" into a PR-exempt failure. Prose keeps it
# unattributable, and unattributable is fail-CLOSED, the correct direction here.
# 0 / unset = no budget (the behaviour every pre-existing caller keeps).
shard_budget=0
# ⛔ `set` AND empty is REFUSED (review cycle 2, #3174): an unset CI variable expands to the empty
# string, and treating that as "0 = no deadline" would be a fail-open dressed as the documented
# default — the step would run with no deadline while its comment claims a non-numeric value is
# refused. `+set` distinguishes "absent" from "present and empty"; only ABSENT means no deadline.
case "${BASH_SHARDS_BUDGET_SECS+set}" in
  "") : ;;
  *)  [ -n "${BASH_SHARDS_BUDGET_SECS}" ] || {
        echo "❌ BASH_SHARDS_BUDGET_SECS is SET but EMPTY — that is a missing value, not 'no deadline'. Unset it, or give it whole seconds (0 = no deadline).";
        exit 2; } ;;
esac
if [ -n "${BASH_SHARDS_BUDGET_SECS:-}" ]; then
  case "$BASH_SHARDS_BUDGET_SECS" in
    *[!0-9]*) echo "❌ BASH_SHARDS_BUDGET_SECS='$BASH_SHARDS_BUDGET_SECS' is not a whole number of seconds"; exit 2 ;;
  esac
  shard_budget=$((10#$BASH_SHARDS_BUDGET_SECS))
  # ⛔ A BUDGET AND A SLICE DO NOT COMPOSE (review finding, #3174). `shard_time` accumulates only the
  # shards THIS process ran, so a sliced caller would compare a ~1/N share against a WHOLE-LIST
  # budget — a deadline ~N times too lenient, with no error, i.e. fail-open for any future caller that
  # sets both. Refuse the pair rather than silently weakening the deadline; a slice's share would have
  # to be derived from a measured whole-list figure, and no caller needs that today.
  # ⛔ …BUT `0` IS NOT A BUDGET (review finding, #3174). `0` is the documented "no deadline" spelling,
  # so there is no share to compare and nothing to weaken — refusing it refused a documented no-op
  # spelling, i.e. a false block (category B). Only a POSITIVE budget composes badly with a slice.
  if [ "$shard_budget" -gt 0 ] && [ -n "${BASH_SHARD_SLICE:-}" ]; then
    echo "❌ BASH_SHARDS_BUDGET_SECS=$shard_budget cannot be combined with BASH_SHARD_SLICE — this process only accumulates the shards its own slice ran, so a whole-list budget would be ~N times too lenient. Set one or the other."
    exit 2
  fi
fi
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
# ── THE PER-SHARD BOUND (#3187) — parsed and VALIDATED before any work ────────────────────────
# `shard_bound` is the number of seconds, or 0 for "no bound"; `shard_bound_desc` is what the
# header and the recap REPORT, so a truncated run says which bound it hit rather than leaving the
# reader to guess whether the step, the job, or this script killed it.
shard_bound_raw="${SHARD_BOUND:-1800}"
shard_bound=0
case "$shard_bound_raw" in
  off|OFF|Off|disabled|DISABLED|none|NONE) shard_bound=0 ;;
  *[!0-9]*)
    echo "❌ SHARD_BOUND='$shard_bound_raw' is not a bound — want a whole number of seconds, or 0/off to disable. Refusing rather than running UNBOUNDED (a typo must not silently remove the bound that #3187 added)." >&2
    exit 2 ;;
  ??????????*)
    # ⛔ WIDTH IS CHECKED BEFORE THE ARITHMETIC, because `$((10#$x))` WRAPS: a 19-digit value becomes
    # NEGATIVE (which the `-lt 1` test below would read as "disabled" — the exact fail-open this
    # block exists to refuse) or a huge positive `sleep` rejects outright (rc 1, so the watchdog fires
    # instantly and kills EVERY shard at t≈0). Ten digits is ~317 years, far past any real bound, and
    # it is the same 9-digit-scale guard the repo's reapers apply to a numeric seam (`docs/ops/disk-reaper.md`).
    echo "❌ SHARD_BOUND='$shard_bound_raw' is TOO LARGE — at most 9 digits (a longer value wraps in shell arithmetic, and a wrapped bound is either NEGATIVE or rejected by sleep). Refusing." >&2
    exit 2 ;;
  *) shard_bound=$((10#$shard_bound_raw)) ;;
esac
if [ "$shard_bound" -lt 1 ]; then
  shard_bound=0
  shard_bound_desc="DISABLED (SHARD_BOUND=$shard_bound_raw) — a hung shard will consume the whole step"
else
  shard_bound_desc="${shard_bound}s per shard (SHARD_BOUND; 0 or 'off' disables)"
fi

shard_ran_log="$(mktemp 2>/dev/null || echo "/tmp/bash-shards-ran.$$")"
# ⛔ THE SKIPPED PATHS ARE RECORDED TOO, WITH THEIR REASON (agent-infra#3079). `shard_skipped` was a
# bare counter, so a slice could SAY it had skipped 31 shards and name none of them — and the
# `ran + skipped == listed` check had no way to tell "this slice skipped 31 by design" from "31
# shards vanished and the counter drifted to the same number". One line per skip, `<path>\t<reason>`.
shard_skip_log="${shard_ran_log}.skipped"
# The bound's mark (#3187): the watchdog WRITES here when it decides the shard overran, so the
# parent can tell "the bound killed it" from "the shard died on its own at about the bound" without
# comparing clock readings. Emptied before every shard; one file, never one per shard.
shard_timeout_marker="${shard_ran_log}.timeout"
: > "$shard_ran_log" 2>/dev/null || true
: > "$shard_skip_log" 2>/dev/null || true
: > "$shard_timeout_marker" 2>/dev/null || true
trap 'rm -f "$shard_ran_log" "$shard_skip_log" "$shard_timeout_marker"' EXIT

# ── A SHARD MUST DIE WITH ITS DRIVER (#3187 review, P2) ────────────────────────────────────────────
# `set -m` (see `shard_run_bounded`) gives the RUNNING shard its own process group, so a GROUP kill of
# this driver — a cancelled CI step, a harness group kill, Ctrl-C — no longer reaches it. Before this
# change the shard inherited the driver's process group and died with it, so this is a regression the
# bound itself introduces and must close: without these traps a cancelled step leaves a shard writing
# into a workspace the runner already considers finished, for up to `SHARD_BOUND` (UNBOUNDED when the
# bound is disabled). The live shard's group and the live watchdog take the TERM; then the driver
# exits as the signal says, and its EXIT trap still runs.
shard_bg_pid=""
shard_wd_pid=""
shard_driver_signal() {
  [ -n "${shard_bg_pid:-}" ] && { kill -TERM -"$shard_bg_pid" 2>/dev/null || kill -TERM "$shard_bg_pid" 2>/dev/null; }
  [ -n "${shard_wd_pid:-}" ] && { kill -TERM -"$shard_wd_pid" 2>/dev/null || kill -TERM "$shard_wd_pid" 2>/dev/null; }
  exit "$1"
}
trap 'shard_driver_signal 129' HUP
trap 'shard_driver_signal 130' INT
trap 'shard_driver_signal 143' TERM

# shard_unaccounted — the listed shards this run neither EXECUTED nor SKIPPED, one path per line.
# ⛔ DERIVED FROM THE LIST, never from the counters (agent-infra#3079). `executed + skipped == listed`
# on its own can be satisfied while a specific shard is missing — the counters are what the loop
# writes, and a loop that never reached a shard writes neither. This compares the derived list
# against the two logs, so the answer is `which shards`, not `how many`.
shard_unaccounted() {
  local all="${shard_ran_log}.all" acct="${shard_ran_log}.acct"
  printf '%s\n' "$shard_paths" | awk 'NF' | LC_ALL=C sort -u > "$all" 2>/dev/null || return 0
  { cat "$shard_ran_log"; cut -f1 "$shard_skip_log"; } 2>/dev/null | awk 'NF' | LC_ALL=C sort -u > "$acct"
  comm -23 "$all" "$acct" 2>/dev/null
  rm -f "$all" "$acct"
  return 0
}
# shard_count_lines <text> — the non-empty line count of a string (a COUNT that cannot be satisfied
# by an empty string is the point: `wc -l` on a value without a trailing newline reports 0).
shard_count_lines() { awk 'NF { n++ } END { print n + 0 }' <<<"$1"; }

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

# ── THE HUNG SHARD (#3187): bounded, NAMED, and the run CONTINUES ────────────────────────────────
# `shard_timeout_list` is the names of the shards this run KILLED at the per-shard bound. It is a
# SEPARATE accumulator on purpose: `shard_failed_list` feeds the recap line
# `❌ failing shard(s): <a>, <b>`, which `scripts/ci_exemption.py` splits on `, ` into
# `bash-shard::<path>` identities (`_BASH_SHARD_RECAP_RE`) — so a marker appended to a name THERE
# would manufacture a phantom identity that matches nothing on main and false-BLOCKs every lane. The
# casualty is therefore named through the SAME `shard_fail` chain as any other failure (one name,
# one chain — unchanged) and this list carries the `TIMEOUT after <n>s` marker as its own recap line.
shard_timeout_list=""

# shard_timed_out <path> <seconds> — the distinguishable mark a bound hit leaves. Printed at the
# point of failure (so a truncated log still explains itself) and replayed in the recap by name.
# Gated on `shard_is_listed` by its caller, exactly like `shard_record_failure`: the runtime sentinel
# deliberately fails a mktemp stub and must never be reported as a timed-out SHARD.
shard_timed_out() { shard_timeout_list="${shard_timeout_list}${shard_timeout_list:+, }$1"; printf '⏱ SHARD TIMEOUT after %ss: %s\n' "$2" "$1"; }

# shard_watchdog — the BOUND itself, run as one background job beside the shard. Reads (never
# writes) the driver's globals: `shard_bg_pid` is the shard's pid, which — under `set -m` — is also
# its process GROUP id. A single `sleep`, not a poll loop (see `shard_run_bounded`).
#
# ⛔ THE TIMER IS A CHILD SO TERM CAN TAKE IT WITH US (#3187 review, and measured the hard way). A
# bare `sleep` in the watchdog's own body is a process the watchdog cannot kill on its way out: if
# only the watchdog's pid is signalled (the fallback path, or any caller that misses the group), the
# `sleep` is orphaned. An orphaned timer is not harmless — it INHERITS STDOUT, so when the driver runs
# inside a `$( … )`/pipeline (which tests/ci-lane-parity does, and so do real callers) the leaked
# `sleep 1800` keeps the pipe open after the driver exits and the caller blocks until the bound —
# measured: a 10-minute `sleep 1800` holding the parity suite's pipe, with the driver long gone.
# Holding the timer as `$shard_timer_pid` and killing it in the TERM trap makes the watchdog exit
# clean no matter which of its processes the signal reaches.
shard_watchdog() {
  # ⛔ JOB CONTROL OFF INSIDE THE TIMER (#3187 review, measured 4/15 in isolation). `set -m` is a
  # shell OPTION, so this subshell inherits it — and with job control on, `sleep … &` gets its OWN
  # process group, which the parent's `kill -TERM -<watchdog pgid>` DOES NOT REACH. The timer then
  # survives every teardown that signals the watchdog's group, and only the trap below could kill it —
  # with a real race, because the trap can fire in the window between the fork and
  # `shard_timer_pid=$!` (observed: 4 of 15 iterations orphaned a fresh `sleep 777`). With `set +m`
  # the timer stays in THIS subshell's group, so the parent's group TERM always reaches it; the trap
  # is then a second, non-load-bearing path. It records nothing, so disabling job control here cannot
  # disturb the driver.
  set +m
  trap 'kill "${shard_timer_pid:-}" 2>/dev/null; kill -TERM -- -"${BASHPID:-$$}" 2>/dev/null; exit 0' TERM INT
  sleep "$shard_bound" &
  shard_timer_pid=$!
  wait "$shard_timer_pid" 2>/dev/null || exit 0
  # Gone already ⇒ this is NOT a timeout: say nothing and leave no mark. ⛔ `kill -0` alone is NOT
  # enough: it SUCCEEDS for a zombie (a child that exited but has not been reaped yet), so a shard
  # that finished at the last instant could be reported as killed. `ps -o stat=` reads `Z` for that
  # state on macOS and Linux alike, and it costs one fork only on the timeout path (review finding,
  # P2 — the window is sub-millisecond, which is exactly why rc alone is the wrong discriminator:
  # consulting rc would turn a TERM-trapping shard's clean exit into a false PASS).
  kill -0 "$shard_bg_pid" 2>/dev/null || exit 0
  case "$(ps -o stat= -p "$shard_bg_pid" 2>/dev/null)" in
    Z*|'') exit 0 ;;
  esac
  printf 'x' >"$shard_timeout_marker" 2>/dev/null
  # The GROUP (`-$pid`), never the bare pid: a wrapper-only kill is the orphan factory this exists
  # to close (#103's hang was inside a CHILD). The bare-pid form is the fallback for a shell whose
  # job control did not give the shard its own group — reaching less beats a shard outliving every
  # bound. TERM, then KILL after a second, so a suite that traps TERM cannot outlive the bound.
  kill -TERM -"$shard_bg_pid" 2>/dev/null || kill -TERM "$shard_bg_pid" 2>/dev/null
  sleep 1
  kill -KILL -"$shard_bg_pid" 2>/dev/null || kill -KILL "$shard_bg_pid" 2>/dev/null
}

# shard_run_bounded <path> — run ONE shard under `SHARD_BOUND`, portable and bash-3.2 clean.
#
# ⛔ WHY NOT `timeout`: it is GNU and absent on macOS (`gtimeout` needs coreutils, and is absent too
# on a bare runner). ⛔ WHY A PROCESS GROUP: `set -m` makes bash place each background job in its
# OWN process group, whose PGID is the job's pid, so `kill -TERM -<pid>` reaches the wrapper AND its
# descendants (see `shard_watchdog`).
#
# ⛔ A WATCHDOG, NOT A POLL LOOP. `while kill -0; do sleep 1; done` costs up to a second of dead time
# per shard — measured on a 5-instant-shard fixture: 6.75 s bounded vs 0.94 s unbounded, i.e. ~1.16 s
# per shard, ~2.9 min added to a 148-shard job whose DURATION is the reason slicing exists. Here the
# parent blocks in `wait` and one `sleep <bound>` does the counting: two forks per shard, no
# wall-clock. The watchdog gets its own process group too, and the parent kills that GROUP off after
# a NORMAL completion — otherwise every fast shard would leave a `sleep 1800` behind.
#
# ⛔ WHY NOT `scripts/lib/bounded.sh` (`tb_timeout`) — the repo's other portable bound? Because the
# two properties #3187 depends on are both absent there, and importing it would make the regression
# invisible: (1) its INTERNAL watchdog (the macOS path, i.e. every laptop and every macOS runner)
# kills the child PID only, so a suite that hung inside a CHILD — precisely what shard #103 did, with
# 0.00 s CPU — leaves that child alive; (2) it is GNU-`timeout`-FIRST when a binary exists, and GNU
# `timeout` signals the child's process GROUP, so the same bound would reach different processes on
# Linux and on macOS: one runner, two contracts. Its contract also forbids setting shell options,
# which `set -m` is. Folding group semantics into a helper the whole reaper family depends on is its
# own change (filed as a follow-up); until then this file owns its bound, stated rather than hidden.
#
# Returns the shard's own rc when it finishes in time; 124 (the `timeout` convention) when the bound
# was hit, decided from the MARKER the watchdog writes (never from a clock comparison, and never from
# rc 124, which a suite is free to exit with itself). `shard_bound` 0 short-circuits to the plain
# invocation, so disabling the bound is not a second code path — it is the ABSENCE of the watchdog,
# which is what `SHARD_BOUND=0` promises.
shard_run_bounded() {
  if [ "$shard_bound" -lt 1 ]; then bash "$1" </dev/null; return $?; fi
  : >"$shard_timeout_marker" 2>/dev/null || true
  set -m                                  # job control ⇒ each background job LEADS its own group
  bash "$1" </dev/null &
  shard_bg_pid=$!
  # ⛔ THE WATCHDOG'S OUTPUT GOES TO /dev/null, and that is load-bearing rather than tidy: the timer
  # must never be able to hold the driver's stdout open. A caller that runs this driver inside
  # `$( … )` or a pipeline waits for EOF on that pipe, so ANY surviving watchdog process would block
  # it until the bound — measured: a leaked `sleep 1800` kept `tests/ci-lane-parity`'s substitution
  # open with the driver long gone (see `shard_watchdog`). The watchdog has nothing to say (it only
  # writes the marker FILE), so nothing is lost.
  shard_watchdog >/dev/null 2>&1 &
  shard_wd_pid=$!
  set +m                                  # …and the driver is not left in job-control mode
  # `wait` is what yields the rc AND reaps the child; whether the wait was CUT SHORT is the
  # watchdog's verdict, and it travels in the marker file, not in a return code.
  wait "$shard_bg_pid"
  shard_bg_rc=$?
  # ⛔ KEEP THE GROUP ID (#3187 review): the shard is reaped here, so `$shard_bg_pid` must not be
  # reused after it is cleared — the timeout branch below still has to signal the shard's PROCESS
  # GROUP when a child outlived the wrapper.
  shard_bg_group="$shard_bg_pid"
  # Tear the watchdog down by GROUP, so its `sleep <bound>` cannot outlive a shard that finished.
  kill -TERM -"$shard_wd_pid" 2>/dev/null || kill -TERM "$shard_wd_pid" 2>/dev/null
  wait "$shard_wd_pid" 2>/dev/null
  # ⛔ AND A SECOND PASS ON THE GROUP, AFTER THE REAP (measured: 3 of 30 runs leaked a timer without
  # it). The watchdog forks its timer as its first act, so a TERM that lands DURING that fork is
  # delivered to the group just before the new child joins it — the child then never receives the
  # signal, while its parent (which did) dies and leaves it orphaned. `kill -TERM -$pgid` returned 0
  # in every one of those runs, so a status check cannot see this: only a pass that happens AFTER the
  # fork can. The group stays addressable by the watchdog's pgid while ANY member lives, so this
  # KILL collects the straggler deterministically and costs one syscall in the normal case.
  kill -KILL -"$shard_wd_pid" 2>/dev/null
  shard_bg_pid=""
  shard_wd_pid=""
  if [ -s "$shard_timeout_marker" ]; then
    # ⛔ THE ESCALATION IS THE PARENT'S JOB TOO (review finding, P1). The group TERM above kills a
    # default-disposition wrapper AT ONCE, so `wait` returns BEFORE the watchdog reaches its KILL —
    # and tearing the watchdog down (above) would cut that KILL off, leaving a child that TRAPS TERM
    # alive with no bound left to reach it. Measured by a reviewer on a fixture whose child ignored
    # TERM: the child survived the bound permanently. So the group gets the same one-second grace
    # here and is then KILLed by the parent, which makes the escalation independent of which process
    # outlived the TERM. The watchdog keeps its own KILL for the other ordering — a WRAPPER that
    # traps TERM, where `wait` has not returned yet (pinned by the suite's arm 2b; this branch is
    # pinned by arm 2c).
    sleep 1
    if [ -n "$shard_bg_group" ]; then
      kill -KILL -"$shard_bg_group" 2>/dev/null || kill -KILL "$shard_bg_group" 2>/dev/null
    fi
    [ "$shard_is_listed" = 1 ] && shard_timed_out "$1" "$shard_bound"
    return 124
  fi
  return $shard_bg_rc
}

slice_skips() {
  slice_pos=$shard_listed
  shard_listed=$((shard_listed + 1))
  slice_calls=$((slice_calls + 1))
  # Whether this call is a LIST line or one of the sentinels below (used by the timing report).
  if [ "$slice_pos" -lt "$listed" ]; then shard_is_listed=1; else shard_is_listed=0; fi
  # ⛔ A POSITION PAST THE DERIVED COUNT IS AN ERROR, NOT EXTRA WORK TO RUN (#2838). This used to
  # answer "past the list, RUN it", which hid the one thing the arithmetic at the end of this file
  # exists to catch: the #2838 enumerated block sat at positions `listed`..`listed+103`, so ~104 rows
  # ran in EVERY slice (measured: all 8 shards died at 70.3-70.4 min). A caller past the end must now
  # DECLARE itself (`shard_past_list=1`, the sentinel) and only `past_list_budget` may do so.
  if [ "$slice_pos" -ge "$listed" ]; then
    if [ "$shard_past_list" -ne 1 ]; then
      echo "❌ call #$((slice_pos + 1)) to run_shard is PAST the derived list ($listed listed shard(s)) and did not DECLARE itself — the list and the execution disagree, so 'executed + skipped == listed' cannot hold. The likely cause is a second, enumerated list of suites in this file (#2838). Refusing: extra work is not a repair for two lists that disagree. Already ran $shard_ran and skipped $shard_skipped of $listed."
      exit 1
    fi
    past_list_calls=$((past_list_calls + 1))
    if [ "$past_list_calls" -gt "$past_list_budget" ]; then
      echo "❌ $past_list_calls call(s) past the derived list ($listed listed shard(s)); the declared budget is $past_list_budget — the runtime failure-recording sentinel alone. Refusing (#2838)."
      exit 1
    fi
  fi
  [ "$slice_count" -gt 0 ] || return 1
  # A DECLARED sentinel always runs: a slice must not leave the failure arm untested.
  [ "$slice_pos" -lt "$listed" ] || return 1
  [ $((slice_pos % slice_count)) -eq "$slice_index" ] && return 1
  shard_skipped=$((shard_skipped + 1))
  printf '%s\tslice %s/%s\n' "$1" "$((slice_index + 1))" "$slice_count" >> "$shard_skip_log" 2>/dev/null || true
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

# shard_budget_trip <what-is-being-started> — the NAMED overrun verdict, checked BEFORE each shard
# so it fires while there is budget left to say why.
# ⛔ THE QUANTITY IS `shard_time`, NOT `$SECONDS`, and the distinction is the whole measurement: the
# 6468 s figure this bound was sized from is the SUM OF THE PER-SUITE ROWS (`▸ <secs> <path>`), i.e.
# shard work, not step wall (the same run's shard STEP took 6469 s; the whole JOB took 6493 s, the
# difference being checkout/setup and the three steps ahead of it). Comparing the budget against the
# same quantity it was measured on keeps the arithmetic honest — and it is why the residue between
# 6468 and 6469 is ~1 s, not the 25 s a first draft of this comment claimed.
# It also draws the line between the two defects a step bound has to survive: a single HUNG suite
# moves `$SECONDS` but barely moves `shard_time` (it has not returned yet), so a hang is still caught
# by the platform's `timeout-minutes` — opaque but red — while the LIST outgrowing its bound is what
# this verdict names. Exits 1: an overrun is RED, and the shards the run does NOT reach are NAMED
# below, so the shortfall can never be mistaken for a suite failure.
shard_budget_trip() {
  [ "$shard_budget" -gt 0 ] || return 0
  [ "$shard_time" -ge "$shard_budget" ] || return 0
  echo "❌ SHARD BUDGET EXCEEDED — the DERIVED LIST outran the step's bound, and this is NOT a suite failure: ${shard_time}s of shard work against BASH_SHARDS_BUDGET_SECS=${shard_budget}s, before starting '$1'. Ran $shard_ran of $listed listed shard(s) (slowest ${shard_slowest_secs}s${shard_slowest:+ ($shard_slowest)}). Fix it with CAPACITY — add matrix slices (ci.yml's bash-suites), split the slowest suite — never by widening this number to whatever the run happened to take."
  # ⛔ GATED ON THE COUNT, AND THE NAME IS OPTIONAL (review finding, #3174). `shard_failed_list` is
  # the NAMES and `shard_errors` is the COUNT — two different quantities, which is why the recap
  # below can report a failure that was counted and NOT named. Gating this line on the name list
  # would let a broken naming arm print "NOT a suite failure" over a run that did fail one, i.e. this
  # verdict would absorb the very failure it disclaims. The count decides; the name is reported when
  # there is one and declared MISSING when there is not.
  if [ "$shard_errors" -gt 0 ]; then
    echo "❌ …and $shard_errors shard(s) failed INDEPENDENTLY of the overrun: ${shard_failed_list:-(counted, NONE named — the naming arm did not run for them, which is a defect in this runner)}"
  fi
  # ⛔ A SHORT COUNT IS NOT A SHORT LIST (#3079 applied to THIS exit). The trip stops the run, so the
  # `executed + skipped == listed` accounting below never executes — and on the run this feature
  # targets that is precisely the information a reader needs. Name the shards that will not run
  # rather than leaving them as the difference between two numbers.
  if [ $((shard_ran + shard_skipped)) -ne "$listed" ]; then
    _left="$(shard_unaccounted)"
    echo "❌ NOT RUN — $(shard_count_lines "$_left") of $listed listed shard(s) will not be attempted because the budget was already spent:"
    while IFS= read -r _u; do [ -n "$_u" ] && printf '   ⏭  NOT RUN: %s\n' "$_u"; done <<<"$_left"
  fi
  exit 1
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
run_shard() { slice_skips "$1" && return 0; shard_ran=$((shard_ran + 1)); printf '%s\n' "$1" >> "$shard_ran_log"; shard_t0=$SECONDS; shard_err0=$shard_errors; shard_run_bounded "$1" || { shard_rc=$?; shard_errors=$((shard_errors + 1)); [ "$shard_is_listed" = 1 ] && printf '❌ SHARD FAILED (rc %s): %s\n' "$shard_rc" "$1"; [ "${1#/}" != "$1" ] || echo "::error::bash shard failed: $1"; }; [ "$shard_errors" -ne "$shard_err0" ] && shard_fail "$1"; [ "$shard_is_listed" = 1 ] && shard_note "$1" $((SECONDS - shard_t0)); return 0; }

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

# ── THE PARTIAL RECAP — an INTERRUPTED run still names what it saw, and says it is INCOMPLETE ──
# (agent-infra#3174)
#
# THE DEFECT. On 2026-10-31 main's `script-validate` job was killed mid-run (run `41217287437`:
# the shard step was terminated after 111 minutes) and a KILLED step printed NO recap at all. So the
# only thing the fleet's merge decisions read — the set of shards red on `main`, which every batch
# verdict subtracts — was produced by a job whose answer silently SHRANK as the job got slower.
# Measured across three consecutive main runs: 13 / 11 / 10 failing shards named, with nothing
# fixed in between. Under-reporting the reference set is not cosmetic: a shard genuinely red on
# `main` drops out of the baseline, then reappears as "a new failure caused by the batch" and gets a
# constituent dropped or reverted on a FALSE signal — and, read as an improvement, it also HIDES the
# failures that were real.
#
# THREE PARTS, and the second is the point:
#   1. A TERM/INT trap emits the same `❌ failing shard(s): …` recap the normal exit emits, from
#      everything accumulated so far, so an interrupted run still NAMES its failures.
#   2. The interrupted recap is VISIBLY INCOMPLETE — `⚠️ RECAP INCOMPLETE (k/n shards ran)` — because
#      a partial recap that LOOKS full is worse than no recap: it is exactly the false-PASS shape
#      this file exists to refuse. The marker is the machine-readable half (scripts/ci_exemption.py
#      detects it, and scripts/ci-failure-set.sh refuses to fold such a run into the baseline).
#   3. The exit code stays 1. An interrupted run proves nothing about the shards it never reached, so
#      it must never read GREEN — a killed step that exits 0 would certify a hole.
#
# ⛔ `shard_errors` is NOT "the whole failure set": it counts what had failed BEFORE the signal. The
# handler therefore never prints a bare "0 failed" as if it were a clean result — with nothing
# failed yet it says NOTHING IS PROVEN, out loud, because the dangerous reading of a truncated run is
# "fewer failures = an improvement".
#
# ⛔ BASH DEFERS THE TRAP while a foreground child runs, which is why the signal must reach the CHILD
# too — GitHub terminates the whole process group, so that is what happens in the incident this fixes
# and what `scripts/run-bash-shards.recap.test.sh` reproduces.
#
# ⚠️ STATED RESIDUAL — WHAT THIS HANDLER CANNOT COVER, PRECISELY (review of this change, P1). A run
# that is SIGKILLed, OOM-killed, or dies with its runner BEFORE the trap executes prints NO recap and
# NO marker — and on that capture the marker's ABSENCE does not mean "not truncated": it is
# indistinguishable from a complete run. Such a run still carries the per-shard
# `❌ FAILED SHARD: <path>` lines printed at the point of failure, so `scripts/ci_exemption.py` still
# yields ids for it with rc 0 and `scripts/ci-failure-set.sh` still folds it in — the PRE-#3174
# behaviour survives on that path, and NO rule in the consumers currently owns it. Do not read this
# trap as covering it. The repair is the consumer treating "shard identities but no recap line at
# all" as a truncated capture (fail closed); that is a behaviour change to the SHARED parser — several
# fixtures legitimately carry a per-shard line and no recap — so it is filed as its own issue (#3182)
# rather than bundled here.
shard_partial_recap() {
  shard_signal="${1:-TERM}"
  shard_done=$((shard_ran + shard_skipped))
  shard_notrun=$((listed - shard_done))
  [ "$shard_notrun" -ge 0 ] || shard_notrun=0
  printf '\n⚠️ RECAP INCOMPLETE (%s/%s shards ran) — scripts/run-bash-shards.sh was TERMINATED (%s) after %s of %s listed shard(s) (%s ran, %s skipped, %s never reached), so this is a TRUNCATED run: the lines below name what had ALREADY failed and say NOTHING about the shard(s) that had not run. A PARTIAL RECAP IS NOT A BASELINE — report UNPROVEN, never a failure set (agent-infra#3174)\n' \
    "$shard_ran" "$listed" "$shard_signal" "$shard_done" "$listed" "$shard_ran" "$shard_skipped" "$shard_notrun"
  if [ -n "$shard_failed_list" ]; then
    printf '❌ %s bash shard(s) had failed when this run was killed\n' "$shard_errors"
    printf '❌ failing shard(s): %s\n' "$shard_failed_list"
    if [ "${sweep_errors:-0}" -gt 0 ]; then
      printf '❌ …and %s of them are SYNTAX-SWEEP failures, not shards — each named at its own bash -n line\n' "$sweep_errors"
    fi
    recap_named_partial=$(printf '%s' "$shard_failed_list" | awk -F', ' '{print NF}')
    if [ "$recap_named_partial" -lt "$shard_errors" ]; then
      printf '❌ …and %s of the counted failure(s) could NOT be named — the naming arm did not run for them (a defect in scripts/run-bash-shards.sh, not in the failing file)\n' "$((shard_errors - recap_named_partial))"
    fi
  else
    printf '❌ NOTHING IS PROVEN: no shard had failed yet at %s/%s, and %s shard(s) had not run — this is NOT a green baseline, it is a run that was killed before it finished\n' \
      "$shard_done" "$listed" "$shard_notrun"
  fi
  printf '   ⚠️ RECAP INCOMPLETE — do not compute a set difference from this run: it is UNPROVEN (agent-infra#3174)\n'
  exit 1
}
trap 'shard_partial_recap TERM' TERM
trap 'shard_partial_recap INT' INT

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
# ⛔ THE BOUND IS ANNOUNCED BEFORE THE FIRST SHARD RUNS (#3187), so a run that is later truncated is
# self-describing: the reader can tell WHICH bound the run was operating under — the step's, the
# job's, or this one — and that a hung shard costs one shard instead of the rest of the list.
echo "   ⏱  per-shard bound: ${shard_bound_desc}"
# Every suite the list below runs is hermetic (temp repos / temp HOME / stubbed tools, no network).
#
# ⛔ THERE IS NO PER-SUITE ROW IN THIS SECTION, AND THAT IS THE COMMITMENT (#2838). `1d56cc10`
# (#2614) made this list a DERIVATION; an older branch's 103 enumerated `run_shard <path>` rows
# landed back on top of it in `718a0874` (#2035) and were never removed — so every suite ran TWICE,
# once from each list, and this file's own `executed + skipped == listed` self-check could never
# hold (measured when #2838 was filed: "executed 212 of 108 listed"). The rows are deleted and must
# not come back: a suite is wired by the FILE matching SUITE_GLOBS, and `tests/ci-lane-parity/run.sh`
# assertion 11 fails on any literal `run_shard <path>` row. The one-sentence notes those rows
# carried (what a suite pins, which incident added it) live in git history on this commit and in
# each suite's own header — and see the note at the end of this file for why they are likewise not
# reproduced here as prose.
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
# ⛔ #1997 OWNS, AND NOTHING HERE PINS: the supervisor's classified-read invariant — `sup_session_list` answers 0 present / 1 absent / 3 cannot-verify, every tmux target is EXACT (`=name`), a session name carrying `:`/`.` is refused rather than resolved, and `TMUX_READ_TIMEOUT` is validated > 0. Its suite (`scripts/cloud-cell-supervisor.hardening.test.sh`) was DROPPED at ba5ba770 because the implementation it pinned was never landed on this branch, so these invariants are currently UNPINNED in this tree — they must return BESIDE the implementation (#1997's land), not as a suite added ahead of it.
# ── the run — ONE loop over the DERIVED list ──────────────────────────────────────────────────
# There is no per-suite line here any more, on purpose: a suite is wired by the FILE it lives in
# matching SUITE_GLOBS, so two harness PRs adding two suites no longer conflict in this file.
# The order is the list's (LC_ALL=C sort -u) — see DERIVATION: every suite is hermetic, so no
# suite depends on running before or after another.
#
# ⛔ THE LIST IS READ INTO MEMORY BEFORE THE FIRST SHARD RUNS (agent-infra#3079). It used to be
# `while read shard; do run_shard "$shard"; done <<<"$shard_paths"`, and that loop's stdin WAS the
# list: every shard inherited it, so a shard that read stdin consumed the lines the driver had not
# reached yet and the loop simply ENDED — no error, no name. Measured on main's `script-validate`
# job (2026-10-30): `executed 107 of 139 listed shard(s) (0 skipped)`, the last timing row being
# `▸ 60s scripts/pi-reap-idle.test.sh` — that suite reads stdin (see `run_shard`'s `</dev/null`),
# drained the remaining 32 lines, and 32 shards silently never ran on main or on any PR for as long
# as the count was tolerated as "a mismatch". An ARRAY cannot be drained by a child, so the list is
# now consumed by the driver alone; `run_shard` additionally hands every shard `</dev/null` so the
# hermetic contract is stated rather than inherited.
shard_array=()
while IFS= read -r shard; do
  # A line with no non-blank text is not a path, so it is not queued. The counter at `:275` counts
  # `awk 'NF { n++ } END { print n + 0 }'`, i.e. lines with at least one field, so the two agree on
  # everything that can actually arrive: the list comes from `shard_discover` (`:143`), which emits
  # only glob-matched paths that passed `[ -f "$f" ]`, and the containment loop above re-verifies
  # each is a real file (exit 1 at `:506`) — so every line here is a non-blank path and both sides
  # count it exactly once. They are NOT identical as predicates — a CR/VT/FF-only line is a field to
  # awk's default FS and is stripped by bash's `[[:space:]]` — and that residue cannot arrive either:
  # such a line is not a file, so the containment loop above exits 1 on it. The assertion below says
  # what a divergence would mean.
  [ -n "${shard//[[:space:]]/}" ] || continue
  shard_array+=("$shard")
done <<<"$shard_paths"
# ⛔ WHAT THIS COMPARISON IS, AND WHAT IT IS NOT (`#3099` review, P2 — this comment has now claimed a
# protection that does not exist TWICE: first as a truncation detector, then as the arm that caught a
# whitespace-only list line with an inverted message). Neither is true.
#   * It is NOT what makes the list safe: the read above is IN-PROCESS — a here-string consumed by the
#     driver alone — so no child can shorten it. The ARRAY is what makes the list safe.
#   * It is NOT reachable from a blank list line, blank OR whitespace-only: the target-containment
#     loop above rejects a non-file target (`[ ! -f "$t" ]` → exit 1, "does not exist") before this
#     line is reached, and a whitespace-only line is not a file.
#   * The net that NAMES an un-reached shard is the end-of-run set difference below
#     (`shard_unaccounted`, a `comm -23` of the derived list against the two logs) — what the 8ap
#     mutant exercises, not this.
# What remains is a DEFENSIVE ASSERTION, and it fails CLOSED (exit 1 below, before the first shard
# runs). ⛔ Do NOT look for a live trigger — there is none, and asserting one is what this block got
# wrong twice already. Given the current derivation, this comparison CANNOT fire: `shard_discover`
# (`:143`, and `[ -f "$f" ]` at `:147`) emits only glob-matched paths that passed that check, the
# containment loop above
# re-verifies each is a real file inside the checkout, and the read above is in-process — so no line
# reaching it can be blank and no line can be lost. It is kept for the case where that CONTRACT
# changes (a derivation that can emit a non-path, or a read that becomes an external process), and a
# firing means "the derivation or the read changed", never "a shard is missing". The arm that names a
# missing shard is the end-of-run set difference (`shard_unaccounted`), and it is proven by the 8ap
# mutant. The predicates are not identical either way — bash's `[[:space:]]` covers CR/VT/FF where
# awk's default FS does not — which is why this is a comparison of two derivations and not a tautology
# to be deleted.
if [ "${#shard_array[@]}" -ne "$listed" ]; then
  echo "❌ the derived list counts $listed shard(s) but its IN-MEMORY array holds ${#shard_array[@]} — the two derivations of ONE list disagree, so the count no longer describes what would run. Refusing to start (this is a DERIVATION or READ change, not a missing shard: the end-of-run set difference names those)."
  exit 1
fi
for shard in ${shard_array[@]+"${shard_array[@]}"}; do
  shard_budget_trip "$shard"
  run_shard "$shard"
done
echo "───────────────────────────────────────────────────────────────────"
# Runtime self-check 1: every listed shard must have been EXECUTED or DELIBERATELY SKIPPED for
# this slice. This is the arm that catches a helper whose execution was disabled — a text-only
# floor would still see the same listed count. `executed + skipped == listed` also means the list
# was traversed end to end: a slice cannot quietly stop early.
#
# ⛔ AND IT NAMES WHAT IS MISSING (agent-infra#3079). The count alone is the defect that hid this
# for 32 shards: `executed 107 of 139 listed shard(s)` says a number is wrong and nothing else, so
# the reader cannot tell which suites never ran, and the merge rail cannot tell "this shard is red"
# from "this shard did not run". The set difference below is computed from the LIST and the two logs
# the loop itself writes, so it reports every listed shard that is neither executed nor skipped —
# by path — and a mismatch whose missing set is EMPTY is reported as the different defect it is
# (a shard executed twice, i.e. a second list), never as the same message.
if [ $((shard_ran + shard_skipped)) -ne "$listed" ]; then
  echo "❌ executed $shard_ran of $listed listed shard(s) ($shard_skipped skipped) — the list and the execution disagree"
  unaccounted="$(shard_unaccounted)"
  if [ -n "$unaccounted" ]; then
    echo "❌ LISTED BUT NEITHER EXECUTED NOR SKIPPED — $(shard_count_lines "$unaccounted") shard(s) this run never reached:"
    while IFS= read -r _u; do [ -n "$_u" ] && printf '   ❌ NEVER RAN: %s\n' "$_u"; done <<<"$unaccounted"
    echo "   (a short COUNT is not a short LIST: each path above is in the derived list and was never handed to a shard — fix the driver, do not lower the number)"
  else
    echo "❌ …yet every listed shard IS accounted for — so a shard was executed MORE than once: $(sort "$shard_ran_log" | uniq -d | tr '\n' ' ')"
    echo "   (a duplicated run is not extra coverage: check for a second list fed into this loop, #2838's class)"
  fi
  if [ "$shard_skipped" -gt 0 ]; then
    echo "   ⏭  $shard_skipped shard(s) were DELIBERATELY skipped, with the reason recorded:"
    while IFS="$(printf '\t')" read -r _p _why; do [ -n "$_p" ] && printf '   ⏭  SKIPPED: %s (%s)\n' "$_p" "$_why"; done < "$shard_skip_log"
  fi
  exit 1
fi
# ⛔ THE CALL COUNT IS CHECKED TOO, NOT ONLY THE TALLY (#2838). `ran + skipped` uses the same
# counters the loop increments, so it cannot see how many times the loop was ENTERED (a second list
# appended to `$shard_paths` moves both sides together). `slice_calls - past_list_calls` is the
# number of calls the LIST accounts for, and it is the arm that survives the refusal above being
# downgraded to a skip.
if [ $((slice_calls - past_list_calls)) -ne "$listed" ]; then
  echo "❌ the shard loop entered run_shard $((slice_calls - past_list_calls)) time(s) for a list of $listed shard(s) — the list and the execution disagree (a second list, or a re-read of the same one)"
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
# ⛔ THE ONE CALL PAST THE LIST, DECLARED BY NAME (#2838): `slice_skips` refuses an undeclared call
# past the end, and a second sentinel must raise `past_list_budget` deliberately.
shard_past_list=1
run_shard "$sentinel"
shard_past_list=0
rm -f "$sentinel"
if [ "$shard_errors" -ne $((before_err + 1)) ]; then
  echo "❌ the failure-recording arm is broken — a failing shard would not fail this run"
  exit 1
fi
shard_errors=$before_err
shard_ran=$before_ran
shard_skipped=$before_skip
shard_listed=$before_listed

# The budget is ALSO checked after the last shard (the pre-shard trip cannot see a list whose LAST
# suite is the one that ran long), and BEFORE the failure recap, so a run that both overran and
# failed prints both reasons in one place.
shard_budget_trip "(end of list)"

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
    # ⛔ THE CASUALTY NAMES ITSELF WITH THE MARKER (#3187). A bound hit is a FAILURE (it reds the
    # run and enters `shard_failed_list` above like any other), but "this shard failed" and "this
    # shard was STILL RUNNING at the bound" are different diagnoses with different fixes: one is a
    # bug in the suite, the other is a HANG. This line carries the marker and the bound that
    # applied, so the recap answers "which shard, and was it killed or did it fail?" — and it is
    # deliberately NOT part of the identity list above, which `scripts/ci_exemption.py` splits into
    # `bash-shard::<path>` keys (a marker inside a name would be a phantom identity).
    if [ -n "$shard_timeout_list" ]; then
      echo "⏱  TIMEOUT after ${shard_bound}s (SHARD_BOUND): $shard_timeout_list — killed (whole process group), counted as failed, and the run CONTINUED to the remaining shards"
    fi
    # ⛔ EVERY recap REPORTS THE BOUND THAT APPLIED (a red without a bound is a red whose truncation
    # the reader has to guess at), not only the recaps where it fired.
    echo "   ⏱  per-shard bound applied: ${shard_bound_desc}"
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
  echo "   ⏱  this slice: ${shard_time}s of shard work over $shard_ran shard(s); slowest ${shard_slowest_secs}s${shard_slowest:+ ($shard_slowest)}; per-shard bound ${shard_bound_desc}"
else
  echo "✅ all $shard_ran bash shards passed ($swept file(s) syntax-checked)"
  echo "   ⏱  ${shard_time}s of shard work; slowest ${shard_slowest_secs}s${shard_slowest:+ ($shard_slowest)}; per-shard bound ${shard_bound_desc}"
fi


# ── the per-suite notes that used to ride on each `run_shard` line are NOT reproduced here ────────
# Each of those 79 lines carried a one-sentence note (what the suite pins, which incident added it).
# A long comment block of them is NOT inert text: the fleet's `main-worktree-guard` reads
# command-position paths in a script's own source, so a block of ~79 path-shaped comment lines made
# it exhaust its seed budget and REFUSE to run this script at all (measured 2026-10-23; recorded on
# agent-infra#2189). The notes are in git history on the commit that derived this list
# (`git log -p --follow` on this file) and each suite's own header states what it pins — a suite's
# MEMBERSHIP needs neither.
