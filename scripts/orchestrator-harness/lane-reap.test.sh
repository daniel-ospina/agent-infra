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
#   HUMAN-WIDENED  every terminal a lane can really have (wezterm/gnome-terminal/konsole/xterm/
#              ghostty/foot/code-server) refuses as HUMAN, not as `unknown`; and a MULTIPLEXER is not
#              a human (SURFACE-TMUX): tmux is the fleet's OWN macOS launcher, so the walk must go
#              THROUGH the server — to the human terminal above it, or to `unknown`
#   HUMAN-UNKNOWN  an ancestry that is NEITHER fleet nor a known human REFUSES (`unknown` permitted
#              the kill); ANCESTRY-INCOMPLETE refuses a truncated ppid walk the same way
#   EVIDENCE-SIBLING  a SIBLING's log never judges this lane (measured: the live pi was TERMed on a
#              backgrounded writer's 3 h-old file); EVIDENCE-AMBIGUOUS refuses two lane logs;
#              EVIDENCE-TEE keeps the shipped `pi | tee L-x.log` shape; EVIDENCE-TEE-ALIEN refuses a
#              tee fed by ANOTHER pipe; EVIDENCE-BLIND separates an UNREADABLE descriptor from
#              "not a lane"
#   EVIDENCE-TEE-LSOF  the same tee shape on the lsof branch (macOS's ONLY branch): a per-pipe NAME
#              (`->0x…`, `pipe:[N]`) that both sides reproduce identifies the writer, a DIFFERENT
#              address does not (…-LSOF-ALIEN), and a GENERIC spelling (`pipe`, `->0x0` — measured
#              from lsof 4.95) is not an identity at all, so the tree ABSTAINS instead of borrowing
#              another pipe's file (…-LSOF-GENERIC)
#   ACTIVE     a subtree that gains any CPU across the window is never a candidate
#   COUNT      `lanes=<live>/<total> zombie=<n>` counts by evidence, not by a `ps | grep` string
#   COUNT-NO-EVIDENCE  a census that cannot read ANY descriptor is `?/?` (never a confident 0/0 that
#              licenses more dispatch), while a readable tree holding no fleet log is a real 0
#   ABSTAINED  a pass that could judge nothing COUNTS it (`abstained=`) and exits 3
#   INERT      a pass that judged NO tree while refusing lanes by POLICY exits 4 (a POLICY verdict,
#              kept apart from rc 3 = cannot-verify) and carries `inert=` — the cell shape, where an
#              inert reaper used to record itself as healthy and then, once escalated, reddened the
#              cell's health verb for ever
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

REAL_SLEEP="$(command -v sleep)"
export REAL_SLEEP
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
# ── the FENCE's window: the switch is armed ONLY by the window sleep ─────────────────────────────
# ⛔ A READ BOUND IS NOT THE WINDOW (#2163 review, P2). This used to arm the incarnation switch on
# ANY `sleep` invocation. On macOS there is no `timeout(1)`, so `bound()` runs its watchdog as a
# REAL `sleep 60` — which armed the switch during the FIRST process read, before any identity was
# recorded, so pass 1 already saw the post-switch incarnation and the leg could never pass (three
# red assertions locally, green on Linux, where `timeout` owns the read bound). Arming it in the
# window arm alone makes the leg deterministic on both platforms.
# ⛔ THE WINDOW AND A READ BOUND ARE NOT THE SAME SLEEP. The window (2s) is stubbed so the suite is
# fast; a READ BOUND must sleep for real, or `bound()`'s watchdog fires the moment it is scheduled and
# kills the read it was protecting — a race that made the FALLBACK leg green or red by timing.
case "${1:-}" in
  2) [ -n "${LSTART_SWITCH:-}" ] && : > "$LSTART_SWITCH"; exit 0 ;;
  *) exec "${REAL_SLEEP:?}" "$@" ;;
esac
SH
chmod +x "$T/bin/sleep"

# A fake `lsof` for the macOS-SHAPE deleted-log leg: an unlinked-but-held descriptor resolves to
# its OLD path with NO " (deleted)" suffix (measured on 26.6.2). The reaper must still recognise the
# file is gone from the kernel evidence alone, not from lsof's spelling.
cat > "$T/bin/lsof" <<'SH'
#!/usr/bin/env bash
[ -n "${LSOF_PATH:-}" ] && printf 'n%s\n' "$LSOF_PATH"
exit 0
SH
chmod +x "$T/bin/lsof"

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
# ⛔ EVERY LANE FIXTURE HANGS OFF THE FLEET BOUNDARY (#2163 review, P1/P2). Gate 2 now requires
# POSITIVE fleet evidence — `unknown` REFUSES, because it used to permit and every host app outside
# the marker set (and every truncated process table) then sent TERM to a live tree. A lane's real
# ancestry is `pi → -zsh → login → cmux.app`, so the shared fixture carries a cmux.app at pid 400 and
# the lane roots below are its children. A HUMAN leg overrides pid 400 with its own terminal row.
psinit() { psrow 1 0 Ss 00:00:00 10:00:00 /sbin/init; psrow 400 1 Ss 00:00:00 10:00:00 "/Applications/cmux.app/Contents/MacOS/cmux"; }

# set_mtime <file> <epoch>
set_mtime() {
  python3 - "$1" "$2" <<'PY'
import os, sys
os.utime(sys.argv[1], (int(sys.argv[2]), int(sys.argv[2])))
PY
}
# fdlink <pid> <fd> <target>
# ⛔ A LEG'S DESCRIPTOR SET IS EXACTLY WHAT IT LINKS (#2163 review, P2). The fake /proc is shared by
# every leg, so a leg that added fd 2 while an earlier one had left fd 2 behind gave ONE `pi` two
# DIFFERENT lane logs — and the reaper then (correctly) reported `ambiguous-log-evidence` instead of
# judging the lane. Linking fd 1 first resets the directory, so each fixture describes its own fds.
fdlink() {
  if [ "${2:-}" = "1" ]; then rm -rf "$PROC/$1/fd"; fi
  mkdir -p "$PROC/$1/fd"; rm -f "$PROC/$1/fd/$2"; ln -s "$3" "$PROC/$1/fd/$2"
}
# newlog <name> <age_seconds> — create a log and backdate it
newlog() {
  local f="$T/logs/$1"
  : > "$f"
  set_mtime "$f" "$((NOW - $2))"
  printf '%s' "$f"
}

# run_reap <table1> [table2] -- <args…>
# REAP_PROC_ROOT_OVERRIDE — set to "" to exercise the lsof branch (macOS shape) on a fixture that
# has no fake /proc; every other leg keeps the /proc root, so this seam changes nothing for them.
run_reap() {
  local t1="$1" t2="${2:-}"; shift 2 2>/dev/null || shift
  [ "${1:-}" = "--" ] && shift
  rm -f "$T/ps.counter" "$KILL_LOG" "$T/dead.pids"
  PS_TABLE1="$t1" PS_TABLE2="$t2" PS_COUNTER="$T/ps.counter" KILL_LOG="$KILL_LOG" \
  DEAD_PIDS="$T/dead.pids" \
  PATH="$T/bin:$PATH" \
  LANE_REAP_PS_BIN="$T/bin/ps" LANE_REAP_PROC_ROOT="${REAP_PROC_ROOT_OVERRIDE-$PROC}" \
  LANE_REAP_LSOF_BIN="${REAP_LSOF_OVERRIDE-lsof}" LANE_REAP_NOW="$NOW" \
  LANE_REAP_WINDOW=2 LANE_REAP_SLEEP_BIN="$T/bin/sleep" LANE_REAP_KILL_BIN="$T/bin/kill" \
  LANE_REAP_LOG="$T/state/lane-reap.log" LANE_REAP_LOCK="$T/state/lane-reap" \
  bash "$REAPER" reap "$@"
}
run_count() { # <table>
  rm -f "$T/ps.counter" "$KILL_LOG"
  PS_TABLE1="$1" PS_COUNTER="$T/ps.counter" KILL_LOG="$KILL_LOG" \
  PATH="$T/bin:$PATH" \
  LANE_REAP_PS_BIN="$T/bin/ps" LANE_REAP_PROC_ROOT="${REAP_PROC_ROOT_OVERRIDE-$PROC}" \
  LANE_REAP_LSOF_BIN="${REAP_LSOF_OVERRIDE-lsof}" LANE_REAP_NOW="$NOW" \
  LANE_REAP_LOG="$T/state/lane-reap.log" LANE_REAP_LOCK="$T/state/lane-reap" \
  bash "$REAPER" count
}

