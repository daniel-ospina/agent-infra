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
MIN_ASSERTIONS=42
MIN_FIXTURE_ROWS=19
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
# ⛔ FAIL-CLOSED EXTRACTION (#10951 review finding 1). `sed -n '/start/,/end/p'` whose END anchor
# stops matching is NOT empty — it emits START → EOF. That silently turns this suite into an `eval`
# of the whole refresh pass (which `mkdir -p`s, `rm -f`s and HONOURS an inherited `O`, so on a box
# with `O` set it rewrites the live queue artefacts). Measured on a copy with the definition
# flattened to one line: 5312 lines extracted, 45 destructive statements inside the block, and the
# `[ -z ]` guard still passed. So the extraction is bounded twice: the end anchor must EXIST in the
# file, and every extracted line must have one of the shapes the definition block is allowed to have.
END_ANCHOR='^"|select((\[\.labels'
END_FIXED='"|select(([.labels'
grep -qF -- "$END_FIXED" "$S" || {
  echo "❌ end anchor '$END_FIXED' is not in $S — refusing to eval an unbounded extraction (it would run the refresh pass in-process)"
  exit 1
}
BLOCK="$(sed -n "/^QUEUE_CONTAINER_TITLE_RE=/,/${END_ANCHOR}/p" "$S")"
if [ -z "$BLOCK" ]; then
  echo "❌ the shared population predicate is not defined in $S (QUEUE_CONTAINER_TITLE_RE … QUEUE_UNIT_SELECT)"
  exit 1
fi
# only these shapes belong in the block: comments/blanks, the three assignments, and the two jq
# `select` continuation lines. Anything else is NOT part of the predicate and must not be eval'd.
SHAPE='^[[:space:]]*(#|$)|^QUEUE_CONTAINER_(TITLE_RE|LABEL)=|^QUEUE_UNIT_SELECT=|^"[|]select'
UNEXPECTED="$(printf '%s\n' "$BLOCK" | grep -vcE "$SHAPE")"
if [ "$UNEXPECTED" -ne 0 ]; then
  echo "❌ the extracted block has $UNEXPECTED line(s) that are not part of the predicate — refusing to eval:"
  printf '%s\n' "$BLOCK" | grep -vnE "$SHAPE" | head -10
  exit 1
fi
# ⛔ SHAPE IS NOT CONTENT (#10951 second review, finding 5). The allowlist above bounds a line's FORM,
# so a line that LOOKS like a jq continuation can still carry shell. Measured: inserting
# `"|select(([.labels$(touch /tmp/PWNED_A3)"` matches `^"[|]select`, passes the shape check, and
# `eval` RUNS the substitution. Two content refusals close it — and the first cut of this guard was
# itself too broad (`;` legitimately appears inside `test(…;"i")`), so the markers are the ones that
# actually execute INSIDE a double-quoted string, which is where every line of this block lives:
#   - no command substitution / backtick anywhere in a non-comment line;
#   - the three ASSIGNMENT lines must END at their closing quote, so nothing can be appended after it
#     (`QUEUE_CONTAINER_LABEL='x'; rm -rf …` would otherwise pass a start-anchored shape).
BADSUB="$(printf '%s\n' "$BLOCK" | grep -vE '^[[:space:]]*#' | grep -cE '\$\(|`')"
if [ "$BADSUB" -ne 0 ]; then
  echo "❌ the extracted block carries command substitution / a backtick on $BADSUB line(s) — refusing to eval:"
  printf '%s\n' "$BLOCK" | grep -vE '^[[:space:]]*#' | grep -nE '\$\(|`' | head -5
  exit 1
fi
BADTAIL="$(printf '%s\n' "$BLOCK" | grep -cE '^QUEUE_')"
GOODTAIL="$(printf '%s\n' "$BLOCK" | grep -cE "^QUEUE_CONTAINER_(TITLE_RE|LABEL)='[^']*'$|^QUEUE_UNIT_SELECT=\"[^\"]*\"\\\\$")"
if [ "$BADTAIL" -ne "$GOODTAIL" ]; then
  echo "❌ an assignment line in the block does not END at its closing quote ($GOODTAIL of $BADTAIL) — refusing to eval"
  printf '%s\n' "$BLOCK" | grep -E '^QUEUE_' | head -5
  exit 1
fi
eval "$BLOCK"
for v in QUEUE_CONTAINER_TITLE_RE QUEUE_CONTAINER_LABEL QUEUE_UNIT_SELECT; do
  if [ -z "${!v:-}" ]; then echo "❌ $v resolved empty after extracting the block"; exit 1; fi
