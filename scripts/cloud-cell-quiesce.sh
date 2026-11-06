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

# Locate the WIP sweep (agent-infra#3485). It lives beside bg-rescue-wip.sh in the clone's scripts/
# (they are a pair: the sweep classifies with `bg-rescue-wip.sh --verdict` and archives with
# `bg-rescue-wip.sh`), with the runtime dir and the farmed home as fallbacks.
SWEEP=""
for c in "$REPO/scripts/wip-sweep.sh" \
         "$REPO/.harness-path/scripts/wip-sweep.sh" \
         "$O/wip-sweep.sh" \
         "${HOME:-/nonexistent}/.pi/agent/scripts/wip-sweep.sh"; do
  [ -f "$c" ] && { SWEEP="$c"; break; }
done
step "wip-sweep: ${SWEEP:-<none found — WORK ON THIS BOX WILL NOT BE ARCHIVED>}"

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

# 3b. ⛔ ARCHIVE EVERY DIRTY WORKTREE BEFORE THIS BOX IS HANDED ON (#3485) — THE TOTAL-LOSS ROW.
# A lane's uncommitted work is rescued by `bg-rescue-wip.sh` from inside `run_agent`, so it survives a
# cap kill. It does NOT survive the two routes that bypass that function, and this script is one of
# them: an OOM-killed lane, or any lane this quiesce just killed, leaves its work in the working tree
# and nothing in the object database. Everything else this script does — kill the sessions, re-seed,
# restart — is fine; reclaiming or rebuilding the VM afterwards is what makes the disk stop existing.
# `refs/wip/*` lives on ORIGIN, so archiving is what turns "the work was on that box" into "the work is
# still there".
#
# ARMED (`--apply`), and that is a deliberate departure from the #1678 rule that a tool acting on a box
# ships dry-run: that rule governs DELETION, where the default must be safe. This ADDS data to origin
# and touches nothing locally (a throwaway index, no branch move, no working-tree write), and a
# dry-run-by-default hook on the path that destroys the disk would archive nothing for ever while
# reading as a safeguard — the inert-enforcer shape.
#
# ⛔ THE FAILURE IS LOUD AND IT IS NOT SWALLOWED, BUT IT DOES NOT STOP SUPERVISION BEING RESTORED.
# Aborting here would leave the cell with ZERO controllers — a worse state than the one this script
# exists to end. So the pass runs to completion and this script exits NON-ZERO at the end, which is
# what `cloud-cell-bringup.sh --check` and the operator read. A missing sweep is the same class as a
# failing one: "a missing rescuer must never read as nothing to rescue".
WIP_RC=0; WIP_WHY=""
if [ -z "$SWEEP" ]; then
  WIP_RC=3; WIP_WHY="wip-sweep.sh not found (looked at \$REPO/scripts, \$REPO/.harness-path/scripts, $O, \$HOME/.pi/agent/scripts)"
  step "FATAL: wip-sweep: $WIP_WHY"
  step "FATAL: wip-sweep: UNCOMMITTED WORK ON THIS BOX WAS NOT ARCHIVED. Any dirty worktree here is lost if this cell is reclaimed."
else
  step "wip-sweep: archiving uncommitted work to refs/wip/* on origin BEFORE this cell is handed on"
  WIP_OUT="$(O="$O" WIP_SWEEP_STATE_DIR="$O/state" bash "$SWEEP" --apply --repo "$REPO" 2>&1)"; WIP_RC=$?
  printf '%s\n' "$WIP_OUT" | sed 's/^/  wip-sweep: /'
  case "$WIP_RC" in
    0) step "wip-sweep: every dirty worktree of $REPO is archived on origin (other clones on this box were NOT swept)" ;;
    1) WIP_WHY="the pass was INCOMPLETE (exit 1: work was deferred by the per-pass cap or the budget, so it is NOT archived)"
       step "FATAL: wip-sweep: $WIP_WHY" ;;
    *) WIP_WHY="the pass FAILED (exit $WIP_RC) — see the run above"
       step "FATAL: wip-sweep: $WIP_WHY"
       step "FATAL: wip-sweep: work on this box is NOT fully archived; it is LOST if this cell is reclaimed. Record: $O/state/wip-sweep.tsv" ;;
  esac
