#!/usr/bin/env bash
# lane-reap.sh — count fleet lanes by EVIDENCE, and reap the ones that provably FINISHED (#2163).
#
# WHY THIS EXISTS (the measured defect)
# A lane is launched roughly as
#     bash -c '… cd <repo>; nohup pi --model … -p "$(cat brief)" > /tmp/jobs/L-<slug>.log 2>&1 &'
# When the turn ends — or the lane is blocked, or its parent died — NOTHING exits. Measured on the
# Mac on 2026-10-19: `ps -eo command | grep -c 'pi --model'` said **76 pi processes**; the truth was
# **14 live lanes and ~60 finished/blocked ones** still resident. Consequences, all measured:
#   * cell-2 filled to 23 lanes and the box OOM-killed 37 processes AND the tmux server
#     (agent-infra#2159), losing every lane on it; most of that memory was resident after finishing;
#   * load average became a lie in both directions, and dispatch decisions were taken on it;
#   * the obvious counting command counts the WRAPPER BASH, not `pi` — so any instrument built on
#     that string over-reports capacity in use, and a reaper built on it "reaps" wrappers while
#     leaving children (or kills live work while sparing zombies).
#
# THE TWO HALVES OF THIS FILE, ONE POPULATION EACH
#   count   the `[cap]` line's `lanes=<live>/<total> zombie=<n>` — a lane is LIVE iff its process
#           tree exists AND its log/turn advanced within a bounded window (LANE_REAP_LIVE_MIN).
#           `total` is every resident lane tree, so a box that LOOKS busy but is not says so.
#   reap    the conservative process reaper. Dry run by default; `--apply` signals.
#
# ⛔ THE THREE GATES, ALL REQUIRED (#1244 — "the parked-CPU rule exists only as prose" — this is the
# code that rule becomes). A lane is reaped ONLY when every one holds:
#   1. ZERO CPU DELTA over a real sample window, summed over the wrapper AND every descendant. A
#      sub-0.1s twitch has the same signature as a parked fork child, a human's prompt redraw and a
#      timer wake, so the tolerance is STATED (CPU_TOL_CS) and the window is a second sample.
#   2. POSITIVE FLEET ANCESTRY — a HUMAN ancestor is a hard refusal, and an ancestry the tool cannot
#      POSITIVELY identify as the fleet also refuses. Walked nearest-first: the FIRST recognised host
#      application decides. `Terminal.app`/`iTerm`/`Warp`/`kitty`/`Alacritty`/`WezTerm`/`Ghostty`/
#      `xterm`/`gnome-terminal`/`konsole`/`foot`/VS Code/a `sshd` session means the
#      process belongs to a HUMAN and is never touched, however parked. ⛔ `tmux`/`screen` are NOT in
#      that set: a multiplexer is the fleet's own launch surface (macOS `worker-terminal.sh` uses tmux
#      when the cmux daemon cannot answer), so the walk goes THROUGH the server to the human terminal
#      above it — or to `unknown`, which refuses. `ppid 1` proves nothing (a
#      daemonising service reparents to 1 BY DESIGN). `login`/`zsh` alone are NOT human: every cmux
#      lane is `pi → -zsh → login → cmux.app`, so treating them as human would make the reaper inert.
#      ⛔ `unknown` REFUSES (#2163 review, P1). It used to PERMIT, and every host app missing from the
#      list above — plus a truncated process table, whose empty command read as "no marker" — then
#      TERMed a live tree. A lane is judged only on POSITIVE fleet evidence: `cmux.app` on the Mac,
#      and — since #2868 — the cell supervisor's environ/cgroup marker on a Linux cell
#      (`cell_fleet_marker`, below). The census and `--dry-run` are unaffected.
#   3. A STALENESS CLASSIFICATION, from a file THIS LANE'S OWN `pi` (or its `tee` writer) holds open:
#        (a) log present, untouched >= LANE_REAP_IDLE_MIN (default 2h); or
#        (b) log absent/deleted AND the process has been up >= LANE_REAP_NO_LOG_H (default 12h).
#      Anything else is REPORTED, never reaped.
#
# ⛔ AN ABSENT ARTEFACT MUST FAIL CLOSED — THE TRAP THIS FILE EXISTS TO NOT REPEAT.
# The first dry run flagged 69 lanes and would have killed one that was 7 MINUTES old: the lane's
# worktree slug was parsed from the SHELL COMMAND TEXT, which contains escapes (`ciwatch\012[`), the
# slug matched no log file, and the reaper read "no log found" as "stale". So:
#   * the lane population and its log are derived from the KERNEL (the process table and the file
#     descriptors it holds), NEVER from parsing a command line for a name;
#   * "I could not resolve a log at all" is `refuse:no-log-evidence`, which is not evidence of
#     staleness and is never reaped;
#   * the no-log branch applies only when a log path IS resolved (e.g. `/…/L-x.log (deleted)`) and
#     the file is provably gone, and even then it needs the 12h age bound.
# Every unreadable read (ps, /proc, lsof, mtime) abstains. A control that cannot see must not kill.
#
# ⛔ THE POPULATION IS NOT `ps | grep 'pi --model'`. A lane is a **`pi` process tree**: a `pi` and,
# when its immediate parent is a shell, that one wrapper shell (the launcher). One wrapper level is
# summed and signalled — climbing further would swallow a tool shell of a LIVE lane (measured on a
# cell: a `pi` reviewer under `reviewer-preflight.sh` whose grandparent was another live lane's
# `pi`), which is a lane-killer. The tree is identified by POSITIVE evidence: THIS LANE's `pi` — the
# root when it is `pi`, else the root's direct `pi` child — or a `tee` in the root's direct children
# whose STDIN IS THAT `pi`'s STDOUT, holding a fleet-namespace log (`L-*.log`, `lane-*.log`,
# `fix-*.log`, `merge-*.log`, `chain-*.log`) as stdout/stderr. ⛔ Not any process in the subtree,
# and not even an arbitrary DIRECT CHILD — measured (#2163 review, P1): a wrapper backgrounding a
# `fix-*` writer and
# the live `pi` beside it let the writer's 3 h-old log judge the 30 s-old lane, and `--apply` TERMed
# the working `pi`. A sibling that holds a DIFFERENT lane's log is not this lane's evidence; when a
# tree presents MORE THAN ONE distinct lane log the answer is `ambiguous-log-evidence` (refused), not
# a guess. A tee counts as this lane's writer only when its stdin IS this lane's `pi`'s stdout (one
# kernel-identity fact, never "some pipe" — #2163 review r3). An interactive `pi` (fds on a
# tty/socket) is not in the population at all.
#
# ⛔ THE CENSUS ABSTAINS RATHER THAN REPORT `0/0` (#2163 review, P0). `count` printed
# `lanes=0/0 zombie=N` with exit 0 when a descriptor could not be read for ANY tree (no /proc, no
# `lsof`, `lsof` denied) — which `orch-loop.sh` reads as a clean `0`, so the MAX_LANES ceiling was
# never reached and the controller dispatched MORE onto the box. A tree whose descriptors cannot be
# read MAY be a lane, so the census abstains (`?/?`, exit 3); a tree whose descriptors WERE read and
# hold no fleet log is simply not a lane (`0/0` is then a real answer).
# ⛔ A THIRD CASE ABSTAINS TOO (#2163 review r7, P3): the reads SUCCEEDED but the platform prints no
# per-pipe name (`pipe`, `->0x0`), so a `tee` beside the tree cannot be shown to be its own writer.
# The tree is counted in `unidentifiable=` and the census abstains — the cause is named in
# $LANE_REAP_LOG, never as a failed read.
#
# WHAT THIS DOES NOT COVER (stated, not silently trusted):
#   * the owner's own interactive `pi` INSIDE cmux with stdout redirected to a lane-shaped log —
#     cmux-rooted ancestry does not by itself separate it from a fleet lane (the residual #1207 and
#     #1244 both name). Mitigated by the zero-CPU window AND the 2h log-idle proof, and reported
#     per lane in the dry run so a human can see it before arming.
#   * a lane whose log was deleted AND whose age is under 12h is REPORTED, not reaped — that is the
#     conservative side of the trap above, and it is why the measured reap population is old lanes.
#   * ⚠️ CELL-INERT, A PRODUCT DECISION FOR THE PR AUTHOR (not a silent behaviour), WITH ITS OWN
#     VERDICT (`reap` exits 4 for it, never 3): a completed pass that judged nothing by policy is not
#     a failed read, and a consumer that treated it as one would show a permanent red on a surface
#     where the policy below is working exactly as recorded. Gate 2 now
#     requires POSITIVE fleet evidence. The fleet hosts this tool recognises are `cmux.app` — a Mac
#     application — and, since #2868, the Linux-cell supervisor: its unit cgroup
#     (`/proc/<pid>/cgroup` naming e.g. `eldato-orchestrator.service` / `cloud-cell-supervisor.service`)
#     or a marker in `/proc/<pid>/environ` written by the supervisor at spawn (`CONTROLLER_UNIT=…`,
#     `HARNESS_MATERIALISER=…`). `cell_fleet_marker` reads both, configurable via
#     `LANE_REAP_CELL_UNITS` / `LANE_REAP_CELL_ENV_MARKERS`. A lane whose ancestry carries NEITHER
#     (`pi → bash → systemd → init` on a cell without those markers, or an orphan reparented to init)
#     is still `unknown` and refused — the ORPHAN-PARENTLESS boundary is unchanged and still pinned
#     by its test leg. The CELL-TMUX leg pins the new behaviour: a cell's own tmux launcher, whose
#     ancestry would otherwise read `unknown`, is POSITIVE fleet evidence once the marker is read.
#   * `--apply` is DRY RUN by default. Arming is a deliberate operator action, same as every other
#     deletion tool in this tree.
#   * a leaked lane whose stdout is a PTY/PIPE and whose log name is outside the fleet namespace has
#     no artefact to judge, so it is in NEITHER the census nor the reap population. That is the same
#     fail-closed rule as `no-log-evidence`; ending such a tree is the operator's call.
#
# Usage:
#   lane-reap.sh count                 # lanes=<live>/<total> zombie=<n>   (for `[cap]`)
#   lane-reap.sh reap [--dry-run|--apply] [--json]
#   lane-reap.sh --help
#
# Env seams (tests + tuning; production uses the defaults):
#   LANE_REAP_PS_BIN       ps (default: ps)
#   LANE_REAP_SLEEP_BIN    sleep (default: sleep)          tests replace it to skip the window
#   LANE_REAP_KILL_BIN     kill (default: kill)            tests stub the SIGNAL
#   LANE_REAP_LSOF_BIN     lsof (default: lsof)             used only where /proc is absent
#   LANE_REAP_PROC_ROOT    /proc-like root (default: /proc; absent → lsof)
#   LANE_REAP_NOW          epoch seconds (tests pin the clock)
#   LANE_REAP_WINDOW       CPU sample window, seconds (default 30)
#   LANE_REAP_CPU_TOL_CS   parked tolerance, centiseconds (default 10 = 0.10s)
#   LANE_REAP_IDLE_MIN     log-untouched bound, minutes (default 120 = 2h)
#   LANE_REAP_NO_LOG_H     no-log age bound, hours (default 12)
#   LANE_REAP_LIVE_MIN     log-advanced window that makes a lane LIVE, minutes (default 125 — it must
#                          sit ABOVE the lane's wall BACKSTOP, or a lane that is alive and inside one
#                          long silent tool call reads as dead to the MAX_LANES gate and the box
#                          over-admits. Was 45, chosen against a 40-minute flat cap; since
#                          agent-infra#2888 the cap is a 2 h backstop (`LANE_BACKSTOP_S`, spawn-gate.sh)
#                          and the progress bound — not the wall — is what ends a wedged lane, so this
#                          window follows the BACKSTOP and lane-bound.test.sh pins the ordering)
#   LANE_REAP_LOG          durable pass log (default ~/.pi/agent/state/lane-reap.log)
#   LANE_REAP_LOCK         single-run lock (default ~/.pi/agent/state/lane-reap.lock)
#   LANE_REAP_TIMEOUT_BIN  timeout(1) (default: timeout; unresolvable ⇒ shell fallback, as on macOS)
#   LANE_REAP_READ_TIMEOUT bound for one external read, seconds (default 60)
#   LANE_REAP_PASS_TIMEOUT budget for ONE pass, seconds (default 120; a spent budget is `?`, never a
#                          partial census)
set -u

