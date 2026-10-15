#!/usr/bin/env bash
# test-gates.sh — the dispatch gate's rule table.
#
# `orch-loop.sh`'s own comment says mp_reason/review_slots "hold the rule so it is directly
# testable (and so a regression cannot hide behind a comment)" — but no test existed. This is it.
# The functions are EXTRACTED from the live script (not copy-pasted), so this test fails if the
# extraction ever stops matching — a drift guard, not a mirror.
set -u
# Default to the orch-loop.sh BESIDE this test — the SHIPPED copy — so the suite runs from a clone
# with no deployed runtime (P2, 2026-10-14 export review: the original default, $HOME/orchestrator,
# does not exist on a fresh box, so the extraction checked nothing and the suite could not run).
# Point ORCH at the live runtime ($HOME/orchestrator/orch-loop.sh) on a box to use this as a drift
# guard against the DEPLOYED copy, which is its original purpose there.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH="${ORCH:-$HERE/orch-loop.sh}"
MERGE="$HERE/merge-one.sh"
PASS=0; FAIL=0

# --- extract the rule functions from the live controller ---
ex() { sed -n "/^$1()/,/^}/p" "$ORCH"; }
MP="$(ex mp_reason)"
if [ "$(printf '%s' "$MP" | wc -l | tr -d ' ')" -lt 3 ]; then
  echo "❌ could not extract mp_reason from $ORCH — the rule moved or was reformatted"; exit 1
fi
eval "$MP"
echo "extracted $(printf '%s' "$MP" | wc -l | tr -d ' ') lines of mp_reason from the live script"

MERGE_PRIORITY_AT=10
ck() { # ck <label> <open_prs> <lanes> <workers> <expect: gate|open>
  local got; got="$(mp_reason "$2" "$3" "$4")"
  if [ "$5" = "gate" ] && [ -n "$got" ]; then echo "  ✅ $1  (gated)"; PASS=$((PASS+1))
  elif [ "$5" = "open" ] && [ -z "$got" ]; then echo "  ✅ $1  (dispatch allowed)"; PASS=$((PASS+1))
  else echo "  ❌ $1 — expected $5, got [${got:-<empty>}] for (prs=$2 lanes=$3 workers=$4)"; FAIL=$((FAIL+1)); fi
}

echo
echo "=== THE FIX: workers must count, not just lanes (agent-infra#1709 item 4) ==="
ck "27 PRs, 0 lanes, 8 reviewers in flight -> DRAIN"      27 0 8  gate
ck "27 PRs, 0 lanes, 1 reviewer  in flight -> DRAIN"      27 0 1  gate
ck "27 PRs, 0 lanes, 0 workers           -> dispatch ok"  27 0 0  open

echo
echo "=== original behaviour preserved ==="
ck "27 PRs, 2 lanes, 5 workers -> DRAIN"                  27 2 5  gate
ck "11 PRs, 0 lanes, 1 worker  -> DRAIN (just over)"      11 0 1  gate
ck "5 PRs,  2 lanes, 5 workers -> dispatch ok"             5 2 5  open
ck "exactly 10 PRs -> NOT over the threshold"             10 2 5  open
ck "11 PRs, 0 lanes, 0 workers -> dispatch ok (nothing to drain with)" 11 0 0 open

echo
echo "=== regression proof: the OLD lanes-only form would have failed the first case ==="
mp_reason_old() { if [ "${1:-0}" -gt "$MERGE_PRIORITY_AT" ] && [ "${2:-0}" -ge 1 ]; then echo gated; fi; }
old="$(mp_reason_old 27 0 8)"
if [ -z "$old" ]; then echo "  ✅ old form returned EMPTY for (27,0,8) — the exact defect being fixed"; PASS=$((PASS+1))
else echo "  ❌ old form gated it — the fix would be a no-op"; FAIL=$((FAIL+1)); fi
new="$(mp_reason 27 0 8)"
[ -n "$new" ] && { echo "  ✅ new form gates it: $new"; PASS=$((PASS+1)); } || { echo "  ❌ new form still lets it through"; FAIL=$((FAIL+1)); }

