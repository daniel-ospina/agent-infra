#!/usr/bin/env bash
# watchdog-loop.sh — the CONTROLLER WATCHDOG: notice a controller that is ALIVE BUT NOT CYCLING,
# restart it ONCE, and stop restarting when the restart cannot help.
#
# ⛔ WHY THIS EXISTS (measured 2026-10-21 on this box). The controller was up and wedged for a full
# hour. `launchctl` said the job was loaded, `harness.sh verify` said GREEN, and the supervisor logged
# `controller pid 98243 is alive but the heartbeat is 3652s old (limit 780s)` every 30 s — while it
# restarted the stack into the SAME crash (a macOS bash 3.2 parse failure, agent-infra#2248) and the
# fleet dispatched NOTHING. A predicate of "the pid exists" cannot see this state; and restarting
# harder cannot fix it either. What is missing is the DIFFERENCE between DOWN and WEDGED, and a
# refusal to loop: the one thing that would have named the cause in the first minute is the
# controller's own last output, which every restart erased.
#
# CONTRACT (this file is the implementation of it, and watchdog-loop.test.sh pins it):
#   heartbeat FRESH + pid alive → HEALTHY   (no action, nothing touched; the streak is cleared)
#   heartbeat FRESH + NO pid    → UNCERTAIN (the heartbeat proves the loop IS cycling, so it is NOT
#                                            restarted — killing a cycling controller on a bookkeeping
#                                            miss is the P0 — but it is not HEALTHY either: the
#                                            contract requires a pid. The streak is NOT cleared, because
#                                            a crash-on-start also starts with a fresh heartbeat.)
#   pid alive + hb STALE        → WEDGED    (ONE restart, then re-check after SETTLE)
#   no pid    + hb STALE        → DOWN      (ONE restart)
#   hb absent / not an instant  → DOWN      (NEVER healthy: an absent datum is not a fresh one; and it
#                                            is never dated from the file's mtime, which `touch` renews)
#   N consecutive restart-worthy observations (WEDGED *or* DOWN) → <VERDICT>_STOPPED: restarting stops
#                                            for that EPISODE and ONE crash record block is written,
#                                            quoting the last lines of the controller's own log (which
#                                            path that is, is RESOLVED — see ctrl_stdout_path).
#                                            A crash-on-start leaves no pid, so DOWN is capped too — a
#                                            cap that only covered WEDGED restarted that forever.
#                                            ⛔ THE LATCH IS BOUNDED, NOT PERMANENT: after a further N
#                                            stopped observations ONE probe restart is allowed WITHIN THE
#                                            SAME EPISODE (the budget stays spent — a genuinely dead box
#                                            must not stay dead for ever because a crash was recorded
#                                            once). MEASURED steady state at N=3 over 15 passes: 3
#                                            initial restarts, then one probe per 4 passes (≈20 min at a
#                                            300s cadence). The episode's crash record is written once;
#                                            a NEW episode (and block) needs a HEALTHY pass.
#
# ⛔ EXIT 0 ALWAYS. A watchdog that dies loudly into a log nobody reads is worse than none: the
# failure would land in a datum only a human already suspecting something would look at. ⛔ NOT
# because "nobody reads launchd's last-exit-status" — that was the original rationale and it is
# FALSE: `scripts/lib/fleet-inventory.sh` reads it (`fleet_job_exit`, the `controller-watchdog` row)
# and reports `FAILING` for a non-zero exit. The reason to exit 0 is different and still holds: a
# non-zero exit here would be a watchdog CRASH reported as a WATCHDOG VERDICT, i.e. the fleet would
# read "the watchdog failed" when what actually happened is "the controller is wedged" — and the
# verdict is already in $LOG. The decision belongs in the log, not in the exit code.
# The VERDICT is the output — one line per decision, in $LOG, bounded — and `--status` reprints it.
#
# ⛔ IT IS NOT THE SUPERVISOR. `supervisor.sh` keeps each PROCESS at exactly one instance and REPORTS a
# wedged controller; it already logs the wedge and deliberately does not act on it (a live controller
# may be mid-merge, and P0 taste says don't kill what you cannot prove is stuck). This file acts, on a
# different datum and at a different cadence, and its whole safety comes from being bounded: one
# restart per observation, a re-check afterwards, and a stop after N consecutive wedges.
#
# PLATFORM. macOS: the controller job is launchd's (`launchctl kickstart -k gui/<uid>/<label>`).
# Linux cell: there is no launchd and no KeepAlive — a cell's controller is launched by
# `cloud-cell-supervisor.sh start`, which is exactly the verb its own doctor role uses, so that is the
# restart this file runs there. Neither branch is invented here; both are the box's existing owner.
#
# Usage:
#   watchdog-loop.sh            one pass (the launchd job's StartInterval entry point)
#   watchdog-loop.sh --status   print the last decision lines and exit (dispatches nothing)
#
# Env (every value validated below; a bad one falls back rather than aborting the arithmetic):
#   O             state dir of the stack (default: $HOME/orchestrator)
#   HB            heartbeat file        (default: $O/heartbeat)
#   HB_STALE      fresh window, seconds (default: 780 — the supervisor's own limit)
#   SETTLE        re-check delay after a restart (default: 60)
#   MAX_CONSEC    consecutive WEDGED/DOWN observations before restarting STOPS (default: 3; < 1 is
#                 rejected and named — 0 meant "never restart" while the cap fired immediately)
#   LABEL         macOS launchd label of the stack job (default: com.eldato.orchestrator-stack)
#   SUPERVISOR    Linux restart verb (default: $O/cloud-cell-supervisor.sh, else this dir's sibling)
#   WATCHDOG_STATE_DIR / WATCHDOG_LOG  state + decision log (default: $HOME/.pi/agent/state[/controller-watchdog.log])
# ⛔ AN UNWRITABLE STATE DIR DISABLES RESTARTING, BY DESIGN. The cap is a count on disk; when it cannot
# be kept, restarting is treated as EXHAUSTED and `PERSIST-FAILED` is logged on every pass THAT CAN BE
# LOGGED — the decision log lives inside the state dir, so a fully unwritable dir loses it too and the
# verdict then reaches only stdout, which launchd captures at /tmp/controller-watchdog.launchd.err. That is the
# fail-closed arm: restarting on a counter that never advances is the tight loop this file exists to
# prevent. A probe whose own write fails is NOT issued. The one degradation is evidence: with only the
# episode file unwritable, a second crash is deduped (recorded once, not twice).
#   WATCHDOG_RESTART_CMD  replace the platform restart with this command (TESTS ONLY)
#   WATCHDOG_NO_RESTART   never invoke the platform restart verb (TESTS ONLY)
#   WATCHDOG_SLEEP_BIN    `sleep` seam (TESTS ONLY)
set -uo pipefail

