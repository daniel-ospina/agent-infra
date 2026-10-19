#!/usr/bin/env bash
# lane-reap.test.sh — hermetic self-check for lane-reap.sh + lane-exec.sh (#2163).
#
# WHY THIS SUITE EXISTS (the acceptance this pins)
# The reaper SIGNALS PROCESSES, so a green suite that only proves "it runs" is worthless. Every leg
# below exists to prove one way it could kill something it must not, or fail to kill what it must:
#
#   LIVE       a lane whose log advanced inside the window is NEVER signalled — even with --apply
#   FINISHED   a parked lane whose log has been untouched past 2h IS signalled, children first
#   NO-LOG     a lane whose log cannot be resolved at all is REFUSED (the measured trap: "no log
#              found" must never read as "stale"; that almost killed a 7-minute-old lane)
#   DELETED    a resolved-but-deleted log is judged by the 12h age bound only: young SKIP, old REAP
#   HUMAN      a human terminal/ssh ancestor is a hard refusal, however parked the lane looks
#   ACTIVE     a subtree that gains any CPU across the window is never a candidate
#   COUNT      `lanes=<live>/<total> zombie=<n>` counts by evidence, not by a `ps | grep` string
#   UNREADABLE an unreadable process table is `lanes=?/?` / exit 3 — never "empty fleet"
#   EXEC       lane-exec.sh EXECs pi: the launcher's pid IS the agent's pid (no wrapper survives)
#
# Hermetic by construction: fake `ps`/`sleep`/`kill` shims, a fake /proc root (fd symlinks), temp
# log/state dirs, a pinned clock. No real process is ever signalled and no real lane is read.
#
# Run: bash scripts/orchestrator-harness/lane-reap.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAPER="$HERE/lane-reap.sh"
EXEC="$HERE/lane-exec.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ✅ %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "$1"; }
eq()   { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: $1, want: $2)"; fi; }
has()  { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 (missing: $2)" ;; esac; }
hasnt(){ case "$1" in *"$2"*) bad "$3 (unexpected: $2)" ;; *) ok "$3" ;; esac; }

T="$(mktemp -d "${TMPDIR:-/tmp}/lane-reap-test.XXXXXX")"
cleanup() { rm -rf "$T"; }
trap cleanup EXIT
mkdir -p "$T/bin" "$T/proc" "$T/state" "$T/logs"

NOW=1790000000                     # pinned clock (2026-09-20-ish); the suite never reads the real one
PROC="$T/proc"
KILL_LOG="$T/kill.log"

# ── the shims ─────────────────────────────────────────────────────────────────────────────────────
# `ps` answers TWO shapes: the whole table (`-A …`) and one pid's `lstart` (the identity fence when
# /proc is fake). The table is swapped on the SECOND `-A` read so a leg can model CPU progress.
cat > "$T/bin/ps" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" -o lstart= "*)
    # A TERM'd pid is GONE: model death so the escalation path can be told apart from the fence.
    pid=""; prev=""
    for a in "$@"; do [ "$prev" = "-p" ] && pid="$a"; prev="$a"; done
    if [ -n "${DEAD_PIDS:-}" ] && [ -f "$DEAD_PIDS" ] && grep -qx "$pid" "$DEAD_PIDS" 2>/dev/null; then
      exit 0
    fi
    # FENCE leg: once the switch exists, the pid reports a DIFFERENT incarnation.
    if [ -n "${LSTART_SWITCH:-}" ] && [ -f "$LSTART_SWITCH" ]; then
      printf 'Tue Oct 20 11:00:00 2026\n'; exit 0
    fi
    printf 'Mon Oct 19 10:00:00 2026\n'; exit 0 ;;
esac
case " $* " in
  *" -A "*) ;;
  *) exit 1 ;;
