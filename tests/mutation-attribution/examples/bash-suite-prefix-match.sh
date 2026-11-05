#!/usr/bin/env bash
# bash-suite-prefix-match.sh — WORKED EXAMPLE of the contract agent-infra#3442 lands: every new
# assertion that claims to protect a behaviour ships with a mutant that REVERTS that behaviour, and the
# mutant must redden THAT assertion (not some other row).
#
# WHY THIS SHAPE AND NOT A HYPOTHETICAL. It is #3368's measured failure, reduced to its bones: the
# pre-fix code matched a reason by PREFIX, so `reason=pin-tree` was accepted where the fix required
# `reason=pin-tree-shape`. Two assertions were added (G15a, G15b), both passed, and BOTH stayed green
# when the whole record-based probe that productionised them was deleted — a prefix match is satisfied
# by the backstop, so the assertion looked like it pinned the fix while pinning nothing.
#
# HOW TO COPY THIS FILE. Three parts, and the third is the part that is usually missing:
#   1. `row_*`   — the production behaviour, reproduced in one line so the example is runnable.
#   2. `assert_*`— the assertions the diff ADDS, each named after what it protects.
#   3. `mutate_*`— ONE mutation per new assertion, reverting exactly the behaviour that assertion
#                  names, plus `run_mutation_leg` which FAILS when a mutation does not redden its row.
#                  ⛔ A mutation that reddens a DIFFERENT row is not a proof. `expect_red` names the
#                  row, and the leg asserts the named row — and only the named row — fails.
#
# Run: bash tests/mutation-attribution/examples/bash-suite-prefix-match.sh
#      bash ... --no-mutations     (the mutant the OUTER suite drives: without the leg, the
#                                   citations are unproven, which is the defect #3442 measured)
set -u
WITH_MUTATIONS=1
[ "${1:-}" = "--no-mutations" ] && WITH_MUTATIONS=0

PASS=0; FAIL=0
ck() { # ck <rc> <message>
  if [ "$1" -eq 0 ]; then printf '  ok   %s\n' "$2"; PASS=$((PASS + 1))
  else printf '  FAIL %s\n' "$2"; FAIL=$((FAIL + 1)); fi
}

# ── 1. the production behaviour (fixed) ────────────────────────────────────────────────────────────
# The fixed rule matches the WHOLE reason, so a differently-suffixed reason is not admitted.
reason_is_pin_tree() { # reason_is_pin_tree <reason>
  [ "${1:-}" = "pin-tree" ]
}
# The pre-fix rule (what the mutation restores): a PREFIX match, which also admits `pin-tree-shape`.
reason_is_pin_tree_prefix() { # reason_is_pin_tree_prefix <reason>
  case "${1:-}" in pin-tree*) return 0 ;; *) return 1 ;; esac
}

# ── 2. the assertions the diff adds ──────────────────────────────────────────────────────────────
# Each is named by the ROW it would redden, so the mutation leg can assert attribution.
row_G15a_exact_reason_is_admitted()  { reason_is_pin_tree "pin-tree" || return 1; }
row_G15b_shape_reason_is_REFUSED()   { reason_is_pin_tree "pin-tree-shape" && return 1; return 0; }

# ── 3. one mutation per assertion ────────────────────────────────────────────────────────────────
# `mutate_<n>_<what>` reverts exactly one behaviour. The leg below runs every mutation and requires
# the row named in `expect` to fail — and requires the OTHER row to keep passing, so a mutation that
# merely breaks the suite cannot masquerade as a proof.
row_fails_under() { # row_fails_under <row-fn> — 0 when the row FAILS
  "$1" >/dev/null 2>&1 && return 1
  return 0
}

# The mutation is `reason_is_pin_tree` widened back to the prefix rule.
mutate_prefix_match_restored() { reason_is_pin_tree() { reason_is_pin_tree_prefix "${1:-}"; }; }

run_mutation_leg() {
  local before_a before_b
  # (a) both rows pass on the FIXED code — without this a mutant could 'redden' a row that was
  #     already failing, which proves nothing about the mutation.
  row_G15a_exact_reason_is_admitted  || { ck 1 "precondition: G15a passes on the fixed code"; return 1; }
  row_G15b_shape_reason_is_REFUSED   || { ck 1 "precondition: G15b passes on the fixed code"; return 1; }
  ck 0 "precondition: both rows pass on the FIXED code (so a red below is the mutation's)"
  mutate_prefix_match_restored
  # (b) the mutation reddens the row that NAMES the behaviour...
  if row_fails_under row_G15b_shape_reason_is_REFUSED; then
    ck 0 "mutant(prefix-match-restored) REDDENS G15b — the row that names the exact-shape rule"
  else
    ck 1 "mutant(prefix-match-restored) did NOT redden G15b — G15b is a VACUOUS pin (this is #3368)"
  fi
  # …and leaves G15a passing, so the red is attributable to the exact-shape rule, not to breakage.
  if row_G15a_exact_reason_is_admitted; then
    ck 0 "…and G15a (a DIFFERENT behaviour) still passes, so the catch is attributable"
  else
    ck 1 "…but G15a also broke — the mutation is too wide to attribute anything"
  fi
}

# ── 4. the suite itself ─────────────────────────────────────────────────────────────────────────
echo "== bash worked example: the #3368 prefix-match shape =="
row_G15a_exact_reason_is_admitted  && ck 0 "G15a: reason=pin-tree is admitted" || ck 1 "G15a: reason=pin-tree is admitted"
row_G15b_shape_reason_is_REFUSED   && ck 0 "G15b: reason=pin-tree-shape is REFUSED" || ck 1 "G15b: reason=pin-tree-shape is REFUSED"
BEFORE_PASS="$PASS"

if [ "$WITH_MUTATIONS" = "1" ]; then
  # ⛔ THIS IS THE LINE WHOSE ABSENCE #3442 MEASURES. Deleting it leaves the two rows above green
  # forever, which is how a guard that cannot fail passes three recorded clean reviews.
  run_mutation_leg
  # The leg must have produced a verdict of its own; a leg that silently did nothing would be the
  # same defect one level up.
  [ "$PASS" -gt "$BEFORE_PASS" ] || ck 1 "the mutation leg contributed assertions (it ran, rather than being skipped)"
else
  # ⛔ A ROW WITHOUT ITS MUTANT IS AN UNPROVEN ROW, and this fixture REFUSES rather than printing the
  # rows green — that refusal is what the outer suite drives to prove the fixture's own contract check
  # is live. A suite that passed with its mutation leg removed would be the defect it documents.
  ck 1 "the MUTATION LEG IS MISSING: this suite asserts rows it cannot show to be falsifiable (that is #3442, exactly)"
fi

echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
