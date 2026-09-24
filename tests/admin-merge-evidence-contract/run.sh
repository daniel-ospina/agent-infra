#!/bin/bash
# ============================================================================
#  The certificate CONTRACT, pinned against REAL evidence (#1388 clauses 6+7).
# ============================================================================
#
#  WHY THIS SUITE EXISTS. `bcbb7df` (2026-09-17, #3756/PR #1147) renamed the
#  producer's residual clause in four places — `unique to this PR: 0` became
#  `blocked by the decision: 0`. Both gates kept requiring the OLD name and every
#  admin merge was refused fleet-wide for six days, with EVERY suite green. The
#  reason no suite noticed is the reason this one is built the way it is: each
#  suite pinned HAND-WRITTEN fixtures, and a hand-written fixture cannot notice
#  that the producer moved. So the refusal case here is a REAL captured
#  certificate, and the drift-pin asserts the GATE's required literals against it.
#
#  PROVENANCE, STATED PER FIXTURE (a claim about "real evidence" is only worth
#  what it can be checked against):
#    NEG  = the REAL capture, byte for byte, and the drift-pin's reference.
#    POS  = the real ENVELOPE with synthetic non-vacuous counts (the producer emits
#           no such body today because no captured PR had failures). It proves the
#           clause-4 spelling is accepted; it does NOT prove the producer emits it.
#    vac-par = the real vacuous body plus the producer's real parity VALUE, so the
#           vacuous positive half is exercised without claiming it was captured.
#
#  Sets its own exit code so it can run standalone or inside another job.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# The versions under test default to this worktree. Both are overridable so the
# suite can be pointed at the PRE-FIX revision and shown to REDDEN — that is how
# the coverage claim is MEASURED rather than asserted:
#   VERIFIER_UNDER_TEST=$(git show <base>:scripts/verify-admin-merge-evidence.sh) …
# Measured against origin/main, with BOTH overrides: 6 assertions redden — the
# non-vacuous positive, the vacuous+parity positive, the literal extraction, the
# retired-claim pin (which now FAILS CLOSED on an empty extraction instead of
# passing vacuously) and the two clause-6 pins. With the VERIFIER override alone it
# is 4: the clause-6 pins test the TS gate, which the verifier override does not swap.
# The per-class mutation tests are provable only against the CURRENT revision: a
# pre-fix gate that refuses EVERY body carrying the new vocabulary cannot
# distinguish a mutation from a legitimate body. That is stated in the PR body
# rather than dressed up as "every class fails before its fix".
VERIFIER="${VERIFIER_UNDER_TEST:-$ROOT/scripts/verify-admin-merge-evidence.sh}"
TS_GATE="${TS_GATE_UNDER_TEST:-$ROOT/extensions/review-enforcer/index.ts}"
PRODUCER="${PRODUCER_UNDER_TEST:-$ROOT/scripts/admin-merge.sh}"
NEG="$HERE/captured-1406-vacuous-parity-not-established.md"
POS="$HERE/derived-1406-nonvacuous-counts.md"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
F=0; P=0
ok()  { P=$((P+1)); printf '   ✅ %s\n' "$1"; }
bad() { F=$((F+1)); printf '   ❌ %s\n' "$1"; }
# The head the captured body is bound to — read FROM the capture, not restated.
HEAD="$(sed -n 's/^PR head: \(.*\)$/\1/p' "$POS" | head -1)"
[ -n "$HEAD" ] || { echo "fixture has no 'PR head:' line — cannot test"; exit 1; }

certifies() { bash "$VERIFIER" --body-file "$1" --head "$HEAD" >/dev/null 2>&1; }

echo "=== the certificate contract (#1388) — real captured evidence ==="
echo "    head under test: ${HEAD:0:12}… (read from the capture)"

# ── 1. the real capture, as the producer actually wrote it ──────────────────
# It is VACUOUS (both counts 0) and its parity line reads NOT ESTABLISHED — the
# #1319 rule says a vacuous comparison is not comparable without parity, so this
# must NOT certify even though every other clause is present.
if certifies "$NEG"; then
  bad "a VACUOUS comparison with 'lane parity: NOT ESTABLISHED' CERTIFIED (clause 5 fail-open)"
else
  ok "a vacuous comparison with parity NOT ESTABLISHED does NOT certify (clause 5)"
fi

