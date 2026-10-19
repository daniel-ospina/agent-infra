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
#   2. NO HUMAN ANCESTOR. Walked nearest-first: the FIRST recognised host application decides.
#      `Terminal.app`/`iTerm`/`Warp`/`kitty`/`Alacritty`/a `sshd` session means the process belongs
#      to a HUMAN and is never touched, however parked. `ppid 1` proves nothing (a daemonising
#      service reparents to 1 BY DESIGN). `login`/`zsh` alone are NOT human: every cmux lane is
#      `pi → -zsh → login → cmux.app`, so treating them as human would make the reaper inert.
#   3. A STALENESS CLASSIFICATION, from a file the process ITSELF holds open:
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
# `pi`), which is a lane-killer. The tree is identified by POSITIVE evidence: one of its processes
# holds a fleet-namespace log (`L-*.log`, `lane-*.log`, `fix-*.log`, `merge-*.log`, `chain-*.log`)
# as stdout/stderr. An interactive `pi` (fds on a tty/socket) is not in the population at all.
#
# WHAT THIS DOES NOT COVER (stated, not silently trusted):
#   * the owner's own interactive `pi` INSIDE cmux with stdout redirected to a lane-shaped log —
#     cmux-rooted ancestry does not by itself separate it from a fleet lane (the residual #1207 and
#     #1244 both name). Mitigated by the zero-CPU window AND the 2h log-idle proof, and reported
#     per lane in the dry run so a human can see it before arming.
#   * a lane whose log was deleted AND whose age is under 12h is REPORTED, not reaped — that is the
#     conservative side of the trap above, and it is why the measured reap population is old lanes.
#   * `--apply` is DRY RUN by default. Arming is a deliberate operator action, same as every other
#     deletion tool in this tree.
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
#   LANE_REAP_LIVE_MIN     log-advanced window that makes a lane LIVE, minutes (default 30)
#   LANE_REAP_LOG          durable pass log (default ~/.pi/agent/state/lane-reap.log)
#   LANE_REAP_LOCK         single-run lock (default ~/.pi/agent/state/lane-reap.lock)
#   LANE_REAP_READ_TIMEOUT bound for one external read, seconds (default 60)
set -u

PROG="lane-reap"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PS_BIN="${LANE_REAP_PS_BIN:-ps}"
SLEEP_BIN="${LANE_REAP_SLEEP_BIN:-sleep}"
KILL_BIN="${LANE_REAP_KILL_BIN:-kill}"
LSOF_BIN="${LANE_REAP_LSOF_BIN:-lsof}"
PROC_ROOT="${LANE_REAP_PROC_ROOT:-/proc}"
WINDOW="${LANE_REAP_WINDOW:-30}"
CPU_TOL_CS="${LANE_REAP_CPU_TOL_CS:-10}"
IDLE_MIN="${LANE_REAP_IDLE_MIN:-120}"
NO_LOG_H="${LANE_REAP_NO_LOG_H:-12}"
LIVE_MIN="${LANE_REAP_LIVE_MIN:-30}"
READ_TIMEOUT="${LANE_REAP_READ_TIMEOUT:-60}"
LOG="${LANE_REAP_LOG:-${HOME:-/tmp}/.pi/agent/state/lane-reap.log}"
LOCK="${LANE_REAP_LOCK:-${HOME:-/tmp}/.pi/agent/state/lane-reap.lock}"

is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
now_s() { if is_num "${LANE_REAP_NOW:-}"; then printf '%s' "$LANE_REAP_NOW"; else date +%s; fi; }

# The numeric seams, coerced ONCE for both audiences. A non-number either aborts the arithmetic under
# `set -u` or silently disables the bound it configures; both are fail-open on a gate. Repair to the
# documented default (fail CLOSED: the bound is restored, not removed).
coerce_limits() {
  for _v in WINDOW CPU_TOL_CS IDLE_MIN NO_LOG_H LIVE_MIN; do
    case "$_v" in
      WINDOW)     is_num "${WINDOW:-}"     || WINDOW=30 ;;
      CPU_TOL_CS) is_num "${CPU_TOL_CS:-}" || CPU_TOL_CS=10 ;;
      IDLE_MIN)   is_num "${IDLE_MIN:-}"   || IDLE_MIN=120 ;;
      NO_LOG_H)   is_num "${NO_LOG_H:-}"   || NO_LOG_H=12 ;;
      LIVE_MIN)   is_num "${LIVE_MIN:-}"   || LIVE_MIN=30 ;;
    esac
  done
}

