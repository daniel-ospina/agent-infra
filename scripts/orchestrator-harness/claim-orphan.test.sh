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
#      duplicate. ⛔ THE TWO PRUNE ASSERTIONS ARE [PINNED], NOT RED→GREEN — measured, they PASS on the
#      pre-change tree, vacuously (nothing reaped by a host rule at all, so "does NOT delete" holds for
#      free); what they guard is the NEW arm not deleting a dead-pid ISSUE claim, and that the prune runs
#      BEFORE the acquire re-stamps the claim (see the ⛔ there). Only the `held-by-live` token and the
#      contrast case — the SAME dead pid on a PR claim IS pruned, which is what makes the exclusion a
#      rule rather than a dead branch — are red→green.
#   O16 [mostly RED→GREEN] orch-loop's `claim_live()` — the FOURTH call site — applies the same rules,
#      so a renamed box stops skipping PRs it could work. Driven by sourcing the SHIPPED function
#      alongside claims.sh; both pre-existing harnesses drive it WITHOUT claims.sh, where the arm is
#      deliberately inert (they assert that too).
#   O19 [RED→GREEN] the destructive arms require POSITIVE evidence: an absent `ref` does not authorise
#      the pid rule, and a `hostname` probe that cannot answer makes `claim_former_hosts` abstain
#      (asserted on the function directly — through `claim_orphan_reason` the live-pid rule masks it).
#   O23 [RED→GREEN] an EMPTY `hostname` answer abstains BEFORE the CLAIM_KNOWN_HOSTS comparison: the
#      pattern `*" $(claim_host) "*` degenerated to `*"  "*`, so any roster with a trailing comma or a
#      double space made the staleness guard pass for a box whose own name it never contained — the
#      steal direction, with the guard bypassed by the failure it exists to catch.
#   O22 [RED→GREEN] the `box` sentinel a failed `hostname` probe produces is NOT an identity — not in the
#      local-pid gate, not in the history reader, and not in the recorder (it is the same string on
#      every box, so treating it as local let each cell reap the others' live claims, and a recorded
#      sentinel would outlive the probe failure that wrote it).
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
#      ⚠️ The 157-minute lease in the incident is `CLAIM_ISSUE_TTL` applied to an
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
# ⛔ LABELLING HONESTY — MEASURED, not asserted. ⛔ AND IT TAKES **TWO** OVERRIDES, because this file
# pins BOTH shipped files (cycle-22 review: a `CLAIMS_SH=`-only run cannot redden the four O16 checks
# that are pinned to orch-loop.sh's `_this_host`/`claim_lease_live`, so the recipe quoted here did not
# reproduce the numbers it claimed). The measurement, taken 2026-10-19 against origin/main's
# `claims.sh` blob `d1604686` AND its `orch-loop.sh`:
#
#   CLAIMS_SH=/tmp/pre/claims.sh LOOP=/tmp/pre/orch-loop.sh bash claim-orphan.test.sh
#
# reports **60 passed, 77 FAILED** of 137 checks, and by label on that tree:
#   • [RED→GREEN]  66 checks — 0 pass, 66 fail. EVERY one is red before the change. (Non-vacuity.)
#   • [PINNED]      54 checks — 45 pass, 9 fail. The 45 pass VACUOUSLY, because the machinery is
#     absent pre-fix (`claim_orphan_reason` does not exist, and nothing reaped by a host rule or read a
#     deny list at all), so assertions of the form "does NOT delete" / "abstains" hold for free. They
#     are labelled PINNED rather than RED→GREEN for exactly that reason: they guard a NEW fail-open,
#     they are not red-to-green. The 9 that fail are controls asserting behaviour the pre-fix tree
#     lacks (the held-by-live token, the roster arm and its control, three `rc=127` O24 controls, the
#     O25 deny-list control, O16's no-leaked-error check, and O26's token assertion).
#   • unlabelled    17 checks — 15 pass, 2 fail.
# The 11 failing checks that carry NO [RED→GREEN] label are, by section:
#     `O7 the PR keying declares a documented ceiling`           (unlabelled by design)
#     `[PINNED]` O15 `it reads held-by-live`                     (the token itself is new)
#     `[PINNED]` O12 `… a roster that names the RUNNING host and omits the holder DOES reap it`
#     `[PINNED]` O23 `with an ANSWERABLE identity the roster arm still reaps an unlisted peer`
#     `[PINNED]` O24 `a DEAD pid under the same local name IS still orphaned`        (rc=127 pre-fix)
#     `[PINNED]` O24 `a peer host the roster OMITS is still reaped`                  (rc=127 pre-fix)
#     `[PINNED]` O24 `an explicit CLAIM_DEAD_HOSTS=box still reaps the sentinel`     (rc=127 pre-fix)
#     `[PINNED]` O25 `… while the SAME deny-listed host with a DEAD pid is reaped` (rc=127 pre-fix)
#     `[PINNED]` O16 `… the comparison does not leak a bash error`      (the old line errors loudly)
#     `[PINNED]` O26 `… and it names the token`                                  (the token is new)
#     `(setup)`  O22 `the failing probe really does fall back to the sentinel`       (needs claim_host)
# ⛔ ONE MORE DIRECTION, measured the same way: a check can be labelled [RED→GREEN] and still be green
# pre-fix FOR THE WRONG REASON — `claim_orphan_reason` is undefined on the old tree, so a subshell that
# calls it exits 127 and any assertion of the form "prints nothing" holds structurally. O25's reason
# check was caught by exactly that and is now labelled [PINNED]; its discrimination comes from the rc=1
# check beside it plus the reordering mutant, which reddens both.
# ⛔ SO PINNED DOES **NOT** MEAN "passes pre-fix", and RED→GREEN does mean "measured red". Read PINNED
# as: **this guards a new fail-open, it is not a regression of old behaviour**; read [RED→GREEN] as:
# **measured red before the change, green after**. Every re-labelling in this file's history happened
# after a measurement contradicted the label (O4's token check, three O15 lines, O17's duplicate check,
# O18's once-per-process check, sixteen in cycle 13, O9's pair in cycle 18, O25's reason pair in cycle
# 22). Re-measure rather than trusting this paragraph — it is a snapshot of one measurement, not an
# invariant, and the file grows.
#
# HERMETIC: every check builds its own throwaway bare origin (`git init --bare`), so no network, no
# real origin and nothing outside $T is written — the claim refs die with the temp dir.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ⛔ OVERRIDABLE so the RED direction can be RE-MEASURED rather than believed:
#   CLAIMS_SH=<main:scripts/orchestrator-harness/claims.sh> LOOP=<main:.../orch-loop.sh> bash claim-orphan.test.sh
# BOTH are needed for the full RED direction: O16 pins orch-loop.sh's readers, everything else pins
# claims.sh. Overriding one alone produces a number that is neither the old tree nor the new one.
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
grep -q 'REJECTED CLAIM_OWNER_ID' <<<"$O6B"; ck "O6 [RED→GREEN] the rejection is LOUD (names CLAIM_OWNER_ID on stderr)" $?
grep -q 'REJECTED CLAIM_OWNER_ID=[^ ]*ghosthost' <<<"$O6B"; ck "O6 [RED→GREEN] the rejection itself names the stale host it refused ('ghosthost')" $?
# And the matching case must stay silent: a correctly configured owner is not a warning.
O6C="$(as_box "" realhost 'printf "OWNER=%s\n" "$(claim_owner)"' CLAIM_OWNER_ID=realhost 2>&1)"
CK_OWNER="$(field "$O6C" OWNER)"
[ "${CK_OWNER%%:*}" = "realhost" ]; ck "O6 [PINNED] a CLAIM_OWNER_ID that DOES match the running host is honoured" $?
grep -q 'REJECTED' <<<"$O6C"; [ $? -ne 0 ]; ck "O6 [PINNED] no rejection is printed when the configured host matches" $?

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
ck "O15 [PINNED] claim_prune does NOT delete a dead-pid ISSUE claim (ref still on the origin)" $P15A
grep -q 'issue-9209450' <<<"$PRUNE15" && PR15=1 || PR15=0
ck "O15 [PINNED] the prune does not even NAME it as reaped" $PR15
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
# ⛔ THE OWNER HOST MUST BE ONE THE RULES ACTUALLY JUDGE (P1, cycle-17 review). `localbox` is a seam
# name with no `claim-hosts` entry, no deny-list entry and no roster, so nothing could have called this
# claim orphaned: the case passed pre-fix, at head, AND under a mutation that let the acquire's orphan
# arm run for an unparseable lease (measured — it reclaimed the claim with rc=0 while the suite stayed
# green). The host is now on the DEAD list, so the ONLY thing keeping the claim LIVE is the guard this
# case names, and the control below proves the same arm still reclaims a PARSEABLE expired lease.
NOLEASE="$(as_box "$ORIG5" localbox 'CLAIM_DEAD_HOSTS=localbox claim_issue_acquire "" 9209408 >/dev/null 2>&1
  printf "RC=%s\nRESULT=%s\n" "$?" "${CLAIM_RESULT:-}"')"
