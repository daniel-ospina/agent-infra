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
# ⛔ THE PRODUCER FOLLOWS THE CONSUMER (review round 1, P3 — agent-infra#2132). ORCH is overridable to
# point this suite at the DEPLOYED tree (the drift-guard mode this file's header documents), but
# MERGE was hard-wired to the shipped copy — so in exactly that mode the #2132 section graded a
# DEPLOYED consumer against a SHIPPED producer, and a deployed merge-one.sh still writing the fixer
# marker unconditionally was undetectable. Both now resolve against the same tree; when ORCH is not
# overridden this is the shipped merge-one.sh beside this test, as before.
MERGE="${MERGE:-$(dirname "$ORCH")/merge-one.sh}"
# ⛔ …AND SO DOES THE REPORTER (review round 2, P3). The driven `report.sh` assertions were pinned to
# the SHIPPED copy while the producer followed ORCH, so in drift mode a deployed report.sh still
# printing a raw file count was undetectable — the same defect one script over.
REPORT="${REPORT:-$(dirname "$ORCH")/report.sh}"
PASS=0; FAIL=0

# --- extract the rule functions from the live controller ---
ex() { sed -n "/^$1()/,/^}/p" "$ORCH"; }
MP="$(ex mp_reason)"
if [ "$(printf '%s' "$MP" | wc -l | tr -d ' ')" -lt 3 ]; then
  echo "❌ could not extract mp_reason from $ORCH — the rule moved or was reformatted"; exit 1
fi
# ⛔ mp_reason is no longer arithmetic-only: it validates its inputs with is_num(), the shipped
# one-liner. Extract THAT from the same file (never re-implement it here, or the suite would grade
# its own copy) and fail loudly if it moved — an undefined is_num makes every gate test read "no
# gate", i.e. a suite that passes by testing nothing.
IS_NUM_FN="$(grep -E '^is_num\(\) \{' "$ORCH")"
[ -n "$IS_NUM_FN" ] || { echo "❌ could not extract is_num() from $ORCH — mp_reason's input validation moved"; exit 1; }
eval "$IS_NUM_FN"
eval "$MP"
# ⛔ mp_reason's fail-closed arm calls is_num(), which the controller defines 30 lines above it. The
# extraction must bring the dependency along or the arm dies with "command not found" — and a command
# that never runs returns non-zero, which the gate would read as "capacity available" (fail OPEN).
_ISNUM="$(grep -E '^is_num\(\) \{' "$ORCH")"
[ -n "$_ISNUM" ] || { echo "❌ could not extract is_num() from $ORCH — mp_reason's guard cannot run"; exit 1; }
eval "$_ISNUM"
echo "extracted $(printf '%s' "$MP" | wc -l | tr -d ' ') lines of mp_reason from the live script"

MERGE_PRIORITY_AT=10
MERGE_PRIORITY_MAX_AGE_MIN=180
# A fixed clock and two land records, so the bound is exercised deterministically: the gate now needs
# EVIDENCE that a drain is happening (a land inside the window) and YOUTH (an unowned PR inside it).
MP_NOW=1800000000
MP_LAND_RECENT=$(( MP_NOW - 300 ))          # a PR landed 5 minutes ago
MP_LAND_STALE=$(( MP_NOW - 4 * 3600 ))      # the last land was 4 hours ago
ck() { # ck <label> <unowned> <lanes> <workers> <expect: gate|open> [age] [land] [open] [blocked_since]
  # `-` (not `:-`): an EXPLICIT empty argument is a CASE (an unreadable land record / age), and
  # `:-` would silently substitute the healthy default — making the release cases below unprovable.
  local got age="${6-5}" land="${7-$MP_LAND_RECENT}" open="${8-$2}" since="${9-}"
  got="$(mp_reason "$2" "$3" "$4" "$age" "$land" "$open" "acme/widget" "$MP_NOW" "$since")"
  if [ "$5" = "gate" ] && [ -n "$got" ]; then echo "  ✅ $1  (gated)"; PASS=$((PASS+1))
  elif [ "$5" = "open" ] && [ -z "$got" ]; then echo "  ✅ $1  (dispatch allowed)"; PASS=$((PASS+1))
  else echo "  ❌ $1 — expected $5, got [${got:-<empty>}] for (prs=$2 lanes=$3 workers=$4 age=${6-5} land=${land:-<none>})"; FAIL=$((FAIL+1)); fi
}

echo
echo "=== THE RULE (owner, 2026-10-18): while ANY un-owned PR remains, issues are not opened ==="
# ⛔ NO THRESHOLD. The first argument is the WORKABLE un-owned count (un-owned PRs the harness has
# not already parked as needs-a-human). One is enough to block new work: that is the owner's rule,
# and it is the whole difference between a fleet that is BUSY and a fleet that is DRAINING.
ck "1 un-owned PR, nothing else running -> DRAIN (one is enough)"   1 0 0 gate
ck "3 un-owned PRs, 2 lanes + 5 workers   -> DRAIN"                 3 2 5 gate
ck "25 un-owned PRs, 0 workers (measured)  -> DRAIN"               25 0 0 gate
ck "56 un-owned PRs, 8 reviewers          -> DRAIN"                56 0 8 gate
ck "0 un-owned PRs, anything at all       -> issues may open"       0 2 5 open
ck "an UNREADABLE count (non-numeric)     -> DRAIN, never open"   abc 0 0 gate

echo
echo "=== regression proof: the OLD threshold form let the MEASURED queue through ==="
# The measured state this change exists for: 25 open PRs, 0 owned by a live process. The old rule was
# `unowned > MERGE_PRIORITY_AT` with MERGE_PRIORITY_AT=25, so 25 un-owned PRs read as "not a backlog"
# and the box opened MORE work from issues. This pins that the old form FAILED and the shipped form
# does not — a revert to a threshold turns the second assertion red.
MERGE_PRIORITY_AT=25
mp_reason_threshold() { if [ "${1:-0}" -gt "$MERGE_PRIORITY_AT" ] && [ $(( ${2:-0} + ${3:-0} )) -ge 1 ]; then echo gated; fi; }
old="$(mp_reason_threshold 25 0 0)"
[ -z "$old" ] && { echo "  ✅ (fixture) the OLD threshold form returns EMPTY for the measured state (25 un-owned, nothing running)"; PASS=$((PASS+1)); } \
  || { echo "  ❌ (fixture) the old form already gated 25 — this case no longer proves anything"; FAIL=$((FAIL+1)); }
new="$(mp_reason 25 0 0)"
[ -n "$new" ] && { echo "  ✅ the SHIPPED form gates it: $new"; PASS=$((PASS+1)); } \
  || { echo "  ❌ the shipped form still lets the measured queue through — a threshold is back"; FAIL=$((FAIL+1)); }

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
# is pinned to the shipped line, and the normaliser's decode source is pinned separately, so a change
# to EITHER side turns a pin red — the rule pin for the classifier, the encoding pin for the
# normaliser. (Round-11 review, P3: the original claim was that a change to either side would turn
# one of the _agree assertions red, which was false — on a UTF-8 host both readers coincide, and
# reverting the normaliser to a hard-coded "utf-8" left the suite green.)
_CLS_RULE="want=(os.environ.get('REQ') or '').split()"
# Capture, then classify in the SHELL — never `… | grep -qF`: the quiet grep exits at
# its FIRST match, the upstream `grep -vE` takes SIGPIPE (141), and under `pipefail`
# a FAILING drift guard reads as a pass (#864's class; the producer here writes the
# whole non-comment stream, so it is a live window, not a shape flag).
_ORCH_RULE_HITS="$(grep -vE '^[[:space:]]*#' "$ORCH" 2>/dev/null || true)"
case "$_ORCH_RULE_HITS" in
  *"$_CLS_RULE"*) { echo "  ✅ the classifier still splits with Python .split() — the rule _normalise_set shares"; PASS=$((PASS+1)); } ;;
  *) { echo "  ❌ the classifier's split rule changed in orch-loop.sh; _normalise_set shares it and must change with it (the two MUST agree) "; FAIL=$((FAIL+1)); } ;;
esac
_agree() { # _agree <set> -> both readers' verdicts on the SAME string
  printf 'authority=%s classifier=%s' "$(merge_authority "${1:-}")" \
    "$(REQ="${1:-}" python3 -c 'import os;print("required" if "ai-review-gate" in (os.environ.get("REQ") or "").split() else "not-required")')"
}
eqv "\\x1c: both readers agree the gate IS required (Python whitespace, not POSIX)" "authority=gate classifier=required" "$(_agree "$(printf 'ai-review-gate\034docs')")"
eqv "\\x1d: both readers agree the gate IS required" "authority=gate classifier=required" "$(_agree "$(printf 'ai-review-gate\035docs')")"
eqv "NBSP: both readers agree the gate IS required (the case no \`tr\` set can express)" "authority=gate classifier=required" "$(_agree "$(printf 'ai-review-gate\302\240docs')")"
eqv "a set WITHOUT the gate: both readers agree it is NOT required (the other direction)" "authority=rail classifier=not-required" "$(_agree 'pipeline-compliance docs')"
# ⛔ round-12 review, P2: `merge_authority` matched $REVIEW_GATE as a SUBSTRING SPAN of the
# space-joined set while the classifier tests it as ONE TOKEN, so a gate NAME CONTAINING A SPACE
# made the authority `gate` (the GREEN arm's RAW merge) while the classifier never enforced it — an
# UNREVIEWED change merges. Measured at ed5ba51e: REVIEW_GATE='docs license-surface' over the set
# 'pipeline-compliance docs license-surface' answered `gate`, and the classifier said NOT enforced.
eqv "a WHITESPACE-bearing REVIEW_GATE refuses — it could raw-merge while never being enforced" "unknown" \
  "$( REVIEW_GATE='docs license-surface'; merge_authority 'pipeline-compliance docs license-surface' )"
eqv "a whitespace-only REVIEW_GATE refuses too" "unknown" \
  "$( REVIEW_GATE=' '; merge_authority 'pipeline-compliance docs' )"
eqv "…and a normal single-token REVIEW_GATE is unaffected (no over-refusal)" "gate" \
  "$( REVIEW_GATE='ai-review-gate'; merge_authority 'pipeline-compliance ai-review-gate' )"
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
# The extraction starts at record_at_head() (#1825): rail mode now asks whether this head already
# carries a head-bound review record BEFORE it may run the rail, so that helper — and rail_attempt,
# which took over the retry/park/invoke block — are part of the driven region. Starting at the
# `if [ "$MERGE_AUTHORITY" = "rail" ]` line would leave both undefined, every drive would fall
# through the evidence test with a `command not found`, and the rail would never be invoked.
{ grep -m1 '^is_num() {' "$MERGE"; grep -m1 '^is_limit() {' "$MERGE"
  awk '/^record_at_head\(\) \{/{f=1} f&&/^# ── 1\) fresh-context review/{f=0} f' "$MERGE"; } > "$TMP/railbranch.sh"
