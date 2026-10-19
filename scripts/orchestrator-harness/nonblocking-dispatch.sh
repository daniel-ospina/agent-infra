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
  # ⛔ A CAP KILL IS ITS OWN FACT (#2045). A lane killed at its wall-clock cap used to be
  # indistinguishable from one that finished with nothing to do: the launcher recorded a bare exit
  # status, `pi -p`'s buffered output is lost on SIGTERM, and the work it had already done sat
  # uncommitted in a temp worktree while the only signal was an absence. The worker now publishes a
  # `.cap` marker (cap seconds + the verified snapshot run_agent wrote), so this line NAMES the cap
  # and the preserved work instead of reporting a bare `rc=143` — or, worse, `commits=0`.
  CAPNOTE=""
  if [ -f "$D/$NAME.cap" ]; then
    # awk, not `sed | head`: this runs on an operator's status call, and a pipeline whose reader exits
    # early is the SIGPIPE shape `scripts/check-no-sigpipe-grep.sh` exists to keep out of the tree.
    CAPNOTE="$(awk -F= '/^note=/{sub(/^note=/, ""); print; exit}' "$D/$NAME.cap" 2>/dev/null)"
  fi
  # ⛔ LIVENESS IS NOT %CPU. `%CPU == 0` means WAITING, not finished — a lane blocked in a long tool
  # call sits at 0 % CPU (docs/ops/fleet-liveness.md). The authoritative signal is the worker's own
  # exit-status file, written by the subshell below; the pid probe only distinguishes
  # running from vanished.
  if [ -n "$RC" ]; then
    if [ "$RC" = "0" ]; then
      printf '%s done rc=0%s\n' "$NAME" "${CAPNOTE:+ (${CAPNOTE})}"
    else
      printf '%s failed rc=%s%s\n' "$NAME" "$RC" "${CAPNOTE:+ (${CAPNOTE})}"
    fi
  elif [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    echo "$NAME running pid=$PID"
  else
    # No status file and no live pid: the worker is gone and its verdict was never recorded. Say so
    # rather than reporting a success that nothing produced.
    printf '%s lost (no exit status recorded and pid %s is gone) log=%s%s\n' "$NAME" "${PID:-<unknown>}" "$D/$NAME.log" "${CAPNOTE:+ (${CAPNOTE})}"
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
CAPF="$D/$NAME.cap"   # written by the worker below when the wall-clock cap fired (#2045)
rm -f "$CAPF"
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
# ⛔ `exec >/dev/null 2>&1` IS LOAD-BEARING, NOT TIDINESS. Without it the worker INHERITS this
# script's stdout/stderr, so a caller that runs this script with its output CAPTURED (a pipe)
# blocks on EOF for the worker's ENTIRE LIFE, not for this script's exit: `subprocess.run(...
# capture_output=True)` measured 5.02 s for a 5 s worker vs 0.03 s non-captured. A "non-blocking"
# dispatcher that holds its caller for the length of the job is worse than a blocking one, because
# the caller believes it returned. run_agent writes everything it has to say to "$LOG", so
# nothing is lost by closing these.
( trap '' HUP
  # ⛔ RESOLVED BY UNION (#2045 rebase): main's `exec` redirection (see the block above) is kept
  # here, inside the PR's cap-marker block. Every write below is explicitly redirected to a
  # file, so closing these fds loses nothing.
  exec >/dev/null 2>&1
  run_agent "$T" "$LOG" "$PROMPT" "bg $NAME"
  rc=$?
  # ⛔ `.cap` BEFORE `.rc` (VGATE cycle 4, nit 1): `--status` reads `.rc` FIRST, so writing the exit
  # status before the note leaves a window in which a cap kill reads as a bare `failed rc=143` with
  # no explanation, and a test asserting the note could flake on it. In this order a status read sees
  # either "running" (no .rc yet) or a verdict WITH its note — never a verdict stripped of it.
  if [ "${AGENT_CAP_HIT:-0}" = "1" ]; then
    # ⛔ THE NOTE FOLLOWS `WIP_SNAPSHOT_RESULT`, NEVER THE PRESENCE OF A DIRECTORY (#2045, VGATE
    # cycle 3). An earlier version keyed on `-n "$WIP_SNAPSHOT_DIR"` and fell through to
    # "the worktree was CLEAN, nothing was lost" when the snapshot FAILED — so a cap kill on a full
    # disk, the leading cell failure mode, would have reported that nothing was lost over work that
    # existed only in a worktree about to be reaped. That is #2045's own defect, one layer up.
    case "${WIP_SNAPSHOT_RESULT:-}" in
      COMPLETE)
        note="cap ${T}s hit — COMPLETE WIP snapshot: ${WIP_SNAPSHOT_DIR:-<unrecorded>}" ;;
      PARTIAL)
        # A PARTIAL snapshot is a rescue aid, NOT a licence to reap: say so here, where an operator
        # reads it, rather than only in the log (VGATE cycle 8, P2).
        note="cap ${T}s hit — PARTIAL WIP snapshot (INCOMPLETE: the worktree is still the only full copy, do NOT reap it): ${WIP_SNAPSHOT_DIR:-<unrecorded>}" ;;
      NOTHING-LOST)
        note="cap ${T}s hit — the worktree was CLEAN, nothing was lost" ;;
      *)
        note="cap ${T}s hit — WORK NOT PRESERVED (${WIP_SNAPSHOT_RESULT:-unknown}): it is still only in the worktree, so do NOT reap it. See $LOG" ;;
    esac
    printf 'cap_s=%s\nresult=%s\nsnapshot=%s\nnote=%s\n' "$T" "${WIP_SNAPSHOT_RESULT:-none}" "${WIP_SNAPSHOT_DIR:-}" "$note" > "$CAPF"
  fi
  echo "$rc" > "$RC"
) <&- &
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
