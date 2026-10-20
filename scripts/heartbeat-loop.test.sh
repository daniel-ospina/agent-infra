#!/bin/bash
# scripts/heartbeat-loop.test.sh — #1933: the detached children's exit status must be REPORTED.
#
# THE DEFECT THIS SUITE PINS
# --------------------------
#   `heartbeat-loop.sh` launches `queue-dispatch.py` and `pr-doctor.py` DETACHED (deliberately:
#   a pass must not wait on a full dispatch cycle), and then reported their health with a LITERAL
#   status: on the base of this worktree the file carries an `rc=0` assignment with no reader at
#   all, and the `QUEUE-DISPATCH FAILED` report it once gated survives only in comments — #2056
#   (`838228de`) deleted the branch and left the vestigial assignment behind, so on the base
#   **nothing replaced the report**: no pass could log a dispatch failure, whatever the child did.
#   The log printed `PR-DOCTOR launched detached (drives open PRs toward merged)` on every pass —
#   including a pass where the child refused at import, crashed, or exited 2 because the PR list
#   could not be read. This became load-bearing with #1872, which makes `pr-doctor` REFUSE
#   (exit 2) on an unreadable queue: a refusal the launcher cannot see is, operationally, still a
#   silent zero.
#
#   (The earlier form of this header quoted `if [ "$rc" -ne 0 ]; then … QUEUE-DISPATCH FAILED …`
#   as the shipped code. That is true of this branch's fork point, not of the merge base: a reader
#   checking the base will find no such branch — #2056 deleted it and left a bare `rc=0` with no
#   reader, so the REPORT was gone, not merely unreachable. Case 0 below pins the shape either way —
#   it asserts no standalone literal `rc=0` is assigned AND THEN the cases assert a real report
#   exists, which is the stronger claim that the base fails. The loop's own comment at the deletion
#   site carries the same history; an earlier version dated the deletion to this branch's fork
#   point and contradicted this header — review P2.)
#
#   SCOPE OF THE SILENCE, ON THE BASE (review P3-5, verified against `git show origin/main:`): the
#   dead branch was **queue-dispatch's** report, and `QUEUE-DISPATCH FAILED` appears on the base
#   only in COMMENTS — no pass could log it, whatever the child did. `pr-doctor` was not entirely
#   silent there: #2056 also added a reader for `$STATE/pr-doctor.status.json` (vocabulary
#   `PR-DOCTOR RED rc=N`), which reports the child's own recorded verdict a tick later but never
#   the rc the launcher failed to capture, and says nothing at all when the record is missing. The
#   sidecar drain below is therefore the dispatcher's only report and the doctor's rc-level one.
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
#   9. THE WORD IS CHOSEN BY THE RC (review P1) — `REFUSED` is #1872's exit-2 vocabulary, so a
#      crash (rc=4) reports as `PR-DOCTOR RED rc=4`, never as a refusal.
#  10. THE RETAINED TAIL IS THE ONE SNAPSHOTTED WHEN THE VALUE WAS RETAINED, not whatever a LATER
#      run wrote into `<child>.stderr` (review P2).
#  11. A VALUE ON DISK WHEN A LAUNCH TAKES THE SIDECAR IS PRESERVED, not overwritten (review P2).
#  12. `HEARTBEAT_PASS_ONCE=0` DOES NOT STOP THE LOOP — only `=1` is one-pass, and it says so.
#      And stopping it leaves NO ORPHAN: the loop is signalled as a PROCESS GROUP, so the
#      `sleep "$SLP"` it parks in (~540 s) does not outlive the test (review advisory, #1954).
#  13. `<child>.stderr` IS TRUNCATED AT LAUNCH, so run N's report cannot carry run N-1's line.
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
# The seam must NAME itself: a one-pass run once logged `sleeping 5s` and then exited, so a stuck
# `HEARTBEAT_PASS_ONCE` read as a healthy beat that simply stopped (case 12).
if has "$(cat "$LOG" 2>/dev/null)" "ONE-PASS MODE"; then
  pass "   ...and the one-pass seam SAYS it is on (it is visible in the log, not inferred from silence)"
else
  fail "HEARTBEAT_PASS_ONCE=1 exited the loop without logging that it was in one-pass mode"