# ── 1b. THE BYPASS BOTH REVIEWERS FOUND, pinned shut ────────────────────────
# Vacuity used to be read from the producer's DESCRIPTIVE line
# (`measured sets: PR failing …`), so deleting that one line from the real body
# certified it with no parity statement at all. Vacuity is now read from the two
# counts, which is the condition itself: remove the description and the verdict
# must not move. This mutation is the reviewer's reproduction, kept as a test.
sed '/measured sets: PR failing/d' "$NEG" > "$TMP/m-nodesc.md"
if [ "$(grep -c 'measured sets' "$TMP/m-nodesc.md")" -ne 0 ]; then
  bad "the mutation did not remove the 'measured sets:' line, so it proves nothing"
elif certifies "$TMP/m-nodesc.md"; then
  bad "DELETING the 'measured sets:' description line CERTIFIED a vacuous body with no parity (clause 5 fail-open — the class both reviewers reproduced)"
else
  ok "deleting the 'measured sets:' line does NOT change the verdict (vacuity is read from the counts, not the description)"
fi

# ── 2. a NON-vacuous comparison, zero residual → certifies ──────────────────
# POS has SYNTHETIC counts over the real envelope (see the header); what it
# proves is that clause 4 accepts the producer's current spelling, and that a
# non-vacuous body does NOT additionally need a parity line.
if certifies "$POS"; then
  ok "a NON-vacuous body in the producer's current clause-4 spelling CERTIFIES (synthetic counts, real envelope)"
else
  bad "a non-vacuous body carrying the producer's clause-4 spelling was REFUSED — clause 4 is unsatisfiable against real evidence"
fi

# ── 3. the vacuous case WITH established parity → certifies ─────────────────
# Built from the REAL vacuous body (both counts 0, so clause 5 applies) with its
# parity line REPLACED by the producer's real positive VALUE — the positive half
# of clause 5, exercised without claiming the combination was captured, and
# without leaving the contradictory `NOT ESTABLISHED` line in place.
sed 's/^   lane parity: NOT ESTABLISHED.*/   lane parity: PR ⊇ main — the PR executed every test shard main'"'"'s lane executed (parity family: test*; 1 shard(s) on the PR side, 1 on main)/' "$NEG" > "$TMP/vac-par.md"
grep -q 'lane parity: PR ⊇ main' "$TMP/vac-par.md" || bad "the vacuous+parity fixture was not built (its parity line was not replaced), so §3 proves nothing"
if certifies "$TMP/vac-par.md"; then
  ok "a vacuous comparison WITH 'lane parity: PR ⊇ main' CERTIFIES (clause 5 positive half)"
else
  bad "vacuous + positive parity was REFUSED (clause 5 is unsatisfiable)"
fi

# ── 4. MUTATIONS — each must flip the verdict ───────────────────────────────
# (a) ONE WORD of the producer's own clause. This is the #1388 mutation: the
#     check is not a spelling preference, it is the certification itself.
sed 's/blocked by the decision: 0/blocked by the decision: 1/' "$POS" > "$TMP/m-clause4.md"
if certifies "$TMP/m-clause4.md"; then bad "a wrong clause-4 value still CERTIFIED (the requirement is not load-bearing)"; else ok "mutation: a wrong clause-4 value refuses"; fi
# (a2) …and the RETIRED spelling must not certify either. This is the outage's own
#      shape: the gate must require what the producer emits TODAY, so a body still
#      carrying `unique to this PR: 0` is refused — not because the claim is wrong
#      (it was stronger) but because the producer can no longer prove it and this
#      gate must track the producer. Both directions are pinned: the retired spelling
#      is refused here, and §5's LITS pin keeps it out of the FILTER.
sed 's/blocked by the decision: 0/unique to this PR: 0/' "$POS" > "$TMP/m-retired.md"
if grep -q 'unique to this PR: 0' "$TMP/m-retired.md"; then
  if certifies "$TMP/m-retired.md"; then bad "a body carrying the RETIRED clause ('unique to this PR: 0') CERTIFIED — the gate accepts a spelling the producer no longer emits"; else ok "mutation: the retired clause spelling refuses"; fi
else
  bad "the retired-clause mutation did not apply, so it proves nothing"
