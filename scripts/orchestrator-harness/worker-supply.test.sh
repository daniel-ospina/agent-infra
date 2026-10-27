#!/bin/bash
# worker-supply.test.sh — the supply half of the repair pool, DRIVEN (agent-infra#2700).
#
# ⛔ WHAT THIS SUITE IS FOR. The defect is measured and it is not subtle: `pr-doctor` printed
# `capacity fix=16 review=12, inflight=0 (alive=0 unknown=0)` and
# `REFUSING: 16 order(s) no worker accepted and nothing was dispatched` on three consecutive passes
# while nothing in the fleet refilled the pool, because dispatch was the ONLY thing that had ever
# created a repair worker. A test that greps a log for `refilled` would pass on a supervisor that
# refills nothing. So every assertion here is BEHAVIOURAL: the shipped `worker-supply.sh` is RUN
# against a stub dispatcher that shares the real one's grammar (`name worktree prompt cap kind`,
# `--status`), and the assertions are on (a) what was actually spawned, (b) what the HARNESS's own
# reader says afterwards, and (c) whether the dangerous direction — two workers in one worktree — is
# possible.
#
# ⛔ THE ONE ASSERTION THAT IS NOT MINE TO INVENT is the doctor's own reader. `worker_live_for()` is
# imported from the shipped `pr-doctor.py` and asked, before and after a refill: `absent` is the state
# in which the doctor's next pass has no worker and must place the order again; `live` is the state in
# which the pool is supplied. Grading that against my own stub would be grading my own copy.
# (The literal `dispatched N of M` line cannot be produced offline: a real pass needs a `gh` fixture
# for the PR list, check-runs, changed files AND the classifier's attestation read. What is asserted
# instead is the precondition that line is computed from — and the honest gap is declared here rather
# than papered over with a stub that prints the sentence.)
#
# Cases (the brief's, in order):
#   (a) a dead worker is refilled, and the doctor's own reader flips absent -> live
#   (b) two supervisors: the second refuses (rc=4) and touches nothing
#   (c) the capacity budget is respected — never more than fix+review live
#   (d) a worker that dies mid-order is replaced and the order is re-offered EXACTLY ONCE
#   (e) mutation: replace the refill step with a no-op => (a) reddens
# plus the guards that keep the design honest: no merge authority, capacity pinned to pr-doctor's own
# reader, and the shipped unit/plist properties that make the supervisor supervised at all.
#
# Hermetic: no network, no gh, no real PRs, no sudo, no service manager. Run: bash worker-supply.test.sh
HERE="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
SUPPLY="$HERE/worker-supply.sh"
PRDOCTOR="$(cd "$HERE/.." 2>/dev/null && pwd)/pr-doctor.py"
INSTALLER="$(cd "$HERE/../.." 2>/dev/null && pwd)/scripts/install-worker-supply.sh"
UNIT_TPL="$(cd "$HERE/../.." 2>/dev/null && pwd)/templates/systemd/eldato-worker-supply.service"
PLIST_TPL="$(cd "$HERE/../.." 2>/dev/null && pwd)/templates/launchd/com.eldato.worker-supply.plist"

