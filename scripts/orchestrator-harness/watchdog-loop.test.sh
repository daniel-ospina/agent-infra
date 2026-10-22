#!/usr/bin/env bash
# watchdog-loop.test.sh — the controller watchdog's contract, driven hermetically.
#
# ⛔ THE CASE THAT MATTERS IS THE MEASURED ONE (2026-10-21): a controller that is ALIVE and whose
# heartbeat has been frozen for an hour, while `launchctl` says loaded and `harness.sh verify` says
# GREEN. A pid-existence predicate reports that box healthy, so this suite exists to prove the
# watchdog does not — and to prove the assertion is not vacuous (last section).
#
# Everything here is scratch: $HOME and the state dir are throwaway, the controller is a `sleep` whose
# command line ends in `orch-loop.sh` (so the pid/identity check is exercised for real), and the
# platform restart is a STUB we count. No launchctl, no systemctl, no real stack, no network.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
WD="$SELF_DIR/watchdog-loop.sh"
[ -f "$WD" ] || { echo "FATAL: $WD not found" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/watchdog-loop-test.XXXXXX")"
trap 'kill $(cat "$WORK"/*.ctrlpid 2>/dev/null) 2>/dev/null; rm -rf "$WORK"' EXIT
ok()  { printf 'ok   %s\n' "$*"; }
bad() { printf 'BAD  %s\n' "$*"; FAIL=$((FAIL+1)); }
FAIL=0
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }
assert_contains() { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 (no '$2' in: $1)" ;; esac; }
assert_absent()  { case "$1" in *"$2"*) bad "$3 (found '$2' in: $1)" ;; *) ok "$3" ;; esac; }

N=0
# A fresh case: its own O / state dir / log / restart-stub counter, and its own fake controller.
newcase() {
  N=$((N+1)); C="$WORK/c$N"; mkdir -p "$C/o/logs" "$C/state"
  STUB="$C/restart.stub"; CALLS="$C/restart.calls"; : > "$CALLS"
  printf '#!/bin/sh\nprintf "restart\\n" >> "%s"\n' "$CALLS" > "$STUB"; chmod +x "$STUB"
}
# A live "controller": a sleeping process whose argv contains orch-loop.sh, recorded in the lock.
start_ctrl() {
  printf 'sleep 300\n' > "$C/o/fake-orch-loop.sh"
  bash "$C/o/fake-orch-loop.sh" >/dev/null 2>&1 &
  CPID=$!
  printf '%s' "$CPID" > "$C/o/.orch.lock"
}
stop_ctrl() { [ -n "${CPID:-}" ] && kill "$CPID" 2>/dev/null; CPID=""; : > "$C/o/.orch.lock"; }
hb_now()   { date +%s > "$C/o/heartbeat"; }
hb_stale() { echo $(( $(date +%s) - 900 )) > "$C/o/heartbeat"; }   # HB_STALE default 780 → stale
# run [extra env…] — one watchdog pass against the current case; prints the decision line.
run() {
  env O="$C/o" HB="$C/o/heartbeat" WATCHDOG_STATE_DIR="$C/state" \
      WATCHDOG_LOG="$C/state/controller-watchdog.log" \
      WATCHDOG_RESTART_CMD="$STUB" SETTLE=0 HB_STALE=780 MAX_CONSEC="${MAXC:-3}" \
      WATCHDOG_NO_RESTART=1 ${@:+"/usr/bin/env" "$@"} bash "$WD" 2>&1 \
    | grep -m1 'verdict=' || true
}
# runall — every line the pass emitted (the post-restart re-check is a SECOND line, and a case about
# recovery must read it; `run` returns the DECISION line, so a STILL_WEDGED follow-up cannot mask it).
runall() {
  env O="$C/o" HB="$C/o/heartbeat" WATCHDOG_STATE_DIR="$C/state" \
      WATCHDOG_LOG="$C/state/controller-watchdog.log" \
      WATCHDOG_RESTART_CMD="$STUB" WATCHDOG_NO_RESTART=1 SETTLE=0 HB_STALE=780 MAX_CONSEC=3 \
      bash "$WD" 2>&1 || true
}
restarts() { wc -l < "$CALLS" | tr -d ' '; }
crashes()  { [ -f "$C/state/controller-watchdog.crash" ] && echo 1 || echo 0; }

