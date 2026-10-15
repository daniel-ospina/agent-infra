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

# (b) the resolved set: env wins; protection is used otherwise; unreadable -> NON-EMPTY fallback.
# ⛔ REQ/REQ_SOURCE are set by the resolver in the CURRENT shell, so it is called WITHOUT a command
# substitution (which would run it in a subshell and lose the globals) — and there is exactly ONE
# resolver (round 6 removed the `effective_required_checks` twin that let a fix land in one copy).
REQ_OVERRIDE='custom-check'
resolve_required_checks daniel-ospina/agent-infra "$G"
eqv "REQ_OVERRIDE wins over the protection read" "custom-check" "$REQ"
eqv "…and its source is reported as 'env'" "env" "$REQ_SOURCE"
REQ_OVERRIDE=''
resolve_required_checks daniel-ospina/agent-infra "$G"
eqv "without an override the repo's protection is used" "pipeline-compliance" "$REQ"
eqv "…and its source is reported as 'protection'" "protection" "$REQ_SOURCE"
resolve_required_checks daniel-ospina/readfail "$G"
fb="$REQ"
eqv "an UNREADABLE protection read falls back to the shipped non-empty set" "$FALLBACK_REQ" "$fb"
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
eqv "an empty set -> unknown (a stale contract refuses; never rail, never a raw merge)" "unknown" "$(merge_authority "")"
# ⛔ round-8 review (classes B2/B3). A WHITESPACE-bearing set made the classifier (`str.split()`,
# which splits on ANY whitespace) and `merge_authority` (a whole-name test delimited on a literal
# SPACE) disagree about the SAME string — the gate was enforced while the authority answered
# `rail`, so on a gate repo `merge-one.sh` took its rail branch and SKIPPED the fresh-context
# reviewer and the signed record. A whitespace-ONLY set was worse: `' '.split()` is `[]` to the
# classifier while a bare `-z` test called it non-empty and ROUTED it to `rail` instead of
# refusing. Both are "an empty contract must refuse, never route".
eqv "a whitespace-only set -> unknown (an empty contract must refuse, never route)" "unknown" "$(merge_authority " ")"
eqv "a TAB-separated set is normalised, so the gate is still recognised" "gate" "$(merge_authority "$(printf 'ai-review-gate\tdocs')")"
eqv "a NEWLINE-separated set is normalised too" "gate" "$(merge_authority "$(printf 'ai-review-gate\ndocs')")"
# ⛔⛔ round-9 review, P2 — THE FIRST FIX ENUMERATED THE BYTES TO FOLD, AND AN ENUMERATION CANNOT BE
# RIGHT. The classifier splits on Python's `str.isspace()`, a SUPERSET of the POSIX `[:space:]` class
# `tr` folds; \x1c-\x1f, \x85, NBSP and U+2028 all split for Python and not for `tr`. Measured at
# the previous head: each of the three below made the classifier report the gate ENFORCED while
# `merge_authority` answered `rail` — the identical §5.1 bypass (rail ⇒ no fresh-context reviewer, no
# signed record), still open. The normaliser now uses the classifier's own rule, so all three read
# `gate`, and adding a fourth exotic separator cannot reopen the class.
# ⛔ round-10 review, P3: the assertions below originally drove ONLY `merge_authority`, so a
# normaliser/classifier MISMATCH — the exact bug they exist to catch — passed them (and did). They
# now assert BOTH readers on the same string, in both directions, and the classifier's RULE itself
# is pinned to the shipped line so a change to either side turns one of these red.
_CLS_RULE="want=(os.environ.get('REQ') or '').split()"
grep -vE '^[[:space:]]*#' "$ORCH" | grep -qF -- "$_CLS_RULE" \
  && { echo "  ✅ the classifier still splits with Python .split() — the rule _normalise_set shares"; PASS=$((PASS+1)); } \
  || { echo "  ❌ the classifier's split rule changed in orch-loop.sh; _normalise_set shares it and must change with it (the two MUST agree) "; FAIL=$((FAIL+1)); }
_agree() { # _agree <set> -> both readers' verdicts on the SAME string
  printf 'authority=%s classifier=%s' "$(merge_authority "${1:-}")" \
    "$(REQ="${1:-}" python3 -c 'import os;print("required" if "ai-review-gate" in (os.environ.get("REQ") or "").split() else "not-required")')"
}
eqv "\\x1c: both readers agree the gate IS required (Python whitespace, not POSIX)" "authority=gate classifier=required" "$(_agree "$(printf 'ai-review-gate\034docs')")"
eqv "\\x1d: both readers agree the gate IS required" "authority=gate classifier=required" "$(_agree "$(printf 'ai-review-gate\035docs')")"
eqv "NBSP: both readers agree the gate IS required (the case no \`tr\` set can express)" "authority=gate classifier=required" "$(_agree "$(printf 'ai-review-gate\302\240docs')")"
eqv "a set WITHOUT the gate: both readers agree it is NOT required (the other direction)" "authority=rail classifier=not-required" "$(_agree 'pipeline-compliance docs')"
eqv "a whitespace-only OVERRIDE is ABSENT, not a nameless env contract (fail-closed)" "fallback" \
  "$( REQ_OVERRIDE=' '; REQ=''; REQ_SOURCE=''; resolve_required_checks daniel-ospina/readfail "$G"; printf '%s' "${REQ_SOURCE:-<EMPTY>}" )"
eqv "a TAB-separated OVERRIDE is normalised onto the space-joined contract" "a b" \
  "$( REQ_OVERRIDE="$(printf 'a\tb')"; REQ=''; REQ_SOURCE=''; resolve_required_checks daniel-ospina/agent-infra "$G"; printf '%s' "${REQ:-}" )"

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
wline() { # wline <label> <file> <fixed-WHOLE-line at column 0>
  # A plain substring pin cannot tell `resolve_required_checks "$OR"` from the SAME text
  # wrapped in a command substitution (`REQ="$(resolve_required_checks "$OR")"`) — the wrap
  # subshells the resolver and drops REQ_SOURCE. Anchored to the whole line, the wrapped form
  # no longer matches (review round 8, P2).
  if grep -qxF "$3" "$2"; then echo "  ✅ $1"; PASS=$((PASS+1)); else echo "  ❌ $1 — the line [$3] is not present at column 0 (a wrapped/subshelled call does not count)"; FAIL=$((FAIL+1)); fi
}
eqv "agent-infra's set -> rail authority" "rail" "$(merge_authority "pipeline-compliance")"
wpin "orch-loop.sh resolves the required set in the CALLER's shell" "$ORCH" 'resolve_required_checks "$OR"'
wpin "orch-loop.sh derives the merge authority from that set" "$ORCH" 'MERGE_AUTHORITY="$(merge_authority "$REQ")"'
wpin "the classifier receives the resolved set + gate name" "$ORCH" 'REQ="$REQ" REVIEW_GATE="$REVIEW_GATE" python3'
wpin "the controller branches on the merge authority" "$ORCH" 'MERGE_AUTHORITY" = "rail"'
wline "merge-one.sh resolves the same contract in the CALLER's shell (whole line, not wrapped in a command substitution)" "$MERGE" 'resolve_required_checks "$OR"'
# (e2) …and BEHAVIOURALLY. The grep above cannot see a command substitution around the call (the
# wrapped form CONTAINS the same substring), so the round-2 defect — REQ_SOURCE lost, `source=?`
# printed, the fallback warning never firing, and the authority-unknown refusal tripping on every
# PR — could return with every pin green (review round 8, P2; the PR body listed this mutant as
# verified RED). Extract merge-one.sh's shipped contract block and DRIVE it: with a resolver that
# sets BOTH globals, a direct call leaves REQ/REQ_SOURCE/AUTHORITY set; the subshell shape leaves
# REQ empty and fires the refusal (exit 5).
awk '/^# ── the repo.s merge authority \(agent-infra#1764\)/{f=1} /^if \[ "\$MERGE_AUTHORITY" = "rail" \]; then/{f=0} f' "$MERGE" > "$TMP/contract.sh"
if [ -s "$TMP/contract.sh" ] && bash -n "$TMP/contract.sh" 2>/dev/null; then
  _c_out="$( REQ_OVERRIDE=''; REQ=''; L="$TMP/contract.log"; OR=daniel-ospina/agent-infra; PR=1764
    resolve_required_checks() { REQ='pipeline-compliance'; REQ_SOURCE='protection'; return 0; }
    merge_authority() { printf 'rail\n'; }
    # shellcheck disable=SC1090
    . "$TMP/contract.sh"
    printf 'REQ=%s SRC=%s AUTH=%s' "$REQ" "${REQ_SOURCE:-}" "$MERGE_AUTHORITY" )" 2>/dev/null
  _c_rc=$?
  if [ "$_c_rc" = "0" ] && [ "$_c_out" = "REQ=pipeline-compliance SRC=protection AUTH=rail" ]; then
    echo "  ✅ merge-one.sh's resolver runs in the CALLER's shell — REQ and REQ_SOURCE survive the call"; PASS=$((PASS+1))
  else
    echo "  ❌ the resolver did not survive its call site (rc=$_c_rc out=[$_c_out]) — a command-substitution wrap drops REQ_SOURCE and trips the authority-unknown refusal on every PR"; FAIL=$((FAIL+1))
  fi
