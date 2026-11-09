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
# §4-§6  start: the kill file, idempotence over a LIVE loop, the RECYCLED pid, and --dry-run
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

# A LIVE stand-in for the loop (the real one would run a fleet pass).
# ⛔ THIS IS THE **RECYCLED-PID** SHAPE (#1867 review P2): a process this user owns, alive, holding a
# pid — and NOT the loop. The pidfile can name it after a SIGKILL/OOM kill/reboot, because the kernel
# reuses pids. `kill -0` alone reads it as a healthy heartbeat; nothing else may.
# ⛔ STDOUT/STDERR ARE REDIRECTED: this runs inside `$( )`, and a child holding the substitution's
# stdout keeps it open, so the caller BLOCKS for the whole sleep. (Measured: the suite hung at §4.)
# The pid is recorded in a FILE, not an array, because a command substitution is a subshell and an
# array appended inside it is lost — the reaper would then have nothing to kill.
live_pid() {
    sleep 120 >/dev/null 2>&1 &
    printf '%s\n' "$!" >> "$T/livepids"
    printf '%s' "$!"
}

# A LIVE process whose OWN ARGV is the loop (#1867 review P2) — what the pidfile legitimately names.
# ⛔ NO `exec` OF A SLEEPER: the process's argv must keep naming the script, which is the identity the
# launcher now proves. `while :; do sleep 1; done` keeps only a one-second child, so this leaves no
# long-lived litter for the next case's cleanup to chase.
LOOP_STANDIN="$T/standin/scripts/heartbeat-loop.sh"
mkdir -p "$(dirname "$LOOP_STANDIN")"
printf '#!/usr/bin/env bash\nwhile :; do sleep 1; done\n' > "$LOOP_STANDIN"
chmod +x "$LOOP_STANDIN"
loop_pid() {
    bash "$LOOP_STANDIN" >/dev/null 2>&1 &
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

# ⛔ THE OTHER HALF OF THE WITNESS (#1867 review P1). macOS ALSO sets `XPC_SERVICE_NAME` in the
# process tree of GUI apps, where the value is a LaunchServices SENTINEL rather than a launchd label:
# `0` (a Terminal/iTerm shell) and `application.<bundle-id>.<uuid>` (an app-launched shell). A bare
# non-empty test refused in BOTH — including a cmux pane, which is the very shell the refusal
# message tells the operator to run `start` from — so the gate closed on the fix. Both must be
# ALLOWED, and §1/§2 above keep proving a REAL label still refuses: the polarity is fail-closed
# (only these two sentinels are allow-listed), not "anything unfamiliar is fine".
R="$(newroot s2b)"
OUT="$(env HEARTBEAT_PI_AGENT_DIR="$R/agent" XPC_SERVICE_NAME=0 bash "$LAUNCH" start --dry-run 2>&1)"; RC=$?
assert_eq "$RC" "0" "§3b XPC_SERVICE_NAME=0 (an ordinary Terminal shell) is NOT launchd — allowed"
assert_not_contains "$OUT" "REFUSING" "§3b …and nothing is refused"
OUT="$(env HEARTBEAT_PI_AGENT_DIR="$R/agent" XPC_SERVICE_NAME=application.com.apple.Terminal.9F2C bash "$LAUNCH" start --dry-run 2>&1)"; RC=$?
assert_eq "$RC" "0" "§3b an application.<bundle-id>.<uuid> sentinel (an app-launched shell) — allowed too"
assert_not_contains "$OUT" "REFUSING" "§3b …and nothing is refused"

echo "── 4-6. start: the kill file, liveness, and --dry-run ──"

R="$(newroot s3)"
: > "$R/agent/state/HEARTBEAT-OFF"
OUT="$(run "$R" -- start)"; RC=$?
assert_eq "$RC" "1" "§4 start REFUSES while the kill file is present"
assert_contains "$OUT" "HEARTBEAT-OFF" "§4 …and names the file that is stopping it"
assert_contains "$OUT" "rm -f" "§4 …and gives the one command that resumes it"
assert_not_contains "$OUT" "started (pid" "§4 …and does NOT claim it started"

# ⛔ A LIVE PID IS THE EVIDENCE, NOT THE FILE. "already running" over a DEAD pid would be the same
# false PASS one layer down, so the three cases are asserted separately: the LOOP (idempotent), a
# DEAD pid (stale), and a RECYCLED LIVE pid that is NOT the loop (also stale — and the one `kill -0`
# alone could never tell apart, #1867 review P2).
R="$(newroot s4)"
P="$(loop_pid)"; printf '%s\n' "$P" > "$R/agent/state/heartbeat-loop.pid"
OUT="$(run "$R" -- start)"; RC=$?
assert_eq "$RC" "0" "§5 a LIVE loop pidfile reads as already running (rc=0, idempotent)"
assert_contains "$OUT" "already running" "§5 …and says so rather than forking a second loop"

# ⛔ THE RECYCLED PID (#1867 review P2). A live, user-owned process that is NOT the loop (the shape a
# reboot leaves in the pidfile) must be named STALE — the pre-fix code proved liveness with `kill -0`
# alone and printed "already running", exiting 0 WITHOUT launching the launched-once loop, so the
# heartbeat stayed dead while the operator was told it was running.
R="$(newroot s5b)"
P="$(live_pid)"; printf '%s\n' "$P" > "$R/agent/state/heartbeat-loop.pid"
OUT="$(run "$R" -- start --dry-run)"; RC=$?
assert_eq "$RC" "0" "§5b a RECYCLED pid does not block the launch (start continues to the launch path)"
assert_contains "$OUT" "stale pidfile" "§5b …the record is named STALE, not trusted"
assert_contains "$OUT" "is NOT heartbeat-loop.sh" "§5b …and the reason is the identity, not the liveness"
assert_not_contains "$OUT" "already running" "§5b …and 'already running' is NOT claimed over a stranger (§5 kept green: polarity is not 'anything alive is stale')"
# ⛔ NO EXIT-CODE ROW HERE (review round 3, rule-3): `cmd_status` ends `return 0` unconditionally, so
# no mutation of this diff could redden one. The live assertion is the COLUMN — the verdict that was
# wrong on a recycled pid.
OUT="$(env HEARTBEAT_PI_AGENT_DIR="$R/agent" bash "$LAUNCH" status 2>&1)"
assert_contains "$OUT" "another process" "§5b status's 'alive:' column says the pid is someone else, not 'yes'"

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
P="$(loop_pid)"; printf '%s\n' "$P" > "$R/agent/state/heartbeat-loop.pid"
OUT="$(run "$R" -- check)"; RC=$?
assert_eq "$RC" "1" "§9 a LIVE loop that never published is still DRIFT — a heartbeat with no beat"
assert_contains "$OUT" "no fleet read was ever published" "§9 …and the reason is named, not inferred"

# ⛔ A RECYCLED PID IS NOT ALIVE AS THE LOOP (#1867 review P2). Same fixture as §13b's green case —
# fresh, non-degenerate snapshot, every other input healthy — except the pid belongs to a stranger.
# Pre-fix this printed `OK loop alive` and returned 0 over a dead heartbeat: the false PASS this
# whole file exists to remove, produced by the probe that was added to remove it.
R="$(newroot c2b)"
P="$(live_pid)"; printf '%s\n' "$P" > "$R/agent/state/heartbeat-loop.pid"
printf '[{"lane":"a","degraded":false}]\n' > "$R/agent/state/lane-status.last.json"
OUT="$(run "$R" -- check)"; RC=$?
assert_eq "$RC" "1" "§9b a RECYCLED pid is DRIFT (1), never OK — a stranger holding the number is not the loop"
assert_contains "$OUT" "NOT running" "§9b …and the line says the loop is not running"
assert_contains "$OUT" "recycled pid" "§9b …and names the recycled pid as the reason"
assert_not_contains "$OUT" "OK    loop alive" "§9b …and never prints the OK line it used to"

# ⛔ THE ASSERTION THIS SUITE EXISTS FOR: alive is NOT the verdict. A running loop whose last fleet
# read is DEGRADED is the exact measured failure (27/27 degraded rows, 0 nudges) and it must be
# RED — every content/process check on the box said that job was fine.
R="$(newroot c3)"
P="$(loop_pid)"; printf '%s\n' "$P" > "$R/agent/state/heartbeat-loop.pid"
printf '[{"lane":"a","degraded":true},{"lane":"b","degraded":true}]\n' > "$R/agent/state/lane-status.last.json"
OUT="$(run "$R" -- check)"; RC=$?
assert_eq "$RC" "1" "§10 ALIVE + DEGRADED is DRIFT — liveness is not health"
assert_contains "$OUT" "2/2 rows DEGRADED" "§10 …and the degraded count is printed"

# An EMPTY row set is not a quiet fleet: `degraded` is a per-row flag, so zero rows is vacuously
# "clean" to any naive check — the trap `lane-status.py`'s own publisher documents.
R="$(newroot c4)"
P="$(loop_pid)"; printf '%s\n' "$P" > "$R/agent/state/heartbeat-loop.pid"
printf '[]\n' > "$R/agent/state/lane-status.last.json"
OUT="$(run "$R" -- check)"; RC=$?
assert_eq "$RC" "1" "§11 an EMPTY snapshot is DRIFT, not a healthy fleet"
assert_contains "$OUT" "empty fleet snapshot" "§11 …and it is named as an empty read"

R="$(newroot c5)"
P="$(loop_pid)"; printf '%s\n' "$P" > "$R/agent/state/heartbeat-loop.pid"
printf '[{"lane":"a","degraded":false}]\n' > "$R/agent/state/lane-status.last.json"
touch -d '40 minutes ago' "$R/agent/state/lane-status.last.json" 2>/dev/null \
    || touch -t "$(date -v-40M '+%Y%m%d%H%M' 2>/dev/null || date '+%Y%m%d%H%M')" "$R/agent/state/lane-status.last.json"
OUT="$(run "$R" HEARTBEAT_CHECK_MAX_AGE=900 -- check)"; RC=$?
assert_eq "$RC" "1" "§12 a STALE fleet read is DRIFT (the loop stopped publishing)"
assert_contains "$OUT" "STALE" "§12 …and says STALE rather than reporting the old rows as current"

R="$(newroot c6)"
P="$(loop_pid)"; printf '%s\n' "$P" > "$R/agent/state/heartbeat-loop.pid"
printf 'not json at all\n' > "$R/agent/state/lane-status.last.json"
OUT="$(run "$R" -- check)"; RC=$?
assert_eq "$RC" "2" "§13 an UNPARSEABLE snapshot is UNKNOWN (2), never 'no degraded rows'"

# The positive case, and the only one that may be green.
R="$(newroot c7)"
P="$(loop_pid)"; printf '%s\n' "$P" > "$R/agent/state/heartbeat-loop.pid"
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
echo "── 15. status timestamps are READABLE on macOS too ──"

# ⛔ `date -r FILE` IS GNU-ONLY SEMANTICS (#1867 review P2). GNU reads `-r` as "use FILE as the
# reference"; BSD/macOS reads it as "seconds since epoch", so passing a PATH failed and `status`
# printed `<unreadable>` for BOTH timestamps — from the verb the docs table says answers "how stale
# is the last pass?", on the one platform that has the defect. This arm emulates BSD `date` in a
# PATH shim (no `-d` at all; `-r` accepts only an epoch), so the GNU-only call cannot accidentally
# pass just because this host is Linux. Pre-change code prints `<unreadable>` here; the portable
# ladder (`stat -c %Y || stat -f %m`, then `date -d @… || date -r …`) answers.
BSDBIN="$T/bsdbin"; mkdir -p "$BSDBIN"
cat > "$BSDBIN/date" <<'SH'
#!/usr/bin/env bash
# BSD `date`, just enough of it: `-d` does not exist, and `-r` takes SECONDS SINCE EPOCH, not a path.
case "${1:-}" in
    -d) exit 1 ;;
    -r) _epoch="${2:-}"
        case "$_epoch" in ''|*[!0-9]*) exit 1 ;; esac
        shift 2
        exec /bin/date -u -d "@$_epoch" "$@" ;;
