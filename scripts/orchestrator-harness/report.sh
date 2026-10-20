#!/usr/bin/env bash
# report.sh [<hours>] — what the orchestrator harness did in the last N hours (default 12).
#
#   O=/path/to/orchestrator REPO=/path/to/tortoise ./report.sh 6
#
# Reads ONLY durable artifacts — state/walltime.tsv, state/merged-*.done, state/parked-*,
# state/fixcount-*, state/needsreview-* (the open-PR stale-evidence queue, #2132),
# $O/logs/orch-loop.log, the recorded harness stamp, and `origin`. It is READ-ONLY (no `gh` write, no
# tmux, no lock), so it is safe to run while the loop is working.
# Dependency-free beyond bash + git + gh + python3 (the last two only for the sections that need
# them; a missing one makes its section say so, never abort the report).
#
# The harness's per-box constants are the same three the other shipped scripts use, so a shell
# that already exports them for orch-loop.sh/install.sh needs no extra setup. `REPO` defaults to
# the tortoise checkout this box drains; override it for any other target.
set -u
H="${1:-12}"
# ⛔ `0[0-9]*` too: a leading zero is OCTAL to `$(( ))`. Measured pre-fix: `report.sh 08` printed
# "08: value too great for base" at the `FROM=` line below and then died at the first use of `$FROM`
# with "FROM: unbound variable", rc=1 — the report stopped partway. (Pre-existing; found by the same
# review that added the identical arm to the heartbeat guard, and closed here because this is the
# file being changed rather than filed as a peer.)
case "$H" in ''|*[!0-9]*|0[0-9]*) H=12 ;; esac
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
  # ⛔ `launchctl list` prints `-` in the PID column for a job that is LOADED but NOT RUNNING, so
  # `[ -n "$pid" ]` alone read a stopped job as UP (measured: a job loaded with no process printed
  # `UP (pid -)   heartbeat age: 92167609s`). `-` must fall through to the NOT RUNNING branch.
  [ "${pid:-}" = "-" ] && pid=""
  if [ -n "${pid:-}" ]; then
    hb=$(cat "$O/heartbeat" 2>/dev/null || echo 0)
    # ⛔ A non-numeric heartbeat is FATAL here, not cosmetic: `$(( NOW - abc ))` recurses into the
    # VARIABLE `abc`, and under `set -u` that is "abc: unbound variable" — so the whole report
    # aborted mid-way (everything after `── controller ──`: merges, wall-time, claims, queue health)
    # and the script still exited 0. Measured with `heartbeat` = `abc`: 3 lines of stdout, rc=0.
    # Validate exactly as the sibling paths already validate their numeric reads.
    # ⛔ `0[0-9]*` too: a leading zero is OCTAL to `$(( ))`, so `heartbeat=08` fails the expansion
    # with "value too great for base" and the status line is dropped silently — the same silent-drop
    # class this guard was added for. (The `case "$H"` guard at the top of this file had the
    # identical gap; it is closed there too.)
    case "$hb" in ''|*[!0-9]*|0[0-9]*) hb=0 ;; esac
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
  # The source commit does NOT describe the deployed bytes when install.sh recorded a mismatch
  # (`deployedMatchesSource: false` — `$O` was synced from a different revision than the checkout
  # install.sh ran from). Printing `[current]` alone would headline a commit the box is not running.
  dm=$(sed -n 's/.*"deployedMatchesSource"[[:space:]]*:[[:space:]]*\([^,}]*\).*/\1/p' "$O/.agent-infra-stamp.json" | tr -d ' "' | head -1)
  echo "  harness: ${hc:-UNKNOWN} [${hr:-unknown}]"
  if [ "$dm" = false ]; then
    echo "  ⚠️  the DEPLOYED copy at \$O differs from the recorded source commit — this box is NOT running those bytes"
    echo "      re-sync and re-record: cp '<checkout>/scripts/orchestrator-harness'/*.sh \"\$O\"/ && O=\"\$O\" bash <checkout>/scripts/orchestrator-harness/install.sh"
  fi
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
# ⛔ TRI-STATE, NOT AN EXIT-CODE GUESS (review round 2, P1). The first form only set the failure flag
# INSIDE the "repo AND gh present" branch, so when either was missing the flag stayed 0 and BOTH
# lines printed a confident `0` — a blind read presented as a clean queue, on the very lines whose
# job is to detect a stall (and the `<needs a repo checkout and gh>` message became unreachable).
# `main` printed that message; this restores it and keeps the three states apart: no repo/gh,
# a read that FAILED, and a read that SUCCEEDED with nothing open.
OPEN_STATE=unreadable; OPENNUMS=""
if [ ! -d "$REPO" ] || ! command -v gh >/dev/null 2>&1; then
  OPEN_STATE=norepo
elif OPENNUMS="$(cd "$REPO" && gh pr list --state open --limit 300 --json number --jq '.[].number' 2>/dev/null)"; then
  OPEN_STATE=ok
fi
case "$OPEN_STATE" in
  norepo) echo "  open PRs: <needs a repo checkout and gh>" ;;
  ok)     echo "  open PRs: $(printf '%s' "$OPENNUMS" | grep -c '[0-9]')" ;;
  *)      echo "  open PRs: <could not read>" ;;