# ── EXEC: lane-exec replaces itself ──────────────────────────────────────────────────────────────
echo "== EXEC (lane-exec.sh execs pi; no wrapper survives)"
# One helper, so the legs below are plain lines: the hub-state guard's script classifier mis-reads
# a nested-quote `$( … )` continued across lines (a false positive on a read-only test), and there
# is nothing to prove by keeping that shape.
run_exec() { # <stub-out> <log> <prompt>
  PATH="$T/bin:$PATH" PI_STUB_OUT="$1" PI_LANE_MODEL="" PI_LANE_PROVIDER="" bash "$EXEC" --log "$2" --prompt "$3"
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
has "$(cat "$T/pi.out")" "args=-p --provider deepseek --model deepseek-flash --no-session hello prompt" \
  "the canonical headless invocation is passed through, with the fleet's RESOLVED default model"
# ⛔ THE RESOLVED PAIR IS NAMED IN THE LOG (#2208): a lane must not run a different model than its
# reviewer, and an ambient override must be visible in the artifact rather than only in the argv.
has "$(cat "$T/logs/exec.log")" "[agent] provider=deepseek model=deepseek-flash" \
  "the log names the resolved provider/model before the exec"
# …and the resolution is REAL, not a new literal: an override reaches the argv (driven, not grepped).
PI_LANE_MODEL=deepseek-v4-pro PI_LANE_PROVIDER=deepseek PATH="$T/bin:$PATH" PI_STUB_OUT="$T/pi3.out" \
  bash "$EXEC" --log "$T/logs/exec3.log" --prompt "override prompt" >/dev/null 2>&1
has "$(cat "$T/pi3.out")" "--model deepseek-v4-pro" "a PI_LANE_MODEL override reaches pi's argv"
has "$(cat "$T/logs/exec3.log")" "[agent] provider=deepseek model=deepseek-v4-pro" \
  "…and the log names the overridden model, not the default"
has "$(cat "$T/logs/exec.log")" "[lane-exec]" "the log carries the launcher's own first line"
has "$(sed -n 's/^prompt=//p' "$T/pi.out")" "hello prompt" "the inline prompt is passed verbatim"
hasnt "$(sed -n 's/^args=//p' "$T/pi.out")" "--no-session --no-session" "extra args are appended, never duplicated"

# ── LIVE: a working lane is never reaped ────────────────────────────────────────────────────────
echo "== LIVE (a lane whose log advanced is never a candidate)"
LIVE_LOG="$(newlog L-live.log 60)"
: > "$T/t-live"; psinit >> "$T/t-live"
psrow 500 400 Ss 00:00:00 01:00:00 "bash -c cd /repo; pi -p \"\$(cat brief)\" > $LIVE_LOG 2>&1 &" >> "$T/t-live"
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
psrow 600 400 Ss 00:00:00 05:00:00 "bash -c cd /repo; pi -p \"\$(cat brief)\" > $DEAD_LOG 2>&1 &" >> "$T/t-dead"
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

# ── the shipped bound and its seam: LANE_IDLE_MIN = 180 min ────────────────────────────────────
# The registry pins the DECLARATION; this pins the BEHAVIOUR, because the number is what decides a
# kill. A 150-minute-idle log sits BETWEEN the 60 and 180 minute candidates, so the pair of legs
# below proves the shipped default is 3 h (not "any staleness") AND that the env seam still moves
# it — a default that silently became 60 would make the first leg reap a lane it must spare.
echo "== DEFAULT (LANE_IDLE_MIN is 3 h, and LANE_REAP_IDLE_MIN moves it)"
MID_LOG="$(newlog L-mid.log $((150 * 60)))"
: > "$T/t-mid"; psinit >> "$T/t-mid"
psrow 700 400 Ss 00:00:00 02:30:00 "bash -c cd /repo; pi -p \"\$(cat brief)\" > $MID_LOG 2>&1 &" >> "$T/t-mid"
psrow 701 700 Sl 00:00:05 02:30:00 pi >> "$T/t-mid"
fdlink 701 1 "$MID_LOG"; fdlink 701 2 "$MID_LOG"
out="$(run_reap "$T/t-mid" "" -- --dry-run)"
hasnt "$out" "WOULD REAP" "DEFAULT: a 150 m idle log is UNDER the shipped LANE_IDLE_MIN (3 h)"
# ⛔ `trees=<working>/<judged>` MUST ACCOUNT FOR EVERY JUDGED TREE (#2163 review, P3). `live` was
# incremented only for a CPU delta above the tolerance or a log younger than LIVE_MIN (125 m), so a
# lane idle BETWEEN the live window and the idle bound — **this one, at 150 m** — counted as neither
# working nor a candidate and the field under-reported the box. A judged tree is working unless it is
# a candidate.
# ⛔ AND THE FIXTURE HAS TO SIT IN THAT BAND TO PROVE IT (agent-infra#2888 review, F4): the interval
# is non-empty only while `LIVE_MIN (125) < LANE_IDLE_MIN (180)`. When the idle bound was 120 the band
# was EMPTY, and a 90-minute fixture was merely "live by log" — the arm passed without ever exercising
# the accounting it exists for, which is what made the overlap invisible.
has "$out" "trees=1/1" "DEFAULT: an idle-but-not-live-not-stale lane (150 m, between 125 and 180) is counted WORKING in trees=<working>/<judged>"
out="$(LANE_REAP_IDLE_MIN=60 run_reap "$T/t-mid" "" -- --dry-run)"
has "$out" "WOULD REAP root=700" "…and LANE_REAP_IDLE_MIN=60 makes the SAME lane a candidate (the seam is live)"

# ── COMPOSITION: a tree that changed shape during the window is doing something ────────────────
echo "== COMPOSITION (a subtree that gained a child is not a freeze)"
: > "$T/t-c1"; psinit >> "$T/t-c1"
psrow 500 400 Ss 00:00:00 05:00:00 "bash -c pi > $DEAD_LOG 2>&1 &" >> "$T/t-c1"
psrow 501 500 Sl 00:00:05 05:00:00 pi >> "$T/t-c1"
fdlink 501 1 "$DEAD_LOG"
: > "$T/t-c2"; psinit >> "$T/t-c2"
psrow 500 400 Ss 00:00:00 05:00:00 "bash -c pi > $DEAD_LOG 2>&1 &" >> "$T/t-c2"
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
psrow 500 400 Ss 00:00:00 05:00:00 "bash -c pi > $DEAD_LOG 2>&1 &" >> "$T/t-fence"
psrow 501 500 Sl 00:00:05 05:00:00 pi >> "$T/t-fence"
fdlink 501 1 "$DEAD_LOG"
out="$(LSTART_SWITCH="$T/fence.switch" run_reap "$T/t-fence" "" -- --apply)"
has "$out" "FENCE-ABSTAIN" "FENCE: the changed incarnation is named"
hasnt "$out" "REAP   root=500" "FENCE: the candidate is not reported as reaped"
eq "$(cat "$KILL_LOG" 2>/dev/null | wc -l | tr -d ' ')" "0" "FENCE: no signal reaches a recycled pid"

# ── CAP: the `[cap]` fields, driven through the loop's own measure_lanes() ─────────────────────
echo "== CAP ([cap] prints lanes=<live>/<total> max_lanes=<n> zombie=<n>)"
LOOP="$HERE/orch-loop.sh"
grep -qF 'lanes=${LANES_DISPLAY:-?}/$LANES_TOTAL' "$LOOP" && grep -qF 'zombie=$ZOMBIES' "$LOOP" && rc=0 || rc=1
eq "$rc" "0" "CAP: the [cap] line carries lanes=<live>/<total> and zombie=<n>"
grep -qF 'lanes_unknown (the lane census could not be read' "$LOOP" && rc=0 || rc=1
eq "$rc" "0" "CAP: the dispatch gate CONSUMES LANES_UNKNOWN (a tripwire: the arm is inline in the loop)"
grep -qF 'lanes_src=' "$LOOP" && grep -qF 'lanes=${LANES_DISPLAY:-?}/$LANES_TOTAL' "$LOOP" && rc=0 || rc=1
eq "$rc" "0" "CAP: [cap] names the census SOURCE, so a LAUNCHER count is never printed as a census"
is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
# ⛔ THE LAUNCH SURFACE'S OWN CENSUS IS A STUB, AND IT IS DISCRIMINATING (#2163 review r8, P1). The
# loop's fallback must be `wt_count lane-` (worker-terminal.sh: durable terminals AND tmux sessions,
# every launcher) and NOT `tmux ls | grep -c '^lane-'`: that sees ONE of the TWO launch surfaces, so
# where the cmux daemon ANSWERS (`wt_launcher` selects `terminal`) the tmux expression reads **0 on a
# busy box** and the capacity gate stops binding. (tmux IS the launcher where the daemon does not
# answer — on a launchd Mac AND on a cell, #2210 — so the defect is the single surface, not tmux.)
# The stub answers only for the `lane-` prefix, so a call with another argument (or none) reads 0 and
# fails the leg.
WT_COUNT_CALLS="$T/wt-count.calls"
: > "$WT_COUNT_CALLS"
# ⛔ THE ARGUMENT IS RECORDED IN A FILE, not a shell variable: `LANES="$(wt_count lane-)"` runs the
# stub in a command substitution, so an in-shell assignment would be lost and the leg would pass on an
# empty reading (the same defect class as the `=$( )` memo in worker-terminal.sh).
wt_count() {
  printf '%s\n' "${1:-<none>}" >> "$WT_COUNT_CALLS"
  case "${1:-}" in lane-) printf '5\n' ;; *) printf '0\n' ;; esac
}
O="$T"; _HERE_RS=/nonexistent; LOG="$T/state/orch.log"
printf '#!/bin/bash\necho "lanes=3/11 zombie=7"\n' > "$T/lane-reap.sh"
chmod +x "$T/lane-reap.sh"
LANE_REAP_SH=""
# The loop's own function, sourced from an extracted block rather than restated here: a copy would
# pass this leg while the shipped loop drifted.
sed -n '/^LANE_REAP_SH=""/,/^}$/p' "$LOOP" > "$T/measure.sh"
. "$T/measure.sh"
measure_lanes
eq "$LANES/$LANES_TOTAL/$ZOMBIES" "3/11/7" "CAP: live/total/zombie parsed from the census"
eq "$LANES_DISPLAY" "3" "CAP: the DISPLAYED numerator is the census value"
eq "$LANES_UNKNOWN" "0" "CAP: a clean census is not flagged unknown"
eq "$LANES_SOURCE" "census" "CAP: the census is LABELLED as the source"
printf '#!/bin/bash\necho "lanes=?/11 zombie=7"; exit 3\n' > "$T/lane-reap.sh"
measure_lanes
eq "$LANES_UNKNOWN" "1" "CAP: an unreadable numerator REFUSES work (no silent fail-open)"
eq "$LANES_TOTAL/$ZOMBIES" "11/7" "CAP: readable totals are still reported"
eq "$LANES_SOURCE" "unknown" "CAP: an abstaining census is labelled unknown"
eq "$LANES_DISPLAY" "?" "CAP: and its DISPLAYED numerator is ?, never a fabricated 0"
eq "$LANES" "5" "CAP: the internal lower bound is the LAUNCHER census (wt_count), not a tmux session count"
printf '#!/bin/bash\necho "lanes=?/? zombie=?"; exit 3\n' > "$T/lane-reap.sh"
measure_lanes
eq "$LANES_UNKNOWN" "1" "CAP: a wholly unreadable census refuses work"
eq "$LANES_TOTAL/$ZOMBIES" "?/?" "CAP: unknown totals stay unknown, never 0"
# The transition arm: no lane-reap.sh at all -> the LAUNCHER's own worker census, LABELLED. Re-source
# the block so the missing-script resolution runs again (it happens at definition time).
# ⛔ THE FIXTURE IS THE CMUX-ANSWERS SHAPE, and it is the whole point of the leg (#2163 review r8,
# P1; shape corrected in cycle 3): the daemon answers, so the lanes are DURABLE TERMINALS and `tmux ls`
# reports NO lane sessions while the launcher census reports 5 live lanes. (tmux IS the launcher where
# the daemon does not answer — launchd Mac and cell alike, #2210 — so this stub is one of the two
# shapes, not "the cell shape".) The tmux double therefore prints NOTHING
# and the expected value comes from `wt_count`, so an implementation that fell back to `tmux ls` reads
# 0 and this leg goes RED — the direction that dispatches onto a full box.
cat > "$T/bin/tmux" <<'SH'
#!/bin/bash
# The cmux-answer shape: the daemon answers, so no lane lives in tmux and the tmux read is 0
# (tmux IS the launcher where the daemon does not answer — #2210).
exit 0
SH
chmod +x "$T/bin/tmux"
rm -f "$T/lane-reap.sh"
: > "$WT_COUNT_CALLS"
LANE_REAP_SH=""
sed -n '/^LANE_REAP_SH=""/,/^}$/p' "$LOOP" > "$T/measure2.sh"
. "$T/measure2.sh"
PATH="$T/bin:$PATH" measure_lanes
eq "$LANES_SOURCE" "terminals" "CAP: a missing tool falls back to the LAUNCHER census AND says so"
eq "$LANES_DISPLAY" "5" "CAP: the transition reports the launcher census, not a tmux session count"
eq "$LANES_UNKNOWN" "0" "CAP: the launcher fallback is not an abstention (it is a named transition)"
eq "$(tr '\n' ' ' < "$WT_COUNT_CALLS" | sed 's/ $//')" "lane-" "CAP: the fallback asks the launcher for the LANE population"
case "$LANES" in 0) bad "CAP: a busy cell read 0 lanes — the tmux fallback returned (fail-OPEN on capacity)" ;; *) ok "CAP: a busy cell is never read as 0 lanes (the #2159 OOM direction)" ;; esac

# ── SURVIVOR: a SIGTERM-immune victim is escalated, but only while its incarnation holds ────────
echo "== SURVIVOR (TERM followed by KILL, still fenced on the same incarnation)"
out="$(KILL_NO_DEATH=1 run_reap "$T/t-dead" "" -- --apply)"
eq "$(grep -c -- '-KILL 601' "$KILL_LOG")" "1" "SURVIVOR: an unkilled child is escalated to KILL"
eq "$(grep -c -- '-KILL 600' "$KILL_LOG")" "1" "SURVIVOR: an unkilled wrapper is escalated to KILL"