esac
[ "${PS_UNREADABLE:-0}" = "1" ] && { exit 0; }
n=0
[ -f "${PS_COUNTER:-/nonexistent}" ] && n="$(cat "$PS_COUNTER" 2>/dev/null)"
case "$n" in ''|*[!0-9]*) n=0 ;; esac
n=$((n + 1)); printf '%s\n' "$n" > "${PS_COUNTER:-/dev/null}" 2>/dev/null || true
if [ "$n" -ge 2 ] && [ -n "${PS_TABLE2:-}" ] && [ -f "${PS_TABLE2}" ]; then
  cat "$PS_TABLE2"
else
  cat "${PS_TABLE1:?PS_TABLE1 not set}"
fi
SH
chmod +x "$T/bin/ps"

cat > "$T/bin/sleep" <<'SH'
#!/usr/bin/env bash
# The window is the only moment between pass 1 (identity recorded) and the kill loop, so it is where
# the FENCE leg flips the pid's reported incarnation.
[ -n "${LSTART_SWITCH:-}" ] && { : > "$LSTART_SWITCH"; }
exit 0
SH
chmod +x "$T/bin/sleep"

cat > "$T/bin/kill" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${KILL_LOG:?KILL_LOG not set}"
# `-TERM <pid>` kills it unless the leg is modelling a SIGTERM-immune survivor.
if [ "${1:-}" = "-TERM" ] && [ "${KILL_NO_DEATH:-0}" != "1" ] && [ -n "${DEAD_PIDS:-}" ]; then
  printf '%s\n' "${2:-}" >> "$DEAD_PIDS" 2>/dev/null || true
fi
exit 0
SH
chmod +x "$T/bin/kill"

# A fake `pi` for the EXEC leg: it records the pid that runs it, so the suite can prove the launcher
# replaced itself instead of forking a wrapper around it.
cat > "$T/bin/pi" <<'SH'
#!/usr/bin/env bash
printf 'pid=%s\n' "$$" > "${PI_STUB_OUT:?PI_STUB_OUT not set}"
printf 'args=%s\n' "$*" >> "${PI_STUB_OUT:?}"
# last argument, bash 3.2-safe (no ${@: -1})
last=""; for a in "$@"; do last="$a"; done
printf 'prompt=%s\n' "$last" >> "${PI_STUB_OUT:?}"
exit 0
SH
chmod +x "$T/bin/pi"

psrow() { printf '%7s %7s %4s %8s %10s %s\n' "$1" "$2" "${3:-S}" "${4:-00:00:00}" "${5:-01:00:00}" "$6"; }
psinit() { psrow 1 0 Ss 00:00:00 10:00:00 /sbin/init; }

# set_mtime <file> <epoch>
set_mtime() {
  python3 - "$1" "$2" <<'PY'
import os, sys
os.utime(sys.argv[1], (int(sys.argv[2]), int(sys.argv[2])))
PY
}
# fdlink <pid> <fd> <target>
fdlink() { mkdir -p "$PROC/$1/fd"; rm -f "$PROC/$1/fd/$2"; ln -s "$3" "$PROC/$1/fd/$2"; }
# newlog <name> <age_seconds> — create a log and backdate it
newlog() {
  local f="$T/logs/$1"
  : > "$f"
  set_mtime "$f" "$((NOW - $2))"
  printf '%s' "$f"
}

# run_reap <table1> [table2] -- <args…>
run_reap() {
  local t1="$1" t2="${2:-}"; shift 2 2>/dev/null || shift
  [ "${1:-}" = "--" ] && shift
  rm -f "$T/ps.counter" "$KILL_LOG" "$T/dead.pids"
  PS_TABLE1="$t1" PS_TABLE2="$t2" PS_COUNTER="$T/ps.counter" KILL_LOG="$KILL_LOG" \
  DEAD_PIDS="$T/dead.pids" \
  PATH="$T/bin:$PATH" \
  LANE_REAP_PS_BIN="$T/bin/ps" LANE_REAP_PROC_ROOT="$PROC" LANE_REAP_NOW="$NOW" \
  LANE_REAP_WINDOW=2 LANE_REAP_SLEEP_BIN="$T/bin/sleep" LANE_REAP_KILL_BIN="$T/bin/kill" \
  LANE_REAP_LOG="$T/state/lane-reap.log" LANE_REAP_LOCK="$T/state/lane-reap" \
  bash "$REAPER" reap "$@"
}
run_count() { # <table>
  rm -f "$T/ps.counter" "$KILL_LOG"
  PS_TABLE1="$1" PS_COUNTER="$T/ps.counter" KILL_LOG="$KILL_LOG" \
  PATH="$T/bin:$PATH" \
  LANE_REAP_PS_BIN="$T/bin/ps" LANE_REAP_PROC_ROOT="$PROC" LANE_REAP_NOW="$NOW" \
  LANE_REAP_LOG="$T/state/lane-reap.log" LANE_REAP_LOCK="$T/state/lane-reap" \
  bash "$REAPER" count
}

