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
#   #633 §14      → a re-record on an already-marker'd body re-runs the head's
#                    NEWEST completed-RED gate check run (singular, id-for-id
#                    with the rerun POST — the recency/livelock guards in
#                    record-review.sh decide it), so the stale red rollup row
#                    is replaced by a fresh attempt; the rerun is gated on the
#                    SIGNED marker, the check-runs read is a GET, and the stub
#                    models the transport so a `-f`-as-POST regression reddens
#                    the suite; fail-soft when nothing to re-run / the API
#                    refuses.

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
assert_not_contains() {
    if grep -qF -- "$2" <<<"$1"; then bad "$3 (unexpectedly present: $2)"; else ok "$3"; fi
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
# HERMETICITY: this suite owns a FAKE HOME and a STUBBED gh, so it must not let the
# ambient shell decide what the subject sees. `GH_REPO` is the sharp one: the script
# falls back to it whenever no repo is passed, and several repo-less vectors (and
# §11.13i) exist precisely to assert the REPO-LESS behaviour — with it exported the
# suite reported 5 failures on an unmodified tree, and with it unset the same tree
# passed, which is a false red in one direction and a false green in the other.
unset GH_REPO
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
#   check-runs (no --jq → RAW envelope) → {"check_runs": ${STUB_CHECK_RUNS:-[]}}
#                                   (the #633 remediation jq's it itself; exit 1
#                                   when STUB_CHECK_RUNS_FAIL=1). A --jq-bearing
#                                   check-runs call is the #1575 clause (E) TSV arm.
#                                   The stub also models the TRANSPORT: a
#                                   /check-runs call carrying -f/-F without
#                                   `-X GET` exits 1 (real gh → POST → 404).
#   PATCH (-X PATCH … --input -)  → swallow stdin; exit 1 when STUB_PATCH_FAIL=1
#   rerun (-X POST … /rerun)      → 201; exit 1 when STUB_RERUN_FAIL=1
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${GH_STUB_LOG:?}"
if [ "$1" = "api" ] && [ "$2" = "-X" ] \
   && { grep -qF -- "/rerun" <<<"$*" || grep -qF -- "-X PATCH" <<<"$*"; }; then
    # PATCH body / job rerun POST. #633: fail either on demand so the fail-soft
    # and no-marker pins are real. A /rerun POST pipes NO stdin, so the read is
    # skipped for it — consuming stdin unconditionally would clobber the PATCH
    # capture with an empty body and, on an inherited terminal, block forever.
    # ⛔ NOT every `-X` call: `gh api -X GET <url> -f …` is a READ (the #633
    # check-runs transport) and must fall through to the routing below. Gating
    # this branch on `$2 = -X` alone mis-routed it here, where it swallowed the
    # capture file with an empty stdin read — which silently BLANKED the recorded
    # marker and made every diff= assertion fail. The branch now names its two
    # mutating callers (PATCH, /rerun) instead of assuming `-X` means write.
    if grep -qF -- "/rerun" <<<"$*"; then
        if [ "${STUB_RERUN_FAIL:-0}" = "1" ]; then exit 1; fi
        exit 0
    fi
    if grep -qF -- "-X PATCH" <<<"$*"; then
        if [ "${STUB_PATCH_FAIL:-0}" = "1" ]; then exit 1; fi
    fi
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
    # #1224 — the review-evidence COMMENT: the copy that TRAVELS (a CI runner's
    # $HOME has no record store, and the record file is per box). Placed before
    # every other arm because the LIST form `issues/<n>/comments` must not be
    # shadowed by the evidence arms below, which key on `issues/comments/<id>`
    # (singular, with an id) and are a different surface.
    #   STUB_COMMENTS         → the list read's `.[].body` answer (already-posed
    #                           markers, for the idempotency pin).
    #   STUB_COMMENTS_FAIL=1  → a transient READ failure: the comment post must
    #                           then be SKIPPED, not duplicated.
    #   STUB_COMMENT_CAPTURE  → sink for a POST body, so the suite can assert the
    #                           COMMENT really carries the marker.
    if grep -qE -- "/issues/[0-9]+/comments" <<<"$*"; then
        if grep -qF -- "--jq" <<<"$*"; then
            [ "${STUB_COMMENTS_FAIL:-0}" = "1" ] && exit 1
            printf '%s' "${STUB_COMMENTS:-}"
            exit 0
        fi
        if [ -n "${STUB_COMMENT_CAPTURE:-}" ]; then cat >"$STUB_COMMENT_CAPTURE"; else cat >/dev/null; fi
        printf '{}\n'
        exit 0
    fi
    # #633 review finding 2: model the TRANSPORT, not just the URL. Real `gh api`
    # switches to POST as soon as ANY `-f`/`-F` parameter is added, and
    # `GET /commits/{ref}/check-runs` is GET-only — so a parameterized call with
    # no explicit `-X GET` answers `404 Not Found`. The original stub matched the
    # URL alone and answered 200 to a request that cannot succeed in production,
    # so it certified the very defect (#633 finding 1) it was meant to catch.
    # A regression to `-f`-without-`-X GET` now reddens the suite (pinned by
    # §14.12). The correct forms are the query string (repo convention) or
    # `-X GET -f …`.
    case "$*" in
        *check-runs*)
            case "$*" in
                *" -f "*|*" -F "*)
                    case "$*" in
                        *"-X GET"*) : ;;
                        *) exit 1 ;;
                    esac ;;
            esac ;;
    esac
    # #2982: the reviewed-diff fetch. Placed FIRST — the request carries no
    # --jq, so it would otherwise fall through to the generic body answer.
    if grep -qF -- "application/vnd.github.v3.diff" <<<"$*"; then
        # #1377: the COMPARE diff read, which the patch carry uses for BOTH
        # sides. Keyed by sha so one test can serve a REVIEWED diff and a
        # DIFFERENT rendered diff for the same base in one invocation — the
        # fixture shape a rebase has and the only way to tell "the patch is the
        # same" apart from "the diff is the same". Gated on the accept header
        # too, so the pre-existing `/compare/` SURFACE arm (which answers the
        # json/meta reads) is untouched.
        if grep -qF -- "/compare/" <<<"$*"; then
            cmp_sha="$(printf '%s' "$*" | sed -n 's#.*/compare/[0-9a-f]*\.\.\.\([0-9a-f]*\).*#\1#p')"
            if [ -n "${STUB_COMPARE_DIFF_DIR:-}" ] && [ -n "$cmp_sha" ] \
               && [ -f "${STUB_COMPARE_DIFF_DIR}/$cmp_sha" ]; then
                cat "${STUB_COMPARE_DIFF_DIR}/$cmp_sha"
                exit 0
            fi
            # No per-sha fixture: fall through to the plain diff arm below, so
            # every test that existed before this arm keeps its behaviour.
        fi
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
    # #633: the stale-gate-run read. The remediation reads the RAW check-runs
    # ENVELOPE and jq's it itself (no --jq in argv), unlike #1575 clause (E)
    # below, which asks gh to emit TSV rows. Distinguished by the missing
    # --jq. STUB_CHECK_RUNS is the JSON array; STUB_CHECK_RUNS_FAIL=1 pins the
    # transport-failure path (a loud warning, never "nothing to remediate").
    if grep -qF -- "check-runs" <<<"$*" && ! grep -qF -- "--jq" <<<"$*"; then
        [ "${STUB_CHECK_RUNS_FAIL:-0}" = "1" ] && exit 1
        printf '{"check_runs": %s}' "${STUB_CHECK_RUNS:-[]}"
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
    # tortoise#9492 — the pinned-head guard's wedge diagnosis: which branch does
    # the PR track, and what does THAT ref point at? Empty STUB_BRANCH_SHA models
    # "could not read it" (the non-wedge arm).
    # #1377: the AUTHORITATIVE base the patch carry diffs against. INERT unless a
    # test sets STUB_BASE_SHA — an armed-always arm would replace whatever the
    # generic tail answers for `.base.sha` today, silently changing the lane-arm
    # vectors that rely on it being unusable.
    if grep -qF -- "--jq .base.sha" <<<"$*" && [ -n "${STUB_BASE_SHA:-}" ]; then
        printf '%s\n' "$STUB_BASE_SHA"
        exit 0
    fi
    if grep -qF -- "--jq .head.ref" <<<"$*"; then
        printf '%s' "${STUB_HEAD_REF:-fix/stub-branch}"
        echo; exit 0
    fi
    if grep -qF -- "git/matching-refs/heads/" <<<"$*"; then
        if [ -z "${STUB_BRANCH_SHA:-}" ]; then exit 1; fi
        printf '%s\n' "$STUB_BRANCH_SHA"
        exit 0
    fi
    # #2872 --recover-body: the repo auto-detection read. The knob is SET-BUT-EMPTY
    # MEANINGFUL (`${STUB_REPO_NAME+x}`), so every pre-existing vector keeps the
    # stub's untouched fall-through: absent = not modelled, empty = "nothing
    # detectable", which is the only way to reach the no-repo refusal.
    if [ -n "${STUB_REPO_NAME+x}" ] && grep -qF -- "nameWithOwner" <<<"$*"; then
        printf '%s' "$STUB_REPO_NAME"
        exit 0
    fi
    if grep -qF -- "--jq .body" <<<"$*"; then
        # Faithful to `--jq .body`: the RAW body text. Real gh applies the jq
        # filter and prints the string bare — it does not emit a JSON wrapper.
        # #2982's carry-forward check greps the body for a marker LINE, so it
        # needs real newlines rather than "\n" escapes.
        # #2872: STUB_BODY_FAIL models a transient read FAILURE, which the
        # recovery verb must report as "could not read" — never as "no marker"
        # ("we could not look" is not "it is not there").
        [ "${STUB_BODY_FAIL:-0}" = "1" ] && { printf '%s' "${STUB_BODY_FAIL_TEXT:-}"; exit 1; }
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
        # #2470/#2511 — the API ANSWERING and REFUSING this revision (a fork head,
        # a rewritten sha): HTTP 404/422, a NON-ZERO exit, and the status on
        # STDERR, which is where `gh` puts it and where `review_surface_rows`
        # classifies it. (#2472 introduced the CAP; #2511 introduced this
        # status-aware refusal — the two are cited where they belong, here and in
        # the §8 preamble.) rc 3 (positive evidence → refuse) must never be
        # confused with a TRANSPORT failure (rc 1 → warn and proceed); §8.16 pins
        # both, and pins a STATUS-BEARING transport failure (403 rate limit / 5xx)
        # separately, because `gh` reports one too and the classifier keys on the
        # status, not on its absence.
        if [ -n "${STUB_COMPARE_HTTP:-}" ]; then
            case "$STUB_COMPARE_HTTP" in
                404) _why="Not Found" ;;
                422) _why="Unprocessable Entity" ;;
                403) _why="API rate limit exceeded" ;;
                5*)  _why="Server Error" ;;
                *)   _why="Error" ;;
            esac
            printf 'gh: %s (HTTP %s)\n' "$_why" "$STUB_COMPARE_HTTP" >&2
            exit 1
        fi
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
        # #2872: a SIDE EFFECT on this read models the only admissible way a record
        # can appear after the pre-read absence check — a concurrent recorder. The
        # late re-check before `mv` exists for exactly this window, and without
        # this knob it could be deleted with the suite green.
        [ -n "${STUB_RACE_PATH:-}" ] && printf '%s\n' "${STUB_RACE_RECORD:-}" > "$STUB_RACE_PATH"
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
        # ⛔ THE clean-micro SURFACE CAP NEEDS A READABLE CHANGED-PATH PAYLOAD, and this runner never
        # supplied one: the stub's `compare/` branch answers with a merge base and NO rows, which the
        # shipped cap reads as rc 3 ("the changed-path payload cannot be certified") and refuses with
        # exit 4 — so every §8/§9 arm that expects a clean-micro ALLOW came back 4, and the 22
        # assertions pinning the LABEL guard were reporting the CAP's refusal instead of the guard they
        # are about. Pre-existing on origin/main (`PASS=622 FAIL=22`), not caused by this change. One
        # benign docs path is enough: the cap refuses a merge/land rail, a CI workflow or an extension,
        # none of which this fixture claims to touch.
        # `-`, not `:-`: C3's arm proves an EMPTY file list refuses, so an explicit "" must survive.
        export STUB_FILES="${STUB_FILES-docs/notes.md}"
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

