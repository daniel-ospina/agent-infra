#!/usr/bin/env bash
# fleet-inventory.sh — THE DECLARED INVENTORY of the fleet's long-lived processes, and the ONE table
# that says whether each of them is alive.
#
# ── WHY THIS FILE EXISTS (owner, 2026-10-18) ────────────────────────────────────────────────────
# The fleet's processes were started from several places with no single inventory: the lane
# controller (`orch-loop.sh`), the launchd watchdog, `watchdog-loop.sh`, `pr-doctor`, the
# heartbeat/cadence nudge, the landers, the reapers, and the cloud-cell supervisor. Every failure
# that produced was SILENT, and all of them were observed on one night:
#
#   * a second controller ran at the same time as launchd's — DUPLICATE dispatch;
#   * the same controllers were ABSENT on two of three cells and nothing noticed;
#   * `pr-doctor` exited 2 on every run for hours and nothing noticed (its job's last exit status
#     was readable the whole time — nothing read it);
#   * `cmux-tui` was OOM-killed and nothing noticed, so the cells reported "no controller";
#   * landers expired silently, so green PRs waited for a human.
#
# The owner's requirement, verbatim: "one script that runs every fleet process and also CHECKS they
# are all alive — so we get neither broken duplication nor a component that is silently off,
# missing, or running twice."
#
# ── THE RULE THIS FILE IS BUILT ON ──────────────────────────────────────────────────────────────
# Every component's liveness predicate is derived from ITS OWN expected behaviour, never from a
# generic "pid exists":
#
#   * a CONTROLLER is a process running THIS state dir's `orch-loop.sh`, and its freshness signal is
#     `$O/heartbeat` (it rewrites it every cycle) — a live pid with a frozen heartbeat is a wedged
#     controller, not a healthy one;
#   * a PIDFILE LOOP (`heartbeat-loop.sh`, `cadence-timer.sh`) is a process whose ARGV is that
#     script, cross-checked against the pid its OWN pidfile names — a recycled pid fails the cross
#     check instead of reading as alive;
#   * a LAUNCHD PERIODIC JOB (`pr-doctor`, the reapers) is NOT "a pid exists": between runs pid is
#     legitimately `-`. Its predicate is: the job is LOADED, its last run exited 0 (the readable
#     datum nobody read — `com.tortoise.pr-doctor` sat at exit 2 for hours), and its OWN standard
#     output has been written within two of ITS OWN `StartInterval`s (read from the plist, so a 6h
#     reaper is not judged by a 20-minute reaper's clock);
#   * a LANDER has no daemon form — it is demand-driven, so 0 live is normal. Its predicate is a
#     BOUND: every live one is younger than the wait it is allowed (a waiter past its own bound is
#     the "expired silently" state that parked green PRs);
#   * the CELL SUPERVISOR is applicable only on a cell; on a Mac it is SKIPPED with a reason, never
#     silently OK.
#
# ── DUPLICATE IS A FIRST-CLASS STATE, NOT A COUNT IN A DETAIL STRING ───────────────────────────
# A lock file is NOT proof of singularity: the measured duplicate ran with a lock present (a
# launcher had removed it, or two state dirs ran the same repo). So every component is counted from
# a LIVE PROCESS READ, and more than one distinct instance is DUPLICATE. A periodic job's own
# in-flight run is the SAME pid launchd reports, so the counts are de-duplicated by pid — otherwise
# every running job would report itself twice.
#
# ── SELF-MATCH SAFETY (this bug bit the fleet repeatedly) ───────────────────────────────────────
# `pgrep -f "orch-loop.sh"` counts the shell that ran it. Every read here matches the process's
# ARGV SHAPE — `<interpreter> <EXACT path>` — so
#     bash -c 'grep pr-doctor.py …'        # a shell running TEXT that mentions the script
#     bash scripts/fleet-inventory.test.sh # the checker
#     tail -f …/orch-loop.log              # a reader of the log
# can never match: their argv does not have the script as its second token. Descendants of a matched
# process are excluded too (`orch-loop.sh` spawns short-lived children whose command line also
# matches — the false duplicate #1761 warns a per-box read must avoid). The checker's own pid is the
# ONLY self-barrier (`q == self`): **ancestors are deliberately KEPT**, so a health read that runs
# beneath the controller (a tick added to `orch-loop.sh`, a lane child) still counts it. Excluding
# ancestors was measured to read a live, fresh controller as MISSING.
#
# ── STATES, AND WHY SKIPPED IS NOT OK ──────────────────────────────────────────────────────────
#   OK         the component's own signal says it is alive and fresh
#   LATE       alive, but its own freshness signal is older than its own bound
#   MISSING    expected on this box and not there
#   DUPLICATE  more than one live instance (the state that consumes a repo's queue twice)
#   FAILING    present but reporting failure (a non-zero last exit, a pidfile that names the wrong
#              process)
#   SKIPPED    NOT APPLICABLE on this box — always with a reason. It is a PASS for the exit code
#              (a Mac is not broken for having no cell supervisor) and it is never rendered as OK,
#              because "not checked" and "checked and healthy" are different answers.
#   UNKNOWN    the check itself could not be performed (an unreadable process table, an unparseable
#              job definition). Fail-closed: it is never a pass — the abstention doctrine this repo
#              already applies to lane liveness (`docs/ops/fleet-liveness.md`).
#
# Exit code of the table: 0 all rows OK or SKIPPED · 1 any row not OK · 2 any row UNKNOWN. That is
# the same 0/1/2 contract `orchestrator-bringup.sh` uses, so one screen has one vocabulary.
#
# Sourced by `scripts/orchestrator-bringup.sh` (the fleet's ONE entry point). It deliberately does
# NOT call `set`: a sourced library must not mutate its caller's shell options.

# ── seams ──────────────────────────────────────────────────────────────────────────────────────
# Every path and every binary below is overridable so the regression suite can drive THIS code
# hermetically (temp HOME, temp state dirs, a `launchctl`/`ps` stub) — and so a box with a
# different layout can be checked without editing the file. The defaults are the shipped layout.
FLEET_HOME="${FLEET_HOME:-$HOME}"
# A cell's identity marker (see fleet_row_cell_supervisor): the kernel alone does not make a box a cell.
# `CELL_HOME` is the seam the entry point ALREADY uses on a cell, so it is read here too — a marker
# nothing sets is an instrument that cannot answer its own question.
FLEET_CELL_HOME="${FLEET_CELL_HOME:-${CELL_HOME:-}}"
# The controller's state dir. The caller (`orchestrator-bringup.sh`) sets this from ITS resolved
# `O=`/`O` (env > config file > platform default) — captured here only as a fallback, because a
# second default would be a second answer to "which directory holds the lock".
FLEET_O="${FLEET_O:-${O:-$FLEET_HOME/orchestrator}}"
# ⛔ NO `:-mac` DEFAULT. A caller that does not say which platform it is on must NOT be assumed to be
# a Mac: on a cell the `cell-supervisor` row would then render `SKIPPED (not applicable on mac)` — a
# PASS on the one box where that component is the thing that keeps the controller alive. Unset means
# the row cannot be answered, and it says so.
# ── WHO OWNS WHAT (read this before adding a verb) ───────────────────────────────────────────
# This file is a READER plus three narrow verbs. It does not replace any other surface:
#   scripts/install-launchd.sh                      the INSTALLER (owns templates/launchd/)
#   scripts/orchestrator-harness/launchd-cycle.sh   the one stop/enable/(re)start that writes no
#                                                   disable (#1975)
#   scripts/cloud-cell-supervisor.sh                a cell's controller tmux session
# Its verbs write NOTHING durable (`bootstrap` / `kickstart` / `bootout`, never `enable`/`unload -w`),
# which has one consequence worth stating: after `stop`, re-running the installer does NOT reload the
# jobs (it skips a byte-identical plist), so **`start` — not a re-install — is the undo**.

FLEET_PLATFORM="${FLEET_PLATFORM:-${PLATFORM:-}}"
FLEET_AGENT_STATE="${FLEET_AGENT_STATE:-$FLEET_HOME/.pi/agent/state}"
FLEET_AGENT_SCRIPTS="${FLEET_AGENT_SCRIPTS:-$FLEET_HOME/.pi/agent/scripts}"
FLEET_LAUNCH_AGENTS_DIR="${FLEET_LAUNCH_AGENTS_DIR:-$FLEET_HOME/Library/LaunchAgents}"
FLEET_LAUNCHCTL="${FLEET_LAUNCHCTL:-launchctl}"
FLEET_PS="${FLEET_PS:-ps}"
FLEET_PLUTIL="${FLEET_PLUTIL:-plutil}"
FLEET_TMUX="${FLEET_TMUX:-tmux}"
FLEET_UID="${FLEET_UID:-$(id -u 2>/dev/null || printf '0')}"
# The controller's freshness bound. `orch-loop.sh` sleeps `CYC` (240s default, minus a jitter share,
# plus each cycle's own work), so 1800 s of silence is many cycles — the point at which "alive" stops
# meaning "working". Deliberately stated as "many cycles" rather than a cycle COUNT: a cycle's work is
# unbounded, so any precise multiple would be a number nothing pins.
FLEET_CONTROLLER_LATE_S="${FLEET_CONTROLLER_LATE_S:-1800}"
# The heartbeat loop's bound: ~45 min, about FIVE passes of the loop's own ~9 min total-pass budget
# (`TARGET=540`, and the sleep is target-minus-elapsed — not a fixed interval added on top). NOT three
# passes (that is the controller's 1800 s), and not the "9-11 min pass" figure `cadence-timer.sh`'s
# header still quotes from the design that predated the total-pass budget.
FLEET_HEARTBEAT_LATE_S="${FLEET_HEARTBEAT_LATE_S:-2700}"
# The cadence timer's bound: its own default interval is 450s (CADENCE_TIMER_INTERVAL), and a
# delivered message is what it exists to produce. Four intervals of silence is late, not merely slow.
FLEET_CADENCE_LATE_S="${FLEET_CADENCE_LATE_S:-1800}"
# A lander's bound. `chain-merge.sh` waits at most 90 min for a PR to exist and then runs the merge.
# 150 min is a PLANNING ALLOCATION on top of that wait, not the sum of two named bounds: the merge
# path's own tail (`merge-one.sh`'s 1800 s review bound plus the rail's re-run fail-safe) is not
# bounded by the remaining 60 min, so a busy chain-merge can outlive this row and read EXPIRED. That
# direction is deliberate — over-reporting a busy lander costs a look, while under-reporting is the
# parked-green-PR state this row exists for.
# A waiter past it is the EXPIRED state the owner observed parking green PRs, not a slow one.
FLEET_LANDER_BOUND_S="${FLEET_LANDER_BOUND_S:-9000}"
# ── component: the DRAIN LOOP (`lander.sh`) ───────────────────────────────────────────────────
# A DIFFERENT component from the landers row: those are per-PR waiters already alive, this one is the
# loop that DECIDES which PRs are ready to land. It is demand-driven like them (no daemon form, 0 live
# is normal), so its predicate cannot be "a pid exists" — it is FRESHNESS OF ITS OWN RUN RECORD,
# which `lander.sh` writes to `state/lander-last` on every completed run.
#
# ⛔ THE FAILURE MODE THIS ROW EXISTS FOR, and why a bound alone is not enough: the drain loop lived
# as `~/lander-v3.sh` on ONE cloud cell, unversioned. A loop that is not running produces NO error
# anywhere — the fleet keeps opening PRs, the landers row keeps reporting "0 live (demand-driven) OK",
# and green PRs wait for a human. So "no run has ever been recorded" and "the last run is older than
# 2x its own cadence" are both REPORTABLE states, never silence.
# 1800 s = two 15-minute passes: one missed pass is a busy box, two in a row is a loop that is off.
FLEET_LANDER_DRAIN_LATE_S="${FLEET_LANDER_DRAIN_LATE_S:-1800}"
# Set by `fleet_start_component` to WHAT IT DID, so a caller cannot print "started" for a no-op (cycle-3
# review: the verb said "already running, left alone" and the caller then printed "started heartbeat-loop").
FLEET_START_ACTION=""
# Bound on `start`'s SETTLE wait (#2221): how long the post-launch read-back keeps RE-reading after a
# process is up, waiting for the record the row reads to name the process that actually runs it. A
# pidfile loop re-execs itself detached, so the pid the FIRST read sees is the transient LAUNCHER; one
# snapshot inside that handover printed `pid ... pidfile says ... FAILING` for a loop that was healthy
# one second later. `status` never had this defect because it reads once, later.
FLEET_START_SETTLE_S="${FLEET_START_SETTLE_S:-3}"
# Tolerated scheduling slack for launchd periodic jobs, added on top of 2×StartInterval.
FLEET_JOB_SLACK_S="${FLEET_JOB_SLACK_S:-300}"

