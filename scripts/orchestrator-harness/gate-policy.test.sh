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
NH="$TMP/nohome"; mkdir -p "$NH"
# A satisfier fixture: a repo carrying both halves the probe looks for.
FIX="$TMP/fixrepo"
mkdir -p "$FIX/scripts" "$FIX/extensions/verification-gate"
# ⛔ `chmod +x` AND A NEUTRAL HOME. The recorder bar is executable+non-empty+parseable, so a stub
# without the mode bit made these four arms pass ONLY because this box's own
# `~/.pi/agent/scripts/record-review.sh` satisfied the probe — they would all FAIL on a clean box, and
# this suite runs in CI where `~/.pi/agent` does not exist (found by review, reproduced with a clean HOME).
printf '#!/usr/bin/env bash\nexit 0\n' > "$FIX/scripts/record-review.sh"
chmod +x "$FIX/scripts/record-review.sh"
printf '#!/usr/bin/env bash\necho review-pr\n' > "$FIX/scripts/review-pr.sh"
chmod +x "$FIX/scripts/review-pr.sh"
printf '#!/usr/bin/env bash\ncase "$1" in\n  record) : ;;\nesac\n' > "$FIX/scripts/vgate.sh"
chmod +x "$FIX/scripts/vgate.sh"

# 2. satisfier present -> ENFORCED.
out="$(HOME="$NH" GP_REPO="$FIX" GP_LOG="$TMP/enforced.jsonl" GP_QUIET=0 bash -c '
  . "$1" || exit 78
  apply_gate_policy test-carrier
  printf "skip_review=%s skip_vgate=%s mode=%s\n" "${AGENT_SKIP_REVIEW_GATE:-none}" "${ELDATO_SKIP_VGATE:-none}" "$GP_MODE"
' _ "$POLICY" 2>&1)"
if grep -q 'skip_review=none skip_vgate=none mode=enforced' <<<"$out"; then
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
if grep -q 'skip_review=1 skip_vgate=1 mode=bypass-audited' <<<"$out"; then
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
out="$(HOME="$NH" AGENT_SKIP_REVIEW_GATE=1 ELDATO_SKIP_VGATE=1 GP_REPO="$FIX" GP_LOG="$TMP/ambient.jsonl" GP_QUIET=1 bash -c '
  . "$1" || exit 78
  apply_gate_policy test-carrier
  printf "skip_review=%s skip_vgate=%s ambient_cleared=%s\n" "${AGENT_SKIP_REVIEW_GATE:-none}" "${ELDATO_SKIP_VGATE:-none}" "$GP_AMBIENT_CLEARED"
' _ "$POLICY" 2>&1)"
if grep -q 'skip_review=none skip_vgate=none ambient_cleared=1' <<<"$out"; then
  ok "ambient: an INHERITED skip flag is removed from the carrier's environment (the stale hatch cannot outlive its reason)"
else
  bad "ambient: an inherited skip flag survived the enforced decision: $out"
fi
if grep -q '"ambient_cleared":1' "$TMP/ambient.jsonl"; then
  ok "ambient: the removal is recorded (ambient_cleared=1), not silent"
else
  bad "ambient: the audit does not record the ambient removal"
fi


# ⛔ TWO ISOLATING FIXTURES, ONE PER HALF (review round 2, with mutation evidence). The single "decoy"
# fixture left BOTH halves unsatisfiable, so reverting either half's capability check changed nothing
# and the arm could not fail. Each fixture below makes exactly ONE half name-only, so the matching
# revert turns this suite red:
#   A: seam + recorder are real programs, vgate.sh carries only a COMMENT — review=1, vgate=0
#   B: vgate.sh has a real `record)` arm, review seam does not exist — review=0, vgate=1
# ⛔ HOME IS NEUTRALISED FOR THESE ARMS: this box's real `~/.pi/agent/scripts/record-review.sh` is a
# valid recorder, so an arm that means to test "a zero-byte recorder does not count" must not be served
# by the operator's own home (found exactly that way — the first run of isolating-C passed for the
# wrong reason and reported a false failure).
VA="$TMP/isorepo-a"; mkdir -p "$VA/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$VA/scripts/record-review.sh"; chmod +x "$VA/scripts/record-review.sh"
printf '#!/usr/bin/env bash\necho review-pr\n' > "$VA/scripts/review-pr.sh"; chmod +x "$VA/scripts/review-pr.sh"
printf '#!/usr/bin/env bash\n# TODO: add --record <ref> support (see #2313)\ncase "$1" in status) : ;; esac\n' > "$VA/scripts/vgate.sh"
chmod +x "$VA/scripts/vgate.sh"
probe_a="$(HOME="$NH" GP_REPO="$VA" bash "$POLICY" --probe 2>&1)"
grep -q 'review_satisfiable=1 vgate_satisfiable=0' <<<"$probe_a" \
  && ok "isolating-A: a vgate.sh whose only 'record' is a COMMENT does NOT count as a recorder (review=1, vgate=0)" \
  || bad "isolating-A: expected review=1 vgate=0, got: $probe_a"

