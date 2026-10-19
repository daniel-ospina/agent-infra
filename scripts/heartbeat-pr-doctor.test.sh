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
# missing / dry-run / a reason carrying `|`.
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
# The block's opening line moved when the DISARMED arm landed (main #2056), so match the FIRST
# conditional of the report and stop at the marker comment that follows it -- never a line number.
awk '/^  if \[ -f "\$STATE\/PR-DOCTOR-OFF" \]; then/,/^  # The SCHEDULED job is a separate component/' \
  "$SRC" | sed '$d' > "$WORK/block.sh"
if [ ! -s "$WORK/block.sh" ]; then
  # the pre-DISARMED shape, so this test keeps working on an older checkout
  awk '/^  if \[ -f "\$STATE\/pr-doctor\.status\.json" \]; then/,/^  # The SCHEDULED job is a separate component/' \
    "$SRC" | sed '$d' > "$WORK/block.sh"
fi
[ -s "$WORK/state_line.sh" ] || { echo "FAIL: no STATE= line in $SRC" >&2; exit 1; }
[ -s "$WORK/block.sh" ] || { echo "FAIL: cannot extract the PR-DOCTOR block from $SRC" >&2; exit 1; }

run_block() {                       # run_block <record-json|-> [dry]
  LOG="$WORK/state/out.log"
  : > "$LOG"
  SCRIPTS="$HERE"
  STERR="$WORK/state/err.log"
  launchctl() { return 0; }         # the cross-check is a macOS-only extra
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
echo "PASS: heartbeat PR-DOCTOR report block (9 states)"