# ── EXEC: lane-exec replaces itself ──────────────────────────────────────────────────────────────
echo "== EXEC (lane-exec.sh execs pi; no wrapper survives)"
# One helper, so the legs below are plain lines: the hub-state guard's script classifier mis-reads
# a nested-quote `$( … )` continued across lines (a false positive on a read-only test), and there
# is nothing to prove by keeping that shape.
run_exec() { # <stub-out> <log> <prompt>
  PATH="$T/bin:$PATH" PI_STUB_OUT="$1" bash "$EXEC" --log "$2" --prompt "$3"
}
run_exec "$T/pi.out" "$T/logs/exec.log" "hello prompt" >/dev/null 2>&1
rc=$?
eq "$rc" "0" "lane-exec exits with pi's status"
# The launcher must have the SAME pid as the agent. Run it as a child so we can compare with `$!`.
# ⛔ The launch is a DIRECT command, not the helper: backgrounding a shell FUNCTION forks a subshell,
# so `$!` would be the subshell — one pid above the `exec`'d agent — and the assertion would fail for
# the test's own reason rather than the launcher's.
PATH="$T/bin:$PATH" PI_STUB_OUT="$T/pi2.out" bash "$EXEC" --log "$T/logs/exec2.log" --prompt "inline prompt" >/dev/null 2>&1 &
launcher_pid=$!
wait "$launcher_pid"
agent_pid="$(sed -n 's/^pid=//p' "$T/pi2.out" | head -1)"
eq "$agent_pid" "$launcher_pid" "the launcher's pid IS the agent's pid (exec, not a fork)"
if kill -0 "$launcher_pid" 2>/dev/null; then bad "no process remains after the turn"; else ok "no process remains after the turn"; fi
has "$(cat "$T/pi.out")" "args=-p --provider deepseek --model deepseek-v4-flash --no-session hello prompt" \
  "the canonical headless invocation is passed through"
has "$(cat "$T/logs/exec.log")" "[lane-exec]" "the log carries the launcher's own first line"
has "$(sed -n 's/^prompt=//p' "$T/pi.out")" "hello prompt" "the inline prompt is passed verbatim"
hasnt "$(sed -n 's/^args=//p' "$T/pi.out")" "--no-session --no-session" "extra args are appended, never duplicated"

# ── LIVE: a working lane is never reaped ────────────────────────────────────────────────────────
echo "== LIVE (a lane whose log advanced is never a candidate)"
LIVE_LOG="$(newlog L-live.log 60)"
: > "$T/t-live"; psinit >> "$T/t-live"
psrow 500 1 Ss 00:00:00 01:00:00 "bash -c cd /repo; pi -p \"\$(cat brief)\" > $LIVE_LOG 2>&1 &" >> "$T/t-live"
psrow 501 500 Sl 00:00:05 01:00:00 pi >> "$T/t-live"
fdlink 501 1 "$LIVE_LOG"; fdlink 501 2 "$LIVE_LOG"
out="$(run_reap "$T/t-live" "" -- --dry-run)"; rc=$?
eq "$rc" "0" "LIVE: pass exits 0"
has "$out" "log advanced" "LIVE: reported as log-advanced"
hasnt "$out" "WOULD REAP" "LIVE: never a candidate"
out="$(run_reap "$T/t-live" "" -- --apply)"
eq "$(cat "$KILL_LOG" 2>/dev/null | wc -l | tr -d ' ')" "0" "LIVE: --apply signals NOTHING"