else
  echo "  ❌ could not extract merge-one.sh's repo-authority contract block"; FAIL=$((FAIL+1))
fi
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
# …and the ABSENCE of a raw merge ON THE RAIL PATH (review round 8, P2). The pin above is a
# PRESENCE grep, so `gh pr merge …` added ALONGSIDE the rail call stays green — and the rail-branch
# drives below did not stub `gh`, so the bypass was invisible to them. Static absence first
# (anchored to a COMMAND line, so the `raw gh pr merge` warning text in an echo cannot match),
# then a behavioural `gh` spy on PATH in the rail-success drive below.
if grep -qE '^[[:space:]]*gh[[:space:]]+pr[[:space:]]+merge' "$TMP/railbranch.sh"; then
  echo "  ❌ merge-one.sh's rail branch issues a raw 'gh pr merge' — the exact bypass this branch forbids"; FAIL=$((FAIL+1))
else
  echo "  ✅ merge-one.sh's rail branch issues NO raw 'gh pr merge' (static absence pin)"; PASS=$((PASS+1))
fi

# RAIL_TRIES is deliberately NOT set here (review round 5, P1): the drive used to supply it, so
# the suite could not tell a shipped script that DEFAULTS it from one that expands it bare under
# `set -u`. With it unset — the production default, since nothing in install.sh, the launchd plist,
# the README or a cell keys.env sets it — the shipped text died `unbound variable` at the cap
# comparison and the park was never written, i.e. rail mode was dead and the spawn loop reopened.
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
  L="$TMP/railO/merge.log"; O="$TMP/railO"; HEAD=bbbb2222; \
  . "$TMP/railbranch.sh" ) >/dev/null 2>&1; prc=$?
_parked="$(cat "$TMP/railO/state/parked-1764" 2>/dev/null)"
[ "$prc" = "0" ] && [ "$_parked" = "bbbb2222" ] \
  && { echo "  ✅ the rail park is REFRESHED on a head change (a stale older-head park cannot block it)"; PASS=$((PASS+1)); } \
  || { echo "  ❌ rail park not refreshed: rc=$prc parked=[$_parked] (expected bbbb2222 — the stale aaaa1111 park survived the cap, so the spawn loop reopens)"; FAIL=$((FAIL+1)); }

# (g2) the rail is ACTUALLY INVOKED with RAIL_TRIES UNSET — the exact line (and only line) the
# round-5 P1 made unreachable: the worker died `unbound variable` at the cap comparison, so
# `bash "$RAIL"` was never reached and no rail-mode PR could ever merge. A fresh head with a rail
# that SUCCEEDS must reach it and record the merge; a text pin on that line proves nothing.
# The stub RECORDS its argv and cwd, so the invocation CONTRACT is driven too, not just greped
# (review round 6, P2): the real rails are called as `<PR> --repo <OR> -- --squash` from $REPO.
rm -f "$TMP/railO/state/railcount-1764" "$TMP/railO/state/merged-1764.done" "$TMP/railO/rail-argv.txt"
# ⚠️ review round 6: the stub must RECORD argv and cwd (via a heredoc, so the inner $PWD/$* are not
# eaten by an outer printf) — the invocation CONTRACT is then driven, not merely greped.
cat > "$TMP/railrepo/scripts/admin-merge.sh" <<RAILSTUB
#!/bin/bash
printf '%s\n' "\$PWD" "\$*" > "$TMP/railO/rail-argv.txt"
exit 0
RAILSTUB
chmod +x "$TMP/railrepo/scripts/admin-merge.sh"
# A `gh` spy on PATH for the rail-success drive: the rail branch is invoked with a rail that
# SUCCEEDS, and any raw `gh pr merge` added to that branch (the bypass) must be recorded here —
# the behavioural half of the absence pin (the stubs above never put `gh` on PATH).
mkdir -p "$TMP/ghspy"
cat > "$TMP/ghspy/gh" <<'GHSPY'
#!/bin/bash
printf '%s\n' "$*" >> "${GH_SPY:?gh-spy invoked without GH_SPY}"
exit 0
GHSPY
chmod +x "$TMP/ghspy/gh"
: > "$TMP/railO/gh-spy.txt"
( PATH="$TMP/ghspy:$PATH"; export GH_SPY="$TMP/railO/gh-spy.txt"; MERGE_AUTHORITY=rail; REPO="$TMP/railrepo"; PR=1764; OR=daniel-ospina/agent-infra; \
  L="$TMP/railO/merge.log"; O="$TMP/railO"; HEAD=cccc3333; \
  . "$TMP/railbranch.sh" ) >/dev/null 2>&1; src2=$?
[ ! -s "$TMP/railO/gh-spy.txt" ] \
  && { echo "  ✅ …and the rail path issued NO gh call at all (a gh spy on PATH saw nothing)"; PASS=$((PASS+1)); } \
  || { echo "  ❌ the rail path invoked gh: [$(tr '\n' ';' < "$TMP/railO/gh-spy.txt")] — the raw-merge bypass this branch forbids"; FAIL=$((FAIL+1)); }
[ "$src2" = "0" ] && [ -f "$TMP/railO/state/merged-1764.done" ] \
  && { echo "  ✅ the rail IS invoked with RAIL_TRIES unset (the merge is recorded — rail mode is reachable)"; PASS=$((PASS+1)); } \
  || { echo "  ❌ the rail was never invoked (rc=$src2, merged-marker=$([ -f "$TMP/railO/state/merged-1764.done" ] && echo yes || echo no)) — rail mode is DEAD, exactly the #1764 deadlock)"; FAIL=$((FAIL+1)); }
_rail_cwd="$(sed -n 1p "$TMP/railO/rail-argv.txt" 2>/dev/null)"; _rail_args="$(sed -n 2p "$TMP/railO/rail-argv.txt" 2>/dev/null)"
case "$_rail_args" in
  "1764 --repo daniel-ospina/agent-infra -- --squash") [ "$_rail_cwd" = "$TMP/railrepo" ] \
    && { echo "  ✅ …and the rail is invoked with the documented contract, from the target repo ($_rail_args)"; PASS=$((PASS+1)); } \
    || { echo "  ❌ the rail ran from cwd=$_rail_cwd, not the target repo"; FAIL=$((FAIL+1)); } ;;
  *) echo "  ❌ the rail was invoked as [$_rail_args] — expected '1764 --repo daniel-ospina/agent-infra -- --squash'"; FAIL=$((FAIL+1)) ;;
esac
# …and the success signal must be FALSIFIABLE (review round 6, P2): after a rail that REFUSES at the
# same head, the merge marker must be ABSENT. A mutant that swallows the rail's exit status
# (`} || true; then`) stayed green without this.
rm -f "$TMP/railO/state/merged-1764.done" "$TMP/railO/state/railcount-1764"
printf '#!/bin/bash\nexit 1\n' > "$TMP/railrepo/scripts/admin-merge.sh"; chmod +x "$TMP/railrepo/scripts/admin-merge.sh"
( MERGE_AUTHORITY=rail; REPO="$TMP/railrepo"; PR=1764; OR=daniel-ospina/agent-infra; \
  L="$TMP/railO/merge.log"; O="$TMP/railO"; HEAD=dddd4444; \
  . "$TMP/railbranch.sh" ) >/dev/null 2>&1
[ ! -f "$TMP/railO/state/merged-1764.done" ] \
  && { echo "  ✅ a REFUSING rail records no merge (the success signal is falsifiable, not write-only)"; PASS=$((PASS+1)); } \
  || { echo "  ❌ a refusing rail still recorded a MERGE — the success signal is unfalsifiable"; FAIL=$((FAIL+1)); }
