#!/usr/bin/env bash
# claims.sh — cross-box claim registry for the agent PR fleet.
# Implements agent-infra#1709 recommendations 1–3 (+ the fencing half of rec 6, + rec 4's jitter
# lives in orch-loop.sh where the poll interval is).
#
# THE PROBLEM. The harness already has a per-PR claim: `state/mergeclaim-<PR>.lock`, created
# with `set -o noclobber`. That is atomic — on ONE machine. With three boxes driving one repo
# it does nothing across boxes: three boxes pick the same PR and the same issue. The research
# (agent-infra#1709, 5 Perplexity queries, ~60 citations) is unanimous that no mechanism
# guarantees two machines never execute the same job under crashes, pauses or partitions, so
# the goal is single active ownership + safe duplicate handling (at-least-once, not
# exactly-once).
#
# WHY A GIT REF. The boxes already share exactly one durable store: the repository. Creating a
# ref with `git push` is ATOMIC — it fails if the ref already exists — so `refs/claims/<key>`
# is a genuine compare-and-swap with no new infrastructure, no broker and no service to run.
# The loser of the race sees the failure and backs off.
#
# WHY `refs/claims/*` AND NOT `refs/heads/claim/*`. As a branch it would fire
# branch-triggered workflows and clutter the branch list. `refs/claims/*` is outside the branch
# namespace and matches no `on: push:` trigger in any workflow.
#
# KEY = <PR>-<head-sha>, NOT <PR> (rec 1). Identity must be content-addressed, the same lesson
# as a Bazel/Nx cache key: two boxes reviewing the SAME head is duplicate work, a box reviewing
# a NEWER head is new work. Keying on the SHA makes the claim idempotent per content version
# and stops a pushed-update PR from being blocked by a stale claim for its predecessor head.
# This is also the defect #1709 found in the existing lock: it is keyed on <PR> alone.
#
# LEASE = DATA, NOT LIVENESS (rec 3). Git refs have no TTL and a remote owner's pid cannot be
# probed (`kill -0` is meaningless across boxes — the existing `claim_live()` relies on it).
# So the claim commit's message carries `owner` and `lease_until`; every box treats an expired
# claim as free and reclaims it with a CAS, not with a blind force.
#
# FENCING (rec 6). Every mutation after acquisition is conditional on the observed SHA of the
# claim ref (`--force-with-lease=<ref>:<sha>`). A box that lost ownership cannot release, and
# cannot reclaim, another box's claim — its writes are rejected. That is what makes a stale
# owner's write impossible rather than merely unlikely.
#
# COST. Acquisition is ONE push. `claim_snapshot()` refreshes every claim in ONE fetch per
# cycle, so the sweep never pays a network round trip per PR.

set -u

CLAIM_NS="${CLAIM_NS:-refs/claims}"
CLAIM_CACHE_NS="${CLAIM_CACHE_NS:-refs/claims-cache}"
CLAIM_TTL="${CLAIM_TTL:-1800}"   # 30 min default lease
# The repository every git call runs against. Defaults to the cwd (correct for merge-one.sh,
# which cd's into $REPO first) but the CONTROLLER must set it: orch-loop.sh runs from launchd
# with cwd=$HOME, where `git fetch` fails and the claim snapshot silently comes back empty —
# which is exactly what "snapshot lines=0 while origin had 3 live claims" looked like.
CLAIM_REPO="${CLAIM_REPO:-.}"
EMPTY_TREE=4b825dc642cb6eb9a060e54bf8d69288fbee4904
export GIT_TERMINAL_PROMPT=0

# Outputs of the last call. Globals, not stdout capture, because `$(claim_acquire …)` would run
# it in a subshell and every one of these would be discarded by the caller.
CLAIM_RESULT=""; CLAIM_COMMIT=""; CLAIM_REF=""; CLAIM_OWNER=""

# Deterministic author so claim commits do not depend on global git identity.
_git() { git -C "$CLAIM_REPO" "$@"; }
_cg() { _git -c user.name="fleet-claim" -c user.email="claims@localhost" "$@"; }

# Which box holds this. Hostname + pid, so a claim names its owner human-readably in the log.
claim_owner() { printf '%s:%s' "$(hostname -s 2>/dev/null || echo box)" "$$"; }

# claim_key <pr> <head-sha> -> "<pr>-<sha12>"   (the content address)
claim_key() { printf '%s-%s' "$1" "${2:0:12}"; }

# claim_ref <pr> <head-sha> -> "refs/claims/<pr>-<sha12>"
claim_ref() { printf '%s/%s' "$CLAIM_NS" "$(claim_key "$1" "$2")"; }