# #1825 — the merge-store fixture. Rail mode only HANDS OFF to the rail when the head already
# carries a head-bound record; otherwise it mints the evidence first. So every drive that expects
# a rail INVOCATION must present one — seeded in a throwaway HOME, never in the real store — and a
# drive that expects NO invocation must present none. `seed_record <home> <pr> <head>` writes the
# repo-qualified record exactly as record-review.sh names it.
seed_record() {
  mkdir -p "$1/.pi/agent/reviews"
  printf '{"pr":%s,"head_sha":"%s","verdict":"clean","repo":"daniel-ospina/agent-infra","reviewed_at":"2026-10-17T00:00:00Z"}\n' \
    "$2" "$3" > "$1/.pi/agent/reviews/daniel-ospina-agent-infra-$2.json"
}
# ONE record per PR fits the store (the filename is repo-qualified), so each drive that expects
# evidence seeds the head IT is about — immediately above the drive, so a drive cannot silently
# run against another drive's head.
SEED_HOME="$TMP/seedhome"; mkdir -p "$SEED_HOME"
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
seed_record "$SEED_HOME" 1764 bbbb2222
printf '%s %s\n' bbbb2222 3 > "$TMP/railO/state/railcount-1764"
printf '%s\n' aaaa1111  > "$TMP/railO/state/parked-1764"                  # a STALE park, older head
( HOME="$SEED_HOME"; MERGE_AUTHORITY=rail; REPO="$TMP/railrepo"; PR=1764; OR=daniel-ospina/agent-infra; \
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
seed_record "$SEED_HOME" 1764 cccc3333
: > "$TMP/railO/gh-spy.txt"
( HOME="$SEED_HOME"; PATH="$TMP/ghspy:$PATH"; export GH_SPY="$TMP/railO/gh-spy.txt"; MERGE_AUTHORITY=rail; REPO="$TMP/railrepo"; PR=1764; OR=daniel-ospina/agent-infra; \
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
seed_record "$SEED_HOME" 1764 dddd4444
printf '#!/bin/bash\nexit 1\n' > "$TMP/railrepo/scripts/admin-merge.sh"; chmod +x "$TMP/railrepo/scripts/admin-merge.sh"
( HOME="$SEED_HOME"; MERGE_AUTHORITY=rail; REPO="$TMP/railrepo"; PR=1764; OR=daniel-ospina/agent-infra; \
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

# (g3-1825) RAIL MODE WITHOUT EVIDENCE MUST NOT MERGE — the #1825 companion, BEHAVIOURAL.
# `pipeline-compliance` check (c) — this repo's ONLY required check — accepts nothing but a
# head-bound review record, so a rail-mode merge of a head with no record leaves the required
# check unsatisfiable forever: "the binding must land together with re-enabling evidence minting
# in rail mode, or pipeline-compliance becomes unsatisfiable on this repo" (issue #1825, owner
# comment). The drive presents a rail that SUCCEEDS and a store with NO record at this head: the
# worker must NOT invoke the rail. It falls through to the review path, where the missing recorder
# parks the head (exit 3) instead of paying for a review whose record step cannot sign.
cat > "$TMP/railrepo/scripts/admin-merge.sh" <<RAILSTUB
#!/bin/bash
printf '%s\n' "\$PWD" "\$*" > "$TMP/railO/rail-argv.txt"
exit 0
RAILSTUB
chmod +x "$TMP/railrepo/scripts/admin-merge.sh"
rm -f "$TMP/railO/rail-argv.txt" "$TMP/railO/state/merged-1764.done" "$TMP/railO/state/railcount-1764" \
      "$TMP/railO/state/parked-1764" "$TMP/railO/state/parkreason-1764"
NOEV_HOME="$TMP/noevhome"; mkdir -p "$NOEV_HOME"
( HOME="$NOEV_HOME"; MERGE_AUTHORITY=rail; REPO="$TMP/railrepo"; PR=1764; OR=daniel-ospina/agent-infra; \
  L="$TMP/railO/merge.log"; O="$TMP/railO"; HEAD=1111eeee; \
  . "$TMP/railbranch.sh" ) >/dev/null 2>&1; noevrc=$?
if [ "$noevrc" = "3" ] && [ ! -f "$TMP/railO/rail-argv.txt" ] && [ ! -f "$TMP/railO/state/merged-1764.done" ]; then
  echo "  ✅ #1825: rail mode with NO head-bound record does NOT run the rail — it falls through to mint the evidence (parks at the missing recorder, exit 3)"
  PASS=$((PASS+1))
else
  echo "  ❌ #1825: rail mode ran the rail (or merged) with NO head-bound record — rc=$noevrc rail-invoked=$([ -f "$TMP/railO/rail-argv.txt" ] && echo yes || echo no) merged=$([ -f "$TMP/railO/state/merged-1764.done" ] && echo yes || echo no). check (c) would be unsatisfiable on this repo and the merge would land unreviewed."
  FAIL=$((FAIL+1))
fi
# ...and the CONTROL for it: the SAME drive with a record at the head DOES invoke the rail. Without
# this pair a `record_at_head` that always returned 1 would satisfy the assertion above while
# breaking rail mode entirely (no agent-infra PR could ever drain — the #1764 deadlock).
rm -f "$TMP/railO/rail-argv.txt" "$TMP/railO/state/merged-1764.done" "$TMP/railO/state/railcount-1764"
seed_record "$SEED_HOME" 1764 bbbb2222
( HOME="$SEED_HOME"; MERGE_AUTHORITY=rail; REPO="$TMP/railrepo"; PR=1764; OR=daniel-ospina/agent-infra; \
  L="$TMP/railO/merge.log"; O="$TMP/railO"; HEAD=bbbb2222; \
  . "$TMP/railbranch.sh" ) >/dev/null 2>&1; evrc=$?
[ "$evrc" = "0" ] && [ -f "$TMP/railO/rail-argv.txt" ] && [ -f "$TMP/railO/state/merged-1764.done" ] \
  && { echo "  ✅ #1825 control: with a head-bound record present, rail mode DOES run the rail (the fast path is intact)"; PASS=$((PASS+1)); } \
  || { echo "  ❌ #1825 control: rail mode did not run the rail WITH a record at the head (rc=$evrc) — the evidence test is inert and no rail PR could drain"; FAIL=$((FAIL+1)); }

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
seed_record "$SEED_HOME" 1764 eeee5555
printf '%s %s\n' aaaa1111 3 > "$TMP/railO/state/railcount-1764"    # an OLDER head, already AT the cap
printf '%s\n' aaaa1111 > "$TMP/railO/state/parked-1764"
( HOME="$SEED_HOME"; MERGE_AUTHORITY=rail; REPO="$TMP/railrepo"; PR=1764; OR=daniel-ospina/agent-infra; \
  L="$TMP/railO/merge.log"; O="$TMP/railO"; HEAD=eeee5555; \
  . "$TMP/railbranch.sh" ) >/dev/null 2>&1; nhrc=$?
[ "$nhrc" = "0" ] && [ -f "$TMP/railO/state/merged-1764.done" ] \
  && { echo "  ✅ a NEW head RE-ARMS the head-keyed budget (a stale count cannot park a head the rail never saw)"; PASS=$((PASS+1)); } \
  || { echo "  ❌ a new head hit the OLD head's cap (rc=$nhrc, merged=$([ -f "$TMP/railO/state/merged-1764.done" ] && echo yes || echo no), parked=[$(cat "$TMP/railO/state/parked-1764" 2>/dev/null)]) — the rail never ran"; FAIL=$((FAIL+1)); }

# (g4) the COERCIONS are load-bearing (review round 7, P2). A typo'd RAIL_TRIES must not disable the
# cap: `[ 3 -ge 99999999999999999999 ]` errors FALSE on bash 3.2 (the shipped /bin/bash), so
# without the coercion the park never lands and the rail is re-run every cycle — the API burn the
# cap exists to close.
seed_record "$SEED_HOME" 1764 aaaa1111
printf '%s %s\n' aaaa1111 3 > "$TMP/railO/state/railcount-1764"
printf '%s\n' zzzz9999 > "$TMP/railO/state/parked-1764"
( HOME="$SEED_HOME"; MERGE_AUTHORITY=rail; REPO="$TMP/railrepo"; PR=1764; OR=daniel-ospina/agent-infra; RAIL_TRIES=99999999999999999999; \
  L="$TMP/railO/merge.log"; O="$TMP/railO"; HEAD=aaaa1111; \
  . "$TMP/railbranch.sh" ) >/dev/null 2>&1
[ "$(cat "$TMP/railO/state/parked-1764" 2>/dev/null)" = "aaaa1111" ] \
  && { echo "  ✅ a 20-digit RAIL_TRIES is coerced back into range (the cap still trips — bash 3.2 errors that compare FALSE)"; PASS=$((PASS+1)); } \
  || { echo "  ❌ a 20-digit RAIL_TRIES disabled the cap: parked=[$(cat "$TMP/railO/state/parked-1764" 2>/dev/null)] (want aaaa1111) — the rail is re-run every cycle"; FAIL=$((FAIL+1)); }
# …and a CORRUPT count is re-sanitised rather than propagated into the arithmetic.
printf '%s %s\n' aaaa1111 99999999999999999999 > "$TMP/railO/state/railcount-1764"
rm -f "$TMP/railO/state/parked-1764"
( HOME="$SEED_HOME"; MERGE_AUTHORITY=rail; REPO="$TMP/railrepo"; PR=1764; OR=daniel-ospina/agent-infra; \
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
  # ⛔ round-10 review, P2 (and round-11 P2): the arm's final `else` issued a RAW merge for ANY
  # authority that was not `rail` — INCLUDING `unknown`. Drive the shipped arm with an UNKNOWN
  # authority; it must merge nothing. ⚠️ This lives INSIDE this `if` on purpose: outside it,
  # `drive_green` and `$_REQ7` are undefined, so an extraction failure aborted the WHOLE suite
  # under `set -u` (measured: rc 1, no RESULT line, ~40 later assertions never ran) instead of
  # failing this one check.
  drive_green unknown "$_REQ7"
  if ! grep -q -- '--squash' "$TMP/g.spy"; then
    echo "  ✅ GREEN+unknown: NO raw merge is issued (an authority that names neither gate nor rail merges nothing)"; PASS=$((PASS+1))
  else
    echo "  ❌ GREEN+unknown: a RAW merge was issued for an unknown authority — spy=[$(tr '\n' ';' < "$TMP/g.spy")]"; FAIL=$((FAIL+1))
  fi
  grep -q 'merge authority is' "$TMP/g.log" \
    && { echo "  ✅ GREEN+unknown: the refusal is LOGGED, naming the authority (a silent no-op is indistinguishable from a hang)"; PASS=$((PASS+1)); } \
    || { echo "  ❌ GREEN+unknown: no refusal log line — the arm refuses silently"; FAIL=$((FAIL+1)); }
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
# ⛔ ANY spelling of `printf %q` on a non-comment line, with LINE CONTINUATIONS JOINED FIRST.
# The round-10 form (`printf.*%q`, line-local) missed a continuation — `printf \` + newline +
# `'%q'` scored 0 (round-11 review, P3). Full-line comments are stripped because this file
# DOCUMENTS the rule in prose.
# ⚠️ CORRECTED (round-11 review, P3): the earlier note claimed the round-9 pattern
# `printf[[:space:]]+.?%q` also missed `printf "%q"`. It did NOT — the `.` matched the double
# quote. It missed only `-- '%q'` and `'REQ=%q'`. The claim was overstated and is restated here.
_QPCT="$(grep -vE '^[[:space:]]*#' "$ORCH" | awk '{ if (sub(/\\$/, "")) printf "%s", $0; else print }' | grep -cE 'printf.*%q')"
[ "${_QPCT:-0}" = "0" ] \
  && { echo "  ✅ no \`printf %q\` site remains in orch-loop.sh (any spelling; its \`\$'…'\` output is not POSIX quoting)"; PASS=$((PASS+1)); } \
  || { echo "  ❌ ${_QPCT} \`printf %q\` site(s) remain in orch-loop.sh — dash re-parses that value as commands"; FAIL=$((FAIL+1)); }

# (i) AUTHORITY_UNKNOWN is REAL (review P2, round 2 — it had zero coverage and could be deleted
# without a red). Two halves: the guard's EXPRESSION does continue when set, and it sits BEFORE
# the classifier (a guard moved after the arms guards nothing).
# ⛔ round-11 review, P3: the AUTHORITY_UNKNOWN derivation is driven BEHAVIOURALLY at (p) below,
# which extracts and runs the shipped fragment. A text pin here was redundant and could be satisfied
# by a comment, so it was removed rather than kept as a weaker twin of the drive.
_au_expr='[ "${AUTHORITY_UNKNOWN:-0}" = "1" ] && continue'
# ⛔ round-11 review, P3: `_agree` below runs on a UTF-8 host, where THIS commit's encoding defect
# is INVISIBLE — reverting the normaliser to a hard-coded "utf-8" left the suite green.
# ⛔ round-12 review, P3: a TOKEN-presence grep was STILL dodgeable (`enc = "utf-8" or
# sys.getfilesystemencoding()` keeps the token and stayed green), and it pinned the decode only.
# The pin is now the exact ASSIGNMENT (a shadowing literal cannot survive it) plus BOTH call sites
# reading the variables, and it REJECTS a literal passed to decode.
_RA_CODE="$(grep -vE '^[[:space:]]*#' "$RA")"
_enc_ok=1
grep -qF 'enc = sys.getfilesystemencoding() or "utf-8"' <<<"$_RA_CODE" || _enc_ok=0
grep -qF 'err = sys.getfilesystemencodeerrors() or "surrogateescape"' <<<"$_RA_CODE" || _enc_ok=0
grep -qF 'decode(enc, err)' <<<"$_RA_CODE" || _enc_ok=0
grep -qF 'encode(enc, err)' <<<"$_RA_CODE" || _enc_ok=0
if grep -qE 'decode\("utf-8"' <<<"$_RA_CODE"; then _enc_ok=0; fi
[ "$_enc_ok" = 1 ] \
  && { echo "  ✅ _normalise_set decodes AND encodes with the FILESYSTEM codec (the exact assignment, no shadowing literal) — the same source os.environ uses"; PASS=$((PASS+1)); } \
  || { echo "  ❌ _normalise_set no longer decodes/encodes with sys.getfilesystemencoding()/encodeerrors() — under a single-byte locale the classifier and the authority can disagree again (the §5.1 bypass) "; FAIL=$((FAIL+1)); }
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
sed -n '/^if \[ -z "${REQ:-}" \]/,/^fi$/p' "$MERGE" > "$TMP/worker-guard.sh"
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
  # ⛔ round-11 review, P2: the guard was a DENY list, so an authority that was neither `rail` nor
  # `unknown` fell through to the review path and its raw merge. Drive an UNRECOGNISED authority
  # (non-empty REQ, protection read, valid override — so ONLY the authority can refuse it).
  for _ba in garbage "" "rail "; do
    ( REQ_SOURCE=protection; REQ_OVERRIDE='pipeline-compliance'; REQ='pipeline-compliance'; MERGE_AUTHORITY="$_ba"; PR=1766; OR=daniel-ospina/agent-infra; \
      L="$TMP/wg4"; O="$TMP"; . "$TMP/worker-guard.sh" ) >/dev/null 2>&1; wg4rc=$?
    [ "$wg4rc" = "5" ] && { echo "  ✅ a worker with an UNRECOGNISED authority ('$_ba') refuses (exit 5) instead of falling into the review path's raw merge"; PASS=$((PASS+1)); } \
      || { echo "  ❌ an unrecognised authority ('$_ba') exited $wg4rc, not 5 — it fell through to a raw merge"; FAIL=$((FAIL+1)); }
  done
  # ⚠️ review round 3: §j sourced the fragment standalone, so the guard's POSITION was unpinned
  # — moved after run_agent it would refuse only AFTER the reviewer ran and was paid for.
  _wg_ln="$(grep -n 'REFUSED: the merge contract is UNKNOWN' "$MERGE" | head -1 | cut -d: -f1)"
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
# agent-infra#1730 moved each of these park writes into orch-loop.sh's park_ctrl helper (marker and
# reason in ONE write, so a reason can never outlive the head it describes). The 4-line window is
# therefore no longer self-contained: it calls park_ctrl, which is defined ~500 lines higher up. The
# extractor must carry the SHIPPED helper, and refuse LOUDLY when it cannot — a helper that failed to
# extract would leave the park unrefreshed and look like the defect this check exists to catch.
_drive_park() { # <anchor-regex> <label>
  awk '/^park_ctrl\(\)/ { f=1 } f { print; if ($0 == "}") exit }' "$ORCH" > "$TMP/parkblk.sh"
  awk -v anc="$1" 'index($0, anc) > 0 { print prev; print; if ((getline c) > 0) print c; if ((getline d) > 0) print d; exit } { prev=$0 }' "$ORCH" >> "$TMP/parkblk.sh"
  if [ -s "$TMP/parkblk.sh" ] && grep -q '^park_ctrl()' "$TMP/parkblk.sh" && bash -n "$TMP/parkblk.sh" 2>/dev/null; then
    mkdir -p "$TMP/pkO/state"; printf '%s\n' aaaa1111 > "$TMP/pkO/state/parked-2317"
    ( PR=2317; HEAD_N=bbbb2222; NFC=3; NFC2=3; V='FAILED:docs'; LOG="$TMP/pkO/park.log"; O="$TMP/pkO"; MAX_FIX_TRIES=3
      # MAX_FIX_TRIES is not a free variable here: orch-loop.sh sets it at the top of the script
      # (`MAX_FIX_TRIES="${MAX_FIX_TRIES:-3}"`), and #1730's park reason quotes it. The block is
      # extracted in isolation, so the harness supplies the same default production has — without
      # it the reason is an unbound variable under `set -u` and the park write never runs.
      # shellcheck disable=SC1090
      . "$TMP/parkblk.sh" ) >/dev/null 2>&1
    _pk="$(cat "$TMP/pkO/state/parked-2317" 2>/dev/null)"
    [ "$_pk" = "bbbb2222" ] && { echo "  ✅ $2: the park is REFRESHED to the new head (a stale older-head park cannot block it)"; PASS=$((PASS+1)); } \
      || { echo "  ❌ $2: parked=[$_pk] (expected bbbb2222) — the stale-park re-spawn loop is back"; FAIL=$((FAIL+1)); }
  else
    echo "  ❌ $2: could not extract the park block (or orch-loop.sh's park_ctrl helper)"; FAIL=$((FAIL+1))
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
OR=x; LOG=/dev/null; D_REQ="$1"; D_SRC="$2"; D_AUTH="${3:-gate}"
resolve_required_checks() { REQ="$D_REQ"; REQ_SOURCE="$D_SRC"; return 0; }
merge_authority() { printf '%s\n' "${D_AUTH:-gate}"; }
. "$DERIV" >/dev/null 2>&1
printf '%s' "${AUTHORITY_UNKNOWN:-}"
DRV
  _au_derive() { DERIV="$TMP/deriv.sh" bash "$TMP/deriv-drive.sh" "$1" "$2" "${3:-gate}"; }
  # ⛔ round-11 review, P3: D_AUTH was NEVER ASSIGNED, so merge_authority always answered EMPTY and
  # the MERGE_AUTHORITY clause was never exercised — a mutant that kept the clause's text but made
  # it inert stayed green. Drive every authority the shipped merge_authority can return, plus an
  # unrecognised one (which the allow-list polarity added in this commit must treat as unknown).
  for _case in "gate:0" "rail:0" "unknown:1" "garbage:1"; do
    _auth="${_case%%:*}"; _want="${_case##*:}"
    _got="$(_au_derive 'pipeline-compliance' protection "$_auth")"
    [ "$_got" = "$_want" ] && { echo "  ✅ derivation: authority=$_auth -> AUTHORITY_UNKNOWN=$_want"; PASS=$((PASS+1)); } \
      || { echo "  ❌ derivation: authority=$_auth gave AUTHORITY_UNKNOWN=$_got (want $_want) — an unrecognised authority would reach the merge arms"; FAIL=$((FAIL+1)); }
  done
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
echo "=== ownership is a LIVE FACT (owner ruling, 2026-10-18) ==="
# WHY THIS SECTION EXISTS. The gate's input used to be the TOTAL open-PR count, so a queue already
# being worked read as congestion and the box CAPPED ITSELF: measured 2026-10-16, two live cells
# logged `[dispatch] skipped (merge-priority (20 open PRs — draining)) lanes=1 workers=0` at `lanes=1`
# of a configured 32, with 59-86% CPU idle and 13.9 GB RAM free. The count was replaced by the
# UN-OWNED count — and then the OWNERSHIP PREDICATE was itself wrong: it read registry declarations
# (a `fix-<PR>` tmux session, a findings marker, a local claim ref) as "someone is working this".
# MEASURED 2026-10-18: pr-doctor reported 21 "running" lanes, a live-cwd scan found NONE of them
# holding a PR branch, and 25 open PRs sat un-owned while the box opened more. So ownership is now
# what the machine can observe: a RUNNING PROCESS whose cwd is a checkout of the PR's head ref (or a
# worktree whose path carries the PR number), plus — the one thing no local probe can see — a claim
# held by ANOTHER box.
# The functions are EXTRACTED from the live controller and the predicate is the SHIPPED module, so a
# rename/reformat/regression fails here instead of silently skipping.
INST="$HERE/install.sh"
LO="$HERE/live-ownership.sh"
for _fn in fix_slots review_slots pr_owned claim_foreign_live claim_live claim_lease_live unowned_pr_count unowned_scan; do
  ex "$_fn" > "$TMP/$_fn.sh"
done
grep -E '^is_num\(\) \{'    "$ORCH" > "$TMP/is_num.sh"
grep -E '^_this_host\(\) \{' "$ORCH" > "$TMP/this_host.sh"
_own_ok=1
for _fn in fix_slots review_slots pr_owned claim_foreign_live claim_live claim_lease_live unowned_pr_count unowned_scan is_num this_host; do
  [ -s "$TMP/$_fn.sh" ] || { echo "  ❌ could not extract $_fn() from orch-loop.sh — the rule moved or was reformatted"; _own_ok=0; }
done
[ -f "$LO" ] || { echo "  ❌ $LO is missing — the ownership predicate moved"; _own_ok=0; }
cat "$TMP/is_num.sh" "$TMP/this_host.sh" "$TMP/fix_slots.sh" "$TMP/review_slots.sh" \
    "$TMP/pr_owned.sh" "$TMP/claim_foreign_live.sh" "$TMP/claim_live.sh" "$TMP/claim_lease_live.sh" "$TMP/unowned_pr_count.sh" "$TMP/unowned_scan.sh" > "$TMP/ownfunctions.sh"
if [ "$_own_ok" = "1" ] && bash -n "$TMP/ownfunctions.sh" 2>/dev/null; then
  # the SHIPPED predicate, not a re-implementation of it
  # shellcheck source=/dev/null
  . "$LO"
  mkdir -p "$TMP/ownO/state"
  # shellcheck source=/dev/null
  . "$TMP/this_host.sh"
  O="$TMP/ownO"
  LO_SCAN=1
  LO_LIVE="$O/state/live.tsv"
  # Subshell helpers: the shipped functions are sourced, never copied, and `O` points at a fixture
  # state dir so nothing here can touch a real box.
  _own()    { ( . "$TMP/ownfunctions.sh"; unowned_pr_count "$1" ); }
  _owned()  { ( . "$TMP/ownfunctions.sh"; if pr_owned "$1" "${2:-}" "${3:-}"; then printf 'owned'; else printf 'unowned'; fi ); }
  # The live table is the MACHINE's answer: "<branch>\t<worktree>\t<pid>\t<cwd>". A fixture row here
  # stands in for a real process — the suite that proves the PROBE really reads processes is
  # live-ownership.test.sh, which spawns them.
  _live() { printf '%s\n' "$@" > "$LO_LIVE"; }

  # (1) THE LIVE ARM. One row per holding process; the branch is the primary signal.
  _live 'fix/7-thing	/repo/.worktrees/x	1234	/repo/.worktrees/x'
  eqv "a live process in the branch's checkout OWNS its PR" "owned" "$(_owned 7 aaa fix/7-thing)"
  eqv "a live process in ANOTHER branch's checkout does not own it" "unowned" "$(_owned 8 aaa fix/8-other)"
  # the path fallback: a worktree whose PATH carries the PR number, on an unrelated branch
  _live 'chore/no-pr-name	/tmp/aig-wt-9100	4321	/tmp/aig-wt-9100'
  eqv "a live worktree PATH carrying the PR number OWNS it" "owned" "$(_owned 9100 bbb chore/no-pr-name)"
  # ⛔ …without turning every DATE directory into a PR: 2026-10-17 is not PR #2026.
  _live 'feat/other	/repo/docs/2026-10-17	999	/repo/docs/2026-10-17'
  # the queried BRANCH must differ from every live row's branch, or the branch arm answers first and
  # the path rule is never exercised (measured: the first version of this case did exactly that).
  eqv "a DATE component (2026-10-17) is not read as PR #2026" "unowned" "$(_owned 2026 vvv feat/unrelated-x)"
  # (2) ⛔ THE MEASURED BUG SHAPE: the registry SAYS owned, the process is DEAD. These two cases are
  # the whole change — a session name and a marker are records of intent, never of work.
  _live
  touch "$O/state/needsfix-11-deadbeef0000"
  eqv "a worker SESSION NAME alone is NOT ownership (nothing is holding the branch)" "unowned" "$(_owned 11 deadbeef0000 fix/11-thing)"
  rm -f "$O/state/needsfix-11-deadbeef0000"
  # …and a findings marker is not ownership either: it AUTHORISES a spawn, it does not prove one ran.
  touch "$O/state/needsfix-12-deadbeef0001"
  eqv "a findings MARKER alone is NOT ownership (it authorises a spawn, it does not prove one ran)" "unowned" "$(_owned 12 deadbeef0001 fix/12-thing)"
  rm -f "$O/state/needsfix-12-deadbeef0001"
  # …and a local lock whose pid is dead is a stale flag, not a worker.
  printf '999999' > "$O/state/mergeclaim-13.lock"
  eqv "a DEAD local lock pid is NOT ownership (a stale flag must not read as a worker)" "unowned" "$(_owned 13 "" fix/13-thing)"
  rm -f "$O/state/mergeclaim-13.lock"
  # (2b) REVIEW R1, P1: ⛔ A LIVE PID IS NOT A PROCESS WORKING THE PR. merge-one.sh writes nothing but
  # `$$`, so once pids recycle the lock reads LIVE for ever and the PR leaves the un-owned queue
  # permanently — this change's failure mode in the dangerous direction. Three cases pin the binding:
  # an alive-but-unrelated process, a merge worker busy with a DIFFERENT PR, and the real worker.
  ( exec sleep 300 ) & _sleepy=$!
  printf '%s' "$_sleepy" > "$O/state/mergeclaim-14.lock"
  eqv "a LIVE lock pid that is NOT a merge worker is NOT ownership (pid recycling)" "unowned" "$(_owned 14 "" fix/14-thing)"
  cat > "$TMP/fake-merge-one.sh" <<'FAKE'
#!/usr/bin/env bash
# NOT `exec sleep`: the binding reads the COMMAND LINE, so the process image must stay bash running
# this script (an exec would rename it to `sleep 300` and name no PR).
sleep 300
FAKE
  ( exec bash "$TMP/fake-merge-one.sh" 999 ) & _other=$!
  printf '%s' "$_other" > "$O/state/mergeclaim-15.lock"
  eqv "a live merge worker on a DIFFERENT PR is NOT ownership" "unowned" "$(_owned 15 "" fix/15-thing)"
  ( exec bash "$TMP/fake-merge-one.sh" 16 ) & _mine=$!
  printf '%s' "$_mine" > "$O/state/mergeclaim-16.lock"
  eqv "a live merge worker NAMING this PR IS ownership (the arm still works)" "owned" "$(_owned 16 "" fix/16-thing)"
  # ⛔ THE RAIL'S OWN SPAWN FORM (review R2, P2): the controller starts a merge worker as
  # `bash merge-one.sh --argv state/argv-<PR>`, so the PR number appears only inside a FILENAME. Matching
  # just the positional form denied a genuinely live worker for its whole run and inflated the un-owned
  # count the owner audits.
  ( exec bash "$TMP/fake-merge-one.sh" --argv "$O/state/argv-17" ) & _argv=$!
  printf '%s' "$_argv" > "$O/state/mergeclaim-17.lock"
  eqv "the --argv spawn form IS ownership (a real rail worker)" "owned" "$(_owned 17 "" fix/17-thing)"
  ( exec bash "$TMP/fake-merge-one.sh" --argv "$O/state/argv-170" ) & _argv2=$!
  printf '%s' "$_argv2" > "$O/state/mergeclaim-18.lock"
  eqv "…and argv-170 does NOT own PR 18 (no filename prefix collision)" "unowned" "$(_owned 18 "" fix/18-thing)"
  kill "$_sleepy" "$_other" "$_mine" "$_argv" "$_argv2" 2>/dev/null || true
  rm -f "$O/state/mergeclaim-14.lock" "$O/state/mergeclaim-15.lock" "$O/state/mergeclaim-16.lock" \
        "$O/state/mergeclaim-17.lock" "$O/state/mergeclaim-18.lock"
  # ⛔ (R2, P1) THE CROSS-BOX ARM MUST NOT INHERIT THE SPAWN GUARD'S LOOSE LOCK TEST. A stale local
  # lock whose pid had been recycled made even an EXPIRED foreign lease read live — so a PR left the
  # un-owned queue for ever, through arm 3 after arm 2 had been fixed. The lease alone decides.
  ( exec sleep 300 ) & _stale=$!
  printf '%s' "$_stale" > "$O/state/mergeclaim-19.lock"
  printf 'refs/claims/19-fff000000000\totherbox:1\t1\n' > "$O/state/claims-snapshot"
  eqv "a stale local lock + an EXPIRED foreign lease is NOT ownership (the lease alone decides)" \
      "unowned" "$(_owned 19 fff000000000)"
  printf 'refs/claims/19-fff000000000\totherbox:1\t9999999999\n' > "$O/state/claims-snapshot"
  eqv "…while a LIVE foreign lease still owns (the arm is not dead)" "owned" "$(_owned 19 fff000000000)"
  kill "$_stale" 2>/dev/null || true
  rm -f "$O/state/mergeclaim-19.lock"
  # (3) THE CROSS-BOX ARM — the only evidence a remote holder can leave (a lease is DATA, not
  # liveness: claims.sh says so, and a remote pid cannot be probed). Per HEAD, never per PR.
  printf 'refs/claims/12-ddd000000000	otherbox:1	9999999999\n' > "$O/state/claims-snapshot"
  eqv "a claim held by ANOTHER box OWNS its PR (unobservable locally)" "owned" "$(_owned 12 ddd000000000)"
  eqv "a claim on a DIFFERENT head does not own this one (per head, not per PR)" "unowned" "$(_owned 12 eee000000000)"
  printf 'refs/claims/12-ddd000000000	%s:1	9999999999\n' "$(_this_host)" > "$O/state/claims-snapshot"
  eqv "THIS box's own claim does not own a PR — only a live process can" "unowned" "$(_owned 12 ddd000000000)"
  printf 'refs/claims/12-ddd000000000	otherbox:1	1\n' > "$O/state/claims-snapshot"
  eqv "an EXPIRED foreign claim does not own its PR (the lease window is respected)" "unowned" "$(_owned 12 ddd000000000)"
  rm -f "$O/state/claims-snapshot"

  # (4) THE COUNT over a real listing, through the SHIPPED unowned_pr_count. Rows are
  # `number:head:branch` — the branch is in the row because ownership is per-PR and LIVE.
  _live 'fix/3-b	/repo/.worktrees/3	11	/repo/.worktrees/3' \
        'fix/9-b	/repo/.worktrees/9	12	/repo/.worktrees/9'
  printf '3:aaa000000000:fix/3-b 4:bbb000000000:fix/4-b 9:ccc000000000:fix/9-b 11:ddd000000000:fix/11-b 12:eee000000000:fix/12-b\n' > "$O/state/last-open-prs"
  eqv "5 open PRs, 2 held by live processes -> 3 UNOWNED (the gate input)" "3" "$(_own 5)"
  # ⛔ FAIL-CLOSED: no listing at all => EVERY open PR counts as unowned. The other direction
  # (assuming they were owned) would OPEN the issue path on a listing we could not read.
  mv "$O/state/last-open-prs" "$O/state/.parked-list"
  eqv "NO listing => the whole count is unowned (fail CLOSED, never fail open)" "7" "$(_own 7)"
  mv "$O/state/.parked-list" "$O/state/last-open-prs"
  # a legacy two-field row carries no branch, so it can only be owned through the local arms — and
  # with none live it counts as unowned (fail CLOSED, the drain direction).
  printf '3:aaa000000000\n' > "$O/state/last-open-prs"
  eqv "a legacy row with no branch field is not read as owned (the drain direction)" "1" "$(_own 1)"
  # a malformed row is skipped, never counted as owned
  printf '3:aaa000000000:fix/3-b xx:bbb000000000:fix/4-b\n' > "$O/state/last-open-prs"
  eqv "a malformed listing row is skipped, not read as ownership" "1" "$(_own 2)"
  # owned ABOVE the listing (a race between the count and the rows) collapses to 0, never negative
  printf '3:aaa000000000:fix/3-b 4:bbb000000000:fix/4-b\n' > "$O/state/last-open-prs"
  _live 'fix/3-b	/repo/w3	1	/repo/w3' 'fix/4-b	/repo/w4	2	/repo/w4' 'fix/5-b	/repo/w5	3	/repo/w5'
  eqv "an OWNED count above the listing collapses to 0, never negative" "0" "$(_own 1)"
  # (5) a MALFORMED argument must FAIL CLOSED — "fail closed" means EMIT NOTHING, never a number:
  # coercing it to 0 hands the gate the most permissive value there is AND a valid-looking one.
  _mal=0; _out="$(_own abc)" || _mal=1
  { [ "$_mal" = "1" ] && [ -z "$_out" ]; } \
    && { echo "  ✅ a non-numeric count FAILS CLOSED (emits nothing, never 0)"; PASS=$((PASS+1)); } \
    || { echo "  ❌ a non-numeric count produced '$_out' — it must emit NOTHING so the caller falls back to the total"; FAIL=$((FAIL+1)); }
  # `08` is the second malformed form and the one a digit-only guard admits: `$(( 08 - … ))` is an
  # OCTAL parse error, `u` came out empty, the caller substituted its own `08`, and `[ 08 -gt 25 ]`
  # read 8 and OPENED the gate. is_num rejects leading zeros precisely so this cannot happen.
  _mal=0; _out="$(_own 08)" || _mal=1
  { [ "$_mal" = "1" ] && [ -z "$_out" ]; } \
    && { echo "  ✅ a leading-zero count (08) FAILS CLOSED (not read as octal 8)"; PASS=$((PASS+1)); } \
    || { echo "  ❌ a leading-zero count produced '$_out' — 08 must not reach the arithmetic or the gate"; FAIL=$((FAIL+1)); }
  # a live table the probe could not read is UNKNOWN: nothing is owned (the drain direction), never
  # "everything is owned" (which would open the issue path on a failed probe).
  rm -f "$LO_LIVE"
  printf '3:aaa000000000:fix/3-b\n' > "$O/state/last-open-prs"
  eqv "an UNREADABLE live table owns nothing (fail CLOSED)" "1" "$(_own 1)"

  # (6) THE WIRING, driven from the shipped gate table below.
  # (4) The DRAIN ARITHMETIC at the shipped threshold. `MERGE_PRIORITY_AT=25` is the raised default;
  #     25 must NOT trip it and 26 must.
  MERGE_PRIORITY_AT=25; MAX_REVIEW=4; MAX_FIX=3
  . "$TMP/fix_slots.sh"
  # review_slots is the sibling half of the same rule and must be driven here too.
  ex review_slots > "$TMP/review_slots.sh"
  . "$TMP/review_slots.sh"
  # ⛔ NO THRESHOLD: the first argument is the WORKABLE un-owned count, and 1 blocks. The old table
  # (26 gated, 25 and 20 open) encoded the defect — the measured box sat at exactly 25 un-owned PRs
  # with nothing working them while it opened more work from issues.
  ck "26 unowned PRs, nothing in flight -> DRAIN (one is enough)"  26 0 0 gate
  ck "25 unowned PRs (the measured state) -> DRAIN"                25 2 5 gate
  ck "20 unowned PRs, 0 workers -> DRAIN"                          20 0 0 gate
  ck "0 unowned PRs -> the issue path may open"                     0 2 5 open
  # ⛔ THE ASYMMETRY THIS FIXES: drain mode raised the REVIEWER budget only, so a backlog of
  # DIRTY/BEHIND PRs — 17 of 20 on the live cells — sent the extra capacity at reviewers while the
  # fixer spawn sites still compared against the unraised MAX_FIX.
  eqv "drain mode RAISES the fixer budget (MAX_FIX+2) — the half that was missing" "5" "$(fix_slots 26)"
  # ⛔ AND THE THRESHOLD IS GONE TOO (review R2, P3): the GATE blocks the issue path on ONE un-owned
  # PR, so the headroom must follow the same predicate — a 25-PR drain at the pre-change WIP is the
  # "capped to a trickle" shape the owner's rule 5 forbids. Below the old size threshold is now FULL.
  eqv "25 un-owned (the measured state) raises the fixer budget too — no size threshold" "5" "$(fix_slots 25)"
  eqv "1 un-owned PR is enough to raise the fixer budget" "5" "$(fix_slots 1)"
  eqv "0 un-owned -> the base fixer budget" "3" "$(fix_slots 0)"
  eqv "review_slots alongside it raises the reviewer budget (MAX_REVIEW+2)" "6" "$(review_slots 26)"
  eqv "25 un-owned raises the reviewer budget too (same predicate as the gate)" "6" "$(review_slots 25)"
  eqv "0 un-owned -> the base reviewer budget" "4" "$(review_slots 0)"
  # ⛔ A NON-NUMERIC COUNT MUST NOT ERROR INTO THE SMALLER BUDGET: `[ "x" -gt 0 ]` errors (rc 2, FALSE)
  # and would silently pick the restrictive arm — the "errored test is FALSE" pattern this file guards.
  eqv "a non-numeric un-owned count falls back to the BASE budget, not an error" "4" "$(review_slots x)"
  # base 10, not octal: `$(( 010 + 2 ))` is 10, `$(( 10#010 + 2 ))` is 12
  MAX_FIX=010
  eqv "fix_slots reads MAX_FIX in BASE 10 (a leading zero is not octal)" "12" "$(fix_slots 26)"
  MAX_FIX=3

  # (5) The DEFAULTS both files resolve, driven rather than grepped: a new cell must inherit the
  #     same threshold as the box it was cloned from, and the raised number is the whole relief.
  _def() { ( unset MERGE_PRIORITY_AT; eval "$(grep -E '^(export +)?MERGE_PRIORITY_AT=' "$1")"; printf '%s' "${MERGE_PRIORITY_AT:-UNSET}" ); }
  eqv "orch-loop.sh defaults MERGE_PRIORITY_AT to 25 (was 10 — the self-cap)" "25" "$(_def "$ORCH")"
  eqv "install.sh defaults MERGE_PRIORITY_AT to the SAME value (a new cell inherits it)" "25" "$(_def "$INST")"
  # ⛔ The fallback for an UNKNOWN count must also clear the raised threshold, or a failed listing
  # would OPEN the gate. Driven from the shipped function (extracted, with a stub failing `gh`) with
  # NO tunable in the environment.
  { echo 'set -u'; grep -m1 '^is_num() {' "$ORCH"; sed -n '/^open_pr_count() {/,/^}/p' "$ORCH"; echo 'open_pr_count'; } > "$TMP/ocdrive.sh"
  mkdir -p "$TMP/ocstub"; printf '#!/bin/bash\nexit 1\n' > "$TMP/ocstub/gh"; chmod +x "$TMP/ocstub/gh"
  rm -f "$TMP/ownO/state/last-open-n"
  # ⛔ The stale row file must be PRESENT before the failing run, or the assertion below is
  # vacuous: pre-deleting it made the post-condition hold whether or not open_pr_count removes it.
  # (Measured: with the `rm -f` deleted from orch-loop.sh, the pre-deleting form stayed GREEN.)
  printf '9:deadbeef00000000000000000000000000000000\n' > "$TMP/ownO/state/last-open-prs"
  eqv "a failed count with no tunable set assumes 26 (above the 25 default, BROAD)" "26" \
    "$(PATH="$TMP/ocstub:$PATH" O="$TMP/ownO" OR=acme/widget LOG=/dev/null bash "$TMP/ocdrive.sh")"
  # ⛔ …and the OTHER HALF of the same listing must not survive that failure: a stale row file
  # paired with a fallback count would silently under-count the unowned set.
  # ⛔ The stale row file that MUST be gone: the assertion above is only meaningful when a row file
  # was actually there to remove (the pre-deleting form of this check could not fail).
  if [ -f "$TMP/ownO/state/last-open-prs" ]; then
    echo "  ❌ a failed listing LEFT a stale state/last-open-prs behind — the unowned scan would read a different moment than the count"; FAIL=$((FAIL+1))
  else
    echo "  ✅ a failed listing REMOVES a stale state/last-open-prs (no stale rows paired with a fallback count)"; PASS=$((PASS+1))
  fi
  # ⛔ THE SUCCESS HALF, and it is the half the whole feature hangs on: if the row file is never
  # WRITTEN, `unowned_pr_count` finds no rows every cycle and assumes NOTHING is owned — it fails
  # CLOSED, so no test goes red on a crash, but the gate reads `unowned = total open` and the fleet
  # re-caps itself exactly as before this change. Silent, and the direction nobody would notice.
  rm -f "$TMP/ownO/state/last-open-n" "$TMP/ownO/state/last-open-prs"
  printf '#!/bin/bash\necho "$*" >> "%s/calls"\nprintf "25 1:aaa000000000 2:bbb000000000\\n"\n' "$TMP/ocstub" > "$TMP/ocstub/gh"
  chmod +x "$TMP/ocstub/gh"; rm -f "$TMP/ocstub/calls"
  eqv "a successful listing returns the count" "25" \
    "$(PATH="$TMP/ocstub:$PATH" O="$TMP/ownO" OR=acme/widget LOG=/dev/null bash "$TMP/ocdrive.sh")"
  eqv "a successful listing PERSISTS the count (last-open-n)" "25" "$(cat "$TMP/ownO/state/last-open-n" 2>/dev/null || printf 'MISSING')"
  eqv "a successful listing PERSISTS the number:sha rows the unowned scan needs (last-open-prs)" \
    "1:aaa000000000 2:bbb000000000" "$(cat "$TMP/ownO/state/last-open-prs" 2>/dev/null || printf 'MISSING')"
  # ONE listing, not two: the rows ride the same call as the count. A second `gh pr list` would
  # double the shared rate-limit budget (#1762) and could read a DIFFERENT moment than the count.
  _gh_calls="$(wc -l < "$TMP/ocstub/calls" 2>/dev/null | tr -d ' ')"
  [ "${_gh_calls:-0}" = "1" ] \
    && { echo "  ✅ count and rows come from ONE gh listing (no second API call, no torn read)"; PASS=$((PASS+1)); } \
    || { echo "  ❌ expected 1 gh pr list call, observed ${_gh_calls:-0} — the count and the rows are a torn read"; FAIL=$((FAIL+1)); }

  # (6) THE WIRING. A perfect ownership count is dead code if the gate still receives the TOTAL.
  wpin "the loop derives UPN (unowned) from the listing" "$ORCH" 'UPN="$(unowned_pr_count "$OPEN_N")"'
  # ⛔ The CALL, not the name: a fixed-string grep for the function name is satisfied by its
  # DEFINITION, so deleting the call would leave the assertion green while the snapshot was never
  # refreshed. Match the indented call form.
  if grep -qE '^[[:space:]]+if lo_scan "\$LO_LIVE" "\$REPO"' "$ORCH"; then
    echo "  ✅ the loop CALLS lo_scan once per cycle (not just defines it)"; PASS=$((PASS+1))
  else
    echo "  ❌ lo_scan is defined but never CALLED in the loop body — ownership would never be refreshed"; FAIL=$((FAIL+1))
  fi
  # ⛔ ABSENCE PIN: the predicate must not go back to reading worker SESSION NAMES. That is the
  # measured defect — pr-doctor reported 21 "running" lanes while a live-cwd scan found none of them
  # holding a PR branch, and 25 PRs sat un-owned.
  if grep -qE '^[[:space:]]*if wsess ' "$ORCH"; then
    echo "  ❌ pr_owned still consults worker session NAMES — a session is a declaration, not work"; FAIL=$((FAIL+1))
  else
    echo "  ✅ pr_owned does not count a session name as ownership (absence pin)"; PASS=$((PASS+1))
  fi
  # ⛔ ORDER, and it is load-bearing: pr_owned->claim_live reads state/claims-snapshot, so the
  # ownership scan must come AFTER the one fetch that refreshes it. Before the fix the scan ran ~220
  # lines early and the gate read the PREVIOUS cycle's file while the sweep read the fresh one.
  _snap_line="$(grep -nF 'claim_snapshot "$O/state/claims-snapshot"' "$ORCH" | head -1 | cut -d: -f1)"
  _scan_line="$(grep -nF 'UPN="$(unowned_pr_count' "$ORCH" | head -1 | cut -d: -f1)"
  [ -n "$_snap_line" ] && [ -n "$_scan_line" ] && [ "$_snap_line" -lt "$_scan_line" ] \
    && { echo "  ✅ the claim snapshot is refreshed BEFORE the ownership scan reads it"; PASS=$((PASS+1)); } \
    || { echo "  ❌ the ownership scan (line ${_scan_line:-?}) runs at or before the claim snapshot refresh (line ${_snap_line:-?}) — the gate reads a stale snapshot"; FAIL=$((FAIL+1)); }
  wpin "the reviewer budget is derived from the UNOWNED count" "$ORCH" 'MR="$(review_slots "$UPN")"'
  wpin "the fixer budget is derived from the UNOWNED count" "$ORCH" 'MF="$(fix_slots "$UPN")"'
  # …at EVERY fixer spawn site (a count, not a find: a partial revert that leaves one site on the
  # unraised MAX_FIX is exactly the asymmetry this change removes).
  _mf_sites="$(grep -cF -- '-lt "$MF"' "$ORCH")"
  [ "${_mf_sites:-0}" = "3" ] \
    && { echo "  ✅ all 3 fixer spawn sites compare against the drain-aware budget"; PASS=$((PASS+1)); } \
    || { echo "  ❌ expected 3 fixer spawn sites on \$MF, found ${_mf_sites:-0} — some still use the unraised MAX_FIX"; FAIL=$((FAIL+1)); }
  if grep -qF -- '-lt "${MAX_FIX:-3}"' "$ORCH"; then
    echo "  ❌ a fixer spawn site still compares against the unraised MAX_FIX (the asymmetry is back)"; FAIL=$((FAIL+1))
  else
    echo "  ✅ no fixer spawn site is left on the unraised MAX_FIX (absence pin)"; PASS=$((PASS+1))
  fi
  wpin "the gate receives the WORKABLE UNOWNED count" "$ORCH" 'GATE_WHY="$(mp_reason "${UPN_WORK:-${UPN:-0}}" "$LANES" "$WORKERS" "${SEL_TOTAL:-${OPEN_N:-0}}")"'
  # ⛔ ONE POPULATION PER CYCLE: the total and its parts are computed together from the RICHEST source
  # that read — state/last-open-prs first, the swept REST set only as its FALLBACK (GraphQL is the
  # listing that fails first under a rate limit, which is why OPEN_N can be a synthetic number), and
  # OPEN_N alone last. The order is the assertion: a funnel whose parts come from different reads is
  # one an operator learns to ignore, and the SWEPT set alone must never be the gate's primary source
  # (SWEEP_LIST is SCOPE-FILTERED, so `SCOPE=own` would read 0 un-owned while the repo held fifty).
  wpin "the funnel's population is the OPEN-PR row set" "$ORCH" 'OPEN_ROWS="$(cat "$O/state/last-open-prs"'
  wpin "…and it is the PRIMARY source for the gate's count" "$ORCH" 'UPN_WORK=$(( UPN - SEL_PARKED )); [ "$UPN_WORK" -lt 0 ] && UPN_WORK=0'
  if grep -qF 'elif [ "${SEL_UNOWNED:-0}" -gt 0 ]' "$ORCH" && grep -qF 'POP=open-rows' "$ORCH"; then
    echo "  ✅ the scope-filtered sweep set is the FALLBACK, reached only when no open-PR rows exist"; PASS=$((PASS+1))
  else
    echo "  ❌ the swept set is not clearly a fallback — a scope-filtered population could be the gate's primary source"; FAIL=$((FAIL+1))
  fi
  # …and the source actually used is printed, so a degraded population is visible rather than inferred.
  wpin "the cycle logs WHICH population the funnel used" "$ORCH" '[select] population=$POP'
  # ⛔ (R2, P2) THE INTERFACE, NOT THE FILE: a `$O` copy providing lo_scan but not lo_order/
  # lo_select_rows/lo_class_compact produced an EMPTY SEL_ROWS — the sweep then acted on ZERO PRs,
  # silently, while `scan=ok`. One missing name must mean the registry-only degrade.
  wpin "LO_SCAN is gated on the FULL interface the loop calls" "$ORCH" \
       'if declare -f lo_scan lo_order lo_select_rows lo_select lo_class_compact >/dev/null 2>&1; then'
  # ⛔ (R2, P2) a FAILED scan must stop the predicate reading a table it could not refresh.
  wpin "a failed scan blanks LO_LIVE (the predicate cannot read a stale table)" "$ORCH" '      LO_LIVE=""'
  # ── THE DRAIN LINE IS DRIVEN, NOT PINNED (measured: an unset-variable abort inside it killed every
  # cycle right after `[dispatch] issues BLOCKED`, and a TEXT pin stayed green through all of it).
  # The block is delimited by [drain-health:begin|end] so it can be extracted and RUN.
  _DRAIN_BLOCK="$(sed -n '/^ *# \[drain-health:begin\]/,/^ *# \[drain-health:end\]/p' "$ORCH")"
  # here-string, never `printf … | grep -q` (#841/#864: the producer takes SIGPIPE and pipefail flips it)
  if grep -q 'DRAIN STALLED' <<<"$_DRAIN_BLOCK"; then
    echo "  ok the drain-health block was extracted from the controller"; PASS=$((PASS+1))
  else
    echo "  ❌ could not extract the drain-health block (markers moved?)"; FAIL=$((FAIL+1))
  fi
  {
    grep -E '^is_num\(\) \{' "$ORCH"
    sed -n '/^file_mtime_epoch() {/,/^}/p' "$ORCH"
    sed -n '/^mp_recent_land() {/,/^}/p' "$ORCH"
  } > "$TMP/drain_helpers.sh"
  DO="$TMP/drainO"; mkdir -p "$DO/state"
  _drain() { # _drain <land-age-minutes> [MERGE_STALL_MIN]
    ( set -u
      O="$DO"; LOG="$TMP/drain.log"; : > "$LOG"; UPN_WORK=50
      . "$TMP/drain_helpers.sh"
      rm -f "$DO"/state/merged-*.done
      if [ -n "${1:-}" ]; then
        : > "$DO/state/merged-7777.done"
        # a bare number is "minutes AGO"; a leading '+' is minutes in the FUTURE (the clock-step case).
        # ⛔ SET THE MTIME PORTABLY: `date -v-200M` is BSD-only, so on the Linux CI runner the stamp
        # stayed at NOW and the two age cases failed there while passing on macOS (measured). python3
        # sits on both runners and `os.utime` cannot be read wrong.
        # a bare number is minutes AGO (negative offset), a leading '+' is minutes in the FUTURE
        case "$1" in +*) _min="${1#+}" ;; -*) _min="-${1#-}" ;; *) _min="-${1}" ;; esac
        python3 - "$_min" "$DO/state/merged-7777.done" <<'PYEOF'
import os, sys, time
os.utime(sys.argv[2], (lambda t: (t, t))(time.time() + int(sys.argv[1]) * 60))
PYEOF
      fi
      if [ -n "${2:-}" ]; then MERGE_STALL_MIN="$2"; else unset MERGE_STALL_MIN; fi
      eval "$_DRAIN_BLOCK"   # SAME shell: the block reads O/LOG/UPN_WORK as shell vars
      cat "$LOG" )
  }
  _out="$(_drain 5)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "  ok the block runs with MERGE_STALL_MIN UNSET, no abort (rc 0)"; PASS=$((PASS+1))
  else
    echo "  ❌ the block ABORTED with MERGE_STALL_MIN unset (rc=$rc) — a live cycle dies here: $_out"; FAIL=$((FAIL+1))
  fi
  case "$_out" in
    *"drain alive"*) echo "  ok a RECENT land prints 'drain alive'"; PASS=$((PASS+1)) ;;
    *) echo "  ❌ a recent land did not print 'drain alive': $_out"; FAIL=$((FAIL+1)) ;;
  esac
  _out="$(_drain 200)"
  case "$_out" in
    *"DRAIN STALLED"*200m*) echo "  ok a 200m-old land NAMES the stall (the age is printed)"; PASS=$((PASS+1)) ;;
    *) echo "  ❌ a 200m-old land did not name the stall: $_out"; FAIL=$((FAIL+1)) ;;
  esac
  _out="$(_drain 5 abc)"
  case "$_out" in
    *"drain alive"*|*"DRAIN STALLED"*) echo "  ok a NON-NUMERIC MERGE_STALL_MIN falls back to 180 and still decides"; PASS=$((PASS+1)) ;;
    *) echo "  ❌ a non-numeric MERGE_STALL_MIN produced no verdict: $_out"; FAIL=$((FAIL+1)) ;;
  esac
  # ⛔ A FUTURE LAND STAMP IS UNMEASURABLE, NOT A FRESH LAND (review cycle 3, P2). `find -mmin -N`
  # passes a future-stamped file, so clamping the negative age to 0 rendered a clock step-back as
  # "drain alive" — and after the release valve was removed this line is a stall's only signal.
  _out="$(_drain +30)"   # a stamp 30 minutes in the FUTURE
  case "$_out" in
    *"drain alive"*) echo "  ❌ a FUTURE land stamp printed 'drain alive' — an unread reading is not an all-clear: $_out"; FAIL=$((FAIL+1)) ;;
    *"UNMEASURED"*) echo "  ok a FUTURE land stamp is UNMEASURED — neither a stall nor an all-clear"; PASS=$((PASS+1)) ;;
    *"DRAIN STALL"*) echo "  ❌ a FUTURE land stamp printed a stall verdict (it is unmeasured, not stalled): $_out"; FAIL=$((FAIL+1)) ;;
    *) echo "  ❌ a FUTURE land stamp produced no verdict at all: $_out"; FAIL=$((FAIL+1)) ;;
  esac

  # ── THE PARKED EXCLUSION IS HEAD-KEYED (review cycle 3, P1) ──────────────────────────────────
  # The gate subtracts parked PRs from the un-owned count, so an exclusion that counts a marker's
  # EXISTENCE over-subtracts: a PR parked at an OLD head, then pushed, is WORKABLE while its marker
  # still sits on disk — and with one un-owned PR left that floored the count to 0 and OPENED the
  # issue path. Extract the block and DRIVE it: same head -> parked (1), different head -> not parked
  # (0), legacy/headless marker -> not parked (0, fail-closed).
  _PARK_BLOCK="$(sed -n '/^ *# \[parked-count:begin\]/,/^ *# \[parked-count:end\]/p' "$ORCH")"
  if grep -q 'SEL_PARKED' <<<"$_PARK_BLOCK"; then
    echo "  ok the parked-count block was extracted from the controller"; PASS=$((PASS+1))
  else
    echo "  ❌ could not extract the parked-count block (markers moved?)"; FAIL=$((FAIL+1))
  fi
  PO="$TMP/parkO"; mkdir -p "$PO/state"
  _parkn() { # _parkn <marker-content|''> <row-head>  -> SEL_PARKED on stdout
    ( set -u
      O="$PO"; SEL_ROWS=""; LOG="$TMP/park.log"; : > "$LOG"
      rm -f "$PO"/state/parked-*; rm -f "$PO/state/last-open-prs"
      if [ -n "${1+set}" ]; then printf '%s\n' "$1" > "$PO/state/parked-42"; fi
      OPEN_ROWS="42:${2:-}:2026-01-01T00:00:00Z"
      pr_owned() { return 1; }   # an un-owned PR: only the park can exclude it
      eval "$_PARK_BLOCK"
      printf '%s' "$SEL_PARKED" )
  }
  _got="$(_parkn aaaa1111 aaaa1111)"; [ "$_got" = "1" ]     && { echo "  ok a park at THIS head excludes the PR (1)"; PASS=$((PASS+1)); }     || { echo "  ❌ a park at this head did not exclude it (got $_got, want 1)"; FAIL=$((FAIL+1)); }
  _got="$(_parkn aaaa1111 bbbb2222)"; [ "$_got" = "0" ]     && { echo "  ok a park from an OLD head does NOT exclude the pushed PR (a stale park is not a park)"; PASS=$((PASS+1)); }     || { echo "  ❌ a STALE park still excluded a pushed, workable PR (got $_got, want 0) — the issue path opens on real work"; FAIL=$((FAIL+1)); }
  _got="$(_parkn '' bbbb2222)"; [ "$_got" = "0" ]     && { echo "  ok a headless/legacy park marker does not exclude (fail-closed)"; PASS=$((PASS+1)); }     || { echo "  ❌ a headless park marker excluded a PR (got $_got, want 0)"; FAIL=$((FAIL+1)); }

  # ── THE FUNNEL'S ARITHMETIC CLOSES IN THE FLOOR BRANCH (review cycle 3, P2) ─────────────────
  # In the fail-closed floor the population IS the listing, so the swept set's parked count must not
  # be printed as an extra part: `26 PRs: 26 un-owned (0 owned, 5 parked)` does not add up.
  grep -q 'SEL_PARKED=0' <<<"$FLOOR_SRC" 2>/dev/null || true
  _FLOOR_SRC="$(sed -n '/⛔ AND THE PARKED PART DIES WITH THE POPULATION/,/FLOOR_NOTE=/p' "$ORCH")"
  if grep -q 'SEL_PARKED=0' <<<"$_FLOOR_SRC"; then
    echo "  ok the fail-closed floor re-bases the parked part (funnel arithmetic closes)"; PASS=$((PASS+1))
  else
    echo "  ❌ the floor branch keeps the swept parked count — the funnel's parts no longer sum to its total"; FAIL=$((FAIL+1))
  fi
  # (F7) the documented `scan=` token must be an ARTIFACT, not a comment promise.
  wpin "the population line carries the scan STATUS (a documented token that exists)" "$ORCH" '[select] population=$POP scan=$LO_STATUS'
  # ── REVIEW R1, P1: the SCOPE-FILTERED fallback may never LOWER the gate ──────────────────────
  # With no open-PR rows the count is the whole listing ("assume nothing is owned") and SWEEP_LIST is
  # scope-filtered and survives a non-200 sweep — so a swept set reading fully owned is a normal state
  # in exactly the cycle that fallback exists for. Taking its smaller number opens the issue path on
  # the defect this change removes, so the floor is pinned, together with its own printed line.
  wpin "the swept fallback is FLOORED by the fail-closed count" "$ORCH" 'if is_num "${UPN:-}" && [ "$UPN" -gt "$UPN_WORK" ]; then'
  wpin "…and the floor is NAMED when it applies" "$ORCH" '⚠️ fail-closed floor: the listing answers'
  # ── REVIEW R1, P3: the parked subtraction is over UN-OWNED PRs only ─────────────────────────
  # UPN already excludes owned PRs; subtracting a PR that is both parked and owned removed a unit
  # that was never in the minuend, and with one un-owned PR left that opened the issue path.
  wpin "a parked PR is subtracted only when it is UN-OWNED" "$ORCH" 'if ! pr_owned "$_op" "$_osha" "$_obr"; then SEL_PARKED=$(( SEL_PARKED + 1 )); fi'
  # ── REVIEW R1, P2: a LOST funnel line is a HOLD, not a re-decision ─────────────────────────
  wpin "a funnel that printed nothing HOLDS (it never re-decides from the capacity gate)" "$ORCH" 'HOLDING: no issue work this cycle'
  if grep -qF 'LO_SELECT_DEFINED' "$ORCH"; then
    echo "  ✅ the fallback keys on AVAILABILITY (module present?), not on an empty line"; PASS=$((PASS+1))
  else
    echo "  ❌ the fallback keys on the funnel line being empty — a failed write would re-decide the cycle"; FAIL=$((FAIL+1))
  fi
  # ── REVIEW R1, P3: the stall tunable is normalised before it is compared ────────────────────
  # ⛔ THE PIN MUST NAME THE SHIPPED LINE, NOT THE COMMENT ABOUT THE OLD ONE (review cycle 3, P2): the
  # previous pin matched a comment quoting the BUGGY form, so deleting the real normalisation left it
  # green. Pin the assignment and the subject it feeds; the behaviour is driven separately below.
  wpin "MERGE_STALL_MIN is validated (a non-numeric value must not read as 'drain alive')" "$ORCH" '_stallraw="${MERGE_STALL_MIN:-180}"'
  wpin "…and the validation case reads the NORMALISED variable, never the bare name" "$ORCH" 'case "$_stallraw" in'
  # ── THE GATE HAS NO RELEASE ARM, AND THAT IS PINNED (owner ruling, 2026-10-18) ────────────────
  # "Only when NO un-owned PR remains may the dispatcher create new work by picking issues." A stalled
  # drain must therefore produce a NAME, never a release: an age-based release turns *PRs are not
  # landing* into *dispatch more issues*, which hides the stall behind fresh activity. The PR queue IS
  # the work, so the correct response to "nothing has landed in 4h" is to say so beside the gate.
  wpin "a long stall is NAMED beside the gate it explains" "$ORCH" '[dispatch] DRAIN STALLED — no PR merged in ${_lage}m'
  # ⛔ ABSENCE PIN against the release arm returning: no function here may take an AGE and return
  # "not held". `mp_reason`'s arguments are inputs to a HOLD; nothing in the selection path may read a
  # land age to decide that the gate should stop holding.
  # (the tokens are the ones such an arm would introduce — `released_until`, `mp_release`, a
  # `RELEASE_NOTE`; a bare word "released" appears in unrelated lock comments and is not a signal)
  if grep -qE 'released_until|mp_release|RELEASE_NOTE' "$ORCH"; then
    echo "  ❌ an age-based RELEASE of the un-owned gate is back — that reverses the owner's ruling (un-owned PRs first, no exception for a stalled drain)"; FAIL=$((FAIL+1))
  else
    echo "  ✅ no age-based release of the un-owned gate (absence pin — a stall is named, never released)"; PASS=$((PASS+1))
  fi
  # …and the stall datum is DIAGNOSTIC ONLY: it must not be handed to the gate or to lo_select.
  # ⛔ NO `producer | grep -q` (agent-infra#841/#864): `grep -q` exits at the first match, the producer
  # takes SIGPIPE, and under `pipefail` the pipeline returns 141 — so the test would silently invert.
  # Capture the source once, then test the capture.
  _stalluse="$(grep -E '_lage|MERGE_STALL_MIN' "$ORCH" 2>/dev/null || true)"
  if [ -n "$_stalluse" ] && grep -qE 'GATE_WHY|lo_select' <<<"$_stalluse"; then
    echo "  ❌ the stall age reaches the gate/selection — it may only be printed"; FAIL=$((FAIL+1))
  else
    echo "  ✅ the stall age is printed, never handed to the gate or to lo_select"; PASS=$((PASS+1))
  fi
  # ⛔ Parked PRs are subtracted from the gate's number (a PR no lane may touch must not latch the
  # issue path shut forever) — and the subtraction must be COMPUTED, not assumed.
  wpin "the gate's count subtracts parked (needs-a-human) PRs" "$ORCH" 'UPN_WORK=$(( UPN - SEL_PARKED ))'
  # ⛔ And the FUNNEL's verdict is authoritative over the issue path: a printed decision that the
  # gate can ignore is exactly the "printed claim with no artifact" failure this change removes.
  wpin "the printed funnel decision gates the issue path" "$ORCH" 'if [ "${LO_CHOICE:-issue}" != "issue" ] && [ -z "$GATE_WHY" ]; then'
  # …and the one line that makes "busy" and "draining" different readings of the log.
  wpin "the issue path announces the block in one line" "$ORCH" '[dispatch] issues BLOCKED'
  # ⛔ The REVERT, pinned as an ABSENCE: passing the total open count is the exact regression this
  # section exists for, and a presence-only wpin cannot see it.
  if grep -qF 'mp_reason "${OPEN_N:-0}"' "$ORCH"; then
    echo "  ❌ the gate still receives the TOTAL open count — the self-cap is back"; FAIL=$((FAIL+1))
  else
    echo "  ✅ the gate no longer receives the total open count anywhere (absence pin)"; PASS=$((PASS+1))
  fi
  # …and the count must not be trusted blindly: a malformed UPN falls back to the TOTAL (drain), not
  # to 0 (dispatch). `[ … -gt … ]` on a non-number ERRORS, and an errored test is FALSE = FAIL OPEN.
  _upn_guard="$(grep -cF 'is_num "${UPN:-}" ||' "$ORCH")"
  [ "${_upn_guard:-0}" = "2" ] \
    && { echo "  ✅ a malformed UPN is coerced twice (total open, then above-threshold) — both fail CLOSED"; PASS=$((PASS+1)); } \
    || { echo "  ❌ expected 2 fail-closed UPN coercions, found ${_upn_guard:-0} — a non-numeric count would ERR and OPEN the gate"; FAIL=$((FAIL+1)); }
  # …and the guard predicate must be `is_num`, not a digit-only `case`: the case pattern admits a
  # LEADING ZERO, which `[ … -gt … ]` reads as decimal, so `08` opened the gate.
  if grep -qF 'case "${UPN:-}" in' "$ORCH"; then
    echo "  ❌ a digit-only UPN guard is back — a leading-zero count (08) slips through it and OPENS the gate"; FAIL=$((FAIL+1))
  else
    echo "  ✅ the UPN guards use is_num, which rejects leading zeros (absence pin)"; PASS=$((PASS+1))
  fi
