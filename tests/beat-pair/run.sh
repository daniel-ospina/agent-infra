#!/bin/bash
# tests/beat-pair/run.sh — #7957 H3 regression suite for the recap/beat pair binding.
#
# THE DEFECT (why this exists)
# ----------------------------
#   `lane-actions.py` publishes TWO files: state/NEEDS-ACTION.md (the recap a human reads) and
#   state/NEEDS-ACTION.beat (the one-line sidecar cadence-nudge.sh actually reads). They are two
#   INDEPENDENT atomic writes, and the recap is written FIRST. So a failure between them left a
#   FRESH recap beside a STALE beat — and the beat write only warned and fell through to
#   `return 0`, so the tick reported success. The floor then published the PREVIOUS tick's action
#   list as THIS tick's: two numbers, one tick, and nothing on the line to say so. The sidecar's
#   own mtime cannot detect this — it is only ever the mtime of the last SUCCESSFUL beat write.
#
#   state/NEEDS-ACTION.README.md already promised the opposite ("With no fresh sidecar, or on any
#   classifier failure, the previous sidecar stands and the beat is as before"). The code did not
#   keep it.
#
# THE DESIGN THIS SUITE PINS
#   The beat carries `md=<sha256(recap)[:12]>` — the digest of the recap it was rendered from —
#   and `write_pair` returns non-zero (4, never 0) when the recap published but the beat did not.
#   `beat_pair_ok` compares the two, and cadence-nudge.sh publishes the act clause ONLY when they
#   agree. ABSENCE IS NOT A PASS: a beat with no `md=` cannot be verified, so it is suppressed.
#   Suppressing reuses that file's OWN degradation (`actfull=0` leaves the older mechanical/Jev
#   clauses standing, exactly as a Jev outage does), so a torn pair falls back to the previous
#   beat rather than publishing a count that describes a different state.
#
# WHAT THIS SUITE PINS
# --------------------
#   0. WIRING IS REAL — the rule is sourced from scripts/beat-pair.sh, the SAME file
#      cadence-nudge.sh sources, and the suite asserts that the floor really sources it. A guard
#      that exists but is not wired in is not a guard, so this is asserted rather than assumed.
#      If the definitions are absent the suite exits RED rather than silently testing nothing.
#   1. AGREEING pair    -> rc 0 (the clause may be published).
#   2. `md=` ABSENT     -> rc 1 (legacy beat: unverifiable, so suppressed).
#   3. `md=` MISMATCHED -> rc 1 (the torn pair — the defect this file exists for).
#   4. RECAP MISSING    -> rc 1 (nothing to verify against => suppressed).
#   5. DIGEST AGREEMENT -> `_mdsha` equals an independently computed sha256[:12]. This guards the
#      CUT WIDTH: a digest that is self-consistent but the wrong width would agree with itself and
#      never with the writer, so every beat would read as "torn" and the clause would vanish
#      silently — a guard that fails closed by refusing everything looks identical to a guard that
#      works, until you notice the clause is never published.
#
# Run: bash tests/beat-pair/run.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
NUDGE="$ROOT/scripts/cadence-nudge.sh"
PAIR_LIB="$ROOT/scripts/beat-pair.sh"

checks=0; failures=0
pass(){ checks=$((checks + 1)); echo "  ok   $1"; }
fail(){ checks=$((checks + 1)); failures=$((failures + 1)); echo "  FAIL $1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "0. the definitions under test are the SHIPPED ones, and the floor actually sources them"
if [ ! -f "$NUDGE" ] || [ ! -f "$PAIR_LIB" ]; then
  echo "❌ beat-pair suite: $NUDGE or $PAIR_LIB not found"; exit 1
fi
. "$PAIR_LIB"
if declare -F beat_pair_ok >/dev/null && declare -F _mdsha >/dev/null; then
  pass "sourced _mdsha + beat_pair_ok from scripts/beat-pair.sh"
else
  fail "scripts/beat-pair.sh did not define beat_pair_ok/_mdsha — the suite would be VACUOUS"
  echo "❌ beat-pair suite: definitions missing"; exit 1
fi
# A rule that exists but is never CALLED is not in force. Assert the floor is wired to it.
if grep -q 'beat-pair.sh' "$NUDGE" && grep -q 'beat_pair_ok "\$STATE"' "$NUDGE"; then
  pass "cadence-nudge.sh sources beat-pair.sh AND calls beat_pair_ok before publishing the clause"
else
  fail "cadence-nudge.sh does not source beat-pair.sh / call beat_pair_ok — the guard is NOT in force"
fi

# mkpair <dir> <recap-text> <md-key: auto|OMIT|LITERAL> [<write-recap: yes|no>]
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
if [ "$failures" -eq 0 ]; then
  echo "✅ beat-pair suite passed (${checks} assertions)"
  exit 0
fi
echo "❌ beat-pair suite: $failures of $checks assertion(s) failed"
exit 1