fleet_say() { printf '%s\n' "$*"; }
# `say` is the ENTRY POINT's reporter; the library's verbs call it. Defaulted here so the verbs can
# be driven from a test (or another caller) without re-declaring it — a verb that can only run under
# one caller is a verb whose mutating paths are asserted nowhere.
# ⛔ `type -t`, NOT `command -v`: macOS SHIPS `/usr/bin/say` (text-to-speech), so `command -v say`
# succeeds and the fallback is never defined — every line this library printed was SPOKEN instead,
# and `status` looked silent. Only a FUNCTION counts as an existing `say`.
[ "$(type -t say 2>/dev/null)" = "function" ] || say() { printf '%s\n' "$*"; }

# ── the process table: ONE read, argv-shape matching, self-match-safe ──────────────────────────
# The awk program is a QUOTED heredoc, not a variable: it contains `$1`, `""` and brackets, and
# re-expanding it would hand awk a mangled program — which fails the read and reads as "no
# component", the false-STOPPED class this whole file exists to prevent (#1856 review).
_fleet_ps_awk() {
  cat <<'AWK'
  { ppid[$1]=$2; c=$0
    sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/, "", c)
    n=split(c, tok, " ")
    if (n >= 2) {
      base=tok[1]; sub(/.*\//, "", base)
      # Only an INTERPRETER's second token can be a script invocation. A shell running TEXT that
      # mentions the path (`bash -c 'pkill -f pr-doctor.py'`) has `-c` there and does not match.
      if (base ~ /^(bash|sh|dash|zsh|python[0-9.]*)$/) {
        for (i in want) if (want[i] != "" && tok[2] == want[i]) { m[$1]=1; break }
      }
    } }
  END {
    # ⛔ THE ONLY SELF-EXCLUSION IS `q == self`, and that is deliberate. Excluding the checker's
    # ANCESTORS was over-broad and measurably wrong: a health check that runs BENEATH the controller
    # (a tick added to `orch-loop.sh`, a lane child, `fix-one.sh`/`chain-merge.sh`) has the controller
    # as an ancestor — so an ancestor barrier reads the controller as MISSING while it is alive and
    # fresh, and the lock cross-check cannot rescue it. MEASURED in review: with the check running as
    # a child of a live `orch-loop.sh`, the row printed MISSING.
    # A DESCENDANT of a match is still not another instance: the controller spawns children whose
    # argv also names its script, and counting them manufactures a duplicate that is not there.
    for (q in m) {
      if (q == self) continue
      y=q; d=0
      for (i=0;i<64;i++) { if (!(y in ppid) || ppid[y] <= 1) break; y=ppid[y]; if (y in m) { d=1; break } }
      if (d) continue
      print q
    }
  }
AWK
}

# fleet_ps_snapshot — the raw table, read ONCE per run so two rows cannot see two different worlds.
fleet_ps_snapshot() {
  if [ -n "${FLEET_PS_CACHE:-}" ]; then printf '%s\n' "$FLEET_PS_CACHE"; return 0; fi
  local t
  t="$("$FLEET_PS" -eo pid=,ppid=,command= 2>/dev/null)" || return 1
  case "$t" in *[![:space:]]*) ;; *) return 1 ;; esac
  FLEET_PS_CACHE="$t"
  printf '%s\n' "$t"
}

# fleet_pids_for <exact-script-path>… — pids running one of these scripts, one per line.
# rc=1 when the process table could not be read (the caller must report UNKNOWN, never OK).
fleet_pids_for() {
  [ "$#" -gt 0 ] || return 0
  local table want
  table="$(fleet_ps_snapshot)" || return 1
  want=""
  local p
  for p in "$@"; do [ -n "$p" ] && want="$want$p"$'\n'; done
  [ -n "$want" ] || return 0
  # ⛔ THE PATH LIST GOES THROUGH THE ENVIRONMENT, never `awk -v`: `-v` interprets backslash escapes
  # and rejects a value containing a real newline ("awk: newline in string"), which is exactly the
  # shape a multi-path list has. A read that fails for a FORMATTING reason reads as "no component
  # running" — the false-STOPPED class this file exists to prevent.
  FLEET_WANT="$want" FLEET_SELF="$$" \
    awk '
    BEGIN { n=split(ENVIRON["FLEET_WANT"], w, "\n"); for (i=1;i<=n;i++) want[i]=w[i]
            self=ENVIRON["FLEET_SELF"] }
    '"$(_fleet_ps_awk)" <<<"$table"
}

# _fleet_lock_owner <state-dir> — the pid `$O/.orch.lock` names, WHEN a fresh ps read shows it
# alive AND its argv is a shell running a script called `orch-loop.sh`.
#
# ⛔ THIS IS AN OWNER-ADDING PREDICATE, NOT A KILL TARGET, and it is deliberately INDEPENDENT of the
# path scopes above: on a cell the controller's argv is the HARNESS path (MEASURED 2026-10-17), and a
# read scoped to paths we guessed would report STOPPED over a busy controller — the #1761 false-STOPPED
# class. The lock is written by the controller FOR ITS OWN state dir, so a live orch-loop.sh named
# there IS this state dir's owner whichever path it execs.
#
# * `kill -0` alone is NOT identity: a pid can be RECYCLED. The argv test is what makes a stale lock
#   file (whose pid now belongs to an unrelated process) contribute NOBODY instead of somebody.
# * It returns 1 only when the process table could not be read (the caller must report UNKNOWN).
_fleet_lock_owner() {
  local o="${1:-}" p table lock_age age now
  # The shared fence slack (`pid-identity.sh:PID_START_SLACK_SECONDS`, 5 s) — the ONE value for
  # "did this pid begin after that record was written". Mirrored here with the same name and default
  # rather than sourced, because this library is farmed standalone (like cloud-cell-supervisor.sh's
  # pinned copy) and must not depend on a sibling. The default is echoed by a parity arm (§9v).
  # ⛔ VALIDATED, because an unvalidated read fails OPEN: `1.5` makes the arithmetic below a bash
  # syntax error, the `[ ]` test fails, `&& return 0` never runs and the recycled-pid fence is
  # SKIPPED — the pid then gets claimed on argv alone. `abc` resolves as an unset name to 0, i.e.
  # the zero-tolerance fence this slack exists to replace. Fail to the documented default instead.
  local slack="${PID_START_SLACK_SECONDS:-5}"
  case "$slack" in ''|*[!0-9]*) slack=5 ;; esac
  [ "$slack" -le 60 ] || slack=5
  [ -n "$o" ] && [ -f "$o/.orch.lock" ] || return 0
  p="$(tr -dc '0-9' 2>/dev/null < "$o/.orch.lock")"
  [ -n "$p" ] || return 0
  kill -0 "$p" 2>/dev/null || return 0            # dead lock owner: nobody
  # ⛔ RECYCLED-PID GUARD (reviewer C measured this file and the bringup disagreeing): the lock's pid
  # must have BEGUN BEFORE the lock was written. Otherwise a stale lock whose pid has been recycled by
  # ANY repo's `orch-loop.sh` reads as this state dir's owner — the bringup's own `lock_pid` already
  # required this, so the two surfaces answered the same question differently. Unknown ages do not
  # disqualify: this check only ever REMOVES a false owner, it never invents one.
  lock_age="$(fleet_file_age "$o/.orch.lock")"
  if [ -n "$lock_age" ]; then
    age="$(fleet_etime_s "$p" 2>/dev/null)"
    if [ -z "$age" ]; then
      # ⛔ CANNOT-TELL IS AN ABSTENTION, NOT AN OWNERSHIP CLAIM. The first version treated an
      # unreadable age as "began before the lock" — i.e. as the strongest possible evidence — so on a
      # box whose `ps` cannot answer `-o etime=` (a shim, a busybox-shaped ps) a two-year-old lock
      # naming a pid since recycled by ANOTHER repo's controller read as this state dir's live owner
      # (#1856's class, and the reason `pid-identity.sh:pid_began_after` returns 2 rather than 1).
      # rc 1 is what the caller renders as UNKNOWN.
      return 1
    fi
    now="$(date +%s)"
    # ⛔ THE FENCE CARRIES THE SHARED SLACK. Without it this refused HEALTHY controllers (#2030 CI
    # red). The two sides come from DIFFERENT CLOCK SOURCES, not from truncation: `fleet_file_age`
    # dates the lock from its mtime (exact), while `fleet_etime_s` dates the process from `ps -o
    # etime=`, which procps derives from `/proc/<pid>/stat` + `btime` — a 1 s-granularity reading
    # that can place the start up to a second LATE. So a controller that started as its own lock was
    # written can derive a start one second AFTER the lock, and a zero-tolerance "began after the
    # lock ⇒ recycled" then refuses the owner of a HEALTHY state dir: the row reads MISSING, a live
    # controller reported as absent — the false-absent class this file exists to prevent. (Flooring
    # alone is monotone and cannot invert; the disagreement between the two clocks is what does.)
    # Measured: Linux procps, fixture spawned 0.3 s before the read → etime=0 against lock_age=1.
    # A genuinely recycled pid is minutes or hours younger than the lock, never one second, so the
    # shared slack removes the disagreement without weakening the guard — and it is the SAME
    # predicate `pid-identity.sh:pid_began_after` has always applied (`ps > epoch + slack`).
    [ "$(( now - age ))" -gt "$(( now - lock_age + slack ))" ] && return 0
  fi
  table="$(fleet_ps_snapshot)" || return 1
  printf '%s\n' "$table" | awk -v p="$p" '
    $1 != p { next }
    { c=$0; sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/, "", c)
      n=split(c, t, " ")
      if (n >= 2) { b=t[1]; sub(/.*\//, "", b)
        if (b ~ /^(bash|sh|dash|zsh)$/ && t[2] ~ /(^|\/)orch-loop\.sh$/) print p } }'
}

