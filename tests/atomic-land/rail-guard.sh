#!/usr/bin/env bash
# tests/atomic-land/rail-guard.sh — the reaper that outlives the suite it protects (#1845).
#
#   rail-guard.sh <supervisor-pid> <limit-secs|0> <pid> [ident]
#
#   exit 0    the rail stopped on its own — nothing was done
#   exit 124  the guard FIRED and reaped a live rail (the caller reports a watchdog timeout)
#   exit 125  the guard fired and the rail SURVIVED SIGKILL — NOT a clean reap
#   exit 2    usage/argument error
#
# ⛔ THE EXIT STATUS, NOT A SENTINEL FILE, CARRIES THE VERDICT. The first cut wrote a sentinel
# into the scenario dir and the caller read it; measured: `: >"$file" 2>/dev/null` does NOT
# suppress the redirection's own failure, so on a deleted scratch dir (or ENOSPC) the sentinel
# was silently absent and the caller reported the rail's SIGKILL status (137) as a bounded stop —
# the exact confusion the sentinel existed to prevent. A process's exit status cannot be lost.
#
# WHY THIS IS A SEPARATE PROCESS AND NOT A FUNCTION IN run.sh.
# The suite's watchdog used to be a poll loop inside `run.sh`. `$!` was already the rail
# (`rail_exec` ends in `exec` — #1532), so the kill was aimed at the right process, and it
# STILL leaked: the loop lived in the suite, so the moment the suite was killed
# mid-scenario — a shard timeout, a lane's own watchdog, an operator, a cancelled CI job —
# nothing bounded the rail any more. Measured on three cloud cells, one per suite run:
# `bash /tmp/atomic-land-suite.*/mut/B14.sh … --poll 0 --wait-timeout 08`, `ppid 1`,
# cwd `(deleted)`, 10–12 % CPU, 4h12m to 1d19h old, on a box other lanes share.
# An enforcer whose termination condition cannot fire is not an enforcer.
#
# So the loop moved HERE, into a process that keeps running after the suite dies and
# fires on EITHER of two conditions:
#   (a) the limit expired, or
#   (b) the supervisor it was handed is gone (the field case).
# Firing reaps the rail and its children and re-checks that the rail is gone (`reap_pid`); a
# reap it cannot prove is reported as a SURVIVOR (exit 125), never as success.
#
# ⛔ IT IS A SEPARATE `bash`, AND THAT IS LOAD-BEARING — not a style choice. A backgrounded
# FUNCTION is a forked subshell of `run.sh`, and a fork INHERITS its traps. Measured
# 2026-11-06: tearing the guard down with SIGTERM made the guard run the suite's
# `trap cleanup EXIT` and `rm -rf` the live suite temp dir mid-run — 136 of 456 assertions
# reddened by the deletion, and all 71 mutation children "reddened" for the same reason, so
# the coverage gate printed ✅ while covering nothing. Clearing the trap inside the subshell
# does NOT fix it either: `kill -TERM` issued right after the fork lands BEFORE the
# subshell's first statement, so the still-inherited trap runs (5/5 reproduced). A new
# `bash` does not inherit traps at all, and the caller never signals this process (it waits),
# so no signal can reach a fork of the caller in its pre-exec window either.
#
# ⛔ AND BASH RUNS AN EXIT TRAP WHEN IT IS KILLED BY A SIGNAL — that is the mechanism above,
# measured directly: `trap 'echo T' EXIT; sleep 30 & wait`, SIGTERM'd, prints T. Any future
# caller that decides to signal this script must re-measure that decision rather than
# assume it.
#
# ⛔ THE GUARD OWNS THE KILL WHILE IT IS ALIVE — the caller does not, and that division must not be
# read as "the caller only waits". `run_rail_watchdog` waits and watches THIS PROCESS, and it
# reaps the rail itself as a LAST RESORT if this process dies first (that is what makes a dead
# guard reportable as an unbounded rail instead of a hang). So: this script's `exit 0` is NOT
# the only path by which a live rail can end up un-reaped, and a reader who assumes the caller
# merely waits will delete the arm that exists for this script's own death.
# This is, however, the only arm that reaps on a SCHEDULE: no clock exists in the caller, so if
# this process cannot run there is no bound at all — which is why the preflight below refuses
# rather than degrading.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 2
# ⛔ PREFLIGHT ITS OWN LIBRARY, or this script lies. `set -uo pipefail` does NOT abort a failed
# `.`, so with reap-lib.sh missing `still_ours` is UNDEFINED: the loop condition fails 127 once,
# the body never runs, and flow reaches `exit 0` — which this script's own header defines as "the
# rail stopped on its own". Measured (2026-11-07, review of this PR): a lone copy of the guard
# against a LIVE rail exited 0 with `still_ours: command not found` on stderr. That is the
# false-PASS class this whole change removes, one level down, and it is the sibling of the
# `[ -f ]` preflights `run.sh` now does for these two files. Exit 2 (refusal), never 0.
if [ ! -f "$HERE/reap-lib.sh" ]; then
  echo "rail-guard: missing $HERE/reap-lib.sh — refusing to pretend the rail is bounded" >&2
  exit 2
fi
# shellcheck source=/dev/null
. "$HERE/reap-lib.sh"
# Belt-and-braces for the same reason: a library that exists but does not define the rules (a
# truncated write, a bad merge) must also refuse rather than fail open on a 127.
if ! command -v still_ours >/dev/null 2>&1 || ! command -v reap_pid >/dev/null 2>&1; then
  echo "rail-guard: reap-lib.sh did not define still_ours/reap_pid — refusing" >&2
  exit 2
fi

if [ "$#" -lt 3 ]; then
  echo "usage: rail-guard.sh <supervisor-pid> <limit-secs|0> <pid> [ident]" >&2
  exit 2
fi
sup="$1"; limit="$2"; pid="$3"; ident="${4:-}"
case "$limit" in ''|*[!0-9]*) echo "rail-guard: the limit must be a non-negative integer" >&2; exit 2 ;; esac

started="$SECONDS"
why=""
# ⛔ `still_ours`, NOT `is_running`: once the rail is reaped its pid can be REUSED, and a
# stranger holding it would keep this loop going to the limit (blocking the caller's `wait`)
# and then make it try to reap an innocent process.
while still_ours "$pid" "$ident"; do
  if [ "$limit" -gt 0 ] && [ $((SECONDS - started)) -ge "$limit" ]; then
    why="the ${limit}s limit expired"
  elif ! kill -0 "$sup" 2>/dev/null; then
    # `kill -0` answers TRUE for a supervisor that was KILLED but not yet REAPED, so that
    # window falls through to the limit above. That is the only backstop for it: the caller
    # checks no limit of its own (it has none — see the header).
    why="its supervisor (pid $sup) is gone"
  fi
  if [ -n "$why" ]; then
    # ⛔ RE-CHECK BEFORE FIRING. The condition was decided at the top of THIS iteration and the
    # rail can exit inside it; without this, a rail that stopped on its own would be reported
    # as a watchdog timeout (and this script would print "reaped" for a process it never
    # signalled — a bound that lies about what it did).
    still_ours "$pid" "$ident" || exit 0
    if reap_pid "$pid" "$ident"; then
      echo "rail-guard: reaped pid $pid — $why" >&2
      exit 124
    fi
    echo "rail-guard: pid $pid SURVIVED SIGKILL — $why (NOT reaped)" >&2
    exit 125
  fi
  sleep 1
done
exit 0
