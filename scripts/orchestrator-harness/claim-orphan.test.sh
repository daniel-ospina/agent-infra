#!/usr/bin/env bash
# claim-orphan.test.sh — a claim whose owner HOST is gone must be reclaimable, and a claim's
# lease must never exceed the TTL that governs its keying (agent-infra#2094).
#
# THE INCIDENT THIS PINS (measured 2026-10-18 on the live box). The machine was renamed
# `Daniels-MacBook-Air` -> `Daniels-MacBook-Air-new` while leases minted under the OLD name were
# outstanding:
#
#     refs/claims/issue-9063   holder Daniels-MacBook-Air:41679   lease_until in 157 min
#     [dispatch] #9063 NOT dispatched — held by Daniels-MacBook-Air:41679 until … (9768s left)
#     [dispatch] backlog empty queue=READ(192)
#   (the ref table and the READ(192) line are #2094's; the dispatch line is its #9063 entry, which
#   the issue also reports freeing by hand along with "157 minutes" of dead lease)
#
# Three properties make that a permanent block rather than a transient one:
#   • `claim_acquire`/`claim_issue_preflight` treat any FUTURE `lease_until` as LIVE, and the
#     owner host is only ever printed, never checked;
#   • `claim_prune` reaps by EXPIRY alone, so a future-stamped lease is immune for its whole term;
#   • a host name that no longer exists can never match again, so no box can ever verify liveness.
# The dispatcher's own line then reported "backlog empty" — the healthiest-looking possible answer —
# because every candidate was withheld as a COLLISION. 14 leases were held by dead pids, 0 alive.
#
# WHAT IS UNDER TEST, and the direction each guard must fail in:
#   O1 [RED→GREEN] a RENAME makes an outstanding claim reclaimable — the same box, a new host name,
#      the old term still in the future. This is the incident, end to end: pre-fix the second
#      acquire returns 1 ("held by"), post-fix it returns 0 and says the claim was ORPHANED.
#   O2 [RED→GREEN] `claim_prune` reaps by ORPHANED HOST as well as by expiry, so an abandoned
#      claim leaves the registry even while its lease has hours left.
#   O3 [PINNED]     `claim_prune` still reaps by EXPIRY (the fix must not trade the old arm away).
#   O4 [PINNED]     a host that IS a known fleet host is NOT orphaned — a live peer's claim must
#      never be stolen. This is the fail-open this whole change could introduce, so it is asserted
#      directly rather than argued in a comment.
#   O5 [RED→GREEN]  the LOCAL rule on a **PR** claim — the only keying the pid may judge: same host
#      + a dead pid is orphaned; same host + a live pid is NOT orphaned. (It needs no roster, so it
#      works on a single-box fleet with no configuration at all.)
#   O15 [partly RED→GREEN] an **ISSUE** claim is NOT reaped by that pid rule: a controller restart
#      leaves the lane working, so a pid-based reap would delete the shared barrier and re-open the
#      duplicate. The prune assertions are RED→GREEN (pre-fix nothing reaped on a HOST rule at all, and
#      they now run BEFORE the acquire re-stamps the claim — see the ⛔ there), and the contrast case —
#      the SAME dead pid on a PR claim IS pruned — is what makes the exclusion a rule, not a dead branch.
#   O16 [mostly RED→GREEN] orch-loop's `claim_live()` — the FOURTH call site — applies the same rules,
#      so a renamed box stops skipping PRs it could work. Driven by sourcing the SHIPPED function
#      alongside claims.sh; both pre-existing harnesses drive it WITHOUT claims.sh, where the arm is
#      deliberately inert (they assert that too).
#   O19 [RED→GREEN] the destructive arms require POSITIVE evidence: an absent `ref` does not authorise
#      the pid rule, and a `hostname` probe that cannot answer makes `claim_former_hosts` abstain
#      (asserted on the function directly — through `claim_orphan_reason` the live-pid rule masks it).
#   O21 [RED→GREEN] a FORMER name of this box with a LIVE local pid on a PR key is held-by-live, and the
#      prune leaves it alone — the P0 that a rename would otherwise turn into a deleted live claim.
#   O20 [RED→GREEN] the prune's unparseable-lease skip is a DELETING branch and is pinned here.
#   O17 [RED→GREEN] the RECORDER (`claim_host_record`) is positively tested. Without it the
#      former-name rule — the only thing that makes a rename self-heal — writes nothing at all, and
#      the negative "a seam identity is not recorded" assertion would still pass.
#   O6 [RED→GREEN] `claim_owner` RE-DERIVES the host on every call (a rename between two calls is
#      visible in the second stamp) and REJECTS a configured `CLAIM_OWNER_ID` whose host segment is
#      not the running host — loudly, and without stamping the stale value.
#   O7 [RED→GREEN] the stamped lease term is <= the TTL that governs the keying: `<= CLAIM_TTL` for
#      a PR claim, `<= CLAIM_ISSUE_TTL` for an issue claim. Read back from the pushed claim commit,
#      not from the argument, so a call site that silently inflates the term is caught.
#      ⚠️ The 157-minute lease in the incident is `CLAIM_ISSUE_TTL` (10800s = 180 min) applied to an
#      ISSUE claim — by design, documented at its definition. O7 therefore asserts the term against
#      the TTL THAT GOVERNS THE KEYING, and asserts the PR default is 1800s separately. Lowering the
#      issue TTL would expire a claim mid-lane (its own comment computes 3h from the lane + chain
#      budgets), which is the duplicate-dispatch failure the registry exists to prevent.
#   O8 [RED→GREEN] the PRE-FLIGHT reads an orphaned claim as CLEAN (free to reclaim) instead of
#      COLLISION, and a live peer's as COLLISION naming `held-by-live`.
#   O9 [PINNED]     a lease whose lease_until cannot be parsed is still LIVE — the existing
#      unparseable-is-live polarity must survive the orphan arm (it is the arm most likely to
#      reorder the checks).
#   O10 [RED→GREEN] a rename SELF-HEALS WITH NO ROSTER: the box remembers the names it has carried
#      and treats its OWN former names as dead. No roster ships in this repo, so without this the
#      incident's own blocked dispatch (the same box refusing its own lease) stays blocked.
#   O11 [PINNED]    a `ps` that cannot answer is NOT a death certificate: the bare probe folded
#      "could not tell" into "gone" and would steal every same-host claim on a box with a hardened
#      /proc, a PS_BIN shim or no procps. Passes on the pre-fix tree because nothing reaped at all;
#      it exists to keep the NEW arm from creating that fail-open.
#   O12 [PINNED]    a roster that does not name the RUNNING host is stale (the usual trigger for that
#      staleness IS a rename) and must ABSTAIN rather than reap the renamed box's live claims.
#   O13 [RED→GREEN] a `CLAIM_OWNER_ID` carrying its own pid is refused (claims.sh always appends the
#      process pid, so it would otherwise stamp `host:pid:pid`).
#   O14 [RED→GREEN] clamping to the ceiling is LOUD. A silent clamp shortens merge-one's derived lease
#      below the review window it must outlive — a mid-review expiry, the duplicate this registry
#      exists to prevent — and leaves nothing to diagnose.
# ⛔ LABELLING HONESTY — MEASURED, not asserted. `CLAIMS_SH=<git archive HEAD>:claims.sh bash
# claim-orphan.test.sh` (2026-10-18, against the pre-change claims.sh) reports 46 passed, 42 FAILED.
# Every [RED→GREEN] line is in that failing set, and so is exactly ONE line that carries no such label:
# `O7 the PR keying declares a documented ceiling` (a pre-fix reader has no ceiling to declare). The
# converse is what keeps the labels honest: a [PINNED] line must PASS pre-fix, because PINNED means
# "this guards a new fail-open, it is not a regression", and five assertions were RE-LABELLED after
# measurement showed they passed or failed the other way (O4's token check, three O15 lines, O17's
# duplicate check, O18's once-per-process check). Re-measure rather than trusting this paragraph — it
# is a snapshot of one measurement, not an invariant, and the file grows.
#
# HERMETIC: every check builds its own throwaway bare origin (`git init --bare`), so no network, no
# real origin and nothing outside $T is written — the claim refs die with the temp dir.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ⛔ OVERRIDABLE so the RED direction can be RE-MEASURED rather than believed:
#   CLAIMS_SH=<git show main:scripts/orchestrator-harness/claims.sh> bash claim-orphan.test.sh
CLAIMS_SH="${CLAIMS_SH:-$HERE/claims.sh}"
[ -f "$CLAIMS_SH" ] || { echo "❌ missing $CLAIMS_SH"; exit 2; }
# O16 drives orch-loop's `claim_live()` (the PR-keyed reader) out of the SHIPPED file, so the fourth
# call site of the orphan rules is EXECUTED rather than assumed. LOOP is overridable for the same
# re-measurement reason as CLAIMS_SH.
LOOP="${LOOP:-$HERE/orch-loop.sh}"
[ -f "$LOOP" ] || { echo "❌ missing $LOOP"; exit 2; }
REAL_GIT="$(command -v git)" || { echo "❌ git not found"; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
ck()  { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi; }
field() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/claim-orphan.XXXXXX")" || exit 2
T="$(cd "$T" && pwd -P)" || exit 2
trap 'rm -rf "$T"' EXIT INT TERM

# mk_origin <name> -> path of a fresh bare repo standing in for the shared remote
mk_origin() {
  local d="$T/$1"
  mkdir -p "$d" || return 1
  "$REAL_GIT" init -q --bare "$d/origin.git" || return 1
  printf '%s' "$d/origin.git"
}
# as_box <origin> <host> <body> [ENV=VALUE ...]
#   Runs <body> as ONE box: cwd is the scenario work repo, CLAIM_REPO is that repo, the owner host
#   is <host>, and every extra assignment is exported. Prints whatever the body prints (stderr is
#   merged by the caller's capture). `eval` of the body keeps each call site one readable line.
as_box() {
  local origin="$1" host="$2" body="$3"; shift 3
  (
    cd "$T" || exit 1
    export CLAIM_REPO="$T/repo"
    export CLAIM_OWNER_HOST="$host"
    unset CLAIM_OWNER_ID CLAIM_KNOWN_HOSTS CLAIM_DEAD_HOSTS
    # ⛔ THE BOX'S OWN FORMER-NAME HISTORY IS PERSISTED, SO ITS HOME MUST BE HERMETIC AND PER-BOX:
    # one shared file would record every simulated box's name and turn an unrelated "not orphaned"
    # assertion into a false one (a scenario's PEER would look like one of this box's former names).
    # The default is therefore per scenario AND per host — i.e. "one file per box" — and the only
    # scenarios that share a directory are the RENAME ones, which pass CLAIM_STATE_DIR explicitly
    # because a renamed box is the SAME box.
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
# ensure_work_repo <origin> — one work repo per scenario, origin-wired
ensure_work_repo() {
  rm -rf "$T/repo" 2>/dev/null
  "$REAL_GIT" init -q "$T/repo" || return 1
  "$REAL_GIT" -C "$T/repo" remote add origin "$1" || return 1
}
# lease_msg <origin> <ref> -> the claim commit's message ("owner=… lease_until=… nonce=…") or ""
lease_msg() {
  local ref="$2" cur
  cur="$("$REAL_GIT" -C "$T/repo" ls-remote origin "$ref" 2>/dev/null | awk '{print $1}')"
  [ -n "$cur" ] || return 1
  "$REAL_GIT" -C "$T/repo" fetch -q origin "+$ref:refs/tmp/orphan-read" 2>/dev/null || return 1
  "$REAL_GIT" -C "$T/repo" cat-file commit refs/tmp/orphan-read 2>/dev/null \
    | sed -n '/^$/,$p' | tail -n +2 | tr -d '\r'
  "$REAL_GIT" -C "$T/repo" update-ref -d refs/tmp/orphan-read 2>/dev/null
  return 0
}
lease_owner() { lease_msg "$1" "$2" | sed -n 's/.*owner=\([^ ]*\).*/\1/p'; }
lease_until() { lease_msg "$1" "$2" | sed -n 's/.*lease_until=\([0-9]*\).*/\1/p'; }
has_ref() { [ -n "$("$REAL_GIT" -C "$T/repo" ls-remote origin "$2" 2>/dev/null)" ]; }
now_s() { date +%s; }

# ══ O6: the owner is re-derived every call, and a STALE configured owner is rejected loudly ══
# This is the root cause named in the issue: `CLAIM_OWNER_ID` cached before the rename keeps
# stamping the dead host, so the fix cannot be "read the host once at source time".
echo "── O6: claim_owner() re-derives the host per call; a stale CLAIM_OWNER_ID is REJECTED ──"
O6="$(as_box "" hostNew '
  a="$(claim_owner)"
  CLAIM_OWNER_HOST=hostRenamedAgain
  b="$(claim_owner)"
  printf "FIRST=%s\nSECOND=%s\n" "$a" "$b"
' 2>&1)"
FIRST="$(field "$O6" FIRST)"; SECOND="$(field "$O6" SECOND)"
[ "${FIRST%%:*}" = "hostNew" ]; ck "O6 [RED→GREEN] claim_owner() stamps the running host (got '${FIRST}')" $?
[ "${SECOND%%:*}" = "hostRenamedAgain" ]; ck "O6 [RED→GREEN] a RENAME between two calls is visible in the second stamp — the host is not cached (got '${SECOND}')" $?

# A configured CLAIM_OWNER_ID naming a host that does not exist must not be stamped. It is
# REJECTED with a message naming the stale host, and the RUNNING host is used instead — never the
# other way round, because silently keeping the dead name is the incident.
O6B="$(as_box "" realhost 'printf "OWNER=%s\n" "$(claim_owner)"' CLAIM_OWNER_ID=ghosthost 2>&1)"
OWN="$(field "$O6B" OWNER)"
[ "${OWN%%:*}" = "realhost" ]; ck "O6 [RED→GREEN] a CLAIM_OWNER_ID with a foreign host is REJECTED — the claim is stamped with the RUNNING host (got '${OWN}')" $?
printf '%s' "$O6B" | grep -q 'REJECTED CLAIM_OWNER_ID'; ck "O6 [RED→GREEN] the rejection is LOUD (names CLAIM_OWNER_ID on stderr)" $?
printf '%s' "$O6B" | grep -q 'REJECTED CLAIM_OWNER_ID=[^ ]*ghosthost'; ck "O6 [RED→GREEN] the rejection itself names the stale host it refused ('ghosthost')" $?
# And the matching case must stay silent: a correctly configured owner is not a warning.
O6C="$(as_box "" realhost 'printf "OWNER=%s\n" "$(claim_owner)"' CLAIM_OWNER_ID=realhost 2>&1)"
CK_OWNER="$(field "$O6C" OWNER)"
[ "${CK_OWNER%%:*}" = "realhost" ]; ck "O6 [PINNED] a CLAIM_OWNER_ID that DOES match the running host is honoured" $?
printf '%s' "$O6C" | grep -q 'REJECTED'; [ $? -ne 0 ]; ck "O6 [PINNED] no rejection is printed when the configured host matches" $?

# ══ O1: the incident — RENAME mid-run, the claim must still be reclaimable ══
echo
echo "── O1: a host RENAME mid-run leaves the outstanding claim reclaimable ──────────────"
ORIG="$(mk_origin o1)" || { echo "❌ fixture"; exit 2; }
ensure_work_repo "$ORIG" || { echo "❌ fixture"; exit 2; }
ISSUE=9209401
STAMP="$(as_box "$ORIG" Daniels-MacBook-Air 'claim_issue_acquire "" '"$ISSUE"' >/dev/null 2>&1
  printf "RC=%s\nRESULT=%s\n" "$?" "${CLAIM_RESULT:-}"')"
STAMP_RES="$(field "$STAMP" RESULT)"
[ "$(field "$STAMP" RC)" = "0" ]; STAMP_RC=$?
ck "O1 (setup) the first host acquires the claim (result='$STAMP_RES')" $STAMP_RC
REF1="refs/claims/issue-$ISSUE"
UNTIL1="$(lease_until "$ORIG" "$REF1")"; OWNER1="$(lease_owner "$ORIG" "$REF1")"
[ -n "$UNTIL1" ] && [ "$UNTIL1" -gt "$(now_s)" ]
ck "O1 (setup) the lease is in the FUTURE (until=$UNTIL1) — so expiry cannot be what frees it" $?
# ⚠️ THIS IS A RED→GREEN ASSERTION, NOT SETUP: the pre-fix writer ignores the simulated box's host and
# stamps `$(hostname -s)`, so "stamped with the OLD host" only holds once `claim_host()` is honoured.
case "$OWNER1" in Daniels-MacBook-Air:*) ok "O1 [RED→GREEN] (setup) the claim is stamped with the OLD host ($OWNER1)" ;;
  *) bad "O1 [RED→GREEN] (setup) the claim is stamped with the OLD host (got '$OWNER1')" ;; esac

# The box is renamed. Same machine, new host name; the fleet roster is the NEW name only, which is
# the "not in a known-hosts list" condition the issue specifies.
RENAMED="$(as_box "$ORIG" Daniels-MacBook-Air-new 'claim_issue_acquire "" '"$ISSUE"' >/dev/null 2>&1
  printf "RC=%s\nRESULT=%s\n" "$?" "${CLAIM_RESULT:-}"' CLAIM_KNOWN_HOSTS=Daniels-MacBook-Air-new)"
RC1="$(field "$RENAMED" RC)"; RES1="$(field "$RENAMED" RESULT)"
[ "$RC1" = "0" ]; ck "O1 [RED→GREEN] after the rename the claim is RECLAIMED, not refused — rc=$RC1 result='$RES1'" $?
case "$RES1" in
  *rphan*) ok "O1 [RED→GREEN] the reclaim says WHY (the owner host is orphaned): '$RES1'" ;;
  *) bad "O1 [RED→GREEN] the reclaim names the orphaned host (got '$RES1')" ;;