NOLRES="$(field "$NOLEASE" RESULT)"
[ "$(field "$NOLEASE" RC)" = "1" ]; NOL_RC=$?
# ⛔ [PINNED], NOT [RED→GREEN] (cycle-18 review, measured): on the pre-change tree nothing consults
# `CLAIM_DEAD_HOSTS` at all, so this passes there VACUOUSLY — the deny list it relies on does not exist.
# It is still the case that pins the ORDERING, which is why the mutation below is what gives it teeth.
ck "O9 [PINNED] an UNPARSEABLE lease reads LIVE even when the owner host is on the DEAD list ('$NOLRES')" $NOL_RC
# CONTROL: the same host, the same deny list, a PARSEABLE expired lease — the orphan arm DOES reclaim it,
# so a mutation that skips the unparseable guard for orphaned hosts reddens the pair.
PARSEABLE="$(as_box "$ORIG5" localbox 'c="$(_claim_commit "localbox:999994" "1000000000")"
  _git push -q --force origin "$c:refs/claims/issue-9209409" 2>/dev/null
  CLAIM_DEAD_HOSTS=localbox claim_issue_acquire "" 9209409 >/dev/null 2>&1
  printf "RC=%s\nRESULT=%s\n" "$?" "${CLAIM_RESULT:-}"')"
[ "$(field "$PARSEABLE" RC)" = "0" ]; O9C_RC=$?
ck "O9 [PINNED] ... while a PARSEABLE expired lease on the same DEAD host IS reclaimed (rc=$(field "$PARSEABLE" RC))" $O9C_RC

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
grep -q 'refs/claims/issue-9209411' <<<"$PRUNE"; ck "O2 [RED→GREEN] claim_prune reaps the ORPHANED-HOST claim (lease had hours left)" $?
grep -q -i 'orphan' <<<"$PRUNE"; ck "O2 [RED→GREEN] the orphan reap says so by name" $?
has_ref "$ORIG2" "refs/claims/issue-9209411" && rc=1 || rc=0
ck "O2 [RED→GREEN] the orphaned-host claim is gone from the origin" $rc
grep -q 'refs/claims/issue-9209412' <<<"$PRUNE"; ck "O3 [PINNED] claim_prune still reaps the EXPIRED claim" $?
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
ck "O7 [PINNED] a PR claim with no explicit ttl is stamped <= CLAIM_TTL=1800s (term=$(( ${U7:-0} - NOW7 ))s)" $?
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
# ⛔ A TWO-SIDED BOUND (P1, cycle-19 review). The upper bound alone could not tell "clamped to the
# CEILING" from "clamped to the DEFAULT" — and those are different behaviours, not different numbers:
# `ttl="$dflt"` instead of `ttl="$max"` silently SHORTENS merge-one's legitimate long lease to 1800s, the
# mid-review expiry the ceiling choice exists to prevent (measured: that one-token mutant left every
# suite green). So the term must land AT the ceiling, not merely below it.
U7TERM=$(( ${U7B:-0} - NOW7B ))
[ -n "$U7B" ] && [ "$U7TERM" -le "${CEIL:-1800}" ] && [ "$U7TERM" -ge "$(( ${CEIL:-1800} - 3 ))" ]
ck "O7 [RED→GREEN] a ttl ABOVE the ceiling is clamped TO THE CEILING, not to the shorter default (term=${U7TERM}s, ceiling=${CEIL:-?}s)" $?
# ⛔ A >9-DIGIT NUMERIC IS ABOVE THE CEILING, NOT UNPARSEABLE (P2, cycle-25 review). It used to be
# routed to `$dflt`, which is the SHORTER-DEFAULT direction this section exists to prevent AND it
# skipped the loud clamp: measured, `claim_acquire … 1000001199` stamped 1797s with EMPTY stderr while
# the 9-digit value stamped 7197s and said so. Reachable from merge-one.sh (`is_limit` accepts a 9-digit
# REVIEW_TIMEOUT, so REVIEW_TIMEOUT=999999999 derives CLAIM_LEASE=1000001199).
CLAIMDIG="$(as_box "$ORIG7" tbox 'claim_acquire "" 9209437 0123456789abcdef0123 1000001199 2>&1 >/dev/null')"
as_box "$ORIG7" tbox 'claim_acquire "" 9209437 0123456789abcdef0123 1000001199 >/dev/null 2>&1' >/dev/null
U7D="$(lease_until "$ORIG7" refs/claims/9209437-0123456789ab)"; NOW7D="$(now_s)"
U7DTERM=$(( ${U7D:-0} - NOW7D ))
[ -n "$U7D" ] && [ "$U7DTERM" -le "${CEIL:-7200}" ] && [ "$U7DTERM" -ge "$(( ${CEIL:-7200} - 3 ))" ]
ck "O7 [RED→GREEN] a 10-DIGIT numeric ttl clamps TO THE CEILING, not to the shorter default (term=${U7DTERM}s, ceiling=${CEIL:-?}s)" $?
case "$CLAIMDIG" in
  *"more than 9 digits"*) O7D2_RC=0 ;;
  *) O7D2_RC=1 ;;
esac
ck "O7 [RED→GREEN] ... and it says so loudly instead of silently shortening the lease ('$CLAIMDIG')" $O7D2_RC
# control: the SAME reader still falls back to the DEFAULT for a genuinely unparseable value, so the
# arm above is a new CASE and not a changed polarity for everything that is not a plain number.
as_box "$ORIG7" tbox 'claim_acquire "" 9209438 0123456789abcdef0123 1x >/dev/null 2>&1' >/dev/null
U7X="$(lease_until "$ORIG7" refs/claims/9209438-0123456789ab)"; NOW7X="$(now_s)"
U7XTERM=$(( ${U7X:-0} - NOW7X ))
[ -n "$U7X" ] && [ "$U7XTERM" -le 1800 ] && [ "$U7XTERM" -gt 1700 ]
ck "O7 [PINNED] an UNPARSEABLE ttl still falls back to the PR default (term=${U7XTERM}s), not the ceiling" $?
# ⛔ THE EXPECTED TERM IS READ FROM THE SHIPPED claims.sh, NOT CACHED HERE (landing-review, HIGH).
# These four pins carried the literal 10800 and the #2029 change raised the default to 14400 — so the
# shard went red on BOTH lanes for a change that was correct, which is exactly what a cached default
# buys: the assertion stops testing "the term is bounded and visible" (its own stated purpose) and
# starts testing "nobody changed the default". Read the governed value out of the source the code is
# built from, and keep every bound RELATIVE to it.
ISSUE_TTL_EXPECTED="$(sed -n 's/^CLAIM_ISSUE_TTL="${CLAIM_ISSUE_TTL:-*\([0-9][0-9]*\)}".*/\1/p' \
                       "$(dirname "${BASH_SOURCE[0]}")/claims.sh" 2>/dev/null | head -1)"
case "$ISSUE_TTL_EXPECTED" in ''|*[!0-9]*)
  ISSUE_TTL_EXPECTED=10800 ;;   # unreadable source: keep the historical default rather than skip the leg
esac
# ⛔ AND THE MAGNITUDE MUST STILL BE PINNED (landing-review, P2). Deriving BOTH sides of the
# comparison from the file under test means a LOWERING moves both — the whole 1801..13589s range stays
# green, which is exactly the guard the literal used to give and the #1850 duplicate-dispatch class the
# file exists to prevent. So the shipped value must still COVER the sum its own comment derives; that is
# an acknowledgement (the same pattern install-launchd.test.sh uses), not a cache: any term moving
# without the TTL reddens.
# ⛔ THE LANE TERM IS READ FROM THE SHIPPED SOURCE, for the same reason the TTL above is (agent-infra#2888
# review, P1 — verified). This sum carried the literal `3300` and stayed GREEN while the lane's own bound
# moved to the 7200 s backstop (`LANE_BACKSTOP_S`, spawn-gate.sh) with `lane.sh`'s `run_agent` call — the
# exact "a literal in the test" shape this file's comment above argues against. `lane.sh` names the seam
# rather than a number, so resolve it from the seam's owner; an unreadable source keeps 3300 rather than
# skipping the leg.
LANE_TERM="$(sed -n 's/^LANE_BACKSTOP_S="${LANE_BACKSTOP_S:-\([0-9][0-9]*\)}".*/\1/p' \
              "$(dirname "${BASH_SOURCE[0]}")/spawn-gate.sh" 2>/dev/null | head -1)"
