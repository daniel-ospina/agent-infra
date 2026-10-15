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
#   resolve_required_checks  -> that set, honouring the REQ operator override, else FALLBACK_REQ
#                               (ONE resolver: an earlier duplicate pair is what let a round-5 fix
#                                land in one copy and not the other — review round 6, P2)
#   merge_authority          -> gate (the review-gate check is the authority) | rail (the repo's
#                               own merge rail is the authority)
#
# ⛔ FAIL-CLOSED, THREE WAYS.
#   1. An unreadable protection endpoint NEVER becomes an EMPTY required set. An empty `want`
#      reads as NOCHECKS (nothing merges) and is indistinguishable from a permission-shaped
#      partial response, so `resolve_required_checks` substitutes FALLBACK_REQ — deliberately
#      NON-EMPTY names, and foreign to a repo that is not tortoise. ⚠️ On such a repo the
#      fallback's gate name reads FAILED (not PENDING — review P2, round 1), so an unresolved
#      contract stops ALL action: the CONTROLLER's sweep merges/auto-arms/spawns nothing while
#      protection is unreadable (orch-loop.sh, AUTHORITY_UNKNOWN), and merge-one.sh REFUSES on
#      its own fallback read (exit 5) — which covers every ingress, including chain-merge.sh and
#      fix-one.sh, which invoke it directly. A fallback left to drive the FAILED arm would
#      otherwise spawn a fresh-context reviewer per PR per cycle for as
#      long as the read fails. That is the fail-closed direction, and it is why the fallback is a
#      real list rather than the empty string.
#   2. The review gate is a REQUIRED name like any other: `merge_authority` reads it from the
#      resolved set, never from a per-PR observation, so "absent on THIS PR" can never demote it —
#      only "this repo does not require it" can.
#   3. A rail-managed repo whose rail is missing REFUSES; it never degrades to `gh pr merge`.
set -u

# The review-gate check NAME is itself repo-dependent (tortoise: `ai-review-gate`).
# REVIEW_GATE_DEFAULT is the name the DETECTOR compares against: a `REVIEW_GATE` that is merely
# echoed back can never disagree with itself (review round 6, P1 — the round-5 detector was
# arithmetically inert), so the question "did the override change the authority?" is answered with
# the DEFAULT gate name, which is what the repo's declaration would give with no override at all.
# Record whether it came from the environment: such an override moves the merge authority — and the
# classifier's gate_ok — onto a different name. That is sometimes intended (a repo whose gate has
# another name), but it must never be SILENT: it is read from the environment, and a cloud cell
# sources keys.env with `set -a`, so a stray export reaches here.
REVIEW_GATE_DEFAULT="ai-review-gate"
REVIEW_GATE_SOURCE="default"
if [ -n "${REVIEW_GATE:-}" ] && [ "$REVIEW_GATE" != "$REVIEW_GATE_DEFAULT" ]; then REVIEW_GATE_SOURCE="env"; fi
REVIEW_GATE="${REVIEW_GATE:-$REVIEW_GATE_DEFAULT}"

# LAST-RESORT ONLY, and the one place the pre-#1764 constant still lives — as the documented
# fallback for a repo whose protection cannot be read (see the header). It is NOT a default, and
# it never overrides a successful read or an explicit REQ.
FALLBACK_REQ="ai-review-gate python-ci-gate docs test-isolation license-surface legal-e2e pricing-artifact"

# _unrepresentable <owner/repo> <newline-delimited names> — rc 1 (loud) if any NAME carries
# whitespace or a comma.
# ⚠️ GitHub allows both in a context name (`ci / lint`, `a,b`), but neither can travel this
# contract: the set is SPACE-joined (the classifier splits on whitespace) and the RED set the
# controller derives is COMMA-joined (the FAILED arm splits on commas), so such a name silently
# becomes two names — the PR sits PENDING forever or misroutes to the wrong arm, with nothing
# logged (review rounds 3-4). The test is PER NAME, on the raw newline-delimited lines.
# Supporting such names end-to-end (bash splits, the python split, case matching) is a redesign;
# REFUSING loudly is the fail-closed answer: this counts as a FAILED read, so the fallback
# applies and the sweep — and every merge worker — refuses to act on a contract it cannot
# represent.
_unrepresentable() {
  grep -Eq '[[:space:],]' <<<"${2:-}" || return 0
  printf 'repo-authority: %s: a required context name contains whitespace or a comma [%s] — the space-joined contract (and the comma-joined RED list) cannot represent it; treating the read as FAILED (fail-closed)\n' "${1:-}" "$(grep -E '[[:space:],]' <<<"${2:-}" | tr '\n' ' ')" >&2
  return 1
}

