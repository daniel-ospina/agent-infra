#!/usr/bin/env bash
# controllers.sh — HOW MANY controllers own THIS runtime? (agent-infra#2043)
#
# THE DEFECT THIS REPLACES
# ------------------------
# `bg/status.sh` counted controllers by argv:
#
#     loop=$(ps ax -o command | grep -c "[o]rch-loop.sh")     # ⛔ a SUBPROCESS count, not a controller count
#
# A bash SUBSHELL wears its parent's argv. `( … )` and `$( … )` inside `orch-loop.sh` are forked from
# the controller without an `exec`, so `ps` shows them as `bash $O/orch-loop.sh` with the CONTROLLER as
# their ppid. Measured 2026-10-18 while exactly one controller existed:
#
#     41679 41665  bash /Users/home/orchestrator/orch-loop.sh     # the controller, child of its supervisor
#     71388 41679  bash /Users/home/orchestrator/orch-loop.sh     # a subshell: ppid IS the controller
#     83157 71388  bash /Users/home/orchestrator/orch-loop.sh     # a subshell of a subshell
#
# Three rows, ONE controller. `bg/status.sh` printed `orch-loop-procs=3`, which reads as "a duplicate
# controller is running" — the exact condition the supervisor's `one_instance` guard exists to prevent,
# and the reason a stale `.orch.lock` investigation looks alarming when nothing is wrong.
#
# THE READING
# -----------
# Two authorities, each used for what it can actually prove:
#
#   * the LOCK (`$O/.orch.lock`) names this runtime's controller pid — the authoritative, SINGULAR
#     handle. It is re-checked against the process table at the moment of use, because a pid is not an
#     identity: it can be recycled. A lock that names something else is NAMED (see below), never
#     silently folded in or out.
#   * the PROCESS TABLE, ancestry-reduced, is what still sees a GENUINE SECOND CONTROLLER — one
#     started outside launchd, which is a real fault this fleet has been bitten by. A count that read
#     only the lock could never report it, so the lock alone is not enough (this is why the
#     `controller_pids` idiom in `harness.sh` — lock-first, pgrep fallback — is adopted here but
#     extended: the table is always consulted, and the lock VERIFIES identity rather than replacing
#     the population).
#
# Subshells are removed by ANCESTRY, not by deduplicating argv: a match whose ppid chain contains
# another match is a subshell of it and is dropped; two matches with independent parents are two
# controllers. This is the same awk the cell supervisor ships (`_controller_ps_awk`,
# cloud-cell-supervisor.sh) — tests/controllers.test.sh pins the two copies together, because two
# copies of one process-identity rule that may DRIFT are the #1178 defect ("two contracts for one
# safety rule").
#
# NAMED OUTCOMES — three, never a silent include or exclude
# ---------------------------------------------------------
#   lock names a dead pid <pid>               the lock outlived its controller (kill -9, OOM, reboot);
#                                             stale, and it contributes nothing to the count
#   lock names a non-controller pid <pid>     the pid is ALIVE but its argv is not an orch-loop.sh
#                                             invocation (a recycled pid, or a lock written by hand)
#   lock is not a regular file / lock is empty named as such; the count falls back to the table
#
# A process table that cannot be read is `controllers=unknown`, exit 2 — NEVER 0 (a broken `ps` is not
# "no controller": the probing process itself appears in any real table — #1178 C3 / #1856).
#
# CONTRACT
# --------
#   bash controllers.sh                 → `controllers=<N> pids="<p1> <p2>"`  (or `controllers=unknown`)
#   bash controllers.sh --count         → `<N>`  (or `unknown`), one token, for `$( … )`
#   bash controllers.sh --pids          → the pids, space-separated, one line
#   warn lines go to STDERR, so `$( … )` captures only the reading.
#
#   rc 0 = read; 1 = nothing is running (controllers=0); 2 = cannot determine; 78 = usage.
#   Exit 1 on a ZERO count is deliberate: it is the answer a caller must be able to tell apart from
#   "the read failed". Callers that only want the number use --count and ignore rc.
#
# ENV
# ---
#   O                      state dir holding `orch-loop.sh` and `.orch.lock` (default ~/orchestrator)
#   EXTRA_CONTROLLER_PATH  a second `orch-loop.sh` path that also counts as THIS runtime's controller
#                          (a cell's pinned harness copy, agents.s `seen_controller_pids`). Default
#                          empty: a controller running another runtime's copy is not ours to count.
#   PS_BIN                 the `ps` to read (default /bin/ps) — the seam the test suite stubs.
#
# READ-ONLY. Nothing here signals, writes or removes anything.
set -u