# …and an EMPTY head REFUSES rather than running an un-keyed retry loop (review round 6, P2): with
# HEAD empty the count file is written as " N", `read` yields RC_N="", RC_N resets every pass, the cap
# is unreachable, no park is written, and the sweep re-runs the rail forever — the burn RAIL_TRIES
# exists to close.
printf '#!/bin/bash\nexit 1\n' > "$TMP/railrepo/scripts/admin-merge.sh"; chmod +x "$TMP/railrepo/scripts/admin-merge.sh"
# ⛔ TRUNCATE BEFORE THE DRIVE (review round 7, P2): the log is SHARED with the missing-rail drive
# above (same $L), which already wrote a `REFUSED` line into it — so the `_hits` half of the
# assertion below was satisfied by a STALE artifact and could never fail. Proven by mutation:
# deleting the empty-head `REFUSED` echo from merge-one.sh (leaving `exit 7`) still reported 88/0.
# `: >`, never `rm -f`: an ABSENT file is not what the assertion reads (drive_green does the same).
: > "$TMP/railO/merge.log.log"
( MERGE_AUTHORITY=rail; REPO="$TMP/railrepo"; PR=1764; OR=daniel-ospina/agent-infra; \
  L="$TMP/railO/merge.log"; O="$TMP/railO"; HEAD=''; \
  . "$TMP/railbranch.sh" ) >/dev/null 2>&1; ehrc=$?
_hits=0; for _i in 1 2 3 4; do
  ( MERGE_AUTHORITY=rail; REPO="$TMP/railrepo"; PR=1764; OR=daniel-ospina/agent-infra; \
    L="$TMP/railO/merge.log"; O="$TMP/railO"; HEAD=''; . "$TMP/railbranch.sh" ) >/dev/null 2>&1
  # The message is specific to the EMPTY-head refusal, not just any `REFUSED` — a stale or
  # different refusal cannot satisfy it.
  grep -qs 'REFUSED: the PR head could not be read' "$TMP/railO/merge.log.log" && _hits=1
done
[ "$ehrc" = "7" ] && [ "$_hits" = "1" ] \
  && { echo "  ✅ an EMPTY head REFUSES (exit 7) instead of running an un-keyed, never-parking retry loop"; PASS=$((PASS+1)); } \
  || { echo "  ❌ an empty head exited $ehrc (want 7, log-hit=$_hits) — the cap is unreachable without a head, so the rail is re-run every cycle"; FAIL=$((FAIL+1)); }

# (g3) the count is HEAD-KEYED, so a count file from a DIFFERENT head must NOT block the new head
# (review round 7, P2): without the reset the worker sees the old head's count at the cap and PARKS
# the new head without ever running the rail — the stale-park deadlock of round 1, one layer down.
cat > "$TMP/railrepo/scripts/admin-merge.sh" <<RAILSTUB
#!/bin/bash
printf '%s\n' "\$PWD" "\$*" > "$TMP/railO/rail-argv.txt"
exit 0
RAILSTUB
chmod +x "$TMP/railrepo/scripts/admin-merge.sh"
rm -f "$TMP/railO/state/merged-1764.done" "$TMP/railO/rail-argv.txt"
printf '%s %s\n' aaaa1111 3 > "$TMP/railO/state/railcount-1764"    # an OLDER head, already AT the cap
printf '%s\n' aaaa1111 > "$TMP/railO/state/parked-1764"
( MERGE_AUTHORITY=rail; REPO="$TMP/railrepo"; PR=1764; OR=daniel-ospina/agent-infra; \
  L="$TMP/railO/merge.log"; O="$TMP/railO"; HEAD=eeee5555; \
  . "$TMP/railbranch.sh" ) >/dev/null 2>&1; nhrc=$?
[ "$nhrc" = "0" ] && [ -f "$TMP/railO/state/merged-1764.done" ] \
  && { echo "  ✅ a NEW head RE-ARMS the head-keyed budget (a stale count cannot park a head the rail never saw)"; PASS=$((PASS+1)); } \
  || { echo "  ❌ a new head hit the OLD head's cap (rc=$nhrc, merged=$([ -f "$TMP/railO/state/merged-1764.done" ] && echo yes || echo no), parked=[$(cat "$TMP/railO/state/parked-1764" 2>/dev/null)]) — the rail never ran"; FAIL=$((FAIL+1)); }

# (g4) the COERCIONS are load-bearing (review round 7, P2). A typo'd RAIL_TRIES must not disable the
# cap: `[ 3 -ge 99999999999999999999 ]` errors FALSE on bash 3.2 (the shipped /bin/bash), so
# without the coercion the park never lands and the rail is re-run every cycle — the API burn the
# cap exists to close.
printf '%s %s\n' aaaa1111 3 > "$TMP/railO/state/railcount-1764"
printf '%s\n' zzzz9999 > "$TMP/railO/state/parked-1764"
( MERGE_AUTHORITY=rail; REPO="$TMP/railrepo"; PR=1764; OR=daniel-ospina/agent-infra; RAIL_TRIES=99999999999999999999; \
  L="$TMP/railO/merge.log"; O="$TMP/railO"; HEAD=aaaa1111; \
  . "$TMP/railbranch.sh" ) >/dev/null 2>&1
[ "$(cat "$TMP/railO/state/parked-1764" 2>/dev/null)" = "aaaa1111" ] \
  && { echo "  ✅ a 20-digit RAIL_TRIES is coerced back into range (the cap still trips — bash 3.2 errors that compare FALSE)"; PASS=$((PASS+1)); } \
  || { echo "  ❌ a 20-digit RAIL_TRIES disabled the cap: parked=[$(cat "$TMP/railO/state/parked-1764" 2>/dev/null)] (want aaaa1111) — the rail is re-run every cycle"; FAIL=$((FAIL+1)); }
# …and a CORRUPT count is re-sanitised rather than propagated into the arithmetic.
printf '%s %s\n' aaaa1111 99999999999999999999 > "$TMP/railO/state/railcount-1764"
rm -f "$TMP/railO/state/parked-1764"
( MERGE_AUTHORITY=rail; REPO="$TMP/railrepo"; PR=1764; OR=daniel-ospina/agent-infra; \
  L="$TMP/railO/merge.log"; O="$TMP/railO"; HEAD=aaaa1111; \
  . "$TMP/railbranch.sh" ) >/dev/null 2>&1
_cnt2="$(awk '{print $2}' "$TMP/railO/state/railcount-1764" 2>/dev/null)"
case "${_cnt2:-}" in ''|*[!0-9]*|??????????*) echo "  ❌ a corrupt count was propagated into the arithmetic (railcount now [$_cnt2])"; FAIL=$((FAIL+1)) ;;
  *) echo "  ✅ a corrupt count is reset to a sane value (railcount now [$_cnt2]) — it cannot overflow the cap into wrapping"; PASS=$((PASS+1)) ;; esac

