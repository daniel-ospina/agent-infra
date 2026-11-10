#!/usr/bin/env bash
# controller-state.test.sh — WHERE a controller keeps its state, and WHETHER it may run (agent-infra#2095).
#
# ⛔ WHAT THIS SUITE IS FOR. A proof copy of `orch-loop.sh` ran LIVE for 5 h 15 m beside the launchd
# controller, sharing one state dir and one log, applying its own derived MAX_LOAD=100 against the
# plist's 250. Two independent defects produced that, and the checks below are grouped by them:
#
#   §1  the STATE DIR a copy uses — an existing install must be untouched (an explicit `O` still wins
#       verbatim), and a copy that is NOT the deployed one must land in an ISOLATED dir instead of
#       adopting production. The last case is the incident itself: a foreign copy with no `O` set.
#   §2  the SINGLETON — a live holder refuses (rc 1), and the refusal is the caller's to make LOUD and
#       NON-ZERO (`orch-loop.sh` exits 75). A bare `kill -0` accepted a RECYCLED pid, so that arm is
#       driven with a real process whose record was backdated: it must be reclaimed, not obeyed.
#   §3  fail-CLOSED on an unjudgeable record: an unreadable age is not evidence of ownership, and it
#       is not evidence of death either — so the instance refuses instead of picking a side.
#   §4  release is OWNERSHIP-SCOPED: an instance never deletes a record naming somebody else.
#   §5  the identity mirror has not drifted from `scripts/lib/pid-identity.sh` (#1178's rule).
#
# ⛔ EVERY CASE DRIVES THE SHIPPED FILE. No re-implementation and no copy of the logic: `orch-loop.sh`
# is exercised through real `bash` invocations in a temp state dir, and the assertions read the real
# exit code, the real stderr and the real log. A case that only sourced its own stub would pass on a
# loop whose wiring had been deleted — so §2's sharpest arm runs the REAL `orch-loop.sh` and asserts
# `rc=75` plus the `[singleton]` log line.
#
# ⛔ NO NETWORK, NO MODEL, NO LAUNCHD, NO TOUCHING OF PRODUCTION. `ORC_PROD_STATE` is re-pointed at a
# temp dir for every case, so the suite cannot read or write `$HOME/orchestrator` even on a box that
# is running a live controller. That is asserted in §0, not assumed.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD="$HERE/controller-state.sh"
LOOP="$HERE/orch-loop.sh"
PASS=0; FAIL=0
ck() { # ck <name> <0|1>
  if [ "$2" -eq 0 ]; then printf '  ✅ %s\n' "$1"; PASS=$((PASS+1));
  else printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); fi
}
hdr() { printf '\n── %s\n' "$1"; }
need() { # need <path> <description> — a missing input is a FAILED case, never a silent skip
  if [ -e "$1" ]; then return 0; fi
  printf '  ❌ MISSING: %s (%s)\n' "$2" "$1"; FAIL=$((FAIL+1)); return 1
}
T="${TMPDIR:-/tmp}/orc-cs-test-$$"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T" || { echo "cannot create $T"; exit 1; }

hdr "§0 the suite cannot reach a production state dir"
if need "$MOD" "the shipped controller-state.sh"; then
  # shellcheck disable=SC1090
  . "$MOD"
  ck "§0 controller-state.sh sources cleanly and defines orc_state_pick" \
     "$(command -v orc_state_pick >/dev/null 2>&1 && echo 0 || echo 1)"
  # The production path is a VARIABLE, so the suite re-points it and proves the redirection took. A
  # case that silently graded the real `$HOME/orchestrator` would be a suite that can damage a live
  # box, and the guard has to be a measurement rather than a promise.
  ORC_PROD_STATE="$T/prod"
  mkdir -p "$ORC_PROD_STATE"
  orc_state_pick "$T/copy" ""
  case "$ORC_STATE_RESOLVED" in
    "$ORC_PROD_STATE") ck "§0 the production redirect did NOT take (refusing to run destructively)" 1 ;;
    *) ck "§0 production state is redirected to $ORC_PROD_STATE for the whole suite" 0 ;;
  esac
fi

# ─────────────────────────────────────────────────────────────────────────────────────────────────
hdr "§1 WHICH STATE DIR — an existing install is untouched, a copy is isolated"
# The order is the contract: (1) ORC_STATE_DIR, (2) an explicit `O` (what every plist and cell
# supervisor sets), (3) the copy that LIVES in production, (4) anything else is isolated.
mkdir -p "$T/prod" "$T/proof" "$T/other"

( ORC_STATE_DIR="$T/explicit" ; orc_state_pick "$T/proof" "$T/legacyO"
  printf '%s|%s\n' "$ORC_STATE_RESOLVED" "$ORC_STATE_SRC" ) > "$T/o1"
[ "$(cat "$T/o1")" = "$T/explicit|env:ORC_STATE_DIR" ] \
  && ck "§1 an explicit ORC_STATE_DIR wins over everything (src names it)" 0 \
  || ck "§1 an explicit ORC_STATE_DIR wins over everything — got '$(cat "$T/o1")'" 1

( orc_state_pick "$T/proof" "$T/legacyO"
  printf '%s|%s\n' "$ORC_STATE_RESOLVED" "$ORC_STATE_SRC" ) > "$T/o2"
[ "$(cat "$T/o2")" = "$T/legacyO|env:O" ] \
  && ck "§1 an explicit legacy O wins VERBATIM — every deployed plist/supervisor keeps its state dir" 0 \
  || ck "§1 an explicit legacy O wins verbatim — got '$(cat "$T/o2")'" 1

( orc_state_pick "$T/prod" ""
  printf '%s|%s\n' "$ORC_STATE_RESOLVED" "$ORC_STATE_SRC" ) > "$T/o3"
[ "$(cat "$T/o3")" = "$ORC_PROD_STATE|default:production" ] \
  && ck "§1 the copy that LIVES in production still uses production (its state is not moved)" 0 \
  || ck "§1 the copy in production uses production — got '$(cat "$T/o3")'" 1

# ⛔ THE INCIDENT ITSELF. `/tmp/orc-proof/orch-loop.sh` with no `O` exported is the shape that shared
# production state for 5 h 15 m. It must land under $TMPDIR, and it must NOT be $HOME/orchestrator.
( orc_state_pick "$T/proof" ""
  printf '%s|%s\n' "$ORC_STATE_RESOLVED" "$ORC_STATE_SRC" ) > "$T/o4"
ORC_FOREIGN_DIR="$(sed 's/|.*//' "$T/o4")"
case "$ORC_FOREIGN_DIR" in
  "$ORC_PROD_STATE") ck "§1 a FOREIGN copy with no O adopted PRODUCTION state (the #2095 incident)" 1 ;;
  */orc-state-*) ck "§1 a foreign copy with no O gets an ISOLATED state dir, never production" 0 ;;
  *) ck "§1 a foreign copy's state dir is not the isolated shape — got '$ORC_FOREIGN_DIR'" 1 ;;
esac
case "$(cat "$T/o4")" in
  *"derived:isolated("*"$T/proof"*) ck "§1 the isolated choice NAMES the copy that caused it (src=$ORC_STATE_SRC)" 0 ;;
  *) ck "§1 the isolated choice names the copy — got '$(cat "$T/o4")'" 1 ;;
esac

# Two DIFFERENT copies must not share one isolated dir: a collision would make two proof runs one
# controller (which is the defect, one directory over).
( mkdir -p "$T/proof2"; orc_state_pick "$T/proof" ""; A="$ORC_STATE_RESOLVED"
  orc_state_pick "$T/proof2" ""; printf '%s|%s\n' "$A" "$ORC_STATE_RESOLVED" ) > "$T/o5"
