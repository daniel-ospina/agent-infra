#!/usr/bin/env bash
# admin-merge.sh — the MANDATED safe `--admin` merge (#930).
#
# `gh pr merge --admin` bypasses required checks, so nothing makes it *safe*: it
# cannot tell a check that is already red on main from a NEW failure the PR
# introduces. tortoise #3420 merged at 08:15 carrying
# `tests/test_markers.py::test_no_redirect_stems_registry_exact` — a test NOT in
# main's failing set — and main ratcheted redder.
#
# This script is the chokepoint. It computes the evidence, refuses to merge on a
# genuine new failure, and only then runs `gh pr merge --admin`. The matching
# merge gate (extensions/review-enforcer/) refuses a RAW `gh pr merge … --admin`
# that carries no head-bound evidence comment — so the bypass is safe or it does
# not happen.
#
#   pr-rows.txt    ← scripts/ci-failure-set.sh --commit-rows <head>   # the head
#                    SHA the evidence marker binds to, with each failure's rate
#                    and its stable SIGNATURE
#   main-rates.txt ← scripts/ci-failure-set.sh --main-union-rates N
#   main-sigs.txt  ← scripts/ci-failure-set.sh --main-union-signatures N
#   rotation       ← scripts/ci-failure-set.sh --commit-rows <head> --per-run:
#                    the head's per-run failing-id sets, UNIONED across every
#                    sample of the SAME head (pre- and post-re-run). An id whose
#                    CLASS stays red while the ID moves between samples is
#                    UNATTRIBUTABLE: it is neither PR-unique nor exempt (#3756 E5).
#   residual       ← the EXEMPTION DECISION (scripts/ci_exemption.py decide):
#                    an id is EXEMPT only when it was measured on main over
#                    enough runs WITH a matching signature and the PR's failure
#                    RATE is not materially higher. The residual is the
#                    decision's BLOCKED ∪ UNATTRIBUTABLE set.
#   residual EMPTY          → post head-bound evidence, then merge
#   residual NON-EMPTY      → re-run the PR's failed jobs ONCE; anything the
#                             decision then finds EXEMPT is flaky, not new
#                             (recorded in the evidence). Residual still
#                             non-empty → BLOCK, print the list, exit non-zero,
#                             NO merge.
#
# WHY NOT `comm -23` (#3756 — CATEGORY A, a false PASS). The old classifier
# decided ownership by MEMBERSHIP in a sample of main:
# `unique = pr-fails − union(main's failing ids over N runs)`. An id that
# appeared even ONCE in main's window was subtracted FOREVER, so a PR that
# genuinely BROKE it was EXCUSED and the gate reported GREEN — the more main
# flaked, the less the gate checked. Presence is never sufficient; only a
# measured RATE on both trees is. The module that makes that decision ships WITH
# THE RAIL (`scripts/ci_exemption.py`, next to this script) and is deliberately
# never read from the repo being merged: a grader drawn from the graded system
# is a bypass.
#
# THREE PRECONDITIONS THE FAILING SETS ALONE CANNOT EXPRESS:
#   1. THE HEAD MUST HAVE BEEN TESTED. The lane must have at least one TESTED run
#      for this head (a run that finished `success`, `failure` or `timed_out`) and
#      none still running. A queued run — or a run that finished `cancelled`,
#      `skipped` or `startup_failure`, none of which exercises the code — yields an
#      EMPTY failing set, indistinguishable from "green". Without this gate the
#      rail certifies nothing and merges before CI finishes, and the fresh
#      failure lands after the merge. That is the #3420 ratchet this rail exists
#      to stop (review P0 #3; `tested` rather than `completed`: review P1, cycle 2).
#   2. THE HEAD MUST NOT MOVE. The marker binds ONE SHA. The head is re-resolved
#      immediately before the comment and again by GitHub via
#      `--match-head-commit`, so a rebase inside the window cannot land an
#      unanalyzed head behind SHA-bound evidence (review P1).
#   3. THE LANE MUST BASELINE BOTH SIDES. The decision compares the PR's failure
#      RATE and SIGNATURE against main's, so if main's measurement is EMPTY every
#      failure the PR carries reads as new — including ones already red on main,
#      which turns a safe merge into a false block. A lane is therefore usable
#      only if it has TESTED runs on main too (the same `tested` counter as
#      precondition 1). Repos that split their lanes by TRIGGER (a
#      `pull_request`-only lane and a `push`-only lane) have no single --workflow
#      spanning both sides; `--any-workflow` compares against every lane on main
#      (#1003).
#
# Usage:
#   scripts/admin-merge.sh <PR> [--main-runs N] [--repo owner/repo]
#                              [--workflow <file|name>] [--any-workflow]
#                              [--no-rerun] [--rerun-timeout S] [--dry-run]
#                              [-- <extra gh pr merge flags>]
#
#   --main-runs N        union over main's last N runs (default 10 — see the
#                        #3469 trap in ci-failure-set.sh; a single run is not a
#                        baseline)
#   --workflow <f>       the TEST lane both sides are read from (default
#                        `python-ci.yml`). NOT cosmetic: an unfiltered main
#                        window is dominated by cron/watchdog lanes and can
#                        contain ZERO test runs, so the baseline extracts EMPTY
#                        and every PR failure reads as new — the bogus zero. See
#                        THE BOGUS ZERO in ci-failure-set.sh.
#   --any-workflow       drop the lane filter (opt-out; re-opens the bogus zero)
#   --rerun-timeout S    bound (seconds) on the RE-RUN wait — the wait for a
#                        re-run run to finish. This is an EXPLICIT override;
#                        when absent the bound is DERIVED at rail runtime from a
#                        recent GREEN population's PER-SHARD COMPLETED SUCCESSFUL
#                        job durations (each shard's 2 x max, floored) — never
#                        from the failing run, whose failing shard was truncated
#                        by `pytest -x` (a short sample). There is deliberately NO
#                        GLOBAL constant: B4's population falsifies one —
#                        main-side `test (a)` n=5 median 18.8m / max 24.2m
#                        against `test (b)` n=5 median 46.6m / max 49.9m, so
#                        `test (b)`'s MEDIAN green run is 2.5x `test (a)`'s.
#                        One number is wrong in BOTH directions: it blocks the
#                        slow shard mid-distribution while being far
#                        over-generous for a fast one. For a REMOTE run this
#                        derived bound is the ONLY bound: the run metadata
#                        carries NO within-job activity signal — `updatedAt`
#                        advances on job/step TRANSITIONS, so a single long test
#                        step leaves it frozen for the whole job — and a
#                        separate "no progress" window therefore cannot tell a
#                        healthy long job from a wedged one; it can only fire
#                        EARLY, which is the false STALL this replaces. STALLED
#                        is thus "the run exceeded its own DERIVED per-shard
#                        bound while still non-completed", and the bound is
#                        named (shard, green n, green max) in the message. An
#                        explicit value is a CEILING instead: an operator's cap,
#                        not a claim about the run. See wait_for_run.
#   --no-rerun           skip the flake re-run classification (a non-empty
#                        unique set then blocks immediately)
#   --print-bounds [<run-id>]
#                        print the re-run bound + per-shard table + source. With NO
#                        run id there is nothing to derive from, so this prints the
#                        FAIL-SAFE (3900s) and makes no gh call at all.
#   --dry-run            compute + print the decision; mutates nothing at all —
#                        no CI re-run, no comment, no merge. On the flake path it
#                        reports and exits 0 (it is an inspection, not a verdict;
#                        a real run would re-run and re-classify). Add --no-rerun
#                        to get the no-reclassification verdict as the exit code.
#   --repo owner/repo    repo for the gh calls
#   Extra flags (`--squash`, `--merge`, `--rebase`, `--delete-branch`, `--auto`,
#   …) are passed through to `gh pr merge` rather than hardcoded. `--admin` is
#   always added by this script; a caller-supplied `--admin` is dropped.
#
#   MERGE METHOD DEFAULT. `gh pr merge` REQUIRES exactly one of
#   `--merge`/`--rebase`/`--squash` when it is NOT interactive; with none it
#   errors and NO-OPs. The passthrough above made that an omission the CALLER
#   could make silently, so the rail posted its head-bound evidence marker and
#   then merged NOTHING — a FALSE PASS by construction (B1 lost #3754/#3755 to
#   exactly this). `--squash` is therefore the DEFAULT whenever the caller
#   supplies no merge method; an explicit `--merge`/`--rebase`/`--squash`
#   overrides it.
#
#   THE MERGE'S EXIT STATUS IS CHECKED. A `gh pr merge` that fails AFTER the
#   evidence marker was posted exits non-zero, prints gh's stderr, and posts a
#   head-bound RETRACTION so the marker can never be read as a successful merge.
#
#   THE TWO WAITS ARE DIFFERENT, AND THEY READ DIFFERENTLY. Two independent
#   bounds gate a merge and must never be mistaken for one another (B7: an
#   operator raised --rerun-timeout and the rail exited INSTANTLY, because the
#   precondition gated first — an ambiguous message made it read as a fresh
#   failure):
#     * the LANE-TERMINAL PRECONDITION — the lane must have finished for the
#       head BEFORE any comparison happens. It REFUSES, naming itself:
#       `precondition unmet: run still in_progress — no classification
#       attempted`. `--rerun-timeout` does NOT apply and never started.
#     * the RE-RUN WAIT (`--rerun-timeout`) — a real wait, after a re-run, on a
#       run that is still RUNNING. A still-RUNNING job is not a failure while it
#       is inside its bound; the wait prints STILL-RUNNING progress, and its
#       bound is DERIVED PER SHARD from the run's own observed green durations —
#       never a global constant — with the derivation named in the message. The
#       SAME bound is the STALLED threshold: a remote run exposes no finer
#       activity signal, so "exceeded its own derived bound" IS the wedge signal
#       (an explicit `--rerun-timeout` is a CEILING instead — an operator's cap,
#       with the OPPOSITE remedy ordering: investigate vs wait).
#
#   A DRAFT IS REFUSED EARLY. `commit-workflow` opens drafts deliberately and
#   `gh` refuses to merge one ("Pull Request is still a draft"), so this is a
#   systematic collision. The rail reads `isDraft` BEFORE any CI work and
#   refuses with that specific reason (tell the caller to `gh pr ready`) — never
#   a generic merge failure after the evidence marker.
#
# Env seams (tests only):
#   ADMIN_MERGE_GH                       the gh command (default: `gh`)
#   ADMIN_MERGE_FAILURE_SET_SH           the parser (default: ./ci-failure-set.sh)
#   ADMIN_MERGE_POLL_INTERVAL            seconds between re-run polls (default 10)
#   ADMIN_MERGE_GREEN_RUNS               recent SUCCESSFUL runs sampled per shard
#                                         for the healthy duration (default 5)
#   ADMIN_MERGE_RERUN_FLOOR              per-shard bound FLOOR (default 1200). A
#                                         floor only ever RAISES the bound, so it
#                                         cannot cause the false block the flat
#                                         no-progress window did; it guards a
#                                         shard whose green sample is a single
#                                         short run.
#   ADMIN_MERGE_RERUN_TIMEOUT_FALLBACK   derivation fail-safe (default 3900)

set -uo pipefail

# File-scope so the EXIT trap can read it after `main` returns (P1-2).
TMP=""

GH="${ADMIN_MERGE_GH:-gh}"
# The jobs-JSON parse and the ISO-8601 age both need a real JSON/timestamp
# reader. python3 is already a hard dependency of this rail — ci-failure-set.sh
# routes its FAILED-id parsing through ci_exemption.py — so this adds no new
# dependency, and it is the portable reader (`date -d` is GNU-only).
if command -v python3 >/dev/null 2>&1; then PYTHON_BIN=python3; else PYTHON_BIN=python; fi
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFS="${ADMIN_MERGE_FAILURE_SET_SH:-$SELF_DIR/ci-failure-set.sh}"
EXEMPTION_PY="$SELF_DIR/ci_exemption.py"
POLL_INTERVAL="${ADMIN_MERGE_POLL_INTERVAL:-10}"

