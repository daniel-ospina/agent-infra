#!/usr/bin/env bash
# gate-policy.test.sh — the removal of the permanent gate bypass, and what must survive it (#2319).
#
# FOUR things are asserted, and each one exists because its absence would be invisible:
#
#  1. NO LIVE CARRIER EXPORTS THE SKIP FLAGS ANY MORE. The flags may appear in exactly ONE file
#     (`gate-policy.sh`, which decides them). This is the red-on-reintroduction guard: the defect was
#     five carriers each exporting a permanent bypass, so the regression to catch is not "someone
#     deleted a line" but "someone added one back".
#  2. WITH THE SATISFIER PRESENT, THE GATES ARE ENFORCED (nothing exported).
#  3. WITH THE SATISFIER ABSENT, THE BYPASS IS AUDITED — the two flags are exported AND one line
#     naming #2319, the carrier and the missing components is appended to the audit log. That is what
#     turns a permanent, invisible default into a dated, attributed state that flips by itself.
#  4. THE THREE REFUSALS THE REMOVAL DEPENDS ON STILL EXIST IN THE LIVE GATE SOURCES, and the suites
#     that exercise them are WIRED INTO CI. ⛔ This half is a text-and-wiring assertion on purpose:
#     the gate extensions import `@earendil-works/pi-coding-agent`, which a fresh worktree does not
#     have, so a behavioural run is attempted (bounded) and SKIPPED WITH THE REASON when it cannot
#     happen here — and the wiring assertion is what stops "the CI suite runs it" from being a thing
#     someone has to remember.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
POLICY="$HERE/gate-policy.sh"
CARRIERS=(orch-loop lane fix-one merge-one nonblocking-dispatch)
PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf 'PASS %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"; }
skip() { SKIP=$((SKIP+1)); printf 'SKIP %s\n' "$1"; }

