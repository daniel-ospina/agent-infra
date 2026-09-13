#!/usr/bin/env bash
# ci-failure-set.sh — resolve a revision's failing test set (#930).
#
# ONE PARSER, TWO CONSUMERS. The pre-merge chokepoint (scripts/admin-merge.sh)
# and the post-merge detector (.github/workflows/admin-merge-detector.yml) must
# agree on what "a unique failure" means — if they are two implementations, they
# drift, and the pre-merge gate stops matching the post-merge alarm. Every
# consumer calls this script; nothing re-implements the parse.
#
# What it does:
#   1. lists the FAILING check runs for a selector (a PR head, a commit, or the
#      last N runs on main);
#   2. fetches each failing run's failed-step log (`gh run view --log-failed`);
#   3. extracts `FAILED <nodeid>` lines and emits a sorted, unique, one-test-
#      per-line set.
#
# Modes:
#   --pr <N>                  failing set of PR #N's head commit
#   --commit <sha>            failing set of a commit's runs
#   --main-union [N]          UNION of main's failing sets over the last N runs
#                             (default 10 — deliberately NOT a single run: a
#                             test that fails on main only in *some* runs, e.g.
#                             an order-dependent sibling pair, must still count
#                             as "already red on main". See the #3469 trap below.)
#   --diff <a> <b>            tests in file a not in file b (the `comm -23`
#                             comparison, shared by every consumer so the two
#                             sides cannot drift)
#
# Options:
#   --exclude <sha>           (--main-union) drop runs whose headSha is <sha>
#   --repo <owner/repo>       repo for the gh calls (default: gh's own resolution)
#   --workflow <file|name>    restrict the run listing to ONE workflow (default
#                             `python-ci.yml`, or $CI_FAILURE_SET_WORKFLOW).
#                             See THE BOGUS ZERO below — this is not optional in
#                             a repo whose main also runs cron/watchdog lanes.
#   --any-workflow            drop the workflow filter (opt-out; re-opens the
#                             bogus zero — use only when the test lane is the
#                             repo's only failing surface)
#   --provenance <file>       write the examined failing runs as `<sha>:<run-id>`
#   --runs-report <file>      write `examined=<n>` / `extracted=<n>` counts
#   --help
#
# Exit codes:
#   0  extracted (the set may legitimately be EMPTY — no failing runs, or
#      failing runs whose failures are not `FAILED <nodeid>` shaped)
#   1  the extraction itself failed (gh error, unreadable log) — the caller MUST
#      treat this as "cannot certify", never as "no unique failures". A rail
#      that reads an extraction error as an empty set is vacuously green.
#   2  usage error
#
# WHY THIS IS NOT `comm` ON A SINGLE RUN (#3469):
#   tortoise #3469: raw `comm -23` reported 1 unique failure, true value 0.
#   `test_import_wrong_key_422` and `test_import_count_mismatch_422` share one
#   assertion; WHICH sibling trips depends on execution order, and main fails
#   each in different runs. A single-run main baseline sees only one of them, so
#   the other reads as "new" — and a literal "require `comm -23` empty" would
#   hard-block a safe merge. A gate that false-blocks once gets disabled, and
#   then we are back to a convention. Hence the union over the last N runs.
#
# THE BOGUS ZERO (the second trap this design exists to avoid):
#   `gh run list --branch main` returns whatever ran most, NOT the test lane.
#   tortoise main, measured 2026-09-13: of the last 30 runs on main, 11 were
#   `availability-watchdog`, 3 `Inbound relay`, 3 `redis-guard`, 3
#   `welcome-e2e-monitor`, 2 `registry-backup-cron` — and only 2 were `Python CI`.
#   So a window of the last 10 runs can contain ZERO test runs, the baseline
#   extracts EMPTY, and every failing test in the PR reads as NEW. That is a
#   vacuous baseline, and it false-blocks: the same failure mode as #3469, just
#   from the other side. Resolve the baseline from the TEST workflow.
#
#   The filter also applies to `--pr`/`--commit`: the PR side and the main side
#   must come from the SAME lane, or `comm -23` compares two different things.
#
# Env seams (tests only):
#   CI_FAILURE_SET_GH         the gh command to run (default: `gh`)
#   CI_FAILURE_SET_WORKFLOW   the workflow filter (default: `python-ci.yml`)

set -uo pipefail

GH="${CI_FAILURE_SET_GH:-gh}"
DEFAULT_MAIN_RUNS=10
DEFAULT_WORKFLOW="python-ci.yml"