[ -f "$SUPPLY" ] || { echo "FATAL: $SUPPLY not found"; exit 1; }
[ -f "$PRDOCTOR" ] || { echo "FATAL: $PRDOCTOR not found (the doctor's own reader is asserted)"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/worker-supply-test.XXXXXX")" || exit 1
PASS=0; FAIL=0
# ⛔ A FAKE WORKER'S LIFE IS A SUB-SECOND VARIABLE, NEVER A BARE `sleep 300` (measured 2026-10-27).
# This suite took >45 min and never finished, and the CAUSE WAS NOT THE SLEEP ITSELF — both halves are
# here, because fixing only one leaves the suite either slow or wrong:
#   * a stub worker `( sleep 300 ) &` INHERITS the stub dispatcher's stdout, which is the pipe the
#     supervisor's `out="$(bounded … bash "$DISPATCH" …)"` is reading — so the supervisor blocked on
#     EOF for the worker's ENTIRE life. This is not a stub quirk: `nonblocking-dispatch.sh` closes its
#     worker's stdout (`exec >/dev/null 2>&1`) and its own comment records the measurement (5.02 s
#     captured vs 0.03 s uncaptured) because of exactly this. The stub MUST mirror it, or it grades a
#     friendlier contract than the shipped dispatcher AND no lifetime short of zero finishes the suite.
#   * a 5-minute lifetime *also* made every case's floor 5 minutes by construction, so the fake worker
#     now PARKS on the case's sentinel in WORKER_STUB_LIFETIME slices instead of sleeping out a fixed
#     sentence: a case ends when the case ends, and a fake worker costs no wall-clock at all.
# The suite is timed at the end and must stay under 60 s.
WORKER_STUB_LIFETIME="${WORKER_STUB_LIFETIME:-0.3}"
case "$WORKER_STUB_LIFETIME" in ''|*[!0-9.]*) echo "FATAL: WORKER_STUB_LIFETIME='$WORKER_STUB_LIFETIME' is not a number"; exit 1 ;; esac
export WORKER_STUB_LIFETIME
SUITE_START=$(date +%s)
ok()  { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

# ── fixture ───────────────────────────────────────────────────────────────────────────────────
O="$TMP/O"; BG="$O/bg"; ST="$O/state"; SPAWNS="$TMP/spawns.tsv"; PIDS="$TMP/pids"
# The case sentinel: touching it ends every fake worker the case's fixture started (and `reset`
# removes it again), so a case can never be outlived by its own stubs. Exported because the stub
# DISPATCHER is a separate process and must be able to see it.
WORKER_STUB_STOP="$TMP/workers.stop"; export WORKER_STUB_STOP
# A fake worker: stdout closed FIRST (the load-bearing half — see the header), then a park that ends
# when the case does. Costs no wall-clock, and answers `running` for as long as the case needs it.
stub_worker() { # -> echoes the pid of a process that answers `running`
  ( exec >/dev/null 2>&1
    while [ ! -f "$WORKER_STUB_STOP" ]; do sleep "$WORKER_STUB_LIFETIME"; done ) &
  echo "$!"
}
cleanup() {
  : > "$WORKER_STUB_STOP" 2>/dev/null
  if [ -f "$PIDS" ]; then
    while read -r p; do [ -n "$p" ] && kill "$p" 2>/dev/null; done < "$PIDS"
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

# The stub dispatcher: the REAL grammar, no gates. `--status` answers exactly as
# `nonblocking-dispatch.sh` does (rc file first, then `kill -0` on the pid, else `lost`), because the
# supervisor must not be able to pass this suite against a friendlier contract than the shipped one.
mk_dispatcher() {
  mkdir -p "$BG" "$ST"
  cat > "$O/nonblocking-dispatch.sh" <<'EOS'
#!/usr/bin/env bash
O="$(cd "$(dirname "$0")" && pwd)"; D="$O/bg"
if [ "${1:-}" = "--status" ]; then
  NAME="${2:-}"
  RC="$(cat "$D/$NAME.rc" 2>/dev/null || true)"
  PID="$(cat "$D/$NAME.pid" 2>/dev/null || true)"
  if [ -n "$RC" ]; then
    if [ "$RC" = "0" ]; then echo "$NAME done rc=0"; else echo "$NAME failed rc=$RC"; fi
  elif [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    echo "$NAME running pid=$PID"
  else
    echo "$NAME lost (no exit status recorded and pid ${PID:-<unknown>} is gone)"
  fi
  exit 0
fi
NAME="$1"; WT="$2"; PROMPT="$3"; T="${4:-2400}"; WK="${5:-bg}"
[ -d "$WT" ]     || { echo "no worktree $WT" >&2; exit 2; }
[ -f "$PROMPT" ] || { echo "no prompt file $PROMPT" >&2; exit 2; }
printf '%s\t%s\t%s\t%s\t%s\n' "$NAME" "$WT" "$PROMPT" "$T" "$WK" >> "${SPAWNS:-$O/spawns.tsv}"
rm -f "$D/$NAME.rc"
printf 'name=%s\nworktree=%s\nbranch=%s\nkind=%s\nprompt=%s\nstarted=%s\ncap=%ss\n' \
  "$NAME" "$WT" "$(git -C "$WT" branch --show-current 2>/dev/null)" "$WK" "$PROMPT" \
  "$(date '+%Y-%m-%d %H:%M:%S')" "$T" > "$D/$NAME.started"
# the worker: `exec >/dev/null 2>&1` FIRST, exactly as `nonblocking-dispatch.sh` does it (a worker
# that holds the caller's captured pipe makes a "non-blocking" dispatcher block — measured 5.02 s vs
# 0.03 s in that script's own comment), then a park that ends with the CASE, not with a sleep.
( exec >/dev/null 2>&1
  while [ ! -f "${WORKER_STUB_STOP:-/nonexistent}" ]; do sleep "${WORKER_STUB_LIFETIME:-0.3}"; done ) &
echo "$!" > "$D/$NAME.pid"
echo "$!" >> "${SPAWNS:-$O/spawns.tsv}.pids"
exit 0
EOS
  chmod +x "$O/nonblocking-dispatch.sh"
}

reset() {
  # end every fake worker the PREVIOUS case started, then start the next case with a fresh sentinel
  : > "$WORKER_STUB_STOP" 2>/dev/null
  if [ -f "$PIDS" ]; then
    while read -r p; do [ -n "$p" ] && kill "$p" 2>/dev/null; done < "$PIDS"
  fi
  [ -f "$SPAWNS.pids" ] && { while read -r p; do [ -n "$p" ] && kill "$p" 2>/dev/null; done < "$SPAWNS.pids"; }
  rm -rf "$TMP/O" "$TMP/wt" "$SPAWNS" "$SPAWNS.pids" "$TMP/briefs" "$TMP/bin"
  rm -f "$WORKER_STUB_STOP"
  : > "$PIDS"
  mk_dispatcher
  mkdir -p "$TMP/briefs" "$TMP/wt" "$TMP/bin"
}

# a real git worktree on the branch the order names — the supervisor REFUSES a tree that moved
mkwt() { # <dir> <branch>
  mkdir -p "$1"
  git -C "$1" init -q 2>/dev/null
  git -C "$1" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m x 2>/dev/null
  git -C "$1" checkout -q -b "$2" 2>/dev/null
}

# an ACCEPTED order: the record `nonblocking-dispatch.sh` writes, and nothing else
mkorder() { # <name> <wt> <branch> <brief> <cap> [<started>]
  local name="$1" wt="$2" branch="$3" brief="$4" cap="${5:-2400}" stamp="${6:-$(date '+%Y-%m-%d %H:%M:%S')}"
  printf 'name=%s\nworktree=%s\nbranch=%s\nkind=%s\nprompt=%s\nstarted=%s\ncap=%ss\n' \
    "$name" "$wt" "$branch" prfix "$brief" "$stamp" "$cap" > "$BG/$name.started"
}

live_worker() { # <name> — a pid that answers `running`
  local p; p="$(stub_worker)"
  echo "$p" > "$BG/$1.pid"
  echo "$p" >> "$PIDS"
}

sup() { # <args...> — run the SHIPPED supervisor against the fixture
  O="$O" bash "$SUPPLY" "$@"
}

spawn_count() { [ -f "$SPAWNS" ] && wc -l < "$SPAWNS" | tr -d ' ' || echo 0; }
spawns_for() { # <name>
  [ -f "$SPAWNS" ] || { echo 0; return 0; }
  awk -F'\t' -v n="$1" '$1==n { c++ } END { printf "%d\n", c+0 }' "$SPAWNS"
}
record_field() { awk -F= -v k="$1" '$1==k { print $2; exit }' "$ST/worker-supply.state" 2>/dev/null; }

# the DOCTOR's own reader, imported from the shipped file (not re-implemented here)
py_live_for() { # <pr-number> -> live|absent|unknown
  O="$O" perl -e 'alarm shift; exec @ARGV' 60 python3 - "$PRDOCTOR" "$1" <<'PY' 2>/dev/null
import importlib.util, sys
spec = importlib.util.spec_from_file_location("prdoctor", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
v = m.worker_live_for(int(sys.argv[2]))
print({True: "live", False: "absent", None: "unknown"}[v])
PY
}

py_capacity() { # <max_fix> <max_review> -> "fix review"  (pr-doctor's OWN capacity(), the one home)
  MAX_FIX="$1" MAX_REVIEW="$2" python3 - "$PRDOCTOR" <<'PY' 2>/dev/null
import importlib.util, sys
spec = importlib.util.spec_from_file_location("prdoctor", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
c = m.capacity()
print(c["max_fix"], c["max_review"])
PY
}

echo "== worker-supply.test.sh =="

# ── (a) a dead worker is refilled ─────────────────────────────────────────────────────────────
echo "-- (a) dead worker refilled"
reset
mkwt "$TMP/wt/prd-11" fix/11
echo brief > "$TMP/briefs/prd-11.txt"
mkorder prd-11 "$TMP/wt/prd-11" fix/11 "$TMP/briefs/prd-11.txt" 2400 "2026-10-27 01:00:00"
before="$(py_live_for 11)"
[ "$before" = "absent" ] && ok "precondition: the doctor's reader says the order has NO worker ($before) — the pool is empty" \
                         || bad "precondition: doctor's reader said '$before', expected absent"

O="$O" SPAWNS="$SPAWNS" MAX_FIX=3 MAX_REVIEW=4 sup refill >/dev/null 2>&1; rc=$?
[ "$rc" = "0" ] && ok "pass rc=0 (a refill happened)" || bad "pass rc=$rc, expected 0"
[ "$(spawn_count)" = "1" ] && ok "exactly ONE worker was spawned for the dead order" \
                           || bad "spawn count $(spawn_count), expected 1"
row="$(head -1 "$SPAWNS" 2>/dev/null)"
case "$row" in
  "prd-11	$TMP/wt/prd-11	$TMP/briefs/prd-11.txt	2400	prfix")
    ok "the re-offer carried the order's OWN argv (worktree, brief, cap, kind=prfix) — the one dispatcher's grammar, replayed" ;;
  *) bad "re-offer argv was '$row' — expected the recorded worktree/brief/cap/kind" ;;
esac
after="$(py_live_for 11)"
[ "$after" = "live" ] && ok "the doctor's own reader now says the pool is supplied ($after)" \
                     || bad "doctor's reader said '$after' after the refill, expected live"
[ "$(record_field decision)" = "refilled" ] && ok "the pass record says decision=refilled" \
                                           || bad "pass record decision='$(record_field decision)', expected refilled"

# a second pass in the same state must NOT spawn again (the refilled worker is live)
O="$O" SPAWNS="$SPAWNS" MAX_FIX=3 MAX_REVIEW=4 sup refill >/dev/null 2>&1
[ "$(spawn_count)" = "1" ] && ok "a second pass spawns NOTHING (the refilled worker holds the slot)" \
                          || bad "a second pass spawned again: $(spawn_count) total"
# the operator's verb is `heal` — the word you reach for when `status` shows dead orders. It is ONE
# alias for the one-shot pass, and a usage error in the moment that matters is how a runbook rots.
O="$O" SPAWNS="$SPAWNS" MAX_FIX=3 MAX_REVIEW=4 sup heal >"$TMP/heal.out" 2>&1; rch=$?
[ "$rch" = "0" ] && ! grep -q 'usage:' "$TMP/heal.out" \
  && ok "the \`heal\` verb is the same one-shot pass (rc=0, not a usage error)" \
  || bad "\`heal\` is not an accepted verb (rc=$rch: $(head -1 "$TMP/heal.out"))"
O="$O" MAX_FIX=3 MAX_REVIEW=4 sup status >"$TMP/status.out" 2>&1; rcs=$?
[ "$rcs" = "0" ] && grep -q 'now:   orders=1' "$TMP/status.out" \
  && ok "\`status\` prints a FRESH count (orders=1, live=1) — the record is not the reading" \
  || bad "\`status\` did not report a fresh live count (rc=$rcs)"

# ── (b) two supervisors: one refuses, workers untouched ───────────────────────────────────────
echo "-- (b) single-instance guard (pid + lock)"
reset
mkwt "$TMP/wt/prd-12" fix/12
echo brief > "$TMP/briefs/prd-12.txt"
mkorder prd-12 "$TMP/wt/prd-12" fix/12 "$TMP/briefs/prd-12.txt"
# a REAL supervisor holds the lock for its lifetime; the second must refuse rather than drain alongside it
O="$O" SPAWNS="$SPAWNS" WORKER_SUPPLY_INTERVAL_S=60 MAX_FIX=3 MAX_REVIEW=4 \
  bash "$SUPPLY" --loop >"$TMP/loop.out" 2>&1 &
LOOP_PID=$!
echo "$LOOP_PID" >> "$PIDS"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ -f "$ST/worker-supply.lock/pid" ] && break
  sleep 0.2
done
[ -f "$ST/worker-supply.lock/pid" ] && ok "the loop took the lock ($(cat "$ST/worker-supply.lock/pid" 2>/dev/null))" \
                                   || bad "the loop never took the lock"
n_before="$(spawn_count)"
O="$O" SPAWNS="$SPAWNS" MAX_FIX=3 MAX_REVIEW=4 sup refill >"$TMP/second.out" 2>&1; rc2=$?
[ "$rc2" = "4" ] && ok "the second supervisor exits 4 (ALREADY-RUNNING)" \
                 || bad "the second supervisor exited $rc2, expected 4"
[ "$(spawn_count)" = "$n_before" ] && ok "the second supervisor spawned NOTHING ($n_before before, $(spawn_count) after)" \
                                   || bad "the second supervisor touched workers ($n_before -> $(spawn_count))"
grep -q 'ALREADY-RUNNING' "$TMP/second.out" 2>/dev/null && ok "the refusal NAMES itself on the record (ALREADY-RUNNING)" \
                                                        || bad "the refusal printed no ALREADY-RUNNING line"
# ⛔ A SUPERVISOR THAT IGNORES SIGTERM IS PINNED, NOT SUPERVISED. `trap 'lock_release' TERM` releases
# the lock and lets the loop CONTINUE (and bash defers a trapped signal until the foreground command --
# `sleep $INTERVAL_S` -- returns), so `systemctl stop` / a launchd unload waited a whole interval and
# then left the loop running WITHOUT its single-instance guard. `wait "$LOOP_PID"` is what hung the
# first attempt for ever, so the stop is now BOUNDED and ASSERTED rather than assumed.
kill -TERM "$LOOP_PID" 2>/dev/null
stopped=0
for (( _i = 0; _i < 50; _i++ )); do
  kill -0 "$LOOP_PID" 2>/dev/null || { stopped=1; break; }
  sleep 0.1
done
[ "$stopped" = 1 ] && ok "the supervisor STOPS on SIGTERM inside its interval (a --loop that never exits pins systemctl stop)" \
                   || bad "the supervisor ignored SIGTERM — a service that cannot be stopped is not supervised"
kill -9 "$LOOP_PID" 2>/dev/null; wait "$LOOP_PID" 2>/dev/null
# ⛔ AND THE LOCK IS RELEASED BY THE HOLDER: a guard that outlives its holder is an inert supervisor.
sleep 0.3
[ -d "$ST/worker-supply.lock" ] && bad "the lock survived its holder — the supervisor would be inert" \
                               || ok "the lock is released when its holder exits"

# a stale lock (holder gone) is TAKEN OVER rather than wedging the supervisor for ever
mkdir -p "$ST/worker-supply.lock"; echo 999999 > "$ST/worker-supply.lock/pid"
O="$O" SPAWNS="$SPAWNS" MAX_FIX=3 MAX_REVIEW=4 sup refill >"$TMP/stale.out" 2>&1; rc3=$?
[ "$rc3" = "0" ] && ok "a stale lock (dead holder pid) is taken over, the pass runs (rc=0)" \
                 || bad "a stale lock wedged the supervisor (rc=$rc3)"
[ "$(spawn_count)" = "1" ] && ok "…and it refilled the order the wedged pass had left dead" \
                          || bad "spawn count after taking a stale lock: $(spawn_count), expected 1"

# ── (c) the capacity budget is respected ──────────────────────────────────────────────────────
echo "-- (c) capacity budget (never more than fix+review)"
reset
i=1
while [ "$i" -le 4 ]; do
  mkwt "$TMP/wt/prd-3$i" "fix/3$i"
  echo brief > "$TMP/briefs/prd-3$i.txt"
  mkorder "prd-3$i" "$TMP/wt/prd-3$i" "fix/3$i" "$TMP/briefs/prd-3$i.txt"
  i=$(( i + 1 ))
done
O="$O" SPAWNS="$SPAWNS" MAX_FIX=1 MAX_REVIEW=1 sup refill >"$TMP/cap.out" 2>&1; rcc=$?
[ "$rcc" = "6" ] && ok "rc=6 DEFERRED — the pass did not claim a clean pass over the two it could not refill" \
                 || bad "rc=$rcc, expected 6 (deferred)"
[ "$(spawn_count)" = "2" ] && ok "exactly fix+review (1+1=2) workers spawned for 4 dead orders" \
                           || bad "spawned $(spawn_count) for a capacity of 2"
[ "$(record_field live)" = "2" ] && ok "the record reads live=2/2" || bad "record live='$(record_field live)'"
grep -q 'budget full' "$ST/worker-supply.state" 2>/dev/null && ok "the record NAMES the bound it hit (budget full)" \
                                                           || bad "the record does not name the budget"

# ── (d) a worker that dies mid-order is replaced exactly once ─────────────────────────────────
echo "-- (d) mid-order death: replaced, re-offered EXACTLY once"
reset
mkwt "$TMP/wt/prd-21" fix/21
echo brief > "$TMP/briefs/prd-21.txt"
mkorder prd-21 "$TMP/wt/prd-21" fix/21 "$TMP/briefs/prd-21.txt" 2400 "2026-10-27 01:00:00"
live_worker prd-21                                   # the order's ORIGINAL worker, alive
O="$O" SPAWNS="$SPAWNS" MAX_FIX=3 MAX_REVIEW=4 sup refill >/dev/null 2>&1
[ "$(spawn_count)" = "0" ] && ok "a LIVE worker is never re-offered (one worker per PR)" \
                           || bad "a live worker was re-offered ($(spawn_count) spawns)"
# …killed mid-order: the pid file stays, the process is gone — the real shape
kill "$(cat "$BG/prd-21.pid" 2>/dev/null)" 2>/dev/null
sleep 0.2
[ "$(py_live_for 21)" = "absent" ] && ok "after the kill the order has no worker (doctor's reader: absent)" \
                                   || bad "doctor's reader did not see the death"
O="$O" SPAWNS="$SPAWNS" MAX_FIX=3 MAX_REVIEW=4 sup refill >/dev/null 2>&1
[ "$(spawns_for prd-21)" = "1" ] && ok "the dead order was re-offered ONCE" \
                                 || bad "re-offers after the death: $(spawns_for prd-21), expected 1"
O="$O" SPAWNS="$SPAWNS" MAX_FIX=3 MAX_REVIEW=4 sup refill >/dev/null 2>&1
[ "$(spawns_for prd-21)" = "1" ] && ok "a further pass does NOT re-offer it again (no duplicate execution)" \
                                 || bad "duplicate execution: $(spawns_for prd-21) re-offers"
[ "$(awk -F'\t' '$2=="prd-21"' "$ST/worker-supply-offers.tsv" 2>/dev/null | wc -l | tr -d ' ')" = "1" ] \
  && ok "the ledger holds exactly one offer row for that spawn instance" \
  || bad "ledger rows for prd-21: $(cat "$ST/worker-supply-offers.tsv" 2>/dev/null | tr '\n' ' ')"
# a SECOND death is a new spawn instance, so it may be re-offered again — up to the refill cap
sleep 1.1                                            # the stamp's resolution is one second
kill "$(cat "$BG/prd-21.pid" 2>/dev/null)" 2>/dev/null
sleep 0.2
O="$O" SPAWNS="$SPAWNS" MAX_FIX=3 MAX_REVIEW=4 sup refill >/dev/null 2>&1
[ "$(spawns_for prd-21)" = "2" ] && ok "a SECOND death is re-offered too (new spawn instance, new ledger row)" \
                                 || bad "second death re-offers: $(spawns_for prd-21), expected 2"
sleep 1.1
kill "$(cat "$BG/prd-21.pid" 2>/dev/null)" 2>/dev/null
sleep 0.2
O="$O" SPAWNS="$SPAWNS" MAX_FIX=3 MAX_REVIEW=4 sup refill >/dev/null 2>&1
[ "$(spawns_for prd-21)" = "2" ] && ok "at MAX_REFILLS=2 a third death STOPS the refills (a dying worker is a diagnosis, not supply)" \
                                 || bad "refill cap breached: $(spawns_for prd-21) re-offers at MAX_REFILLS=2"
grep -q 'spent its 2 refill' "$ST/worker-supply.log" 2>/dev/null && ok "…and the log names the exhausted order" \
                                                                 || bad "the exhausted order was not named"

# ── (e2) an order that COMPLETED is not re-offered, and a FAILED one is ──────────────────────────
# ⛔ FOUND BY REVIEW (P1), and it is the duplicate-execution direction the brief calls out one case
# over: the first version folded `--status`'s `done` into DEAD, so a worker that RAN ITS BRIEF TO
# COMPLETION was re-offered — re-executing finished work on the same worktree and bypassing the
# doctor's own re-grade (its next pass classifies the PR against its new head, checks and cooldown).
# Supply replaces workers that DIED; it never replays ones that finished.
echo "-- (e2) completed is not dead: no replay of a finished order"
reset
mkwt "$TMP/wt/prd-41" fix/41
mkwt "$TMP/wt/prd-42" fix/42
echo brief > "$TMP/briefs/prd-41.txt"
echo brief > "$TMP/briefs/prd-42.txt"
mkorder prd-41 "$TMP/wt/prd-41" fix/41 "$TMP/briefs/prd-41.txt"
mkorder prd-42 "$TMP/wt/prd-42" fix/42 "$TMP/briefs/prd-42.txt"
echo 0 > "$BG/prd-41.rc"          # the order RAN TO COMPLETION (the harness's own verdict)
echo 1 > "$BG/prd-42.rc"          # the order FAILED (a crashed worker: that IS supply's business)
O="$O" SPAWNS="$SPAWNS" MAX_FIX=3 MAX_REVIEW=4 sup refill >"$TMP/e2.out" 2>&1
e2rc=$?
[ "$(spawns_for prd-41)" = "0" ] && ok "a COMPLETED order (done rc=0) is NOT re-offered — finished work is never replayed" \
                                  || bad "a completed order was re-offered $(spawns_for prd-41)x — duplicate execution of finished work"
[ "$(spawns_for prd-42)" = "1" ] && ok "…and a FAILED order (rc=1) IS re-offered once (that is what supply is for)" \
                                  || bad "a failed order was NOT re-offered ($(spawns_for prd-42)) — the pool would never recover"
[ "$e2rc" = "0" ] && ok "the pass is CLEAN (rc=0): a completed order is not work still waiting" \
                  || bad "pass rc=$e2rc — a completed order was reported as a deferred/dead one"
[ "$(record_field complete)" = "1" ] && ok "the record counts it as complete=1 (a state of its own, not a dead one)" \
                                      || bad "record complete='$(record_field complete)', expected 1"

# ── (e3) a DRY RUN writes NOTHING — the record is the last REAL pass's evidence ────────────────
echo "-- (e3) --dry-run is a rehearsal: no record, no ledger row, no spawn"
reset
mkwt "$TMP/wt/prd-51" fix/51
echo brief > "$TMP/briefs/prd-51.txt"
mkorder prd-51 "$TMP/wt/prd-51" fix/51 "$TMP/briefs/prd-51.txt"
O="$O" SPAWNS="$SPAWNS" MAX_FIX=3 MAX_REVIEW=4 sup --dry-run >"$TMP/dry.out" 2>&1; dryrc=$?
[ "$dryrc" = "0" ] && ok "the dry run exits 0 (a rehearsal is not a pass verdict)" || bad "dry run rc=$dryrc"
[ "$(spawn_count)" = "0" ] && ok "the dry run spawned NOTHING" || bad "the dry run spawned $(spawn_count)"
[ -f "$ST/worker-supply.state" ] && bad "the dry run WROTE a pass record — it would overwrite the last real pass's evidence" \
                                || ok "the dry run wrote NO pass record (the last real pass stays readable)"
[ -f "$ST/worker-supply-offers.tsv" ] && bad "the dry run wrote a ledger row" \
                                      || ok "…and no offer ledger row"
grep -q 'DRY-RUN pass:' "$TMP/dry.out" 2>/dev/null && ok "…and it says what it WOULD have done (DRY-RUN pass: … would-refill=1)" \
                                                  || bad "the dry run printed no DRY-RUN verdict line"

# ── (f) safety and single-source guards ──────────────────────────────────────────────────────
echo "-- (f) guards: not a merge authority, capacity from ONE home, no second spawn path"
# ⛔ GRADE THE CODE, NOT THE PROSE. This file's own header PROMISES it never calls `admin-merge.sh` or
# `record-review.sh`, so a whole-file grep reddens on the promise that makes it auditable. A call can
# only live on a non-comment line, so comment lines are stripped first and the guard reads what is left.
CODE="$TMP/supply.code"
grep -v '^[[:space:]]*#' "$SUPPLY" > "$CODE" 2>/dev/null || : > "$CODE"
if grep -Eq 'admin-merge|record-review|gh pr merge|gh api|"gh"|(^|[^a-z])gh ' "$CODE" 2>/dev/null; then
  bad "worker-supply.sh contains a gh/merge/attestation call — a supervisor that can land a PR is a second merge path"
else
  ok "worker-supply.sh never calls gh, admin-merge.sh or record-review.sh (it supplies, it does not land)"
fi
grep -q 'bash "\$DISPATCH"' "$CODE" && ok "…and it INVOKES the ONE dispatcher (\`bash \"\$DISPATCH\" …\`), never 'pi' directly" \
                                       || bad "the one dispatcher is not the invocation path in worker-supply.sh"
grep -Eq '(^|[^_a-z])pi \$\{|exec pi|"\$PI"' "$SUPPLY" 2>/dev/null && bad "the supervisor invokes pi itself (a second spawn path)" \
                                                                 || ok "…no direct 'pi' invocation anywhere"

# capacity pinned to pr-doctor's OWN reader: three shapes where a hand-rolled second copy would drift
pl="$TMP/plist.plist"
MAX_FIX=9 MAX_REVIEW=7 python3 - "$pl" <<'PY' 2>/dev/null
import plistlib, sys
plistlib.dump({"EnvironmentVariables": {"MAX_FIX": "9", "MAX_REVIEW": "7"}}, open(sys.argv[1], "wb"))
PY
if [ -f "$pl" ]; then
  # the READER is graded through `status`, which prints exactly what it read
  stat_line="$(O="$O" WORKER_SUPPLY_ORCH_PLIST="$pl" env -u MAX_FIX -u MAX_REVIEW bash "$SUPPLY" status 2>/dev/null | grep -o 'fix=[0-9]* review=[0-9]*' | head -1)"
  [ "$stat_line" = "fix=9 review=7" ] && ok "capacity read from the orchestrator plist when the env is unset ($stat_line)" \
                                     || bad "plist capacity read '$stat_line', expected fix=9 review=7"
  want="$(py_capacity 9 7)"; [ "$stat_line" = "fix=${want%% *} review=${want##* }" ] \
    && ok "…and it equals pr-doctor.capacity() for the same source (ONE home for the budget)" \
    || bad "capacity diverged from pr-doctor's own reader ($stat_line vs '$want')"
  stat_line="$(O="$O" WORKER_SUPPLY_ORCH_PLIST="$pl" MAX_FIX=010 MAX_REVIEW= MAX_REVIEW= bash "$SUPPLY" status 2>/dev/null | grep -o 'fix=[0-9]* review=[0-9]*' | head -1)"
  want="$(py_capacity 010 "")"
  [ "$stat_line" = "fix=${want%% *} review=${want##* }" ] \
    && ok "an INVALID override ($stat_line) coerces exactly as pr-doctor does — no fail-open budget" \
    || bad "invalid-override divergence: '$stat_line' vs pr-doctor '$want'"
  stat_line="$(O="$O" WORKER_SUPPLY_ORCH_PLIST="$pl" MAX_FIX=2 MAX_REVIEW=5 bash "$SUPPLY" status 2>/dev/null | grep -o 'fix=[0-9]* review=[0-9]*' | head -1)"
  [ "$stat_line" = "fix=2 review=5" ] && ok "the environment WINS over the plist ($stat_line)" \
                                     || bad "env did not win: '$stat_line'"
else
  bad "could not write the fixture plist"
fi

# ── (g) the shipped supervision artifacts ───────────────────────────────────────────────────
echo "-- (g) the unit/plist that make the supervisor SUPERVISED"
[ -f "$UNIT_TPL" ] || bad "missing $UNIT_TPL"
if [ -f "$UNIT_TPL" ]; then
  grep -q '^ExecStart=/bin/bash {{SCRIPT}} --loop' "$UNIT_TPL" && ok "the systemd unit runs the supervisor's --loop" \
                                                              || bad "the unit's ExecStart does not name --loop"
  # ⛔ THE #2716 PROPERTY: a re-offer backgrounds a worker, so a cgroup teardown at the end of a pass
  # would SIGTERM the worker it just started. Asserted for the shipped unit rather than remembered.
  grep -q '^KillMode=process' "$UNIT_TPL" && ok "the unit carries KillMode=process (a worker outlives the pass)" \
                                          || bad "the unit lacks KillMode=process — it would kill the workers it spawns"
  grep -q '^Restart=always' "$UNIT_TPL" && ok "the unit carries Restart=always (an orderly exit must come back)" \
                                        || bad "the unit does not carry Restart=always"
  # ⛔ A SECOND COPY OF THE BUDGET WOULD BE A FAIL-OPEN BUDGET, so the guard grades the DIRECTIVES: the
  # unit's own comment names MAX_FIX/MAX_REVIEW to say it deliberately does not set them, and a
  # whole-file grep would redden on that explanation (the comment line is the OPPOSITE of the defect).
  unit_code="$(grep -v '^[[:space:]]*#' "$UNIT_TPL" 2>/dev/null || true)"
  case "$unit_code" in
    *MAX_FIX*|*MAX_REVIEW*) bad "the unit renders its own MAX_FIX/MAX_REVIEW — a second copy of the budget" ;;
    *) ok "the unit does NOT set MAX_FIX/MAX_REVIEW (one home for the budget: the orchestrator plist)" ;;
  esac
