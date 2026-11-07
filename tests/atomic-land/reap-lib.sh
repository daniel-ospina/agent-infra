#!/usr/bin/env bash
# tests/atomic-land/reap-lib.sh — the three questions a reaper has to answer, stated ONCE.
#
#   is_running <pid>        is this process ALIVE (not merely present)?
#   proc_ident <pid>        is the process holding this pid still the SAME process?
#   reap_pid <pid> <ident>  SIGKILL it and its children, and PROVE it is gone.
#
# ⛔ "AND ITS CHILDREN" IS CONDITIONAL ON `pkill`. With no `pkill` on PATH this is a
# PARENT-ONLY reap, and it says so on stderr rather than absorbing the degradation: an
# unreported narrower reap is still reported to the caller as a PROVEN one (#3622 review,
# P3). `pkill` ships with macOS and procps, so this is a slim-container case.
#
# Sourced by `run.sh` (the four last-resort reaps in `run_rail_watchdog`, the `proc_ident`
# capture it hands the guard, and the survivor/refusal assertions 7g/7h/7j make about a real
# process — there is deliberately NO "barrier" there that notices a rail leaking during a
# normal scenario: 7b/7f's `is_running "$LAST_RAIL_PID"` checks were removed because
# `run_rail_watchdog` has already collected the rail by then, so they could never fail) and by
# `rail-guard.sh` (the watchdog's reaper, which runs as its own process so it outlives the
# suite — #1845). Two copies of these rules is how one of them drifts into a false answer, so
# they live here.
#
# Sourced only: no side effects, no shell options, no policy. The CALLER decides what a
# still-running process means. Bash 3.2-safe (macOS `/bin/bash`), POSIX tools only.

is_running() { # <pid> — ALIVE, not merely present: a killed child of ours is a ZOMBIE
  # ⛔ TWO PROBES, AND THE ORDER IS THE FIX (#3622 review round 2, P1).
  # `ps` MUST NOT BE ABLE TO DISARM THE BOUND. An empty `ps -o stat=` means "`ps` could not
  # answer" — a slim container has no `ps`, and busybox' `ps` rejects `-o stat= -p` — NOT
  # "the process is gone". Reading it as gone made the guard's loop never run, so the guard
  # exited 0 ("the rail stopped on its own") and the caller fell through to `wait "$pid"` on
  # a hanging rail: pre-#1845 restored one level up. Measured with a `ps` shim (`exit 0`, no output) over a
  # live pid: below returns GONE while the kernel still has the pid and `kill -0` says
  # ALIVE. This repo has already measured that same misread in a bound and fixed it the
  # same way — `scripts/run-bash-shards.sh:702-716`: "reading it as 'not a timeout' made the
  # bound INERT while the run still printed ✅".
  # So `kill -0` — a builtin, which cannot fail for want of a binary — answers EXISTENCE, and
  # `ps` is asked only the question it alone can answer: is this a ZOMBIE? An unreadable
  # state therefore falls through to ALIVE: fail-closed.
  # (EPERM reads as gone, both here and in `rail-guard.sh`'s supervisor probe; the reaper
  # family only ever targets same-user processes, and an unconfirmable target must not be
  # signalled anyway — see `reap_pid`'s identity rule.)
  kill -0 "$1" 2>/dev/null || return 1
  # ⛔ THE EXIT STATUS DECIDES WHETHER THERE IS AN ANSWER AT ALL (#3622 review round 6, P2).
  # The rule above is "`ps` must not be able to disarm the bound", and an EMPTY answer was the
  # only shape it guarded. A `ps` that FAILS can still WRITE TO STDOUT — a wrapper, a shim, a
  # future procps printing a usage/legend banner — and an unanchored `*Z*` matches the `Z` in
  # "Z zombie": measured 2026-11-07 with a `ps` that printed `Z zombie` and exited 1, this
  # function answered GONE for a LIVE pid, so the guard took its `exit 0` ("the rail stopped
  # on its own") over a running rail — the round-2 fail-open through a second door. So only an
  # EXIT-0 `ps` is allowed to say "zombie"; a failed one falls through to ALIVE, fail-closed.
  local st
  st="$(ps -o stat= -p "$1" 2>/dev/null)" || return 0
  case "$st" in
    *Z*) return 1 ;;   # a corpse is not running: only `ps` can tell us that
  esac
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
  # ⛔ ONLY A READABLE MISMATCH PROVES A STRANGER (#3622 review round 3, P2). An EMPTY
  # `proc_ident` means `ps` could not answer THIS time — not that the pid changed hands —
  # and reading it as "not ours" is the same fail-open direction round 2 fixed one line
  # above: the guard exits 0 with no sentinel while a HEALTHY rail is still running, and
  # the caller then reports "it lost the process" and kills the rail it was protecting.
  # Measured with a `ps` that answers the capture and then cannot: `still_ours` said FALSE
  # for a live pid. So an unreadable identity degrades to the liveness answer, exactly like
  # a blank one.
  is_running "$1" || return 1
  [ -z "$2" ] && return 0
  local cur
  cur="$(proc_ident "$1")"
  [ -z "$cur" ] && return 0
  [ "$cur" = "$2" ]
}

reap_pid() { # <pid> <ident> — 0 = provably gone (or provably NOT the process), 1 = SURVIVED
  local pid="$1" ident="$2" n=0 cur
  while is_running "$pid"; do
    # ⛔ IDENTITY BEFORE EVERY SIGNAL — the pid-recycling insurance
    # `scripts/sweep-orphans.sh` states, applied with a stamp an orphan still carries. A
    # RECYCLED pid belongs to a stranger, and `pkill -P` on it would signal that stranger's
    # children: the bad-reap direction (#1393) is worse than a leak. So a pid that a
    # CAPTURED stamp proves is a different process is NEVER signalled — see the next
    # paragraph for the other half, which this paragraph used to state wrongly.
    # ⛔ AND "CANNOT CONFIRM" IS NOT "CONFIRMED DIFFERENT" (#3622 review round 3, P2).
    # Only a READABLE mismatch may skip the signal: an EMPTY `proc_ident` here (a transient
    # `ps` failure, not a recycled pid) used to `return 0` — "provably gone" — without
    # signalling anything, and the guard then wrote `reaped <pid>` and the caller returned
    # 124 ("the rail stopped") over a live rail. Measured: `reap_pid rc=0` with the victim
    # still running. So an unreadable stamp falls through to the SIGNAL (fail-closed), and a
    # BLANK stamp forfeits the recycling protection entirely rather than refusing to act.
    if [ -n "$ident" ]; then
      cur="$(proc_ident "$pid")"
      if [ -n "$cur" ] && [ "$cur" != "$ident" ]; then return 0; fi
    fi
    # ⛔ CHILDREN FIRST. Once the parent dies its children reparent to 1 and can no longer
    # be found by parentage, so a parent-first kill leaks exactly the class #1845 names
    # and the two steps cannot be reordered.
    if command -v pkill >/dev/null 2>&1; then
      pkill -9 -P "$pid" 2>/dev/null
    elif [ "$n" -eq 0 ]; then
      # Once per call, not per iteration: the degradation is stated, not absorbed, and it
      # is stated rather than turned into a refusal because the PARENT reap still has to
      # happen.
      echo "reap-pid: no pkill on PATH — reaping pid $pid only; its children are NOT reaped" >&2
    fi
    kill -9 "$pid" 2>/dev/null
    n=$((n + 1))
    [ "$n" -ge 50 ] && return 1
    sleep 0.1
  done
  return 0
}
