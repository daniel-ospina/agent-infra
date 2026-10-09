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
#   tortoise#7391 §13      → a FRESH `clean` record requires a VERIFIED review artifact
#                    (the current-head path used to record unconditionally);
#                    fresh repo-less `clean` is refused, and the legacy key
#                    still serves the verdicts the gate does not cover.

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
# tortoise#7391 (friction, found while adding §13): `trap 'rm -rf "$T"' EXIT` LAUNDERED the
# exit status. Under bash 3.2 an unreached `set -u`/`set -e` abort left the shell
# exiting 0 because the trap's last command succeeded — so the harness could die
# mid-run and still report success.
#
# Re-raising `$?` is NOT enough, and that is measured, not assumed: on bash 3.2.57
# an UNBOUND-VARIABLE abort under `set -u` already reads as 0 at EXIT-trap time, so
# `exit $?` re-raises 0 and the harness aborts GREEN — while
# `scripts/run-bash-shards.sh:68` decides by EXIT CODE ONLY
# (`bash "$1" || shard_errors=…`), counting the shard as a pass. The reliable
# signal is a SENTINEL set only where the harness is allowed to finish: if the
# summary never printed, the exit is non-zero whatever `$?` says. §13o pins the
# abort case and §13o2 the positive control, both against this block as written.
SUMMARY_PRINTED=0
cleanup() {
    rc=$?
    rm -rf "$T" 2>/dev/null || :
    if [ "${SUMMARY_PRINTED:-0}" = "1" ]; then exit "$rc"; fi
    echo "  ❌ this harness aborted BEFORE its summary — FAILURE, not a pass (exit forced non-zero)" >&2
    exit 1
}
trap cleanup EXIT
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
        # #1577: a STATEFUL transient failure — fail the first N calls, then serve
        # the body, so a RETRY can be shown to RECOVER. A one-shot STUB_DIFF_FAIL
        # proves only that the loop iterates; it cannot separate "retried" from
        # "retried and still refused", which is the whole point of the retry.
        if [ "${STUB_DIFF_FAIL_TIMES:-0}" != "0" ]; then
            n=0
            if [ -n "${STUB_DIFF_COUNT:-}" ] && [ -f "$STUB_DIFF_COUNT" ]; then
                n="$(cat "$STUB_DIFF_COUNT" 2>/dev/null || echo 0)"
                case "$n" in ''|*[!0-9]*) n=0 ;; esac
            fi
            n=$(( n + 1 ))
            [ -n "${STUB_DIFF_COUNT:-}" ] && printf '%s' "$n" > "$STUB_DIFF_COUNT"
            [ "$n" -le "$STUB_DIFF_FAIL_TIMES" ] && exit 1
        fi
        [ "${STUB_DIFF_FAIL:-0}" = "1" ] && exit 1
        # #1398: the DOCUMENTED 300-file cap — gh exits NON-ZERO and writes a
        # NON-EMPTY JSON error body to stdout (measured: 337 bytes on
        # tortoise#7653). The non-emptiness is the trap the producer must not
        # hash; the stub models both streams (body on stdout, exit 1).
        if [ -n "${STUB_DIFF_406_FILE:-}" ]; then cat "$STUB_DIFF_406_FILE"; exit 1; fi
        cat "${STUB_DIFF_FILE:-/dev/null}"
        exit 0
    fi
    # #1398: the base/head identity the local fallback reads from the PR object.
    # Distinct from the clean-low meta arm below (that one is a TSV of three
    # fields); this one is exactly the `[.base.sha,.head.sha,.base.ref]|@tsv` read.
    if grep -qF -- "base.sha,.head.sha" <<<"$*"; then
        [ "${STUB_LOCAL_META_FAIL:-0}" = "1" ] && exit 1
        printf '%s\t%s\t%s\n' "${STUB_LOCAL_BASE:-}" "${STUB_LOCAL_HEAD:-}" "${STUB_LOCAL_BASE_REF:-main}"
        exit 0
    fi
    # #1575 clause (E): the target head's check-runs. STUB_CHECKS_ROWS carries the TSV
    # rows the caller's --jq would emit (app.slug|name|id|status|conclusion), one
    # per line; empty/absent = an empty surface.
    if grep -qF -- "check-runs" <<<"$*"; then
        [ "${STUB_CHECKS_FAIL:-0}" = "1" ] && exit 1
        [ -n "${STUB_CHECKS_ROWS:-}" ] && printf '%s\n' "${STUB_CHECKS_ROWS}"
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
    # tortoise#7391: the review-EVIDENCE reads — an issue comment / a PR review / an
    # inline review comment by id — plus the recorded head's commit date. Each
    # emits the exact TSV shape the caller's --jq would (created_at, parent URL,
    # body). Placed here so they cannot shadow the arms above.
    #   STUB_EVIDENCE_FAIL=1  → the artifact cannot be read (404 / unreachable).
    #   STUB_EVIDENCE_PARENT  → override the parent URL (other-PR simulation).
    #   STUB_EVIDENCE_AT      → the artifact's created_at (postdate assertions).
    #   STUB_EVIDENCE_BODY    → its body (the NOT-CLEAN / marker-shape vectors).
    #     NOTE the `-` (not `:-`): an EXPLICITLY EMPTY body must be expressible,
    #     because the empty-body parse is its own adversarial case (reviewer B,
    #     cycle 2 — `:-` substitutes on empty, so §13 could not express it).
    #     The body is @tsv-ESCAPED on the way out (newlines → the two characters
    #     `\n`, tabs → `\t`, backslashes doubled), which is what jq's `@tsv` does:
    #     the real read therefore receives ONE line. Printing the body RAW made
    #     this fixture read only its FIRST LINE (measured: a 15-byte body), so a
    #     multi-line veto subject was never exercised — a fixture that does not
    #     model the read it claims to test cannot pin it (#7391 scoping cycle 3).
    #   STUB_EVIDENCE_PR      → which PR the parent names (set by the runners).
    #   STUB_REVIEW_STATE     → the 4th TSV field, emitted ONLY by the reviews arm
    #     (which is exactly what the real `evidence_fetch` does). Default APPROVED;
    #     set to CHANGES_REQUESTED / DISMISSED / PENDING to exercise the state veto.
    #   STUB_COMMIT_FAIL=1    → the head commit date is unreadable.
    if grep -qF -- "issues/comments/" <<<"$*" \
       || grep -qF -- "pulls/comments/" <<<"$*" \
       || grep -qE -- "/pulls/[0-9]+/reviews/" <<<"$*"; then
        [ "${STUB_EVIDENCE_FAIL:-0}" = "1" ] && exit 1
        _parent="${STUB_EVIDENCE_PARENT:-}"
        if [ -z "$_parent" ]; then
            _base="https://api.github.com/repos/${STUB_EVIDENCE_REPO:-daniel-ospina/agent-infra}"
            case "$*" in
                *issues/comments/*) _parent="$_base/issues/${STUB_EVIDENCE_PR:-0}" ;;
                *)                  _parent="$_base/pulls/${STUB_EVIDENCE_PR:-0}" ;;
            esac
        fi
        # The reviews arm carries GitHub's own verdict as a 4th field (the other
        # arms emit three and `read` leaves the 4th empty) — the real
        # `evidence_fetch` review arm always emits it.
        _state=""
        case "$*" in *"/pulls/"*"reviews/"*|*"/reviews/"*) _state="$(printf '\t')${STUB_REVIEW_STATE:-APPROVED}" ;; esac
        printf '%s\t%s\t%s%s\n' \
            "${STUB_EVIDENCE_AT:-2026-01-02T03:04:05Z}" \
            "$_parent" \
            "$(printf '%s' "${STUB_EVIDENCE_BODY-Reviewed the diff; no issues found.}" | awk '{ gsub(/\\/,"\\\\"); gsub(/\t/,"\\t"); printf "%s\\n", $0 }')" \
            "$_state"
        exit 0
    fi
    if grep -qF -- "commits/" <<<"$*"; then
        [ "${STUB_COMMIT_FAIL:-0}" = "1" ] && exit 1
        printf '%s\n' "${STUB_COMMIT_DATE:-2026-01-01T00:00:00Z}"
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

# tortoise#7391 — a FRESH `clean` record must name a review artifact. Every vector ABOVE
# this point that records `clean` at $SHA reaches the once-unguarded
# current-head path (the stub's STUB_HEAD_SHA default IS $SHA), so the shared
# runners hand the gate a ref the stub answers with a valid row. That keeps each
# of those vectors testing its OWN subject; the gate itself is pinned by §13,
# which drives the evidence environment explicitly through run_record_ev.
# EV_ARGS="" omits the flag (the "no evidence" arm); a non-clean verdict gets no
# ref at all, because it never reaches the gate and a record must not claim an
# `evidence` it never verified.
EV_REF="${EV_REF:-comment:7391001}"
EV_ARGS="--evidence $EV_REF"
STUB_EVIDENCE_REPO="daniel-ospina/agent-infra"

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
        export STUB_EVIDENCE_PR="$pr" STUB_EVIDENCE_REPO="daniel-ospina/agent-infra"
        rc=0
        if [ -n "$repo" ]; then
            bash "$RECORD" "$pr" "$sha" clean "$repo" $EV_ARGS || rc=$?
        else
            bash "$RECORD" "$pr" "$sha" clean $EV_ARGS || rc=$?
        fi
        printf '%s' "$rc" > "$rcfile"
    ) 2>/dev/null
    RECORD_RC="$(cat "$rcfile" 2>/dev/null || echo 99)"
}

# #513: verdict-parameterized runner capturing rc AND stderr (the clean-micro
# guard's refusals/warnings are written to stderr).
run_record_verdict() { # <verdict> <repo-or-empty> <pr> [sha] → $RECORD_RC $RECORD_ERR
    local verdict="$1" repo="${2:-}" pr="$3" sha="${4:-$SHA}" rcfile="$T/rc" errfile="$T/err"
    # tortoise#7391: only a `clean` verdict reaches the evidence gate; anything else
    # must NOT be handed a ref, or the record would carry an `evidence` the
    # gate never verified (clean-micro runs no review by design).
    local ev=""
    [ "$verdict" = "clean" ] && ev="$EV_ARGS"
    : > "$LOG"
    rm -f "$errfile"
    (
        export HOME="$F_HOME"
        export PATH="$T/bin:$PATH"
        export GH_STUB_LOG="$LOG"
        export STUB_EVIDENCE_PR="$pr" STUB_EVIDENCE_REPO="daniel-ospina/agent-infra"
        rc=0
        if [ -n "$repo" ]; then
            bash "$RECORD" "$pr" "$sha" "$verdict" "$repo" $ev 2>"$errfile" || rc=$?
        else
            bash "$RECORD" "$pr" "$sha" "$verdict" $ev 2>"$errfile" || rc=$?
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
# #1362 D1: parameterised by the record SCRIPT so a mutant copy (whose sibling
# lib/diff-normalize.py is a different primitive) runs through the SAME harness.
run_record_diff_with() { # <record-script> <pr> <sha> <body> [diff-file] [diff-fail] [extra record args…]
    local rec="$1" pr="$2" sha="$3" body="$4" dfile="${5:-/dev/null}" dfail="${6:-0}"
    shift $(( $# > 6 ? 6 : $# ))   # remaining args pass verbatim to record-review.sh
    local rcfile="$T/rc" errfile="$T/err" cap="$T/cap"
    : > "$LOG"; : > "$cap"; rm -f "$errfile"
    (
        export HOME="$F_HOME"
        export PATH="$T/bin:$PATH"
        export GH_STUB_LOG="$LOG"
        export STUB_BODY="$body" STUB_DIFF_FILE="$dfile" STUB_DIFF_FAIL="$dfail" STUB_CAPTURE="$cap"
        export STUB_EVIDENCE_PR="$pr" STUB_EVIDENCE_REPO="daniel-ospina/agent-infra"
        # #1577: the suite must never SLEEP. The retry contract pinned below is the
        # ATTEMPT COUNT (the stub log), not the backoff duration — the backoff is a
        # production politeness knob with no assertion that could tell 1s from 30s
        # without making the suite slow. These two are read from the ambient
        # environment so a caller can opt a single vector into the transient path.
        export RECORD_REVIEW_DIFF_FETCH_SLEEP="${RECORD_REVIEW_DIFF_FETCH_SLEEP:-0}"
        export STUB_DIFF_FAIL_TIMES="${STUB_DIFF_FAIL_TIMES:-0}" STUB_DIFF_COUNT="${STUB_DIFF_COUNT:-}"
        # NOTE (measured): the check surface is read by the stub from this env var,
        # so the runner canNOT scrub an AMBIENT value — the per-invocation prefix
        # works because it overrides, but a caller with the var already exported
        # reaches the earlier carries too (verified: it reddens 11.2/12a/12d/12e/12f).
        # No caller sets it, and the vectors that must be red pin it inline, so this
        # is a declared limitation rather than a hermeticity claim. Fixing it properly
        # means passing the surface as a file path, not as environment.
        export STUB_CHECKS_ROWS="${STUB_CHECKS_ROWS:-}"
        rc=0
        bash "$rec" "$pr" "$sha" clean "daniel-ospina/agent-infra" "$@" $EV_ARGS 2>"$errfile" || rc=$?
        printf '%s' "$rc" > "$rcfile"
    ) 2>/dev/null
    RECORD_RC="$(cat "$rcfile" 2>/dev/null || echo 99)"
    RECORD_ERR="$(cat "$errfile" 2>/dev/null || true)"
    RECORD_CAP="$(cat "$cap" 2>/dev/null || true)"
}
run_record_diff() { # <pr> <sha> <body> [diff-file] [diff-fail] [extra record args…]
    run_record_diff_with "$RECORD" "$@"
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

echo "── 4. Repo-less: fresh clean REFUSED; legacy key still serves ───"
# tortoise#7391 — a repo-less fresh `clean` WAS the bypass: readReviewRecord falls back
# to the legacy <pr>.json when the qualified file is absent, so a repo-less
# record satisfied the merge gate with no repo to name — and, before this, no
# evidence to check. Evidence cannot be verified without a repo, so the gate
# fails CLOSED here. The legacy KEY is still reachable via the verdicts the
# gate does not cover, which is the second half of this vector.
run_record_verdict clean "" 424244
L="$F_HOME/.pi/agent/reviews/424244.json"
[ "$RECORD_RC" = "3" ] && ok "repo-less fresh clean refused (rc 3 — nothing verifiable)" || bad "repo-less fresh clean (rc=$RECORD_RC, want 3)"
[ ! -f "$L" ] && ok "repo-less fresh clean writes no record" || bad "repo-less fresh clean wrote a record"
# The named reason is the VERIFY branch's, not the missing-flag branch: the
# default ref IS passed, and there is no repo to read it from.
assert_contains "$RECORD_ERR" "without a repo" "repo-less refusal names the remedy (pass owner/repo)"
run_record_verdict clean-micro "" 424244
[ -f "$L" ] && ok "repo-less record at legacy key (clean-micro path)" || bad "repo-less record at legacy key ($L)"
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
assert_contains "$RECORD_ERR" "record-review.sh 424301 <head-sha> clean daniel-ospina/agent-infra --evidence" "arm (b): exit-4 stderr prescribes the standard/complex remedy"
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
        export STUB_EVIDENCE_PR="$pr" STUB_EVIDENCE_REPO="daniel-ospina/agent-infra"
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
run_record_raw 424508 "$SHA" --force-stale clean "daniel-ospina/agent-infra" $EV_ARGS
[ "$RECORD_RC" = "0" ] && ok "guard: --force-stale leading still records (rc 0)" || bad "guard: --force-stale leading (rc=$RECORD_RC)"
[ -f "$(rec_path 424508)" ] && ok "guard: --force-stale leading wrote a record" || bad "guard: --force-stale leading wrote no record"

run_record_raw 424509 "$SHA" clean "daniel-ospina/agent-infra" --force-stale $EV_ARGS
[ "$RECORD_RC" = "0" ] && ok "guard: --force-stale trailing still records (rc 0)" || bad "guard: --force-stale trailing (rc=$RECORD_RC)"
[ -f "$(rec_path 424509)" ] && ok "guard: --force-stale trailing wrote a record" || bad "guard: --force-stale trailing wrote no record"

run_record_raw 424510 "$SHA" clean "daniel-ospina/agent-infra" $EV_ARGS
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

# ── #1575 clause (E): a carry must not re-bind onto a MEASURABLY RED head ─────
# Every arm below clones 11.2 EXACTLY (same stale sha, same unchanged diff, same
# valid prior marker) and changes only the target head's check surface. 11.2
# proves the carry succeeds without (E), so a refusal here is attributable to (E)
# and to nothing else.
prior_for() { # <pr> -> the signed clean marker line for $DH at $STALE
  local t="review recorded: reviews/$1.json verdict=clean @ $STALE diff=$DH (daniel-ospina/agent-infra)"
  printf '%s sig=%s' "$t" "$(printf '%s' "$t" | openssl dgst -sha256 -hmac "$TEST_GATE_KEY" | awk '{print $NF}')"
}

# 11.3a: a completed FAILURE at the target head refuses the carry. Without (E)
# this is tortoise #4823 / #5395 / #5292 — a signed `clean` on a head whose own
# checks are failing, which the merge gate cannot see once the record outlives
# the run.
rm -f "$(Q2 424510)"
STUB_CHECKS_ROWS='github-actions|ci / unit-test|11|completed|failure' \
  run_record_diff 424510 "$STALE" "body

$(prior_for 424510)" "$D_F"
[ "$RECORD_RC" = "3" ] && ok "11.3a (E) a RED target head refuses the carry (rc 3)" || bad "11.3a (E) carried onto a red head! (rc=$RECORD_RC)"
assert_contains "$RECORD_ERR" "TARGET HEAD IS MEASURABLY RED" "11.3a (E) names the refusal condition"
[ ! -f "$(Q2 424510)" ] && ok "11.3a (E) no record written for a red head" || bad "11.3a (E) wrote a record onto a red head"
if grep -qF "carry-forward" <<<"$RECORD_ERR"; then bad "11.3a (E) still printed the carry SUCCESS line"; else ok "11.3a (E) the carry success line is not printed"; fi

# 11.3b: POLARITY CONTROL — a group whose OLDER attempt failed and whose NEWEST
# passed is NOT red. This is what stops (E) being written as an ungrouped `any
# failure`, which refuses a green head; this fleet produces re-runs routinely
# (one job held 10 attempts carrying BOTH `failure` and `success`), and a guard
# that fires on green heads gets deleted rather than fixed.
rm -f "$(Q2 424511)"
STUB_CHECKS_ROWS='github-actions|ci / unit-test|11|completed|failure
github-actions|ci / unit-test|12|completed|success' \
  run_record_diff 424511 "$STALE" "body

$(prior_for 424511)" "$D_F"
[ "$RECORD_RC" = "0" ] && ok "11.3b (E) a re-run-green head still carries (rc 0) — the grouping is load-bearing" || bad "11.3b (E) refused a GREEN head (rc=$RECORD_RC) — the check is ungrouped"
assert_contains "$RECORD_ERR" "carry-forward" "11.3b (E) the carry proceeded"

# 11.3c: an UNDOCUMENTED conclusion is RED. The allow-list polarity is deliberate
# (#1399 / tortoise #4877): a conclusion GitHub has not documented cannot be read
# as green, and neither can a null one.
for spec in "11.3c some_future_conclusion" "11.3d null"; do
  tag="${spec%% *}"; concl="${spec#* }"; n="${tag#11.3}"
  case "$n" in c) pr=424512 ;; d) pr=424513 ;; esac
  rm -f "$(Q2 $pr)"
  STUB_CHECKS_ROWS="github-actions|ci / unit-test|11|completed|$concl" \
    run_record_diff "$pr" "$STALE" "body

$(prior_for "$pr")" "$D_F"
  [ "$RECORD_RC" = "3" ] && ok "$tag (E) conclusion '$concl' is RED (rc 3)" || bad "$tag (E) treated '$concl' as green (rc=$RECORD_RC)"
done

# 11.3e: NOT-RED states must NOT refuse — in-flight, cancelled, and an EMPTY
# surface. (E) may only ADD a refusal; an unmeasured head is the pre-existing
# state of every carry, so refusing there would block carries fleet-wide.
for spec in "11.3e 424514 github-actions|ci / unit-test|11|in_progress|null" \
            "11.3f 424515 github-actions|ci / unit-test|11|completed|cancelled" \
            "11.3g 424516 "; do
  tag="${spec%% *}"; rest="${spec#* }"; pr="${rest%% *}"; rows="${rest#* }"
  rm -f "$(Q2 $pr)"
  STUB_CHECKS_ROWS="$rows" \
    run_record_diff "$pr" "$STALE" "body

$(prior_for "$pr")" "$D_F"
  [ "$RECORD_RC" = "0" ] && ok "$tag (E) a not-red surface still carries (rc 0)" || bad "$tag (E) refused a not-red surface (rc=$RECORD_RC)"
done

# 11.3h: the ANTI-REGRESSION vector for the veto's surface. `ai-review-gate` sits on
# the PR head and goes red BECAUSE the evidence is stale — the condition the carry
# exists to remedy. Counting it refuses `lane_dimension_carry` BY CONSTRUCTION (#6213
# measured the gate flipping SUCCESS -> FAILURE seven seconds after the rail moved the
# head). A red the carry itself explains is not evidence about the tree.
rm -f "$(Q2 424517)"
STUB_CHECKS_ROWS='github-actions|ai-review-gate|11|completed|failure' \
  run_record_diff 424517 "$STALE" "body

$(prior_for 424517)" "$D_F"
[ "$RECORD_RC" = "0" ] && ok "11.3h (E) a stale-ai-review-gate red alone still carries (rc 0)" || bad "11.3h (E) the veto fired on its OWN evidence gate (rc=$RECORD_RC) — the lane arm is refused by construction"

# 11.3i: the exclusion is NARROW — the gate's redness must not mask a genuine red.
rm -f "$(Q2 424518)"
STUB_CHECKS_ROWS='github-actions|ai-review-gate|11|completed|failure
github-actions|ci / unit-test|12|completed|failure' \
  run_record_diff 424518 "$STALE" "body

$(prior_for 424518)" "$D_F"
[ "$RECORD_RC" = "3" ] && ok "11.3i (E) a genuine red beside the gate still refuses (rc 3)" || bad "11.3i (E) the gate exclusion masked a real red (rc=$RECORD_RC)"

# 11.3j: an unrecognised STATUS spelling alongside a conclusion is judged by that
# conclusion. `null` here means RED, not "in flight" — see 11.3k for the distinction.
rm -f "$(Q2 424519)"
STUB_CHECKS_ROWS='github-actions|ci / unit-test|11|completely_finished|failure' \
  run_record_diff 424519 "$STALE" "body

$(prior_for 424519)" "$D_F"
[ "$RECORD_RC" = "3" ] && ok "11.3j (E) an unknown STATUS with a failure conclusion is red (rc 3)" || bad "11.3j (E) waved through an unknown status (rc=$RECORD_RC)"

# 11.3k: and an unknown STATUS with a NULL conclusion is red too. This is the #1353
# fail-open: gating "in flight" on the ABSENCE of a conclusion lets any status
# spelling this code has not seen read as pending, and the surface read GREEN. In
# flight is a NAMED set, not "anything that is not completed".
rm -f "$(Q2 424560)"
STUB_CHECKS_ROWS='github-actions|ci / unit-test|11|completely_finished|null' \
  run_record_diff 424560 "$STALE" "body

$(prior_for 424560)" "$D_F"
[ "$RECORD_RC" = "3" ] && ok "11.3k (E) an unknown status with a NULL conclusion is red (rc 3) — in-flight is a named set" || bad "11.3k (E) #1353 fail-open: an unseen status read as pending (rc=$RECORD_RC)"

# 11.3l: an UNPARSEABLE row must make the surface RED, not vanish. A check name
# containing a literal pipe shifts every later field; DISCARDING the row is the same
# #1353 fail-open, and MIS-GROUPING it (the reviewer's mutant: fields shift left, the
# status `completed` lands in the conclusion slot, which is not in the allow-list)
# would red the surface by ACCIDENT. The rc assertion alone cannot tell those apart —
# the diagnostic assertion below is what pins the intended branch.
rm -f "$(Q2 424561)"
STUB_CHECKS_ROWS='github-actions|ci | shard 1|11|completed|failure' \
  run_record_diff 424561 "$STALE" "body

$(prior_for 424561)" "$D_F"
[ "$RECORD_RC" = "3" ] && ok "11.3l (E) an unparseable row makes the surface RED, not absent (rc 3)" || bad "11.3l (E) a literal pipe in a check name silently vanished (rc=$RECORD_RC)"
assert_contains "$RECORD_ERR" "unparseable check-run row" "11.3l (E) the drop is announced, not mute"

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

# 11.5a #1577 — the diff fetch is RETRIED, and a TRANSIENT failure that CLEARS
# carries the verdict. Before this fix the fetch was ONE attempt, so a network
# blip emptied DIFF_HASH, the stale-sha guard refused the carry, and the rail
# reported "the reviewed diff CHANGED" — the most expensive remedy in the system,
# demanded for a diff that never moved. Measured on agent-infra #1554: a full
# rail cycle ([1/4] + ~45 min of [2/4] + [3/4]) was discarded on a diff that was
# BYTE-IDENTICAL. REGRESSION-SENSITIVE: with a single attempt this records a
# legacy sha-only marker (no diff=) instead of carrying.
rm -f "$(Q2 424540)" "$T/diffcount-11.5a"
export STUB_DIFF_FAIL_TIMES=2 STUB_DIFF_COUNT="$T/diffcount-11.5a"
run_record_diff 424540 "$SHA" "PR body" "$D_F" 0
unset STUB_DIFF_FAIL_TIMES STUB_DIFF_COUNT
[ "$RECORD_RC" = "0" ] && ok "11.5a #1577 a transient fetch failure that CLEARS still records (rc 0)" || bad "11.5a #1577 rc=$RECORD_RC (err=$RECORD_ERR)"
grep -qF "diff=" <<<"$RECORD_CAP" && ok "11.5a #1577 the RETRIED fetch still carries the diff binding" || bad "11.5a #1577 fell back to a sha-only marker — the retry did not happen"
grep -q '"diff_sha256"' "$(Q2 424540)" 2>/dev/null && ok "11.5a #1577 the record carries diff_sha256" || bad "11.5a #1577 record omits diff_sha256"
[ "$(grep -cF 'application/vnd.github.v3.diff' "$LOG")" = "3" ] && ok "11.5a #1577 the fetch was attempted 3x (2 failures, then the success)" || bad "11.5a #1577 expected 3 diff attempts, saw $(grep -cF 'application/vnd.github.v3.diff' "$LOG")"

# 11.5b #1577 — the retry is BOUNDED, and the warning NAMES the condition as
# transient instead of implying a content change (the attribution half of the
# defect: a failed fetch and a changed diff call for opposite responses).
rm -f "$(Q2 424541)"
run_record_diff 424541 "$SHA" "PR body" "$D_F" 1
[ "$(grep -cF 'application/vnd.github.v3.diff' "$LOG")" = "3" ] && ok "11.5b #1577 a permanent failure stops at 3 attempts (bounded)" || bad "11.5b #1577 saw $(grep -cF 'application/vnd.github.v3.diff' "$LOG") attempts (expected 3)"
assert_contains "$RECORD_ERR" "A FAILED FETCH IS NOT A CHANGED ARTIFACT" "11.5b #1577 the warning names the transient condition"
assert_contains "$RECORD_ERR" "3 of 3 attempt(s)" "11.5b #1577 the warning reports the attempt count"

# 11.5c #1577 — an EMPTY body is a property of the DIFF, not the network, so it
# is NOT retried (an idempotent GET answers the same thing twice) and its
# warning must not claim a fetch failure.
rm -f "$(Q2 424542)"
run_record_diff 424542 "$SHA" "PR body" /dev/null 0
[ "$(grep -cF 'application/vnd.github.v3.diff' "$LOG")" = "1" ] && ok "11.5c #1577 an empty diff is NOT retried (1 attempt)" || bad "11.5c #1577 empty diff attempted $(grep -cF 'application/vnd.github.v3.diff' "$LOG")x (expected 1)"
assert_contains "$RECORD_ERR" "diff body was EMPTY" "11.5c #1577 the empty-diff warning names the empty body"
if grep -qF "FAILED" <<<"$RECORD_ERR"; then bad "11.5c #1577 the empty-diff warning must not claim a fetch FAILURE"; else ok "11.5c #1577 the empty-diff warning does not claim a fetch failure"; fi

# 11.5d #1577 — an out-of-range SLEEP knob must not abort the record. The first
# guard rejected only non-digits and 0, so an all-digit value past /bin/sleep's
# range (2147483648) reached sleep, which exited 1 under `set -e` — aborting the
# whole record with NO warning and NO record written (reproduced end-to-end by
# the VGATE verifier); an in-range-but-huge value (999999999) hung it for years
# instead. The knob is now CLAMPED to DIFF_FETCH_SLEEP_MAX, because a mistyped
# POLITENESS knob must never cost the ATTESTATION. The clamp is observed on a
# STUBBED sleep, so the suite pays none of the (bounded) real delay.
mkdir -p "$T/binsleep"
cat > "$T/binsleep/sleep" <<'SLEEPSTUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SLEEP_LOG:-/dev/null}"
exit 0
SLEEPSTUB
chmod +x "$T/binsleep/sleep"
for _v in 2147483648 999999999; do
    rm -f "$(Q2 424543)" "$T/sleeplog-11.5d"
    SLEEP_LOG="$T/sleeplog-11.5d" RECORD_REVIEW_DIFF_FETCH_SLEEP="$_v" \
      PATH="$T/binsleep:$PATH" run_record_diff 424543 "$SHA" "PR body" "$D_F" 1
    [ "$RECORD_RC" = "0" ] && ok "11.5d #1577 sleep=$_v does NOT abort the record (rc 0)" || bad "11.5d #1577 sleep=$_v aborted the record (rc=$RECORD_RC, err=$RECORD_ERR)"
    [ -f "$(Q2 424543)" ] && ok "11.5d #1577 sleep=$_v still writes the record" || bad "11.5d #1577 sleep=$_v wrote NO record"
    SLOG="$(cat "$T/sleeplog-11.5d" 2>/dev/null || true)"
    # The NEGATIVE assertion is guarded on the log being non-empty: with no retry
    # there is no sleep at all, and grepping an empty log passed vacuously
    # (#1577 review P3). The vector still REDs via the clamp assertion below, but
    # a negative assertion that cannot fail is not an assertion.
    if [ -z "$SLOG" ]; then bad "11.5d #1577 sleep=$_v: NO sleep observed, so the clamp was never exercised"
    elif grep -qxF "$_v" <<<"$SLOG"; then bad "11.5d #1577 sleep=$_v REACHED sleep unclamped"
    else ok "11.5d #1577 sleep=$_v never reaches sleep unclamped"; fi
    if grep -qxF "30" <<<"$SLOG"; then ok "11.5d #1577 sleep=$_v is CLAMPED to 30"; else bad "11.5d #1577 sleep=$_v was not clamped (log: $(printf '%s' "$SLOG" | tr '\n' ' '))"; fi
done
unset RECORD_REVIEW_DIFF_FETCH_SLEEP SLEEP_LOG _v SLOG

# 11.5e #1577 review P1 — the cleanup trap must survive functrace. A RETURN
# trap is INHERITED by NESTED functions, so it fired when diff_fetch_once
# returned and deleted the temp file BEFORE the hash read it, aborting the
# record rc 1 with NO record written -- on every SUCCESSFUL fetch. Functrace
# arrives only via an explicit `bash -T` or an ancestor that EXPORTED SHELLOPTS
# (`set -T` alone does NOT export it). The trap is now EXIT (armed only after the
# early returns, with the function's own rm -f as the normal cleanup).
# REGRESSION-SENSITIVE: with the RETURN trap this records nothing. (No backticks
# in the assertion strings below -- they would run as command substitution,
# which is the exact defect fixed elsewhere in this file.)
rm -f "$(Q2 424544)" "$T/cap-11.5e" "$T/err-11.5e" "$T/rc-11.5e"
# SHELLOPTS is READONLY, so it cannot be used as an env-prefix to flip functrace;
# the flag is passed to the child bash directly (`bash -T`), which is exactly the
# environment the P1 reproduced under.
(
    export HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG"
    export STUB_BODY="PR body" STUB_DIFF_FILE="$D_F" STUB_DIFF_FAIL=0 STUB_CAPTURE="$T/cap-11.5e"
    export STUB_EVIDENCE_PR="424544" STUB_EVIDENCE_REPO="daniel-ospina/agent-infra"
    unset STUB_DIFF_FAIL_TIMES STUB_DIFF_COUNT
    export RECORD_REVIEW_DIFF_FETCH_SLEEP=0
    rc=0
    bash -T "$RECORD" 424544 "$SHA" clean "daniel-ospina/agent-infra" --evidence "$EV_REF" 2>"$T/err-11.5e" || rc=$?
    printf '%s' "$rc" > "$T/rc-11.5e"
) 2>/dev/null
RECORD_RC="$(cat "$T/rc-11.5e" 2>/dev/null || echo 99)"
RECORD_ERR="$(cat "$T/err-11.5e" 2>/dev/null || true)"
RECORD_CAP="$(cat "$T/cap-11.5e" 2>/dev/null || true)"
[ "$RECORD_RC" = "0" ] && ok "11.5e #1577 a functrace (set -T) ancestor still records (rc 0)" || bad "11.5e #1577 functrace aborted the record (rc=$RECORD_RC, err=$(printf '%s' "$RECORD_ERR" | tail -2 | tr '\n' ' '))"
[ -f "$(Q2 424544)" ] && ok "11.5e #1577 the record IS written under functrace" || bad "11.5e #1577 NO record written under functrace"
grep -qF "diff=" <<<"$RECORD_CAP" && ok "11.5e #1577 the diff binding survives under functrace" || bad "11.5e #1577 no diff binding under functrace"

# 11.5f #1577 review P3 — an unusable attempt budget degrades to the DEFAULT and
# never leaks a raw `integer expression expected` or a nonsense count. A huge
# in-range value used to leave the loop effectively unbounded (234 attempts in
# ~6s at a zero backoff).
for _a in abc 0 9223372036854775807; do
    rm -f "$(Q2 424545)"
    RECORD_REVIEW_DIFF_FETCH_ATTEMPTS="$_a" RECORD_REVIEW_DIFF_FETCH_SLEEP=0 \
      run_record_diff 424545 "$SHA" "PR body" "$D_F" 1
    if grep -qF "integer expression expected" <<<"$RECORD_ERR"; then bad "11.5f #1577 attempts=$_a leaked a raw bash error"; else ok "11.5f #1577 attempts=$_a leaks no raw bash error"; fi
    assert_contains "$RECORD_ERR" "of 3 attempt(s) made" "11.5f #1577 attempts=$_a falls back to the default budget (3)"
    [ "$(grep -cF 'application/vnd.github.v3.diff' "$LOG")" = "3" ] && ok "11.5f #1577 attempts=$_a makes exactly 3 fetch attempts" || bad "11.5f #1577 attempts=$_a made $(grep -cF 'application/vnd.github.v3.diff' "$LOG") attempts (expected 3)"
done
unset _a RECORD_REVIEW_DIFF_FETCH_ATTEMPTS

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
run_record_diff 424520 "$SHA" "PR body" "$D_F"
json_valid "$(Q2 424520)" && ok "11.10 A DIFF-only record is well-formed JSON" || bad "11.10 A DIFF-only record is MALFORMED: $(cat "$(Q2 424520)" 2>/dev/null)"
# B: MB+DIFF — the combination this merge exists to enable.
STUB_FILES="docs/plans/2026-09-22-x.md" GH_STUB_PATCH_BODY="$P2" STUB_DIFF_FILE="$D_F" \
  run_record_verdict clean-low "daniel-ospina/agent-infra" 424521
json_valid "$(Q2 424521)" && ok "11.10 B MB+DIFF record is well-formed JSON" || bad "11.10 B MB+DIFF record is MALFORMED: $(cat "$(Q2 424521)" 2>/dev/null)"
assert_contains "$(cat "$(Q2 424521)" 2>/dev/null)" "\"merge_base_sha\":\"$MB\"" "11.10 B carries merge_base_sha"
assert_contains "$(cat "$(Q2 424521)" 2>/dev/null)" "\"diff_sha256\":\"$DH\"" "11.10 B carries diff_sha256"
# C: MB only — clean-low with the diff fetch unavailable.
STUB_FILES="docs/plans/2026-09-22-x.md" GH_STUB_PATCH_BODY="$P2" \
  run_record_verdict clean-low "daniel-ospina/agent-infra" 424522
json_valid "$(Q2 424522)" && ok "11.10 C MB-only record is well-formed JSON" || bad "11.10 C MB-only record is MALFORMED: $(cat "$(Q2 424522)" 2>/dev/null)"
# D: NEITHER — clean, diff fetch forced to fail.
run_record_diff 424523 "$SHA" "PR body" "$D_F" "1"
json_valid "$(Q2 424523)" && ok "11.10 D NEITHER record is well-formed JSON" || bad "11.10 D NEITHER record is MALFORMED: $(cat "$(Q2 424523)" 2>/dev/null)"
# Two cleanups, for two DIFFERENT reasons:
#  (1) PR NUMBERS. §10 (#1348) runs AFTER this section and its C1 vector asserts
#      "writes no record" for PR 424600. Reusing any number up there would leave a
#      record behind and make C1 fail for a reason that has nothing to do with C1.
#      The range must ALSO be one no EARLIER VECTOR writes — including vectors in
#      other §11 blocks, since the collision this guards against is INTRA-§11:
#      `11.3k`/`11.3l` briefly used the same two numbers as A/B. A parses the record at
#      its own PR number, so a leftover record there would let the parse pass even
#      if A's writer silently failed (the vacuity this block exists to close).
#      424520-424523 is verified unused by every other vector in this file.
#  (2) The env-prefix assignments LEAK: `VAR=val func` does not restore VAR if it
#      was previously UNSET (bash semantics), so STUB_FILES/STUB_DIFF_FILE would
#      persist into §10 and make its code-bearing vectors see a docs-only diff.
unset STUB_FILES STUB_DIFF_FILE GH_STUB_PATCH_BODY STUB_HEAD_SHA P2 MB

# ─────────────────────────────────────────────────────────────────────────
# 11.11 #1398 — the 300-file diff cap: classify by CONTENT, fall back to a
#       LOCAL diff, and NEVER hash the (non-empty) error body.
# ─────────────────────────────────────────────────────────────────────────
# GitHub refuses to render a PR diff above 300 files: `gh api -H
# "Accept: application/vnd.github.v3.diff"` exits NON-ZERO and writes a
# NON-EMPTY JSON error object to stdout (MEASURED on tortoise#7653,
# `changed_files: 2265`: exit 1, 337 bytes on stdout, `grep -c '^diff --git'`
# → 0). The non-emptiness is the trap: `[ -s "$f" ]` PASSES on it, and the ONLY
# thing that stopped it being hashed was the `&&` short-circuit on the exit
# code — so a naive `|| true` "fix" would hash 337 bytes of error message as
# the reviewed diff, giving every oversized PR ONE constant digest (the
# collision ⇒ false-accept direction this issue exists to prevent).
# These vectors pin the classification, the fallback, and that negative control.
echo "── 11.11 #1398: the 300-file diff cap + local fallback ────────"
NORM1398="$SCRIPT_DIR/lib/diff-normalize.py"

# A REAL git fixture: the fallback runs `git diff` against actual objects, so a
# fabricated diff would not exercise it. `origin` names the repo under test so
# the identity guard accepts it.
L_REPO="$T/local-repo-1398"
git init -q "$L_REPO"
git -C "$L_REPO" config user.email "t@example.test"
git -C "$L_REPO" config user.name "t"
git -C "$L_REPO" remote add origin "https://github.com/daniel-ospina/agent-infra.git"
printf 'line1\nline2\nline3\nline4\nline5\n' > "$L_REPO/f.txt"
git -C "$L_REPO" add f.txt
git -C "$L_REPO" -c commit.gpgsign=false commit -q -m base
L_BASE="$(git -C "$L_REPO" rev-parse HEAD)"
printf 'line1\nline2\nCHANGED\nline3\nline4\nline5\n' > "$L_REPO/f.txt"
git -C "$L_REPO" -c commit.gpgsign=false commit -q -am head
L_HEAD="$(git -C "$L_REPO" rev-parse HEAD)"

# The digest the producer's fallback must arrive at: its exact command, then the
# SAME shared normalizer the API path uses.
local_diff_sha1398() { # <repo> <base> <head>
    git -C "$1" -c diff.noprefix=false -c diff.mnemonicPrefix=false -c diff.relative=false \
      -c diff.suppressBlankEmpty=false \
      diff --no-color --no-ext-diff --no-textconv --full-index \
           --src-prefix=a/ --dst-prefix=b/ --unified=3 --diff-algorithm=myers --find-renames "$2...$3" \
      | python3 "$NORM1398" | openssl dgst -sha256 | awk '{print $NF}'
}
L_SHA="$(local_diff_sha1398 "$L_REPO" "$L_BASE" "$L_HEAD")"
[ -n "$L_SHA" ] && ok "11.11 fixture: the local rendering yields a normalized digest" || bad "11.11 fixture: no local digest"

# The 406 body. The SHAPE is what the classifier reads (no `diff --git`, one
# line, JSON error object with status 406 / code too_large).
CAP406="$T/cap-406.json"
printf '%s' '{"message":"Sorry, the diff exceeded the maximum number of files (300).","errors":[{"resource":"PullRequest","field":"diff","code":"too_large"}],"documentation_url":"https://docs.github.com/rest/pulls/pulls","status":"406"}' > "$CAP406"
CAP406_SHA="$(openssl dgst -sha256 < "$CAP406" | awk '{print $NF}')"
grep -qE '^diff --git' "$CAP406" && bad "11.11 fixture: the cap body must NOT contain a diff entry" || ok "11.11 fixture: the cap body carries no 'diff --git' entry (as measured)"

# (a) NEGATIVE CONTROL — the cap body with NO usable local checkout. It must be
#     classified STRUCTURAL, attempted ONCE (not retried), and NEVER hashed.
rm -f "$(Q2 424770)"
STUB_DIFF_406_FILE="$CAP406" STUB_LOCAL_BASE="$L_BASE" STUB_LOCAL_HEAD="$L_HEAD" \
  RECORD_REVIEW_LOCAL_REPO="$T/no-such-checkout-1398" \
  run_record_diff 424770 "$SHA" "PR body" /dev/null 0
[ "$RECORD_RC" = "0" ] && ok "11.11a cap without a checkout still records (rc 0)" || bad "11.11a rc=$RECORD_RC (err=$RECORD_ERR)"
[ "$(grep -cF 'application/vnd.github.v3.diff' "$LOG")" = "1" ] && ok "11.11a a STRUCTURAL cap is NOT retried (1 attempt)" || bad "11.11a made $(grep -cF 'application/vnd.github.v3.diff' "$LOG") attempts (expected 1)"
if grep -qF "diff=" <<<"$RECORD_CAP"; then bad "11.11a the cap error body was hashed into the marker (diff= present)"; else ok "11.11a no diff= — the cap error body is never hashed"; fi
if grep -qF "diff=$CAP406_SHA" <<<"$RECORD_CAP"; then bad "11.11a THE TRAP: the 406 body's own sha256 was recorded as the reviewed diff"; else ok "11.11a the 406 body's own sha256 is NOT recorded"; fi
if grep -q '"diff_sha256"' "$(Q2 424770)" 2>/dev/null; then bad "11.11a record carries a diff_sha256 minted from the error body"; else ok "11.11a record omits diff_sha256"; fi
assert_contains "$RECORD_ERR" "300-FILE DIFF CAP" "11.11a names the STRUCTURAL cause"
assert_contains "$RECORD_ERR" "RETRYING WILL NOT HELP" "11.11a says retrying will not help"
if grep -qF "gh/API/openssl unavailable" <<<"$RECORD_ERR"; then bad "11.11a misdiagnoses the documented cap as a tooling outage"; else ok "11.11a does NOT blame gh/openssl"; fi

# (b) the fallback MINTS a digest when a local checkout holds both objects.
rm -f "$(Q2 424771)"
STUB_DIFF_406_FILE="$CAP406" STUB_LOCAL_BASE="$L_BASE" STUB_LOCAL_HEAD="$L_HEAD" \
  RECORD_REVIEW_LOCAL_REPO="$L_REPO" \
  run_record_diff 424771 "$SHA" "PR body" /dev/null 0
[ "$RECORD_RC" = "0" ] && ok "11.11b cap WITH a local checkout records (rc 0)" || bad "11.11b rc=$RECORD_RC (err=$RECORD_ERR)"
assert_contains "$(cat "$(Q2 424771)" 2>/dev/null)" "\"diff_sha256\":\"$L_SHA\"" "11.11b the record carries the LOCAL normalized digest"
assert_contains "$RECORD_CAP" "diff=$L_SHA" "11.11b the marker carries the LOCAL normalized digest"
[ "$(grep -cF 'application/vnd.github.v3.diff' "$LOG")" = "1" ] && ok "11.11b the fallback does not re-fetch (1 attempt)" || bad "11.11b attempts=$(grep -cF 'application/vnd.github.v3.diff' "$LOG")"
assert_contains "$RECORD_ERR" "computed from the LOCAL checkout" "11.11b the provenance is stated, not implied"

# (c) the SAME content through the API path and the local path produce the SAME
#     digest. The API rendering differs only in the fields the normalizer exists
#     to erase — the `index` abbreviation width and the hunk start lines (both
#     move on a base-only update). Perturb exactly those and hash it as the API
#     would.
API_STYLE="$T/api-style-1398.diff"
python3 - "$L_REPO" "$L_BASE" "$L_HEAD" "$API_STYLE" <<'PY'
import re, subprocess, sys
repo, base, head, out = sys.argv[1:5]
raw = subprocess.run(["git", "-C", repo, "diff", "--no-color", f"{base}...{head}"],
                     capture_output=True, check=True).stdout.decode("latin-1")
lines = []
for ln in raw.split("\n"):
    m = re.match(r"^index ([0-9a-f]+)\.\.([0-9a-f]+)(.*)$", ln)
    if m:
        ln = "index %s..%s%s" % ((m.group(1) + "0" * 13)[:13], (m.group(2) + "0" * 13)[:13], m.group(3))
    m = re.match(r"^@@ -(\d+)((?:,\d+)?) \+(\d+)((?:,\d+)?) @@(.*)$", ln)
    if m:
        ln = "@@ -%d%s +%d%s @@%s" % (int(m.group(1)) + 7, m.group(2), int(m.group(3)) + 13, m.group(4), m.group(5))
    lines.append(ln)
open(out, "w").write("\n".join(lines))
PY
API_STYLE_SHA="$(python3 "$NORM1398" < "$API_STYLE" | openssl dgst -sha256 | awk '{print $NF}')"
assert_eq "$API_STYLE_SHA" "$L_SHA" "11.11c an API rendering and the local git diff normalize to the SAME digest"
rm -f "$(Q2 424772)"
run_record_diff 424772 "$SHA" "PR body" "$API_STYLE" 0
assert_contains "$(cat "$(Q2 424772)" 2>/dev/null)" "\"diff_sha256\":\"$L_SHA\"" "11.11c the API path records the SAME digest the local fallback mints"

# (d) a SUCCESSFUL response whose body is not a diff is refused, not hashed —
#     the 200-with-a-non-diff-body form of the same trap (a 406-shaped body is
#     already caught as a cap above, so this uses a body that is neither).
rm -f "$(Q2 424773)"
printf '{"message":"Not Found","documentation_url":"https://docs.github.com/rest","status":"404"}' > "$T/err-404.json"
STUB_DIFF_FILE="$T/err-404.json" STUB_DIFF_FAIL=0 \
  RECORD_REVIEW_LOCAL_REPO="$T/no-such-checkout-1398" \
  run_record_diff 424773 "$SHA" "PR body" "$T/err-404.json" 0
if grep -qF "diff=" <<<"$RECORD_CAP"; then bad "11.11d a non-diff body was hashed (diff= present)"; else ok "11.11d a body with no 'diff --git' entry is never hashed"; fi
assert_contains "$RECORD_ERR" "NO 'diff --git' entry boundary" "11.11d the refusal names the missing entry boundary"
if grep -q '"diff_sha256"' "$(Q2 424773)" 2>/dev/null; then bad "11.11d record carries a diff_sha256 from a non-diff body"; else ok "11.11d record omits diff_sha256"; fi

# (e) the classifier must NOT mistake a REAL diff that CONTAINS the literal
#     `"code":"too_large"` for the cap error — this fix's own fixtures contain
#     that string, and a naive substring match would demote every such PR to the
#     fallback.
REAL_WITH_CODE="$T/real-with-too-large.diff"
printf 'diff --git a/f b/f\nindex 1111111..2222222 100644\n--- a/f\n+++ b/f\n@@ -1,2 +1,3 @@\n ctx\n+    "code":"too_large"\n ctx2\n' > "$REAL_WITH_CODE"
REAL_WITH_CODE_SHA="$(python3 "$NORM1398" < "$REAL_WITH_CODE" | openssl dgst -sha256 | awk '{print $NF}')"
rm -f "$(Q2 424774)"
STUB_DIFF_FILE="$REAL_WITH_CODE" STUB_DIFF_FAIL=0 \
  RECORD_REVIEW_LOCAL_REPO="$T/no-such-checkout-1398" \
  run_record_diff 424774 "$SHA" "PR body" "$REAL_WITH_CODE" 0
assert_contains "$(cat "$(Q2 424774)" 2>/dev/null)" "\"diff_sha256\":\"$REAL_WITH_CODE_SHA\"" "11.11e a real diff containing the literal cap marker is still hashed as a diff"

# (f) MUTATION PIN — the naive `|| true` relaxation the issue warns about. A
#     copy whose fetch ignores the exit code AND both content guards hashes the
#     406 body, proving 11.11a is load-bearing rather than green by accident.
mkdir -p "$T/mut-cap/lib"
cp "$SCRIPT_DIR/lib/diff-normalize.py" "$T/mut-cap/lib/diff-normalize.py"
python3 - "$RECORD" "$T/mut-cap/record-review.sh" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
old = """  if diff_body_is_size_cap "$2"; then return 3; fi
  [ "$frc" -eq 0 ] || return 1
  [ -s "$2" ] || return 2
  command grep -qE '^diff --git ' "$2" 2>/dev/null || return 4
  return 0"""
new = """  # MUTATION (#1398): the naive relaxation — exit code ignored, no content
  # classification, `[ -s ]` alone decides. This MUST hash the 406 body.
  [ -s "$2" ] || return 2
  return 0"""
assert old in text, "mutation anchor not found"
open(dst, "w").write(text.replace(old, new))
PY
if cmp -s "$T/mut-cap/record-review.sh" "$RECORD"; then bad "11.11f mutation(f): the mutant copy is IDENTICAL to the script"; else ok "11.11f mutation(f): the mutant copy differs from the script"; fi
rm -f "$(Q2 424775)"
STUB_DIFF_406_FILE="$CAP406" STUB_LOCAL_BASE="$L_BASE" STUB_LOCAL_HEAD="$L_HEAD" \
  RECORD_REVIEW_LOCAL_REPO="$T/no-such-checkout-1398" \
  run_record_diff_with "$T/mut-cap/record-review.sh" 424775 "$SHA" "PR body" /dev/null 0
if grep -qF "diff=$CAP406_SHA" <<<"$RECORD_CAP"; then ok "11.11f mutation(f): with the guards removed the 406 body IS hashed (rc=$RECORD_RC) — 11.11a is load-bearing"; else bad "11.11f mutation(f): the mutant still refused the 406 body (rc=$RECORD_RC) — 11.11a is not testing the guard"; fi

# ── 11.11g–l — the fallback's own fail-closed guards. A mutation probe found
# that removing ALL of them at once left the suite green, so the guards that can
# be isolated now have vectors: 11.11g pins the repo-identity guard (a
# wrong-origin checkout HAS the objects, so without the guard the digest IS
# minted) and 11.11l pins the empty-diff refusal (MEASURED: removing the `[ -s ]`
# test alone stays green because the entry-boundary grep covers it, and removing
# the grep alone stays green for the same reason — removing BOTH reddens it).
# The cat-file guards are defence-in-depth: a missing object makes git's own
# `diff` fail, so they add an explicit refusal rather than the only one — stated
# here rather than implied by a count. These decide whether a locally-computed
# diff may be trusted, the same class tests/record-review/run.sh mutation-pins
# for lane_dimension_carry.
#
# 11.11g: a checkout of a DIFFERENT repo (origin normalises to another owner/name)
#         must never be used. Without this guard, any unrelated clone could supply
#         the "reviewed" diff.
L_WRONG="$T/local-wrong-1398"
git init -q "$L_WRONG"
git -C "$L_WRONG" config user.email "t@example.test"
git -C "$L_WRONG" config user.name "t"
git -C "$L_WRONG" remote add origin "https://github.com/daniel-ospina/tortoise.git"
git -C "$L_WRONG" fetch -q --no-tags "$L_REPO" "HEAD:refs/remotes/local/wrongsrc"
rm -f "$(Q2 424780)"
STUB_DIFF_406_FILE="$CAP406" STUB_LOCAL_BASE="$L_BASE" STUB_LOCAL_HEAD="$L_HEAD" \
  RECORD_REVIEW_LOCAL_REPO="$L_WRONG" RECORD_REVIEW_LOCAL_DIFF_NOFETCH=1 \
  run_record_diff 424780 "$SHA" "PR body" /dev/null 0
if grep -qF "diff=" <<<"$RECORD_CAP"; then bad "11.11g a checkout of ANOTHER repo produced a diff identity"; else ok "11.11g a checkout whose origin is another repo is refused (no diff=)"; fi

# 11.11h: a revision absent from the checkout must be refused, not fabricated.
rm -f "$(Q2 424781)"
STUB_DIFF_406_FILE="$CAP406" STUB_LOCAL_BASE="$(printf 'c%.0s' $(seq 1 40))" STUB_LOCAL_HEAD="$L_HEAD" \
  RECORD_REVIEW_LOCAL_REPO="$L_REPO" RECORD_REVIEW_LOCAL_DIFF_NOFETCH=1 \
  run_record_diff 424781 "$SHA" "PR body" /dev/null 0
if grep -qF "diff=" <<<"$RECORD_CAP"; then bad "11.11h a MISSING base object still produced a diff identity"; else ok "11.11h a missing revision is refused (no diff=)"; fi

# 11.11i: the base/head identity read failing must refuse, not fall through to a
#         local-ref guess.
rm -f "$(Q2 424782)"
STUB_DIFF_406_FILE="$CAP406" STUB_LOCAL_META_FAIL=1 STUB_LOCAL_BASE="$L_BASE" STUB_LOCAL_HEAD="$L_HEAD" \
  RECORD_REVIEW_LOCAL_REPO="$L_REPO" RECORD_REVIEW_LOCAL_DIFF_NOFETCH=1 \
  run_record_diff 424782 "$SHA" "PR body" /dev/null 0
if grep -qF "diff=" <<<"$RECORD_CAP"; then bad "11.11i a failed base/head read still produced a diff identity"; else ok "11.11i a failed base/head read is refused (no diff=)"; fi

# 11.11j/k: THE accept-and-spend GUARD. `atomic-land.sh` moves the head with a
# server-side `gh pr update-branch`, so the post-update commit exists ONLY on the
# remote. Without a fetch the fallback would fail AFTER the head moved — turning
# today's pre-update refusal into an accept-and-spend. These two vectors pin the
# fetch and show it is load-bearing: same repo state, fetch off => no hash,
# fetch on => the digest is minted from the fetched head.
BARE1398="$T/bare1398"
git init -q --bare "$BARE1398"
git -C "$L_REPO" push -q "$BARE1398" "$L_BASE:refs/heads/main" "$L_HEAD:refs/pull/424784/head"
make_partial_repo1398() { # <dir> [insteadOf-url]
    git init -q "$1"
    git -C "$1" config user.email "t@example.test"
    git -C "$1" config user.name "t"
    git -C "$1" remote add origin "https://github.com/daniel-ospina/agent-infra.git"
    [ -n "${2:-}" ] && git -C "$1" config "url.$2.insteadOf" "https://github.com/daniel-ospina/agent-infra.git"
    # Fetch ONLY the base ref; the PR head object stays absent.
    git -C "$1" fetch -q --no-tags "$BARE1398" "refs/heads/main:refs/remotes/local/base"
}
L_NOFETCH="$T/local-nofetch-1398"
make_partial_repo1398 "$L_NOFETCH"
L_FETCH="$T/local-fetch-1398"
make_partial_repo1398 "$L_FETCH" "$BARE1398"
if git -C "$L_FETCH" cat-file -e "$L_HEAD^{commit}" 2>/dev/null; then bad "11.11j fixture: the fetch repo must NOT already hold the PR head"; else ok "11.11j fixture: the PR head object is absent before the run"; fi
rm -f "$(Q2 424783)"
STUB_DIFF_406_FILE="$CAP406" STUB_LOCAL_BASE="$L_BASE" STUB_LOCAL_HEAD="$L_HEAD" \
  RECORD_REVIEW_LOCAL_REPO="$L_NOFETCH" RECORD_REVIEW_LOCAL_DIFF_NOFETCH=1 \
  run_record_diff 424783 "$SHA" "PR body" /dev/null 0
if grep -qF "diff=" <<<"$RECORD_CAP"; then bad "11.11j with the fetch DISABLED a missing head still produced a hash"; else ok "11.11j with the fetch disabled a missing head is refused (no diff=) — the fetch is load-bearing"; fi
rm -f "$(Q2 424784)"
STUB_DIFF_406_FILE="$CAP406" STUB_LOCAL_BASE="$L_BASE" STUB_LOCAL_HEAD="$L_HEAD" \
  RECORD_REVIEW_LOCAL_REPO="$L_FETCH" \
  run_record_diff 424784 "$SHA" "PR body" /dev/null 0
assert_contains "$(cat "$(Q2 424784)" 2>/dev/null)" "\"diff_sha256\":\"$L_SHA\"" "11.11k a MISSING post-update head is FETCHED and the digest minted (the accept-and-spend guard)"
if git -C "$L_FETCH" cat-file -e "$L_HEAD^{commit}" 2>/dev/null; then ok "11.11k the run actually fetched the head object"; else bad "11.11k the head object is still absent — the fetch did not run"; fi

# 11.11l: base == head is an EMPTY diff. Without the emptiness guard the fallback
#         would hand back a 0-byte body, sha256("") would become the recorded
#         digest, and every "PR" in that shape would share ONE constant identity
#         — a false accept. The digest must simply not be minted.
rm -f "$(Q2 424785)"
STUB_DIFF_406_FILE="$CAP406" STUB_LOCAL_BASE="$L_HEAD" STUB_LOCAL_HEAD="$L_HEAD" \
  RECORD_REVIEW_LOCAL_REPO="$L_REPO" RECORD_REVIEW_LOCAL_DIFF_NOFETCH=1 \
  run_record_diff 424785 "$SHA" "PR body" /dev/null 0
if grep -qF "diff=" <<<"$RECORD_CAP"; then bad "11.11l an EMPTY local diff produced a diff identity"; else ok "11.11l an empty local diff is refused (no diff=) — sha256(\"\") is not minted"; fi

# 11.11m: a HUNK-LESS (binary) entry keeps its `index` line VERBATIM, so an
#         ambient `core.abbrev` would decide the binding's collision resistance
#         (git's minimum is 4 hex). The implementation pins `--full-index`; this
#         fixture sets the HOSTILE `core.abbrev=4`, and the recorded digest must
#         still be the FULL-index one. Drop `--full-index` and this reddens
#         because the implementation would emit a 4-hex index line while the
#         expectation below is framed over the full-index rendering.
L_BIN="$T/local-bin-1398"
git init -q "$L_BIN"
git -C "$L_BIN" config user.email "t@example.test"
git -C "$L_BIN" config user.name "t"
git -C "$L_BIN" config core.abbrev 4
git -C "$L_BIN" remote add origin "https://github.com/daniel-ospina/agent-infra.git"
{ printf 'BIN\0'; printf '0001\n'; } > "$L_BIN/b.bin"
git -C "$L_BIN" add b.bin
git -C "$L_BIN" -c commit.gpgsign=false commit -q -m base
LB_BASE="$(git -C "$L_BIN" rev-parse HEAD)"
{ printf 'BIN\0'; printf '0002\n'; } > "$L_BIN/b.bin"
git -C "$L_BIN" -c commit.gpgsign=false commit -q -am head
LB_HEAD="$(git -C "$L_BIN" rev-parse HEAD)"
if git -C "$L_BIN" diff --no-color "$LB_BASE...$LB_HEAD" | grep -q '^Binary files'; then ok "11.11m fixture: the entry is hunk-less (binary) so its index line survives"; else bad "11.11m fixture: the entry is not binary"; fi
LB_SHA="$(local_diff_sha1398 "$L_BIN" "$LB_BASE" "$LB_HEAD")"
LB_SHA4="$(git -C "$L_BIN" -c core.abbrev=4 diff --no-color "$LB_BASE...$LB_HEAD" | python3 "$NORM1398" | openssl dgst -sha256 | awk '{print $NF}')"
if [ "$LB_SHA" != "$LB_SHA4" ]; then ok "11.11m the full-index and the 4-hex renderings really differ (the fixture is not degenerate)"; else bad "11.11m the fixture is degenerate: 4-hex and full-index normalize identically"; fi
rm -f "$(Q2 424786)"
STUB_DIFF_406_FILE="$CAP406" STUB_LOCAL_BASE="$LB_BASE" STUB_LOCAL_HEAD="$LB_HEAD" \
  RECORD_REVIEW_LOCAL_REPO="$L_BIN" RECORD_REVIEW_LOCAL_DIFF_NOFETCH=1 \
  run_record_diff 424786 "$SHA" "PR body" /dev/null 0
assert_contains "$(cat "$(Q2 424786)" 2>/dev/null)" "\"diff_sha256\":\"$LB_SHA\"" "11.11m a hunk-less entry is bound at FULL index width, not the ambient core.abbrev"
# 11.11n–p: WRAPPING-ROBUSTNESS of the cap classification (#1398). The
#         single-line requirement in `diff_body_is_error_object` (a `grep -c ''`
#         ≤ 1 line test) classified the real 406 only because GitHub emits it on
#         ONE line. A PRETTY-PRINTED / re-wrapped envelope — GitHub, or a proxy,
#         reformatting the error — fell through to the `nondiff` arm: the local
#         fallback was SKIPPED (the oversized PR returned to the unlandability
#         this fix removes) and the operator was told the body had NO entry
#         boundary instead of being told about the 300-file cap. The fixture
#         below is MUTATION-PINNED (11.11p) so it cannot pass vacuously.
CAP406_PRETTY="$T/cap-406-pretty.json"
printf '{\n  "message": "Sorry, the diff exceeded the maximum number of files (300).",\n  "errors": [\n    { "resource": "PullRequest", "field": "diff", "code": "too_large" }\n  ],\n  "documentation_url": "https://docs.github.com/rest/pulls/pulls",\n  "status": "406"\n}\n' > "$CAP406_PRETTY"
CAP406_PRETTY_SHA="$(openssl dgst -sha256 < "$CAP406_PRETTY" | awk '{print $NF}')"
[ "$(grep -c '' "$CAP406_PRETTY")" -gt 1 ] && ok "11.11n fixture: the pretty cap body is genuinely MULTI-LINE (non-vacuous)" || bad "11.11n fixture: the pretty cap body is single-line — the vector is vacuous"
grep -qE '^diff --git' "$CAP406_PRETTY" && bad "11.11n fixture: the pretty cap body must NOT contain a diff entry" || ok "11.11n fixture: the pretty cap body carries no 'diff --git' entry"

# (n) NO usable checkout: the pretty cap must still classify STRUCTURAL and the
#     diagnosis must name the CAP, not the missing entry boundary.
rm -f "$(Q2 424787)"
STUB_DIFF_406_FILE="$CAP406_PRETTY" STUB_LOCAL_BASE="$L_BASE" STUB_LOCAL_HEAD="$L_HEAD" \
  RECORD_REVIEW_LOCAL_REPO="$T/no-such-checkout-1398" \
  run_record_diff 424787 "$SHA" "PR body" /dev/null 0
[ "$RECORD_RC" = "0" ] && ok "11.11n a pretty-printed cap still records (rc 0)" || bad "11.11n rc=$RECORD_RC (err=$RECORD_ERR)"
[ "$(grep -cF 'application/vnd.github.v3.diff' "$LOG")" = "1" ] && ok "11.11n a pretty-printed cap is STRUCTURAL, not retried (1 attempt)" || bad "11.11n made $(grep -cF 'application/vnd.github.v3.diff' "$LOG") attempts (expected 1)"
if grep -qF "diff=" <<<"$RECORD_CAP"; then bad "11.11n the pretty cap error body was hashed (diff= present)"; else ok "11.11n no diff= — the pretty cap body is never hashed"; fi
if grep -qF "diff=$CAP406_PRETTY_SHA" <<<"$RECORD_CAP"; then bad "11.11n the pretty 406 body's own sha256 was recorded as the reviewed diff"; else ok "11.11n the pretty 406 body's own sha256 is NOT recorded"; fi
if grep -q '"diff_sha256"' "$(Q2 424787)" 2>/dev/null; then bad "11.11n record carries a diff_sha256 minted from the pretty error body"; else ok "11.11n record omits diff_sha256"; fi
assert_contains "$RECORD_ERR" "300-FILE DIFF CAP" "11.11n the message names the 300-file cap"
if grep -qF "NO 'diff --git' entry boundary" <<<"$RECORD_ERR"; then bad "11.11n the pretty cap was misdiagnosed as the nondiff arm"; else ok "11.11n the pretty cap is NOT misdiagnosed as nondiff"; fi
assert_contains "$RECORD_ERR" "RETRYING WILL NOT HELP" "11.11n says retrying will not help"
if grep -qF "gh/API/openssl unavailable" <<<"$RECORD_ERR"; then bad "11.11n misdiagnoses the pretty cap as a tooling outage"; else ok "11.11n does NOT blame gh/openssl"; fi

# (o) WITH a checkout: the fallback must be ATTEMPTED for the pretty cap and mint
#     the SAME digest as the one-line body — a skipped fallback leaves no diff=.
rm -f "$(Q2 424788)"
STUB_DIFF_406_FILE="$CAP406_PRETTY" STUB_LOCAL_BASE="$L_BASE" STUB_LOCAL_HEAD="$L_HEAD" \
  RECORD_REVIEW_LOCAL_REPO="$L_REPO" \
  run_record_diff 424788 "$SHA" "PR body" /dev/null 0
[ "$RECORD_RC" = "0" ] && ok "11.11o a pretty cap with a checkout records (rc 0)" || bad "11.11o rc=$RECORD_RC (err=$RECORD_ERR)"
assert_contains "$(cat "$(Q2 424788)" 2>/dev/null)" "\"diff_sha256\":\"$L_SHA\"" "11.11o the fallback is ATTEMPTED for the pretty cap and mints the LOCAL digest"
assert_contains "$RECORD_CAP" "diff=$L_SHA" "11.11o the marker carries the LOCAL digest for the pretty cap"
[ "$(grep -cF 'application/vnd.github.v3.diff' "$LOG")" = "1" ] && ok "11.11o the pretty cap is not re-fetched (1 attempt)" || bad "11.11o attempts=$(grep -cF 'application/vnd.github.v3.diff' "$LOG")"
if grep -qF "diff=$CAP406_PRETTY_SHA" <<<"$RECORD_CAP"; then bad "11.11o the pretty error body was hashed instead of the local digest"; else ok "11.11o the pretty error body is never hashed"; fi
assert_contains "$RECORD_ERR" "computed from the LOCAL checkout" "11.11o the provenance is stated for the pretty cap"

# (p) MUTATION PIN — restore the `≤1 line` blind spot and show the pretty vector
#     reddens: the pretty cap is demoted to the `nondiff` arm, the fallback is
#     SKIPPED, and the operator is misdiagnosed. This is the regression 11.11n/o
#     exist to prevent, so those vectors are load-bearing, not green by accident.
mkdir -p "$T/mut-lines/lib"
cp "$SCRIPT_DIR/lib/diff-normalize.py" "$T/mut-lines/lib/diff-normalize.py"
python3 - "$RECORD" "$T/mut-lines/record-review.sh" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
old = """  command grep -qE '^diff --git ' "$1" 2>/dev/null && return 1
  # Flatten"""
new = """  command grep -qE '^diff --git ' "$1" 2>/dev/null && return 1
  [ "$(command grep -c '' "$1" 2>/dev/null)" -le 1 ] || return 1  # MUTATION: the <=1-line blind spot
  # Flatten"""
assert old in text, "mutation anchor not found"
open(dst, "w").write(text.replace(old, new, 1))
PY
if cmp -s "$T/mut-lines/record-review.sh" "$RECORD"; then bad "11.11p mutation(p): the mutant copy is IDENTICAL to the script"; else ok "11.11p mutation(p): the mutant copy differs from the script"; fi
rm -f "$(Q2 424789)"
STUB_DIFF_406_FILE="$CAP406_PRETTY" STUB_LOCAL_BASE="$L_BASE" STUB_LOCAL_HEAD="$L_HEAD" \
  RECORD_REVIEW_LOCAL_REPO="$L_REPO" \
  run_record_diff_with "$T/mut-lines/record-review.sh" 424789 "$SHA" "PR body" /dev/null 0
if grep -qF "diff=$L_SHA" <<<"$RECORD_CAP"; then bad "11.11p mutation(p): the mutant still minted the fallback digest — 11.11o is vacuous"; else ok "11.11p mutation(p): with the <=1-line blind spot restored the fallback is SKIPPED (rc=$RECORD_RC) — 11.11o is load-bearing"; fi
# The MEASURED 406 exits NON-ZERO with the envelope on stdout, so the blind spot
# drops the pretty cap onto the RETRYABLE `unavailable` arm (gh/auth/network
# blame, and a STRUCTURAL refusal retried), NOT the exit-0 `nondiff` arm. Assert
# the true regression, not the finding's short form.
if grep -qF "300-FILE DIFF CAP" <<<"$RECORD_ERR"; then bad "11.11p mutation(p): the mutant still named the cap — 11.11n is vacuous"; else ok "11.11p mutation(p): with the blind spot restored the pretty cap is NOT named as a cap"; fi
assert_contains "$RECORD_ERR" "transient: gh auth/network" "11.11p mutation(p): the mutant blames the transient gh/network arm (the regression 11.11n pins)"

# 11.11q–t: SHARED-FLATTEN drift between the two classifiers (#1398 round 2). The
#         previous fix made `diff_body_is_error_object` line-agnostic, but
#         `diff_body_is_size_cap` still re-grepped the ORIGINAL, line-oriented
#         body — where `[[:space:]]*` cannot cross a newline. An envelope whose
#         VALUES sit on the next line for BOTH keys was therefore recognised as an
#         ERROR and NOT as the size cap: `error_object=YES, size_cap=NO`. The
#         fallback was SKIPPED and the structural refusal was warned as a
#         transient gh/auth/network fault and RETRIED — the round-1 P3 behind a
#         narrower trigger. Sharing ONE flatten between the predicates is the fix;
#         these vectors MUTATION-PIN it (11.11t) so it cannot regress silently.
CAP406_SPLIT="$T/cap-406-split.json"
printf '{ "status":\n "406", "code":\n "too_large" }\n' > "$CAP406_SPLIT"
CAP406_SPLIT_SHA="$(openssl dgst -sha256 < "$CAP406_SPLIT" | awk '{print $NF}')"
[ "$(grep -c '' "$CAP406_SPLIT")" -gt 1 ] && ok "11.11q fixture: the split-value body is genuinely MULTI-LINE (non-vacuous)" || bad "11.11q fixture: the split-value body is single-line — the vector is vacuous"
grep -qE '^diff --git' "$CAP406_SPLIT" && bad "11.11q fixture: the split-value body must NOT contain a diff entry" || ok "11.11q fixture: the split-value body carries no 'diff --git' entry"
# The trigger is specifically the VALUE after the colon on the NEXT line: assert
# the RAW body defeats the line-oriented matcher the old size-cap predicate used.
grep -qE '"status"[[:space:]]*:[[:space:]]*"?406"?' "$CAP406_SPLIT" && bad "11.11q fixture: the raw body already matches the line-oriented grep — the trigger is not exercised" || ok "11.11q fixture: the raw body defeats a line-oriented grep (the trigger is real)"

# (q) NO usable checkout: the split-value cap must still classify STRUCTURAL.
rm -f "$(Q2 424790)"
STUB_DIFF_406_FILE="$CAP406_SPLIT" STUB_LOCAL_BASE="$L_BASE" STUB_LOCAL_HEAD="$L_HEAD" \
  RECORD_REVIEW_LOCAL_REPO="$T/no-such-checkout-1398" \
  run_record_diff 424790 "$SHA" "PR body" /dev/null 0
[ "$RECORD_RC" = "0" ] && ok "11.11q a split-value cap still records (rc 0)" || bad "11.11q rc=$RECORD_RC (err=$RECORD_ERR)"
[ "$(grep -cF 'application/vnd.github.v3.diff' "$LOG")" = "1" ] && ok "11.11q a split-value cap is STRUCTURAL, not retried (1 attempt)" || bad "11.11q made $(grep -cF 'application/vnd.github.v3.diff' "$LOG") attempts (expected 1)"
if grep -qF "diff=" <<<"$RECORD_CAP"; then bad "11.11q the split-value cap error body was hashed (diff= present)"; else ok "11.11q no diff= — the split-value cap body is never hashed"; fi
if grep -qF "diff=$CAP406_SPLIT_SHA" <<<"$RECORD_CAP"; then bad "11.11q the split-value 406 body's own sha256 was recorded as the reviewed diff"; else ok "11.11q the split-value 406 body's own sha256 is NOT recorded"; fi
if grep -q '"diff_sha256"' "$(Q2 424790)" 2>/dev/null; then bad "11.11q record carries a diff_sha256 minted from the split-value error body"; else ok "11.11q record omits diff_sha256"; fi
assert_contains "$RECORD_ERR" "300-FILE DIFF CAP" "11.11q the message names the 300-file cap"
if grep -qF "NO 'diff --git' entry boundary" <<<"$RECORD_ERR"; then bad "11.11q the split-value cap was misdiagnosed as the nondiff arm"; else ok "11.11q the split-value cap is NOT misdiagnosed as nondiff"; fi
assert_contains "$RECORD_ERR" "RETRYING WILL NOT HELP" "11.11q says retrying will not help"
if grep -qF "gh/API/openssl unavailable" <<<"$RECORD_ERR"; then bad "11.11q misdiagnoses the split-value cap as a tooling outage"; else ok "11.11q does NOT blame gh/openssl"; fi
if grep -qF "transient: gh auth/network" <<<"$RECORD_ERR"; then bad "11.11q blames the transient gh/network arm (the misdiagnosed, retried shape)"; else ok "11.11q is NOT warned as a transient gh/network fault"; fi

# (r) WITH a checkout: the fallback must be ATTEMPTED for the split-value cap and
#     mint the SAME digest as every other 406 shape — a skipped fallback leaves no
#     diff= and returns the oversized PR to the unlandability #1398 removes.
rm -f "$(Q2 424791)"
STUB_DIFF_406_FILE="$CAP406_SPLIT" STUB_LOCAL_BASE="$L_BASE" STUB_LOCAL_HEAD="$L_HEAD" \
  RECORD_REVIEW_LOCAL_REPO="$L_REPO" \
  run_record_diff 424791 "$SHA" "PR body" /dev/null 0
[ "$RECORD_RC" = "0" ] && ok "11.11r a split-value cap with a checkout records (rc 0)" || bad "11.11r rc=$RECORD_RC (err=$RECORD_ERR)"
assert_contains "$(cat "$(Q2 424791)" 2>/dev/null)" "\"diff_sha256\":\"$L_SHA\"" "11.11r the fallback is ATTEMPTED for the split-value cap and mints the LOCAL digest"
assert_contains "$RECORD_CAP" "diff=$L_SHA" "11.11r the marker carries the LOCAL digest for the split-value cap"
[ "$(grep -cF 'application/vnd.github.v3.diff' "$LOG")" = "1" ] && ok "11.11r the split-value cap is not re-fetched (1 attempt)" || bad "11.11r attempts=$(grep -cF 'application/vnd.github.v3.diff' "$LOG")"
if grep -qF "diff=$CAP406_SPLIT_SHA" <<<"$RECORD_CAP"; then bad "11.11r the split-value error body was hashed instead of the local digest"; else ok "11.11r the split-value error body is never hashed"; fi
assert_contains "$RECORD_ERR" "computed from the LOCAL checkout" "11.11r the provenance is stated for the split-value cap"

# (s) the boundary is DECISIVE: a REAL diff that CONTAINS the same split envelope
#     text is still a diff and is hashed as one — the shared flatten refuses a
#     body carrying a `^diff --git` entry BEFORE any JSON test, so no wrapping and
#     no JSON content can demote a real diff.
SPLIT_DIFF="$T/split-envelope-in-a-diff.diff"
printf 'diff --git a/f b/f\nindex 1111111..2222222 100644\n--- a/f\n+++ b/f\n@@ -1,2 +1,5 @@\n ctx\n+{ "status":\n+ "406", "code":\n+ "too_large" }\n ctx2\n' > "$SPLIT_DIFF"
SPLIT_DIFF_SHA="$(python3 "$NORM1398" < "$SPLIT_DIFF" | openssl dgst -sha256 | awk '{print $NF}')"
rm -f "$(Q2 424792)"
STUB_DIFF_FILE="$SPLIT_DIFF" STUB_DIFF_FAIL=0 \
  RECORD_REVIEW_LOCAL_REPO="$T/no-such-checkout-1398" \
  run_record_diff 424792 "$SHA" "PR body" "$SPLIT_DIFF" 0
assert_contains "$(cat "$(Q2 424792)" 2>/dev/null)" "\"diff_sha256\":\"$SPLIT_DIFF_SHA\"" "11.11s a diff containing the split envelope text is still hashed as a diff"
if grep -qF '300-FILE DIFF CAP' <<<"$RECORD_ERR"; then bad "11.11s the diff carrying the envelope was misclassified as the size cap"; else ok "11.11s the diff carrying the envelope is NOT misclassified as a cap"; fi

# (t) MUTATION PIN — restore the line-oriented re-grep of the ORIGINAL body in
#     `diff_body_is_size_cap` (the round-2 drift) and show the split-value vector
#     reddens: the cap is not recognised, the fallback is SKIPPED, and the
#     structural refusal is blamed on gh/network and RETRIED. 11.11q/r are
#     load-bearing, not green by accident.
mkdir -p "$T/mut-splitcap/lib"
cp "$SCRIPT_DIR/lib/diff-normalize.py" "$T/mut-splitcap/lib/diff-normalize.py"
python3 - "$RECORD" "$T/mut-splitcap/record-review.sh" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
old = """diff_body_is_size_cap() { # <file> -> 0 when the body declares the 300-file cap
  local flat
  flat="$(diff_body_flatten "$1")" || return 1
  flat_body_is_error_object "$flat" || return 1
  flat_body_is_size_cap "$flat"
}"""
new = """diff_body_is_size_cap() { # <file> -> 0 when the body declares the 300-file cap
  local flat
  flat="$(diff_body_flatten "$1")" || return 1
  flat_body_is_error_object "$flat" || return 1
  # MUTATION: re-grep the ORIGINAL, line-oriented body (the round-2 drift).
  command grep -qE '"status"[[:space:]]*:[[:space:]]*"?406"?' "$1" 2>/dev/null && return 0
  command grep -qE '"code"[[:space:]]*:[[:space:]]*"too_large"' "$1" 2>/dev/null && return 0
  return 1
}"""
assert old in text, "mutation anchor not found"
open(dst, "w").write(text.replace(old, new, 1))
PY
if cmp -s "$T/mut-splitcap/record-review.sh" "$RECORD"; then bad "11.11t mutation(t): the mutant copy is IDENTICAL to the script"; else ok "11.11t mutation(t): the mutant copy differs from the script"; fi
rm -f "$(Q2 424793)"
STUB_DIFF_406_FILE="$CAP406_SPLIT" STUB_LOCAL_BASE="$L_BASE" STUB_LOCAL_HEAD="$L_HEAD" \
  RECORD_REVIEW_LOCAL_REPO="$L_REPO" \
  run_record_diff_with "$T/mut-splitcap/record-review.sh" 424793 "$SHA" "PR body" /dev/null 0
if grep -qF "diff=$L_SHA" <<<"$RECORD_CAP"; then bad "11.11t mutation(t): the mutant still minted the fallback digest — 11.11r is vacuous"; else ok "11.11t mutation(t): with the line-oriented re-grep restored the fallback is SKIPPED (rc=$RECORD_RC) — 11.11r is load-bearing"; fi
if grep -qF "300-FILE DIFF CAP" <<<"$RECORD_ERR"; then bad "11.11t mutation(t): the mutant still named the cap — 11.11q is vacuous"; else ok "11.11t mutation(t): with the re-grep restored the split-value cap is NOT named as a cap"; fi
assert_contains "$RECORD_ERR" "transient: gh auth/network" "11.11t mutation(t): the mutant blames the transient gh/network arm (the regression 11.11q pins)"

# (u) the flatten BOUND is real. Flattening materialised the body as a shell
#     string (O(size); a 2 MB envelope cost ~2.3 s), so `diff_body_flatten`
#     refuses a body above ${RECORD_REVIEW_BODY_MAX_BYTES:-262144} instead of
#     trusting the envelope to be small. Pin it with a body the same 406 shape
#     but a bound set below its size: without the check the cap WOULD classify
#     and the fallback WOULD mint diff=$L_SHA, so this is load-bearing, and the
#     refusal is fail-closed (never hashed).
rm -f "$(Q2 424794)"
RECORD_REVIEW_BODY_MAX_BYTES=1 \
  STUB_DIFF_406_FILE="$CAP406" STUB_LOCAL_BASE="$L_BASE" STUB_LOCAL_HEAD="$L_HEAD" \
  RECORD_REVIEW_LOCAL_REPO="$L_REPO" \
  run_record_diff 424794 "$SHA" "PR body" /dev/null 0
if grep -qF "diff=" <<<"$RECORD_CAP"; then bad "11.11u an over-bound non-diff body was hashed (the bound is not enforced)"; else ok "11.11u an over-bound non-diff body is refused — never classified, never hashed"; fi
if grep -qF "300-FILE DIFF CAP" <<<"$RECORD_ERR"; then bad "11.11u an over-bound body was still classified as the cap"; else ok "11.11u an over-bound body is not flattened or classified"; fi

# ─────────────────────────────────────────────────────────────────────────
# 11.12 #1351 — the READ-ONLY consumer seam: `--print-diff-hash <pr> [repo]`
# ─────────────────────────────────────────────────────────────────────────
# The local merge gate (extensions/review-enforcer) accepts a recorded review
# whose `diff_sha256` matches the PR's CURRENT diff even at a stale head — the
# same content-identity carry the GitHub ai-review-gate implements. It must use
# THIS script's diff machinery rather than a second hashing scheme, so the seam
# prints `<status>\t<hash>` from `diff_hash_for_pr` and exits before any write.
# These pin the contract the extension parses: ONLY `ok` carries a digest, a
# degraded/refused fetch NEVER does, and no record is written.
echo "── 11.12 #1351: --print-diff-hash (read-only consumer seam) ────────"
PDH_DIFF="$T/prdh-real.diff"
printf 'diff --git a/docs/x.md b/docs/x.md\nindex 1111111..2222222 100644\n--- a/docs/x.md\n+++ b/docs/x.md\n@@ -1,3 +1,4 @@\n a\n+b\n c\n d\n' > "$PDH_DIFF"
PDH_SHA="$(python3 "$NORM1398" < "$PDH_DIFF" | openssl dgst -sha256 | awk '{print $NF}')"
PDH_TAB="$(printf '\t')"
PDH_EMPTY_DIGEST="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

run_print_diff_hash() { # <pr> [repo] -> PDH_OUT / PDH_RC
    PDH_OUT="$(PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG" \
        STUB_DIFF_FILE="${STUB_DIFF_FILE:-/dev/null}" STUB_DIFF_FAIL="${STUB_DIFF_FAIL:-0}" \
        STUB_DIFF_406_FILE="${STUB_DIFF_406_FILE:-}" \
        STUB_LOCAL_BASE="${STUB_LOCAL_BASE:-}" STUB_LOCAL_HEAD="${STUB_LOCAL_HEAD:-}" \
        RECORD_REVIEW_LOCAL_REPO="${RECORD_REVIEW_LOCAL_REPO:-.}" \
        bash "$RECORD" --print-diff-hash "$1" "${2:-daniel-ospina/agent-infra}" 2>"$T/pdh-err")"
    PDH_RC=$?
}

# (a) a readable diff → ok + the SAME normalized digest the record path stores.
rm -f "$(Q2 424800)"
STUB_DIFF_FILE="$PDH_DIFF" STUB_DIFF_FAIL=0 run_print_diff_hash 424800
assert_eq "$PDH_RC" "0" "11.12a exit 0 (the status field carries the outcome)"
assert_eq "$PDH_OUT" "ok${PDH_TAB}${PDH_SHA}" "11.12a a readable diff prints ok + the normalized digest"
if [ -e "$(Q2 424800)" ]; then bad "11.12a the read-only mode wrote a record"; else ok "11.12a no record is written"; fi

# (b) the EMPTY body — the CONSTANT-digest trap. It must print `empty` with NO
#     digest; sha256("") would collide across every PR and carry any stale record.
STUB_DIFF_FILE=/dev/null STUB_DIFF_FAIL=0 run_print_diff_hash 424801
assert_eq "$PDH_OUT" "empty${PDH_TAB}" "11.12b an empty body prints empty + NO digest"
if grep -qF "$PDH_EMPTY_DIGEST" <<<"$PDH_OUT"; then bad "11.12b THE TRAP: sha256(\"\") was printed as a digest"; else ok "11.12b sha256(\"\") is never printed"; fi

# (c) a 2xx whose body is not a diff (an error object) → nondiff, never hashed.
PDH_NONDIFF="$T/prdh-nondiff.json"
printf '%s' '{"message":"Not Found","documentation_url":"https://docs.github.com/rest","status":"404"}' > "$PDH_NONDIFF"
STUB_DIFF_FILE="$PDH_NONDIFF" STUB_DIFF_FAIL=0 run_print_diff_hash 424802
assert_eq "$PDH_OUT" "nondiff${PDH_TAB}" "11.12c a non-diff body prints nondiff + NO digest"

# (d) the DOCUMENTED 300-file cap, with no usable local checkout → too_large.
STUB_DIFF_406_FILE="$CAP406" RECORD_REVIEW_LOCAL_REPO="$T/no-such-checkout-1398" run_print_diff_hash 424803
assert_eq "$PDH_OUT" "too_large${PDH_TAB}" "11.12d the API cap prints too_large + NO digest"

# (e) a failed read → unavailable (NEVER a digest: a failed read is not a match).
STUB_DIFF_FAIL=1 run_print_diff_hash 424804
assert_eq "$PDH_OUT" "unavailable${PDH_TAB}" "11.12e a failed fetch prints unavailable + NO digest"

# (f) the #1398 fallback is available to the SEAM too: the cap with a local
#     checkout holding both objects mints the local digest (so an oversized PR
#     still carries across a base refresh).
STUB_DIFF_406_FILE="$CAP406" RECORD_REVIEW_LOCAL_REPO="$L_REPO" \
  STUB_LOCAL_BASE="$L_BASE" STUB_LOCAL_HEAD="$L_HEAD" run_print_diff_hash 424805
assert_eq "$PDH_OUT" "ok${PDH_TAB}${L_SHA}" "11.12f the size-cap fallback mints the LOCAL normalized digest"

# NOTE: a former §11.12g looped over four hardcoded `<status>TAB` literals and
# asserted their (hand-constructed) hash field was empty. It never invoked
# `run_print_diff_hash`, so it could not fail whatever the seam emitted —
# TAUTOLOGICAL, not coverage. The contract it claimed to pin (only `ok` carries
# a digest) is already pinned by 11.12b-e, each of which RUNS the seam and
# asserts the full `<status>TAB` output — so the loop was deleted rather than
# reworded. The four non-ok statuses are the seam's complete non-ok set.
unset PDH_OUT PDH_RC PDH_TAB PDH_EMPTY_DIGEST PDH_NONDIFF

unset STUB_DIFF_406_FILE STUB_LOCAL_BASE STUB_LOCAL_HEAD STUB_LOCAL_META_FAIL STUB_LOCAL_BASE_REF RECORD_REVIEW_LOCAL_DIFF_NOFETCH STUB_DIFF_FAIL STUB_DIFF_FILE NORM1398 L_REPO L_BASE L_HEAD L_SHA CAP406 CAP406_SHA CAP406_PRETTY CAP406_PRETTY_SHA CAP406_SPLIT CAP406_SPLIT_SHA SPLIT_DIFF SPLIT_DIFF_SHA API_STYLE API_STYLE_SHA REAL_WITH_CODE REAL_WITH_CODE_SHA L_WRONG L_NOFETCH L_FETCH BARE1398 L_BIN LB_BASE LB_HEAD LB_SHA LB_SHA4

# ─────────────────────────────────────────────────────────────────────────
# 12. #1362 D1 — the review-evidence digest is computed over the NORMALIZED
#     diff (owner ruling 2026-09-23), with a raw-hash backward-compat arm.
# ─────────────────────────────────────────────────────────────────────────
# The normalization itself is pinned BYTE-FOR-BYTE by
# scripts/diff-normalize.test.sh. THIS section pins the PRODUCER's use of it
# end-to-end and carries the four required mutation pins ((a)-(d)) plus §12f,
# the binary fail-open the 2026-09-23 amendment closed (with its own mutation
# pin). Each mutant
# is a real copy of record-review.sh whose SIBLING lib/diff-normalize.py is a
# different primitive — the shared-normalizer design is what makes the mutation
# a single-file swap — so every property test is shown to FAIL when its own
# mechanism is removed.
echo "── 12. #1362 D1: normalized diff digest + backward compat ──────"

NFX="$T/n-b1.diff";  printf 'diff --git a/f b/f\nindex 1111111..2222222 100644\n--- a/f\n+++ b/f\n@@ -1,3 +1,4 @@\n ctx\n+added\n ctx2\n' > "$NFX"
NFX2="$T/n-b2.diff"; printf 'diff --git a/f b/f\nindex aaaaaaa..bbbbbbb 100644\n--- a/f\n+++ b/f\n@@ -10,3 +11,4 @@\n ctx\n+added\n ctx2\n' > "$NFX2"
NFXC="$T/n-content.diff"; printf 'diff --git a/f b/f\nindex aaaaaaa..bbbbbbb 100644\n--- a/f\n+++ b/f\n@@ -10,3 +11,4 @@\n ctx\n+added-CHANGED\n ctx2\n' > "$NFXC"
NFXW="$T/n-ws.diff"; printf 'diff --git a/f b/f\nindex aaaaaaa..bbbbbbb 100644\n--- a/f\n+++ b/f\n@@ -10,3 +11,4 @@\n ctx\n+ added\n ctx2\n' > "$NFXW"

NORM_PY="$SCRIPT_DIR/lib/diff-normalize.py"
norm_sha_with() { python3 "$1" < "$2" | openssl dgst -sha256 | awk '{print $NF}'; }
norm_sha() { norm_sha_with "$NORM_PY" "$1"; }
raw_sha()  { openssl dgst -sha256 < "$1" | awk '{print $NF}'; }
signed_marker() { # <pr> <sha> <diff> → the signed marker line
    local pr="$1" sha="$2" diff="$3" text
    text="review recorded: reviews/${pr}.json verdict=clean @ ${sha} diff=${diff} (daniel-ospina/agent-infra)"
    printf '%s sig=%s' "$text" "$(printf '%s' "$text" | openssl dgst -sha256 -hmac "$TEST_GATE_KEY" | awk '{print $NF}')"
}
assert_ne() { if [ "$1" != "$2" ]; then ok "$3"; else bad "$3"; fi; }

# (a) a BASE-ONLY update (same changed lines, different base) leaves the
#     normalized digest UNCHANGED — the whole point of D1.
NH="$(norm_sha "$NFX")"
assert_eq "$NH" "$(norm_sha "$NFX2")" "12a direct: a base move leaves the NORMALIZED digest unchanged"
assert_ne "$(raw_sha "$NFX")" "$(raw_sha "$NFX2")" "12a direct: the RAW digest DID move (normalization is what fixes it)"
NPR_a=424700; rm -f "$(Q2 $NPR_a)"
run_record_diff "$NPR_a" "$STALE" "body

$(signed_marker $NPR_a "$STALE" "$NH")" "$NFX2"
[ "$RECORD_RC" = "0" ] && ok "12a carry-forward across a base-only update (rc 0)" || bad "12a base-only update refused (rc=$RECORD_RC, err=$RECORD_ERR)"
assert_contains "$RECORD_CAP" "diff=$NH" "12a re-records the unchanged normalized digest at the current head"

# (b) a real CONTENT change DOES change the digest.
assert_ne "$NH" "$(norm_sha "$NFXC")" "12b direct: a content change changes the normalized digest"
NPR_b=424701; rm -f "$(Q2 $NPR_b)"
run_record_diff "$NPR_b" "$STALE" "body

$(signed_marker $NPR_b "$STALE" "$NH")" "$NFXC"
[ "$RECORD_RC" = "3" ] && ok "12b a content change is NOT carried (rc 3)" || bad "12b carried a changed diff (rc=$RECORD_RC)"
[ ! -f "$(Q2 $NPR_b)" ] && ok "12b no record written for the changed diff" || bad "12b wrote a record for a changed diff"

# (c) a WHITESPACE-ONLY change DOES change the digest — THE ANTI-patch-id PIN.
#     `git patch-id --stable` (and the default) IGNORE whitespace, so under it
#     this change would carry. The binding is sha256 over content.
assert_ne "$NH" "$(norm_sha "$NFXW")" "12c direct: a whitespace-only change changes the normalized digest"
NPR_c=424702; rm -f "$(Q2 $NPR_c)"
run_record_diff "$NPR_c" "$STALE" "body

$(signed_marker $NPR_c "$STALE" "$NH")" "$NFXW"
[ "$RECORD_RC" = "3" ] && ok "12c a whitespace-only change is NOT carried (rc 3)" || bad "12c carried a whitespace-only change (rc=$RECORD_RC)"

# (d) BACKWARD COMPAT — a LEGACY RAW-hash marker still carries forward.
RH="$(raw_sha "$NFX2")"
assert_ne "$RH" "$NH" "12d the raw hash differs from the normalized one (the fixture is not degenerate)"
NPR_d=424703; rm -f "$(Q2 $NPR_d)"
run_record_diff "$NPR_d" "$STALE" "body

$(signed_marker $NPR_d "$STALE" "$RH")" "$NFX2"
[ "$RECORD_RC" = "0" ] && ok "12d a legacy raw-hash marker carries forward (rc 0)" || bad "12d legacy raw marker refused (rc=$RECORD_RC, err=$RECORD_ERR)"
assert_contains "$RECORD_CAP" "diff=$NH" "12d the re-record UPGRADES the binding to the normalized hash"

# ── 12e MUTATION PINS ──────────────────────────────────────────────────────
mut_dir() { # <dir> — a record-review.sh copy; its sibling normalizer is swapped next
    mkdir -p "$1/lib"
    cp "$RECORD" "$1/record-review.sh"
}
# M_RAW — normalization removed (passthrough) → the pre-#1362 primitive.
mut_dir "$T/mut-raw"
cat > "$T/mut-raw/lib/diff-normalize.py" <<'PY'
import sys
sys.stdout.buffer.write(sys.stdin.buffer.read())
PY
# Positive control: the passthrough mutant really IS the raw primitive. Without
# this, mutation(a) could stay green against a broken/unused mutant lib.
assert_eq "$(norm_sha_with "$T/mut-raw/lib/diff-normalize.py" "$NFX")" "$(raw_sha "$NFX")" \
  "12e mutation(a): the passthrough mutant really is the raw primitive"
NPR_m=424710; rm -f "$(Q2 $NPR_m)"
# The prior marker is the RAW hash of the base-1 diff — what the pre-change
# producer would have minted.
run_record_diff_with "$T/mut-raw/record-review.sh" "$NPR_m" "$STALE" "body

$(signed_marker $NPR_m "$STALE" "$(raw_sha "$NFX")")" "$NFX2"
[ "$RECORD_RC" = "3" ] && ok "12e mutation(a): with normalization REMOVED the base-only update is refused again (rc 3) — 12a is load-bearing" || bad "12e mutation(a): the raw path still carried (rc=$RECORD_RC) — 12a is NOT testing normalization"

# M_NOCONTENT — drops every +/- hunk-body line → content-blind.
mut_dir "$T/mut-nocontent"
cat > "$T/mut-nocontent/lib/diff-normalize.py" <<'PY'
import re, sys
raw = sys.stdin.buffer.read().decode("latin-1")
out = []
for line in raw.split("\n"):
    if re.match(r"^index [0-9a-f]+\.\.[0-9a-f]+( [0-7]{6})?$", line):
        continue
    m = re.match(r"^@@ -([0-9]+)(,([0-9]+))? \+([0-9]+)(,([0-9]+))? @@(.*)$", line)
    if m:
        line = "@@ -0,%s +0,%s @@%s" % (m.group(3) or "1", m.group(6) or "1", m.group(7))
    if line.startswith("+") or line.startswith("-"):
        continue   # MUTATION: hunk content is ignored
    out.append(line)
sys.stdout.buffer.write("\n".join(out).encode("latin-1"))
PY
MNC_H="$(norm_sha_with "$T/mut-nocontent/lib/diff-normalize.py" "$NFX2")"
assert_eq "$MNC_H" "$(norm_sha_with "$T/mut-nocontent/lib/diff-normalize.py" "$NFXC")" \
  "12e mutation(b): a CONTENT-BLIND primitive makes the content change invisible"
NPR_m=424711; rm -f "$(Q2 $NPR_m)"
run_record_diff_with "$T/mut-nocontent/record-review.sh" "$NPR_m" "$STALE" "body

$(signed_marker $NPR_m "$STALE" "$MNC_H")" "$NFXC"
[ "$RECORD_RC" = "0" ] && ok "12e mutation(b): under a content-blind primitive the content change WOULD carry (rc 0) — 12b is load-bearing" || bad "12e mutation(b): expected a false carry (rc=$RECORD_RC)"

# M_WSBLIND — strips all whitespace → the `patch-id --stable` hole.
mut_dir "$T/mut-ws"
cat > "$T/mut-ws/lib/diff-normalize.py" <<'PY'
import re, sys
raw = sys.stdin.buffer.read().decode("latin-1")
out = []
for line in raw.split("\n"):
    if re.match(r"^index [0-9a-f]+\.\.[0-9a-f]+( [0-7]{6})?$", line):
        continue
    m = re.match(r"^@@ -([0-9]+)(,([0-9]+))? \+([0-9]+)(,([0-9]+))? @@(.*)$", line)
    if m:
        line = "@@ -0,%s +0,%s @@%s" % (m.group(3) or "1", m.group(6) or "1", m.group(7))
    out.append(re.sub(r"[ \t]", "", line))   # MUTATION: whitespace is ignored
sys.stdout.buffer.write("\n".join(out).encode("latin-1"))
PY
MWS_H="$(norm_sha_with "$T/mut-ws/lib/diff-normalize.py" "$NFX2")"
assert_eq "$MWS_H" "$(norm_sha_with "$T/mut-ws/lib/diff-normalize.py" "$NFXW")" \
  "12e mutation(c): a WHITESPACE-BLIND primitive makes the ws change invisible"
NPR_m=424712; rm -f "$(Q2 $NPR_m)"
run_record_diff_with "$T/mut-ws/record-review.sh" "$NPR_m" "$STALE" "body

$(signed_marker $NPR_m "$STALE" "$MWS_H")" "$NFXW"
[ "$RECORD_RC" = "0" ] && ok "12e mutation(c): under a whitespace-blind primitive the ws change WOULD carry (rc 0) — 12c is load-bearing" || bad "12e mutation(c): expected a false carry (rc=$RECORD_RC)"

# M_NOLEGACY — the carry grep accepts ONLY the normalized hash.
mkdir -p "$T/mut-nolegacy/lib"
cp "$NORM_PY" "$T/mut-nolegacy/lib/diff-normalize.py"
sed 's#^\( *\)PRIOR_DIFF_ALT=.*#\1PRIOR_DIFF_ALT="$DIFF_HASH"#' "$RECORD" > "$T/mut-nolegacy/record-review.sh"
if cmp -s "$T/mut-nolegacy/record-review.sh" "$RECORD"; then bad "12e mutation(d): the legacy-arm sed did not change the script"; else ok "12e mutation(d): the legacy-arm removal mutant differs from the script"; fi
NPR_m=424713; rm -f "$(Q2 $NPR_m)"
run_record_diff_with "$T/mut-nolegacy/record-review.sh" "$NPR_m" "$STALE" "body

$(signed_marker $NPR_m "$STALE" "$RH")" "$NFX2"
[ "$RECORD_RC" = "3" ] && ok "12e mutation(d): with the legacy arm REMOVED the raw marker is refused (rc 3) — 12d is load-bearing" || bad "12e mutation(d): the raw marker still carried (rc=$RECORD_RC) — 12d is NOT testing backward compat"

# M_NOLIB — the normalizer is ABSENT (a partial install). The producer must fail
# OPEN to the raw digest with a loud warning and NEVER mint a digest no consumer
# can verify. REGRESSION-SENSITIVE: letting DIFF_HASH go empty here would write a
# sha-only record and redden the first half; the warning reddens the second.
mkdir -p "$T/mut-nolib"
cp "$RECORD" "$T/mut-nolib/record-review.sh"   # intentionally NO lib/
NPR_m=424714; rm -f "$(Q2 $NPR_m)"
run_record_diff_with "$T/mut-nolib/record-review.sh" "$NPR_m" "$SHA" "body" "$NFX2"
[ "$RECORD_RC" = "0" ] && ok "12e fail-open: a missing normalizer still records (rc 0)" || bad "12e fail-open: missing normalizer blocked the record (rc=$RECORD_RC)"
assert_contains "$RECORD_ERR" "diff normalizer is unavailable" "12e fail-open: the missing normalizer is warned about loudly"
assert_contains "$RECORD_CAP" "diff=$RH" "12e fail-open: the marker carries the RAW digest (a verifiable legacy hash)"
if grep -qF "diff=$NH" <<<"$RECORD_CAP"; then bad "12e fail-open: the marker must NOT carry a normalized digest when the normalizer is missing"; else ok "12e fail-open: no normalized digest is minted without the normalizer"; fi

# M_EMPTYLIB — the normalizer EXISTS but is EMPTY. `python3 empty.py` exits 0 and prints
# NOTHING, so without an output guard DIFF_HASH becomes sha256("") — a CONSTANT
# that collides for EVERY diff and lets the carry-forward arm mint head-bound
# evidence for an unreviewed revision. The producer must treat empty output
# exactly like an absent normalizer (raw fallback), never mint the constant.
# The cause is a truncation between write and read; setup.sh installs the lib
# atomically since #1362 review, but the guard must not depend on the install
# path being atomic.
mkdir -p "$T/mut-emptylib/lib"
cp "$RECORD" "$T/mut-emptylib/record-review.sh"
: > "$T/mut-emptylib/lib/diff-normalize.py"
NPR_m=424715; rm -f "$(Q2 $NPR_m)"
run_record_diff_with "$T/mut-emptylib/record-review.sh" "$NPR_m" "$SHA" "body" "$NFX2"
[ "$RECORD_RC" = "0" ] && ok "12e fail-open: an EMPTY normalizer still records (rc 0)" || bad "12e fail-open: empty normalizer blocked the record (rc=$RECORD_RC)"
assert_contains "$RECORD_ERR" "produced no output" "12e fail-open: the empty normalizer is warned about loudly"
assert_contains "$RECORD_CAP" "diff=$RH" "12e fail-open: the empty-normalizer marker carries the RAW digest"
if grep -qF 'diff=e3b0c442' <<<"$RECORD_CAP"; then bad '12e fail-open: the marker carries sha256("") — a CONSTANT digest that collides for every diff'; else ok '12e fail-open: no sha256("") constant is minted from an empty normalizer'; fi

# ── 12f THE BINARY FAIL-OPEN (2026-09-23 amendment) ──────────────────────
# A binary entry has NO hunk, so its `index` line is its ONLY content-bearing
# field (`Binary files … differ` is content-independent). Before the amendment
# the normalizer dropped it unconditionally, so a signed marker over binary v1
# carried to binary v2 at the same path: review v1, sign the marker, swap in v2,
# digest unchanged → the gate accepts an UNREVIEWED binary. The amendment scopes
# the drop to entries that HAVE a hunk; the predicate is hunk PRESENCE, never a
# binary marker (an empty-file add/delete keeps its index line too).
NBFA="$T/nb-a.diff"; printf 'diff --git a/f.bin b/f.bin\nindex 1111111..2222222 100644\nBinary files a/f.bin and b/f.bin differ\n' > "$NBFA"
NBFB="$T/nb-b.diff"; printf 'diff --git a/f.bin b/f.bin\nindex 1111111..3333333 100644\nBinary files a/f.bin and b/f.bin differ\n' > "$NBFB"
NBH="$(norm_sha "$NBFA")"
assert_ne "$NBH" "$(norm_sha "$NBFB")" "12f direct: two DIFFERENT binaries have DIFFERENT normalized digests (fail-open closed)"
assert_ne "$(raw_sha "$NBFA")" "$(raw_sha "$NBFB")" "12f control: the raw digests also differ (the fixtures are not degenerate)"
NPR_f=424704; rm -f "$(Q2 $NPR_f)"
run_record_diff "$NPR_f" "$STALE" "body

$(signed_marker $NPR_f "$STALE" "$NBH")" "$NBFB"
[ "$RECORD_RC" = "3" ] && ok "12f a signed marker over binary v1 does NOT carry to a swapped binary v2 (rc 3)" || bad "12f carried an unreviewed binary (rc=$RECORD_RC, err=$RECORD_ERR)"
[ ! -f "$(Q2 $NPR_f)" ] && ok "12f no record written for the swapped binary" || bad "12f wrote a record for a swapped binary"

# MUTATION PIN — the (a) evidence. Rebuild the pre-amendment primitive
# (unconditional index drop) and show the SAME end-to-end vector FALSELY CARRIES
# under it (rc 0). That is precisely the hole the entry-scoping closes, and it is
# why §12f's refusal above is load-bearing rather than an artifact.
mut_dir "$T/mut-unscoped"
cat > "$T/mut-unscoped/lib/diff-normalize.py" <<'PY'
import re, sys
out = []
for line in sys.stdin.buffer.read().decode("latin-1").split("\n"):
    if re.match(r"^index [0-9a-f]+\.\.[0-9a-f]+( [0-7]{6})?$", line):
        continue   # MUTATION: unconditional drop (the pre-amendment rule)
    m = re.match(r"^@@ -([0-9]+)(,([0-9]+))? \+([0-9]+)(,([0-9]+))? @@(.*)$", line)
    if m:
        line = "@@ -0,%s +0,%s @@%s" % (m.group(3) or "1", m.group(6) or "1", m.group(7))
    out.append(line)
sys.stdout.buffer.write("\n".join(out).encode("latin-1"))
PY
MUS_H="$(norm_sha_with "$T/mut-unscoped/lib/diff-normalize.py" "$NBFA")"
assert_eq "$MUS_H" "$(norm_sha_with "$T/mut-unscoped/lib/diff-normalize.py" "$NBFB")" \
  "12f mutation control: under the pre-amendment primitive the two binaries COLLAPSE to one digest"
if cmp -s <(python3 "$NORM_PY" < "$NBFA") <(python3 "$T/mut-unscoped/lib/diff-normalize.py" < "$NBFA"); then
  bad "12f mutation control: the mutant normalizer is not actually a mutation on the binary fixture"
else
  ok "12f mutation control: the mutant differs from the shipped normalizer on the binary fixture (it is a genuine mutation)"
fi
NPR_m=424715; rm -f "$(Q2 $NPR_m)"
run_record_diff_with "$T/mut-unscoped/record-review.sh" "$NPR_m" "$STALE" "body

$(signed_marker $NPR_m "$STALE" "$MUS_H")" "$NBFB"
[ "$RECORD_RC" = "0" ] && ok "12f MUTATION PIN: with entry-scoping REMOVED the swapped binary WOULD carry (rc 0) — §12f is load-bearing" || bad "12f mutation: expected a false carry (rc=$RECORD_RC) — §12f is NOT testing entry-scoping"

unset NFX NFX2 NFXC NFXW NORM_PY NH RH MNC_H MWS_H NPR_a NPR_b NPR_c NPR_d NPR_f NPR_m NBFA NBFB NBH MUS_H
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
# §10 needs a DIFFERENT key (the clean-low tier signs its own markers), but the
# suite key is suite-GLOBAL state — save it so the teardown RESTORES it instead
# of leaving it unset for every later section. §13's signed-carry vectors need
# it, and an empty key makes record-review.sh skip the marker HMAC check
# SILENTLY: the symptom downstream is a carry that refuses with no diagnostic at
# all, which is exactly how this leak was finally found (by tracing GATE_KEY
# while PRIOR_LINE was populated).
_SUITE_GATE_KEY="$AI_REVIEW_GATE_KEY"
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
export AI_REVIEW_GATE_KEY="$_SUITE_GATE_KEY"
unset _SUITE_GATE_KEY

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
    local ev=""
    [ "$2" = "clean" ] && ev="$EV_ARGS"
    : > "$T/merr"
    (
        export HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG"
        export STUB_EVIDENCE_PR="$4" STUB_EVIDENCE_REPO="daniel-ospina/agent-infra"
        rc=0
        bash "$script" "$4" "$SHA" "$2" "$3" $ev >/dev/null 2>"$T/merr" || rc=$?
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

# ── 13. tortoise#7391 — a FRESH `clean` record requires VERIFIED evidence ────────
# THE DEFECT: passing the PR's CURRENT head was, on its own, sufficient to mint
# a validly-signed, head-bound `verdict=clean`. There was no current-head
# branch at all — the head/stale block simply fell through the equality case,
# so the most natural invocation there is ("record this PR at its current
# head") asked no question. tortoise#3549 merged on exactly such a record while
# every review comment on it said NOT CLEAN.
#
# This runner drives the evidence environment EXPLICITLY. A prefix assignment on
# a shell FUNCTION is a shell variable, not an exported one, so a `STUB_*=v`
# prefix would NOT reach the stubbed gh; the knobs are exported here by name.
run_record_ev() { # <pr> [VAR=VAL…]; ref via $EV_REF (empty ⇒ omit --evidence)
    local pr="$1"; shift
    local rcfile="$T/evrc" errfile="$T/everr" kv
    rm -f "$errfile"
    : > "$LOG"   # 13a asserts on the ABSENCE of a fetch — must not see a prior vector's calls
    (
        export HOME="$F_HOME"
        export PATH="$T/bin:$PATH"
        export GH_STUB_LOG="$LOG"
        export STUB_EVIDENCE_PR="$pr" STUB_EVIDENCE_REPO="daniel-ospina/agent-infra"
        for kv in "$@"; do export "$kv"; done
        rc=0
        if [ -n "${EV_REF:-}" ]; then
            bash "$RECORD" "$pr" "$SHA" clean "daniel-ospina/agent-infra" --evidence "$EV_REF" 2>"$errfile" || rc=$?
        else
            bash "$RECORD" "$pr" "$SHA" clean "daniel-ospina/agent-infra" 2>"$errfile" || rc=$?
        fi
        printf '%s' "$rc" > "$rcfile"
    ) 2>/dev/null
    RECORD_RC="$(cat "$rcfile" 2>/dev/null || echo 99)"
    RECORD_ERR="$(cat "$errfile" 2>/dev/null || true)"
}

echo "── 13. tortoise#7391: fresh clean requires VERIFIED review evidence ─────"

# 13a — the mandated NEGATIVE half: no --evidence at the current head →
# REFUSED with a non-zero exit and a NAMED reason, and no record minted.
rm -f "$(Q2 424720)"
EV_REF="" run_record_ev 424720
assert_eq "$RECORD_RC" "3" "13a no --evidence at the current head refuses (rc 3)"
[ ! -f "$(Q2 424720)" ] && ok "13a mints NO record" || bad "13a minted a record with no evidence"
assert_contains "$RECORD_ERR" "tortoise#7391" "13a the refusal names the issue"
assert_contains "$RECORD_ERR" "--evidence" "13a the refusal names the remedy"
if grep -q "repos/daniel-ospina/agent-infra/issues/comments" "$LOG"; then
    bad "13a no artifact was even named (a fetch happened anyway)"
else
    ok "13a refuses BEFORE any artifact fetch"
fi

# 13b — the mandated POSITIVE half: the same invocation WITH a named, verified
# artifact still records exactly as before. Together with 13a this isolates the
# refusal to the MISSING evidence rather than to something else the gate broke.
rm -f "$(Q2 424721)"
EV_REF="comment:42472101" run_record_ev 424721
assert_eq "$RECORD_RC" "0" "13b current head WITH evidence still records (rc 0)"
R13="$(cat "$(Q2 424721)" 2>/dev/null || true)"
assert_contains "$R13" '"verdict":"clean"' "13b verdict is clean"
assert_contains "$R13" '"evidence":"comment:42472101"' "13b the record names the artifact it was verified against"
assert_contains "$R13" '"mint":"fresh"' "13b a fresh record is marked mint=fresh (provenance)"
if grep -q '"carried_from"' <<<"$R13"; then bad "13b a fresh record claims carried_from"; else ok "13b a fresh record carries no carry fields"; fi

# 13c — the marker SHAPE is pinned by OTHER scripts (atomic-land.sh and
# check-pipeline-compliance.sh both regex it). tortoise#7391 must not widen it.
run_record_diff 424722 "$SHA" "plain body" "$D_F" 0
assert_contains "$RECORD_CAP" "review recorded: reviews/424722.json verdict=clean @" "13c the marker keeps its documented shape"
if grep -qF "evidence" <<<"$RECORD_CAP"; then bad "13c evidence leaked into the marker (cross-script shape)"; else ok "13c the marker carries no evidence field"; fi

# 13d — FAIL CLOSED on everything unverifiable. A gate that degraded to a pass
# when it could not read the artifact would be this SAME defect one layer up.
EV_REF="comment:42472301" run_record_ev 424723 STUB_EVIDENCE_FAIL=1
assert_eq "$RECORD_RC" "3" "13d an UNREADABLE artifact refuses (a failed read is not evidence)"
[ ! -f "$(Q2 424723)" ] && ok "13d writes no record on an unreadable artifact" || bad "13d wrote a record on an unreadable artifact"
EV_REF="https://example.invalid/not-an-artifact" run_record_ev 424724
assert_eq "$RECORD_RC" "3" "13d an unparseable reference refuses (rc 3)"
EV_REF="comment:notanumber" run_record_ev 424725
assert_eq "$RECORD_RC" "3" "13d a non-numeric id refuses (rc 3)"
EV_REF="comment:42472601" run_record_ev 424726 STUB_EVIDENCE_PARENT="https://api.github.com/repos/daniel-ospina/agent-infra/issues/999999"
assert_eq "$RECORD_RC" "3" "13d an artifact belonging to ANOTHER PR refuses (rc 3)"
run_record_ev 424727 STUB_COMMIT_FAIL=1
assert_eq "$RECORD_RC" "3" "13d an unreadable head commit date refuses (rc 3)"

# 13e — the artifact must POSTDATE the recorded revision: otherwise a lane can
# name a clean artifact from an EARLIER head and mint a verdict on an
# unreviewed one, which is the whole failure mode in a different disguise.
EV_REF="comment:42472801" run_record_ev 424728 STUB_EVIDENCE_AT="2020-01-01T00:00:00Z"
assert_eq "$RECORD_RC" "3" "13e evidence PREDATING the head refuses (rc 3)"

# 13f — tortoise#3549's ACTUAL shape: the artifact exists and is on this PR, but
# it says the review did NOT conclude clean. Mere existence must not suffice.
EV_REF="comment:42472901" run_record_ev 424729 STUB_EVIDENCE_BODY="## Review — NOT CLEAN
2 P1s remain: unbounded retry, missing auth check."
assert_eq "$RECORD_RC" "3" "13f an artifact asserting NOT CLEAN refuses (rc 3)"

# 13g — a record MARKER must not be usable as its own evidence: it attests that
# a verdict was recorded, which is precisely the claim under test.
EV_REF="comment:42473001" run_record_ev 424730 STUB_EVIDENCE_BODY="review recorded: reviews/424730.json verdict=clean @ $SHA"
assert_eq "$RECORD_RC" "3" "13g a record MARKER is not accepted as evidence (rc 3)"

# 13g2 — the ref is interpolated INTO the record's JSON, which the merge gate
# parses. A ref carrying a quote, a backslash or a control character must not be
# able to break that framing (refused rather than escaped).
EV_REF='comment:12"' run_record_ev 424731
assert_eq "$RECORD_RC" "3" "13g2 a ref carrying a QUOTE is refused (JSON framing unbreakable)"
[ ! -f "$(Q2 424731)" ] && ok "13g2 no record written for a quote-carrying ref" || bad "13g2 wrote a record for a quote-carrying ref"
EV_REF='comment:12\1' run_record_ev 424732
assert_eq "$RECORD_RC" "3" "13g2 a ref carrying a BACKSLASH is refused"
# The arm must fire on a SINGLE backslash — the form above is also refused by the
# numeric-id check, so it alone cannot pin the arm (it was a false pin until
# reviewer B, cycle 2). This URL-shaped ref reaches the arm with a valid numeric
# id, so ONLY the backslash refusal can reject it.
rm -f "$(Q2 424734)"
EV_REF='https://github.com/daniel-ospina/agent-infra/pull/424734\#issuecomment-5' run_record_ev 424734
assert_eq "$RECORD_RC" "3" "13g2 a SINGLE backslash in a URL-shaped ref is refused (the arm fires, not the id check)"
[ ! -f "$(Q2 424734)" ] && ok "13g2 no record written for a single-backslash ref" || bad "13g2 wrote a record for a single-backslash ref"
EV_REF='review-comment:abc' run_record_ev 424733
assert_eq "$RECORD_RC" "3" "13g2 a non-numeric id on a valid kind is refused"

# 13h — PROVENANCE. A carried record must be distinguishable from a fresh one,
# and the carry must NOT overwrite the original mint time: pre-tortoise#7391 a carried
# record's reviewed_at was the CARRY (≈ merge) time, so the time the review
# actually happened was unrecoverable afterwards — the #3549 record's own shape.
# §12 unsets its fixtures, so this section builds its own — using a diff whose
# shape §12 already proved survives the SHIPPED normalizer, and computing its
# digest with the same helper §12 used.
PRV=424740
EV13_D="$T/ev13.diff"
printf 'diff --git a/f b/f\nindex 1111111..2222222 100644\n--- a/f\n+++ b/f\n@@ -1,3 +1,4 @@\n ctx\n+added\n ctx2\n' > "$EV13_D"
EV13_H="$(norm_sha_with "$SCRIPT_DIR/lib/diff-normalize.py" "$EV13_D")"
assert_ne "" "$EV13_H" "13h the §13 diff fixture normalizes to a digest"
# Cross-check the FIXTURE's contract before leaning on it: a fresh `clean` at
# the current head must bind this exact digest in the marker. If that ever
# diverges, the carry vectors below would refuse for a reason of the fixture's
# own making rather than for the carry logic — which is what a digest mismatch
# looked like when this section was first written.
run_record_diff 424739 "$SHA" "plain body" "$EV13_D" 0
assert_contains "$RECORD_CAP" "diff=$EV13_H" "13h the script binds the SAME digest this section computed (fixture contract)"
rm -f "$(Q2 $PRV)"
# 1) mint a record AT $STALE (--force-stale: a stale sha with no diff binding).
run_record_diff $PRV "$STALE" "body" "$EV13_D" 0 --force-stale
assert_eq "$RECORD_RC" "0" "13h a fresh record can be minted at a stale sha via --force-stale (rc 0)"
T1="$(sed -n 's/.*"reviewed_at":"\([^"]*\)".*/\1/p' "$(Q2 $PRV)" | head -1)"
assert_contains "$(cat "$(Q2 $PRV)")" '"mint":"fresh"' "13h the first record is marked mint=fresh"
assert_ne "" "$T1" "13h the fresh record has a reviewed_at to preserve"
# 2) re-record the SAME reviewed artifact onto the moved head → a CARRY. It
#    needs no --evidence (its evidence is the signed prior marker it verified).
EV13_BODY="body

