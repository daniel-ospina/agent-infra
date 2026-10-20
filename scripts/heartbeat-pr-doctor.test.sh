#!/bin/bash
# heartbeat-pr-doctor.test.sh -- the PR-DOCTOR report block in heartbeat-loop.sh, against fixtures.
#
# ⛔ WHY THIS FILE EXISTS (#2055 review). `heartbeat-loop.sh` reads
# `$STATE/pr-doctor.status.json` through a `python3 -c` one-liner and then splits the result in
# bash on `|`. That is a CROSS-LANGUAGE contract: a Python-only test cannot catch a field reorder,
# and `bash -n` only proves the file parses. Until this file existed, the block had NO test at all
# -- and neither did the `PR_DOCTOR_STATE_DIR` seam it reads its record through.
#
# It extracts the block FROM the shipped script (so it tests the real code, not a copy) and drives
# every state the block must distinguish: DISARMED / ok / RED (rc=2,3) / stale / unreadable /
# missing / dry-run / a reason carrying `|` / a failing scheduled job / a running one / a healthy
# one / one that recorded no exit code. (rc=5 NO-CAPACITY is NOT one of them: the exit was DELETED
# with `machine_headroom()`, so a header that listed it sent a reader looking for coverage that
# does not exist -- this file's own count is now DERIVED from the assertions, never a literal.)
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/heartbeat-loop.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC" >&2; exit 1; }

WORK="${TMPDIR:-/tmp}/heartbeat-pr-doctor-test.$$"
mkdir -p "$WORK/state" || exit 1
trap 'rm -rf "$WORK"' EXIT

FAIL=0
CHECKS=0
# ⛔ THE COUNT IS COUNTED, NOT TYPED (#2055 review). A literal in the PASS line went stale against
# the assertions it claims to summarize ("15 states" over 17 `ok` lines), and a reader auditing the
# matrix from that number audits a different matrix than the one that runs.
ok()  { CHECKS=$((CHECKS + 1)); printf '  ok   %s\n' "$1"; }
bad() { CHECKS=$((CHECKS + 1)); printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

# ── the two pieces of the real file under test ───────────────────────────────────────────────
# 1. the STATE derivation (the LAYOUT seam), 2. the RECORD seam, 3. the PR-DOCTOR report
#    block, marker to marker.
# ⛔ BOTH SEAM LINES ARE SOURCED, AND THE FILE ORDER IS THE TEST (#2055 review). The report block
# refers to `$PD_STATE` for every pr-doctor path; a test that sources only `STATE=` leaves `PD_STATE`
# unset, so under `set -u` the shard dies instead of testing anything -- a missing line would look
# like a failing fix rather than the extraction bug it is.
grep -E '^(PI_AGENT_DIR|STATE|PD_STATE)=' "$SRC" | tail -3 > "$WORK/state_line.sh"
# ...plus the seam's CREATOR (#2055 review, issue 3). `pr-doctor.py` makes its own state dirs, but it
# only gets to run if the launcher's redirect succeeds: `>>"$PD_STATE/pr-doctor.log"` into a
# directory that does not exist aborts the whole command (measured: `nohup /bin/echo hi
# >>/nonexistent-dir-xyz/x.log` -> rc=1, nothing executed). `$STATE` is created by the deployment;
# the seam had no creator, so a box that only set the seam never ran a pass at all.
grep -E '^mkdir -p "\$PD_STATE"' "$SRC" >> "$WORK/state_line.sh" || true
# The extraction is ASSERTED, never assumed: a rename that dropped one of the three would make every
# assertion below run against the WRONG root -- the false-green shape this whole file exists for.
for _v in PI_AGENT_DIR STATE PD_STATE; do
  if ! grep -qE "^$_v=" "$WORK/state_line.sh"; then
    echo "FAIL: heartbeat-loop.sh no longer defines $_v= -- the test cannot source the layout" >&2
    exit 1
  fi
done
if ! grep -qE '^mkdir -p "\$PD_STATE"' "$WORK/state_line.sh"; then
  echo "FAIL: heartbeat-loop.sh no longer creates \$PD_STATE -- a seamed box's launcher redirect fails and pr-doctor never runs" >&2
  exit 1
fi
# ⛔ A UNIQUE MARKER PAIR, NEVER A NEARBY CONDITIONAL (#2055 review, cycle 9). The block is the
# report only; the DISPATCH path sits a few lines above it and contains `nohup ... launched
# detached`, so a start pattern that matched a neighbouring `PR-DOCTOR-OFF` test would silently
# widen the capture to that code -- and sourcing it would SPAWN a real pr-doctor while this test
# still printed PASS. Measured: that widening turned a 48-line capture into 88 and all 11
# assertions still passed. The BEGIN/END markers cannot be matched by a neighbour, and the
# invariant below is a second, independent check that the capture is the report.
# The END marker sits BELOW the launchd cross-check, so the capture is the WHOLE report: the
# sidecar verdict and the scheduled job's last-exit status. An end marker above it left that
# printer untested (see the marker's own comment in heartbeat-loop.sh).
BEGIN_MARK='PR-DOCTOR VERDICT REPORT (BEGIN)'
END_MARK='PR-DOCTOR VERDICT REPORT (END)'
awk -v b="$BEGIN_MARK" -v e="$END_MARK" 'index($0,b){f=1} f && index($0,e){exit} f' \
  "$SRC" > "$WORK/block.sh"
if [ ! -s "$WORK/block.sh" ]; then
  # the pre-marker shape (an older checkout), kept so this test still works there
  awk '/^  if \[ ! -f "\$PD_STATE\/PR-DOCTOR-OFF" \]; then/,/^  rc=0$/' "$SRC" | sed '$d' > "$WORK/block.sh"
fi
# comments are stripped first: the invariant is about EXECUTED code, and a comment may say "nohup"
# CAPTURE-then-case, never `grep … | grep -q` — a quiet grep under `pipefail` can read SIGPIPE as a
# non-match (#841/#864, checked by scripts/check-no-sigpipe-grep.sh).
_uncommented="$(grep -v '^ *#' "$WORK/block.sh" || true)"
case "$_uncommented" in
  *nohup*|*pr-doctor.lock*|*'launched detached'*)
    echo "FAIL: extracted the DISPATCH block, not the PR-DOCTOR report block" >&2
    exit 1
    ;;