O="${O:-$HOME/orchestrator}"
HB="${HB:-$O/heartbeat}"
LABEL="${LABEL:-com.eldato.orchestrator-stack}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)"
# Explicit override only; the DEFAULT is resolved against the files the shipped producers write — see
# ctrl_stdout_path below for why the old default ($O/logs/controller-stdout.log) was the wrong guess.
CTRL_STDOUT="${CTRL_STDOUT:-}"

# ── numeric bounds. ⛔ A non-number is not a small number: `[ "$age" -le abc ]` errors, and the
# `if` then takes the FALSE arm — i.e. a typo in HB_STALE would declare a healthy controller wedged
# and restart it every tick. Leading zeros are rejected too: `$(( ))` reads them as OCTAL on the
# /bin/bash 3.2 this box runs. Every one falls back to its documented default and says so in $LOG.
num_ok() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; 0) return 0 ;; 0*) return 1 ;; *) [ "${#1}" -le 9 ] ;; esac; }
_bad=""
for _v in HB_STALE SETTLE MAX_CONSEC; do
  eval "_cur=\${$_v:-}"
  [ -n "$_cur" ] && { num_ok "$_cur" || _bad="$_bad $_v=$_cur"; }
done
HB_STALE="${HB_STALE:-780}"; num_ok "$HB_STALE" || HB_STALE=780
SETTLE="${SETTLE:-60}";       num_ok "$SETTLE"   || SETTLE=60
MAX_CONSEC="${MAX_CONSEC:-3}"; num_ok "$MAX_CONSEC" || MAX_CONSEC=3
# ⛔ ZERO IS NOT A SETTING. `MAX_CONSEC=0` used to be accepted, which meant "never restart" — and then
# the cap fired on the FIRST observation and recorded a crash for a restart that was never attempted,
# i.e. the one action this job exists to take was disabled by a value that looks like a tightening.
# Anything below 1 falls back to 3 and is NAMED in BOUND-FALLBACK.
[ "$MAX_CONSEC" -ge 1 ] || { _bad="$_bad MAX_CONSEC=$MAX_CONSEC(<1)"; MAX_CONSEC=3; }

STATE_DIR="${WATCHDOG_STATE_DIR:-$HOME/.pi/agent/state}"
LOG="${WATCHDOG_LOG:-$STATE_DIR/controller-watchdog.log}"
STREAK_FILE="$STATE_DIR/controller-watchdog.streak"
CRASH_FILE="$STATE_DIR/controller-watchdog.crash"
# ⛔ AN EPISODE COUNTER, because "record it once" and "record every crash" are the same requirement
# seen from two sides. A streak that reaches 0 and starts again is a NEW crash loop — its evidence may
# be different (a different syntax error), so writing the file only `if absent` would leave the durable
# record naming the FIRST crash for ever while a second, different one was never captured. Each new
# streak increments the episode; the crash file records the episode it belongs to; a pass that finds
# its own episode already there does not rewrite it.
EPISODE_FILE="$STATE_DIR/controller-watchdog.episode"
# Which episode the crash record already covers. ⛔ NOT a grep over $CRASH_FILE: the record's body is
# the controller's own output, so a log line containing `episode=7` made the dedupe read back the
# WRONG episode and the file grew one block per stopped pass (measured in review: 3 blocks for one
# episode, 288/day at a 300s cadence, and the crash file — unlike the decision log — is never rotated).
CRASH_EPISODE_FILE="$STATE_DIR/controller-watchdog.crash-episode"
# The decision log is APPEND-ONLY and read by humans and by `--status`, so it is TRUNCATED once it
# passes this size (the same shape as the branch reaper's report log). 1 MiB is ~5,000 decision lines
# at ~200 bytes: months of passes, and it cannot grow without bound on a box nobody prunes.
LOG_MAX_BYTES="${WATCHDOG_LOG_MAX_BYTES:-1048576}"
num_ok "$LOG_MAX_BYTES" || { _bad="$_bad WATCHDOG_LOG_MAX_BYTES=$LOG_MAX_BYTES"; LOG_MAX_BYTES=1048576; }
# ⛔ THE FALLBACK IS SAID OUT LOUD. `_bad` used to be accumulated and never read, so a typo'd
# HB_STALE silently became 780 — an operator's "raise the window" then edits a value the script
# ignores invisibly, which is worse than refusing. It is logged on every pass that carries one, and
# this is also why LOG_MAX_BYTES is validated: an unvalidated bound made `[ "$sz" -le abc ]` error and
# the `&&` false arm TRUNCATED the decision log on every pass (measured in review).
SLEEP_BIN="${WATCHDOG_SLEEP_BIN:-sleep}"

