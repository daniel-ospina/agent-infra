#!/bin/bash
# tests/beat-pair/run.sh — #7957 H3 regression suite for the recap/beat pair binding.
#
# THE DEFECT (why this exists)
# ----------------------------
#   `lane-actions.py` publishes TWO files: state/NEEDS-ACTION.md (the recap a human reads) and
#   state/NEEDS-ACTION.beat (the one-line sidecar cadence-nudge.sh actually reads and publishes).
#   They are two INDEPENDENT atomic writes, and the recap is written FIRST. So a failure between them
#   left a FRESH recap beside a STALE beat — and the beat write only warned and fell through to
#   `return 0`, so the tick reported success. The floor then published the PREVIOUS tick's action
#   list as THIS tick's: two numbers, one tick, and nothing on the line to say so. The sidecar's own
#   mtime cannot detect this — it is only ever the mtime of the last SUCCESSFUL beat write.
#
#   state/NEEDS-ACTION.README.md already promised the opposite ("With no fresh sidecar, or on any
#   classifier failure, the previous sidecar stands and the beat is as before"). The code did not
#   keep it.
#
# THE DESIGN THIS SUITE PINS
#   The beat carries `md=<sha256(recap)[:12]>` — the digest of the recap it was rendered from — and
#   `write_pair` returns non-zero (4, never 0) when the recap published but the beat did not.
#   `beat_pair_ok` compares the two, and every reader must call it before publishing the clause.
#   ABSENCE IS NOT A PASS: a beat with no `md=` cannot be verified, so it is suppressed. Suppressing
#   reuses the readers' OWN degradation (`actfull=0` leaves the older mechanical/Jev clauses
#   standing, exactly as a Jev outage does), so a torn pair falls back to the previous beat rather
#   than publishing a count that describes a different state.
#
# WHAT THIS SUITE PINS
# --------------------
#   0. WIRING IS REAL — the rule is sourced from scripts/lib/beat-pair.sh and the definitions are
#      present; if they are not, the suite exits RED rather than silently testing nothing.
#   1. AGREEING pair    -> rc 0 (the clause may be published).
#   2. `md=` ABSENT     -> rc 1 (legacy beat: unverifiable, so suppressed).
#   3. `md=` MISMATCHED -> rc 1 (the torn pair — the defect this file exists for).
#   4. RECAP MISSING    -> rc 1 (nothing to verify against => suppressed).
#   5. DIGEST AGREEMENT -> `_mdsha` equals an independently computed sha256[:12]. This guards the CUT
#      WIDTH: a digest that is self-consistent but the wrong width agrees with itself and never with
#      the writer, so every beat reads as "torn" and the clause vanishes silently. A guard that fails
#      closed by refusing everything looks IDENTICAL to a guard that works — until you notice the
#      clause is never published. That is why the width is pinned against an independent digest.
#   6. THE FLOOR, DRIVEN END TO END — `cadence-nudge.sh` is run for real with its own `NUDGE_DRY=1`
#      seam (it prints the message and sends nothing), and the clause is asserted present on a
#      verified pair and ABSENT on a torn one, on a `md=`-less one, and with the helper UNDEPLOYED.
#      This section exists because a text grep for the wiring is not a test of the wiring: a guard
#      rewritten to `if ! beat_pair_ok …` STILL matches those strings and stayed green. Only running
#      the floor can tell a correct guard from an inverted one.
#   7. THE SUPPRESSION IS RECORDED — the driver is `cadence-timer.sh`, which runs the nudge as
#      `( … ) >/dev/null 2>&1 &`, so a suppressed clause that is only reported on stderr is INVISIBLE.
#      A permanent suppression must leave something in the log. (It did not before this review, which
#      is how a guard file missing from the farm shipped green.)
#
#   8. THE SECOND READER — `heartbeat-loop.sh` makes the same ONE call, and the shared call refuses
#      a torn pair at the function level (behaviourally, not by grep).
#
# Run: bash tests/beat-pair/run.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
NUDGE="$ROOT/scripts/cadence-nudge.sh"
PAIR_LIB="$ROOT/scripts/lib/beat-pair.sh"