[ "$(cut -d'|' -f1 "$T/o5")" != "$(cut -d'|' -f2 "$T/o5")" ] \
  && ck "§1 two different copies get two different isolated state dirs" 0 \
  || ck "§1 two copies got the SAME isolated dir — one singleton would cover both" 1

# A trailing slash and a symlinked spelling are the same directory, or an instance started through a
# link would take a second state dir for the same copy and pass its own singleton.
( mkdir -p "$T/prod2"; ln -sfn "$T/prod2" "$T/prodlink"
  orc_state_pick "$T/prod2/" ""
  A="$ORC_STATE_RESOLVED"
  orc_state_pick "$T/prodlink" ""
  printf '%s|%s\n' "$A" "$ORC_STATE_RESOLVED" ) > "$T/o6"
[ "$(cut -d'|' -f1 "$T/o6")" = "$(cut -d'|' -f2 "$T/o6")" ] \
  && ck "§1 a trailing slash and a symlinked spelling resolve to the SAME state dir" 0 \
  || ck "§1 path spelling changed the state dir — got '$(cat "$T/o6")'" 1

# ⛔ THE SLUG IS A NAME, NOT A PATH (fresh-context review of #3846, cosmetic). `orc_state_slug`
# sanitises EVERY non-[A-Za-z0-9._-] byte to `_` — `/` included — so a copy's path can never create a
# NESTED state dir: the isolated dir must stay a DIRECT child of `ORC_ISOLATED_ROOT`. This is the
# property a `base="${base##*/}"` in `orc_state_slug` used to LOOK like it was providing; the
# sanitising `tr` provides it, the dead line is gone, and this arm is what makes the claim checkable
# rather than a comment (a sanitising regression puts the state dir one level down, under a
# directory named after part of the copy's path).
( orc_state_pick "$T/deep/er/still/proof" ""; printf '%s\n' "$ORC_STATE_RESOLVED" ) > "$T/o7"
[ "$(dirname "$(cat "$T/o7")")" = "$ORC_ISOLATED_ROOT" ] \
  && ck "§1 an isolated state dir is a DIRECT child of the isolated root (the slug is a name, not a path)" 0 \
  || ck "§1 the isolated state dir escaped the isolated root — got '$(cat "$T/o7")'" 1

# ⛔ AND THE RESOLVED DIR MUST BE EXPORTED (fresh-context review of #3846, P1). Three of the loop's
# DIRECT children re-default `O` themselves (`harness-refresh.sh`, `refresh-candidates.sh`,
# `dispatch-merge.sh`, each with `O="${O:-$HOME/orchestrator}"`), so an instance whose state dir is not
# production had its refresh rewrite PRODUCTION's queue and its dispatch-merge write production's
# bookkeeping — while the loop printed "PRODUCTION state is untouched by this instance". The worker
# path already exported it (`worker-terminal.sh`'s env snapshot exists for exactly this reason); the
# direct children did not. An unexported assignment is invisible behaviour, so it is pinned here.
if need "$LOOP" "the shipped orch-loop.sh"; then
  _assign_line="$(grep -n '^O="\$ORC_STATE_RESOLVED"$' "$LOOP" | head -1 | cut -d: -f1)"
  _export_line="$(grep -n '^export O$' "$LOOP" | head -1 | cut -d: -f1)"
  if [ -z "$_assign_line" ] || [ -z "$_export_line" ]; then
    ck "§1 the loop assigns the resolved state dir AND exports it (children re-default to production)" 1
  elif [ "$_export_line" -gt "$_assign_line" ]; then
    ck "§1 the loop EXPORTS the resolved O, after the assignment (children cannot fall back to production)" 0
  else
    ck "§1 'export O' sits BEFORE the resolved assignment — children would get the un-resolved value" 1
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────────────────────────
hdr "§2 THE SINGLETON — a live holder is refused, a recycled pid is reclaimed"
LK="$T/lk"; mkdir -p "$LK"

# Acquire in a SEPARATE PROCESS (not a subshell: under bash `$$` is the parent's pid even inside
# `( )`, so a subshell holder would record the suite's own pid and prove nothing about a second
# instance), then try a second one: the holder is live and began before the record was written, so
# the second must be refused (1), not steal it.
cat > "$T/holder.sh" <<'HSTUB'
set -u
. "$1"
orc_singleton_acquire "$2"
echo "rc=$?" > "$3"
sleep 5
HSTUB
bash "$T/holder.sh" "$MOD" "$LK/.orch.lock" "$T/acq1" & HPID=$!
i=0; while [ ! -f "$T/acq1" ] && [ $i -lt 60 ]; do sleep 0.1; i=$((i+1)); done
if need "$LK/.orch.lock" "the first instance took the lock"; then
  [ "$(cat "$LK/.orch.lock")" = "$HPID" ] \
    && ck "§2 the record is a BARE PID on one line (six shipped tools parse it that way)" 0 \
    || ck "§2 the record is a bare pid — got '$(cat "$LK/.orch.lock")', wanted $HPID" 1
  ( . "$MOD"; orc_singleton_acquire "$LK/.orch.lock"; printf '%s\n%s\n' "$?" "$ORC_SINGLETON_WHY" ) > "$T/acq2"
  [ "$(sed -n 1p "$T/acq2")" = "1" ] \
    && ck "§2 a LIVE holder is refused with rc 1 (not stolen, not a silent success)" 0 \
    || ck "§2 a live holder was not refused — got '$(cat "$T/acq2")'" 1
  case "$(sed -n 2p "$T/acq2")" in
    *"$HPID"*) ck "§2 the refusal NAMES the holder pid (the human does not have to go looking)" 0 ;;
    *) ck "§2 the refusal does not name the holder — got '$(sed -n 2p "$T/acq2")'" 1 ;;
  esac
  # ⛔ OWNERSHIP-SCOPED RELEASE: this process does not own the record, so it must survive.
  ( . "$MOD"; orc_singleton_release "$LK/.orch.lock" )
  [ -f "$LK/.orch.lock" ] \
    && ck "§2 a NON-owner's release leaves the record alone" 0 \
    || ck "§2 a non-owner's release DELETED the holder's record" 1
fi
kill -TERM "$HPID" 2>/dev/null; wait "$HPID" 2>/dev/null

# A DEAD holder (the SIGKILL/OOM/reboot path) is reclaimed.
printf '999999\n' > "$LK/.orch.lock"
( . "$MOD"; orc_singleton_acquire "$LK/.orch.lock"; printf '%s|%s\n' "$?" "$ORC_SINGLETON_WHY" ) > "$T/acq3"
case "$(cat "$T/acq3")" in
  0\|*DEAD*) ck "§2 a provably DEAD holder is reclaimed (and the reason says so)" 0 ;;
  *) ck "§2 a dead holder was not reclaimed — got '$(cat "$T/acq3")'" 1 ;;
esac
[ "$(cat "$LK/.orch.lock")" = "$$" ] \
  && ck "§2 the reclaimed record names the new owner" 0 \
  || ck "§2 the reclaimed record does not name the new owner — got '$(cat "$LK/.orch.lock")'" 1

