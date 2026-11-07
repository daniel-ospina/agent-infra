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
#   9 CHAINED HOOK         a FOREIGN pre-push hook already in place still receives the ref lines on
#                          STDIN and its ARGV, so a chain written `while read …; do validate; done`
#                          validates the real lines instead of silently validating nothing.
#  10 THE TERM             the DEFAULT branch lease is `CLAIM_BRANCH_TTL` (14400s), that same value is
#                          the CEILING (a caller cannot mint a longer one), `CLAIM_TTL_MAX` (9600)
#                          does NOT clamp it, an over-ceiling clamp is LOUD on stderr, and raising the
#                          env var raises default AND ceiling together (one knob, not two). Added by
#                          later rounds on the same case: an UNPARSEABLE ttl falls back to the BRANCH
#                          default — never the PR claim's 1800s — the printed ceiling FOLLOWS the knob,
#                          and the bound is a STRICT `-gt` (a lease of exactly the ceiling is never
#                          "clamped" and never warns). Before
#                          this case NOTHING in the suite named `CLAIM_BRANCH_TTL`: measured,
#                          reverting the default to the PR claim's 1800s left every suite green, so
#                          the single-owner guarantee's entire term — the thing whose expiry lets a
#                          peer take a LIVE batch branch — was unpinned.
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
# ⛔ AND SO ARE THE LEASE SEAMS, for the same reason one class further along (review round 1): case 10
# pins the DEFAULT term, so a cell that legitimately raised the knob — the operation `claims.sh`
# advertises — would get a FALSE RED on correct code. Measured (round 7, this `unset` deleted and
# `CLAIM_BRANCH_TTL=18000` exported): case 10 reddens on EVERY arm that pins a term — the default
# lease, the at-ceiling lease (the bound is a strict `-gt`), the unparseable-ttl fallback, the printed
# ceiling and the over-ceiling clamp — a lease that was doing exactly what it was told, read as five
# defects. The arms are NAMED by subject rather than counted because a count rots the moment an arm is
# added: round 1 wrote "2 failures" here, by round 5 the same experiment reddened 3, the round-12
# fallback arm made it 4, and the round-13 boundary arm made it 5 — so a reader re-running it must
# compare SUBJECTS, not a number. Empty is safe: `claims.sh`
# falls back to 14400 / 9600 on an empty or unparseable value.
unset CLAIM_REPO CLAIM_OWNER_HOST CLAIM_BRANCH_TTL CLAIM_TTL_MAX

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

echo "== 7b. an UNPARSEABLE lease on a branch claim is an ABSTENTION, never a live holder (#3203)"
# ⛔ THE PUSH GATE IS THE ONE REFUSAL SITE WHOSE WORD A LANE ACTUALLY READS. Before agent-infra#3203
# a branch claim whose `lease_until` cannot be parsed fell through to `reason=held-by-live`, telling
# the lane a PEER IS WORKING on it — when in truth nobody could ever judge the term (and, before the
# bounded reap, nobody could ever release it). The answer is unchanged (rc 1, nothing released); the
# LABEL is the fix, and a lane cannot be told to wait for a holder that does not exist.
BCREF="refs/claims/branch-integration-land-batch-2"
( cd "$T/owner" && export CLAIM_REPO="$T/owner" CLAIM_OWNER_HOST=boxA && . "$SELFDIR/claims.sh" \
  && c="$(_claim_commit "peerbox:4242" 0)" && _git push -q --force origin "$c:$BCREF" ) 2>/dev/null \
  || bad "fixture: cannot seed an unparseable-lease branch claim"
guard_from stray "$BR"; eq "an unparseable branch lease still REFUSES the lane (rc 1)" "$?" "1"
grep -q 'reason=lease-unreadable' "$T/guard.err" \
  && ok "the refusal names the real fault (reason=lease-unreadable)" \
  || bad "the push gate still mislabels the class: $(cat "$T/guard.err")"
grep -q 'held-by-live' "$T/guard.err" \
  && bad "the refusal claims a LIVE holder for a lease nobody can parse: $(cat "$T/guard.err")" \
  || ok "...and does NOT claim a live holder (no held-by-live)"
grep -q 'CLAIM_UNREADABLE_LEASE_MAX_AGE\|agent-infra#3203' "$T/guard.err" \
  && ok "...and names the bounded reap that will end the block, or the hand remedies" \
  || bad "the refusal names no way out: $(cat "$T/guard.err")"
