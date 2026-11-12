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
# The suite is timed at the end and must stay inside `SUITE_BOUND_S` (180 s — raised from 60 s by
# measurement, not preference: the suite takes ~100-120 s on a saturated 10-CPU box, printed beside the
# number so the next reader can tell saturation from an unbounded test).
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

# ⛔ THE FIXTURE BRIEFS MUST SATISFY THE GATE THAT JUDGES THEM (agent-infra#3958). Every re-offer is
# REVALIDATED against `brief-gate.sh` now, so the old bare `echo brief > …` fixture is a brief the real
# gate REFUSES — a brief that could not be dispatched on any real box. Left as it was, every healthy-path
# case below would redden for the FIXTURE's sake instead of for the behaviour it grades, which is the
# "grading my own stub" trap this suite's header warns about in the other direction.
# The admitted brief is RENDERED BY THE SHIPPED GATE (`--section worker` — the same call `pr-doctor`
# splices into every worker brief, so a healthy fixture is byte-identical in kind to a real order) and
# cached ONCE: the gate costs ~0.2 s and the suite has a bounded wall clock (`SUITE_BOUND_S`, 180 s).
# Case (j) keeps a REFUSED brief on purpose, and asserts the gate really refuses it.
ADMITTED_BRIEF="$TMP/admitted-brief.txt"
bash "$HERE/brief-gate.sh" --section worker > "$ADMITTED_BRIEF" 2>/dev/null
if bash "$HERE/brief-gate.sh" --check "$ADMITTED_BRIEF" worker >/dev/null 2>&1; then
  ok "fixture: the shipped brief gate ADMITS its own rendered worker brief (a healthy re-offer is a real, dispatcheable order)"
else
  bad "fixture: \`brief-gate.sh --section worker\` renders a brief its own --check REFUSES — the healthy-path cases would grade the fixture, not the supervisor"
fi
mkbrief() { # <path> — an order brief the gate will ADMIT
  cp "$ADMITTED_BRIEF" "$1" 2>/dev/null || :
  return 0
}

# ── (a) a dead worker is refilled ─────────────────────────────────────────────────────────────
echo "-- (a) dead worker refilled"
reset
mkwt "$TMP/wt/prd-11" fix/11
mkbrief "$TMP/briefs/prd-11.txt"
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
mkbrief "$TMP/briefs/prd-12.txt"
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
# ⛔ THE LOOP'S OWN FIRST PASS MUST HAVE FINISHED BEFORE THE COUNT IS TAKEN. The lock file appears as
# soon as the loop takes it, which is BEFORE its first pass spawns anything, so capturing the count
# there races the very work this assertion tries to isolate (measured: 0 -> 1, a false failure, after
# a change that made the first pass slower). The pass record is written at the END of a pass — wait
# for it, bounded, then count.
for (( _w = 0; _w < 100; _w++ )); do
  [ -f "$ST/worker-supply.state" ] && break
  sleep 0.1
done
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
# ⛔ THE ASSERTION MUST BE ABOUT WHAT *THIS* PASS DID. The loop's own first pass already refilled
# prd-12, so an absolute `spawn_count = 1` is satisfied by work another pass did: it cannot fail,
# and it labelled itself "it refilled the order the wedged pass had left dead" while the takeover
# pass spawned nothing at all (reproduced: its record reads `live=1/7 dead=0 refilled=0`). Capture
# the count BEFORE the takeover and assert it is unchanged, plus the absence of a re-offer line.
n_stale="$(spawn_count)"
O="$O" SPAWNS="$SPAWNS" MAX_FIX=3 MAX_REVIEW=4 sup refill >"$TMP/stale.out" 2>&1; rc3=$?
[ "$rc3" = "0" ] && ok "a stale lock (dead holder pid) is taken over, the pass runs (rc=0)" \
                 || bad "a stale lock wedged the supervisor (rc=$rc3)"
[ "$(spawn_count)" = "$n_stale" ] && ok "…and that pass spawned NOTHING it did not need to ($n_stale before, $(spawn_count) after — the one order it inherited is already running)" \
                                  || bad "the takeover pass spawned $(spawn_count - n_stale) worker(s) of its own ($n_stale -> $(spawn_count))"
! grep -q 'RE-OFFERED' "$TMP/stale.out" 2>/dev/null && ok "…and it printed no RE-OFFERED line (a running order is not re-offered)" \
                                             || bad "the takeover pass re-offered a running order: $(grep 'RE-OFFERED' "$TMP/stale.out" | head -1)"

# ── (c) the capacity budget is respected ──────────────────────────────────────────────────────
echo "-- (c) capacity budget (never more than fix+review)"
reset
i=1
while [ "$i" -le 4 ]; do
  mkwt "$TMP/wt/prd-3$i" "fix/3$i"
mkbrief "$TMP/briefs/prd-3$i.txt"
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
mkbrief "$TMP/briefs/prd-21.txt"
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

# ── (d4) THE BOUND MUST NOT GO INERT FROM A TYPO ────────────────────────────────────
# ⛔ FOUND BY REVIEW (#2896 round 2, P2), and it failed OPEN: `[ "$(refills_of …)" -ge "$MAX_REFILLS" ]`
# with a non-numeric MAX_REFILLS does not fail the pass — it fails to PARSE, the `if` reads FALSE, and
# the order is re-offered for ever with nothing in the record saying the bound was never applied.
# `WORKER_SUPPLY_INTERVAL_S=abc` is the same class one knob over: `sleep` returns at once, so `--loop`
# re-passes with no cadence. Pinned BEHAVIOURALLY, not by grepping for the guard: `status` reports the
# knob it actually resolved, and the cap still HOLDS at the fallback.
reset
mkdir -p "$BG" 2>/dev/null
mkwt "$TMP/wt/prd-31" fix/31
mkbrief "$TMP/briefs/prd-31.txt"
mkorder prd-31 "$TMP/wt/prd-31" fix/31 "$TMP/briefs/prd-31.txt" 2400 "2026-10-27 01:00:00"
knob_line="$(O="$O" WORKER_SUPPLY_MAX_REFILLS=two WORKER_SUPPLY_INTERVAL_S=abc WORKER_SUPPLY_PREFIX='prd -' \
             bash "$SUPPLY" status 2>/dev/null | grep -o 'interval_s=[0-9]* max_refills=[0-9]* prefix=[^ ]*' | head -1)"
[ "$knob_line" = "interval_s=60 max_refills=2 prefix=prd-" ] \
  && ok "an UNREADABLE override falls back to the shipped default and SAYS so ($knob_line)" \
  || bad "the invalid overrides were not normalised: '$knob_line' (expected interval_s=60 max_refills=2 prefix=prd-)"
O="$O" SPAWNS="$SPAWNS" WORKER_SUPPLY_MAX_REFILLS=two MAX_FIX=3 MAX_REVIEW=4 sup refill >/dev/null 2>&1
[ "$(spawns_for prd-31)" = "1" ] && ok "…and a pass still re-offers the dead order (the typo does not disable supply)" \
                                 || bad "the invalid override stopped the refill: $(spawns_for prd-31) spawns"
sleep 1.1
kill "$(cat "$BG/prd-31.pid" 2>/dev/null)" 2>/dev/null
sleep 0.2
O="$O" SPAWNS="$SPAWNS" WORKER_SUPPLY_MAX_REFILLS=two MAX_FIX=3 MAX_REVIEW=4 sup refill >/dev/null 2>&1
[ "$(spawns_for prd-31)" = "2" ] && ok "…a second death is re-offered (2 of the fallback's 2)" \
                                 || bad "second death re-offers: $(spawns_for prd-31), expected 2"
