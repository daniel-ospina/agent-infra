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
#  that the producer moved. So the load-bearing fixtures here are a REAL captured
#  certificate, and the suite asserts the GATE's required literals against it.
#
#  Sets its own exit code so it can run standalone or inside another job.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# The versions under test default to this worktree. Both are overridable so the
# suite can be pointed at the PRE-FIX revision and shown to REDDEN — that is how
# "every declared class has a test that fails against the revision before its
# fix" is demonstrated rather than asserted:
#   VERIFIER_UNDER_TEST=$(git show <base>:scripts/verify-admin-merge-evidence.sh) …
# The knobs are for producing evidence; CI runs the defaults.
VERIFIER="${VERIFIER_UNDER_TEST:-$ROOT/scripts/verify-admin-merge-evidence.sh}"
TS_GATE="${TS_GATE_UNDER_TEST:-$ROOT/extensions/review-enforcer/index.ts}"
PRODUCER="$ROOT/scripts/admin-merge.sh"
NEG="$HERE/captured-1406-vacuous-parity-not-established.md"
POS="$HERE/captured-1406-parity-established.md"
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
# It is VACUOUS (measured sets runs=0) and its parity line reads NOT ESTABLISHED
# — the #1319 rule says a vacuous comparison is not comparable without parity,
# so this must NOT certify even though every other clause is present.
if certifies "$NEG"; then
  bad "a VACUOUS comparison with 'lane parity: NOT ESTABLISHED' CERTIFIED (clause 5 fail-open)"
else
  ok "a vacuous comparison with parity NOT ESTABLISHED does NOT certify (clause 5)"
fi

# ── 2. a real comparison, zero residual → certifies ─────────────────────────
if certifies "$POS"; then
  ok "the same envelope as a NON-vacuous comparison CERTIFIES (clause 4)"
else
  bad "a real, non-vacuous certificate was REFUSED — the gate requires something the producer does not emit"
fi

# ── 3. the vacuous case WITH established parity → certifies ─────────────────
{ cat "$POS"
  printf '   measured sets: PR failing runs=0 | main failing runs=0 (lane: ci.yml)\n'
  printf '   lane parity: PR ⊇ main — the PR executed every test shard main'"'"'s lane executed (parity family: test*; 1 shard(s) on the PR side, 1 on main)\n'
} > "$TMP/vac-par.md"
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

# ── 5. DRIFT-PIN — every literal phrase the GATE requires by `contains(...)` must
# EXIST in evidence the producer really writes. This is the instrument the
# six-day outage needed: it extracts the required literals FROM the verifier (not
# from a copy of them) and asserts each is present in a body the producer really
# wrote. Had it existed on 2026-09-17 it would have reddened on the rename.
#
# The BOUNDED clauses (the two zero clauses and the parity line) are regexes, so
# they are not extractable as literal phrases; they are covered instead by the
# behaviour tests above (POS certifies, and each boundary mutation refuses) plus
# the producer greps in §6. That split is stated rather than left implicit,
# because a pin that silently checks less than it appears to is worse than none.
#
# SCOPE MATTERS, and this is the same rule as the refusal vocabulary above: a
# literal is only required in the state it describes. `lane parity: PR ⊇ main` is
# required only when the comparison is VACUOUS, so checking it against the
# non-vacuous POS body would be a false alarm — the error this pin exists to
# catch, made by the pin itself. So the reference is the UNION of the two
# legitimate states, both derived from the same real capture.
cat "$POS" "$TMP/vac-par.md" > "$TMP/states.md"
LITS="$(sed -n '/^CLAUSE_FILTER=/,/^jq_program=/p' "$VERIFIER" | grep -o 'contains("[^"]*")' | sed 's/^contains("//; s/")$//' | grep -v '\$' | sort -u)"
[ -n "$LITS" ] || bad "could not extract any required literal from the verifier's CLAUSE_FILTER (the extraction is broken, so this pin proves nothing)"
# The extraction is scoped to the FILTER ASSIGNMENT, not the file: the file's
# comments quote the retired clause to explain the rename, and a pin that reads
# prose reports requirements the code does not have. (This pin made exactly that
# mistake on its first run — it picked the literal up out of the explanatory
# comment. Same rule as the refusal vocabulary: match the state, not the prose.)
echo "    (pinning $(printf '%s\n' "$LITS" | grep -c .) literal phrase(s) extracted from the CLAUSE_FILTER)"
while IFS= read -r lit; do
  [ -n "$lit" ] || continue
  if grep -qF "$lit" "$TMP/states.md"; then
    ok "required literal is present in real evidence: ${lit:0:52}"
  else
    bad "the gate REQUIRES a literal no real evidence contains: '$lit' (this is the #1388 class)"
  fi
done <<< "$LITS"

# ── 6. DRIFT-PIN — the producer still emits the clause the gate requires, and
# the gate requires the producer's spelling (both directions, so neither can
# move alone).
if grep -qF 'blocked by the decision: 0' "$PRODUCER"; then
  ok "the producer still emits 'blocked by the decision: 0'"
else
  bad "the producer no longer emits the clause-4 spelling the gate requires"
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
# comparison is refused whether or not it was comparable.
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