now_iso() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
# One line per decision: tab-separated so `status`, awk and a human all read it, and the verb is in
# the SECOND field so a `grep -w WEDGED` cannot match a sentence about one.
log_line() {
  local line
  line="$(now_iso)"$'\t'"$*"
  # ⛔ stderr is silenced BEFORE the append: redirections apply left to right, so `>> "$LOG" 2>/dev/null`
  # reports the OPEN failure to the shell's stderr first — one bash diagnostic per pass into the
  # launchd capture, which is the surface that is supposed to hold only a pre-logging death.
  # ⛔ AND THE LOG IS INSIDE THE STATE DIR, so the unwritable-state-dir case would otherwise leave the
  # verdict nowhere but stdout. The stderr fallback puts it where launchd does capture it (/tmp).
  printf '%s\n' "$line" 2>/dev/null >> "$LOG" || printf '%s\n' "$line" >&2
  printf '%s\n' "$line"
}
# Rotate BEFORE the append that would exceed the bound, and never silently: a log that vanished
# without a line saying so is indistinguishable from a watchdog that stopped running.
rotate_log() {
  [ -f "$LOG" ] || return 0
  local sz
  # ⛔ `wc -c < f` is PADDED on some platforms (`sz='    2000'`), and a padded value hits the
  # non-numeric guard below and silently disables rotation for ever — measured in this file's own
  # suite (case 6) before the strip was added.
  sz="$(wc -c < "$LOG" 2>/dev/null | tr -d '[:space:]')" || return 0
  case "${sz:-}" in ''|*[!0-9]*) return 0 ;; esac
  [ "$sz" -le "$LOG_MAX_BYTES" ] && return 0
  : > "$LOG" 2>/dev/null || return 0
  log_line "verdict=LOG-ROTATED"$'\t'"note=previous lines dropped at ${sz}B (bound ${LOG_MAX_BYTES}B)"
}

