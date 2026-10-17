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
# namespace and matches no `on: push:` trigger in any workflow — VERIFIED EMPIRICALLY 2026-10-14 on
# both daniel-ospina/agent-infra and daniel-ospina/tortoise: a probe push to refs/claims/* created
# zero workflow runs and zero check-runs, and every `on: push` in both repos is filtered to
# `branches: [main]` or `tags`.
#
# KEY = <PR>-<head-sha12>, NOT <PR> (rec 1). Identity must be content-addressed, the same lesson
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
# claim ref (`--force-with-lease=<ref>:<sha>`). A box holding a STALE commit — one that is no longer
# the ref's tip, because it was superseded or reclaimed — cannot release, and cannot reclaim,
# another box's claim: its write is rejected. That is what makes a stale owner's write impossible
# rather than merely unlikely.
# ⛔ The fence is on the ref's VALUE, not on ownership (P3.1, 2026-10-14 adversarial review): it
# stops a STALE write; it does NOT stop a caller who happens to pass the ref's CURRENT sha. Every
# shipped call site passes only the sha it pushed (`$CROSS_OWN` / `$CLAIM_COMMIT`), which is what
# makes the property hold in practice.
#
# COST. Acquisition is ONE push. `claim_snapshot()` refreshes every claim in ONE fetch per
# cycle, so the sweep never pays a network round trip per PR.

set -u

CLAIM_NS="${CLAIM_NS:-refs/claims}"
CLAIM_CACHE_NS="${CLAIM_CACHE_NS:-refs/claims-cache}"
# Worker-side lease-READ temp refs live in their OWN namespace, never in CLAIM_CACHE_NS.
# ⛔ `claim_snapshot` fetches with `--prune` and an explicit destination refspec, and `--prune` with
# an explicit destination prunes anything matching the DESTINATION pattern (`refs/claims-cache/*`)
# — not just refs that came from the source. The controller and the workers share ONE repo
# (CLAIM_REPO="$REPO"), so a snapshot fetch used to delete a concurrent worker's `read-…` /
# `status-…` / `prune-…` temp ref mid-read; `_lease_of` then returned "?\t0", and an unparseable
# lease is treated as LIVE, so the merge was refused while nobody owned it — every cycle
# (P2, 2026-10-14 adversarial review). Keeping temp refs out of the pruned namespace removes the
# race. If you add a temp ref anywhere below, put it under CLAIM_TMP_NS.
CLAIM_TMP_NS="${CLAIM_TMP_NS:-refs/claims-tmp}"
CLAIM_TTL="${CLAIM_TTL:-1800}"   # 30 min default lease
# ⛔ EVERY LEASE MUST BE A MAGNITUDE, NOT JUST A DIGIT STRING (P2, third review round, 2026-10-14).
# `ttl` feeds `until=$(( now + ttl ))`, and a ttl at or above 2**63 WRAPS that NEGATIVE. `_lease_of`'s
# `[0-9]*` pattern cannot parse a minus sign, so the lease reads as absent — and an absent lease is
# treated as LIVE forever (below), while `claim_prune` can never reap it (`[ "$now" -gt "-" ]` is an
# error, not a match). One bad tunable therefore froze a PR/head across ALL boxes with no automatic
# recovery: FAIL-CLOSED, the opposite of this file's stated fail-open policy. The callers validate
# their own tunables with `is_limit`; this clamps the primitive as well, so NO caller can mint an
# unprunable lease. Accept only `0` or `[1-9][0-9]*` (leading zeros are read as octal by `$(( ))`),
# at most 9 digits (9 digits + an epoch second cannot overflow).
case "${CLAIM_TTL:-}" in
  ''|*[!0-9]*|0*) CLAIM_TTL=1800 ;;
  *) [ "${#CLAIM_TTL}" -le 9 ] || CLAIM_TTL=1800 ;;
esac

