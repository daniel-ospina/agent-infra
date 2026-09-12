#!/usr/bin/env bash
# record-review.test.sh — self-check for scripts/record-review.sh, focused on
# the #426 repo-qualified registry key (PR numbers collide across repos).
#
# Run: bash scripts/record-review.test.sh
# Fake HOME + stubbed gh — never touches the real ~/.pi/agent/reviews or gh.
#
# Coverage:
#   repo known     → writes <owner>-<repo>-<PR>.json with the repo field
#   migration      → supersedes a legacy <PR>.json that belongs to this repo
#   collision-safe → does NOT delete a legacy <PR>.json from ANOTHER repo
#   repo-less      → legacy <PR>.json (backward compat, no repo field)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECORD="$SCRIPT_DIR/record-review.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
assert_eq() {
    if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: $1, want: $2)"; fi
}
assert_contains() {
    if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing: $2)"; fi
}

T="$(mktemp -d /tmp/record-review-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT
SHA="$(printf 'a%.0s' $(seq 1 40))" # 40×a — matches the stub's head answer

# Stubbed gh: answers the stale-sha head query + PR-body read/PATCH + the
# #513 clean-micro tier guard's body/labels queries.
#   head    (--jq .head.sha)      → ${STUB_HEAD_SHA:-40×a}
#   body    (--jq .body)          → {"body": "${STUB_BODY:-PR body}"}  (PR body text)
#   labels  (--jq '.[].name')     → ${STUB_LABELS:-} lines, or the per-issue
#                                   file ${STUB_LABELS_DIR}/<issue-num> when it
#                                   exists; exit 1 when STUB_LABELS_FAIL=1
#   PATCH (-X PATCH … --input -)  → swallow stdin
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${GH_STUB_LOG:?}"
if [ "$1" = "api" ] && [ "$2" = "-X" ]; then
    # PATCH body — capture stdin when GH_STUB_PATCH_BODY is set (#716), else swallow
    if [ -n "${GH_STUB_PATCH_BODY:-}" ]; then
        cat > "$GH_STUB_PATCH_BODY"
    else
        cat >/dev/null
    fi
    exit 0
fi
if [ "$1" = "api" ]; then
    if printf '%s' "$*" | grep -qF -- "--jq .head.sha"; then
        printf '%s' "${STUB_HEAD_SHA:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
        echo; exit 0
    fi
    if printf '%s' "$*" | grep -qF -- "--jq .body"; then
        printf '{"body": "%s"}' "${STUB_BODY:-PR body}"
        exit 0
    fi
    if printf '%s' "$*" | grep -qF -- "--jq .[].name"; then
        [ "${STUB_LABELS_FAIL:-0}" = "1" ] && exit 1
        num="$(printf '%s' "$*" | sed -n 's/.*issues\/\([0-9]*\)\/labels.*/\1/p')"
        if [ -n "$num" ] && [ -n "${STUB_LABELS_DIR:-}" ] && [ -f "${STUB_LABELS_DIR}/$num" ]; then
            cat "${STUB_LABELS_DIR}/$num"
            exit 0
        fi
        printf '%s\n' "${STUB_LABELS:-}"
        exit 0
    fi
    printf '{"body": "PR body"}' ; exit 0
fi
exit 0
STUB
chmod +x "$T/bin/gh"

F_HOME="$T/home"
mkdir -p "$F_HOME/.pi/agent/reviews"
LOG="$T/gh.log"

run_record() { # <repo-or-empty> <pr>
    run_record_rc "$1" "$2" "$SHA"
}

run_record_rc() { # <repo-or-empty> <pr> <sha> — captures rc in $RECORD_RC
    local repo="${1:-}" pr="$2" sha="$3" rcfile="$T/rc"
    : > "$LOG"
    (
        export HOME="$F_HOME"
        export PATH="$T/bin:$PATH"
        export GH_STUB_LOG="$LOG"
        rc=0
        if [ -n "$repo" ]; then
            bash "$RECORD" "$pr" "$sha" clean "$repo" || rc=$?
        else
            bash "$RECORD" "$pr" "$sha" clean || rc=$?
        fi
        printf '%s' "$rc" > "$rcfile"
    ) 2>/dev/null
    RECORD_RC="$(cat "$rcfile" 2>/dev/null || echo 99)"
}