# ── NO-LOG: an unresolvable log is never evidence of staleness ──────────────────────────────────
echo "== NO-LOG (the measured trap: absent evidence must fail closed)"
: > "$T/t-nolog"; psinit >> "$T/t-nolog"
psrow 700 400 Ss 00:00:00 30:00:00 "bash -c cd /repo; pi -p \"\$(cat ciwatch\\012[ brief)\" > /tmp/x 2>&1 &" >> "$T/t-nolog"
psrow 701 700 Sl 00:00:00 30:00:00 pi >> "$T/t-nolog"
fdlink 701 1 "pipe:[4242]"; fdlink 701 2 "socket:[4243]"
out="$(run_reap "$T/t-nolog" "" -- --apply)"
has "$out" "no-log-evidence" "NO-LOG: reported as no-log-evidence"
hasnt "$out" "WOULD REAP" "NO-LOG: not a candidate"
hasnt "$out" "REAP   root=700" "NO-LOG: never reaped"
eq "$(cat "$KILL_LOG" 2>/dev/null | wc -l | tr -d ' ')" "0" "NO-LOG: --apply signals nothing"

# ── EVIDENCE-SIBLING: a SIBLING's log never judges this lane ─────────────────────────────────────
# ⛔ MEASURED KILL (#2163 review, P1). The evidence was "the first fd whose basename matches the
# namespace", walking root then every direct child in pid order — with no check that the holder was
# THIS lane's pi. Repro: root 930 (`bash lane.sh`), child 931 = a backgrounded `tee` holding a 3 h-old
# `fix-9.log`, child 932 = the LIVE pi holding `L-sib.log` written 30 s ago. The pass read the sibling's
# file as the lane's staleness (`log-idle=10800s`) and `--apply` TERMed 932 — the working agent.
echo "== EVIDENCE-SIBLING (only the lane's own pi supplies its log)"
SIB_OLD="$(newlog fix-9.log $((3 * 3600)))"
SIB_LIVE="$(newlog L-sib.log 30)"
: > "$T/t-sib"; psinit >> "$T/t-sib"
psrow 930 400 Ss 00:00:00 05:00:00 "bash lane.sh /repo" >> "$T/t-sib"
psrow 931 930 Sl 00:00:30 05:00:00 "tee $SIB_OLD" >> "$T/t-sib"
psrow 932 930 Sl 00:00:05 05:00:00 "pi --model x" >> "$T/t-sib"
fdlink 931 1 "$SIB_OLD"
fdlink 932 1 "$SIB_LIVE"; fdlink 932 2 "$SIB_LIVE"
out="$(run_reap "$T/t-sib" "" -- --apply)"
has "$out" "log advanced" "EVIDENCE-SIBLING: the lane is judged on ITS OWN log (30 s old)"
hasnt "$out" "log-idle" "EVIDENCE-SIBLING: the sibling's 3 h-old file is never its evidence"
hasnt "$out" "REAP   root=930" "EVIDENCE-SIBLING: the live lane is never reaped"
eq "$(cat "$KILL_LOG" 2>/dev/null | wc -l | tr -d ' ')" "0" "EVIDENCE-SIBLING: --apply signals NOTHING"
has "$out" "trees=1/1" "EVIDENCE-SIBLING: and it is counted WORKING, not as neither"

# ── EVIDENCE-AMBIGUOUS: two lane logs in one tree is ambiguity, not a choice ─────────────────────
# ⛔ No ONE of them is "this lane's" staleness evidence, so taking the first match is picking the file
# that justifies the kill. Refused.
echo "== EVIDENCE-AMBIGUOUS (two distinct lane logs => refused, never a guess)"
AMB_A="$(newlog L-amb-a.log $((5 * 3600)))"
AMB_B="$(newlog L-amb-b.log 60)"
: > "$T/t-amb"; psinit >> "$T/t-amb"
psrow 940 400 Ss 00:00:00 05:00:00 "bash lane.sh /repo" >> "$T/t-amb"
psrow 941 940 Sl 00:00:05 05:00:00 pi --model x >> "$T/t-amb"
fdlink 941 1 "$AMB_A"; fdlink 941 2 "$AMB_B"
out="$(run_reap "$T/t-amb" "" -- --apply)"
has "$out" "ambiguous-log-evidence" "EVIDENCE-AMBIGUOUS: reported as ambiguous-log-evidence"
hasnt "$out" "REAP   root=940" "EVIDENCE-AMBIGUOUS: never reaped on a guess about which file is the lane"
eq "$(cat "$KILL_LOG" 2>/dev/null | wc -l | tr -d ' ')" "0" "EVIDENCE-AMBIGUOUS: --apply signals NOTHING"

# ── EVIDENCE-TEE: `… pi | tee L-x.log` — the pipe-fed writer IS this lane's evidence ─────────────
# The narrowing above must not lose the SHIPPED tee shape: the pi's stdout is a pipe, and the `tee`
# beside it holds the log. A tee whose stdin is NOT a pipe is not this lane's writer.
echo "== EVIDENCE-TEE (a pipe-fed tee beside the pi supplies the log)"
TEE_LOG="$(newlog L-tee.log $((3 * 3600)))"
: > "$T/t-tee"; psinit >> "$T/t-tee"
psrow 950 400 Ss 00:00:00 05:00:00 "bash -c 'pi | tee $TEE_LOG'" >> "$T/t-tee"
psrow 951 950 Sl 00:00:05 05:00:00 pi >> "$T/t-tee"
psrow 952 950 Sl 00:00:05 05:00:00 "tee $TEE_LOG" >> "$T/t-tee"
fdlink 951 1 "pipe:[5150]"
fdlink 952 1 "$TEE_LOG"; fdlink 952 0 "pipe:[5150]"
out="$(run_reap "$T/t-tee" "" -- --dry-run)"
has "$out" "WOULD REAP root=950" "EVIDENCE-TEE: the tee-held log is the lane's evidence"
has "$out" "log-idle" "EVIDENCE-TEE: and the staleness reason is that log's age"

# ── EVIDENCE-TEE-ALIEN: an unrelated pipe-fed tee is NOT this lane's writer ─────────────────────
# ⛔ MEASURED KILL (#2163 review r3, P1). The tee was accepted on "its stdin is a pipe", never on
# "its stdin is THIS LANE's pi's stdout". Repro: root 500, child 501 `tee …/fix-9.log` fed by child
# 503 `cat brief`, child 502 the LIVE 5-minute-old `pi` with fd1 on /dev/null ⇒ the sibling's 3 h-old
# log judged the lane: `REAP root=500 log-idle=10800s`, `-TERM 502`, `-KILL 502`. The sibling's pipe
# and the pi's stdout are DIFFERENT descriptors, which is the one fact the gate was missing.
echo "== EVIDENCE-TEE-ALIEN (a pipe-fed tee that copies something else is not the lane's writer)"
ALIEN_LOG="$(newlog fix-alien.log $((3 * 3600)))"
: > "$T/t-alien"; psinit >> "$T/t-alien"
psrow 500 400 Ss 00:00:00 05:00:00 "bash lane.sh /repo" >> "$T/t-alien"
psrow 501 500 Sl 00:05:00 05:00:00 "tee $ALIEN_LOG" >> "$T/t-alien"
psrow 502 500 Sl 00:05:00 00:05:00 "pi --model x" >> "$T/t-alien"
psrow 503 500 Sl 00:00:01 05:00:00 "cat brief" >> "$T/t-alien"
fdlink 501 1 "$ALIEN_LOG"
fdlink 501 0 "pipe:[7001]"
fdlink 502 1 "/dev/null";  fdlink 502 2 "/dev/null"
fdlink 503 1 "pipe:[7001]"
out="$(run_reap "$T/t-alien" "" -- --apply)"; rc=$?
has "$out" "no-log-evidence" "EVIDENCE-TEE-ALIEN: the alien tee supplies NO evidence (no-log-evidence)"
hasnt "$out" "log-idle" "EVIDENCE-TEE-ALIEN: the sibling's 3 h-old log never judges the live lane"
hasnt "$out" "REAP   root=500" "EVIDENCE-TEE-ALIEN: the live pi is never reaped"
eq "$(cat "$KILL_LOG" 2>/dev/null | wc -l | tr -d ' ')" "0" "EVIDENCE-TEE-ALIEN: --apply signals NOTHING"

# ── EVIDENCE-TEE-LSOF: the same tee shape, through lsof's spellings (macOS's ONLY branch) ───────
# ⛔ A SPELLING IS NOT A TYPE (#2163 review r3, P1). The old test was written in /proc's spelling
# only (`pipe:*`), while lsof 4.95 prints `pipe` and macOS prints `->0x…`. On the lsof branch the
# shipped `pi | tee L-x.log` shape therefore resolved rc 1: `reap` refused `no-log-evidence` AND the
# CENSUS counted the lane `not_lane`, printing `lanes=0/0 zombie=0` with exit 0 while the lane was
# RESIDENT — a false under-count ⇒ a false MAX_LANES ⇒ dispatch-more, on the only platform where
# `fleet` ancestry can exist.
# ⛔ …AND A *TYPE* IS NOT AN *IDENTITY* (#2163 review r4, P1). The r3 fixture handed EVERY pid and
# EVERY fd 0 the same name (`pipe`), so the two pipes in it were the same string BY CONSTRUCTION:
# the leg could not go red if the identity check were deleted, and there was no alien-tee leg on
# this branch at all. The double therefore takes the spelling from the leg (`LSOF_PIPE_PI` for the
# pi's fd 1, `LSOF_PIPE_STDIN` for whatever stdin pipe is read), so a leg can model a platform that
# prints a real per-pipe name (`->0x…`, `pipe:[N]`) AND one that prints only a generic one
# (`pipe`, `->0x0`) — which is what lsof 4.95 actually does, and which must ABSTAIN, never accept.
cat > "$T/bin/lsof-tee" <<'SH'
#!/usr/bin/env bash
# REAL lsof SHAPE: `-Ft` is the TYPE, `-Fn` the NAME, one `n` per fd. On Linux lsof 4.95 the name of
# an anonymous pipe is the literal `pipe` (measured) — the SAME string for both ends of EVERY pipe,
# so it is a spelling and never an identity; macOS prints an address (`->0x…`).
pid=""; fds=""; prev=""
for a in "$@"; do
  [ "$prev" = "-p" ] && pid="$a"
  [ "$prev" = "-d" ] && fds="$a"
  prev="$a"
done
if [ "$fds" = "0" ]; then printf 'tFIFO\nn%s\n' "${LSOF_PIPE_STDIN:?}"; exit 0; fi
case "$pid" in
  "${LSOF_TEE_PID:?}") printf 'tREG\nn%s\n' "${LSOF_TEE_LOG:?}" ;;
  *) printf 'tFIFO\nn%s\n' "${LSOF_PIPE_PI:?}" ;;
esac
exit 0
SH
chmod +x "$T/bin/lsof-tee"
echo "== EVIDENCE-TEE-LSOF (an ADDRESS both sides reproduce identifies the lane's own tee)"
TEE2_LOG="$(newlog L-tee2.log $((3 * 3600)))"
: > "$T/t-tee2"; psinit >> "$T/t-tee2"
psrow 960 400 Ss 00:00:00 05:00:00 "bash -c 'pi | tee $TEE2_LOG'" >> "$T/t-tee2"
psrow 961 960 Sl 00:00:05 05:00:00 pi >> "$T/t-tee2"
psrow 962 960 Sl 00:00:05 05:00:00 "tee $TEE2_LOG" >> "$T/t-tee2"
out="$(REAP_PROC_ROOT_OVERRIDE="" LSOF_TEE_PID=962 LSOF_TEE_LOG="$TEE2_LOG" \
       LSOF_PIPE_PI='->0xAAA' LSOF_PIPE_STDIN='->0xAAA' \
       REAP_LSOF_OVERRIDE="$T/bin/lsof-tee" run_reap "$T/t-tee2" "" -- --dry-run)"