esac
[ -s "$WORK/block.sh" ] || { echo "FAIL: cannot extract the PR-DOCTOR block from $SRC" >&2; exit 1; }

run_block() {                       # run_block <record-json|-> [dry]
  LOG="$WORK/state/out.log"
  : > "$LOG"
  SCRIPTS="$HERE"
  STERR="$WORK/state/err.log"
  # the scheduled-job cross-check reads `launchctl list`; a case may set LAUNCHCTL_OUT to drive it
  launchctl() { printf '%s\n' "${LAUNCHCTL_OUT:-}"; }
  # shellcheck disable=SC1090
  . "$WORK/state_line.sh"
  # shellcheck disable=SC1090
  . "$WORK/block.sh"
  cat "$LOG"                      # the MISSING-record message is two lines on purpose
}

record() { /usr/bin/python3 - "$@" <<'PY'
import json, sys, time
rc = int(sys.argv[1])
json.dump({"rc": rc, "kind": sys.argv[2], "reason": sys.argv[3],
           "at": "2026-10-18T22:00:00Z", "at_epoch": time.time() - float(sys.argv[4]),
           "dry_run": sys.argv[5] == "1"},
          open(sys.argv[6], "w"))
PY
}

REC="$WORK/state/pr-doctor.status.json"
export PR_DOCTOR_STATE_DIR="$WORK/state"
export HOME="$WORK/fakehome"        # so a reverted seam has NO record to find
mkdir -p "$HOME"

# ── 0. DISARMED is a named state, not RED ───────────────────────────────────────────────────────
touch "$WORK/state/PR-DOCTOR-OFF"
line="$(run_block)"
rm -f "$WORK/state/PR-DOCTOR-OFF"
case "$line" in
  *"PR-DOCTOR DISARMED"*) ok "the operator stop marker renders DISARMED, not RED" ;;
  *) bad "disarmed line was: $line" ;;
esac