case "$LANE_TERM" in ''|*[!0-9]*) LANE_TERM=3300 ;; esac
LEASE_TERMS=$(( LANE_TERM + 5400 + 1890 + 3000 ))   # lane + chain PR wait + merge-phase wait + review/merge
[ "$ISSUE_TTL_EXPECTED" -ge "$LEASE_TERMS" ]
ck "O7 the shipped CLAIM_ISSUE_TTL (${ISSUE_TTL_EXPECTED}s) still COVERS its own derived terms (${LEASE_TERMS}s, lane term ${LANE_TERM}s read from spawn-gate.sh)" $?
IVAL="$(as_box "$ORIG7" tbox 'printf "%s\n" "$CLAIM_ISSUE_TTL"')"
[ "$IVAL" = "$ISSUE_TTL_EXPECTED" ]
ck "O7 the ISSUE claim's default TTL is the SHIPPED claims.sh value (${ISSUE_TTL_EXPECTED}s, got '$IVAL')" $?
as_box "$ORIG7" tbox 'claim_issue_acquire "" 9209432 >/dev/null 2>&1' >/dev/null
U8="$(lease_until "$ORIG7" refs/claims/issue-9209432)"; NOW8="$(now_s)"
[ -n "$U8" ] && [ "$(( U8 - NOW8 ))" -le "$ISSUE_TTL_EXPECTED" ] \
             && [ "$(( U8 - NOW8 ))" -gt "$(( ISSUE_TTL_EXPECTED - 200 ))" ]
ck "O7 [PINNED] an ISSUE claim's stamped term is <= CLAIM_ISSUE_TTL=${ISSUE_TTL_EXPECTED}s (term=$(( ${U8:-0} - NOW8 ))s)" $?
# ⚠️ The incident's lease is THIS one: CLAIM_ISSUE_TTL on an ISSUE
# claim, by design (its own comment derives the term from LANE_TIMEOUT + the merge phase + review).
# asserted here so the number is BOUNDED and visible, not so it is silently lowered.
as_box "$ORIG7" tbox 'claim_issue_acquire "" 9209436 999999999 >/dev/null 2>&1' >/dev/null
U8B="$(lease_until "$ORIG7" refs/claims/issue-9209436)"; NOW8B="$(now_s)"
# two-sided for the same reason: the issue ceiling is 10800s and the issue DEFAULT is also 10800s, but a
# slip to the PR default (1800s) must not pass.
U8TERM=$(( ${U8B:-0} - NOW8B ))
[ -n "$U8B" ] && [ "$U8TERM" -le "$ISSUE_TTL_EXPECTED" ] \
              && [ "$U8TERM" -ge "$(( ISSUE_TTL_EXPECTED - 3 ))" ]
ck "O7 [RED→GREEN] an ISSUE ttl above CLAIM_ISSUE_TTL is clamped TO IT, not to a shorter default (term=${U8TERM}s)" $?
# An unparseable ttl must fall back to the keying's own default — never to the PR's shorter one.
as_box "$ORIG7" tbox 'claim_issue_acquire "" 9209433 07 >/dev/null 2>&1' >/dev/null
U9="$(lease_until "$ORIG7" refs/claims/issue-9209433)"; NOW9="$(now_s)"
[ -n "$U9" ] && [ "$(( U9 - NOW9 ))" -le "$ISSUE_TTL_EXPECTED" ] \
             && [ "$(( U9 - NOW9 ))" -gt 1800 ]
ck "O7 [PINNED] an unparseable ttl falls back to the ISSUE default (${ISSUE_TTL_EXPECTED}s), never the PR's shorter one (term=$(( ${U9:-0} - NOW9 ))s)" $?

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
# ⛔ (e) THE DOCUMENTED ISSUE-KEY RESIDUAL, PINNED (P2, cycle-13 review: the README cited O10 for a
# `<former name>:<live pid>` ISSUE claim, and O10's pid was DEAD by the time it reclaimed — so the
# attestation overstated what was measured). Here the pid is the TEST SHELL's own, alive and local:
#   • an ISSUE ref  → ORPHANED, because the pid rule is PR-keyed and the former-name HOST rule answers
#   • a PR ref       → held-by-live, because the same name makes the pid probeable
# That difference IS the residual: neither remedy preserves an in-flight ISSUE claim.
LIVEPID10="$(
  CLAIM_REPO="$ORIG10"; CLAIM_STATE_DIR="$CS10"; export CLAIM_REPO CLAIM_STATE_DIR
  . "$CLAIMS_SH" || exit 1
  r="$(claim_orphan_reason "boxOldName:$$" "refs/claims/issue-9209438")"
  printf "%s" "$r" )"
case "$LIVEPID10" in *FORMER*) LP10_OK=0 ;; *) LP10_OK=1 ;; esac
ck "O10 [RED→GREEN] an ISSUE claim under a FORMER name with a LIVE pid is still orphaned ('$LIVEPID10')" $LP10_OK
LIVEPID10P="$(
  CLAIM_REPO="$ORIG10"; CLAIM_STATE_DIR="$CS10"; export CLAIM_REPO CLAIM_STATE_DIR
  . "$CLAIMS_SH" || exit 1
  r="$(claim_orphan_reason "boxOldName:$$" "refs/claims/9209439-0123456789ab")"
  # ⛔ TWO LINES: `field` matches at LINE START, so a single-line "RC=1 R=[]" yields "1 R=[]" and the
  # comparison against "1" fails for a reason that has nothing to do with the rule.
  printf "RC=%s\nR=[%s]\n" "$?" "$r" )"
[ "$(field "$LIVEPID10P" RC)" = "1" ]; LP10P_RC=$?
ck "O10 [RED→GREEN] ... while the SAME name on a PR ref reads held-by-live ($(field "$LIVEPID10P" R))" $LP10P_RC

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
ck "O12 [PINNED] a roster that does not list the RUNNING host does not authorise a reap (rc=$(field "$STALE" RC))" $O12_RC1
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
grep -q 'REJECTED CLAIM_OWNER_ID' <<<"$O13"; ck "O13 [RED→GREEN] the refusal is loud" $?

# ══ O14: the ceiling clamp is LOUD ══
# A silent clamp is what makes a mid-review expiry undiagnosable: merge-one.sh derives its lease from
# REVIEW_TIMEOUT and would never know the ceiling had shortened it.
echo
echo "── O14: clamping a ttl to the ceiling says so ─────────────────────────────────────"
ORIG14="$(mk_origin o14)"; ensure_work_repo "$ORIG14" || { echo "❌ fixture"; exit 2; }
CLAMP="$(as_box "$ORIG14" tbox 'claim_acquire "" 9209440 0123456789abcdef0123 999999999 >/dev/null
  printf "DONE=%s\n" "$?"' 2>&1)"
grep -q 'clamped' <<<"$CLAMP"
ck "O14 [RED→GREEN] a ttl above the ceiling reports the clamp (stderr) instead of shortening silently" $?
grep -q 'CLAIM_TTL_MAX' <<<"$CLAMP"
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
# ⛔ EXTRACT EVERY FUNCTION THE READERS CALL (cycle-17 review). origin/main's #2129 split the old
# `claim_live` into a thin spawn guard over `claim_lease_live`, and moved OWNERSHIP to
# `claim_foreign_live`; extracting `claim_live` alone yielded a stub whose only callee did not exist,
# so every case below measured "NOTLIVE" for the wrong reason. The orphan arm itself now lives in
# `claim_lease_live` (the shared lease reader), which is where #2094's PR half belongs.
{
  sed -n '/^claim_lease_live() {/,/^}/p' "$LOOP"
  sed -n '/^_this_host() {/,/^}/p' "$LOOP"
  sed -n '/^claim_live() {/,/^}/p' "$LOOP"
  sed -n '/^claim_selection_verdict() {/,/^}/p' "$LOOP"
  sed -n '/^claim_foreign_live() {/,/^}/p' "$LOOP"
} > "$O16/claimlive.sh"
# agent-infra#2466: `claim_foreign_live` is now a mapping over `claim_selection_verdict`, which in turn
# calls claims.sh's `claim_snapshot_verdict`. Extracting the outer function without the middle one made
# the middle call exit 127 — which is fail-closed in the predicate, so every case read OWNED and the
# assertions graded a missing extraction rather than the rule.
[ -s "$O16/claimlive.sh" ] && grep -q 'claim_lease_live()' "$O16/claimlive.sh" \
  && grep -q 'claim_selection_verdict()' "$O16/claimlive.sh" \
  && grep -q 'claim_foreign_live()' "$O16/claimlive.sh"
