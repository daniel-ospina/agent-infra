#!/usr/bin/env bash
# report.sh [<hours>] — what the orchestrator harness did in the last N hours (default 12).
#
#   O=/path/to/orchestrator REPO=/path/to/tortoise ./report.sh 6
#
# Reads ONLY durable artifacts — state/walltime.tsv, state/merged-*.done, state/parked-*,
# state/fixcount-*, $O/logs/orch-loop.log, the recorded harness stamp, and `origin`. It is
# READ-ONLY (no `gh` write, no tmux, no lock), so it is safe to run while the loop is working.
# Dependency-free beyond bash + git + gh + python3 (the last two only for the sections that need
# them; a missing one makes its section say so, never abort the report).
#
# The harness's per-box constants are the same three the other shipped scripts use, so a shell
# that already exports them for orch-loop.sh/install.sh needs no extra setup. `REPO` defaults to
# the tortoise checkout this box drains; override it for any other target.
set -u
H="${1:-12}"
case "$H" in ''|*[!0-9]*) H=12 ;; esac
O="${O:-$HOME/orchestrator}"
REPO="${REPO:-$HOME/eldato/tortoise}"
NOW=$(date +%s); FROM=$(( NOW - H * 3600 ))

# GNU `stat -c %Y` FIRST, then BSD `stat -f %m`. The reverse order is NOT safe: GNU `stat -f %m`
# treats `%m` as a second FILENAME, prints a whole filesystem-status block to stdout and only THEN
# errors, so `-f %m || -c %Y` captures that block CONCATENATED with the epoch — a multi-line value
# that `[ -ge ]` rejects, so every merge reads as outside the window. Each probe is validated
# numerically and empties on anything else, so a garbled value is "cannot judge", never a number.
mtime() {
  local m
  m="$(stat -c %Y "$1" 2>/dev/null || true)"; case "$m" in ''|*[!0-9]*) m="" ;; esac
  if [ -z "$m" ]; then m="$(stat -f %m "$1" 2>/dev/null || true)"; case "$m" in ''|*[!0-9]*) m="" ;; esac; fi
  [ -n "$m" ] && printf '%s' "$m"
}

echo "════════ orchestrator report — last ${H}h ($(date '+%Y-%m-%d %H:%M')) ════════"
echo
echo "── controller ──────────────────────────────────────────────"
if command -v launchctl >/dev/null 2>&1; then
  pid=$(launchctl list 2>/dev/null | awk '/orchestrator/{print $1}')
  if [ -n "${pid:-}" ]; then
    hb=$(cat "$O/heartbeat" 2>/dev/null || echo 0)
    echo "  UP (pid $pid)   heartbeat age: $(( NOW - hb ))s"
  else
    echo "  ⚠️  NOT RUNNING (no launchd job)"
  fi
else
  echo "  launchd absent — not a macOS box (check the process/tmux on this host)"
