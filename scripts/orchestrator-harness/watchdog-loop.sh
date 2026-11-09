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
# PLATFORM. macOS: the controller job is launchd's. WHICH launchd verb, and in WHICH DOMAIN, is
# MEASURED and not assumed — a job loaded from an SSH session lives in `user/`, so a `gui/`-only verb
# could never reach it:
#   loaded  → `launchctl kickstart -k <domain>/<label>`, in the domain the read FOUND it (cures a wedge)
#   REMOVED → `launchctl enable` + `launchctl bootstrap <domain> <plist>` (agent-infra#1986: KeepAlive
#             cannot reach a job that is no longer in the domain, and `kickstart` fails for ever on it,
#             so a controller launchd REMOVED is put back from the plist provisioned for its label —
#             NOT necessarily one `install.sh` rendered: see `PLIST_PATH` below)
#             ⛔ AND ONLY ON EVIDENCE THE CONTROLLER IS **GONE**, NEVER MERELY WEDGED (review P1,
#             #1986). `WEDGED` is a state of a LIVE controller — `pid_is_controller` proved it alive —
#             so a `bootstrap` there starts a SECOND controller beside the first.
#             ⛔ IT DOES **NOT** PROTECT A DELIBERATE STOP, AND MUST NOT CLAIM TO (review P2, cycle 11).
#             `launchctl disable`/`bootout` leaves exactly the state this arm acts on — REMOVED, with no
#             live controller — and on this evidence a `Disabled` override is indistinguishable from the
#             `-w` residue the arm exists to clear, so the arm DOES clear it and re-load (the same
#             enable-then-verify sequence as `launchd-cycle.sh`'s `lc_start`/`lc_disable_state`). An
#             operator who wants the fleet stopped must keep a live controller, or point
#             `WATCHDOG_PLIST` at nothing. ⛔ A PRE-`enable` refusal on a `disabled` read was considered
#             and is WRONG: it would make this arm inert for its own main case. The mechanism, in
#             `orch-loop.sh`'s own words: the lock is `LOCKF="$O/.orch.lock"` and its acquisition is
#             `orc_singleton_acquire "$LOCKF"` (its decision lives in `controller-state.sh`;
#             agent-infra#2095) — a newcomer beside a LIVE lock-holder EXITS AT ONCE, with **75** and a
#             `[singleton]` line naming the holder, rather than queueing behind it (this used to be a
#             silent `exit 0`; the arm's reasoning is unchanged, its citation was) (and `KeepAlive` then
#             relaunches it into the same exit, i.e. thrash), while where that controller's lock is
#             ABSENT OR STALE the newcomer TAKES IT OVER. Both ends are the duplicate-controller class
#             (#1715). ⛔ AN EARLIER VERSION OF THIS COMMENT CITED `orch-loop.sh:1546-1551` AND CLAIMED
#             THE NEWCOMER "DEFERS … UNTIL THE FIRST EXITS": that range is the `--check-refresh` case
#             arm, and nothing in the lock defers. The refusal is unchanged — the RATIONALE is now the
#             one the code supports. The REMOVED arm therefore RE-PROBES the controller at the moment of
#             the mutation and REFUSES if anything is alive.
#   unreadable → `kickstart` (never a bootstrap: that action cannot double-load an existing job)
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
#   WATCHDOG_PLIST   the plist a REMOVED job is bootstrapped from (default: $HOME/Library/LaunchAgents/<LABEL>.plist)
# ⛔ AN UNWRITABLE STATE DIR DISABLES RESTARTING, BY DESIGN. The cap is a count on disk; when it cannot
# be kept, restarting is treated as EXHAUSTED and `PERSIST-FAILED` is logged on every pass THAT CAN BE
# LOGGED — the decision log lives inside the state dir, so a fully unwritable dir loses it too and the
# verdict then reaches only stdout, which launchd captures at /tmp/controller-watchdog.launchd.err. That is the
# fail-closed arm: restarting on a counter that never advances is the tight loop this file exists to
# prevent. A probe whose own write fails is NOT issued. The one degradation is evidence: with only the
# episode file unwritable, a second crash is deduped (recorded once, not twice).
#   WATCHDOG_RESTART_CMD  replace the platform restart with this command (TESTS ONLY)
#   WATCHDOG_NO_RESTART   never invoke the platform restart verb (TESTS ONLY)
#   WATCHDOG_LAUNCHCTL_PIN  the ONLY `launchctl` this file may execute, by resolved path. If the one on
#                         PATH is a different binary, NO launchctl verb is issued and the pass says
#                         RESTART-REFUSED. A test enters the Darwin arm behind a PATH shim and pins it,
#                         so a shim that failed to be written refuses instead of reaching the real verb.
#   WATCHDOG_SUPERVISOR_PIN  the ONLY cell supervisor this file may execute, by path (the cell arm's
#                         equivalent of the launchctl pin). A MISMATCH refuses and issues nothing. This
#                         matters because the arm's own fallback resolves `$SELF_DIR/../cloud-cell-
#                         supervisor.sh`, which in any checkout IS the box's live supervisor: without a
#                         pin, a harness whose `SUPERVISOR` is unset executes the real one (#1986 review).
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
# The plist a REMOVED job is re-loaded from. ⛔ IT IS NOT ASSUMED TO BE A FILE `install.sh` RENDERS
# (review P2, #1986): `install.sh` renders exactly ONE label — `com.eldato.orchestrator-loop`
# (`install.sh:147` → `:156` `$HOME/Library/LaunchAgents/$LABEL.plist`) — while this file's DEFAULT label
# is `com.eldato.orchestrator-stack`, the box's own supervision job (`orchestrator-bringup.sh:1065-1069`:
# "here the loaded job is `com.eldato.orchestrator-stack` → `/bin/bash $O/supervisor.sh`, while
# `install.sh` renders `com.eldato.orchestrator-loop`"). So the path is the standard LaunchAgents
# location for THIS label, provisioned by whatever provisioned the job — and an absent plist is
# REPORTED (RESTART-UNAVAILABLE) rather than guessed at or rendered in passing.
PLIST_PATH="${WATCHDOG_PLIST:-$HOME/Library/LaunchAgents/$LABEL.plist}"
# The root the per-commit harness trees live under. ⛔ THIS IS WHERE THE CONTROLLER'S ARGV ACTUALLY
# POINTS on a shipped Mac: launchd runs `bash __HARNESS__/__ENTRY__` (`launchd.plist.template:24`,
# rendered from install.sh's `HARNESS_PIN_DIR`, default `$HOME/harness`), NOT `$O/orch-loop.sh`. Measured
# on a live box: `bash /home/cmux/harness/9a3cf06e09b4/scripts/orchestrator-harness/orch-loop.sh`, while
# `$O` is the deployed harness dir and this file's `$SELF_DIR` is whatever checkout it was started from —
# three different paths. The REMOVED arm's liveness probe needs this root or it is LOCK-ONLY.
PIN_ROOT="${WATCHDOG_PIN_DIR:-${HARNESS_PIN_DIR:-$HOME/harness}}"
# ⛔ A DELIBERATE REFUSAL IS NOT A FAILED VERB — AND IT IS NOT AN EXIT CODE EITHER (review P1, #1986).
# Both are non-zero (a refusal must never be read as a recovery), but only a refusal means *nothing was
# executed*, so `main` must not turn it into RESTART-FAILED and must not fall through to the post-settle
# `STILL_NOT_CYCLING` arm as though an attempt had been made and simply did not work.
#
# The distinction is carried OUT OF BAND, in this flag — NOT as a reserved return code. It used to be
# `RC_REFUSED=75`, and an in-band sentinel shares its value space with the verbs' own exit statuses: this
# file already documents launchctl answering `rc 64` (EX_USAGE), i.e. it answers in sysexits.h, so an
# `enable`/`kickstart`/`bootstrap` that failed with 75 (EX_TEMPFAIL) was reported as a REFUSAL and the
# pass produced NO verdict at all (measured: only `verdict=WEDGED … restart=1`, no RESTART-FAILED, no
# refusal line, rc 0). Any value a verb can return is unsafe as a sentinel. `RESTART_VERB` below is the
# same pattern done right, and `RESTART-REFUSED` coverage has its own case (§8b(i)) so a verb's 75 is
# still RESTART-FAILED.
RESTART_REFUSED=0
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
  # launchd job runs `bash __HARNESS__/__ENTRY__` (`launchd.plist.template:24`) — the PIN tree, which is
  # neither `$O` nor `$SELF_DIR`, see `PIN_ROOT` — while a cell's supervisor runs `bash
  # '<harness>/orch-loop.sh'` (cloud-cell-supervisor.sh:1985 — the same measurement the inventory records
  # in fleet-inventory.sh's two-scope controller row). A single `$O`-scoped scan therefore could not see a
  # cell's controller AT ALL, so WEDGED was unreachable there: a live but frozen controller read as DOWN,
  # and every pass issued a restart. The second pattern is THIS script's own sibling — the harness dir the
  # cell pins — not a guess at an operator's path.
  # ⚠ STILL INCOMPLETE, AND NAMED RATHER THAN HIDDEN: this scan does not cover the MAC's pin-tree argv, so
  # on a shipped Mac a live-but-frozen controller reads DOWN and WEDGED is unreachable (filed as a
  # follow-up; the REMOVED arm guards itself separately with the same three roots, because THAT is where a
  # wrong answer mutates the box).
  local pat
  for pat in "bash ${O}/orch-loop.sh" "bash ${SELF_DIR}/orch-loop.sh"; do
    [ -n "$pat" ] || continue
    pid="$(pgrep -f "$pat" 2>/dev/null | head -1)"
    [ -n "$pid" ] && pid_is_controller "$pid" && { printf '%s\n' "$pid"; return 0; }
  done
  printf '\n'
}

