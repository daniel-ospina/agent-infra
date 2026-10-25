#!/usr/bin/env bash
# shard: off a live-origin loop proof, not a CI suite: it drives the claim CAS against a real (bare) origin from scratch repos. `spawn-gate.test.sh` pins the unwired population to exactly {this, test-crossbox.sh}
# test-claims.sh — prove the git-ref CAS claim is real, using TWO independent scratch repositories
# (`git init` + `remote add origin <bare repo>`) as stand-ins for two boxes. Not a mock: both talk to
# the live origin.
#
# Properties under test (the ones agent-infra#1709 says decide the design):
#   1  atomic create          — the second box must LOSE, not race-and-both-win
#   1b nonce UNIQUENESS       — two same-owner, same-second acquisitions build DIFFERENT objects and
#                               the second LOSES; a presence check for `nonce=` cannot fail on a
#                               CONSTANT nonce (measured: it stayed green on `nonce=CONSTANT`)
#   2  read-back confirmation — success is confirmed from the remote, not the exit code
#   2a read-back failure      — the CREATE path surfaces the commit it pushed, so a read-back failure
#                               does not orphan a claim its creator can never release
#   2b reclaim classification — a failed reclaim push is infra (rc=2, fail-open) only when the ref is
#                               unchanged or unreadable; a MOVED ref is still a real lost race (rc=1)
#   2c status + snapshot      — a lookup by claim_ref() must MATCH (regression: it built
#                               refs/claims/.-<sha> and every lookup missed silently)
#   2c snapshot isolation     — a snapshot fetch must not `--prune` a concurrent worker's temp ref
#   3  lease is data          — an expired claim is free; a live one is not
#   6  fencing                — a STALE commit cannot release the winner's claim; the fence is on the
#                               ref's value, so the test offers a REAL other claim's sha (not a random
#                               one, which would pass with no fencing at all)
#
# ISSUE-KEYED CLAIMS (agent-infra#1850) — the sections prefixed `I`. An issue has no head sha, so
# the PR key cannot express it and the whole registry was bypassed for ISSUE dispatch; two boxes
# pointed at the same repo both read CLEAN and both dispatched the same issue. The properties these
# tests pin, and the specific way each one is RED before the change:
#   I1  TWO BOXES, SAME **UN-PUSHED** ISSUE — A claims, B's pre-flight read must NOT be CLEAN. ⛔ No
#       branch and no PR is pushed anywhere in this section: the defect is invisible-to-git work, so
#       a test that only passes after a push does not test it. On the pre-change claims.sh
#       `claim_issue_preflight` does not exist at all, so this section fails with rc=127.
#   I2  the CAS, not just the read — B must LOSE the acquire (rc=1, told who holds it)
#   I3  DISJOINT FROM THE PR KEY — a PR claim for the SAME NUMBER must neither block nor be blocked
#   I4  an expired issue claim is free; the reclaim is a CAS and the loser's FENCED release cannot
#       delete the winner's — `CLAIM_TTL` expiry and fencing hold for the issue key
#   I5  the RELEASE path does not ERROR under `set -u` — `claim_release` with three arguments raised
#       `$4: unbound variable` (a release that errors leaves the claim held to the lease), and
#       `claim_issue_release` with two arguments raised `$3:`; both must reach the documented
#       refusal instead. This is the incidental defect the #1850 verification found.
#   I6  claim_issue_status reports the lease; an UNREADABLE lease reads as LIVE; a claim ref whose
#       lease cannot be read is never stolen and never reported CLEAN by the pre-flight
#   I7  an abandoned claim DECAYS — claim_prune reaps the expired issue ref (the release path for a
#       box that died mid-lane)
#   I8  an UNREACHABLE registry is INCOMPLETE (rc=2), never CLEAN — a registry outage must not
#       become a duplicate dispatch
#   I9  the RELEASE RECORD (the handover of the pushed commit, from the acquiring process to the one
#       that releases): it refuses an empty commit, releases fenced through the record, is a no-op
#       when the record is missing, and an EMPTY record can never delete a PEER's claim
#
# ORDER MATTERS: every step that changes the holder must finish before the next step captures
# the ref sha, or the later assertions compare against a claim that no longer exists.
#
# SELF-CONTAINED (P2 in the 2026-10-14 export review): the two "boxes" are created here as fresh
# repos whose origin is THIS harness's origin, and the claims.sh under test is the one beside this
# file — not `~/orchestrator/claims.sh` and not a hard-coded /Users/home path. The claim refs are
# written to the REAL origin: that is deliberate (a CAS needs a genuinely shared ref) and safe —
# VERIFIED EMPIRICALLY 2026-10-14 on both daniel-ospina/agent-infra and daniel-ospina/tortoise: a
# probe push to refs/claims/* created zero workflow runs and zero check-runs (every `on: push` in
# both repos is filtered to `branches: [main]` or `tags`). Their deletion is now in the trap,
# fenced, on EXIT/INT/TERM.
#
# ⛔ STILL NOT THE CROSS-BOX PROOF. Both "boxes" share one machine, so this cannot witness the
# three-box fleet. What it does pin is the CAS primitive: the second acquirer LOST, and — with the
# P1b discriminator below — the two acquisitions built DIFFERENT objects. Before the nonce, two
# acquisitions in the same second produced byte-identical commits, the second push exited 0 as
# "up-to-date", and the suite passed anyway. Set the nonce to a constant today and P1b goes RED.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ⛔ OVERRIDABLE, because the non-vacuity claim in this file is only worth what it can be SHOWN to
# be: `CLAIMS_SH=<a copy of the pre-change claims.sh> bash test-claims.sh` must FAIL the `I`
# sections, and it cannot if the path is hardcoded. See the header of section I1.
CLAIMS_SH="${CLAIMS_SH:-$HERE/claims.sh}"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
ORIGIN_URL="$(git -C "$REPO_ROOT" remote get-url origin)"
[ -f "$CLAIMS_SH" ] || { echo "❌ missing $CLAIMS_SH"; exit 2; }
[ -n "$ORIGIN_URL" ] || { echo "❌ $REPO_ROOT has no origin remote"; exit 2; }

# Two boxes = two repos sharing one origin. Fresh `git init` + `remote add` (no clone) is enough:
# a claim is a root commit pushed by sha, so neither box needs any history.
A="/tmp/xb-claims-boxa.$$"
B="/tmp/xb-claims-boxb.$$"
SNAP="/tmp/xb-claims-snap.$$"
rm -rf "$A" "$B" "$SNAP" 2>/dev/null
mkdir -p "$A" "$B"
git -C "$A" init -q && git -C "$A" remote add origin "$ORIGIN_URL"
git -C "$B" init -q && git -C "$B" remote add origin "$ORIGIN_URL"
cleanup_boxes() { rm -rf "$A" "$B" "$SNAP" "${CWD_TMP:-}" 2>/dev/null; }
# ⛔ Remote refs are NOT inside the temp dirs. This suite writes claim refs to LIVE origin on purpose
# (a CAS needs a genuinely shared ref), and a Ctrl-C/kill/abort used to leave them orphaned there —
# the EXIT trap cleaned local dirs only. Delete the remote refs best-effort (fenced), and cover INT
# and TERM as well as EXIT (P3.2, 2026-10-14 adversarial review).
cleanup_remote() {
  local ref cur
  # ⛔ NOT `${ISSUE_REF}`: `issue-<N>` is the one key whose identity is the NUMBER ALONE, so an
  # observed-tip fence can delete a peer's claim (see cleanup_issue_ref). It is handled there, fenced
  # on OUR commit from $OWN_LOG. The sha12-suffixed keys below cannot collide that way.
  for ref in "${REF:-}" "${OTHER_REF:-}" "${PRNUM_REF:-}" "${CWD_REF:-}"; do
    [ -n "$ref" ] || continue
    cur="$(git -C "$A" ls-remote origin "$ref" 2>/dev/null | awk '{print $1}')"
    [ -n "$cur" ] && git -C "$A" push -q --force-with-lease="$ref:$cur" origin ":$ref" 2>/dev/null
  done
  return 0
}
cleanup_all() { # ⛔ the ISSUE and PROBE refs are cleaned HERE too (adversarial round 2): with
  # ISSUE_REF removed from cleanup_remote (it cannot be deleted on an observed-tip fence), an aborted
  # run would otherwise leave a LIVE claim on the production origin. Both are ownership-checked, so
  # adding them here is safe; the guards keep `set -u` from aborting the trap before the temp dirs go.
  trap - EXIT INT TERM
  cleanup_remote
  [ -n "${ISSUE_REF:-}" ] && [ -n "${ISSUE:-}" ] && cleanup_issue_ref
  [ -n "${PROBE_REF:-}" ] && [ -n "${probe_own:-}" ] && \
    git -C "$A" push -q --force-with-lease="$PROBE_REF:$probe_own" origin ":$PROBE_REF" 2>/dev/null
  cleanup_boxes; }
trap cleanup_all EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Run a claims.sh command AS one box. The per-box CLAIM_OWNER_HOST is what makes the two stand-ins
# two boxes: without it both carry the same host+pid owner, so "B lost the race" is not evidence.
runA() { ( cd "$A" && export CLAIM_OWNER_HOST=boxA && . "$CLAIMS_SH" && "$@" ); }
runB() { ( cd "$B" && export CLAIM_OWNER_HOST=boxB && . "$CLAIMS_SH" && "$@" ); }

# cleanup_ref for the ISSUE ref, so the I sections cannot leak an issue claim onto live origin even
# if the suite aborts mid-way (the EXIT trap covers the variables it can see; these are belt-and-braces
# for a Ctrl-C between sections).
# ⛔ WHOSE CLAIM IS IT? A LEASE ON THE OBSERVED TIP IS NOT AN OWNERSHIP CHECK:
# `--force-with-lease=<ref>:<observed>` is a conditional WRITE — it refuses only if the ref moves in
# the microseconds between the `ls-remote` and the push — so fencing on the observed tip deletes
# whatever is there, and `$A` is wired to the LIVE origin. The adversarial review reproduced exactly
# that: a peer's live claim deleted on a scratch origin, reachable with the documented `ISSUE=`
# override, a `PR`/`ISSUE` bump, or an unreadable registry read as "unclaimed".
# The registry itself carries the ownership evidence: every lease's owner is `<id>:<pid>`, the suite
# runs all of its box identities from ONE process, and a peer box is a DIFFERENT pid. So a claim is
# this run's iff its lease names our pid — which also covers the synthetic `expiredbox` leases the
# sections push by hand, and covers every acquire path (`runA`, `runB`, and the direct subshells)
# without a per-call-site log that a new section can silently miss.
_owned_by_this_run() { # -> 0 if the lease on $ISSUE_REF names THIS process
  local st who
  [ -n "${ISSUE:-}" ] || return 1
  # claim_issue_status takes (repo, issue) — the repo argument exists only for API symmetry, and
  # omitting it trips `set -u` inside claims.sh, which reads as "not ours" and silently disables every
  # teardown (measured: that is exactly how the first draft of this guard failed).
  st="$( cd "$A" && . "$CLAIMS_SH" && claim_issue_status "$A" "$ISSUE" 2>/dev/null )" || return 1
  who="${st%%	*}"
  # Two shapes of owner appear here: leases claims.sh wrote (`boxA:<pid>`) and leases the sections
  # hand-build with `_claim_commit expiredbox …`, which carry NO pid at all. An owner with no pid is
  # ours only if it is one of the suite's own synthetic ids — a real peer never uses them.
  case "$who" in
    # the synthetic ids the sections hand-build leases with (`_claim_commit foreignbox 0` etc):
    # this suite planted them, so deleting them is not destroying a peer's claim
    # ⛔ THIS IS SAFE ONLY BECAUSE `claim_owner` ALWAYS APPENDS `:<pid>` — it prints
    # `<claim_host>:$$` (`printf '%s:%s' "$host" "$$"`), where `claim_host` is `CLAIM_OWNER_HOST` when
    # that seam is set and `hostname -s` otherwise. A real peer lease is therefore never these exact
    # tokens. If that format ever loses the pid, this whitelist starts deleting other boxes' claims —
    # pin the format, not just this list.
    expiredbox|foreignbox|twin|probe|proberef|boxA|boxB) return 0 ;;
  esac
  case "${who##*:}" in ''|*[!0-9]*) return 1 ;; esac
  [ "${who##*:}" = "$$" ]
}
cleanup_issue_ref() {
  local cur; [ -n "${ISSUE_REF:-}" ] || return 0
  cur="$(git -C "$A" ls-remote origin "$ISSUE_REF" 2>/dev/null | awk '{print $1}')"
  [ -n "$cur" ] || return 0
  if _owned_by_this_run; then
    git -C "$A" push -q --force-with-lease="$ISSUE_REF:$cur" origin ":$ISSUE_REF" 2>/dev/null
  else
    echo "  ⚠️ $ISSUE_REF is not this run's claim (no lease naming pid $$) — leaving it alone"
  fi
  return 0
}

