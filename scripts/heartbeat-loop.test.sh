#!/bin/bash
# scripts/heartbeat-loop.test.sh — #1933: the detached child's exit status must be REPORTED.
#
# ⛔ THE SUBJECT IS NOW ONE CHILD (#1874). When this suite was written the beat launched BOTH
# ⛔ `queue-dispatch.py` and `pr-doctor.py` detached; the lane-table dispatcher was retired by
# ⛔ #1874, so `pr-doctor.py` is the only detached dispatch left and every assertion below grades
# ⛔ it. The dispatcher-specific cases (5, 11b) are retired in place with a note saying what they
# ⛔ covered and which surviving case carries that coverage; the retired step itself is preserved
# ⛔ at `scripts/orchestrator-harness/retired/queue-dispatch.py`.
#
# THE DEFECT THIS SUITE PINS
# --------------------------
#   `heartbeat-loop.sh` launches `pr-doctor.py` DETACHED (deliberately: a pass must not wait on a
#   full dispatch cycle), and then reported its health with a LITERAL
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
#   5. RETIRED (#1874) — `queue-dispatch.py` got the same treatment (`QUEUE-DISPATCH FAILED
#      rc=N`), because the deleted dead branch was ITS report. That step no longer launches, so
#      the case is a note at its old position rather than an assertion on a line nothing writes.
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
#  15. THE PATH PIN'S RANK (#1867 review P1 residual) — the gh shim must outrank
#      `/opt/homebrew/bin`, which is where `gh` lives on a brew Mac. Prepending per entry installed
#      the list REVERSED, so the shim was shadowed and the #984/#1910 gates inert.
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
# mkfix <case> <pr-doctor-exit>
#
# ⛔ ONE DETACHED CHILD, since #1874 retired the lane-table dispatcher: `queue-dispatch.py` is no
# ⛔ longer launched by the beat, so a fixture that stubbed it (and a sidecar drain it no longer has)
# ⛔ would be pinning a step that cannot run — the shape `scripts/test_dispatch_wiring.py` exists to
# ⛔ refuse. The surviving launch, and every assertion below, is `pr-doctor.py`.
mkfix() {
  local d="$TMP/$1" pdr="$2"
  mkdir -p "$d/home" "$d/agent/state/queues" "$d/agent/scripts/lib"
  # The tick (step 1), its fallback scan, and the classifier/nudger steps: all no-ops. `|| true`
  # is not needed — each stub exits 0 by construction. The TICK deliberately writes a line to
  # stderr, because that is the input which proves the drained tail is the CHILD's own and not
  # "whoever wrote to the shared heartbeat-stderr.log last" (see case 2).
  printf '#!/bin/bash\nprintf "TICK-NOISE-not-a-pr-doctor-error\\n" >&2\nexit 0\n' \
    > "$d/agent/scripts/orchestrator-heartbeat.sh"
  printf '#!/bin/bash\nexit 0\n' > "$d/agent/scripts/lane-scan-fallback.sh"
  local py
  for py in lane-actions turn-classify turn-end lane-watchdog; do
    printf 'import sys\nsys.exit(0)\n' > "$d/agent/scripts/$py.py"
  done
  # The ONE DETACHED child under test. Its exit code is the input of every case, and it writes a
  # marker to its OWN stderr so case 2 can prove the report's tail is attributed to it.
  printf 'import sys\nsys.stderr.write("PRDOCTOR-OWN-STDERR-MARKER\\n")\nsys.exit(%s)\n' "$pdr" \
    > "$d/agent/scripts/pr-doctor.py"
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
  # ⛔ `RUN_PASS_PATH` LETS ONE CASE CHOOSE THE INHERITED PATH (#1867 review P2, round 6). The pin's
  # whole job is to OVERRIDE an inherited rank, so a case that wants to prove it must be able to
  # hand the loop a PATH of its own; every other case takes `$PATH` unchanged. `-`, not `:-`: an EMPTY
  # value is a PATH OF ITS OWN (round 8's §15d drives an empty PATH), not a request for the default.
  ( HOME="$d/home" HEARTBEAT_PI_AGENT_DIR="$d/agent" LOOP_DETACHED=1 HEARTBEAT_PASS_ONCE=1 \
      PATH="${RUN_PASS_PATH-$PATH}" \
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
FIX="$(mkfix refused 2)"; LOG="$(logof "$FIX")"

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
FIX3="$(mkfix consumed 0)"; LOG3="$(logof "$FIX3")"
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
# Reuse the consumed fixture: the child exits 0 there and the log now has 2 passes in it.
# ⛔ THE DISPATCHER HALF LEFT WITH THE DISPATCHER (#1874). This case used to assert that a clean
# ⛔ `queue-dispatch.py` produced no `QUEUE-DISPATCH FAILED` line; the beat no longer launches it,
# ⛔ so the assertion would grade a line that cannot be written either way.
FIX4="$(mkfix clean 0)"; LOG4="$(logof "$FIX4")"
run_pass "$FIX4"; sleep 0.5; run_pass "$FIX4"
if [ "$(num_of "$LOG4" 'PR-DOCTOR REFUSED')" -eq 0 ] && has "$(cat "$LOG4" 2>/dev/null)" "PR-DOCTOR launched"; then
  pass "two passes with a clean pr-doctor: the pass RAN and logged no refusal"
else
  fail "a clean pr-doctor produced a refusal (or the pass did not run) — see $LOG4"
fi

echo ""
# 5. RETIRED WITH ITS SUBJECT (#1874): "the dispatcher gets the same treatment" pinned
# `QUEUE-DISPATCH FAILED rc=N`, its own sidecar drain and the drain-before-launch ordering for
# `queue-dispatch.py`. The beat no longer launches that step — `scripts/test_dispatch_wiring.py`
# now REFUSES its re-appearance — so there is no child, no sidecar and no report line left to
# pin here. The ordering rule it also covered (drain BEFORE this pass's launch) is still pinned
# for the surviving step by `order_pinned` in case 2; deleting this case removes no coverage of
# `pr-doctor.py`. The retired source and the record of what it did are in
# `scripts/orchestrator-harness/retired/queue-dispatch.py` and step 4 of the beat's own note.

echo ""
echo "6. an unreadable sidecar is NAMED, never read as success or as a failure"
FIX6="$(mkfix garbage 0)"; LOG6="$(logof "$FIX6")"
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
FIX7="$(mkfix nonewline 0)"; LOG7="$(logof "$FIX7")"
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
FIX8A="$(mkfix logwritable 0)"; LOG8A="$(logof "$FIX8A")"
printf '2\n' > "$FIX8A/agent/state/pr-doctor.rc"
: > "$FIX8A/agent/state/PR-DOCTOR-OFF"
run_pass "$FIX8A"
if has "$(cat "$LOG8A" 2>/dev/null)" "PR-DOCTOR REFUSED rc=2" && [ ! -f "$FIX8A/agent/state/pr-doctor.rc" ]; then
  pass "CONTROL: a writable log gets the report and the sidecar is consumed"
else
  fail "CONTROL failed — the drain was not reached in this fixture shape, so case 8 proves nothing"
fi
FIX8B="$(mkfix logunwritable 0)"; LOG8B="$(logof "$FIX8B")"
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
FIX8C="$(mkfix logunwritablelaunch 0)"; LOG8C="$(logof "$FIX8C")"
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
FIX8D="$(mkfix logunwritablegarbage 0)"; LOG8D="$(logof "$FIX8D")"
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
FIX9="$(mkfix crash 4)"; LOG9="$(logof "$FIX9")"
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
FIX10="$(mkfix retainedtail 0)"; LOG10="$(logof "$FIX10")"
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
FIX11="$(mkfix launchpreserve 0)"; LOG11="$(logof "$FIX11")"
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
# ⛔ THE DISPATCHER TWIN IS RETIRED WITH ITS SUBJECT (#1874). `FIX11B` seeded
# `queue-dispatch.rc` / `.rc.pending` and asserted the SAME preservation for that launch; the beat
# launches only `pr-doctor.py` now, so the twin has no launch to grade. The surviving guard is
# still pinned twice over — case 8C/14 for the carrier-vs-launch interaction and case 11 above for
# the snapshot order — so nothing about `pr-doctor.py`'s preservation is left uncovered.

echo "12. only HEARTBEAT_PASS_ONCE=1 is one-pass — a non-empty value must not kill the heartbeat"
FIX12="$(mkfix passonce0 0)"; LOG12="$(logof "$FIX12")"
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
FIX14="$(mkfix retainedacrosspasses 0)"; LOG14="$(logof "$FIX14")"
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
FIX13="$(mkfix truncation 2)"; LOG13="$(logof "$FIX13")"
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

echo ""
echo "14. #2291: a NO-CAPACITY verdict is WAITING, not RED — and a transport refusal is still RED"
# ⛔ THE TWO FACTS THAT SHARED `EXIT rc=3` NOW SHARE NOTHING a reader can confuse. `pr-doctor` writes
# rc=6 when the box's own spawn gate refused every order (nothing consumed, clears by itself); the
# beat used to print that as `PR-DOCTOR RED rc=6`, the same line a broken dispatcher produces, so the
# one screen an operator reads could not tell "wait" from "repair". The record is seeded directly:
# the reader under test is the status.json block, and the stub child only writes its own rc.
FIX14="$(mkfix no-capacity 0)"; LOG14="$(logof "$FIX14")"
printf '{"rc": 6, "verdict": "NO-CAPACITY", "reason": "VERDICT=NO-CAPACITY bound=load=1 room=host=box ncpu=8 load1=4520 lpc=565; 1 order(s) the BOX refused", "at": "x", "at_epoch": %s}\n' \
  "$(date +%s)" > "$FIX14/agent/state/pr-doctor.status.json"
run_pass "$FIX14"
TXT14="$(cat "$LOG14" 2>/dev/null)"
if has "$TXT14" "PR-DOCTOR WAITING (no capacity) rc=6"; then
  pass "14. a NO-CAPACITY record reads WAITING — the box has no room, nothing failed"
else
  fail "14. a no-capacity record produced no WAITING line (see $LOG14) — a busy box reads as a broken dispatcher"
fi
if has "$TXT14" "PR-DOCTOR RED rc=6"; then
  fail "14. a no-capacity record was reported as RED — the operator is sent to repair a box that only needs to be waited for"
else
  pass "14. …and it is NOT reported as RED"
fi
if has "$TXT14" "lpc=565"; then
  pass "14. …and the box's own measurement reaches the line"
else
  fail "14. the no-capacity line carried no box measurement — the report says 'nobody took it' without saying what was measured"
fi
# CONTROL: the allowance is for code 6 only. A transport refusal (3) must still be RED, or this arm
# would be "everything is WAITING" — the false-pass direction.
FIX14B="$(mkfix transport-refusal 0)"; LOG14B="$(logof "$FIX14B")"
printf '{"rc": 3, "verdict": "UNDELIVERED", "reason": "VERDICT=UNDELIVERED next=repair the dispatch chain", "at": "x", "at_epoch": %s}\n' \
  "$(date +%s)" > "$FIX14B/agent/state/pr-doctor.status.json"
run_pass "$FIX14B"
TXT14B="$(cat "$LOG14B" 2>/dev/null)"
if has "$TXT14B" "PR-DOCTOR RED rc=3"; then
  pass "14. a TRANSPORT refusal is still RED (the WAITING allowance is narrow)"
else
  fail "14. a transport refusal no longer reads RED — code 3 has been swallowed with 6 (see $LOG14B)"
fi

# ⛔ THE OTHER TWO pr-doctor SURFACES IN THIS FILE (review P1, #2291). Teaching only the
# `status.json` block left the DRAIN and the LAUNCHD arm printing `RED` for the same rc=6 — one
# heartbeat saying "RED rc=6" one line above "WAITING (no capacity) rc=6". Both are driven here with
# the seeding pattern the other cases already use (`pr-doctor.rc` for the drain, a `launchctl` stub
# for the scheduled job).
FIX14C="$(mkfix no-capacity-drain 0)"; LOG14C="$(logof "$FIX14C")"
printf '6\n' > "$FIX14C/agent/state/pr-doctor.rc"
run_pass "$FIX14C"
TXT14C="$(cat "$LOG14C" 2>/dev/null)"
if has "$TXT14C" "PR-DOCTOR WAITING (no capacity) rc=6"; then
  pass "14c. a DRAINED rc=6 reads WAITING — the detached run is not reported as broken"
else
  fail "14c. the drain reported a no-capacity run without the WAITING word (got: $(grep -m1 'rc=6' "$LOG14C" 2>/dev/null | cut -c1-140))"
fi
if has "$TXT14C" "PR-DOCTOR RED rc=6"; then
  fail "14c. the drain still printed 'PR-DOCTOR RED rc=6' — the same log then carries two verdicts for one pass"
else
  pass "14c. …and it is NOT reported as RED"
fi

# The SCHEDULED job runs pr-doctor.py directly, so LastExitStatus=6 lands on its own arm.
STUBBIN="$TMP/stubbin"; mkdir -p "$STUBBIN"
printf '#!/bin/bash\n[ "${1:-}" = list ] && printf -- "-\\t6\\tcom.tortoise.pr-doctor\\n"\nexit 0\n' \
  > "$STUBBIN/launchctl"; chmod +x "$STUBBIN/launchctl"
FIX14D="$(mkfix no-capacity-launchd 0)"; LOG14D="$(logof "$FIX14D")"
printf '{"rc": 6, "verdict": "NO-CAPACITY", "reason": "VERDICT=NO-CAPACITY next=wait bound=load=1", "at_epoch": %s}\n' \
  "$(date +%s)" > "$FIX14D/agent/state/pr-doctor.status.json"
export HEARTBEAT_LAUNCHCTL="$STUBBIN/launchctl"
run_pass "$FIX14D"
unset HEARTBEAT_LAUNCHCTL
TXT14D="$(cat "$LOG14D" 2>/dev/null)"
if has "$TXT14D" "PR-DOCTOR LAUNCHD WAITING (no capacity, last exit 6)"; then
  pass "14d. the scheduled job's last exit 6 reads WAITING — 'the scheduled job is failing' is not claimed"
else
  fail "14d. the launchd arm did not report a no-capacity last exit as WAITING (got: $(grep -m1 'LAUNCHD' "$LOG14D" 2>/dev/null | cut -c1-140))"
fi
if has "$TXT14D" "LAUNCHD RED (last exit 6)"; then
  fail "14d. the launchd arm still says the scheduled job is failing on a no-capacity pass"
else
  pass "14d. …and it is NOT reported as a failing job"
fi
# CONTROL: the allowance is for 6 alone. A real failure on the same arm is still RED.
FIX14E="$(mkfix failing-launchd 0)"; LOG14E="$(logof "$FIX14E")"
printf '#!/bin/bash\n[ "${1:-}" = list ] && printf -- "-\\t4\\tcom.tortoise.pr-doctor\\n"\nexit 0\n' \
  > "$STUBBIN/launchctl"
export HEARTBEAT_LAUNCHCTL="$STUBBIN/launchctl"
run_pass "$FIX14E"
unset HEARTBEAT_LAUNCHCTL
TXT14E="$(cat "$LOG14E" 2>/dev/null)"
if has "$TXT14E" "PR-DOCTOR LAUNCHD RED (last exit 4)"; then
  pass "14e. a CRASHING scheduled job (last exit 4) is still RED (the WAITING arm is narrow)"
else
  fail "14e. a crashing scheduled job no longer reads RED — the WAITING arm swallowed every exit"
fi

# ⛔ A STALE RECORD IS UNREPORTED BEFORE IT IS ANYTHING ELSE (review P1, #2291). The rc arms were
# tested BEFORE the age arm, so a `6` written six hours ago printed
# `PR-DOCTOR WAITING (no capacity) rc=6 (21600s ago)` -- "the box has no room, wait" -- for a
# dispatcher that had written NO verdict at all since. `objective.pr_doctor_last_run()` deliberately
# orders it the other way (`age > 2400` -> UNREPORTED, before `waiting`), so the two readers of ONE
# record disagreed about the same file, on the one screen an operator reads.
FIX14F="$(mkfix stale-no-capacity 0)"; LOG14F="$(logof "$FIX14F")"
printf '{"rc": 6, "verdict": "NO-CAPACITY", "reason": "VERDICT=NO-CAPACITY bound=load=1", "at_epoch": %s}\n' \
  "$(( $(date +%s) - 21600 ))" > "$FIX14F/agent/state/pr-doctor.status.json"
run_pass "$FIX14F"
TXT14F="$(cat "$LOG14F" 2>/dev/null)"
if has "$TXT14F" "PR-DOCTOR RED UNREPORTED (verdict is STALE"; then
  pass "14f. a SIX-HOUR-OLD rc=6 reads UNREPORTED — a stale verdict is never 'wait'"
else
  fail "14f. a stale rc=6 was not reported as UNREPORTED (got: $(grep -m1 'PR-DOCTOR' "$LOG14F" 2>/dev/null | cut -c1-140))"
fi
if has "$TXT14F" "WAITING (no capacity)"; then
  fail "14f. a six-hour-old rc=6 still printed WAITING — nothing has written the record for six hours, so 'wait' answers a question nobody asked"
else
  pass "14f. …and it does NOT claim WAITING"
fi
# CONTROL: staleness outranks every rc arm, which is the SAME order `objective.pr_doctor_last_run()`
# uses. A FRESH rc=3 is still RED (14's control above), so this narrows staleness rather than
# swallowing failures.
FIX14G="$(mkfix stale-transport 0)"; LOG14G="$(logof "$FIX14G")"
printf '{"rc": 3, "verdict": "UNDELIVERED", "reason": "VERDICT=UNDELIVERED", "at_epoch": %s}\n' \
  "$(( $(date +%s) - 21600 ))" > "$FIX14G/agent/state/pr-doctor.status.json"
run_pass "$FIX14G"
TXT14G="$(cat "$LOG14G" 2>/dev/null)"
if has "$TXT14G" "PR-DOCTOR RED UNREPORTED (verdict is STALE"; then
  pass "14g. …and a stale rc=3 is UNREPORTED too (one ordering, matching objective.py)"
else
  fail "14g. a stale rc=3 was not reported as UNREPORTED (got: $(grep -m1 'PR-DOCTOR' "$LOG14G" 2>/dev/null | cut -c1-140))"
fi

echo ""
echo "15. THE PIN'S RANK: the gh shim must NOT lose to /opt/homebrew/bin (the brew-Mac box)"
# ⛔ THE DEFECT THIS PINS (#1867 review P1 residual). The pin was TWO loops that each PREPENDED per
# entry, and prepending in list order installs the list REVERSED — the LAST entry wins the front. So
# `/opt/homebrew/bin` landed ahead of `$HOME/.pi/agent/shims`: on a brew Mac (`gh` IS
# `/opt/homebrew/bin/gh`, `scripts/capacity-transfer.test.sh:48`) every child's bare `gh` resolved to
# the RAW binary, silently disarming the shim's #984 admin-merge guard and #1910 pacing gate for the
# loop's whole life while the pin looked installed. `MEMORY.md:59` records the same trap.
#
# ⛔ THE FIXTURE IS THE SHIPPED FILE, NOT A COPY OF ITS LOGIC. The two macOS-absolute dirs cannot
# exist on a Linux runner, so they are RE-ROOTED into the fixture and the assertion below proves the
# relocation changed nothing else. The pass is REAL: the tick stub only reports what the loop's own
# PATH made `gh` resolve to, so nothing here re-implements the precedence it is grading.
PINROOT="$TMP/pinrank"
mkdir -p "$PINROOT/opt/homebrew/bin" "$PINROOT/Applications/cmux.app/Contents/Resources/bin"
printf '#!/bin/bash\necho SHIM-GH\n' > "$PINROOT/shim-gh"
printf '#!/bin/bash\necho REAL-GH\n' > "$PINROOT/real-gh"
chmod +x "$PINROOT/shim-gh" "$PINROOT/real-gh"
RELOC="$PINROOT/relocated-heartbeat-loop.sh"
sed -e "s#/Applications/cmux.app#$PINROOT/Applications/cmux.app#g" \
    -e "s#/opt/homebrew/bin#$PINROOT/opt/homebrew/bin#g" "$LOOP" > "$RELOC"
BACK="$(sed -e "s#$PINROOT/Applications/cmux.app#/Applications/cmux.app#g" \
             -e "s#$PINROOT/opt/homebrew/bin#/opt/homebrew/bin#g" "$RELOC" | cksum)"
if [ "$BACK" = "$(cksum < "$LOOP")" ]; then
  pass "15. the fixture is the SHIPPED loop with ONLY the two macOS-absolute dirs re-rooted"
else
  fail "15. the relocated fixture is not the shipped loop — the arm would be grading a rewrite"
fi
FIX15="$(mkfix pinrank 0)"
# Every directory in the pin's list, all present, so the RANK is observable end to end.
mkdir -p "$FIX15/home/bin" "$FIX15/home/.pi/agent/bin" "$FIX15/home/.pi/agent/shims" "$FIX15/home/.local/bin"
cp "$PINROOT/shim-gh" "$FIX15/home/.pi/agent/shims/gh"
cp "$PINROOT/real-gh" "$PINROOT/opt/homebrew/bin/gh"
cat > "$FIX15/agent/scripts/orchestrator-heartbeat.sh" <<SH
#!/bin/bash
{ command -v gh; printf '%s\n' "\$PATH"; } > "$FIX15/gh-resolved" 2>&1
exit 0
SH
SAVED_LOOP="$LOOP"; LOOP="$RELOC"
run_pass "$FIX15"
LOOP="$SAVED_LOOP"
RESOLVED="$(sed -n 1p "$FIX15/gh-resolved" 2>/dev/null)"
PINPATH="$(sed -n 2p "$FIX15/gh-resolved" 2>/dev/null)"
# rank 1 = furthest front; 0 = not on PATH at all (an ABSENT control entry makes the order vacuous)
rank_of(){ printf '%s' "$1" | tr ':' '\n' | awk -v want="$2" '$0 == want { print NR; f=1 } END { if (!f) print 0 }'; }
SHIM_RANK="$(rank_of "$PINPATH" "$FIX15/home/.pi/agent/shims")"
BREW_RANK="$(rank_of "$PINPATH" "$PINROOT/opt/homebrew/bin")"
if [ "$BREW_RANK" -gt 0 ] && [ "$SHIM_RANK" -gt 0 ]; then
  pass "15. control: BOTH the shim dir and homebrew are on the pinned PATH (ranks $SHIM_RANK / $BREW_RANK)"
else
  fail "15. control: the pinned PATH is missing one of the two dirs (shim=$SHIM_RANK brew=$BREW_RANK) — nothing to rank"
fi
if [ "$RESOLVED" = "$FIX15/home/.pi/agent/shims/gh" ]; then
  pass "15. a child's bare 'gh' resolves to the SHIM, not to /opt/homebrew/bin/gh"
else
  fail "15. a child's bare 'gh' resolved to [${RESOLVED:-<none>}] — the shim is SHADOWED on the brew-Mac layout"
fi
if [ "$SHIM_RANK" -gt 0 ] && [ "$BREW_RANK" -gt 0 ] && [ "$SHIM_RANK" -lt "$BREW_RANK" ]; then
  pass "15. the shim dir outranks homebrew ($SHIM_RANK < $BREW_RANK) — list order is not installed reversed"
else
  fail "15. the shim dir does NOT outrank homebrew (shim=$SHIM_RANK brew=$BREW_RANK) — the pin is installed REVERSED"
fi

# ⛔ AND "ALREADY ON PATH" IS NOT "ALREADY IN FRONT" (#1867 review P2, round 6). The pin SKIPPED any
# entry already present, which preserves that entry's INHERITED rank. So on the very box this pin
# exists for — a brew Mac whose login PATH already carries /opt/homebrew/bin BEFORE
# $HOME/.pi/agent/shims — both dirs were skipped, only the absent ones were prepended, and the raw
# `gh` still won: the #984 admin-merge guard and #1910 pacing gate inert for every child, while the
# block's own comment said the shim dir "must never be omitted". §15 above cannot see this by
# construction: it inherits the RUNNER's PATH, which carries neither dir, so both are always absent
# and only the list order is graded. Here the inherited PATH carries BOTH, brew first.
FIX15B="$(mkfix pinrank2 0)"
mkdir -p "$FIX15B/home/bin" "$FIX15B/home/.pi/agent/bin" "$FIX15B/home/.pi/agent/shims" "$FIX15B/home/.local/bin"
cp "$PINROOT/shim-gh" "$FIX15B/home/.pi/agent/shims/gh"
cat > "$FIX15B/agent/scripts/orchestrator-heartbeat.sh" <<SH
#!/bin/bash
{ command -v gh; printf '%s\n' "\$PATH"; } > "$FIX15B/gh-resolved" 2>&1
exit 0
SH
RUN_PASS_PATH="$PINROOT/opt/homebrew/bin:$FIX15B/home/.pi/agent/shims:/usr/local/bin:/usr/bin:/bin"
run_pass "$FIX15B"
unset RUN_PASS_PATH
RES15B="$(sed -n 1p "$FIX15B/gh-resolved" 2>/dev/null)"
PATH15B="$(sed -n 2p "$FIX15B/gh-resolved" 2>/dev/null)"
if [ "$RES15B" = "$FIX15B/home/.pi/agent/shims/gh" ]; then
  pass "15b. an INHERITED shim dir behind homebrew is MOVED to the front, not skipped — bare 'gh' is the shim"
else
  fail "15b. the inherited PATH put homebrew ahead of the shims and the pin skipped both, so bare 'gh' resolved to [${RES15B:-<none>}] — the shim is SHADOWED on the exact box the pin exists for"
fi
S15B="$(rank_of "$PATH15B" "$FIX15B/home/.pi/agent/shims")"
B15B="$(rank_of "$PATH15B" "$PINROOT/opt/homebrew/bin")"
if [ "$S15B" -gt 0 ] && [ "$B15B" -gt 0 ] && [ "$S15B" -lt "$B15B" ]; then
  pass "15b. …and each dir appears once, shim ahead of homebrew (ranks $S15B / $B15B) — forced, not inherited"
else
  fail "15b. the pinned PATH has the shim dir at rank ${S15B:-0} and homebrew at rank ${B15B:-0} — the pin did not force the order"
fi

# ⛔ AND AN ALL-PINNED INHERITED PATH MUST NOT REINTRODUCE AN EMPTY COMPONENT (#1867 review P3, round 7).
# The prefix always ends in `:`; appending an EMPTY tail produced `…shims::/usr/local/bin:…`, and a
# double colon is an empty PATH component — the CWD — which is the hazard the same block's comment
# says it drops. The inputs that reach it: a caller whose whole PATH is already the pinned dirs, or
# an empty PATH.
FIX15C="$(mkfix pinrank3 0)"
mkdir -p "$FIX15C/home/bin" "$FIX15C/home/.pi/agent/bin" "$FIX15C/home/.pi/agent/shims" "$FIX15C/home/.local/bin"
cat > "$FIX15C/agent/scripts/orchestrator-heartbeat.sh" <<SH
#!/bin/bash
printf '%s\n' "\$PATH" > "$FIX15C/path"
exit 0
SH
RUN_PASS_PATH="$FIX15C/home/bin:$FIX15C/home/.pi/agent/bin:$FIX15C/home/.pi/agent/shims:$FIX15C/home/.local/bin"
run_pass "$FIX15C"
unset RUN_PASS_PATH
P15C="$(cat "$FIX15C/path" 2>/dev/null)"
if [ -z "$P15C" ]; then
  fail "15c. the pin row produced no PATH to inspect — nothing was measured"
elif [ "${P15C#:}" != "$P15C" ] || [ "${P15C%:}" != "$P15C" ] || [ "${P15C#*::}" != "$P15C" ]; then
  fail "15c. the pinned PATH carries an EMPTY component (the cwd): $P15C"
else
  pass "15c. a PATH made entirely of pinned dirs yields no empty component (the cwd is not silently added)"
fi

# ⛔ AND THE EMPTY-COMPONENT PRUNE MUST RUN FOR EVERY INPUT, NOT ONLY WHEN A PINNED DIR EXISTS
# (#1867 review P3, round 8). Round 7 closed the empty TAIL (no trailing `:` when `_pin_rest` is empty)
# and the comment claimed empty components "are dropped by the same pass" — but that pass lives INSIDE
# the `for _path_dir` loop, so it only ran when at least one of the six dirs existed, while the system
# tail was appended unconditionally afterwards. Two shapes slipped through: an EMPTY PATH with no pinned
# dir (the append built `:/usr/local/bin:…` — a LEADING empty component, i.e. the cwd ranked ahead of
# every system dir) and an INTERIOR `::` inherited from a caller (nothing pruned it). §15c cannot see
# either: its PATH is entirely pinned dirs, so the inner pass always runs there.
# ⚠️ DISCLOSED: this row's failing arm needs NO pinned dir to exist. Four of the six are under the
# fixture HOME (controlled), but `/Applications/cmux.app/…` and `/opt/homebrew/bin` are literals — on a
# host where either exists the inner pass runs and its prune covers the interior shape, so the row
# discriminates for the LEADING arm only there. On the Linux runner (where the suite runs in CI) neither
# exists, so both arms discriminate. The empty-PATH case is asserted against the leading arm directly.
FIX15D="$(mkfix pinrank4 0)"
cat > "$FIX15D/agent/scripts/orchestrator-heartbeat.sh" <<SH
#!/bin/bash
printf '%s\n' "\$PATH" > "$FIX15D/path"
exit 0
SH
# Shape 1: an EMPTY inherited PATH (a caller that exported PATH= / an unset-looking environment).
RUN_PASS_PATH=""
run_pass "$FIX15D"
P15D="$(cat "$FIX15D/path" 2>/dev/null)"
rm -f "$FIX15D/path"
if [ -z "$P15D" ]; then
  fail "15d. the empty-PATH row produced no PATH to inspect — nothing was measured"
elif [ "${P15D#:}" != "$P15D" ] || [ "${P15D%:}" != "$P15D" ] || [ "${P15D#*::}" != "$P15D" ]; then
  fail "15d. an EMPTY inherited PATH produced an EMPTY component (the cwd on PATH): $P15D"
else
  pass "15d. an EMPTY inherited PATH yields no empty component — the system tail is not welded on behind a ':'"
fi
case ":$P15D:" in
  *:/usr/bin:*) pass "15d. ... and the system tail is still appended (an empty PATH is not a broken PATH)" ;;
  *) fail "15d. the system tail is MISSING from the assembled PATH: ${P15D:-<none>}" ;;
