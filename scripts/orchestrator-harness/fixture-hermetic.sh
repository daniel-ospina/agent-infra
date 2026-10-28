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
# ⛔ WHY THE GROUP, AND WHEN `$!` IS (AND IS NOT) THE RIGHT ID.
# `harness-refresh.test.sh` starts its controller inside `$( ... )`, so the background job is a
# GRANDCHILD: killing the WRAPPER's id orphans the controller (the very shape #3011 is about, and
# `reap()` in that suite already documents a measured 9-survivor variant of it). So each fixture
# process is started in its OWN process group, and the group is what gets signalled.
# `$!` is used deliberately, and it is CORRECT on the tested paths: the pgid is established BEFORE
# `exec` (perl `setpgrp`, or `setsid`), so the process keeps its own pid and leads its own group —
# `$!` therefore IS the group leader's id. (That is the POSIX reason `setsid()` must be called by a
# NON-leader: a background child is not a leader, so the call succeeds and the new group id equals
# its pid.) What is NOT safe is assuming it always holds: on the fallback path below no group is
# created, so the recorded id is a plain pid. The teardown therefore RESOLVES the kind at signal time
# (`fixture_terminate` / `fixture_alive_id`) rather than assuming a group — see the residual note,
# which now describes what the code actually does.
# The portable idiom is the one `refresh-candidates.sh` already uses (`setpgrp`), NOT `setsid`,
# which macOS does not ship (verified: `command -v setsid` is empty on darwin, present on the cells).
#
# STATED RESIDUALS.
#   * Neither `perl` nor `setsid` on PATH: the fixture still runs, but in the CALLER's group, so the
#     reaper signals the PID alone (there is no group of ours to signal) and names that limit on
#     stderr. Descendants the fixture forked may survive; the fixture process itself is still
#     SIGNALLED AND VERIFIED dead. Both platforms we ship to have perl (verified darwin + the cell
#     image), so the tested path is always the group.
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
  # ⛔ THE DEFAULT SET MUST INCLUDE THE ENV'S OWN ANSWER. The orchestrator directory is configurable
  # (`deploy-mac-orchestrator.sh` sets `O="${O:-$HOME/orchestrator}"`), and this repo's own README
  # documents a real cell logging from `/home/cmux/orchestrator/…` — a path matching NEITHER
  # original root, so a genuinely live box was silently skipped and the guard abstained (review,
  # cycle 2). The roots above are real; the set was simply not closed over the two variables that
  # decide where the fleet actually lives.
  # `${FIXTURE_LIVE_ROOTS-…}` uses NO COLON on purpose: an explicitly EMPTY value then means "no
  # roots", which is the seam a minimal fixture uses. With `${…:-…}` an empty value silently fell
  # back to the host defaults, so that seam could never do what it said.
  local roots="${FIXTURE_LIVE_ROOTS-/tmp/cell-home /home/cmux/harness ${CELL_HOME:-} ${O:-$HOME/orchestrator}}"
  local r live_roots="" seen=" "
  for r in $roots; do
    [ -n "$r" ] || continue
    [ -d "$r" ] || continue
    case "$seen" in *" $r "*) continue ;; esac   # a root listed twice must not count two controllers
    seen="$seen$r "
    live_roots="$live_roots $r"
  done
  [ -n "$live_roots" ] || return 0
  # ONE `ps` for every root, and each process reported ONCE: scanning per root double-counted any
  # controller whose path matched two roots (e.g. `$HOME` and `$HOME/orchestrator`), inflating the
  # count in the refusal. `-ww` because `ps` otherwise truncates the command at the terminal width —
  # and the root path is exactly the part that gets cut, so the guard would abstain about a live cell.
  ps -A -o pid=,args= -ww 2>/dev/null | awk -v roots="$live_roots" '
    BEGIN { n = split(roots, R, " ") }
    /orch-loop\.sh/ {
      for (i = 1; i <= n; i++) if (R[i] != "" && index($0, R[i] "/")) { print $1, R[i]; next }
    }'
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
    printf '  ⚠️  fixture-hermetic: neither perl nor setsid on PATH — starting in the CALLER group; the reaper can only signal this pid (descendants it forks may survive)\n' >&2
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
# ── group-or-pid resolution ────────────────────────────────────────────────────────────────────
# ⛔ THE RECORDED ID IS NOT ALWAYS A GROUP. On the perl/setsid paths it is (the pgid is set before
# `exec`), so signal the GROUP: that ends the controller AND anything it forked. On the fallback
# path no group was created, so the id is a plain pid and `kill -TERM -- -<id>` hits NOTHING — which
# made a group-only reaper report "all gone" over a LIVE fixture: the exact false PASS #3011 is
# about, sitting on the one path its own stderr warning claimed to handle. So resolve at signal time,
# probing the GROUP first: a group whose leader has already exited still exists while its children
# live, and that is precisely the case an "is this pid a leader?" (`ps -o pgid=`) test gets WRONG.
fixture_terminate() { # <sig> <id> — the group when one exists, else the process
  case "${2:-}" in ''|*[!0-9]*) return 0 ;; esac
  if kill -0 -- "-$2" 2>/dev/null; then kill -"$1" -- "-$2" 2>/dev/null
  else kill -"$1" "$2" 2>/dev/null; fi
}

