#!/bin/bash
# lane-census.sh — the fleet's OCCUPANCY from cheap primitives (agent-infra#2095).
#
# ── WHY THIS FILE EXISTS, MEASURED ───────────────────────────────────────────────────────────────
# The controller's lane count was `tmux ls | grep -c '^lane-'`. Measured on the live box while the
# queue sat undrained:
#
#     [cap] load=158/100 lanes=0/25 …          <- the count the gate used
#     48-50 live `pi --model` processes        <- the fleet as it actually was
#
# A session NAME is a convention. Any lane not started through that exact naming is invisible, so the
# controller believed it had 25 free slots on a box thrashing at load 170 with swap at 12.4 GB of
# 13.3 GB. It is wrong in BOTH directions: it also counts a lane session whose process has died.
#
# ── WHAT IT ANSWERS, FROM WHAT ──────────────────────────────────────────────────────────────────
# Two INDEPENDENT observations, reported separately and never merged silently:
#
#   1. LIVE PROCESSES. Every live `pi` process's cwd is read in ONE bounded call (`lsof` on macOS,
#      `/proc/<pid>/cwd` on Linux), and a process whose cwd is inside `<repo>/.worktrees/<name>` is
#      HOLDING that worktree: `<name>` is one occupied slot. This is an observation of the machine.
#   2. THE SESSION CONVENTION. `tmux ls` names, counted by the harness's own prefixes.
#
# The census reports both, plus `used` = the LARGER of the two, because the failure being fixed is
# UNDER-counting and a larger count can only ever REFUSE a dispatch (the safe direction). A caller
# that prints `used` without `src` is presenting a fallback as a measurement, which is the defect.
#
# ⛔ CHEAP BY CONSTRUCTION, AND BOUNDED. `lane-status.py` costs 147-420s under load (measured) and its
# timeout is why the dispatcher went blind on exactly the passes where the fleet was fullest. This
# file must never repeat that: two subprocess reads, each hard-bounded, and an UNREADABLE answer is
# returned as UNREADABLE in ~seconds rather than as a timeout.
#
# OUTPUT — one line, `key=value` tokens (no spaces in any value):
#   state=READ|PARTIAL|UNREADABLE   PARTIAL = one of the two observations read, the other did not
#   procs=<n>        live agent processes observed (the cross-check the issue asks for)
#   worktrees=<n>    distinct worktrees held by a live process (alias of `taken`)
#   taken=<n>        the same number, under the name the roster vocabulary uses
#   lanes_wt=<n>     occupied slots whose worktree name marks a LANE  (tm-*, lane-*)
#   workers_wt=<n>   occupied slots whose worktree name marks a WORKER (fix-*, merge-*, prd-*)
#   lanes_tmux=<n>   `^lane-` sessions            workers_tmux=<n> `^(fix|merge)-` sessions
#   used=<n>         max(lanes_wt, lanes_tmux)   src=worktrees|tmux|none
#   why=<token>      present only when state != READ — never a space
# EXIT is always 0: the STATE token is the answer, so a caller cannot read a non-zero exit as "zero".
#
# Usage:  lane-census.sh [--repo <checkout>]
#         REPO=<checkout> lane-census.sh
set -u

REPO_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)   REPO_DIR="${2:-}"; shift 2 ;;
    --repo=*) REPO_DIR="${1#*=}"; shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) shift ;;
  esac
done
[ -n "$REPO_DIR" ] || REPO_DIR="${REPO:-}"
[ -n "$REPO_DIR" ] || REPO_DIR="$(pwd)"