else
  echo "  ❌ the ownership functions did not extract to syntactically valid shell"; FAIL=$((FAIL+1))
fi

echo
echo "=== NO TIME BOUND, NO AGE-BASED RELEASE (owner ruling, 2026-10-18 — #2099) ==="
# ⛔ THIS SECTION REPLACES agent-infra#2040's bounded-gate suite. #2040 built an age/land/youngest-evidence
# RELEASE of the merge-priority gate; the owner's ruling has no such arm ("Only when NO un-owned PR
# remains may the dispatcher create new work by picking issues"), so the machinery — mp_reason's
# evidence clauses, mp_release, mp_bound_released, mp_released_until/marker, mp_block_marker and
# unowned_youngest_age_min — was removed at merge. What replaces it is a NAME for a stalled drain
# plus an ABSENCE PIN below, so the arm cannot return silently.
if grep -qE 'mp_release|mp_bound_released|mp_released_until|mp_released_marker|mp_block_marker|released_until' "$ORCH"; then
  echo "  ❌ the age-based RELEASE machinery is back in the controller — that reverses #2099"; FAIL=$((FAIL+1))
else
  echo "  ✅ no release machinery in the controller (absence pin over the whole file)"; PASS=$((PASS+1))
fi
# …and the GATE ITSELF is driven with that tunable set to a pathological value: a release arm keyed on
# it would return EMPTY here, which these two cases would catch.
MERGE_PRIORITY_MAX_AGE_MIN=1
ck "the tunable cannot release the gate: 3 un-owned with a 1m window -> still DRAIN" 3 1 1 gate
ck "…and with no lane at all"                                                        3 0 0 gate

