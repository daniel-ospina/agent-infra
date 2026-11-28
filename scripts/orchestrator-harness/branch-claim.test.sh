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
#   6 SCOPE                the TRUNK is out of scope by KIND (a CLAIMED `main` still pushes), while an
#                          ordinary lane branch stays IN scope — and the trunk subject is CLAIMED first,
#                          so the arm can fail (cycle-3 review F2: unclaimed, rc was 0 either way).
#   7 RECOVERY             after the holder releases, it can re-acquire AND push — the gate is not
#                          a dead end.
#   8 MUTANT               with the hook removed the same stray push SUCCEEDS and the head MOVES,
#                          so 3 measured the hook and not the fixture.
#   9 CHAINED HOOK         a FOREIGN pre-push hook already in place still receives the ref lines on
#                          STDIN and its ARGV, so a chain written `while read …; do validate; done`
#                          validates the real lines instead of silently validating nothing.
#  10 THE TERM             the DEFAULT branch lease is `CLAIM_BRANCH_TTL` (14400s), that same value is
#                          the CEILING (a caller cannot mint a longer one), `CLAIM_TTL_MAX` (43200
#                          since agent-infra#4034) does NOT clamp it — this keying's ceiling is its own
#                          term — an over-ceiling clamp is LOUD on stderr, and raising the
#                          env var raises default AND ceiling together (one knob, not two). Added by
#                          later rounds on the same case: an UNPARSEABLE ttl falls back to the BRANCH
#                          default — never the PR claim's 1800s — the printed ceiling FOLLOWS the knob,
#                          and the bound is a STRICT `-gt` (a lease of exactly the ceiling is never
#                          "clamped" and never warns). Before
#                          this case NOTHING in the suite named `CLAIM_BRANCH_TTL`: measured,
#                          reverting the default to the PR claim's 1800s left every suite green, so
#                          the single-owner guarantee's entire term — the thing whose expiry lets a
#                          peer take a LIVE batch branch — was unpinned.
#  16 INSTALL SUBJECT      `install-hook` verifies the checkout it WROTE TO, not the caller's cwd, so a
#                          controller outside any work tree (the documented `CLAIM_REPO` fallback) gets
#                          INSTALLED **and** rc 0. The pre-fix code printed INSTALLED and then exited 2
#                          claiming "the push is NOT gated by this install" over a hook that was armed and
#                          correct — the operator told the opposite of the state on disk (review F3).
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
# falls back to 14400 / 43200 (9600 before agent-infra#4034) on an empty or unparseable value.
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

echo "== 6. scope is by KIND: the trunk is skipped even when it IS claimed, and nothing else is"
# ⛔ THE SUBJECT OF THIS CASE CHANGED TWICE, AND BOTH CHANGES ARE THE POINT.
#   #3696 replaced `refs/heads/fix/whatever` (which the prefix list then covered) with a prefix outside
#   the list. #4260 removed the prefix list itself: the gate now covers EVERY branch a lane can write
#   (#4260 §3a measured 6 of 10 open PRs on prefixes the list never inspected), so there is no longer
#   any LANE prefix that is out of scope. The only out-of-scope KIND left is the shared trunk — which is
#   exactly the boundary the new default must NOT swallow, and the one an over-broad gate would break
#   first: a claim on `main` would be a fleet-wide push block, not single-ownership.
# ⛔ AND THE FALSE-PASS TRAP THIS CASE HAS FALLEN INTO BEFORE IS CLOSED THE SAME WAY: a `hook-ref` that
# answers 0 proves nothing unless the same subject WOULD be refused by `guard`, so the control line
# below is part of the case rather than decoration.
commit_in stray "feature"
if push_in stray "refs/heads/chore/whatever" "$T/p6.err"; then
  ok "an ordinary unclaimed branch pushes freely (no over-block from the wider scope)"
else
  bad "an unclaimed ordinary branch was refused: $(cat "$T/p6.err")"
fi
acquire_from owner main
 eq "fixture: the TRUNK is CLAIMED before the scope reads it" "$?" "0"
guard_from stray main
eq "the guard DOES refuse the trunk — so rc 0 below is the scope's doing, not an unarmed claim" "$?" "1"
( cd "$T/stray" && "$BC" hook-ref refs/heads/main >/dev/null 2>&1 ); _rc6=$?
case "$_rc6" in
  0) ok "hook-ref SKIPS the CLAIMED trunk (the exclusion is by kind, before any registry read)" ;;
  *) bad "hook-ref gated the trunk (rc=$_rc6) — a claim on main would block every push in the fleet" ;;