PROG="lane-reap"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PS_BIN="${LANE_REAP_PS_BIN:-ps}"
SLEEP_BIN="${LANE_REAP_SLEEP_BIN:-sleep}"
KILL_BIN="${LANE_REAP_KILL_BIN:-kill}"
LSOF_BIN="${LANE_REAP_LSOF_BIN:-lsof}"
# ⛔ `-`, NOT `:-`: the header documents "`LANE_REAP_PROC_ROOT` — /proc-like root (default: /proc;
# absent → lsof)", so an EMPTY value is a deliberate "do not use /proc" (the macOS shape, and the
# seam the test suite drives the lsof branch with). `:-` silently rewrote it back to /proc, which made
# that seam inert — and a seam that cannot express "no /proc" hides the whole lsof path from CI.
PROC_ROOT="${LANE_REAP_PROC_ROOT-/proc}"
# ⛔ THE CELL-SUPERVISOR EVIDENCE SOURCE (#2868). On a Linux cell the fleet's launch surface is a
# systemd unit, not `cmux.app`, and gate 2 (host_verdict) therefore read every cell lane as
# `unknown` and refused it — the CELL-INERT note in this file's header. The supervisor writes TWO
# positive markers into every process it spawns: an environ variable name (CONTROLLER_UNIT=…) and
# the unit's cgroup (`/system.slice/<unit>.service`). Recognising either as fleet makes the armed
# reaper live on a cell. Both lists are configurable so a cell under any unit name supplies its own
# evidence, and NEITHER is matched on argv — a prompt/path that merely mentions the name cannot
# spoof a marker read from /proc.
CELL_ENV_MARKERS="${LANE_REAP_CELL_ENV_MARKERS:-CONTROLLER_UNIT HARNESS_MATERIALISER}"
CELL_UNITS="${LANE_REAP_CELL_UNITS:-eldato-orchestrator.service cloud-cell-supervisor.service cloud-cell-controller.service}"
WINDOW="${LANE_REAP_WINDOW:-30}"
CPU_TOL_CS="${LANE_REAP_CPU_TOL_CS:-10}"
# NOT `IDLE_MIN`: that name is a REGISTERED term owned by `scripts/orchestrator-heartbeat.sh`
# (its 9-minute "spinner absent ⇒ finished" classification bound). This is a different bound with
# a different value (3 h), so sharing the name would read as one authority and hide the divergence
# the registry exists to surface. The env seam keeps its documented `LANE_REAP_` prefix.
# ⛔ THE SHIPPED DEFAULT IS DELIBERATELY ABOVE **TWO** OTHER BOUNDS, and both orderings are pinned by
# `lane-bound.test.sh` (i0) so the next edit cannot re-invert them (agent-infra#2888 review, F4):
#   1. `LIVE_MIN` (the capacity census's "this lane's log moved, so it is live" window). LIVE_MIN must
#      sit ABOVE the backstop (a lane may legitimately run that long), and the idle window must sit
#      ABOVE LIVE_MIN — otherwise a lane in the band between them is counted LIVE for capacity AND is
#      a reap CANDIDATE, two shipped instruments disagreeing about the same lane. 125 < 180.
#   2. `LANE_BACKSTOP_S` (7200 s = 120 min). At 120 the reaper could declare a lane finished at the
#      exact instant its own backstop still allows it to run, with no evidence but log silence.
LANE_IDLE_MIN="${LANE_REAP_IDLE_MIN:-180}"
NO_LOG_H="${LANE_REAP_NO_LOG_H:-12}"
LIVE_MIN="${LANE_REAP_LIVE_MIN:-125}"
READ_TIMEOUT="${LANE_REAP_READ_TIMEOUT:-60}"
# The budget for ONE pass, in seconds. A controller calls `count` every cycle, and the per-read
# bound (`READ_TIMEOUT`) bounds ONE fork, not the sweep: 76 lane roots x a slow/hung lsof is a pass
# that outlives the cycle it is measuring. The deadline turns "slow" into a NAMED abstention
# (`lanes=?/?` / CANNOT-VERIFY) instead of a controller that stops logging capacity. It is checked
# between lanes, so a pass never stops in the middle of a kill.
PASS_TIMEOUT="${LANE_REAP_PASS_TIMEOUT:-120}"
LOG="${LANE_REAP_LOG:-${HOME:-/tmp}/.pi/agent/state/lane-reap.log}"
LOCK="${LANE_REAP_LOCK:-${HOME:-/tmp}/.pi/agent/state/lane-reap.lock}"

is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
now_s() { if is_num "${LANE_REAP_NOW:-}"; then printf '%s' "$LANE_REAP_NOW"; else date +%s; fi; }

# The numeric seams, coerced ONCE for both audiences. A non-number either aborts the arithmetic under
# `set -u` or silently disables the bound it configures; both are fail-open on a gate. Repair to the
# documented default (fail CLOSED: the bound is restored, not removed).
coerce_limits() {
  is_num "${PASS_TIMEOUT:-}" || PASS_TIMEOUT=120
  for _v in WINDOW CPU_TOL_CS LANE_IDLE_MIN NO_LOG_H LIVE_MIN; do
    case "$_v" in
      WINDOW)        is_num "${WINDOW:-}"        || WINDOW=30 ;;
      CPU_TOL_CS)    is_num "${CPU_TOL_CS:-}"    || CPU_TOL_CS=10 ;;
      LANE_IDLE_MIN) is_num "${LANE_IDLE_MIN:-}" || LANE_IDLE_MIN=180 ;;
      NO_LOG_H)   is_num "${NO_LOG_H:-}"   || NO_LOG_H=12 ;;
      LIVE_MIN)   is_num "${LIVE_MIN:-}"   || LIVE_MIN=125 ;;
    esac
  done
}

# Bound ONE external read. `timeout`/`gtimeout` when present; otherwise a WATCHDOG SUBSHELL, because
# macOS ships neither and an unbounded read on that box stalls the controller's hot loop (the same
# MUST the doctor's `bounded` obeys, and the read here feeds every cycle's `[cap]`). A read we cannot
# bound is not silently unbounded: it is killed after the budget, and the caller sees a failed read.
# `LANE_REAP_TIMEOUT_BIN` is the tool seam (default `timeout`): pointing it at an unresolvable name
# forces the shell fallback, which is the ONLY path macOS takes and which CI would otherwise never
# execute. Same idiom as the doctor's `DOCTOR_TIMEOUT_BIN`.
TIMEOUT_BIN="${LANE_REAP_TIMEOUT_BIN:-timeout}"
bound() { # bound <seconds> <cmd...>
  local s="$1"; shift
  if [ -n "$TIMEOUT_BIN" ] && command -v "$TIMEOUT_BIN" >/dev/null 2>&1; then
    "$TIMEOUT_BIN" "$s" "$@"; return $?
  fi
  local p w rc sp was_m jm
  "$@" &
  p=$!
  # ⛔ THE WATCHDOG KILLS ITS SLEEPER BECAUSE IT IS A PROCESS-GROUP LEADER (#2163 review, P2 — third
  # and final shape). The earlier attempts failed for a STRUCTURAL reason worth writing down:
  # `wait` only sees the caller's OWN children, and a pid handed between shells (a variable, then a
  # file) has a hand-off window in which the sleeper is orphaned. Here the watchdog is started under
  # job control, so `-$w` names ITS group: the subshell AND the `sleep` it forked are ended by ONE
  # signal, with no hand-off and no window. The parent knows `$w` synchronously.
  # If job control is refused (a shell without `set -m`), the group operand matches nothing and the
  # fallback `kill "$w"` ends the subshell; its sleeper then expires on its own, bounded by READ_TIMEOUT.
  # STATED RESIDUAL: on such a shell, ONE `sleep <read-timeout>` may outlive a read.
  was_m=0; case $- in *m*) was_m=1 ;; esac
  jm=0
  set -m 2>/dev/null && jm=1
  ( "$SLEEP_BIN" "$s" & sp=$!
    wait "$sp"
    kill -TERM "$p" 2>/dev/null; "$SLEEP_BIN" 1; kill -KILL "$p" 2>/dev/null ) >/dev/null 2>&1 &
  w=$!
  [ "$was_m" = "1" ] || { [ "$jm" = "1" ] && set +m 2>/dev/null; }
  wait "$p"; rc=$?
  if [ "$jm" = "1" ]; then
    kill -TERM -- "-$w" 2>/dev/null || kill -TERM "$w" 2>/dev/null
  else
    kill -TERM "$w" 2>/dev/null
  fi
  wait "$w" 2>/dev/null
  return "$rc"
}

logline() { # one durable, bounded line per event (best effort; never fails the pass)
  local dir
  dir="$(dirname "$LOG")"
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || return 0
  printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG" 2>/dev/null || true
}

# ── the process table, ONE snapshot ───────────────────────────────────────────────────────────────
# Fields: pid, ppid, stat, TIME (cumulative CPU), ELAPSED, and the rest of the line (args).
# Output is TAB-separated and NORMALISED (cpu in centiseconds, elapsed in seconds) so every later
# awk compares numbers, not `ps`'s human spellings.
#
# ⛔ `-ww`: without it `ps` TRUNCATES the command at the terminal width, and the truncated tail is
# exactly where a launcher's `nohup pi …` lives — the classifier would then see a shell with no
# `pi` under it. (The doctor reads `ppid,args` per pid and pays one fork each; this reads the table
# once, which is what lets `count` run every controller cycle.)
read_table() {
  bound "$READ_TIMEOUT" "$PS_BIN" -A -o pid=,ppid=,stat=,time=,etime=,args= -ww 2>/dev/null | awk '
    function cs(t,   i,d,n,a,b,sec) {
      # [[dd-]hh:]mm:ss.cc -> centiseconds
      d = 0; i = index(t, "-")
      if (i > 0) { d = substr(t, 1, i-1) + 0; t = substr(t, i+1) }
      n = split(t, a, ":"); sec = 0
      if (n >= 3)      sec = (a[1]+0)*3600 + (a[2]+0)*60 + a[3]
      else if (n == 2) sec = (a[1]+0)*60 + a[2]
      else             sec = a[1]
      split(sec ".", b, ".")
      # sec may be "12.34"; b[1] is whole seconds, b[2] hundredths
      hun = 0
      if (b[2] != "") { hun = (b[2] "00"); hun = substr(hun, 1, 2) + 0 }
      return d*8640000 + (b[1]+0)*100 + hun
    }
    function es(t,   i,d,n,a,s) {
      d = 0; i = index(t, "-")
      if (i > 0) { d = substr(t, 1, i-1) + 0; t = substr(t, i+1) }
      n = split(t, a, ":"); s = 0
      if (n >= 3)      s = (a[1]+0)*3600 + (a[2]+0)*60 + (a[3]+0)
      else if (n == 2) s = (a[1]+0)*60 + (a[2]+0)
      else             s = a[1] + 0
      return d*86400 + s
    }
    {
      pid = $1; ppid = $2; stat = $3; tim = $4; et = $5
      if (pid !~ /^[0-9]+$/ || ppid !~ /^[0-9]+$/) next
      # `args` is everything after the fifth field — peeled by REGEX, so a `[comm]` that contains
      # spaces (a kernel thread) cannot shift the columns.
      cmd = $0
      sub(/^[ \t]*[^ \t]+[ \t]+[^ \t]+[ \t]+[^ \t]+[ \t]+[^ \t]+[ \t]+[^ \t]+[ \t]*/, "", cmd)
      printf "%s\t%s\t%s\t%d\t%d\t%s\n", pid, ppid, stat, cs(tim), es(et), cmd
    }'
}

# A table is a READ only when it can answer for the processes every host has: pid 1 and at least
# one more row. `{}`/blank is a FAILED read, never an empty fleet — an empty fleet is a destruction
# signal here (it makes every lane "gone" and every log "unowned").
table_readable() { # <tablefile>
  [ -s "$1" ] || return 1
  awk -F'\t' 'NR>0 { n++; if ($1 == 1) one = 1 } END { exit !(one && n >= 2) }' "$1"
}