$(signed_marker $PRV "$STALE" "$EV13_H")"
EV13_PAT="^review recorded: reviews/$PRV\.json verdict=clean @ [0-9a-f]{40} diff=$EV13_H \(.*\) sig=[0-9a-f]{64}$"
# The carry below verifies a SIGNED prior marker, so the suite gate key must be
# armed. §10 (clean-low) retargets it, and an EMPTY key makes record-review.sh
# skip the HMAC block SILENTLY — the carry then refuses with no diagnostic at
# all. Pin the key here rather than rediscovering that asymmetry.
assert_ne "" "${AI_REVIEW_GATE_KEY:-}" "13h the suite gate key is armed for the carry vectors"
assert_eq "${AI_REVIEW_GATE_KEY:-}" "$TEST_GATE_KEY" "13h the armed key is the suite key (not a section's leftover)"
# Pin the PLANTED marker against the script's own prior-line pattern. If this
# fails, a carry refusal below is the fixture's fault, not the carry's — which
# is what a silent no-match looked like when this section was first written.
if grep -qE "$EV13_PAT" <<<"$EV13_BODY"; then
  ok "13h the planted marker matches the script's own prior-line pattern (harness side)"
else
  bad "13h the planted marker does NOT match the script's prior-line pattern (harness-side fault)"
