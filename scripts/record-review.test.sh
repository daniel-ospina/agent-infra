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
    if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi
}

T="$(mktemp -d /tmp/record-review-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT
SHA="$(printf 'a%.0s' $(seq 1 40))" # 40×a — matches the stub's head answer

# Stubbed gh: answers the stale-sha head query + PR-body read/PATCH + the
# #513 clean-micro tier guard's body/labels queries.
#   head    (--jq .head.sha)      → ${STUB_HEAD_SHA:-40×a}
#   body    (--jq .body)          → raw ${STUB_BODY:-PR body}. `gh --jq .body`
#                                   prints the body TEXT, not the JSON envelope;
#                                   the old envelope form only "worked" while the
#                                   closing parser was unanchored (#1012).
#   labels  (--jq '.[].name')     → ${STUB_LABELS:-} lines, or the per-issue
#                                   file ${STUB_LABELS_DIR}/<issue-num> when it
#                                   exists; exit 1 when STUB_LABELS_FAIL=1
#   PATCH (-X PATCH … --input -)  → swallow stdin
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${GH_STUB_LOG:?}"
if [ "$1" = "api" ] && [ "$2" = "-X" ]; then
    # PATCH body — capture stdin to whichever sink the test asked for, else swallow.
    # STUB_CAPTURE (#2982, the diff-binding sink) is checked FIRST so precedence is
    # deterministic; GH_STUB_PATCH_BODY is retained as a fallback because main's
    # harness spelled it that way (#716 — that subsystem was removed, so no current
    # test sets it). Neither name is dropped: keeping only one would silently turn
    # the other's capture into a no-op, and a negative assertion ("the marker must
    # NOT carry diff=") would then pass VACUOUSLY by capturing nothing at all.
    if [ -n "${STUB_CAPTURE:-}" ]; then
        cat >"$STUB_CAPTURE"
    elif [ -n "${GH_STUB_PATCH_BODY:-}" ]; then
        cat > "$GH_STUB_PATCH_BODY"
    else
        cat >/dev/null
    fi
    exit 0
fi
if [ "$1" = "api" ]; then
    # #2982: the reviewed-diff fetch. Placed FIRST — the request carries no
    # --jq, so it would otherwise fall through to the generic body answer.
    if grep -qF -- "application/vnd.github.v3.diff" <<<"$*"; then
        [ "${STUB_DIFF_FAIL:-0}" = "1" ] && exit 1
        cat "${STUB_DIFF_FILE:-/dev/null}"
        exit 0
    fi
    if grep -qF -- "--jq .head.sha" <<<"$*"; then
        printf '%s' "${STUB_HEAD_SHA:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
        echo; exit 0
    fi
    if grep -qF -- "--jq .body" <<<"$*"; then
        # Faithful to `--jq .body`: the RAW body text. Real gh applies the jq
        # filter and prints the string bare — it does not emit a JSON wrapper.
        # #2982's carry-forward check greps the body for a marker LINE, so it
        # needs real newlines rather than "\n" escapes.
        printf '%s' "${STUB_BODY:-PR body}"
        exit 0
    fi
    if grep -qF -- "--jq .[].name" <<<"$*"; then
        [ "${STUB_LABELS_FAIL:-0}" = "1" ] && exit 1
        num="$(printf '%s' "$*" | sed -n 's/.*issues\/\([0-9]*\)\/labels.*/\1/p')"
        if [ -n "$num" ] && [ -n "${STUB_LABELS_DIR:-}" ] && [ -f "${STUB_LABELS_DIR}/$num" ]; then
            cat "${STUB_LABELS_DIR}/$num"
            exit 0
        fi
        printf '%s\n' "${STUB_LABELS:-}"
        exit 0
    fi
    # #1348 clean-low: the head/base/changed_files meta read.
    if grep -qF -- "--jq [(.head.sha), (.base.sha)" <<<"$*"; then
        [ "${STUB_META_FAIL:-0}" = "1" ] && exit 1
        derived=0
        if [ -n "${STUB_COMPARE:-}" ]; then
            derived="$(printf '%s\n' "$STUB_COMPARE" | sed '/^$/d' | wc -l | tr -d ' ')"
        elif [ -n "${STUB_FILES:-}" ]; then
            derived="$(printf '%s\n' "$STUB_FILES" | sed '/^$/d' | wc -l | tr -d ' ')"
        fi
        [ "${derived:-0}" = "0" ] && derived=1
        printf '%s\t%s\t%s' \
            "${STUB_META_HEAD:-${STUB_HEAD_SHA:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}}" \
            "${STUB_META_BASE:-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}" \
            "${STUB_CHANGED_FILES:-$derived}"
        echo; exit 0
    fi
    # #1348 clean-low: the sha-addressable diff read. The guard reads the MERGE
    # BASE out of the SAME response (it is the commit the three-dot diff is taken
    # from, and the sha the record pins), so the stub returns a leading
    # `mb<TAB><sha>` line followed by the rows. STUB_MERGE_BASE lets a vector
    # simulate a response with no merge base (→ refuse).
    if grep -qF -- "compare/" <<<"$*"; then
        [ "${STUB_COMPARE_FAIL:-0}" = "1" ] && exit 1
        printf 'mb\t%s\n' "${STUB_MERGE_BASE-cccccccccccccccccccccccccccccccccccccccc}"
        if [ -n "${STUB_COMPARE:-}" ]; then
            printf '%s\n' "$STUB_COMPARE"
            exit 0
        fi
        out="$(printf '%s\n' "${STUB_FILES:-}" | sed '/^$/d' | awk -F'\t' '{ print "added\t" $1 "\t" }')"
        [ -n "$out" ] && printf '%s\n' "$out"
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
# Deterministic gate key for the WHOLE suite. The recorder signs markers with
# AI_REVIEW_GATE_KEY, and #784's carry-forward now VERIFIES that HMAC (a
# shape-only check let a forged marker in the attacker-writable PR body be
# carried forward and re-signed with the real key). So the suite must not depend
# on the ambient key — or on its absence.
export AI_REVIEW_GATE_KEY="test-key-2982"
TEST_GATE_KEY="$AI_REVIEW_GATE_KEY"

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

# #1012 r2/r3 GitHub-parity seam: closing_issue_refs with the WORD-BOUNDARY-
# ANCHORED CLOSING_KW (no positional REFCTX prefix, but `\b`-anchored exactly
# as the tier guard passes it). The #513 tier guard unions this scan with the
# positional one, so a mid-sentence ref GitHub will auto-close still binds —
# while prose that merely CONTAINS the class ("prefix", "discloses") does not.
refs_for_any() { # <repo> <text> — boundary-anchored keyword-class scan
    local repo="$1" text="$2"
    (
        export REPO="$repo"
        bash -c 'source "$1" >/dev/null 2>&1 || exit 1; closing_issue_refs "$2" "\b$CLOSING_KW"' _ "$RECORD" "$text"
    ) 2>/dev/null || true
}