sleep 1.1
kill "$(cat "$BG/prd-31.pid" 2>/dev/null)" 2>/dev/null
sleep 0.2
O="$O" SPAWNS="$SPAWNS" WORKER_SUPPLY_MAX_REFILLS=two MAX_FIX=3 MAX_REVIEW=4 sup refill >/dev/null 2>&1
[ "$(spawns_for prd-31)" = "2" ] && ok "…and the cap HOLDS at the fallback: a third death stops the refills (the typo cannot make the bound inert)" \
                                 || bad "the crash-loop bound was INERT under a non-numeric override: $(spawns_for prd-31) re-offers"

# ── (d2) ONE WORKTREE, TWO NAMES — the guard that stops a second worker into a live tree ────────
# ⛔ FOUND BY REVIEW (#2896 round 1, P1), and it is the documented #2280 defect one layer down.
# `pr-doctor.worker_name()` is MODE-QUALIFIED (`prd-<tag>-42` in a multi-repo pass) while the
# WORKTREE is `prd-42` in BOTH modes, so two orders can name one directory. `worker_live_for`
# (pr-doctor.py:3526) probes BOTH names for exactly this reason; `nonblocking-dispatch.sh` performs
# NO liveness check itself, so a supervisor that asks only the order's own name re-offers into a
# tree whose other-named worker is RUNNING — a second agent on one git index, one branch, and the
# live worker's log/.rc/.pid destroyed. Each assertion below fails if the guard is removed.
echo "-- (d2) one worktree, two names: no second worker into a live tree"
# (i) the ALIAS arm: `prd-42` runs, and the DEAD order is the mode-qualified name for the SAME tree.
reset
mkwt "$TMP/wt/prd-42" fix/42
mkbrief "$TMP/briefs/prd-42.txt"
live_worker prd-42                                     # the single-repo pass's worker: LIVE, no order file
mkorder prd-daniel-ospina-tortoise-42 "$TMP/wt/prd-42" fix/42 "$TMP/briefs/prd-42.txt"
[ "$(py_live_for 42)" = "live" ] && ok "the doctor's own reader says PR 42 is LIVE ($(cat "$BG/prd-42.pid"))" \
                                || bad "fixture is wrong: the doctor's reader does not see a live worker"
O="$O" SPAWNS="$SPAWNS" MAX_FIX=3 MAX_REVIEW=4 sup refill >"$TMP/d2a.out" 2>&1; d2arc=$?
[ "$(spawns_for prd-daniel-ospina-tortoise-42)" = "0" ] \
  && ok "…so the DEAD order naming the same worktree is NOT re-offered under its other name (0 spawns)" \
  || bad "the alias guard is missing: $(spawns_for prd-daniel-ospina-tortoise-42) worker(s) spawned into a live tree"
grep -q 'another order holds its worktree' "$TMP/d2a.out" 2>/dev/null \
  && ok "…and it SAYS why (the holder is named, not silently skipped)" \
  || bad "the refusal did not name the worktree holder: $(head -3 "$TMP/d2a.out")"
[ "$(record_field live)" = "1" ] && ok "the pool census moves with it: the order reads live=1 (a held slot), not dead" \
                                 || bad "record live='$(record_field live)', expected 1 — a live holder is a held slot"
# (ii) the POPULATION arm: BOTH names have an order file, the second one DEAD, the first LIVE.
reset
mkwt "$TMP/wt/prd-43" fix/43
mkbrief "$TMP/briefs/prd-43.txt"
mkorder prd-43 "$TMP/wt/prd-43" fix/43 "$TMP/briefs/prd-43.txt"
live_worker prd-43
mkorder prd-daniel-ospina-tortoise-43 "$TMP/wt/prd-43" fix/43 "$TMP/briefs/prd-43.txt"
O="$O" SPAWNS="$SPAWNS" MAX_FIX=3 MAX_REVIEW=4 sup refill >"$TMP/d2b.out" 2>&1
[ "$(spawns_for prd-daniel-ospina-tortoise-43)" = "0" ] \
  && ok "two order FILES on one worktree: the dead one is not re-offered while the other runs (0 spawns)" \
  || bad "the population arm of the guard is missing: $(spawns_for prd-daniel-ospina-tortoise-43) spawn(s)"
# (iii) UNANSWERABLE wins over a negative: the holder's `running` is past its own cap+slack, so the
# harness cannot be trusted — the safe direction is still not to spawn.
reset
mkwt "$TMP/wt/prd-44" fix/44
mkbrief "$TMP/briefs/prd-44.txt"
mkorder prd-44 "$TMP/wt/prd-44" fix/44 "$TMP/briefs/prd-44.txt" 60 "2026-10-27 01:00:00"   # ancient stamp
# ⛔ THE STALE-CLAIM IS COMPUTED FROM THE RECORD'S MTIME, NOT ITS `started=` FIELD (`mtime_of "$stamp"`
# in ask_status), so the FILE must be aged: a fresh file holding an old stamp is NOT stale.
touch -d '3 hours ago' "$BG/prd-44.started" 2>/dev/null || touch -t 202601010101 "$BG/prd-44.started"
live_worker prd-44
mkorder prd-daniel-ospina-tortoise-44 "$TMP/wt/prd-44" fix/44 "$TMP/briefs/prd-44.txt"
O="$O" SPAWNS="$SPAWNS" MAX_FIX=3 MAX_REVIEW=4 sup refill >"$TMP/d2c.out" 2>&1
[ "$(spawns_for prd-daniel-ospina-tortoise-44)" = "0" ] \
  && ok "an UNANSWERABLE holder (stale claim) spawns NOTHING — the safe direction is not to spawn blind" \
  || bad "an unreadable holder was treated as freedom to spawn ($(spawns_for prd-daniel-ospina-tortoise-44) spawn(s))"
[ "$(record_field unknown)" -ge 1 ] 2>/dev/null \
  && ok "…and the census records it as unknown (not as dead, and not as a held slot)" \
  || bad "record unknown='$(record_field unknown)', expected >=1"
# (iv) the guard must NOT block a worktree nobody else holds — the same fixture, one name, refills.
reset
mkwt "$TMP/wt/prd-45" fix/45
mkbrief "$TMP/briefs/prd-45.txt"
mkorder prd-45 "$TMP/wt/prd-45" fix/45 "$TMP/briefs/prd-45.txt"
O="$O" SPAWNS="$SPAWNS" MAX_FIX=3 MAX_REVIEW=4 sup refill >/dev/null 2>&1
[ "$(spawns_for prd-45)" = "1" ] && ok "a worktree nobody holds is still refilled (the guard is not a blanket refusal)" \
                                 || bad "the guard blocked an unheld worktree ($(spawns_for prd-45) spawns)"