esac
release_from owner main >/dev/null 2>&1
# ⛔ AND THE IN-SCOPE HALF AT A NAME THE OLD LIST DID NOT CARRY: with `*` as the default, a lane prefix
# that has never been seen before must be gated, and an unclaimed branch of it must still push. Case 14
# runs this for six prefixes; this arm is the one that fails if the default is ever narrowed again.
commit_in stray "new-prefix push"
( cd "$T/stray" && git push -q origin "HEAD:refs/heads/chore/whatever" ) || bad "fixture: cannot push chore/whatever unclaimed"
acquire_from owner "chore/whatever"
eq "6) fixture: the claim on a never-before-seen prefix is HELD (acquire is pattern-independent)" "$?" "0"
# ⛔ THE SCOPE ARM MUST RUN THE COMMAND THAT CONSULTS THE SCOPE (review P2, rule 3 — this REPLACED an
# arm that could not vary). `acquire`/`guard` never read `BRANCH_CLAIM_PATTERN` or
# `BRANCH_CLAIM_EXCLUDE_PATTERN`: `cmd_hook_ref` is the only caller of `branch_in_scope`, so an arm
# phrased through `acquire`/`guard` stayed GREEN under the pre-#4260 three-prefix default AND with
# `branch_in_scope` deleted outright — it measured `claim_branch_guard` refusing a peer, which was true
# under every scope, under a label that claimed "by KIND, not because it was on a list". These two go
# through `hook-ref` (the path the installed hook takes), and the SECOND one is the mutant that makes
# the first attributable: the same subject under the old default must NOT be refused — which is exactly
# the ungated `feat/*` push #4260 measured.
( cd "$T/stray" && "$BC" hook-ref refs/heads/chore/whatever >/dev/null 2>&1 ); _rc6p=$?
case "$_rc6p" in
  1) ok "6) hook-ref REFUSES a peer on a NEW prefix — in scope by KIND, not because it was on a list" ;;
  *) bad "6) hook-ref on a peer-claimed chore/whatever said rc=$_rc6p (want 1) — the default scope was narrowed, so the gate does not cover every branch a lane writes" ;;
esac
( cd "$T/stray" && BRANCH_CLAIM_PATTERN='integration/* fix/* rescue/*' "$BC" hook-ref refs/heads/chore/whatever >/dev/null 2>&1 ); _rc6q=$?
case "$_rc6q" in
  0) ok "6) …and under the PRE-#4260 three-prefix default the same peer push is ALLOWED — so the arm above measures the scope, not the guard" ;;
  *) bad "6) the pre-#4260 pattern also refused chore/whatever (rc=$_rc6q), so the arm above cannot be attributed to the scope" ;;
esac
release_from owner "chore/whatever" >/dev/null 2>&1

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
  # 1800, 14400 and 43200 are 1000 s+ apart.
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
# so — not to CLAIM_TTL_MAX (43200 since agent-infra#4034; 9600 before it, when a clamp to it shredded
# 33 % of a batch's term, 14400 -> 9600). The separation is this keying's own ceiling, not an ordering:
# the arm stays load-bearing at any CLAIM_TTL_MAX value, which is what makes it safe to have moved the
# ceiling past this term.
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
# names are wrong (43200 / 48000 since agent-infra#4034; 9600 / 18000 then), so a fixer was sent to raise a knob that is not the ceiling. Two
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
if [ -n "$L2" ]; then lease_arm "an over-ceiling request clamps to CLAIM_BRANCH_TTL (14400), NOT to CLAIM_TTL_MAX (43200 since agent-infra#4034)" 14400 "$L2"; else bad "no lease_until on the over-ceiling claim ref"; fi
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

echo "== 11. a PR BRANCH is gated too — the #3696 loss, on the branch a fixer actually pushes"
# ⛔ THE LOSS THIS CASE PINS, MEASURED (issue #3696, tortoise PR #11385, 2026-11-07): two lanes wrote
# one PR for ~6 h — 11 superseded heads, 5 clean reviews on 5 different heads, **0 landings** — because
# every push superseded the other lane's head-bound review attestation. #3328 built this exact
# single-owner mechanism for BATCH branches and stopped the identical loss there; the PR branch a FIXER
# pushes was simply outside the guard's `integration/*` scope, so the mechanism existed and did not
# cover the branch the loss actually happened on.
# ⛔ IT IS TWO ARMS, AND THE FIRST ONE IS THE ONE THAT MATTERS: widening a scope must never turn into
# "the guard refuses lanes that never heard of it". An UNCLAIMED branch of an in-scope name still
# pushes freely (case 1's polarity, restated at the new name), and only a STRAY push on top of a LIVE
# claim is refused. Reverting the scope to `integration/*` reddens the second arm and nothing else.
PRBR="fix/3696-claims-block-push"; PRBR_REF="refs/heads/$PRBR"
RESBR="rescue/3696-claims"; RESBR_REF="refs/heads/$RESBR"
# Seeded from the STRAY's head, deliberately: the arms below push from `stray`, so its commit must be
# a FAST-FORWARD of the seeded tip. Seeding from `owner` made the first arm fail on a non-fast-forward
# rejection — a fixture artefact that looks exactly like a guard refusal, and which would have made the
# case pass or fail for a reason no reader could see.
( cd "$T/stray" && git push -q origin "HEAD:$PRBR_REF" && git push -q origin "HEAD:$RESBR_REF" ) \
  || bad "fixture: cannot seed the PR/rescue branches"
commit_in stray "unclaimed PR-branch push"
if push_in stray "$PRBR_REF" "$T/p11a.err"; then
  ok "an UNCLAIMED PR branch pushes freely — widening the scope is not over-block"
else
  bad "an unclaimed PR branch was refused ($(cat "$T/p11a.err")) — its branch lease was released, so the only in-scope reason to refuse is scope, and a false block here is what gets a gate deleted"