fi
[ -f "$PLIST_TPL" ] || bad "missing $PLIST_TPL"
if [ -f "$PLIST_TPL" ]; then
  grep -q 'worker-supply.sh' "$PLIST_TPL" && grep -q '<string>--loop</string>' "$PLIST_TPL" \
    && ok "the launchd job runs the same core (--loop)" || bad "the plist does not run the supervisor's --loop"
  awk '/<key>KeepAlive<\/key>/{ getline; print }' "$PLIST_TPL" | grep -q '<true/>' \
    && ok "the launchd job is KeepAlive (it comes back from a crash, a kill and an orderly exit)" \
    || bad "the plist is not KeepAlive"
fi

# the installer: one command, both platforms, fail-closed rendering
if [ -f "$INSTALLER" ]; then
  out="$(ELDATO_PLATFORM=Linux UNIT_DIR="$TMP/units" SYSTEMCTL=/bin/true WORKER_SUPPLY_SCRIPT="$SUPPLY" \
        bash "$INSTALLER" --dry-run 2>&1)"
  case "$out" in
    *'{{'*) bad "the installer's dry-run left a placeholder in the rendered unit" ;;
    *ExecStart*) ok "a Linux install renders the unit from one command (dry-run, no service manager touched)" ;;
    *) bad "the installer dry-run rendered no ExecStart: $(printf '%s' "$out" | head -3)" ;;
  esac
  case "$out" in
    *"$SUPPLY"*) ok "the rendered ExecStart names the resolved script ($SUPPLY)" ;;
    *) bad "the rendered unit does not name the resolved script" ;;
  esac
  ELDATO_PLATFORM=Darwin WORKER_SUPPLY_SCRIPT="$SUPPLY" bash "$INSTALLER" --dry-run >"$TMP/darwin.out" 2>&1
  rcd=$?
  [ "$rcd" != "0" ] && grep -q 'install-launchd.sh' "$TMP/darwin.out" \
    && ok "on macOS the Linux installer REFUSES and names the one launchd installer (no second launchd path)" \
    || bad "the installer did not refuse on Darwin with the launchd pointer (rc=$rcd)"
  # ⛔ THE BYTE-IDENTICAL NO-OP (found by review, P2). The installer's own comment promised "a no-op
  # must stay a no-op: restarting a healthy supervisor costs an interval of supply for nothing", and
  # the code restarted it anyway. Pinned here, against a stub manager that records every call.
  SC="$TMP/systemctl"; SC_CALLS="$TMP/sc.calls"; export SC_CALLS
  cat > "$SC" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SC_CALLS:?}"