echo "=== the repo surface: derived from the checkout, never a standing literal (P1 of the epilogue) ==="
# The guard counted ANOTHER repo's PR queue for hours because `OR` was an independent literal. The
# parse is the fix, so it is DRIVEN — every shape, including the ones that must be REFUSED.
SLUG="$HERE/repo-slug.sh"
if bash -n "$SLUG" 2>/dev/null; then
  _slug() { ( . "$SLUG"; repo_slug_from_remote "$1" ); }
  eqv "https origin -> owner/name"                    "acme/widget" "$(_slug https://github.com/acme/widget.git)"
  eqv "https origin without .git -> owner/name"        "acme/widget" "$(_slug https://github.com/acme/widget)"
  eqv "scp-style ssh origin -> owner/name"             "acme/widget" "$(_slug git@github.com:acme/widget.git)"
  eqv "ssh:// origin with a user -> owner/name"        "acme/widget" "$(_slug ssh://git@github.com/acme/widget.git)"
  eqv "a LOCAL PATH remote is REFUSED (empty)"         ""            "$(_slug /tmp/foo)"
  eqv "a file:// remote is REFUSED (empty)"            ""            "$(_slug file:///srv/mirror.git)"
  eqv "a remote with no owner is REFUSED (empty)"      ""            "$(_slug https://github.com/widget.git)"
  eqv "an empty remote is REFUSED (empty)"             ""            "$(_slug '')"
  eqv "an ssh:// origin with an explicit PORT -> owner/name" "acme/widget" "$(_slug ssh://git@github.com:22/acme/widget.git)"
  eqv "an http origin on a self-hosted port -> owner/name"   "owner/name"  "$(_slug http://ghe.local:8080/owner/name.git)"
  eqv "a deep path (…/owner/name/tree/main) is REFUSED"      ""           "$(_slug https://github.com/owner/name/tree/main)"
  eqv "a QUERY string is REFUSED, never carried into gh --repo" ""        "$(_slug 'https://github.com/acme/widget?tab=1')"
  eqv "a .git/ remote (slash AFTER .git) -> owner/name"      "acme/widget" "$(_slug https://github.com/acme/widget.git/)"
  eqv "https with a user:token authority -> owner/name"       "acme/widget" "$(_slug https://user:tok@github.com/acme/widget.git)"
  eqv "an explicit OR that is not owner/name is REFUSED"      ""            "$( ( . "$SLUG"; derive_or "$HERE/../.." garbage ) )"
  # ⛔ AND THE RETURN CODE SAYS WHICH FAILURE IT IS (review round 8, P1). Conflated with "the origin
  # cannot be parsed", an invalid pin fell back to the hardcoded literal — #2040 itself — so rc 2 is
  # the whole difference between "refuse the operator's typo" and "grade a repo nobody named".
  eqv "an invalid explicit OR returns rc=2 (a config error, not an underivable origin)" \
      "rc=2" "$( ( . "$SLUG"; derive_or "$HERE/../.." garbage ) >/dev/null 2>&1; echo "rc=$?" )"
  eqv "a valid explicit OR returns rc=0" \
      "rc=0" "$( ( . "$SLUG"; derive_or "$HERE/../.." other/repo ) >/dev/null 2>&1; echo "rc=$?" )"
  # …and an explicit OR still WINS over the checkout (a cell that grades another queue says so).
  eqv "an explicit OR overrides the checkout"          "other/repo"  "$( ( . "$SLUG"; derive_or "$HERE/../.." other/repo ) )"