echo
echo "=== THE REPO'S OWN ANSWERS: required checks + merge authority (agent-infra#1764) ==="
# The required-check list and the review authority are read from the TARGET REPO's branch
# protection. This is the regression for the defect that deadlocked every merge: the loop carried
# TORTOISE's protection contexts as a constant, so on agent-infra (whose only required check is
# `pipeline-compliance`) it named eight checks that can never appear, forced
# `FAILED:ai-review-gate` on a PR with 22 passing checks, and the queue could not drain.
# Both repo SHAPES are pinned, plus the fail-closed arm.
RA="$HERE/repo-authority.sh"
if [ ! -f "$RA" ]; then echo "❌ repo-authority.sh is missing — the per-repo contract moved"; exit 1; fi
# shellcheck source=/dev/null
. "$RA"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/gh" <<'SH'
#!/usr/bin/env bash
# Stub: only the required_status_checks read is modelled. The API shape is the real one
# (gh api … --jq '.contexts[]' prints one context per line).
case "$*" in
  *branches/main/protection/required_status_checks*)
    case "$*" in
      *agent-infra*) printf 'pipeline-compliance\n' ;;
      *readfail*)    exit 1 ;;
      *)             printf 'pricing-artifact\ndocs\ntest-isolation\nlicense-surface\nlegal-e2e\npython-ci-gate\nai-review-gate\n' ;;
    esac
    exit 0 ;;
esac
exit 1
SH
chmod +x "$TMP/gh"
G="$TMP/gh"
eqv() { # eqv <label> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "  ✅ $1"; PASS=$((PASS+1))
  else echo "  ❌ $1 — expected [$2], got [$3]"; FAIL=$((FAIL+1)); fi
}

# (a) the resolver reads each repo's OWN protection
eqv "agent-infra resolves to [pipeline-compliance]" "pipeline-compliance" "$(required_checks daniel-ospina/agent-infra "$G")"
eqv "tortoise resolves to its eight-name set" "pricing-artifact docs test-isolation license-surface legal-e2e python-ci-gate ai-review-gate" "$(required_checks daniel-ospina/tortoise "$G")"
required_checks daniel-ospina/readfail "$G" >/dev/null 2>&1; rrc=$?
[ "$rrc" -ne 0 ] && { echo "  ✅ an unreadable protection read reports FAILURE (rc=$rrc), not an empty set"; PASS=$((PASS+1)); } \
  || { echo "  ❌ an unreadable protection read exited 0 — a fail-OPEN read"; FAIL=$((FAIL+1)); }

# (b) the effective set: env wins; protection is used otherwise; unreadable -> NON-EMPTY fallback.
# ⛔ REQ_SOURCE is set by the function in the CURRENT shell, so each call whose source is asserted
# is made WITHOUT a command substitution (which would run it in a subshell and lose the global).
REQ_OVERRIDE='custom-check'
over="$(effective_required_checks daniel-ospina/agent-infra "$G")"
eqv "REQ_OVERRIDE wins over the protection read" "custom-check" "$over"
effective_required_checks daniel-ospina/agent-infra "$G" >/dev/null
eqv "…and its source is reported as 'env'" "env" "$REQ_SOURCE"
REQ_OVERRIDE=''
prot="$(effective_required_checks daniel-ospina/agent-infra "$G")"
eqv "without an override the repo's protection is used" "pipeline-compliance" "$prot"
effective_required_checks daniel-ospina/agent-infra "$G" >/dev/null
eqv "…and its source is reported as 'protection'" "protection" "$REQ_SOURCE"
fb="$(effective_required_checks daniel-ospina/readfail "$G")"
eqv "an UNREADABLE protection read falls back to the shipped non-empty set" "$FALLBACK_REQ" "$fb"
effective_required_checks daniel-ospina/readfail "$G" >/dev/null
eqv "…and its source is reported as 'fallback'" "fallback" "$REQ_SOURCE"
[ -n "$fb" ] && { echo "  ✅ the fallback is NON-EMPTY (an empty required set must never be the answer)"; PASS=$((PASS+1)); } \
  || { echo "  ❌ the fallback is empty — the fail-open the fallback exists to prevent"; FAIL=$((FAIL+1)); }