# fleet_pid_argv_names <pid> <basename> — does this pid's argv name a script with that BASENAME?
# Deliberately weaker than `fleet_pids_for` (exact path) and used only to REFUSE a deletion: a live
# loop run from another path is still this component, and a record it owns must not be removed.
fleet_pid_argv_names() { # <pid> <basename>
  local p="${1:-}" base="${2:-}" cmd
  [ -n "$p" ] && [ -n "$base" ] || return 1
  cmd="$(fleet_ps_snapshot 2>/dev/null)" || return 1
  printf '%s\n' "$cmd" | awk -v p="$p" -v b="$base" '
    $1 != p { next }
    { for (i=3;i<=NF;i++) { t=$i; sub(/^.*\//, "", t); if (t == b) { found=1; break } } }
    END { exit(found ? 0 : 1) }'
}

# fleet_count — distinct pids (sorted, de-duplicated), newline separated.
fleet_uniq_pids() { awk 'NF && !seen[$0]++'; }

# fleet_etime_s <pid> — the process's elapsed seconds, or empty when unreadable.
# macOS and GNU `ps` both accept `-o etime=`; the FORMAT differs ([[dd-]hh:]mm:ss vs the same), so
# the parse is shared and ambiguity resolves to empty (an unreadable age is never "young").
fleet_etime_s() {
  local p="${1:-}" e
  [ -n "$p" ] || return 0
  e="$("$FLEET_PS" -o etime= -p "$p" 2>/dev/null | tr -d ' ' | head -1)"
  [ -n "$e" ] || return 0
  printf '%s\n' "$e" | awk '
    { s=$0; days=0
      if (s ~ /-/) { split(s, d, "-"); days=d[1]; s=d[2] }
      n=split(s, t, ":")
      if (n == 3)   secs=t[3]+60*t[2]+3600*t[1]
      else if (n == 2) secs=t[2]+60*t[1]
      else if (n == 1 && t[1] ~ /^[0-9]+$/) secs=t[1]
      else { print ""; exit }
      print days*86400 + secs }'
}

# fleet_file_age <path> — seconds since mtime, or empty when the file does not exist / cannot be read.
fleet_file_age() {
  local f="${1:-}" mt
  [ -n "$f" ] && [ -e "$f" ] || return 0
  mt="$(date -r "$f" +%s 2>/dev/null || stat -c %Y "$f" 2>/dev/null)" || return 0
  case "$mt" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s\n' "$(( $(date +%s) - mt ))"
}

# fleet_human_age <seconds> — 41s / 7m / 2h10m / 3d4h, for the ACTUAL column.
fleet_human_age() {
  local s="${1:-}"
  case "$s" in ''|*[!0-9]*) printf 'age-unknown'; return 0 ;; esac
  if [ "$s" -lt 90 ]; then printf '%ss' "$s"
  elif [ "$s" -lt 5400 ]; then printf '%sm' "$(( s / 60 ))"
  elif [ "$s" -lt 172800 ]; then printf '%dh%02dm' "$(( s / 3600 ))" "$(( (s % 3600) / 60 ))"
  else printf '%dd%02dh' "$(( s / 86400 ))" "$(( (s % 86400) / 3600 ))"; fi
}

# ── launchd: ONE read, plus each job's own declaration ────────────────────────────────────────
# `launchctl list` is `PID<TAB>Status<TAB>Label`; PID is `-` between runs, Status is the LAST EXIT
# STATUS. That status is the datum nobody read while `pr-doctor` exited 2 for hours, so it is a
# first-class input here — not a curiosity in a detail string.
fleet_launchctl_available() {
  [ "${FLEET_NO_LAUNCHD:-0}" = 1 ] && return 1
  command -v "$FLEET_LAUNCHCTL" >/dev/null 2>&1 || return 1
  return 0
}

fleet_launchd_table() {
  if [ -n "${FLEET_LAUNCHD_CACHE:-}" ]; then printf '%s\n' "$FLEET_LAUNCHD_CACHE"; return 0; fi
  fleet_launchctl_available || return 1
  local t
  t="$("$FLEET_LAUNCHCTL" list 2>/dev/null)" || return 1
  case "$t" in *[![:space:]]*) ;; *) return 1 ;; esac
  FLEET_LAUNCHD_CACHE="$t"
  printf '%s\n' "$t"
}

# fleet_job_field <label> <pid|exit> — the label's live pid (only when numeric) or its last exit.
fleet_job_pid() {
  local t
  t="$(fleet_launchd_table)" || return 1
  printf '%s\n' "$t" | awk -v l="${1:?}" -F'\t' '$3 == l { print ($1 ~ /^[0-9]+$/ ? $1 : ""); exit }'
}
fleet_job_exit() {
  local t
  t="$(fleet_launchd_table)" || return 1
  printf '%s\n' "$t" | awk -v l="${1:?}" -F'\t' '$3 == l { print ($2 == "-" ? "" : $2); exit }'
}
fleet_job_loaded() {
  local t
  t="$(fleet_launchd_table)" || return 1
  printf '%s\n' "$t" | awk -v l="${1:?}" -F'\t' '$3 == l { found=1; exit } END { print (found ? "yes" : "no") }'
}

fleet_plist() { printf '%s\n' "$FLEET_LAUNCH_AGENTS_DIR/${1:?}.plist"; }

# fleet_plist_value <label> <key> — a value from the job's OWN definition, so a component is judged
# by the schedule it declares rather than by a constant invented here.
# ⛔ THREE OUTCOMES, and the caller must tell them apart (E-2 in review): prints the value and exits 0
# when it was read; prints nothing and exits 0 when the key is ABSENT from a readable plist; prints
# nothing and exits 2 when the definition could NOT be read. Folding 2 into 0 made an unreadable
# declaration indistinguishable from "this job declares no interval" — which sets no freshness bound
# and renders a plain green OK, the fail-open this file's own UNKNOWN doctrine forbids.
fleet_plist_value() {
  local f v
  f="$(fleet_plist "${1:?}")"
  [ -f "$f" ] || return 2
  v="$("$FLEET_PLUTIL" -extract "$2" raw -o - "$f" 2>/dev/null)" && { printf '%s\n' "$v"; return 0; }
  # plutil fails for BOTH a missing key and a file it cannot parse, so ask a SECOND reader: `plutil -p`
  # renders any parseable plist (binary included — a grep on the bytes would miss a binary plist and
  # silently restore the exact fail-open this branch exists to close). If -p succeeds and the key is
  # named, the file is readable and the key is there → the extract's failure is not "absent".
  local dump
  if ! dump="$("$FLEET_PLUTIL" -p "$f" 2>/dev/null)"; then return 2; fi   # the file is not a plist
  case "$dump" in *"\"$2\" =>"*) return 2 ;; esac                        # named but not extractable
  return 0
}

# ── rows ──────────────────────────────────────────────────────────────────────────────────────
# One row is: COMPONENT · EXPECTED · ACTUAL · STATE · DETAIL. TAB-delimited, because the renderer
# aligns columns and a detail may name paths with spaces.
fleet_row() { # <name> <expected> <actual> <state> <detail>
  local n="${1:-?}" e="${2:-}" a="${3:-}" s="${4:-UNKNOWN}" d="${5:-}"
  printf '%s\t%s\t%s\t%s\t%s\n' "$n" "${e//$'\t'/ }" "${a//$'\t'/ }" "$s" "${d//$'\t'/ }"
}

# ── component: the lane controller ────────────────────────────────────────────────────────────
# Its OWN behaviour: it holds `$O/.orch.lock`, rewrites `$O/heartbeat` every cycle, and its argv is
# `<shell> <state-dir>/orch-loop.sh` or `<shell> <harness>/orch-loop.sh` (MEASURED 2026-10-17 on a
# cell: the harness path, not `$O` — a read scoped to `$O` alone found no controller on a box that
# was busy spawning lanes).
fleet_row_controller() {
  local o="${FLEET_O:-${O:-$FLEET_HOME/orchestrator}}" harness="${1:-}"
  local own_pids foreign harness_pids lock
  # ⛔ TWO SCOPES, ONE VERDICT (#1856 review; #1761). The STATE-DIR scope may witness a verdict; the
  # SHARED-HARNESS scope may only be REPORTED. `harness` is one directory per cell home, so on a box
  # running two repos (explicitly supported: "an orchestrator for repo A and an orchestrator for repo
  # B") it returns repo A's controller to repo B. Counting it here would report DUPLICATE for a
  # healthy two-repo box, exit non-zero forever, and tell an operator to "stop all but one" — i.e. to
  # kill the other repo's live controller. Measured in review of this change.
  own_pids="$(fleet_pids_for "$o/orch-loop.sh")" || {
    fleet_row controller "1 controller for this state dir" "<ps unreadable>" UNKNOWN \
      "the process table could not be read, so no controller state can be reported — an unreadable read is never a pass"; return 0; }
  harness_pids=""
  if [ -n "$harness" ]; then
    harness_pids="$(fleet_pids_for "$harness/orch-loop.sh")" || {
      fleet_row controller "1 controller for this state dir" "<ps unreadable>" UNKNOWN \
        "the process table could not be read (harness scope) — an unreadable read is never a pass"; return 0; }
  fi
  # The lock's owner is an OWNER-ADDING read (it can name a controller whose path we did not guess),
  # and an unreadable ps there is again an abstention, not "nobody".
  lock="$(_fleet_lock_owner "$o")" || {
    fleet_row controller "1 controller for this state dir" "<ps unreadable>" UNKNOWN \
      "the process table could not be read while resolving the lock owner — an unreadable read is never a pass"; return 0; }
  own_pids="$(printf '%s\n%s\n' "$own_pids" "$lock" | fleet_uniq_pids)"
  # `foreign` = harness matches that are NOT one of ours. Reported, never counted.
  foreign="$(printf '%s\n' "$harness_pids" | FLEET_OWN="$(printf '%s' "$own_pids" | tr '\n' ' ')" awk '
    BEGIN { n=split(ENVIRON["FLEET_OWN"], a, " "); for (i=1;i<=n;i++) if (a[i] != "") own[a[i]]=1 }
    NF && !($0 in own)')"
  local n nf hb_age detail
  n="$(printf '%s' "$own_pids" | awk 'NF' | wc -l | tr -d ' ')"
  nf="$(printf '%s' "$foreign" | awk 'NF' | wc -l | tr -d ' ')"
  hb_age="$(fleet_file_age "$o/heartbeat")"
  detail=""
  [ "${nf:-0}" -eq 0 ] || detail="also seen from the shared harness path (NOT this state dir's, not counted): pid $(printf '%s' "$foreign" | tr '\n' ' ' | sed 's/ *$//')"
  if [ "${n:-0}" -eq 0 ]; then
    if [ "${nf:-0}" -gt 0 ]; then
      # Not MISSING: a controller IS running here, we simply cannot attribute it. Declaring the
      # population we could not consult is what keeps this from reading as a clean bill.
      fleet_row controller "1 controller for this state dir" "1+ from the shared harness, unattributable" UNKNOWN \
        "$detail — no live lock owner in $o/.orch.lock names a controller for this state dir, so this box cannot say whether that controller serves THIS repo; it may be another repo's (a two-repo box is supported). Reported, never counted."; return 0
    fi
    detail="no orch-loop.sh is running for $o${harness:+ (scope: $o, $harness)}"
    [ -f "$o/.orch.lock" ] && detail="$detail; a lock file EXISTS — two start paths can both pass it (a lock is not proof of singularity: #1761)"
    fleet_row controller "1 controller for this state dir" "none" MISSING "$detail"; return 0
  fi
  if [ "${n:-0}" -gt 1 ]; then
    fleet_row controller "1 controller for this state dir" "$n live for this state dir (pid $(printf '%s' "$own_pids" | tr '\n' ' ' | sed 's/ *$//'))" DUPLICATE \
      "MORE THAN ONE controller owns this state dir: pid $(printf '%s' "$own_pids" | tr '\n' ' ' | sed 's/ *$//') — every one of them drains the same queue, so work is dispatched twice; stop all but one by hand (no health check kills a process)${detail:+; $detail}"; return 0
  fi
  if [ -z "$hb_age" ]; then
    fleet_row controller "1 controller for this state dir" "pid $own_pids (no heartbeat file)" LATE \
      "a controller is running but $o/heartbeat is absent or undatable, so its cycle age cannot be read — the file it rewrites every cycle is the only proof it is dispatching, not only alive${detail:+; $detail}"; return 0
  fi
  if [ "$hb_age" -gt "$FLEET_CONTROLLER_LATE_S" ]; then
    fleet_row controller "1 controller for this state dir" "pid $own_pids, last cycle $(fleet_human_age "$hb_age") ago" LATE \
      "live but its heartbeat is $(fleet_human_age "$hb_age") old (bound ${FLEET_CONTROLLER_LATE_S}s) — the measured 'alive and dispatching nothing' state; check $o/logs/orch-loop.log${detail:+; $detail}"; return 0
  fi
  fleet_row controller "1 controller for this state dir" "pid $own_pids, last cycle $(fleet_human_age "$hb_age") ago${detail:+; $detail}" OK ""
}