fi

SIDE="$FIX/agent/state/pr-doctor.rc"
if wait_rc "$SIDE" 2; then
  pass "1. the detached child wrote its OWN rc=2 into the sidecar (captured inside the subshell)"
else
  fail "no sidecar with rc=2 appeared at $SIDE — the child's exit status is still uncaptured"
fi

launches_before="$(num_of "$LOG" 'PR-DOCTOR launched detached')"
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
# ⛔ THE DRAIN'S PLACEMENT IS LOAD-BEARING AND IS NOW PINNED, not just described in the loop's own
# comment ("the line must precede this pass's launch line, so the log reads 'last run failed, this
# run launched'"). MEASURED as a gap by review: moving both `report_detached_rc` calls to the END
# of the pass — after this pass's launches — left the previous 17 assertions all green. Pass 2 here
# both DRAINS the refusal and LAUNCHES a child, so the two lines exist in one pass and their order
# is observable: the LAST report must sit before the LAST launch line.
# ⛔ AND THE PRECONDITION IS ASSERTED FIRST (review P3-2). The awk takes the LAST of each line over
# the CUMULATIVE log, so if the second pass launches nothing it compares this pass's report against
# pass 1's launch and reports "after" with a message naming placement — a red that names the wrong
# cause. The launch count going 1 -> 2 is the price of asking the question at all.
# order_pinned <log> <report-pattern> <launch-pattern> <launches-before> <launches-after>
order_pinned() {
  local log="$1" rep="$2" launch="$3" before="$4" after="$5" order
  if [ "$after" -ne $((before + 1)) ]; then
    fail "$6: PRECONDITION — the pass launched $(($after - before)) child(ren), not 1, so the ordering is not observable (see $log)"
    return 0
  fi
  order="$(awk -v rep="$rep" -v launch="$launch" '
      $0 ~ rep    { r = NR }
      $0 ~ launch { l = NR }
      END { print ((r && l && r < l) ? "before" : "after") }' "$log" 2>/dev/null)"
  if [ "$order" = "before" ]; then
    pass "$6: the drain runs BEFORE this pass's launch (the log reads 'last run failed, this run launched')"
  else
    fail "$6: the report line does not precede the launch line of the SAME pass ($order) — a drain below the launch reports last pass's failure as this pass's"
  fi
}
order_pinned "$LOG" 'PR-DOCTOR REFUSED' 'PR-DOCTOR launched detached' \
  "$launches_before" "$(num_of "$LOG" 'PR-DOCTOR launched detached')" "the PR-DOCTOR half"

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
q_launches_before="$(num_of "$LOG5" 'DISPATCH-STEP launched detached')"
run_pass "$FIX5"
# ⛔ THE OTHER HALF OF "ahead of BOTH launches" (review P3-3). The doctor half alone leaves the
# dispatcher's placement unpinned: with both drains moved BETWEEN the two launches the doctor
# assertion stays green, and case 5's tail match catches it only incidentally (the launch truncated
# the child's stderr). Same order helper, applied to the dispatcher's own lines.
order_pinned "$LOG5" 'QUEUE-DISPATCH FAILED' 'DISPATCH-STEP launched detached' \
  "$q_launches_before" "$(num_of "$LOG5" 'DISPATCH-STEP launched detached')" "the dispatcher half"
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
if has "$LOG6TXT" "PR-DOCTOR RED UNREADABLE"; then
  pass "a non-numeric sidecar is reported as UNREADABLE (it cannot say 'all fine')"
else
  fail "a non-numeric sidecar produced no UNREADABLE line — it reads as silence, which reads as a pass"
fi
if has "$LOG6TXT" "PR-DOCTOR RED rc="; then
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
# A KILL is not a refusal either: the word follows the rc (case 9 pins the crash half of the same
# rule), so `143` reports as RED.
if has "$(cat "$LOG7" 2>/dev/null)" "PR-DOCTOR RED rc=143"; then
  pass "a newline-less '143' is reported as rc=143 (the value read is kept)"
else
  fail "a newline-less sidecar drained as $(grep -m1 'PR-DOCTOR' "$LOG7" 2>/dev/null | cut -c1-120) — a truncated write erased a real failure"
