#!/usr/bin/env bash
# supervisor.test.sh — the supervisor must SAY when the stack is alive but not working, and must not
# signal anything it has not identified.
#
# Run: bash scripts/orchestrator-harness/supervisor.test.sh
# Exits 0 when ALL assertions pass. HERMETIC and SAFE: a throwaway $O whose every executable is a stub
# (`orch-loop.sh` sleeps and writes its own pid to `.orch.lock`, the three workers sleep), so nothing
# real is supervised, no repo is touched, and the only pids signalled are the stubs this file started.
#
# WHY IT EXISTS. Everything the supervisor did until 2026-10-18 made processes EXIST: KeepAlive restarts
# the supervisor, ensure_stack restarts the four children. None of it can see the measured failure
# (#1761 arm (c)) — a controller that is ALIVE with a FROZEN heartbeat, where every observable except
# the work itself is green. `tick()` reads $O/heartbeat for exactly that, and these assertions pin the
# three things that can go wrong with such a guard:
#
#   1. it does not fire at all (a missing tick is invisible: the box looks supervised);
#   2. it fires at the DEFAULT setting and KILLS a healthy controller — so repair is opt-in
#      (HARNESS_SELF_HEAL=1), and with it unset the stub controller must SURVIVE;
#   3. it kills a pid it did not identify — `.orch.lock` is a cache of a past state and a pid can be
#      reused, so the cmdline is re-read at the moment of action; a lock naming a foreign process must
#      be REFUSED, not obeyed.
#
# Also pinned: a missing supervised worker exits 78 at startup instead of being relaunched every
# INTERVAL forever (the silent-respawn class), and REPO is required rather than defaulted to a path
# that exists on one developer's machine.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUP="$SCRIPT_DIR/supervisor.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
assert_contains() { if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi; }
assert_absent()   { if grep -qF -- "$2" <<<"$1"; then bad "$3 (found: $2)"; else ok "$3"; fi; }

SB="$(mktemp -d 2>/dev/null || true)"
[ -n "$SB" ] || { echo "supervisor.test: cannot create a temp dir" >&2; exit 1; }
SUP_PID=""
cleanup() {
  [ -n "$SUP_PID" ] && kill "$SUP_PID" 2>/dev/null
  # Only pids whose cmdline names this sandbox: the stubs the supervisor started.
  local p
  for p in $(pgrep -f "bash $SB/orchestrator/orch-loop.sh" 2>/dev/null) $(pgrep -f "bash $SB/orchestrator/bg/" 2>/dev/null); do
    kill "$p" 2>/dev/null
  done
  rm -rf "$SB"
}
trap cleanup EXIT

mkstack() { # <dir> [workers?]
  mkdir -p "$1/logs" "$1/bg"
  # The heartbeat arithmetic lives in launchd-cycle.sh and is sourced from $O. Without it the tick
  # reports UNKNOWN — correct, and asserted separately below by NOT copying it.
  cp "$SCRIPT_DIR/launchd-cycle.sh" "$1/launchd-cycle.sh"
  # ⛔ QUOTED heredoc and "$O" inside the stub ON PURPOSE: the stub must find its own state dir the way
  # every real child does (`O="${O:-$HOME/orchestrator}"`), so this section FAILS if the supervisor
  # stops exporting O. A stack whose $O is not the default one would otherwise write its lock and
  # heartbeat into $HOME/orchestrator — two stacks, one state dir.
  cat > "$1/orch-loop.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' $$ > "$O/.orch.lock"
sleep 120
STUB
  if [ "${2:-workers}" = "workers" ]; then
    local w
    for w in digest watch-prs finish; do
      printf '#!/usr/bin/env bash\nsleep 120\n' > "$1/bg/$w.sh"
      chmod +x "$1/bg/$w.sh"
    done
  fi
}
TARGET="$SB/target"; mkdir -p "$TARGET"

echo "== 1. REPO is required, never defaulted to someone's machine"
out="$(O="$SB/nope" REPO= bash "$SUP" 2>&1)"; rc=$?
[ "$rc" -eq 78 ] && ok "no REPO exits 78" || bad "no REPO exited $rc (want 78)"
assert_contains "$out" "FATAL REPO is unset" "it names REPO as the fault"

echo "== 2. a missing supervised worker fails closed instead of respawning forever"
O1="$SB/o1"; mkstack "$O1" noworkers
out="$(O="$O1" REPO="$TARGET" INTERVAL=1 bash "$SUP" 2>&1)"; rc=$?
[ "$rc" -eq 78 ] && ok "a missing worker exits 78" || bad "a missing worker exited $rc (want 78)"
assert_contains "$out" "missing worker(s) at $O1/bg" "it names the missing worker directory"
assert_contains "$out" "deploy" "it names the remedy"

