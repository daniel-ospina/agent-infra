#!/usr/bin/env bash
# branch-claim.test.sh — the single-owner guarantee for batch branches (agent-infra#3328).
#
# THE LOSS IT PREVENTS (measured 2026-11-03): a live peer pushed onto `integration/land-batch-2`
# 43 minutes after the head `004d5afa4` had been reviewed, recorded and tested. The push superseded
# the head, the per-PR `concurrency` group cancelled run 41557371710, and ELEVEN already-green jobs
# were discarded. `gh run rerun --failed` cannot recover that (a cancelled run is not a failed one)
# and a QUEUED job may never be "marked" green — so the only fix is that the branch never moves.
#
# WHAT IS PROVEN HERE, and why each case exists rather than being assumed:
#   1 UNCLAIMED PUSHES     a branch nobody claimed is not refused. Shipping a refusal here would
#                          break every existing `integration/*` push the day it lands.
#   2 OWNER PUSHES         the holder's own push proceeds through the installed hook (a gate that
#                          refuses its owner gets deleted within a day).
#   3 STRAY REFUSED        a lane with no token is REFUSED and told WHO holds it — "advice" that
#                          does not name the holder is not enforcement.
#   4 FENCING              a token that is no longer the claim ref's tip cannot push (the property
#                          is inherited from claims.sh, not re-derived here).
#   5 FENCED RELEASE       a peer cannot release the holder's claim.
#   6 SCOPE                an ordinary feature branch is never gated.
#   7 RECOVERY             after the holder releases, it can re-acquire AND push — the gate is not
#                          a dead end.
#   8 MUTANT               with the hook removed the same stray push SUCCEEDS and the head MOVES,
#                          so 3 measured the hook and not the fixture.
#
# ⛔ NO `git checkout` ANYWHERE: every push names its destination ref (`HEAD:refs/heads/...`).
#
# Run: bash scripts/orchestrator-harness/branch-claim.test.sh
set -u