# ── THE RE-RUN BOUND IS DERIVED PER SHARD, AT RAIL RUNTIME ──────────────
# There is deliberately NO GLOBAL CONSTANT. B4's population falsifies one:
# on main, `test (a)` is n=5 median 18.8m / max 24.2m while `test (b)` is
# n=5 median 46.6m / max 49.9m — so `test (b)`'s MEDIAN green run is 2.5x
# `test (a)`'s. A single number is wrong in BOTH directions: the old
# `observed_slowest_shard` (1563s) bound blocked `test (b)` mid-
# distribution while being many times over-generous for a 1.6m shard.
#
# Per shard s, over a GREEN population — recent COMPLETED SUCCESSFUL jobs of the
# SAME lane, never the failing run:
#     bound(s) = max(FLOOR, 2 * max(D(s)))   # D(s) = a completed SUCCESSFUL job's duration
# The failing shard's job was truncated by `pytest -x`, so a duration read off the
# failing run is a SHORT failure sample: 2 x it can be SMALLER than the healthy
# re-run it must cover — the exact too-tight-bound defect this replaces, in the
# common case (the slow shard is the one that failed). A shard with NO green
# sample takes the FAIL-SAFE, never the truncated failure.
# The run bound C is the max over the shards the rail might still WAIT ON —
# the NOT-completed ones. When every shard is completed (the normal case: the
# run a re-run is about to replace is terminal), C is the max over ALL shards.
#
# FLOOR is load-bearing: a shard's green bound must never be tiny. A shard whose
# green sample is one short run would otherwise get a bound barely above that run,
# and a healthy re-run a little slower than the one observed sample would be
# called STALLED — the too-tight-bound defect by another door. The floor only
# ever RAISES a bound, so it can never cause a false STALL; it bounds how fast a
# wedged FAST shard is noticed, not whether a healthy run is blocked. The
# fail-safe is larger still and applies to ANY derivation failure — a derivation
# that failed must never produce a SMALL bound.
# The floor and the fail-safe are validated by name in validate_timing_knobs.
FAILSAFE_RERUN_TIMEOUT="${ADMIN_MERGE_RERUN_TIMEOUT_FALLBACK:-3900}"
RERUN_FLOOR="${ADMIN_MERGE_RERUN_FLOOR:-1200}"

# The lane-run projection, mirrored from ci-failure-set.sh's LANE_RUN_JQ. Used
# ONLY to locate a PENDING run id for the lane-terminal diagnostic: the parser's
# provenance file records the FAILING runs, and a pending run has no conclusion,
# so its id never reaches that file.
LANE_RUN_JQ='.[] | "\(.status)\t\(.conclusion)\t\(.headSha):\(.databaseId)"'

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }
say_err() { printf '%s\n' "$*" >&2; }
info() { printf '%s\n' "$*"; }

count_lines() { wc -l < "$1" | tr -d ' '; }

# report_value <report-file> <key> → the numeric value, or empty.
report_value() {
  [ -n "$1" ] && [ -r "$1" ] || { printf ''; return 0; }
  awk -F= -v k="$2" '$1 == k { print $2 }' "$1"
}

# Counter predicates — and why they are written this way.
#
# A counter that is NOT A NUMBER answers nothing: `[ "$x" -eq 0 ]` (and `-gt 0`)
# returns 2 on such a value, and under `set -uo pipefail` (no `-e`) the `if` body
# is SKIPPED — so a guard written as `[ "$x" -eq 0 ]` fails OPEN on a malformed
# report. Both predicates therefore return FALSE for an unreadable counter, and
# every caller must BLOCK unless its condition is AFFIRMATIVELY true (`!`) — never
# "unless it evaluated false".
#
# check-lane-tested.sh refuses the same values for the detector (a fail-open in
# the guard itself, cycle-5 review P2); the two consumers must agree on the
# report contract.
counter_is_zero() {
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -eq 0 ]
}
counter_is_positive() {
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -gt 0 ]
}
# TRUE only for a counter that is a readable non-negative integer. A caller that must
# COMPARE two counters uses this instead of a bare `-lt`, which returns 2 on garbage —
# and under `set -uo pipefail` (no `-e`) that SKIPS the guard rather than failing it.
counter_is_number() {
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  return 0
}
# TRUE only for an all-digit value STRICTLY GREATER than <max>, for a value of ANY
# length. `counter_is_number` alone is not enough: it accepts a run of digits too
# long for the shell's 64-bit integers, and such a value breaks the guard two ways.
# A value PAST int64max makes the `-lt`/`-ge` comparisons that consume it ERROR
# (test returns 2, so the `if` body is SKIPPED) — a silent fail-OPEN in the very
# guard that exists to fail closed. A value at int64max in a `$((… + step))`
# WRAPS negative, so a comparison consuming it PASSES for a bound that is really
# absurd. The comparison is therefore done by DIGIT COUNT first, so a 30-digit
# string never reaches a `-gt` or a `$((…))` that would error or wrap; equal
# lengths compare lexicographically, which for all-digit strings is numeric.
counter_exceeds_max() {
  local v="${1:-}" max="${2:-}"
  case "$v" in ''|*[!0-9]*) return 1 ;; esac
  case "$max" in ''|*[!0-9]*) return 1 ;; esac
  v="${v#"${v%%[!0]*}"}"; [ -n "$v" ] || v=0
  [ "${#v}" -gt "${#max}" ] && return 0
  [ "${#v}" -lt "${#max}" ] && return 1
  [ "$v" \> "$max" ]
}
# TRUE for an all-digit value carrying a LEADING ZERO (`0100`, `08`, `0008`) — the
# one numeric spelling the shell does NOT read uniformly. bash ARITHMETIC reads it
# as OCTAL, while the `test` builtin, `sleep`, and the counter predicates above all
# read it as DECIMAL. `POLL_INTERVAL=010` is the live case: `10#$step` advances the
# wait's clock by 10 while `sleep "$POLL_INTERVAL"` sleeps 10 — the same number only
# because a `10#` guards that site; drop it and the interval is accounted as 8.
# `08`/`0999` are not valid octal at all and error such a site outright. Refusing
# the spelling on every timing knob gives one spelling one meaning; `10#` at the
# arithmetic sites is defence in depth.
counter_has_leading_zero() {
  case "${1:-}" in 0[0-9]*) return 0 ;; esac
  return 1
}

# TIMING_KNOB_MAX — the largest value any timing knob may take. NOT a policy bound:
# an ARITHMETIC one. Nine digits is ~31 years, far beyond any usable bound and
# comfortably inside the range these comparisons can hold, so a value above it is
# nonsense AND unsafe (see counter_exceeds_max).
TIMING_KNOB_MAX=999999999
# POLL_INTERVAL_MAX — a tighter, POLICY bound. The poll interval PACES the bound
# detection, so an hour between polls is already useless; more to the point, an
# all-digit giant that `sleep` cannot take (BSD `sleep` rejects it with a usage
# error) made EVERY poll's sleep fail, turning a 600s window into a tight gh BUSY
# SPIN — measured at 201 `gh run view` calls in 11s. 0 stays LEGAL: it is the
# deterministic TEST SEAM (no real sleeping), not an interval.
POLL_INTERVAL_MAX=3600

# validate_timing_knobs — REFUSE a timing knob that is not a positive integer.
# A comparison against a non-numeric value returns 2, and under `set -uo pipefail`
# (no `-e`) the `if` body is SKIPPED: a bad value silently stops the guard from
# gating. The floor, the fail-safe and the poll interval all feed `-ge`/`-lt`, so a
# `10m` value can make a guard's comparison error out — which SKIPS it instead of
# failing it — and a `10m` poll interval also makes every `sleep` fail, turning the
# wait into a tight gh BUSY SPIN.
#
# There is no longer an ORDERING to enforce between a stall window and a bound:
# they are the SAME derived bound (see wait_for_run). STALLED is that derived bound
# being exceeded; CEILING is an explicit `--rerun-timeout` being exceeded — a
# provenance distinction, not a race between two windows.
#
# POLL_INTERVAL is validated too, and in two stages: a NON-NUMERIC value makes
# `[ "$step" -gt 0 ]` error (step falls back to 1) while `sleep "$POLL_INTERVAL"`
# then fails EVERY iteration; and a numeric value `sleep` cannot take does the
# same thing — "all digits" is not the same as "usable". 0 stays LEGAL: it is the
# deterministic TEST SEAM (no real sleeping), never refused.
#
# LEADING ZEROS are refused on EVERY timing knob, before any arithmetic. bash reads
# `0100` as OCTAL 64 in `$((…))` but as DECIMAL 100 in `test`/`sleep`, so one
# spelling could mean two numbers across the clock the wait advances and the clock
# it sleeps. `08`/`0999` are not even valid octal and error such a site. One
# spelling, one meaning: refuse the zeros.
#
# Named, at startup, before any CI work.
validate_timing_knobs() {
  local bad=0
  if counter_has_leading_zero "$RERUN_FLOOR"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_RERUN_FLOOR='${RERUN_FLOOR}' — a LEADING ZERO is ambiguous:"
    say_err "   bash ARITHMETIC reads it as OCTAL while the 'test' comparisons that gate the wait read it"
    say_err "   as DECIMAL, so the floor and the wait would disagree about the same value."
    say_err "   Write it without the leading zero (e.g. '1200', not '01200')."
  elif ! counter_is_positive "$RERUN_FLOOR"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_RERUN_FLOOR='${RERUN_FLOOR}' — the per-shard bound"
    say_err "   floor must be a POSITIVE integer number of seconds."
  elif counter_exceeds_max "$RERUN_FLOOR" "$TIMING_KNOB_MAX"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_RERUN_FLOOR='${RERUN_FLOOR}' — beyond the usable range"
    say_err "   (max ${TIMING_KNOB_MAX}s). An all-digit value past the shell's integer range makes the"
    say_err "   bound comparison error out, which SKIPS it instead of failing it."
  fi
  if counter_has_leading_zero "$FAILSAFE_RERUN_TIMEOUT"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_RERUN_TIMEOUT_FALLBACK='${FAILSAFE_RERUN_TIMEOUT}' — a LEADING"
    say_err "   ZERO is ambiguous: bash ARITHMETIC reads it as OCTAL while the comparisons that gate the"
    say_err "   wait read it as DECIMAL. Write it without the leading zero (e.g. '3900', not '03900')."
  elif ! counter_is_positive "$FAILSAFE_RERUN_TIMEOUT"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_RERUN_TIMEOUT_FALLBACK='${FAILSAFE_RERUN_TIMEOUT}' — the"
    say_err "   derivation fail-safe must be a POSITIVE integer number of seconds."
  elif counter_exceeds_max "$FAILSAFE_RERUN_TIMEOUT" "$TIMING_KNOB_MAX"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_RERUN_TIMEOUT_FALLBACK='${FAILSAFE_RERUN_TIMEOUT}' — beyond"
    say_err "   the usable range (max ${TIMING_KNOB_MAX}s)."
  fi
  if counter_has_leading_zero "$POLL_INTERVAL"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_POLL_INTERVAL='${POLL_INTERVAL}' — a LEADING ZERO is"
    say_err "   ambiguous and changes the PACING: bash ARITHMETIC accounts '010' as octal 8 while"
    say_err "   'sleep' sleeps 10s, so the clock the wait advances and the clock it sleeps disagree."
    say_err "   Write it without the leading zero (e.g. '10', not '010')."
  elif ! counter_is_number "$POLL_INTERVAL"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_POLL_INTERVAL='${POLL_INTERVAL}' — the poll interval must be"
    say_err "   a NON-NEGATIVE integer number of seconds (0 is legal: the test seam). A non-numeric"
    say_err "   value makes the step guard error and every 'sleep' fail, turning the wait into a tight"
    say_err "   BUSY SPIN of gh calls instead of a paced poll."
  elif counter_exceeds_max "$POLL_INTERVAL" "$POLL_INTERVAL_MAX"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_POLL_INTERVAL='${POLL_INTERVAL}' — beyond the usable range"
    say_err "   (max ${POLL_INTERVAL_MAX}s). 'all digits' is not enough: a value 'sleep' cannot take fails"
    say_err "   on EVERY poll, so the wait becomes a tight BUSY SPIN of gh calls instead of a paced"
    say_err "   poll — and an interval beyond an hour paces nothing."
  fi
  [ "$bad" -eq 0 ] || { say_err "   These are operator knobs; fix the value and re-run the rail."; return 1; }
  return 0
}