VB="$TMP/isorepo-b"; mkdir -p "$VB/scripts"
printf '#!/usr/bin/env bash\ncase "$1" in\n  record) : ;;\nesac\n' > "$VB/scripts/vgate.sh"; chmod +x "$VB/scripts/vgate.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$VB/scripts/record-review.sh"; chmod +x "$VB/scripts/record-review.sh"
probe_b="$(HOME="$NH" GP_REPO="$VB" bash "$POLICY" --probe 2>&1)"
grep -q 'review_satisfiable=0 vgate_satisfiable=1' <<<"$probe_b" \
  && ok "isolating-B: a real record arm counts, and a MISSING seam still holds review at 0 (the halves are independent)" \
  || bad "isolating-B: expected review=0 vgate=1, got: $probe_b"

# ⛔ A ZERO-BYTE RECORDER IS NOT A RECORDER (review round 2: the recorder half was still `-f` only).
VC="$TMP/isorepo-c"; mkdir -p "$VC/scripts"
: > "$VC/scripts/record-review.sh"
printf '#!/usr/bin/env bash\necho review-pr\n' > "$VC/scripts/review-pr.sh"; chmod +x "$VC/scripts/review-pr.sh"
probe_c="$(HOME="$NH" GP_REPO="$VC" bash "$POLICY" --probe 2>&1)"
grep -q 'review_satisfiable=0' <<<"$probe_c" \
  && ok "isolating-C: a zero-byte record-review.sh does not count (existence is not capability, on BOTH halves)" \
  || bad "isolating-C: a zero-byte recorder satisfied the review half: $probe_c"


# ⛔ D: a seam that EXISTS but is not executable/reachable is not a seam (the seam-`-f` revert's own arm).
VE="$TMP/isorepo-e"; mkdir -p "$VE/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$VE/scripts/record-review.sh"; chmod +x "$VE/scripts/record-review.sh"
printf '#!/usr/bin/env bash\necho review-pr\n' > "$VE/scripts/review-pr.sh"   # deliberately NOT executable
probe_e="$(HOME="$NH" GP_REPO="$VE" bash "$POLICY" --probe 2>&1)"
grep -q 'review_satisfiable=0' <<<"$probe_e" \
  && ok "isolating-D: a review-pr.sh that exists but cannot be EXECUTED does not count" \
  || bad "isolating-D: a non-executable review seam satisfied the review half: $probe_e"

# ⛔ THE FLAT-DEPLOY ARM (review round 2: the repo-root fix had no arm). A deploy dir that is NOT a git
# checkout, with the satisfiers SEEDED BESIDE the carrier — the Mac's `$O` shape. It must resolve from
# `$base` alone, and it must SAY that the repo root was unresolved instead of silently looking.
VD="$TMP/flatdeploy"; mkdir -p "$VD"
cp "$POLICY" "$VD/gate-policy.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$VD/record-review.sh"; chmod +x "$VD/record-review.sh"
printf '#!/usr/bin/env bash\necho review-pr\n' > "$VD/review-pr.sh"; chmod +x "$VD/review-pr.sh"
printf '#!/usr/bin/env bash\ncase "$1" in\n  record) : ;;\nesac\n' > "$VD/vgate.sh"; chmod +x "$VD/vgate.sh"
probe_flat="$(bash "$VD/gate-policy.sh" --probe 2>&1)"
grep -q 'review_satisfiable=1 vgate_satisfiable=1' <<<"$probe_flat" \
  && ok "flat-deploy: satisfiers seeded BESIDE the carrier (the Mac's \$O shape, no git root) make both gates satisfiable" \
  || bad "flat-deploy: expected both satisfiable from \$base alone, got: $probe_flat"
grep -q 'note=repo-root-unresolved' <<<"$probe_flat" \
  && ok "flat-deploy: and the unresolved repo root is RECORDED (note=repo-root-unresolved), not silently searched" \
  || bad "flat-deploy: the unresolved repo root is not reported: $probe_flat"


# ⛔ THE LIVING TREE'S OWN VERDICT, WHICH NOTHING ELSE ASSERTED (review, P2). README §5.4's `today`
# column said `review-pr.sh` (#2288) was MISSING, while the file has been executable, non-empty and
# `bash -n`-clean in this tree since 9b80ee4c — so the doc pointed a reader diagnosing "why is the
# bypass still on" at a component that had already shipped. No arm could catch that: the
# "unsatisfiable" fixture is an EMPTY repo, so the probe's answer for the REAL checkout was never
# asserted, and a doc claim with no arm behind it drifts silently on the next merge.
# ⛔ HOME IS NEUTRALISED so the operator's own `~/.pi/agent/scripts/record-review.sh` cannot supply the
# half being measured (same reason as the isolating fixtures above); `GP_REPO` names this checkout, so
# the answer is a property of the tree under test and not of the box.
# ⛔ WHAT GOES RED, AND WHY THAT IS THE POINT: when #2313 lands a real `record)` verb (or the review
# half regresses), this arm fails and sends the author to README §5.4's table. That coupling is
# deliberate — the table is the change's measured claim, and the flip is exactly when it must change.
probe_live="$(HOME="$NH" GP_REPO="$REPO" bash "$POLICY" --probe 2>&1)"
grep -q 'review_satisfiable=1 vgate_satisfiable=0' <<<"$probe_live" \
  && ok "live-tree: this checkout SATISFIES the review half (record-review.sh + review-pr.sh #2288) — the README §5.4 table's measured claim" \
  || bad "live-tree: README §5.4 says the review half is satisfied; the probe says otherwise (update the table WITH the change): $probe_live"