# ── the lane population: `pi` trees with a fleet log held open ────────────────────────────────────
# One wrapper level. `pi` is the process whose argv's FIRST token is `pi` (the binary rewrites its
# title to APP_NAME); its immediate parent joins the tree only when that parent is a SHELL.
lane_roots() { # <tablefile>
  awk -F'\t' '
    function base(cmd,   f,g,p) {
      if (cmd == "") return ""
      split(cmd, f, /[ \t]+/)
      g = split(f[1], p, "/")
      return tolower(p[g])
    }
    BEGIN { split("bash sh zsh dash ksh fish ash mksh", _s, " "); for (i in _s) shell[_s[i]] = 1 }
    { ppid[$1] = $2; cmd[$1] = $6 }
    END {
      for (p in cmd) {
        if (base(cmd[p]) != "pi") continue
        root = p
        par = ppid[p]
        if (par != "" && (par in cmd) && (base(cmd[par]) in shell)) root = par
        seen[root] = 1
      }
      for (r in seen) print r
    }' "$1" | sort -n -u
}

tree_pids() { # <tablefile> <root> -> "pid<TAB>depth", deepest LAST
  awk -F'\t' -v root="$2" '
    { pp[$1] = $2 }
    END {
      if (!(root in pp)) { print root "\t0"; exit }
      d[root] = 0
      for (i = 0; i < 64; i++) {
        ch = 0
        for (p in pp) if (!(p in d) && (pp[p] in d)) { d[p] = d[pp[p]] + 1; ch = 1 }
        if (!ch) break
      }
      for (p in d) printf "%s\t%d\n", p, d[p]
    }' "$1"
}

cpu_sum_cs() { # <tablefile> <pidsfile>
  awk -F'\t' 'FNR == NR { sel[$1] = 1; next } ($1 in sel) { s += $4 } END { print s+0 }' "$2" "$1"
}

# ⛔ THE WALK MUST SAY WHETHER IT WAS COMPLETE (#2163 review, P1). It used to break out on a ppid row
# that was not in the table and let `host_verdict` read the resulting empty command as "no marker" —
# so an unreadable or truncated process table produced `unknown`, which PERMITTED the kill. Every row
# is followed by a terminator line, so a caller can tell "I walked to the top and saw nothing" from
# "I lost the chain". `cloud-cell-doctor.sh`'s `human_above` already refuses (rc 2) on the same
# input; this is the same rule in this tool's vocabulary.
ancestry() { # <tablefile> <pid> -> "pid<TAB>cmd" nearest first, then "#complete"|"#incomplete"
  awk -F'\t' -v start="$2" '
    { pp[$1] = $2; cm[$1] = $6 }
    END {
      p = start; done = 0
      for (i = 0; i < 64 && p != "" && p != 0; i++) {
        # a missing row (or a pid with no command) is a TRUNCATED TABLE, not the top of the chain
        if (!(p in cm) || cm[p] == "") { print "#incomplete"; done = 1; break }
        print p "\t" cm[p]
        if (p == 1) { print "#complete"; done = 1; break }
        q = pp[p]
        if (q == 0) { print "#complete"; done = 1; break }
        if (!(q in cm)) { print "#incomplete"; done = 1; break }
        p = q
      }
      if (!done) print "#incomplete"
    }' "$1"
}

# ── the log the process itself holds open (kernel evidence, never a parsed slug) ──────────────────
# Accepted names are the fleet's own log namespace — EXACTLY the files the shipped writers create:
#   lane.sh         `$O/logs/lane-$N.log`      → lane-*.log
#   chain-merge.sh  `$O/logs/chain-$N.log`     → chain-*.log
#   fix-one.sh      `$O/logs/fix-$PR.log`      → fix-*.log    (`L` is the PREFIX; the file is "$L.log")
#   merge-one.sh    `$O/logs/merge-$PR.log`    → merge-*.log  (same shape)
#   the launcher    `/tmp/jobs/L-<slug>.log`   → L-*.log
# The DIRECTORY does not matter: what matters is that this process has that file open as
# stdout/stderr, which an interactive session does not.
is_lane_log_name() {
  case "${1:-}" in
    L-*.log|lane-*.log|fix-*.log|merge-*.log|chain-*.log) return 0 ;;
  esac
  return 1
}

# _log_candidate <path> <pid> — the ONE place a descriptor becomes a lane-log candidate.
# Returns 0 and echoes "path<TAB>deleted<TAB>holder_pid" when it is one; 1 otherwise.
_log_candidate() {
  local path="${1:-}" pid="${2:-}" del=0 pdir=""
  [ -n "$path" ] || return 1
  case "$path" in *" (deleted)") del=1; path="${path% (deleted)}" ;; esac
  # ⛔ macOS lsof DOES NOT APPEND " (deleted)" (measured on 26.6.2, #2163 review): an
  # unlinked-but-held log resolves to its OLD path, so the `case` arm above only ever fires on
  # the /proc spelling and the whole `NO_LOG_H` arm was unreachable on the platform this tool
  # ships to (the lane then abstained forever on `log-age-unreadable`, and the census reported
  # `lanes=?` every cycle — a reaper-proof dispatch stall). The kernel still supplies the fact:
  # a path whose PARENT is readable but which itself cannot be stat()ed is gone. It is judged
  # ONLY when the directory is readable, so an unreadable tree stays `unknown` (abstain) rather
  # than being called deleted on an absence we cannot see.
  if [ "$del" = "0" ] && [ ! -e "$path" ]; then
    pdir="${path%/*}"; [ "$pdir" = "$path" ] && pdir="."
    [ -d "$pdir" ] && [ -r "$pdir" ] && del=1
  fi
  is_lane_log_name "${path##*/}" || return 1
  printf '%s\t%s\t%s\n' "$path" "$del" "$pid"
  return 0
}

