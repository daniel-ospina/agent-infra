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
#   pr-fails.txt   ← scripts/ci-failure-set.sh --pr <N>
#   main-fails.txt ← scripts/ci-failure-set.sh --main-union N
#   unique         ← scripts/ci-failure-set.sh --diff pr-fails.txt main-fails.txt
#   unique EMPTY            → post head-bound evidence, then merge
#   unique NON-EMPTY        → re-run the PR's failed jobs ONCE; anything that
#                             passes on retry is flaky, not new (recorded in the
#                             evidence). Residual unique still non-empty →
#                             BLOCK, print the list, exit non-zero, NO merge.
#
# TWO PRECONDITIONS THE FAILING SETS ALONE CANNOT EXPRESS:
#   1. THE HEAD MUST HAVE BEEN TESTED. The lane must have at least one COMPLETED
#      run for this head, and none still running. A queued run yields an EMPTY
#      failing set — indistinguishable from "green" — so without this gate the
#      rail certifies nothing and merges before CI finishes, and the fresh
#      failure lands after the merge. That is the #3420 ratchet this rail exists
#      to stop (review P0 #3).
#   2. THE HEAD MUST NOT MOVE. The marker binds ONE SHA. The head is re-resolved
#      immediately before the comment and again by GitHub via
#      `--match-head-commit`, so a rebase inside the window cannot land an
#      unanalyzed head behind SHA-bound evidence (review P1).
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
#   --no-rerun           skip the flake re-run classification (a non-empty
#                        unique set then blocks immediately)
#   --dry-run            compute + print the decision, post nothing, merge nothing
#   --repo owner/repo    repo for the gh calls
#   Extra flags (`--squash`, `--merge`, `--rebase`, `--delete-branch`, `--auto`,
#   …) are passed through to `gh pr merge` rather than hardcoded. `--admin` is
#   always added by this script; a caller-supplied `--admin` is dropped.
#
# Env seams (tests only):
#   ADMIN_MERGE_GH              the gh command (default: `gh`)
#   ADMIN_MERGE_FAILURE_SET_SH  the parser to use (default: ./ci-failure-set.sh)
#   ADMIN_MERGE_POLL_INTERVAL   seconds between re-run status polls (default 10)

set -uo pipefail

GH="${ADMIN_MERGE_GH:-gh}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFS="${ADMIN_MERGE_FAILURE_SET_SH:-$SELF_DIR/ci-failure-set.sh}"
POLL_INTERVAL="${ADMIN_MERGE_POLL_INTERVAL:-10}"

usage() { sed -n '1,50p' "$0" | sed -n 's/^# \{0,1\}//p'; }
say_err() { printf '%s\n' "$*" >&2; }
info() { printf '%s\n' "$*"; }

count_lines() { wc -l < "$1" | tr -d ' '; }

# report_value <report-file> <key> → the numeric value, or empty.
report_value() {
  [ -n "$1" ] && [ -r "$1" ] || { printf ''; return 0; }
  awk -F= -v k="$2" '$1 == k { print $2 }' "$1"
}

resolve_head() {
  local pr="$1"; shift
  # shellcheck disable=SC2086
  $GH pr view "$pr" "$@" --json headRefOid --jq .headRefOid 2>/dev/null
}

# run_failure_set <mode...> — invoke the shared parser, splitting its stdout
# into the set (stdout) while surfacing an EXTRACTION FAILURE as our own exit 1.
# An extraction error must never be read as "no unique failures" — that is the
# vacuous pass this rail exists to prevent.
run_failure_set() {
  # shellcheck disable=SC2086
  "$BASH" "$CFS" "$@"
}

# wait_for_run <run-id> — poll until the run is completed. Returns 1 on timeout.
wait_for_run() {
  local run_id="$1" waited=0 status
  while [ "$waited" -lt "$RERUN_TIMEOUT" ]; do
    status="$($GH run view "$run_id" --json status --jq .status 2>/dev/null || echo unknown)"
    [ "$status" = "completed" ] && return 0
    sleep "$POLL_INTERVAL"
    waited=$((waited + POLL_INTERVAL))
  done
  return 1
}

# build_evidence — the machine-readable comment. The marker binds the evidence
# to ONE head SHA: every push invalidates it, and the merge gate matches on it.
build_evidence() {
  local head="$1" main_prov="$2" pr_count="$3" main_count="$4"
  local unique_raw="$5" flake_line="$6" analyzed="$7" lane="$8"

  printf '<!-- admin-merge-safety: %s -->\n' "$head"
  printf 'PR head: %s\n' "$head"
  printf 'test lane: %s\n' "$lane"
  printf 'main compared (union of %s runs of %s): %s\n' "$MAIN_RUNS" "$lane" "$(tr '\n' ' ' < "$main_prov" | sed 's/ *$//' | tr ' ' ',' | sed 's/,,*/,/g' | sed 's/,$//')"
  printf 'PR failing: %s | main failing: %s | unique to this PR: 0\n' "$pr_count" "$main_count"
  printf '%s\n' "$analyzed"
  printf '<details><summary>raw `comm -23` output</summary>\n\n```\n%s\n```\n</details>\n' "${unique_raw:-}"
  printf '%s\n' "$flake_line"
}