# ── the restart, per platform. ONE verb, the box's own owner ─────────────────────────────────────
# launchd_job_state — prints `"<state> <domain>"`. state 0 = loaded (domain = the one it was FOUND in),
# 1 = absent from every domain (domain = the first domain that EXISTS, i.e. where a bootstrap belongs),
# 2 = UNKNOWN (domain `-`: the read established nothing).
# ⛔ WHY THIS EXISTS AT ALL (agent-infra#1986): a REMOVED job is not a crashed one, and `kickstart`
# cannot put one back. Measured five times on 2026-10-17 — a persistent-disable verb, or a `bootout`
# whose `bootstrap` then failed, leaves `Setting service … to disabled` → `removing service`: the job
# is no longer in the domain, `KeepAlive` cannot reach it, the controller simply stops dispatching,
# and nothing logs an error the fleet can see. `launchctl kickstart -k` on such a label exits
# non-zero for ever, so the ONE restart this file issues — bounded by the shared on-disk budget —
# would never restore it. The capability therefore lives HERE, in the tracked agent, and not in a
# second launchd job: `templates/launchd/RETIRED` retired the hand-provisioned
# `com.eldato.orchestrator-watchdog` precisely because two loaded watchdogs are two MUTATING actors
# on one controller, and `docs/ops/fleet-liveness.md` names `watchdog-loop.sh` as its replacement.
# ⛔ `launchctl print`, NOT `launchctl list <label>`: the repo pins `print` against a captured real
# block (`pid =` / `last exit code =`), while two shipped files disagree about what `list <label>`
# prints on current macOS.
# ⛔ BOTH DOMAINS, because a job loaded from an SSH session lives in `user/`, so a `gui/`-only read
# would call a RUNNING controller "not loaded" and issue a bootstrap over it — and the DOMAIN IS
# RETURNED WITH THE STATE, because a `gui/`-only VERB has the same defect from the other side: a job
# found in `user/` could be read as loaded and then never kickstarted (measured review P2, #1986).
# ⛔ A DOMAIN-LEVEL REJECTION (`Could not find domain …`) means that domain cannot hold the job — not
# that the read failed — so it continues to the next domain, and does NOT count as a place to load into.
# ⛔ NOT-FOUND IS THE RETURN CODE; the text only backstops it. ⚠ CORRECTED 2026-11-01 against the live
# box: the previous version of this comment (and the README row it came from) said a bare `Bad request.`
# was the UNREADABLE marker. It is not — a NOT-FOUND read is `rc 113` and its FIRST line is `Bad
# request.`, followed by `Could not find service "<label>" in domain for user …` (verified for both
# `gui/<uid>` and `user/<uid>`; the selftest's own fixture had learned half of this). The measured
# UNREADABLE read is `rc 64` + `Unrecognized target specifier.` for a malformed target, or any other
# non-zero whose text is neither of the two below. Matching `rc 113` is what keeps this polarity
# correct if launchd's wording changes; UNKNOWN stays UNKNOWN and NEVER becomes "absent", because
# deciding a mutation from an error message is how a healthy job gets re-bootstrapped underneath a live
# controller.