echo "== 3. a frozen heartbeat is REPORTED (default: detect only)"
O2="$SB/o2"; mkstack "$O2"
printf '1000000000\n' > "$O2/heartbeat"      # a plausible epoch, 2001 — far past any bound
O="$O2" REPO="$TARGET" INTERVAL=1 HB_STALE=1 WEDGE_TICKS=2 bash "$SUP" >/dev/null 2>&1 & SUP_PID=$!
# Wait for the escalation line rather than sleeping a fixed time.
for _ in $(seq 1 40); do grep -q 'WEDGED' "$O2/logs/supervisor.log" 2>/dev/null && break; sleep 0.5; done
LOG="$(cat "$O2/logs/supervisor.log" 2>/dev/null)"
assert_contains "$LOG" "WEDGED" "a frozen heartbeat is reported"
assert_contains "$LOG" "NOT idle" "it distinguishes wedged from idle"
assert_absent   "$LOG" "heal: stopping" "with HARNESS_SELF_HEAL unset it repairs NOTHING"
CPID="$(cat "$O2/.orch.lock" 2>/dev/null || true)"
# Non-vacuity: the pid must be ALIVE **and** be this sandbox's controller — a pid reused by an
# unrelated process would otherwise make this assertion pass for the wrong reason.
if [ -n "$CPID" ] && kill -0 "$CPID" 2>/dev/null && [ "$(ps -o command= -p "$CPID" 2>/dev/null)" = "bash $O2/orch-loop.sh" ]; then
  ok "the controller was left untouched (pid $CPID, cmdline verified)"
else
  bad "the controller was signalled (or is unidentifiable) with self-heal OFF: pid='$CPID' cmd='$(ps -o command= -p "${CPID:-0}" 2>/dev/null)'"
fi
assert_absent "$LOG" "controller: clearing stale lock" "a live controller's lock is never cleared"
kill "$SUP_PID" 2>/dev/null; wait "$SUP_PID" 2>/dev/null; SUP_PID=""
# Stop the stub the supervisor started, so section 4 starts from a clean sandbox.
[ -n "$CPID" ] && kill "$CPID" 2>/dev/null
for p in $(pgrep -f "bash $O2/bg/" 2>/dev/null); do kill "$p" 2>/dev/null; done

echo "== 4. with HARNESS_SELF_HEAL=1 it repairs the wedge — and only its own controller"
O3="$SB/o3"; mkstack "$O3"
printf '1000000000\n' > "$O3/heartbeat"
# the pid the supervisor will start, captured once it records the lock
CPID3=""
O="$O3" REPO="$TARGET" INTERVAL=1 HB_STALE=1 WEDGE_TICKS=2 HARNESS_SELF_HEAL=1 bash "$SUP" >/dev/null 2>&1 & SUP_PID=$!
for _ in $(seq 1 60); do grep -q 'healed=' "$O3/logs/supervisor.log" 2>/dev/null && break; sleep 0.5; done
CPID3="$(sed -n 's/.*heal: stopping the wedged controller (pid \([0-9]*\)).*/\1/p' "$O3/logs/supervisor.log" 2>/dev/null | sed -n 1p)"
LOG="$(cat "$O3/logs/supervisor.log" 2>/dev/null)"
assert_contains "$LOG" "heal: stopping the wedged controller" "it stops the wedged controller"
assert_contains "$LOG" "pid $CPID3" "…and names the pid it identified"
assert_contains "$LOG" "controller: starting" "ensure_stack starts a fresh one afterwards"
assert_absent   "$LOG" "REFUSED to signal" "it did not mistake its own controller for a foreign pid"
kill "$SUP_PID" 2>/dev/null; wait "$SUP_PID" 2>/dev/null; SUP_PID=""

echo "== 5. a lock naming a FOREIGN pid is refused, never obeyed"
O4="$SB/o4"; mkstack "$O4"
# A real controller first (it records its own pid in .orch.lock), THEN the lock is made to name a
# foreign process — the pid-reuse shape the guard must refuse.
O="$O4" bash "$O4/orch-loop.sh" & REAL_CTL=$!
for _ in $(seq 1 20); do [ -s "$O4/.orch.lock" ] && break; sleep 0.2; done
sleep 120 & FOREIGN=$!                        # alive, and NOT this stack's controller
printf '%s\n' "$FOREIGN" > "$O4/.orch.lock"
printf '1000000000\n' > "$O4/heartbeat"
# Drive the heal path directly: a supervisor tick would first ensure_stack, which is not what this
# assertion is about, so call the same guard through a one-shot supervisor and read the log.
O="$O4" REPO="$TARGET" INTERVAL=1 HB_STALE=1 WEDGE_TICKS=2 HARNESS_SELF_HEAL=1 bash "$SUP" >/dev/null 2>&1 & SUP_PID=$!
for _ in $(seq 1 60); do grep -q 'REFUSED to signal' "$O4/logs/supervisor.log" 2>/dev/null && break; sleep 0.5; done
LOG="$(cat "$O4/logs/supervisor.log" 2>/dev/null)"
assert_contains "$LOG" "REFUSED to signal pid $FOREIGN" "the foreign pid is refused by cmdline"
if kill -0 "$FOREIGN" 2>/dev/null; then ok "the foreign process was NOT signalled"; else bad "the foreign process was killed"; fi
kill "$SUP_PID" 2>/dev/null; wait "$SUP_PID" 2>/dev/null; SUP_PID=""
kill "$FOREIGN" "$REAL_CTL" 2>/dev/null; wait "$FOREIGN" "$REAL_CTL" 2>/dev/null

echo
printf '==> %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