O="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SELFDIR="$O"
BC="$O/branch-claim.sh"
FAILS=0; PASSES=0
ok()  { PASSES=$((PASSES+1)); printf '  ok   %s\n' "$1"; }
bad() { FAILS=$((FAILS+1));  printf '  FAIL %s\n' "$1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/branch-claim-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
git config --global init.defaultBranch main
# ⛔ HERMETIC CLAIM STATE: the token files live in each checkout's git dir, but the host roster and
# any fallback state must never touch the real fleet's.
export O="$T/orch" CLAIM_STATE_DIR="$T/orch/state"
# ⛔ AND THE AMBIENT REPO SEAM IS CLEARED. The guard resolves the CHECKOUT it runs in; an inherited
# `CLAIM_REPO` (which the harness exports for the controller) made this suite's first run read the
# real registry and report "unclaimed" over a live claim — the bug the guard now refuses to have.
unset CLAIM_REPO CLAIM_OWNER_HOST

BR=integration/land-batch-2
REMOTE_BR="refs/heads/$BR"
SCRATCH=integration/scratch-unclaimed
SCRATCH_REF="refs/heads/$SCRATCH"

# ── fixture: bare "origin", an owner lane, and a peer lane that joins AFTER the branch exists ────
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/owner" 2>/dev/null
( cd "$T/owner" && echo seed > f.txt && git add f.txt && git commit -qm seed \
  && git push -q origin HEAD:main && git push -q origin "HEAD:$REMOTE_BR" && git push -q origin "HEAD:$SCRATCH_REF" ) \
  || { echo "fixture: cannot seed origin" >&2; exit 2; }
git clone -q "$T/origin.git" "$T/stray" 2>/dev/null
for c in owner stray; do
  ( cd "$T/$c" && CLAIM_REPO="$T/$c" "$BC" install-hook >/dev/null ) \
    || { echo "fixture: install-hook failed in $c" >&2; exit 2; }
done

guard_from()   { ( cd "$T/$1" && "$BC" guard "$2" >/dev/null 2>"$T/guard.err" ); }
acquire_from() { ( cd "$T/$1" && "$BC" acquire "$2" ${3:+"$3"} >"$T/acq.out" 2>&1 ); }
release_from() { ( cd "$T/$1" && "$BC" release "$2" >"$T/rel.out" 2>&1 ); }
commit_in()    { ( cd "$T/$1" && echo "$2" >> f.txt && git commit -qam "$2" ); }
push_in()      { ( cd "$T/$1" && git push -q origin "HEAD:$2" 2>"${3:-/dev/null}" ); }

echo "== 1. unclaimed branch: the push is NOT refused"
guard_from stray "$SCRATCH"; eq "guard allows an unclaimed branch" "$?" "0"
commit_in stray "unclaimed push"
if push_in stray "$SCRATCH_REF" "$T/p1.err"; then
  ok "stray push to an UNCLAIMED branch succeeds (fail-closed here would break every existing push)"
else
  bad "stray push to an unclaimed branch was refused: $(cat "$T/p1.err")"
fi

echo "== 2. owner acquires; its own push proceeds through the hook"
acquire_from owner "$BR"; eq "owner acquire rc" "$?" "0"
grep -q '^HELD branch=' "$T/acq.out" && ok "acquire prints HELD" || bad "acquire output: $(cat "$T/acq.out")"
guard_from owner "$BR"; eq "guard allows the HOLDER" "$?" "0"
commit_in owner "owner push"
if push_in owner "$REMOTE_BR" "$T/p2.err"; then
  ok "owner push succeeds"
else
  bad "owner push refused: $(cat "$T/p2.err")"
fi
OWNER_HEAD="$(cd "$T/owner" && git rev-parse HEAD)"

echo "== 3. stray lane is REFUSED, and told who holds it"
commit_in stray "STRAY push"
STRAY_HEAD="$(cd "$T/stray" && git rev-parse HEAD)"
if push_in stray "$REMOTE_BR" "$T/stray.err"; then
  bad "the STRAY push SUCCEEDED — the branch is not single-owner"
else
  ok "stray push refused"
fi
grep -q 'branch-claim: REFUSED' "$T/stray.err" && ok "refusal names itself (branch-claim: REFUSED)" \
  || bad "refusal text: $(cat "$T/stray.err")"
grep -qE 'holder=[^ ]+:[0-9]+' "$T/stray.err" && ok "refusal NAMES THE HOLDER" || bad "no holder in: $(cat "$T/stray.err")"
grep -q 'held-by-live' "$T/stray.err" && ok "refusal carries the reason (held-by-live)" || bad "no reason in: $(cat "$T/stray.err")"
eq "the remote branch did NOT move (no head move => nothing to supersede)" \
   "$(cd "$T/origin.git" && git rev-parse "$BR")" "$OWNER_HEAD"

echo "== 4a. a LIVE claim cannot be re-acquired by a peer (the orphan rules must abstain)"
# ⛔ THIS IS THE B3/F1 REGRESSION PIN. A branch claim's holder pid is the acquiring CLI, dead by
# design, so a pid-based orphan rule reclaims a live claim; a host-based one does it after a rename or
# with a roster that does not name the peer. Both gave the peer ownership and refused the real owner.
acquire_from stray "$BR"; eq "peer acquire against a LIVE claim is refused" "$?" "1"
grep -q 'held-by' "$T/acq.out" && ok "refusal says held-by-live" || bad "text: $(cat "$T/acq.out")"
( . "$SELFDIR/claims.sh"; claim_orphan_reason "oldbox:4242" "refs/claims/branch-integration-land-batch-2" >/dev/null 2>&1 ) \
  && bad "claim_orphan_reason called a BRANCH claim ORPHANED (a prune would delete a live claim)" \
  || ok "claim_orphan_reason ABSTAINS for a branch key (former-name / roster arms included)"
# ⛔ THE PROBE ABOVE IS NOT ENOUGH ON ITS OWN (cycle-3 review): in a hermetic state dir with no roster
# and no former name, EVERY host arm abstains for ANY key — so it stayed green against the very code it
# was written to catch. These probes PUSH the host arms: a former name on disk, a roster that does not
# name the peer, and a DEAD_HOSTS entry — plus a PR-claim CONTROL, so a claim_orphan_reason that
# abstained for everything could not pass them either.
mkdir -p "$CLAIM_STATE_DIR"; printf 'oldbox\n' >> "$CLAIM_STATE_DIR/claim-hosts"
(
  . "$SELFDIR/claims.sh"
  export CLAIM_OWNER_HOST=mehost CLAIM_KNOWN_HOSTS="mehost,thirdbox" CLAIM_DEAD_HOSTS=deadbox
  claim_orphan_reason "oldbox:4242" "refs/claims/branch-integration-land-batch-2" >/dev/null 2>&1 && exit 0
  claim_orphan_reason "peerbox:4242" "refs/claims/branch-integration-land-batch-2" >/dev/null 2>&1 && exit 0
  claim_orphan_reason "deadbox:4242" "branch-integration-2026-11-03-batch" >/dev/null 2>&1 && exit 0
  claim_orphan_reason "peerbox:4242" "refs/claims/3329-e70c7e325fd7" >/dev/null 2>&1 || exit 0
  exit 1
)
case "$?" in
  0) bad "claim_orphan_reason called a BRANCH claim ORPHANED through a HOST arm (a prune would delete a live claim)" ;;
  1) ok "claim_orphan_reason abstains for a branch key on the FORMER-NAME, ROSTER and DEAD_HOSTS arms (PR control still ORPHANED)" ;;
  *) bad "the host-arm orphan probe did not run cleanly" ;;
esac

echo "== 4b. an EXPIRED claim must be reclaimed, not waited on forever (until= must parse)"
release_from owner "$BR"; eq "owner releases" "$?" "0"
acquire_from stray "$BR" 1; eq "peer acquires with a 1s lease" "$?" "0"
sleep 2
guard_from owner "$BR"; eq "an EXPIRED claim is refused for a lane without its token" "$?" "1"
grep -q 'claim-expired-unreclaimed' "$T/guard.err" && ok "the expired arm is reachable (reason=claim-expired-unreclaimed)" \
  || bad "the expired arm did not fire — until= is unparseable again: $(cat "$T/guard.err")"