( cd "$T/origin.git" && git rev-parse --verify -q "$BCREF" >/dev/null ) \
  && ok "the unparseable claim was NOT released by the guard (a refusal is never a release)" \
  || bad "the guard DELETED an unparseable claim it should only have refused"

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

echo "== 10. the DEFAULT branch lease is CLAIM_BRANCH_TTL (14400s), and it is its OWN ceiling"
# ⛔ WHY THIS CASE EXISTS. `claim_branch_acquire` passes `CLAIM_BRANCH_TTL` as the default AND the
# ceiling, and the lease is the single-owner guarantee in arithmetic form: a term shorter than the
# batch hands the branch to a peer MID-BATCH (the exact loss #3328 exists to prevent), and a term
# longer than the key's own ceiling is one no reaper can reach. Nothing pinned either number.
lease_of() { # <ref> -> the claim commit's lease_until epoch
  git --git-dir="$T/origin.git" log -1 --format=%s "$1" 2>/dev/null | sed -n 's/.*lease_until=\([0-9]*\).*/\1/p'
}
lease_arm() { # <label> <expected-seconds> <lease_until-epoch>
  # ⛔ THE TOLERANCE IS WIDE ENOUGH TO SURVIVE A LOADED BOX, NOT A TIGHT CLOCK. `NOW` is taken
  # immediately before EVERY acquire (see each arm), so the delta can only exceed the term by that one
  # acquire's own duration — a bare-repo CAS under a loaded fleet is not sub-second, and a tighter
  # bound would be a flake rather than a gate. ±15 s still discriminates every value that matters here:
  # 1800 and 9600 are 1000 s+ away.
  local want="$2" d
  d=$(( $3 - NOW ))
  if [ "$d" -ge "$(( want - 15 ))" ] && [ "$d" -le "$(( want + 15 ))" ]; then
    ok "$1 (lease ${d}s from now, want ~${want}s)"
  else
    bad "$1 (lease ${d}s from now, want ~${want}s; lease_until=$3 now=$NOW)"
  fi
}
BR_LEASE=integration/lease-default
BR_LEASE_BOUNDARY=integration/lease-boundary
BR_LEASE_CEIL=integration/lease-ceiling
BR_LEASE_FALLBACK=integration/lease-fallback
BR_LEASE_KNOB=integration/lease-knob
BR_LEASE_KNOB_DEF=integration/lease-knob-default
NOW=$(date +%s)
acquire_from owner "$BR_LEASE"
eq "acquire with NO explicit ttl succeeds" "$?" "0"
L1="$(lease_of refs/claims/branch-integration-lease-default)"
if [ -n "$L1" ]; then lease_arm "the DEFAULT lease is the branch key's own 14400s, not the PR claim's 1800s" 14400 "$L1"; else bad "no lease_until on the default-acquire claim ref"; fi
# ⛔ AND THE BOUND IS A STRICT `-gt`, WHICH IS A PROPERTY OF ITS OWN (review round 13, P2).
# `claim_branch_acquire` passes `CLAIM_BRANCH_TTL` as BOTH the default and the ceiling, so its DEFAULT
# path requests a ttl EXACTLY EQUAL to `max`. Under a `-ge` bound that acquire is "clamped": nothing
# is shortened, but every batch acquire prints `lease ttl 14400s exceeds this keying ceiling
# (14400s) — clamped.` on stderr — telling an operator to raise a knob while the lease is exactly what
# was asked for, on the path `merge-one.sh` runs with stdout discarded. Measured BEFORE the arm
# below existed: flipping the bound to `-ge` left this suite 45 passed, 0 failed — nothing pinned the
# strictness, although `merge-one.sh` states it as a FACT ("its test is a STRICT `-gt`, so a lease of
# exactly the ceiling is never clamped"). With the arm in place the same flip reddens exactly that
# arm and nothing else. The AT-CEILING acquire runs with the streams SPLIT and its stderr is read
# three ways — grep's exit 2
# (unreadable operand) must not read as "no warning", the same fail-closed rule as the arm above.
NOW=$(date +%s)
( cd "$T/owner" && "$BC" acquire "$BR_LEASE_BOUNDARY" >"$T/bnd.stdout" 2>"$T/bnd.stderr" )
eq "an acquire at EXACTLY the ceiling succeeds" "$?" "0"
L1C="$(lease_of refs/claims/branch-integration-lease-boundary)"
if [ -n "$L1C" ]; then lease_arm "a lease of EXACTLY the ceiling is NOT shortened (the bound is a strict -gt)" 14400 "$L1C"; else bad "no lease_until on the at-ceiling claim ref"; fi
grep -q 'exceeds this keying ceiling' "$T/bnd.stderr"; BND_RC=$?
case "$BND_RC" in
  0) bad "a lease of EXACTLY the ceiling emitted the clamp warning — under a '-ge' bound every batch acquire warns while shortening nothing: $(cat "$T/bnd.stderr")" ;;
  1) ok "a lease of EXACTLY the ceiling is not clamped and emits no warning (the bound is a strict -gt)" ;;
  *) bad "the at-ceiling stderr probe could not be read (grep rc=$BND_RC) — an unreadable stream must not read as clean: $(cat "$T/bnd.stderr")" ;;
