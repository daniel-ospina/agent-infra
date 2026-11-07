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
#   I6  claim_issue_status reports the lease; an UNREADABLE lease is an ABSTENTION (never reported
#       CLEAN, never reported as live, never stolen — #3203); a claim ref whose
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
cleanup_boxes() { rm -rf "$A" "$B" "$SNAP" "${CWD_TMP:-}" "${P4ORIG:-}" "${P4BOX:-}" 2>/dev/null; }
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
echo "=== 2d. a FAILED PUBLISH publishes NOTHING and keeps the last good snapshot (#2466 review) ==="
# ⛔ THE FAIL-OPEN THIS PR REMOVED CAN COME BACK WITH EVERY SUITE GREEN, which is why this arm
# exists. The writer used to discard its own exit status and run `mv … || true`, so a failed write
# published a 0-byte snapshot; a header-less snapshot falls back to a fresh mtime, so every key then
# read `claim-absent` (FREE) while the cycle log printed `read=ok`. Reverting the writer to that shape
# reddened NOTHING: `claim_snapshot` is only ever driven on its writable path.
#
# The failure is forced deterministically and as any uid: squat a DIRECTORY on the writer's own
# `$out.body.$$` path, so the body write cannot happen at all (a read-only dir would be ignored by
# root, which would make the arm vacuous on a root runner).
# The assertion is the OUTCOME a reader sees, not just a flag — and the DISCRIMINATOR here is that
# the previous bytes survive at all (the pre-fix writer replaced them with a 32-byte header-only
# snapshot, which is what made every key read FREE). The `reader=` token is PRINTED for triage but
# deliberately NOT asserted: it depends on a live claim existing at this point in the suite, and on a
# box where the claim machinery is itself red that would make this arm fail for an unrelated reason.
pubfail() { # <box-dir> <snapshot-file> -> tokens, one per line
  ( cd "$1" && export CLAIM_OWNER_HOST=boxA && . "$CLAIMS_SH" \
    && claim_snapshot "$2" >/dev/null 2>&1 || { echo "setup=failed"; exit 0; } \
    && cp "$2" "$2.before" \
    && mkdir -p "$2.body.$$" \
    && claim_snapshot "$2" >/dev/null 2>&1; rc=$? \
    && printf 'rc=%s\nwrite=%s\nfetch=%s\n' "$rc" "${CLAIM_SNAPSHOT_WRITE:-?}" "${CLAIM_SNAPSHOT_FETCH:-?}" \
    && if cmp -s "$2" "$2.before"; then echo "published=none"; else echo "published=replaced"; fi \
    && if [ -e "$2.$$" ]; then echo "tmp=left"; else echo "tmp=clean"; fi \
    && echo "reader=$(claim_snapshot_verdict "$2" "$(claim_ref "$PR" "$SHA")" >/dev/null 2>&1; echo $?)" )
}
pf="$(pubfail "$A" "$SNAP")"
echo "  failed-publish tokens => $(echo "$pf" | tr '\n' ' ')"
ck "a failed PUBLISH still returns 0 (the caller's contract)" '^0$' "$(echo "$pf" | sed -n 's/^rc=//p')"
ck "…and is reported as a WRITE failure, not a FETCH one" '^failed$' "$(echo "$pf" | sed -n 's/^write=//p')"
ck "…while the FETCH keeps its own (successful) answer" '^ok$' "$(echo "$pf" | sed -n 's/^fetch=//p')"
# ⛔ THIS IS THE DISCRIMINATOR. The pre-fix writer replaced the file with a 32-byte header-only
# snapshot (that is what made every key read FREE); it cannot leave the previous bytes intact.
ck "…nothing is published, so the last GOOD snapshot survives byte-identical" '^none$' "$(echo "$pf" | sed -n 's/^published=//p')"
ck "…and no temp file is left behind" '^clean$' "$(echo "$pf" | sed -n 's/^tmp=//p')"
rm -rf "$SNAP.before" "$SNAP.body."* 2>/dev/null || true
rm -f "$SNAP"
# ⛔ AND THE OTHER HALF OF THE SAME INVARIANT, WHICH IS THE ONE THE READER SEES (review, P1): a failed
# publish with NO previous snapshot must leave the key UNREADABLE (rc 2), never FREE (rc 0). The
# pre-fix writer published a 0-byte snapshot here (it discarded its own write status and ran
# `mv … || true`), and a header-less file is believed on its fresh mtime — so every key read
# `claim-absent`, i.e. freedom, from a read that never happened. Nothing above can see that: the arm
# above is graded on the bytes SURVIVING, and this one on the verdict the sweep consumes.
# The failure is forced the same root-proof way (squat a DIRECTORY on the body path, not chmod).
pubfail_none() { # <box-dir> <snapshot-file> -> tokens
  ( cd "$1" && export CLAIM_OWNER_HOST=boxA && . "$CLAIMS_SH" \
    && rm -f "$2" \
    && mkdir -p "$2.body.$$" \
    && claim_snapshot "$2" >/dev/null 2>&1; rc=$? \
    && printf 'rc=%s\nwrite=%s\n' "$rc" "${CLAIM_SNAPSHOT_WRITE:-?}" \
    && if [ -e "$2" ]; then echo "published=replaced"; else echo "published=none"; fi \
    && echo "reader=$(claim_snapshot_verdict \"$2\" \"$(claim_ref "$PR" "$SHA")\" >/dev/null 2>&1; echo $?)" )
}
pn="$(pubfail_none "$A" "$SNAP")"
echo "  failed-publish-with-no-previous tokens => $(echo "$pn" | tr '\n' ' ')"
ck "no previous snapshot + a failed publish publishes NOTHING" '^none$' "$(echo "$pn" | sed -n 's/^published=//p')"
ck "…and the READER answers claim-unreadable (rc 2), not freedom — the sweep acts on nothing" '^2$' "$(echo "$pn" | sed -n 's/^reader=//p')"
rm -rf "$SNAP.body."* 2>/dev/null || true
rm -f "$SNAP"

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
# `until=$(( now + ttl ))` wraps NEGATIVE at or above 2**63; `_lease_of`'s anchored ASCII-digit match cannot parse the
# minus sign, an unparseable lease can no longer be reaped on its own term, so the head would be
# frozen across ALL boxes (before #3203, with no automatic recovery at all) — and even now it would
# wait out CLAIM_UNREADABLE_LEASE_MAX_AGE. The shipped callers now validate
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
else echo "  ❌ lease_until='$hlv' is absent/negative/oversized — unparseable, so read as never-expired and never reapable before #3203"; FAIL=$((FAIL+1)); fi
cleanup_ref

echo
echo "=== P3e. a FOREIGN oversized (>=2**63) lease is an ABSTENTION, not STOLEN ==="
# `[ "$now" -le "$held_until" ]` ERRORS (rc=2, and an errored test is FALSE) at or above 2**63, so
# control fell through to the RECLAIM CAS and STOLE a claim this code means to treat as NOT EXPIRED; the
# "unparseable = never expired" branch covered an ABSENT lease but not an oversized-but-numeric one. The seed
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
ck "an oversized (>=2**63) lease reads as UNPARSEABLE => ABSTENTION (rc=1, never stolen)" "^1$" "$rcH"
ck "the refusal says it cannot parse the lease" "no parseable lease" "$outH"
stillH="$(git -C "$A" ls-remote origin "$REF" | awk '{print $1}')"
if [ -n "$EH" ] && [ "$stillH" = "$EH" ]; then
  echo "  ✅ the oversized-lease claim was NOT stolen"; PASS=$((PASS+1))
else echo "  ❌ the claim was STOLEN or the seed failed ($stillH vs seed '$EH')"; FAIL=$((FAIL+1)); fi
cleanup_ref

echo
echo "=== P3f. a foreign UNREADABLE lease (0, and the -5 that collapses to it) ABSTAINS, not STOLEN ==="
# claim_acquire's unparseable branch is `[ -z "$held_until" ] || [ "$held_until" = "0" ]`: a claim
# whose commit message carries `lease_until=0` (or a negative, which _lease_of's anchored ASCII-digit match cannot match
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
  ck "lease_until=$L reads as UNPARSEABLE => ABSTENTION (rc=1, never stolen)" "^1$" "$rcL"
  ck "the refusal for lease_until=$L says it cannot parse the lease" "no parseable lease" "$outL"
  stillL="$(git -C "$A" ls-remote origin "$REF" | awk '{print $1}')"
  if [ -n "$EL" ] && [ "$stillL" = "$EL" ]; then
    echo "  ✅ the lease_until=$L claim was NOT stolen"; PASS=$((PASS+1))
  else echo "  ❌ the lease_until=$L claim was STOLEN or the seed failed ($stillL vs seed '$EL')"; FAIL=$((FAIL+1)); fi
done
cleanup_ref

