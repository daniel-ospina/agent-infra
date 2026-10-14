#!/usr/bin/env bash
# TEST 2 — the ACQUIRE path of the cross-box claim in merge-one.sh, the trap release, and the P1
# coercion of a non-integer REVIEW_TIMEOUT.
# Hermetic: `gh` and `pi` are exported bash functions (functions shadow PATH lookup), so no reviewer
# ever touches a real PR or a real model. The fake `pi` sleeps out the wall limit so step 1's
# mid-flight assertion does not depend on how fast the real model answers.
#
# SELF-CONTAINED (P2 in the 2026-10-14 export review): this runs THIS directory's merge-one.sh and
# claims.sh — not `/tmp/merge-one.new`, which was never in the export — against a throwaway git repo
# whose origin is this harness's origin, with a throwaway $O. No /Users/home/... path. The claim
# refs go to the REAL origin: deliberate (a CAS needs a shared ref) and safe — verified empirically
# on both daniel-ospina/agent-infra and daniel-ospina/tortoise: a push to refs/claims/* created ZERO
# workflow runs and ZERO check-runs (every `on: push` in both repos is filtered to branches: [main]
# or tags). Their deletion is now in the trap, fenced, on EXIT/INT/TERM.
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
REF2="refs/claims/888888-${SHA:0:12}"
FIXREF="refs/claims/666666-${SHA:0:12}"

# A = the repo merge-one.sh claims against; O = the running-copy dir it reads claims.sh from.
A="/tmp/xb-crossbox-repo.$$"
O="/tmp/xb-crossbox-orch.$$"
rm -rf "$A" "$O" 2>/dev/null
mkdir -p "$A" "$O/logs" "$O/state"
git -C "$A" init -q && git -C "$A" remote add origin "$ORIGIN_URL"
# A real branch + commit so fix-one.sh's `git worktree list` finds a worktree (step 7).
git -C "$A" -c user.name=t -c user.email=t@t commit --allow-empty -q -m init
git -C "$A" -c user.name=t -c user.email=t@t branch -M test/branch
cp "$HERE/claims.sh" "$O/claims.sh"
PASS=0; FAIL=0
ok()  { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

# Remote refs live on LIVE origin (deliberate) and are NOT inside the temp dirs. A Ctrl-C/kill/abort
# used to leave orphaned refs/claims/* there — the EXIT trap cleaned local dirs only. Delete them
# best-effort (fenced) and cover INT and TERM as well as EXIT (P3.2, 2026-10-14 adversarial review).
cleanup_remote() {
  local ref cur
  for ref in "${REF:-}" "${REF2:-}" "${FIXREF:-}"; do
    [ -n "$ref" ] || continue
    cur="$(git -C "$A" ls-remote origin "$ref" 2>/dev/null | awk '{print $1}')"
    [ -n "$cur" ] && git -C "$A" push -q --force-with-lease="$ref:$cur" origin ":$ref" 2>/dev/null
  done
  return 0
}
cleanup_all() { trap - EXIT INT TERM; cleanup_remote; rm -rf "$A" "$O" 2>/dev/null; }
trap cleanup_all EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export O

gh() {
  case "$*" in
    *headRefOid*) echo "$SHA" ;;
    *"pr checks"*) echo "[]" ;;
    *--comments*) echo "stub: no reviewer comment" ;;
    *) echo "fake-gh unhandled: $*" >&2; return 1 ;;
  esac
}
export -f gh
# Hermetic reviewer. Measured: the shipped suite ran the REAL pi and passed (elapsed 16s > the 7s
# sample), but a warm/fast reviewer could finish and release the claim before the sample — the
# spurious failure this was reported with. FAKE_PI_INSTANT=1 returns immediately, which the P1 step
# needs (there REVIEW_TIMEOUT is coerced to 1800s and we must not actually wait for it).
pi() { [ "${FAKE_PI_INSTANT:-0}" = 1 ] && return 0; sleep 300; }
export -f pi

clear_ref() { # <ref>
  local c; c="$(git -C "$A" ls-remote origin "$1" | awk '{print $1}')"
  [ -n "$c" ] && git -C "$A" push -q --force-with-lease="$1:$c" origin ":$1"
  return 0
}

