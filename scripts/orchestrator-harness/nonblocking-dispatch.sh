#!/usr/bin/env bash
# nonblocking-dispatch.sh <name> <worktree-dir> <prompt-file> [timeout-seconds]
# nonblocking-dispatch.sh --status <name>
#
# Launches a headless worker in the BACKGROUND and RETURNS IMMEDIATELY, so an orchestrator can keep
# working instead of blocking on it. (The built-in `task`/`subagent` tools block the caller — that is
# agent-infra#1662, "non-blocking dispatch is the one remaining structural gap"; this is the harness's
# own version of the shape #206 sanctions, with the status seam #1662 names as the missing piece.)
#
# ⛔ IT CARRIES NO AGENT INVOCATION OF ITS OWN. It backgrounds `run_agent()` from spawn-gate.sh, so a
# background worker gets the SAME load gate (agent-infra#1720), the same wall-clock watchdog and the
# same #1709 walltime row as `lane.sh` and `fix-one.sh`. The local copy this is ported from spawned
# `pi` itself with NO load gate — i.e. it was a fourth, ungated launch path, exactly what
# spawn-gate.test.sh's two-scope census exists to refuse (it asserts the invoker SET as an equality).
# Routing through the helper is the whole point of the port; do not "simplify" it back to a direct
# spawn, or the census goes red and a background worker starts landing on a saturated box.
set -u
NAME="${1:-}"
if [ "$NAME" = "--status" ]; then
  NAME="${2:-}"
  [ -n "$NAME" ] || { echo "usage: nonblocking-dispatch.sh --status <name>" >&2; exit 2; }
  O="${O:-$HOME/orchestrator}"; D="$O/bg"
  RC="$(cat "$D/$NAME.rc" 2>/dev/null || true)"
  PID="$(cat "$D/$NAME.pid" 2>/dev/null || true)"
  # ⛔ LIVENESS IS NOT %CPU. `%CPU == 0` means WAITING, not finished — a lane blocked in a long tool
  # call sits at 0 % CPU (docs/ops/fleet-liveness.md). The authoritative signal is the worker's own
  # exit-status file, written by the subshell below; the pid probe only distinguishes
  # running from vanished.
  if [ -n "$RC" ]; then
    [ "$RC" = "0" ] && echo "$NAME done rc=0" || echo "$NAME failed rc=$RC"
  elif [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    echo "$NAME running pid=$PID"
  else
    # No status file and no live pid: the worker is gone and its verdict was never recorded. Say so
    # rather than reporting a success that nothing produced.
    echo "$NAME lost (no exit status recorded and pid ${PID:-<unknown>} is gone) log=$D/$NAME.log"
  fi
  exit 0
fi
WT="${2:-}"; PROMPT="${3:-}"; T="${4:-3000}"
if [ -z "$NAME" ] || [ -z "$WT" ] || [ -z "$PROMPT" ]; then
  echo "usage: nonblocking-dispatch.sh <name> <worktree-dir> <prompt-file> [timeout-seconds]" >&2
  echo "       nonblocking-dispatch.sh --status <name>" >&2
  exit 2
fi
case "${T:-}" in ''|*[!0-9]*) echo "nonblocking-dispatch.sh: timeout '$T' is not a positive integer" >&2; exit 2 ;; esac

