#!/usr/bin/env bash
# claim-action-proof.test.sh — the hold-proof AT THE ACTION SITE (agent-infra#2867).
#
# WHY THIS EXISTS. The claim registry (claims.sh) fences DISPATCH: the pre-flight refuses a
# duplicate dispatch and the acquire CAS refuses a live holder. It does NOT fence ACTION: the
# acting tool (`gh pr merge --admin`) runs with nothing verifying that the lane that reached it
# still holds the claim for this PR at this head. A dead harness whose claim was pruned, or a
# stale actor whose token a peer superseded, would still act. `claim_action_proof` is the fence:
# it refuses unless (i) a claim ref exists, (ii) its tip is the actor's own commit (the fencing
# token), (iii) it names THIS box, and (iv) its holder is not dead.
#
# WHAT IS UNDER TEST — one discriminator per refusal rung, so reverting one guard reddens exactly
# one group (the MUTATION section drives the RED direction mechanically):
#   HP1 [held]           a claim whose tip IS the actor's token, minted by this box with a LIVE
#                        pid, passes (rc 0, "HELD") — the only positive outcome.
#   HP2 [no-claim]       an absent ref is a REFUSAL (rc 1), never "free".
#   HP3 [fence-mismatch] a ref whose tip is NOT the actor's token (a peer reclaimed it) refuses.
#   HP4 [foreign-holder] a claim minted by ANOTHER box refuses, even with the correct token.
#   HP5 [orphaned-holder] a claim whose minting pid is DEAD refuses (the holder is gone).
#   HP6 [input]          a non-numeric PR, a non-hex head, a 39-char head, a short token refuse rc 2.
#   HP7 [unreadable]     an unreadable registry (ls-remote rc != 0) refuses rc 2 — NOT "no claim".
#
# ⛔ FAIL-CLOSED IS THE WHOLE POINT. Every refusal is a REFUSAL OF THE ACTION; rc 2 ("unreadable")
# is a distinct refusal, never a pass. `--mutations` reverts each guard in a TEMP COPY of claims.sh
# (never the shipped file) and requires the paired case to flip to the PASS direction — a mutation
# that leaves the paired case refusing proves the guard was INERT, which is a failure here.
#
# HERMETIC: every check builds its own bare origin + work repo (no network, nothing outside $T),
# using the same `as_box` seam as claim-orphan.test.sh.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAIMS_SH="${CLAIMS_SH:-$HERE/claims.sh}"
[ -f "$CLAIMS_SH" ] || { echo "❌ missing $CLAIMS_SH"; exit 2; }
REAL_GIT="$(command -v git)" || { echo "❌ git not found"; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
ck()  { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi; }
field() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/claim-action-proof.XXXXXX")" || exit 2
T="$(cd "$T" && pwd -P)" || exit 2
trap 'rm -rf "$T"' EXIT INT TERM

HEAD="0123456789abcdef0123456789abcdef01234567"   # 40-hex; sha12 = 0123456789ab
PR=424242
WRONG="ffffffffffffffffffffffffffffffffffffffff"

# mk_origin <name> -> path of a fresh bare repo standing in for the shared remote
mk_origin() {
  local d="$T/$1"
  mkdir -p "$d" || return 1
  "$REAL_GIT" init -q --bare "$d/origin.git" || return 1
  printf '%s' "$d/origin.git"
}
# ensure_work_repo <origin> — one work repo per scenario, origin-wired
ensure_work_repo() {
  rm -rf "$T/repo" 2>/dev/null
  "$REAL_GIT" init -q "$T/repo" || return 1
  "$REAL_GIT" -C "$T/repo" remote add origin "$1" || return 1
}
# as_box <origin> <host> <body> [ENV=VALUE ...] — run <body> as ONE box (see claim-orphan.test.sh)
as_box() {
  local origin="$1" host="$2" body="$3"; shift 3
  (
    cd "$T" || exit 1
    export CLAIM_REPO="$T/repo"
    export CLAIM_OWNER_HOST="$host"
    unset CLAIM_OWNER_ID CLAIM_KNOWN_HOSTS CLAIM_DEAD_HOSTS
    if [ -z "${CLAIM_STATE_DIR:-}" ]; then
      case "$origin" in
        "") CLAIM_STATE_DIR="$T/cs-none/$host" ;;
        *)  CLAIM_STATE_DIR="$(dirname "$(dirname "$origin")")/state/$host" ;;
      esac
    fi
    export CLAIM_STATE_DIR
    mkdir -p "$CLAIM_STATE_DIR" 2>/dev/null
    local kv
    for kv in "$@"; do export "${kv?}"; done
    # shellcheck source=/dev/null
    . "$CLAIMS_SH" || exit 1
    eval "$body"
  )
}
# plant <origin> <host> <owner-pid> <until> <pr> <sha12> -> the claim commit sha, pushed directly
# (the same synthetic-owner seam claim-orphan.test.sh uses, so a dead pid is deterministic).
plant() {
  local origin="$1" host="$2" opid="$3" until="$4" pr="$5" sha12="$6"
  as_box "$origin" "$host" 'c="$(_claim_commit "'"$host:$opid"'" "'"$until"'")"
    _git push -q origin "$c:refs/claims/'"$pr"'-'"$sha12"'" 2>/dev/null || exit 9
    printf "%s" "$c"'
}
# proof <origin> <host> <pr> <head> <token> -> "RC=<n> RES=<line>" from claim_action_proof
proof() {
  as_box "$1" "$2" 'claim_action_proof '"$3"' '"$4"' '"$5"' >/dev/null 2>&1
    printf "RC=%s\nRES=%s\n" "$?" "${CLAIM_ACTION_RESULT:-}"'
}
FUTURE() { printf '%s' "$(( $(date +%s) + 7200 ))"; }