# ── (d5) A POOL THE PASS COULD NOT READ IS NOT A CLEAN PASS ───────────────────────────────────━
# ⛔ FOUND BY REVIEW (#2896 round 3, P2). Every UNKNOWN path fell through to the verdict's `clean`
# arm, so a pass whose only order was a stale claim printed `pass: clean — live=0/7 unknown=1` and
# exited 0: the doctor's `capacity … inflight=0` health theatre reproduced one layer down, and a direct
# contradiction of exit code 2 ("a read a pass needs could not be taken"). It also LOST the dead order
# from the census when a worktree holder was unreadable, which is why the assertion below is on the
# census too and not only on rc.
reset
mkwt "$TMP/wt/prd-46" fix/46
mkbrief "$TMP/briefs/prd-46.txt"
mkorder prd-46 "$TMP/wt/prd-46" fix/46 "$TMP/briefs/prd-46.txt" 60 "2026-10-27 01:00:00"
touch -d '3 hours ago' "$BG/prd-46.started" 2>/dev/null || touch -t 202601010101 "$BG/prd-46.started"
live_worker prd-46                                    # answers `running`, past its own cap+slack
O="$O" SPAWNS="$SPAWNS" MAX_FIX=3 MAX_REVIEW=4 sup refill >"$TMP/d5.out" 2>&1; rc5=$?
[ "$rc5" = "2" ] && ok "a pass that supplied nothing because it could NOT READ the pool exits 2 (REFUSING), not 0" \
                 || bad "an unreadable pool reported rc=$rc5, expected 2 (a clean pass over a pool nobody could read)"
[ "$(record_field decision)" = "unreadable" ] && ok "…and the record says so (decision=unreadable), instead of `clean`" \
                                             || bad "record decision='$(record_field decision)', expected unreadable"
[ "$(record_field unknown)" -ge 1 ] 2>/dev/null && ok "…with the unreadable order counted (unknown=$(record_field unknown))" \
                                               || bad "the census lost the unknown: '$(record_field unknown)'"
[ "$(spawn_count)" = "0" ] && ok "…and nothing was spawned (an unreadable order is never read as free)" \
                          || bad "an unreadable order was spawned into ($(spawn_count) spawns)"

# ── (d6) A TYPO IN THE LOCK BOUND MUST NOT TURN A YOUNG LOCK INTO A STALE ONE ─────────────────━
# ⛔ FOUND BY REVIEW (#2896 round 3, P2) — the worst of the knob class, because its fail-open is the
# DOUBLE SUPERVISOR: `[ $((now - age)) -lt "$LOCK_MAX_S" ]` with a non-numeric bound does not parse,
# the `if` reads false, and a pid-less lock is TAKEN OVER while its holder is alive and between `mkdir`
# and its pid write. Round 2 guarded the render-time knobs only; the lock bound is the same rule.
reset
mkdir -p "$ST/worker-supply.lock" 2>/dev/null   # held, no pid yet, freshly created => YOUNG
O="$O" SPAWNS="$SPAWNS" WORKER_SUPPLY_LOCK_MAX_S=abc MAX_FIX=3 MAX_REVIEW=4 sup refill >"$TMP/lockknob.out" 2>&1; rcl=$?
[ "$rcl" = "4" ] && ok "a non-numeric LOCK_MAX_S still refuses as ALREADY-RUNNING (rc=4) — the lock is not taken over" \
                 || bad "rc=$rcl with LOCK_MAX_S=abc: a young lock with no pid was taken over (fail-open, two supervisors)"
[ -d "$ST/worker-supply.lock" ] && ok "…and the lock directory is untouched (no takeover happened)" \
                                 || bad "the young lock was removed by an unreadable bound"
grep -q 'ALREADY-RUNNING' "$TMP/lockknob.out" 2>/dev/null && ok "…and it SAYS the lock is held (ALREADY-RUNNING), rather than classifying it stale" \
                                                           || bad "the refusal did not name the lock: $(head -2 "$TMP/lockknob.out")"

# ── (j) A BRIEF THE GATE REFUSES IS NEVER RE-OFFERED UNCHANGED (agent-infra#3958) ────────────────━
# ⛔ THE MEASURED DEFECT. A re-offer replays the argv `nonblocking-dispatch.sh` recorded at ACCEPT time,
# and one of those arguments is the brief PATH — so a brief written once during a bad window was handed
# to the gate on EVERY pass and refused `rc=80` for ever: `orders=100 live=0/18 dead=83 … 72
# re-offer(s) refused`, pass after pass, while the composer (`pr-doctor.py`) rewrites briefs correctly
# and its own passes were logging `research contract rendered … admitted by 1 validator(s)`.
# THE INVARIANT: a brief the gate refuses never reaches the dispatcher again, the skip is reported as a
# REGENERATION NEED (naming the composer) rather than as a dispatch attempt, and it spends none of the
# order's refills — so the order recovers the moment the composer rewrites the brief.
echo "-- (j) a refused (stale) brief is never re-offered: REGENERATION REQUIRED, no refill spent"
reset
mkwt "$TMP/wt/prd-71" fix/71
printf '## ORDER — re-run the checks on this head\n\n(the 18-day-old shape: no research contract)\n' > "$TMP/briefs/prd-71.txt"
cp "$TMP/briefs/prd-71.txt" "$TMP/briefs/prd-71.fossil"      # the bytes must survive the pass
mkorder prd-71 "$TMP/wt/prd-71" fix/71 "$TMP/briefs/prd-71.txt" 2400 "2026-10-24 23:03:00"
bash "$HERE/brief-gate.sh" --check "$TMP/briefs/prd-71.txt" worker >/dev/null 2>&1
[ "$?" = "80" ] && ok "fixture: the shipped gate REFUSES this brief (rc=80) — the fossil shape measured on the box" \
                || bad "fixture: the shipped gate did not refuse the stale brief, so case (j) would grade nothing"
O="$O" SPAWNS="$SPAWNS" MAX_FIX=3 MAX_REVIEW=4 sup refill >"$TMP/j.out" 2>&1; jrc=$?
[ "$(spawns_for prd-71)" = "0" ] && ok "the refused brief was NEVER handed to the dispatcher (0 spawns) — the fossil is not replayed" \
                                 || bad "the refused brief WAS re-offered $(spawns_for prd-71)x — the invariant is missing"
grep -q 'REFUSED by the brief gate (rc=80)' "$TMP/j.out" 2>/dev/null && grep -q 'REGENERATION REQUIRED' "$TMP/j.out" 2>/dev/null \
  && ok "…and the skip is REPORTED as a regeneration need, quoting the gate's own rc (REGENERATION REQUIRED)" \
  || bad "the skip was not logged as a regeneration need: $(head -3 "$TMP/j.out")"
grep -q 'pr-doctor' "$TMP/j.out" 2>/dev/null && ok "…and it names the one COMPOSER (pr-doctor.py) — this supervisor does not invent an order" \
                                            || bad "the regeneration line does not name the composer"
cmp -s "$TMP/briefs/prd-71.txt" "$TMP/briefs/prd-71.fossil" \
  && ok "…and the brief file is BYTE-IDENTICAL: the supervisor neither edits nor deletes a fossil" \
  || bad "the supervisor MODIFIED the cached brief — editing the symptom teaches the loop nothing"
[ -f "$ST/worker-supply-offers.tsv" ] && bad "a skip wrote a LEDGER row — it would spend one of the order's MAX_REFILLS" \
                                     || ok "…and no ledger row was written (a regeneration is not a failed worker, so no refill is spent)"
[ "$jrc" = "6" ] && ok "the pass is DEFERRED (rc=6) — it supplied nothing and did not call itself clean" \
                || bad "pass rc=$jrc, expected 6 (a pass that skipped its only dead order is not a clean pass)"
[ "$(record_field stale_briefs)" = "1" ] && ok "…and the RECORD names the bound (stale_briefs=1), so \`status\` reports it without the log" \
                                        || bad "record stale_briefs='$(record_field stale_briefs)', expected 1"
grep -q 'REGENERATION REQUIRED' "$ST/worker-supply.state" 2>/dev/null && ok "…and the record's reason says what has to happen (not a silent skip)" \
                                                                    || bad "the record does not name the regeneration"