resolve_head() {
  local pr="$1"; shift
  # shellcheck disable=SC2086
  $GH pr view "$pr" "$@" --json headRefOid --jq .headRefOid 2>/dev/null
}

# resolve_draft <pr> → the PR's `isDraft` flag (`true`/`false`). `commit-workflow`
# opens drafts on purpose, and `gh pr merge` refuses a draft with "Pull Request is
# still a draft" — so the rail probes this BEFORE any CI work and refuses early
# with THAT reason, rather than surfacing it late as a generic merge failure once
# the head-bound evidence marker has already been posted.
resolve_draft() {
  local pr="$1"; shift
  # shellcheck disable=SC2086
  $GH pr view "$pr" "$@" --json isDraft --jq .isDraft 2>/dev/null
}

# run_failure_set <mode...> — invoke the shared parser, splitting its stdout
# into the set (stdout) while surfacing an EXTRACTION FAILURE as our own exit 1.
# An extraction error must never be read as "no unique failures" — that is the
# vacuous pass this rail exists to prevent.
run_failure_set() {
  # shellcheck disable=SC2086
  "$BASH" "$CFS" "$@"
}

# is_run_id — a GitHub run id is decimal. Used to accept the OPTIONAL
# `--print-bounds <run-id>` argument without swallowing the next flag.
is_run_id() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# fail_safe_rerun_timeout <reason> — install the fail-safe and say WHY, loudly.
# NEVER small: the whole defect this replaces was a bound that was too tight.
fail_safe_rerun_timeout() {
  local reason="$1"
  DERIVED_RERUN_TIMEOUT="$FAILSAFE_RERUN_TIMEOUT"
  DERIVED_RERUN_SOURCE="fail-safe ${FAILSAFE_RERUN_TIMEOUT}s — derivation unavailable (${reason})"
  DERIVED_TABLE=""
  say_err "admin-merge: derivation unavailable (${reason}) — using the fail-safe ${FAILSAFE_RERUN_TIMEOUT}s (never a small bound)"
}

# fetch_run_jobs <run-id> → the raw jobs JSON on stdout. The API rather than
# `gh run view --json jobs`, because only the API carries `started_at` /
# `completed_at` per job. It goes through $GH so the harness can stub it — no new
# network path. `{owner}/{repo}` is gh's own placeholder, used only when --repo
# was not supplied. $GH is expanded UNQUOTED, like every other call site in this
# rail: the seam is a COMMAND (the presence check reads `${GH%% *}`), so
# `ADMIN_MERGE_GH="gh --hostname h"` must word-split into a command and its
# flags — a quoted "$GH" ran a file literally named `gh --hostname h`.
# shellcheck disable=SC2086
fetch_run_jobs() {
  local run_id="$1" slug
  if [ -n "$REPO" ]; then
    slug="repos/$REPO/actions/runs/$run_id/jobs?per_page=100"
  else
    slug="repos/{owner}/{repo}/actions/runs/$run_id/jobs?per_page=100"
  fi
  $GH api "$slug" --paginate
}

# ── THE GREEN POPULATION ────────────────────────────────────────────────
# D(s) is sampled from recent COMPLETED SUCCESSFUL jobs of the SAME lane —
# NEVER from the run about to be re-run. On that run the shard that failed was
# truncated by `pytest -x`, so its completed duration is a SHORT failure sample
# and `2 x` it can be SMALLER than the healthy re-run it must cover. That is the
# too-tight-bound defect this derivation replaces, and it fires in the COMMON
# case (the slow shard is the one that failed). `gh run list` is already on this
# rail's network surface (pending_run_id uses it); the jobs fetch is the Jobs API
# fetch_run_jobs already uses.
GREEN_RUNS="${ADMIN_MERGE_GREEN_RUNS:-5}"

# green_run_ids — recent COMPLETED SUCCESSFUL run ids for the selected lane, one
# per line. `--any-workflow` is a PARSER flag, not a `gh run list` flag, so it is
# deliberately NOT forwarded (real gh rejects it, and `2>/dev/null || true` would
# hide that — the WAIT-vs-STALLED diagnostic would be silently dead).
green_run_ids() {
  local args=()
  [ -n "${REPO:-}" ] && args+=(--repo "$REPO")
  if [ "${ANY_WORKFLOW:-0}" -ne 1 ] && [ -n "${WORKFLOW:-}" ]; then
    args+=(--workflow "$WORKFLOW")
  fi
  # shellcheck disable=SC2086
  $GH run list --status success --limit "$GREEN_RUNS" \
    ${args[@]+"${args[@]}"} \
    --json databaseId --jq '.[].databaseId' 2>/dev/null || true
}

# derive_rerun_timeout <run-id> — set DERIVED_RERUN_TIMEOUT / _SOURCE / _TABLE
# from a GREEN population's observed per-shard job durations. NEVER fails the
# caller: every failure path installs the fail-safe and says so loudly.
#
# The TARGET run supplies only the shard SET and which shards are unfinished (the
# pool the rail might wait on). Its own durations are deliberately NOT used — a
# failure-truncated sample must never stand in for a shard's healthy duration, and
# a shard with no green sample takes the FAIL-SAFE.
#
# Shard normalisation: a job name is (1) stripped of a reusable-workflow caller
# prefix (`<caller> / <called>`, which gh renders for a `workflow_call` job) and
# (2) reduced to its FIRST matrix axis (`test (a, docker)` → `test (a)`), then
# left verbatim. That is the shard identity the workflow's own `name:` template
# produces — `test (a)`, `test (b)`, `test-slow (b)`, `test-carve-out` — so the
# grouping survives the two things that actually vary between runs (the caller
# prefix and extra matrix axes) without inventing a grouping key that is not the
# shard.
derive_rerun_timeout() {
  local run_id="$1" json_file="" green_file="" gids="" gid="" out="" rc=0 line tag name n maxd ceil unfin sample
  local green_files=()
  DERIVED_RERUN_TIMEOUT="$FAILSAFE_RERUN_TIMEOUT"
  DERIVED_RERUN_SOURCE=""
  DERIVED_TABLE=""
  [ -n "$run_id" ] || { fail_safe_rerun_timeout "no run id"; return 0; }
  command -v "${GH%% *}" >/dev/null 2>&1 || { fail_safe_rerun_timeout "gh absent"; return 0; }
  json_file="$(mktemp "${TMPDIR:-/tmp}/admin-merge-jobs.XXXXXX")"
  if ! fetch_run_jobs "$run_id" > "$json_file" 2>/dev/null; then
    rm -f "$json_file"
    fail_safe_rerun_timeout "jobs API error"
    return 0
  fi
  if [ ! -s "$json_file" ]; then
    rm -f "$json_file"
    fail_safe_rerun_timeout "empty jobs response"
    return 0
  fi
  # The GREEN population: the failing run is the SHARD MAP, never the sample.
  gids="$(green_run_ids)"
  if [ -n "$gids" ]; then
    while IFS= read -r gid; do
      [ -n "$gid" ] || continue
      green_file="$(mktemp "${TMPDIR:-/tmp}/admin-merge-green.XXXXXX")"
      if fetch_run_jobs "$gid" > "$green_file" 2>/dev/null && [ -s "$green_file" ]; then
        green_files+=("$green_file")
      else
        rm -f "$green_file"
      fi
    done <<< "$gids"
  fi
  out="$("$PYTHON_BIN" -c 'import datetime, json, re, sys
floor, failsafe, tpath = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
gpaths = sys.argv[4:]
def norm(name):
    s = (name or "").strip()
    if " / " in s:
        s = s.rsplit(" / ", 1)[1].strip()
    m = re.match(r"^(.*?)\s*\((.*)\)\s*$", s)
    if m and m.group(1).strip():
        s = "%s (%s)" % (m.group(1).strip(), m.group(2).split(",")[0].strip())
    return s
def ts(raw):
    if not raw:
        return None
    try:
        d = datetime.datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None
    if d.tzinfo is None:
        d = d.replace(tzinfo=datetime.timezone.utc)
    return d
def secs(job):
    a, b = ts(job.get("started_at")), ts(job.get("completed_at"))
    if a is None or b is None:
        return None
    n = int((b - a).total_seconds())
    return n if n >= 0 else None
def jobs_of(path):
    raw = open(path, "r", encoding="utf-8", errors="replace").read()
    docs = []
    dec = json.JSONDecoder()
    i = 0
    while i < len(raw):
        while i < len(raw) and raw[i] in " \t\r\n":
            i += 1
        if i >= len(raw):
            break
        try:
            obj, i = dec.raw_decode(raw, i)
        except ValueError:
            return None
        docs.append(obj)
    jobs = []
    saw = False
    for d in docs:
        if isinstance(d, dict) and isinstance(d.get("jobs"), list):
            saw = True
            jobs.extend(j for j in d["jobs"] if isinstance(j, dict))
    return jobs if saw else None
target = jobs_of(tpath)
if target is None:
    raise SystemExit(2)
shards = {}
target_completed = 0
for job in target:
    name = norm(job.get("name"))
    if not name:
        continue
    rec = shards.setdefault(name, {"unfinished": False})
    if job.get("status") and job.get("status") != "completed":
        rec["unfinished"] = True
    if secs(job) is not None:
        target_completed += 1
if target_completed == 0:
    raise SystemExit(3)
green = {}
for path in gpaths:
    jobs = jobs_of(path)
    if jobs is None:
        continue
    for job in jobs:
        if job.get("conclusion") != "success":
            continue
        name = norm(job.get("name"))
        if not name:
            continue
        secs_n = secs(job)
        if secs_n is None:
            continue
        rec = green.setdefault(name, {"n": 0, "max": 0})
        rec["n"] += 1
        if secs_n > rec["max"]:
            rec["max"] = secs_n
if not green:
    raise SystemExit(4)
def shard_ceiling(name):
    rec = green.get(name)
    if rec is None:
        return failsafe
    return max(floor, 2 * rec["max"])
for name in sorted(shards):
    rec = green.get(name)
    if rec is None:
        n, mx, sample = 0, 0, "none"
    else:
        n, mx, sample = rec["n"], rec["max"], "green"
    print("SHARD\t%s\t%d\t%d\t%d\t%d\t%s" % (name, n, mx, shard_ceiling(name), 1 if shards[name]["unfinished"] else 0, sample))
unfinished = [s for s in shards if shards[s]["unfinished"]]
if unfinished:
    pool, reason = unfinished, "slowest unfinished shard"
else:
    pool, reason = list(shards), "slowest shard (every shard completed)"
win = max(sorted(pool), key=shard_ceiling)
rec = green.get(win)
wn, wmax = (0, 0) if rec is None else (rec["n"], rec["max"])
print("C\t%d\t%s\t%d\t%d\t%s" % (shard_ceiling(win), win, wn, wmax, reason))' "$RERUN_FLOOR" "$FAILSAFE_RERUN_TIMEOUT" "$json_file" ${green_files[@]+"${green_files[@]}"} 2>/dev/null)"
  rc=$?
  rm -f "$json_file" ${green_files[@]+"${green_files[@]}"}
  case "$rc" in
    0) [ -n "$out" ] || { fail_safe_rerun_timeout "unparsable jobs response"; return 0; } ;;
    3) fail_safe_rerun_timeout "no job durations observed"; return 0 ;;
    4) fail_safe_rerun_timeout "no completed SUCCESSFUL job observed for the lane"; return 0 ;;
    *) fail_safe_rerun_timeout "unparsable jobs response"; return 0 ;;
  esac
  local table="" c_line="" c="" win="" winn="" winmax="" wreason="" state max_disp
  while IFS= read -r line; do
    case "$line" in
      C$'\t'*) c_line="$line" ;;
      SHARD$'\t'*)
        IFS=$'\t' read -r tag name n maxd ceil unfin sample <<< "$line"
        state="finished"
        [ "$unfin" = "1" ] && state="unfinished"
        if [ "$sample" = "green" ]; then max_disp="${maxd}s"; else max_disp="--"; fi
        table="${table}shard ${name}	n=${n}	max=${max_disp}	bound=${ceil}s	state=${state}	sample=${sample}"$'\n'
        ;;
    esac
  done <<< "$out"
  DERIVED_TABLE="${table%$'\n'}"
  IFS=$'\t' read -r tag c win winn winmax wreason <<< "$c_line"
  counter_is_number "$c" || { fail_safe_rerun_timeout "unparsable jobs response"; return 0; }
  DERIVED_RERUN_TIMEOUT="$c"
  DERIVED_RERUN_SOURCE="derived per-shard green bound ${c}s (${wreason}: ${win}, green n=${winn}, green max=${winmax}s)"
}