fi

echo ""
echo "8. an UNWRITABLE log does not consume the only copy of the report"
# ⛔ THE UNLINK MUST BE GATED ON THE WRITE, and "unlink last" alone is not a gate (review P3,
# MEASURED: with `$LOG` unwritable the old code printed nothing AND deleted the sidecar, so a log
# outage in the wake of a failing child destroyed the failure permanently). A CONTROL fixture with
# an identical seed and a writable log proves the drain is reached at all, so the treatment case
# cannot pass by never running the drain.
FIX8A="$(mkfix logwritable 0 0)"; LOG8A="$(logof "$FIX8A")"
printf '2\n' > "$FIX8A/agent/state/pr-doctor.rc"
: > "$FIX8A/agent/state/PR-DOCTOR-OFF"
run_pass "$FIX8A"
if has "$(cat "$LOG8A" 2>/dev/null)" "PR-DOCTOR REFUSED rc=2" && [ ! -f "$FIX8A/agent/state/pr-doctor.rc" ]; then
  pass "CONTROL: a writable log gets the report and the sidecar is consumed"
else
  fail "CONTROL failed — the drain was not reached in this fixture shape, so case 8 proves nothing"
fi
FIX8B="$(mkfix logunwritable 0 0)"; LOG8B="$(logof "$FIX8B")"
printf '2\n' > "$FIX8B/agent/state/pr-doctor.rc"
: > "$FIX8B/agent/state/PR-DOCTOR-OFF"
# Every append to this path now fails (EISDIR): the same outage a full disk produces.
rm -f "$LOG8B"; mkdir -p "$LOG8B"
run_pass "$FIX8B"
if [ -f "$FIX8B/agent/state/pr-doctor.rc.pending" ] && [ "$(cat "$FIX8B/agent/state/pr-doctor.rc.pending" 2>/dev/null)" = "2" ]; then
  pass "an UNWRITABLE log keeps the rc (as a PENDING carrier), so the failure is not lost"
else
  fail "the value was deleted although no report could be written — the only copy of rc=2 is gone"
fi
# ⛔ AND "RETAINED" MUST SURVIVE THE NEXT LAUNCH (review P3-1, MEASURED). Gating the unlink is not
# enough: the child writes the SAME path with write-then-rename, so a value left in `<child>.rc` was
# overwritten by the next run before any pass could report it (seeded 2 -> observed 0). The pending
# carrier is a path no launch writes; the child is NOT disarmed here, so it really does launch.
# ⛔ THE FRESH CHILD MUST EXIT A **DIFFERENT** rc THAN THE SEEDED ONE (review P1, MEASURED). With a
# child that also exits 2, `.rc` is rewritten with the value the pending carrier already holds, so
# EVERY assertion below passed with the carrier-precedence line deleted — a retry path that never
# retries graded green (measured: precedence mutant -> exit 0, 0 failures). The child is CLEAN now,
# which makes the precedence line the only thing that can produce the rc=2 report.
FIX8C="$(mkfix logunwritablelaunch 0 0)"; LOG8C="$(logof "$FIX8C")"
printf '2\n' > "$FIX8C/agent/state/pr-doctor.rc"
rm -f "$LOG8C"; mkdir -p "$LOG8C"
run_pass "$FIX8C"
wait_rc "$FIX8C/agent/state/pr-doctor.rc" 0      # the freshly launched child DOES overwrite `.rc`
if [ "$(cat "$FIX8C/agent/state/pr-doctor.rc.pending" 2>/dev/null)" = "2" ]; then
  pass "the next LAUNCH cannot overwrite a pending report (the carrier is a path no launch writes)"
else
  fail "the launched child overwrote the retained report (pending='$(cat "$FIX8C/agent/state/pr-doctor.rc.pending" 2>/dev/null)')"
fi
# …and once the log is writable again the retained failure is reported, not merely kept.
rm -rf "$LOG8C"
run_pass "$FIX8C"
if has "$(cat "$LOG8C" 2>/dev/null)" "PR-DOCTOR REFUSED rc=2"; then
  pass "once the log recovers, the retained failure IS reported (a later pass, not never)"