else
  echo "  FAIL repo-slug.sh does not parse"; FAIL=$((FAIL+1))
fi

echo
echo "=== the PR listing carries the HEAD REF end-to-end (the jq is DRIVEN) ==="
# ⛔ THE ROW FORMAT IS WHAT MAKES OWNERSHIP ANSWERABLE: the live predicate is "a process is in a
# checkout of this PR's head ref", so the head ref has to ride the SAME listing as the count. Drive the
# SHIPPED jq program against real JSON — a revert to `number,headRefOid` rows would leave the branch
# empty and every PR un-owned-by-branch, which is the failure this change removes.
_JQ_PROG="$(grep -o -- "--jq '[^']*'" "$ORCH" | grep 'headRefName' | head -1 | sed "s/^--jq '//; s/'$//")"
if [ -n "$_JQ_PROG" ] && command -v jq >/dev/null 2>&1; then
  eqv "the shipped --jq emits number:headOid:headRef for a normal row" "1 7:abc:feat/x" \
      "$(printf '%s' '[{"number":7,"headRefOid":"abc","headRefName":"feat/x"}]' | jq -r "$_JQ_PROG")"
  case "$(grep -o -- '--json number,headRefOid[,a-zA-Z]*' "$ORCH" | head -1)" in
    *headRefName*) echo "  ok the PR listing ASKS for headRefName in the same read (no second, drifting snapshot)"; PASS=$((PASS+1)) ;;
    *) echo "  FAIL the PR listing does not request headRefName — the predicate is unanswerable"; FAIL=$((FAIL+1)) ;;
  esac
else
  echo "  FAIL the shipped --jq (or jq itself) is unavailable — the predicate's input is unverifiable"; FAIL=$((FAIL+1))
fi

echo "=== the land probe is DRIVEN, not described (the stall line reads it) ==="
# ⛔ `unowned_youngest_age_min` was removed at merge with #2040's release arm (see the absence pin
# above); `mp_recent_land` SURVIVES because the `DRAIN STALLED` diagnostic and `[cap] last_land=`
# both read it, so it must stay driven rather than described.
# ⛔ DRIVEN, NOT DESCRIBED: neither probe was executed by any suite, so a wrong default dir, a wrong
# glob or a wrong token parse stayed green. The fixture is built from the SHIPPED functions and their
# real dependencies (is_num, the mtime reader, the ownership arms) — a missing one makes `bash -n` or
# the probe itself fail loudly instead of returning a plausible empty answer.
{
  ex file_mtime_epoch; ex pr_owned; ex claim_foreign_live; ex claim_live; ex claim_lease_live
  ex unowned_scan; ex unowned_pr_count; ex mp_recent_land
  grep -E '^is_num\(\) \{' "$ORCH"; grep -E '^_this_host\(\) \{' "$ORCH"
} > "$TMP/pr_all.sh"
if bash -n "$TMP/pr_all.sh" 2>/dev/null; then
  PO="$TMP/probeO"; mkdir -p "$PO/state"
  _probe() { ( O="$PO"; WSESS=""; . "$TMP/pr_all.sh"; "$@" ); }
  # (1) a landed PR is evidence of progress; nothing else is.
  eqv "no state/merged-*.done -> no land recorded" "" "$(_probe mp_recent_land)"
  : > "$PO/state/merged-1.done"
  [ -n "$(_probe mp_recent_land)" ] \
    && { echo "  ok a state/merged-<PR>.done IS read as a land (dir default, glob, mtime)"; PASS=$((PASS+1)); } \
    || { echo "  FAIL mp_recent_land did not see state/merged-1.done"; FAIL=$((FAIL+1)); }
  # (2) THE ROW FORMAT (`<pr>:<head-sha>:<head-ref>`). The head REF is what makes the live predicate
  # answerable, and the marker key is (pr, head). Both are driven here against the SHIPPED parser.
  printf '7:aaaaaaaaaaaaaaaaaaaa:fix/7-thing 8:bbbbbbbbbbbbbbbbbbbb:fix/8-thing\n' > "$PO/state/last-open-prs"
  # ⛔ THE 3-FIELD ROW: `needsfix-<pr>-<head>` must still match when the row carries a third field.
  # Parsed as `sha="<head>:<ref>"` the marker never matches, so EVERY PR reads unowned and the gate's
  # input is inflated — measured in review.
  : > "$PO/state/needsfix-8-bbbbbbbbbbbbbbbbbbbb"
  # ⛔ AND A MARKER IS NOT OWNERSHIP (the whole change): the 3-field row must PARSE, and the marker
  # must still leave the PR un-owned — a marker authorises a spawn, it does not prove one ran.
  eqv "a 3-FIELD row parses and its findings MARKER alone does not own it (both unowned)" "2" "$(_probe unowned_pr_count 2)"
  rm -f "$PO/state/needsfix-8-bbbbbbbbbbbbbbbbbbbb"
  # …and the HEAD REF alone owns a PR whose branch a live process holds (the whole change): the
  # fixture's live table stands in for the process, as in the ownership section above.
  printf 'fix/7-thing\t/repo/.worktrees/x\t1234\t/repo/.worktrees/x\n' > "$PO/state/live.tsv"
  eqv "a 3-FIELD row whose HEAD REF is held by a live process reads OWNED" "1" \
      "$( ( O="$PO"; LO_SCAN=1; LO_LIVE="$PO/state/live.tsv"; . "$TMP/pr_all.sh"; . "$LO"; unowned_pr_count 2 ) )"
  rm -f "$PO/state/live.tsv"
  # ⛔ THE OLDER-ROW TOLERANCE IS KEPT, RE-POINTED: a 2-field row has no branch, so only the local
  # arms can own it — it must parse, never crash and never invent a branch.
  printf '9:cccccccccccccccccccc\n' > "$PO/state/last-open-prs"
  eqv "a 2-FIELD (older-format) row is tolerated (no branch -> both unowned)" "1" "$(_probe unowned_pr_count 1)"
  printf '%s\n' "9" > "$PO/state/last-open-prs"
  eqv "a 1-FIELD row is tolerated too (no crash)" "1" "$(_probe unowned_pr_count 1)"
else
  echo "  FAIL the probe functions did not extract to syntactically valid shell"; FAIL=$((FAIL+1))
fi

echo
echo "=== the dispatch funnel: decomposes, bounds its record's age, and never fabricates ==="
ex dispatch_funnel > "$TMP/fn_dispatch_funnel.sh"
if bash -n "$TMP/fn_dispatch_funnel.sh" 2>/dev/null; then
  FO="$TMP/funnelO"; mkdir -p "$FO/state"
  _funnel() { ( O="$FO"; FUNNEL_MAX_AGE_MIN=30; . "$TMP/fn_dispatch_funnel.sh"; dispatch_funnel "$@" ); }
  # (1) NO record: says UNRECORDED, never "backlog empty" and never a decomposition it lacks.
  out="$(_funnel 0 "READ(223)(9m)" "" 1000000000)"
  case "$out" in *UNRECORDED*) echo "  ok a missing funnel record reads UNRECORDED, not as an empty funnel"; PASS=$((PASS+1)) ;;
    *) echo "  FAIL a missing record produced: $out"; FAIL=$((FAIL+1)) ;; esac
  case "$out" in "[dispatch] [dispatch]"*) echo "  FAIL the line carries the [dispatch] prefix twice"; FAIL=$((FAIL+1)) ;;
    "[dispatch] "*) echo "  ok exactly one [dispatch] prefix (the call sites no longer add their own)"; PASS=$((PASS+1)) ;;
    *) echo "  FAIL the line is not prefixed [dispatch]: $out"; FAIL=$((FAIL+1)) ;; esac
  # (2) a REAL record decomposes: listed -> per-reason counts -> dispatched, and names the held gate.
  printf 'listed=223 judged=6 queued=0 collision=0 landed=0 unjudged=6 skipped_checked=0 skipped_dispatched=0 not_reached=217 limit=6 reconciled=1 at=%s\n' 1000000000 > "$FO/state/refresh-funnel"
  printf '1\n2\n3\n' > "$FO/candidates.txt"
  out="$(_funnel 2 "READ(223)(9m)" "load=9>=max_load=8" 1000000000)"
  case "$out" in
    "[dispatch] 223 candidates -> 0 queued, 0 peer-owned (claim), 0 already landed, 6 unjudged (pre-flight), 0 blacklisted (checked), 0 already dispatched, 217 not reached (limit) -> 2 dispatched | held: load=9>=max_load=8"*)
      echo "  ok the funnel decomposes the pool and names the held gate"; PASS=$((PASS+1)) ;;
    *) echo "  FAIL unexpected funnel line: $out"; FAIL=$((FAIL+1)) ;;
  esac
  # (3) an UNRECONCILED record is labelled, never rendered as a clean decomposition.
  printf 'listed=223 judged=6 queued=1 collision=0 landed=0 unjudged=1 skipped_checked=0 skipped_dispatched=0 not_reached=217 limit=6 reconciled=0 at=%s\n' 1000000000 > "$FO/state/refresh-funnel"
  case "$(_funnel 0 "READ(223)" "" 1000000000)" in *UNRECONCILED*) echo "  ok a record whose parts do not sum is labelled UNRECONCILED"; PASS=$((PASS+1)) ;;
    *) echo "  FAIL an unreconciled record was rendered as clean"; FAIL=$((FAIL+1)) ;; esac
  # (4) AGE-BOUNDED: an old record is REPLACED by its age, never presented as this cycle's numbers.
  printf 'listed=223 judged=6 queued=0 collision=0 landed=0 unjudged=6 skipped_checked=0 skipped_dispatched=0 not_reached=217 limit=6 reconciled=1 at=%s\n' $(( 1000000000 - 3600 )) > "$FO/state/refresh-funnel"
  out="$(_funnel 0 "READ(223)")"
  case "$out" in *STALE*) echo "  ok a stale funnel record reads STALE(<age>), not as a fresh decomposition"; PASS=$((PASS+1)) ;;
    *) echo "  FAIL a one-hour-old record printed as this cycle's: $out"; FAIL=$((FAIL+1)) ;; esac
  # (5) A record with NO age field is not "fresh" either — unverifiable is STALE (review round 5).
  printf 'listed=223 judged=6 queued=0 collision=0 landed=0 unjudged=6 skipped_checked=0 skipped_dispatched=0 not_reached=217 limit=6 reconciled=1\n' > "$FO/state/refresh-funnel"
  out="$(_funnel 0 "READ(223)")"
  case "$out" in *"STALE(age unknown"*) echo "  ok a record with no usable at= reads STALE(age unknown)"; PASS=$((PASS+1)) ;;
    *) echo "  FAIL a record with no at= printed as this cycle's: $out"; FAIL=$((FAIL+1)) ;; esac
  # (6) …and a FUTURE at= (a clock step-back) is unverifiable too, never "0m old".
  printf 'listed=223 judged=6 queued=0 collision=0 landed=0 unjudged=6 skipped_checked=0 skipped_dispatched=0 not_reached=217 limit=6 reconciled=1 at=%s\n' 1000009999 > "$FO/state/refresh-funnel"
  out="$(_funnel 0 "READ(223)" "" 1000000000)"
  case "$out" in *"STALE(age unknown"*) echo "  ok a FUTURE at= is unverifiable (STALE), not a fresh 0m-old decomposition"; PASS=$((PASS+1)) ;;
    *) echo "  FAIL a future at= was read as fresh: $out"; FAIL=$((FAIL+1)) ;; esac
  # (7) ABSENT reconciled= is not "reconciled" — only a writer that recorded 1 has shown the sum.
  printf 'listed=223 judged=6 queued=0 collision=0 landed=0 unjudged=6 skipped_checked=0 skipped_dispatched=0 not_reached=217 limit=6 at=%s\n' 1000000000 > "$FO/state/refresh-funnel"
  out="$(_funnel 0 "READ(223)" "" 1000000000)"
  case "$out" in *UNRECONCILED*) echo "  ok a record with no reconciled= field is UNRECONCILED (unverified, not clean)"; PASS=$((PASS+1)) ;;
    *) echo "  FAIL a record with no reconciliation was rendered as clean: $out"; FAIL=$((FAIL+1)) ;; esac
  # (8) an EXISTING but empty record is UNRECORDED(unreadable), not "no pass has recorded one yet".
  : > "$FO/state/refresh-funnel"
  out="$(_funnel 0 "READ(223)" "" 1000000000)"
  case "$out" in *"exists but is unreadable"*) echo "  ok an empty record is reported as unreadable, not as 'no pass yet'"; PASS=$((PASS+1)) ;;
    *) echo "  FAIL an empty record produced: $out"; FAIL=$((FAIL+1)) ;; esac