echo "=== step 0: clear any holder so A starts from a free ref ==="
clear_ref "$REF"; clear_ref "$REF2"
echo "  refs/claims/* on origin: $(git -C "$A" ls-remote origin 'refs/claims/*' | wc -l | tr -d ' ')"

echo
echo "=== step 1: run the REAL merge-one.sh from this directory — expect ACQUIRED ==="
rm -f "$O/state/mergeclaim-777777.lock" "$O/logs/merge-777777.log"
( cd "$A" && O="$O" REVIEW_TIMEOUT=12 bash "$MERGE_ONE" "$A" daniel-ospina/tortoise 777777 test/branch >/dev/null 2>&1 ) &
MID=$!
sleep 7
INFLIGHT="$(git -C "$A" ls-remote origin "$REF" | awk '{print $1}')"
[ -n "$INFLIGHT" ] && ok "claim ref EXISTS while the reviewer runs ($INFLIGHT)" \
                  || bad "no claim ref during the run — claim was never taken"
wait "$MID"; echo "  A exit=$?"
echo "  --- key log lines ---"
grep -aE "cross-box claim|\[timeout\] agent" "$O/logs/merge-777777.log" | sed 's/^/  /'

echo
echo "=== step 2: claim ref must be GONE after exit (the trap released it, fenced) ==="
n="$(git -C "$A" ls-remote origin "$REF" | wc -l | tr -d ' ')"
[ "$n" = "0" ] && ok "released — ref gone" || bad "leak — ref still present"
[ -z "$(ls "$O/state/mergeclaim-777777.lock" 2>/dev/null)" ] && ok "local lock dropped" || bad "local lock left behind"

echo
echo "=== step 3: fencing — a FOREIGN LIVE claim's real sha must not release this one ==="
# The old test passed a RANDOM 40-char sha, which is not an object anywhere; it proved only that the
# lease rejects a nonsense value. Here the caller holds a REAL commit sha — but not THIS ref's tip.
clear_ref "$REF2"
( cd "$A" && source "$O/claims.sh" && claim_acquire "." 888888 "$SHA" 600 >/dev/null ) || bad "could not mint the foreign claim"
foreign="$(git -C "$A" ls-remote origin "$REF2" | awk '{print $1}')"
( cd "$A" && source "$O/claims.sh" && claim_acquire "." 777777 "$SHA" 600 >/dev/null && echo "  holder: ${CLAIM_RESULT##*owner=}" )
held="$(git -C "$A" ls-remote origin "$REF" | awk '{print $1}')"
( cd "$A" && source "$O/claims.sh" && claim_release "." 777777 "$SHA" "$foreign" ) | sed 's/^/  rc-note: /'
after="$(git -C "$A" ls-remote origin "$REF" | awk '{print $1}')"
[ "$after" = "$held" ] && [ -n "$held" ] && ok "live claim SURVIVED the foreign-sha release" || bad "foreign sha deleted a live claim"
( cd "$A" && source "$O/claims.sh" && claim_release "." 777777 "$SHA" "$held" ) >/dev/null 2>&1
( cd "$A" && source "$O/claims.sh" && claim_release "." 888888 "$SHA" "$foreign" ) >/dev/null 2>&1

echo
echo "=== step 4 (P1): a non-integer REVIEW_TIMEOUT must NOT disable the claim ==="
# /bin/bash 3.2.57: a failed arithmetic assignment (`CLAIM_LEASE=$(( 30m + 1200 ))`) aborts the rest
# of the enclosing `if` body and resumes after `fi` with status 0 — claim_acquire never runs, the log
# carries NO "cross-box claim" line, and the worker still reports success. `30m` is VALID for `sleep`,
# which is exactly how an operator would set it, so the claim silently vanishes while the timeout works.
clear_ref "$REF2"
rm -f "$O/state/mergeclaim-888888.lock" "$O/logs/merge-888888.log"
( cd "$A" && O="$O" REVIEW_TIMEOUT=30m FAKE_PI_INSTANT=1 bash "$MERGE_ONE" "$A" daniel-ospina/tortoise 888888 test/branch >/dev/null 2>&1 )
echo "  exit=$?"
if grep -qa 'cross-box claim: acquired' "$O/logs/merge-888888.log"; then
  ok "REVIEW_TIMEOUT=30m still ran claim_acquire (coerced to an integer)"