else
  fail "the log recovered and the retained rc=2 was still never reported — retention without a retry path is a quieter loss"
fi
# ⛔ THE UNREADABLE ARM'S GATE IS NOW PINNED TOO (review P3-4). Case 8B seeds a NUMERIC value, so a
# mutant that drops the gate ONLY in the `''|*[!0-9]*` arm stayed fully green. That arm is where
# losing the sidecar is least recoverable: the report IS the garbage, so deleting the file destroys
# the only record of what it held.
FIX8D="$(mkfix logunwritablegarbage 0 0)"; LOG8D="$(logof "$FIX8D")"
printf 'not-a-number\n' > "$FIX8D/agent/state/pr-doctor.rc"
: > "$FIX8D/agent/state/PR-DOCTOR-OFF"
rm -f "$LOG8D"; mkdir -p "$LOG8D"
run_pass "$FIX8D"
if [ "$(cat "$FIX8D/agent/state/pr-doctor.rc.pending" 2>/dev/null)" = "not-a-number" ]; then
  pass "an UNREADABLE value is retained through a failed write too (the record of what it held survives)"
else
  fail "the unreadable sidecar was deleted when its report could not be written — the arm's gate is missing"
fi

echo ""
echo "9. the WORD is chosen by the rc: a crash is not a refusal (REFUSED is #1872's exit-2 word)"
FIX9="$(mkfix crash 4 0)"; LOG9="$(logof "$FIX9")"
run_pass "$FIX9"
if has "$(cat "$LOG9" 2>/dev/null)" "PR-DOCTOR launched detached"; then
  : # the non-vacuity floor is asserted below on the report itself
else
  fail "case 9: pass 1 wrote no launch line — the case proves nothing"
fi
wait_rc "$FIX9/agent/state/pr-doctor.rc" 4
run_pass "$FIX9"
LOG9TXT="$(cat "$LOG9" 2>/dev/null)"
if has "$LOG9TXT" "PR-DOCTOR RED rc=4"; then
  pass "a CRASH (rc=4) is reported as 'PR-DOCTOR RED rc=4'"
else
  fail "a crash (rc=4) produced no 'PR-DOCTOR RED rc=4' line (got: $(grep -m1 'rc=4' "$LOG9" 2>/dev/null | cut -c1-140))"
fi
if has "$LOG9TXT" "PR-DOCTOR REFUSED"; then
  fail "a CRASH was reported as a REFUSAL — the reader then chases the queue read instead of the crash"
else
  pass "...and it is NOT claimed as a refusal (rc=4 is a crash; only rc=2 is a refusal)"
fi

echo ""
echo "10. a retained failure is reported with ITS OWN tail, not with a LATER run's stderr"
FIX10="$(mkfix retainedtail 0 0)"; LOG10="$(logof "$FIX10")"
printf '2\n' > "$FIX10/agent/state/pr-doctor.rc"
printf 'REAL-CAUSE-AT-THE-TIME-OF-THE-FAILURE\n' > "$FIX10/agent/state/pr-doctor.stderr"
: > "$FIX10/agent/state/PR-DOCTOR-OFF"
rm -f "$LOG10"; mkdir -p "$LOG10"            # the log outage: no report can land
run_pass "$FIX10"
if [ "$(cat "$FIX10/agent/state/pr-doctor.rc.pending" 2>/dev/null)" = "2" ]; then
  pass "CONTROL: the failure was RETAINED across the outage (so the report below has a subject)"
else
  fail "CONTROL failed — nothing was retained, so case 10 proves nothing"
fi
# A LATER run overwrites the child's stderr before the next pass drains the carrier. This is what
# `: > "$STATE/<child>.stderr"` at every launch does in production; here it is deterministic.
printf 'LATER-RUN-NOISE-nothing-failed-here\n' > "$FIX10/agent/state/pr-doctor.stderr"
rm -rf "$LOG10"                                # the log recovers
run_pass "$FIX10"
LOG10TXT="$(cat "$LOG10" 2>/dev/null)"
if has "$LOG10TXT" "PR-DOCTOR REFUSED rc=2 :: REAL-CAUSE-AT-THE-TIME-OF-THE-FAILURE"; then
  pass "10. the retained failure carries the tail SNAPSHOTTED when it was retained"
