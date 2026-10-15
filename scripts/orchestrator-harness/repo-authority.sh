#!/usr/bin/env bash
# repo-authority.sh — the per-repo merge contract (agent-infra#1764).
#
# WHY THIS FILE EXISTS. orch-loop.sh carried tortoise's branch-protection contexts as a literal,
# and merge-one.sh asked every repo for tortoise's review gate. Pointed at a second repo both
# produced a CONFIDENT WRONG verdict: agent-infra PR #1763 had 21 passing checks and ZERO
# `ai-review-gate` runs, and the loop nonetheless logged `#1763 FAILED:ai-review-gate` — so no PR
# could read GREEN, the merge queue could not drain, and the controller logged
# `[dispatch] skipped (merge-priority …)` indefinitely. The required-check list and the review
# authority are REPO-DEPENDENT INPUTS carried as constants — the same class the #1736/#1748
# venv fix addressed, and the widened root this issue names.
#
# ONE HOME for the two inputs, SOURCED by BOTH orch-loop.sh and merge-one.sh so the two cannot
# drift:
#   required_checks          -> the repo's own branch-protection contexts
#   effective_required_checks-> that set, honouring the REQ operator override, else FALLBACK_REQ
#   merge_authority          -> gate (the review-gate check is the authority) | rail (the repo's
#                               own merge rail is the authority)
#
# ⛔ FAIL-CLOSED, THREE WAYS.
#   1. An unreadable protection endpoint NEVER becomes an EMPTY required set. An empty `want`
#      reads as NOCHECKS (nothing merges) and is indistinguishable from a permission-shaped
#      partial response, so `effective_required_checks` substitutes FALLBACK_REQ — deliberately
#      NON-EMPTY names, and foreign to a repo that is not tortoise, so every PR stays PENDING and
#      nothing merges unattended. That is the fail-closed direction, and it is why the fallback
#      is a real list rather than the empty string.
#   2. The review gate is a REQUIRED name like any other: `merge_authority` reads it from the
#      resolved set, never from a per-PR observation, so "absent on THIS PR" can never demote it —
#      only "this repo does not require it" can.
#   3. A rail-managed repo whose rail is missing REFUSES; it never degrades to `gh pr merge`.
set -u

# The review-gate check NAME is itself repo-dependent (tortoise: `ai-review-gate`).
REVIEW_GATE="${REVIEW_GATE:-ai-review-gate}"

# LAST-RESORT ONLY, and the one place the pre-#1764 constant still lives — as the documented
# fallback for a repo whose protection cannot be read (see the header). It is NOT a default, and
# it never overrides a successful read or an explicit REQ.
FALLBACK_REQ="ai-review-gate python-ci-gate docs test-isolation license-surface legal-e2e pricing-artifact"

# required_checks <owner/repo> [<gh-binary>]
# Print the repo's required status-check contexts, space-separated, once each.
#   rc 0 -> READ from branch protection (the printed set is NON-EMPTY)
#   rc 1 -> could NOT be read (network / permission / shape); nothing is printed
# A zero-name read is a FAILED read, never "this repo requires nothing".
required_checks() {
  local or="${1:-}" gh="${2:-gh}" raw joined
  [ -n "$or" ] || return 1
  raw="$("$gh" api "repos/$or/branches/main/protection/required_status_checks" --jq '.contexts[]' 2>/dev/null)" || return 1
  # De-duplicate and join on one line: the classifier splits on whitespace, and a newline would
  # otherwise reach it as part of the value rather than as a separator.
  joined="$(printf '%s\n' "$raw" | awk 'NF && !seen[$0]++' | tr '\n' ' ')"
  joined="${joined% }"
  [ -n "$joined" ] || return 1
  printf '%s\n' "$joined"
}

# effective_required_checks <owner/repo> [<gh-binary>]
# Print the required-check string the classifier must use, and set the global REQ_SOURCE to the
# home it came from (`env` | `protection` | `fallback`). Never fails: the fallback is the
# fail-closed answer.
# ⛔ READ THE OVERRIDE FROM REQ_OVERRIDE, NOT REQ. Both callers overwrite REQ every cycle with
# the resolved value; reading REQ here would make the second cycle believe the FIRST cycle's
# resolution was an operator override and freeze it. REQ_OVERRIDE is captured once, before the
# first resolution.
effective_required_checks() {
  local or="${1:-}" gh="${2:-gh}" req
  if [ -n "${REQ_OVERRIDE:-}" ]; then
    REQ_SOURCE=env
    printf '%s\n' "$REQ_OVERRIDE"
    return 0
  fi
  if req="$(required_checks "$or" "$gh")"; then
    REQ_SOURCE=protection
    printf '%s\n' "$req"
    return 0
  fi
  REQ_SOURCE=fallback
  printf '%s\n' "$FALLBACK_REQ"
}

# resolve_required_checks <owner/repo> [<gh-binary>]
# Sets REQ and REQ_SOURCE in the CALLER'S shell — the one production callers use.
# ⛔ A CALLER CANNOT DO THIS ITSELF: `REQ="$(effective_required_checks …)"` runs the resolver in
# a command-substitution SUBSHELL, so REQ_SOURCE cannot survive the assignment (measured live:
# REQ=[pipeline-compliance] REQ_SOURCE=[<EMPTY>]) and the operational fallback warning below can
# never fire. This wrapper performs the same three-way resolution in the current shell, where
# both globals land.
resolve_required_checks() {
  if [ -n "${REQ_OVERRIDE:-}" ]; then REQ="$REQ_OVERRIDE"; REQ_SOURCE=env; return 0; fi
  if REQ="$(required_checks "$1" "${2:-gh}")"; then REQ_SOURCE=protection; return 0; fi
  REQ="$FALLBACK_REQ"; REQ_SOURCE=fallback; return 0
}

# merge_authority <required-check-string> -> `gate` | `rail`
# A repo that REQUIRES the review gate uses that check as the merge authority, and a plain
# squash merge lands. A repo that does NOT must use its own merge rail: `gh pr merge` there
# would land the PR on the required checks alone, with no head-bound evidence — the bypass
# agent-infra's own AGENTS.md forbids ("merge via `scripts/admin-merge.sh <PR>`, never raw
# `gh pr merge`").
merge_authority() {
  case " ${1:-} " in
    *" $REVIEW_GATE "*) printf 'gate\n' ;;
    *)                  printf 'rail\n' ;;
  esac
}