ck "O16 (setup) the readers are extractable from the shipped orch-loop.sh" $?
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
# ⛔ A HARDCODED `999` IS A REACHABLE PID on this kernel (kern.maxproc=8000), so naming it as "the pid is
# gone" made these assertions fail for a reason unrelated to the rule whenever a process held it
# (cycle-15 review). Derive a pid that is absent RIGHT NOW, the way O24 does.
DEADPID16=999999
while ps -p "$DEADPID16" >/dev/null 2>&1; do DEADPID16=$((DEADPID16+1)); done
snap refs/claims/9209460-0123456789ab "boxOldName:$DEADPID16" "$FUT"
[ "$(cl 9209460 $SHA16)" = "NOTLIVE" ]
ck "O16 [RED→GREEN] a PR claim stamped by a FORMER name of this box is NOT in flight (the PR is workable again)" $?
snap refs/claims/9209461-0123456789ab "peerBox:$DEADPID16" "$FUT"
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
snap refs/claims/9209463-0123456789ab "boxOldName:$DEADPID16" "0"
[ "$(cl 9209463 $SHA16)" = "LIVE" ]
ck "O16 [PINNED] an UNPARSEABLE lease stays LIVE in claim_live() too (the orphan arm runs after it)" $?
# ⛔ THE FOURTH READER'S CLOCK PROBE MUST ABSTAIN TOWARD LIVE (P2, cycle-23 review). `[ "$(date +%s)" -le
# "$until" ]` folded an UNREADABLE clock into "not in flight" (and printed `[: …: integer expression
# expected` on every call), so during a clock failure every worker-held PR read as free: the sweep
# attempted a spawn per PR and `claim_acquire` refused each on its own clock guard. The three readers in
# claims.sh all treat that clock as LIVE; this one is the fourth, and it must agree.
# ⛔ THE HOLDER MUST BE ONE THE ORPHAN ARM LEAVES ALONE, or the fixture proves the wrong thing: a live
# local pid is neither a former name nor a dead host, so the CLOCK probe is the only guard left to judge.
snap refs/claims/9209465-0123456789ab "$(hostname -s):$$" "$FUT"
mkdir -p "$T/bin-nodate16"
printf '#!/bin/sh\necho notanumber\n' > "$T/bin-nodate16/date"; chmod +x "$T/bin-nodate16/date"
# ⛔ PATH IS SET INSIDE THE SUBSHELL, BEFORE the extraction is sourced: a `date` shim exported by the
# caller only reaches children, and every comparison in this harness runs in-process.
# ⛔ BOTH STREAMS FROM INSIDE THE SUBSHELL (mutation-verified, cycle-23): with a plain `"$( … )"` the
# bash error went to the TEST's stderr, so the "no leaked error" check below read nothing and stayed
# green under a mutation that restored the very bug it exists for.
O16CLK="$(
  { PATH="$T/bin-nodate16:$PATH"
    CLAIM_REPO="$T/repo"; CLAIM_STATE_DIR="$O16/state"; O="$O16"; export PATH CLAIM_REPO CLAIM_STATE_DIR O
    . "$CLAIMS_SH" || exit 1
    . "$O16/claimlive.sh" || exit 1
    if claim_lease_live 9209465 "$SHA16"; then printf LIVE; else printf NOTLIVE; fi; } 2>&1 )"
case "$O16CLK" in
  "LIVE") O16CLK_RC=0 ;;
  *) O16CLK_RC=1 ;;
esac
ck "O16 [RED→GREEN] an UNREADABLE clock abstains toward LIVE in claim_lease_live() (got '$O16CLK')" $O16CLK_RC
case "$O16CLK" in
  *"integer expression"*) O16CLK2_RC=1 ;;
  *) O16CLK2_RC=0 ;;
esac
ck "O16 [PINNED] ... and the comparison does not leak a bash error into the controller log ('$O16CLK')" $O16CLK2_RC
# control: the SAME entry with a WORKING clock is not in flight once its lease has passed — so the
# assertion above measures the clock probe, not a reader that stopped judging leases at all.
snap refs/claims/9209465-0123456789ab "$(hostname -s):$$" "1"
[ "$(cl 9209465 $SHA16)" = "NOTLIVE" ]
ck "O16 [PINNED] ... while an EXPIRED lease is still NOT in flight with a working clock" $?
snap refs/claims/9209464-0123456789ab "peerBox:$DEADPID16" "$FUT"
[ "$(cl 9209464 $SHA16 CLAIM_DEAD_HOSTS=peerBox)" = "NOTLIVE" ]
ck "O16 [RED→GREEN] the DEAD-host roster reaches claim_live() as well (one rule set, four call sites)" $?
# And the branch must be GATED, not unconditional: a call site with no claims.sh loaded behaves as
# before — which is exactly what selftest.sh / test-gates.sh rely on.
# ⛔ `snap` REPLACES the file, so each case must re-write the entry IT names — the last case left only
# 9209464 in place, and a probe against 9209460 would then read "absent" (not live) and prove nothing.
# ⛔ AND THE CHECK MUST DISCRIMINATE (cycle-15 review): the old form asserted only "a future lease reads
# LIVE" in the no-claims.sh harness, which is TRUE whether or not the orphan arm exists — a mutation
# deleting the arm's `declare -f` gate left every suite green (the gate is now gone; see orch-loop.sh).
# The fixture below is an ORPHANED one (former name, dead pid, future lease): with claims.sh loaded the
# same owner reads NOTLIVE (pinned above), so asserting LIVE here measures exactly the arm's absence.
snap refs/claims/9209460-0123456789ab "boxOldName:$DEADPID16" "$FUT"
O16G="$( cd "$T" || exit 1; O="$O16"; export O; . "$O16/claimlive.sh"
  if claim_live 9209460 "$SHA16"; then printf LIVE; else printf NOTLIVE; fi )"
[ "$O16G" = "LIVE" ]
O16G_RC=$?
ck "O16 [PINNED] with no claims.sh loaded the orphan arm is INERT and the lease polarity decides (got '$O16G')" $O16G_RC
# ⛔ AND THE OWNERSHIP READER MUST AGREE (agent-infra#2094 on origin/main's #2129). `pr_owned` calls
# `claim_foreign_live`, NOT `claim_live`, so an orphan arm that only reached the spawn guard left the PR
# half of the incident open: after a rename the box's own PR claim kept the PR OUT of the un-owned
# queue for its whole term. `claim_foreign_live` consults `claim_orphan_reason` before the lease now.
clf() { # <pr> <sha> — 0 when a LIVE claim is held by another box
  ( cd "$T" || exit 1
    O="$O16"; CLAIM_STATE_DIR="$O16/state"; CLAIM_REPO="$T/repo"
    export O CLAIM_STATE_DIR CLAIM_REPO
    . "$CLAIMS_SH" || exit 1
    . "$O16/claimlive.sh" || exit 1
    if claim_foreign_live "$1" "$2"; then echo OWNED; else echo FREE; fi ) 2>&1
}
snap refs/claims/9209470-0123456789ab "boxOldName:$DEADPID16" "$FUT"
[ "$(clf 9209470 $SHA16)" = "FREE" ]
ck "O16 [RED→GREEN] claim_foreign_live() does NOT count an ORPHANED PR claim as ownership (the PR re-enters the queue)" $?
snap refs/claims/9209471-0123456789ab "peerBox:$DEADPID16" "$FUT"
# (REAL24 is defined in the O24 section further down; this section runs first, so probe inline.)
[ "$(CLAIM_KNOWN_HOSTS="$(hostname -s) peerBox" clf 9209471 $SHA16)" = "OWNED" ]
ck "O16 [PINNED] ... while a KNOWN live peer's claim still reads OWNED (no steal from the queue)" $?
# ⛔ AND A PROBE-BLIND BOX MUST NOT READ A PEER'S `box:<pid>` CLAIM AS ITS OWN (P2, cycle-21 review).
# `_this_host` fell back to the literal `box`, so `[ "$host" != "$(_this_host)" ]` matched a peer's
# sentinel-stamped claim, `claim_foreign_live` answered "not foreign", and `pr_owned()` dropped that PR
# out of the owned set — the sweep then spawned for it every cycle and `claim_acquire` refused.
mkdir -p "$T/bin-nohost16"
printf '#!/bin/sh\nexit 1\n' > "$T/bin-nohost16/hostname"; chmod +x "$T/bin-nohost16/hostname"
snap refs/claims/9209472-0123456789ab "box:41234" "$FUT"
O16BOX="$(
  PATH="$T/bin-nohost16:$PATH"
  CLAIM_REPO="$T/repo"; CLAIM_STATE_DIR="$O16/state"; O="$O16"; export PATH CLAIM_REPO CLAIM_STATE_DIR O
  . "$CLAIMS_SH" || exit 1
  . "$O16/claimlive.sh" || exit 1
  printf "THIS=[%s] " "$(_this_host)"
  if claim_foreign_live 9209472 "$SHA16"; then printf "OWNED"; else printf "FREE"; fi )"
