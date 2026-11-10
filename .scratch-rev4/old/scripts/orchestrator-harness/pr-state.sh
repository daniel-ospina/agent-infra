#!/usr/bin/env bash
# pr-state.sh — THE ROUTER SEAM (agent-infra #2866): one row of the PR state table, for a bash actor.
#
#   . pr-state.sh                       # definitions only; this file never runs anything on source
#   prstate_row <owner/repo> <pr>       # → "ACTION<TAB>rerun_run<TAB>reason"   (rc 0 = a row)
#   prstate_row <owner/repo> <pr>       # → "unavailable<TAB>-<TAB>why"         (rc 2 = it did NOT run)
#
# WHY A SEAM AND NOT A SECOND CLASSIFIER. `tools/fleet/pr_state.py` is the ONE place that answers
# "what does this PR need next"; an actor that re-derives the answer is the defect #2866 names (each
# of `admin-merge.sh`, `pr-doctor.py`, `refresh-candidates.sh`, `pr-sickness.sh` knows a slice and
# none answers the question). So the actors call it and consume the row, and they never parse its
# JSON: `--action` prints exactly the three fields below.
#
# ⛔ AN UNRESOLVED ROUTER IS A NAMED ABSENCE, NEVER AN EMPTY ROW. Every failure path prints
# `unavailable` with a reason and returns 2, and the CALLER must say so in its own line. An empty
# row parsed into an empty action would silently mean "nothing to say", which is how a gate that
# never ran reads as a gate that passed.
#
# Resolution order (first that exists wins):
#   $PR_STATE_BIN                                   explicit; suites and operators set this
#   ${O}/tools/fleet/pr_state.py                    the deployed harness checkout
#   ~/.pi/agent/scripts/fleet/pr_state.py           the pi-bootstrap farm (setup.sh fleet_tools)
#   <this file's dir>/../../tools/fleet/pr_state.py the repo / worktree this file lives in
#
# `$PR_STATE_GH` (optional) is passed through to the module: it is how a consumer that already has a
# stubbed `gh` (pr-sickness's `PS_GH`, a test's PATH) keeps the router on the SAME read surface.
set -u

prstate_bin() {  # → the module path on stdout, rc 1 when none resolves
  local cand=""
  # ⛔ AN EXPLICIT PR_STATE_BIN THAT DOES NOT EXIST IS A REFUSAL, NOT A FALLBACK. Falling through to
  # another copy after an operator named one hides the misconfiguration, and a silent fallback is
  # indistinguishable from compliance (`skills/research` PREFLIGHT; premise-labs#400).
  if [ -n "${PR_STATE_BIN:-}" ]; then
    [ -f "$PR_STATE_BIN" ] && { printf '%s' "$PR_STATE_BIN"; return 0; }
    return 1
  fi
  for cand in \
              "${O:-}/tools/fleet/pr_state.py" \
              "$HOME/.pi/agent/scripts/fleet/pr_state.py" \
              "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)/../../tools/fleet/pr_state.py"; do
    [ -n "$cand" ] && [ -f "$cand" ] && { printf '%s' "$cand"; return 0; }
  done
  return 1
}

prstate_row() {  # <owner/repo> <pr> → the row; rc 0 = a row, 2 = the router did not run
  local repo="${1:-}" pr="${2:-}" bin out why
  if [ -z "$repo" ] || [ -z "$pr" ]; then
    printf 'unavailable\t-\tthe seam was called without both <owner/repo> and <pr>'
    return 2
  fi
  bin="$(prstate_bin)" || {
    printf 'unavailable\t-\tno pr_state.py resolved ($PR_STATE_BIN, $O/tools/fleet, the farm, this tree)'
    return 2
  }
  if ! command -v python3 >/dev/null 2>&1; then
    printf 'unavailable\t-\tpython3 is not on PATH, so the router could not run'
    return 2
  fi
  out="$(python3 "$bin" --repo "$repo" --only "$pr" --action 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] || [ -z "${out:-}" ]; then
    why="$(printf '%s' "${out:-}" | tail -1 | cut -c1-200)"
    printf 'unavailable\t-\tthe router exited %s: %s' "$rc" "${why:-no output}"
    return 2
  fi
  # ⛔ ONE LINE, THREE FIELDS. A row that is not that shape is an unreadable answer, not an action.
  case "$out" in
    *"$(printf '\t')"*"$(printf '\t')"*) printf '%s' "$out"; return 0 ;;
    *) printf 'unavailable\t-\tthe router answered in an unreadable shape (%s)' "$(printf '%s' "$out" | head -1 | cut -c1-160)"; return 2 ;;
  esac
}
