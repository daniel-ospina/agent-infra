#!/usr/bin/env bash
# cloud-cell-quiesce.test.sh — the regression contract for the WIP-sweep hook (agent-infra#3485).
#
# ⛔ WHY THIS EXISTS. `cloud-cell-quiesce.sh` is the ONE path in this repo that hands a cell's disk on to
# be reclaimed. The hook added at step 3b is the only thing standing between a lane's uncommitted work and
# total loss on that row of the abandonment matrix, and until this file existed NOTHING asserted it: an
# edit could drop `--apply` (turning the hook into the report-only no-op its own comment rejects), move it
# below the re-seed/restart, or stop propagating the sweep's exit code — and every check would stay green
# while the quiesce printed `DONE` having archived nothing.
#
# WHAT IS PINNED, and each arm says which wrong outcome it catches:
#   A. the sweep is invoked, with `--apply` and an explicit `--repo "$REPO"`  (a report-only hook archives
#      nothing; an ambient repo would sweep a repo nobody asked about)
#   B. it runs AFTER the kill sweep and BEFORE the controller is started  (archiving after the restart
#      rescues a tree that has already been reopened)
#   C. a FAILING sweep does not stop supervision being restored — the controller is started anyway  (a
#      quiesce that aborts leaves the cell with zero controllers, worse than what it exists to fix)
#   D. a failing sweep makes the script exit NON-ZERO and prints `NOT DONE`  (a green exit with unarchived
#      work is the false PASS this hook exists to avoid)
#   E. a MISSING sweep is loud and non-zero, never silence
#
# HOW: every external command the script touches is stubbed on PATH, in a scratch tree, with an event log
# so ORDER is asserted rather than assumed. The fleet is never touched.
#
# ⛔ ONE HOST LIMIT, stated rather than skipped silently: step 7 reads `/proc/<pid>/environ`, which exists
# on the Linux cells this script is for and not on macOS. With no `/proc` the script exits 1 there, so the
# two exit-CODE arms are skipped loudly on such a host; every ordering arm (A-E) still runs, because they
# are asserted from the event log.
#
# Run:  bash scripts/cloud-cell-quiesce.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
Q="$HERE/cloud-cell-quiesce.sh"
[ -f "$Q" ] || { echo "❌ missing $Q"; exit 1; }

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
skip() { SKIP=$((SKIP+1)); echo "  ⏭  SKIP: $1"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/quiesce.XXXXXX")"
trap 'rm -rf "$T"' EXIT
echo "==> cloud-cell-quiesce WIP hook ($HERE)"
echo "    scratch: $T"
HAS_PROC=0; [ -d /proc ] && [ -r "/proc/$$/environ" ] && HAS_PROC=1

# mk_world <name> — a REPO with the stub supervisor + sweep, a HARNESS with claims.sh, a log.
mk_world() {
  local n="$1" d="$T/$1"
  mkdir -p "$d/repo/scripts/orchestrator-harness" "$d/repo/scripts" "$d/O" "$d/home" || return 1
  : > "$d/claims.sh" || return 1
  cp "$d/claims.sh" "$d/repo/scripts/orchestrator-harness/claims.sh" || return 1
  # Supervisor: logs stop/start, and toggles the "controller is running" flag the ps stub reads.
  printf '%s\n' '#!/usr/bin/env bash' \
    'echo "supervisor:$1" >> "'"$d"'/events"' \
    'case "$1" in' \
    '  start) : > "'"$d"'/running" ;;' \
    '  stop)  rm -f "'"$d"'/running" ;;' \
    'esac' \
    'exit 0' > "$d/repo/scripts/cloud-cell-supervisor.sh" || return 1
  chmod +x "$d/repo/scripts/cloud-cell-supervisor.sh"
  # The sweep stub: logs its argv and exits $SWEEP_RC (0 by default).
  printf '%s\n' '#!/usr/bin/env bash' \
    'echo "sweep:$*" >> "'"$d"'/events"' \
    'exit "${SWEEP_RC:-0}"' > "$d/repo/scripts/wip-sweep.sh" || return 1
  chmod +x "$d/repo/scripts/wip-sweep.sh"
  # PATH stubs for the process/tmux surface.
  mkdir -p "$d/bin"
  printf '%s\n' '#!/usr/bin/env bash' \
    'case "$*" in' \
    '  "kill-server"*) echo "tmux:kill-server" >> "'"$d"'/events"; rm -f "'"$d"'/running"; rm -f "'"$d"'/alive" ;;' \
    '  "ls"*) exit 0 ;;' \
    '  *) exit 0 ;;' \
    'esac' \
    'exit 0' > "$d/bin/tmux"
  printf '%s\n' '#!/usr/bin/env bash' \
    'echo "pkill:$*" >> "'"$d"'/events"' \
    'rm -f "'"$d"'/alive"' \
    'exit 0' > "$d/bin/pkill"
  # ps: one orch-loop line while the stub controller is "alive", none after the kill sweep.
  printf '%s\n' '#!/usr/bin/env bash' \
    'if [ -f "'"$d"'/running" ]; then echo "bash /tmp/cell/orch-loop.sh"; else echo "bash /tmp/cell/other.sh"; fi' \
    'exit 0' > "$d/bin/ps"
  # pgrep: a pid whose /proc environ carries REPO= (so step 7 verifies it) — the sleeper the caller
  # launches, or a harmless self-reference when there is no /proc.
  printf '%s\n' '#!/usr/bin/env bash' \
    'cat "'"$d"'/sleeper.pid" 2>/dev/null || echo $$' \
    'exit 0' > "$d/bin/pgrep"
  chmod +x "$d/bin/tmux" "$d/bin/pkill" "$d/bin/ps" "$d/bin/pgrep"
  return 0
}

# run_quiesce <name> [sweep-rc] — stubs on PATH, the fleet's own processes never touched.
run_quiesce() {
  local n="$1" rc="${2:-0}" d="$T/$1" sleeper=""
  if [ "$HAS_PROC" = 1 ]; then
    # A live process that carries REPO in its environ, so step 7's read-back finds the right value.
    REPO="$d/repo" OR="daniel-ospina/tortoise" SCOPE=own sleep 120 >/dev/null 2>&1 &
    sleeper=$!
    echo "$sleeper" > "$d/sleeper.pid"
  else
    echo "$$" > "$d/sleeper.pid"
  fi
  : > "$d/events"
# ⛔ HOME IS STUBBED TOO, AND THAT IS NOT TIDINESS (review finding). The script's FOURTH resolution
# candidate is `${HOME}/.pi/agent/scripts/wip-sweep.sh` — the path `pi-bootstrap/setup.sh`'s `fleet_srcs`
# fills on every farmed cell. Without overriding HOME, arm E ("a missing sweep") resolves the REAL farmed
# sweep on such a host: it then runs an unstubbed real tool and reports three false FAILs. This suite is
# green on an unfarmed box either way, which is exactly how that defect would survive — so HOME points
# into the scratch tree.
# ⛔ AND THE ASSIGNMENTS BELOW MUST STAY CONTIGUOUS. A `#` line inserted between a `\`-continued
# assignment and its continuation does not comment out a fragment: it ENDS the logical line, so the
# remaining assignments become a SEPARATE command and the prefix is silently dropped. Measured on a copy:
# `CELL_HOME`/`O`/`HARNESS` were dropped while `bash -n` still returned 0, so the suite ran against the
# wrong roots and reported nonsense instead of failing. Which of them survives a break depends on whether
# it was already exported — an already-exported `PATH` still propagates, a `CELL_HOME` set only here does
# not — so the blast radius varies with position rather than being fixed. The whole env block is therefore
# one block with NO comment inside it.
  PATH="$d/bin:$PATH" HOME="$d/home" \
  REPO="$d/repo" OR="daniel-ospina/tortoise" SCOPE=own MAX_LANES=3 \
  CELL_HOME="$d/home" O="$d/O" HARNESS="$d/repo/scripts/orchestrator-harness" \
  SWEEP_RC="$rc" bash "$Q" > "$d/out" 2>&1
  local st=$?
  [ -n "$sleeper" ] && kill "$sleeper" 2>/dev/null
  return "$st"
}

# ── A/B: invocation, arming, and ORDER ───────────────────────────────────────────────────────────────
echo; echo "── A/B. the sweep is invoked armed, after the kill and before the restart ──"
mk_world ab || { echo "❌ fixture failed (ab)"; exit 1; }
D="$T/ab"
echo alive > "$D/alive"
run_quiesce ab 0; RC=$?
SWLINE="$(grep -m1 '^sweep:' "$D/events" 2>/dev/null)"
[ -n "$SWLINE" ] && ok "A1 the quiesce INVOKES the sweep (the hook exists at all)" \
  || bad "A1 the quiesce never invoked the sweep — events: $(tr '\n' ' ' < "$D/events")"
case "$SWLINE" in
  *"--apply"*) ok "A2 it is ARMED (--apply) — a report-only hook on the path that destroys the disk archives nothing" ;;
  *) bad "A2 the sweep was invoked WITHOUT --apply: $SWLINE" ;;