# ⛔ AND THE SKIP IS NOT A PERMANENT WEDGE. `pr-doctor.py:4338-4340` rewrites the brief
# UNCONDITIONALLY on its next spawn for the PR, so the same PATH starts holding admitted bytes and the
# very next pass re-offers the order. Pinned here because a fix that skipped forever would turn a
# replay bug into a stranded order.
O="$O" SPAWNS="$SPAWNS" MAX_FIX=3 MAX_REVIEW=4 sup refill >/dev/null 2>&1
[ "$(spawns_for prd-71)" = "0" ] && ok "a second pass still offers nothing (the recorded brief is still the fossil)" \
                                 || bad "a second pass re-offered the refused brief ($(spawns_for prd-71) spawns)"
mkbrief "$TMP/briefs/prd-71.txt"            # the composer regenerates it — same PATH, admitted bytes
O="$O" SPAWNS="$SPAWNS" MAX_FIX=3 MAX_REVIEW=4 sup refill >"$TMP/j2.out" 2>&1; j2rc=$?
[ "$(spawns_for prd-71)" = "1" ] && ok "…and once the brief is REGENERATED the order IS re-offered (no refill was spent on the skips)" \
                                 || bad "a regenerated brief was NOT re-offered ($(spawns_for prd-71) spawns) — the fix would strand the order"
[ "$j2rc" = "0" ] && ok "…and that pass is clean (rc=0): supply recovered the order the moment its brief became admissible" \
                  || bad "the recovering pass exited $j2rc, expected 0"

# ── (l) A GATE THAT CANNOT ANSWER IS NOT "STALE" ────────────────────────────────━─────━──━──━──━──━
# ⛔ THE POLARITY THAT MUST NOT FLIP. `brief-gate.sh` exits 78 when the VALIDATOR is missing and 142
# when the bound fires; neither says anything about the brief. Converting those into "this order needs a
# new brief" would report an INSTALL fault as a content fault — the `$O`-skew lesson (#2708). The offer
# must still reach the DISPATCHER, which owns that refusal and reports it loudly (rc=78).
echo "-- (l) a gate that cannot answer falls through to the dispatcher, not to a false 'stale' verdict"
reset
mkdir -p "$TMP/bin"
printf '#!/usr/bin/env bash\nexit 78\n' > "$TMP/bin/brief-gate-78.sh"; chmod +x "$TMP/bin/brief-gate-78.sh"
mkwt "$TMP/wt/prd-81" fix/81
printf '## ORDER — no contract here either\n' > "$TMP/briefs/prd-81.txt"
mkorder prd-81 "$TMP/wt/prd-81" fix/81 "$TMP/briefs/prd-81.txt" 2400 "2026-10-27 01:00:00"
WORKER_SUPPLY_BRIEF_GATE="$TMP/bin/brief-gate-78.sh" O="$O" SPAWNS="$SPAWNS" MAX_FIX=3 MAX_REVIEW=4 \
  sup refill >"$TMP/l.out" 2>&1; lrc=$?
[ "$(spawns_for prd-81)" = "1" ] && ok "a gate that returns NO VERDICT (rc=78) does not suppress the offer — the dispatcher still receives it" \
                                 || bad "an unanswerable gate was read as 'stale brief' and swallowed the offer ($(spawns_for prd-81) spawns)"
grep -q 'could not be revalidated' "$TMP/l.out" 2>/dev/null && ok "…and the pass SAYS the revalidation could not be taken (rc named), instead of staying silent" \
                                                        || bad "the unanswerable gate was not reported: $(head -3 "$TMP/l.out")"
! grep -q 'REGENERATION REQUIRED' "$TMP/l.out" 2>/dev/null && ok "…and it does NOT claim the brief needs regenerating (the wrong fault, and the wrong remedy)" \
                                                   || bad "an install fault was reported as a stale brief"

# ── (d3) an accepted re-offer that ENDS AT ONCE holds no slot ───────────────────────────────━━
# ⛔ FOUND BY REVIEW (#2896 round 1, P2): the confirmation step treated "the worker already left a
# .rc" as ACCEPTANCE *and* as a LIVE slot, so a fast-failing worker (bad credentials, missing
# interpreter) consumed a budget slot that nobody occupies — the "bookkeeping is not the worker"
# class pr-doctor fixed on #2700 C5. With MAX_FIX=1 and two dead orders, the second was deferred
# while zero workers were alive.
echo "-- (d3) a re-offer that ends at once holds no slot"
reset
mkwt "$TMP/wt/prd-61" fix/61
mkwt "$TMP/wt/prd-62" fix/62
mkbrief "$TMP/briefs/prd-61.txt"
mkbrief "$TMP/briefs/prd-62.txt"
mkorder prd-61 "$TMP/wt/prd-61" fix/61 "$TMP/briefs/prd-61.txt" 60 "2026-10-27 01:00:00"
mkorder prd-62 "$TMP/wt/prd-62" fix/62 "$TMP/briefs/prd-62.txt" 60 "2026-10-27 01:00:00"
# a dispatcher whose worker dies instantly: it writes the spawn and a non-zero .rc at once.
# ⛔ IT MUST LIVE INSIDE `$O`: the stub derives its own state directory from `dirname "$0"`, so a copy
# in `$TMP` would write its `.started`/`.pid` into `$TMP/bg` while `--status` answers from `$TMP/bg`
# too — the supervisor's `$O/bg` would then see an order whose `--status` is `lost` and the fixture
# would test nothing (measured: that is exactly how the first version of this case passed vacuously).
DEAD_DISPATCH="$O/nonblocking-dispatch-dies.sh"
sed 's|^echo "\$!" > "\$D/\$NAME.pid"$|echo "$!" > "$D/$NAME.pid"; echo 1 > "$D/$NAME.rc"   # the worker dies at once|' \
  "$O/nonblocking-dispatch.sh" > "$DEAD_DISPATCH"
chmod +x "$DEAD_DISPATCH"
cmp -s "$O/nonblocking-dispatch.sh" "$DEAD_DISPATCH" \
  && bad "the dies-at-once dispatcher fixture did not apply — the case would test nothing" \
  || ok "the dies-at-once dispatcher fixture applied (it writes a non-zero .rc with the pid)"
WORKER_SUPPLY_DISPATCH="$DEAD_DISPATCH" O="$O" SPAWNS="$SPAWNS" MAX_FIX=1 MAX_REVIEW=0 \
  sup refill >"$TMP/d3.out" 2>&1; d3rc=$?
[ "$(spawn_count)" = "2" ] && ok "both dead orders were offered exactly once each pass (no phantom slot held the budget)" \
                            || bad "spawns=$(spawn_count) for two dead orders at fix=1 — a finished re-offer was counted as live"
grep -q 'ENDED at once' "$TMP/d3.out" 2>/dev/null && ok "…and the log says the re-offer ENDED at once instead of claiming a replacement" \
                                                 || bad "the log claimed a replacement for a worker that died at once: $(head -3 "$TMP/d3.out")"
[ "$(record_field live)" = "0" ] && ok "the record reads live=0 (no slot is held by a worker that has already exited)" \
                                 || bad "record live='$(record_field live)', expected 0"