grep -q 'review-pr.sh(#2288)' <<<"$probe_live" \
  && bad "live-tree: the probe still names review-pr.sh(#2288) as missing — that file is in this tree (9b80ee4c), so the seam search is what is broken: $probe_live" \
  || ok "live-tree: the review seam is NOT reported missing (the doc's old claim is now falsifiable in one assertion)"
grep -q 'vgate-record(#2313)' <<<"$probe_live" \
  && ok "live-tree: the bypass is carried by the VGATE half ALONE, and the reason names it (#2313) — deleting the review half first would have stopped every lane at its first push" \
  || bad "live-tree: expected the VGATE half to be the only unsatisfied one, got: $probe_live"


# 3. satisfier absent -> AUDITED bypass, naming #2319 and what is missing.
EMPTY="$TMP/empty-repo"
mkdir -p "$EMPTY/scripts"
out="$(GP_REPO="$EMPTY" GP_LOG="$TMP/bypass.jsonl" GP_QUIET=0 bash -c '
  . "$1" || exit 78
  apply_gate_policy test-carrier
  printf "skip_review=%s skip_vgate=%s mode=%s\n" "${AGENT_SKIP_REVIEW_GATE:-none}" "${ELDATO_SKIP_VGATE:-none}" "$GP_MODE"
' _ "$POLICY" 2>&1)"
if grep -q 'skip_review=1 skip_vgate=1 mode=bypass-audited' <<<"$out"; then
  ok "unsatisfiable: the flags ARE exported — deliberately, so the fleet keeps running"
else
  bad "unsatisfiable: expected the audited bypass, got: $out"
fi
if [ -f "$TMP/bypass.jsonl" ] && grep -q 'agent-infra#2319' "$TMP/bypass.jsonl" && grep -q '"carrier":"test-carrier"' "$TMP/bypass.jsonl"; then
  ok "unsatisfiable: the bypass is RECORDED with the issue, the carrier and the missing components"
else
  bad "unsatisfiable: no audit line naming #2319 / the carrier"
fi
if grep -q 'review-pr.sh(#2288)' <<<"$out"; then
  ok "unsatisfiable: the reason names the absent satisfier (review-pr.sh / #2288) rather than 'policy'"
else
  bad "unsatisfiable: the refusal does not name what is missing: $out"
fi

# 2d. THE AUDIT LINE MUST PARSE. A format/argument misalignment shipped once (a 10th argument inserted
# without a 10th conversion): `host` received the note, `pid` the hostname, and printf re-applied the
# whole format to the leftover `$$` — two objects on one line, unparseable. `grep` could not see it,
# because the first truncated object still matched every assertion (found by review).
if command -v python3 >/dev/null 2>&1 && [ -f "$TMP/bypass.jsonl" ] && [ -s "$TMP/bypass.jsonl" ]; then
  if python3 - "$TMP/bypass.jsonl" "$TMP/enforced.jsonl" <<'PYEOF'
import json, sys
bad = 0
for path in sys.argv[1:]:
    try:
        with open(path) as fh:
            for i, line in enumerate(fh, 1):
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except Exception as exc:
                    print("  %s:%d not JSON: %s" % (path, i, exc)); bad += 1; continue
                if not isinstance(rec.get("pid"), int) or not isinstance(rec.get("host"), str):
                    print("  %s:%d pid/host in the wrong field: %r" % (path, i, rec)); bad += 1
    except FileNotFoundError:
        pass
sys.exit(1 if bad else 0)
PYEOF
  then ok "audit: every emitted line is valid JSON with pid as a number and host as a string"
  else bad "audit: an emitted line is not parseable (format/argument misalignment)"; fi
else
  bad "audit: no audit log to parse — the decision was not recorded"
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
# ⛔ THE RIGHT TEST, NAMED (review round 2): `head_mismatch` in `index.test.ts` is the MERGE-SCOPE stale
# checkout decision, NOT the hash-mismatch refusal this issue is about. The refusal surface (a VERIFIED
# file edited again) is covered by the e2e scenario "post-PASS edit must re-block (hash mismatch,
# fail-closed)" in `index.e2e.test.ts`, and that file is run by ci-main.yml — so the arm asserts THOSE,
# and it reds if the scenario or its wiring is removed.
if [ -f "$REPO/extensions/verification-gate/index.e2e.test.ts" ] \
   && grep -q 'post-PASS edit must re-block (hash mismatch, fail-closed)' "$REPO/extensions/verification-gate/index.e2e.test.ts"; then
  ok "(c) stale verification: the post-PASS-edit re-block scenario exists in index.e2e.test.ts"