else
  echo "  FAIL dispatch_funnel did not extract to syntactically valid shell"; FAIL=$((FAIL+1))
fi

echo
echo "=== #2132: a head nobody reviewed is NEEDS-REVIEW, never a fixer authorisation ==="
# ⛔ THE PRODUCER AND THE CONSUMER ARE EXTRACTED FROM THE LIVE SCRIPTS (merge-one.sh writes the
# state, orch-loop.sh acts on it), never copied here — a copy would keep passing after the shipped
# pair drifted apart, which is the defect this section exists to catch. Both are DRIVEN, because a
# grep cannot tell a live arm from one neutered to `if false` (the inert-enforcer class).
{
  grep -m1 '^is_limit() {' "$MERGE"
  grep -m1 '^is_num() {' "$MERGE"
  awk '/^verdict_class\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$MERGE"
  awk '/^review_state_record\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$MERGE"
  awk '/^review_state_clear\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$MERGE"
} > "$TMP/reviewstate.sh"
ex review_gate_state > "$TMP/fn_review_gate_state.sh"
# ⛔ NON-EMPTY AND DEFINED, not merely `bash -n`-clean (P2, first review round): `bash -n` on an EMPTY
# file exits 0, so a renamed/moved function extracted to nothing and the whole section its `&&` guard
# then SKIPPED its assertions — a suite that passes by testing nothing, the same false-PASS shape this
# file's own drifts guards exist for. The definition greps make the extraction falsifiable.
_rs_sz="$(wc -c < "$TMP/reviewstate.sh" | tr -d ' ')"; _rgs_sz="$(wc -c < "$TMP/fn_review_gate_state.sh" | tr -d ' ')"
if [ "${_rs_sz:-0}" -gt 0 ] && [ "${_rgs_sz:-0}" -gt 0 ] \
   && grep -q '^verdict_class() {' "$TMP/reviewstate.sh" \
   && grep -q '^review_state_record() {' "$TMP/reviewstate.sh" \
   && grep -q '^review_state_clear() {' "$TMP/reviewstate.sh" \
   && grep -q '^review_gate_state() {' "$TMP/fn_review_gate_state.sh" \
   && bash -n "$TMP/reviewstate.sh" 2>/dev/null && bash -n "$TMP/fn_review_gate_state.sh" 2>/dev/null; then
  RS="$TMP/rso"; mkdir -p "$RS/state"
  _vc() { ( . "$TMP/reviewstate.sh"; verdict_class "$1" ); }
  # _rs <class> <head> [max] — drive the PRODUCER exactly as merge-one.sh's `*)` arm calls it. The
  # park stub mirrors the REAL park() in merge-one.sh (which writes `parked-<PR>` = the head plus the
  # reason): a stub that wrote only the reason would let a park pass here and land nowhere in
  # production, which is the inert-enforcer shape this section exists to catch.
  _rs() {
    ( O="$RS"; L="$RS/merge.log"; PR=2132; HEAD="$2"; MAX_REVIEW_TRIES="${3:-3}"
      park() { printf '%s\n' "$*" > "$RS/parkreason"; [ -n "${HEAD:-}" ] && printf '%s\n' "$HEAD" > "$RS/state/parked-$PR"; }
      . "$TMP/reviewstate.sh"; review_state_record "$1" )
  }
  # _rgs <pr> <head> — drive the CONSUMER's classifier against the same state dir.
  _rgs() { ( O="$RS"; . "$TMP/fn_review_gate_state.sh"; review_gate_state "$1" "$2" ); }
  # _rc <head> — drive the CLEAR path (verified evidence) against the same state dir.
  _rc() { ( O="$RS"; L="$RS/merge.log"; PR=2132; HEAD="$1"; . "$TMP/reviewstate.sh"; review_state_clear ); }
  _clean() { rm -f "$RS"/state/needsfix-* "$RS"/state/needsreview-* "$RS"/state/parked-* "$RS"/state/reviewcount-* "$RS/parkreason"; : > "$RS/merge.log"; }

  eqv "an ISSUES verdict is a FIXER state" "ISSUES" "$(_vc 'ISSUES 3')"
  eqv "a CLEAN verdict keeps its own class" "CLEAN" "$(_vc 'CLEAN https://github.com/o/r/pull/1#issuecomment-9')"
  eqv "an EMPTY final line is NO-VERDICT, not ISSUES" "NO-VERDICT" "$(_vc '')"
  eqv "an unparseable final line is NO-VERDICT too" "NO-VERDICT" "$(_vc 'I read it and I think it is fine')"
  # ⛔ THE COUNT IS PART OF THE VERDICT (review round 3, P3). `ISSUES 0` is a reviewer saying they
  # found NOTHING — the pre-fix prefix match turned it into a fixer authorisation, spending a
  # MAX_FIX_TRIES attempt on a head with nothing to fix. A bare `ISSUES` is unparseable, and a
  # 10-digit count must not reach `-ge` (it errs FALSE on bash 3.2).
  eqv "ISSUES 0 is NO-VERDICT (nothing to fix, so no fixer)" "NO-VERDICT" "$(_vc 'ISSUES 0')"
  eqv "a bare ISSUES with no count is NO-VERDICT" "NO-VERDICT" "$(_vc 'ISSUES')"
  eqv "a two-digit count is still ISSUES" "ISSUES" "$(_vc 'ISSUES 12')"
  # ⛔ A SEPARATOR BEFORE THE COUNT IS A FORMAT VARIANT, NOT AN ABSENCE (review round 7, P3).
  eqv "ISSUES: 3 is a verdict with findings" "ISSUES" "$(_vc 'ISSUES: 3')"
  eqv "ISSUES - 2 is a verdict with findings" "ISSUES" "$(_vc 'ISSUES - 2')"
  eqv "an absurd count is NO-VERDICT (no arithmetic on an unbounded value)" "NO-VERDICT" "$(_vc 'ISSUES 9999999999999')"

  # ⛔ THE EXTRACTOR IS TAKEN FROM THE SHIPPED SCRIPT AND EVALUATED — NOT RE-TYPED (review round 8,
  # P2). The first form re-typed the pattern here, so reverting merge-one.sh's expression left the
  # whole suite green: a pin over a COPY, the exact false PASS the round-8 finding was about. This
  # evaluates the producer's own `LAST=` line, so the two cannot drift apart again.
  if grep -q '^LAST="$(grep -aE' "$MERGE"; then
    _last_of() {
      ( L="$TMP/extract"; printf '%s\n' "$1" > "$TMP/extract.log"
        eval "$(grep -m1 '^LAST="$(grep -aE' "$MERGE")"
        printf '%s' "${LAST:-}" )
    }
  else
    _last_of() { printf '%s' ''; }
  fi
  eqv "the shipped verdict extractor accepts ISSUES 3" "ISSUES 3" "$(_last_of 'ISSUES 3')"
  eqv "…accepts ISSUES: 3" "ISSUES: 3" "$(_last_of 'ISSUES: 3')"
  eqv "…accepts ISSUES - 2" "ISSUES - 2" "$(_last_of 'ISSUES - 2')"
  eqv "…accepts a CLEAN line with its URL" "CLEAN https://github.com/o/r/pull/1#issuecomment-9" "$(_last_of 'CLEAN https://github.com/o/r/pull/1#issuecomment-9')"
  eqv "…ignores earlier noise and takes the LAST verdict" "ISSUES 2" "$(_last_of 'ISSUES 5
noise
ISSUES 2')"
  eqv "…and an ISSUES: 3 line now CLASSIFIES as findings (the two halves agree)" "ISSUES" "$(_vc "$(_last_of 'ISSUES: 3')")"
  # (1) CONTROL: findings at a head authorise a fixer and write NO stale-evidence marker.
  _clean; _rs ISSUES aaaa1111
  done_issues=1
  [ -f "$RS/state/needsfix-2132-aaaa1111" ] && [ ! -f "$RS/state/needsreview-2132-aaaa1111" ] || done_issues=0
  [ "$done_issues" = "1" ] \
    && { echo "  ✅ a reviewer's FINDINGS record the fixer marker (and no stale-evidence marker)"; PASS=$((PASS+1)); } \
    || { echo "  ❌ ISSUES did not leave exactly the fixer marker — fixer=$( [ -f "$RS/state/needsfix-2132-aaaa1111" ] && echo yes || echo no) needsreview=$( [ -f "$RS/state/needsreview-2132-aaaa1111" ] && echo yes || echo no)"; FAIL=$((FAIL+1)); }
  eqv "…and the controller classifies that head NEEDS-FIX" "NEEDS-FIX" "$(_rgs 2132 aaaa1111)"

  # (2) THE DEFECT (#2132): a reviewer that produced NO verdict left a FIXER marker, so the
  # controller spent a MAX_FIX_TRIES attempt on a head nobody had reviewed — the fixer pushed, the
  # push invalidated the signed review by design, and the PR could never converge. The remedy for a
  # no-verdict head is another REVIEW; it must never authorise a fixer.
  _clean; _rs NO-VERDICT bbbb2222
  if [ -f "$RS/state/needsreview-2132-bbbb2222" ] && [ ! -f "$RS/state/needsfix-2132-bbbb2222" ]; then
    echo "  ✅ a reviewer that produced NO verdict records stale evidence — NOT a fixer authorisation"; PASS=$((PASS+1))
  else
    echo "  ❌ a no-verdict head wrote the FIXER marker (needsfix=$( [ -f "$RS/state/needsfix-2132-bbbb2222" ] && echo yes || echo no), needsreview=$( [ -f "$RS/state/needsreview-2132-bbbb2222" ] && echo yes || echo no)) — the controller would burn fixer attempts on an unreviewed head"; FAIL=$((FAIL+1))
  fi
  eqv "…and the controller classifies that head NEEDS-REVIEW" "NEEDS-REVIEW" "$(_rgs 2132 bbbb2222)"
  # (3) INERT-BY-ABSENCE: with no marker at all the controller must NOT authorise a fixer. "Nothing
  # says findings exist" is not "findings exist", and the fail-closed direction is the re-review.
  eqv "no marker at all reads NEEDS-REVIEW (fail-closed, never a fixer)" "NEEDS-REVIEW" "$(_rgs 2132 cccc3333)"
  # (4) BOUNDED: a reviewer that never returns a verdict must not buy an unbounded run of PAID
  # reviews (the #1717 class, one input over). The count is per HEAD, so a push re-arms it.
  _clean; _rs NO-VERDICT dddd4444; _rs NO-VERDICT dddd4444
  [ -f "$RS/state/needsreview-2132-dddd4444" ] && [ ! -f "$RS/state/parked-2132" ] \
    && { echo "  ✅ a second no-verdict at the SAME head is still a re-review, not yet a park"; PASS=$((PASS+1)); } \
    || { echo "  ❌ the re-review loop did not survive its second attempt at one head (parked=$( [ -f "$RS/state/parked-2132" ] && echo yes || echo no))"; FAIL=$((FAIL+1)); }
  _rs NO-VERDICT dddd4444
  if [ "$(cat "$RS/state/parked-2132" 2>/dev/null)" = "dddd4444" ] && [ ! -f "$RS/state/needsreview-2132-dddd4444" ] \
     && grep -qi 'no usable verdict' "$RS/parkreason" 2>/dev/null; then
    echo "  ✅ MAX_REVIEW_TRIES PARKS the head — bounded, with a reason naming that NOTHING was reviewed"; PASS=$((PASS+1))
  else
    echo "  ❌ the no-verdict loop is UNBOUNDED (parked=[$(cat "$RS/state/parked-2132" 2>/dev/null)] marker=$( [ -f "$RS/state/needsreview-2132-dddd4444" ] && echo yes || echo no) reason=[$(cat "$RS/parkreason" 2>/dev/null | cut -c1-60)])"; FAIL=$((FAIL+1))
  fi
  # (5) …and the bound belongs to the HEAD: a new push retries instead of inheriting the cap.
  _rs NO-VERDICT eeee5555
  [ -f "$RS/state/needsreview-2132-eeee5555" ] \
    && { echo "  ✅ a NEW head re-arms the re-review budget (it does not inherit the previous head's cap)"; PASS=$((PASS+1)); } \
    || { echo "  ❌ a new head inherited the old head's re-review count and was parked without an attempt"; FAIL=$((FAIL+1)); }
  # (5b) ⛔ A PARK MUST NOT LEAVE SUPERSEEDED MARKERS BEHIND (review round 5, P2). The park branch used
  # to remove only the marker AT the parked head, so residue at another head was counted by report.sh
  # as "stalled on evidence" while the SAME PR was also counted by the parked line — one PR, two
  # queues, two remedies. MAX_REVIEW_TRIES=1 makes the first run park; the earlier marker must be gone.
  _clean; _rs NO-VERDICT 1111aaaa; _rs NO-VERDICT 2222bbbb 1
  _residue="$(ls "$RS/state/" | grep '^needsreview-2132-' || true)"
  if [ "$(cat "$RS/state/parked-2132" 2>/dev/null)" = "2222bbbb" ] && [ -z "$_residue" ]; then
    echo "  ✅ a PARK removes the PR's whole marker set (no superseded-head residue left for report.sh to double-count)"; PASS=$((PASS+1))
  else
    echo "  ❌ the park left residue (parked=[$(cat "$RS/state/parked-2132" 2>/dev/null)] markers=[${_residue:-none}])"; FAIL=$((FAIL+1))
  fi
  # (5b) ⛔ A USABLE VERDICT RESETS THE VERDICT-LESS COUNTER (review round 10, P2). The counter bounds
  # CONSECUTIVE verdict-less runs; without a reset, N-1 timeouts followed by a verified CLEAN (or by
  # findings) still parked the head on the next timeout, with a reason claiming nothing had been
  # reviewed at a head that had been. Both resets are driven.
  _clean; _rs NO-VERDICT 9999aaaa; _rs NO-VERDICT 9999aaaa; _rc 9999aaaa
  _rs NO-VERDICT 9999aaaa
  if [ ! -f "$RS/state/parked-2132" ] && [ "$(cat "$RS/state/reviewcount-2132" 2>/dev/null | awk '{print $2}')" = "1" ]; then
    echo "  ✅ a verified CLEAN resets the verdict-less counter (one timeout after it does not park)"; PASS=$((PASS+1))
  else
    echo "  ❌ the counter survived a verified CLEAN (parked=$(cat "$RS/state/parked-2132" 2>/dev/null) count=$(cat "$RS/state/reviewcount-2132" 2>/dev/null))"; FAIL=$((FAIL+1))
  fi
  _clean; _rs NO-VERDICT 7777bbbb; _rs NO-VERDICT 7777bbbb; _rs ISSUES 7777bbbb
  rm -f "$RS/state/needsfix-2132-7777bbbb"; : > "$RS/state/fixspend-2132-7777bbbb"
  _rs NO-VERDICT 7777bbbb
  if [ ! -f "$RS/state/parked-2132" ] && [ "$(cat "$RS/state/reviewcount-2132" 2>/dev/null | awk '{print $2}')" = "1" ]; then
    echo "  ✅ a FINDINGS verdict resets it too (a fixer is the remedy, not a park)"; PASS=$((PASS+1))
  else
    echo "  ❌ the counter survived a findings verdict (parked=$(cat "$RS/state/parked-2132" 2>/dev/null) count=$(cat "$RS/state/reviewcount-2132" 2>/dev/null))"; FAIL=$((FAIL+1))
  fi
  # (6) WIRING: the `*)` arm must USE the classifier, and the controller's dispatch must read the
  # STATE — a helper nothing calls would leave both scripts exactly as broken as before.
  awk '/^  \*\)$/{f=1} f&&/^    ;;$/{print;exit} f' "$MERGE" > "$TMP/merge_star_arm.sh"
  awk '/^  CLEAN\*\)$/{f=1} f&&/^    ;;$/{print;exit} f' "$MERGE" > "$TMP/merge_clean_arm.sh"
  if grep -qF 'review_state_record "$(verdict_class "$LAST")"' "$TMP/merge_star_arm.sh" \
     && ! grep -qF 'touch "$O/state/needsfix-$PR-$HEAD"' "$TMP/merge_star_arm.sh"; then
    echo "  ✅ merge-one.sh's verdict arm routes through the classifier (no unconditional fixer marker)"; PASS=$((PASS+1))
  else
    echo "  ❌ merge-one.sh's verdict arm does not route through the classifier, or still writes the fixer marker unconditionally"; FAIL=$((FAIL+1))
  fi
  # (7) ⛔ THE CLEAR ARM (#2132 Required item 4): a COMPLETED review at the new head clears the
  # state. Without this assertion the clear sites could be deleted outright and the suite stayed
  # green — i.e. the half of the requirement that makes the state temporary was untested.
  _clean; _rs NO-VERDICT ffff6666
  _marker_before=$([ -f "$RS/state/needsreview-2132-ffff6666" ] && echo yes || echo no)
  # ⛔ AND A FINDINGS MARKER AT THAT HEAD MUST GO TOO (review round 6, P2): a CLEAN verdict with a
  # verified marker is the LATEST verdict at the head, and `review_gate_state()` reads only `needsfix`,
  # so a leftover findings marker authorised a fixer for a head just reviewed CLEAN.
  : > "$RS/state/needsfix-2132-ffff6666"
  _rc ffff6666
  if [ "$_marker_before" = "yes" ] && [ ! -e "$RS/state/needsreview-2132-ffff6666" ] \
     && [ ! -e "$RS/state/needsfix-2132-ffff6666" ] \
     && [ "$(_rgs 2132 ffff6666)" = "NEEDS-REVIEW" ]; then
    echo "  ✅ verified evidence CLEARS the stale-evidence AND the findings state at that head (the head stops authorising a fixer)"; PASS=$((PASS+1))
  else
    echo "  ❌ the clear path left state behind (needsreview=$([ -e "$RS/state/needsreview-2132-ffff6666" ] && echo yes || echo no) needsfix=$([ -e "$RS/state/needsfix-2132-ffff6666" ] && echo yes || echo no) class=$(_rgs 2132 ffff6666))"; FAIL=$((FAIL+1))
  fi
  # (7c2) ⛔ THE SPEND RECORD DIES WITH THE CLEAR (review round 7, P2): it exists only to authorise
  # `refund_bailed_fixer` restoring the findings state at that head, so keeping it let a later bail at
  # the same head MINT a `needsfix` marker at a head with a signed CLEAN marker.
  _clean; : > "$RS/state/needsreview-2132-5555dddd"; : > "$RS/state/fixspend-2132-5555dddd"
  _rc 5555dddd
  if [ ! -e "$RS/state/fixspend-2132-5555dddd" ]; then
    echo "  ✅ the clear also consumes the spend record (a later bail cannot mint findings at a CLEAN head)"; PASS=$((PASS+1))
  else
    echo "  ❌ the spend record survived the clear — a later bail would restore a findings marker at a head with a signed CLEAN verdict"; FAIL=$((FAIL+1))
  fi
  # (7c) ⛔ A VERDICT-LESS RUN MUST NOT SUPERSEDE FINDINGS AT THE SAME HEAD (review round 6, P3):
  # nothing was pushed, so it carries no information about the head — and the old code deleted the
  # findings marker and then parked with a reason claiming nothing had been reviewed.
  _clean; _rs ISSUES 3333cccc; _rs NO-VERDICT 3333cccc; _rs NO-VERDICT 3333cccc; _rs NO-VERDICT 3333cccc
  if [ -f "$RS/state/needsfix-2132-3333cccc" ] && [ ! -f "$RS/state/parked-2132" ] \
     && [ "$(_rgs 2132 3333cccc)" = "NEEDS-FIX" ]; then
    echo "  ✅ a no-verdict run at a head that already has FINDINGS keeps NEEDS-FIX (and spends no re-review budget)"; PASS=$((PASS+1))
  else
    echo "  ❌ no-verdict runs erased the findings state at the same head (needsfix=$([ -f "$RS/state/needsfix-2132-3333cccc" ] && echo yes || echo no) parked=$(cat "$RS/state/parked-2132" 2>/dev/null) class=$(_rgs 2132 3333cccc))"; FAIL=$((FAIL+1))
  fi
  # (7b) …and the clear is CALLED, and only AFTER the signed marker verified: a clear above the
  # `marker_ok` guard would let a bare rc=0 (record-review ran but posted no verifiable marker) read
  # as a satisfied head and erase the evidence queue's only record of it.
  _guard_ln="$(grep -n 'if \[ "$marker_ok" -ne 1 \]' "$MERGE" | head -1 | cut -d: -f1)"
  _clear_ln="$(grep -n '^    review_state_clear$' "$MERGE" | head -1 | cut -d: -f1)"
  # ⛔ IF, NOT CASE (review round 2, P2). The first form was `case "x:y" in ''*|*:'' )`, and inside a
  # `case` PATTERN the quotes are stripped — `''*` IS `*`, which matched every value, so the failure
  # arm always ran: a permanent red over a correct tree, and a real ordering regression would print
  # the same line. Two explicit emptiness tests are the only way to say "either anchor is missing".
  # ⛔ AND ARM MEMBERSHIP IS PART OF THE CONTRACT (review round 4, P2). Line order alone accepts the
  # call ANYWHERE below the guard — including the `*)` arm, where every no-verdict run would delete
  # the marker it just wrote and a verified review would clear nothing, with the suite green. The
  # clear must be in the CLEAN arm and absent from the no-verdict arm; both arms are extracted above
  # from the shipped file, so this cannot be satisfied by a copy.
  if [ -z "${_guard_ln:-}" ] || [ -z "${_clear_ln:-}" ]; then
    echo "  ❌ could not locate the marker_ok guard and the review_state_clear call site in merge-one.sh"; FAIL=$((FAIL+1))
  elif [ "${_clear_ln}" -le "${_guard_ln}" ]; then
    echo "  ❌ the clear is invoked at line $_clear_ln, not after the marker_ok guard at line $_guard_ln — an unverified record would read as a clean head"; FAIL=$((FAIL+1))
  elif ! grep -q '^    review_state_clear$' "$TMP/merge_clean_arm.sh"; then
    echo "  ❌ review_state_clear is NOT in the CLEAN arm — a verified review would clear nothing"; FAIL=$((FAIL+1))
  elif grep -q '^    review_state_clear$' "$TMP/merge_star_arm.sh"; then
    echo "  ❌ review_state_clear is in the NO-VERDICT arm — every no-verdict run would delete the marker it just wrote"; FAIL=$((FAIL+1))
  else
    echo "  ✅ the clear is in the CLEAN arm, ABSENT from the no-verdict arm, and reached only AFTER the marker verifies (line $_clear_ln > guard $_guard_ln)"; PASS=$((PASS+1))
  fi
  # (8) ⛔ NO ACCUMULATION (#2132 review round 1, P2): the marker set describes NOW. One marker per
  # PR — a head that advances must not leave the previous head's marker behind for report.sh to
  # count, or the published number could never fall back to 0.
  _clean; _rs NO-VERDICT 1111aaaa; _rs NO-VERDICT 2222bbbb
  _old=$([ -f "$RS/state/needsreview-2132-1111aaaa" ] && echo yes || echo no)
  _new=$([ -f "$RS/state/needsreview-2132-2222bbbb" ] && echo yes || echo no)
  if [ "$_old" = "no" ] && [ "$_new" = "yes" ]; then
    echo "  ✅ a new head REPLACES the previous head's stale-evidence marker (the set cannot only grow)"; PASS=$((PASS+1))
  else
    echo "  ❌ stale-evidence markers accumulate: old-head marker=$_old, current-head marker=$_new"; FAIL=$((FAIL+1))
  fi
  # (8b) ⛔ THE FINDINGS POPULATION IS ONE PER PR TOO (review rounds 7-9). A PR that collects findings
  # at several heads used to keep a marker for every head for its whole life — inert (both readers are
  # head-keyed) but an untested claim until here, and a state directory that only grows. Both writers of
  # an old head now prune: the ISSUES verdict and a NO-VERDICT run at a NEW head (which must keep the
  # same-head marker, so it prunes only after its early return).
  _clean; _rs ISSUES 3333dddd; _rs ISSUES 4444eeee
  _nf="$(ls "$RS/state/" 2>/dev/null | grep -c '^needsfix-2132-' || true)"
  if [ "$_nf" = "1" ] && [ -f "$RS/state/needsfix-2132-4444eeee" ] && [ ! -e "$RS/state/needsfix-2132-3333dddd" ]; then
    echo "  ✅ a new head REPLACES the previous head's FINDINGS marker (one marker per PR)"; PASS=$((PASS+1))
  else
    echo "  ❌ findings markers accumulate (count=$_nf kept=$(ls "$RS/state" | tr '\n' ' '))"; FAIL=$((FAIL+1))
  fi
  _clean; _rs ISSUES 5555gggg; _rs NO-VERDICT 6666hhhh
  _nf2="$(ls "$RS/state/" 2>/dev/null | grep -c '^needsfix-2132-' || true)"
  if [ "$_nf2" = "0" ] && [ -f "$RS/state/needsreview-2132-6666hhhh" ]; then
    echo "  ✅ a NO-VERDICT run at a NEW head prunes the old head's FINDINGS marker (the two writers agree)"; PASS=$((PASS+1))
  else
    echo "  ❌ an old findings marker survived a no-verdict run at a new head (needsfix count=$_nf2)"; FAIL=$((FAIL+1))
  fi
  # (9) ⛔ AND THE PUBLISHED COUNT IS OPEN-PRs-ONLY (#2132 review round 1, P2). Driven against a real
  # report.sh run with a stub `gh`: two markers exist, only ONE belongs to an open PR, so the line must
  # read 1 — a raw file count would read 2 and could never return to the 0 indicator (b) asks for.
  RPT="$TMP/rpt"; mkdir -p "$RPT/state" "$RPT/repo" "$TMP/ghstub"
  # ⛔ TWO markers for the SAME open PR and one for a PR that is not open (review round 2, P2): a
  # file count would print 3, an open-PR-only count prints 2, and the correct per-PR count prints 1.
  # The controller used to be able to leave two markers for one PR; report.sh must not report that as
  # two stalls even if a peer box does it.
  : > "$RPT/state/needsreview-6001-aaa"; : > "$RPT/state/needsreview-6001-bbb"; : > "$RPT/state/needsreview-6999-ccc"
  cat > "$TMP/ghstub/gh" <<'GHOPEN'
#!/bin/bash
case "$*" in *"--state open"*) printf '6001:head1\n6002:head2\n' ;; esac
exit 0
GHOPEN
  chmod +x "$TMP/ghstub/gh"
  _rpt_line="$( O="$RPT" REPO="$RPT/repo" PATH="$TMP/ghstub:$PATH" bash "$REPORT" 2 2>/dev/null | grep 'stale evidence' )"
  eqv "report.sh counts STALLED PRs — open, and one per PR (not per marker file)" "  stale evidence (needs re-review): 1" "$_rpt_line"
  # (9b) …and an UNREADABLE open-PR list must not print a confident 0. A stub that FAILS the list
  # read stands in for a rate-limited or offline box.
  cat > "$TMP/ghstub/gh" <<'GHFAIL'