# ── component: the watchdog that puts a REMOVED controller back ───────────────────────────────
# Two mechanisms exist on a Mac and they MUTATE the same job (`watchdog.sh` loads/reloads the
# controller's launchd job): the launchd job `com.eldato.orchestrator-watchdog` and the plain
# `$O/watchdog-loop.sh`. Both running is the "duplicate of a mutating action" case — each reload
# races the other. Exactly one is expected.
fleet_row_watchdog() {
  local o="${FLEET_O:-${O:-$FLEET_HOME/orchestrator}}" label="com.eldato.orchestrator-watchdog"
  local installed=0 mechanisms="" n=0 loop_pids loaded
  [ -f "$(fleet_plist "$label")" ] && installed=1
  [ -f "$o/watchdog-loop.sh" ] && installed=1
  if [ "$installed" -eq 0 ]; then
    if [ -f "$o/watchdog.sh" ]; then
      fleet_row controller-watchdog "1 watchdog (launchd job or watchdog-loop.sh)" "no watchdog job or loop" MISSING \
        "$o/watchdog.sh is on this box but neither the $label job nor $o/watchdog-loop.sh exists — nothing invokes it, so a controller launchd removes stays removed (the measured 2026-10-17 state)"; return 0
    fi
    fleet_row controller-watchdog "1 watchdog (launchd job or watchdog-loop.sh)" "not installed" SKIPPED \
      "neither $label nor $o/watchdog-loop.sh exists on this box — nothing to check (this is NOT a healthy watchdog)"; return 0
  fi
  if fleet_launchctl_available; then
    # E-9 (measured in review): the `|| loaded="unknown"` here made an unreadable launchctl fall
    # through to "0 mechanisms" -> MISSING, i.e. an unperformed read reported as a confirmed absence.
    if ! loaded="$(fleet_job_loaded "$label")"; then
      fleet_row controller-watchdog "1 watchdog" "<launchctl unreadable>" UNKNOWN \
        "the job definition exists but launchctl could not be read, so whether $label is loaded is not known"; return 0
    fi
    [ "$loaded" = "yes" ] && { mechanisms="launchd:$label"; n=$(( n + 1 )); }
  fi
  loop_pids="$(fleet_pids_for "$o/watchdog-loop.sh")" || {
    fleet_row controller-watchdog "1 watchdog" "<ps unreadable>" UNKNOWN "the process table could not be read"; return 0; }
  local ln=0
  ln="$(printf '%s' "$loop_pids" | awk 'NF' | wc -l | tr -d ' ')"
  if [ "${ln:-0}" -gt 0 ]; then
    mechanisms="${mechanisms:+$mechanisms + }watchdog-loop.sh(pid $(printf '%s' "$loop_pids" | tr '\n' ' ' | sed 's/ *$//'))"
    n=$(( n + ln ))
  fi
  if [ "$n" -eq 0 ]; then
    fleet_row controller-watchdog "1 watchdog" "none" MISSING \
      "installed but nothing is running it: a controller that launchd removes stays removed (measured four times on 2026-10-17) — start it with: bash scripts/orchestrator-bringup.sh start"; return 0
  fi
  # Read the job's last exit BEFORE the pair branch below: on the shipped configuration (both
  # mechanisms present) that branch returns, so a launchd watchdog exiting non-zero was unreadable —
  # and "a job exited 2 for hours and nothing noticed" is this file's headline case.
  local ex; ex="$(fleet_job_exit "$label" 2>/dev/null)"
  if [ "$n" -gt 1 ]; then
    # Same mechanism twice is a real duplicate: two launchd jobs cannot share a label, but two
    # watchdog-loop.sh processes can, and then the same action runs twice with no bound.
    local loop_n=0
    loop_n="$(printf '%s' "$loop_pids" | awk 'NF' | wc -l | tr -d ' ')"
    if [ "${loop_n:-0}" -gt 1 ]; then
      fleet_row controller-watchdog "1 watchdog" "$n instances ($mechanisms)" DUPLICATE \
        "$loop_n copies of $o/watchdog-loop.sh are running — the same mechanism twice, so every action runs twice"; return 0
    fi
    # ⛔ NOT DUPLICATE, and this is a deliberate departure from the plain reading. Both mechanisms run
    # the SAME idempotent watchdog.sh (check -> load -> log -> exit); they cannot disagree about the
    # desired state, so the overlap costs one redundant no-op pass, not divergent work. The pair is
    # intentional redundancy against launchctl being defeated (see watchdog-loop.sh's header; the
    # loop is the stopgap for #1976). Calling that a fault reddens this row on a HEALTHY box forever
    # and turns `status` into a permanently non-zero command — a false block, which must not be red.
    if [ -n "$ex" ] && [ "$ex" != "0" ]; then
      fleet_row controller-watchdog "1 watchdog" "1 launchd (exit $ex) + watchdog-loop.sh" FAILING \
        "the launchd watchdog's last run exited $ex — the plain loop is still covering the controller, which is why this is not fatal, but a failing watchdog is silent by construction (it logs only when it acts); its own log: ${FLEET_AGENT_STATE}/orchestrator-watchdog.log"
      return 0
    fi
    fleet_row controller-watchdog "1 watchdog" "1 launchd + watchdog-loop.sh (redundant by design)" OK \
      "both mechanisms invoke $o/watchdog.sh; the overlap is deliberate redundancy for #1976 (the plain loop survives a bootout), so it is not reported as a duplicate — only a second copy of the SAME mechanism is"
    return 0
  fi
  if [ -n "$ex" ] && [ "$ex" != "0" ]; then
    fleet_row controller-watchdog "1 watchdog" "1 ($mechanisms), last exit $ex" FAILING \
      "the watchdog's last run exited $ex — a watchdog that fails is silent by construction (it logs only when it acts)"; return 0
  fi
  fleet_row controller-watchdog "1 watchdog" "1 ($mechanisms)" OK ""
}

# ── component: a PIDFILE LOOP (heartbeat-loop.sh, cadence-timer.sh) ───────────────────────────
# Its OWN behaviour: it writes its pid to its own pidfile, removes it on exit, and appends to the
# heartbeat log it exists to produce. So the predicate is the pidfile CROSS-CHECKED against the
# process whose argv is that script — a pidfile alone is a number, and a recycled pid is alive.
_fleet_row_pidfile_loop() { # <name> <script> <pidfile> <freshness-file> <late-seconds> <what> [missing-note-fn]
  local name="${1:?}" script="${2:?}" pidfile="${3:?}" fresh="${4:?}" late="${5:?}" what="${6:?}" missing_note="${7:-}"
  local pids pf age n detail
  if [ ! -f "$script" ]; then
    fleet_row "$name" "1 $what" "not installed" SKIPPED \
      "$script does not exist on this box — nothing to check (NOT a healthy $what)"; return 0
  fi
  pids="$(fleet_pids_for "$script")" || {
    fleet_row "$name" "1 $what" "<ps unreadable>" UNKNOWN "the process table could not be read"; return 0; }
  n="$(printf '%s' "$pids" | awk 'NF' | wc -l | tr -d ' ')"
  pf=""
  [ -f "$pidfile" ] && pf="$(tr -dc '0-9' 2>/dev/null < "$pidfile")"
  if [ "${n:-0}" -eq 0 ]; then
    detail="$name is not running"
    if [ -n "$pf" ] && kill -0 "$pf" 2>/dev/null; then
      fleet_row "$name" "1 $what" "pidfile names $pf (alive, NOT a $name)" FAILING \
        "$pidfile names pid $pf, which is alive but is not running $script — a RECYCLED pid; the loop itself is gone and its pidfile is lying"; return 0
    fi
    [ -n "$pf" ] && detail="$detail (stale pidfile names pid $pf)"
    fleet_row "$name" "1 $what" "none" MISSING \
      "$detail — start it with: bash scripts/orchestrator-bringup.sh start"; return 0
  fi
  if [ "${n:-0}" -gt 1 ]; then
    fleet_row "$name" "1 $what" "$n live (pid $(printf '%s' "$pids" | tr '\n' ' ' | sed 's/ *$//'))" DUPLICATE \
      "more than one $name is running: pid $(printf '%s' "$pids" | tr '\n' ' ' | sed 's/ *$//') — its pidfile guard is defeated and the loop's work happens twice"; return 0
  fi
  if [ -n "$pf" ] && [ "$pf" != "$(printf '%s' "$pids" | awk 'NF{print; exit}')" ]; then
    fleet_row "$name" "1 $what" "pid $(printf '%s' "$pids" | awk 'NF{print; exit}'), pidfile says $pf" FAILING \
      "$pidfile does not name the running process — the loop is alive but its own liveness record is wrong, so every other reader of $pidfile is misled"; return 0
  fi
  age="$(fleet_file_age "$fresh")"
  if [ -z "$age" ]; then
    local why="$fresh does not exist — this component's only proof of doing its job is that file"
    if [ -n "$missing_note" ]; then
      why="$("$missing_note" "$fresh")"
    fi
    fleet_row "$name" "1 $what" "pid $(printf '%s' "$pids" | awk 'NF{print; exit}'), no freshness file" LATE \
      "running, but $why"; return 0
  fi
  if [ "$age" -gt "$late" ]; then
    fleet_row "$name" "1 $what" "pid $(printf '%s' "$pids" | awk 'NF{print; exit}'), last output $(fleet_human_age "$age") ago" LATE \
      "the process is alive but has produced nothing for $(fleet_human_age "$age") (bound ${late}s) — a live loop whose output stopped is the 'silently off' state"; return 0
  fi
  fleet_row "$name" "1 $what" "pid $(printf '%s' "$pids" | awk 'NF{print; exit}'), last output $(fleet_human_age "$age") ago" OK ""
}

fleet_row_heartbeat_loop() {
  _fleet_row_pidfile_loop heartbeat-loop "$FLEET_AGENT_SCRIPTS/heartbeat-loop.sh" \
    "$FLEET_AGENT_STATE/heartbeat-loop.pid" "$FLEET_AGENT_STATE/orchestrator-heartbeat.log" \
    "$FLEET_HEARTBEAT_LATE_S" heartbeat-loop
}

# Why the cadence timer's freshness file is missing — a stale INSTALLED copy, not a dead loop. The
# beacon was added with this row; a farmed copy from before it logs `CADENCE-TIMER started pid=…` and
# writes nothing else, so "no beacon" is a statement about the COPY, and the fix is a re-sync.
_fleet_cadence_beacon_note() { # <beacon-path>
  local log="$FLEET_AGENT_STATE/orchestrator-heartbeat.log"
  if grep -q 'CADENCE-TIMER started pid=' "$log" 2>/dev/null; then
    printf '%s predates the beacon: the copy of cadence-timer.sh on this box was installed before this row existed (its own start line is in %s), so its freshness cannot be proven — re-sync ~/.pi/agent/scripts from the repo and restart it with: bash scripts/orchestrator-bringup.sh restart' "$1" "$log"
    return 0
  fi
  printf '%s does not exist and the installed cadence-timer.sh wrote no start line either — this component proves nothing about its own cadence' "$1"
}

fleet_row_cadence_timer() {
  # ⛔ ITS OWN BEACON, not the heartbeat loop's log. This row used to read
  # `orchestrator-heartbeat.log`, which heartbeat-loop.sh appends to every pass — so the timer's LATE
  # branch could only fire if BOTH loops stopped, i.e. it could not report the one state it exists
  # for ("alive and pacing nothing"). cadence-timer.sh now writes `cadence-timer.beat` per tick.
  _fleet_row_pidfile_loop cadence-timer "$FLEET_AGENT_SCRIPTS/cadence-timer.sh" \
    "$FLEET_AGENT_STATE/cadence-timer.pid" "$FLEET_AGENT_STATE/cadence-timer.beat" \
    "$FLEET_CADENCE_LATE_S" cadence-timer _fleet_cadence_beacon_note
}