# pending_run_id <head> — the first NON-COMPLETED lane run id for this head, or
# empty. Only the lane-terminal diagnostic needs it: the parser's provenance file
# records the FAILING runs, and a pending run has no conclusion, so its id never
# reaches that file.
pending_run_id() {
  local head="$1" line args=()
  [ -n "${REPO:-}" ] && args+=(--repo "$REPO")
  # ONLY gh-native flags. `--any-workflow` is the PARSER's opt-out: real gh
  # rejects it (`unknown flag`), and `2>/dev/null || true` hid that, so the
  # WAIT-vs-STALLED diagnostic was silently dead for the very invocation
  # commit-workflow's own docs prescribe.
  if [ "${ANY_WORKFLOW:-0}" -ne 1 ] && [ -n "${WORKFLOW:-}" ]; then
    args+=(--workflow "$WORKFLOW")
  fi
  # shellcheck disable=SC2086
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in completed$'\t'*) continue ;; esac
    printf '%s' "${line##*:}"
    return 0
  done < <($GH run list --commit "$head" --limit 100 \
      ${args[@]+"${args[@]}"} \
      --json databaseId,status,conclusion,headSha --jq "$LANE_RUN_JQ" 2>/dev/null || true)
  return 0
}

# run_exemption_decision <pr-rows> <main-rates> <main-sigs> <rotation> <prefix>
#   Runs the exemption decision and writes `<prefix>.{verdict,blocked,unattributable,exempt}`.
#   Returns 0 when a VERDICT was produced (BLOCK or CLEAN — both are decisions),
#   1 when the decision could NOT run (module absent, unreadable input, crash).
#   The distinction is load-bearing: the CLI exits 1 for a GATED verdict as well
#   as for a crash, so the VERDICT FILE is the only thing that tells "the gate
#   refused this PR" from "the gate is broken". Reading a crash as CLEAN is
#   fail-open; reading it as BLOCK is merely a false block, so every ambiguous
#   path returns 1 and the caller BLOCKS loudly.
run_exemption_decision() {
  local pr_rows="$1" main_rates="$2" main_sigs="$3" rotation="$4" prefix="$5"
  if [ ! -f "$EXEMPTION_PY" ]; then
    say_err "admin-merge: ✗ the exemption decision module is ABSENT at $EXEMPTION_PY."
    say_err "   The rail refuses to fall back to presence-based subtraction — that is the"
    say_err "   #3756 category-A defect (a PR that breaks a test main once flaked gets"
    say_err "   excused and the gate reports GREEN). Restore the agent-infra checkout."
    return 1
  fi
  rm -f "$prefix.verdict" "$prefix.blocked" "$prefix.unattributable" "$prefix.exempt"
  local rot_args=()
  [ -n "$rotation" ] && rot_args=(--rotation "$rotation")
  "$PYTHON_BIN" "$EXEMPTION_PY" decide \
    --pr-failures "$pr_rows" --main-rates "$main_rates" --main-signatures "$main_sigs" \
    ${rot_args[@]+"${rot_args[@]}"} \
    --blocked-out "$prefix.blocked" --unattributable-out "$prefix.unattributable" \
    --exempt-out "$prefix.exempt" --verdict-out "$prefix.verdict" \
    > "$prefix.lines" 2> "$prefix.err"
  if [ ! -s "$prefix.verdict" ] || ! grep -q '^VERDICT' "$prefix.verdict"; then
    say_err "admin-merge: ✗ BLOCK — the exemption decision produced NO verdict; refusing to"
    say_err "   read a broken gate as a green one. The module said:"
    sed 's/^/   /' "$prefix.err" >&2 2>/dev/null || true
    return 1
  fi
  return 0
}

# residual_of <prefix> <out-file> — the set the merge is refused over: the
# decision's BLOCKED ∪ UNATTRIBUTABLE ids. They are disjoint, and both refuse.
residual_of() {
  local prefix="$1" out="$2"
  : > "$out"
  [ -s "$prefix.blocked" ] && cat "$prefix.blocked" >> "$out"
  [ -s "$prefix.unattributable" ] && cat "$prefix.unattributable" >> "$out"
  sort -u -o "$out" "$out"
}