# ── FINISHED: a stale, parked lane is reaped, children first ────────────────────────────────────
echo "== FINISHED (stale log + zero CPU + no human => reaped)"
DEAD_LOG="$(newlog L-dead.log $((3 * 3600)))"
: > "$T/t-dead"; psinit >> "$T/t-dead"
psrow 600 1 Ss 00:00:00 05:00:00 "bash -c cd /repo; pi -p \"\$(cat brief)\" > $DEAD_LOG 2>&1 &" >> "$T/t-dead"
psrow 601 600 Sl 00:00:05 05:00:00 pi >> "$T/t-dead"
fdlink 601 1 "$DEAD_LOG"; fdlink 601 2 "$DEAD_LOG"
out="$(run_reap "$T/t-dead" "" -- --dry-run)"
has "$out" "WOULD REAP root=600" "FINISHED: dry run names the lane (the wrapper root)"
has "$out" "log-idle" "FINISHED: the reason is the log's own idle age"
eq "$(cat "$KILL_LOG" 2>/dev/null | wc -l | tr -d ' ')" "0" "FINISHED: dry run signals nothing"
out="$(run_reap "$T/t-dead" "" -- --apply)"
eq "$(sed -n '1p' "$KILL_LOG")" "-TERM 601" "FINISHED: the CHILD is signalled first"
eq "$(sed -n '2p' "$KILL_LOG")" "-TERM 600" "FINISHED: the wrapper root is signalled second"
hasnt "$(cat "$KILL_LOG")" "-KILL" "FINISHED: both die on TERM (no escalation needed)"

# ── COMPOSITION: a tree that changed shape during the window is doing something ────────────────
echo "== COMPOSITION (a subtree that gained a child is not a freeze)"
: > "$T/t-c1"; psinit >> "$T/t-c1"
psrow 500 1 Ss 00:00:00 05:00:00 "bash -c pi > $DEAD_LOG 2>&1 &" >> "$T/t-c1"
psrow 501 500 Sl 00:00:05 05:00:00 pi >> "$T/t-c1"
fdlink 501 1 "$DEAD_LOG"
: > "$T/t-c2"; psinit >> "$T/t-c2"
psrow 500 1 Ss 00:00:00 05:00:00 "bash -c pi > $DEAD_LOG 2>&1 &" >> "$T/t-c2"
psrow 501 500 Sl 00:00:05 05:00:00 pi >> "$T/t-c2"
psrow 502 501 Sl 00:00:01 00:10:00 "bash -c claude-review" >> "$T/t-c2"
fdlink 501 1 "$DEAD_LOG"
out="$(run_reap "$T/t-c1" "$T/t-c2" -- --apply)"
has "$out" "subtree-changed" "COMPOSITION: the change is named"
hasnt "$out" "REAP   root=500" "COMPOSITION: never reaped"
eq "$(cat "$KILL_LOG" 2>/dev/null | wc -l | tr -d ' ')" "0" "COMPOSITION: no signal"

# ── FENCE: a pid whose incarnation changed between measurement and signal is not signalled ─────
echo "== FENCE (identity re-read at signal time)"
: > "$T/t-fence"; psinit >> "$T/t-fence"
psrow 500 1 Ss 00:00:00 05:00:00 "bash -c pi > $DEAD_LOG 2>&1 &" >> "$T/t-fence"
psrow 501 500 Sl 00:00:05 05:00:00 pi >> "$T/t-fence"
fdlink 501 1 "$DEAD_LOG"
out="$(LSTART_SWITCH="$T/fence.switch" run_reap "$T/t-fence" "" -- --apply)"
has "$out" "FENCE-ABSTAIN" "FENCE: the changed incarnation is named"
hasnt "$out" "REAP   root=500" "FENCE: the candidate is not reported as reaped"
eq "$(cat "$KILL_LOG" 2>/dev/null | wc -l | tr -d ' ')" "0" "FENCE: no signal reaches a recycled pid"