# ── THE ISSUE CLAIM'S LEASE (agent-infra#1850) ────────────────────────────────────────────────
# An ISSUE claim is held for the WHOLE working period of its lane, not for one push. The PR claim's
# 1800s default covers a review+merge; the issue claim must cover the lane's own budget plus the
# chain that follows it, or it expires MID-FLIGHT, a peer reads it as free and reclaims it, and the
# duplicate dispatch this file exists to prevent happens anyway. The arithmetic, from the shipped
# defaults (orch-loop.sh's LANE_TIMEOUT is orch-loop.sh's own variable and is NOT readable here):
#
#   lane (LANE_TIMEOUT)            2400s   (~40 min — spawn-gate.sh's wall clock)
#   chain-merge.sh waits for the PR 5400s  (90 x 60s) — it exits AT ONCE when the lane recorded a
#                                           capacity refusal, releasing this claim within a poll
#                                           interval (agent-infra#1909), so the ceiling below is a
#                                           ceiling and no longer the normal cost of a refused lane
#   merge-one.sh review+merge      ~3000s  (REVIEW_TIMEOUT + the 1200s bound)
#                                 ------  =======
#                                 10800s  (3 h)
#
# ⚠️ THIS IS A CEILING, NOT A PREDICTION. The holder RELEASES on completion (chain-merge.sh, every
# exit path) and on the failure/abandon paths, so the lease only ever runs its full length when the
# box dies mid-lane. Raising LANE_TIMEOUT without raising this leaves a claim that expires before
# the lane finishes — override CLAIM_ISSUE_TTL (env, or the cell's keys.env) at the same time.
# The same digit clamp as CLAIM_TTL: an unparseable lease is worse than the default (see above).
CLAIM_ISSUE_TTL="${CLAIM_ISSUE_TTL:-10800}"
case "${CLAIM_ISSUE_TTL:-}" in
  ''|*[!0-9]*|0*) CLAIM_ISSUE_TTL=10800 ;;
  *) [ "${#CLAIM_ISSUE_TTL}" -le 9 ] || CLAIM_ISSUE_TTL=10800 ;;
esac
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
# CLAIM_OWNER_ID is a TEST SEAM (P1, 2026-10-14 export review): it lets one machine present as two
# DIFFERENT boxes, which the cross-box test needs to be a real witness. Without it both simulated
# boxes carry the same host+pid identity, so "B lost the race" proves nothing about boxing.
claim_owner() { printf '%s:%s' "${CLAIM_OWNER_ID:-$(hostname -s 2>/dev/null || echo box)}" "$$"; }

# claim_key <pr> <head-sha> -> "<pr>-<sha12>"   (the content address)
claim_key() { printf '%s-%s' "$1" "${2:0:12}"; }

# claim_ref <pr> <head-sha> -> "refs/claims/<pr>-<sha12>"
claim_ref() { printf '%s/%s' "$CLAIM_NS" "$(claim_key "$1" "$2")"; }

# ── THE ISSUE KEY: "issue-<N>", ONE REF PER ISSUE (agent-infra#1850) ──────────────────────────
# An issue has no head sha, so `claim_ref <pr> <sha>` cannot express it at all — `claim_live`
# returns 1 on an empty sha and the WHOLE registry is bypassed for issue dispatch. This is the
# keying that expresses it.
#
# ⛔ THE KEY IS THE ISSUE ALONE — NOT `issue-<N>-<box-id>`. The box id lives in the claim commit's
# `owner=` field (where it already lives for PR claims), NOT in the key, and that is load-bearing:
#   • A KEY CONTAINING THE BOX ID IS NOT A CAS. Two boxes mint two DISTINCT refs and BOTH pushes
#     succeed, so the ref can only be READ, never WON. The pre-flight read is not enough to close
#     the gap on its own: it runs BEFORE the claim, so both boxes can read CLEAN and then both
#     claim. Only a mutually-exclusive ref makes the second acquisition impossible rather than
#     merely unlikely.
#   • IDEMPOTENT FOR THE SAME WORK. One issue is one work item, so `issue-<N>` is its content
#     address exactly as `<PR>-<sha12>` is the head's: a re-acquire for the same issue lands on the
#     same ref (and is refused while the holder's lease is live), never on a fresh one.
#   • DISJOINT FROM THE PR KEY. A PR claim is `<number>-<sha12>`; the `issue-` prefix cannot collide
#     with it, so an issue claim is never blocked by — and never blocks — a PR claim for the same
#     number (`refs/claims/1850-abcdef123456` and `refs/claims/issue-1850` are different refs).
#
# ⛔ THE REF'S HOME IS THE **TARGET REPO'S** ORIGIN — the repo whose issue number is claimed, i.e.
# whatever `CLAIM_REPO` points at (the same repo the PR claims already go to). It is NOT the harness
# repo. Every would-be dispatcher of that issue already resolves `$REPO`/`--repo` to it, so it is
# the one namespace all of them read; a claim pushed into agent-infra would be invisible to a peer
# dispatching tortoise — which is exactly the 2026-10-16 collision (two cells dispatched tortoise
# issues while running the agent-infra harness).
claim_issue_key() { printf 'issue-%s' "$1"; }

