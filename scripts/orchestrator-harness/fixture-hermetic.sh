#!/usr/bin/env bash
# fixture-hermetic.sh — a suite's fixtures must not outlive the suite (agent-infra#3011).
#
# THE DEFECT THIS CLOSES. `harness-refresh.test.sh` starts REAL controllers
# (`bash <tree>/scripts/orchestrator-harness/orch-loop.sh`) to exercise the identity arm, and its
# teardown was `trap 'rm -rf "$T"' EXIT` — which removes the temp dir and reaps NOTHING. A deleted
# cwd does not end a process, and the fixture controller's own script is `read -r _ < <fifo>`, so
# each one parks forever at 0 CPU and is reparented to 1 when the suite exits.
# MEASURED 2026-10-28 on `pi-cell-4`: 145 such controllers, load 33–39 on 8 cores, most executing
# from `/tmp/harness-refresh.<rand>/…` dirs that no longer exist. That is category A: the box's
# entire headroom silently destroyed, read by the fleet as "the cell is busy", and a FALSE PASS for
# the suite that leaked it (exit 0 while leaving live processes behind).
#
# THE GOAL. A leaked controller is visible and the suite that leaked it fails (#3011's acceptance),
# not merely "impossible if the code is right": the reaper VERIFIES, and reports survivors.
#
# ⛔ WHY THE GROUP, AND WHY THE ID MUST COME FROM THE PROCESS TABLE, NOT FROM `$!`.
# `harness-refresh.test.sh` starts its controller inside `$( ... )`, so the growing background job is
# a GRANDCHILD: killing `$!` kills a wrapper and orphans the controller (the very shape #3011 is
# about, and `reap()` in that suite already documents a measured 9-survivor variant of it). So each
# fixture process is started in its OWN process group and the group is what gets signalled. The pgid
# is set BEFORE `exec` (perl `setpgrp`), so the id we record is the group leader's own id: one
# signal ends the controller and anything it forked, and nothing else on the host can be touched.
# The portable idiom is the one `refresh-candidates.sh` already uses (`setpgrp`), NOT `setsid`,
# which macOS does not ship (verified: `command -v setsid` is empty on darwin, present on the cells).
#
# STATED RESIDUALS.
#   * Neither `perl` nor `setsid` on PATH: the fixture still runs, but in the CALLER's group, so the
#     reaper falls back to signalling the pid alone and names that limit on stderr. Both platforms we
#     ship to have perl (verified darwin + the cell image), so the tested path is always the group.
#   * A pgid recycled by the OS between the start and the teardown would be a different process. The
#     window is the suite's own runtime and the ledger is truncated before use; the exposed pid set
#     is the group we created, and the teardown re-reads its OWN ledger.

FIXTURE_PGID_FILE=""
FIXTURE_REAP_GRACE="${FIXTURE_REAP_GRACE:-5}"
FIXTURE_TMP_TO_REMOVE=""

# ── placement guard ──────────────────────────────────────────────────────────────────────────────
# ⛔ THE POLARITY IS "A CONTROLLER IS EXECUTING FROM A LIVE CELL ROOT", NOT "A CELL DIRECTORY EXISTS".
# A directory is a STALE FLAG: /tmp/cell-home exists on a laptop that once ran a cell fixture (verified
# on this box, with no controller behind it), so dir-presence would refuse every local run — a false
# block on a healthy machine, which is the failure class this repo calls a stale flag that records a
# past state and is never revalidated. A controller executing from the root is a MEASUREMENT of the
# condition that actually matters: this box is running the fleet, so a suite here leaks onto capacity.
fixture_live_controllers() { # -> "<pid> <root>" per line
  local roots="${FIXTURE_LIVE_ROOTS:-/tmp/cell-home /home/cmux/harness}" r
  for r in $roots; do
    [ -d "$r" ] || continue
    # `-ww`: without it `ps` truncates the command at the terminal width, and the root path is
    # exactly the part that gets cut — the guard would then abstain about a box that is a live cell.
    ps -A -o pid=,args= -ww 2>/dev/null | awk -v root="$r" '
      index($0, root "/") && /orch-loop\.sh/ { print $1, root }'
  done
}

fixture_guard_placement() { # [suite-name]
  local suite="${1:-this suite}" live n
  live="$(fixture_live_controllers)"
  [ -n "$live" ] || return 0
  n=$(printf '%s\n' "$live" | wc -l | tr -d ' ')
  if [ "${HARNESS_SUITE_ALLOW_LIVE_CELL:-0}" = "1" ]; then
    printf '  ⚠️  %s: running on a LIVE cell (%s controller(s)) — allowed by HARNESS_SUITE_ALLOW_LIVE_CELL=1\n' \
      "$suite" "$n" >&2
    return 0
  fi
  {
    printf '\n❌ %s REFUSES TO RUN ON A LIVE CELL\n\n' "$suite"
    printf '   %s controller(s) are executing from a live cell root:\n' "$n"
    printf '%s\n' "$live" | sed 's/^/     pid /'
    printf '\n   A cell is a CAPACITY RESOURCE: the fleet reads its load as its own busy signal, and a\n'
    printf '   fixture controller left behind here is indistinguishable from a real one (#3011: 145\n'
    printf '   leaked controllers, load 39 on 8 cores). The fixture REAPER (fixture-hermetic.sh) now\n'
    printf '   removes what a suite starts, but a suite still has no business running on a live cell.\n\n'
    printf '   Run it on a laptop or CI instead. To override deliberately:\n'
    printf '     HARNESS_SUITE_ALLOW_LIVE_CELL=1 bash %s\n' "$suite"
  } >&2
  exit 78   # EX_CONFIG — a refusal, not a test failure
}

