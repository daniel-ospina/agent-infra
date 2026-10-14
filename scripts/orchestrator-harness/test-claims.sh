#!/usr/bin/env bash
# test-claims.sh — prove the git-ref CAS claim is real, using TWO independent clones as
# stand-ins for two boxes. Not a mock: both clones talk to the live origin.
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
# ⛔ Remote refs are NOT inside the temp dirs. This suite writes claim refs to LIVE origin on purpose
# (a CAS needs a genuinely shared ref), and a Ctrl-C/kill/abort used to leave them orphaned there —
# the EXIT trap cleaned local dirs only. Delete the remote refs best-effort (fenced), and cover INT
# and TERM as well as EXIT (P3.2, 2026-10-14 adversarial review).
cleanup_remote() {
  local ref cur
  for ref in "${REF:-}" "${OTHER_REF:-}"; do
    [ -n "$ref" ] || continue
    cur="$(git -C "$A" ls-remote origin "$ref" 2>/dev/null | awk '{print $1}')"
    [ -n "$cur" ] && git -C "$A" push -q --force-with-lease="$ref:$cur" origin ":$ref" 2>/dev/null
  done
  return 0
}
cleanup_all() { trap - EXIT INT TERM; cleanup_remote; cleanup_boxes; }
trap cleanup_all EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Run a claims.sh command AS one box. The per-box CLAIM_OWNER_ID is what makes the two stand-ins
# two boxes: without it both carry the same host+pid owner, so "B lost the race" is not evidence.
runA() { ( cd "$A" && export CLAIM_OWNER_ID=boxA && . "$CLAIMS_SH" && "$@" ); }
runB() { ( cd "$B" && export CLAIM_OWNER_ID=boxB && . "$CLAIMS_SH" && "$@" ); }

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

PR=999999
SHA=deadbeefcafebabe0123456789abcdef01234567
REF="refs/claims/$PR-${SHA:0:12}"
# A SECOND real claim, so the fencing test can offer a caller a genuine commit sha that is not this
# ref's — the property the old random-sha test could not exercise (P3.1).
OTHER_SHA=1111111111111111111111111111111111111111
OTHER_REF="refs/claims/$PR-${OTHER_SHA:0:12}"
PASS=0; FAIL=0
ck() { # ck <label> <expected-regex> <actual>
  # ⛔ here-string, not a pipe: `printf … | grep -q` lets grep exit at its first match while the
  # writer is still writing, so the writer takes SIGPIPE — under `set -o pipefail` the pipeline then
  # reports the writer's 141 instead of a match (#841). scripts/check-no-sigpipe-grep.sh fails the
  # build on the piped form.
  if grep -q "$2" <<<"$3"; then echo "  ✅ $1"; PASS=$((PASS+1));
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
# the same CLAIM_OWNER_ID in the same second BOTH reported `acquired` (a byte-identical root commit
# pushed to a ref that already holds it exits 0 as "up-to-date"). The assertions below are the ones
# that go RED without a per-acquisition nonce: the lease SECOND and the git timestamps are forced
# identical, so the nonce is the ONLY thing that can differentiate the two commit objects.
same_second_acquire() { # <box-dir> <owner-id>
  ( cd "$1" \
    && export CLAIM_OWNER_ID="$2" GIT_AUTHOR_DATE='2001-01-01T00:00:00Z' GIT_COMMITTER_DATE='2001-01-01T00:00:00Z' \
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
  ( cd "$1" && export CLAIM_OWNER_ID=probe \
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
  ( cd "$1" && export CLAIM_OWNER_ID=probe \
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
  ( cd "$1" && export CLAIM_OWNER_ID=late CNT="$2" \
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
  ( cd "$1" && export CLAIM_OWNER_ID=boxA && . "$CLAIMS_SH" \
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
  ( cd "$1" && export CLAIM_OWNER_ID=probe \
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
echo "=== cleanup ==="
cleanup_ref
left=$(git -C "$A" ls-remote origin "$REF" | wc -l | tr -d ' ')
echo "  refs left: $left"
[ "$left" = "0" ] && { echo "  ✅ clean"; PASS=$((PASS+1)); } || { echo "  ❌ leak"; FAIL=$((FAIL+1)); }
git -C "$A" for-each-ref --format='  leftover local scratch: %(refname)' refs/claims-cache | head -3

echo
echo "================ RESULT: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