esac
LEASE2_OWNER="$(lease_owner "$ORIG" "$REF1")"
case "$LEASE2_OWNER" in "Daniels-MacBook-Air-new:"*) ok "O1 the claim now belongs to the RUNNING host ($LEASE2_OWNER)" ;;
  *) bad "O1 the claim now belongs to the running host (got '$LEASE2_OWNER')" ;; esac

# ══ O4: a KNOWN live peer is NOT orphaned — the fail-open this change could introduce ══
echo
echo "── O4: a claim held by a KNOWN fleet host is NOT reclaimed (no stealing a live peer) ──"
ORIG4="$(mk_origin o4)"; ensure_work_repo "$ORIG4" || { echo "❌ fixture"; exit 2; }
ISSUE4=9209404
as_box "$ORIG4" peerbox 'claim_issue_acquire "" '"$ISSUE4"' >/dev/null 2>&1; printf "RC=%s\n" "$?"' >/dev/null
STEAL="$(as_box "$ORIG4" mybox 'claim_issue_acquire "" '"$ISSUE4"' >/dev/null 2>&1
  printf "RC=%s\nRESULT=%s\n" "$?" "${CLAIM_RESULT:-}"' CLAIM_KNOWN_HOSTS='mybox peerbox')"
RC4="$(field "$STEAL" RC)"; RES4="$(field "$STEAL" RESULT)"
[ "$RC4" = "1" ]; ck "O4 [PINNED] a claim from a KNOWN host is still refused (rc=$RC4, '$RES4')" $?
case "$RES4" in
  *held-by-live*) ok "O4 [RED→GREEN] the refusal names held-by-live — the dispatcher can tell it from an orphan ('$RES4')" ;;
  *) bad "O4 [RED→GREEN] the refusal names held-by-live (got '$RES4')" ;;