# #513: verdict-parameterized runner capturing rc AND stderr (the clean-micro
# guard's refusals/warnings are written to stderr).
run_record_verdict() { # <verdict> <repo-or-empty> <pr> [sha] → $RECORD_RC $RECORD_ERR
    local verdict="$1" repo="${2:-}" pr="$3" sha="${4:-$SHA}" rcfile="$T/rc" errfile="$T/err"
    : > "$LOG"
    rm -f "$errfile"
    (
        export HOME="$F_HOME"
        export PATH="$T/bin:$PATH"
        export GH_STUB_LOG="$LOG"
        rc=0
        if [ -n "$repo" ]; then
            bash "$RECORD" "$pr" "$sha" "$verdict" "$repo" 2>"$errfile" || rc=$?
        else
            bash "$RECORD" "$pr" "$sha" "$verdict" 2>"$errfile" || rc=$?
        fi
        printf '%s' "$rc" > "$rcfile"
    ) 2>/dev/null
    RECORD_RC="$(cat "$rcfile" 2>/dev/null || echo 99)"
    RECORD_ERR="$(cat "$errfile" 2>/dev/null || true)"
}

# #513 parser-parity seam: source the guarded script (main guard makes this
# inert) and run closing_issue_refs directly. Bare #N resolves against the
# exported REPO, mirroring the guard's same-repo semantics.
refs_for() { # <repo> <text> — prints one "repo#num" per line
    local repo="$1" text="$2"
    (
        export REPO="$repo"
        # arg0 = _ (NOT the script path) — the main guard compares $0 with
        # BASH_SOURCE[0]; an arg0 equal to the script path would RUN main.
        bash -c 'source "$1" >/dev/null 2>&1 || exit 1; closing_issue_refs "$2"' _ "$RECORD" "$text"
    ) 2>/dev/null || true
}

echo "── 1. Repo known → qualified key ───────────────────────────────"
run_record "daniel-ospina/agent-infra" 424241
Q="$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-424241.json"
[ -f "$Q" ] && ok "qualified file written" || bad "qualified file written ($Q)"
assert_contains "$(cat "$Q")" '"repo":"daniel-ospina/agent-infra"' "record carries the repo field"
[ ! -f "$F_HOME/.pi/agent/reviews/424241.json" ] && ok "no legacy file for repo'd record" || bad "no legacy file for repo'd record"

echo "── 2. Migration: matching legacy superseded + removed ──────────"
LEGACY="$F_HOME/.pi/agent/reviews/424242.json"
printf '{"pr":424242,"head_sha":"%s","verdict":"clean","repo":"daniel-ospina/agent-infra","reviewed_at":"old"}\n' "$SHA" > "$LEGACY"
run_record "daniel-ospina/agent-infra" 424242
[ ! -f "$LEGACY" ] && ok "matching legacy removed" || bad "matching legacy removed"
[ -f "$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-424242.json" ] && ok "qualified file supersedes legacy" || bad "qualified file supersedes legacy"

echo "── 3. Collision-safe: ANOTHER repo's legacy is never deleted ───"
OTHER="$F_HOME/.pi/agent/reviews/424243.json"
printf '{"pr":424243,"head_sha":"%s","verdict":"clean","repo":"daniel-ospina/DMeer","reviewed_at":"old"}\n' "$SHA" > "$OTHER"
run_record "daniel-ospina/agent-infra" 424243
[ -f "$OTHER" ] && ok "foreign legacy untouched (its data is not ours to delete)" || bad "foreign legacy untouched"
[ -f "$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-424243.json" ] && ok "our qualified record written alongside" || bad "our qualified record written alongside"

echo "── 4. Repo-less → legacy key (backward compat) ─────────────────"
run_record "" 424244
L="$F_HOME/.pi/agent/reviews/424244.json"
[ -f "$L" ] && ok "repo-less record at legacy key" || bad "repo-less record at legacy key"
if grep -q '"repo"' "$L"; then bad "repo-less record has no repo field"; else ok "repo-less record has no repo field"; fi

echo "── 5. Unparseable legacy (formatted JSON) is never deleted ─────"
UNPARSEABLE="$F_HOME/.pi/agent/reviews/424245.json"
printf '{\n  "pr": 424245,\n  "repo": "daniel-ospina/agent-infra"\n}\n' > "$UNPARSEABLE"
run_record "daniel-ospina/agent-infra" 424245
[ -f "$UNPARSEABLE" ] && ok "unparseable legacy preserved (never delete what we can't attribute)" || bad "unparseable legacy preserved"