# ⛔ THE EXPECTED ANSWER IS `OWNED`, AND THAT IS THE POINT: with the identity abstaining, the claim is
# NOT read as this box's own — the guard falls through and the LEASE decides, which is the same answer
# every genuinely foreign holder gets (the sweep keeps counting the PR as worked, and no spawn churn is
# produced by a refused acquire). Reading it as `not foreign` (the `box` fallback) was the bug.
case "$O16BOX" in
  "THIS=[] OWNED") O16BOX_RC=0 ;;
  *) O16BOX_RC=1 ;;
esac
ck "O16 [RED→GREEN] a probe-blind box does not treat a peer's 'box:<pid>' claim as its own ($O16BOX)" $O16BOX_RC

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
ck "O17 [PINNED] an ABSENT state dir is not created (recording writes nothing rather than conjuring state)" $MKD_RC

# ══ O18: the SEAM announces what it costs ══
# `CLAIM_OWNER_HOST` is inherited silently by everything a cell starts. Two consequences were invisible:
# it stamps a name these rules cannot judge (so the box cannot reclaim its OWN leases), and it
# suppresses `claim_host_record` (so the rename self-heal goes inert while reporting nothing). The seam
# stays supported — the harnesses and cross-box simulations need it — but it says so, once.
echo
echo "── O18: a CLAIM_OWNER_HOST that differs from the running host WARNS (once) ─────────"
SEAMW="$(as_box "" seamhost 'claim_owner >/dev/null; claim_owner >/dev/null' 2>&1)"
grep -q 'CLAIM_OWNER_HOST=seamhost' <<<"$SEAMW"
SW1=$?
ck "O18 [RED→GREEN] the warning NAMES the seam value" $SW1
grep -q "$(hostname -s)" <<<"$SEAMW"
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
SW3="$(grep -c 'CLAIM_OWNER_HOST=' <<<"$SEAMW2")"
[ "$SW3" = "1" ]
SW3_RC=$?
ck "O18 [RED→GREEN] it fires ONCE per process through the SHIPPED mint path (two acquires, $SW3 warning(s))" $SW3_RC
# ⛔ AND ONCE ACROSS RE-SOURCES (cycle-11 review). "Once per process" was really once per SOURCE: the
# flag was a hard `=0` at file scope, and `orch-loop.sh` re-sources claims.sh INSIDE its main loop, so
# the controller warned once per cycle (~2 min) forever — the exact spam the flag exists to stop. The
# shipped controller cannot be run here, so this reproduces its shape: source, acquire, source, acquire.
SEAMW3="$(
  CLAIM_REPO="$T/repo"; CLAIM_STATE_DIR="$T/state18r"; CLAIM_OWNER_HOST=seamhost2
  export CLAIM_REPO CLAIM_STATE_DIR CLAIM_OWNER_HOST
  mkdir -p "$CLAIM_STATE_DIR"
  i=0
  while [ "$i" -lt 2 ]; do
    . "$CLAIMS_SH" || exit 1
    claim_acquire "" 920948$i 0123456789abcdef0123 >/dev/null
    i=$((i+1))
  done 2>&1 >/dev/null)"
SW6="$(grep -c 'CLAIM_OWNER_HOST=' <<<"$SEAMW3")"
[ "$SW6" = "1" ]
SW6_RC=$?
ck "O18 [RED→GREEN] it stays ONCE across a re-source (the controller re-sources every cycle; $SW6 warning(s))" $SW6_RC
# Silent when the seam AGREES with the running host — a correctly configured box is not a warning.
SEAMOK="$(as_box "" "$(hostname -s)" 'claim_owner >/dev/null' 2>&1)"
[ -z "$SEAMOK" ]
SW4=$?
ck "O18 [PINNED] no warning when the seam equals the running host" $SW4
# ⛔ THE WARNING'S OWN PROBE ABSTAINS (cycle-10 review): a `hostname` that cannot answer used to leak its
# error to stderr, print "overrides the running host ()", and abort the mint under a `set -e` caller.
mkdir -p "$T/bin-nohost18"
printf '#!/bin/sh\nexit 1\n' > "$T/bin-nohost18/hostname"; chmod +x "$T/bin-nohost18/hostname"
SEAMLEAK="$(
  PATH="$T/bin-nohost18:$PATH"
  CLAIM_OWNER_HOST=seamBox; CLAIM_STATE_DIR="$T/cl18b"; export PATH CLAIM_OWNER_HOST CLAIM_STATE_DIR
  mkdir -p "$CLAIM_STATE_DIR"
  . "$CLAIMS_SH" || exit 1
  out="$(claim_owner 2>&1 >/dev/null)"; printf "STDERR=[%s]\n" "$out" )"
case "$(field "$SEAMLEAK" STDERR)" in
  *hostname*|*"running host ()"*) SW5=1 ;;
  *) SW5=0 ;;
esac
ck "O18 [PINNED] a blind hostname makes the seam warning ABSTAIN (no probe error leaks, no empty host)" $SW5
# ⛔ AND A FAILED PROBE MUST NOT CONSUME THE ONCE (P1, cycle-16 review): the flag used to be set BEFORE
# the `hostname` probe answered, so one transient failure silenced the seam warning for the life of the
# process — the silent inertness the warning exists to expose. Every other case here runs in a fresh
# process, so none could observe it; this one drives BOTH probes in ONE shell.
# ⛔ THE WARNING IS ON STDERR, so both streams must be captured from INSIDE the subshell (a `2>&1` on
# the assignment redirects the assignment, not the subshell — measured in an earlier cycle as "0
# warning(s)").
SEAMSEQ="$(
  {
    PATH="$T/bin-nohost18:$PATH"
    CLAIM_OWNER_HOST=seamSeq; CLAIM_STATE_DIR="$T/cl18c"; export PATH CLAIM_OWNER_HOST CLAIM_STATE_DIR
    mkdir -p "$CLAIM_STATE_DIR"
    . "$CLAIMS_SH" || exit 1
    claim_owner >/dev/null                      # the probe FAILS here, so it must not warn
    PATH="/usr/bin:/bin:/usr/sbin:/sbin"; export PATH   # the probe RECOVERS in the SAME process
    claim_owner >/dev/null                      # now it warns — exactly once
    claim_owner >/dev/null                      # and not again
  } 2>&1
)"
SW7="$(grep -c 'CLAIM_OWNER_HOST=' <<<"$SEAMSEQ")"
[ "$SW7" = "1" ]
SW7_RC=$?
ck "O18 [RED→GREEN] a probe that could not answer does NOT consume the once — the next acquire warns ($SW7 warning(s))" $SW7_RC

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
ck "O19 [PINNED] a BLIND hostname probe makes claim_former_hosts ABSTAIN (got '${FORMERS}')" $O19C_RC
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
ck "O19 [PINNED] a SEAM + a BLIND hostname probe abstains too (got '${FORMERS4}')" $O19F_RC
# ... including a probe that SUCCEEDS and prints NOTHING (cycle-8 review): `real=""` subtracted nothing,
# so the machine's own current name came back as FORMER — the same steal direction, one shim away.
mkdir -p "$T/bin-emptyhost"
printf '#!/bin/sh\nexit 0\n' > "$T/bin-emptyhost/hostname"; chmod +x "$T/bin-emptyhost/hostname"
FORMERS5="$( cd "$T" || exit 1
  CLAIM_REPO="$T/repo"; CLAIM_STATE_DIR="$O19H"; CLAIM_OWNER_HOST=seamBox
  export CLAIM_REPO CLAIM_STATE_DIR CLAIM_OWNER_HOST
  PATH="$T/bin-emptyhost:$PATH"; export PATH
  . "$CLAIMS_SH" || exit 1
  claim_former_hosts )"
[ -z "${FORMERS5// /}" ]
O19G_RC=$?
ck "O19 [PINNED] a probe that exits 0 with EMPTY output abstains too (got '${FORMERS5}')" $O19G_RC


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
ck "O20 [PINNED] the unparseable-lease claim SURVIVES a prune that names its host DEAD" $?
grep -q 'issue-7003' <<<"$PRUNE20" && P20=1 || P20=0
ck "O20 [PINNED] the prune does not even NAME it as reaped" $P20
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
ck "O21 [PINNED] the former-name owner with a LIVE pid is NOT reclaimed (rc=$R21) ('$R21RES')" $O21A
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
ck "O21 [PINNED] claim_prune leaves it alone (owner is still '$OWN21')" $O21B
# ... while the SAME former name with a DEAD pid IS reaped — the pid, not the host name, is the datum.
as_box "$ORIG21" oldBox21 'c="$(_claim_commit "oldBox21:999999" "'"$FUT21"'")"
  _git push -q origin "$c:refs/claims/9209491-0123456789ab" 2>/dev/null' CLAIM_STATE_DIR="$CS21" >/dev/null