has "$out" "WOULD REAP root=960" "EVIDENCE-TEE-LSOF: the tee-held log is the lane's evidence on the lsof branch"
hasnt "$out" "no-log-evidence" "EVIDENCE-TEE-LSOF: it is never refused as no-log-evidence"
out="$(REAP_PROC_ROOT_OVERRIDE="" LSOF_TEE_PID=962 LSOF_TEE_LOG="$TEE2_LOG" \
       LSOF_PIPE_PI='->0xAAA' LSOF_PIPE_STDIN='->0xAAA' \
       REAP_LSOF_OVERRIDE="$T/bin/lsof-tee" run_count "$T/t-tee2")"; rc=$?
eq "$out" "lanes=0/1 zombie=0" "EVIDENCE-TEE-LSOF: the census counts the RESIDENT lane (0/1), never a confident 0/0"
eq "$rc" "0" "EVIDENCE-TEE-LSOF: …and a readable census is not an abstention"
# The `pipe:[N]` spelling, seen THROUGH lsof (a build that answers with the kernel's inode): the
# same pipe at both ends is still an identity, so the acceptance is not tied to the `->0x` shape.
out="$(REAP_PROC_ROOT_OVERRIDE="" LSOF_TEE_PID=962 LSOF_TEE_LOG="$TEE2_LOG" \
       LSOF_PIPE_PI='pipe:[5150]' LSOF_PIPE_STDIN='pipe:[5150]' \
       REAP_LSOF_OVERRIDE="$T/bin/lsof-tee" run_reap "$T/t-tee2" "" -- --dry-run)"
has "$out" "WOULD REAP root=960" "EVIDENCE-TEE-LSOF: a pipe:[N] identity through lsof is accepted too"

# ── EVIDENCE-TEE-LSOF-ALIEN: a DIFFERENT address is never this lane's writer ─────────────────────
# The r4 repro's shape (root 500, alien tee 501 fed by 503 `cat brief` on pipe B, the LIVE pi 502
# piped to a logger on pipe A), on the ONLY branch macOS has. With per-pipe names the two ends differ,
# so the tee is not this lane's writer and nothing is signalled. (Deleting the identity check makes
# THIS leg reap the live pi, which is what the r3 fixture could never show.)
echo "== EVIDENCE-TEE-LSOF-ALIEN (a different pipe address is not this lane's writer)"
ALIEN3_LOG="$(newlog fix-alien3.log $((3 * 3600)))"
: > "$T/t-alien3"; psinit >> "$T/t-alien3"
psrow 500 400 Ss 00:00:00 05:00:00 "bash lane.sh /repo" >> "$T/t-alien3"
psrow 501 500 Sl 00:05:00 05:00:00 "tee $ALIEN3_LOG" >> "$T/t-alien3"
psrow 502 500 Sl 00:05:00 00:05:00 "pi --model x" >> "$T/t-alien3"
psrow 503 500 Sl 00:00:01 05:00:00 "cat brief" >> "$T/t-alien3"
out="$(REAP_PROC_ROOT_OVERRIDE="" LSOF_TEE_PID=501 LSOF_TEE_LOG="$ALIEN3_LOG" \
       LSOF_PIPE_PI='->0xAAA' LSOF_PIPE_STDIN='->0xBBB' \
       REAP_LSOF_OVERRIDE="$T/bin/lsof-tee" run_reap "$T/t-alien3" "" -- --apply)"; rc=$?
has "$out" "no-log-evidence" "EVIDENCE-TEE-LSOF-ALIEN: the alien tee supplies NO evidence (no-log-evidence)"
hasnt "$out" "log-idle" "EVIDENCE-TEE-LSOF-ALIEN: the sibling's 3 h-old log never judges the live lane"
hasnt "$out" "REAP   root=500" "EVIDENCE-TEE-LSOF-ALIEN: the live pi is never reaped"
eq "$(cat "$KILL_LOG" 2>/dev/null | wc -l | tr -d ' ')" "0" "EVIDENCE-TEE-LSOF-ALIEN: --apply signals NOTHING"
eq "$rc" "0" "EVIDENCE-TEE-LSOF-ALIEN: the pass is clean (the reads were taken; this tree is not a lane)"

# ── EVIDENCE-TEE-LSOF-GENERIC: a generic pipe spelling is NOT an identity ⇒ ABSTAIN ────────────
# ⛔ MEASURED KILL ON THE lsof BRANCH (#2163 review r4, P1). lsof 4.95 prints `pipe` — measured —
# for BOTH ends of EVERY anonymous pipe, so `_pipe_ident` used to return the same string for the pi's
# stdout and an unrelated tee's stdin: root 500, child 501 `tee …/fix-9.log` fed by 503 `cat brief`
# (pipe B), child 502 the LIVE 5-minute-old `pi` piped to a logger (pipe A) ⇒ `REAP root=500`,
# `-TERM 502`, `-KILL 502`, rc 0. lsof is the ONLY branch on macOS. A generic name cannot prove the
# tee is the writer and cannot prove it is not, so the tree ABSTAINS (rc 2 ⇒ `abstained=` + exit 3):
# no evidence is ever borrowed, and a real lane's own writer is not silently dropped either.
echo "== EVIDENCE-TEE-LSOF-GENERIC (lsof's 'pipe' is a spelling, not an identity: ABSTAIN)"
for spelling in 'pipe' '->0x0'; do
  out="$(REAP_PROC_ROOT_OVERRIDE="" LSOF_TEE_PID=501 LSOF_TEE_LOG="$ALIEN3_LOG" \
         LSOF_PIPE_PI="$spelling" LSOF_PIPE_STDIN="$spelling" \
         REAP_LSOF_OVERRIDE="$T/bin/lsof-tee" run_reap "$T/t-alien3" "" -- --apply)"; rc=$?
  has "$out" "pipe-identity-unusable" "EVIDENCE-TEE-LSOF-GENERIC [$spelling]: refused as pipe-identity-unusable (the READS succeeded), never judged"
  # ⛔ AN UNUSABLE IDENTITY IS NOT A FAILED READ (#2163 review r5, P3). `log-evidence-unreadable`
  # asserts "the descriptors could not be read" — false here, where every read was taken — and
  # `abstained=` ("a SAFETY read failed") then sends the operator after an lsof/permissions fault
  # that does not exist. The cause has its own token AND its own counter.
  hasnt "$out" "log-evidence-unreadable" "EVIDENCE-TEE-LSOF-GENERIC [$spelling]: never reported as a FAILED READ"
  has "$out" "unidentifiable=1" "EVIDENCE-TEE-LSOF-GENERIC [$spelling]: counted in its OWN counter (unidentifiable=)"
  has "$out" "abstained=0" "EVIDENCE-TEE-LSOF-GENERIC [$spelling]: …and NOT as a failed-read abstention"
  hasnt "$out" "log-idle" "EVIDENCE-TEE-LSOF-GENERIC [$spelling]: the sibling's 3 h-old log never judges the lane"
  hasnt "$out" "REAP   root=500" "EVIDENCE-TEE-LSOF-GENERIC [$spelling]: nothing is reaped on a borrowed identity"
  eq "$(cat "$KILL_LOG" 2>/dev/null | wc -l | tr -d ' ')" "0" "EVIDENCE-TEE-LSOF-GENERIC [$spelling]: --apply signals NOTHING"
  eq "$rc" "3" "EVIDENCE-TEE-LSOF-GENERIC [$spelling]: the pass ABSTAINS (exit 3), never a clean 0"
done

# ⛔ THE CENSUS MUST ABSTAIN TOO (#2163 review r6, P1). The rc-2/rc-4 split left `cmd_count` with no
# arm for an unusable identity: the tree fell through to `attributed` with an EMPTY path, the lane-log
# filter dropped it, and the census printed `lanes=0/0` exit 0 over a RESIDENT lane — the same
# under-count ⇒ false MAX_LANES ⇒ dispatch-more fail-open this issue closes, on the only platform
# where `fleet` ancestry exists. Measured before the fix: `lanes=0/0 zombie=0`, rc 0.
out="$(REAP_PROC_ROOT_OVERRIDE="" LSOF_TEE_PID=501 LSOF_TEE_LOG="$ALIEN3_LOG" \
       LSOF_PIPE_PI="pipe" LSOF_PIPE_STDIN="pipe" \
       REAP_LSOF_OVERRIDE="$T/bin/lsof-tee" run_count "$T/t-alien3")"; rc=$?
has "$out" "lanes=?/?" "CENSUS-UNIDENTIFIABLE: an unusable identity abstains the census, never a confident 0/0"
eq "$rc" "3" "CENSUS-UNIDENTIFIABLE: …with exit 3"

# ── EVIDENCE-MIXED: a readable box must not be reported as a BLIND one ─────────────────────────
# ⛔ MEASURED (#2163 review r5, P3). The generic-spelling abstention reused the READ-FAILURE refusal
# and counter, so on a box with ONE healthy live lane and ONE generic-spelling tee tree the reaper
# printed `REFUSE root=500 — log-evidence-unreadable (the descriptors could not be read …)` beside
# `SKIP root=600 … log advanced 60s ago` and `trees=1/1 … abstained=1`, rc 3 — and the doctor, whose
# only escalation arm was `*abstained=[!0]*`, recorded `reap FAILED rc=3` whose only cause line named
# a blind read. Every read on that box SUCCEEDED; the operator would chase an lsof/permissions fault
# that does not exist. The identity abstention now has its own token (`pipe-identity-unusable`), its
# own counter (`unidentifiable=`, beside `inert=`), and its own exit-3 path, so the cause named is the
# cause that happened. This leg is that exact box, and it pins the WHOLE summary line.
echo "== EVIDENCE-MIXED (a readable box's identity abstention is not a blind read)"
cat > "$T/bin/lsof-mixed" <<'SH'
#!/usr/bin/env bash
# Per-(pid, -d) lsof so ONE table can carry both trees: 500 is the generic-spelling tee tree (its pi
# is piped, its tee's stdin is a pipe, and the platform names neither), 600 is a healthy live lane
# whose pi holds a real log file.
pid=""; fds=""; prev=""
for a in "$@"; do
  [ "$prev" = "-p" ] && pid="$a"
  [ "$prev" = "-d" ] && fds="$a"
  prev="$a"
done
case "$pid:$fds" in
  501:0) printf 'tFIFO\nn%s\n' "${LSOF_PIPE_STDIN:?}" ;;
  # collect_evidence reads BOTH descriptors of the lane's `pi` (the pstd identity read takes fd 1
  # alone), so this arm answers `1,2` — one pipe line per fd, neither a log.
  502:1,2) printf 'tFIFO\nn%s\ntFIFO\nn%s\n' "${LSOF_PIPE_PI:?}" "${LSOF_PIPE_PI:?}" ;;
  601:1,2) printf 'tREG\nn%s\ntREG\nn%s\n' "${MIXED_LIVE_LOG:?}" "${MIXED_LIVE_LOG:?}" ;;
  *) exit 1 ;;