esac
# ⛔ SUPERSEDED PARKS ARE NOT "NEEDS A HUMAN" (review round 6, P3), AND THE LINE IS PRINTED EXACTLY
# ONCE (review round 7, P2 — the first form left the raw echo above AND the adjusted echo below, so an
# operator read two contradictory numbers for one quantity: the same one-PR-two-answers class rounds
# 3-6 kept removing). A park whose recorded head is not the PR's current head has been RE-ARMED by a
# push (the controller honours a park only when its content matches the live head), so that PR is being
# worked and belongs in neither queue. The whole quantity is computed in the `ok` arm, over the OPEN
# listing this block already read, and printed once per state.
# ⛔ THE STALE-EVIDENCE COUNT IS ITS OWN LINE (agent-infra#2132), because it is a DIFFERENT queue with
# a DIFFERENT remedy: a parked PR needs a human, while a `needsreview-<PR>-<head>` PR needs to be
# re-reviewed. Indicator (b) of that issue is "the count of open PRs stalled on stale evidence stays
# at 0", and before this line nothing in the harness could answer it at all.
# ⛔ WHAT A MARKER MEANS, EXACTLY: `merge-one.sh` writes it when a reviewer run at that head produced
# NO usable verdict (cap hit, kill, empty final line) — the single writer, because it is the only
# component that can see whether head-bound evidence exists (review round 3). So this counts open,
# unparked PRs whose reviewer produced no verdict at the head the marker names; it deliberately does
# NOT try to prove the head is still current (that needs a `gh pr view` per PR, and a marker for a
# superseded head is cleared by the next `merge-one.sh` run for that PR).
# ⛔ OPEN PRs ONLY, COUNTED PER PR (review rounds 1-3). A marker left by a merged/closed PR is
# bookkeeping lag, not a stall; two markers for one PR are still ONE stalled PR. `seen` is the
# durable half — it holds even for a marker set written by a deployed peer box.
case "$OPEN_STATE" in
  norepo)
    echo "  parked (needs a human): $(ls "$O"/state/parked-* 2>/dev/null | wc -l | tr -d ' ')"
    echo "  stale evidence (needs re-review): <needs a repo checkout and gh>" ;;
  ok)
    stale=0; seen=""; superseded=0
    for f in "$O"/state/needsreview-*; do
      [ -e "$f" ] || continue
      pr="$(basename "$f" | sed -n 's/^needsreview-\([0-9][0-9]*\)-.*/\1/p')"
      [ -n "$pr" ] || continue
      case " $seen " in *" $pr "*) continue ;; esac
      printf '%s\n' "$OPENNUMS" | grep -qx -- "$pr" || continue
      # ⛔ THE PARK IS EVALUATED OVER THE PR'S WHOLE MARKER SET (review round 4, P3). Checking only the
      # FIRST marker the glob visits is order-dependent: a PR carrying a superseded marker plus one at
      # its parked head was counted in BOTH queues (the round-3 defect, still reachable from pre-#2132
      # per-head residue). A PR is in the parked queue when its parked head is among the heads its
      # markers name, so skip it then. Local file reads only.
      _parked_head="$(cat "$O/state/parked-$pr" 2>/dev/null)"
      _is_parked=0
      if [ -n "$_parked_head" ]; then
        for g in "$O"/state/needsreview-"$pr"-*; do
          [ -e "$g" ] || continue
          [ "${g##*-}" = "$_parked_head" ] && { _is_parked=1; break; }
        done
      fi
      seen="$seen $pr"
      if [ "$_is_parked" = "1" ]; then continue; fi
      # A park at a head no marker names is SUPERSEDED (the loop re-armed it), so this PR is neither
      # "needs a human" nor stalled: it is being worked. Counted separately, never silently dropped.
      [ -n "$_parked_head" ] && { superseded=$((superseded + 1)); continue; }
      stale=$((stale + 1))
    done
    _pt=""
    for _pf in "$O"/state/parked-*; do
      [ -e "$_pf" ] || continue
      _pp="$(basename "$_pf" | sed -E 's/^parked-([0-9][0-9]*)$/\1/p')"
      [ -n "$_pp" ] || continue
      # Scoped to the SAME open listing as the stale count: a park for a merged/closed PR is
      # bookkeeping residue, not a human's queue.
      printf '%s\n' "$OPENNUMS" | grep -qx -- "$_pp" && _pt=$(( ${_pt:-0} + 1 ))
    done
    _pn=$(( ${_pt:-0} - superseded )); [ "$_pn" -lt 0 ] && _pn=0
    if [ "$superseded" -gt 0 ]; then
      echo "  parked (needs a human): $_pn ($superseded at a superseded head — the loop has re-armed them)"
    else
      echo "  parked (needs a human): $_pn"
    fi
    echo "  stale evidence (needs re-review): $stale" ;;
  *) echo "  parked (needs a human): $(ls "$O"/state/parked-* 2>/dev/null | wc -l | tr -d ' ')"
     echo "  stale evidence (needs re-review): <could not read, $(ls "$O"/state/needsreview-* 2>/dev/null | wc -l | tr -d ' ') marker(s) present>" ;;
esac
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