[ "$d3rc" = "6" ] && ok "…and the pass is DEFERRED (rc=6), not clean: the orders are still dead" \
                  || bad "rc=$d3rc, expected 6 — a pass over workers that all died is not a clean pass"


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
mkbrief "$TMP/briefs/prd-41.txt"
mkbrief "$TMP/briefs/prd-42.txt"
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
mkbrief "$TMP/briefs/prd-51.txt"
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
  # ⛔ THE START LIMIT IS A [Unit] DIRECTIVE, AND ITS SECTION IS THE WHOLE POINT (#2896 review round
  # 1, P1). `StartLimitIntervalSec` in `[Service]` is IGNORED ("Unknown key name … ignoring.",
  # measured with `systemd-analyze verify`) while `StartLimitBurst` is not — so the pair looked
  # shipped, the window silently fell back to 10 s against RestartSec=15, and a configuration
  # failure restarted for ever with `is-active` reporting healthy. A whole-file grep passes that
  # broken unit, so this asserts the SECTION the directive lands in.
  section_of() { awk -v k="$1" '/^\[/{ s=$0 } index($0, k "=")==1 { print s; exit }' "$2"; }
  for _d in StartLimitIntervalSec StartLimitBurst; do
    _s="$(section_of "$_d" "$UNIT_TPL")"
    [ "$_s" = "[Unit]" ] && ok "the unit puts $_d in [Unit] (where systemd honours it), not in [Service]" \
                         || bad "$_d sits in '${_s:-<absent>}' — systemd ignores StartLimitIntervalSec outside [Unit], so the restart bound can never fire"
  done
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
  # ⛔ THE EXIT CODE MUST CARRY THE VERDICT (review #2896 round 3). `--status` printed `❌ enabled: no` /
  # `❌ active: no` and still exited 0 whenever the unit FILE existed, so any caller that reads the code
  # was told `healthy` about a unit that is not running — while this installer's own header promises
  # `0 installed/healthy`. Both directions are pinned, so the assertion cannot be satisfied by a
  # hard-coded 1.
  # ⛔ "HEALTHY" NOW INCLUDES A SUPERVISOR THAT IS ACTUALLY PASSING (agent-infra#4007). `ActiveState`
  # is true of a `--loop` that stopped passing — the measured supervisor was alive 16 days with a log
  # that had stopped 2 days earlier — so this verb folds in the supervisor's own heartbeat verdict.
  # Both directions are pinned here: a completed pass inside the bound is 0, and the SAME unit with a
  # record older than the bound is 1 with STALE named (a hard-coded verdict cannot satisfy both).
  reset
  O="$O" SPAWNS="$SPAWNS" MAX_FIX=3 MAX_REVIEW=4 sup refill >/dev/null 2>&1
  SC_DEAD="$TMP/systemctl-dead"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SC_DEAD"; chmod +x "$SC_DEAD"
  O="$O" SUDO=false ELDATO_PLATFORM=Linux UNIT_DIR="$TMP/units2" SYSTEMCTL="$SC_DEAD" \
    WORKER_SUPPLY_SCRIPT="$SUPPLY" bash "$INSTALLER" --status >"$TMP/status-dead.out" 2>&1; rcs_dead=$?
  [ "$rcs_dead" = "1" ] && ok "--status exits 1 for a unit the manager reports enabled=no / active=no (the CODE carries the verdict, not the file's existence)" \
    || bad "--status exited $rcs_dead for a disabled, inactive unit — a false PASS from a status verb"
  O="$O" SUDO=false ELDATO_PLATFORM=Linux UNIT_DIR="$TMP/units2" SYSTEMCTL="$SC" \
    WORKER_SUPPLY_SCRIPT="$SUPPLY" bash "$INSTALLER" --status >"$TMP/status-ok.out" 2>&1; rcs_ok=$?
  [ "$rcs_ok" = "0" ] && ok "…and 0 when it is installed, enabled, active AND its last pass is inside the bound (the assertion is not vacuous)" \
    || bad "--status exited $rcs_ok for a healthy unit: $(tail -2 "$TMP/status-ok.out")"
  # …and the measured failure: the unit is up, the record is old. `active: yes` must NOT outvote it.
  # …and ANY other non-zero supervisor verdict fails closed too (review P2 on #4017): a supervisor that
  # cannot run (126/127) or dies mid-`status` used to leave the verb at 0 — "healthy" over a supervisor
  # that answered nothing, the same false PASS the STALE arm removes, reached by a different code.
  printf '#!/usr/bin/env bash\nexit 7\n' > "$TMP/sup-broken.sh"; chmod +x "$TMP/sup-broken.sh"
  O="$O" SUDO=false ELDATO_PLATFORM=Linux UNIT_DIR="$TMP/units2" SYSTEMCTL="$SC" \
    WORKER_SUPPLY_SCRIPT="$TMP/sup-broken.sh" bash "$INSTALLER" --status >"$TMP/status-broken.out" 2>&1; rcs_broken=$?
  [ "$rcs_broken" = "1" ] && ok "…and an UNREADABLE supervisor verdict (status exited 7) fails closed (rc=1), not healthy" \
    || bad "--status exited $rcs_broken for a supervisor whose own status could not be read (a false PASS): $(tail -2 "$TMP/status-broken.out")"
  # ⛔ TWO HOMES, ONE STATE DIR (review P1, round 2 on #4017). The installer resolves its OWN `O` from
  # `$CELL_HOME`, so if that is not EXPORTED the child it judges reads `$HOME/orchestrator` instead —
  # and on a cell `cmux vm exec` hands over a HOME the image does not create, so the child found no
  # record, said STALE, and the folded code turned a HEALTHY supervisor into `REFUSING`. This arm runs
  # the installer WITHOUT `O` in its environment, which is the shape that was broken.
  # ⛔ HOME AND CELL_HOME MUST DIFFER, or the arm proves nothing: with HOME == CELL_HOME both resolutions
  # land on the SAME path and the missing export is invisible (measured while building this case — the
  # first version passed on the buggy installer). A cell's `cmux vm exec` hands over HOME=/home/ubuntu,
  # which is the shape below.
  CELLD="$TMP/cellhome"; OTHER_HOME="$TMP/home-other"; mkdir -p "$CELLD" "$OTHER_HOME"
  O="$CELLD/orchestrator" SPAWNS="$SPAWNS" MAX_FIX=3 MAX_REVIEW=4 sup refill >/dev/null 2>&1
  env -u O HOME="$OTHER_HOME" CELL_HOME="$CELLD" SUDO=false ELDATO_PLATFORM=Linux UNIT_DIR="$TMP/units2" \
    SYSTEMCTL="$SC" WORKER_SUPPLY_SCRIPT="$SUPPLY" bash "$INSTALLER" --status >"$TMP/status-twohome.out" 2>&1; rcs_2h=$?
  [ "$rcs_2h" = "0" ] && grep -q 'beat:  ok' "$TMP/status-twohome.out" \
    && ok "…and a healthy supervisor is NOT refused when the installer resolves its state dir from \$CELL_HOME and the caller exported no O (the child reads the same dir)" \
    || bad "--status exited $rcs_2h for a healthy supervisor under a two-home shell (O unexported): $(grep -m1 'beat:' "$TMP/status-twohome.out")"
  touch -t 202601010000 "$ST/worker-supply.state" "$ST/worker-supply.pass-start"
  O="$O" SUDO=false ELDATO_PLATFORM=Linux UNIT_DIR="$TMP/units2" SYSTEMCTL="$SC" \
    WORKER_SUPPLY_SCRIPT="$SUPPLY" bash "$INSTALLER" --status >"$TMP/status-stale.out" 2>&1; rcs_stale=$?
  [ "$rcs_stale" = "1" ] && grep -q 'STALE' "$TMP/status-stale.out" \
    && ok "…and 1 (STALE named) for an ACTIVE unit whose supervisor has written no completed pass inside the bound — the 16-day-alive/2-day-silent shape" \
    || bad "--status exited $rcs_stale for an active-but-stale supervisor (a stopped log must not read as healthy): $(tail -2 "$TMP/status-stale.out")"
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
mkbrief "$TMP/briefs/prd-11.txt"
  mkorder prd-11 "$TMP/wt/prd-11" fix/11 "$TMP/briefs/prd-11.txt" 2400 "2026-10-27 01:00:00"
  O="$O" SPAWNS="$SPAWNS" MAX_FIX=3 MAX_REVIEW=4 bash "$MUT" refill >/dev/null 2>&1
  n_mut="$(spawn_count)"; live_mut="$(py_live_for 11)"
  if [ "$n_mut" = "0" ] && [ "$live_mut" = "absent" ]; then
    ok "with the refill step neutered the (a) assertion REDDENS: spawns=$n_mut, doctor's reader=$live_mut — the test really tests the refill"
  else
    bad "the mutation did NOT redden (a): spawns=$n_mut reader=$live_mut — (a) would pass on a supervisor that refills nothing"
  fi