# ── a hard bound, because macOS ships no timeout(1) (same reason lib/bounded.sh exists) ─────────
# `census_bounded <secs> <cmd...>`: the command's own status is what the caller sees; a bound that
# fired is 124. The sentinel file distinguishes a real SIGKILL from a command that exited 137.
CENSUS_TMP="${TMPDIR:-/tmp}/lane-census.$$"
mkdir -p "$CENSUS_TMP" 2>/dev/null || CENSUS_TMP="/tmp"
census_cleanup() { rm -rf "$CENSUS_TMP" 2>/dev/null || true; }
trap census_cleanup EXIT INT TERM
census_bounded() {
  local secs="$1"; shift
  local pid timer rc=0
  # ⛔ THE SENTINEL IS PER CALL, NOT PER PROCESS (2026-10-19, caught by this file's own suite). It
  # was created once and never cleared, so ONE bounded read that fired made EVERY LATER read in the
  # same run report 124 — a stale flag describing a past state. Measured: a hanging `pgrep` (the arm
  # the bound exists for) left the sentinel behind and the tmux read two lines later was reported as
  # unreadable, which turned a PARTIAL answer into `used=0 src=none`. A bound that has already fired
  # must never describe a command that has not run.
  rm -f "$CENSUS_TMP/killed" 2>/dev/null || true
  "$@" >"$CENSUS_TMP/out" 2>/dev/null &
  pid=$!
  ( sleep "$secs"; : > "$CENSUS_TMP/killed"; kill -TERM "$pid" 2>/dev/null; sleep 2; kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  timer=$!
  wait "$pid" 2>/dev/null || rc=$?
  kill "$timer" 2>/dev/null || true
  wait "$timer" 2>/dev/null || true
  if [ -f "$CENSUS_TMP/killed" ]; then return 124; fi
  return $rc
}

# ── the two observations ───────────────────────────────────────────────────────────────────────
# pi_pids — the agent processes. `pgrep -x pi` is the SAME exact-name predicate `lane-status.py` uses
# (`_pi_pid_cwds`), so the two surfaces cannot disagree about what an agent process is.
pi_pids() {
  local rc
  if command -v pgrep >/dev/null 2>&1; then
    census_bounded 10 pgrep -x pi; rc=$?
    case "$rc" in
      0) cat "$CENSUS_TMP/out" 2>/dev/null; return 0 ;;
      # `pgrep` answers 1 for "ran, matched nothing" — a READ of zero processes, not a failure.
      1) return 0 ;;
      124) return 124 ;;
    esac
  fi
  # pgrep absent or unhappy: the SAME question from the process table. The executable NAME is
  # compared exactly (basenamed), never a substring of argv.
  census_bounded 10 ps -Ao pid=,comm= || return 124
  awk '{n=$2; sub(/.*\//,"",n); if (n == "pi") print $1}' "$CENSUS_TMP/out" 2>/dev/null
  return 0
}

# pi_cwds — {pid, cwd} in ONE bounded call. Linux reads /proc directly (no process spawn per pid);
# macOS batches every pid into one `lsof`, which is what `lane-status.py`'s `_pi_cwd_map` does.
pi_cwds() {
  local pids="$1" p
  if [ -d /proc ] && [ -r /proc/self/cwd ]; then
    for p in $pids; do
      [ -r "/proc/$p/cwd" ] || continue
      # `readlink` is portable, `ls -l` output is not; a denied cwd is simply absent (a FLOOR on
      # visible work, never a claim of completeness).
      printf '%s\t%s\n' "$p" "$(readlink "/proc/$p/cwd" 2>/dev/null)" 2>/dev/null
    done
    return 0
  fi
  command -v lsof >/dev/null 2>&1 || return 1
  # shellcheck disable=SC2086
  census_bounded 20 lsof -w -a -d cwd -Fn -p "$(printf '%s' "$pids" | tr ' ' ',')" || return 1
  awk 'BEGIN{p=""} /^p/{p=substr($0,2); next} /^n/{if (p!="") {print p "\t" substr($0,2); p=""}}' \
      "$CENSUS_TMP/out" 2>/dev/null
  return 0
}

# tmux_names — the CONVENTION. An unreadable/absent tmux server leaves this EMPTY, which the caller
# must not read as "zero sessions" — that distinction is the whole point of `state=`.
tmux_names() {
  command -v tmux >/dev/null 2>&1 || return 1
  census_bounded 10 tmux ls -F '#{session_name}' || return 1
  cat "$CENSUS_TMP/out" 2>/dev/null
  return 0
}

