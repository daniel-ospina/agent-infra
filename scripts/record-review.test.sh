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
#   #633 stale-run → a re-record on an already-marker'd body re-runs each
#                    completed-FAILURE gate check run on the head (so the
#                    red rollup row is replaced by a SUCCESS attempt);
#                    fail-soft when nothing to re-run / the API refuses

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
# #513 clean-micro tier guard's body/labels queries + the #633 stale-run
# remediation's check-runs query + job rerun POST.
#   head        (--jq .head.sha)   → ${STUB_HEAD_SHA:-40×a}
#   body        (--jq .body)       → {"body": "${STUB_BODY:-PR body}"}  (PR body text)
#   labels      (--jq '.[].name')  → ${STUB_LABELS:-} lines, or the per-issue
#                                   file ${STUB_LABELS_DIR}/<issue-num> when it
#                                   exists; exit 1 when STUB_LABELS_FAIL=1
#   check-runs  (URL has /check-runs) → {"check_runs": ${STUB_CHECK_RUNS:-[]}}
#                                   (RAW payload — the script applies its own
#                                   local jq; exit 1 when STUB_CHECK_RUNS_FAIL=1)
#   PATCH (-X PATCH … --input -)    → swallow stdin; exit 1 when
#                                     STUB_PATCH_FAIL=1
#   POST rerun (-X POST … /rerun)   → swallow stdin (201); exit 1 when
#                                     STUB_RERUN_FAIL=1
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${GH_STUB_LOG:?}"
if [ "$1" = "api" ] && [ "$2" = "-X" ]; then
    # PATCH body / job rerun POST. Fail the evidence PATCH or the rerun on
    # demand (#633 fail-soft + no-marker pins). Consume piped stdin (PATCH
    # feeds it via --input -) WITHOUT blocking on an inherited terminal/stdin
    # — the rerun POST pipes nothing, so a bare `cat` would hang the suite
    # when run interactively.
    if printf '%s' "$*" | grep -qF -- "/rerun"; then
        [ "${STUB_RERUN_FAIL:-0}" = "1" ] && exit 1
    elif printf '%s' "$*" | grep -qF -- "-X PATCH"; then
        [ "${STUB_PATCH_FAIL:-0}" = "1" ] && exit 1
    fi
    if [ -t 0 ]; then :; else cat >/dev/null; fi
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
    if printf '%s' "$*" | grep -qF -- "/check-runs"; then
        # RAW envelope — the script applies its own local jq (no --jq in
        # argv). Exit 1 on demand to pin the #633 loud-API-failure path.
        [ "${STUB_CHECK_RUNS_FAIL:-0}" = "1" ] && exit 1
        printf '{"check_runs": %s}' "${STUB_CHECK_RUNS:-[]}"
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