echo "── 6. Guard consulted gh (head query logged) + evidence PATCH ──"
run_record "daniel-ospina/agent-infra" 424246
Q6="$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-424246.json"
if grep -q "api repos/daniel-ospina/agent-infra/pulls/424246 --jq .head.sha" "$LOG"; then
    ok "stale-sha guard queried the PR head via gh"
else
    bad "stale-sha guard queried the PR head via gh"
fi
if grep -qF -- "-X PATCH repos/daniel-ospina/agent-infra/pulls/424246" "$LOG"; then
    ok "evidence PATCH posted (qualified-basename marker path exercised)"
else
    bad "evidence PATCH posted"
fi
[ -f "$Q6" ] && ok "record written in guard+evidence flow" || bad "record written in guard+evidence flow"

echo "── 7. Stale-sha refusal: mismatched head → exit 3, no record ────"
MISMATCH_SHA="$(printf 'b%.0s' $(seq 1 40))" # 40×b — stub answers aaaa…, so bbbb… is stale
STUB_HEAD_SHA="$SHA" run_record_rc "daniel-ospina/agent-infra" 424247 "$MISMATCH_SHA"
RC7="$RECORD_RC"
[ "$RC7" = "3" ] && ok "stale-sha guard refuses (exit 3)" || bad "stale-sha guard refuses (exit 3, got rc=$RC7)"
[ ! -f "$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-424247.json" ] && ok "no record written on refusal" || bad "no record written on refusal"

echo "── 8. #513 clean-micro tier guard ────────────────────────────"

# 8.1 arm (a): linked same-repo issue complexity:micro → allow, marker carries the verdict.
STUB_BODY="Fixes #424300" STUB_LABELS="complexity:micro" run_record_verdict clean-micro "daniel-ospina/agent-infra" 424300
Q81="$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-424300.json"
[ "$RECORD_RC" = "0" ] && ok "arm (a): complexity:micro linked issue allows (rc 0)" || bad "arm (a): allows (rc=$RECORD_RC, err=$RECORD_ERR)"
[ -f "$Q81" ] && ok "arm (a): record written" || bad "arm (a): record written"
assert_contains "$(cat "$Q81" 2>/dev/null || true)" '"verdict":"clean-micro"' "arm (a): record carries verdict clean-micro"

# 8.2 arm (b): complexity:standard → exit 4, NO record.
STUB_BODY="Fixes #424301" STUB_LABELS="complexity:standard" run_record_verdict clean-micro "daniel-ospina/agent-infra" 424301
Q82="$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-424301.json"
[ "$RECORD_RC" = "4" ] && ok "arm (b): complexity:standard refuses (exit 4)" || bad "arm (b): refuses (rc=$RECORD_RC, err=$RECORD_ERR)"
[ ! -f "$Q82" ] && ok "arm (b): no record written on refusal" || bad "arm (b): no record written on refusal"
assert_contains "$RECORD_ERR" "record-review.sh 424301 <head-sha> clean daniel-ospina/agent-infra" "arm (b): exit-4 stderr prescribes the standard/complex remedy"
assert_contains "$RECORD_ERR" "relabel complexity:micro" "arm (b): exit-4 stderr names the mislabel remedy"

# 8.3 arm (b): complexity:complex → exit 4 (label-space totality: any non-micro complexity:*).
STUB_BODY="Fixes #424302" STUB_LABELS="complexity:complex" run_record_verdict clean-micro "daniel-ospina/agent-infra" 424302
[ "$RECORD_RC" = "4" ] && ok "arm (b): complexity:complex refuses (exit 4)" || bad "arm (b): complexity:complex (rc=$RECORD_RC)"

# 8.4 arm (b): pre-existing valid record survives a refusal byte-identical.
Q84="$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-424303.json"
printf '{"pr":424303,"head_sha":"%s","verdict":"clean","repo":"daniel-ospina/agent-infra","reviewed_at":"old"}\n' "$SHA" > "$Q84"
BEFORE84="$(cat "$Q84")"
STUB_BODY="Fixes #424303" STUB_LABELS="complexity:standard" run_record_verdict clean-micro "daniel-ospina/agent-infra" 424303
[ "$RECORD_RC" = "4" ] && ok "arm (b): refuses over a pre-existing clean record (rc 4)" || bad "arm (b): pre-existing (rc=$RECORD_RC)"
[ "$(cat "$Q84")" = "$BEFORE84" ] && ok "arm (b): pre-existing record survives byte-identical" || bad "arm (b): pre-existing record mutated by the refusal"