fi
run_record_diff $PRV "$STALE" "$EV13_BODY" "$EV13_D"
# DIAGNOSTIC (temporary): the carry reads the PR body to find the prior marker.
# If that read never happens the grep below cannot match, and the carry refuses
# WITHOUT a warning — the exact symptom this section first hit.
if grep -qF "pulls/$PRV --jq .body" "$LOG"; then
    ok "13h the carry read the PR body via gh"
else
    bad "13h the carry NEVER read the PR body (gh log has no .body fetch for $PRV)"
fi
assert_eq "$RECORD_RC" "0" "13h the carry onto the current head records (rc 0) [err: $(printf '%s' "$RECORD_ERR" | tr '\n' ' ')]"
R13H="$(cat "$(Q2 $PRV)" 2>/dev/null || true)"
assert_contains "$R13H" '"mint":"carried"' "13h a carried record is distinguished from a fresh one"
assert_contains "$R13H" "\"carried_from\":\"$STALE\"" "13h carried_from names the head the verdict was actually reviewed at"
assert_contains "$R13H" '"carried_at"' "13h carried_at records when the carry happened"
assert_contains "$R13H" "\"reviewed_at\":\"$T1\"" "13h reviewed_at is PRESERVED as the original mint time (not the carry time)"
assert_contains "$R13H" "\"head_sha\":\"$SHA\"" "13h the carried record binds the CURRENT head"
# NB: no backticks in these strings — they would run as COMMAND SUBSTITUTION
# (the same defect this file warns about at §11.5e, and one it caught here).
if grep -q '"evidence"' <<<"$R13H"; then bad "13h the carry claims an unverified evidence field"; else ok "13h the carry claims no evidence field (it was not verified)"; fi