# _target_kind <name> — the coarse KIND of a descriptor, from its target's spelling.
# ⛔ THE SPELLING IS THE PLATFORM'S, THE KIND IS OURS (#2163 review r3, P1). `/proc` spells a pipe
# `pipe:[5150]`, lsof 4.95 spells it `pipe`, and macOS lsof spells it `->0x7f…`. A caller that wants
# to ask "is this descriptor the same pipe as that one" must never compare raw spellings — it asks
# this function for the kind and compares the NAMES, which are comparable between two reads taken on
# the SAME platform. See `read_targets`.
_target_kind() {
  case "${1:-}" in
    pipe:*)       printf 'pipe' ;;
    socket:*)     printf 'socket' ;;
    pipe|'->'*)   printf 'pipe' ;;
    /*)           printf 'file' ;;
    *)            printf 'other' ;;
  esac
}

# _pipe_ident <"kind<TAB>name"> — this descriptor's pipe IDENTITY, when the platform names a pipe
# PER PIPE. The one place the platform's pipe spelling is normalised, so callers compare identities.
#   rc 0  echoes the identity — two reads of THE SAME pipe produce the SAME string
#   rc 1  not a pipe at all (a file, a socket, no descriptor) — it cannot be a lane's writer
#   rc 2  a pipe whose NAME is not an identity on this platform — UNIDENTIFIABLE: the caller abstains
#
# ⛔ A PIPE'S *TYPE* IS NOT A PIPE'S IDENTITY (#2163 review r4, P1). Normalising the KIND (see
# `_target_kind`) makes the tee test the same question on every platform, but the NAME it compares
# has to be a PER-PIPE name, and not every platform prints one: `/proc` prints `pipe:[<inode>]` (the
# pipe itself — identical at both ends), macOS lsof prints an address (`->0x…`), and **lsof 4.95 on
# Linux prints `pipe` — the same literal for BOTH ends of EVERY anonymous pipe** (measured). Reading
# `pipe` as a name made the tee test match *some* pipe in the tree: root 500, child 501
# `tee …/fix-9.log` fed by 503 `cat brief` (pipe B), child 502 the LIVE 5-minute-old `pi` piped to a
# logger (pipe A) ⇒ `REAP root=500 log-idle=10800s`, `-TERM 502`, `-KILL 502`. A generic spelling is
# therefore evidence of NOTHING, and lsof's `->0x0` (its placeholder when it cannot resolve the
# address) is a generic spelling too. An address form IS distinguishing — two live pipes never share
# one — but it is accepted only as a name that BOTH SIDES must reproduce, so it can never be borrowed
# from another pipe. Where the platform cannot do better the tee is unidentifiable, and the pass
# ABSTAINS rather than accept a guess (accepting borrows evidence; refusing outright would drop a
# real lane's own writer and re-open the `lanes=0/0` capacity fail-open).
# RESIDUAL, stated: if a platform's address is the PEER's (the far end's) rather than the pipe's own,
# the two ends of one pipe print different strings, so a `pi | tee L-x.log` there resolves
# `no-log-evidence` — an UNDER-count of capacity, never a kill. That is the conservative side of the
# trade; the pass that cannot name a pipe at all lands on the abstention above.
_pipe_ident() { # <target-line>
  local line="${1:-}" kind name
  kind="${line%%$'\t'*}"
  [ "$kind" = "pipe" ] || return 1
  name="${line#*$'\t'}"
  [ "$name" = "$line" ] && name=""
  case "$name" in
    'pipe:['[1-9]*)        printf '%s' "$name"; return 0 ;;   # /proc: pipe:[<inode>]
    '->0x'[1-9A-Fa-f]*)    printf '%s' "$name"; return 0 ;;   # lsof: a real address, never ->0x0
  esac
  return 2
}

# read_targets <pid> [fd…] — one descriptor per line as `<kind><TAB><name>`; rc 0 = the READ WAS
# TAKEN, 1 = BLIND.
#
# ⛔ "COULD NOT READ" AND "READ, NOTHING THERE" ARE DIFFERENT FACTS (#2163 review, P0). The census
# must tell them apart: a process whose descriptors cannot be read MAY be a lane (so the census
# abstains), while a process whose descriptors WERE read and hold no fleet log is simply not a lane.
# Collapsing the two is exactly how a blind box printed `lanes=0/0` and licensed more dispatch.
#
# ⛔ THE KIND TRAVELS WITH THE NAME (#2163 review r3, P1). The `tee` identity test compares THIS
# LANE's `pi` stdout against the tee's stdin, and does it by (kind, name) so the comparison is the
# same question on every platform — the old `case "$(read_targets …)" in pipe:*)` accepted only
# /proc's spelling, so the documented `pi | tee L-x.log` shape was refused on the lsof branch (rc 1
# ⇒ `reap` said `no-log-evidence` AND the census counted the lane `not_lane`, printing a confident
# `lanes=0/0` with exit 0 over a resident lane — the false-MAX_LANES fail-open this file closes
# elsewhere, on the only platform where `fleet` ancestry can exist).
#
# On Linux `/proc/<pid>/fd/{1,2}` is read directly; where /proc is absent (macOS) ONE `lsof` per
# process answers BOTH descriptors (a pass runs every controller cycle; two forks per pid does not).
read_targets() {
  local p="$1"; shift
  local fds="${*:-1 2}" fd path out rc
  if [ -n "$PROC_ROOT" ] && [ -d "$PROC_ROOT/$p" ]; then
    # present in the /proc namespace: an unreadable (or missing) fd dir is BLIND, not "no fds"
    [ -d "$PROC_ROOT/$p/fd" ] && [ -r "$PROC_ROOT/$p/fd" ] || return 1
    for fd in $fds; do
      path="$(readlink "$PROC_ROOT/$p/fd/$fd" 2>/dev/null)" || continue
      printf '%s\t%s\n' "$(_target_kind "$path")" "$path"
    done
    return 0
  fi
  # ⛔ A PID THAT VANISHED FROM A REAL /proc IS GONE, NOT BLIND. The population is a SNAPSHOT, so on a
  # busy box a lane can exit between the table read and this read — calling that "I could not see" would
  # abstain the whole census every cycle a lane happens to finish, which is how a fail-closed rule turns
  # into a false block. A real /proc advertises itself with `self`; a synthetic/unmounted root does not,
  # and there the absence is indistinguishable from a blind read, so it stays blind.
  if [ -n "$PROC_ROOT" ] && [ -e "$PROC_ROOT/self" ]; then return 0; fi
  if [ -n "$LSOF_BIN" ] && command -v "$LSOF_BIN" >/dev/null 2>&1; then
    # `-Ft` as well as `-Fn`: the TYPE is what separates a pipe from a unix socket when the platform
    # spells both `->0x…` (macOS). Field ORDER is lsof's own (4.95 prints `t` before `n` per fd), so
    # the pairing is done by holding the last `t` until its `n` arrives — never by position.
    out="$(bound "$READ_TIMEOUT" "$LSOF_BIN" -n -P -a -p "$p" \
             -d "$(printf '%s' "$fds" | tr ' ' ',')" -Ftn 2>/dev/null)"; rc=$?
    # lsof exits non-zero (with empty output) when it cannot stat the pid — a denial, not "no fds"
    [ "$rc" = "0" ] || return 1
    [ -n "$out" ] && printf '%s\n' "$out" | awk '
      function kind(t, n) {
        if (t == "FIFO" || t == "PIPE") return "pipe"
        if (t == "sock" || t == "unix") return "socket"
        if (n ~ /^pipe:/ || n == "pipe" || n ~ /^->/) return "pipe"
        if (n ~ /^\//) return "file"
        if (t == "REG" || t == "DIR" || t == "CHR") return "file"
        return "other"
      }
      /^t/ { t = substr($0, 2); next }
      /^f/ { t = ""; next }
      /^p/ { t = ""; next }
      /^n/ { n = substr($0, 2); printf "%s\t%s\n", kind(t, n), n; t = "" }
    '
    return 0
  fi
  return 1
}

# collect_evidence <pid> [fd…] — "path<TAB>deleted<TAB>holder" for every lane-namespace fd.
# rc 0 = read taken, 1 = BLIND (which is NOT "no evidence").
collect_evidence() {
  local p="$1"; shift
  local targets rc path found
  targets="$(read_targets "$p" "$@")"; rc=$?
  [ "$rc" = "0" ] || return 1
  [ -n "$targets" ] || return 0
  while IFS=$'\t' read -r _kind path; do
    [ -n "${path:-}" ] || continue
    found="$(_log_candidate "$path" "$p")" || continue
    printf '%s\n' "$found"
  done <<< "$targets"
  return 0
}

# lane_pi_pids <table> <root> — the pids that ARE this lane's agent: the root itself when its argv[0]
# basename is `pi`, else the root's direct children whose argv[0] basename is `pi`, in pid order.
# Nothing deeper: a descendant `pi` is ANOTHER lane (a reviewer, a tool subagent) and its log is not
# this lane's evidence (#2163 review, P1).
lane_pi_pids() {
  awk -F'\t' -v root="$2" '
    function base(cmd,   f,g,p) {
      if (cmd == "") return ""
      split(cmd, f, /[ \t]+/); g = split(f[1], p, "/")
      return tolower(p[g])
    }
    { pp[$1] = $2; cm[$1] = $6 }
    END {
      if (base(cm[root]) == "pi") { print root; exit }
      n = 0
      for (p in cm) if (pp[p] == root && base(cm[p]) == "pi") sel[n++] = p
      for (i = 0; i < n; i++) for (j = i + 1; j < n; j++)
        if (sel[j] + 0 < sel[i] + 0) { t = sel[i]; sel[i] = sel[j]; sel[j] = t }
      for (i = 0; i < n; i++) print sel[i]
    }' "$1"
}

# lane_tee_pids <table> <root> — `tee` in the root's direct children, in pid order. A tee is a
# candidate WRITER for this lane (`… pi | tee L-x.log`), and `resolve_log` accepts it only when its
# stdin really is a pipe, never a tee that merely shares the wrapper.
lane_tee_pids() {
  awk -F'\t' -v root="$2" '
    function base(cmd,   f,g,p) {
      if (cmd == "") return ""
      split(cmd, f, /[ \t]+/); g = split(f[1], p, "/")
      return tolower(p[g])
    }
    { pp[$1] = $2; cm[$1] = $6 }
    END {
      n = 0
      for (p in cm) if (pp[p] == root && base(cm[p]) == "tee") sel[n++] = p
      for (i = 0; i < n; i++) for (j = i + 1; j < n; j++)
        if (sel[j] + 0 < sel[i] + 0) { t = sel[i]; sel[i] = sel[j]; sel[j] = t }
      for (i = 0; i < n; i++) print sel[i]
    }' "$1"
}

# resolve_log <table> <root> — THIS LANE's own evidence, and nothing else's.
#   rc 0  echoes "path<TAB>deleted<TAB>holder_pid"   — one attributable evidence file
#   rc 1  the reads were taken and the tree holds no fleet log        — not a lane
#   rc 2  BLIND: a descriptor read failed, so the tree MAY be a lane  — abstain, never judge
#   rc 3  AMBIGUOUS: more than one distinct lane log                  — no single file is the evidence
#   rc 4  UNIDENTIFIABLE: the descriptors WERE read, but a pipe has no per-pipe NAME on this
#         platform, so a tee's identity cannot be compared at all     — abstain, never judge
# ⛔ rc 2 AND rc 4 ARE BOTH ABSTENTIONS BUT THEY ARE NOT THE SAME FACT (#2163 review r5, P3). rc 2
# says a READ FAILED (a blind box: lsof denied, no /proc); rc 4 says every read SUCCEEDED and the
# platform simply prints no identity for an anonymous pipe (lsof 4.95's literal `pipe`). Collapsing
# them made a perfectly readable tree report `log-evidence-unreadable (the descriptors could not be
# read …)` and count in `abstained=` — a blind-read cause for a blind-read that never happened, which
# sends the operator chasing a nonexistent lsof/permissions failure. A read failure outranks an
# unusable identity when a tree has both (the failed read is the stronger, true statement).
#
# ⛔ THE EVIDENCE MUST BELONG TO THIS LANE, NOT TO ANY PROCESS UNDER IT (measured, #2163 review P1).
# It used to take the FIRST fd whose basename matched the namespace, walking root then every direct
# child in pid order — with no check that the holder was THIS lane's pi. Reproduced: root 500
# (`bash lane.sh`), child 501 holding a 3 h-old `fix-9.log`, child 502 = the live pi holding
# `L-live.log` written 30 s ago ⇒ `REAP root=500 … log-idle=10800s`, and `--apply` TERMed 502 — the
# WORKING agent. Any wrapper that backgrounds two things (the legacy launcher shape) makes it live.
# So the evidence set is now:
#   `… nohup pi > L-x.log &`     → the lane's `pi`
#   `… pi | tee L-x.log`         → the tee, only when ITS STDIN IS THIS LANE'S PI'S STDOUT
#   `run_agent` (`pi >> "$log"`) → the lane's `pi`
# and nothing else. Two distinct lane logs in that set is ambiguity, not a choice.
resolve_log() {
  local table="$1" root="$2" p out cands="" blind=0 unident=0 distinct n
  local pis tees pstd tin pname prc trc
  pis="$(lane_pi_pids "$table" "$root")"
  tees="$(lane_tee_pids "$table" "$root")"
  for p in $pis; do
    out="$(collect_evidence "$p")" || { blind=1; continue; }
    [ -n "$out" ] && cands="$cands$out
"
  done
  if [ -n "$tees" ]; then
    # ⛔ THE TEE MUST BE **THIS LANE'S** WRITER, NOT MERELY *A* PIPE-FED TEE (#2163 review r3, P1).
    # The old test asked only "is this tee's stdin a pipe", so an unrelated pipe-fed sibling supplied
    # the evidence: root 500 (`bash lane.sh`), child 501 `tee …/fix-9.log` fed by 503 `cat brief`,
    # child 502 the LIVE 5-minute-old `pi` with fd1 on /dev/null ⇒ `REAP root=500 log-idle=10800s`,
    # `-TERM 502`, `-KILL 502`. The identity of the lane's writer is ONE fact: this tee's stdin IS
    # this lane's pi's stdout, read from the kernel on both sides.
    # ⛔ …AND THAT IDENTITY MUST BE A *PER-PIPE* NAME, NOT A SPELLING (#2163 review r4, P1). The
    # (kind, name) comparison is only as good as the platform's name: lsof 4.95 prints the literal
    # `pipe` for both ends of EVERY anonymous pipe, so comparing it matched ANY pipe in the tree and
    # re-ran the r3 kill on the lsof branch — the only branch macOS has, the only platform where
    # `fleet` ancestry exists. `_pipe_ident` returns an identity only when the platform prints one;
    # a tee whose stdin pipe cannot be identified is NOT "not this lane's writer" (refusing it would
    # drop a real lane's own writer and re-open the `lanes=0/0` capacity fail-open) and is NOT
    # evidence (accepting it borrows another pipe's file) — so the tree ABSTAINS.
    pstd=""; pblind=0
    for p in $pis; do
      tin="$(read_targets "$p" 1 2>/dev/null | head -1)"
      pname="$(_pipe_ident "$tin")"; prc=$?
      case "$prc" in
        0) pstd="$pstd$pname
" ;;
        2) pblind=1 ;;   # this lane's pi IS piped, but the pipe has no name this platform can tell
      esac
    done
    for p in $tees; do
      # BLIND on the candidate writer means the tree may hold evidence we cannot see — abstain.
      tin="$(read_targets "$p" 0 2>/dev/null)" || { blind=1; continue; }
      tin="$(printf '%s\n' "$tin" | head -1)"
      pname="$(_pipe_ident "$tin")"; trc=$?
      # stdin is not a pipe ⇒ this tee is not any lane's writer
      [ "$trc" = "1" ] && continue
      # stdin IS a pipe but the identity is unusable ⇒ unidentifiable, so ABSTAIN (never accept).
      # ⛔ THAT IS NOT A FAILED READ (#2163 review r5, P3): the descriptor was read and answered —
      # the platform just has no per-pipe name to compare. `unident` keeps it out of the blind-read
      # counter so `log-evidence-unreadable` stays reserved for a read that actually failed.
      if [ "$trc" = "2" ] || [ "$pblind" = "1" ]; then unident=1; continue; fi
      # not this lane's stdout ⇒ this tee is not its writer, whatever log it happens to hold
      # ⛔ THIS IS A SHAPE FIX, NOT A BEHAVIOUR FIX (#841/#864 `sigpipe-grep`; stated accurately after
      # review). `pipefail` is NOT active in this file (`set -u` only) and the caller runs it as a
      # child `bash`, which does not inherit it — so the 141 race is not reachable here, and `pstd`
      # (a single `pipe:[<inode>]`/`->0x…` line) is far below the size where grep -q's early exit could
      # lose a match. What reds is the IDIOM: the guard rejects a producer piped into a quiet grep
      # regardless, and this here-string is its sanctioned form. The stream is byte-identical
      # (`printf '%s\n'` and `<<<` each append exactly one newline), so the comparison cannot change.
      grep -Fxq -e "$pname" <<<"$pstd" || continue
      out="$(collect_evidence "$p")" || { blind=1; continue; }
      [ -n "$out" ] && cands="$cands$out
"
    done
  fi
  distinct="$(printf '%s' "$cands" | cut -f1 | awk 'NF && !seen[$0]++')"
  n="$(printf '%s\n' "$distinct" | awk 'NF { n++ } END { print n + 0 }')"
  [ "$n" -gt 1 ] && return 3
  # ⛔ A FAILED READ VETOES THE CANDIDATE, EVEN WHEN EXACTLY ONE WAS READ (#2163 review, P1). This
  # test used to sit BELOW the single-candidate return, so a tree holding one readable 3 h-old lane log
  # BESIDE a sibling whose descriptors could not be read resolved to that log and went on to be
  # TERM/KILLed as a whole tree — including the process whose state was never read — while the pass
  # printed `abstained=0` and exited 0. One candidate is not an answer to "what does THIS tree's
  # evidence say" when part of the tree was invisible: the tree may hold a second (live) lane, and the
  # file we happened to read belongs to the one that finished. Same rule as the blind arm below, one
  # step earlier: a control that cannot see must not kill.
  [ "$blind" = "1" ] && return 2
  if [ "$n" = "1" ]; then
    printf '%s\n' "$cands" | awk -F'\t' -v want="$distinct" '$1 == want { print; exit }'
    return 0
  fi
  [ "$unident" = "1" ] && return 4
  return 1
}

# instrument_usable <table> <roots…> — 0 when at least ONE descriptor of the trees we must judge can
# be read. One is enough: the census abstains per-lane on the ones it cannot read, so this is only
# the up-front "this box is BLIND" probe, and it makes the abstention one named line instead of a
# full pass of `lsof` denials.
instrument_usable() {
  local table="$1"; shift
  local root p n=0
  # Our OWN process is the cheapest proof that descriptors can be read at all: a /proc that cannot
  # answer for `$$` is a /proc this box does not have. `lsof` answers for it too, where /proc does not
  # exist (macOS).
  read_targets "$$" >/dev/null 2>&1 && return 0
  # Then the first few trees we must judge — our own fd dir can be outside a fake/remote root, and a
  # probe that walks the WHOLE population is exactly the cost this up-front check exists to avoid.
  for root in "$@"; do
    for p in $root $(lane_pi_pids "$table" "$root") $(lane_tee_pids "$table" "$root"); do
      read_targets "$p" >/dev/null 2>&1 && return 0
      n=$((n + 1)); [ "$n" -ge 8 ] && return 1
    done
  done
  return 1
}

mtime_epoch() { # prints epoch seconds, or nothing when unreadable
  local m
  m="$(stat -c %Y "$1" 2>/dev/null)"
  is_num "${m:-}" || m="$(stat -f %m "$1" 2>/dev/null)"
  is_num "${m:-}" || m=""
  printf '%s' "$m"
}

# ── gate 2: the first recognised HOST APPLICATION in the chain decides ────────────────────────────
# Returns: human | fleet | unknown | incomplete. `human` is a hard refusal, and so are `incomplete`
# (a truncated/unreadable process table) and `unknown` — #2163 review, P1: `unknown` used to PERMIT
# the kill, so every host app missing from the marker set (xterm, wezterm, gnome-terminal, a cloud web
# console with no sshd, a tmux daemonised from init) and every truncated table read as permission.
# Only `fleet` licenses judging a tree: a lane is judged on POSITIVE fleet evidence.
# ⚠️ On a Linux cell every lane used to be `unknown`, so the ARMED reaper was inert there — the CELL
# evidence source below (`cell_fleet_marker`) closes that, reading the supervisor's environ/cgroup
# marker from /proc. See the PRODUCT DECISION note in this file's header.
#
# ⛔ THE WALK STARTS AT THE FIRST ANCESTOR, NOT AT THE ROOT (#2163 review, P1). The root's OWN argv
# is the launcher's: it carries the brief path, a `PATH=/Applications/cmux.app/...` export, even the
# prompt. Matching that text let a `cmux.app` substring in the root's command line return `fleet`
# BEFORE the real `Terminal.app` ancestor was ever examined — the verdict decided by prompt text, the
# exact "never parse a command line for a name" trap this file exists to close. Gate 2 is about
# ANCESTORS, so `tail -n +2` drops the root and the walk starts where the host app actually lives.
# cell_fleet_marker <pid> — the Linux-cell fleet evidence source (#2868). On a cell the fleet's
# launch surface is a systemd unit, not `cmux.app`. The supervisor writes TWO positive markers into
# every process it spawns, and either one read from /proc is fleet evidence:
#   1. an environ variable name in CELL_ENV_MARKERS (CONTROLLER_UNIT=…, HARNESS_MATERIALISER=…);
#   2. the unit's cgroup (`/system.slice/<unit>.service`) in CELL_UNITS.
# rc 0 = fleet (echoes the evidence kind), rc 1 = no marker (the walk continues). An unreadable
# /proc for a pid answers NOTHING (rc 1), so a blind read can never become fleet — fail-closed.
cell_fleet_marker() { # <pid> -> prints cell-env|cell-unit; rc 0 fleet, 1 no-marker
  local pid="$1" cg env mk u
  [ -n "$pid" ] && is_num "$pid" || return 1
  [ -n "$PROC_ROOT" ] && [ -d "$PROC_ROOT/$pid" ] || return 1
  if [ -r "$PROC_ROOT/$pid/environ" ]; then
    env="$(tr '\0' '\n' < "$PROC_ROOT/$pid/environ" 2>/dev/null)"
    for mk in $CELL_ENV_MARKERS; do
      [ -n "$mk" ] || continue
      case "$env" in *"$mk="*) printf 'cell-env\n'; return 0 ;; esac
    done
  fi
  if [ -r "$PROC_ROOT/$pid/cgroup" ]; then
    cg="$(cat "$PROC_ROOT/$pid/cgroup" 2>/dev/null)"
    for u in $CELL_UNITS; do
      [ -n "$u" ] || continue
      case "$cg" in *"/$u") printf 'cell-unit\n'; return 0 ;; esac
    done
  fi
  return 1
}

host_verdict() { # <tablefile> <pid> -> human | fleet | unknown | incomplete
  local apid acmd low exe base complete=0
  while IFS=$'\t' read -r apid acmd; do
    case "$apid" in
      '#complete')   complete=1; continue ;;
      '#incomplete') printf 'incomplete\n'; return 0 ;;
    esac
    low="$(printf '%s' "$acmd" | tr '[:upper:]' '[:lower:]')"
    # ⛔ THE TWO MARKER SETS HAVE DELIBERATELY DIFFERENT POLARITIES (#2163 review, P2 — and cycle 4
    # corrected this comment, which had claimed both were executable-only).
    # HUMAN is matched ANYWHERE in the ancestor's argv: a prompt or `-c` payload that merely mentions
    # `Terminal.app` then over-REFUSES (the lane is spared), which is the safe direction — and it also
    # covers an executable PATH that contains a space (`/Applications/My Apps/Terminal.app/…`), which
    # a first-token split would miss and turn into `unknown`.
    # ⛔ THE HUMAN SET IS EVERY TERMINAL A LANE'S ANCESTRY CAN ACTUALLY HAVE (#2163 review, P1). The
    # shipped set was the macOS-native handful, so `xterm`/`wezterm`/`ghostty`/`konsole`/
    # `gnome-terminal-server`/`foot`/VS Code/a bare `screen`/a tmux daemonised from init all fell to
    # `unknown` — and `unknown` PERMITTED the kill. Over-refusal is the safe direction here (the lane
    # is spared); a terminal missing from this set is a human's lane a reaper must not touch.
    # The names below cannot be mistaken for a `TERM=…` value, so they are matched ANYWHERE in argv
    # (which is also what covers an executable path containing a space).
    case "$low" in
      *terminal.app*|*iterm*|*warp.app*|*kitty.app*|*alacritty.app*|*hyper.app*|*sshd*|\
      *gnome-terminal*|*konsole*|*wezterm*|*ghostty*|*code-server*|*code\ helper*)
        printf 'human\n'; return 0 ;;
    esac
    # ⛔ THESE ARE MATCHED ON THE EXECUTABLE BASENAME, NOT ANYWHERE (#2163 review, P1). `xterm` is
    # ALSO a `TERM=` spelling (`TERM=xterm-256color` is the commonest value there is), so an
    # anywhere-match would refuse a fleet lane on an ancestor wrapper that merely exported its
    # terminal type — a false refusal that reads exactly like an armed reaper being inert. A basename
    # match still refuses every real xterm host, which is the safe direction.
    # ⛔ AND `tmux`/`screen` ARE DELIBERATELY **NOT** IN THIS SET (#2163 review r3, P2). A multiplexer
    # is not a human: it is the fleet's own LAUNCH SURFACE. `worker-terminal.sh` selects tmux as THE
    # launcher on macOS whenever `cmux tree --json` cannot answer (the launchd controller — measured
    # and recorded in `tools/fleet/lane_liveness.py`), and a pane's processes descend from the tmux
    # SERVER. Naming `tmux` human classified every lane on that surface `human-ancestor` and every
    # `tmux: server` root `unknown` — i.e. it made the armed reaper INERT on exactly the surface the
    # fleet spawns on, while the declared consequence named only Linux cells. Dropping them loses no
    # protection: the walk continues THROUGH the server and refuses on the human terminal above it
    # (`Terminal.app`/iTerm/WezTerm/…), and a server daemonised from init/launchd reaches `unknown`,
    # which refuses too. RESIDUAL, the same one #1207/#1244 already name: a human's interactive `pi`
    # inside a cmux pane has a tmux server under cmux.app and so reads `fleet` — bounded by the
    # zero-CPU window and the 2 h idle proof, and named in the dry run before arming.
    exe="${acmd%%[[:space:]]*}"
    exe="$(printf '%s' "$exe" | tr '[:upper:]' '[:lower:]')"
    base="${exe##*/}"
    case "$base" in
      foot|xterm|uxterm) printf 'human\n'; return 0 ;;
    esac
    # FLEET is decided on the EXECUTABLE ONLY (the first token): accepting a `/…cmux.app/…` path in
    # an ARGUMENT made an ancestor's `PATH=…`/prompt text return `fleet` and `return` before a real
    # human terminal above it was examined — the kill-path fail-open, reproduced by review. A cmux
    # path containing a SPACE is therefore classified `unknown`, and `unknown` now REFUSES.
    case "$exe" in
      */cmux.app/*|cmuxterm|*/cmuxterm|cmux) printf 'fleet\n'; return 0 ;;
    esac
    # CELL: the Linux-cell supervisor's marker, read from /proc (cgroup + environ), is POSITIVE
    # fleet evidence (#2868). It runs AFTER the human checks above (an sshd/Terminal ancestor still
    # refuses first) and AFTER the cmux check (so cmux keeps its macOS precedence). On macOS there
    # is no cgroup and no supervisor environ, so this branch is inert there. An unreadable /proc for
    # this pid answers NOTHING (rc 1) and the walk continues — a blind read never becomes fleet.
    if cell_fleet_marker "$apid" >/dev/null 2>&1; then printf 'fleet\n'; return 0; fi
  done < <(ancestry "$1" "$2" | tail -n +2)
  [ "$complete" = "1" ] || { printf 'incomplete\n'; return 0; }
  printf 'unknown\n'
}