else
  fail "the retained rc=2 was reported with '$(grep -m1 'PR-DOCTOR REFUSED' "$LOG10" 2>/dev/null | cut -c1-150)' — the tail names a different run"
fi
if has "$LOG10TXT" "LATER-RUN-NOISE"; then
  fail "the retained report carried a LATER run's stderr — a diagnosis that names the wrong cause"
else
  pass "...and it does NOT carry the later run's line"
fi

echo ""
echo "11. a value on disk when a LAUNCH takes the sidecar is preserved, not overwritten"
# The drain runs at the top of the dispatch region and each launch writes the SAME sidecar path with
# `mv -f`, so a child that finishes between the two (or a sibling started by the stale-lock takeover,
# which deliberately runs a second child while the first is alive) had its rc destroyed. Seeded here
# deterministically: an OLDER retained value is drained first, leaving an unreported `.rc` in place
# when this pass launches.
FIX11="$(mkfix launchpreserve 0 0)"; LOG11="$(logof "$FIX11")"
printf '4\n' > "$FIX11/agent/state/pr-doctor.rc"
printf '2\n' > "$FIX11/agent/state/pr-doctor.rc.pending"
printf 'SEEDED-OLD-CAUSE-LINE\n' > "$FIX11/agent/state/pr-doctor.stderr"
run_pass "$FIX11"
wait_rc "$FIX11/agent/state/pr-doctor.rc" 0    # the launched child really did rewrite `.rc`
if [ "$(cat "$FIX11/agent/state/pr-doctor.rc.pending" 2>/dev/null)" = "4" ]; then
  pass "11. the launch MOVED the unreported rc=4 to the launch-proof carrier instead of overwriting it"
else
  fail "the launch destroyed an unreported rc=4 (pending='$(cat "$FIX11/agent/state/pr-doctor.rc.pending" 2>/dev/null)') — a dispatch failure became invisible forever"
fi
run_pass "$FIX11"
if has "$(cat "$LOG11" 2>/dev/null)" "PR-DOCTOR RED rc=4"; then
  pass "...and the preserved value is REPORTED on the next pass (retention with a retry path)"
else
  fail "the value survived but was never reported — retention without a retry path is a quieter loss"
fi
# ⛔ THE SNAPSHOT MUST BE TAKEN BEFORE THE TRUNCATION (re-review P2, MEASURED). Asserting only the
# `rc=4` prefix left the order unpinned: swapping the snapshot below `: > …stderr` kept every case
# green while the preserved report lost the line that names its cause — case 10's defect, one path
# over. The seed is the only tail this report can legitimately carry.
if has "$(cat "$LOG11" 2>/dev/null)" "PR-DOCTOR RED rc=4 :: SEEDED-OLD-CAUSE-LINE"; then
  pass "...and with its tail, snapshotted BEFORE the launch truncated the child's stderr"
else
  fail "the preserved rc=4 was reported without its tail (got: $(grep -m1 'RED rc=4' "$LOG11" 2>/dev/null | cut -c1-140)) — the snapshot ran after the truncation"
fi
# ⛔ THE DISPATCHER HALF IS PINNED TOO (re-review P2, MEASURED: deleting the dispatcher's guard left
# the suite fully green). Every guard in this file comes in twins; a value destroyed at the
# dispatcher launch is the same silent loss as one destroyed at the doctor launch.
FIX11B="$(mkfix launchpreserveqd 0 0)"; LOG11B="$(logof "$FIX11B")"
printf '4\n' > "$FIX11B/agent/state/queue-dispatch.rc"
printf '2\n' > "$FIX11B/agent/state/queue-dispatch.rc.pending"
run_pass "$FIX11B"
wait_rc "$FIX11B/agent/state/queue-dispatch.rc" 0
if [ "$(cat "$FIX11B/agent/state/queue-dispatch.rc.pending" 2>/dev/null)" = "4" ]; then
  pass "11b. the DISPATCHER launch preserves an unreported rc too (the twin guard is not decorative)"
else
  fail "the dispatcher launch destroyed an unreported rc=4 (pending='$(cat "$FIX11B/agent/state/queue-dispatch.rc.pending" 2>/dev/null)')"