# claim_issue_ref <issue> -> "refs/claims/issue-<N>"
claim_issue_ref() { printf '%s/%s' "$CLAIM_NS" "$(claim_issue_key "$1")"; }

# _claim_commit <owner> <lease_until> -> commit sha carrying the lease as data
#
# ⛔ THE NONCE IS LOAD-BEARING, NOT DECORATION (P1 in the 2026-10-14 export review). A claim commit
# is a ROOT commit whose entire content is this message, and git stamps it with the current SECOND,
# so two acquisitions with the SAME owner and the SAME lease second build a BYTE-IDENTICAL object.
# Pushing an identical commit to a ref that already holds it exits 0 ("Everything up-to-date"), the
# read-back below then matches, and the SECOND box reports `acquired` — the CAS is silently
# defeated. It does not corrupt state (it degrades to the tolerated duplicate execution and fencing
# is by the same sha), but it makes cross-box atomicity untestable, so test-claims.sh's headline
# assertion was flaky and must not be trusted as the cross-box proof. A unique object per
# acquisition turns the loser's push into a genuine non-fast-forward rejection.
_claim_commit() {
  _cg commit-tree "$EMPTY_TREE" -m "claim owner=$1 lease_until=$2 nonce=$RANDOM$RANDOM$$-$(date +%s%N)" 2>/dev/null
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
  _claim_acquire_at "$(claim_ref "$2" "$3")" "${4:-$CLAIM_TTL}"
}

# claim_issue_acquire <repo> <issue> [ttl] — the SAME CAS, keyed by ISSUE (agent-infra#1850)
# Sets CLAIM_RESULT / CLAIM_COMMIT / CLAIM_REF / CLAIM_OWNER exactly as claim_acquire does, so a
# caller that already handles rc=1 (another box owns it) and rc=2 (infra) needs no new vocabulary.
# ⛔ The `<repo>` argument is API symmetry only, like claim_status's: every git call runs against
#    CLAIM_REPO, and claim_issue_ref takes the issue alone.
claim_issue_acquire() {
  _claim_acquire_at "$(claim_issue_ref "$2")" "${3:-$CLAIM_ISSUE_TTL}" "$CLAIM_ISSUE_TTL"
}