# 13i — an unreadable ORIGINAL mint time must be LOUD, never silently the carry
# time (the pre-tortoise#7391 behaviour that made the mint time unrecoverable).
PRV2=424741
rm -f "$(Q2 $PRV2)"
run_record_diff $PRV2 "$STALE" "body

$(signed_marker $PRV2 "$STALE" "$EV13_H")" "$EV13_D"
assert_eq "$RECORD_RC" "0" "13i a carry with NO prior record still records (rc 0) [err: $(printf '%s' "$RECORD_ERR" | tail -2 | tr '\n' ' ')]"
assert_contains "$RECORD_ERR" "not recoverable" "13i the unrecoverable mint time is announced on stderr"
assert_contains "$(cat "$(Q2 $PRV2)")" '"mint":"carried"' "13i the record is still marked carried"

# 13j/13k — the arms that are NOT carries must not become evidence-free side
# doors. The gate is skipped only when CARRY_ARM set (a verified carry, whose
# evidence is the prior signed marker it re-verified). --force-stale and the
# #784 fail-open arm are NOT carries: they mint a fresh `clean` attestation, so
# they must demand evidence like any other.
rm -f "$(Q2 424742)"
(
    export HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG"
    export STUB_EVIDENCE_PR=424742 STUB_EVIDENCE_REPO="daniel-ospina/agent-infra"
    rc=0
    bash "$RECORD" 424742 "$STALE" clean "daniel-ospina/agent-infra" --force-stale 2>"$T/err-13j" || rc=$?
    printf '%s' "$rc" > "$T/rc-13j"
) 2>/dev/null
RECORD_RC="$(cat "$T/rc-13j" 2>/dev/null || echo 99)"
RECORD_ERR="$(cat "$T/err-13j" 2>/dev/null || true)"
assert_eq "$RECORD_RC" "3" "13j --force-stale with NO evidence is refused (the override is not a side door)"
[ ! -f "$(Q2 424742)" ] && ok "13j --force-stale mints no evidence-free record" || bad "13j --force-stale minted an evidence-free record"
assert_contains "$RECORD_ERR" "tortoise#7391" "13j the refusal names the issue"