fi
acquire_from owner "$PRBR"; eq "owner acquires the PR-BRANCH claim" "$?" "0"
OWNER_PR_HEAD="$(cd "$T/origin.git" && git rev-parse "$PRBR")"
commit_in stray "STRAY push onto an owned PR branch"
if push_in stray "$PRBR_REF" "$T/p11b.err"; then
  bad "the STRAY PR-branch push SUCCEEDED — a peer can still write on top of an owned head (#3696's whole failure)"
else
  ok "a stray push onto an OWNED PR branch is REFUSED"
fi
grep -q 'branch-claim: REFUSED' "$T/p11b.err" && ok "the PR-branch refusal names itself" \
  || bad "refusal text: $(cat "$T/p11b.err")"
grep -q 'held-by-live' "$T/p11b.err" && ok "...and says a live owner holds it (the peer can be told who)" \
  || bad "no held-by-live reason in: $(cat "$T/p11b.err")"
eq "the PR branch did NOT move (=> no head superseded, no attestation invalidated)" \
   "$(cd "$T/origin.git" && git rev-parse "$PRBR")" "$OWNER_PR_HEAD"
# rescue/* is the same class of writer (a rescue lane pushes a branch for a PR it does not own).
( cd "$T/owner" && CLAIM_REPO="$T/owner" "$BC" acquire "$RESBR" >/dev/null 2>&1 ) \
  || bad "fixture: cannot claim the rescue branch"
( cd "$T/stray" && "$BC" hook-ref "$RESBR_REF" >/dev/null 2>&1 )
eq "the scope covers rescue/* — a stray push on an OWNED rescue branch is refused" "$?" "1"


echo "== 12. the scope list is NOT pathname-expanded (review P2, MEASURED fail-open)"
# ⛔ `for pat in $BRANCH_CLAIM_PATTERN` runs the list through word-splitting AND pathname expansion, so a
# checkout containing a top-level `integration/` (or `fix/`) DIRECTORY rewrote the patterns into that
# directory's entries — measured `PAT=[integration/sub]` instead of `integration/*` — after which no
# branch matched and the gate refused nothing. It fails OPEN, silently, for exactly the branch class the
# gate exists to refuse. `set -f` in `branch_matches_pattern` is the fix; this arm is its detector, and
# it must be run from a checkout that HAS such a directory (the hook always runs from the repo root, so
# this is the real posture, not a contrived one).
GLOBBR="integration/globscope-3696"; GLOBREF="refs/heads/$GLOBBR"
( cd "$T/stray" && git push -q origin "HEAD:$GLOBREF" && mkdir -p integration && : > integration/sub ) \
  || bad "fixture: cannot seed the glob-scope branch/directory"
acquire_from owner "$GLOBBR"; eq "owner acquires the glob-scope branch" "$?" "0"
( cd "$T/stray" && "$BC" hook-ref "$GLOBREF" >/dev/null 2>&1 )
eq "a checkout with an \`integration/\` DIR still gates that branch (the list is not glob-expanded)" "$?" "1"

echo "== 13. branch_matches_pattern RESTORES the caller's \`-f\` (review F3: the restore had no mutant)"
# ⛔ THE SCOPE FIX IS `set -f` INSIDE `branch_matches_pattern`, AND ITS PRIMARY TOOTH IS CASE 12 ABOVE.
# The RESTORE half — the `_had_f` capture and the `[ "$_had_f" -eq 0 ] && set +f` on both exits — was
# pinned by NOTHING: a mutant that never restores `-f`, or one that unconditionally clears it over a
# caller who had it, reddened no arm in either suite (agent-infra#3442 rule 1: a new guard with no
# mutant reads to the next reader as covered). It is inert in the SHIPPED process (\`cmd_hook_ref\` does
# no globbing afterwards and the script exits), which is exactly why it needed a pin rather than an
# argument: an unconditional \`set +f\` would re-enable pathname expansion in a caller's shell — this
# gate's own fail-open class.
BM="$T/bmp.sh"
sed -n '/^branch_matches_pattern() {/,/^}/p' "$BC" > "$BM"
[ -s "$BM" ] && ok "13) branch_matches_pattern is extractable for a same-shell \`\$-\` observation" \
  || bad "13) cannot extract branch_matches_pattern from $BC"
# run_bmp <fn-file> <caller-had--f:0|1> <branch> → "<rc>:<-f-after>" measured in ONE shell, because the
# property is about the caller's options and a subshell boundary would hide the leak it exists to catch.
run_bmp() {
  local fn="$1" hadf="$2" br="$3"
  ( set +f
    [ "$hadf" = 1 ] && set -f
    BRANCH_CLAIM_PATTERN='integration/* fix/*'
    . "$fn"
    branch_matches_pattern "$br"; _rc=$?
    case "$-" in *f*) _f=1 ;; *) _f=0 ;; esac
    printf '%s:%s\n' "$_rc" "$_f"
  )
}
eq "13) a caller WITHOUT -f gets it back OFF after a MATCH (the function does not leak -f)" \
   "$(run_bmp "$BM" 0 integration/x)" "0:0"
eq "...and after a NON-match, so BOTH exits restore" \
   "$(run_bmp "$BM" 0 chore/x)" "1:0"
eq "...and -f the CALLER already had is PRESERVED, not cleared over it" \
   "$(run_bmp "$BM" 1 integration/x)" "0:1"
eq "...on the non-match exit too" \
   "$(run_bmp "$BM" 1 chore/x)" "1:1"