echo
echo "=== P4. an UNPARSEABLE lease is an ABSTENTION with a BOUNDED expiry, never a live claim (#3203) ==="
# ⛔ THE DEFECT THIS PINS, MEASURED (agent-infra#3203): a claim whose lease no reader can parse was
# unreclaimable AND unprunable — `_lease_unparseable` -> `_lease_is_live` answered LIVE (rc 1),
# `_claim_acquire_at` returned before its orphan arm, and `claim_prune` skipped the ref on BOTH arms
# (expiry said "live", and the orphan arm had an explicit `_lease_unparseable` continue). The only
# cure was a human `git push origin :refs/claims/<key>`: the #8175 shape, and a batch that folds N
# PRs inherits it N times. The fix must hold in BOTH directions at once, so this section asserts both
# and a mutant for each is quoted in the PR:
#   (i)  it must NOT hold forever -> `claim_prune` reaps it once the claim's own COMMIT is older than
#        CLAIM_UNREADABLE_LEASE_MAX_AGE (18000s = CLAIM_ISSUE_TTL, the longest shipped lease);
#   (ii) it must NOT silently grant the claim -> every READER still refuses while the ref exists —
#        never CLEAN, never `claim-held`, never rc 0 — and STILL refuses past that bound, because
#        the bound is the REAPER's schedule, not a reader's licence. The state change is a DELETION
#        that names the fault, never the passage of time.
P4NOW="$(date +%s)"
# ⛔ FULLY HERMETIC (a bare origin created for this section), and NOT the live registry. Two reasons,
# both measured: (1) this section DELETES refs, and a mistake here must never reap a claim on the
# shared origin; (2) the live-origin arms of this suite are the historical source of its flakiness
# (a transient `ls-remote` reads as "absent"), and an assertion whose fixture depends on the network
# cannot discriminate a mutant from a hiccup. The issue's own measurement used a fresh
# `git init --bare` origin for the same reason.
P4ORIG="/tmp/xb-claims-3203-orig.$$"; P4BOX="/tmp/xb-claims-3203-box.$$"
rm -rf "$P4ORIG" "$P4BOX"
git init -q --bare "$P4ORIG"; git init -q "$P4BOX"; git -C "$P4BOX" remote add origin "$P4ORIG"
p4_run() { ( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" CLAIM_OWNER_HOST=boxA && . "$CLAIMS_SH" && "$@" ); }
p4_seed() { # <ref-name> <owner> <lease> <age-seconds-ago> -> prints the commit it pushed
  local c
  c="$( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" && . "$CLAIMS_SH" && GIT_COMMITTER_DATE="@$(( P4NOW - $4 )) +0000" _claim_commit "$2" "$3" )"
  ( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" && . "$CLAIMS_SH" && _git push -q origin "$c:refs/claims/$1" ) || return 1
  printf '%s' "$c"
}
p4_has() { [ -n "$(git -C "$P4BOX" ls-remote origin "refs/claims/$1" 2>/dev/null)" ]; }
p4_prune() { ( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" && . "$CLAIMS_SH" && claim_prune ) 2>&1; }
p4_verdict() { # <ref-name> -> "RC=<n> WORD=<word>" from a FRESH snapshot of the hermetic origin
  # ⛔ `;` AFTER THE SNAPSHOT, NOT `&&`: the verdict legitimately returns 1 for the abstention this
  # section is asserting, and an `&&` chain would swallow the very output the assertion reads (that
  # is how the first draft of A10 reported an empty string instead of a red verdict).
  ( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" && . "$CLAIMS_SH" \
    && claim_snapshot "$P4BOX/snap3203" >/dev/null 2>&1; \
    claim_snapshot_verdict "$P4BOX/snap3203" "refs/claims/$1" >/dev/null 2>&1
    printf 'RC=%s\nWORD=%s' "$?" "${CLAIM_VERDICT:-}" ) 2>/dev/null
}
# ── (ii) THE READERS. `pr-3203` is ALSO older than the reap bound, so A4 is the "never granted by
# age" assertion: a "fix" that let a reader expire an unparseable lease by its commit age reddens it.
P4C="$(p4_seed pr-3203 weird3203 HAVOC 40000)"; echo "  seeded an unparseable-lease claim (lease_until=HAVOC, commit 40000s old): $P4C"
outP4=$(p4_run claim_pr_acquire "" 3203); rcP4=$?
echo "  acquire rc=$rcP4 :: $outP4"
ck "A1 [RED→GREEN] an unparseable lease is NOT stolen (rc=1)" "^1$" "$rcP4"
ck "A2 [RED→GREEN] ...and the refusal names the ABSTENTION token, not a live holder" "held-by-unreadable-lease" "$outP4"
case "$outP4" in *held-by-live*) P4HL=0 ;; *) P4HL=1 ;; esac
ck "A3 [RED→GREEN] ...and does NOT claim the lease is live (no held-by-live token)" "^1$" "$P4HL"
P4TIP="$(git -C "$P4BOX" ls-remote origin refs/claims/pr-3203 | awk '{print $1}')"
# BOTH halves: the ref is untouched AND the refusal never became an acquisition. `rcP4` is part of the
# assertion because "nothing was stolen" is exactly the pair (the tip did not move, and the caller was
# told no) — a mutant that only flips the return code moves no ref and would otherwise pass here.
[ -n "$P4C" ] && [ "$P4TIP" = "$P4C" ] && [ "$rcP4" = "1" ] && P4KEEP=0 || P4KEEP=1
ck "A4 [RED→GREEN] PAST the reap bound the ref is untouched AND still refuses (the bound is the reaper's schedule, never a reader's licence)" "^0$" "$P4KEEP"
# The SNAPSHOT verdict word: the reader the controller's sweep and its spawn guard share. Before the
# fix it published `claim-held` — "a live, non-orphaned window" — for a window nobody could read.
P4SNAP="$A/state-snap3203"
printf '#claim-snapshot\t%s\tok\t1\nrefs/claims/3203-ffffffffffff\tweird3203:9\tHAVOC\n' "$P4NOW" > "$P4SNAP"
P4V="$( cd "$A" && . "$CLAIMS_SH" && claim_snapshot_verdict "$P4SNAP" refs/claims/3203-ffffffffffff >/dev/null 2>&1
       printf 'RC=%s\nWORD=%s\nWHY=%s' "$?" "${CLAIM_VERDICT:-}" "${CLAIM_VERDICT_WHY:-}" )"
echo "  snapshot verdict: $(printf '%s' "$P4V" | tr '\n' ' ')"
ck "A5 [RED→GREEN] the snapshot verdict is the ABSTENTION word claim-lease-unreadable" "^claim-lease-unreadable$" "$(printf '%s\n' "$P4V" | sed -n 's/^WORD=//p')"
case "$P4V" in *"WORD=claim-held"*) P4W=0 ;; *) P4W=1 ;; esac
ck "A6 [RED→GREEN] ...and is NOT published as claim-held (a live, non-orphaned window)" "^1$" "$P4W"
ck "A7 [RED→GREEN] ...it still BLOCKS (rc=1): an abstention is never freedom" "^1$" "$(printf '%s\n' "$P4V" | sed -n 's/^RC=//p')"
ck "A8 [RED→GREEN] ...and its reason names the bounded reap that will end the block" "claim_prune reaps it" "$(printf '%s' "$P4V" | sed -n 's/^WHY=//p')"
# ── (i) THE BOUNDED EXPIRY, on the same hermetic origin ────────────────────────────────────────
p4_seed p4-young   weird3203 HAVOC 0      >/dev/null
p4_seed p4-future  weird3203 HAVOC -40000 >/dev/null
p4_seed p4-expired oldbox    1000000000 0 >/dev/null
p4_has pr-3203 && p4_has p4-young && p4_has p4-future && p4_has p4-expired; P4SETUP=$?
ck "A9 (setup) an aged (pr-3203), a young, a future-dated and an EXPIRED claim are all planted on the hermetic origin" "^0$" "$P4SETUP"
P4PRE="$(p4_verdict pr-3203)"
echo "  pre-prune read of the AGED key: $(printf '%s' "$P4PRE" | tr '\n' ' ')"
ck "A10 [RED→GREEN] before the reap the aged key still ABSTAINS (rc=1, never claim-held)" "^RC=1 WORD=claim-lease-unreadable$" "$(printf '%s' "$P4PRE" | tr '\n' ' ')"
P4OUT="$(p4_prune)"
echo "  prune output:"; printf '%s\n' "$P4OUT" | sed 's/^/    /'
ck "A11 [RED→GREEN] claim_prune REAPS the unparseable-lease claim once its commit is past the bound" "pruned unreadable-lease refs/claims/pr-3203" "$P4OUT"
p4_has pr-3203 && P4GONE=1 || P4GONE=0
ck "A12 [RED→GREEN] ...and the ref is really GONE from the origin (the eternal block ended)" "^0$" "$P4GONE"
p4_has p4-young && P4YOUNG=0 || P4YOUNG=1
ck "A13 [RED→GREEN] a YOUNG unparseable claim is NOT reaped (the bound gates the arm; it is not reap-everything)" "^0$" "$P4YOUNG"
ck "A14 [RED→GREEN] ...and the pass NAMES it as kept, with its age (an abstention reaches the operator)" "kept unreadable-lease refs/claims/p4-young" "$P4OUT"
p4_has p4-future && P4FUT=0 || P4FUT=1
ck "A15 [RED→GREEN] a FUTURE-dated claim commit KEEPS its claim: an unmeasurable age is not evidence of expiry" "^0$" "$P4FUT"
ck "A16 [RED→GREEN] ...and says why, instead of dropping it silently" "AHEAD of this box's clock" "$P4OUT"
ck "A17 [PINNED] the EXPIRED arm still reaps (the new arm did not displace it)" "pruned expired refs/claims/p4-expired" "$P4OUT"
P4POST="$(p4_verdict pr-3203)"
echo "  post-prune read of the AGED key: $(printf '%s' "$P4POST" | tr '\n' ' ')"
ck "A18 [RED→GREEN] after the DELETION the key reads free (claim-absent, rc=0) — the state change is the reap, not the clock" "^RC=0 WORD=claim-absent$" "$(printf '%s' "$P4POST" | tr '\n' ' ')"
# ── the bound's own guard rails: a garbage tunable, and an UNREADABLE local clock ──
# Both are the arm's silent-failure modes: a garbage bound is not validated before it is used (and an
# unvalidated `-le` ERRORS, which is FALSE, i.e. it reaps on a value nobody checked), and an EMPTY
# `date` used to be read as epoch 0 and reported as clock SKEW — the wrong cause for a clock this box
# could not read at all. (The `12:34:56` shape, whose arithmetic error aborts the pass, is guarded by
# the same top-of-function check; these assertions pin the two that are reachable through the test seam.)
p4_seed pr-3205 weird3203 HAVOC 40000 >/dev/null
outP4BG=$( ( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" CLAIM_OWNER_HOST=boxA CLAIM_UNREADABLE_LEASE_MAX_AGE=abc \
              && . "$CLAIMS_SH" && claim_prune ) 2>&1 )
ck "A21 [RED→GREEN] a GARBAGE CLAIM_UNREADABLE_LEASE_MAX_AGE is clamped to the shipped 18000s (asserted on the bound the line NAMES: unclamped, the -le test ERRORS on 'abc', an errored test is FALSE, and the arm reaps on a value it never validated — the fail-OPEN direction)" "PAST the 18000s bound" "$outP4BG"
p4_seed pr-3206 weird3203 HAVOC 40000 >/dev/null
# A NON-EMPTY, NON-NUMERIC CLOCK ("12:34:56") IS THE DISCRIMINATING SEAM. An empty one is caught by
# the `[ -z "$now" ]` branch even WITHOUT the top-of-function normalisation; a value that is invalid
# arithmetic syntax makes the age arithmetic a SYNTAX ERROR that kills the subshell, so the pass stops
# at the first unparseable ref and every later ref is never examined. Asserting a line for BOTH seeded
# refs is what pins "the pass completed", which an empty clock cannot discriminate.
outP4CK=$( ( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" CLAIM_OWNER_HOST=boxA && . "$CLAIMS_SH" \
              && date() { printf '12:34:56\n'; } && claim_prune ) 2>&1 )
ck "A22 [RED→GREEN] an UNREADABLE local clock reaps nothing and names the CLOCK (not clock skew)" "the LOCAL CLOCK is unreadable" "$outP4CK"
case "$outP4CK" in *"AHEAD of this box's clock"*) P4CK=0 ;; *) P4CK=1 ;; esac
ck "A23 [RED→GREEN] ...and does NOT misblame clock SKEW for a clock it could not read" "^1$" "$P4CK"
p4_has pr-3206 && P4CKEEP=0 || P4CKEEP=1
ck "A24 [RED→GREEN] ...and the past-bound claim SURVIVES that pass: no age, no reap (fail-closed)" "^0$" "$P4CKEEP"
# ── THE WRITER SIDE: no lease is MINTED on a clock this box cannot read ────────────────────────
# ⛔ MEASURED FAIL-OPEN (review, agent-infra#3203): with `date` broken, `until=$(( now + ttl ))` is
# `0 + ttl`, so the acquire pushed a claim stamped `lease_until=1800` (epoch 1970) — which `_lease_is_live`
# reads EXPIRED, so any peer may STEAL the claim this box just acquired. An agent must not be able to
# defeat the registry by breaking the clock, so the mint is refused.
outP4AC=$( ( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" CLAIM_OWNER_HOST=boxA && . "$CLAIMS_SH" \
             && date() { return 3; } && claim_pr_acquire "" 3207 ) 2>/dev/null ); rcP4AC=$?
echo "  acquire with an UNREADABLE CLOCK rc=$rcP4AC :: $outP4AC"
ck "A25 [RED→GREEN] a WRITER refuses to mint a lease on an unreadable clock (never an epoch-0 term)" "held-by-unreadable-clock" "$outP4AC"
ck "A26 [RED→GREEN] ...and the refusal is REFUSED (rc 1), never the INFRA code rc 2 that makes every PR-claim consumer proceed" "^1$" "$rcP4AC"
p4_has pr-3207 && P4ACMINT=1 || P4ACMINT=0
ck "A27 [RED→GREEN] ...and NOTHING was pushed: no claim exists to be stolen as already-expired" "^0$" "$P4ACMINT"
# AND WITH A CLAIM ALREADY HELD (review, agent-infra#3203 — the P1): the answer must still be a
# REFUSAL. If this path answered rc 2, merge-one.sh/fix-one.sh would read it as "registry unavailable"
# and proceed WITHOUT the cross-box exclusion — a broken clock would drop the gate.
P4PEER="$(p4_seed pr-3208 peerbox "$(( P4NOW + 3600 ))" 0)"
outP4PK=$( ( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" CLAIM_OWNER_HOST=boxA && . "$CLAIMS_SH" \
             && date() { return 3; } && claim_pr_acquire "" 3208 ) 2>/dev/null ); rcP4PK=$?
echo "  acquire over a PEER claim with an UNREADABLE CLOCK rc=$rcP4PK :: $outP4PK"
ck "A28 [RED→GREEN] a broken clock still REFUSES a peer-held claim (rc 1, never the infra rc 2)" "^1$" "$rcP4PK"
P4PKTIP="$(git -C "$P4BOX" ls-remote origin refs/claims/pr-3208 | awk '{print $1}')"
[ -n "$P4PEER" ] && [ "$P4PKTIP" = "$P4PEER" ] && P4PKK=0 || P4PKK=1
ck "A29 [RED→GREEN] ...and the peer claim is untouched (a refusal is not a release)" "^0$" "$P4PKK"
# THE CEILING (review, agent-infra#3203): a 9-digit override (~31 years) would re-create the eternal
# block as "configuration". 700000s is past the 7-day ceiling and short of 999999999, so a clamped arm
# REAPS and an unclamped one KEEPS — the only fixture that distinguishes the two.
p4_seed pr-3209 weird3203 HAVOC 700000 >/dev/null
outP4CE=$( ( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" CLAIM_OWNER_HOST=boxA CLAIM_UNREADABLE_LEASE_MAX_AGE=999999999 \
              && . "$CLAIMS_SH" && claim_prune ) 2>&1 )
ck "A30 [RED→GREEN] a ~31-year override is clamped to the 7-day ceiling, so the bound stays a BOUND" "pruned unreadable-lease refs/claims/pr-3209" "$outP4CE"
# AN UNMEASURABLE AGE MUST NOT BECOME A FABRICATED ONE (review, agent-infra#3203 — T3). A ref that
# points at a NON-COMMIT object has no committer stamp: _claim_commit_time returns rc 1, so the age is
# unmeasurable. Without the `-z "$ct"` guard the arithmetic invents an age from nothing and REAPS.
( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" && . "$CLAIMS_SH" \
  && b="$(printf 'not a claim commit' | _git hash-object -w --stdin)" && _git push -q --force origin "$b:refs/claims/pr-3210" ) 2>/dev/null
p4_has pr-3210 && P4BLOBSEED=0 || P4BLOBSEED=1
ck "A31a (setup) a claim ref pointing at a NON-COMMIT object is planted" "^0$" "$P4BLOBSEED"
outP4BL=$( ( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" CLAIM_OWNER_HOST=boxA && . "$CLAIMS_SH" && claim_prune ) 2>&1 )
ck "A31 [RED→GREEN] a claim whose commit time cannot be read is NAMED as unmeasurable, not reaped on a fabricated age" "AGE IS UNMEASURABLE" "$outP4BL"
p4_has pr-3210 && P4BLOBKEEP=0 || P4BLOBKEEP=1
ck "A32 [RED→GREEN] ...and the ref SURVIVES (no stamp, no age, no reap)" "^0$" "$P4BLOBKEEP"
# A STAMP THAT IS ALL DIGITS BUT NOT A TIME (review, agent-infra#3203 — P1). `0000009999` passes a
# digit-shape check but `$(( now - ct ))` reads a LEADING-ZERO operand as OCTAL, so it aborted the
# arithmetic with `value too great for base` — a fatal error that killed the prune subshell. Every ref
# sorting after the crafted one was then never examined, nothing was named, and the pass exited 0: the
# eternal block, restored. `git hash-object` refuses such a date, but `git fast-import` writes it with
# no flags, so a peer CAN land one. The fixture ALSO seeds an aged unparseable claim that sorts AFTER
# it (`pr-3299` > `pr-3211`), because "the pass completed" is the half a single-ref fixture cannot see.
( cd "$P4BOX" && printf 'commit refs/heads/crafted\ncommitter a <a@b> 0000009999 +0000\ndata <<MSG\nclaim owner=weird3203 lease_until=HAVOC nonce=crafted\nMSG\nM 100644 inline f\ndata 2\nx\n' \
    | git fast-import --quiet ) 2>/dev/null
( cd "$P4BOX" && git push -q --force origin refs/heads/crafted:refs/claims/pr-3211 ) 2>/dev/null
p4_has pr-3211 && P4CRAFT=0 || P4CRAFT=1
ck "A33a (setup) a claim commit with a LEADING-ZERO committer stamp is planted" "^0$" "$P4CRAFT"
p4_seed pr-3299 weird3203 HAVOC 40000 >/dev/null
outP4CZ=$( p4_prune )   # NOTE: no `date` seam here — the crafted stamp alone must not stop the pass
echo "  prune output (crafted stamp):"; printf '%s\n' "$outP4CZ" | sed 's/^/    /'
ck "A33 [RED→GREEN] a leading-zero committer stamp is refused as unmeasurable, so the pass never dies on it" "kept unreadable-lease refs/claims/pr-3211" "$outP4CZ"
ck "A34 [RED→GREEN] ...and the pass COMPLETES: the aged ref that sorts AFTER the crafted one is still reaped" "pruned unreadable-lease refs/claims/pr-3299" "$outP4CZ"
p4_has pr-3211 && P4CZ=0 || P4CZ=1
ck "A35 [RED→GREEN] ...and the crafted ref itself survives (unmeasurable age is not evidence of expiry)" "^0$" "$P4CZ"
# THE CHEAPEST FABRICATED CLOCKS (review, agent-infra#3203 — shape is not enough). A `date` shim that
# prints `0` mints `until=ttl` (epoch 1970), which every peer then reclaims as EXPIRED; a leading-zero
# clock aborts the age arithmetic as OCTAL, truncating the pass exactly as the crafted-stamp case did.
# One ref per bad-clock shape, or the first iteration's (illegal) push would make the second look failed
# for the wrong reason.
P4ZREF=3212
for P4BAD in 0 0000009999 18446744073709551616 99999999999999999999; do
  outP4Z=$( ( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" CLAIM_OWNER_HOST=boxA && . "$CLAIMS_SH" \
              && date() { printf '%s\n' "$P4BAD"; } && claim_pr_acquire "" "$P4ZREF" ) 2>/dev/null ); rcP4Z=$?
  echo "  acquire with date='$P4BAD' rc=$rcP4Z :: $outP4Z"
  ck "A36 [RED→GREEN] a clock that answers '$P4BAD' is unreadable: the mint is REFUSED (rc 1), never an epoch-0 term" "^1$" "$rcP4Z"
  p4_has "pr-$P4ZREF" && P4ZM=1 || P4ZM=0
  ck "A37 [RED→GREEN] ...and nothing was pushed for that shape (no already-expired claim to be stolen)" "^0$" "$P4ZM"
  P4ZREF=$(( P4ZREF + 1 ))
done
p4_seed pr-3213 weird3203 HAVOC 40000 >/dev/null
p4_seed pr-3214 weird3203 HAVOC 0      >/dev/null
outP4OC=$( ( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" CLAIM_OWNER_HOST=boxA && . "$CLAIMS_SH" \
             && date() { printf '0000009999\n'; } && claim_prune ) 2>&1 )
echo "  prune with a LEADING-ZERO clock:"; printf '%s\n' "$outP4OC" | sed 's/^/    /'
ck "A38 [RED→GREEN] a leading-zero clock is unreadable: the pass NAMES a ref instead of dying as OCTAL" "LOCAL CLOCK is unreadable" "$outP4OC"
# ⛔ AND AN OVERSIZED CLOCK IS UNREADABLE, NOT A WRAPPED ONE (review, agent-infra#3203). A 20-digit clock
# WRAPS through `$(( ))`, and a wrapped `now` makes a 5-SECOND-old claim look astronomically old — so the
# arm REAPS on a fabricated time base. Shape-checking alone does not catch this: the value is all digits.
p4_seed pr-3217 weird3203 HAVOC 5 >/dev/null
outP4MAG=$( ( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" CLAIM_OWNER_HOST=boxA && . "$CLAIMS_SH" \
              && date() { printf '99999999999999999999\n'; } && claim_prune ) 2>&1 )
ck "A46 [RED→GREEN] an OVERSIZED (wrapping) clock is named as unreadable, never used as a time base" "LOCAL CLOCK is unreadable" "$outP4MAG"
p4_has pr-3217 && P4MAGK=0 || P4MAGK=1
ck "A47 [RED→GREEN] ...so a 5-SECOND-old claim is NOT reaped on its wrap-around" "^0$" "$P4MAGK"
p4_has pr-3213 && P4OCK=0 || P4OCK=1
ck "A39 [RED→GREEN] ...and nothing in the class was reaped on it (fail-closed)" "^0$" "$P4OCK"
# A PEER-PLANTED TERM OF THE SAME SHAPE (leading zero) must be UNPARSEABLE, not decimal 9999 — else the
# acquire reclaims it, claim_prune deletes it, and the snapshot says claim-expired so a controller SPAWNS.
P4LEAD="$(p4_seed pr-3215 peerbox 0000009999 0)"
outP4LZ=$( ( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" CLAIM_OWNER_HOST=boxA && . "$CLAIMS_SH" \
             && claim_pr_acquire "" 3215 ) 2>/dev/null ); rcP4LZ=$?
echo "  acquire over a LEADING-ZERO lease rc=$rcP4LZ :: $outP4LZ"
ck "A40 [RED→GREEN] a lease_until='0000009999' is UNPARSEABLE (abstention, held-by-unreadable-lease)" "held-by-unreadable-lease" "$outP4LZ"
ck "A41 [RED→GREEN] ...so the peer claim is REFUSED, not reclaimed as a 1970 window" "^1$" "$rcP4LZ"
P4LZTIP="$(git -C "$P4BOX" ls-remote origin refs/claims/pr-3215 | awk '{print $1}')"
[ -n "$P4LEAD" ] && [ "$P4LZTIP" = "$P4LEAD" ] && P4LZK=0 || P4LZK=1
ck "A42 [RED→GREEN] ...and its ref is untouched (never stolen)" "^0$" "$P4LZK"
# ⛔ A NON-ASCII DIGIT IS NOT A DIGIT, AND AN ERRORED COMPARISON IS NOT A VERDICT (review,
# agent-infra#3203 — a P1 for six rounds). Two independent fail-open paths in the SAME line:
#   (a) POSIX bracket RANGES are COLLATION-based, so under a UTF-8 locale `[!0-9]` does not exclude
#       U+0663 ARABIC-INDIC THREE — `lease_until=1٣` walked past `_lease_unparseable`, then
#       `[ "$now" -le "1٣" ]` ERRORED, `if` read the error as FALSE, and the answer was `expired`
#       ⇒ the acquire RECLAIMED a peer's claim. Measured on the shipped file under en_US.UTF-8.
#   (b) an all-digit clock above 2**63 also ERRORs `[`, and errored-as-FALSE is `expired` ⇒ FREE.
# `[!0123456789]` is the enumerated class (locale-proof), and the state reader now reads `$?` so a
# comparison that cannot be performed answers `unknown` instead of either polarity.
outP4AR=$( ( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" LC_ALL=en_US.UTF-8 && . "$CLAIMS_SH" \
             && _claim_lease_state "1$(printf '\u0663')" "$P4NOW" ) 2>&1 )
ck "A48 [RED→GREEN] a locale-collated NON-ASCII digit lease is unreadable, not 'expired'" "unreadable" "$outP4AR"
outP4HU=$( ( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" && . "$CLAIMS_SH" \
             && _claim_lease_state "$(( P4NOW + 900 ))" "20000000000000000000" ) 2>&1 )
ck "A49 [RED→GREEN] a clock ABOVE 2**63 that ERRORS the comparison answers unknown, never expired" "unknown" "$outP4HU"
# TWO `committer` HEADERS (review, agent-infra#3203): git dates a commit from the LAST one, so a crafted
# commit can carry `committer … 1 +0000` then `committer … <now> +0000` — a `head -n 1` reader dates it
# 1970 and REAPS a claim that is seconds old, while `git log` says it is fresh. `git hash-object -t commit
# --literally` writes such an object and a plain push lands it (`git fsck --strict` still accepts it).
P4TWO="$( ( cd "$P4BOX" && printf 'tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904\nauthor a <a@b> %s +0000\ncommitter a <a@b> 1 +0000\ncommitter a <a@b> %s +0000\n\nclaim owner=weird3203 lease_until=HAVOC nonce=two\n' "$P4NOW" "$P4NOW" \
   | git hash-object -w -t commit --literally --stdin ) 2>/dev/null )"
( cd "$P4BOX" && git push -q --force origin "$P4TWO:refs/claims/pr-3216" ) 2>/dev/null
p4_has pr-3216 && P4TWOOK=0 || P4TWOOK=1
ck "A43a (setup) a claim commit carrying TWO committer headers is planted" "^0$" "$P4TWOOK"
ck "A43 [RED→GREEN] the reaper dates it from the LAST committer header, like git does" "^${P4NOW}$" "$( ( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" && . "$CLAIMS_SH" \
     && c="$( _git ls-remote origin refs/claims/pr-3216 | awk '{print $1}' )" && _git fetch -q origin "+refs/claims/pr-3216:$CLAIM_TMP_NS/two3203" && _claim_commit_time "$CLAIM_TMP_NS/two3203" ) 2>/dev/null )"
outP4TW=$( p4_prune )
ck "A44 [RED→GREEN] ...so a SECONDS-OLD claim with a forged first header is NOT reaped as ancient" "kept unreadable-lease refs/claims/pr-3216" "$outP4TW"
p4_has pr-3216 && P4TWZ=0 || P4TWZ=1
ck "A45 [RED→GREEN] ...and it survives the pass" "^0$" "$P4TWZ"
# ⛔ THE AGE COMES FROM THE HEADER, NOT THE MESSAGE (review, agent-infra#3203). `cat-file commit`
# returns headers AND body, and the body is peer-writable: a message line shaped like
# `committer Evil <e@x> 1 +0000` was picked up by the parse while git dates the commit from the
# header — so a claim `git log --format=%ct` calls SECONDS OLD was reaped as ancient (a future-dated
# message line pinned it past the bound for ever). Same commit, two readers, two answers: this pins
# the one that matches git.
P4HDR="$( ( cd "$P4BOX" && printf 'tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904\nauthor a <a@b> %s +0000\ncommitter a <a@b> %s +0000\n\nclaim owner=weird3203 lease_until=HAVOC nonce=msg\ncommitter Evil <e@x> 1 +0000\n' "$P4NOW" "$P4NOW" \
   | git hash-object -w -t commit --literally --stdin ) 2>/dev/null )"
( cd "$P4BOX" && git push -q --force origin "$P4HDR:refs/claims/pr-3218" ) 2>/dev/null
ck "A50a (setup) a claim commit carrying a 'committer' line in its MESSAGE is planted" "0" "$( p4_has pr-3218 && echo 0 || echo 1 )"
# ONE comparison, two readers: the reaper's age input and git's own answer must be the SAME number
# (and it must be the header's, not the message's forged `1`).
P4HDRCT="$(git -C "$P4BOX" log -1 --format='%ct' "$P4HDR" 2>/dev/null)"
P4REAPCT="$( ( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" && . "$CLAIMS_SH" \
             && _git fetch -q origin "+refs/claims/pr-3218:$CLAIM_TMP_NS/msg3203" 2>/dev/null \
             && _claim_commit_time "$CLAIM_TMP_NS/msg3203" ) 2>/dev/null )"
echo "  header stamp: git=$P4HDRCT reaper=$P4REAPCT (the message line forged 1)"
ck "A50 [RED→GREEN] ...and the age is read from the HEADER stamp, exactly the number git reports" "^${P4HDRCT}$" "$P4REAPCT"
ck "A50b [RED→GREEN] ...which is NOT the forged message stamp (the value a body-wide parse returns)" "^0$" "$([ "$P4REAPCT" = "1" ] && echo 1 || echo 0)"
outP4MSG=$( p4_prune )
ck "A51 [RED→GREEN] ...so a SECONDS-OLD claim with a forged message line is NOT reaped" "kept unreadable-lease refs/claims/pr-3218" "$outP4MSG"
# ⛔ AND THE STEAL ITSELF, END TO END (review, agent-infra#3203): the reviewer reclaimed a peer's claim
# through `claim_pr_acquire` with `lease_until=1٣` under a UTF-8 locale and showed `rc=0
# reclaimed expired claim`. The unit asserts the CLASS; this asserts that no caller can act on it.
P4NON="$( ( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" && . "$CLAIMS_SH" && GIT_COMMITTER_DATE="@$(( P4NOW - 10 )) +0000" _claim_commit peerbox "1$(printf '\u0663')" ) 2>/dev/null )"
( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" && . "$CLAIMS_SH" && LC_ALL=en_US.UTF-8 _git push -q origin "$P4NON:refs/claims/pr-3219" ) 2>/dev/null
outP4NS=$( ( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" CLAIM_OWNER_HOST=boxA LC_ALL=en_US.UTF-8 && . "$CLAIMS_SH" \
             && claim_pr_acquire "" 3219 ) 2>/dev/null ); rcP4NS=$?
echo "  acquire over a NON-ASCII lease rc=$rcP4NS :: $outP4NS"
ck "A52 [RED→GREEN] a non-ASCII lease cannot be RECLAIMED (the reviewer's steal, closed)" "^1$" "$rcP4NS"
ck "A53 [RED→GREEN] ...and it is named as the abstention, not as an expiry" "held-by-unreadable-lease" "$outP4NS"
P4NSTIP="$(git -C "$P4BOX" ls-remote origin refs/claims/pr-3219 | awk '{print $1}')"
[ -n "$P4NON" ] && [ "$P4NSTIP" = "$P4NON" ] && P4NSK=0 || P4NSK=1
ck "A54 [RED→GREEN] ...and the peer's ref is untouched" "^0$" "$P4NSK"
# ⛔ AN ANCHORED TRAILER, NOT A DIGIT PREFIX (review rounds 9). `_lease_of`'s unanchored `[0-9]*`
# captured the PREFIX and discarded the rest, so a peer-planted `lease_until=1junk` became `1` — a
# parseable, long-expired term — and every reader answered FREE (measured: `acquired`/`reclaimed
# expired claim … (was until 1)`). Two shapes, because they fail through different mechanisms: a
# SUFFIX the digit run does not cover, and a NON-ASCII digit INSIDE the run (which the exhaustive
# ASCII class must reject while an unanchored `[0-9]*` prefix-matched around it).
P4JREF=3220
for P4JUNK in "1junk" "1$(printf '\u0669')2000000" "junk1"; do
  P4JSEED="$(p4_seed "pr-$P4JREF" peerbox "$P4JUNK" 10)"
  outP4J=$( ( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" CLAIM_OWNER_HOST=boxA LC_ALL=en_US.UTF-8 && . "$CLAIMS_SH" \
              && claim_pr_acquire "" "$P4JREF" ) 2>/dev/null ); rcP4J=$?
  echo "  acquire over lease_until='$P4JUNK' rc=$rcP4J :: $outP4J"
  ck "A55 [RED→GREEN] a truncated/garbled term ('$P4JUNK') is UNPARSEABLE, so the claim is not reclaimed" "^1$" "$rcP4J"
  ck "A56 [RED→GREEN] ...and it is named as the abstention" "held-by-unreadable-lease" "$outP4J"
  P4JTIP="$(git -C "$P4BOX" ls-remote origin "refs/claims/pr-$P4JREF" | awk '{print $1}')"
  ck "A57 [RED→GREEN] ...and the peer's ref is untouched (never stolen)" "^1$" "$([ "$P4JTIP" = "$P4JSEED" ] && echo 1 || echo 0)"
# ⛔ AND THE OTHER TWO CLOCK GUARDS AGREE WITH THIS ONE (review round 10, agent-infra#3203). Both were
# SHAPE-ONLY, so `date` printing a leading zero reached `$(( ))`, bash read it as OCTAL, aborted, and
# the arm answered with NO WORD, NO REASON and NO TOKEN — an abstention nobody can act on (measured:
# `claim_snapshot_verdict` rc=1 word= why="", and `claim_issue_preflight` with empty output) — and a
# 20-digit clock WRAPPED into a negative "s left". Fail-closed either way; the NAME is the product.
P4SNAPCLK="$( ( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" && . "$CLAIMS_SH" \
                && date() { printf '01792000000\n'; } && claim_snapshot "$P4BOX/snapclk3203" >/dev/null 2>&1; \
                claim_snapshot_verdict "$P4BOX/snapclk3203" refs/claims/pr-3203 >/dev/null 2>&1
                printf '%s|%s' "$?" "${CLAIM_VERDICT:-}" ) 2>/dev/null )"
echo "  snapshot verdict with a LEADING-ZERO clock: $P4SNAPCLK"
# The verdict WORD is the product: before the magnitude arm the same clock produced rc=1 with an EMPTY
# word (bash aborted the `$(( ))` as octal and neither the fresh nor the stale test fired).
ck "A58 [RED→GREEN] a leading-zero clock leaves the snapshot verdict NAMED, not empty" "^2|claim-unreadable" "$P4SNAPCLK"
# the preflight's clock guard sits BEHIND a found claim, so seed one — otherwise the arm returns "no
# claim" and proves nothing (measured: an earlier draft asserted against exactly that empty answer).
p4_seed issue-9001 peerbox 9999999999 10 >/dev/null
P4PRE="$( ( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" && . "$CLAIMS_SH" \
           && date() { printf '99999999999999999999\n'; } && claim_issue_preflight 9001 ) 2>/dev/null )"
echo "  preflight with a 20-DIGIT clock: $P4PRE"
ck "A59 [RED→GREEN] ...and a wrapping clock is NAMED by the preflight, never used as a time base" "clock is unreadable" "$P4PRE"
p4_seed issue-9001 peerbox 9999999999 10 >/dev/null
P4PRELZ="$( ( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" && . "$CLAIMS_SH" \
             && date() { printf '0000009999\n'; } && claim_issue_preflight 9001 ) 2>/dev/null )"
echo "  preflight with a LEADING-ZERO clock: $P4PRELZ"
ck "A60 [RED→GREEN] ...and so is a leading-zero one (no silent empty answer, no octal abort)" "clock is unreadable" "$P4PRELZ"
# ⛔ AND THE BRANCH GUARD — THE THIRD READER WITH ITS OWN CLOCK ARM (review round 11,
# agent-infra#3203). Shape only meant `0` and a 20-digit clock fell through to `_lease_is_live` →
# `_claim_lease_state` → `unknown`, which this guard published as `reason=held-by-live` — a nominal
# LIVE holder for a window nobody can judge, with the remedy "wait for the lease to expire", a remedy
# that can never fire. Every sibling names the clock; so must this one.
# the arm sits BEHIND "a claim exists", so mint one held by a PEER (a claim we own would take the
# `held-by-you` early return and never reach the clock at all — an earlier draft of this assertion
# measured exactly that empty path).
P4BGR="$( ( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" && . "$CLAIMS_SH" && claim_branch_ref boxa-topic ) 2>/dev/null )"
p4_seed "$(printf '%s' "$P4BGR" | sed 's#^refs/claims/##')" peerbox 9999999999 10 >/dev/null
for P4BG in 0 99999999999999999999 0000009999; do
  outP4BG=$( ( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" CLAIM_OWNER_HOST=boxA && . "$CLAIMS_SH" \
               && date() { printf '%s\n' "$P4BG"; } && claim_branch_guard boxa-topic ) 2>&1 )
  echo "  branch guard with clock='$P4BG' :: $(printf '%s' "$outP4BG" | head -1 | cut -c1-110)"
  ck "A61 [RED→GREEN] the branch guard NAMES an unreadable clock ('$P4BG'), never a nominal live holder" "reason=clock-unreadable" "$outP4BG"
done
# ⛔ ONE LINE IN, ONE ANSWER OUT (review round 11, agent-infra#3203). A claim commit carries ONE
# `claim owner=… lease_until=… nonce=…` line, so a second one is peer-planted junk. `_lease_of` must
# read the FIRST line for BOTH fields: with the lease taking the first match and the owner printing
# one line per match, a two-line message produced a MULTI-LINE owner (`owner` came back as
# "peerbox\njunkbox") beside a first-line lease — the two halves of one answer from different lines.
# `claim_lanes.py` reads the FIRST too (L10b pins the Python side; this pins the shell side).
P4TWO2="$( ( cd "$P4BOX" && printf 'tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904\nauthor a <a@b> %s +0000\ncommitter a <a@b> %s +0000\n\nclaim owner=peerbox lease_until=9999999999 nonce=1\nclaim owner=junkbox lease_until=1 nonce=2\n' "$P4NOW" "$P4NOW" \
   | git hash-object -w -t commit --literally --stdin ) 2>/dev/null )"
( cd "$P4BOX" && git push -q --force origin "$P4TWO2:refs/claims/pr-3223" ) 2>/dev/null
P4LEASEOUT="$( ( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" && . "$CLAIMS_SH" \
                && _git fetch -q origin "+refs/claims/pr-3223:$CLAIM_TMP_NS/two2" 2>/dev/null \
                && printf '%s' "$( _lease_of "$CLAIM_TMP_NS/two2" )" ) 2>/dev/null | cat -A | tr '\n' '|' )"
echo "  _lease_of over a TWO-LINE claim message: $P4LEASEOUT"
ck "A62 [RED→GREEN] the lease extraction takes the FIRST claim line" "^peerbox\^I9999999999$" "$P4LEASEOUT"
outP4TWOV=$( ( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" CLAIM_OWNER_HOST=boxA && . "$CLAIMS_SH" \
               && claim_pr_acquire "" 3223 ) 2>/dev/null ); rcP4TWOV=$?
echo "  acquire over the two-line claim rc=$rcP4TWOV :: $(printf '%s' "$outP4TWOV" | head -1 | cut -c1-100)"
ck "A63 [RED→GREEN] ...and the reader below it agrees with the FIRST line (LIVE ⇒ not stolen)" "^1$" "$rcP4TWOV"
ck "A64 [RED→GREEN] ...naming the live window, not an expiry" "held-by-live" "$outP4TWOV"
# ⛔ AND THE SAME FIELD TWICE ON ONE LINE (review round 12, agent-infra#3203). A greedy `.*` prefix in
# the old extraction bound the LAST token while both Python readers take the FIRST — so
# `lease_until=9999999999 … lease_until=1` read EXPIRED (FREE) in the shell and LIVE in Python. The
# extraction is field-based now: FIRST non-empty line, FIRST faithful token of each field.
P4TWOF="$( ( cd "$P4BOX" && printf 'tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904\nauthor a <a@b> %s +0000\ncommitter a <a@b> %s +0000\n\nclaim owner=peerbox lease_until=9999999999 lease_until=1 nonce=x\n' "$P4NOW" "$P4NOW" \
   | git hash-object -w -t commit --literally --stdin ) 2>/dev/null )"
( cd "$P4BOX" && git push -q --force origin "$P4TWOF:refs/claims/pr-3224" ) 2>/dev/null
P4TWOFV="$( ( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" && . "$CLAIMS_SH" \
             && _git fetch -q origin "+refs/claims/pr-3224:$CLAIM_TMP_NS/twof" 2>/dev/null \
             && _lease_of "$CLAIM_TMP_NS/twof" ) 2>/dev/null | cat -A )"
echo "  _lease_of over a repeated on-line token: $P4TWOFV"
ck "A65 [RED→GREEN] a repeated on-line lease token resolves to the FIRST one, as both Python readers do" "^peerbox\^I9999999999$" "$P4TWOFV"
# ⛔ THE ONE CLOCK GUARD THAT COULD KILL ITS CALLER (review round 12, agent-infra#3203).
# `claim_snapshot_verdict` is called DIRECTLY by orch-loop.sh's claim_selection_verdict (no subshell),
# and its `now` guard was shape-only, so `date +%s` printing a leading zero made bash abort the
# `$(( now - read_at ))` as OCTAL and take the CONTROLLER down mid-sweep; a 20-digit clock wrapped and
# silently skipped the CLAIM_SNAPSHOT_MAX_AGE bound. A58 passed only because its shim also poisoned
# `read_at` — this one keeps `read_at` clean and shims ONLY the clock.
# ⛔ THE WRITER'S OWN HEADER FORMAT (`\t`-separated: `#claim-snapshot<TAB><read_at><TAB>ok|failed<TAB>n`).
# An earlier draft wrote `#claim-snapshot read_at=…`, which the reader cannot parse — so it answered
# `claim-unreadable` for THAT reason and the clock arm was never reached: the mutant stayed green and
# the assertion proved nothing.
{ printf '#claim-snapshot\t%s\tok\t1\n' "$(( P4NOW - 30 ))"
  printf 'refs/claims/pr-3225\t%s:4242\t%s\n' peerbox "$(( P4NOW + 900 ))"; } > "$P4BOX/snapclean3203"
for P4BADC in 01792000000 99999999999999999999; do
  outP4SV=$( ( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" && . "$CLAIMS_SH" \
               && date() { printf '%s\n' "$P4BADC"; } && claim_snapshot_verdict "$P4BOX/snapclean3203" refs/claims/pr-3225
               printf 'rc=%s word=%s' "$?" "${CLAIM_VERDICT:-}" ) 2>&1 | tail -1 )
  echo "  snapshot verdict, CLEAN read_at, clock='$P4BADC' :: $outP4SV"
  ck "A66 [RED→GREEN] a clean snapshot with an unreadable clock ('$P4BADC') NAMES it instead of aborting the caller" "rc=2 word=claim-unreadable" "$outP4SV"
done
  P4JREF=$(( P4JREF + 1 ))
done
# ⛔ THE BELT IS PINNED, NOT MERELY PRESENT (review round 19, agent-infra#3203). `_claim_lease_state`'s
# `case "$?"` arm is UNREACHABLE while both guards hold — an unparseable lease and an unreadable clock
# are each rejected before the comparison, so `[ "$now" -le "$lease" ]` can never return 2. That made
# it look DEAD: replacing the dispatch with a plain `if … then live; else expired; fi` left this whole
# suite GREEN (242 passed, 0 failed), while the arm is in fact the ONLY thing that answers if a future
# loosening of either guard lets a non-integer reach the comparison — which is exactly how the P1 it
# closes arrived. A belt nobody can observe is indistinguishable from a dead guard, so this drives it
# directly: `_lease_unparseable` is stubbed to ACCEPT the term, reproducing the state such a loosening
# would create, and the comparison is then handed `1junk` so `[` really does error.
outP4BELT=$( ( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" && . "$CLAIMS_SH" \
              && _lease_unparseable() { return 1; } \
              && _claim_lease_state "1junk" "$P4NOW" ) 2>/dev/null | tail -1 )
echo "  _claim_lease_state with the guard stubbed open, over '1junk': $outP4BELT"
ck "A67 [PINNED] a comparison that cannot be performed answers 'unknown', never 'expired' (the belt behind the guards)" "^unknown$" "$outP4BELT"
# ⛔ THE CEILING HAS A TWIN (review round 19, agent-infra#3203). The ceiling stops a ~31-year override
# from re-creating the eternal block. Without a FLOOR the same knob does the opposite and far worse
# thing: `CLAIM_UNREADABLE_LEASE_MAX_AGE=1` makes the unattended hourly `claim_prune` delete an
# unparseable-lease claim SECONDS after it was minted — a peer's LIVE claim, removed on a schedule, i.e.
# the steal direction this arm exists to refuse.
# ⛔ AND THE FLOOR IS CALIBRATED ON THE LONGEST MINTABLE TERM (review round 20, agent-infra#3203):
# `CLAIM_BRANCH_TTL` and `CLAIM_TTL_MAX` are each overrides that can be raised PAST `CLAIM_ISSUE_TTL`,
# and a floor nailed to 18000 would then fire INSIDE a live 40000 s branch term — the same steal, one
# knob over. Both arms are pinned below, so a future simplification back to one knob goes RED.
outP4FLOOR=$( ( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" CLAIM_UNREADABLE_LEASE_MAX_AGE=1 \
                && . "$CLAIMS_SH" && printf '%s' "$CLAIM_UNREADABLE_LEASE_MAX_AGE" ) 2>/dev/null | tail -1 )
echo "  CLAIM_UNREADABLE_LEASE_MAX_AGE=1 resolves to: $outP4FLOOR"
ck "A68 [RED→GREEN] a sub-lease bound is clamped UP to the longest mintable term, never below it" "^18000$" "$outP4FLOOR"
outP4FLOORB=$( ( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" CLAIM_UNREADABLE_LEASE_MAX_AGE=1 \
                   CLAIM_BRANCH_TTL=40000 && . "$CLAIMS_SH" && printf '%s' "$CLAIM_UNREADABLE_LEASE_MAX_AGE" ) 2>/dev/null | tail -1 )
echo "  ...and with CLAIM_BRANCH_TTL=40000 it resolves to: $outP4FLOORB"
ck "A69 [RED→GREEN] ...and the floor FOLLOWS a raised branch term, so it cannot fire inside a live branch claim" "^40000$" "$outP4FLOORB"
# The VALUE clamp is not the behaviour it exists for, so the decision itself is asserted: a 2-SECOND-old
# unparseable claim under a bound of 1 must be KEPT and NAMED — not deleted. This is the literal
# measurement behind the floor, promoted to a gate: a future refactor that hoists the bound into a local
# before the clamp, or gives a reader its own default, keeps the value assertions above green while
# restoring the scheduled steal.
# ⛔ AND THE SEED IS ASSERTED, NOT SWALLOWED (review round 25). The mint used to be
# `p4_seed … >/dev/null`, so a seed that failed (a non-fast-forward against a ref an earlier pass left
# behind, a transport failure) reported nothing and the assertions below measured a STALE object — or
# an absent one — while reading green. The suite's own A76a sets the pattern: a fixture that is not
# proven to exist is not a fixture.
ck "A70a (setup) a 2 s-old unparseable claim is MINTED for the floor case" "^[0-9a-f]\{40\}$" "$( p4_seed pr-3231 weird3203 HAVOC 2 2>/dev/null )"
outP4FB=$( ( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" CLAIM_OWNER_HOST=boxA CLAIM_UNREADABLE_LEASE_MAX_AGE=1 \
              && . "$CLAIMS_SH" && claim_prune ) 2>&1 )
echo "  prune with CLAIM_UNREADABLE_LEASE_MAX_AGE=1 over a 2s-old unparseable claim:"; printf '%s\n' "$outP4FB" | sed 's/^/    /'
ck "A70 [RED→GREEN] a sub-lease bound does not make the reaper DELETE a peer's 2-SECOND-old claim (it is KEPT and NAMED)" "kept unreadable-lease refs/claims/pr-3231" "$outP4FB"
p4_has pr-3231 && P4FBK=0 || P4FBK=1
ck "A71 [RED→GREEN] ...and the ref is really still there (the bound is a bound, not a message)" "^0$" "$P4FBK"
# ⛔ THE CEILING KNOB IS THE SAME STEAL FROM THE OTHER SIDE (review round 20, agent-infra#3203). The floor
# above is applied BEFORE the ceiling clamp, so a CEILING set below the floor wins and the bound lands
# below the longest mintable term — measured on the shipped file: `MAXAGE=1 CEIL=1` resolved the bound
# to 1 s and `claim_prune` DELETED a 2-SECOND-old claim, and `CEIL=3600` alone reaped a 4000 s-old claim
# that the shipped defaults keep. `CLAIM_UNREADABLE_LEASE_MAX_AGE_CEIL` appeared ZERO times in this suite
# before these assertions, so nothing could go red on the knob itself. Note they assert the KEEP, not a
# message: the clamps value is the last line of defence and it has to be observed.
outP4CEIL1=$( ( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" CLAIM_UNREADABLE_LEASE_MAX_AGE=1 \
                 CLAIM_UNREADABLE_LEASE_MAX_AGE_CEIL=1 && . "$CLAIMS_SH" && printf '%s' "$CLAIM_UNREADABLE_LEASE_MAX_AGE" ) 2>/dev/null | tail -1 )
echo "  MAXAGE=1 CEIL=1 resolves to: $outP4CEIL1"
ck "A72 [RED→GREEN] a CEILING below the floor term cannot undercut it (a sub-term ceiling is a scheduled steal)" "^18000$" "$outP4CEIL1"
outP4CEIL2=$( ( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" CLAIM_UNREADABLE_LEASE_MAX_AGE_CEIL=3600 \
                 && . "$CLAIMS_SH" && printf '%s' "$CLAIM_UNREADABLE_LEASE_MAX_AGE" ) 2>/dev/null | tail -1 )
echo "  CEIL=3600 alone resolves to: $outP4CEIL2"
ck "A73 [RED→GREEN] ...and it cannot undercut the DEFAULT bound either (3600 s is inside a 18000 s lease)" "^18000$" "$outP4CEIL2"
ck "A72a (setup) a 2 s-old unparseable claim is MINTED for the ceiling case" "^[0-9a-f]\{40\}$" "$( p4_seed pr-3232 weird3203 HAVOC 2 2>/dev/null )"
outP4CEILB=$( ( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" CLAIM_OWNER_HOST=boxA CLAIM_UNREADABLE_LEASE_MAX_AGE=1 \
                  CLAIM_UNREADABLE_LEASE_MAX_AGE_CEIL=1 && . "$CLAIMS_SH" && claim_prune ) 2>&1 )
echo "  prune with MAXAGE=1 CEIL=1 over a 2s-old unparseable claim:"; printf '%s\n' "$outP4CEILB" | sed 's/^/    /'
ck "A74 [RED→GREEN] ...so the 2-SECOND-old claim is KEPT, not deleted at a 1 s ceiling" "kept unreadable-lease refs/claims/pr-3232" "$outP4CEILB"
p4_has pr-3232 && P4CEILK=0 || P4CEILK=1
ck "A75 [RED→GREEN] ...and its ref survives the pass" "^0$" "$P4CEILK"
# ⛔ THE LAST `committer` LINE IS OUTPUT FIRST, THEN PARSED (review round 20, agent-infra#3203). The age
# parse used to be ONE anchored `sed` piped to `tail -n 1`, i.e. "the last line that MATCHES". Git dates
# the object from the last `committer` header whatever else that line carries, so a newest header with a
# trailing token is filtered out by the `$` anchor and `tail` returns an EARLIER committer line —
# measured: a claim `git log --format=%ct` dates as 1 s old was reaped with `the claim commit is
# 1793991810s old, PAST the 18000s bound`. A newest header this parser cannot read must make the age
# UNMEASURABLE (kept and NAMED), never fall back to older text the attacker wrote.
P4JUNK="$( ( cd "$P4BOX" && printf 'tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904\nauthor a <a@b> %s +0000\ncommitter a <a@b> 1 +0000\ncommitter a <a@b> %s +0000 junk\n\nclaim owner=weird3203 lease_until=HAVOC nonce=junk\n' "$P4NOW" "$P4NOW" \
   | git hash-object -w -t commit --literally --stdin ) 2>/dev/null )"
( cd "$P4BOX" && git push -q --force origin "$P4JUNK:refs/claims/pr-3233" ) 2>/dev/null
ck "A76a (setup) a claim commit whose LAST committer header carries a trailing token is planted" "0" "$( p4_has pr-3233 && echo 0 || echo 1 )"
P4JUNKRC=$( ( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" && . "$CLAIMS_SH" \
               && c="$( _git ls-remote origin refs/claims/pr-3233 | awk '{print $1}' )" \
               && _git fetch -q origin "+refs/claims/pr-3233:$CLAIM_TMP_NS/junk3203" \
               && _claim_commit_time "$CLAIM_TMP_NS/junk3203" >/dev/null 2>&1; printf '%s' "$?" ) 2>/dev/null | tail -1 )
echo "  _claim_commit_time over a newest committer line with a trailing token: rc=$P4JUNKRC"
ck "A76 [RED→GREEN] a newest committer header this parser cannot read is UNMEASURABLE (rc=1), never an older line" "^1$" "$P4JUNKRC"
outP4JUNKP=$( p4_prune )
ck "A77 [RED→GREEN] ...so the claim is KEPT and NAMED (an unmeasurable age is not evidence of expiry)" "kept unreadable-lease refs/claims/pr-3233" "$outP4JUNKP"
p4_has pr-3233 && P4JUNKK=0 || P4JUNKK=1
ck "A78 [RED→GREEN] ...and it survives the pass instead of being reaped on an earlier forged header" "^0$" "$P4JUNKK"
# ⛔ A TOKEN THAT PARSES MUST NOT BECOME THE VALUE (review round 22, agent-infra#3203). A76-A78 only
# drove a token the `$` anchor REJECTS (`+0000 junk`), which pins the SHAPE of the fallback and not the
# FIELD the parse is allowed to read. The greedy `.* ` therefore survived them and took the LAST
# `digits [+-]dddd` pair anywhere on the line, so the same one-push attack came back through a token that
# MATCHES: measured on the shipped file, `committer a <a@b> <NOW> +0000 1 +0000` — a claim `git log
# --format=%ct` dates as 0 s old — made `_claim_commit_time` answer 1, and `claim_prune` DELETED it as
# `1793991810s old, PAST the 18000s bound`. The parse is now anchored on `> ` (the ident's end), so the
# accepted stamp is the field git reads; any other `digits +-dddd` tail simply is not a match and lands
# on rc=1 (unmeasurable -> KEPT and NAMED).
P4FIELDFORGE="$( ( cd "$P4BOX" && printf 'tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904\nauthor a <a@b> %s +0000\ncommitter a <a@b> %s +0000 1 +0000\n\nclaim owner=weird3203 lease_until=HAVOC nonce=field\n' "$P4NOW" "$P4NOW" \
   | git hash-object -w -t commit --literally --stdin ) 2>/dev/null )"
( cd "$P4BOX" && git push -q --force origin "$P4FIELDFORGE:refs/claims/pr-3235" ) 2>/dev/null
ck "A79a (setup) a claim commit whose committer line carries a SECOND 'digits +dddd' pair is planted" "0" "$( p4_has pr-3235 && echo 0 || echo 1 )"
P4FIELDRC=$( ( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" && . "$CLAIMS_SH" \
                && c="$( _git ls-remote origin refs/claims/pr-3235 | awk '{print $1}' )" \
                && _git fetch -q origin "+refs/claims/pr-3235:$CLAIM_TMP_NS/field3203" \
                && _claim_commit_time "$CLAIM_TMP_NS/field3203" >/dev/null 2>&1; printf '%s' "$?" ) 2>/dev/null | tail -1 )
echo "  _claim_commit_time over a committer line with a second 'digits +dddd' pair: rc=$P4FIELDRC"
ck "A79 [RED→GREEN] the stamp is the IDENT's field (anchored on '> '), never the last 'digits +dddd' token on the line" "^1$" "$P4FIELDRC"
outP4FIELDP=$( p4_prune )
ck "A80 [RED→GREEN] ...so a claim git dates as CURRENT is KEPT and NAMED, not reaped as ancient" "kept unreadable-lease refs/claims/pr-3235" "$outP4FIELDP"
p4_has pr-3235 && P4FIELDK=0 || P4FIELDK=1
ck "A81 [RED→GREEN] ...and its ref survives the pass" "^0$" "$P4FIELDK"
# ⛔ THE TWO 30-DAY LITERALS ARE THE ONLY THING KEEPING THE BOUND BOUNDED (review round 22,
# agent-infra#3203). `_claim_floor_term` and `CLAIM_UNREADABLE_LEASE_MAX_AGE_CEIL` are both hard-capped at
# 2592000 so no knob reaches ~31 years — and NOTHING pinned either cap: deleting one left this whole suite
# GREEN (the COUNT of passes follows where this block sits in the file; the GREEN does not — verified by
# deleting each cap and re-running: A82-A85 go red) while `MAXAGE=999999999 CEIL=999999999` resolved the bound to 999999999 and
# a 2-YEAR-old unparseable-lease claim went from `pruned … PAST the 2592000s bound` to `kept … INSIDE the
# 999999999s bound`, i.e. #3203's eternal hold restored through a knob. The knobs appeared in this suite
# only BELOW the caps (CEIL=1, CEIL=3600) — the one region the caps do not govern.
outP4CEILCAP=$( ( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" CLAIM_UNREADABLE_LEASE_MAX_AGE=999999999 \
                     CLAIM_UNREADABLE_LEASE_MAX_AGE_CEIL=991999999 && . "$CLAIMS_SH" && printf '%s' "$CLAIM_UNREADABLE_LEASE_MAX_AGE" ) 2>/dev/null | tail -1 )
echo "  MAXAGE=999999999 CEIL=991999999 resolves to: $outP4CEILCAP"
ck "A82 [RED→GREEN] the CEILING is hard-capped at the 30-day literal, so no override reaches ~31 years" "^2592000$" "$outP4CEILCAP"
outP4FLOORCAP=$( ( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" CLAIM_TTL_MAX=999999999 \
                      && . "$CLAIMS_SH" && printf '%s' "$CLAIM_UNREADABLE_LEASE_MAX_AGE" ) 2>/dev/null | tail -1 )
echo "  TTL_MAX=999999999 resolves to: $outP4FLOORCAP"
ck "A83 [RED→GREEN] the FLOOR TERM is hard-capped at the 30-day literal, so a 9-digit term cannot raise the ceiling with it" "^2592000$" "$outP4FLOORCAP"
# ...and the cap is the DECISION, not just the value: a 2-year-old claim is REAPED at the ceiling, so a
# deleted cap shows up as a KEPT claim, not as a number.
# ⛔ AND THIS SEED IS ASSERTED, NOT SWALLOWED (review rounds 30–33, agent-infra#3203) — the same rule round
# 25 wrote at A70a above. `pr-3236` WAS one of 14 seeds this P4 block planted with `p4_seed … >/dev/null` —
# 13 others still are — and it was the only one OF THOSE 14 whose PAIRED assertion is an ABSENCE: A85 reads
# `p4_has pr-3236 && … || P4CAPK=1` and asserts `^1$`, and `p4_has` (:806) cannot tell "pruned" from
# "never planted" — both answer 1. So a seed that failed inside the redirect read `✅ "it is really gone"`
# over a ref that never existed: a ROW passing an unverified artifact.
# ⛔ WHAT THIS ROW BUYS, STATED NARROWLY — four earlier drafts of this paragraph claimed more, so the
# bounds are written down rather than left to the next reader.
#   * It does NOT change the run's polarity. An absent fixture was ALREADY a red run: A84 greps the prune
#     output for the literal `pruned … refs/claims/pr-3236`, which a never-planted ref cannot produce, so
#     A84 was the run-level red all along (the suite's own last command, `[ "$FAIL" -eq 0 ]` — cited by
#     its TEXT, not a line number, which is what rotted the first draft of this pointer)
#   * It does NOT stop A84/A85 running. The suite is `set -u`, NOT `set -e` (:69), and `ck` only increments
#     FAIL (:275-282) — there is no early exit, so both rows still execute.
#   * It DOES move the failure to a SETUP row whose message NAMES the seed, instead of surfacing as an A84
#     red that reads like a 30-day-CEILING-cap regression. Attribution is the whole purchase: a red that
#     names the wrong cause costs a diagnosis.
# ⛔ THE COUNTS ARE TWO DIFFERENT SETS, AND CONFLATING THEM IS HOW THE PREVIOUS DRAFT WENT WRONG (review
# round 33). HISTORY: 14 swallowed seeds, of which `pr-3236` was the only absence-paired one. NOW: 13
# swallowed seeds, and `pr-3236` is NOT among them — A84a plants it with `2>/dev/null` INSIDE the asserted
# `ck`, which is the whole point of this paragraph. So at this head NONE of the 13 swallowed seeds is
# absence-paired, and the one absence-paired seed of the original 14 is the asserted one. Citing the 13 by
# NAME, not by line, for the reason the pointer above records: they are `p4-young`, `p4-future`,
# `p4-expired`, `pr-3205`, `pr-3206`, `pr-3209`, `pr-3299`, `pr-3213`, `pr-3214`, `pr-3217`, `issue-9001`
# (twice) and `$P4BGR`. Of those, `pr-3214` is planted and read by NO assertion at all, so its seed can
# fail silently; that is dead weight rather than a false PASS, it feeds no absence assertion, and it is
# PRE-EXISTING on `main` — a follow-up (`p4_has pr-3214` beside A39) rather than this change.
ck "A84a (setup) a 2-YEAR-old unparseable-lease claim is MINTED for the ceiling-cap case" "^[0-9a-f]\{40\}$" "$( p4_seed pr-3236 weird3203 HAVOC 63072000 2>/dev/null )"
outP4CAPB=$( ( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" CLAIM_OWNER_HOST=boxA \
                  CLAIM_UNREADABLE_LEASE_MAX_AGE=999999999 CLAIM_UNREADABLE_LEASE_MAX_AGE_CEIL=999999999 \
                  && . "$CLAIMS_SH" && claim_prune ) 2>&1 )
echo "  prune of a 2-YEAR-old claim with both knobs at 999999999:"; printf '%s\n' "$outP4CAPB" | sed 's/^/    /'
ck "A84 [RED→GREEN] ...so a 2-YEAR-old claim is still REPAIRED at the 30-day ceiling, not kept for 31 years" "pruned unreadable-lease refs/claims/pr-3236" "$outP4CAPB"
p4_has pr-3236 && P4CAPK=0 || P4CAPK=1
ck "A85 [RED→GREEN] ...and it is really gone (the bound is a bound at every knob setting)" "^1$" "$P4CAPK"
# ⛔ A NON-UTF-8 BYTE IN THE COMMITTER NAME MUST NOT MAKE THE AGE UNMEASURABLE (merge of review round 26
# with round 22, agent-infra#3203). `sed`'s `.` does not consume an INVALID UTF-8 byte under a UTF-8
# locale, so the SAME object answered its stamp under `LC_ALL=POSIX` and UNMEASURABLE under
# `LC_ALL=C.UTF-8` — measured, one datum with two answers depending on which box read it, in the field
# the bounded reap is measured from. The parse is now byte-oriented (`LC_ALL=C` on all three stages), and
# the caller below deliberately runs under a UTF-8 ambient locale: the function must not inherit it.
# ⛔ THIS PIN EXISTS BECAUSE THE FIX SHIPPED UNPINNED: removing all three `LC_ALL=C` stages left BOTH
# suites fully green (the harness's crafted fixtures are all SHAPE hazards — trailing token, extra
# committer line, NUL, 3-digit tz — and not one carries a non-UTF-8 byte), so the one regression this
# merge exists to prevent had no assertion at all.
P4NONUTF="$( ( cd "$P4BOX" && printf 'tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904\nauthor a <a@b> %s +0000\ncommitter a <a\377@b> %s +0000\n\nclaim owner=weird3203 lease_until=HAVOC nonce=byte\n' "$P4NOW" "$P4NOW" \
   | git hash-object -w -t commit --literally --stdin ) 2>/dev/null )"
( cd "$P4BOX" && git push -q --force origin "$P4NONUTF:refs/claims/pr-3237" ) 2>/dev/null
# ⛔ THE PIN BELOW MUST BE ABLE TO FAIL — A MISSING `en_US.UTF-8` MADE IT INERT (review round 27,
# agent-infra#3203). A86 relied on `en_US.UTF-8` being INSTALLED: glibc FALLS BACK to `C` when it is not
# (and the subshell's `2>/dev/null` hid the warning), so `sed` was already byte-oriented and A86/A87 passed
# with OR without the three `LC_ALL=C` prefixes — a green that measured nothing. Measured with
# `LC_ALL=xx_YY.UTF-8`: the Q4 mutant is NOT caught, and the pin silently claims a property its box
# cannot test. So the ambient locale is now the first UTF-8 locale this box actually HAS (`C.UTF-8` is
# built into modern glibc and is UTF-8 for this purpose), and a box that reports NONE says the pin is
# inert instead of passing quietly.
P4UTF8=""
if command -v locale >/dev/null 2>&1; then
  while IFS= read -r _p4l; do
    # ⛔ ANY UTF-8 LOCALE, NOT FOUR LITERALS (review round 28, agent-infra#3203). Matching only
    # `en_US.UTF-8|en_US.utf8|C.UTF-8|C.utf8` left a box whose only UTF-8 locale is, say, `de_DE.UTF-8`
    # taking the fallback below — i.e. INERT — which is the very defect this probe was added to close.
    case "$_p4l" in *.[Uu][Tt][Ff]-8|*.[Uu][Tt][Ff]8) P4UTF8="$_p4l"; break ;; esac
  done <<<"$(locale -a 2>/dev/null)"
fi
if [ -z "$P4UTF8" ]; then
  echo "  ⚠️ A86/A87: no *.UTF-8/*.utf8 locale reported by 'locale -a' on this box — the byte-orientation"
  echo "     pin is INERT here: it would pass with the three LC_ALL=C prefixes removed. Not a failure of the"
  echo "     fix, but the pin cannot measure it on this box — so it is reported as SKIPPED, never as a pass."
fi
ck "A86a (setup) a claim commit whose committer NAME carries an invalid UTF-8 byte is planted" "0" "$( p4_has pr-3237 && echo 0 || echo 1 )"
# ⛔ THE PIN IS ONLY A PIN IF THE BOX CAN RUN IT (review round 28, agent-infra#3203). With no UTF-8 locale
# installed (glibc falls back to `C`), `sed` is byte-oriented with OR without the three `LC_ALL=C` prefixes,
# so A86/A87 pass while measuring NOTHING — a false GREEN on the only assertions for the byte-orientation
# property. The old code reported that in an out-of-band `⚠️` and still incremented PASS. It is now a named
# SKIP: the RESULT line carries `N SKIPPED`, and an inert pin can never read as a verified property.
if [ -n "$P4UTF8" ]; then
  P4NONUTFV=$( ( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" LC_ALL="$P4UTF8" && . "$CLAIMS_SH" \
                 && _git ls-remote origin refs/claims/pr-3237 >/dev/null 2>&1 \
                 && _git fetch -q origin "+refs/claims/pr-3237:$CLAIM_TMP_NS/nonutf3203" \
                 && _claim_commit_time "$CLAIM_TMP_NS/nonutf3203" ) 2>/dev/null | tail -1 )
  echo "  _claim_commit_time over a committer name with a 0xFF byte, under UTF-8 ambient locale '$P4UTF8': '$P4NONUTFV'"
  ck "A86 [RED→GREEN] a non-UTF-8 byte in the committer NAME does not stop the stamp being measured (the parse is byte-oriented)" "^${P4NOW}$" "$P4NONUTFV"
  outP4NONUTFP=$( p4_prune )
  ck "A87 [RED→GREEN] ...so the claim is AGED from that stamp (INSIDE the bound), not reported unmeasurable" "kept unreadable-lease refs/claims/pr-3237 (owner weird3203 .*INSIDE the 18000s bound" "$outP4NONUTFP"
else
  echo "  ⏭️ A86/A87 SKIPPED — this box has no UTF-8 locale, so the byte-orientation pin is INERT and cannot"
  echo "     measure the mutation. Counted as SKIPPED, never as a pass (an inert pin that increments PASS is"
  echo "     the false GREEN this block exists to prevent)."
  SKIPPED=$((SKIPPED+1))
fi
# ⛔ THE READER'S ANSWER IS PINNED TO **GIT'S OWN ANSWER** (review round 27, agent-infra#3203).
# A round-27 review finding claimed git reads the FIRST `<`…FIRST `>` span, so that
# `committer a <a@b> <NOW> +0000 > 1 +0000` is dated NOW by git and only a mail-span anchor could close
# the steal. MEASURED against git 2.43.0 (`hash-object -w -t commit --literally` + `git log -1
# --format=%ct`), the premise is FALSE: git dates the object from the field after the **LAST** `>`,
#
#   committer a <a@b> <NOW> +0000                     git %ct = <NOW>
#   committer a <a@b> <NOW> +0000 > 1 +0000           git %ct = 1        <- the claim IS ancient
#   committer a <a@b> <NOW> +0000 <c@d> 1 +0000       git %ct = 1        <- the claim IS ancient
#   committer a <a@b> 1 +0000 > <NOW> +0000           git %ct = <NOW>    <- the reverse sign
#   committer a <a@b> <NOW> +0000 1 +0000             git %ct = <NOW>    <- we ABSTAIN (keep)
#   committer a <a@b> <NOW> +0000 junk                git %ct = <NOW>    <- we ABSTAIN (keep)
#
# and a mail-span anchor answered UNMEASURABLE for the two `> ` shapes — which is the PERMANENT-HOLD
# direction, not the steal: `claim_prune` `continue`s on an unmeasurable age BEFORE the bound is
# compared, so a peer appending ` > 1 +0000` would hold its claim FOR EVER (#3203 re-opened through the
# reaper reporting itself healthy). So the assertion is not "the parser refuses" — it is **the parser
# answers what git answers**, on both signs, and the LAST two rows are the only permitted divergence:
# the `$` anchor is a deliberate property of this reader (claim-reaper.test.sh:124 pins it), and it
# refuses a whole line git would tolerate a trailing token on — always in the KEEP direction.
#
# ⛔ EACH ROW ASSERTS GIT'S ANSWER (`p4_git_ct`) AS WELL AS THE READER'S, so a future "fix" that
# re-derives git's ident split differently cannot pass by agreeing with itself: the oracle is in the
# assertion, not in a comment.
p4_plant_committer() { # <ref-name> <committer-line> -> plants it verbatim, pushes, prints the object id
  local o
  o="$( ( cd "$P4BOX" && printf 'tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904\nauthor a <a@b> %s +0000\n%s\n\nclaim owner=weird3203 lease_until=HAVOC nonce=forge\n' "$P4NOW" "$2" \
        | git hash-object -w -t commit --literally --stdin ) 2>/dev/null )"
  [ -n "$o" ] || return 1
  ( cd "$P4BOX" && git push -q --force origin "$o:refs/claims/$1" ) 2>/dev/null
  printf '%s' "$o"
}
p4_git_ct() { # <object-id> -> what GIT itself dates it at (the oracle the reader is pinned to)
  git -C "$P4BOX" log -1 --format=%ct "$1" 2>/dev/null
}
p4_ct_val() { # <ref-name> <ns-suffix> -> _claim_commit_time's measured stamp (empty when unmeasurable)
  ( cd "$P4BOX" && export CLAIM_REPO="$P4BOX" && . "$CLAIMS_SH" \
    && _git fetch -q origin "+refs/claims/$1:$CLAIM_TMP_NS/$2" \
    && _claim_commit_time "$CLAIM_TMP_NS/$2" ) 2>/dev/null | tail -1
}
# ── row 1: a forged tail after a `>` — GIT says 1970, so the claim is genuinely ancient and MUST be
# reaped. A reader that abstains here holds a claim for ever; a reader that answers anything but git's
# value reports an age git contradicts.
P4G1="$(p4_plant_committer pr-3238 "committer a <a@b> $P4NOW +0000 > 1 +0000")"
ck "A88a (setup) a committer line with a trailing '> 1 +0000' past the ident is planted" "0" "$( p4_has pr-3238 && echo 0 || echo 1 )"
ck "A88b (oracle) GIT dates that object at 1, so the claim really is ancient by its own commit" "^1$" "$( p4_git_ct "$P4G1" )"
ck "A88 [RED→GREEN] the reader answers GIT's value (1) — not an abstention, which would hold the claim for ever" "^1$" "$( p4_ct_val pr-3238 forge3203 )"
outP4G1=$( p4_prune )
ck "A88c [RED→GREEN] ...and claim_prune REAPS it (an unmeasurable age would keep it past every bound)" "pruned unreadable-lease refs/claims/pr-3238" "$outP4G1"
p4_has pr-3238 && P4G1K=0 || P4G1K=1
ck "A88d [RED→GREEN] ...and the ref is really gone" "^1$" "$P4G1K"
# ── row 2: the same, through a later mail-SHAPED span. git's split point is the last `>`, so this is
# dated 1 by git too — the reader must agree, not prefer the `<c@d>` span.
P4G2="$(p4_plant_committer pr-3239 "committer a <a@b> $P4NOW +0000 <c@d> 1 +0000")"
ck "A89a (setup) the same forgery through a later '<c@d>' mail-shaped span is planted" "0" "$( p4_has pr-3239 && echo 0 || echo 1 )"
ck "A89b (oracle) GIT dates that object at 1 as well" "^1$" "$( p4_git_ct "$P4G2" )"
ck "A89 [RED→GREEN] ...and the reader answers GIT's value, from the LAST '>' span, not the earlier one" "^1$" "$( p4_ct_val pr-3239 forge3204 )"
outP4G2=$( p4_prune )
ck "A89c [RED→GREEN] ...so that claim is REAPED too" "pruned unreadable-lease refs/claims/pr-3239" "$outP4G2"
p4_has pr-3239 && P4G2K=0 || P4G2K=1
ck "A89d [RED→GREEN] ...and its ref is gone" "^1$" "$P4G2K"
# ── row 3: the REVERSE sign. A peer forges a FRESH stamp after a `>` to DELAY a reap — git reads that
# same fresh stamp, so agreeing with git is what defeats it (the reader must not prefer the ident's).
P4G3="$(p4_plant_committer pr-3240 "committer a <a@b> 1 +0000 > $P4NOW +0000")"
ck "A90a (setup) a committer line with a forged LATER stamp after '>' is planted" "0" "$( p4_has pr-3240 && echo 0 || echo 1 )"
ck "A90b (oracle) GIT dates that object at <NOW> — this shape is a FORGED-FRESH claim" "^${P4NOW}$" "$( p4_git_ct "$P4G3" )"
ck "A90 [RED→GREEN] ...and the reader answers GIT's value, so the forged-fresh stamp cannot buy a delay" "^${P4NOW}$" "$( p4_ct_val pr-3240 revsign3203 )"
# ── row 4 (the permitted divergence, pinned so it stays in the KEEP direction and is not mistaken for
# an assertion that the parser is right): a trailing token after the tz makes the `$` anchor refuse the
# line while git ignores the token. The claim stays KEPT and NAMED — the same decision A79 pins — and
# the ORACLE assertion records the divergence explicitly rather than leaving it to be rediscovered.
P4G4="$(p4_plant_committer pr-3241 "committer a <a@b> $P4NOW +0000 1 +0000")"
ck "A91a (setup) a forged tail with NO '>' in front of it is planted (the shape A79 drives)" "0" "$( p4_has pr-3241 && echo 0 || echo 1 )"
ck "A91b (oracle) GIT dates that object at <NOW> — the divergence below is a TOLERANCE, not a disagreement" "^${P4NOW}$" "$( p4_git_ct "$P4G4" )"
ck "A91 [documented divergence] the reader ABSTAINS here (the \`$\` anchor refuses a trailing token), and abstention is the KEEP direction" "^$" "$( p4_ct_val pr-3241 junk3203 )"
outP4G3G4=$( p4_prune )
ck "A91c ...so that claim is KEPT and NAMED, never reaped on a stamp git would have had to interpret" "kept unreadable-lease refs/claims/pr-3241" "$outP4G3G4"
ck "A90c ...while the forged-FRESH claim (git dates it <NOW>) is kept INSIDE the bound, not reaped" "kept unreadable-lease refs/claims/pr-3240" "$outP4G3G4"
# ── row 5: a name that legitimately carries `> 1 +0000` BEFORE the date field. Any anchor that
# demanded the FIRST `>` be the split point would refuse this shape git dates fine.
P4G5="$(p4_plant_committer pr-3242 "committer a > 1 +0000 <a@b> $P4NOW +0000")"
ck "A92a (setup) a committer NAME carrying '> 1 +0000' before the date field is planted" "0" "$( p4_has pr-3242 && echo 0 || echo 1 )"
ck "A92b (oracle) GIT dates that object at <NOW>" "^${P4NOW}$" "$( p4_git_ct "$P4G5" )"
ck "A92 [control] ...and the reader agrees with git (the anchor must not over-reach into names)" "^${P4NOW}$" "$( p4_ct_val pr-3242 nametail3203 )"
# ── rows 6-8: the WHITESPACE after the split `>` (review round 28, agent-infra#3203). git does NOT
# require a space there — it skips whitespace before the date field — so zero, two, three spaces and a
# TAB all answer the SAME value. An anchor of `> ` (EXACTLY one space) abstained on every one of them,
# and for `>  1 +0000` the PREVIOUS bare-`.* ` parser had measured GIT's own answer — so the `> ` form
# turned a git-ancient claim's REAP into a HOLD (the #3203 direction). Each row pins git's answer, the
# reader's, and, where the claim is genuinely ancient, that claim_prune really deletes it.
P4G6="$(p4_plant_committer pr-3243 "committer a <a@b> $P4NOW +0000 >  1 +0000")"
ck "A93a (setup) a committer line with TWO spaces after the split '>' is planted" "0" "$( p4_has pr-3243 && echo 0 || echo 1 )"
ck "A93b (oracle) GIT dates that object at 1 — it skips whitespace after the split '>'" "^1$" "$( p4_git_ct "$P4G6" )"
ck "A93 [RED→GREEN] ...and the reader answers GIT's value, not an abstention (which would hold the claim)" "^1$" "$( p4_ct_val pr-3243 ws3203 )"
outP4G6=$( p4_prune )
ck "A93c [RED→GREEN] ...so claim_prune REAPS it, never keeps a git-ancient claim past every bound" "pruned unreadable-lease refs/claims/pr-3243" "$outP4G6"
p4_has pr-3243 && P4G6K=0 || P4G6K=1
ck "A93d [RED→GREEN] ...and the ref is really gone" "^1$" "$P4G6K"
# ── row 7: NO whitespace at all after the split `>`. git's split point is the `>`, not the `> ` pair.
P4G7="$(p4_plant_committer pr-3244 "committer a <a@b> $P4NOW +0000 >1 +0000")"
ck "A94a (setup) a committer line with NO whitespace after the split '>' is planted" "0" "$( p4_has pr-3244 && echo 0 || echo 1 )"
ck "A94b (oracle) GIT dates that object at 1 as well" "^1$" "$( p4_git_ct "$P4G7" )"
ck "A94 [RED→GREEN] ...and the reader agrees with git" "^1$" "$( p4_ct_val pr-3244 nows3203 )"
# ── row 8: a TAB. git skips it, and `[[:blank:]]` is space+TAB by definition, so the anchor must too.
P4G8="$(p4_plant_committer pr-3245 "committer a <a@b> $P4NOW +0000 >$(printf '\t')1 +0000")"
ck "A95a (setup) a committer line with a TAB after the split '>' is planted" "0" "$( p4_has pr-3245 && echo 0 || echo 1 )"
ck "A95b (oracle) GIT dates that object at 1" "^1$" "$( p4_git_ct "$P4G8" )"
ck "A95 [RED→GREEN] ...and the reader agrees with git, so a TAB cannot buy an abstention" "^1$" "$( p4_ct_val pr-3245 tab3203 )"
for _p4n in P4G1 P4G2 P4G3 P4G4 P4G5 P4G6 P4G7 P4G8; do
  [ -n "$(eval "printf '%s' \"\$$_p4n\"")" ] || echo "  ⚠️ $_p4n: the fixture did not plant — the assertions above cannot discriminate"
done
rm -rf "$P4ORIG" "$P4BOX"

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

# I6. AN UNREADABLE LEASE ABSTAINS — NOT FREE, AND NOT CALLED LIVE (agent-infra#3203). The ANSWER is
# the same one claim_acquire and orch-loop's claim_live give (`lease_until=0` means "a claim EXISTS
# whose lease this reader cannot parse" — reading it as free would let a peer steal a live claim);
# what changed is the CLASSIFICATION: the reason now names the abstention (`held-by-unreadable-lease`)
# instead of asserting a live holder the reader cannot see.
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
ck "an UNREADABLE issue lease ABSTAINS (rc=1, never CLEAN)" "^1$" "$rcU"
ck "...and says so" "lease unreadable" "$outU"
ck "...naming the abstention token, so the class is greppable" "held-by-unreadable-lease" "$outU"
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
