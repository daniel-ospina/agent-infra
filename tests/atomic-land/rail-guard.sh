#!/usr/bin/env bash
# tests/atomic-land/rail-guard.sh — the reaper that outlives the suite it protects (#1845).
#
#   rail-guard.sh <supervisor-pid> <limit-secs|0> <sentinel> <pid> [ident]
#
#   <limit-secs>  the wall-clock bound on the rail. `0` means NO TIME LIMIT — the guard
#                 then fires only when its supervisor is gone. (That is what `0` means
#                 HERE; it is NOT "fire now". The old inline loop had no lower guard, so
#                 `0` fired on its first iteration — a caller that reads "0 seconds" as
#                 "no patience" would get the opposite of what it expects. No caller passes
#                 0 today; both meanings are stated so the next one cannot guess wrong.)
#   <sentinel>    created when the guard FIRES, so the caller can tell "the guard reaped
#                 it" from "the rail stopped by itself".
#                 `<sentinel>.report` carries the OUTCOME as one line — `reaped <pid>` or
#                 `survived <pid>` — because a sentinel alone proves an INTENT, not a reap:
#                 the caller returns 124 ("the rail was stopped") on it, and a `reap_pid`
#                 that could not kill would otherwise still be reported as a bound.
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
# Firing reaps the rail and its children and PROVES the rail is gone (`reap_pid`); a reap
# it cannot prove is printed as a SURVIVOR, never reported as success.
#
# ⛔ IT IS A SEPARATE `bash`, AND THAT IS LOAD-BEARING — not a style choice. A backgrounded
# FUNCTION is a forked subshell of `run.sh`, and a fork INHERITS its traps. Measured
# 2026-11-06: tearing the guard down with SIGTERM made the guard run the suite's
# `trap cleanup EXIT` and `rm -rf` the live suite temp dir mid-run — 136 of 456 assertions
# reddened by the deletion, and all 71 mutation children "reddened" for the same reason, so
# the coverage gate printed ✅ while covering nothing. Clearing the trap inside the subshell
# does NOT fix it either: `kill -TERM` issued right after the fork lands BEFORE the
# subshell's first statement, so the still-inherited trap runs (5/5 reproduced). A new
# `bash` does not inherit traps at all, which closes that race by construction — and the
# caller now NEVER signals this process (it exits on its own when the rail is gone), so no
# signal can reach a fork of the caller in its pre-exec window either.
#
# ⛔ AND BASH RUNS AN EXIT TRAP WHEN IT IS KILLED BY A SIGNAL — that is the mechanism above,
# measured directly: `trap 'echo T' EXIT; sleep 30 & wait`, SIGTERM'd, prints T. It is also
# why the caller WAITS instead of killing. Any future caller that decides to signal this
# script must re-measure that decision rather than assume it.
#
# ⛔ WHAT THIS DOES *NOT* COVER — one of the deaths named above defeats it, and the claim
# here is narrower than "no rail ever outlives its suite". `scripts/run-bash-shards.sh`
# gives each shard its OWN process group (`set -m`) and its timeout kills the GROUP
# (`kill -TERM -<pgid>`, then KILL). This guard is an ordinary background child in that
# group, so a SHARD TIMEOUT kills the guard together with the suite. Nothing leaks — the
# group KILL takes the rail too — but the supervisor-death arm cannot fire for that case.
# So what the guard actually covers is an INDIVIDUAL process death (an operator's `kill`, a
# lane's own watchdog, a cancelled CI job that signals one pid) plus the limit. Covering the
# group case would mean `setsid`, which changes what the guard is a child of and is a
# different change.
#
# The sentinel is how the caller tells "the guard reaped it" from "the rail exited by
# itself": `run_rail_watchdog` returns 124 only when this script wrote it, so a rail that
# legitimately stops (rc 1) can never be reported as a watchdog timeout. The
# `<sentinel>.report` line is the same distinction one level deeper — fired vs PROVED —
# and the caller refuses a fired-without-proof as a WATCHDOG FAILURE (125), not as 124.
#
# ⛔ ONE WINDOW THIS CANNOT CLOSE, stated so nobody over-reads it: the rail is started by
# the CALLER and the guard is handed its pid, so a supervisor killed between the spawn and
# the guard's first poll leaves the rail unbounded for that instant. The measured field
# triggers (shard timeout, operator, cancelled CI job) are seconds-scale, so this is not a
# practical leak; closing it structurally means the GUARD creates the rail, which is a
# bigger change than the one that removed the 4h12m-1d19h class.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 2
# shellcheck source=/dev/null
. "$HERE/reap-lib.sh"
# ⛔ A FAILED SOURCE IS SILENT HERE, so check it. `set -uo pipefail` has no `-e`: without
# this guard the script would run with its primitives UNDEFINED, hit `still_ours: command
# not found` in its loop, and EXIT 0 having done nothing — and rc 0 from this script means
# "the rail is gone". Measured (scratch copy, reap-lib.sh removed): `still_ours: command
# not found` then `guard rc=0`. run.sh also refuses to start without the lib; this script
# is separately invocable (7g/7h drive it directly), so it must not trust its caller.
command -v still_ours >/dev/null 2>&1 \
  || { echo "rail-guard: reap-lib.sh did not load (still_ours is undefined) — refusing to report a bound" >&2; exit 2; }

if [ "$#" -lt 4 ]; then
  echo "usage: rail-guard.sh <supervisor-pid> <limit-secs|0> <sentinel> <pid> [ident]" >&2
  exit 2
fi
sup="$1"; limit="$2"; sentinel="$3"; pid="$4"; ident="${5:-}"
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
    # window falls through to the limit — which is why the limit is checked here as well,
    # and not only by the caller.
    why="its supervisor (pid $sup) is gone"
  fi
  if [ -n "$why" ]; then
    : >"$sentinel" 2>/dev/null
    if reap_pid "$pid" "$ident"; then
      printf 'reaped %s\n' "$pid" >"$sentinel.report" 2>/dev/null
      echo "rail-guard: reaped pid $pid — $why" >&2
    else
      # ⛔ NOT SUCCESS. A reap this script cannot prove is a SURVIVOR, and the caller reads
      # this line to decide whether 124 is allowed to mean "the rail stopped".
      printf 'survived %s\n' "$pid" >"$sentinel.report" 2>/dev/null
      echo "rail-guard: pid $pid SURVIVED SIGKILL — $why (not reaped)" >&2
    fi
    exit 0
  fi
  sleep 1
done
