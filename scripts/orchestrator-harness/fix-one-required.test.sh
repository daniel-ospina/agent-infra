#!/usr/bin/env bash
# fix-one-required.test.sh — a red check is called REQUIRED only when the repo requires it (#3461).
#
# THE MEASURED FAILURE. `fix-one.sh` rendered EVERY red check under the heading
# `=== failing required check: <c> ===` and its fixer prompt ASSERTED "REQUIRED CI CHECKS ARE ALSO
# FAILING". Nothing in the file read branch protection (`grep -c required_status_checks` was 0), so
# the word "required" was asserted, never computed. Measured on tortoise PR #10726 (head 6bbd1f2742ea,
# 2026-11-05): the only red group was `github-actions/redis-guard` — absent from main's required set,
# and a job that had died in `Set up job` with 0 steps, so it carried no verdict on the tree either.
# A capped fix lane was dispatched on a premise that was false for the PR and could not have
# unblocked the rail; the repo's own workflow header had already corrected the same claim in writing.
#
# WHAT IS PINNED (all arms drive the SHIPPED block, extracted from fix-one.sh between its own
# `FIX-ONE-REQ-SPLIT` markers — never a re-typed copy of the rule):
#   1  a head whose ONLY red is a NON-required check → no `=== failing required check:` heading at
#      all; the check is reported as NON-required and named in the log (reported, never dropped).
#   2  a red REQUIRED check still gets `=== failing required check:` (the gate is not weakened).
#   3  both at once → two headings, the REQUIRED one first.
#   4  an UNREADABLE contract (resolver fallback) → every heading is `required-status UNKNOWN`, the
#      read is recorded, and NOTHING is demoted to advisory (fail closed in the direction that
#      matters here: a blocking red must not become informational).
#   5  a resolver that answers with NO NAMES is UNKNOWN too, not "nothing is required".
#   6  the `_bare_is` normalisation (shared with lane-merge.sh) still matches a suffixed surface name
#      (`agent-infra-ci / lint`) against the required context (`lint`).
#   7  the resolved set is NOT handed to the child merge-one.sh as an operator `REQ` override, and a
#      genuine operator override still is (the exported-override bypass lane-merge.sh documents).
#   8  the fixer prompt no longer asserts "REQUIRED" unconditionally, and fix-one.sh still parses.
#
# FAILS ON PRE-FIX CODE: the extracted block does not exist there (`FIX-ONE-REQ-SPLIT:BEGIN` absent),
# so arm 0 refuses rather than passing vacuously — and the pre-fix renderer emits
# `=== failing required check:` for a non-required red, which arm 1 reads directly.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
FIXER="$HERE/fix-one.sh"
[ -r "$FIXER" ] || { echo "FATAL: fix-one.sh not found beside this test ($FIXER)" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/fix-one-required.XXXXXX")"
trap 'rm -rf "$T"' EXIT
pass=0 fail=0
ok()  { printf '  ✅ %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  ❌ %s\n' "$1"; fail=$((fail+1)); }
ck()  { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi; }

# ── 0. extract the SHIPPED block ────────────────────────────────────────────────────────────────
sed -n '/FIX-ONE-REQ-SPLIT:BEGIN/,/FIX-ONE-REQ-SPLIT:END/p' "$FIXER" > "$T/region.sh"
if [ ! -s "$T/region.sh" ]; then
  bad "0) the required/advisory block is not in fix-one.sh (no FIX-ONE-REQ-SPLIT markers) — every arm below would pass vacuously"
  echo "───────────────────────────────────────────────────────────────────"
  echo "❌ fix-one required-vs-advisory suite: 1 failure(s), 0 passed"
  exit 1
fi
ok "0) the block is extractable from fix-one.sh ($(wc -l < "$T/region.sh" | tr -d ' ') lines)"
for needle in 'resolve_required_checks' 'fix_req_is' '_fix_check_section' 'checks_required_unknown'; do
  grep -qF -e "$needle" "$T/region.sh"; ck "0) the extracted block still carries '$needle' (cannot be vacuous)" $?
done

# ── the driver: source the REAL block against a stubbed contract resolver ──────────────────────
# drive <required-names> <req-source> <failing-checks> [<exported REQ before the block>]
# Leaves behind: $T/req_fail $T/adv_fail $T/req_after $T/o/logs/fix-99-failing.txt $T/o/logs/fix-99.log
drive() {
  local want="${1-}" src="${2-}" failing="${3-}" preset="${4-__absent__}" d
  d="$T/run"; rm -rf "$d"; mkdir -p "$d/mod" "$d/o/logs" "$d/o/state"
  cat > "$d/mod/repo-authority.sh" <<STUB
# stub of the ONE contract home: the resolver's in-place REQ/REQ_SOURCE contract, nothing else.
resolve_required_checks() { REQ="$want"; REQ_SOURCE="$src"; return 0; }
STUB
  : > "$d/o/logs/fix-99-failing.txt"; : > "$d/o/logs/fix-99.log"
  (
    set -u
    SELF="$d/mod"; O="$d/o"; _FIX_MOD_DIR="$d/mod"
    PR=99; OR=o/r; FAILING_CHECKS="$failing"
    L="$d/o/logs/fix-99"
    if [ "$preset" != "__absent__" ]; then export REQ="$preset"; else unset REQ; fi
    gh() { :; }   # no network, no real gh: the contract read is the stub above
    . "$T/region.sh" >/dev/null 2>&1
    printf '%s\n' "${FIX_REQ_FAIL-}" > "$d/req_fail"
    printf '%s\n' "${FIX_ADV_FAIL-}" > "$d/adv_fail"
    printf '%s\n' "${REQ-__unset__}"   > "$d/req_after"
  )
  REQ_FAIL="$(cat "$T/run/req_fail")"; ADV_FAIL="$(cat "$T/run/adv_fail")"
  REQ_AFTER="$(cat "$T/run/req_after")"
  FFAIL="$T/run/o/logs/fix-99-failing.txt"; FLOG="$T/run/o/logs/fix-99.log"
}

printf '── 1. the ONLY red is a NON-required check: reported as advisory, NEVER as required ──\n'
drive "pipeline-compliance" protection "bash-suites"
ck "1) the non-required red is NOT in the required set" $([ -z "$REQ_FAIL" ] && echo 0 || echo 1)
ck "1) …and IS in the advisory set (named, not dropped): got [$ADV_FAIL]" $([ "$ADV_FAIL" = "bash-suites" ] && echo 0 || echo 1)
ck "1) no '=== failing required check:' heading is written for it" $(grep -q '^=== failing required check:' "$FFAIL" && echo 1 || echo 0)
ck "1) the heading names the advisory class and this repo's contract" \
   $(grep -q "^=== failing NON-required check (not one of o/r required contexts" "$FFAIL" && grep -q 'bash-suites' "$FFAIL" && echo 0 || echo 1)
ck "1) the log REPORTS it instead of hiding it ($(head -1 "$FLOG" 2>/dev/null | cut -c1-40)…)" \
   $(grep -q 'ALSO RED and NOT required by o/r' "$FLOG" && grep -q 'bash-suites' "$FLOG" && echo 0 || echo 1)
ck "1) the resolved set does not leak onward as an operator REQ override: got [$REQ_AFTER]" $([ -z "$REQ_AFTER" ] && echo 0 || echo 1)

printf '── 2. a red REQUIRED check is still 'required' (the gate is not weakened) ──\n'
drive "pipeline-compliance" protection "pipeline-compliance"
ck "2) the required red lands in the REQUIRED set" $([ "$REQ_FAIL" = "pipeline-compliance" ] && echo 0 || echo 1)
ck "2) the advisory set is empty" $([ -z "$ADV_FAIL" ] && echo 0 || echo 1)
ck "2) its heading is '=== failing required check: pipeline-compliance ==='" \
   $(grep -qxF '=== failing required check: pipeline-compliance ===' "$FFAIL" && echo 0 || echo 1)
ck "2) nothing is labelled NON-required" $(grep -q 'NON-required' "$FFAIL" && echo 1 || echo 0)
ck "2) no advisory line is logged" $(grep -q 'ALSO RED and NOT required' "$FLOG" && echo 1 || echo 0)

printf '── 3. both at once: two headings, the REQUIRED one first ──\n'
drive "pipeline-compliance" protection "bash-suites pipeline-compliance"
ck "3) the split is [required]=pipeline-compliance [advisory]=bash-suites" \
   $([ "$REQ_FAIL" = "pipeline-compliance" ] && [ "$ADV_FAIL" = "bash-suites" ] && echo 0 || echo 1)
ck "3) BOTH headings are present" \
   $(grep -q '^=== failing required check: pipeline-compliance ===' "$FFAIL" && grep -q 'NON-required.*bash-suites' "$FFAIL" && echo 0 || echo 1)
ck "3) the REQUIRED heading precedes the advisory one (the fixer meets the blocking red first)" \
   $([ "$(grep -n '^=== failing ' "$FFAIL" | head -1 | grep -c 'failing required check')" = 1 ] && echo 0 || echo 1)

printf '── 4. an UNREADABLE contract: EVERY heading is UNKNOWN, nothing is demoted ──\n'
drive "ai-review-gate python-ci-gate docs" fallback "bash-suites"
ck "4) the fallback red is NOT demoted to advisory: got [$ADV_FAIL]" $([ -z "$ADV_FAIL" ] && echo 0 || echo 1)
ck "4) its heading claims NOTHING about blocking (no 'failing required check', no 'NON-required')" \
   $(grep -qE '^=== failing (required check|NON-required)' "$FFAIL" && echo 1 || echo 0)
ck "4) its heading is 'required-status UNKNOWN'" $(grep -q '^=== failing check (required-status UNKNOWN): bash-suites ===$' "$FFAIL" && echo 0 || echo 1)
ck "4) the read failure is RECORDED in the file the fixer reads" $(grep -q 'could not be read' "$FFAIL" && echo 0 || echo 1)
ck "4) …and in the log" $(grep -q 'required-check contract UNKNOWN' "$FLOG" && echo 0 || echo 1)
ck "4) the FALLBACK list is not handed to the child as an operator override: got [$REQ_AFTER]" $([ -z "$REQ_AFTER" ] && echo 0 || echo 1)

printf '── 5. a resolver that answers with NO NAMES is UNKNOWN, not "nothing is required" ──\n'
drive "" protection "bash-suites"
ck "5) no red is demoted to advisory on an empty contract" $([ -z "$ADV_FAIL" ] && echo 0 || echo 1)
ck "5) the heading is UNKNOWN" $(grep -q 'required-status UNKNOWN' "$FFAIL" && echo 0 || echo 1)
ck "5) the empty answer is named as such" $(grep -q 'returned NO NAMES' "$FFAIL" && echo 0 || echo 1)

printf '── 6. the shared _bare_is normalisation: a suffixed surface name matches its required parent ──\n'
sed -n '/^fix_req_is()/,/^}/p' "$FIXER" > "$T/matcher.sh"
ck "6) the matcher is extractable from fix-one.sh" $([ -s "$T/matcher.sh" ] && echo 0 || echo 1)
( set -u; FIX_REQ="lint"; checks_required_unknown=""; . "$T/matcher.sh"
  fix_req_is "lint" && fix_req_is "agent-infra-ci / lint" && ! fix_req_is "bash-suites" && ! fix_req_is "agent-infra-ci / bash" )
ck "6) 'agent-infra-ci / lint' IS required for contract 'lint'; 'bash-suites' is not" $?

printf '── 7. an operator override still passes through, and only when the resolver accepted it ──\n'
drive "from-env" env "bash-suites" "operator-list"
ck "7) a resolver-accepted override reaches the child unchanged: got [$REQ_AFTER]" $([ "$REQ_AFTER" = "operator-list" ] && echo 0 || echo 1)
drive "from-env" fallback "bash-suites" "operator-list"
ck "7) an override the resolver DISCARDED (fallback) does not reach the child: got [$REQ_AFTER]" $([ -z "$REQ_AFTER" ] && echo 0 || echo 1)

printf '── 8. the fixer prompt asserts nothing it did not compute, and the script still parses ──\n'
ck "8) the prompt no longer asserts 'REQUIRED CI CHECKS ARE ALSO FAILING'" \
   $(grep -q 'REQUIRED CI CHECKS ARE ALSO FAILING' <(grep -v '^#' "$FIXER") && echo 1 || echo 0)
ck "8) it names the NON-required heading as non-blocking" $(grep -q 'does NOT block the merge' "$FIXER" && echo 0 || echo 1)
ck "8) it keeps the UNKNOWN arm honest ('required-status UNKNOWN')" $(grep -q 'failing check (required-status UNKNOWN)' "$FIXER" && echo 0 || echo 1)
if /bin/bash -n "$FIXER" 2>"$T/n.log"; then ok "8) bash -n passes"; else bad "8) bash -n fails: $(head -2 "$T/n.log" | tr '\n' ' ')"; fi

echo "───────────────────────────────────────────────────────────────────"
if [ "$fail" -eq 0 ]; then echo "✅ fix-one required-vs-advisory suite: all $pass assertions passed"; else echo "❌ fix-one required-vs-advisory suite: $fail failure(s), $pass passed"; fi
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
