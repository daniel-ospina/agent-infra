#!/bin/bash
# scripts/heartbeat-loop.test.sh — #1933: the detached children's exit status must be REPORTED.
#
# THE DEFECT THIS SUITE PINS
# --------------------------
#   `heartbeat-loop.sh` launches `queue-dispatch.py` and `pr-doctor.py` DETACHED (deliberately:
#   a pass must not wait on a full dispatch cycle), and then reported their health with:
#
#       rc=0                                                        # ← a literal, on the next line
#       if [ "$rc" -ne 0 ]; then printf … QUEUE-DISPATCH FAILED …; fi
#
#   `rc` was assigned the literal 0 immediately above the only branch that could report a
#   dispatch failure, so that branch was **unreachable by construction**. The log printed
#   `PR-DOCTOR launched detached (drives open PRs toward merged)` on every pass — including a
#   pass where the child refused at import, crashed, or exited 2 because the PR list could not
#   be read. This became load-bearing with #1872, which makes `pr-doctor` REFUSE (exit 2) on an
#   unreadable queue: a refusal the launcher cannot see is, operationally, still a silent zero.
#
# WHY A GREP WOULD NOT HAVE BEEN A TEST
# ------------------------------------
#   `tests/beat-pair/run.sh` §8 already greps this file, and a grep is exactly what cannot tell
#   a reachable branch from an unreachable one: the dead code CONTAINED the string
#   `QUEUE-DISPATCH FAILED`. So the assertions below RUN THE REAL LOOP — one real pass, twice
#   where the status has to cross a pass boundary — with every child of the pass stubbed in a
#   temp layout, and assert on the log the loop actually writes.
#
#   NON-VACUITY IS ASSERTED, not assumed. Each case first proves the pass RAN (the launch line
#   is present in that pass's log). Without that floor this whole suite would pass on a box where
#   the loop exits before the first step — which is not hypothetical: an unconditional
#   `cd /Users/danielospina` made the loop exit 0 with an EMPTY log on any other host (#1933),
#   so a suite that only asserted "no failure line" would have been green there and tested
#   nothing.
#
# WHAT IS PINNED
#   0. The removed defect: the shipped file no longer assigns a literal `rc=0` before testing it.
#   1. CAPTURE — a child that exits 2 writes 2 into its own sidecar FROM INSIDE the subshell
#      (the only place `$?` is still the child's). Proven by reading the sidecar the real child
#      wrote, not by reading the source.
#   2. REPORT — the NEXT pass turns that sidecar into a distinct `PR-DOCTOR REFUSED rc=2` line.
#      This is the assertion the pre-fix file fails: it never reads the sidecar at all.
#   3. ONE-SHOT — a reported failure is CONSUMED. A stale failure cannot be re-reported on every
#      pass from then on (the reader removes the sidecar; the writer re-creates it only if the
#      child runs again and fails again).
#   4. DISCRIMINATION — a clean child (rc 0) writes NO failure line. A branch reported
#      unconditionally would satisfy (2) and be just as useless.
#   5. THE DISPATCHER — `queue-dispatch.py` gets the same treatment (`QUEUE-DISPATCH FAILED
#      rc=N`), because the deleted dead branch was ITS report.
#   6. AN UNREADABLE SIDECAR IS NAMED, never read as success — and never claimed as a failure
#      either (it is unverifiable). `[ "garbage" -ne 0 ]` would error, and an error read as
#      "not a failure" is the same defect in a different coat.
#
# Run: bash scripts/heartbeat-loop.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LOOP="$ROOT/scripts/heartbeat-loop.sh"

