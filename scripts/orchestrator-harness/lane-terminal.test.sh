#!/usr/bin/env bash
# lane-terminal.test.sh — offline suite for lane-terminal.sh (agent-infra#2833).
#
# HERMETIC: throwaway $O, no network, no gh, no pi, no tmux. Every arm runs the REAL library in a real
# child process and asserts on the artifacts it leaves — never on the source text, because a source-shape
# assertion passes on a file whose runtime behaviour lost the property.
#
# WHAT IS PINNED, and why each arm exists:
#   • a lane that ends on its own is recorded WITH ITS OWN STATUS — 0 is an exit status, never "passed";
#   • a lane killed by a signal is recorded as `signal:<n>` and the signal is named (item 4's measurable
#     half) while the SENDER is never claimed (docs/ops/lane-signal-forensics.md proves it cannot be);
#   • a lane killed by SIGKILL leaves NO record and the census ABSTAINS — `no-terminal-record`, never
#     success and never failure (item 3's whole point);
#   • a STALE record from an earlier dispatch of the same issue is not read as this run's (a re-dispatched
#     lane's log is appended), because a stale flag that reads as a verdict is the false-PASS class;
#   • the caller's own EXIT cleanup is CHAINED and still runs, and its failure cannot change the status;
#   • lane-terminal.sh refuses to install over an existing EXIT trap instead of silently destroying it;
#   • lane.sh actually USES all of this — an unrecorded refusal is the population the issue is about.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/lane-terminal.sh"
pass=0; fail=0
ck() { # ck <name> <0|1>
  if [ "$2" -eq 0 ]; then printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1));
  else printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); fi
}
[ -s "$LIB" ] || { echo "  FAIL lane-terminal.sh is missing or empty"; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# A tiny driver: sources the real library, installs a record for $O/lane-<id>, optionally registers a
# cleanup and a reason, then exits with the status given.
drive() { # drive <driver-script> <O> [extra env assignments...] ; prints nothing, sets DR
  DR=0; O="$2" bash "$1" >/dev/null 2>&1 || DR=$?
}
mk_driver() { # mk_driver <path> <name> <exitcode> [reason] [cleanup]
  local p="$1" name="$2" code="$3" reason="${4:-}" cleanup="${5:-}"
  {
    echo 'set -u'
    echo ". '$LIB'"
    echo "lane_terminal_install \"\$O\" '$name' || exit 99"
    [ -n "$cleanup" ] && echo "lane_terminal_at_exit '$cleanup'"
    [ -n "$reason" ] && echo "lane_terminal_reason '$reason'"
    echo "exit $code"
  } > "$p"
}
rec_lines() { grep -c '^\[lane-terminal\] TERMINAL' "$1" 2>/dev/null || true; }
reason_of() { sed -n 's/^\[lane-terminal\] TERMINAL name=[^ ]* rc=[^ ]* reason=\([^ ]*\) .*/\1/p' "$1" 2>/dev/null | tail -1; }
rc_of()     { sed -n 's/^\[lane-terminal\] TERMINAL name=[^ ]* rc=\([^ ]*\) .*/\1/p' "$1" 2>/dev/null | tail -1; }

echo "── A. the writer: every ordinary exit path leaves one record with its OWN status ──"
O1="$T/o1"
mk_driver "$T/d1.sh" lane-1 0
drive "$T/d1.sh" "$O1"
ck "A1 exit 0 → rc file is 0, reason=exit (an EXIT STATUS, not a 'passed')" \
   $([ "$(cat "$O1/state/lane-1.rc" 2>/dev/null)" = "0" ] && [ "$(reason_of "$O1/logs/lane-1.log")" = "exit" ] && echo 0 || echo 1)
mk_driver "$T/d2.sh" lane-2 7
drive "$T/d2.sh" "$O1"
ck "A2 exit 7 → rc=7 recorded (a non-zero status never becomes an abstention)" \
   $([ "$(cat "$O1/state/lane-2.rc" 2>/dev/null)" = "7" ] && echo 0 || echo 1)
mk_driver "$T/d3.sh" lane-3 75 'refused:load'
drive "$T/d3.sh" "$O1"
ck "A3 a caller-named cause is recorded verbatim (refused:load, rc=75)" \
   $([ "$(reason_of "$O1/logs/lane-3.log")" = "refused:load" ] && [ "$(rc_of "$O1/logs/lane-3.log")" = "75" ] && echo 0 || echo 1)
mk_driver "$T/d4.sh" lane-4 1 'bad reason with spaces'
drive "$T/d4.sh" "$O1"
ck "A4 a reason with spaces is sanitised to ONE token (a record the reader cannot parse is a false abstention)" \
   $(grep -q 'reason=bad_reason_with_spaces' "$O1/logs/lane-4.log" && echo 0 || echo 1)
# A5: the cleanup runs AFTER the record — so a reaper that deletes a worktree cannot destroy the evidence.
mk_driver "$T/d5.sh" lane-5 3 'exit' "printf 'CLEANUP\n' >> '$O1/logs/lane-5.log'"
drive "$T/d5.sh" "$O1"
ck "A5 the caller's cleanup is CHAINED and runs AFTER the record line" \
   $([ "$(rec_lines "$O1/logs/lane-5.log")" = "1" ] \
      && [ "$(grep -n '^\[lane-terminal\]' "$O1/logs/lane-5.log" | cut -d: -f1)" -lt \
           "$(grep -n '^CLEANUP$' "$O1/logs/lane-5.log" | cut -d: -f1)" ] \
      && [ "$(cat "$O1/state/lane-5.rc")" = "3" ] && echo 0 || echo 1)
# A6: a FAILING cleanup does not change the lane's own status.
mk_driver "$T/d6.sh" lane-6 4 'exit' 'false'
drive "$T/d6.sh" "$O1"
ck "A6 a cleanup that fails does not change the recorded status (rc=4 stays 4)" \
   $([ "$DR" = "4" ] && [ "$(cat "$O1/state/lane-6.rc")" = "4" ] && echo 0 || echo 1)
# A7: install REFUSES to clobber an existing EXIT trap, and the caller's trap still runs.
cat > "$T/d7.sh" <<EOF
set -u
. '$LIB'
trap 'printf "MINE\n" >> "$O1/logs/pre-trap.log"' EXIT
lane_terminal_install "\$O" lane-7; echo "install_rc=\$?" >> "$O1/logs/pre-trap.log"
EOF
rm -f "$O1/logs/pre-trap.log"; O="$O1" bash "$T/d7.sh" >/dev/null 2>&1
ck "A7 install over an existing EXIT trap REFUSES (rc=2) and the caller's trap is not clobbered" \
   $(grep -q 'install_rc=2' "$O1/logs/pre-trap.log" && grep -q '^MINE$' "$O1/logs/pre-trap.log" \
      && [ "$(rec_lines "$O1/logs/lane-7.log")" = "0" ] && echo 0 || echo 1)

echo
echo "── B. a SIGNAL is recorded with its NUMBER; a SIGKILL leaves nothing and is never invented ──"
cat > "$T/hang.sh" <<EOF
set -u
. '$LIB'
lane_terminal_install "\$O" "\$NAME" || exit 99
while :; do sleep 0.2; done
EOF
O2="$T/o2"
NAME=lane-terM O="$O2" bash "$T/hang.sh" & p=$!; sleep 0.7; kill -TERM "$p" 2>/dev/null; wait "$p" 2>/dev/null; sw=$?
ck "B1 SIGTERM → rc=143, reason=signal:15, exactly ONE record line" \
   $([ "$sw" = "143" ] && [ "$(cat "$O2/state/lane-terM.rc")" = "143" ] \
      && [ "$(reason_of "$O2/logs/lane-terM.log")" = "signal:15" ] \
      && [ "$(rec_lines "$O2/logs/lane-terM.log")" = "1" ] && echo 0 || echo 1)
ck "B2 the record names the signal NUMBER and never a SENDER (forensics: the sender is unrecordable)" \
   $(grep -q 'reason=signal:15' "$O2/logs/lane-terM.log" && ! grep -qE 'sender=|killed_by=|SIGTERM by' "$O2/logs/lane-terM.log" && echo 0 || echo 1)
NAME=lane-int O="$O2" bash "$T/hang.sh" & p=$!; sleep 0.7; kill -INT "$p" 2>/dev/null; wait "$p" 2>/dev/null; si=$?
ck "B3 SIGINT → rc=130, reason=signal:2" \
   $([ "$si" = "130" ] && [ "$(reason_of "$O2/logs/lane-int.log")" = "signal:2" ] && echo 0 || echo 1)
NAME=lane-kil O="$O2" bash "$T/hang.sh" & p=$!; sleep 0.7; kill -KILL "$p" 2>/dev/null; wait "$p" 2>/dev/null; sk=$?
ck "B4 SIGKILL → NO terminal line and NO .rc content (a trap cannot run; the harness must not pretend)" \
   $([ "$sk" = "137" ] && [ "$(rec_lines "$O2/logs/lane-kil.log")" = "0" ] \
      && [ ! -s "$O2/state/lane-kil.rc" ] && echo 0 || echo 1)
ck "B5 the census reports that lane as no-terminal-record (ABSTENTION), not as failure and not as success" \
   $(O="$O2" bash "$LIB" --census > "$T/c1.txt" 2>&1; grep -q 'no-terminal-record  1' "$T/c1.txt" \
      && grep -q 'no record: lane-kil' "$T/c1.txt" && echo 0 || echo 1)

echo
echo "── C. a STALE record is not this run's, and a partial record is named as partial ──"
O3="$T/o3"
mk_driver "$T/d8.sh" lane-8 0
drive "$T/d8.sh" "$O3"                       # run A: records rc=0
NAME=lane-8 O="$O3" bash "$T/hang.sh" & p=$!; sleep 0.5; kill -KILL "$p" 2>/dev/null; wait "$p" 2>/dev/null
ck "C1 a re-dispatched lane killed with SIGKILL does NOT inherit run A's rc=0 (stale record rejected)" \
   $(O="$O3" bash "$LIB" --census > "$T/c2.txt" 2>&1; grep -q 'no-terminal-record  1' "$T/c2.txt" \
      && grep -q 'recorded            0' "$T/c2.txt" && echo 0 || echo 1)
O4="$T/o4"; mk_driver "$T/d9.sh" lane-9 0
drive "$T/d9.sh" "$O4"; rm -f "$O4/state/lane-9.rc"
ck "C2 a terminal line with no .rc is reported recorded-no-rc (partial), never silently 'recorded'" \
   $(O="$O4" bash "$LIB" --census > "$T/c3.txt" 2>&1; grep -q 'recorded-no-rc      1' "$T/c3.txt" \
      && grep -q 'no .rc:    lane-9' "$T/c3.txt" && echo 0 || echo 1)

echo
echo "── D. the census counts by reason, filters by window, and is a report — not a gate ──"
O5="$T/o5"; mkdir -p "$O5/logs" "$O5/state"
mk_driver "$T/e1.sh" lane-a 0;        drive "$T/e1.sh" "$O5"
mk_driver "$T/e2.sh" lane-b 77 'refused:disk'; drive "$T/e2.sh" "$O5"
mk_driver "$T/e3.sh" lane-c 1 'killed:exceeded-wallclock'; drive "$T/e3.sh" "$O5"
mk_driver "$T/e4.sh" lane-d 0 'something-else'; drive "$T/e4.sh" "$O5"
printf 'no record here\n' > "$O5/logs/lane-e.log"
O="$O5" bash "$LIB" --census > "$T/c4.txt" 2>&1; cr=$?
ck "D1 the census classifies a mixed population and prints the population size" \
   $(grep -q 'population=5 lane logs' "$T/c4.txt" && grep -q 'recorded            4' "$T/c4.txt" \
      && [ "$(sed -n 's/^    refused:  \([0-9]*\).*/\1/p' "$T/c4.txt")" = "1" ] \
      && [ "$(sed -n 's/^    killed:   \([0-9]*\).*/\1/p' "$T/c4.txt")" = "1" ] \
      && [ "$(sed -n 's/^    other     \([0-9]*\).*/\1/p' "$T/c4.txt")" = "1" ] && echo 0 || echo 1)
ck "D2 a report is not a gate: the census exits 0 with abstentions present (rc=$cr)" $([ "$cr" = 0 ] && echo 0 || echo 1)
O="$O5" bash "$LIB" --census --json > "$T/c5.json" 2>&1
ck "D3 --json carries the four states and the abstained lane's NAME (machine-readable, diffable)" \
   $(grep -q '"population":5' "$T/c5.json" && grep -q '"no_terminal_record":1' "$T/c5.json" \
      && grep -q '"no_terminal_record_lanes":"lane-e"' "$T/c5.json" && echo 0 || echo 1)
O="$O5" bash "$LIB" --census --hours abc >/dev/null 2>&1
ck "D4 an unusable --hours is REFUSED (exit 2), not silently read as 'all time'" $([ "$?" = 2 ] && echo 0 || echo 1)
O6="$T/o6"; mkdir -p "$O6/logs"
O="$O6" bash "$LIB" --census > "$T/c6.txt" 2>&1
ck "D5 an EMPTY population prints n/a and says it classified nothing (never a clean bill)" \
   $(grep -q 'population=0' "$T/c6.txt" && grep -q 'never a pass' "$T/c6.txt" && echo 0 || echo 1)

echo
echo "── E. sourcing the library has no side effects, and lane.sh really uses it ──"
O7="$T/o7"; mkdir -p "$O7"
( . "$LIB"; trap -p EXIT; trap -p TERM ) > "$T/traps.txt" 2>&1
ck "E1 sourcing installs NO traps (a library that traps on source hijacks its caller)" \
   $([ ! -s "$T/traps.txt" ] && echo 0 || echo 1)
# E2: a non-repo cwd makes lane.sh refuse at the repo-target gate (72) — the refusal must be RECORDED,
# because a lane that refuses and writes nothing is exactly the population the issue cannot classify.
NOTREPO="$T/not-a-repo"; mkdir -p "$NOTREPO"
( cd "$NOTREPO" && O="$O7" LANE_DRY_RUN=1 REAP_LANE_VENV_DISABLE=1 bash "$HERE/lane.sh" --repo daniel-ospina/agent-infra 5001 feat/5001 ) >/dev/null 2>&1
lr=$?
ck "E2 lane.sh's repo-target REFUSAL is recorded (exit 72, reason=refused:repo-target, rc file 72)" \
   $([ "$lr" = "72" ] && [ "$(reason_of "$O7/logs/lane-5001.log")" = "refused:repo-target" ] \
      && [ "$(cat "$O7/state/lane-5001.rc" 2>/dev/null)" = "72" ] && echo 0 || echo 1)
# E3: the dependency is FAIL-CLOSED — a rig without the library must refuse, never start unrecorded.
RIG="$T/rig-missing"; mkdir -p "$RIG"; cp "$HERE"/*.sh "$RIG/"; rm -f "$RIG/lane-terminal.sh"
( cd "$NOTREPO" && O="$T/o8" LANE_DRY_RUN=1 bash "$RIG/lane.sh" --repo daniel-ospina/agent-infra 5002 feat/5002 ) > "$T/e3.out" 2>&1
e3=$?
ck "E3 a lane.sh without lane-terminal.sh REFUSES (exit 78) and names the missing file" \
   $([ "$e3" = "78" ] && grep -q 'lane-terminal.sh missing' "$T/e3.out" && echo 0 || echo 1)
# E4: the record survives the venv reaper's own block — i.e. lane.sh's cleanup is registered THROUGH the
# library, so installing the record first did not silently delete the #1932 reaper.
( cd "$NOTREPO" && O="$T/o9" LANE_DRY_RUN=1 bash "$HERE/lane.sh" --repo daniel-ospina/agent-infra 5003 feat/5003 ) >/dev/null 2>&1
ck "E4 lane.sh records the run AND keeps its own exit cleanup registered (no clobber in either direction)" \
   $([ "$(rec_lines "$T/o9/logs/lane-5003.log")" = "1" ] && grep -q 'lane_terminal_at_exit' "$HERE/lane.sh" && echo 0 || echo 1)

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[32mALL %d lane-terminal checks passed\033[0m\n' "$pass"
else
  printf '\033[31m%d passed, %d FAILED\033[0m\n' "$pass" "$fail"
fi
[ "$fail" -eq 0 ]
