#!/usr/bin/env bash
# fix-one-branchclaim.test.sh — a FIXER must take the coarser BRANCH claim before it works, a peer that
# already owns the branch must be refused BEFORE any head is pushed on top of its work, and the claim it
# takes must be one its OWN push can pass (agent-infra#3696, P0).
#
# THE MEASURED FAILURE (tortoise PR #11385, 2026-11-07, ~6 h of two lanes' wall clock):
#   lane A took `refs/claims/11385-a51050d7b`, measured the head, started a fix round
#   lane B pushed `93b85f33d` — A's review of `a51050d7b` was invalidated
#   … ten more heads over the next five hours; five fresh reviews returned clean on five DIFFERENT
#   heads, and the PR produced **11 superseded heads and 0 landings**.
# Neither lane was idle and neither misreported itself. The per-head claim cannot express this loss:
# it is keyed `<PR>-<head12>`, and the writer that caused it **creates a new head**, so it takes a
# fresh key and wins its own CAS every single time. The question the incident needed is coarser —
# *does another lane own this BRANCH right now?* — which is `refs/claims/branch-<slug>`, the key and
# CAS #3328 already built for batch branches.
#
# WHAT IS PINNED — arms 0–5 and C/R/T drive the SHIPPED block, extracted from fix-one.sh between its
# `[fixgate-branchclaim:…]` markers, never a re-typed copy of the rule. Arm E composes the SHIPPED
# pieces against a REAL git fixture, because that is the composition that ships:
#   0  the block is extractable (the PRE-FIX code has no markers, so this FAILS instead of passing
#      vacuously), fix-one.sh still parses, the extracted block parses on its own, and the block sits
#      BEFORE the per-head `claim_acquire` call — coarse-to-fine, the order merge-one.sh uses for its
#      own keys. A block that ran after it would refuse a peer only once this box had booked the head.
#   1  a PEER holds the branch (rc=1) → refuse, write the HEAD-KEYED `fixbail-<PR>-<head>` marker the
#      controller's refund reads, and exit 0 WITHOUT attempting the head claim. That last clause is the
#      incident: a lane that bails must not also stamp ownership on a head.
#   2  the claim is acquired (rc=0) → `BRANCH_OWN` carries the claim commit (the EXIT trap can release
#      it) AND the FENCING TOKEN is written for the worktree — see arm E for why that is not optional.
#   2b no worktree path → no token, and the log says so rather than leaving a silent hole.
#   3  the registry is UNREADABLE (rc=2) → proceed and say so. The over-block arm: an abstention is not
#      a refusal, and the per-head CAS is still the backstop.
#   4  a claims.sh that PREDATES #3328 (no `claim_branch_acquire`) → proceed, and NAME it in the log.
#   5  the acquire is made with NO ttl argument, so the BRANCH key's own term governs — see the arm's
#      own note: this is the KEY'S ceiling, and the residual that it is shorter than the lane bound is
#      stated in fix-one.sh rather than papered over by a per-dispatch clamp warning.
#   C  rc=1 with `held-by-unreadable-clock` is NOT reported as a peer (claims.sh mints rc 1 for a broken
#      clock on purpose, so a caller that assumes "a peer owns it" blames nobody who exists).
#   R  `release_branch_claim` fences the CAS on (REPO, BR, claim commit) and DELETES the token, and the
#      EXIT trap actually calls it. Both were unpinned: deleting `; release_branch_claim` from the trap
#      left every other arm green, and a stranded branch claim refuses every peer fixer until it expires.
#   R2 a FAILED fenced release KEEPS the token (the claim is still ours; it is the only possession proof),
#      with a mutant deleting the `[ "$rc" -eq 0 ]` guard — the detector cycle-3 review F1 found missing.
#   T  the trap line names it.
#   E  END TO END, the composition that ships: REAL `claims.sh`, REAL `branch-claim.sh install-hook`, the
#      block's own acquire, then a real `git push` from the worktree. It must SUCCEED as `held-by-you`.
#      ⛔ THIS ARM IS THE P0 REGRESSION TEST. The library `claim_branch_acquire` does NOT write the token
#      (`claim_branch_record`'s only caller in the tree is `branch-claim.sh`'s `cmd_acquire`, which the
#      fixer does not go through), and the guard decides by POSSESSION — so before this arm existed, a
#      correct acquire was REFUSED `held-by-live` by the fixer's own claim, which is the "a gate that
#      refuses its owner gets deleted within a day" failure. Each half was green in isolation: the unit
#      arms stub the acquire, and `branch-claim.test.sh` acquires through the CLI that writes the token.
#   M  the MUTANT: with the bail-marker write deleted from a doctored copy of the SAME block, arm 1's
#      marker assertion fails — so arm 1 measures the block and not the fixture.
#
# Run: bash scripts/orchestrator-harness/fix-one-branchclaim.test.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
FIXER="$HERE/fix-one.sh"
BC="$HERE/branch-claim.sh"
[ -r "$FIXER" ] || { echo "FATAL: fix-one.sh not found beside this test ($FIXER)" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/fix-one-branchclaim.XXXXXX")" || { echo "FATAL: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$T"' EXIT
pass=0 fail=0
ok()  { printf '  ✅ %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  ❌ %s\n' "$1"; fail=$((fail+1)); }
ck()  { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi; }

# ── 0. extract the SHIPPED pieces ──────────────────────────────────────────────────────────────
sed -n '/\[fixgate-branchclaim:begin\]/,/\[fixgate-branchclaim:end\]/p' "$FIXER" > "$T/branchclaim.sh"
if [ ! -s "$T/branchclaim.sh" ]; then
  bad "0) the branch-claim block is EMPTY — fix-one.sh has no [fixgate-branchclaim] markers, so every arm below would pass vacuously"
  echo "───────────────────────────────────────────────────────────────────"
  echo "❌ fix-one branch-claim suite: the block is not extractable — refusing to run arm 1+"
  exit 1
fi
# ⛔ THE STATUS IS CAPTURED BEFORE THE MESSAGE IS BUILT (review F4, MEASURED FALSE PASS). The message's
# `$(wc -l … | tr …)` runs BEFORE a later word's `$?` is expanded, and `$?` is "the most recently
# executed command" (GNU Bash manual §3.4.2) — so a bare `$?` here delivered the `wc|tr` status, which is
# 0 whenever the block file is readable (and `:71-76` already exits 1 if it is not). Measured: with a
# FAILING grep this arm still printed a green ✅. The "calls claim_branch_acquire" half was asserted
# nowhere. Capture first, print second — the same rule as arm 2's token check below.
# ⛔ AND THE PATTERN MATCHES THE **CALL**, NOT ANY MENTION (review F4's second half): a bare
# `grep -qF claim_branch_acquire` is satisfied by the block's own `echo "… defines no
# claim_branch_acquire …"` prose, so it stayed green with the call deleted — the prose-vs-code confusion
# this file strips comments for at arm M. Anchoring on the first token asserts the call itself.
grep -qE '^[[:space:]]*claim_branch_acquire[[:space:]]' "$T/branchclaim.sh"; _acq_rc=$?
ck "0) the block is extractable and calls claim_branch_acquire ($(wc -l < "$T/branchclaim.sh" | tr -d ' ') lines)" "$_acq_rc"
bash -n "$FIXER"; ck "0) fix-one.sh still parses" $?
# The braces are part of the extracted program, not decoration: a block whose `if`/`fi` moved would
# otherwise be sourced as a truncated statement and fail for a reason unrelated to the rule.
bash -n "$T/branchclaim.sh"; ck "0) the extracted block parses on its own" $?

# ── ORDER: the branch claim must be taken BEFORE the per-head one ────────────────────────────
_setting_line="$(grep -n '\[fixgate-branchclaim:begin\]' "$FIXER" | head -1 | cut -d: -f1)"
_head_line="$(grep -n '^  claim_acquire "\$REPO" "\$PR" "\$HEAD"' "$FIXER" | head -1 | cut -d: -f1)"
if [ -n "$_setting_line" ] && [ -n "$_head_line" ] && [ "$_setting_line" -lt "$_head_line" ]; then
  ok "0) the BRANCH claim is taken before the per-head claim ($_setting_line < $_head_line) — coarse to fine"
else
  bad "0) the branch claim does not precede the per-head claim (branch=$_setting_line head=$_head_line) — a peer would be refused only after this box booked the head"
fi

# ── the driver (arms 1–5, C) ──────────────────────────────────────────────────────────────────
# run_block <block-file> <claim-rc> <claim-result> [has-acquire:0|1] [wt:path|none]
#   → $T/run/{rc,calls,branchown,token,fenced} + $T/run/o/state/fixbail-* + $T/run/o/logs/fix-3696.log
run_block() {
  local block="$1" rc="$2" res="$3" has="${4:-1}" wt="${5:-$T/run/wt}" d="$T/run"
  rm -rf "$d"; mkdir -p "$d/o/state" "$d/o/logs" "$d/wt"
  (
    set -u
    O="$d/o"; L="$d/o/logs/fix-3696"; PR=3696
    REPO=/repo; BR=fix/3696-claims-block-push
    HEAD=abc123def4567890abc123def4567890abc12345
    BRANCH_OWN=""; BRANCH_TOKEN=""
    [ "$wt" = none ] && unset WT || WT="$d/wt"
    : > "$L"
    CALLS="$d/calls"; : > "$CALLS"
    if [ "$has" = 1 ]; then
      # ⛔ THE STUB RECORDS ITS THIRD ARGUMENT, because arm 5 is about the TERM. A stub that swallowed
      # the ttl could not tell "no ttl given" from "the fixer's 10 h head-claim lease handed over".
      claim_branch_acquire() {
        printf 'branch_acquire repo=%s branch=%s ttl=%s\n' "${1-}" "${2-}" "${3-<none>}" >> "$CALLS"
        CLAIM_RESULT="$res"; CLAIM_COMMIT=deadbeefcafebabe; return "$rc"
      }
    fi
    # The token seams, stubbed so arm 2 can see whether the block WROTE one and where. Arm E exercises
    # the real ones; these two must therefore mirror the real signatures, not an invented one.
    # ⛔ MIRRORS THE REAL SHAPE, NOT A CONVENIENT ONE (cycle-2 review F5): `claim_branch_token_path`
    # prints `<gitdir>/branchclaim-<claim_branch_key>` — ONE path segment, `<gitdir>/branchclaim-branch-fix-e2e`
    # (arm E prints exactly that). The first stub printed `<dir>/branchclaim-fix/3696-...`, a DIRECTORY
    # plus a file that the library can never produce, so arm 2 pinned a shape that survived a format change.
    claim_branch_token_path() { printf '%s/branchclaim-branch-%s' "${2:-/nodir}" "$(printf '%s' "$1" | sed -e 's#[^A-Za-z0-9._-]#-#g' -e 's#--*#-#g')"; }
    claim_branch_record() {
      mkdir -p "$(dirname -- "${1:?}")" 2>/dev/null || return 1
      printf '%s\n%s\n' "${2-}" "${3-}" > "$1" || return 1
      printf '%s' "$1"
    }
    git() { printf '%s\n' "$d/gitdir"; }
    # The per-head CAS this block must PRECEDE. It records rather than decides: the block under test
    # is what may skip it.
    claim_acquire() {
      printf 'head_acquire repo=%s pr=%s head=%s\n' "${1-}" "${2-}" "${3-}" >> "$CALLS"
      CLAIM_RESULT=acquired; CLAIM_COMMIT=feedfacefeedface; return 0
    }
    . "$block" >/dev/null 2>&1
    # Reached only when the block did NOT exit (acquired / unreadable / legacy).
    claim_acquire "$REPO" "$PR" "$HEAD"
    printf '%s\n' "${BRANCH_OWN-__unset__}" > "$d/branchown"
    printf '%s\n' "${BRANCH_TOKEN-__unset__}" > "$d/token"
  )
  printf '%s\n' "$?" > "$d/rc"
}

# 1. a PEER owns the branch — the incident
run_block "$T/branchclaim.sh" 1 'branch-claim: REFUSED branch=fix/3696-claims-block-push holder=peerbox:4242 reason=held-by-live'
ck "1) a peer-owned branch is REFUSED with a clean exit (rc=$(cat "$T/run/rc"))" \
   "$([ "$(cat "$T/run/rc")" = 0 ] && echo 0 || echo 1)"
grep -qF 'single-owner branch claim REFUSED' "$T/run/o/logs/fix-3696.log"
ck "1) the log names the refusal and the peer" $?
grep -qF 'agent-infra#3696' "$T/run/o/logs/fix-3696.log"
ck "1) the log names the loss it prevented, so the next reader need not re-derive it" $?
# ⛔ THE MARKER MUST BE HEAD-KEYED: `orch-loop.sh` refunds against `fixbail-<PR>-<HEAD>` matched to the
# head it dispatched for, so a marker written under any other name refunds nothing and the refusal burns
# a repair attempt (the 2026-10-14 P2 this marker exists for).
[ -f "$T/run/o/state/fixbail-3696-abc123def4567890abc123def4567890abc12345" ]
ck "1) the bail marker is written under fixbail-<PR>-<HEAD> (the name the refund reads)" "$?"
grep -q '^head_acquire' "$T/run/calls"
ck "1) NO head claim was attempted (a bailed lane must not stamp ownership on a head)" \
   "$([ $? -ne 0 ] && echo 0 || echo 1)"

# 2. acquired — and the token that makes the claim pushable
run_block "$T/branchclaim.sh" 0 'acquired refs/claims/branch-fix-3696-claims-block-push'
ck "2) an acquired branch proceeds (rc=$(cat "$T/run/rc"))" "$([ "$(cat "$T/run/rc")" = 0 ] && echo 0 || echo 1)"
# ⛔ SAME SHAPE AS ARM 2'S TOKEN CHECK (review F2, MEASURED FALSE PASS) — cycle 2's fix generalised to
# the token arm and NOT to this one. The message's `$(cat …)` is executed before `$?` is expanded, so
# `ck` received cat's status (always 0, the record always exists) and the arm printed a green ✅ beside a
# message that contradicted it. `BRANCH_OWN` is what makes `release_branch_claim` (`fix-one.sh:819`)
# release at all: an empty one strands the claim for `CLAIM_BRANCH_TTL` on EVERY fixer run. The
# mutation is caught only incidentally by the line-2 fence check below, which is exactly why the named
# assertion must be made LIVE rather than deleted.
grep -qx 'deadbeefcafebabe' "$T/run/branchown"; _own_rc=$?
ck "2) BRANCH_OWN carries the claim commit ($(cat "$T/run/branchown")) — the EXIT trap can release it" "$_own_rc"
# ⛔ THE P0 ARM (see arm E for the measured end-to-end form): without this file the guard refuses the
# fixer's OWN push as held-by-live, because it decides by POSSESSION.
# ⛔ THE STATUS IS CAPTURED BEFORE THE MESSAGE IS BUILT (cycle-2 review F1, MEASURED FALSE PASS). The
# first version passed a bare `$?` as `ck`'s second argument while its MESSAGE ran `$(cat …)`, so `ck`
# received cat's status (always 0, the record always exists) and the arm printed a green ✅ with an EMPTY
# `()` while the token had never been written: deleting the whole token-write block left this arm green
# and only 7 others red. A test whose headline clause cannot fail is the same class as the gate this PR
# is fixing. Capture first, print second.
_TOK="$T/run/gitdir/branchclaim-branch-fix-3696-claims-block-push"
[ -s "$_TOK" ]; _tok_rc=$?
if [ "$_tok_rc" -eq 0 ]; then
  ok "2) the FENCING TOKEN is written into the worktree's git dir ($_TOK)"
else
  bad "2) NO fencing token at $_TOK — the guard would refuse this lane's own push as held-by-live"
fi
sed -n 2p "$_TOK" 2>/dev/null | grep -qx 'deadbeefcafebabe'; _tok2_rc=$?
ck "2) and it names the claim commit (line 2 is the fence)" "$_tok2_rc"
grep -qF 'fencing token written for worktree' "$T/run/o/logs/fix-3696.log"
ck "2) the log records that the token was written" $?
grep -qF 'single-owner branch claim: acquired' "$T/run/o/logs/fix-3696.log"
ck "2) the log records the claim it took" $?
grep -q '^head_acquire' "$T/run/calls"
ck "2) the per-head claim still runs after the branch claim" $?
ls "$T/run/o/state"/fixbail-* >/dev/null 2>&1
ck "2) no bail marker is written on the proceeding path" "$([ $? -ne 0 ] && echo 0 || echo 1)"

# 2b. no worktree path at all — the token cannot be placed, and that must be LOUD
run_block "$T/branchclaim.sh" 0 'acquired refs/claims/branch-fix-3696-claims-block-push' 1 none
grep -qF 'WARNING: no worktree path is set' "$T/run/o/logs/fix-3696.log"
ck "2b) with no WT the missing token is stated, not silently skipped" $?

# 3. the registry is unreadable — an ABSTENTION is not a refusal (over-block arm)
run_block "$T/branchclaim.sh" 2 'branch-claim: REFUSED branch=fix/3696-claims-block-push reason=registry-unreadable'
ck "3) an UNREADABLE registry does NOT refuse the fixer (rc=$(cat "$T/run/rc"))" \
   "$([ "$(cat "$T/run/rc")" = 0 ] && echo 0 || echo 1)"
grep -qF 'branch claim UNAVAILABLE' "$T/run/o/logs/fix-3696.log"
ck "3) and it says the exclusion did not happen, instead of reading as 'nobody owns it'" $?
ck "3) nothing is held for release (BRANCH_OWN is empty: '$(cat "$T/run/branchown")')" \
   "$([ -z "$(cat "$T/run/branchown")" ] && echo 0 || echo 1)"
grep -q '^head_acquire' "$T/run/calls"
ck "3) the per-head CAS still runs — it is the backstop when the branch key cannot be read" $?

# 4. a claims.sh that predates #3328
run_block "$T/branchclaim.sh" 0 'unused' 0
ck "4) an OLD claims.sh does not refuse the fixer (rc=$(cat "$T/run/rc"))" \
   "$([ "$(cat "$T/run/rc")" = 0 ] && echo 0 || echo 1)"
grep -qF 'defines no claim_branch_acquire' "$T/run/o/logs/fix-3696.log"
ck "4) and the missing primitive is NAMED as a named state, not silently read as freedom" $?
grep -q '^branch_acquire' "$T/run/calls"
ck "4) no branch claim was attempted when the function does not exist" \
   "$([ $? -ne 0 ] && echo 0 || echo 1)"

# 5. the TERM handed to the branch key
run_block "$T/branchclaim.sh" 0 'acquired refs/claims/branch-fix-3696-claims-block-push'
# ⛔ CAPTURED, NOT INHERITED (review F3, MEASURED FALSE PASS): `$?` would be the message's inner
# `grep '^branch_acquire'` status. Measured on a `calls` file whose ttl is 37200 (so `ttl=<none>` is
# absent and the TESTED grep fails), this arm still printed a green ✅ while its own message showed
# `ttl=37200`. The intent is covered by the NEXT assertion (`ttl=[0-9]`), so this was a dead arm rather
# than an unguarded property — but a dead arm is a false PASS, which is the class this PR exists to fix.
grep -q 'ttl=<none>' "$T/run/calls"; _ttl_rc=$?
ck "5) the acquire passes NO ttl ($(grep '^branch_acquire' "$T/run/calls")) — the branch key's own CLAIM_BRANCH_TTL governs" "$_ttl_rc"
# ⛔ THE REASON IS NOT LOG NOISE (review P1). `CLAIM_BRANCH_TTL` is this keying's default AND ceiling, so
# a ttl of FIX_LEASE (37200) is clamped to the SAME 14400 — the minted term would be identical and every
# dispatch would print a clamp warning. Asking for it would therefore buy nothing and look like a fix.
# The real residual — 14400 s is shorter than this lane's 36000 s bound, so a >4 h fixer can lose
# exclusivity — is stated in fix-one.sh's own lifetime comment instead of being papered over here.
grep -q 'ttl=[0-9]' "$T/run/calls"
ck "5) and it never hands over the fixer's head-claim lease, which would be clamped to the same term anyway" \
   "$([ $? -ne 0 ] && echo 0 || echo 1)"

# C. rc=1 is not always a peer: an unreadable CLOCK is minted as rc 1 too
run_block "$T/branchclaim.sh" 1 'branch-claim: REFUSED branch=fix/3696-claims-block-push holder=?:0 reason=held-by-unreadable-clock'
grep -qF 'CLOCK is unreadable' "$T/run/o/logs/fix-3696.log"
ck "C) an unreadable clock is reported as the CLOCK, not as a peer" $?
grep -qF 'another lane already owns branch' "$T/run/o/logs/fix-3696.log"
ck "C) ...and the peer sentence is not printed over it" "$([ $? -ne 0 ] && echo 0 || echo 1)"
[ -f "$T/run/o/state/fixbail-3696-abc123def4567890abc123def4567890abc12345" ]
ck "C) the attempt is still refunded (nothing ran)" "$?"

# R/T. the release mechanism and its trap line
sed -n '/^release_branch_claim() {/,/^}/p' "$FIXER" > "$T/release.sh"
grep -qF 'claim_branch_release' "$T/release.sh"
ck "R) release_branch_claim is extractable and calls the fenced release" $?
grep -qE "^trap '[^']*release_branch_claim[^']*' EXIT" "$FIXER"
ck "T) the EXIT trap calls release_branch_claim (unpinned before: deleting it left every arm green)" $?
(
  set -u
  REPO=/repo; BR=fix/x; BRANCH_OWN=deadbeefcafebabe; BRANCH_TOKEN=/tmp/tok-unused
  claim_branch_release() { printf 'release repo=%s branch=%s own=%s\n' "$1" "$2" "$3" > "$T/rel-call"; return 0; }
  claim_branch_forget() { printf 'forget %s\n' "$1" > "$T/rel-forget"; return 0; }
  . "$T/release.sh" >/dev/null 2>&1
  release_branch_claim
  printf '%s\n' "$?" > "$T/rel-rc"
)
ck "R) release fences on (REPO, BR, the claim commit): $(cat "$T/rel-call" 2>/dev/null)" \
   "$(grep -qx 'release repo=/repo branch=fix/x own=deadbeefcafebabe' "$T/rel-call" 2>/dev/null && echo 0 || echo 1)"
ck "R) and it FORGETS the token (a stale token would later pass the fence): $(cat "$T/rel-forget" 2>/dev/null)" \
   "$(grep -qx 'forget /tmp/tok-unused' "$T/rel-forget" 2>/dev/null && echo 0 || echo 1)"
ck "R) a successful release returns 0 (rc=$(cat "$T/rel-rc"))" "$([ "$(cat "$T/rel-rc")" = 0 ] && echo 0 || echo 1)"

# R2. a FAILED fenced release must KEEP the token — the one case where it is still the proof of ownership
# ⛔ THE CODE FIX SHIPPED BEFORE THIS DETECTOR (cycle-3 review F1: "Detector: none exists"). Arm R stubs
# `claim_branch_release` to return 0, so nothing drove the failure path. `_claim_release_at` returns 1
# WITHOUT deleting the ref when the fenced push fails or the 20 s watchdog TERMs it — an expected outcome,
# documented by this file's own 20 s bound — and on that path the claim is STILL OURS, with the token as
# the only possession proof: recovery path (1) in fix-one.sh's lifetime note is "any same-box lane that
# holds the token can `branch-claim.sh release <br>`", and an unconditional forget kills it, refusing
# that lane by design and stranding the claim for the whole 4 h branch lease.
(
  set -u
  REPO=/repo; BR=fix/x; BRANCH_OWN=deadbeefcafebabe; BRANCH_TOKEN=/tmp/tok-keep
  rm -f "$T/rel-forget-fail"
  claim_branch_release() { return 1; }
  claim_branch_forget() { printf 'forget %s\n' "$1" > "$T/rel-forget-fail"; return 0; }
  . "$T/release.sh" >/dev/null 2>&1
  release_branch_claim
  printf '%s\n' "$?" > "$T/rel-rc-fail"
)
ck "R2) a FAILED fenced release is propagated as rc=1 (rc=$(cat "$T/rel-rc-fail"))" \
   "$([ "$(cat "$T/rel-rc-fail")" = 1 ] && echo 0 || echo 1)"
[ -e "$T/rel-forget-fail" ]; _r2_forgot=$?
ck "R2) ...and it does NOT forget the token (the claim is still ours; the token is the only possession proof)" \
   "$([ "$_r2_forgot" -ne 0 ] && echo 0 || echo 1)"
# ⛔ AND THE MUTANT, so R2 is attributed to the rc guard rather than to the fixture: delete the guard and
# the token IS forgotten. The mutant must still be a VALID program (cycle-2 F2's lesson: a mutant that
# does not parse proves only that a file which does not parse does nothing).
sed 's|^  \[ "\$rc" -eq 0 \] && ||' "$T/release.sh" > "$T/release-mutant.sh"
if cmp -s "$T/release.sh" "$T/release-mutant.sh"; then
  bad "R2) the mutant is IDENTICAL to the shipped release — the rc guard was not found to delete, so R2 cannot be attributed to it"
else
  bash -n "$T/release-mutant.sh"
  ck "R2) the mutant is still a VALID program (a syntax-error mutant proves nothing)" $?
  (
    set -u
    REPO=/repo; BR=fix/x; BRANCH_OWN=deadbeefcafebabe; BRANCH_TOKEN=/tmp/tok-keep
    rm -f "$T/rel-forget-mutant"
    claim_branch_release() { return 1; }
    claim_branch_forget() { printf 'forget %s\n' "$1" > "$T/rel-forget-mutant"; return 0; }
    . "$T/release-mutant.sh" >/dev/null 2>&1
    release_branch_claim
  ) >/dev/null 2>&1
  [ -e "$T/rel-forget-mutant" ]; _r2m=$?
  ck "R2) with the rc guard deleted the token IS forgotten on a failed release — so R2 measures the guard" \
     "$([ "$_r2m" -eq 0 ] && echo 0 || echo 1)"
fi

# E. END TO END — the composition that ships: real claims.sh, real hook, real push
# ⛔ THIS ARM EXISTS BECAUSE EACH HALF WAS GREEN WHILE THE PAIR WAS BROKEN (review P2 → measured P0).
E="$T/e2e"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export O="$E/o" CLAIM_STATE_DIR="$E/o/state"
unset CLAIM_REPO CLAIM_OWNER_HOST CLAIM_BRANCH_TTL CLAIM_TTL_MAX 2>/dev/null || true
git init -q --bare "$E/origin.git" 2>/dev/null
git clone -q "$E/origin.git" "$E/lane" 2>/dev/null
( cd "$E/lane" && echo seed > f.txt && git add f.txt && git commit -qm seed \
  && git push -q origin HEAD:main && git push -q origin HEAD:refs/heads/fix/e2e ) 2>/dev/null \
  || bad "E) fixture: cannot seed the e2e origin"
( cd "$E/lane" && CLAIM_REPO="$E/lane" "$BC" install-hook >/dev/null ) 2>/dev/null \
  || bad "E) fixture: install-hook failed"
E_HEAD="$(cd "$E/lane" && git rev-parse HEAD)"
mkdir -p "$E/o/state" "$E/o/logs"
(
  set -u
  O="$E/o"; L="$E/o/logs/fix-1"; PR=1
  REPO="$E/lane"; BR=fix/e2e; HEAD="$E_HEAD"; WT="$E/lane"
  BRANCH_OWN=""; BRANCH_TOKEN=""
  : > "$L"
  CLAIM_REPO="$E/lane"
  . "$HERE/claims.sh" || exit 3
  . "$T/branchclaim.sh" || exit 4
  printf '%s\n' "${BRANCH_OWN-}" > "$E/own"
  printf '%s\n' "${BRANCH_TOKEN-}" > "$E/token"
) >/dev/null 2>&1
ck "E) the block acquired the branch against a REAL registry (own=$(head -c 12 "$E/own" 2>/dev/null))" \
   "$([ -n "$(cat "$E/own" 2>/dev/null)" ] && echo 0 || echo 1)"
ck "E) and wrote a fencing token into the WORKTREE'S git dir (token=$(cat "$E/token" 2>/dev/null))" \
   "$([ -n "$(cat "$E/token" 2>/dev/null)" ] && echo 0 || echo 1)"
( cd "$E/lane" && echo more >> f.txt && git commit -qam e2e && git push -q origin HEAD:refs/heads/fix/e2e 2>"$E/push.err" )
ck "E) THE FIXER'S OWN PUSH SUCCEEDS through the installed hook (rc=$?) — the gate does not refuse its owner" $?
( cd "$E/lane" && git fetch -q origin refs/heads/fix/e2e 2>/dev/null; git log -1 --format=%s origin/fix/e2e 2>/dev/null | grep -qx e2e )
ck "E) and the branch really moved onto the fixer's commit" $?
# The control: a lane WITHOUT the token is refused on the same branch, so arm E measured the token.
# ⛔ CHECKED OUT ON THE BRANCH ITSELF (`--branch`), like `branch-claim.test.sh` case 8: a clone whose
# HEAD is `main` diverges from the moved branch, so its push is rejected as NON-FAST-FORWARD — a
# fixture artefact that reads exactly like a guard refusal and would make this control prove nothing.
git clone -q --branch fix/e2e "$E/origin.git" "$E/stray" 2>/dev/null
( cd "$E/stray" && CLAIM_REPO="$E/stray" "$BC" install-hook >/dev/null && echo x > g.txt && git add g.txt && git commit -qm stray ) 2>/dev/null
( cd "$E/stray" && git push -q origin HEAD:refs/heads/fix/e2e 2>"$E/stray.err" )
ck "E) CONTROL: a stray lane with no token IS refused on that branch" "$([ $? -ne 0 ] && echo 0 || echo 1)"
grep -q 'held-by-live' "$E/stray.err" 2>/dev/null
ck "E) ...with reason=held-by-live, naming the holder" $?

# E2. THE TOKEN GOES TO THE **WORKTREE'S** GIT DIR, NOT THE REPO'S — a pin, because the mistake is silent
# ⛔ REVIEW CYCLE 2 MEASURED THIS UNPINNED: patching `-C "$WT"` to `-C "$REPO"` — exactly what the block's
# own comment forbids — left all 43 arms green. Arm E could not see it (that fixture is a single checkout,
# where REPO==WT and the two git dirs are the same), and arm 2's `git()` stub prints one constant
# regardless of its arguments. A linked worktree is the posture that ships (`fix-one.sh` materialises one)
# and the one where the two differ: `<repo>/.git` vs `<repo>/.git/worktrees/<name>`.
E2ROOT="$T/e2e2"; E2WT="$E2ROOT/wt"
mkdir -p "$E2ROOT"
( cd "$E/lane" && git worktree add -q "$E2WT" -b fix/e2e2 2>/dev/null ) \
  || bad "E2) fixture: cannot create the linked worktree"
(
  set -u
  O="$E2ROOT/o"; L="$E2ROOT/o/logs/fix-2"; PR=2
  REPO="$E/lane"; BR=fix/e2e2; HEAD="$(git -C "$E2WT" rev-parse HEAD)"; WT="$E2WT"
  BRANCH_OWN=""; BRANCH_TOKEN=""
  mkdir -p "$O/state" "$O/logs"; : > "$L"
  CLAIM_REPO="$E/lane"
  . "$HERE/claims.sh" || exit 3
  . "$T/branchclaim.sh" || exit 4
  printf '%s\n' "${BRANCH_TOKEN-}" > "$E2ROOT/token"
) >/dev/null 2>&1
E2_GITDIR="$(git -C "$E2WT" rev-parse --absolute-git-dir 2>/dev/null)"
[ -n "$E2_GITDIR" ] && [ "$E2_GITDIR" != "$(git -C "$E/lane" rev-parse --absolute-git-dir)" ]
ck "E2) the fixture really has TWO git dirs (wt=$E2_GITDIR)" $?
[ -s "$E2_GITDIR/branchclaim-branch-fix-e2e2" ]
ck "E2) the token landed in the WORKTREE's git dir" "$?"
[ -e "$E/lane/.git/branchclaim-branch-fix-e2e2" ]
ck "E2) and NOT in the shared repo git dir (which every lane on this box can read)" \
   "$([ $? -ne 0 ] && echo 0 || echo 1)"

# M. the MUTANT — arm 1 measures the block, not the fixture
sed 's|: > "\$O/state/fixbail-\$PR-\$HEAD"|:|' "$T/branchclaim.sh" > "$T/branchclaim-mutant.sh"
if cmp -s "$T/branchclaim.sh" "$T/branchclaim-mutant.sh"; then
  bad "M) the mutant is IDENTICAL to the block — the marker write was not found to delete, so arm 1 cannot be attributed to it"
else
  run_block "$T/branchclaim-mutant.sh" 1 'branch-claim: REFUSED branch=fix/3696-claims-block-push holder=peerbox:4242 reason=held-by-live'
  ls "$T/run/o/state"/fixbail-* >/dev/null 2>&1
  ck "M) with the marker write deleted the bail marker is GONE — so arm 1 measured the block" \
     "$([ $? -ne 0 ] && echo 0 || echo 1)"
fi
# the token mutant: the P0 arm must be about the write, not about the fixture
# ⛔ THE MUTANT MUST STILL BE A VALID PROGRAM (cycle-2 review F2, VERIFIED). The first defused the call by
# opening a `#` comment INSIDE the `$( )`, which swallows the closing paren — `bash -n` refuses the file
# and `run_block` sources it with its output discarded, so the arm proved only that a file which does not
# parse writes no token. This one replaces the ASSIGNMENT, so the block is still the block minus the write;
# the parse is asserted FIRST, and it must be mutated at all.
sed 's|BRANCH_TOKEN="\$(claim_branch_record|BRANCH_TOKEN="\$(\:|' "$T/branchclaim.sh" > "$T/branchclaim-notoken.sh"
if cmp -s "$T/branchclaim.sh" "$T/branchclaim-notoken.sh"; then
  bad "M) the token mutant is IDENTICAL to the block — the record call was not found to defuse"
else
  bash -n "$T/branchclaim-notoken.sh"
  ck "M) the token mutant is still a VALID program (a syntax-error mutant proves nothing)" $?
  # ⛔ COMMENTS ARE STRIPPED FIRST: the block's own prose NAMES `claim_branch_record` (it explains why the
  # token must be written), so a plain grep stays green on a mutant that still calls it — the same
  # prose-vs-code confusion the repo's other design pins strip comments to avoid.
  # ⛔ NO PIPE: `grep -v` piped into a QUIET grep is the SIGPIPE false-negative idiom
  # `scripts/check-no-sigpipe-grep.sh` exists to ban (#841/#864; it was RED on this file). Under
  # `pipefail` a SIGPIPE-killed `grep -v` (141) makes the pipeline non-zero *while the call is still
  # present* — and this assertion reads non-zero as "the call is gone", so it fails in the FALSE-PASS
  # direction: a mutant that was NOT defused would be announced as defused, and arm M's whole claim ("so
  # the P0 arm measures the write") rests on this line. Capture, then test in the shell — the guard's own
  # prescribed remedy, and a `case` needs no pipe.
  _nc="$(grep -v '^[[:space:]]*#' "$T/branchclaim-notoken.sh" || true)"
  case "$_nc" in
    *'claim_branch_record "'*) _nc_rc=1 ;;
    *)                        _nc_rc=0 ;;
  esac
  ck "M) ...and the record CALL is genuinely gone from it (comments aside)" "$_nc_rc"
  run_block "$T/branchclaim-notoken.sh" 0 'acquired refs/claims/branch-fix-3696-claims-block-push'
  [ -s "$T/run/gitdir/branchclaim-branch-fix-3696-claims-block-push" ]
  ck "M) with the token write defused, arm 2's token assertion IS red — so the P0 arm measures the write" \
     "$([ $? -ne 0 ] && echo 0 || echo 1)"
fi

echo
printf 'fix-one-branchclaim.test.sh: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