# ── the two READINGS, and neither may claim health it did not observe ───────────────────────────
# hb_age — seconds since the controller's last heartbeat, or the literal `missing`.
# ⛔ `missing` covers: no file, not a regular file, no usable instant, an instant in the future beyond
# the 60 s skew band, and a mtime that could not be stat'ed. All of them are "UNKNOWN", and the caller
# maps UNKNOWN to DOWN — deliberately the SAFE polarity here (unlike the supervisor, which reports
# UNKNOWN and touches nothing): this file's only action is a restart, and refusing to restart a
# controller whose own liveness record cannot be read is how the measured hour was spent.
hb_age() {
  local f="$HB" v now
  [ -e "$f" ] || { printf 'missing\n'; return 0; }
  [ -f "$f" ] || { printf 'missing\n'; return 0; }
  now="$(date +%s)"
  # tr strips everything non-numeric, so a garbage file yields the empty string => UNKNOWN (below)
  v="$(tr -dc '0-9' < "$f" 2>/dev/null)" || v=""
  if [ -n "$v" ]; then
    [ "${#v}" -le 12 ] || v=""
  fi
  # ⛔ NO mtime FALLBACK. Deriving freshness from the file's mtime makes "health" renewable by
  # anything that touches the path — a `cp`, a restore, an editor, a log rotation — so a wedged
  # controller would read healthy for HB_STALE seconds after any of them. The heartbeat's CONTENT is
  # the instant the loop itself wrote; if it carries no usable instant, the age is UNKNOWN, and the
  # caller maps UNKNOWN to DOWN (never healthy). A datum that can be forged by `touch` is not a datum.
  [ -n "$v" ] || { printf 'missing\n'; return 0; }
  # ⛔ FORCE DECIMAL, THEN REQUIRE A PLAUSIBLE EPOCH — the same three guards launchd-cycle.sh:310-327
  # already carries, and their absence here was a real hazard: `tr -dc '0-9'` happily yields a
  # leading-zero run (`01760000000`), and `/bin/bash` 3.2 reads that as OCTAL in `$(( ))`, so
  #   * the filed value is not the instant that was read, and
  #   * `$(( now - v ))` produces a ~1.5e9 age from a controller that is cycling normally.
  # An all-zero run (`0000000000`, the same thing an empty-ish write looks like) passes the future
  # check and yields `now - 0` — a fabricated age of the whole epoch. Either one asserts WEDGED on a
  # HEALTHY controller, which here is not a label: it is a restart, a durable crash record, and a
  # probe restart later. They are all "UNKNOWN", and the caller already maps that to DOWN.
  # `10#$v` is harmless when v has no leading zero, so this cannot reject a legitimate reading.
  v=$(( 10#$v ))
  [ "$v" -ge 1000000000 ] || { printf 'missing\n'; return 0; }   # before 2001-09-09: not an instant
  [ "$v" -le "$(( now + 60 ))" ] || { printf 'missing\n'; return 0; }
  # ⛔ AN AGE IS SECONDS SINCE THE WRITE, so it can never be negative: inside the tolerated 60 s skew
  # band `now - v` underflows, and the decision line then reads "heartbeat -29s old" for a value
  # documented as an age. The band stays (a small future skew is a clock wobble, not corruption) and
  # the answer is clamped: "written within the last moment".
  v=$(( now - v ))
  [ "$v" -ge 0 ] || v=0
  printf '%s\n' "$v"
}

# ctrl_stdout_path — WHERE the controller's own output actually IS, as far as anything on this box can
# say. ⛔ THE OLD DEFAULT NAMED A FILE NO PRODUCER IN THIS REPO WRITES (`$O/logs/controller-stdout.log`:
# outside this script and the test that manufactures it, the literal appears nowhere — there is no
# producer behind it). The shipped producers write:
#   $O/logs/launchd.err / launchd.out  — the controller JOB's declared StandardOutPath/ErrorPath
#                                        (scripts/orchestrator-harness/launchd.plist.template:21-23);
#                                        a crash-on-start lands in .err
#   $O/logs/controller.log            — the cell supervisor's `tee` of the controller's output
#                                        (scripts/cloud-cell-supervisor.sh:1985)
#   $O/logs/orch-loop.log             — the loop's own append-only log
# A crash record quoting a path that is never written is a record that ALWAYS says "unreadable or
# absent" — the one piece of evidence this file exists to preserve, lost exactly when it matters. So:
# an explicit CTRL_STDOUT wins (test seam, or an operator pointing it at a real capture); otherwise the
# first READABLE shipped path; otherwise launchd's stderr, which is the shape a crash-on-start takes —
# and the record names whichever path that was, so a reader can tell "nothing was logged" from "the
# watchdog looked somewhere else".
ctrl_stdout_path() {
  local f
  [ -n "${CTRL_STDOUT:-}" ] && { printf '%s\n' "$CTRL_STDOUT"; return 0; }
  for f in "$O/logs/launchd.err" "$O/logs/launchd.out" "$O/logs/controller.log" \
           "$O/logs/orch-loop.log" "$O/logs/controller-stdout.log"; do
    [ -r "$f" ] && { printf '%s\n' "$f"; return 0; }
  done
  printf '%s\n' "$O/logs/launchd.err"
}

# controller_pid — the controller's pid, or EMPTY. Two sources, in order: the lock the controller
# itself holds ($O/.orch.lock — the supervisor stops the controller through it, so it is the fleet's
# own record of "the controller pid") and, failing that, a process-table scan. A pid found either way
# must still be ALIVE, and (when its command line is readable) must still BE the loop: a recycled pid
# is the failure mode both sources share, and restarting on a recycled pid restarts a healthy stack.
pid_is_controller() {
  local pid="$1" cmd=""
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  if [ -r "/proc/$pid/cmdline" ]; then
    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
  fi
  [ -n "$cmd" ] || cmd="$(ps -o command= -p "$pid" 2>/dev/null)"
  # An UNREADABLE command line is not evidence of a recycled pid — fall back to "alive", because
  # treating it as dead would restart a live controller on a box where `ps` is denied.
  [ -z "$cmd" ] && return 0
  case "$cmd" in *orch-loop.sh*) return 0 ;; esac
  return 1
}
controller_pid() {
  local pid=""
  if [ -f "$O/.orch.lock" ] && [ -r "$O/.orch.lock" ]; then
    pid="$(tr -dc '0-9' < "$O/.orch.lock" 2>/dev/null)"
    [ "${#pid}" -le 9 ] || pid=""
  fi
  case "${pid:-}" in ''|*[!0-9]*) pid="" ;; esac
  if [ -n "$pid" ] && pid_is_controller "$pid"; then printf '%s\n' "$pid"; return 0; fi
  # The lock is absent, unreadable, or names a pid that is not this controller. Scan, newest first is
  # meaningless here — there must be at most ONE, so the first match is the one the fleet has.
  # ⛔ TWO SCOPES, because the controller's argv carries a DIFFERENT path on each platform: a Mac
  # launchd job runs `bash __O__/orch-loop.sh` (launchd.plist.template:10), while a cell's supervisor
  # runs `bash '<harness>/orch-loop.sh'` (cloud-cell-supervisor.sh:1985 — the same measurement the
  # inventory records in fleet-inventory.sh's two-scope controller row). A single `$O`-scoped scan
  # therefore could not see a cell's controller AT ALL, so WEDGED was unreachable there: a live but
  # frozen controller read as DOWN, and every pass issued a restart. The second pattern is THIS
  # script's own sibling — the harness dir the cell pins — not a guess at an operator's path.
  local pat
  for pat in "bash ${O}/orch-loop.sh" "bash ${SELF_DIR}/orch-loop.sh"; do
    [ -n "$pat" ] || continue
    pid="$(pgrep -f "$pat" 2>/dev/null | head -1)"
    [ -n "$pid" ] && pid_is_controller "$pid" && { printf '%s\n' "$pid"; return 0; }
  done
  printf '\n'
}