REQ_OVERRIDE=''

# (b2) the PRODUCTION caller shape (agent-infra#1764 review round 2): resolve_required_checks
# sets BOTH globals in the caller's shell. The direct-call tests above prove the resolver's
# contract; these prove the globals survive the way orch-loop.sh and merge-one.sh actually call
# it — the exact defect live-measured after round 1 (`REQ="$(…)"` subshells REQ_SOURCE away, so
# the ⚠️ fallback warning can never fire and merge-one's log printed source=?).
REQ_SOURCE=''; resolve_required_checks daniel-ospina/agent-infra "$G"
eqv "caller shape: REQ resolved" "pipeline-compliance" "${REQ:-}"
eqv "caller shape: REQ_SOURCE survives to the caller" "protection" "${REQ_SOURCE:-<EMPTY>}"
REQ_SOURCE=''; resolve_required_checks daniel-ospina/readfail "$G"
eqv "caller shape (unreadable): REQ is the non-empty fallback" "$FALLBACK_REQ" "${REQ:-}"
eqv "caller shape (unreadable): REQ_SOURCE is 'fallback' (the warning CAN fire)" "fallback" "${REQ_SOURCE:-<EMPTY>}"
REQ_OVERRIDE='custom-check'; REQ_SOURCE=''; resolve_required_checks daniel-ospina/agent-infra "$G"
eqv "caller shape (override): REQ_OVERRIDE wins" "custom-check" "${REQ:-}"
eqv "caller shape (override): REQ_SOURCE is 'env'" "env" "${REQ_SOURCE:-<EMPTY>}"
REQ_OVERRIDE=''
# (c) the authority follows from the set, by WHOLE NAME (a substring is not a match)
eqv "tortoise's set -> gate authority" "gate" "$(merge_authority "pricing-artifact docs ai-review-gate")"
eqv "a NAME that merely contains the gate is not the gate" "rail" "$(merge_authority "ai-review-gate-extra")"
eqv "an empty set -> rail (never a raw merge)" "rail" "$(merge_authority "")"

# (d) the shipped classifier against BOTH shapes. Rendered from the measured surfaces:
#     agent-infra PR #1763 = 22 checks, all non-red, NO ai-review-gate row.
awk '/^import sys,json$/,/^" 2>\/dev\/null\)\)$/' "$ORCH" | sed 's/^" 2>\/dev\/null))$//' \
  | sed -n '1,/^print(/p' > "$TMP/classify.py"