esac
# With NO roster configured a foreign host must never be assumed dead: fail safe, not fail open.
STEAL2="$(as_box "$ORIG4" mybox 'claim_issue_acquire "" '"$ISSUE4"' >/dev/null 2>&1; printf "RC=%s\n" "$?"')"
[ "$(field "$STEAL2" RC)" = "1" ]; ck "O4 [PINNED] with NO known-hosts roster a foreign holder is NOT orphaned (fail-safe default)" $?
# An explicit DEAD-host roster is the other supported form: it must orphan that host, and only it.
as_box "$ORIG4" peerbox 'claim_issue_acquire "" 9209407 >/dev/null 2>&1; printf "RC=%s\n" "$?"' >/dev/null
DEADLIST="$(as_box "$ORIG4" mybox 'claim_issue_acquire "" 9209407 >/dev/null 2>&1
  printf "RC=%s\nRESULT=%s\n" "$?" "${CLAIM_RESULT:-}"' CLAIM_DEAD_HOSTS=peerbox)"
[ "$(field "$DEADLIST" RC)" = "0" ]; ck "O4 [RED→GREEN] a host on the DEAD-host roster is reclaimed (CLAIM_DEAD_HOSTS=peerbox)" $?

# ══ O5: the LOCAL rule — same host, dead pid, on a **PR** claim ══
# ⛔ A PR CLAIM IS THE ONLY KEYING THE PID RULE MAY JUDGE (agent-infra#2094 cycle 2). A PR claim is
# minted by the WORKER (`merge-one.sh`/`fix-one.sh` lease it for their own lifetime), so "the minting
# pid is gone" means "no worker holds this". An ISSUE claim is minted by the CONTROLLER and released
# by the CHAIN — different processes — so a controller restart (every deploy) leaves the lane working
# with the claiming pid gone. Judging that by the pid deletes the SHARED barrier and a peer dispatches
# the same issue: the duplicate the registry exists to prevent. O15 pins that exclusion.
echo
echo "── O5: the LOCAL rule (no roster needed): same host + dead pid on a PR claim ────────"
ORIG5="$(mk_origin o5)"; ensure_work_repo "$ORIG5" || { echo "❌ fixture"; exit 2; }
PR5=9209405; SHA5=0123456789abcdef0123; REF5=refs/claims/9209405-0123456789ab
as_box "$ORIG5" localbox 'c="$(_claim_commit "localbox:999999" "$(( $(date +%s) + 7200 ))")"
  _git push -q origin "$c:refs/claims/9209405-0123456789ab" 2>/dev/null; printf "PUSHED=%s\n" "$?"' >/dev/null
has_ref "$ORIG5" "$REF5"
ck "O5 (setup) a PR lease naming a DEAD pid on the running host is planted" $?
DEADRC="$(as_box "$ORIG5" localbox 'claim_acquire "" '"$PR5 $SHA5"' >/dev/null 2>&1
  printf "RC=%s\nRESULT=%s\n" "$?" "${CLAIM_RESULT:-}"')"
DEADRCRES="$(field "$DEADRC" RESULT)"
[ "$(field "$DEADRC" RC)" = "0" ]; DEADRC_RC=$?
ck "O5 [RED→GREEN] same host + DEAD pid is reclaimable immediately, regardless of the future lease ('$DEADRCRES')" $DEADRC_RC
# A LIVE pid on this host must not be touched, even with no roster at all.
ALIVE_OWN="alivebox:$$"
as_box "$ORIG5" alivebox 'c="$(_claim_commit "'"$ALIVE_OWN"'" "$(( $(date +%s) + 7200 ))")"
  _git push -q origin "$c:refs/claims/9209406-0123456789ab" 2>/dev/null; printf "PUSHED=%s\n" "$?"' >/dev/null
ALIVERC="$(as_box "$ORIG5" alivebox 'claim_acquire "" 9209406 0123456789abcdef0123 >/dev/null 2>&1
  printf "RC=%s\nRESULT=%s\n" "$?" "${CLAIM_RESULT:-}"')"
ALIVERES="$(field "$ALIVERC" RESULT)"
[ "$(field "$ALIVERC" RC)" = "1" ]; ALIVE_RC=$?
ck "O5 [PINNED] same host + a LIVE pid is NOT orphaned ('$ALIVERES')" $ALIVE_RC

# ══ O15: an ISSUE claim is NOT judged by the local pid — a controller restart must not open the
#         duplicate window on the shared queue ══
# The failure this pins, measured in review: peer pre-flight `held-by-live` for issue N, our prune
# `pruned orphaned-host` on the pid rule, peer then `no claim on #N` and dispatches it. Two lanes, one
# issue, both believing they hold it — on the keying whose whole purpose is to stop that. The lease
# term still bounds a genuinely abandoned issue claim, so nothing is unreclaimable.
echo
echo "── O15: an ISSUE claim is NOT reaped by the local-pid rule (controller ≠ worker) ─────"
ORIG15="$(mk_origin o15)"; ensure_work_repo "$ORIG15" || { echo "❌ fixture"; exit 2; }
as_box "$ORIG15" ctrlbox 'c="$(_claim_commit "ctrlbox:999999" "$(( $(date +%s) + 10800 ))")"
  _git push -q origin "$c:refs/claims/issue-9209450" 2>/dev/null' >/dev/null
has_ref "$ORIG15" refs/claims/issue-9209450; ck "O15 (setup) an ISSUE claim from a DEAD local pid is planted" $?
# ⛔ THE PRUNE MUST RUN FIRST, WHILE THE CLAIM STILL CARRIES THE SYNTHETIC DEAD PID (cycle-6 review).
# Run AFTER the acquire below, that acquire has RE-STAMPED the claim with THIS process's own live pid,
# so `ps -p` reads "live" and both prune assertions passed even with the issue-key exclusion DELETED —
# a false green on the one branch that deletes claims. Measured: acquirer-pid == prune-subshell-pid.
PRUNE15="$(as_box "$ORIG15" ctrlbox 'claim_prune' 2>&1)"
has_ref "$ORIG15" refs/claims/issue-9209450; P15A=$?
ck "O15 [RED→GREEN] claim_prune does NOT delete a dead-pid ISSUE claim (ref still on the origin)" $P15A
printf '%s' "$PRUNE15" | grep -q 'issue-9209450' && PR15=1 || PR15=0
ck "O15 [RED→GREEN] the prune does not even NAME it as reaped" $PR15
# ... and the acquire agrees: the claim reads LIVE, so a peer still sees the barrier.
RESTART="$(as_box "$ORIG15" ctrlbox 'claim_issue_acquire "" 9209450 >/dev/null 2>&1
  printf "RC=%s\nRESULT=%s\n" "$?" "${CLAIM_RESULT:-}"')"
R15="$(field "$RESTART" RC)"; R15RES="$(field "$RESTART" RESULT)"
[ "$R15" = "1" ]; R15_RC=$?
ck "O15 [PINNED] an ISSUE claim with a DEAD local pid is still LIVE (rc=$R15 — a restart must not free the issue) ('$R15RES')" $R15_RC
case "$R15RES" in
  *held-by-live*) ok "O15 [PINNED] it reads held-by-live, so a peer still sees the barrier" ;;
  *) bad "O15 [PINNED] it reads held-by-live (got '$R15RES')" ;;