# _claim_acquire_at <ref> [ttl] — the ref-explicit CAS core that BOTH keyings share.
# ⛔ ONE IMPLEMENTATION, TWO KEYS. A second copy of the CAS for the issue key would let the two
# drift, and every property #1709 established (atomic create, nonce, read-back, lease-as-data, CAS
# reclaim, and the infra-vs-lost-race classification) is exactly what must NOT differ between them.
_claim_acquire_at() {
  local ref="$1" ttl="$2" dflt="${3:-$CLAIM_TTL}"
  local now until commit back cur tmp perr after

  # Same bound as CLAIM_TTL above, at the ARITHMETIC SITE, because `ttl` may arrive from the caller:
  # a leased value this function cannot parse back is worse than the default lease (see the note on
  # CLAIM_TTL). Leading zeros are refused for the same reason there — `$(( 08 ))` is an octal error.
  # ⛔ THE FALLBACK IS THE KEYING'S OWN DEFAULT (`dflt`), NOT a shared literal: a bad value for an
  # ISSUE claim must not silently become the PR claim's 1800s, which is SHORTER than LANE_TIMEOUT —
  # it would expire mid-lane and hand the issue to a peer (agent-infra#1850).
  case "${ttl:-}" in
    ''|*[!0-9]*|0?*) ttl="$dflt" ;;
    0) ;;
    *) [ "${#ttl}" -le 9 ] || ttl="$dflt" ;;
  esac

  CLAIM_REF="$ref"
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
      # P2 (2026-10-14 adversarial review): the push may have CREATED the ref and only the read-back
      # failed. Surface the commit we pushed so the caller can attempt a FENCED release — otherwise
      # the claim is orphaned for the whole lease (up to REVIEW_TIMEOUT+1200 = 50 min) and every box
      # refuses that head until it expires. merge-one.sh consumes CLAIM_COMMIT on rc=2.
      CLAIM_COMMIT="$commit"
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
  tmp="$CLAIM_TMP_NS/read-$RANDOM$$"
  if ! _git fetch -q origin "+$CLAIM_REF:$tmp" 2>/dev/null; then
    _git update-ref -d "$tmp" 2>/dev/null
    CLAIM_RESULT="cannot fetch the existing claim to read its lease"; echo "$CLAIM_RESULT"; return 2
  fi
  local lease held_owner held_until
  lease="$(_lease_of "$tmp")"; _git update-ref -d "$tmp" 2>/dev/null
  held_owner="${lease%%$'\t'*}"; held_until="${lease##*$'\t'}"

  # ⛔ AN OVERSIZED BUT NUMERIC LEASE IS ALSO UNPARSEABLE (P3, third review round, 2026-10-14). A
  # value at or above 2**63 makes `[ "$now" -le "$held_until" ]` ERROR (rc=2, test FALSE), so control
  # fell through to the RECLAIM CAS and STOLE a claim this code means to treat as live. The "no
  # parseable lease" branch below covers an absent value; it did not cover one a foreign or older
  # writer minted at full width. Bound the digits BEFORE the comparison, exactly as the writer side
  # now does. Not reachable from the shipped writers (they clamp), so this is defence in depth.
  #
  # ⛔ THE BOUND IS 18 DIGITS, NOT 9. The review finding asked for "longer than 9 digits", but
  # `lease_until` is an EPOCH SECOND, which is 10 digits TODAY (`date +%s` = 1792001642) — a 9-digit
  # bound would call every legitimate lease unparseable and treat it as LIVE forever, so no claim
  # would ever expire or be reclaimed (a fleet-wide fail-closed, and test-claims.sh's expiry steps
  # go RED). The overflow threshold is 2**63-1 = 9223372036854775807 (19 digits): 18 digits max is
  # 999999999999999999 < 2**63, so the comparison cannot error. Rejecting 19+ digits is therefore the
  # precise magnitude guard — and it is the CONSERVATIVE direction (a foreign full-width lease reads
  # as live, never as stolen).
  if [ -z "$held_until" ] || [ "$held_until" = "0" ] || [ "${#held_until}" -gt 18 ]; then
    CLAIM_RESULT="held by $held_owner (no parseable lease — treating as live)"
    echo "$CLAIM_RESULT"; return 1
  fi
  if [ "$now" -le "$held_until" ]; then
    CLAIM_RESULT="held by $held_owner until $held_until ($(( held_until - now ))s left)"
    echo "$CLAIM_RESULT"; return 1
  fi

  # --- expired: reclaim with a CAS on the observed value, never a blind force. If another box
  #     reclaimed it meanwhile our expected value no longer matches and we lose cleanly.
  if perr="$(_git push -q --force-with-lease="$CLAIM_REF:$cur" origin "$commit:$CLAIM_REF" 2>&1)"; then
    back="$(_git ls-remote origin "$CLAIM_REF" 2>/dev/null | awk '{print $1}')"
    if [ "$back" = "$commit" ]; then
      CLAIM_COMMIT="$commit"
      CLAIM_RESULT="reclaimed expired claim from $held_owner (was until $held_until)"
      echo "$CLAIM_RESULT"; return 0
    fi
    CLAIM_COMMIT="$commit"   # may have landed; the caller can attempt a fenced release
    CLAIM_RESULT="reclaim read-back differs ($back != $commit)"
    echo "$CLAIM_RESULT"; return 2
  fi
  # ⛔ The push failed. DISTINGUISH "I lost the race" from "the remote was unreachable" (P2,
  # 2026-10-14 adversarial review). The CREATE path already does this; the reclaim path used to call
  # EVERY non-zero exit a lost race (stderr discarded), so `merge-one.sh` logged "another box owns
  # head" and exited 0 on a transient network failure — FAIL-CLOSED, the opposite of the stated
  # policy. Re-read the ref: a DIFFERENT sha = genuine lost race (rc=1); unchanged at `$cur`, or
  # unreadable, = infrastructure failure (rc=2 → fail-open).
  after="$(_git ls-remote origin "$CLAIM_REF" 2>/dev/null | awk '{print $1}')"
  perr="$(printf '%s' "${perr:-}" | tr '\n' ' ' | cut -c1-200)"
  if [ "$after" = "$commit" ]; then
    # the push landed despite its non-zero exit; the read-back is the authority.
    CLAIM_COMMIT="$commit"
    CLAIM_RESULT="reclaimed expired claim from $held_owner (was until $held_until; push exited non-zero but the ref is ours)"
    echo "$CLAIM_RESULT"; return 0
  fi
  if [ -z "$after" ] || [ "$after" = "$cur" ]; then
    # ⛔ Set CLAIM_COMMIT BEFORE this return (P2, second review round, 2026-10-14). The push exited
    # non-zero, but it may have LANDED and only the immediate re-read failed (`after` is unreadable
    # in exactly that window). Returning 2 without the commit left merge-one.sh's
    # `if [ -n "${CLAIM_COMMIT:-}" ]` false, so it never attempted the fenced release — and the box
    # PROCEEDED fail-open while genuinely owning the ref, so every other box refused that head until
    # the lease expired (up to REVIEW_TIMEOUT+1200 = 50 min). Safe to set unconditionally: the
    # fenced release is a no-op when the ref is still `$cur` (the lease does not match), so it can
    # never delete another box's claim.
    CLAIM_COMMIT="$commit"
    CLAIM_RESULT="reclaim push failed and $CLAIM_REF is ${after:-unreadable} (still $cur) — infrastructure failure, not a lost race: ${perr:-no stderr}"
    echo "$CLAIM_RESULT"; return 2
  fi
  CLAIM_RESULT="lost the reclaim race for $CLAIM_REF (another box took it: $cur -> $after)"
  echo "$CLAIM_RESULT"; return 1
}

