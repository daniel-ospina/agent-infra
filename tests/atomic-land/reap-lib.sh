#!/usr/bin/env bash
# tests/atomic-land/reap-lib.sh — the three questions a reaper has to answer, stated ONCE.
#
#   is_running <pid>        is this process ALIVE (not merely present)?
#   proc_ident <pid>        is the process holding this pid still the SAME process?
#   reap_pid <pid> <ident>  SIGKILL it and its children, and PROVE it is gone.
#
# Sourced by `run.sh` (the survivor assertions) and by `rail-guard.sh` (the watchdog's
# reaper, which runs as its own process so it outlives the suite — #1845). Two copies of
# these rules is how one of them drifts into a false answer, so they live here.
#
# Sourced only: no side effects, no shell options, no policy. The CALLER decides what a
# still-running process means. Bash 3.2-safe (macOS `/bin/bash`), POSIX tools only.

is_running() { # <pid> — ALIVE, not merely present: a killed child of ours is a ZOMBIE
  # `kill -0` answers TRUE for a zombie, so a liveness test built on it alone cannot prove
  # a reap — it would report a leak as "gone" (or, worse here, keep killing a corpse).
  # `ps -o stat=` answers existence AND state in one read, so it is used INSTEAD of
  # `kill -0` rather than beside it.
  local st
  st="$(ps -o stat= -p "$1" 2>/dev/null)"
  [ -n "$st" ] || return 1
  case "$st" in *Z*) return 1 ;; esac
  return 0
}

proc_ident() { # <pid> -> its start stamp; empty when there is no such process
  # IDENTITY FOR A SIGNAL. pid + start time is effectively unique and — unlike `ppid` —
  # it SURVIVES the reparent-to-1 that is the field signature of #1845, so it is the
  # check that can be applied to a genuine orphan, which a ppid test cannot.
  ps -o lstart= -p "$1" 2>/dev/null
}

still_ours() { # <pid> <ident> — the process we were handed is STILL that process
  # The guard's loop condition. `is_running` alone is not enough: once the rail is reaped
  # its pid is free to be REUSED, and a stranger holding it would keep the guard polling to
  # its limit (30s of the suite blocked on a `wait`) and then make it "reap" an innocent
  # process. A blank ident means the capture failed, so liveness is all we can ask.
  is_running "$1" || return 1
  [ -z "$2" ] && return 0
  [ "$(proc_ident "$1")" = "$2" ]
}

reap_pid() { # <pid> <ident> — 0 = provably gone (or provably NOT the process), 1 = SURVIVED
  local pid="$1" ident="$2" n=0
  while is_running "$pid"; do
    # ⛔ IDENTITY BEFORE EVERY SIGNAL — the pid-recycling insurance
    # `scripts/sweep-orphans.sh` states, applied with a stamp an orphan still carries. A
    # RECYCLED pid belongs to a stranger, and `pkill -P` on it would signal that
    # stranger's children: the bad-reap direction (#1393) is worse than a leak, so an
    # identity we cannot confirm means DO NOT SIGNAL. A blank stamp means the capture
    # failed, and reaping is this function's whole job, so it proceeds.
    if [ -n "$ident" ] && [ "$(proc_ident "$pid")" != "$ident" ]; then return 0; fi
    # ⛔ CHILDREN FIRST. Once the parent dies its children reparent to 1 and can no longer
    # be found by parentage, so a parent-first kill leaks exactly the class #1845 names
    # and the two steps cannot be reordered.
    if command -v pkill >/dev/null 2>&1; then pkill -9 -P "$pid" 2>/dev/null; fi
    kill -9 "$pid" 2>/dev/null
    n=$((n + 1))
    [ "$n" -ge 50 ] && return 1
    sleep 0.1
  done
  return 0
}