rm -f "$(Q2 424743)"
(
    export HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG"
    export STUB_HEAD_SHA="API rate limit exceeded"
    export STUB_EVIDENCE_PR=424743 STUB_EVIDENCE_REPO="daniel-ospina/agent-infra"
    rc=0
    bash "$RECORD" 424743 "$SHA" clean "daniel-ospina/agent-infra" 2>"$T/err-13k" || rc=$?
    printf '%s' "$rc" > "$T/rc-13k"
) 2>/dev/null
RECORD_RC="$(cat "$T/rc-13k" 2>/dev/null || echo 99)"
RECORD_ERR="$(cat "$T/err-13k" 2>/dev/null || true)"
assert_eq "$RECORD_RC" "3" "13k the #784 fail-open arm with NO evidence is refused (an API failure is not an exemption)"
[ ! -f "$(Q2 424743)" ] && ok "13k no record minted while the head was unverifiable" || bad "13k minted a record from an unverifiable head"

# 13l — DECLARED OUT OF SCOPE, PINNED. The gate proves an artifact EXISTS on
# this PR, postdates the head, and does not assert NOT-CLEAN. It does NOT prove
# the artifact is a REVIEW: a bot or CI comment that describes no review
# satisfies it. Reviewer identity is the missing ingredient, and this fleet
# cannot supply it (every session authenticates as one GitHub account), so the
# class is DECLARED out of scope rather than half-closed — and pinned here so a
# later narrowing has to be deliberate instead of the residual silently
# changing shape. What the gate does close is the SILENT path (naming the
# current head with no argument at all — 13a): naming a non-review artifact is
# a deliberate act, which is the bar.
rm -f "$(Q2 424744)"
EV_REF="comment:42474401" run_record_ev 424744 STUB_EVIDENCE_BODY="🤖 Mergify: your pull request has been merged automatically."
assert_eq "$RECORD_RC" "0" "13l (DECLARED OUT OF SCOPE) a non-review artifact is ACCEPTED — the gate checks artifact, not review"
R13L="$(cat "$(Q2 424744)" 2>/dev/null || true)"
assert_contains "$R13L" '"evidence":"comment:42474401"' "13l the record names the non-review artifact it accepted"
assert_contains "$R13L" '"mint":"fresh"' "13l the looser path is still a fresh mint (provenance unaffected)"