# claim_release <repo> <pr> <head-sha> <own-commit>
# Deletes ONLY if the ref still points at <own-commit> (fencing, rec 6). A box holding a STALE
# commit — its claim was superseded or reclaimed — cannot release the winner's claim.
# ⛔ The fence is on the ref's VALUE, not on ownership (P3.1, 2026-10-14 adversarial review): it
# refuses a STALE commit; it does not refuse a caller who passes the ref's CURRENT sha. Shipped call
# sites pass only the sha they pushed.
claim_release() {
  # `"${3:-}"` as well as `"${4:-}"`: an arity slip (repo + PR only) must not abort the caller
  # under `set -u` either. Both missing arguments land on the documented refusal inside the core,
  # which pushes NOTHING — so a mis-called release stays a refusal, never a blind delete.
  _claim_release_at "$(claim_ref "${2:-}" "${3:-}")" "${4:-}"
}

# claim_issue_release <repo> <issue> [<own-commit>] — fenced release of an ISSUE claim (#1850).
# Same fence and same reason strings as claim_release, so a stale holder cannot delete a winner's
# issue claim either.
claim_issue_release() {
  _claim_release_at "$(claim_issue_ref "${2:-}")" "${3:-}"
}

# _claim_release_at <ref> [<own-commit>]
# ⛔ `own` IS READ WITH `:-`, AND THAT IS A FIX, NOT STYLE (agent-infra#1850). The PR-keyed wrapper
# used to read `$4` BARE while `set -u` is on, so a three-argument call — a caller that has no
# commit to fence on, which is exactly what a refused or half-completed acquire leaves it with —
# aborted the caller with `line 260: $4: unbound variable` (measured on the release path). A
# release that ERRORS leaves the claim held until the lease expires, and for an ISSUE claim that is
# up to three hours of a free issue no box will dispatch: the failure this check exists to prevent.
_claim_release_at() {
  local ref="$1" own="${2:-}"
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
  _claim_status_at "$(claim_ref "$2" "$3")"
}