# ── the restart, per platform. ONE verb, the box's own owner ─────────────────────────────────────
restart_stack() {
  local rc=0
  if [ -n "${WATCHDOG_RESTART_CMD:-}" ]; then
    # TESTS ONLY: an exact stand-in for the platform verb, so every case is driven hermetically.
    if [ -x "$WATCHDOG_RESTART_CMD" ]; then "$WATCHDOG_RESTART_CMD" >>"$LOG" 2>&1 || rc=$?
    else sh -c "$WATCHDOG_RESTART_CMD" >>"$LOG" 2>&1 || rc=$?; fi
    return "$rc"
  fi
  # ⛔ A TEST THAT FORGETS A STUB MUST NOT REACH THE LIVE PLATFORM VERB. The suite sets this after a
  # real `launchctl kickstart -k` was issued by a case that omitted its restart seam — restarting the
  # live stack from a unit test is exactly the P0 the watchdog exists to bound, so the suppression is
  # IN THE PRODUCT and not only in the test's discipline. It sits AFTER the stub seam on purpose: a
  # stub IS the restart under test, and suppressing it would make every restart assertion vacuous.
  if [ -n "${WATCHDOG_NO_RESTART:-}" ]; then
    log_line "verdict=RESTART-SUPPRESSED"$'\t'"note=WATCHDOG_NO_RESTART is set — the platform restart verb was NOT invoked"
    return 0
  fi
  case "$(uname -s 2>/dev/null)" in
    Darwin)
      if ! command -v launchctl >/dev/null 2>&1; then rc=127
      else launchctl kickstart -k "gui/$(id -u)/$LABEL" >>"$LOG" 2>&1 || rc=$?; fi ;;
    *)
      # ⛔ NOT a second launcher and NOT a systemd unit invented here: on a cell the controller is
      # started by the cell supervisor, and `start` is the SAME verb the doctor role runs to bring
      # one back (cloud-cell-doctor.sh's controller arm). If the supervisor is not on this box, say so
      # and change nothing — a watchdog that invents its own launch path races the real one.
      local sup="${SUPERVISOR:-}"
      [ -n "$sup" ] || { [ -f "$O/cloud-cell-supervisor.sh" ] && sup="$O/cloud-cell-supervisor.sh"; }
      [ -n "$sup" ] || { [ -f "$SELF_DIR/../cloud-cell-supervisor.sh" ] && sup="$SELF_DIR/../cloud-cell-supervisor.sh"; }
      if [ -n "$sup" ] && [ -f "$sup" ]; then
        # ⛔ PIN `ORCH_FOREGROUND=0` (review P2, #2402). A watchdog that itself runs INSIDE a service-managed
        # controller's environment inherits `Environment=ORCH_FOREGROUND=1` from the unit (it is exported into
        # the whole controller tree, and a tmux server started by that controller carries it to every lane
        # shell). Inherited, `start` takes the FOREGROUND branch: it parks inside the handover wait for up to
        # CONTROLLER_HANDOVER_TIMEOUT instead of delegating to the unit — the same inheritance the doctor pins
        # against, at a call site the doctor's pin cannot reach.
        ORCH_FOREGROUND=0 bash "$sup" start >>"$LOG" 2>&1 || rc=$?
      else
        rc=127
        log_line "verdict=RESTART-UNAVAILABLE"$'\t'"note=no $O/cloud-cell-supervisor.sh and no SUPERVISOR set — nothing was restarted"
      fi ;;
  esac
  return "$rc"
}