# #2982: diff-binding runner — lets a test set the PR body AND the diff bytes
# the stubbed `gh` returns for the `Accept: …v3.diff` fetch.
run_record_diff() { # <pr> <sha> <body> [diff-file] [diff-fail] [extra record args…]
    local pr="$1" sha="$2" body="$3" dfile="${4:-/dev/null}" dfail="${5:-0}"
    shift $(( $# > 5 ? 5 : $# ))   # remaining args pass verbatim to record-review.sh
    local rcfile="$T/rc" errfile="$T/err" cap="$T/cap"
    : > "$LOG"; : > "$cap"; rm -f "$errfile"
    (
        export HOME="$F_HOME"
        export PATH="$T/bin:$PATH"
        export GH_STUB_LOG="$LOG"
        export STUB_BODY="$body" STUB_DIFF_FILE="$dfile" STUB_DIFF_FAIL="$dfail" STUB_CAPTURE="$cap"
        rc=0
        bash "$RECORD" "$pr" "$sha" clean "daniel-ospina/agent-infra" "$@" 2>"$errfile" || rc=$?
        printf '%s' "$rc" > "$rcfile"
    ) 2>/dev/null
    RECORD_RC="$(cat "$rcfile" 2>/dev/null || echo 99)"
    RECORD_ERR="$(cat "$errfile" 2>/dev/null || true)"
    RECORD_CAP="$(cat "$cap" 2>/dev/null || true)"
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
STUB_BODY=$'Fixes #424310\nCloses #424311' run_record_verdict clean-micro "daniel-ospina/agent-infra" 424309 "$SHA"
[ "$RECORD_RC" = "4" ] && ok "multi-ref: any same-repo non-micro ref refuses (rc 4)" || bad "multi-ref: any non-micro refuses (rc=$RECORD_RC, err=$RECORD_ERR)"
STUB_BODY=$'Fixes #424312\nCloses #424313' run_record_verdict clean-micro "daniel-ospina/agent-infra" 424314 "$SHA"
[ "$RECORD_RC" = "0" ] && ok "multi-ref: all-micro refs allow (rc 0)" || bad "multi-ref: all-micro allows (rc=$RECORD_RC, err=$RECORD_ERR)"
unset STUB_LABELS_DIR STUB_LABELS
rm -rf "$T/labels"

# 8.9a #1012 × #513 — GITHUB-PARITY tier bind. The positional closing scan
# alone MISSES "This also closes #424331" (mid-sentence), so pre-fix the guard
# resolved only the micro ref #424330, reached no refusal, and recorded
# clean-micro on a PR that ALSO auto-closes complexity:complex #424331 on merge
# — a SILENT FAIL-OPEN. The guard now unions the positional scan with a
# WORD-BOUNDARY-ANCHORED CLOSING_KW scan. RED before the record-review.sh
# parity fix.
mkdir -p "$T/labels"
printf 'complexity:micro\n'   > "$T/labels/424330"
printf 'complexity:complex\n' > "$T/labels/424331"
export STUB_LABELS_DIR="$T/labels"
export STUB_LABELS=""   # per-issue map takes precedence in the stub
STUB_BODY=$'Closes #424330\nThis also closes #424331' run_record_verdict clean-micro "daniel-ospina/agent-infra" 424332 "$SHA"
[ "$RECORD_RC" = "4" ] && ok "github-parity bind: mid-sentence complex ref refuses (rc 4)" || bad "github-parity bind: mid-sentence complex ref must refuse (rc=$RECORD_RC, err=$RECORD_ERR)"
[ ! -f "$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-424332.json" ] && ok "github-parity bind: no record written on refusal" || bad "github-parity bind: record written on refusal"
# Positive control: when the mid-sentence ref is ALSO micro, the union must not
# manufacture a refusal.
printf 'complexity:micro\n' > "$T/labels/424333"
STUB_BODY=$'Closes #424330\nThis also closes #424333' run_record_verdict clean-micro "daniel-ospina/agent-infra" 424334 "$SHA"
[ "$RECORD_RC" = "0" ] && ok "github-parity bind: mid-sentence micro ref still allows (rc 0)" || bad "github-parity bind: all-micro union must allow (rc=$RECORD_RC, err=$RECORD_ERR)"
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
OUT="$(refs_for "daniel-ospina/agent-infra" $'Closes daniel-ospina/tortoise#7\nResolves #9')"
assert_contains "$OUT" "daniel-ospina/tortoise#7" "parser: owner/repo#N carries its own repo"
assert_contains "$OUT" "daniel-ospina/agent-infra#9" "parser: bare #N on its own line still resolves"
OUT="$(refs_for "daniel-ospina/agent-infra" "Fixes https://github.com/other/orgrepo/issues/12")"
assert_contains "$OUT" "other/orgrepo#12" "parser: full URL form"
OUT="$(refs_for "daniel-ospina/agent-infra" "Fixes https://github.com/other/orgrepo/pull/12")"
[ -z "$OUT" ] && ok "parser: pull-URL excluded" || bad "parser: pull-URL excluded (got: $OUT)"
# #1012 — the closing match is POSITIONAL, so a mid-sentence mention must NOT
# resolve (this vector used to assert the opposite; it is what let PR #968
# satisfy the compliance gate). A bullet reference context still resolves.
OUT="$(refs_for "daniel-ospina/agent-infra" "This fixes #42 in passing")"
[ -z "$OUT" ] && ok "parser: mid-sentence mention does not resolve (positional, #1012)" || bad "parser: mid-sentence mention must not resolve (got: $OUT)"
OUT="$(refs_for "daniel-ospina/agent-infra" "- Fixes #42")"
assert_contains "$OUT" "#42" "parser: bullet reference context resolves (parse_issue_ref parity)"
# #1012 r2 — the reference context was too narrow: heading / ordered-list /
# task-list / blockquote / "+" bullet are all accepted Markdown reference
# shapes (they resolved before the positional rule) and were left UNPINNED.
OUT="$(refs_for "daniel-ospina/agent-infra" "## Closes #42")"
assert_contains "$OUT" "#42" "parser: heading reference context resolves"
OUT="$(refs_for "daniel-ospina/agent-infra" "1. Closes #42")"
assert_contains "$OUT" "#42" "parser: ordered-list reference context resolves"
OUT="$(refs_for "daniel-ospina/agent-infra" "- [ ] Closes #42")"
assert_contains "$OUT" "#42" "parser: task-list reference context resolves"
OUT="$(refs_for "daniel-ospina/agent-infra" "> Closes #42")"
assert_contains "$OUT" "#42" "parser: blockquote reference context resolves"
OUT="$(refs_for "daniel-ospina/agent-infra" "+ Closes #42")"
assert_contains "$OUT" "#42" "parser: plus-bullet reference context resolves"
# #1012 r3 — the prefix + checkbox groups are REPEATABLE, so COMPOUND prefixes
# (nested blockquote, list-inside-quote) are reference contexts. A
# single-consumption group false-BLOCKED check (a) on these while GitHub still
# auto-closes on merge.
OUT="$(refs_for "daniel-ospina/agent-infra" "> > Closes #42")"
assert_contains "$OUT" "#42" "parser: nested-blockquote reference context resolves"
OUT="$(refs_for "daniel-ospina/agent-infra" "> - Closes #42")"
assert_contains "$OUT" "#42" "parser: list-inside-quote reference context resolves"
OUT="$(refs_for "daniel-ospina/agent-infra" ">> Closes #42")"
assert_contains "$OUT" "#42" "parser: tight-nested blockquote reference context resolves"
# Anti-vacuous control: consuming more prefixes must NOT reopen the
# mid-sentence vacuity — the keyword must follow the marks immediately.
OUT="$(refs_for "daniel-ospina/agent-infra" "> - This also closes #42")"
[ -z "$OUT" ] && ok "parser: compound prefix does not reopen mid-sentence vacuity" || bad "parser: compound prefix must not resolve a mid-sentence keyword (got: $OUT)"
# Anti-vacuous control: an ATX heading is at most 6 hashes.
OUT="$(refs_for "daniel-ospina/agent-infra" "####### Closes #42")"
[ -z "$OUT" ] && ok "parser: 7-hash run is not a heading context" || bad "parser: 7-hash run must not resolve (got: $OUT)"
# #1012 r2/r3 — the GitHub-parity scan (boundary-anchored CLOSING_KW) DOES
# resolve the mid-sentence ref the positional scan ignores; this is the
# mechanism the #513 tier guard unions in (§8.9a).
OUT="$(refs_for_any "daniel-ospina/agent-infra" "This also closes #42")"
assert_contains "$OUT" "#42" "parser: parity scan resolves a mid-sentence closing ref (GitHub parity)"
OUT="$(refs_for_any "daniel-ospina/agent-infra" "a sentence about refs #42")"
[ -z "$OUT" ] && ok "parser: parity scan still ignores the trace class" || bad "parser: parity scan must not match trace keywords (got: $OUT)"
# #1012 r3 — the parity scan is WORD-BOUNDARY-anchored because the keyword class
# is a SUFFIX of ordinary English words. Unanchored, these three bodies were
# read as `fix #42` / `closes #42` / `resolved #42`, triggering a label fetch
# and a false `exit 4` refusal on a non-micro issue. RED pre-fix.
OUT="$(refs_for_any "daniel-ospina/agent-infra" "The prefix #42 is unrelated.")"
[ -z "$OUT" ] && ok "parser: parity scan ignores 'prefix #42' (word boundary)" || bad "parser: parity scan must ignore 'prefix #42' (got: $OUT)"
OUT="$(refs_for_any "daniel-ospina/agent-infra" "This discloses #42 but does not close it.")"
[ -z "$OUT" ] && ok "parser: parity scan ignores 'discloses #42' (word boundary)" || bad "parser: parity scan must ignore 'discloses #42' (got: $OUT)"
OUT="$(refs_for_any "daniel-ospina/agent-infra" "Unresolved #42 remains open.")"
[ -z "$OUT" ] && ok "parser: parity scan ignores 'unresolved #42' (word boundary)" || bad "parser: parity scan must ignore 'unresolved #42' (got: $OUT)"

# 8.12 repo-less clean-micro → arm (c) fail-open (no repo to tier-bind).
run_record_verdict clean-micro "" 424316
[ "$RECORD_RC" = "0" ] && ok "repo-less clean-micro fails open (rc 0)" || bad "repo-less clean-micro (rc=$RECORD_RC)"
assert_contains "$RECORD_ERR" "UNVERIFIED" "repo-less clean-micro warns the tier is unverified"

# 8.13 cross-script byte-identity pin (#1012 r2) — the REFCTX positional prefix
# and the CLOSING_KW keyword class MUST be byte-identical between
# check-pipeline-compliance.sh and record-review.sh: that equality is the
# stated justification for anchoring both parsers with the same rule, yet
# nothing asserted it, so a one-sided edit could silently desynchronize the two
# gates. Extract the constant lines (in file order) and compare them.
A_CONST="$(grep -E '^(REFCTX|CLOSING_KW)=' "$SCRIPT_DIR/check-pipeline-compliance.sh" || true)"
B_CONST="$(grep -E '^(REFCTX|CLOSING_KW)=' "$RECORD" || true)"
[ -n "$A_CONST" ] && [ -n "$B_CONST" ] || bad "cross-script pin: REFCTX/CLOSING_KW lines missing from a script (extraction is vacuous)"
assert_eq "$A_CONST" "$B_CONST" "cross-script byte-identity: REFCTX + CLOSING_KW lines identical"

# 8.14 FALSE-REFUSAL guard on the parity scan (#1012 r3). The parity scan is
# WORD-BOUNDARY-anchored. Unanchored, the keyword class matches INSIDE English
# words that GitHub's own closing parser — which requires a word boundary —
# never treats as keywords, so the guard REFUSED a legitimate clean-micro over
# prose. RED pre-fix: `The prefix #424340 is unrelated.` yielded `fix #424340`
# from the bare scan, fetched #424340's labels, and exited 4 because they were
# non-micro. The guard must PROCEED (record) — and arm (c) must still warn that
# no real ref was found, which is what makes this vector non-vacuous (a
# "proceeds" result could otherwise be a micro ref that slipped through).
mkdir -p "$T/labels"
printf 'complexity:standard\n' > "$T/labels/424340"
printf 'complexity:standard\n' > "$T/labels/424341"
printf 'complexity:standard\n' > "$T/labels/424342"
export STUB_LABELS_DIR="$T/labels"
export STUB_LABELS=""   # per-issue map takes precedence in the stub
STUB_BODY='The prefix #424340 is unrelated.' run_record_verdict clean-micro "daniel-ospina/agent-infra" 424340 "$SHA"
[ "$RECORD_RC" = "0" ] && ok "false-refusal: 'prefix #N' is not a closing ref (rc 0)" || bad "false-refusal: 'prefix #N' must not refuse (rc=$RECORD_RC, err=$RECORD_ERR)"
[ -f "$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-424340.json" ] && ok "false-refusal: 'prefix #N' record written" || bad "false-refusal: 'prefix #N' record must be written"
assert_contains "$RECORD_ERR" "no same-repo closing-issue ref" "false-refusal: 'prefix #N' reached arm (c), not a tier bind"
STUB_BODY='This discloses #424341 but does not close it.' run_record_verdict clean-micro "daniel-ospina/agent-infra" 424341 "$SHA"
[ "$RECORD_RC" = "0" ] && ok "false-refusal: 'discloses #N' is not a closing ref (rc 0)" || bad "false-refusal: 'discloses #N' must not refuse (rc=$RECORD_RC, err=$RECORD_ERR)"
STUB_BODY='Unresolved #424342 remains open.' run_record_verdict clean-micro "daniel-ospina/agent-infra" 424342 "$SHA"
[ "$RECORD_RC" = "0" ] && ok "false-refusal: 'unresolved #N' is not a closing ref (rc 0)" || bad "false-refusal: 'unresolved #N' must not refuse (rc=$RECORD_RC, err=$RECORD_ERR)"
unset STUB_LABELS_DIR STUB_LABELS
rm -rf "$T/labels"

# 9. #980 argv/env fail-closed guard ─────────────────────────────
# The second-model flag/env surface was REMOVED. Its removal must fail CLOSED:
# exit 2, a named message, and NO record written. The defect class it guards:
# only $1..$4 are read, so a stale trailing flag was silently dropped and the
# record was still written with rc=0 (a false green: the caller believes
# evidence was captured; none was).
# Adversarial-domain rule: every declared refusal class is covered by a test —
# and the test must be REGRESSION-SENSITIVE, i.e. it must fail if the guard is
# reverted. Two classes (9.2, 9.3) are ALSO caught downstream by the pre-existing
# "repo must be owner/name" validator, so rc=2 alone would pass either way;
# those groups therefore assert the NAMED message, which only the guard emits.
# (Verified against the pre-change script: classes 1/4/5/6 fail without the
# guard; 2/3 pass on rc alone and are only caught by the message assertion.)
run_record_raw() { # <pr> <sha> [args...] verbatim; env via SM_ENV_MODEL / SM_ENV_IND
    local pr="$1" sha="$2"; shift 2
    local rcfile="$T/grc" errfile="$T/gerr"
    : > "$errfile"
    (
        export HOME="$F_HOME"
        export PATH="$T/bin:$PATH"
        export GH_STUB_LOG="$LOG"
        [ -n "${SM_ENV_MODEL:-}" ] && export SECOND_MODEL_GATE_MODEL="$SM_ENV_MODEL"
        [ -n "${SM_ENV_IND:-}" ]   && export SECOND_MODEL_GATE_INDEPENDENT="$SM_ENV_IND"
        rc=0
        bash "$RECORD" "$pr" "$sha" "$@" 2>"$errfile" || rc=$?
        printf '%s' "$rc" > "$rcfile"
    )
    RECORD_RC="$(cat "$rcfile" 2>/dev/null || echo 99)"
    RECORD_ERR="$(cat "$errfile" 2>/dev/null || true)"
}
rec_path() { printf '%s/.pi/agent/reviews/daniel-ospina-agent-infra-%s.json' "$F_HOME" "$1"; }
assert_refused() { # <pr> <label>
    [ "$RECORD_RC" = "2" ] && ok "guard: $2 refuses (rc 2)" || bad "guard: $2 (rc=$RECORD_RC, want 2)"
    if [ -f "$(rec_path "$1")" ]; then bad "guard: $2 wrote a record"; else ok "guard: $2 writes no record"; fi
}

# 9.1 full stale flag pair, trailing (the documented stale invocation).
run_record_raw 424501 "$SHA" clean "daniel-ospina/agent-infra" \
    --second-model openrouter/anthropic/claude-opus-4.8 --second-model-independent yes
assert_refused 424501 "trailing --second-model pair"
assert_contains "$RECORD_ERR" "second-model subsystem" "guard: refusal names the removed subsystem"

# 9.2 the flag in the REPO slot. rc=2 alone does NOT prove the guard ran —
# the pre-existing repo-format validator also refuses it — so this asserts the
# guard's NAMED message, which is what a revert would remove.
run_record_raw 424502 "$SHA" clean --second-model somewhere
assert_refused 424502 "--second-model in the REPO slot"
assert_contains "$RECORD_ERR" "second-model subsystem" \
    "guard: REPO-slot refusal names the removed subsystem (not the repo-format error)"

# 9.3 --second-model-independent alone (same downstream-fallback caveat as 9.2).
run_record_raw 424503 "$SHA" clean --second-model-independent yes
assert_refused 424503 "--second-model-independent alone"
assert_contains "$RECORD_ERR" "second-model subsystem" \
    "guard: --second-model-independent refusal names the removed subsystem"

# 9.4 any other unknown dashed option.
run_record_raw 424504 "$SHA" clean "daniel-ospina/agent-infra" --bogus-flag
assert_refused 424504 "unknown option"
assert_contains "$RECORD_ERR" "unknown option" "guard: unknown option is named"

# 9.5 over-arity — the old parser truncated silently.
run_record_raw 424505 "$SHA" clean "daniel-ospina/agent-infra" extra-positional
assert_refused 424505 "five positionals"
assert_contains "$RECORD_ERR" "too many arguments" "guard: over-arity is named"

# 9.6 removed env var: SECOND_MODEL_GATE_MODEL (was silently ignored).
SM_ENV_MODEL=openrouter/some-model run_record_raw 424506 "$SHA" clean "daniel-ospina/agent-infra"
assert_refused 424506 "SECOND_MODEL_GATE_MODEL set"
assert_contains "$RECORD_ERR" "SECOND_MODEL_GATE_MODEL" "guard: the offending env var is named"

# 9.7 removed env var: SECOND_MODEL_GATE_INDEPENDENT.
SM_ENV_IND=yes run_record_raw 424507 "$SHA" clean "daniel-ospina/agent-infra"
assert_refused 424507 "SECOND_MODEL_GATE_INDEPENDENT set"
assert_contains "$RECORD_ERR" "SECOND_MODEL_GATE_INDEPENDENT" "guard: the offending env var is named"

# 9.8-9.10 positive controls — the guard must not break legitimate invocations.
run_record_raw 424508 "$SHA" --force-stale clean "daniel-ospina/agent-infra"
[ "$RECORD_RC" = "0" ] && ok "guard: --force-stale leading still records (rc 0)" || bad "guard: --force-stale leading (rc=$RECORD_RC)"
[ -f "$(rec_path 424508)" ] && ok "guard: --force-stale leading wrote a record" || bad "guard: --force-stale leading wrote no record"

run_record_raw 424509 "$SHA" clean "daniel-ospina/agent-infra" --force-stale
[ "$RECORD_RC" = "0" ] && ok "guard: --force-stale trailing still records (rc 0)" || bad "guard: --force-stale trailing (rc=$RECORD_RC)"
[ -f "$(rec_path 424509)" ] && ok "guard: --force-stale trailing wrote a record" || bad "guard: --force-stale trailing wrote no record"

run_record_raw 424510 "$SHA" clean "daniel-ospina/agent-infra"
[ "$RECORD_RC" = "0" ] && ok "guard: plain 4-positional form still records (rc 0)" || bad "guard: plain form (rc=$RECORD_RC)"
[ -f "$(rec_path 424510)" ] && ok "guard: plain form wrote a record" || bad "guard: plain form wrote no record"
echo "── 11. #2982: diff binding (reviewed artifact = the diff) ──────"
D_F="$T/diff.txt"; printf 'diff --git a/x b/x\n+hello\n' > "$D_F"
DH="$(openssl dgst -sha256 < "$D_F" | awk '{print $NF}')"
D_F2="$T/diff2.txt"; printf 'diff --git a/x b/x\n+other\n' > "$D_F2"
DH2="$(openssl dgst -sha256 < "$D_F2" | awk '{print $NF}')"
STALE="$(printf 'b%.0s' $(seq 1 40))"
Q2() { printf '%s/.pi/agent/reviews/daniel-ospina-agent-infra-%s.json' "$F_HOME" "$1"; }

# 11.1 normal path: the record and the signed marker both carry the diff hash.
run_record_diff 424500 "$SHA" "PR body" "$D_F"
[ "$RECORD_RC" = "0" ] && ok "11.1 normal record succeeds" || bad "11.1 normal record (rc=$RECORD_RC)"
assert_contains "$(cat "$(Q2 424500)" 2>/dev/null)" "\"diff_sha256\":\"$DH\"" "11.1 record carries diff_sha256"
assert_contains "$RECORD_CAP" "diff=$DH" "11.1 posted marker carries diff="
assert_contains "$RECORD_CAP" "@ $SHA diff=$DH " "11.1 marker format: '@ <sha> diff=<hash> ('"

# 11.2 stale sha + prior evidence for the SAME diff → carry forward to the head.
PRIOR="review recorded: reviews/424501.json verdict=clean @ $STALE diff=$DH (daniel-ospina/agent-infra) sig=$(printf '%s' "review recorded: reviews/424501.json verdict=clean @ $STALE diff=$DH (daniel-ospina/agent-infra)" | openssl dgst -sha256 -hmac "$TEST_GATE_KEY" | awk '{print $NF}')"
run_record_diff 424501 "$STALE" "body

$PRIOR" "$D_F"
[ "$RECORD_RC" = "0" ] && ok "11.2 stale sha + same diff carries forward (rc 0)" || bad "11.2 carry-forward (rc=$RECORD_RC, err=$RECORD_ERR)"
assert_contains "$RECORD_ERR" "carry-forward" "11.2 explains the carry-forward"
assert_contains "$(cat "$(Q2 424501)" 2>/dev/null)" "\"head_sha\":\"$SHA\"" "11.2 re-records against the CURRENT head"
assert_contains "$RECORD_CAP" "@ $SHA diff=$DH " "11.2 posted marker binds the current head + the same diff"

# 11.3 stale sha + prior evidence for a DIFFERENT diff → still refused (exit 3).
# The prior marker's sig must be a WELL-FORMED 64-hex value, or the carry-forward
# shape check rejects it on the SIG and this case would pass for the wrong
# reason — deleting the diff comparison would leave the suite green. (It did:
# an 8-hex `sig=deadbeef` fixture made this test vacuous until #784's review.)
PRIOR3="review recorded: reviews/424502.json verdict=clean @ $STALE diff=$DH2 (daniel-ospina/agent-infra) sig=$(printf '%064d' 0)"
rm -f "$(Q2 424502)"
run_record_diff 424502 "$STALE" "body

$PRIOR3" "$D_F"
[ "$RECORD_RC" = "3" ] && ok "11.3 stale sha + CHANGED diff still refuses (rc 3)" || bad "11.3 changed-diff refusal (rc=$RECORD_RC)"
[ ! -f "$(Q2 424502)" ] && ok "11.3 no record written when the diff changed" || bad "11.3 wrote a record for an unreviewed diff"
assert_contains "$RECORD_ERR" "cannot be shown unchanged" "11.3 names the reason"

# 11.4 stale sha, no prior evidence at all → refused (pre-#2982 behaviour kept).
rm -f "$(Q2 424503)"
run_record_diff 424503 "$STALE" "body with no markers" "$D_F"
[ "$RECORD_RC" = "3" ] && ok "11.4 stale sha + no prior evidence refuses (rc 3)" || bad "11.4 no-evidence refusal (rc=$RECORD_RC)"

# 11.5 diff fetch unavailable → legacy sha-only marker (gate's sha path governs).
run_record_diff 424504 "$SHA" "PR body" "$D_F" "1"
[ "$RECORD_RC" = "0" ] && ok "11.5 diff fetch failure still records (rc 0)" || bad "11.5 diff-fail record (rc=$RECORD_RC)"
if grep -qF "diff=" <<<"$RECORD_CAP"; then bad "11.5 legacy marker must not carry diff="; else ok "11.5 falls back to a legacy sha-only marker"; fi
assert_contains "$RECORD_ERR" "could not compute this PR's diff hash" "11.5 warns that the marker cannot carry forward"
if grep -q '"diff_sha256"' "$(Q2 424504)" 2>/dev/null; then bad "11.5 record must omit diff_sha256"; else ok "11.5 record omits diff_sha256"; fi

# 11.6 #784 — --force-stale must NOT mint a diff-binding marker. A stale sha's
# diff cannot be shown unchanged, so emitting diff= would create a
# (stale_sha, live_diff) pair that never coexisted — and rule (b) accepts on
# diff-equality ALONE, so the gate would accept it and attest to an unreviewable
# revision. REGRESSION-SENSITIVE: before the fix this marker carried diff=.
rm -f "$(Q2 424505)"
run_record_diff 424505 "$STALE" "body with no markers" "$D_F" 0 --force-stale
[ "$RECORD_RC" = "0" ] && ok "11.6 #784 --force-stale still records (rc 0)" || bad "11.6 #784 --force-stale record (rc=$RECORD_RC)"
[ -f "$(Q2 424505)" ] && ok "11.6 #784 the record is still written (force-stale stays usable)" || bad "11.6 #784 record not written"
if grep -qF "diff=" <<<"$RECORD_CAP"; then bad "11.6 #784 --force-stale must NOT emit diff= (rule (b) would accept a pair that never coexisted)"; else ok "11.6 #784 --force-stale marker is legacy sha-only"; fi
if grep -q '"diff_sha256"' "$(Q2 424505)" 2>/dev/null; then bad "11.6 #784 record must omit diff_sha256"; else ok "11.6 #784 record omits diff_sha256"; fi

# 11.7 #784 head-fetch failure — the WIDER half of the same class. When the head
# cannot be confirmed the stale-sha guard block is skipped ENTIRELY, so the
# original fix (nested inside the verified-stale arm) never ran and DIFF_HASH
# survived into the marker: `@ <unverified_sha> diff=<live_diff>`, which rule (b)
# accepts at face value. A transient gh/API failure (403 rate-limit, 5xx, expired
# token) would thus launder ANY caller-supplied sha into a gate-accepted diff
# binding. REGRESSION-SENSITIVE: before the fix this marker carried diff=.
rm -f "$(Q2 424506)"
STUB_HEAD_SHA="API rate limit exceeded" run_record_diff 424506 "$STALE" "body with no markers" "$D_F" 0 --force-stale
[ "$RECORD_RC" = "0" ] && ok "11.7 #784 head-fetch failure still records (rc 0)" || bad "11.7 #784 head-fetch record (rc=$RECORD_RC)"
if grep -qF "diff=" <<<"$RECORD_CAP"; then bad "11.7 #784 an UNVERIFIED head must NOT be bound to a diff (rule (b) accepts it at face value)"; else ok "11.7 #784 head-fetch failure degrades to a sha-only marker"; fi
if grep -q '"diff_sha256"' "$(Q2 424506)" 2>/dev/null; then bad "11.7 #784 record must omit diff_sha256 when the head is unverified"; else ok "11.7 #784 record omits diff_sha256"; fi

# 11.8 #784 cycle-2 — a FORGED prior marker must NOT carry forward. The PR body
# is attacker-writable, so matching the SHAPE `sig=[0-9a-f]{64}` is not evidence:
# before this fix a forged line with sig=<64 zeros> was accepted, carried to the
# current head, and RE-SIGNED with the real key — a genuine attestation for a
# diff nobody reviewed, undetectable by the gate because the producer is the
# signer. REGRESSION-SENSITIVE: with a shape-only check this carries forward.
rm -f "$(Q2 424507)"
FORGED="review recorded: reviews/424507.json verdict=clean @ $STALE diff=$DH (daniel-ospina/agent-infra) sig=$(printf '%064d' 0)"
run_record_diff 424507 "$STALE" "body

$FORGED" "$D_F"
[ "$RECORD_RC" = "3" ] && ok "11.8 #784 a forged prior marker does NOT carry forward (rc 3)" || bad "11.8 #784 FORGED marker carried forward! (rc=$RECORD_RC)"
[ ! -f "$(Q2 424507)" ] && ok "11.8 #784 no record written from forged evidence" || bad "11.8 #784 wrote a record from forged evidence"
assert_contains "$RECORD_ERR" "BAD SIGNATURE" "11.8 #784 names the bad signature"

# 11.9 #784 cycle-2 — the prior verdict must MATCH. A clean-micro attestation is
# evidence of the MICRO process; it must not authorize a full clean record at a
# new head. REGRESSION-SENSITIVE: a `clean(-micro)?` pattern let it escalate.
rm -f "$(Q2 424508)"
PM="review recorded: reviews/424508.json verdict=clean-micro @ $STALE diff=$DH (daniel-ospina/agent-infra)"
PSIG="$(printf '%s' "$PM" | openssl dgst -sha256 -hmac "$TEST_GATE_KEY" | awk '{print $NF}')"
run_record_diff 424508 "$STALE" "body

$PM sig=$PSIG" "$D_F"
[ "$RECORD_RC" = "3" ] && ok "11.9 #784 a clean-micro prior does NOT authorize a clean record (rc 3)" || bad "11.9 #784 clean-micro escalated to clean (rc=$RECORD_RC)"

# 11.10 R1 (merge resolution) — the COMPOSED record must be well-formed JSON in
# EVERY field combination, and the MB+DIFF combination must actually be REACHED.
# The merge composed #1348's MB_FIELD (clean-low only) with #2982's DIFF_FIELD
# (only when a diff hash exists). A doubled comma or a dropped trailing comma
# keeps every SUBSTRING grep green, so only a JSON parse can falsify it. Before
# this test the suite reached MB+DIFF ZERO times and never parsed a record at
# all — an adversarial review found the mutants M1 (`%s%s` -> `%s,%s`), M2
# (DIFF_FIELD's trailing comma dropped) and M3 (MB_FIELD's) all left it green.
json_valid() { python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" 2>/dev/null; }
MB="cccccccccccccccccccccccccccccccccccccccc"
P2="$T/patch-compose.json"; : > "$P2"
# A: DIFF only — clean, diff hash available.
run_record_diff 424510 "$SHA" "PR body" "$D_F"
json_valid "$(Q2 424510)" && ok "11.10 A DIFF-only record is well-formed JSON" || bad "11.10 A DIFF-only record is MALFORMED: $(cat "$(Q2 424510)" 2>/dev/null)"
# B: MB+DIFF — the combination this merge exists to enable.
STUB_FILES="docs/plans/2026-09-22-x.md" GH_STUB_PATCH_BODY="$P2" STUB_DIFF_FILE="$D_F" \
  run_record_verdict clean-low "daniel-ospina/agent-infra" 424511
json_valid "$(Q2 424511)" && ok "11.10 B MB+DIFF record is well-formed JSON" || bad "11.10 B MB+DIFF record is MALFORMED: $(cat "$(Q2 424511)" 2>/dev/null)"
assert_contains "$(cat "$(Q2 424511)" 2>/dev/null)" "\"merge_base_sha\":\"$MB\"" "11.10 B carries merge_base_sha"
assert_contains "$(cat "$(Q2 424511)" 2>/dev/null)" "\"diff_sha256\":\"$DH\"" "11.10 B carries diff_sha256"
# C: MB only — clean-low with the diff fetch unavailable.
STUB_FILES="docs/plans/2026-09-22-x.md" GH_STUB_PATCH_BODY="$P2" \
  run_record_verdict clean-low "daniel-ospina/agent-infra" 424512
json_valid "$(Q2 424512)" && ok "11.10 C MB-only record is well-formed JSON" || bad "11.10 C MB-only record is MALFORMED: $(cat "$(Q2 424512)" 2>/dev/null)"
# D: NEITHER — clean, diff fetch forced to fail.
run_record_diff 424513 "$SHA" "PR body" "$D_F" "1"
json_valid "$(Q2 424513)" && ok "11.10 D NEITHER record is well-formed JSON" || bad "11.10 D NEITHER record is MALFORMED: $(cat "$(Q2 424513)" 2>/dev/null)"
# Two cleanups, for two DIFFERENT reasons:
#  (1) PR NUMBERS. §10 (#1348) runs AFTER this section and its C1 vector asserts
#      "writes no record" for PR 424600. Reusing any number up there would leave a
#      record behind and make C1 fail for a reason that has nothing to do with C1.
#      That is why these use 424510-424513 — a range this suite does not otherwise touch.
#  (2) The env-prefix assignments LEAK: `VAR=val func` does not restore VAR if it
#      was previously UNSET (bash semantics), so STUB_FILES/STUB_DIFF_FILE would
#      persist into §10 and make its code-bearing vectors see a docs-only diff.
unset STUB_FILES STUB_DIFF_FILE GH_STUB_PATCH_BODY STUB_HEAD_SHA P2 MB

# ─────────────────────────────────────────────────────────────────────────
# 10. #1348 clean-low content-shape guard — ADVERSARIAL DOMAIN
# ─────────────────────────────────────────────────────────────────────────
# Correctness claim: a clean-low record cannot be obtained for a revision
# whose diff is not provably content-only. Every declared class (C1-C6 in
# docs/plans/2026-09-22-issue-1348-clean-low-verdict.md) has its own vector.
#
# MUTATION DISCIPLINE — why this section is not vacuous. Against the
# PRE-CHANGE script every clean-low vector is RED for one uninteresting reason
# (the verdict is rejected at the `case` with rc 2), which alone would prove
# nothing about the guard: a guard that refused EVERY clean-low would pass the
# whole attack suite. So the section pins THREE things, not one:
#   (i)   POSITIVE controls — legitimate content-only diffs must record (rc 0);
#   (ii)  attack vectors — must refuse with the GUARD's rc 4 and its named
#         message, never the verdict `case`'s rc 2;
#   (iii) MUTATION HARNESS (§10.9) — two mutants, built from THIS script:
#         neuter the guard  → the code-bearing attack must go GREEN (rc 0),
#         i.e. the suite would fail if the guard were removed; revert the
#         verdict arm → the positive vector must go RED (rc 2), i.e. the
#         positive vector is genuinely red against the pre-change script.
# Only (iii) makes the suite regression-sensitive; (i)+(ii) alone would not.
echo "── 10. #1348 clean-low content-shape guard ──────────────────────"

low_path_ok() { # <path> — direct unit call on the sourceable predicate
    bash -c 'source "$1" >/dev/null 2>&1 || exit 1; clean_low_path_ok "$2"' _ "$RECORD" "$1" 2>/dev/null
}
# <pr> <label> [want-rc] — refusal assertions: exit code AND no record written.
assert_low_refused() {
    local pr="$1" label="$2" want="${3:-4}"
    [ "$RECORD_RC" = "$want" ] && ok "$label (rc $want)" || bad "$label (rc=$RECORD_RC, want $want)"
    [ -f "$(rec_path "$pr")" ] && bad "$label wrote a record" || ok "$label writes no record"
}

# ── 10.1 C1 code-bearing diffs (accept-side discrimination) ─────────────
STUB_FILES="src/app.ts" run_record_verdict clean-low "daniel-ospina/agent-infra" 424600
assert_low_refused 424600 "C1 code-bearing src/app.ts refuses"
assert_contains "$RECORD_ERR" "NOT content-only" "C1 refusal names the content-shape cause (not the verdict case)"
[ "$RECORD_RC" != "2" ] && ok "C1 refusal is the guard's rc 4, not the verdict case's rc 2" || bad "C1 refused at the verdict case instead of the guard"
STUB_FILES="package.json" run_record_verdict clean-low "daniel-ospina/agent-infra" 424601
assert_low_refused 424601 "C1 build manifest package.json refuses"
STUB_FILES="requirements.txt" run_record_verdict clean-low "daniel-ospina/agent-infra" 424602
assert_low_refused 424602 "C1 root build input requirements.txt refuses"

# ── 10.2 C2 enforcement inputs — refused even under a docs-looking prefix ─
for _spec in \
    "424610:scripts/record-review.sh:gate script" \
    "424611:extensions/review-enforcer/index.ts:gate extension" \
    "424612:.github/workflows/ai-review-gate.yml:required-check workflow" \
    "424613:skills/code-review/SKILL.md:skill instruction layer" \
    "424614:templates/AGENTS.base.md:materialized instruction template" \
    "424615:AGENTS.md:always-loaded instruction file" \
    "424616:MEMORY.md:always-loaded memory file" \
    "424617:VENDOR.md:always-loaded vendored-doc file" \
    "424618:docs/evil.sh:executable under a docs prefix" \
    "424619:docs/.github/workflows/x.yml:config under a docs prefix" ; do
    _pr="${_spec%%:*}"; _rest="${_spec#*:}"; _path="${_rest%%:*}"; _label="${_rest#*:}"
    STUB_FILES="$_path" run_record_verdict clean-low "daniel-ospina/agent-infra" "$_pr"
    assert_low_refused "$_pr" "C2 $_label ($_path) refuses"
done
# Mixed diffs: one enforcement path poisons an otherwise content-only set.
STUB_FILES=$'docs/a.md\ndocs/b.css\nAGENTS.md' run_record_verdict clean-low "daniel-ospina/agent-infra" 424620
assert_low_refused 424620 "C2 one enforcement path in a mixed diff refuses"

# ── 10.3 C3 unverifiable shape — FAIL-CLOSED ────────────────────────────
run_record_verdict clean-low "" 424630
assert_low_refused 424630 "C3 repo undetectable refuses"
assert_contains "$RECORD_ERR" "repo undetectable or gh missing" "C3 repo-less refusal names the cause"
# C3 (`gh` ABSENT from PATH entirely, not merely a stubbed failure). The guard's
# condition is `-z $REPO || ! command -v gh`; every other vector has a stub gh on
# PATH, so without this one the SECOND disjunct is untested — deleting it leaves
# the suite green.
#
# The path must lose `gh` WITHOUT losing everything else in the directory `gh`
# happens to live in. Dropping the whole directory (the obvious filter) is
# runner-dependent: on a usrmerge distro `/bin` is a symlink to `/usr/bin`, so a
# runner whose `gh` is `/usr/bin/gh` loses `bash`, `jq`, `date` and `mktemp` with
# it and the script dies with **127** instead of refusing 4 — green on macOS
# (`gh` in `/opt/homebrew/bin`), red on the ubuntu runner. That is the exact
# failure this vector produced in CI on its first main push.
#
# So: replace each gh-bearing directory with a SHADOW directory that re-exports
# its executable files (symlinked) minus `gh` itself, and keep every directory
# that does not carry `gh` as-is. Cost is a few hundred symlinks; the effect is
# that `command -v gh` is the only thing the PATH loses.
run_record_no_gh() { # <verdict> <repo> <pr>
    local verdict="$1" repo="$2" pr="$3" rcfile="$T/nrc" errfile="$T/nerr"
    local shadow="$T/nogh-bin" _dir _cand _base _kept=""
    rm -rf "$shadow"; mkdir -p "$shadow"
    while IFS= read -r _dir; do
        [ -n "$_dir" ] || continue
        if [ -x "$_dir/gh" ]; then
            for _cand in "$_dir"/*; do
                [ -f "$_cand" ] && [ -x "$_cand" ] || continue
                _base="${_cand##*/}"
                [ "$_base" = "gh" ] && continue
                [ -e "$shadow/$_base" ] || ln -s "$_cand" "$shadow/$_base" 2>/dev/null || true
            done
        else
            _kept="$_kept$_dir:"
        fi
    done <<< "$(printf '%s' "$PATH" | tr ':' '\n')"
    # Fail loudly rather than silently testing the wrong thing: if the shadow
    # cannot run the script, or still resolves gh, this vector would pass for a
    # reason of its own. Two details matter:
    #   * each probe runs in a SUBSHELL whose first statement SETS the PATH and
    #     then clears bash's command hash (`hash -r`). A `PATH=… command -v x`
    #     prefix assignment does NOT clear the hash, so on a host where bash has
    #     already resolved `x` the probe consults the stale entry instead of the
    #     shadow PATH and reports the opposite of the truth.
    #   * RECORD_RC is poisoned on a vacuity hit so the assertions that follow
    #     cannot pass on the PREVIOUS vector's stale values (that vector's
    #     refusal carries the same message this one asserts).
    if ! ( PATH="$shadow:${_kept%:}"; hash -r; command -v bash >/dev/null 2>&1 ); then
        bad "C3 gh-absent vector: the shadow PATH cannot resolve bash — the vector would be vacuous"
        RECORD_RC=99; RECORD_ERR=""; return 0
    fi
    if ( PATH="$shadow:${_kept%:}"; hash -r; command -v gh >/dev/null 2>&1 ); then
        bad "C3 gh-absent vector: gh is STILL resolvable — the vector would be vacuous"
        RECORD_RC=99; RECORD_ERR=""; return 0
    fi
    rm -f "$errfile"
    (
        export HOME="$F_HOME" PATH="$shadow:${_kept%:}" GH_STUB_LOG="$LOG"
        rc=0
        bash "$RECORD" "$pr" "$SHA" "$verdict" "$repo" 2>"$errfile" || rc=$?
        printf '%s' "$rc" > "$rcfile"
    ) 2>/dev/null
    RECORD_RC="$(cat "$rcfile" 2>/dev/null || echo 99)"
    RECORD_ERR="$(cat "$errfile" 2>/dev/null || true)"
}
run_record_no_gh clean-low "daniel-ospina/agent-infra" 424629
assert_low_refused 424629 "C3 gh absent from PATH refuses"
assert_contains "$RECORD_ERR" "repo undetectable or gh missing" "C3 the gh-absent refusal names the cause (only the new guard emits this)"
STUB_FILES="docs/a.md" STUB_COMPARE_FAIL=1 run_record_verdict clean-low "daniel-ospina/agent-infra" 424631
assert_low_refused 424631 "C3 compare API failure refuses"
# The merge base is the commit the certified diff is taken FROM, so a response
# without one must refuse (an absent merge base is unverifiable content, not an
# empty diff).
STUB_FILES="docs/a.md" STUB_MERGE_BASE="" run_record_verdict clean-low "daniel-ospina/agent-infra" 424638
assert_low_refused 424638 "C3 a response with no merge base refuses"
assert_contains "$RECORD_ERR" "read no merge base" "C3 the merge-base refusal names the cause"
STUB_FILES="docs/a.md" STUB_MERGE_BASE="not-a-sha" run_record_verdict clean-low "daniel-ospina/agent-infra" 424639
assert_low_refused 424639 "C3 a malformed merge base refuses"
STUB_FILES="" run_record_verdict clean-low "daniel-ospina/agent-infra" 424632
assert_low_refused 424632 "C3 empty/absent file list refuses"
STUB_FILES="docs/a.md" STUB_META_FAIL=1 run_record_verdict clean-low "daniel-ospina/agent-infra" 424633
assert_low_refused 424633 "C3 PR meta read failure refuses"
STUB_FILES="docs/a.md" STUB_CHANGED_FILES=2 run_record_verdict clean-low "daniel-ospina/agent-infra" 424634
assert_low_refused 424634 "C3 list short of .changed_files refuses (truncation/forgery)"
STUB_FILES="docs/a.md" STUB_CHANGED_FILES=0 run_record_verdict clean-low "daniel-ospina/agent-infra" 424636
assert_low_refused 424636 "C3 zero/absent .changed_files refuses (the truncation detector cannot run)"
STUB_FILES="docs/a.md" STUB_CHANGED_FILES=abc run_record_verdict clean-low "daniel-ospina/agent-infra" 424637
assert_low_refused 424637 "C3 unparseable .changed_files refuses"
CAPFILES="$(printf 'docs/cap-%s.md\n' $(seq 1 300))"
STUB_FILES="$CAPFILES" run_record_verdict clean-low "daniel-ospina/agent-infra" 424635
assert_low_refused 424635 "C3 file list AT the 300-entry compare cap refuses (may be truncated)"

# ── 10.4 C4 revision mismatch ───────────────────────────────────────────
run_record_raw 424640 "$SHA" clean-low "daniel-ospina/agent-infra" --force-stale
[ "$RECORD_RC" = "2" ] && ok "C4 clean-low + --force-stale refused (rc 2)" || bad "C4 --force-stale (rc=$RECORD_RC, want 2)"
assert_contains "$RECORD_ERR" "incompatible with the clean-low verdict" "C4 refusal names the incompatibility (only the new guard emits this)"
[ -f "$(rec_path 424640)" ] && bad "C4 --force-stale wrote a record" || ok "C4 --force-stale writes no record"
STUB_FILES="docs/a.md" STUB_META_HEAD="$(printf 'c%.0s' $(seq 1 40))" run_record_verdict clean-low "daniel-ospina/agent-infra" 424641
assert_low_refused 424641 "C4 head != recorded sha refuses"
assert_contains "$RECORD_ERR" "is not the current head" "C4 head-mismatch refusal names the cause"

# ── 10.5 C5 path-shape spoofing ─────────────────────────────────────────
for _spec in \
    "424650:notes.md.ts:extension is a substring, not a suffix" \
    "424651:docs/x.md.bak:extension suffix is .bak" \
    "424652:docs/../src/a.ts:path traversal" \
    "424653:docs//x.md:empty segment" \
    "424654:/docs/x.md:absolute path" \
    "424655:docs/./x.md:dot segment" \
    "424656:docs/x.mdx:mdx compiles JSX to JS" \
    "424657:docs/x.html:html can carry script" ; do
    _pr="${_spec%%:*}"; _rest="${_spec#*:}"; _path="${_rest%%:*}"; _label="${_rest#*:}"
    STUB_FILES="$_path" run_record_verdict clean-low "daniel-ospina/agent-infra" "$_pr"
    assert_low_refused "$_pr" "C5 $_label ($_path) refuses"
done
# Direct predicate vectors for the control characters a TSV row cannot carry
# faithfully. DEFENCE IN DEPTH, not live coverage: the guard's own rows come from
# `jq @tsv`, which ESCAPES \t and \n, so a real control character cannot reach the
# class test from production and an ESCAPED one is a literal in-class filename.
# Both halves are pinned: the raw form refuses (the arm exists), and the escaped
# form is ADMITTED (the live production behaviour — §10.8).
low_path_ok "$(printf 'docs/a\nb.md')" && bad "C5 newline inside a filename must refuse" || ok "C5 raw newline inside a filename refuses (defence in depth)"
low_path_ok "$(printf 'docs/a\tb.md')" && bad "C5 tab inside a filename must refuse" || ok "C5 raw tab inside a filename refuses (defence in depth)"
# A tab-split row: 4 TSV fields → malformed framing, refused before any class test.
STUB_COMPARE="$(printf 'added\tdocs/a.md\tscripts/evil.sh')x" run_record_verdict clean-low "daniel-ospina/agent-infra" 424658
assert_low_refused 424658 "C5 old-path poisoned row refuses"
STUB_COMPARE="$(printf 'added\tdocs/a.md\textra\tfields')" run_record_verdict clean-low "daniel-ospina/agent-infra" 424659
assert_low_refused 424659 "C5 malformed (NF!=3) row refuses"

# ── 10.6 C6 row framing / old path ──────────────────────────────────────
STUB_COMPARE="$(printf 'renamed\tdocs/evil.md\tscripts/evil.sh')" run_record_verdict clean-low "daniel-ospina/agent-infra" 424660
assert_low_refused 424660 "C6 rename with a code OLD path refuses"
STUB_COMPARE="$(printf 'renamed\tdocs/evil.md\t')" run_record_verdict clean-low "daniel-ospina/agent-infra" 424661
assert_low_refused 424661 "C6 rename without its old path refuses"
STUB_COMPARE="$(printf 'copied\tdocs/a.md\tdocs/b.md')" run_record_verdict clean-low "daniel-ospina/agent-infra" 424662
assert_low_refused 424662 "C6 copied row refuses (copy source is absent from the diff — refused by ABSENCE from the status enum)"
assert_contains "$RECORD_ERR" "malformed diff row" "C6 the copied refusal is the framing arm, not the shape arm"
STUB_COMPARE="$(printf 'junked\tdocs/a.md\t')" run_record_verdict clean-low "daniel-ospina/agent-infra" 424663
assert_low_refused 424663 "C6 unknown status enum refuses"
STUB_COMPARE="$(printf 'added\t\t')" run_record_verdict clean-low "daniel-ospina/agent-infra" 424664
assert_low_refused 424664 "C6 empty filename refuses"

# ── 10.7 POSITIVE controls — the legitimate path must actually record ────
# Without these, a guard that refused everything would pass §10.1-10.6.
PATCH="$T/patch-cleanlow.json"
: > "$PATCH"
export AI_REVIEW_GATE_KEY="test-key-clean-low"
STUB_FILES="docs/plans/2026-09-22-x.md" GH_STUB_PATCH_BODY="$PATCH" run_record_verdict clean-low "daniel-ospina/agent-infra" 424670
QLOW="$(rec_path 424670)"
[ "$RECORD_RC" = "0" ] && ok "positive: content-only docs diff records (rc 0)" || bad "positive: content-only must record (rc=$RECORD_RC, err=$RECORD_ERR)"
[ -f "$QLOW" ] && ok "positive: record written" || bad "positive: record written"
assert_contains "$(cat "$QLOW" 2>/dev/null || true)" '"verdict":"clean-low"' "positive: record carries verdict clean-low"
assert_contains "$(cat "$QLOW" 2>/dev/null || true)" "\"head_sha\":\"$SHA\"" "positive: record is head-bound"
# #1348 content pin: the attestation is the three-dot diff compare/<base>...<head>,
# whose CONTENT is identified by the merge base — not by the base branch's tip,
# which moves on every unrelated merge while the certified diff is unchanged. The
# record must carry the merge base, or a post-record `gh pr edit --base` silently
# changes what merges while the head sha still matches.
assert_contains "$(cat "$QLOW" 2>/dev/null || true)" '"merge_base_sha":"cccccccccccccccccccccccccccccccccccccccc"' "positive: clean-low record is CONTENT-bound (merge base)"
# The certified diff must be read at the merge base's compare, i.e. against the
# BASE — not against the head. Nothing else in the suite observes that argument,
# so flipping it to $META_HEAD (which makes the base pin certify a diff the guard
# never read) would otherwise stay green.
assert_contains "$(cat "$LOG" 2>/dev/null || true)" "compare/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb...$SHA" "positive: the diff is read against the BASE, not the head"
# The FIELD the guard reads is the token that distinguishes this binding from the
# rejected tip binding, and the stub answers any `compare/` call with a canned
# mb line — so a one-token rewrite back to `.base.sha` (which would pin the base
# branch's moving tip and expire every record on the next unrelated merge) leaves
# the record assertion above GREEN. Only the argv observes it.
assert_contains "$(cat "$LOG" 2>/dev/null || true)" ".merge_base_commit.sha" "positive: the diff read pins the MERGE BASE field, not the base tip"
assert_contains "$(cat "$PATCH" 2>/dev/null || true)" "verdict=clean-low @ $SHA" "positive: signed marker posted with the clean-low verdict"
# Multi-path, mixed content extensions, nested docs, root prose.
STUB_FILES=$'docs/a.md\ndocs/nested/deep/b.rst\ndocs/c.css\nREADME.md\nCHANGELOG.md' run_record_verdict clean-low "daniel-ospina/agent-infra" 424671
[ "$RECORD_RC" = "0" ] && ok "positive: multi-path mixed content extensions record (rc 0)" || bad "positive: multi-path (rc=$RECORD_RC, err=$RECORD_ERR)"
# A delete+add of ONE path is two rows for one distinct path — must not be
# falsely refused by the changed_files equality check.
STUB_COMPARE="$(printf 'removed\tdocs/a.md\t\nadded\tdocs/a.md\t')" STUB_CHANGED_FILES=1 run_record_verdict clean-low "daniel-ospina/agent-infra" 424672
[ "$RECORD_RC" = "0" ] && ok "positive: delete+add of one path records (rows != distinct paths)" || bad "positive: delete+add (rc=$RECORD_RC, err=$RECORD_ERR)"
# A rename WITHIN the class must record (both ends are content).
STUB_COMPARE="$(printf 'renamed\tdocs/new.md\tdocs/old.md')" run_record_verdict clean-low "daniel-ospina/agent-infra" 424673
[ "$RECORD_RC" = "0" ] && ok "positive: content-to-content rename records" || bad "positive: content rename (rc=$RECORD_RC, err=$RECORD_ERR)"
# clean/clean-micro are untouched by the new guard.
STUB_FILES="src/app.ts" run_record_verdict clean "daniel-ospina/agent-infra" 424674
[ "$RECORD_RC" = "0" ] && ok "positive: clean is not shape-guarded (rc 0 on a code diff)" || bad "positive: clean must not be shape-guarded (rc=$RECORD_RC)"
# The content pin is clean-low only: clean/clean-micro keep their record shape
# byte-identical (their base-blindness is pre-existing — agent-infra #1362).
QCLEAN="$(rec_path 424674)"
if [ -f "$QCLEAN" ] && ! grep -qF '"merge_base_sha"' "$QCLEAN"; then
  ok "positive: clean record carries no merge_base_sha (shape unchanged)"
else
  bad "positive: clean record must EXIST and carry no merge_base_sha (shape unchanged)"
fi
unset AI_REVIEW_GATE_KEY

# ── 10.8 direct predicate corpus (no gh; pins the class itself) ──────────
for _spec in \
    "docs/plans/x.md:PASS" "docs/a.css:PASS" "docs/deep/nested/x.rst:PASS" \
    "docs/x.markdown:PASS" "docs/x.txt:PASS" "docs/x.adoc:PASS" "docs/x.scss:PASS" \
    "README.md:PASS" "CHANGELOG.md:PASS" "CONTRIBUTING.md:PASS" "SECURITY.md:PASS" "CODE_OF_CONDUCT.md:PASS" \
    "docs/x.md.ts:REFUSE" "notes.md.ts:REFUSE" "docs/evil.sh:REFUSE" "docs/x.py:REFUSE" \
    "AGENTS.md:REFUSE" "MEMORY.md:REFUSE" "VENDOR.md:REFUSE" "requirements.txt:REFUSE" \
    "LICENSE:REFUSE" "src/README.md:REFUSE" "skills/x.md:REFUSE" "templates/x.md:REFUSE" \
    "docs/../src/a.ts:REFUSE" "docs//x.md:REFUSE" "/docs/x.md:REFUSE" "docs/./x.md:REFUSE" \
    "docs/x.mdx:REFUSE" "docs/x.html:REFUSE" "docs:REFUSE" "docs/:REFUSE" \
    "docs/c\\nd.md:PASS" "docs/c\\td.md:PASS" ; do
    _p="${_spec%%:*}"; _want="${_spec#*:}"
    if low_path_ok "$_p"; then _got="PASS"; else _got="REFUSE"; fi
    assert_eq "$_got" "$_want" "predicate: $_p -> $_want"
done

# ── 10.9 MUTATION HARNESS — the suite is regression-sensitive ───────────
# Two mutants built from THIS script. Without them, §10.1-10.7 prove only that
# the new code rejects or accepts; they do not prove the GUARD is load-bearing.
MUTANT_LOOSE="$T/mutant-guard-neutered.sh"
MUTANT_PRE="$T/mutant-verdict-reverted.sh"
# Portable across GNU and BSD sed: a `c\` command is not portable, so the
# loose mutant neutralises the guard's DECISION at its call site instead.
sed 's#clean_low_shape_ok "\$ROWS"#true#' "$RECORD" > "$MUTANT_LOOSE"
sed 's#^  clean|clean-micro|clean-low) ;;#  clean|clean-micro) ;;#' "$RECORD" > "$MUTANT_PRE"
bash -n "$MUTANT_LOOSE" && ok "mutation: neutered-guard mutant parses" || bad "mutation: neutered-guard mutant is not valid bash"
bash -n "$MUTANT_PRE" && ok "mutation: reverted-verdict mutant parses" || bad "mutation: reverted-verdict mutant is not valid bash"
if cmp -s "$MUTANT_LOOSE" "$RECORD"; then bad "mutation: guard-neutering sed did not change the script"; else ok "mutation: guard-neutering sed changed the script"; fi
if cmp -s "$MUTANT_PRE" "$RECORD"; then bad "mutation: reverted-verdict sed did not change the script"; else ok "mutation: reverted-verdict sed changed the script"; fi

run_mutant() { # <script> <verdict> <repo> <pr>
    local script="$1" rcfile="$T/mrc"
    : > "$T/merr"
    (
        export HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG"
        rc=0
        bash "$script" "$4" "$SHA" "$2" "$3" >/dev/null 2>"$T/merr" || rc=$?
        printf '%s' "$rc" > "$rcfile"
    ) 2>/dev/null
    MUTANT_RC="$(cat "$rcfile" 2>/dev/null || echo 99)"
    MUTANT_ERR="$(cat "$T/merr" 2>/dev/null || true)"
}
# (a) Neutering the guard must let the code-bearing attack THROUGH (rc 0). If it
#     did not, §10.1 would be passing for some reason other than the guard and
#     the suite would be vacuous.
STUB_FILES="src/app.ts" run_mutant "$MUTANT_LOOSE" clean-low "daniel-ospina/agent-infra" 424680
[ "$MUTANT_RC" = "0" ] && ok "mutation(a): neutered guard ADMITS the code-bearing diff (guard is load-bearing)" || bad "mutation(a): neutered guard still refused (rc=$MUTANT_RC, err=$MUTANT_ERR) — §10.1 is not testing the guard"
# (b) Reverting the verdict arm must make the POSITIVE vector RED (rc 2) — this
#     is the durable, in-suite form of "the test fails against the pre-change
#     script": the pre-change script has no clean-low verdict at all.
STUB_FILES="docs/a.md" run_mutant "$MUTANT_PRE" clean-low "daniel-ospina/agent-infra" 424681
[ "$MUTANT_RC" = "2" ] && ok "mutation(b): pre-change verdict arm REFUSES the positive vector (rc 2 — positive vector is RED pre-change)" || bad "mutation(b): expected rc 2 without the verdict arm (rc=$MUTANT_RC)"
# (c) Sanity: the mutants do not break an unrelated verdict (`clean` still records).
STUB_FILES="src/app.ts" run_mutant "$MUTANT_LOOSE" clean "daniel-ospina/agent-infra" 424682
[ "$MUTANT_RC" = "0" ] && ok "mutation(c): mutants leave the clean path intact" || bad "mutation(c): clean path broken by mutation (rc=$MUTANT_RC)"

# ── 10.10 no gh reads for a verdict that does not need them ─────────────
run_record "daniel-ospina/agent-infra" 424690
if grep -q "compare/" "$LOG"; then
    bad "clean verdict performs no clean-low diff read"
else
    ok "clean verdict performs no clean-low diff read"
fi

echo ""
echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { echo "  ❌ FAILURES — fix and re-run"; exit 1; }
echo "  ✅ all checks passed"
exit 0
