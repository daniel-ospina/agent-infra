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

# _normalise_set <string> — collapse every whitespace RUN to one space and trim both ends, so the
# bash matchers (which delimit a name on a literal SPACE) and the classifier's `str.split()` can
# never disagree about the SAME string. A whitespace-only value normalises to EMPTY, which every
# caller here reads as "absent" — never as a non-empty contract.
# ⛔ review round 8, classes B2/B3. `_override_usable` screened only a comma, so a tab-separated
# override made `merge_authority` answer `rail` while the classifier enforced the gate: on a gate
# repo `merge-one.sh` then took its RAIL branch, skipping the fresh-context reviewer and the signed
# record — a §5.1 bypass — and a whitespace-only override routed to `rail` instead of refusing.
# ⛔⛔ THE DEFINITION MUST BE SHARED, NOT COPIED (round-9 review, P2). The first fix ENUMERATED the
# bytes to fold (`tr '\n\t\r\v\f'`), and an enumeration cannot be right: the classifier splits on
# Python's `str.isspace()`, a SUPERSET of POSIX `[:space:]`. Measured at 10c56ed5, a set joined by
# \x1c, \x1d or NBSP still made the classifier report GATE-ENFORCED while `merge_authority`
# answered `rail` — the identical bypass, still open. python3 is ALREADY the classifier's own
# dependency, so this normalises with the classifier's own rule and the two readers now agree BY
# CONSTRUCTION. rc 1 = the normaliser is unavailable; every caller must then treat the contract as
# ABSENT (fail-closed) rather than let an un-normalised value reach both readers differently.
_normalise_set() {
  local py
  py="$(command -v python3 2>/dev/null || true)"
  [ -n "$py" ] || return 1
  printf '%s' "${1:-}" | "$py" -c '
import sys
# ⛔ DECODE EXACTLY AS THE CLASSIFIER DOES (round-10 review, P2). The classifier reads
# os.environ["REQ"], which Python decodes with the FILESYSTEM encoding — NOT utf-8. Hard-coding
# utf-8 made the two definitions differ on a host whose filesystem encoding is single-byte:
# measured under a localedef ISO-8859-1 locale, a lone 0xA0 decoded to NBSP for the classifier
# (whitespace, so it SPLIT and enforced the gate) and to a surrogate here (not whitespace, so it
# did not, and merge_authority answered `rail`) — the same §5.1 bypass, one environment away.
enc = sys.getfilesystemencoding() or "utf-8"
err = sys.getfilesystemencodeerrors() or "surrogateescape"
d = sys.stdin.buffer.read().decode(enc, err)
sys.stdout.buffer.write(" ".join(d.split()).encode(enc, err))
' 2>/dev/null || return 1
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

# _gh_named_state — the gh layer's NAMED budget state (`gh-core-exhausted resets_in=12m`), or empty
# when the budget is fine or the record is stale.
#
# ⛔ WHY A LANE MUST SAY THIS INSTEAD OF “branch protection UNREADABLE”: on 2026-10-22 the account's
# REST pool reached `5000 used / 0 remaining` while GraphQL still held 4769. Every lane read the
# refused protection endpoint as “the merge contract is UNKNOWN”, and the human-facing diagnosis that
# follows — wrong token, wrong repo, broken protection — was WRONG in all three parts. A budget the
# fleet's own polling spent is indistinguishable, from inside a lane, from GitHub being down, so the
# layer names it and this function repeats the name verbatim.
#
# ⛔ IT READS LOCAL STATE, DELIBERATELY: this runs at exactly the moment every gh call is refused, and
# `gh-limit.py --health` is the surface that answers then (no request, no quota, no credentials). The
# file is read directly rather than shelling out, because a resolver called once per candidate must
# not add a process per call.
# ⛔ AND IT IS AGE-BOUNDED, like `last-limit`: a record whose `reset` has passed is not a CURRENT
# state, or one exhausted window would keep asserting itself for the rest of the day.
#
# ⛔ AN UNDATED RECORD IS STILL A STATE — the shape this function USED TO IGNORE ENTIRELY. A refusal
# that carried no `X-RateLimit-Reset` is recorded with `reset=0` (the layer cannot invent a window),
# and EVERY `GH_LIMIT_NO_WAIT` caller produces exactly that shape — eight heartbeat tools set it. So
# requiring `reset > now` made this function print NOTHING in the most common case, and the lane went
# back to “branch protection UNREADABLE” with no reason, which is the whole defect this exists to
# remove (measured 2026-10-22: the same record printed nothing here while `gh-limit.py --health`
# named it). The age bound is the layer's own `HEALTH_UNKNOWN_WINDOW` (900 s) for that shape, and the
# token says `?` rather than a number nobody measured.
_gh_named_state() {
  local dir p line tok reset at now _win
  dir="${GH_LIMIT_DIR:-${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/gh-limit}"
  p="$dir/health"
  [ -f "$p" ] || return 0
  IFS= read -r line < "$p" 2>/dev/null || return 0
  tok="${line%% *}"
  case "$tok" in gh-*) ;; *) return 0 ;; esac
  reset="$(printf '%s' "$line" | sed -n 's/.*[[:space:]]reset=\([0-9][0-9]*\).*/\1/p')"
  now="$(date +%s)"
  if [ -n "$reset" ] && [ "$reset" -gt 0 ]; then
    [ "$reset" -gt "$now" ] || return 0
    printf '%s resets_in=%dm' "$tok" "$(( (reset - now + 59) / 60 ))"
    return 0
  fi
  # undated: current only inside the layer's bounded window, and honest about the number
  at="$(printf '%s' "$line" | sed -n 's/.*[[:space:]]at=\([0-9][0-9]*\).*/\1/p')"
  [ -n "$at" ] && [ "$at" -gt 0 ] || return 0
  # ⛔ THE BOUND IS CLAMPED EXACTLY AS THE LAYER CLAMPS IT (cfg_secs(…, 60, 86400)). Taking the env
  # verbatim made the two readers DISAGREE about the same record: at window=30 a 45 s-old record
  # printed nothing here while `gh-limit.py --health` named it — the “two contracts for one rule”
  # defect, in the pair of readers that must agree or the lane is told two different things. And the
  # clamp must accept what `cfg_secs` accepts: a DECIMAL (`45.5` → 60) and a NEGATIVE (`-5` → 60)
  # reach the floor, while a NON-NUMERIC falls back to the default — a digits-only `case`, which is
  # what this was, sent both of the first two to the 900 s default instead.
  _win="${GH_LIMIT_HEALTH_UNKNOWN_WINDOW:-900}"
  case "$_win" in ''|*[!0-9.+-]*) _win=900 ;; esac
  _win="$(awk -v v="$_win" 'BEGIN { n = v + 0; if (n < 60) n = 60; if (n > 86400) n = 86400; printf "%d", n }' 2>/dev/null)"
  case "$_win" in ''|*[!0-9]*) _win=900 ;; esac
  [ "$now" -ge "$at" ] && [ "$(( now - at ))" -le "$_win" ] || return 0
  printf '%s resets_in=?' "$tok"
}