esac
# Non-vacuity for this pair: the SAME dead pid on a PR claim IS reaped by that prune, so the exclusion
# is specific to the keying and not the whole rule being dead.
as_box "$ORIG15" ctrlbox 'c="$(_claim_commit "ctrlbox:999999" "$(( $(date +%s) + 7200 ))")"
  _git push -q origin "$c:refs/claims/9209451-0123456789ab" 2>/dev/null' >/dev/null
as_box "$ORIG15" ctrlbox 'claim_prune' >/dev/null 2>&1
has_ref "$ORIG15" refs/claims/9209451-0123456789ab && rc15=1 || rc15=0
ck "O15 [RED→GREEN] ... while the SAME dead pid on a PR claim IS pruned (the rule is keyed, not dead)" $rc15

# ══ O9: unparseable lease is still LIVE (must survive the orphan arm) ══
echo
echo "── O9: an unparseable lease stays LIVE even when the owner host looks orphaned ─────"
as_box "$ORIG5" localbox 'c="$(_claim_commit "localbox:999995" 0)"
  _git push -q origin "$c:refs/claims/issue-9209408" 2>/dev/null; printf "PUSHED=%s\n" "$?"' >/dev/null
NOLEASE="$(as_box "$ORIG5" localbox 'claim_issue_acquire "" 9209408 >/dev/null 2>&1
  printf "RC=%s\nRESULT=%s\n" "$?" "${CLAIM_RESULT:-}"')"
NOLRES="$(field "$NOLEASE" RESULT)"
[ "$(field "$NOLEASE" RC)" = "1" ]; NOL_RC=$?
ck "O9 [PINNED] a claim with no parseable lease reads LIVE, not orphaned ('$NOLRES')" $NOL_RC

# ══ O2/O3: claim_prune reaps by ORPHANED HOST as well as by EXPIRY ══
echo
echo "── O2/O3: claim_prune reaps by orphaned host AND still by expiry ───────────────────"
ORIG2="$(mk_origin o2)"; ensure_work_repo "$ORIG2" || { echo "❌ fixture"; exit 2; }
as_box "$ORIG2" oldhost 'c="$(_claim_commit "oldhost:999998" "$(( $(date +%s) + 10800 ))")"
  _git push -q origin "$c:refs/claims/issue-9209411" 2>/dev/null' >/dev/null
as_box "$ORIG2" oldhost 'c="$(_claim_commit "oldhost:999997" "1000000000")"
  _git push -q origin "$c:refs/claims/issue-9209412" 2>/dev/null' >/dev/null
as_box "$ORIG2" peerhost 'c="$(_claim_commit "peerhost:1" "$(( $(date +%s) + 10800 ))")"
  _git push -q origin "$c:refs/claims/issue-9209413" 2>/dev/null' >/dev/null
has_ref "$ORIG2" refs/claims/issue-9209411 && has_ref "$ORIG2" refs/claims/issue-9209412 \
  && has_ref "$ORIG2" refs/claims/issue-9209413
ck "O2 (setup) the three fixture claims are on the origin" $?
PRUNE="$(as_box "$ORIG2" newhost 'claim_prune' CLAIM_KNOWN_HOSTS='newhost peerhost')"
printf '%s' "$PRUNE" | grep -q 'refs/claims/issue-9209411'; ck "O2 [RED→GREEN] claim_prune reaps the ORPHANED-HOST claim (lease had hours left)" $?
printf '%s' "$PRUNE" | grep -qi 'orphan'; ck "O2 [RED→GREEN] the orphan reap says so by name" $?
has_ref "$ORIG2" "refs/claims/issue-9209411" && rc=1 || rc=0
ck "O2 [RED→GREEN] the orphaned-host claim is gone from the origin" $rc
printf '%s' "$PRUNE" | grep -q 'refs/claims/issue-9209412'; ck "O3 [PINNED] claim_prune still reaps the EXPIRED claim" $?
has_ref "$ORIG2" "refs/claims/issue-9209412" && rc=1 || rc=0
ck "O3 [PINNED] the expired claim is gone from the origin" $rc
has_ref "$ORIG2" "refs/claims/issue-9209413"; ck "O4 [PINNED] the KNOWN live host's claim SURVIVED the prune" $?

# ══ O8: the PRE-FLIGHT must read an orphaned claim as CLEAN, a live peer's as COLLISION ══
echo
echo "── O8: the pre-flight distinguishes a reclaimable claim from a LIVE peer's ─────────"
ORIG8="$(mk_origin o8)"; ensure_work_repo "$ORIG8" || { echo "❌ fixture"; exit 2; }
as_box "$ORIG8" ghostbox 'c="$(_claim_commit "ghostbox:999996" "$(( $(date +%s) + 10800 ))")"
  _git push -q origin "$c:refs/claims/issue-9209421" 2>/dev/null' >/dev/null
PRE_ORPH="$(as_box "$ORIG8" mybox 'claim_issue_preflight "9209421" >/dev/null 2>&1
  printf "RC=%s\nRESULT=%s\n" "$?" "${CLAIM_RESULT:-}"' CLAIM_KNOWN_HOSTS=mybox)"
P8="$(field "$PRE_ORPH" RC)"; P8RES="$(field "$PRE_ORPH" RESULT)"
[ "$P8" = "0" ]; P8_RC=$?
ck "O8 [RED→GREEN] the pre-flight returns CLEAN (0) for an ORPHANED claim — rc=$P8 '$P8RES'" $P8_RC
as_box "$ORIG8" peer2 'claim_issue_acquire "" 9209422 >/dev/null 2>&1' >/dev/null
PRE_LIVE="$(as_box "$ORIG8" mybox 'claim_issue_preflight "9209422" >/dev/null 2>&1
  printf "RC=%s\nRESULT=%s\n" "$?" "${CLAIM_RESULT:-}"' CLAIM_KNOWN_HOSTS='mybox peer2')"
P8L="$(field "$PRE_LIVE" RC)"
[ "$P8L" = "1" ]; ck "O8 [PINNED] the pre-flight still refuses a LIVE peer's claim (rc=$P8L)" $?
case "$(field "$PRE_LIVE" RESULT)" in
  *held-by-live*) ok "O8 [RED→GREEN] the pre-flight's COLLISION names held-by-live" ;;
  *) bad "O8 [RED→GREEN] the pre-flight's COLLISION names held-by-live (got '$(field "$PRE_LIVE" RESULT)')" ;;
esac

