#!/usr/bin/env bash
# fix-one-branchclaim.test.sh — a FIXER must take the coarser BRANCH claim before it works, and a peer
# that already owns the branch must be refused BEFORE any head is pushed on top of its work
# (agent-infra#3696, P0).
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
# WHAT IS PINNED — every arm drives the SHIPPED block, extracted from fix-one.sh between its
# `[fixgate-branchclaim:…]` markers, never a re-typed copy of the rule:
#   0  the block is extractable (the PRE-FIX code has no markers, so this FAILS instead of passing
#      vacuously), fix-one.sh still parses, and the block sits BEFORE the per-head `claim_acquire`
#      call — coarse-to-fine, the same order merge-one.sh takes its keys in. A block that runs after
#      the head claim would refuse a peer only once this box had already booked the head.
#   1  a PEER holds the branch (rc=1) → the fixer refuses, writes the HEAD-KEYED `fixbail-<PR>-<head>`
#      marker the controller's refund reads, and exits 0 WITHOUT attempting the head claim. That last
#      clause is the incident: a lane that bails must not also stamp ownership on a head.
#   2  the claim is acquired (rc=0) → `BRANCH_OWN` carries the claim commit (so the EXIT trap can
#      release it — an unreleased branch claim strands the branch for every peer), and the head claim
#      still runs afterwards.
#   3  the registry is UNREADABLE (rc=2) → the fixer PROCEEDS and says so. This is the over-block arm:
#      an abstention is not a refusal, and the per-head CAS is still the backstop.
#   4  a claims.sh that PREDATES #3328 (no `claim_branch_acquire`) → proceed, and NAME it in the log,
#      instead of silently reading as "nobody owns this branch".
#   5  the acquire is made with NO ttl argument, so the BRANCH key's own term (`CLAIM_BRANCH_TTL`)
#      governs. Passing the fixer's head-claim lease (FIX_TIMEOUT+1200, up to 10 h) would be clamped to
#      the branch ceiling noisily on every dispatch, and passing a SHORTER one would expire the claim
#      mid-run — which is how a peer acquires a branch a live fixer is still writing.
#   M  the MUTANT: with the bail-marker write deleted from a doctored copy of the SAME block, arm 1's
#      marker assertion fails — so arm 1 measures the block and not the fixture.
#
# Run: bash scripts/orchestrator-harness/fix-one-branchclaim.test.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
FIXER="$HERE/fix-one.sh"
[ -r "$FIXER" ] || { echo "FATAL: fix-one.sh not found beside this test ($FIXER)" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/fix-one-branchclaim.XXXXXX")" || { echo "FATAL: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$T"' EXIT
pass=0 fail=0
ok()  { printf '  ✅ %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  ❌ %s\n' "$1"; fail=$((fail+1)); }
ck()  { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi; }

# ── 0. extract the SHIPPED block ───────────────────────────────────────────────────────────────
sed -n '/\[fixgate-branchclaim:begin\]/,/\[fixgate-branchclaim:end\]/p' "$FIXER" > "$T/branchclaim.sh"
if [ ! -s "$T/branchclaim.sh" ]; then
  bad "0) the branch-claim block is EMPTY — fix-one.sh has no [fixgate-branchclaim] markers, so every arm below would pass vacuously"
  echo "───────────────────────────────────────────────────────────────────"
  echo "❌ fix-one branch-claim suite: the block is not extractable — refusing to run arm 1+"
  exit 1
fi
grep -qF 'claim_branch_acquire' "$T/branchclaim.sh"
ck "0) the block is extractable and calls claim_branch_acquire ($(wc -l < "$T/branchclaim.sh" | tr -d ' ') lines)" $?
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

# ── the driver ────────────────────────────────────────────────────────────────────────────────
# run_block <block-file> <claim-rc> <claim-result> [has-acquire:0|1]
#   → $T/run/{rc,calls,branchown} + $T/run/o/state/fixbail-* + $T/run/o/logs/fix-3696.log
run_block() {
  local block="$1" rc="$2" res="$3" has="${4:-1}" d="$T/run"
  rm -rf "$d"; mkdir -p "$d/o/state" "$d/o/logs"
  (
    set -u
    O="$d/o"; L="$d/o/logs/fix-3696"; PR=3696
    REPO=/repo; BR=fix/3696-claims-block-push
    HEAD=abc123def4567890abc123def4567890abc12345
    BRANCH_OWN=""
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

# 2. acquired
run_block "$T/branchclaim.sh" 0 'acquired refs/claims/branch-fix-3696-claims-block-push'
ck "2) an acquired branch proceeds (rc=$(cat "$T/run/rc"))" "$([ "$(cat "$T/run/rc")" = 0 ] && echo 0 || echo 1)"
grep -qx 'deadbeefcafebabe' "$T/run/branchown"
ck "2) BRANCH_OWN carries the claim commit ($(cat "$T/run/branchown")) — the EXIT trap can release it" $?
grep -qF 'single-owner branch claim: acquired' "$T/run/o/logs/fix-3696.log"
ck "2) the log records the claim it took" $?
grep -q '^head_acquire' "$T/run/calls"
ck "2) the per-head claim still runs after the branch claim" $?
ls "$T/run/o/state"/fixbail-* >/dev/null 2>&1
ck "2) no bail marker is written on the proceeding path" "$([ $? -ne 0 ] && echo 0 || echo 1)"

# 3. the registry is unreadable — an ABSTENTION is not a refusal (over-block arm)
run_block "$T/branchclaim.sh" 2 'branch-claim: REFUSED branch=fix/3696-claims-block-push reason=registry-unreadable'
ck "3) an UNREADABLE registry does NOT refuse the fixer (rc=$(cat "$T/run/rc"))" \
   "$([ "$(cat "$T/run/rc")" = 0 ] && echo 0 || echo 1)"
grep -qF 'branch claim UNAVAILABLE' "$T/run/o/logs/fix-3696.log"
ck "3) and it says the exclusion did not happen, instead of reading as 'nobody owns it'" $?
grep -qx '__unset__\|' "$T/run/branchown" 2>/dev/null || true
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
grep -q 'ttl=<none>' "$T/run/calls"
ck "5) the acquire passes NO ttl ($(grep '^branch_acquire' "$T/run/calls")) — the branch key's own CLAIM_BRANCH_TTL governs" $?
grep -q 'ttl=[0-9]' "$T/run/calls"
ck "5) and it never hands over the fixer's head-claim lease (which the branch ceiling would clamp, or a shorter one would expire mid-run)" \
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

echo
printf 'fix-one-branchclaim.test.sh: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