# 8.5 arm (c): labels carry no complexity:* → fail-open, record written, loud warning.
STUB_BODY="Fixes #424304" STUB_LABELS="enhancement" run_record_verdict clean-micro "daniel-ospina/agent-infra" 424304
Q85="$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-424304.json"
[ "$RECORD_RC" = "0" ] && ok "arm (c): no complexity label fails open (rc 0)" || bad "arm (c): no complexity label (rc=$RECORD_RC)"
[ -f "$Q85" ] && ok "arm (c): record written" || bad "arm (c): record written"
assert_contains "$RECORD_ERR" "UNVERIFIED" "arm (c): warning names the unverified tier"

# 8.6 arm (c): labels fetch failure (stub exit 1) → fail-open, no refusal.
STUB_BODY="Fixes #424305" STUB_LABELS="complexity:micro" STUB_LABELS_FAIL=1 run_record_verdict clean-micro "daniel-ospina/agent-infra" 424305
Q86="$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-424305.json"
[ "$RECORD_RC" = "0" ] && ok "arm (c): labels fetch failure fails open (rc 0)" || bad "arm (c): labels fetch failure (rc=$RECORD_RC, err=$RECORD_ERR)"
[ -f "$Q86" ] && ok "arm (c): record written on fetch failure" || bad "arm (c): record written on fetch failure"

# 8.7 arm (c): no closing ref in the body → fail-open warning.
STUB_BODY="Just a docs change, no issue referenced" STUB_LABELS="complexity:micro" run_record_verdict clean-micro "daniel-ospina/agent-infra" 424306
[ "$RECORD_RC" = "0" ] && ok "arm (c): body without closing ref fails open (rc 0)" || bad "arm (c): no closing ref (rc=$RECORD_RC)"
assert_contains "$RECORD_ERR" "no same-repo closing-issue ref" "arm (c): warning names the missing linkage"

# 8.8 arm (c): cross-repo-only closing ref → never binds tier → fail-open.
STUB_BODY="Fixes daniel-ospina/tortoise#424307" STUB_LABELS="complexity:standard" run_record_verdict clean-micro "daniel-ospina/agent-infra" 424308
[ "$RECORD_RC" = "0" ] && ok "arm (c): cross-repo-only ref fails open (rc 0)" || bad "arm (c): cross-repo-only (rc=$RECORD_RC, err=$RECORD_ERR)"

# 8.9 multi-ref: ANY same-repo non-micro closing ref refuses; all-micro allows.
mkdir -p "$T/labels"
printf 'complexity:micro\n' > "$T/labels/424310"
printf 'complexity:standard\n' > "$T/labels/424311"
printf 'complexity:micro\n' > "$T/labels/424312"
printf 'complexity:micro\n' > "$T/labels/424313"
# NOTE (#513 review r2): ok/bad MUST run in the counting shell — a
# subshell would discard the PASS/FAIL increments and the suite would exit 0
# even when these pins fail (the only failure gate is top-level FAIL=0).
export STUB_LABELS_DIR="$T/labels"
export STUB_LABELS=""   # per-issue map takes precedence in the stub
STUB_BODY="Fixes #424310 and also closes #424311" run_record_verdict clean-micro "daniel-ospina/agent-infra" 424309 "$SHA"
[ "$RECORD_RC" = "4" ] && ok "multi-ref: any same-repo non-micro ref refuses (rc 4)" || bad "multi-ref: any non-micro refuses (rc=$RECORD_RC, err=$RECORD_ERR)"
STUB_BODY="Fixes #424312 and Closes #424313" run_record_verdict clean-micro "daniel-ospina/agent-infra" 424314 "$SHA"
[ "$RECORD_RC" = "0" ] && ok "multi-ref: all-micro refs allow (rc 0)" || bad "multi-ref: all-micro allows (rc=$RECORD_RC, err=$RECORD_ERR)"
unset STUB_LABELS_DIR STUB_LABELS
rm -rf "$T/labels"