esac
# ⛔ AND THE CORE'S OWN `dflt` ARGUMENT (review of this change, P2). `claim_branch_acquire` passes
# FOUR things to `_claim_acquire_at` — ref, ttl, dflt, max — and the arm above pins only the
# CALLER-side default (`${3:-$CLAIM_BRANCH_TTL}`). Nothing pinned arg 3, which is what an UNPARSEABLE
# ttl falls back to (`claims.sh`: `''|*[!0-9]*|0?*) ttl="$dflt"`); measured, changing arg 3 alone to
# `$CLAIM_TTL` left THIS SUITE 44/0 and `claim-orphan.test.sh` 138/0 — both fully green. WITH the arm
# below in place the same mutant reddens EXACTLY IT (the fallback arm goes red and no other arm does),
# so the number above is the PRE-ARM baseline and is labelled as such rather than read as a statement
# about this head: re-run it by SUBJECT, not by count. That is the
# same class this case exists to remove, one level down, and it is REACHABLE: `branch-claim.sh`'s
# `cmd_acquire` passes the CLI ttl through unvalidated (`acquire <branch> 07`), so a typo would hand a
# live batch the PR claim's 1800s term. The issue keying's equivalent property is already pinned next
# door (`claim-orphan.test.sh`, "an unparseable ttl falls back to the ISSUE default … never the PR's
# shorter one"); the branch keying was the one left out.
NOW=$(date +%s)
acquire_from owner "$BR_LEASE_FALLBACK" 07
L1B="$(lease_of refs/claims/branch-integration-lease-fallback)"
if [ -n "$L1B" ]; then lease_arm "an UNPARSEABLE ttl falls back to the BRANCH default (14400s), never the PR claim's 1800s" 14400 "$L1B"; else bad "no lease_until on the unparseable-ttl claim ref"; fi
# ⛔ THE CEILING ARM. An explicit over-ceiling request must clamp to THIS KEY's ceiling (14400) and say
# so — not to CLAIM_TTL_MAX (9600). A clamp to 9600 shreds 33 % of a batch's term (14400 -> 9600).
NOW=$(date +%s)
# ⛔ THE WARNING MUST BE ON STDERR, AND THAT IS ASSERTED ON THE STREAM ITSELF (review of this change,
# P3). `acquire_from` merges `2>&1` into `$T/acq.out`, so it proves only that SOME stream carries the
# warning while this case's stated subject is "clamped LOUDLY on stderr". Measured: deleting `>&2`
# from the clamp left this suite 44/0 — and stderr is the ONLY stream that survives the shipped call
# site, because `merge-one.sh` runs its acquire with `>/dev/null`: a stdout warning would be
# completely invisible in the log, which is the one consequence this bound must never hide. So the
# streams are split for this arm, then recombined so every later assertion still reads `acq.out`.
( cd "$T/owner" && "$BC" acquire "$BR_LEASE_CEIL" 999999 >"$T/acq.stdout" 2>"$T/acq.stderr" )
cat "$T/acq.stderr" "$T/acq.stdout" >"$T/acq.out"
grep -q 'exceeds this keying ceiling' "$T/acq.stderr" && ok "an over-ceiling ttl is clamped LOUDLY on STDERR (the stream merge-one cannot discard)" \
  || bad "the clamp warning is NOT on stderr — merge-one runs the acquire with stdout discarded, so it would be silent: $(cat "$T/acq.stdout")"