fi
run_pass "$FIX11B"
if has "$(cat "$LOG11B" 2>/dev/null)" "QUEUE-DISPATCH FAILED rc=4"; then
  pass "...and it is reported on the next pass"
else
  fail "the dispatcher's preserved rc=4 was never reported"
fi

echo ""
echo "12. only HEARTBEAT_PASS_ONCE=1 is one-pass — a non-empty value must not kill the heartbeat"
FIX12="$(mkfix passonce0 0 0)"; LOG12="$(logof "$FIX12")"
# ⛔ NO HARD DEADLINE FOR THE PASS ITSELF (re-review P1, MEASURED: a 2 s `timeout` reddened this
# CONTROL twice in 26 runs on a loaded box, with a message blaming the product — a pass is ~200 ms
# nominally but seconds under load). The question is not "how long may a pass take?" but "did the
# loop STOP after one pass?", so the pass is POLLED for and then the PROCESS is probed: pre-fix it
# is gone within milliseconds of logging `PASS done`, post-fix it is asleep (the loop sleeps
# hundreds of seconds), so 2 s of probing separates them with no dependence on machine speed.
# ⛔ THE LOOP GETS ITS OWN PROCESS GROUP (review advisory, #1954). Between passes it parks in
# `sleep "$SLP"` (540 s measured), and signalling the loop ALONE orphaned that sleep (ppid 1) —
# the same litter class run_pass's watchdog comment documents as fixed for its own `sleep 90`.
# `set -m` makes the loop a group leader, so the group signal below takes the sleep with it.
set -m
HOME="$FIX12/home" HEARTBEAT_PI_AGENT_DIR="$FIX12/agent" LOOP_DETACHED=1 HEARTBEAT_PASS_ONCE=0 \
  /bin/bash "$LOOP" >/dev/null 2>&1 &
pid12=$!
set +m
i=0; while [ "$i" -lt 300 ] && ! has "$(cat "$LOG12" 2>/dev/null)" "PASS done in"; do
  i=$((i + 1)); sleep 0.1
done
if has "$(cat "$LOG12" 2>/dev/null)" "PASS done in"; then
  pass "CONTROL: a '=0' run still executed a real pass (so the probe below means what it says)"
else
  fail "CONTROL failed — the '=0' run never finished a pass (see $LOG12)"
fi
i=0; while [ "$i" -lt 20 ] && kill -0 "$pid12" 2>/dev/null; do i=$((i + 1)); sleep 0.1; done
if kill -0 "$pid12" 2>/dev/null; then
  pass "12. HEARTBEAT_PASS_ONCE=0 does NOT stop the loop (only '=1' is one-pass)"
  # The parked sleep IS the litter subject, so it is captured BEFORE the signal: an implementation
  # that signals only the loop leaves it alive for ~540 s (pre-fix behaviour) and the check below
  # says so instead of passing vacuously on a `ps` that simply found nothing.
  sleep12=""
  i=0; while [ "$i" -lt 30 ] && [ -z "$sleep12" ]; do
    sleep12="$(ps -eo pid=,ppid=,args= 2>/dev/null | awk -v p="$pid12" '$2==p && $3=="sleep"{print $1; exit}')"
    [ -n "$sleep12" ] || { i=$((i + 1)); sleep 0.1; }
  done
  if [ -n "$sleep12" ]; then
    pass "CONTROL: the running loop is parked in a real \`sleep\` (so the litter check has a subject)"
  else
    fail "CONTROL failed — the '=0' loop is alive but has no \`sleep\` child to orphan"
  fi
  kill -TERM -- "-$pid12" 2>/dev/null || kill -TERM "$pid12" 2>/dev/null
  wait "$pid12" 2>/dev/null
  i=0; while [ "$i" -lt 20 ] && [ -n "$sleep12" ] && kill -0 "$sleep12" 2>/dev/null; do
    i=$((i + 1)); sleep 0.1
  done
  if [ -n "$sleep12" ] && kill -0 "$sleep12" 2>/dev/null; then
    fail "case 12 left the loop's parked \`sleep\` ORPHANED (pid $sleep12, ~540 s of litter, ppid 1)"
  else
    pass "...and stopping it leaves NO orphan: the group signal took the parked \`sleep\`"
  fi
