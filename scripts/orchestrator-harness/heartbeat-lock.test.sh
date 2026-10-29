#!/usr/bin/env bash
# heartbeat-lock.test.sh — the single-instance guard in `scripts/orchestrator-heartbeat.sh` (#2890).
#
# ⛔ WHAT THIS SUITE IS FOR. The heartbeat had NO single-instance guard, so instances accumulated on one
# `$STATE` and ran the same pass concurrently (measured 2026-10-27: `ps` showed two live processes, and
# two again within three minutes of a kill + `kickstart`). The guard is a lock with a stale-takeover
# rule, and the risk of adding one is NOT "it does not work" — it is #1985: a lock that reclaims on
# liveness alone, or that never lets a new instance start, stops the box silently AND blocks its own
# recovery. So every case below is either a rule the guard must hold, or a way it could wedge/misfire:
#
#   0. the guard sits ABOVE every `$STATE` write (that is what makes "a refusal touches nothing" true)
#   1. two starts against ONE temp `$STATE` → the second REFUSES, names the holder, mutates nothing
#   2. a LIVE holder is never taken over (and the refusing tick leaves the lock naming it)
#   3. a DEAD holder is reclaimed
#   4. a RECYCLED pid is NOT read as live (the #1985 case — liveness is not identity)
#   5. a live-but-ANCIENT lock is reclaimed (a wedged holder may cost one pass, never the box)
#   6. an UNWRITABLE `$STATE` permits the pass, and says so loudly (the explicit decision)
#   7. `--dry-run` still answers while a pass is live, and reclaims nothing
#
# ⛔ NO NETWORK, NO MODEL, NO FLEET. Each case gets its own `$HOME` fixture: a `$STATE`, an empty lane
# registry, and a stub `scripts/ask-owner.py` that records that the pass REACHED it (proof the pass ran)
# and then sleeps, which is what keeps a first instance holding the lock while the second starts. The
# subject is the real script, driven through its real entry point (`bash <script>`), never a
# re-implementation of the guard.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBJECT="$HERE/../orchestrator-heartbeat.sh"
PASS=0; FAIL=0; SKIP=0
ck() { # ck <name> <0|1>
  if [ "$2" -eq 0 ]; then printf '  ✅ %s\n' "$1"; PASS=$((PASS+1));
  else printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); fi
}
skip() { printf '  ⏭ %s\n' "$1"; SKIP=$((SKIP+1)); }
want() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }   # substring membership (no nesting in $( ))

