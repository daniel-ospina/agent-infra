#!/usr/bin/env bash
# lane-census.test.sh — the lane count from LIVE PROCESSES, cross-checked against the tmux
# convention (agent-infra#2095 item 3).
#
# THE MEASUREMENT THIS SUITE EXISTS FOR. `tmux ls | grep -c '^lane-'` reported `lanes=0` while
# 48-50 `pi --model` processes were live, so the controller believed it had 25 free slots on a box
# thrashing at load 170 with swap at 12.4 GB of 13.3 GB. A session NAME is a convention; a live
# process holding a worktree is an observation.
#
# ⛔ THE FIXTURE IS REAL PROCESSES AND REAL WORKTREES. Stubbing `pgrep`/`lsof` would test the
# parsing of a fiction: the whole defect is about what those tools see on a loaded box. So this
# suite launches actual `pi`-named processes with real cwds under a real
# `<repo>/.worktrees/<name>` tree, and drives the SHIPPED `lane-census.sh` against them —
# including the empty-box and disagreement arms, where the safe direction is the LARGER count.
#
# ⛔ AND IT CHECKS THE BOUND. `lane-status.py` costs 147-420 s under load; the whole point of this
# reader is that it answers in seconds or says UNREADABLE in seconds. A `pgrep` that never returns
# is the shape that used to hang a pass, and it is exercised below.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CENSUS="$HERE/lane-census.sh"
GUARD="$HERE/controller-state.sh"
PASS=0; FAIL=0
ck() { # ck <name> <0|1>
  if [ "$2" -eq 0 ]; then printf '  ✅ %s\n' "$1"; PASS=$((PASS+1));
  else printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); fi
}
TMP="$(mktemp -d)"
AGENT_PIDS=""
cleanup() {
  for p in $AGENT_PIDS; do kill -TERM "$p" 2>/dev/null || true; done
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "==> lane-census self-test ($HERE)"

[ -s "$CENSUS" ] && bash -n "$CENSUS"; rc=$?
ck "lane-census.sh exists and parses" $rc
grep -q 'lane-census.sh' "$HERE/orch-loop.sh"; rc=$?
ck "orch-loop.sh resolves the census (the controller actually uses it)" $rc

# ── the fixture: a repo with three occupied worktrees, plus one process outside them ──────────
REPO="$TMP/repo"
mkdir -p "$REPO/.worktrees/tm-1" "$REPO/.worktrees/fix-2" "$REPO/.worktrees/lane-3" "$REPO/plain"
mkdir -p "$TMP/bin"
# A process whose COMM is exactly `pi` — the same predicate lane-status.py uses (`pgrep -x pi`), so
# the two surfaces cannot disagree about what an agent process is.
cp /bin/sleep "$TMP/bin/pi" 2>/dev/null || cp "$(command -v sleep)" "$TMP/bin/pi"
chmod +x "$TMP/bin/pi"
# ⛔ NEVER `pid=$(spawn …)`: a backgrounded child INHERITS the command substitution's stdout, so the
# substitution blocks on the child's lifetime and the suite hangs on its own fixture. The pid is
# handed back through a variable, and the child's output is closed.
LAST_PID=""
spawn_agent() { # spawn_agent <cwd>; sets LAST_PID
  ( cd "$1" && exec "$TMP/bin/pi" 120 ) >/dev/null 2>&1 &
  LAST_PID=$!
  AGENT_PIDS="$AGENT_PIDS $LAST_PID"
}
spawn_agent "$REPO/.worktrees/tm-1"
spawn_agent "$REPO/.worktrees/fix-2"
spawn_agent "$REPO/.worktrees/lane-3"
spawn_agent "$REPO/plain"          # a live agent NOT holding a worktree slot
# ...and one agent in the repo root: a process, but not an occupied slot
spawn_agent "$REPO"
sleep 0.5

# ── tmux stubs, one per arm ───────────────────────────────────────────────────────────────────
mkdir -p "$TMP/tmux1" "$TMP/tmux3" "$TMP/tmux-broken"
cat > "$TMP/tmux1/tmux" <<'S'
#!/bin/sh
printf 'lane-9\nmerge-4\n'
S
cat > "$TMP/tmux3/tmux" <<'S'
#!/bin/sh
printf 'lane-1\nlane-2\nlane-3\n'
S
cat > "$TMP/tmux-broken/tmux" <<'S'
#!/bin/sh
echo "no server running on /tmp/tmux-501/default" >&2
exit 1
S
chmod +x "$TMP/tmux1/tmux" "$TMP/tmux3/tmux" "$TMP/tmux-broken/tmux"

# `pgrep`/`lsof` come from the real PATH (the process table is the subject); only `tmux` is stubbed.
census() { # census <tmux-dir>
  PATH="$1:$PATH" bash "$CENSUS" --repo "$REPO" 2>/dev/null
}
tok() { printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -1; }

OUT1="$(census "$TMP/tmux1")"
echo "      census: $OUT1"
[ "$(tok "$OUT1" state)" = "READ" ]; rc=$?
ck "a normal read reports state=READ (never a silent zero)" $rc
# ⛔ THE ABSOLUTE NUMBER IS NOT OURS TO ASSERT: this suite runs on the live fleet's own box, where
# other `pi` processes exist. The three worktree-scoped counts below are exact (they are scoped to
# the FIXTURE repo); `procs` is asserted as "at least our five", which is what makes it a
# CROSS-CHECK rather than a total.
[ "$(tok "$OUT1" procs)" -ge 5 ] 2>/dev/null; rc=$?
ck "procs>=5 — the CROSS-CHECK the issue asks for (live agent processes): $(tok "$OUT1" procs)" $rc
[ "$(tok "$OUT1" worktrees)" = "3" ]; rc=$?
ck "worktrees=3 — distinct worktrees held by live processes: $(tok "$OUT1" worktrees)" $rc
[ "$(tok "$OUT1" lanes_wt)" = "2" ]; rc=$?
ck "lanes_wt=2 (tm-1, lane-3 — a plain/fix worktree is not a lane): $(tok "$OUT1" lanes_wt)" $rc
[ "$(tok "$OUT1" workers_wt)" = "1" ]; rc=$?
ck "workers_wt=1 (fix-2): $(tok "$OUT1" workers_wt)" $rc
[ "$(tok "$OUT1" lanes_tmux)" = "1" ]; rc=$?
ck "lanes_tmux=1 (the convention is still READ and reported, not discarded): $(tok "$OUT1" lanes_tmux)" $rc
[ "$(tok "$OUT1" used)" = "2" ] && [ "$(tok "$OUT1" src)" = "worktrees" ]; rc=$?
ck "used=2 src=worktrees — the process observation wins, and SAYS so" $rc

# ── THE DISAGREEMENT ARM: the convention claims MORE than the process table proves ────────────
# A lane whose process has already died still has its session name. The count used is the LARGER of
# the two independent observations, because the failure being fixed is UNDER-counting and a larger
# count can only ever REFUSE a dispatch — the safe direction.
OUT3="$(census "$TMP/tmux3")"
echo "      census: $OUT3"
[ "$(tok "$OUT3" lanes_tmux)" = "3" ] && [ "$(tok "$OUT3" lanes_wt)" = "2" ]; rc=$?
ck "both observations are REPORTED when they disagree (tmux=$(tok "$OUT3" lanes_tmux) wt=$(tok "$OUT3" lanes_wt))" $rc
[ "$(tok "$OUT3" used)" = "3" ] && [ "$(tok "$OUT3" src)" = "tmux" ]; rc=$?
ck "the LARGER count is used, and its source is named: used=$(tok "$OUT3" used) src=$(tok "$OUT3" src)" $rc

# ...and the controller's own token form says DISAGREE, naming both. This is the line an operator
# greps when the gate and `tmux ls` tell different stories.
CTOK="$( ( PATH="$TMP/tmux3:$PATH"; . "$GUARD"; orc_census "$CENSUS" "$REPO"; orc_census_token 25 ) 2>/dev/null )"
case "$CTOK" in
  *DISAGREE*) rc=0 ;;
  *) rc=1 ;;