fi

# ── (j2) MUTATION: neuter the revalidation, and (j) must redden ───────────────────────────────
# ⛔ A NEW ASSERTION THAT CANNOT FAIL IS NOT A TEST (#3442). Case (j) is the one that pins the #3958
# invariant, so the mutant that REMOVES the invariant must redden it: with `brief_verdict` forced to 0
# the fossil reaches the dispatcher again — which is exactly the live defect
# (`72 re-offer(s) refused by the dispatcher`, pass after pass).
echo "-- (j2) mutation: no brief revalidation must redden (j)"
MUT3="$TMP/worker-supply.norevalidate.sh"
sed 's|^brief_verdict() { # <brief>$|brief_verdict() { return 0   # MUTATION: the brief is never revalidated|' \
  "$SUPPLY" > "$MUT3"
if cmp -s "$SUPPLY" "$MUT3"; then
  bad "the revalidation mutation did not apply (\`brief_verdict() {\` was not found) — a mutation that cannot mutate proves nothing"
else
  reset
  mkwt "$TMP/wt/prd-72" fix/72
  printf '## ORDER — re-run the checks on this head\n' > "$TMP/briefs/prd-72.txt"
  mkorder prd-72 "$TMP/wt/prd-72" fix/72 "$TMP/briefs/prd-72.txt" 2400 "2026-10-24 23:03:00"
  O="$O" SPAWNS="$SPAWNS" MAX_FIX=3 MAX_REVIEW=4 bash "$MUT3" refill >"$TMP/j2mut.out" 2>&1
  n_mut3="$(spawns_for prd-72)"
  if [ "$n_mut3" = "1" ]; then
    ok "with the revalidation neutered the (j) assertion REDDENS: the refused brief reached the dispatcher ($n_mut3 spawn) — (j) really grades the invariant"
  else
    bad "the mutation did NOT redden (j): spawns=$n_mut3 — (j) would pass on a supervisor that replays a refused brief for ever"
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
mkbrief "$TMP/briefs/prd-13.txt"
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

echo "-- (g2) the shipped DEFAULT_MAX_REVIEW agrees with the loop (agent-infra#3441)"
# ⛔ THE THIRD READER OF ONE NUMBER, AND THE ONLY ONE NOTHING PINNED (round 2 review, P2).
# `MAX_REVIEW` is now BOTH the reviewer-concurrency cap and the per-PR review-ROUND ceiling, and it has
# three fallbacks: `orch-loop.sh`/`install.sh` (pinned equal by `selftest.sh`) and TWO consumer copies —
# `pr-doctor.py` (pinned by `test_pr_doctor.py`, which extracts the loop default) and THIS file. Every
# case above supplies `MAX_REVIEW` explicitly through the plist/env fixture, so reverting this fallback
# to the old 4 kept the whole suite green while a box with no plist silently throttled the drain against
# a documented 10 — the exact divergence the file's own comment forbids. This is the same extraction
# `test_pr_doctor.py` uses, so the two pins cannot disagree about what "the loop default" is.
WS_DEFAULT="$(sed -n 's/^DEFAULT_MAX_REVIEW=\([0-9][0-9]*\)$/\1/p' "$HERE/worker-supply.sh" | head -1)"
# the loop's assignment carries a trailing `# keep in sync …` comment, so the extraction cannot be
# anchored at end-of-line; take the `:-` default out of the first MAX_REVIEW assignment.
LOOP_DEFAULT="$(grep -m1 '^MAX_REVIEW=' "$HERE/orch-loop.sh" | sed -n 's/.*:-\([0-9][0-9]*\)}.*/\1/p')"
if [ -n "$WS_DEFAULT" ] && [ "$WS_DEFAULT" = "$LOOP_DEFAULT" ]; then
  ok "-- DEFAULT_MAX_REVIEW=$WS_DEFAULT matches orch-loop.sh's shipped default (one number, three readers)"
else
  bad "-- DEFAULT_MAX_REVIEW='${WS_DEFAULT:-<not found>}' != orch-loop.sh's '${LOOP_DEFAULT:-<not found>}' — a box with no plist would budget a different number than the loop runs"
fi

# ── (k) A FOSSIL IS RETIRED, NOT DEFERRED FOR EVER (agent-infra#4007) ────────────────────────────
# ⛔ THE DEFECT THIS GRADES, MEASURED 2026-12-04: the order population only ever grows, so a box held
# orders for PRs that had long since merged (105 distinct order PR numbers, 105 not open, 0 orders for
# the 18 live PRs). Every pass walked them, the gate refused 72 of them, and the pass ended `deferred`
# for ever -- so `live=` could never become non-zero and the pool could not say anything at all. The
# assertions are BEHAVIOURAL: what left the population, what was NOT spawned, and what a fresh order
# does on the very next pass (the composer un-retires it by rewriting its record).
echo "-- (k) an un-actionable fossil is RETIRED; new work is still supplied"
reset
fossil_fixture() { # two dead orders whose refills are spent; only prd-41 is older than the TTL
  for _n in 41 42; do
    mkwt "$TMP/wt/prd-$_n" "fix/$_n"
    mkbrief "$TMP/briefs/prd-$_n.txt"
    mkorder "prd-$_n" "$TMP/wt/prd-$_n" "fix/$_n" "$TMP/briefs/prd-$_n.txt" 2400 "2026-10-27 01:00:00"
    printf '%s\t%s\t%s\t%s\n' 1 "prd-$_n" s1 accepted >> "$ST/worker-supply-offers.tsv"
    printf '%s\t%s\t%s\t%s\n' 2 "prd-$_n" s2 accepted >> "$ST/worker-supply-offers.tsv"
  done
  touch -t 202601010000 "$BG/prd-41.started"      # the FOSSIL: older than the 7-day TTL
  # ⛔ AND THE DOMINANT REAL CASE: the repair tree the order names had been REAPED (measured 2026-12-04:
  # 80 orders, 0 worktrees present). Every pass logged "the worktree recorded for the order is gone" and
  # could never act, so this order is a fossil too — and it is old enough to be retired on that reason.
  mkorder prd-44 "$TMP/wt/prd-44-reaped" fix/44 "$TMP/briefs/prd-41.txt" 2400 "2026-10-27 01:00:00"
  touch -t 202601010000 "$BG/prd-44.started"
}
fossil_fixture
O="$O" SPAWNS="$SPAWNS" MAX_FIX=3 MAX_REVIEW=4 sup refill >"$TMP/k1.out" 2>&1; rck=$?
[ "$(record_field retired)" = "2" ] && ok "both un-actionable FOSSILS are RETIRED (record retired=2: spent refills + a REAPED worktree) — they leave the pool instead of being deferred for ever" \
                                    || bad "record retired='$(record_field retired)', expected 2 (prd-41 spent refills, prd-44 reaped worktree)"
