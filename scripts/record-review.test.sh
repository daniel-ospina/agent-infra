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
    # PATCH body — capture stdin when GH_STUB_PATCH_BODY is set (#716), else swallow
    if [ -n "${GH_STUB_PATCH_BODY:-}" ]; then
        cat > "$GH_STUB_PATCH_BODY"
    else
        cat >/dev/null
    fi
    exit 0
fi
if [ "$1" = "api" ]; then
    if grep -qF -- "--jq .head.sha" <<<"$*"; then
        printf '%s' "${STUB_HEAD_SHA:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
        echo; exit 0
    fi
    if grep -qF -- "--jq .body" <<<"$*"; then
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

echo ""
echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { echo "  ❌ FAILURES — fix and re-run"; exit 1; }
echo "  ✅ all checks passed"
exit 0