# ── component: a LAUNCHD PERIODIC JOB ─────────────────────────────────────────────────────────
# ⛔ "pid exists" is the WRONG predicate here, and using it is how a job that exited 2 for hours read
# as healthy. Between runs, pid is legitimately `-`. The predicate is the job's OWN declaration:
#   loaded?            (a job booted out of the domain runs never again)
#   last exit == 0?    (the readable datum nobody read)
#   own output fresh?  (its StandardOutPath, within 2× its OWN StartInterval + slack)
# A second instance (a hand-run copy alongside the scheduled one) is DUPLICATE — counted by DISTINCT
# pid, so the job's own in-flight run is not mistaken for a second one.
_fleet_row_launchd_job() { # <name> <label> <script-path-to-count-or-empty> <what> [own-log] [requires]
  # `own-log` (5th) is the log the COMPONENT ITSELF writes, for a job whose plist declares no
  # StandardOutPath/StandardErrorPath. It is not a guess: each path below is cited from the script
  # that opens it. Without it, four of this box's reapers read OK on "last exit 0" alone — a job
  # launchd stops scheduling (or whose runs die before they write) would read OK forever, which is
  # exactly the "silently off" state this file exists to end. Measured in review of this change:
  # pi-reap-worktrees.log was 16.0h old against that job's own 12.08h bound and rendered OK.
  local name="${1:?}" label="${2:?}" script="${3:-}" what="${4:?}" own_log="${5:-}" requires="${6:-}"
  local plist; plist="$(fleet_plist "$label")"
  [ -n "$requires" ] || requires="$script"
  if [ ! -f "$plist" ]; then
    if [ -n "$requires" ] && [ -f "$requires" ]; then
      # ⛔ NOT SKIPPED. The component's own code is on this box, so something is expected to run it;
      # a job that installs it was never created. Rendering that as SKIPPED (a pass) is exactly the
      # green-by-absence this row exists to end — and it is invisible to `start`.
      fleet_row "$name" "loaded, last exit 0, fresh output" "no job definition" MISSING \
        "this component's code IS on this box ($requires) but no job installs it (looked for $plist) — nothing runs it, and nothing will until the job is provisioned"; return 0
    fi
    fleet_row "$name" "loaded, last exit 0, fresh output" "not installed" SKIPPED \
      "neither a job definition ($plist) nor the component's code exists on this box — this component does not exist here (NOT a healthy $what)"; return 0
  fi
  if ! fleet_launchctl_available; then
    fleet_row "$name" "loaded, last exit 0, fresh output" "no launchctl" SKIPPED \
      "this platform has no launchctl, so a launchd job cannot be run or checked here"; return 0
  fi
  local loaded; loaded="$(fleet_job_loaded "$label")" || {
    fleet_row "$name" "loaded, last exit 0, fresh output" "<launchctl unreadable>" UNKNOWN \
      "launchctl could not be read, so the job's state cannot be determined"; return 0; }
  if [ "$loaded" != "yes" ]; then
    fleet_row "$name" "loaded, last exit 0, fresh output" "not loaded" MISSING \
      "the job definition exists but $label is NOT in the launchd domain — it will never run; load it with: launchctl bootstrap gui/$FLEET_UID $plist"; return 0
  fi
  local pid ex interval out age bound irc
  pid="$(fleet_job_pid "$label" 2>/dev/null)"
  ex="$(fleet_job_exit "$label" 2>/dev/null)"
  interval="$(fleet_plist_value "$label" StartInterval)"; irc=$?
  if [ "$irc" -eq 2 ]; then
    # E-2 MEASURED IN REVIEW: plutil failing was folded into "no interval declared", which sets no
    # freshness bound and renders a plain green OK. An unreadable DECLARATION is a read that could not
    # be performed — the abstention this file already uses for every other unreadable source.
    fleet_row "$name" "loaded, last exit 0, fresh output" "$label: job definition unreadable" UNKNOWN \
      "$plist exists but its StartInterval could not be read, so this job's own freshness bound cannot be derived and 'loaded + last exit 0' is the only evidence — which is the reading that made a job exiting 2 for hours look healthy"
    return 0
  fi
  out="$(fleet_plist_value "$label" StandardOutPath)"
  [ -n "$out" ] || out="$(fleet_plist_value "$label" StandardErrorPath)"
  [ -n "$out" ] || out="$own_log"
  age="$(fleet_file_age "$out")"
  # The job's OWN schedule decides "fresh": a 6h reaper is not late for being quiet for 40 minutes.
  bound=""
  case "$interval" in
    ''|*[!0-9]*|0?*) ;;                   # no StartInterval declared (or a leading zero): not derivable
    *) bound=$(( 10#$interval * 2 + 10#$FLEET_JOB_SLACK_S ));;
  esac
  # DUPLICATE: the scheduled instance plus a hand-run copy (or two hand-run copies).
  local inst="" man="" np=0
  [ -n "$pid" ] && inst="$pid"
  if [ -n "$script" ]; then
    man="$(fleet_pids_for "$script")" || man=""
  fi
  np="$(printf '%s\n%s\n' "$inst" "$man" | fleet_uniq_pids | awk 'NF' | wc -l | tr -d ' ')"
  local actual="loaded${pid:+, running pid $pid}"
  [ -n "$ex" ] && actual="$actual, last exit $ex"
  [ -n "$age" ] && actual="$actual, output $(fleet_human_age "$age") ago"
  if [ "${np:-0}" -gt 1 ]; then
    fleet_row "$name" "loaded, last exit 0, fresh output" "$np instances ($actual)" DUPLICATE \
      "more than one $label process is live (pid $(printf '%s\n%s\n' "$inst" "$man" | fleet_uniq_pids | awk 'NF' | tr '\n' ' ' | sed 's/ *$//')) — a hand-run copy beside the scheduled one does the same work twice"; return 0
  fi
  if [ -n "$ex" ] && [ "$ex" != "0" ]; then
    fleet_row "$name" "loaded, last exit 0, fresh output" "$actual" FAILING \
      "the job's last run exited $ex — it ran and FAILED, and nothing has been reading that status (the measured pr-doctor exit-2-for-hours state); its own log: ${out:-<none declared>}"; return 0
  fi
  if [ -n "$bound" ]; then
    if [ -z "$out" ]; then
      # ⛔ NOT OK. The job declares an interval and there is NO output file to date its last run, so
      # "loaded + last exit 0" is the only evidence — and a job launchd stops scheduling, or one whose
      # runs die before writing, is then indistinguishable from a healthy one. "Not checked" must not
      # carry a green exit code (the same reason SKIPPED is its own state). UNKNOWN is the abstention
      # this repo already uses for a read it could not perform.
      fleet_row "$name" "loaded, last exit 0, fresh output" "$actual (no output file to date its runs)" UNKNOWN \
        "no freshness signal is derivable for $label: its plist declares no StandardOutPath/StandardErrorPath and no own-log was declared for this row, so a job that stopped running cannot be distinguished from a healthy one; name the log it writes and pass it as this row's own-log"
      return 0
    fi
    if [ -z "$age" ]; then
      fleet_row "$name" "loaded, last exit 0, fresh output" "$actual (no output file)" LATE \
        "the job declares a ${interval}s interval and writes $out, but that file has never been written — a loaded job that never runs is indistinguishable from one that runs"
      return 0
    fi
    if [ "$age" -gt "$bound" ]; then
      fleet_row "$name" "loaded, last exit 0, fresh output" "$actual" LATE \
        "no output for $(fleet_human_age "$age") against its own ${interval}s interval (bound ${bound}s) — either it is not being scheduled or every run is dying before it writes"; return 0
    fi
  fi
  fleet_row "$name" "loaded, last exit 0, fresh output" "$actual" OK ""
}

fleet_row_pr_doctor() {
  _fleet_row_launchd_job pr-doctor com.tortoise.pr-doctor \
    "$FLEET_AGENT_SCRIPTS/pr-doctor.py" pr-doctor
}

# The reapers, one row each — a group row would hide which of them is dead, and their schedules
# differ by two orders of magnitude (1h … 24h), so a single freshness bound would be a lie.
# The OWN LOG each reaper writes, cited from the script that opens it — never inferred:
#   pi-reap-worktrees.sh:190            REAP_WT_LOG=$STATE_DIR/pi-reap-worktrees.log
#   cleanup-stale-branches.sh:2411      ~/.pi/agent/state/cleanup-stale-branches.log
#   pi-reap-idle.sh (session reaper)    ~/.pi/agent/state/pi-reap-idle.log
#   fleet/lane_liveness.py              ~/.pi/agent/state/lane-liveness.log
# A missing file is LATE, not OK: the component promises to write it.
fleet_row_reaper() { # <label> <own-log-name> <script-path>
  local label="${1:?}"
  _fleet_row_launchd_job "reaper.${label##*.}" "$label" "" "reaper" \
    "$FLEET_AGENT_STATE/${2:?}" "${3:-}"
}

# ── component: the cloud-cell supervisor ──────────────────────────────────────────────────────
# A cell has no launchd: `cloud-cell-supervisor.sh` owns the controller's tmux session. On a Mac
# this component does not exist, and saying so is the point — "absent" and "not applicable" must not
# render the same.
# _fleet_cell_identity — does THIS box carry a cell's identity?
# ⛔ NOT "is FLEET_CELL_HOME set". The entry point DEFAULTS `CELL_HOME=/tmp/cell-home`, and mapping a
# default into this seam made every Linux box a "cell" — which is how the identity test in the row
# became dead code (cycle-4 review). Evidence must be provisioned, not defaulted: the environment
# variable itself, a keyfile a provisioner mounted, the harness pin, or an explicit state marker.
_fleet_cell_identity() {
  [ -f "$FLEET_AGENT_STATE/.cell" ] && return 0
  [ -n "$FLEET_CELL_HOME" ] || return 1
  [ -f "$FLEET_CELL_HOME/keys.env" ] || [ -f "$FLEET_CELL_HOME/.harness-path" ] && return 0
  # A caller that SET the variable has said the box is a cell; the library cannot see whether it was
  # defaulted, so an existing directory is the weaker-but-explicit alternative and a missing one is not.
  [ -d "$FLEET_CELL_HOME" ] && [ -n "${FLEET_CELL_HOME_SET:-}" ] && return 0
  return 1
}

fleet_row_cell_supervisor() {
  local supervisor="${FLEET_CELL_SUPERVISOR:-}" platform="${FLEET_PLATFORM:-}"
  case "$platform" in
    cell) ;;
    '')
      # ⛔ UNKNOWN, not SKIPPED. An unset platform is a read that could not be performed, and SKIPPED
      # is severity 0 — on the one row that keeps a CELL's controller alive. The previous version also
      # asserted "the controller runs under launchd here" about a box whose platform it had just said
      # it did not know (measured by review: `this box is '': the controller runs under launchd here`).
      fleet_row cell-supervisor "1 cell supervisor (cell only)" "platform unknown" UNKNOWN \
        "FLEET_PLATFORM/PLATFORM is unset, so whether a cell supervisor applies here cannot be determined — an unanswered question is not a pass"; return 0 ;;
    mac)
      fleet_row cell-supervisor "1 cell supervisor (cell only)" "not applicable on mac" SKIPPED \
        "this is a Mac: the controller runs under launchd, so there is no cell supervisor to check (NOT a healthy supervisor)"; return 0 ;;
    *)
      fleet_row cell-supervisor "1 cell supervisor (cell only)" "not applicable on $platform" SKIPPED \
        "this box reports platform '$platform', which has no cell supervisor (NOT a healthy supervisor)"; return 0 ;;
  esac
  # ⛔ A CELL IS A BOX THAT CARRIES A CELL'S IDENTITY, decided HERE and first — not inside the
  # "supervisor script is missing" branch below. Two measured defects made that nesting wrong:
  #   (a) the entry point ALWAYS sets FLEET_CELL_SUPERVISOR to the checkout's cloud-cell-supervisor.sh
  #       and that file EXISTS, so the identity test was unreachable — every Linux dev box and CI
  #       runner (`uname -s = Linux` maps to PLATFORM=cell) was permanently MISSING, the very defect
  #       the guard claimed to fix;
  #   (b) `$STATE/.cell` had no writer anywhere in the repo, so a REAL cell whose supervisor was gone
  #       read SKIPPED — told it was "not a cell" — a pass on the component that keeps a cell's
  #       controller alive.
  if ! _fleet_cell_identity; then
    fleet_row cell-supervisor "1 cell supervisor (cell only)" "no cell identity on this box" SKIPPED \
      "the platform reads 'cell' from the kernel alone (Linux; no CELL_HOME and no $FLEET_AGENT_STATE/.cell marker), so this is a dev box or CI runner, not a cell — nothing to check here (NOT a healthy supervisor)"; return 0
  fi
  if [ -z "$supervisor" ] || [ ! -f "$supervisor" ]; then
    fleet_row cell-supervisor "1 cell supervisor" "not installed" MISSING \
      "this box carries a cell's identity (${FLEET_CELL_HOME:-$FLEET_AGENT_STATE/.cell}) but no cloud-cell-supervisor.sh was found${supervisor:+ at $supervisor} — nothing owns the controller's session"; return 0
  fi
  local pids n session="${FLEET_CELL_SESSION:-orch}" tm=""
  pids="$(fleet_pids_for "$supervisor")" || {
    fleet_row cell-supervisor "1 cell supervisor" "<ps unreadable>" UNKNOWN "the process table could not be read"; return 0; }
  n="$(printf '%s' "$pids" | awk 'NF' | wc -l | tr -d ' ')"
  if command -v "$FLEET_TMUX" >/dev/null 2>&1; then
    # ⛔ `-t orch` PREFIX-matches: reviewer C measured it satisfied by a session named
    # `orch-controller`. `=` forces an exact name, so "the session exists" means the session asked for.
    "$FLEET_TMUX" has-session -t "=$session" 2>/dev/null && tm="yes" || tm="no"
  else
    tm="unknown"
  fi
  if [ "${n:-0}" -eq 0 ]; then
    fleet_row cell-supervisor "1 cell supervisor" "none (tmux $session: $tm)" MISSING \
      "no cloud-cell-supervisor.sh is running on this cell${tm:+ (tmux session $session: $tm)} — the measured 'controllers absent on two of three cells and nothing noticed' state"; return 0
  fi
  if [ "${n:-0}" -gt 1 ]; then
    fleet_row cell-supervisor "1 cell supervisor" "$n live (tmux $session: $tm)" DUPLICATE \
      "more than one cell supervisor is running (pid $(printf '%s' "$pids" | tr '\n' ' ' | sed 's/ *$//')) — each applies the harness pin and starts a controller"; return 0
  fi
  if [ "$tm" = "no" ]; then
    fleet_row cell-supervisor "1 cell supervisor" "pid $(printf '%s' "$pids" | awk 'NF{print; exit}'), but tmux $session is GONE" LATE \
      "the supervisor process is alive but its tmux session $session does not exist — the measured 'cmux-tui OOM-killed, boxes report no controller' state"; return 0
  fi
  fleet_row cell-supervisor "1 cell supervisor" "pid $(printf '%s' "$pids" | awk 'NF{print; exit}'), tmux $session: $tm" OK ""
}