esac
exit 0
SH
chmod +x "$T/bin/lsof-mixed"
MIXED_LIVE_LOG="$(newlog L-mixedlive.log 60)"
: > "$T/t-mixed"; psinit >> "$T/t-mixed"
psrow 500 400 Ss 00:00:00 05:00:00 "bash lane.sh /repo" >> "$T/t-mixed"
psrow 501 500 Sl 00:05:00 05:00:00 "tee $ALIEN3_LOG" >> "$T/t-mixed"
psrow 502 500 Sl 00:05:00 00:05:00 "pi --model x" >> "$T/t-mixed"
psrow 503 500 Sl 00:00:01 05:00:00 "cat brief" >> "$T/t-mixed"
psrow 600 400 Ss 00:00:00 01:00:00 "bash -c cd /repo; pi -p \"\$(cat brief)\" > $MIXED_LIVE_LOG 2>&1 &" >> "$T/t-mixed"
psrow 601 600 Sl 00:00:05 01:00:00 pi >> "$T/t-mixed"
out="$(REAP_PROC_ROOT_OVERRIDE="" LSOF_TEE_PID=501 LSOF_TEE_LOG="$ALIEN3_LOG" \
       LSOF_PIPE_PI='pipe' LSOF_PIPE_STDIN='pipe' MIXED_LIVE_LOG="$MIXED_LIVE_LOG" \
       REAP_LSOF_OVERRIDE="$T/bin/lsof-mixed" run_reap "$T/t-mixed" "" -- --apply)"; rc=$?
has "$out" "pipe-identity-unusable" "EVIDENCE-MIXED: the identity abstention names IDENTITY"
hasnt "$out" "log-evidence-unreadable" "EVIDENCE-MIXED: no tree on a readable box is reported as a FAILED READ"
hasnt "$out" "descriptors could not be read" "EVIDENCE-MIXED: …nor with the read-failure wording"
has "$out" "log advanced 60s ago" "EVIDENCE-MIXED: the healthy lane beside it is still judged (readable, live)"
has "$out" "trees=1/1" "EVIDENCE-MIXED: the judged tree is counted as judged"
has "$out" "lane-reap: trees=1/1 zombie=0 candidates=0 reaped=0 refused=1 inert=0 unidentifiable=1 abstained=0 mode=apply" \
  "EVIDENCE-MIXED: the summary line carries the identity counter BESIDE inert, with abstained=0"
eq "$rc" "3" "EVIDENCE-MIXED: an identity abstention is still exit 3 (never a clean 0)"
eq "$(cat "$KILL_LOG" 2>/dev/null | wc -l | tr -d ' ')" "0" "EVIDENCE-MIXED: --apply signals NOTHING on either tree"
out="$(REAP_PROC_ROOT_OVERRIDE="" LSOF_TEE_PID=501 LSOF_TEE_LOG="$ALIEN3_LOG" \
       LSOF_PIPE_PI='pipe' LSOF_PIPE_STDIN='pipe' MIXED_LIVE_LOG="$MIXED_LIVE_LOG" \
       REAP_LSOF_OVERRIDE="$T/bin/lsof-mixed" run_reap "$T/t-mixed" "" -- --json)"
has "$out" '"unidentifiable":1' "EVIDENCE-MIXED: --json carries the counter too"
has "$out" '"abstained":0' "EVIDENCE-MIXED: …and does not inflate the failed-read count"

# ── EVIDENCE-BLIND: a descriptor read that FAILED is an abstention, never "no log" ───────────────
# ⛔ `no-log-evidence` and `log-evidence-unreadable` look identical in the summary and mean opposite
# things: the first is "I looked and this tree is not a lane", the second is "I could not look".
# Collapsing them is the #2163 P0 fail-open one tree at a time, so the blind case has its own refusal
# AND increments `abstained` (the pass exits 3 rather than reporting a clean `refused=0 reaped=0`).
echo "== EVIDENCE-BLIND (an unreadable descriptor is an abstention, not 'no log')"
cat > "$T/bin/lsof-fail" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$T/bin/lsof-fail"
: > "$T/t-blind"; psinit >> "$T/t-blind"
psrow 955 400 Ss 00:00:00 05:00:00 "bash lane.sh /repo" >> "$T/t-blind"
psrow 956 955 Sl 00:00:05 05:00:00 pi --model x >> "$T/t-blind"
out="$(REAP_PROC_ROOT_OVERRIDE=/nonexistent/proc REAP_LSOF_OVERRIDE="$T/bin/lsof-fail" \
       run_reap "$T/t-blind" "" -- --apply)"; rc=$?
has "$out" "log-evidence-unreadable" "EVIDENCE-BLIND: refused as log-evidence-unreadable, NOT no-log-evidence"
hasnt "$out" "no-log-evidence" "EVIDENCE-BLIND: a blind read is never reported as \"not a lane\""
hasnt "$out" "pipe-identity-unusable" "EVIDENCE-BLIND: a FAILED read is never reported as an unusable identity"
has "$out" "abstained=1" "EVIDENCE-BLIND: the abstention is counted"
has "$out" "unidentifiable=0" "EVIDENCE-BLIND: …in the READ-FAILURE counter, not the identity one"
eq "$rc" "3" "EVIDENCE-BLIND: the pass exits 3"
eq "$(cat "$KILL_LOG" 2>/dev/null | wc -l | tr -d ' ')" "0" "EVIDENCE-BLIND: --apply signals NOTHING"

# ── EVIDENCE-BLIND-PARTIAL: one readable candidate does not outvote a sibling read that FAILED ───
# ⛔ THE SAME FAIL-OPEN, ONE CANDIDATE AT A TIME (#2163 review, P1). `blind` used to be tested BELOW
# the single-candidate return, so a tree holding one readable 3 h-old lane log BESIDE a sibling whose
# descriptors could not be read resolved to that log, judged the WHOLE tree stale, and TERMed/KILLed it
# — including the process nobody had read — while printing `abstained=0` and exiting 0. One readable
# file is not an answer about a tree that is partly invisible: the unread sibling may be the LIVE lane
# and the readable file may belong to the one that finished.
echo "== EVIDENCE-BLIND-PARTIAL (a readable lane log beside an unreadable sibling ABSTAINS)"
cat > "$T/bin/lsof-partial" <<'SH'
#!/usr/bin/env bash
# 701's descriptors read normally (a stale lane log); 702's read FAILS, so that sibling is BLIND.
pid=""; prev=""
for a in "$@"; do
  [ "$prev" = "-p" ] && pid="$a"
  prev="$a"
done
case "$pid" in
  701) printf 'tREG\nn%s\ntREG\nn%s\n' "${PARTIAL_STALE_LOG:?}" "${PARTIAL_STALE_LOG:?}" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/bin/lsof-partial"
PARTIAL_STALE_LOG="$(newlog L-partial-stale.log $((3 * 3600)))"
: > "$T/t-partial"; psinit >> "$T/t-partial"
psrow 700 400 Ss 00:00:00 05:00:00 "bash lane.sh /repo" >> "$T/t-partial"
psrow 701 700 Sl 00:00:00 05:00:00 "pi --model x" >> "$T/t-partial"
psrow 702 700 Sl 00:00:05 05:00:00 "pi --model x" >> "$T/t-partial"
out="$(REAP_PROC_ROOT_OVERRIDE="" PARTIAL_STALE_LOG="$PARTIAL_STALE_LOG" \
       REAP_LSOF_OVERRIDE="$T/bin/lsof-partial" run_reap "$T/t-partial" "" -- --apply)"; rc=$?
has "$out" "log-evidence-unreadable" "EVIDENCE-BLIND-PARTIAL: the tree abstains on the unreadable sibling"
hasnt "$out" "REAP   root=700" "EVIDENCE-BLIND-PARTIAL: the readable log never licenses a kill"
has "$out" "abstained=1" "EVIDENCE-BLIND-PARTIAL: the abstention is counted"
eq "$rc" "3" "EVIDENCE-BLIND-PARTIAL: the pass exits 3"
eq "$(cat "$KILL_LOG" 2>/dev/null | wc -l | tr -d ' ')" "0" "EVIDENCE-BLIND-PARTIAL: --apply signals NOTHING"

# ── DELETED: a resolved-but-deleted log is judged by the 12h bound only ─────────────────────────
echo "== DELETED (no-log needs the 12h age bound; young lanes are spared)"
: > "$T/t-del"; psinit >> "$T/t-del"
psrow 800 400 Ss 00:00:00 01:00:00 "bash launch-lane.sh /tmp/wt /tmp/brief > /tmp/L-old.log 2>&1" >> "$T/t-del"
psrow 801 800 Sl 00:00:00 01:00:00 pi >> "$T/t-del"
fdlink 801 1 "/tmp/L-old.log (deleted)"
out="$(run_reap "$T/t-del" "" -- --dry-run)"
has "$out" "under 12h" "DELETED: a 1h-old deleted-log lane is spared"
hasnt "$out" "WOULD REAP" "DELETED: young deleted-log lane is not a candidate"
: > "$T/t-del2"; psinit >> "$T/t-del2"
psrow 800 400 Ss 00:00:00 13:00:00 "bash launch-lane.sh /tmp/wt /tmp/brief > /tmp/L-old.log 2>&1" >> "$T/t-del2"
psrow 801 800 Sl 00:00:00 13:00:00 pi >> "$T/t-del2"
fdlink 801 1 "/tmp/L-old.log (deleted)"
out="$(run_reap "$T/t-del2" "" -- --dry-run)"
has "$out" "WOULD REAP root=800" "DELETED: a 13h-old deleted-log lane IS stale"

# ── DELETED (macOS SHAPE): lsof prints the OLD path, with no " (deleted)" suffix ─────────────────
# Measured on 26.6.2: `lsof -n -P -a -p <pid> -d 1,2 -Fn` prints the plain path for an unlinked fd.
# Before this leg the whole 12h no-log arm was unreachable on macOS (the lane abstained for ever on
# `log-age-unreadable`), so the ONLY covered spelling was Linux's fake /proc one above.
: > "$T/t-del3"; psinit >> "$T/t-del3"
psrow 810 400 Ss 00:00:00 13:00:00 "bash launch-lane.sh /tmp/wt /tmp/brief > $T/logs/L-gone.log 2>&1" >> "$T/t-del3"
psrow 811 810 Sl 00:00:00 13:00:00 pi >> "$T/t-del3"
out="$(REAP_PROC_ROOT_OVERRIDE="" LSOF_PATH="$T/logs/L-gone.log" run_reap "$T/t-del3" "" -- --dry-run)"
has "$out" "no-log up=46800s" "DELETED (lsof shape): an unlinked log is recognised WITHOUT the \" (deleted)\" suffix"
has "$out" "WOULD REAP root=810" "DELETED (lsof shape): the 13h no-log bound decides it"
: > "$T/t-del4"; psinit >> "$T/t-del4"
psrow 820 400 Ss 00:00:00 01:00:00 "bash launch-lane.sh /tmp/wt /tmp/brief > $T/logs/L-gone2.log 2>&1" >> "$T/t-del4"
psrow 821 820 Sl 00:00:00 01:00:00 pi >> "$T/t-del4"
out="$(REAP_PROC_ROOT_OVERRIDE="" LSOF_PATH="$T/logs/L-gone2.log" run_reap "$T/t-del4" "" -- --dry-run)"
hasnt "$out" "WOULD REAP" "DELETED (lsof shape): a 1h-old unlinked log is still spared"