else
  bad "(c) stale verification: the hash-mismatch e2e scenario is gone from the gate's e2e suite"
fi
if grep -q 'extensions/verification-gate/index.e2e.test.ts' "$REPO/.github/workflows/ci-main.yml"; then
  ok "(c) stale verification: and that e2e suite is invoked by ci-main.yml (so it runs)"
else
  bad "(c) stale verification: the e2e suite carrying the refusal is wired into no workflow"
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

# ── 5. NO SCHEDULED-JOB DECLARATION MAY CARRY THE HATCH (agent-infra#4002) ─────────────────────
# §1-4 grade what a CARRIER does to its own process. This one grades the OTHER route the hatch takes:
# a unit/service/plist whose `Environment=`/`EnvironmentVariables` sets it, which hands the hatch to
# every process the job ever spawns and which no spawned lane can undo. The measured case (#4002) was a
# cell's drainer started by a hand-written wrapper exporting all four flags — an UNATTENDED dispatcher
# with the review gate, the verification gate and hub-discipline off.
# ⛔ WHY THIS IS A TEMPLATE CENSUS **AND** A RENDER: the templates are clean today, so a
# templates-only grep is a green that cannot fail until someone reintroduces the line — and the line can
# also arrive from a SUBSTITUTION, which only the rendered bytes show. So the arms are: every shipped
# declaration (census), the bytes the installer would actually install (render), and a MUTANT the grader
# must REFUSE (discrimination). Without the mutant, a scan whose regex silently stopped matching would
# still print PASS.
echo
echo "== unit declarations (#4002) =="
DECL_LIST="$( { ls "$REPO"/templates/systemd/*.service "$REPO"/templates/systemd/*.timer 2>/dev/null
               find "$REPO/templates/launchd" -name '*.plist' -type f 2>/dev/null; } | LC_ALL=C sort )"
DECL_SEEN=0; DECL_VETOED=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  DECL_SEEN=$((DECL_SEEN+1))
  bash "$POLICY" --unit-veto "$f" "${f#"$REPO"/}" >/dev/null 2>&1 \
    || DECL_VETOED="$DECL_VETOED ${f#"$REPO"/}"
done <<EOF
$DECL_LIST
EOF
DECL_FILES="$(printf '%s\n' "$DECL_LIST" | grep -c . || true)"
# NON-VACUITY FIRST: an empty scan is never a clean scan (the census must have looked at every shipped
# declaration, and the count is the file count — not a number that can drift from the directory).
[ "$DECL_SEEN" -gt 0 ] && [ "$DECL_SEEN" -eq "$DECL_FILES" ] \
  && ok "(5a) census: graded all $DECL_SEEN shipped systemd/launchd declarations (count = file count)" \
  || bad "(5a) census: graded $DECL_SEEN of $DECL_FILES declarations — the scan is not looking at the tree"
[ -z "$DECL_VETOED" ] \
  && ok "(5a) census: none of the $DECL_SEEN declarations names a gate-bypass flag in its environment" \
  || bad "(5a) census: a shipped declaration hands the hatch to everything it spawns:$DECL_VETOED"

# (5b) THE RENDERED UNIT — the bytes the installer would put on a box, not the template.
INST="$HERE/install-drainer-timer.sh"
RD="$TMP/render"; mkdir -p "$RD/bin"
cat >"$RD/bin/systemctl" <<'RD_SC'
#!/bin/sh
case "$*" in *is-active*) echo active ;; esac
exit 0
RD_SC
chmod +x "$RD/bin/systemctl"
RD_OUT="$(PATH="$RD/bin:$PATH" SYSTEMD_UNIT_DIR="$RD/units" DRAINER="$HERE/ai-drainer.sh" \
         DRAINER_STATE="$RD/state" DRAINER_O="$RD" bash "$INST" --dry-run 2>&1)"; RD_RC=$?
printf '%s\n' "$RD_OUT" >"$RD/rendered.txt"
# The render must have HAPPENED, or the veto below is grading an error message.
grep -q '^[[:space:]]*ExecStart=' "$RD/rendered.txt" && [ "$RD_RC" -eq 0 ] \
  && ok "(5b) render: install-drainer-timer.sh --dry-run produced a real unit (ExecStart present)" \
  || bad "(5b) render: --dry-run produced no ExecStart (rc=$RD_RC) — the arm below would grade nothing"
bash "$POLICY" --unit-veto "$RD/rendered.txt" "rendered eldato-ai-drainer.service" >"$RD/veto.log" 2>&1 \
  && ok "(5b) render: the RENDERED drainer unit carries no gate-bypass Environment= entry" \
  || bad "(5b) render: the RENDERED drainer unit carries a bypass: $(head -1 "$RD/veto.log")"

