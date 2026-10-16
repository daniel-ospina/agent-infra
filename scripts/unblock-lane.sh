#!/bin/bash
# unblock-lane.sh — kill ONE parked child and prove the parent resumed.
#
# Reports before it acts, and proves the effect afterwards: the whole point is that
# a parked child is invisible from the parent's side (the parent writes nothing while
# it waits), so "the parent resumed" has to be OBSERVED, not assumed.
#
# Three signals, all required (AGENTS.md):
#   1. zero CPU delta, tolerance stated   — measured separately, before this runs
#   2. ancestry walked to the top         — no Terminal.app / iTerm: agent-owned
#   3. progress vs the process's own bound — the harness bound, not a guess
#
# It is NOT tidiness: a parked child blocks a live lane, and the child's own work is
# already lost (nothing written for hours).
CHILD="$1"
SID="$2"
F=$(ls -1t "$HOME"/.pi/agent/sessions/*/*"$SID"*.jsonl 2>/dev/null | head -1)

before_size=$(stat -f %z "$F" 2>/dev/null)
before_cpu=$(ps -o time= -p "$CHILD" 2>/dev/null | tr -d ' ')
ppid=$(ps -o ppid= -p "$CHILD" 2>/dev/null | tr -d ' ')
p_cpu_before=$(ps -o time= -p "$ppid" 2>/dev/null | tr -d ' ')
echo "child  $CHILD  cpu=$before_cpu  ppid=$ppid (parent cpu=$p_cpu_before)"
echo "parent session: $(basename "$F")  size=$before_size"
echo "killing $CHILD ..."
kill "$CHILD" 2>/dev/null
sleep 3
if ps -o pid= -p "$CHILD" >/dev/null 2>&1; then
  echo "  still alive after SIGTERM; sending SIGKILL"
  kill -9 "$CHILD" 2>/dev/null
  sleep 2
fi
ps -o pid= -p "$CHILD" >/dev/null 2>&1 && echo "  STILL ALIVE" || echo "  child gone"

echo "watching the parent for 90s ..."
i=0
while [ "$i" -lt 30 ]; do
  now_size=$(stat -f %z "$F" 2>/dev/null)
  if [ -n "$now_size" ] && [ "$now_size" != "$before_size" ]; then
    echo "  PARENT RESUMED after $((i*3))s: session $before_size -> $now_size bytes"
    echo "  parent cpu: $p_cpu_before -> $(ps -o time= -p "$ppid" 2>/dev/null | tr -d ' ')"
    exit 0
  fi
  i=$((i+1)); sleep 3
done
echo "  parent has NOT written in 90s (size still $(stat -f %z "$F" 2>/dev/null))"
echo "  parent cpu: $p_cpu_before -> $(ps -o time= -p "$ppid" 2>/dev/null | tr -d ' ')"
echo "  -> the child was not what the parent was waiting on, OR the parent is wedged"