# (h) the controller's GREEN arm dispatches the rail — BEHAVIOURAL (review P2, round 1): the
# 'controller branches on the merge authority' pin greps a condition, which a NEUTERED guard
# (`= "rail" ] && false`) still satisfies while every PR falls through to a raw merge on a rail
# repo — the exact bypass this branch exists to prevent. So the arm is EXTRACTED and DRIVEN with
# mocked gh/tmux: rail authority must tmux-spawn merge-<PR> and issue NO raw merge; gate authority
# must do the reverse.
sed -n '/^      GREEN)$/,/^      PENDING:\*)$/p' "$ORCH" | sed '$d' | sed '$s/ ;;$//' | sed '1d' > "$TMP/greenarm.sh"
# The quoter the spawn line uses must be the SHIPPED one (extracted, not re-implemented) — the
# spawn line calls `shq`, so the drive below must resolve it exactly as the shipped loop does.
# shq is a ONE-LINER, so extract by whole-line grep: a `/^shq() {/,/^}/` sed RANGE never matches its
# own end pattern on that line and swallows the next 57 lines of orch-loop.sh instead (measured).
grep -E '^shq\(\) \{' "$ORCH" > "$TMP/shq.sh"
# shellcheck disable=SC1090
[ -s "$TMP/shq.sh" ] && . "$TMP/shq.sh"
if [ -s "$TMP/greenarm.sh" ] && grep -q 'MERGE_AUTHORITY.*rail' "$TMP/greenarm.sh" && bash -n "$TMP/greenarm.sh" 2>/dev/null; then
  drive_green() { # drive_green <authority> <req> [<gate-name>] -> writes $TMP/g.spy / g.tspy / LOG
    # `: >`, never `rm -f` (review P2, round 2): an ABSENT file made `! grep -q new-session`
    # pass vacuously in the gate drive — the tmux mock never ran, so there was no file to read.
    : > "$TMP/g.spy"; : > "$TMP/g.tspy"; : > "$TMP/g.log"
    ( PR=1765; OR=daniel-ospina/agent-infra; REPO="$TMP/grepo"; BR=fix/x; HEAD_N=deadbeef
      MR=3; MERGE_AUTHORITY="$1"; REQ="$2"; REVIEW_GATE="${3:-ai-review-gate}"
      LOG="$TMP/g.log"; O="$TMP/gO"; mkdir -p "$O/state"
      sess() { return 1; }; claim_live() { return 1; }; can_spawn() { return 0; }
      gh()   { echo "GH $*" >> "$TMP/g.spy"; return 0; }
      tmux() { echo "TMUX $*" >> "$TMP/g.tspy"; [ "$1" = ls ] && return 0; return 0; }
      # shellcheck disable=SC1090
      . "$TMP/shq.sh"
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
  grep -qF -- "REQ=$(shq 'pipeline-compliance')" "$TMP/g.tspy" \
    && { echo "  ✅ GREEN+rail: the spawn line carries REQ=$(grep -o "REQ=[^ ]*" "$TMP/g.tspy" | head -1) (one resolution, one authority)"; PASS=$((PASS+1)); } \
    || { echo "  ❌ GREEN+rail: the spawn line carries no resolved REQ — the worker re-resolves and can disagree"; FAIL=$((FAIL+1)); }
  # The quoting is load-bearing and must be pinned with a MULTI-NAME set (review P2, round 2):
  # with a single token the quoting is a no-op, so the assertion above passes without it — but
  # `sh -c 'REQ=pricing-artifact docs … bash worker'` is `docs: command not found` (rc 127, the
  # worker never runs, no merge ever happens) on the real 7-name tortoise set. Drive it and
  # require the EXACT POSIX-quoted token in the spawn line.
  _REQ7='pricing-artifact docs test-isolation license-surface legal-e2e python-ci-gate ai-review-gate'
  drive_green rail "$_REQ7"
  _EXP7="REQ=$(shq "$_REQ7")"
  if grep -qF -- "$_EXP7" "$TMP/g.tspy"; then
    echo "  ✅ GREEN+rail: a MULTI-name REQ arrives whole (the POSIX-quoted 7-name set is in the spawn line)"; PASS=$((PASS+1))
  else
    echo "  ❌ GREEN+rail: the 7-name set did not survive the spawn line (expected [$_EXP7]; tspy=[$(tr '\n' ';' < "$TMP/g.tspy")]) — an unquoted multi-name REQ kills the worker at sh -c"; FAIL=$((FAIL+1))
  fi
  drive_green rail "$_REQ7" my-gate
  _EXPG="REVIEW_GATE=$(shq 'my-gate')"
  if grep -qF -- "$_EXPG" "$TMP/g.tspy"; then
    echo "  ✅ GREEN+rail: a NON-DEFAULT REVIEW_GATE is carried to the worker too (one resolution, one authority)"; PASS=$((PASS+1))
  else
    echo "  ❌ GREEN+rail: the spawn line dropped REVIEW_GATE=[$_EXPG] (tspy=[$(tr '\n' ';' < "$TMP/g.tspy")]) — the worker re-resolves with the DEFAULT gate name and can disagree with the controller about the authority"; FAIL=$((FAIL+1))
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
# every merge spawn line must POSIX-quote the carried REQ — BOTH of them (review round 3: a single
# grep over a file with two identical lines let ONE de-quoted spawn stay green; an unquoted
# 7-name REQ kills the worker at sh -c rc 127). Count, don't just find.
_QPAT='REQ=$(shq "$REQ")'
_NQ="$(grep -cF -- "$_QPAT" "$ORCH")"
[ "${_NQ:-0}" = "2" ] \
  && { echo "  ✅ every merge spawn line (${_NQ} of 2) POSIX-quotes the carried REQ"; PASS=$((PASS+1)); } \
  || { echo "  ❌ expected 2 POSIX-quoted spawn lines, found ${_NQ:-0} — one spawn's worker dies at sh -c on a multi-name REQ"; FAIL=$((FAIL+1)); }
# …and the GATE NAME must travel with it (review round 7, P2): §h's old guard counted only REQ, so
# dropping REVIEW_GATE from the spawn line stayed green — and a worker that re-resolves under the
# DEFAULT gate name can land on a different authority than the controller classified under.
_GPAT='REVIEW_GATE=$(shq "$REVIEW_GATE")'
_NG="$(grep -cF -- "$_GPAT" "$ORCH")"
[ "${_NG:-0}" = "2" ] \
  && { echo "  ✅ every merge spawn line (${_NG} of 2) POSIX-quotes the carried REVIEW_GATE"; PASS=$((PASS+1)); } \
  || { echo "  ❌ expected 2 POSIX-quoted REVIEW_GATE carriers, found ${_NG:-0} — a worker can re-resolve under the default gate name and disagree about the authority"; FAIL=$((FAIL+1)); }
  # ⛔ round-10 review, P2. The arm's final `else` issued a RAW `gh pr merge` for ANY authority that
  # was not `rail` — INCLUDING `unknown`, which `_normalise_set` now returns when it cannot run. So a
  # normaliser failure could raw-merge: the exact bypass this change exists to prevent. Drive the
  # shipped arm with an UNKNOWN authority; it must merge nothing.
  drive_green unknown "$_REQ7"
  if ! grep -q -- '--squash' "$TMP/g.spy"; then
    echo "  ✅ GREEN+unknown: NO raw merge is issued (an authority that names neither gate nor rail merges nothing)"; PASS=$((PASS+1))
  else
    echo "  ❌ GREEN+unknown: a RAW merge was issued for an unknown authority — spy=[$(tr '\n' ';' < "$TMP/g.spy")]"; FAIL=$((FAIL+1))
  fi
  grep -q 'merge authority is' "$TMP/g.log" \
    && { echo "  ✅ GREEN+unknown: the refusal is LOGGED, naming the authority (a silent no-op is indistinguishable from a hang)"; PASS=$((PASS+1)); } \
    || { echo "  ❌ GREEN+unknown: no refusal log line — the arm refuses silently"; FAIL=$((FAIL+1)); }
# ⛔ ANY spelling of `printf %q`, not just `printf '%q'` (round-9 review, P3: the single-quoted
# spelling alone let `printf %q "$1"` through). Comments are excluded (`^[^#]*`) because this file
# DOCUMENTS the rule in prose — an unanchored match counted its own documentation as a violation.
# The assertion runs after the drive below, so the drive's own evidence is printed first.
if [ -s "$TMP/shq.sh" ]; then
  # shellcheck disable=SC1090
  . "$TMP/shq.sh"
  command -v shq >/dev/null 2>&1 \
    && { echo "  ✅ shq() extracted from the shipped orch-loop.sh and is callable"; PASS=$((PASS+1)); } \
    || { echo "  ❌ the extracted $TMP/shq.sh does not define shq() — extraction is broken"; FAIL=$((FAIL+1)); }
  # a quote AND a control byte, plus shell metacharacters and ${IFS} — the exact shape that makes
  # `printf %q` emit `$'…'` and lets dash re-parse the remainder as commands.
  _PAY="a'$(printf '\033');touch\${IFS}$TMP/PWNED;#"
  rm -f "$TMP/PWNED" "$TMP/shq-got"
  # The property being pinned is POSIX-sh SAFETY, so exercise a REAL POSIX sh where one exists.
  # On macOS /bin/sh is bash, which ACCEPTS `$'…'` and therefore hides the very defect class this
  # drive exists to catch (round-9 review, P3: a `printf %q` quoter passes this suite on macOS and
  # executes the payload under dash). Prefer dash; naming the shell keeps a macOS green from
  # reading as dash-safety.
  _DSH="$(command -v dash 2>/dev/null || printf '/bin/sh')"
  case "${_DSH##*/}" in
    dash) _DKIND=dash ;;
    *)    _DKIND="$("$_DSH" -c '[ -n "${BASH_VERSION:-}" ] && printf bash || printf posix-sh' 2>/dev/null)" ;;
  esac
  "$_DSH" -c "REQ=$(shq "$_PAY"); printf '%s' \"\$REQ\" > '$TMP/shq-got'" 2>/dev/null
  if [ -f "$TMP/PWNED" ]; then
    echo "  ❌ a control byte in a required-check name EXECUTED through the spawn shape — the carried contract is injectable under /bin/sh"; FAIL=$((FAIL+1))
  elif [ "$(cat "$TMP/shq-got" 2>/dev/null)" = "$_PAY" ]; then
    if [ "${_DKIND:-}" = "bash" ]; then
      # ⛔ A SKIP IS NOT A PASS (round-10 review, P3). bash ACCEPTS `$'…'`, so it cannot discriminate
      # a dash-unsafe quoter — and counting this green is exactly what let a `printf %q` quoter pass
      # this suite on macOS. The always-on guarantee is the `printf %q`-absence pin below.
      echo "  ⊘ POSIX-sh injection drive SKIPPED — this box's sh is bash, which accepts \$'…' and so cannot discriminate a dash-unsafe quoter; CI's ubuntu sh is dash. (The `printf %q`-absence pin below still applies.)"
    else
      echo "  ✅ a quote + control-byte name survives a POSIX sh -c WHOLE and executes nothing (shell=${_DKIND:-?} at ${_DSH})"; PASS=$((PASS+1))
    fi
  else
    echo "  ❌ the payload was mangled by the shipped shq (got [$(cat "$TMP/shq-got" 2>/dev/null | od -c | head -2 | tr '\n' ' ')])"; FAIL=$((FAIL+1))
  fi