# (5c) MUTATION — inject the measured wrapper's hatch into a copy of the template and require the
# install to REFUSE (and to say which flag), and the census to redden on the same file.
MUT="$TMP/mutant"; mkdir -p "$MUT/tpl"
cp "$REPO/templates/systemd/eldato-ai-drainer.service" "$MUT/tpl/"
cp "$REPO/templates/systemd/eldato-ai-drainer.timer" "$MUT/tpl/"
printf 'Environment=AGENT_SKIP_REVIEW_GATE=1\n' >>"$MUT/tpl/eldato-ai-drainer.service"
bash "$POLICY" --unit-veto "$MUT/tpl/eldato-ai-drainer.service" mutant >/dev/null 2>&1; MUT_VETO=$?
[ "$MUT_VETO" -eq 1 ] \
  && ok "(5c) mutation: the census VETOES a declaration carrying AGENT_SKIP_REVIEW_GATE=1 (rc=1)" \
  || bad "(5c) mutation: the census did not veto the injected hatch (rc=$MUT_VETO) — its scan cannot discriminate"
MUT_OUT="$(PATH="$RD/bin:$PATH" SYSTEMD_UNIT_DIR="$MUT/units" TEMPLATES_DIR="$MUT/tpl" \
           DRAINER="$HERE/ai-drainer.sh" DRAINER_STATE="$MUT/state" DRAINER_O="$MUT" \
           bash "$INST" 2>&1)"; MUT_RC=$?
[ "$MUT_RC" -ne 0 ] && grep -q 'AGENT_SKIP_REVIEW_GATE' <<<"$MUT_OUT" \
  && ok "(5c) mutation: the INSTALLER REFUSES it and names the flag (rc=$MUT_RC)" \
  || bad "(5c) mutation: the installer installed a bypassing unit (rc=$MUT_RC): $(printf '%s' "$MUT_OUT" | tail -1)"
[ ! -f "$MUT/units/eldato-ai-drainer.service" ] \
  && ok "(5c) mutation: …and nothing was written to the unit dir (a refused install leaves no artefact)" \
  || bad "(5c) mutation: a refused install still wrote $MUT/units/eldato-ai-drainer.service"

# (5c2) THE MISSING-JUDGE REFUSAL, and it must be the RIGHT refusal (fresh review of #4002, P2). This is
# the one guard in the installer whose WHOLE point is the fail-closed answer when the CHECKER is absent, and
# nothing exercised it: delete the preflight and every other arm stays green. ⛔ The two states are
# distinguishable and it matters which one an operator gets — WITHOUT the preflight the install still stops,
# but `bash ""` exits 127 and `if ! bash "$GP_GUARD" …` reports a GATE BYPASS it never found, i.e. a wrong
# diagnosis for a missing checker.
MG="$TMP/nogr"
MG_OUT="$(PATH="$RD/bin:$PATH" SYSTEMD_UNIT_DIR="$MG/units" DRAINER="$HERE/ai-drainer.sh" \
          DRAINER_STATE="$MG/state" DRAINER_O="$MG" GP_GUARD=/nonexistent/absent.sh \
          bash "$INST" 2>&1)"; MG_RC=$?
[ "$MG_RC" -ne 0 ] && grep -q 'gate-policy.sh not found' <<<"$MG_OUT" \
  && ok "(5c2) install path: an unresolvable JUDGE refuses by name — 'cannot vet' is never a silent install" \
  || bad "(5c2) install path: a missing judge answered rc=$MG_RC · $(printf '%s' "$MG_OUT" | tail -1)"
grep -q 'GATE BYPASS' <<<"$MG_OUT" \
  && bad "(5c2) install path: a missing judge was reported as a GATE BYPASS it never found — wrong diagnosis" \
  || ok "(5c2) install path: …and it does NOT claim a bypass it could not have seen"
[ ! -f "$MG/units/eldato-ai-drainer.service" ] \
  && ok "(5c2) install path: …and nothing is written (an unvetted unit is not a clean one)" \
  || bad "(5c2) install path: a refused install still wrote $MG/units/eldato-ai-drainer.service"

printf '[Service]\nEnvironment="O=/x ELDATO_SKIP_VGATE=1"\nExecStart=/bin/true\n' >"$TMP/quoted.service"
bash "$POLICY" --unit-veto "$TMP/quoted.service" quoted >/dev/null 2>&1 \
  && bad "(5d) edges: a quoted multi-variable Environment= carrying ELDATO_SKIP_VGATE was NOT vetoed" \
  || ok "(5d) edges: a quoted multi-variable Environment= carrying a hatch IS vetoed"
printf '[Service]\nEnvironment=AGENT_SKIP_REVIEW_GATE_DISABLED=1\nExecStart=/bin/true\n' >"$TMP/superset.service"
bash "$POLICY" --unit-veto "$TMP/superset.service" superset >/dev/null 2>&1 \
  && ok "(5d) edges: a LONGER name that only contains a hatch name is not vetoed (whole-word match)" \
  || bad "(5d) edges: AGENT_SKIP_REVIEW_GATE_DISABLED=1 was vetoed — the match is a substring, not a name"