# ⛔ THE RECYCLED PID. A `sleep` is started FIRST, then a record naming its pid is written and
# BACKDATED five minutes: the process is alive, and it began AFTER the record was written, so it
# cannot be that record's owner. The shipped `kill -0` test called this "already running" for ever.
sleep 30 & RPID=$!
printf '%s\n' "$RPID" > "$LK/.orch.lock"
touch -t "$(date -v-5M +%Y%m%d%H%M.%S 2>/dev/null || date -d '-5 minutes' +%Y%m%d%H%M.%S)" "$LK/.orch.lock" 2>/dev/null
( . "$MOD"; orc_singleton_acquire "$LK/.orch.lock"; printf '%s|%s\n' "$?" "$ORC_SINGLETON_WHY" ) > "$T/acq4"
case "$(cat "$T/acq4")" in
  0\|*RECYCLED*) ck "§2 a LIVE but RECYCLED pid is reclaimed, not obeyed (the bare \`kill -0\` defect)" 0 ;;
  *) ck "§2 a recycled pid was not reclaimed — got '$(cat "$T/acq4")'" 1 ;;
esac
kill -0 "$RPID" 2>/dev/null \
  && ck "§2 the reclaimed pid's process was NOT signalled (reclaim displaces a RECORD, never a process)" 0 \
  || ck "§2 reclaim killed the unrelated process holding the recycled pid" 1
kill -9 "$RPID" 2>/dev/null; wait "$RPID" 2>/dev/null

# An EMPTY record: every shipped reader already treats it as STOPPED, so it is reclaimed, not obeyed.
: > "$LK/.orch.lock"
( . "$MOD"; orc_singleton_acquire "$LK/.orch.lock"; printf '%s|%s\n' "$?" "$ORC_SINGLETON_WHY" ) > "$T/acq5"
case "$(cat "$T/acq5")" in
  0\|*EMPTY*) ck "§2 an EMPTY record (the shape \`status\` reads as STOPPED) is reclaimed" 0 ;;
  *) ck "§2 an empty record was not reclaimed — got '$(cat "$T/acq5")'" 1 ;;
esac

# ⛔ THE RECLAIM RESTORE MUST NOT OVERWRITE A LATER WINNER (fresh-context review of #3846, P3).
# Three starters interleaved: we judged record 111 stale, and while we were judging, a THIRD starter
# created its own record at the same path. The restore's job is to put the DISPLACED record back — but
# `mv -f` REPLACES, so the unfixed code swapped the winner's record for the judged pid and returned a
# refusal, leaving a record nobody owns (the winner's ownership-scoped release then leaves it alone).
# `orc_lock_pid` is overridden IN THIS SUBSHELL so the read that decides "somebody else took it" also
# lets that third starter win the path: deterministic, with no race to lose. The discriminator is the
# surviving record, not rc — both shapes return 1.
LKR="$T/lkr"; mkdir -p "$LKR"
printf '111\n' > "$LKR/.orch.lock"
( . "$MOD"
  orc_lock_pid() { printf '333\n' > "$LKR/.orch.lock"; printf '%s\n' 222; }
  orc_lock_reclaim "$LKR/.orch.lock" 111; printf 'rc=%s\n' "$?" ) > "$T/rcl1" 2>&1
[ "$(cat "$T/rcl1")" = "rc=1" ] \
  && ck "§2 a contested reclaim still reports the refusal (rc 1)" 0 \
  || ck "§2 a contested reclaim returned '$(cat "$T/rcl1")', wanted rc=1" 1
[ "$(cat "$LKR/.orch.lock")" = "333" ] \
  && ck "§2 the reclaim restore did NOT overwrite a later winner's record (it only fills a free path)" 0 \
  || ck "§2 the reclaim restore OVERWROTE a later winner's record — got '$(cat "$LKR/.orch.lock" 2>/dev/null)', wanted 333" 1
case "$(ls "$LKR"/.orch.lock.reclaim.* 2>/dev/null)" in
  '') ck "§2 …and it leaves no reclaim temp file beside the record" 0 ;;
  *)  ck "§2 …and it left a reclaim temp file beside the record: $(ls "$LKR"/.orch.lock.reclaim.* 2>/dev/null | tr '\n' ' ')" 1 ;;
esac

# ⛔ THE CHECK-THEN-ACT WAS THE FINDING, AND THE ROW ABOVE CANNOT SEE IT (fresh review of #3846, P2).
# That row proves the SEQUENTIAL case: the winner's record already exists when the restore runs, so a
# `[ -e ]` test sees it. The defect is the window BETWEEN that test and the write — `mv -f` is
# `rename(2)` and replaces unconditionally, so a third starter that noclobber-created its record in
# that window was still overwritten by the older pid; the winner believed it held the lock, its
# ownership-scoped release left the record alone, and the next starter reclaimed a record naming a
# stale pid (two controllers on one state dir, #1715).
# So this row injects the third starter AT THE FILL ITSELF. The `ln` shim below creates the winner's
# record first and then runs the REAL `ln`, so the fill's own create-if-absent is what decides: `ln`
# refuses an occupied path and the winner survives. The assertion is the SURVIVING RECORD, so it does
# not care which primitive the fix chose — only that it cannot replace: a revert to `mv -f`, or to
# `cp`/a plain `>`, never reaches the shim, finds a FREE path, and writes the DISPLACED record (111)
# over nothing — which reddens the row below just as hard (measured: `rc=2, record=111` on the
# pre-fix code).
# ⛔ ONLY `ln` IS SHIMMED, AND `mv` DELIBERATELY IS NOT. Shimming `mv` as `command mv "$@"` makes this
# FILE read as a discard whose target is a runtime expansion, and the repo's own `main-worktree-guard`
# then refuses to run the suite at all (`script-indirection`, #709) — a test that cannot be executed is
# a broken test, and buying this row's fidelity with the suite's runnability is not a trade worth making.
LKQ="$T/lkq"; mkdir -p "$LKQ"
printf '111\n' > "$LKQ/.orch.lock"     # the record this caller is judging
( . "$MOD"
  # The record CHANGED under us: the temp read answers a different pid than the one judged (so the
  # take-it-back path is the one under test), while the real records stay readable.
  orc_lock_pid() { case "${1:-}" in */.orch.lock.reclaim.*) printf '222\n' ;; *) command tr -dc '0-9' < "$1" 2>/dev/null ;; esac; }
  # ⛔ THE THIRD STARTER LANDS AT THE FILL: the link's destination (its LAST non-option argument) is
  # occupied first, and then the REAL `ln` runs and has to refuse it.
  ln() { local _a _dst=""; for _a in "$@"; do case "$_a" in -*) ;; *) _dst="$_a" ;; esac; done
         case "$_dst" in */.orch.lock) printf '333\n' > "$_dst" ;; esac
         command ln "$@"; }
  orc_lock_reclaim "$LKQ/.orch.lock" 111; printf 'rc=%s holder=%s\n' "$?" "$ORC_RECLAIM_HOLDER" ) > "$T/rcl-race" 2>&1
[ "$(cat "$LKQ/.orch.lock" 2>/dev/null)" = "333" ] \
  && ck "§2 a third starter that creates the record AT THE FILL keeps its record (the restore cannot replace it)" 0 \
  || ck "§2 the restore OVERWROTE the record a third starter created in the check-then-act window — got '$(cat "$LKQ/.orch.lock" 2>/dev/null)', wanted 333" 1
[ "$(cat "$T/rcl-race" | tr '\n' ' ')" = "rc=1 holder=333 " ] \
  && ck "§2 …and the refusal is rc 1 naming the real winner (not UNJUDGED)" 0 \
  || ck "§2 the raced reclaim returned '$(cat "$T/rcl-race" | tr '\n' ' ')' — wanted 'rc=1 holder=333 '" 1