TMP="$(mktemp -d)" || exit 1
KIDS=""
cleanup() {
  for p in $KIDS; do kill -9 "$p" 2>/dev/null; done
  chmod -R u+rwX "$TMP" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "==> heartbeat single-instance guard self-test ($HERE)"

# ── 0) the subject exists, parses, and the guard sits ABOVE every `$STATE` write ──────────────────
[ -s "$SUBJECT" ]; ck "orchestrator-heartbeat.sh exists and is non-empty" $?
# ⛔ SPELLED AS A LITERAL SCRIPT NAME AFTER A `cd`, NOT `bash -n "$SUBJECT"`. Measured: with the
# variable form, the main-worktree-guard (`main-worktree-guard`, #709) cannot statically resolve the
# script this suite would run, so it refuses to run THE SUITE ITSELF (script-indirection) — an
# unrunnable suite protects nothing. The literal form passes the same check and is resolvable.
( cd "$HERE/.." && bash -n orchestrator-heartbeat.sh ); ck "orchestrator-heartbeat.sh parses under bash" $?
GUARD_LINE="$(grep -n 'SINGLE-INSTANCE GUARD — ONE HEARTBEAT PER' "$SUBJECT" | head -1 | cut -d: -f1)"
BOUNDED_LOG_LINE="$(grep -n '^# -- bounded log' "$SUBJECT" | head -1 | cut -d: -f1)"
[ -n "$GUARD_LINE" ] && [ -n "$BOUNDED_LOG_LINE" ] && [ "$GUARD_LINE" -lt "$BOUNDED_LOG_LINE" ]
ck "the guard is defined ABOVE the log truncation (a refusal must precede every \$STATE write)" $?
grep -q "trap 'hb_release' EXIT" "$SUBJECT"; ck "the lock is released from the EXIT trap (one release point)" $?
# ⛔ THE REFUSAL PATH MUST NOT STAGE. `mkdir $STATE/.heartbeat.lock.$$` is a WRITE under $STATE, so
# the held-lock check has to come FIRST inside hb_claim; otherwise every refused tick (and every settle
# attempt of one) touches the state dir it claims not to touch. Review found this with strace.
# (Two fixed-string anchors, each unique in the file, compared by LINE NUMBER: the held-lock return and
# the staging mkdir. Fixed-string greps, not patterns — a bracket/brace pattern here is what made the
# main-worktree-guard refuse to run this suite at all, so the anchors stay literal.)
EXISTS_AT="$(grep -nF 'then return 2; fi' "$SUBJECT" | head -1 | cut -d: -f1)"
STAGE_AT="$(grep -nF 'mkdir "$stage"' "$SUBJECT" | head -1 | cut -d: -f1)"
[ -n "$EXISTS_AT" ] && [ -n "$STAGE_AT" ] && [ "$EXISTS_AT" -lt "$STAGE_AT" ]
ck "hb_claim detects a HELD lock BEFORE staging anything (a refusal writes nothing under \$STATE)" $?

# ── the fixture ──────────────────────────────────────────────────────────────────────────────────
# mkhome <dir> — a $HOME the subject can run in. `ask-owner.py` is the pass's first expensive step and
# the KEEPALIVE: it appends to $HOME/mark (proof the pass RAN) and then sleeps HB_TEST_SLEEP seconds,
# which is what lets a second start be timed against a first that is genuinely mid-pass.
mkhome() {
  local h="$1"
  rm -rf "$h"; mkdir -p "$h/.pi/agent/state" "$h/.pi/agent/sessions" "$h/.pi/agent/scripts" || return 1
  : > "$h/.pi/agent/state/lane-registry.tsv"
  cat > "$h/.pi/agent/scripts/ask-owner.py" <<'PY'
import os, time
m = os.environ.get("HB_TEST_MARK")
if m:
    with open(m, "a") as fh:
        fh.write("ask\n")
time.sleep(float(os.environ.get("HB_TEST_SLEEP", "0")))
PY
}
# run_hb <home> <sleep> <lock-wait-s> <lock-stale-min> [subject args…] — the REAL entry point, in that
# home. Every knob is passed explicitly rather than by a `VAR=x func` prefix (bash's environment for a
# prefix-assigned FUNCTION call is not something this suite should be betting an assertion on).
run_hb() {
  local h="$1" slp="$2" wait_s="$3" stale="$4"; shift 4
  HOME="$h" HB_TEST_MARK="$h/mark" HB_TEST_SLEEP="$slp" \
    HB_LOCK_WAIT_S="$wait_s" HB_LOCK_STALE_MIN="$stale" \
    bash "$SUBJECT" "$@" 2>&1
}
ran() { [ -s "$1/mark" ]; }                       # the pass reached ask-owner => the guard permitted it
runs() { local c; c="$(grep -c ask "$1/mark" 2>/dev/null)"; printf '%s' "${c:-0}"; }   # passes that reached it
state_snapshot() {  # files AND directories: a files-only walk cannot see a staging dir
  ( cd "$1" && find . -print | LC_ALL=C sort |
      while IFS= read -r f; do
        if [ -f "$f" ]; then printf '%s ' "$f"; cksum < "$f"; else printf '%s dir\n' "$f"; fi
      done ) }
mk_lock() { # mk_lock <state> <pid> <start-string>
  mkdir -p "$1/heartbeat.lock" || return 1
  printf '%s\n' "$2" > "$1/heartbeat.lock/pid"
  printf '%s\n' "$3" > "$1/heartbeat.lock/start"
}
ident() { LC_ALL=C ps -p "$1" -o lstart= 2>/dev/null | sed -e 's/^ *//' -e 's/ *$//'; }
lock_pid() { cat "$1/heartbeat.lock/pid" 2>/dev/null | tr -d '[:space:]'; }
# ⛔ A HELPER THAT BACKGROUNDS A CHILD MUST NOT BE CALLED IN `$( )`. Measured while writing this suite:
# `P="$(live_child)"` hung for the full 60 s of the child — the orphan inherits the command
# substitution's stdout PIPE, so the substitution does not see EOF until that child exits. It sets
# LIVE_PID in the CALLER's shell instead, and the child is forked from a short-lived subshell so it is
# not this suite's JOB: a job of this shell gets a `Killed` line printed when case cleanup reaps it,
# which reads like a failure in a CI log. (The pid still survives — it is reparented, not killed.)
live_child() {  # sets LIVE_PID (and tracks it for cleanup); never called in $( )
  local f="$TMP/livepid.$RANDOM"
  ( sleep 60 & printf '%s' "$!" > "$f" )
  LIVE_PID="$(cat "$f" 2>/dev/null)"; rm -f "$f"
  KIDS="$KIDS $LIVE_PID"
}

# ── 1) TWO INSTANCES, ONE $STATE: the second REFUSES, names the holder, touches nothing ───────────
echo "-- 1) two starts against one \$STATE"
H1="$TMP/one"; mkhome "$H1"
ST1="$H1/.pi/agent/state"
( run_hb "$H1" 6 10 30 > "$TMP/a1.out" 2>&1 ) &
A_JOB=$!; KIDS="$KIDS $A_JOB"
n=0; while [ "$n" -lt 40 ]; do ran "$H1" && [ -d "$ST1/heartbeat.lock" ] && break; sleep 0.25; n=$((n+1)); done
ck "the FIRST instance took \$STATE/heartbeat.lock while it runs" \
   "$( [ -d "$ST1/heartbeat.lock" ] && echo 0 || echo 1 )"
HELD="$(lock_pid "$ST1")"
ck "the lock names the pid of a RUNNING heartbeat ($HELD)" \
   "$( [ -n "$HELD" ] && ps -p "$HELD" -o command= 2>/dev/null | grep -q 'orchestrator-heartbeat\.sh' && echo 0 || echo 1 )"
ck "the lock records the holder's START TIME, not just its pid (identity, #1985)" \
   "$( [ "$(cat "$ST1/heartbeat.lock/start" 2>/dev/null | tr -d '[:space:]')" = "$(ident "$HELD" | tr -d '[:space:]')" ] && echo 0 || echo 1 )"
ck "the first instance is mid-pass (it reached ask-owner exactly once)" \
   "$( [ "$(runs "$H1")" -eq 1 ] && echo 0 || echo 1 )"

: > "$TMP/stamp.before"
sleep 1                                     # outrun a 1-second-granularity mtime, if the fs has one
BEFORE="$(state_snapshot "$ST1")"
OUT1="$(run_hb "$H1" 0 0 30)"; RC1=$?
AFTER="$(state_snapshot "$ST1")"
ck "the SECOND instance refuses (rc=$RC1)" \
   "$( [ "$RC1" -eq 0 ] && want "$OUT1" "another instance is live" && echo 0 || echo 1 )"
ck "the refusal NAMES the holding pid ($HELD)" "$( want "$OUT1" "pid $HELD" && echo 0 || echo 1 )"
ck "the second instance ran NO pass of its own (still exactly one)" \
   "$( [ "$(runs "$H1")" -eq 1 ] && echo 0 || echo 1 )"
ck "the second instance left \$STATE IDENTICAL (file+directory set, before/after)" \
   "$( [ "$BEFORE" = "$AFTER" ] && echo 0 || echo 1 )"
ck "the refused tick left no staging debris (no .heartbeat.lock.<pid> under \$STATE)" \
   "$( [ -z "$(find "$ST1" -maxdepth 1 -name '.heartbeat.lock.*' -print 2>/dev/null)" ] && echo 0 || echo 1 )"
ck "the lock still names the LIVE holder after the refusal (it was not reclaimed)" \
   "$( [ "$(lock_pid "$ST1")" = "$HELD" ] && echo 0 || echo 1 )"
ck "the refused tick did not even bump \$STATE's own mtime (mkdir+rmdir would)" \
   "$( [ -z "$(find "$ST1" -maxdepth 0 -newer "$TMP/stamp.before" 2>/dev/null)" ] && echo 0 || echo 1 )"
wait "$A_JOB" 2>/dev/null
ck "the lock is RELEASED when the pass exits (EXIT trap)" \
   "$( [ ! -e "$ST1/heartbeat.lock" ] && echo 0 || echo 1 )"

# ── 2) a LIVE holder (any process with the recorded identity) is NOT taken over ───────────────────
echo "-- 2) a live holder is not taken over"
H2="$TMP/two"; mkhome "$H2"; ST2="$H2/.pi/agent/state"
live_child; HOLD="$LIVE_PID"; mk_lock "$ST2" "$HOLD" "$(ident "$HOLD")"
OUT2="$(run_hb "$H2" 0 0 30)"; RC2=$?
ck "a live, identity-matching holder is refused, not replaced (rc=$RC2)" \
   "$( want "$OUT2" "another instance is live (pid $HOLD" && echo 0 || echo 1 )"
ck "the refused tick ran no pass" "$( ran "$H2" && echo 1 || echo 0 )"
ck "the live holder's lock is untouched" "$( [ "$(lock_pid "$ST2")" = "$HOLD" ] && echo 0 || echo 1 )"
kill -9 "$HOLD" 2>/dev/null

# ── 3) a DEAD holder is reclaimed (the ordinary crash path) ───────────────────────────────────────
echo "-- 3) a dead holder is reclaimed"
H3="$TMP/three"; mkhome "$H3"; ST3="$H3/.pi/agent/state"
DEAD=""
for _try in 1 2 3 4 5 6 7 8 9 10; do
  sh -c 'exit 0' & _p=$!; wait "$_p" 2>/dev/null
  [ -z "$(ident "$_p")" ] && { DEAD="$_p"; break; }
done
ck "the fixture produced a genuinely DEAD pid ($DEAD)" "$( [ -n "$DEAD" ] && echo 0 || echo 1 )"
mk_lock "$ST3" "$DEAD" "Mon Jan  1 00:00:00 2024"
OUT3="$(run_hb "$H3" 0 0 30)"; RC3=$?
ck "a lock naming a DEAD pid is reclaimed and the pass runs (rc=$RC3)" \
   "$( want "$OUT3" "reclaimed a stale lock (pid $DEAD, reason: dead)" && ran "$H3" && echo 0 || echo 1 )"
ck "the reclaimed lock is gone once the pass exits" \
   "$( [ ! -e "$ST3/heartbeat.lock" ] && echo 0 || echo 1 )"

# ── 4) a RECYCLED pid is NOT read as live — the #1985 case ────────────────────────────────────────
# `kill -0` says alive; the recorded START TIME is a previous process's, so this pid is NOT the holder.
# Liveness is not identity: reclaiming here is what keeps a SIGKILLed pass from blocking its own restart.
echo "-- 4) a recycled pid is not \"live\" (#1985)"
H4="$TMP/four"; mkhome "$H4"; ST4="$H4/.pi/agent/state"
RECY=""; live_child; RECY="$LIVE_PID"; mk_lock "$ST4" "$RECY" "Mon Jan  1 00:00:00 2024"
ck "the fixture really is a LIVE pid with a foreign start time" \
   "$( [ -n "$(ident "$RECY")" ] && [ "$(ident "$RECY")" != "Mon Jan  1 00:00:00 2024" ] && echo 0 || echo 1 )"
OUT4="$(run_hb "$H4" 0 0 30)"; RC4=$?
ck "a RECYCLED pid does not read as live — the lock is reclaimed (rc=$RC4)" \
   "$( want "$OUT4" "reclaimed a stale lock (pid $RECY, reason: recycled)" && ran "$H4" && echo 0 || echo 1 )"
ck "a recycled holder does NOT wedge its own restart (the pass ran)" "$( ran "$H4" && echo 0 || echo 1 )"
kill -9 "$RECY" 2>/dev/null

# ── 5) a live-but-ANCIENT lock is reclaimed: a wedged holder costs one pass, never the box ────────
echo "-- 5) an aged lock is reclaimed even though its pid looks live"
H5="$TMP/five"; mkhome "$H5"; ST5="$H5/.pi/agent/state"
OLD=""; live_child; OLD="$LIVE_PID"; mk_lock "$ST5" "$OLD" "$(ident "$OLD")"
touch -t 200001010000 "$ST5/heartbeat.lock" 2>/dev/null
OUT5="$(run_hb "$H5" 0 0 1)"; RC5=$?
ck "an ancient lock is reclaimed as aged — a wedged holder cannot block the box (rc=$RC5)" \
   "$( want "$OUT5" "reclaimed a stale lock (pid $OLD, reason: aged)" && ran "$H5" && echo 0 || echo 1 )"
kill -9 "$OLD" 2>/dev/null

# ── 6) an UNWRITABLE $STATE PERMITS the pass, and says so ─────────────────────────────────────────
# The explicit decision: the guard's job is to serialize a shared $STATE; a state dir that cannot hold
# the lock is already broken, and refusing there would take the box's only alarm offline exactly when
# the box is in trouble — and could not even log the reason, because the log lives in that same dir.
echo "-- 6) an unwritable \$STATE permits (fail-open BY DECISION, loudly)"
if [ "$(id -u)" = "0" ]; then
  skip "unwritable-\$STATE case not runnable as root (chmod does not bind) — this arm is NOT covered by this run"
else
  H6="$TMP/six"; mkhome "$H6"; ST6="$H6/.pi/agent/state"
  chmod 500 "$ST6"
  OUT6="$(run_hb "$H6" 0 0 30)"; RC6=$?
  chmod 700 "$ST6" 2>/dev/null
  ck "an unwritable \$STATE runs the pass UNGUARDED and says so on stdout (rc=$RC6)" \
     "$( want "$OUT6" "cannot be written" && want "$OUT6" "running WITHOUT it" && ran "$H6" && echo 0 || echo 1 )"
  ck "no lock is left behind by the unguarded run" \
     "$( [ ! -e "$ST6/heartbeat.lock" ] && echo 0 || echo 1 )"
fi

# ── 7) `--dry-run` still answers while a pass is live, and reclaims nothing ───────────────────────
echo "-- 7) --dry-run answers beside a live pass"
H7="$TMP/seven"; mkhome "$H7"; ST7="$H7/.pi/agent/state"
DRYHOLD=""; live_child; DRYHOLD="$LIVE_PID"; mk_lock "$ST7" "$DRYHOLD" "$(ident "$DRYHOLD")"
OUT7="$(run_hb "$H7" 0 0 30 --dry-run)"; RC7=$?
ck "a dry run does NOT refuse on a live box (rc=$RC7)" \
   "$( if [ "$RC7" -eq 0 ] && ! want "$OUT7" "another instance is live"; then echo 0; else echo 1; fi )"
ck "a dry run reports, and says it is running without the lock" \
   "$( want "$OUT7" "DRY-RUN" && want "$OUT7" "must not reclaim" && echo 0 || echo 1 )"
ck "a dry run does NOT reclaim the live holder's lock" \
   "$( [ "$(lock_pid "$ST7")" = "$DRYHOLD" ] && echo 0 || echo 1 )"
kill -9 "$DRYHOLD" 2>/dev/null

# ── 8) an EXITING tick must not delete a SUCCESSOR's lock (ownership-checked release) ───────
# The #1761 shape: a release that deletes whatever lock is there turns "A finished" into "B lost its
# lock", and a third start then runs beside B. The lock is replaced under the running tick here (what a
# stale takeover does) and the tick's own exit must leave the replacement alone.
echo "-- 8) an exiting tick does not delete a successor's lock"
H8="$TMP/eight"; mkhome "$H8"; ST8="$H8/.pi/agent/state"
( run_hb "$H8" 6 10 30 > "$TMP/a8.out" 2>&1 ) &
A8="$!"; KIDS="$KIDS $A8"
n=0; while [ "$n" -lt 40 ]; do ran "$H8" && [ -d "$ST8/heartbeat.lock" ] && break; sleep 0.25; n=$((n+1)); done
rm -rf "$ST8/heartbeat.lock"
live_child; SUCC="$LIVE_PID"; mk_lock "$ST8" "$SUCC" "$(ident "$SUCC")"
wait "$A8" 2>/dev/null
ck "the exiting tick left the SUCCESSOR's lock in place (release is ownership-checked)" \
   "$( [ "$(lock_pid "$ST8")" = "$SUCC" ] && echo 0 || echo 1 )"
kill -9 "$SUCC" 2>/dev/null

# ── 9) numeric knobs: a zero-padded bound falls back, and `0` is NOT silently replaced ─────
# ⛔ THIS CASE DRIVES `HB_LOCK_WAIT_S`, NOT `HB_LOCK_STALE_MIN`, AND THAT IS THE POINT. The octal abort
# lives in `hb_max_attempt=$((HB_LOCK_WAIT_S + 8))`; `HB_LOCK_STALE_MIN` never reaches `$(( ))` (it only
# feeds `find -mmin`), so a case that fed `08` to it passed with BOTH validation lines deleted — an
# inert case reported as a green (measured in review). `08` here must fall back to the documented
# default settle, and `0` must stay 0 (a refusal is then immediate, not 10 s later).
echo "-- 9) a zero-padded bound falls back; 0 is honoured, not replaced"
H9="$TMP/nine"; mkhome "$H9"; ST9="$H9/.pi/agent/state"
live_child; PAD="$LIVE_PID"; mk_lock "$ST9" "$PAD" "$(ident "$PAD")"   # LIVE identity: the age arm must be what fires
touch -t 200001010000 "$ST9/heartbeat.lock" 2>/dev/null
OUT9="$(run_hb "$H9" 0 08 30)"; RC9=$?
ck "HB_LOCK_WAIT_S=08 does not abort the arithmetic — the aged lock is still reclaimed (rc=$RC9)" \
   "$( [ "$RC9" -eq 0 ] && want "$OUT9" "reason: aged" && ran "$H9" \
        && ! want "$OUT9" "value too great" && ! want "$OUT9" "unbound variable" && echo 0 || echo 1 )"
kill -9 "$PAD" 2>/dev/null
# and `0` must NOT be read as "missing": with a live holder and a zero settle the refusal is immediate.
H9B="$TMP/nine-b"; mkhome "$H9B"; ST9B="$H9B/.pi/agent/state"
live_child; HW="$LIVE_PID"; mk_lock "$ST9B" "$HW" "$(ident "$HW")"
T0="$(date +%s)"
OUT9B="$(run_hb "$H9B" 0 0 30)"; RC9B=$?
T1="$(date +%s)"
ck "HB_LOCK_WAIT_S=0 is HONOURED — the refusal is immediate, not a 10 s settle (rc=$RC9B, $((T1-T0))s)" \
   "$( [ "$RC9B" -eq 0 ] && want "$OUT9B" "another instance is live" && [ "$((T1-T0))" -le 3 ] && echo 0 || echo 1 )"
kill -9 "$HW" 2>/dev/null

# ── 10) `HB_LOCK_STALE_MIN=0` is not a setting: it must fall back, or a live pass becomes joinable ─
# `find -mmin +0` means "older than a minute", so an explicit 0 would let a second instance join a pass
# that had merely run for 60 s — the #2890 defect, re-created by a misconfiguration. Same shape as
# watchdog-loop.sh's MAX_CONSEC: below 1 falls back to the documented default, so a YOUNG live lock is
# still respected.
echo "-- 10) HB_LOCK_STALE_MIN=0 falls back (a live lock is not aged by a zero bound)"
H10="$TMP/ten"; mkhome "$H10"; ST10="$H10/.pi/agent/state"
live_child; YOUNG="$LIVE_PID"; mk_lock "$ST10" "$YOUNG" "$(ident "$YOUNG")"
OUT10="$(run_hb "$H10" 0 0 0)"; RC10=$?
ck "a zero age bound falls back to the default: the young live lock is still respected (rc=$RC10)" \
   "$( [ "$RC10" -eq 0 ] && want "$OUT10" "another instance is live" && ! ran "$H10" && echo 0 || echo 1 )"
kill -9 "$YOUNG" 2>/dev/null

# ── 11) a zero-padded AGE bound falls back too (a live 10-minute-old lock is not aged at 30) ─
# The sibling of case 9 for the other knob: `08` must fall back to the documented 30, so a lock that is
# merely 10 minutes old is STILL respected. Without that validation line `08` survives as a literal
# 8-minute bound and this lock would be reclaimed — which is how a typed `08` would quietly shorten the
# anti-wedge window this guard documents. (A lock AGE between the two bounds is what makes the case
# discriminate: an ancient one is reclaimed either way.)
echo "-- 11) a zero-padded age bound falls back (a 10-minute-old live lock is still respected)"
H11="$TMP/eleven"; mkhome "$H11"; ST11="$H11/.pi/agent/state"
ten_min_ago() { date -v-10M +%Y%m%d%H%M 2>/dev/null || date -d '-10 min' +%Y%m%d%H%M 2>/dev/null; }
TEN="$(ten_min_ago)"
live_child; MID="$LIVE_PID"; mk_lock "$ST11" "$MID" "$(ident "$MID")"
[ -n "$TEN" ] && touch -t "$TEN" "$ST11/heartbeat.lock" 2>/dev/null
OUT11="$(run_hb "$H11" 0 0 08)"; RC11=$?
ck "HB_LOCK_STALE_MIN=08 falls back to 30: a 10-minute-old live lock is NOT reclaimed (rc=$RC11)" \
   "$( [ "$RC11" -eq 0 ] && want "$OUT11" "another instance is live" && ! ran "$H11" && echo 0 || echo 1 )"
kill -9 "$MID" 2>/dev/null

echo
printf 'heartbeat-lock: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