# ── component: the landers ────────────────────────────────────────────────────────────────────
# A lander is a per-PR waiter (`merge-one.sh` / `chain-merge.sh`) that waits for green and then
# lands. It is DEMAND-DRIVEN, so 0 live is normal — the failure is not absence, it is a waiter that
# outlives its own bound and quietly stops merging (the owner's "landers expired silently, so green
# PRs waited for a human"). Its own bound is the wait `chain-merge.sh` allows: 90 min, plus the
# merge; a waiter older than that is expired, not slow.
fleet_row_landers() {
  local harness="${1:-}" o="${FLEET_O:-${O:-$FLEET_HOME/orchestrator}}" pids n detail oldest=0 pid et
  pids="$(fleet_pids_for "$o/merge-one.sh" "${harness:+$harness/merge-one.sh}" "$o/chain-merge.sh" "${harness:+$harness/chain-merge.sh}")" || {
    fleet_row landers "every live lander younger than ${FLEET_LANDER_BOUND_S}s" "<ps unreadable>" UNKNOWN \
      "the process table could not be read"; return 0; }
  n="$(printf '%s' "$pids" | awk 'NF' | wc -l | tr -d ' ')"
  if [ "${n:-0}" -eq 0 ]; then
    fleet_row landers "every live lander younger than ${FLEET_LANDER_BOUND_S}s" "0 live (demand-driven)" OK ""
    return 0
  fi
  detail=""
  local expired=0
  for pid in $pids; do
    et="$(fleet_etime_s "$pid")"
    if [ -z "$et" ]; then
      detail="$detail pid $pid (age unreadable)"
      expired=$(( expired + 1 ))
      continue
    fi
    [ "$et" -gt "$oldest" ] && oldest="$et"
    if [ "$et" -gt "$FLEET_LANDER_BOUND_S" ]; then
      expired=$(( expired + 1 ))
      detail="$detail pid $pid alive $(fleet_human_age "$et") (bound ${FLEET_LANDER_BOUND_S}s);"
    fi
  done
  if [ "$expired" -gt 0 ]; then
    fleet_row landers "every live lander younger than ${FLEET_LANDER_BOUND_S}s" "$n live, oldest $(fleet_human_age "$oldest")" LATE \
      "an EXPIRED lander holds its claim and no longer lands anything:$detail a green PR behind it waits for a human — check the merge-* log for that PR"
    return 0
  fi
  fleet_row landers "every live lander younger than ${FLEET_LANDER_BOUND_S}s" "$n live, oldest $(fleet_human_age "$oldest")" OK ""
}

# ── component: the DRAIN LOOP ────────────────────────────────────────────────────────────────
# Reads the record `lander.sh` writes: `epoch queued in-progress merged enqueued waiting skipped errors`.
# ⛔ THE CI QUEUE DEPTH IS PART OF THE ROW, not buried in a log: it is the measured reason a mergeable
# PR is not landing (127 queued against 5 in progress, 2026-10-22) and nothing else in the fleet
# surfaces it. An UNREADABLE queue count is printed as `queue unreadable`, never as 0 — zero is an
# all-clear and an unread all-clear is the fail-open this fleet keeps paying for.
fleet_row_lander_drain() {
  local o="${FLEET_O:-${O:-$FLEET_HOME/orchestrator}}" f ep q ip merged enq wait skip errs age now exp
  f="$o/state/lander-last"
  exp="a lander.sh run recorded within ${FLEET_LANDER_DRAIN_LATE_S}s (so ready PRs are actually landing)"
  if [ ! -e "$f" ]; then
    # NOT OK, and NOT LATE either: nothing has ever run, so no freshness can be computed. SKIPPED is a
    # pass, and a Mac whose drain loop lives on a cell is not broken — but the advice names the whole
    # point, because "silently off" is exactly the state that parked green PRs.
    fleet_row lander-drain "$exp" "no run recorded" SKIPPED \
      "nothing has ever written $f on this box: either the drain loop is not installed here (fine on a Mac — see the landers row) or it was deleted with the cell that carried it (GREEN PRs THEN WAIT FOR A HUMAN — the reason lander.sh was versioned into the harness)"
    return 0
  fi
  # shellcheck disable=SC2034  # `age`/`errs` are read for bounds and advice below
  read -r ep q ip merged enq wait skip errs < "$f" 2>/dev/null || { ep=""; }
  case "${ep:-}" in
    ''|*[!0-9]*) fleet_row lander-drain "$exp" "record unreadable" UNKNOWN \
      "$f exists but its first field is not an epoch ('${ep:-<empty>}') — an unreadable record is never a pass, and never a guess" ; return 0 ;;
  esac
  now="$(date +%s 2>/dev/null || echo 0)"
  age=$(( now - ep ))
  [ "$age" -lt 0 ] && age=0
  # Queue depth is rendered from the record; a non-numeric field says so instead of printing 0.
  local qs
  case "${q:-}" in ''|*[!0-9]*) qs="queue unreadable" ;; *) case "${ip:-}" in ''|*[!0-9]*) qs="queue ${q} queued/unknown" ;; *) qs="CI queue ${q} queued/${ip} in progress" ;; esac ;; esac
  local counts="merged=${merged:-?} waiting=${wait:-?} skipped=${skip:-?}"
  if [ "$age" -gt "$FLEET_LANDER_DRAIN_LATE_S" ]; then
    fleet_row lander-drain "$exp" "last run $(fleet_human_age "$age") ago" LATE \
      "the drain loop has not run for $(fleet_human_age "$age") (bound ${FLEET_LANDER_DRAIN_LATE_S}s): at that run $counts, $qs. A loop that is off opens no PR, reds no check and logs nothing — ready PRs are now waiting on a human"
    return 0
  fi
  fleet_row lander-drain "$exp" "last run $(fleet_human_age "$age") ago: $counts, $qs" OK ""
}

# ── the inventory, and the one table ──────────────────────────────────────────────────────────
# `fleet_rows <harness-path>` — every row, in a fixed order: the controller first (it is what every
# other component exists to serve), then the things that keep it alive, then the maintenance jobs.
fleet_rows() {
  local harness="${1:-}"
  # ONE `ps` read and ONE `launchctl list` for the whole table: both are EXPORTED, so every row —
  # each of which reads them inside a command substitution (a subshell) — sees the same snapshot.
  # Without this, one `status` on a loaded box spawns ~20 `ps` processes and takes 5.4s (measured),
  # and a health screen nobody waits for is a health screen nobody reads. One snapshot also means
  # two rows cannot report two different worlds.
  FLEET_PS_CACHE=""; FLEET_LAUNCHD_CACHE=""   # a NEW snapshot per table, never a stale one reused
  fleet_ps_snapshot >/dev/null 2>&1 || true
  export FLEET_PS_CACHE
  fleet_launchd_table >/dev/null 2>&1 || true
  export FLEET_LAUNCHD_CACHE
  fleet_row_controller "$harness"
  fleet_row_watchdog
  fleet_row_heartbeat_loop
  fleet_row_cadence_timer
  fleet_row_pr_doctor
  # The 3rd arg is the code the job runs, CITED FROM THE INSTALLED PLIST (not guessed): both the
  # worktree and the branch reaper are driven by the same wrapper, with a different --script.
  fleet_row_reaper com.tortoise.worktree-reaper pi-reap-worktrees.log "$FLEET_AGENT_SCRIPTS/pi-reap-worktrees-launchd.py"
  fleet_row_reaper com.tortoise.branch-reaper cleanup-stale-branches.log "$FLEET_AGENT_SCRIPTS/pi-reap-worktrees-launchd.py"
  fleet_row_reaper com.eldato.pi-session-reaper pi-reap-idle.log "$FLEET_AGENT_SCRIPTS/pi-reap-idle.sh"
  fleet_row_reaper com.eldato.lane-liveness lane-liveness.log "$FLEET_AGENT_SCRIPTS/fleet/lane_liveness.py"
  fleet_row_cell_supervisor
  fleet_row_landers "$harness"
  fleet_row_lander_drain
}

# fleet_state_severity <state> — 0 pass (OK, SKIPPED) · 1 not OK · 2 cannot determine.
# SKIPPED is a PASS deliberately: a Mac is not broken for having no cell supervisor, and a nil
# exit would teach operators to ignore the one screen they are meant to read. It is never rendered
# as OK, so "not checked" and "checked and healthy" stay distinguishable.
fleet_state_severity() {
  case "${1:-UNKNOWN}" in
    OK|SKIPPED) printf '0\n' ;;
    UNKNOWN)    printf '2\n' ;;
    *)          printf '1\n' ;;
  esac
}

# fleet_render_table — stdin: rows. stdout: the table, then the notes for every row that is not OK.
# Returns the worst row's severity as its exit code (0/1/2).
fleet_render_table() {
  local rows; rows="$(cat)"
  # ⛔ ZERO ROWS IS NOT "EVERYTHING IS FINE". `printf '\n' | fleet_render_table` printed a header and
  # a phantom empty row and returned 0 — so a declaration that failed to load, or a read that produced
  # nothing, read identically to a healthy fleet ("a missing check is not a green check"). A table
  # with no `controller` row is not this inventory: refuse to certify it.
  local nc
  nc="$(printf '%s\n' "$rows" | awk -F'\t' 'NF && $1 == "controller" {c++} END {print c+0}')"
  case "$nc" in
    ''|0)
      printf '%s\n' "cannot determine: the inventory produced no controller row — a table with nothing in it is not a healthy fleet" >&2
      return 2 ;;
  esac
  printf '%s\n' "$rows" | awk -F'\t' '
    { n=NR
      name[n]=$1; expect[n]=$2; act[n]=$3; st[n]=$4; det[n]=$5
      if (length($1) > w1) w1=length($1)
      if (length($2) > w2) w2=length($2)
      if (length($3) > w3) w3=length($3)
      if (length($4) > w4) w4=length($4) }
    END {
      hdr1="COMPONENT"; hdr2="EXPECTED"; hdr3="ACTUAL"; hdr4="STATE"
      if (length(hdr1) > w1) w1=length(hdr1)
      if (length(hdr2) > w2) w2=length(hdr2)
      if (length(hdr3) > w3) w3=length(hdr3)
      if (length(hdr4) > w4) w4=length(hdr4)
      printf "%-*s  %-*s  %-*s  %-*s\n", w1, hdr1, w2, hdr2, w3, hdr3, w4, hdr4
      printf "%-*s  %-*s  %-*s  %-*s\n", w1, "---------", w2, "--------", w3, "------", w4, "-----"
      for (i=1;i<=n;i++) printf "%-*s  %-*s  %-*s  %-*s\n", w1, name[i], w2, expect[i], w3, act[i], w4, st[i]
      notes=0
      for (i=1;i<=n;i++) if (st[i] != "OK") {
        if (!notes) { printf "\nnotes:\n"; notes=1 }
        printf "  %-14s %s: %s\n", name[i], st[i], det[i]
      }
    }'
  # The exit code is the WORST row, so a green table and a zero exit are the same statement.
  local worst=0 sev
  while IFS=$'\t' read -r _n _e _a state _d; do
    [ -n "${state:-}" ] || continue
    sev="$(fleet_state_severity "$state")"
    [ "$sev" -gt "$worst" ] && worst="$sev"
  done <<<"$rows"
  return "$worst"
}