echo "── HP1: a live local holder with the correct token PASSES the proof ───────────────────"
ORIG1="$(mk_origin hp1)"; ensure_work_repo "$ORIG1" || { echo "❌ fixture"; exit 2; }
HP1="$(as_box "$ORIG1" boxA '
  c="$(_claim_commit "boxA:$$" "'"$(FUTURE)"'")"
  _git push -q origin "$c:refs/claims/'"$PR"'-0123456789ab" 2>/dev/null || exit 9
  claim_action_proof '"$PR"' '"$HEAD"' "$c" >/dev/null 2>&1
  printf "RC=%s\nRES=%s\n" "$?" "${CLAIM_ACTION_RESULT:-}"
')"
[ "$(field "$HP1" RC)" = "0" ]; ck "HP1 [held] the proof holds (rc=0) for a live local holder with its own token" $?
case "$(field "$HP1" RES)" in
  *HELD*) ok "HP1 [held] the result says HELD, naming the holder: '$(field "$HP1" RES)'" ;;
  *) bad "HP1 [held] the result says HELD (got '$(field "$HP1" RES)')" ;;
esac

echo
echo "── HP2: an absent ref is a REFUSAL, never freedom ─────────────────────────────────────"
ORIG2="$(mk_origin hp2)"; ensure_work_repo "$ORIG2" || { echo "❌ fixture"; exit 2; }
HP2="$(proof "$ORIG2" boxA "$PR" "$HEAD" "$WRONG")"
[ "$(field "$HP2" RC)" = "1" ]; ck "HP2 [no-claim] rc=1 for a head with no claim (an actor that cannot show a claim does not hold it)" $?
case "$(field "$HP2" RES)" in
  *reason=no-claim*) ok "HP2 [no-claim] the refusal names no-claim: '$(field "$HP2" RES)'" ;;
  *) bad "HP2 [no-claim] the refusal names no-claim (got '$(field "$HP2" RES)')" ;;
esac

echo
echo "── HP3: a mismatched tip (a peer reclaimed the claim) is REFUSED by the fence ─────────"
ORIG3="$(mk_origin hp3)"; ensure_work_repo "$ORIG3" || { echo "❌ fixture"; exit 2; }
TOK3="$(plant "$ORIG3" boxA 999999 "$(FUTURE)" "$PR" 0123456789ab)"
[ -n "$TOK3" ] && [ "${#TOK3}" -eq 40 ]; ck "HP3 (setup) the claim is planted with a synthetic dead pid" $?
HP3="$(proof "$ORIG3" boxA "$PR" "$HEAD" "$WRONG")"
[ "$(field "$HP3" RC)" = "1" ]; ck "HP3 [fence-mismatch] rc=1 when the presented token is not the ref tip" $?
case "$(field "$HP3" RES)" in
  *reason=fence-mismatch*) ok "HP3 [fence-mismatch] the refusal names fence-mismatch: '$(field "$HP3" RES)'" ;;
  *) bad "HP3 [fence-mismatch] the refusal names fence-mismatch (got '$(field "$HP3" RES)')" ;;