checks=0; failures=0
pass(){ checks=$((checks + 1)); echo "  ok   $1"; }
fail(){ checks=$((checks + 1)); failures=$((failures + 1)); echo "  FAIL $1"; }
# ⛔ A SUBSTRING TEST THAT IS NOT THE SIGPIPE IDIOM. This file cites
# `scripts/check-no-sigpipe-grep.sh` (#841) two lines below, so it must not use `printf … | grep -q`
# itself. `tests/` is not in that guard's scan path, so the idiom would be latent rather than
# caught -- and the direction matters here: on a WITHHOLDING assertion a fired SIGPIPE race would
# take the `else` branch and report PASS. A `case` glob has no upstream writer to race with.
has(){ case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "0. the definitions under test are the SHIPPED ones"
if [ ! -f "$NUDGE" ] || [ ! -f "$PAIR_LIB" ]; then
  echo "❌ beat-pair suite: $NUDGE or $PAIR_LIB not found"; exit 1
fi
# shellcheck source=/dev/null
. "$PAIR_LIB"
if declare -F beat_pair_ok >/dev/null && declare -F _mdsha >/dev/null; then
  pass "sourced _mdsha + beat_pair_ok from scripts/lib/beat-pair.sh"
else
  fail "scripts/lib/beat-pair.sh did not define beat_pair_ok/_mdsha — the suite would be VACUOUS"
  echo "❌ beat-pair suite: definitions missing"; exit 1
fi
# The source line must be in EXECUTABLE position, not merely present in the file (a mutation that
# comments it out, or deletes the file, must not read as wired). COMMENTS ARE STRIPPED FIRST and the
# count is taken with `grep -c`, not `| grep -q`: a `-q` reader exits on the first match, which is the
# SIGPIPE idiom this repo bans outright (`scripts/check-no-sigpipe-grep.sh`, #841) — and `-c` also
# means an unrelated trailing comment cannot satisfy the check.
_src_hits="$(sed 's/#.*//' "$NUDGE" | grep -c '\$SCRIPTS/lib/beat-pair\.sh' || true)"
if [ "${_src_hits:-0}" -ge 1 ]; then
  pass "cadence-nudge.sh sources scripts/lib/beat-pair.sh in executable position (not in a comment)"
else
  fail "cadence-nudge.sh's scripts/lib/beat-pair.sh source line is absent or commented out"
fi

# mkpair <state-dir> <recap-text> <md-key: auto|OMIT|LITERAL> [<write-recap: yes|no>]
# `auto` computes the digest AFTER writing the recap, so the pair is genuinely self-consistent.
mkpair(){
  local d="$1" recap="$2" mdkey="$3" wr="${4:-yes}"
  mkdir -p "$d"
  [ "$wr" = yes ] && printf '%s' "$recap" > "$d/NEEDS-ACTION.md"
  [ "$mdkey" = auto ] && mdkey="$(_mdsha "$d/NEEDS-ACTION.md")"
  if [ "$mdkey" = OMIT ]; then
    printf 'act=DO: X\nactfull=1\n' > "$d/NEEDS-ACTION.beat"
  else
    printf 'act=DO: X\nactfull=1\nmd=%s\n' "$mdkey" > "$d/NEEDS-ACTION.beat"
  fi
}

echo ""
echo "1. the digest agrees with the recap on disk -> publishable"
d="$TMP/agree"; mkpair "$d" "# recap" auto
if beat_pair_ok "$d" 2>/dev/null; then
  pass "an agreeing pair returns 0"
else
  fail "an agreeing pair must return 0 (the clause would never publish)"
fi

echo ""
echo "2. md= ABSENT — a beat written before the binding existed"
d="$TMP/nomd"; mkpair "$d" "# recap" OMIT
if beat_pair_ok "$d" 2>/dev/null; then
  fail "a beat with NO md= must NOT pass (absence is not a pass)"
else
  pass "a beat with no md= returns 1 (unverifiable, suppressed)"
fi

echo ""
echo "3. md= MISMATCHED — the torn pair"
d="$TMP/torn"; mkpair "$d" "# recap" "deadbeefdead"
if beat_pair_ok "$d" 2>/dev/null; then
  fail "a torn pair must NOT pass — this is the defect the suite exists for"
else
  pass "a torn pair returns 1 (the beat describes a different recap)"
fi

echo ""
echo "4. the RECAP is missing (the beat outlived the file it describes)"
d="$TMP/norecap"; mkpair "$d" "# recap" "deadbeefdead" no
if beat_pair_ok "$d" 2>/dev/null; then
  fail "a missing recap must NOT pass"
else
  pass "a missing recap returns 1 (nothing to verify against)"
fi

echo ""
echo "5. _mdsha width — a self-consistent but wrongly-cut digest suppresses EVERYTHING"
printf 'abc' > "$TMP/w.txt"
got="$(_mdsha "$TMP/w.txt")"
want="$(/usr/bin/python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest()[:12])' "$TMP/w.txt")"
if [ -n "$got" ] && [ "$got" = "$want" ]; then
  pass "_mdsha('abc') == sha256('abc')[:12] == $want"
else
  fail "_mdsha gave '$got', independently computed '$want' — writer and reader would NEVER agree"
fi

echo ""
echo "6. the FLOOR, driven end to end (NUDGE_DRY=1: prints the message, sends nothing)"
# ── the sandbox ──────────────────────────────────────────────────────────────────────────────────
# `cadence-nudge.sh` resolves the orchestrator pane by GREPPING the tick, and reads its "is a nudge
# due?" answer from the log -- so the sandbox supplies the same shapes it greps for, and nothing else.
TAG="ACTCLAUSEPRESENT"
floor_home(){ # floor_home <dir> <recap> <md-key> [<copy-lib: yes|no>]
  # ⛔ THE SANDBOX MIRRORS THE REAL LAYOUT, NOT A CONVENIENT ONE. The floor derives its paths from
  # `$HOME` (`SCRIPTS="$HOME/.pi/agent/scripts"`, `STATE="$HOME/.pi/agent/state"`), so the stub
  # tick, the lib, the log, the recap and the pair all have to sit under `$h/.pi/agent/…`. A sandbox
  # that puts them at `$h/scripts` + `$h/state` looks right and tests NOTHING: the floor finds no log,
  # cannot parse a previous nudge and exits before it builds a message at all.
  local h="$1" recap="$2" mdkey="$3" copy_lib="${4:-yes}"
  mkdir -p "$h/.pi/agent/state" "$h/.pi/agent/scripts/lib"
  [ "$copy_lib" = yes ] && cp "$PAIR_LIB" "$h/.pi/agent/scripts/lib/beat-pair.sh"
  printf 'ORCH_WS="WS-TEST"\nORCH_SURFACE="SURF-TEST"\n' > "$h/.pi/agent/scripts/orchestrator-heartbeat.sh"
  printf 'NUDGE at=1000000000 delivered=yes (cadence-floor) gap=1m queue=[] alerts=[] ask=[]\n' \
    > "$h/.pi/agent/state/orchestrator-heartbeat.log"
  # ⛔ THE RECAP MUST EXIST, OR THE FLOOR FALLS BACK (MEASURED by mutation, 2026-10-17). The floor
  # reads the beat only INSIDE `if [ -f "$STATE/lane-recap.last" ]`; without this file it still SENDS
  # -- a degraded message with no act clause -- so a sandbox that omits it cannot distinguish "clause
  # withheld" from "clause never built", and the withholding assertions below would be misleading.
  # The non-empty-message guard in 6a catches a DIFFERENT early exit: the one this sandbox actually
  # had, where the floor found no log (wrong `$HOME` layout) and exited before building any message.
  # Both guards are needed, and neither is decoration -- dropping this file was measured to redden the
  # suite (2 failures), and the wrong layout was measured to redden it 5 times over.
  printf 'fleet=f1 | lane-x(3m)\nbusy=none\n' > "$h/.pi/agent/state/lane-recap.last"
  mkpair "$h/.pi/agent/state" "$recap" "$mdkey"
}
# ⛔ The nested invocation uses a LITERAL relative path after `cd` into the WORKTREE, deliberately: a
# `bash "$VAR/…"` command-position script path is refused by the script-indirection gate
# (#1228/#1893), and a literal relative path is both statically visible to that gate and exactly as
# faithful here. It `cd`s to the WORKTREE, not to the sandbox -- the sandbox only supplies `$HOME`
# (`SCRIPTS`/`STATE`), and it carries no copy of the floor.
# stderr goes to a FILE in the sandbox, never to /dev/null: the driver discards stderr in production,
# but a suite that also discards it cannot tell "the floor withheld the clause" from "the floor died"
# -- and can only report a bare empty string, which is what this section did before the fix.
floor_run(){ ( cd "$ROOT" && HOME="$1" NUDGE_DRY=1 bash scripts/cadence-nudge.sh 2>"$1/floor.err" ); }
floor_err(){ tr '\n' ' ' < "$1/floor.err" 2>/dev/null | cut -c1-200; }
seeded_beat(){ # seeded_beat <dir> <md-value>
  printf 'act=%s\nactfull=1\nmd=%s\n' "$TAG" "$2" > "$1/.pi/agent/state/NEEDS-ACTION.beat"
}

# 6a. a VERIFIED pair is delivered — AND the floor produced a message at all. The second half is what
#     makes 6b/6c/6d mean anything: an empty message "withholds" every clause trivially.
h="$TMP/good"; floor_home "$h" "# recap" auto
seeded_beat "$h" "$(_mdsha "$h/.pi/agent/state/NEEDS-ACTION.md")"
out="$(floor_run "$h")"
if [ -z "$out" ]; then
  fail "the floor produced NO message on a healthy pair -- it exited before sending, so every withholding assertion below would be VACUOUS (stderr: $(floor_err "$h"))"
elif has "$out" "$TAG"; then
  pass "a VERIFIED pair is DELIVERED (the act clause reaches the message)"
else
  fail "a verified pair was NOT delivered — the floor lost the clause on a healthy pair (got: ${out:0:200})"
fi

# 6b. a TORN pair is withheld, and the withholding is RECORDED
h="$TMP/torn2"; floor_home "$h" "# recap" auto
seeded_beat "$h" "deadbeefdead"
out="$(floor_run "$h")"
if [ -z "$out" ]; then
  fail "the floor produced NO message on the torn case — a silently-exiting floor cannot demonstrate withholding (stderr: $(floor_err "$h"))"
elif has "$out" "$TAG"; then
  fail "a TORN pair was DELIVERED — the previous tick's clause was published as current"
else
  pass "a TORN pair is WITHHELD (the clause never reaches the message)"
fi
if grep -q 'NUDGE-SUPPRESSED' "$h/.pi/agent/state/orchestrator-heartbeat.log" 2>/dev/null; then
  pass "...and the suppression is RECORDED in the log (the driver discards stderr)"
else
  fail "...the suppression is SILENT — nothing in the log says the clause was withheld"
fi

# 6c. an unverifiable (md=-less) beat is withheld end to end
h="$TMP/nomd2"; floor_home "$h" "# recap" OMIT
out="$(floor_run "$h")"
if [ -z "$out" ]; then
  fail "the floor produced NO message on the md=-less case (stderr: $(floor_err "$h"))"
elif has "$out" "$TAG"; then
  fail "a beat with NO md= was delivered end to end (absence read as a pass)"
else
  pass "a beat with NO md= is WITHHELD end to end (absence is not a pass)"
fi

# 6d. the helper UNDEPLOYED => withheld, and the floor still RUNS (partial deploy cannot assert).
#     Built by simply NOT copying the helper: a discard verb (`rm`) with an unresolvable target is
#     exactly the shape the script-execution gate refuses, and the sandbox does not need one.
h="$TMP/nolib"; floor_home "$h" "# recap" auto no
seeded_beat "$h" "$(_mdsha "$h/.pi/agent/state/NEEDS-ACTION.md")"
out="$(floor_run "$h")"
if [ -z "$out" ]; then
  fail "the floor produced NO message with the helper ABSENT — a missing lib must not stop the floor (stderr: $(floor_err "$h"))"
elif has "$out" "$TAG"; then
  fail "the clause was delivered with the helper ABSENT (an unverifiable pair was published)"
else
  pass "the helper absent => WITHHELD, and the floor still produced a message"
fi

echo ""
# 7. THE FARM. It is the LIB farm, not the flat fleet farm: the two readers resolve the rule as
#    `$(dirname "${BASH_SOURCE[0]}")/lib/beat-pair.sh`, and the lib farm installs atomically so a
#    concurrent reader can never observe a truncated lib (#1362). Checking `fleet_srcs` instead would
#    pass on a farm that puts the file where NO reader looks — the exact #1552 class.
echo "7. the LIB FARM delivers the rule both readers source (#1897)"
SETUP="$ROOT/pi-bootstrap/setup.sh"
if [ -f "$SETUP" ]; then
  _lib_hits="$(sed -n 's/^lib_srcs=(\(.*\))$/\1/p' "$SETUP" | tr -s ' ' '\n' | grep -cx 'beat-pair.sh' || true)"
  if [ "${_lib_hits:-0}" -ge 1 ]; then
    pass "beat-pair.sh is in pi-bootstrap/setup.sh's lib_srcs (both readers resolve it under scripts/lib/)"
  else
    fail "beat-pair.sh is NOT in the lib farm — on a rebuilt box the floor would suppress the clause FOREVER"
  fi
else
  fail "$SETUP not found — cannot verify the farm"
fi

echo ""
# 8. THE SECOND READER, AND THE SHARED CALL IT MUST USE (#1897 review, P2).
#    `heartbeat-loop.sh` LOGS the clause rather than publishing it, and its guard used to be a
#    hand-rolled "verify, then read" -- invertible, and untested, because section 6 drives only the
#    floor. Both readers now make ONE call into the lib, so the invertible form does not exist; the
#    behavioural assertions below prove that call actually refuses.
echo "8. the second reader, and the one shared call both readers make (#1897 review)"
mkdir -p "$TMP/bcv"
mkpair "$TMP/bcv" "# recap" auto
out="$(beat_clause_verified "$TMP/bcv" 420)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "DO: X" ]; then
  pass "beat_clause_verified RETURNS the clause on a verified pair (rc 0)"
else
  fail "beat_clause_verified gave rc=$rc out='$out' on a VERIFIED pair (expected rc=0, 'DO: X')"
fi
printf 'changed after the beat was written' > "$TMP/bcv/NEEDS-ACTION.md"
out="$(beat_clause_verified "$TMP/bcv" 420)"; rc=$?
if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
  pass "...and returns NOTHING with rc != 0 on a TORN pair (the guard cannot be bypassed by a caller)"
else
  fail "beat_clause_verified published '$out' (rc=$rc) on a TORN pair — a reader could store a stale clause"
fi
HB="$ROOT/scripts/heartbeat-loop.sh"
if [ ! -f "$HB" ]; then
  fail "scripts/heartbeat-loop.sh not found — the second reader is unpinned"
else
  hb_n="$(sed 's/#.*//' "$HB" | grep -c 'beat_clause_verified' || true)"
  if [ "${hb_n:-0}" -ge 1 ]; then
    pass "heartbeat-loop.sh CALLS beat_clause_verified (not a hand-rolled verify-then-read)"
  else
    fail "heartbeat-loop.sh does not call beat_clause_verified — its guard is hand-rolled and invertible, and nothing else exercises it"
  fi
  hb_priv="$(sed 's/#.*//' "$HB" | grep -c 's/\^act=//p' || true)"
  if [ "${hb_priv:-0}" -eq 0 ]; then
    pass "...and it has no PRIVATE read of act= (the shared call is the only path to the clause)"
  else
    fail "heartbeat-loop.sh reads the beat with its own sed — that read bypasses the shared guard"
  fi
fi

echo ""
if [ "$failures" -eq 0 ]; then
  echo "✅ beat-pair suite passed (${checks} assertions)"
  exit 0
fi
echo "❌ beat-pair suite: $failures of $checks assertion(s) failed"
exit 1