# ⛔ AN EXPLICITLY EMPTY LIST MUST MEAN EMPTY, NOT "FALL BACK TO THE INCLUDE LIST" (review P2, same
# source, unreachable today only because the exclude default above uses `:-`). With `${2:-…}` an empty
# argument resolved to `$BRANCH_CLAIM_PATTERN` — `*` — which matches every branch, so `branch_in_scope`
# answered "out of scope" for the whole TREE and the gate refused nothing, silently, from one exported
# variable. Both directions are measured: the shipped function must NOT match, and the pre-fix default
# must. (`empty_list_rc` prints the rc from a same-shell subshell, as `run_bmp` does.)
empty_list_rc() { ( set +f; BRANCH_CLAIM_PATTERN='*'; . "$1"; branch_matches_pattern "$2" "" >/dev/null 2>&1; printf '%s' "$?" ); }
eq "13) an EXPLICIT EMPTY list matches NOTHING (empty means empty, never the include list)" \
   "$(empty_list_rc "$BM" chore/x)" "1"
sed 's|list="${2-\$BRANCH_CLAIM_PATTERN}"|list="${2:-\$BRANCH_CLAIM_PATTERN}"|' "$BM" > "$T/bmp-emptylist.sh"
if cmp -s "$BM" "$T/bmp-emptylist.sh"; then
  bad "13) the empty-list mutant is IDENTICAL — the default was not found to change, so the arm above is unpinned"
else
  eq "13) …and under the PRE-FIX colon-dash default the same empty list matches EVERYTHING — so the arm measures it" \
     "$(empty_list_rc "$T/bmp-emptylist.sh" chore/x)" "0"
fi
# the mutant: delete BOTH restores. The function then leaks `set -f` into its caller, and row 1 reddens.
sed 's|\[ "$_had_f" -eq 0 \] && set +f|:|' "$BM" > "$T/bmp-norestore.sh"
if cmp -s "$BM" "$T/bmp-norestore.sh"; then
  bad "13) the mutant is IDENTICAL — the restore was not found to delete, so the rows above cannot be attributed to it"
else
  bash -n "$T/bmp-norestore.sh" && ok "13) the mutant is still a VALID program" || bad "13) the mutant does not parse"
  eq "13) with the restores deleted the caller's -f LEAKS — so the rows above measure the restore" \
     "$(run_bmp "$T/bmp-norestore.sh" 0 integration/x)" "0:1"
  # the other direction: never CAPTURE, so it always clears. A caller that had -f loses it.
  sed 's|_had_f=1 ;;|_had_f=0 ;;|' "$BM" > "$T/bmp-alwaysclear.sh"
  if cmp -s "$BM" "$T/bmp-alwaysclear.sh"; then
    bad "13) the always-clear mutant is IDENTICAL — the capture was not found to defuse"
  else
    bash -n "$T/bmp-alwaysclear.sh" && ok "13) the always-clear mutant is still a VALID program" \
      || bad "13) the always-clear mutant does not parse"
    eq "13) a function that never CAPTURES clears a caller's -f — so the capture is measured too" \
       "$(run_bmp "$T/bmp-alwaysclear.sh" 1 integration/x)" "0:0"
  fi
fi

echo "== 14. EVERY in-scope prefix, BOTH directions — the scope is by KIND, not by a list of names"
# ⛔ WHY THIS CASE EXISTS (agent-infra#4260). Case 11 pins `fix/*` and `rescue/*`; the measured
# population had 6 of 10 open PRs on `feat/*` and `pr-go/*`, which the old allOWLIST
# (`integration/* fix/* rescue/*`) never inspected. Widening the list to those two names would
# reproduce the defect at the next new prefix, so the default is now INCLUDE-EVERYTHING and only the
# trunk names are excluded — and that is what these arms measure: for EVERY prefix a lane writes, an
# UNCLAIMED branch pushes freely and a PEER-CLAIMED branch is refused.
# ⛔ THE SECOND HOLDER IS REAL, NOT SIMULATED. `stray` is a separate clone with its own installed hook
# and no fencing token — the same shape as a second cell pushing a branch it does not own. A test that
# "simulated" the peer (by skipping the hook, or by hand-editing the token) would prove nothing about
# the boundary, which is precisely the failure #4260's acceptance criteria call out.
# ⛔ AND THE TRUNK IS THE CONTROL. `main` is excluded BY KIND, so even a CLAIMED `main` is not refused
# here: a claim on the trunk would be a fleet-wide push block, not single-ownership. Without this arm a
# scope that had swallowed the trunk would read as "thorough" instead of "an outage".
for _pfx in integration fix feat pr-go design scope; do
  BR="$_pfx/4260-scope-arm"; REF="refs/heads/$BR"
  # Seed from stray's head so every arm below is a fast-forward (a non-ff rejection looks exactly
  # like a guard refusal — the artefact case 11 records).
  ( cd "$T/stray" && git push -q origin "HEAD:$REF" ) || { bad "14) fixture: cannot seed $REF"; continue; }
  commit_in stray "unclaimed push on $BR"
  if push_in stray "$REF" "$T/p14a.err"; then
    ok "14) $BR — an UNCLAIMED branch pushes freely (no over-block)"
  else
    bad "14) $BR — an unclaimed branch was REFUSED: $(cat "$T/p14a.err")"
    continue
  fi
  acquire_from owner "$BR"; eq "14) $BR — owner acquires" "$?" "0"
  OWNED_HEAD="$(cd "$T/origin.git" && git rev-parse "$BR")"
  commit_in stray "STRAY push onto owned $BR"
  if push_in stray "$REF" "$T/p14b.err"; then
    bad "14) $BR — a PEER-CLAIMED branch was NOT refused (the guard does not cover this prefix)"
  else
    ok "14) $BR — a peer-claimed branch is REFUSED"
  fi
  grep -q 'branch-claim: REFUSED' "$T/p14b.err" 2>/dev/null \
    && ok "14) $BR — the refusal names itself" \
    || bad "14) $BR — no branch-claim refusal line: $(cat "$T/p14b.err" 2>/dev/null)"
  eq "14) $BR — the branch did NOT move (no head superseded)" \
     "$(cd "$T/origin.git" && git rev-parse "$BR")" "$OWNED_HEAD"
  release_from owner "$BR" >/dev/null 2>&1
  ( cd "$T/origin.git" && git update-ref -d "$REF" ) 2>/dev/null || true