DEAD21="$(as_box "$ORIG21" newBox21 'claim_acquire "" 9209491 0123456789abcdef0123 >/dev/null 2>&1
  printf "RC=%s\nRESULT=%s\n" "$?" "${CLAIM_RESULT:-}"' CLAIM_STATE_DIR="$CS21")"
[ "$(field "$DEAD21" RC)" = "0" ]; O21C=$?
ck "O21 [RED→GREEN] the SAME former name with a DEAD pid IS reclaimable (rc=$(field "$DEAD21" RC))" $O21C

# ══ O22: the `box` SENTINEL from a failed `hostname` probe is NOT an identity ══
# ⛔ P0, cycle-9 review. `claim_host` falls back to the literal `box`, and that string is THE SAME ON EVERY
# BOX — so `[ "$host" = "$(claim_host)" ]` matched EVERY peer's `box:<pid>` claim, read the peer's pid
# as absent on this machine, and reclaimed (and pruned) a LIVE remote worker's claim. One shared
# install/PATH mistake makes every cell stamp `box:<pid>`, i.e. each box reaping the others' claims.
# A sentinel owner must fall through to the host rules, which abstain when they cannot judge.
echo
echo "── O22: a \`box:\` owner is never treated as this box (the sentinel is fleet-wide) ─"
ORIG22="$(mk_origin o22)"; ensure_work_repo "$ORIG22" || { echo "❌ fixture"; exit 2; }
mkdir -p "$T/bin-nohost22"
printf '#!/bin/sh\nexit 1\n' > "$T/bin-nohost22/hostname"; chmod +x "$T/bin-nohost22/hostname"
CS22="$T/cs-o22"; mkdir -p "$CS22"
FUT22=$(( $(date +%s) + 7200 ))
as_box "$ORIG22" box 'c="$(_claim_commit "box:999999" "'"$FUT22"'")"
  _git push -q origin "$c:refs/claims/9209500-0123456789ab" 2>/dev/null' CLAIM_STATE_DIR="$CS22" >/dev/null
has_ref "$ORIG22" refs/claims/9209500-0123456789ab; ck "O22 (setup) a peer's \`box:\` PR claim is planted" $?
SENT22="$(
  PATH="$T/bin-nohost22:$PATH"
  CLAIM_REPO="$T/repo"; CLAIM_STATE_DIR="$CS22"
  export PATH CLAIM_REPO CLAIM_STATE_DIR
  . "$CLAIMS_SH" || exit 1
  printf "HOST=%s\n" "$(claim_host)"
  claim_orphan_reason "box:999999" "refs/claims/9209500-0123456789ab" >/dev/null 2>&1; printf "RC=%s\n" "$?" )"
[ "$(field "$SENT22" HOST)" = "box" ]; S22A=$?
ck "O22 (setup) the failing probe really does fall back to the sentinel (host='$(field "$SENT22" HOST)')" $S22A
[ "$(field "$SENT22" RC)" = "1" ]; S22B=$?
ck "O22 [RED→GREEN] a live-unknown 'box:<pid>' PR claim is NOT orphaned (rc=$(field "$SENT22" RC))" $S22B
# AND the prune must leave it alone — this is the arm that would delete a live REMOTE worker's claim.
PR22="$(
  PATH="$T/bin-nohost22:$PATH"
  CLAIM_REPO="$T/repo"; CLAIM_STATE_DIR="$CS22"; export PATH CLAIM_REPO CLAIM_STATE_DIR
  . "$CLAIMS_SH" || exit 1
  claim_prune )"
OWN22="$(lease_owner "$ORIG22" refs/claims/9209500-0123456789ab)"
case "$OWN22" in
  box:999999) S22C=0 ;;
  *) S22C=1 ;;
esac
ck "O22 [PINNED] claim_prune leaves it alone (owner is still '$OWN22')" $S22C
# … and a `box` entry that reached the history file (an OLDER claims.sh recorded it before the recorder
# refused the sentinel) is still not an identity. ⛔ THE REAL `hostname` MUST BE IN PLAY HERE (cycle-10
# review): the previous form of this case ran under the blind shim, where `claim_former_hosts` abstains
# at the probe guard and returns an empty roster WHATEVER the file holds — so it passed with no sentinel
# handling at all, and the reap it was meant to catch went straight through.
# ⛔ THE FILE MUST ACTUALLY CONTAIN THE SENTINEL — the seed line was lost in an edit, which made this
# case vacuous in a second way (an empty file yields an empty roster whatever the reader excludes).
printf 'box\n' > "$CS22/claim-hosts"
grep -qx 'box' "$CS22/claim-hosts"; S22SEED=$?
ck "O22 (setup) 'box' really is in the history file for the reader case" $S22SEED
SENT22B="$(
  CLAIM_REPO="$T/repo"; CLAIM_STATE_DIR="$CS22"; export CLAIM_REPO CLAIM_STATE_DIR
  . "$CLAIMS_SH" || exit 1
  claim_orphan_reason "box:999999" "refs/claims/9209500-0123456789ab" >/dev/null 2>&1; printf "RC=%s\n" "$?" )"
[ "$(field "$SENT22B" RC)" = "1" ]; S22D=$?
ck "O22 [RED→GREEN] 'box' in state/claim-hosts is still not an identity (rc=$(field "$SENT22B" RC))" $S22D
# AND the recorder must refuse to WRITE it, so a later pass cannot re-read it even after the probe
# recovers (the record outlives the failure that created it).
CS22B="$T/cl22-rec"; mkdir -p "$CS22B"
( PATH="$T/bin-nohost22:$PATH"
  unset CLAIM_OWNER_HOST; CLAIM_REPO="$T/repo"; CLAIM_STATE_DIR="$CS22B"; export PATH CLAIM_REPO CLAIM_STATE_DIR
  . "$CLAIMS_SH" || exit 1
  claim_owner >/dev/null ) 2>/dev/null
[ ! -s "$CS22B/claim-hosts" ] || ! grep -qx 'box' "$CS22B/claim-hosts"
S22E=$?
ck "O22 [PINNED] the RECORDER refuses to write the sentinel into claim-hosts" $S22E

echo
echo "── O23: an UNANSWERABLE identity abstains BEFORE the roster comparison (steal direction) ─"
# ⛔ THE STALENESS GUARD MUST NOT BE BYPASSABLE BY THE PROBE FAILURE IT EXISTS TO CATCH (P1, cycle-12
# review). `claim_host` prints the EMPTY STRING when `hostname -s` exits 0 printing nothing, so the
# allow-list pattern `*" $(claim_host) "*` became `*"  "*` — which matches any roster carrying two
# consecutive spaces (a trailing comma, a double space). Measured on the pre-fix code: a LIVE unlisted
# peer returned rc=0 "owner host peerC is not in CLAIM_KNOWN_HOSTS" — the destructive verdict — so
# `claim_prune` deleted the ref and `claim_acquire` reclaimed a live peer's claim.
mkdir -p "$T/bin-emptyh23"
printf '#!/bin/sh\nexit 0\n' > "$T/bin-emptyh23/hostname"; chmod +x "$T/bin-emptyh23/hostname"
# ⛔ SOURCED, AND STDERR ASSERTED EMPTY (P1, cycle-13 review): a bare `claim_host` in a shell that
# never sourced claims.sh printed `claim_host: command not found` and the `-z` test passed for THAT
# reason — a setup assertion true by accident, with the error visible in the suite's own output.
EMPTYH23="$(
  CLAIM_REPO="$T/repo"; CLAIM_STATE_DIR="$T/cl23"; export CLAIM_REPO CLAIM_STATE_DIR
  . "$CLAIMS_SH" || exit 1
  PATH="$T/bin-emptyh23:$PATH"; export PATH
  printf 'OUT=[%s]' "$(claim_host)" 2>"$T/o23.err"
  printf ' ERRSIZE=%s' "$(wc -c < "$T/o23.err" | tr -d ' ')" )"