# ── PLIST PROVENANCE — read the job a bootstrap WOULD load, BEFORE loading it ─────────────────────
# ⛔ WHY THIS EXISTS (review P1, cycle 4 of #1986). `launchctl bootstrap <dom> <plist>` resolves the job
# by the plist's OWN `Label`, NOT by the file's name. So "a file exists at $PLIST_PATH" is NOT evidence
# that loading it restores THIS label: `$PLIST_PATH` defaults to `$HOME/Library/LaunchAgents/$LABEL.plist`
# but is also a documented knob (`WATCHDOG_PLIST`), so a stale or copied plist there — or one left by a
# different provisioning model — makes the pass `enable $LABEL` (a no-op for the job launchd actually
# holds) and then LOAD A DIFFERENT JOB beside the box's supervision model. That is the
# duplicate-controller class this arm's own comment forbids (#1761/#1715), and the pass would report it
# as a failed restart of a controller it never touched.
# The doctrine is the repo's own — `orchestrator-bringup.sh` `launchd_job_for_state_dir()`: OPERATE THE
# JOB THAT IS ALREADY HERE, never load a new one. Here the two proofs are (a) the plist's `Label` IS
# `$LABEL`, and (b) its program is a controller entry inside one of THIS box's roots — the same three
# the live-probe below uses: the deploy path `$O`, this file's own tree, and `$PIN_ROOT`.
# ⛔ NO `plutil`: it is macOS-only, and these suites also run on Linux CI runners — a macOS-only reader
# ── THE PROBE: one dependency-free reader that reports what the plist ACTUALLY declares ──────────
# ⛔ IT IS A PROBE, NOT THREE GREPS, because every previous version was fooled by a shape it did not
# imagine (review P1, cycle 6 of #1986):
#   * the COMPACT form `<key>ProgramArguments</key><array><string>…</string></array>` — which is the
#     shape `orchestrator-bringup.test.sh` writes for THIS BOX'S OWN stack plist — made the old
#     line-oriented reader return EMPTY, so the arm was inert on the shipped configuration;
#   * `<!-- … -->` comments were scanned as if they were data, so a "copied from" comment naming the
#     right label made a FOREIGN plist pass;
#   * a plist declaring `Label` TWICE (the superseded one first) passed on the first match.
# So: strip comments first (the state machine below handles comments spanning lines), then read the
# document as ONE string, and report the number of `Label` keys so an ambiguous plist can be refused.
# ⛔ NO `plutil` (macOS-only; these suites run on Linux CI too) and NO `python3` (a launchd job's PATH
# may not carry it). awk only. Output is a sequence of NUL-TERMINATED kind/value PAIRS — `COUNT`, `LABEL`,
# `PROGRAM`, then one `ARG` per ProgramArguments element — read back by `plist_not_this_job` with
# `read -r -d ''`. The framing is NUL and not a tab/newline because the values come from the FILE and an
# XML `<string>` may contain either; see the reader for the measured consequences of getting this wrong.
plist_probe() { # <file>
  awk '
    function strip(s,   out, p, pc, pd, body) {
      out = ""
      while (length(s) > 0) {
        if (inc)       { p = index(s, "-->");  if (p == 0) { s = "" } else { s = substr(s, p + 3); inc = 0 } }
        # ⛔ CDATA IS TEXT, NOT MARKUP (review P1, cycle 10 of #1986). `<!…>` was passed through to canon,
        # which stops at the first `>` — and `>` is legal inside a CDATA body — so the remainder of the
        # section (`]]>`) stayed in the document and any `<dict>`/`<key>` it CONTAINED was scanned as a real
        # tag. MEASURED: a benign ProgramArguments followed by `<key>Notes</key><string><![CDATA[x><dict>]]>
        # </string>` and then a top-level `Program` of `/opt/evil/run-agent` left `depthat` one level deep for
        # the rest of the document, so the foreign `Program` was not counted, the gate PASSED and `bootstrap`
        # loaded it (plistlib resolves that document to the foreign Program). The body is now consumed as a
        # UNIT and kept as VALUE TEXT with `<`/`>` entity-escaped, so it can be neither scanned as a tag nor
        # dropped from the value (dropping it would hand back the same fail-open: a CDATA-wrapped foreign
        # Program would read as empty and a benign ProgramArguments would decide).
        else if (cinc) {
          p = index(s, "]]>"); body = (p == 0) ? s : substr(s, 1, p - 1)
          # ⛔ `&` IS ESCAPED FIRST, so a literal reference inside a CDATA body stays TEXT through the
          # decoder (review P1, cycle 11 of #1986). Escaping only `<`/`>` meant `decode()` read a
          # `&#46;` as the character `.` — the one place decoding must not apply, because inside CDATA XML
          # defines no references at all.
          gsub(/&/, "\\&amp;", body)
          gsub(/</, "&lt;", body); gsub(/>/, "&gt;", body)
          out = out body
          if (p == 0) { s = "" } else { s = substr(s, p + 3); cinc = 0 }
        }
        else {
          pc = index(s, "<!--"); pd = index(s, "<![CDATA[")
          if (pc == 0 && pd == 0) { out = out s; s = "" }
          else if (pd > 0 && (pc == 0 || pd < pc)) { out = out substr(s, 1, pd - 1); s = substr(s, pd + 9); cinc = 1 }
          else { out = out substr(s, 1, pc - 1); s = substr(s, pc + 4); inc = 1 }
        }
      }
      return out
    }
    # ⛔ XML CHARACTER REFERENCES ARE RESOLVED THE WAY launchd RESOLVES THEM (review P1, cycle 11 of
    # #1986). Reading a value as RAW TEXT made this proof disagree with the parser that actually loads
    # the job, in BOTH directions, and the fail-open one is the duplicate-controller class this gate
    # exists to stop. MEASURED with the shipped functions before this fix: `ProgramArguments`
    # `[/bin/bash, /opt/orch/&#46;&#46;/evil/orch-loop.sh]` has no literal `..` and string-prefixes `$O`,
    # so every proof PASSED and `bootstrap` would have run it — while CFPropertyList/plistlib resolve
    # that element to `/opt/orch/../evil/orch-loop.sh`, i.e. `/opt/evil/orch-loop.sh`, outside every
    # root. The inert direction is equally real: a plist that escapes a NON-ASCII character in an honest
    # path (`/x/Usr jos&#233;/orch-loop.sh`, `plistlib` → `…josé…`) was refused for ever with a FALSE
    # reason ("not under any of the box roots" over a path that IS).
    # So: named refs and ASCII numeric refs are decoded; a reference this reader will NOT decode is
    # collected in `badref` and reported, so the caller REFUSES with the true reason instead of comparing
    # a raw string and refusing with a false one. ⛔ Only code points 1..126 are decoded — never a guess
    # at a wider encoding: `sprintf("%c", n)` for n > 126 means a UTF-8 code point in gawk and a single
    # BYTE in BWK awk (macOS), so "decoding" those would mint mojibake on one of the two platforms. A
    # reference it cannot prove is refused, not invented.
    function hexval(h,   i, c, v, n) {
      n = 0
      for (i = 1; i <= length(h); i++) {
        c = tolower(substr(h, i, 1))
        if (index("0123456789abcdef", c) == 0) return -1
        n = n * 16 + (index("0123456789abcdef", c) - 1)
        if (n > 1114111) return -1
      }
      return (length(h) == 0) ? -1 : n
    }
    function decval(d,   i, n) {
      n = 0
      for (i = 1; i <= length(d); i++) {
        if (substr(d, i, 1) !~ /[0-9]/) return -1
        n = n * 10 + (substr(d, i, 1) + 0)
        if (n > 1114111) return -1
      }
      return (length(d) == 0) ? -1 : n
    }
    function note_badref(ref) { badref = badref (badref == "" ? "" : ",") ref }
    function decode(s,   out, p, q, ref, cp) {
      out = ""
      while ((p = index(s, "&")) > 0) {
        out = out substr(s, 1, p - 1)
        q = index(substr(s, p), ";")
        if (q == 0) { out = out substr(s, p); return out }
        ref = substr(s, p + 1, q - 2)
        s = substr(s, p + q)
        if (ref == "lt")        { out = out "<" }
        else if (ref == "gt")   { out = out ">" }
        else if (ref == "amp")  { out = out "&" }
        else if (ref == "quot") { out = out "\"" }
        else if (ref == "apos") { out = out "\047" }
        else if (substr(ref, 1, 2) == "#x" || substr(ref, 1, 2) == "#X") {
          cp = hexval(substr(ref, 3))
          if (cp < 1 || cp > 126) note_badref(ref); else out = out sprintf("%c", cp)
        }
        else if (substr(ref, 1, 1) == "#") {
          cp = decval(substr(ref, 2))
          if (cp < 1 || cp > 126) note_badref(ref); else out = out sprintf("%c", cp)
        }
        else note_badref(ref)
      }
      return out s
    }
    # value of the FIRST <string> at or after `from`, bounded by `to`, AS THE FILE SPELLED IT
    function strraw(doc, from, to,   p, q) {
      if (to <= from) return ""
      p = index(substr(doc, from, to - from + 1), "<string>"); if (p == 0) return ""
      p = from + p - 1
      q = index(substr(doc, p + 8), "</string>"); if (q == 0) return ""
      return substr(doc, p + 8, q - 1)
    }
    # …and the same value with its character references resolved
    function strval(doc, from, to) { return decode(strraw(doc, from, to)) }
    # the value of the key whose `<key>…</key>` starts at `at`, bounded to that key OWN dict entry
    function keyval(doc, at, keylen,   from, nk) {
      from = at + keylen; nk = index(substr(doc, from), "<key>")
      return strval(doc, from, (nk > 0) ? from + nk - 2 : length(doc))
    }
    # ⛔ DICT DEPTH AT A POSITION, because launchd resolves `Label`/`Program`/`ProgramArguments` by
    # TOP-LEVEL key lookup and NOT by substring (review P1, cycle 8). A `<key>Program</key>` nested inside
    # `EnvironmentVariables` is an ENV VAR named Program, which launchd ignores — yet a document-wide
    # first-match read reported it as PROGRAM, that value overrode ProgramArguments, and a plist whose
    # real argv[0] was `/opt/evil/run-agent` PASSED the gate and was bootstrapped under `$LABEL`
    # (measured). Every key below is therefore accepted only at depth 1.
    function depthat(doc, upto,   rest, n, p) {
      n = 0; rest = substr(doc, 1, upto - 1)
      while ((p = index(rest, "<dict>")) > 0) { n++; rest = substr(rest, p + 6) }
      rest = substr(doc, 1, upto - 1)
      while ((p = index(rest, "</dict>")) > 0) { n--; rest = substr(rest, p + 7) }
      return n
    }
    # ⛔ EVERY TAG IS NORMALISED BEFORE ANY SCAN (review P1, cycle 9 of #1986). An XML start tag may legally
    # carry whitespace or attributes — `<key >Program</key>`, `<dict xml:space="preserve">` — and so may an
    # end tag: `</dict >`. Every scan below matches the LITERAL spellings, so the same document used to give
    # a different answer depending on HOW IT WAS SPELLED. Both directions were MEASURED: (a) a foreign
    # `Program` written `<key >Program</key>` was not a key at all, so a benign ProgramArguments decided the
    # verdict and `bootstrap` loaded the foreign program under `$LABEL` — the #1761/#1715 class, with this
    # gate reporting PASS; (b) a legitimate plist closing `</dict >` left `depthat` raised, so its own keys
    # read as nested and the recovery arm was refused on every pass for ever (an inert arm). Rewriting each
    # tag to `<name>`/`</name>` before the scans makes the answer a property of the DOCUMENT rather than of
    # its spelling. Text content is copied untouched; `<!…>`/`<?…>` (DOCTYPE, XML decl) are preserved.
    # ⛔ A TAG ENDS AT THE FIRST `>` **OUTSIDE A QUOTED ATTRIBUTE VALUE** (review P1, cycle 11 of #1986).
    # XML allows attributes on ANY element and `>` is legal inside one, so `index(s, ">")` ended the tag
    # INSIDE `<key note="a>b">Program</key>`; the remainder `b">Program</key>` became TEXT, so a foreign
    # top-level `Program` was invisible to every count and every proof. MEASURED with the shipped
    # functions: that document PASSED the gate while plistlib resolves it to `Program= /opt/evil/run-agent`.
    function tagend(s,   i, ch, q) {
      q = ""
      for (i = 2; i <= length(s); i++) {
        ch = substr(s, i, 1)
        if (q != "") { if (ch == q) q = "" }
        else if (ch == "\"" || ch == "\047") { q = ch }
        else if (ch == ">") { return i }
      }
      return 0
    }
    function canon(doc,   out, i, p, q, s, name, j, rest) {
      out = ""; i = 1
      while ((p = index(substr(doc, i), "<")) > 0) {
        out = out substr(doc, i, p - 1)
        rest = substr(doc, i + p - 1)
        q = tagend(rest)
        if (q == 0) return out rest
        s = substr(rest, 2, q - 2)
        i = i + p + q - 1
        if (substr(s, 1, 1) == "!" || substr(s, 1, 1) == "?") { out = out "<" s ">"; continue }
        if (substr(s, 1, 1) == "/") { name = "/"; j = 2 } else { name = ""; j = 1 }
        while (j <= length(s) && substr(s, j, 1) ~ /[A-Za-z0-9_.:-]/) { name = name substr(s, j, 1); j++ }
        # ⛔ A SELF-CLOSING TAG MUST STAY SELF-CLOSING (review P0, cycle 10). `/` is outside the name charset,
        # so `<dict/>` was emitted as `<dict>` — a CLOSED empty element became an UNCLOSED one, `depthat` rose
        # for the rest of the document, and every later top-level key read as nested, i.e. "not a job key at
        # all". MEASURED, both directions: a plist with `<key>EnvironmentVariables</key><dict/>` between a
        # benign and a foreign top-level `ProgramArguments` PASSED (plistlib resolves the duplicate to the
        # foreign one — the duplicate-key guard was bypassed), and an honest plist with an empty `<dict/>`
        # before `ProgramArguments` was read as declaring no program at all, so the recovery arm refused for
        # ever. `<array/>` and `<dict/>` are ordinary plist spellings; the marker is preserved verbatim.
        if (substr(s, 1, 1) != "/" && substr(s, length(s), 1) == "/") name = name "/"
        out = out "<" name ">"
      }
      return out substr(doc, i)
    }
    { doc = doc strip($0) "\n" }
    END {
      doc = canon(doc)
      # ⛔ EVERY TOP-LEVEL KEY IS COUNTED, NOT JUST `Label` (review P1, cycle 8). A plist declaring
      # `Program` or `ProgramArguments` TWICE is as ambiguous as one declaring `Label` twice —
      # CFPropertyList keeps the LAST occurrence while a first-match reader keeps the FIRST, so the two
      # readers disagree about what runs. The caller refuses on a count > 1 for any of the three.
      lc = 0; pc = 0; ac = 0; pos = 1
      while ((p = index(substr(doc, pos), "<key>")) > 0) {
        at = pos + p - 1
        if (depthat(doc, at) == 1) {
          rest = substr(doc, at)
          if (index(rest, "<key>Label</key>") == 1)            { lc++; lpos[lc] = at }
          else if (index(rest, "<key>Program</key>") == 1)     { pc++; ppos[pc] = at }
          else if (index(rest, "<key>ProgramArguments</key>") == 1) { ac++; apos[ac] = at }
        }
        pos = at + 5
      }
      # ⛔ NUL-FRAMED, NOT TAB/NEWLINE-DELIMITED (review P2, cycle 7 of #1986). Every value here comes
      # from the FILE, and an XML `<string>` may legally contain a tab or a newline. The previous stream
      # was read back with `awk -F` on a TAB and an unquoted `$(…)`, so a tab inside a Label truncated it to a
      # matching-looking prefix (a FOREIGN label then passed proof 1) and a newline inside a value FORGED
      # an extra `ARG` record that satisfied proof 3. Both were measured. A NUL cannot occur in XML text,
      # so `read -r -d` with an EMPTY delimiter reads back exactly the value the file declared — whatever it
      # contains.
      # ⛔ AND THAT IS WHY NO APOSTROPHE MAY APPEAR IN THIS awk PROGRAM (review P1, cycle 11 of #1986). The
      # program is single-quoted, so one apostrophe inside it CLOSES the string: the shell then reads the
      # rest as UNQUOTED text — minting a command substitution out of a `$(…)` and mangling every `\0` —
      # which is the same class as the cycle-10 bug that RAN `enable` from a comment. Two pre-existing
      # apostrophes in this program happened to pair up, so the file parsed while silently rewriting its
      # own text. §8b(am) now fails on an ODD number of apostrophes anywhere in this program.
      printf "COUNT\0%d\0", lc
      printf "PCOUNT\0%d\0", pc
      printf "PACOUNT\0%d\0", ac
      if (lc >= 1) printf "LABEL\0%s\0", keyval(doc, lpos[lc], length("<key>Label</key>"))
      # ⛔ `Program` AND `ProgramArguments` ARE REPORTED SEPARATELY, AND NEITHER IMPLIES THE OTHER (review
      # P1, cycle 7). `man launchd.plist`: `Program` "maps to the first argument of execvp(3)" and, when
      # present, is what RUNS — `ProgramArguments` then supplies only argv[1..]. A reader that only ever
      # looked at ProgramArguments could therefore be shown this box controller entry in an ARGUMENT
      # position while launchd execs a different file. Both are emitted; the caller decides.
      if (pc >= 1) printf "PROGRAM\0%s\0", keyval(doc, ppos[pc], length("<key>Program</key>"))
      if (ac >= 1) {
        from = apos[ac] + length("<key>ProgramArguments</key>")
        a2 = index(substr(doc, from), "<array>")
        if (a2 > 0) {
          from = from + a2 - 1 + 7
          z = index(substr(doc, from), "</array>")
          if (z > 0) {
            to = from + z - 2
            n = 0; start = from
            while (start <= to && n < 40) {
              q = index(substr(doc, start, to - start + 1), "<string>"); if (q == 0) break
              # ⛔ THE ADVANCE USES THE **RAW** LENGTH, NOT THE DECODED ONE (review P1, cycle 11 of
              # #1986). `start` walks the DOCUMENT, so skipping `length(decoded)` left it mid-element
              # after any reference was resolved (`&amp;` is 5 chars raw, 1 decoded): the next
              # `index(…, "<string>")` would then land inside the element it had just read, and an ARG
              # could be reported TWICE or dropped.
              raw = strraw(doc, start, to); if (raw == "") break
              v = decode(raw)
              n++; printf "ARG\0%s\0", v
              start = start + q - 1 + 8 + length(raw) + 9
            }
          }
        }
      }
      # ⛔ THE UNDECODABLE-REFERENCE RECORD IS EMITTED LAST, AFTER EVERY VALUE HAS BEEN DECODED (review
      # P1, cycle 11 of #1986). Emitting it beside LABEL/PROGRAM meant the ARGs were still undecoded at
      # that point, so a reference in a ProgramArguments element (the case that matters) produced NO
      # record at all and the caller compared a silently-truncated value.
      if (badref != "") printf "BADREF\0%s\0", badref
    }' "$1" 2>/dev/null
}
# Returns 0 when the plist is NOT this label's job (and prints the reason); returns 1 only when it IS.
# ⛔ THE CONVENTION IS DELIBERATELY "0 = REFUSE", read as `if plist_not_this_job …; then refuse` — a
# proof function that returned 0 for "proven bad" would invite the inverse reading at the one call site
# that mutates, and an inverted reading there bootstraps the FOREIGN plist, which is the exact
# duplicate-controller class this function exists to stop (#1761/#1715).
# ⛔ THE THREE PROOFS, and why each is there:
#   1. EXACTLY ONE `Label`, and it IS `$LABEL`. Two Labels is ambiguous (which one does launchd resolve?)
#      and an unknown one is a different job.
#   2. `ProgramArguments` (or `Program`) declares a program.
#   3. THE PROGRAM LAUNCHD WILL EXEC — not merely "some entry that looks like our controller" — is a
#      CONTROLLER ENTRY (basename one of the box's entry points) under one of THIS box's three roots
#      ($O, this file's tree, $PIN_ROOT), with no `..` segment. A name list alone was cycle 5's bug (it
#      refused the shipped `supervisor.sh`); a root test alone was cycle 6's (it accepted
#      `$SELF_DIR/watchdog-loop.sh`, i.e. loading the WATCHDOG as the controller, which keeps the
#      controller dead and then blocks the real restore with "service already loaded"); and "ANY
#      argument matches" was cycle 7's — a plist with `/opt/evil/run-agent` as argv[0] and this box's
#      controller path in an ARGUMENT position PASSED, and `bootstrap` loaded the foreign program under
#      `$LABEL` (measured). Proof 3 is about the program that RUNS.
plist_not_this_job() { # <file>
  local -a _args=()
  local _cnt="" _pcnt="" _pacnt="" _lbl="" _prog="" _kind _val _exec="" _e _root _badref=""
  while IFS= read -r -d '' _kind; do
    IFS= read -r -d '' _val || break
    case "$_kind" in
      COUNT)   _cnt="$_val" ;;
      PCOUNT)  _pcnt="$_val" ;;
      PACOUNT) _pacnt="$_val" ;;
      LABEL)   _lbl="$_val" ;;
      PROGRAM) _prog="$_val" ;;
      BADREF)  _badref="$_val" ;;
      ARG)     _args+=("$_val") ;;
    esac
  done < <(plist_probe "$1")
  # ⛔ A REFERENCE THIS READER CANNOT PROVE IS A REFUSAL, WITH THE TRUE REASON (review P1, cycle 11 of
  # #1986). It used to be compared as raw text, which is how `&#46;&#46;` passed as "not `..`" (fail-open)
  # and how an honest non-ASCII path was refused with the FALSE line "not under any of this box's roots"
  # (inert arm). launchd resolves these references; this gate therefore refuses what it cannot resolve
  # rather than deciding on a string launchd will not see.
  if [ -n "$_badref" ]; then
    printf 'it declares XML character reference(s) this reader does not resolve (%s) — launchd DOES resolve them, so what a bootstrap would run cannot be proven from the raw text; re-render the plist without character references (or point WATCHDOG_PLIST at one that is already plain)' "$_badref"
    return 0
  fi
  # ⛔ NO FIELD SPLITTING AND NO DELIMITER PARSING ANYWHERE (review P2, cycle 7 of #1986). `$(…)` word-
  # splits on spaces, so on a box whose root path contains a space NO plist could ever pass and the arm
  # was permanently INERT there; `awk -F'\t'` truncates at a tab, so a tab inside a Label made a FOREIGN
  # label pass as `$LABEL`. Both measured. The values are now read exactly as the file declared them.
  case "${_cnt:-}" in
    1)  : ;;
    # ⛔ "THE FILE WAS NEVER PARSED" AND "NO LABEL KEY" ARE ONE ANSWER, AND 0 IS NOT "AMBIGUOUS" (review
    # P2, cycle 7). A BINARY plist — a legitimate LaunchAgent format — yields 0, and the old `*` arm told
    # the operator it "declares 0 Label keys, which is ambiguous": a claim about the CONTENT of a file
    # that was never read. The polarity was safe (nothing loaded), but such a box was permanently inert
    # and the reason it printed was false. `install.sh` already names the correct diagnosis for this.
    0|'') printf 'it could not be read as a plist at all — no parsable Label key (a binary plist? this reader is XML-only; inspect it with plutil -p \047%s\047)' "$1"; return 0 ;;
    *)  printf 'it declares %s Label keys, which is ambiguous — refusing to guess which job launchctl would resolve' "$_cnt"; return 0 ;;
  esac
  [ "$_lbl" = "$LABEL" ] || {
    printf 'its Label is \047%s\047, not \047%s\047' "${_lbl:-<none>}" "$LABEL"; return 0; }
  # ⛔ A DUPLICATE `Program`/`ProgramArguments` IS AS AMBIGUOUS AS A DUPLICATE `Label` (review P1, cycle 8).
  # CFPropertyList keeps the LAST occurrence of a repeated key while a first-match reader keeps the FIRST,
  # so the two disagree about which program runs — and the reader that decides whether to bootstrap must
  # not be the lenient one. Only TOP-LEVEL keys are counted (the probe's `depthat`), so a `Program`-named
  # entry inside `EnvironmentVariables` is not a job key at all and cannot be substituted for one.
  case "${_pcnt:-0}" in 1) : ;; 0) : ;; *) printf 'it declares %s top-level Program keys, which is ambiguous — a repeated key resolves to a DIFFERENT one for launchd than for a first-match reader' "$_pcnt"; return 0 ;; esac
  case "${_pacnt:-0}" in 1) : ;; 0) : ;; *) printf 'it declares %s top-level ProgramArguments keys, which is ambiguous — a repeated key resolves to a DIFFERENT one for launchd than for a first-match reader' "$_pacnt"; return 0 ;; esac
  # ⛔ WHICH ELEMENT IS THE PROGRAM (review P1, cycle 7; interpreter skip in the `Program` branch review
  # P2, cycle 8). `man launchd.plist`: `Program` maps to "the first argument of execvp(3)" and, when
  # present, is argv[0], while `ProgramArguments` then supplies argv[1..]; otherwise argv[0] is the first
  # ProgramArguments element. In BOTH cases, when argv[0] is an INTERPRETER the file that actually runs is
  # the first following non-flag element. So the candidate sequence is `Program` first, then every
  # ProgramArguments element, and the answer is the first that is neither a flag nor an interpreter.
  # ⛔ THE PREVIOUS VERSION APPLIED THE SKIP ONLY TO ProgramArguments, so `Program=/bin/bash` with the
  # box controller as the first argument was REFUSED on every pass for ever — with a line asserting
  # launchd would run `/bin/bash`, which is not what happens (measured, cycle 8). That is the "dead arm
  # that looks healthy" shape this file refuses elsewhere.
  # ⛔ NOTE THE PRECEDENCE DIFFERS FROM `install.sh` `plist_program`, WHICH PREFERS ProgramArguments AND
  # FALLS BACK TO Program. This one follows the man page, because this gate is deciding what `execvp`
  # receives. `install.sh` asks a different question (which SCRIPT does the rendered job start) and its
  # answer is still right for that; where the two differ, this answer is the more conservative of the two
  # in the direction that matters (it takes `Program` when both are present).
  for _e in ${_prog:+"$_prog"} ${_args[@]+"${_args[@]}"}; do
    case "$_e" in -*) continue ;; esac
    case "${_e##*/}" in bash|sh|zsh|ksh|dash|env) continue ;; esac
    _exec="$_e"; break
  done
  if [ -z "$_exec" ]; then
    printf 'it declares neither a Program nor a runnable ProgramArguments entry, so there is nothing to load'
    return 0
  fi
  # ⛔ TRAVERSAL IS REFUSED EXPLICITLY: the root test below is a string prefix, and an unnormalised
  # `$O/../../evil/...` satisfies it while naming a program outside every root (measured in review).
  case "$_exec" in
    *..*) printf 'the program launchd would exec (%s) contains a .. segment' "$_exec"; return 0 ;;
  esac
  case "${_exec##*/}" in
    orch-loop.sh|launchd-controller.sh|supervisor.sh) : ;;
    *) printf 'launchd would exec \047%s\047, which is not a controller entry (orch-loop.sh/launchd-controller.sh/supervisor.sh) — loading it would run a DIFFERENT program under \047%s\047' "$_exec" "$LABEL"; return 0 ;;
  esac
  # ⛔ TRAILING SLASHES ARE STRIPPED FIRST (review P2, cycle 8). `$O` is an exported operator value and
  # `O=~/orchestrator/` is ordinary spelling; `case "$_exec" in "$_root"/*)` then becomes
  # `/…/orchestrator//*`, which a normal path never matches — so a legitimate plist was REFUSED on every
  # pass, naming the very root the program is under. `install.sh:879-881` already normalises exactly this
  # way before a prefix test; this uses the same loop.
  for _root in "$O" "$SELF_DIR" "$PIN_ROOT"; do
    [ -n "$_root" ] || continue
    while [ "${#_root}" -gt 1 ] && [ "${_root%/}" != "$_root" ]; do _root="${_root%/}"; done
    case "$_exec" in "$_root"/*) return 1 ;; esac
  done
  printf 'launchd would exec \047%s\047, which is not under any of this box\047s roots (%s, %s, %s)' \
    "$_exec" "$O" "$SELF_DIR" "$PIN_ROOT"
  return 0
}

# disable_state <domain> <label> — the persistent Disabled override ACTUALLY in effect, measured from
# `launchctl print-disabled` (read-only). One of `disabled`, `enabled`, `unset`, `unknown`.
# ⛔ MEASURED, NOT ASSUMED (review P2, cycle 7 of #1986). `launchd-cycle.sh:412-413` verifies this after
# `enable` and records why: a `disabled` that did not clear means the load would "either fail or — worse
# — succeed into a state the next boot loses". This file's own comment already states the failure mode
# ("bootstrap of a disabled label is a no-op that can still exit 0"), yet the REMOVED arm took `enable`
# exiting 0 as proof and reported `restart=1` for a load that could not survive a reboot.
# ⛔ THE THREE STATES ARE KEPT APART, exactly as `lc_disable_state` keeps them: "the read failed", "no
# override is recorded" (the HEALTHY state) and "an entry we cannot classify" are different answers, and
# folding them into one `unknown` made a healthy box report itself as unreadable at the moment an
# operator is already diagnosing launchd. An UNREADABLE answer must never become a false block.
disable_state() { # <domain> <label>
  local out entry
  out="$(launchctl print-disabled "$1" 2>/dev/null)" || { printf 'unknown\n'; return 0; }
  entry="$(grep -F "\"$2\"" <<<"$out" 2>/dev/null || true)"
  case "$entry" in
    *'=> disabled'*) printf 'disabled\n' ;;
    *'=> enabled'*)  printf 'enabled\n' ;;
    '')              printf 'unset\n' ;;     # the read ANSWERED: no override for this label (healthy)
    *)               printf 'unknown\n' ;;   # an entry we cannot classify
  esac
}

launchd_job_state() {
  local d out rc unknown="" target=""
  for d in "gui/$(id -u)" "user/$(id -u)"; do
    out="$(launchctl print "$d/$LABEL" 2>&1)"; rc=$?
    [ "$rc" -eq 0 ] && { printf '0 %s\n' "$d"; return 0; }
    case "$out" in *"Could not find domain"*) continue ;; esac
    # this domain EXISTS (it did not reject the domain itself), so it is where a bootstrap belongs
    [ -n "$target" ] || target="$d"
    if [ "$rc" -eq 113 ]; then continue; fi
    case "$out" in
      *"Could not find service"*|*"not find service"*|*"service not found"*) continue ;;
      *) unknown=1 ;;
    esac
  done
  if [ -n "$unknown" ]; then printf '2 -\n'; return 0; fi
  # ⛔ NO DOMAIN ACCEPTED THE TARGET SPECIFIER ⇒ UNKNOWN, NOT "ABSENT" (review P2, cycle 3 of #1986).
  # When BOTH reads were a domain-level rejection the loop never set `target`, and the old
  # `${target:-gui/$(id -u)}` fallback printed state 1 — the state that authorises `enable`+`bootstrap` —
  # for a read that established nothing about the job, in the very domain it had just rejected. That
  # contradicted the ⛔ note above ("does NOT count as a place to load into") and T2's polarity. With no
  # accepted domain the only safe answer is UNKNOWN, whose whole consequence is a `kickstart`.
  [ -n "$target" ] || { printf '2 -\n'; return 0; }
  printf '1 %s\n' "$target"
}
# RESTART_VERB — the one platform verb this pass issued, for the caller's failure line. A bare
# `RESTART-FAILED rc=1` cannot be acted on: `enable`, `bootstrap`, `kickstart` and the cell supervisor
# fail for completely different reasons, and the reader had to guess which one this was.
RESTART_VERB=""
restart_stack() {
  local rc=0
  # this invocation's own answer: a caller must never inherit a previous pass's refusal (or its absence)
  RESTART_REFUSED=0
  if [ -n "${WATCHDOG_RESTART_CMD:-}" ]; then
    # TESTS ONLY: an exact stand-in for the platform verb, so every case is driven hermetically.
    RESTART_VERB="$WATCHDOG_RESTART_CMD"
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
      if ! command -v launchctl >/dev/null 2>&1; then
        # ⛔ A REFUSAL, NOT A FAILED VERB (review P2, cycle 3 of #1986): no `launchctl` on this box's
        # PATH means NOTHING WAS ISSUED, so `main` must not report `RESTART-FAILED … verb=unknown` — the
        # sixth arm of this function, and the same invariant the plist and cell arms were fixed for.
        # §8b(k) covers it (uname shim = Darwin, no launchctl anywhere on the fixture PATH).
        rc=127
        RESTART_REFUSED=1
        log_line "verdict=RESTART-UNAVAILABLE"$'\t'"note=no launchctl on this box's PATH — nothing was issued (this is the macOS arm, so the job cannot be recovered from here)"
      else
        # ⛔ A PINNED BINARY THAT IS NOT THE ONE ON PATH REFUSES EVERY VERB — INCLUDING THE READS.
        # The Darwin arm is the one place this file executes another program that can MUTATE the box, and
        # a test enters it behind a PATH shim. Under `set -uo pipefail` with no `-e`, a shim write that
        # failed used to leave the case running against the LIVE `/bin/launchctl` — measured shape: a real
        # `kickstart -k gui/501/…` issued from a unit test. `WATCHDOG_NO_RESTART` could not prevent it
        # (the arm that must be exercised has to unset it, which is the whole point of the case), so the
        # protection is a comparison of the RESOLVED PATH against a pin: whatever answers, it is named by
        # the caller, and if it is not, nothing runs.
        if [ -n "${WATCHDOG_LAUNCHCTL_PIN:-}" ]; then
          local lc; lc="$(command -v launchctl 2>/dev/null)"
          if [ "$lc" != "$WATCHDOG_LAUNCHCTL_PIN" ]; then
            log_line "verdict=RESTART-REFUSED"$'\t'"note=WATCHDOG_LAUNCHCTL_PIN=${WATCHDOG_LAUNCHCTL_PIN} but launchctl resolves to ${lc:-nothing} — NO launchctl verb was issued (not even the state read); whatever would have answered is not the binary this caller pinned"
            RESTART_REFUSED=1; return 1
          fi
        fi
        # ONE restart, but WHICH verb depends on a MEASURED state — see launchd_job_state above. A
        # loaded job takes the wedge-curing `kickstart -k` IN THE DOMAIN IT WAS FOUND IN; a job launchd
        # has REMOVED is re-enabled (a `-w` unload leaves a persistent Disabled override, and `bootstrap`
        # of a disabled label is a no-op that can still exit 0) and then `bootstrap`ed from its plist. An
        # UNKNOWN read takes the kickstart: it is the action that cannot double-load a job that exists,
        # and refusing to act on an unreadable state is exactly how the measured hour was spent.
        local st state dom
        st="$(launchd_job_state)"; state="${st%% *}"; dom="${st##* }"
        case "$state" in
          1)
            # ⛔ THE TRIGGER IS "THE CONTROLLER IS GONE", NOT "THE CONTROLLER IS WEDGED" (review P1,
            # #1986). Re-probed HERE, at the moment of the mutation, and not inherited from the pass's
            # first reading: the whole point is that no `bootstrap` may land beside a process that is
            # still running. `WEDGED` is exactly such a state, and `main` cannot tell them apart at this
            # call site — so this arm asks.
            local live; live="$(controller_pid)"
            if [ -z "$live" ]; then
              # ⛔ THE SECOND PROBE, SCOPED TO THE TREE launchd ACTUALLY RUNS (review P1, cycle 3 of
              # #1986). `controller_pid` scans the LOCK and two PATH-SCOPED argv patterns that name
              # `$O` and `$SELF_DIR` — and on a shipped box NEITHER is the controller's path (see
              # `PIN_ROOT` above). So without this the guard is LOCK-ONLY, and the dangerous case is
              # exactly a controller alive with an ABSENT or STALE lock — the case `orch-loop.sh:1575-1577`
              # lets a newcomer TAKE OVER. Measured by review: a live controller at the pinned path plus
              # no lock produced `enable` + `bootstrap` over it.
              # ⛔ SCOPED, NOT A BLANKET `pgrep -f orch-loop.sh`: on a box that also runs a controller for
              # another root (or a second checkout), a blanket scan REFUSES FOR EVER and the arm — which
              # exists to put a REMOVED controller back — never fires. The three roots here are the
              # deploy path, this file's own tree, and the pin root; a fourth is a follow-up, not a reason
              # to trade a dead arm for a safe one.
              # ⛔ OVER-REFUSING WITHIN THOSE ROOTS IS DELIBERATE: a withheld bootstrap costs one retry on
              # the next pass, while a bootstrap beside a live controller is two controllers on one PR
              # queue (#1715). `pid_is_controller` still gates each candidate, so a recycled pid or a
              # look-alike without `orch-loop.sh` in its argv is not evidence of life.
              local _pat _cand
              # ⛔ THE PIN-TREE PATTERN IS INTERPRETER-ANCHORED, LIKE ITS TWO SIBLINGS (review P2, cycle 6).
              # It used to be a bare path, and `pid_is_controller` accepts any argv merely CONTAINING
              # `orch-loop.sh` — so an editor, a `tail -f` or a `git diff` left open on the controller file
              # was read as "a controller is ALIVE" and withheld the restore for as long as it lived, then
              # named it as the controller in the durable log (measured). `(^|/)bash ` keeps the shapes the
              # box actually launches (`/bin/bash …` and `bash …`) and drops the look-alikes. RESIDUAL,
              # stated because it is the dangerous direction: a controller started through a DIFFERENT
              # interpreter would no longer be seen by this pattern — the same residual the other two
              # patterns already carry, which is why this makes the set CONSISTENT rather than adding it.
              for _pat in "bash ${O}/orch-loop.sh" "bash ${SELF_DIR}/orch-loop.sh" \
                          "(^|/)bash +${PIN_ROOT}/[^ ]*/scripts/orchestrator-harness/(orch-loop|launchd-controller)\.sh"; do
                for _cand in $(pgrep -f "$_pat" 2>/dev/null); do
                  [ "$_cand" = "$$" ] && continue
                  if pid_is_controller "$_cand"; then live="$_cand"; break 2; fi
                done
              done
            fi
            if [ -n "$live" ]; then
              log_line "verdict=RESTART-REFUSED"$'\t'"pid=$live"$'\t'"note=$LABEL is NOT in any launchd domain, but a controller (pid $live) is ALIVE — NOT bootstrapping: over a job an operator deliberately stopped this reverses that stop, a bootstrapped job that then loses the lock race exits at once so KeepAlive thrashes it, and where that controller's lock is absent or stale the newcomer WOULD take over — a SECOND controller on one PR queue. Nothing was issued; if the box needs this controller replaced, stop it first (the handoff ritual) and the next REMOVED pass will restore it"
              RESTART_REFUSED=1; return 1
            elif [ ! -f "$PLIST_PATH" ]; then
              # ⛔ ALSO A REFUSAL, FOR THE SAME REASON (review P2, #1986): NOTHING WAS EXECUTED. Without
              # the flag `main` emitted a second, FALSE verdict over this one — `RESTART-FAILED rc=127
              # verb=unknown note=the platform restart verb failed` — while the only launchctl calls in
              # the pass were the two `print` reads. The arm below states the verdict and its reason;
              # `main` must not restate it as a failed verb. §8b(c) asserts RESTART-FAILED is ABSENT.
              RESTART_REFUSED=1; rc=127
              # ⛔ THE REMEDY IS LABEL-DEPENDENT (review P2, cycle 2 of #1986). `install.sh` renders
              # `com.eldato.orchestrator-loop` (see `PLIST_PATH` above), which IS this arm's subject when
              # LABEL is that label — so a hardcoded "it repairs the loop label and NOT this one" withheld
              # the one provisioning verb that is CORRECT on such a box, and contradicted the note beside
              # it in the same record. For any other label (the default `com.eldato.orchestrator-stack`)
              # install.sh would render a DIFFERENT job, so naming it there would install that job beside
              # the box's supervision model.
              local _remedy
              if [ "$LABEL" = "com.eldato.orchestrator-loop" ]; then
                _remedy="install.sh renders THIS label ($LABEL) at this same path, so it is the correct provisioning verb on this box"
              else
                _remedy="install.sh renders only com.eldato.orchestrator-loop — a DIFFERENT job — so it does not repair this label ($LABEL); provision $LABEL's plist from whatever provisioned the job"
              fi
              log_line "verdict=RESTART-UNAVAILABLE"$'\t'"note=$LABEL is NOT loaded and no $PLIST_PATH exists — there is nothing to bootstrap, so nothing was issued; provision the plist for $LABEL at that path"$'\t'"detail=$_remedy"
            else
              # ⛔ PROVENANCE BEFORE MUTATION (review P1, cycle 4 of #1986). This branch used to go
              # straight from "the file exists" to `enable` + `bootstrap`. `bootstrap` resolves the job
              # by the plist's OWN Label, so a stale/copied/foreign plist at `$PLIST_PATH` would enable
              # a label it does not hold and load a DIFFERENT job beside this box's supervision model
              # (#1761/#1715) — then report the result as a failed restart of a controller nothing
              # touched. `plist_not_this_job` proves it first, and a failed proof is a REFUSAL, not a
              # failed verb: nothing is issued.
              local _plist_why
              if _plist_why="$(plist_not_this_job "$PLIST_PATH")"; then
                log_line "verdict=RESTART-REFUSED"$'\t'"plist=$PLIST_PATH"$'\t'"note=$LABEL is NOT loaded and a plist exists at $PLIST_PATH, but it is NOT this job: $_plist_why — NOTHING was issued, because launchctl bootstrap resolves the job by the plist's own Label, so loading it would load a DIFFERENT job beside this box's model (the #1761/#1715 duplicate-controller class) and report it as a failed restart of a controller it never touched. Point WATCHDOG_PLIST at $LABEL's own plist, or provision it there"
                RESTART_REFUSED=1; return 1
              fi
              # ⛔ AN `enable` THAT FAILS STOPS THE ARM — it is not swallowed. It used to be
              # `enable … || true`, so a REFUSED verb fell through to a `bootstrap` of a label that may
              # still be disabled (a documented silent no-op that can exit 0) and the pass then reported
              # STILL_NOT_CYCLING — i.e. a refusal was presented as "the restart did not work" (review
              # P2, #1986). The rc propagates, so the caller says RESTART-FAILED and names the verb.
              RESTART_VERB="launchctl enable $dom/$LABEL"
              launchctl enable "$dom/$LABEL" >>"$LOG" 2>&1 || rc=$?
              if [ "$rc" -eq 0 ]; then
                # ⛔ THE ENABLE IS VERIFIED, NOT ASSUMED (review P2, cycle 7 of #1986). Same read-back,
                # same words, same reason as `launchd-cycle.sh`'s `lc_start` — which is where this whole
                # sequence comes from, and which the PR body claims this arm already matches. A DEFINITE
                # `disabled` means the override did not clear, so the load would either fail or succeed
                # into a state the next boot loses: refuse and say what an operator must run. Anything
                # UNREADABLE is a warning and the bootstrap decides — an unknown must not become a false
                # block either.
                case "$(disable_state "$dom" "$LABEL")" in
                  disabled)
                    RESTART_REFUSED=1
                    log_line "verdict=RESTART-REFUSED"$'\t'"note=launchctl enable $dom/$LABEL exited 0, but the persistent Disabled override STILL reads 'disabled' — NOT bootstrapping: the load would either fail or succeed into a state the next boot loses. Next: launchctl enable $dom/$LABEL; launchctl print-disabled $dom | grep $LABEL"
                    return 1 ;;
                  unknown)
                    log_line "verdict=RESTART-WARN"$'\t'"note=could not read whether $LABEL is disabled (launchctl print-disabled gave no usable answer) — continuing, because the bootstrap below is the proof" ;;
                esac   # `enabled` and `unset` (no override recorded — the healthy state) proceed silently
                # ⛔ THE LEGACY FALLBACK IS HERE FOR THE MEASURED REASON `lc_start` CARRIES IT: on
                # 2026-10-17 `bootstrap` failed with EIO and plain `load` is what brought the controller
                # back. Without it this arm reports RESTART-FAILED for ever on a box in that state, and
                # the one verb that works is never tried. WHICH path ran is what RESTART_VERB records, so
                # the next operator does not have to guess. `load` is PLAIN, never `load -w`, which would
                # write the disable straight back.
                RESTART_VERB="launchctl bootstrap $dom $PLIST_PATH"
                if launchctl bootstrap "$dom" "$PLIST_PATH" >>"$LOG" 2>&1; then
                  rc=0
                else
                  rc=$?
                  log_line "verdict=RESTART-WARN"$'\t'"note=launchctl bootstrap $dom exited $rc — trying the legacy 'load' path, which is what brought the controller back when bootstrap failed with EIO (measured 2026-10-17)"
                  RESTART_VERB="launchctl load $PLIST_PATH"
                  if launchctl load "$PLIST_PATH" >>"$LOG" 2>&1; then rc=0; else rc=$?; fi
                fi
              fi
            fi ;;
          0)
            RESTART_VERB="launchctl kickstart -k $dom/$LABEL"
            launchctl kickstart -k "$dom/$LABEL" >>"$LOG" 2>&1 || rc=$? ;;
          *)
            # UNKNOWN: the read established nothing. `kickstart` cannot double-load a job that exists, so
            # it is the only safe polarity — and it is the one that was measured to cure the wedge.
            RESTART_VERB="launchctl kickstart -k gui/$(id -u)/$LABEL"
            launchctl kickstart -k "gui/$(id -u)/$LABEL" >>"$LOG" 2>&1 || rc=$? ;;
        esac
      fi ;;
    *)
      # ⛔ NOT a second launcher and NOT a systemd unit invented here: on a cell the controller is
      # started by the cell supervisor, and `start` is the SAME verb the doctor role runs to bring
      # one back (cloud-cell-doctor.sh's controller arm). If the supervisor is not on this box, say so
      # and change nothing — a watchdog that invents its own launch path races the real one.
      local sup="${SUPERVISOR:-}"
      [ -n "$sup" ] || { [ -f "$O/cloud-cell-supervisor.sh" ] && sup="$O/cloud-cell-supervisor.sh"; }
      [ -n "$sup" ] || { [ -f "$SELF_DIR/../cloud-cell-supervisor.sh" ] && sup="$SELF_DIR/../cloud-cell-supervisor.sh"; }
      if [ -n "$sup" ] && [ -f "$sup" ]; then
        # ⛔ THE SUPERVISOR PIN (review P2, cycle 3 of #1986) — the cell arm's equivalent of
        # WATCHDOG_LAUNCHCTL_PIN, and for the same measured reason: this branch executes a binary that
        # starts the box's controller, and its own fallback (`$SELF_DIR/../cloud-cell-supervisor.sh`)
        # resolves to the REAL supervisor in any checkout. A caller that pins a path gets nothing run
        # when what would run is not that path.
        if [ -n "${WATCHDOG_SUPERVISOR_PIN:-}" ] && [ "$sup" != "$WATCHDOG_SUPERVISOR_PIN" ]; then
          log_line "verdict=RESTART-REFUSED"$'\t'"note=WATCHDOG_SUPERVISOR_PIN=${WATCHDOG_SUPERVISOR_PIN} but the supervisor resolves to ${sup} — NO supervisor verb was issued; whatever would have answered is not the binary this caller pinned"
          RESTART_REFUSED=1; return 1
        fi
        # ⛔ PIN `ORCH_FOREGROUND=0` (review P2, #2402). A watchdog that itself runs INSIDE a service-managed
        # controller's environment inherits `Environment=ORCH_FOREGROUND=1` from the unit (it is exported into
        # the whole controller tree, and a tmux server started by that controller carries it to every lane
        # shell). Inherited, `start` takes the FOREGROUND branch: it parks inside the handover wait for up to
        # CONTROLLER_HANDOVER_TIMEOUT instead of delegating to the unit — the same inheritance the doctor pins
        # against, at a call site the doctor's pin cannot reach.
        RESTART_VERB="$sup start"
        ORCH_FOREGROUND=0 bash "$sup" start >>"$LOG" 2>&1 || rc=$?
      else
        rc=127
        # ⛔ THE SAME REFUSAL, ON THE CELL ARM (review P2, cycle 2 of #1986). This branch issued NOTHING
        # — there is no supervisor to run — so it must not be followed by `main`'s RESTART-FAILED
        # (`verb=unknown`), which claims a platform verb ran and failed. The plist arm above and this one
        # are the same class; the invariant stated there ("a deliberate refusal is not a failed verb")
        # holds on every platform, and a cell farm deployed by `cp *.sh` (agent-infra#2041) is exactly
        # where this arm is reached. §8c asserts RESTART-FAILED is ABSENT here too.
        RESTART_REFUSED=1
        log_line "verdict=RESTART-UNAVAILABLE"$'\t'"note=no supervisor resolved — looked at \$SUPERVISOR, \$O/cloud-cell-supervisor.sh and \$SELF_DIR/../cloud-cell-supervisor.sh; nothing was restarted"
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
    # ⛔ THE LAST BLOCK, NOT THE FIRST THREE LINES (review P2, cycle 8). `record_crash` APPENDS per
    # episode and the 64 KiB trimmer keeps the TAIL, so `sed -n '1,3p'` printed the OLDEST episode while
    # the header one line above reported the CURRENT one — during an outage the operator read a previous
    # episode's `cause:` under a report that named a different episode (measured: `episode: 2` above
    # `episode=1 … cause: EPISODE-ONE`). Start at the LAST line that begins with an ISO timestamp — the
    # shape `record_crash` writes as each block's header — so the block shown is the one that matters.
    # ⛔ THE HEADER IS `<ISO>Z<TAB>verdict=…`, NOT `<ISO>Z<SPACE>` (review P1, cycle 9). The evidence
    # lines `record_crash` embeds are the controller's own log lines, and those are written as
    # `<ISO>Z<SPACE>[startup] …` (`nochk-guard.sh:27`, `orch-loop.sh:460`) — so a timestamp+space match
    # selected an EMBEDDED line and `--status` printed one stray tail line with no `cause:` at all, under
    # a header naming the current episode: the same "superseded evidence" complaint, in a new form. The
    # selector requires the header's own separator AND the date shape, so an embedded log line cannot win.
    awk 'BEGIN { last = 0 }
         { lines[NR] = $0
           if (index($0, "Z\tverdict=") == 20 && substr($0, 1, 19) ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/) last = NR }
         END { if (last == 0) last = 1; for (i = last; i <= NR; i++) print lines[i] }' "$CRASH_FILE" 2>/dev/null
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
  local pid age verdict reason streak=0 restart=0 rc=0 episode=0 announced=0 decision_line=""

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
  local prev_episode; prev_episode="$(cat "$EPISODE_FILE" 2>/dev/null || echo 0)"
  case "${prev_episode:-}" in ''|*[!0-9]*) prev_episode=0 ;; esac
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
    decision_line="verdict=PROBE_RESTART"$'\t'"pid=${pid:-none}"$'\t'"heartbeat=${age}s"$'\t'"streak=${streak}/${MAX_CONSEC}"$'\t'"restart=1"$'\t'"episode=$episode"$'\t'"reason=observation ${obs} of this episode (> 2x${MAX_CONSEC}) — ONE probe restart, continuing the same episode with the budget spent (a dead box must not stay dead for ever; the next probe comes $((${MAX_CONSEC} + 1)) passes after this one)"
    announced=1          # the decision is COMPOSED here; it is emitted only once the arm issued a verb
  fi

  [ "${announced:-0}" = "1" ] || decision_line="verdict=$verdict"$'\t'"pid=${pid:-none}"$'\t'"heartbeat=${age}s"$'\t'"streak=${streak}/${MAX_CONSEC}"$'\t'"restart=1"$'\t'"reason=$reason"

  # ── 4. ONE restart, then PROVE it after a settle window. Never a second restart in this pass: a
  #       loop that restarts until something looks healthy is the behaviour this file replaces.
  restart_stack || rc=$?
  # ⛔ A REFUSAL IS ITS OWN VERDICT, already stated WITH ITS REASON by the arm that refused. It must not
  # become RESTART-FAILED (nothing was executed, so nothing failed) and must not reach the settle re-read
  # (there is nothing to settle into), which is how a refusal used to surface as STILL_NOT_CYCLING.
  # The flag, not `rc`: see its declaration — a reserved exit code collides with a verb that fails with
  # that same value, and a failed `kickstart` must stay a FAILED kickstart.
  if [ "${RESTART_REFUSED:-0}" -eq 1 ]; then
    # ⛔ AND A REFUSAL COSTS NOTHING (review P2, cycle 4 of #1986), in both directions:
    #   * NO CLAIM. The decision line above carries `restart=1` and, at the cap, "ONE probe restart". It
    #     used to be EMITTED BEFORE this test, so every refusal pass logged a restart — and a probe
    #     restart — for a pass in which `launchctl.calls` held nothing but `print` lines. That is the
    #     exact false claim cycle 3 removed from the arm's own lines, left alive one line above them.
    #   * NO BUDGET. The streak AND the episode are restored to the values this pass READ, because a
    #     WITHHELD restart is not a restart that FAILED. Counting refusals against the consecutive cap
    #     let three harmless refusals latch the box into `<verdict>_STOPPED` and then withheld the arm
    #     for up to `2 x MAX_CONSEC` further passes — trading a dead arm for a safe one, which this arm's
    #     own comment refuses. The episode matters for the same reason cycle 6 found it: the bump is
    #     PERSISTED during the pass, so leaving it alone made every refusal consume an episode number
    #     (measured: `episode=1,2,3,4,5` across five refusals with `streak=0` throughout), and the crash
    #     record's `episode=` — whose whole purpose is "a new streak is a NEW crash loop" — degenerated
    #     into a pass counter (~288/day at the 300 s cadence) that no operator can correlate.
    printf '%s' "${prev_streak:-0}" 2>/dev/null > "$STREAK_FILE" || true
    printf '%s' "${prev_episode:-0}" 2>/dev/null > "$EPISODE_FILE" || true
    # ⛔ THE OBSERVATION IS STILL RECORDED — with `restart=0`, which is the honest claim. Dropping the
    # decision line entirely on a refusal would lose the measured verdict (WEDGED/DOWN) that the arm's
    # refusal is a statement ABOUT; keeping it with `restart=1` is the false claim above. Both halves are
    # pinned: (r) asserts `restart=0` and no `restart=1` on a refusal pass, 8b(f) asserts the WEDGED
    # observation survives it.
    log_line "verdict=$verdict"$'\t'"pid=${pid:-none}"$'\t'"heartbeat=${age}s"$'\t'"streak=${prev_streak:-0}/${MAX_CONSEC}"$'\t'"restart=0"$'\t'"reason=$reason"$'\t'"note=the restart was WITHHELD — the arm that refused stated why above, and this pass consumed no restart budget. ⛔ NOT no platform verb was issued: the one arm that refuses AFTER reaching launchd (the persistent Disabled override still reading 'disabled' following a successful enable) has already said so in its own line above, and for every other refusing arm nothing was issued"
    return 0
  fi
  log_line "$decision_line"
  if [ "$rc" -ne 0 ]; then
    log_line "verdict=RESTART-FAILED"$'\t'"pid=${pid:-none}"$'\t'"rc=$rc"$'\t'"verb=${RESTART_VERB:-unknown}"$'\t'"note=the platform restart verb failed; nothing else was attempted"
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