# required_checks <owner/repo> [<gh-binary>]
# Print the repo's required status-check contexts, space-separated, once each.
#   rc 0 -> READ from branch protection (the printed set is NON-EMPTY)
#   rc 1 -> could NOT be read (network / permission / shape); nothing is printed
# A zero-name read is a FAILED read, never "this repo requires nothing".
required_checks() {
  local or="${1:-}" gh="${2:-gh}" raw joined named
  [ -n "$or" ] || return 1
  raw="$("$gh" api "repos/$or/branches/main/protection/required_status_checks" --jq '.contexts[]' 2>/dev/null)" || {
    # The read failed. Say WHY when the layer knows: an exhausted budget is a “wait 12 minutes”, not
    # a “fix your token”. Silence otherwise — the existing fail-closed path is unchanged.
    named="$(_gh_named_state)"
    if [ -n "$named" ]; then
      printf 'repo-authority: %s: required checks UNREAD — %s (the REST budget is spent, not a broken repo, not an invalid token, not GitHub being down). The merge contract is UNKNOWN until the window clears (fail-closed).\n' "$or" "$named" >&2
    fi
    return 1
  }
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
  local _ov
  if [ -n "${REQ_OVERRIDE:-}" ]; then
    if ! _ov="$(_normalise_set "${REQ_OVERRIDE:-}")"; then
      # The normaliser itself is unavailable (no python3). Discard the override rather than let an
      # un-normalised value reach the classifier and the matcher unalike — fail-closed.
      printf 'repo-authority: %s: the REQ override CANNOT be normalised (python3 is required) — the override is IGNORED (fail-closed: the repo declaration is used instead)\n' "${1:-}" >&2
    elif [ -z "$_ov" ]; then
      # ⛔ A whitespace-only override is NOT an override: `' '.split()` is `[]` for the classifier,
      # so a non-empty-but-NAMELESS contract would ROUTE (`rail`) instead of refusing — the round-8
      # B3 bypass. Discard it and fall through to the repo's own declaration (fail-closed).
      printf 'repo-authority: %s: the REQ override is whitespace-only — it carries no names, so it is treated as ABSENT (fail-closed: the repo declaration is used instead)\n' "${1:-}" >&2
    elif _override_usable "$1" "$_ov"; then REQ="$_ov"; REQ_SOURCE=env; return 0
    fi
    REQ_OVERRIDE=""  # malformed or nameless: discard (loudly) and use the repo's own declaration
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
  # ⛔ NORMALISE FIRST (review round 8, B3). A whitespace-bearing set makes the classifier
  # (`str.split()`, which splits on ANY whitespace) and this whole-name test (which delimited on a
  # literal space) disagree about the same string — `rail` here, gate enforced there. And a
  # whitespace-only set is `[]` to the classifier while a bare `-z` test called it non-empty and
  # routed it to `rail`; both are "an empty contract must refuse, never route".
  local _set
  if ! _set="$(_normalise_set "${1:-}")"; then
    printf 'repo-authority: the required-check set CANNOT be normalised (python3 is required) — refusing (fail-closed)\n' >&2
    printf 'unknown\n'; return 0
  fi
  if [ -z "$_set" ]; then printf 'unknown\n'; return 0; fi
  # ⛔ round-12 review, P2. The classifier tests the gate name as ONE WHOLE TOKEN (`rgate in
  # want`), while the `case` below matches it as a SUBSTRING SPAN of the space-joined set. Those
  # agree for every single-token name and DIVERGE for a name containing whitespace: with
  # REVIEW_GATE='docs license-surface' and the set 'pipeline-compliance docs license-surface', the
  # span MATCHED (authority=gate, so the GREEN arm issued a RAW `gh pr merge`) while the classifier
  # never enforced the gate (no such TOKEN existed) — an UNREVIEWED change merges. Measured at
  # ed5ba51e. A whitespace-bearing name is not representable as one token in this space-joined
  # model, so it REFUSES rather than answering `gate`; reachable from an ambient / keys.env
  # REVIEW_GATE, which the harness otherwise does not screen.
  case "${REVIEW_GATE:-}" in
    *[[:space:]]*)
      printf 'repo-authority: REVIEW_GATE=[%s] contains whitespace — REQ is space-joined, so a name with an internal space can never be matched as ONE token by the classifier; the merge authority is UNKNOWN and nothing merges (fail-closed)\n' "${REVIEW_GATE:-}" >&2
      printf 'unknown\n'; return 0 ;;
  esac
  case " $_set " in
    *" $REVIEW_GATE "*) printf 'gate\n' ;;
    *)                  printf 'rail\n' ;;
  esac
}