fi
# (b) the attribution count — a dropped token means a CLIPPED set, not a measured zero.
sed 's/PR=0 | main=0/PR=2 | main=0/' "$POS" > "$TMP/m-attr.md"
if certifies "$TMP/m-attr.md"; then bad "a CLIPPED set (PR=2) still CERTIFIED (clause 5 fail-open)"; else ok "mutation: a CLIPPED set refuses"; fi
# (c) remove the parity line from the vacuous case.
grep -v 'lane parity: PR ⊇ main' "$TMP/vac-par.md" > "$TMP/m-parity.md"
if certifies "$TMP/m-parity.md"; then bad "vacuous WITHOUT parity still CERTIFIED (clause 5 fail-open)"; else ok "mutation: vacuous without parity refuses"; fi
# (c2) …and a parity line that NEGATES parity must not certify either, IN EITHER
#      SPELLING. A confirming review reproduced the first spelling against an earlier
#      PREFIX test (`lane parity: PR ⊇ main is NOT established` matched
#      `^(...)[ \t]*lane parity: PR ⊇ main`). Requiring the em dash closed that one,
#      and a SECOND confirming review then reproduced the class one spelling further
#      in: `lane parity: PR ⊇ main — NOT established: …` still certified, because a
#      separator is not a truth value. Both are pinned here, and the clause now
#      requires the producer's actual positive sentence (see the verifier's comment).
sed 's/^   lane parity: .*/   lane parity: PR ⊇ main is NOT established — this head did NOT execute every shard/' "$NEG" > "$TMP/m-parity-negated.md"
if grep -q 'PR ⊇ main is NOT established' "$TMP/m-parity-negated.md"; then
  if certifies "$TMP/m-parity-negated.md"; then bad "a NEGATED parity line ('PR ⊇ main is NOT established') CERTIFIED (clause 5 fail-open)"; else ok "mutation: a NEGATED parity line (no em dash) refuses"; fi
else
  bad "the negated-parity mutation did not apply, so it proves nothing"
fi
# (c3) THE SAME NEGATION *AFTER* THE EM DASH — the spelling the first fix left open.
sed 's/^   lane parity: .*/   lane parity: PR ⊇ main — NOT established: this head did NOT execute every shard main ran/' "$NEG" > "$TMP/m-parity-postdash.md"
if grep -q 'PR ⊇ main — NOT established' "$TMP/m-parity-postdash.md"; then
  if certifies "$TMP/m-parity-postdash.md"; then bad "a parity line that NEGATES parity AFTER the em dash CERTIFIED (clause 5 fail-open — an em dash is a separator, not a truth value)"; else ok "mutation: a negation AFTER the em dash refuses"; fi
else
  bad "the post-em-dash negation mutation did not apply, so it proves nothing"
fi
# (c4) …and a body that states the producer's positive sentence and then DISCLAIMS it
#      — INSIDE the parenthetical the clause tolerates — must refuse too. This is the
#      third spelling of the same class: the sentence is present, so a sentence-only
#      check passes, and the parenthetical used to accept any text. Allowed trailing
#      text is now ENUMERATED (the producer's own parenthetical shape), and the
#      negation guard is case-insensitive, because a case-sensitive deny-list is
#      defeated by `Not established` / `not ESTABLISHED` (a review reproduced both).
for trap_case in \
  'parity family: test*; 3 shard(s) on the PR side, 3 on main — Not established: this head did NOT execute 1 shard' \
  'parity family: test*; 3 shard(s) on the PR side, 3 on main; not ESTABLISHED — declared off' \
  'parity family: test*; 3 shard(s) on the PR side, 3 on main — MISMATCH: this head ran a different lane'; do
  sed "s|^   lane parity: .*|   lane parity: PR ⊇ main — the PR executed every test shard main's lane executed ($trap_case)|" "$NEG" > "$TMP/m-parity-trap.md"
  if grep -qF "$trap_case" "$TMP/m-parity-trap.md"; then
    if certifies "$TMP/m-parity-trap.md"; then bad "the producer's positive sentence with an appended disclaimer CERTIFIED (clause 5 fail-open): $trap_case"; else ok "mutation: the positive sentence with an appended disclaimer refuses"; fi
  else
    bad "the appended-disclaimer mutation did not apply, so it proves nothing: $trap_case"
  fi
done
# (d) the marker — an unrelated body must not certify.
grep -v 'admin-merge-safety' "$POS" > "$TMP/m-marker.md"
if certifies "$TMP/m-marker.md"; then bad "a body with NO marker CERTIFIED"; else ok "mutation: no marker refuses"; fi