[ -f "$POLICY" ] || { echo "❌ gate-policy.sh missing"; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/gate-policy-test-XXXXXX")" || { echo "❌ mktemp"; exit 1; }
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ── 1. no live carrier decides the flags for itself.
offenders=""
for c in "${CARRIERS[@]}"; do
  f="$HERE/$c.sh"
  [ -f "$f" ] || { offenders="$offenders missing:$c"; continue; }
  # an EXPORT of either flag outside gate-policy.sh is the defect
  if grep -nE '^[[:space:]]*export[[:space:]].*(AGENT_SKIP_REVIEW_GATE|ELDATO_SKIP_VGATE)' "$f" >/dev/null 2>&1; then
    offenders="$offenders $c"
  fi
  # ...and every carrier must actually route through the policy
  grep -q 'apply_gate_policy' "$f" || offenders="$offenders no-policy:$c"
done
if [ -z "$offenders" ]; then
  ok "carriers: none of ${CARRIERS[*]} exports the skip flags; all route through apply_gate_policy"
else
  bad "carriers: still bypassing outside the policy:$offenders"
fi
# The retired/ scripts are NOT carriers (nothing invokes them); say so rather than let a reader think
# the census missed them.
skip "retired/*.sh still carry the old export — out of scope BY DEFINITION (nothing invokes them; the census is the INVOKER set, not a grep of the tree)"

# ── 2/3. the two decisions, hermetically.
# A satisfier fixture: a repo carrying both halves the probe looks for.
FIX="$TMP/fixrepo"
mkdir -p "$FIX/scripts" "$FIX/extensions/verification-gate"
printf 'record-review stub\n' > "$FIX/scripts/record-review.sh"
printf '#!/usr/bin/env bash\necho review-pr\n' > "$FIX/scripts/review-pr.sh"
chmod +x "$FIX/scripts/review-pr.sh"
printf '#!/usr/bin/env bash\ncase "$1" in\n  record) : ;;\nesac\n' > "$FIX/scripts/vgate.sh"
chmod +x "$FIX/scripts/vgate.sh"

# 2. satisfier present -> ENFORCED.
out="$(GP_REPO="$FIX" GP_LOG="$TMP/enforced.jsonl" GP_QUIET=0 bash -c '
  . "$1" || exit 78
  apply_gate_policy test-carrier
  printf "skip_review=%s skip_vgate=%s mode=%s\n" "${AGENT_SKIP_REVIEW_GATE:-none}" "${ELDATO_SKIP_VGATE:-none}" "$GP_MODE"
' _ "$POLICY" 2>&1)"
if printf '%s' "$out" | grep -q 'skip_review=none skip_vgate=none mode=enforced'; then
  ok "satisfiable: BOTH gates stay ON (nothing exported) — the removal arrives with the satisfier"
else
  bad "satisfiable: expected no export + mode=enforced, got: $out"
fi
if [ -f "$TMP/enforced.jsonl" ] && grep -q '"mode":"enforced"' "$TMP/enforced.jsonl"; then
  ok "satisfiable: the decision is recorded (not a silent no-op)"
else
  bad "satisfiable: no audit line for the enforced decision"
fi


# 2b. THE FLEET-STOPPING REGRESSION (found by review). Existence is not capability: a zero-byte,
# non-executable `review-pr.sh` used to flip the probe to "satisfiable", which UNSETS the skips — so
# every lane on every box would be refused at its first push. The probe must keep bypassing + auditing.
FAKE="$TMP/fakerepo"
mkdir -p "$FAKE/scripts"
: > "$FAKE/scripts/record-review.sh"          # exists, empty, not executable
: > "$FAKE/scripts/review-pr.sh"              # exists, empty, not executable
printf 'not a recorder\n' > "$FAKE/scripts/vgate.sh"
out="$(GP_REPO="$FAKE" GP_LOG="$TMP/fake.jsonl" GP_QUIET=0 bash -c '
  . "$1" || exit 78
  apply_gate_policy test-carrier
  printf "skip_review=%s skip_vgate=%s mode=%s\n" "${AGENT_SKIP_REVIEW_GATE:-none}" "${ELDATO_SKIP_VGATE:-none}" "$GP_MODE"
' _ "$POLICY" 2>&1)"
if printf '%s' "$out" | grep -q 'skip_review=1 skip_vgate=1 mode=bypass-audited'; then
  ok "decoy: files that EXIST but cannot work do NOT enforce the gates (existence is not capability)"
else
  bad "decoy: a name-only satisfier flipped the probe to enforced — that stops every lane: $out"
fi
if ! grep -q '"mode":"enforced"' "$TMP/fake.jsonl" 2>/dev/null; then
  ok "decoy: and the audit line does NOT claim enforced"
else
  bad "decoy: the audit claims enforced for a name-only satisfier"
fi

# 2c. AN INHERITED SKIP FLAG IS REMOVED when the gates are enforceable (README §5.4) — the arm that
# would pass even if the `unset` were deleted did not exist (found by review).
out="$(AGENT_SKIP_REVIEW_GATE=1 ELDATO_SKIP_VGATE=1 GP_REPO="$FIX" GP_LOG="$TMP/ambient.jsonl" GP_QUIET=1 bash -c '
  . "$1" || exit 78
  apply_gate_policy test-carrier
  printf "skip_review=%s skip_vgate=%s ambient_cleared=%s\n" "${AGENT_SKIP_REVIEW_GATE:-none}" "${ELDATO_SKIP_VGATE:-none}" "$GP_AMBIENT_CLEARED"
' _ "$POLICY" 2>&1)"
if printf '%s' "$out" | grep -q 'skip_review=none skip_vgate=none ambient_cleared=1'; then
  ok "ambient: an INHERITED skip flag is removed from the carrier's environment (the stale hatch cannot outlive its reason)"
else
  bad "ambient: an inherited skip flag survived the enforced decision: $out"
fi
if grep -q '"ambient_cleared":1' "$TMP/ambient.jsonl"; then
  ok "ambient: the removal is recorded (ambient_cleared=1), not silent"
else
  bad "ambient: the audit does not record the ambient removal"
fi

# 3. satisfier absent -> AUDITED bypass, naming #2319 and what is missing.
EMPTY="$TMP/empty-repo"
mkdir -p "$EMPTY/scripts"
out="$(GP_REPO="$EMPTY" GP_LOG="$TMP/bypass.jsonl" GP_QUIET=0 bash -c '
  . "$1" || exit 78
  apply_gate_policy test-carrier
  printf "skip_review=%s skip_vgate=%s mode=%s\n" "${AGENT_SKIP_REVIEW_GATE:-none}" "${ELDATO_SKIP_VGATE:-none}" "$GP_MODE"
' _ "$POLICY" 2>&1)"
if printf '%s' "$out" | grep -q 'skip_review=1 skip_vgate=1 mode=bypass-audited'; then
  ok "unsatisfiable: the flags ARE exported — deliberately, so the fleet keeps running"
else
  bad "unsatisfiable: expected the audited bypass, got: $out"
fi
if [ -f "$TMP/bypass.jsonl" ] && grep -q 'agent-infra#2319' "$TMP/bypass.jsonl" && grep -q '"carrier":"test-carrier"' "$TMP/bypass.jsonl"; then
  ok "unsatisfiable: the bypass is RECORDED with the issue, the carrier and the missing components"
else
  bad "unsatisfiable: no audit line naming #2319 / the carrier"
fi
if printf '%s' "$out" | grep -q 'review-pr.sh(#2288)'; then
  ok "unsatisfiable: the reason names the absent satisfier (review-pr.sh / #2288) rather than 'policy'"
else
  bad "unsatisfiable: the refusal does not name what is missing: $out"
fi

# ── 4. the refusals the removal depends on still exist, and their suites are wired into CI.
# (a) a lane with NO reviewer cannot land.
if grep -q 'Blocked — no reviewers dispatched' "$REPO/extensions/review-enforcer/index.ts"; then
  ok "(a) no-reviewer: the gate still refuses git operations with no reviewer dispatch"
else
  bad "(a) no-reviewer: the refusal text is gone from extensions/review-enforcer/index.ts"
fi
# ...and the reason a LANE cannot satisfy it today, which is why the bypass is still audited:
if grep -q 'you have NO .task. tool' "$HERE/lane.sh"; then
  ok "(a) no-reviewer: lane.sh still tells the lane it has no \`task\` tool — the measured reason the removal is sequenced, not instant"
else
  bad "(a) no-reviewer: lane.sh no longer states the no-task-tool fact this sequencing rests on"
fi

# (b) a same-call state mutation + commit is refused ('in-batch mutation chain').
if grep -q 'in-batch mutation chain' "$REPO/extensions/verification-gate/index.ts"; then
  ok "(b) in-batch chain: the refusal is still in extensions/verification-gate/index.ts"
else
  bad "(b) in-batch chain: the refusal is gone"
fi
if grep -q 'commitChainMutationClass' "$REPO/extensions/verification-gate/index.test.ts"; then
  ok "(b) in-batch chain: exercised by extensions/verification-gate/index.test.ts"
else
  bad "(b) in-batch chain: the gate test no longer exercises it"
fi

# (c) a stale verification is refused ('mismatched').
if grep -q 'mismatched' "$REPO/extensions/verification-gate/index.ts"; then
  ok "(c) mismatched: the stale-verification refusal is still in extensions/verification-gate/index.ts"
else
  bad "(c) mismatched: the refusal is gone"
fi
# ⛔ THE FIRST VERSION OF THIS ARM GREPPED THE LITERAL `mismatched` AND REPORTED A COVERAGE GAP. That was
# WRONG (found by review): the gate's suite exercises the same refusal under its own reason name,
# `head_mismatch` (`extensions/verification-gate/index.test.ts:1059`, "same-repo stale checkout -> skip"),
# so the "gap" was a trailing-`ed` artifact and the skip told a reader a required property was uncovered.
# It is asserted as a hard PASS on the name the suite actually uses.
if grep -q 'mismatched' "$REPO/extensions/verification-gate/index.test.ts" \
   || grep -q 'head_mismatch' "$REPO/extensions/verification-gate/index.test.ts"; then
  ok "(c) stale verification: exercised by the gate test (mismatched / head_mismatch)"
else
  bad "(c) stale verification: no test in the gate's own suite exercises the stale-head refusal"
fi

# The suites that carry (a) must be WIRED, or "CI runs it" is a memory, not a mechanism.
if grep -q 'extensions/review-enforcer/index.test.ts' "$REPO/.github/workflows/ci-main.yml"; then
  ok "wiring: extensions/review-enforcer/index.test.ts is invoked by ci-main.yml (so (a) runs somewhere)"
else
  bad "wiring: the review-enforcer suite is named in no workflow step — (a) would be covered by nothing"
fi

# A bounded behavioural attempt, when this box can resolve the extension's dependency.
if node -e 'require.resolve("@earendil-works/pi-coding-agent")' >/dev/null 2>&1; then
  if NODE_ENV=test npx --no-install tsx "$REPO/extensions/review-enforcer/index.test.ts" >"$TMP/rev.log" 2>&1; then
    ok "behavioural: extensions/review-enforcer/index.test.ts ran here and passed"
  else
    bad "behavioural: extensions/review-enforcer/index.test.ts FAILED here (see below)"
    tail -20 "$TMP/rev.log" | sed 's/^/    /'
  fi
else
  skip "behavioural: extensions/review-enforcer/index.test.ts NOT run here — @earendil-works/pi-coding-agent is not installed in a fresh worktree (no node_modules); CI installs it, and the wiring arm above asserts the step exists"
fi

printf '\ngate-policy.test: %d passed, %d failed, %d skipped (%s)\n' "$PASS" "$FAIL" "$SKIP" "$(uname -s)"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