if [ -s "$TMP/classify.py" ]; then
  clr() { printf '%s' "$2" | REQ="$1" REVIEW_GATE=ai-review-gate python3 "$TMP/classify.py" 2>/dev/null; }
  AISURF='[{"name":"vendor-drift","state":"SUCCESS"},{"name":"cost-config","state":"SUCCESS"},{"name":"verify","state":"SUCCESS"},{"name":"admin-merge","state":"SUCCESS"},{"name":"drift-check","state":"SUCCESS"},{"name":"ci / lint","state":"SUCCESS"},{"name":"sigpipe-grep","state":"SUCCESS"},{"name":"bash-suites","state":"SUCCESS"},{"name":"http-pool-hygiene","state":"SUCCESS"},{"name":"pipeline-compliance","state":"SUCCESS"},{"name":"Mergify Merge Queue","state":"NEUTRAL"}]'
  TORTSURF='[{"name":"ai-review-gate","state":"SUCCESS"},{"name":"python-ci-gate","state":"SUCCESS"},{"name":"docs","state":"SKIPPED"},{"name":"test-isolation","state":"SUCCESS"},{"name":"license-surface","state":"SUCCESS"},{"name":"legal-e2e","state":"NEUTRAL"},{"name":"pricing-artifact","state":"SUCCESS"}]'
  TORTREQ='ai-review-gate python-ci-gate docs test-isolation license-surface legal-e2e pricing-artifact'
  eqv "REGRESSION: the OLD answer (tortoise's REQ on agent-infra's surface) was FAILED:ai-review-gate" \
      "FAILED:ai-review-gate" "$(clr "$TORTREQ" "$AISURF")"
  eqv "the FIX: agent-infra's own REQ on the same surface reads GREEN" \
      "GREEN" "$(clr 'pipeline-compliance' "$AISURF")"
  eqv "tortoise's shape still reads GREEN on its own REQ (behaviour preserved)" \
      "GREEN" "$(clr "$TORTREQ" "$TORTSURF")"
  # the fail-closed rule INSIDE the correct set must not be weakened by the scoping
  eqv "a required check that never reported stays PENDING" \
      "PENDING:pipeline-compliance" "$(clr 'pipeline-compliance' '[{"name":"ci / lint","state":"SUCCESS"}]')"
  eqv "a required check that reported red stays FAILED" \
      "FAILED:pipeline-compliance" "$(clr 'pipeline-compliance' '[{"name":"pipeline-compliance","state":"FAILURE"}]')"
  eqv "a missing review gate on a repo that REQUIRES it stays FAILED" \
      "FAILED:ai-review-gate" "$(clr "$TORTREQ" '[{"name":"docs","state":"SUCCESS"}]')"
  # the review-gate NAME is an input too: a repo whose gate is spelled differently must still have
  # its gate ENFORCED (SKIPPED is not satisfied). A revert to the 'ai-review-gate' literal reads
  # this surface as GREEN and is RED here.
  clrg() { printf '%s' "$3" | REQ="$1" REVIEW_GATE="$2" python3 "$TMP/classify.py" 2>/dev/null; }
  eqv "a custom review-gate name is enforced (the name is an input)" \
      "FAILED:my-gate" "$(clrg 'my-gate other' 'my-gate' '[{"name":"my-gate","state":"SKIPPED"},{"name":"other","state":"SUCCESS"}]')"
else
  echo "  ❌ could not extract the classifier from $ORCH"; FAIL=$((FAIL+1))
fi

# (e) the WIRING — a resolver that nothing calls is not a fix. The constants-and-functions above
# can all be right while the loop still uses a literal, so the CALL SITES are pinned too. This is
# the check that fails if #1764 is "fixed" by changing repo-authority.sh and not wiring it in.
if grep -q 'REQ="ai-review-gate python-ci-gate docs test-isolation' "$ORCH"; then
  echo "  ❌ orch-loop.sh still carries a hardcoded required-check constant"; FAIL=$((FAIL+1))
else
  echo "  ✅ orch-loop.sh carries NO hardcoded required-check constant"; PASS=$((PASS+1))
fi
wpin() { # wpin <label> <file> <fixed-string>
  if grep -qF "$3" "$2"; then echo "  ✅ $1"; PASS=$((PASS+1)); else echo "  ❌ $1 — [$3] not found in $(basename "$2")"; FAIL=$((FAIL+1)); fi
}
eqv "agent-infra's set -> rail authority" "rail" "$(merge_authority "pipeline-compliance")"
wpin "orch-loop.sh resolves the required set in the CALLER's shell" "$ORCH" 'resolve_required_checks "$OR"'
wpin "orch-loop.sh derives the merge authority from that set" "$ORCH" 'MERGE_AUTHORITY="$(merge_authority "$REQ")"'
wpin "the classifier receives the resolved set + gate name" "$ORCH" 'REQ="$REQ" REVIEW_GATE="$REVIEW_GATE" python3'
wpin "the controller branches on the merge authority" "$ORCH" 'MERGE_AUTHORITY" = "rail"'
wpin "merge-one.sh resolves the same contract" "$MERGE" 'resolve_required_checks "$OR"'
# (f) the missing-rail REFUSAL is BEHAVIOURAL, not textual. A grep pin cannot tell a live guard
# from one neutered to `if false` (the refusal echo stays in the file either way) — that is the
# inert-enforcer class this repo treats as category A. So the rail branch is EXTRACTED and DRIVEN
# with the rail absent: it must exit 6 (a refusal), not fall through to the rest of the script.
{ grep -m1 '^is_num() {' "$MERGE"; grep -m1 '^is_limit() {' "$MERGE"
  awk '/^if \[ "\$MERGE_AUTHORITY" = "rail" \]; then/{f=1} f&&/^# ── 1\) fresh-context review/{f=0} f' "$MERGE"; } > "$TMP/railbranch.sh"