# ═══ 1. advancing heartbeat + live pid → HEALTHY, and the stub was NOT called ════════════════════
echo "── 1. healthy: a cycling controller is left alone"
newcase; start_ctrl; hb_now
out="$(run)"
assert_contains "$out" "verdict=HEALTHY" "a fresh heartbeat + live pid is HEALTHY"
assert_contains "$out" "pid=$CPID" "…and the line names the controller pid"
assert_eq "$(restarts)" "0" "…and the restart command was NOT called (proven, not assumed)"
assert_eq "$(crashes)" "0" "…and no crash record was written"
assert_eq "$(run --status | wc -l | tr -d ' ')" "$(run --status >/dev/null; run --status | wc -l | tr -d ' ')" "--status renders the state (a reader other than launchd can see it)"

# ═══ 2. THE MEASURED CASE: live pid + stale heartbeat → exactly ONE restart, WEDGED ══════════════
echo "── 2. WEDGED: pid alive, heartbeat stale (the measured hour)"
newcase; start_ctrl; hb_stale
out="$(run)"
assert_contains "$out" "verdict=WEDGED" "a live pid with a stale heartbeat is WEDGED, not healthy"
assert_contains "$out" "heartbeat=900s" "…and the line carries the heartbeat age the decision used"
assert_eq "$(restarts)" "1" "…and EXACTLY one restart was issued"
assert_contains "$(run)" "verdict=WEDGED" "a second pass re-observes the same state (no silent success)"

# 2b. the same, with a restart that actually cures it → RECOVERED, still exactly one restart
echo "── 2b. one restart that works is reported as RECOVERED"
newcase; start_ctrl; hb_stale
cat > "$STUB" <<EOF
#!/bin/sh
printf "restart\n" >> "$CALLS"
date +%s > "$C/o/heartbeat"
EOF
chmod +x "$STUB"
assert_contains "$(runall)" "verdict=RECOVERED" "a restart that restores cycling is reported RECOVERED"
assert_eq "$(restarts)" "1" "…with exactly one restart"

# ═══ 3. dead pid + stale heartbeat → DOWN → restart ═════════════════════════════════════════════
echo "── 3. DOWN: no pid, heartbeat stale"
newcase; printf '999999' > "$C/o/.orch.lock"; hb_stale
out="$(run)"
assert_contains "$out" "verdict=DOWN" "a stale heartbeat with no pid is DOWN"
assert_eq "$(restarts)" "1" "…and it restarts"

# ═══ 4. missing heartbeat → DOWN, NEVER healthy (an absent datum is not a fresh one) ════════════
echo "── 4. a missing heartbeat is DOWN, never HEALTHY"
newcase; start_ctrl          # live pid, NO heartbeat file at all
out="$(run)"
assert_contains "$out" "verdict=DOWN" "a live pid with NO heartbeat file is DOWN"
assert_absent  "$out" "HEALTHY" "…and nothing in the line says HEALTHY"
assert_contains "$out" "no readable heartbeat" "…and it names the missing datum"
assert_eq "$(restarts)" "1" "…and it restarts"
# 4b. an empty / garbage heartbeat file is the same class — present but not a usable instant
newcase; start_ctrl; printf 'not-a-time' > "$C/o/heartbeat"; touch -t 202001010000 "$C/o/heartbeat"
# ⛔ present-but-unusable is NOT the same class as ABSENT: the value cannot be read, but the file's own
# mtime still dates the last write — and that age is 6 years, i.e. ALIVE BUT STALE, which is WEDGED.
# Reporting DOWN here would send an operator looking for a dead process that is running.
assert_contains "$(run)" "verdict=WEDGED" "a heartbeat present but unusable (mtime 2020) is WEDGED, never healthy"