# ⛔ AND IT MUST NOT NAME ANOTHER KEYING'S KNOB AS THE CEILING (review round 2, P2; round 5 widened
# it). The warning used to read "(CLAIM_TTL_MAX/CLAIM_ISSUE_TTL = 14400s)" — for a branch key BOTH
# names are wrong (9600 / 18000), so a fixer was sent to raise a knob that is not the ceiling. Two
# literal greps (the exact former string, then a positive mention of this keying's name) were each
# defeated by a respelling — "ceiling (CLAIM_ISSUE_TTL = 14400s) — clamped. Candidates: … CLAIM_BRANCH_TTL"
# mentions this keying AND avoids the old spelling while still naming the wrong ceiling. So the
# assertion is on the PROPERTY: the clause inside `ceiling ( … )` must not be another keying's knob.
# ⛔ AND IT MUST FAIL CLOSED (review round 6, P2). The first form of this arm was
# `if grep -qE '…' ; then bad …; else ok …; fi`, which reports PASS for ANY non-zero grep status —
# exit 2 (unreadable operand) included — and used `\b`, a GNU/BSD extension rather than POSIX ERE.
# A guard that cannot answer must not read as clean, so the three outcomes are separated here.
# ⛔ AND IT MUST NOT BE A SPELLING (review round 7, P1 + P2). The pattern as it stood terminated the
# knob name with `([ )]|$)` — space, `)` or EOL — so the LEAST creative respelling, a SLASH, walked
# straight through it: the exact former message `ceiling (CLAIM_TTL_MAX/CLAIM_ISSUE_TTL = 14400s)`
# printed `ok`, and so did a hybrid carrying both a wrong clause and the right one. Widening the
# delimiter class only moves the same problem one respelling along. So this arm asserts the
# PROPERTY instead: the clause INSIDE `ceiling ( … )` states the ceiling VALUE and nothing else —
# every knob name lives in the "raise the ceiling for that keying ( … )" list that FOLLOWS — so the
# clause must contain no `CLAIM_` name at all. No respelling of a knob can be a bare number.
# ⛔ AND IT IS NON-VACUOUS (round 7, P2): `grep` returns 1 both for "found nothing" and "read
# nothing", so an EMPTY message used to satisfy "does not name another knob". Here an absent clause
# is its own outcome and it is RED, not green.
# ⛔ AND THE PROPERTY COVERS THE WHOLE MESSAGE (round 8 then round 9 — two reviews MEASURED this arm
# instead of trusting its comment, and each found a region left unread). Round 7 guarded only the
# parenthetical and passed a message naming the wrong ceiling OUTSIDE it; round 8 guarded "before the
# candidate list" and passed one naming it AFTER the list — "… (CLAIM_TTL_MAX / CLAIM_ISSUE_TTL /
# CLAIM_BRANCH_TTL) …; the ceiling is CLAIM_ISSUE_TTL." ran 43 passed, 0 failed. There are three
# regions, so all three are asserted: (a) inside `ceiling ( … )`, (b) before the candidate list,
# (c) AFTER it. A `CLAIM_` name is legal ONLY inside the candidate list, which is exactly what the
# shipped message does. If the list sentence is ever reworded the arm reddens — fail-CLOSED, because a
# contract the test does not recognise is not a pass.
# ⛔ AND THERE IS EXACTLY ONE CLAUSE (round 9 self-check, P2). "First clause" is only the OPERATIVE
# clause if no earlier decoy exists: on the head that round was written on, "the branch ceiling
# (14400s) is documented here. lease ttl %ss exceeds this keying ceiling (9600s) — clamped. …" ran
# 43 passed, 0 failed while a fixer reads 9600 (the count is that round's; re-run by SUBJECT). The
# contract is ONE clause, so any second `ceiling (` — before OR after it — is RED.
clause_report() { # <message-file> -> the arm's structured verdict (see the comment above)
awk '
  { msg = $0
    s = msg
    while ((i = index(s, "ceiling (")) > 0) {
      s = substr(s, i + 9)
      j = index(s, ")")
      if (j == 0) { unterminated = 1; break }
      n++
      c = substr(s, 1, j - 1)
      if (n == 1) firstval = c
      if (c ~ /CLAIM_/) named = c
      s = substr(s, j + 1)
    }
    p = index(msg, "Raise the ceiling for that keying (")
    if (p > 0) {
      head = substr(msg, 1, p - 1)
      rest = substr(msg, p)
      q = index(rest, ")")
      after = (q > 0) ? substr(rest, q + 1) : rest
    } else {
      head = msg
      after = ""
    }
    if (head ~ /CLAIM_/) outside = head
    if (after ~ /CLAIM_/) trail = after }
  END {
    if (unterminated) print "UNTERMINATED"
    else if (n == 0) print "ABSENT"
    else if (named != "") print "NAMES " named
    else if (outside != "") print "BEFORE-LIST " outside
    else if (trail != "") print "AFTER-LIST " trail
    else if (n != 1) print "MULTIPLE " n
    else print "OK " firstval
  }
' "$1" 2>/dev/null
}
CLAUSE_REPORT="$(clause_report "$T/acq.out")"
case "$CLAUSE_REPORT" in
  "OK "*) ok "the clamp warning names a keying knob ONLY in the candidate list" ;;
  ABSENT) bad "the clamp warning carries no 'ceiling ( … )' clause to evaluate — an empty or absent clause must not read as clean: $(cat "$T/acq.out")" ;;
  UNTERMINATED) bad "the clamp warning's 'ceiling (' clause is unterminated — the property cannot be evaluated: $(cat "$T/acq.out")" ;;
  "NAMES "*) bad "the clamp warning names a keying knob AS this ceiling inside 'ceiling ( … )': ${CLAUSE_REPORT#NAMES }" ;;
  "BEFORE-LIST "*) bad "the clamp warning names a keying knob as the ceiling BEFORE the candidate list: ${CLAUSE_REPORT#BEFORE-LIST }" ;;
  "AFTER-LIST "*) bad "the clamp warning names a keying knob as the ceiling AFTER the candidate list: ${CLAUSE_REPORT#AFTER-LIST }" ;;
  "MULTIPLE "*) bad "the clamp warning carries ${CLAUSE_REPORT#MULTIPLE } 'ceiling ( … )' clauses — with more than one, the number a fixer reads is not provably this keying's: $(cat "$T/acq.out")" ;;
  *) bad "the not-another-knob guard could not evaluate the property (awk said '${CLAUSE_REPORT}') — unreadable operand must not read as clean" ;;