checks=0; failures=0
pass(){ checks=$((checks + 1)); echo "  ok   $1"; }
fail(){ checks=$((checks + 1)); failures=$((failures + 1)); echo "  FAIL $1"; }
# A `case` glob, not `printf … | grep -q`: `scripts/` is scanned by
# scripts/check-no-sigpipe-grep.sh (#841) and a fired SIGPIPE race would flip a WITHHOLDING
# assertion to PASS — the direction that hides a defect.
has(){ case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
# grep as a PRODUCER is proven-writer (it reads everything before matching), so this is not the
# #841 idiom; it is the one place a line count is wanted rather than a yes/no.
num_of(){ local n; n="$(grep -c -- "$2" "$1" 2>/dev/null)"; printf '%s' "${n:-0}"; }

if [ ! -f "$LOOP" ]; then
  echo "❌ $LOOP not found — nothing to pin"
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── THE FIXTURE ───────────────────────────────────────────────────────────────────────────────
# A complete detached-run layout under $TMP/<case>: every child of a pass is a stub, so a pass
# runs end to end in ~a second and touches nothing real. `HEARTBEAT_PI_AGENT_DIR` places STATE
# and SCRIPTS in it; `HEARTBEAT_PASS_ONCE` makes one invocation carry exactly ONE pass (the seam
# is after the pass, so it cannot skip a step inside it).
#
# mkfix <case> <pr-doctor-exit> <queue-dispatch-exit>
mkfix() {
  local d="$TMP/$1" pdr="$2" qdr="$3"
  mkdir -p "$d/home" "$d/agent/state/queues" "$d/agent/scripts/lib"
  # The tick (step 1), its fallback scan, and the classifier/nudger steps: all no-ops. `|| true`
  # is not needed — each stub exits 0 by construction. The TICK deliberately writes a line to
  # stderr, because that is the input which proves the drained tail is the CHILD's own and not
  # "whoever wrote to the shared heartbeat-stderr.log last" (see case 2).
  printf '#!/bin/bash\nprintf "TICK-NOISE-not-a-pr-doctor-error\\n" >&2\nexit 0\n' \
    > "$d/agent/scripts/orchestrator-heartbeat.sh"
  printf '#!/bin/bash\nexit 0\n' > "$d/agent/scripts/lane-scan-fallback.sh"
  local py
  for py in lane-actions turn-classify turn-end lane-watchdog refresh-queues; do
    printf 'import sys\nsys.exit(0)\n' > "$d/agent/scripts/$py.py"
  done
  # The two DETACHED children under test. Their exit codes are the input of every case, and each
  # writes a marker to its OWN stderr so case 2 can prove the report's tail is attributed to it.
  printf 'import sys\nsys.stderr.write("PRDOCTOR-OWN-STDERR-MARKER\\n")\nsys.exit(%s)\n' "$pdr" \
    > "$d/agent/scripts/pr-doctor.py"
  printf 'import sys\nsys.stderr.write("DISPATCH-OWN-STDERR-MARKER\\n")\nsys.exit(%s)\n' "$qdr" \
    > "$d/agent/scripts/queue-dispatch.py"
  printf 'import sys\nsys.exit(0)\n' > "$d/agent/state/queues/refresh-queues.py"
  # A FRESH lane snapshot (so the classifier path runs instead of the detached fallback scan)
  # and a FRESH objective cache (so the pass does not spend its objective refresh).
  printf '{"lanes":[]}\n' > "$d/agent/state/lane-status.last.json"
  printf 'main=GREEN\n' > "$d/agent/state/objective.last"
  echo "$d"
}

# run_pass <fixture> — ONE real pass of the real loop, bounded. The bound is a runaway guard, not
# a timeout for a slow child: the stubs are instantaneous, so anything near the bound means the
# one-pass exit is gone and the suite must fail rather than hang CI forever.
run_pass() {
  local d="$1"
  ( HOME="$d/home" HEARTBEAT_PI_AGENT_DIR="$d/agent" LOOP_DETACHED=1 HEARTBEAT_PASS_ONCE=1 \
      /bin/bash "$LOOP" >/dev/null 2>&1 ) &
  local pid=$! wd
  # ⛔ KILL THE GROUP, NOT THE SUBSHELL. `kill "$wd"` reaped the watchdog subshell and orphaned the
  # `sleep 90` it had forked (MEASURED: 9 survivors per suite run, ppid 1, 90 s each) — litter that
  # would ride along on every PR runner. `set -m` makes the watchdog its own process group, so the
  # group signal takes the sleep with it.
  set -m
  ( sleep 90; kill -TERM "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  wd=$!
  set +m
  wait "$pid" 2>/dev/null; local rc=$?
  kill -TERM -- "-$wd" 2>/dev/null || kill -TERM "$wd" 2>/dev/null
  wait "$wd" 2>/dev/null
  return "$rc"
}

logof(){ printf '%s' "$1/agent/state/orchestrator-heartbeat.log"; }

# wait_rc <sidecar> <expected> — the detached child writes asynchronously; give it a real window
# instead of sleeping a fixed amount (a fixed sleep is a flake generator on a loaded runner).
wait_rc() {
  local f="$1" want="$2" i=0 got=""
  while [ "$i" -lt 150 ]; do
    if [ -f "$f" ]; then got="$(cat "$f" 2>/dev/null)"; [ "$got" = "$want" ] && return 0; fi
    i=$((i + 1)); sleep 0.1
  done
  return 1
}

echo "0. the unreachable-branch shape is gone (the defect itself)"
# `rc=0` as a full assignment statement is what made the branch dead. Scoped to the loop file,
# and matched as a standalone statement so a legitimate `local rc=$?` / `rc=$?` is untouched.
dead="$(sed 's/#.*//' "$LOOP" | grep -cE '^[[:space:]]*(local[[:space:]]+)?rc=0[[:space:]]*$' || true)"
if [ "${dead:-0}" -eq 0 ]; then
  pass "no literal 'rc=0' is assigned as a statement anywhere in heartbeat-loop.sh"
else
  fail "heartbeat-loop.sh assigns a literal rc=0 ($dead site(s)) — a status nobody captured, tested next line"
fi

echo ""
echo "1-4. a child that REFUSES is captured, reported, consumed, and discriminated"
FIX="$(mkfix refused 2 0)"; LOG="$(logof "$FIX")"

run_pass "$FIX"
if has "$(cat "$LOG" 2>/dev/null)" "PR-DOCTOR launched detached"; then
  pass "pass 1 RAN (the launch line is in the log — the non-vacuity floor)"
else
  fail "pass 1 wrote no launch line — the loop exited before the dispatch step; every assertion below is void"
fi
if has "$(cat "$LOG" 2>/dev/null)" "PR-DOCTOR REFUSED"; then
  fail "pass 1 reported a refusal before any child had run — the launch line cannot be a failure report"
else
  pass "pass 1 (which launched the child) reports NO refusal — it does not invent a status"
fi

SIDE="$FIX/agent/state/pr-doctor.rc"
if wait_rc "$SIDE" 2; then
  pass "1. the detached child wrote its OWN rc=2 into the sidecar (captured inside the subshell)"
else
  fail "no sidecar with rc=2 appeared at $SIDE — the child's exit status is still uncaptured"
fi

run_pass "$FIX"
LOG2="$(cat "$LOG" 2>/dev/null)"
if has "$LOG2" "PR-DOCTOR REFUSED rc=2"; then
  pass "2. the NEXT pass reports it: 'PR-DOCTOR REFUSED rc=2' (the pre-fix file never reads the sidecar)"
else
  fail "no 'PR-DOCTOR REFUSED rc=2' line after the failing child — the failure is still a silent zero"
fi
if has "$LOG2" "PR-DOCTOR REFUSED rc=2 :: PRDOCTOR-OWN-STDERR-MARKER"; then
  pass "   …and the tail is THE CHILD'S OWN stderr (its marker), so the diagnosis names the right component"
else
  fail "'PR-DOCTOR REFUSED' was logged without the child's own stderr tail (got: $(grep -m1 'PR-DOCTOR REFUSED' "$LOG" 2>/dev/null))"
fi
if has "$LOG2" "TICK-NOISE-not-a-pr-doctor-error"; then
  fail "the report carried the SHARED stderr log's last line (the tick's) — the tail names the wrong component"
else
  pass "   …and it does NOT carry another step's stderr (the shared heartbeat-stderr.log is not the source)"
fi

echo ""
echo "3. one-shot: a reported failure is CONSUMED, not re-reported forever"
# ⛔ THE CHILD IS DISARMED HERE ON PURPOSE. With the child running, it REWRITES its own sidecar
# after the drain, so a mutant that drops the `rm -f` (and therefore re-reports a stale failure
# every pass) still reads as green — measured: the "no rm" mutant passed this suite before this
# line existed. `PR-DOCTOR-OFF` stops the launch without stopping the DRAIN, so two passes on a
# seeded failure can only report once if the drain really consumes it. It also pins the drain's
# PLACEMENT: a drain moved inside the disarm guard reports NOTHING and fails the first assertion.
FIX3="$(mkfix consumed 0 0)"; LOG3="$(logof "$FIX3")"
printf '2\n' > "$FIX3/agent/state/pr-doctor.rc"
: > "$FIX3/agent/state/PR-DOCTOR-OFF"
run_pass "$FIX3"
n1="$(num_of "$LOG3" 'PR-DOCTOR REFUSED')"
run_pass "$FIX3"
n2="$(num_of "$LOG3" 'PR-DOCTOR REFUSED')"
if [ "${n1:-0}" -eq 1 ]; then
  pass "a seeded failure is reported exactly once on the pass that reads it"
else
  fail "a seeded failure produced ${n1:-0} report(s) on the first pass (expected 1)"
fi
if [ "${n2:-0}" -eq "${n1:-0}" ]; then
  pass "...and NOT again on the next pass — the sidecar is removed once read"
else
  fail "the same failure was reported again ($n1 -> $n2): a stale status is being re-published every pass"
fi
if [ ! -f "$FIX3/agent/state/pr-doctor.rc" ]; then
  pass "...and the consumed sidecar is gone (the disarm file prevented a fresh write)"
else
  fail "the sidecar still holds '$(cat "$FIX3/agent/state/pr-doctor.rc" 2>/dev/null)' — a stale failure survives and will be reported again"
fi

echo ""
echo "4. discrimination: a CLEAN child writes no failure line"
# Reuse the consumed fixture: both children exit 0 there and the log now has 2 passes in it.
if [ "$(num_of "$LOG3" 'QUEUE-DISPATCH FAILED')" -eq 0 ]; then
  pass "a clean dispatcher (rc 0) produces no 'QUEUE-DISPATCH FAILED' line"
else
  fail "a clean child reported a failure — the branch is not discriminating"
fi
FIX4="$(mkfix clean 0 0)"; LOG4="$(logof "$FIX4")"
run_pass "$FIX4"; sleep 0.5; run_pass "$FIX4"
if [ "$(num_of "$LOG4" 'PR-DOCTOR REFUSED')" -eq 0 ] && has "$(cat "$LOG4" 2>/dev/null)" "PR-DOCTOR launched"; then
  pass "two passes with a clean pr-doctor: the pass RAN and logged no refusal"
else
  fail "a clean pr-doctor produced a refusal (or the pass did not run) — see $LOG4"
fi

echo ""
echo "5. the dispatcher gets the same treatment (its report was the dead branch)"
FIX5="$(mkfix dispatch 0 2)"; LOG5="$(logof "$FIX5")"
run_pass "$FIX5"
if wait_rc "$FIX5/agent/state/queue-dispatch.rc" 2; then
  pass "the detached dispatcher's rc=2 is captured in its own sidecar"
else
  fail "no queue-dispatch sidecar with rc=2 — its exit status is still uncaptured"
fi
run_pass "$FIX5"
if has "$(cat "$LOG5" 2>/dev/null)" "QUEUE-DISPATCH FAILED rc=2 :: DISPATCH-OWN-STDERR-MARKER"; then
  pass "the next pass reports 'QUEUE-DISPATCH FAILED rc=2' with the dispatcher's OWN stderr (the line that could never print)"
else
  fail "no 'QUEUE-DISPATCH FAILED rc=2' line — the deleted branch was not replaced by a working one"
fi

echo ""
echo "6. an unreadable sidecar is NAMED, never read as success or as a failure"
FIX6="$(mkfix garbage 0 0)"; LOG6="$(logof "$FIX6")"
printf 'not-a-number\n' > "$FIX6/agent/state/pr-doctor.rc"
run_pass "$FIX6"
LOG6TXT="$(cat "$LOG6" 2>/dev/null)"
if has "$LOG6TXT" "PR-DOCTOR REFUSED UNREADABLE"; then
  pass "a non-numeric sidecar is reported as UNREADABLE (it cannot say 'all fine')"
else
  fail "a non-numeric sidecar produced no UNREADABLE line — it reads as silence, which reads as a pass"
fi
if has "$LOG6TXT" "PR-DOCTOR REFUSED rc="; then
  fail "a non-numeric sidecar was reported as a numeric failure — the line would assert an rc nobody read"
else
  pass "...and it is NOT claimed as a numeric failure (unverifiable is neither pass nor fail)"
fi

echo ""
echo "7. a sidecar written WITHOUT a trailing newline is still a value, not 'UNREADABLE'"
# `read` returns 1 at EOF-without-newline while STILL setting the variable, so the natural
# `read -r rc < file || rc=""` idiom throws away exactly the value it just read — measured: a
# sidecar holding `143` with no newline drained as `UNREADABLE (held "")`. The writer appends a
# newline, so this needs a torn write; the whole point of naming an unreadable sidecar is that a
# torn write must never be able to erase the failure it was recording.
FIX7="$(mkfix nonewline 0 0)"; LOG7="$(logof "$FIX7")"
printf '143' > "$FIX7/agent/state/pr-doctor.rc"
: > "$FIX7/agent/state/PR-DOCTOR-OFF"
run_pass "$FIX7"
if has "$(cat "$LOG7" 2>/dev/null)" "PR-DOCTOR REFUSED rc=143"; then
  pass "a newline-less '143' is reported as rc=143 (the value read is kept)"
else
  fail "a newline-less sidecar drained as $(grep -m1 'PR-DOCTOR REFUSED' "$LOG7" 2>/dev/null | cut -c1-120) — a truncated write erased a real failure"
fi

echo ""
if [ "$failures" -eq 0 ]; then
  echo "✅ heartbeat-loop suite passed (${checks} assertions)"
  exit 0
fi
echo "❌ heartbeat-loop suite: $failures of $checks assertion(s) failed"
exit 1