# ── grouped start ────────────────────────────────────────────────────────────────────────────────
fixture_start_group() { # <cmd...> -> prints the pid (== pgid) of the started process
  local pid
  # ⛔ THE CHILD'S STREAMS MUST BE SEVERED HERE, and the reason is measured: callers capture the pid
  # as `pid="$(fixture_start_group …)"` (a PIPE), and `$( … )` reads until EVERY writer closes it.
  # A live controller holds its inherited stdout for its whole lifetime, so the substitution would
  # BLOCK until the controller exited — the fixture would hang instead of returning an id. Same
  # defect class `refresh-candidates.sh` records as "the capture must not be a pipe".
  if command -v perl >/dev/null 2>&1; then
    # `setpgrp(0,0)` then `exec`: the process keeps perl's pid and already leads its own group, so
    # `$!` IS the pgid — no fork, no window in which we hold the wrong id.
    perl -e 'setpgrp(0,0); exec @ARGV' -- "$@" >/dev/null 2>&1 </dev/null &
  elif command -v setsid >/dev/null 2>&1; then
    setsid "$@" >/dev/null 2>&1 </dev/null &   # Linux: `setsid` execs in place for a non-leader, so `$!` is the leader
  else
    printf '  ⚠️  fixture-hermetic: neither perl nor setsid on PATH — starting in the CALLER group; the reaper can only signal the pid (children may survive)\n' >&2
    "$@" >/dev/null 2>&1 </dev/null &
  fi
  pid=$!
  [ -n "$FIXTURE_PGID_FILE" ] && printf '%s\n' "$pid" >> "$FIXTURE_PGID_FILE" 2>/dev/null
  printf '%s\n' "$pid"
}

# ── teardown ────────────────────────────────────────────────────────────────────────────────────
# ⬛ THE READ IS SEPARATE FROM THE ACT, on purpose. "Which groups survive" is EVIDENCE, and a reaper
# that signals and returns is indistinguishable from one that signalled the wrong id — the question in
# #3011 is whether the fixture is GONE, never whether the teardown ran. Separating them also makes the
# detector testable on its own: the contract suite drives `fixture_survivors` with a group left alive
# on purpose, so a green H4 cannot be a vacuous one (H5).
fixture_survivors() { # <pgid...> -> prints each survivor; returns the count (READ ONLY)
  local pgid survivors=0
  for pgid in "$@"; do
    case "$pgid" in ''|*[!0-9]*) continue ;; esac
    kill -0 -- "-$pgid" 2>/dev/null || continue
    survivors=$((survivors + 1))
    printf '  ❌ FIXTURE LEAK: process group %s survived the teardown\n' "$pgid" >&2
    # ⛔ NOT `ps -g`: on macOS `-g` selects by SECURITY GROUP, not process group, so it would print
    # the login user's whole process table as if it were the leak — the report would name everything
    # on the box and nothing about the fixture. Filter the process-group COLUMN instead (portable).
    ps -A -o pid=,ppid=,pgid=,args= -ww 2>/dev/null | awk -v g="$pgid" '$3 == g' | sed 's/^/       /' >&2
  done
  return "$survivors"
}

fixture_reap_all() { # -> 0 when every recorded group is gone; nonzero = number of survivors
  local pgid list alive i
  [ -n "$FIXTURE_PGID_FILE" ] && [ -f "$FIXTURE_PGID_FILE" ] || return 0
  list="$(sort -u "$FIXTURE_PGID_FILE" 2>/dev/null)"
  : > "$FIXTURE_PGID_FILE"          # truncate first: a re-entrant trap must not re-signal a recycled id
  [ -n "$list" ] || return 0
  for pgid in $list; do
    case "$pgid" in ''|*[!0-9]*) continue ;; esac
    kill -TERM -- "-$pgid" 2>/dev/null
  done
  i=0
  while [ "$i" -lt "$(( FIXTURE_REAP_GRACE * 5 ))" ]; do
    alive=""
    for pgid in $list; do kill -0 -- "-$pgid" 2>/dev/null && alive="$alive $pgid"; done
    [ -z "$alive" ] && break
    sleep 0.2; i=$((i + 1))
  done
  for pgid in $list; do
    kill -0 -- "-$pgid" 2>/dev/null || continue
    kill -KILL -- "-$pgid" 2>/dev/null
  done
  sleep 0.2
  # shellcheck disable=SC2086
  fixture_survivors $list
}

fixture_hermetic_init() { # <pgid-ledger-path> [temp-dir-to-remove]
  FIXTURE_PGID_FILE="$1"
  FIXTURE_TMP_TO_REMOVE="${2:-}"
  : > "$FIXTURE_PGID_FILE" 2>/dev/null || FIXTURE_PGID_FILE=""
  # shellcheck disable=SC2064
  trap 'fixture_teardown' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

fixture_teardown() {
  local rc=0
  fixture_reap_all || rc=1
  [ -n "$FIXTURE_TMP_TO_REMOVE" ] && rm -rf "$FIXTURE_TMP_TO_REMOVE"
  # A leak is a suite FAILURE, and the EXIT trap is the only place that can still say so: the
  # suite's own verdict was computed before its fixtures died. `exit` from an EXIT trap sets the
  # final status, which is what CI and `run-bash-shards.sh` read.
  [ "$rc" -eq 0 ] || exit 1
  return 0
}