esac
# ⛔ AND THE PRINTED NUMBER IS PINNED SEPARATELY (round 5, P2), AND ON THE OPERATIVE CLAUSE (round 9,
# P2). The arm above checks WHICH KNOBS are named; this one checks the NUMBER. Round 5's form was
# `grep -q 'ceiling (14400s)'` — presence ANYWHERE in the message, so a message whose operative clause
# printed 9600 while a decoy clause carried `ceiling (14400s)` ran 43 passed, 0 failed, and a fixer
# reads `ceiling (9600s)`. The number must be the FIRST clause's — the shipped message has exactly one
# and it is the operative one — so awk reports it and this asserts on the value, not on presence.
# Each arm below carries an `ok` as well as its `bad` (review round 6, P2): an assertion with only
# the failure arm prints nothing on success and increments neither PASSES nor FAILS, so a green run
# under-reports what executed and the arm can be deleted without moving any number.
case "$CLAUSE_REPORT" in
  "OK 14400s") ok "the clamp warning prints this keying's own ceiling (14400s) as its operative ceiling" ;;
  *) bad "the clamp warning's operative ceiling clause does not print this keying's ceiling (14400s) — report '${CLAUSE_REPORT}': $(cat "$T/acq.out")" ;;
esac
# ⛔ AND THE GUARD IS NOT A SINGLE LITERAL (review round 3, P2): the message must also name THIS
# keying's variable among the candidates it suggests raising.
if grep -q 'CLAIM_BRANCH_TTL' "$T/acq.out"; then
  ok "the clamp warning names CLAIM_BRANCH_TTL among the ceiling candidates"
else
  bad "the clamp warning does not name CLAIM_BRANCH_TTL as a ceiling candidate: $(cat "$T/acq.out")"