[ "$(awk -F'\t' '$2=="prd-44" { print $3 }' "$ST/worker-supply-retired.tsv" 2>/dev/null)" = "worktree-gone" ] \
  && ok "…and the reason is RECORDED (prd-44: worktree-gone — the measured 80-orders/0-worktrees shape)" \
  || bad "the reaped-worktree order's retirement reason is '$(awk -F'\t' '$2=="prd-44" { print $3 }' "$ST/worker-supply-retired.tsv" 2>/dev/null)', expected worktree-gone"
[ "$(spawns_for prd-41)" = "0" ] && ok "…and it was NOT re-offered (a retired order costs no spawn and no gate call)" \
                                  || bad "the retired order was re-offered: $(spawns_for prd-41) spawn(s)"
[ "$(awk -F'\t' '$2=="prd-41"' "$ST/worker-supply-retired.tsv" 2>/dev/null | wc -l | tr -d ' ')" = "1" ] \
  && ok "the retirement is a durable RECORD (one row in worker-supply-retired.tsv naming the order)" \
  || bad "the retired ledger does not hold exactly one row for prd-41"
[ "$(awk -F'\t' '$2=="prd-42"' "$ST/worker-supply-retired.tsv" 2>/dev/null | wc -l | tr -d ' ')" = "0" ] \
  && ok "…and the FRESH order of the same shape is NOT retired (the TTL is the discriminator, not the deadness)" \
  || bad "a fresh un-actionable order was retired — retirement would lose work the composer has not expired"
[ "$rck" = "6" ] && ok "rc=6 DEFERRED — the pass still refuses to call itself clean over the order it could not supply" \
                 || bad "rc=$rck, expected 6 (the fresh un-actionable order is still dead)"
# ⛔ THE COMPOSER UN-RETIRES WITHOUT A HUMAN: pr-doctor rewrites `.started` on every spawn, so a
# re-ordered PR produces a NEW record instance and the retirement row stops matching. Then NEW work
# appears — and that is the acceptance criterion this case exists for: `live` becomes non-zero.
mkorder prd-41 "$TMP/wt/prd-41" fix/41 "$TMP/briefs/prd-41.txt" 2400 "$(date '+%Y-%m-%d %H:%M:%S')"
mkwt "$TMP/wt/prd-44" fix/44          # the composer re-materialised the tree; its record is rewritten too
mkorder prd-44 "$TMP/wt/prd-44" fix/44 "$TMP/briefs/prd-41.txt" 2400 "$(date '+%Y-%m-%d %H:%M:%S')"
mkwt "$TMP/wt/prd-43" fix/43
mkbrief "$TMP/briefs/prd-43.txt"
mkorder prd-43 "$TMP/wt/prd-43" fix/43 "$TMP/briefs/prd-43.txt"
O="$O" SPAWNS="$SPAWNS" MAX_FIX=3 MAX_REVIEW=4 sup refill >"$TMP/k2.out" 2>&1
[ "$(record_field retired)" = "0" ] && ok "a RE-ORDERED record un-retires itself (retired=0) — retirement never shadows live work" \
                                    || bad "record retired='$(record_field retired)' after the composer re-ordered it, expected 0"
[ "$(spawns_for prd-43)" = "1" ] && ok "NEW work is supplied on the same pass (prd-43 spawned once)" \
                                  || bad "new work was not supplied: $(spawns_for prd-43) spawn(s)"
[ "$(record_field live)" = "2" ] && ok "…and the pool's live count becomes NON-ZERO with the new work (record live=2: the new order + the re-materialised one) — the reading that could not happen over a 100 %-fossil pool" \
                                  || bad "record live='$(record_field live)', expected 2"

# ── (k2) MUTATION: neuter retirement, and (k) must redden ──────────────────────────────────────
echo "-- (k2) mutation: no retirement must redden (k)"
MUT4="$TMP/worker-supply.noretire.sh"
sed 's|^retire_order() {|retire_order() { return 1   # MUTATION: retirement is gone|' "$SUPPLY" > "$MUT4"
if cmp -s "$SUPPLY" "$MUT4"; then
  bad "the retirement mutation did not apply (\`retire_order() {\` was not found) — a mutation that cannot mutate proves nothing"
else
  reset
  fossil_fixture
  O="$O" SPAWNS="$SPAWNS" MAX_FIX=3 MAX_REVIEW=4 bash "$MUT4" refill >"$TMP/k2mut.out" 2>&1; rck2=$?
  # ⛔ THE PREDICATE MUST NAME THE DISCRIMINATING VALUE (review P2 on #4017, reproduced). `!= "1"` was
  # TRUE on the unmutated script too (it prints retired=2), so this arm reported `ok` even for a mutation
  # that changed no behaviour at all — the `cmp -s` guard above proves the FILE changed, never that the
  # BEHAVIOUR did. The mutant retires NOTHING, so `= "0"` is the value only it can produce.
  if [ "$(record_field retired)" = "0" ] && [ "$rck2" = "6" ]; then
    ok "with retirement neutered the (k) assertion REDDENS: retired='$(record_field retired)', rc=$rck2 — (k) really grades retirement and not the fixture"
  else
    bad "the mutation did NOT redden (k): retired='$(record_field retired)', rc=$rck2 — the case would pass on a supervisor that defers a fossil for ever"
  fi
fi

# ── (k3) A RETIREMENT MAY NOT LAUNDER AN UNREADABLE POOL (review P1 on #4017) ────────────────────
# ⛔ REPRODUCED BY REVIEW: the `retired` arm sat above the `unreadable` arm, so a pool of unanswerable
# probes plus ONE retirable fossil printed `decision=retired` and exited 0 — "nothing supplied, two reads
# not taken" reported as a healthy pass, which is the #2896 round-3 defect one decision arm over.
echo "-- (k3) retirement does not launder an unreadable pool"
reset
cat > "$O/nonblocking-dispatch.sh" <<'EOS'
#!/usr/bin/env bash
if [ "${1:-}" = "--status" ]; then
  case "${2:-}" in prd-61) echo "garbage-answer-that-parses-to-nothing"; exit 0 ;; esac
  echo "${2:-} lost (no process)"; exit 0
fi
exit 1
EOS
chmod +x "$O/nonblocking-dispatch.sh"
mkwt "$TMP/wt/prd-61" fix/61
mkbrief "$TMP/briefs/prd-61.txt"
mkorder prd-61 "$TMP/wt/prd-61" fix/61 "$TMP/briefs/prd-61.txt" 2400 "2026-10-27 01:00:00"
# the retirable one: its recorded worktree is gone, and it is older than the TTL
mkorder prd-62 "$TMP/wt/prd-62-reaped" fix/62 "$TMP/briefs/prd-61.txt" 2400 "2026-10-27 01:00:00"
touch -t 202601010000 "$BG/prd-61.started" "$BG/prd-62.started"
O="$O" SPAWNS="$SPAWNS" MAX_FIX=3 MAX_REVIEW=4 sup refill >"$TMP/k3.out" 2>&1; rck3=$?
[ "$(record_field retired)" = "1" ] && ok "the retirable fossil was still retired and counted (retired=1)" \
                                   || bad "record retired='$(record_field retired)', expected 1"