fixture_alive_id() { # <id> -> 0 when the recorded group OR process is still alive
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 -- "-$1" 2>/dev/null || kill -0 "$1" 2>/dev/null
}

fixture_survivors() { # <id...> -> prints each survivor; returns the count (READ ONLY)
  local id survivors=0 what
  for id in "$@"; do
    case "$id" in ''|*[!0-9]*) continue ;; esac
    fixture_alive_id "$id" || continue
    survivors=$((survivors + 1))
    if kill -0 -- "-$id" 2>/dev/null; then what="process group $id"; else what="pid $id"; fi
    printf '  ❌ FIXTURE LEAK: %s survived the teardown\n' "$what" >&2
    # ⛔ NOT `ps -g`: on macOS `-g` selects by SECURITY GROUP, not process group, so it would print
    # the login user's whole process table as if it were the leak — the report would name everything
    # on the box and nothing about the fixture. Filter the process-group COLUMN (and, on the fallback
    # path where the group is the CALLER's, the pid column) instead — that is portable.
    ps -A -o pid=,ppid=,pgid=,args= -ww 2>/dev/null | awk -v id="$id" '$3 == id || $1 == id' | sed 's/^/       /' >&2
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
    fixture_terminate TERM "$pgid"
  done
  i=0
  while [ "$i" -lt "$(( FIXTURE_REAP_GRACE * 5 ))" ]; do
    alive=""
    for pgid in $list; do fixture_alive_id "$pgid" && alive="$alive $pgid"; done
    [ -z "$alive" ] && break
    sleep 0.2; i=$((i + 1))
  done
  for pgid in $list; do
    fixture_alive_id "$pgid" || continue
    fixture_terminate KILL "$pgid"
  done
  sleep 0.2
  # shellcheck disable=SC2086
  fixture_survivors $list
}

fixture_hermetic_init() { # <pgid-ledger-path> [temp-dir-to-remove]
  FIXTURE_PGID_FILE="$1"
  FIXTURE_TMP_TO_REMOVE="${2:-}"
  # ⛔ A LEDGER THAT CANNOT BE WRITTEN TURNS THE REAPER INTO A NO-OP WITH NO MESSAGE: every record
  # would be silently skipped and `fixture_reap_all` would answer "nothing to do" forever — the same
  # "an enforcer that cannot fire" class the header calls category A. Refuse instead of degrading.
  : > "$FIXTURE_PGID_FILE" 2>/dev/null || {
    printf '  ❌ fixture-hermetic: cannot write the pgid ledger at %s — refusing to run fixtures that cannot be reaped\n' "$FIXTURE_PGID_FILE" >&2
    exit 2
  }
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