# ── DELETED (HOLDER AGE): the 12 h bound is measured on the process that HOLDS the log ──────────
# ⛔ THE WITNESS'S AGE, NOT THE WRAPPER'S (#2163 review r3, P3). Gate 3's no-log bound was read from
# `$root` — the WRAPPER — while the descriptor that IS the evidence belongs to the lane's `pi` (the
# `holder` `resolve_log` already returned and nothing consumed). A wrapper up 28 h hosting a `pi`
# started 10 minutes ago with a rotated (deleted) log therefore satisfied `up>=12h` IMMEDIATELY:
# `-TERM`, `-KILL`, a 10-minute-old lane killed. `up=` must be the HOLDER's elapsed time.
echo "== DELETED-HOLDER-AGE (the no-log bound is the log-holder's age, not the wrapper's)"
: > "$T/t-del5"; psinit >> "$T/t-del5"
psrow 1100 400 Ss 00:00:00 28:00:00 "bash lane.sh /repo" >> "$T/t-del5"
psrow 1101 1100 Sl 00:00:05 00:10:00 pi >> "$T/t-del5"
fdlink 1101 1 "/tmp/L-rotated.log (deleted)"
out="$(run_reap "$T/t-del5" "" -- --apply)"; rc=$?
has "$out" "no-log up=600s" "DELETED-HOLDER-AGE: up= is the PI's 10 minutes, not the wrapper's 28 hours"
has "$out" "under 12h" "DELETED-HOLDER-AGE: a freshly started pi with a rotated log is SPARED"
hasnt "$out" "REAP   root=1100" "DELETED-HOLDER-AGE: the live lane is never reaped"
eq "$(cat "$KILL_LOG" 2>/dev/null | wc -l | tr -d ' ')" "0" "DELETED-HOLDER-AGE: --apply signals NOTHING"

# ── INERT: a pass that refuses every lane it found is not a clean pass ───────────────────────────
# ⛔ THE CELL SHAPE (#2163 review r3, P2). On a cell every lane's ancestry is `unknown`, so the armed
# pass judged ZERO trees while refusing all of them and still printed `trees=0/0 … refused=1
# abstained=0 mode=apply` with rc 0; `cloud-cell-doctor.sh` records `state_write reap 0` — a healthy
# reaper, every pass, from an instrument that is inert there BY DESIGN. A policy refusal is a
# decision, so it is counted (`inert=`) and a pass that judged nothing says so in its exit code.
# ⛔ IT IS `4`, NOT `3` (#2163 review r8, P1): `3` is CANNOT-VERIFY (a read that failed) and a consumer
# must escalate it; on a LINUX CELL this shape is the STEADY STATE, so escalating it there made
# `cloud-cell-supervisor.sh status` red for ever and collapsed a real cannot-verify — and a failed
# controller restart — into the same number. `4` is its own POLICY verdict: still never a clean `0`,
# and now distinguishable from a failure.
echo "== INERT (a refusal that judged zero trees is exit 4, and inert= names the count)"
: > "$T/t-inert"; psinit >> "$T/t-inert"
psrow 400 1 Ss 00:00:00 10:00:00 "/usr/sbin/cron -f" >> "$T/t-inert"
psrow 1200 400 Ss 00:00:00 05:00:00 "bash lane.sh /repo" >> "$T/t-inert"
psrow 1201 1200 Sl 00:00:05 05:00:00 pi >> "$T/t-inert"
fdlink 1201 1 "$DEAD_LOG"
out="$(run_reap "$T/t-inert" "" -- --apply)"; rc=$?
has "$out" "refused=1 inert=1 unidentifiable=0 abstained=0" "INERT: the refusal is counted as inert, not as an abstention"
has "$out" "trees=0/0" "INERT: no tree was judged"
eq "$rc" "4" "INERT: …and that is exit 4 (a POLICY verdict), never a clean 0 and never cannot-verify"
out="$(run_reap "$T/t-inert" "" -- --json)"
has "$out" '"inert":1' "INERT: --json carries the counter too"
# …and inert>0 on a pass that DID judge trees is normal, not an error: a human-owned lane beside a
# fleet-owned one is refused AND the pass is clean.
echo "== INERT-MIXED (a policy refusal beside a judged lane is NOT a failed pass)"
: > "$T/t-mixed"; psinit >> "$T/t-mixed"
psrow 400 1 Ss 00:00:00 10:00:00 "/Applications/Terminal.app/Contents/MacOS/Terminal" >> "$T/t-mixed"
psrow 1300 400 Ss 00:00:00 05:00:00 "bash lane.sh /repo" >> "$T/t-mixed"
psrow 1301 1300 Sl 00:00:05 05:00:00 pi >> "$T/t-mixed"
fdlink 1301 1 "$DEAD_LOG"
psrow 1400 1 Ss 00:00:00 10:00:00 "/Applications/cmux.app/Contents/MacOS/cmux" >> "$T/t-mixed"
psrow 1401 1400 Ss 00:00:00 05:00:00 "bash lane.sh /repo" >> "$T/t-mixed"
psrow 1402 1401 Sl 00:00:05 05:00:00 pi >> "$T/t-mixed"
fdlink 1402 1 "$DEAD_LOG"
out="$(run_reap "$T/t-mixed" "" -- --dry-run)"; rc=$?
has "$out" "human-ancestor" "INERT-MIXED: the human-owned lane is refused"
has "$out" "WOULD REAP root=1401" "INERT-MIXED: the fleet-owned lane is judged"
has "$out" "trees=0/1" "INERT-MIXED: one tree was judged (and is a dry-run candidate)"
has "$out" "inert=1" "INERT-MIXED: the refusal is still counted"
eq "$rc" "0" "INERT-MIXED: a judged lane keeps the pass clean (inert alone is not an error)"

# ── CPU going BACKWARDS is a broken read, never "parked" ─────────────────────────────────────────
# The composition check above proved this subtree identical across the window, so its CPU total
# cannot shrink; a negative delta means a truncated/incomplete second read. It used to fall through
# `[ dcs -gt CPU_TOL_CS ]` as "cpu unchanged" and hand the decision to the idle-log gate alone,
# TERMing a lane that may be working.
NEG_LOG="$(newlog L-neg.log $((3 * 3600)))"
: > "$T/t-neg1"; psinit >> "$T/t-neg1"
psrow 900 400 Ss 00:00:00 03:00:00 "bash -c cd /repo; pi -p x > $NEG_LOG 2>&1 &" >> "$T/t-neg1"
psrow 901 900 Sl 00:00:40 03:00:00 pi >> "$T/t-neg1"
fdlink 901 1 "$NEG_LOG"; fdlink 901 2 "$NEG_LOG"
# the second read reports LESS cpu for the same, unchanged pids — the broken-read shape
{ psinit
  psrow 900 400 Ss 00:00:00 03:00:00 "bash -c cd /repo; pi -p x > $NEG_LOG 2>&1 &"
  psrow 901 900 Sl 00:00:00 03:00:00 pi
} > "$T/t-neg2"
out="$(run_reap "$T/t-neg1" "$T/t-neg2" -- --apply)"
rc=$?
has "$out" "cpu-unreadable" "NEG-DELTA: a CPU total that went backwards is reported as an unreadable read"
hasnt "$out" "REAP   root=900" "NEG-DELTA: the lane is NOT called reaped"
eq "$(cat "$KILL_LOG" 2>/dev/null | wc -l | tr -d ' ')" "0" "NEG-DELTA: --apply signals NOTHING on a broken read"

# ── the lock's own acquisition window is HELD, not stale ─────────────────────────────────────────
# Between `mkdir $LOCK.d` and the pid write there is a moment with no pid file; a SIGKILL leaves the
# same state. Reading that as "stale" put TWO passes on one population (each then deleting the
# other's lock via the EXIT trap). A young pid-less lock is HELD; a backdated one is reclaimed.
: > "$T/t-lock"; psinit >> "$T/t-lock"
psrow 100 1 Ss 00:00:00 01:00:00 /usr/sbin/cron >> "$T/t-lock"
mkdir -p "$T/state/lane-reap.d"
out="$(run_reap "$T/t-lock" "" -- --dry-run)"
has "$out" "another pass holds" "LOCK: a pid-less lock dir inside the acquisition window is HELD"
hasnt "$out" "candidates=" "LOCK: a held lock runs no pass at all"
set_mtime "$T/state/lane-reap.d" "$((NOW - 3600))"
out="$(run_reap "$T/t-lock" "" -- --dry-run)"
has "$out" "candidates=" "LOCK: a backdated pid-less lock is reclaimed (a killed pass does not disarm the reaper)"
rm -rf "$T/state/lane-reap.d"

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

# ── HUMAN-ARGV: a human marker ANYWHERE in an ancestor's argv refuses (over-refusal is safe) ─────
echo "== HUMAN-ARGV (HUMAN is matched anywhere in an ancestor's argv — fail closed)"
: > "$T/t-hargv"; psinit >> "$T/t-hargv"
psrow 400 1 Ss 00:00:00 10:00:00 "/Applications/Terminal.app/Contents/MacOS/Terminal" >> "$T/t-hargv"
psrow 401 400 Ss 00:00:00 10:00:00 "zsh -c launch --brief '/tmp/brief-mentioning-cmux.app'" >> "$T/t-hargv"
psrow 902 401 Ss 00:00:00 05:00:00 "bash -c PATH=/Applications/cmux.app/Contents/MacOS:$PATH pi > $DEAD_LOG 2>&1 &" >> "$T/t-hargv"
psrow 903 902 Sl 00:00:00 05:00:00 pi >> "$T/t-hargv"
fdlink 903 1 "$DEAD_LOG"
out="$(run_reap "$T/t-hargv" "" -- --apply)"
has "$out" "human-ancestor" "HUMAN-ARGV: a Terminal.app above is found THROUGH the text"
hasnt "$out" "REAP   root=902" "HUMAN-ARGV: never reaped"
eq "$(cat "$KILL_LOG" 2>/dev/null | wc -l | tr -d ' ')" "0" "HUMAN-ARGV: no signal"

echo "== HUMAN-SPACED (a human executable path containing a space is still a refusal)"
: > "$T/t-space"; psinit >> "$T/t-space"
psrow 420 1 Ss 00:00:00 10:00:00 "/Applications/My Apps/Terminal.app/Contents/MacOS/Terminal" >> "$T/t-space"
psrow 406 420 Ss 00:00:00 05:00:00 "bash -c pi > $DEAD_LOG 2>&1 &" >> "$T/t-space"
psrow 407 406 Sl 00:00:00 05:00:00 pi >> "$T/t-space"
fdlink 407 1 "$DEAD_LOG"
out="$(run_reap "$T/t-space" "" -- --apply)"
has "$out" "human-ancestor" "HUMAN-SPACED: a space in the executable path cannot hide the host app"
hasnt "$out" "REAP   root=406" "HUMAN-SPACED: never reaped"
eq "$(cat "$KILL_LOG" 2>/dev/null | wc -l | tr -d ' ')" "0" "HUMAN-SPACED: no signal"