esac
case "$SWLINE" in
  *"--repo $D/repo"*) ok "A3 it names --repo \"\$REPO\" explicitly (no ambient repo selection)" ;;
  *) bad "A3 the sweep was not given the intended --repo: $SWLINE" ;;
esac
# ORDER, read from the event log: kill sweep -> wip sweep -> controller start.
KILL_AT="$(grep -n 'tmux:kill-server\|^pkill:' "$D/events" | head -1 | cut -d: -f1)"
SWEEP_AT="$(grep -n '^sweep:' "$D/events" | head -1 | cut -d: -f1)"
START_AT="$(grep -n '^supervisor:start' "$D/events" | head -1 | cut -d: -f1)"
[ -n "$KILL_AT" ] && [ -n "$SWEEP_AT" ] && [ -n "$START_AT" ] \
  && [ "$KILL_AT" -lt "$SWEEP_AT" ] && [ "$SWEEP_AT" -lt "$START_AT" ] \
  && ok "B1 the ORDER is kill($KILL_AT) → sweep($SWEEP_AT) → start($START_AT) — archive before the tree is reopened" \
  || bad "B1 wrong order (kill=$KILL_AT sweep=$SWEEP_AT start=$START_AT) in: $(tr '\n' ' ' < "$D/events")"
grep -q '^supervisor:stop' "$D/events" \
  && ok "B2 the supervised controller was stopped first (the sweep runs against final trees)" \
  || bad "B2 the supervisor was never stopped"