# A pass-through for the `_git` failure seams below. ⛔ NOT a plain `git`-with-a-positional-args
# wrapper: the fleet's checkout guard statically classifies an unresolved git VERB (a positional
# parameter used as the verb) as an unverifiable working-tree discard and fails closed, which refused
# to even RUN this suite (`bash test-claims.sh` — guard form `unverifiable-verb`). Writing each
# delegated verb LITERALLY keeps the seam statically visible, so the guard can verify it is not a
# discard, and the suite runs. The verb set is exactly what claims.sh's `_git` call sites use.
_git_delegate() { # <git-args...> — dispatch the VERB literally so the guard can classify it
  local a1="${1:-}" a2="${2:-}" a3="${3:-}" a4="${4:-}" v
  # `_cg` prefixes the deterministic author identity (`-c user.name=… -c user.email=… <verb> …`),
  # so the verb is the 5th token in that shape and the 1st otherwise.
  if [ "$a1" = "-c" ] && [ "$a3" = "-c" ]; then v="${5:-}"; shift 5 2>/dev/null || true
  else v="$a1"; shift 2>/dev/null || true; fi
  case "$v" in
    commit-tree)  command git -C "$CLAIM_REPO" -c "$a2" -c "$a4" commit-tree "$@" ;;
    push)         command git -C "$CLAIM_REPO" push "$@" ;;
    ls-remote)    command git -C "$CLAIM_REPO" ls-remote "$@" ;;
    fetch)        command git -C "$CLAIM_REPO" fetch "$@" ;;
    cat-file)     command git -C "$CLAIM_REPO" cat-file "$@" ;;
    update-ref)   command git -C "$CLAIM_REPO" update-ref "$@" ;;
    for-each-ref) command git -C "$CLAIM_REPO" for-each-ref "$@" ;;
    rev-parse)    command git -C "$CLAIM_REPO" rev-parse "$@" ;;
    *) echo "_git_delegate: unexpected git invocation '${v:-}'" >&2; return 2 ;;
  esac
}

# ⛔ THE KEYS ARE PER-RUN, NOT FIXED (2026-10-16 review). The same finding was raised in PR #1749's
# review and not taken then. Two concurrent runs of this suite used to collide on ONE set of refs in
# the PRODUCTION `refs/claims` namespace on the LIVE origin: each run's teardown deletes refs the
# other run is mid-CAS on, so a GREEN suite reported 15–19 false failures (measured with two
# simultaneous runs; three sequential runs of the same head gave 11/4/0). The fleet routinely runs
# several reviewers of one PR at once, and a false red from THIS suite blocks a merge.
# A random key per run isolates them while keeping the SHIPPED namespace and key shape under test —
# a namespaced ref would stop exercising `refs/claims/issue-<N>` and `refs/claims/<pr>-<sha12>`
# themselves. Override for a reproducible run: `PR=… ISSUE=… bash test-claims.sh`.
PR="${PR:-$(( (RANDOM << 15 | RANDOM) % 900000 + 100000 ))}"
# ⛔ THE ISSUE KEY IS A BARE NUMBER, SO IT MUST BE UNCLAIMED WHEN THE RUN STARTS (cycle-2 adversarial
# review). Every other key here also carries a fixed sha12 that no live claim can match; `issue-<N>`
# is the one ref whose identity is the number ALONE — and the teardown FORCE-DELETES it. If a repo's
# issue numbers ever reached this band, teardown would delete a live box's claim, and a peer reading
# the registry afterwards would see that issue as free. ONE implementation of the choice, used for
# EVERY bare `issue-<N>` key this suite CHOOSES (the main key and the I9 probe — the probe originally
# picked `ISSUE + 77` unchecked, which reintroduced exactly this defect). The one exception is a
# caller-supplied `ISSUE=`, honoured as-is so a run can be reproduced; and the `+1` bumps used to keep
# the probe distinct are never re-checked against origin, so a peer claiming exactly that number in the
# window between the choice and the acquire is handled by the acquire's own fence, not by this helper.
unclaimed_issue_number() { # -> a number whose refs/claims/issue-<N> does not exist on origin
  # rc=0 found; rc=1 no unclaimed number in 10 rolls; rc=2 the REGISTRY IS UNREADABLE.
  # ⛔ rc=2 exists because a failed `ls-remote` reads as an empty answer, so the old form took the
  # registry's FAIL-OPEN polarity — the opposite of claim_issue_preflight, which calls an unreadable
  # registry INCOMPLETE and never CLEAN. An unreadable origin must stop the run, not pick a number.
  local n out tries=0
  while [ "$tries" -lt 10 ]; do
    n=$(( (RANDOM << 15 | RANDOM) % 900000 + 100000 ))
    out="$(git -C "$A" ls-remote origin "refs/claims/issue-$n" 2>/dev/null)" || return 2
    [ -z "$out" ] && { printf '%s' "$n"; return 0; }
    tries=$(( tries + 1 ))
  done
  return 1
}
# ⛔ THE FENCE'S DECISION, AS A FUNCTION, SO IT CAN BE TESTED DIRECTLY. `rc1` is the acquire's own
# outcome and `own` its `CLAIM_COMMIT`; `now` is the ref's current tip. An acquire that LOST a race
# returns rc1 != 0 and leaves the WINNER's commit as the tip — so fencing on "the tip equals what I
# read" would delete a live claim. The rc1 test is therefore part of the fence, not a caller's
# convenience (VGATE finding on the first draft of this teardown).
probe_fence() { # <rc1> <own> <now> -> "delete" | "skip"
  [ "$1" = "0" ] && [ -n "$2" ] && [ "$3" = "$2" ] && { printf 'delete'; return 0; }
  printf 'skip'
}
# ⛔ THE TEARDOWN'S OWNERSHIP CHECK NEEDS A CLAIM IT MUST *NOT* DELETE (adversarial round 2). Every
# lease this suite plants is either written by its own box identities (pid == $$) or carries a
# whitelisted synthetic id, so the not-owned branch is never entered: replacing `_owned_by_this_run`
# with `return 0` — the exact pre-fix "delete whatever is there" — left the suite 115/0 GREEN. So a
# FOREIGN claim is minted in a SEPARATE PROCESS (`bash -c`, whose $$ differs from this one), and the
# teardown must leave it alone.
run_unclaimed_guard() { ( A=/nonexistent; unclaimed_issue_number >/dev/null 2>&1; printf '%s' "$?" ); }
if [ -n "${ISSUE:-}" ]; then ISSUE_SET=1; else ISSUE_SET=0; fi
if [ "$ISSUE_SET" -eq 0 ]; then
  ISSUE="$(unclaimed_issue_number)" || {
    echo "❌ could not pick an UNCLAIMED issue number (rc=$?; the registry may be unreadable) — refusing to run: a teardown would delete a live claim"
    exit 2
  }
fi
# ⛔ NO `+1` TO KEEP THE ISSUE KEY DISTINCT FROM `PR` (adversarial review). The two keys live in
# DIFFERENT namespaces — `refs/claims/<PR>-<sha12>` versus `refs/claims/issue-<N>` — so equality is
# harmless, while a bump applied AFTER the unclaimed check hands the suite a number nothing verified.
# The old `+1` predated the helper and was carried along; it was a live backdoor onto a peer's claim
# whenever `PR` and `ISSUE` happened to be equal (reachable with `PR=… ISSUE=… `, which the header
# documents as a reproducible-run override).
SHA=deadbeefcafebabe0123456789abcdef01234567
REF="refs/claims/$PR-${SHA:0:12}"
# A SECOND real claim, so the fencing test can offer a caller a genuine commit sha that is not this
# ref's — the property the old random-sha test could not exercise (P3.1).
OTHER_SHA=1111111111111111111111111111111111111111
OTHER_REF="refs/claims/$PR-${OTHER_SHA:0:12}"
# The ISSUE-keyed refs (agent-infra#1850). `ISSUE` is a throwaway number with no real work behind it,
# derived per run like `PR` above (two fixed numbers collided across concurrent runs).
ISSUE_REF="refs/claims/issue-$ISSUE"
# A PR-keyed claim for the SAME NUMBER, to prove the two keyings cannot collide (I3).
PRNUM_REF="refs/claims/$ISSUE-${SHA:0:12}"
PASS=0; FAIL=0; SKIPPED=0  # SKIPPED is printed in RESULT: a skipped arm must never read as a pass
ck() { # ck <label> <expected-regex> <actual>
  # ⛔ here-string, not a pipe: `printf … | grep -q` lets grep exit at its first match while the
  # writer is still writing, so the writer takes SIGPIPE — under `set -o pipefail` the pipeline then
  # reports the writer's 141 instead of a match (#841). scripts/check-no-sigpipe-grep.sh fails the
  # build on the piped form.
  if grep -q "$2" <<<"$3"; then echo "  ✅ $1"; PASS=$((PASS+1));
  else echo "  ❌ $1 — expected /$2/ in: $3"; FAIL=$((FAIL+1)); fi
}

echo
echo "=== I0. OWNERSHIP: a teardown must never delete a claim this run did not take ==="
# (1) an UNREADABLE registry is a REFUSAL, not an empty answer — the polarity claim_issue_preflight
# takes. Without this assertion, deleting `|| return 2` restores the fail-open silently.
ck "I0: an unreadable registry REFUSES the key choice (rc=2), it does not pick a number" "^2$" "$(run_unclaimed_guard)"
# (2) a FOREIGN claim must survive the teardown. Minted in a SEPARATE PROCESS so its $$ is not ours.
FOREIGN="$(unclaimed_issue_number)" || { echo "❌ no unclaimed number for the foreign-claim case"; exit 2; }
( cd "$A" && bash -c 'export CLAIM_OWNER_HOST=peerbox; . "$1"; claim_issue_acquire 0 "$2" 600' _ "$CLAIMS_SH" "$FOREIGN" ) >/dev/null 2>&1
FOREIGN_SHA="$(git -C "$A" ls-remote origin "refs/claims/issue-$FOREIGN" | awk '{print $1}')"
ck "I0: the foreign claim was minted (by a different pid)" "^[0-9a-f]\{40\}$" "$FOREIGN_SHA"
saved_issue="$ISSUE"; saved_ref="$ISSUE_REF"
ISSUE="$FOREIGN"; ISSUE_REF="refs/claims/issue-$FOREIGN"
cleanup_issue_ref >/dev/null 2>&1
left="$(git -C "$A" ls-remote origin "$ISSUE_REF" | awk '{print $1}')"
[ "$left" = "$FOREIGN_SHA" ] \
  && { echo "  ✅ a claim this run did NOT take survives its teardown"; PASS=$((PASS+1)); } \
  || { echo "  ❌ the teardown DELETED a foreign claim (${FOREIGN_SHA:-<none>} -> ${left:-<gone>})"; FAIL=$((FAIL+1)); }