if [ -s "$TMP/railbranch.sh" ] && grep -q 'refusing to fall back to a raw gh pr merge' "$TMP/railbranch.sh"; then
  mkdir -p "$TMP/railrepo" "$TMP/railO/state"
  ( MERGE_AUTHORITY=rail; REPO="$TMP/railrepo"; PR=1764; OR=daniel-ospina/agent-infra; \
    L="$TMP/railO/merge.log"; O="$TMP/railO"; HEAD=deadbeef; RAIL_TRIES=3; \
    . "$TMP/railbranch.sh" ) >/dev/null 2>&1; mrc=$?
  [ "$mrc" = "6" ] && { echo "  ✅ a missing rail EXITS 6 (refusal) with no gh pr merge fallback"; PASS=$((PASS+1)); } \
    || { echo "  ❌ a missing rail exited $mrc, not 6 — the guard is inert or absent"; FAIL=$((FAIL+1)); }
else
  echo "  ❌ could not extract the rail branch from merge-one.sh"; FAIL=$((FAIL+1))
fi
wpin "merge-one.sh runs the repo's rail, not a raw merge" "$MERGE" 'bash "$RAIL" "$PR" --repo "$OR" -- --squash'

# (g) the rail park is REFRESHED on a head change — BEHAVIOURAL (review P1, round 1). The guarded
# write left a PREVIOUS head's park in place forever: a new head reached the cap, saw the stale
# file, never recorded itself, and exit 0'd — so the sweep (which honours a park only when its
# CONTENT matches the current head) re-spawned a rail worker every cycle forever, the exact burn
# RAIL_TRIES exists to close. Driven with a REFUSING rail at the cap and a stale older-head park:
# the park file must come back holding the NEW head.
mkdir -p "$TMP/railrepo/scripts" "$TMP/railO/state"
printf '#!/bin/bash\nexit 1\n' > "$TMP/railrepo/scripts/admin-merge.sh"   # a rail that REFUSES
chmod +x "$TMP/railrepo/scripts/admin-merge.sh"
printf '%s %s\n' bbbb2222 3 > "$TMP/railO/state/railcount-1764"
printf '%s\n' aaaa1111  > "$TMP/railO/state/parked-1764"                  # a STALE park, older head
( MERGE_AUTHORITY=rail; REPO="$TMP/railrepo"; PR=1764; OR=daniel-ospina/agent-infra; \
  L="$TMP/railO/merge.log"; O="$TMP/railO"; HEAD=bbbb2222; RAIL_TRIES=3; \
  . "$TMP/railbranch.sh" ) >/dev/null 2>&1; prc=$?
_parked="$(cat "$TMP/railO/state/parked-1764" 2>/dev/null)"
[ "$prc" = "0" ] && [ "$_parked" = "bbbb2222" ] \
  && { echo "  ✅ the rail park is REFRESHED on a head change (a stale older-head park cannot block it)"; PASS=$((PASS+1)); } \
  || { echo "  ❌ rail park not refreshed: rc=$prc parked=[$_parked] (expected bbbb2222 — the stale aaaa1111 park survived the cap, so the spawn loop reopens)"; FAIL=$((FAIL+1)); }