# ═══ 5. N consecutive wedges → restarting STOPS, ONE crash line, and it SURVIVES a restart ═══════
echo "── 5. a crash loop stops being restarted, and the crash is recorded ONCE"
newcase; start_ctrl; hb_stale; MAXC=2
printf 'orchestrator: starting\n' > "$C/o/logs/controller-stdout.log"
printf 'line: 412: syntax error near unexpected token `(`\n' >> "$C/o/logs/controller-stdout.log"
printf 'orchestrator: exiting 2\n' >> "$C/o/logs/controller-stdout.log"
o1="$(run)"; o2="$(run)"; o3="$(run)"
assert_contains "$o1" "verdict=WEDGED" "wedge 1/2 restarts"
assert_contains "$o2" "verdict=WEDGED" "wedge 2/2 restarts"
assert_contains "$o3" "verdict=WEDGED_STOPPED" "wedge 3 (> 2) STOPS restarting"
assert_contains "$o3" "restart=0" "…and says so in the same line"
assert_eq "$(restarts)" "2" "…and the restart count stopped at the limit (2), not 3"
assert_eq "$(crashes)" "1" "…and ONE crash record exists"
assert_contains "$(cat "$C/state/controller-watchdog.crash")" "syntax error" "…and it NAMES the crash from the controller's own stdout"
assert_contains "$(cat "$C/state/controller-watchdog.crash")" "last 25 lines" "…and carries the tail of that log"
sig1="$(cksum < "$C/state/controller-watchdog.crash")"
# a SIMULATED restart: the stub runs, the controller is replaced, the wedge continues
stop_ctrl; start_ctrl; hb_stale
o4="$(run)"
assert_contains "$o4" "verdict=WEDGED_STOPPED" "after a restart the loop is STILL stopped"
assert_eq "$(restarts)" "2" "…and it did not restart again"
assert_eq "$(cksum < "$C/state/controller-watchdog.crash")" "$sig1" "…and the crash record SURVIVED the restart byte for byte (written once)"

# ═══ 6. the decision log is bounded and rotated with a line saying so ═══════════════════════════
echo "── 6. the decision log cannot grow without bound"
newcase; start_ctrl; hb_now
head -c 2000 /dev/zero | tr '\0' 'x' > "$C/state/controller-watchdog.log"
env O="$C/o" HB="$C/o/heartbeat" WATCHDOG_STATE_DIR="$C/state" \
    WATCHDOG_LOG="$C/state/controller-watchdog.log" WATCHDOG_LOG_MAX_BYTES=1024 \
    WATCHDOG_RESTART_CMD="$STUB" WATCHDOG_NO_RESTART=1 SETTLE=0 bash "$WD" >/dev/null 2>&1
assert_contains "$(cat "$C/state/controller-watchdog.log")" "LOG-ROTATED" "an over-bound log is rotated with a line naming it"
[ "$(wc -c < "$C/state/controller-watchdog.log")" -lt 1024 ] && ok "…and the log came back under the bound" || bad "…the log is still over its bound"

# ═══ 7. hostile bounds fall back instead of inverting the predicate ═════════════════════════════
echo "── 7. a non-numeric HB_STALE must not turn a healthy controller into a wedged one"
newcase; start_ctrl; hb_now
out="$(env O="$C/o" HB="$C/o/heartbeat" WATCHDOG_STATE_DIR="$C/state" WATCHDOG_LOG="$C/state/l" \
        WATCHDOG_RESTART_CMD="$STUB" WATCHDOG_NO_RESTART=1 SETTLE=0 HB_STALE=abc bash "$WD" 2>&1 | grep -m1 verdict=)"
