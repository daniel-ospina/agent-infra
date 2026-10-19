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
# every state the block must distinguish: DISARMED / ok / RED (rc=2,3,5) / stale / unreadable /
# missing / dry-run / a reason carrying `|` / a failing scheduled job / a running one / a healthy
# one / one that recorded no exit code.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/heartbeat-loop.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC" >&2; exit 1; }

WORK="${TMPDIR:-/tmp}/heartbeat-pr-doctor-test.$$"
mkdir -p "$WORK/state" || exit 1
trap 'rm -rf "$WORK"' EXIT

FAIL=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

# ── the two pieces of the real file under test ───────────────────────────────────────────────
# 1. the STATE derivation (the seam), 2. the PR-DOCTOR report block, marker to marker.
grep -E '^STATE=' "$SRC" | tail -1 > "$WORK/state_line.sh"
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
  awk '/^  if \[ -f "\$STATE\/PR-DOCTOR-OFF" \]; then/,/^  rc=0$/' "$SRC" | sed '$d' > "$WORK/block.sh"
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
            "3:UNDELIVERED:2 order(s) no lane accepted" \
            "5:NO-CAPACITY:machine OVER BAND: load 260.0 is at or above MAX_LOAD=250"; do
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
record 3 UNDELIVERED "2 order(s) no lane accepted" 20 0 "$REC"
line="$(run_block)"
case "$line" in
  *"PR-DOCTOR RED rc=3 UNDELIVERED"*) ok "PR_DOCTOR_STATE_DIR is honoured by the reader" ;;
  *) bad "seam line was: $line  (HOME=$HOME has no record; a hardcoded \$HOME reads UNREPORTED)" ;;
esac

if [ "$FAIL" -ne 0 ]; then
  echo "FAILED: $FAIL assertion(s)" >&2
  exit 1
fi
echo "PASS: heartbeat PR-DOCTOR report block (13 states)"
