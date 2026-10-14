#!/usr/bin/env bash
# test-claims.sh — prove the git-ref CAS claim is real, using TWO independent clones as
# stand-ins for two boxes. Not a mock: both clones talk to the live origin.
#
# Properties under test (the ones agent-infra#1709 says decide the design):
#   1  atomic create          — the second box must LOSE, not race-and-both-win
#   2  read-back confirmation — success is confirmed from the remote, not the exit code
#   2c status + snapshot      — a lookup by claim_ref() must MATCH (regression: it built
#                               refs/claims/.-<sha> and every lookup missed silently)
#   3  lease is data          — an expired claim is free; a live one is not
#   6  fencing                — a box that lost ownership cannot release the winner's claim
#
# ORDER MATTERS: every step that changes the holder must finish before the next step captures
# the ref sha, or the later assertions compare against a claim that no longer exists.
#
# SELF-CONTAINED (P2 in the 2026-10-14 export review): the two "boxes" are created here as fresh
# repos whose origin is THIS harness's origin, and the claims.sh under test is the one beside this
# file — not `~/orchestrator/claims.sh` and not a hard-coded /Users/home path. The claim refs are
# written to the REAL origin: that is deliberate (a CAS needs a genuinely shared ref) and safe —
# refs/claims/* is outside refs/heads/* and matches no `on: push:` trigger.
#
# ⛔ STILL NOT THE CROSS-BOX PROOF. Both "boxes" share one machine, so this cannot witness the
# three-box fleet. What it does pin is the CAS primitive: the second acquirer LOST, and — with the
# nonce check below — the two acquisitions built DIFFERENT objects. Before the nonce, two
# acquisitions in the same second produced byte-identical commits, the second push exited 0 as
# "up-to-date", and this whole suite passed while proving nothing.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAIMS_SH="$HERE/claims.sh"
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
cleanup_boxes() { rm -rf "$A" "$B" "$SNAP" 2>/dev/null; }
trap cleanup_boxes EXIT

# Run a claims.sh command AS one box. The per-box CLAIM_OWNER_ID is what makes the two stand-ins
# two boxes: without it both carry the same host+pid owner, so "B lost the race" is not evidence.
runA() { ( cd "$A" && export CLAIM_OWNER_ID=boxA && . "$CLAIMS_SH" && "$@" ); }
runB() { ( cd "$B" && export CLAIM_OWNER_ID=boxB && . "$CLAIMS_SH" && "$@" ); }

PR=999999
SHA=deadbeefcafebabe0123456789abcdef01234567
REF="refs/claims/$PR-${SHA:0:12}"
PASS=0; FAIL=0
ck() { # ck <label> <expected-regex> <actual>
  if printf '%s' "$3" | grep -q "$2"; then echo "  ✅ $1"; PASS=$((PASS+1));
  else echo "  ❌ $1 — expected /$2/ in: $3"; FAIL=$((FAIL+1)); fi
}
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
sn=$( cd "$A" && export CLAIM_OWNER_ID=boxA && . "$CLAIMS_SH" \
      && claim_snapshot "$SNAP" >/dev/null \
      && r="$(claim_ref $PR "$SHA")" && awk -F'\t' -v r="$r" '$1==r{print "MATCH "$0}' "$SNAP" ); rm -f "$SNAP"
echo "  snapshot lookup => $sn"
ck "snapshot lookup by claim_ref MATCHES" "^MATCH" "$sn"

echo
echo "=== 6. fencing: A cannot release with a SHA it does not hold ==="
out=$(runA claim_release "$A" $PR "$SHA" 1111111111111111111111111111111111111111); rc=$?
echo "  rc=$rc :: $out"
ck "stale release REFUSED" "refused" "$out"
still=$(git -C "$A" ls-remote origin "$REF" | awk '{print $1}')
if [ "$still" = "$remote_sha" ]; then echo "  ✅ claim survived the stale release attempt"; PASS=$((PASS+1));
else echo "  ❌ claim was deleted by a stale owner"; FAIL=$((FAIL+1)); fi

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
echo "=== cleanup ==="
cleanup_ref
left=$(git -C "$A" ls-remote origin "$REF" | wc -l | tr -d ' ')
echo "  refs left: $left"
[ "$left" = "0" ] && { echo "  ✅ clean"; PASS=$((PASS+1)); } || { echo "  ❌ leak"; FAIL=$((FAIL+1)); }
git -C "$A" for-each-ref --format='  leftover local scratch: %(refname)' refs/claims-cache | head -3

echo
echo "================ RESULT: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