# 8.9b mixed-case slug: GitHub repo identity is case-INSENSITIVE — a
# same-repo closing ref written with differing casing (DANIEL-OSPINA/… or a
# mixed-case full URL) must still bind the tier (refuse clean-micro for a
# standard-linked issue), never drop to arm (c) fail-open. RED pre-fix (the
# same-repo filter compared $1 == "$REPO" case-sensitively).
mkdir -p "$T/labels"
printf 'complexity:standard\n' > "$T/labels/424316"
export STUB_LABELS_DIR="$T/labels"
export STUB_LABELS=""   # per-issue map takes precedence in the stub
STUB_BODY="Fixes DANIEL-OSPINA/Agent-Infra#424316" run_record_verdict clean-micro "daniel-ospina/agent-infra" 424317 "$SHA"
[ "$RECORD_RC" = "4" ] && ok "mixed-case slug: same-repo ref with different casing still refuses (rc 4)" || bad "mixed-case slug: casing bypassed the tier bind (rc=$RECORD_RC, err=$RECORD_ERR)"
STUB_BODY="Fixes https://github.com/Daniel-Ospina/Agent-Infra/issues/424316" run_record_verdict clean-micro "daniel-ospina/agent-infra" 424318 "$SHA"
[ "$RECORD_RC" = "4" ] && ok "mixed-case URL: full-URL casing still refuses (rc 4)" || bad "mixed-case URL: casing bypassed the tier bind (rc=$RECORD_RC, err=$RECORD_ERR)"
STUB_BODY="Fixes https://GITHUB.com/Daniel-Ospina/Agent-Infra/issues/424316" run_record_verdict clean-micro "daniel-ospina/agent-infra" 424319 "$SHA"
[ "$RECORD_RC" = "4" ] && ok "mixed-case HOST URL: uppercase host still refuses (rc 4)" || bad "mixed-case HOST URL: host casing bypassed the tier bind (rc=$RECORD_RC, err=$RECORD_ERR)"
unset STUB_LABELS_DIR STUB_LABELS
rm -rf "$T/labels"

# 8.10 clean verdict: ZERO extra gh calls (no labels query in the log).
run_record "daniel-ospina/agent-infra" 424315
if grep -q "labels" "$LOG"; then
    bad "clean verdict adds no gh labels call"
else
    ok "clean verdict adds no gh labels call"
fi

# 8.11 parser-parity corpus (check-pipeline-compliance parse_issue_ref semantics).
OUT="$(refs_for "daniel-ospina/agent-infra" "Fixes #42")"
assert_contains "$OUT" "daniel-ospina/agent-infra#42" "parser: bare #N resolves against REPO"
OUT="$(refs_for "daniel-ospina/agent-infra" "Closes daniel-ospina/tortoise#7 and Resolves #9")"
assert_contains "$OUT" "daniel-ospina/tortoise#7" "parser: owner/repo#N carries its own repo"
assert_contains "$OUT" "daniel-ospina/agent-infra#9" "parser: bare #N next to owner/repo#N still resolves"
OUT="$(refs_for "daniel-ospina/agent-infra" "Fixes https://github.com/other/orgrepo/issues/12")"
assert_contains "$OUT" "other/orgrepo#12" "parser: full URL form"
OUT="$(refs_for "daniel-ospina/agent-infra" "Fixes https://github.com/other/orgrepo/pull/12")"
[ -z "$OUT" ] && ok "parser: pull-URL excluded" || bad "parser: pull-URL excluded (got: $OUT)"
OUT="$(refs_for "daniel-ospina/agent-infra" "This fixes #42 in passing")"
assert_contains "$OUT" "#42" "parser: narrative prose-verb class matches (parse_issue_ref parity)"

# 8.12 repo-less clean-micro → arm (c) fail-open (no repo to tier-bind).
run_record_verdict clean-micro "" 424316
[ "$RECORD_RC" = "0" ] && ok "repo-less clean-micro fails open (rc 0)" || bad "repo-less clean-micro (rc=$RECORD_RC)"
assert_contains "$RECORD_ERR" "UNVERIFIED" "repo-less clean-micro warns the tier is unverified"

echo ""
echo "── 9. #716 second-model gate line ─────────────────────────────"

