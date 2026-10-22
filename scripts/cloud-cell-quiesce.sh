#!/usr/bin/env bash
# cloud-cell-quiesce.sh — reset ONE cloud cell to a single, known controller.
#
# Why this exists: a cell accumulates tmux sessions and orch-loop processes from
# every earlier configuration it ever ran. A `ps | grep orch-loop | head -1` check
# shows one and hides the rest, so a cell can silently be draining TWO repos at
# once (observed 2026-10-14: cell 2 held 3 orch-loop processes and sessions in
# both /tmp/cell-ai and /tmp/cell-t). This makes the cell's actor set exactly one.
#
# Usage (on the cell):
#   REPO=/tmp/cell OR=daniel-ospina/tortoise SCOPE=own MAX_LANES=3 \
#     bash cloud-cell-quiesce.sh
#
# Env: REPO (required) OR (required) SCOPE (default own) MAX_LANES (default 3)
#      CELL_HOME (default /tmp/cell-home) ENV_FILE (default $CELL_HOME/keys.env)
#      HARNESS (default $REPO/scripts/orchestrator-harness)
set -uo pipefail

REPO="${REPO:?REPO is required}"
OR="${OR:?OR is required}"
SCOPE="${SCOPE:-own}"
MAX_LANES="${MAX_LANES:-3}"
CELL_HOME="${CELL_HOME:-/tmp/cell-home}"
ENV_FILE="${ENV_FILE:-$CELL_HOME/keys.env}"
O="${O:-$CELL_HOME/orchestrator}"
HARNESS="${HARNESS:-$REPO/scripts/orchestrator-harness}"

step() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

step "=== QUIESCE REPO=$REPO OR=$OR SCOPE=$SCOPE ==="

# 1. Before: record what was actually there, so the change is auditable.
step "before: $(ps -eo args 2>/dev/null | grep -c '[o]rch-loop\.sh') orch-loop process(es)"
ps -eo etime,args 2>/dev/null | grep '[o]rch-loop\.sh' | sed 's/^/  before: /' | cut -c1-160
step "before: $(tmux ls 2>/dev/null | wc -l | tr -d ' ') tmux session(s)"
tmux ls 2>/dev/null | cut -d: -f1 | while read -r s; do
  p="$(tmux list-panes -t "$s" -F '#{pane_current_path}' 2>/dev/null | head -1)"
  printf '  before: %-16s -> %s\n' "$s" "$p"
done

# Locate the supervisor. It is NOT in the harness dir: the cells keep it at
# <clone>/scripts/cloud-cell-supervisor.sh (agent-infra) or in the runtime dir.
SW=""
for c in "$REPO/scripts/cloud-cell-supervisor.sh" \
         "$O/cloud-cell-supervisor.sh" \
         /tmp/cell-ai/scripts/cloud-cell-supervisor.sh \
         /tmp/cell/scripts/cloud-cell-supervisor.sh; do
  [ -f "$c" ] && { SW="$c"; break; }
done
step "supervisor: ${SW:-<none found — will start tmux directly>}"

# 2. Stop the supervised controller, then kill EVERY session and ANY stray
#    controller. tmux kill-server is the only reliable sweep: kill-session -t orch
#    leaves the fix-*/merge-*/chain-* sessions (and their claim leases) behind.
[ -n "$SW" ] && bash "$SW" stop >/dev/null 2>&1 || true
tmux kill-server >/dev/null 2>&1 || true
sleep 2
# The bracket keeps this pattern from matching this script's own argv.
pkill -f '[o]rch-loop\.sh' >/dev/null 2>&1 || true
pkill -f '[m]erge-one\.sh' >/dev/null 2>&1 || true
pkill -f '[f]ix-one\.sh' >/dev/null 2>&1 || true
sleep 2