# 13m — the review skills' OWN unresolved-exit templates. Found by the #7391
# scoping verifier (cycle 2): 13f pins a comment that literally says "NOT CLEAN",
# but the `code-review` skill's Step 8 header for a review that ends with
# UN-FIXED issues contains no `not…clean` substring at all — so the literal veto
# ACCEPTED a comment documenting an un-fixed P0/P1 and minted `clean` from it.
# The veto now names the unresolved-exit vocabulary the skills emit; these four
# vectors are those templates as the skills write them, plus the over-block guard.
# (Cycle 3 found the fixture itself read only the body's FIRST line — the stub now
# @tsv-escapes, so these bodies are exercised in full.)
EV_REF="comment:42474501" run_record_ev 424745 STUB_EVIDENCE_BODY="⚠️ Auto-fix stalled after 3 cycles — 2 issues require human attention

### Code review

Found 2 issues:

1. unbounded retry on the shard splitter (bugs)
2. missing repo guard (guidance)"
assert_eq "$RECORD_RC" "3" "13m the skill's stalled-exit template is not evidence of a CLEAN review (rc 3)"
[ ! -f "$(Q2 424745)" ] && ok "13m mints no record from an unresolved review artifact" || bad "13m minted a record from an unresolved artifact"

# 13m2 — the OVER-BLOCK guard for 13m: the skill's CLEAN template lists issues
# that were FIXED and carries none of the unresolved-exit markers. Vetoing
# "Found N issues" would false-refuse a legitimate clean record and deadlock the
# lane, which is why the veto names unresolved STATES only.
rm -f "$(Q2 424746)"
EV_REF="comment:42474601" run_record_ev 424746 STUB_EVIDENCE_BODY="### Code review