# ── the incarnation fence, re-read at signal time ─────────────────────────────────────────────────
# The fleet's ONE identity comparison (/proc/<pid>/stat field 22, else `lstart`): a pid recycled
# between the measurement and the signal must never receive it. `lstart` alone is second-resolution
# and cannot separate a same-second recycle, which is why /proc wins where it exists.
pid_ident() { # <pid>
  local pid="$1" st f22
  st="$(cat "${PROC_ROOT:-/proc}/$pid/stat" 2>/dev/null)"
  if [ -n "$st" ]; then
    f22="$(printf '%s' "$st" | sed 's/.*) //' | awk '{print $20}')"
    case "$f22" in ''|*[!0-9]*) ;; *) printf 'proc:%s\n' "$f22"; return 0 ;; esac
  fi
  bound "$READ_TIMEOUT" "$PS_BIN" -p "$pid" -o lstart= 2>/dev/null
}

# pass_expired <deadline> — has this pass spent its budget? (0 = yes)
pass_expired() { [ "$(now_s)" -ge "${1:-0}" ]; }

zombie_count() { # <tablefile> — the box's corpses, so "busy" cannot hide them
  awk -F'\t' '$3 ~ /^Z/ { n++ } END { printf "%d\n", n+0 }' "$1"
}

# ── count: the `[cap]` reading ────────────────────────────────────────────────────────────────────
# `lanes=<live>/<total> zombie=<n>`, or `lanes=?/? zombie=?` with exit 3 when the box could not be
# read. `?` is deliberate: an unreadable `ps` must not render as an empty fleet, because "I could not
# look" and "nothing is there" are the two readings this whole issue conflates.
cmd_count() {
  coerce_limits
  local table roots root live=0 total=0 z live_unknown=0
  local not_lane=0 blind=0 ambiguous=0 attributed=0 unidentifiable=0
  table="$(mktemp "${TMPDIR:-/tmp}/lane-reap-count.XXXXXX")" || return 3
  read_table > "$table"
  if ! table_readable "$table"; then
    rm -f "$table"
    printf 'lanes=?/? zombie=?\n'
    return 3
  fi
  z="$(zombie_count "$table")"
  roots="$(lane_roots "$table")"
  local deadline
  deadline=$(( $(now_s) + 10#$PASS_TIMEOUT ))
  # ⛔ A CENSUS THAT CANNOT SEE A DESCRIPTOR MUST NOT PRINT A NUMBER (#2163 review, P0). The
  # POPULATION comes from the process table, but every lane's LIVENESS comes from a file descriptor it
  # holds. When the box cannot read descriptors at all — no /proc and no `lsof`, `lsof -p` denied,
  # a container whose /proc carries no fds — every tree used to fall out of BOTH `live` and `total`
  # and this printed `lanes=0/0 zombie=N` with exit 0. `orch-loop.sh` reads that as a clean `0`
  # (`LANES_UNKNOWN` stays 0, the `lanes_unknown` refusal never fires, `MAX_LANES` is never reached)
  # and DISPATCHES MORE onto a box whose capacity it cannot see — the #2159 OOM direction.
  if [ -n "$roots" ] && ! instrument_usable "$table" $roots; then
    rm -f "$table"
    printf 'lanes=?/? zombie=%s\n' "$z"
    logline "census-blind — no descriptor of any lane tree could be read (proc_root=${PROC_ROOT:-none} lsof=${LSOF_BIN:-none})"
    return 3
  fi
  for root in $roots; do
    # ⛔ A PARTIAL CENSUS IS NOT A CENSUS. Stopping half-way and printing the lanes seen so far
    # would under-report `total` — the exact direction that hides a leak. Budget spent => `?`, and
    # the caller (which gates dispatch on this) falls back conservatively.
    if pass_expired "$deadline"; then
      rm -f "$table"
      printf 'lanes=?/? zombie=?\n'
      logline "census-budget-expired after ${PASS_TIMEOUT}s"
      return 3
    fi
    # The lane's OWN evidence: its `pi` (the root, or the root's direct `pi` child), plus a
    # pipe-fed `tee` sibling — see resolve_log. The census walks no deeper: it has no CPU gate and
    # no kill loop, so the whole-tree walk (one extra full-table awk per lane, on the every-cycle
    # path) is not done here.
    local logres path del holder age m rc
    logres="$(resolve_log "$table" "$root")"; rc=$?
    case "$rc" in
      0) ;;                                                     # one attributable evidence file
      1) not_lane=$((not_lane + 1)); continue ;;                 # read taken: no fleet log ⇒ not a lane
      # ⛔ A BLIND OR AMBIGUOUS TREE MIGHT BE A LANE, so it cannot be dropped from the census: both
      # the numerator and the total would then be LOWER BOUNDS and the ceiling test would be false —
      # dispatch more onto a box that may be full. It is counted and the census abstains below.
      2) blind=$((blind + 1)); continue ;;
      3) ambiguous=$((ambiguous + 1)); continue ;;
      # ⛔ AN UNUSABLE PIPE IDENTITY IS TAKEN-BUT-UNATTRIBUTABLE, NOT NOT-A-LANE (#2163 review r6,
      # P1). Without this arm the tree fell through to `attributed` with an empty path, the
      # lane-log filter dropped it, and the census printed `lanes=0/0` exit 0 over a resident lane
      # — the fail-open this whole issue closes, reintroduced by the rc-2/rc-4 split.
      4) unidentifiable=$((unidentifiable + 1)); continue ;;
    esac
    attributed=$((attributed + 1))
    path="$(printf '%s' "$logres" | cut -f1)"
    del="$(printf '%s' "$logres" | cut -f2)"
    # ⛔ A WORKER IS NOT A LANE FOR THIS COUNT. `fix-*`/`merge-*`/`chain-*` wrappers are counted by
    # orch-loop's `workers=` and are gated by their own caps; folding them into `lanes=` would make
    # MAX_LANES refuse dispatch for reviewers, a behaviour change this issue does not ask for. They
    # ARE in the reaper's population (a leaked reviewer holds the same memory), which is why the two
    # audiences read the same resolved log and differ only in this filter.
    case "${path##*/}" in L-*.log|lane-*.log) ;; *) continue ;; esac
    total=$((total + 1))
    if [ "$del" = "1" ]; then
      # ⛔ A DELETED LOG IS NOT EVIDENCE THAT THE LANE IS DEAD (#2163 review, P1). The reap pass says
      # the same thing one branch over ("a live lane may have rotated its log"), and `/tmp` pruning
      # does exactly that. For a CAPACITY gate a possibly-live lane must count as live: counting it
      # `0` makes the ceiling test false and DISPATCHES MORE onto a box that may already be full.
      # `total` still shows it as resident, and the reaper's 12h no-log bound decides whether it is.
      live=$((live + 1))
    else
      m="$(mtime_epoch "$path")"
      if is_num "${m:-}"; then
        age=$(( $(now_s) - m ))
        # ⛔ A NEGATIVE AGE IS NOT "NOT LIVE" either (#2163 review, P2): a clock step, `rsync -t` or
        # a snapshot restore puts the mtime in the future. The old `[ "$age" -ge 0 ] &&` guard made
        # the lane vanish from the NUMERATOR without flagging anything, so the output read as a
        # confident `lanes=2/5` instead of the `?` the unreadable-age branch insists on — the same
        # fail-open direction (under-counted live ⇒ ceiling test false ⇒ dispatch more).
        if [ "$age" -lt 0 ]; then
          live_unknown=1
        else
          [ "$age" -le $(( 10#$LIVE_MIN * 60 )) ] && live=$((live + 1))
        fi
      else
        # ⛔ AN UNREADABLE AGE IS NOT "NOT LIVE" (#2163 review, P2). Silently omitting this lane
        # UNDER-COUNTS `live`, which makes the ceiling test false and DISPATCHES MORE — a fail-open
        # in the one direction that fills the box. The NUMERATOR becomes `?`; `live` itself stays a
        # NUMBER so the next lane's `live=$((live + 1))` cannot hit an arithmetic error (the earlier
        # cut assigned the literal `?` and aborted the whole pass on the next readable lane).
        live_unknown=1
      fi
    fi
  done
  rm -f "$table"
  # ⛔ AN UNATTRIBUTABLE TREE ABSTAINS THE WHOLE CENSUS. A tree whose descriptor read failed
  # (`blind`) or that presents two distinct lane logs (`ambiguous`) may be a lane, so `total` is a
  # lower bound as well as `live`; printing the number we happened to reach is the fail-open this
  # fix closes. `zombie=` IS readable and is kept, so the line still says something true.
  if [ "$blind" -gt 0 ] || [ "$ambiguous" -gt 0 ] || [ "$unidentifiable" -gt 0 ]; then
    printf 'lanes=?/? zombie=%s\n' "$z"
    logline "census-abstained blind=$blind ambiguous=$ambiguous unidentifiable=$unidentifiable attributed=$attributed not-a-lane=$not_lane"
    return 3
  fi
  local live_out="$live"
  [ "$live_unknown" = "1" ] && live_out="?"
  printf 'lanes=%s/%d zombie=%d\n' "$live_out" "$total" "$z"
  # A `?` numerator is a PARTIAL answer: the totals are real, but at least one lane's liveness could
  # not be read. Exit 3 so a caller that gates work on this treats it as cannot-verify.
  [ "$live_unknown" = "1" ] && return 3
  return 0
}

# ── reap: three gates, dry run by default ────────────────────────────────────────────────────────
cmd_reap() {
  local apply=0 json=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --apply) apply=1 ;;
      --dry-run) apply=0 ;;
      --json) json=1 ;;
      -h|--help) usage; return 0 ;;
      *) printf '%s: unknown argument %s\n' "$PROG" "$1" >&2; return 2 ;;
    esac
    shift
  done
  coerce_limits

  local t0 t1
  t0="$(mktemp "${TMPDIR:-/tmp}/lane-reap-t0.XXXXXX")" || return 3
  t1="$(mktemp "${TMPDIR:-/tmp}/lane-reap-t1.XXXXXX")" || { rm -f "$t0"; return 3; }
  rm -f "$t1"
  read_table > "$t0"
  if ! table_readable "$t0"; then
    rm -f "$t0"
    printf '%s: CANNOT-VERIFY — the process table could not be read; nothing was judged\n' "$PROG"
    logline "cannot-verify ps-unreadable"
    return 3
  fi

  local now total z roots root verdict logres logpath del holder
  local etime ident_file victims_file candidates=0 reaped=0 refused=0 live=0 abstained=0 inert=0
  local unidentifiable=0
  local inert_human=0 inert_unknown=0
  now="$(now_s)"
  z="$(zombie_count "$t0")"
  roots="$(lane_roots "$t0")"
  total=0
  refused=0
  candidates=0
  ident_file="$(mktemp "${TMPDIR:-/tmp}/lane-reap-ident.XXXXXX")" || { rm -f "$t0"; return 3; }
  victims_file="$(mktemp "${TMPDIR:-/tmp}/lane-reap-victims.XXXXXX")" || {
    rm -f "$t0" "$ident_file"; return 3; }
  : > "$victims_file"

  # Pass 1: resolve every lane's evidence BEFORE sampling, so the CPU window is spent once for the
  # whole population rather than once per lane (a 30s window per lane would make the pass unbounded).
  local cand_file
  cand_file="$(mktemp "${TMPDIR:-/tmp}/lane-reap-cand.XXXXXX")" || { rm -f "$t0" "$ident_file" "$victims_file"; return 3; }
  : > "$cand_file"
  local deadline
  deadline=$(( $(now_s) + 10#$PASS_TIMEOUT ))
  for root in $roots; do
    # The budget is checked BETWEEN lanes and BEFORE any signal: a pass that runs out of time judges
    # nothing further and says so. Acting on evidence it happened to reach while past its budget is
    # how a slow box turns into a reaper that signals in an unbounded window.
    if pass_expired "$deadline"; then
      rm -f "$t0" "$ident_file" "$victims_file" "$cand_file"
      printf '%s: CANNOT-VERIFY — the pass budget (%ss) was spent before the sample; nothing was signalled\n' "$PROG" "$PASS_TIMEOUT"
      logline "cannot-verify pass-budget-expired"
      return 3
    fi
    # The lane's OWN evidence — its `pi`, plus a pipe-fed `tee` sibling (see resolve_log). NOT the
    # root's arbitrary children: a wrapper backgrounding a `fix-*` writer beside the live `pi` used
    # to let the writer's 3 h-old log judge the 30 s-old lane, and `--apply` TERMed the working agent.
    TREE_PIDS="$(tree_pids "$t0" "$root" | cut -f1 | tr '\n' ' ')"
    local rrc
    logres="$(resolve_log "$t0" "$root")"; rrc=$?
    case "$rrc" in
      0) ;;
      1) refused=$((refused + 1))
         printf '  REFUSE root=%s — no-log-evidence (the tree was read and holds no fleet log: not a lane, and never evidence of staleness)\n' "$root"
         continue ;;
      # ⛔ A BLIND READ IS NOT "NO LOG" (#2163 review, P0/P2). The descriptors could not be read at
      # all, so this tree may well be a lane; it is refused AND abstained, because a pass that says
      # `refused=0 reaped=0` over it is indistinguishable from an idle one.
      2) refused=$((refused + 1)); abstained=$((abstained + 1))
         printf '  REFUSE root=%s — log-evidence-unreadable (the descriptors could not be read; a blind read never becomes "stale")\n' "$root"
         continue ;;
      # ⛔ TWO LANE LOGS IN ONE TREE IS AMBIGUITY, NOT A CHOICE (#2163 review, P1). No one of them is
      # this lane's staleness evidence, so judging it is guessing which file is the lane — refuse.
      3) refused=$((refused + 1)); abstained=$((abstained + 1))
         printf '  REFUSE root=%s — ambiguous-log-evidence (the tree holds more than one distinct lane log; none of them is ITS evidence)\n' "$root"
         continue ;;
      # ⛔ AN UNUSABLE PIPE IDENTITY IS NOT A FAILED READ (#2163 review r5, P3). The descriptors
      # were read SUCCESSFULLY; this platform just prints no per-pipe name (lsof 4.95's literal
      # `pipe`, or its unresolved `->0x0`), so a tee beside the tree can be neither accepted (that
      # borrows another pipe's file) nor refused (that drops a real lane's own writer). It is still
      # an ABSTENTION and still exit 3 — but under a cause that NAMES IDENTITY. Sharing rc 2 with a
      # blind read made a mixed box print `log-evidence-unreadable (the descriptors could not be
      # read …)` beside a healthy lane and count it in `abstained=` ("a SAFETY read failed"), so the
      # doctor's `reap FAILED rc=3` pointed the operator at an lsof/permissions fault that did not
      # exist. `unidentifiable=` is that fact, counted beside `inert=` and carried by the exit code.
      4) refused=$((refused + 1)); unidentifiable=$((unidentifiable + 1))
         printf '  REFUSE root=%s — pipe-identity-unusable (the descriptors WERE read; this platform prints no per-pipe name, so a tee beside the tree cannot be shown to be its own writer — and an unusable identity never becomes "stale")\n' "$root"
         continue ;;
    esac
    logpath="$(printf '%s' "$logres" | cut -f1)"
    del="$(printf '%s' "$logres" | cut -f2)"
    holder="$(printf '%s' "$logres" | cut -f3)"
    verdict="$(host_verdict "$t0" "$root")"
    # ⛔ `unknown` AND `incomplete` REFUSE (#2163 review, P1). `unknown` used to PERMIT the kill, so
    # every host app outside the marker set (xterm, wezterm, gnome-terminal-server, konsole, ghostty,
    # foot, VS Code/code-server, a bare screen, a cloud web console with no sshd, a tmux daemonised
    # from init) — and every TRUNCATED process table, whose empty command read as "no marker" — sent
    # TERM to a live tree. A lane is judged only on POSITIVE fleet evidence; anything else is refused.
    case "$verdict" in
      human)
        # ⛔ A POLICY REFUSAL IS NOT AN IDLE PASS (#2163 review r3, P2). `abstained` counts a SAFETY
        # READ that failed; a refusal that DECIDED not to judge is a different fact and used to be
        # counted nowhere, so a pass that judged NOBODY printed `trees=0/0 … refused=1 abstained=0`
        # and exited 0 — a clean bill of health from a reaper that judged nothing at all. `inert=`
        # counts the LANES the policy refused (a resolved lane log, a verdict this tool will not act
        # on), and a pass with zero judged trees is exit 3 (see the summary below).
        refused=$((refused + 1)); inert=$((inert + 1)); inert_human=$((inert_human + 1))
        printf '  REFUSE root=%s log=%s — human-ancestor (the first recognised host app is a human terminal/ssh)\n' "$root" "$logpath"
        continue ;;
      fleet) ;;
      incomplete)
        refused=$((refused + 1)); abstained=$((abstained + 1))
        printf '  REFUSE root=%s log=%s — ancestry-unreadable (the ppid walk lost the chain; an unread table cannot be read as "no human above")\n' "$root" "$logpath"
        continue ;;
      *)
        refused=$((refused + 1)); inert=$((inert + 1)); inert_unknown=$((inert_unknown + 1))
        printf '  REFUSE root=%s log=%s — ancestry-unknown (no positive fleet evidence in the chain; a lane is judged only on a fleet marker)\n' "$root" "$logpath"
        continue ;;
    esac
    # ⛔ THE NO-LOG BOUND IS MEASURED ON THE PROCESS THAT HOLDS THE EVIDENCE (#2163 review r3, P3).
    # `etime` used to be the ROOT's, and on the no-log arm the root is the WRAPPER — so a wrapper up
    # 28 h hosting a `pi` started 10 minutes ago with a rotated (deleted) log satisfied `up>=12h` and
    # was reaped IMMEDIATELY. `holder` is the pid whose descriptor IS the evidence (the lane's `pi`,
    # or its tee); the root is only the fallback for a resolver that reported none.
    etime="$(awk -F'\t' -v r="${holder:-$root}" '$1 == r { print $5 }' "$t0")"
    is_num "${etime:-}" || etime=""
    total=$((total + 1))
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$root" "$logpath" "$del" "$verdict" "${etime:-}" "$TREE_PIDS" >> "$cand_file"
    for p in $TREE_PIDS; do
      printf '%s\t%s\n' "$p" "$(pid_ident "$p")" >> "$ident_file"
    done
  done
  # A budget already spent before the window would make the second snapshot meaningless, and the
  # window itself is the largest single cost of the pass.
  if pass_expired "$deadline"; then
    rm -f "$t0" "$ident_file" "$victims_file" "$cand_file"
    printf '%s: CANNOT-VERIFY — the pass budget (%ss) was spent before the CPU window; nothing was signalled\n' "$PROG" "$PASS_TIMEOUT"
    logline "cannot-verify pass-budget-expired-before-window"
    return 3
  fi
  # One real window, then the second snapshot.
  "$SLEEP_BIN" "$WINDOW"
  read_table > "$t1"
  if ! table_readable "$t1"; then
    rm -f "$t0" "$t1" "$ident_file" "$victims_file" "$cand_file"
    printf '%s: CANNOT-VERIFY — the second process read failed; no lane was judged and NOTHING was signalled\n' "$PROG"
    logline "cannot-verify ps-unreadable-second"
    return 3
  fi

  local active=0
  while IFS=$'\t' read -r root logpath del verdict etime tree; do
    [ -n "${root:-}" ] || continue
    # composition must not have changed across the window: a child born or gone is a lane doing
    # something (or being replaced), and a single window cannot tell that from a freeze.
    local now_pids
    now_pids="$(tree_pids "$t1" "$root" | cut -f1 | sort -n | tr '\n' ' ')"
    local old_sorted new_sorted
    old_sorted="$(printf '%s\n' $tree | sort -n | tr '\n' ' ')"
    new_sorted="$(printf '%s\n' $now_pids | sort -n | tr '\n' ' ')"
    if [ "$old_sorted" != "$new_sorted" ]; then
      printf '  SKIP   root=%s log=%s — subtree-changed during the window (it is doing something)\n' "$root" "$logpath"
      continue
    fi
    local u_cpu0 u_cpu1 dcs
    u_cpu0="$(cpu_sum_cs "$t0" <(printf '%s\n' $tree))"
    u_cpu1="$(cpu_sum_cs "$t1" <(printf '%s\n' $tree))"
    dcs=$(( u_cpu1 - u_cpu0 ))
    # ⛔ A NEGATIVE DELTA IS NOT "PARKED" (#2163 review, P1). The composition check above just
    # proved this subtree is byte-identical across the window, so its CPU total CANNOT go
    # backwards; a negative delta means one of the two reads was incomplete (a truncated `ps`,
    # a root row that vanished mid-stream, which `tree_pids` prints as an unchanged single pid).
    # Treating that as "cpu unchanged" hands the decision to the idle-log gate alone and TERMs a
    # lane that may be working — the reading is broken, so the answer is an abstention, never
    # the code's most permissive value.
    if [ "$dcs" -lt 0 ]; then
      printf '  SKIP   root=%s log=%s — cpu-unreadable (delta %dcs across the window; a stable subtree cannot lose CPU)\n' \
        "$root" "$logpath" "$dcs"
      abstained=$((abstained + 1))
      continue
    fi
    if [ "$dcs" -gt "$CPU_TOL_CS" ]; then
      printf '  SKIP   root=%s log=%s — still working (cpu %d.%02ds over %ss)\n' \
        "$root" "$logpath" "$((dcs / 100))" "$((dcs % 100))" "$WINDOW"
      continue
    fi
    # Gate 3. An unreadable age aborts the lane's judgement (abstain), never "old enough".
    # ⛔ AN ABSTENTION IS NOT AN IDLE PASS (#2163 review, P2): each of these branches used to leave
    # every counter untouched, so a pass that could judge NOTHING reported `reaped=0 refused=0` and
    # exited 0 — `cloud-cell-doctor.sh` only escalates on a literal `CANNOT-VERIFY`, so a silently
    # abstaining reaper was indistinguishable from an idle one.
    local stale_reason="" age
    if [ "$del" = "1" ]; then
      if ! is_num "${etime:-}"; then
        printf '  SKIP   root=%s log=%s — no-log-age-unreadable (cannot judge; never reap on a guess)\n' "$root" "$logpath"
        abstained=$((abstained + 1))
        continue
      fi
      age="$etime"
      if [ "$age" -ge $(( 10#$NO_LOG_H * 3600 )) ]; then
        stale_reason="no-log up=${age}s>=$(( 10#$NO_LOG_H * 3600 ))s"
      else
        printf '  SKIP   root=%s log=%s (deleted) — no-log up=%ss under %sh (conservative: a live lane may have rotated its log)\n' \
          "$root" "$logpath" "$age" "$NO_LOG_H"
        continue
      fi
    else
      local m
      m="$(mtime_epoch "$logpath")"
      if ! is_num "${m:-}"; then
        printf '  SKIP   root=%s log=%s — log-age-unreadable (cannot judge; never reap on a guess)\n' "$root" "$logpath"
        abstained=$((abstained + 1))
        continue
      fi
      age=$(( now - m ))
      if [ "$age" -ge $(( 10#$LANE_IDLE_MIN * 60 )) ]; then
        stale_reason="log-idle=${age}s>=$(( 10#$LANE_IDLE_MIN * 60 ))s"
      else
        printf '  SKIP   root=%s log=%s — log advanced %ss ago (under %sm)\n' "$root" "$logpath" "$age" "$LANE_IDLE_MIN"
        continue
      fi
    fi
    candidates=$((candidates + 1))
    if [ "$apply" = "0" ]; then
      printf '  WOULD REAP root=%s log=%s pids=%s — %s, cpu unchanged (%ss window), %s ancestry\n' \
        "$root" "$logpath" "$(printf '%s' "$tree" | tr ' ' ',')" "$stale_reason" "$WINDOW" "$verdict"
      continue
    fi
    # ── act ─────────────────────────────────────────────────────────────────────────────────────
    # Deepest first (children before parents) so nothing is reparented mid-kill; each victim is
    # re-fenced at signal time against the incarnation measured in the SAME snapshot as its CPU.
    local depth pid wanted got signalled=0
    while IFS=$'\t' read -r pid depth; do
      case " $tree " in *" $pid "*) ;; *) continue ;; esac
      wanted="$(awk -F'\t' -v p="$pid" '$1 == p { print $2 }' "$ident_file" | head -1)"
      got="$(pid_ident "$pid")"
      if [ -z "$wanted" ] || [ "$wanted" != "$got" ]; then
        printf '  FENCE-ABSTAIN pid=%s — incarnation changed between measurement and signal (NOT signalled)\n' "$pid"
        continue
      fi
      "$KILL_BIN" -TERM "$pid" 2>/dev/null || true
      printf '%s\n' "$pid" >> "$victims_file"
      signalled=$((signalled + 1))
    done < <(tree_pids "$t1" "$root" | sort -k2 -r -n)
    # ⛔ A CANDIDATE THAT SIGNALLED NOTHING IS NOT "REAPED" (#2163 review, P2). Every victim can
    # abstain on the fence (a recycled pid), and the summary then said `reaped=1` over a lane that
    # is still running — the operator's only evidence of what happened, wrong in the safe direction
    # but wrong. The lane is reported as fence-abstained and NOT counted.
    if [ "$signalled" -gt 0 ]; then
      printf '  REAP   root=%s log=%s — %s, cpu unchanged (%ss window), %s ancestry\n' \
        "$root" "$logpath" "$stale_reason" "$WINDOW" "$verdict"
      reaped=$((reaped + 1))
    else
      printf '  SKIP   root=%s log=%s — fence-abstained (no victim still held its measured incarnation; nothing was signalled)\n' \
        "$root" "$logpath"
      abstained=$((abstained + 1))
    fi
  done < "$cand_file"

  if [ "$apply" = "1" ] && [ -s "$victims_file" ]; then
    "$SLEEP_BIN" 1
    local v
    while read -r v; do
      is_num "$v" || continue
      local w g
      w="$(awk -F'\t' -v p="$v" '$1 == p { print $2 }' "$ident_file" | head -1)"
      g="$(pid_ident "$v")"
      if [ -n "$w" ] && [ "$w" = "$g" ]; then
        "$KILL_BIN" -KILL "$v" 2>/dev/null || true
        printf '  KILL   pid=%s — survived TERM after 1s (same incarnation)\n' "$v"
      fi
    done < "$victims_file"
  fi

  # ⛔ `trees=<working>/<judged>` MUST ACCOUNT FOR EVERY JUDGED TREE (#2163 review, P3). `live` was
  # incremented only for a CPU delta above the tolerance or a log younger than `LIVE_MIN`, so a lane
  # idle between 45 m and 2 h, or one that abstained, counted as NEITHER working nor a candidate and
  # `trees=` silently under-reported the box. A judged tree is working unless it is a candidate: the
  # arithmetic below cannot drift from the branches above.
  live=$((total - candidates))
  [ "$live" -lt 0 ] && live=0
  if [ "$json" = "1" ]; then
    printf '{"trees":"%d/%d","zombie":%d,"candidates":%d,"reaped":%d,"refused":%d,"inert":%d,"unidentifiable":%d,"abstained":%d,"apply":%s}\n' \
      "$live" "$total" "$z" "$candidates" "$reaped" "$refused" "$inert" "$unidentifiable" "$abstained" "$([ "$apply" = "1" ] && echo true || echo false)"
  else
    # `trees=<working>/<judged>` — deliberately NOT `lanes=`: this pass judges every fleet tree
    # (`lane-`, `L-`, `fix-`, `merge-`, `chain-`), while `count`'s `lanes=` is the lane census only.
    # Two audiences, two honest labels; a shared one would make the numbers look like a disagreement.
    # `refused` = never judged (no/unreadable/ambiguous evidence, or a human/unknown ancestry).
    # `abstained` = a SAFETY read failed, so no verdict could be taken (a subset of `refused` for
    # evidence/ancestry, a subset of `live` for the CPU and age gates). Non-zero ⇒ exit 3.
    # `inert` = the subset of `refused` that is a POLICY decision over a REAL lane (a resolved lane
    # log with a human or unclassifiable ancestry). It is the field that makes "this reaper judged
    # nothing" sayable: `trees=0/0 refused=1 abstained=0` used to be a clean pass.
    # `unidentifiable` = the subset of `refused` whose reads SUCCEEDED but whose pipe has no per-pipe
    # name on this platform, so a tee's identity could not be compared (`pipe-identity-unusable`).
    # An abstention, so it exits 3 — but NOT `abstained=`, which stays reserved for a read that
    # failed; the two causes need different fixes, so a shared field would name the wrong one.
    printf '%s: trees=%d/%d zombie=%d candidates=%d reaped=%d refused=%d inert=%d unidentifiable=%d abstained=%d mode=%s\n' \
      "$PROG" "$live" "$total" "$z" "$candidates" "$reaped" "$refused" "$inert" "$unidentifiable" "$abstained" \
      "$([ "$apply" = "1" ] && echo apply || echo dry-run)"
  fi
  logline "pass trees=$live/$total zombie=$z candidates=$candidates reaped=$reaped refused=$refused inert=$inert unidentifiable=$unidentifiable (human=$inert_human unknown=$inert_unknown) abstained=$abstained mode=$([ "$apply" = "1" ] && echo apply || echo dry-run)"
  rm -f "$t0" "$t1" "$ident_file" "$victims_file" "$cand_file"
  # ⛔ A PASS THAT COULD NOT JUDGE AT LEAST ONE TREE IS NOT A CLEAN PASS (#2163 review, P2). The
  # human line and `--json` both carry `abstained=`, and the EXIT CODE says it too so a consumer that
  # never parses the line cannot read an abstention as `reaped=0` means idle.
  [ "$abstained" -gt 0 ] && return 3
  # …AND SO IS AN UNUSABLE PIPE IDENTITY (#2163 review r5, P3). It is a tree the pass could not
  # judge, so it must never read as idle — but it says so through its OWN field, because the fix an
  # operator needs (a platform that names a pipe) is not the fix an `abstained` needs (a read that
  # failed).
  [ "$unidentifiable" -gt 0 ] && return 3
  # ⛔ …AND NEITHER IS A PASS THAT REFUSED EVERY LANE IT FOUND (#2163 review r3, P2). On a cell every
  # lane is `ancestry-unknown`, so the armed pass judged ZERO trees while refusing all of them and
  # exited 0; `cloud-cell-doctor.sh` recorded `state_write reap 0` — a healthy reaper, every pass,
  # from an instrument that is inert there by design. A pass that judged nothing while refusing a
  # real lane is not a clean pass, and it says so.
  # ⛔ BUT IT IS NOT `3` (#2163 review r8, P1). `3` means CANNOT-VERIFY — a read that failed, which a
  # consumer must escalate — and on a LINUX CELL this shape is the STEADY STATE, not an incident: the
  # only fleet marker is `cmux.app`, so every cell lane is `ancestry-unknown` and refused, every
  # pass. Reporting cannot-verify there made the cell's health verb red for ever, and made a REAL
  # cannot-verify (and a failed controller restart beside it) indistinguishable from a policy verdict
  # nobody can act on. `4` is its own verdict: the pass COMPLETED and JUDGED NOTHING because the
  # policy refused the whole population — named, counted, and never folded into a failure.
  if [ "$total" -eq 0 ] && [ "$inert" -gt 0 ]; then
    logline "inert-pass — judged no tree and refused $inert lane(s) by policy"
    return 4
  fi
  return 0
}

usage() {
  cat <<'EOF'
lane-reap.sh — count fleet lanes by evidence, and reap the ones that provably finished (#2163).

  lane-reap.sh count                 print `lanes=<live>/<total> zombie=<n>` (exit 3 = cannot-verify: unreadable, ambiguous, or an
                                              unidentifiable pipe identity — see the header)
  lane-reap.sh reap [--dry-run]      report what WOULD be reaped (the default)
  lane-reap.sh reap --apply          signal the lanes that pass all three gates
  lane-reap.sh reap --json           one machine-readable summary line

exit codes for `reap`: 0 = a pass that completed (including one that judged lanes and refused some by
policy); 3 = cannot-verify (a read failed, so the pass could not judge — never a clean pass);
4 = policy-inert (the pass COMPLETED and judged NO tree because the policy refused every lane it
found — the Linux-cell steady state, named apart from 3 so a consumer can report it without calling a
working policy a failure).

A lane is a `pi` process tree (the pi and its immediate shell wrapper) whose OWN pi — or a pipe-fed
`tee` beside it — holds a fleet-namespace log open as stdout/stderr. It is reaped only when ALL
hold: zero CPU delta over the sample window summed over the whole tree; POSITIVE fleet ancestry
(`cmux.app` today — a human terminal/ssh ancestor refuses, and so does an ancestry that is neither,
which makes the armed reaper inert on a systemd-scoped cell); and either its log is untouched past
LANE_REAP_IDLE_MIN (2h) or it has no log and has been up past LANE_REAP_NO_LOG_H (12h). A log that
cannot be resolved is `no-log-evidence`, and one that cannot be READ is `log-evidence-unreadable`:
both are refused, never read as staleness. A tree that presents two distinct lane logs is
`ambiguous-log-evidence` — refused, because no one of them is that tree's evidence. A tree whose
descriptors were read but whose pipe has no per-pipe name on this platform (so a tee beside it cannot
be shown to be its writer) is `pipe-identity-unusable` — also refused, and NOT a read failure.

The summary's `abstained=<n>` counts trees whose SAFETY read failed (descriptors, ancestry, CPU
delta, log age); a pass with any abstention exits 3, so an abstaining pass never reads as idle.
`inert=<n>` counts the LANES a POLICY refused (a resolved lane log under a human or unclassifiable
ancestry): a pass that judged NO tree while refusing some of them exits 4 too, because a reaper that
judged nothing is not a clean pass — but 4 is a POLICY verdict over a population this tool will not
judge (the Linux-cell steady state), kept apart from 3 (a read that FAILED) so a consumer is never
forced to report a permanent red it cannot act on. `unidentifiable=<n>` counts the trees refused
because a pipe has no per-pipe name on this platform: an abstention (exit 3), counted apart from
`abstained=` so an operator is never sent after a blind read that did not happen.
EOF
}

# ── the single-run lock ──────────────────────────────────────────────────────────────────────────
# Two concurrent passes would sample the same lanes and could both believe a subtree parked. The
# lock is held for the whole pass; a killed pass releases it with the process. An UNOPENABLE lock is
# an environmental failure and says so — it must not read as "nothing to do" (the inert-reaper
# shape). Bash 3.2 has no flock(1); `mkdir` is the atomic primitive.
acquire_lock() {
  local d holder
  d="$(dirname "$LOCK")"
  [ -d "$d" ] || mkdir -p "$d" 2>/dev/null || return 2
  if ! mkdir "$LOCK.d" 2>/dev/null; then
    # ⛔ A LOCK LEFT BY A KILLED PASS MUST NOT DISARM THE REAPER FOR EVER. A stale flag that is
    # never revalidated is the "process problem is yours to fix" class: the holder pid is re-read
    # and, when it is gone, the directory is reclaimed. An UNREADABLE holder is NOT proof of death.
    holder="$(cat "$LOCK.d/pid" 2>/dev/null)"
    if is_num "${holder:-}" && [ "$holder" -gt 0 ] && kill -0 "$holder" 2>/dev/null; then
      # A live pid is necessary but NOT sufficient: a lock left behind by a killed pass names a pid
      # that the kernel may since have recycled, and "a process with that pid exists" would then
      # hold the lock for ever (the stale-flag class). The holder must still BE this tool.
      # An UNREADABLE holder read is HELD (fail closed): reclaiming on a read we could not take
      # would put two passes on one population for the sake of an instrument failure.
      local hargs
      hargs="$(bound "$READ_TIMEOUT" "$PS_BIN" -p "$holder" -o args= 2>/dev/null)"
      case "$hargs" in
        '') return 1 ;;
        *lane-reap.sh*|*"$PROG"*) return 1 ;;
      esac
    elif [ -z "${holder:-}" ] || ! is_num "${holder:-}"; then
      # ⛔ AN ABSENT pid FILE IS NOT A STALE LOCK (#2163 review, P2). There is a real window between
      # `mkdir` and the pid write below (and a pass SIGKILLed inside it leaves the same state), so
      # treating "no pid" as reclaimable let TWO passes sample one population — each then deleting
      # the OTHER's lock through the EXIT trap, which admits a third. A lock dir whose age we cannot
      # even read is HELD (the read is the instrument failure, not the evidence).
      local lockm lm_age
      lockm="$(mtime_epoch "$LOCK.d")"
      if ! is_num "${lockm:-}"; then return 1; fi
      lm_age=$(( $(now_s) - lockm ))
      # Younger than one read bound: the holder is still writing its pid. Older: a killed pass.
      [ "$lm_age" -lt $(( 10#$READ_TIMEOUT * 2 )) ] && return 1
    fi
    rm -rf "$LOCK.d" 2>/dev/null || return 1
    mkdir "$LOCK.d" 2>/dev/null || return 1
  fi
  printf '%s\n' "$$" > "$LOCK.d/pid" 2>/dev/null || true
  trap 'rm -rf "'"$LOCK"'.d" 2>/dev/null || true' EXIT
  return 0
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    count) shift; cmd_count "$@" ;;
    reap)
      shift
      local lk; acquire_lock; lk=$?
      if [ "$lk" = "1" ]; then
        printf '%s: skipped — another pass holds %s.d\n' "$PROG" "$LOCK"
        return 0
      elif [ "$lk" = "2" ]; then
        printf '%s: LOCK UNAVAILABLE — %s could not be created; the pass did NOT run\n' "$PROG" "$LOCK" >&2
        logline "lock-unavailable"
        return 3
      fi
      cmd_reap "$@" ;;
    -h|--help|help|"") usage; [ -z "$cmd" ] && return 2 || return 0 ;;
    *) printf '%s: unknown command %s\n' "$PROG" "$cmd" >&2; usage >&2; return 2 ;;
  esac
}

main "$@"