# ── FLEET-PROMPT: a cmux PATH in an ancestor's ARGUMENT is not the fleet boundary ──────────────
echo "== FLEET-PROMPT (fleet is the EXECUTABLE only; argument text decides nothing)"
: > "$T/t-fprompt"; psinit >> "$T/t-fprompt"
psrow 430 1 Ss 00:00:00 10:00:00 "/Applications/Terminal.app/Contents/MacOS/Terminal" >> "$T/t-fprompt"
psrow 431 430 Ss 00:00:00 10:00:00 "zsh -c export PATH=/Applications/cmux.app/Contents/MacOS:$PATH; lane.sh /repo" >> "$T/t-fprompt"
psrow 408 431 Ss 00:00:00 05:00:00 "bash -c pi > $DEAD_LOG 2>&1 &" >> "$T/t-fprompt"
psrow 409 408 Sl 00:00:00 05:00:00 pi >> "$T/t-fprompt"
fdlink 409 1 "$DEAD_LOG"
out="$(run_reap "$T/t-fprompt" "" -- --apply)"
has "$out" "human-ancestor" "FLEET-PROMPT: a cmux path in an ARGUMENT cannot stop the walk"
hasnt "$out" "fleet ancestry" "FLEET-PROMPT: not classified fleet on argument text"
hasnt "$out" "REAP   root=408" "FLEET-PROMPT: the human-owned tree is never reaped"
eq "$(cat "$KILL_LOG" 2>/dev/null | wc -l | tr -d ' ')" "0" "FLEET-PROMPT: no signal"

# ── FLEET: cmux-rooted ancestry is the fleet boundary ───────────────────────────────────────────
echo "== FLEET (a cmux.app ancestor is the fleet, and the lane is judged)"
: > "$T/t-fleet"; psinit >> "$T/t-fleet"
psrow 410 1 Ss 00:00:00 10:00:00 "/Applications/cmux.app/Contents/MacOS/cmux" >> "$T/t-fleet"
psrow 904 410 Ss 00:00:00 05:00:00 "bash -c pi > $DEAD_LOG 2>&1 &" >> "$T/t-fleet"
psrow 905 904 Sl 00:00:00 05:00:00 pi >> "$T/t-fleet"
fdlink 905 1 "$DEAD_LOG"
out="$(run_reap "$T/t-fleet" "" -- --dry-run)"
has "$out" "fleet ancestry" "FLEET: cmux.app is recognised as the fleet boundary"
has "$out" "WOULD REAP root=904" "FLEET: and the stale lane is a candidate"

# ── HUMAN-WIDENED: every terminal a lane's ancestry can actually have is a refusal ─────────────
# ⛔ A LANE UNDER AN UNRECOGNISED HOST APP WAS TERMed (#2163 review, P1). The shipped marker set was
# the macOS-native handful, so a lane under WezTerm / gnome-terminal-server / konsole / ghostty /
# foot / VS Code / code-server / a bare `screen` / a tmux daemonised from init read as `unknown` —
# and `unknown` PERMITTED the kill. Each row below is a terminal this tool previously did not know.
echo "== HUMAN-WIDENED (wezterm/gnome-terminal/konsole/xterm/ghostty/foot/code-server)"
_wid_pid=970
for host in \
  "/opt/homebrew/bin/wezterm-gui start" \
  "/usr/libexec/gnome-terminal-server" \
  "/usr/bin/konsole" \
  "/usr/bin/xterm -e zsh" \
  "/Applications/Ghostty.app/Contents/MacOS/ghostty" \
  "/usr/bin/foot --server" \
  "/usr/bin/code-server --port 8080" ; do
  hpid=$_wid_pid
  _wid_pid=$((_wid_pid + 1))
  : > "$T/t-wid"; psinit >> "$T/t-wid"
  psrow "$hpid" 1 Ss 00:00:00 10:00:00 "$host" >> "$T/t-wid"
  psrow 966 "$hpid" Ss 00:00:00 05:00:00 "bash -c pi > $DEAD_LOG 2>&1 &" >> "$T/t-wid"
  psrow 967 966 Sl 00:00:00 05:00:00 pi >> "$T/t-wid"
  fdlink 967 1 "$DEAD_LOG"
  out="$(run_reap "$T/t-wid" "" -- --apply)"
  has "$out" "human-ancestor" "HUMAN-WIDENED: $host refuses as a HUMAN ancestor"
  hasnt "$out" "REAP   root=966" "HUMAN-WIDENED: $host never reaped"
  eq "$(cat "$KILL_LOG" 2>/dev/null | wc -l | tr -d ' ')" "0" "HUMAN-WIDENED: $host — no signal"
done

# ── SURFACE-TMUX: a multiplexer is the fleet's LAUNCH SURFACE, not a human ─────────────────────
# ⛔ `tmux`/`screen` IN THE HUMAN SET MADE THE FLEET'S OWN LAUNCHER INERT (#2163 review r3, P2).
# `worker-terminal.sh` selects tmux as THE launcher on macOS whenever `cmux tree --json` cannot answer
# (the launchd controller), and a pane's processes descend from the tmux SERVER:
#   * `…/tmux new-session -d -s lane-7`  ⇒ `human-ancestor` ⇒ EVERY lane on that surface refused;
#   * `tmux: server`                     ⇒ `ancestry-unknown` ⇒ the same refusal, one row up.
# The declared consequence named only Linux cells, so the fleet's own macOS launch surface went
# unreported. A multiplexer is transparent: the walk continues THROUGH it.
echo "== SURFACE-TMUX (the tmux launcher is walked THROUGH, not refused as human)"
: > "$T/t-tmux1"; psinit >> "$T/t-tmux1"
psrow 430 400 Ss 00:00:00 10:00:00 "tmux: server" >> "$T/t-tmux1"
psrow 968 430 Ss 00:00:00 05:00:00 "tmux new-session -d -s lane-7" >> "$T/t-tmux1"
psrow 969 968 Ss 00:00:00 05:00:00 "bash -c pi > $DEAD_LOG 2>&1 &" >> "$T/t-tmux1"
psrow 971 969 Sl 00:00:05 05:00:00 pi >> "$T/t-tmux1"
fdlink 971 1 "$DEAD_LOG"
out="$(run_reap "$T/t-tmux1" "" -- --dry-run)"; rc=$?
hasnt "$out" "human-ancestor" "SURFACE-TMUX: the tmux launcher is NOT a human ancestor"
has "$out" "fleet ancestry" "SURFACE-TMUX: the walk passes THROUGH the server to cmux.app above it"
has "$out" "WOULD REAP root=969" "SURFACE-TMUX: so a tmux-launched stale lane IS a candidate (the fleet's launcher is not inert)"
echo "== SURFACE-TMUX-ORPHAN (a server daemonised from init is ancestry-unknown, which refuses)"
: > "$T/t-tmux2"; psinit >> "$T/t-tmux2"
psrow 430 1 Ss 00:00:00 10:00:00 "tmux: server" >> "$T/t-tmux2"
psrow 972 430 Ss 00:00:00 05:00:00 "bash -c pi > $DEAD_LOG 2>&1 &" >> "$T/t-tmux2"
psrow 973 972 Sl 00:00:05 05:00:00 pi >> "$T/t-tmux2"
fdlink 973 1 "$DEAD_LOG"
out="$(run_reap "$T/t-tmux2" "" -- --apply)"; rc=$?
has "$out" "ancestry-unknown" "SURFACE-TMUX-ORPHAN: no fleet evidence above the server ⇒ ancestry-unknown"
hasnt "$out" "human-ancestor" "SURFACE-TMUX-ORPHAN: still never classified as a HUMAN ancestor"
hasnt "$out" "REAP   root=972" "SURFACE-TMUX-ORPHAN: never reaped"
eq "$(cat "$KILL_LOG" 2>/dev/null | wc -l | tr -d ' ')" "0" "SURFACE-TMUX-ORPHAN: no signal"
# ── CELL-TMUX: the cell supervisor's marker is POSITIVE fleet evidence (#2868) ──────────────────
# ⛔ THE CELL-INERT DEFECT. On a Linux cell the launch surface is a systemd unit, not cmux.app, so
# `host_verdict` read every cell lane as `unknown` and the ARMED reaper refused it for ever (the
# CELL-INERT note in this file's header). The supervisor writes TWO markers into every spawned
# process — an environ variable (CONTROLLER_UNIT=…) and the unit's cgroup — and either, read from
# /proc, is fleet evidence. This leg is the SURFACE-TMUX-ORPHAN shape (a tmux server daemonised from
# init) PLUS the marker, and it must now be a CANDIDATE — proving the cell reaper is armed, not
# inert. The environ marker is matched on the variable NAME (any value carries it); the cgroup on
# the unit basename under a slice. A HUMAN sshd ancestor still refuses first (the human checks run
# before this branch), and an unreadable /proc answers NOTHING — neither is asserted here but both
# are pinned by the HUMAN and ANCESTRY-INCOMPLETE legs.
echo "== CELL-TMUX (the cell supervisor marker lifts the fleet's own launcher out of unknown)"
: > "$T/t-cell1"; psinit >> "$T/t-cell1"
psrow 430 1 Ss 00:00:00 10:00:00 "tmux: server" >> "$T/t-cell1"
psrow 974 430 Ss 00:00:00 05:00:00 "bash -c pi > $DEAD_LOG 2>&1 &" >> "$T/t-cell1"
psrow 975 974 Sl 00:00:05 05:00:00 pi >> "$T/t-cell1"
fdlink 975 1 "$DEAD_LOG"
mkdir -p "$PROC/430"
printf 'CONTROLLER_UNIT=eldato-orchestrator.service\0HARNESS_MATERIALISER=/tmp/cell-home\0' > "$PROC/430/environ"
printf '0::/system.slice/eldato-orchestrator.service\n' > "$PROC/430/cgroup"
out="$(run_reap "$T/t-cell1" "" -- --dry-run)"; rc=$?
hasnt "$out" "ancestry-unknown" "CELL-TMUX: the cell marker lifts the tmux server out of unknown"
has "$out" "fleet ancestry" "CELL-TMUX: the cell supervisor is POSITIVE fleet evidence"
has "$out" "WOULD REAP root=974" "CELL-TMUX: a stale cell lane IS a candidate (the cell reaper is armed, not inert)"
echo "== ORPHAN-PARENTLESS (a pi reparented to init is ancestry-unknown, and refuses)"
# ⛔ THE ORPHAN BOUNDARY IS PINNED HERE, NOT ONLY IN PROSE (#2163 review, P2). When the launcher
# wrapper exits, the surviving `pi` is reparented to init and its only ancestor is `/sbin/init`, so
# `host_verdict` reads `unknown` and cmd_reap refuses it for ever — the exact residue #2163 exists to
# remove survives on any box without a fleet marker above the orphan. That is a declared boundary
# (`docs/ops/fleet-liveness.md` §11.4) and NOT a licence to let `unknown` through, so this leg pins
# the refusal: the orphan must not become a kill by accident when someone later widens the marker set.
: > "$T/t-orphan"; psinit >> "$T/t-orphan"
psrow 9601 1 Sl 00:00:00 20:00:00 "pi --model x" >> "$T/t-orphan"
fdlink 9601 1 "$DEAD_LOG"
out="$(run_reap "$T/t-orphan" "" -- --apply)"; rc=$?
has "$out" "ancestry-unknown" "ORPHAN-PARENTLESS: a ppid-1 pi has no fleet evidence ⇒ ancestry-unknown"
hasnt "$out" "REAP   root=9601" "ORPHAN-PARENTLESS: never reaped"
eq "$(cat "$KILL_LOG" 2>/dev/null | wc -l | tr -d ' ')" "0" "ORPHAN-PARENTLESS: no signal"