# (3) ...and the SAME teardown does remove a claim this run took (so the check is not "never delete").
ISSUE="$saved_issue"; ISSUE_REF="$saved_ref"
runA claim_issue_acquire "$A" "$saved_issue" 600 >/dev/null 2>&1
own_sha="$(git -C "$A" ls-remote origin "$ISSUE_REF" | awk '{print $1}')"
ck "I0: this run's own claim was taken" "^[0-9a-f]\{40\}$" "$own_sha"
cleanup_issue_ref >/dev/null 2>&1
left="$(git -C "$A" ls-remote origin "$ISSUE_REF" | awk '{print $1}')"
[ -z "$left" ] \
  && { echo "  ✅ this run's OWN claim is removed by the same teardown"; PASS=$((PASS+1)); } \
  || { echo "  ❌ the teardown left this run's OWN claim behind (${left:-<gone>})"; FAIL=$((FAIL+1)); }
# the foreign ref is ours to remove (we minted it), fenced on its own commit
git -C "$A" push -q --force-with-lease="refs/claims/issue-$FOREIGN:$FOREIGN_SHA" origin ":refs/claims/issue-$FOREIGN" 2>/dev/null
cleanup_ref() {
  local cur; cur="$(git -C "$A" ls-remote origin "$REF" | awk '{print $1}')"
  [ -n "$cur" ] && git -C "$A" push -q --force-with-lease="$REF:$cur" origin ":$REF" 2>/dev/null
  return 0
}

echo "=== setup: clear any leftover claim ref ==="
cleanup_ref; git -C "$A" ls-remote origin "$REF" | head -1

echo
echo "=== 1+2. atomicity: A acquires, B must LOSE ==="
outA=$(runA claim_acquire "$A" $PR "$SHA"); rcA=$?
outB=$(runB claim_acquire "$B" $PR "$SHA"); rcB=$?
echo "  A rc=$rcA :: $outA"
echo "  B rc=$rcB :: $outB"
ck "A acquired (rc=0)" "^0$" "$rcA"
ck "B lost the race (rc=1)" "^1$" "$rcB"
ck "B was told who holds it" "held by" "$outB"
ck "acquire names the box (owner=)" "owner=" "$outA"

echo
echo "=== 2b. read-back: the ref on origin resolves ==="
remote_sha=$(git -C "$A" ls-remote origin "$REF" | awk '{print $1}')
if [ -n "$remote_sha" ]; then echo "  ✅ ref exists on origin ($remote_sha)"; PASS=$((PASS+1));
else echo "  ❌ ref absent on origin"; FAIL=$((FAIL+1)); fi

echo
echo "=== 2c. claim_status + snapshot must MATCH claim_ref() ==="
st=$( runA claim_status "$A" $PR "$SHA" ); rc=$?
echo "  claim_status rc=$rc => [$st]"
ck "claim_status returns a lease" "^[^	]*	[0-9]\+$" "$st"
sn=$( cd "$A" && export CLAIM_OWNER_HOST=boxA && . "$CLAIMS_SH" \
      && claim_snapshot "$SNAP" >/dev/null \
      && r="$(claim_ref $PR "$SHA")" && awk -F'\t' -v r="$r" '$1==r{print "MATCH "$0}' "$SNAP" ); rm -f "$SNAP"
echo "  snapshot lookup => $sn"
ck "snapshot lookup by claim_ref MATCHES" "^MATCH" "$sn"

echo
echo "=== 6. fencing: A cannot release with ANOTHER LIVE claim's real sha ==="
# ⛔ The old test offered a RANDOM 40-char sha, which is not an object anywhere, so it proved only
# that `--force-with-lease` rejects a nonsense value — it would also pass with a plain unfenced
# delete-detection that never consulted the sha. The property that matters: a caller holding a REAL
# commit sha that is not THIS ref's tip still cannot release it (the fence is on the ref's value).
cleanup_other() {
  local cur; cur="$(git -C "$A" ls-remote origin "$OTHER_REF" 2>/dev/null | awk '{print $1}')"
  [ -n "$cur" ] && git -C "$A" push -q --force-with-lease="$OTHER_REF:$cur" origin ":$OTHER_REF" 2>/dev/null
  return 0
}
cleanup_other
outOther=$(runB claim_acquire "$B" $PR "$OTHER_SHA" 600); rcOther=$?
other_live_sha=$(git -C "$A" ls-remote origin "$OTHER_REF" 2>/dev/null | awk '{print $1}')
echo "  another live claim: $OTHER_REF = $other_live_sha (rc=$rcOther)"
out=$(runA claim_release "$A" $PR "$SHA" "$other_live_sha"); rc=$?
echo "  rc=$rc :: $out"
ck "release with another LIVE claim's real sha REFUSED" "refused" "$out"
still=$(git -C "$A" ls-remote origin "$REF" | awk '{print $1}')
if [ "$still" = "$remote_sha" ]; then echo "  ✅ our claim survived the foreign-sha release attempt"; PASS=$((PASS+1));
else echo "  ❌ our claim was deleted by a foreign sha"; FAIL=$((FAIL+1)); fi
cleanup_other

echo
echo "=== 5. A releases with its real SHA ==="
out=$(runA claim_release "$A" $PR "$SHA" "$remote_sha"); rc=$?
echo "  rc=$rc :: $out"
ck "release accepted" "released" "$out"
gone=$(git -C "$A" ls-remote origin "$REF" | awk '{print $1}')
if [ -z "$gone" ]; then echo "  ✅ ref gone from origin"; PASS=$((PASS+1)); else echo "  ❌ ref still present"; FAIL=$((FAIL+1)); fi

echo
echo "=== 3. lease is data: an EXPIRED claim is reclaimable, a LIVE one is not ==="
# TTL must comfortably exceed the time to the next assertion, or the test races its own expiry
# (a 1s TTL expired between two commands and the code — correctly — read it as free).
out=$(runB claim_acquire "$B" $PR "$SHA" 8); rc=$?
echo "  B acquire ttl=8 rc=$rc :: $out"
ck "B acquired the free ref" "^0$" "$rc"
BOWNER=$(printf '%s' "$out" | sed -n 's/.*owner=\([^ ]*\).*/\1/p')
out=$(runA claim_acquire "$A" $PR "$SHA"); rc=$?
echo "  A attempts while lease LIVE rc=$rc :: $out"
ck "live lease blocks A" "^1$" "$rc"
ck "A is told it is B's lease" "$BOWNER" "$out"
echo "  ...sleeping 9s for the lease to expire..."
sleep 9
out=$(runA claim_acquire "$A" $PR "$SHA"); rc=$?
echo "  A attempts after expiry rc=$rc :: $out"
ck "expired lease reclaimed by A" "^0$" "$rc"
ck "reclaim names the previous owner" "reclaimed expired" "$out"
ck "reclaim names B specifically" "$BOWNER" "$out"

echo
echo "=== P1. the claim object carries a uniqueness nonce ==="
# Without this, two acquisitions with the same owner and the same lease SECOND build a
# byte-identical root commit; pushing an identical commit to a ref that already holds it exits 0
# ("up-to-date"), the read-back confirms, and the SECOND box reports `acquired` — the CAS is
# defeated. A is the current holder here, and its reclaim commit is present in its own odb.
held_sha=$(git -C "$A" ls-remote origin "$REF" | awk '{print $1}')
msg="$(git -C "$A" cat-file commit "$held_sha" 2>/dev/null | tail -1)"
echo "  claim commit message => $msg"
ck "claim message carries nonce=" "nonce=" "$msg"

echo
echo "=== P1b (DISCRIMINATING). same owner + SAME lease second => different objects, loser LOSES ==="
# ⛔ The presence check above cannot fail while `nonce=` is emitted — even for a CONSTANT nonce.
# Measured: with `nonce=CONSTANT` the suite still reported 19 passed / 0 failed, while two boxes with
# the same CLAIM_OWNER_HOST in the same second BOTH reported `acquired` (a byte-identical root commit
# pushed to a ref that already holds it exits 0 as "up-to-date"). The assertions below are the ones
# that go RED without a per-acquisition nonce: the lease SECOND and the git timestamps are forced
# identical, so the nonce is the ONLY thing that can differentiate the two commit objects.
same_second_acquire() { # <box-dir> <owner-id>
  ( cd "$1" \
    && export CLAIM_OWNER_HOST="$2" GIT_AUTHOR_DATE='2001-01-01T00:00:00Z' GIT_COMMITTER_DATE='2001-01-01T00:00:00Z' \
    && . "$CLAIMS_SH" && date() { echo 1700000000; } \
    && claim_acquire "$1" "$PR" "$SHA" 600 )
}
cleanup_ref
outX=$(same_second_acquire "$A" twin); rcX=$?
outY=$(same_second_acquire "$B" twin); rcY=$?
echo "  twin A rc=$rcX :: $outX"
echo "  twin B rc=$rcY :: $outY"
ck "same-owner/same-second: first WINS" "^0$" "$rcX"
ck "same-owner/same-second: second LOSES (unique object => push rejected)" "^1$" "$rcY"
o1=$( cd "$A" && export GIT_AUTHOR_DATE='2001-01-01T00:00:00Z' GIT_COMMITTER_DATE='2001-01-01T00:00:00Z' \
      && . "$CLAIMS_SH" && date() { echo 1700000000; } && _claim_commit twin 1700000600 )
o2=$( cd "$B" && export GIT_AUTHOR_DATE='2001-01-01T00:00:00Z' GIT_COMMITTER_DATE='2001-01-01T00:00:00Z' \
      && . "$CLAIMS_SH" && date() { echo 1700000000; } && _claim_commit twin 1700000600 )
if [ -n "$o1" ] && [ -n "$o2" ] && [ "$o1" != "$o2" ]; then
  echo "  ✅ two same-owner/same-second claim objects DIFFER ($o1 != $o2) — the nonce is UNIQUE"; PASS=$((PASS+1))
else
  echo "  ❌ identical/empty claim objects ($o1 / $o2) — the nonce is PRESENT but not UNIQUE"; FAIL=$((FAIL+1))
fi
cleanup_ref

echo
echo "=== P2b. reclaim: a failed push is an INFRA failure (rc=2), not a lost race ==="
# The CREATE path distinguishes "lost the CAS" from "the remote was unreachable"; the reclaim path
# used to call EVERY non-zero push a lost race and merge-one.sh then logged "another box owns head"
# and exited 0 — FAIL-CLOSED, the opposite of the stated policy. `_git` is wrapped below so the
# reclaim push fails while the ref is left unchanged, which is exactly a transient push failure.
seed_expired() { # <owner> -> prints the commit it pushed
  local exp c
  exp=$(( $(date +%s) - 5 ))
  c="$( cd "$A" && . "$CLAIMS_SH" && _claim_commit "$1" "$exp" )"
  ( cd "$A" && . "$CLAIMS_SH" && _git push -q origin "$c:$REF" ) || return 1
  echo "$c"
}
infra_reclaim() { # <box-dir>
  ( cd "$1" && export CLAIM_OWNER_HOST=probe \
    && . "$CLAIMS_SH" \
    && _git() { case "$*" in *"--force-with-lease"*) return 1 ;; *) _git_delegate "$@" ;; esac; } \
    && claim_acquire "$1" "$PR" "$SHA" 600 )
}
cleanup_ref
E1="$(seed_expired oldowner)"; echo "  seeded expired claim $E1"
outI=$(infra_reclaim "$A"); rcI=$?
echo "  rc=$rcI :: $outI"
ck "failed push with an UNCHANGED ref => infra rc=2 (fail-open)" "^2$" "$rcI"
ck "the reason names infrastructure, not a lost race" "infrastructure failure" "$outI"
cleanup_ref