# Runner that sets the #716 env (or flags) and captures the PATCH body.
# run_record_sm <env-model> <env-independent> <pr> [flag-model] [flag-independent]
run_record_sm() {
    local env_model="$1" env_ind="$2" pr="$3" flag_model="${4:-}" flag_ind="${5:-}"
    local rcfile="$T/rc" patchfile="$T/patch"
    : > "$LOG"; : > "$patchfile"
    (
        export HOME="$F_HOME"
        export PATH="$T/bin:$PATH"
        export GH_STUB_LOG="$LOG"
        export GH_STUB_PATCH_BODY="$patchfile"
        export SECOND_MODEL_GATE_MODEL="$env_model"
        export SECOND_MODEL_GATE_INDEPENDENT="$env_ind"
        rc=0
        if [ -n "$flag_model" ] && [ -n "$flag_ind" ]; then
            bash "$RECORD" "$pr" "$SHA" clean "daniel-ospina/agent-infra" --second-model "$flag_model" --second-model-independent "$flag_ind" 2>"$T/err" || rc=$?
        else
            bash "$RECORD" "$pr" "$SHA" clean "daniel-ospina/agent-infra" 2>"$T/err" || rc=$?
        fi
        printf '%s' "$rc" > "$rcfile"
    )
    RECORD_RC="$(cat "$rcfile" 2>/dev/null || echo 99)"
    PATCH_BODY="$(cat "$patchfile" 2>/dev/null || true)"
}

# 9.1 happy path — the marker line reaches the PR body PATCH.
run_record_sm "moonshot/kimi-k3" "yes" 424400
[ "$RECORD_RC" = "0" ] && ok "SM marker: record rc 0" || bad "SM marker: rc=$RECORD_RC"
assert_contains "$PATCH_BODY" "[SECOND-MODEL-GATE] model=moonshot/kimi-k3 independent=yes @ $SHA" "SM marker line posted in the PATCH body (head-bound)"
assert_contains "$PATCH_BODY" "review recorded: reviews/424400.json" "verdict marker still posted alongside"

# 9.2 absent env — no SM line at all (backward compatible).
run_record_sm "" "" 424401
[ "$RECORD_RC" = "0" ] && ok "SM absent: record rc 0" || bad "SM absent: rc=$RECORD_RC"
if printf '%s' "$PATCH_BODY" | grep -qF '[SECOND-MODEL-GATE]'; then bad "SM absent: no SM line expected"; else ok "SM absent: no SM line posted"; fi

# 9.3 model without independent → refuse (exit 2), no record.
run_record_sm "moonshot/kimi-k3" "" 424402
[ "$RECORD_RC" = "2" ] && ok "SM model without independent refuses (exit 2)" || bad "SM model without independent (rc=$RECORD_RC)"
[ ! -f "$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-424402.json" ] && ok "SM refusal writes no record" || bad "SM refusal wrote a record"

# 9.4 DEGRADED is a first-class value (check (f) then blocks on it).
run_record_sm "**DEGRADED" "DEGRADED" 424403
[ "$RECORD_RC" = "0" ] && ok "SM DEGRADED: record rc 0" || bad "SM DEGRADED: rc=$RECORD_RC"
assert_contains "$PATCH_BODY" "[SECOND-MODEL-GATE] model=**DEGRADED independent=DEGRADED" "SM DEGRADED line posted verbatim"

# 9.5 invalid independent value → refuse.
run_record_sm "moonshot/kimi-k3" "maybe" 424404
[ "$RECORD_RC" = "2" ] && ok "SM invalid independent refuses (exit 2)" || bad "SM invalid independent (rc=$RECORD_RC)"

# 9.6 independent without a model → refuse.
run_record_sm "" "yes" 424405
[ "$RECORD_RC" = "2" ] && ok "SM independent without model refuses (exit 2)" || bad "SM independent without model (rc=$RECORD_RC)"

# 9.7 flag form is equivalent to the env form.
run_record_sm "" "" 424406 "openrouter/anthropic/claude-opus-4.8" "yes"
[ "$RECORD_RC" = "0" ] && ok "SM flag form: record rc 0" || bad "SM flag form: rc=$RECORD_RC"
assert_contains "$PATCH_BODY" "[SECOND-MODEL-GATE] model=openrouter/anthropic/claude-opus-4.8 independent=yes" "SM flag form posts the marker"

# 9.8 idempotent — a body already carrying BOTH markers is not re-PATCHed.
STUB_BODY="review recorded: reviews/424407.json verdict=clean @ $SHA (daniel-ospina/agent-infra) [SECOND-MODEL-GATE] model=moonshot/kimi-k3 independent=yes @ $SHA" run_record_sm "moonshot/kimi-k3" "yes" 424407
if grep -q -- "-X PATCH" "$LOG"; then bad "SM idempotency: re-PATCHed despite both markers present"; else ok "SM idempotency: both markers present → no PATCH"; fi