# ⛔ A BACKSLASH-CONTINUED `Environment=` IS ONE DIRECTIVE (fresh review of #4002, P1 — reproduced as a
# fail-open on the evidence head). systemd joins a line ending in an unescaped `\` with the following one
# (`systemd.syntax(7)`), so this sets the hatch while every PHYSICAL line looks innocent:
#     Environment=FOO=1 \
#         AGENT_SKIP_REVIEW_GATE=1
# The census answered CLEAN for it until the fold was added — in the census AND on the install path. This
# arm is the regression guard, and it is the reason §5c's mutation had to move off a single physical line.
printf '[Service]\nEnvironment=FOO=1 \\\n    AGENT_SKIP_REVIEW_GATE=1\nExecStart=/bin/true\n' >"$TMP/continued.service"
bash "$POLICY" --unit-veto "$TMP/continued.service" continued >/dev/null 2>&1; CONT_RC=$?
[ "$CONT_RC" -eq 1 ] \
  && ok "(5d) edges: a BACKSLASH-CONTINUED Environment= carrying a hatch IS vetoed (one logical directive, not one physical line)" \
  || bad "(5d) edges: a backslash-continued Environment= answered rc=$CONT_RC — the fold is gone and the census fails OPEN"
# …and the fold must not create false positives in either direction: a clean continuation is clean, and a
# WRAPPED COMMENT swallows its continuation exactly as systemd does (so the flag below is not a declaration).
printf '[Service]\nEnvironment=FOO=1 \\\n    BAR=2\nExecStart=/bin/true\n' >"$TMP/cleancont.service"
bash "$POLICY" --unit-veto "$TMP/cleancont.service" cleancont >/dev/null 2>&1 \
  && ok "(5d) edges: a clean continued Environment= is still clean (the fold is not matching everything)" \
  || bad "(5d) edges: a clean continued Environment= was vetoed — the fold over-matches"
printf '[Service]\n# a comment wrapping \\\nEnvironment=AGENT_SKIP_REVIEW_GATE=1\nExecStart=/bin/true\n' >"$TMP/commentwrap.service"
bash "$POLICY" --unit-veto "$TMP/commentwrap.service" commentwrap >/dev/null 2>&1 \
  && ok "(5d) edges: a WRAPPED COMMENT swallows its continuation (systemd's rule) and is not a declaration" \
  || bad "(5d) edges: a wrapped comment's continuation was graded — the fold is not faithful to systemd"
# …and the LAUNCHD half of the grader must be able to REDDEN (fresh review of #4002, P2). 5a passes if the
# `<key>` branch does nothing at all — no shipped plist carries a hatch — so without a mutated copy the
# "grades BOTH declaration dialects" claim is proven for one dialect only. Mutated in $TMP, never the
# template: the census above grades the real ones.
PLIST_SRC="$REPO/templates/launchd/com.eldato.pi-cache-reap.plist"
if [ -f "$PLIST_SRC" ]; then
  sed 's|<key>PATH</key>|<key>AGENT_SKIP_REVIEW_GATE</key>|' "$PLIST_SRC" >"$TMP/mut.plist"
  MUTPLIST_RC=0; bash "$POLICY" --unit-veto "$TMP/mut.plist" mutplist >/dev/null 2>&1 || MUTPLIST_RC=$?
  [ "$MUTPLIST_RC" -eq 1 ] \
    && ok "(5d) edges: a launchd plist carrying the hatch as its own <key> IS vetoed (a shipped plist mutated in \$TMP)" \
    || bad "(5d) edges: the plist branch answered rc=$MUTPLIST_RC for a hatch-bearing plist — that half of the grader cannot redden"
else
  bad "(5d) edges: $PLIST_SRC is gone, so the launchd half of the grader has no discriminating arm"
fi
printf '[Service]\nEnvironment=ELDATO_SKIP_REVIEW_GATE=1\nExecStart=/bin/true\n' >"$TMP/alias.service"
bash "$POLICY" --unit-veto "$TMP/alias.service" alias >/dev/null 2>&1 \
  && bad "(5d) edges: ELDATO_SKIP_REVIEW_GATE=1 was NOT vetoed — the dual-prefix alias bypasses the review gate" \
  || ok "(5d) edges: the DUAL-PREFIX alias ELDATO_SKIP_REVIEW_GATE (no AGENT_ variable present) IS vetoed"
# …and the FOURTH hatch, which skips the head-bound admin-merge evidence gate. It is a bypass of a certifying
# gate, which is the same #4002 shape as the other three (fresh review of #4002, round 3).
printf '[Service]\nEnvironment=AGENT_ADMIN_MERGE_OVERRIDE=1\nExecStart=/bin/true\n' >"$TMP/adminovr.service"
bash "$POLICY" --unit-veto "$TMP/adminovr.service" adminovr >/dev/null 2>&1 \
  && bad "(5d) edges: AGENT_ADMIN_MERGE_OVERRIDE=1 was NOT vetoed — it skips the head-bound admin-merge evidence gate" \
  || ok "(5d) edges: AGENT_ADMIN_MERGE_OVERRIDE (skips the admin-merge evidence gate) IS vetoed"