case "$1" in is-active) exit 0 ;; *) exit 0 ;; esac
EOS
  chmod +x "$SC"
  : > "$SC_CALLS"
  O="$O" SUDO=false ELDATO_PLATFORM=Linux UNIT_DIR="$TMP/units2" SYSTEMCTL="$SC" \
    WORKER_SUPPLY_SCRIPT="$SUPPLY" bash "$INSTALLER" --install >"$TMP/inst1.out" 2>&1
  first_restarts="$(grep -c '^restart' "$SC_CALLS" 2>/dev/null | tr -d ' ')"
  : > "$SC_CALLS"
  O="$O" SUDO=false ELDATO_PLATFORM=Linux UNIT_DIR="$TMP/units2" SYSTEMCTL="$SC" \
    WORKER_SUPPLY_SCRIPT="$SUPPLY" bash "$INSTALLER" --install >"$TMP/inst2.out" 2>&1
  second_restarts="$(grep -c '^restart' "$SC_CALLS" 2>/dev/null | tr -d ' ')"
  [ -f "$TMP/units2/eldato-worker-supply.service" ] && ok "a first --install writes the unit" \
    || bad "a first --install wrote no unit: $(tail -2 "$TMP/inst1.out")"
  [ "${first_restarts:-0}" -ge 1 ] && ok "…and restarts it once ($first_restarts restart call(s))" \
    || bad "a first --install never restarted the unit (calls: $(tr '\n' ' ' < "$SC_CALLS"))"
  [ "${second_restarts:-1}" = "0" ] && ok "a re-install of the BYTE-IDENTICAL unit restarts NOTHING — a no-op stays a no-op" \
    || bad "an unchanged re-install restarted the supervisor ($second_restarts restart call(s)) — it costs an interval of supply for nothing"