done
# ⛔ AND THE BLOCK'S CONTENT, NOT ONLY ITS VARIABLE NAMES (#10951 second review, measured). The loop
# above proves the three variables are NON-EMPTY — not that they still carry the two parts of the rule.
# A truncated extraction (one that ends after the title select) leaves three non-empty variables, and
# then arm 4 strips a fragment that was never there, so "removing the label select changed the answer"
# is asserted about a program that never had a label select.
# ⚠️ MATCH THE EXPANDED VALUE. The first cut of this pin looked for the literal token
# `QUEUE_CONTAINER_LABEL` inside `$QUEUE_UNIT_SELECT` — but `eval "$BLOCK"` has already expanded it, so
# the token can never appear and the `case` fell through an empty `esac`: a pin that could not fire,
# reported green. It also had no `*)` arm, so a non-match was silent. Both are fixed here.
case "$QUEUE_UNIT_SELECT" in
  *'.labels[]?.name'*'index('*) : ;;
  *) { echo "❌ the extracted predicate carries no DECLARATION-label arm — the block is truncated (got: $QUEUE_UNIT_SELECT)"; exit 1; } ;;
esac
case "$QUEUE_CONTAINER_LABEL" in
  standing-constraint) : ;;
  *) { echo "❌ QUEUE_CONTAINER_LABEL is no longer \`standing-constraint\` (got: $QUEUE_CONTAINER_LABEL)"; exit 1; } ;;
esac
# ⛔ A FIXTURE ROW THAT IS DELETED MUST RED, NOT PASS. `has N && bad … || ok …` takes the `ok` branch
# when the row is ABSENT, so every behavioural arm above is vacuous against a fixture that lost its
# row (measured: deleting a row left ALL PASSED). The count is pinned as a FLOOR, so a legitimate
# addition does not red it either.
FIX_ROWS="$(jq 'length' "$FIX" 2>/dev/null)"
case "${FIX_ROWS:-}" in ''|*[!0-9]*) FIX_ROWS=0 ;; esac
if [ "$FIX_ROWS" -lt "$MIN_FIXTURE_ROWS" ]; then
  echo "❌ the fixture carries $FIX_ROWS row(s) but this suite needs at least $MIN_FIXTURE_ROWS — a row the arms name was deleted, so those arms are vacuous"
  exit 1
fi

echo "── arm 1: one definition, every call site"
eq "the container-title pattern is built in exactly one place (comments excluded)" \
  "1" "$(grep -v '^[[:space:]]*#' "$S" | grep -c '\^(epic')"
eq "the narrow ^(epic|OWNER DECISION) filter survives nowhere" \
  "0" "$(grep -c 'test("^(epic|OWNER DECISION)";"i")' "$S")"
# ⛔ COUNT THE CALL-SITE SHAPE, COMMENTS EXCLUDED (#10951 review finding 2). The old assertion read
# `grep -c QUEUE_UNIT_SELECT` = 5, which counts comments and the definition itself. Measured both
# directions: drop a whole tier's call site but leave one comment naming the variable → count still
# 5, ALL PASSED; add one `#:` doc line to the block → count 6, FAILED. So the sites are counted by
# their literal `--jq` prefix, and an INLINE predicate at any listing is counted separately — a
# second filter cannot ride alongside the shared one unseen.
# ⛔ THREE DIRECT CALL SITES PLUS ONE ALIAS (#10951, delivery-lane review P1). The emergency listing
# reads the definition through a LOCAL alias (`local unit_select="${QUEUE_UNIT_SELECT:-}"`) because a
# TOP-LEVEL constant is an UNSET VARIABLE inside `product-floor.test.sh`'s extracted copy — which
# crashed under `set -u` and cost five assertions at `bc9a9227`. The alias is therefore pinned as a
# literal of its own: "one definition" would otherwise be a claim about a copy.
eq "the three tier call sites interpolate \$QUEUE_UNIT_SELECT (comments excluded)" \
  "3" "$(grep -v '^[[:space:]]*#' "$S" | grep -cF -- '--jq ".[]|${QUEUE_UNIT_SELECT}|')"
eq "the emergency listing reads the predicate through a local alias of the SAME variable" \
  "1" "$(grep -v '^[[:space:]]*#' "$S" | grep -cF -- 'local unit_select="${QUEUE_UNIT_SELECT:-}"')"
eq "...and interpolates that alias, so it cannot carry a predicate of its own" \
  "1" "$(grep -v '^[[:space:]]*#' "$S" | grep -cF -- '--jq ".[]|${unit_select}|.number"')"