# …and an UNREADABLE declaration is not a clean one: rc 2, never 0.
bash "$POLICY" --unit-veto "$TMP/no-such-declaration" absent >/dev/null 2>&1; ABSENT_RC=$?
[ "$ABSENT_RC" -eq 2 ] \
  && ok "(5d) edges: an ungradable declaration answers 2 (not 0) — 'cannot check' is never a pass" \
  || bad "(5d) edges: an absent declaration answered rc=$ABSENT_RC (a no-op gate reports clean)"

# (5e) THE INSTALL PATH, NOT JUST THE CENSUS — because the installer is where the refusal is FELT, and
# a hatch can arrive on the RENDERED bytes from a substitution while the template stays clean. §5d
# proves the grader discriminates; this proves the thing that would put the unit on a box refuses it.
# Measured pre-fold on the reviewed head: the installer returned 0 and printed "ai-drainer scheduled",
# i.e. it installed a dispatcher that hands the review gate to every lane it spawns.
CV="$TMP/continuation-install"; mkdir -p "$CV/tpl"
cp "$REPO/templates/systemd/eldato-ai-drainer.service" "$REPO/templates/systemd/eldato-ai-drainer.timer" "$CV/tpl/"
printf 'Environment=NORMAL=1 \\\n            AGENT_SKIP_REVIEW_GATE=1\n' >>"$CV/tpl/eldato-ai-drainer.service"
CV_OUT="$(PATH="$RD/bin:$PATH" SYSTEMD_UNIT_DIR="$CV/units" TEMPLATES_DIR="$CV/tpl" \
          DRAINER="$HERE/ai-drainer.sh" DRAINER_STATE="$CV/state" DRAINER_O="$CV" \
          bash "$INST" 2>&1)"; CV_RC=$?
[ "$CV_RC" -ne 0 ] && grep -q 'AGENT_SKIP_REVIEW_GATE' <<<"$CV_OUT" \
  && ok "(5e) install path: the INSTALLER REFUSES rendered bytes whose hatch is on a continued line, and names the flag" \
  || bad "(5e) install path: the installer installed a unit whose hatch is on a continued line (rc=$CV_RC): $(printf '%s' "$CV_OUT" | tail -1)"
[ ! -f "$CV/units/eldato-ai-drainer.service" ] \
  && ok "(5e) install path: …and a refused install leaves no artefact (a refused unit is not on the box)" \
  || bad "(5e) install path: a refused install still wrote $CV/units/eldato-ai-drainer.service"

# ── 5f. THE LIST IS EXACTLY WHAT THE GATES HONOUR (agent-infra#4002, fresh reviews) ────────────────
# The list is hand-maintained, and the honoured set is NOT a fixed vocabulary: two hatches are read through
# `process.env["AGENT_" + n] ?? process.env["ELDATO_" + n]`, so each has two spellings and BOTH bypass the
# gate. That is how the earlier cuts of the list missed `ELDATO_SKIP_REVIEW_GATE` (rounds 1-2) and then
# `ADMIN_MERGE_OVERRIDE` entirely (round 3) — each a measured fail-open: the grader answered CLEAN for a unit
# whose hatch was live, and the installer printed `scheduled`. ⛔ AND NO ARM COULD REDDEN ON EITHER, because
# every arm exercised a name that was present.
# ⛔ SO THE DERIVATION IS FROM THE CALL SITES, NOT FROM A HAND-WRITTEN ALTERNATION (a fixed
# `(AGENT|ELDATO)_(SKIP_REVIEW_GATE|SKIP_VGATE|ALLOW_MAIN_EDITS)` pattern cannot see a stem it was not told
# about — that was round 3's finding against the first version of this arm):
#   * every `_getEnv("STEM")` call site, expanded to BOTH prefixes;
#   * plus every direct `process.env.(AGENT|ELDATO)_*` read whose name carries the hatch vocabulary
#     (SKIP|ALLOW|OVERRIDE|BYPASS) — direct reads are unpaired, so they are matched on the vocabulary.
# The declared non-hatch stems are subtracted BY NAME with a reason, so a config variable cannot be mistaken
# for a hatch and a new hatch cannot hide behind "it looked like config".
# STATED LIMIT: a hatch whose stem carries none of the vocabulary words AND is read without `_getEnv` would
# still be invisible here. That is the one shape this arm cannot see, and it is written down rather than
# implied — the `_getEnv` convention is what the gates actually use, so the first half is the load-bearing one.
echo
echo "== the list is what the gates honour (#4002) =="
NON_HATCH_STEMS="SESSION_TEAM"   # selects a team (`extensions/loop-enforcer`); it disables no gate
DECLARED="$(sed -n 's/^GP_UNIT_BYPASS_FLAGS="\(.*\)"$/\1/p' "$POLICY" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u)"
STEMS="$(grep -ohE '_getEnv\("[A-Z_]+"\)' "$REPO"/extensions/*/index.ts 2>/dev/null | sed -E 's/.*"([A-Z_]+)".*/\1/' | LC_ALL=C sort -u)"
DUAL=""
for _s in $STEMS; do
  case " $NON_HATCH_STEMS " in *" $_s "*) continue ;; esac
  DUAL="$DUAL$(printf 'AGENT_%s\nELDATO_%s\n' "$_s" "$_s")