# ── CAP: the `[cap]` fields, driven through the loop's own measure_lanes() ─────────────────────
echo "== CAP ([cap] prints lanes=<live>/<total> max_lanes=<n> zombie=<n>)"
LOOP="$HERE/orch-loop.sh"
grep -qF 'lanes=$LANES/$LANES_TOTAL' "$LOOP" && grep -qF 'zombie=$ZOMBIES' "$LOOP" && rc=0 || rc=1
eq "$rc" "0" "CAP: the [cap] line carries lanes=<live>/<total> and zombie=<n>"
is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
O="$T"; _HERE_RS=/nonexistent
printf '#!/bin/bash\necho "lanes=3/11 zombie=7"\n' > "$T/lane-reap.sh"
chmod +x "$T/lane-reap.sh"
LANE_REAP_SH=""
# The loop's own function, sourced from an extracted block rather than restated here: a copy would
# pass this leg while the shipped loop drifted.
sed -n '/^LANE_REAP_SH=""/,/^}$/p' "$LOOP" > "$T/measure.sh"
. "$T/measure.sh"
measure_lanes
eq "$LANES/$LANES_TOTAL/$ZOMBIES" "3/11/7" "CAP: live/total/zombie parsed from the census"
eq "$LANES_UNKNOWN" "0" "CAP: a clean census is not flagged unknown"
printf '#!/bin/bash\necho "lanes=?/11 zombie=7"; exit 3\n' > "$T/lane-reap.sh"
measure_lanes
eq "$LANES_UNKNOWN" "1" "CAP: an unreadable numerator REFUSES work (no silent fail-open)"
eq "$LANES_TOTAL/$ZOMBIES" "11/7" "CAP: readable totals are still reported"
printf '#!/bin/bash\necho "lanes=?/? zombie=?"; exit 3\n' > "$T/lane-reap.sh"
measure_lanes
eq "$LANES_UNKNOWN" "1" "CAP: a wholly unreadable census refuses work"
eq "$LANES_TOTAL/$ZOMBIES" "?/?" "CAP: unknown totals stay unknown, never 0"

# ── SURVIVOR: a SIGTERM-immune victim is escalated, but only while its incarnation holds ────────
echo "== SURVIVOR (TERM followed by KILL, still fenced on the same incarnation)"
out="$(KILL_NO_DEATH=1 run_reap "$T/t-dead" "" -- --apply)"
eq "$(grep -c -- '-KILL 601' "$KILL_LOG")" "1" "SURVIVOR: an unkilled child is escalated to KILL"
eq "$(grep -c -- '-KILL 600' "$KILL_LOG")" "1" "SURVIVOR: an unkilled wrapper is escalated to KILL"

# ── NO-LOG: an unresolvable log is never evidence of staleness ──────────────────────────────────
echo "== NO-LOG (the measured trap: absent evidence must fail closed)"
: > "$T/t-nolog"; psinit >> "$T/t-nolog"
psrow 700 1 Ss 00:00:00 30:00:00 "bash -c cd /repo; pi -p \"\$(cat ciwatch\\012[ brief)\" > /tmp/x 2>&1 &" >> "$T/t-nolog"
psrow 701 700 Sl 00:00:00 30:00:00 pi >> "$T/t-nolog"
fdlink 701 1 "pipe:[4242]"; fdlink 701 2 "socket:[4243]"
out="$(run_reap "$T/t-nolog" "" -- --apply)"
has "$out" "no-log-evidence" "NO-LOG: reported as no-log-evidence"
hasnt "$out" "WOULD REAP" "NO-LOG: not a candidate"
hasnt "$out" "REAP   root=700" "NO-LOG: never reaped"
eq "$(cat "$KILL_LOG" 2>/dev/null | wc -l | tr -d ' ')" "0" "NO-LOG: --apply signals nothing"