esac
ck "the [cap] census token flags DISAGREE with both numbers: ${CTOK:0:120}…" $rc
case "$CTOK" in
  *lanes=*) [[ "$CTOK" == *"lanes=3/25"* ]] && rc=0 || rc=1 ;;
  *) rc=1 ;;
esac
ck "the token carries the value USED and the ceiling (lanes=<used>/<max>)" $rc

# ── THE UNREADABLE-CONVENTION ARM: no tmux server is PARTIAL, not zero sessions ───────────────
OUTB="$(census "$TMP/tmux-broken")"
echo "      census: $OUTB"
[ "$(tok "$OUTB" state)" = "PARTIAL" ] && [ "$(tok "$OUTB" why)" = "tmux_unreadable" ]; rc=$?
ck "an unreadable tmux is state=PARTIAL why=tmux_unreadable — never 'zero sessions'" $rc
[ "$(tok "$OUTB" used)" = "2" ] && [ "$(tok "$OUTB" src)" = "worktrees" ]; rc=$?
ck "a partial read still answers from the process table: used=$(tok "$OUTB" used) src=$(tok "$OUTB" src)" $rc

# ── THE BOUND: a `pgrep` that never returns must not become a hung pass ──────────────────────
# ⛔ THIS IS THE DEFECT, NOT A HYPOTHETICAL. The roster read this replaces timed out at the fleet's
# busiest moments, i.e. exactly when occupancy mattered most. The bound is 10 s inside the census
# (`census_bounded`), so the whole call must come back in well under a minute even when the process
# probe hangs, and it must come back with a STATE rather than nothing.
mkdir -p "$TMP/hang"
cat > "$TMP/hang/pgrep" <<'S'
#!/bin/sh
sleep 600
S
chmod +x "$TMP/hang/pgrep"
T0=$(date +%s)
OUTH="$(PATH="$TMP/hang:$TMP/tmux1:$PATH" bash "$CENSUS" --repo "$REPO" 2>/dev/null)"
T1=$(date +%s)
echo "      census (hanging pgrep, $((T1-T0))s): $OUTH"
[ "$(tok "$OUTH" state)" = "PARTIAL" ] && [ "$(tok "$OUTH" why)" = "agent_process_read_timed_out" ]; rc=$?
ck "a HANGING process probe is bounded and reported (state=PARTIAL why=agent_process_read_timed_out)" $rc
[ $((T1-T0)) -lt 60 ]; rc=$?
ck "the whole census returned in $((T1-T0))s despite the hang (bound is 10 s per read)" $rc
# ...and the tmux convention still answered, so the controller is not blind either way.
[ "$(tok "$OUTH" used)" = "1" ] && [ "$(tok "$OUTH" src)" = "tmux" ]; rc=$?
ck "with the process table unreadable the convention still answers, named: used=$(tok "$OUTH" used) src=$(tok "$OUTH" src)" $rc