# (e) and (f) THE BOUNDARY GUARDS — the first cut of this change used `contains`
# for these two clauses, which is a SUBSTRING test: `...: 0.5` and `PR=0 |\nmain=01`
# would both have satisfied it, so a NON-ZERO residual would have CERTIFIED. That
# is a fail-open, and `tests/gh-shim/run.sh` already pinned exactly this shape for
# the retired clause. Pinned here against the new one so the guard cannot be lost
# again by a future rewording.
sed 's/blocked by the decision: 0/blocked by the decision: 0.5/' "$POS" > "$TMP/m-zero5.md"
if certifies "$TMP/m-zero5.md"; then bad "'blocked by the decision: 0.5' CERTIFIED — the clause is a substring match, not an exact zero (fail-open)"; else ok "mutation: a non-zero residual '0.5' refuses (the zero clause is BOUNDED)"; fi
sed 's/blocked by the decision: 0/blocked by the decision: 01/' "$POS" > "$TMP/m-zero01.md"
if certifies "$TMP/m-zero01.md"; then bad "'blocked by the decision: 01' CERTIFIED (fail-open)"; else ok "mutation: '01' refuses (not a zero)"; fi
sed 's/PR=0 | main=0/PR=0 | main=01/' "$POS" > "$TMP/m-attr01.md"
if certifies "$TMP/m-attr01.md"; then bad "a dropped-token count of '01' CERTIFIED (the attribution clause is not bounded)"; else ok "mutation: an '01' attribution count refuses (bounded)"; fi
sed 's/PR=0 | main=0/PR=0 | main=2/' "$POS" > "$TMP/m-attr2.md"
if certifies "$TMP/m-attr2.md"; then bad "a dropped main-side token CERTIFIED (clause 5 fail-open)"; else ok "mutation: a main-side dropped token refuses"; fi
# (g) ZEROING BOTH COUNTS must newly REQUIRE parity — the counterpart of 1b. A
#     body whose comparison came out vacuous is held to clause 5's parity
#     requirement even though it carries no vacuous-state PROSE.
sed 's/PR failing: 2 | main failing: 7 | blocked by the decision: 0/PR failing: 0 | main failing: 0 | blocked by the decision: 0/' "$POS" > "$TMP/m-vacuous-noparity.md"
if grep -q 'PR failing: 0 | main failing: 0 | blocked by the decision: 0' "$TMP/m-vacuous-noparity.md"; then
  if certifies "$TMP/m-vacuous-noparity.md"; then bad "a body with BOTH counts zero and NO parity line CERTIFIED (clause 5 fail-open)"; else ok "mutation: both counts zero without parity refuses (vacuity comes from the counts)"; fi
else
  bad "the zeroing mutation did not apply, so it proves nothing"
fi
# (h) A LEADING-ZERO ZERO counts as zero, and must be treated as vacuous rather than
#     smuggled past the vacuity test by its spelling. `00` is refused by clause 4's
#     canonical-count rule as well — this pins the SECOND line of defence, so the
#     class stays closed if the count predicate is ever relaxed.
sed 's/PR failing: 2 | main failing: 7 | blocked by the decision: 0/PR failing: 00 | main failing: 0 | blocked by the decision: 0/' "$POS" > "$TMP/m-leadzero.md"
if grep -q 'PR failing: 00 | main failing: 0 | blocked by the decision: 0' "$TMP/m-leadzero.md"; then
  if certifies "$TMP/m-leadzero.md"; then bad "a non-canonical zero ('PR failing: 00') CERTIFIED — it dodges the vacuity test while satisfying the count clause (fail-open)"; else ok "mutation: a leading-zero count refuses"; fi
else
  bad "the leading-zero mutation did not apply, so it proves nothing"
fi