done
# the control: the trunk is OUT of scope even when claimed.
acquire_from owner main; eq "14) fixture: the trunk is CLAIMED" "$?" "0"
commit_in stray "trunk commit"
if push_in stray "refs/heads/main" "$T/p14c.err"; then
  ok "14) a CLAIMED trunk still pushes — the exclusion is by KIND, and a claim cannot block the fleet's main"
else
  bad "14) the scope swallowed main: $(cat "$T/p14c.err")"
fi
release_from owner main >/dev/null 2>&1

# ⛔ AND THE SAME KIND RULE MUST BE WHAT `check-hook` REPORTS, or the verifier can pass while the gate
# is narrower than the verifier believes (a false PASS of exactly the class #4260 exists for).
check_in() { ( cd "$T/$1" && "$BC" check-hook 2>/dev/null ); }
_c14="$(check_in owner)"; eq "14) check-hook PASSES in an installed checkout" "$?" "0"
case "$_c14" in HOOK-OK*) ok "14) ...and prints HOOK-OK with the gate path" ;; *) bad "14) check-hook verdict: $_c14" ;; esac

# ── 15. check-hook NAMES THE BOX AND THE FAULT (#4260 §4.2: prove a FAILING box, not only a passing one)
# ⛔ "INSTALLED ONCE AND HOPING" IS THE MEASURED DEFECT: the hook was present, executable, resolvable
# and syntax-clean on ONE cell of five, and nothing could say so. So the verifier is exercised against a
# box that FAILS, in each of the three shapes that matter, and the verdict must NAME the host and the
# fault — a bare non-zero rc is the abstention this instrument exists to replace.
git clone -q "$T/origin.git" "$T/nohook" 2>/dev/null || bad "15) fixture: cannot clone nohook"
_n15="$(check_in nohook)"; _r15=$?
case "$_r15" in 1) ok "15) a box with NO hook FAILS check-hook (rc 1, not an abstention)" ;; *) bad "15) no-hook rc=$_r15 (want 1): $_n15" ;; esac
case "$_n15" in HOOK-FAIL*MISSING*) ok "15) ...and the verdict NAMES the fault (MISSING)" ;; *) bad "15) verdict does not name MISSING: $_n15" ;; esac
case "$_n15" in *"$(hostname 2>/dev/null || uname -n)"*) ok "15) ...and NAMES THE BOX (so a fleet run can say which cell is unarmed)" ;; *) bad "15) verdict names no host: $_n15" ;; esac
# the shape a present-and-executable check calls GREEN and which refuses every push on the box:
( cd "$T/nohook" && "$BC" install-hook >/dev/null 2>&1 ) || bad "15) fixture: install-hook in nohook"
_n15b="$(check_in nohook)"; eq "15) ...and the same box PASSES once the hook is installed" "$?" "0"
case "$_n15b" in HOOK-OK*) ok "15) ...printing HOOK-OK" ;; *) bad "15) after install: $_n15b" ;; esac
sed 's|^bc="${BRANCH_CLAIM_BIN:-.*}"$|bc="${BRANCH_CLAIM_BIN:-/nonexistent/4260/branch-claim.sh}"|' "$T/nohook/.git/hooks/pre-push" > "$T/nohook/.git/hooks/pre-push.new" \
  && cat "$T/nohook/.git/hooks/pre-push.new" > "$T/nohook/.git/hooks/pre-push" \
  && rm -f "$T/nohook/.git/hooks/pre-push.new"