grep -q 'until=[0-9]' "$T/guard.err" && ok "the refusal prints a real lease deadline" || bad "until= empty: $(cat "$T/guard.err")"
acquire_from owner "$BR"; eq "owner reclaims the EXPIRED claim" "$?" "0"
guard_from stray "$BR"; eq "the STALE holder is refused" "$?" "1"
grep -q 'held-by-live' "$T/guard.err" && ok "stale-token refusal is held-by-live (token fence)" || bad "text: $(cat "$T/guard.err")"

echo "== 5. release is fenced: a peer cannot release the holder's claim"
release_from stray "$BR"; eq "peer release refused" "$?" "1"
( cd "$T/origin.git" && git rev-parse --verify -q refs/claims/branch-integration-land-batch-2 >/dev/null ) \
  && ok "the claim ref survives the peer's release attempt" || bad "the peer's release deleted the claim"

echo "== 6. scope: an ordinary branch is never gated"
commit_in stray "feature"
if push_in stray "refs/heads/fix/whatever" "$T/p6.err"; then
  ok "non-integration branch pushes freely"
else
  bad "scope too broad: $(cat "$T/p6.err")"
fi

echo "== 7. recovery: the holder releases, re-acquires and pushes again"
( cd "$T/owner" && git fetch -q origin "$REMOTE_BR:$REMOTE_BR" 2>/dev/null || git fetch -q origin )
release_from owner "$BR"; eq "owner release" "$?" "0"
acquire_from owner "$BR"; eq "owner re-acquire" "$?" "0"
commit_in owner "owner after reclaim"
if push_in owner "$REMOTE_BR" "$T/p7.err"; then
  ok "owner push proceeds after reclaim"
else
  bad "owner push refused after reclaim: $(cat "$T/p7.err")"
fi

echo "== 8. MUTANT — remove the enforcement; the same stray push succeeds and the head MOVES"
# A FRESH clone with NO hook installed: the mutant is "the guard is absent", not "the guard is
# bypassed by a fixture accident", and a fresh clone also has the remote tip as its base.
git clone -q --branch "$BR" "$T/origin.git" "$T/stray2" 2>/dev/null
commit_in stray2 "MUTANT stray push"
MUTANT_HEAD="$(cd "$T/stray2" && git rev-parse HEAD)"
if push_in stray2 "$REMOTE_BR" "$T/mut.err"; then
  ok "MUTANT: with no hook the stray push SUCCEEDS — so case 3 measured the hook"
else
  bad "MUTANT: the stray push was still refused without any hook — case 3 proves nothing: $(cat "$T/mut.err")"
fi
eq "MUTANT: the branch head moved onto the stray commit" \
   "$(cd "$T/origin.git" && git rev-parse "$BR")" "$MUTANT_HEAD"

echo "== 9. a chained FOREIGN pre-push hook still receives the ref lines on stdin"
# ⛔ F2: our own `while read` consumes stdin, so the chain used to see ZERO lines and a chain written
# `while read local_ref …; do validate; done` validated nothing and exited 0 — a false PASS on a peer's
# gate. The chain here records what it was handed; the assertion is on those bytes.
git clone -q --branch "$BR" "$T/origin.git" "$T/chainbox" 2>/dev/null
hookdir="$T/chainbox/.git/hooks"
printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\n" "$a"; done > "%s/chain-argv.txt"\ncat > "%s/chain-stdin.txt"\n' "$T" "$T" > "$hookdir/pre-push"
chmod +x "$hookdir/pre-push"
( cd "$T/chainbox" && "$BC" install-hook --force >/dev/null 2>&1 ) || bad "install-hook --force over a foreign hook"
commit_in chainbox "chained hook"
push_in chainbox "$REMOTE_BR" "$T/p9.err" || true
if [ -s "$T/chain-stdin.txt" ]; then
  ok "the chained hook RECEIVED its ref lines ($(wc -l < "$T/chain-stdin.txt") line(s))"
  grep -q 'refs/heads/integration/land-batch-2' "$T/chain-stdin.txt" && ok "the chain got the ref it must validate" \
    || bad "wrong bytes to the chain: $(cat "$T/chain-stdin.txt")"
  # ⛔ ARGV IS THE OTHER HALF OF THE CONTRACT (cycle-3 review): a chain keyed on the remote, or one
  # running under `set -u`, sees `$1`/`$2` unset when only stdin is forwarded.
  grep -q origin "$T/chain-argv.txt" 2>/dev/null && ok "the chain got its ARGUMENTS (remote name/url)" \
    || bad "the chain got no arguments: argv=[$(tr '\n' ' ' < "$T/chain-argv.txt" 2>/dev/null)]"
else
  bad "the chained hook got an EMPTY stdin — a peer gate would validate nothing and PASS"
fi

echo
printf 'branch-claim.test.sh: %d passed, %d failed\n' "$PASSES" "$FAILS"
[ "$FAILS" -eq 0 ] || exit 1