# ── 5. DRIFT-PIN — every literal phrase the GATE requires by `contains(...)` must
# EXIST in evidence the producer really writes. This is the instrument the
# six-day outage needed: it extracts the required literals FROM the verifier (not
# from a copy of them) and asserts each is present in the REAL capture.
#
# THE REFERENCE IS THE REAL CAPTURE, and nothing the suite wrote. An earlier
# version checked the literals against `$POS` plus a hand-written variant, which
# made the pin SELF-REFERENTIAL: the only literal it extracted was matched against
# text this suite had typed to mirror the gate, so a producer rename would have
# left it green. A reviewer reproduced that reasoning; the reference is now
# `$NEG` alone, which is byte-for-byte the producer's output.
#
# The BOUNDED clauses (the two zero clauses, the provenance shape and the parity
# line) are regexes, so they are not extractable as literal phrases; they are
# covered by the behaviour tests above plus the producer greps in §6. The
# extraction is scoped to the FILTER ASSIGNMENT, never the whole file: the file's
# comments quote the retired clause to explain the rename, and a pin that reads
# prose reports requirements the code does not have.
LITS="$(sed -n '/^CLAUSE_FILTER=/,/^jq_program=/p' "$VERIFIER" | grep -o 'contains("[^"]*")' | sed 's/^contains("//; s/")$//' | grep -v '\$' | sort -u)"
[ -n "$LITS" ] || bad "could not extract any required literal from the verifier's CLAUSE_FILTER (the extraction is broken, so this pin proves nothing)"
echo "    (pinning $(printf '%s\n' "$LITS" | grep -c .) literal phrase(s) extracted from the CLAUSE_FILTER against the REAL capture)"
while IFS= read -r lit; do
  [ -n "$lit" ] || continue
  if grep -qF "$lit" "$NEG"; then
    ok "required literal is present in the REAL capture: ${lit:0:52}"
  else
    bad "the gate REQUIRES a literal the real capture does not contain: '$lit' (this is the #1388 class)"
  fi
done <<< "$LITS"