# ── 1. ok ────────────────────────────────────────────────────────────────────────────────────
record 0 OK "dispatched 1 of 1 queued (3 open PR(s)) — ok" 120 0 "$REC"
line="$(run_block)"
case "$line" in
  *"PR-DOCTOR ok rc=0"*"dispatched 1 of 1 queued"*) ok "rc=0 renders ok with the reason" ;;
  *) bad "rc=0 line was: $line" ;;
esac

# ── 2. each RED kind, distinguishable ────────────────────────────────────────────────────────
for spec in "2:UNREADABLE:queue UNREADABLE: the open-PR read FAILED (rc=1 rate limited)" \
            "3:UNDELIVERED:2 order(s) no worker accepted"; do
  rc="${spec%%:*}"; rest="${spec#*:}"; kind="${rest%%:*}"; why="${rest#*:}"
  record "$rc" "$kind" "$why" 60 0 "$REC"
  line="$(run_block)"
  case "$line" in
    *"PR-DOCTOR RED rc=$rc $kind"*"$why"*) ok "rc=$rc $kind renders RED with its own reason" ;;
    *) bad "rc=$rc line was: $line" ;;
  esac
done

# ── 3. a stale verdict must NOT print ok ─────────────────────────────────────────────────────
record 0 OK "dispatched 0 of 0 queued (2 open PR(s)) — nothing to do" 3000 0 "$REC"
line="$(run_block)"
case "$line" in
  *"RED UNREPORTED (verdict is STALE"*) ok "a stale rc=0 is RED UNREPORTED, never ok" ;;
  *) bad "stale line was: $line" ;;
esac

# ── 4. a dry run is not a pass verdict ───────────────────────────────────────────────────────
record 0 OK "dry run: would dispatch 1" 10 1 "$REC"
line="$(run_block)"
case "$line" in
  *"DRY RUN (not a pass verdict"*) ok "a dry-run record is labelled, not counted" ;;
  *) bad "dry-run line was: $line" ;;
esac

# ── 5. an unreadable record is RED, not silence ──────────────────────────────────────────────
printf 'not json' > "$REC"
line="$(run_block)"
case "$line" in
  *"RED UNREPORTED"*"UNREADABLE"*) ok "an unparseable record is RED UNREPORTED" ;;
  *) bad "unreadable line was: $line" ;;
esac

# ── 6. a MISSING record is UNREPORTED, not a clean pass ──────────────────────────────────────
rm -f "$REC"
line="$(run_block)"
case "$line" in
  *"PR-DOCTOR UNREPORTED"*"no status record"*) ok "a missing record is UNREPORTED" ;;
  *) bad "missing line was: $line" ;;
esac

# ── 7. the reason survives a `|` in it (the field separator) ─────────────────────────────────
record 2 UNREADABLE "queue UNREADABLE: a|b|c" 30 0 "$REC"
line="$(run_block)"
case "$line" in
  *"a|b|c"*) ok "a reason containing | survives the record split" ;;
  *) bad "pipe-reason line was: $line" ;;
esac

# ── 7b. the SCHEDULED job's last exit is a second, independent RED ─────────────────────────────
# ⛔ HALF THE REPORT (#2055 review, cycle 10). The block prints the sidecar verdict AND the launchd
# job's last-exit status, because the dispatcher has two launchers that fail independently -- "the
# scheduler is dead" must not hide behind "the heartbeat is alive", or the reverse. An end marker
# placed above this printer left it untested: replacing its printf with `:` kept the suite green.
LAUNCHCTL_OUT='-	1	com.tortoise.pr-doctor'
record 0 OK "dispatched 1 of 1 queued (3 open PR(s)) — ok" 30 0 "$REC"
line="$(run_block)"
case "$line" in
  *"PR-DOCTOR LAUNCHD RED (last exit 1)"*) ok "a failing scheduled job prints its own RED" ;;
  *) bad "launchd-red line was: $line" ;;
esac

# a RUNNING job's status column is the PREVIOUS run, so it is not a verdict yet -- no line. The
# fixture carries a NON-ZERO previous status on purpose: with `0` there, the `!= "0"` guard would
# suppress the line and the `_plpid = "-"` guard (the one this case is about) would go untested.
LAUNCHCTL_OUT='4321	1	com.tortoise.pr-doctor'
line="$(run_block)"
case "$line" in
  *LAUNCHD*) bad "a running job must not print LAUNCHD RED: $line" ;;
  *) ok "a running scheduled job is not a verdict" ;;