# ── DELETED: a resolved-but-deleted log is judged by the 12h bound only ─────────────────────────
echo "== DELETED (no-log needs the 12h age bound; young lanes are spared)"
: > "$T/t-del"; psinit >> "$T/t-del"
psrow 800 1 Ss 00:00:00 01:00:00 "bash launch-lane.sh /tmp/wt /tmp/brief > /tmp/L-old.log 2>&1" >> "$T/t-del"
psrow 801 800 Sl 00:00:00 01:00:00 pi >> "$T/t-del"
fdlink 801 1 "/tmp/L-old.log (deleted)"
out="$(run_reap "$T/t-del" "" -- --dry-run)"
has "$out" "under 12h" "DELETED: a 1h-old deleted-log lane is spared"
hasnt "$out" "WOULD REAP" "DELETED: young deleted-log lane is not a candidate"
: > "$T/t-del2"; psinit >> "$T/t-del2"
psrow 800 1 Ss 00:00:00 13:00:00 "bash launch-lane.sh /tmp/wt /tmp/brief > /tmp/L-old.log 2>&1" >> "$T/t-del2"
psrow 801 800 Sl 00:00:00 13:00:00 pi >> "$T/t-del2"
fdlink 801 1 "/tmp/L-old.log (deleted)"
out="$(run_reap "$T/t-del2" "" -- --dry-run)"
has "$out" "WOULD REAP root=800" "DELETED: a 13h-old deleted-log lane IS stale"

# ── HUMAN: the first recognised host application refuses the lane ───────────────────────────────
echo "== HUMAN (a human terminal/ssh ancestor is a hard refusal)"
: > "$T/t-human"; psinit >> "$T/t-human"
psrow 400 1 Ss 00:00:00 10:00:00 "/Applications/Terminal.app/Contents/MacOS/Terminal" >> "$T/t-human"
psrow 900 400 Ss 00:00:00 05:00:00 "bash -c cd /repo; pi -p x > $DEAD_LOG 2>&1 &" >> "$T/t-human"
psrow 901 900 Sl 00:00:00 05:00:00 pi >> "$T/t-human"
fdlink 901 1 "$DEAD_LOG"
out="$(run_reap "$T/t-human" "" -- --apply)"
has "$out" "human-ancestor" "HUMAN: refused with a reason"
hasnt "$out" "REAP   root=900" "HUMAN: never reaped"
eq "$(cat "$KILL_LOG" 2>/dev/null | wc -l | tr -d ' ')" "0" "HUMAN: --apply signals nothing"

# ── ACTIVE: any CPU gain across the window spares the lane ──────────────────────────────────────
echo "== ACTIVE (a subtree that gains CPU is working, not finished)"
: > "$T/t-act1"; psinit >> "$T/t-act1"
psrow 500 1 Ss 00:00:00 05:00:00 "bash -c cd /repo; pi -p x > $DEAD_LOG 2>&1 &" >> "$T/t-act1"
psrow 501 500 Sl 00:00:05 05:00:00 pi >> "$T/t-act1"
fdlink 501 1 "$DEAD_LOG"
: > "$T/t-act2"; psinit >> "$T/t-act2"
psrow 500 1 Ss 00:00:00 05:00:00 "bash -c cd /repo; pi -p x > $DEAD_LOG 2>&1 &" >> "$T/t-act2"
psrow 501 500 Rl 00:00:09 05:00:00 pi >> "$T/t-act2"     # +0.04s: above the 0.01s test tolerance
out="$(LANE_REAP_CPU_TOL_CS=0 run_reap "$T/t-act1" "$T/t-act2" -- --apply)"
has "$out" "still working" "ACTIVE: spared while the subtree gains CPU"
hasnt "$out" "REAP   root=500" "ACTIVE: never reaped"
eq "$(cat "$KILL_LOG" 2>/dev/null | wc -l | tr -d ' ')" "0" "ACTIVE: no signal"