echo
echo "=== P2c2. the reclaim infra-failure path SURFACES the commit (fenced release possible) ==="
# Same defect as P2a, on the RECLAIM path (P2, second review round, 2026-10-14): it returned rc=2
# without setting CLAIM_COMMIT, so merge-one.sh's `if [ -n "$CLAIM_COMMIT" ]` never attempted the
# fenced release. If the reclaim push HAD landed and only the immediate re-read failed, the box
# proceeded fail-open while genuinely owning the ref and every other box refused that head until the
# lease expired (up to 50 min). Setting it is safe: the fenced release is a no-op while the ref is
# still the seeded `$cur`.
cleanup_ref
E3="$(seed_expired oldowner3)"; echo "  seeded expired claim $E3"
infra_reclaim_commit() { # <box-dir> -> "rc=<n> commit=<sha>"
  ( cd "$1" && export CLAIM_OWNER_HOST=probe \
    && . "$CLAIMS_SH" \
    && _git() { case "$*" in *"--force-with-lease"*) return 1 ;; *) _git_delegate "$@" ;; esac; } \
    && claim_acquire "$1" "$PR" "$SHA" 600 >/dev/null; rc=$?; printf 'rc=%s commit=%s\n' "$rc" "$CLAIM_COMMIT" )
}
ir="$(infra_reclaim_commit "$A")"
echo "  $ir"
ck "reclaim infra failure => rc=2" "rc=2" "$ir"
irc="$(printf '%s' "$ir" | sed -n 's/.*commit=\([0-9a-f]*\).*/\1/p')"
if [ -n "$irc" ]; then echo "  ✅ CLAIM_COMMIT set on the reclaim infra-failure path ($irc)"; PASS=$((PASS+1));
else echo "  ❌ CLAIM_COMMIT empty — merge-one.sh cannot attempt the fenced release (orphan)"; FAIL=$((FAIL+1)); fi
# And the surfaced commit must NOT delete the seed: the fence rejects it, so the ref is unchanged.
beforeIR="$(git -C "$A" ls-remote origin "$REF" | awk '{print $1}')"
( cd "$A" && . "$CLAIMS_SH" && claim_release "$A" "$PR" "$SHA" "$irc" ) >/dev/null 2>&1
afterIR="$(git -C "$A" ls-remote origin "$REF" | awk '{print $1}')"
if [ -n "$beforeIR" ] && [ "$beforeIR" = "$E3" ] && [ "$afterIR" = "$E3" ]; then
  echo "  ✅ the surfaced commit cannot delete a claim it does not own (fenced no-op)"; PASS=$((PASS+1))
else echo "  ❌ the surfaced release changed the ref ($beforeIR -> $afterIR, seed=$E3)"; FAIL=$((FAIL+1)); fi
cleanup_ref

echo
echo "=== P2b. reclaim: a failed push with a MOVED ref is a genuine LOST RACE (rc=1) ==="
# The other half of the classification: the re-read must still detect a real lost race, or the fix
# would be fail-open ALWAYS and hide the CAS loss. Simulated: the reclaim push fails and the read-back
# shows a DIFFERENT sha than the one the reclaim was fenced on (the second ls-remote).
cleanup_ref
E2="$(seed_expired oldowner2)"; echo "  seeded expired claim $E2"
CNT="/tmp/xb-claims-lsremotecalls.$$"; rm -f "$CNT"
# Defined at TOP LEVEL, not inside $( ... ): bash 3.2 mis-parses a `case` block nested inside a
# command substitution (syntax error on the `;;`), and macOS ships 3.2.
moved_reclaim() { # <box-dir> <counter-file>
  ( cd "$1" && export CLAIM_OWNER_HOST=late CNT="$2" \
    && . "$CLAIMS_SH" \
    && _git() {
         case "$*" in
           *"--force-with-lease"*) return 1 ;;
           *ls-remote*)
             local n; n="$(cat "$CNT" 2>/dev/null || echo 0)"; n=$((n+1)); echo "$n" > "$CNT"
             if [ "$n" -le 1 ]; then _git_delegate "$@"
             else printf '1111111111111111111111111111111111111111\t%s\n' "$CLAIM_REF"; fi ;;
           *) _git_delegate "$@" ;;
         esac
       } \
    && claim_acquire "$1" "$PR" "$SHA" 600 )
}
outR="$(moved_reclaim "$A" "$CNT")"; rcR=$?
echo "  rc=$rcR :: $outR"
ck "failed push with a MOVED ref => lost race rc=1" "^1$" "$rcR"
ck "the reason says lost the reclaim race" "lost the reclaim race" "$outR"
rm -f "$CNT"
cleanup_ref

echo
echo "=== P2c. claim_snapshot --prune must NOT delete a concurrent worker temp ref ==="
# The controller and workers share ONE repo, and `claim_snapshot` fetches with `--prune` and an
# explicit destination refspec — which prunes anything matching the DESTINATION pattern, not just
# refs that came from the source. A worker's lease-read temp ref used to live under CLAIM_CACHE_NS,
# so a snapshot could delete it mid-read; `_lease_of` then returned "?<TAB>0", an unparseable lease
# was read as LIVE, and the merge was refused although nobody owned it. The temp ref below is created
# in the namespace the CODE chooses, so aliasing CLAIM_TMP_NS back onto CLAIM_CACHE_NS turns it RED.
cleanup_ref
tmp_survives() { # <box-dir> <snapshot-file> -> SURVIVED|PRUNED
  ( cd "$1" && export CLAIM_OWNER_HOST=boxA && . "$CLAIMS_SH" \
    && c="$(_claim_commit boxA $(( $(date +%s) + 600 )))" \
    && command git -C "$1" push -q origin "$c:$REF" \
    && tref="$CLAIM_TMP_NS/xb-tmp-$$" \
    && command git -C "$1" update-ref "$tref" "$c" \
    && claim_snapshot "$2" >/dev/null \
    && if command git -C "$1" show-ref --verify --quiet "$tref"; then echo "SURVIVED $CLAIM_TMP_NS"; else echo "PRUNED $CLAIM_TMP_NS"; fi )
}
outS="$(tmp_survives "$A" "$SNAP")"
echo "  temp ref after a snapshot fetch: $outS"
ck "snapshot --prune did NOT delete the temp ref" "^SURVIVED" "$outS"
( cd "$A" && . "$CLAIMS_SH" && command git -C "$A" update-ref -d "$CLAIM_TMP_NS/xb-tmp-$$" 2>/dev/null )
cleanup_ref

echo
echo "=== P3.4. claim_prune reaps a LEAKED temp ref but leaves a FRESH one alone ==="
# `claim_prune` used to sweep only CLAIM_NS, while every lease READ/STATUS creates a local ref under
# CLAIM_TMP_NS and deletes it with `update-ref -d`. A SIGKILL between the fetch and the delete leaks
# that ref FOREVER — it is local-only, so no ls-remote sweep can ever see it (P3.4, second review
# round, 2026-10-14). The age bound is the REF FILE's mtime, so a 2h bound cannot touch a live read.
# CLAIM_NS is scoped to a private namespace so this cannot disturb a concurrent suite's live refs.
prune_tmp() { # <box-dir> -> "OLD=<survived|pruned> NEW=<survived|pruned>"
  ( cd "$1" && export CLAIM_NS="refs/claims-xbprune-$$" && . "$CLAIMS_SH" \
    && c="$(_claim_commit probe $(( $(date +%s) + 600 )))" \
    && command git -C "$1" update-ref "$CLAIM_TMP_NS/old-$$" "$c" \
    && command git -C "$1" update-ref "$CLAIM_TMP_NS/new-$$" "$c" \
    && op="$(command git -C "$1" rev-parse --git-path "$CLAIM_TMP_NS/old-$$")" \
    && touch -t 202001010000 "$op" \
    && claim_prune >/dev/null 2>&1 \
    && { command git -C "$1" show-ref --verify --quiet "$CLAIM_TMP_NS/old-$$" && o=survived || o=pruned; } \
    && { command git -C "$1" show-ref --verify --quiet "$CLAIM_TMP_NS/new-$$" && n=survived || n=pruned; } \
    && command git -C "$1" update-ref -d "$CLAIM_TMP_NS/new-$$" 2>/dev/null; \
    printf 'OLD=%s NEW=%s\n' "$o" "$n" )
}
cleanup_ref
outP="$(prune_tmp "$A")"
echo "  $outP"
ck "an OLD leaked temp ref is reaped by claim_prune" "OLD=pruned" "$outP"
ck "a FRESH temp ref (a live read) is NOT reaped" "NEW=survived" "$outP"
cleanup_ref

echo
echo "=== P2a. a read-back failure on CREATE surfaces the commit (no orphan) ==="
# The push can SUCCEED on the remote and fail only the read-back. Before the fix claims.sh returned
# rc=2 with CLAIM_COMMIT empty, so merge-one.sh fail-opened with CROSS_OWN="" and the EXIT trap never
# released a claim that DID exist — the head was held fleet-wide until the lease expired (up to
# REVIEW_TIMEOUT+1200 = 50 min). `_git` is wrapped so the push lands and ls-remote fails.
readback_fail() { # <box-dir> -> "rc=<n> commit=<sha> ref=<ref>"
  ( cd "$1" && export CLAIM_OWNER_HOST=probe \
    && . "$CLAIMS_SH" \
    && _git() { case "$*" in *ls-remote*) return 1 ;; *) _git_delegate "$@" ;; esac; } \
    && claim_acquire "$1" "$PR" "$SHA" 600 >/dev/null; rc=$?; printf 'rc=%s commit=%s ref=%s\n' "$rc" "$CLAIM_COMMIT" "$CLAIM_REF" )
}
cleanup_ref
rb="$(readback_fail "$A")"
echo "  $rb"
ck "read-back failure => rc=2" "rc=2" "$rb"
rb_commit="$(printf '%s' "$rb" | sed -n 's/.*commit=\([0-9a-f]*\).*/\1/p')"
origin_now="$(command git -C "$A" ls-remote origin "$REF" | awk '{print $1}')"
echo "  called-back commit=$rb_commit ; ref on origin=$origin_now"
if [ -n "$rb_commit" ] && [ "$rb_commit" = "$origin_now" ]; then
  echo "  ✅ the caller is handed the REAL created commit — a fenced release is possible"; PASS=$((PASS+1))
else
  echo "  ❌ CLAIM_COMMIT is empty or does not match the ref ($rb_commit vs $origin_now) — the claim is orphaned"; FAIL=$((FAIL+1))
fi
outRel=$( ( cd "$A" && . "$CLAIMS_SH" && claim_release "$A" "$PR" "$SHA" "$rb_commit" ) ); rcRel=$?
echo "  release rc=$rcRel :: $outRel"
ck "the surfaced commit lets the caller release the orphan" "released" "$outRel"
cleanup_ref