# ══ O7: the stamped term is bounded by the TTL that governs the keying ══
# ⛔ THE BOUND IS PER KEYING AND IT IS A CEILING, NOT THE DEFAULT. The shipped callers lease a PR
# claim for MORE than `CLAIM_TTL`: merge-one.sh asks REVIEW_TIMEOUT+1200 (=3000s) and fix-one.sh asks
# FIX_TIMEOUT+1200 (=3600s), both deliberately, because the lease has to cover the review+merge the
# claim is taken for. So "term <= 1800" is NOT the invariant — an assertion of it would redden the
# merge path. What must hold, and what the incident actually violated, is that no lease can exceed
# the DOCUMENTED CEILING for its keying (`CLAIM_TTL_MAX`, `CLAIM_ISSUE_TTL`) — i.e. no caller can
# silently mint a term that outlives every reaper's reach, which is how a 157-minute lease on a
# renamed host became unreclaimable.
echo "── O7: the stamped lease term <= the CEILING for that keying (no silent extension) ──"
ORIG7="$(mk_origin o7)"; ensure_work_repo "$ORIG7" || { echo "❌ fixture"; exit 2; }
PVAL="$(as_box "$ORIG7" tbox 'printf "%s\n" "$CLAIM_TTL"')"
[ "$PVAL" = "1800" ]; ck "O7 the PR claim's default TTL is 1800s (got '$PVAL')" $?
# (a) the DEFAULT term
as_box "$ORIG7" tbox 'claim_acquire "" 9209431 0123456789abcdef0123 >/dev/null 2>&1' >/dev/null
U7="$(lease_until "$ORIG7" refs/claims/9209431-0123456789ab)"; NOW7="$(now_s)"
[ -n "$U7" ] && [ "$(( U7 - NOW7 ))" -le 1800 ] && [ "$(( U7 - NOW7 ))" -gt 1700 ]
ck "O7 [RED→GREEN] a PR claim with no explicit ttl is stamped <= CLAIM_TTL=1800s (term=$(( ${U7:-0} - NOW7 ))s)" $?
# (b) the shipped merge lease (3000s) must still be HONOURED — this is the PINNED half, so the
# ceiling cannot be implemented by clamping everything to the default.
as_box "$ORIG7" tbox 'claim_acquire "" 9209435 0123456789abcdef0123 3000 >/dev/null 2>&1' >/dev/null
U7M="$(lease_until "$ORIG7" refs/claims/9209435-0123456789ab)"; NOW7M="$(now_s)"
[ -n "$U7M" ] && [ "$(( U7M - NOW7M ))" -gt 2900 ]
ck "O7 [PINNED] merge-one.sh's 3000s lease is still honoured (term=$(( ${U7M:-0} - NOW7M ))s)" $?
# (c) a term above the ceiling is CLAMPED — the silent extension the incident exposed.
CEIL="$(as_box "$ORIG7" tbox 'printf "%s\n" "${CLAIM_TTL_MAX:-}"')"
[ "${CEIL:-0}" -gt 0 ]; ck "O7 the PR keying declares a documented ceiling (CLAIM_TTL_MAX=${CEIL:-unset})" $?
as_box "$ORIG7" tbox 'claim_acquire "" 9209434 0123456789abcdef0123 999999999 >/dev/null 2>&1' >/dev/null
U7B="$(lease_until "$ORIG7" refs/claims/9209434-0123456789ab)"; NOW7B="$(now_s)"
[ -n "$U7B" ] && [ "$(( U7B - NOW7B ))" -le "${CEIL:-1800}" ]
ck "O7 [RED→GREEN] a ttl ABOVE the ceiling cannot mint a term past it (term=$(( ${U7B:-0} - NOW7B ))s, ceiling=${CEIL:-?}s)" $?
IVAL="$(as_box "$ORIG7" tbox 'printf "%s\n" "$CLAIM_ISSUE_TTL"')"
[ "$IVAL" = "10800" ]; ck "O7 the ISSUE claim's default TTL is 10800s (got '$IVAL')" $?
as_box "$ORIG7" tbox 'claim_issue_acquire "" 9209432 >/dev/null 2>&1' >/dev/null
U8="$(lease_until "$ORIG7" refs/claims/issue-9209432)"; NOW8="$(now_s)"
[ -n "$U8" ] && [ "$(( U8 - NOW8 ))" -le 10800 ] && [ "$(( U8 - NOW8 ))" -gt 10600 ]
ck "O7 [RED→GREEN] an ISSUE claim's stamped term is <= CLAIM_ISSUE_TTL=10800s (term=$(( ${U8:-0} - NOW8 ))s)" $?
# ⚠️ The incident's 157-minute lease is THIS one: CLAIM_ISSUE_TTL (10800s = 180 min) on an ISSUE
# claim, by design (its own comment derives 3h from LANE_TIMEOUT + chain-merge + review). It is
# asserted here so the number is BOUNDED and visible, not so it is silently lowered.
as_box "$ORIG7" tbox 'claim_issue_acquire "" 9209436 999999999 >/dev/null 2>&1' >/dev/null
U8B="$(lease_until "$ORIG7" refs/claims/issue-9209436)"; NOW8B="$(now_s)"
[ -n "$U8B" ] && [ "$(( U8B - NOW8B ))" -le 10800 ]
ck "O7 [RED→GREEN] an ISSUE ttl above CLAIM_ISSUE_TTL is clamped to it (term=$(( ${U8B:-0} - NOW8B ))s)" $?
# An unparseable ttl must fall back to the keying's own default — never to the PR's shorter one.
as_box "$ORIG7" tbox 'claim_issue_acquire "" 9209433 07 >/dev/null 2>&1' >/dev/null
U9="$(lease_until "$ORIG7" refs/claims/issue-9209433)"; NOW9="$(now_s)"
[ -n "$U9" ] && [ "$(( U9 - NOW9 ))" -le 10800 ] && [ "$(( U9 - NOW9 ))" -gt 1800 ]
ck "O7 [PINNED] an unparseable ttl falls back to the ISSUE default (10800s), never the PR's shorter one (term=$(( ${U9:-0} - NOW9 ))s)" $?

# ══ O10: the RENAME SELF-HEALS with NO roster at all (the shipped default) ══
# The incident's blocked dispatch was the SAME box refusing its OWN lease minutes after it was
# renamed, and nothing in this repo ships a roster. So the box remembers the names it has carried
# (`state/claim-hosts`) and treats its own former names as dead. The blast radius is its own history,
# by construction — and the history is written ONLY from the real hostname, never from a seam, so a
# simulated peer can never become "a former name of this box".
echo
echo "── O10: a rename self-heals with NO roster (the box's own former name is dead) ──────"
ORIG10="$(mk_origin o10)"; ensure_work_repo "$ORIG10" || { echo "❌ fixture"; exit 2; }
ISSUE10=9209430
CS10="$T/cs-o10"; mkdir -p "$CS10"
# (a) the SEAM CANNOT POISON THE HISTORY: presenting as another box writes nothing.
as_box "$ORIG10" boxOldName 'claim_issue_acquire "" '"$ISSUE10"' >/dev/null 2>&1' CLAIM_STATE_DIR="$CS10" >/dev/null
if [ -s "$CS10/claim-hosts" ]; then
  SEAMLEAK=1
else SEAMLEAK=0; fi
ck "O10 [PINNED] a seam identity is NOT recorded as one of this machine's names" $SEAMLEAK
# (b) the PERSISTED history is what the rule reads: the name the box wore BEFORE the rename, exactly
# as `claim_owner` would have recorded it while that name was current. (The recorder is gated on the
# real hostname, so under this seam the file is seeded directly — same datum, same reader.)
printf '%s\n' "boxOldName" > "$CS10/claim-hosts"
has_ref "$ORIG10" "refs/claims/issue-$ISSUE10"; ck "O10 (setup) the pre-rename host took the claim" $?
SELFHEAL="$(as_box "$ORIG10" boxNewName 'claim_issue_acquire "" '"$ISSUE10"' >/dev/null 2>&1
  printf "RC=%s\nRESULT=%s\n" "$?" "${CLAIM_RESULT:-}"' CLAIM_STATE_DIR="$CS10")"
SH10_RES="$(field "$SELFHEAL" RESULT)"
[ "$(field "$SELFHEAL" RC)" = "0" ]; SH10_RC=$?
ck "O10 [RED→GREEN] after the rename the claim is reclaimed with NO roster configured ('$SH10_RES')" $SH10_RC
case "$SH10_RES" in *FORMER*) SH10_TOK=0 ;; *) SH10_TOK=1 ;; esac
ck "O10 [RED→GREEN] the reason names the FORMER name as the cause ('$SH10_RES')" $SH10_TOK
# ... and a name this box NEVER carried is not on that list, so a peer is not reaped by it.
as_box "$ORIG10" peerTen 'claim_issue_acquire "" 9209437 >/dev/null 2>&1' CLAIM_STATE_DIR="$T/cs-o10peer" >/dev/null
NOFALSE="$(as_box "$ORIG10" boxNewName 'claim_issue_acquire "" 9209437 >/dev/null 2>&1
  printf "RC=%s\n" "$?"' CLAIM_STATE_DIR="$CS10")"
[ "$(field "$NOFALSE" RC)" = "1" ]; ck "O10 [PINNED] a PEER host that was never this box's name is NOT reclaimed" $?

# ══ O11: an INSTRUMENT FAILURE is not a death certificate ══
# `ps -p` has three outcomes (found / absent / could not tell). Folding the third into "absent" turns
# a broken probe into a steal of EVERY same-host claim, so the local rule requires a positive witness:
# a ps that cannot see this very process cannot witness anyone's death.
echo
echo "── O11: a ps that cannot answer must NOT read as \"the pid is gone\" ───────────────"
ORIG11="$(mk_origin o11)"; ensure_work_repo "$ORIG11" || { echo "❌ fixture"; exit 2; }
mkdir -p "$T/bin-badps"
printf '#!/bin/sh\nexit 1\n' > "$T/bin-badps/ps"; chmod +x "$T/bin-badps/ps"
as_box "$ORIG11" probeBox 'c="$(_claim_commit "probeBox:'"$$"'" "$(( $(date +%s) + 7200 ))")"
  _git push -q origin "$c:refs/claims/9209424-0123456789ab" 2>/dev/null' >/dev/null
BLINDPS="$(as_box "$ORIG11" probeBox 'claim_acquire "" 9209424 0123456789abcdef0123 >/dev/null 2>&1
  printf "RC=%s\nRESULT=%s\n" "$?" "${CLAIM_RESULT:-}"' PATH="$T/bin-badps:$PATH")"
BL_RES="$(field "$BLINDPS" RESULT)"
[ "$(field "$BLINDPS" RC)" = "1" ]; BL_RC=$?
ck "O11 [PINNED] a blind ps does NOT orphan a LIVE pid's claim (rc should be 1) — '$BL_RES'" $BL_RC