esac
# Shape 2: an INTERIOR empty component inherited from the caller.
RUN_PASS_PATH="/usr/bin::/bin"
run_pass "$FIX15D"
P15E="$(cat "$FIX15D/path" 2>/dev/null)"
rm -f "$FIX15D/path"
unset RUN_PASS_PATH
if [ -z "$P15E" ]; then
  fail "15e. the interior-empty row produced no PATH to inspect — nothing was measured"
elif [ "${P15E#*::}" != "$P15E" ] || [ "${P15E#:}" != "$P15E" ] || [ "${P15E%:}" != "$P15E" ]; then
  fail "15e. an inherited INTERIOR empty component survived the pin (the cwd on PATH): $P15E"
else
  pass "15e. an inherited INTERIOR '::' is dropped — the prune is no longer conditional on a pinned dir existing"
fi

# ── 15f. THE OTHER TWO SPELLINGS OF THE cwd ENTRY (round 12) ─────────────────────────────────
# Dropping the EMPTY component only covers `::`. A caller can equally write `.` or `..`, and both name
# the child's cwd just as surely. This is NEW with the PATH inheritance: on main the block REPLACED
# PATH with one literal and inherited nothing, so neither spelling could survive it. The loop now runs
# for days, detached, and its children `cd` into worktrees and run bare commands — so a literal `.`
# executing whatever the cwd holds is the hazard the block's own comment names. MEASURED pre-fix:
# `PATH='/opt/homebrew/bin:/usr/bin:.:/bin'` → `…:/usr/bin:.:/bin:/usr/local/bin:…`.
RUN_PASS_PATH="/opt/homebrew/bin:/usr/bin:.:/bin:..:/sbin"
run_pass "$FIX15D"
P15F="$(cat "$FIX15D/path" 2>/dev/null)"
rm -f "$FIX15D/path"
unset RUN_PASS_PATH
# ⛔ A CHARACTER TEST IS NOT A COMPONENT TEST (#3826 review P2). This row asked `${P15F#*.}` —
# "strip the shortest prefix ending at ANY dot" — so a PATH whose DIRECTORY NAMES merely contain a
# dot failed while the property held. The pinned dirs necessarily carry dots on macOS:
# `heartbeat-loop.sh` pins `/Applications/cmux.app/Contents/Resources/bin` and `$HOME/.pi/agent/bin`,
# so on the ONE platform this change exists for the suite reddened for a non-defect. MEASURED by
# making a pinned dir exist in the fixture (nothing else changed):
#   FAIL 15f. a literal '.' or '..' survived the pin …: <fix>/home/.pi/agent/bin:/opt/homebrew/bin:…
# The property is about a `:`-delimited COMPONENT equal to `.` or `..`, which is what §15c-§15e
# already assert component-wise. Tested the same way here.
P15F_dot=0
case ":$P15F:" in *:.:*|*:..:*) P15F_dot=1 ;; esac
if [ -z "$P15F" ]; then
  fail "15f. the literal-dot row produced no PATH to inspect — nothing was measured"