# claim_issue_status <repo> <issue> -> "owner\tlease_until", rc=1 if unheld (#1850)
claim_issue_status() {
  _claim_status_at "$(claim_issue_ref "$2")"
}

_claim_status_at() {
  local ref="$1" tmp cur
  cur="$(_git ls-remote origin "$ref" 2>/dev/null | awk '{print $1}')"
  [ -n "$cur" ] || return 1
  tmp="$CLAIM_TMP_NS/status-$RANDOM$$"
  _git fetch -q origin "+$ref:$tmp" 2>/dev/null || { _git update-ref -d "$tmp" 2>/dev/null; return 1; }
  _lease_of "$tmp"; echo
  _git update-ref -d "$tmp" 2>/dev/null
  return 0
}

# claim_issue_preflight <issue> — THE PRE-FLIGHT'S REGISTRY READ (agent-infra#1850)
#   0 CLEAN      — no issue claim is visible: the issue may be certified dispatchable
#   1 COLLISION  — a LIVE claim is held (or one whose lease is unreadable, which claim_acquire also
#                  treats as live): another box owns this issue
#   2 INCOMPLETE — the registry could NOT be read. NEVER a CLEAN: a registry outage must not become
#                  a duplicate dispatch (#1850). This is the fail-CLOSED direction, and it is
#                  deliberately the opposite of claim_acquire's infra rc=2 (which fails OPEN so a
#                  merge is not refused by a network blip): there, refusing costs one PR's merge;
#                  here, certifying a free issue costs duplicated work on two boxes.
# Sets CLAIM_RESULT; echoes it, so a caller in a subshell still sees the reason.
claim_issue_preflight() {
  local issue="$1" ref out rc cur tmp lease owner until now
  ref="$(claim_issue_ref "$issue")"
  # ⛔ THE EXIT STATUS IS THE DISTINCTION THAT MATTERS HERE. `git ls-remote <ref>` exits 0 with
  # EMPTY output when the ref simply does not exist, and NON-ZERO only when the remote itself could
  # not be consulted (measured: rc=128 for an unreachable remote). Collapsing the two — which is
  # what a bare `[ -n "$(…)" ]` does — reads an outage as "nobody holds it", which is the exact
  # false CLEAN this gate exists to remove.
  out="$(_git ls-remote origin "$ref" 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    CLAIM_RESULT="the claim registry is UNREADABLE ($ref: git ls-remote exited $rc) — INCOMPLETE, never CLEAN"
    echo "$CLAIM_RESULT"; return 2
  fi
  cur="$(printf '%s\n' "$out" | awk '{print $1}')"
  if [ -z "$cur" ]; then
    CLAIM_RESULT="no claim on #$issue"
    echo "$CLAIM_RESULT"; return 0
  fi
  tmp="$CLAIM_TMP_NS/pre-$RANDOM$$"
  if ! _git fetch -q origin "+$ref:$tmp" 2>/dev/null; then
    _git update-ref -d "$tmp" 2>/dev/null
    CLAIM_RESULT="a claim ref exists for #$issue but its lease could not be read — INCOMPLETE, never CLEAN"
    echo "$CLAIM_RESULT"; return 2
  fi
  lease="$(_lease_of "$tmp")"; _git update-ref -d "$tmp" 2>/dev/null
  owner="${lease%%$'\t'*}"; until="${lease##*$'\t'}"
  # ⛔ THE SAME UNPARSEABLE-IS-LIVE POLARITY AS claim_acquire(). An absent lease, the `0` sentinel,
  # a negative, or an oversized value all mean "a claim EXISTS whose lease this reader cannot
  # parse" — never "free". Reading any of them as free would steal a live claim, and the fourth
  # reader (orch-loop.sh's claim_live) already agrees on this datum; a fifth polarity would be a
  # new disagreement about the same fact.
  if [ -z "$until" ] || [ "$until" = "0" ] || [ -n "${until//[0-9]/}" ] || [ "${#until}" -gt 18 ]; then
    CLAIM_RESULT="a claim on #$issue is held by ${owner:-?} (lease unreadable — treated as live)"
    echo "$CLAIM_RESULT"; return 1
  fi
  now="$(date +%s)"
  if [ "$now" -le "$until" ]; then
    CLAIM_RESULT="a claim on #$issue is held by ${owner:-?} until $until ($(( until - now ))s left)"
    echo "$CLAIM_RESULT"; return 1
  fi
  CLAIM_RESULT="the only claim on #$issue EXPIRED at $until (was ${owner:-?}) — free to reclaim"
  echo "$CLAIM_RESULT"; return 0
}