esac
# the two STATUS-COLUMN suppressions: a healthy last exit, and no recorded code at all. The second
# is a regression that already happened once (the source comment at heartbeat-loop.sh records it),
# and both were unpinned until this case existed -- the suite then pinned when a line must appear
# and the pid guard, but not the guards that keep a false RED off a healthy box.
LAUNCHCTL_OUT='-	0	com.tortoise.pr-doctor'
line="$(run_block)"
case "$line" in
  *LAUNCHD*) bad "a healthy scheduled job must not print LAUNCHD RED: $line" ;;
  *) ok "a healthy scheduled job prints no LAUNCHD line" ;;
esac

LAUNCHCTL_OUT='-	-	com.tortoise.pr-doctor'      # `-` = not running, NO last-exit code recorded
line="$(run_block)"
case "$line" in
  *LAUNCHD*) bad "a missing last-exit code must not print LAUNCHD RED: $line" ;;
  *) ok "a missing last-exit code is not a RED" ;;
esac
unset LAUNCHCTL_OUT

# ── 8. the state-dir SEAM: the record is found through PR_DOCTOR_STATE_DIR, not $HOME ────────
record 3 UNDELIVERED "2 order(s) no worker accepted" 20 0 "$REC"
line="$(run_block)"
case "$line" in
  *"PR-DOCTOR RED rc=3 UNDELIVERED"*) ok "PR_DOCTOR_STATE_DIR is honoured by the reader" ;;
  *) bad "seam line was: $line  (HOME=$HOME has no record; a hardcoded \$HOME reads UNREPORTED)" ;;
esac

# ── 8b. ⛔ THE SEAM MOVES THE RECORD ONLY, NOT THE LOOP'S STATE ROOT ──────────────────────────
# A previous revision bound `STATE` ITSELF to `PR_DOCTOR_STATE_DIR`. `$STATE` here is the heartbeat's
# whole world -- `HEARTBEAT-OFF` (the operator stop switch the LIFECYCLE header documents at its
# literal `$HOME` path), the pidfile singleton guard, `lane-status.last.json` and the
# `queues/refresh-queues.py` program path -- and every one of those is produced or read by a SIBLING
# that hardcodes `$HOME/.pi/agent/state`. Relocating them made the documented stop switch stop
# stopping, silently, on a box that merely honoured the record seam. This asserts the two roots are
# INDEPENDENT: with the record seam set, `$STATE` must still be the layout root.
_seam_state="$(set -u; . "$WORK/state_line.sh"; printf '%s' "$STATE")"
_seam_pd="$(set -u; . "$WORK/state_line.sh"; printf '%s' "$PD_STATE")"
if [ "$_seam_state" = "$HOME/.pi/agent/state" ] && [ "$_seam_pd" = "$WORK/state" ]; then
  ok "the record seam moves \$PD_STATE only -- \$STATE (kill switch, pidfile, snapshot) is untouched"
else
  bad "seam split is wrong: STATE=$_seam_state (want $HOME/.pi/agent/state), PD_STATE=$_seam_pd (want $WORK/state) -- a relocated STATE moves HEARTBEAT-OFF, the pidfile and the lane snapshot with it"
fi

# ── 9. the LAUNCHER arm reads the marker through the seam too ─────────────────────────────────
# ⛔ MEASURED GAP (#2055 review): reverting `if [ ! -f "$PD_STATE/PR-DOCTOR-OFF" ]` to `$STATE` left
# this shard FULLY GREEN, because the report block above only reads the RECORD -- the launcher is a
# different `if`, a few lines above the BEGIN marker, and no case touched it. The consequence of that
# revert is the silent one: the beat prints DISARMED from the seam while the launcher keeps spawning
# pr-doctor, i.e. the operator's stop switch stops stopping.
# The expression is EVALUATED AS SHIPPED (extracted from the file, then `eval`ed against two real
# directories), so this is a behavioural pin of the guard, not a grep for a variable name.
_launch_if="$(grep -nE '^  if \[ ! -f "\$(PD_STATE|STATE)/PR-DOCTOR-OFF" \]; then$' "$SRC")"
if [ -z "$_launch_if" ]; then
  bad "the launcher's PR-DOCTOR-OFF guard was not found -- the extraction below is stale"