# Populated by main() before any selector runs. Bash locals are dynamically
# scoped, but these are deliberately global: every helper below (and every
# helper they call) must route --repo and --workflow identically, or one call
# site silently drops a flag — which is how the bogus zero happened the first
# time (--repo was accepted and then never forwarded to `gh run list`).
REPO_ARGS=()
WORKFLOW_ARGS=()

# A failing check run. `cancelled` is deliberately EXCLUDED: ci.yml uses
# `cancel-in-progress`, so a superseded run is cancelled, not failed — counting
# it as red would pollute every baseline with noise.
FAILING_RUN_JQ='.[] | select(.conclusion=="failure" or .conclusion=="timed_out" or .conclusion=="startup_failure") | "\(.headSha):\(.databaseId)"'

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

say_err() { printf '%s\n' "$*" >&2; }

# ── selectors ─────────────────────────────────────────────

# list_failing_runs <flag> <value> <limit>  → `<sha>:<run-id>` lines on stdout.
# <flag> is `--commit` or `--branch`. Exits 1 when gh fails (fail-closed: an
# unreadable run list must never read as "nothing failed").
list_failing_runs() {
  local flag="$1" value="$2" limit="$3"
  # shellcheck disable=SC2086
  $GH run list "$flag" "$value" --limit "$limit" \
    ${WORKFLOW_ARGS[@]+"${WORKFLOW_ARGS[@]}"} ${REPO_ARGS[@]+"${REPO_ARGS[@]}"} \
    --json databaseId,conclusion,headSha --jq "$FAILING_RUN_JQ"
}

# extract_failed_tests <run-id> → sorted-unique nodeids, one per line.
# A failing run whose failed-step log cannot be fetched is an EXTRACTION
# FAILURE (exit 1), not an empty contribution: silently dropping it is exactly
# the vacuous pass this rail exists to prevent.
extract_failed_tests() {
  local run_id="$1" log
  # shellcheck disable=SC2086
  if ! log="$($GH run view "$run_id" ${REPO_ARGS[@]+"${REPO_ARGS[@]}"} --log-failed 2>/dev/null)"; then
    say_err "ci-failure-set: ✗ could not fetch the failed-step log for run $run_id (gh error) — refusing to read this as an empty failing set"
    return 1
  fi
  printf '%s\n' "$log" \
    | sed $'s/\033\\[[0-9;]*[A-Za-z]//g' \
    | awk '{ for (i = 1; i < NF; i++) if ($i == "FAILED") { print $(i+1); break } }'
}

# ── modes ─────────────────────────────────────────────────

# Sets a union of the FAILED nodeids across every failing run in <run-list>.
# Also writes provenance/counts when requested. Returns 1 on extraction failure.
collect_union() {
  local runs_file="$1" provenance="$2" report="$3"
  local tmp_set="" examined=0 extracted=0 run_id line
  tmp_set="$(mktemp "${TMPDIR:-/tmp}/ci-failure-set.XXXXXX")"
  : > "$tmp_set"
  # The provenance file must exist even when NOTHING failed — callers build the
  # evidence from it (`tr < file`), and a missing file is an error, not an empty
  # baseline.
  [ -n "$provenance" ] && : > "$provenance"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    run_id="${line##*:}"
    examined=$((examined + 1))
    printf '%s\n' "$line" >> "${provenance:-/dev/null}"
    local one
    one="$(extract_failed_tests "$run_id")" || { rm -f "$tmp_set"; return 1; }
    if [ -n "$one" ]; then
      extracted=$((extracted + 1))
      printf '%s\n' "$one" >> "$tmp_set"
    fi
  done < "$runs_file"
  if [ -n "$report" ]; then
    printf 'examined=%s\nextracted=%s\n' "$examined" "$extracted" > "$report"
  fi
  sort -u "$tmp_set"
  rm -f "$tmp_set"
}

# ── main ──────────────────────────────────────────────────