fi
sessions=0
command -v tmux >/dev/null 2>&1 && sessions=$(tmux ls 2>/dev/null | wc -l | tr -d ' ')
echo "  sessions: $sessions   load: $(uptime | sed -E 's/.*load averages?: ([0-9.]+).*/\1/')"
# ⛔ `wc -l < missing-file 2>/dev/null` still prints a bash REDIRECTION error: bash reports the
# failed `<` itself, before `wc` (and its `2>/dev/null`) runs. Guard the redirection instead.
queued=0; [ -r "$O/candidates.txt" ] && queued=$(wc -l < "$O/candidates.txt" | tr -d ' ')
dispatched=0; [ -r "$O/dispatched.txt" ] && dispatched=$(wc -l < "$O/dispatched.txt" | tr -d ' ')
echo "  backlog: $queued candidates queued   dispatched-to-date: $dispatched"
# Which harness commit this box runs (agent-infra#1745). Absent record reads UNKNOWN, never blank.
if [ -f "$O/.agent-infra-stamp.json" ]; then
  hc=$(sed -n 's/.*"commit"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$O/.agent-infra-stamp.json" | head -1)
  hr=$(sed -n 's/.*"relation"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$O/.agent-infra-stamp.json" | head -1)
  echo "  harness: ${hc:-UNKNOWN} [${hr:-unknown}]"
else
  echo "  harness: UNKNOWN (no $O/.agent-infra-stamp.json — run install.sh to record it)"
fi
echo

echo "── merges landed ───────────────────────────────────────────"
n=0; nums=""
for f in "$O"/state/merged-*.done; do
  [ -e "$f" ] || continue
  m=$(mtime "$f"); [ -n "$m" ] || continue
  if [ "$m" -ge "$FROM" ]; then
    n=$((n + 1)); nums="$nums $(basename "$f" | sed 's/merged-//; s/\.done//')"
  fi
done
[ -n "$nums" ] && printf '%s\n' $nums | sort -V | tr '\n' ' ' | fold -s -w 100 | sed 's/^/ /'
echo
echo "  → total in window: $n"
echo

echo "── agent wall-time (append-only series) ────────────────────"
python3 - "$O/state/walltime.tsv" "$FROM" <<'PY' 2>/dev/null || echo "  (python3 unavailable or the series is unreadable)"
import sys
path, frm = sys.argv[1], int(sys.argv[2])
try:
    rows = [l.split() for l in open(path) if l.strip()]
except (FileNotFoundError, PermissionError):
    print("  (no series yet)"); raise SystemExit
rows = [r for r in rows if len(r) >= 6 and r[0].isdigit() and r[3].isdigit() and r[4].isdigit() and int(r[0]) >= frm]
real = [r for r in rows if int(r[3]) > 100]
if not real:
    print("  (no agent runs in window)"); raise SystemExit
from collections import defaultdict
by = defaultdict(list)
for r in real:
    by[r[1]].append((int(r[3]), int(r[4])))
print(f"  {'kind':<9} {'n':>3} {'p50':>7} {'max':>7}  {'killed at cap':>14}")
for k in sorted(by):
    v = sorted(x[1] for x in by[k]); cap = by[k][0][0]
    hits = sum(1 for c, e in by[k] if e >= c - 2)
    print(f"  {k:<9} {len(v):>3} {v[len(v)//2]/60:>6.1f}m {max(v)/60:>6.1f}m  {hits:>4}/{len(v):<4} {100*hits/len(v):>3.0f}%")
tot = sum(len(v) for v in by.values()); hits = sum(1 for v in by.values() for c, e in v if e >= c - 2)
print(f"  → {hits}/{tot} runs ({100*hits/tot:.0f}%) ended at the cap = produced no result")
PY
echo

echo "── cross-box claims (what other machines can see) ─────────"
claims=0
if [ -d "$REPO" ] && command -v git >/dev/null 2>&1; then
  live=$(git -C "$REPO" ls-remote origin 'refs/claims/*' 2>/dev/null)
  claims=$(printf '%s\n' "$live" | grep -c 'refs/claims/' )
  printf '%s\n' "$live" | awk 'NF{print "  "$2}' | head -12
fi
echo "  → live: ${claims:-0}  (a claim with a live lease = a reviewer in flight on some box)"
echo

echo "── queue health ────────────────────────────────────────────"
if [ -d "$REPO" ] && command -v gh >/dev/null 2>&1; then
  open=$(cd "$REPO" && gh pr list --state open --limit 300 --json number --jq length 2>/dev/null)
  echo "  open PRs: ${open:-<could not read>}"
else
  echo "  open PRs: <needs a repo checkout and gh>"
fi
echo "  parked (needs a human): $(ls "$O"/state/parked-* 2>/dev/null | wc -l | tr -d ' ')"
cap=3
[ -n "${MAX_FIX_TRIES:-}" ] && case "$MAX_FIX_TRIES" in ''|*[!0-9]*) ;; *) cap="$MAX_FIX_TRIES" ;; esac
atcap=0
for f in "$O"/state/fixcount-*; do
  [ -e "$f" ] || continue
  c=$(cat "$f" 2>/dev/null)
  [ -n "$c" ] && [ "$c" -ge "$cap" ] 2>/dev/null && atcap=$((atcap + 1))
done
echo "  at fix-tries cap:       $atcap"
echo

echo "── last 8 dispatch decisions ───────────────────────────────"
grep -a "dispatch\]" "$O/logs/orch-loop.log" 2>/dev/null | tail -8 | sed 's/^/  /'