elif [ "$P15F_dot" -eq 1 ]; then
  fail "15f. a literal '.' or '..' survived the pin (the cwd on PATH): $P15F"
else
  pass "15f. a literal '.' and '..' are dropped from an inherited PATH — the cwd cannot be executed from"
fi
case ":$P15F:" in
  *:/usr/bin:*) pass "15f. ... and the system tail is still appended (dropping them does not empty the PATH)" ;;
  *) fail "15f. the system tail is MISSING from the assembled PATH: ${P15F:-<none>}" ;;
esac

# ── 15g. THE FALSE-RED CONTROL FOR THE ROW ABOVE ───────────────────────────────────────────────
# A row that only asserts the ABSENCE of `.`/`..` cannot tell a correct component test from the
# character test it replaced: the pre-fix `${P15F#*.}` version passed this suite on Linux too, because
# no pinned dir carrying a dot EXISTED here. So the discriminating case is the other direction — a
# pinned dir that exists AND has a dot in its NAME, with no `.`/`..` component anywhere. The old
# assertion reds on it; the component test does not. `$HOME/.pi/agent/bin` is the real pinned path
# (`heartbeat-loop.sh`'s own list), so this is the shape macOS has and the Linux runner does not.
mkdir -p "$FIX15D/home/.pi/agent/bin"
RUN_PASS_PATH="/opt/homebrew/bin:/usr/bin:/bin"
run_pass "$FIX15D"
P15G="$(cat "$FIX15D/path" 2>/dev/null)"
rm -f "$FIX15D/path"
unset RUN_PASS_PATH
if [ -z "$P15G" ]; then
  fail "15g. the dot-in-a-directory-name row produced no PATH to inspect — nothing was measured"