else
  fail "HEARTBEAT_PASS_ONCE=0 exited after one pass — any non-empty value killed the fleet heartbeat"
fi

echo ""
echo "14. a retained carrier is NOT overwritten by the next pass's launch (re-review P1, MEASURED)"
# The guard added in case 11 first had no "no carrier waiting" test, so while a retained rc=2 sat
# waiting (its log still down) the next pass's guard replaced it with the clean child's 0, which the
# drain then consumed as silence: the failure was never reported at all (measured: pass1
# pending=2 -> pass2 pending=0 -> no rc= line, ever). A retention must outlive the outage.
FIX14="$(mkfix retainedacrosspasses 0 0)"; LOG14="$(logof "$FIX14")"
printf '2\n' > "$FIX14/agent/state/pr-doctor.rc.pending"
printf 'THE-REAL-CAUSE\n' > "$FIX14/agent/state/pr-doctor.rc.tail"
rm -f "$LOG14"; mkdir -p "$LOG14"          # the outage spans TWO passes
run_pass "$FIX14"
wait_rc "$FIX14/agent/state/pr-doctor.rc" 0  # a clean child DID write its own rc=0 meanwhile
run_pass "$FIX14"
if [ "$(cat "$FIX14/agent/state/pr-doctor.rc.pending" 2>/dev/null)" = "2" ]; then
  pass "14. the retained rc=2 survived a SECOND pass (the launch guard did not overwrite the carrier)"
else
  fail "the launch overwrote the retained carrier with '$(cat "$FIX14/agent/state/pr-doctor.rc.pending" 2>/dev/null)' — the failure is lost for good"
fi
rm -rf "$LOG14"                              # the log recovers
run_pass "$FIX14"
if has "$(cat "$LOG14" 2>/dev/null)" "PR-DOCTOR REFUSED rc=2 :: THE-REAL-CAUSE"; then
  pass "...and it is reported, with its own tail, once the log recovers"
else
  fail "the retained failure never reached the recovered log — (got: $(grep -m1 'PR-DOCTOR REFUSED' "$LOG14" 2>/dev/null | cut -c1-140))"
fi

echo ""
echo "13. <child>.stderr is TRUNCATED at launch — run N's report cannot carry run N-1's line"
FIX13="$(mkfix truncation 2 0)"; LOG13="$(logof "$FIX13")"
# A child that writes its stderr marker ONLY on its first launch, so a missing truncation is visible:
# without it, run 2's report would carry run 1's marker (the wrong run's cause).
printf 'import os, sys\nf = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pr-doctor.seen")\nif not os.path.exists(f):\n    open(f, "w").write("1")\n    sys.stderr.write("FIRST-RUN-ONLY-MARKER\\n")\nsys.exit(2)\n' \
  > "$FIX13/agent/scripts/pr-doctor.py"
run_pass "$FIX13"
wait_rc "$FIX13/agent/state/pr-doctor.rc" 2
run_pass "$FIX13"                               # reports run 1 (with its own marker) AND launches run 2
wait_rc "$FIX13/agent/state/pr-doctor.rc" 2      # run 2 has written its own rc=2
run_pass "$FIX13"                               # reports run 2, which wrote NOTHING to stderr
LAST13="$(grep -- 'PR-DOCTOR REFUSED rc=2' "$LOG13" 2>/dev/null | tail -1)"
if [ -z "$LAST13" ]; then
  fail "case 13 never produced a refusal report at all — the assertions below are void (see $LOG13)"
elif has "$LAST13" "FIRST-RUN-ONLY-MARKER"; then
  fail "run 2's report carried RUN 1's stderr ('$LAST13') — <child>.stderr was not truncated at launch, so the tail names the wrong run"
else
  pass "13. run 2's report carries no stale tail: the child's stderr is truncated at every launch"
fi

if [ "$failures" -eq 0 ]; then
  echo "✅ heartbeat-loop suite passed (${checks} assertions)"
  exit 0
fi
echo "❌ heartbeat-loop suite: $failures of $checks assertion(s) failed"
exit 1