esac

echo
echo "── HP4: a claim minted by ANOTHER box is REFUSED (names this actor, not any actor) ────"
ORIG4="$(mk_origin hp4)"; ensure_work_repo "$ORIG4" || { echo "❌ fixture"; exit 2; }
TOK4="$(plant "$ORIG4" peerbox 999999 "$(FUTURE)" "$PR" 0123456789ab)"
HP4="$(proof "$ORIG4" mybox "$PR" "$HEAD" "$TOK4")"
[ "$(field "$HP4" RC)" = "1" ]; ck "HP4 [foreign-holder] rc=1 for a claim minted by another box, even with the correct token" $?
case "$(field "$HP4" RES)" in
  *reason=foreign-holder*) ok "HP4 [foreign-holder] the refusal names foreign-holder: '$(field "$HP4" RES)'" ;;
  *) bad "HP4 [foreign-holder] the refusal names foreign-holder (got '$(field "$HP4" RES)')" ;;
esac

echo
echo "── HP5: a claim whose minting pid is DEAD is REFUSED (the holder is gone) ─────────────"
ORIG5="$(mk_origin hp5)"; ensure_work_repo "$ORIG5" || { echo "❌ fixture"; exit 2; }
TOK5="$(plant "$ORIG5" boxA 999999 "$(FUTURE)" "$PR" 0123456789ab)"
HP5="$(proof "$ORIG5" boxA "$PR" "$HEAD" "$TOK5")"
[ "$(field "$HP5" RC)" = "1" ]; ck "HP5 [orphaned-holder] rc=1 for a local claim whose pid is dead" $?
case "$(field "$HP5" RES)" in
  *reason=orphaned-holder*) ok "HP5 [orphaned-holder] the refusal names orphaned-holder: '$(field "$HP5" RES)'" ;;
  *) bad "HP5 [orphaned-holder] the refusal names orphaned-holder (got '$(field "$HP5" RES)')" ;;
esac

echo
echo "── HP6: unreadable inputs are refused at the door (rc 2, never a pass) ────────────────"
ORIG6="$(mk_origin hp6)"; ensure_work_repo "$ORIG6" || { echo "❌ fixture"; exit 2; }
HP6A="$(proof "$ORIG6" boxA notapr "$HEAD" "$WRONG")"
[ "$(field "$HP6A" RC)" = "2" ]; ck "HP6 [input] a non-numeric PR refuses rc 2" $?
HP6B="$(proof "$ORIG6" boxA "$PR" "not-a-sha" "$WRONG")"
[ "$(field "$HP6B" RC)" = "2" ]; ck "HP6 [input] a non-hex head refuses rc 2" $?
HP6C="$(proof "$ORIG6" boxA "$PR" "${HEAD%?}" "$WRONG")"   # 39 chars
[ "$(field "$HP6C" RC)" = "2" ]; ck "HP6 [input] a 39-char head refuses rc 2 (not 40-hex)" $?
HP6D="$(proof "$ORIG6" boxA "$PR" "$HEAD" "deadbeef")"
[ "$(field "$HP6D" RC)" = "2" ]; ck "HP6 [input] a non-40-hex token refuses rc 2" $?

echo
echo "── HP7: an UNREADABLE registry is rc 2, never collapsed into no-claim ─────────────────"
ORIG7="$(mk_origin hp7)"; ensure_work_repo "$ORIG7" || { echo "❌ fixture"; exit 2; }
# A work repo whose origin names a path that does not exist: ls-remote fails (rc != 0).
"$REAL_GIT" -C "$T/repo" remote set-url origin "$T/no-such-origin.git" 2>/dev/null
HP7="$(proof "$ORIG7" boxA "$PR" "$HEAD" "$WRONG")"
[ "$(field "$HP7" RC)" = "2" ]; ck "HP7 [unreadable] an unreadable registry refuses rc 2, never 'no claim'" $?
case "$(field "$HP7" RES)" in
  *reason=registry-unreadable*) ok "HP7 [unreadable] the refusal names registry-unreadable: '$(field "$HP7" RES)'" ;;
  *) bad "HP7 [unreadable] the refusal names registry-unreadable (got '$(field "$HP7" RES)')" ;;
esac