elif [ "$(printf '%s' "$P15G" | grep -c '\.pi/agent/bin' || true)" -eq 0 ]; then
  fail "15g. the fixture's dot-bearing pinned dir is NOT on the assembled PATH, so the row proves nothing: $P15G"
else
  pass "15g. a pinned dir whose NAME contains a dot is not read as a '.' component (a component test, not a character test)"
fi
rmdir "$FIX15D/home/.pi/agent/bin" 2>/dev/null || true

# ── 16. THE LEGACY SELF-DETACH MUST NOT CLAIM A START IT DID NOT GET (#3826 review P3) ────────────
# ⛔ The detach arm slept one second and then printed
#   `heartbeat loop started (pid $(cat "$PIDFILE" 2>/dev/null || echo '?'))`   … exit 0
# so a FIRST run — `$STATE` absent, which is the documented start case — printed `started (pid ?)`
# with a green status while the child's `echo $$ > "$PIDFILE"` was failing silently and no loop ran.
# That is the same false PASS `heartbeat-launch.sh start` was written to remove (its §16c asserts the
# identical property one file over), left standing on the path the loop itself documents.
# The arm now POLLS for a live pidfile and fails loudly. Discriminating shape: the loop is made to exit
# at the top of its pass (the kill file), so a correct arm prints REFUSING rc 1 and a pre-fix arm prints
# `started (pid ?)` rc 0 — the two assertions below cannot both hold on the old code.
FIX16="$TMP/legacy16"
mkdir -p "$FIX16/home" "$FIX16/agent/state"
touch "$FIX16/agent/state/HEARTBEAT-OFF"
set +e
OUT16="$(HOME="$FIX16/home" HEARTBEAT_PI_AGENT_DIR="$FIX16/agent" /bin/bash "$LOOP" 2>&1)"
RC16=$?
set -e
if [ "$RC16" -eq 1 ]; then
  pass "16. a self-detach that leaves no live loop exits 1 (pre-fix: 0, with 'started (pid ?)')"