# (h) the controller's GREEN arm dispatches the rail — BEHAVIOURAL (review P2, round 1): the
# 'controller branches on the merge authority' pin greps a condition, which a NEUTERED guard
# (`= "rail" ] && false`) still satisfies while every PR falls through to a raw merge on a rail
# repo — the exact bypass this branch exists to prevent. So the arm is EXTRACTED and DRIVEN with
# mocked gh/tmux: rail authority must tmux-spawn merge-<PR> and issue NO raw merge; gate authority
# must do the reverse.
sed -n '/^      GREEN)$/,/^      PENDING:\*)$/p' "$ORCH" | sed '$d' | sed '$s/ ;;$//' | sed '1d' > "$TMP/greenarm.sh"
if [ -s "$TMP/greenarm.sh" ] && grep -q 'MERGE_AUTHORITY.*rail' "$TMP/greenarm.sh" && bash -n "$TMP/greenarm.sh" 2>/dev/null; then
  drive_green() { # drive_green <authority> <req> -> writes $TMP/g.spy / $TMP/g.tspy / LOG
    # `: >`, never `rm -f` (review P2, round 2): an ABSENT file made `! grep -q new-session`
    # pass vacuously in the gate drive — the tmux mock never ran, so there was no file to read.
    : > "$TMP/g.spy"; : > "$TMP/g.tspy"; : > "$TMP/g.log"
    ( PR=1765; OR=daniel-ospina/agent-infra; REPO="$TMP/grepo"; BR=fix/x; HEAD_N=deadbeef
      MR=3; MERGE_AUTHORITY="$1"; REQ="$2"; REVIEW_GATE='ai-review-gate'
      LOG="$TMP/g.log"; O="$TMP/gO"; mkdir -p "$O/state"
      sess() { return 1; }; claim_live() { return 1; }; can_spawn() { return 0; }
      gh()   { echo "GH $*" >> "$TMP/g.spy"; return 0; }
      tmux() { echo "TMUX $*" >> "$TMP/g.tspy"; [ "$1" = ls ] && return 0; return 0; }
      # shellcheck disable=SC1090
      . "$TMP/greenarm.sh" ) >/dev/null 2>&1
  }
  drive_green rail 'pipeline-compliance'
  if grep -q 'new-session' "$TMP/g.tspy" && ! grep -q -- '--squash' "$TMP/g.spy"; then
    echo "  ✅ GREEN+rail: a merge worker is spawned and NO raw merge is issued"; PASS=$((PASS+1))
  else
    echo "  ❌ GREEN+rail: tspy=[$(tr '\n' ';' < "$TMP/g.tspy")] spy=[$(tr '\n' ';' < "$TMP/g.spy")] — a rail repo must never reach a raw merge"; FAIL=$((FAIL+1))
  fi
  grep -q 'GREEN -> rail worker' "$TMP/g.log" \
    && { echo "  ✅ GREEN+rail: the worker carries the resolved contract (REQ/REVIEW_GATE in the spawn line)"; PASS=$((PASS+1)); } \
    || { echo "  ❌ GREEN+rail: no rail-worker log line — the arm did not take the rail path"; FAIL=$((FAIL+1)); }
  grep -q 'REQ=pipeline' "$TMP/g.tspy" \
    && { echo "  ✅ GREEN+rail: the spawn line carries REQ=$(grep -o "REQ=[^ ]*" "$TMP/g.tspy" | head -1) (one resolution, one authority)"; PASS=$((PASS+1)); } \
    || { echo "  ❌ GREEN+rail: the spawn line carries no resolved REQ — the worker re-resolves and can disagree"; FAIL=$((FAIL+1)); }
  # The quoting is load-bearing and must be pinned with a MULTI-NAME set (review P2, round 2):
  # a single-token REQ makes `printf %q` a no-op, so the assertion above passes without it — but
  # `sh -c 'REQ=pricing-artifact docs … bash worker'` is `docs: command not found` (rc 127, the
  # worker never runs, no merge ever happens) on the real 7-name tortoise set. Drive it and
  # require the EXACT %q-escaped token in the spawn line.
  _REQ7='pricing-artifact docs test-isolation license-surface legal-e2e python-ci-gate ai-review-gate'
  drive_green rail "$_REQ7"
  _EXP7="REQ=$(printf '%q' "$_REQ7")"
  if grep -qF -- "$_EXP7" "$TMP/g.tspy"; then
    echo "  ✅ GREEN+rail: a MULTI-name REQ arrives whole (the %q-escaped 7-name set is in the spawn line)"; PASS=$((PASS+1))
  else
    echo "  ❌ GREEN+rail: the 7-name set did not survive the spawn line (expected [$_EXP7]; tspy=[$(tr '\n' ';' < "$TMP/g.tspy")]) — an unquoted multi-name REQ kills the worker at sh -c"; FAIL=$((FAIL+1))
  fi
  drive_green gate 'pipeline-compliance'
  if grep -q -- '--squash' "$TMP/g.spy" && ! grep -q 'new-session' "$TMP/g.tspy"; then
    echo "  ✅ GREEN+gate: the squash merge path is UNCHANGED (no worker detour)"; PASS=$((PASS+1))
  else
    echo "  ❌ GREEN+gate: tspy=[$(tr '\n' ';' < "$TMP/g.tspy")] spy=[$(tr '\n' ';' < "$TMP/g.spy")] — gate authority must merge directly as before"; FAIL=$((FAIL+1))
  fi