else
  bad "no cross-box claim with REVIEW_TIMEOUT=30m — the claim was silently disabled"
  grep -a 'cross-box\|REVIEW_TIMEOUT' "$O/logs/merge-888888.log" | sed 's/^/     /'
fi

echo
echo "=== step 4b (P2): a LEADING-ZERO REVIEW_TIMEOUT must NOT disable the claim ==="
# `is_num` used `''|*[!0-9]*`, which ACCEPTS `08` — so `CLAIM_LEASE=$(( 08 + 1200 ))` reached the
# arithmetic, and on /bin/bash 3.2.57 the failed assignment ABORTED the claim block with status 0:
# claim_acquire never ran, the log had no 'cross-box claim' line, and the worker reported success.
# Rejecting leading zeros (accept only `0` or `[1-9][0-9]*`) coerces these to 1800 so the claim is
# genuinely taken. RED on the pre-fix predicate for BOTH values.
for rt in 08 09; do
  clear_ref "$REF2"
  rm -f "$O/state/mergeclaim-888888.lock" "$O/logs/merge-888888.log"
  ( cd "$A" && O="$O" REVIEW_TIMEOUT=$rt FAKE_PI_INSTANT=1 bash "$MERGE_ONE" "$A" daniel-ospina/tortoise 888888 test/branch >/dev/null 2>&1 )
  if grep -qa 'cross-box claim: acquired' "$O/logs/merge-888888.log"; then
    ok "REVIEW_TIMEOUT=$rt acquired the claim (leading zero rejected, coerced to 1800)"
  else
    bad "REVIEW_TIMEOUT=$rt did NOT acquire — a leading-zero lease silently disabled the claim"
    grep -a 'cross-box\|REVIEW_TIMEOUT' "$O/logs/merge-888888.log" 2>/dev/null | sed 's/^/     /'
  fi
done
clear_ref "$REF2"

echo
echo "=== step 4c (P2): a LEADING-ZERO FIX_TIMEOUT must NOT disable the FIXER's claim ==="
# The same predicate and the same failure on the FIXER: `FIX_LEASE=$(( 08 + 1200 ))` aborted the
# claim block, so the fixer ran UNCLAIMED for its whole duration and a second box could spawn its own
# fixer for the same head. Asserted separately from step 4b because the two scripts carry SEPARATE
# copies of `is_num` — a one-file fix would leave this path silently open while 4b stayed green.
O4F="/tmp/xb-crossbox-fixorch-lz.$$"
rm -rf "$O4F"; mkdir -p "$O4F/logs" "$O4F/state"
cp "$HERE/claims.sh" "$O4F/claims.sh"
printf '#!/usr/bin/env bash\necho "stub merge-one called"\n' > "$O4F/merge-one.sh"
for ft in 08 09; do
  c="$(git -C "$A" ls-remote origin "$FIXREF" | awk '{print $1}')"
  [ -n "$c" ] && git -C "$A" push -q --force-with-lease="$FIXREF:$c" origin ":$FIXREF"
  rm -f "$O4F/logs/fix-666666.log"
  ( cd "$A" && exec env O="$O4F" FIX_TIMEOUT=$ft FAKE_PI_INSTANT=1 bash "$HERE/fix-one.sh" "$A" daniel-ospina/tortoise 666666 test/branch >/dev/null 2>&1 )
  if grep -qa 'cross-box fixer claim: acquired' "$O4F/logs/fix-666666.log"; then
    ok "FIX_TIMEOUT=$ft acquired the FIXER's claim (leading zero rejected, coerced to 2400)"
  else
    bad "FIX_TIMEOUT=$ft did NOT acquire — the fixer ran UNCLAIMED"
    grep -a 'cross-box\|FIX_TIMEOUT' "$O4F/logs/fix-666666.log" 2>/dev/null | sed 's/^/     /'
  fi
done
c="$(git -C "$A" ls-remote origin "$FIXREF" | awk '{print $1}')"
[ -n "$c" ] && git -C "$A" push -q --force-with-lease="$FIXREF:$c" origin ":$FIXREF"
rm -rf "$O4F"