case "$(ls "$LKQ"/.orch.lock.reclaim.* 2>/dev/null)" in
  '') ck "§2 …and the raced restore leaves no reclaim temp file" 0 ;;
  *)  ck "§2 …and the raced restore left a reclaim temp file: $(ls "$LKQ"/.orch.lock.reclaim.* 2>/dev/null | tr '\n' ' ')" 1 ;;
esac

# ⛔ LOSING OUR OWN FINAL CREATE IS "HELD", NOT "UNJUDGED" (same finding, second half). `orc_lock_write`
# is a noclobber create, so after the stale record was moved aside the only way it fails is that a
# THIRD starter created the record first — and that starter ACQUIRED. Reporting 2 told `orch-loop.sh` to
# print "the record … could not be judged (contents: '<winner>')" and told `harness-up`'s exit-74 row to
# offer `rm -f .orch.lock` as the remedy, about a fresh readable record naming the LIVE winner.
LKW="$T/lkw"; mkdir -p "$LKW"
printf '999999\n' > "$LKW/.orch.lock"
( . "$MOD"
  orc_lock_write() { printf '333\n' > "$1"; ( set -o noclobber; printf '%s\n' "$$" > "$1" ) 2>/dev/null; }
  orc_lock_reclaim "$LKW/.orch.lock" 999999; printf 'rc=%s holder=%s\n' "$?" "$ORC_RECLAIM_HOLDER" ) > "$T/rcl-lost" 2>&1
[ "$(cat "$T/rcl-lost" | tr '\n' ' ')" = "rc=1 holder=333 " ] \
  && ck "§2 losing our own create race reports HELD (rc 1) naming the winner — NOT UNJUDGED" 0 \
  || ck "§2 losing our own create race returned '$(cat "$T/rcl-lost" | tr '\n' ' ')' — wanted 'rc=1 holder=333 ' (rc 2 turns a live winner into a \`rm -f\` remedy)" 1

# …AND THE ACQUIRE ARM MUST PROPAGATE THAT, because the operator text is built from it: rc 2 is what
# `orch-loop.sh` prints "could not be judged" for and what `harness-up` answers with "rm -f the record".
LKA="$T/lka"; mkdir -p "$LKA"
printf '999999\n' > "$LKA/.orch.lock"     # a DEAD holder, so this instance judges it reclaimable
( . "$MOD"
  _w=0
  orc_lock_write() {
    _w=$((_w+1))
    # call 1 is the ACQUIRE attempt (the record exists, so it fails like the real one); call 2 is the
    # reclaim's create, which now arrives AFTER a third starter has already taken the path.
    if [ "$_w" -ge 2 ]; then printf '333\n' > "$1"; fi
    ( set -o noclobber; printf '%s\n' "$$" > "$1" ) 2>/dev/null
  }
  orc_singleton_acquire "$LKA/.orch.lock"; printf 'rc=%s|%s\n' "$?" "$ORC_SINGLETON_WHY" ) > "$T/acq-raced" 2>&1
case "$(cat "$T/acq-raced")" in
  rc=1\|*333*) ck "§2 a reclaim that loses the create race makes the singleton HELD (rc 1), naming the winner" 0 ;;
  *)           ck "§2 a reclaim that lost the create race returned '$(cat "$T/acq-raced" | tr '\n' ' ')' — wanted rc 1 naming 333" 1 ;;
esac
case "$(cat "$T/acq-raced")" in
  *"could not be judged"*|*"could not be replaced"*)
    ck "§2 …and its refusal does NOT assert an unjudgeable record (the destructive-advice text)" 1 ;;
  *) ck "§2 …and its refusal does not assert an unjudgeable record" 0 ;;
esac

# ⛔ A NON-EEXIST `ln` FAILURE MUST NOT DESTROY THE ONLY COPY (fresh-context review of #3846, P2).
# `ln` does not fail only on EEXIST. Measured on this box with NO shims: EPERM (`fs.protected_hardlinks=1`
# with a record owned by another user — a sudo/service-installed controller) and ENOSPC (an
# inode-exhausted state dir) both fail with the destination FREE, while `mv`/`rename` in that same
# directory still succeeds. Collapsing every failure into "the path is taken" made this caller delete
# the record it had just moved aside — the only copy of another instance's record — after which the
# state dir reads FREE, the next starter's `orc_lock_write` succeeds and ACQUIRES, and two controllers
# share one state dir (#1715) — while the rc-2 text told the operator "nothing was removed".
# The `ln` shim below fails with the destination FREE, which is exactly that shape.
LKF="$T/lkf"; mkdir -p "$LKF"
printf '111\n' > "$LKF/.orch.lock"
( . "$MOD"
  orc_lock_pid() { case "${1:-}" in */.orch.lock.reclaim.*) printf '222\n' ;; *) command tr -dc '0-9' 2>/dev/null < "$1" ;; esac; }
  ln() { return 1; }
  orc_lock_reclaim "$LKF/.orch.lock" 111; printf 'rc=%s holder=%s\n' "$?" "$ORC_RECLAIM_HOLDER" ) > "$T/rcl-nolink" 2>&1
[ -f "$LKF/.orch.lock" ] \
  && ck "§2 a non-EEXIST ln failure still RESTORES the displaced record (the state dir cannot read FREE)" 0 \
  || ck "§2 a non-EEXIST ln failure DELETED the only copy of the displaced record — the state dir now reads FREE, so the next starter acquires over a live instance (#1715)" 1
[ "$(cat "$LKF/.orch.lock" 2>/dev/null)" = "222" ] \
  && ck "§2 …and what it restored names the pid the record was carrying (the one this caller did not judge)" 0 \
  || ck "§2 …and the restored record is '$(cat "$LKF/.orch.lock" 2>/dev/null)', wanted 222" 1
[ "$(cat "$T/rcl-nolink" | tr '\n' ' ')" = "rc=1 holder=222 " ] \
  && ck "§2 …and it is reported HELD naming that holder, not UNJUDGED" 0 \
  || ck "§2 …and the no-link reclaim returned '$(cat "$T/rcl-nolink" | tr '\n' ' ')' — wanted 'rc=1 holder=222 '" 1
case "$(ls "$LKF"/.orch.lock.reclaim.* 2>/dev/null)" in
  '') ck "§2 …and the fallback consumed the temp (no .reclaim file left beside the record)" 0 ;;
  *)  ck "§2 …and the fallback left a reclaim temp: $(ls "$LKF"/.orch.lock.reclaim.* 2>/dev/null | tr '\n' ' ')" 1 ;;
esac

# ⛔ A RECORD THAT CANNOT BE PUT BACK IS KEPT, NOT DELETED, AND THE REFUSAL NAMES IT (fresh-context
# review of #3846, cycle 2). An `O_EXCL` create can SUCCEED and the WRITE then fail — ENOSPC, EFBIG,
# `ulimit -f` — leaving a **0-byte record we created ourselves** (measured with `ulimit -f 0`:
# `create rc=153, file exists: YES size=0`). EXISTENCE cannot tell that from a third starter's record,
# and answering "taken" for it deleted the displaced record AND left a record every shipped reader
# treats as STOPPED — so the next starter reclaimed the empty record and ACQUIRED over a still-live
# displaced holder (#1715). CONTENT decides instead, and when there is no content to trust the fill
# answers "cannot tell" and the caller KEEPS the only copy. The `ln` shim below fails with the
# destination free and leaves a 0-byte record behind: exactly that state, deterministically.
LKZ="$T/lkz"; mkdir -p "$LKZ"
printf '111\n' > "$LKZ/.orch.lock"
( . "$MOD"
  orc_lock_pid() { case "${1:-}" in */.orch.lock.reclaim.*) printf '222\n' ;; *) command tr -dc '0-9' 2>/dev/null < "$1" ;; esac; }
  ln() { : > "$2"; return 1; }
  orc_lock_reclaim "$LKZ/.orch.lock" 111; printf 'rc=%s temp=%s\n' "$?" "${ORC_RECLAIM_TEMP:-none}" ) > "$T/rcl-keep" 2>&1