fi

# 4. Re-seed the runtime from the harness (the source of truth) and restart ONE.
[ -d "$REPO" ] || { step "FATAL: no clone at $REPO"; exit 1; }
[ -f "$HARNESS/claims.sh" ] || { step "FATAL: no claims.sh in $HARNESS"; exit 1; }
mkdir -p "$O"
cp "$HARNESS"/*.sh "$O"/ 2>/dev/null || true
step "seeded $O with $(ls "$O"/*.sh 2>/dev/null | wc -l | tr -d ' ') scripts (claims.sh: $([ -f "$O/claims.sh" ] && echo yes || echo NO))"

# 5. Start exactly one controller.
step "starting controller: OR=$OR REPO=$REPO SCOPE=$SCOPE MAX_LANES=$MAX_LANES"
if [ -n "$SW" ]; then
  # ⛔ ORCH_FOREGROUND DESCRIBES THE CALLER, AND THIS CALLER IS NOT THE SERVICE MANAGER (review P1 round 19,
  # #2402 / C). The unit exports `ORCH_FOREGROUND=1` and every lane shell inherits it through the tmux server
  # the controller created; quiesce is the LAST unpinned `start` caller. It is also the worst one to leave
  # unpinned: quiesce STOPS the unit a few lines above, so `foreground_handover` has nothing to wait for and
  # `start` execs `orch-loop.sh` inside quiesce's own child — a dispatcher OUTSIDE the unit's cgroup while the
  # enabled unit is stopped. Quiesce's own "exactly one orch-loop" assertions then pass and it prints DONE:
  # the cell is left unsupervised with a green report, which is #2402 restored silently.
  CELL_HOME="$CELL_HOME" ENV_FILE="$ENV_FILE" REPO="$REPO" O="$O" OR="$OR" \
    SCOPE="$SCOPE" MAX_LANES="$MAX_LANES" ORCH_FOREGROUND=0 \
    bash "$SW" start >/dev/null 2>&1 || true
else
  # Direct start, mirroring the supervisor's launch line.
  #
  # ⛔ `unset GH_REPO` AFTER `set +a`, the same two-token strip the supervisor's session command
  # carries: `$ENV_FILE` is re-sourced INSIDE the session, so a global `export GH_REPO=…` in it
  # answers every `gh` call that omits `--repo` from this controller onward — the #2235 fail-open
  # (a rail printing '✅ PR #2232 is ALREADY MERGED' for a tortoise PR while grading agent-infra).
  # This path builds its OWN session instead of going through the supervisor, so it needs its own
  # strip; `cloud-cell-supervisor.test.sh` §12 pins the supervisor's two and cannot see this one.
  #
  # ⛔ WHY THESE COMMENTS ARE HERE AND NOT INSIDE THE CONTINUATION BELOW (#2235 review P1): a
  # backslash-newline is joined LEXICALLY, so a `#` line placed between `tmux new-session … \` and
  # the command string ENDS THE COMMAND — tmux then starts a bare default shell named `orch` with
  # NO command argument, the string runs as a separate command (127, swallowed by `2>/dev/null ||
  # true`), and the script reports success having started nothing. Verified by the reviewer with a
  # stub `tmux` recording `new-session -d -s orch -c <dir>` and no argv[7].
  tmux new-session -d -s orch -c "$HARNESS" \
    "set -a; [ ! -f '$ENV_FILE' ] || . '$ENV_FILE'; set +a; unset GH_REPO; \
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

# 8. The quiesce is only DONE when the work that was on this box is on origin (#3485). One controller
# restored AND zero archived work is not a success: the next reclaim takes the work with it. Reported
# last, so the operator sees the true state of the cell, and via the exit code, so a scripted bring-up
# sees it too.
if [ "$WIP_RC" != "0" ]; then
  step "NOT DONE — one controller IS restored on $REPO, but the WIP archive did not complete: $WIP_WHY"
  exit 1
fi
step "DONE — cell has exactly one controller on $REPO"