_n15c="$(check_in nohook)"; _r15c=$?
case "$_r15c" in 1) ok "15) a hook whose BAKED GATE PATH is gone FAILS (rc 1)" ;; *) bad "15) gone-gate rc=$_r15c (want 1): $_n15c" ;; esac
case "$_n15c" in *GATE-ABSENT*) ok "15) ...naming GATE-ABSENT (the shape that would refuse EVERY push on that box)" ;; *) bad "15) verdict: $_n15c" ;; esac
chmod -x "$T/nohook/.git/hooks/pre-push"
_n15d="$( ( cd "$T/nohook" && "$BC" check-hook 2>/dev/null ) )"; _r15d=$?
case "$_r15d" in 1) ok "15) a NON-EXECUTABLE hook FAILS (git runs no non-executable hook: inert while looking installed)" ;; *) bad "15) non-exec rc=$_r15d: $_n15d" ;; esac
case "$_n15d" in *NOT-EXECUTABLE*) ok "15) ...naming NOT-EXECUTABLE" ;; *) bad "15) verdict: $_n15d" ;; esac
# cannot-verify is its own answer, and it is NOT a pass.
_n15e="$( cd "$T" && "$BC" check-hook 2>/dev/null )"; _r15e=$?
case "$_r15e" in 2) ok "15) outside any work tree the answer is CANNOT-VERIFY (rc 2), never a pass" ;; *) bad "15) not-a-tree rc=$_r15e: $_n15e" ;; esac
# ⛔ NO `bash` ON PATH IS AN ABSTENTION, NOT A SYNTAX FAULT (review round 1, finding 8; the rc
# vocabulary documented above already reserved rc 2 for this and the code did not have the arm). The
# fixture is the decisive one: a PATH carrying every program the verifier needs EXCEPT the interpreter.
# Without the arm `bash -n` is "command not found", the `!` inverts that into a pass, and a PERFECTLY
# GOOD hook is reported `SYNTAX` at rc 1 (measured) — the verifier asserting a fault in an artifact it
# never read. `$T/nohook` is the subject because it HAS an installed hook (its `-x` bit is restored
# first), so a pre-fix run cannot stop at MISSING or NOT-EXECUTABLE instead.
chmod +x "$T/nohook/.git/hooks/pre-push" 2>/dev/null
BASH_ABS="$(command -v bash)"
mkdir -p "$T/minbin"
for _t in git dirname grep sed cmp mktemp head hostname uname cat rm chmod awk; do
  _p="$(command -v "$_t" 2>/dev/null)" && [ -n "$_p" ] && ln -sf "$_p" "$T/minbin/$_t"
done
[ -e "$T/minbin/bash" ] && bad "15) fixture: minbin carries bash, so the arm below would prove nothing"
_n15f="$( ( cd "$T/nohook" && env PATH="$T/minbin" "$BASH_ABS" "$BC" check-hook 2>/dev/null ) )"; _r15f=$?
case "$_r15f" in
  2) ok "15) with no bash on PATH the answer is CANNOT-VERIFY (rc 2), never a fault it cannot measure" ;;
  *) bad "15) no-bash rc=$_r15f (want 2): $_n15f" ;;
esac
case "$_n15f" in
  *"no bash"*) ok "15) …and it NAMES the missing interpreter (so nobody is sent to reinstall a correct hook)" ;;
  *) bad "15) the no-bash verdict names no interpreter: $_n15f" ;;
esac
# ⛔ AND PRESENT + RESOLVABLE IS NOT "THE CURRENT GENERATION" (review P1). Every arm above passes on a
# hook whose baked gate is an OLDER `branch-claim.sh` — the pre-#4260 `integration/* fix/* rescue/*`
# scope — which is the shape the doctor's row would have reported as `armed`, about a box whose `feat/*`
# pushes are still ungated. Four fixtures: (a) a REAL install from a byte-identical copy at another
# path, which is CURRENT and must stay green (a pin, a consumer repo's vendored tree); (b) the same
# copy one generation stale in its CONTENT at the SAME path as the copy, which must be named
# GATE-STALE; (c) an install from a pre-#3329 TEMPLATE, present, executable, ours, parseable and with a
# resolvable current gate, which must be named HOOK-STALE; (d) reinstall from this tree, green again, so
# none of the three reds came from the fixture.
git clone -q "$T/origin.git" "$T/gen" 2>/dev/null || bad "15) fixture: cannot clone gen"
GEN_HOOK="$T/gen/.git/hooks/pre-push"
gen_verdict() { ( cd "$T/gen" && "$BC" check-hook 2>/dev/null ); }
# (a) a REAL install from a byte-identical tree at a different path — the pin/consumer shape.
mkdir -p "$T/gen/copy"
cp "$BC" "$SELFDIR/claims.sh" "$SELFDIR/branch-claim-hook.sh" "$T/gen/copy/"
( cd "$T/gen" && CLAIM_REPO="$T/gen" bash "$T/gen/copy/branch-claim.sh" install-hook >/dev/null 2>&1 ) \
  || bad "15) fixture: install-hook from the copied tree failed"
_g15a="$(gen_verdict)"; _r15a=$?
case "$_r15a" in 0) ok "15) a hook installed from a BYTE-IDENTICAL copy at another path still verifies (a pin is not stale by PATH)" ;; *) bad "15) identical-copy rc=$_r15a (want 0) — a path compare leaked into the verdict: $_g15a" ;; esac
case "$_g15a" in *"gate=$T/gen/copy/branch-claim.sh"*) ok "15) …and the verdict names the gate that is actually installed" ;; *) bad "15) verdict does not name the installed gate: $_g15a" ;; esac
# (b) the same path, one generation older in its CONTENT: the pre-#4260 narrow scope.
sed 's|BRANCH_CLAIM_PATTERN="${BRANCH_CLAIM_PATTERN:-\*}"|BRANCH_CLAIM_PATTERN="${BRANCH_CLAIM_PATTERN:-integration/* fix/* rescue/*}"|' \
  "$BC" > "$T/gen/copy/branch-claim.sh.old"