case "$(sed -n 1p "$T/rcl-keep")" in
  rc=2\ temp=*.orch.lock.reclaim.*) ck "§2 a record that cannot be put back is rc 2 and the KEPT copy is NAMED" 0 ;;
  *) ck "§2 an unrestorable record returned '$(cat "$T/rcl-keep" | tr '\n' ' ')' — wanted rc 2 with the kept copy named" 1 ;;
esac
[ "$(cat "$LKZ"/.orch.lock.reclaim.* 2>/dev/null)" = "111" ] \
  && ck "§2 …and the displaced record is still on disk beside the lock (NOT deleted)" 0 \
  || ck "§2 …and the displaced record was DELETED (found '$(cat "$LKZ"/.orch.lock.reclaim.* 2>/dev/null)', wanted 111) — a state dir that reads STOPPED over a live displaced holder (#1715)" 1

# …AND THE OPERATOR-FACING SENTENCE MUST SAY WHERE IT IS. rc 2 is two shapes now — an unreadable
# record, and a record that could not be put back — and the remedy is opposite (leave it vs move the
# kept copy back). `orch-loop.sh` branches on `ORC_RECLAIM_TEMP` and `harness-up`'s exit-74 row names
# both; this row pins the module half, which is what both read.
LKZ2="$T/lkz2"; mkdir -p "$LKZ2"
printf '999999\n' > "$LKZ2/.orch.lock"     # a DEAD holder, so the reclaim arm is reachable
( . "$MOD"
  orc_lock_pid() { case "${1:-}" in */.orch.lock.reclaim.*) printf '222\n' ;; *) command tr -dc '0-9' 2>/dev/null < "$1" ;; esac; }
  ln() { : > "$2"; return 1; }
  orc_singleton_acquire "$LKZ2/.orch.lock"; printf '%s|%s\n' "$?" "$ORC_SINGLETON_WHY" ) > "$T/acq-keep" 2>&1
case "$(cat "$T/acq-keep")" in
  2\|*"KEPT at "*.orch.lock.reclaim.*) ck "§2 the UNJUDGED refusal NAMES the kept copy (the operator can find it)" 0 ;;
  *) ck "§2 the UNJUDGED refusal does not name the kept copy — got '$(cat "$T/acq-keep" | tr '\n' ' ')'" 1 ;;
esac
case "$(cat "$T/acq-keep")" in
  *"nothing was removed"*) ck "§2 …and it does not claim 'nothing was removed' with no location (that is the orphaned-copy text)" 1 ;;
  *) ck "§2 …and it does not claim 'nothing was removed' with no location" 0 ;;
esac
# ─────────────────────────────────────────────────────────────────────────────────────────────────
hdr "§3 FAIL CLOSED — an unjudgeable record is a refusal, not a guess"
# The age is unreadable when `ps` cannot answer. `PS_BIN` is the seam the fleet's own suites use
# (#1856/#2402), so the box does not have to be broken for this arm to run.
cat > "$T/badps" <<'STUB'
#!/bin/sh
exit 1
STUB
chmod +x "$T/badps"
sleep 30 & APID=$!
printf '%s\n' "$APID" > "$LK/.orch.lock"
( . "$MOD"; PS_BIN="$T/badps" orc_singleton_acquire "$LK/.orch.lock"; printf '%s|%s\n' "$?" "$ORC_SINGLETON_WHY" ) > "$T/acq6"
case "$(cat "$T/acq6")" in
  2\|*CANNOT*) ck "§3 an UNREADABLE age refuses (rc 2, 'cannot be shown to be recycled') instead of guessing" 0 ;;
  *) ck "§3 an unreadable age did not fail closed — got '$(cat "$T/acq6")'" 1 ;;
esac
[ "$(cat "$LK/.orch.lock")" = "$APID" ] \
  && ck "§3 the unjudgeable record was NOT removed (an unreadable record is not a dead one)" 0 \
  || ck "§3 an unjudgeable record was DELETED" 1
kill -9 "$APID" 2>/dev/null; wait "$APID" 2>/dev/null

# ⛔ AND THE REAL LOOP MUST ACT ON IT. rc 2 has to become a NON-ZERO EXIT with the evidence on both
# surfaces; `exit 0` was the false PASS that let a second controller look healthy. This drives the
# shipped `orch-loop.sh` itself (not the module), because the mapping rc→exit is the loop's contract.
if need "$LOOP" "the shipped orch-loop.sh"; then
  R="$T/loop"; mkdir -p "$R/o/logs" "$R/repo" "$R/bin"
  git init -q "$R/repo" 2>/dev/null
  git -C "$R/repo" remote add origin https://github.com/daniel-ospina/agent-infra.git 2>/dev/null
  # The loop validates far more than the lock before it cycles; the case only has to reach the lock,
  # so the two files it refuses to run without are staged and the run is expected to STOP at the
  # singleton. A refusal here is the assertion; anything past it means the record was obeyed.
  cp "$HERE/repo-slug.sh" "$R/o/repo-slug.sh" 2>/dev/null
  cp "$HERE/controller-state.sh" "$R/o/controller-state.sh" 2>/dev/null
  printf '%s\n' "$$" > "$R/o/.orch.lock"
  out_rc=0
  ( O="$R/o" REPO="$R/repo" OR="daniel-ospina/agent-infra" bash "$LOOP" ) > "$T/loopout" 2>&1 || out_rc=$?
  # ⛔ Either outcome is informative, and BOTH are asserted: if the loop got as far as the lock it
  # must exit 75 and log `[singleton]`; if it stopped EARLIER on a missing seed, that is a different
  # refusal and this arm cannot judge the lock — so it says so instead of passing vacuously.
  if grep -q '\[singleton\]' "$R/o/logs/orch-loop.log" 2>/dev/null; then
    [ "$out_rc" = "75" ] \
      && ck "§3 the REAL orch-loop.sh refuses a held lock with EXIT 75 (was: exit 0, silently)" 0 \
      || ck "§3 the real loop logged [singleton] but exited $out_rc, not 75" 1
    grep -q '\[singleton\]' "$T/loopout" \
      && ck "§3 the refusal also reaches stderr (launchd.err), not only the log file" 0 \
      || ck "§3 the refusal did not reach stderr" 1
  else
    printf '      note: the loop refused before the lock (rc=%s): %s\n' "$out_rc" "$(head -2 "$T/loopout" | tr '\n' ' ')"
    ck "§3 the real-loop arm could not reach the lock — INCONCLUSIVE, counted as a failure" 1
  fi
  [ "$(cat "$R/o/.orch.lock" 2>/dev/null)" = "$$" ] \
    && ck "§3 the refused instance left the holder's record intact" 0 \
    || ck "§3 the refused instance MUTATED the holder's record" 1
fi

# ─────────────────────────────────────────────────────────────────────────────────────────────────
hdr "§4 release is OWNERSHIP-SCOPED"
printf '4242\n' > "$LK/.orch.lock"
( . "$MOD"; orc_singleton_release "$LK/.orch.lock" )
[ -f "$LK/.orch.lock" ] \
  && ck "§4 a record naming another pid SURVIVES this process's exit trap" 0 \
  || ck "§4 the exit trap deleted a record it did not own (a co-run window)" 1