# ══ O12: a roster that does not name THIS box is stale, and must ABSTAIN ══
# The trigger for a stale roster IS a rename, so acting on it would reap the renamed box's live claims
# fleet-wide — the opposite of the fix. Abstaining costs an under-reap, which the lease bounds.
echo
echo "── O12: a roster that omits the RUNNING host abstains instead of reaping a peer ────"
ORIG12="$(mk_origin o12)"; ensure_work_repo "$ORIG12" || { echo "❌ fixture"; exit 2; }
# ⛔ THE CLAIM MUST BE HELD BY A HOST THE ROSTER DOES **NOT** NAME (agent-infra#2094 cycle-5 review).
# The first fixture planted it on `peerTwelve`, which the roster DID list — so the "listed -> live" arm
# answered and the assertion passed with or without the staleness guard (mutation: deleting the guard
# kept every suite green). With a THIRD host absent from the roster the only thing that can save the
# claim is the abstention, and the steal it prevents is fleet-wide.
as_box "$ORIG12" peerThirteen 'claim_issue_acquire "" 9209425 >/dev/null 2>&1' >/dev/null
STALE="$(as_box "$ORIG12" renamedBox 'claim_issue_acquire "" 9209425 >/dev/null 2>&1
  printf "RC=%s\nRESULT=%s\n" "$?" "${CLAIM_RESULT:-}"' CLAIM_KNOWN_HOSTS='peerTwelve otherhost')"
[ "$(field "$STALE" RC)" = "1" ]
# ⛔ `$?` MUST BE CAPTURED BEFORE THE LABEL (agent-infra#2094 cycle-5, measured): the label below embeds
# a `$(field …)` COMMAND SUBSTITUTION, which resets `$?` to the substitution's status (0). That made this
# assertion print ✅ with `rc=0` — a false green that survived the very mutation it exists for.
O12_RC1=$?
ck "O12 [RED→GREEN] a roster that does not list the RUNNING host does not authorise a reap (rc=$(field "$STALE" RC))" $O12_RC1
# ⛔ SURVIVAL MEANS THE HOLDER IS UNCHANGED, not that the ref exists: a RECLAIM leaves the ref in place
# under a new owner, so `has_ref` passed while the peer's claim had just been taken (measured under the
# mutation). The owner is the datum.
OWN12="$(lease_owner "$ORIG12" refs/claims/issue-9209425)"
case "$OWN12" in
  peerThirteen:*) O12_RC3=0 ;;
  *) O12_RC3=1 ;;
esac
ck "O12 [RED→GREEN] the claim from the unlisted THIRD host still belongs to IT (owner '$OWN12')" $O12_RC3
# And a roster that DOES name this box still reaps a host it omits — the rule is not "never reap".
as_box "$ORIG12" listerBox 'claim_issue_acquire "" 9209425 >/dev/null 2>&1' >/dev/null
LISTED="$(as_box "$ORIG12" listerBox 'claim_issue_acquire "" 9209425 >/dev/null 2>&1; printf "RC=%s\n" "$?"' CLAIM_KNOWN_HOSTS='listerBox')"
[ "$(field "$LISTED" RC)" = "0" ]
O12_RC2=$?
ck "O12 [PINNED] ... while a roster that names the RUNNING host and omits the holder DOES reap it (rc=$(field "$LISTED" RC))" $O12_RC2

# ══ O13: a full identity in CLAIM_OWNER_ID is refused (it would stamp host:pid:pid) ══
echo
echo "── O13: a CLAIM_OWNER_ID carrying its own pid is REJECTED ──────────────────────────"
O13="$(as_box "" realhost 'printf "OWNER=%s\n" "$(claim_owner)"' CLAIM_OWNER_ID='realhost:41679' 2>&1)"
O13OWN="$(field "$O13" OWNER)"
[ "$O13OWN" = "realhost:$$" ]
ck "O13 [RED→GREEN] CLAIM_OWNER_ID=host:pid is refused and the running host+pid is stamped (got '$O13OWN')" $?
printf '%s' "$O13" | grep -q 'REJECTED CLAIM_OWNER_ID'; ck "O13 [RED→GREEN] the refusal is loud" $?

# ══ O14: the ceiling clamp is LOUD ══
# A silent clamp is what makes a mid-review expiry undiagnosable: merge-one.sh derives its lease from
# REVIEW_TIMEOUT and would never know the ceiling had shortened it.
echo
echo "── O14: clamping a ttl to the ceiling says so ─────────────────────────────────────"
ORIG14="$(mk_origin o14)"; ensure_work_repo "$ORIG14" || { echo "❌ fixture"; exit 2; }
CLAMP="$(as_box "$ORIG14" tbox 'claim_acquire "" 9209440 0123456789abcdef0123 999999999 >/dev/null
  printf "DONE=%s\n" "$?"' 2>&1)"
printf '%s' "$CLAMP" | grep -q 'clamped'
ck "O14 [RED→GREEN] a ttl above the ceiling reports the clamp (stderr) instead of shortening silently" $?
printf '%s' "$CLAMP" | grep -q 'CLAIM_TTL_MAX'
ck "O14 [RED→GREEN] the clamp message names the ceiling knob to raise" $?

# ══ O16: `claim_live()` (orch-loop's PR-keyed reader) applies the SAME orphan rules ══
# ⛔ THE FOURTH CALL SITE, AND THE ONE NO SUITE DROVE (agent-infra#2094 cycle-3 review). An orphan rule
# that only the ISSUE path applies leaves the PR path stuck for the whole lease after a rename — the
# asymmetry that keeps a "fixed" box skipping the PRs it could work. Both pre-existing harnesses drive
# `claim_live` WITHOUT claims.sh (selftest.sh extracts the function standalone; test-gates.sh cats the
# extraction into a stub), so `declare -f claim_orphan_reason` is false there and the branch is never
# entered. This section sources BOTH, so the branch IS executed — and it fails if the guard is
# inverted, the argument order swapped, or the arm deleted.
echo
echo "── O16: claim_live() treats an ORPHANED PR claim as not in flight ─────────────────"
O16="$T/cl16"; mkdir -p "$O16/state"
sed -n '/^claim_live() {/,/^}/p' "$LOOP" > "$O16/claimlive.sh"
[ -s "$O16/claimlive.sh" ] && grep -q 'claim_live()' "$O16/claimlive.sh"
ck "O16 (setup) claim_live() is extractable from the shipped orch-loop.sh" $?
printf '%s\n' "boxOldName" > "$O16/state/claim-hosts"
snap() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" > "$O16/state/claims-snapshot"; }
cl() { # <pr> <sha> [KEY=VAL ...]
  local pr="$1" sha="$2"; shift 2
  ( cd "$T" || exit 1
    O="$O16"; CLAIM_STATE_DIR="$O16/state"; CLAIM_REPO="$T/repo"
    export O CLAIM_STATE_DIR CLAIM_REPO
    local kv; for kv in "$@"; do export "${kv?}"; done
    . "$CLAIMS_SH" || exit 1
    . "$O16/claimlive.sh" || exit 1
    if claim_live "$pr" "$sha"; then echo LIVE; else echo NOTLIVE; fi ) 2>&1
}
FUT=$(( $(date +%s) + 5400 )); SHA16=0123456789abcdef0123
snap refs/claims/9209460-0123456789ab "boxOldName:999" "$FUT"
[ "$(cl 9209460 $SHA16)" = "NOTLIVE" ]
ck "O16 [RED→GREEN] a PR claim stamped by a FORMER name of this box is NOT in flight (the PR is workable again)" $?
snap refs/claims/9209461-0123456789ab "peerBox:999" "$FUT"
[ "$(cl 9209461 $SHA16 CLAIM_KNOWN_HOSTS="$(hostname -s) peerBox")" = "LIVE" ]
ck "O16 [PINNED] a PR claim from a KNOWN live peer IS in flight — the orphan arm cannot steal it" $?
# ⛔ THE OWNER HOST MUST BE THE RUNNING ONE: the pid rule only judges a pid on THIS box (a pid from
# another host is not probeable), so a claim stamped `somePeer:999999` is correctly left alone.
snap refs/claims/9209462-0123456789ab "$(hostname -s):999999" "$FUT"
[ "$(cl 9209462 $SHA16)" = "NOTLIVE" ]
O16_RC=$?
ck "O16 [RED→GREEN] a PR claim whose minting pid is GONE is NOT in flight (PR keying: the pid IS the worker)" $O16_RC
# The ordering guard: an UNPARSEABLE lease keeps its polarity (LIVE) even when the owner host is a
# former name — the orphan rules are a reason to stop trusting a TERM, not evidence about the holder.
snap refs/claims/9209463-0123456789ab "boxOldName:999" "0"
[ "$(cl 9209463 $SHA16)" = "LIVE" ]
ck "O16 [PINNED] an UNPARSEABLE lease stays LIVE in claim_live() too (the orphan arm runs after it)" $?
snap refs/claims/9209464-0123456789ab "peerBox:999" "$FUT"
[ "$(cl 9209464 $SHA16 CLAIM_DEAD_HOSTS=peerBox)" = "NOTLIVE" ]
ck "O16 [RED→GREEN] the DEAD-host roster reaches claim_live() as well (one rule set, four call sites)" $?
# And the branch must be GATED, not unconditional: a call site with no claims.sh loaded behaves as
# before — which is exactly what selftest.sh / test-gates.sh rely on.
# ⛔ `snap` REPLACES the file, so each case must re-write the entry IT names — the last case left only
# 9209464 in place, and a probe against 9209460 would then read "absent" (not live) and prove nothing.
snap refs/claims/9209460-0123456789ab "boxOldName:999" "$FUT"
( cd "$T" || exit 1; O="$O16"; export O; . "$O16/claimlive.sh"; claim_live 9209460 "$SHA16" ) >/dev/null 2>&1
O16G_RC=$?
ck "O16 [PINNED] without claims.sh loaded (the extraction-only harnesses) the pre-existing polarity still runs" $O16G_RC