# 3. Prove the sweep is complete before restarting — a restart on a dirty cell
#    just re-creates the problem we are here to fix.
LEFT="$(ps -eo args 2>/dev/null | grep -c '[o]rch-loop\.sh')"
if [ "$LEFT" != "0" ]; then
  step "FATAL: $LEFT orch-loop process(es) survived the sweep"
  ps -eo pid,etime,args 2>/dev/null | grep '[o]rch-loop\.sh' | cut -c1-160
  exit 1
fi
step "sweep clean: 0 orch-loop, $(tmux ls 2>/dev/null | wc -l | tr -d ' ') tmux session(s)"

# 4. Re-seed the runtime from the harness (the source of truth) and restart ONE.
[ -d "$REPO" ] || { step "FATAL: no clone at $REPO"; exit 1; }
[ -f "$HARNESS/claims.sh" ] || { step "FATAL: no claims.sh in $HARNESS"; exit 1; }
mkdir -p "$O"
cp "$HARNESS"/*.sh "$O"/ 2>/dev/null || true
step "seeded $O with $(ls "$O"/*.sh 2>/dev/null | wc -l | tr -d ' ') scripts (claims.sh: $([ -f "$O/claims.sh" ] && echo yes || echo NO))"

# 5. Start exactly one controller.
step "starting controller: OR=$OR REPO=$REPO SCOPE=$SCOPE MAX_LANES=$MAX_LANES"
if [ -n "$SW" ]; then
  CELL_HOME="$CELL_HOME" ENV_FILE="$ENV_FILE" REPO="$REPO" O="$O" OR="$OR" \
    SCOPE="$SCOPE" MAX_LANES="$MAX_LANES" \
    bash "$SW" start >/dev/null 2>&1 || true
else
  # Direct start, mirroring the supervisor's launch line.
  tmux new-session -d -s orch -c "$HARNESS" \
    "set -a; [ ! -f '$ENV_FILE' ] || . '$ENV_FILE'; set +a; \
     HOME='$CELL_HOME' REPO='$REPO' O='$O' OR='$OR' SCOPE='$SCOPE' MAX_LANES='$MAX_LANES' \
     bash '$O/orch-loop.sh' >> '$O/logs/orch-loop.log' 2>&1" >/dev/null 2>&1 || true
fi

for _ in 1 2 3 4 5 6 7 8 9 10; do
  sleep 3
  n="$(ps -eo args 2>/dev/null | grep -c '[o]rch-loop\.sh')"
  [ "$n" = "1" ] && break
done

# 6. After: assert the invariant. ONE controller, and it is on the intended repo.
AFTER="$(ps -eo args 2>/dev/null | grep -c '[o]rch-loop\.sh')"
step "after: $AFTER orch-loop process(es), $(tmux ls 2>/dev/null | wc -l | tr -d ' ') session(s) $(tmux ls 2>/dev/null | cut -d: -f1 | tr '\n' ' ')"
if [ "$AFTER" != "1" ]; then
  step "FATAL: expected exactly 1 controller, found $AFTER"
  ps -eo pid,etime,args 2>/dev/null | grep '[o]rch-loop\.sh' | cut -c1-160
  exit 1
fi

# 7. Confirm it is pointed at the right repo, read from the live process env.
PID="$(pgrep -f '[o]rch-loop\.sh' | head -1)"
EFF_REPO="$(tr '\0' '\n' < "/proc/$PID/environ" 2>/dev/null | grep '^REPO=' | head -1)"
EFF_OR="$(tr '\0' '\n' < "/proc/$PID/environ" 2>/dev/null | grep '^OR=' | head -1)"
EFF_SCOPE="$(tr '\0' '\n' < "/proc/$PID/environ" 2>/dev/null | grep '^SCOPE=' | head -1)"
step "live controller pid=$PID  $EFF_REPO  $EFF_OR  $EFF_SCOPE"
case "$EFF_REPO" in
  "REPO=$REPO") : ;;
  *) step "FATAL: live REPO does not match intended ($EFF_REPO vs REPO=$REPO)"; exit 1 ;;
esac
step "DONE — cell has exactly one controller on $REPO"