echo
echo "=== P3.2. the trap cleans REMOTE refs (not just local dirs) and covers INT/TERM ==="
# Behavioral: cleanup_remote is what the trap calls; it must delete the refs this suite mints on LIVE
# origin. Structural: INT and TERM must be trapped, or a Ctrl-C leaves the ref behind.
( cd "$A" && . "$CLAIMS_SH" && c="$(_claim_commit proberef $(( $(date +%s) + 600 )))" && git -C "$A" push -q origin "$c:$OTHER_REF" )
before="$(git -C "$A" ls-remote origin "$OTHER_REF" | wc -l | tr -d ' ')"
cleanup_remote
after="$(git -C "$A" ls-remote origin "$OTHER_REF" | wc -l | tr -d ' ')"
if [ "$before" = "1" ] && [ "$after" = "0" ]; then echo "  ✅ cleanup_remote deletes a live ref on origin"; PASS=$((PASS+1));
else echo "  ❌ cleanup_remote did not delete it ($before -> $after)"; FAIL=$((FAIL+1)); fi
tr="$(trap -p EXIT INT TERM)"
for s in EXIT INT TERM; do
  # bash 3.2 prints SIGINT/SIGTERM, later bashes print INT/TERM — a substring match covers both.
  if grep -q "$s" <<<"$tr"; then echo "  ✅ trap registered for $s"; PASS=$((PASS+1));
  else echo "  ❌ no trap for $s"; FAIL=$((FAIL+1)); fi
done

echo
echo "=== P2d. an OVERFLOWING ttl is CLAMPED at the arithmetic site, not written as a lease ==="
# `until=$(( now + ttl ))` wraps NEGATIVE at or above 2**63; `_lease_of`'s `[0-9]*` cannot parse the
# minus sign, an unparseable lease is read as LIVE forever, and `claim_prune` can never reap it — so
# the head is frozen across ALL boxes with no automatic recovery. The shipped callers now validate
# their tunables with `is_limit`, and the PRIMITIVE clamps too (defence in depth: no caller can mint
# a lease this module is unable to read back). Pre-fix the acquire echoes a negative lease_until.
huge_lease() { # <box-dir>
  ( cd "$1" && export CLAIM_OWNER_HOST=huge \
    && . "$CLAIMS_SH" \
    && claim_acquire "$1" "$PR" "$SHA" 9223372036854775807 >/dev/null; rc=$?
    printf 'rc=%s lease=%s\n' "$rc" "$(printf '%s' "$CLAIM_RESULT" | sed -n 's/.*lease_until=\(.*\)$/\1/p')" )
}
cleanup_ref
hl="$(huge_lease "$A")"
echo "  $hl"
ck "an overflowing ttl still acquires (it is clamped, not refused)" "rc=0" "$hl"
hlv="$(printf '%s' "$hl" | sed -n 's/.*lease=\(.*\)$/\1/p')"
case "$hlv" in
  ''|*[!0-9]*) hlb=0 ;;
  *) if [ "${#hlv}" -le 10 ] && [ "$hlv" -gt 0 ]; then hlb=1; else hlb=0; fi ;;
esac
if [ "$hlb" = "1" ]; then echo "  ✅ the overflowing ttl was clamped — the lease parses ($hlv)"; PASS=$((PASS+1));
else echo "  ❌ lease_until='$hlv' is absent/negative/oversized — unparseable, so read as LIVE forever"; FAIL=$((FAIL+1)); fi
cleanup_ref

echo
echo "=== P3e. a FOREIGN oversized (>=2**63) lease is treated as LIVE, not STOLEN ==="
# `[ "$now" -le "$held_until" ]` ERRORS (rc=2, and an errored test is FALSE) at or above 2**63, so
# control fell through to the RECLAIM CAS and STOLE a claim this code means to treat as live; the
# "unparseable = live" branch covered an ABSENT lease but not an oversized-but-numeric one. The seed
# is a real claim commit with lease_until = 9223372036854775808 (exactly 2**63 — the smallest value
# at which `[` errors; 2**63-1 is still an in-range integer). Not reachable from the shipped writers
# (they clamp), so this is defence in depth against a foreign or older writer. RED pre-fix: the
# acquire reclaims it (rc=0) instead of refusing (rc=1).
seed_huge() { # -> prints the commit it pushed
  local c
  c="$( cd "$A" && . "$CLAIMS_SH" && _claim_commit foreignbox 9223372036854775808 )"
  ( cd "$A" && . "$CLAIMS_SH" && _git push -q origin "$c:$REF" ) || return 1
  echo "$c"
}
cleanup_ref
EH="$(seed_huge)"; echo "  seeded an oversized-lease claim: $EH"
outH=$(runA claim_acquire "$A" $PR "$SHA"); rcH=$?
echo "  rc=$rcH :: $outH"
ck "an oversized (>=2**63) lease reads as UNPARSEABLE => LIVE (rc=1)" "^1$" "$rcH"
ck "the refusal says it cannot parse the lease" "no parseable lease" "$outH"
stillH="$(git -C "$A" ls-remote origin "$REF" | awk '{print $1}')"
if [ -n "$EH" ] && [ "$stillH" = "$EH" ]; then
  echo "  ✅ the oversized-lease claim was NOT stolen"; PASS=$((PASS+1))
else echo "  ❌ the claim was STOLEN or the seed failed ($stillH vs seed '$EH')"; FAIL=$((FAIL+1)); fi
cleanup_ref

echo
echo "=== P3f. a foreign UNREADABLE lease (0, and the -5 that collapses to it) is LIVE, not STOLEN ==="
# claim_acquire's unparseable branch is `[ -z "$held_until" ] || [ "$held_until" = "0" ]`: a claim
# whose commit message carries `lease_until=0` (or a negative, which _lease_of's `[0-9]*` cannot match
# and therefore collapses to `0`) means "a claim EXISTS whose lease is unreadable". Reading it as dead
# would let a box STEAL it. This is the datum claim_live() must AGREE with (selftest §14's `0` case),
# and the class the fifth review round closed on the reader side. RED pre-fix is on the READER; this
# pins the WRITER-side semantics it must match.
seed_lease() { # <lease-string> -> prints the commit it pushed
  local c
  c="$( cd "$A" && . "$CLAIMS_SH" && _claim_commit foreignbox "$1" )"
  ( cd "$A" && . "$CLAIMS_SH" && _git push -q origin "$c:$REF" ) || return 1
  echo "$c"
}
for L in 0 -5; do
  cleanup_ref
  EL="$(seed_lease "$L")"; echo "  seeded lease_until=$L: $EL"
  outL=$(runA claim_acquire "$A" $PR "$SHA"); rcL=$?
  echo "  rc=$rcL :: $outL"
  ck "lease_until=$L reads as UNPARSEABLE => LIVE (rc=1)" "^1$" "$rcL"
  ck "the refusal for lease_until=$L says it cannot parse the lease" "no parseable lease" "$outL"
  stillL="$(git -C "$A" ls-remote origin "$REF" | awk '{print $1}')"
  if [ -n "$EL" ] && [ "$stillL" = "$EL" ]; then
    echo "  ✅ the lease_until=$L claim was NOT stolen"; PASS=$((PASS+1))
  else echo "  ❌ the lease_until=$L claim was STOLEN or the seed failed ($stillL vs seed '$EL')"; FAIL=$((FAIL+1)); fi
done
cleanup_ref

echo
echo "=== I1. TWO BOXES, ONE ISSUE, **NOTHING PUSHED**: the second box must NOT read CLEAN (#1850) ==="
# ⛔ THIS IS THE DEFECT TEST. A peer's work is invisible to git from the moment it starts until it
# first pushes a branch, opens a PR or is assigned — and nothing assigns on dispatch — so the
# pre-flight's surfaces (branches, worktrees, PRs, assignee) all say CLEAN for the WHOLE working
# period of the lane. The claim is the only artifact that exists in that window, so the test creates
# NO branch, NO PR and NO push of anything but the claim ref itself.
#
# NON-VACUITY, MEASURED: on the pre-change claims.sh `claim_issue_preflight` does not exist, so the
# command substitution below returns rc=127 with an empty reason and `ck` fails. Reproduce with:
#     git show <pre-change-rev>:scripts/orchestrator-harness/claims.sh > /tmp/old-claims.sh
#     CLAIMS_SH=/tmp/old-claims.sh bash test-claims.sh     # I1..I10 go RED
cleanup_issue_ref
claim_before="$(git -C "$A" ls-remote origin "$ISSUE_REF" | wc -l | tr -d ' ')"
[ "$claim_before" = "0" ] && { echo "  ✅ no issue claim exists yet (nothing pushed)"; PASS=$((PASS+1)); } \
                         || { echo "  ❌ a stale issue claim is present on origin"; FAIL=$((FAIL+1)); }
outA=$(runA claim_issue_acquire "$A" "$ISSUE"); rcA=$?
echo "  A claim_issue_acquire rc=$rcA :: $outA"
ck "A claimed the ISSUE (rc=0)" "^0$" "$rcA"
ck "the issue claim lives in the ISSUE namespace (refs/claims/issue-<N>)" "refs/claims/issue-$ISSUE" "$outA"
# ⛔ A's OWN commit, captured NOW (A's acquire ran in a subshell, so CLAIM_COMMIT is gone). It is
# what the stale-release assertion in I4 fences on: the commit A really pushed, not a random sha.
A_ISSUE_SHA=$(git -C "$A" ls-remote origin "$ISSUE_REF" | awk '{print $1}')
# Read it from the REMOTE, not from a local ref: a claim only exists for the peer if it is on origin.
remote_issue_sha=$(git -C "$A" ls-remote origin "$ISSUE_REF" | awk '{print $1}')
[ -n "$remote_issue_sha" ] && { echo "  ✅ the issue claim is on origin ($remote_issue_sha)"; PASS=$((PASS+1)); } \
                           || { echo "  ❌ the issue claim was not pushed"; FAIL=$((FAIL+1)); }
outB=$(runB claim_issue_preflight "$ISSUE"); rcB=$?
echo "  B pre-flight registry read rc=$rcB :: $outB"
ck "B's pre-flight does NOT read CLEAN (rc=1)" "^1$" "$rcB"
ck "B is told WHO holds the issue" "held by" "$outB"
ck "B names A as the holder" 'boxA' "$outB"

# I2. A read is not a lock: the acquire must actually LOSE, or two boxes both read CLEAN and both
# claim (a claim ref keyed per box would do exactly that).
outB2=$(runB claim_issue_acquire "$B" "$ISSUE"); rcB2=$?
echo "  B claim_issue_acquire rc=$rcB2 :: $outB2"
ck "B LOST the issue CAS (rc=1)" "^1$" "$rcB2"
ck "B's loss names the holder" "held by" "$outB2"
out_st=$(runA claim_issue_status "$A" "$ISSUE"); rc_st=$?
ck "claim_issue_status returns the lease" "^[^	]*	[0-9]\+$" "$out_st"

# I3. DISJOINT KEYINGS: a PR claim for the SAME NUMBER must neither block the issue claim nor be
# blocked by it. (`<PR>-<sha12>` vs `issue-<N>` — the `issue-` prefix is what makes this true.)
cleanup_pref() { local c; c="$(git -C "$A" ls-remote origin "$PRNUM_REF" | awk '{print $1}')"; [ -n "$c" ] && git -C "$A" push -q --force-with-lease="$PRNUM_REF:$c" origin ":$PRNUM_REF" 2>/dev/null; return 0; }
cleanup_pref
outP=$(runB claim_acquire "$B" "$ISSUE" "$SHA" 600); rcP=$?
echo "  a PR-keyed claim for the same number: $PRNUM_REF rc=$rcP :: $outP"
ck "a PR claim for the same NUMBER is its own ref and is acquired" "^0$" "$rcP"
ck "...and it is NOT the issue ref" "refs/claims/$ISSUE-${SHA:0:12}" "$outP"
outB3=$(runB claim_issue_preflight "$ISSUE"); rcB3=$?
echo "  B pre-flight while BOTH keys exist rc=$rcB3 :: $outB3"
ck "a live PR claim on the same number does not make the issue ref unreadable" "^1$" "$rcB3"
ck "...and the pre-flight still reports A's ISSUE claim (not the PR one)" 'boxA' "$outB3"
cleanup_pref

