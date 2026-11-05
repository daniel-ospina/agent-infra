#!/usr/bin/env bash
# tests/queue-population-filter/run.sh — #10951: ONE population predicate, and a standing constraint
# excluded by DECLARATION rather than by guessing at a title prefix.
#
# THE DEFECT THIS PINS. `refresh-candidates.sh` carried FOUR copies of "what is not a unit of work",
# with TWO different meanings: the P0 pool and the emergency listing excluded
# `^(epic|lane|OWNER DECISION|decision|analysis|investigation)`; the P1-severe and P2-moderate pools
# excluded only `^(epic|OWNER DECISION)`. Measured 2026-11-04 18:52Z, 6 of the 8 remaining `NO-PR`
# P1 units were containers the narrow filter let through — including #10175, whose own title reads
# "the hosted capture cap is HELD deliberately — never override it". A picker that lands there
# dispatches a lane AT a standing constraint: a bypass, not a bad sort.
#
# WHAT IS PINNED, and why each arm exists:
#   1. the predicate is DEFINED ONCE and every pool/emergency call site reads it — the two-narrow-
#      filters shape is gone, so no tier can disagree with another about what a unit is;
#   2. the spellings the repo actually writes (`design(`, `coord:`, `measure(`) are counted as
#      containers, and the ones that are plausibly real work (`feat(`, `fix(`, a bare title) still
#      are NOT — a filter that excludes everything is as useless as one that excludes nothing;
#   3. a `standing-constraint` LABEL excludes, whatever the title says (#10902: declare the
#      property, do not infer it from prose) — and the arm is MUTATION-checked, so a label select
#      that silently stopped working cannot pass;
#   4. an ASSIGNED issue is still someone else's work, and a payload with NO labels key is still a
#      candidate — the label arm must not turn a missing field into a false exclusion;
#   5. the regex carries NO BACKSLASH. That is the trap this check exists to keep closed: the
#      pattern is interpolated into a jq STRING literal, and `\b` there is jq's BACKSPACE escape
#      (U+0008), consumed before the regex engine sees it — so a `\b` would match nothing and the
#      whole filter would fail OPEN while looking stricter. Arm 1 would still pass in that state,
#      which is why the behavioural arms below run the REAL jq program.
#
# The arms drive the definitions extracted from the live script (never a copy), so the test cannot
# drift from the code it grades.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
S="$ROOT/scripts/orchestrator-harness/refresh-candidates.sh"
FIX="$ROOT/tests/fixtures/queue-population-filter/issues.json"
MIN_ASSERTIONS=18
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
eq() { if [ "$2" = "$3" ]; then ok "$1 → [$3]"; else bad "$1: expected [$2], got [$3]"; fi; }

if ! command -v jq >/dev/null 2>&1; then
  echo "❌ jq is required to grade the population predicate (the script's own --jq program)"
  exit 1
fi
if [ ! -f "$S" ]; then
  echo "❌ missing $S — this suite grades the live script, so its absence is a failure, not a skip"
  exit 1
fi
if [ ! -f "$FIX" ]; then
  echo "❌ missing fixture $FIX"
  exit 1
fi