[ "$EMPTYH23" = "OUT=[] ERRSIZE=0" ]
O23PRE=$?
ck "O23 (setup) the shim really makes claim_host print the EMPTY string silently (got '$EMPTYH23')" $O23PRE
n=0
for R in 'peerA,peerB' 'peerA,peerB,' 'peerA  peerB' ',peerA' 'peerA,,peerB'; do
  n=$((n+1))
  OUT23="$(
    PATH="$T/bin-emptyh23:$PATH"
    CLAIM_REPO="$T/repo"; CLAIM_STATE_DIR="$T/cl23"; CLAIM_KNOWN_HOSTS="$R"
    export PATH CLAIM_REPO CLAIM_STATE_DIR CLAIM_KNOWN_HOSTS
    mkdir -p "$CLAIM_STATE_DIR"
    . "$CLAIMS_SH" || exit 1
    r="$(claim_orphan_reason "peerC:4242" "refs/claims/9209600${n}-0123456789ab")"
    printf "RC=%s\n" "$?" )"
  [ "$(field "$OUT23" RC)" = "1" ]; O23=$?
  ck "O23 [RED→GREEN] roster '$R' + an EMPTY hostname never declares a live peer orphaned (rc=$(field "$OUT23" RC))" $O23
done
# AND the control: with a working probe the SAME roster that NAMES this box still reaps — so the fix
# abstains on the identity, not on the whole arm (a suite that stopped reaping entirely would pass the
# five checks above and defeat the fix's purpose).
OUT23P="$(
  CLAIM_REPO="$T/repo"; CLAIM_STATE_DIR="$T/cl23p"; CLAIM_KNOWN_HOSTS="$(hostname -s),peerB"
  export CLAIM_REPO CLAIM_STATE_DIR CLAIM_KNOWN_HOSTS
  mkdir -p "$CLAIM_STATE_DIR"
  . "$CLAIMS_SH" || exit 1
  claim_orphan_reason "peerC:4242" "refs/claims/9209699-0123456789ab" >/dev/null 2>&1
  printf "RC=%s\n" "$?" )"
[ "$(field "$OUT23P" RC)" = "0" ]; O23P=$?
ck "O23 [PINNED] with an ANSWERABLE identity the roster arm still reaps an unlisted peer (rc=$(field "$OUT23P" RC))" $O23P

echo
echo "── O24: with a SEAM set, this machine's own hostname is still LOCAL (steal direction) ─────────"
# ⛔ `claim_host` RETURNS THE SEAM, AND `claim_former_hosts` EXCLUDES THE PROBED REAL NAME (P1, cycle-13
# review) — so under a seam a claim stamped with THIS machine's real hostname matched neither "the host"
# nor "a former name", skipped the pid probe, and reached the roster arm, which called it ORPHANED.
# Measured on a live pid: rc=0 "owner host <realHost> is not in CLAIM_KNOWN_HOSTS" (and the same for an
# `issue-` ref) against rc=1 held-by-live with the seam unset. `claim_prune` deletes on rc=0 and
# `claim_acquire` reclaims, so that is the steal direction on a claim whose holder this box can SEE.
REAL24="$(hostname -s)"
o24() { # o24 <owner> <ref> <roster>
  CLAIM_REPO="$T/repo"; CLAIM_STATE_DIR="$T/cl24"; CLAIM_OWNER_HOST=seam24
  CLAIM_KNOWN_HOSTS="$3"; export CLAIM_REPO CLAIM_STATE_DIR CLAIM_OWNER_HOST CLAIM_KNOWN_HOSTS
  mkdir -p "$CLAIM_STATE_DIR"
  . "$CLAIMS_SH" || exit 1
  r="$(claim_orphan_reason "$1" "$2")"
  printf "RC=%s\nR=[%s]\n" "$?" "$r"
}
O24A="$(o24 "$REAL24:$$" 'refs/claims/9209700-0123456789ab' 'seam24 peer1')"
[ "$(field "$O24A" RC)" = "1" ]; O24A_RC=$?
ck "O24 [RED→GREEN] a LIVE local pid under the REAL hostname is held even with a seam set (rc=$(field "$O24A" RC))" $O24A_RC
O24B="$(o24 "$REAL24:$$" 'refs/claims/issue-9209701' 'seam24 peer1')"
[ "$(field "$O24B" RC)" = "1" ]; O24B_RC=$?
ck "O24 [RED→GREEN] ... and an ISSUE key under the REAL hostname is not called a stranger (rc=$(field "$O24B" RC))" $O24B_RC
# CONTROLS — the fix must not stop the arm from working. (a) the SAME real hostname with a pid that is
# DEAD is still orphaned: the name is local, so the pid is probeable and its absence is evidence.
DEAD24=999999
while ps -p "$DEAD24" >/dev/null 2>&1; do DEAD24=$((DEAD24+1)); done
O24C="$(o24 "$REAL24:$DEAD24" 'refs/claims/9209702-0123456789ab' 'seam24 peer1')"
[ "$(field "$O24C" RC)" = "0" ]; O24C_RC=$?
ck "O24 [PINNED] a DEAD pid under the same local name IS still orphaned (rc=$(field "$O24C" RC))" $O24C_RC
# (b) a PEER host that the roster omits is still reaped — the abstention is about THIS box only.
O24D="$(o24 "peer9:4242" 'refs/claims/9209703-0123456789ab' 'seam24 peer1')"
[ "$(field "$O24D" RC)" = "0" ]; O24D_RC=$?
ck "O24 [PINNED] a peer host the roster OMITS is still reaped (rc=$(field "$O24D" RC))" $O24D_RC
# ⛔ AND THE STALENESS GUARD CAN BE SATISFIED BY EITHER NAME, SO BOTH NEED THE ABSTENTION (P1, cycle-14
# review). With the seam set and a roster naming the REAL host only, a claim stamped `seam24:<live pid>`
# passed the guard, failed the `*" $host "*` match, and was called ORPHANED — measured rc=0, while the
# same owner on a PR ref read held-by-live.
# ⛔ THE ROSTER MUST CARRY THE REAL HOSTNAME, NOT A PLACEHOLDER (measured: substituting into the OUTPUT
# left the roster as the literal `REALHOST peer1`, which then failed the staleness guard and abstained
# for the wrong reason — the case stayed green under the mutation that removes the guard it targets).
O24E="$(o24 "seam24:$$" 'refs/claims/issue-9209704' "$REAL24 peer1")"
[ "$(field "$O24E" RC)" = "1" ]; O24E_RC=$?
ck "O24 [RED→GREEN] under a seam, a roster naming only the REAL host does not reap the seam owner (rc=$(field "$O24E" RC))" $O24E_RC
# ⛔ AND THE `box` SENTINEL IS NOT JUDGEABLE FROM A ROSTER (P1, cycle-14 review): every cell that loses
# its `hostname` probe stamps `box`, while any roster lists the box's real NAME — so the match never
# fires for it and every live claim that cell mints is reaped by any peer holding a roster.
O24F="$(o24 'box:999999' 'refs/claims/9209705-0123456789ab' "$REAL24 peer1")"
[ "$(field "$O24F" RC)" = "1" ]; O24F_RC=$?
ck "O24 [RED→GREEN] the 'box' sentinel is NOT reaped by a roster that names this box's real name (rc=$(field "$O24F" RC))" $O24F_RC
# control: an explicit `CLAIM_DEAD_HOSTS=box` still reaps — the operator's own statement is not a roster
# inference, and the deny list is checked above the roster arm.
O24G="$(
  CLAIM_REPO="$T/repo"; CLAIM_STATE_DIR="$T/cl24"; CLAIM_OWNER_HOST=seam24
  CLAIM_KNOWN_HOSTS="$REAL24 peer1"; CLAIM_DEAD_HOSTS="box"
  export CLAIM_REPO CLAIM_STATE_DIR CLAIM_OWNER_HOST CLAIM_KNOWN_HOSTS CLAIM_DEAD_HOSTS
  mkdir -p "$CLAIM_STATE_DIR"
  . "$CLAIMS_SH" || exit 1
  claim_orphan_reason "box:999999" "refs/claims/9209706-0123456789ab" >/dev/null 2>&1
  printf "RC=%s\n" "$?" )"
[ "$(field "$O24G" RC)" = "0" ]; O24G_RC=$?
ck "O24 [PINNED] an explicit CLAIM_DEAD_HOSTS=box still reaps the sentinel (rc=$(field "$O24G" RC))" $O24G_RC