# _override_usable <owner/repo> <space-joined REQ_OVERRIDE> — rc 1 (loud) if the override carries
# a comma (review round 5). The override is itself SPACE-separated, so a name containing a space
# is indistinguishable from two names there and cannot be screened; the comma IS detectable and is
# the destructive one, because it splits the comma-joined RED list — a red required check then
# reaches no worker at all. An unusable override is discarded by the resolvers, which fall through
# to the repo's own declaration (and, if that read also fails, to the refusal).
_override_usable() {
  grep -q ',' <<<"${2:-}" || return 0
  printf 'repo-authority: %s: the REQ override [%s] contains a comma — the comma-joined RED list cannot represent it, so the override is IGNORED (fail-closed: the repo declaration is used instead, or every caller refuses)\n' "${1:-}" "${2:-}" >&2
  return 1
}

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
  _unrepresentable "$or" "$raw" || return 1
  joined="$(printf '%s\n' "$raw" | awk 'NF && !seen[$0]++' | tr '\n' ' ')"
  joined="${joined% }"
  [ -n "$joined" ] || return 1
  printf '%s\n' "$joined"
}

# `resolve_required_checks` <owner/repo> [<gh-binary>]
# Sets REQ and REQ_SOURCE in the CALLER'S shell — the one production callers use.
# ⛔ A CALLER CANNOT DO THIS ITSELF: `REQ="$(resolve_required_checks …)"` runs the resolver in
# a command-substitution SUBSHELL, so REQ_SOURCE cannot survive the assignment (measured live:
# REQ=[pipeline-compliance] REQ_SOURCE=[<EMPTY>]) and the operational fallback warning can never
# fire. This wrapper performs the same three-way resolution in the current shell, where both
# globals land.
# ⛔ ONE RESOLVER, DELIBERATELY (review round 6). An `effective_required_checks` twin existed and
# had no production caller; a fix landed in `resolve_required_checks` only, and a mutant of the
# twin stayed green across every suite. Two copies of one policy is how that happens.
resolve_required_checks() {
  if [ -n "${REQ_OVERRIDE:-}" ]; then
    if _override_usable "$1" "${REQ_OVERRIDE:-}"; then REQ="$REQ_OVERRIDE"; REQ_SOURCE=env; return 0; fi
    REQ_OVERRIDE=""  # malformed: discard (loudly) and use the repo's own declaration — see above
  fi
  if REQ="$(required_checks "$1" "${2:-gh}")"; then REQ_SOURCE=protection; return 0; fi
  REQ="$FALLBACK_REQ"; REQ_SOURCE=fallback; return 0
}

# merge_authority <required-check-string> -> `gate` | `rail` | `unknown`
# ⚠️ An EMPTY set is `unknown` (review round 3): a stale or partial repo-authority.sh used to
# yield REQ="" here, which read as `rail` and silently rerouted a gate repo onto the rail —
# an empty contract must refuse, never route.
# A repo that REQUIRES the review gate uses that check as the merge authority, and a plain
# squash merge lands. A repo that does NOT must use its own merge rail: `gh pr merge` there
# would land the PR on the required checks alone, with no head-bound evidence — the bypass
# agent-infra's own AGENTS.md forbids ("merge via `scripts/admin-merge.sh <PR>`, never raw
# `gh pr merge`").
merge_authority() {
  if [ -z "${1:-}" ]; then printf 'unknown\n'; return 0; fi
  case " ${1:-} " in
    *" $REVIEW_GATE "*) printf 'gate\n' ;;
    *)                  printf 'rail\n' ;;
  esac
}