run_record_stale() { # <repo> <pr> <sha> — records with --force-stale (head
    # answers STUB_HEAD_SHA ≠ recorded sha, so the stale-sha guard would
    # refuse without the flag). Captures rc in $RECORD_RC.
    local repo="$1" pr="$2" sha="$3" rcfile="$T/rc"
    : > "$LOG"
    (
        export HOME="$F_HOME"
        export PATH="$T/bin:$PATH"
        export GH_STUB_LOG="$LOG"
        rc=0
        bash "$RECORD" "$pr" "$sha" clean "$repo" --force-stale || rc=$?
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

# 8.10 clean verdict call budget (#513/#568 + #633): no gh LABELS call and no
# job rerun — the #633 remediation's check-runs query is bounded (no rerun
# POST when nothing failed on the head).
run_record "daniel-ospina/agent-infra" 424315
if grep -q "labels" "$LOG"; then
    bad "clean verdict adds no gh labels call"
else
    ok "clean verdict adds no gh labels call"
fi
if grep -qF -- "actions/jobs/" "$LOG"; then
    bad "clean verdict adds no job rerun when nothing failed (log: $(cat "$LOG"))"
else
    ok "clean verdict adds no job rerun when nothing failed"
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

# #633: recompute the exact signed marker record-review.sh posts for a
# PR/repo at $SHA under AI_REVIEW_GATE_KEY=testkey (same openssl call).
signed_marker() { # <pr> <repo> [verdict]
    local pr="$1" repo="$2" verdict="${3:-clean}" m sig
    m="review recorded: reviews/${pr}.json verdict=${verdict} @ ${SHA} (${repo})"
    sig="$(printf '%s' "$m" | openssl dgst -sha256 -hmac "testkey" 2>/dev/null | awk '{print $NF}')"
    printf '%s sig=%s' "$m" "$sig"
}

echo "── 9. #633 stale gate-run remediation ───────────────────────────"
# 9.1 Re-record on an already-marker'd body: the marker is present, so the
#     body is left untouched (no PATCH — no body spam on re-record), but the
#     completed-FAILURE gate job on the head MUST be re-run so the stale red
#     rollup row is replaced by a fresh SUCCESS attempt. RED pre-fix: the old
#     idempotency guard made a same-sha re-record a silent no-op (no PATCH, no
#     edited event, no fresh gate run) — the documented remediation "re-run
#     record-review.sh to retry" did nothing.
STUB_BODY="$(signed_marker 424320 daniel-ospina/agent-infra)" \
STUB_CHECK_RUNS='[{"name":"ai-review-gate","status":"completed","conclusion":"failure","id":777}]' \
AI_REVIEW_GATE_KEY="testkey" run_record "daniel-ospina/agent-infra" 424320
if grep -qF -- "actions/jobs/777/rerun" "$LOG"; then
    ok "9.1 re-record re-runs the stale FAILURE gate job (no more silent no-op)"
else
    bad "9.1 re-record re-runs the stale FAILURE gate job (log: $(cat "$LOG"))"
fi
if grep -qF -- "-X PATCH" "$LOG"; then
    bad "9.1 re-record leaves the marker'd body untouched (no PATCH)"
else
    ok "9.1 re-record leaves the marker'd body untouched (no PATCH)"
fi
if grep -qF -- "commits/$SHA/check-runs" "$LOG"; then
    ok "9.1 remediation queries the RECORDED head's check runs"
else
    bad "9.1 remediation queries the RECORDED head's check runs (log: $(cat "$LOG"))"
fi

# 9.2 Fresh record (marker absent) with a stale FAILURE on the head: posts
#     the marker AND re-runs the failed gate job in the same call.
STUB_BODY="PR body" \
STUB_CHECK_RUNS='[{"name":"ai-review-gate","status":"completed","conclusion":"failure","id":778}]' \
AI_REVIEW_GATE_KEY="testkey" run_record "daniel-ospina/agent-infra" 424321
grep -qF -- "-X PATCH" "$LOG" && ok "9.2 fresh record still posts the marker" || bad "9.2 fresh record posts the marker (log: $(cat "$LOG"))"
grep -qF -- "actions/jobs/778/rerun" "$LOG" && ok "9.2 fresh record also re-runs the stale FAILURE job" || bad "9.2 fresh record re-runs the stale FAILURE job (log: $(cat "$LOG"))"

# 9.3 Nothing failed on the head → no rerun call (no needless Actions runs),
#     marker still posted.
STUB_BODY="PR body" STUB_CHECK_RUNS='[]' AI_REVIEW_GATE_KEY="testkey" run_record "daniel-ospina/agent-infra" 424322
if grep -qF -- "actions/jobs/" "$LOG"; then
    bad "9.3 no rerun when nothing failed (log: $(cat "$LOG"))"
else
    ok "9.3 no rerun when nothing failed"
fi
grep -qF -- "-X PATCH" "$LOG" && ok "9.3 marker still posted" || bad "9.3 marker still posted"

# 9.4 A failed run of a DIFFERENT check name is never re-run (name filter).
STUB_BODY="$(signed_marker 424320 daniel-ospina/agent-infra)" \
STUB_CHECK_RUNS='[{"name":"other-gate","status":"completed","conclusion":"failure","id":779}]' \
AI_REVIEW_GATE_KEY="testkey" run_record "daniel-ospina/agent-infra" 424320
if grep -qF -- "actions/jobs/" "$LOG"; then
    bad "9.4 foreign check name not re-run (log: $(cat "$LOG"))"
else
    ok "9.4 foreign check name not re-run"
fi

# 9.5 Rerun API refusal → fail-soft: record saved, exit 0, loud warning.
STUB_BODY="$(signed_marker 424320 daniel-ospina/agent-infra)" \
STUB_CHECK_RUNS='[{"name":"ai-review-gate","status":"completed","conclusion":"failure","id":780}]' \
STUB_RERUN_FAIL=1 AI_REVIEW_GATE_KEY="testkey" run_record_verdict clean "daniel-ospina/agent-infra" 424323
[ "$RECORD_RC" = "0" ] && ok "9.5 rerun refusal fails soft (rc 0, record saved)" || bad "9.5 rerun refusal fails soft (rc=$RECORD_RC, err=$RECORD_ERR)"
[ -f "$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-424323.json" ] && ok "9.5 record written despite rerun refusal" || bad "9.5 record written despite rerun refusal"
assert_contains "$RECORD_ERR" "could not re-run stale" "9.5 refusal warns on stderr"

# 9.6 Recency guard: a newer SUCCESS for the gate name on the same head
#     already satisfies the required check — the normal green end-state — so
#     the older FAILURE must NOT trigger a rerun (no needless Actions churn
#     on every re-record of an already-green head; matches diagnosis #1 that
#     the FAILURE+SUCCESS pair is harmless).
STUB_BODY="$(signed_marker 424320 daniel-ospina/agent-infra)" \
STUB_CHECK_RUNS='[{"name":"ai-review-gate","status":"completed","conclusion":"failure","id":100},{"name":"ai-review-gate","status":"completed","conclusion":"success","id":200}]' \
AI_REVIEW_GATE_KEY="testkey" run_record "daniel-ospina/agent-infra" 424320
if grep -qF -- "actions/jobs/" "$LOG"; then
    bad "9.6 newer SUCCESS suppresses the rerun (log: $(cat "$LOG"))"
else
    ok "9.6 newer SUCCESS suppresses the rerun"
fi

# 9.7 --force-stale is never remediated: a deliberately stale sha's gate
#     state is unresolvable by design (#2133 escape hatch), and a rerun in
#     the PR's per-PR concurrency group could cancel the REAL head's
#     in-flight gate run — so force-stale records skip the remediation
#     entirely (no check-runs query, no rerun) but still save the record.
STUB_HEAD_SHA="$(printf 'c%.0s' $(seq 1 40))" \
STUB_BODY="$(signed_marker 424320 daniel-ospina/agent-infra)" \
STUB_CHECK_RUNS='[{"name":"ai-review-gate","status":"completed","conclusion":"failure","id":300}]' \
AI_REVIEW_GATE_KEY="testkey" run_record_stale "daniel-ospina/agent-infra" 424320 "$(printf 'b%.0s' $(seq 1 40))"
[ "$RECORD_RC" = "0" ] && ok "9.7 force-stale record still saves (rc 0)" || bad "9.7 force-stale record still saves (rc=$RECORD_RC)"
if grep -qF -- "/check-runs" "$LOG" || grep -qF -- "actions/jobs/" "$LOG"; then
    bad "9.7 force-stale skips the stale-run remediation (log: $(cat "$LOG"))"
else
    ok "9.7 force-stale skips the stale-run remediation"
fi

# 9.8 check-runs query failure (gh/API error): warns LOUDLY on stderr and
#     skips the rerun — a transient API failure must never read as "no red
#     run" (the #405 silent-no-op class, one level down). Record still saves,
#     exit 0 (best-effort).
STUB_BODY="$(signed_marker 424320 daniel-ospina/agent-infra)" \
STUB_CHECK_RUNS='[{"name":"ai-review-gate","status":"completed","conclusion":"failure","id":400}]' \
STUB_CHECK_RUNS_FAIL=1 AI_REVIEW_GATE_KEY="testkey" run_record_verdict clean "daniel-ospina/agent-infra" 424324
[ "$RECORD_RC" = "0" ] && ok "9.8 check-runs query failure fails soft (rc 0)" || bad "9.8 check-runs query failure fails soft (rc=$RECORD_RC, err=$RECORD_ERR)"
[ -f "$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-424324.json" ] && ok "9.8 record written despite query failure" || bad "9.8 record written despite query failure"
assert_contains "$RECORD_ERR" "could not read check runs" "9.8 query failure warns loudly on stderr"
if grep -qF -- "actions/jobs/" "$LOG"; then
    bad "9.8 no rerun on query failure (log: $(cat "$LOG"))"
else
    ok "9.8 no rerun on query failure"
fi

# 9.9 Livelock guard: when the newest run for the gate name is queued/
#     in_progress (a rerun the remediation itself fired, or the `edited` run
#     a fresh PATCH just started), the OLDER completed red run is NOT re-run —
#     firing a second job would cancel the in-flight fresh run through the
#     PR's per-PR concurrency group (cancel-in-progress) and self-perpetuate.
STUB_BODY="$(signed_marker 424320 daniel-ospina/agent-infra)" \
STUB_CHECK_RUNS='[{"name":"ai-review-gate","status":"completed","conclusion":"failure","id":100},{"name":"ai-review-gate","status":"in_progress","conclusion":null,"id":900}]' \
AI_REVIEW_GATE_KEY="testkey" run_record "daniel-ospina/agent-infra" 424320
if grep -qF -- "actions/jobs/" "$LOG"; then
    bad "9.9 in-flight gate run suppresses the rerun (log: $(cat "$LOG"))"
else
    ok "9.9 in-flight gate run suppresses the rerun"
fi

# 9.10 No signed marker posted (evidence PATCH API failure) → remediation
#      MUST NOT fire: a rerun of a marker-less body re-evaluates to a
#      guaranteed red, churning Actions for nothing. Record still saves
#      (best-effort).
STUB_BODY="PR body — no review evidence yet" \
STUB_CHECK_RUNS='[{"name":"ai-review-gate","status":"completed","conclusion":"failure","id":500}]' \
STUB_PATCH_FAIL=1 AI_REVIEW_GATE_KEY="testkey" run_record_verdict clean "daniel-ospina/agent-infra" 424325
[ "$RECORD_RC" = "0" ] && ok "9.10 PATCH failure still saves the record (rc 0)" || bad "9.10 PATCH failure saves record (rc=$RECORD_RC, err=$RECORD_ERR)"
[ -f "$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-424325.json" ] && ok "9.10 record written despite PATCH failure" || bad "9.10 record written despite PATCH failure"
assert_contains "$RECORD_ERR" "could not post review evidence" "9.10 PATCH failure notes on stderr"
if grep -qF -- "actions/jobs/" "$LOG"; then
    bad "9.10 no rerun without a posted marker (log: $(cat "$LOG"))"
else
    ok "9.10 no rerun without a posted marker"
fi

echo ""
echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { echo "  ❌ FAILURES — fix and re-run"; exit 1; }
echo "  ✅ all checks passed"
exit 0