# 9.10 C3(a) — the reserved DEGRADED marker is never recorded as independent.
run_record_sm "**DEGRADED" "yes" 424409
[ "$RECORD_RC" = "2" ] && ok "SM reserved model with independent=yes refuses (exit 2)" || bad "SM reserved model + yes (rc=$RECORD_RC)"
[ ! -f "$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-424409.json" ] && ok "SM reserved+yes refusal writes no record" || bad "SM reserved+yes wrote a record"

# 9.11 C3(a) — a non-id model value is refused.
run_record_sm "<script>" "yes" 424410
[ "$RECORD_RC" = "2" ] && ok "SM non-id model refuses (exit 2)" || bad "SM non-id model (rc=$RECORD_RC)"
[ ! -f "$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-424410.json" ] && ok "SM non-id refusal writes no record" || bad "SM non-id wrote a record"

# 9.12 G5 — reserved/placeholder tokens (beyond DEGRADED) are never independent.
run_record_sm "none" "yes" 424411
[ "$RECORD_RC" = "2" ] && ok "SM reserved 'none' + yes refuses (exit 2)" || bad "SM reserved none (rc=$RECORD_RC)"
run_record_sm "null" "yes" 424412
[ "$RECORD_RC" = "2" ] && ok "SM reserved 'null' + yes refuses (exit 2)" || bad "SM reserved null (rc=$RECORD_RC)"
run_record_sm "unknown" "DEGRADED" 424413
[ "$RECORD_RC" = "0" ] && ok "SM reserved 'unknown' + DEGRADED records (the sanctioned degraded form)" || bad "SM reserved unknown + DEGRADED (rc=$RECORD_RC)"
if printf '%s' "$PATCH_BODY" | grep -qF 'model=unknown independent=DEGRADED'; then ok "SM reserved 'unknown' records only as DEGRADED"; else bad "SM reserved 'unknown' DEGRADED marker not posted"; fi

# 9.13 G10 — a NEW second-model marker REPLACES a stale one (append-and-never-
# remove left a conflicting body that check (f) now fails closed on).
STALE_SM_BODY="review recorded: reviews/424414.json verdict=clean @ $SHA (daniel-ospina/agent-infra)
[SECOND-MODEL-GATE] model=moonshot/kimi-k3 independent=DEGRADED @ $SHA"
STUB_BODY="$STALE_SM_BODY" run_record_sm "moonshot/kimi-k3" "yes" 424414
if printf '%s' "$PATCH_BODY" | grep -qF "independent=yes"; then ok "SM replace: new marker posted"; else bad "SM replace: new marker not posted"; fi
_sm_count="$(printf '%s' "$PATCH_BODY" | grep -cF '[SECOND-MODEL-GATE]')"
if [ "$_sm_count" = "1" ]; then ok "SM replace: exactly one SM marker in the patched body"; else bad "SM replace: stale marker stacked (count=$_sm_count)"; fi
if printf '%s' "$PATCH_BODY" | grep -qF "independent=DEGRADED"; then bad "SM replace: stale DEGRADED marker survived"; else ok "SM replace: stale DEGRADED marker removed"; fi
if printf '%s' "$PATCH_BODY" | grep -qF "reviews/424414.json"; then ok "SM replace: verdict marker preserved"; else bad "SM replace: verdict marker was dropped"; fi

# 9.9 a verdict marker already present but SM line missing → only the SM line posts.
STUB_BODY="review recorded: reviews/424408.json verdict=clean @ $SHA (daniel-ospina/agent-infra)" run_record_sm "moonshot/kimi-k3" "yes" 424408
if printf '%s' "$PATCH_BODY" | grep -qF '[SECOND-MODEL-GATE]'; then ok "SM partial idempotency: missing SM line was posted"; else bad "SM partial idempotency: SM line not posted"; fi
if printf '%s' "$PATCH_BODY" | grep -qF 'PR body'; then bad "SM partial idempotency: injected STUB_BODY was NOT read (test would be vacuous)"; else ok "SM partial idempotency: injected body honored (non-vacuous)"; fi

unset STUB_BODY

echo ""
echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { echo "  ❌ FAILURES — fix and re-run"; exit 1; }
echo "  ✅ all checks passed"
exit 0