# wait_for_run <run-id> — poll until the run is `completed`.
#   return 0  completed.
#   return 1  STALLED — still non-completed at the DERIVED per-shard bound. THIS is
#             the failure signal. A REMOTE run exposes no within-job activity
#             signal (`updatedAt` advances on job/step transitions, so a single
#             long step freezes it for the whole job), so a separate no-progress
#             window cannot distinguish a healthy long run from a wedged one — it
#             can only fire EARLY. The run's own green-derived bound is therefore
#             the ONLY honest discriminator; the message names the shard, its
#             green n and its green max.
#   return 2  CEILING — still RUNNING at an EXPLICIT `--rerun-timeout`. An
#             operator's cap is not a claim about the run, so this stays distinct
#             from STALLED; it is still NOT a failure of the run.
#   return 3  UNOBSERVABLE — gh could not be read for the whole bound, so the
#             run's state was NEVER OBSERVED. Deliberately distinct from STALLED
#             (1): "exceeded its bound" is a claim about a run we watched; an
#             outage is the absence of that observation. Opposite remedies.
# A still-RUNNING run prints progress (status, elapsed, bound, and the
# derivation) instead of a verdict — the old flat message read as a failure
# when it was only impatience (B5).
wait_for_run() {
  local run_id="$1" waited=0 unobs=0 observed=0 step status line
  # Wall-clock accounting must advance even when the test seam sets the interval
  # to 0 — a 0-step loop can never reach its own bound and spins forever.
  step="$POLL_INTERVAL"; [ "$step" -gt 0 ] 2>/dev/null || step=1
  while [ "$waited" -lt "$RERUN_TIMEOUT" ]; do
    # ONE gh call: the run's completion state. `updatedAt` is deliberately NOT
    # read. It advances on JOB/STEP TRANSITIONS, so it is frozen for the entire
    # duration of a single long step — a progress clock that cannot tick during
    # the very job it is supposed to be watching. Treating its freeze as "no
    # progress" is the false STALL this wait no longer reports.
    # shellcheck disable=SC2086
    line="$($GH run view "$run_id" ${repo_args[@]+"${repo_args[@]}"} \
      --json status --jq '.status' 2>/dev/null || true)"
    status="$line"
    [ "$status" = "completed" ] && return 0
    # "Could not read the run" is NOT "the run exceeded its bound". A gh failure
    # yields an empty status; counting that as progress-less made a transient
    # gh/auth/network outage report STALLED — a claim the code cannot support,
    # because it never read the run. The two faults have OPPOSITE remedies —
    # repair gh, vs escalate a wedged run — so they must not share a diagnosis.
    # Fail-closed either way: an unreadable run still blocks.
    if [ -z "$status" ] || [ "$status" = "unknown" ]; then
      unobs=$((unobs + 10#$step))
      sleep "$POLL_INTERVAL"; waited=$((waited + 10#$step)); continue
    fi
    observed=1; unobs=0
    info "admin-merge: … run $run_id STILL RUNNING (status=${status}, ${waited}s of the ${RERUN_TIMEOUT}s bound — ${RERUN_TIMEOUT_SOURCE}). A running job is not a failure — waiting."
    sleep "$POLL_INTERVAL"
    waited=$((waited + 10#$step))
  done
  # The bound elapsed. If the run was NEVER observed — unreadable for the whole
  # bound — this is not a stall claim: a stall is a claim about a run we watched.
  if [ "$observed" -eq 0 ] || [ "$unobs" -ge "$RERUN_TIMEOUT" ]; then
    return 3
  fi
  # PROVENANCE, not timing, decides the verdict: an explicit cap is a CEILING;
  # the derived per-shard bound is a STALL.
  [ "${RERUN_TIMEOUT_EXPLICIT:-0}" -eq 1 ] && return 2
  return 1
}

# print_bounds [<run-id>] — the re-run bound, its per-shard table (each figure
# carrying its n), and the source. `rerun-timeout=` stays the FIRST line:
# existing greps depend on the key, and it is also the STALLED threshold — there
# is ONE bound for a remote run (see wait_for_run). With NO run id there is
# nothing to derive from, so this is the one path that prints the fail-safe and
# makes no call.
print_bounds() {
  local run_id="$1"
  if [ "$RERUN_TIMEOUT_EXPLICIT" -eq 1 ]; then
    printf 'rerun-timeout=%s\n' "$RERUN_TIMEOUT"
    printf 'source=explicit --rerun-timeout (a CEILING, not a derived stall bound)\n'
    return 0
  fi
  if [ -z "$run_id" ]; then
    printf 'rerun-timeout=%s\n' "$FAILSAFE_RERUN_TIMEOUT"
    printf 'source=fail-safe %ss — no run id supplied; the derivation needs a run (pass one: --print-bounds <run-id>)\n' "$FAILSAFE_RERUN_TIMEOUT"
    return 0
  fi
  derive_rerun_timeout "$run_id"
  printf 'rerun-timeout=%s\n' "$DERIVED_RERUN_TIMEOUT"
  [ -n "$DERIVED_TABLE" ] && printf '%s\n' "$DERIVED_TABLE"
  printf 'source=%s\n' "$DERIVED_RERUN_SOURCE"
}

# build_evidence — the machine-readable comment. The marker binds the evidence
# to ONE head SHA: every push invalidates it, and the merge gate matches on it.
# ── EVIDENCE TAIL: one bound, one note, no fences ───────────────────────────
# The shape here is deliberately minimal, and the reasons are load-bearing:
#
#  * A LIST, not a fenced code block. A fence is a parser with state: a node id
#    containing a backtick run closes it early and swallows the rest of the
#    comment. A list has no such surface — so the fence-length computation, the
#    clip disclosure and the fence-balance test all cease to exist rather than
#    needing to be right.
#  * ONE limit for every embedded list, sized from the OBSERVED distribution:
#    main's union baseline runs ~18-19 entries of ~60 chars, and the default
#    window is 10 runs. So in practice the limit never fires — it is a safety
#    branch, not machinery that engages on every merge. 25 x 300 = 7,500 chars
#    per list; four lists is 30,000, comfortably under GitHub's 65,536-char body
#    cap, with no per-case arithmetic to re-derive.
#  * ONE note, on every list that was trimmed. A capped list that LOOKS complete
#    is worse than no list, so trimming is always stated.
#  * The display policy is stated ONCE in the body, not recomputed per list —
#    which is why there is no second note vocabulary.
#
# Bounds here are sized to what has actually been observed, not to a hypothetical
# worst case. Over-sizing them was how this section accumulated four interacting
# rules and a fence algorithm in the first place.
EVIDENCE_ENTRIES=25
EVIDENCE_WIDTH=300

# One <details> block: a list, capped, with a single stated remainder.
#   $1 summary   $2 newline-separated content   $3 what to say when empty
evidence_list() {
  local summary="$1" content="$2" empty="$3"
  local shown total more=0
  # `|| true` guards the pipeline against SIGPIPE from `head` on large input.
  shown="$(printf '%s\n' "$content" | head -n "$EVIDENCE_ENTRIES" | cut -c1-"$EVIDENCE_WIDTH" || true)"
  total="$(printf '%s\n' "$content" | grep -c . 2>/dev/null || true)"
  total="${total:-0}"
  if [ "$total" -gt "$EVIDENCE_ENTRIES" ]; then more=$((total - EVIDENCE_ENTRIES)); fi
  printf '<details><summary>%s</summary>\n\n' "$summary"
  if [ -z "$(printf '%s' "$shown" | tr -d '[:space:]')" ]; then
    printf '%s\n' "$empty"
  else
    printf '%s\n' "$shown" | grep . | sed 's/^/- /'
    if [ "$more" -gt 0 ]; then
      printf -- '- ...and %s more (list capped; the full set is reproducible from the run ids above)\n' "$more"
    fi
  fi
  printf '\n</details>\n'
  return 0
}

# The run ids for the provenance line, comma-separated — same single limit, so
# there is one number to reason about rather than one per field.
provenance_ids() {
  local raw n
  raw="$(tr '\n' ',' < "$1" | sed 's/,,*/,/g; s/,$//')"
  n="$(printf '%s' "$raw" | awk -F, '{print NF+0}')"
  if [ "${n:-0}" -gt "$EVIDENCE_ENTRIES" ]; then
    printf '%s' "$(printf '%s' "$raw" | cut -d, -f1-"$EVIDENCE_ENTRIES"),+$((n - EVIDENCE_ENTRIES)) more"
  else
    printf '%s' "$raw"
  fi
}

build_evidence() {
  local head="$1" main_prov="$2" pr_count="$3" main_count="$4"
  local unique_raw="$5" flake_line="$6" analyzed="$7" lane="$8"
  local pr_fails="$9" main_fails="${10}" final_unique_raw="${11:-}" exempt_raw="${12:-}"

  printf '<!-- admin-merge-safety: %s -->\n' "$head"
  printf 'PR head: %s\n' "$head"
  printf 'test lane: %s\n' "$lane"
  # The count is the runs that ACTUALLY CONTRIBUTED to the union, not the
  # REQUESTED window ($MAIN_RUNS). A run that contributed nothing — it was green —
  # adds nothing to the union and is not counted, so N always equals the number of
  # ids printed here, and the total window is still stated on the `Lane completion:`
  # line. Printing the requested window instead asserted a comparison that did not
  # happen, in the one line the review-enforcer trusts enough to certify a bypass
  # (#1003).
  local main_union_n=0
  if [ -f "$main_prov" ]; then main_union_n="$(count_lines "$main_prov")"; fi
  local run_word="runs"
  if [ "$main_union_n" = "1" ]; then run_word="run"; fi
  printf 'main compared (union of %s %s of %s): %s\n' "$main_union_n" "$run_word" "$lane" "$(provenance_ids "$main_prov")"
  printf 'PR failing: %s | main failing: %s | blocked by the decision: 0\n' "$pr_count" "$main_count"
  printf '%s\n' "$analyzed"
  # THE AUDITABLE SET, not just its verdict (#3467 item 2): the decision only
  # reaches this point with a zero residual, so every failure the PR carries IS
  # exempt-with-evidence, and recording the set is what lets a reviewer reach
  # `blocked: 0` from the comment instead of taking it on faith.
  evidence_list "the $pr_count failure(s) this PR carries — all EXEMPT (measured on main with a matching signature and no worse rate)" \
    "$(cat "$pr_fails")" "(none — this PR carries no failure of its own)"
  evidence_list "main baseline: $main_count pre-existing failure(s), for comparison" \
    "$(cat "$main_fails")" "(none)"
  # THE VISIBLE EXEMPTIONS (#3756). An exemption that exists only as an absence
  # IS the fail-open defect, so every exempt id is printed with BOTH rates and
  # the reason the decision permitted it.
  evidence_list 'EXEMPT by the decision (visible — both rates, matching signature)' \
    "$exempt_raw" "(none — no failure was exempted)"
  # The PRE-rerun residual, when the flake path ran. Labelled for what it IS: it
  # is NOT the diff of the two sets above (those are POST-rerun), so it must not
  # be presented under a "must be empty" heading.
  if [ -n "$unique_raw" ]; then
    evidence_list 'residual BEFORE the flake re-run — reclassified as flaky, NOT new failures' \
      "$unique_raw" "(none)"
  fi
  evidence_list 'final residual (the exemption decision: BLOCKED ∪ UNATTRIBUTABLE) — must be empty' \
    "$final_unique_raw" "(empty — the decision exempts every failure this PR carries)"
  printf '\nLists show at most %s entries of %s chars; the full sets are reproducible from the run ids above.\n' \
    "$EVIDENCE_ENTRIES" "$EVIDENCE_WIDTH"
  printf '%s\n' "$flake_line"
}

# attribute_residual <residual-file> <main-fails-file> — name WHY each residual
# failure is not in main's baseline. This IMPROVES the diagnosis of a refusal;
# it must never NARROW the refusal. Every caller blocks on a non-empty residual
# regardless of the label here, and there is deliberately NO waiver label
# (B1 asked for lane-matched attribution sufficient to CERTIFY; the answer is
# no — a gate cannot adjudicate causation, and accepting it once lets the next
# genuinely-new failure in that file ride the same argument).
#
#   measured on this lane, not present on main
#       main's baseline carries a failure in the SAME test file, so the lane is
#       demonstrably measuring that file and does not show this test red.
#   not measurable on this lane
#       main's baseline carries NO failure in that file. A FAILURE-ONLY baseline
#       cannot tell "green on main" from "never run on main", so absence is NOT
#       evidence of novelty — the rail must not call it "unique to this PR".
#       (B1: CI's docker lane reproduces ZERO occurrences of the embedded lane's
#       redislite/GRAPH.COPY race while the embedded lane reproduces it — the old
#       wording asserted uniqueness with nothing to compare against.)
attribute_residual() {
  local residual="$1" mainfails="$2" nodeid file main_files=""
  [ -s "$mainfails" ] && main_files="$(sed 's/::.*//' "$mainfails" | sort -u)"
  while IFS= read -r nodeid; do
    [ -n "$nodeid" ] || continue
    file="${nodeid%%::*}"
    if [ -n "$main_files" ] && grep -qxF -- "$file" <<<"$main_files"; then
      printf '   %s\n      -> measured on this lane, not present on main\n' "$nodeid"
    else
      printf '   %s\n      -> not measurable on this lane: main carries no failure in %s, so absence is NOT evidence of novelty\n' "$nodeid" "$file"
    fi
  done < "$residual"
}

main() {
  local PR="" MAIN_RUNS="${MAIN_RUNS:-10}" REPO="" DRY_RUN=0 NO_RERUN=0
  local WORKFLOW="${CI_FAILURE_SET_WORKFLOW:-python-ci.yml}" ANY_WORKFLOW=0
  local PRINT_BOUNDS=0 PRINT_BOUNDS_RUN=""
  # Numeric operator knobs are validated BEFORE anything reads them: a value that
  # is not a positive integer makes the `-ge`/`-lt` guards return 2 and silently
  # skip, which disables the gate rather than failing it.
  validate_timing_knobs || exit 2
  # NO GLOBAL CEILING. An explicit --rerun-timeout (or $RERUN_TIMEOUT) is a
  # verbatim override; otherwise the bound is DERIVED from a GREEN population's
  # observed shard durations at the re-run site, and the fail-safe applies only
  # when the derivation is unavailable — never as a small default.
  RERUN_TIMEOUT="${RERUN_TIMEOUT:-}"
  RERUN_TIMEOUT_EXPLICIT=0
  [ -n "$RERUN_TIMEOUT" ] && RERUN_TIMEOUT_EXPLICIT=1
  RERUN_TIMEOUT_SOURCE=""
  [ "$RERUN_TIMEOUT_EXPLICIT" -eq 1 ] && RERUN_TIMEOUT_SOURCE="explicit --rerun-timeout"
  local MERGE_ARGS=() MERGE_METHOD_SET=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --main-runs) MAIN_RUNS="${2:-}"; shift 2 ;;
      --repo) REPO="${2:-}"; shift 2 ;;
      --workflow) WORKFLOW="${2:-}"; shift 2 ;;
      --any-workflow) ANY_WORKFLOW=1; shift ;;
      --rerun-timeout) RERUN_TIMEOUT="${2:-}"; RERUN_TIMEOUT_EXPLICIT=1; RERUN_TIMEOUT_SOURCE="explicit --rerun-timeout"; shift 2 ;;
      --no-rerun) NO_RERUN=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      # Make the DERIVATION visible on demand: the re-run bound is not a round
      # number, and an operator must be able to see where it came from without
      # reading the source. Handled AFTER the loop so `--repo` may appear on
      # either side of it; the run id is OPTIONAL and must not swallow a flag.
      --print-bounds)
        PRINT_BOUNDS=1
        if [ $# -ge 2 ] && is_run_id "${2:-}"; then PRINT_BOUNDS_RUN="${2:-}"; shift; fi
        shift ;;
      --help|-h) usage; exit 0 ;;
      --) shift; while [ $# -gt 0 ]; do
            case "$1" in --merge|--rebase|--squash) MERGE_METHOD_SET=1 ;; esac
            MERGE_ARGS+=("$1"); shift
          done ;;
      --admin|--admin=true) shift ;;  # always added by this script
      -*) case "$1" in --merge|--rebase|--squash) MERGE_METHOD_SET=1 ;; esac
          MERGE_ARGS+=("$1"); shift ;;
      *)
        if [ -z "$PR" ]; then PR="$1"; else say_err "admin-merge: unexpected argument '$1'"; exit 2; fi
        shift ;;
    esac
  done

  # An explicit --rerun-timeout is an operator-supplied CEILING, checked here (not
  # in validate_timing_knobs, which runs before the flags are parsed) for two
  # faults:
  #   * a LEADING ZERO (`0100`) — bash ARITHMETIC reads it as OCTAL while the
  #     `[ "$waited" -lt "$RERUN_TIMEOUT" ]` loop condition reads it as DECIMAL,
  #     so the same spelling would mean two different bounds;
  #   * not a POSITIVE INTEGER — `[ "$waited" -lt "$RERUN_TIMEOUT" ]` returns 2, the
  #     loop body NEVER RUNS and the function falls through to the bound with ZERO
  #     polls, printing a verdict about a run it never looked at.
  # There is no ordering to enforce against a stall window: they are the same
  # derived bound, so an explicit cap is always coherent (see wait_for_run).
  if [ "$RERUN_TIMEOUT_EXPLICIT" -eq 1 ]; then
    if counter_has_leading_zero "$RERUN_TIMEOUT"; then
      say_err "admin-merge: ✗ refusing --rerun-timeout '${RERUN_TIMEOUT}' — a LEADING ZERO is ambiguous: bash"
      say_err "   ARITHMETIC reads it as OCTAL while the 'test' comparisons that bound the wait read it as"
      say_err "   DECIMAL, so the same spelling would mean two different bounds."
      say_err "   Write it without the leading zero (e.g. '100', not '0100')."
      exit 2
    fi
    if ! counter_is_positive "$RERUN_TIMEOUT"; then
      say_err "admin-merge: ✗ refusing --rerun-timeout '${RERUN_TIMEOUT}' — it must be a POSITIVE integer number of seconds."
      say_err "   A non-numeric or zero bound makes the re-run wait's comparison error out, so the"
      say_err "   loop runs ZERO polls and the rail reports a verdict about a run it never looked at."
      say_err "   Omit the flag to derive the bound per shard."
      exit 2
    fi
    if counter_exceeds_max "$RERUN_TIMEOUT" "$TIMING_KNOB_MAX"; then
      say_err "admin-merge: ✗ refusing --rerun-timeout '${RERUN_TIMEOUT}' — beyond the usable range"
      say_err "   (max ${TIMING_KNOB_MAX}s). An all-digit value past the shell's integer range makes the"
      say_err "   wait's comparison error out, which SKIPS the loop instead of bounding it."
      exit 2
    fi
  fi

  # The derivation report is an inspection: print and exit BEFORE any PR is
  # required, so `--print-bounds <run-id>` works on a bare invocation.
  if [ "$PRINT_BOUNDS" -eq 1 ]; then print_bounds "$PRINT_BOUNDS_RUN"; exit 0; fi

  # gh REQUIRES a merge method when it is not interactive. Default it so an
  # omission cannot leave the evidence marker standing over an unmerged PR. An
  # explicit --merge/--rebase/--squash wins and is not doubled (the caller's
  # flags keep their exact order/position).
  if [ "$MERGE_METHOD_SET" -eq 0 ]; then
    MERGE_ARGS=(--squash ${MERGE_ARGS[@]+"${MERGE_ARGS[@]}"})
  fi

  [ -n "$PR" ] || { say_err "admin-merge: a PR number is required"; usage >&2; exit 2; }
  case "$PR" in *[!0-9]*) say_err "admin-merge: PR must be numeric (got '$PR')"; exit 2 ;; esac
  [ -x "$CFS" ] || [ -f "$CFS" ] || { say_err "admin-merge: parser not found at $CFS"; exit 1; }
  BASH="${BASH:-bash}"

  local repo_args=()
  [ -n "$REPO" ] && repo_args=(--repo "$REPO")

  # The lane both sides are read from. An unfiltered main window is how the
  # baseline reads EMPTY while main is red (the bogus zero) — so the filter is
  # the default and the opt-out is explicit.
  local wf_args=() lane="$WORKFLOW"
  if [ "$ANY_WORKFLOW" -eq 1 ] || [ -z "$WORKFLOW" ]; then
    wf_args=(--any-workflow); lane="any workflow"
  else
    wf_args=(--workflow "$WORKFLOW")
  fi

  # P1-2 (fresh review): `local TMP` + a trap that READS it is broken — bash runs
  # the EXIT trap after `main` returns, when the local is already out of scope, so
  # under `set -u` the trap aborted with "TMP: unbound variable" and cleanup never
  # ran (729 stale `admin-merge.*` directories, 21 MB, on the reviewing machine).
  # Assign the FILE-SCOPE `TMP` declared below and expand it at trap-set time.
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/admin-merge.XXXXXX")"
  trap 'rm -rf "${TMP:-}"' EXIT

  local head
  # shellcheck disable=SC2086
  head="$(resolve_head "$PR" ${repo_args[@]+"${repo_args[@]}"})"
  [ -n "$head" ] || { say_err "admin-merge: ✗ could not resolve the head of PR #$PR"; exit 1; }
  info "admin-merge: PR #$PR head $head"

  # ── 0. A DRAFT CANNOT BE MERGED — refuse EARLY, by name ──────────────────
  # gh refuses a draft with "Pull Request is still a draft", and commit-workflow
  # opens drafts deliberately, so this is a systematic collision, not an edge
  # case. Refuse BEFORE any CI work and with the SPECIFIC reason, rather than
  # letting it surface as a generic merge failure after the evidence marker was
  # posted. The rail does NOT silently ready the PR: a draft is a deliberate
  # review checkpoint, and clearing it is the author's act, not the rail's.
  local is_draft
  # shellcheck disable=SC2086
  is_draft="$(resolve_draft "$PR" ${repo_args[@]+"${repo_args[@]}"})"
  if [ "$is_draft" = "true" ]; then
    say_err "admin-merge: ✗ BLOCK — PR #$PR is a DRAFT, and gh refuses to merge a draft"
    say_err "   (\"Pull Request is still a draft\"). This is NOT a CI-failure verdict and NOT"
    say_err "   a merge failure: no comparison was run and no evidence was posted. A draft is a"
    say_err "   deliberate review checkpoint, so clearing it is the author's act, not the rail's."
    say_err "   Mark the PR ready and re-run:  gh pr ready $PR"
    exit 1
  fi

  # ── 1. the PR's failing set, with provenance for the flake re-run ────────
  # Selected by COMMIT, not by PR: the analyzed set must be provably the SHA the
  # evidence marker names. `--pr` would re-resolve the head internally, so a push
  # between the two resolutions could analyze one SHA and certify another (#P1).
  local pr_status=0
  run_failure_set --commit-rows "$head" ${repo_args[@]+"${repo_args[@]}"} ${wf_args[@]+"${wf_args[@]}"} \
    --provenance "$TMP/pr-runs.txt" --runs-report "$TMP/pr-report.txt" --per-run "$TMP/pr-per-run.txt" \
    > "$TMP/pr-rows.txt" || pr_status=$?
  if [ "$pr_status" -ne 0 ]; then
    say_err "admin-merge: ✗ BLOCK — could not extract the PR's failing set (parser exit $pr_status)."
    say_err "   Refusing to certify a comparison computed over an unreadable set."
    exit 1
  fi
  # The id set the evidence and the re-run loop use, derived from the ROWS the
  # decision consumes, so the two can never disagree about which ids exist.
  cut -f1 "$TMP/pr-rows.txt" 2>/dev/null | sort -u > "$TMP/pr-fails.txt"

  # ── 1b. THE HEAD MUST HAVE BEEN TESTED (review P0 #3) ────────────────────
  # `examined=0` is NOT the signal — a green lane legitimately has no failing
  # runs. The signal is `tested=0` (no run actually exercised this revision) or
  # `pending>0` (something has not finished). Either way an empty failing set
  # proves nothing, so the rail must not read it as "no unique failures".
  local pr_completed pr_tested pr_pending
  pr_completed="$(report_value "$TMP/pr-report.txt" completed)"
  pr_tested="$(report_value "$TMP/pr-report.txt" tested)"
  pr_pending="$(report_value "$TMP/pr-report.txt" pending)"

  # "Not proven finished" is not "finished": `! counter_is_zero` blocks on an
  # UNREADABLE `pending` too, not only on a positive one. A bare `-gt 0` skipped
  # the body on a non-numeric value (`[ n/a: integer expression expected`, exit
  # 2) and the rail merged while the lane might still be running — the #3420
  # ratchet that precondition 1 exists to stop (VGATE cycle 2, #1003).
  if ! counter_is_zero "$pr_pending"; then
    say_err "admin-merge: ✗ BLOCK — precondition unmet: run still in_progress — no classification attempted."
    say_err "   The test lane has NOT finished for head $head:"
    if counter_is_positive "$pr_pending"; then
      say_err "   $pr_pending run(s) still queued/in progress (lane: $lane)."
    else
      say_err "   the run report's 'pending' counter is unreadable ('${pr_pending:-}'), so the rail"
      say_err "   cannot show the lane finished (lane: $lane)."
    fi
    # ── WHICH WAIT IS THIS? BOTH waits must read differently (B7). One
    # `gh run view` call, ONLY here, on the pending run. This is the
    # LANE-TERMINAL PRECONDITION, not the re-run wait: the re-run wait has not
    # started, and its derived bound does not exist yet. So this claims NEITHER a
    # WAIT NOR a STALL — a stall is a claim that a run exceeded its own bound, and
    # no bound has been derived here. A remote run exposes no within-job activity
    # signal anyway (`updatedAt` is frozen for the whole of a single long step),
    # so the old "frozen clock ⇒ STALLED" reading here was the same false claim
    # this rail removed from wait_for_run. The parser COUNTS pending runs but does
    # not record their ids (a pending run has no conclusion), so the id is looked
    # up here; this is the failure path, so the extra list costs nothing.
    if counter_is_positive "$pr_pending"; then
      local pend_id="" vline="" vstatus=""
      pend_id="$(pending_run_id "$head")"
      if [ -n "$pend_id" ]; then
        # shellcheck disable=SC2086
        vline="$($GH run view "$pend_id" ${repo_args[@]+"${repo_args[@]}"} --json status --jq '.status' 2>/dev/null || true)"
        vstatus="$vline"
        if [ -n "$vstatus" ] && [ "$vstatus" != "completed" ]; then
          say_err "   the lane run $pend_id reports status=$vstatus — still running. A running job is not a failure, and this is NOT a stall claim: the re-run bound has not been DERIVED yet, so there is no bound for this run to have exceeded. This is the LANE-TERMINAL PRECONDITION, not the re-run wait."
        elif [ "$vstatus" = "completed" ]; then
          say_err "   the lane run $pend_id now reports status=completed — re-run the rail to re-list the lane."
        else
          say_err "   the lane run $pend_id could not be read (its status was not obtained) — check gh auth/network, then re-run. This is NOT a stall: a stall is a claim about a run we watched."
        fi
      fi
    fi
    say_err "   An unfinished lane yields an empty failing set, which proves nothing."
    say_err "   Wait for CI to complete, then re-run the rail."
    say_err "   This is the LANE-TERMINAL PRECONDITION, which gates BEFORE any comparison:"
    say_err "   --rerun-timeout never started and would not change this exit. The re-run"
    say_err "   wait is a DIFFERENT wait and names itself differently when it fires."
    exit 1
  fi
  # NOT `completed`: a `cancelled`/`skipped` run is terminal but exercised
  # nothing, so it cannot certify the revision (review P1, cycle 2). A parser too
  # old to emit `tested` therefore BLOCKS — fail closed, never vacuous. The
  # counter is VALIDATED, not trusted: a non-numeric `tested` made `[ -eq ]`
  # error and skip this body, which is a fail-open (VGATE, #1003).
  if ! counter_is_positive "$pr_tested"; then
    say_err "admin-merge: ✗ BLOCK — no run of the lane actually TESTED head $head (lane: $lane)."
    say_err "   completed=${pr_completed:-0} run(s), of which tested=${pr_tested:-0}."
    say_err "   A cancelled or skipped run is finished but exercised nothing, so an"
    say_err "   empty failing set proves nothing about this revision."
    # "The lane ran but exercised nothing" and "this lane does not run on pull
    # requests at all" are different faults with different fixes. On a repo that
    # splits its lanes by trigger the second is the common one, and waiting for
    # CI cannot help — the lane must be changed (#1003).
    # "No runs at all" is completed AND pending BOTH zero — NOT `examined=0`,
    # which is equally true of a run that finished `cancelled`/`skipped`. Those
    # are the "ran but proved nothing" case the lines above already describe, and
    # calling them a main-only lane is simply false (VGATE, #1003).
    if counter_is_zero "$pr_completed" && counter_is_zero "$pr_pending"; then
      say_err "   The lane '$lane' has NO runs for this head at all — which is what a"
      say_err "   MAIN-ONLY lane looks like. If this repo splits its lanes by trigger,"
      say_err "   pick a lane that runs on pull requests."
    fi
    say_err "   Confirm the lane is the right one (--workflow) and that CI ran for this head."
    exit 1
  fi
  # ── 1c. EVERY FAILING RUN MUST BE ATTRIBUTED (cycle-3 review) ────────────
  # `examined` counts the lane's failing runs; `extracted` counts those whose log
  # yielded at least one `FAILED <nodeid>` line. A failing run that contributes
  # NOTHING leaves the residual UNKNOWN while the certificate would print
  # `PR failing: 0` for a lane that is RED — a FALSE certificate, the one severity
  # this rail exists to prevent (the cycle-3 repro: a head run failing with
  # `ImportError: no module named y` certified as zero-residual, and the rail
  # merged). A gate whose output authorises a bypass fails CLOSED here.
  #
  # ORDER MATTERS: this sits AFTER the not-finished / not-tested diagnostics. Run
  # first, an absent or unreadable report made THIS the reported reason, masking the
  # real one — and the suite pins those messages (cycle-3, caught by CI).
  #
  # Deliberately NOT applied to the MAIN side: an unattributed run there
  # under-reports the BASELINE, which can only make the residual look larger — a
  # false block, whose designed remedy is the retry path. The false-certificate
  # direction is the PR side.
  local pr_examined pr_extracted
  pr_examined="$(report_value "$TMP/pr-report.txt" examined)"
  pr_extracted="$(report_value "$TMP/pr-report.txt" extracted)"
  if ! counter_is_number "$pr_examined" || ! counter_is_number "$pr_extracted"; then
    say_err "⛔ admin-merge: BLOCKED — the lane run report carries unreadable"
    say_err "   examined/extracted counters (examined='${pr_examined:-}', extracted='${pr_extracted:-}'),"
    say_err "   so the failing set cannot be shown to be complete."
    exit 1
  fi
  if [ "$pr_extracted" -lt "$pr_examined" ]; then
    say_err "⛔ admin-merge: BLOCKED — $((pr_examined - pr_extracted)) of $pr_examined failing PR run(s)"
    say_err "   yielded NO parseable 'FAILED <nodeid>' line, so their failures are NOT in the"
    say_err "   set and 'blocked by the decision: 0' would be a false certificate (lane: $lane)."
    say_err "   Either the run failed outside the test step (fix it), or the log format moved"
    say_err "   and the parser needs updating. This is a refusal, not a comparison."
    exit 1
  fi

  info "admin-merge: lane finished for $head (${pr_tested} tested of ${pr_completed} completed run(s))"

  # ── 2. main's baseline: the RATE table and the SIGNATURE table ───────────
  # Both halves of ONE measurement. The rate table alone is not enough: an empty
  # `main_signatures` makes the decision's subset rule fail CLOSED and no failure
  # is ever exempt. Neither side is drawn from the repo being merged.
  local main_status=0
  run_failure_set --main-union-rates "$MAIN_RUNS" ${repo_args[@]+"${repo_args[@]}"} ${wf_args[@]+"${wf_args[@]}"} \
    --exclude "$head" --provenance "$TMP/main-runs.txt" --runs-report "$TMP/main-report.txt" \
    > "$TMP/main-rates.txt" || main_status=$?
  if [ "$main_status" -ne 0 ]; then
    say_err "admin-merge: ✗ BLOCK — could not extract main's rate table (parser exit $main_status)."
    say_err "   Refusing to certify a comparison computed over an unreadable baseline."
    exit 1
  fi
  local main_sig_status=0
  run_failure_set --main-union-signatures "$MAIN_RUNS" ${repo_args[@]+"${repo_args[@]}"} ${wf_args[@]+"${wf_args[@]}"} \
    --exclude "$head" \
    > "$TMP/main-signatures.txt" || main_sig_status=$?
  if [ "$main_sig_status" -ne 0 ]; then
    say_err "admin-merge: ✗ BLOCK — could not extract main's signature table (parser exit $main_sig_status)."
    say_err "   Without it every signature check fails closed; that is a refusal, not a green."
    exit 1
  fi
  # main's failing UNION — the baseline list the evidence shows — IS the rate
  # table's id column. One measurement, one source, no second pass to disagree.
  cut -f1 "$TMP/main-rates.txt" 2>/dev/null | sort -u > "$TMP/main-fails.txt"

  # ── 2b. is the selected lane a BASELINE at all? ───────────────────────────
  # A rail certificate claims "this PR carries no failure that is not already red
  # on main". That claim IS a comparison, so it needs a baseline. A lane that
  # never ran on main gives an empty baseline, and an empty baseline absorbs
  # nothing: every failure the PR carries reads as new, PRE-EXISTING ones
  # included, and a safe merge is refused for the wrong reason. An over-blocking
  # gate is a broken gate too — but the remedy is a REAL baseline, not a
  # certificate backed by nothing, so this BLOCKS and names the way to one.
  #
  # The signal is `tested`, NOT `examined`, and deliberately the SAME one the
  # head-side check uses: `examined` counts only FAILING runs (a green lane
  # legitimately has examined=0), so it cannot tell a green baseline from a
  # missing one. `tested` counts every run that actually exercised the revision,
  # passing or failing — exactly the question here.
  #
  # This does not ride on the vacuous case below: "green on both sides" is an
  # OUTCOME of a comparison that happened, "never tested main" is a
  # MISCONFIGURATION in which none did, and a reader must tell them apart. Repos
  # that split their lanes by trigger (a pull_request-only lane and a push-only
  # lane — this one does) have no single --workflow spanning both sides, which is
  # what --any-workflow is for (#1003).
  local main_tested main_completed
  main_tested="$(report_value "$TMP/main-report.txt" tested)"
  main_completed="$(report_value "$TMP/main-report.txt" completed)"
  if ! counter_is_positive "$main_tested"; then
    say_err "admin-merge: ✗ BLOCK — the lane '$lane' never TESTED main, so there is no baseline."
    say_err "   main: completed=${main_completed:-0} run(s), of which tested=${main_tested:-0}."
    say_err "   A rail certificate claims \"this PR carries no failure that is not already red"
    say_err "   on main\". That claim IS a comparison. With nothing on main to compare against,"
    say_err "   every failure this PR carries reads as new — PRE-EXISTING ones included — and a"
    say_err "   safe merge is refused for the wrong reason."
    say_err "   A repo can split its lanes by TRIGGER (a PR-only lane and a main-only lane), and"
    say_err "   then no single --workflow spans both sides. Compare against every lane on main"
    say_err "   instead: add --any-workflow."
    exit 1
  fi

  # ── 3. THE EXEMPTION DECISION (one implementation, two consumers) ────────
  # No `comm -23`: membership in main's sample is not evidence that a failure
  # pre-exists, and the more main flakes the less the subtraction checks. The
  # decision's own exit cannot distinguish a GATED verdict from a crash, so
  # `run_exemption_decision` returns 0 for a VERDICT and 1 for a broken gate —
  # and a broken gate BLOCKS.
  local dec_rc=0
  run_exemption_decision "$TMP/pr-rows.txt" "$TMP/main-rates.txt" "$TMP/main-signatures.txt" \
    "$TMP/pr-per-run.txt" "$TMP/unique" || dec_rc=$?
  if [ "$dec_rc" -ne 0 ]; then
    say_err "admin-merge: ✗ BLOCK — the exemption decision could not run. No merge."
    exit 1
  fi
  residual_of "$TMP/unique" "$TMP/unique.txt"
  local unique_before
  unique_before="$(count_lines "$TMP/unique.txt")"

  local flake_line="Flake classification: none needed (nothing blocked before the re-run)"
  local rerun_residual=0

  if [ "$unique_before" -gt 0 ]; then
    info "admin-merge: $unique_before failure(s) are blocked by the decision — re-run classification:"
    sed 's/^/   /' "$TMP/unique.txt"
    if [ "$NO_RERUN" -eq 1 ]; then
      say_err "admin-merge: ✗ BLOCK — failures are blocked by the decision and --no-rerun given. No merge."
      # §37 (main): WHY each residual could not be attributed to this PR — the
      # FILE-level diagnosis. Complementary to the decision's id-level reason
      # lines below, not a replacement: the decision says WHAT it decided and on
      # what evidence; this says why the residual's file was not attributable.
      # BOTH block; no label here clears a failure.
      attribute_residual "$TMP/unique.txt" "$TMP/main-fails.txt" >&2
      exit 1
    fi
    # `--dry-run` MUTATES NOTHING — including CI. Re-running failed jobs before
    # the DRY_RUN branch would make a documented no-op re-run a caller's CI
    # (review P2, cycle 2). Report the decision instead of performing it.
    if [ "$DRY_RUN" -eq 1 ]; then
      info "admin-merge: (dry-run) a real run would re-run the failing job(s) of this head once and re-classify them."
      info "admin-merge: (dry-run) --dry-run performs no CI re-run, posts no comment and merges nothing."
      info "admin-merge: (dry-run) decision: BLOCK unless the residual clears on retry. No merge."
      exit 0
    fi
    # Re-run every failing run of the PR head ONCE. A test that passes on retry
    # is order/timing flaky, not new — the #3469 shape (a sibling pair that
    # trips alternately on main) must not hard-block a safe merge.
    local run_line run_id wait_rc
    while IFS= read -r run_line; do
      [ -n "$run_line" ] || continue
      run_id="${run_line##*:}"
      # DERIVE BEFORE THE RE-RUN. At this point the run is terminal (`pr-runs.txt`
      # carries failing runs), so EVERY shard has a completed sample and the run
      # bound is the slow shard's own 2 x max. Deriving AFTER the re-run would
      # see the just-re-started shard as unfinished with no sample of its own —
      # exactly the shard whose bound matters — and substitute a floor/fail-safe
      # for the one measurement that was available a moment earlier.
      if [ "$RERUN_TIMEOUT_EXPLICIT" -eq 0 ]; then
        derive_rerun_timeout "$run_id"
        RERUN_TIMEOUT="$DERIVED_RERUN_TIMEOUT"
        RERUN_TIMEOUT_SOURCE="$DERIVED_RERUN_SOURCE"
      fi
      info "admin-merge: ↻ re-running failed jobs of run $run_id"
      # shellcheck disable=SC2086
      if ! $GH run rerun "$run_id" --failed ${repo_args[@]+"${repo_args[@]}"} >/dev/null 2>&1; then
        say_err "admin-merge: ✗ BLOCK — could not re-run $run_id (gh error). No merge."
        exit 1
      fi
      wait_for_run "$run_id"; wait_rc=$?
      if [ "$wait_rc" -eq 1 ]; then
        say_err "admin-merge: ✗ BLOCK — run $run_id STALLED: still non-completed at its DERIVED per-shard bound — ${RERUN_TIMEOUT_SOURCE}. A REMOTE run exposes no within-job activity signal (updatedAt advances only on job/step transitions, so one long step freezes it for the whole job), so exceeding the run's own green-derived bound is the only honest wedge signal: this run is either wedged or pathologically slower than its entire green population. No merge."
        exit 1
      fi
      if [ "$wait_rc" -eq 3 ]; then
        say_err "admin-merge: ✗ BLOCK — run $run_id UNOBSERVABLE: gh could not be read for the whole bound (${RERUN_TIMEOUT}s). This is NOT a stall — a stall is a claim about a run we watched, and this rail never saw the field. Remedy differs: check gh auth/network, then re-run. No merge."
        exit 1
      fi
      if [ "$wait_rc" -ne 0 ]; then
        say_err "admin-merge: ✗ BLOCK — run $run_id still RUNNING at the ${RERUN_TIMEOUT}s ceiling — ${RERUN_TIMEOUT_SOURCE}. Not a stall — this is an operator cap that was reached, not a claim that the run is wedged. No merge."
        exit 1
      fi
    done < "$TMP/pr-runs.txt"

    # The branch must not have moved during the re-run — evidence is bound to a
    # SHA, and a push invalidates it.
    local head_after
    # shellcheck disable=SC2086
    head_after="$(resolve_head "$PR" ${repo_args[@]+"${repo_args[@]}"})"
    if [ "$head_after" != "$head" ]; then
      say_err "admin-merge: ✗ BLOCK — head moved during re-run ($head → $head_after). Re-run the rail."
      exit 1
    fi

    local pr_status2=0
    run_failure_set --commit-rows "$head" ${repo_args[@]+"${repo_args[@]}"} ${wf_args[@]+"${wf_args[@]}"} \
      --runs-report "$TMP/pr-report2.txt" --per-run "$TMP/pr-per-run2.txt" \
      > "$TMP/pr-rows2.txt" || pr_status2=$?
    [ "$pr_status2" -eq 0 ] || { say_err "admin-merge: ✗ BLOCK — PR failing set unreadable after re-run"; exit 1; }
    cut -f1 "$TMP/pr-rows2.txt" 2>/dev/null | sort -u > "$TMP/pr-fails2.txt"
    # THE SECOND DOOR (#3756): the post-rerun verdict is the DECISION again, not a
    # second subtraction. A swap touching only the first would leave this verdict
    # presence-based, so a failure excused on the first pass would be excused
    # identically here.
    #
    # E5, DOOR 3 — the identity that MOVED. B7 measured it on #3749: the SAME
    # head's SAME run id (35221282837) yielded DIFFERENT failure ids when sampled
    # before and after the re-run. A single per-collection sample cannot see that,
    # so the rotation observation is the UNION of every sample of THIS head — the
    # head is provably unmoved (`head_after == head` above), so the samples are
    # two observations of one revision, not a baseline drawn from a second tree.
    # Without this the moved id is read as "unique to this PR" (a wrong reason,
    # and a permanent one), or — when main also measures the new id — as EXEMPT
    # AND SILENT, which is the fail-open direction B7's two cycles produced.
    # With it the class is red across runs with a MOVING id, which
    # `detect_rotating_identity` classifies UNATTRIBUTABLE: never PR-unique,
    # never exempt, and therefore never a merge.
    cat "$TMP/pr-per-run.txt" "$TMP/pr-per-run2.txt" > "$TMP/pr-rotation.txt"
    local dec2_rc=0
    run_exemption_decision "$TMP/pr-rows2.txt" "$TMP/main-rates.txt" "$TMP/main-signatures.txt" \
      "$TMP/pr-rotation.txt" "$TMP/unique2" || dec2_rc=$?
    if [ "$dec2_rc" -ne 0 ]; then
      say_err "admin-merge: ✗ BLOCK — the exemption decision could not run after the re-run. No merge."
      exit 1
    fi
    residual_of "$TMP/unique2" "$TMP/unique2.txt"
    rerun_residual="$(count_lines "$TMP/unique2.txt")"

    if [ "$rerun_residual" -gt 0 ]; then
      say_err "admin-merge: ✗ BLOCK — $rerun_residual failure(s) SURVIVED the re-run:"
      # §33 (#1147): the REASON, not just the node id. An UNATTRIBUTABLE id (a rotating identity,
      # or one with no main-side measurement) is created with `blocked=True`, so its
      # verdict line is a `BLOCK` line whose reason names the class — and a refusal
      # that printed ONLY the node id would read as an ordinary "unique to this PR",
      # leaving the E5 class unreported. Never exempt-and-SILENT applies to the
      # refusal too.
      grep -v '^EXEMPT' "$TMP/unique2.lines" 2>/dev/null | sed 's/^/   /' >&2 \
        || sed 's/^/   /' "$TMP/unique2.txt" >&2
      # §37 (main): the FILE-level attribution. Complementary to the id-level
      # reason lines above — BOTH are printed, BOTH block. Printing only one of
      # them leaves either the E5 class or the file-level refusal unexplained.
      attribute_residual "$TMP/unique2.txt" "$TMP/main-fails.txt" >&2
      say_err "   The attribution above separates MEASURED-ABSENT (main's lane demonstrably"
      say_err "   measures this file and does not show this test red) from NOT-MEASURABLE"
      say_err "   (main's baseline carries no measurement of the file, so absence is NOT"
      say_err "   evidence of novelty). BOTH block; no label here clears a failure."
      say_err "   The exemption decision still refuses them — merge refused."
      exit 1
    fi
    cp "$TMP/pr-fails2.txt" "$TMP/pr-fails.txt"
    flake_line="Flake classification: $unique_before residual re-ran → all passed on retry (flaky, not new)"
    info "admin-merge: ✅ all $unique_before residual failure(s) passed on retry — flaky, not new"
  fi

  # ── 4. THE HEAD IS RE-RESOLVED IMMEDIATELY BEFORE THE EVIDENCE (review P1) ─
  # This check used to live only inside the flake branch, so the common clean
  # path resolved the head once, posted evidence for that SHA, and then merged
  # whatever the head was by then. A rebase/update-branch in that window merged
  # an unanalyzed head behind SHA-bound evidence. Now it runs unconditionally —
  # and GitHub is asked to enforce it too, via --match-head-commit below.
  local head_final
  # shellcheck disable=SC2086
  head_final="$(resolve_head "$PR" ${repo_args[@]+"${repo_args[@]}"})"
  if [ "$head_final" != "$head" ]; then
    say_err "admin-merge: ✗ BLOCK — head moved before the evidence was posted ($head → $head_final)."
    say_err "   The evidence would be bound to $head; re-run the rail for the new head."
    exit 1
  fi

  local pr_count main_count
  pr_count="$(count_lines "$TMP/pr-fails.txt")"
  main_count="$(count_lines "$TMP/main-fails.txt")"
  local analyzed
  analyzed="$(printf 'Failing runs examined: PR=%s main=%s (with parseable FAILED lines: PR=%s main=%s)' \
    "$(report_value "$TMP/pr-report.txt" examined)" "$(report_value "$TMP/main-report.txt" examined)" \
    "$(report_value "$TMP/pr-report.txt" extracted)" "$(report_value "$TMP/main-report.txt" extracted)")"
  [ -s "$TMP/pr-report2.txt" ] && analyzed="$(printf 'Failing runs examined: PR=%s main=%s (with parseable FAILED lines: PR=%s main=%s)' \
    "$(report_value "$TMP/pr-report2.txt" examined)" "$(report_value "$TMP/main-report.txt" examined)" \
    "$(report_value "$TMP/pr-report2.txt" extracted)" "$(report_value "$TMP/main-report.txt" extracted)")"
  # The lane's COMPLETION state is part of the evidence: it is the fact that
  # makes an empty failing set mean "tested and green" rather than "never ran".
  analyzed="$analyzed