else
  echo "  ❌ shq() could not be extracted from orch-loop.sh — the injection drive did NOT run (a skipped check is not a pass)"; FAIL=$((FAIL+1))
fi
# ⛔ ANY spelling of `printf %q` ANYWHERE after `printf` on a non-comment line. The previous form
# required `%q` to sit one character after `printf`'s whitespace, so `printf -- '%q'`, `printf "%q"`
# and `printf 'REQ=%q'` all passed it (round-10 review, P3 — "any spelling" was false).
# Full-line comments are stripped first because this file DOCUMENTS the rule in prose — an
# unanchored match counted its own documentation as a violation.
_QPCT="$(grep -vE '^[[:space:]]*#' "$ORCH" | grep -cE 'printf.*%q')"
[ "${_QPCT:-0}" = "0" ] \
  && { echo "  ✅ no \`printf %q\` site remains in orch-loop.sh (any spelling; its \`\$'…'\` output is not POSIX quoting)"; PASS=$((PASS+1)); } \
  || { echo "  ❌ ${_QPCT} \`printf %q\` site(s) remain in orch-loop.sh — dash re-parses that value as commands"; FAIL=$((FAIL+1)); }

# (i) AUTHORITY_UNKNOWN is REAL (review P2, round 2 — it had zero coverage and could be deleted
# without a red). Two halves: the guard's EXPRESSION does continue when set, and it sits BEFORE
# the classifier (a guard moved after the arms guards nothing).
_au_expr='[ "${AUTHORITY_UNKNOWN:-0}" = "1" ] && continue'
# ⛔ round-10 review, P2: the DERIVATION ignored MERGE_AUTHORITY, so an authority of `unknown`
# (which `_normalise_set` now returns when it cannot run) left AUTHORITY_UNKNOWN=0 and fell through
# to the merge arms — where the GREEN arm's old bare `else` issued a RAW merge. Pin the clause in
# non-comment code only, so a comment mention cannot satisfy it.
grep -vE '^[[:space:]]*#' "$ORCH" | grep -qF -- '[ "${MERGE_AUTHORITY:-}" = "unknown" ]' \
  && { echo "  ✅ the AUTHORITY_UNKNOWN derivation ALSO trips on an unknown MERGE_AUTHORITY (not only on REQ/fallback)"; PASS=$((PASS+1)); } \
  || { echo "  ❌ the derivation ignores MERGE_AUTHORITY — an unreadable authority is not treated as unknown, so the merge arms run on it"; FAIL=$((FAIL+1)); }
_au_ln="$(grep -nF -- "$_au_expr" "$ORCH" | head -1 | cut -d: -f1)"
_cls_ln="$(grep -nF 'V="$(gh pr checks' "$ORCH" | head -1 | cut -d: -f1)"
if [ -n "$_au_ln" ] && [ -n "$_cls_ln" ] && [ "$_au_ln" -lt "$_cls_ln" ]; then
  echo "  ✅ AUTHORITY_UNKNOWN guard exists and precedes the classifier (line $_au_ln < $_cls_ln)"; PASS=$((PASS+1))
else
  echo "  ❌ AUTHORITY_UNKNOWN guard missing or misplaced (guard@${_au_ln:-none} classifier@${_cls_ln:-none}) — deleted, the sweep acts on an unknown contract"; FAIL=$((FAIL+1))
fi
_au_hits=0; AUTHORITY_UNKNOWN=1
# ⚠️ review round 3: the previous half evaluated a TEST-LOCAL copy of the expression, so a
# shipped guard wrapped in a dead branch stayed green. Drive the SHIPPED pre-classifier block
# (HEAD_N fetch → parked check → authority check) with mocked gh: when set, NO PR reaches the
# sentinel after it; when clear, both do.
sed -n '/^    HEAD_N="\$(gh pr view/,/AUTHORITY_UNKNOWN:-0.*] && continue/p' "$ORCH" > "$TMP/aublock.sh"
if [ -s "$TMP/aublock.sh" ] && bash -n "$TMP/aublock.sh" 2>/dev/null; then
  mkdir -p "$TMP/auO/state"
  _au_run() { # _au_run <flag> -> prints how many PRs passed the guard
    _c=0
    _ghsave="$(declare -f gh 2>/dev/null)"
    for PR in 1111 2222; do
      AUTHORITY_UNKNOWN="$1"; OR=daniel-ospina/agent-infra; O="$TMP/auO"
      gh() { case "$1 $2" in "pr view") echo deadbeef ;; *) return 1 ;; esac; }
      # shellcheck disable=SC1090
      . "$TMP/aublock.sh"
      _c=$((_c+1))   # reached only when no `continue` fired
    done
    [ -n "$_ghsave" ] && eval "$_ghsave" || unset -f gh 2>/dev/null
    echo "$_c"
  }
  [ "$(_au_run 1)" = "0" ] && { echo "  ✅ the SHIPPED guard continues every PR when set (dead-branch wrapping would break extraction or this)"; PASS=$((PASS+1)); } \
    || { echo "  ❌ the shipped guard did not continue every PR when set"; FAIL=$((FAIL+1)); }
  [ "$(_au_run 0)" = "2" ] && { echo "  ✅ …and lets every PR through when clear"; PASS=$((PASS+1)); } \
    || { echo "  ❌ the shipped guard continued when clear"; FAIL=$((FAIL+1)); }
else
  echo "  ❌ could not extract the shipped AUTHORITY_UNKNOWN block from orch-loop.sh"; FAIL=$((FAIL+1))
fi
AUTHORITY_UNKNOWN=0; _au_hits=0

# (j) the WORKER refuses an unknown contract — BEHAVIOURAL (review P1, round 2): the controller
# guard covers only the sweep; chain-merge.sh and fix-one.sh invoke merge-one.sh directly. Drive
# the shipped guard: fallback + no override must exit 5 BEFORE any reviewer; fallback + override
# must proceed (and then hit the missing-rail refusal, exit 6 — proving the override path).
sed -n '/^if \[ -z "${REQ:-}" \] || \[ "$MERGE_AUTHORITY" = "unknown" \]/,/^fi$/p' "$MERGE" > "$TMP/worker-guard.sh"
if [ -s "$TMP/worker-guard.sh" ] && bash -n "$TMP/worker-guard.sh" 2>/dev/null; then
  ( REQ_SOURCE=fallback; REQ_OVERRIDE=''; REQ=''; MERGE_AUTHORITY='unknown'; PR=1766; OR=daniel-ospina/agent-infra; \
    L="$TMP/wg"; O="$TMP"; . "$TMP/worker-guard.sh" ) >/dev/null 2>&1; wgrc=$?
  [ "$wgrc" = "5" ] && { echo "  ✅ a worker whose protection read FAILED refuses (exit 5) before any reviewer"; PASS=$((PASS+1)); } \
    || { echo "  ❌ worker guard exited $wgrc, not 5 — an unknown contract can still merge via a non-sweep ingress"; FAIL=$((FAIL+1)); }
  ( REQ_SOURCE=fallback; REQ_OVERRIDE='pipeline-compliance'; REQ='pipeline-compliance'; MERGE_AUTHORITY='rail'; PR=1766; OR=daniel-ospina/agent-infra; \
    L="$TMP/wg2"; O="$TMP"; . "$TMP/worker-guard.sh" ) >/dev/null 2>&1; wg2rc=$?
  [ "$wg2rc" != "5" ] && { echo "  ✅ an explicit REQ override still proceeds (the refusal is about NOT KNOWING, not about overriding)"; PASS=$((PASS+1)); } \
    || { echo "  ❌ the worker guard refused a valid operator override"; FAIL=$((FAIL+1)); }
  # ⚠️ review round 4: the sandbox above sets REQ='' AND MERGE_AUTHORITY=unknown, so the first two
  # disjuncts already fire and the THIRD — a non-empty FALLBACK_REQ read as `fallback` (gate
  # authority) with no override — was never exercised; deleting it stayed green in every suite.
  # That is the case that used to burn a full fresh-context reviewer first on an unreadable read.
  ( REQ_SOURCE=fallback; REQ_OVERRIDE=''; REQ="$FALLBACK_REQ"; MERGE_AUTHORITY="$(merge_authority "$FALLBACK_REQ")"; PR=1766; OR=daniel-ospina/tortoise; \
    L="$TMP/wg3"; O="$TMP"; . "$TMP/worker-guard.sh" ) >/dev/null 2>&1; wg3rc=$?
  [ "$wg3rc" = "5" ] && { echo "  ✅ a NON-EMPTY fallback contract ($FALLBACK_REQ, authority=gate) with no override still refuses (exit 5)" ; PASS=$((PASS+1)); } \
    || { echo "  ❌ the fallback disjunct is dead: a gate-authority fallback with no override exited $wg3rc, not 5"; FAIL=$((FAIL+1)); }
  # ⚠️ review round 3: §j sourced the fragment standalone, so the guard's POSITION was unpinned
  # — moved after run_agent it would refuse only AFTER the reviewer ran and was paid for.
  _wg_ln="$(grep -n 'REFUSED: branch protection' "$MERGE" | head -1 | cut -d: -f1)"
  _ra_ln="$(grep -n '^run_agent "' "$MERGE" | head -1 | cut -d: -f1)"
  [ -n "$_wg_ln" ] && [ -n "$_ra_ln" ] && [ "$_wg_ln" -lt "$_ra_ln" ] \
    && { echo "  ✅ the refusal sits BEFORE the reviewer (line $_wg_ln < run_agent @ $_ra_ln)"; PASS=$((PASS+1)); } \
    || { echo "  ❌ the refusal moved after the reviewer (refusal@${_wg_ln:-none} run_agent@${_ra_ln:-none}) — it must fire before any reviewer is paid"; FAIL=$((FAIL+1)); }