# I4. TTL + FENCING FOR THE ISSUE KEY. A holds it; the lease expires; B reclaims (a CAS, not a
# blind force); A's fenced release with the commit it pushed MUST be refused — a stale holder
# cannot delete a winner's claim.
cleanup_issue_ref
outI=$(runA claim_issue_acquire "$A" "$ISSUE" 8); rcI=$?
echo "  A claim ttl=8 rc=$rcI :: $outI"
ck "A reclaimed the issue ref (previous holder's lease expired)" "^0$" "$rcI"
AOWN="$(printf '%s' "$outI" | sed -n 's/.*owner=\([^ ]*\).*/\1/p')"
echo "  ...sleeping 9s for the issue lease to expire..."
sleep 9
outR=$(runB claim_issue_acquire "$B" "$ISSUE" 600); rcR=$?
echo "  B reclaim after expiry rc=$rcR :: $outR"
ck "an EXPIRED issue claim is reclaimed by B" "^0$" "$rcR"
ck "the reclaim names A as the previous owner" "$AOWN" "$outR"
BOWN_SHA=$(git -C "$A" ls-remote origin "$ISSUE_REF" | awk '{print $1}')
# A releases with the commit A ACTUALLY pushed (captured in I1): a real stale sha, so the fence is
# exercised rather than a nonsense value that any delete-detection would also refuse.
outRel=$(runA claim_issue_release "$A" "$ISSUE" "$A_ISSUE_SHA"); rcRel=$?
echo "  A (stale) release rc=$rcRel :: $outRel"
ck "a STALE holder's issue release is refused" "refused" "$outRel"
still_issue=$(git -C "$A" ls-remote origin "$ISSUE_REF" | awk '{print $1}')
if [ -n "$BOWN_SHA" ] && [ "$still_issue" = "$BOWN_SHA" ]; then
  echo "  ✅ the winner's issue claim survived the stale release"; PASS=$((PASS+1))
else echo "  ❌ the stale release deleted/changed the winner's claim ($still_issue vs $BOWN_SHA)"; FAIL=$((FAIL+1)); fi
# The FENCED release FROM THE REAL HOLDER still works (the fence must not be a blanket refusal).
outR2=$(runB claim_issue_release "$B" "$ISSUE" "$BOWN_SHA"); rcR2=$?
echo "  B (the winner) release rc=$rcR2 :: $outR2"
ck "the winning holder CAN release its own issue claim" "released" "$outR2"
gone_issue=$(git -C "$A" ls-remote origin "$ISSUE_REF" | awk '{print $1}')
[ -z "$gone_issue" ] && { echo "  ✅ the issue ref is gone from origin"; PASS=$((PASS+1)); } \
                      || { echo "  ❌ the issue ref is still present"; FAIL=$((FAIL+1)); }

# I5. THE RELEASE PATH MUST NOT ERROR UNDER `set -u` — the incidental defect found while verifying
# #1850: `claim_release` with THREE arguments raised `line 260: $4: unbound variable` on the release
# path (the direct `git push origin :refs/...` worked instead). A release that ERRORS leaves the
# claim held until its lease runs out — and for the issue key that is a FREE issue no box will
# dispatch for up to CLAIM_ISSUE_TTL. RED pre-fix: the output carries `unbound variable`, not the
# documented refusal, and the assertion below fails on the message.
outRel3=$( ( cd "$A" && . "$CLAIMS_SH" && claim_release "$A" "$PR" "$SHA" ) 2>&1 ); rcRel3=$?
echo "  claim_release with 3 args (no own commit) rc=$rcRel3 :: $outRel3"
ck "claim_release with 3 args REFUSES (rc=1)" "^1$" "$rcRel3"
ck "...and reaches the documented refusal" "no claim commit to fence on" "$outRel3"
case "$outRel3" in
  *"unbound variable"*) echo "  ❌ the release path still aborts under set -u ($outRel3)"; FAIL=$((FAIL+1)) ;;
  *) echo "  ✅ the release path does not abort under set -u"; PASS=$((PASS+1)) ;;
esac
outIR2=$( ( cd "$A" && . "$CLAIMS_SH" && claim_issue_release "$A" "$ISSUE" ) 2>&1 ); rcIR2=$?
echo "  claim_issue_release with 2 args rc=$rcIR2 :: $outIR2"
ck "claim_issue_release with 2 args REFUSES (rc=1)" "^1$" "$rcIR2"
ck "...with the same documented refusal" "no claim commit to fence on" "$outIR2"
case "$outIR2" in
  *"unbound variable"*) echo "  ❌ claim_issue_release aborts under set -u ($outIR2)"; FAIL=$((FAIL+1)) ;;
  *) echo "  ✅ claim_issue_release does not abort under set -u"; PASS=$((PASS+1)) ;;
esac

# I6. AN UNREADABLE LEASE IS LIVE, NOT FREE (and never CLEAN). The same polarity as claim_acquire
# and orch-loop's claim_live: `lease_until=0` means "a claim EXISTS whose lease this reader cannot
# parse". Reading it as free would let a peer steal a live claim.
seed_issue_lease() { # <lease-string> -> prints the commit it pushed
  local c
  c="$( cd "$A" && . "$CLAIMS_SH" && _claim_commit foreignbox "$1" )"
  ( cd "$A" && . "$CLAIMS_SH" && _git push -q origin "$c:$ISSUE_REF" ) || return 1
  echo "$c"
}
cleanup_issue_ref
E0="$(seed_issue_lease 0)"; echo "  seeded an issue claim with lease_until=0: $E0"
outU=$(runB claim_issue_preflight "$ISSUE"); rcU=$?
echo "  pre-flight rc=$rcU :: $outU"
ck "an UNREADABLE issue lease reads as LIVE (rc=1)" "^1$" "$rcU"
ck "...and says so" "lease unreadable" "$outU"
outU2=$(runB claim_issue_acquire "$B" "$ISSUE"); rcU2=$?
ck "an UNREADABLE issue lease is NOT stolen (acquire rc=1)" "^1$" "$rcU2"
stillU=$(git -C "$A" ls-remote origin "$ISSUE_REF" | awk '{print $1}')
if [ -n "$E0" ] && [ "$stillU" = "$E0" ]; then
  echo "  ✅ the unreadable-lease issue claim was NOT stolen"; PASS=$((PASS+1))
else echo "  ❌ the unreadable-lease issue claim was STOLEN ($stillU vs $E0)"; FAIL=$((FAIL+1)); fi

# I7. THE DECAY PATH. A box that dies mid-lane never releases, so `claim_prune` is the recovery —
# and for an issue claim that is up to CLAIM_ISSUE_TTL of a free issue nobody may dispatch. The
# seeded commit is already expired (a 5s lease minted in the past), so the prune must reap it.
# ⚠️ This sweeps the DEFAULT claim namespace (the controller does exactly this hourly); it deletes
# only EXPIRED refs, and the suite's other refs are live, so nothing owned is touched.
cleanup_issue_ref
EP="$( cd "$A" && . "$CLAIMS_SH" && _claim_commit expiredbox $(( $(date +%s) - 5 )) )"
( cd "$A" && . "$CLAIMS_SH" && _git push -q origin "$EP:$ISSUE_REF" )
beforeP="$(git -C "$A" ls-remote origin "$ISSUE_REF" | awk '{print $1}')"
( cd "$A" && . "$CLAIMS_SH" && claim_prune ) >/dev/null 2>&1
afterP="$(git -C "$A" ls-remote origin "$ISSUE_REF" | awk '{print $1}')"
if [ -n "$beforeP" ] && [ -z "$afterP" ]; then
  echo "  ✅ claim_prune reaps an EXPIRED issue claim (the abandon path decays)"; PASS=$((PASS+1))
else echo "  ❌ claim_prune left the expired issue claim behind ($beforeP -> ${afterP:-<gone>})"; FAIL=$((FAIL+1)); fi

# I9. THE RELEASE-RECORD CONVENTION (claims.sh). The claim is taken by orch-loop.sh and released by
# a DIFFERENT process (chain-merge.sh's trap, or dispatch-merge.sh on the path that never spawns a
# chain), so the commit that was pushed is handed over in a file. One writer convention and one
# reader implementation live together in claims.sh; these pin both, plus the two ways the handover
# can go wrong: an EMPTY record (must delete nothing — an unfenced delete would remove a PEER's
# claim) and a MISSING record (nothing to do, rc=1).
cleanup_issue_ref
SR="$A/state-i9"; mkdir -p "$SR"
# (1) an empty commit is REFUSED, and writes no file at all
( cd "$A" && . "$CLAIMS_SH" && claim_issue_record "$SR" "$ISSUE" "" ) >/dev/null 2>&1; rcEmpty=$?
[ "$rcEmpty" = "1" ] && [ ! -e "$SR/state/issueclaim-$ISSUE" ] \
  && { echo "  ✅ claim_issue_record REFUSES an empty commit (writes nothing)"; PASS=$((PASS+1)); } \
  || { echo "  ❌ claim_issue_record accepted an empty commit (rc=$rcEmpty, file=$([ -e "$SR/state/issueclaim-$ISSUE" ] && echo present || echo absent))"; FAIL=$((FAIL+1)); }
# (2) the real path: acquire, record, release through the record
outA=$(runA claim_issue_acquire "$A" "$ISSUE" 600); rcA=$?
A_SHA="$(git -C "$A" ls-remote origin "$ISSUE_REF" | awk '{print $1}')"
ck "I9: A acquires the issue to be released through the record" "^0$" "$rcA"
( cd "$A" && . "$CLAIMS_SH" && claim_issue_record "$SR" "$ISSUE" "$A_SHA" ) >/dev/null 2>&1; rcRec=$?
[ "$rcRec" = "0" ] && [ -s "$SR/state/issueclaim-$ISSUE" ] \
  && { echo "  ✅ claim_issue_record writes the commit (rc=0)"; PASS=$((PASS+1)); } \
  || { echo "  ❌ claim_issue_record did not write the record (rc=$rcRec)"; FAIL=$((FAIL+1)); }
outRec=$( ( cd "$A" && . "$CLAIMS_SH" && claim_issue_release_record "$SR" "$A" "$ISSUE" ) ); rcRec2=$?
ck "I9: claim_issue_release_record releases the claim (fenced)" "released" "$outRec"
[ "$rcRec2" = "0" ] && { echo "  ✅ ...and reports success (rc=0)"; PASS=$((PASS+1)); } \
                    || { echo "  ❌ ...reported rc=$rcRec2"; FAIL=$((FAIL+1)); }
gone_rec="$(git -C "$A" ls-remote origin "$ISSUE_REF" | awk '{print $1}')"
[ -z "$gone_rec" ] && [ ! -e "$SR/state/issueclaim-$ISSUE" ] \
  && { echo "  ✅ the ref AND the record are both gone"; PASS=$((PASS+1)); } \
  || { echo "  ❌ ref='$gone_rec' record=$([ -e "$SR/state/issueclaim-$ISSUE" ] && echo present || echo absent)"; FAIL=$((FAIL+1)); }
# (3) a MISSING record: nothing to do, rc=1, and NO push (a release with no fence must never happen)
( cd "$A" && . "$CLAIMS_SH" && claim_issue_release_record "$SR" "$A" "$ISSUE" ) >/dev/null 2>&1; rcNo=$?
[ "$rcNo" = "1" ] && { echo "  ✅ a missing record is a no-op (rc=1)"; PASS=$((PASS+1)); } \
                    || { echo "  ❌ a missing record returned rc=$rcNo (want 1)"; FAIL=$((FAIL+1)); }