( . "$MOD"; orc_singleton_acquire "$LK/.orch.lock" >/dev/null 2>&1
  orc_singleton_release "$LK/.orch.lock" )
[ -f "$LK/.orch.lock" ] \
  && ck "§4 the owner's own release removes its record" 1 \
  || ck "§4 the owner's own release removes its record" 0

# ─────────────────────────────────────────────────────────────────────────────────────────────────
hdr "§5 the identity mirror has not drifted from scripts/lib/pid-identity.sh"
LIB="$HERE/../lib/pid-identity.sh"
if need "$LIB" "the fleet's one process-identity rule (#1178)"; then
  # The rule is extracted from BOTH files and compared after normalising only the NAME line and the
  # comments. `controller-state.sh` ships in FLAT deployments that have no `lib/` sibling, so it
  # carries a mirror; the mirror is what drifts, and nothing else in CI would notice.
  norm() { sed -n "/^$2()/,/^}/p" "$1" | sed "1s/^$2()/FN()/" | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$'; }
  norm "$LIB" pid_start_epoch > "$T/lib_body"
  norm "$MOD" _orc_proc_start_epoch > "$T/mod_body"
  if [ ! -s "$T/lib_body" ] || [ ! -s "$T/mod_body" ]; then
    ck "§5 the drift comparison could not extract a body (the pin would be vacuous)" 1
  elif diff -q "$T/lib_body" "$T/mod_body" >/dev/null 2>&1; then
    ck "§5 the shipped start-epoch mirror is byte-identical to pid-identity.sh" 0
  else
    ck "§5 the start-epoch mirror DRIFTED from pid-identity.sh:" 1
    diff "$T/lib_body" "$T/mod_body" | head -10 | sed 's/^/      /'
  fi
  # The slack is what makes the recycled-pid test correct in BOTH files; a different number here would
  # let a genuine holder be reclaimed, or a recycled pid be obeyed.
  ls_="$(sed -n 's/^PID_START_SLACK_SECONDS="${PID_START_SLACK_SECONDS:-\([0-9]*\)}"/\1/p' "$LIB" | head -1)"
  ms_="$(sed -n 's/.*ORC_LOCK_START_SLACK_SECONDS:-\([0-9]*\).*/\1/p' "$MOD" | head -1)"
  [ -n "$ls_" ] && [ "$ls_" = "$ms_" ] \
    && ck "§5 the start-time slack matches pid-identity.sh ($ls_ s)" 0 \
    || ck "§5 the start-time slack drifted (lib='$ls_' module='$ms_')" 1
fi

# ─────────────────────────────────────────────────────────────────────────────────────────────────
hdr "§6 the provenance tokens a [cap] line needs"
# ⛔ DRIVEN FROM THE SHIPPED LINES, not from a model of them: the MAX_LOAD provenance block is
# extracted out of `orch-loop.sh` and run in a bare shell with a substituted core probe, exactly the
# way selftest.sh drives the lane derivation. A copy of the rule here would pass on a loop whose own
# block had been deleted (the vacuity this repo's suites keep having to remove).
if need "$LOOP" "the shipped orch-loop.sh"; then
  maxload_drv() { # <env MAX_LOAD or ''> <origin or ''> <core probe> -> '<MAX_LOAD>|<MAX_LOAD_SRC>'
    local e="$1" o="$2" p="$3"
    { echo 'set -uo pipefail'
      grep -F 'is_num() {' "$LOOP"; grep -F 'is_limit() {' "$LOOP"
      printf 'sysctl() { printf "%%s\\n" %s; }\n' "'$p'"
      sed -n '/^_NCPU=/,/^MAX_LANES=/p' "$LOOP"
      printf 'printf "%%s|%%s" "$MAX_LOAD" "$MAX_LOAD_SRC"'
    } > "$T/maxload-drive.sh"
    if [ -n "$e" ]; then env MAX_LOAD="$e" ORC_CONTROLLER_ORIGIN="$o" bash "$T/maxload-drive.sh" 2>&1
    else env -u MAX_LOAD ORC_CONTROLLER_ORIGIN="$o" bash "$T/maxload-drive.sh" 2>&1; fi
  }
  [ "$(maxload_drv "250" "" "10")" = "250|env" ] \
    && ck "§6 an env-supplied MAX_LOAD is labelled 'env'" 0 \
    || ck "§6 env MAX_LOAD label — got '$(maxload_drv "250" "" "10")'" 1
  [ "$(maxload_drv "250" "/Library/LaunchDaemons/x.plist" "10")" = "250|plist(/Library/LaunchDaemons/x.plist)" ] \
    && ck "§6 a plist-supplied MAX_LOAD names the plist it came from" 0 \
    || ck "§6 plist MAX_LOAD label — got '$(maxload_drv "250" "/Library/LaunchDaemons/x.plist" "10")'" 1
  [ "$(maxload_drv "" "" "10")" = "100|derived:cores" ] \
    && ck "§6 a DERIVED MAX_LOAD says so (this is the 100-vs-250 divergence, made visible)" 0 \
    || ck "§6 derived MAX_LOAD — got '$(maxload_drv "" "" "10")'" 1
  case "$(maxload_drv "0x" "" "10")" in
    "100|repair:"*) ck "§6 an unusable MAX_LOAD is REPAIRED and labelled as repaired (not 'env')" 0 ;;
    *) ck "§6 an unusable MAX_LOAD is mislabelled — got '$(maxload_drv "0x" "" "10")'" 1 ;;
  esac
fi
( . "$MOD"; ORC_STATE_RESOLVED="$T/x"; orc_instance_id "$T/x" "/tmp/orc-proof" ) > "$T/id"
case "$(cat "$T/id")" in
  "pid=$$@orc-proof#"*) ck "§6 the instance token names the PID and WHICH COPY it is (the incident's discriminator)" 0 ;;
  *) ck "§6 the instance token — got '$(cat "$T/id")'" 1 ;;
esac

# `[cap]` must actually carry them: a token nobody prints is not provenance.
if need "$LOOP" "the shipped orch-loop.sh"; then
  grep -q 'ctl=\${ORC_INSTANCE' "$LOOP" \
    && ck "§6 the [cap] line carries ctl= (which instance wrote it)" 0 \
    || ck "§6 the [cap] line does NOT carry ctl= — a divergence stays invisible" 1
  grep -q 'max_load_src=\${MAX_LOAD_SRC' "$LOOP" \
    && ck "§6 the [cap] line carries max_load_src= (which input set the ceiling)" 0 \
    || ck "§6 the [cap] line does NOT carry max_load_src=" 1
  grep -q 'state_src=\${ORC_STATE_SRC' "$LOOP" \
    && ck "§6 the [cap] line carries state_src= (which state dir is in force)" 0 \
    || ck "§6 the [cap] line does NOT carry state_src=" 1
fi