# ── COUNT: evidence, not a string ───────────────────────────────────────────────────────────────
echo "== COUNT (lanes=<live>/<total>, zombie=<n>)"
FRESH="$(newlog L-fresh.log 30)"
OLD="$(newlog L-stale.log $((6 * 3600)))"
: > "$T/t-count"; psinit >> "$T/t-count"
psrow 500 1 Ss 00:00:00 05:00:00 "bash -c pi > $FRESH 2>&1" >> "$T/t-count"
psrow 501 500 Sl 00:00:01 05:00:00 pi >> "$T/t-count"
fdlink 501 1 "$FRESH"
psrow 600 1 Ss 00:00:00 05:00:00 "bash -c pi > $OLD 2>&1" >> "$T/t-count"
psrow 601 600 Sl 00:00:01 05:00:00 pi >> "$T/t-count"
fdlink 601 1 "$OLD"
psrow 800 1 Ss 00:00:00 05:00:00 "bash -c pi > /dev/null 2>&1" >> "$T/t-count"
psrow 801 800 Sl 00:00:01 05:00:00 pi >> "$T/t-count"
fdlink 801 1 "pipe:[77]"
psrow 900 1 Z 00:00:00 05:00:00 "[pi] <defunct>" >> "$T/t-count"
psrow 901 1 Z 00:00:00 05:00:00 "[bash] <defunct>" >> "$T/t-count"
out="$(run_count "$T/t-count")"
eq "$out" "lanes=1/2 zombie=2" "COUNT: one live of two resident lanes; two zombies"

# ── BUDGET: a spent pass budget is an ABSTENTION, never a partial census ───────────────────────
echo "== BUDGET (a pass that runs out of time judges nothing and says so)"
out="$(LANE_REAP_PASS_TIMEOUT=0 run_count "$T/t-count")"; rc=$?
eq "$rc" "3" "BUDGET: count exits 3"
eq "$out" "lanes=?/? zombie=?" "BUDGET: a partial census is never printed as a number"
out="$(LANE_REAP_PASS_TIMEOUT=0 run_reap "$T/t-count" "" -- --apply)"; rc=$?
eq "$rc" "3" "BUDGET: reap exits 3"
has "$out" "CANNOT-VERIFY" "BUDGET: reap says the budget was spent"
eq "$(cat "$KILL_LOG" 2>/dev/null | wc -l | tr -d ' ')" "0" "BUDGET: nothing is signalled"

# ── UNREADABLE: cannot-verify is not an empty fleet ────────────────────────────────────────────
echo "== UNREADABLE (a failed ps read never renders as 0 lanes)"
rm -f "$T/ps.counter"
out="$(PS_UNREADABLE=1 PS_TABLE1="$T/t-count" PS_COUNTER="$T/ps.counter" PATH="$T/bin:$PATH" \
       LANE_REAP_PS_BIN="$T/bin/ps" LANE_REAP_PROC_ROOT="$PROC" LANE_REAP_NOW="$NOW" \
       LANE_REAP_LOG="$T/state/lane-reap.log" LANE_REAP_LOCK="$T/state/lane-reap" \
       bash "$REAPER" count)"; rc=$?
eq "$rc" "3" "UNREADABLE: count exits 3"
eq "$out" "lanes=?/? zombie=?" "UNREADABLE: counts render as unknown, never as 0"
out="$(PS_UNREADABLE=1 KILL_LOG="$KILL_LOG" PS_TABLE1="$T/t-count" PS_COUNTER="$T/ps.counter" \
       PATH="$T/bin:$PATH" LANE_REAP_PS_BIN="$T/bin/ps" LANE_REAP_PROC_ROOT="$PROC" \
       LANE_REAP_NOW="$NOW" LANE_REAP_WINDOW=1 LANE_REAP_SLEEP_BIN="$T/bin/sleep" \
       LANE_REAP_KILL_BIN="$T/bin/kill" LANE_REAP_LOG="$T/state/lane-reap.log" \
       LANE_REAP_LOCK="$T/state/lane-reap" bash "$REAPER" reap --apply)"; rc=$?
eq "$rc" "3" "UNREADABLE: reap exits 3"
has "$out" "CANNOT-VERIFY" "UNREADABLE: reap says so loudly"
eq "$(cat "$KILL_LOG" 2>/dev/null | wc -l | tr -d ' ')" "0" "UNREADABLE: signals nothing"

echo
printf 'lane-reap.test: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