else
  fail "16. the self-detach exited $RC16 for a loop that is NOT running — a launch nobody verified"
fi
# ⛔ NO `printf … | grep -q` (#841/#864, and this repo's own guard reds it): under `pipefail` the
# writer takes SIGPIPE and the `if` takes its ELSE branch, so the assertion passes without reading the
# line. `case` tests the string directly — the pipe was never needed.
case "$OUT16" in
    *'REFUSING: the loop left no live pidfile'*)
        pass "16. …and names the artefact it looked for, so the operator knows what failed" ;;
    *)
        fail "16. the refusal did not name the missing pidfile: $OUT16" ;;
esac
case "$OUT16" in
    *'started (pid'*)
        fail "16. …and it still printed 'started (pid …)' over a loop that is not running: $OUT16" ;;
    *)
        pass "16. …and NEVER prints 'started' over an unverified launch" ;;
esac
# The other direction, so the row above cannot be green on a BROKEN FIXTURE: the same shape of layout,
# run the way every other case runs it (`LOOP_DETACHED=1`, one pass), must complete and exit 0. If the
# fixture itself could not run a loop, the refusal above would prove nothing about the detach arm.
FIX16C="$(mkfix legacy16c 0)"
set +e
run_pass "$FIX16C"
RC16C=$?
set -e
if [ "$RC16C" -eq 0 ]; then
  pass "16. control: the same fixture runs a real pass cleanly, so the refusal is the detach arm's own"
else
  fail "16. control: the fixture cannot run a pass (rc $RC16C) — the detach row above proves nothing"
fi

if [ "$failures" -eq 0 ]; then
  echo "✅ heartbeat-loop suite passed (${checks} assertions)"
  exit 0
fi
echo "❌ heartbeat-loop suite: $failures of $checks assertion(s) failed"
exit 1