else
  bad "missing $INSTALLER"
fi

# ── (e) MUTATION: neuter the refill step, and (a) must redden ─────────────────────────────────
echo "-- (e) mutation: a no-op refill step must redden (a)"
MUT="$TMP/worker-supply.mutant.sh"
sed 's|^    out="\$(bounded "\$SPAWN_CALL_TIMEOUT" bash "\$DISPATCH".*|    out=""; rc=0   # MUTATION: the refill step does nothing|' \
  "$SUPPLY" > "$MUT"
if cmp -s "$SUPPLY" "$MUT"; then
  bad "the mutation did not apply (the refill call was not found) — a mutation test that cannot mutate proves nothing"
else
  reset
  mkwt "$TMP/wt/prd-11" fix/11
  echo brief > "$TMP/briefs/prd-11.txt"
  mkorder prd-11 "$TMP/wt/prd-11" fix/11 "$TMP/briefs/prd-11.txt" 2400 "2026-10-27 01:00:00"
  O="$O" SPAWNS="$SPAWNS" MAX_FIX=3 MAX_REVIEW=4 bash "$MUT" refill >/dev/null 2>&1
  n_mut="$(spawn_count)"; live_mut="$(py_live_for 11)"
  if [ "$n_mut" = "0" ] && [ "$live_mut" = "absent" ]; then
    ok "with the refill step neutered the (a) assertion REDDENS: spawns=$n_mut, doctor's reader=$live_mut — the test really tests the refill"
  else
    bad "the mutation did NOT redden (a): spawns=$n_mut reader=$live_mut — (a) would pass on a supervisor that refills nothing"
  fi