else
  echo "  ❌ could not extract the worker authority-unknown guard from merge-one.sh"; FAIL=$((FAIL+1))
fi

# (k) the FAILED arm's gate test is WHOLE-NAME (review P2, round 2): `grep -qF` matched a
# substring, so REVIEW_GATE=compliance misrouted a red pipeline-compliance into the review arm
# while merge_authority correctly said rail. Extract the shipped derivation and drive both.
sed -n '/^        _gate_hit=0; _gifs=/,/^        .*IFS="\$_gifs"$/p' "$ORCH" > "$TMP/gatehit.sh"
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
  # ⚠️ review round 4: the loop needs `set -f` too — an unquoted ${V#FAILED:} GLOB-EXPANDS against
  # the controller's cwd (the target repo), so a red check name containing a metacharacter is
  # rewritten by whatever files happen to be there. Drive it from a dir holding a file named
  # exactly like the gate: without `set -f` the glob expands to that filename and fakes a hit.
  _gdir="$TMP/globdir"; mkdir -p "$_gdir"; : > "$_gdir/ai-review-gate"
  _gh_hit="$( cd "$_gdir" && REVIEW_GATE=ai-review-gate; V='FAILED:*'; _gate_hit=0
    # shellcheck disable=SC1090
    . "$TMP/gatehit.sh"; printf '%s' "${_gate_hit:-}" )"
  [ "$_gh_hit" = "0" ] && { echo "  ✅ a metacharacter in a red name is a LITERAL token (no glob against the cwd)"; PASS=$((PASS+1)); } \
    || { echo "  ❌ the FAILED-list split glob-expanded: a file named ai-review-gate in the cwd faked a gate hit (${_gh_hit})"; FAIL=$((FAIL+1)); }
else
  echo "  ❌ could not extract the gate-hit derivation from orch-loop.sh"; FAIL=$((FAIL+1))
fi

# (l) the PENDING arm never arms --auto on a rail repo — BEHAVIOURAL (review round 3: the guard
# had zero coverage; `if true` kept 59/0 green while --auto merged on the required checks alone,
# bypassing the rail — the exact bypass this branch exists to prevent).
sed -n '/^      PENDING:\*)$/,/^      FAILED:\*)$/p' "$ORCH" | sed '$d' | sed '$s/ ;;$//' | sed '1d' > "$TMP/pendingarm.sh"
if [ -s "$TMP/pendingarm.sh" ] && bash -n "$TMP/pendingarm.sh" 2>/dev/null; then
  _drive_pending() { # <authority> -> writes g.spy / g.log
    : > "$TMP/g.spy"; : > "$TMP/g.log"
    ( PR=1767; OR=daniel-ospina/agent-infra; MERGE_AUTHORITY="$1"; LOG="$TMP/g.log"; O="$TMP/gO"
      gh()   { echo "GH $*" >> "$TMP/g.spy"; return 0; }
      # shellcheck disable=SC1090
      . "$TMP/pendingarm.sh" ) >/dev/null 2>&1
  }
  _drive_pending rail
  if ! grep -q -- '--auto' "$TMP/g.spy" && grep -q 'NOT armed' "$TMP/g.log"; then
    echo "  ✅ PENDING+rail: --auto is NOT armed (the log says so)"; PASS=$((PASS+1))
  else
    echo "  ❌ PENDING+rail: spy=[$(tr '\n' ';' < "$TMP/g.spy")] log=[$(tr '\n' ';' < "$TMP/g.log")] — arming --auto on a rail repo bypasses the rail"; FAIL=$((FAIL+1))
  fi
  _drive_pending gate
  if grep -q -- '--auto' "$TMP/g.spy"; then
    echo "  ✅ PENDING+gate: --auto IS armed (tortoise's behaviour unchanged)"; PASS=$((PASS+1))
  else
    echo "  ❌ PENDING+gate: spy=[$(tr '\n' ';' < "$TMP/g.spy")] — gate repos must arm --auto exactly as before"; FAIL=$((FAIL+1))
  fi
else
  echo "  ❌ could not extract a valid PENDING arm from orch-loop.sh"; FAIL=$((FAIL+1))
fi

# (m) BOTH orch-loop park refreshes are driven (review round 3: they were only grep-pinned, so
# the stale-park re-spawn loop could silently return). Extract each 4-line block by its unique
# PARKED message and drive it with a STALE older-head park at the cap: the new head must land.
_drive_park() { # <anchor-regex> <label>
  awk -v anc="$1" 'index($0, anc) > 0 { print prev; print; if ((getline c) > 0) print c; if ((getline d) > 0) print d; exit } { prev=$0 }' "$ORCH" > "$TMP/parkblk.sh"
  if [ -s "$TMP/parkblk.sh" ] && bash -n "$TMP/parkblk.sh" 2>/dev/null; then
    mkdir -p "$TMP/pkO/state"; printf '%s\n' aaaa1111 > "$TMP/pkO/state/parked-2317"
    ( PR=2317; HEAD_N=bbbb2222; NFC=3; NFC2=3; V='FAILED:docs'; LOG="$TMP/pkO/park.log"; O="$TMP/pkO"
      # shellcheck disable=SC1090
      . "$TMP/parkblk.sh" ) >/dev/null 2>&1
    _pk="$(cat "$TMP/pkO/state/parked-2317" 2>/dev/null)"
    [ "$_pk" = "bbbb2222" ] && { echo "  ✅ $2: the park is REFRESHED to the new head (a stale older-head park cannot block it)"; PASS=$((PASS+1)); } \
      || { echo "  ❌ $2: parked=[$_pk] (expected bbbb2222) — the stale-park re-spawn loop is back"; FAIL=$((FAIL+1)); }
  else
    echo "  ❌ $2: could not extract the park block"; FAIL=$((FAIL+1))
  fi
}
_drive_park 'PARKED (still CONFLICTING after' 'CONFLICTING-arm park refresh'
_drive_park 'PARKED (CI still red after' 'CI-red-arm park refresh'

# (n) a spaced context name is REJECTED as a failed read (review round 3: `ci / lint` in the
# required set would split into three names and sit PENDING forever — silently). It must
# refuse LOUDLY: rc 1 from required_checks, fallback from the resolver, stderr names the cause.
_spg="$TMP/spaced-gh"
printf '#!/bin/bash\ncase "$*" in *required_status_checks*) printf "ci / lint\\n" ;; *) exit 1 ;; esac\n' > "$_spg"; chmod +x "$_spg"
_sp_out="$(required_checks daniel-ospina/spaced "$_spg" 2>"$TMP/spaced.err")"; _sp_rc=$?
if [ "$_sp_rc" != "0" ] && grep -q 'contains whitespace' "$TMP/spaced.err" 2>/dev/null; then
  echo "  ✅ a spaced required name (\`ci / lint\`) is a FAILED read, loudly — not a silent 3-name split"; PASS=$((PASS+1))
else
  echo "  ❌ a spaced required name was not rejected loudly (rc=$_sp_rc err=[$(cat "$TMP/spaced.err" 2>/dev/null)])"; FAIL=$((FAIL+1))