#!/bin/bash
exit 1
GHFAIL
  chmod +x "$TMP/ghstub/gh"
  _rpt_fail="$( O="$RPT" REPO="$RPT/repo" PATH="$TMP/ghstub:$PATH" bash "$REPORT" 2 2>/dev/null | grep 'stale evidence' )"
  case "$_rpt_fail" in
    *"could not read"*) echo "  ✅ an unreadable open-PR list prints <could not read> with the raw marker count, never a confident 0"; PASS=$((PASS+1)) ;;
    *) echo "  ❌ an unreadable open-PR list printed [$_rpt_fail] — a blind read must not read as a clean queue"; FAIL=$((FAIL+1)) ;;
  esac
  # (9c2) …and a marker whose PR is PARKED at that head belongs to the line above, not this one
  # (review round 3, P2): one PR in two queues with two different remedies is how an operator ends up
  # re-reviewing a PR that is waiting for a human. ⛔ Evaluated over the PR's WHOLE marker set (review
  # round 4, P3): checking only the first marker the glob visits let a superseded marker plus a marker
  # at the parked head be counted in BOTH queues.
  : > "$RPT/state/needsreview-6002-aaa"; : > "$RPT/state/needsreview-6002-ddd"
  printf '%s\n' ddd > "$RPT/state/parked-6002"
  cat > "$TMP/ghstub/gh" <<'GHOPEN2'
#!/bin/bash
case "$*" in *"--state open"*) printf '6001:head1\n6002:ddd\n' ;; esac
exit 0
GHOPEN2
  chmod +x "$TMP/ghstub/gh"
  _rpt_parked="$( O="$RPT" REPO="$RPT/repo" PATH="$TMP/ghstub:$PATH" bash "$REPORT" 2 2>/dev/null | grep 'stale evidence' )"
  eqv "…and a PR parked at ANY of its marked heads is counted as parked, not as stalled on evidence" "  stale evidence (needs re-review): 1" "$_rpt_parked"
  # (9c2b) ⛔ THE PARKED COUNT IS PINNED TOO (review round 7, P3 — the suite was blind to a
  # regression of exactly the attribution round 9 fixed: case b must read 1, not 0).
  eqv "a park at the LIVE head counts as parked" "1" "$(printf '%s\n' "$( O="$RPT" REPO="$RPT/repo" PATH="$TMP/ghstub:$PATH" bash "$REPORT" 2 2>/dev/null)" | sed -n 's/^  parked (needs a human): \([0-9][0-9]*\).*/\1/p' | head -1)"
  # (9c3) ⛔ AND THE PARKED LINE IS PRINTED EXACTLY ONCE (review round 7, P2): the superseded-park fix
  # left the raw echo above the adjusted one, so two contradictory numbers for one quantity appeared
  # in the same block — and NOTHING pinned that line, which is why the suite was green over it.
  # A park at a head no marker names is superseded (re-armed): counted under the parked line with its
  # own number, NOT as a stall.
  printf '%s\n' oldhead > "$RPT/state/parked-6002"
  # 6002 carries a marker at a NEW head while its park names an OLD one, so the PR is being worked;
  # 6001's markers are removed so the stale count isolates this case. The stub must report 6002's LIVE
  # head as `newhead` — the classification compares the park against the listed head (review round 7).
  rm -f "$RPT/state/needsreview-6001-aaa" "$RPT/state/needsreview-6001-bbb"
  : > "$RPT/state/needsreview-6002-newhead"
  cat > "$TMP/ghstub/gh" <<'GHOPEN3'
#!/bin/bash
case "$*" in *"--state open"*) printf '6001:head1\n6002:newhead\n' ;; esac
exit 0
GHOPEN3
  chmod +x "$TMP/ghstub/gh"
  _rpt_superseded="$( O="$RPT" REPO="$RPT/repo" PATH="$TMP/ghstub:$PATH" bash "$REPORT" 2 2>/dev/null )"
  eqv "the parked line is printed EXACTLY once" "1" "$(printf '%s\n' "$_rpt_superseded" | grep -c 'parked (needs a human)')"
  case "$_rpt_superseded" in
    *"parked (needs a human): 0 (1 at a superseded head"*)
      echo "  ✅ a park at a head no marker names is SUPERSEDED, not 'needs a human'"; PASS=$((PASS+1)) ;;
    *) echo "  ❌ the superseded park was not attributed correctly: [$(printf '%s\n' "$_rpt_superseded" | grep 'parked (needs' | tr '\n' '|')] stale=[$(printf '%s\n' "$_rpt_superseded" | grep 'stale evidence')]"; FAIL=$((FAIL+1)) ;;
  esac
  # ⛔ AND IT IS NOT COUNTED AS STALE EITHER (review round 10 final pass): the message claimed "the
  # stale count stays 0" while only the parked prefix was matched, so a regression that counted a
  # parked-at-one-head, marked-at-another PR in BOTH queues stayed green. Both lines are asserted now.
  eqv "…and a SUPERSEDED park is not counted as stale evidence" "  stale evidence (needs re-review): 0" "$(printf '%s\n' "$_rpt_superseded" | grep 'stale evidence')"
  rm -f "$RPT/state/parked-6002" "$RPT/state/needsreview-6002-newhead"
  rm -f "$RPT/state/parked-6002" "$RPT/state/needsreview-6002-aaa" "$RPT/state/needsreview-6002-ddd"
  # (9c) …and NO repo/gh at all is its OWN state, not 0 (review round 2, P1). The first form derived
  # the state from a flag only set inside the "repo AND gh present" arm, so a box without a checkout
  # printed `open PRs: 0` and `stale evidence: 0` — a blind read presented as a clean queue.
  _rpt_norepo="$( O="$RPT" REPO="$RPT/does-not-exist" bash "$REPORT" 2 2>/dev/null | grep -E 'open PRs|stale evidence' )"
  case "$_rpt_norepo" in
    *"open PRs: 0"*|*"stale evidence (needs re-review): 0"*) echo "  ❌ with no repo checkout report.sh printed a confident 0: [$_rpt_norepo]"; FAIL=$((FAIL+1)) ;;
    *"needs a repo checkout and gh"*) echo "  ✅ with no repo checkout both lines name the missing dependency instead of printing 0"; PASS=$((PASS+1)) ;;
    *) echo "  ❌ an unreadable environment produced [$_rpt_norepo] — expected the named missing dependency"; FAIL=$((FAIL+1)) ;;
  esac
  # (9c4) ⛔ AND ON THE DEGRADED PATHS THE PARKED COUNT NAMES ITS OWN PROVENANCE (landing-review note,
  # P3). Attribution needs the OPEN LISTING — it is the only source of a PR's live head — so with no
  # checkout, or with an unreadable listing, the number that gets printed is the raw `parked-*` FILE
  # count and a superseded park is indistinguishable from a current one. Printing it UNLABELLED
  # presents an inflated human queue as a measured one; the stale line on these same two paths already
  # names its degradation, so the parked line must too. Driven, not grepped: two parks exist, NEITHER
  # of which can be attributed on these paths (that is the whole reason the count is raw).
  printf '%s\n' livehead > "$RPT/state/parked-6001"
  printf '%s\n' oldhead > "$RPT/state/parked-6999"
  _rpt_norepo_parked="$( O="$RPT" REPO="$RPT/does-not-exist" bash "$REPORT" 2 2>/dev/null | grep 'parked (needs a human)' )"
  case "$_rpt_norepo_parked" in
    *" 2  (raw marker count"*) echo "  ✅ with no repo checkout the parked line KEEPS the count (2) and says it is RAW"; PASS=$((PASS+1)) ;;
    *) echo "  ❌ with no repo checkout the parked line printed [$_rpt_norepo_parked] — expected '2' plus a raw-provenance note"; FAIL=$((FAIL+1)) ;;
  esac
  cat > "$TMP/ghstub/gh" <<'GHFAIL2'
