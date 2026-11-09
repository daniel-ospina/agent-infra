#!/usr/bin/env bash
# heartbeat-launch.test.sh — self-check for scripts/heartbeat-launch.sh (#1867).
#
# Run: bash scripts/heartbeat-launch.test.sh
#
# WHAT THIS SUITE IS FOR
# ----------------------
# The heartbeat has never once worked on the machine it runs on: it was installed as a launchd job,
# and the cmux control socket (`socketControlMode = cmuxOnly`) refuses a launchd-spawned caller. The
# measured result was 1,695 `lane-status: DEGRADED` reads, 210 refusals and **0 delivered nudges**,
# with the log reading as activity for the job's whole life.
#
# The pre-change behaviour fails this suite in the strongest possible way: **there was no launcher
# at all**, so `start` — the documented path — did not exist, and the only thing an operator could
# do was the thing that was wrong. Every assertion below is therefore about behaviour that could
# not be checked before this change.
#
# §1-§3  the launchd refusal — the gate that must never open
# §4-§6  start: the kill file, idempotence over a LIVE pid, and --dry-run launching nothing
# §7-§13 check: a BEHAVIOUR probe (0 OK / 1 DRIFT / 2 UNKNOWN, never a pass by default)
# §14    the launcher carries no literal user home
#
# Hermetic: every case builds its own state dir under a temp root and sets
# HEARTBEAT_PI_AGENT_DIR, which is the SAME single root scripts/heartbeat-loop.sh derives from — a
# scratch instance is a layout, not a parallel mechanism. No real state directory is read or
# written, and no loop is ever started.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCH="$SCRIPT_DIR/heartbeat-launch.sh"
LOOP="$SCRIPT_DIR/heartbeat-loop.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

assert_eq() { # <actual> <expected> <label>
    if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: $1, want: $2)"; fi
}
assert_contains() {
    if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi
}
assert_not_contains() {
    if grep -qF -- "$2" <<<"$1"; then bad "$3 (unexpected: $2)"; else ok "$3"; fi
}

[ -f "$LAUNCH" ] || { echo "FATAL: $LAUNCH does not exist — the launch path is the subject of this suite"; exit 1; }
[ -x "$LAUNCH" ] || { echo "FATAL: $LAUNCH is not executable"; exit 1; }
command -v python3 >/dev/null 2>&1 || echo "note: no python3 on PATH — the check-probe cases below will read UNKNOWN"

T="$(mktemp -d /tmp/heartbeat-launch-test.XXXXXX)"
cleanup() {
    local p
    if [ -f "$T/livepids" ]; then
        while IFS= read -r p; do [ -n "$p" ] && kill "$p" 2>/dev/null; done < "$T/livepids"
    fi
    rm -rf "$T"
}
trap cleanup EXIT

# A fresh scratch root per case, so one case's pidfile/snapshot can never decide another's verdict.
newroot() { # <name> → echoes the root, creates <root>/agent/state
    local r="$T/$1"
    mkdir -p "$r/agent/state"
    printf '%s' "$r"
}

# A LIVE stand-in for the loop (the real one would run a fleet pass). `kill -0` is the only thing
# the launcher and the probe ask about a pid, so a sleeping process is the same fact to them.
# ⛔ STDOUT/STDERR ARE REDIRECTED: this runs inside `$( )`, and a child holding the substitution's
# stdout keeps it open, so the caller BLOCKS for the whole sleep. (Measured: the suite hung at §4.)
# The pid is recorded in a FILE, not an array, because a command substitution is a subshell and an
# array appended inside it is lost — the reaper would then have nothing to kill.
live_pid() {
    sleep 120 >/dev/null 2>&1 &
    printf '%s\n' "$!" >> "$T/livepids"
    printf '%s' "$!"
}