fi
REQ_SOURCE=''; resolve_required_checks daniel-ospina/spaced "$_spg" 2>/dev/null
[ "${REQ_SOURCE:-}" = "fallback" ] && { echo "  ✅ …and the resolver answers fallback (authority-unknown: the sweep and every worker refuse)"; PASS=$((PASS+1)); } \
  || { echo "  ❌ the resolver did not treat the spaced read as fallback (source=${REQ_SOURCE:-?})"; FAIL=$((FAIL+1)); }

# (n2) …and the SAME for a COMMA (review round 4). The required set is SPACE-joined but the RED set
# the controller derives is COMMA-joined, so `a,b` passes the whitespace screen and then splits
# into two names in the FAILED arm — the same silent misroute, one layer down.
_cmg="$TMP/comma-gh"
printf '#!/bin/bash\ncase "$*" in *required_status_checks*) printf "ci,lint\\n" ;; *) exit 1 ;; esac\n' > "$_cmg"; chmod +x "$_cmg"
_cm_out="$(required_checks daniel-ospina/comma "$_cmg" 2>"$TMP/comma.err")"; _cm_rc=$?
if [ "$_cm_rc" != "0" ] && grep -q 'contains whitespace or a comma' "$TMP/comma.err" 2>/dev/null; then
  echo "  ✅ a comma in a required name is a FAILED read, loudly — it would split in the comma-joined RED list"; PASS=$((PASS+1))
else
  echo "  ❌ a comma-bearing required name was not rejected (rc=$_cm_rc out=[$_cm_out] err=[$(cat "$TMP/comma.err" 2>/dev/null)])"; FAIL=$((FAIL+1))
fi

# (n3) …and an rc-0 read with NO contexts is a FAILED read, not "this repo requires nothing"
# (review round 4: the guard was unpinned — deleting it stayed green everywhere). This is
# defence in depth: the consumers refuse an empty REQ anyway, but the header's promise ("an
# unreadable protection endpoint NEVER becomes an EMPTY required set") must be pinned here.
_emg="$TMP/empty-gh"
printf '#!/bin/bash\nexit 0\n' > "$_emg"; chmod +x "$_emg"
_em_out="$(required_checks daniel-ospina/empty "$_emg" 2>/dev/null)"; _em_rc=$?
if [ "$_em_rc" != "0" ] && [ -z "$_em_out" ]; then
  echo "  ✅ an rc-0 read with no contexts is a FAILED read (never \"requires nothing\")"; PASS=$((PASS+1))
else
  echo "  ❌ an empty rc-0 read returned rc=$_em_rc out=[$_em_out] — it must be a failed read"; FAIL=$((FAIL+1))
fi
REQ='x'; REQ_SOURCE='x'; resolve_required_checks daniel-ospina/empty "$_emg" 2>/dev/null
[ "${REQ_SOURCE:-}" = "fallback" ] && { echo "  ✅ …so the resolver falls back (authority-unknown: nothing merges on an empty read)"; PASS=$((PASS+1)); } \
  || { echo "  ❌ an empty read resolved as source=${REQ_SOURCE:-?} REQ=[$REQ]"; FAIL=$((FAIL+1)); }

# (q) `merge_authority` honours the CONFIGURED review-gate name, not a hardcoded literal (review
# round 4: hardcoding `ai-review-gate` stayed green while diverging the classifier from the
# authority decision — a custom-gate repo would be routed to the rail while the classifier still
# enforced the gate).
[ "$(REVIEW_GATE=my-gate merge_authority 'my-gate other')" = "gate" ] \
  && { echo "  ✅ a custom REVIEW_GATE name still reads gate (the gate name is repo-dependent)"; PASS=$((PASS+1)); } \
  || { echo "  ❌ merge_authority ignored a non-default REVIEW_GATE: got [$(REVIEW_GATE=my-gate merge_authority 'my-gate other')]"; FAIL=$((FAIL+1)); }
[ "$(REVIEW_GATE=my-gate merge_authority 'other only')" = "rail" ] \
  && { echo "  ✅ …and a set without the configured gate reads rail"; PASS=$((PASS+1)); } \
  || { echo "  ❌ a set without the configured gate did not read rail"; FAIL=$((FAIL+1)); }

# (p) the CONTROLLER's AUTHORITY_UNKNOWN DERIVATION is driven from the shipped lines (review
# round 4: §i sets the flag directly, so the derivation could be forced to 0 — the sweep would
# then act on an unknown contract, the exact burn loop the fallback exists to prevent).
sed -n '/^  resolve_required_checks "\$OR"$/,/^  fi$/p' "$ORCH" > "$TMP/deriv.sh"
if [ -s "$TMP/deriv.sh" ] && bash -n "$TMP/deriv.sh" 2>/dev/null; then
  # A separate script, not an inline subshell: the fragment must source AFTER the stubs exist, and
  # a function-definition inside `( … )` inside a function does not parse.
  cat > "$TMP/deriv-drive.sh" <<'DRV'
#!/usr/bin/env bash
OR=x; LOG=/dev/null; D_REQ="$1"; D_SRC="$2"
resolve_required_checks() { REQ="$D_REQ"; REQ_SOURCE="$D_SRC"; return 0; }
merge_authority() { printf '%s\n' "$D_AUTH"; }
. "$DERIV" >/dev/null 2>&1
printf '%s' "${AUTHORITY_UNKNOWN:-}"
DRV
  _au_derive() { DERIV="$TMP/deriv.sh" bash "$TMP/deriv-drive.sh" "$1" "$2"; }
  for _case in "fallback:1" "protection:0"; do
    _src="${_case%%:*}"; _want="${_case##*:}"
    _got="$(_au_derive 'pipeline-compliance' "$_src")"
    [ "$_got" = "$_want" ] && { echo "  ✅ derivation: REQ non-empty + source=$_src -> AUTHORITY_UNKNOWN=$_want"; PASS=$((PASS+1)); } \
      || { echo "  ❌ derivation: source=$_src gave AUTHORITY_UNKNOWN=$_got (want $_want)"; FAIL=$((FAIL+1)); }
  done
  _got="$(_au_derive '' protection)"
  [ "$_got" = "1" ] && { echo "  ✅ derivation: an EMPTY contract is unknown even when the source says protection"; PASS=$((PASS+1)); } \
    || { echo "  ❌ derivation: an empty contract gave AUTHORITY_UNKNOWN=$_got (want 1)"; FAIL=$((FAIL+1)); }
else
  echo "  ❌ could not extract the AUTHORITY_UNKNOWN derivation from orch-loop.sh"; FAIL=$((FAIL+1))
fi