# _claim_commit <owner> <lease_until> -> commit sha carrying the lease as data
_claim_commit() {
  _cg commit-tree "$EMPTY_TREE" -m "claim owner=$1 lease_until=$2" 2>/dev/null
}

# _lease_of <ref> -> "owner lease_until" parsed from the claim commit message ("" if absent)
_lease_of() {
  local msg
  msg="$(_git cat-file commit "$1" 2>/dev/null | sed -n '/^$/,$p' | tail -n +2 | tr -d '\r')"
  local o u
  o="$(printf '%s' "$msg" | sed -n 's/.*owner=\([^ ]*\).*/\1/p')"
  u="$(printf '%s' "$msg" | sed -n 's/.*lease_until=\([0-9]*\).*/\1/p')"
  printf '%s\t%s' "${o:-?}" "${u:-0}"
}

# claim_acquire <repo> <pr> <head-sha> [ttl]
#   0 = acquired (or reclaimed an EXPIRED claim), 1 = held by a live claim, 2 = error
# Sets CLAIM_RESULT (human-readable reason), CLAIM_COMMIT, CLAIM_REF, CLAIM_OWNER.
# Echoes CLAIM_RESULT as well, so a caller in a subshell still sees the reason.
claim_acquire() {
  local repo="$1" pr="$2" sha="$3" ttl="${4:-$CLAIM_TTL}"
  local now until commit back cur tmp

  CLAIM_REF="$(claim_ref "$pr" "$sha")"
  CLAIM_OWNER="$(claim_owner)"
  now="$(date +%s)"; until=$(( now + ttl ))
  commit="$(_claim_commit "$CLAIM_OWNER" "$until")"
  if [ -z "$commit" ]; then CLAIM_RESULT="could not build claim commit"; echo "$CLAIM_RESULT"; return 2; fi

  # --- attempt 1: atomic create. Fails if the ref exists — and every claim commit is a ROOT
  #     commit, so a different claim can never fast-forward it, whatever the timing.
  if _git push -q origin "$commit:$CLAIM_REF" 2>/dev/null; then
    # rec 2: read the ref BACK rather than trusting the exit code alone.
    back="$(_git ls-remote origin "$CLAIM_REF" 2>/dev/null | awk '{print $1}')"
    if [ "$back" != "$commit" ]; then
      CLAIM_RESULT="push reported success but read-back differs ($back != $commit)"
      echo "$CLAIM_RESULT"; return 2
    fi
    CLAIM_COMMIT="$commit"
    CLAIM_RESULT="acquired $CLAIM_REF owner=$CLAIM_OWNER lease_until=$until"
    echo "$CLAIM_RESULT"; return 0
  fi

  # --- the ref exists. Read the lease (data, not liveness) and decide.
  cur="$(_git ls-remote origin "$CLAIM_REF" 2>/dev/null | awk '{print $1}')"
  if [ -z "$cur" ]; then CLAIM_RESULT="push failed and ref is unreadable (network?)"; echo "$CLAIM_RESULT"; return 2; fi
  tmp="$CLAIM_CACHE_NS/read-$RANDOM$$"
  if ! _git fetch -q origin "+$CLAIM_REF:$tmp" 2>/dev/null; then
    _git update-ref -d "$tmp" 2>/dev/null
    CLAIM_RESULT="cannot fetch the existing claim to read its lease"; echo "$CLAIM_RESULT"; return 2
  fi
  local lease held_owner held_until
  lease="$(_lease_of "$tmp")"; _git update-ref -d "$tmp" 2>/dev/null
  held_owner="${lease%%$'\t'*}"; held_until="${lease##*$'\t'}"

  if [ -z "$held_until" ] || [ "$held_until" = "0" ]; then
    CLAIM_RESULT="held by $held_owner (no parseable lease — treating as live)"
    echo "$CLAIM_RESULT"; return 1
  fi
  if [ "$now" -le "$held_until" ]; then
    CLAIM_RESULT="held by $held_owner until $held_until ($(( held_until - now ))s left)"
    echo "$CLAIM_RESULT"; return 1
  fi

  # --- expired: reclaim with a CAS on the observed value, never a blind force. If another box
  #     reclaimed it meanwhile our expected value no longer matches and we lose cleanly.
  if _git push -q --force-with-lease="$CLAIM_REF:$cur" origin "$commit:$CLAIM_REF" 2>/dev/null; then
    back="$(_git ls-remote origin "$CLAIM_REF" 2>/dev/null | awk '{print $1}')"
    if [ "$back" = "$commit" ]; then
      CLAIM_COMMIT="$commit"
      CLAIM_RESULT="reclaimed expired claim from $held_owner (was until $held_until)"
      echo "$CLAIM_RESULT"; return 0
    fi
    CLAIM_RESULT="reclaim read-back differs"; echo "$CLAIM_RESULT"; return 2
  fi
  CLAIM_RESULT="lost the reclaim race for $CLAIM_REF (another box took it)"
  echo "$CLAIM_RESULT"; return 1
}