# ⛔ EVERY `--jq` THAT MENTIONS `select` MUST USE THE SHARED ONE (#10951 second review, finding 4).
# The first version matched only `select((` — so a fifth copy shaped `select(.title|test("^wip|"))`
# (single paren) rode in green. Measured: inserting such a tier query left the suite at ALL PASSED.
# That is exactly the "two meanings of a unit" shape this issue exists to prevent, so the arm is now
# POSITIVE: a `--jq` line that mentions `select` but not the shared fragment is a failure, whatever
# its spelling.
eq "no tier query carries a predicate of its own" \
  "0" "$(grep -v '^[[:space:]]*#' "$S" | grep -E -- '--jq ' | grep -F select | grep -vcE -- '\$\{QUEUE_UNIT_SELECT\}|\$\{unit_select\}')"

# ⛔ THE CALL SITES' OWN PROGRAMS, NOT JUST THE SHARED SELECT (#10951 review finding 3). The arms
# above extract only the DEFINITION and then build their own `--jq` program by hand — so the four
# call sites' rank prefixes and their `\"` / `\(` escaping were graded by nothing. Measured: double
# the backslash at the P2 site (`\\(` → `\\\\(` in source) → jq emits the literal `2 \\(.number)`
# for every row; the pool collapses to that one bogus token and the suite still printed ALL PASSED.
# Each tier's suffix is therefore pinned as an exact literal: changing a single backslash reds it.
# (The literals are SINGLE-quoted so the shell cannot interpret a byte of them — the source text is
# `|\"0 \\(.number)\"`, i.e. a double backslash that becomes `\(` in the assembled jq program.)
eq "the P0 call site emits the '0 ' rank prefix with correct jq escaping" \
  "1" "$(grep -v '^[[:space:]]*#' "$S" | grep -cF -- '|${QUEUE_UNIT_SELECT}|\"0 \\(.number)\"')"
eq "the P1 call site emits the '1 ' rank prefix with correct jq escaping" \
  "1" "$(grep -v '^[[:space:]]*#' "$S" | grep -cF -- '|${QUEUE_UNIT_SELECT}|\"1 \\(.number)\"')"
eq "the P2 call site emits the '2 ' rank prefix with correct jq escaping" \
  "1" "$(grep -v '^[[:space:]]*#' "$S" | grep -cF -- '|${QUEUE_UNIT_SELECT}|\"2 \\(.number)\"')"
eq "the emergency listing emits a bare .number (no rank prefix)" \
  "1" "$(grep -v '^[[:space:]]*#' "$S" | grep -cF -- '|${unit_select}|.number')"

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

eq "the fixture's pickable population" "8488 10175 10538 90001 90004 90005 90007 90009 90014 90019 90020 " "$(pickable)"

for n in 5333 4917 9097 90006 90008 90010 90011 90012 90015 90016 90017 90018; do
  has "$n" && bad "#$n ($(jq -r ".[]|select(.number==$n)|.title" "$FIX" | cut -c1-24)…) is a container and must NOT be pickable" \
           || ok "#$n is excluded as a container"
done
has 2281 && bad "#2281 (epic: …) must not be pickable" || ok "#2281 is excluded as an epic"
# ⚠️ WHAT #8488 IS MODELLED AS, NOT WHAT IT IS (second review, P2). Live `tortoise#8488` carries
# `owner-decision,provenance-stale,P1-severe`; this fixture row carries `P1-severe` only. That is
# DELIBERATE: the rule under test is the one where `owner-decision` is NOT an exclusion (see the
# comment on `QUEUE_CONTAINER_LABEL` — it would drop three live P0-blockers), so the row isolates the
# title/label rule from a label this predicate does not read. The live label set and the decision it
# needs are recorded on the follow-up issue, not asserted here.
for n in 8488 10538 90001 90005 90007 90009; do
  has "$n" && ok "#$n is real work and stays pickable" || bad "#$n is real work but was excluded"
done
has 90002 && bad "#90002 declares \`standing-constraint\` and must not be pickable" \
          || ok "#90002 is excluded BY ITS LABEL, though its title looks like ordinary work"
# ⛔ THE OVER-EXCLUSION DIRECTION, WHICH NOTHING ELSE GUARDS (#10951 second review, measured). Every arm
# above asserts "container → excluded"; none asserted "REAL WORK → kept" for the shapes the live queue
# actually carries. Measured: adding `P0 |P0:|P1:|P1 ` to the title regex left the suite at ALL PASSED,
# and that entry hides eight live tier rows including three `P0-blocker`s (tortoise#10976 "P0 storage:
# nothing evicts the FalkorDB cache…", tortoise#10000, agent-infra#2833 "P0: lanes die constantly…").
# Row 90014 is that shape: a severIty prefix is not a container prefix, and a filter that hides a P0 is
# the failure this issue exists to prevent — in the opposite direction.
has 90014 && ok "#90014 (a \`P0 <noun>:\` title — real work, and the shape three live P0-blockers carry) stays pickable" \
          || bad "#90014 was excluded: a severity prefix is not a container prefix, and this hides real P0 work"