# ══ O17: the RECORDER writes — the positive half of the former-name rule ══
# ⛔ O10 SEEDS `claim-hosts` BY HAND AND `as_box` ALWAYS SETS THE SEAM, so until this section existed the
# only assertion touching the writer was the NEGATIVE one ("a seam identity is not recorded") — which
# passes when the writer writes NOTHING AT ALL. The recorder is deliberately gated on the seam being
# ABSENT (a simulated box must never become "a former name of this machine"), so this case must call
# `claim_owner` with a real, unset CLAIM_OWNER_HOST. If the write path breaks in production — a wrong
# CLAIM_STATE_DIR under a worker, or the `[ -d ]` guard never being satisfied — the former-name rule
# dies and every other test in this file stays green.
echo
echo "── O17: claim_owner() RECORDS the running host name (what makes a rename self-heal) ─"
O17="$T/cl17"; mkdir -p "$O17/state"
REAL_HOST="$(hostname -s)"
recdrv() { # <state-dir> [allow-missing]
  ( cd "$T" || exit 1
    unset CLAIM_OWNER_HOST CLAIM_OWNER_ID CLAIM_KNOWN_HOSTS CLAIM_DEAD_HOSTS
    CLAIM_REPO="$T/repo"; CLAIM_STATE_DIR="$1"; export CLAIM_REPO CLAIM_STATE_DIR
    . "$CLAIMS_SH" || exit 1
    claim_owner >/dev/null; claim_owner >/dev/null ) 2>&1
}
recdrv "$O17/state" >/dev/null
[ -f "$O17/state/claim-hosts" ] && grep -qx -- "$REAL_HOST" "$O17/state/claim-hosts"
REC_RC=$?
ck "O17 [RED→GREEN] claim_owner() appends the REAL hostname ($REAL_HOST) to state/claim-hosts" $REC_RC
N17="$(grep -cx -- "$REAL_HOST" "$O17/state/claim-hosts" 2>/dev/null || echo 0)"
[ "$N17" = "1" ]
N17_RC=$?
ck "O17 [RED→GREEN] a second claim_owner() call does not duplicate the entry (got ${N17:-0} line(s))" $N17_RC
# And it never conjures the state dir: a box whose state dir does not exist must not have one created.
O17B="$T/cl17-missing"
recdrv "$O17B" >/dev/null
[ ! -e "$O17B" ]
MKD_RC=$?
ck "O17 [RED→GREEN] an ABSENT state dir is not created (recording writes nothing rather than conjuring state)" $MKD_RC

# ══ O18: the SEAM announces what it costs ══
# `CLAIM_OWNER_HOST` is inherited silently by everything a cell starts. Two consequences were invisible:
# it stamps a name these rules cannot judge (so the box cannot reclaim its OWN leases), and it
# suppresses `claim_host_record` (so the rename self-heal goes inert while reporting nothing). The seam
# stays supported — the harnesses and cross-box simulations need it — but it says so, once.
echo
echo "── O18: a CLAIM_OWNER_HOST that differs from the running host WARNS (once) ─────────"
SEAMW="$(as_box "" seamhost 'claim_owner >/dev/null; claim_owner >/dev/null' 2>&1)"
printf '%s' "$SEAMW" | grep -q 'CLAIM_OWNER_HOST=seamhost'
SW1=$?
ck "O18 [RED→GREEN] the warning NAMES the seam value" $SW1
printf '%s' "$SEAMW" | grep -q "$(hostname -s)"
SW2=$?
ck "O18 [RED→GREEN] the warning NAMES the running host it is overriding" $SW2
# ⛔ DRIVEN THROUGH THE SHIPPED PATH, NOT A BARE `claim_owner` CALL (agent-infra#2094 cycle-4 review).
# Every production mint is `CLAIM_OWNER="$(claim_owner)"`, a COMMAND SUBSTITUTION — so a once-flag set
# inside it dies with the subshell. The first version of this check called `claim_owner` directly and
# passed while production warned once per mint; that is the false green it now closes.
ORIG18="$(mk_origin o18)"; ensure_work_repo "$ORIG18" || { echo "❌ fixture"; exit 2; }
# ⚠️ stdout goes to /dev/null but STDERR MUST SURVIVE — the warning is on stderr, so `2>&1` on the
# mint would swallow the very datum this check counts (measured: that mistake read "0 warning(s)").
SEAMW2="$(as_box "$ORIG18" seamhost 'claim_acquire "" 9209470 0123456789abcdef0123 >/dev/null
  claim_acquire "" 9209471 0123456789abcdef0123 >/dev/null' 2>&1)"
SW3="$(printf '%s' "$SEAMW2" | grep -c 'CLAIM_OWNER_HOST=')"
[ "$SW3" = "1" ]
SW3_RC=$?
ck "O18 [RED→GREEN] it fires ONCE per process through the SHIPPED mint path (two acquires, $SW3 warning(s))" $SW3_RC
# Silent when the seam AGREES with the running host — a correctly configured box is not a warning.
SEAMOK="$(as_box "" "$(hostname -s)" 'claim_owner >/dev/null' 2>&1)"
[ -z "$SEAMOK" ]
SW4=$?
ck "O18 [PINNED] no warning when the seam equals the running host" $SW4

# ══ O19: the DESTRUCTIVE arms require positive evidence — an absent ref, or an unverifiable host ══
# Two ways the same steal could arrive that no test pinned (agent-infra#2094 cycle-4 review):
#   (a) `ref` is OPTIONAL, and defaulting the `*)` arm to "probe the pid" put the whole duplicate
#       window one omitted argument away — a one-arg call would pid-judge an ISSUE-keyed owner;
#   (b) the former-name rule compares against the RUNNING host, so a probe that cannot answer (empty
#       or `claim_host`'s `box` sentinel) makes this box's OWN CURRENT NAME look FORMER — the steal
#       direction. Every other probe in the file abstains when it cannot answer; so must this one.
echo
echo "── O19: no ref, and no verifiable host, both ABSTAIN (never the steal direction) ─────"
ORIG19="$(mk_origin o19)"; ensure_work_repo "$ORIG19" || { echo "❌ fixture"; exit 2; }
# (a) ONE ARG: the owner is on THIS host with a DEAD pid, which is an ISSUE claim's shape.
NOREF="$(as_box "$ORIG19" thisbox 'printf "RC1=%s\nR1=%s\n" \
  "$( claim_orphan_reason "thisbox:999999" >/dev/null 2>&1; echo $? )" \
  "$( claim_orphan_reason "thisbox:999999" )"' 2>/dev/null)"
NR_RC="$(field "$NOREF" RC1)"
[ "$NR_RC" = "1" ]
O19A_RC=$?
ck "O19 [RED→GREEN] an ABSENT ref does NOT authorise the pid rule (one-arg call returns 1, got '$NR_RC')" $O19A_RC
# ... and the SAME owner WITH a PR key IS judged by the pid (the contrast that makes the above a rule).
PRKEY="$(as_box "$ORIG19" thisbox 'claim_orphan_reason "thisbox:999999" "refs/claims/9209475-0123456789ab" >/dev/null 2>&1; echo $?')"
[ "$PRKEY" = "0" ]
O19B_RC=$?
ck "O19 [RED→GREEN] the SAME owner WITH a PR ref IS orphaned (the rule is keyed, not disabled)" $O19B_RC
# (b) a `hostname` that cannot answer must not turn the RUNNING host into "a former name".
# ⛔ ASSERT ON `claim_former_hosts` ITSELF, NOT THROUGH `claim_orphan_reason` (agent-infra#2094 cycle-5
# review). Two masks make the indirect form vacuous: `as_box` always exports the seam (so the probe is
# never reached), and for a same-host owner the live-pid rule answers first and returns "not orphaned"
# whatever the host rules say. Proven vacuous by mutation: deleting the guard left 74/74 green while a
# blind probe returned the box's own current name as FORMER. This form fails when the guard is deleted.
REAL="$(hostname -s)"
mkdir -p "$T/bin-nohost"
printf '#!/bin/sh\nexit 1\n' > "$T/bin-nohost/hostname"; chmod +x "$T/bin-nohost/hostname"
O19H="$T/cl19"; mkdir -p "$O19H"
printf '%s\n' "$REAL" > "$O19H/claim-hosts"     # exactly what production records while the name is current
FORMERS="$( cd "$T" || exit 1
  unset CLAIM_OWNER_HOST CLAIM_OWNER_ID CLAIM_KNOWN_HOSTS CLAIM_DEAD_HOSTS
  CLAIM_REPO="$T/repo"; CLAIM_STATE_DIR="$O19H"; export CLAIM_REPO CLAIM_STATE_DIR
  PATH="$T/bin-nohost:$PATH"; export PATH
  . "$CLAIMS_SH" || exit 1
  claim_former_hosts )"