# ── 6. DRIFT-PIN — every static literal the filter requires must exist in the
# producer's evidence EMISSION.
#
# THIS SECTION EXISTS BECAUSE A COMMITTED CAPTURE CANNOT NOTICE A LATER PRODUCER
# MOVE. The §5 pin checks the gate's extractable literals against the real capture —
# but the capture is a FILE, so renaming the producer's line leaves §1–§5 green with
# a stale fixture: the six-day outage all over again. The literals are therefore
# pinned against the producer itself.
#
# SCOPED TO THE EMISSION, AND COMPLETE — both of which were review findings. An
# earlier version grepped the producer FILE, where the same strings occur in prose
# and log lines (:257, :2667, :3421), so renaming the ONE line that posts evidence
# left it green. Scoping it to `build_evidence()` fixed that, but the scoped list was
# still INCOMPLETE: the run-word (`runs?`), the ` | ` and `):` separators, and the
# marker's ` -->` close were required by the filter and pinned by nothing, so a
# producer rename of any of them left every suite green while the gate refused every
# real certificate. The pins are now the producer's TEMPLATES, so a rename of any
# part of a line the gate depends on is visible here.
#
# …and the pin is pinned: the self-test iterates over EVERY requirement and requires
# the pin to catch each one renamed. (The earlier self-test renamed a single
# literal, so deleting any other from the list would have gone unnoticed.)
#
# WHAT IS *NOT* PINNED HERE, stated so the claim is not wider than the checks: the
# two parity sites and the attribution line live outside `build_evidence()` and are
# pinned individually below. The token cross-check at the end is a weaker,
# mechanical sweep of the filter's own vocabulary.
emission_block() { sed -n '/^build_evidence()/,/^}/p' "$1"; }
# The paris emission lives in `main()`, inside the VACUOUS block's `analyzed=`
# assignment. Scoped by that block rather than the whole file because a sibling
# `info` line (:3418) carries the same string — renaming only the EVIDENCE line while
# the log line keeps the old spelling is exactly the masking a review reproduced.
parity_block() {
  # From the `analyzed=` assignment that carries `lane parity:` through the line that
  # closes the string (the closing `"` may be appended to the last content line, so
  # the block ends where a line ENDS with a quote, not where one equals one).
  awk '/analyzed="\$analyzed$/{inb=1; buf=""; next} inb{buf=buf $0 ORS; if (substr($0, length($0), 1)=="\""){ if (index(buf,"lane parity: ")>0){ printf "%s", buf; exit } inb=0 }}' "$1"
}
PIN_EMISSION=(
  '<!-- admin-merge-safety: %s -->'
  'PR head: %s'
  'main compared (union of %s %s of %s): %s'
  # WITH ITS TERMINATOR: the pin stops at the end of the FORMAT STRING (`0\n'`), so a
  # producer that emitted `…blocked by the decision: 0X` would break this instead of
  # satisfying a pin that stops at `0`. (The line continues with printf ARGUMENTS, so
  # this one cannot be an end-of-line check.) A reviewer reproduced the `0X` case.
  "PR failing: %s | main failing: %s | blocked by the decision: 0\\n'"
)
PIN_OTHER=(
  'run_word="runs"'
  'run_word="run"'
)
# …AND THIS ONE MUST *END ITS LINE*, checked as such rather than as a substring: the
# attribution's first line ends at `${main_drops}.`, so a producer that emitted
# `main=${main_drops}.Z` would ship a body the gate REFUSES while a substring pin
# stayed green. The line stops there because the string continues on the next line
# (the CLIPPED/COMPARABLE explanation), which is why the terminator is the period and
# not a quote. A reviewer reproduced the `.Z` case.
PIN_ENDLINE=(
  # THE WHOLE TAIL OF THE LINE, not the suffix a review broke: pinning only
  # `main=${main_drops}.` left `PR=${pr_drops} | ` — the half clause (f) also requires
  # — unpinned, so a producer edit there (`PR=0|main=0.`) would make the gate refuse
  # every certificate with the suite still at all-green. That is the #1388 class with
  # the gate's own pin as the thing that fails to notice it.
  'set): PR=${pr_drops} | main=${main_drops}.'
)
# The producer's PARITY VALUE, pinned as the SENTENCE AND ITS PARENTHETICAL TEMPLATE
# rather than as the delimiter the gate checks. A pin on `PR ⊇ main —` is satisfied by
# `PR ⊇ main — NOT established: …`, so a producer that reworded or negated its positive
# value could keep this green while the gate accepted a negation. The gate now requires
# this sentence and this parenthetical shape, so the pin must cover both: a producer
# reword reddens here, at the PR that causes it.
PIN_PARITY_VALUE='parity_evidence="PR ⊇ main — the PR executed every test shard main'"'"'s lane executed (parity family: ${LANE_JOB_PREFIX}*; $(lane_count "$TMP/lane-pr.txt") shard(s) on the PR side, $(lane_count "$TMP/lane-main.txt") on main)'
endline_present() {  # the literal must END a line of the file
  python3 - "$1" "$2" <<'PY'
import sys
path, lit = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
sys.exit(0 if any(line.endswith(lit) for line in text.splitlines()) else 1)
PY
}
producer_pin_missing() {  # prints the first missing requirement, or nothing when OK
  local f="$1" blk lit
  blk="$(emission_block "$f")"
  [ -n "$blk" ] || { printf 'build_evidence() block not found\n'; return; }
  for lit in "${PIN_EMISSION[@]}"; do
    if ! printf '%s' "$blk" | grep -qF "$lit"; then printf '%s\n' "$lit"; return; fi
  done
  for lit in "${PIN_OTHER[@]}"; do
    if ! grep -qF "$lit" "$f"; then printf '%s\n' "$lit"; return; fi
  done
  for lit in "${PIN_ENDLINE[@]}"; do
    if ! endline_present "$f" "$lit"; then printf '%s\n' "$lit (must END its line)"; return; fi
  done
  if ! grep -qF "$PIN_PARITY_VALUE" "$f"; then
    printf '%s\n' "$PIN_PARITY_VALUE"; return
  fi
  # …and the parity REFERENCE must be its own line's start, indentation aside: the
  # gate anchors `(^|\n)[ \t]*lane parity:`, so a producer edit that prefixes the
  # line (`NOTE lane parity: …`) would make every certificate refuse while a
  # substring pin stayed green. A reviewer reproduced that too.
  if ! parity_block "$f" | grep -qE '^[[:space:]]*lane parity: \$parity_evidence[[:space:]]*$'; then
    printf '%s\n' 'a line of the form `lane parity: $parity_evidence` (line-initial, nothing else on the line)'
  fi
}
if miss="$(producer_pin_missing "$PRODUCER")"; [ -z "$miss" ]; then
  ok "every static literal the filter requires is present in the producer's evidence EMISSION"
else
  bad "the gate requires '$miss' and the producer's evidence emission no longer contains it (the #1388 class — a committed capture cannot notice this)"
fi
# The self-test: EVERY pinned requirement, renamed EVERYWHERE in a copy, must be
# caught. (A single-occurrence rename is not enough: a string carried by a sibling
# log line would still satisfy a file-wide grep, and the first version of this
# self-test was fooled by exactly that.)
MUTN=0
for lit in "${PIN_EMISSION[@]}" "${PIN_OTHER[@]}" "${PIN_ENDLINE[@]}" "$PIN_PARITY_VALUE" 'lane parity: $parity_evidence'; do
  MUTN=$((MUTN+1))
  cp "$PRODUCER" "$TMP/producer-mut.sh"
  python3 - "$TMP/producer-mut.sh" "$lit" <<'PY'