# ── start / stop, one verb each, driven by the same inventory ─────────────────────────────────
# Start is defined as "make every MISSING (or unrecoverably FAILING) component present", never as
# "run these commands": a component that is already OK is left alone, and a DUPLICATE is REPORTED,
# never resolved by killing (a kill driven by a process read is how a healthy peer's work dies).
# `stop` removes a component with the LEAST destructive mechanism that actually removes it, and it
# READS THE DOMAIN BACK afterwards — the answer is the read after, never the command's status (the
# measured `launchctl unload -w` that exits 0 while printing "Unload failed").

# The launchd label behind each multi-instance component, or empty. One table, so the start, stop and
# per-row readers cannot disagree about which job a row means.
_fleet_label_for() { # <name>
  case "${1:-}" in
    controller-watchdog)       printf 'com.eldato.orchestrator-watchdog\n' ;;
    pr-doctor)                 printf 'com.tortoise.pr-doctor\n' ;;
    reaper.worktree-reaper)    printf 'com.tortoise.worktree-reaper\n' ;;
    reaper.branch-reaper)      printf 'com.tortoise.branch-reaper\n' ;;
    reaper.pi-session-reaper)  printf 'com.eldato.pi-session-reaper\n' ;;
    reaper.lane-liveness)      printf 'com.eldato.lane-liveness\n' ;;
  esac
}

# fleet_component_has_start <name> — can THIS box start this component at all?
# The distinction matters for the verb contract: a component that is missing because it is not
# installed here (no plist, no script) is not a START FAILURE — it is a component this box cannot
# start, and saying so is different from claiming the fleet came up. A component whose mechanism
# EXISTS and does not work IS a failure, and `start` must exit non-zero for it.
fleet_component_has_start() { # <name>
  case "${1:-}" in
    heartbeat-loop) [ -f "$FLEET_AGENT_SCRIPTS/heartbeat-loop.sh" ]; return ;;
    cadence-timer)  [ -f "$FLEET_AGENT_SCRIPTS/cadence-timer.sh" ];  return ;;
  esac
  local label; label="$(_fleet_label_for "$1")"
  [ -n "$label" ] || return 1
  [ -f "$(fleet_plist "$label")" ] || return 1
  fleet_launchctl_available
}

# fleet_component_has_stop <name> — is there a stop mechanism for this component ON THIS BOX?
# ⛔ A component with no stop mechanism must be SKIPPED BY NAME, not attempted: a healthy `stop` that
# prints "could not stop landers — it may still be running" on every run is a screen nobody reads
# (measured in review of this change: live landers made `stop` warn and return 1).
fleet_component_has_stop() { # <name>
  case "${1:-}" in
    heartbeat-loop|cadence-timer)
      fleet_component_has_start "$1"; return ;;
    controller-watchdog)
      # ⛔ EITHER mechanism. `fleet_component_has_start` needs the launchd job, but on a box that runs
      # only the plain loop (no plist) the loop IS stoppable — asking has_start there answered "no
      # stop mechanism" and `stop` left a watchdog running that it could have signalled.
      [ -f "$(fleet_plist com.eldato.orchestrator-watchdog)" ] || [ -f "$FLEET_O/watchdog-loop.sh" ]; return ;;
  esac
  fleet_component_has_start "$1"
}

# fleet_start_component <name> — the start mechanism for the row of that name.
fleet_start_component() { # <name>
  local name="${1:?}" label plist
  case "$name" in
    controller) return 0 ;;   # the platform verb owns it, with its redundancy guard
    heartbeat-loop|cadence-timer)
      local script i pids pf_now p hit nopf alive settle_polls
      # ⛔ THE BOUND IS VALIDATED, not trusted (#9v's lesson: an env value of `1.5` makes bash
      # arithmetic a SYNTAX ERROR, which turns a fence into an abort). A bad value falls back to the
      # shipped window instead of skipping the wait.
      # ⛔ AND "ALL DIGITS" IS NOT A VALID ARITHMETIC TOKEN: `08`, `09` and `010` are OCTAL, and
      # `$(( 08 * 5 ))` is a FATAL "value too great for base" that kills the whole bringup shell
      # (measured: with FLEET_START_SETTLE_S=08 the verb never printed its table and exited 1 —
      # exactly the abort this fence exists to prevent). `10#` pins the base, so every digit string
      # means what the operator wrote. The result is CAPPED: a typo (or an intmax value that wraps)
      # must not turn `start` into an unbounded wait.
      # ⛔ THE CAP IS IN POLLS, NOT SECONDS. A poll is `sleep 0.2` PLUS one `fleet_pids_for` (a `ps`
      # read under load), so 300 polls is on the order of minutes, not the "60 s" an earlier comment
      # claimed — and the cap is only reachable when the operator asks for a window beyond it AND the
      # record stays wrong. Stated so the number is not read as a wall-clock bound.
      case "$FLEET_START_SETTLE_S" in
        ''|*[!0-9]*) settle_polls=15 ;;
        *) settle_polls=$(( 10#$FLEET_START_SETTLE_S * 5 ))
           if [ "$settle_polls" -lt 0 ]; then settle_polls=15
           elif [ "$settle_polls" -gt 300 ]; then settle_polls=300    # ~300 polls (see below)
           fi ;;
      esac
      if [ "$name" = "heartbeat-loop" ]; then
        script="$FLEET_AGENT_SCRIPTS/heartbeat-loop.sh"
      else
        script="$FLEET_AGENT_SCRIPTS/cadence-timer.sh"
      fi
      [ -f "$script" ] || return 1
      # ⛔ READ BEFORE LAUNCHING. A pidfile loop reads FAILING while its process IS alive (the pidfile
      # names a different pid — the record is wrong, the loop is not), and this branch used to launch
      # anyway: MEASURED by review as 1 live copy before the verb, 2 after, plus "started" reported
      # from the copy it had just made. `start` manufacturing the duplicate it exists to detect is the
      # #1761 class. The live process wins: the defect is the RECORD, so say so and change nothing —
      # a health check does not kill, and it must not multiply either.
      # (an unreadable table here must ABSTAIN, not launch: `|| return 1`, never `2>/dev/null`)
      local live_now
      live_now="$(fleet_pids_for "$script")" || return 1
      if [ -n "$(printf '%s' "$live_now" | tr -d '[:space:]')" ]; then
        FLEET_START_ACTION="already running — the FAILING state is its stale pidfile, not an absent process; left alone (its row names the pidfile defect)"
        say "$name: $FLEET_START_ACTION"
        return 0
      fi
      # ⛔ THE STALE RECORD IS THIS VERB'S TO CLEAR, and it has already been PROVEN stale by the same
      # argv-shape predicate the row used (a live pid that is not this script). Without this, the
      # launcher's own pidfile guard ("already running (pid $old)") exits immediately, the read-back
      # fails, and `start` reports a failure that points at the LAUNCHER instead of the pidfile the
      # row names — a diagnosed row left permanently un-repairable.
      local pf="$FLEET_AGENT_STATE/${name}.pid" pf_pid pf_base
      pf_base="${script##*/}"
      if [ -f "$pf" ]; then
        pf_pid="$(tr -dc '0-9' 2>/dev/null < "$pf")"
        if [ -n "$pf_pid" ] && kill -0 "$pf_pid" 2>/dev/null; then
          if fleet_pid_argv_names "$pf_pid" "$pf_base"; then
            # ⛔ THE PIDFILE IS *RIGHT*: a live copy of THIS component exists, just not at the path the
            # row's exact-argv predicate counts. Deleting its record (the first version of this repair)
            # started a second copy and then reported OK over two loops — a false pass, and the
            # duplicate that `DUPLICATE` exists to catch (cycle-4 review, measured).
            FLEET_START_ACTION="not started — $pf names pid $pf_pid, which is running $pf_base from another path, so that copy owns the record; two copies would both run"
            say "$name: $FLEET_START_ACTION"
            return 0
          fi
          rm -f "$pf" && say "$name: removed $pf — it named pid $pf_pid, which is alive but is not $name (a recycled pid)"
        fi
      fi
      # ⛔ DETACHED, then READ BACK — never in the foreground. The launcher's own self-detach is a
      # property of ONE COPY of it (pi-bootstrap ships these as copies, which lag the repo), so
      # depending on it makes `start` block for as long as that script runs. The row's predicate is
      # the verification: a launcher that did not come up is a start FAILURE, not a claim.
      FLEET_START_ACTION="started"
      nohup /bin/bash "$script" >/dev/null 2>&1 &
      FLEET_PS_CACHE=""       # the process table just changed: a cached read would miss it
      i=0
      while [ "$i" -lt 25 ]; do
        pids="$(fleet_pids_for "$script")" || return 1
        [ -n "$(printf '%s' "$pids" | tr -d '[:space:]')" ] && break
        sleep 0.2; i=$(( i + 1 ))
      done
      [ "$i" -lt 25 ] || return 1
      # ⛔ SETTLE, THEN JUDGE (#2221). A process being up is NOT the same as the read being about the
      # process that runs this component: `heartbeat-loop.sh` re-execs itself DETACHED, so the pid the
      # read-back above returns on is the LAUNCHER, and `fleet_pids_for` cannot even see the daemon
      # while it is the launcher's child (a descendant of a match is not a second instance — out of
      # `_fleet_ps_awk`, correctly). MEASURED on the owner's Mac: `start` printed
      # `pid 67710, pidfile says 67715 FAILING` and `status` said OK a second later, with ONE loop
      # alive the whole time — the row's verdict was about the handover, not about the loop.
      #
      # So this verb does not print a verdict about a process it has just created and not yet seen
      # settle. It re-reads until the component's OWN record names a pid the row will also count
      # (the row's OK predicate, i.e. exactly what the table `start` prints is about to read), or
      # until the wait is spent — and then it still returns 0, because a process IS alive: if the
      # record is genuinely wrong after that, that is the row's FAILING to report, not a start to
      # negate (a start that negates it would also hide the record defect the row names).
      # ⛔ A CACHED TABLE HERE WOULD NEVER SETTLE: `fleet_ps_snapshot` answers `FLEET_PS_CACHE` when it
      # is set, so every poll must clear it or the loop re-reads the launcher forever.
      i=0; nopf=0; alive=1     # alive=1: a process WAS seen (the read-back above broke out on it)
      while [ "$i" -lt "$settle_polls" ]; do
        sleep 0.2; i=$(( i + 1 ))
        FLEET_PS_CACHE=""
        pids="$(fleet_pids_for "$script")" || return 1
        if [ -z "$(printf '%s' "$pids" | tr -d '[:space:]')" ]; then
          alive=0; nopf=0; continue      # it came up and then went: keep watching, end on the last read
        fi
        alive=1
        pf_now=""
        [ -f "$pf" ] && pf_now="$(tr -dc '0-9' 2>/dev/null < "$pf")"
        if [ -n "$pf_now" ]; then
          hit=0
          for p in $pids; do [ "$p" = "$pf_now" ] && { hit=1; break; }; done
          [ "$hit" -eq 1 ] && return 0  # settled: the record names the live loop, so the row reads OK
          nopf=0
        else
          # NO RECORD AT ALL, for a whole second of polls: nothing here can hand over or go stale, and
          # this row cannot read FAILING on an ABSENT pidfile (it reports LATE/MISSING instead), so
          # there is nothing about this component for the window to fix.
          nopf=$(( nopf + 1 ))
          [ "$nopf" -ge 5 ] && return 0
        fi
      done
      # ⛔ RETURN, do not fall through: a `case` branch that only EVALUATES its last test runs on into
      # the launchd path below, which has no plist for these two components and answers a bare 1.
      [ "$alive" -eq 1 ] && return 0
      return 1 ;;
  esac
  label="$(_fleet_label_for "$name")"
  [ -n "$label" ] || return 1
  plist="$(fleet_plist "$label")"
  [ -f "$plist" ] || return 1
  fleet_launchctl_available || return 1
  # RESTORE the plain loop too when the box has one: `stop` signals it (both mechanisms ARE this
  # component), so without this `restart` silently downgrades a two-mechanism box to one. Recreating
  # the box's own configuration is not a policy decision — inventing one would be.
  if [ "$name" = "controller-watchdog" ] && [ -f "$FLEET_O/watchdog-loop.sh" ]; then
    if [ -z "$(fleet_pids_for "$FLEET_O/watchdog-loop.sh" 2>/dev/null | tr -d '[:space:]')" ]; then
      nohup /bin/bash "$FLEET_O/watchdog-loop.sh" >/dev/null 2>&1 &
    fi
  fi
  # ⛔ NEVER `launchctl enable`/`-w`: that writes a persistent override flag, and `watchdog.sh`'s own
  # header records what a persistently-disabled job costs (it is REMOVED, so KeepAlive cannot help).
  FLEET_LAUNCHD_CACHE=""      # the domain is about to change: read it fresh before deciding
  if [ "$(fleet_job_loaded "$label" 2>/dev/null)" = "yes" ]; then
    # Loaded but LATE or FAILING: KICK IT so the verdict is about a RUN, not about the last stale one.
    # Without this, `start` could never repair a FAILING periodic job — including the measured
    # `pr-doctor, last exit 2` this component exists for.
    "$FLEET_LAUNCHCTL" kickstart "gui/$FLEET_UID/$label" 2>/dev/null || return 1
  else
    "$FLEET_LAUNCHCTL" bootstrap "gui/$FLEET_UID" "$plist" 2>/dev/null || return 1
    # E-8 (measured in review): bootstrapping a job that does not RunAtLoad leaves it "loaded, last
    # exit 0" — a green OK for a job that has never run under this start. Kick it so `start` produces
    # evidence rather than an absence.
    "$FLEET_LAUNCHCTL" kickstart "gui/$FLEET_UID/$label" 2>/dev/null || :   # a job mid-run refuses; not a failure
  fi
  FLEET_LAUNCHD_CACHE=""
  # READ THE DOMAIN BACK: a bootstrap that reported success over a job that is not there is the
  # false-PASS shape this file exists to end.
  [ "$(fleet_job_loaded "$label" 2>/dev/null)" = "yes" ] || return 1
  return 0
}

fleet_stop_component() { # <name>
  local name="${1:?}" label plist pids p rc=0 wp
  case "$name" in
    controller) return 0 ;;   # the CALLER stops it with the platform verb
    heartbeat-loop|cadence-timer)
      local script
      if [ "$name" = "heartbeat-loop" ]; then
        script="$FLEET_AGENT_SCRIPTS/heartbeat-loop.sh"
      else
        script="$FLEET_AGENT_SCRIPTS/cadence-timer.sh"
      fi
      pids="$(fleet_pids_for "$script")" || return 1   # fail closed on an unreadable read
      local i
      for p in $pids; do kill -TERM "$p" 2>/dev/null && :; done
      # Bounded wait for the TERM to land, then READ: `kill -TERM` returning 0 proves only that the
      # signal was queued. A `restart` that proceeds while the old loop is still alive races the new
      # one (cadence-timer's own pidfile guard would make the new timer a no-op).
      i=0
      while [ "$i" -lt 25 ]; do
        FLEET_PS_CACHE=""
        pids="$(fleet_pids_for "$script")" || return 1
        [ -n "$(printf '%s' "$pids" | tr -d '[:space:]')" ] || break
        sleep 0.2; i=$(( i + 1 ))
      done
      [ -z "$(printf '%s' "$pids" | tr -d '[:space:]')" ] || rc=1
      return "$rc" ;;
    controller-watchdog)
      # BOTH mechanisms, because both ARE this component: the plain loop is signalled here and the
      # launchd job is booted out below. Stopping only one leaves the duplicate this row reports
      # still reloading the controller's job — the confusing half-stop.
      pids="$(fleet_pids_for "$FLEET_O/watchdog-loop.sh")" || return 1   # fail closed
      for p in $pids; do kill -TERM "$p" 2>/dev/null && :; done
      local i2; i2=0
      while [ "$i2" -lt 25 ]; do
        wp="$(fleet_pids_for "$FLEET_O/watchdog-loop.sh")" || return 1
        [ -z "$(printf '%s' "$wp" | tr -d '[:space:]')" ] && break
        sleep 0.2; i2=$(( i2 + 1 ))
      done
      [ -z "$(printf '%s' "$wp" | tr -d '[:space:]')" ] || rc=1 ;;
  esac
  label="$(_fleet_label_for "$name")"
  [ -n "$label" ] || return 1
  fleet_launchctl_available || return 1
  # `bootout` (NOT `unload -w`): it removes the job from the domain and writes NO persistent disable,
  # so `start` can put it back. Reversible by construction.
  "$FLEET_LAUNCHCTL" bootout "gui/$FLEET_UID/$label" 2>/dev/null || true
  FLEET_LAUNCHD_CACHE=""
  # ⛔ THE READ AFTER, never the command's status: a bootout can fail (wrong domain, permissions) and
  # still be treated as success by `|| true`. A job still in the domain is NOT stopped.
  [ "$(fleet_job_loaded "$label" 2>/dev/null)" != "yes" ] || rc=1
  return "$rc"
}