# (4) an EMPTY record must not delete a PEER's claim — the unfenced-delete failure
cleanup_issue_ref
outB9=$(runB claim_issue_acquire "$B" "$ISSUE" 600); rcB9=$?
PEER_SHA="$(git -C "$A" ls-remote origin "$ISSUE_REF" | awk '{print $1}')"
ck "I9: B holds the issue for the empty-record case" "^0$" "$rcB9"
: > "$SR/state/issueclaim-$ISSUE"
( cd "$A" && . "$CLAIMS_SH" && claim_issue_release_record "$SR" "$A" "$ISSUE" ) >/dev/null 2>&1
survived="$(git -C "$A" ls-remote origin "$ISSUE_REF" | awk '{print $1}')"
[ -n "$PEER_SHA" ] && [ "$survived" = "$PEER_SHA" ] \
  && { echo "  ✅ an EMPTY record cannot delete a peer's claim"; PASS=$((PASS+1)); } \
  || { echo "  ❌ an empty record deleted/changed the peer's claim (${survived:-<gone>} vs $PEER_SHA)"; FAIL=$((FAIL+1)); }
[ ! -e "$SR/state/issueclaim-$ISSUE" ] && { echo "  ✅ the empty record is still consumed"; PASS=$((PASS+1)); } \
                                       || { echo "  ❌ the empty record was left behind"; FAIL=$((FAIL+1)); }
# (5) ⛔ THE GENERATION GUARD (2026-10-16 review). The record is keyed on the ISSUE, so the SAME box
# can become the holder again while its first chain is still running — after a lapsed lease — and the
# re-acquire OVERWRITES the record. A release that read the file when it fired would then fence on
# the NEW commit, which IS the ref tip, and delete the live holder's claim, freeing a busy issue for
# a peer: the duplicate this registry exists to prevent, and a fail-OPEN. A chain that captured its
# own commit must be refused, and the newer generation's record must SURVIVE for its own release.
cleanup_issue_ref
outB10=$(runB claim_issue_acquire "$B" "$ISSUE" 600); rcB10=$?
GEN_NEW="$(git -C "$A" ls-remote origin "$ISSUE_REF" | awk '{print $1}')"
ck "I9: B holds the issue for the generation case" "^0$" "$rcB10"
printf '%s\n' "$GEN_NEW" > "$SR/state/issueclaim-$ISSUE"
GEN_OLD="$(printf '%040d' 1)"
outGen=$( ( cd "$A" && . "$CLAIMS_SH" && claim_issue_release_record "$SR" "$A" "$ISSUE" "$GEN_OLD" ) 2>&1 ); rcGen=$?
surv_gen="$(git -C "$A" ls-remote origin "$ISSUE_REF" | awk '{print $1}')"
[ "$rcGen" != "0" ] && [ "$surv_gen" = "$GEN_NEW" ] \
  && { echo "  ✅ an OLDER generation's captured commit cannot release the NEWER holder's claim"; PASS=$((PASS+1)); } \
  || { echo "  ❌ the generation guard released the newer claim (rc=$rcGen, ${surv_gen:-<gone>} vs $GEN_NEW)"; FAIL=$((FAIL+1)); }
ck "I9: the refusal NAMES the newer generation" "NEWER generation" "$outGen"
[ -e "$SR/state/issueclaim-$ISSUE" ] \
  && { echo "  ✅ ...and the newer record is left for ITS release"; PASS=$((PASS+1)); } \
  || { echo "  ❌ the generation-refused release consumed the newer record"; FAIL=$((FAIL+1)); }
# (6) the READER a chain uses to capture its generation at start, and the matching generation's own
# release still working (the guard must not refuse the legitimate holder).
outGot="$( cd "$A" && . "$CLAIMS_SH" && claim_issue_record_commit "$SR" "$ISSUE" )"
ck "I9: claim_issue_record_commit returns the recorded generation" "^$GEN_NEW$" "$outGot"
( cd "$A" && . "$CLAIMS_SH" && claim_issue_release_record "$SR" "$A" "$ISSUE" "$GEN_NEW" ) >/dev/null 2>&1; rcOwn=$?
[ "$rcOwn" = "0" ] \
  && { echo "  ✅ the capture does NOT block the holder's OWN release"; PASS=$((PASS+1)); } \
  || { echo "  ❌ the holder could not release its own claim (rc=$rcOwn)"; FAIL=$((FAIL+1)); }
cleanup_issue_ref

# (7) ⛔ `CLAIM_COMMIT` MUST NOT CARRY A PREVIOUS ISSUE'S COMMIT INTO A FAILED ATTEMPT (cycle-2
# adversarial review). It is a GLOBAL that claims.sh resets only when it is SOURCED — once per
# controller cycle — so an acquire that fails BEFORE any push (rc=2: the ref is unreadable) used to
# leave the PREVIOUS issue's commit in it. orch-loop.sh's "rc=2 with a claim commit → write the
# handover record and try a fenced release" then wrote a record for an issue this attempt never
# claimed, consumed it, and logged a release that never happened. The fence keeps the registry safe,
# so this is state hygiene rather than a fail-open — but the log is what an operator reads.
PROBE_ISSUE="$(unclaimed_issue_number)" || {
  echo "❌ could not find an UNCLAIMED number for the I9 probe — refusing to run"
  exit 2
}
if [ "$PROBE_ISSUE" = "$ISSUE" ]; then
  PROBE_ISSUE="$(unclaimed_issue_number)" || {
    echo "❌ could not pick a DISTINCT unclaimed number for the I9 probe — refusing to run"; exit 2; }
  [ "$PROBE_ISSUE" = "$ISSUE" ] && { echo "❌ the I9 probe key collided with the main key — refusing to run"; exit 2; }
fi
PROBE_REF="refs/claims/issue-$PROBE_ISSUE"
# The probe's OWN commit, read from origin IMMEDIATELY after its successful acquire — that is the
# only ref this suite may delete for the probe. The teardown below fences on it, NEVER on whatever
# tip happens to be there (a lease on the observed value is not an ownership check: $A is wired to
# the LIVE origin, so "delete whatever is there" can destroy a peer's claim).
# ⛔ `own` IS `CLAIM_COMMIT`, NOT THE OBSERVED TIP (VGATE finding). `claims.sh` sets it ONLY on a
# SUCCESSFUL acquire; an acquire that lost a race to a live peer returns rc=1 and leaves the PEER's
# commit as the tip. Reading the tip here would hand the teardown the peer's commit as if it were
# ours — the fence would pass, and the delete would destroy a live claim. That is precisely the hazard
# this whole change exists to close, so the value must come from the acquire's own outcome.
probe_out=$( ( cd "$A" && export CLAIM_OWNER_HOST=boxA && . "$CLAIMS_SH"
               claim_issue_acquire 0 "$PROBE_ISSUE" 600 >/dev/null 2>&1; r1=$?
               own="${CLAIM_COMMIT:-}"
               CLAIM_REPO="$A/definitely-not-a-repo"
               claim_issue_acquire 0 "$PROBE_ISSUE" 600 >/dev/null 2>&1; r2=$?
               printf '%s|%s|%s|%s' "$r1" "$r2" "${CLAIM_COMMIT:-}" "$own" ) )
probe_rc1="${probe_out%%|*}"; probe_rest="${probe_out#*|}"
probe_rc2="${probe_rest%%|*}"; probe_rest2="${probe_rest#*|}"
probe_commit="${probe_rest2%%|*}"; probe_own="${probe_rest2#*|}"
ck "I9: the precondition acquire succeeded" "^0$" "$probe_rc1"
ck "I9: an acquire against an UNREADABLE registry returns rc=2" "^2$" "$probe_rc2"
[ -z "$probe_commit" ] \
  && { echo "  ✅ a failed acquire leaves CLAIM_COMMIT EMPTY (no previous issue's commit)"; PASS=$((PASS+1)); } \
  || { echo "  ❌ a failed acquire carried a STALE CLAIM_COMMIT ($probe_commit) — orch-loop would write a release record for an issue this box never claimed"; FAIL=$((FAIL+1)); }
# remove ONLY our own probe ref: the lease is the commit THIS run's acquire created. When the acquire
# did not win (rc1 != 0, so `own` is empty) nothing at all is deleted — a ref there belongs to whoever
# won, and "it must be mine because I asked" is exactly the reasoning that deletes a peer's claim.
probe_owned=0; probe_now=""
[ "$probe_rc1" = "0" ] && probe_now="$(git -C "$A" ls-remote origin "$PROBE_REF" | awk '{print $1}')"
case "$(probe_fence "$probe_rc1" "$probe_own" "$probe_now")" in
  delete)
    probe_owned=1
    git -C "$A" push -q --force-with-lease="$PROBE_REF:$probe_own" origin ":$PROBE_REF" 2>/dev/null
    echo "  ✅ the probe ref is removed from origin (fenced on OUR commit)"
    PASS=$((PASS+1)) ;;
  *)
    if [ "$probe_rc1" != "0" ]; then
      echo "  ⚠️ the probe never held a claim (rc1=$probe_rc1) — deleting NOTHING at $PROBE_REF"
    else
      echo "  ⚠️ the probe ref moved (${probe_now:-<gone>} != ${probe_own:-<none>}) — leaving it alone"
    fi
    PASS=$((PASS+1)) ;;
esac
# the DECISION TABLE itself — including the case the VGATE found: the acquire lost the race, yet the
# tip happens to equal the value we read, so a tip-only fence would have deleted the winner's claim.
ck "I9: the fence deletes when the acquire won and the tip is still ours" "^delete$" "$(probe_fence 0 abc abc)"
ck "I9: the fence deletes NOTHING when the acquire LOST the race (tip == what we read)" "^skip$" "$(probe_fence 1 abc abc)"
ck "I9: the fence deletes NOTHING when the tip moved" "^skip$" "$(probe_fence 0 abc def)"
ck "I9: the fence deletes NOTHING with no commit of our own" "^skip$" "$(probe_fence 0 '' abc)"
# ⛔ THE TEARDOWN PATH MUST BE EXERCISED, and the leak check must run unconditionally (adversarial
# review of the fence fix): with everything above in `if owned`, a broken `ls-remote` or a fence that
# silently took the skip branch leaks the ref and reports ✅. So (a) the acquire must have WON on a
# key chosen unclaimed — otherwise the run proved nothing about deletion — and (b) the ref must then
# be gone, whatever path was taken.
ck "I9: the probe's acquire WON, so its teardown path is actually exercised" "^1$" "$probe_owned"
probe_left="$(git -C "$A" ls-remote origin "$PROBE_REF" 2>/dev/null | wc -l | tr -d ' ')"
if [ "$probe_owned" = "1" ]; then
  [ "$probe_left" = "0" ] && { echo "  ✅ the probe ref is gone"; PASS=$((PASS+1)); } \
                             || { echo "  ❌ the probe ref leaked ($PROBE_REF)"; FAIL=$((FAIL+1)); }
else
  # we never held it: nothing may have been deleted, so a ref here belongs to whoever won
  [ "$probe_left" != "0" ] && { echo "  ✅ a ref we never held was left untouched"; PASS=$((PASS+1)); } \
                             || { echo "  ❌ a ref we never HELD disappeared ($PROBE_REF)"; FAIL=$((FAIL+1)); }
fi
cleanup_issue_ref