# ── HUMAN-UNKNOWN: an ancestry that is neither fleet nor a known HUMAN refuses ───────────────────
# ⛔ `unknown` REFUSES (#2163 review, P1). It used to PERMIT, so ANY host app the marker set did not
# name — and any truncation of the table (`ANCESTRY-INCOMPLETE` below) — handed the lane to the kill
# path. The lane is judged on POSITIVE fleet evidence or not at all.
echo "== HUMAN-UNKNOWN (no fleet marker anywhere in the chain => refusal, never a kill)"
: > "$T/t-unk"; psinit >> "$T/t-unk"
# pid 400 is the fixture's cmux.app; override it with a plain daemon so nothing above is fleet.
psrow 400 1 Ss 00:00:00 10:00:00 "/usr/sbin/cron -f" >> "$T/t-unk"
psrow 910 400 Ss 00:00:00 05:00:00 "bash -c pi > $DEAD_LOG 2>&1 &" >> "$T/t-unk"
psrow 911 910 Sl 00:00:00 05:00:00 pi >> "$T/t-unk"
fdlink 911 1 "$DEAD_LOG"
out="$(run_reap "$T/t-unk" "" -- --apply)"; rc=$?
has "$out" "ancestry-unknown" "HUMAN-UNKNOWN: refused as ancestry-unknown"
hasnt "$out" "REAP   root=910" "HUMAN-UNKNOWN: never reaped"
eq "$(cat "$KILL_LOG" 2>/dev/null | wc -l | tr -d ' ')" "0" "HUMAN-UNKNOWN: --apply signals NOTHING"
# ⛔ A PASS THAT JUDGED NOTHING IS NOT A CLEAN PASS (#2163 review r3, P2): the only tree here is a
# real lane (it has a resolved lane log) refused by POLICY, so `inert=1` and a non-zero exit. It is
# rc 4 (a POLICY verdict), NOT rc 3 — see the INERT leg above (#2163 review r8, P1).
has "$out" "inert=1" "HUMAN-UNKNOWN: the policy refusal is COUNTED (inert=)"
has "$out" "trees=0/0" "HUMAN-UNKNOWN: no tree was judged"
eq "$rc" "4" "HUMAN-UNKNOWN: a pass that judged zero trees while refusing a lane exits 4 (policy), never 0"

# ── ANCESTRY-INCOMPLETE: a truncated process table is not "no human above" ───────────────────────
# ⛔ The walk broke out on a ppid row that was missing and `host_verdict` read the resulting empty
# command as "no marker" — a FAIL-OPEN on an unreadable table, the exact input `cloud-cell-doctor.sh`
# already refuses (`human_above` returns 2 and skips). The lane here hangs off pid 777, which is not
# in the table at all.
echo "== ANCESTRY-INCOMPLETE (a lost ppid row is an abstention, not a permission)"
: > "$T/t-inc"; psinit >> "$T/t-inc"
psrow 920 777 Ss 00:00:00 05:00:00 "bash -c pi > $DEAD_LOG 2>&1 &" >> "$T/t-inc"
psrow 921 920 Sl 00:00:00 05:00:00 pi >> "$T/t-inc"
fdlink 921 1 "$DEAD_LOG"
out="$(run_reap "$T/t-inc" "" -- --apply)"
has "$out" "ancestry-unreadable" "ANCESTRY-INCOMPLETE: refused as ancestry-unreadable"
hasnt "$out" "REAP   root=920" "ANCESTRY-INCOMPLETE: never reaped"
eq "$(cat "$KILL_LOG" 2>/dev/null | wc -l | tr -d ' ')" "0" "ANCESTRY-INCOMPLETE: --apply signals NOTHING"

# ── ACTIVE: any CPU gain across the window spares the lane ──────────────────────────────────────
echo "== ACTIVE (a subtree that gains CPU is working, not finished)"
: > "$T/t-act1"; psinit >> "$T/t-act1"
psrow 500 400 Ss 00:00:00 05:00:00 "bash -c cd /repo; pi -p x > $DEAD_LOG 2>&1 &" >> "$T/t-act1"
psrow 501 500 Sl 00:00:05 05:00:00 pi >> "$T/t-act1"
fdlink 501 1 "$DEAD_LOG"
: > "$T/t-act2"; psinit >> "$T/t-act2"
psrow 500 400 Ss 00:00:00 05:00:00 "bash -c cd /repo; pi -p x > $DEAD_LOG 2>&1 &" >> "$T/t-act2"
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

# ── COUNT-NO-EVIDENCE: a census that cannot read a descriptor abstains ──────────────────────────
# ⛔ THE MEASURED FAIL-OPEN (#2163 review, P0). `count` printed `lanes=0/0 zombie=<n>` with exit 0
# when NO tree's descriptor could be read (no /proc and no `lsof`, or `lsof -p` denied) — every tree
# fell out of BOTH `live` and `total` and left no trace. `orch-loop.sh` then reads a clean `0`:
# `LANES_UNKNOWN` stays 0, the `lanes_unknown` refusal never fires, the `MAX_LANES` test is false, and
# the controller DISPATCHES MORE onto a box whose capacity it cannot see (the #2159 OOM direction).
# The population comes from `ps`, but liveness comes from a descriptor — so a blind box says `?`.
echo "== COUNT-NO-EVIDENCE (a blind census is ?/?, never a confident 0/0)"
out="$(REAP_PROC_ROOT_OVERRIDE=/nonexistent/proc REAP_LSOF_OVERRIDE=/nonexistent/lsof run_count "$T/t-count")"; rc=$?
eq "$rc" "3" "COUNT-NO-EVIDENCE: an unreadable descriptor instrument exits 3"
eq "$out" "lanes=?/? zombie=2" "COUNT-NO-EVIDENCE: never 0/0 on a live fleet (zombie= is still readable)"
# …and the answer is not "0/0 is always wrong": with the instrument working, a tree whose
# descriptors WERE read and hold no fleet log is simply not a lane.
out="$(run_count "$T/t-count")"; rc=$?
eq "$rc" "0" "COUNT-NO-EVIDENCE: a readable instrument still produces a clean census"
eq "$out" "lanes=1/2 zombie=2" "COUNT-NO-EVIDENCE: …and the non-lane tree (fd on a pipe) is excluded, not abstained"

# ── FALLBACK: the no-timeout(1) path macOS takes, and an unkillable ps read ────────────────────
echo "== FALLBACK (bound() without timeout(1), and a read that must be cut)"
out="$(LANE_REAP_TIMEOUT_BIN=/nonexistent/tmux-timeout run_count "$T/t-count")"; rc=$?
eq "$rc" "0" "FALLBACK: count still exits 0 through the shell watchdog"
eq "$out" "lanes=1/2 zombie=2" "FALLBACK: the fallback runs the read and returns its OUTPUT"
printf '#!/usr/bin/env bash\nsleep 30\n' > "$T/bin/ps-hang"
chmod +x "$T/bin/ps-hang"
rm -f "$T/ps.counter"
out="$(PS_HANG=1 PS_TABLE1="$T/t-count" PS_COUNTER="$T/ps.counter" PATH="$T/bin:$PATH" \
       LANE_REAP_PS_BIN="$T/bin/ps-hang" LANE_REAP_PROC_ROOT="$PROC" LANE_REAP_NOW="$NOW" \
       LANE_REAP_TIMEOUT_BIN=/nonexistent/tmux-timeout LANE_REAP_READ_TIMEOUT=1 \
       LANE_REAP_LOG="$T/state/lane-reap.log" LANE_REAP_LOCK="$T/state/lane-reap" \
       bash "$REAPER" count)"; rc=$?
eq "$rc" "3" "FALLBACK: a read that outlives its bound exits 3"
eq "$out" "lanes=?/? zombie=?" "FALLBACK: and never renders as an empty fleet"

# ── COUNT-ARMS: a deleted log is possibly-live, and an unreadable age must not abort the pass ──
echo "== COUNT-ARMS (deleted log counts as live; unreadable age is a ? numerator, in any lane order)"
: > "$T/t-count2"; psinit >> "$T/t-count2"
psrow 600 1 Ss 00:00:00 05:00:00 "bash -c pi > /tmp/L-gone.log 2>&1" >> "$T/t-count2"
psrow 601 600 Sl 00:00:01 05:00:00 pi >> "$T/t-count2"
fdlink 601 1 "/tmp/L-gone.log (deleted)"
out="$(run_count "$T/t-count2")"; rc=$?
eq "$out" "lanes=1/1 zombie=0" "COUNT-ARMS: a deleted-log lane counts as LIVE (a possibly-live lane holds a slot)"
eq "$rc" "0" "COUNT-ARMS: and the census is not an abstention"
GHOST="$(newlog L-unreadable.log 30)"
: > "$T/t-count3"; psinit >> "$T/t-count3"
psrow 500 1 Ss 00:00:00 05:00:00 "bash -c pi > $T/gone-dir/L-ghost.log 2>&1" >> "$T/t-count3"
psrow 501 500 Sl 00:00:01 05:00:00 pi >> "$T/t-count3"
# ⛔ the PARENT directory is absent, so `-e` is false but deletion cannot be POSITIVELY established
# (an unlinked fd in a readable dir is the deleted arm above) — this is the unreadable-age shape.
fdlink 501 1 "$T/gone-dir/L-ghost.log"
psrow 700 1 Ss 00:00:00 05:00:00 "bash -c pi > $GHOST 2>&1" >> "$T/t-count3"
psrow 701 700 Sl 00:00:01 05:00:00 pi >> "$T/t-count3"
fdlink 701 1 "$GHOST"
out="$(run_count "$T/t-count3" 2>&1)"; rc=$?
eq "$rc" "3" "COUNT-ARMS: an unreadable age exits 3"
eq "$out" "lanes=?/2 zombie=0" "COUNT-ARMS: the numerator is ? while the TOTAL survives; no arithmetic abort"
hasnt "$out" "syntax error" "COUNT-ARMS: the pass never aborts on a ? numerator"

# ── ABSTAINED: a pass that could judge nothing is not an idle pass ──────────────────────────────
# ⛔ `-` (#2163 review, P2). A `live_unknown=1` (a negative CPU delta) was ASSIGNED AND NEVER READ,
# and `log-age-unreadable` / `no-log-age-unreadable` incremented NO counter, so a pass that abstained
# on every lane reported `reaped=0 refused=0` and exited 0. `cloud-cell-doctor.sh` escalates only on a
# literal `CANNOT-VERIFY`, so a silently abstaining reaper was indistinguishable from an idle one.
echo "== ABSTAINED (a safety read that failed is counted, printed, and is exit 3)"
: > "$T/t-abst"; psinit >> "$T/t-abst"
# the lane's log is at a path whose PARENT does not exist: deletion cannot be established and the
# mtime cannot be read — the `log-age-unreadable` abstention (a live, working-shaped lane).
psrow 110 400 Ss 00:00:00 05:00:00 "bash -c pi > $T/gone-dir2/L-abst.log 2>&1" >> "$T/t-abst"
psrow 111 110 Sl 00:00:01 05:00:00 pi >> "$T/t-abst"
fdlink 111 1 "$T/gone-dir2/L-abst.log"
out="$(run_reap "$T/t-abst" "" -- --dry-run)"; rc=$?
has "$out" "log-age-unreadable" "ABSTAINED: the lane is named as unjudgeable"
has "$out" "abstained=1" 'ABSTAINED: the human line COUNTS it (reaped=0 refused=0 is not "nothing happened")'
has "$out" "trees=1/1" "ABSTAINED: and the judged tree is still accounted for in trees=<working>/<judged>"
eq "$rc" "3" "ABSTAINED: the pass exits 3 so an exit-code consumer cannot read it as idle"
out="$(run_reap "$T/t-abst" "" -- --dry-run --json)"
has "$out" '"abstained":1' "ABSTAINED: --json carries the counter too"

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