main() {
  local PR="" MAIN_RUNS="${MAIN_RUNS:-10}" REPO="" DRY_RUN=0 NO_RERUN=0
  local WORKFLOW="${CI_FAILURE_SET_WORKFLOW:-python-ci.yml}" ANY_WORKFLOW=0
  RERUN_TIMEOUT="${RERUN_TIMEOUT:-1800}"
  local MERGE_ARGS=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --main-runs) MAIN_RUNS="${2:-}"; shift 2 ;;
      --repo) REPO="${2:-}"; shift 2 ;;
      --workflow) WORKFLOW="${2:-}"; shift 2 ;;
      --any-workflow) ANY_WORKFLOW=1; shift ;;
      --rerun-timeout) RERUN_TIMEOUT="${2:-}"; shift 2 ;;
      --no-rerun) NO_RERUN=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --help|-h) usage; exit 0 ;;
      --) shift; while [ $# -gt 0 ]; do MERGE_ARGS+=("$1"); shift; done ;;
      --admin|--admin=true) shift ;;  # always added by this script
      -*) MERGE_ARGS+=("$1"); shift ;;
      *)
        if [ -z "$PR" ]; then PR="$1"; else say_err "admin-merge: unexpected argument '$1'"; exit 2; fi
        shift ;;
    esac
  done

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

  local TMP
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/admin-merge.XXXXXX")"
  trap 'rm -rf "$TMP"' EXIT

  local head
  # shellcheck disable=SC2086
  head="$(resolve_head "$PR" ${repo_args[@]+"${repo_args[@]}"})"
  [ -n "$head" ] || { say_err "admin-merge: ✗ could not resolve the head of PR #$PR"; exit 1; }
  info "admin-merge: PR #$PR head $head"

  # ── 1. the PR's failing set, with provenance for the flake re-run ────────
  # Selected by COMMIT, not by PR: the analyzed set must be provably the SHA the
  # evidence marker names. `--pr` would re-resolve the head internally, so a push
  # between the two resolutions could analyze one SHA and certify another (#P1).
  local pr_status=0
  run_failure_set --commit "$head" ${repo_args[@]+"${repo_args[@]}"} ${wf_args[@]+"${wf_args[@]}"} \
    --provenance "$TMP/pr-runs.txt" --runs-report "$TMP/pr-report.txt" > "$TMP/pr-fails.txt" || pr_status=$?
  if [ "$pr_status" -ne 0 ]; then
    say_err "admin-merge: ✗ BLOCK — could not extract the PR's failing set (parser exit $pr_status)."
    say_err "   Refusing to certify a comparison computed over an unreadable set."
    exit 1
  fi

  # ── 1b. THE HEAD MUST HAVE BEEN TESTED (review P0 #3) ────────────────────
  # `examined=0` is NOT the signal — a green lane legitimately has no failing
  # runs. The signal is `completed=0` (nothing ever finished) or `pending>0`
  # (something has not). Either way an empty failing set proves nothing, so the
  # rail must not read it as "no unique failures".
  local pr_completed pr_pending
  pr_completed="$(report_value "$TMP/pr-report.txt" completed)"
  pr_pending="$(report_value "$TMP/pr-report.txt" pending)"
  if [ "${pr_pending:-0}" -gt 0 ]; then
    say_err "admin-merge: ✗ BLOCK — the test lane has NOT finished for head $head:"
    say_err "   $pr_pending run(s) still queued/in progress (lane: $lane)."
    say_err "   An unfinished lane yields an empty failing set, which proves nothing."
    say_err "   Wait for CI to complete, then re-run the rail."
    exit 1
  fi
  if [ "${pr_completed:-0}" -eq 0 ]; then
    say_err "admin-merge: ✗ BLOCK — no COMPLETED run of the lane exists for head $head (lane: $lane)."
    say_err "   Nothing about this revision was tested, so a comparison cannot certify anything."
    say_err "   Confirm the lane is the right one (--workflow) and that CI ran for this head."
    exit 1
  fi
  info "admin-merge: lane finished for $head ($pr_completed completed run(s))"

  # ── 2. main's baseline: the UNION over the last N runs ───────────────────
  local main_status=0
  run_failure_set --main-union "$MAIN_RUNS" ${repo_args[@]+"${repo_args[@]}"} ${wf_args[@]+"${wf_args[@]}"} \
    --exclude "$head" --provenance "$TMP/main-runs.txt" --runs-report "$TMP/main-report.txt" \
    > "$TMP/main-fails.txt" || main_status=$?
  if [ "$main_status" -ne 0 ]; then
    say_err "admin-merge: ✗ BLOCK — could not extract main's failing set (parser exit $main_status)."
    say_err "   Refusing to certify a comparison computed over an unreadable baseline."
    exit 1
  fi

  # ── 3. the shared comparison (one implementation, two consumers) ─────────
  # Its OWN exit status is checked: a failed `--diff` leaves an EMPTY file, which
  # reads as "no unique failures" and merges. That is fail-open (review P2).
  if ! run_failure_set --diff "$TMP/pr-fails.txt" "$TMP/main-fails.txt" > "$TMP/unique.txt"; then
    say_err "admin-merge: ✗ BLOCK — the shared comparison failed (parser exit). No merge."
    exit 1
  fi
  local unique_before
  unique_before="$(count_lines "$TMP/unique.txt")"

  local flake_line="Flake classification: none needed (no unique failures before re-run)"
  local rerun_residual=0

  if [ "$unique_before" -gt 0 ]; then
    info "admin-merge: $unique_before failure(s) look unique to this PR — re-run classification:"
    sed 's/^/   /' "$TMP/unique.txt"
    if [ "$NO_RERUN" -eq 1 ]; then
      say_err "admin-merge: ✗ BLOCK — unique failures present and --no-rerun given. No merge."
      exit 1
    fi
    # Re-run every failing run of the PR head ONCE. A test that passes on retry
    # is order/timing flaky, not new — the #3469 shape (a sibling pair that
    # trips alternately on main) must not hard-block a safe merge.
    local run_line run_id
    while IFS= read -r run_line; do
      [ -n "$run_line" ] || continue
      run_id="${run_line##*:}"
      info "admin-merge: ↻ re-running failed jobs of run $run_id"
      if ! $GH run rerun "$run_id" --failed >/dev/null 2>&1; then
        say_err "admin-merge: ✗ BLOCK — could not re-run $run_id (gh error). No merge."
        exit 1
      fi
      if ! wait_for_run "$run_id"; then
        say_err "admin-merge: ✗ BLOCK — run $run_id did not complete within ${RERUN_TIMEOUT}s. No merge."
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
    run_failure_set --commit "$head" ${repo_args[@]+"${repo_args[@]}"} ${wf_args[@]+"${wf_args[@]}"} \
      --runs-report "$TMP/pr-report2.txt" > "$TMP/pr-fails2.txt" || pr_status2=$?
    [ "$pr_status2" -eq 0 ] || { say_err "admin-merge: ✗ BLOCK — PR failing set unreadable after re-run"; exit 1; }
    if ! run_failure_set --diff "$TMP/pr-fails2.txt" "$TMP/main-fails.txt" > "$TMP/unique2.txt"; then
      say_err "admin-merge: ✗ BLOCK — the shared comparison failed after the re-run (parser exit). No merge."
      exit 1
    fi
    rerun_residual="$(count_lines "$TMP/unique2.txt")"

    if [ "$rerun_residual" -gt 0 ]; then
      say_err "admin-merge: ✗ BLOCK — $rerun_residual unique failure(s) SURVIVED the re-run:"
      sed 's/^/   /' "$TMP/unique2.txt" >&2
      say_err "   These are new failures this PR introduces — merge refused."
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
Lane completion: PR completed=$(report_value "$TMP/pr-report.txt" completed) pending=$(report_value "$TMP/pr-report.txt" pending) | main completed=$(report_value "$TMP/main-report.txt" completed) pending=$(report_value "$TMP/main-report.txt" pending)"

  # A vacuous comparison is STATED, never implied. Both sides empty is usually a
  # correct outcome (the lane is green on both sides) — but it is also exactly
  # what a WRONG lane selector looks like, so the two must be distinguishable by
  # a reader of the evidence. See the bogus-zero trap in ci-failure-set.sh.
  if [ "$pr_count" -eq 0 ] && [ "$main_count" -eq 0 ]; then
    analyzed="$analyzed
⚠️ vacuous comparison: no failing runs were observed on EITHER side, so nothing was actually compared. Correct when the lane is green on both sides — but if the lane selector is wrong (--workflow), this certifies nothing."
    info "admin-merge: ⚠️  vacuous comparison — no failing runs on either side; nothing was compared (lane: $lane)"
  fi

  info "admin-merge: PR failing: $pr_count | main failing: $main_count | unique to this PR: 0"

  build_evidence "$head" "$TMP/main-runs.txt" "$pr_count" "$main_count" \
    "$(cat "$TMP/unique.txt")" "$flake_line" "$analyzed" "$lane" > "$TMP/evidence.md"

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
  $GH pr merge "$PR" --admin --match-head-commit "$head" ${MERGE_ARGS[@]+"${MERGE_ARGS[@]}"} ${repo_args[@]+"${repo_args[@]}"}
}

main "$@"