O="${O:-$HOME/orchestrator}"
EXTRA_CONTROLLER_PATH="${EXTRA_CONTROLLER_PATH:-}"
PS_BIN="${PS_BIN:-/bin/ps}"
LOCK="$O/.orch.lock"
CONTROLLER="$O/orch-loop.sh"

warn() { printf '%s\n' "$*" >&2; }
usage() {
  printf '%s\n' "usage: controllers.sh [--count|--pids]" >&2
  exit 78
}

# ⛔ THIS AWK IS A PINNED MIRROR of `_controller_ps_awk` in scripts/cloud-cell-supervisor.sh, which
# cannot be sourced from here (both files are shipped STANDALONE into a runtime dir, so neither can
# source the other). The descendant rule is the fleet's, not this file's: a match whose ppid chain
# contains another match is a SUBSHELL of it, and only the ancestor is a controller. Do not "improve"
# one copy alone — controllers.test.sh compares the two bodies byte-for-byte and reddens on drift.
_controller_ps_awk='
  { ppid[$1]=$2; c=$0; sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/,"",c)
    n=split(c,tok," ")
    if (n>=2 && tok[2]!="-" && index(tok[2],"orch-loop.sh") && (tok[2]==a || (h!="" && tok[2]==h)) && tok[1] ~ /(bash|sh)$/) m[$1]=1 }
  END { for (p in m) { q=p; d=0
          for (i=0;i<64;i++) { if (!(q in ppid) || ppid[q]<=1) break; q=ppid[q]; if (q in m) { d=1; break } }
          if (!d) print p } }'

# The process table, or rc 1 when it could not be read. `-eo pid=,ppid=,command=` is the same shape
# the cell supervisor reads, and it is supported by both BSD and GNU ps.
read_table() {
  local t
  t="$("$PS_BIN" -eo pid=,ppid=,command= 2>/dev/null)" || return 1
  # ⛔ An EMPTY table is an unreadable read, never "no process exists": the probing process itself must
  # appear in any real table (#1178 C3, the rule #1856 measured on a broken-`ps` box).
  case "$t" in *[![:space:]]*) ;; *) return 1 ;; esac
  printf '%s\n' "$t"
}

# The lock's pid, when it can be read at all. rc 1 (with the reason NAMED) otherwise.
# ⛔ `[ -f ]` BEFORE the read: a FIFO or a wedged network mount makes `tr` BLOCK on open, so an
# unreadable lock would hang the caller instead of reporting (the same guard lc_foreign_controller
# needed in launchd-cycle.sh).
read_lock_pid() {
  local p
  [ -e "$LOCK" ] || return 1
  if [ ! -f "$LOCK" ]; then
    warn "lock is not a regular file — cannot read $LOCK"
    return 1
  fi
  p="$(tr -dc '0-9' 2>/dev/null < "$LOCK")" || p=""
  if [ -z "$p" ]; then
    warn "lock is empty — it names no pid"
    return 1
  fi
  printf '%s\n' "$p"
}