Lane completion: PR completed=$(report_value "$TMP/pr-report.txt" completed) tested=$(report_value "$TMP/pr-report.txt" tested) pending=$(report_value "$TMP/pr-report.txt" pending) | main completed=$(report_value "$TMP/main-report.txt" completed) tested=$(report_value "$TMP/main-report.txt" tested) pending=$(report_value "$TMP/main-report.txt" pending)"

  # A vacuous comparison is STATED, never implied. Both sides empty is usually a
  # correct outcome (the lane is green on both sides) — but it is also exactly
  # what a WRONG lane selector looks like, so the two must be distinguishable by
  # a reader of the evidence. See the bogus-zero trap in ci-failure-set.sh.
  if [ "$pr_count" -eq 0 ] && [ "$main_count" -eq 0 ]; then
    analyzed="$analyzed
⚠️ vacuous comparison: no failing runs were observed on EITHER side, so nothing was actually compared. Correct when the lane is green on both sides — but if the lane selector is wrong (--workflow), this certifies nothing."
    info "admin-merge: ⚠️  vacuous comparison — no failing runs on either side; nothing was compared (lane: $lane)"
  fi

  info "admin-merge: PR failing: $pr_count | main failing: $main_count | blocked by the decision: 0"

  # The set the "must be empty" claim is actually ABOUT: after a flake re-run,
  # unique2.txt is the post-rerun residual (pr-fails2 vs main-fails), while
  # unique.txt is the PRE-rerun one. Showing the pre-rerun set under a "must be
  # empty" heading contradicts the displayed (post-rerun) sets. (VGATE round 2.)
  local final_unique="$TMP/unique.txt"
  if [ -f "$TMP/unique2.txt" ]; then final_unique="$TMP/unique2.txt"; fi
  # Post-rerun state wins when it exists: the evidence must describe the decision
  # that actually authorised the merge, not the pre-rerun one.
  local final_exempt="$TMP/unique.exempt"
  if [ -f "$TMP/unique2.verdict" ]; then final_exempt="$TMP/unique2.exempt"; fi
  build_evidence "$head" "$TMP/main-runs.txt" "$pr_count" "$main_count" \
    "$(cat "$TMP/unique.txt")" "$flake_line" "$analyzed" "$lane" \
    "$TMP/pr-fails.txt" "$TMP/main-fails.txt" "$(cat "$final_unique")" \
    "$(cat "$final_exempt" 2>/dev/null || true)" > "$TMP/evidence.md"

  if [ "$DRY_RUN" -eq 1 ]; then
    info "admin-merge: --dry-run — evidence that WOULD be posted:"
    cat "$TMP/evidence.md"
    info "admin-merge: (dry-run) no comment posted, no merge"
    exit 0
  fi

  # shellcheck disable=SC2086
  if ! $GH pr comment "$PR" ${repo_args[@]+"${repo_args[@]}"} --body-file "$TMP/evidence.md" >/dev/null; then
    say_err "admin-merge: ✗ could not post the evidence comment — refusing to merge without it"
    exit 1
  fi
  info "admin-merge: ✅ head-bound evidence posted (marker: admin-merge-safety: $head)"

  # shellcheck disable=SC2086
  # ORDER MATTERS. `--match-head-commit "$head"` is deliberately passed AFTER the caller's
  # passthrough args (MERGE_ARGS): gh takes the LAST occurrence of a scalar flag, so with
  # the old order a `-- --match-head-commit <other>` passthrough silently REBOUND the merge
  # to a head other than the one just certified, defeating the binding this comment claims
  # (cycle-3 review). Ours goes last so ours wins.
  #
  # THE EXIT STATUS IS CHECKED. `gh pr merge` requires a merge method when it is
  # not interactive; with none it printed that error and NO-OPed while this
  # function returned success — leaving "✅ head-bound evidence posted" standing
  # over an UNMERGED PR (B1 lost #3754/#3755 to exactly that). A merge that fails
  # must fail LOUD.
  local merge_status=0
  # shellcheck disable=SC2086
  $GH pr merge "$PR" --admin ${MERGE_ARGS[@]+"${MERGE_ARGS[@]}"} --match-head-commit "$head" ${repo_args[@]+"${repo_args[@]}"} \
    >"$TMP/merge.out" 2>"$TMP/merge.err" || merge_status=$?
  if [ "$merge_status" -ne 0 ]; then
    say_err "⛔ admin-merge: FAILED — the merge of PR #$PR did NOT happen (gh pr merge exit $merge_status)."
    say_err "   THE SUCCESS MARKER IS STANDING OVER AN UNMERGED PR. Read"
    say_err "     ✅ head-bound evidence posted (marker: admin-merge-safety: $head)"
    say_err "   as 'the EVIDENCE COMMENT was posted' — NOT as 'the PR merged'. The merge it was"
    say_err "   posted to authorize FAILED, so PR #$PR is NOT merged."
    if [ -s "$TMP/merge.err" ]; then
      say_err "   gh pr merge said:"
      sed 's/^/      /' "$TMP/merge.err" >&2
    fi
    if [ -s "$TMP/merge.out" ]; then
      say_err "   gh pr merge stdout:"
      sed 's/^/      /' "$TMP/merge.out" >&2
    fi
    # CORRECT THE MARKER. A posted marker must never be left standing over an
    # unmerged PR, so a head-bound RETRACTION is posted (best effort) stating that
    # the merge FAILED and the evidence above is not a successful merge. The
    # retraction is deliberately NOT a certificate — it carries no
    # `unique to this PR: 0` line — so the merge gate will not accept it in place
    # of the evidence.
    {
      printf '<!-- admin-merge-retraction: %s -->\n' "$head"
      printf '⚠️ RETRACTED — the admin merge of head `%s` FAILED and did NOT happen.\n\n' "$head"
      printf 'The evidence comment above (`admin-merge-safety: %s`) records that the safety\n' "$head"
      printf 'comparison passed and the evidence was posted. It does NOT mean this PR merged:\n'
      printf '`gh pr merge` exited %s after that marker was posted.\n\n' "$merge_status"
      if [ -s "$TMP/merge.err" ]; then
        printf 'gh pr merge said:\n\n'
        # Indented, never fenced: this body is machine-read too, and a fence is a
        # parser with state.
        sed 's/^/    /' "$TMP/merge.err"
        printf '\n'
      fi
      printf 'Re-run the rail once the cause is fixed; the evidence above is still head-bound to `%s`.\n' "$head"
    } > "$TMP/retraction.md"
    # shellcheck disable=SC2086
    if ! $GH pr comment "$PR" ${repo_args[@]+"${repo_args[@]}"} --body-file "$TMP/retraction.md" >/dev/null 2>&1; then
      say_err "   (could not post the retraction comment — the FAILED merge above still stands)"
    fi
    exit 1
  fi
  info "admin-merge: ✅ merged PR #$PR at $head"
}

main "$@"