# Bound ONE external read. `timeout`/`gtimeout` when present; an absent one must not silently drop
# the bound, but it also must not stop the pass on a platform that ships neither — the read is then
# unbounded and the caller's own budget is the only guard (stated, not implied).
bound() { # bound <seconds> <cmd...>
  local s="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"; return $?; fi
  if command -v gtimeout >/dev/null 2>&1; then gtimeout "$s" "$@"; return $?; fi
  "$@"
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

ancestry() { # <tablefile> <pid> -> "pid<TAB>cmd" nearest first, bounded
  awk -F'\t' -v start="$2" '
    { pp[$1] = $2; cm[$1] = $6 }
    END {
      p = start
      for (i = 0; i < 64 && p != "" && p != 0; i++) {
        print p "\t" cm[p]
        if (p == 1) break
        p = pp[p]
      }
    }' "$1"
}

# ── the log the process itself holds open (kernel evidence, never a parsed slug) ──────────────────
# Accepted names are the fleet's own log namespace. The DIRECTORY does not matter: what matters is
# that this process has that file open as stdout/stderr, which an interactive session does not.
is_lane_log_name() {
  case "${1:-}" in
    L-*.log|lane-*.log|fix-*.log|merge-*.log|chain-*.log) return 0 ;;
  esac
  return 1
}

# _log_candidate <path> <pid> — the ONE place a descriptor becomes a lane-log candidate.
# Returns 0 and echoes "path<TAB>deleted<TAB>holder_pid" when it is one; 1 otherwise.
_log_candidate() {
  local path="${1:-}" pid="${2:-}" del=0
  [ -n "$path" ] || return 1
  case "$path" in *" (deleted)") del=1; path="${path% (deleted)}" ;; esac
  is_lane_log_name "${path##*/}" || return 1
  printf '%s\t%s\t%s\n' "$path" "$del" "$pid"
  return 0
}

# resolve_log <root> — TREE_PIDS is the global pid list. Echoes "path<TAB>deleted<TAB>holder_pid".
#
# ⛔ THE KERNEL IS THE SOURCE, NOT THE COMMAND LINE. On Linux `/proc/<pid>/fd/{1,2}` is read
# directly; where /proc is absent (macOS) ONE `lsof` per process answers BOTH descriptors. That
# one-call-per-process shape is not a micro-optimisation: `count` runs every controller cycle, and
# the measured box had ~76 lane roots — two lsof forks each is a pass that outlives the cycle.
resolve_log() {
  local p fd path found
  for p in $TREE_PIDS; do
    found=""
    if [ -n "$PROC_ROOT" ] && [ -d "$PROC_ROOT/$p/fd" ]; then
      for fd in 1 2; do
        path="$(readlink "$PROC_ROOT/$p/fd/$fd" 2>/dev/null)" || continue
        if found="$(_log_candidate "$path" "$p")"; then printf '%s' "$found"; return 0; fi
      done
    elif [ -n "$LSOF_BIN" ] && command -v "$LSOF_BIN" >/dev/null 2>&1; then
      while IFS= read -r path; do
        if found="$(_log_candidate "$path" "$p")"; then printf '%s' "$found"; return 0; fi
      done < <(bound "$READ_TIMEOUT" "$LSOF_BIN" -n -P -a -p "$p" -d 1,2 -Fn 2>/dev/null \
               | sed -n 's/^n//p')
    fi
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
# Returns: human | fleet | unknown. `human` is a hard refusal. `unknown` is acceptable ONLY because
# the population already requires positive in-tree evidence (the fleet log held open).
host_verdict() { # <tablefile> <pid>
  local apid acmd low
  while IFS=$'\t' read -r apid acmd; do
    low="$(printf '%s' "$acmd" | tr '[:upper:]' '[:lower:]')"
    case "$low" in
      *terminal.app*|*iterm*|*warp.app*|*kitty.app*|*alacritty.app*|*hyper.app*|*sshd*)
        printf 'human\n'; return 0 ;;
      *cmux.app*|*cmuxterm*)
        printf 'fleet\n'; return 0 ;;
    esac
  done < <(ancestry "$1" "$2")
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