fi
L2="$(lease_of refs/claims/branch-integration-lease-ceiling)"
if [ -n "$L2" ]; then lease_arm "an over-ceiling request clamps to CLAIM_BRANCH_TTL (14400), NOT to CLAIM_TTL_MAX (9600)" 14400 "$L2"; else bad "no lease_until on the over-ceiling claim ref"; fi
# ⛔ THE KNOB ARM — ONE KNOB, NOT TWO (review round 2, P2). The comment in `claims.sh` claims that
# raising the env var raises the DEFAULT and the CEILING together. Two literals cannot prove that: a
# mutant that hardcodes the ceiling (`_claim_acquire_at … "14400"`) leaves every arm above green,
# because it only differs once the knob MOVES. Here it moves: with CLAIM_BRANCH_TTL=20000 an
# over-ceiling request must clamp to 20000, not to 14400. Measured with the split-knob mutant
# (`_claim_acquire_at … "$CLAIM_BRANCH_TTL" "14400"`): this arm AND the DEFAULT arm below both
# redden, because a hardcoded ceiling caps a raised default too — plus, since round 11, the
# knob-follows value arm, which raises that tally to three. It said "this arm is the ONLY one that
# reddens" until round 11: true when measured in round 2, and rotted the moment round 3 added the arm
# below — the "a count rots the moment an arm is added" defect this file's `unset` comment records.
NOW=$(date +%s)
CLAIM_BRANCH_TTL=20000 acquire_from owner "$BR_LEASE_KNOB" 999999
L3="$(lease_of refs/claims/branch-integration-lease-knob)"
if [ -n "$L3" ]; then lease_arm "CLAIM_BRANCH_TTL=20000 raises the CEILING too — one knob, not a split term" 20000 "$L3"; else bad "no lease_until on the env-raised claim ref"; fi
# ⛔ AND THE PRINTED NUMBER MUST FOLLOW THE KNOB TOO (review round 11, P2). The value arm above runs
# with `CLAIM_BRANCH_TTL` UNSET, so it pins the literal `14400s` and cannot tell a `%ss`-from-`$max`
# message from one that hardcodes `14400s`: measured, a message that always prints `ceiling (14400s)`
# ran 43 passed, 0 failed — and it prints a number that is NOT the ceiling the moment this same case
# raises the knob to 20000, which is exactly the misdirection ("a fixer reads a number that is not
# the ceiling") the arm exists to catch. The knob has moved HERE, so the number must move with it.
KNOB_CLAUSE_REPORT="$(clause_report "$T/acq.out")"
case "$KNOB_CLAUSE_REPORT" in
  "OK 20000s") ok "the printed ceiling FOLLOWS the knob (20000s) — it is the keying's \$max, not a literal" ;;
  *) bad "the printed ceiling did not follow CLAIM_BRANCH_TTL=20000 — report '${KNOB_CLAUSE_REPORT}' (a hardcoded number passes every arm that runs at the default): $(cat "$T/acq.out")" ;;
esac
# ⛔ AND THE OTHER HALF OF THE SAME PROPERTY (review round 3, P2): the CEILING following the knob does
# not prove the DEFAULT does. The default arm above runs with the knob UNSET, where a hardcoded
# `${3:-14400}` is indistinguishable from `$CLAIM_BRANCH_TTL` — BEFORE the arm below existed, that
# mutant left EVERY assertion green (naming the count here would rot, as the `unset` comment above
# records); with the arm in place it reddens exactly that arm. Without it, `CLAIM_BRANCH_TTL=20000`
# produced a 14400 s DEFAULT against a 20000 s ceiling — exactly the "longer than its own clamp" split
# these arms exist to forbid. So the knob is moved once more, on the DEFAULT path.
NOW=$(date +%s)
CLAIM_BRANCH_TTL=20000 acquire_from owner "$BR_LEASE_KNOB_DEF"
L4="$(lease_of refs/claims/branch-integration-lease-knob-default)"
if [ -n "$L4" ]; then lease_arm "CLAIM_BRANCH_TTL=20000 raises the DEFAULT too — one knob, not two" 20000 "$L4"; else bad "no lease_until on the env-raised DEFAULT claim ref"; fi

echo
printf 'branch-claim.test.sh: %d passed, %d failed\n' "$PASSES" "$FAILS"
[ "$FAILS" -eq 0 ] || exit 1