# ── THE EMPTY-BOX ARM: an idle box is a READ of zero, not an UNREADABLE ──────────────────────
# The polarity that matters: a false zero makes the controller dispatch into nothing, and a false
# UNREADABLE makes it refuse forever. Both are wrong, and they are different states.
for p in $AGENT_PIDS; do kill -TERM "$p" 2>/dev/null || true; done
AGENT_PIDS=""
sleep 0.3
mkdir -p "$TMP/tmux-none"
cat > "$TMP/tmux-none/tmux" <<'S'
#!/bin/sh
exit 0
S
chmod +x "$TMP/tmux-none/tmux"
OUTE="$(PATH="$TMP/tmux-none:$PATH" bash "$CENSUS" --repo "$REPO" 2>/dev/null)"
echo "      census (idle box): $OUTE"
case "$(tok "$OUTE" state)" in
  READ|PARTIAL) rc=0 ;;          # no agents is a legitimate read; it must not be UNREADABLE
  *) rc=1 ;;
esac
ck "an EMPTY fixture repo is still a READ/partial read, not UNREADABLE: state=$(tok "$OUTE" state)" $rc
# The counts are scoped to the fixture repo, so they ARE exact even on a busy box: nothing there.
[ "$(tok "$OUTE" used)" = "0" ] && [ "$(tok "$OUTE" worktrees)" = "0" ]; rc=$?
ck "an empty fixture repo reads used=0 worktrees=0 (a zero, not an absence): $(tok "$OUTE" used)/$(tok "$OUTE" worktrees)" $rc

echo
echo "==> lane-census: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