# worktree_token <cwd> — the worktree name this cwd belongs to, or nothing.
# `<repo>/.worktrees/<name>/sub/dir` -> `<name>`. A cwd exactly AT `<repo>/.worktrees` is not a slot.
WORKTREE_ROOT="${REPO_DIR%/}/.worktrees"
worktree_token() {
  local cwd="${1:-}" rest
  case "$cwd" in "$WORKTREE_ROOT"/*) ;; *) return 1 ;; esac
  rest="${cwd#"$WORKTREE_ROOT"/}"
  printf '%s' "${rest%%/*}"
}

# ── run ───────────────────────────────────────────────────────────────────────────────────────
STATE="READ"
WHY=""
PROCS=""
TAKEN=""
LANES_WT=""
WORKERS_WT=""
LANES_TMUX=""
WORKERS_TMUX=""

PIDS="$(pi_pids)"; rc=$?
case "$rc" in
  0) PROCS="$(printf '%s\n' "$PIDS" | grep -c '[0-9]')" ;;
  124) STATE="PARTIAL"; WHY="agent_process_read_timed_out"; PROCS="" ;;
  *)  STATE="PARTIAL"; WHY="agent_process_read_failed"; PROCS="" ;;
esac
case "${PROCS:-}" in ''|*[!0-9]*) PROCS=""; [ -n "$STATE" ] && [ "$STATE" = "READ" ] && { STATE="PARTIAL"; WHY="agent_process_read_failed"; } ;; esac

if [ -n "$PROCS" ]; then
  CWDS="$(pi_cwds "$PIDS")"; rc=$?
  if [ "$rc" -ne 0 ]; then
    # The pids were observed but their cwd could not be: occupancy is UNKNOWN, while the process
    # COUNT is still a fact (and is the cross-check the caller prints).
    STATE="PARTIAL"; [ -n "$WHY" ] || WHY="cwd_read_${rc}"
    TAKEN=""; LANES_WT=""; WORKERS_WT=""
  else
    TOKENS="$(
      printf '%s\n' "$CWDS" | while IFS="$(printf '\t')" read -r _pid _cwd; do
        [ -n "${_cwd:-}" ] || continue
        t="$(worktree_token "$_cwd")" || continue
        [ -n "$t" ] || continue
        printf '%s\n' "$t"
      done | sort -u
    )"
    TAKEN="$(printf '%s\n' "$TOKENS" | grep -c '[^[:space:]]')"
    LANES_WT="$(printf '%s\n' "$TOKENS" | grep -cE '^(tm-|lane-)')"
    WORKERS_WT="$(printf '%s\n' "$TOKENS" | grep -cE '^(fix-|merge-|prd-)')"
  fi
fi

if NAMES="$(tmux_names)"; then
  LANES_TMUX="$(printf '%s\n' "$NAMES" | grep -c '^lane-')"
  WORKERS_TMUX="$(printf '%s\n' "$NAMES" | grep -cE '^(merge|fix)-')"
else
  LANES_TMUX=""; WORKERS_TMUX=""
  [ "$STATE" = "READ" ] && { STATE="PARTIAL"; WHY="tmux_unreadable"; }
fi

# ── the value to use, and its source ─────────────────────────────────────────────────────────
USED=""
SRC="none"
case "${LANES_WT:-}" in
  ''|*[!0-9]*) : ;;
  *) USED="$LANES_WT"; SRC="worktrees" ;;
esac
case "${LANES_TMUX:-}" in
  ''|*[!0-9]*) : ;;
  *) if [ -z "$USED" ] || [ "$LANES_TMUX" -gt "$USED" ]; then USED="$LANES_TMUX"; SRC="tmux"; fi ;;
esac
[ -n "$USED" ] || { USED=0; [ "$STATE" = "READ" ] && { STATE="UNREADABLE"; WHY="no_observation"; } ; }

# A state that says READ while nothing was read is the false green this file exists to remove.
if [ "$STATE" = "READ" ] && [ -z "${PROCS:-}" ]; then STATE="PARTIAL"; [ -n "$WHY" ] || WHY="no_agent_processes_observed"; fi
case "$WHY" in
  '') : ;;
  *) WHY="$(printf '%s' "$WHY" | tr -c 'A-Za-z0-9._-' '_')" ;;
esac

printf 'state=%s procs=%s worktrees=%s taken=%s lanes_wt=%s workers_wt=%s lanes_tmux=%s workers_tmux=%s used=%s src=%s' \
  "$STATE" "${PROCS:-?}" "${TAKEN:-?}" "${TAKEN:-?}" \
  "${LANES_WT:-?}" "${WORKERS_WT:-?}" \
  "${LANES_TMUX:-?}" "${WORKERS_TMUX:-?}" "$USED" "$SRC"
[ -n "$WHY" ] && printf ' why=%s' "$WHY"
printf '\n'
exit 0
