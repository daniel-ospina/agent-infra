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
# the coverage claim is DEMONSTRATED rather than asserted:
#   VERIFIER_UNDER_TEST=$(git show <base>:scripts/verify-admin-merge-evidence.sh) …
# It reddens 5 of its assertions against origin/main, and those 5 are the honest
# extent of what any suite can show against a gate that refuses everything: a
# pre-fix gate that refuses EVERY body carrying the new vocabulary cannot
# distinguish a mutation from a legitimate body, so the per-class mutation tests
# are provable only against the CURRENT revision. The classes are covered by
# tests that FAIL against the fix they belong to, which is stated in the PR body.
VERIFIER="${VERIFIER_UNDER_TEST:-$ROOT/scripts/verify-admin-merge-evidence.sh}"
TS_GATE="${TS_GATE_UNDER_TEST:-$ROOT/extensions/review-enforcer/index.ts}"
PRODUCER="$ROOT/scripts/admin-merge.sh"
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
# (b) the attribution count — a dropped token means a CLIPPED set, not a measured zero.
sed 's/PR=0 | main=0/PR=2 | main=0/' "$POS" > "$TMP/m-attr.md"
if certifies "$TMP/m-attr.md"; then bad "a CLIPPED set (PR=2) still CERTIFIED (clause 5 fail-open)"; else ok "mutation: a CLIPPED set refuses"; fi
# (c) remove the parity line from the vacuous case.
grep -v 'lane parity: PR ⊇ main' "$TMP/vac-par.md" > "$TMP/m-parity.md"
if certifies "$TMP/m-parity.md"; then bad "vacuous WITHOUT parity still CERTIFIED (clause 5 fail-open)"; else ok "mutation: vacuous without parity refuses"; fi
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

# ── 6. DRIFT-PIN — every STATIC literal the filter requires must exist in the
# producer's evidence EMISSION.
#
# THIS SECTION EXISTS BECAUSE A COMMITTED CAPTURE CANNOT NOTICE A LATER PRODUCER
# MOVE. The §5 pin checks the gate's extractable literals against the real capture —
# but the capture is a FILE, so renaming the producer's line leaves §1–§5 green with
# a stale fixture: the six-day outage all over again. The literals are therefore
# pinned against the producer itself.
#
# SCOPED TO THE EMISSION BLOCK, NOT THE FILE, and that scoping is the fix for a gap
# a review round reproduced: a file-wide grep is satisfied by the producer's PROSE.
# `main failing:`, `PR failing:` and `blocked by the decision: 0` all appear in the
# producer's comments and in its log lines (e.g. :257, :2667, :3421), so renaming
# the ONE line that posts evidence left this section green while the gate would have
# refused every real certificate — every admin merge blocked fleet-wide with all
# suites green, which is the failure this whole change is about. The evidence body
# is built by `build_evidence()`, so that is what is searched.
#
# The same reproduction also showed the marker pin was loose by one character:
# grepping `<!-- admin-merge-safety` accepted a rename to
# `<!-- admin-merge-safety-X `. The pin now includes the `: ` suffix.
#
# The parity pair is pinned at its own two sites — the assignment that builds the
# positive value and the line that emits it — because neither lives in
# `build_evidence()`.
emission_block() { sed -n '/^build_evidence()/,/^}/p' "$1"; }
producer_pin_missing() {  # prints the first missing requirement, or nothing when OK
  local f="$1" blk
  blk="$(emission_block "$f")"
  [ -n "$blk" ] || { printf 'build_evidence() block not found\n'; return; }
  local lit
  for lit in '<!-- admin-merge-safety: ' 'PR head: ' 'main compared (union of ' 'PR failing: ' 'main failing: ' 'blocked by the decision: 0'; do
    if ! printf '%s' "$blk" | grep -qF "$lit"; then printf '%s\n' "$lit"; return; fi
  done
  grep -qF 'lane parity: $parity_evidence' "$f" || { printf 'lane parity: $parity_evidence\n'; return; }
  grep -qF 'parity_evidence="PR ⊇ main' "$f" || { printf 'parity_evidence="PR ⊇ main\n'; return; }
  # The attribution clause requires `PR=0 | main=0.`; its static shape is built in
  # `attribution_line`, so it is pinned there rather than by a file-wide grep.
  grep -qF 'Attribution — FAILED tokens DROPPED by the parser (not test ids, so NEVER in a failing set): PR=${pr_drops} | main=${main_drops}.' "$f" \
    || { printf 'the attribution line\n'; return; }
}
if miss="$(producer_pin_missing "$PRODUCER")"; [ -z "$miss" ]; then
  ok "every static literal the filter requires is present in the producer's evidence EMISSION"
else
  bad "the gate requires '$miss' and the producer's evidence emission no longer contains it (the #1388 class — a committed capture cannot notice this)"
fi
# …and the pin is pinned: a renamed EMISSION (not prose) must be caught by it.
# This is the reviewer's reproduction, kept as a test so the looseness cannot return.
sed 's/PR failing: %s | main failing: %s/PR failing: %s | main failure: %s/' "$PRODUCER" > "$TMP/producer-renamed.sh"
if ! grep -qF 'main failure: %s' "$TMP/producer-renamed.sh"; then
  bad "the renamed-emission mutation did not apply, so the self-test below proves nothing"
elif [ -n "$(producer_pin_missing "$TMP/producer-renamed.sh")" ]; then
  ok "the producer pin CATCHES a renamed emission ('$(producer_pin_missing "$TMP/producer-renamed.sh" | head -1)')"
else
  bad "the producer pin MISSES a renamed evidence emission — a file-wide grep would too (a reviewer reproduced exactly this)"
fi
# Scope to the CLAUSE FILTER, not the file: the verifier's comments DISCUSS the
# retired name to explain the rename, so a file-wide grep reports it as still
# required. Only the filter decides what is accepted.
if printf '%s\n' "$LITS" | grep -qxF 'unique to this PR: 0'; then
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
# The self-tests below run the pin against exactly those spellings, including the
# historical one, so the pin cannot pass by being unable to see what it exists to see.
TS_CODE="$(sed 's://.*::' "$TS_GATE" | grep -v '^[[:space:]]*[*]')"
pin_flags() { printf '%s\n' "$1" | grep -E 'blocked by the decision|unique to this PR' | grep -vq 'blocked by the decision: 1'; }
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