fi

# ── (i) MUTATION: remove the single-instance guard, and (b) must redden ────────────────────────
echo "-- (i) mutation: no single-instance guard must redden (b)"
MUT2="$TMP/worker-supply.nolock.sh"
sed 's|^lock_take() {|lock_take() { return 0   # MUTATION: the single-instance guard is gone|' \
  "$SUPPLY" > "$MUT2"
if cmp -s "$SUPPLY" "$MUT2"; then
  bad "the lock mutation did not apply (\`lock_take() {\` was not found) — a mutation that cannot mutate proves nothing"
else
  reset
  mkwt "$TMP/wt/prd-13" fix/13
  echo brief > "$TMP/briefs/prd-13.txt"
  mkorder prd-13 "$TMP/wt/prd-13" fix/13 "$TMP/briefs/prd-13.txt"
  # the same shape as (b): a live supervisor holding the guard, then a second one against it
  O="$O" SPAWNS="$SPAWNS" WORKER_SUPPLY_INTERVAL_S=60 MAX_FIX=3 MAX_REVIEW=4 \
    bash "$MUT2" --loop >"$TMP/mut2loop.out" 2>&1 &
  M2_PID=$!
  echo "$M2_PID" >> "$PIDS"
  sleep 0.5
  O="$O" SPAWNS="$SPAWNS" MAX_FIX=3 MAX_REVIEW=4 bash "$MUT2" refill >"$TMP/mut2.out" 2>&1; rc2m=$?
  [ "$rc2m" != "4" ] \
    && ok "with the lock neutered the (b) assertion REDDENS: the second supervisor exited $rc2m, not 4 — two supervisors would drain the same pool together" \
    || bad "the mutation did NOT redden (b): the second supervisor still refused with 4"
  kill -TERM "$M2_PID" 2>/dev/null
  for (( _i = 0; _i < 50; _i++ )); do kill -0 "$M2_PID" 2>/dev/null || break; sleep 0.1; done
  kill -9 "$M2_PID" 2>/dev/null; wait "$M2_PID" 2>/dev/null
fi

# ── (h) THE WALL-CLOCK BOUND ──────────────────────────────────────────────────────────────────────────
# ⛔ THIS IS A TEST, NOT A COMMENT. The first attempt at this fix died inside its own suite: 45 minutes
# and no result, so the fix never shipped. An unbounded test is a defect in the deliverable, so the
# duration is measured and asserted like any other property.
echo "-- (h) the suite's own wall-clock"
SUITE_END=$(date +%s); ELAPSED=$(( SUITE_END - SUITE_START ))
echo "   suite wall-clock: ${ELAPSED}s (bound 60s, fake-worker slice ${WORKER_STUB_LIFETIME}s)"
[ "$ELAPSED" -le 60 ] && ok "the suite finished in ${ELAPSED}s, inside its 60s bound" \
                      || bad "the suite took ${ELAPSED}s — an unbounded test is why the fix never shipped"

echo
echo "passed=$PASS failed=$FAIL (${ELAPSED}s)"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