# ── the crash record: ONE durable line, written ONCE, never erased by a restart ─────────────────
# It has to survive the restart that produced it, so it lives outside the controller's own logs and is
# never deleted here — only a human (or the operator's own rotation) removes it, and the decision log
# names where it is on every pass that finds it.
record_crash() { # <verdict-token> <pid> <age> <streak> <episode>
  local verdict="$1" pid="$2" age="$3" streak="$4" episode="$5" signature="" recorded="" src=""
  # ONCE PER EPISODE, not once per file: a crash loop that ended and a different one that started are
  # two facts, and the second must not be lost behind the first (measured in review: the record still
  # named CRASH ONE through a completely different second crash loop).
  recorded="$(cat "$CRASH_EPISODE_FILE" 2>/dev/null)"
  [ -n "$recorded" ] && [ "$recorded" = "$episode" ] && return 0
  # The signature is the LAST line of the filtered tail that actually looks like an error, because a
  # crash's cause is usually ONE line and the tail below is 25. `tail -n 1` of a filtered tail, not a
  # grep over the whole file: the whole file is the history, and the crash is the END of it — so the
  # LAST error-looking line is the one nearest the crash, which is the `tail -n 1` this does.
  src="$(ctrl_stdout_path)"
  if [ -r "$src" ]; then
    signature="$(tail -n 200 "$src" 2>/dev/null \
      | grep -iE 'error|syntax|traceback|fatal|unbound|not found|No such file' 2>/dev/null \
      | tail -n 1)"
  fi
  mkdir -p "$(dirname "$CRASH_FILE")" 2>/dev/null
  [ -f "$CRASH_FILE" ] || : 2>/dev/null > "$CRASH_FILE"
  {
    printf '%s\tverdict=%s_STOPPED\tpid=%s\theartbeat=%ss\tstreak=%s/%s\trestart=0\tepisode=%s\tcrash=%s\n' \
      "$(now_iso)" "$verdict" "${pid:-none}" "$age" "$streak" "$MAX_CONSEC" "$episode" "$CRASH_FILE"
    printf 'cause: %s\n' "${signature:-<no error-looking line in the last 200 lines>}"
    printf -- '--- last 25 lines of %s ---\n' "$src"
    tail -n 25 "$src" 2>/dev/null || printf '(unreadable or absent)\n'
  # ⛔ APPEND per episode, TRUNCATE only when there is no record yet: a second crash loop's evidence
  # must not replace the first, and `>` here did exactly that (measured in review).
  } 2>/dev/null >> "$CRASH_FILE" || return 0
  # ⛔ BOUNDED even across episodes: the record is evidence, not an archive. Past 64 KiB the OLDEST
  # episodes are dropped so a long-lived crash loop cannot fill the state dir — the most recent evidence
  # is what a human needs, and the decision log keeps the timeline.
  local sz
  sz="$(wc -c < "$CRASH_FILE" 2>/dev/null | tr -d '[:space:]')"
  case "${sz:-}" in ''|*[!0-9]*) ;; *)
    if [ "$sz" -gt 65536 ]; then
      # `sed 1d` drops the PARTIAL first line the byte cut leaves behind, so the oldest retained block
      # at least starts on a line boundary instead of mid-sentence.
      tail -c 32768 "$CRASH_FILE" 2>/dev/null | sed '1d' > "$CRASH_FILE.tmp" 2>/dev/null
      # ⛔ a single line longer than the whole window makes `sed 1d` produce NOTHING, so an
      # unconditional `mv` would erase the evidence it is supposed to trim. Keep the untrimmed file.
      if [ -s "$CRASH_FILE.tmp" ]; then mv "$CRASH_FILE.tmp" "$CRASH_FILE" 2>/dev/null
      else rm -f "$CRASH_FILE.tmp" 2>/dev/null; fi
    fi ;;
  esac
  # Written LAST and only on success: this is the dedupe key for the next pass.
  printf '%s' "$episode" > "$CRASH_EPISODE_FILE" 2>/dev/null
}

status_show() {
  echo "controller-watchdog: O=$O HB=$HB HB_STALE=${HB_STALE}s SETTLE=${SETTLE}s MAX_CONSEC=$MAX_CONSEC"
  echo "  log:    $LOG"
  echo "  evidence: $(ctrl_stdout_path)"
  echo "  streak: $(cat "$STREAK_FILE" 2>/dev/null || echo 0)  episode: $(cat "$EPISODE_FILE" 2>/dev/null || echo 0)"
  if [ -s "$CRASH_FILE" ]; then
    echo "  ⛔ CRASH RECORDED ($CRASH_FILE):"
    echo "     (restarting was stopped for that episode; a later probe restart continues it with the"
    echo "      budget spent, and a healthy pass ends it. The record is never erased here.)"
    sed -n '1,3p' "$CRASH_FILE"
  else
    echo "  crash:  none recorded"
  fi
  echo "  last decisions:"
  tail -n 10 "$LOG" 2>/dev/null || echo "    (none yet)"
}