"
done
DIRECT="$(grep -ohE 'process\.env\.(AGENT|ELDATO)_[A-Z_]*(SKIP|ALLOW|OVERRIDE|BYPASS)[A-Z_]*' "$REPO"/extensions/*/index.ts 2>/dev/null | sed 's/.*process\.env\.//' | LC_ALL=C sort -u)"
DERIVED="$(printf '%s%s\n' "$DUAL" "$DIRECT" | sed '/^$/d' | LC_ALL=C sort -u)"
DERIVED_N="$(grep -c . <<<"$DERIVED")"
[ -n "$STEMS" ] && [ "$DERIVED_N" -ge 2 ] \
  && ok "(5f) drift: derived the honoured hatch set from the extensions ($DERIVED_N names across $(printf '%s\n' $STEMS | grep -c .) _getEnv stems) — the equality is not vacuous" \
  || bad "(5f) drift: derived only $DERIVED_N honoured name(s) — the equality would pass on an empty set"
if [ "$DECLARED" = "$DERIVED" ]; then
  ok "(5f) drift: GP_UNIT_BYPASS_FLAGS EQUALS the set the gates honour — no dual-prefix alias can hide"
else
  only_decl="$(comm -23 <(printf '%s\n' "$DECLARED") <(printf '%s\n' "$DERIVED") | tr '\n' ' ')"
  only_hon="$(comm -13 <(printf '%s\n' "$DECLARED") <(printf '%s\n' "$DERIVED") | tr '\n' ' ')"
  bad "(5f) drift: the declared list and the gates disagree — declared-but-not-honoured:[$only_decl] honoured-but-not-declared:[$only_hon]"
fi

# ── 5g. A DECLARATION THAT IS GENERATED INLINE IS GRADED TOO (fresh review of #4002, round 3) ──────
# `scripts/install-lane-arm-timer.sh` does not render a template: `service_body()` is a heredoc that writes
# the `Environment=` lines itself, and the installer IS farmed (`pi-bootstrap/setup.sh`'s fleet set), so it
# is a LIVE install path on cells that no template census can see. An earlier revision of the census claimed
# the opposite in prose. The bytes it would install are gradeable through its own `--dry-run`, so they are
# graded here — and then a hatch is injected into those SAME bytes to prove the arm is reading a declaration
# and not an error message.
LARM="$REPO/scripts/install-lane-arm-timer.sh"
LG="$TMP/lanearm"; mkdir -p "$LG/scripts" "$LG/home"
cp "$REPO/scripts/lane-arm.sh" "$LG/scripts/" 2>/dev/null || true
LG_OUT="$(LANE_ARM_SCRIPTS_DIR="$LG/scripts" LANE_ARM_STATE_DIR="$LG/state" HOME="$LG/home" \
          SYSTEMD_UNIT_DIR="$LG/units" bash "$LARM" --dry-run 2>&1)"; LG_RC=$?
printf '%s\n' "$LG_OUT" >"$LG/rendered.txt"
# NON-VACUITY FIRST: a declaration was actually rendered (an Environment= and an ExecStart=), or the veto
# below would be grading a usage message and the mutation would be mutating prose.
if [ "$LG_RC" -eq 0 ] && grep -q '^[[:space:]]*Environment=' "$LG/rendered.txt" \
   && grep -q '^[[:space:]]*ExecStart=' "$LG/rendered.txt"; then
  ok "(5g) inline generator: install-lane-arm-timer.sh --dry-run rendered a real declaration (Environment= + ExecStart=)"
else
  bad "(5g) inline generator: --dry-run produced no gradeable declaration (rc=$LG_RC) — the arm below grades nothing"
fi
bash "$POLICY" --unit-veto "$LG/rendered.txt" "install-lane-arm-timer service_body" >/dev/null 2>&1 \
  && ok "(5g) inline generator: its GENERATED declaration carries no gate-bypass Environment= entry" \
  || bad "(5g) inline generator: the declaration install-lane-arm-timer.sh generates carries a bypass"
{ cat "$LG/rendered.txt"; printf 'Environment=AGENT_ADMIN_MERGE_OVERRIDE=1\n'; } >"$LG/mutated.txt"
bash "$POLICY" --unit-veto "$LG/mutated.txt" "install-lane-arm-timer mutant" >/dev/null 2>&1 \
  && bad "(5g) inline generator: a hatch injected into those SAME bytes was NOT vetoed — the arm cannot redden" \
  || ok "(5g) inline generator: a hatch injected into those same bytes IS vetoed (the arm reads a declaration, not an error message)"

printf '\ngate-policy.test: %d passed, %d failed, %d skipped (%s)\n' "$PASS" "$FAIL" "$SKIP" "$(uname -s)"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