Found 3 issues:

1. off-by-one in the shard splitter (bugs)
2. missing repo guard (guidance)
3. stale comment (quality)

All three fixed in 9f1a2b3."
assert_eq "$RECORD_RC" "0" "13m2 the clean template (issues FOUND then FIXED) still records (rc 0)"
R13M2="$(cat "$(Q2 424746)" 2>/dev/null || true)"
assert_contains "$R13M2" '"evidence":"comment:42474601"' "13m2 the clean review artifact is what the record names"

# 13m3 — a SECOND unresolved-exit vocabulary the widened veto must cover: the
# plan-review skill's block marker is "Requires Human Input", which the earlier
# "require … human attention" pattern did NOT match (found in cycle 3 by reading
# the skill's own text).
rm -f "$(Q2 424747)"
EV_REF="comment:42474701" run_record_ev 424747 STUB_EVIDENCE_BODY="### Plan review

⚠️ Requires Human Input — the plan did not converge; see the issue thread."
assert_eq "$RECORD_RC" "3" "13m3 'Requires Human Input' is refused (rc 3)"

# 13m4 — the SECOND over-block guard: a CLEAN review may legitimately say
# "No issues remain after the fixes". The remain pattern therefore requires a
# leading COUNT, so this records rather than deadlocking the lane.
rm -f "$(Q2 424748)"
EV_REF="comment:42474801" run_record_ev 424748 STUB_EVIDENCE_BODY="### Code review