# claim_release <repo> <pr> <head-sha> <own-commit>
# Deletes ONLY if the ref still points at our own claim (fencing, rec 6): a box that lost
# ownership cannot release the winner's claim.
claim_release() {
  local repo="$1" pr="$2" sha="$3" own="$4" ref
  ref="$(claim_ref "$pr" "$sha")"
  if [ -z "${own:-}" ]; then CLAIM_RESULT="release refused — no claim commit to fence on"; echo "$CLAIM_RESULT"; return 1; fi
  if _git push -q --force-with-lease="$ref:$own" origin ":$ref" 2>/dev/null; then
    CLAIM_RESULT="released $ref"; echo "$CLAIM_RESULT"; return 0
  fi
  CLAIM_RESULT="release refused — $ref no longer ours (fenced; another box owns it)"
  echo "$CLAIM_RESULT"; return 1
}

# claim_status <repo> <pr> <head-sha> -> "owner\tlease_until" on stdout, rc=1 if unheld
# The <repo> argument exists only for API symmetry with claim_acquire/claim_release; every git
# call uses the cwd. It must NOT be forwarded to claim_ref(), which takes (pr, sha) — forwarding
# all three built `refs/claims/.-<sha>` and made every status lookup miss.
claim_status() {
  local ref tmp cur
  ref="$(claim_ref "$2" "$3")"
  cur="$(_git ls-remote origin "$ref" 2>/dev/null | awk '{print $1}')"
  [ -n "$cur" ] || return 1
  tmp="$CLAIM_CACHE_NS/status-$RANDOM$$"
  _git fetch -q origin "+$ref:$tmp" 2>/dev/null || { _git update-ref -d "$tmp" 2>/dev/null; return 1; }
  _lease_of "$tmp"; echo
  _git update-ref -d "$tmp" 2>/dev/null
  return 0
}

# claim_snapshot [<outfile>]
# Refresh EVERY claim ref locally in ONE round trip, and write one line per claim:
#     <ref>\t<owner>\t<lease_until>
# The sweep then answers "is anyone working on this PR?" from a local file. Without this the
# controller would pay two network round trips per PR per cycle (24 PRs x 2 = 48 calls).
claim_snapshot() {
  local out="${1:-$HOME/orchestrator/state/claims-snapshot}" tmp="$1.$$"
  : > "$tmp"
  # --prune so a claim DELETED on another box (released, or pruned) does not linger here.
  _git fetch -q --prune origin "+$CLAIM_NS/*:$CLAIM_CACHE_NS/*" 2>/dev/null || true
  _git for-each-ref --format='%(refname)' "$CLAIM_CACHE_NS" 2>/dev/null | while read -r ref; do
    [ -n "$ref" ] || continue
    local lease owner until
    lease="$(_lease_of "$ref")"
    owner="${lease%%$'\t'*}"; until="${lease##*$'\t'}"
    # Emit the CLAIM namespace, not the cache namespace the fetch landed in, so a lookup with
    # claim_ref() matches. (Measured: emitting the cache ref made every lookup miss silently.)
    printf '%s\t%s\t%s\n' "${CLAIM_NS}/${ref#"$CLAIM_CACHE_NS"/}" "${owner:-?}" "${until:-0}"
  done > "$tmp"
  mv -f "$tmp" "$out" 2>/dev/null || true
}

# claim_prune — delete expired claim refs (git refs are unbounded).
claim_prune() {
  local now ref lease until owner; now="$(date +%s)"
  _git ls-remote origin "$CLAIM_NS/*" 2>/dev/null | awk '{print $2}' | while read -r ref; do
    [ -n "$ref" ] || continue
    local cur tmp
    cur="$(_git ls-remote origin "$ref" 2>/dev/null | awk '{print $1}')"
    [ -n "$cur" ] || continue
    tmp="$CLAIM_CACHE_NS/prune-$RANDOM$$"
    _git fetch -q origin "+$ref:$tmp" 2>/dev/null || continue
    lease="$(_lease_of "$tmp")"; _git update-ref -d "$tmp" 2>/dev/null
    until="${lease##*$'\t'}"
    if [ -n "$until" ] && [ "$until" != "0" ] && [ "$now" -gt "$until" ]; then
      _git push -q --force-with-lease="$ref:$cur" origin ":$ref" 2>/dev/null && echo "pruned expired $ref"
    fi
  done
}