zombie_count() { # <tablefile> — the box's corpses, so "busy" cannot hide them
  awk -F'\t' '$3 ~ /^Z/ { n++ } END { printf "%d\n", n+0 }' "$1"
}

# ── count: the `[cap]` reading ────────────────────────────────────────────────────────────────────
# `lanes=<live>/<total> zombie=<n>`, or `lanes=?/? zombie=?` with exit 3 when the box could not be
# read. `?` is deliberate: an unreadable `ps` must not render as an empty fleet, because "I could not
# look" and "nothing is there" are the two readings this whole issue conflates.
cmd_count() {
  coerce_limits
  local table roots root live=0 total=0 z
  table="$(mktemp "${TMPDIR:-/tmp}/lane-reap-count.XXXXXX")" || return 3
  read_table > "$table"
  if ! table_readable "$table"; then
    rm -f "$table"
    printf 'lanes=?/? zombie=?\n'
    return 3
  fi
  z="$(zombie_count "$table")"
  roots="$(lane_roots "$table")"
  for root in $roots; do
    TREE_PIDS="$(tree_pids "$table" "$root" | cut -f1 | tr '\n' ' ')"
    local resolved path del holder age m
    resolved="$(resolve_log "$root")" || continue   # no fleet log → not a lane (a subagent/tool pi)
    path="$(printf '%s' "$resolved" | cut -f1)"
    del="$(printf '%s' "$resolved" | cut -f2)"
    # ⛔ A WORKER IS NOT A LANE FOR THIS COUNT. `fix-*`/`merge-*`/`chain-*` wrappers are counted by
    # orch-loop's `workers=` and are gated by their own caps; folding them into `lanes=` would make
    # MAX_LANES refuse dispatch for reviewers, a behaviour change this issue does not ask for. They
    # ARE in the reaper's population (a leaked reviewer holds the same memory), which is why the two
    # audiences read the same resolved log and differ only in this filter.
    case "${path##*/}" in L-*.log|lane-*.log) ;; *) continue ;; esac
    total=$((total + 1))
    if [ "$del" = "0" ]; then
      m="$(mtime_epoch "$path")"
      if is_num "${m:-}"; then
        age=$(( $(now_s) - m ))
        [ "$age" -ge 0 ] && [ "$age" -le $(( 10#$LIVE_MIN * 60 )) ] && live=$((live + 1))
      fi
    fi
  done
  rm -f "$table"
  printf 'lanes=%d/%d zombie=%d\n' "$live" "$total" "$z"
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
  local etime ident_file victims_file candidates=0 reaped=0 refused=0 live=0
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
  for root in $roots; do
    TREE_PIDS="$(tree_pids "$t0" "$root" | cut -f1 | tr '\n' ' ')"
    logres="$(resolve_log "$root")" || {
      refused=$((refused + 1))
      printf '  REFUSE root=%s — no-log-evidence (not a lane, or the log cannot be resolved; never evidence of staleness)\n' "$root"
      continue
    }
    logpath="$(printf '%s' "$logres" | cut -f1)"
    del="$(printf '%s' "$logres" | cut -f2)"
    holder="$(printf '%s' "$logres" | cut -f3)"
    verdict="$(host_verdict "$t0" "$root")"
    if [ "$verdict" = "human" ]; then
      refused=$((refused + 1))
      printf '  REFUSE root=%s log=%s — human-ancestor (the first recognised host app is a human terminal/ssh)\n' "$root" "$logpath"
      continue
    fi
    etime="$(awk -F'\t' -v r="$root" '$1 == r { print $5 }' "$t0")"
    is_num "${etime:-}" || etime=""
    total=$((total + 1))
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$root" "$logpath" "$del" "$verdict" "${etime:-}" "$TREE_PIDS" >> "$cand_file"
    for p in $TREE_PIDS; do
      printf '%s\t%s\n' "$p" "$(pid_ident "$p")" >> "$ident_file"
    done
  done
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
    if [ "$dcs" -gt "$CPU_TOL_CS" ]; then
      printf '  SKIP   root=%s log=%s — still working (cpu %d.%02ds over %ss)\n' \
        "$root" "$logpath" "$((dcs / 100))" "$((dcs % 100))" "$WINDOW"
      live=$((live + 1))
      continue
    fi
    # Gate 3. An unreadable age aborts the lane's judgement (abstain), never "old enough".
    local stale_reason="" age
    if [ "$del" = "1" ]; then
      if ! is_num "${etime:-}"; then
        printf '  SKIP   root=%s log=%s — no-log-age-unreadable (cannot judge; never reap on a guess)\n' "$root" "$logpath"
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
        continue
      fi
      age=$(( now - m ))
      if [ "$age" -ge $(( 10#$IDLE_MIN * 60 )) ]; then
        stale_reason="log-idle=${age}s>=$(( 10#$IDLE_MIN * 60 ))s"
      else
        printf '  SKIP   root=%s log=%s — log advanced %ss ago (under %sm)\n' "$root" "$logpath" "$age" "$IDLE_MIN"
        [ "$age" -le $(( 10#$LIVE_MIN * 60 )) ] && live=$((live + 1))
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
    local depth pid wanted got
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
    done < <(tree_pids "$t1" "$root" | sort -k2 -r -n)
    printf '  REAP   root=%s log=%s — %s, cpu unchanged (%ss window), %s ancestry\n' \
      "$root" "$logpath" "$stale_reason" "$WINDOW" "$verdict"
    reaped=$((reaped + 1))
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

  if [ "$json" = "1" ]; then
    printf '{"trees":"%d/%d","zombie":%d,"candidates":%d,"reaped":%d,"refused":%d,"apply":%s}\n' \
      "$live" "$total" "$z" "$candidates" "$reaped" "$refused" "$([ "$apply" = "1" ] && echo true || echo false)"
  else
    # `trees=<working>/<judged>` — deliberately NOT `lanes=`: this pass judges every fleet tree
    # (`lane-`, `L-`, `fix-`, `merge-`, `chain-`), while `count`'s `lanes=` is the lane census only.
    # Two audiences, two honest labels; a shared one would make the numbers look like a disagreement.
    printf '%s: trees=%d/%d zombie=%d candidates=%d reaped=%d refused=%d mode=%s\n' \
      "$PROG" "$live" "$total" "$z" "$candidates" "$reaped" "$refused" \
      "$([ "$apply" = "1" ] && echo apply || echo dry-run)"
  fi
  logline "pass trees=$live/$total zombie=$z candidates=$candidates reaped=$reaped refused=$refused mode=$([ "$apply" = "1" ] && echo apply || echo dry-run)"
  rm -f "$t0" "$t1" "$ident_file" "$victims_file" "$cand_file"
  return 0
}

usage() {
  cat <<'EOF'
lane-reap.sh — count fleet lanes by evidence, and reap the ones that provably finished (#2163).

  lane-reap.sh count                 print `lanes=<live>/<total> zombie=<n>` (exit 3 = unreadable)
  lane-reap.sh reap [--dry-run]      report what WOULD be reaped (the default)
  lane-reap.sh reap --apply          signal the lanes that pass all three gates
  lane-reap.sh reap --json           one machine-readable summary line

A lane is a `pi` process tree (the pi and its immediate shell wrapper) holding a fleet-namespace
log open as stdout/stderr. It is reaped only when ALL hold: zero CPU delta over the sample window
summed over the whole tree; no human terminal/ssh ancestor; and either its log is untouched past
LANE_REAP_IDLE_MIN (2h) or it has no log and has been up past LANE_REAP_NO_LOG_H (12h). An
unresolvable log is `no-log-evidence`: refused, never read as staleness.
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