run() { # <root> [ENV=VAL ...] -- <args...>
    local root="$1"; shift
    local envs=()
    while [ "${1:-}" != "--" ] && [ $# -gt 0 ]; do envs+=("$1"); shift; done
    shift || true
    env -u XPC_SERVICE_NAME HEARTBEAT_PI_AGENT_DIR="$root/agent" "${envs[@]}" bash "$LAUNCH" "$@" 2>&1
}

echo "── 1-3. The launchd refusal (§1867) ──"

R="$(newroot s1)"
OUT="$(env HEARTBEAT_PI_AGENT_DIR="$R/agent" XPC_SERVICE_NAME=com.tortoise.heartbeat bash "$LAUNCH" start 2>&1)"; RC=$?
assert_eq "$RC" "1" "§1 start REFUSES under launchd (rc=1, not a silent success)"
assert_contains "$OUT" "com.tortoise.heartbeat" "§1 …and names the launchd Label it found"
assert_contains "$OUT" "socketControlMode" "§1 …and names the socket gate that makes it blind"
assert_contains "$OUT" "heartbeat-launch.sh start" "§1 …and names the documented launch path"
[ -f "$R/agent/state/heartbeat-loop.pid" ] \
    && bad "§1 …and started NOTHING (no pidfile was written)" \
    || ok "§1 …and started NOTHING (no pidfile was written)"

# ⛔ THE REFUSAL MUST NOT DEPEND ON `start` BEING DISTINGUISHED BY ARGUMENT. A launcher that refuses
# only when asked nicely is not a gate: `--dry-run` under launchd must ALSO be a refusal, because the
# question "may this run under launchd" is answered by the ENVIRONMENT, not by the argv.
OUT="$(env HEARTBEAT_PI_AGENT_DIR="$R/agent" XPC_SERVICE_NAME=com.tortoise.heartbeat bash "$LAUNCH" start --dry-run 2>&1)"; RC=$?
assert_eq "$RC" "1" "§2 the refusal also applies to --dry-run (the environment decides, not the argv)"
assert_contains "$OUT" "REFUSING" "§2 …and it is a refusal, not a warning beside a dry run"

# The witness is the ENVIRONMENT VARIABLE launchd sets in the job's own env — so an interactive
# shell, a tmux pane and a systemd unit (which set none of it) are all allowed through.
R="$(newroot s2)"
OUT="$(env -u XPC_SERVICE_NAME HEARTBEAT_PI_AGENT_DIR="$R/agent" bash "$LAUNCH" start --dry-run 2>&1)"; RC=$?
assert_eq "$RC" "0" "§3 with no launchd witness, start --dry-run is ALLOWED (rc=0)"
assert_not_contains "$OUT" "REFUSING" "§3 …and nothing is refused"

echo "── 4-6. start: the kill file, liveness, and --dry-run ──"

R="$(newroot s3)"
: > "$R/agent/state/HEARTBEAT-OFF"
OUT="$(run "$R" -- start)"; RC=$?
assert_eq "$RC" "1" "§4 start REFUSES while the kill file is present"
assert_contains "$OUT" "HEARTBEAT-OFF" "§4 …and names the file that is stopping it"
assert_contains "$OUT" "rm -f" "§4 …and gives the one command that resumes it"
assert_not_contains "$OUT" "started (pid" "§4 …and does NOT claim it started"

# ⛔ A LIVE PID IS THE EVIDENCE, NOT THE FILE. "already running" over a DEAD pid would be the same
# false PASS one layer down, so the two cases are asserted separately.
R="$(newroot s4)"
P="$(live_pid)"; printf '%s\n' "$P" > "$R/agent/state/heartbeat-loop.pid"
OUT="$(run "$R" -- start)"; RC=$?
assert_eq "$RC" "0" "§5 a LIVE pidfile reads as already running (rc=0, idempotent)"
assert_contains "$OUT" "already running" "§5 …and says so rather than forking a second loop"

R="$(newroot s5)"
printf '999999\n' > "$R/agent/state/heartbeat-loop.pid"
OUT="$(run "$R" -- start --dry-run)"; RC=$?
assert_eq "$RC" "0" "§6 a DEAD pid is named as a stale record (the launch is not silently skipped)"
assert_contains "$OUT" "stale pidfile" "§6 …and the word 'stale' appears, so the record is not trusted"
assert_contains "$OUT" "DRY RUN" "§6 …and --dry-run prints the command it WOULD run"
assert_contains "$OUT" "LOOP_DETACHED=1" "§6 …including LOOP_DETACHED=1, so the loop is not forked twice"
[ -f "$R/agent/state/heartbeat-launch.log" ] \
    && bad "§6 …and launched NOTHING (no log file was created)" \
    || ok "§6 …and launched NOTHING (no log file was created)"

echo "── 7-13. check: the behaviour probe (0 OK / 1 DRIFT / 2 UNKNOWN) ──"

R="$T/nostate"
OUT="$(env -u XPC_SERVICE_NAME HEARTBEAT_PI_AGENT_DIR="$R/agent" bash "$LAUNCH" check 2>&1)"; RC=$?
assert_eq "$RC" "2" "§7 check returns UNKNOWN (2) when the state dir does not exist — never a pass"
assert_contains "$OUT" "UNKNOWN" "§7 …and says UNKNOWN on the line a caller reads"

R="$(newroot c1)"
OUT="$(run "$R" -- check)"; RC=$?
assert_eq "$RC" "1" "§8 a loop that is not running is DRIFT (1)"
assert_contains "$OUT" "NOT running" "§8 …and the line names the condition"

R="$(newroot c2)"
P="$(live_pid)"; printf '%s\n' "$P" > "$R/agent/state/heartbeat-loop.pid"
OUT="$(run "$R" -- check)"; RC=$?
assert_eq "$RC" "1" "§9 a LIVE loop that never published is still DRIFT — a heartbeat with no beat"
assert_contains "$OUT" "no fleet read was ever published" "§9 …and the reason is named, not inferred"

# ⛔ THE ASSERTION THIS SUITE EXISTS FOR: alive is NOT the verdict. A running loop whose last fleet
# read is DEGRADED is the exact measured failure (27/27 degraded rows, 0 nudges) and it must be
# RED — every content/process check on the box said that job was fine.
R="$(newroot c3)"
P="$(live_pid)"; printf '%s\n' "$P" > "$R/agent/state/heartbeat-loop.pid"
printf '[{"lane":"a","degraded":true},{"lane":"b","degraded":true}]\n' > "$R/agent/state/lane-status.last.json"
OUT="$(run "$R" -- check)"; RC=$?
assert_eq "$RC" "1" "§10 ALIVE + DEGRADED is DRIFT — liveness is not health"
assert_contains "$OUT" "2/2 rows DEGRADED" "§10 …and the degraded count is printed"

# An EMPTY row set is not a quiet fleet: `degraded` is a per-row flag, so zero rows is vacuously
# "clean" to any naive check — the trap `lane-status.py`'s own publisher documents.
R="$(newroot c4)"
P="$(live_pid)"; printf '%s\n' "$P" > "$R/agent/state/heartbeat-loop.pid"
printf '[]\n' > "$R/agent/state/lane-status.last.json"
OUT="$(run "$R" -- check)"; RC=$?
assert_eq "$RC" "1" "§11 an EMPTY snapshot is DRIFT, not a healthy fleet"
assert_contains "$OUT" "empty fleet snapshot" "§11 …and it is named as an empty read"

R="$(newroot c5)"
P="$(live_pid)"; printf '%s\n' "$P" > "$R/agent/state/heartbeat-loop.pid"
printf '[{"lane":"a","degraded":false}]\n' > "$R/agent/state/lane-status.last.json"
touch -d '40 minutes ago' "$R/agent/state/lane-status.last.json" 2>/dev/null \
    || touch -t "$(date -v-40M '+%Y%m%d%H%M' 2>/dev/null || date '+%Y%m%d%H%M')" "$R/agent/state/lane-status.last.json"
OUT="$(run "$R" HEARTBEAT_CHECK_MAX_AGE=900 -- check)"; RC=$?
assert_eq "$RC" "1" "§12 a STALE fleet read is DRIFT (the loop stopped publishing)"
assert_contains "$OUT" "STALE" "§12 …and says STALE rather than reporting the old rows as current"

R="$(newroot c6)"
P="$(live_pid)"; printf '%s\n' "$P" > "$R/agent/state/heartbeat-loop.pid"
printf 'not json at all\n' > "$R/agent/state/lane-status.last.json"
OUT="$(run "$R" -- check)"; RC=$?
assert_eq "$RC" "2" "§13 an UNPARSEABLE snapshot is UNKNOWN (2), never 'no degraded rows'"

# The positive case, and the only one that may be green.
R="$(newroot c7)"
P="$(live_pid)"; printf '%s\n' "$P" > "$R/agent/state/heartbeat-loop.pid"
printf '[{"lane":"a","degraded":false},{"lane":"b","degraded":false}]\n' > "$R/agent/state/lane-status.last.json"
OUT="$(run "$R" -- check)"; RC=$?
assert_eq "$RC" "0" "§13b a LIVE loop with a FRESH, non-degenerate read is OK (0)"
assert_contains "$OUT" "0 degraded" "§13b …and the green line states the counts it read"

echo "── 14. the launcher and the loop carry no literal user home ──"

# ⛔ THIS IS THE ONE ASSERTION THAT FAILS ON PRE-CHANGE CODE BY CONSTRUCTION. The loop exported
# `/Users/danielospina/bin:/Users/danielospina/.pi/agent/shims:$PATH` and later re-pinned
# HOME to that same directory — correct on exactly one laptop, and on any other box it both
# prepended non-directories and SKIPPED the `gh` shim dir entirely. Comments may quote the old
# path as evidence; a non-comment occurrence is the defect.
LIT="$(grep -n '/Users/danielospina' "$LOOP" | grep -v '^[0-9]*:#' || true)"
assert_eq "$LIT" "" "§14 scripts/heartbeat-loop.sh has no NON-COMMENT literal user home"
assert_not_contains "$(grep -n '/Users/' "$LAUNCH" | grep -v '^[0-9]*:#' || true)" "/Users/" \
    "§14 scripts/heartbeat-launch.sh has no literal /Users path either"

# HOME is REQUIRED, not force-set: an unset HOME must refuse loudly (rc=2), never fall through to
# `cd "$HOME" || exit 0` and exit green having logged nothing.
OUT="$(env -u HOME -u XPC_SERVICE_NAME HEARTBEAT_PI_AGENT_DIR="$T/nohome/agent" bash "$LOOP" 2>&1)"; RC=$?
assert_eq "$RC" "2" "§14 an unset HOME makes the loop REFUSE (2) instead of silently exiting 0"
assert_contains "$OUT" "REFUSING" "§14 …and the refusal says so on stderr"

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "✅ heartbeat-launch suite passed ($PASS assertions)"
    exit 0
fi
echo "❌ heartbeat-launch suite FAILED ($FAIL of $((PASS + FAIL)) assertions)"
exit 1