# fleet_ensure_components <harness-path> — bring up what can be brought up, then RE-READ and report.
# The re-read is the point: a start that reports success and a component that is still absent is
# exactly the silent failure this file exists to end.
fleet_ensure_components() { # <harness-path>
  local harness="${1:-}" out worst=0 name state unknown_rows tostart
  out="$(fleet_rows "$harness")"
  # ⛔ AN UNREADABLE READ IS NOT "NOTHING TO DO". With an unreadable `ps` every row is UNKNOWN, the
  # tostart filter matches nothing, and the early return below used to print "every component is
  # already OK" and exit 0 — `start` reporting a green fleet from a read it could not perform.
  unknown_rows="$(printf '%s\n' "$out" | awk -F'\t' '$4 == "UNKNOWN" {print $1}' | tr '\n' ' ' | sed 's/ *$//')"
  if [ -n "$unknown_rows" ]; then
    printf 'cannot determine: %s component(s) could not be checked (%s) — an unreadable read is never a pass\n' \
      "$(printf '%s' "$unknown_rows" | wc -w | tr -d ' ')" "$unknown_rows" >&2
    printf '%s\n' "$out" | fleet_render_table
    return 2
  fi
  # MISSING → start; FAILING → kick (a periodic job that ran and failed is repairable by a re-run);
  # LATE/DUPLICATE → reported, never auto-resolved (both are about a LIVE process: one is alive but
  # stale, the other is duplicated, and a health check that kills either is a lane-killer).
  tostart="$(printf '%s\n' "$out" | awk -F'\t' '$4=="MISSING" || $4=="FAILING" || $4=="LATE" || $4=="DUPLICATE" {print $1"\t"$4}')"
  [ -n "$tostart" ] || { say "every component is already OK (or not applicable)"; return 0; }
  while IFS=$'\t' read -r name state; do
    [ -n "$name" ] || continue
    case "$name" in
      controller)
        # ⛔ REPORTED, NOT FATAL, and the reason is specific rather than convenient: `cmd_start` has
        # ALREADY proved a live owner (it exits `cannot-determine` when it cannot) — through the
        # launchd agent's pid or the cell supervisor's own status verb. A MISSING row here therefore
        # means this read could not ATTRIBUTE the owner, not that nothing is running. Asserting a
        # start failure from it would be reading a scope gap as a verdict, and two answers to one
        # question is the defect this entry point exists to remove (#1745/#1856).
        say "controller: $state in this read's scope — start already proved a live owner through the platform verb. Reported, not fatal."
        continue ;;
    esac
    if [ "$state" = "DUPLICATE" ]; then
      say "$name: DUPLICATE — not touched; two live instances must be reconciled by hand"
      worst=1; continue
    fi
    if [ "$state" = "LATE" ]; then
      say "$name: LATE — left running; cycle it with: bash scripts/orchestrator-bringup.sh restart"
      worst=1; continue
    fi
    if ! fleet_component_has_start "$name"; then
      # ⛔ NAMED, not silent, and not a START FAILURE: this box has no mechanism for it, so nothing
      # was attempted. `status` still reports it as not-OK — the health verb and the start verb
      # answer different questions, and this is the one place they must differ.
      case "$name" in
        cell-supervisor) say "$name: $state — not startable from here; a cell is provisioned by cloud-cell-bringup.sh" ;;
        *)               say "$name: $state — not installed on this box (no start mechanism), so nothing was started" ;;
      esac
      continue
    fi
    FLEET_START_ACTION=""
    if fleet_start_component "$name"; then
      say "$name: ${FLEET_START_ACTION:-started} (was $state)"
    else
      say "FAILED to start $name (was $state) — its start mechanism exists on this box and did not work"
      worst=1
    fi
  done <<<"$tostart"
  # Re-read after starting: the honest answer is what is alive NOW.
  out="$(fleet_rows "$harness")"
  printf '%s\n' "$out" | fleet_render_table
  local table_rc=$?
  # ⛔ THE EXIT CODE IS ABOUT WHAT THIS VERB DID, NOT ABOUT THE WHOLE BOX. `start` fails when
  # something it ATTEMPTED did not come up (worst=1) or when a live process must be reconciled by
  # hand (DUPLICATE/LATE). A component this box cannot start at all was never attempted and is
  # reported as such; making it fail would turn every Mac into a broken `start` for the cell
  # supervisor's absence. `status` remains the verb whose exit code is the FLEET's verdict.
  if [ "$worst" -ne 0 ]; then return 1; fi
  if [ "$table_rc" -ne 0 ]; then
    say ""
    say "NOTE: the table above is not all-OK; every non-OK row needed no action from this verb (see above). Run: bash scripts/orchestrator-bringup.sh status  — its exit code is the fleet verdict."
  fi
  return 0
}

# fleet_stop_all <harness-path> — stop every component this file CAN stop, and never report a stop
# it did not verify. The controller is the CALLER's (the platform verb proves the owner is dead
# before releasing the lock); a lander and the cell supervisor are explicitly left alone.
fleet_stop_all() { # <harness-path>
  local harness="${1:-}" out name state stopped=0 failed=0
  out="$(fleet_rows "$harness")"
  while IFS=$'\t' read -r name state; do
    [ -n "${name:-}" ] || continue
    case "$name" in
      controller)
        # Counting it here would print "stopped controller" for a no-op.
        continue ;;
      landers)
        say "landers: left running — a lander is in-flight work for one change; its claim expires on its own"; continue ;;
      cell-supervisor)
        say "cell-supervisor: left running — it owns the controller session; stop it with cloud-cell-supervisor.sh stop"; continue ;;
    esac
    case "$state" in
      SKIPPED|MISSING) continue ;;
    esac
    if ! fleet_component_has_stop "$name"; then
      say "$name: left running (no stop mechanism on this box)"; continue
    fi
    if fleet_stop_component "$name"; then
      say "stopped $name (was $state)"; stopped=$(( stopped + 1 ))
    else
      say "could not stop $name (was $state) — it may still be running"; failed=$(( failed + 1 ))
    fi
  done <<<"$(printf '%s\n' "$out" | awk -F'\t' '{print $1"\t"$4}')"
  [ "$stopped" -gt 0 ] || say "no other fleet component was running"
  [ "$failed" -eq 0 ] || return 1
  return 0
}