# ══ MUTATIONS — every guard must be load-bearing: revert it, the paired case must go RED ══
# Each mutation is applied to a TEMP COPY of claims.sh (never the shipped file), then the FULL
# suite is re-run against that copy and the paired case's ❌ line must appear. A mutation that
# leaves the paired case green proves the guard was INERT — the false-PASS shape this section
# exists to remove. Each anchor is an EXACT substring of the shipped claims.sh; `mut_apply`
# asserts the anchor is present before replacing, so a drifted anchor fails loudly rather than
# silently mutating nothing.
run_mutations() {
  local mut_dir
  mut_dir="$(mktemp -d "${TMPDIR:-/tmp}/claim-action-proof-mut.XXXXXX")" || exit 2
  echo
  echo "── MUTATIONS: each guard reverted, its paired case must go RED ────────────────────────"

  # mut_apply <name> <path> — replace the exact anchor for <name> in <path> (python exact match).
  mut_apply() {
    python3 - "$1" "$2" <<'PY'
import sys
name, p = sys.argv[1], sys.argv[2]
MUTS = {
    "M1-no-claim": (
        'reason=no-claim"\n    echo "$CLAIM_ACTION_RESULT"; return 1',
        'reason=no-claim"\n    echo "$CLAIM_ACTION_RESULT"; return 0',
    ),
    "M2-fence": (
        '  if [ "$cur" != "$own" ]; then',
        '  if false; then',
    ),
    "M3-foreign": (
        'claim_host_is_local() {\n  local h="${1:-}" me real',
        'claim_host_is_local() {\n  return 0\n  local h="${1:-}" me real',
    ),
    "M4-orphan": (
        '  # (iv) the holder must not be ORPHANED — a dead pid on this box cannot be the acting lane.\n  orph="$(claim_orphan_reason "$owner" "$ref")" || orph=""',
        '  # (iv) MUTATED\n  orph=""',
    ),
    "M5-input": (
        '  if [ "${#head}" -ne 40 ]; then\n    CLAIM_ACTION_RESULT="claim-action-proof: REFUSED pr=$pr head=${head:0:12} reason=head-not-40-hex"\n    echo "$CLAIM_ACTION_RESULT"; return 2\n  fi',
        '',
    ),
    "M6-unreadable": (
        '  if [ "$lrc" -ne 0 ]; then\n    CLAIM_ACTION_RESULT="claim-action-proof: REFUSED pr=$pr head=${head:0:12} holder=<unreadable> reason=registry-unreadable"\n    echo "$CLAIM_ACTION_RESULT"; return 2\n  fi',
        '',
    ),
}
old, new = MUTS[name]
t = open(p).read()
assert old in t, "mutation %s: anchor not found in %s" % (name, p)
open(p, "w").write(t.replace(old, new, 1))
PY
  }

  # mut <name> <paired-case-needle> — apply, re-run the FULL suite, require the paired case RED.
  mut() {
    local name="$1" needle="$2" out
    cp "$CLAIMS_SH" "$mut_dir/claims.sh" || { bad "MUTATION $name: could not copy claims.sh"; return; }
    if ! mut_apply "$name" "$mut_dir/claims.sh"; then
      bad "MUTATION $name: anchor not found (claims.sh drifted?)"; return
    fi
    bash -n "$mut_dir/claims.sh" 2>/dev/null || { bad "MUTATION $name: temp claims.sh no longer parses"; return; }
    out="$( CLAIMS_SH="$mut_dir/claims.sh" bash "$HERE/claim-action-proof.test.sh" 2>&1 )" || true
    if grep -qF "$needle" <<< "$out"; then
      ok "MUTATION $name: the guard is load-bearing — reverted, the paired case went RED"
    else
      bad "MUTATION $name: the guard is INERT — reverted, the paired case still passed"
    fi
  }

  mut "M1-no-claim"     "❌ HP2 [no-claim]"
  mut "M2-fence"        "❌ HP3 [fence-mismatch]"
  mut "M3-foreign"      "❌ HP4 [foreign-holder]"
  mut "M4-orphan"       "❌ HP5 [orphaned-holder]"
  mut "M5-input"        "❌ HP6 [input]"
  mut "M6-unreadable"   "❌ HP7 [unreadable]"

  rm -rf "$mut_dir"
}

if [ "${1:-}" = "--mutations" ]; then
  run_mutations
fi

echo
echo "── RESULT: $PASS passed, $FAIL failed ────────────────────────────────────────────────"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