O="${O:-$HOME/orchestrator}"; D="$O/bg"; mkdir -p "$D" "$O/state"
# ⛔ PATH FIRST, then source — this part IS lane.sh/fix-one.sh's rule. spawn-gate.sh derives `_NCPU`
# at SOURCE time (sysctl/nproc/getconf), so sourcing it under a cell's pre-export PATH pins
# `_NCPU=4` / `MAX_LOAD=40` for every cell (agent-infra#1702). The two siblings carry the same ⛔.
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
# ⛔ AND RE-ASSERT THE gh LIMIT LAYER AFTER IT (#1988) — the same rule lane.sh / fix-one.sh /
# merge-one.sh / chain-merge.sh carry. This script does not call `gh` itself, but it SPAWNS a whole
# worker session IN-PROCESS (`run_agent` inherits this environment), so without these two lines every
# `gh` that worker runs resolves to `/opt/homebrew/bin/gh` — the layer would be deployed and inert,
# which is exactly the state the issue exists to remove. Grouped so the population check in
# `gh-limit.test.sh` sees them.
if [ -d "$O/gh-limit" ]; then PATH="$O/gh-limit:$PATH"; fi
if [ -d "$O/gh-rest" ]; then PATH="$O/gh-rest:$PATH"; fi
# The RESOLUTION, though, mirrors merge-one.sh's repo-authority.sh — NOT lane.sh/fix-one.sh, which
# source only `$SELF/spawn-gate.sh` and never consult `$O`. Prefer the daemon's copy at `$O`, fall
# back to the copy beside THIS script; an unresolved helper must never degrade into "the worker ran".
if [ -f "$O/spawn-gate.sh" ]; then . "$O/spawn-gate.sh"; HARNESS="$O"
else
  HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  . "$HARNESS/spawn-gate.sh" 2>/dev/null \
    || { echo "nonblocking-dispatch.sh: spawn-gate.sh not found (looked in $O and ${HARNESS:-<unresolved>}) — refusing to start an ungated worker" >&2; exit 78; }
fi
command -v run_agent >/dev/null 2>&1 \
  || { echo "nonblocking-dispatch.sh: spawn-gate.sh is stale (no run_agent) — refusing to start an ungated worker" >&2; exit 78; }

[ -d "$WT" ]     || { echo "nonblocking-dispatch.sh: no worktree $WT" >&2; exit 2; }
[ -f "$PROMPT" ] || { echo "nonblocking-dispatch.sh: no prompt file $PROMPT" >&2; exit 2; }

LOG="$D/$NAME.log"; RC="$D/$NAME.rc"; PIDF="$D/$NAME.pid"; STAMP="$D/$NAME.started"
# The worker is a fleet lane in every respect except that nobody waits for it: the local review/VGATE
# gates are bypassed so the PARENT owns the review ceremony, and no MCP servers are started.
export AGENT_SKIP_REVIEW_GATE=1 ELDATO_SKIP_VGATE=1 AGENT_ALLOW_MAIN_EDITS=1 ELDATO_ALLOW_MAIN_EDITS=1
export PI_MCP_SERVERS=none
export PI_SKIP_VERSION_CHECK=1 SKILL_ENFORCER_DISABLED=1 LOOP_ENFORCER_DISABLED=1 \
       SLACK_BRIDGE_DISABLE=1 VISION_INTERCEPTOR_DISABLED=1
KIND=bg; TAG="$NAME"; export KIND TAG

rm -f "$RC"
: > "$LOG"
printf 'name=%s\nworktree=%s\nbranch=%s\nprompt=%s\nstarted=%s\ncap=%ss\n' \
  "$NAME" "$WT" "$(git -C "$WT" branch --show-current 2>/dev/null)" "$PROMPT" \
  "$(date '+%Y-%m-%d %H:%M:%S')" "$T" > "$STAMP"

cd "$WT" || exit 2
# The worker itself — backgrounded, NOT waited on. `trap '' HUP` + `disown` let it outlive the
# orchestrator that dispatched it; `<&-` closes stdin so it cannot steal the parent's tty input.
( trap '' HUP; run_agent "$T" "$LOG" "$PROMPT" "bg $NAME"; echo "$?" > "$RC" ) <&- &
PID=$!
echo "$PID" > "$PIDF"
disown "$PID" 2>/dev/null || true

# Durable record, so a later session can see what was dispatched and when (and can find the exit
# status later via `--status`, rather than inferring it from a log tail).
mkdir -p "$O/state" "$D"
printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$NAME" "$(git branch --show-current 2>/dev/null)" "$PID" "$(date '+%H:%M:%S')" >> "$D/dispatch-log.tsv"

echo "launched $NAME  pid=$PID  branch=$(git branch --show-current 2>/dev/null)  cap=${T}s"
echo "  log:     $LOG"
echo "  status:  bash $0 --status $NAME"
echo "  worktree: $WT"
echo "NOTE: nothing reviews this worker's PR — AGENT_SKIP_REVIEW_GATE=1 is exported above, so the"
echo "      PARENT owns the review gate. Hand the PR to the chain when it appears:"
echo "  chain:   bash $HARNESS/chain-merge.sh <repo-path> <owner/repo> <issue> <branch>"