import sys
path, lit = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
if lit not in text:
    sys.exit(3)
open(path, "w", encoding="utf-8").write(text.replace(lit, lit[0] + "X" + lit[1:]))
PY
  if [ $? -ne 0 ]; then
    bad "the mutation for '$lit' could not be applied, so its self-test proves nothing"
    continue
  fi
  if [ -n "$(producer_pin_missing "$TMP/producer-mut.sh")" ]; then
    ok "the producer pin CATCHES a renamed: ${lit:0:44}"
  else
    bad "the producer pin MISSES a renamed '$lit' — a reviewer reproduced exactly this class"
  fi
done
# The token cross-check: every word inside the FILTER's own patterns must still
# exist in the producer. Weaker than the template pins (it is file-wide), but it
# sweeps EVERY word — `runs` -> `executions`, `parity` -> `alignment` — rather than
# only the templates above. Only the quoted pattern arguments are tokenised; the
# assignment's own names (CLAUSE/jq_program/comments) are the gate's, not the
# producer's, and would be false alarms.
# The DENY-LIST vocabulary is excluded on purpose: those words are the guard's FORBIDDEN
# set (a line carrying them must NOT certify), so demanding the producer spell them would
# be backwards — and the earlier run of this cross-check said exactly that about
# `MISMATCH`, which is the check working as written and the exclusion being missing.
FILTER_TOKENS="$(sed -n '/^CLAUSE_FILTER=/,/^jq_program=/p' "$VERIFIER" | grep -oE '(contains|test)\("[^"]*"' | grep -oE '[A-Za-z]{4,}' | sort -u | grep -vxE 'contains|test|NOT|ESTABLISHED|FAILED|MISMATCH|DID|NEVER')"
TOKN=0
while IFS= read -r tok; do
  [ -n "$tok" ] || continue
  TOKN=$((TOKN+1))
  if grep -qF "$tok" "$PRODUCER"; then
    ok "the producer still carries a word the filter depends on: $tok"
  else
    bad "the filter's pattern depends on '$tok' and the producer no longer carries it (the #1388 class)"
  fi
done <<< "$FILTER_TOKENS"
echo "    (producer pin: $MUTN requirements, each mutation-tested; token cross-check: $TOKN tokens)"
# Scope to the CLAUSE FILTER, not the file: the verifier's comments DISCUSS the
# retired name to explain the rename, so a file-wide grep reports it as still
# required. Only the filter decides what is accepted.
#
# FAIL CLOSED when nothing could be extracted: without this the assertion reads
# GREEN against a verifier that has no `CLAUSE_FILTER=` assignment at all — i.e.
# against the pre-fix gate that requires the retired clause — because an empty
# `$LITS` makes the `grep -qxF` false. A confirming review caught that: the claim
# "the gate does not require 'unique to this PR: 0'" was passing vacuously exactly
# when it was FALSE.
if [ -z "$LITS" ]; then
  bad "no literal could be extracted from the CLAUSE_FILTER, so 'the gate does not require the retired claim' cannot be evaluated — failing closed (this is what the pre-fix gate looks like)"
elif printf '%s\n' "$LITS" | grep -qxF 'unique to this PR: 0'; then
  bad "the gate went back to requiring 'unique to this PR: 0' — the claim the producer cannot prove: #1319 fail-open"
else
  ok "the gate does NOT require the retired, stronger claim ('unique to this PR: 0')"
fi
# The producer must still be able to state the positive parity half the gate
# accepts — otherwise the vacuous case is unsatisfiable and every vacuous
# comparison is refused whether or not it was comparable. (The assignment site is
# pinned by `producer_pin_missing` above; this keeps the older, wider check too.)
if grep -qF 'PR ⊇ main' "$PRODUCER"; then
  ok "the producer can still state established parity ('PR ⊇ main')"
else
  bad "the gate accepts 'PR ⊇ main' but the producer can no longer emit it — vacuous certificates would be unsatisfiable"
fi

# ── 7. DRIFT-PIN — clause 6: ONE implementation. The TS gate must not
# re-acquire its own copy of the contract (two copies is what drifted).
#
# WHAT IS ALLOWED IS DATA, WHAT IS FORBIDDEN IS A REQUIREMENT. The gate legitimately
# contains one clause line as DATA — the negative-control probe body — and that single
# line is excluded by its own literal (`blocked by the decision: 1`: the probe's
# residual, which no requirement would ever spell). Every other non-comment line that
# names a clause fires, which catches a same-line `.test(...)`, a hoisted constant
# (`const CLAUSE = "blocked by the decision";`) and a split regex.
#
# TWO EARLIER VERSIONS OF THIS PIN WERE WRONG, and their own self-tests below are how
# it was found — worth recording, because each looked reasonable:
#   v1) grepped the bare literal  -> flagged the PROBE (data) as a re-implementation;
#   v2) required the clause and a comparison on the SAME line -> MISSED the hoisted
#       spellings; and then the obvious fix
#   v2b) excluded any line containing `PR failing:` -> MISSED the HISTORICAL
#       re-implementation itself, whose regex spells the whole count clause
#       (`/PR failing:\s*\d+ … unique to this PR:\s*0\b/.test(body)`).
# A THIRD was reported by a confirming review and is the reason for the NORMALIZATION
# below: v3 matched the phrases CONTIGUOUSLY, so a re-implementation that split a
# literal across adjacent fragments (`"blocked by the " + "decision: 0"`, an array
# `.join("")`, or a `\u0020` escape) named the clause while the pin stayed green. The
# line is now folded (whitespace, quotes, `+`, `\u0020`, case) BEFORE matching, so the
# fragments cannot be separated; the alternative spelling of the count clause is
# checked as a FRAGMENT (`uniquetothis`) for the same reason.
# The self-tests below run the pin against exactly those spellings, including the
# historical one and the three split ones, so the pin cannot pass by being unable to
# see what it exists to see.
TS_CODE="$(sed 's://.*::' "$TS_GATE" | grep -v '^[[:space:]]*[*]')"
fold_clause_text() { tr -d ' \t' | sed 's/\\u0020//g' | sed 's/["\x27+]//g' | tr 'A-Z' 'a-z'; }
pin_flags() { printf '%s\n' "$1" | fold_clause_text | grep -E 'blocked.{0,40}by.{0,40}the.{0,40}decision|unique.{0,20}to.{0,20}this' | grep -vqE 'blocked.{0,40}by.{0,40}the.{0,40}decision.{0,3}1'; }
if pin_flags "$TS_CODE"; then
  bad "the TS gate re-implements the contract's clauses instead of delegating (clause 6)"
else
  ok "the TS gate holds no copy of the clause set (clause 6: one implementation)"
fi
while IFS= read -r probe_line; do
  [ -n "$probe_line" ] || continue
  if pin_flags "$probe_line"; then
    ok "the clause-6 pin catches a re-implementation spelled: ${probe_line:0:48}"
  else
    bad "the clause-6 pin MISSES a re-implementation spelled: $probe_line"
  fi
done <<'PROBES'
  if (/PR failing:\s*\d+\s*\|\s*main failing:\s*\d+\s*\|\s*unique to this PR:\s*0\b/.test(body)) {
const CLAUSE = "blocked by the decision";
const RESIDUAL_RE = /blocked by the decision:\s*0/;
body.includes("blocked by the decision: 0")
const SPLIT = "blocked by the " + "decision: 0";
const SPLIT2 = ["blocked by the ", "decision"].join("");
const SPLIT3 = "blocked by the\u0020decision: 0";
const REGEXSP = /blocked\s+by\s+the\s+decision:\s*0/;
const HEXSP = "blocked\x20by\x20the\x20decision: 0";
const FROMCC = "blocked" + String.fromCharCode(32) + "by" + String.fromCharCode(32) + "the decision: 0";
PROBES
# …and the probe DATA line must NOT fire (it is the one legitimate occurrence).
if pin_flags '    "\nPR failing: 1 | main failing: 0 | blocked by the decision: 1" +'; then
  bad "the clause-6 pin flags the negative-control PROBE (data) as a re-implementation — a false positive that would block every legitimate change to it"
else
  ok "the clause-6 pin allows the one legitimate occurrence (the probe's data line)"
fi
if grep -qF 'verify-admin-merge-evidence.sh' "$TS_GATE"; then
  ok "the TS gate references the single implementation (verify-admin-merge-evidence.sh)"
else
  bad "the TS gate does not delegate to scripts/verify-admin-merge-evidence.sh (clause 6)"
fi

echo
if [ "$F" -eq 0 ]; then echo "✅ all $P admin-merge evidence-contract test(s) passed"; exit 0; fi
echo "❌ $F of $((F+P)) admin-merge evidence-contract test(s) failed"; exit 1
