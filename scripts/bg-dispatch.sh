#!/usr/bin/env bash
# bg-dispatch.sh <name> <worktree-dir> <prompt-file> [timeout-seconds]
#
# Launches a headless worker in the BACKGROUND and returns immediately, so the orchestrator can
# keep working instead of blocking on it. (The `task`/`subagent` tools block the caller — that is
# agent-infra#1662 — so this mirrors what lane.sh already does internally: `pi -p … &` plus a
# watchdog subshell, minus the `wait`.)
#
# Env mirrors lane.sh exactly, so a background worker behaves like a fleet lane: local review/VGATE
# gates bypassed (the PARENT is responsible for running the review gate on the result), no MCP
# servers (saves ~25 processes/run), no capture/skill/loop extensions.
set -u
NAME="$1"; WT="$2"; PROMPT="$3"; T="${4:-3000}"

O=/Users/home/orchestrator; D="$O/bg"; mkdir -p "$D"
LOG="$D/$NAME.log"; PIDF="$D/$NAME.pid"; STAMP="$D/$NAME.started"

[ -d "$WT" ]      || { echo "bg-dispatch: no worktree $WT" >&2; exit 2; }
[ -f "$PROMPT" ]  || { echo "bg-dispatch: no prompt $PROMPT" >&2; exit 2; }

cd "$WT" || exit 2
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
export AGENT_SKIP_REVIEW_GATE=1 ELDATO_SKIP_VGATE=1 AGENT_ALLOW_MAIN_EDITS=1 ELDATO_ALLOW_MAIN_EDITS=1
export PI_MCP_SERVERS=none
export PI_SKIP_VERSION_CHECK=1 SKILL_ENFORCER_DISABLED=1 LOOP_ENFORCER_DISABLED=1 \
       SLACK_BRIDGE_DISABLE=1 VISION_INTERCEPTOR_DISABLED=1

: > "$LOG"
printf 'name=%s\nworktree=%s\nbranch=%s\nprompt=%s\nstarted=%s\ncap=%ss\n' \
  "$NAME" "$WT" "$(git branch --show-current 2>/dev/null)" "$PROMPT" "$(date '+%Y-%m-%d %H:%M:%S')" "$T" > "$STAMP"

# The worker itself — backgrounded, NOT waited on.
nohup pi -p --provider deepseek --model deepseek-v4-flash --no-session "$(cat "$PROMPT")" >> "$LOG" 2>&1 &
PID=$!
echo "$PID" > "$PIDF"

# Watchdog: bound a hung worker (the harness's second line of defence is its stale-worker reaper).
# ⛔ THE KILL IS PRECEDED BY A RESCUE (agent-infra#2045). A lane that dies at its cap used to leave
# its whole working tree on this disk and nothing in the object database — measured overnight: 4 of 6
# lanes killed at the cap, 193-342 KB of reading each, ZERO commits, and the only durable copy of a
# verified fix was one a sibling lane happened to commit by hand. A cap that destroys work is a
# data-loss mechanism, so the worktree is archived to `origin refs/wip/<branch>` BEFORE the TERM and
# once more AFTER the KILL (the lane may write between the two). Rescue failure is reported, never
# silent: it means the work is still only on this disk.
_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_rescue() {
  [ -x "$_HERE/bg-rescue-wip.sh" ] || [ -f "$_HERE/bg-rescue-wip.sh" ] || return 0
  bash "$_HERE/bg-rescue-wip.sh" "$WT" "lane '$NAME' hit its ${T}s cap" >> "$LOG" 2>&1
}
( sleep "$T"; _rescue; kill -TERM "$PID" 2>/dev/null; sleep 20; _rescue; kill -KILL "$PID" 2>/dev/null ) >/dev/null 2>&1 &

# Durable record, so a later session can see what was dispatched and when.
mkdir -p "$O/state"
printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$NAME" "$(git branch --show-current 2>/dev/null)" "$PID" "$(date '+%H:%M:%S')" >> "$O/bg/dispatch-log.tsv"

disown "$PID" 2>/dev/null || true

# Announce completion. This launcher must return immediately, so a detached watcher owns the wait.
nohup bash "$D/on-exit.sh" "$PID" "$NAME" "$WT" >> "$D/notify.out" 2>&1 &
disown
echo "launched $NAME  pid=$PID  branch=$(git branch --show-current 2>/dev/null)  cap=${T}s"
echo "  log:      $LOG"
echo "  worktree: $WT"
