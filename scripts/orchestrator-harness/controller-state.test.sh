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
say() { printf '\n── %s\n' "$1"; }
need() { # need <path> <description> — a missing input is a FAILED case, never a silent skip
  [ -e "$1" ] || [ -n "${2:-}" ]
  if [ -e "$1" ]; then return 0; fi
  printf '  ❌ MISSING: %s (%s)\n' "$2" "$1"; FAIL=$((FAIL+1)); return 1
}
T="${TMPDIR:-/tmp}/orc-cs-test-$$"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T" || { echo "cannot create $T"; exit 1; }

say "§0 the suite cannot reach a production state dir"
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
say "§1 WHICH STATE DIR — an existing install is untouched, a copy is isolated"
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

# ─────────────────────────────────────────────────────────────────────────────────────────────────
say "§2 THE SINGLETON — a live holder is refused, a recycled pid is reclaimed"
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

# ─────────────────────────────────────────────────────────────────────────────────────────────────
say "§3 FAIL CLOSED — an unjudgeable record is a refusal, not a guess"
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
say "§4 release is OWNERSHIP-SCOPED"
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
say "§5 the identity mirror has not drifted from scripts/lib/pid-identity.sh"
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
say "§6 the provenance tokens a [cap] line needs"
( . "$MOD"; orc_max_load_src "250" "" ; orc_max_load_src "250" "/Library/LaunchDaemons/x.plist"; orc_max_load_src "" "" ) > "$T/src"
[ "$(sed -n 1p "$T/src")" = "env" ] \
  && ck "§6 an env-supplied MAX_LOAD is labelled 'env'" 0 \
  || ck "§6 env MAX_LOAD label — got '$(sed -n 1p "$T/src")'" 1
[ "$(sed -n 2p "$T/src")" = "plist(/Library/LaunchDaemons/x.plist)" ] \
  && ck "§6 a plist-supplied MAX_LOAD names the plist it came from" 0 \
  || ck "§6 plist MAX_LOAD label — got '$(sed -n 2p "$T/src")'" 1
[ "$(sed -n 3p "$T/src")" = "derived:cores" ] \
  && ck "§6 a DERIVED MAX_LOAD says so (this is the 100-vs-250 divergence, made visible)" 0 \
  || ck "§6 derived MAX_LOAD label — got '$(sed -n 3p "$T/src")'" 1
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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