# ─────────────────────────────────────────────────────────────────────────────────────────────────
hdr "§7 the state dir and the HARNESS ROOT are two homes, and the module seam knows it"
# ⛔ WHICH MODULES A STATE-DIR INSTANCE CAN STILL LOAD (fresh-context review of #3846, P1). `orch-loop.sh`
# makes `$O` the state dir and exports it, so every module resolved `$O`-first needs a second home or the
# documented `ORC_STATE_DIR` arrangement silently loses it — for `claims.sh` that meant the snapshot never
# loaded, the sweep abstained, every PR read `claim-unreadable`, NOTHING was spawned, and `[cap]` kept
# printing a healthy line. This drives the SHIPPED resolution block with two real fixture dirs rather
# than grepping for it: state dir WITHOUT the module, loop dir WITH it.
if need "$LOOP" "the shipped orch-loop.sh"; then
  sed -n '/_claims_home=""/,/^  fi$/p' "$LOOP" > "$T/claimsres.sh"
  if [ ! -s "$T/claimsres.sh" ]; then
    ck "§7 the claims two-home resolution is extractable from the shipped loop" 1
  else
    SD="$T/sd"; LD="$T/ld"; mkdir -p "$SD" "$LD"; : > "$LD/claims.sh"
    out7="$(O="$SD" _HERE_RS="$LD" bash -c 'set -u; . "$1"; printf "%s" "${_claims_home:-none}"' _ "$T/claimsres.sh" 2>&1)"
    [ "$out7" = "$LD" ] \
      && ck "§7 with no claims.sh in the STATE dir, the loop resolves it from the harness root" 0 \
      || ck "§7 the claims registry was NOT resolved beside the loop — got '$out7' (this is the claim-unreadable-everything shape)" 1
    : > "$SD/claims.sh"
    out8="$(O="$SD" _HERE_RS="$LD" bash -c 'set -u; . "$1"; printf "%s" "${_claims_home:-none}"' _ "$T/claimsres.sh" 2>&1)"
    [ "$out8" = "$SD" ] \
      && ck "§7 a seeded STATE dir still WINS (production is not redirected by the fallback)" 0 \
      || ck "§7 a seeded state dir stopped winning — got '$out8'" 1
    rm -f "$SD/claims.sh"
    out9="$(O="$SD" _HERE_RS="" bash -c 'set -u; . "$1"; printf "%s" "${_claims_home:-none}"' _ "$T/claimsres.sh" 2>&1)"
    [ "$out9" = "none" ] \
      && ck "§7 neither home ⇒ no registry claimed (an absent one is not a found one)" 0 \
      || ck "§7 a missing registry was reported as found — got '$out9'" 1
  fi
  # ⛔ AND THE RESOLVED HARNESS ROOT IS EXPORTED, or the workers lose their own modules: they resolve
  # `claims.sh` / `repo-authority.sh` from `$O`, which is now the STATE dir.
  grep -q '^export O_WORK$' "$LOOP" \
    && ck "§7 the harness root is EXPORTED as O_WORK (workers resolve their modules from it)" 0 \
    || ck "§7 O_WORK is not exported — a worker on a state-dir instance loses claims and the merge contract" 1
  # ⛔ EVERY WORKER RESOLVES ITS **CODE** FROM THE WORK ROOT, NOT FROM `$O` (#3846 review, P1). `$O` is
  # the STATE dir, so a script path built from it cannot exist on the documented `ORC_STATE_DIR`
  # arrangement. Each file carries ONE `_X_WORK="${O_WORK:-$O}"` line, DRIVEN here rather than grepped
  # for by name — so a revert to `_X_WORK="$O"` reddens instead of still matching a variable name.
  for _w in chain-merge.sh dispatch-merge.sh stall-fix.sh refresh-candidates.sh nonblocking-dispatch.sh adopt-fix.sh report.sh; do
    _wkline="$(grep -m1 -E '^_[A-Z][A-Z_]*_WORK="\$\{O_WORK:-\$O\}"' "$HERE/$_w" 2>/dev/null)"
    if [ -z "$_wkline" ]; then
      ck "§7 $_w declares a work root (\${O_WORK:-\$O})" 1
      continue
    fi
    _wkvar="${_wkline%%=*}"
    outw="$(O=/state-dir O_WORK=/work-root bash -c 'set -u; eval "$1"; eval "printf %s \"\${$2}\""' _ "$_wkline" "$_wkvar" 2>&1)"
    [ "$outw" = "/work-root" ] \
      && ck "§7 $_w takes its work root from O_WORK when the controller exports it" 0 \
      || ck "§7 $_w resolved its work root as '$outw' — a script path built from \$O cannot exist on a state-dir instance" 1
    outw2="$(env -u O_WORK O=/state-dir bash -c 'set -u; eval "$1"; eval "printf %s \"\${$2}\""' _ "$_wkline" "$_wkvar" 2>&1)"
    [ "$outw2" = "/state-dir" ] \
      && ck "§7 $_w still uses \$O when O_WORK is unset (a hand-started worker is unchanged)" 0 \
      || ck "§7 $_w changed behaviour for a caller that never set O_WORK — got '$outw2'" 1
  done
  # ⛔ AND NO CODE PATH IS STILL BUILT FROM `$O`. The review named these five sites; each pair is
  # "the old resolution must be GONE" + "the work-root one must be THERE", so deleting the fix reddens
  # the first arm and a half-applied fix reddens the second.
  # ⛔ THE CHAIN SPAWN IS THE SIXTH, AND IT IS THE ONE A HALF-APPLIED FIX LEFT GREEN (fresh-context
  # review of #3846, P1): `dispatch-merge.sh` was converted at :35/:483/:520 and line :526 — three lines
  # below a converted sibling — still handed the CHAIN a state-dir path. That pane dies 127 while
  # `wt_spawn` answers 0 (worker-terminal.sh's pre-check runs `$envpfx`, not `$cmd`), so the dispatch
  # BOOKS `chain-<N>` as spawned, no review/record/merge ever runs, and the issue claim is held for its
  # 4h lease because `chain-merge.sh`'s EXIT trap never fires.
  # ⛔ THE LAST TWO LAUNCHERS WERE RECORDED AS FOLLOW-UP NOTES BY THE REVIEW, AND ARE PINNED IN THE
  # TABLE BELOW SO THEY CANNOT BE RE-DERIVED NEXT ROUND. Both are reached only on a split box, which is
  # why neither blocked — and both fail there in the wrong place: `adopt-fix.sh` 127'd the fixer into its
  # own log (an operator surface no fleet caller uses), and `report.sh` answered the worker census from
  # a module it could not find, which stays `UNKNOWN` rather than a confident 0. STATE paths are
  # deliberately NOT converted: `$O/logs`, `$O/state`, `$O/heartbeat` are the state dir on a split box.
  while IFS='|' read -r _f _bad _good; do
    [ -n "$_f" ] || continue
    if grep -qF -- "$_bad" "$HERE/$_f" 2>/dev/null; then
      ck "§7 $_f still resolves CODE from \$O ('$_bad') — that path cannot exist on a state-dir instance" 1
    elif grep -qF -- "$_good" "$HERE/$_f" 2>/dev/null; then
      ck "§7 $_f resolves that code from the work root ('$_good')" 0
    else
      ck "§7 $_f names NEITHER the old nor the work-root resolution — expected '$_good'" 1
    fi
  done <<'PAIRS'