# ── the definitions, extracted from the LIVE script (no copy, no paraphrase) ──────────────────
BLOCK="$(sed -n '/^QUEUE_CONTAINER_TITLE_RE=/,/^"|select((\[.labels/p' "$S")"
if [ -z "$BLOCK" ]; then
  echo "❌ the shared population predicate is not defined in $S (QUEUE_CONTAINER_TITLE_RE … QUEUE_UNIT_SELECT)"
  exit 1
fi
eval "$BLOCK"
for v in QUEUE_CONTAINER_TITLE_RE QUEUE_CONTAINER_LABEL QUEUE_UNIT_SELECT; do
  if [ -z "${!v:-}" ]; then echo "❌ $v resolved empty after extracting the block"; exit 1; fi
done

echo "── arm 1: one definition, every call site"
eq "the container-title pattern is built in exactly one place (comments excluded)" \
  "1" "$(grep -v '^[[:space:]]*#' "$S" | grep -c '\^(epic')"
eq "the narrow ^(epic|OWNER DECISION) filter survives nowhere" \
  "0" "$(grep -c 'test("^(epic|OWNER DECISION)";"i")' "$S")"
eq "one definition + four call sites use \$QUEUE_UNIT_SELECT" \
  "5" "$(grep -c 'QUEUE_UNIT_SELECT' "$S")"

echo "── arm 2: the jq escaping trap (a backslash here fails OPEN)"
case "$QUEUE_CONTAINER_TITLE_RE" in
  *\\*) bad "the pattern carries a backslash — in a jq string literal that is an ESCAPE (\\b → U+0008), so the filter would match nothing: [$QUEUE_CONTAINER_TITLE_RE]" ;;
  *) ok "the pattern carries no backslash, so jq hands the regex engine exactly what the shell defined" ;;
esac
eq "the pattern is anchored at the start (a prefix test is the whole rule)" \
  "^(epic" "${QUEUE_CONTAINER_TITLE_RE:0:6}"

echo "── arm 3: behaviour on the REAL jq program (the one the script sends)"
pickable() { jq -r ".[]|${QUEUE_UNIT_SELECT}|\"\(.number)\"" "$FIX" | sort -n | tr '\n' ' '; }
has() { case " $(pickable) " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

eq "the fixture's pickable population" "8488 10175 10538 90001 90004 " "$(pickable)"

for n in 5333 4917 9097; do
  has "$n" && bad "#$n ($(jq -r ".[]|select(.number==$n)|.title" "$FIX" | cut -c1-24)…) is a container and must NOT be pickable" \
           || ok "#$n is excluded as a container"
done
has 2281 && bad "#2281 (epic: …) must not be pickable" || ok "#2281 is excluded as an epic"
for n in 8488 10538 90001; do
  has "$n" && ok "#$n is real work and stays pickable" || bad "#$n is real work but was excluded"
done
has 90002 && bad "#90002 declares \`standing-constraint\` and must not be pickable" \
          || ok "#90002 is excluded BY ITS LABEL, though its title looks like ordinary work"
has 90003 && bad "#90003 is assigned and must not be pickable" \
          || ok "#90003 is excluded because it is assigned"
has 10175 && ok "#10175 is still title-pickable — the label, not the title, is how a constraint is declared" \
          || bad "#10175 should be excluded only by its label; the title arm alone must not be the mechanism"
has 90004 && ok "#90004 (no labels key) stays pickable — a missing field is not an exclusion" \
          || bad "#90004 was excluded: the label arm turned a missing labels key into a false exclusion"

echo "── arm 4: MUTATION — strip the label select and the label arm must go GREEN"
MUT="$(printf '%s' "$QUEUE_UNIT_SELECT" | sed 's/|select((\[.*$//')"
mut_pickable() { jq -r ".[]|${MUT}|\"\(.number)\"" "$FIX" | tr '\n' ' '; }
case " $(mut_pickable) " in
  *" 90002 "*) ok "removing the label select makes #90002 pickable again — the arm discriminates" ;;
  *) bad "removing the label select did NOT change the answer, so that arm is not actually pinned" ;;
esac

echo "── arm 5: the suite cannot be emptied"
case "$MIN_ASSERTIONS" in
  ''|*[!0-9]*)
    echo "❌ MIN_ASSERTIONS is not a non-negative integer ('$MIN_ASSERTIONS') — the pin is deactivated, which is itself a failure"
    FAIL=$((FAIL + 1)) ;;
  *)
    if [ "$FAIL" -eq 0 ] && [ "$PASS" -ne "$MIN_ASSERTIONS" ]; then
      echo "❌ $PASS assertion(s) ran but this suite declares $MIN_ASSERTIONS — a section was deleted or skipped, or an assertion was added without updating the pin"
      FAIL=$((FAIL + 1))
    fi ;;
esac

if [ "$FAIL" -eq 0 ]; then echo "ALL PASSED ($PASS assertion(s))"; exit 0; fi
echo "FAILED: $FAIL of $((PASS + FAIL)) assertion(s)"
exit 1