# #1012 r2/r3, #1336 GitHub-parity seam: closing_issue_refs with the
# BOUNDARY-ANCHORED CLOSING_KW (no positional REFCTX prefix; the boundary is
# CLOSING_KW_BOUNDARY, composed exactly as the tier guard passes it). The #513
# tier guard unions this scan with the positional one, so a mid-sentence ref
# GitHub will auto-close still binds — while prose that merely CONTAINS the
# class ("prefix", "discloses") does not. Since #1336 the boundary also admits
# an emphasis OPENING `_`, so a mid-sentence `_closes #N_` (which GitHub DOES
# close) binds too.
refs_for_any() { # <repo> <text> — boundary-anchored keyword-class scan
    local repo="$1" text="$2"
    (
        export REPO="$repo"
        bash -c 'source "$1" >/dev/null 2>&1 || exit 1; closing_issue_refs "$2" "${CLOSING_KW_BOUNDARY}${CLOSING_KW}"' _ "$RECORD" "$text"
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
        # #1377: the patch-carry knobs, exported EXPLICITLY (with empty defaults)
        # so an ambient value cannot leak into another vector — the scrub the
        # STUB_CHECKS_ROWS note above records as a known limitation here does
        # not exist. A per-invocation prefix still reaches them.
        export STUB_COMPARE_DIFF_DIR="${STUB_COMPARE_DIFF_DIR:-}" STUB_BASE_SHA="${STUB_BASE_SHA:-}"
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

# ── #1224 — ONE MINT, TWO ARTIFACTS, AND THEY MUST AGREE ──────────────────
# check (c) now reads the head-bound RECORD FILE first and falls back to the
# BODY marker only when no record covers the head (agent-infra#1224). That makes
# AGREEMENT between the two a correctness property: if one run could write a
# record at head H with verdict V and append a marker naming a DIFFERENT
# revision, the fallback would be evidence for a revision nobody recorded — the
# gate's own fallback certifying an unreviewed head. The assertion is on the
# (pr, verdict, head, repo) fields only; the marker's optional ` diff=`/` sig=`
# are tolerated, because those are the producer's signing/CARRY contract (#2982)
# and are not part of the binding the gate reads.
# The SECOND run pins idempotency from the outside: the record must come back
# BYTE-IDENTICAL (no churned `reviewed_at`; the #1709 rec 7 no-op is §15.4) and
# the body post must remain a no-op-once-posted append (§12). Together they are
# what makes a duplicate execution harmless — and a duplicate execution is the
# documented remedy for a skipped post.
Q6V="$(sed -n 's/.*"verdict":"\([^"]*\)".*/\1/p' "$Q6" | head -1)"
Q6H="$(sed -n 's/.*"head_sha":"\([^"]*\)".*/\1/p' "$Q6" | head -1)"
Q6_RE="review recorded: reviews/424246\.json verdict=${Q6V} @ ${Q6H}( diff=[0-9a-f]{64})? \(daniel-ospina/agent-infra\)( sig=[0-9a-f]{64})?$"
Q6_RE_SIG="review recorded: reviews/424246\.json verdict=${Q6V} @ ${Q6H}( diff=[0-9a-f]{64})? \(daniel-ospina/agent-infra\)( sig=[0-9a-f]{64})?"
cp "$Q6" "$T/q6-before.json" 2>/dev/null || true
P1224="$T/p1224-patch.json"; : > "$P1224"
STUB_CAPTURE="$P1224" run_record "daniel-ospina/agent-infra" 424246
# The capture is the PATCH payload (`{"body": "…"}`, exactly what the producer
# sends), so the assertion reads `.body` rather than grepping the JSON envelope —
# the envelope would defeat the end-anchor below. Without jq the raw file is read:
# the marker line is then embedded in JSON and the anchor simply does not apply.
P1224_BODY="$T/p1224-body.txt"
if command -v jq >/dev/null 2>&1; then
    jq -r '.body // ""' "$P1224" > "$P1224_BODY" 2>/dev/null || cp "$P1224" "$P1224_BODY"
else
    cp "$P1224" "$P1224_BODY"
fi
if [ "$RECORD_RC" = "0" ] && grep -qE "$Q6_RE" "$P1224_BODY" 2>/dev/null; then
    ok "#1224 the body marker and the record AGREE on (pr, verdict, head, repo) — the gate's fallback is evidence for the revision the record certifies"
else
    bad "#1224 the body marker and the record DISAGREE (or the re-run posted nothing) — check (c)'s fallback would certify a different revision than the record"
fi
if cmp -s "$Q6" "$T/q6-before.json"; then
    ok "#1224 a duplicate run left the record BYTE-IDENTICAL (idempotent — reviewed_at not churned)"
else
    bad "#1224 a duplicate run REWROTE the record (non-idempotent write / reviewed_at churn)"
fi
unset P1224 P1224_BODY

# ── #1224 review finding 3 — THE RECORD FILE IS SIGNED ────────────────────
# The record store is private and leaves NO trace on the PR, so the gate now
# accepts a record as evidence only when its `sig` verifies. That is a CONTRACT
# between two files: the canonical text is declared once in the gate
# (`review_record_sig_text`) and once here (`record_sig_for`), and a divergence
# would make every legitimate record unusable while each file kept passing its
# own tests. This assertion recomputes the GATE's text and checks the producer's
# file against it, so a drift reds the producer's suite.
Q6_SIG="$(sed -n 's/.*"sig":"\([^"]*\)".*/\1/p' "$Q6" | head -1)"
Q6_EXPECT="$(printf '%s' "review-record:v1:424246:${Q6H}:${Q6V}:daniel-ospina/agent-infra" \
    | openssl dgst -sha256 -hmac "$TEST_GATE_KEY" | awk '{print $NF}')"
if [ -n "$Q6_SIG" ] && [ "$Q6_SIG" = "$Q6_EXPECT" ]; then
    ok "#1224 the record FILE carries a sig= over the gate's canonical text (pr,head,verdict,repo) — the private artifact is authenticated, not merely well-shaped"
else
    bad "#1224 the record FILE's sig= does not verify over the gate's canonical text (got: ${Q6_SIG:-<absent>}, want: $Q6_EXPECT) — the gate would refuse every legitimate record"
fi
unset Q6_SIG Q6_EXPECT

# ── #1224 review finding 2 — THE COPY THAT TRAVELS IS A PR COMMENT ──────────
# The required `pipeline-compliance` check runs on a clean CI runner whose $HOME
# has no `~/.pi/agent/reviews`, so a record-first gate can never answer there.
# The marker must therefore also land in a PR COMMENT (`gh pr edit` cannot wipe
# one) — and posting it must be IDEMPOTENT, because the documented remedy for a
# skipped post is to re-run the recorder, and a re-run that re-posted would
# bury the timeline.
Q1224C="$T/p1224-comment.json"; : > "$Q1224C"
STUB_COMMENT_CAPTURE="$Q1224C" run_record "daniel-ospina/agent-infra" 424246
Q1224C_BODY="$T/p1224-comment-body.txt"
if command -v jq >/dev/null 2>&1; then
    jq -r '.body // ""' "$Q1224C" > "$Q1224C_BODY" 2>/dev/null || cp "$Q1224C" "$Q1224C_BODY"
else
    cp "$Q1224C" "$Q1224C_BODY"
fi
if [ "$RECORD_RC" = "0" ] && grep -qE "$Q6_RE_SIG" "$Q1224C_BODY" 2>/dev/null; then
    ok "#1224 the review attestation is ALSO posted as a PR COMMENT — the copy a body edit cannot wipe and a CI runner CAN read"
else
    bad "#1224 no PR COMMENT carrying the marker was posted — the fix stays inert on the required check, whose runner has no record store (finding 2)"
fi
# IDEMPOTENCE: the marker is already in the list, so a re-run must post nothing.
Q1224D="$T/p1224-comment-2.json"; : > "$Q1224D"
STUB_COMMENTS="$(cat "$Q1224C_BODY")" STUB_COMMENT_CAPTURE="$Q1224D" run_record "daniel-ospina/agent-infra" 424246
if [ -s "$Q1224D" ]; then
    bad "#1224 a re-run DUPLICATED the evidence comment (the marker was already there) — every re-record would bury the timeline"
else
    ok "#1224 a re-run posts NO second comment when the marker is already present (idempotent, like the body append)"
fi
# A FAILED LIST READ IS NOT "NO COMMENTS": posting on it would duplicate the
# evidence on every transient API error, so the post must be skipped instead.
Q1224E="$T/p1224-comment-3.json"; : > "$Q1224E"
STUB_COMMENTS_FAIL=1 STUB_COMMENT_CAPTURE="$Q1224E" run_record "daniel-ospina/agent-infra" 424246
if [ -s "$Q1224E" ]; then
    bad "#1224 an unreadable comment list was treated as 'no comment' and the evidence was re-posted — a transient 5xx duplicates evidence"
else
    ok "#1224 an unreadable comment list SKIPS the post (skipped, never duplicated)"
fi
unset Q1224C Q1224C_BODY Q1224D Q1224E Q6V Q6H Q6_RE Q6_RE_SIG

echo "── 7. Stale-sha refusal: mismatched head → exit 3, no record ────"
MISMATCH_SHA="$(printf 'b%.0s' $(seq 1 40))" # 40×b — stub answers aaaa…, so bbbb… is stale
STUB_HEAD_SHA="$SHA" run_record_rc "daniel-ospina/agent-infra" 424247 "$MISMATCH_SHA"
RC7="$RECORD_RC"
[ "$RC7" = "3" ] && ok "stale-sha guard refuses (exit 3)" || bad "stale-sha guard refuses (exit 3, got rc=$RC7)"
[ ! -f "$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-424247.json" ] && ok "no record written on refusal" || bad "no record written on refusal"

echo "── 8. #513 clean-micro tier guard ────────────────────────────"

# ── THE SURFACE FIXTURE (fixture-vs-code, decided at #2615) ─────────────────
# #2472 added the clean-micro SURFACE CAP to record-review.sh (arm a0): the
# guard reads the recorded revision's CHANGED PATHS before it reads the tier,
# because a tier chosen from a linked issue's label alone could clear a one-line
# edit to a merge/land rail for a process that dispatches no reviewers. So every
# vector below has to model a PR that HAS a surface — one docs path, the shape a
# genuine micro change has.
#
# It did not, and this suite went RED the moment the cap landed (measured:
# PASS=644 FAIL=0 at aa6c1600f^ → PASS=622 FAIL=22 at aa6c1600f). The stub's
# meta arm answered `changed_files=1` (its `derived` default) and its `compare/`
# arm answered with a merge base and NO row (it emits a row only when
# `STUB_COMPARE`/`STUB_FILES` is set), so `review_surface_rows` returned rc 3 and
# the cap refused exit 4.
#
# ⛔ THE REFUSAL WAS CORRECT — this is a FIXTURE fix, not a code fix (#2615).
# `changed_files>=1` with an empty `.files[]` is not an answer GitHub gives, and
# the SURFACE CAP's own contract (#2470/#2472) is that an EMPTY payload must
# never certify a changed-path surface ("0 changed paths ⇒ no surface change" is
# the fail-open). Loosening this arm to make the vectors pass is that defect
# coming back. (The #2982 citations elsewhere in this file are the DIFF-BINDING
# sink — the sha-keyed carry-forward — not this contract; the empty-payload rule
# arrived with the cap in #2472, and the 404/422 positive-evidence rule with
# #2511. Cited correctly here so the next lane reads the rule where it lives.)
# The competing hypothesis is falsified by measurement: a 0-byte DIFF BODY is not
# refused at all — with a truthful one-row surface and `/dev/null` as the diff,
# clean-micro records rc 0 and only loses the carry-forward digest (a legacy
# sha-only marker). §8.16 pins the cap's four outcomes apart, including the
# "claims-a-surface, delivers-none" shape as a REFUSAL, so it can never again be
# read as a stale vector and "fixed" by loosening it.
#
# A refusal assertion is only meaningful next to the WORDING its own arm emits:
# the cap and the tier guard BOTH exit 4, so every vector that asserts `rc 4`
# kept passing while the cap was the one refusing. Measured on the stale fixture:
# neutering the tier guard's own `exit 4` left this suite at FAIL=22, the SAME
# count it had without the mutation — the rc=4 arms did not move at all, and only
# §8.2's two stderr assertions noticed. Hence `assert_tier_refusal` on every
# arm-(b) vector below (it fires on 9 of them when the cap is what refuses).
MICRO_SURFACE="docs/plans/2026-09-22-x.md"
run_micro_verdict() { # <pr> [sha] — clean-micro on a REAL one-file diff
    # `STUB_FILES` stays overridable (and `-`, not `:-`, so an EXPLICIT empty
    # value means "no changed-path rows") because §8.16 has to express the
    # surface states this suite now distinguishes.
    STUB_FILES="${STUB_FILES-$MICRO_SURFACE}" run_record_verdict clean-micro "daniel-ospina/agent-infra" "$@"
}
assert_tier_refusal() { # <label> — the rc is asserted by the caller
    assert_contains "$RECORD_ERR" "is REFUSED for a non-micro linked issue" \
        "$1: the TIER guard refused it (not the surface cap)"
}

# 8.1 arm (a): linked same-repo issue complexity:micro → allow, marker carries the verdict.
STUB_BODY="Fixes #424300" STUB_LABELS="complexity:micro" run_micro_verdict 424300
Q81="$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-424300.json"
[ "$RECORD_RC" = "0" ] && ok "arm (a): complexity:micro linked issue allows (rc 0)" || bad "arm (a): allows (rc=$RECORD_RC, err=$RECORD_ERR)"
[ -f "$Q81" ] && ok "arm (a): record written" || bad "arm (a): record written"
assert_contains "$(cat "$Q81" 2>/dev/null || true)" '"verdict":"clean-micro"' "arm (a): record carries verdict clean-micro"

# 8.2 arm (b): complexity:standard → exit 4, NO record.
STUB_BODY="Fixes #424301" STUB_LABELS="complexity:standard" run_micro_verdict 424301
Q82="$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-424301.json"
[ "$RECORD_RC" = "4" ] && ok "arm (b): complexity:standard refuses (exit 4)" || bad "arm (b): refuses (rc=$RECORD_RC, err=$RECORD_ERR)"
[ ! -f "$Q82" ] && ok "arm (b): no record written on refusal" || bad "arm (b): no record written on refusal"
assert_tier_refusal "arm (b)"
assert_contains "$RECORD_ERR" "record-review.sh 424301 <head-sha> clean daniel-ospina/agent-infra --evidence" "arm (b): exit-4 stderr prescribes the standard/complex remedy"
assert_contains "$RECORD_ERR" "relabel complexity:micro" "arm (b): exit-4 stderr names the mislabel remedy"

# 8.3 arm (b): complexity:complex → exit 4 (label-space totality: any non-micro complexity:*).
STUB_BODY="Fixes #424302" STUB_LABELS="complexity:complex" run_micro_verdict 424302
[ "$RECORD_RC" = "4" ] && ok "arm (b): complexity:complex refuses (exit 4)" || bad "arm (b): complexity:complex (rc=$RECORD_RC)"
assert_tier_refusal "arm (b) complex"

# 8.4 arm (b): pre-existing valid record survives a refusal byte-identical.
Q84="$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-424303.json"
printf '{"pr":424303,"head_sha":"%s","verdict":"clean","repo":"daniel-ospina/agent-infra","reviewed_at":"old"}\n' "$SHA" > "$Q84"
BEFORE84="$(cat "$Q84")"
STUB_BODY="Fixes #424303" STUB_LABELS="complexity:standard" run_micro_verdict 424303
[ "$RECORD_RC" = "4" ] && ok "arm (b): refuses over a pre-existing clean record (rc 4)" || bad "arm (b): pre-existing (rc=$RECORD_RC)"
[ "$(cat "$Q84")" = "$BEFORE84" ] && ok "arm (b): pre-existing record survives byte-identical" || bad "arm (b): pre-existing record mutated by the refusal"
assert_tier_refusal "arm (b) over a pre-existing record"

# 8.5 arm (c): labels carry no complexity:* → fail-open, record written, loud warning.
STUB_BODY="Fixes #424304" STUB_LABELS="enhancement" run_micro_verdict 424304
Q85="$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-424304.json"
[ "$RECORD_RC" = "0" ] && ok "arm (c): no complexity label fails open (rc 0)" || bad "arm (c): no complexity label (rc=$RECORD_RC)"
[ -f "$Q85" ] && ok "arm (c): record written" || bad "arm (c): record written"
assert_contains "$RECORD_ERR" "UNVERIFIED" "arm (c): warning names the unverified tier"

# 8.6 arm (c): labels fetch failure (stub exit 1) → fail-open, no refusal.
STUB_BODY="Fixes #424305" STUB_LABELS="complexity:micro" STUB_LABELS_FAIL=1 run_micro_verdict 424305
Q86="$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-424305.json"
[ "$RECORD_RC" = "0" ] && ok "arm (c): labels fetch failure fails open (rc 0)" || bad "arm (c): labels fetch failure (rc=$RECORD_RC, err=$RECORD_ERR)"
[ -f "$Q86" ] && ok "arm (c): record written on fetch failure" || bad "arm (c): record written on fetch failure"

# 8.7 arm (c): no closing ref in the body → fail-open warning.
STUB_BODY="Just a docs change, no issue referenced" STUB_LABELS="complexity:micro" run_micro_verdict 424306
[ "$RECORD_RC" = "0" ] && ok "arm (c): body without closing ref fails open (rc 0)" || bad "arm (c): no closing ref (rc=$RECORD_RC)"
assert_contains "$RECORD_ERR" "no same-repo closing-issue ref" "arm (c): warning names the missing linkage"

# 8.8 arm (c): cross-repo-only closing ref → never binds tier → fail-open.
STUB_BODY="Fixes daniel-ospina/tortoise#424307" STUB_LABELS="complexity:standard" run_micro_verdict 424308
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
STUB_BODY=$'Fixes #424310\nCloses #424311' run_micro_verdict 424309 "$SHA"
[ "$RECORD_RC" = "4" ] && ok "multi-ref: any same-repo non-micro ref refuses (rc 4)" || bad "multi-ref: any non-micro refuses (rc=$RECORD_RC, err=$RECORD_ERR)"
assert_tier_refusal "multi-ref non-micro"
STUB_BODY=$'Fixes #424312\nCloses #424313' run_micro_verdict 424314 "$SHA"
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
STUB_BODY=$'Closes #424330\nThis also closes #424331' run_micro_verdict 424332 "$SHA"
[ "$RECORD_RC" = "4" ] && ok "github-parity bind: mid-sentence complex ref refuses (rc 4)" || bad "github-parity bind: mid-sentence complex ref must refuse (rc=$RECORD_RC, err=$RECORD_ERR)"
[ ! -f "$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-424332.json" ] && ok "github-parity bind: no record written on refusal" || bad "github-parity bind: record written on refusal"
assert_tier_refusal "github-parity mid-sentence complex"
# Positive control: when the mid-sentence ref is ALSO micro, the union must not
# manufacture a refusal.
printf 'complexity:micro\n' > "$T/labels/424333"
STUB_BODY=$'Closes #424330\nThis also closes #424333' run_micro_verdict 424334 "$SHA"
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
STUB_BODY="Fixes DANIEL-OSPINA/Agent-Infra#424316" run_micro_verdict 424317 "$SHA"
[ "$RECORD_RC" = "4" ] && ok "mixed-case slug: same-repo ref with different casing still refuses (rc 4)" || bad "mixed-case slug: casing bypassed the tier bind (rc=$RECORD_RC, err=$RECORD_ERR)"
assert_tier_refusal "mixed-case slug"
STUB_BODY="Fixes https://github.com/Daniel-Ospina/Agent-Infra/issues/424316" run_micro_verdict 424318 "$SHA"
[ "$RECORD_RC" = "4" ] && ok "mixed-case URL: full-URL casing still refuses (rc 4)" || bad "mixed-case URL: casing bypassed the tier bind (rc=$RECORD_RC, err=$RECORD_ERR)"
assert_tier_refusal "mixed-case URL"
STUB_BODY="Fixes https://GITHUB.com/Daniel-Ospina/Agent-Infra/issues/424316" run_micro_verdict 424319 "$SHA"
[ "$RECORD_RC" = "4" ] && ok "mixed-case HOST URL: uppercase host still refuses (rc 4)" || bad "mixed-case HOST URL: host casing bypassed the tier bind (rc=$RECORD_RC, err=$RECORD_ERR)"
assert_tier_refusal "mixed-case HOST URL"
unset STUB_LABELS_DIR STUB_LABELS
rm -rf "$T/labels"

# 8.10 clean verdict: no gh LABELS call (#513/#568). The clean path now makes
#      exactly ONE other gh call — the bounded `commits/<sha>/check-runs` GET
#      the #633 stale-run remediation reads — so the claim is scoped to the
#      labels query, which is what this pin greps for. The pre-fix comment
#      ("ZERO extra gh calls") stopped being true with #633; corrected here.
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
# #1012 r3 — the parity scan is BOUNDARY-anchored because the keyword class is
# a SUFFIX of ordinary English words. Unanchored, these three bodies were
# read as `fix #42` / `closes #42` / `resolved #42`, triggering a label fetch
# and a false `exit 4` refusal on a non-micro issue. RED pre-fix.
OUT="$(refs_for_any "daniel-ospina/agent-infra" "The prefix #42 is unrelated.")"
[ -z "$OUT" ] && ok "parser: parity scan ignores 'prefix #42' (word boundary)" || bad "parser: parity scan must ignore 'prefix #42' (got: $OUT)"
OUT="$(refs_for_any "daniel-ospina/agent-infra" "This discloses #42 but does not close it.")"
[ -z "$OUT" ] && ok "parser: parity scan ignores 'discloses #42' (word boundary)" || bad "parser: parity scan must ignore 'discloses #42' (got: $OUT)"
OUT="$(refs_for_any "daniel-ospina/agent-infra" "Unresolved #42 remains open.")"
[ -z "$OUT" ] && ok "parser: parity scan ignores 'unresolved #42' (word boundary)" || bad "parser: parity scan must ignore 'unresolved #42' (got: $OUT)"
# #1336 — the boundary is NOT a bare `\b`: GitHub CLOSES an emphasis-wrapped
# `_Closes #N_` (measured against GitHub's own closingIssuesReferences on scratch
# repo `ai-gate-semantics-test` PR #13), so the parity scan must resolve it —
# otherwise a mid-sentence underscore-emphasis closure records clean-micro with
# the tier guard silent. RED pre-#1336.
OUT="$(refs_for_any "daniel-ospina/agent-infra" "_Closes #42_")"
assert_contains "$OUT" "#42" "parser: parity scan resolves underscore-emphasis '_Closes #N_' (#1336)"
OUT="$(refs_for_any "daniel-ospina/agent-infra" "__Closes #42__")"
assert_contains "$OUT" "#42" "parser: parity scan resolves '__Closes #N__' (#1336)"
OUT="$(refs_for_any "daniel-ospina/agent-infra" "This also _closes #42_ in passing")"
assert_contains "$OUT" "#42" "parser: parity scan resolves a MID-SENTENCE '_closes #N_' (#1336)"
# ...and the mirror control: an INTRA-WORD underscore is not an emphasis
# opener, and GitHub does NOT close `foo_closes #42` — a fix that widened the
# class to `[^[:alnum:]]` would invent a ref here and FALSE-refuse.
OUT="$(refs_for_any "daniel-ospina/agent-infra" "This is a foo_closes #42 reference.")"
[ -z "$OUT" ] && ok "parser: parity scan ignores 'foo_closes #42' (intra-word underscore)" || bad "parser: parity scan must ignore 'foo_closes #42' (got: $OUT)"

# 8.12 repo-less clean-micro → arm (c) fail-open (no repo to tier-bind).
run_record_verdict clean-micro "" 424316
[ "$RECORD_RC" = "0" ] && ok "repo-less clean-micro fails open (rc 0)" || bad "repo-less clean-micro (rc=$RECORD_RC)"
assert_contains "$RECORD_ERR" "UNVERIFIED" "repo-less clean-micro warns the tier is unverified"

# 8.13 cross-script byte-identity pin (#1012 r2, extended #1336) — the REFCTX
# positional prefix, the CLOSING_KW keyword class AND the CLOSING_KW_BOUNDARY
# parity wrapper MUST be byte-identical between check-pipeline-compliance.sh and
# record-review.sh: that equality is the stated justification for anchoring both
# parsers with the same rule, yet nothing asserted it, so a one-sided edit could
# silently desynchronize the two gates. Extract the constant lines (in file
# order) and compare them.
A_CONST="$(grep -E '^(REFCTX|CLOSING_KW|CLOSING_KW_BOUNDARY)=' "$SCRIPT_DIR/check-pipeline-compliance.sh" || true)"
B_CONST="$(grep -E '^(REFCTX|CLOSING_KW|CLOSING_KW_BOUNDARY)=' "$RECORD" || true)"
[ -n "$A_CONST" ] && [ -n "$B_CONST" ] || bad "cross-script pin: REFCTX/CLOSING_KW/CLOSING_KW_BOUNDARY lines missing from a script (extraction is vacuous)"
assert_eq "$A_CONST" "$B_CONST" "cross-script byte-identity: REFCTX + CLOSING_KW + CLOSING_KW_BOUNDARY lines identical"

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
STUB_BODY='The prefix #424340 is unrelated.' run_micro_verdict 424340 "$SHA"
[ "$RECORD_RC" = "0" ] && ok "false-refusal: 'prefix #N' is not a closing ref (rc 0)" || bad "false-refusal: 'prefix #N' must not refuse (rc=$RECORD_RC, err=$RECORD_ERR)"
[ -f "$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-424340.json" ] && ok "false-refusal: 'prefix #N' record written" || bad "false-refusal: 'prefix #N' record must be written"
assert_contains "$RECORD_ERR" "no same-repo closing-issue ref" "false-refusal: 'prefix #N' reached arm (c), not a tier bind"
STUB_BODY='This discloses #424341 but does not close it.' run_micro_verdict 424341 "$SHA"
[ "$RECORD_RC" = "0" ] && ok "false-refusal: 'discloses #N' is not a closing ref (rc 0)" || bad "false-refusal: 'discloses #N' must not refuse (rc=$RECORD_RC, err=$RECORD_ERR)"
STUB_BODY='Unresolved #424342 remains open.' run_micro_verdict 424342 "$SHA"
[ "$RECORD_RC" = "0" ] && ok "false-refusal: 'unresolved #N' is not a closing ref (rc 0)" || bad "false-refusal: 'unresolved #N' must not refuse (rc=$RECORD_RC, err=$RECORD_ERR)"
unset STUB_LABELS_DIR STUB_LABELS
rm -rf "$T/labels"

# 8.15 (#1336) — the #513 tier guard must BIND a mid-sentence underscore-emphasis
# closing keyword. GitHub CLOSES `_closes #N_` (measured: scratch repo
# `ai-gate-semantics-test` PR #13 vs its GraphQL closingIssuesReferences), and
# the POSITIONAL scan cannot see it (not line-leading), so before #1336 the
# parity scan's `\b` was the only candidate — and `\b` does not fire after `_`
# (`_` is a word character), so a non-micro issue could be recorded clean-micro
# with the guard silent. RED pre-fix (rc 0, record written); GREEN post-fix
# (rc 4, no record).
mkdir -p "$T/labels"
printf 'complexity:standard\n' > "$T/labels/424350"
printf 'complexity:standard\n' > "$T/labels/424351"
export STUB_LABELS_DIR="$T/labels"
export STUB_LABELS=""
STUB_BODY='This also _closes #424350_ in passing' run_micro_verdict 424350 "$SHA"
[ "$RECORD_RC" = "4" ] && ok "#1336: mid-sentence '_closes #N_' refuses a non-micro ref (rc 4)" || bad "#1336: mid-sentence '_closes #N_' must refuse (rc=$RECORD_RC, err=$RECORD_ERR)"
[ ! -f "$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-424350.json" ] && ok "#1336: underscore-emphasis refusal wrote no record" || bad "#1336: refusal must write no record"
assert_tier_refusal "#1336 underscore-emphasis"
# Negative control, and it is the whole point of `[^[:alnum:]_]` over
# `[^[:alnum:]]`: an INTRA-WORD underscore is not an emphasis opener and GitHub
# does NOT close `foo_closes #N`, so the guard must PROCEED (arm (c)). A fix that
# widened the class by deleting `_` from the non-word set would false-refuse.
STUB_BODY='This is a foo_closes #424351 reference' run_micro_verdict 424351 "$SHA"
[ "$RECORD_RC" = "0" ] && ok "#1336: intra-word 'foo_closes #N' is not a closing ref (rc 0)" || bad "#1336: 'foo_closes #N' must not refuse (rc=$RECORD_RC, err=$RECORD_ERR)"
assert_contains "$RECORD_ERR" "no same-repo closing-issue ref" "#1336: 'foo_closes #N' reached arm (c), not a tier bind"
unset STUB_LABELS_DIR STUB_LABELS
rm -rf "$T/labels"

# 8.16 (#2615) — THE SURFACE CAP'S FOUR OUTCOMES, PINNED APART. The cap is the
# one place where "the API answered EMPTY" and "I could not read it" were read by
# a human as the same thing: tonight's red was diagnosed from a log that showed
# an empty DIFF BODY beside a refusal, although the refusal came from the
# CHANGED-PATH payload and the empty body only cost the carry-forward digest.
# No vector in this suite exercised the cap at all — the only ones that did
# lived in tests/record-review/run.sh §30viii/30ix/30x — so its arms could
# collapse without a red. Each arm below asserts its own rc and whether a record
# was written; the WORDING is a class, not an arm: `review_surface_rows` returns
# one rc per cause CLASS, so REFUSED (a compare 404/422) and INCONSISTENT (a
# `mb` header with no row) are the SAME rc 3 and share its cause-list message —
# they are pinned as one class with two causes. rc 0/1/2 each have wording of
# their own. The count/parity refusal ("changes N path(s) but GitHub reports M —
# the changed-path list is truncated or inconsistent") is a rc-0 path with its OWN
# message, so it is pinned separately below: without that vector, deleting the
# arm (`[ "$MICRO_DISTINCT" -ge 300 ] || [ "$MICRO_DISTINCT" != "$MICRO_EXPECT" ]`)
# leaves this suite green (measured), i.e. a truncated or forged changed-path
# list could certify a surface. `tests/record-review/run.sh` §30vi pins only the
# `--print-tier` classification (`too_large`), never this record-path refusal.
#
#   EMPTY        the API ANSWERED: 0 changed files            → rc 2, exit 4
#   UNREADABLE   transport, no status / status-bearing 403/5xx → rc 1, WARN + record
#   REFUSED      the API answered and REFUSED this revision    → rc 3, exit 4
#   INCONSISTENT claims a surface and delivers no row          → rc 3, exit 4
#
# The split is load-bearing, not cosmetic: a transport blip must not strand a
# legitimate micro record (fail-open), while a payload that cannot certify a
# surface must never clear a tier that dispatches no reviewers (fail-closed).
# Both halves of the refusal set are pinned: the classifier keys on
# `HTTP (404|422)`, so a 422-only regression (a rewritten sha) would be invisible
# to a 404-only vector — measured: narrowing that regex to `HTTP 404` left this
# suite green before the 422 vector existed.
echo "── 8.16 (#2615) the clean-micro surface cap tells its four outcomes apart ──"

# EMPTY — the API answered with NO changed files. The `empty` status, not a
# truncation and not a read failure: there is no surface to certify.
STUB_CHANGED_FILES=0 STUB_FILES="" run_micro_verdict 424360
[ "$RECORD_RC" = "4" ] && ok "8.16 empty: 0 changed files refuses (exit 4)" || bad "8.16 empty: must refuse (rc=$RECORD_RC, err=$RECORD_ERR)"
[ ! -f "$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-424360.json" ] && ok "8.16 empty: no record written" || bad "8.16 empty: wrote a record for a diff with no surface"
assert_contains "$RECORD_ERR" "has NO changed files, so there is no surface to certify" "8.16 empty: the refusal names the EMPTY payload"
assert_not_contains "$RECORD_ERR" "could not read the changed paths" "8.16 empty: an answered-empty is NOT reported as a read failure"
assert_not_contains "$RECORD_ERR" "cannot be certified" "8.16 empty: the EMPTY arm is distinct from the uncertifiable arm"

# UNREADABLE (1/2) — a TRANSPORT failure with NO status at all: `gh` exits
# non-zero with empty stderr (a dead socket, a killed process). NOTHING was read,
# so the cap is UNVERIFIED and the record PROCEEDS with a loud warning (the
# pre-existing fail-open posture). If this ever starts refusing, a legitimate
# micro PR is stranded on a network blip and told to pay for a full review.
STUB_COMPARE_FAIL=1 STUB_BODY="Fixes #424361" STUB_LABELS="complexity:micro" run_micro_verdict 424361
[ "$RECORD_RC" = "0" ] && ok "8.16 unreadable: a transport failure warns and PROCEEDS (rc 0)" || bad "8.16 unreadable: must proceed (rc=$RECORD_RC, err=$RECORD_ERR)"
[ -f "$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-424361.json" ] && ok "8.16 unreadable: the record IS written (fail-open)" || bad "8.16 unreadable: no record written — a transport blip stranded a legitimate record"
assert_contains "$RECORD_ERR" "could not read the changed paths" "8.16 unreadable: the warning names the READ failure"
assert_not_contains "$RECORD_ERR" "cannot be certified" "8.16 unreadable: a read failure is NOT reported as an uncertifiable payload"

# UNREADABLE (2/2) — a TRANSPORT failure that DOES carry a status (a 403 rate
# limit / a 5xx). `gh` reports those on stderr just as it reports a 404, so the
# classifier must key on WHICH status, not on whether one is present: only
# 404/422 refuse. This vector is the reason the stub's HTTP arm prints a
# status-appropriate reason string.
STUB_COMPARE_HTTP=503 STUB_BODY="Fixes #424365" STUB_LABELS="complexity:micro" run_micro_verdict 424365
[ "$RECORD_RC" = "0" ] && ok "8.16 unreadable: a status-bearing transport failure (503) PROCEEDS (rc 0)" || bad "8.16 unreadable: a 503 must proceed, not refuse (rc=$RECORD_RC, err=$RECORD_ERR)"
[ -f "$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-424365.json" ] && ok "8.16 unreadable: the 503 record IS written" || bad "8.16 unreadable: a 503 stranded a legitimate record"
assert_contains "$RECORD_ERR" "could not read the changed paths" "8.16 unreadable: the 503 warning names the READ failure"
assert_not_contains "$RECORD_ERR" "cannot be certified" "8.16 unreadable: a 503 is NOT reported as an uncertifiable payload"

# UNREADABLE (3/3) — the OTHER rc-1 cause: the `pulls` meta read itself failed,
# so the cap never reaches the compare. Same posture (warn, record proceeds), and
# pinned because `review_surface_rows`' contract names three rc-1 causes while a
# compare-only vector exercises one.
# ⚠️ PINNED AS-IS, NOT AS SHOULD (#2628). The pulls read does
# `2>/dev/null ... || return 1`, so it cannot tell a dead socket from a 401/403/
# 5xx/404 — the #2511 review's P1, still unfixed and was untracked until #2628.
# This vector therefore pins the CURRENT behaviour deliberately; when #2628 makes
# that read status-aware (404/422 → rc 3), THIS assertion must change with it.
# Do not read it as an endorsement.
STUB_META_FAIL=1 STUB_BODY="Fixes #424366" STUB_LABELS="complexity:micro" run_micro_verdict 424366
[ "$RECORD_RC" = "0" ] && ok "8.16 unreadable: a failed meta read PROCEEDS (rc 0)" || bad "8.16 unreadable: a failed meta read must proceed (rc=$RECORD_RC, err=$RECORD_ERR)"
[ -f "$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-424366.json" ] && ok "8.16 unreadable: the record IS written after a failed meta read" || bad "8.16 unreadable: a failed meta read stranded a legitimate record"
assert_contains "$RECORD_ERR" "could not read the changed paths" "8.16 unreadable: the failed-meta warning names the READ failure"

# UNREADABLE (4/4) — and a rate-limit window (403), which `gh` reports WITH a
# status. Pinned separately from the 503 because it is the shape a lane actually
# hits and the one #2511's review measured as a false-refusal risk: if the
# classifier ever widened to `HTTP 403`, a throttled compare would REFUSE and
# strand a legitimate micro record. Measured: widening `HTTP (404|422)` to
# include 403 now reds this vector.
STUB_COMPARE_HTTP=403 STUB_BODY="Fixes #424368" STUB_LABELS="complexity:micro" run_micro_verdict 424368
[ "$RECORD_RC" = "0" ] && ok "8.16 unreadable: a rate-limited compare (403) PROCEEDS (rc 0)" || bad "8.16 unreadable: a 403 must proceed, not refuse (rc=$RECORD_RC, err=$RECORD_ERR)"
[ -f "$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-424368.json" ] && ok "8.16 unreadable: the 403 record IS written" || bad "8.16 unreadable: a 403 stranded a legitimate record"
assert_contains "$RECORD_ERR" "could not read the changed paths" "8.16 unreadable: the 403 warning names the READ failure"
assert_not_contains "$RECORD_ERR" "cannot be certified" "8.16 unreadable: a 403 is NOT reported as an uncertifiable payload"

# REFUSED (1/2) — the API ANSWERED and refused this revision (HTTP 404: an
# unreachable fork head, a rewritten sha). POSITIVE evidence, so it refuses: the
# surface of THIS sha cannot be read, and a tier that dispatches no reviewers must
# not be cleared on a guess. The wording must not blame the network.
STUB_COMPARE_HTTP=404 STUB_BODY="Fixes #424362" STUB_LABELS="complexity:micro" run_micro_verdict 424362
[ "$RECORD_RC" = "4" ] && ok "8.16 refused: a compare 404 refuses (exit 4)" || bad "8.16 refused: must refuse (rc=$RECORD_RC, err=$RECORD_ERR)"
[ ! -f "$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-424362.json" ] && ok "8.16 refused: no record written" || bad "8.16 refused: wrote a record over a refused revision"
assert_contains "$RECORD_ERR" "cannot be certified" "8.16 refused: the refusal names the uncertifiable payload"
assert_not_contains "$RECORD_ERR" "could not read the changed paths" "8.16 refused: an API REFUSAL is NOT reported as a transport failure"

# REFUSED (2/2) — and the SAME class's other status, 422 (a rewritten sha).
# The classifier's pattern is `HTTP (404|422)`, so a 404-only vector cannot see a
# regression that drops 422 — measured: narrowing it to `HTTP 404` left this
# suite green, which is a fail-open on the rewritten-sha class the cap exists for.
STUB_COMPARE_HTTP=422 STUB_BODY="Fixes #424367" STUB_LABELS="complexity:micro" run_micro_verdict 424367
[ "$RECORD_RC" = "4" ] && ok "8.16 refused: a compare 422 refuses (exit 4)" || bad "8.16 refused: a 422 must refuse (rc=$RECORD_RC, err=$RECORD_ERR)"
[ ! -f "$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-424367.json" ] && ok "8.16 refused: no record written for a 422" || bad "8.16 refused: wrote a record over a 422-refused revision"
assert_contains "$RECORD_ERR" "cannot be certified" "8.16 refused: the 422 refusal names the uncertifiable payload"
assert_not_contains "$RECORD_ERR" "could not read the changed paths" "8.16 refused: a 422 is NOT reported as a transport failure"

# INCONSISTENT — the payload CLAIMS a surface (changed_files=1) and delivers no
# changed-path row. THIS IS TONIGHT'S SHAPE (#2615): the fixture produced it and
# the cap refused, correctly. Pinned as a REFUSAL so a future stale vector can
# never be "fixed" by loosening this arm back into the #2470/#2472 fail-open.
STUB_CHANGED_FILES=1 STUB_FILES="" STUB_COMPARE="" STUB_BODY="Fixes #424363" STUB_LABELS="complexity:micro" run_micro_verdict 424363
[ "$RECORD_RC" = "4" ] && ok "8.16 inconsistent: a claimed-but-absent surface refuses (exit 4)" || bad "8.16 inconsistent: must refuse — an empty payload must never certify a surface (rc=$RECORD_RC, err=$RECORD_ERR)"
[ ! -f "$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-424363.json" ] && ok "8.16 inconsistent: no record written" || bad "8.16 inconsistent: certified a tier from an empty changed-path payload"
assert_contains "$RECORD_ERR" "cannot be certified" "8.16 inconsistent: the refusal names the uncertifiable payload"

# ...and the boundary on the other side, so 8.16 cannot pass by refusing
# everything: a rail path in the SAME one-file shape still refuses, and names
# the surface it hit.
STUB_FILES="scripts/admin-merge.sh" STUB_BODY="Fixes #424364" STUB_LABELS="complexity:micro" run_micro_verdict 424364
[ "$RECORD_RC" = "4" ] && ok "8.16 rail: a rail path in a micro diff still refuses (exit 4)" || bad "8.16 rail: must refuse (rc=$RECORD_RC, err=$RECORD_ERR)"
[ ! -f "$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-424364.json" ] && ok "8.16 rail: no record written" || bad "8.16 rail: wrote a clean-micro record for a rail edit"
assert_contains "$RECORD_ERR" "touches an ALWAYS-FULL surface" "8.16 rail: the refusal names the ALWAYS-FULL surface"

# PARITY/TRUNCATION — the payload delivers a DIFFERENT number of distinct paths
# than GitHub's own `changed_files` says the PR has (the compare endpoint caps at
# 300 entries and does not paginate, so an AT-THE-CAP list may be short — and a
# short list could be missing the one rail path that would have selected `full`).
# This arm had no vector anywhere: `tests/record-review/run.sh` §30vi pins the
# `--print-tier` `too_large` status only, so deleting the record-path arm left
# both suites green (measured). Note the message is its OWN, not the rc-3 list.
STUB_CHANGED_FILES=2 STUB_BODY="Fixes #424369" STUB_LABELS="complexity:micro" run_micro_verdict 424369
[ "$RECORD_RC" = "4" ] && ok "8.16 parity: a 1-row payload for a 2-file PR refuses (exit 4)" || bad "8.16 parity: a truncated list must refuse (rc=$RECORD_RC, err=$RECORD_ERR)"
[ ! -f "$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-424369.json" ] && ok "8.16 parity: no record written for a truncated list" || bad "8.16 parity: certified a surface from a list GitHub says is short"
assert_contains "$RECORD_ERR" "the changed-path list is truncated or inconsistent" "8.16 parity: the refusal names the truncated/inconsistent list"
assert_not_contains "$RECORD_ERR" "cannot be certified" "8.16 parity: the truncation arm has its own wording (not the rc-3 cause list)"

# THE 300-ENTRY CEILING — the arm's OTHER disjunct, and it is a different failure
# mode from the parity one above: the compare endpoint returns at most 300 entries
# and does not paginate, so a diff AT the cap may have been silently shortened —
# and `a diff that large is never micro` is the policy besides. Pinned separately
# because each disjunct guards a different hole: the parity vector above catches a
# COUNT MISMATCH, this one catches a COMPLETE-LOOKING 300-path diff, which the
# `-ge 300` half refuses on size alone. Measured: deleting just `[ "$MICRO_DISTINCT"
# -ge 300 ] ||` left this suite green before this vector existed, i.e. a 300-path
# diff could have recorded clean-micro — the tier that dispatches no reviewers.
STUB_CHANGED_FILES=300 STUB_FILES="$(seq -f 'docs/f%g.md' 1 300)" STUB_BODY="Fixes #424370" STUB_LABELS="complexity:micro" run_micro_verdict 424370
[ "$RECORD_RC" = "4" ] && ok "8.16 ceiling: a 300-path diff refuses (exit 4)" || bad "8.16 ceiling: a 300-path diff must refuse (rc=$RECORD_RC, err=$RECORD_ERR)"
[ ! -f "$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-424370.json" ] && ok "8.16 ceiling: no record written at the 300-entry cap" || bad "8.16 ceiling: certified a 300-path diff clean-micro"
assert_contains "$RECORD_ERR" "the changed-path list is truncated or inconsistent" "8.16 ceiling: the refusal names the truncated/inconsistent list"

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

# 11.3e2 (#2342): a REFUSED read of the target head's surface is NOT "not red". The read used to be
# `... 2>/dev/null || true` plus `[ -n "$raw" ] || return 1`, so an empty stdout — which a spent
# budget, a floor refusal and an auth error all produce — skipped the veto and bound a SIGNED `clean`
# to a head nobody had looked at. A failed READ must be its own answer, and it fails CLOSED.
rm -f "$(Q2 424516)"
STUB_CHECKS_FAIL=1 run_record_diff 424516 "$STALE" "body

$(prior_for 424516)" "$D_F"
[ "$RECORD_RC" = "3" ] && ok "11.3e2 an UNREADABLE target surface refuses the carry (rc 3)" || bad "11.3e2 carried onto a head whose surface was never read! (rc=$RECORD_RC)"
assert_contains "$RECORD_ERR" "COULD NOT BE READ" "11.3e2 names the unread surface (not 'not red')"
[ ! -f "$(Q2 424516)" ] && ok "11.3e2 no record written for an unread surface" || bad "11.3e2 wrote a record onto an unread surface"
if grep -qF "TARGET HEAD IS MEASURABLY RED" <<<"$RECORD_ERR"; then bad "11.3e2 claimed a RED head it never read"; else ok "11.3e2 does not claim a red head it never read"; fi

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
#  (2) The env-prefix assignments: `VAR=val func` is NOT a leak — a prefix
#      assignment before a FUNCTION call is restored when the call returns, and a
#      PLAIN assignment inside the callee is discarded too (measured on bash
#      5.2.21: `g(){ W=inside; }; W=pre; W=pfx g` → W=pre; prev-unset → unset;
#      `k(){ :; }` → restored either way). What DEFEATS the restore is the callee
#      EXPORTING that variable, whatever its previous value:
#      `h(){ export W=inside; }; W=pre; W=pfx h` → W=inside (prev-unset → inside
#      too), and even a bare `export W` leaves the TEMPORARY value behind
#      (`j(){ export W; }; W=pre; W=pfx j` → W=pfx). Special builtins OTHER than
#      `export` keep the value only under `set -o posix`, which this suite does
#      not use (`C=pre; C=pfx :` → C=pre here, C=pfx under --posix) — but `export`
#      IS a special builtin and keeps it in BOTH modes (`A=pre; A=pfx export A`
#      → A=pfx either way), so a top-level `VAR=… export VAR` idiom is not safe
#      here on posix-mode grounds.
#      That export case is exactly why every runner here does its `export`s
#      INSIDE its own `( … )` subshell: nothing a runner exports can escape the
#      call (measured: after a `run_record_diff_with` the four variables come back
#      unset, or at their pre-set value). NOTE: an earlier revision of this note
#      restricted the exception to the previously-UNSET case — a probe with the
#      callee exporting a DIFFERENT variable appeared to confirm it. That was a
#      buggy probe; the sentence you are reading is the measured one.
#      The carriers that survive a call are the TOP-LEVEL exports: `export
#      STUB_LABELS_DIR` / `export STUB_LABELS` in §8.9 / §8.9a / §8.9b / §8.14 /
#      §8.15 (the five blocks that install a per-issue label map). Each unsets its
#      own after use; the line below is DEFENSIVE for a future block that returns
#      early, and it now names them so the belt is real rather than claimed
#      (measured: the line is removable today without changing the suite — that is
#      what "defensive" means here, not that it is unnecessary).
#      §8.16's `run_micro_verdict` relies on the RESTORE half of the same
#      semantics — `STUB_FILES="${STUB_FILES-$MICRO_SURFACE}"` must not leak a
#      surface into the next vector — and this note documented that behaviour
#      backwards until a review measured it (#2615).
unset STUB_FILES STUB_DIFF_FILE GH_STUB_PATCH_BODY STUB_HEAD_SHA STUB_LABELS_DIR STUB_LABELS P2 MB

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
# 11.13 #1351 — `--check-carry`: THE LANE'S QUESTION, answered by the gate's own
#      predicate ("my record's head is stale; is the diff I reviewed still the
#      diff that would merge?").
# ─────────────────────────────────────────────────────────────────────────
# WHY THIS EXISTS. The local merge gate carries a record across a base move when
# the recorded `diff_sha256` equals the PR's live normalized three-dot diff. No
# surface TOLD a lane that, so lanes inferred "the branch moved, therefore the
# review is stale" and paid for a fresh 20-40 minute review after every base
# move — while the content was byte-identical. This mode is the ONE way to ask,
# and it adds NO second definition of "unchanged": it reuses the same
# `diff_hash_for_pr` the record path and the GitHub gate share, and the gate's
# own identity rule (full lowercase 64-hex, never the empty-body constant).
#
# The negatives carry the weight: a MISSING record, a missing digest, a CHANGED
# diff and an UNREADABLE diff must each be distinguishable from a carry, because
# every one of them has a different remedy — and "could not read" must never be
# reported as "unchanged" (that is the fail-open this whole design forbids).
echo "── 11.13 #1351: --check-carry (the lane's carry question) ────────"
CC_REPO="daniel-ospina/agent-infra"
CC_RDIR="$F_HOME/.pi/agent/reviews"
mkdir -p "$CC_RDIR"
CC_TAB="$(printf '\t')"
CC_HEAD="$(printf 'a%.0s' $(seq 1 40))"     # the stub's .head.sha
CC_STALE="$(printf 'd%.0s' $(seq 1 40))"
# SELF-CONTAINED fixtures: §11.12's are unset above, and a section that leaned on
# them would abort under `set -u` (or, worse, silently compare against a digest
# some other section computed with different bytes).
CC_DIFF="$T/cc-real.diff"
printf 'diff --git a/docs/cc.md b/docs/cc.md\nindex 1111111..2222222 100644\n--- a/docs/cc.md\n+++ b/docs/cc.md\n@@ -1,3 +1,4 @@\n a\n+b\n c\n d\n' > "$CC_DIFF"
# The digest is computed with the ONE shared normalizer (scripts/lib/diff-normalize.py)
# — the same primitive the producer and the GitHub gate use. A local second
# implementation here would let the fixture agree with itself and disagree with
# production, which is the drift the single-implementation rule forbids.
CC_SHA="$(python3 "$SCRIPT_DIR/lib/diff-normalize.py" < "$CC_DIFF" | openssl dgst -sha256 | awk '{print $NF}')"
CC_DIFF_B="$(printf '2%.0s' $(seq 1 64))"
CC_NONDIFF="$T/cc-nondiff.json"
printf '%s' '{"message":"Not Found","documentation_url":"https://docs.github.com/rest","status":"404"}' > "$CC_NONDIFF"
CC_CAP406="$T/cc-cap-406.json"
printf '%s' '{"message":"Sorry, the diff exceeded the maximum number of files (300).","errors":[{"resource":"PullRequest","field":"diff","code":"too_large"}],"documentation_url":"https://docs.github.com/rest/pulls/pulls","status":"406"}' > "$CC_CAP406"
CC_FILE="$CC_RDIR/daniel-ospina-agent-infra"
cc_rec() { # <pr> <head> <diff-or-EMPTY>
    if [ "$3" = "EMPTY" ]; then
        printf '{"pr":%s,"head_sha":"%s","verdict":"clean","mint":"fresh","repo":"%s","reviewed_at":"2026-10-20T00:00:00Z"}\n' "$1" "$2" "$CC_REPO" > "$CC_FILE-$1.json"
    else
        printf '{"pr":%s,"head_sha":"%s","diff_sha256":"%s","verdict":"clean","mint":"fresh","repo":"%s","reviewed_at":"2026-10-20T00:00:00Z"}\n' "$1" "$2" "$3" "$CC_REPO" > "$CC_FILE-$1.json"
    fi
}
run_check_carry() { # <pr> <repo> [script] -> CC_OUT / CC_RC
    local sh="${3:-$RECORD}"
    # ⛔ CC_RC IS RESET *AND* CAPTURED WITH `||`. A bare `CC_OUT=$(…)` assignment
    # inherits the command's exit status, so under this harness's `set -e` the
    # FIRST non-zero verdict (a `fresh`, an `unreadable`, a `norecord` — i.e.
    # every answer this section exists to assert) would abort the whole suite and
    # the missing summary would be attributed to the next section. The `||` keeps
    # the compound list's status 0 while still recording the real code.
    CC_RC=0
    # GH_REPO="" (not merely unset): the script falls back to it when no repo is
    # passed, and this suite must answer from what the FIXTURE says, not from the
    # ambient shell a developer happens to have exported.
    CC_OUT="$(HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG" GH_REPO="" \
        STUB_DIFF_FILE="${STUB_DIFF_FILE:-$CC_DIFF}" STUB_DIFF_FAIL="${STUB_DIFF_FAIL:-0}" \
        STUB_DIFF_406_FILE="${STUB_DIFF_406_FILE:-}" \
        STUB_LOCAL_BASE="${STUB_LOCAL_BASE:-}" STUB_LOCAL_HEAD="${STUB_LOCAL_HEAD:-}" \
        STUB_HEAD_SHA="${STUB_HEAD_SHA:-$CC_HEAD}" \
        RECORD_REVIEW_LOCAL_REPO="${RECORD_REVIEW_LOCAL_REPO:-.}" \
        bash "$sh" --check-carry "$1" "$2" 2>"$T/cc-err")" || CC_RC=$?
}

# (a) a record bound to the CURRENT head is valid with NO digest at all — and it
#     must report `head`, not `carry`: "nothing is stale" and "the content is
#     identical" are different statements, and only one of them is true here.
cc_rec 424901 "$CC_HEAD" EMPTY
run_check_carry 424901 "$CC_REPO"
assert_eq "$CC_RC" "0" "11.13a a record at the current head is accepted (exit 0)"
assert_eq "${CC_OUT%%"$CC_TAB"*}" "head" "11.13a …and reports 'head', not 'carry'"

# (b) THE CARRY: base-only move, diff unchanged. This is the answer that saves the
#     lane a whole review cycle.
cc_rec 424902 "$CC_STALE" "$CC_SHA"
run_check_carry 424902 "$CC_REPO"
assert_eq "$CC_RC" "0" "11.13b a stale head with an UNCHANGED diff is a carry (exit 0)"
assert_eq "$CC_OUT" "carry${CC_TAB}${CC_SHA}${CC_TAB}${CC_SHA}" "11.13b …and prints both digests, so the claim is checkable"
assert_contains "$(cat "$T/cc-err")" "Do NOT re-review" "11.13b …and says the one thing a lane needs to hear"

# (c) the DIFF CHANGED → a fresh review IS owed. Distinct exit code, distinct advice.
cc_rec 424903 "$CC_STALE" "$CC_DIFF_B"
run_check_carry 424903 "$CC_REPO"
assert_eq "$CC_RC" "1" "11.13c a CHANGED diff is NOT a carry (exit 1)"
assert_eq "${CC_OUT%%"$CC_TAB"*}" "fresh" "11.13c …and reports 'fresh'"
assert_contains "$(cat "$T/cc-err")" "the DIFF CHANGED" "11.13c …and names the finding, not a read failure"

# (d) AN UNREADABLE DIFF IS NEVER A CARRY — checked for every non-ok status the
#     seam can emit. This is the fail-open the design forbids: "we could not read
#     it" must not become "it is unchanged".
cc_rec 424904 "$CC_STALE" "$CC_SHA"
for cc_status in empty nondiff too_large unavailable; do
    case "$cc_status" in
        empty) STUB_DIFF_FILE=/dev/null STUB_DIFF_FAIL=0 run_check_carry 424904 "$CC_REPO" ;;
        nondiff) STUB_DIFF_FILE="$CC_NONDIFF" STUB_DIFF_FAIL=0 run_check_carry 424904 "$CC_REPO" ;;
        too_large) STUB_DIFF_406_FILE="$CC_CAP406" RECORD_REVIEW_LOCAL_REPO="$T/no-such-checkout-1398" run_check_carry 424904 "$CC_REPO" ;;
        unavailable) STUB_DIFF_FAIL=1 run_check_carry 424904 "$CC_REPO" ;;
    esac
    if [ "$CC_RC" = "0" ]; then bad "11.13d an unreadable diff ($cc_status) was reported as a carry (exit 0)";
    else ok "11.13d an unreadable diff ($cc_status) is refused (exit $CC_RC), never a carry"; fi
    assert_eq "${CC_OUT%%"$CC_TAB"*}" "unreadable" "11.13d …reported as 'unreadable', not 'fresh' (different remedy)"
    assert_eq "$(printf '%s' "$CC_OUT" | cut -f3)" "$cc_status" "11.13d …and names the seam status ($cc_status)"
done
unset STUB_DIFF_FILE STUB_DIFF_FAIL STUB_DIFF_406_FILE STUB_LOCAL_BASE STUB_LOCAL_HEAD RECORD_REVIEW_LOCAL_REPO

# (e) no record at all → nothing to carry, and it says so rather than guessing.
rm -f "$CC_FILE-424905.json" "$CC_RDIR/424905.json"
run_check_carry 424905 "$CC_REPO"
assert_eq "$CC_RC" "4" "11.13e no record → exit 4 (nothing to carry)"
assert_eq "${CC_OUT%%"$CC_TAB"*}" "norecord" "11.13e …reports 'norecord'"

# (f) a legacy/degraded record (NO diff_sha256) beside a stale head → `nodigest`,
#     whose remedy is the RECORDER's own carry arm (a carry, not a review). It
#     must not be reported as `fresh` — that is the 20-40 minute mistake.
cc_rec 424906 "$CC_STALE" EMPTY
run_check_carry 424906 "$CC_REPO"
assert_eq "$CC_RC" "5" "11.13f a record with no usable digest → exit 5 (nodigest)"
assert_eq "${CC_OUT%%"$CC_TAB"*}" "nodigest" "11.13f …reports 'nodigest', not 'fresh'"
assert_contains "$(cat "$T/cc-err")" "that is a CARRY, not a fresh review" "11.13f …and points at the recorder's carry arms"

# (g) #426: a legacy <pr>.json naming ANOTHER repo is not this PR's record.
rm -f "$CC_FILE-424907.json"
printf '{"pr":424907,"head_sha":"%s","verdict":"clean","repo":"someone-else/other"}\n' "$CC_STALE" > "$CC_RDIR/424907.json"
run_check_carry 424907 "$CC_REPO"
assert_eq "$CC_RC" "4" "11.13g another repo's legacy record is not read (exit 4)"
rm -f "$CC_RDIR/424907.json"

# (g2) THE GATE'S COLLISION RULE, APPLIED TO THE QUALIFIED FILE TOO (review, #2353 P1).
# The merge gate treats a qualified record whose embedded `repo` names ANOTHER repo as
# ABSENT (the identical-slug overwrite class). A surface that reported `carry … land it`
# for it would be a second definition of "the record" — the exact divergence this mode
# exists to prevent.
printf '{"pr":424909,"head_sha":"%s","diff_sha256":"%s","verdict":"clean","repo":"someone-else/other"}\n' "$CC_STALE" "$CC_SHA" > "$CC_FILE-424909.json"
run_check_carry 424909 "$CC_REPO"
assert_eq "$CC_RC" "4" "11.13g2 a qualified record naming ANOTHER repo is not read (exit 4)"
assert_eq "${CC_OUT%%"$CC_TAB"*}" "norecord" "11.13g2 …reports 'norecord', like the gate"
rm -f "$CC_FILE-424909.json"

# (g2b) …AND THE COLLISION MUST NOT FALL THROUGH TO THE LEGACY FILE (review round 2, F3).
# The gate returns NULL on a qualified collision — it does not then look for `<pr>.json`.
# A fall-through shape answers `head`/`carry` ("land it") on the same fixtures while the
# gate blocks, which IS the round-1 P1b re-introduced. The qualified file and a matching
# legacy sibling must disagree in exactly one direction: norecord.
printf '{"pr":424912,"head_sha":"%s","diff_sha256":"%s","verdict":"clean","repo":"someone-else/other"}\n' "$CC_STALE" "$CC_SHA" > "$CC_FILE-424912.json"
printf '{"pr":424912,"head_sha":"%s","diff_sha256":"%s","verdict":"clean","repo":"%s"}\n' "$CC_STALE" "$CC_SHA" "$CC_REPO" > "$CC_RDIR/424912.json"
run_check_carry 424912 "$CC_REPO"
assert_eq "$CC_RC" "4" "11.13g2b a qualified collision does NOT fall through to the legacy sibling (exit 4)"
assert_eq "${CC_OUT%%"$CC_TAB"*}" "norecord" "11.13g2b …norecord, exactly as the gate finds no record"
rm -f "$CC_FILE-424912.json" "$CC_RDIR/424912.json"

# (g3) THE KEY IS CASE-EXACT. `repo` is compared as a string by the gate, and the record
# path is derived from the spelling the writer was handed; folding case here would make
# this mode accept a key the gate never looks up.
printf '{"pr":424910,"head_sha":"%s","diff_sha256":"%s","verdict":"clean","repo":"Daniel-Ospina/agent-infra"}\n' "$CC_STALE" "$CC_SHA" > "$CC_FILE-424910.json"
run_check_carry 424910 "$CC_REPO"
assert_eq "$CC_RC" "4" "11.13g3 a differently-CASED repo is a different key (exit 4)"
rm -f "$CC_FILE-424910.json"

# (g4) NO REPO IS A DIFFERENT RULE, NOT A DEGENERATE ONE (review, #2353 P2).
# With no repo context the gate cannot derive a qualified name, so it trusts a key that
# PROVES its repo: one uniquely-matching <owner>-<repo>-<pr>.json. This mode looked only
# at <pr>.json, so in the exact state it exists for — repo auto-detection failing under a
# contested gh gate — it said "no record … run the review" about a record the gate reads.
# The record IS found here (so NOT `norecord`); what fails is the diff READ, which needs a
# repo — and a failed read is `unreadable`, never `norecord` and never a carry.
cc_rec 424913 "$CC_STALE" "$CC_SHA"
run_check_carry 424913 ""
assert_eq "$CC_RC" "3" "11.13g4 with no repo, a UNIQUE qualified record is FOUND (exit 3 = the read failed, not 'no record')"
assert_eq "${CC_OUT%%"$CC_TAB"*}" "unreadable" "11.13g4 …reports 'unreadable', not 'norecord'"
rm -f "$CC_FILE-424913.json"

# (g5) …while an AMBIGUOUS lookup is genuinely no record: two repos claim #PR, and the
# gate treats that as absent (it cannot tell which is yours). The remedy must name the
# missing repo, not "run the review".
cc_rec 424914 "$CC_STALE" "$CC_SHA"
printf '{"pr":424914,"head_sha":"%s","diff_sha256":"%s","verdict":"clean","repo":"someone-else/other"}\n' "$CC_STALE" "$CC_SHA" > "$CC_RDIR/someone-else-other-424914.json"
run_check_carry 424914 ""
assert_eq "$CC_RC" "4" "11.13g5 with no repo, TWO qualified records are ambiguous (exit 4)"
assert_eq "${CC_OUT%%"$CC_TAB"*}" "norecord" "11.13g5 …reports 'norecord'"
assert_contains "$(cat "$T/cc-err")" "pass owner/repo" "11.13g5 …and names the actual remedy (a repo), not a re-review"
rm -f "$CC_FILE-424914.json" "$CC_RDIR/someone-else-other-424914.json"

# (g6) …and a legacy record that EMBEDS a repo is rejected with no repo context (#426
# review P0-2): it may be another repo's PR with this number.
printf '{"pr":424915,"head_sha":"%s","diff_sha256":"%s","verdict":"clean","repo":"%s"}\n' "$CC_STALE" "$CC_SHA" "$CC_REPO" > "$CC_RDIR/424915.json"
run_check_carry 424915 ""
assert_eq "$CC_RC" "4" "11.13g6 with no repo, a repo-EMBEDDING legacy record is not trusted (exit 4)"
rm -f "$CC_RDIR/424915.json"

# (g7) THE POSITIVE LEGACY DIRECTION (review, #2353 round 3 note). With a repo resolved
# and NO qualified file, a legacy <pr>.json naming THIS repo IS the record — the #426
# migration fallback. Unpinned, the `elif` could be narrowed away and every pre-#426 lane
# would be told there is no record.
printf '{"pr":424916,"head_sha":"%s","diff_sha256":"%s","verdict":"clean","repo":"%s"}\n' "$CC_STALE" "$CC_SHA" "$CC_REPO" > "$CC_RDIR/424916.json"
run_check_carry 424916 "$CC_REPO"
assert_eq "$CC_RC" "0" "11.13g7 with a repo, the legacy record naming this repo is READ (exit 0)"
assert_eq "${CC_OUT%%"$CC_TAB"*}" "carry" "11.13g7 …and carries on the matching digest"
rm -f "$CC_RDIR/424916.json"

# (f2) `nodigest` NEEDS NO READ, so it must be decided BEFORE the diff read (review,
# #2353 P2). With a digest-less record AND an unreadable diff, the answer is the one
# that unsticks the lane (re-run the recorder's carry arms), not an endless RETRY.
cc_rec 424911 "$CC_STALE" EMPTY
STUB_DIFF_FAIL=1 run_check_carry 424911 "$CC_REPO"
assert_eq "$CC_RC" "5" "11.13f2 a digest-less record answers nodigest even when the diff cannot be read"
assert_eq "${CC_OUT%%"$CC_TAB"*}" "nodigest" "11.13f2 …not 'unreadable' (a RETRY loop that cannot converge)"

# (f3) THE `nodigest` REMEDY MUST BE RUNNABLE IN THE STATE IT FIRES IN (review, #2353
# round 4). It used to end `… $REPO`, which with REPO empty is an EMPTY SLOT: the advised
# command is refused by the recorder's own carry arms (they must compute the diff, which
# needs a repo), names "run the review" — the 20-40 minute path this mode exists to avoid
# — and re-running --check-carry answers `nodigest` again. A remedy that cannot converge
# is not a remedy; with no repo it must name what is missing instead.
cc_rec 424917 "$CC_STALE" EMPTY
run_check_carry 424917 ""
assert_eq "$CC_RC" "5" "11.13f3 no repo + digest-less record → still 'nodigest' (exit 5), not a carry"
assert_contains "$(cat "$T/cc-err")" "owner/repo" "11.13f3 …and the remedy NAMES the missing repo instead of printing an empty slot"
assert_contains "$(cat "$T/cc-err")" "NO repo was resolved here" "11.13f3 …stating that the carry arms cannot verify identity without it"
rm -f "$CC_FILE-424917.json"

# (h) READ-ONLY means read-only: a record-minting flag is REFUSED, not ignored —
#     otherwise a caller believes it recorded something it did not.
CC_RC=0
CC_OUT="$(HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG" bash "$RECORD" --check-carry 424902 "$CC_REPO" --evidence comment:1 2>/dev/null)" || CC_RC=$?
assert_eq "$CC_RC" "2" "11.13h --evidence is refused in --check-carry (exit 2)"
assert_eq "$CC_OUT" "" "11.13h …and prints no verdict (it did not answer)"

# (i) NO REPO → the diff CANNOT be read (the read is keyed on the repo), so the mode
#     must FAIL CLOSED: `unreadable`, exit 3 — never a carry, even with a record present.
#     A verdict that claims "unchanged" without having read the diff is exactly the
#     fail-open this design forbids.
printf '{"pr":424908,"head_sha":"%s","diff_sha256":"%s","verdict":"clean","mint":"fresh"}\n' "$CC_STALE" "$CC_SHA" > "$CC_RDIR/424908.json"
run_check_carry 424908 ""
assert_eq "$CC_RC" "3" "11.13i with no repo the mode fails CLOSED (exit 3, never a carry)"
assert_eq "${CC_OUT%%"$CC_TAB"*}" "unreadable" "11.13i …reports 'unreadable', not 'carry'"
rm -f "$CC_RDIR/424908.json"

# (j) MUTATION PIN — the comparison itself must be load-bearing. A real copy of
#     the script with the equality replaced by "always equal" must report the
#     CHANGED-diff case (11.13c) as a CARRY; if it does not, 11.13c proves nothing.
CC_MUT="$T/record-review-cc-mutant.sh"
cp "$RECORD" "$CC_MUT"
if grep -qF 'if [ "$CC_DIFF" = "$DIFF_HASH" ]; then' "$CC_MUT"; then
    # The anchor allows LEADING WHITESPACE: the comparison sits inside the
    # `if [ "$CHECK_CARRY" -eq 1 ]` block, so `^if` would never match and the
    # mutant would silently stay an exact copy of the script — a mutation pin
    # pinned to a line that never changes proves nothing.
    sed -i.bak 's/^[[:space:]]*if \[ "\$CC_DIFF" = "\$DIFF_HASH" \]; then$/  if [ -n "$DIFF_HASH" ]; then/' "$CC_MUT"
    rm -f "$CC_MUT.bak"
    if cmp -s "$RECORD" "$CC_MUT"; then
        bad "11.13j the mutant is byte-identical to the script — the sed did not apply (re-anchor it)"
    fi
    run_check_carry 424903 "$CC_REPO" "$CC_MUT"
    if [ "$CC_RC" = "0" ] && [ "${CC_OUT%%"$CC_TAB"*}" = "carry" ]; then
        ok "11.13j mutation CAUGHT: with the digest comparison removed the CHANGED-diff case IS reported as a carry — so 11.13c is load-bearing"
    else
        bad "11.13j mutation NOT caught (rc=$CC_RC, out=$CC_OUT) — 11.13c cannot fail, so it proves nothing"
    fi
else
    bad "11.13j the mutation anchor 'if [ \"\\\$CC_DIFF\" = \"\\\$DIFF_HASH\" ]; then' is gone — re-anchor the mutant rather than dropping the pin"
fi
unset CC_OUT CC_RC CC_REPO CC_RDIR CC_HEAD CC_STALE CC_DIFF CC_DIFF_B CC_SHA CC_FILE CC_MUT CC_TAB CC_NONDIFF CC_CAP406


# ─────────────────────────────────────────────────────────────────────────
# 11.14 #2872 — `--recover-body`: rebuild a MISSING record from the PR body's
#       SIGNED marker.
# ─────────────────────────────────────────────────────────────────────────
# WHY THIS EXISTS. The record file is PER BOX; the signed marker in the PR body
# is the only copy of the verdict that TRAVELS with the PR. Measured 2026-10-26:
# of 45 open PRs, 12 carried a marker whose `diff=` equalled the PR's live diff
# with no record file on the merging box, and the registry covered 2 of them —
# so 10 lanes were being told to run a second 20-40 minute review for a verdict
# the fleet already held, with the proof sitting in the body.
#
# ⛔ THE NEGATIVES CARRY THE DESIGN. A body is attacker-writable, so the ONLY
# thing that makes a marker evidence is its HMAC. Each refusal below is a
# different way to present a marker that is not evidence (forged, tampered,
# unsigned, foreign repo, unreadable, an existing record that must not be
# replaced), because each has a different remedy and none of them may mint.
# §11.14k is the mutation pin: with the HMAC comparison removed, the forged
# vector must SUCCEED — which is what proves the vector above tests the check
# rather than the shape.
echo "── 11.14 #2872: --recover-body (rebuild a record from the signed marker) ────────"
RB_REPO="daniel-ospina/agent-infra"
RB_RDIR="$F_HOME/.pi/agent/reviews"
mkdir -p "$RB_RDIR"
RB_TAB="$(printf '\t')"
RB_HEAD="$(printf 'c%.0s' $(seq 1 40))"
RB_DIFF="$(printf '9%.0s' $(seq 1 64))"
RB_MINT_AT="2026-01-01T00:00:00Z"   # the STUB's commits/ answer (STUB_COMMIT_DATE)
rb_marker() { # <pr> <text-without-sig>
    printf '%s sig=%s' "$2" "$(printf '%s' "$2" | openssl dgst -sha256 -hmac "$TEST_GATE_KEY" | awk '{print $NF}')"
}
rb_clear() { rm -f "$RB_RDIR"/*.json; }
run_recover() { # <pr> <repo> [script] -> RB_OUT / RB_RC
    local sh="${3:-$RECORD}"
    RB_RC=0
    RB_OUT="$(HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG" GH_REPO="" \
        bash "$sh" --recover-body "$1" "$2" 2>"$T/rb-err")" || RB_RC=$?
}

# (a) THE RECOVERY: a record file is absent, the body carries a valid signed
#     marker → the record is rebuilt, with the marker's own head/diff/verdict.
rb_clear
export STUB_BODY="Some PR description.

$(rb_marker 424911 "review recorded: reviews/424911.json verdict=clean @ $RB_HEAD diff=$RB_DIFF ($RB_REPO)")"
run_recover 424911 "$RB_REPO"
assert_eq "$RB_RC" "0" "11.14a a verified marker rebuilds the missing record (exit 0)"
assert_eq "$RB_OUT" "recovered${RB_TAB}${RB_HEAD}${RB_TAB}${RB_DIFF}" "11.14a …and prints the restored head + digest, so the claim is checkable"
RB_REC="$RB_RDIR/daniel-ospina-agent-infra-424911.json"
if [ -f "$RB_REC" ]; then ok "11.14a the record file is written at the repo-qualified path"; else bad "11.14a no record file at daniel-ospina-agent-infra-424911.json"; fi
assert_contains "$(cat "$RB_REC" 2>/dev/null)" "\"head_sha\":\"$RB_HEAD\"" "11.14a …bound to the marker's head"
assert_contains "$(cat "$RB_REC" 2>/dev/null)" "\"diff_sha256\":\"$RB_DIFF\"" "11.14a …carrying the marker's reviewed diff"
assert_contains "$(cat "$RB_REC" 2>/dev/null)" '"mint":"recovered-body"' "11.14a …marking PROVENANCE: it is recovered, not a fresh mint"
assert_contains "$(cat "$RB_REC" 2>/dev/null)" '"repo":"daniel-ospina/agent-infra"' "11.14a …namespaced to the repo it was verified for"
# ⛔ reviewed_at is a LOWER BOUND, not the mint time: this box never observed the
# mint, so the record carries the head commit's committer date and says so
# (`mint=recovered-body`, `recovered_at`). What must never happen is stamping a
# time the review did not happen — `now` is tortoise#7391.
assert_contains "$(cat "$RB_REC" 2>/dev/null)" "\"reviewed_at\":\"$RB_MINT_AT\"" "11.14a reviewed_at is the head COMMIT's date, a LOWER BOUND, not the recovery time"
assert_contains "$(cat "$T/rb-err")" "LOWER BOUND" "11.14a …and the report says so, rather than implying it is the mint time"
assert_contains "$(cat "$T/rb-err")" "did not observe the mint" "11.14a …naming what this box could not observe"
assert_contains "$(cat "$RB_REC" 2>/dev/null)" '"recovered_at":"' "11.14a …and the restoration time is recorded separately"
assert_contains "$(cat "$T/rb-err")" "does not certify" "11.14a …and says it restores a verdict without certifying one"

# (b) A FORGED signature is not evidence. `sig=<64 zeros>` satisfies the SHAPE
#     the old carry-forward arm accepted; it must not survive the HMAC check.
rb_clear
RB_TEXT_B="review recorded: reviews/424912.json verdict=clean @ $RB_HEAD diff=$RB_DIFF ($RB_REPO)"
export STUB_BODY="$RB_TEXT_B sig=$(printf '0%.0s' $(seq 1 64))"
run_recover 424912 "$RB_REPO"
assert_eq "$RB_RC" "3" "11.14b a forged sig=<64 zeros> is REFUSED (exit 3)"
if [ -f "$RB_RDIR/daniel-ospina-agent-infra-424912.json" ]; then bad "11.14b a forged marker minted a record"; else ok "11.14b …and nothing is written"; fi
assert_contains "$(cat "$T/rb-err")" "does not verify" "11.14b …and names the signature as the reason"

# (c) TAMPERED TEXT: a genuine signature over a DIFFERENT head. The sig is well
#     formed and 64-hex; only the HMAC over THIS text exposes it.
rb_clear
RB_OTHER_HEAD="$(printf 'e%.0s' $(seq 1 40))"
RB_GENUINE="$(rb_marker 424913 "review recorded: reviews/424913.json verdict=clean @ $RB_OTHER_HEAD diff=$RB_DIFF ($RB_REPO)")"
# re-present that GENUINE signature over text that names a DIFFERENT head
export STUB_BODY="review recorded: reviews/424913.json verdict=clean @ $RB_HEAD diff=$RB_DIFF ($RB_REPO) sig=${RB_GENUINE##* sig=}"
run_recover 424913 "$RB_REPO"
assert_eq "$RB_RC" "3" "11.14c a marker whose sig covers DIFFERENT text is refused (exit 3)"
if [ -f "$RB_RDIR/daniel-ospina-agent-infra-424913.json" ]; then bad "11.14c a tampered marker minted a record"; else ok "11.14c …and nothing is written"; fi

# (d) UNSIGNED: the poster warns and posts unsigned when the key is missing. An
#     unsigned marker is a body edit by definition — there is nothing to verify.
rb_clear
export STUB_BODY="review recorded: reviews/424914.json verdict=clean @ $RB_HEAD diff=$RB_DIFF ($RB_REPO)"
run_recover 424914 "$RB_REPO"
assert_eq "$RB_RC" "3" "11.14d an UNSIGNED marker is refused (exit 3)"
assert_contains "$(cat "$T/rb-err")" "body EDIT" "11.14d …and says why an unverified marker is not evidence"

# (e) FOREIGN REPO: PR numbers collide across repos, which is why the record is
#     repo-qualified. A signed marker naming another repo must not be adopted.
rb_clear
export STUB_BODY="$(rb_marker 424915 "review recorded: reviews/424915.json verdict=clean @ $RB_HEAD diff=$RB_DIFF (daniel-ospina/tortoise)")"
run_recover 424915 "$RB_REPO"
assert_eq "$RB_RC" "3" "11.14e a marker signed for ANOTHER repo is refused (exit 3)"
assert_contains "$(cat "$T/rb-err")" "DIFFERENT repo" "11.14e …and names the collision, not a signature failure"
if [ -f "$RB_RDIR/daniel-ospina-agent-infra-424915.json" ]; then bad "11.14e a foreign marker minted a record"; else ok "11.14e …and nothing is written"; fi

# (f) NO MARKER AT ALL: distinct from every refusal above, because the remedy is
#     genuinely "run the review" — there is no verdict anywhere.
rb_clear
export STUB_BODY="A PR body with no marker in it."
run_recover 424916 "$RB_REPO"
assert_eq "$RB_RC" "3" "11.14f a body with no marker is refused (exit 3)"
# ⛔ The message must NOT claim no review happened anywhere: the evidence post is
# best-effort and a body edit removes a marker, so absence HERE is all it knows.
assert_contains "$(cat "$T/rb-err")" "not proof no review happened" "11.14f …and refuses to turn absence-in-this-body into a verdict about the review"
assert_contains "$(cat "$T/rb-err")" "registry-sync.sh pull" "11.14f …and names where a peer-box verdict may live"

# (g) AN UNREADABLE BODY IS NOT "NO MARKER". A transient API failure must RETRY,
#     and must never be reported as "the marker is absent".
rb_clear
export STUB_BODY_FAIL=1
run_recover 424917 "$RB_REPO"
unset STUB_BODY_FAIL
assert_eq "$RB_RC" "3" "11.14g an unreadable body is refused (exit 3)"
assert_contains "$(cat "$T/rb-err")" "could not READ" "11.14g …and reports the READ failure, never 'no marker'"

# (h) RECOVERY FILLS AN ABSENCE; IT NEVER REPLACES. An existing record may be
#     NEWER than the marker (a later review, an already-re-bound carry), so
#     overwriting it would walk the gate BACKWARDS.
rb_clear
RB_EXIST="$RB_RDIR/daniel-ospina-agent-infra-424918.json"
printf '%s\n' '{"pr":424918,"head_sha":"ffffffffffffffffffffffffffffffffffffffff","verdict":"clean","mint":"fresh","repo":"daniel-ospina/agent-infra","reviewed_at":"2026-02-02T00:00:00Z"}' > "$RB_EXIST"
RB_BEFORE="$(cat "$RB_EXIST")"
export STUB_BODY="$(rb_marker 424918 "review recorded: reviews/424918.json verdict=clean @ $RB_HEAD diff=$RB_DIFF ($RB_REPO)")"
run_recover 424918 "$RB_REPO"
assert_eq "$RB_RC" "5" "11.14h an existing record is not replaced (exit 5)"
assert_eq "$(cat "$RB_EXIST")" "$RB_BEFORE" "11.14h …byte-identical afterwards"

# (i) AN HONEST reviewed_at IS NOT NEGOTIABLE. If the head commit's date cannot
#     be read, refuse — stamping `now` as a mint time is the tortoise#7391 defect.
rb_clear
export STUB_BODY="$(rb_marker 424919 "review recorded: reviews/424919.json verdict=clean @ $RB_HEAD diff=$RB_DIFF ($RB_REPO)")"
export STUB_COMMIT_FAIL=1
run_recover 424919 "$RB_REPO"
unset STUB_COMMIT_FAIL
assert_eq "$RB_RC" "3" "11.14i an unreadable commit date is refused (exit 3)"
assert_contains "$(cat "$T/rb-err")" "will not stamp a time the review did not happen" "11.14i …and names the mint-time rule it will not break"
if [ -f "$RB_RDIR/daniel-ospina-agent-infra-424919.json" ]; then bad "11.14i a record was minted without an honest reviewed_at"; else ok "11.14i …and nothing is written"; fi

# (j) `--recover-body` takes no --evidence: it restores a verdict a reviewer
#     already produced, so accepting an evidence ref would let a RECOVERED
#     record claim evidence nobody read.
rb_clear
RB_RC=0
RB_OUT="$(HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG" GH_REPO="" \
    bash "$RECORD" --recover-body 424920 "$RB_REPO" --evidence comment:1 2>"$T/rb-err")" || RB_RC=$?
assert_eq "$RB_RC" "2" "11.14j --evidence is refused in --recover-body (exit 2)"
assert_contains "$(cat "$T/rb-err")" "ALREADY recorded" "11.14j …and says the verdict was already recorded"

# (k) THE MUTATION PIN. Remove the HMAC comparison and the forged vector must
#     SUCCEED — proving 11.14b tests the CHECK, not the marker's shape.
RB_MUT="$T/rb-mut.sh"
sed 's@if \[ -z "$_expect" \] || \[ "$_expect" != "$_sig" \]; then@if false; then@' "$RECORD" > "$RB_MUT"
if grep -q 'if false; then' "$RB_MUT"; then
    rb_clear
    RB_TEXT_M="review recorded: reviews/424921.json verdict=clean @ $RB_HEAD diff=$RB_DIFF ($RB_REPO)"
    export STUB_BODY="$RB_TEXT_M sig=$(printf '0%.0s' $(seq 1 64))"
    run_recover 424921 "$RB_REPO" "$RB_MUT"
    assert_eq "$RB_RC" "0" "11.14k WITHOUT the HMAC check the forged marker mints (the pin has teeth)"
else
    bad "11.14k the mutation anchor is gone — re-anchor the mutant rather than dropping the pin"
fi
unset STUB_BODY STUB_BODY_FAIL STUB_COMMIT_FAIL RB_OUT RB_RC RB_REC RB_EXIST RB_BEFORE RB_MUT

# (l) NO REPO RESOLVED: a record is identified by PR *and* repo (numbers collide
#     across repos), so an unresolvable repo is a USAGE error, not a guess.
rb_clear
export STUB_REPO_NAME=""
export STUB_BODY="$(rb_marker 424922 "review recorded: reviews/424922.json verdict=clean @ $RB_HEAD diff=$RB_DIFF ($RB_REPO)")"
RB_RC=0
RB_OUT="$(HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG" GH_REPO="" \
    bash "$RECORD" --recover-body 424922 2>"$T/rb-err")" || RB_RC=$?
unset STUB_REPO_NAME
assert_eq "$RB_RC" "2" "11.14l with no resolvable repo the verb refuses (exit 2)"
assert_contains "$(cat "$T/rb-err")" "no repo resolved" "11.14l …and names the missing argument instead of filing under a guess"

# (m) NO GATE KEY: the signature cannot be VERIFIED, and an unverified marker is a
#     body edit by definition. Minting on trust would make the whole check
#     decorative, so this is a REFUSAL even when a valid-looking marker exists.
rb_clear
export STUB_BODY="$(rb_marker 424923 "review recorded: reviews/424923.json verdict=clean @ $RB_HEAD diff=$RB_DIFF ($RB_REPO)")"
RB_RC=0
RB_OUT="$(HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG" GH_REPO="" AI_REVIEW_GATE_KEY="" \
    bash "$RECORD" --recover-body 424923 "$RB_REPO" 2>"$T/rb-err")" || RB_RC=$?
assert_eq "$RB_RC" "3" "11.14m with no gate key nothing is minted (exit 3)"
assert_contains "$(cat "$T/rb-err")" "not configured" "11.14m …and says the signature could not be verified"
if [ -f "$RB_RDIR/daniel-ospina-agent-infra-424923.json" ]; then bad "11.14m a record was minted with no key to verify against"; else ok "11.14m …and nothing is written"; fi

# (n) THE LEGACY repo-less file is a collision ONLY when it EMBEDS this repo —
#     the same rule the recorder already applies. This repo's own legacy record
#     must refuse (5); a FOREIGN one must be left BYTE-IDENTICAL and not block
#     this repo's recovery (0). Deleting another repo's record is never an option.
rb_clear
RB_LEG="$RB_RDIR/424924.json"
printf '%s\n' '{"pr":424924,"head_sha":"ffffffffffffffffffffffffffffffffffffffff","verdict":"clean","mint":"fresh","repo":"daniel-ospina/agent-infra","reviewed_at":"2026-02-02T00:00:00Z"}' > "$RB_LEG"
export STUB_BODY="$(rb_marker 424924 "review recorded: reviews/424924.json verdict=clean @ $RB_HEAD diff=$RB_DIFF ($RB_REPO)")"
run_recover 424924 "$RB_REPO"
assert_eq "$RB_RC" "5" "11.14n a legacy record naming THIS repo is not replaced (exit 5)"
if [ -f "$RB_RDIR/daniel-ospina-agent-infra-424924.json" ]; then bad "11.14n a qualified record was minted beside an existing legacy one"; else ok "11.14n …and no qualified record is minted beside it"; fi
rb_clear
printf '%s\n' '{"pr":424925,"head_sha":"ffffffffffffffffffffffffffffffffffffffff","verdict":"clean","mint":"fresh","repo":"daniel-ospina/tortoise","reviewed_at":"2026-02-02T00:00:00Z"}' > "$RB_RDIR/424925.json"
RB_FOREIGN_BEFORE="$(cat "$RB_RDIR/424925.json")"
export STUB_BODY="$(rb_marker 424925 "review recorded: reviews/424925.json verdict=clean @ $RB_HEAD diff=$RB_DIFF ($RB_REPO)")"
run_recover 424925 "$RB_REPO"
assert_eq "$RB_RC" "0" "11.14n a FOREIGN legacy record does not block this repo's recovery (exit 0)"
assert_eq "$(cat "$RB_RDIR/424925.json")" "$RB_FOREIGN_BEFORE" "11.14n …and the other repo's record is left byte-identical, never deleted"
unset STUB_BODY RB_OUT RB_RC RB_LEG RB_FOREIGN_BEFORE

# (o) LAST VERIFYING MARKER WINS. The poster APPENDS, so a second verdict for the
#     same PR replaces the first; recovering the FIRST would resurrect a verdict
#     the review itself superseded. Nothing else in §11.14 pins this choice.
rb_clear
RB_OLD_HEAD="$(printf '7%.0s' $(seq 1 40))"
RB_OLD_DIFF="$(printf '8%.0s' $(seq 1 64))"
export STUB_BODY="$(rb_marker 424926 "review recorded: reviews/424926.json verdict=clean @ $RB_OLD_HEAD diff=$RB_OLD_DIFF ($RB_REPO)")
$(rb_marker 424926 "review recorded: reviews/424926.json verdict=clean-micro @ $RB_HEAD diff=$RB_DIFF ($RB_REPO)")"
run_recover 424926 "$RB_REPO"
assert_eq "$RB_RC" "0" "11.14o two markers for one PR: recovery succeeds (exit 0)"
assert_contains "$(cat "$RB_RDIR/daniel-ospina-agent-infra-424926.json" 2>/dev/null)" "\"head_sha\":\"$RB_HEAD\"" "11.14o …restoring the LAST marker's head, not the first"
assert_contains "$(cat "$RB_RDIR/daniel-ospina-agent-infra-424926.json" 2>/dev/null)" '"verdict":"clean-micro"' "11.14o …and its verdict, not the superseded one"

# (p) THE LEGACY DIFF-LESS MARKER: a marker minted before #2982 has no `diff=`.
#     The recovered record then carries NO digest — honestly, rather than a guess —
#     and `--check-carry` answers `nodigest` (5), not `fresh` (1): "no digest to
#     compare" and "the diff changed" are different facts with different remedies.
rb_clear
export STUB_BODY="$(rb_marker 424927 "review recorded: reviews/424927.json verdict=clean @ $RB_HEAD ($RB_REPO)")"
run_recover 424927 "$RB_REPO"
assert_eq "$RB_RC" "0" "11.14p a diff-less (pre-#2982) marker still recovers (exit 0)"
assert_eq "$RB_OUT" "recovered${RB_TAB}${RB_HEAD}${RB_TAB}-" "11.14p …and prints '-' for the digest it does not have"
if grep -q 'diff_sha256' "$RB_RDIR/daniel-ospina-agent-infra-424927.json" 2>/dev/null; then bad "11.14p the record invented a diff digest"; else ok "11.14p …and the record carries NO diff_sha256 rather than a guess"; fi
# ⛔ NOT run_check_carry: §11.13's teardown UNSETS CC_DIFF, so the helper's
# `${STUB_DIFF_FILE:-$CC_DIFF}` makes the subshell die under `set -u` and the
# recorded rc becomes 1 ("fresh") for a reason that has nothing to do with the
# verb. Every input is given explicitly instead.
RB_LIVE_DIFF="$T/rb-live.diff"
printf 'diff --git a/docs/rb.md b/docs/rb.md\nindex 1111111..2222222 100644\n--- a/docs/rb.md\n+++ b/docs/rb.md\n@@ -1,3 +1,4 @@\n a\n+b\n c\n d\n' > "$RB_LIVE_DIFF"
RB_CC_RC=0
RB_CC_OUT="$(HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG" GH_REPO="" \
    STUB_DIFF_FILE="$RB_LIVE_DIFF" STUB_DIFF_FAIL=0 STUB_HEAD_SHA="$(printf 'a%.0s' $(seq 1 40))" \
    RECORD_REVIEW_LOCAL_REPO="$T/no-local-checkout-2872" \
    bash "$RECORD" --check-carry 424927 "$RB_REPO" 2>"$T/rb-err")" || RB_CC_RC=$?
assert_eq "$RB_CC_RC" "5" "11.14p …so --check-carry answers nodigest (5), never 'fresh' (1)"
assert_eq "${RB_CC_OUT%%"$RB_TAB"*}" "nodigest" "11.14p …and the verdict WORD says nodigest, so a caller branches on the right remedy"

# (q) A `clean-low` MARKER IS REFUSED. That tier certifies the MERGE BASE, the
#     marker does not carry `merge_base_sha`, and a recovered record of that tier
#     would make the rail skip its base guard while the gate blocks the same
#     record as `base_unverifiable` — one record, two verdicts.
rb_clear
export STUB_BODY="$(rb_marker 424928 "review recorded: reviews/424928.json verdict=clean-low @ $RB_HEAD diff=$RB_DIFF ($RB_REPO)")"
run_recover 424928 "$RB_REPO"
assert_eq "$RB_RC" "3" "11.14q a clean-low marker is refused (exit 3)"
assert_contains "$(cat "$T/rb-err")" "FRESH mint (not a carry" "11.14q …and names the remedy that IS available, correctly labelled (a fresh mint, not a carry)"
assert_contains "$(cat "$T/rb-err")" "record-review.sh 424928" "11.14q …with the exact command to run"
if [ -f "$RB_RDIR/daniel-ospina-agent-infra-424928.json" ]; then bad "11.14q a clean-low record was minted without merge_base_sha"; else ok "11.14q …and nothing is written"; fi

# (r) ONE VERB PER INVOCATION. `--recover-body --check-carry` would print a
#     read-only answer and exit 0 having written NOTHING — a successful-looking
#     recovery that did not happen.
rb_clear
export STUB_BODY="$(rb_marker 424929 "review recorded: reviews/424929.json verdict=clean @ $RB_HEAD diff=$RB_DIFF ($RB_REPO)")"
RB_RC=0
RB_OUT="$(HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG" GH_REPO="" \
    bash "$RECORD" --recover-body 424929 "$RB_REPO" --check-carry 2>"$T/rb-err")" || RB_RC=$?
assert_eq "$RB_RC" "2" "11.14r --recover-body combined with --check-carry is refused (exit 2)"
if [ -f "$RB_RDIR/daniel-ospina-agent-infra-424929.json" ]; then bad "11.14r the combined form wrote a record anyway"; else ok "11.14r …and the refusal explains that nothing would have been written"; fi

# (s) A QUALIFIED FILE NAMING ANOTHER REPO is the identical-slug overwrite state.
#     The gate reads it as ABSENT, but it is still another repo's verdict: this
#     verb refuses rather than destroy it, and the refusal names a way out that
#     does not come back here (the loop the P2 review found was advice pointing at
#     a verb that answers `norecord` and points back).
rb_clear
printf '%s\n' '{"pr":424930,"head_sha":"ffffffffffffffffffffffffffffffffffffffff","verdict":"clean","mint":"fresh","repo":"daniel-ospina/tortoise","reviewed_at":"2026-02-02T00:00:00Z"}' > "$RB_RDIR/daniel-ospina-agent-infra-424930.json"
RB_OTHER_BEFORE="$(cat "$RB_RDIR/daniel-ospina-agent-infra-424930.json")"
export STUB_BODY="$(rb_marker 424930 "review recorded: reviews/424930.json verdict=clean @ $RB_HEAD diff=$RB_DIFF ($RB_REPO)")"
run_recover 424930 "$RB_REPO"
assert_eq "$RB_RC" "5" "11.14s a qualified file embedding ANOTHER repo is not overwritten (exit 5)"
assert_contains "$(cat "$T/rb-err")" "daniel-ospina/tortoise" "11.14s …and the refusal names the repo whose verdict is at stake"
assert_contains "$(cat "$T/rb-err")" "Move that file aside" "11.14s …and names a remedy that does not loop back to --check-carry"
assert_eq "$(cat "$RB_RDIR/daniel-ospina-agent-infra-424930.json")" "$RB_OTHER_BEFORE" "11.14s …and the file is byte-identical afterwards"
unset STUB_BODY RB_OUT RB_RC RB_OLD_HEAD RB_OLD_DIFF RB_OTHER_BEFORE

# (t) THE RACE. The absence check runs BEFORE two network reads, so a concurrent
#     recorder can mint a fresh record inside that window. Without the re-check
#     immediately before `mv`, the older recovered verdict would SILENTLY replace
#     it — the "walk the gate backwards" failure the whole rule exists to prevent.
#     The stub performs the concurrent mint as a side effect of the LAST read.
rb_clear
export STUB_BODY="$(rb_marker 424931 "review recorded: reviews/424931.json verdict=clean @ $RB_HEAD diff=$RB_DIFF ($RB_REPO)")"
RB_RACE="$RB_RDIR/daniel-ospina-agent-infra-424931.json"
RB_RACE_JSON='{"pr":424931,"head_sha":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","diff_sha256":"1111111111111111111111111111111111111111111111111111111111111111","verdict":"clean","mint":"fresh","repo":"daniel-ospina/agent-infra","reviewed_at":"2026-12-01T00:00:00Z"}'
export STUB_RACE_PATH="$RB_RACE" STUB_RACE_RECORD="$RB_RACE_JSON"
run_recover 424931 "$RB_REPO"
unset STUB_RACE_PATH STUB_RACE_RECORD
assert_eq "$RB_RC" "5" "11.14t a record minted DURING the recovery is not replaced (exit 5)"
assert_eq "$(cat "$RB_RACE" 2>/dev/null)" "$RB_RACE_JSON" "11.14t …the concurrent (newer) record survives byte-identical"
assert_contains "$(cat "$T/rb-err")" "appeared WHILE" "11.14t …and the refusal names the race rather than a plain existing record"

# (u) THE OTHER TWO VERB COMBINATIONS are refused by the same condition, above the
#     read-only dispatch (where `--print-diff-hash` would otherwise take the branch
#     first and answer for a PR whose recovery never ran).
for _combo in --print-diff-hash --print-tier; do
    rb_clear
    export STUB_BODY="$(rb_marker 424932 "review recorded: reviews/424932.json verdict=clean @ $RB_HEAD diff=$RB_DIFF ($RB_REPO)")"
    RB_RC=0
    RB_OUT="$(HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG" GH_REPO="" \
        bash "$RECORD" --recover-body 424932 "$RB_REPO" "$_combo" 2>"$T/rb-err")" || RB_RC=$?
    assert_eq "$RB_RC" "2" "11.14u --recover-body with $_combo is refused (exit 2)"
    if [ -f "$RB_RDIR/daniel-ospina-agent-infra-424932.json" ]; then bad "11.14u $_combo: the combined form wrote a record"; else ok "11.14u $_combo …and nothing is written"; fi
done
unset STUB_BODY RB_OUT RB_RC RB_RACE RB_RACE_JSON _combo

# (v) THE OTHER HALF OF THE WRITE-TIME RE-CHECK: a FOREIGN identical-slug record
#     landing during the recovery. `rb_existing_record` answers only for THIS repo,
#     so without the second arm the `mv` would destroy another repo's verdict —
#     the same class as 11.14t, which is why it is checked at the write too.
rb_clear
RB_FOREIGN_JSON='{"pr":424933,"head_sha":"dddddddddddddddddddddddddddddddddddddddd","verdict":"clean","mint":"fresh","repo":"daniel-ospina/tortoise","reviewed_at":"2026-12-01T00:00:00Z"}'
export STUB_BODY="$(rb_marker 424933 "review recorded: reviews/424933.json verdict=clean @ $RB_HEAD diff=$RB_DIFF ($RB_REPO)")"
export STUB_RACE_PATH="$RB_RDIR/daniel-ospina-agent-infra-424933.json" STUB_RACE_RECORD="$RB_FOREIGN_JSON"
run_recover 424933 "$RB_REPO"
unset STUB_RACE_PATH STUB_RACE_RECORD
export STUB_BODY="$(rb_marker 424933 "review recorded: reviews/424933.json verdict=clean @ $RB_HEAD diff=$RB_DIFF ($RB_REPO)")"
assert_eq "$RB_RC" "5" "11.14v a FOREIGN record appearing mid-recovery is not destroyed (exit 5)"
assert_eq "$(cat "$RB_RDIR/daniel-ospina-agent-infra-424933.json" 2>/dev/null)" "$RB_FOREIGN_JSON" "11.14v …the other repo's verdict survives byte-identical"

# (w) A CORRUPT RECORD IS NOT "NOTHING TO REPAIR". A truncated file parses to no
#     `repo`, which the ownership test reads as unowned — so the plain refusal
#     would assert there is nothing to fix about a file the GATE calls corrupt.
rb_clear
printf '%s' '{"pr":424934,"head_sha":"abc' > "$RB_RDIR/daniel-ospina-agent-infra-424934.json"
export STUB_BODY="$(rb_marker 424934 "review recorded: reviews/424934.json verdict=clean @ $RB_HEAD diff=$RB_DIFF ($RB_REPO)")"
run_recover 424934 "$RB_REPO"
assert_eq "$RB_RC" "5" "11.14w a corrupt record is refused (exit 5)"
assert_contains "$(cat "$T/rb-err")" "NOT a usable record" "11.14w …and it is named as unusable, not as 'nothing to repair'"
assert_contains "$(cat "$T/rb-err")" "move it aside" "11.14w …with a way out"

# (x) NO SILENT POSITIONAL DROP. `--recover-body 42 o/r clean-low <sha>` used to
#     take $2 as the repo and DISCARD the verdict and head, minting the marker's
#     verdict with exit 0 while the caller believed it had chosen one.
rb_clear
export STUB_BODY="$(rb_marker 424935 "review recorded: reviews/424935.json verdict=clean @ $RB_HEAD diff=$RB_DIFF ($RB_REPO)")"
RB_RC=0
RB_OUT="$(HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG" GH_REPO="" \
    bash "$RECORD" --recover-body 424935 "$RB_REPO" clean-low "$RB_HEAD" 2>"$T/rb-err")" || RB_RC=$?
assert_eq "$RB_RC" "2" "11.14x extra positionals with --recover-body are refused (exit 2)"
if [ -f "$RB_RDIR/daniel-ospina-agent-infra-424935.json" ]; then bad "11.14x the positional form minted a record"; else ok "11.14x …and nothing is written"; fi
unset STUB_BODY RB_OUT RB_RC RB_FOREIGN_JSON

# (y) A RECORD IS WHAT THE GATE CAN READ, NOT WHAT THIS RECORDER WROTE. A
#     pretty-printed record (a `jq .` round-trip) parses fine for the gate, so
#     calling it "NOT a usable record" and telling an operator to move it aside
#     would walk the gate BACKWARDS. It must be treated as an existing record.
rb_clear
printf '%s\n' '{' '  "pr": 424936,' '  "head_sha": "ffffffffffffffffffffffffffffffffffffffff",' '  "verdict": "clean",' '  "repo": "daniel-ospina/agent-infra",' '  "reviewed_at": "2026-02-02T00:00:00Z"' '}' > "$RB_RDIR/daniel-ospina-agent-infra-424936.json"
export STUB_BODY="$(rb_marker 424936 "review recorded: reviews/424936.json verdict=clean @ $RB_HEAD diff=$RB_DIFF ($RB_REPO)")"
run_recover 424936 "$RB_REPO"
assert_eq "$RB_RC" "5" "11.14y a pretty-printed (jq round-trip) record counts as existing (exit 5)"
assert_contains "$(cat "$T/rb-err")" "already exists" "11.14y …and is NOT called unusable, because the gate reads it fine"

# (y2) PRESENT BUT UNTYPED IS NOT A RECORD. The gate requires STRINGS, so
#      `"head_sha": null` is ABSENT to it. Treating that as an existing record
#      here would answer "nothing to repair" for a file the rail says NO-RECORD
#      about — the round-2 loop, narrowed to a present-but-untyped key.
rb_clear
printf '%s\n' '{"pr":424938,"head_sha":null,"verdict":"clean","repo":"daniel-ospina/agent-infra","reviewed_at":"2026-02-02T00:00:00Z"}' > "$RB_RDIR/daniel-ospina-agent-infra-424938.json"
export STUB_BODY="$(rb_marker 424938 "review recorded: reviews/424938.json verdict=clean @ $RB_HEAD diff=$RB_DIFF ($RB_REPO)")"
run_recover 424938 "$RB_REPO"
assert_eq "$RB_RC" "5" "11.14y2 a record with an untyped head_sha is refused (exit 5)"
assert_contains "$(cat "$T/rb-err")" "NOT a usable record" "11.14y2 …as an unusable record, matching what the gate sees (absent)"

# (z) A PERMANENT ERROR IS NOT A TRANSIENT ONE. A 404 on the PR read used to say
#     "RETRY", which a lane can obey forever.
rb_clear
export STUB_BODY_FAIL=1 STUB_BODY_FAIL_TEXT='gh: Not Found (HTTP 404)'
run_recover 424937 "$RB_REPO"
unset STUB_BODY_FAIL STUB_BODY_FAIL_TEXT
assert_eq "$RB_RC" "3" "11.14z a 404 on the PR read is refused (exit 3)"
assert_contains "$(cat "$T/rb-err")" "retrying will NOT help" "11.14z …and does not tell the lane to RETRY a permanent failure"
assert_contains "$(cat "$T/rb-err")" "Not Found" "11.14z …quoting what gh actually said"

# (aa) SHAPE PIN: the final write is a NO-CLOBBER create, not a rename. A
#      check-then-`mv` leaves a window in which a concurrent recorder's verdict is
#      replaced; `ln` fails with EEXIST instead. (A shape pin, not a race: the
#      window cannot be opened from a test.)
if grep -qF 'ln "$RB_TMP" "$RB_FILE" 2>/dev/null' "$RECORD"; then
    ok "11.14aa the write uses a no-clobber atomic create (ln), not check-then-mv"
else
    bad "11.14aa the write is not a no-clobber create — a concurrent record can still be replaced"
fi
if grep -qF 'mv "$RB_TMP" "$RB_FILE"' "$RECORD"; then
    bad "11.14aa a plain mv to the record path is still present"
else
    ok "11.14aa …and no plain mv to the record path remains"
fi
unset STUB_BODY RB_OUT RB_RC


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

# ─────────────────────────────────────────────────────────────────────────
# 12g #1377 — THE PATCH CARRY: a REBASE whose reviewed change is untouched is
# re-recorded, NOT re-reviewed; a changed patch is still refused.
#
# This is the end-to-end pin. §12a-pin territory above is BYTE-identity of the
# normalized diff; the vectors here are the case that one cannot see: the
# rendered diff MOVES (hunk context rewritten by what `main` landed) while every
# reviewed line is byte-identical. Both directions are mandatory — an acceptance
# vector alone would let a fail-open (carry anything) land green, and a refusal
# vector alone would let the arm be dead code.
#
# The fixture is three diff renderings of ONE change against three bases:
#   PFX_REVIEWED — what the review approved
#   PFX_REBASE   — the same change rebased onto a moved base: new blob ids, moved
#                  hunk line numbers, DIFFERENT CONTEXT (this is why the
#                  binding moves and #1377 exists)
#   PFX_EDIT     — the same shape with ONE changed line altered  → must REFUSE
#   PFX_WS       — whitespace only                               → must REFUSE
#   PFX_MOVED    — the same lines at a different PATH             → must REFUSE
# ─────────────────────────────────────────────────────────────────────────
PBASE="$(printf 'c%.0s' $(seq 1 40))"
POLD="$(printf 'd%.0s' $(seq 1 40))"          # the head the MARKER names
# §12's tail UNSETS its knobs (NORM_PY among them), so a section that runs after
# it must re-establish what it uses — the same self-containment §11.12 is written
# for. `norm_sha` below resolves this global at CALL time, so the re-assignment
# is what makes the helper usable here at all.
NORM_PY="$SCRIPT_DIR/lib/diff-normalize.py"
PCD="$T/pcompare"; mkdir -p "$PCD"
PFX_REVIEWED="$T/p-reviewed.diff"; printf 'diff --git a/fix.txt b/fix.txt\nindex 1111111..2222222 100644\n--- a/fix.txt\n+++ b/fix.txt\n@@ -3,4 +3,5 @@ def f():\n context before\n-old line\n+new line\n context after\n tail\n' > "$PFX_REVIEWED"
PFX_REBASE="$T/p-rebase.diff";   printf 'diff --git a/fix.txt b/fix.txt\nindex 7777777..8888888 100644\n--- a/fix.txt\n+++ b/fix.txt\n@@ -40,4 +41,5 @@ def f():\n MAIN landed a different context line\n-old line\n+new line\n another context line\n tail\n' > "$PFX_REBASE"
PFX_EDIT="$T/p-edit.diff";       printf 'diff --git a/fix.txt b/fix.txt\nindex 7777777..8888888 100644\n--- a/fix.txt\n+++ b/fix.txt\n@@ -40,4 +41,5 @@ def f():\n MAIN landed a different context line\n-old line\n+new line CHANGED\n another context line\n tail\n' > "$PFX_EDIT"
PFX_WS="$T/p-ws.diff";           printf 'diff --git a/fix.txt b/fix.txt\nindex 7777777..8888888 100644\n--- a/fix.txt\n+++ b/fix.txt\n@@ -40,4 +41,5 @@ def f():\n MAIN landed a different context line\n- old line\n+new line\n another context line\n tail\n' > "$PFX_WS"
PFX_MOVED="$T/p-moved.diff";      printf 'diff --git a/other.txt b/other.txt\nindex 7777777..8888888 100644\n--- a/other.txt\n+++ b/other.txt\n@@ -40,4 +41,5 @@ def f():\n MAIN landed a different context line\n-old line\n+new line\n another context line\n tail\n' > "$PFX_MOVED"

# The advertised premise of every vector below, stated as an assertion so it can
# never rot into a fixture that no longer tests what its caption claims.
PNORM_REVIEWED="$(norm_sha "$PFX_REVIEWED")"
assert_ne "$PNORM_REVIEWED" "$(norm_sha "$PFX_REBASE")" \
  "12g fixture: the rebase MOVES the binding (else the patch arm is never reached)"
assert_ne "$(norm_sha "$PFX_EDIT")" "$(norm_sha "$PFX_REBASE")" \
  "12g fixture: the one-line edit really is a different artifact"
assert_ne "$(norm_sha "$PFX_WS")" "$(norm_sha "$PFX_REBASE")" \
  "12g fixture: the whitespace-only edit really is a different artifact"

pcarry() { # <pr> <new-diff-file> [marker-diff] -> sets RECORD_RC/ERR/CAP £RECORD_ERR £RECORD_CAP
    local pr="$1" newf="$2" marker_diff="${3:-$PNORM_REVIEWED}"
    rm -f "$PCD/$POLD" "$PCD/$SHA"
    cp "$PFX_REVIEWED" "$PCD/$POLD"; cp "$newf" "$PCD/$SHA"
    STUB_COMPARE_DIFF_DIR="$PCD" STUB_BASE_SHA="$PBASE" \
      run_record_diff "$pr" "$POLD" "body

$(signed_marker "$pr" "$POLD" "$marker_diff")" "$newf"
}

# (g1) THE ACCEPTANCE: a pure rebase is re-recorded, with NO fresh review owed.
PRG=424740; rm -f "$(Q2 $PRG)"
pcarry "$PRG" "$PFX_REBASE"
[ "$RECORD_RC" = "0" ] && ok "12g1 a REBASE with an unchanged patch is carried (rc 0)" \
    || bad "12g1 pure rebase refused (rc=$RECORD_RC, err=$RECORD_ERR)"
assert_contains "$RECORD_ERR" "#1377 patch carry" "12g1 the carry names itself (#1377)"
assert_contains "$(cat "$(Q2 $PRG)" 2>/dev/null)" "\"head_sha\":\"$SHA\"" "12g1 re-records against the CURRENT head"
# The minted marker must bind the CURRENT head AND the LIVE digest — never the
# old pair. Inheriting either would be the head-binding hole #930 class 1.
assert_contains "$RECORD_CAP" "@ $SHA diff=$(norm_sha "$PFX_REBASE")" "12g1 the marker binds the current head to the LIVE digest"
# The posting path APPENDS (idempotent, #163), so the body keeps the old marker
# above the new one. What the merge gate must read is therefore the GOVERNING
# (last) marker — assert on that, not on the absence of the stale line, which
# would be false by construction and would look like a head-binding failure.
# The captured PATCH is the JSON envelope, so the body's newlines are the
# two-character `\n` escape — match the marker TEXT, not a line start.
PLAST="$(grep -o 'review recorded: [^"\\]*' <<<"$RECORD_CAP" | tail -1 || true)"
if grep -qF "@ $SHA diff=$(norm_sha "$PFX_REBASE")" <<<"$PLAST"; then
    ok "12g1 the GOVERNING (last) marker names the current head"
else
    bad "12g1 the governing marker does not name the current head: $PLAST"
fi
if grep -qF "@ $POLD " <<<"$PLAST"; then bad "12g1 the governing marker still names the STALE head"; else ok "12g1 the governing marker does not name the stale head"; fi

# (g2) THE REFUSAL THAT MAKES IT SOUND: one changed line ⇒ no carry.
PRG2=424741; rm -f "$(Q2 $PRG2)"
pcarry "$PRG2" "$PFX_EDIT"
[ "$RECORD_RC" = "3" ] && ok "12g2 a ONE-LINE change is NOT carried (rc 3)" \
    || bad "12g2 carried a genuinely changed patch (rc=$RECORD_RC) — FAIL-OPEN"
[ ! -f "$(Q2 $PRG2)" ] && ok "12g2 no record written for the changed patch" || bad "12g2 wrote a record for a changed patch"
if grep -qF "#1377 patch carry" <<<"$RECORD_ERR"; then bad "12g2 the carry success line was printed on a refusal"; else ok "12g2 the carry success line is not printed"; fi

# (g3) WHITESPACE-ONLY — the exact hole `git patch-id --stable` has, pinned HERE
# so a future "just use patch-id" simplification reddens instead of shipping.
PRG3=424742; rm -f "$(Q2 $PRG3)"
pcarry "$PRG3" "$PFX_WS"
[ "$RECORD_RC" = "3" ] && ok "12g3 a WHITESPACE-ONLY change is NOT carried (rc 3)" \
    || bad "12g3 carried a whitespace-only change (the patch-id --stable hole)"

# (g4) THE SAME LINES AT A DIFFERENT PATH — patch identity includes the path.
PRG4=424743; rm -f "$(Q2 $PRG4)"
pcarry "$PRG4" "$PFX_MOVED"
[ "$RECORD_RC" = "3" ] && ok "12g4 the same lines at a DIFFERENT PATH are NOT carried (rc 3)" \
    || bad "12g4 carried a change whose path moved"

# (g5) A FORGED marker (right shape, wrong signature) at a different head must
# not carry — the body is not a trust boundary (#784).
PRG5=424744; rm -f "$(Q2 $PRG5)"
cp "$PFX_REVIEWED" "$PCD/$POLD"; cp "$PFX_REBASE" "$PCD/$SHA"
FORGED="review recorded: reviews/$PRG5.json verdict=clean @ $POLD diff=$PNORM_REVIEWED (daniel-ospina/agent-infra) sig=$(printf '%064d' 0)"
STUB_COMPARE_DIFF_DIR="$PCD" STUB_BASE_SHA="$PBASE" \
  run_record_diff "$PRG5" "$POLD" "body

$FORGED" "$PFX_REBASE"
[ "$RECORD_RC" = "3" ] && ok "12g5 a FORGED prior marker does NOT patch-carry (rc 3)" \
    || bad "12g5 forged marker carried (rc=$RECORD_RC) — the body became a trust boundary"

# (g6) THE ANCHOR: a well-formed marker whose `diff=` is NOT what the reviewed
# head actually normalizes to must refuse. Without the anchor, an attacker-chosen
# sha would pair with any diff and the patch comparison would be meaningless.
PRG6=424745; rm -f "$(Q2 $PRG6)"
pcarry "$PRG6" "$PFX_REBASE" "$(printf 'e%.0s' $(seq 1 64))"
[ "$RECORD_RC" = "3" ] && ok "12g6 an unanchored marker (diff= that the reviewed head does not reproduce) refuses (rc 3)" \
    || bad "12g6 carried without the anchor — the reconstruction is not the reviewed artifact"

# ── 12h MUTATION PINS for the patch arm ───────────────────────────────────
# Each mutant is a real copy of record-review.sh with ONE line of the arm's
# logic changed, and each must redden the vector above that depends on it.
# `mut_dir` copies ONLY the script; each mutant here keeps the REAL normalizer,
# because the mechanism under mutation is the ARM's logic, not the projection.
pmut() { mut_dir "$1"; cp "$SCRIPT_DIR/lib/diff-normalize.py" "$1/lib/diff-normalize.py"; }
PMUT="$T/mut-patch"
pmut "$PMUT"
# M_NOANCHOR — delete the anchor comparison (the `on != anchor` refusal).
python3 - "$PMUT/record-review.sh" <<'PY'
import sys
p = sys.argv[1]
src = open(p, encoding="utf-8").read()
needle = '  if [ "$on" != "$anchor" ]; then command rm -f "$tmp"; return 1; fi\n'
assert needle in src, "anchor mutation needle not found — the arm changed shape"
open(p, "w", encoding="utf-8").write(src.replace(needle, '', 1))
PY
PRGm=424746; rm -f "$(Q2 $PRGm)"
cp "$PFX_REVIEWED" "$PCD/$POLD"; cp "$PFX_REBASE" "$PCD/$SHA"
STUB_COMPARE_DIFF_DIR="$PCD" STUB_BASE_SHA="$PBASE" \
  run_record_diff_with "$PMUT/record-review.sh" "$PRGm" "$POLD" "body

$(signed_marker "$PRGm" "$POLD" "$(printf 'e%.0s' $(seq 1 64))")" "$PFX_REBASE"
[ "$RECORD_RC" = "0" ] && ok "12h mutation(a): with the ANCHOR removed an unanchored marker WOULD carry (rc 0) — 12g6 is load-bearing" \
    || bad "12h mutation(a): expected a false carry without the anchor (rc=$RECORD_RC)"

# M_ALWAYS — the patch comparison always succeeds (a fail-open predicate).
PMUT2="$T/mut-patch-always"
pmut "$PMUT2"
python3 - "$PMUT2/record-review.sh" <<'PY'
import sys
p = sys.argv[1]
src = open(p, encoding="utf-8").read()
cand = [l for l in src.split('\n') if l.startswith('  [ "${pair#*$')]
assert len(cand) == 1, cand          # exactly ONE decision line, or the mutant is ambiguous
needle = cand[0] + '\n'
assert needle in src, "decision mutation needle not found"
open(p, "w", encoding="utf-8").write(src.replace(needle, '  :\n', 1))
PY
PRGm2=424747; rm -f "$(Q2 $PRGm2)"
STUB_COMPARE_DIFF_DIR="$PCD" STUB_BASE_SHA="$PBASE" \
  run_record_diff_with "$PMUT2/record-review.sh" "$PRGm2" "$POLD" "body

$(signed_marker "$PRGm2" "$POLD" "$PNORM_REVIEWED")" "$PFX_EDIT"
[ "$RECORD_RC" = "0" ] && ok "12h mutation(b): a comparison that always matches carries the ONE-LINE change (rc 0) — 12g2 is load-bearing" \
    || bad "12h mutation(b): expected a false carry under the always-match mutant (rc=$RECORD_RC)"

# M_NEVER — the arm can never fire (a no-op predicate): the acceptance reddens.
PMUT3="$T/mut-patch-never"
pmut "$PMUT3"
python3 - "$PMUT3/record-review.sh" <<'PY'
import sys
p = sys.argv[1]
src = open(p, encoding="utf-8").read()
needle = 'patch_dimension_carry() { # <reviewed-sha> <reviewed-binding-digest> <current-head> -> 0 = patch unchanged\n'
assert needle in src, "function header not found"
open(p, "w", encoding="utf-8").write(src.replace(needle, needle + '  return 1\n', 1))
PY
PRGm3=424748; rm -f "$(Q2 $PRGm3)"
STUB_COMPARE_DIFF_DIR="$PCD" STUB_BASE_SHA="$PBASE" \
  run_record_diff_with "$PMUT3/record-review.sh" "$PRGm3" "$POLD" "body

$(signed_marker "$PRGm3" "$POLD" "$PNORM_REVIEWED")" "$PFX_REBASE"
[ "$RECORD_RC" = "3" ] && ok "12h mutation(c): a patch arm that can never fire refuses the pure rebase (rc 3) — 12g1 is load-bearing" \
    || bad "12h mutation(c): the dead arm still carried (rc=$RECORD_RC)"

# ── 12i #1377 — `--check-carry` answers `carry-patch`, not `fresh` ────────
# The lane's ONE way to ask "is my stale record still good?" must not answer
# "run the review" for an unchanged PATCH — that is the 20-40 minute cost this
# issue exists to remove. The token is DELIBERATELY not `carry`: the merge gate
# does NOT carry a record whose binding moved, so a caller must re-record; and
# the exit code is not 0 for the same reason.
run_pcarry_check() { # <pr> -> CC_OUT / CC_RC (self-contained: §11.13's knobs are not reused)
    local out rc
    rc=0
    out="$(HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG" GH_REPO="" \
        STUB_DIFF_FILE="$PFX_REBASE" STUB_HEAD_SHA="$SHA" \
        STUB_COMPARE_DIFF_DIR="$PCD" STUB_BASE_SHA="$PBASE" STUB_COMPARE_DIFF_DIR="$PCD" \
        STUB_DIFF_FAIL=0 STUB_LOCAL_BASE="" STUB_LOCAL_HEAD="" RECORD_REVIEW_LOCAL_REPO=. \
        bash "$RECORD" --check-carry "$1" "daniel-ospina/agent-infra" 2>"$T/pcc-err")" || rc=$?
    CC_OUT="$out"; CC_RC="$rc"
}
prec() { # <pr> — a local record bound to the REVIEWED head with the REVIEWED digest
    printf '{"pr":%s,"head_sha":"%s","diff_sha256":"%s","verdict":"clean","mint":"fresh","repo":"daniel-ospina/agent-infra","reviewed_at":"2026-10-20T00:00:00Z"}\n' \
        "$1" "$POLD" "$PNORM_REVIEWED" > "$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-$1.json"
}
PTAB="$(printf '\t')"
PCHK=424749; prec "$PCHK"
cp "$PFX_REVIEWED" "$PCD/$POLD"; cp "$PFX_REBASE" "$PCD/$SHA"
run_pcarry_check "$PCHK"
assert_eq "${CC_OUT%%"$PTAB"*}" "carry-patch" "12i1 a rebase reports 'carry-patch' (not 'fresh', not 'carry')"
assert_eq "$CC_RC" "6" "12i1 …with its own exit code, because the gate does NOT carry it"
if [ "${CC_OUT%%"$PTAB"*}" = "carry" ]; then bad "12i1 the token is DISTINCT from 'carry'"; else ok "12i1 the token is distinct from 'carry' (the gate will not carry it as-is)"; fi
assert_contains "$(cat "$T/pcc-err" 2>/dev/null)" "do NOT run a review cycle" "12i1 the answer says what to do instead of reviewing"
# The SAME record against a changed patch must still be `fresh`.
cp "$PFX_EDIT" "$PCD/$SHA"
run_pcarry_check "$PCHK"
assert_eq "${CC_OUT%%"$PTAB"*}" "fresh" "12i2 a changed patch still reports 'fresh'"
assert_eq "$CC_RC" "1" "12i2 …exit 1 (a review really is owed)"

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

# 13h2 — A RECOVERED PREDECESSOR IS NOT A MINT TIME (#2872, round 4). A record
# minted by `--recover-body` carries reviewed_at = the head commit's date, which is
# a LOWER BOUND. Inheriting it on the next carry and printing "preserved as the
# ORIGINAL mint time" would launder a commit date into a mint time and drop the
# recovery label in the same step — the tortoise#7391 corruption this arm exists to
# prevent, with nothing else standing in the way. Both branches of the warning are
# otherwise indistinguishable to this suite.
PRV3=424744
rm -f "$(Q2 $PRV3)"
printf '%s\n' "{\"pr\":$PRV3,\"head_sha\":\"$STALE\",\"diff_sha256\":\"$EV13_H\",\"mint\":\"recovered-body\",\"recovered_at\":\"2026-01-01T00:00:00Z\",\"verdict\":\"clean\",\"repo\":\"daniel-ospina/agent-infra\",\"reviewed_at\":\"2026-01-01T00:00:00Z\"}" > "$(Q2 $PRV3)"
EV13_BODY3="body

$(signed_marker $PRV3 "$STALE" "$EV13_H")"
run_record_diff $PRV3 "$STALE" "$EV13_BODY3" "$EV13_D"
assert_eq "$RECORD_RC" "0" "13h2 a carry over a RECOVERED predecessor still records (rc 0) [err: $(printf '%s' "$RECORD_ERR" | tail -2 | tr '\n' ' ')]"
R13H2="$(cat "$(Q2 $PRV3)" 2>/dev/null || true)"
assert_contains "$R13H2" '"mint":"carried"' "13h2 it is still a carry"
if grep -q '"reviewed_at":"2026-01-01T00:00:00Z"' <<<"$R13H2"; then
  bad "13h2 the carry INHERITED the recovered record's LOWER BOUND as a mint time"
else
  ok "13h2 the recovered lower bound is NOT inherited as a mint time"
fi
assert_contains "$RECORD_ERR" "NOT inherited" "13h2 …and the warning says so, rather than 'preserved as the original mint time'"

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

  # 13n — THE PRECISION GUARD (agent-infra#1964). The loose `not...clean` arm is a substring search
  # over PROSE, and prose about a review legitimately contains the phrase mid-sentence while a review
  # of fail-closed code necessarily uses words like "failed"/"unresolved". Measured on tortoise#8866:
  # a genuine CLEAN review whose body opens `**Outcome: CLEAN**` was REFUSED (rc 3) because a later
  # sentence contained the phrase, parking a reviewed PR with a false "evidence could not be
  # verified" diagnosis. When the artifact states an explicit `Outcome:`, that field IS its claim
  # about the outcome, so the loose arm must not override it.
  rm -f "$(Q2 424747)"
  EV_REF="comment:42474701" run_record_ev 424747 STUB_EVIDENCE_BODY="### Code review

**Outcome: CLEAN — no blocking issues found.**

#### What I verified positively

**The resolver keeps its fail-closed shape.** Both refusal paths land on the pre-existing handler,
and an unresolved entity name is raised only from the recorder — this is not clean-up code, it is
the guard itself.

One test failed on origin/main and passes here."
  assert_eq "$RECORD_RC" "0" "13n an explicit Outcome: CLEAN outranks prose mentioning not-clean/failed (rc 0)"
  R13N="$(cat "$(Q2 424747)" 2>/dev/null || true)"
  assert_contains "$R13N" '"evidence":"comment:42474701"' "13n the clean artifact is what the record names"

  # 13n2 — THE EXPLOIT GUARD for 13n. Splitting the arms must NOT let a comment claim an outcome and
  # still be an ABORTED review: the structural exit markers veto unconditionally, which is what keeps
  # the tortoise#3549 hole closed.
  rm -f "$(Q2 424748)"
  EV_REF="comment:42474801" run_record_ev 424748 STUB_EVIDENCE_BODY="**Outcome: CLEAN — no blocking issues found.**

⚠️ Auto-fix stalled after 3 cycles — 2 issues require human attention"
  assert_eq "$RECORD_RC" "3" "13n2 Outcome: CLEAN does NOT override a structural abort marker (rc 3)"
  [ ! -f "$(Q2 424748)" ] && ok "13n2 no record minted from an aborted review that also claims clean" || bad "13n2 minted a record from an aborted review"

  # 13n3 — BACK-COMPAT. With NO `Outcome:` field nothing changes: the loose arm still refuses, so the
  # precision fix cannot widen the fail-open for artifacts written in the older style.
  rm -f "$(Q2 424749)"
  EV_REF="comment:42474901" run_record_ev 424749 STUB_EVIDENCE_BODY="## Review — NOT CLEAN

3 blocking issues remain."
  assert_eq "$RECORD_RC" "3" "13n3 with no Outcome field the loose NOT-CLEAN arm still refuses (rc 3)"
  [ ! -f "$(Q2 424749)" ] && ok "13n3 no record minted from a NOT-CLEAN artifact with no Outcome field" || bad "13n3 minted a record from a NOT-CLEAN artifact"

  # 13n4 — THE MIXED-DECLARATION GUARD (found in review of this change). The `Outcome:` suppression
  # makes arm 2 skippable, so a body declaring BOTH a clean and a NOT-CLEAN outcome would be
  # accepted — the tortoise#3549 shape (§13f) for the price of one pasted line. Arm 1b vetoes
  # DECLARATIONS unconditionally, in both orderings.
  rm -f "$(Q2 424795)"
  EV_REF="comment:42479501" run_record_ev 424795 STUB_EVIDENCE_BODY="**Outcome: CLEAN — no blocking issues found.**

## Review — NOT CLEAN

2 blockers found."
  assert_eq "$RECORD_RC" "3" "13n4 Outcome: CLEAN does NOT suppress a DECLARED NOT-CLEAN header (rc 3)"
  [ ! -f "$(Q2 424795)" ] && ok "13n4 no record minted from a body declaring both outcomes" || bad "13n4 minted a record declaring both outcomes"

  # 13n5 — the same exploit in the OPPOSITE order (the declaration BEFORE the clean line).
  rm -f "$(Q2 424796)"
  EV_REF="comment:42479601" run_record_ev 424796 STUB_EVIDENCE_BODY="## Review — NOT CLEAN

3 blocking issues remain.

**Outcome: CLEAN** (copied from the template)"
  assert_eq "$RECORD_RC" "3" "13n5 the declaration is caught in either order (rc 3)"
  [ ! -f "$(Q2 424796)" ] && ok "13n5 no record minted regardless of the two lines' order" || bad "13n5 minted a record with the declaration first"

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
    'reached the 10-cycle safety cap — unresolved issues remain; escalate to a human' \
    "reached this change's proportional cycle ceiling (3 of 3 cycles, RISK_CLASS=low-medium) — blocking issues remain; escalate to a human" \
    '[NO-LOOP-BUDGET] RISK_CLASS=low — the single Step 4 pass is the whole budget'; do
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
# un-substituted `N` template (`⚠️ Test review capped at 10 cycles — N issues remain:`
# in skills/test-review/SKILL.md) and the digit-substituted one.
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

# ══ §14 #633 stale gate-run remediation ═══════════════════════════════
# Renumbered from the branch's §9: main owns §9 for the #980 argv guard.
# A same-sha re-record used to be a silent no-op (marker already in the body →
# no PATCH → no `edited` event → no fresh gate run), so the documented remedy
# "re-run record-review.sh to retry" did nothing. These vectors pin the
# rerun, its recency/livelock guards, the SIGNED-marker gate, the GET transport
# of the check-runs read, and fail-soft on every failure stage.
run_record_633() { # <pr> <sha> <check-runs-json> [extra record args…]
    local pr="$1" sha="$2" cruns="$3"; shift 3
    local rcfile="$T/rc633" errfile="$T/err633" cap="$T/cap633"
    : > "$LOG"; : > "$cap"; rm -f "$errfile"
    (
        export HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG"
        export STUB_BODY="${STUB_BODY:-PR body}"
        export STUB_CAPTURE="$cap"
        export STUB_EVIDENCE_PR="$pr" STUB_EVIDENCE_REPO="daniel-ospina/agent-infra"
        export STUB_CHECK_RUNS="$cruns"
        export STUB_CHECK_RUNS_FAIL="${STUB_CHECK_RUNS_FAIL:-0}"
        export STUB_RERUN_FAIL="${STUB_RERUN_FAIL:-0}"
        export STUB_PATCH_FAIL="${STUB_PATCH_FAIL:-0}"
        # Review finding 3: an UNSIGNED marker (no key) must not fire the rerun.
        # The runner passes the caller's gate key through so a vector can unset
        # it (the suite exports a deterministic key at the top).
        export AI_REVIEW_GATE_KEY="${AI_REVIEW_GATE_KEY-}"
        # The check-name override is passed through for the same reason.
        export AI_REVIEW_GATE_CHECK_NAME="${AI_REVIEW_GATE_CHECK_NAME-}"
        [ -n "${STUB_HEAD_SHA:-}" ] && export STUB_HEAD_SHA
        rc=0
        bash "$RECORD" "$pr" "$sha" clean "daniel-ospina/agent-infra" "$@" $EV_ARGS 2>"$errfile" || rc=$?
        printf '%s' "$rc" > "$rcfile"
    ) 2>/dev/null || true
    RECORD_RC="$(cat "$rcfile" 2>/dev/null || echo 99)"
    RECORD_ERR="$(cat "$errfile" 2>/dev/null || true)"
    RECORD_CAP633="$(cat "$cap" 2>/dev/null || true)"
}

# The "marker already present" state is PRODUCED, not hand-built: run once on a
# marker-less body and hand the recorder's own posted body back. Hand-writing the
# marker would drift from the diff=/sig= contract the script actually posts.
seed_marker_body() { # <pr> → echoes the body the recorder posts (marker included)
    local pr="$1" cap="$T/seedcap"
    : > "$cap"
    (
        export HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$T/seedgh.log"
        export STUB_BODY="seeded body" STUB_CAPTURE="$cap"
        export STUB_EVIDENCE_PR="$pr" STUB_EVIDENCE_REPO="daniel-ospina/agent-infra"
        export STUB_CHECK_RUNS="[]"
        bash "$RECORD" "$pr" "$SHA" clean "daniel-ospina/agent-infra" $EV_ARGS >/dev/null 2>&1 || true
    )
    jq -r '.body' "$cap" 2>/dev/null
}

echo "── 14. #633 stale gate-run remediation ──────────────────────────"
# 14.1 Re-record on an already-marker'd body: the body is left untouched (no
#     PATCH — no body spam), but the completed-FAILURE gate job on the head MUST
#     be re-run so the stale red rollup row is replaced by a fresh attempt.
#     RED pre-fix: the idempotency guard made a same-sha re-record do nothing.
SEED_BODY="$(seed_marker_body 424320)"
if [ -n "$SEED_BODY" ]; then ok "14.0 the seed run posted a marker-bearing body (prerequisite)"; else bad "14.0 the seed run posted a marker-bearing body (prerequisite)"; fi
STUB_BODY="$SEED_BODY" run_record_633 424320 "$SHA" \
    '[{"name":"ai-review-gate","status":"completed","conclusion":"failure","id":777}]'
if grep -qF -- "actions/jobs/777/rerun" "$LOG"; then
    ok "14.1 re-record re-runs the stale FAILURE gate job (no more silent no-op)"
else
    bad "14.1 re-record re-runs the stale FAILURE gate job (log: $(cat "$LOG"))"
fi
if grep -qF -- "-X PATCH" "$LOG"; then
    bad "14.1 re-record leaves the marker'd body untouched (no PATCH)"
else
    ok "14.1 re-record leaves the marker'd body untouched (no PATCH)"
fi
if grep -qF -- "commits/$SHA/check-runs" "$LOG"; then
    ok "14.1 remediation queries the RECORDED head's check runs"
else
    bad "14.1 remediation queries the RECORDED head's check runs (log: $(cat "$LOG"))"
fi
# 14.1b THE TRANSPORT PIN: the check-runs read must be a GET. Real gh switches
#     to POST the moment a -f/-F parameter is added, and this endpoint is
#     GET-only, so `-f` without `-X GET` 404s — the exact defect this fix
#     addresses (a dead rerun behind a false "gh/API failure" warning).
#     NO PIPE INTO THE QUIET GREP: capture first, then classify the capture (#864). The piped
#     form's upstream grep takes SIGPIPE when the quiet grep exits at its first match, and
#     `pipefail` turns that 141 into a false "parameter absent" here.
if grep -q -- ' -f ' <<<"$(grep -E 'commits/.*/check-runs' "$LOG" || true)"; then
    if grep -q -- '-X GET' <<<"$(grep -E 'commits/.*/check-runs' "$LOG" || true)"; then
        ok "14.1b the check-runs read is an explicit GET (transport)"
    else
        bad "14.1b the check-runs read adds -f with NO -X GET → real gh POSTs → 404 (log: $(cat "$LOG"))"
    fi
else
    ok "14.1b the check-runs read carries its parameters in the query string (transport)"
fi

# 14.2 Fresh record (marker absent) with a stale FAILURE on the head: posts the
#     marker AND re-runs the failed gate job in the same call.
STUB_BODY="PR body" run_record_633 424321 "$SHA" \
    '[{"name":"ai-review-gate","status":"completed","conclusion":"failure","id":778}]'
grep -qF -- "-X PATCH" "$LOG" && ok "14.2 fresh record still posts the marker" || bad "14.2 fresh record posts the marker (log: $(cat "$LOG"))"
grep -qF -- "actions/jobs/778/rerun" "$LOG" && ok "14.2 fresh record also re-runs the stale FAILURE job" || bad "14.2 fresh record re-runs the stale FAILURE job (log: $(cat "$LOG"))"

# 14.3 Nothing failed on the head → no rerun (no needless Actions runs), marker
#     still posted.
STUB_BODY="PR body" run_record_633 424322 "$SHA" '[]'
if grep -qF -- "actions/jobs/" "$LOG"; then
    bad "14.3 no rerun when nothing failed (log: $(cat "$LOG"))"
else
    ok "14.3 no rerun when nothing failed"
fi
grep -qF -- "-X PATCH" "$LOG" && ok "14.3 marker still posted" || bad "14.3 marker still posted"

# 14.4 A failed run of a DIFFERENT check name is never re-run (name filter) —
#     and the zero-match case fires the loud rename hint: a wrong
#     AI_REVIEW_GATE_CHECK_NAME must not read as "nothing to remediate".
STUB_BODY="PR body" run_record_633 424323 "$SHA" \
    '[{"name":"other-gate","status":"completed","conclusion":"failure","id":779}]'
if grep -qF -- "actions/jobs/" "$LOG"; then
    bad "14.4 foreign check name not re-run (log: $(cat "$LOG"))"
else
    ok "14.4 foreign check name not re-run"
fi
assert_contains "$RECORD_ERR" "no check run named 'ai-review-gate'" "14.4 zero-match fires the loud rename hint"

# 14.5 Rerun API refusal → fail-soft: record saved, exit 0, loud warning.
STUB_BODY="PR body" STUB_RERUN_FAIL=1 run_record_633 424324 "$SHA" \
    '[{"name":"ai-review-gate","status":"completed","conclusion":"failure","id":780}]'
[ "$RECORD_RC" = "0" ] && ok "14.5 rerun refusal fails soft (rc 0, record saved)" || bad "14.5 rerun refusal fails soft (rc=$RECORD_RC, err=$RECORD_ERR)"
[ -f "$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-424324.json" ] && ok "14.5 record written despite rerun refusal" || bad "14.5 record written despite rerun refusal"
assert_contains "$RECORD_ERR" "could not re-run stale" "14.5 refusal warns on stderr"

# 14.6 Recency guard: a newer SUCCESS for the gate name already satisfies the
#     required check, so the older FAILURE must NOT trigger a rerun (no churn
#     on every re-record of an already-green head).
STUB_BODY="PR body" run_record_633 424325 "$SHA" \
    '[{"name":"ai-review-gate","status":"completed","conclusion":"failure","id":100},{"name":"ai-review-gate","status":"completed","conclusion":"success","id":200}]'
if grep -qF -- "actions/jobs/" "$LOG"; then
    bad "14.6 newer SUCCESS suppresses the rerun (log: $(cat "$LOG"))"
else
    ok "14.6 newer SUCCESS suppresses the rerun"
fi

# 14.7 --force-stale is never remediated: a deliberately stale sha's gate state
#     is unresolvable by design, and a rerun in the PR's per-PR concurrency
#     group could cancel the REAL head's in-flight gate run. No check-runs
#     query, no rerun — the record still saves.
STALE_SHA="$(printf 'b%.0s' $(seq 1 40))"
STUB_BODY="PR body" run_record_633 424326 "$STALE_SHA" \
    '[{"name":"ai-review-gate","status":"completed","conclusion":"failure","id":300}]' --force-stale
[ "$RECORD_RC" = "0" ] && ok "14.7 force-stale record still saves (rc 0)" || bad "14.7 force-stale record still saves (rc=$RECORD_RC)"
if grep -qF -- "/check-runs" "$LOG" || grep -qF -- "actions/jobs/" "$LOG"; then
    bad "14.7 force-stale skips the stale-run remediation (log: $(cat "$LOG"))"
else
    ok "14.7 force-stale skips the stale-run remediation"
fi

# 14.8 check-runs query failure (gh/API error): warns LOUDLY on stderr and skips
#     the rerun — a transient API failure must never read as "no red run" (the
#     #405 silent-no-op class, one level down). Record still saves, exit 0.
STUB_BODY="PR body" STUB_CHECK_RUNS_FAIL=1 run_record_633 424327 "$SHA" \
    '[{"name":"ai-review-gate","status":"completed","conclusion":"failure","id":400}]'
[ "$RECORD_RC" = "0" ] && ok "14.8 check-runs query failure fails soft (rc 0)" || bad "14.8 check-runs query failure fails soft (rc=$RECORD_RC, err=$RECORD_ERR)"
[ -f "$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-424327.json" ] && ok "14.8 record written despite query failure" || bad "14.8 record written despite query failure"
assert_contains "$RECORD_ERR" "could not read check runs" "14.8 query failure warns loudly on stderr"
if grep -qF -- "actions/jobs/" "$LOG"; then
    bad "14.8 no rerun on query failure (log: $(cat "$LOG"))"
else
    ok "14.8 no rerun on query failure"
fi

# 14.9 Livelock guard: when the NEWEST run for the gate name is queued/
#     in_progress (a rerun the remediation fired, or the `edited` run a fresh
#     PATCH just started), the OLDER completed red run is NOT re-run — a second
#     job would cancel the in-flight fresh run via the PR's concurrency group.
STUB_BODY="PR body" run_record_633 424328 "$SHA" \
    '[{"name":"ai-review-gate","status":"completed","conclusion":"failure","id":100},{"name":"ai-review-gate","status":"in_progress","conclusion":null,"id":900}]'
if grep -qF -- "actions/jobs/" "$LOG"; then
    bad "14.9 in-flight gate run suppresses the rerun (log: $(cat "$LOG"))"
else
    ok "14.9 in-flight gate run suppresses the rerun"
fi

# 14.10 No SIGNED marker in the body (PATCH failure) → remediation MUST NOT fire:
#      a rerun of a marker-less body re-evaluates to a guaranteed red. Record
#      still saves (best-effort).
STUB_BODY="PR body — no review evidence yet" STUB_PATCH_FAIL=1 run_record_633 424329 "$SHA" \
    '[{"name":"ai-review-gate","status":"completed","conclusion":"failure","id":500}]'
[ "$RECORD_RC" = "0" ] && ok "14.10 PATCH failure still saves the record (rc 0)" || bad "14.10 PATCH failure saves record (rc=$RECORD_RC, err=$RECORD_ERR)"
[ -f "$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-424329.json" ] && ok "14.10 record written despite PATCH failure" || bad "14.10 record written despite PATCH failure"
assert_contains "$RECORD_ERR" "could not post review evidence" "14.10 PATCH failure notes on stderr"
if grep -qF -- "actions/jobs/" "$LOG"; then
    bad "14.10 no rerun without a posted marker (log: $(cat "$LOG"))"
else
    ok "14.10 no rerun without a posted marker"
fi

# 14.11 gh-200 whose payload fails the LOCAL jq stage (shape drift, broken jq):
#      the parse failure warns loudly and skips — record saved, rc 0, no rerun.
STUB_BODY="PR body" run_record_633 424330 "$SHA" '{"check_runs": [BROKEN'
[ "$RECORD_RC" = "0" ] && ok "14.11 unparseable payload fails soft (rc 0)" || bad "14.11 unparseable payload fails soft (rc=$RECORD_RC, err=$RECORD_ERR)"
[ -f "$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-424330.json" ] && ok "14.11 record written despite parse failure" || bad "14.11 record written despite parse failure"
assert_contains "$RECORD_ERR" "could not parse the check-runs payload" "14.11 parse failure warns loudly on stderr"
if grep -qF -- "actions/jobs/" "$LOG"; then
    bad "14.11 no rerun on parse failure (log: $(cat "$LOG"))"
else
    ok "14.11 no rerun on parse failure"
fi

# 14.12 THE STUB'S OWN FIDELITY (review finding 2). The stub must model the
#       TRANSPORT, not just the URL: a /check-runs call carrying -f/-F without
#       `-X GET` is a POST and real gh/GitHub 404s it. Without this the suite
#       answers 200 to a request that cannot succeed in production and certifies
#       a dead call (it did exactly that for the branch's original `-f` read).
TLOG="$T/transport.log"; : > "$TLOG"
if GH_STUB_LOG="$TLOG" STUB_CHECK_RUNS='[]' "$T/bin/gh" api "repos/x/y/commits/$SHA/check-runs" -f check_name=ai-review-gate -f per_page=100 >/dev/null 2>&1; then
    bad "14.12 the stub 404s a parameterized check-runs call without -X GET (it did not — the suite would be blind again)"
else
    ok "14.12 the stub 404s a parameterized check-runs call without -X GET (transport modeled)"
fi
if GH_STUB_LOG="$TLOG" STUB_CHECK_RUNS='[]' "$T/bin/gh" api "repos/x/y/commits/$SHA/check-runs?check_name=ai-review-gate&per_page=100" >/dev/null 2>&1; then
    ok "14.12b the stub serves the query-string form (the fix's transport)"
else
    bad "14.12b the stub serves the query-string form"
fi
if GH_STUB_LOG="$TLOG" STUB_CHECK_RUNS='[]' "$T/bin/gh" api "repos/x/y/commits/$SHA/check-runs" -X GET -f check_name=ai-review-gate >/dev/null 2>&1; then
    ok "14.12c the stub serves the explicit -X GET form"
else
    bad "14.12c the stub serves the explicit -X GET form"
fi
# 14.12d the RECORDER's actual argv order (`-X GET` BEFORE the URL) must be a
#       READ, not the stub's PATCH/rerun capture branch. That branch keyed on
#       `$2 = -X` alone, so the check-runs read fell into it, consumed an empty
#       stdin into STUB_CAPTURE, and BLANKED the recorded marker — every diff=
#       assertion failed while the check-runs pins still passed. RED pre-fix:
#       the call returns empty stdout (the capture branch prints nothing).
TLOG="$T/transport.log"
GOT_14_12D="$(GH_STUB_LOG="$TLOG" STUB_CHECK_RUNS='[{"name":"x"}]' "$T/bin/gh" api -X GET "repos/x/y/commits/$SHA/check-runs" -f check_name=x -f per_page=100 </dev/null 2>/dev/null)"
assert_contains "$GOT_14_12D" '"check_runs"' "14.12d the stub treats the recorder's -X GET (before the URL) as a READ"

# 14.13 THE SIGNED-MARKER GATE (review finding 3). With NO gate key the recorder
#       posts an UNSIGNED marker, which the gate is guaranteed to reject — so a
#       rerun against it is pure churn. The predicate must therefore key on the
#       SIGNED form (sig=…), not on the marker text. RED pre-fix: MARKER_PRESENT
#       was set from a text-only grep, so the unsigned body re-ran the job.
UNSIGNED_BODY="$(printf '%s' "$SEED_BODY" | sed 's/ sig=[0-9a-f]\{64\}$//')"
if [ "$UNSIGNED_BODY" != "$SEED_BODY" ] && ! grep -q ' sig=' <<<"$UNSIGNED_BODY"; then
    ok "14.13 the unsigned-marker fixture dropped the signature (prerequisite)"
else
    bad "14.13 the unsigned-marker fixture dropped the signature (prerequisite)"
fi
STUB_BODY="$UNSIGNED_BODY" AI_REVIEW_GATE_KEY="" run_record_633 424331 "$SHA" \
    '[{"name":"ai-review-gate","status":"completed","conclusion":"failure","id":601}]'
assert_contains "$RECORD_ERR" "AI_REVIEW_GATE_KEY not configured" "14.13 an unkeyed run posts an unsigned marker (prerequisite)"
if grep -qF -- "actions/jobs/601/rerun" "$LOG"; then
    bad "14.13 an UNSIGNED marker does not fire the rerun (guaranteed-red churn) (log: $(cat "$LOG"))"
else
    ok "14.13 an UNSIGNED marker does not fire the rerun (guaranteed-red churn)"
fi

# 14.14 THE ALLOW-LIST POLARITY (review finding 1). The repo mandate (AGENTS.md
#       §"Reading verification state" step 4, implemented by target_head_red in
#       this same file) is: only success/neutral/skipped are green and
#       cancelled/stale are non-red; EVERY OTHER conclusion is RED — including
#       one GitHub has not documented and a null one. A CLOSED red-list
#       (failure/cancelled/timed_out/action_required) read an unrecognised or
#       null conclusion as "not red AND not suspicious": no rerun and no
#       warning — the silent no-op #633 exists to close. RED pre-fix: `notice`
#       and `null` both left NEWEST_RED_ID empty with nothing on stderr.
STUB_BODY="PR body" run_record_633 424332 "$SHA" \
    '[{"name":"ai-review-gate","status":"completed","conclusion":"notice","id":610}]'
if grep -qF -- "actions/jobs/610/rerun" "$LOG"; then
    ok "14.14 an UNDOCUMENTED conclusion (notice) is RED and re-runs the job"
else
    bad "14.14 an undocumented conclusion was silently treated as non-red (log: $(cat "$LOG"); err=$RECORD_ERR)"
fi
# 14.14b a NULL conclusion on a completed run is RED too (the #1353 fail-open,
#       one level down) — and must warn/remediate, never read as nothing-to-do.
STUB_BODY="PR body" run_record_633 424333 "$SHA" \
    '[{"name":"ai-review-gate","status":"completed","conclusion":null,"id":611}]'
grep -qF -- "actions/jobs/611/rerun" "$LOG" && ok "14.14b a NULL conclusion on the newest completed run is RED" || bad "14.14b a null conclusion was silently treated as non-red (log: $(cat "$LOG"))"
# 14.14c the named NON-RED conclusions stay non-red — no churn. `cancelled` is
#        non-red per the repo rule (the pre-fix closed list had it RED).
STUB_BODY="PR body" run_record_633 424334 "$SHA" \
    '[{"name":"ai-review-gate","status":"completed","conclusion":"cancelled","id":612}]'
if grep -qF -- "actions/jobs/" "$LOG"; then
    bad "14.14c cancelled is non-red — no rerun (log: $(cat "$LOG"))"
else
    ok "14.14c cancelled is non-red — no rerun"
fi
# 14.14d an unrecognised STATUS with a NULL conclusion is RED (in-flight is the
#        named set only) — the same decision target_head_red makes.
STUB_BODY="PR body" run_record_633 424335 "$SHA" \
    '[{"name":"ai-review-gate","status":"something_new","conclusion":null,"id":613}]'
grep -qF -- "actions/jobs/613/rerun" "$LOG" && ok "14.14d an unknown status with a NULL conclusion is RED" || bad "14.14d an unknown status read as pending/non-red (log: $(cat "$LOG"))"

# 14.15 THE CHECK-NAME OVERRIDE (review finding 2). A check-run NAME is an
#       arbitrary string; interior whitespace is MEANINGFUL and must survive the
#       override read. `tr -d '[:space:]'` (copied from the HMAC-key read)
#       deleted it, so the documented AI_REVIEW_GATE_CHECK_NAME override silently
#       mismatched any renamed check containing a space (`python-ci / test` is a
#       real name on this fleet): server filter matched nothing, local name
#       filter matched nothing, remediation never fired. RED pre-fix: GATE_CHECK
#       became `python-ci/test`. Only leading/trailing padding is still trimmed.
STUB_BODY="PR body" AI_REVIEW_GATE_CHECK_NAME="  python-ci / test  " run_record_633 424336 "$SHA" \
    '[{"name":"python-ci / test","status":"completed","conclusion":"failure","id":614}]'
if grep -qF -- "actions/jobs/614/rerun" "$LOG"; then
    ok "14.15 an override with interior whitespace is preserved and re-runs the job"
else
    bad "14.15 interior whitespace in AI_REVIEW_GATE_CHECK_NAME was mangled (log: $(cat "$LOG"); err=$RECORD_ERR)"
fi
if grep -qF -- "check_name=python-ci / test" "$LOG"; then
    ok "14.15 padding trimmed, interior whitespace intact in the query"
else
    bad "14.15 check-name normalization mangled the name (log: $(cat "$LOG"))"
fi


echo ""
echo "── 15. #1709 rec 7: the same head twice is the SAME record ──────────"
# `record-review.sh` runs AT-LEAST-ONCE (a crash, a paused worker that resumes,
# or a second box sweeping the same PR re-executes the same record). The side
# effect must therefore be idempotent: recording the SAME review for the SAME
# head twice must produce the SAME artifact. The PR-body MARKER already satisfied
# this — its text is a pure function of pr/verdict/sha/diff/repo and the append is
# a whole-string `grep -qF` — but the RECORD FILE did not: every run re-stamped
# `reviewed_at` from the wall clock and rewrote the file, so a duplicate MUTATED
# the attestation. That is corruption, not waste: `reviewed_at` is the audit
# trail's ONLY join from a merge-gate pass to the review that authorised it
# (extensions/review-enforcer `logMergeGateDecision`), and it must not move
# because a paused worker resumed. The head sha is the idempotency key.
PR_IDEM=424800
IDEM_PATH="$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-$PR_IDEM.json"
rm -f "$IDEM_PATH"
run_record_diff "$PR_IDEM" "$SHA" "PR body" "$D_F"
[ "$RECORD_RC" = "0" ] && ok "15.1 first record succeeds" || bad "15.1 first record (rc=$RECORD_RC)"
IDEM_1="$(cat "$IDEM_PATH" 2>/dev/null || true)"
# A ≥1s gap: `reviewed_at` has SECOND resolution, so a shorter gap could produce
# the same stamp by luck and the equality asserted below would hold for a reason
# that is not the guard.
sleep 1
run_record_diff "$PR_IDEM" "$SHA" "PR body" "$D_F"
[ "$RECORD_RC" = "0" ] && ok "15.2 the duplicate execution succeeds" || bad "15.2 duplicate execution (rc=$RECORD_RC)"
IDEM_2="$(cat "$IDEM_PATH" 2>/dev/null || true)"
if [ -n "$IDEM_1" ] && [ "$IDEM_1" = "$IDEM_2" ]; then
    ok "15.3 same head twice → BYTE-IDENTICAL record (reviewed_at preserved)"
else
    bad "15.3 a duplicate execution rewrote the record: 1=$IDEM_1 2=$IDEM_2"
fi
assert_contains "$RECORD_ERR" "#1709 rec 7 idempotent" "15.4 the no-op is named on stderr, not silent"

# 15.5-15.6 the IDENTITY PREDICATE directly — NOT the guard's wiring, which §15.7 drives
#        through the real runner: only the VOLATILE fields (`reviewed_at`, the carry
#        provenance) are dropped. The deterministic fields — and in particular the
#        EVIDENCE ref — ARE the identity, so a predicate that dropped one would call a
#        different artifact the same attestation and swallow its re-record.
idem_ident() { bash -c 'source "$1" >/dev/null 2>&1 || exit 1; record_identity "$2"' _ "$RECORD" "$1"; }
printf '{"pr":1,"head_sha":"S","diff_sha256":"D","mint":"fresh","evidence":"comment:1","verdict":"clean","repo":"r","reviewed_at":"2026-01-01T00:00:00Z"}\n' > "$T/idem-a.json"
printf '{"pr":1,"head_sha":"S","diff_sha256":"D","mint":"carried","carried_from":"H","carried_at":"2026-01-02T00:00:00Z","evidence":"comment:1","verdict":"clean","repo":"r","reviewed_at":"2025-01-01T00:00:00Z"}\n' > "$T/idem-b.json"
printf '{"pr":1,"head_sha":"S","diff_sha256":"D","mint":"fresh","evidence":"comment:2","verdict":"clean","repo":"r","reviewed_at":"2026-01-01T00:00:00Z"}\n' > "$T/idem-c.json"
if [ "$(idem_ident "$T/idem-a.json")" = "$(idem_ident "$T/idem-b.json")" ]; then
    ok "15.5 a fresh and a carried record at one head share an identity (volatile provenance dropped)"
else
    bad "15.5 the carry provenance was treated as identity — a duplicate carry would churn the record"
fi
if [ "$(idem_ident "$T/idem-a.json")" != "$(idem_ident "$T/idem-c.json")" ]; then
    ok "15.6 a DIFFERENT evidence ref is a different attestation (it still rewrites)"
else
    bad "15.6 the evidence ref was dropped from the identity — the predicate cannot tell two attestations apart"
fi

# 15.7 RUNNER-LEVEL: the SAME head with a DIFFERENT artifact still REWRITES. §15.1-§15.3
#      pin the equal-identity no-op and §15.5/§15.6 pin the predicate
#      DIRECTLY — but neither drives the shipped script through the guard's ELSE arm, so a
#      guard weakened to compare only `head_sha` would leave every vector above green while
#      silently SWALLOWING a re-record of a different artifact at the same head, which is
#      the one failure rec 7 must not introduce. A second diff file gives the same head a
#      different `diff_sha256`, through the real runner.
D_F2="$T/diff-idem-2.txt"; printf 'diff --git a/x b/x\n+goodbye\n' > "$D_F2"
D1_SHA="$(printf '%s' "$IDEM_2" | sed -n 's/.*"diff_sha256":"\([^"]*\)".*/\1/p')"
run_record_diff "$PR_IDEM" "$SHA" "PR body" "$D_F2"
[ "$RECORD_RC" = "0" ] \
    && ok "15.7 a same-head re-record on a DIFFERENT diff succeeds" \
    || bad "15.7 same-head re-record on a different diff (rc=$RECORD_RC; err=$RECORD_ERR)"
D2_SHA="$(sed -n 's/.*"diff_sha256":"\([^"]*\)".*/\1/p' "$IDEM_PATH" 2>/dev/null)"
if [ -n "$D2_SHA" ] && [ "$D2_SHA" != "$D1_SHA" ]; then
    ok "15.7 the record CHANGED (diff_sha256 ${D1_SHA:0:12}… → ${D2_SHA:0:12}…): the guard did not swallow it"
else
    bad "15.7 the guard swallowed a same-head re-record of a DIFFERENT artifact (diff_sha256 stayed '${D2_SHA:-<none>}')"
fi
case "$RECORD_ERR" in
    *idempotent*) bad "15.7 the different-artifact run took the NO-OP path — the guard over-fired on an inequality" ;;
    *)            ok "15.7 the different-artifact run did NOT take the no-op path" ;;
esac

# 15.8 the LEGACY MIGRATION still runs when the record write is SKIPPED.
#      The comment on the guard CLAIMS the legacy-migration and evidence-post blocks below
#      still run — code the no-op path does not itself execute — so it must be PINNED, not
#      asserted. The run below is a true same-head DUPLICATE (the diff matches what is on
#      disk, so the identity is equal and the write is skipped) with a legacy key present.
printf '{"pr":%d,"head_sha":"%s","verdict":"clean","repo":"daniel-ospina/agent-infra","reviewed_at":"old"}\n' \
    "$PR_IDEM" "$SHA" > "$F_HOME/.pi/agent/reviews/$PR_IDEM.json"
run_record_diff "$PR_IDEM" "$SHA" "PR body" "$D_F2"
[ "$RECORD_RC" = "0" ] \
    && ok "15.8 the duplicate run still exits 0 with a legacy key present" \
    || bad "15.8 duplicate run with a legacy key (rc=$RECORD_RC; err=$RECORD_ERR)"
case "$RECORD_ERR" in
    *idempotent*) ok "15.8  …and the write really WAS skipped, so the migration claim is tested on the no-op path" ;;
    *)            bad "15.8 the run rewrote the record — the legacy claim was NOT tested on the skip path" ;;
esac
[ ! -f "$F_HOME/.pi/agent/reviews/$PR_IDEM.json" ] \
    && ok "15.8 the legacy key is MIGRATED AWAY even though the record write was skipped" \
    || bad "15.8 the duplicate run took the no-op path and STRANDED the legacy key"

# 15.9 MUTATION PIN — the guard is what makes 15.3 true. A copy with the
#      idempotency guard disarmed MUST rewrite the record on the second run
#      (reviewed_at moves), proving 15.3 is load-bearing rather than green by
#      accident.
mkdir -p "$T/mut-idem/lib"
cp "$SCRIPT_DIR/lib/diff-normalize.py" "$T/mut-idem/lib/diff-normalize.py"
python3 - "$RECORD" "$T/mut-idem/record-review.sh" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
old = 'if [ -f "$FILE" ] && [ "$(record_identity "$FILE")" = "$(record_identity "$TMP")" ]; then'
new = 'if false; then   # MUTATION (#1709 rec 7): the idempotency guard disarmed'
assert old in text, "mutation anchor not found"
open(dst, "w").write(text.replace(old, new))
PY
if cmp -s "$T/mut-idem/record-review.sh" "$RECORD"; then
    bad "15.9 mutation: the mutant copy is IDENTICAL to the script"
else
    ok "15.9 mutation: the mutant copy differs from the script"
fi
PR_IDEM_M=424801
IDEM_M_PATH="$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-$PR_IDEM_M.json"
rm -f "$IDEM_M_PATH"
run_record_diff_with "$T/mut-idem/record-review.sh" "$PR_IDEM_M" "$SHA" "PR body" "$D_F"
IDEM_M1="$(cat "$IDEM_M_PATH" 2>/dev/null || true)"
sleep 1
run_record_diff_with "$T/mut-idem/record-review.sh" "$PR_IDEM_M" "$SHA" "PR body" "$D_F"
IDEM_M2="$(cat "$IDEM_M_PATH" 2>/dev/null || true)"
if [ -n "$IDEM_M1" ] && [ "$IDEM_M1" != "$IDEM_M2" ]; then
    ok "15.9 MUTATION: without the guard the duplicate REWRITES the record — 15.3 is load-bearing"
else
    bad "15.9 mutation: the guardless copy still produced an identical record — 15.3 does not test the guard"
fi


echo "── 19. tortoise#9492: --expect-head pins the head the reviewer NAMED ──"
# The defect this pins: GitHub can leave `refs/pull/<n>/head` behind its own
# branch. `--force-stale` is not the tool for it (that records the stale sha on
# purpose), and the #2982 carry arm answers about the PR HEAD's diff — so a
# reviewer who names the tree they read had no way to make that statement hold.
E_OK=424811; E_MISMATCH=424812; E_WEDGE=424813; E_SHORT=424814
rm -f "$(Q2 $E_OK)" "$(Q2 $E_MISMATCH)" "$(Q2 $E_WEDGE)" "$(Q2 $E_SHORT)"

# 19.1 the pin MATCHES the PR head → an ordinary record, and it names that head.
run_record_diff "$E_OK" "$SHA" "PR body" "$D_F" 0 --expect-head "$SHA"
[ "$RECORD_RC" = "0" ] && ok "19.1 a matching --expect-head records (rc 0)" || bad "19.1 matching pin (rc=$RECORD_RC, err=$RECORD_ERR)"
assert_contains "$(cat "$(Q2 $E_OK)" 2>/dev/null)" "\"head_sha\":\"$SHA\"" "19.1 the record names the pinned head"
assert_contains "$RECORD_CAP" "@ $SHA diff=$DH " "19.1 the marker binds the pinned head"

# 19.2 the pin names a sha the PR head is NOT → refuse, and write NOTHING.
# STUB_BRANCH_SHA is left unset so the stub answers "could not read the branch".
unset STUB_BRANCH_SHA 2>/dev/null || true
run_record_diff "$E_MISMATCH" "$SHA" "PR body" "$D_F" 0 --expect-head "$STALE"
[ "$RECORD_RC" = "3" ] && ok "19.2 a mismatched --expect-head refuses (exit 3)" || bad "19.2 mismatched pin (rc=$RECORD_RC, want 3)"
assert_contains "$RECORD_ERR" "--expect-head" "19.2 the refusal names the flag"
assert_contains "$RECORD_ERR" "Neither the PR ref" "19.2 the refusal says neither ref is at the named sha"
[ ! -f "$(Q2 $E_MISMATCH)" ] && ok "19.2 no record written" || bad "19.2 a record was written for a refused pin"
[ -z "$RECORD_CAP" ] && ok "19.2 no marker posted" || bad "19.2 a marker was posted for a refused pin"

# 19.3 the SAME refusal, but the BRANCH is at the named sha → name the wedge.
# This is the measured tortoise#9484 state: branch 45c7aaf33, PR ref f9e69256c.
STUB_BRANCH_SHA="$STALE" run_record_diff "$E_WEDGE" "$SHA" "PR body" "$D_F" 0 --expect-head "$STALE"
[ "$RECORD_RC" = "3" ] && ok "19.3 the wedged-head case refuses (exit 3)" || bad "19.3 wedged head (rc=$RECORD_RC, want 3)"
assert_contains "$RECORD_ERR" "refs/heads/" "19.3 the refusal names the branch ref it read"
assert_contains "$RECORD_ERR" "behind its own branch" "19.3 the refusal names the wedge as the cause"
[ ! -f "$(Q2 $E_WEDGE)" ] && ok "19.3 no record written for the wedged head" || bad "19.3 a record was written for the wedged head"

# 19.4 a SHORT sha is a usage error, never a prefix match.
run_record_diff "$E_SHORT" "$SHA" "PR body" "$D_F" 0 --expect-head "${STALE:0:8}"
[ "$RECORD_RC" = "2" ] && ok "19.4 a short --expect-head is a usage error (exit 2)" || bad "19.4 short pin (rc=$RECORD_RC, want 2)"
assert_contains "$RECORD_ERR" "40-hex" "19.4 the usage error says what it wants"
[ ! -f "$(Q2 $E_SHORT)" ] && ok "19.4 no record written for the usage error" || bad "19.4 a record was written for the usage error"

# 19.5 the flag is INERT when the heads agree — the same invocation WITHOUT it
# must reach the same decision, or every existing caller changes behaviour.
run_record_diff "$E_OK" "$SHA" "PR body" "$D_F" 0
[ "$RECORD_RC" = "0" ] && ok "19.5 without the flag the matching case still records (rc 0)" || bad "19.5 flagless control (rc=$RECORD_RC)"

# 19.6 a pin that CANNOT be checked must refuse, not pass. Without a $REPO the
# head-resolution block is skipped entirely — the pin would be ignored and a
# record written, making --expect-head decorative. "I could not check" is not
# "it matched".
E_NOREPO=424815; rm -f "$(Q2 $E_NOREPO)" "$F_HOME/.pi/agent/reviews/$E_NOREPO.json"
run_record_raw "$E_NOREPO" "$SHA" clean --expect-head "$SHA"
[ "$RECORD_RC" = "3" ] && ok "19.6 an unverifiable pin refuses (exit 3)" || bad "19.6 unverifiable pin (rc=$RECORD_RC, want 3)"
assert_contains "$RECORD_ERR" "could not verify the PR head" "19.6 the refusal says the pin could not be checked"
[ ! -f "$(Q2 $E_NOREPO)" ] && ok "19.6 no record written" || bad "19.6 a record was written for an unverifiable pin"
[ ! -f "$F_HOME/.pi/agent/reviews/$E_NOREPO.json" ] && ok "19.6 no legacy record written" || bad "19.6 a legacy record was written for an unverifiable pin"

echo ""
echo "  PASS=$PASS FAIL=$FAIL"
SUMMARY_PRINTED=1   # the sentinel: only from here may the EXIT trap pass an exit status through
[ "$FAIL" -eq 0 ] || { echo "  ❌ FAILURES — fix and re-run"; exit 1; }
echo "  ✅ all checks passed"
exit 0