fix-one.sh|bash "$O/merge-one.sh"|bash "${_FIX_MOD_DIR:-$O}/merge-one.sh"
chain-merge.sh|bash "$O/merge-one.sh"|bash "${_CM_WORK:-$O}/merge-one.sh"
dispatch-merge.sh|bash '$O/lane.sh'|bash '${_DM_WORK:-$O}/lane.sh'
dispatch-merge.sh|bash '$O/chain-merge.sh'|bash '${_DM_WORK:-$O}/chain-merge.sh'
stall-fix.sh|DISP="$O/nonblocking-dispatch.sh"|DISP="${_SF_WORK:-$O}/nonblocking-dispatch.sh"
adopt-fix.sh|bash "$O/fix-one.sh"|bash "${_AF_WORK:-$O}/fix-one.sh"
report.sh|"$O/worker-terminal.sh"|"$_RP_WORK/worker-terminal.sh"
merge-one.sh|if [ -n "${HEAD:-}" ] && [ -f "$O/claims.sh" ]; then|if [ -n "${HEAD:-}" ] && [ -f "$_M1_MOD/claims.sh" ]; then
PAIRS
  # ⛔ AND THE DISPATCH ARM MUST RESOLVE THE REGISTRY ITSELF, IN TWO HOMES. It tested `$O/claims.sh`
  # while the sweep sourced `$_claims_home`, so on a state-dir instance the registry was LOADED and the
  # guard said absent. It may also not simply READ `$_claims_home`: that is assigned 3000 lines above and
  # the arm is EXTRACTED and DRIVEN on its own (`refresh-scout.test.sh`), where the name is unbound —
  # measured as `claim-unreadable … nothing was batched` on every dispatch leg of that suite.
  grep -qF '_dch="${_claims_home-}"' "$LOOP" \
    && grep -qF 'elif [ -n "${_HERE_RS:-}" ] && [ -f "$_HERE_RS/claims.sh" ]; then _dch="$_HERE_RS"' "$LOOP" \
    && ck "§7 the DISPATCH arm resolves the claim registry itself, in the same two homes as the sweep" 0 \
    || ck "§7 the dispatch arm cannot resolve the registry on its own — a state-dir instance takes no issue claim, and an extracted driver reads it as absent" 1
  # ⛔ AND THE SPAWN GATE'S FORK FLOOR IS NOT SILENTLY OFF. Its resolver searched `$O` (now the STATE
  # dir) and "beside me" (no harness for the installed `pi` shim), so the work root has its own name.
  grep -q '"${O_WORK:-}"' "$HERE/spawn-gate.sh" \
    && ck "§7 spawn-gate searches the work root for capacity.sh (its fork floor is not silently off)" 0 \
    || ck "§7 spawn-gate does not search O_WORK — on a state-dir instance its fork floor is silently OFF" 1
fi

# ─────────────────────────────────────────────────────────────────────────────────────────────
hdr "§8 THE SLACK SEAM — validated before it reaches arithmetic (fresh review of #3846, P1)"
# ⛔ THE GUARD `main` CARRIED AND THIS MODULE LOST. `orch-loop.sh:2335-2351` on main validated
# `ORCH_LOCK_START_SLACK_SECONDS` before its arithmetic; the replacement name was added without it.
# Two distinct failures followed, and the FIRST is a fail-OPEN on the singleton — the exact class this
# file exists to prevent:
#   a NEGATIVE value makes `orc_began_after` answer 0 for a process that IS the current owner, so
#   `orc_singleton_acquire` returns 0 and the LIVE owner's record is displaced (two controllers on
#   one state dir, #1715, plus an unowned lock afterwards);
#   a NON-NUMERIC value aborts the and-or list `orc_singleton_acquire "$LOCKF"; RC=$?`, so `RC` is
#   never assigned and the caller dies on `case "$ORC_SINGLETON_RC"` under `set -u` with NO
#   `[singleton]` line and NO 74/75 (#1985's cryptic-stop class).
# The matrix is pinned FIRST, then the dangerous values are DRIVEN through the shipped acquire against
# a live holder — the matrix alone cannot prove the value reaches the arithmetic.
# ⛔ THE EXPECTED VALUES ARE main's DOCUMENTED BEHAVIOUR, not a restatement of the code: an all-digit
# value with leading zeros is NORMALISED (`08`->8, `007`->7) and KEPT, because both are inside the
# bound; only a NON-digit value or one wider than 60 falls to the documented 5.
# ⛔ `-1` AND `+1` ARE IN THE MATRIX BECAUSE THEY ISOLATE THE STAGE THE REST CANNOT REACH (fresh review of
# #3846, P2). The guard has three stages, in this order in `_orc_lock_slack`: the non-digit test, the
# octal strip, and the length/width bound — and every non-digit value above is >=3 characters, so the
# LENGTH bound would catch it if the non-digit test were not FIRST: deleting the
# non-digit stage (`case "$s" in ''|*[!0-9]*) s=5 ;; esac`) left this suite 68 passed, 0 failed, while
# `_orc_lock_slack -1` returned `-1` instead of 5 and `+1` returned `+1`. `-1` is TWO characters, so it
# passes the length bound and the octal strip leaves it alone — straight into `[ "$ps" -gt "$((pe + slack))" ]`
# with a NEGATIVE slack, i.e. the fail-OPEN reclaim this whole section exists to prevent. Two characters,
# signed, is the only shape that reaches the stage alone.
_lsv=""
for _lv in "" "-100" "1.5" "08" "007" "61" "100000" "abc" "-1" "+1"; do
  _lsv="$_lsv$(_orc_lock_slack "$_lv") "
done
[ "$_lsv" = "5 5 5 8 7 5 5 5 5 5 " ] \
  && ck "§8 every invalid slack falls to 5, and all-digit values are normalised not rejected" 0 \
  || ck "§8 the slack matrix drifted from main's documented behaviour — for ''/-100/1.5/08/007/61/100000/abc/-1/+1 got '$_lsv', wanted '5 5 5 8 7 5 5 5 5 5 '" 1
# ⛔ DRIVEN: a live process whose record was written AFTER it started (the normal HELD case) must be
# REFUSED for every one of these. Pre-fix, `-100` reclaimed it (rc 0, the owner's record replaced) and
# the three non-numeric ones died inside the arithmetic instead of returning a verdict. `-1` is driven
# as well as matrixed: it is the shortest signed value that reaches the arithmetic, so it is the one
# that proves the NON-DIGIT stage alone still refuses a live holder.
SLK="$T/slk"; mkdir -p "$SLK"
sleep 30 & SLH=$!
for _bad in -100 -1 1.5 abc 08; do
  printf '%s\n' "$SLH" > "$SLK/.orch.lock"
  ( export ORC_LOCK_START_SLACK_SECONDS="$_bad"
    . "$MOD"
    orc_singleton_acquire "$SLK/.orch.lock"; rc=$?
    printf '%s|%s|%s\n' "$rc" "$(cat "$SLK/.orch.lock")" "$ORC_SINGLETON_WHY" ) > "$T/slk-$_bad" 2>&1
  case "$(cat "$T/slk-$_bad")" in
    1\|"$SLH"\|*) ck "§8 slack '$_bad' still REFUSES the live owner (rc 1, the holder's record intact)" 0 ;;
    *) ck "§8 slack '$_bad' did NOT refuse the live owner — got '$(cat "$T/slk-$_bad")' (a fail-OPEN reclaims a live controller's lock; a cryptic death skips the refusal entirely)" 1 ;;
  esac
done
# ⛔ AND THE SAME SEAM ASSIGNED **AFTER** THE MODULE IS LOADED. That is the measurement path a reviewer
# takes to check this fix, so it is closed explicitly: `orc_began_after` re-validates at the point of
# use rather than trusting the load-time value.
printf '%s\n' "$SLH" > "$SLK/.orch.lock"
( . "$MOD"
  ORC_LOCK_START_SLACK_SECONDS=-100
  orc_singleton_acquire "$SLK/.orch.lock"; rc=$?
  printf '%s|%s\n' "$rc" "$(cat "$SLK/.orch.lock")" ) > "$T/slk-post" 2>&1
case "$(cat "$T/slk-post")" in
  1\|"$SLH"*) ck "§8 a slack assigned AFTER load cannot reach the arithmetic either (no fail-OPEN on a later caller)" 0 ;;
  *) ck "§8 a slack assigned after load still reached the reclaim decision — got '$(cat "$T/slk-post")'" 1 ;;
esac
kill -TERM "$SLH" 2>/dev/null; wait "$SLH" 2>/dev/null

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