echo
echo "=== I10. AN UNREADABLE CLOCK IS NOT EVIDENCE OF EXPIRY (#1850 review) ==="
# ⛔ `[ "" -le "$until" ]` prints "integer expression expected" and evaluates FALSE. The pre-change
# reader fell THROUGH that comparison into `return 0` (CLEAN) — a FALSE CLEAN whenever `date` could
# not be read, and the one direction this gate must never fail in: it duplicates the work the
# registry exists to serialise. The clock is a SECOND input to the same decision, so it is guarded.
cleanup_issue_ref
outC=$(runA claim_issue_acquire "$A" "$ISSUE" 600); rcC=$?
ck "I10: A holds the issue before the clock is broken" "^0$" "$rcC"
clock_pref=$( ( cd "$B" && export CLAIM_OWNER_HOST=boxB && . "$CLAIMS_SH" && date() { echo notanumber; } && claim_issue_preflight "$ISSUE" ) 2>&1 ); rcC2=$?
ck "I10: an unreadable clock is INCOMPLETE (rc=2), never CLEAN" "^2$" "$rcC2"
ck "...and the reason names the CLOCK, not a holder" "clock is unreadable" "$clock_pref"
cleanup_issue_ref

# I8. AN UNREADABLE REGISTRY IS INCOMPLETE, NEVER CLEAN. The read must distinguish "the ref does not
# exist" (ls-remote exits 0, empty) from "the remote could not be consulted" (non-zero) — collapsing
# the two reads an OUTAGE as "nobody holds it", which is the false CLEAN this gate exists to remove.
# Driven through the real function, with CLAIM_REPO pointed at a directory that is not a
# repository: `git -C <that> ls-remote` exits non-zero, which is exactly what an unreachable remote
# produces. ⛔ NOT a `_git() { git … "$@"; }` seam — an unresolved git VERB is the shape the checkout
# guard fails closed on (`unverifiable-verb`), and it would refuse to run this suite at all (the
# note above `_git_delegate` records that defect).
unreachable_preflight() {
  ( cd "$A" && CLAIM_REPO="$A/no-such-repo-$$" && . "$CLAIMS_SH" && claim_issue_preflight "$ISSUE" )
}
outX=$(unreachable_preflight); rcX=$?
echo "  unreachable registry rc=$rcX :: $outX"
ck "an UNREACHABLE registry is INCOMPLETE (rc=2), never CLEAN" "^2$" "$rcX"
ck "...and the reason says so" "UNREADABLE" "$outX"
ck "...and names the REPO when the repo is the reason (a wrong CLAIM_REPO refuses every issue)" \
   "not a readable directory: CLAIM_REPO=" "$outX"
# And the other direction: the SAME function on the SAME issue with a reachable registry and no
# claim must read CLEAN — otherwise the fail-closed check above could pass by always refusing.
cleanup_issue_ref
outY=$(runB claim_issue_preflight "$ISSUE"); rcY=$?
echo "  reachable registry, no claim rc=$rcY :: $outY"
ck "a reachable registry with NO claim reads CLEAN (rc=0)" "^0$" "$rcY"
ck "...and names the issue" "no claim on #$ISSUE" "$outY"
cleanup_issue_ref

echo
echo "=== C. THE CALLER'S CWD IS NOT PART OF A CLAIM (live Mac, 2026-10-18) ==="
# ⛔ THE MEASURED DEFECT (agent-infra, 2026-10-18). The controller runs under launchd with cwd `/`,
# which macOS denies reading from that context. `claims.sh` defaulted `CLAIM_REPO` to `.` (the
# caller's cwd) and every git call was `git -C "$CLAIM_REPO"`, so the claim commit could not be
# built: `[dispatch] #<n> NOT dispatched — could not build claim commit` for EVERY candidate, every
# cycle, while `gh` reads (which ignore cwd) looked healthy — the queue read as live and the fleet
# refused all work. The refusal arrived as an EMPTY STRING, with no repo, no cwd and no git error.
#
# Two properties, both driven through the REAL function:
#   C1  an acquire whose caller has an UNREADABLE cwd still SUCCEEDS (CLAIM_REPO derives from REPO)
#   C2  when it cannot, the reason NAMES the repo and the cwd instead of being empty
#
# ⛔ THE CWD IS MADE UNREADABLE, NOT JUST "NOT A REPO". A cwd that merely is not a git tree already
# fails with "not a git repository"; the launchd failure is `getcwd()` itself being denied, so the
# arm uses a mode-000 directory — the closest portable reproduction of the EPERM the live box hit
# (verified: `git -C . rev-parse` dies with "Unable to read current working directory").
# ⛔ NON-VACUITY IS ASSERTED, NOT ASSUMED: the probe reports a `witness=` line saying whether the
# cwd really was unusable, and the arm SKIPS (loudly, counted) if this environment can still read a
# 0000 directory — otherwise the test would silently become a normal-cwd test and pass forever.
CWD_PR=$(( PR + 11 ))
CWD_SHA="cwd$$-aaaaaaaa"
# The ref the helper will push, derived by SOURCING claims.sh (never re-implemented here) — the
# key shape is part of what the shipped code owns.
CWD_REF="$( ( cd "$A" && . "$CLAIMS_SH" && claim_ref "$CWD_PR" "$CWD_SHA" ) )"
CWD_TMP="/tmp/xb-claims-cwd.$$"; rm -rf "$CWD_TMP"; mkdir -p "$CWD_TMP"
cat > "$CWD_TMP/cwd-acquire.sh" <<'SH'
# cwd-acquire.sh <claims.sh> <box> <pr> <sha> <claim_repo|-> <repo|->
# Runs an acquire from a cwd that has been made UNREADABLE, and reports what happened.
set -u
CS="$1"; BOX="$2"; PRN="$3"; SHA="$4"; CREPO="$5"; RPO="$6"
LOCK="$(mktemp -d "${TMPDIR:-/tmp}/cwd-lock.XXXXXX")" || exit 111
cd "$LOCK" || exit 111
chmod 000 "$LOCK" || exit 112            # getcwd() now fails: the launchd cwd=/ shape
( # ⛔ `git -C .` here is a WITNESS, not a call path: it answers "is this cwd actually unusable?"
  if git -C . rev-parse --git-dir >/dev/null 2>&1; then echo "witness=cwd-usable"; else echo "witness=cwd-unreadable"; fi
  [ "$CREPO" = "-" ] || export CLAIM_REPO="$CREPO"
  [ "$RPO" = "-" ] || export REPO="$RPO"
  # ⛔ THE HOST SEAM, not a whole identity (agent-infra#2094 renamed it): a `CLAIM_OWNER_ID` whose host
  # segment is not the running host is now REFUSED LOUDLY on stderr, and that advisory lands on the
  # FIRST line of this probe's captured output — which is exactly the line C2 asserts on, so the reason
  # this arm exists for was masked by a warning about the test's own fixture. `CLAIM_OWNER_HOST`
  # overrides only the host, which is what a cross-box probe wants and what the `I` sections use.
  export CLAIM_OWNER_HOST=probe
  # shellcheck source=/dev/null
  . "$CS"
  claim_acquire "$BOX" "$PRN" "$SHA"; rc=$?
  # ⛔ THE RESULT IS NAMED, NOT "the first line that is not a witness/rc/commit". claims.sh emits
  # advisories on stderr about this probe's own fixture (the host seam, above), and taking the first
  # remaining line made C2 assert on a warning instead of on the reason it exists for.
  printf 'result=%s\n' "${CLAIM_RESULT:-}"
  printf 'rc=%s\ncommit=%s\n' "$rc" "${CLAIM_COMMIT:-}" )
CHMOD_RC=$?
chmod 755 "$LOCK" 2>/dev/null
rmdir "$LOCK" 2>/dev/null
exit $CHMOD_RC
SH
# C1 — CLAIM_REPO unset (the launchd shape: nothing sets it, so it derives from $REPO)
outC1="$( bash "$CWD_TMP/cwd-acquire.sh" "$CLAIMS_SH" "$A" "$CWD_PR" "$CWD_SHA" - "$A" 2>&1 )"
c1_witness="$(printf '%s\n' "$outC1" | sed -n 's/^witness=//p')"
c1_rc="$(printf '%s\n' "$outC1" | sed -n 's/^rc=//p')"
if [ "$c1_witness" != "cwd-unreadable" ]; then
  echo "  ⚠️ SKIP C1/C2 — this environment can still read a 0000-mode cwd (running as root?), so the"
  echo "     unreadable-cwd arm cannot be exercised here. The properties are NOT verified by this run."
  SKIPPED=$((SKIPPED+1))
else
  ck "C1: an acquire from an UNREADABLE cwd derives CLAIM_REPO and SUCCEEDS" "^0$" "$c1_rc"
  c1_tip="$(git -C "$A" ls-remote origin "$CWD_REF" 2>/dev/null | awk '{print $1}')"
  [ -n "$c1_tip" ] && { echo "  ✅ C1: the claim ref reached origin ($CWD_REF)"; PASS=$((PASS+1)); } \
                    || { echo "  ❌ C1: no claim ref on origin after a reported success ($CWD_REF)"; FAIL=$((FAIL+1)); }
  # The failure must be LEGIBLE. Before the fix this was the bare string "could not build claim
  # commit" with no repo, no cwd and no git error — the reason it took weeks to find.
  outC2="$( bash "$CWD_TMP/cwd-acquire.sh" "$CLAIMS_SH" "$A" "$(( PR + 12 ))" "$CWD_SHA" "$A/no-such-repo-$$" - 2>&1 )"
  c2_msg="$(printf '%s\n' "$outC2" | sed -n 's/^result=//p')"
  echo "  C2 reason: $c2_msg"
  ck "C2: an unusable CLAIM_REPO names the repo and the cwd in the reason" \
     "not a readable directory: CLAIM_REPO=.*cwd=" "$c2_msg"
  [ "$c2_msg" = "could not build claim commit" ] && rc=1 || rc=0
  ck "C2: ...and it is NOT the bare pre-fix string (an empty explanation)" "^0$" "$rc"
fi
# The probe's own ref is deleted here (fenced on the tip we observed), and CWD_REF is in the EXIT
# trap's list too, so an abort mid-arm cannot leave it behind.
c1_tip="$(git -C "$A" ls-remote origin "$CWD_REF" 2>/dev/null | awk '{print $1}')"
[ -n "$c1_tip" ] && git -C "$A" push -q --force-with-lease="$CWD_REF:$c1_tip" origin ":$CWD_REF" 2>/dev/null
cwd_left="$(git -C "$A" ls-remote origin "$CWD_REF" 2>/dev/null | wc -l | tr -d ' ')"
[ "$cwd_left" = "0" ] && { echo "  ✅ the cwd probe's ref is gone"; PASS=$((PASS+1)); } \
                       || { echo "  ❌ the cwd probe's ref leaked ($CWD_REF)"; FAIL=$((FAIL+1)); }

echo
# ⛔ EVERY key the suite creates, not just `$REF` (2026-10-16 review): the issue-keyed families were
# added to `cleanup_remote` but not to this assertion, so a partially-failed teardown reported
# "clean" while `refs/claims/issue-<N>` stayed on the shared origin.
echo "=== cleanup ==="
cleanup_ref
left=0; leaked=""
for _r in "$REF" "$OTHER_REF" "$ISSUE_REF" "$PRNUM_REF"; do
  _n="$(git -C "$A" ls-remote origin "$_r" | wc -l | tr -d ' ')"
  [ "$_n" = "0" ] || { left=$((left + _n)); leaked="$leaked $_r"; }
done
echo "  refs left: $left${leaked:+ (under:${leaked})}"
[ "$left" = "0" ] && { echo "  ✅ clean"; PASS=$((PASS+1)); } || { echo "  ❌ leak"; FAIL=$((FAIL+1)); }
git -C "$A" for-each-ref --format='  leftover local scratch: %(refname)' refs/claims-cache | head -3

echo
echo "================ RESULT: $PASS passed, $FAIL failed$([ "${SKIPPED:-0}" -gt 0 ] && printf ', %s SKIPPED' "$SKIPPED") ================"
[ "$FAIL" -eq 0 ]