[ -z "${FORMERS// /}" ]
O19C_RC=$?
ck "O19 [RED→GREEN] a BLIND hostname probe makes claim_former_hosts ABSTAIN (got '${FORMERS}')" $O19C_RC
# ... and with the probe working, the SAME file yields exactly the names that are NOT current.
FORMERS2="$( cd "$T" || exit 1
  unset CLAIM_OWNER_HOST CLAIM_OWNER_ID CLAIM_KNOWN_HOSTS CLAIM_DEAD_HOSTS
  CLAIM_REPO="$T/repo"; CLAIM_STATE_DIR="$O19H"; export CLAIM_REPO CLAIM_STATE_DIR
  . "$CLAIMS_SH" || exit 1
  claim_former_hosts )"
[ "$(printf '%s' "$FORMERS2" | tr -d ' ')" = "" ]
O19D_RC=$?
ck "O19 [PINNED] with a working probe the box's OWN current name is still not 'former' ('${FORMERS2}')" $O19D_RC
# (c) the seam must not make the machine's REAL name look former either (cycle-5 review): a
# seam-presenting process would otherwise reclaim a non-seam process's claim on the SAME machine.
printf '%s\n' "boxOldName" >> "$O19H/claim-hosts"
FORMERS3="$( cd "$T" || exit 1
  CLAIM_REPO="$T/repo"; CLAIM_STATE_DIR="$O19H"; CLAIM_OWNER_HOST=seamBox; export CLAIM_REPO CLAIM_STATE_DIR CLAIM_OWNER_HOST
  . "$CLAIMS_SH" || exit 1
  claim_former_hosts )"
[ "$(printf '%s' "$FORMERS3" | tr -d ' ')" = "boxOldName" ]
O19E_RC=$?
ck "O19 [RED→GREEN] under a SEAM the real current hostname is still excluded (got '${FORMERS3}')" $O19E_RC
# ... AND a seam does NOT excuse the probe from answering (cycle-6 review): with `CLAIM_OWNER_HOST` set
# and `hostname` blind, an empty `real` subtracted nothing and the machine's OWN current name came back
# as FORMER — a seam-presenting process reclaiming a real process's claim on the SAME machine.
FORMERS4="$( cd "$T" || exit 1
  CLAIM_REPO="$T/repo"; CLAIM_STATE_DIR="$O19H"; CLAIM_OWNER_HOST=seamBox
  export CLAIM_REPO CLAIM_STATE_DIR CLAIM_OWNER_HOST
  PATH="$T/bin-nohost:$PATH"; export PATH
  . "$CLAIMS_SH" || exit 1
  claim_former_hosts )"
[ -z "${FORMERS4// /}" ]
O19F_RC=$?
ck "O19 [RED→GREEN] a SEAM + a BLIND hostname probe abstains too (got '${FORMERS4}')" $O19F_RC


# ══ O20: the PRUNE's unparseable-lease skip is a DELETING branch and was untested ══
# `claim_prune` reaps by expiry AND by orphan, and the orphan arm sits downstream of an explicit
# `_lease_unparseable` continue. Mutation (cycle-5 review): deleting that `continue` left every suite
# green while the prune DELETED an unparseable-lease claim on an orphan guess. Losing a claim is the
# duplicate window; keeping one costs a lease.
echo
echo "── O20: claim_prune leaves an UNPARSEABLE lease alone, even from an orphaned host ────"
ORIG20="$(mk_origin o20)"; ensure_work_repo "$ORIG20" || { echo "❌ fixture"; exit 2; }
as_box "$ORIG20" deadbox 'c="$(_claim_commit "deadbox:2" 0)"
  _git push -q origin "$c:refs/claims/issue-7003" 2>/dev/null' >/dev/null
as_box "$ORIG20" deadbox 'c="$(_claim_commit "deadbox:2" "1000000000")"
  _git push -q origin "$c:refs/claims/issue-7004" 2>/dev/null' >/dev/null
has_ref "$ORIG20" refs/claims/issue-7003 && has_ref "$ORIG20" refs/claims/issue-7004
ck "O20 (setup) an UNPARSEABLE lease and an EXPIRED one are both planted" $?
PRUNE20="$(as_box "$ORIG20" livebox 'claim_prune' CLAIM_DEAD_HOSTS=deadbox 2>&1)"
has_ref "$ORIG20" refs/claims/issue-7003
ck "O20 [RED→GREEN] the unparseable-lease claim SURVIVES a prune that names its host DEAD" $?
printf '%s' "$PRUNE20" | grep -q 'issue-7003' && P20=1 || P20=0
ck "O20 [RED→GREEN] the prune does not even NAME it as reaped" $P20
# Non-vacuity: the SAME host's EXPIRED claim IS reaped by this prune, and so is its ORPHANED one.
has_ref "$ORIG20" refs/claims/issue-7004 && pr20=1 || pr20=0
ck "O20 [PINNED] the expired claim from the same dead host IS still reaped (the arm is alive)" $pr20

# ══ O21: a PR claim from a FORMER NAME of this box with a LIVE pid is HELD-BY-LIVE ══
# ⛔ P0, cycle-7 review. The pid gate used to be `host == claim_host`, so immediately after a rename a PR
# claim stamped `<oldName>:<live pid>` skipped the probe and fell through to the former-name rule, which
# called it ORPHANED — and the first hourly `claim_prune` deleted the box's OWN in-flight merge/fix
# claim. Every peer's pre-flight then read `no claim on #N`, a peer won a fresh CAS and merged the same
# head: the steal direction, on the keying where the minting pid IS the worker. A live pid is direct
# evidence the worker is alive, so it outranks the host name — but only for a LOCAL pid, and never for
# an ISSUE key (whose holder and worker are different processes; O15 pins that half).
echo
echo "── O21: former name + LIVE local pid on a PR key is HELD, not orphaned ─────────────"
ORIG21="$(mk_origin o21)"; ensure_work_repo "$ORIG21" || { echo "❌ fixture"; exit 2; }
CS21="$T/cs-o21"; mkdir -p "$CS21"; printf '%s\n' "oldBox21" > "$CS21/claim-hosts"
FUT21=$(( $(date +%s) + 7200 ))
as_box "$ORIG21" oldBox21 'c="$(_claim_commit "oldBox21:'"$$"'" "'"$FUT21"'")"
  _git push -q origin "$c:refs/claims/9209490-0123456789ab" 2>/dev/null' CLAIM_STATE_DIR="$CS21" >/dev/null
has_ref "$ORIG21" refs/claims/9209490-0123456789ab; ck "O21 (setup) a PR claim from the FORMER name with a LIVE pid is planted" $?
HELD21="$(as_box "$ORIG21" newBox21 'claim_acquire "" 9209490 0123456789abcdef0123 >/dev/null 2>&1
  printf "RC=%s\nRESULT=%s\n" "$?" "${CLAIM_RESULT:-}"' CLAIM_STATE_DIR="$CS21")"
R21="$(field "$HELD21" RC)"; R21RES="$(field "$HELD21" RESULT)"
[ "$R21" = "1" ]; O21A=$?
ck "O21 [RED→GREEN] the former-name owner with a LIVE pid is NOT reclaimed (rc=$R21) ('$R21RES')" $O21A
case "$R21RES" in
  *held-by-live*) ok "O21 [RED→GREEN] it reads held-by-live, so a peer still sees the barrier" ;;
  *) bad "O21 [RED→GREEN] it reads held-by-live (got '$R21RES')" ;;
esac
# AND the prune agrees — this is the arm that would DELETE the live worker's claim on a schedule.
PR21="$(as_box "$ORIG21" newBox21 'claim_prune' CLAIM_STATE_DIR="$CS21" 2>&1)"
OWN21="$(lease_owner "$ORIG21" refs/claims/9209490-0123456789ab)"
case "$OWN21" in
  oldBox21:*) O21B=0 ;;
  *) O21B=1 ;;
esac
ck "O21 [RED→GREEN] claim_prune leaves it alone (owner is still '$OWN21')" $O21B
# ... while the SAME former name with a DEAD pid IS reaped — the pid, not the host name, is the datum.
as_box "$ORIG21" oldBox21 'c="$(_claim_commit "oldBox21:999999" "'"$FUT21"'")"
  _git push -q origin "$c:refs/claims/9209491-0123456789ab" 2>/dev/null' CLAIM_STATE_DIR="$CS21" >/dev/null
DEAD21="$(as_box "$ORIG21" newBox21 'claim_acquire "" 9209491 0123456789abcdef0123 >/dev/null 2>&1
  printf "RC=%s\nRESULT=%s\n" "$?" "${CLAIM_RESULT:-}"' CLAIM_STATE_DIR="$CS21")"
[ "$(field "$DEAD21" RC)" = "0" ]; O21C=$?
ck "O21 [RED→GREEN] the SAME former name with a DEAD pid IS reclaimable (rc=$(field "$DEAD21" RC))" $O21C

echo
echo "─────────────────────────────────────────────────────────────"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