# controller_shaped <pid> <table> — 0 when the pid's argv is an orch-loop.sh INVOCATION.
# ⛔ Match the INVOCATION, not the string: a `bash -c '… orch-loop.sh …'` launcher, an editor or a
# tmux client whose command line merely CONTAINS the path is not a controller (the measured false
# positive the cell supervisor's scoped reads exist for). The controller's argv is exactly
# `<shell> <…/orch-loop.sh>`; `orch-loop.sh` takes no arguments.
# ⛔ The lock-named pid's PATH is deliberately not compared to $O: the lock is per-$O, so a controller
# holding it is this runtime's by construction — and the measured #1761 duplicate is a LEFTOVER HARNESS
# COPY (`bash /tmp/cell-home/harness/<sha>/…/orch-loop.sh`) holding the lock. Requiring $O's path here
# would report that live duplicate as "not a controller".
controller_shaped() { # <pid> <table>
  local row
  row="$(printf '%s\n' "$2" | awk -v p="$1" '
    { c=$0; sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/,"",c); if ($1==p) { print c; exit } }')"
  [ -n "$row" ] || return 1
  # shellcheck disable=SC2086
  set -- $row
  [ "$#" -eq 2 ] || return 1
  case "${1##*/}" in bash|sh|dash|zsh) ;; *) return 1 ;; esac
  case "${2##*/}" in orch-loop.sh) ;; *) return 1 ;; esac
  return 0
}

# ancestors_of <pid> <table> — one ppid per line, nearest first. Bounded, never loops.
ancestors_of() { # <pid> <table>
  printf '%s\n' "$2" | awk -v p="$1" '
    { ppid[$1]=$2 }
    END { q=p; for (i=0;i<64;i++) { if (!(q in ppid) || ppid[q]<=1) break; q=ppid[q]; print q } }'
}

main() {
  local mode="${1:-}" table matches lock lset pids n
  case "$mode" in ""|--count|--pids) ;; *) usage ;; esac

  if ! table="$(read_table)"; then
    warn "cannot read the process table ($PS_BIN -eo pid=,ppid=,command= failed or returned no rows) — the controller count is cannot-determine, not zero"
    case "$mode" in --count) printf 'unknown\n' ;; --pids) printf '\n' ;; *) printf 'controllers=unknown pids=""\n' ;; esac
    return 2
  fi

  # 1) the ancestry-reduced argv matches: this runtime's controller(s), subshells removed.
  matches="$(printf '%s\n' "$table" | awk -v a="$CONTROLLER" -v h="$EXTRA_CONTROLLER_PATH" "$_controller_ps_awk")"

  # 2) the lock, re-checked against the SAME table read (never a second, racier read).
  lset=""
  if lock="$(read_lock_pid)"; then
    if ! kill -0 "$lock" 2>/dev/null; then
      warn "lock names a dead pid $lock — stale lock from a controller that exited without its trap (kill -9, OOM, reboot); not counted"
    elif ! controller_shaped "$lock" "$table"; then
      warn "lock names a non-controller pid $lock — the pid is alive but its argv is not an orch-loop.sh invocation (recycled pid, or a lock written by hand); not counted"
    else
      # ⛔ A RECYCLED pid can land on a SUBSHELL of another controller (a subshell's argv is the
      # controller's), which would count 2 over one controller — the very miscount this file removes.
      # Drop it when any of its ancestors is already a match.
      lset="$lock"
      for p in $(ancestors_of "$lock" "$table"); do
        case " $(printf '%s' "$matches" | tr '\n' ' ') " in
          *" $p "*) warn "lock names pid $lock, which is a subshell of controller $p — counted once, as $p"; lset="" ; break ;;
        esac
      done
    fi
  fi

  pids="$(printf '%s\n%s\n' "$matches" "$lset" | awk 'NF && !s[$0]++' | sort -n | tr '\n' ' ' | sed 's/ *$//')"
  n=0
  [ -n "$pids" ] && n="$(printf '%s\n' "$pids" | wc -w | tr -d ' ')"

  case "$mode" in
    --count) printf '%s\n' "$n" ;;
    --pids)  printf '%s\n' "$pids" ;;
    *)       printf 'controllers=%s pids="%s"\n' "$n" "$pids" ;;
  esac
  [ "$n" -gt 0 ] || return 1
  return 0
}

main "$@"