main() {
  mkdir -p "$STATE_DIR" 2>/dev/null
  rotate_log
  [ -n "$_bad" ] && log_line "verdict=BOUND-FALLBACK"$'\t'"note=non-numeric bound(s) ignored, defaults used:$_bad"

  # ⛔ `announced` is LOCAL: as a global it was inherited from the environment, and `env announced=1`
  # made the probe path suppress the generic decision line — a real restart with NO line saying it
  # happened. Test-only seams are allowed to be read from the environment; a control-flow flag is not.
  local pid age verdict reason streak=0 restart=0 rc=0 episode=0 announced=0

  # ── 1. ONE observation ──────────────────────────────────────────────────────────────────────────
  pid="$(controller_pid)"
  age="$(hb_age)"

  # ⛔ THE HEALTH PREDICATE, IN ONE PLACE, AND IT IS THE WHOLE POINT: a pid alone is not health.
  # This line is what the test's non-vacuity case removes — with it gone, a live pid is reported
  # HEALTHY however long the heartbeat has been frozen, i.e. exactly the measured hour.
  hb_is_fresh() { [ "${1:-missing}" != "missing" ] && [ "$1" -le "$HB_STALE" ]; }

  if hb_is_fresh "$age" && [ -n "$pid" ]; then
    log_line "verdict=HEALTHY"$'\t'"pid=$pid"$'\t'"heartbeat=${age}s"
    [ -f "$STREAK_FILE" ] && rm -f "$STREAK_FILE" 2>/dev/null   # a live cycle ends the streak
    return 0
  fi

  # ⛔ A FRESH HEARTBEAT WITH NO DISCOVERABLE PID IS *NOT* DOWN. The heartbeat is proof the loop wrote
  # within the window — i.e. it IS cycling — so restarting would kill a working controller on a bookkeeping
  # miss (a removed $O/.orch.lock, the #1715 class; or a controller whose argv the scan cannot match).
  # It is not HEALTHY either (the contract requires a pid), so it is UNCERTAIN: reported, never restarted,
  # and the streak is NOT cleared — a repeat is still a repeat.
  if hb_is_fresh "$age" && [ -z "$pid" ]; then
    log_line "verdict=UNCERTAIN"$'\t'"pid=none"$'\t'"heartbeat=${age}s"$'\t'"restart=0"$'\t'"reason=the heartbeat is ${age}s old (limit ${HB_STALE}s) so the loop IS cycling, but no pid could be identified — NOT restarted (killing a cycling controller on a bookkeeping miss is the P0); check $O/.orch.lock"
    return 0
  fi

  if [ "$age" = "missing" ]; then
    verdict="DOWN"; reason="no readable heartbeat at $HB"
  elif [ -z "$pid" ]; then
    verdict="DOWN"; reason="no controller pid (heartbeat ${age}s old, limit ${HB_STALE}s)"
  else
    verdict="WEDGED"; reason="pid $pid is alive but the heartbeat is ${age}s old (limit ${HB_STALE}s)"
  fi

  # ── 2. the streak — for EVERY arm that restarts, not only WEDGED. ⛔ A DOWN observation used to
  #       reset it, so a controller that crashes on start (absent at observation time — the #2248
  #       bash-3.2 class, which leaves no pid) was restarted on every tick for ever and none of its
  #       output was ever captured. The cap is about RESTARTS THAT DO NOT HELP, and "no pid" is one of
  #       those when it repeats. A streak that goes 0 -> 1 is a NEW episode (see EPISODE_FILE).
  streak="$(cat "$STREAK_FILE" 2>/dev/null || echo 0)"
  case "${streak:-}" in ''|*[!0-9]*) streak=0 ;; esac
  local prev_streak="$streak"
  streak=$(( streak + 1 ))
  # ⛔ THE PERSIST COMES BEFORE THE EPISODE BUMP, AND THE BUMP IS GATED ON IT. When the streak file
  # cannot be written the read is ALWAYS 0, so an unguarded `if streak -eq 0` starts a new episode on
  # every pass — and with it a fresh dedupe key, i.e. one crash block per pass: exactly the symptom the
  # episode counter exists to prevent, merely moved onto the PERSIST-FAILED path (measured in review:
  # 4 blocks in 4 passes). A failed persist instead treats the cap as SPENT and says so.
  if printf '%s' "$streak" 2>/dev/null > "$STREAK_FILE"; then
    if [ "$prev_streak" -eq 0 ]; then
      episode="$(cat "$EPISODE_FILE" 2>/dev/null || echo 0)"
      case "${episode:-}" in ''|*[!0-9]*) episode=0 ;; esac
      episode=$(( episode + 1 ))
      if printf '%s' "$episode" 2>/dev/null > "$EPISODE_FILE"; then
        :
      else
        log_line "verdict=PERSIST-FAILED"$'\t'"note=cannot write $EPISODE_FILE — this pass keeps the previous episode number so its evidence is deduped, not duplicated"
        episode=$(( episode - 1 ))
      fi
    fi
  else
    log_line "verdict=PERSIST-FAILED"$'\t'"note=cannot write $STREAK_FILE — the restart cap cannot be counted, so restarting is treated as EXHAUSTED for this pass (fail closed)"
    streak=$(( MAX_CONSEC + 1 ))
  fi

  # ── 3. the decision. ⛔ THE STOP COMES BEFORE THE RESTART, ALWAYS: `> MAX_CONSEC` must be
  #       unreachable as a restart, or "stop restarting" is a label on a loop that keeps going.
  # ⛔ THE LATCH IS BOUNDED. A "stopped" state that is only ever released by a HEALTHY pass (which
  # needs a discoverable pid) can freeze for ever: measured in review — the streak stayed at 3 through
  # three UNCERTAIN passes while an operator restarted the stack by hand, so a LATER genuine death was
  # reported STOPPED and never restarted at all (and the reason string claimed four consecutive
  # observations when there was one). So once a second full budget of stopped observations has passed,
  # ONE probe restart is allowed and a new episode starts. Worst case that is one restart per ~N passes
  # (≈20 min at MAX_CONSEC=3 and a 300s cadence) — slow, never a tight loop — and it is the only way a
  # genuinely dead box gets repaired without a human.
  if [ "$streak" -gt "$MAX_CONSEC" ]; then
    episode="$(cat "$EPISODE_FILE" 2>/dev/null || echo 0)"
    case "${episode:-}" in ''|*[!0-9]*) episode=0 ;; esac
    record_crash "$verdict" "$pid" "$age" "$streak" "$episode"
    if [ "$streak" -le "$(( MAX_CONSEC * 2 ))" ]; then
      # The countdown is stated as the ABSOLUTE observation index the probe falls on (`2N+1`), which is
      # the one number a reader can verify against the streak beside it. (`2N - streak` would be the
      # remaining stopped passes, off by one against this index; not worth a second formula.)
      log_line "verdict=${verdict}_STOPPED"$'\t'"pid=${pid:-none}"$'\t'"heartbeat=${age}s"$'\t'"streak=${streak}/${MAX_CONSEC}"$'\t'"restart=0"$'\t'"episode=$episode"$'\t'"reason=restart ${streak} would exceed the consecutive cap (${MAX_CONSEC}) — restarting disabled for this episode; crash at $CRASH_FILE; the next probe comes on observation $(( MAX_CONSEC * 2 + 1 )) of this episode (${streak} so far)"
      return 0
    fi
    # ⛔ THE PROBE DOES NOT RE-ARM A FULL BUDGET. It continues the SAME episode with the budget already
    # spent (`streak=$MAX_CONSEC`), which MEASURES one probe per `N+1` passes (4 at N=3, ~20 min at a
    # 300s cadence). Re-arming with `streak=1` measured one restart every 2 passes (~10 min) — twice
    # the documented rate, in a script whose whole point is not to restart in a loop. A probe that WORKS
    # is what ends the episode: HEALTHY clears the streak, RECOVERED clears it.
    local obs="$streak"
    streak="$MAX_CONSEC"
    # ⛔ IF THIS WRITE DOES NOT LAND, THE PASS MUST NOT RESTART. The old shape said "the next pass
    # treats the cap as exhausted" and then fell through to `restart_stack` anyway: with the file still
    # holding a value above `2*MAX_CONSEC`, EVERY subsequent pass read it, incremented, probed and
    # restarted — one restart per pass, for ever (measured in review with a fault-injected write; the
    # log claimed fail-closed the whole time). A cap that cannot be recorded is a cap that is spent.
    if ! printf '%s' "$streak" 2>/dev/null > "$STREAK_FILE"; then
      log_line "verdict=PERSIST-FAILED"$'\t'"note=cannot write $STREAK_FILE after a probe — the probe is NOT issued (a restart the cap cannot count is the tight loop this file exists to prevent)"
      return 0
    fi
    log_line "verdict=PROBE_RESTART"$'\t'"pid=${pid:-none}"$'\t'"heartbeat=${age}s"$'\t'"streak=${streak}/${MAX_CONSEC}"$'\t'"restart=1"$'\t'"episode=$episode"$'\t'"reason=observation ${obs} of this episode (> 2x${MAX_CONSEC}) — ONE probe restart, continuing the same episode with the budget spent (a dead box must not stay dead for ever; the next probe comes $((${MAX_CONSEC} + 1)) passes after this one)"
    announced=1          # the decision is already stated; do not state it twice
  fi

  [ "${announced:-0}" = "1" ] || log_line "verdict=$verdict"$'\t'"pid=${pid:-none}"$'\t'"heartbeat=${age}s"$'\t'"streak=${streak}/${MAX_CONSEC}"$'\t'"restart=1"$'\t'"reason=$reason"

  # ── 4. ONE restart, then PROVE it after a settle window. Never a second restart in this pass: a
  #       loop that restarts until something looks healthy is the behaviour this file replaces.
  restart_stack || rc=$?
  if [ "$rc" -ne 0 ]; then
    log_line "verdict=RESTART-FAILED"$'\t'"pid=${pid:-none}"$'\t'"rc=$rc"$'\t'"note=the platform restart verb failed; nothing else was attempted"
    return 0
  fi
  [ "$SETTLE" -gt 0 ] && "$SLEEP_BIN" "$SETTLE" 2>/dev/null

  local pid2 age2
  pid2="$(controller_pid)"; age2="$(hb_age)"
  if hb_is_fresh "$age2" && [ -n "$pid2" ]; then
    log_line "verdict=RECOVERED"$'\t'"pid=$pid2"$'\t'"heartbeat=${age2}s"$'\t'"note=cycling after one restart"
    rm -f "$STREAK_FILE" 2>/dev/null
  else
    # ⛔ NOT a second restart, and NOT a cleared streak: the next pass observes again, and N of those
    # in a row is what stops the loop. A restart that did not cure the wedge is the ONLY evidence that
    # restarting is useless, so it must be reported (and it is the last moment the output is still on
    # disk for the crash record).
    log_line "verdict=STILL_NOT_CYCLING"$'\t'"pid=${pid2:-none}"$'\t'"heartbeat=${age2}s"$'\t'"note=one restart did not restore cycling (no second restart in this pass)"
  fi
  return 0
}

# ⛔ EXIT 0 ALWAYS — including on an unexpected death. The trap is the difference between "the
# watchdog ran and found nothing to say" and "the watchdog crashed", and launchd's last-exit-status is
# read by nobody, so a non-zero here would be invisible exactly when it matters. It is installed BEFORE
# the argument parse: a mistyped verb used to `exit 2` past it.
trap 'exit 0' EXIT
case "${1:-}" in
  --status) status_show; exit 0 ;;
  ""|--once) ;;
  *) echo "usage: watchdog-loop.sh [--status]" >&2; exit 2 ;;
esac
main
exit 0