# ── THE ISSUE CLAIM'S RELEASE RECORD (agent-infra#1850) ───────────────────────────────────────
# The claim is taken by `orch-loop.sh` and released by whichever process ends up owning the END of
# the work: `chain-merge.sh` (its EXIT trap — the normal path) or `dispatch-merge.sh` (the path that
# decides NOT to spawn a chain, so no trap will ever run). Neither of those is the process that
# ACQUIRED the claim, so the commit it pushed — the only thing `--force-with-lease` can be keyed on
# — has to be handed over. It is handed over in `$O/state/issueclaim-<N>`.
# ⛔ THE FORMAT LIVES HERE, BESIDE THE FENCE IT FEEDS, so there is ONE writer convention and ONE
# reader implementation. Two copies of this is how a reader and a writer of the same datum drift,
# and the drift is silent: a record nobody can parse releases nothing and the claim runs to its
# lease instead (3h of a free issue).

# claim_issue_record <state-dir> <issue> <own-commit> -> 0 written, 1 nothing to record (#1850)
# ⛔ REFUSES AN EMPTY COMMIT rather than writing an empty file: an empty record is indistinguishable
# from a corrupt one, and it can never fence anything.
claim_issue_record() {
  local dir="${1:-$HOME/orchestrator}" issue="${2:-}" own="${3:-}"
  [ -n "$own" ] || return 1
  [ -n "$issue" ] || return 1
  mkdir -p "$dir/state" 2>/dev/null || true
  printf '%s\n' "$own" > "$dir/state/issueclaim-$issue" 2>/dev/null || return 1
  return 0
}

# claim_issue_release_record <state-dir> <repo> <issue> -> claim_issue_release's status (1 = refused
# or nothing to do). Removes the record in EVERY case: an empty or unreadable record can never fence
# a release, so leaving it behind makes every later attempt re-read a dead file.
claim_issue_release_record() {
  local f="${1:-$HOME/orchestrator}/state/issueclaim-${3:-}" own
  [ -f "$f" ] || return 1
  own="$(cat "$f" 2>/dev/null || true)"
  rm -f "$f" 2>/dev/null
  [ -n "$own" ] || return 1
  claim_issue_release "${2:-}" "${3:-}" "$own"
}