if cmp -s "$BC" "$T/gen/copy/branch-claim.sh.old"; then
  bad "15) the stale-gate mutant is IDENTICAL — the default was not found, so the arm below is unpinned"
else
  cat "$T/gen/copy/branch-claim.sh.old" > "$T/gen/copy/branch-claim.sh"
  rm -f "$T/gen/copy/branch-claim.sh.old" "$GEN_HOOK"
  ( cd "$T/gen" && CLAIM_REPO="$T/gen" bash "$T/gen/copy/branch-claim.sh" install-hook >/dev/null 2>&1 ) \
    || bad "15) fixture: install-hook from the stale copy failed"
  _g15b="$(gen_verdict)"; _r15b=$?
  case "$_r15b" in 1) ok "15) an armed hook whose GATE is an older generation FAILS (rc 1) — present+resolvable+executable is not CURRENT" ;; *) bad "15) stale-gate rc=$_r15b (want 1): $_g15b" ;; esac
  case "$_g15b" in *GATE-STALE*) ok "15) …naming GATE-STALE (the box the old verifier reported as HOOK-OK and the fleet read as fixed)" ;; *) bad "15) verdict: $_g15b" ;; esac
fi
# (c) the pre-#3329 hook: present, executable, ours, parses, gate CURRENT — and validates no ref at all.
mkdir -p "$T/gen/oldtmpl"
cp "$BC" "$SELFDIR/claims.sh" "$T/gen/oldtmpl/"
awk '!done && $0=="set -u" { print; print "cat >/dev/null   # pre-#3329: consume the ref lines, replay none"; done=1; next } { print }' \
  "$SELFDIR/branch-claim-hook.sh" > "$T/gen/oldtmpl/branch-claim-hook.sh"
if cmp -s "$SELFDIR/branch-claim-hook.sh" "$T/gen/oldtmpl/branch-claim-hook.sh"; then
  bad "15) the stale-template mutant is IDENTICAL — the template was not found, so the arm below is unpinned"
else
  rm -f "$GEN_HOOK"
  ( cd "$T/gen" && CLAIM_REPO="$T/gen" bash "$T/gen/oldtmpl/branch-claim.sh" install-hook >/dev/null 2>&1 ) \
    || bad "15) fixture: install-hook from the old template failed"
  _g15c="$(gen_verdict)"; _r15c2=$?
  case "$_r15c2" in 1) ok "15) a hook from an OLDER TEMPLATE FAILS (rc 1) — the inert-while-looking-installed class, caught by content" ;; *) bad "15) stale-template rc=$_r15c2 (want 1): $_g15c" ;; esac
  case "$_g15c" in *HOOK-STALE*) ok "15) …naming HOOK-STALE" ;; *) bad "15) verdict: $_g15c" ;; esac
fi
# (d) control: reinstall from THIS tree and the same checkout verifies, so (b)/(c) measured the hooks.
rm -f "$GEN_HOOK"
( cd "$T/gen" && CLAIM_REPO="$T/gen" "$BC" install-hook >/dev/null 2>&1 ) || bad "15) fixture: reinstall in gen"
_g15d="$(gen_verdict)"; eq "15) …and the SAME checkout verifies again after a reinstall from this tree (so the two reds above are the hooks, not the fixture)" "$?" "0"

# ⛔ AND THE INSTALLER MUST NOT REPORT SUCCESS IT CANNOT VERIFY. `install-hook` calls the same
# verifier and DIES when the artifact does not answer. The fixture is a real one: a copy of the script
# beside a template whose `@BC@` placeholder is missing, so the hook it installs names a gate path that
# cannot resolve — the exact shape of a box whose harness moved. The SHIPPED script must refuse that
# install; a MUTANT with the verification line replaced by `true` installs it and exits 0. The
# difference between the two runs is the only thing that proves the line load-bearing.
BM2="$T/branch-claim-verify-mutant.sh"
sed 's|^  check_hook_report |  true |' "$BC" > "$BM2"
if cmp -s "$BC" "$BM2"; then
  bad "15) the install-verification mutant is IDENTICAL — the call was not found, so the shipped line is unpinned"
