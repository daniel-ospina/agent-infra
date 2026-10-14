#!/usr/bin/env bash
# TEST 2 — the ACQUIRE path of the cross-box claim in merge-one.sh, plus the trap release.
# Hermetic: `gh` is an exported bash function (functions shadow PATH lookup), so no reviewer
# ever touches a real PR, and the agent is killed after 3s.
set -u
SHA=deadbeefcafebabe0123456789abcdef01234567
export SHA   # MUST be exported: merge-one.sh runs `set -u`, and the stub function is evaluated
             # in THAT shell — an unexported SHA makes `echo "$SHA"` fail and HEAD come back empty,
             # which silently skips the whole claim block and looks like a passing test.
REF="refs/claims/777777-${SHA:0:12}"
A=/Users/home/eldato/tortoise
O=$HOME/orchestrator

gh() { case "$*" in *headRefOid*) echo "$SHA";; *) echo "fake-gh unhandled: $*" >&2; return 1;; esac; }
export -f gh

echo "=== step 0: clear any holder so A starts from a free ref ==="
cur="$(git -C "$A" ls-remote origin "$REF" | awk '{print $1}')"
if [ -n "$cur" ]; then
  git -C "$A" push -q --force-with-lease="$REF:$cur" origin ":$REF" && echo "  cleared previous holder"
else
  echo "  ref was already free"
fi
echo "  refs/claims/* on origin: $(git -C "$A" ls-remote origin 'refs/claims/*' | wc -l | tr -d ' ')"

echo
echo "=== step 1: run the NEW merge-one.sh — expect ACQUIRED ==="
rm -f "$O/state/mergeclaim-777777.lock" "$O/logs/merge-777777.log"
( cd "$A" && REVIEW_TIMEOUT=12 bash /tmp/merge-one.new "$A" daniel-ospina/tortoise 777777 test/branch >/dev/null 2>&1 ) &
MID=$!
sleep 7
INFLIGHT="$(git -C "$A" ls-remote origin "$REF" | awk '{print $1}')"
[ -n "$INFLIGHT" ] && echo "  ✅ claim ref EXISTS while the reviewer runs ($INFLIGHT)" \
                  || echo "  ❌ no claim ref during the run — claim was never taken"
wait "$MID"; echo "  A exit=$?"
echo "  --- key log lines ---"
grep -aE "cross-box claim|\[timeout\] agent|end " "$O/logs/merge-777777.log" | sed 's/^/  /'

echo
echo "=== step 2: claim ref must be GONE after exit (the trap released it, fenced) ==="
n="$(git -C "$A" ls-remote origin "$REF" | wc -l | tr -d ' ')"
[ "$n" = "0" ] && echo "  ✅ released — ref gone" || echo "  ❌ leak — ref still present"
echo "  local lock: $(ls "$O/state/mergeclaim-777777.lock" 2>/dev/null || echo 'none ✅')"

echo
echo "=== step 3: fencing on the release — a STALE owner must not delete a live claim ==="
( cd "$A" && source "$O/claims.sh" && claim_acquire "." 777777 "$SHA" 600 >/dev/null && echo "  holder: ${CLAIM_RESULT##*owner=}" )
held="$(git -C "$A" ls-remote origin "$REF" | awk '{print $1}')"
( cd "$A" && source "$O/claims.sh" && claim_release "." 777777 "$SHA" 1111111111111111111111111111111111111111 ) | sed 's/^/  rc-note: /'
after="$(git -C "$A" ls-remote origin "$REF" | awk '{print $1}')"
[ "$after" = "$held" ] && echo "  ✅ live claim SURVIVED the stale release" || echo "  ❌ stale owner deleted a live claim"
( cd "$A" && source "$O/claims.sh" && claim_release "." 777777 "$SHA" "$held" ) | sed 's/^/  /'
echo "  cleanup refs left: $(git -C "$A" ls-remote origin "$REF" | wc -l | tr -d ' ')"