main() {
  local mode="" pr="" commit="" main_runs="$DEFAULT_MAIN_RUNS"
  local exclude="" repo="" provenance="" report="" diff_a="" diff_b=""
  local workflow="${CI_FAILURE_SET_WORKFLOW:-$DEFAULT_WORKFLOW}" any_workflow=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --pr) mode="pr"; pr="${2:-}"; shift 2 ;;
      --commit) mode="commit"; commit="${2:-}"; shift 2 ;;
      --main-union)
        mode="main-union"
        if [ $# -ge 2 ] && [ -n "${2:-}" ] && [ -z "${2##[0-9]*}" ]; then
          main_runs="$2"; shift 2
        else
          shift 1
        fi ;;
      --diff) mode="diff"; diff_a="${2:-}"; diff_b="${3:-}"; shift 3 ;;
      --exclude) exclude="${2:-}"; shift 2 ;;
      --repo) repo="${2:-}"; shift 2 ;;
      --workflow) workflow="${2:-}"; shift 2 ;;
      --any-workflow) any_workflow=1; shift ;;
      --provenance) provenance="${2:-}"; shift 2 ;;
      --runs-report) report="${2:-}"; shift 2 ;;
      --help|-h) usage; exit 0 ;;
      *) say_err "ci-failure-set: unknown argument '$1'"; usage >&2; exit 2 ;;
    esac
  done

  REPO_ARGS=()
  [ -n "$repo" ] && REPO_ARGS=(--repo "$repo")
  WORKFLOW_ARGS=()
  # An empty --workflow (or --any-workflow) means no filter. Filtering by the
  # TEST lane is the default because an unfiltered window is how the baseline
  # reads EMPTY while main is red — see THE BOGUS ZERO in the header.
  if [ "$any_workflow" -eq 0 ] && [ -n "$workflow" ]; then
    WORKFLOW_ARGS=(--workflow "$workflow")
  fi

  case "$mode" in
    diff)
      [ -n "$diff_a" ] && [ -n "$diff_b" ] || { say_err "ci-failure-set: --diff needs two files"; exit 2; }
      [ -r "$diff_a" ] || { say_err "ci-failure-set: cannot read $diff_a"; exit 1; }
      [ -r "$diff_b" ] || { say_err "ci-failure-set: cannot read $diff_b"; exit 1; }
      # One comparison, one implementation — the pre-merge gate and the
      # post-merge detector both shell out to this branch, so "unique failure"
      # cannot mean two different things.
      comm -23 <(sort -u "$diff_a") <(sort -u "$diff_b")
      ;;
    pr)
      [ -n "$pr" ] || { say_err "ci-failure-set: --pr needs a PR number"; exit 2; }
      local head runs
      # shellcheck disable=SC2086
      # `${repo_args[@]+…}` — bash 3.2 (macOS /bin/bash) errors on `"${arr[@]}"`
      # for an empty array under `set -u`.
      head="$($GH pr view "$pr" ${REPO_ARGS[@]+"${REPO_ARGS[@]}"} --json headRefOid --jq .headRefOid 2>/dev/null)" || {
        say_err "ci-failure-set: ✗ could not resolve head of PR #$pr"; exit 1; }
      [ -n "$head" ] || { say_err "ci-failure-set: ✗ empty head for PR #$pr"; exit 1; }
      runs="$(mktemp "${TMPDIR:-/tmp}/ci-failure-set.XXXXXX")"
      list_failing_runs --commit "$head" 100 > "$runs" || { rm -f "$runs"; say_err "ci-failure-set: ✗ could not list runs for $head"; exit 1; }
      collect_union "$runs" "$provenance" "$report" || { rm -f "$runs"; exit 1; }
      rm -f "$runs"
      ;;
    commit)
      [ -n "$commit" ] || { say_err "ci-failure-set: --commit needs a SHA"; exit 2; }
      local runs
      runs="$(mktemp "${TMPDIR:-/tmp}/ci-failure-set.XXXXXX")"
      list_failing_runs --commit "$commit" 100 > "$runs" || { rm -f "$runs"; say_err "ci-failure-set: ✗ could not list runs for $commit"; exit 1; }
      collect_union "$runs" "$provenance" "$report" || { rm -f "$runs"; exit 1; }
      rm -f "$runs"
      ;;
    main-union)
      local runs filtered
      runs="$(mktemp "${TMPDIR:-/tmp}/ci-failure-set.XXXXXX")"
      filtered="$(mktemp "${TMPDIR:-/tmp}/ci-failure-set.XXXXXX")"
      list_failing_runs --branch main "$main_runs" > "$runs" || { rm -f "$runs" "$filtered"; say_err "ci-failure-set: ✗ could not list main runs"; exit 1; }
      if [ -n "$exclude" ]; then
        awk -F: -v x="$exclude" '$1 != x' "$runs" > "$filtered"
      else
        cp "$runs" "$filtered"
      fi
      collect_union "$filtered" "$provenance" "$report" || { rm -f "$runs" "$filtered"; exit 1; }
      rm -f "$runs" "$filtered"
      ;;
    *)
      say_err "ci-failure-set: one of --pr, --commit, --main-union, --diff is required"
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
