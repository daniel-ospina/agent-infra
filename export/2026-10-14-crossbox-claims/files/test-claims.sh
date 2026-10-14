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
set -u
A=/Users/home/eldato/tortoise
B=/Users/home/tortoise
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
outA=$(cd "$A" && source ~/orchestrator/claims.sh && claim_acquire "$A" $PR "$SHA"); rcA=$?
outB=$(cd "$B" && source ~/orchestrator/claims.sh && claim_acquire "$B" $PR "$SHA"); rcB=$?
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
st=$( cd "$A" && source ~/orchestrator/claims.sh && claim_status "$A" $PR "$SHA" ); rc=$?
echo "  claim_status rc=$rc => [$st]"
ck "claim_status returns a lease" "^[^	]*	[0-9]\+$" "$st"
sn=$( cd "$A" && source ~/orchestrator/claims.sh && claim_snapshot /tmp/snap.$$ >/dev/null; \
      r="$(claim_ref $PR "$SHA")"; awk -F'\t' -v r="$r" '$1==r{print "MATCH "$0}' /tmp/snap.$$ ); rm -f /tmp/snap.$$
echo "  snapshot lookup => $sn"
ck "snapshot lookup by claim_ref MATCHES" "^MATCH" "$sn"

echo
echo "=== 6. fencing: A cannot release with a SHA it does not hold ==="
out=$(cd "$A" && source ~/orchestrator/claims.sh && \
      claim_release "$A" $PR "$SHA" 1111111111111111111111111111111111111111); rc=$?
echo "  rc=$rc :: $out"
ck "stale release REFUSED" "refused" "$out"
still=$(git -C "$A" ls-remote origin "$REF" | awk '{print $1}')
if [ "$still" = "$remote_sha" ]; then echo "  ✅ claim survived the stale release attempt"; PASS=$((PASS+1));
else echo "  ❌ claim was deleted by a stale owner"; FAIL=$((FAIL+1)); fi

echo
echo "=== 5. A releases with its real SHA ==="
out=$(cd "$A" && source ~/orchestrator/claims.sh && claim_release "$A" $PR "$SHA" "$remote_sha"); rc=$?
echo "  rc=$rc :: $out"
ck "release accepted" "released" "$out"
gone=$(git -C "$A" ls-remote origin "$REF" | awk '{print $1}')
if [ -z "$gone" ]; then echo "  ✅ ref gone from origin"; PASS=$((PASS+1)); else echo "  ❌ ref still present"; FAIL=$((FAIL+1)); fi

echo
echo "=== 3. lease is data: an EXPIRED claim is reclaimable, a LIVE one is not ==="
# TTL must comfortably exceed the time to the next assertion, or the test races its own expiry
# (a 1s TTL expired between two commands and the code — correctly — read it as free).
out=$(cd "$B" && source ~/orchestrator/claims.sh && claim_acquire "$B" $PR "$SHA" 8); rc=$?
echo "  B acquire ttl=8 rc=$rc :: $out"
ck "B acquired the free ref" "^0$" "$rc"
BOWNER=$(printf '%s' "$out" | sed -n 's/.*owner=\([^ ]*\).*/\1/p')
out=$(cd "$A" && source ~/orchestrator/claims.sh && claim_acquire "$A" $PR "$SHA"); rc=$?
echo "  A attempts while lease LIVE rc=$rc :: $out"
ck "live lease blocks A" "^1$" "$rc"
ck "A is told it is B's lease" "$BOWNER" "$out"
echo "  ...sleeping 9s for the lease to expire..."
sleep 9
out=$(cd "$A" && source ~/orchestrator/claims.sh && claim_acquire "$A" $PR "$SHA"); rc=$?
echo "  A attempts after expiry rc=$rc :: $out"
ck "expired lease reclaimed by A" "^0$" "$rc"
ck "reclaim names the previous owner" "reclaimed expired" "$out"
ck "reclaim names B specifically" "$BOWNER" "$out"

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