else
  echo "  ❌ could not extract a SYNTACTICALLY VALID GREEN arm from orch-loop.sh (extraction or the arm itself is broken)"; FAIL=$((FAIL+1))
fi
# every merge spawn line must %q-quote the carried REQ (both the GREEN rail spawn and the
# re-record spawn — review P2, round 2's second half)
grep -q 'REQ=$(printf '\''%q'\'' "$REQ")' "$ORCH" \
  && { echo "  ✅ every merge spawn line %q-quotes the carried REQ"; PASS=$((PASS+1)); } \
  || { echo "  ❌ a merge spawn line lost its %q quoting"; FAIL=$((FAIL+1)); }

# (i) AUTHORITY_UNKNOWN is REAL (review P2, round 2 — it had zero coverage and could be deleted
# without a red). Two halves: the guard's EXPRESSION does continue when set, and it sits BEFORE
# the classifier (a guard moved after the arms guards nothing).
_au_expr='[ "${AUTHORITY_UNKNOWN:-0}" = "1" ] && continue'
_au_ln="$(grep -nF -- "$_au_expr" "$ORCH" | head -1 | cut -d: -f1)"
_cls_ln="$(grep -nF 'V="$(gh pr checks' "$ORCH" | head -1 | cut -d: -f1)"
if [ -n "$_au_ln" ] && [ -n "$_cls_ln" ] && [ "$_au_ln" -lt "$_cls_ln" ]; then
  echo "  ✅ AUTHORITY_UNKNOWN guard exists and precedes the classifier (line $_au_ln < $_cls_ln)"; PASS=$((PASS+1))
else
  echo "  ❌ AUTHORITY_UNKNOWN guard missing or misplaced (guard@${_au_ln:-none} classifier@${_cls_ln:-none}) — deleted, the sweep acts on an unknown contract"; FAIL=$((FAIL+1))
fi
_au_hits=0; AUTHORITY_UNKNOWN=1
for _p in a b; do eval "$([ "${AUTHORITY_UNKNOWN:-0}" = "1" ] && echo continue || echo : )"; _au_hits=$((_au_hits+1)); done
[ "$_au_hits" = "0" ] && { echo "  ✅ the guard's expression continues every PR when set"; PASS=$((PASS+1)); } \
  || { echo "  ❌ the guard expression did not continue (hits=$_au_hits)"; FAIL=$((FAIL+1)); }
AUTHORITY_UNKNOWN=0; _au_hits=0
for _p in a b; do [ "${AUTHORITY_UNKNOWN:-0}" = "1" ] && continue; _au_hits=$((_au_hits+1)); done
[ "$_au_hits" = "2" ] && { echo "  ✅ …and does NOT continue when clear"; PASS=$((PASS+1)); } \
  || { echo "  ❌ the guard continued when clear (hits=$_au_hits)"; FAIL=$((FAIL+1)); }

# (j) the WORKER refuses an unknown contract — BEHAVIOURAL (review P1, round 2): the controller
# guard covers only the sweep; chain-merge.sh and fix-one.sh invoke merge-one.sh directly. Drive
# the shipped guard: fallback + no override must exit 5 BEFORE any reviewer; fallback + override
# must proceed (and then hit the missing-rail refusal, exit 6 — proving the override path).
sed -n '/^if \[ "${REQ_SOURCE:-}" = "fallback" \] && \[ -z "${REQ_OVERRIDE:-}" \]; then$/,/^fi$/p' "$MERGE" > "$TMP/worker-guard.sh"
if [ -s "$TMP/worker-guard.sh" ] && bash -n "$TMP/worker-guard.sh" 2>/dev/null; then
  ( REQ_SOURCE=fallback; REQ_OVERRIDE=''; PR=1766; OR=daniel-ospina/agent-infra; \
    L="$TMP/wg"; O="$TMP"; . "$TMP/worker-guard.sh" ) >/dev/null 2>&1; wgrc=$?
  [ "$wgrc" = "5" ] && { echo "  ✅ a worker whose protection read FAILED refuses (exit 5) before any reviewer"; PASS=$((PASS+1)); } \
    || { echo "  ❌ worker guard exited $wgrc, not 5 — an unknown contract can still merge via a non-sweep ingress"; FAIL=$((FAIL+1)); }
  ( REQ_SOURCE=fallback; REQ_OVERRIDE='pipeline-compliance'; PR=1766; OR=daniel-ospina/agent-infra; \
    L="$TMP/wg2"; O="$TMP"; . "$TMP/worker-guard.sh" ) >/dev/null 2>&1; wg2rc=$?
  [ "$wg2rc" != "5" ] && { echo "  ✅ an explicit REQ override still proceeds (the refusal is about NOT KNOWING, not about overriding)"; PASS=$((PASS+1)); } \
    || { echo "  ❌ the worker guard refused a valid operator override"; FAIL=$((FAIL+1)); }
else
  echo "  ❌ could not extract the worker authority-unknown guard from merge-one.sh"; FAIL=$((FAIL+1))
fi

# (k) the FAILED arm's gate test is WHOLE-NAME (review P2, round 2): `grep -qF` matched a
# substring, so REVIEW_GATE=compliance misrouted a red pipeline-compliance into the review arm
# while merge_authority correctly said rail. Extract the shipped derivation and drive both.
sed -n '/^        _gate_hit=0; _gifs=/,/^        IFS="\$_gifs"$/p' "$ORCH" > "$TMP/gatehit.sh"
if [ -s "$TMP/gatehit.sh" ] && bash -n "$TMP/gatehit.sh" 2>/dev/null; then
  REVIEW_GATE=compliance; V='FAILED:pipeline-compliance'; _gate_hit=1
  # shellcheck disable=SC1090
  . "$TMP/gatehit.sh"
  [ "${_gate_hit:-}" = "0" ] && { echo "  ✅ gate hit is whole-name: compliance does NOT match pipeline-compliance"; PASS=$((PASS+1)); } \
    || { echo "  ❌ gate hit matched a substring (compliance vs pipeline-compliance) — a substring REVIEW_GATE misroutes red CI checks into the review arm"; FAIL=$((FAIL+1)); }
  REVIEW_GATE=ai-review-gate; V='FAILED:ai-review-gate,docs'; _gate_hit=0
  # shellcheck disable=SC1090
  . "$TMP/gatehit.sh"
  [ "${_gate_hit:-}" = "1" ] && { echo "  ✅ …and the exact gate name DOES match"; PASS=$((PASS+1)); } \
    || { echo "  ❌ the exact gate name did not match"; FAIL=$((FAIL+1)); }
else
  echo "  ❌ could not extract the gate-hit derivation from orch-loop.sh"; FAIL=$((FAIL+1))
fi

echo
echo "================ RESULT: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
