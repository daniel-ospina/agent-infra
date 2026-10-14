#!/usr/bin/env bash
# TEST 2 — the ACQUIRE path of the cross-box claim in merge-one.sh, plus the trap release.
# Hermetic: `gh` is an exported bash function (functions shadow PATH lookup), so no reviewer
# ever touches a real PR, and the agent is killed after REVIEW_TIMEOUT seconds.
#
# SELF-CONTAINED (P2 in the 2026-10-14 export review): this runs THIS directory's merge-one.sh and
# claims.sh — not `/tmp/merge-one.new`, which was never in the export — against a throwaway git repo
# whose origin is this harness's origin, with a throwaway $O. No /Users/home/... path. The claim
# refs go to the REAL origin: deliberate (a CAS needs a shared ref) and safe — refs/claims/* is
# outside refs/heads/* and matches no `on: push:` trigger.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MERGE_ONE="$HERE/merge-one.sh"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
ORIGIN_URL="$(git -C "$REPO_ROOT" remote get-url origin)"
[ -f "$MERGE_ONE" ] || { echo "❌ missing $MERGE_ONE"; exit 2; }
[ -f "$HERE/claims.sh" ] || { echo "❌ missing $HERE/claims.sh"; exit 2; }

SHA=deadbeefcafebabe0123456789abcdef01234567
export SHA   # MUST be exported: merge-one.sh runs `set -u`, and the stub function is evaluated
             # in THAT shell — an unexported SHA makes `echo "$SHA"` fail and HEAD come back empty,
             # which silently skips the whole claim block and looks like a passing test.
REF="refs/claims/777777-${SHA:0:12}"

# A = the repo merge-one.sh claims against; O = the running-copy dir it reads claims.sh from.
A="/tmp/xb-crossbox-repo.$$"
O="/tmp/xb-crossbox-orch.$$"
rm -rf "$A" "$O" 2>/dev/null
mkdir -p "$A" "$O/logs" "$O/state"
git -C "$A" init -q && git -C "$A" remote add origin "$ORIGIN_URL"
cp "$HERE/claims.sh" "$O/claims.sh"
cleanup_tmp() { rm -rf "$A" "$O" 2>/dev/null; }
trap cleanup_tmp EXIT
export O

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
echo "=== step 1: run the REAL merge-one.sh from this directory — expect ACQUIRED ==="
rm -f "$O/state/mergeclaim-777777.lock" "$O/logs/merge-777777.log"
( cd "$A" && O="$O" REVIEW_TIMEOUT=12 bash "$MERGE_ONE" "$A" daniel-ospina/tortoise 777777 test/branch >/dev/null 2>&1 ) &
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