# claim_snapshot [<outfile>]
# Refresh EVERY claim ref locally in ONE round trip, and write one line per claim:
#     <ref>\t<owner>\t<lease_until>
# The sweep then answers "is anyone working on this PR?" from a local file. Without this the
# controller would pay two network round trips per PR per cycle (24 PRs x 2 = 48 calls).
claim_snapshot() {
  # `$1` is OPTIONAL and `set -u` is on, so the temp name must NOT be built from it directly:
  # `local out="${1:-…}" tmp="$1.$$"` dereferences the unset `$1` and aborts the whole fetch with
  # "unbound variable" (exit 127) instead of falling back to the default (P2, 2026-10-14 export
  # review). Derive the temp name from the RESOLVED output path.
  local out="${1:-$HOME/orchestrator/state/claims-snapshot}"
  local tmp="$out.$$"
  : > "$tmp"
  # --prune so a claim DELETED on another box (released, or pruned) does not linger here.
  # ⛔ It prunes by DESTINATION pattern, so worker-side temp refs must live in CLAIM_TMP_NS, never
  # under CLAIM_CACHE_NS — a snapshot must not delete a concurrent lease read (P2).
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

# claim_prune — delete expired claim refs (git refs are unbounded), and reap LEAKED temp refs.
claim_prune() {
  local now ref lease until owner; now="$(date +%s)"
  _git ls-remote origin "$CLAIM_NS/*" 2>/dev/null | awk '{print $2}' | while read -r ref; do
    [ -n "$ref" ] || continue
    local cur tmp
    cur="$(_git ls-remote origin "$ref" 2>/dev/null | awk '{print $1}')"
    [ -n "$cur" ] || continue
    tmp="$CLAIM_TMP_NS/prune-$RANDOM$$"
    _git fetch -q origin "+$ref:$tmp" 2>/dev/null || continue
    lease="$(_lease_of "$tmp")"; _git update-ref -d "$tmp" 2>/dev/null
    until="${lease##*$'\t'}"
    # The same 18-digit bound as claim_acquire's live check: a 19+ digit lease can error `[` (2**63),
    # and the safe reading of an unreadable lease is "still live, do not reap". The explicit bound
    # also keeps an ignored `[` error from being relied on as control flow. (10 digits is a REAL
    # epoch second — see the note in claim_acquire; do not tighten this to 9.)
    if [ -n "$until" ] && [ "$until" != "0" ] && [ "${#until}" -le 18 ] && [ "$now" -gt "$until" ]; then
      _git push -q --force-with-lease="$ref:$cur" origin ":$ref" 2>/dev/null && echo "pruned expired $ref"
    fi
  done

  # ── leaked CLAIM_TMP_NS refs (P3.4, second review round, 2026-10-14) ─────────
  # Every lease READ/STATUS creates a local ref here and deletes it with `update-ref -d`. A SIGKILL,
  # a Ctrl-C or a reboot between the fetch and the delete leaks that ref FOREVER: it is local-only,
  # so no `ls-remote` sweep can ever see it, and this namespace was unbounded until now.
  # ⛔ The age is the REF FILE's mtime — when THIS box wrote the ref — NOT the claim commit's date.
  # The commit may be minutes old while the read ref was created a second ago, so a commit-date bound
  # would delete the ref underneath a LIVE concurrent read; `_lease_of` would then return "?\t0"
  # (unparseable = treated as LIVE) and the merge would be falsely refused — the exact race this
  # namespace exists to avoid. A read takes seconds, so a 2-hour bound cannot touch a live one.
  _git for-each-ref --format='%(refname)' "$CLAIM_TMP_NS" 2>/dev/null | while read -r ref; do
    [ -n "$ref" ] || continue
    local tpath gdir
    # ⛔ Resolve the ref FILE absolutely. Plain `--git-path` can return a path relative to the REPO
    # ROOT (measured: `git -C /tmp/r rev-parse --git-path refs/x` -> `.git/refs/x` even from another
    # cwd), so prefixing the GIT DIR resolves `.git/.git/refs/...` and the file is never found —
    # the reaper then no-ops silently. `--path-format=absolute` (git >= 2.31) is authoritative; the
    # fallback (`<gitdir>/<ref>`) is correct for the non-worktree repos these scripts run in, and an
    # empty result skips the ref rather than guessing.
    tpath="$(_git rev-parse --path-format=absolute --git-path "$ref" 2>/dev/null)"
    if [ -z "$tpath" ]; then
      gdir="$(_git rev-parse --absolute-git-dir 2>/dev/null)"
      [ -n "$gdir" ] || continue
      tpath="$gdir/$ref"
    fi
    [ -e "$tpath" ] || continue
    # NOTE the `[ -n "$(find ...)" ]` form: `find <file> -mmin +N` exits 0 whether or not it
    # matches, so a bare `find ... && echo` would reap EVERY temp ref, live ones included.
    if [ -n "$(find "$tpath" -mmin +120 2>/dev/null)" ]; then
      _git update-ref -d "$ref" 2>/dev/null && echo "pruned leaked temp ref $ref"
    fi
  done
}