else
  # the extracted line is `<n>:  if <cond>; then` -> the condition alone
  _cond="$(printf '%s' "${_launch_if#*:}" | sed -e 's/^ *if //' -e 's/; then$//')"
  _other="$WORK/launcher-state"
  mkdir -p "$_other"
  touch "$WORK/state/PR-DOCTOR-OFF"          # the marker sits in the RECORD dir (the seam)
  # `$STATE` here is the layout root (case 8b proved it is NOT the seam); PD_STATE is the record dir.
  ( set -u; . "$WORK/state_line.sh"; eval "$_cond" ) \
    && bad "a marker in the RECORD dir did NOT disarm the launcher: the guard reads \$STATE, not \$PD_STATE ($_cond)" \
    || ok "the launcher's guard evaluates the RECORD dir: a marker there disarms the spawn"
  rm -f "$WORK/state/PR-DOCTOR-OFF"
  # ...and the converse: with the marker ONLY in the layout root, the launcher must still spawn, or
  # the seam silently invented a stop switch the operator cannot see.
  mkdir -p "$WORK/fakehome/.pi/agent/state"
  touch "$WORK/fakehome/.pi/agent/state/PR-DOCTOR-OFF"
  ( set -u; . "$WORK/state_line.sh"; eval "$_cond" ) \
    && ok "a marker outside the record dir does not disarm a seamed launcher" \
    || bad "the launcher was disarmed by a marker it does not read ($_cond)"
  rm -f "$WORK/fakehome/.pi/agent/state/PR-DOCTOR-OFF"
fi

# ── 10. ⛔ THE SEAM HAS NO CREATOR WITHOUT THIS LINE (issue 3, MEASURED) ────────────────────────
# The launcher arm writes its child's stdout through the seam:
#     nohup /usr/bin/python3 "$SCRIPTS/pr-doctor.py" >>"$PD_STATE/pr-doctor.log" …
# and a shell redirect into a directory that does not exist aborts the COMMAND, not just the log
# (measured: `nohup /bin/echo hi >>/nonexistent-dir-xyz/x.log` -> rc=1, nothing executed). `$STATE`
# is created by the deployment; `$PR_DOCTOR_STATE_DIR` is created by NOBODY unless the loop does it,
# and docs/ops/load-policy.md §10.1 tells cells to set it. On such a box the pass never runs, no
# record is ever written, and every beat prints UNREPORTED pointing at a log that cannot exist --
# permanently, with no self-healing on a later pass.
# The assertion is BEHAVIOURAL: the extracted line is SOURCED against a fresh, non-existent seam dir,
# and the same redirect the launcher uses must then succeed.
_fresh="$WORK/seam-not-yet-created/pr-doctor"
rm -rf "$WORK/seam-not-yet-created"
_got="$( set -u; PR_DOCTOR_STATE_DIR="$_fresh"; export PR_DOCTOR_STATE_DIR; \
         . "$WORK/state_line.sh" >/dev/null 2>&1; printf '%s' "$PD_STATE" )"
if [ "$_got" = "$_fresh" ] && [ -d "$_fresh" ] && printf 'probe\n' >>"$_fresh/pr-doctor.log" 2>/dev/null; then
  ok "the seam CREATES its directory: the launcher's redirect into a fresh seamed dir succeeds"
else
  bad "PR_DOCTOR_STATE_DIR=$_fresh was not created by the launcher arm (PD_STATE='$_got', dir exists: $([ -d "$_fresh" ] && echo yes || echo no)) -- the nohup redirect fails and pr-doctor NEVER runs"
fi

if [ "$FAIL" -ne 0 ]; then
  echo "FAILED: $FAIL of $CHECKS assertion(s)" >&2
  exit 1
fi
echo "PASS: heartbeat PR-DOCTOR report block ($CHECKS states, $FAIL failed)"