#!/bin/bash
exit 1
GHFAIL2
  chmod +x "$TMP/ghstub/gh"
  _rpt_unread_parked="$( O="$RPT" REPO="$RPT/repo" PATH="$TMP/ghstub:$PATH" bash "$REPORT" 2 2>/dev/null | grep 'parked (needs a human)' )"
  case "$_rpt_unread_parked" in
    *" 2  (raw marker count"*) echo "  ✅ with an unreadable open-PR list the parked line keeps the count (2) and says it is RAW too"; PASS=$((PASS+1)) ;;
    *) echo "  ❌ with an unreadable open-PR list the parked line printed [$_rpt_unread_parked] — expected '2' plus a raw-provenance note"; FAIL=$((FAIL+1)) ;;
  esac
  rm -f "$RPT/state/parked-6001" "$RPT/state/parked-6999"
  wpin "orch-loop.sh classifies the red gate before dispatching" "$ORCH" '_rgs="$(review_gate_state "$PR" "${HEAD_N:-}")"'
  wpin "…and authorises a fixer ONLY on NEEDS-FIX" "$ORCH" '[ "$_rgs" = "NEEDS-FIX" ]'
  # ⛔ ONE WRITER (review round 3, P2; widened round 4, P3): the controller must never WRITE the
  # stale-evidence state — it cannot see the review store, so a marker from there asserts a property
  # it cannot measure (it published the state for brand-new unreviewed PRs and for heads whose signed
  # marker had just verified). Pinning the `touch` IDIOM left `printf … > path`, `: > path` and `>>`
  # free to reintroduce it, so this pins the target PATH: every non-comment line in orch-loop.sh that
  # names `needsreview` must be an `rm -f` (a delete, which is allowed).
  _sr_bad="$(grep -nE '(touch|>>|>|:)[[:space:]]*"?\$O/state/needsreview|(cp|install|ln)[^;|&]*needsreview' "$ORCH" | grep -v '^[0-9]*: *#' || true)"
  if [ -n "$_sr_bad" ]; then
    echo "  ❌ orch-loop.sh WRITES needsreview state — the controller cannot see whether evidence exists, so that marker asserts an unmeasured property: [$(printf '%s' "$_sr_bad" | head -1)]"; FAIL=$((FAIL+1))
  else
    echo "  ✅ orch-loop.sh never writes the stale-evidence state (no write redirect/touch/copy targets it; merge-one.sh is the single writer)"; PASS=$((PASS+1))
  fi
  # (9d) ⛔ AND ON THE GREEN ARM THE EVIDENCE SWEEP IS AUTHORITY-GUARDED (review round 5, P1 — a
  # regression this branch introduced and this assertion now pins).
  # ⛔ POLARITY, NOT PRESENCE (review round 6, P3): the first form only asked whether the WORD
  # `MERGE_AUTHORITY` appeared on the line, so `= "rail"` (the inverse — deletes exactly where GREEN
  # does not imply evidence) and the `||` typo both passed. The exact form is pinned.
  awk '/^      GREEN\)$/{f=1} f&&/^        if \[ "\$MERGE_AUTHORITY" = "rail" \]/{exit} f' "$ORCH" > "$TMP/green_arm.sh"
  if ! grep -qF '[ "$MERGE_AUTHORITY" = "gate" ] && rm -f "$O/state/needsreview-$PR-"*' "$TMP/green_arm.sh"; then
    echo "  ❌ the GREEN arm's needsreview sweep is not the exact gate-authority form (inverted, \`||\`, or missing) — on a rail repo GREEN does not imply evidence, so any other polarity deletes a TRUE state"; FAIL=$((FAIL+1))
  else
    echo "  ✅ the GREEN arm's stale-evidence sweep is exactly the gate-authority form"; PASS=$((PASS+1))
  fi
  # (9d2) …and the prune is CALLED (review round 6, P3): the function is defined and driven by (12),
  # but deleting its one call site left every assertion green — an inert enforcer.
  wpin "the orphan prune is CALLED once per cycle, against the listing the cycle already read" "$ORCH" 'prune_orphan_markers "$OPEN_ROWS" "${_nrows:-0}"'
  # (10) ⛔ A BAIL MUST NOT MANUFACTURE A FINDINGS MARKER (review round 4, P3). `refund_bailed_fixer … 1`
  # used to `touch needsfix-*` unconditionally, so a bail written by the CI-red or CONFLICTING arm —
  # neither of which consumes a findings marker — refunded on a later gate-red cycle INVENTED one, and
  # since #2132 that marker is the sole fixer authorisation. The restore is now gated on
  # `fixspend-<PR>-<head>`, which only the consuming spawn writes. Driven, both ways.
  { grep -m1 '^is_num() {' "$ORCH"; ex refund_bailed_fixer; } > "$TMP/refund_fix.sh"
  if grep -q 'refund_bailed_fixer()' "$TMP/refund_fix.sh"; then
    RF="$TMP/rfx"; mkdir -p "$RF/state"
    _rf() { ( O="$RF"; LOG="$RF/log"; . "$TMP/refund_fix.sh"; refund_bailed_fixer 4242 cafe0001 "$1" ); }
    rm -f "$RF/state/"*; : > "$RF/state/fixbail-4242-cafe0001"; echo 2 > "$RF/state/fixcount-4242"
    _rf 1
    if [ -f "$RF/state/needsfix-4242-cafe0001" ]; then
      echo "  ❌ a bail with NO recorded spend still manufactured a findings marker"; FAIL=$((FAIL+1))
    else
      echo "  ✅ a bail that consumed no findings marker does NOT manufacture one"; PASS=$((PASS+1))
    fi
    rm -f "$RF/state/"*; : > "$RF/state/fixbail-4242-cafe0001"; : > "$RF/state/fixspend-4242-cafe0001"; echo 2 > "$RF/state/fixcount-4242"
    _rf 1
    if [ -f "$RF/state/needsfix-4242-cafe0001" ] && [ ! -f "$RF/state/fixspend-4242-cafe0001" ]; then
      echo "  ✅ …and a bail that DID consume one restores it, consuming the spend record"; PASS=$((PASS+1))
    else
      echo "  ❌ a bail with a recorded spend did not restore the findings marker (or left the spend record)"; FAIL=$((FAIL+1))
    fi
  else
    echo "  ❌ could not extract refund_bailed_fixer from orch-loop.sh"; FAIL=$((FAIL+1))
  fi
  # (11) ⛔ THE SPEND RECORD MUST BE WRITTEN BEFORE THE SPAWN (review round 5, residual 1).  # `fix-one.sh` starts concurrently inside the tmux session and can write `fixbail-*` in its first
  # milliseconds; `refund_bailed_fixer` then refuses a restore (no spend on record) and withholds the
  # findings marker — fail-closed, but one review paid for nothing. A comment cannot hold that order,
  # so the SOURCE order is pinned: the write is the first line of that arm, the spawn within 3 lines.
  _fs_w="$(grep -n '^ *: > "$O/state/fixspend-$PR-$HEAD_N"$' "$ORCH" | head -1 | cut -d: -f1)"
  _fs_s=""
  if [ -n "${_fs_w:-}" ]; then
    _fs_s="$(awk -v w="$_fs_w" 'NR>w && /if tmux new-session -d -s "fix-\$PR"/{print NR; exit}' "$ORCH")"
  fi
  if [ -z "${_fs_w:-}" ] || [ -z "${_fs_s:-}" ] || [ "$(( _fs_s - _fs_w ))" -gt 3 ]; then
    echo "  ❌ the fixspend record is not written immediately BEFORE the fixer spawn (write=${_fs_w:-<none>} spawn=${_fs_s:-<none>}) — a concurrent fix-one.sh can record its bail first and the findings marker is then withheld"; FAIL=$((FAIL+1))
  else
    echo "  ✅ the spend record is written BEFORE the spawn (write line $_fs_w, spawn line $_fs_s) — a concurrent bail cannot race it"; PASS=$((PASS+1))
  fi
  # (12) ⛔ THE ORPHAN PRUNE, DRIVEN (review round 5, residual 1 — it was unpinned and a future edit
  # that dropped the row-count guard would turn "unreadable listing" into "delete every marker").
  ex prune_orphan_markers > "$TMP/fn_prune_orphan.sh"
  if grep -q '^prune_orphan_markers() {' "$TMP/fn_prune_orphan.sh"; then
    PO="$TMP/pruneO"; mkdir -p "$PO/state"
    : > "$PO/state/needsreview-6001-aaa"; : > "$PO/state/needsreview-6999-bbb"; : > "$PO/state/fixspend-6001-ccc"
    # The listing is written AFTER these markers, so they are all older than it (the cycle boundary).
    sleep 1; : > "$PO/state/last-open-prs"
    ( O="$PO"; . "$TMP/fn_prune_orphan.sh"; prune_orphan_markers '6001:head1:br1' 1 )
    if [ -f "$PO/state/needsreview-6001-aaa" ] && [ -f "$PO/state/fixspend-6001-ccc" ] && [ ! -e "$PO/state/needsreview-6999-bbb" ]; then
      echo "  ✅ the orphan prune keeps an OPEN PR's markers and deletes a PR that left the listing"; PASS=$((PASS+1))
    else
      echo "  ❌ the orphan prune kept=$(ls "$PO/state" | tr '\n' ' ') — expected 6001's two markers kept and 6999 deleted"; FAIL=$((FAIL+1))
    fi
    # (12b) ⛔ A FAILED LISTING DELETES NOTHING. Two independent guards spare the markers when the
    # listing is absent — the explicit `-e last-open-prs` early return AND the `-ot` test (POSIX: `-ot`
    # against a missing file is FALSE, so every marker is skipped). This assertion pins the OUTCOME,
    # not which line produced it: an early return only optimises, and the outcome is what must hold.
    rm -f "$PO/state/last-open-prs"; : > "$PO/state/needsreview-6999-bbb"
    ( O="$PO"; . "$TMP/fn_prune_orphan.sh"; prune_orphan_markers '' 0 )
    if [ -f "$PO/state/needsreview-6999-bbb" ] && [ -f "$PO/state/needsreview-6001-aaa" ]; then
      echo "  ✅ …and a FAILED listing (no last-open-prs) deletes NOTHING — an unreadable read is not 'no PRs open'"; PASS=$((PASS+1))
    else
      echo "  ❌ a failed listing deleted markers (kept=$(ls "$PO/state" | tr '\n' ' ')) — a blind read would wipe the whole queue"; FAIL=$((FAIL+1))
    fi
    # (12c) ⛔ A MARKER WRITTEN AFTER THE LISTING MUST SURVIVE (review round 6, P3): the prune runs
    # hundreds of lines after the listing is read, so a marker for a PR that appeared in between (a
    # lane's brand-new PR via chain-merge.sh → merge-one.sh) is TRUE and the rows cannot contain it.
    # ⛔ THE LISTING MUST EXIST FOR THIS TO TEST ANYTHING (review round 8, P2): the first form wrote
    # `last-open-prs.keep`, so `prune_orphan_markers` returned at its missing-file guard and the `-ot`
    # freshness guard was never reached — deleting that guard left the suite green. The listing is
    # created AFTER the fresh marker now, and its inverse is driven too (an OLD marker absent from the
    # rows IS deleted).
    : > "$PO/state/last-open-prs"
    sleep 1; : > "$PO/state/needsreview-7777-late"
    ( O="$PO"; . "$TMP/fn_prune_orphan.sh"; prune_orphan_markers '6001:head1:br1' 1 )
    if [ -f "$PO/state/needsreview-7777-late" ]; then
      echo "  ✅ a marker written AFTER the listing is read survives the prune (the listing could not have seen it)"; PASS=$((PASS+1))
    else
      echo "  ❌ the prune deleted a marker newer than the listing — a same-cycle true state was lost"; FAIL=$((FAIL+1))
    fi
    # …and the inverse: an OLD marker for a PR absent from the rows IS removed, so the `-ot` guard is
    # doing the sparing in the case above rather than shielding everything.
    : > "$PO/state/needsreview-8888-old"; sleep 1; : > "$PO/state/last-open-prs"
    ( O="$PO"; . "$TMP/fn_prune_orphan.sh"; prune_orphan_markers '6001:head1:br1' 1 )
    if [ ! -e "$PO/state/needsreview-8888-old" ]; then
      echo "  ✅ …while an OLD marker for a PR absent from the rows IS deleted (the freshness guard is the one sparing markers)"; PASS=$((PASS+1))
    else
      echo "  ❌ an old orphan marker survived — the prune is shielding everything, not just same-cycle markers"; FAIL=$((FAIL+1))
    fi
    # (12f) ⛔ `needsfix-*` IS ORPHAN-PRUNED TOO (review round 9): it was the one marker family the glob
    # omitted, so a PR that closed out of band kept its findings marker for the life of `$O`.
    rm -f "$PO/state/"*; : > "$PO/state/needsfix-6999-eee"; sleep 1; : > "$PO/state/last-open-prs"
    ( O="$PO"; . "$TMP/fn_prune_orphan.sh"; prune_orphan_markers '6001:head1:br1' 1 )
    if [ ! -e "$PO/state/needsfix-6999-eee" ]; then
      echo "  ✅ the orphan prune also deletes a departed PR's FINDINGS marker"; PASS=$((PASS+1))
    else
      echo "  ❌ a departed PR's needsfix marker survived the prune (the family leaks)"; FAIL=$((FAIL+1))
    fi
    # (12g) …and a MALFORMED row count refuses to prune (fail closed, not "empty set").
    : > "$PO/state/needsreview-6999-fff"; sleep 1; : > "$PO/state/last-open-prs"
    ( O="$PO"; . "$TMP/fn_prune_orphan.sh"; prune_orphan_markers '' 'x1' )
    if [ -e "$PO/state/needsreview-6999-fff" ]; then
      echo "  ✅ a MALFORMED row count prunes nothing (garbage is not read as 'no open PRs')"; PASS=$((PASS+1))
    else
      echo "  ❌ a malformed row count deleted markers — garbage was coerced to the destructive reading"; FAIL=$((FAIL+1))
    fi
    # (12h) ⛔ A NAME OUTSIDE THE FAMILIES IS SPARED (review round 10 final pass): `sed` without `-n`
    # echoed every non-matching basename as if it were a PR id, so such a file was DELETED as an
    # orphan — a delete-direction bug in the one function that is supposed to fail closed.
    rm -f "$PO/state/"*; : > "$PO/state/needsfix-note.txt"; : > "$PO/state/reviewcount-6999"; sleep 1; : > "$PO/state/last-open-prs"
    ( O="$PO"; . "$TMP/fn_prune_orphan.sh"; prune_orphan_markers '' 0 )
    if [ -e "$PO/state/needsfix-note.txt" ] && [ ! -e "$PO/state/reviewcount-6999" ]; then
      echo "  ✅ a name outside the marker families is SPARED, while a departed PR's reviewcount IS pruned"; PASS=$((PASS+1))
    else
      echo "  ❌ the prune mis-handled names outside the families (note=$( [ -e "$PO/state/needsfix-note.txt" ] && echo kept || echo DELETED) reviewcount=$( [ -e "$PO/state/reviewcount-6999" ] && echo kept || echo deleted))"; FAIL=$((FAIL+1))
    fi
    # (12d) ⛔ AN EMPTY BUT SUCCESSFUL LISTING PRUNES (review round 7, P3): n=0 with `last-open-prs`
    # present means "this repo has no open PRs", where every marker is orphaned — the drained state.
    # (12e) …and a TRUNCATED listing (n at the 300-row cap) prunes NOTHING, because the rows may omit
    # open PRs.
    rm -f "$PO/state/"*; : > "$PO/state/needsreview-6999-bbb"; sleep 1; : > "$PO/state/last-open-prs"
    ( O="$PO"; . "$TMP/fn_prune_orphan.sh"; prune_orphan_markers '' 0 )
    if [ ! -e "$PO/state/needsreview-6999-bbb" ]; then
      echo "  ✅ an EMPTY but SUCCESSFUL listing prunes orphans (the drained state does not leak)"; PASS=$((PASS+1))
    else
      echo "  ❌ an empty successful listing pruned nothing — markers leak forever on a drained box"; FAIL=$((FAIL+1))
    fi
    # (12e): the marker is OLDER than the listing, so only the 300-row cap can spare it.
    : > "$PO/state/needsreview-6999-bbb"; sleep 1; : > "$PO/state/last-open-prs"
    ( O="$PO"; . "$TMP/fn_prune_orphan.sh"; prune_orphan_markers '6001:h:br' 300 )
    if [ -e "$PO/state/needsreview-6999-bbb" ]; then
      echo "  ✅ a TRUNCATED listing (row count at the 300 cap) prunes NOTHING — an omitted open PR keeps its marker"; PASS=$((PASS+1))
    else
      echo "  ❌ a truncated listing pruned a marker — an open PR outside the cap lost its state"; FAIL=$((FAIL+1))
    fi
  else
    echo "  ❌ could not extract prune_orphan_markers from orch-loop.sh"; FAIL=$((FAIL+1))
  fi
  # (13) …and the SPEND sweep still exists on the GREEN arm (review round 5, residual 2): losing it
  # silently restores the monotonic state/ growth round 5 fixed, and nothing else would notice.
  wpin "the GREEN arm still sweeps the local spend record" "$TMP/green_arm.sh" 'rm -f "$O/state/fixspend-$PR-"*'

  wpin "report.sh surfaces the stale-evidence queue (indicator b)" "$REPORT" 'stale evidence (needs re-review)'
else
  echo "  ❌ the verdict/state functions did not extract to syntactically valid shell from merge-one.sh / orch-loop.sh"; FAIL=$((FAIL+1))
fi

echo
echo "================ RESULT: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