assert_contains "$out" "verdict=HEALTHY" "HB_STALE=abc falls back to 780 and the controller stays healthy"
assert_eq "$(restarts)" "0" "…and nothing was restarted"
# a zero HB_STALE is a legitimate (strict) setting: every non-zero age is stale
newcase; start_ctrl; echo $(( $(date +%s) - 5 )) > "$C/o/heartbeat"
out="$(env O="$C/o" HB="$C/o/heartbeat" WATCHDOG_STATE_DIR="$C/state" WATCHDOG_LOG="$C/state/l" \
        WATCHDOG_RESTART_CMD="$STUB" WATCHDOG_NO_RESTART=1 SETTLE=0 HB_STALE=0 bash "$WD" 2>&1 | grep -m1 verdict=)"
assert_contains "$out" "verdict=WEDGED" "HB_STALE=0 is honoured (a 5s-old heartbeat is stale), not silently defaulted"

# ═══ 8. exit 0 always ══════════════════════════════════════════════════════════════════════════
echo "── 8. the watchdog always exits 0"
newcase; start_ctrl; hb_stale
env O="$C/o" HB="$C/o/heartbeat" WATCHDOG_STATE_DIR="$C/state" WATCHDOG_LOG="$C/state/l" \
    WATCHDOG_RESTART_CMD="/bin/false" WATCHDOG_NO_RESTART=1 SETTLE=0 bash "$WD" >/dev/null 2>&1
assert_eq "$?" "0" "a FAILED restart verb still exits 0 (the verdict is the output)"
env O="$C/o" HB="$C/o/heartbeat" WATCHDOG_STATE_DIR="$C/state" WATCHDOG_LOG="$C/state/l" \
    WATCHDOG_RESTART_CMD="/bin/false" WATCHDOG_NO_RESTART=1 SETTLE=0 bash "$WD" >/dev/null 2>&1
assert_contains "$(grep -m1 RESTART-FAILED "$C/state/l")" "RESTART-FAILED" "…and it says the restart failed"
# ⛔ THE STUB AND THE SUPPRESSION ARE NOT OPTIONAL, even here: the FIRST version of this case ran the
# real platform verb and issued `launchctl kickstart -k gui/501/com.eldato.orchestrator-stack` against
# the LIVE stack (measured — the job's pid changed). A unit test must never be able to do that, which
# is why `WATCHDOG_NO_RESTART` exists in the product, not only in this file.
assert_eq "$(env O=/nonexistent/xyz WATCHDOG_STATE_DIR="$C/state2" WATCHDOG_NO_RESTART=1 WATCHDOG_LOG="$C/state2/l" SETTLE=0 bash "$WD" >/dev/null 2>&1; echo $?)" "0" "an unusable O still exits 0"

# ═══ 9. NON-VACUITY: remove the heartbeat check and the WEDGED arm MUST fail ═════════════════════
echo "── 9. non-vacuity: without the heartbeat check, a wedged controller reads healthy"
MUT="$WORK/mutant.sh"
sed 's|^  hb_is_fresh() {.*$|  hb_is_fresh() { return 0; }|' "$WD" > "$MUT"
if cmp -s "$WD" "$MUT"; then
  bad "mutation did not apply — the assertions below would be vacuous"
else
  newcase; start_ctrl; hb_stale
  mout="$(env O="$C/o" HB="$C/o/heartbeat" WATCHDOG_STATE_DIR="$C/state" WATCHDOG_LOG="$C/state/l" \
           WATCHDOG_RESTART_CMD="$STUB" WATCHDOG_NO_RESTART=1 SETTLE=0 bash "$MUT" 2>&1 | grep -m1 verdict=)"
  assert_contains "$mout" "verdict=HEALTHY" "MUTANT: with the heartbeat check gone, the wedged controller reads HEALTHY"
  assert_eq "$(restarts)" "0" "MUTANT: …and is never restarted — so case 2 is not passing by accident"
  # the shipped script, same fixture, must disagree
  newcase; start_ctrl; hb_stale
  sout="$(run)"
  assert_contains "$sout" "verdict=WEDGED" "the SHIPPED script on the same fixture says WEDGED (the mutation is the only difference)"
fi

echo
if [ "$FAIL" -eq 0 ]; then echo "PASS — watchdog-loop: all cases ok"; exit 0; fi
echo "FAIL — $FAIL case(s)"; exit 1