else
  bash -n "$BM2" && ok "15) the install-verification mutant still parses" || bad "15) the mutant does not parse"
  mkdir -p "$T/notmpl"
  cp "$BC" "$T/notmpl/branch-claim.sh" && chmod +x "$T/notmpl/branch-claim.sh"
  cp "$SELFDIR/claims.sh" "$T/notmpl/claims.sh"
  # ⛔ THE MUTANT MUST SHARE THE FIXTURE'S DIRECTORY, not sit beside the real script: it sources
  # `$SELF_DIR/claims.sh` and reads `$SELF_DIR/branch-claim-hook.sh`, so a mutant anywhere else dies on
  # `cannot load claims.sh` (rc 2) and the case would read that as "the mutant also refused" — a
  # fixture artefact masquerading as a measurement.
  cp "$BM2" "$T/notmpl/branch-claim-verify-mutant.sh" && chmod +x "$T/notmpl/branch-claim-verify-mutant.sh"
  BM2="$T/notmpl/branch-claim-verify-mutant.sh"
  # the template WITHOUT its @BC@ placeholder: install substitutes nothing, the hook's gate path stays
  # the literal `@BC@`, and a hook that cannot resolve its gate is the one that refuses every push.
  sed 's|@BC@||g' "$SELFDIR/branch-claim-hook.sh" > "$T/notmpl/branch-claim-hook.sh" \
    || bad "15) fixture: cannot build the template without its placeholder"
  git clone -q "$T/origin.git" "$T/verify-a" 2>/dev/null; git clone -q "$T/origin.git" "$T/verify-b" 2>/dev/null
  ( cd "$T/verify-a" && bash "$T/notmpl/branch-claim.sh" install-hook >"$T/va.out" 2>&1 ); _ra=$?
  ( cd "$T/verify-b" && bash "$BM2" install-hook >"$T/vb.out" 2>&1 ); _rb=$?
  case "$_ra" in
    0) bad "15) install-hook reported SUCCESS for a hook whose gate path cannot resolve: $(cat "$T/va.out")" ;;
    *) ok "15) install-hook REFUSES an install that does not VERIFY (rc=$_ra)" ;;
  esac
  case "$_ra:$_rb" in
    0:0|0:*) bad "15) BOTH runs failed/succeeded alike (shipped=$_ra mutant=$_rb) — the mutant does not differ, so the verification line is unpinned" ;;
    *:0) ok "15) the MUTANT accepts it (rc=0) — so the refusal above IS the verification, not the fixture" ;;
    *) bad "15) the mutant also refused (rc=$_rb): $(cat "$T/vb.out") — the fixture, not the verification, produced the refusal" ;;
  esac
fi

# ── 16. INSTALL-HOOK VERIFIES THE CHECKOUT IT WROTE TO (#4260 review F3)
# ⛔ EVERY OTHER install-hook ARM IN THIS SUITE AND IN THE TREE `cd`s INTO THE REPO FIRST, so none of
# them can see the disagreement this case pins: `cmd_install_hook` resolves its subject through
# `claim_repo_init` (cwd, ELSE the documented `CLAIM_REPO` fallback for "a controller that has already
# cd'd home, or a systemd timer"), while `check_hook_report` used to resolve its own subject from the
# PROCESS CWD. For that caller the two are DIFFERENT checkouts: the install wrote a correct hook, printed
# INSTALLED, and then exited 2 with "the push is NOT gated by this install" — a false FAIL on the one
# path the fallback exists for, and a bootstrap aborted over a hook that is armed.
echo "== 16. install-hook verifies the checkout it WROTE TO, not the caller's cwd"
git clone -q "$T/origin.git" "$T/f3repo" 2>/dev/null || bad "16) fixture: cannot clone f3repo"
mkdir -p "$T/outside" && rm -f "$T/f3repo/.git/hooks/pre-push"
( cd "$T/outside" && CLAIM_REPO="$T/f3repo" bash "$BC" install-hook >"$T/f3.out" 2>&1 ); _f3=$?
eq "16) install-hook from OUTSIDE any work tree, via the documented CLAIM_REPO fallback, exits 0" "$_f3" "0"
grep -qF "INSTALLED $T/f3repo/.git/hooks/pre-push" "$T/f3.out" 2>/dev/null \
  && ok "16) ...and names the hook it wrote (so the arm measured an install, not an early exit)" \
  || bad "16) no INSTALLED line naming the CLAIM_REPO hook: $(cat "$T/f3.out" 2>/dev/null)"
if [ -x "$T/f3repo/.git/hooks/pre-push" ]; then ok "16) ...and the hook is on disk, executable"
else bad "16) the hook is not executable at the CLAIM_REPO path"; fi
_f3v="$(check_in f3repo)"; _f3r=$?
case "$_f3r" in 0) ok "16) ...and the installed checkout verifies HOOK-OK (the install told the truth)" ;; *) bad "16) check-hook in f3repo rc=$_f3r: $_f3v" ;; esac
# ⛔ NON-VACUITY: revert exactly the fix (drop the subject argument, so the verifier resolves from the
# caller's cwd again) and the SAME arm must fail. Without this pair the green above could be produced by
# the fixture rather than by the argument.
mkdir -p "$T/f3mut"
sed 's|^  check_hook_report "$CLAIM_REPO" |  check_hook_report |' "$BC" > "$T/f3mut/branch-claim.sh"
if cmp -s "$BC" "$T/f3mut/branch-claim.sh"; then
  bad "16) the cwd-verifier mutant is IDENTICAL — the call was not found, so the fix is unpinned"
else
  cp "$SELFDIR/claims.sh" "$T/f3mut/claims.sh"
  cp "$SELFDIR/branch-claim-hook.sh" "$T/f3mut/branch-claim-hook.sh"
  chmod +x "$T/f3mut/branch-claim.sh"
  rm -f "$T/f3repo/.git/hooks/pre-push"
  ( cd "$T/outside" && CLAIM_REPO="$T/f3repo" bash "$T/f3mut/branch-claim.sh" install-hook >"$T/f3m.out" 2>&1 ); _f3m=$?
  case "$_f3m" in
    0) bad "16) the cwd-verifier MUTANT also succeeded — the fixture, not the fix, produced the green (and the F3 regression would be invisible)" ;;
    *) ok "16) the cwd-verifier MUTANT fails the same install (rc=$_f3m) — so the arm measures the subject argument" ;;
  esac
fi

echo
printf 'branch-claim.test.sh: %d passed, %d failed\n' "$PASSES" "$FAILS"
[ "$FAILS" -eq 0 ] || exit 1