echo
echo "=== step 5 (P3.4): a TERM'd worker releases the claim on the way out ==="
clear_ref "$REF2"
rm -f "$O/state/mergeclaim-888888.lock" "$O/logs/merge-888888.log"
( cd "$A" && exec env O="$O" REVIEW_TIMEOUT=60 bash "$MERGE_ONE" "$A" daniel-ospina/tortoise 888888 test/branch >/dev/null 2>&1 ) &
M2=$!
sleep 5
mid2="$(git -C "$A" ls-remote origin "$REF2" | awk '{print $1}')"
[ -n "$mid2" ] && ok "claim taken while the worker runs" || bad "no claim to release on TERM"
kill -TERM "$M2" 2>/dev/null
wait "$M2" 2>/dev/null; echo "  worker exit=$?"
i=0
while [ "$i" -lt 15 ]; do
  [ -z "$(git -C "$A" ls-remote origin "$REF2" | awk '{print $1}')" ] && break
  sleep 1; i=$((i+1))
done
after2="$(git -C "$A" ls-remote origin "$REF2" | awk '{print $1}')"
[ -z "$after2" ] && ok "TERM'd worker released the claim (ref gone)" \
                 || bad "orphan claim after TERM ($after2)"

echo
echo "=== step 6 (P3.2): the suite's trap cleans REMOTE refs and covers INT/TERM ==="
( cd "$A" && source "$O/claims.sh" && c="$(_claim_commit proberef $(( $(date +%s) + 600 )))" && git -C "$A" push -q origin "$c:$REF2" )
before="$(git -C "$A" ls-remote origin "$REF2" | wc -l | tr -d ' ')"
cleanup_remote
after3="$(git -C "$A" ls-remote origin "$REF2" | wc -l | tr -d ' ')"
[ "$before" = "1" ] && [ "$after3" = "0" ] && ok "cleanup_remote deletes a live ref on origin" \
                                            || bad "cleanup_remote did not delete it ($before -> $after3)"
t="$(trap -p EXIT INT TERM)"
for s in EXIT INT TERM; do
  # bash 3.2 prints SIGINT/SIGTERM, later bashes print INT/TERM — a substring match covers both.
  # here-string, not a pipe — `printf … | grep -q` takes SIGPIPE under pipefail (#841).
  grep -q "$s" <<<"$t" && ok "trap registered for $s" || bad "no trap for $s"
done

echo
echo "=== step 7 (P3.3): the FIXER path takes the cross-box claim too ==="
# fix-one.sh ran the fixer before calling merge-one.sh (the only claim_acquire caller), so two boxes
# could each spawn a fixer for the same PR. It now claims the current head for the fixer's duration
# and releases before the merge chain, so merge-one.sh may re-claim a head the fixer did not move.
O2="/tmp/xb-crossbox-fixorch.$$"
rm -rf "$O2"; mkdir -p "$O2/logs" "$O2/state"
cp "$HERE/claims.sh" "$O2/claims.sh"
printf '#!/usr/bin/env bash\necho "stub merge-one called"\n' > "$O2/merge-one.sh"
fixref_clear() { local c; c="$(git -C "$A" ls-remote origin "$FIXREF" | awk '{print $1}')"; [ -n "$c" ] && git -C "$A" push -q --force-with-lease="$FIXREF:$c" origin ":$FIXREF"; return 0; }
fixref_clear
( cd "$A" && exec env O="$O2" FIX_TIMEOUT=12 bash "$HERE/fix-one.sh" "$A" daniel-ospina/tortoise 666666 test/branch >/dev/null 2>&1 ) &
F1=$!
sleep 6
fixflight="$(git -C "$A" ls-remote origin "$FIXREF" | awk '{print $1}')"
[ -n "$fixflight" ] && ok "fixer claim EXISTS while the fixer runs ($fixflight)" || bad "no fixer claim during the fix run"
wait "$F1" 2>/dev/null; echo "  fix-one exit=$?"
gone=$([ -z "$(git -C "$A" ls-remote origin "$FIXREF" | awk '{print $1}')" ] && echo yes || echo no)
[ "$gone" = "yes" ] && ok "fixer claim released (no orphan after the merge chain)" || bad "fixer claim leaked"
# Non-vacuity for step 7c's marker: a CLEAN acquire must leave NO bail marker, or a future change
# that writes it unconditionally would refund an attempt that was genuinely consumed.
[ ! -f "$O2/state/fixbail-666666-$SHA" ] && ok "the ACQUIRE path leaves no bail marker (refusal-only)" \
                                         || bad "a bail marker exists after a CLEAN acquire"