# (s) an override that CHANGES the merge authority away from the repo's own declaration is LOUD
# (review round 4). The override still wins — it is the documented way to pin a contract during
# an outage — but a silent flip from `rail` to `gate` re-enables the raw merge this branch exists
# to prevent, and REQ/REVIEW_GATE are read from the environment (a cloud cell sources keys.env
# with `set -a`). Drive the shipped block: a disagreeing override warns, an agreeing one does not.
sed -n '/^  if \[ "\${REQ_SOURCE:-}" = "env" \] ||/,/^  fi$/p' "$ORCH" > "$TMP/ovr.sh"
if [ -s "$TMP/ovr.sh" ] && bash -n "$TMP/ovr.sh" 2>/dev/null; then
  _ovr() { # <own-set> <authority> <override-set> -> prints the log
    # required_checks is stubbed to return the OWN declaration (arg 1) regardless of the repo
    # argument — the block under test calls it as `required_checks "$OR"`, so a stub keyed on $1
    # would hand it the repo NAME and the baseline authority would be computed from nonsense.
    ( OR=daniel-ospina/agent-infra; LOG="$TMP/ovr.log"; : > "$LOG"; REQ_SOURCE=env; REQ="$3"
      MERGE_AUTHORITY="$2"; OWN_SET="$1"; required_checks() { printf '%s\n' "$OWN_SET"; }
      # shellcheck disable=SC1090
      . "$TMP/ovr.sh" >/dev/null 2>&1; cat "$LOG" )
  }
  _o1="$(_ovr 'pipeline-compliance' 'gate' 'pipeline-compliance ai-review-gate')"
  case "$_o1" in
    *"CHANGES the merge authority"*) echo "  ✅ an override that flips rail->gate is logged as an authority CHANGE (never silent)"; PASS=$((PASS+1)) ;;
    *) echo "  ❌ an authority-changing override was silent — log=[$_o1]"; FAIL=$((FAIL+1)) ;;
  esac
  _o2="$(_ovr 'ai-review-gate docs' 'gate' 'ai-review-gate docs')"
  case "$_o2" in
    *"CHANGES the merge authority"*) echo "  ❌ an override that AGREES with the repo's declaration drew a false change warning"; FAIL=$((FAIL+1)) ;;
    *) echo "  ✅ an override that agrees with the repo's own declaration warns about nothing (gate repo, gate name required)"; PASS=$((PASS+1)) ;;
  esac
  # ⚠️ review round 6, P1: this drive must be PRODUCTION-FAITHFUL. It used to hand-set
  # MERGE_AUTHORITY='rail' while leaving REVIEW_GATE at the default — a pair the shipped derivation
  # can never produce — and the real case (REVIEW_GATE=<a name the rail repo already requires>)
  # makes `merge_authority` answer `gate` from that SAME overridden name. So `_own_auth` computed
  # from $REVIEW_GATE equalled MERGE_AUTHORITY BY CONSTRUCTION and the detector could never fire
  # while agent-infra issued a raw `gh pr merge`. Here REVIEW_GATE is the real alternate name and
  # the authority is DERIVED, so an inert detector fails this test.
  _o3="$(REVIEW_GATE_SOURCE=env; REVIEW_GATE=pipeline-compliance; OR=daniel-ospina/agent-infra; LOG="$TMP/ovr3.log"; : > "$LOG"; REQ_SOURCE=protection; REQ="pipeline-compliance"; \
    MERGE_AUTHORITY="$(merge_authority "$REQ")"; required_checks() { printf '%s\n' 'pipeline-compliance'; }; \
    # shellcheck disable=SC1090
    . "$TMP/ovr.sh" >/dev/null 2>&1; cat "$LOG")"
  case "$_o3" in
    *"CHANGES the merge authority"*) echo "  ✅ a REVIEW_GATE override that flips a rail repo to GATE authority IS detected (the detector is not inert)"; PASS=$((PASS+1)) ;;
    *) echo "  ❌ a REVIEW_GATE override flipped agent-infra rail->gate SILENTLY (log=[$_o3]) — the raw merge this branch forbids"; FAIL=$((FAIL+1)) ;;
  esac
  case "$_o3" in
    *"RAW gh pr merge"*) echo "  ✅ …and the warning names the consequence (a raw merge, not merely a different label)"; PASS=$((PASS+1)) ;;
    *) echo "  ❌ the authority-change warning does not name the consequence — log=[$_o3]"; FAIL=$((FAIL+1)) ;;
  esac
  # ⚠️ review round 7, P2: an override active while the read FAILS must NOT warn — the baseline is
  # `unknown`, which is not a disagreement. Dropping that clause emitted a false "CHANGES the merge
  # authority ('unknown' -> 'rail')" line, and the README tells operators to treat that line as an
  # error, so a false one costs real attention.
  _o4="$(REVIEW_GATE_SOURCE=env; OR=daniel-ospina/agent-infra; LOG="$TMP/ovr4.log"; : > "$LOG"; REQ_SOURCE=protection; REQ='pipeline-compliance'; \
    MERGE_AUTHORITY='rail'; required_checks() { return 1; }; \
    # shellcheck disable=SC1090
    . "$TMP/ovr.sh" >/dev/null 2>&1; cat "$LOG")"
  case "$_o4" in
    *"CHANGES the merge authority"*) echo "  ❌ an UNREADABLE baseline drew a false authority-change warning — log=[$_o4]"; FAIL=$((FAIL+1)) ;;
    *) echo "  ✅ an unreadable baseline (unknown) draws NO change warning — only a real disagreement does"; PASS=$((PASS+1)) ;;
  esac
  # (t) a MALFORMED override is discarded, loudly, and never travels the contract (review round 5).
  # The screen lived only in required_checks, so an override skipped it: `REQ='ci,lint'` reached the
  # classifier as a comma-joined RED set, split there, and a red required check matched no worker at
  # all — silently. Discarding (rather than merely refusing) is what keeps the authority-unknown
  # refusal armed, since that refusal keys on REQ_OVERRIDE being EMPTY.
  _og="$TMP/ovr-gh"; printf '#!/bin/bash\ncase "$*" in *required_status_checks*) printf "pipeline-compliance\\n" ;; *) exit 1 ;; esac\n' > "$_og"; chmod +x "$_og"
  REQ_OVERRIDE='ci,lint'; REQ=''; REQ_SOURCE=''
  # ⛔ called DIRECTLY, never in `$( )`: a command substitution runs the resolver in a subshell and
  # REQ/REQ_SOURCE cannot survive it — the exact trap this branch exists to close (and the trap this
  # assertion fell into the first time it was written).
  resolve_required_checks daniel-ospina/agent-infra "$_og" 2>"$TMP/ov.err"
  _ov_req="$REQ"; _ov_src="${REQ_SOURCE:-}"; _ov_kept="${REQ_OVERRIDE:-}"
  if [ "$_ov_req" = "pipeline-compliance" ] && [ "$_ov_src" = "protection" ] && [ -z "$_ov_kept" ] \
     && grep -q 'contains a comma' "$TMP/ov.err" 2>/dev/null; then
    echo "  ✅ a comma-bearing REQ override is discarded loudly and the repo's own declaration is used"; PASS=$((PASS+1))
  else
    echo "  ❌ a malformed override leaked through: REQ=[$_ov_req] source=[$_ov_src] override-left=[$_ov_kept] err=[$(cat "$TMP/ov.err" 2>/dev/null)]"; FAIL=$((FAIL+1))
  fi
  REQ_OVERRIDE='ci,lint'; REQ=''; REQ_SOURCE=''
  resolve_required_checks daniel-ospina/agent-infra /nonexistent-gh 2>/dev/null
  [ "${REQ_SOURCE:-}" = "fallback" ] && [ -z "${REQ_OVERRIDE:-}" ] \
    && { echo "  ✅ …and with the read ALSO failing it lands on the fallback with the override EMPTY (so every caller still REFUSES) — not on a non-empty override that would defeat the refusal"; PASS=$((PASS+1)); } \
    || { echo "  ❌ a discarded override still defeated the refusal: source=[${REQ_SOURCE:-?}] override-left=[${REQ_OVERRIDE:-}] REQ=[$REQ]"; FAIL=$((FAIL+1)); }
  REQ_OVERRIDE=''
else
  echo "  ❌ could not extract the override-authority warning from orch-loop.sh"; FAIL=$((FAIL+1))
fi

# (o) a PRESENT but STALE repo-authority.sh is a FATAL, not a silent rail (review round 3: it
# sourced cleanly, yielded REQ="", read as `rail`, and rerouted a gate repo). Extract the
# shipped source block and drive it with a stub $O whose repo-authority.sh lacks the resolver.
sed -n '/^_HERE_RA=/,/^  || { echo "orch-loop: FATAL repo-authority.sh at/p' "$ORCH" > "$TMP/srcblock.sh"
if [ -s "$TMP/srcblock.sh" ] && bash -n "$TMP/srcblock.sh" 2>/dev/null; then
  mkdir -p "$TMP/staleO"; printf '#!/usr/bin/env bash\nFALLBACK_REQ="stale"\n' > "$TMP/staleO/repo-authority.sh"
  # unset first: this suite defines the resolver functions at the top, and they would leak into
  # the subshell and make `command -v` pass — the exact false green the presence check exists for.
  ( unset -f resolve_required_checks merge_authority required_checks 2>/dev/null
    O="$TMP/staleO" REQ='ai-review-gate'; . "$TMP/srcblock.sh" ) >/dev/null 2>&1; _st_rc=$?
  [ "$_st_rc" = "78" ] && { echo "  ✅ a stale repo-authority.sh (resolver absent) is FATAL exit 78 — never a silent rail"; PASS=$((PASS+1)); } \
    || { echo "  ❌ stale repo-authority.sh exited $_st_rc, not 78 — an empty contract can still read as rail"; FAIL=$((FAIL+1)); }
  # …and the good copy sources clean (the same block with the real $O).
  _GD="$(cd "$(dirname "$ORCH")" && pwd)"
  ( unset -f resolve_required_checks merge_authority required_checks 2>/dev/null
    O="$_GD" REQ='ai-review-gate'; . "$TMP/srcblock.sh" ) >/dev/null 2>&1; _gd_rc=$?
  [ "$_gd_rc" = "0" ] && { echo "  ✅ the shipped repo-authority.sh passes the same presence check"; PASS=$((PASS+1)); } \
    || { echo "  ❌ the presence check rejects the SHIPPED repo-authority.sh (rc=$_gd_rc)"; FAIL=$((FAIL+1)); }
else
  echo "  ❌ could not extract the repo-authority source block from orch-loop.sh"; FAIL=$((FAIL+1))
fi

echo
echo "================ RESULT: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