echo
echo "── O25: the PID arm is matched on the ref SHAPE, and the host rules still run for issue keys ──"
# ⛔ P1, cycle-17 review: the two shape arms were pinned by NOTHING — reverting `*[0-9]*-*` to `*-*` and
# deleting the `*issue-*` arm left the suite green while restoring the defect: the PR-only pid rule
# judging an ISSUE key (`issue-1234`) and opening the shared-barrier window it exists to close. The
# three-way contrast below is what makes the shapes load-bearing.
SHAPE() { # SHAPE <ref> [<owner>] [<CLAIM_DEAD_HOSTS>]
  CLAIM_REPO="$T/repo"; CLAIM_STATE_DIR="$T/cl25"
  CLAIM_DEAD_HOSTS="${3:-}"
  export CLAIM_REPO CLAIM_STATE_DIR CLAIM_DEAD_HOSTS
  mkdir -p "$CLAIM_STATE_DIR"
  . "$CLAIMS_SH" || exit 1
  r="$(claim_orphan_reason "${2:-$REAL24:$DEADPID16}" "$1")"
  printf "RC=%s\nR=[%s]\n" "$?" "$r"
}
# (a) a BARE issue key must NOT take the pid arm (the host is this box, the pid is gone — the pid rule
#     would say ORPHANED; an issue key must abstain from it and fall through to the host rules).
O25A="$(SHAPE 'issue-9209800')"
[ "$(field "$O25A" RC)" = "1" ]; O25A_RC=$?
ck "O25 [RED→GREEN] a BARE issue key never takes the pid arm (rc=$(field "$O25A" RC))" $O25A_RC
# (b) an unrecognised hyphenated ref abstains too.
O25B="$(SHAPE 'refs/claims/pr-abc')"
[ "$(field "$O25B" RC)" = "1" ]; O25B_RC=$?
ck "O25 [RED→GREEN] an unrecognised hyphenated ref abstains (rc=$(field "$O25B" RC))" $O25B_RC
# (c) the PR shape DOES take it — the control that keeps the arm alive.
O25C="$(SHAPE 'refs/claims/9209801-0123456789ab')"
[ "$(field "$O25C" RC)" = "0" ]; O25C_RC=$?
ck "O25 [RED→GREEN] a PR ref DOES take the pid arm (rc=$(field "$O25C" RC))" $O25C_RC
# (d) AND the issue key still reaches the HOST rules: both forms of the key must agree on an orphaned
#     host (cycle-17 P2 — `return 1` in that arm made the bare form abstain where this form reclaimed).
O25D="$(SHAPE 'refs/claims/issue-9209802' 'peerQ:4242' 'peerQ')"
O25E="$(SHAPE 'issue-9209802' 'peerQ:4242' 'peerQ')"
[ "$(field "$O25D" RC)" = "0" ] && [ "$(field "$O25E" RC)" = "0" ]; O25D_RC=$?
ck "O25 [RED→GREEN] prefixed and BARE issue keys agree on an orphaned host (prefixed rc=$(field "$O25D" RC), bare rc=$(field "$O25E" RC))" $O25D_RC
# ⛔ AND THE ISSUE ARM NEEDS A SHAPE THAT WOULD OTHERWISE MATCH THE PID ARM (cycle-18 review: for a BARE
# `issue-<N>` the `*[0-9]*-*` pattern can never fire, so deleting `*issue-*)` left the suite green and the
# arm unpinned). This ref is `issue-` + digits + `-` + hex — exactly the PR shape — so only the issue arm
# keeps it off the pid rule.
O25G="$(SHAPE 'refs/claims/issue-9209803-0123456789ab')"
[ "$(field "$O25G" RC)" = "1" ]; O25G_RC=$?
ck "O25 [RED→GREEN] an issue ref shaped like a PR ref still abstains from the pid arm (rc=$(field "$O25G" RC))" $O25G_RC
case "$(field "$O25E" R)" in *DEAD_HOSTS*) O25F_RC=0 ;; *) O25F_RC=1 ;; esac
ck "O25 [RED→GREEN] the BARE issue key's verdict comes from the HOST rules ('$(field "$O25E" R)')" $O25F_RC
# ⛔ THE PID ARM MUST OUTRANK THE DENY LIST, AND THAT ORDERING IS DOCUMENTED AS MEASURED (P2, cycle-21
# review) while nothing pinned it: moving `CLAIM_DEAD_HOSTS` above the ref case made a DENY-listed
# CURRENT host reap a LIVE local PR worker's claim (`720e780d`'s P0, reinstated) and the suite stayed
# green. The guidance "the deny list is safe for PR claims this box minted" rests on exactly this.
O25H="$(
  CLAIM_REPO="$T/repo"; CLAIM_STATE_DIR="$T/cl25"; CLAIM_DEAD_HOSTS="$REAL24"
  export CLAIM_REPO CLAIM_STATE_DIR CLAIM_DEAD_HOSTS
  mkdir -p "$CLAIM_STATE_DIR"
  . "$CLAIMS_SH" || exit 1
  r="$(claim_orphan_reason "$REAL24:$$" 'refs/claims/9209804-0123456789ab')"
  printf "RC=%s\nR=[%s]\n" "$?" "$r" )"
[ "$(field "$O25H" RC)" = "1" ]; O25H_RC=$?
ck "O25 [RED→GREEN] a LIVE local PR pid OUTRANKS a deny list naming this box (rc=$(field "$O25H" RC))" $O25H_RC
# `claim_orphan_reason` prints NOTHING when it does not judge the claim orphaned; the `held-by-live`
# token is produced by the CALLERS (claim_acquire/claim_status), not by this predicate — so the
# assertion here is "no reason for a live local pid", not a token match.
# the helper prints `R=[<reason>]`, so "no reason" is the literal `[]`.
[ "$(field "$O25H" R)" = "[]" ]; O25H2_RC=$?
# ⛔ PINNED, NOT RED→GREEN (cycle-22 review): pre-change `claim_orphan_reason` does not exist, so
# the subshell exits 127 and `R` is empty for a reason UNRELATED to the ordering being pinned — this
# assertion is structurally green on the old tree. It discriminates only in COMPANY (the rc=1 check
# above it, and the reordering mutant, which reddens both), which is exactly what PINNED means.
ck "O25 [PINNED] ... and it reports NO orphan reason at all ('$(field "$O25H" R)')" $O25H2_RC
# control: the SAME deny-listed host with a DEAD pid IS reaped — so the ordering, not a disabled arm.
O25I="$(
  CLAIM_REPO="$T/repo"; CLAIM_STATE_DIR="$T/cl25"; CLAIM_DEAD_HOSTS="$REAL24"
  export CLAIM_REPO CLAIM_STATE_DIR CLAIM_DEAD_HOSTS
  . "$CLAIMS_SH" || exit 1
  claim_orphan_reason "$REAL24:$DEADPID16" 'refs/claims/9209805-0123456789ab' >/dev/null 2>&1
  printf "RC=%s\n" "$?" )"
[ "$(field "$O25I" RC)" = "0" ]; O25I_RC=$?
ck "O25 [PINNED] ... while the SAME deny-listed host with a DEAD pid is reaped (rc=$(field "$O25I" RC))" $O25I_RC

echo
echo "── O26: the PRE-FLIGHT's unparseable-lease order (a FALSE CLEAN duplicates the work) ────"
# ⛔ P1, cycle-18 review: `claim_issue_preflight` is the FOURTH reader of the same decision and the only
# one nothing pinned. A mutant that consults `claim_orphan_reason` inside its `_lease_unparseable`
# branch returns rc=0 CLEAN for a `lease_until=0` claim whose host is on CLAIM_DEAD_HOSTS — which is
# exactly the duplicate dispatch the pre-flight exists to prevent — while this suite and test-claims
# both stayed green. The pair below is O9's, moved to the pre-flight.
PRE26() { # PRE26 <issue> <owner> <lease-until> <CLAIM_DEAD_HOSTS-or-empty>
  CLAIM_REPO="$T/repo"; CLAIM_STATE_DIR="$T/cl26"
  CLAIM_DEAD_HOSTS="${4:-}"
  export CLAIM_REPO CLAIM_STATE_DIR CLAIM_DEAD_HOSTS
  mkdir -p "$CLAIM_STATE_DIR"
  . "$CLAIMS_SH" || exit 1
  c="$(_claim_commit "$2" "$3")"
  _git push -q --force origin "$c:refs/claims/issue-$1" 2>/dev/null
  r="$(claim_issue_preflight "$1")"
  printf "RC=%s\nR=[%s]\n" "$?" "$r"
}
O26A="$(PRE26 9209900 'deadhostq:4242' 0 'deadhostq')"
[ "$(field "$O26A" RC)" = "1" ]; O26A_RC=$?
ck "O26 [PINNED] an UNPARSEABLE lease on a DEAD-listed host is NOT clean (rc=$(field "$O26A" RC))" $O26A_RC
case "$(field "$O26A" R)" in *held-by-live*) O26B_RC=0 ;; *) O26B_RC=1 ;; esac
ck "O26 [PINNED] ... and it names the token ('$(field "$O26A" R)')" $O26B_RC
O26C="$(PRE26 9209901 'deadhostq:4243' 1000000000 'deadhostq')"
[ "$(field "$O26C" RC)" = "0" ]; O26C_RC=$?
ck "O26 [PINNED] CONTROL: a PARSEABLE expired lease on the same host IS clean (rc=$(field "$O26C" RC))" $O26C_RC

echo
echo "─────────────────────────────────────────────────────────────"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