fixref_clear
rm -rf "$O2"

echo
echo "=== step 7b (P2): a FAILED final release must keep the retry latch, so the EXIT trap retries ==="
# Pre-fix `release_fix_claim >/dev/null 2>&1` discarded the rc and then ran an unconditional
# `CROSS_OWN=""`, so a failing release was never retried and the claim stranded on the remote for
# the whole fixer lease. Make every claim_release FAIL and count invocations: the explicit release
# is call 1, and ONLY a retained latch lets the EXIT trap make call 2.
O3="/tmp/xb-crossbox-fixorch-retry.$$"
rm -rf "$O3"; mkdir -p "$O3/logs" "$O3/state"
cp "$HERE/claims.sh" "$O3/claims.sh"
printf '#!/usr/bin/env bash\necho "stub merge-one called"\n' > "$O3/merge-one.sh"
CNT="$O3/release-calls"
printf '\nclaim_release() { echo x >> "%s"; return 1; }\n' "$CNT" >> "$O3/claims.sh"
fixref_clear
( cd "$A" && exec env O="$O3" FIX_TIMEOUT=60 FAKE_PI_INSTANT=1 bash "$HERE/fix-one.sh" "$A" daniel-ospina/tortoise 666666 test/branch >/dev/null 2>&1 ) &
F1b=$!
wait "$F1b" 2>/dev/null; echo "  fix-one exit=$?"
calls="$(wc -l < "$CNT" 2>/dev/null | tr -d ' ')"
[ "${calls:-0}" -ge 2 ] && ok "failed release RETRIED by the EXIT trap ($calls claim_release call(s))" \
                        || bad "failed release NOT retried — latch cleared ($calls call(s))"
# P3.1 (second review round): the failed release must also be LOGGED, not silent — otherwise the
# retained latch is invisible and nobody can tell a torn release from a released claim.
grep -qa 'could not release' "$O3/logs/fix-666666.log" 2>/dev/null && ok "the failed release is LOGGED, not silent" \
                        || bad "a failed release is not logged (the retry is invisible)"
fixref_clear
rm -rf "$O3"

echo
echo "=== step 7c (P2): a REFUSED fixer records a bail marker so the attempt can be refunded ==="
# The controller books the attempt (fixcount+1) and deletes the reviewer's findings marker at SPAWN,
# so a cross-box refusal — which does NO work — used to burn one of MAX_FIX_TRIES and destroy the
# findings record. Three refusals PARK the PR as needs-a-human although no fixer ever ran. fix-one.sh
# now records the refusal in $O/state/fixbail-<pr>-<head>; orch-loop.sh refunds both.
O4="/tmp/xb-crossbox-fixorch-bail.$$"
rm -rf "$O4"; mkdir -p "$O4/logs" "$O4/state"
cp "$HERE/claims.sh" "$O4/claims.sh"
printf '#!/usr/bin/env bash\necho "stub merge-one called"\n' > "$O4/merge-one.sh"
fixref_clear
# another box holds the head with a LIVE lease, so our acquire must be REFUSED (rc=1)
( cd "$A" && . "$O4/claims.sh" && CLAIM_OWNER_ID=otherbox claim_acquire "." 666666 "$SHA" 600 >/dev/null ) \
  || bad "could not seed the other box's live claim"
( cd "$A" && exec env O="$O4" FIX_TIMEOUT=12 FAKE_PI_INSTANT=1 bash "$HERE/fix-one.sh" "$A" daniel-ospina/tortoise 666666 test/branch >/dev/null 2>&1 )
echo "  fix-one exit=$?"
if [ -f "$O4/state/fixbail-666666-$SHA" ]; then
  ok "a REFUSED fixer wrote the bail marker (the controller can refund the attempt)"
else
  bad "no bail marker — a cross-box refusal still burns a capped attempt"
  grep -a 'REFUSED' "$O4/logs/fix-666666.log" 2>/dev/null | sed 's/^/     /'