# ⛔ A KIND AS A BARE PREFIX IS THE SAME DEFECT, ONE RULE OVER (#10951 review cycle 1, measured). `epic`
# is a PREFIX of `epidemic`, and `lane ` of `lane reaper:` — so a bare stem excludes a title that merely
# STARTS with the letters. Both are real work shapes and both were pickable before this change, so
# shipping the bare form would have been a REGRESSION that no container arm above could see.
has 90019 && ok "#90019 (\`analysis-paralysis fix: …\` — real work) stays pickable: the analysis stem is form-anchored, never a bare prefix" \
          || bad "#90019 was excluded by a bare \`analysis\` stem — \`analysis\` is a prefix of \`analysis-paralysis\`, so this hides real work"
has 90020 && ok "#90020 (\`lane reaper: …\` — a real bug ticket) stays pickable: the lane form needs a lane ID" \
          || bad "#90020 was excluded by a bare \`lane \` form — \`lane-<tool>:\` and \`lane reaper:\` are real tickets"
has 90003 && bad "#90003 is assigned and must not be pickable" \
          || ok "#90003 is excluded because it is assigned"
has 10175 && ok "#10175 is still title-pickable — the label, not the title, is how a constraint is declared" \
          || bad "#10175 should be excluded only by its label; the title arm alone must not be the mechanism"
has 90004 && ok "#90004 (NO labels key at all — the key is absent, not empty) stays pickable — a missing field is not an exclusion" \
          || bad "#90004 was excluded: the label arm turned a missing labels key into a false exclusion"
has 90009 && ok "#90009 (no ASSIGNEES key) stays pickable — the other half of the missing-field question" \
          || bad "#90009 was excluded: a missing assignees key became a false exclusion"
# ⛔ THE CLAIM "NO labels KEY" IS ITSELF PINNED (#10951 second review, finding 3). `has` is true for
# an ABSENT key and for `[]` alike, so the assertion above passed even if the fixture put
# `"labels": []` back — the absent-key path (the one `?.` exists for) would silently lose its only
# coverage, and `[.labels[]?.name]` could then be de-`?`-ed with the suite still green. Pin the shape.
eq "the fixture's #90004 really carries NO labels key" \
  "false" "$(jq -r '.[]|select(.number==90004)|has("labels")' "$FIX")"
eq "the fixture's #90009 really carries NO assignees key" \
  "false" "$(jq -r '.[]|select(.number==90009)|has("assignees")' "$FIX")"

echo "── arm 4: MUTATION — strip the label select and the label arm must go GREEN"
# ⛔ A MUTATION THAT CHANGES NOTHING PROVES NOTHING. If the strip below no longer matches (the label
# select is renamed, respelled, or absent), `$MUT` is identical to `$QUEUE_UNIT_SELECT` and the
# "it discriminates" assertion below becomes a tautology — a green arm that cannot go red, which is
# the class of defect this suite exists to refuse. So the mutation's EFFECT is asserted first.
MUT="$(printf '%s' "$QUEUE_UNIT_SELECT" | sed 's/|select((\[.*$//')"
[ "$MUT" != "$QUEUE_UNIT_SELECT" ]
if [ "$MUT" = "$QUEUE_UNIT_SELECT" ]; then
  bad "the mutation did not change the predicate — the label select is gone or respelled, so arm 4 asserts nothing"
fi
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
    # ⛔ `<` NOT `!=` (#10951 review). The pin exists to catch a suite that was EMPTIED or skipped; `-ne`
    # also reds on a legitimate ADDITION, which is the "gate refuses honest work" class this file has
    # otherwise been careful about — this very series tripped it (18 → 34) while adding arms. `-lt` keeps
    # every anti-emptying property (delete a section and PASS still falls below the floor) and drops the
    # false failure. The count is still REPORTED either way.
    if [ "$FAIL" -eq 0 ] && [ "$PASS" -lt "$MIN_ASSERTIONS" ]; then
      echo "❌ only $PASS assertion(s) ran but this suite declares a floor of $MIN_ASSERTIONS — a section was deleted or skipped"
      FAIL=$((FAIL + 1))
    fi ;;
esac

if [ "$FAIL" -eq 0 ]; then echo "ALL PASSED ($PASS assertion(s), floor $MIN_ASSERTIONS)"; exit 0; fi
echo "FAILED: $FAIL of $((PASS + FAIL)) assertion(s)"
exit 1