No issues remain after the fixes in 9f1a2b3."
assert_eq "$RECORD_RC" "0" "13m4 a clean review saying 'No issues remain' still records (rc 0)"

# 13m5 — the OTHER FOUR unresolved prefixes from the file that OWNS the
# vocabulary: skills/code-review/references/fixer-loop.md §"PR comment prefix".
# The earlier veto hard-coded a PARAPHRASE of the skill's marker ("requires human
# attention") where the skill emits "requires human review", so zero-progress,
# convergence, honest-stuck and aborted were all admitted — a lane whose review
# ABORTED could name its own Step-8 comment and mint clean (reviewer B, cycle 1).
# Each body below is the skill's prefix VERBATIM. If a new prefix is added to
# fixer-loop.md and not here, this vector set is what tells you the pattern drifted.
_m5=0
for _m5_prefix in \
    'made no changes for 2 consecutive cycles (zero-progress) — requires human review' \
    'converged with issues unresolved — requires human review' \
    'stuck (honest-stuck — issue count not shrinking for 3 cycles) — requires human review' \
    'aborted (push-failed) — issues require human review' \
    'reached the 10-cycle safety cap — unresolved issues remain; escalate to a human'; do
    _m5=$((_m5 + 1)); _m5_pr=$((424750 + _m5))
    rm -f "$(Q2 $_m5_pr)"
    EV_REF="comment:${_m5_pr}01" run_record_ev "$_m5_pr" \
        STUB_EVIDENCE_BODY="⚠️ Auto-fix ${_m5_prefix}

### Code review

Found 2 issues:

1. …"
    assert_eq "$RECORD_RC" "3" "13m5 fixer-loop prefix refuses: '${_m5_prefix%% *} …'"
done

# 13m5b — the CAP markers match the veto via their own alternatives (not via
# `issues? remain` alone), so each must be pinned by a vector or a later edit can
# drop its alternative with no red test — the false-pin failure 13g2's backslash
# arm just suffered. Both forms of the test-review marker are pinned: the literal
# un-substituted `N` template (skills/test-review/SKILL.md:433) and the
# digit-substituted one.
rm -f "$(Q2 424766)"
EV_REF="comment:42476601" run_record_ev 424766 \
    STUB_EVIDENCE_BODY="⚠️ Test review capped at 10 cycles — N issues remain:

1. <issue>"
assert_eq "$RECORD_RC" "3" "13m5b the test-review cap marker with a literal N is refused (rc 3)"
rm -f "$(Q2 424767)"
EV_REF="comment:42476701" run_record_ev 424767 \
    STUB_EVIDENCE_BODY="⚠️ Test review capped at 10 cycles — 2 issues remain:

1. <issue>"
assert_eq "$RECORD_RC" "3" "13m5b the test-review cap marker with a digit is refused (rc 3)"

# 13m6 — the adversarial-domain BOUNDED exit is not a clean exit either: a run
# that reports residuals has not concluded clean, so its marker must refuse.
rm -f "$(Q2 424756)"
EV_REF="comment:42475601" run_record_ev 424756 \
    STUB_EVIDENCE_BODY="[ADVERSARIAL-BOUND] cycles=2 threats=17 covered=15 residuals=#12,#14 — bounded by the declared threat surface (#838); residuals filed, not chased"
assert_eq "$RECORD_RC" "3" "13m6 an [ADVERSARIAL-BOUND] (residuals filed) artifact is refused (rc 3)"

# 13g3 — the marker veto must be anchored to a LINE START, not to position 0. The
# body arrives @tsv-escaped, so a marker introduced by ANY preceding line used to
# slip through `^` — the exact laundering 13g forbids, with a preamble in front.
rm -f "$(Q2 424757)"
EV_REF="comment:42475701" run_record_ev 424757 \
    STUB_EVIDENCE_BODY="Evidence for PR 424757:
review recorded: reviews/424757.json verdict=clean @ $SHA"
assert_eq "$RECORD_RC" "3" "13g3 a marker introduced by a preceding line is refused (rc 3)"
[ ! -f "$(Q2 424757)" ] && ok "13g3 no record written for a prefixed marker" || bad "13g3 wrote a record for a prefixed marker"

# 13g4 — the WHOLE C0 range must be refused, not just \n and \t. A raw CR used to
# pass the enumerated case and then land in the record as "evidence":"…\r…",
# which both jq and Python json reject as an invalid control character — a record
# that no consumer can read (reviewer B, cycle 1).
rm -f "$(Q2 424758)"
EV_REF=$'https://github.com/daniel-ospina/agent-infra/pull/424758\r#issuecomment-5' run_record_ev 424758
assert_eq "$RECORD_RC" "3" "13g4 a ref carrying a RAW control character is refused (rc 3)"
[ ! -f "$(Q2 424758)" ] && ok "13g4 no record written for a control-carrying ref" || bad "13g4 wrote a record for a control-carrying ref"

# 13q — a PR REVIEW carries GitHub's own verdict in `state`, which no body-text
# widen can reach: a CHANGES_REQUESTED review with an empty body has no veto
# phrase to match yet is plainly not evidence of a clean review (reviewer B, P2).
# REFUTED CONTROL in the same vector: the identical body under COMMENTED records,
# so this pins the STATE arm rather than "review refs are broken".
rm -f "$(Q2 424759)"
EV_REF="review:42475901" run_record_ev 424759 STUB_EVIDENCE_BODY="Reviewed the diff." STUB_REVIEW_STATE="CHANGES_REQUESTED"
assert_eq "$RECORD_RC" "3" "13q a CHANGES_REQUESTED review is refused (rc 3)"
[ ! -f "$(Q2 424759)" ] && ok "13q no record written for a CHANGES_REQUESTED review" || bad "13q wrote a record for a CHANGES_REQUESTED review"
rm -f "$(Q2 424760)"
EV_REF="review:42476001" run_record_ev 424760 STUB_EVIDENCE_BODY="Reviewed the diff." STUB_REVIEW_STATE="COMMENTED"
assert_eq "$RECORD_RC" "0" "13q control: the same body under COMMENTED still records (rc 0)"

# 13q2 — the EMPTY-BODY parse is its own adversarial case, and it defeated the
# 13q fix on its first attempt: `IFS=$'\t' read` collapses an empty field, so
# `TS\tPARENT\t\tCHANGES_REQUESTED` parsed as body="CHANGES_REQUESTED", state=""
# and the state guard was skipped — a changes-requested review with inline
# comments and no prose was ACCEPTED (reviewer B, cycle 2). The body is now
# split with `%%`/`#`, which preserves empty fields. The empty body is
# expressible here only because the fixture uses `${VAR-default}`, not `:-`.
_q2=0
for _q2_state in CHANGES_REQUESTED DISMISSED PENDING; do
    _q2=$((_q2 + 1)); _q2_pr=$((424760 + _q2))
    rm -f "$(Q2 $_q2_pr)"
    EV_REF="review:${_q2_pr}01" run_record_ev "$_q2_pr" STUB_EVIDENCE_BODY="" STUB_REVIEW_STATE="$_q2_state"
    assert_eq "$RECORD_RC" "3" "13q2 an EMPTY-BODY $_q2_state review is refused (rc 3)"
    [ ! -f "$(Q2 $_q2_pr)" ] && ok "13q2 no record written for an empty-body $_q2_state review" || bad "13q2 wrote a record for an empty-body $_q2_state review"
done
rm -f "$(Q2 424764)"
EV_REF="review:42476401" run_record_ev 424764 STUB_EVIDENCE_BODY="" STUB_REVIEW_STATE="APPROVED"
assert_eq "$RECORD_RC" "0" "13q2 control: an empty-body APPROVED review still records (rc 0)"
rm -f "$(Q2 424765)"
EV_REF="review:42476501" run_record_ev 424765 STUB_EVIDENCE_BODY="" STUB_REVIEW_STATE="COMMENTED"
assert_eq "$RECORD_RC" "0" "13q2 control: an empty-body COMMENTED review still records (rc 0)"

# 13n — T15: the evidence value must NOT be smuggled in through the ENVIRONMENT.
# The gate reads it from argv only; a caller that exports EVIDENCE and passes no
# flag must be refused, or "you must name the artifact" would be satisfiable
# without naming anything at the command line. (The script's plain `EVIDENCE=""`
# assignment shadows any inherited value — this pins that, so a refactor to
# `${EVIDENCE:-}` cannot silently reopen the class.)
rm -f "$(Q2 424749)"
(
    export HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG"
    export STUB_EVIDENCE_PR=424749 STUB_EVIDENCE_REPO="daniel-ospina/agent-infra"
    export EVIDENCE="comment:42474901"   # the smuggled value
    rc=0
    bash "$RECORD" 424749 "$SHA" clean "daniel-ospina/agent-infra" 2>"$T/err-13n" || rc=$?
    printf '%s' "$rc" > "$T/rc-13n"
) 2>/dev/null
RECORD_RC="$(cat "$T/rc-13n" 2>/dev/null || echo 99)"
RECORD_ERR="$(cat "$T/err-13n" 2>/dev/null || true)"
assert_eq "$RECORD_RC" "3" "13n an ENV-smuggled EVIDENCE is not accepted (rc 3)"
[ ! -f "$(Q2 424749)" ] && ok "13n mints no record from an environment value" || bad "13n minted a record from an environment value"
assert_contains "$RECORD_ERR" "--evidence" "13n the refusal still names the flag"

# 13o/13o2 — T17, the FALSE PASS this harness itself can produce. A harness that
# aborts mid-run and still exits 0 is counted as a PASSING SHARD by
# scripts/run-bash-shards.sh (exit-code-only). Re-raising `$?` does NOT fix it on
# bash 3.2 (an unbound-variable abort reads 0 at EXIT-trap time) — measured. These
# two vectors execute the harness's OWN cleanup block, extracted from this file
# rather than copied, so the pin cannot drift from the implementation: 13o induces
# the abort and requires a NON-ZERO exit; 13o2 is the positive control (a run that
# reached its summary passes its status through unchanged).
_TRAP_BLOCK="$(awk 'index($0,"cleanup() {")==1{f=1} f{print} f && $0=="}"{exit}' "${BASH_SOURCE[0]}")"
_TRAP_LINE="$(grep -m1 -x 'trap cleanup EXIT' "${BASH_SOURCE[0]}" || true)"
assert_ne "" "$_TRAP_BLOCK" "13o the harness declares a cleanup() EXIT handler (prerequisite for the pin)"
assert_ne "" "$_TRAP_LINE" "13o the harness installs cleanup on EXIT (prerequisite for the pin)"
_PROBE_T="$T/probe-tmp"; mkdir -p "$_PROBE_T"
printf 'set -u\nT=%q\nSUMMARY_PRINTED=0\n%s\n%s\n: "${DEFINITELY_UNSET_7391}"\n' \
    "$_PROBE_T" "$_TRAP_BLOCK" "$_TRAP_LINE" > "$T/probe-abort.sh"
_probe_rc=0; bash "$T/probe-abort.sh" >/dev/null 2>&1 || _probe_rc=$?
assert_eq "$_probe_rc" "1" "13o T17: a run that aborts BEFORE the summary exits NON-ZERO (\$? is 0 there on bash 3.2)"
mkdir -p "$T/probe-tmp2"
printf 'set -u\nT=%q\nSUMMARY_PRINTED=1\n%s\n%s\nexit 3\n' \
    "$T/probe-tmp2" "$_TRAP_BLOCK" "$_TRAP_LINE" > "$T/probe-ok.sh"
_probe_rc=0; bash "$T/probe-ok.sh" >/dev/null 2>&1 || _probe_rc=$?
assert_eq "$_probe_rc" "3" "13o2 T17 positive control: a run that reached its summary passes its exit status through"


echo ""
echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL"
SUMMARY_PRINTED=1   # the sentinel: only from here may the EXIT trap pass an exit status through
[ "$FAIL" -eq 0 ] || { echo "  ❌ FAILURES — fix and re-run"; exit 1; }
echo "  ✅ all checks passed"
exit 0
