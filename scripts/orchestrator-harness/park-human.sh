#!/usr/bin/env bash
# park-human.sh — freeze a PR as a HUMAN decision, so the harness cannot rebase it away.
#
# THE DEFECT THIS EXISTS TO CLOSE (fresh-context review, P2, agent-infra#4126 round 7). The controller's
# `[parked-guard]` exemption has to answer ONE question about a `CONFLICTING` head: does a rebase settle
# this park? A machine park (`park_ctrl`, `merge-one.sh::park()` and its rail cap, `pr-sickness.sh`'s two
# escalations) records its author in `state/parkorigin-<PR>`, and the guard trusts that marker over the
# reason PROSE — which is what makes a new machine wording safe to add. But the counterpart had no
# producer anywhere in the repo: `git grep` found the value `human` in a test driver and in nothing that
# ships, so the human arm was unreachable. An operator who wanted to freeze a PR did the only thing
# available — `printf` the reason and the head into the state dir — which stamps NO author. The guard
# then read the machine park's own stamp (per-PR, outliving the park it described) and REBASED a head a
# human had deliberately frozen: the one direction the marker was documented never to be wrong in.
#
# WHAT IT WRITES, AND IN WHAT ORDER
#   1. `state/parkreason-<PR>`  the reason (the operator's record; the exit-5 refusals print it verbatim)
#   2. `state/parked-<PR>`      the head the park is keyed to
#   3. `state/parkorigin-<PR>`  `<head> human` — LAST, so a partial write leaves no attribution at all
#                               and the guard fails closed on the prose path instead of trusting a
#                               half-written park.
# The marker is `<head> <author>`, and a park written by hand with `printf` still lands on the guard's
# migration path: unrecognised prose => *a human decision stands* (fail closed). The residual is a
# hand-written reason at EXACTLY the head a machine park already stamped — use this tool, not `printf`.
#
# THE HEAD IS READ, NEVER GUESSED. A park keyed to the wrong head freezes nothing (the guard compares the
# stored head to the live one), so a stale head is a silent no-op. The head therefore comes from `gh` (the
# live head) or from `PARK_HEAD`, and if neither is available this tool REFUSES rather than writing a
# park that cannot work.
#
# USAGE
#   park-human.sh <pr> <reason…>
#   PARK_HEAD=<40-hex-sha>  park-human.sh <pr> <reason…>     # when gh cannot reach the API
#   PARK_REPO=<owner/repo>  …                                # when cwd is not the PR's repo
#   PARK_STATE_DIR=<dir>    …                                # the state dir itself (default: ${O:-$HOME/orchestrator}/state)
#
# ⛔ NOT A MERGE TOOL AND NOT A LIFT TOOL. Lifting a park is still `rm -f` of the pair — the recipes this
# tool prints include `parkorigin-<PR>`, because a lift that left the attribution behind would attribute
# the NEXT park at this PR (a human's) to the harness.
set -u

PROG="park-human.sh"
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 2; }

pr="${1:-}"
[ -n "$pr" ] || die "usage: $PROG <pr> <reason…>   (freezes PR <pr> as a HUMAN decision)"
shift
case "$pr" in ''|*[!0-9]*) die "PR number must be numeric, got '$pr'" ;; esac
reason="$*"
[ -n "${reason// /}" ] || die "a park needs a REASON — it is the only record of why the head is frozen (usage: $PROG <pr> <reason…>)"

# `PARK_STATE_DIR` is the STATE DIRECTORY itself (the same shape as `pr-sickness.sh::ps_state_dir`'s
# `PS_STATE_DIR`), defaulting to the controller's own layout: `O` is the orchestrator ROOT
# (orch-loop.sh:44) and the state dir is `$O/state`.
sd="${PARK_STATE_DIR:-${O:-$HOME/orchestrator}/state}"

head="${PARK_HEAD:-}"
if [ -z "$head" ]; then
  command -v gh >/dev/null 2>&1 || die "gh is not on PATH, so the LIVE head cannot be read. A park keyed to a guessed head freezes nothing — re-run as: PARK_HEAD=<the PR's full 40-char head sha> $PROG $pr \"$reason\""
  repo_args=""
  [ -n "${PARK_REPO:-}" ] && repo_args="--repo $PARK_REPO"
  # shellcheck disable=SC2086 # repo_args is either empty or exactly `--repo <slug>`
  head="$(gh pr view "$pr" ${repo_args} --json headRefOid --jq .headRefOid 2>/dev/null)" \
    || die "gh could not read PR #$pr's head${PARK_REPO:+ in $PARK_REPO} — a park keyed to a guessed head freezes nothing. Fix gh (or pass PARK_REPO=), then re-run; or: PARK_HEAD=<40-char sha> $PROG $pr \"$reason\""
fi
case "$head" in
  ''|*[!0-9a-f]*) die "the head must be a full lowercase 40-char hex sha, got '$head'. The guard compares it to the live head, so a short or uppercase one silently freezes nothing" ;;
esac
[ "${#head}" -eq 40 ] || die "the head must be the FULL 40-char sha (got '${head}', ${#head} chars) — the live head is compared verbatim, so a short sha freezes nothing"

mkdir -p "$sd" 2>/dev/null || die "cannot create the state dir '$sd'"
# reason → head → author, in that order (see the header): a failure leaves no attribution behind, and the
# tool says so instead of half-parking.
printf '%s\n' "$reason" > "$sd/parkreason-$pr" 2>/dev/null \
  || die "cannot write '$sd/parkreason-$pr' — the park did NOT land (make $sd writable)"
printf '%s\n' "$head" > "$sd/parked-$pr" 2>/dev/null \
  || die "cannot write '$sd/parked-$pr' — the park did NOT land (reason left in parkreason-$pr for the record)"
printf '%s %s\n' "$head" 'human' > "$sd/parkorigin-$pr" 2>/dev/null \
  || die "cannot write '$sd/parkorigin-$pr' — the head is parked but its AUTHOR is missing, so the guard would read the prose (fail closed) instead of the marker. Make $sd writable and re-run"

printf 'PARKED (human) #%s at head=%s\n' "$pr" "$head"
printf '  reason: %s\n' "$reason"
printf '  files:  %s/parked-%s, %s/parkreason-%s, %s/parkorigin-%s\n' "$sd" "$pr" "$sd" "$pr" "$sd" "$pr"
printf '  the conflict router will NOT rebase this head (a human decision stands).\n'
printf '  to lift it deliberately: rm -f '"'"'%s/parked-%s'"'"' '"'"'%s/parkreason-%s'"'"' '"'"'%s/parkorigin-%s'"'"'\n' "$sd" "$pr" "$sd" "$pr" "$sd" "$pr"