fi
fixref_clear
rm -rf "$O4"

echo
echo "=== step 8 (P3.4): a BLACK-HOLED release cannot hang the exit path, and the lock survives it ==="
# The old trap did `rm -f "$CLAIM"` FIRST and then an UNTIMED claim_release push: a black-holed
# connection hung the exit for minutes with the local pid lock already gone, so the controller could
# spawn a second worker for the same PR. Make the running copy's claim_release hang, exactly as a
# black-holed push would: the exit must be BOUNDED and the lock must persist until the release ends.
cp "$HERE/claims.sh" "$O/claims.sh.bak"
printf '\nclaim_release() { sleep 60; }\n' >> "$O/claims.sh"
clear_ref "$REF2"
rm -f "$O/state/mergeclaim-888888.lock" "$O/logs/merge-888888.log"
t0="$(date +%s)"
( cd "$A" && exec env O="$O" REVIEW_TIMEOUT=60 bash "$MERGE_ONE" "$A" daniel-ospina/tortoise 888888 test/branch >/dev/null 2>&1 ) &
M3=$!
sleep 5
kill -TERM "$M3" 2>/dev/null
lockstate=""
i=0
while [ "$i" -lt 12 ]; do
  # Overwrite each second: the LAST state observed while the process is alive is the one that
  # answers the ordering question. A sticky flag would catch the lock before the handler ran and
  # pass spuriously with the OLD (lock-first) trap.
  if kill -0 "$M3" 2>/dev/null; then
    if [ -f "$O/state/mergeclaim-888888.lock" ]; then lockstate=present; else lockstate=absent; fi
  fi
  sleep 1; i=$((i+1))
done
wait "$M3" 2>/dev/null; rc3=$?
t1="$(date +%s)"; el=$((t1 - t0))
echo "  exit=$rc3 elapsed=${el}s (the stubbed release sleeps 60s) last-lock-state=$lockstate"
[ "$el" -le 40 ] && ok "exit path BOUNDED with a hung release (${el}s <= 40s)" || bad "exit hung on the release (${el}s)"
[ "$lockstate" = "present" ] && ok "local lock held WHILE the release is in flight (release first, drop last)" \
                            || bad "lock was dropped before the release finished (last state: ${lockstate:-none})"
cp "$O/claims.sh.bak" "$O/claims.sh"; rm -f "$O/claims.sh.bak"
clear_ref "$REF2"

echo
echo "=== step 9 (P2a): a read-back failure on CREATE must not orphan the claim ==="
# Append an ls-remote failure to the running copy of claims.sh: the push CREATES the ref, the
# read-back fails, claim_acquire returns 2 with CLAIM_COMMIT set — and merge-one.sh must release it
# rather than fail-open and strand the head for the whole lease.
cp "$HERE/claims.sh" "$O/claims.sh.bak"
printf '\n_git() { case "$*" in *ls-remote*) return 1 ;; *) command git -C "$CLAIM_REPO" "$@" ;; esac; }\n' >> "$O/claims.sh"
clear_ref "$REF2"
rm -f "$O/state/mergeclaim-888888.lock" "$O/logs/merge-888888.log"
( cd "$A" && O="$O" REVIEW_TIMEOUT=30 FAKE_PI_INSTANT=1 bash "$MERGE_ONE" "$A" daniel-ospina/tortoise 888888 test/branch >/dev/null 2>&1 )
echo "  exit=$?"
grep -a 'cross-box claim UNAVAILABLE\|released the orphaned' "$O/logs/merge-888888.log" | sed 's/^/  /'
if grep -qa 'released the orphaned claim commit' "$O/logs/merge-888888.log"; then
  ok "merge-one released the orphaned claim after the read-back failure"
else
  bad "no orphan release logged on the read-back failure path"
fi
after9="$(git -C "$A" ls-remote origin "$REF2" | awk '{print $1}')"
[ -z "$after9" ] && ok "the created claim is GONE from origin (not orphaned)" || bad "orphan claim left on origin ($after9)"
cp "$O/claims.sh.bak" "$O/claims.sh"; rm -f "$O/claims.sh.bak"
clear_ref "$REF2"

echo
echo "================ RESULT: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