[ "$(record_field decision)" != "retired" ] && [ "$rck3" = "2" ] \
  && ok "…and the pass does NOT call itself clean over the read it could not take (decision=$(record_field decision), rc=$rck3)" \
  || bad "an unreadable pool was laundered by a retirement: decision='$(record_field decision)', rc=$rck3 (expected unreadable + 2)"

# ── (m) THE HEARTBEAT: A STOPPED SUPERVISOR IS STALE, NOT QUIET (agent-infra#4007) ──────────────
# ⛔ THE MEASURED SHAPE: a supervisor alive 16 days whose log had stopped two days earlier. Every
# derived number read "quiet" and NOTHING reported the absence, so the silence was indistinguishable
# from health. `status` now grades the AGE of the last completed pass and exits 5 on STALE. Both
# directions are asserted (a bound that can never be exceeded is not a bound) and so is the knob.
echo "-- (m) status reports STALE when the last completed pass is older than the bound"
# one reader for the heartbeat line, so no assertion below has to nest quotes inside an interpolation
beat_line_of() { grep -m1 'beat:' "$1" 2>/dev/null || echo '<no beat line>'; }
reset
mkwt "$TMP/wt/prd-51" fix/51
mkbrief "$TMP/briefs/prd-51.txt"
mkorder prd-51 "$TMP/wt/prd-51" fix/51 "$TMP/briefs/prd-51.txt"
O="$O" MAX_FIX=3 MAX_REVIEW=4 sup status >"$TMP/m0.out" 2>&1; rcm0=$?
[ "$rcm0" = "5" ] && grep -q 'beat:  STALE' "$TMP/m0.out" \
  && ok "a box whose record was NEVER written reports STALE (rc=5), not silence — this is the 2-day-stale log" \
  || bad "an absent pass record reported rc=$rcm0 / '$(beat_line_of "$TMP/m0.out")', expected STALE + 5"
O="$O" SPAWNS="$SPAWNS" MAX_FIX=3 MAX_REVIEW=4 sup refill >/dev/null 2>&1
O="$O" MAX_FIX=3 MAX_REVIEW=4 sup status >"$TMP/m1.out" 2>&1; rcm1=$?
[ "$rcm1" = "0" ] && grep -q 'beat:  ok' "$TMP/m1.out" \
  && ok "…and a pass that just completed reads ok (rc=0) — the assertion is not vacuous" \
  || bad "a fresh record reported rc=$rcm1 / '$(beat_line_of "$TMP/m1.out")', expected ok + 0"
touch -t 202601010000 "$ST/worker-supply.state" "$ST/worker-supply.pass-start"
O="$O" MAX_FIX=3 MAX_REVIEW=4 sup status >"$TMP/m2.out" 2>&1; rcm2=$?
[ "$rcm2" = "5" ] && grep -q 'beat:  STALE' "$TMP/m2.out" \
  && ok "…and the SAME box with a record older than the bound reports STALE (rc=5): the process being up is not the question" \
  || bad "an aged record reported rc=$rcm2, expected STALE + 5"
O="$O" WORKER_SUPPLY_STALE_AFTER_S=999999999 MAX_FIX=3 MAX_REVIEW=4 sup status >"$TMP/m3.out" 2>&1; rcm3=$?
[ "$rcm3" = "0" ] && ok "the BOUND is what decides: the same record is inside a 999999999s bound (rc=0)" \
  || bad "the staleness knob is inert: rc=$rcm3 with a bound of 999999999s"
# ⛔ AND A LIVE, LONG PASS IS NOT A DEAD ONE (review P2, round 2 on #4017): the record only advances at
# pass END, so grading the record alone called a pass that is still walking 29–105 orders "DEAD or
# WEDGED". A real pass stamps its START, and the newest of the two decides — while a START that is
# itself older than the bound is a WEDGED pass and must still read STALE.
O="$O" SPAWNS="$SPAWNS" MAX_FIX=3 MAX_REVIEW=4 sup refill >/dev/null 2>&1   # fresh record + fresh start
touch -t 202601010000 "$ST/worker-supply.state"                            # the record is old …
O="$O" MAX_FIX=3 MAX_REVIEW=4 sup status >"$TMP/m4.out" 2>&1; rcm4=$?
[ "$rcm4" = "0" ] && grep -q 'IN PROGRESS' "$TMP/m4.out" \
  && ok "…a pass that is still RUNNING reads IN PROGRESS (rc=0), not STALE (its start marker is fresh)" \
  || bad "a live pass read rc=$rcm4 / '$(beat_line_of "$TMP/m4.out")', expected IN PROGRESS + 0"
touch -t 202601010000 "$ST/worker-supply.state" "$ST/worker-supply.pass-start"
O="$O" MAX_FIX=3 MAX_REVIEW=4 sup status >"$TMP/m5.out" 2>&1; rcm5=$?
[ "$rcm5" = "5" ] && grep -q 'WEDGED' "$TMP/m5.out" \
  && ok "…and a pass whose START is also past the bound reads STALE (WEDGED, rc=5) — the in-progress arm cannot be inert" \
  || bad "a wedged pass read rc=$rcm5 / '$(beat_line_of "$TMP/m5.out")', expected STALE/WEDGED + 5"

# ── (h) THE WALL-CLOCK BOUND ──────────────────────────────────────────────────────────────────────────
# ⛔ THIS IS A TEST, NOT A COMMENT. The first attempt at this fix died inside its own suite: 45 minutes
# and no result, so the fix never shipped. An unbounded test is a defect in the deliverable, so the
# duration is measured and asserted like any other property.
# ⛔ THE BOUND IS 180 s, RAISED FROM 60 s, AND THE REASON IS MEASURED RATHER THAN FELT (agent-infra#3958).
# Two facts, both read on this box 2026-11-11: (1) every re-offer now runs the SHIPPED brief gate, which
# is ~0.22 s per call — stubbing it (`WORKER_SUPPLY_BRIEF_GATE=/usr/bin/true`) measured 89 s against
# 98 s, i.e. the new work is ~9 s of the total; (2) the rest is the BOX, not the suite: `uptime` read
# **load 230 on 10 CPUs** in the same window, and this suite is mostly bounded `sleep`/poll loops, so it
# stretches with saturation. A bound tuned on a quiet box fails on a loaded one for a reason that says
# nothing about the deliverable. 180 s is still 15x under the 45-minute hang it exists to catch, and the
# LOAD is printed beside it so the next reader can tell saturation from a genuinely unbounded test
# instead of re-deriving which one this was.
echo "-- (h) the suite's own wall-clock"
SUITE_BOUND_S=180
SUITE_END=$(date +%s); ELAPSED=$(( SUITE_END - SUITE_START ))
LOAD_NOW="$(uptime 2>/dev/null | sed -n 's/.*load averages*: *//p' | cut -c1-40)"
echo "   suite wall-clock: ${ELAPSED}s (bound ${SUITE_BOUND_S}s, fake-worker slice ${WORKER_STUB_LIFETIME}s, load ${LOAD_NOW:-<unreadable>})"
[ "$ELAPSED" -le "$SUITE_BOUND_S" ] && ok "the suite finished in ${ELAPSED}s, inside its ${SUITE_BOUND_S}s bound (load ${LOAD_NOW:-?})" \
                                    || bad "the suite took ${ELAPSED}s (load ${LOAD_NOW:-?}) — an unbounded test is why the fix never shipped"

echo
echo "passed=$PASS failed=$FAIL (${ELAPSED}s)"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