# ── C/D: a FAILING sweep still restores supervision, and fails the run ───────────────────────────────
echo; echo "── C/D. a failing sweep does NOT leave the cell with zero controllers ──"
mk_world cd || { echo "❌ fixture failed (cd)"; exit 1; }
D="$T/cd"
echo alive > "$D/alive"
run_quiesce cd 4; RC=$?
grep -q '^supervisor:start' "$D/events" \
  && ok "C1 the controller WAS started despite the failing sweep (aborting here would leave zero controllers)" \
  || bad "C1 the quiesce aborted before restoring supervision — events: $(tr '\n' ' ' < "$D/events")"
[ "$RC" -ne 0 ] && ok "D1 a failing sweep makes the quiesce exit non-zero (rc=$RC)" \
               || bad "D1 a failing sweep exited 0 — unarchived work behind a green exit"
grep -q 'NOT DONE' "$D/out" \
  && ok "D2 it says NOT DONE rather than DONE" \
  || bad "D2 the run did not say NOT DONE: $(tail -2 "$D/out")"
grep -q 'FATAL: wip-sweep' "$D/out" \
  && ok "D3 the failure is LOUD (a FATAL line naming the sweep)" \
  || bad "D3 the failure was silent"

# ── E: a MISSING sweep ──────────────────────────────────────────────────────────────────────────────
echo; echo "── E. a missing sweep is loud and non-zero, never silence ──"
mk_world e || { echo "❌ fixture failed (e)"; exit 1; }
D="$T/e"
rm -f "$D/repo/scripts/wip-sweep.sh"
echo alive > "$D/alive"
run_quiesce e 0; RC=$?
grep -q 'FATAL: wip-sweep' "$D/out" \
  && ok "E1 a missing sweep prints a FATAL naming it" \
  || bad "E1 no FATAL for a missing sweep: $(tail -2 "$D/out")"
grep -q 'WORK ON THIS BOX WILL NOT BE ARCHIVED' "$D/out" \
  && ok "E2 it says the work will NOT be archived — a missing rescuer never reads as 'nothing to rescue'" \
  || bad "E2 the missing-sweep message does not state the consequence"
[ "$RC" -ne 0 ] && ok "E3 a missing sweep exits non-zero (rc=$RC)" || bad "E3 a missing sweep exited 0"
grep -q '^supervisor:start' "$D/events" \
  && ok "E4 supervision is still restored with no sweep present" \
  || bad "E4 the quiesce stopped before restoring supervision"

# ── the success arm (exit code is only judgeable where /proc exists) ─────────────────────────────────
echo; echo "── F. the success path ──"
mk_world f || { echo "❌ fixture failed (f)"; exit 1; }
D="$T/f"
echo alive > "$D/alive"
run_quiesce f 0; RC=$?
grep -q '^supervisor:start' "$D/events" \
  && ok "F1 the controller was started" || bad "F1 the controller was never started"
if [ "$HAS_PROC" = 1 ]; then
  [ "$RC" -eq 0 ] && ok "F2 an armed sweep that succeeded exits 0" || bad "F2 success path exited $RC (want 0): $(tail -3 "$D/out")"
  grep -q 'DONE — cell has exactly one controller' "$D/out" \
    && ok "F3 it says DONE" || bad "F3 no DONE line: $(tail -2 "$D/out")"
else
  skip "F2/F3 the success path's EXIT CODE needs /proc/<pid>/environ (step 7), absent on this host — the ordering arms above still ran"
fi

echo
echo "── summary ──"
echo "  PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