esac
exit 1
SH
chmod +x "$BSDBIN/date"
R="$(newroot s15)"
printf 'a pass\n' > "$R/agent/state/orchestrator-heartbeat.log"
printf '[{"lane":"a","degraded":false}]\n' > "$R/agent/state/lane-status.last.json"
OUT="$(PATH="$BSDBIN:$PATH" HEARTBEAT_PI_AGENT_DIR="$R/agent" bash "$LAUNCH" status 2>&1)"
# ⛔ NO `assert_eq "$RC" "0"` ROW HERE (review round 3, rule-3). `cmd_status` ends `return 0`
# unconditionally — it is the INFORMATIONAL verb, and the table in docs/ops/heartbeat-launch-path.md
# says so — so an exit-code row could not be varied by any mutation of this diff. An arm nothing can
# redden reads as coverage and is dead weight; the two rows below are the live ones (they carry the
# GNU-only `date -r <path>` defect this section exists for).
assert_not_contains "$OUT" "<unreadable>" '§15 …and both timestamps are READABLE (no GNU-only date -r <path>)'
assert_contains "$OUT" "last pass: 20" "§15 …the last-pass line carries a real ISO timestamp"

echo ""
echo '── 16. start LAUNCHES on a box with no working setsid (macOS) ──'

# ⛔ THE P0 THIS ARM PINS (#1867 review). macOS ships no `setsid` binary — `check-portability-traps.sh`
# says so twice (the rule and its detector arm), VENDOR.md says so, and the loop's own detach never
# used one — so `start`, the ONE documented launch path, could not start the loop on the ONLY
# platform this file exists for: `nohup: failed to run command 'setsid': No such file or
# directory`, 5 s of waiting, `DRIFT`. Measured by the reviewer on a PATH without setsid (rc=1) with
# the same args and setsid present as the control (rc=0).
#
# A `setsid` that FAILS is how this Linux host emulates macOS's absent one: it is deterministic here
# and indistinguishable to the caller (`nohup` reports the same failure). Nothing else on PATH is
# shimmed, so a fix that works here is a fix on the Mac — and `( … ) &` plus `LOOP_DETACHED=1` is the
# portable detach the portability rule names.
#
# The stand-in loop is the launcher's whole contract: it leaves the pidfile the launcher verifies.
# (The real loop would run a fleet pass; `kill -0` is all this launcher asks of a pid.)
R="$(newroot s16)"
mkdir -p "$R/agent/scripts"
cat > "$R/agent/scripts/heartbeat-loop.sh" <<'SH'
#!/usr/bin/env bash
mkdir -p "$HEARTBEAT_PI_AGENT_DIR/state"
printf '%s\n' "$$" > "$HEARTBEAT_PI_AGENT_DIR/state/heartbeat-loop.pid"
exec sleep 60
SH
chmod +x "$R/agent/scripts/heartbeat-loop.sh"
NOSETSID="$T/nosetsid-bin"; mkdir -p "$NOSETSID"
printf '#!/usr/bin/env bash\n# a FAILING setsid is macOS having no setsid binary at all\nexit 127\n' > "$NOSETSID/setsid"
chmod +x "$NOSETSID/setsid"
# ⛔ OUTPUT GOES TO A FILE, NOT `$( … )`. Measured on this box: capturing the launcher's output in a
# command substitution reaped the detached child within 200 ms (foreground and `bash -c` captures keep
# it), so a `$( )` here would test the CAPTURE's lifecycle rather than the launcher's detach — and it
# would report the child dead on a fixed script. The documented operator invocation is foreground.
S16_OUT="$T/s16-start.out"
PATH="$NOSETSID:$PATH" HEARTBEAT_PI_AGENT_DIR="$R/agent" bash "$LAUNCH" start >"$S16_OUT" 2>&1; RC=$?
OUT="$(cat "$S16_OUT" 2>/dev/null || true)"
assert_eq "$RC" "0" "§16 start SUCCEEDS with no setsid on the box (the macOS launch path)"
assert_contains "$OUT" "heartbeat loop started (pid" "§16 …and reports the pid it verified"
SP="$(tr -dc '0-9' < "$R/agent/state/heartbeat-loop.pid" 2>/dev/null)"
if [ -n "$SP" ] && kill -0 "$SP" 2>/dev/null; then
    ok "§16 …and the pid in the pidfile is ALIVE (the artefact, not the exit code)"
    printf '%s\n' "$SP" >> "$T/livepids"
else
    bad "§16 …and the pid in the pidfile is ALIVE (got: ${SP:-none})"
fi
kill "$SP" 2>/dev/null || true
# The dry run must print the SAME command the real one runs — a dry run that prints a `setsid` line
# is a launcher that tells an operator to run the thing that fails on their machine.
R="$(newroot s16b)"
OUT="$(env HEARTBEAT_PI_AGENT_DIR="$R/agent" bash "$LAUNCH" start --dry-run 2>&1)"; RC=$?
assert_eq "$RC" "0" "§16b start --dry-run exits 0"
assert_not_contains "$OUT" "setsid" "§16b …and prints NO setsid — the printed command is the one that runs"
assert_contains "$OUT" "LOOP_DETACHED=1 nohup bash" "§16b …it prints the portable detach instead"

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "✅ heartbeat-launch suite passed ($PASS assertions)"
    exit 0
fi
echo "❌ heartbeat-launch suite FAILED ($FAIL of $((PASS + FAIL)) assertions)"
exit 1
